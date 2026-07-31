from __future__ import annotations

import json
import hashlib
import tempfile
import unittest
from pathlib import Path

from tools.check_map_stream_hardware_gate import (
    approval_record,
    load_requirements,
    validate_report,
    validate_report_bytes,
)
from map_platform.map_stream_hardware_requirements import (
    HardwareRequirementsDocument,
    parse_hardware_requirements,
)
from map_platform.strict_json import loads_strict_json


class MapStreamHardwareGateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def write_report(self, report: dict) -> Path:
        path = Path(self.tmp.name) / "report.json"
        path.write_text(json.dumps(report, sort_keys=True), encoding="utf-8")
        return path

    def trusted_keys(self) -> dict[str, str]:
        return {"map-prod-2026-01": "5" * 64}

    def requirements(self) -> dict:
        return {
            "schemaVersion": 1,
            "targets": ["WAVESHARE_AMOLED_206"],
            "scenarios": {"shanghai_clean_install": 1},
            "boundedResumeScenarios": [],
            "exactSingleWriteScenarios": ["shanghai_clean_install"],
            "requiredRetrySkipScenarios": [],
            "legacyCompatibility": {
                "oldApp": {"iosBuild": "1", "iosGitSha": "a" * 40},
                "oldFirmware": {
                    "version": "0.2.4",
                    "build": 88,
                    "gitSha": "b" * 40,
                },
            },
            "requiredAssertions": [
                "durablePrefixNotRewritten",
                "finalStateCorrect",
                "previousMapRecoverable",
                "singlePayloadHash",
                "singlePayloadWrite",
                "uiResponsive",
            ],
            "requiredMetrics": [
                "durableBytesRewritten",
                "maxTemperatureC",
                "payloadBytes",
                "payloadBytesWritten",
                "retryBytesSkipped",
                "step1Seconds",
                "step2Seconds",
                "step3Seconds",
            ],
            "minimumShanghaiPostTransferReductionPercent": 25,
            "minimumShanghaiSdWriteReductionPercent": 25,
            "maximumResumeWriteAmplificationBytes": 2_097_152,
            "maximumShanghaiTemperatureRegressionC": 2,
            "maximumTemperatureCByTarget": {
                "WAVESHARE_AMOLED_206": 65,
            },
        }

    def valid_report(self) -> dict:
        return {
            "schemaVersion": 1,
            "candidate": {
                "gitSha": "1" * 40,
                "producerBuildSha256": "6" * 64,
                "workerImageDigest": "sha256:" + "c" * 64,
                "firmwareVersion": "0.3.0",
                "firmwareBuild": 42,
                "firmwareGitSha": "7" * 40,
                "iosBuild": "100",
                "iosGitSha": "d" * 40,
                "iosBuildSha256": "e" * 64,
                "signingKeys": [
                    {
                        "keyId": "map-prod-2026-01",
                        "publicKeySha256": "5" * 64,
                    }
                ],
            },
            "runs": [
                {
                    "target": "WAVESHARE_AMOLED_206",
                    "scenario": "shanghai_clean_install",
                    "repetition": 1,
                    "recordedAt": "2026-07-13T00:00:00Z",
                    "passed": True,
                    "observed": {
                        "iosBuild": "100",
                        "iosGitSha": "d" * 40,
                        "iosBuildSha256": "e" * 64,
                        "firmwareVersion": "0.3.0",
                        "firmwareBuild": 42,
                        "firmwareGitSha": "7" * 40,
                        "artifactFormat": "bike-map-stream-v1",
                        "artifactSha256": "8" * 64,
                        "producerBuildSha256": "6" * 64,
                        "producerImageDigest": "sha256:" + "c" * 64,
                        "signatureKeyId": "map-prod-2026-01",
                        "signatureKeySha256": "5" * 64,
                        "signedManifestReceipt": "9" * 64,
                    },
                    "metrics": {
                        "durableBytesRewritten": 0,
                        "maxTemperatureC": 48,
                        "payloadBytes": 1000,
                        "payloadBytesWritten": 1000,
                        "retryBytesSkipped": 0,
                        "step1Seconds": 100,
                        "step2Seconds": 10,
                        "step3Seconds": 5,
                        "v1MaxTemperatureC": 50,
                        "v1PayloadBytesWritten": 2500,
                        "v1PostTransferSeconds": 60,
                    },
                    "assertions": {
                        "durablePrefixNotRewritten": True,
                        "finalStateCorrect": True,
                        "previousMapRecoverable": True,
                        "singlePayloadHash": True,
                        "singlePayloadWrite": True,
                        "uiResponsive": True,
                    },
                    "notes": "bench run",
                }
            ],
            "approval": {
                "approved": True,
                "approvedAt": "2026-07-13T01:00:00Z",
                "approvedBy": "release-owner",
                "notes": "all required runs reviewed",
            },
        }

    def test_checked_in_requirements_are_complete_and_valid(self):
        requirements = load_requirements()
        self.assertEqual(
            requirements["targets"],
            ["WAVESHARE_AMOLED_175", "WAVESHARE_AMOLED_206"],
        )
        self.assertEqual(requirements["scenarios"]["shanghai_clean_install"], 3)
        self.assertIn("power_loss_pointer_transaction", requirements["scenarios"])
        self.assertIn("old_app_new_firmware", requirements["scenarios"])
        self.assertIn(
            "wifi_interruption_90_percent",
            requirements["requiredRetrySkipScenarios"],
        )

    def test_requirements_reject_boolean_schema_and_unbounded_repetitions(self):
        boolean_schema = self.requirements()
        boolean_schema["schemaVersion"] = True
        excessive_repetitions = self.requirements()
        excessive_repetitions["scenarios"]["shanghai_clean_install"] = 11
        for document in (boolean_schema, excessive_repetitions):
            with self.subTest(document=document):
                with self.assertRaises(ValueError):
                    parse_hardware_requirements(
                        json.dumps(document).encode("utf-8")
                    )

    def test_hostile_depth_and_numeric_overflow_are_controlled_rejections(self):
        deeply_nested = "[" * 10_000 + "0" + "]" * 10_000
        with self.assertRaisesRegex(ValueError, "unreadable|nesting"):
            loads_strict_json(
                deeply_nested,
                description="hostile hardware report",
            )

        requirements = load_requirements()
        requirements["maximumShanghaiTemperatureRegressionC"] = 10**400
        with self.assertRaisesRegex(ValueError, "finite"):
            parse_hardware_requirements(json.dumps(requirements).encode("utf-8"))

        report = self.valid_report()
        report["runs"][0]["metrics"]["maxTemperatureC"] = 10**400
        with self.assertRaisesRegex(ValueError, "valid range"):
            validate_report(
                self.write_report(report),
                self.requirements(),
                self.trusted_keys(),
            )

    def test_passing_report_emits_a_hash_bound_promotion_record(self):
        path = self.write_report(self.valid_report())
        report_bytes = path.read_bytes()
        report = validate_report(
            path,
            self.requirements(),
            self.trusted_keys(),
        )
        approval = approval_record(
            report_bytes,
            report,
            "msr-20260713-hardware-pass",
            HardwareRequirementsDocument(
                values=self.requirements(),
                sha256="4" * 64,
            ),
            {"map-prod-2026-01": "5" * 64},
        )
        self.assertEqual(approval["candidateGitSha"], "1" * 40)
        self.assertEqual(approval["producerBuildSha256"], "6" * 64)
        self.assertEqual(approval["workerImageDigest"], "sha256:" + "c" * 64)
        self.assertEqual(len(approval["reportSha256"]), 64)
        self.assertEqual(approval["requirementsSha256"], "4" * 64)
        self.assertEqual(approval["firmwareVersion"], "0.3.0")
        self.assertEqual(approval["firmwareBuild"], 42)
        self.assertEqual(approval["firmwareGitSha"], "7" * 40)
        self.assertEqual(approval["iosBuild"], "100")
        self.assertEqual(approval["iosGitSha"], "d" * 40)
        self.assertEqual(approval["iosBuildSha256"], "e" * 64)
        self.assertEqual(
            approval["signingKeys"],
            [
                {
                    "keyId": "map-prod-2026-01",
                    "publicKeySha256": "5" * 64,
                }
            ],
        )

    def test_gate_rejects_untrusted_keys_failures_and_measurement_regressions(self):
        cases = []

        unapproved = self.valid_report()
        unapproved["approval"]["approved"] = False
        cases.append((unapproved, self.trusted_keys()))

        overheated = self.valid_report()
        overheated["runs"][0]["metrics"]["maxTemperatureC"] = 70
        cases.append((overheated, self.trusted_keys()))

        amplified = self.valid_report()
        amplified["runs"][0]["metrics"]["payloadBytesWritten"] = 1001
        cases.append((amplified, self.trusted_keys()))

        slow = self.valid_report()
        slow["runs"][0]["metrics"]["step2Seconds"] = 50
        cases.append((slow, self.trusted_keys()))

        cases.append((self.valid_report(), {}))

        for report, trust in cases:
            with self.subTest(report=report, trust=trust):
                with self.assertRaises(ValueError):
                    validate_report(
                        self.write_report(report),
                        self.requirements(),
                        trust,
                    )

    def test_gate_uses_independent_thermal_limit_and_exact_repetitions(self):
        overheated = self.valid_report()
        overheated["runs"][0]["metrics"]["maxTemperatureC"] = 66
        with self.assertRaisesRegex(ValueError, "thermal limit"):
            validate_report(
                self.write_report(overheated),
                self.requirements(),
                self.trusted_keys(),
            )

    def test_resume_metrics_are_integer_typed_and_bounded_by_scenario(self):
        requirements = self.requirements()
        requirements["scenarios"] = {"wifi_interruption_90_percent": 1}
        requirements["boundedResumeScenarios"] = ["wifi_interruption_90_percent"]
        requirements["requiredRetrySkipScenarios"] = ["wifi_interruption_90_percent"]
        report = self.valid_report()
        run = report["runs"][0]
        run["scenario"] = "wifi_interruption_90_percent"
        for field in (
            "v1MaxTemperatureC",
            "v1PayloadBytesWritten",
            "v1PostTransferSeconds",
        ):
            del run["metrics"][field]
        run["metrics"]["payloadBytesWritten"] = 1000 + 2_097_152
        run["metrics"]["retryBytesSkipped"] = 900
        validate_report(
            self.write_report(report),
            requirements,
            self.trusted_keys(),
        )

        huge_write = json.loads(json.dumps(report))
        huge_write["runs"][0]["metrics"]["payloadBytesWritten"] += 1
        fractional_bytes = json.loads(json.dumps(report))
        fractional_bytes["runs"][0]["metrics"]["payloadBytes"] = 1000.5
        huge_payload = json.loads(json.dumps(report))
        huge_payload["runs"][0]["metrics"]["payloadBytes"] = 512 * 1024 * 1024 + 1
        huge_payload["runs"][0]["metrics"]["payloadBytesWritten"] = (
            512 * 1024 * 1024 + 1
        )
        no_skip = json.loads(json.dumps(report))
        no_skip["runs"][0]["metrics"]["retryBytesSkipped"] = 0
        for invalid in (huge_write, fractional_bytes, huge_payload, no_skip):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                validate_report(
                    self.write_report(invalid),
                    requirements,
                    self.trusted_keys(),
                )

    def test_compatibility_runs_bind_the_exact_old_and_new_sides(self):
        cases = (
            (
                "old_app_new_firmware",
                {
                    "iosBuild": "1",
                    "iosGitSha": "a" * 40,
                    "iosBuildSha256": None,
                    "firmwareVersion": "0.3.0",
                    "firmwareBuild": 42,
                    "firmwareGitSha": "7" * 40,
                },
            ),
            (
                "new_app_old_firmware",
                {
                    "iosBuild": "100",
                    "iosGitSha": "d" * 40,
                    "iosBuildSha256": "e" * 64,
                    "firmwareVersion": "0.2.4",
                    "firmwareBuild": 88,
                    "firmwareGitSha": "b" * 40,
                },
            ),
        )
        for scenario, identity in cases:
            requirements = self.requirements()
            requirements["scenarios"] = {
                "shanghai_clean_install": 1,
                scenario: 1,
            }
            report = self.valid_report()
            run = json.loads(json.dumps(report["runs"][0]))
            report["runs"].append(run)
            run["scenario"] = scenario
            for field in (
                "v1MaxTemperatureC",
                "v1PayloadBytesWritten",
                "v1PostTransferSeconds",
            ):
                del run["metrics"][field]
            run["observed"].update(identity)
            run["observed"].update(
                {
                    "artifactFormat": "zip-stored-v1",
                    "producerBuildSha256": None,
                    "producerImageDigest": None,
                    "signatureKeyId": None,
                    "signatureKeySha256": None,
                    "signedManifestReceipt": None,
                }
            )
            with self.subTest(scenario=scenario):
                validate_report(
                    self.write_report(report),
                    requirements,
                    self.trusted_keys(),
                )

                wrong_side = json.loads(json.dumps(report))
                wrong_side["runs"][-1]["observed"]["iosBuild"] = "100"
                wrong_side["runs"][-1]["observed"]["iosGitSha"] = "d" * 40
                wrong_side["runs"][-1]["observed"]["iosBuildSha256"] = "e" * 64
                if scenario == "new_app_old_firmware":
                    wrong_side["runs"][-1]["observed"].update(
                        {
                            "firmwareVersion": "0.3.0",
                            "firmwareBuild": 42,
                            "firmwareGitSha": "7" * 40,
                        }
                    )
                with self.assertRaises(ValueError):
                    validate_report(
                        self.write_report(wrong_side),
                        requirements,
                        self.trusted_keys(),
                    )

    def test_every_noncompatibility_run_binds_the_candidate_artifact(self):
        substituted = self.valid_report()
        substituted["runs"][0]["observed"]["producerBuildSha256"] = "a" * 64
        with self.assertRaisesRegex(ValueError, "candidate stream artifact"):
            validate_report(
                self.write_report(substituted),
                self.requirements(),
                self.trusted_keys(),
            )

    def test_every_approved_signing_key_is_exercised_and_all_writes_are_bounded(self):
        unexercised_key = self.valid_report()
        unexercised_key["candidate"]["signingKeys"].append(
            {
                "keyId": "map-prod-2026-02",
                "publicKeySha256": "f" * 64,
            }
        )
        with self.assertRaisesRegex(ValueError, "did not exercise signing key"):
            validate_report(
                self.write_report(unexercised_key),
                self.requirements(),
                {**self.trusted_keys(), "map-prod-2026-02": "f" * 64},
            )

        requirements = self.requirements()
        requirements["scenarios"] = {"display_off_upload": 1}
        report = self.valid_report()
        report["runs"][0]["scenario"] = "display_off_upload"
        for field in (
            "v1MaxTemperatureC",
            "v1PayloadBytesWritten",
            "v1PostTransferSeconds",
        ):
            del report["runs"][0]["metrics"][field]
        report["runs"][0]["metrics"]["payloadBytesWritten"] = 4_294_967_296
        with self.assertRaisesRegex(ValueError, "write-amplification"):
            validate_report(
                self.write_report(report),
                requirements,
                self.trusted_keys(),
            )

    def test_firmware_build_identity_is_bounded_to_the_wire_uint32(self):
        report = self.valid_report()
        report["candidate"]["firmwareBuild"] = 4_294_967_296
        report["runs"][0]["observed"]["firmwareBuild"] = 4_294_967_296
        with self.assertRaisesRegex(ValueError, "firmware identity"):
            validate_report(
                self.write_report(report),
                self.requirements(),
                self.trusted_keys(),
            )

        wrong_repetition = self.valid_report()
        wrong_repetition["runs"][0]["repetition"] = 2
        with self.assertRaisesRegex(ValueError, "exactly cover"):
            validate_report(
                self.write_report(wrong_repetition),
                self.requirements(),
                self.trusted_keys(),
            )

    def test_report_is_parsed_and_hashed_from_the_same_bytes(self):
        path = self.write_report(self.valid_report())
        validated_bytes = path.read_bytes()
        report = validate_report_bytes(
            validated_bytes,
            self.requirements(),
            self.trusted_keys(),
        )
        path.write_text('{"schemaVersion": 0}', encoding="utf-8")
        approval = approval_record(
            validated_bytes,
            report,
            "msr-20260713-same-report-bytes",
            HardwareRequirementsDocument(
                values=self.requirements(),
                sha256="4" * 64,
            ),
            {"map-prod-2026-01": "5" * 64},
        )
        self.assertEqual(
            approval["reportSha256"],
            hashlib.sha256(validated_bytes).hexdigest(),
        )

    def test_approval_must_follow_every_recorded_run(self):
        report = self.valid_report()
        report["approval"]["approvedAt"] = "2026-07-12T23:59:59Z"
        with self.assertRaisesRegex(ValueError, "does not follow"):
            validate_report(
                self.write_report(report),
                self.requirements(),
                self.trusted_keys(),
            )

        report = self.valid_report()
        report["approval"]["approvedAt"] = report["runs"][0]["recordedAt"]
        with self.assertRaisesRegex(ValueError, "does not follow"):
            validate_report(
                self.write_report(report),
                self.requirements(),
                self.trusted_keys(),
            )

    def test_report_and_approval_bind_exact_signing_key_material(self):
        substituted = self.valid_report()
        substituted["candidate"]["signingKeys"][0][
            "publicKeySha256"
        ] = "6" * 64
        with self.assertRaisesRegex(ValueError, "signing material"):
            validate_report(
                self.write_report(substituted),
                self.requirements(),
                self.trusted_keys(),
            )

        path = self.write_report(self.valid_report())
        report_bytes = path.read_bytes()
        report = validate_report(
            path,
            self.requirements(),
            self.trusted_keys(),
        )
        with self.assertRaisesRegex(ValueError, "signing material"):
            approval_record(
                report_bytes,
                report,
                "msr-20260713-key-substitution",
                HardwareRequirementsDocument(
                    values=self.requirements(),
                    sha256="4" * 64,
                ),
                {"map-prod-2026-01": "6" * 64},
            )

    def test_duplicate_report_keys_are_rejected(self):
        duplicate = (
            b'{"schemaVersion":1,"schemaVersion":1,'
            b'"candidate":{},"runs":[],"approval":{}}'
        )
        with self.assertRaisesRegex(ValueError, "duplicate JSON object key"):
            validate_report_bytes(
                duplicate,
                self.requirements(),
                self.trusted_keys(),
            )


if __name__ == "__main__":
    unittest.main()
