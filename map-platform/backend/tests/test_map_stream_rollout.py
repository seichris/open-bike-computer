from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from map_platform.map_stream_rollout import (
    MapStreamPromotionApproval,
    MapStreamRolloutMode,
    MapStreamRolloutPolicy,
    load_approved_promotion_ids,
    load_approved_promotions,
    parse_map_stream_trust_capabilities,
)


INSTALLATION_A = "inst_v2_00000000000000000000000000000001"
INSTALLATION_B = "inst_v2_00000000000000000000000000000002"
CANDIDATE_SHA = "1" * 40
PRODUCER_BUILD_SHA = "6" * 64
WORKER_IMAGE_DIGEST = "sha256:" + "8" * 64
WORKER_IMAGE_REFERENCE = "registry.invalid/map-worker@" + WORKER_IMAGE_DIGEST
IOS_GIT_SHA = "9" * 40
IOS_BUILD_SHA = "a" * 64
REQUIREMENTS_SHA = "2" * 64


def approval(promotion_id: str) -> MapStreamPromotionApproval:
    return MapStreamPromotionApproval(
        promotion_id=promotion_id,
        candidate_git_sha=CANDIDATE_SHA,
        producer_build_sha256=PRODUCER_BUILD_SHA,
        worker_image_digest=WORKER_IMAGE_DIGEST,
        firmware_version="0.3.0",
        firmware_build=42,
        firmware_git_sha="7" * 40,
        ios_build="100",
        ios_git_sha=IOS_GIT_SHA,
        ios_build_sha256=IOS_BUILD_SHA,
        report_sha256="3" * 64,
        requirements_sha256=REQUIREMENTS_SHA,
        approved_signing_keys=frozenset({("map-prod-1", "4" * 64)}),
    )


class MapStreamRolloutPolicyTests(unittest.TestCase):
    def policy(
        self,
        *,
        approved_promotions: dict[str, MapStreamPromotionApproval] | None = None,
        **values: str,
    ) -> MapStreamRolloutPolicy:
        environment = {
            "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE": "disabled",
            "MAP_PLATFORM_MAP_STREAM_ROLLOUT_ALLOWLIST": "",
            "MAP_PLATFORM_MAP_STREAM_ROLLOUT_BASIS_POINTS": "0",
            "MAP_PLATFORM_MAP_STREAM_ROLLOUT_SECRET": "",
            "MAP_PLATFORM_MAP_STREAM_PROMOTION_ID": "",
            "MAP_PLATFORM_WORKER_IMAGE_REFERENCE": WORKER_IMAGE_REFERENCE,
            **values,
        }
        with patch.dict(os.environ, environment, clear=True):
            return MapStreamRolloutPolicy.from_environment(
                approved_promotions_by_id=approved_promotions,
                trusted_signing_keys={"map-prod-1": "4" * 64},
                current_requirements_sha256=REQUIREMENTS_SHA,
            )

    def test_disabled_is_the_fail_closed_default(self):
        with patch.dict(os.environ, {}, clear=True):
            policy = MapStreamRolloutPolicy.from_environment()
        self.assertEqual(policy.mode, MapStreamRolloutMode.DISABLED)
        self.assertFalse(policy.includes(INSTALLATION_A))
        self.assertFalse(policy.includes(None))
        self.assertEqual(policy.public_summary(), {"mode": "disabled"})

    def test_allowlist_is_exact_and_never_accepts_unregistered_shapes(self):
        policy = self.policy(
            MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE="allowlist",
            MAP_PLATFORM_MAP_STREAM_ROLLOUT_ALLOWLIST=INSTALLATION_A,
        )
        self.assertTrue(policy.includes(INSTALLATION_A))
        self.assertFalse(policy.includes(INSTALLATION_B))
        self.assertFalse(policy.includes("installation-owner"))
        self.assertTrue(
            policy.allows_artifact(
                INSTALLATION_A,
                "map-preproduction-1",
                "5" * 64,
                "9" * 64,
                WORKER_IMAGE_DIGEST,
                frozenset({("map-preproduction-1", "5" * 64)}),
                "101",
                IOS_GIT_SHA,
                IOS_BUILD_SHA,
            )
        )
        self.assertEqual(
            policy.public_summary(),
            {"mode": "allowlist", "allowlistCount": 1},
        )

    def test_percentage_assignment_is_stable_and_monotonic(self):
        secret = "stable-map-stream-rollout-secret-32-bytes"
        low = self.policy(
            approved_promotions={
                "msr-20260713-percentage-tests": approval(
                    "msr-20260713-percentage-tests"
                )
            },
            MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE="percentage",
            MAP_PLATFORM_MAP_STREAM_ROLLOUT_BASIS_POINTS="2500",
            MAP_PLATFORM_MAP_STREAM_ROLLOUT_SECRET=secret,
            MAP_PLATFORM_MAP_STREAM_PROMOTION_ID="msr-20260713-percentage-tests",
        )
        high = self.policy(
            approved_promotions={
                "msr-20260713-percentage-tests": approval(
                    "msr-20260713-percentage-tests"
                )
            },
            MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE="percentage",
            MAP_PLATFORM_MAP_STREAM_ROLLOUT_BASIS_POINTS="7500",
            MAP_PLATFORM_MAP_STREAM_ROLLOUT_SECRET=secret,
            MAP_PLATFORM_MAP_STREAM_PROMOTION_ID="msr-20260713-percentage-tests",
        )
        installations = [
            f"inst_v2_{index:032x}"
            for index in range(1, 257)
        ]
        first = [value for value in installations if low.includes(value)]
        second = [value for value in installations if low.includes(value)]
        expanded = [value for value in installations if high.includes(value)]
        self.assertEqual(first, second)
        self.assertTrue(first)
        self.assertTrue(set(first).issubset(expanded))
        self.assertLess(len(first), len(expanded))
        self.assertNotIn(secret, repr(low))

    def test_all_mode_requires_a_valid_registered_installation_shape(self):
        policy = self.policy(
            approved_promotions={
                "msr-20260713-all-tests": approval(
                    "msr-20260713-all-tests"
                )
            },
            MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE="all",
            MAP_PLATFORM_MAP_STREAM_PROMOTION_ID="msr-20260713-all-tests",
        )
        self.assertTrue(policy.includes(INSTALLATION_A))
        self.assertFalse(policy.includes("bad"))
        client_trust = frozenset({("map-prod-1", "4" * 64)})
        self.assertTrue(
            policy.allows_artifact(
                INSTALLATION_A,
                "map-prod-1",
                "4" * 64,
                PRODUCER_BUILD_SHA,
                WORKER_IMAGE_DIGEST,
                client_trust,
                "100",
                IOS_GIT_SHA,
                IOS_BUILD_SHA,
            )
        )
        self.assertFalse(
            policy.allows_artifact(
                INSTALLATION_A,
                "map-prod-1",
                "4" * 64,
                "9" * 64,
                WORKER_IMAGE_DIGEST,
                client_trust,
                "100",
                IOS_GIT_SHA,
                IOS_BUILD_SHA,
            )
        )
        self.assertFalse(
            policy.allows_artifact(
                INSTALLATION_A,
                "map-prod-1",
                "4" * 64,
                PRODUCER_BUILD_SHA,
                "sha256:" + "b" * 64,
                client_trust,
                "100",
                IOS_GIT_SHA,
                IOS_BUILD_SHA,
            )
        )
        self.assertFalse(
            policy.allows_artifact(
                INSTALLATION_A,
                "map-prod-1",
                "4" * 64,
                PRODUCER_BUILD_SHA,
                WORKER_IMAGE_DIGEST,
                client_trust,
                "100",
                IOS_GIT_SHA,
                "b" * 64,
            )
        )
        self.assertFalse(
            policy.allows_artifact(
                INSTALLATION_A,
                "map-prod-1",
                "4" * 64,
                PRODUCER_BUILD_SHA,
                WORKER_IMAGE_DIGEST,
                client_trust,
                "101",
                IOS_GIT_SHA,
                IOS_BUILD_SHA,
            )
        )
        self.assertEqual(
            policy.public_summary(),
            {
                "mode": "all",
                "promotionId": "msr-20260713-all-tests",
                "candidateGitSha": CANDIDATE_SHA,
                "producerBuildSha256": PRODUCER_BUILD_SHA,
                "workerImageDigest": WORKER_IMAGE_DIGEST,
                "requiredFirmwareVersion": "0.3.0",
                "requiredFirmwareBuild": 42,
                "requiredFirmwareGitSha": "7" * 40,
                "requiredIosBuild": "100",
                "requiredIosGitSha": IOS_GIT_SHA,
                "requiredIosBuildSha256": IOS_BUILD_SHA,
                "reportSha256": "3" * 64,
                "requirementsSha256": REQUIREMENTS_SHA,
                "approvedSigningKeyCount": 1,
            },
        )

    def test_post_test_approval_commit_keeps_the_tested_worker_eligible(self):
        promotion_id = "msr-20260713-post-test-approval"
        tested_approval = approval(promotion_id)
        self.assertEqual(tested_approval.candidate_git_sha, CANDIDATE_SHA)
        policy = self.policy(
            approved_promotions={promotion_id: tested_approval},
            MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE="all",
            MAP_PLATFORM_MAP_STREAM_PROMOTION_ID=promotion_id,
        )
        client_trust = frozenset({("map-prod-1", "4" * 64)})
        self.assertTrue(
            policy.allows_artifact(
                INSTALLATION_A,
                "map-prod-1",
                "4" * 64,
                PRODUCER_BUILD_SHA,
                WORKER_IMAGE_DIGEST,
                client_trust,
                "100",
                IOS_GIT_SHA,
                IOS_BUILD_SHA,
            )
        )
        self.assertFalse(
            policy.allows_artifact(
                INSTALLATION_A,
                "map-prod-1",
                "4" * 64,
                "9" * 64,
                WORKER_IMAGE_DIGEST,
                client_trust,
                "100",
                IOS_GIT_SHA,
                IOS_BUILD_SHA,
            )
        )

    def test_invalid_or_ambiguous_configuration_fails_startup(self):
        invalid = [
            {"MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE": "unknown"},
            {
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE": "allowlist",
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_ALLOWLIST": "",
            },
            {
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE": "allowlist",
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_ALLOWLIST": "bad",
            },
            {
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE": "percentage",
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_BASIS_POINTS": "2500",
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_SECRET": "short",
            },
            {
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE": "all",
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_BASIS_POINTS": "10000",
            },
            {
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE": "disabled",
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_SECRET": (
                    "unused-map-stream-rollout-secret-32-bytes"
                ),
            },
        ]
        for values in invalid:
            with self.subTest(values=values):
                with self.assertRaises(ValueError):
                    self.policy(**values)

        with self.assertRaisesRegex(ValueError, "not approved"):
            self.policy(
                MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE="all",
                MAP_PLATFORM_MAP_STREAM_PROMOTION_ID="msr-20260713-unapproved",
            )

        promotion_id = "msr-20260713-bound-candidate"

        with self.assertRaisesRegex(ValueError, "absent from production trust"):
            with patch.dict(
                os.environ,
                {
                    "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE": "all",
                    "MAP_PLATFORM_MAP_STREAM_ROLLOUT_ALLOWLIST": "",
                    "MAP_PLATFORM_MAP_STREAM_ROLLOUT_BASIS_POINTS": "0",
                    "MAP_PLATFORM_MAP_STREAM_ROLLOUT_SECRET": "",
                    "MAP_PLATFORM_MAP_STREAM_PROMOTION_ID": promotion_id,
                    "MAP_PLATFORM_WORKER_IMAGE_REFERENCE": WORKER_IMAGE_REFERENCE,
                },
                clear=True,
            ):
                MapStreamRolloutPolicy.from_environment(
                    approved_promotions_by_id={promotion_id: approval(promotion_id)},
                    trusted_signing_keys={},
                    current_requirements_sha256=REQUIREMENTS_SHA,
                )

        with self.assertRaisesRegex(ValueError, "absent from production trust"):
            with patch.dict(
                os.environ,
                {
                    "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE": "all",
                    "MAP_PLATFORM_MAP_STREAM_ROLLOUT_ALLOWLIST": "",
                    "MAP_PLATFORM_MAP_STREAM_ROLLOUT_BASIS_POINTS": "0",
                    "MAP_PLATFORM_MAP_STREAM_ROLLOUT_SECRET": "",
                    "MAP_PLATFORM_MAP_STREAM_PROMOTION_ID": promotion_id,
                    "MAP_PLATFORM_WORKER_IMAGE_REFERENCE": WORKER_IMAGE_REFERENCE,
                },
                clear=True,
            ):
                MapStreamRolloutPolicy.from_environment(
                    approved_promotions_by_id={promotion_id: approval(promotion_id)},
                    trusted_signing_keys={"map-prod-1": "5" * 64},
                    current_requirements_sha256=REQUIREMENTS_SHA,
                )

        with self.assertRaisesRegex(ValueError, "requirements do not match"):
            with patch.dict(
                os.environ,
                {
                    "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE": "all",
                    "MAP_PLATFORM_MAP_STREAM_ROLLOUT_ALLOWLIST": "",
                    "MAP_PLATFORM_MAP_STREAM_ROLLOUT_BASIS_POINTS": "0",
                    "MAP_PLATFORM_MAP_STREAM_ROLLOUT_SECRET": "",
                    "MAP_PLATFORM_MAP_STREAM_PROMOTION_ID": promotion_id,
                    "MAP_PLATFORM_WORKER_IMAGE_REFERENCE": WORKER_IMAGE_REFERENCE,
                },
                clear=True,
            ):
                MapStreamRolloutPolicy.from_environment(
                    approved_promotions_by_id={promotion_id: approval(promotion_id)},
                    trusted_signing_keys={"map-prod-1": "4" * 64},
                    current_requirements_sha256="5" * 64,
                )

        for image_reference in (
            "registry.invalid/map-worker:latest",
            "registry.invalid/map-worker@sha256:" + "b" * 64,
        ):
            with self.subTest(image_reference=image_reference), self.assertRaisesRegex(
                ValueError,
                "approved digest-pinned worker image",
            ):
                self.policy(
                    approved_promotions={promotion_id: approval(promotion_id)},
                    MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE="all",
                    MAP_PLATFORM_MAP_STREAM_PROMOTION_ID=promotion_id,
                    MAP_PLATFORM_WORKER_IMAGE_REFERENCE=image_reference,
                )

    def test_committed_approval_registry_is_strict_and_secret_free(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "approvals.json"
            path.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "approvals": [
                            {
                                "promotionId": "msr-20260713-hardware-a",
                                "candidateGitSha": "1" * 40,
                                "producerBuildSha256": "6" * 64,
                                "workerImageDigest": WORKER_IMAGE_DIGEST,
                                "firmwareVersion": "0.3.0",
                                "firmwareBuild": 42,
                                "firmwareGitSha": "7" * 40,
                                "iosBuild": "100",
                                "iosGitSha": IOS_GIT_SHA,
                                "iosBuildSha256": IOS_BUILD_SHA,
                                "reportSha256": "2" * 64,
                                "requirementsSha256": "3" * 64,
                                "approvedAt": "2026-07-13T00:00:00Z",
                                "approvedBy": "release-owner",
                                "targets": [
                                    "WAVESHARE_AMOLED_175",
                                    "WAVESHARE_AMOLED_206",
                                ],
                                "signingKeys": [
                                    {
                                        "keyId": "map-prod-2026-01",
                                        "publicKeySha256": "4" * 64,
                                    }
                                ],
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            self.assertEqual(
                load_approved_promotion_ids(path),
                frozenset({"msr-20260713-hardware-a"}),
            )
            self.assertEqual(
                load_approved_promotions(path)[
                    "msr-20260713-hardware-a"
                ].approved_signing_keys,
                frozenset({("map-prod-2026-01", "4" * 64)}),
            )

            document = json.loads(path.read_text(encoding="utf-8"))
            oversized_build = json.loads(json.dumps(document))
            oversized_build["approvals"][0]["firmwareBuild"] = 4_294_967_296
            path.write_text(json.dumps(oversized_build), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "firmware build identity"):
                load_approved_promotions(path)
            path.write_text(
                json.dumps({"schemaVersion": True, "approvals": []}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "unsupported schema"):
                load_approved_promotions(path)
            path.write_text(json.dumps(document), encoding="utf-8")
            document["approvals"][0]["rolloutSecret"] = "must-not-be-committed"
            path.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "invalid fields"):
                load_approved_promotion_ids(path)

            path.write_text(
                '{"schemaVersion":1,"schemaVersion":1,"approvals":[]}',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "duplicate JSON object key"):
                load_approved_promotions(path)

            fixture_document = {
                "schemaVersion": 1,
                "approvals": [
                    {
                        "promotionId": "msr-20260713-fixture-key",
                        "candidateGitSha": "1" * 40,
                        "producerBuildSha256": "6" * 64,
                        "workerImageDigest": WORKER_IMAGE_DIGEST,
                        "firmwareVersion": "0.3.0",
                        "firmwareBuild": 42,
                        "firmwareGitSha": "7" * 40,
                        "iosBuild": "100",
                        "iosGitSha": IOS_GIT_SHA,
                        "iosBuildSha256": IOS_BUILD_SHA,
                        "reportSha256": "2" * 64,
                        "requirementsSha256": "3" * 64,
                        "approvedAt": "2026-07-13T00:00:00Z",
                        "approvedBy": "release-owner",
                        "targets": [
                            "WAVESHARE_AMOLED_175",
                            "WAVESHARE_AMOLED_206",
                        ],
                        "signingKeys": [
                            {
                                "keyId": "map-test-2026-01",
                                "publicKeySha256": "4" * 64,
                            }
                        ],
                    }
                ],
            }
            path.write_text(json.dumps(fixture_document), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "invalid signing keys"):
                load_approved_promotions(path)

    def test_client_trust_capability_parser_is_strict(self):
        value = f"map-prod-1={'4' * 64},map-prod-2={'5' * 64}"
        self.assertEqual(
            parse_map_stream_trust_capabilities(value),
            frozenset(
                {
                    ("map-prod-1", "4" * 64),
                    ("map-prod-2", "5" * 64),
                }
            ),
        )
        for invalid in (
            "map-prod-1",
            f"map-test-2026-01={'4' * 64}",
            f"map-prod-1={'4' * 63}",
            f"map-prod-1={'4' * 64},map-prod-1={'4' * 64}",
        ):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                parse_map_stream_trust_capabilities(invalid)


if __name__ == "__main__":
    unittest.main()
