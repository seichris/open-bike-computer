from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[3]


class StravaComposeTests(unittest.TestCase):
    _COMPOSE_FILES = (
        REPO_ROOT / "map-platform" / "backend" / "docker-compose.yml",
        REPO_ROOT / "map-platform" / "deploy" / "compose.yaml",
        REPO_ROOT / "map-platform" / "deploy" / "compose.hardware-validation.yaml",
    )
    _SHARED_VARIABLES = (
        "MAP_PLATFORM_STRAVA_ENABLED",
        "MAP_PLATFORM_STRAVA_CLIENT_ID",
        "MAP_PLATFORM_STRAVA_CLIENT_SECRET",
        "MAP_PLATFORM_STRAVA_REDIRECT_URI",
        "MAP_PLATFORM_STRAVA_TOKEN_KEY_ID",
        "MAP_PLATFORM_STRAVA_TOKEN_KEY_BASE64",
        "MAP_PLATFORM_STRAVA_PREVIOUS_TOKEN_KEYS",
        "MAP_PLATFORM_STRAVA_CONNECTION_IDLE_TTL_DAYS",
    )
    _API_ONLY_VARIABLES = (
        "MAP_PLATFORM_STRAVA_OAUTH_START_LIMIT_PER_HOUR",
        "MAP_PLATFORM_STRAVA_ROUTE_IMPORT_LIMIT_PER_HOUR",
        "MAP_PLATFORM_STRAVA_ROUTE_VALIDATION_LIMIT_PER_HOUR",
        "MAP_PLATFORM_STRAVA_DISCONNECT_LIMIT_PER_HOUR",
    )

    def _service(self, compose: str, service: str) -> str:
        match = re.search(
            rf"(?ms)^  {re.escape(service)}:\n(.*?)(?=^  \S|\Z)",
            compose,
        )
        self.assertIsNotNone(match, service)
        return match.group(0)

    def test_api_and_maintenance_receive_required_strava_configuration(self):
        for path in self._COMPOSE_FILES:
            compose = path.read_text(encoding="utf-8")
            api = self._service(compose, "map-platform-api")
            maintenance = self._service(compose, "map-platform-maintenance")
            for variable in self._SHARED_VARIABLES:
                self.assertIn(variable, api, (path.name, "api", variable))
                self.assertIn(variable, maintenance, (path.name, "maintenance", variable))
            for variable in self._API_ONLY_VARIABLES:
                self.assertIn(variable, api, (path.name, "api", variable))
                self.assertNotIn(variable, maintenance, (path.name, "maintenance", variable))

    def test_worker_never_receives_strava_credentials_or_tokens(self):
        for path in self._COMPOSE_FILES:
            compose = path.read_text(encoding="utf-8")
            worker = self._service(compose, "map-platform-worker")
            for variable in self._SHARED_VARIABLES + self._API_ONLY_VARIABLES:
                self.assertNotIn(variable, worker, (path.name, variable))

    def test_strava_is_disabled_by_default(self):
        for path in self._COMPOSE_FILES:
            compose = path.read_text(encoding="utf-8")
            for service in ("map-platform-api", "map-platform-maintenance"):
                section = self._service(compose, service)
                self.assertIn(
                    "MAP_PLATFORM_STRAVA_ENABLED: ${MAP_PLATFORM_STRAVA_ENABLED:-0}",
                    section,
                    (path.name, service),
                )


if __name__ == "__main__":
    unittest.main()
