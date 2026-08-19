import hashlib
import json
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
from map_platform.building_scope import canonical_json
from map_platform.reuse import MapBlock


SHA = "a" * 64
CONTENT = "b" * 64


def workload_receipt():
    return {
        "schemaVersion": 1,
        "sourceIndexKey": "c" * 64,
        "sourceSnapshotSha256": "d" * 64,
        "candidateKeys": ["w1"],
        "requiredRelationKeys": ["r1"],
        "requiredWayKeys": ["w1"],
        "requiredNodeKeys": ["n1", "n2"],
        "calibrationTargetCells": [[1, 2]],
        "calibrationSampleCells": [[0, 1], [1, 2]],
        "closurePlanSha256": "e" * 64,
        "relationCount": 1,
        "wayCount": 1,
        "nodeCount": 2,
        "totalObjectCount": 4,
        "storedRelationMemberCount": 1,
        "wayNodeReferenceCount": 2,
        "vertexCount": 2,
        "candidateOutlineCount": 1,
        "candidatePartCount": 0,
        "ringCount": None,
        "holeCount": None,
    }


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

    def test_parent_stage_and_progress_are_monotonic_and_receipt_based(self):
        self.store.add_tasks([self.spec(blocks=((1, 2),))])
        stage = self.store.set_plan_stage("job-1", stage="building_chunks")
        self.assertEqual(stage["stage"], "building_chunks")
        with self.assertRaises(BuildingTaskStoreError):
            self.store.set_plan_stage("job-1", stage="chunk_planning")
        claimed = self.store.claim_next(worker_id="worker-a")
        assert claimed is not None
        self.store.publish_receipt(
            claimed.task.task_id,
            worker_id="worker-a",
            lease_token=claimed.lease_token,
            block=(1, 2),
            cache_identity_sha256=SHA,
            content_sha256=CONTENT,
            producer_identity={},
            validation={"valid": True},
        )
        self.store.mark_ready(
            claimed.task.task_id,
            worker_id="worker-a",
            lease_token=claimed.lease_token,
        )
        progress = self.store.progress("job-1")
        self.assertEqual(progress["completedBlocks"], 1)
        self.assertEqual(progress["totalBlocks"], 3)
        self.assertEqual(progress["readyChunks"], 1)
        self.assertEqual(progress["totalChunks"], 1)
        self.assertFalse(progress["indeterminate"])

    def test_memory_capability_admission_skips_heavy_task(self):
        self.store.add_tasks(
            [
                BuildingTaskSpec(
                    task_id="heavy-task",
                    parent_job_id="job-1",
                    kind="building_chunk",
                    blocks=((1, 2),),
                    chunk_plan_sha256=SHA,
                    predicted_resource={"estimatedPeakMemoryBytes": 4_000_000_000},
                )
            ]
        )
        self.assertIsNone(
            self.store.claim_next(
                worker_id="small-worker",
                worker_capability={"memoryLimitBytes": 4_000_000_000},
            )
        )
        claimed = self.store.claim_next(
            worker_id="large-worker",
            worker_capability={"memoryLimitBytes": 8_000_000_000},
        )
        self.assertIsNotNone(claimed)
        attempts = self.store.list_attempts("job-1")
        admission = json.loads(attempts[0]["worker_capability_json"])["admission"]
        self.assertEqual(admission["memoryLimitBytes"], 8_000_000_000)
        self.assertEqual(admission["memoryReservationBytes"], 4_000_000_000)

    def test_resource_reservation_defaults_to_one_heavy_task_and_releases(self):
        self.store.add_tasks(
            [
                self.spec("task-1", ((1, 2),)),
                self.spec("task-2", ((1, 3),)),
            ]
        )
        capability = {
            "resourcePool": "coolify-worker-a",
            "memoryLimitBytes": 8_000_000_000,
            "cpuCount": 8,
        }
        first = self.store.claim_next(
            worker_id="worker-a", worker_capability=capability
        )
        self.assertIsNotNone(first)
        assert first is not None
        self.assertEqual(len(self.store.list_resource_reservations("job-1")), 1)
        self.assertIsNone(
            self.store.claim_next(worker_id="worker-b", worker_capability=capability)
        )
        self.store.publish_receipt(
            first.task.task_id,
            worker_id="worker-a",
            lease_token=first.lease_token,
            block=(1, 2),
            cache_identity_sha256=SHA,
            content_sha256=CONTENT,
            producer_identity={},
            validation={"valid": True},
        )
        self.store.mark_ready(
            first.task.task_id,
            worker_id="worker-a",
            lease_token=first.lease_token,
        )
        self.assertEqual(self.store.list_resource_reservations("job-1"), ())
        self.assertIsNotNone(
            self.store.claim_next(worker_id="worker-b", worker_capability=capability)
        )

    def test_resource_reservation_recovery_and_memory_sum_are_fenced(self):
        self.store.add_tasks(
            [
                BuildingTaskSpec(
                    task_id="task-1",
                    parent_job_id="job-1",
                    kind="building_chunk",
                    blocks=((1, 2),),
                    chunk_plan_sha256=SHA,
                    predicted_resource={"estimatedPeakMemoryBytes": 4_000_000_000},
                ),
                BuildingTaskSpec(
                    task_id="task-2",
                    parent_job_id="job-1",
                    kind="building_chunk",
                    blocks=((1, 3),),
                    chunk_plan_sha256=SHA,
                    predicted_resource={"estimatedPeakMemoryBytes": 4_000_000_000},
                ),
            ]
        )
        capability = {
            "resourcePool": "coolify-worker-b",
            "memoryLimitBytes": 8_000_000_000,
            "cpuCount": 8,
            "maxConcurrentTasks": 2,
        }
        first = self.store.claim_next(
            worker_id="worker-a", lease_seconds=10, worker_capability=capability
        )
        self.assertIsNotNone(first)
        self.assertIsNone(
            self.store.claim_next(worker_id="worker-b", worker_capability=capability)
        )
        self.clock.value = 111
        self.assertEqual(self.store.recover_expired(now=111), 1)
        self.assertEqual(self.store.list_resource_reservations("job-1"), ())
        self.assertIsNotNone(
            self.store.claim_next(worker_id="worker-b", worker_capability=capability)
        )

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

    def test_workload_scan_receipt_is_durable_and_promotes_chunk(self):
        self.store.add_tasks(
            [
                BuildingTaskSpec(
                    task_id="scan-1",
                    parent_job_id="job-1",
                    kind="building_workload_scan",
                    blocks=((1, 2),),
                    chunk_plan_sha256=SHA,
                    predicted_resource={"requiresExactWorkloadScan": True},
                )
            ]
        )
        claimed = self.store.claim_next(worker_id="scanner", lease_seconds=10)
        assert claimed is not None
        promoted = self.store.complete_workload_scan(
            claimed.task.task_id,
            worker_id="scanner",
            lease_token=claimed.lease_token,
            workload_receipt=workload_receipt(),
            actual_resource={"peakRssBytes": 123},
            peak_rss_bytes=123,
        )
        self.assertEqual(promoted.kind, "building_chunk")
        self.assertEqual(promoted.state, "pending")
        self.assertEqual(promoted.closure_plan_sha256, "e" * 64)
        self.assertEqual(
            promoted.predicted_resource["workloadReceipt"]["totalObjectCount"],
            4,
        )
        receipts = self.store.list_workload_receipts("job-1")
        self.assertEqual(len(receipts), 1)
        self.assertEqual(receipts[0]["closure_plan_sha256"], "e" * 64)
        self.assertEqual(self.store.list_attempts("job-1")[0]["outcome"], "workload_scanned")

    def test_workload_scan_rejects_inconsistent_object_totals(self):
        self.store.add_tasks(
            [
                BuildingTaskSpec(
                    task_id="scan-2",
                    parent_job_id="job-1",
                    kind="building_workload_scan",
                    blocks=((1, 2),),
                    chunk_plan_sha256=SHA,
                )
            ]
        )
        claimed = self.store.claim_next(worker_id="scanner")
        assert claimed is not None
        invalid = workload_receipt()
        invalid["totalObjectCount"] = 3
        with self.assertRaises(BuildingTaskStoreError):
            self.store.complete_workload_scan(
                claimed.task.task_id,
                worker_id="scanner",
                lease_token=claimed.lease_token,
                workload_receipt=invalid,
            )

    def test_chunk_receipts_are_reread_from_cache_before_publication(self):
        block = MapBlock(12, 34)
        spec = self.spec(blocks=((block.x, block.y),))
        self.store.add_tasks([spec])
        claimed = self.store.claim_next(worker_id="builder")
        assert claimed is not None
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cache_root = root / "building-cache"
            identity_body = {
                "sourceSnapshotSha256": "c" * 64,
                "rulesSha256": "d" * 64,
            }
            identity_sha = hashlib.sha256(canonical_json(identity_body)).hexdigest()
            identity = {**identity_body, "cacheIdentitySha256": identity_sha}
            namespace = (
                cache_root
                / "building-block-v1"
                / identity_body["sourceSnapshotSha256"]
                / identity_body["rulesSha256"]
                / identity_sha
            )
            section = b"chunk-section"
            section_sha = hashlib.sha256(section).hexdigest()
            body = {
                "schemaVersion": 1,
                "cacheIdentitySha256": identity_sha,
                "block": {
                    "x": block.x,
                    "y": block.y,
                    "boundsMeters": [
                        block.x * 4096,
                        block.y * 4096,
                        (block.x + 1) * 4096,
                        (block.y + 1) * 4096,
                    ],
                },
                "section": {
                    "path": f"sections/{section_sha}.bin",
                    "bytes": len(section),
                    "sha256": section_sha,
                },
                "stats": {"recordCount": 0, "sectionBytes": len(section)},
            }
            manifest = {
                **body,
                "manifestSha256": hashlib.sha256(canonical_json(body)).hexdigest(),
            }
            (namespace / "blocks").mkdir(parents=True)
            (namespace / "sections").mkdir()
            (namespace / "sections" / f"{section_sha}.bin").write_bytes(section)
            identity_path = root / "cache-identity.json"
            identity_path.write_bytes(canonical_json(identity))
            (namespace / "blocks" / f"{block.x}_{block.y}.json").write_bytes(
                canonical_json(manifest)
            )
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                building_task_store=self.store,
            )
            result = pipeline.publish_building_chunk_receipts(
                task_id=claimed.task.task_id,
                worker_id="builder",
                lease_token=claimed.lease_token,
                cache_identity_path=identity_path,
                blocks=[block],
            )
            self.assertEqual(result["receiptCount"], 1)
            ready = self.store.mark_ready(
                claimed.task.task_id,
                worker_id="builder",
                lease_token=claimed.lease_token,
            )
            self.assertEqual(ready.state, "ready")

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
