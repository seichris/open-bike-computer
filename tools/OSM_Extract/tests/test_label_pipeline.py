import pathlib
import sys
import unittest

from shapely import LineString


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from label_pipeline import (
    extract_label_tags,
    generate_candidates,
    join_named_roads,
    label_variants,
    normalize_language_tag,
    normalize_label_text,
    normalize_preferred_languages,
    prepare_road_labels,
)


class LabelPipelineTests(unittest.TestCase):
    def test_label_tags_preserve_names_localizations_and_ref(self):
        tags = extract_label_tags(
            {"name": " 皇后大道東 ", "ref": "H1"},
            {
                "name:zh_hant": "皇后大道東",
                "name:en": "Queen's Road East",
                "int_name": "Queens Road East",
            },
        )

        self.assertEqual(tags["name"], "皇后大道東")
        self.assertEqual(tags["name:zh-Hant"], "皇后大道東")
        self.assertEqual(tags["name:en"], "Queen's Road East")
        self.assertEqual(tags["int_name"], "Queens Road East")
        self.assertEqual(tags["ref"], "H1")

    def test_invalid_control_and_oversized_labels_are_rejected(self):
        self.assertIsNone(normalize_label_text("bad\u202ename"))
        self.assertIsNone(normalize_label_text("x" * 256))
        self.assertEqual(normalize_label_text(" Cafe\u0301 "), "Café")

    def test_language_tags_are_canonical_and_bounded(self):
        self.assertEqual(normalize_language_tag("ZH_hant_hk"), "zh-Hant-HK")
        self.assertEqual(
            normalize_preferred_languages(["en-US", "en_us", "zh-Hant"]),
            ("en-US", "zh-Hant"),
        )
        with self.assertRaises(ValueError):
            normalize_preferred_languages(["en", "zh", "ja", "ko"])

    def test_variant_order_is_local_preferred_international_ref(self):
        variants = label_variants(
            {
                "name": "皇后大道東",
                "name:en": "Queen's Road East",
                "int_name": "Queens Road East",
                "ref": "H1",
            },
            preferred_languages=["en-GB"],
            international_fallback="en",
        )

        self.assertEqual(
            [(item.kind, item.language, item.text) for item in variants],
            [
                ("local", None, "皇后大道東"),
                ("preferred", "en-GB", "Queen's Road East"),
                ("international", "en", "Queen's Road East"),
                ("ref", None, "H1"),
            ],
        )

    def test_candidates_reject_tight_bends_and_are_deterministic(self):
        straight = LineString([(0, 0), (500, 0)])
        variants = label_variants({"name": "Long Straight Road"})

        first = generate_candidates(straight, variants, rank=1)
        second = generate_candidates(straight, variants, rank=1)

        self.assertEqual(first, second)
        self.assertGreaterEqual(len(first), 2)
        self.assertTrue(all(item["start"][1] == 0 for item in first))

        bend = LineString([(0, 0), (30, 0), (30, 30)])
        self.assertEqual(generate_candidates(bend, variants, rank=1), [])

    def test_compatible_named_fragments_join_before_candidate_generation(self):
        base = {
            "type": "highway.residential",
            "geom_type": "line",
            "label_tags": {"name": "Test Street"},
            "label_join": {"layer": "0"},
            "z_order": 0,
        }
        features = [
            {**base, "id": "2", "geom": LineString([(50, 0), (100, 0)])},
            {**base, "id": "1", "geom": LineString([(0, 0), (50, 0)])},
        ]

        joined = join_named_roads(features)
        prepared = prepare_road_labels(joined, preferred_languages=["en"])

        self.assertEqual(len(prepared), 1)
        self.assertAlmostEqual(prepared[0]["geom"].length, 100)
        self.assertEqual(prepared[0]["type_id"], 7)
        self.assertTrue(prepared[0]["label_candidates"])

    def test_diagnostics_are_aggregate_and_do_not_include_street_text(self):
        diagnostics = {}
        tags = extract_label_tags(
            {"name": "Test Street"},
            {"name:bad!": "ignored", "int_name": "bad\u202ename"},
            diagnostics=diagnostics,
        )
        features = [{
            "type": "highway.residential",
            "geom_type": "line",
            "label_tags": tags,
            "label_join": {},
            "z_order": 0,
            "id": "1",
            "geom": LineString([(0, 0), (300, 0)]),
        }]
        joined = join_named_roads(features, diagnostics=diagnostics)
        prepared = prepare_road_labels(joined, diagnostics=diagnostics)

        self.assertEqual(diagnostics["namedRoadsRead"], 1)
        self.assertEqual(diagnostics["namedRoadsJoined"], 1)
        self.assertGreater(diagnostics["candidatesByRoadRank"]["3"], 0)
        self.assertGreater(
            diagnostics["candidatesByRoadClass"]["highway.residential"], 0
        )
        self.assertGreater(diagnostics["candidatesByZoomBand"]["0-3"], 0)
        self.assertEqual(diagnostics["rejectedText"]["invalidLanguageTag"], 1)
        self.assertEqual(diagnostics["rejectedText"]["unsafeControl"], 1)
        self.assertNotIn("Test Street", repr(diagnostics))
        self.assertTrue(prepared[0]["label_candidates"])


if __name__ == "__main__":
    unittest.main()
