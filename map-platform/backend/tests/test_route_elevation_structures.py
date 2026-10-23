from __future__ import annotations

import math
import sqlite3
import tempfile
import unittest
from pathlib import Path

from map_platform import route_elevation as rel
from map_platform.route_elevation_structures import (
    OSM_ATTRIBUTION,
    StructureAnnotator,
    StructureIndex,
    StructureWay,
    _decode_geometry,
    associate_structures,
    build_structure_index,
    parse_layer,
    structure_kind,
)

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "route_elevation_structures.osm"
GOLDEN_GATE_SIDEWALK = (970229713, 368033990)
GOLDEN_GATE_MOTORWAY = 595194543
MILLAU = 4296812
SYNTHETIC_TUNNEL = 9_000_000_001
SYNTHETIC_STACK = (9_000_000_002, 9_000_000_003)
SYNTHETIC_LONG_BRIDGE = 9_000_000_004
SYNTHETIC_LAYER_CHAIN = (9_000_000_005, 9_000_000_006)
# Observed Open Topo Data SRTM30 values at five Millau way nodes (bridge-test-recheck.json,
# 2026-10-22). They demonstrate the valley artifact; they are not surveyed deck heights.
MILLAU_SRTM30_NODE_VALUES = (
    ((44.0910166, 3.0210656), 585.0),
    ((44.0830509, 3.0218832), 407.0),
    ((44.0799528, 3.0223435), 489.0),
    ((44.0769031, 3.0228219), 509.0),
    ((44.0689639, 3.0245167), 676.0),
)


def destination(lat, lon, bearing, distance):
    radius = rel.EARTH_RADIUS_M
    delta = distance / radius
    theta = math.radians(bearing)
    phi1, lambda1 = math.radians(lat), math.radians(lon)
    phi2 = math.asin(math.sin(phi1) * math.cos(delta) + math.cos(phi1) * math.sin(delta) * math.cos(theta))
    lambda2 = lambda1 + math.atan2(math.sin(theta) * math.sin(delta) * math.cos(phi1),
                                   math.cos(delta) - math.sin(phi1) * math.sin(phi2))
    return math.degrees(phi2), math.degrees(lambda2)


def geometry_from_points(points):
    return rel.build_route_geometry([round(lat * 1e6) for lat, _ in points], [round(lon * 1e6) for _, lon in points])


def with_approaches(points, approach_m=300.0, step_m=50.0):
    inbound = rel.initial_bearing_deg(*points[0], *points[1])
    outbound = rel.initial_bearing_deg(*points[-2], *points[-1])
    start = destination(*points[0], (inbound + 180.0) % 360.0, approach_m)
    route = [destination(*start, inbound, distance) for distance in range(0, int(approach_m), int(step_m))]
    route.extend(points)
    route.extend(destination(*points[-1], outbound, distance)
                 for distance in range(int(step_m), int(approach_m) + int(step_m), int(step_m)))
    return route


class StructureIndexTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.directory = Path(cls.tmp.name) / "indexes"
        cls.directory.mkdir()
        cls.index_path = cls.directory / "fixture.sqlite3"
        cls.summary = build_structure_index(FIXTURE, cls.index_path, source_label="fixture:osm-xml")
        connection = sqlite3.connect(cls.index_path)
        cls.ways = {}
        for row in connection.execute(
            "SELECT way_id, version, kind, highway, layer, bicycle, access, geometry FROM structures"
        ):
            lat, lon = _decode_geometry(row[7])
            cls.ways[row[0]] = StructureWay(row[0], row[1], row[2], row[3], row[4], row[5], row[6], lat, lon)
        connection.close()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def points(self, way_id, reverse=False):
        way = self.ways[way_id]
        points = [(way.latitude(i), way.longitude(i)) for i in range(len(way.lat_e7))]
        return list(reversed(points)) if reverse else points

    def all_ways(self):
        return [self.ways[key] for key in sorted(self.ways)]


class StructureIndexBuilderTests(StructureIndexTestCase):
    def test_builder_reads_osm_with_pyosmium_and_records_provenance(self):
        self.assertEqual(self.summary["wayCount"], 10)
        index = StructureIndex(self.index_path)
        self.assertEqual(index.source_label, "fixture:osm-xml")
        connection = sqlite3.connect(self.index_path)
        meta = dict(connection.execute("SELECT key, value FROM meta"))
        connection.close()
        self.assertEqual(meta["attribution"], OSM_ATTRIBUTION)
        self.assertEqual(self.ways[MILLAU].version, 60)
        self.assertEqual(self.ways[GOLDEN_GATE_MOTORWAY].version, 12)
        self.assertFalse(self.ways[GOLDEN_GATE_MOTORWAY].cyclable)
        self.assertTrue(all(self.ways[way_id].cyclable for way_id in GOLDEN_GATE_SIDEWALK))
        self.assertEqual(self.ways[SYNTHETIC_TUNNEL].kind, "tunnel")
        with self.assertRaises(Exception):
            build_structure_index(FIXTURE, self.index_path, source_label="again")

    def test_tag_classification_and_layer_parsing(self):
        self.assertEqual(structure_kind({"highway": "cycleway", "bridge": "viaduct"}), "bridge")
        self.assertEqual(structure_kind({"highway": "service", "tunnel": "building_passage"}), "tunnel")
        for tags in ({"highway": "residential", "bridge": "no"}, {"highway": "footway", "tunnel": "culvert"},
                     {"highway": "proposed", "bridge": "yes"}, {"bridge": "yes"},
                     {"highway": "path", "bridge": "yes", "tunnel": "yes"}):
            self.assertIsNone(structure_kind(tags))
        self.assertEqual([parse_layer(v) for v in (None, "1", "-2", "+3", "x", "9", "1;2")], [0, 1, -2, 3, 0, 5, 0])


class StructureAssociationTests(StructureIndexTestCase):
    def test_cycling_route_on_golden_gate_sidewalk_is_estimated_despite_adjacent_motorway(self):
        sidewalk = self.points(GOLDEN_GATE_SIDEWALK[0]) + self.points(GOLDEN_GATE_SIDEWALK[1])[1:]
        geometry = geometry_from_points(with_approaches(sidewalk))
        spans = associate_structures(geometry, self.all_ways(), travel_mode="cycling")
        self.assertEqual(len(spans), 1, spans)
        span = spans[0]
        self.assertEqual((span.kind, span.resolution), ("bridge", rel.STRUCTURE_ESTIMATED))
        self.assertTrue(set(GOLDEN_GATE_SIDEWALK) <= set(span.way_ids))
        self.assertAlmostEqual(span.start_m, 300.0, delta=40.0)
        self.assertAlmostEqual(span.end_m - span.start_m, 2102.8, delta=60.0)

        plan = rel.plan_sampling(geometry.length_m)
        # Synthetic approach terrain; 0 m over the strait is the observed SRTM30 midpoint value.
        raw = [0.0 if span.start_m < distance < span.end_m else 70.0 for distance in plan.distances_m]
        profile = rel.process_profile(geometry, plan, raw, rel.ElevationSource("internal-dem", "test"),
                                      structures=spans)
        middle = min(range(plan.count), key=lambda i: abs(plan.distances_m[i] - (span.start_m + span.end_m) / 2))
        self.assertAlmostEqual(profile.elevation_m[middle], 70.0, delta=0.5)
        self.assertTrue(profile.flags[middle] & rel.FLAG_STRUCTURE_ESTIMATED)
        self.assertEqual(profile.raw_elevation_m[middle], 0.0)
        self.assertEqual(profile.statistics.total_ascent_m, 0.0)

    def test_millau_motorway_is_not_force_corrected_for_cycling(self):
        geometry = geometry_from_points(with_approaches(self.points(MILLAU)))
        cycling = associate_structures(geometry, self.all_ways(), travel_mode="cycling")
        self.assertEqual([(s.resolution, s.reason) for s in cycling],
                         [(rel.STRUCTURE_AMBIGUOUS, "structure-not-usable-by-travel-mode")])
        stress = associate_structures(geometry, self.all_ways(), travel_mode="any")
        self.assertEqual([(s.kind, s.resolution, s.way_ids) for s in stress],
                         [("bridge", rel.STRUCTURE_ESTIMATED, (MILLAU,))])
        self.assertAlmostEqual(stress[0].end_m - stress[0].start_m, 2469.1, delta=40.0)

    def test_millau_srtm_dip_is_replaced_by_an_estimated_deck_line(self):
        geometry = geometry_from_points(with_approaches(self.points(MILLAU)))
        spans = associate_structures(geometry, self.all_ways(), travel_mode="any")
        plan = rel.plan_sampling(geometry.length_m)
        node_distances = []
        for (lat, lon), value in MILLAU_SRTM30_NODE_VALUES:
            nearest = min(range(geometry.point_count),
                          key=lambda i: abs(geometry.latitude(i) - lat) + abs(geometry.longitude(i) - lon))
            node_distances.append((geometry.cumulative_m[nearest], value))
        raw = []
        for distance in plan.distances_m:
            if distance <= node_distances[0][0]:
                raw.append(node_distances[0][1])
            elif distance >= node_distances[-1][0]:
                raw.append(node_distances[-1][1])
            else:
                for (d0, v0), (d1, v1) in zip(node_distances, node_distances[1:]):
                    if d0 <= distance <= d1:
                        raw.append(v0 + (v1 - v0) * (distance - d0) / (d1 - d0))
                        break
        uncorrected = rel.process_profile(geometry, plan, raw, rel.ElevationSource("internal-dem", "srtm30-fixture"))
        corrected = rel.process_profile(geometry, plan, raw, rel.ElevationSource("internal-dem", "srtm30-fixture"),
                                        structures=spans)
        self.assertLess(min(value for value in uncorrected.elevation_m if value is not None), 420.0)
        deck = [value for value, flag in zip(corrected.elevation_m, corrected.flags)
                if flag & rel.FLAG_STRUCTURE_ESTIMATED]
        self.assertTrue(deck)
        self.assertGreaterEqual(min(deck), 584.0)
        self.assertLessEqual(max(deck), 677.0)
        self.assertLess(corrected.statistics.total_descent_m, uncorrected.statistics.total_descent_m)

    def test_tunnel_is_estimated_between_portals(self):
        geometry = geometry_from_points(with_approaches(self.points(SYNTHETIC_TUNNEL)))
        spans = associate_structures(geometry, self.all_ways())
        self.assertEqual([(s.kind, s.resolution) for s in spans], [("tunnel", rel.STRUCTURE_ESTIMATED)])

    def test_out_and_back_through_a_tunnel_produces_two_spans(self):
        outbound = with_approaches(self.points(SYNTHETIC_TUNNEL))
        route = outbound + list(reversed(outbound))[1:]
        spans = associate_structures(geometry_from_points(route), self.all_ways())
        self.assertEqual([s.resolution for s in spans], [rel.STRUCTURE_ESTIMATED, rel.STRUCTURE_ESTIMATED])
        self.assertLess(spans[0].end_m, spans[1].start_m)

    def test_stacked_layers_are_ambiguous(self):
        geometry = geometry_from_points(with_approaches(self.points(SYNTHETIC_STACK[0])))
        spans = associate_structures(geometry, self.all_ways())
        self.assertEqual([(s.resolution, s.reason) for s in spans], [(rel.STRUCTURE_AMBIGUOUS, "stacked-structures")])
        self.assertEqual(set(spans[0].way_ids), set(SYNTHETIC_STACK))

    def test_chained_spans_with_different_layers_are_not_stacked(self):
        chain = self.points(SYNTHETIC_LAYER_CHAIN[0]) + self.points(SYNTHETIC_LAYER_CHAIN[1])[1:]
        spans = associate_structures(geometry_from_points(with_approaches(chain)), self.all_ways())
        self.assertEqual([(s.kind, s.resolution) for s in spans], [("bridge", rel.STRUCTURE_ESTIMATED)])
        self.assertEqual(set(spans[0].way_ids), set(SYNTHETIC_LAYER_CHAIN))
        self.assertAlmostEqual(spans[0].end_m - spans[0].start_m, 900.0, delta=30.0)

    def test_partial_parallel_alignment_is_ambiguous(self):
        bridge = self.points(SYNTHETIC_LONG_BRIDGE)
        approach = destination(*bridge[4], 90.0, 400.0)
        route = [approach, destination(*bridge[4], 90.0, 8.0)]
        route += [destination(*point, 90.0, 8.0) for point in bridge[5:9]]
        route.append(destination(*bridge[8], 90.0, 400.0))
        spans = associate_structures(geometry_from_points(route), self.all_ways())
        self.assertEqual([(s.resolution, s.reason) for s in spans], [(rel.STRUCTURE_AMBIGUOUS, "partial-alignment")])

    def test_perpendicular_crossing_under_a_bridge_is_not_a_structure(self):
        bridge = self.points(SYNTHETIC_LONG_BRIDGE)
        middle = bridge[len(bridge) // 2]
        route = [destination(*middle, 270.0, 300.0), destination(*middle, 90.0, 300.0)]
        self.assertEqual(associate_structures(geometry_from_points(route), self.all_ways()), [])


class StructureAnnotatorTests(StructureIndexTestCase):
    def test_missing_outside_and_partial_coverage_are_explicit(self):
        none = StructureAnnotator.from_directory(None)
        geometry = geometry_from_points(with_approaches(self.points(SYNTHETIC_TUNNEL)))
        spans, correction = none.annotate(geometry, travel_mode="cycling")
        self.assertEqual((spans, correction.status, correction.reason), ([], "unavailable", "no-structure-index"))

        annotator = StructureAnnotator.from_directory(self.directory)
        spans, correction = annotator.annotate(geometry, travel_mode="cycling")
        self.assertEqual(correction.status, "partial-coverage")
        self.assertEqual([s.kind for s in spans], ["tunnel"])
        self.assertIn("fixture:osm-xml", correction.source_version)
        self.assertEqual(correction.attribution, (OSM_ATTRIBUTION,))

        far = geometry_from_points([(-33.9, 151.2), (-33.91, 151.2)])
        spans, correction = annotator.annotate(far, travel_mode="cycling")
        self.assertEqual((spans, correction.reason), ([], "outside-structure-index-coverage"))


if __name__ == "__main__":
    unittest.main()
