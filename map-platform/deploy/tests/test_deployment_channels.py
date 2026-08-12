from pathlib import Path
import unittest


DEPLOY_DIR = Path(__file__).resolve().parents[1]


class DeploymentChannelComposeTests(unittest.TestCase):
    def test_production_api_uses_reviewed_channel_policy(self):
        compose = (DEPLOY_DIR / "compose.yaml").read_text(encoding="utf-8")
        api_environment = compose.split("  map-platform-worker:", 1)[0]

        self.assertIn(
            "MAP_PLATFORM_DEPLOYMENT_CHANNEL: "
            "${MAP_PLATFORM_DEPLOYMENT_CHANNEL:-production}",
            api_environment,
        )
        self.assertIn(
            "MAP_PLATFORM_GENERATION_PROFILE_POLICY: "
            "/app/config/generation-profile-policy-v1.json",
            api_environment,
        )
        self.assertIn("MAP_PLATFORM_LABEL_TARGET2_ENABLED", api_environment)
        self.assertIn("MAP_PLATFORM_BUILDING_TARGET3_ENABLED", api_environment)
        self.assertIn("MAP_PLATFORM_BUILDING_TARGET3_ALLOWLIST", api_environment)

    def test_validation_api_defaults_to_development_channel(self):
        compose = (DEPLOY_DIR / "compose.hardware-validation.yaml").read_text(
            encoding="utf-8"
        )
        api_environment = compose.split("  map-platform-worker:", 1)[0]

        self.assertIn(
            "MAP_PLATFORM_DEPLOYMENT_CHANNEL: "
            "${MAP_PLATFORM_DEPLOYMENT_CHANNEL:-development}",
            api_environment,
        )
        self.assertIn("MAP_PLATFORM_BUILDING_TARGET3_ENABLED", api_environment)


if __name__ == "__main__":
    unittest.main()
