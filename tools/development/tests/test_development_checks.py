import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = load("dev_check", ROOT / "tools/dev_check.py")
swift = load("swift_sources", ROOT / "tools/development/swift_compile.py")
simulator = load("simulator_session", ROOT / "tools/development/simulator_session.py")


class DevelopmentChecksTests(unittest.TestCase):
    def run_checks(self, checks, *, changed=False):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        report = Path(temporary.name) / "results.json"
        source = {"commit": "a" * 40, "dirty": False}
        identities = [source, {**source, "dirty": True} if changed else source]
        with patch.object(runner, "source_identity", side_effect=identities), contextlib.redirect_stdout(io.StringIO()):
            code = runner.run_checks(checks, report)
        return code, json.loads(report.read_text())

    def test_missing_dependency_is_blocked_and_never_runs(self):
        code, report = self.run_checks([{"id": "missing", "name": "Missing", "command": "exit 99",
                                        "tools": ["bicino-definitely-not-installed"]}])
        self.assertEqual(code, 1)
        self.assertEqual(report["checks"][0]["status"], "blocked")
        self.assertNotIn("exitCode", report["checks"][0])

    def test_failed_probe_blocks_before_product_test(self):
        code, report = self.run_checks([{"id": "probe", "name": "Probe", "command": "exit 99",
            "probes": [{"command": [sys.executable, "-c", "raise SystemExit(2)"]}]}])
        self.assertEqual(code, 1)
        self.assertEqual(report["checks"][0]["status"], "blocked")

    def test_failure_does_not_hide_other_results(self):
        code, report = self.run_checks([
            {"id": "bad", "name": "Bad", "command": "exit 7"},
            {"id": "good", "name": "Good", "command": "test -d \"$TMPDIR\""}])
        self.assertEqual(code, 1)
        self.assertEqual([c["status"] for c in report["checks"]], ["failed", "passed"])
        self.assertEqual(report["checks"][0]["exitCode"], 7)

    def test_changed_source_invalidates_success(self):
        code, report = self.run_checks([{"id": "good", "name": "Good", "command": "true"}], changed=True)
        self.assertEqual(code, 1)
        self.assertFalse(report["sourceUnchanged"])
        self.assertEqual(report["checks"][0]["status"], "passed")
        self.assertEqual(report["status"], "failed")

    def test_missing_board_blocks_firmware(self):
        code, report = self.run_checks([{"id": "board", "name": "Board", "command": "exit 99", "requiresBoard": True}])
        self.assertEqual(code, 1)
        self.assertIn("--board", report["checks"][0]["reasons"][0])

    def test_exact_build_is_blocked_before_expensive_dirty_source_validation(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(runner, "source_identity", return_value={"commit":"a"*40,"dirty":True}), contextlib.redirect_stdout(io.StringIO()):
            report=Path(temporary)/"results.json"
            self.assertEqual(runner.run_checks([{"id":"exact", "name":"Exact", "command":"exit 99", "requiresCleanSource":True}],report),1)
            result=json.loads(report.read_text())["checks"][0]
            self.assertEqual(result["status"],"blocked")
            self.assertNotIn("exitCode",result)

    def test_success_retains_commit_and_logs(self):
        code, report = self.run_checks([{"id": "good", "name": "Good", "command": "echo checked"}])
        self.assertEqual(code, 0)
        self.assertEqual(report["source"]["commit"], "a" * 40)
        self.assertEqual(Path(report["checks"][0]["log"]).read_text().strip(), "checked")

    def test_registry_has_unique_ids_existing_workdirs_and_valid_graphs(self):
        registry = json.loads(runner.REGISTRY.read_text())["checks"]
        self.assertEqual(len(registry), len({c["id"] for c in registry}))
        for check in registry:
            self.assertTrue((ROOT / check.get("cwd", ".")).is_dir(), check["id"])
        groups = json.loads((ROOT / "tools/development/swift-sources.json").read_text())["groups"]
        for name in groups:
            for source in swift.sources(name, groups):
                self.assertTrue((ROOT / source).is_file(), (name, source))

    def test_source_groups_reject_cycles(self):
        with self.assertRaisesRegex(ValueError, "cyclic"):
            swift.sources("a", {"a": {"groups": ["b"]}, "b": {"groups": ["a"]}})

    def test_dirty_identity_changes_with_content_not_just_filename(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def git(*args):
                return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)
            git("init", "-q")
            file = root / "source.txt"
            file.write_text("initial")
            git("add", ".")
            git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "Initial")
            with patch.object(runner, "ROOT", root):
                file.write_text("one")
                first = runner.source_identity()
                file.write_text("two")
                second = runner.source_identity()
            self.assertTrue(first["dirty"])
            self.assertEqual(first["commit"], second["commit"])
            self.assertNotEqual(first["workingStateSha256"], second["workingStateSha256"])


class SimulatorOwnershipTests(unittest.TestCase):
    identifier = "00000000-0000-0000-0000-000000000001"

    def test_explicit_simulator_is_never_shutdown_or_deleted(self):
        devices = {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            {"udid": self.identifier, "isAvailable": True, "state": "Booted"}]}}
        with patch.object(simulator, "lease", return_value=contextlib.nullcontext()), \
             patch.object(simulator, "simctl", return_value=devices), \
             patch.object(simulator.subprocess, "Popen") as child, \
             patch.object(simulator.subprocess, "run") as cleanup:
            child.return_value.wait.return_value = 0
            child.return_value.poll.return_value = 0
            self.assertEqual(simulator.run("ios", ["true"], identifier=self.identifier), 0)
            cleanup.assert_not_called()

    def test_owned_simulator_is_cleaned_after_failed_child(self):
        devices = {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            {"udid": self.identifier, "isAvailable": True, "state": "Shutdown"}]}}
        with patch.object(simulator, "create", return_value=self.identifier), \
             patch.object(simulator, "lease", return_value=contextlib.nullcontext()), \
             patch.object(simulator, "simctl", return_value=devices), \
             patch.object(simulator.subprocess, "Popen") as child, \
             patch.object(simulator.subprocess, "run") as cleanup:
            child.return_value.wait.return_value = 7
            child.return_value.poll.return_value = 7
            self.assertEqual(simulator.run("ios", ["false"]), 7)
            self.assertEqual([c.args[0][2] for c in cleanup.call_args_list], ["shutdown", "delete"])
            self.assertTrue(all(c.args[0][3] == self.identifier for c in cleanup.call_args_list))

    def test_same_simulator_lease_cannot_overlap(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(Path, "home", return_value=Path(temporary)):
            with simulator.lease(self.identifier):
                with self.assertRaisesRegex(RuntimeError, "already leased"):
                    with simulator.lease(self.identifier):
                        self.fail("overlapping simulator lease was admitted")


if __name__ == "__main__":
    unittest.main()
