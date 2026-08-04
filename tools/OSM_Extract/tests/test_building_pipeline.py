import pathlib
import sys
import unittest
from dataclasses import replace

from shapely.geometry import box, LineString, mapping, MultiPolygon, Polygon
from shapely.ops import unary_union
import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from building_height import HeightProvenance, HeightRules
from building_pipeline import (
    BUILDING_FLAG_FLAT_BASE,
    clip_buildings,
    prepare_buildings,
    projected_selection_geometry,
)
from map_format import MAX_BUILDING_RINGS, _building_section


def feature(identifier, geometry, other_tags, *, building="yes", relation=False):
    return {
        "type": "Feature",
        "properties": {
            "osm_id" if relation else "osm_way_id": identifier,
            "building": building,
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

    def test_local_median_uses_direct_same_class_cell_halo_samples_only(self):
        rules = replace(
            self.rules,
            cell_size_meters=100,
            halo_cells=1,
            minimum_samples=3,
        )
        two_direct_and_fallbacks = [
            feature(100, box(10, 10, 20, 20), '"height"=>"10"', building="office"),
            feature(101, box(30, 10, 40, 20), '"height"=>"20"', building="office"),
            feature(102, box(50, 10, 60, 20), "", building="office"),
            feature(103, box(70, 10, 80, 20), "", building="office"),
            # A different class never calibrates office buildings.
            feature(104, box(20, 30, 30, 40), '"height"=>"200"', building="commercial"),
        ]
        buildings, _report, _flat = prepare_buildings(
            two_direct_and_fallbacks, rules
        )
        by_key = {item.object_key: item for item in buildings}
        self.assertEqual(
            by_key["w102"].resolved.provenance,
            HeightProvenance.CLASS_DEFAULT,
        )

        # The third direct office sample sits across a cell boundary but inside
        # the one-cell halo, meeting the threshold with median 20 m.
        calibrated_input = [
            *two_direct_and_fallbacks,
            feature(105, box(140, 10, 150, 20), '"height"=>"30"', building="office"),
            # Cell 2 is beyond the cell-0 target's halo and cannot affect it.
            feature(106, box(240, 10, 250, 20), '"height"=>"90"', building="office"),
            feature(107, box(250, 30, 260, 40), "", building="office"),
        ]
        first, first_report, _flat = prepare_buildings(calibrated_input, rules)
        shuffled, shuffled_report, _flat = prepare_buildings(
            list(reversed(calibrated_input)), rules
        )
        first_snapshot = [
            (item.object_key, item.resolved.height_dm, item.resolved.provenance)
            for item in first
        ]
        shuffled_snapshot = [
            (item.object_key, item.resolved.height_dm, item.resolved.provenance)
            for item in shuffled
        ]
        self.assertEqual(first_snapshot, shuffled_snapshot)
        self.assertEqual(first_report, shuffled_report)
        calibrated = {item.object_key: item for item in first}
        self.assertEqual(calibrated["w102"].resolved.height_dm, 200)
        self.assertEqual(
            calibrated["w102"].resolved.provenance,
            HeightProvenance.LOCAL_OSM_MEDIAN,
        )
        self.assertEqual(
            calibrated["w107"].resolved.provenance,
            HeightProvenance.CLASS_DEFAULT,
        )

    def test_cross_block_seams_multiple_outers_and_bytes_are_deterministic(self):
        crossing = feature(
            200,
            box(50, 50, 150, 150),
            '"height"=>"24"',
            building="apartments",
        )
        multiple_outers = feature(
            201,
            MultiPolygon([box(10, 10, 30, 30), box(160, 160, 190, 190)]),
            '"height"=>"12"',
            building="commercial",
            relation=True,
        )
        inputs = [crossing, multiple_outers]
        buildings, _report, _flat = prepare_buildings(inputs, self.rules)
        shuffled, _shuffled_report, _flat = prepare_buildings(
            list(reversed(inputs)), self.rules
        )

        reconstructed = []
        encoded = []
        shuffled_encoded = []
        for min_x, min_y in ((0, 0), (100, 0), (0, 100), (100, 100)):
            block = box(min_x, min_y, min_x + 100, min_y + 100)
            records, _stats = clip_buildings(buildings, block, min_x, min_y)
            shuffled_records, _stats = clip_buildings(
                shuffled, block, min_x, min_y
            )
            encoded.append(_building_section(records)[0])
            shuffled_encoded.append(_building_section(shuffled_records)[0])
            for record in records:
                for ring in record["rings"]:
                    global_points = [
                        (x + min_x, y + min_y) for x, y in ring["points"]
                    ]
                    if ring["flags"] == 0:
                        reconstructed.append(Polygon(global_points))
                    for index, start in enumerate(global_points):
                        end = global_points[(index + 1) % len(global_points)]
                        if (
                            (start[0] == end[0] == 100)
                            or (start[1] == end[1] == 100)
                        ):
                            self.assertFalse(ring["walls"][index])

        self.assertEqual(encoded, shuffled_encoded)
        crossing_roofs = [
            polygon
            for polygon in reconstructed
            if polygon.intersection(box(50, 50, 150, 150)).area > 0
        ]
        self.assertAlmostEqual(
            unary_union(crossing_roofs).intersection(box(50, 50, 150, 150)).area,
            10_000,
        )
        relation_records = sum(
            1
            for min_x, min_y in ((0, 0), (100, 0), (0, 100), (100, 100))
            for record in clip_buildings(
                buildings, box(min_x, min_y, min_x + 100, min_y + 100), min_x, min_y
            )[0]
            if record["source_key"] == "r201"
        )
        self.assertEqual(relation_records, 2)

    def test_ring_winding_and_start_vertex_encode_canonically(self):
        outer = [(0, 0), (80, 0), (80, 80), (0, 80)]
        hole = [(20, 20), (20, 60), (60, 60), (60, 20)]

        def closed_variant(points, rotation, reverse):
            values = list(reversed(points)) if reverse else list(points)
            values = values[rotation:] + values[:rotation]
            return [*values, values[0]]

        canonical = Polygon(
            closed_variant(outer, 0, False),
            [closed_variant(hole, 0, False)],
        )
        equivalent = Polygon(
            closed_variant(outer, 2, True),
            [closed_variant(hole, 1, True)],
        )

        encoded = []
        records_by_variant = []
        for geometry in (canonical, equivalent):
            buildings, _report, _flat = prepare_buildings(
                [feature(250, geometry, '"height"=>"18"')], self.rules
            )
            records, _stats = clip_buildings(
                buildings, box(0, 0, 100, 100), 0, 0
            )
            records_by_variant.append(records)
            encoded.append(_building_section(records)[0])

        self.assertEqual(encoded[0], encoded[1])
        self.assertEqual(records_by_variant[0], records_by_variant[1])

        def signed_area(points):
            return sum(
                start[0] * end[1] - end[0] * start[1]
                for start, end in zip(points, [*points[1:], points[0]])
            )

        rings = records_by_variant[0][0]["rings"]
        self.assertGreater(signed_area(rings[0]["points"]), 0)
        self.assertLess(signed_area(rings[1]["points"]), 0)

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
