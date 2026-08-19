from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace

from map_platform.building_tasks import (
    BuildingTaskSpec,
    BuildingTaskStore,
    BuildingTaskStoreError,
    StaleLeaseError,
    deterministic_building_task_id,
)
from map_platform.building_orchestration import partition_global_building_plan
from map_platform.building_scope import plan_global_building_scope
from map_platform.models import Bounds, GeometryMode, NormalizedGeometry, SourceRegion
from map_platform.pipeline import MapBuildPipeline, PipelinePaths


SHA = "a" * 64
CONTENT = "b" * 64


class Clock:
    def __init__(self):
        self.value = 100.0

    def __call__(self):
        return self.value


class BuildingTaskStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.clock = Clock()
        self.store = BuildingTaskStore(
            Path(self.temp.name) / "tasks.sqlite3", clock=self.clock
        )
        self.store.create_plan(
            parent_job_id="job-1",
            global_plan_sha256=SHA,
            input_identity={"source": "source-sha"},
            expected_output_block_count=3,
            policy_version=1,
            resource_model_version="v1",
        )

    def tearDown(self):
        self.temp.cleanup()

    def spec(self, task_id="task-1", blocks=((1, 2), (1, 3))):
        return BuildingTaskSpec(
            task_id=task_id,
            parent_job_id="job-1",
            kind="building_chunk",
            blocks=blocks,
            chunk_plan_sha256=SHA,
        )

    def test_claim_receipt_and_ready_are_fenced_and_durable(self):
        self.store.add_tasks([self.spec(blocks=((1, 2),))])
        claimed = self.store.claim_next(worker_id="worker-a", lease_seconds=10)
        self.assertIsNotNone(claimed)
        assert claimed is not None
        self.assertEqual(claimed.attempt_number, 1)
        attempts = self.store.list_attempts("job-1")
        self.assertEqual(len(attempts), 1)
        self.assertEqual(attempts[0]["task_id"], claimed.task.task_id)
        self.assertEqual(attempts[0]["outcome"], "leased")
        self.store.heartbeat(
            claimed.task.task_id,
            worker_id="worker-a",
            lease_token=claimed.lease_token,
            lease_seconds=10,
        )
        with self.assertRaises(StaleLeaseError):
            self.store.publish_receipt(
                claimed.task.task_id,
                worker_id="worker-b",
                lease_token=claimed.lease_token,
                block=(1, 2),
                cache_identity_sha256=SHA,
                content_sha256=CONTENT,
                producer_identity={"image": "sha256"},
                validation={"valid": True},
            )
        self.store.publish_receipt(
            claimed.task.task_id,
            worker_id="worker-a",
            lease_token=claimed.lease_token,
            block=(1, 2),
            cache_identity_sha256=SHA,
            content_sha256=CONTENT,
            producer_identity={"image": "sha256"},
            validation={"valid": True},
        )
        ready = self.store.mark_ready(
            claimed.task.task_id,
            worker_id="worker-a",
            lease_token=claimed.lease_token,
            actual_resource={"peakRssBytes": 10},
            peak_rss_bytes=10,
        )
        self.assertEqual(ready.state, "ready")
        self.assertRegex(ready.output_receipt_set_sha256 or "", r"^[0-9a-f]{64}$")
        self.assertEqual(len(self.store.list_receipts("job-1")), 1)

    def test_readding_the_same_task_is_idempotent_but_identity_changes_fail(self):
        spec = self.spec(blocks=((1, 2),))
        self.store.add_tasks([spec])
        self.store.add_tasks([spec])
        with self.assertRaises(BuildingTaskStoreError):
            self.store.add_tasks(
                [
                    BuildingTaskSpec(
                        task_id=spec.task_id,
                        parent_job_id=spec.parent_job_id,
                        kind="different_kind",
                        blocks=spec.blocks,
                        chunk_plan_sha256=spec.chunk_plan_sha256,
                    )
                ]
            )

    def test_deterministic_task_id_is_order_independent(self):
        first = deterministic_building_task_id(
            parent_job_id="job-1",
            kind="building_chunk",
            blocks=((2, 1), (1, 1)),
            chunk_plan_sha256=SHA,
        )
        second = deterministic_building_task_id(
            parent_job_id="job-1",
            kind="building_chunk",
            blocks=((1, 1), (2, 1)),
            chunk_plan_sha256=SHA,
        )
        self.assertEqual(first, second)

    def test_shadow_partition_persists_scan_tasks_without_execution(self):
        geometry = NormalizedGeometry(
            mode=GeometryMode.CUSTOM_BBOX,
            bounds=Bounds(121.11, 30.8, 121.2, 30.9),
            area_km2=100.0,
            vertex_count=0,
        )
        source_region = SourceRegion(
            id="china",
            provider="test",
            name="China",
            url="https://example.invalid/china.pbf",
            bounds=Bounds(120.0, 30.0, 123.0, 32.0),
            checksum="c" * 64,
        )
        job = SimpleNamespace(
            job_id="job-shadow",
            request={"target": {"format": 3}},
            geometry=geometry,
            source_region=source_region,
        )
        global_plan = plan_global_building_scope(
            job,
            calibration_cell_size_meters=10_000,
            calibration_halo_cells=1,
            calibration_minimum_samples=20,
        )
        partition = partition_global_building_plan(global_plan)
        with tempfile.TemporaryDirectory() as tmp:
            store = BuildingTaskStore(Path(tmp) / "tasks.sqlite3")
            pipeline = MapBuildPipeline(
                PipelinePaths(
                    Path(__file__).resolve().parents[3],
                    Path(tmp) / "work",
                    Path(tmp) / "packs",
                ),
                building_task_store=store,
            )
            pipeline._persist_shadow_building_partition(
                job,
                global_plan=global_plan,
                partition=partition,
            )
            self.assertEqual(
                store.get_plan("job-shadow")["global_plan_sha256"],
                global_plan.sha256,
            )
            tasks = store.list_tasks("job-shadow")
            self.assertEqual(len(tasks), len(partition.chunks))
            self.assertTrue(all(task.kind == "building_workload_scan" for task in tasks))

    def test_ready_requires_every_assigned_receipt(self):
        self.store.add_tasks([self.spec()])
        claimed = self.store.claim_next(worker_id="worker-a")
        assert claimed is not None
        with self.assertRaises(BuildingTaskStoreError):
            self.store.mark_ready(
                claimed.task.task_id,
                worker_id="worker-a",
                lease_token=claimed.lease_token,
            )

    def test_expired_lease_returns_task_to_pending_and_fences_old_worker(self):
        self.store.add_tasks([self.spec(blocks=((1, 2),))])
        claimed = self.store.claim_next(worker_id="worker-a", lease_seconds=5)
        assert claimed is not None
        self.clock.value = 106
        self.assertEqual(self.store.recover_expired(), 1)
        with self.assertRaises(StaleLeaseError):
            self.store.heartbeat(
                claimed.task.task_id,
                worker_id="worker-a",
                lease_token=claimed.lease_token,
            )
        retry = self.store.claim_next(worker_id="worker-b")
        self.assertIsNotNone(retry)
        assert retry is not None
        self.assertEqual(retry.attempt_number, 2)

    def test_split_reassigns_block_ownership_and_preserves_parent_audit(self):
        self.store.add_tasks([self.spec(blocks=((1, 2), (1, 3), (1, 4)))])
        claimed = self.store.claim_next(worker_id="worker-a")
        assert claimed is not None
        children = self.store.split(
            claimed.task.task_id,
            worker_id="worker-a",
            lease_token=claimed.lease_token,
            reason="building_object_limit_exceeded",
            children=[
                self.spec("child-a", ((1, 2),)),
                self.spec("child-b", ((1, 3), (1, 4))),
            ],
        )
        self.assertEqual(len(children), 2)
        states = {task.task_id: task.state for task in self.store.list_tasks("job-1")}
        self.assertEqual(states["task-1"], "split")
        self.assertEqual(states["child-a"], "pending")
        self.assertEqual(states["child-b"], "pending")

    def test_cancel_fences_active_task(self):
        self.store.add_tasks([self.spec(blocks=((1, 2),))])
        claimed = self.store.claim_next(worker_id="worker-a")
        assert claimed is not None
        self.store.cancel_plan("job-1")
        with self.assertRaises(StaleLeaseError):
            self.store.publish_receipt(
                claimed.task.task_id,
                worker_id="worker-a",
                lease_token=claimed.lease_token,
                block=(1, 2),
                cache_identity_sha256=SHA,
                content_sha256=CONTENT,
                producer_identity={},
                validation={},
            )
        self.assertEqual(self.store.get_plan("job-1")["state"], "cancelled")

    def test_duplicate_block_ownership_is_rejected(self):
        self.store.add_tasks([self.spec(blocks=((1, 2),))])
        with self.assertRaises(Exception):
            self.store.add_tasks([self.spec("task-2", ((1, 2),))])


if __name__ == "__main__":
    unittest.main()
