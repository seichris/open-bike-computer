import json
import unittest
from pathlib import Path

from map_platform.topography_notices import (
    APP_MAXIMUM_LINE_LENGTH,
    APP_MAXIMUM_LINES,
    routing_graph_elevation_credits,
    topography_attribution,
)

ELEVATION_SOURCES = Path(__file__).resolve().parents[2] / "routing" / "elevation-sources.json"


class TopographyNoticeTests(unittest.TestCase):
    def test_both_pinned_sources_have_adapted_notices_and_liability_text(self):
        sample = {"sources": [
            {"sourceId": "copernicus-glo30-public-2021", "datasetRelease": "2021",
             "termsUrl": "https://example.test/glo30", "attributionUrl": "https://example.test/attribution"},
            {"sourceId": "copernicus-glo90-2021", "datasetRelease": "2021",
             "termsUrl": "https://example.test/glo90", "attributionUrl": "https://example.test/attribution"},
        ]}
        notice = topography_attribution(sample).decode("utf-8")
        for product in ("Copernicus WorldDEM-30", "Copernicus WorldDEM™-90"):
            self.assertIn(f"produced using {product} © DLR e.V.", notice)
            self.assertIn(f"do not incur any liability for any use of the {product}", notice)
        self.assertEqual(notice.count("Source notice: © DLR e.V."), 2)
        self.assertNotIn("not yet approved", notice)

    def test_unknown_source_or_release_cannot_get_a_public_notice(self):
        for source_id, release in (("other", "2021"),
                                   ("copernicus-glo30-public-2021", "2024")):
            with self.subTest(source_id=source_id, release=release):
                with self.assertRaisesRegex(ValueError, "no reviewed public notice"):
                    topography_attribution({"sources": [{"sourceId": source_id,
                                                          "datasetRelease": release}]})


class RoutingGraphCreditTests(unittest.TestCase):
    def test_hybrid_graph_credits_each_source_once_and_copernicus_with_its_notices(self):
        credits = routing_graph_elevation_credits(
            ["usgs-3dep-13", "nrcan-mrdem-30", "copernicus-glo30-public-2021", "copernicus-glo90-2021"])
        joined = "\n".join(credits)
        self.assertIn("Map services and data available from U.S. Geological Survey, National Geospatial Program.",
                      joined)
        self.assertIn("Contains information licensed under the Open Government Licence – Canada", joined)
        for product in ("Copernicus WorldDEM-30", "Copernicus WorldDEM™-90"):
            self.assertIn(f"Produced using {product} © DLR e.V. 2010-2014", joined)
            self.assertIn(f"do not incur any liability for any use of the {product}.", joined)
        self.assertEqual(credits[-1], "Bicino is not endorsed by the Copernicus DEM provider or programme.")
        self.assertEqual(joined.count("not endorsed"), 1)

    def test_a_graph_without_elevation_credits_nothing(self):
        self.assertEqual(routing_graph_elevation_credits([]), ())
        self.assertNotIn("Copernicus", "\n".join(routing_graph_elevation_credits(["usgs-3dep-13"])))

    def test_unknown_or_repeated_sources_are_refused(self):
        with self.assertRaisesRegex(ValueError, "no reviewed public notice"):
            routing_graph_elevation_credits(["geoscience-australia-5m"])
        with self.assertRaisesRegex(ValueError, "listed twice"):
            routing_graph_elevation_credits(["usgs-3dep-13", "usgs-3dep-13"])

    def test_every_listed_terrain_source_has_a_credit_that_fits_the_app(self):
        """A graph graded with all of them must still reach the app's Settings.

        The app drops the whole list when it has too many lines or one is too
        long, and the API refuses to start with a source it has no credit for.
        """
        listed = [source["id"] for source in json.loads(ELEVATION_SOURCES.read_text())["terrain"]]
        self.assertEqual(len(listed), 6)
        credits = routing_graph_elevation_credits(
            listed + ["copernicus-glo30-public-2021", "copernicus-glo90-2021"])
        self.assertLessEqual(len(credits), APP_MAXIMUM_LINES)
        for line in credits:
            self.assertLessEqual(len(line), APP_MAXIMUM_LINE_LENGTH, line[:60])
            self.assertEqual(line, line.strip())
        joined = "\n".join(credits)
        for licensed in ("Sonny's LiDAR Digital Terrain Models of Europe", "Toitu Te Whenua Land Information New Zealand"):
            self.assertIn(licensed, joined)
        self.assertEqual(joined.count("https://creativecommons.org/licenses/by/4.0/"), 2)
        self.assertIn("The Government of the Hong Kong Special Administrative Region is the owner of the data.", joined)
        self.assertIn("Geospatial Information Authority of Japan", joined)

    def test_app_limits_match_the_ios_app(self):
        swift = (Path(__file__).resolve().parents[3] / "ios-app" / "BikeComputer" / "BikeComputer" / "Models"
                 / "BicycleRouteService.swift").read_text()
        self.assertIn(f"static let maximumLines = {APP_MAXIMUM_LINES}\n", swift)
        self.assertIn(f"static let maximumLineLength = {APP_MAXIMUM_LINE_LENGTH}\n", swift)

    def test_terrain_credits_name_approved_routing_sources(self):
        terrain = {source["id"]: source for source in json.loads(ELEVATION_SOURCES.read_text())["terrain"]}
        usgs = terrain["usgs-3dep-13"]["attribution"]
        self.assertIn(usgs, routing_graph_elevation_credits(["usgs-3dep-13"])[0])
        self.assertIn("Open Government Licence - Canada", terrain["nrcan-mrdem-30"]["license"])


if __name__ == "__main__":
    unittest.main()
