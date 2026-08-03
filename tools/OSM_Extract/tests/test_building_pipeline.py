import pathlib
import sys
import unittest

from shapely.geometry import box, mapping, Polygon
import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from building_height import HeightRules
from building_pipeline import clip_buildings, prepare_buildings


def feature(identifier, geometry, other_tags):
    return {
        "type": "Feature",
        "properties": {
            "osm_way_id": identifier,
            "building": "yes",
            "other_tags": other_tags,
        },
        "geometry": mapping(geometry),
    }


class BuildingPipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raw = yaml.safe_load((ROOT / "conf" / "building_height_rules.yaml").read_text())
        cls.rules = HeightRules.from_mapping(raw)

    def test_preserves_holes_and_suppresses_only_clip_edges(self):
        geometry = Polygon(
            [(-10, 10), (60, 10), (60, 70), (-10, 70), (-10, 10)],
            [[(10, 20), (30, 20), (30, 40), (10, 40), (10, 20)]],
        )
        buildings, report, _flat = prepare_buildings(
            [feature(1, geometry, '"height"=>"12","building"=>"apartments"')],
            self.rules,
        )
        records, stats = clip_buildings(buildings, box(0, 0, 100, 100), 0, 0)
        self.assertEqual(report["holeCount"], 1)
        self.assertEqual(len(records), 1)
        self.assertEqual(len(records[0]["rings"]), 2)
        self.assertEqual(records[0]["rings"][1]["flags"], 1)
        outer = records[0]["rings"][0]
        seam_edges = []
        for index, point in enumerate(outer["points"]):
            end = outer["points"][(index + 1) % len(outer["points"])]
            if point[0] == 0 and end[0] == 0:
                seam_edges.append(outer["walls"][index])
        self.assertEqual(seam_edges, [False])
        self.assertGreater(stats["emittedWallCount"], 0)
        self.assertGreater(stats["suppressedWallCount"], 0)

    def test_relation_parent_controls_inheritance_and_outline_base(self):
        outline = feature(
            10,
            box(0, 0, 100, 100),
            '"height"=>"24","building"=>"apartments"',
        )
        part = feature(
            11,
            box(10, 10, 90, 90),
            '"building:part"=>"apartments"',
        )
        buildings, report, flat = prepare_buildings(
            [outline, part],
            self.rules,
            {"partParents": {"w11": "w10"}},
        )
        by_key = {building.object_key: building for building in buildings}
        self.assertFalse(by_key["w10"].extrude)
        self.assertTrue(by_key["w11"].extrude)
        self.assertEqual(by_key["w11"].resolved.height_dm, 240)
        self.assertEqual(flat, {"w10"})
        self.assertEqual(report["relationAssociationCount"], 1)


if __name__ == "__main__":
    unittest.main()
