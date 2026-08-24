import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from map_platform.generation_profiles import (
    GenerationProfilePolicy,
    configured_deployment_channel,
)


class GenerationProfilePolicyTests(unittest.TestCase):
    def setUp(self):
        self.repo_root = Path(__file__).resolve().parents[3]
        self.policy_path = (
            self.repo_root
            / "map-platform"
            / "config"
            / "generation-profile-policy-v1.json"
        )

    def test_checked_in_channels_are_explicit_and_ordered_by_format(self):
        policy = GenerationProfilePolicy.load(self.policy_path)

        self.assertEqual(
            [
                profile.renderer_format_version
                for profile in policy.available_profiles("development")
            ],
            [3, 2, 1],
        )
        self.assertEqual(
            [
                profile.renderer_format_version
                for profile in policy.available_profiles("production")
            ],
            [3, 2, 1],
        )
        self.assertEqual(
            [
                profile.renderer_format_version
                for profile in policy.available_profiles(
                    "production",
                    canary_profile_ids=frozenset({"buildings-3d-v1"}),
                )
            ],
            [3, 2, 1],
        )

    def test_invalid_or_ambiguous_policy_fails_closed(self):
        payload = json.loads(self.policy_path.read_text(encoding="utf-8"))
        payload["channels"]["production"]["globalProfiles"].append(
            "buildings-3d-v1"
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "policy.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "production is invalid"):
                GenerationProfilePolicy.load(path)

    def test_deployment_channel_is_strict(self):
        with patch.dict(os.environ, {"MAP_PLATFORM_DEPLOYMENT_CHANNEL": "DEV"}):
            with self.assertRaisesRegex(ValueError, "development or production"):
                configured_deployment_channel()

    def test_duplicate_json_keys_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "policy.json"
            path.write_text(
                '{"schemaVersion":1,"schemaVersion":1}',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "duplicate JSON object key"):
                GenerationProfilePolicy.load(path)

    def test_unknown_fields_and_missing_formats_fail_at_startup(self):
        payload = json.loads(self.policy_path.read_text(encoding="utf-8"))
        payload["deploymentChanel"] = "development"
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "unknown-field.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "fields are invalid"):
                GenerationProfilePolicy.load(path)

            payload.pop("deploymentChanel")
            payload["profiles"] = [
                profile
                for profile in payload["profiles"]
                if profile["rendererFormatVersion"] != 3
            ]
            for channel in payload["channels"].values():
                channel["globalProfiles"] = [
                    profile_id
                    for profile_id in channel["globalProfiles"]
                    if profile_id != "buildings-3d-v1"
                ]
                channel["canaryProfiles"] = [
                    profile_id
                    for profile_id in channel["canaryProfiles"]
                    if profile_id != "buildings-3d-v1"
                ]
            path = Path(tmp) / "missing-format.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "requires renderer formats"):
                GenerationProfilePolicy.load(path)


if __name__ == "__main__":
    unittest.main()
