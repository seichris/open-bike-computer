from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[3]


class StravaComposeTests(unittest.TestCase):
    _COMPOSE_FILES = (
        REPO_ROOT / "map-platform" / "backend" / "docker-compose.yml",
        REPO_ROOT / "map-platform" / "deploy" / "compose.yaml",
        REPO_ROOT / "map-platform" / "deploy" / "compose.development.yaml",
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
        "MAP_PLATFORM_STRAVA_ROUTE_LIST_LIMIT_PER_HOUR",
        "MAP_PLATFORM_STRAVA_ROUTE_VALIDATION_LIMIT_PER_HOUR",
        "MAP_PLATFORM_STRAVA_DISCONNECT_LIMIT_PER_HOUR",
    )

    _MASK = "${BICINO_STRAVA_MASK:-}"
    _COOLIFY_MANIFESTS = {"compose.yaml", "compose.development.yaml"}
    _BRIDGE_VARIABLES = (
        "MAP_PLATFORM_STRAVA_DEVELOPMENT_BRIDGE_SECRET",
        "MAP_PLATFORM_STRAVA_DEVELOPMENT_INSTALLATION",
        "MAP_PLATFORM_STRAVA_DEVELOPMENT_ATHLETE",
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

    def test_development_bridge_configuration_is_scoped_to_the_apis(self):
        bridge, installation, athlete = self._BRIDGE_VARIABLES
        for path in self._COMPOSE_FILES:
            compose = path.read_text(encoding="utf-8")
            api = self._service(compose, "map-platform-api")
            if path.name in self._COOLIFY_MANIFESTS:
                self.assertIn(bridge, api)
                self.assertIn(installation, api)
                maintenance = self._service(compose, "map-platform-maintenance")
                for variable in self._BRIDGE_VARIABLES:
                    self.assertIn(f"{variable}: {self._MASK}", maintenance)
            else:
                for service in (api, self._service(compose, "map-platform-maintenance")):
                    for variable in self._BRIDGE_VARIABLES:
                        self.assertNotIn(variable, service)
            if path.name == "compose.yaml":
                self.assertIn(f"{athlete}: ${{{athlete}:-}}", api)
            elif path.name == "compose.development.yaml":
                self.assertIn(f"{athlete}: {self._MASK}", api)
            else:
                self.assertNotIn(athlete, api)
            worker = self._service(compose, "map-platform-worker")
            for variable in self._BRIDGE_VARIABLES:
                self.assertNotIn(variable, worker, (path.name, variable))

    def test_coolify_env_file_cannot_supply_strava_credentials_to_other_services(self):
        for path in self._COMPOSE_FILES:
            if path.name not in self._COOLIFY_MANIFESTS:
                continue
            compose = path.read_text(encoding="utf-8")
            start = compose.index("x-strava-disabled: &strava-disabled\n")
            overrides = compose[start:compose.index("\n\n", start)]
            self.assertIn("MAP_PLATFORM_STRAVA_ENABLED: '0'", overrides)
            for variable in self._SHARED_VARIABLES[1:-1] + self._BRIDGE_VARIABLES:
                self.assertIn(f"{variable}: {self._MASK}", overrides)
            worker = self._service(compose, "map-platform-worker")
            self.assertIn("<<: *strava-disabled", worker)
            if path.name == "compose.yaml":
                promotion = self._service(compose, "map-platform-promotion")
                valhalla = self._service(compose, "map-platform-valhalla")
                self.assertIn("<<: *strava-disabled", promotion)
                self.assertIn("environment: *strava-disabled", valhalla)

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
