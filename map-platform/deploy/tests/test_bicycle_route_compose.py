from pathlib import Path
import importlib.util
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[3]


class BicycleRouteComposeTests(unittest.TestCase):
    """Create a Route's bicycle legs run in the API only.

    Both locks pass the route endpoint's own limits through to the API so they
    can be tuned without a lock change, and both keep App Attest required.
    """

    _PRODUCTION = REPO_ROOT / "map-platform" / "deploy" / "compose.yaml"
    _DEVELOPMENT = REPO_ROOT / "map-platform" / "deploy" / "compose.development.yaml"
    _TUNABLE = {
        "MAP_PLATFORM_BICYCLE_ROUTE_ENABLED": "1",
        "MAP_PLATFORM_BICYCLE_ROUTE_TIMEOUT_SECONDS": "15",
        "MAP_PLATFORM_BICYCLE_ROUTE_MAX_CONCURRENT": "2",
        "MAP_PLATFORM_BICYCLE_ROUTE_MAX_SEPARATION_METERS": "150000",
        "MAP_PLATFORM_BICYCLE_ROUTE_IP_LIMIT_PER_HOUR": "480",
        "MAP_PLATFORM_BICYCLE_ROUTE_LIMIT_PER_HOUR": "240",
        "MAP_PLATFORM_BICYCLE_ROUTE_LIMIT_PER_DAY": "1200",
    }

    def _service(self, path: Path, service: str) -> str | None:
        match = re.search(
            rf"(?ms)^  {re.escape(service)}:\n(.*?)(?=^  \S|\Z)",
            path.read_text(encoding="utf-8"),
        )
        return None if match is None else match.group(0)

    def test_both_locks_pass_the_route_limits_to_the_api(self):
        for path in (self._PRODUCTION, self._DEVELOPMENT):
            api = self._service(path, "map-platform-api")
            self.assertIsNotNone(api, path.name)
            self.assertIn("MAP_PLATFORM_BICYCLE_ROUTING_UPSTREAM_URL: ", api, path.name)
            for variable, default in self._TUNABLE.items():
                self.assertIn(f"{variable}: ${{{variable}:-{default}}}\n", api, (path.name, variable))

    def test_app_attest_stays_required(self):
        production = self._service(self._PRODUCTION, "map-platform-api")
        self.assertIn("MAP_PLATFORM_BICYCLE_ROUTE_REQUIRE_APP_ATTEST: '1'\n", production)
        development = self._service(self._DEVELOPMENT, "map-platform-api")
        self.assertIn(
            "MAP_PLATFORM_BICYCLE_ROUTE_REQUIRE_APP_ATTEST: ${MAP_PLATFORM_BICYCLE_ROUTE_REQUIRE_APP_ATTEST:-1}\n",
            development,
        )

    def test_elevation_credits_name_the_graph_grading_sources(self):
        """Each lock names the sources its graph was graded with, or none.

        Development serves the planet graph graded on 2026-11-27 (3DEP and
        MRDEM-30 over Copernicus); production serves the graph without
        elevation until a graded one is promoted with its sources.
        """
        # The notices module needs only the standard library; load it by path so
        # these lock tests run without the backend package installed.
        spec = importlib.util.spec_from_file_location(
            "topography_notices",
            REPO_ROOT / "map-platform" / "backend" / "map_platform" / "topography_notices.py",
        )
        notices = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(notices)
        routing_graph_elevation_credits = notices.routing_graph_elevation_credits

        variable = "MAP_PLATFORM_BICYCLE_ROUTING_ELEVATION_SOURCES"
        development = self._service(self._DEVELOPMENT, "map-platform-api")
        match = re.search(rf"^      {variable}: \$\{{{variable}:-([^}}]*)\}}\n", development, re.MULTILINE)
        self.assertIsNotNone(match)
        sources = match.group(1).split(",")
        self.assertEqual(sources, ["usgs-3dep-13", "nrcan-mrdem-30",
                                   "copernicus-glo30-public-2021", "copernicus-glo90-2021"])
        self.assertTrue(routing_graph_elevation_credits(sources))
        production = self._service(self._PRODUCTION, "map-platform-api")
        ungraded = "/graphs/abe5e72eb5ba43b7796fb24216b0b6568058d1ba6b06ce7b9fd5c163c7dfbfd8\n"
        if ungraded in self._PRODUCTION.read_text(encoding="utf-8"):
            self.assertNotIn(variable, production)
        else:
            match = re.search(rf"^      {variable}: '?([^'\n]*)'?\n", production, re.MULTILINE)
            self.assertIsNotNone(match, "a new production graph names its elevation sources, or none")
            if match.group(1):
                self.assertTrue(routing_graph_elevation_credits(match.group(1).split(",")))

    def test_routing_settings_never_reach_worker_or_maintenance(self):
        for path in (self._PRODUCTION, self._DEVELOPMENT):
            for service in ("map-platform-worker", "map-platform-maintenance"):
                section = self._service(path, service)
                if section is None:
                    continue
                self.assertNotIn("BICYCLE_ROUTE", section, (path.name, service))


if __name__ == "__main__":
    unittest.main()
