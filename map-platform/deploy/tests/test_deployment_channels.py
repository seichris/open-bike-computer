from pathlib import Path
import re
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

    def test_production_worker_has_an_explicit_chunk_memory_ceiling(self):
        compose = (DEPLOY_DIR / "compose.yaml").read_text(encoding="utf-8")
        worker_environment = compose.split("  map-platform-worker:", 1)[1].split(
            "  map-platform-maintenance:", 1
        )[0]

        self.assertIn(
            "mem_limit: ${MAP_PLATFORM_WORKER_MEMORY_LIMIT:-12g}",
            worker_environment,
        )
        self.assertIn("MAP_PLATFORM_WORKER_MEMORY_LIMIT_BYTES", worker_environment)

    def test_catalog_maintenance_has_bounded_network_batches(self):
        for filename in ("compose.yaml", "compose.hardware-validation.yaml"):
            compose = (DEPLOY_DIR / filename).read_text(encoding="utf-8")
            maintenance = compose.split("  map-platform-maintenance:", 1)[1]
            self.assertIn(
                "MAP_PLATFORM_CATALOG_PUBLICATION_RETRY_BATCH: "
                "${MAP_PLATFORM_CATALOG_PUBLICATION_RETRY_BATCH:-4}",
                maintenance,
            )
            self.assertIn(
                "MAP_PLATFORM_CATALOG_RETENTION_BATCH: "
                "${MAP_PLATFORM_CATALOG_RETENTION_BATCH:-5}",
                maintenance,
            )
        self.assertNotIn(
            "MAP_PLATFORM_CATALOG_REQUIRED_IOS_",
            (DEPLOY_DIR / "compose.yaml").read_text(encoding="utf-8"),
        )


class PreparationEstimateComposeTests(unittest.TestCase):
    _SERVICES = (
        "map-platform-api",
        "map-platform-worker",
        "map-platform-maintenance",
    )
    _VARIABLES = (
        "MAP_PLATFORM_PREPARATION_ESTIMATES_MODE",
        "MAP_PLATFORM_PREPARATION_ESTIMATE_MODEL_PATH",
        "MAP_PLATFORM_ESTIMATOR_WORKER_CLASS",
        "MAP_PLATFORM_ESTIMATOR_WORKER_CONCURRENCY_CLASS",
        "MAP_PLATFORM_ESTIMATE_MIN_HISTORY_SAMPLES",
        "MAP_PLATFORM_ESTIMATE_HIGH_CONFIDENCE_SAMPLES",
        "MAP_PLATFORM_ESTIMATE_VALIDATED_CONFIDENCE",
        "MAP_PLATFORM_ESTIMATE_MAX_REVISIONS_PER_JOB",
        "MAP_PLATFORM_ESTIMATE_MIN_UPDATE_SECONDS",
        "MAP_PLATFORM_ESTIMATE_MATERIAL_CHANGE_BPS",
        "MAP_PLATFORM_ESTIMATE_MAX_SECONDS",
    )

    def _service_section(self, compose: str, service: str) -> str:
        match = re.search(
            rf"(?ms)^  {re.escape(service)}:\n(.*?)(?=^  \S|\Z)", compose
        )
        self.assertIsNotNone(match, service)
        return match.group(0)

    def test_all_deployment_services_receive_estimator_configuration(self):
        for filename in (
            "compose.yaml",
            "compose.hardware-validation.yaml",
        ):
            compose = (DEPLOY_DIR / filename).read_text(encoding="utf-8")
            for service in self._SERVICES:
                section = self._service_section(compose, service)
                for variable in self._VARIABLES:
                    self.assertIn(variable, section, (filename, service, variable))

    def test_production_and_validation_defaults_keep_estimates_off(self):
        for filename in (
            "compose.yaml",
            "compose.hardware-validation.yaml",
        ):
            compose = (DEPLOY_DIR / filename).read_text(encoding="utf-8")
            for service in self._SERVICES:
                section = self._service_section(compose, service)
                self.assertIn(
                    "MAP_PLATFORM_PREPARATION_ESTIMATES_MODE: "
                    "${MAP_PLATFORM_PREPARATION_ESTIMATES_MODE:-off}",
                    section,
                )

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
