import pathlib
import sys
import unittest

from shapely.geometry import box, LineString, mapping, Polygon
import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from building_height import HeightRules
from building_pipeline import (
    BUILDING_FLAG_FLAT_BASE,
    clip_buildings,
    prepare_buildings,
    projected_selection_geometry,
)
from map_format import MAX_BUILDING_RINGS


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

    def test_partial_parts_do_not_flatten_the_remaining_outline(self):
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
        self.assertTrue(by_key["w10"].extrude)
        self.assertTrue(by_key["w11"].extrude)
        self.assertEqual(by_key["w11"].resolved.height_dm, 240)
        self.assertEqual(by_key["w10"].geometry.area, 3_600)
        self.assertIsNotNone(by_key["w10"].wall_boundary)
        self.assertEqual(flat, set())
        self.assertEqual(report["relationAssociationCount"], 1)

        records, _stats = clip_buildings(buildings, box(0, 0, 100, 100), 0, 0)
        outline_record = next(record for record in records if record["source_key"] == "w10")
        self.assertEqual(len(outline_record["rings"]), 2)
        self.assertFalse(any(outline_record["rings"][1]["walls"]))

    def test_complete_parts_keep_a_ring_preserving_flat_outline(self):
        geometry = Polygon(
            [(0, 0), (100, 0), (100, 100), (0, 100), (0, 0)],
            [[(30, 30), (70, 30), (70, 70), (30, 70), (30, 30)]],
        )
        outline = feature(
            20, geometry, '"height"=>"24","building"=>"apartments"'
        )
        part = feature(
            21,
            geometry,
            '"height"=>"18","building:part"=>"apartments"',
        )
        buildings, _report, flat = prepare_buildings(
            [outline, part], self.rules, {"partParents": {"w21": "w20"}}
        )
        self.assertEqual(flat, {"w20"})
        records, _stats = clip_buildings(buildings, box(0, 0, 100, 100), 0, 0)
        flat_record = next(
            record for record in records if record["flags"] & BUILDING_FLAG_FLAT_BASE
        )
        self.assertEqual(len(flat_record["rings"]), 2)
        self.assertFalse(any(any(ring["walls"]) for ring in flat_record["rings"]))

    def test_rejection_diagnostics_count_each_source_once(self):
        _buildings, report, _flat = prepare_buildings(
            [feature(30, box(0, 0, 10, 10), '"height"=>"unknown"')],
            self.rules,
        )
        self.assertEqual(report["rejectedTags"]["heightMalformed"], 1)

    def test_excess_holes_are_bounded_deterministically(self):
        holes = []
        for index in range(MAX_BUILDING_RINGS + 8):
            x = 10 + (index % 8) * 20
            y = 10 + (index // 8) * 20
            size = 4 + (index % 3)
            holes.append(list(box(x, y, x + size, y + size).exterior.coords))
        geometry = Polygon(list(box(0, 0, 200, 200).exterior.coords), holes)
        buildings, _report, _flat = prepare_buildings(
            [feature(35, geometry, '"height"=>"20"')],
            self.rules,
        )

        records, stats = clip_buildings(buildings, box(0, 0, 200, 200), 0, 0)

        self.assertEqual(len(records), 1)
        self.assertEqual(len(records[0]["rings"]), MAX_BUILDING_RINGS)
        self.assertEqual(stats["droppedHoleCount"], 9)
        self.assertTrue(all(ring["flags"] == 1 for ring in records[0]["rings"][1:]))

    def test_selection_excludes_halo_buildings_from_output(self):
        buildings, report, _flat = prepare_buildings(
            [
                feature(40, box(0, 0, 10, 10), '"height"=>"10"'),
                feature(41, box(100, 100, 110, 110), '"height"=>"20"'),
            ],
            self.rules,
            selection_geometry=box(-1, -1, 20, 20),
        )
        self.assertEqual([building.object_key for building in buildings], ["w40"])
        self.assertEqual(report["sourceCount"], 1)

    def test_projects_polygon_and_buffers_route_selection(self):
        polygon = projected_selection_geometry(mapping(box(0, 0, 0.01, 0.01)))
        self.assertGreater(polygon.area, 1_000_000)

        route = projected_selection_geometry(
            mapping(LineString([(0, 0), (0.01, 0)])), buffer_meters=50
        )
        self.assertGreater(route.area, 100_000)
        self.assertLess(route.bounds[1], 0)
        self.assertGreater(route.bounds[3], 0)
        with self.assertRaisesRegex(ValueError, "buffer is invalid"):
            projected_selection_geometry(
                mapping(LineString([(0, 0), (0.01, 0)])),
                buffer_meters=float("nan"),
            )


if __name__ == "__main__":
    unittest.main()
