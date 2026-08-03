import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from building_height import (
    HeightProvenance,
    HeightRules,
    parse_length_meters,
    resolve_height,
)
import yaml


class BuildingHeightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raw = yaml.safe_load((ROOT / "conf" / "building_height_rules.yaml").read_text())
        cls.rules = HeightRules.from_mapping(raw)

    def test_parses_metric_and_imperial_without_accepting_ranges(self):
        self.assertEqual(parse_length_meters("12.5 m"), 12.5)
        self.assertAlmostEqual(parse_length_meters("10' 6\""), 3.2004)
        self.assertIsNone(parse_length_meters("10-12"))
        self.assertIsNone(parse_length_meters("10;12"))
        self.assertIsNone(parse_length_meters("about ten"))

    def test_height_precedence_and_minimum_height(self):
        resolved = resolve_height(
            {
                "building": "apartments",
                "height": "21.2",
                "building:levels": "4",
                "min_height": "3 m",
            },
            self.rules,
        )
        self.assertEqual(resolved.provenance, HeightProvenance.EXPLICIT_HEIGHT)
        self.assertEqual(resolved.height_dm, 212)
        self.assertEqual(resolved.minimum_height_dm, 30)

    def test_levels_include_roof_once(self):
        resolved = resolve_height(
            {
                "building": "house",
                "building:levels": "2",
                "roof:levels": "1",
            },
            self.rules,
        )
        self.assertEqual(resolved.provenance, HeightProvenance.LEVELS)
        self.assertEqual(resolved.height_dm, 85)

    def test_parent_then_local_then_class_default(self):
        parent = resolve_height({"height": "20", "building": "office"}, self.rules)
        inherited = resolve_height(
            {"building:part": "office"}, self.rules, parent=parent, local_median=12
        )
        self.assertEqual(inherited.provenance, HeightProvenance.PARENT_INHERITANCE)
        local = resolve_height(
            {"building": "office"}, self.rules, local_median=18
        )
        self.assertEqual(local.provenance, HeightProvenance.LOCAL_OSM_MEDIAN)
        fallback = resolve_height({"building": "unknown"}, self.rules)
        self.assertEqual(fallback.provenance, HeightProvenance.CLASS_DEFAULT)


if __name__ == "__main__":
    unittest.main()
