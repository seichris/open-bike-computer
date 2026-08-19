import hashlib
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

from map_platform.building_scope import (
    BuildingScopeError,
    BuildingScopePolicy,
    BUILDING_BLOCK_GRID_VERSION,
    BUILDING_MAX_SOURCE_AREA_M2,
    BUILDING_SCOPE_POLICY_VERSION,
    configured_building_max_relation_objects_per_job,
    legacy_building_scope_diagnostics,
    mercator_scale,
    plan_building_scope,
    point_in_ring,
    segment_rectangle_distance,
)
from map_platform.geometry import normalize_geometry
from map_platform.models import Bounds, JobStatus, MapJob, SourceRegion


def make_job(geometry_request, *, source_bounds=Bounds(120, 20, 125, 35)):
    return MapJob(
        job_id="scope-test",
        status=JobStatus.QUEUED,
        request={"target": {"rendererFormatVersion": 3}},
        geometry=normalize_geometry(geometry_request),
        source_region=SourceRegion(
            id="china/region",
            name="Region",
            provider="geofabrik",
            bounds=source_bounds,
            url="https://download.geofabrik.de/example.osm.pbf",
        ),
    )


class BuildingScopeTests(unittest.TestCase):
    def plan(self, job, **kwargs):
        return plan_building_scope(
            job,
            calibration_cell_size_meters=8192,
            calibration_halo_cells=1,
            calibration_minimum_samples=3,
            **kwargs,
        )

    def test_bbox_plan_is_canonical_and_separates_source_from_calibration(self):
        job = make_job({"mode": "custom_bbox", "bbox": [121.45, 31.20, 121.50, 31.24]})
        first = self.plan(job)
        second = self.plan(job)
        self.assertEqual(first.canonical_bytes(), second.canonical_bytes())
        self.assertEqual(first.sha256, second.sha256)
        self.assertEqual(first.sha256, hashlib.sha256(first.canonical_bytes()).hexdigest())
        self.assertGreater(len(first.calibration_sample_cells), len(first.calibration_cells))
        self.assertLessEqual(first.document["metrics"]["sourceToOutputAreaBasisPoints"], 13_500)
        self.assertLess(first.document["metrics"]["sourceAreaM2"], BUILDING_MAX_SOURCE_AREA_M2)

    def test_default_policy_accepts_observed_348_square_kilometer_shanghai_scope(self):
        job = make_job({
            "mode": "custom_bbox",
            "bbox": [
                121.30632294659607,
                31.158348295222982,
                121.52266583255309,
                31.31010442485655,
            ],
        })

        plan = self.plan(job)

        self.assertEqual(BUILDING_SCOPE_POLICY_VERSION, 5)
        self.assertEqual(BUILDING_MAX_SOURCE_AREA_M2, 1_200_000_000)
        self.assertEqual(
            plan.document["policy"]["maxSourceAreaM2"], 1_200_000_000
        )
        self.assertEqual(
            plan.document["policy"]["maxRelationObjectsPerJob"], 500_000
        )
        self.assertEqual(
            plan.document["metrics"]["requestedApproximateAreaM2"],
            347_879_737,
        )
        self.assertEqual(plan.document["metrics"]["outputBlockCount"], 42)
        self.assertEqual(plan.document["metrics"]["outputAreaM2"], 704_643_072)
        self.assertEqual(plan.document["metrics"]["sourceAreaM2"], 732_168_192)

        with self.assertRaises(BuildingScopeError) as raised:
            self.plan(job, policy=BuildingScopePolicy(max_source_area_m2=732_000_000))
        self.assertEqual(raised.exception.code, "building_scope_exceeded")

    def test_relation_object_ceiling_can_be_temporarily_overridden(self):
        with patch.dict(
            os.environ,
            {"MAP_PLATFORM_BUILDING_MAX_RELATION_OBJECTS_PER_JOB": "600000"},
            clear=False,
        ):
            self.assertEqual(
                configured_building_max_relation_objects_per_job(), 600_000
            )
            plan = self.plan(
                make_job({
                    "mode": "custom_bbox",
                    "bbox": [
                        121.30632294659607,
                        31.158348295222982,
                        121.52266583255309,
                        31.31010442485655,
                    ],
                })
            )
            self.assertEqual(
                plan.document["policy"]["maxRelationObjectsPerJob"], 600_000
            )
            self.assertEqual(plan.summary()["maxRelationObjectsPerJob"], 600_000)

    def test_relation_object_ceiling_override_is_bounded(self):
        with patch.dict(
            os.environ,
            {"MAP_PLATFORM_BUILDING_MAX_RELATION_OBJECTS_PER_JOB": "2000001"},
            clear=False,
        ):
            with self.assertRaises(BuildingScopeError) as raised:
                configured_building_max_relation_objects_per_job()
            self.assertEqual(raised.exception.code, "building_scope_policy_invalid")

    def test_default_policy_accepts_source_scope_between_800_and_1200_square_kilometers(self):
        job = make_job({
            "mode": "custom_bbox",
            "bbox": [
                121.2738715137025,
                31.135584875777948,
                121.55511726544664,
                31.332867844301585,
            ],
        })

        plan = self.plan(job)

        self.assertEqual(plan.document["metrics"]["outputBlockCount"], 63)
        self.assertEqual(plan.document["metrics"]["outputAreaM2"], 1_056_964_608)
        self.assertEqual(plan.document["metrics"]["sourceAreaM2"], 1_090_781_184)

        with self.assertRaises(BuildingScopeError) as raised:
            self.plan(
                job,
                policy=BuildingScopePolicy(max_source_area_m2=1_090_000_000),
            )
        self.assertEqual(raised.exception.code, "building_scope_exceeded")

    def test_polygon_selects_only_intersecting_blocks(self):
        coordinates = [[121.45, 31.20], [121.50, 31.20], [121.50, 31.22], [121.45, 31.20]]
        polygon = make_job({"mode": "custom_polygon", "geometry": {"type": "Polygon", "coordinates": [coordinates]}})
        bbox = make_job({"mode": "custom_bbox", "bbox": polygon.geometry.bounds.to_list()})
        selected = self.plan(polygon)
        rectangular = self.plan(bbox)
        self.assertEqual(selected.output_blocks, tuple(sorted(selected.output_blocks)))
        self.assertLessEqual(len(selected.output_blocks), len(rectangular.output_blocks))

    def test_route_corridor_selects_a_stable_nonempty_block_set(self):
        job = make_job({
            "mode": "route_corridor",
            "route": [[121.45, 31.20], [121.50, 31.22]],
            "corridorWidthM": 200,
        })
        first = self.plan(job)
        second = self.plan(job)
        self.assertTrue(first.output_blocks)
        self.assertEqual(first.output_blocks, second.output_blocks)

    def test_scope_limit_fails_closed(self):
        job = make_job({"mode": "custom_bbox", "bbox": [121.45, 31.20, 121.50, 31.24]})
        with self.assertRaises(BuildingScopeError) as raised:
            self.plan(job, policy=BuildingScopePolicy(max_source_area_m2=1))
        self.assertEqual(raised.exception.code, "building_scope_exceeded")

    def test_source_region_must_cover_complete_output_blocks(self):
        request = {"mode": "custom_bbox", "bbox": [121.45, 31.20, 121.50, 31.24]}
        job = make_job(request, source_bounds=Bounds(121.45, 31.20, 121.50, 31.24))
        with self.assertRaises(BuildingScopeError) as raised:
            self.plan(job)
        self.assertEqual(raised.exception.code, "building_scope_exceeded")

    def test_diagonal_segment_does_not_claim_every_point_in_its_bbox(self):
        ring = [(0, 0), (10_000, 10_000), (10_000, 0), (0, 0)]
        self.assertFalse(point_in_ring((1_000, 9_000), ring))

    def test_route_buffer_uses_euclidean_distance_and_mercator_scale(self):
        self.assertGreater(mercator_scale(60), 1.99)
        self.assertGreater(segment_rectangle_distance((-200, -200), (-200, -200), (0, 0, 4096, 4096)), 256)

    def test_semantically_equivalent_polygon_order_has_one_scope_identity(self):
        first = make_job({
            "mode": "custom_polygon",
            "geometry": {"type": "MultiPolygon", "coordinates": [
                [[[121.45, 31.20], [121.46, 31.20], [121.46, 31.21], [121.45, 31.20]]],
                [[[121.49, 31.23], [121.50, 31.23], [121.50, 31.24], [121.49, 31.23]]],
            ]},
        })
        second = make_job({
            "mode": "custom_polygon",
            "geometry": {"type": "MultiPolygon", "coordinates": [
                [[[121.50, 31.24], [121.50, 31.23], [121.49, 31.23], [121.50, 31.24]]],
                [[[121.46, 31.21], [121.46, 31.20], [121.45, 31.20], [121.46, 31.21]]],
            ]},
        })
        self.assertEqual(self.plan(first).sha256, self.plan(second).sha256)

    def test_disjoint_multipolygon_uses_source_union_not_large_envelope_area(self):
        job = make_job({
            "mode": "custom_polygon",
            "geometry": {"type": "MultiPolygon", "coordinates": [
                [[[121.40, 31.20], [121.401, 31.20], [121.401, 31.201], [121.40, 31.20]]],
                [[[121.80, 31.50], [121.801, 31.50], [121.801, 31.501], [121.80, 31.50]]],
            ]},
        }, source_bounds=Bounds(120, 20, 125, 35))
        plan = self.plan(job)
        self.assertEqual(len(plan.output_blocks), 2)
        self.assertEqual(len(plan.document["sourceScope"]["rectanglesMeters"]), 2)
        self.assertLess(plan.document["metrics"]["sourceAreaM2"], 50_000_000)

    def test_scope_document_is_defensive_and_written_hash_is_verifiable(self):
        import tempfile
        plan = self.plan(make_job({"mode": "custom_bbox", "bbox": [121.45, 31.20, 121.50, 31.24]}))
        mutated = plan.document
        mutated["metrics"]["outputAreaM2"] = 1
        self.assertNotEqual(mutated, plan.document)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "scope.json"
            plan.write(path)
            written = json.loads(path.read_text())
        digest = written.pop("scopePlanSha256")
        encoded = json.dumps(written, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        self.assertEqual(hashlib.sha256(encoded).hexdigest(), digest)

    def test_unknown_block_grid_version_fails_closed(self):
        job = make_job({"mode": "custom_bbox", "bbox": [121.45, 31.20, 121.50, 31.24]})
        with self.assertRaises(BuildingScopeError) as raised:
            self.plan(job, policy=BuildingScopePolicy(block_grid_version=BUILDING_BLOCK_GRID_VERSION + 1))
        self.assertEqual(raised.exception.code, "building_scope_policy_invalid")

    def test_legacy_diagnostics_capture_cell_halo_expansion(self):
        job = make_job({"mode": "custom_bbox", "bbox": [121.45, 31.20, 121.50, 31.24]})
        legacy = legacy_building_scope_diagnostics(
            job,
            calibration_cell_size_meters=8192,
            calibration_halo_cells=1,
        )
        self.assertGreater(legacy["legacySourceAreaM2"], legacy["outputAreaM2"])
        self.assertGreater(legacy["legacySourceToOutputAreaBasisPoints"], 10_000)

    def test_scope_metrics_are_integer_canonical(self):
        plan = self.plan(make_job({"mode": "custom_bbox", "bbox": [121.45, 31.20, 121.50, 31.24]}))
        decoded = json.loads(plan.canonical_bytes())
        self.assertTrue(all(isinstance(value, int) for value in decoded["metrics"].values()))
        self.assertTrue(all(isinstance(value, int) for value in decoded["sourceScope"]["boundsMeters"]))

    def test_synthetic_shanghai_benchmark_replaces_the_legacy_cell_envelope(self):
        fixture = json.loads(
            (Path(__file__).parent / "fixtures" / "shanghai_24km2_scope.json").read_text()
        )
        job = make_job(fixture["request"])
        plan = self.plan(job)
        legacy = legacy_building_scope_diagnostics(
            job,
            calibration_cell_size_meters=8192,
            calibration_halo_cells=1,
        )
        expected = fixture["expected"]
        self.assertEqual(plan.document["metrics"]["requestedApproximateAreaM2"], expected["requestedApproximateAreaM2"])
        self.assertEqual(plan.document["metrics"]["outputAreaM2"], expected["outputAreaM2"])
        self.assertEqual(plan.document["metrics"]["sourceAreaM2"], expected["newSourceAreaM2"])
        # The legacy diagnostic round-trips integer Web-Mercator cell edges
        # through floating-point WGS-84 bounds. libm/Python combinations can
        # move an inverse-projected edge by one metre, so keep only this legacy
        # comparison approximate; the canonical selected metrics above remain
        # exact identity inputs.
        self.assertAlmostEqual(
            legacy["legacySourceAreaM2"],
            expected["legacySourceAreaM2"],
            delta=32_768,
        )
        self.assertEqual(len(plan.output_blocks), expected["outputBlockCount"])
        self.assertEqual(
            [[block.x, block.y] for block in plan.output_blocks],
            expected["outputBlocks"],
        )
        self.assertEqual(plan.document["policy"]["policyVersion"], expected["scopePolicyVersion"])
        self.assertEqual(plan.document["policy"]["blockGridVersion"], expected["blockGridVersion"])
        reduction_basis_points = (
            (legacy["legacySourceAreaM2"] - plan.document["metrics"]["sourceAreaM2"])
            * 10_000
            // legacy["legacySourceAreaM2"]
        )
        self.assertGreaterEqual(reduction_basis_points, expected["minimumLegacyReductionBasisPoints"])
        self.assertLessEqual(
            plan.document["metrics"]["sourceToOutputAreaBasisPoints"],
            expected["maximumSourceToOutputAreaBasisPoints"],
        )


if __name__ == "__main__":
    unittest.main()
