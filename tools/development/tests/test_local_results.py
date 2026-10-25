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
        untrusted = Path(cls.keys.name) / "untrusted"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(untrusted)], check=True)
        cls.untrusted_public = " ".join(untrusted.with_suffix(".pub").read_text().split()[:2])

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
        policy = {**self.policy, "publicKeys": [self.untrusted_public]}
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

    def run_ci(self, receipt, *, event_name="pull_request", allowed="true", fork=False, transport_error=False,
               consumer_source=None, after_source=None, tracked_entries=None, fingerprint_error=None,
               prerequisite_reasons=None):
        event = {"repository": {"full_name": local.REPOSITORY}, "pull_request": {
            "base": {"sha": "d" * 40}, "head": {"sha": self.source["commit"],
            "repo": {"full_name": "fork/repo" if fork else local.REPOSITORY}}}}
        event_path = self.root / "event.json"
        event_path.write_text(json.dumps(event))
        seen = []
        def read(path, ref, **kwargs):
            seen.append((path, ref))
            if transport_error:
                raise RuntimeError("GitHub evidence transport unavailable")
            if path == local.POLICY:
                return local.canonical(self.policy), "policy-blob"
            return None if receipt is None else (receipt if isinstance(receipt, bytes) else local.canonical(receipt), "receipt-blob")
        real_command = local.command
        def command(args, **kwargs):
            if args == ["git", "ls-files", "-v"] and tracked_entries is not None:
                return tracked_entries
            return real_command(args, **kwargs)
        report = self.root / "report.json"
        before = self.source if consumer_source is None else consumer_source
        identities = [before, before if after_source is None else after_source]
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "CI": "true",
             "GITHUB_EVENT_NAME": event_name, "LOCAL_RESULTS_ALLOWED": allowed,
             "GITHUB_EVENT_PATH": str(event_path)}), \
             patch.object(runner, "source_identity", side_effect=identities), \
             patch.object(runner, "prerequisites", return_value=prerequisite_reasons or []), \
             patch.object(local, "command", side_effect=command), \
             patch.object(local, "read_file", side_effect=read), \
             patch.object(local, "fingerprint", return_value=self.toolchain, side_effect=fingerprint_error), \
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
        metrics = json.loads((self.root / "report-reuse-metrics.json").read_text())
        row = metrics["observations"][0]
        self.assertEqual((row["eligible"], row["attempted"], row["outcome"], row["reason"]), (True, True, "accepted", "accepted"))
        self.assertEqual(row["estimatedAvoidedExecutionMs"], 9000)
        self.assertIsNone(row["fallbackDurationMs"])
        self.assertGreater(row["verificationMs"], 0)
        self.assertGreater(metrics["initializationMs"], 0)
        self.assertNotIn("Actual local test output", json.dumps(metrics))
        self.assertNotIn("signature", json.dumps(metrics))
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
                row = json.loads((self.root / "report-reuse-metrics.json").read_text())["observations"][0]
                self.assertTrue(row["eligible"])
                self.assertNotEqual(row["outcome"], "accepted")
                self.assertEqual(row["estimatedAvoidedExecutionMs"], 0)
                self.assertGreaterEqual(row["fallbackDurationMs"], 0)

    def test_failed_hosted_fallback_remains_a_failed_gate_input(self):
        self.check["command"] = "exit 8"
        code, report, _ = self.run_ci(None)
        self.assertEqual(code, 1)
        self.assertEqual(report["checks"][0]["exitCode"], 8)
        self.assertEqual(report["status"], "failed")

    def test_runner_falls_back_for_source_recipe_runtime_and_stale_receipts(self):
        cases = {
            "head": {"source": {**self.source, "commit": "e" * 40}},
            "merge tree": {"source": {**self.source, "tree": "e" * 40}},
            "dirty producer": {"source": {**self.source, "dirty": True}},
            "producer changed": {"sourceUnchanged": False},
            "command filter": {"recipe": {**self.recipe, "check": {**self.check, "command": "true"}}},
            "source graph metadata": {"recipe": {**self.recipe, "check": {**self.check, "ciInputs": {"swiftGroups": ["different"]}}}},
            "verifier": {"recipe": {**self.recipe, "verifierSha256": "different"}},
            "runtime build": {"toolchain": {**self.toolchain, "simulators": {"ios": {"build": "different"}}}},
            "stale": {"startedAt": self.now - 3601},
            "failed": {"status": "failed", "exitCode": 1},
            "skipped": {"status": "skipped"},
        }
        for label, changes in cases.items():
            with self.subTest(label=label):
                self.marker.unlink(missing_ok=True)
                code, report, _ = self.run_ci(local.sign({**self.payload, **changes}, self.key))
                self.assertEqual(code, 0)
                self.assertTrue(self.marker.exists())
                self.assertEqual(report["checks"][0]["execution"], "hosted")

    def test_dirty_sparse_and_assume_unchanged_consumers_execute_normally(self):
        for options in ({"consumer_source": {**self.source, "dirty": True}},
                        {"consumer_source": {**self.source, "tree": "e" * 40}},
                        {"tracked_entries": "h ios-app/source.swift"},
                        {"tracked_entries": "S ios-app/source.swift"}):
            with self.subTest(options=options):
                self.marker.unlink(missing_ok=True)
                code, report, _ = self.run_ci(self.envelope, **options)
                self.assertEqual(code, 0)
                self.assertTrue(self.marker.exists())
                self.assertEqual(report["checks"][0]["execution"], "hosted")

    def test_malformed_oversized_and_untrusted_receipts_execute_the_fallback(self):
        for receipt in (b"not json", b"[" * 2000 + b"]" * 2000,
                        {**self.envelope, "padding": "x" * local.MAX_ENVELOPE}):
            self.marker.unlink(missing_ok=True)
            code, report, _ = self.run_ci(receipt)
            self.assertEqual(code, 0)
            self.assertTrue(self.marker.exists())
            self.assertEqual(report["checks"][0]["execution"], "hosted")
        # A key from the receipt/PR cannot override the base policy returned by read_file.
        self.policy = {**self.policy, "publicKeys": [self.untrusted_public]}
        self.marker.unlink()
        code, report, seen = self.run_ci(self.envelope)
        self.assertEqual(code, 0)
        self.assertTrue(self.marker.exists())
        self.assertEqual(report["checks"][0]["execution"], "hosted")
        self.assertEqual(seen[0], (local.POLICY, "d" * 40))

    def test_fingerprint_inventory_race_is_a_miss_and_failed_fallback_stays_failed(self):
        # selected_type can return a runtime absent from the preceding inventory.
        self.check["command"] = "exit 8"
        for error in (StopIteration(), subprocess.TimeoutExpired("xcrun", 120)):
            with self.subTest(error=type(error).__name__):
                code, report, _ = self.run_ci(self.envelope, fingerprint_error=error)
                self.assertEqual(code, 1)
                self.assertEqual(report["checks"][0]["exitCode"], 8)
                self.assertEqual(report["checks"][0]["execution"], "hosted")

    def test_blocked_prerequisite_and_changed_checkout_cannot_become_green(self):
        code, report, seen = self.run_ci(self.envelope, prerequisite_reasons=["fixture tool unavailable"])
        self.assertEqual(code, 1)
        self.assertEqual(report["checks"][0]["status"], "blocked")
        self.assertFalse(self.marker.exists())
        self.assertEqual(seen, [(local.POLICY, "d" * 40)])
        code, report, _ = self.run_ci(self.envelope, after_source={**self.source, "dirty": True})
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "failed")
        self.assertFalse(report["sourceUnchanged"])

    def test_receipt_miss_executes_the_normalized_profile_without_test_filters(self):
        self.check["command"] = 'test -z "${ONLY_TESTING:-}${BASH_ENV:-}${SDKROOT:-}${PYTHONPATH:-}"'
        with patch.dict(os.environ, {"ONLY_TESTING": "OneTest", "BASH_ENV": "/nonexistent",
                                     "SDKROOT": "/fake-sdk", "PYTHONPATH": "/fake-imports"}):
            code, report, _ = self.run_ci(None)
        self.assertEqual(code, 0)
        self.assertEqual(report["checks"][0]["execution"], "hosted")

    def test_initialization_misses_cannot_turn_a_full_failure_into_a_filtered_pass(self):
        # Mirrors run-workout-platform-tests.sh honoring ONLY_TESTING. The full
        # command fails, while a narrowed subset would incorrectly pass.
        self.check["command"] = 'if test -n "${ONLY_TESTING:-}"; then exit 0; else exit 8; fi'
        for options in ({}, {"transport_error": True}, {"fingerprint_error": StopIteration()},
                        {"consumer_source": {**self.source, "dirty": True}},
                        {"tracked_entries": "S ios-app/source.swift"},
                        {"event_name": "workflow_dispatch"}, {"allowed": "false"}, {"fork": True}):
            with self.subTest(options=options), patch.dict(os.environ, {"ONLY_TESTING": "OneTest"}):
                code, report, _ = self.run_ci(None, **options)
                self.assertEqual(code, 1)
                self.assertEqual(report["checks"][0]["exitCode"], 8)
                self.assertEqual(report["status"], "failed")

    def test_transport_size_bound_rejects_before_decoding(self):
        with patch.object(local, "api", return_value={"type": "file", "encoding": "base64",
                "size": local.MAX_ENVELOPE + 1, "content": "", "sha": "fixture"}):
            with self.assertRaisesRegex(ValueError, "oversized"):
                local.read_file("results/fixture", local.BRANCH)

    def test_metrics_categories_come_from_real_signed_validation(self):
        cases = [("source-mismatch", {"source": {**self.source, "tree": "c" * 40}}),
                 ("recipe-mismatch", {"recipe": {**self.recipe, "fresh": True}}),
                 ("toolchain-mismatch", {"toolchain": {**self.toolchain, "sdk": "other"}}),
                 ("dependencies-mismatch", {"toolchain": {**self.toolchain, "python": {"packages": ["different"]}}}),
                 ("stale-or-invalid-time", {"startedAt": self.now - 3601})]
        for reason, changes in cases:
            with self.subTest(reason=reason):
                self.run_ci(local.sign({**self.payload, **changes}, self.key))
                row = json.loads((self.root / "report-reuse-metrics.json").read_text())["observations"][0]
                self.assertEqual(row["reason"], reason)
                self.assertTrue(row["attempted"])
                self.assertTrue(self.marker.exists())
        altered = copy.deepcopy(self.envelope)
        altered["payload"]["exitCode"] = 8
        self.run_ci(altered)
        row = json.loads((self.root / "report-reuse-metrics.json").read_text())["observations"][0]
        self.assertEqual(row["reason"], "signature-invalid")

    def test_telemetry_collection_and_write_failures_do_not_change_gates(self):
        with patch.object(local.metrics.ReuseMetrics, "start", side_effect=RuntimeError("private")), \
             patch.object(local.metrics.ReuseMetrics, "write", side_effect=OSError("private")):
            code, report, _ = self.run_ci(self.envelope)
            self.assertEqual(code, 0)
            self.assertEqual(report["checks"][0]["execution"], "reused-local")
            self.assertFalse(self.marker.exists())
            self.check["command"] = "exit 8"
            code, report, _ = self.run_ci(None)
            self.assertEqual(code, 1)
            self.assertEqual(report["checks"][0]["exitCode"], 8)

    def test_metrics_distinguish_disabled_and_policy_ineligible_from_absence(self):
        with patch.dict(os.environ, {"CI": "1", "GITHUB_ACTIONS": "", "GITHUB_EVENT_PATH": ""}):
            session = local.Session([], self.source, reuse=False)
            self.assertEqual(session.metrics.report["context"], "ci-mode")
            self.assertEqual(session.observation(self.check)["reason"], "disabled")
            session.reuse = True
            session.policy = {**self.policy, "checks": []}
            self.assertEqual(session.observation(self.check)["reason"], "policy-ineligible")
            session.metric_hosted = False
            self.assertEqual(session.observation(self.check)["reason"], "local-execution")

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
