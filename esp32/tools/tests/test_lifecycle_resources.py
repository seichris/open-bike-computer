import importlib.util
from pathlib import Path
import unittest
import tempfile
import subprocess
import sys
import json
from copy import deepcopy

spec = importlib.util.spec_from_file_location("analyzer", Path(__file__).parents[1] / "analyze_lifecycle_resources.py")
analyzer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analyzer)


def fixtures():
    events = []
    for cycle in range(1, 101):
        mode = ("map", "firmware", "diagnostics", "debug")[(cycle - 1) % 4]
        for sample, phase in enumerate(("transfer_entry", "network_ready", "owner_released"), 1):
            common = dict(bootSequence=1, firmwareFingerprint="abcdef12", attempt=cycle, sampleCount=sample)
            events.append(dict(event="transfer_checkpoint", fields=dict(common, mode=mode, phase=phase, cleanupFailed=False)))
            for pool in analyzer.POOLS:
                events.append(dict(event="transfer_resources", fields=dict(common, scope=pool, freeBytes=1000,
                    largestBytes=800, minimumFreeBytes=900, minimumLargestBytes=700)))
            events.append(dict(event="transfer_stacks", fields=dict(common, tlsStackBytes=100, ownerStackBytes=100, rendererStackBytes=100, stackAvailableMask=7)))
    return events


class TestAnalysis(unittest.TestCase):
    def test_complete_campaign_is_only_evidence_completeness(self):
        report = analyzer.analyze(fixtures())
        self.assertTrue(report["evidenceComplete"])
        self.assertEqual(report["completeCycles"], 100)
        self.assertIn("NOT ESTABLISHED", report["physicalAcceptance"])

    def test_missing_pool_and_duplicate_fail(self):
        events = fixtures()
        events.pop(1)
        self.assertFalse(analyzer.analyze(events)["evidenceComplete"])
        events = fixtures()
        events.append(events[0])
        self.assertFalse(analyzer.analyze(events)["evidenceComplete"])

    def test_failed_cleanup_and_missing_cycle_fail(self):
        events = fixtures()
        events[0]["fields"]["cleanupFailed"] = True
        self.assertFalse(analyzer.analyze(events)["evidenceComplete"])
        self.assertFalse(analyzer.analyze(fixtures()[:-15])["evidenceComplete"])

    def test_reboots_are_separate_cycles(self):
        events = fixtures()
        for event in events[750:]:
            event["fields"]["bootSequence"] = 2
            event["fields"]["attempt"] -= 50
        self.assertTrue(analyzer.analyze(events)["evidenceComplete"])

    def test_missing_stack_is_distinct_from_exhausted(self):
        events = fixtures()
        for event in events:
            if event["event"] == "transfer_stacks":
                event["fields"]["rendererStackBytes"] = 0
                event["fields"]["stackAvailableMask"] = 3
        report = analyzer.analyze(events)
        self.assertIsNone(report["stackMinimaBytes"]["rendererStackBytes"])
        events[4]["fields"]["stackAvailableMask"] = 7
        self.assertEqual(analyzer.analyze(events)["stackMinimaBytes"]["rendererStackBytes"], 0)

    def test_mixed_images_rejected(self):
        events = fixtures()
        for event in events[-15:]:
            event["fields"]["firmwareFingerprint"] = "12345678"
        self.assertFalse(analyzer.analyze(events)["evidenceComplete"])

    def test_profile_requires_all_supported_modes_without_debug(self):
        for board in ("175", "206"):
            for suffix in ("", "_PRODUCTION", "_LIFECYCLE_QUALIFICATION"):
                events = fixtures()
                for event in events:
                    if event["event"] == "transfer_checkpoint" and event["fields"]["mode"] == "debug":
                        event["fields"]["mode"] = "map"
                modes = analyzer.PROFILES[f"WAVESHARE_AMOLED_{board}{suffix}"]
                report = analyzer.analyze(events, required_modes=modes)
                self.assertTrue(report["evidenceComplete"], report["errors"])
                self.assertEqual(report["requiredModes"], ["map", "firmware", "diagnostics"])
                for missing in modes:
                    altered = deepcopy(events)
                    for event in altered:
                        if event["event"] == "transfer_checkpoint" and event["fields"]["mode"] == missing:
                            event["fields"]["mode"] = "firmware" if missing == "map" else "map"
                    self.assertFalse(analyzer.analyze(altered, required_modes=modes)["evidenceComplete"])
                self.assertFalse(analyzer.analyze(fixtures(), required_modes=modes)["evidenceComplete"])
        self.assertEqual(analyzer.PROFILES["WAVESHARE_AMOLED_206_REMOTE_DEBUG"], analyzer.MODES)

    def test_malformed_fields_fail_closed_without_exception(self):
        for malformed in (None, [], {}, {"event": []}, {"event": "transfer_stacks", "fields": None}):
            report = analyzer.analyze(fixtures() + [malformed])
            self.assertFalse(report["evidenceComplete"])
            self.assertTrue(any("record 1501:" in error for error in report["errors"]))
        for index, field, value in ((0, "attempt", []), (0, "phase", []),
                                   (0, "cleanupFailed", "false"), (1, "freeBytes", True),
                                   (4, "stackAvailableMask", 8), (4, "tlsStackBytes", -1)):
            events = fixtures()
            events[index]["fields"][field] = value
            self.assertFalse(analyzer.analyze(events)["evidenceComplete"])
        self.assertFalse(analyzer.analyze([], 0, 0)["evidenceComplete"])

    def test_cli_profile_and_invalid_json(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "events.jsonl"
            events = fixtures()
            for event in events:
                if event["event"] == "transfer_checkpoint" and event["fields"]["mode"] == "debug":
                    event["fields"]["mode"] = "map"
            path.write_text("".join(json.dumps(event) + "\n" for event in events))
            command = [sys.executable, str(Path(analyzer.__file__)), "--profile", "WAVESHARE_AMOLED_175_PRODUCTION", str(path)]
            result = subprocess.run(command, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["profile"], "WAVESHARE_AMOLED_175_PRODUCTION")
            with path.open("a") as stream:
                stream.write("{malformed\n")
            result = subprocess.run(command, text=True, capture_output=True)
            self.assertEqual(result.returncode, 1)
            report = json.loads(result.stdout)
            self.assertFalse(report["evidenceComplete"])
            self.assertTrue(any(":1501: invalid JSON" in error for error in report["errors"]))
            self.assertNotIn("Traceback", result.stderr)

    def test_actual_production_path_and_no_hot_path_recording(self):
        root = Path(__file__).parents[2]
        source = (root / "lib/device_transfer/device_transfer_http.cpp").read_text()
        for phase in ("commit_granted", "grant_released", "shutdown_requested", "transfer_entry", "owner_released"):
            self.assertIn(f'observeResources("{phase}")', source)
        self.assertIn('"lifecycle", "transfer_checkpoint", fields', source)
        self.assertIn("resourceSample_ < 64", source)
        binding = source[source.index("bool HttpTransferServer::bindResourceOperation"):source.index("HttpTransferServer::CommitGrant HttpTransferServer::beginAuthorizedCommit")]
        self.assertIn("isHttpTransferGenerationCurrent", binding)
        self.assertIn("constantTimeEqual(request.transferToken, sessionToken_)", binding)
        self.assertIn("mode_ == mode", binding)
        firmware = (root / "lib/firmware_update/firmware_update_http.cpp").read_text()
        bind = firmware.index('bindResourceOperation(request, "firmware", operationId)')
        self.assertLess(firmware.index("manifest_signature_invalid"), bind)
        self.assertLess(firmware.index('"operation_replay"'), bind)
        self.assertLess(firmware.index("pendingReceipt_ = operationRecord"), bind)
        self.assertLess(firmware.index('"ota_owner_busy"'), bind)
        renderer = (root / "lib/maps/src/maps.cpp").read_text()
        self.assertIn("renderer_diagnostics::sampleRendererStackBytes", renderer)
        self.assertIn("uxTaskGetStackHighWaterMark(nullptr)", renderer)


if __name__ == "__main__":
    unittest.main()
