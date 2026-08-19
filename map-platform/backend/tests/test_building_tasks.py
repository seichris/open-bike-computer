import hashlib
import json
from pathlib import Path
import sqlite3
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

    def test_failed_parent_reopens_for_job_retry_without_discarding_history(self):
        self.store.add_tasks([self.spec(blocks=((1, 2),))])
        claimed = self.store.claim_next(worker_id="worker-a")
        self.assertIsNotNone(claimed)
        assert claimed is not None
        self.store.fail(
            claimed.task.task_id,
            worker_id="worker-a",
            lease_token=claimed.lease_token,
            typed_failure="building_chunk_execution_failed",
            transient=False,
        )
        self.store.set_plan_stage("job-1", stage="failed", state="failed")

        reopened = self.store.reopen_failed_plan("job-1")

        self.assertEqual(reopened["state"], "chunk_planning")
        self.assertEqual(self.store.get_task("task-1").state, "pending")
        self.assertEqual(len(self.store.list_attempts("job-1")), 1)

    def test_terminal_retention_prunes_failed_history_but_not_cache_policy(self):
        self.store.add_tasks([self.spec(blocks=((1, 2),))])
        claimed = self.store.claim_next(worker_id="worker-a")
        assert claimed is not None
        self.store.fail(
            claimed.task.task_id,
            worker_id="worker-a",
            lease_token=claimed.lease_token,
            typed_failure="building_chunk_execution_failed",
            transient=False,
        )
        self.store.set_plan_stage("job-1", stage="failed", state="failed")

        result = self.store.prune_terminal_evidence(
            older_than_days=1,
            max_plans=10,
            now=100.0 + 86_401,
        )

        self.assertEqual(result["removedPlans"], 1)
        self.assertEqual(result["removedTasks"], 1)
        self.assertEqual(result["removedAttempts"], 1)
        self.assertIsNone(self.store.get_plan("job-1"))

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
            block=first.task.blocks[0],
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

    def test_resource_claims_round_robin_across_parent_jobs(self):
        self.store.create_plan(
            parent_job_id="job-2",
            global_plan_sha256="b" * 64,
            input_identity={"source": "source-sha-2"},
            expected_output_block_count=2,
            policy_version=1,
            resource_model_version="v1",
        )
        self.store.add_tasks(
            [
                self.spec("job-1-task-1", ((1, 2),)),
                self.spec("job-1-task-2", ((1, 3),)),
                BuildingTaskSpec(
                    task_id="job-2-task-1",
                    parent_job_id="job-2",
                    kind="building_chunk",
                    blocks=((2, 2),),
                    chunk_plan_sha256=SHA,
                ),
                BuildingTaskSpec(
                    task_id="job-2-task-2",
                    parent_job_id="job-2",
                    kind="building_chunk",
                    blocks=((2, 3),),
                    chunk_plan_sha256=SHA,
                ),
            ]
        )
        capability = {
            "resourcePool": "fair-pool",
            "memoryLimitBytes": 8_000_000_000,
            "cpuCount": 8,
            "maxConcurrentTasks": 4,
        }

        claimed = [
            self.store.claim_next(
                worker_id=f"worker-{index}",
                worker_capability=capability,
            )
            for index in range(4)
        ]

        self.assertEqual(
            [item.task.parent_job_id for item in claimed if item is not None],
            ["job-1", "job-2", "job-1", "job-2"],
        )
        self.assertEqual(
            [
                plan["last_claimed_at"]
                for plan in (
                    self.store.get_plan("job-1"),
                    self.store.get_plan("job-2"),
                )
            ],
            [100.0, 100.0],
        )

    def test_schema_v3_migrates_fair_claim_cursor(self):
        path = Path(self.temp.name) / "legacy-tasks.sqlite3"
        connection = sqlite3.connect(path)
        connection.executescript(
            """
            CREATE TABLE map_build_plans(
                parent_job_id TEXT PRIMARY KEY,
                global_plan_sha256 TEXT NOT NULL,
                input_identity_json TEXT NOT NULL,
                stage TEXT NOT NULL,
                state TEXT NOT NULL,
                expected_output_block_count INTEGER NOT NULL,
                policy_version INTEGER NOT NULL,
                resource_model_version TEXT NOT NULL,
                cancellation_generation INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            PRAGMA user_version=3;
            """
        )
        connection.close()

        BuildingTaskStore(path)

        connection = sqlite3.connect(path)
        columns = {
            row[1]
            for row in connection.execute("PRAGMA table_info(map_build_plans)")
        }
        version = connection.execute("PRAGMA user_version").fetchone()[0]
        connection.close()
        self.assertIn("last_claimed_at", columns)
        self.assertEqual(version, 5)

    def test_weighted_virtual_finish_and_active_parent_quota_prevent_monopoly(self):
        self.store.create_plan(
            parent_job_id="job-weighted",
            global_plan_sha256="b" * 64,
            input_identity={"source": "weighted"},
            expected_output_block_count=3,
            policy_version=1,
            resource_model_version="v1",
            scheduling_weight=1,
            active_task_quota=1,
        )
        self.store.add_tasks(
            [
                BuildingTaskSpec(
                    task_id="weighted-small",
                    parent_job_id="job-weighted",
                    kind="building_chunk",
                    blocks=((2, 2),),
                    chunk_plan_sha256="b" * 64,
                ),
                BuildingTaskSpec(
                    task_id="weighted-small-2",
                    parent_job_id="job-weighted",
                    kind="building_chunk",
                    blocks=((2, 3),),
                    chunk_plan_sha256="b" * 64,
                ),
            ]
        )
        capability = {
            "resourcePool": "weighted-pool",
            "memoryLimitBytes": 8_000_000_000,
            "cpuCount": 8,
            "maxConcurrentTasks": 2,
        }
        first = self.store.claim_next(worker_id="worker-a", worker_capability=capability)
        self.assertIsNotNone(first)
        assert first is not None
        self.assertEqual(first.task.parent_job_id, "job-weighted")
        # The parent-specific quota blocks a second lease even though the pool
        # has a second slot. Completing the first task makes the next claim
        # eligible and weighted virtual finish prefers the smaller parent.
        self.assertIsNone(
            self.store.claim_next(worker_id="worker-b", worker_capability=capability)
        )
        self.store.publish_receipt(
            first.task.task_id,
            worker_id="worker-a",
            lease_token=first.lease_token,
            block=first.task.blocks[0],
            cache_identity_sha256=SHA,
            content_sha256=CONTENT,
            producer_identity={},
            validation={},
        )
        # Fail it to release the reservation and exercise the scheduler
        # handoff to the next weighted task.
        self.store.fail(
            first.task.task_id,
            worker_id="worker-a",
            lease_token=first.lease_token,
            typed_failure="test_scheduler_release",
            transient=False,
        )
        second = self.store.claim_next(worker_id="worker-b", worker_capability=capability)
        self.assertIsNotNone(second)
        assert second is not None
        self.assertEqual(second.task.parent_job_id, "job-weighted")

    def test_receipt_set_identity_is_complete_and_block_ordered(self):
        path = Path(self.temp.name) / "receipt-identity.sqlite3"
        store = BuildingTaskStore(path, clock=self.clock)
        store.create_plan(
            parent_job_id="job-receipts",
            global_plan_sha256=SHA,
            input_identity={},
            expected_output_block_count=2,
            policy_version=1,
            resource_model_version="v1",
        )
        store.add_tasks(
            [
                BuildingTaskSpec(
                    task_id="receipt-a",
                    parent_job_id="job-receipts",
                    kind="building_chunk",
                    blocks=((2, 2),),
                    chunk_plan_sha256=SHA,
                ),
                BuildingTaskSpec(
                    task_id="receipt-b",
                    parent_job_id="job-receipts",
                    kind="building_chunk",
                    blocks=((1, 1),),
                    chunk_plan_sha256=SHA,
                ),
            ]
        )
        for worker, block in (("worker-a", (2, 2)), ("worker-b", (1, 1))):
            claimed = store.claim_next(worker_id=worker)
            self.assertIsNotNone(claimed)
            assert claimed is not None
            store.publish_receipt(
                claimed.task.task_id,
                worker_id=worker,
                lease_token=claimed.lease_token,
                block=block,
                cache_identity_sha256=SHA,
                content_sha256=CONTENT,
                producer_identity={},
                validation={},
            )
            store.mark_ready(
                claimed.task.task_id,
                worker_id=worker,
                lease_token=claimed.lease_token,
            )

        identity = store.receipt_set_sha256("job-receipts")

        self.assertRegex(identity or "", r"^[0-9a-f]{64}$")
        self.assertIsNone(self.store.receipt_set_sha256("job-1"))

    def test_receipt_set_identity_is_partition_invariant_across_task_layouts(self):
        def build_store(path, specs):
            store = BuildingTaskStore(path, clock=self.clock)
            store.create_plan(
                parent_job_id="job-layout",
                global_plan_sha256=SHA,
                input_identity={"globalPlan": SHA},
                expected_output_block_count=3,
                policy_version=1,
                resource_model_version="v1",
            )
            store.add_tasks(specs)
            for worker in ("worker-a", "worker-b", "worker-c"):
                claimed = store.claim_next(worker_id=worker)
                if claimed is None:
                    break
                for block in claimed.task.blocks:
                    store.publish_receipt(
                        claimed.task.task_id,
                        worker_id=worker,
                        lease_token=claimed.lease_token,
                        block=block,
                        cache_identity_sha256=SHA,
                        content_sha256=CONTENT,
                        producer_identity={"producer": "same"},
                        validation={"valid": True},
                    )
                store.mark_ready(
                    claimed.task.task_id,
                    worker_id=worker,
                    lease_token=claimed.lease_token,
                )
            return store

        with tempfile.TemporaryDirectory() as directory:
            first = build_store(
                Path(directory) / "first.sqlite3",
                [
                    BuildingTaskSpec(
                        task_id="first-a",
                        parent_job_id="job-layout",
                        kind="building_chunk",
                        blocks=((2, 2), (1, 1)),
                        chunk_plan_sha256=SHA,
                    ),
                    BuildingTaskSpec(
                        task_id="first-b",
                        parent_job_id="job-layout",
                        kind="building_chunk",
                        blocks=((3, 3),),
                        chunk_plan_sha256=SHA,
                    ),
                ],
            )
            second = build_store(
                Path(directory) / "second.sqlite3",
                [
                    BuildingTaskSpec(
                        task_id="second-a",
                        parent_job_id="job-layout",
                        kind="building_chunk",
                        blocks=((3, 3), (1, 1)),
                        chunk_plan_sha256=SHA,
                    ),
                    BuildingTaskSpec(
                        task_id="second-b",
                        parent_job_id="job-layout",
                        kind="building_chunk",
                        blocks=((2, 2),),
                        chunk_plan_sha256=SHA,
                    ),
                ],
            )
            self.assertEqual(
                first.receipt_set_sha256("job-layout"),
                second.receipt_set_sha256("job-layout"),
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
        self.assertGreater(
            promoted.predicted_resource["estimatedPeakMemoryBytes"], 0
        )
        self.assertEqual(
            promoted.predicted_resource["memoryEstimateSource"],
            "conservative-counter-floor-v1",
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

    def test_runtime_split_enqueues_deterministic_workload_scans(self):
        self.store.add_tasks(
            [self.spec(blocks=((1, 2), (1, 3), (1, 4), (1, 5)))]
        )
        claimed = self.store.claim_next(worker_id="worker-a")
        assert claimed is not None
        children = self.store.split_runtime_task(
            claimed.task.task_id,
            worker_id="worker-a",
            lease_token=claimed.lease_token,
            reason="building_object_limit_exceeded",
        )
        self.assertEqual(len(children), 2)
        self.assertTrue(
            all(child.kind == "building_workload_scan" for child in children)
        )
        self.assertEqual(
            tuple(sorted(block for child in children for block in child.blocks)),
            ((1, 2), (1, 3), (1, 4), (1, 5)),
        )
        self.assertEqual(
            [child.task_id for child in children],
            [
                deterministic_building_task_id(
                    parent_job_id="job-1",
                    kind="building_workload_scan",
                    blocks=child.blocks,
                    chunk_plan_sha256=SHA,
                    split_depth=1,
                )
                for child in children
            ],
        )
        parent = self.store.get_task("task-1")
        self.assertIsNotNone(parent)
        assert parent is not None
        self.assertEqual(parent.state, "split")

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
        attempts = self.store.list_attempts("job-1")
        self.assertEqual(attempts[0]["outcome"], "cancelled")
        self.assertEqual(attempts[0]["typed_failure"], "building_task_cancelled")
        self.assertIsNotNone(attempts[0]["finished_at"])
        self.store.cancel_plan("job-1")

    def test_cancel_does_not_rewrite_ready_plan(self):
        self.store.add_tasks([self.spec(blocks=((1, 2),))])
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
            validation={},
        )
        self.store.mark_ready(
            claimed.task.task_id,
            worker_id="worker-a",
            lease_token=claimed.lease_token,
        )
        self.store.set_plan_stage("job-1", stage="ready", state="ready")

        self.store.cancel_plan("job-1")

        self.assertEqual(self.store.get_plan("job-1")["state"], "ready")

    def test_reconcile_cancelled_plan_releases_legacy_reservation(self):
        self.store.add_tasks([self.spec(blocks=((1, 2),))])
        claimed = self.store.claim_next(
            worker_id="worker-a",
            worker_capability={
                "resourcePool": "pool-a",
                "memoryLimitBytes": 8_000_000_000,
                "cpuCount": 8,
            },
        )
        self.assertIsNotNone(claimed)
        self.assertEqual(len(self.store.list_resource_reservations("job-1")), 1)

        self.assertEqual(self.store.reconcile_cancelled_plans(("job-1",)), 1)

        self.assertEqual(self.store.get_plan("job-1")["state"], "cancelled")
        self.assertEqual(self.store.get_task("task-1").state, "cancelled")
        self.assertEqual(self.store.list_resource_reservations("job-1"), ())
        self.assertEqual(self.store.reconcile_cancelled_plans(("job-1",)), 0)

    def test_duplicate_block_ownership_is_rejected(self):
        self.store.add_tasks([self.spec(blocks=((1, 2),))])
        with self.assertRaises(Exception):
            self.store.add_tasks([self.spec("task-2", ((1, 2),))])


if __name__ == "__main__":
    unittest.main()
