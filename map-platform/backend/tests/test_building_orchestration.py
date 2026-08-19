import json
import random
import tempfile
import unittest
from pathlib import Path

from map_platform.building_orchestration import (
    BlockWorkload,
    BuildingChunkPolicy,
    BuildingChunkPlanningError,
    BuildingPartitionPlan,
    deterministic_runtime_bisection,
    partition_global_building_plan,
)
from map_platform.building_scope import (
    GlobalBuildingPlanPolicy,
    plan_global_building_scope,
)
from map_platform.geometry import normalize_geometry
from map_platform.models import Bounds, JobStatus, MapJob, SourceRegion
from map_platform.reuse import MapBlock


def make_job(bbox):
    return MapJob(
        job_id="orchestration-test",
        status=JobStatus.QUEUED,
        request={"target": {"rendererFormatVersion": 3}},
        geometry=normalize_geometry({"mode": "custom_bbox", "bbox": bbox}),
        source_region=SourceRegion(
            id="china/region",
            name="Region",
            provider="geofabrik",
            bounds=Bounds(118, 29, 123, 33),
            url="https://download.geofabrik.de/example.osm.pbf",
        ),
    )


class BuildingOrchestrationTests(unittest.TestCase):
    def global_plan(self, bbox=(121.11, 30.8, 122.02, 31.29)):
        return plan_global_building_scope(
            make_job(bbox),
            calibration_cell_size_meters=8192,
            calibration_halo_cells=1,
            calibration_minimum_samples=3,
            global_policy=GlobalBuildingPlanPolicy(max_output_blocks=1024),
        )

    def test_full_shanghai_is_split_deterministically_without_exact_workload(self):
        plan = self.global_plan()
        first = partition_global_building_plan(plan)
        second = partition_global_building_plan(plan)
        self.assertEqual(first.canonical_bytes(), second.canonical_bytes())
        self.assertGreaterEqual(len(first.chunks), 7)
        self.assertEqual(sum(len(chunk.blocks) for chunk in first.chunks), 442)
        self.assertTrue(
            all(chunk.workload.requires_exact_workload_scan for chunk in first.chunks)
        )
        self.assertTrue(all(chunk.workload.hard_violations == () for chunk in first.chunks))

    def test_cache_hits_are_removed_from_heavy_chunks(self):
        plan = self.global_plan((121.30, 31.10, 121.57, 31.32))
        cached = plan.output_blocks[:3]
        workloads = {
            block: BlockWorkload(block=block, cache_hit=block in cached)
            for block in plan.output_blocks
        }
        partition = partition_global_building_plan(plan, workloads=workloads)
        self.assertEqual(partition.cache_hit_blocks, cached)
        self.assertNotIn(cached[0], {block for chunk in partition.chunks for block in chunk.blocks})

    def test_exact_closure_evidence_drives_recursive_split(self):
        plan = self.global_plan((121.30, 31.10, 121.57, 31.32))
        workloads = {
            block: BlockWorkload(
                block=block,
                closure_objects=20_000,
                estimated_wall_seconds=20,
            )
            for block in plan.output_blocks
        }
        policy = BuildingChunkPolicy(
            source_area_target_m2=1_000_000_000,
            closure_objects_target=50_000,
            closure_objects_hard=100_000,
            max_missing_building_blocks=48,
        )
        partition = partition_global_building_plan(
            plan,
            workloads=workloads,
            policy=policy,
        )
        self.assertGreater(len(partition.chunks), 1)
        self.assertTrue(all(chunk.workload.admissible for chunk in partition.chunks))
        self.assertTrue(
            all(
                chunk.workload.closure_objects is not None
                and chunk.workload.closure_objects <= policy.closure_objects_hard
                for chunk in partition.chunks
            )
        )

    def test_one_pathological_block_is_not_silently_accepted(self):
        plan = self.global_plan((121.30, 31.10, 121.33, 31.13))
        pathological = plan.output_blocks[0]
        workloads = {
            block: BlockWorkload(
                block=block,
                closure_objects=600_000 if block == pathological else 10,
                estimated_wall_seconds=10,
            )
            for block in plan.output_blocks
        }
        partition = partition_global_building_plan(plan, workloads=workloads)
        leaf = next(chunk for chunk in partition.chunks if pathological in chunk.blocks)
        self.assertEqual(leaf.blocks, (pathological,))
        self.assertIn("closure_objects", leaf.workload.hard_violations)
        self.assertFalse(leaf.workload.admissible)

    def test_workload_validation_rejects_unknown_block(self):
        plan = self.global_plan((121.30, 31.10, 121.33, 31.13))
        with self.assertRaises(BuildingChunkPlanningError):
            partition_global_building_plan(
                plan,
                workloads={
                    MapBlock(999, 999): BlockWorkload(block=MapBlock(999, 999))
                },
            )

    def test_runtime_bisection_prefers_longer_axis_and_is_stable(self):
        blocks = (MapBlock(8, 4), MapBlock(10, 4), MapBlock(9, 4), MapBlock(8, 5))
        left, right = deterministic_runtime_bisection(blocks)
        self.assertEqual(left, (MapBlock(8, 4), MapBlock(8, 5)))
        self.assertEqual(right, (MapBlock(9, 4), MapBlock(10, 4)))
        self.assertEqual(
            deterministic_runtime_bisection(tuple(reversed(blocks))),
            (left, right),
        )

    def test_runtime_bisection_fails_closed_for_one_block(self):
        with self.assertRaises(BuildingChunkPlanningError) as raised:
            deterministic_runtime_bisection((MapBlock(1, 1),))
        self.assertEqual(raised.exception.code, "building_pathological_block")

    def test_partition_hash_is_stable_under_workload_input_order(self):
        plan = self.global_plan((121.30, 31.10, 121.57, 31.32))
        entries = [
            (
                block,
                BlockWorkload(
                    block=block,
                    closure_objects=1000 + index,
                    estimated_wall_seconds=2,
                ),
            )
            for index, block in enumerate(plan.output_blocks)
        ]
        shuffled = list(entries)
        random.Random(42).shuffle(shuffled)
        first = partition_global_building_plan(plan, workloads=dict(entries))
        second = partition_global_building_plan(plan, workloads=dict(shuffled))
        self.assertEqual(first.sha256, second.sha256)
        self.assertEqual(json.loads(first.canonical_bytes()), json.loads(second.canonical_bytes()))

    def test_partition_plan_round_trips_for_resume(self):
        plan = self.global_plan((121.30, 31.10, 121.33, 31.13))
        partition = partition_global_building_plan(plan)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "partition-plan.json"
            partition.write(path)
            restored = BuildingPartitionPlan.read(
                path,
                global_plan_sha256=plan.sha256,
                expected_blocks=plan.output_blocks,
            )
        self.assertEqual(restored.sha256, partition.sha256)
        self.assertEqual(restored.canonical_bytes(), partition.canonical_bytes())


if __name__ == "__main__":
    unittest.main()
