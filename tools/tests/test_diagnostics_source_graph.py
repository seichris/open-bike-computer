"""Check each Swift compiler invocation, not mere file presence in a script.

A script may build several independent modules. PR #553 added live diagnostics
references to BLEManager but omitted their sources from the Catalyst preview
module, even though the first compiler invocation already included them.
"""
from pathlib import Path
import re
import json
import importlib.util
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
PREFIX = "ios-app/BikeComputer/BikeComputer/"
SPEC = importlib.util.spec_from_file_location(
    "swift_compile", ROOT / "tools/development/swift_compile.py")
swift_compile = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(swift_compile)



class DiagnosticsSourceGraphTests(unittest.TestCase):
    def test_every_ble_harness_has_its_diagnostics_dependencies(self):
        checked = 0
        groups = json.loads((ROOT / "tools/development/swift-sources.json").read_text())["groups"]
        for path in (ROOT / "ios-app/scripts").glob("*.sh"):
            # Join shell continuations so each compiler command is inspected
            # independently; do not let another module hide a missing source.
            commands = path.read_text().replace("\\\n", " ").splitlines()
            for command in commands:
                sources = set(re.findall(r"ios-app/[^\s\\\"]+\.swift", command))
                registered = re.search(r'\$\{DEV_SWIFT_COMPILER\}"\s+([a-z0-9-]+)', command)
                if registered:
                    sources.update(swift_compile.sources(registered[1], groups))
                if PREFIX + "Managers/BLEManager.swift" not in sources:
                    continue
                checked += 1
                for relative in (
                    "Managers/DeviceDiagnosticsTransferManager.swift",
                    "Managers/DiagnosticsAcquisitionStore.swift",
                    "Utilities/RideDiagnostics.swift",
                    "Utilities/DiagnosticsSchema.generated.swift",
                    "Utilities/DiagnosticsCapturePolicy.swift",
                ):
                    self.assertIn(PREFIX + relative, sources,
                                  f"{path.name}: BLE module missing {relative}")
        self.assertGreaterEqual(checked, 3)

    def test_every_recorder_harness_has_acquisition_evidence_types(self):
        groups = json.loads((ROOT / "tools/development/swift-sources.json").read_text())["groups"]
        checked = 0
        for path in (ROOT / "ios-app/scripts").glob("*.sh"):
            commands = path.read_text().replace("\\\n", " ").splitlines()
            for command in commands:
                sources = set(re.findall(r"ios-app/[^\s\\\"]+\.swift", command))
                registered = re.search(r'\$\{DEV_SWIFT_COMPILER\}"\s+([a-z0-9-]+)', command)
                if registered:
                    sources.update(swift_compile.sources(registered[1], groups))
                if PREFIX + "Utilities/RideDiagnostics.swift" not in sources:
                    continue
                checked += 1
                self.assertIn(PREFIX + "Managers/DiagnosticsAcquisitionStore.swift", sources,
                              f"{path.name}: recorder module missing acquisition evidence types")
        self.assertGreaterEqual(checked, 4)

    def test_policy_forwarding_is_explicit_and_phone_collection_does_not_use_radio(self):
        app = (ROOT / PREFIX / "BikeComputerApp.swift").read_text()
        self.assertNotIn("rideDiagnosticsRecorder.$runtimeCapturePolicy", app)
        client = (ROOT / PREFIX / "Managers/DiagnosticsBrokerClient.swift").read_text()
        collect = client.split('case "collect":', 1)[1].split('case "export":', 1)[0]
        self.assertIn("guard command.requiresFirmware else", collect)
        self.assertLess(collect.index("guard command.requiresFirmware else"), collect.index("collector.start()"))
        stop = client.split('case "stop_capture":', 1)[1].split('case "mark":', 1)[0]
        self.assertIn('"device_policy_not_queued"', stop)
        self.assertNotIn("_ = bleManager.sendDiagnosticsCapturePolicy", stop)
        coordinator = (ROOT / PREFIX / "Managers/DiagnosticsCollectionCoordinator.swift").read_text()
        self.assertIn("guard restoreFinished, !restoreFailed", coordinator)
        self.assertIn("generation == operationGeneration", coordinator)
        self.assertIn("cancelled: Task.isCancelled && userCancelled", coordinator)
        self.assertIn('"ride_started"', coordinator)
        self.assertIn("DiagnosticsPostRideJournal.enqueue", coordinator)
        self.assertRegex(coordinator,
                         r"DiagnosticsPostRideJournal\.Request\(id:\s*\$0\.requestID,\s*"
                         r"captureID:\s*\$0\.captureID,\s*deviceDigest:\s*\$0\.deviceDigest\)")
        self.assertLess(app.index("observeRide(active: state.current)"), app.index("rideDiagnosticsRecorder?.endRideCapture()"))
        self.assertIn("$0.canResumeAutomatically(postRideEnabled: automaticPostRideCollection) && $0.deviceDigest == digest", coordinator)

    def test_resume_rereads_committed_state_and_runs_after_cleanup(self):
        app = (ROOT / PREFIX / "BikeComputerApp.swift").read_text()
        readiness = app.split("bleManager.$isNavigationReady.removeDuplicates()", 1)[1].split(".store(in:", 1)[0]
        self.assertLess(readiness.index(".receive(on: DispatchQueue.main)"), readiness.index(".sink"))
        coordinator = (ROOT / PREFIX / "Managers/DiagnosticsCollectionCoordinator.swift").read_text()
        ended = coordinator.split("rideIsActive = false\n", 2)[-1].split("let preceding = rideJournalTask", 1)[0]
        self.assertIn("Task { [weak self] in self?.resumeIfPossible() }", ended)
        self.assertLess(ended.index("self?.resumeIfPossible()"), ended.index("guard !contexts.isEmpty"))
        task = coordinator.split("task = Task { [weak self] in", 1)[1]
        cleanup = task.split("defer {", 1)[1].split("\n            }", 1)[0]
        self.assertLess(cleanup.index("isRunning = false"), cleanup.index("resumeIfPossible()"))
        self.assertLess(cleanup.index("task = nil"), cleanup.index("resumeIfPossible()"))

    def test_fast_ci_local_scripts_resolve_from_effective_directory(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text())
        job = workflow["jobs"]["ios-fast"]
        checks = {c["id"]: c for c in json.loads(
            (ROOT / "tools/development/checks.json").read_text())["checks"]}
        default = job.get("defaults", {}).get("run", {}).get("working-directory", ".")
        checked = 0
        for step in job["steps"]:
            command = step.get("run", "")
            directory = step.get("working-directory", default)
            registered = re.search(r"--check ([a-z0-9-]+)", command)
            if registered:
                check = checks[registered[1]]
                command = check["command"]
                directory = check.get("cwd", ".")
            for script in re.findall(r"(?:^|\s)(\./scripts/[A-Za-z0-9_-]+\.sh)", command):
                self.assertTrue((ROOT / directory / script).is_file(),
                                f"{step['name']}: {script} does not exist from {directory}")
                checked += 1
        self.assertGreaterEqual(checked, 8)


if __name__ == "__main__":
    unittest.main()
