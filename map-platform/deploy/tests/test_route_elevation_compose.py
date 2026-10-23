from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[3]


class RouteElevationComposeTests(unittest.TestCase):
    """The Geoapify key is an API-only server secret.

    The production and development locks auto-deploy when they change, so
    their route-elevation passthrough lands with the reviewed image promotion
    (see docs/route-elevation-profile.md); this checks what exists today.
    """

    _LOCAL_COMPOSE = REPO_ROOT / "map-platform" / "backend" / "docker-compose.yml"
    _COMPOSE_FILES = (
        _LOCAL_COMPOSE,
        REPO_ROOT / "map-platform" / "deploy" / "compose.yaml",
        REPO_ROOT / "map-platform" / "deploy" / "compose.development.yaml",
        REPO_ROOT / "map-platform" / "deploy" / "compose.hardware-validation.yaml",
    )
    _API_VARIABLES = (
        "MAP_PLATFORM_ROUTE_ELEVATION_ENABLED",
        "MAP_PLATFORM_ROUTE_ELEVATION_PROVIDERS",
        "MAP_PLATFORM_GEOAPIFY_API_KEY",
        "MAP_PLATFORM_GEOAPIFY_DAILY_CREDIT_BUDGET",
        "MAP_PLATFORM_GEOAPIFY_TIMEOUT_SECONDS",
        "MAP_PLATFORM_GEOAPIFY_REQUESTS_PER_SECOND",
        "MAP_PLATFORM_ROUTE_ELEVATION_INSTALLATION_DAILY_CREDITS",
        "MAP_PLATFORM_ROUTE_ELEVATION_DEM_ENABLED",
        "MAP_PLATFORM_ROUTE_ELEVATION_DEM_CACHE",
        "MAP_PLATFORM_ROUTE_ELEVATION_STRUCTURE_INDEX_DIR",
        "MAP_PLATFORM_ROUTE_ELEVATION_MAX_CONCURRENT",
        "MAP_PLATFORM_ROUTE_ELEVATION_DEADLINE_SECONDS",
        "MAP_PLATFORM_ROUTE_ELEVATION_REQUIRE_APP_ATTEST",
        "MAP_PLATFORM_ROUTE_ELEVATION_IP_LIMIT_PER_HOUR",
        "MAP_PLATFORM_ROUTE_ELEVATION_LIMIT_PER_HOUR",
        "MAP_PLATFORM_ROUTE_ELEVATION_LIMIT_PER_DAY",
    )

    def _service(self, compose: str, service: str) -> str | None:
        match = re.search(
            rf"(?ms)^  {re.escape(service)}:\n(.*?)(?=^  \S|\Z)",
            compose,
        )
        return None if match is None else match.group(0)

    def test_local_api_receives_route_elevation_configuration(self):
        api = self._service(self._LOCAL_COMPOSE.read_text(encoding="utf-8"), "map-platform-api")
        self.assertIsNotNone(api)
        for variable in self._API_VARIABLES:
            self.assertIn(f"{variable}: ${{{variable}:-", api, variable)

    def test_hosted_terrain_and_dem_are_inert_by_default(self):
        api = self._service(self._LOCAL_COMPOSE.read_text(encoding="utf-8"), "map-platform-api")
        self.assertIn("MAP_PLATFORM_GEOAPIFY_API_KEY: ${MAP_PLATFORM_GEOAPIFY_API_KEY:-}\n", api)
        self.assertIn(
            "MAP_PLATFORM_ROUTE_ELEVATION_DEM_ENABLED: ${MAP_PLATFORM_ROUTE_ELEVATION_DEM_ENABLED:-0}\n", api
        )
        self.assertIn(
            "MAP_PLATFORM_ROUTE_ELEVATION_REQUIRE_APP_ATTEST: ${MAP_PLATFORM_ROUTE_ELEVATION_REQUIRE_APP_ATTEST:-1}\n",
            api,
        )

    def test_provider_secret_never_reaches_worker_or_maintenance(self):
        for path in self._COMPOSE_FILES:
            compose = path.read_text(encoding="utf-8")
            for service in ("map-platform-worker", "map-platform-maintenance"):
                section = self._service(compose, service)
                if section is None:
                    continue
                self.assertNotIn("GEOAPIFY", section, (path.name, service))
                self.assertNotIn("ROUTE_ELEVATION", section, (path.name, service))


if __name__ == "__main__":
    unittest.main()
