from __future__ import annotations

import importlib.util
import json
import math
import unittest
from pathlib import Path

from map_platform import route_elevation as rel

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "protocol" / "fixtures" / "route-elevation-v1"


def straight(lat: float, lon: float, bearing: float, length_m: float, step_m: float) -> list[list[int]]:
    return load_generator().straight_route(lat, lon, bearing, length_m, step_m)


def geometry_of(points: list[list[int]]) -> rel.RouteGeometry:
    return rel.build_route_geometry([lat for _, lat in points], [lon for lon, _ in points])


SOURCE = rel.ElevationSource(kind="internal-dem", identifier="test")


def load_generator():
    spec = importlib.util.spec_from_file_location("generator", ROOT / "tools" / "generate_route_elevation_fixtures.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class SharedFixtureTests(unittest.TestCase):
    """The committed fixtures are the contract the Swift and firmware tests consume."""

    def test_committed_fixtures_match_the_reference_generator(self):
        self.assertEqual(load_generator().check(), [])

    def test_every_case_reprocesses_within_tolerance(self):
        generator = load_generator()
        document = json.loads((FIXTURES / "processing.json").read_text(encoding="utf-8"))
        self.assertEqual(document["processingVersion"], rel.PROCESSING_VERSION)
        tolerance = max(document["tolerances"].values())
        names = set()
        for case in document["cases"]:
            names.add(case["name"])
            with self.subTest(case=case["name"]):
                geometry = geometry_of(case["geometryE6"])
                plan = rel.plan_sampling(geometry.length_m)
                if case["input"]["kind"] == "vertices":
                    raw = rel.resample_vertex_elevations(geometry, plan, case["input"]["vertexElevationM"])
                else:
                    raw = case["input"]["rawElevationM"]
                spans = [rel.StructureSpan(kind=s["kind"], start_m=s["startM"], end_m=s["endM"],
                                           resolution=s["resolution"], way_ids=tuple(s["osmWayIds"]),
                                           reason=s.get("reason"))
                         for s in case["structures"]]
                profile = rel.process_profile(geometry, plan, raw, SOURCE, structures=spans).to_dict()
                expected = case["expected"]
                self.assertEqual(profile["geometry"]["digest"], expected["geometryDigest"])
                for key in ("samples", "statistics", "quality", "structures"):
                    self.assertEqual(generator.numbers_close(expected[key], profile[key], tolerance), [], key)
        self.assertTrue({"ordinary-hill", "flat-low-relief", "below-sea-level", "missing-data",
                         "bridge-estimated", "tunnel-estimated", "ambiguous-crossing",
                         "unresolved-structure", "gpx-vertices", "long-route-spacing"} <= names)

    def test_display_points_preserve_extremes_boundaries_and_gaps(self):
        generator = load_generator()
        document = json.loads((FIXTURES / "processing.json").read_text(encoding="utf-8"))
        cases = {case["name"]: case for case in document["cases"]}
        long_case = cases["long-route-spacing"]["expected"]
        display = long_case["display"]
        self.assertLessEqual(len(display), document["displayMaximumPoints"])
        elevations = [value for value in long_case["samples"]["elevationM"] if value is not None]
        shown = [point["elevationM"] for point in display]
        self.assertEqual(max(shown), round(max(elevations)))
        self.assertEqual(min(shown), round(min(elevations)))
        self.assertEqual(display[0]["distanceM"], 0)
        self.assertEqual(display[-1]["distanceM"], round(long_case["lengthM"]))
        gaps = cases["missing-data"]["expected"]["display"]
        self.assertTrue(any(point["elevationM"] is None for point in gaps))
        self.assertTrue(all(point["flags"] < 64 for case in cases.values() for point in case["expected"]["display"]))
        bridge = cases["bridge-estimated"]["expected"]["display"]
        self.assertTrue(any(point["flags"] & (1 << 3) and point["flags"] & (1 << 5) for point in bridge))
        self.assertEqual(generator.grade_band(None), 0)
        self.assertEqual([generator.grade_band(value) for value in (-2.1, -2.0, 1.9, 2.0, 7.9, 12.0)],
                         [1, 2, 2, 3, 5, 7])


class GeometryTests(unittest.TestCase):
    def test_digest_binds_order_and_quantized_coordinates(self):
        first = rel.geometry_digest([1_000_000, 2_000_000], [3_000_000, 4_000_000])
        self.assertEqual(first, rel.geometry_digest([1_000_000, 2_000_000], [3_000_000, 4_000_000]))
        self.assertNotEqual(first, rel.geometry_digest([2_000_000, 1_000_000], [4_000_000, 3_000_000]))
        self.assertNotEqual(first, rel.geometry_digest([1_000_001, 2_000_000], [3_000_000, 4_000_000]))

    def test_parse_requires_geojson_axis_order_integers_and_matching_digest(self):
        payload = {"crs": "EPSG:4326", "coordinatesE6": [[7_000_000, 45_000_000], [7_000_000, 45_010_000]]}
        geometry = rel.parse_route_geometry(payload)
        self.assertAlmostEqual(geometry.latitude(1), 45.01)
        self.assertAlmostEqual(geometry.length_m, 1111.95, places=1)
        rel.parse_route_geometry({**payload, "digest": geometry.digest})
        invalid = [
            {**payload, "digest": "0" * 64},
            {**payload, "crs": "EPSG:3857"},
            {"coordinatesE6": [[7_000_000, 45_000_000]]},
            {"coordinatesE6": [[7.0, 45.0], [7.0, 45.1]]},
            {"coordinatesE6": [[True, 45_000_000], [7_000_000, 45_010_000]]},
            {"coordinatesE6": [[7_000_000, 91_000_000], [7_000_000, 45_010_000]]},
            {"coordinatesE6": [[7_000_000, 45_000_000], [7_000_000, 45_000_000]]},
            {"coordinatesE6": [[0, 0]] * (rel.MAXIMUM_ROUTE_POINTS + 1)},
            {"coordinatesE6": [[0, 0], [0, 10_000_000]]},
        ]
        for value in invalid:
            with self.subTest(value=str(value)[:80]), self.assertRaises(rel.RouteElevationError):
                rel.parse_route_geometry(value)

    def test_antimeridian_segment_uses_the_short_distance(self):
        geometry = rel.build_route_geometry([0, 0], [179_999_000, -179_999_000])
        self.assertLess(geometry.length_m, 300.0)
        lat, lon = geometry.point_at_distance(geometry.length_m / 2)
        self.assertTrue(lon >= 179.999 or lon <= -179.999)


class SamplingTests(unittest.TestCase):
    def test_spacing_widens_only_beyond_the_sample_bound(self):
        self.assertEqual(rel.sampling_spacing_m(200_000.0), 50.0)
        self.assertEqual(rel.sampling_spacing_m(200_001.0), 60.0)
        self.assertEqual(rel.sampling_spacing_m(260_000.0), 70.0)
        plan = rel.plan_sampling(1_000_000.0)
        self.assertLessEqual(plan.count, rel.MAXIMUM_SAMPLES)
        self.assertEqual(plan.distances_m[-1], 1_000_000.0)

    def test_last_sample_is_the_exact_route_end(self):
        plan = rel.plan_sampling(123.4)
        self.assertEqual(plan.distances_m, (0.0, 50.0, 100.0, 123.4))
        exact = rel.plan_sampling(100.0)
        self.assertEqual(exact.distances_m, (0.0, 50.0, 100.0))

    def test_vertex_resampling_keeps_long_gaps_unknown(self):
        geometry = geometry_of(straight(45.0, 7.0, 0.0, 1000.0, 250.0))
        plan = rel.plan_sampling(geometry.length_m)
        values = rel.resample_vertex_elevations(geometry, plan, [100.0, None, None, 160.0, 170.0])
        self.assertEqual(values[0], 100.0)
        self.assertIsNone(values[5])
        self.assertAlmostEqual(values[-3], 160.0 + 10.0 * (900.0 - 750.0) / 250.0, delta=0.01)


class HysteresisTests(unittest.TestCase):
    def test_noise_below_threshold_is_not_climbing(self):
        values = [100.0 + (2.0 if index % 2 else -2.0) for index in range(200)]
        result = rel.hysteresis_totals(values)
        self.assertEqual((result.ascent_m, result.descent_m), (0.0, 0.0))
        self.assertTrue(all(value == 0.0 for value in result.cumulative_ascent_m))

    def test_reversing_a_profile_swaps_ascent_and_descent(self):
        values = [200 + 80 * math.sin(index / 9.0) + 3 * math.sin(index * 1.7) for index in range(300)]
        forward = rel.hysteresis_totals(values)
        backward = rel.hysteresis_totals(list(reversed(values)))
        self.assertAlmostEqual(forward.ascent_m, backward.descent_m, delta=rel.ASCENT_HYSTERESIS_M)
        self.assertAlmostEqual(forward.descent_m, backward.ascent_m, delta=rel.ASCENT_HYSTERESIS_M)

    def test_unknown_gap_is_never_counted_and_cumulative_is_monotonic(self):
        values = [100.0, 110.0, 120.0, None, None, 300.0, 310.0]
        result = rel.hysteresis_totals(values)
        self.assertEqual(result.ascent_m, 30.0)
        known = [value for value in result.cumulative_ascent_m if value is not None]
        self.assertEqual(known, sorted(known))
        self.assertEqual(known[-1], result.ascent_m)
        self.assertIsNone(result.cumulative_ascent_m[3])


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.geometry = geometry_of(straight(46.0, 8.0, 90.0, 3000.0, 50.0))
        self.plan = rel.plan_sampling(self.geometry.length_m)

    def test_grade_uses_a_distance_window_not_adjacent_samples(self):
        raw = [500.0 + 0.05 * distance for distance in self.plan.distances_m]
        raw[30] += 4.0
        profile = rel.process_profile(self.geometry, self.plan, raw, SOURCE)
        grades = [grade for grade in profile.grade_percent if grade is not None]
        self.assertTrue(all(3.5 < grade < 6.5 for grade in grades), grades)
        self.assertIsNone(profile.grade_percent[-1])

    def test_structure_spans_estimate_unknown_or_ambiguous_honestly(self):
        raw = [500.0 + 0.02 * distance - (120.0 if 1000.0 <= distance <= 2000.0 else 0.0)
               for distance in self.plan.distances_m]
        estimated = rel.process_profile(self.geometry, self.plan, raw, SOURCE, structures=[
            rel.StructureSpan("bridge", 1000.0, 2000.0, rel.STRUCTURE_ESTIMATED, (7,))])
        middle = self.plan.distances_m.index(1500.0)
        self.assertAlmostEqual(estimated.elevation_m[middle], 530.0, delta=0.5)
        self.assertTrue(estimated.flags[middle] & rel.FLAG_STRUCTURE_ESTIMATED)
        self.assertTrue(estimated.flags[middle] & rel.FLAG_BRIDGE)
        self.assertTrue(estimated.statistics.includes_estimated)
        self.assertEqual(estimated.raw_elevation_m[middle], raw[middle])

        steep = list(raw)
        for index, distance in enumerate(self.plan.distances_m):
            if distance >= 2000.0:
                steep[index] += 400.0
        unresolved = rel.process_profile(self.geometry, self.plan, steep, SOURCE, structures=[
            rel.StructureSpan("bridge", 1000.0, 2000.0, rel.STRUCTURE_ESTIMATED, (7,))])
        self.assertEqual(unresolved.structures[0].resolution, rel.STRUCTURE_UNRESOLVED)
        self.assertEqual(unresolved.structures[0].reason, "implausible-anchor-grade")
        self.assertIsNone(unresolved.elevation_m[middle])
        self.assertFalse(unresolved.statistics.complete)

        ambiguous = rel.process_profile(self.geometry, self.plan, raw, SOURCE, structures=[
            rel.StructureSpan("bridge", 1000.0, 2000.0, rel.STRUCTURE_AMBIGUOUS, (7, 8), "stacked-structures")])
        self.assertIsNotNone(ambiguous.elevation_m[middle])
        self.assertIsNone(ambiguous.grade_percent[middle])
        self.assertEqual(ambiguous.quality.status, rel.QUALITY_PARTIAL)
        self.assertIn("ambiguous-structure", ambiguous.quality.reasons)

    def test_long_structure_is_never_interpolated(self):
        geometry = geometry_of(straight(46.0, 8.0, 90.0, 20_000.0, 500.0))
        plan = rel.plan_sampling(geometry.length_m)
        profile = rel.process_profile(geometry, plan, [400.0] * plan.count, SOURCE, structures=[
            rel.StructureSpan("tunnel", 1000.0, 1000.0 + rel.MAXIMUM_STRUCTURE_LENGTH_M + 50.0,
                              rel.STRUCTURE_ESTIMATED, (9,))])
        self.assertEqual(profile.structures[0].reason, "structure-too-long")

    def test_mostly_missing_profile_is_unavailable_not_zero(self):
        raw = [None] * self.plan.count
        raw[0] = 100.0
        profile = rel.process_profile(self.geometry, self.plan, raw, SOURCE)
        self.assertEqual(profile.quality.status, rel.QUALITY_UNAVAILABLE)
        self.assertIsNone(profile.statistics.total_ascent_m)
        self.assertIsNone(profile.statistics.minimum_elevation_m)

    def test_round_half_away_matches_swift_rounding(self):
        self.assertEqual(rel.round_half_away(2.25, 1), 2.3)
        self.assertEqual(rel.round_half_away(-2.25, 1), -2.3)
        self.assertEqual(rel.round_half_away(0.5, 0), 1.0)
        self.assertEqual(rel.round_half_away(-0.04, 1), 0.0)


if __name__ == "__main__":
    unittest.main()
