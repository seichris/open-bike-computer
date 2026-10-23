"""Exercise the trust boundary and the real runner's reuse/fallback paths."""
import base64
import contextlib
import copy
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import time
import unittest
import zlib
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("dev_check_reuse_tests", ROOT / "tools/dev_check.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
local = runner.local_results


class LocalResultsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys = tempfile.TemporaryDirectory()
        cls.key = Path(cls.keys.name) / "key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(cls.key)], check=True)
        cls.public = " ".join(cls.key.with_suffix(".pub").read_text().split()[:2])

    @classmethod
    def tearDownClass(cls):
        cls.keys.cleanup()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.marker = self.root / "hosted-executed"
        self.check = {"id": "ios-navigation-radio", "name": "Radio", "component": "ios",
                      "host": ["Darwin"], "tools": ["xcrun"],
                      "command": f"touch '{self.marker}'"}
        self.source = {"commit": "a" * 40, "tree": "b" * 40, "dirty": False}
        self.policy = {"schema": 1, "repository": local.REPOSITORY, "publicKeys": [self.public],
                       "checks": [self.check["id"]], "maxAgeSeconds": 3600}
        self.toolchain = {"os": "macOS build", "swiftc": "compiler hash", "sdk": "sdk build"}
        self.recipe = local.recipe(self.check)
        self.now = int(time.time())
        log = b"Actual local test output\n"
        self.payload = {"schema": 1, "repository": local.REPOSITORY, "source": self.source,
                        "sourceUnchanged": True, "checkId": self.check["id"], "recipe": self.recipe,
                        "toolchain": self.toolchain, "status": "passed", "exitCode": 0,
                        "execution": "local", "startedAt": self.now - 10, "completedAt": self.now - 1,
                        "logZlibBase64": base64.b64encode(zlib.compress(log)).decode(),
                        "logSha256": local.digest(log), "logBytes": len(log)}
        self.envelope = local.sign(self.payload, self.key)

    def verify(self, envelope=None, **overrides):
        args = dict(policy=self.policy, source=self.source, expected_commit=self.source["commit"],
                    expected_recipe=self.recipe, toolchain=self.toolchain, now=self.now)
        args.update(overrides)
        return local.verify(envelope or self.envelope, **args)

    def test_real_signature_roundtrip_and_json_transport(self):
        envelope = json.loads(local.canonical(self.envelope))
        self.assertEqual(self.verify(envelope), b"Actual local test output\n")

    def test_unsigned_legacy_and_malformed_receipts_are_rejected(self):
        for invalid in ({"schema": 1, "status": "passed"}, [], None, {"payload": {}},
                        {"payload": self.payload, "signature": "invalid"}):
            with self.subTest(invalid=invalid), self.assertRaises(local.ERRORS):
                local.verify(invalid, self.policy, self.source, self.source["commit"], self.recipe, self.toolchain)

    def test_altered_signature_and_untrusted_key_fail(self):
        tampered = copy.deepcopy(self.envelope)
        tampered["payload"]["toolchain"]["os"] = "other"
        with self.assertRaises(subprocess.SubprocessError):
            self.verify(tampered)
        policy = {**self.policy, "publicKeys": ["ssh-ed25519 AAAA"]}
        with self.assertRaises(subprocess.SubprocessError):
            self.verify(policy=policy)

    def test_signed_but_ineligible_evidence_is_rejected(self):
        cases = {
            "old schema": lambda p: p.update(schema=0),
            "wrong repo": lambda p: p.update(repository="other/repo"),
            "different tree": lambda p: p["source"].update(tree="c" * 40),
            "different head": lambda p: p["source"].update(commit="c" * 40),
            "dirty": lambda p: p["source"].update(dirty=True),
            "changed during test": lambda p: p.update(sourceUnchanged=False),
            "command": lambda p: p["recipe"]["check"].update(command="true"),
            "flags": lambda p: p["recipe"].update(fresh=True),
            "runner": lambda p: p["recipe"].update(runnerSha256="different"),
            "toolchain": lambda p: p["toolchain"].update(swiftc="different"),
            "failed": lambda p: p.update(status="failed"),
            "nonzero exit": lambda p: p.update(exitCode=1),
            "planned": lambda p: p.update(execution="planned"),
            "reused receipt": lambda p: p.update(execution="reused-local"),
            "expired": lambda p: p.update(startedAt=self.now - 3601),
            "future": lambda p: p.update(completedAt=self.now + 100),
            "reversed time": lambda p: p.update(startedAt=self.now),
            "bad log hash": lambda p: p.update(logSha256="wrong"),
            "wrong log length": lambda p: p.update(logBytes=1),
            "truncated log": lambda p: p.update(logZlibBase64=base64.b64encode(zlib.compress(b"log")[:-1]).decode()),
            "log bomb": lambda p: p.update(logZlibBase64=base64.b64encode(zlib.compress(b"x" * (local.MAX_LOG+1))).decode()),
        }
        for label, mutate in cases.items():
            with self.subTest(label=label):
                payload = copy.deepcopy(self.payload)
                mutate(payload)
                with self.assertRaises(ValueError):
                    self.verify(local.sign(payload, self.key))

    def test_merge_tree_dirty_consumer_and_command_mismatches(self):
        for overrides in ({"source": {**self.source, "tree": "c" * 40}},
                          {"source": {**self.source, "dirty": True}},
                          {"expected_commit": "d" * 40},
                          {"toolchain": {}}, {"policy": {**self.policy, "checks": []}}):
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                self.verify(**overrides)

    def run_ci(self, receipt, *, event_name="pull_request", allowed="true", fork=False, transport_error=False):
        event = {"repository": {"full_name": local.REPOSITORY}, "pull_request": {
            "base": {"sha": "d" * 40}, "head": {"sha": self.source["commit"],
            "repo": {"full_name": "fork/repo" if fork else local.REPOSITORY}}}}
        event_path = self.root / "event.json"
        event_path.write_text(json.dumps(event))
        seen = []
        def read(path, ref, **kwargs):
            seen.append((path, ref))
            if transport_error:
                raise RuntimeError("offline")
            if path == local.POLICY:
                return local.canonical(self.policy), "policy-blob"
            return None if receipt is None else (local.canonical(receipt), "receipt-blob")
        report = self.root / "report.json"
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "CI": "true",
             "GITHUB_EVENT_NAME": event_name, "LOCAL_RESULTS_ALLOWED": allowed,
             "GITHUB_EVENT_PATH": str(event_path)}), \
             patch.object(runner, "source_identity", return_value=self.source), \
             patch.object(runner, "prerequisites", return_value=[]), \
             patch.object(local, "read_file", side_effect=read), \
             patch.object(local, "fingerprint", return_value=self.toolchain), \
             patch.object(local, "publish") as publish, contextlib.redirect_stdout(io.StringIO()):
            code = runner.run_checks([self.check], report, reuse_local=True)
        publish.assert_not_called()
        return code, json.loads(report.read_text()), seen

    def test_runner_reuses_real_signed_evidence_without_executing_command(self):
        code, report, seen = self.run_ci(self.envelope)
        self.assertEqual(code, 0)
        self.assertFalse(self.marker.exists())
        entry = report["checks"][0]
        self.assertEqual(entry["execution"], "reused-local")
        self.assertEqual(Path(entry["log"]).read_bytes(), self.verify())
        self.assertEqual(json.loads(Path(entry["signedReceipt"]).read_text()), self.envelope)
        self.assertEqual(seen[0], (local.POLICY, "d" * 40))

    def test_every_miss_runs_the_actual_hosted_command(self):
        changed = copy.deepcopy(self.payload)
        changed["toolchain"]["sdk"] = "other SDK"
        for receipt, kwargs in ((None, {}), ({"schema": 1}, {}),
                (local.sign(changed, self.key), {}), (self.envelope, {"transport_error": True}),
                (self.envelope, {"event_name": "merge_group"}),
                (self.envelope, {"event_name": "workflow_dispatch"}),
                (self.envelope, {"allowed": "false"}), (self.envelope, {"fork": True})):
            with self.subTest(kwargs=kwargs, receipt=receipt is not None):
                self.marker.unlink(missing_ok=True)
                code, report, _ = self.run_ci(receipt, **kwargs)
                self.assertEqual(code, 0)
                self.assertTrue(self.marker.exists())
                self.assertEqual(report["checks"][0]["execution"], "hosted")

    def test_failed_hosted_fallback_remains_a_failed_gate_input(self):
        self.check["command"] = "exit 8"
        code, report, _ = self.run_ci(None)
        self.assertEqual(code, 1)
        self.assertEqual(report["checks"][0]["exitCode"], 8)
        self.assertEqual(report["status"], "failed")

    def test_execution_profile_drops_test_filters_and_compiler_overrides(self):
        with patch.dict(os.environ, {"ONLY_TESTING": "OneTest", "SDKROOT": "/fake", "BASH_ENV": "/fake",
             "TOOLCHAINS": "fake", "DYLD_INSERT_LIBRARIES": "fake", "BICINO_SIMULATOR_UDID": "fake",
             "PYTHONPATH": "/fake", "GH_TOKEN": "private"}):
            env = local.environment()
        for key in ("ONLY_TESTING", "SDKROOT", "BASH_ENV", "TOOLCHAINS", "DYLD_INSERT_LIBRARIES",
                    "BICINO_SIMULATOR_UDID", "PYTHONPATH", "GH_TOKEN"):
            self.assertNotIn(key, env)

    def test_builds_and_linux_checks_can_never_be_eligible(self):
        checks = json.loads(runner.REGISTRY.read_text())["checks"]
        for check in checks:
            if check["component"] in ("firmware_host", "firmware_build") or check["id"] == "ios-build-containers":
                self.assertFalse(local.eligible(check), check["id"])

    def test_source_change_failed_plan_and_toolchain_change_prevent_publication(self):
        session = local.Session([], self.source)
        session.key = self.key
        session.contracts = {self.check["id"]: self.recipe}
        session.fingerprints = {False: self.toolchain}
        for status, unchanged in (("planned", True), ("failed", True), ("passed", False), ("passed", True)):
            with patch.object(local, "fingerprint", return_value={"different": True}), \
                 patch.object(local, "publish") as publish, contextlib.redirect_stdout(io.StringIO()):
                session.finish({"status": status, "sourceUnchanged": unchanged})
            publish.assert_not_called()

    def test_upload_uses_conditional_blob_update_and_data_branch_only(self):
        with patch.object(local, "read_file", return_value=(b"old", "old-blob")), \
             patch.object(local, "api") as api:
            local.publish(self.envelope)
        endpoint, method, body = api.call_args.args
        self.assertEqual(method, "PUT")
        self.assertEqual(body["branch"], local.BRANCH)
        self.assertEqual(body["sha"], "old-blob")
        self.assertNotIn(".github", endpoint)
        self.assertEqual(json.loads(base64.b64decode(body["content"])), self.envelope)


if __name__ == "__main__":
    unittest.main()
