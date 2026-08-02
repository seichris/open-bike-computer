import pathlib
import unittest


DEPLOY_DIR = pathlib.Path(__file__).resolve().parents[1]


class HardwareValidationComposeTests(unittest.TestCase):
    def test_validation_stack_requires_one_candidate_image(self):
        compose = (DEPLOY_DIR / "compose.hardware-validation.yaml").read_text(
            encoding="utf-8"
        )

        self.assertIn(
            "${MAP_PLATFORM_VALIDATION_IMAGE:?set MAP_PLATFORM_VALIDATION_IMAGE "
            "to an immutable ghcr.io image digest}",
            compose,
        )
        self.assertEqual(compose.count("image: *map-platform-image"), 3)
        self.assertNotIn("ghcr.io/seichris/open-bike-computer-map-platform@sha256:", compose)

    def test_validation_stack_is_isolated_and_fail_closed(self):
        compose = (DEPLOY_DIR / "compose.hardware-validation.yaml").read_text(
            encoding="utf-8"
        )

        self.assertIn("map-platform-validation-data:/data", compose)
        self.assertIn("MAP_PLATFORM_ARTIFACT_STORE: filesystem", compose)
        self.assertIn(
            "MAP_PLATFORM_MAP_STREAM_ENABLED: ${MAP_PLATFORM_MAP_STREAM_ENABLED:-0}",
            compose,
        )
        self.assertIn(
            "MAP_PLATFORM_LABEL_TARGET2_ENABLED: "
            "${MAP_PLATFORM_LABEL_TARGET2_ENABLED:-0}",
            compose,
        )
        self.assertIn(
            "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE: "
            "${MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE:-disabled}",
            compose,
        )


if __name__ == "__main__":
    unittest.main()
