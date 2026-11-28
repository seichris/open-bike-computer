import json
import unittest
from pathlib import Path

from map_platform.topography_notices import routing_graph_elevation_credits, topography_attribution

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
            routing_graph_elevation_credits(["sonny-dtm-europe-1s-v25"])
        with self.assertRaisesRegex(ValueError, "listed twice"):
            routing_graph_elevation_credits(["usgs-3dep-13", "usgs-3dep-13"])

    def test_terrain_credits_name_approved_routing_sources(self):
        terrain = {source["id"]: source for source in json.loads(ELEVATION_SOURCES.read_text())["terrain"]}
        usgs = terrain["usgs-3dep-13"]["attribution"]
        self.assertIn(usgs, routing_graph_elevation_credits(["usgs-3dep-13"])[0])
        self.assertIn("Open Government Licence - Canada", terrain["nrcan-mrdem-30"]["license"])


if __name__ == "__main__":
    unittest.main()
