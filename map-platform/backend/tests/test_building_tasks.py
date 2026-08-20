import hashlib
import json
from dataclasses import asdict
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
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
from map_platform.pipeline import MapBuildPipeline, PipelinePaths, _TaskLeaseHeartbeat
from map_platform.pipeline import (
    BuildingChunkRetryExhausted,
    BuildingChunkSchedulingYield,
    _ParentPhaseLeaseHeartbeat,
)
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

    def test_active_cache_references_drive_fail_closed_retention_protection(self):
        self.store.add_tasks(
            [
                BuildingTaskSpec(
                    task_id="cache-task",
                    parent_job_id="job-1",
                    kind="building_chunk",
                    blocks=((1, 2),),
                    chunk_plan_sha256=SHA,
                    predicted_resource={
                        "cacheHit": True,
                        "cacheIdentitySha256": SHA,
                    },
                )
            ]
        )

        protection = self.store.cache_retention_protection()

        self.assertEqual(
            protection["protectedCacheIdentitySha256s"], (SHA,)
        )
        self.assertFalse(protection["protectAll"])

        self.store.add_tasks(
            [
                BuildingTaskSpec(
                    task_id="legacy-cache-task",
                    parent_job_id="job-1",
                    kind="building_chunk",
                    blocks=((1, 3),),
                    chunk_plan_sha256=SHA,
                    predicted_resource={"cacheHit": True},
                )
            ]
        )
        self.assertTrue(self.store.cache_retention_protection()["protectAll"])

    def test_eviction_before_cache_hit_atomically_requeues_leased_task(self):
        self.store.add_tasks(
            [
                BuildingTaskSpec(
                    task_id="cache-task",
                    parent_job_id="job-1",
                    kind="building_chunk",
                    blocks=((1, 2),),
                    chunk_plan_sha256=SHA,
                    predicted_resource={
                        "cacheHit": True,
                        "cacheIdentitySha256": SHA,
                        "estimatedPeakMemoryBytes": 0,
                    },
                )
            ]
        )
        claimed = self.store.claim_next(worker_id="cache-worker")
        assert claimed is not None
        self.store.publish_receipt(
            claimed.task.task_id,
            worker_id="cache-worker",
            lease_token=claimed.lease_token,
            block=(1, 2),
            cache_identity_sha256=SHA,
            content_sha256=CONTENT,
            producer_identity={},
            validation={"cacheHit": True},
        )

        requeued = self.store.invalidate_cache_for_retry(
            "job-1",
            blocks=((1, 2),),
            cache_identity_sha256=SHA,
            typed_failure="building_block_cache_missing",
            task_id=claimed.task.task_id,
            worker_id="cache-worker",
            lease_token=claimed.lease_token,
        )

        self.assertEqual(len(requeued), 1)
        self.assertEqual(requeued[0].state, "pending")
        self.assertNotIn("cacheHit", requeued[0].predicted_resource)
        self.assertGreater(
            requeued[0].predicted_resource["estimatedPeakMemoryBytes"], 0
        )
        self.assertEqual(self.store.list_receipts("job-1"), ())
        self.assertEqual(self.store.get_plan("job-1")["state"], "building_chunks")
        attempt = self.store.list_attempts("job-1")[0]
        self.assertEqual(attempt["outcome"], "cache_invalidated")
        self.assertEqual(
            attempt["typed_failure"], "building_block_cache_missing"
        )
        self.assertIsNotNone(self.store.claim_next(worker_id="build-worker"))

    def test_task_lease_heartbeat_refreshes_long_running_child(self):
        self.store.add_tasks([self.spec(blocks=((1, 2),))])
        claimed = self.store.claim_next(worker_id="worker-a", lease_seconds=10)
        self.assertIsNotNone(claimed)
        assert claimed is not None
        initial = claimed.task.heartbeat_at
        heartbeat = _TaskLeaseHeartbeat(
            self.store,
            task_id=claimed.task.task_id,
            worker_id="worker-a",
            lease_token=claimed.lease_token,
            lease_seconds=10,
            interval_seconds=0.01,
        )
        heartbeat.start()
        self.clock.value = 101.0
        time.sleep(0.05)
        heartbeat.stop()
        refreshed = self.store.list_tasks("job-1")[0]
        self.assertGreater(refreshed.heartbeat_at or 0, initial or 0)

    def test_task_lease_heartbeat_retries_transient_fault_before_safety_boundary(self):
        succeeded = threading.Event()

        class FlakyStore:
            def __init__(self):
                self.calls = 0

            def heartbeat(self, *_args, **_kwargs):
                self.calls += 1
                if self.calls == 1:
                    raise OSError("temporary sqlite fault")
                succeeded.set()

        store = FlakyStore()
        heartbeat = _TaskLeaseHeartbeat(
            store,
            task_id="task-flaky",
            worker_id="worker-a",
            lease_token="token",
            lease_seconds=0.5,
            interval_seconds=0.01,
        )
        heartbeat.start()
        self.assertTrue(succeeded.wait(timeout=1))
        heartbeat.stop()

        self.assertGreaterEqual(store.calls, 2)
        self.assertFalse(heartbeat.lost)

    def test_task_lease_heartbeat_marks_lost_before_failed_lease_is_reusable(self):
        class FailingStore:
            def heartbeat(self, *_args, **_kwargs):
                raise OSError("persistent sqlite fault")

        heartbeat = _TaskLeaseHeartbeat(
            FailingStore(),
            task_id="task-lost",
            worker_id="worker-a",
            lease_token="token",
            lease_seconds=0.08,
            interval_seconds=0.01,
        )
        heartbeat.start()
        deadline = time.monotonic() + 1
        while not heartbeat.lost and time.monotonic() < deadline:
            time.sleep(0.005)
        heartbeat.stop()

        self.assertTrue(heartbeat.lost)

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

    def test_failed_parent_reopens_without_retrying_deterministic_child(self):
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
        self.assertEqual(self.store.get_task("task-1").state, "failed")
        self.assertIsNone(self.store.claim_next(worker_id="worker-b"))
        self.assertEqual(len(self.store.list_attempts("job-1")), 1)

    def test_transient_task_failure_backs_off_and_exhausts_after_three_attempts(self):
        self.store.add_tasks([self.spec(blocks=((1, 2),))])
        delays = []
        for attempt_number in range(1, 4):
            claimed = self.store.claim_next(worker_id=f"worker-{attempt_number}")
            self.assertIsNotNone(claimed)
            assert claimed is not None
            self.assertEqual(claimed.attempt_number, attempt_number)
            failed = self.store.fail(
                claimed.task.task_id,
                worker_id=f"worker-{attempt_number}",
                lease_token=claimed.lease_token,
                typed_failure="building_chunk_execution_failed",
                transient=True,
            )
            if attempt_number < 3:
                self.assertEqual(failed.state, "pending")
                assert failed.next_eligible_at is not None
                delays.append(failed.next_eligible_at - self.clock.value)
                self.assertNotIn(
                    "job-1",
                    self.store.resumable_parent_ids(),
                )
                self.assertEqual(
                    self.store.pending_task_availability("job-1"),
                    {"eligible": 0, "deferred": 1},
                )
                self.assertIsNone(self.store.claim_next(worker_id="too-early"))
                self.clock.value = failed.next_eligible_at
                self.assertIn(
                    "job-1",
                    self.store.resumable_parent_ids(),
                )
            else:
                self.assertEqual(failed.state, "failed")
                self.assertIsNone(failed.next_eligible_at)

        self.assertGreater(delays[1], delays[0])
        self.assertIsNone(self.store.claim_next(worker_id="attempt-four"))
        self.assertEqual(
            [row["outcome"] for row in self.store.list_attempts("job-1")],
            ["failed_transient", "failed_transient", "failed_retry_exhausted"],
        )
        terminal = MapBuildPipeline._terminal_chunk_failure(failed)
        self.assertIsInstance(terminal, BuildingChunkRetryExhausted)
        assert isinstance(terminal, BuildingChunkRetryExhausted)
        self.assertEqual(terminal.task_id, "task-1")
        self.assertEqual(
            terminal.root_failure_code,
            "building_chunk_execution_failed",
        )

    def test_receipt_complete_parent_remains_resumable_for_assembly(self):
        self.store.add_tasks(
            [self.spec(blocks=((1, 2), (1, 3), (1, 4)))]
        )
        claimed = self.store.claim_next(worker_id="worker-a")
        self.assertIsNotNone(claimed)
        assert claimed is not None
        for block in claimed.task.blocks:
            self.store.publish_receipt(
                claimed.task.task_id,
                worker_id="worker-a",
                lease_token=claimed.lease_token,
                block=block,
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

        self.assertIn("job-1", self.store.resumable_parent_ids())

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

    def test_cache_hit_claims_without_heavy_reservation_when_pool_is_occupied(self):
        self.store.create_plan(
            parent_job_id="cache-parent",
            global_plan_sha256="c" * 64,
            input_identity={"source": "source-sha-cache"},
            expected_output_block_count=1,
            policy_version=1,
            resource_model_version="v1",
        )
        self.store.add_tasks(
            [
                BuildingTaskSpec(
                    task_id="heavy-blocker",
                    parent_job_id="job-1",
                    kind="building_chunk",
                    blocks=((1, 2),),
                    chunk_plan_sha256=SHA,
                    predicted_resource={"estimatedPeakMemoryBytes": 4_000_000_000},
                ),
                BuildingTaskSpec(
                    task_id="cache-hit",
                    parent_job_id="cache-parent",
                    kind="building_chunk",
                    blocks=((2, 2),),
                    chunk_plan_sha256="c" * 64,
                    predicted_resource={
                        "cacheHit": True,
                        "cacheIdentitySha256": SHA,
                        "estimatedPeakMemoryBytes": 0,
                        "memoryEstimateSource": "cache_receipt",
                    },
                ),
            ]
        )
        capability = {
            "resourcePool": "shared-cache-pool",
            "memoryLimitBytes": 8_000_000_000,
            "cpuCount": 8,
            "maxConcurrentTasks": 1,
        }
        blocker = self.store.claim_next(
            worker_id="heavy-worker", worker_capability=capability
        )
        self.assertIsNotNone(blocker)
        claimed = self.store.claim_next(
            worker_id="cache-worker", worker_capability=capability
        )
        self.assertIsNotNone(claimed)
        self.assertEqual(self.store.list_resource_reservations("cache-parent"), ())
        assert claimed is not None
        admission = json.loads(
            self.store.list_attempts("cache-parent")[0]["worker_capability_json"]
        )["admission"]
        self.assertFalse(admission["reservationRequired"])
        self.assertTrue(admission["reservationAccepted"])

    def test_receipt_complete_assembly_precedes_pending_child_parent(self):
        self.store.create_plan(
            parent_job_id="pending-parent",
            global_plan_sha256="d" * 64,
            input_identity={"source": "source-sha-pending"},
            expected_output_block_count=1,
            policy_version=1,
            resource_model_version="v1",
        )
        self.store.add_tasks(
            [
                self.spec(blocks=((1, 2), (1, 3), (1, 4))),
                BuildingTaskSpec(
                    task_id="pending-child",
                    parent_job_id="pending-parent",
                    kind="building_chunk",
                    blocks=((2, 2),),
                    chunk_plan_sha256="d" * 64,
                    predicted_resource={"estimatedPeakMemoryBytes": 1},
                ),
            ]
        )
        claimed = self.store.claim_next(worker_id="receipt-worker")
        self.assertIsNotNone(claimed)
        assert claimed is not None
        for block in claimed.task.blocks:
            self.store.publish_receipt(
                claimed.task.task_id,
                worker_id="receipt-worker",
                lease_token=claimed.lease_token,
                block=block,
                cache_identity_sha256=SHA,
                content_sha256=CONTENT,
                producer_identity={},
                validation={"valid": True},
            )
        self.store.mark_ready(
            claimed.task.task_id,
            worker_id="receipt-worker",
            lease_token=claimed.lease_token,
        )
        self.assertEqual(
            self.store.resumable_parent_ids(),
            ("job-1", "pending-parent"),
        )

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

    def test_missing_capability_still_reserves_default_pool_in_both_directions(self):
        self.store.create_plan(
            parent_job_id="job-2",
            global_plan_sha256="b" * 64,
            input_identity={},
            expected_output_block_count=1,
            policy_version=1,
            resource_model_version="v1",
        )
        self.store.add_tasks(
            [
                BuildingTaskSpec(
                    task_id="job-2-task",
                    parent_job_id="job-2",
                    kind="building_chunk",
                    blocks=((2, 2),),
                    chunk_plan_sha256=SHA,
                )
            ]
        )
        parent = self.store.acquire_parent_phase_reservation(
            parent_job_id="job-1",
            phase="source_preparation",
            worker_id="parent-worker",
            worker_capability=None,
        )
        assert parent is not None
        self.assertIsNone(self.store.claim_next(worker_id="child-worker"))
        self.store.release_parent_phase_reservation(
            parent_job_id="job-1",
            phase="source_preparation",
            worker_id="parent-worker",
            lease_token=parent.lease_token,
        )

        child = self.store.claim_next(worker_id="child-worker")
        assert child is not None
        self.assertEqual(len(self.store.list_resource_reservations("job-2")), 1)
        self.assertIsNone(
            self.store.acquire_parent_phase_reservation(
                parent_job_id="job-1",
                phase="map_assembly",
                worker_id="parent-worker",
                worker_capability=None,
            )
        )

    def test_parent_phase_uses_five_gibibyte_conservative_floor(self):
        with self.assertRaisesRegex(
            BuildingTaskStoreError,
            "cannot admit the parent resource phase",
        ):
            self.store.acquire_parent_phase_reservation(
                parent_job_id="job-1",
                phase="source_preparation",
                worker_id="small-parent",
                worker_capability={"memoryLimitBytes": 5 * 1024**3},
            )
        reservation = self.store.acquire_parent_phase_reservation(
            parent_job_id="job-1",
            phase="source_preparation",
            worker_id="large-parent",
            worker_capability={"memoryLimitBytes": 8 * 1024**3},
        )
        assert reservation is not None
        row = self.store.list_parent_phase_reservations("job-1")[0]
        self.assertEqual(row["memory_reservation_bytes"], 5 * 1024**3)

    def test_planless_parent_stage_waiter_is_admitted_only_after_pool_frees(self):
        capability = {
            "resourcePool": "parent-stage-pool",
            "memoryLimitBytes": 8 * 1024**3,
            "cpuCount": 8,
            "maxConcurrentTasks": 1,
        }
        blocker = self.store.acquire_parent_phase_reservation(
            parent_job_id="blocker",
            phase="source_preparation",
            worker_id="worker-a",
            worker_capability=capability,
        )
        self.assertIsNotNone(blocker)
        waiter = self.store.acquire_parent_phase_reservation(
            parent_job_id="planless-parent",
            phase="source_preparation",
            worker_id="worker-b",
            worker_capability=capability,
        )
        self.assertIsNone(waiter)
        self.assertEqual(
            self.store.list_parent_stage_eligibility("planless-parent"),
            (
                {
                    "parent_job_id": "planless-parent",
                    "phase": "source_preparation",
                    "state": "waiting",
                    "worker_id": None,
                    "created_at": 100.0,
                    "updated_at": 100.0,
                },
            ),
        )
        self.assertNotIn(
            "planless-parent",
            self.store.resumable_parent_ids(worker_capability=capability),
        )

        assert blocker is not None
        self.store.release_parent_phase_reservation(
            parent_job_id="blocker",
            phase="source_preparation",
            worker_id="worker-a",
            lease_token=blocker.lease_token,
        )
        self.assertIn(
            "planless-parent",
            self.store.resumable_parent_ids(worker_capability=capability),
        )
        admitted = self.store.acquire_parent_phase_reservation(
            parent_job_id="planless-parent",
            phase="source_preparation",
            worker_id="worker-b",
            worker_capability=capability,
        )
        self.assertIsNotNone(admitted)
        self.assertEqual(
            self.store.list_parent_stage_eligibility("planless-parent")[0]["state"],
            "active",
        )
        assert admitted is not None
        self.store.release_parent_phase_reservation(
            parent_job_id="planless-parent",
            phase="source_preparation",
            worker_id="worker-b",
            lease_token=admitted.lease_token,
        )
        self.assertEqual(
            self.store.list_parent_stage_eligibility("planless-parent"), ()
        )

    def test_terminal_stage_transitions_clear_parent_stage_eligibility(self):
        capability = {
            "resourcePool": "terminal-stage-pool",
            "memoryLimitBytes": 8 * 1024**3,
            "cpuCount": 8,
            "maxConcurrentTasks": 1,
        }
        for parent_job_id in ("failed-stage-parent", "advanced-failed-parent"):
            self.store.create_plan(
                parent_job_id=parent_job_id,
                global_plan_sha256=(parent_job_id[0] * 64),
                input_identity={"source": parent_job_id},
                expected_output_block_count=1,
                policy_version=1,
                resource_model_version="v1",
            )
        blocker = self.store.acquire_parent_phase_reservation(
            parent_job_id="terminal-stage-blocker",
            phase="source_preparation",
            worker_id="worker-blocker",
            worker_capability=capability,
        )
        self.assertIsNotNone(blocker)
        for parent_job_id in ("failed-stage-parent", "advanced-failed-parent"):
            self.assertIsNone(
                self.store.acquire_parent_phase_reservation(
                    parent_job_id=parent_job_id,
                    phase="source_preparation",
                    worker_id="worker-waiter",
                    worker_capability=capability,
                )
            )
        self.assertEqual(
            len(self.store.list_parent_stage_eligibility()), 3
        )
        self.store.set_plan_stage(
            "failed-stage-parent", stage="failed", state="failed"
        )
        self.store.advance_plan_stage(
            "advanced-failed-parent", stage="failed", state="failed"
        )
        self.assertEqual(
            self.store.list_parent_stage_eligibility("failed-stage-parent"), ()
        )
        self.assertEqual(
            self.store.list_parent_stage_eligibility("advanced-failed-parent"), ()
        )
        assert blocker is not None
        self.store.release_parent_phase_reservation(
            parent_job_id="terminal-stage-blocker",
            phase="source_preparation",
            worker_id="worker-blocker",
            lease_token=blocker.lease_token,
        )

    def test_ready_reconciliation_clears_planless_parent_stage_waiter(self):
        capability = {
            "resourcePool": "planless-reconcile-pool",
            "memoryLimitBytes": 8 * 1024**3,
            "cpuCount": 8,
            "maxConcurrentTasks": 1,
        }
        blocker = self.store.acquire_parent_phase_reservation(
            parent_job_id="planless-reconcile-blocker",
            phase="source_preparation",
            worker_id="worker-blocker",
            worker_capability=capability,
        )
        self.assertIsNotNone(blocker)
        self.assertIsNone(
            self.store.acquire_parent_phase_reservation(
                parent_job_id="planless-reconcile-parent",
                phase="source_preparation",
                worker_id="worker-waiter",
                worker_capability=capability,
            )
        )
        self.assertEqual(
            self.store.reconcile_ready_plans(("planless-reconcile-parent",)), 0
        )
        self.assertEqual(
            self.store.list_parent_stage_eligibility("planless-reconcile-parent"),
            (),
        )
        assert blocker is not None
        self.store.release_parent_phase_reservation(
            parent_job_id="planless-reconcile-blocker",
            phase="source_preparation",
            worker_id="worker-blocker",
            lease_token=blocker.lease_token,
        )

    def test_reopen_failed_plan_clears_stale_parent_stage_waiter(self):
        self.store.set_plan_stage("job-1", stage="failed", state="failed")
        connection = sqlite3.connect(self.store.path)
        connection.execute(
            """
            INSERT INTO map_build_parent_stage_eligibility(
                parent_job_id, phase, state, lease_token, worker_id,
                created_at, updated_at
            ) VALUES ('job-1', 'source_preparation', 'waiting', NULL, NULL, 100, 100)
            """
        )
        connection.commit()
        connection.close()

        self.store.reopen_failed_plan("job-1")

        self.assertEqual(self.store.list_parent_stage_eligibility("job-1"), ())

    def test_two_waiting_parent_stages_are_quietly_handed_between_workers(self):
        capability = {
            "resourcePool": "two-worker-parent-pool",
            "memoryLimitBytes": 8 * 1024**3,
            "cpuCount": 8,
            "maxConcurrentTasks": 1,
        }
        blocker = self.store.acquire_parent_phase_reservation(
            parent_job_id="blocker-two-worker",
            phase="source_preparation",
            worker_id="worker-blocker",
            worker_capability=capability,
        )
        self.assertIsNotNone(blocker)
        for parent_job_id, worker_id in (
            ("parent-a", "worker-a"),
            ("parent-b", "worker-b"),
        ):
            self.assertIsNone(
                self.store.acquire_parent_phase_reservation(
                    parent_job_id=parent_job_id,
                    phase="source_preparation",
                    worker_id=worker_id,
                    worker_capability=capability,
                )
            )
        assert blocker is not None
        self.store.release_parent_phase_reservation(
            parent_job_id="blocker-two-worker",
            phase="source_preparation",
            worker_id="worker-blocker",
            lease_token=blocker.lease_token,
        )

        first_candidates = self.store.resumable_parent_ids(
            worker_capability=capability
        )
        self.assertEqual(first_candidates, ("parent-a", "parent-b"))
        first = self.store.acquire_parent_phase_reservation(
            parent_job_id="parent-a",
            phase="source_preparation",
            worker_id="worker-a",
            worker_capability=capability,
        )
        self.assertIsNotNone(first)
        self.assertEqual(
            self.store.resumable_parent_ids(worker_capability=capability), ()
        )
        assert first is not None
        self.store.release_parent_phase_reservation(
            parent_job_id="parent-a",
            phase="source_preparation",
            worker_id="worker-a",
            lease_token=first.lease_token,
        )
        self.assertEqual(
            self.store.resumable_parent_ids(worker_capability=capability),
            ("parent-b",),
        )

    def test_receipt_complete_assembly_waits_for_parent_pool_capacity(self):
        self.store.add_tasks([self.spec(blocks=((1, 2), (1, 3), (1, 4)))])
        claimed = self.store.claim_next(worker_id="worker-receipt")
        self.assertIsNotNone(claimed)
        assert claimed is not None
        for block in claimed.task.blocks:
            self.store.publish_receipt(
                claimed.task.task_id,
                worker_id="worker-receipt",
                lease_token=claimed.lease_token,
                block=block,
                cache_identity_sha256=SHA,
                content_sha256=CONTENT,
                producer_identity={},
                validation={"valid": True},
            )
        self.store.mark_ready(
            claimed.task.task_id,
            worker_id="worker-receipt",
            lease_token=claimed.lease_token,
        )
        capability = {
            "resourcePool": "assembly-pool",
            "memoryLimitBytes": 8 * 1024**3,
            "cpuCount": 8,
            "maxConcurrentTasks": 1,
        }
        blocker = self.store.acquire_parent_phase_reservation(
            parent_job_id="assembly-blocker",
            phase="source_preparation",
            worker_id="worker-blocker",
            worker_capability=capability,
        )
        self.assertIsNotNone(blocker)
        self.assertNotIn(
            "job-1",
            self.store.resumable_parent_ids(worker_capability=capability),
        )
        assert blocker is not None
        self.store.release_parent_phase_reservation(
            parent_job_id="assembly-blocker",
            phase="source_preparation",
            worker_id="worker-blocker",
            lease_token=blocker.lease_token,
        )
        self.assertIn(
            "job-1",
            self.store.resumable_parent_ids(worker_capability=capability),
        )

    def test_pending_child_parent_waits_for_shared_pool_capacity(self):
        self.store.add_tasks([self.spec(blocks=((1, 2),))])
        capability = {
            "resourcePool": "pending-child-pool",
            "memoryLimitBytes": 8 * 1024**3,
            "cpuCount": 8,
            "maxConcurrentTasks": 1,
        }
        blocker = self.store.acquire_parent_phase_reservation(
            parent_job_id="pending-child-blocker",
            phase="source_preparation",
            worker_id="worker-blocker",
            worker_capability=capability,
        )
        self.assertIsNotNone(blocker)
        self.assertNotIn(
            "job-1",
            self.store.resumable_parent_ids(worker_capability=capability),
        )
        assert blocker is not None
        self.store.release_parent_phase_reservation(
            parent_job_id="pending-child-blocker",
            phase="source_preparation",
            worker_id="worker-blocker",
            lease_token=blocker.lease_token,
        )
        self.assertIn(
            "job-1",
            self.store.resumable_parent_ids(worker_capability=capability),
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

    def test_two_parent_workers_cannot_overlap_heavy_phases(self):
        self.store.create_plan(
            parent_job_id="job-2",
            global_plan_sha256="b" * 64,
            input_identity={"source": "source-sha-2"},
            expected_output_block_count=1,
            policy_version=1,
            resource_model_version="v1",
        )
        capability = {
            "resourcePool": "shared-heavy-pool",
            "memoryLimitBytes": 8_000_000_000,
            "cpuCount": 8,
            "maxConcurrentTasks": 4,
        }
        start = threading.Barrier(3)
        acquired = threading.Barrier(3)
        release = threading.Event()
        results = []

        def reserve(parent_job_id, phase, worker_id):
            start.wait()
            reservation = self.store.acquire_parent_phase_reservation(
                parent_job_id=parent_job_id,
                phase=phase,
                worker_id=worker_id,
                worker_capability=capability,
                lease_seconds=10,
            )
            results.append(reservation)
            acquired.wait()
            release.wait(timeout=2)
            if reservation is not None:
                self.store.release_parent_phase_reservation(
                    parent_job_id=parent_job_id,
                    phase=phase,
                    worker_id=worker_id,
                    lease_token=reservation.lease_token,
                )

        workers = [
            threading.Thread(
                target=reserve,
                args=("job-1", "source_preparation", "worker-a"),
            ),
            threading.Thread(
                target=reserve,
                args=("job-2", "map_assembly", "worker-b"),
            ),
        ]
        for worker in workers:
            worker.start()
        start.wait()
        acquired.wait()
        try:
            self.assertEqual(sum(item is not None for item in results), 1)
            self.assertEqual(len(self.store.list_parent_phase_reservations()), 1)
        finally:
            release.set()
            for worker in workers:
                worker.join(timeout=2)
        self.assertTrue(all(not worker.is_alive() for worker in workers))
        self.assertEqual(self.store.list_parent_phase_reservations(), ())

    def test_parent_phase_and_child_reservations_deny_overlap(self):
        self.store.create_plan(
            parent_job_id="job-2",
            global_plan_sha256="b" * 64,
            input_identity={"source": "source-sha-2"},
            expected_output_block_count=1,
            policy_version=1,
            resource_model_version="v1",
        )
        self.store.add_tasks(
            [
                BuildingTaskSpec(
                    task_id="job-2-task",
                    parent_job_id="job-2",
                    kind="building_chunk",
                    blocks=((2, 2),),
                    chunk_plan_sha256=SHA,
                )
            ]
        )
        capability = {
            "resourcePool": "shared-heavy-pool",
            "memoryLimitBytes": 8_000_000_000,
            "cpuCount": 8,
            # The active parent reservation must keep this inconsistent
            # worker report from bypassing the concurrency-one policy.
            "maxConcurrentTasks": 4,
        }
        parent = self.store.acquire_parent_phase_reservation(
            parent_job_id="job-1",
            phase="source_preparation",
            worker_id="worker-parent",
            worker_capability=capability,
        )
        self.assertIsNotNone(parent)
        assert parent is not None
        self.assertTrue(
            self.store.resource_capacity_occupied(worker_capability=capability)
        )
        self.assertIsNone(
            self.store.claim_next(
                worker_id="worker-child", worker_capability=capability
            )
        )
        page = self.store.diagnostic_page("job-1")
        self.assertEqual(page["counts"]["parentPhaseReservations"], 1)
        self.assertEqual(
            page["parentPhaseReservations"][0]["phase"],
            "source_preparation",
        )
        self.store.release_parent_phase_reservation(
            parent_job_id="job-1",
            phase="source_preparation",
            worker_id="worker-parent",
            lease_token=parent.lease_token,
        )
        child = self.store.claim_next(
            worker_id="worker-child", worker_capability=capability
        )
        self.assertIsNotNone(child)
        self.assertIsNone(
            self.store.acquire_parent_phase_reservation(
                parent_job_id="job-1",
                phase="map_assembly",
                worker_id="worker-parent",
                worker_capability=capability,
            )
        )

    def test_diagnostic_page_redacts_active_fencing_tokens(self):
        capability = {
            "resourcePool": "diagnostic-redaction",
            "memoryLimitBytes": 12_000_000_000,
            "cpuCount": 4,
            "maxConcurrentTasks": 1,
        }
        self.store.add_tasks([self.spec(task_id="redacted-task")])
        claimed = self.store.claim_next(
            worker_id="worker-child",
            worker_capability=capability,
        )
        self.assertIsNotNone(claimed)
        assert claimed is not None

        child_page = self.store.diagnostic_page("job-1")

        self.assertEqual(
            self.store.get_task(claimed.task.task_id).lease_token,
            claimed.lease_token,
        )
        self.assertNotIn("lease_token", asdict(child_page["tasks"][0]))
        self.assertNotIn(
            "lease_token", child_page["resourceReservations"][0]
        )

        self.store.fail(
            claimed.task.task_id,
            worker_id="worker-child",
            lease_token=claimed.lease_token,
            typed_failure="test_failure",
            transient=False,
        )
        parent = self.store.acquire_parent_phase_reservation(
            parent_job_id="job-1",
            phase="source_preparation",
            worker_id="worker-parent",
            worker_capability=capability,
        )
        self.assertIsNotNone(parent)
        assert parent is not None

        parent_page = self.store.diagnostic_page("job-1")

        self.assertNotIn(
            "lease_token", parent_page["parentPhaseReservations"][0]
        )
        self.store.release_parent_phase_reservation(
            parent_job_id="job-1",
            phase="source_preparation",
            worker_id="worker-parent",
            lease_token=parent.lease_token,
        )

    def test_parent_phase_expiry_heartbeat_and_token_fencing(self):
        capability = {
            "resourcePool": "shared-heavy-pool",
            "memoryLimitBytes": 8_000_000_000,
        }
        reservation = self.store.acquire_parent_phase_reservation(
            parent_job_id="job-1",
            phase="source_preparation",
            worker_id="worker-a",
            worker_capability=capability,
            lease_seconds=10,
        )
        self.assertIsNotNone(reservation)
        assert reservation is not None
        heartbeat = _ParentPhaseLeaseHeartbeat(
            self.store,
            parent_job_id="job-1",
            phase="source_preparation",
            worker_id="worker-a",
            lease_token=reservation.lease_token,
            lease_seconds=10,
            interval_seconds=0.01,
        )
        heartbeat.start()
        self.clock.value = 105
        time.sleep(0.05)
        heartbeat.stop()
        row = self.store.list_parent_phase_reservations("job-1")[0]
        self.assertEqual(row["heartbeat_at"], 105)
        self.assertEqual(row["expires_at"], 115)
        with self.assertRaises(StaleLeaseError):
            self.store.release_parent_phase_reservation(
                parent_job_id="job-1",
                phase="source_preparation",
                worker_id="worker-b",
                lease_token=reservation.lease_token,
            )

        self.clock.value = 116
        self.assertEqual(self.store.recover_expired(), 1)
        replacement = self.store.acquire_parent_phase_reservation(
            parent_job_id="unplanned-job-2",
            phase="map_assembly",
            worker_id="worker-b",
            worker_capability=capability,
        )
        self.assertIsNotNone(replacement)
        with self.assertRaises(StaleLeaseError):
            self.store.release_parent_phase_reservation(
                parent_job_id="job-1",
                phase="source_preparation",
                worker_id="worker-a",
                lease_token=reservation.lease_token,
            )

    def test_parent_phase_context_releases_on_success_failure_and_yield(self):
        capability = {
            "resourcePool": "shared-heavy-pool",
            "memoryLimitBytes": 8_000_000_000,
        }
        pipeline = MapBuildPipeline(
            PipelinePaths(
                Path(self.temp.name),
                Path(self.temp.name) / "work",
                Path(self.temp.name) / "packs",
            ),
            building_scope_mode="chunked",
            building_task_store=self.store,
        )
        with pipeline._parent_phase_reservation(
            parent_job_id="job-1",
            phase="source_preparation",
            worker_id="worker-a",
            worker_capability=capability,
        ) as cancellation_requested:
            self.assertFalse(cancellation_requested())
            self.assertEqual(len(self.store.list_parent_phase_reservations()), 1)
        self.assertEqual(self.store.list_parent_phase_reservations(), ())

        with self.assertRaisesRegex(RuntimeError, "phase failed"):
            with pipeline._parent_phase_reservation(
                parent_job_id="job-1",
                phase="map_assembly",
                worker_id="worker-a",
                worker_capability=capability,
            ):
                raise RuntimeError("phase failed")
        self.assertEqual(self.store.list_parent_phase_reservations(), ())

        with pipeline._parent_phase_reservation(
            parent_job_id="job-1",
            phase="source_preparation",
            worker_id="worker-a",
            worker_capability=capability,
        ):
            with self.assertRaises(BuildingChunkSchedulingYield):
                with pipeline._parent_phase_reservation(
                    parent_job_id="unplanned-job-2",
                    phase="map_assembly",
                    worker_id="worker-b",
                    worker_capability=capability,
                ):
                    self.fail("overlapping phase unexpectedly acquired")
        self.assertEqual(self.store.list_parent_phase_reservations(), ())

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
        self.assertEqual(version, 7)

    def test_future_schema_is_rejected_before_any_schema_mutation(self):
        path = Path(self.temp.name) / "future-tasks.sqlite3"
        connection = sqlite3.connect(path)
        connection.execute("PRAGMA user_version=8")
        connection.commit()
        connection.close()

        with self.assertRaisesRegex(
            BuildingTaskStoreError,
            "unsupported building task schema",
        ):
            BuildingTaskStore(path)

        connection = sqlite3.connect(path)
        version = connection.execute("PRAGMA user_version").fetchone()[0]
        tables = connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        ).fetchall()
        connection.close()
        self.assertEqual(version, 8)
        self.assertEqual(tables, [])

    def test_concurrent_legacy_initializers_serialize_migrations(self):
        path = Path(self.temp.name) / "concurrent-legacy-tasks.sqlite3"
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
        barrier = threading.Barrier(8)
        errors = []

        def initialize():
            try:
                barrier.wait()
                BuildingTaskStore(path)
            except BaseException as exc:  # surfaced below on the test thread
                errors.append(exc)

        threads = [threading.Thread(target=initialize) for _ in range(8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=10)

        self.assertTrue(all(not thread.is_alive() for thread in threads))
        self.assertEqual(errors, [])
        connection = sqlite3.connect(path)
        version = connection.execute("PRAGMA user_version").fetchone()[0]
        columns = {
            row[1]
            for row in connection.execute("PRAGMA table_info(map_build_plans)")
        }
        connection.close()
        self.assertEqual(version, 7)
        self.assertIn("scheduling_weight", columns)
        self.assertIn("last_claimed_at", columns)

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

    def test_observed_plan_is_nonclaimable_retained_and_reactivatable(self):
        self.store.add_tasks([self.spec(blocks=((1, 2), (1, 3)))])

        observed = self.store.mark_plan_observed("job-1")

        self.assertEqual(observed["state"], "observed")
        self.assertEqual(observed["stage"], "observed")
        self.assertIsNone(self.store.claim_next(worker_id="worker-a"))
        task = self.store.get_task("task-1")
        assert task is not None
        self.assertEqual(task.state, "cancelled")
        self.assertEqual(task.typed_error, "building_shadow_observed")

        active = self.store.activate_observed_plan("job-1")

        assert active is not None
        self.assertEqual(active["state"], "chunk_planning")
        self.assertEqual(self.store.list_tasks("job-1"), ())

    def test_observed_plan_publication_rolls_back_before_tasks_are_claimable(self):
        path = Path(self.temp.name) / "atomic-shadow.sqlite3"
        store = BuildingTaskStore(path, clock=self.clock)
        specs = [
            BuildingTaskSpec(
                task_id="shadow-a",
                parent_job_id="shadow-parent",
                kind="building_chunk",
                blocks=((1, 1),),
                chunk_plan_sha256=SHA,
            ),
            BuildingTaskSpec(
                task_id="shadow-b",
                parent_job_id="shadow-parent",
                kind="building_chunk",
                blocks=((1, 2),),
                chunk_plan_sha256=SHA,
            ),
        ]
        original_insert = store._insert_task
        inserted = 0

        def fail_after_first_insert(connection, spec):
            nonlocal inserted
            original_insert(connection, spec)
            inserted += 1
            if inserted == 1:
                raise RuntimeError("injected shadow publication failure")

        store._insert_task = fail_after_first_insert
        with self.assertRaisesRegex(RuntimeError, "injected shadow"):
            store.publish_observed_plan(
                parent_job_id="shadow-parent",
                global_plan_sha256=SHA,
                input_identity={"source": "shadow"},
                expected_output_block_count=2,
                policy_version=1,
                resource_model_version="v1",
                tasks=specs,
            )
        store._insert_task = original_insert

        self.assertIsNone(store.get_plan("shadow-parent"))
        self.assertEqual(store.list_tasks("shadow-parent"), ())
        self.assertIsNone(store.claim_next(worker_id="unexpected-worker"))

    def test_observed_plan_retry_atomically_replaces_changed_partition(self):
        first_partition = [
            BuildingTaskSpec(
                task_id="shadow-old",
                parent_job_id="job-1",
                kind="building_chunk",
                blocks=((1, 2), (1, 3), (1, 4)),
                chunk_plan_sha256=SHA,
            )
        ]
        second_partition = [
            BuildingTaskSpec(
                task_id="shadow-new-a",
                parent_job_id="job-1",
                kind="building_chunk",
                blocks=((1, 2),),
                chunk_plan_sha256=CONTENT,
            ),
            BuildingTaskSpec(
                task_id="shadow-new-b",
                parent_job_id="job-1",
                kind="building_chunk",
                blocks=((1, 3), (1, 4)),
                chunk_plan_sha256=CONTENT,
            ),
        ]
        plan_args = {
            "parent_job_id": "job-1",
            "global_plan_sha256": SHA,
            "input_identity": {"source": "source-sha"},
            "expected_output_block_count": 3,
            "policy_version": 1,
            "resource_model_version": "v1",
        }
        self.store.publish_observed_plan(tasks=first_partition, **plan_args)

        observed = self.store.publish_observed_plan(
            tasks=second_partition,
            **plan_args,
        )

        self.assertEqual(observed["state"], "observed")
        self.assertIsNone(self.store.get_task("shadow-old"))
        replacement = self.store.list_tasks("job-1")
        self.assertEqual(
            {task.task_id for task in replacement},
            {"shadow-new-a", "shadow-new-b"},
        )
        self.assertTrue(all(task.state == "cancelled" for task in replacement))
        self.assertIsNone(self.store.claim_next(worker_id="shadow-worker"))

    def test_observed_plan_retry_rejects_execution_evidence(self):
        specs = [
            BuildingTaskSpec(
                task_id="shadow-old",
                parent_job_id="job-1",
                kind="building_chunk",
                blocks=((1, 2), (1, 3), (1, 4)),
                chunk_plan_sha256=SHA,
            )
        ]
        plan_args = {
            "parent_job_id": "job-1",
            "global_plan_sha256": SHA,
            "input_identity": {"source": "source-sha"},
            "expected_output_block_count": 3,
            "policy_version": 1,
            "resource_model_version": "v1",
        }
        self.store.publish_observed_plan(tasks=specs, **plan_args)
        self.store.activate_observed_plan("job-1")
        self.store.add_tasks(
            [
                BuildingTaskSpec(
                    task_id="executed-task",
                    parent_job_id="job-1",
                    kind="building_chunk",
                    blocks=((1, 2), (1, 3), (1, 4)),
                    chunk_plan_sha256=SHA,
                )
            ]
        )
        claimed = self.store.claim_next(worker_id="selected-worker")
        assert claimed is not None

        with self.assertRaisesRegex(
            BuildingTaskStoreError,
            "compatible shadow observation|execution evidence",
        ):
            self.store.publish_observed_plan(tasks=specs, **plan_args)

        retained = self.store.get_task("executed-task")
        assert retained is not None
        self.assertEqual(retained.state, "leased")
        self.assertEqual(retained.lease_token, claimed.lease_token)

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
            self.assertEqual(store.get_plan("job-shadow")["state"], "observed")
            tasks = store.list_tasks("job-shadow")
            self.assertEqual(len(tasks), len(partition.chunks))
            self.assertTrue(all(task.kind == "building_workload_scan" for task in tasks))
            self.assertTrue(all(task.state == "cancelled" for task in tasks))
            self.assertIsNone(store.claim_next(worker_id="shadow-worker"))

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

    def test_workload_scan_splits_multi_block_wall_target_before_build(self):
        self.store.add_tasks(
            [
                BuildingTaskSpec(
                    task_id="scan-wall-split",
                    parent_job_id="job-1",
                    kind="building_workload_scan",
                    blocks=((1, 2), (1, 3)),
                    chunk_plan_sha256=SHA,
                    predicted_resource={"requiresExactWorkloadScan": True},
                )
            ]
        )
        claimed = self.store.claim_next(worker_id="scanner")
        assert claimed is not None
        receipt = workload_receipt()
        receipt["wayNodeReferenceCount"] = 30_000_001

        split = self.store.complete_workload_scan(
            claimed.task.task_id,
            worker_id="scanner",
            lease_token=claimed.lease_token,
            workload_receipt=receipt,
        )

        self.assertEqual(split.state, "split")
        self.assertIn("wall_time", split.predicted_resource["targetViolations"])
        self.assertGreater(split.predicted_resource["estimatedWallSeconds"], 600)
        children = [
            task
            for task in self.store.list_tasks("job-1")
            if task.task_id != split.task_id
        ]
        self.assertEqual(len(children), 2)
        self.assertTrue(
            all(task.kind == "building_workload_scan" for task in children)
        )

    def test_workload_scan_fails_single_block_above_wall_hard_ceiling(self):
        self.store.add_tasks(
            [
                BuildingTaskSpec(
                    task_id="scan-wall-hard",
                    parent_job_id="job-1",
                    kind="building_workload_scan",
                    blocks=((1, 2),),
                    chunk_plan_sha256=SHA,
                )
            ]
        )
        claimed = self.store.claim_next(worker_id="scanner")
        assert claimed is not None
        receipt = workload_receipt()
        receipt["wayNodeReferenceCount"] = 100_000_000

        failed = self.store.complete_workload_scan(
            claimed.task.task_id,
            worker_id="scanner",
            lease_token=claimed.lease_token,
            workload_receipt=receipt,
        )

        self.assertEqual(failed.state, "failed")
        self.assertEqual(failed.typed_error, "building_pathological_block")
        self.assertIn("wall_time", failed.predicted_resource["hardViolations"])

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
        deferred = self.store.get_task(claimed.task.task_id)
        assert deferred is not None and deferred.next_eligible_at is not None
        self.clock.value = deferred.next_eligible_at
        retry = self.store.claim_next(worker_id="worker-b")
        self.assertIsNotNone(retry)
        assert retry is not None
        self.assertEqual(retry.attempt_number, 2)

    def test_scheduler_automatically_recovers_expiry_and_fences_old_publish(self):
        self.store.add_tasks([self.spec(blocks=((1, 2),))])
        expired = self.store.claim_next(worker_id="worker-a", lease_seconds=5)
        assert expired is not None
        self.clock.value = 106

        self.assertIsNone(
            self.store.claim_next(worker_id="worker-b", lease_seconds=5)
        )
        deferred = self.store.get_task(expired.task.task_id)
        assert deferred is not None and deferred.next_eligible_at is not None
        self.clock.value = deferred.next_eligible_at
        reclaimed = self.store.claim_next(worker_id="worker-b", lease_seconds=5)

        assert reclaimed is not None
        self.assertEqual(reclaimed.task.task_id, expired.task.task_id)
        self.assertEqual(reclaimed.attempt_number, 2)
        with self.assertRaises(StaleLeaseError):
            self.store.publish_receipt(
                expired.task.task_id,
                worker_id="worker-a",
                lease_token=expired.lease_token,
                block=(1, 2),
                cache_identity_sha256=SHA,
                content_sha256=CONTENT,
                producer_identity={},
                validation={},
            )
        attempts = self.store.list_attempts("job-1")
        self.assertEqual(attempts[0]["outcome"], "lease_expired")
        self.assertEqual(attempts[0]["typed_failure"], "building_task_lease_expired")

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

    def test_split_requires_exact_coverage_and_rolls_back_parent_state(self):
        self.store.add_tasks([self.spec(blocks=((1, 2), (1, 3), (1, 4)))])
        claimed = self.store.claim_next(
            worker_id="worker-a",
            worker_capability={
                "memoryLimitBytes": 8_000_000_000,
                "cpuCount": 8,
                "resourcePool": "test",
                "maxConcurrentTasks": 1,
            },
        )
        assert claimed is not None
        attempts_before = self.store.list_attempts("job-1")
        reservations_before = self.store.list_resource_reservations("job-1")

        with self.assertRaisesRegex(
            BuildingTaskStoreError,
            "exactly cover the parent block set",
        ):
            self.store.split(
                claimed.task.task_id,
                worker_id="worker-a",
                lease_token=claimed.lease_token,
                reason="building_object_limit_exceeded",
                children=[
                    self.spec("child-a", ((1, 2),)),
                    self.spec("child-b", ((1, 3),)),
                ],
            )

        parent = self.store.get_task(claimed.task.task_id)
        assert parent is not None
        self.assertEqual(parent.state, "leased")
        self.assertEqual(parent.blocks, ((1, 2), (1, 3), (1, 4)))
        self.assertEqual(parent.lease_owner, "worker-a")
        self.assertEqual(parent.lease_token, claimed.lease_token)
        self.assertIsNone(self.store.get_task("child-a"))
        self.assertIsNone(self.store.get_task("child-b"))
        self.assertEqual(self.store.list_attempts("job-1"), attempts_before)
        self.assertEqual(
            self.store.list_resource_reservations("job-1"),
            reservations_before,
        )

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

    def test_reconcile_ready_plan_fences_leased_child_and_reservation(self):
        self.store.add_tasks([self.spec(blocks=((1, 2),))])
        claimed = self.store.claim_next(
            worker_id="worker-a",
            worker_capability={
                "resourcePool": "pool-a",
                "memoryLimitBytes": 8_000_000_000,
                "cpuCount": 8,
                "maxConcurrentTasks": 1,
            },
        )
        self.assertIsNotNone(claimed)
        assert claimed is not None
        self.assertEqual(len(self.store.list_resource_reservations("job-1")), 1)

        self.assertEqual(self.store.reconcile_ready_plans(("job-1",)), 1)

        self.assertEqual(self.store.get_plan("job-1")["state"], "ready")
        superseded = self.store.get_task(claimed.task.task_id)
        self.assertIsNotNone(superseded)
        assert superseded is not None
        self.assertEqual(superseded.state, "cancelled")
        self.assertEqual(
            superseded.typed_error,
            "building_task_superseded_by_public_ready",
        )
        self.assertEqual(self.store.list_resource_reservations("job-1"), ())
        attempt = self.store.list_attempts("job-1")[0]
        self.assertEqual(attempt["outcome"], "superseded")
        self.assertEqual(
            attempt["typed_failure"],
            "building_task_superseded_by_public_ready",
        )
        with self.assertRaises(StaleLeaseError):
            self.store.mark_ready(
                claimed.task.task_id,
                worker_id="worker-a",
                lease_token=claimed.lease_token,
            )
        self.assertEqual(self.store.reconcile_ready_plans(("job-1",)), 0)

    def test_reconcile_ready_plan_releases_parent_phase_reservation(self):
        self.store.add_tasks([self.spec(blocks=((1, 2),))])
        reservation = self.store.acquire_parent_phase_reservation(
            parent_job_id="job-1",
            phase="source_preparation",
            worker_id="worker-parent",
            worker_capability={
                "resourcePool": "pool-a",
                "memoryLimitBytes": 8_000_000_000,
                "cpuCount": 8,
                "maxConcurrentTasks": 1,
            },
        )
        self.assertIsNotNone(reservation)
        self.assertEqual(
            len(self.store.list_parent_phase_reservations("job-1")),
            1,
        )

        self.assertEqual(self.store.reconcile_ready_plans(("job-1",)), 1)

        self.assertEqual(
            self.store.list_parent_phase_reservations("job-1"),
            (),
        )
        self.assertEqual(self.store.get_task("task-1").state, "cancelled")

    def test_reconcile_ready_does_not_promote_observed_plan(self):
        observed = self.store.mark_plan_observed("job-1")
        self.assertEqual(observed["state"], "observed")

        self.assertEqual(self.store.reconcile_ready_plans(("job-1",)), 0)

        self.assertEqual(self.store.get_plan("job-1")["state"], "observed")
        self.assertEqual(self.store.get_plan("job-1")["stage"], "observed")

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
        attempt = self.store.list_attempts("job-1")[0]
        self.assertEqual(attempt["outcome"], "cancelled")
        self.assertEqual(attempt["typed_failure"], "building_task_cancelled")
        self.assertIsNotNone(attempt["finished_at"])
        self.assertEqual(self.store.reconcile_cancelled_plans(("job-1",)), 0)

    def test_duplicate_block_ownership_is_rejected(self):
        self.store.add_tasks([self.spec(blocks=((1, 2),))])
        with self.assertRaises(Exception):
            self.store.add_tasks([self.spec("task-2", ((1, 2),))])


if __name__ == "__main__":
    unittest.main()
