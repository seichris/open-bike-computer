import json
import shutil
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from map_platform.artifacts import ArtifactRecord, FileSystemArtifactStore, sha256_file
from map_platform.jobs import (
    ArtifactGarbageCollectionError,
    JobClaimError,
    JobRecordEnumerationError,
    JobStore,
    MapJobService,
)
from map_platform.models import Bounds, JobStatus, MapDownloadReceipt, SourceRegion
from map_platform.monitoring import MapMonitoringStore
from map_platform.pipeline import MapBuildResult, run_job
from map_platform.sources import SourceIndex
from map_platform.worker import (
    ExpiredArtifactCleanupError,
    MapWorker,
    WorkDirectoryCleanupError,
    cleanup_expired_pack_artifacts,
    cleanup_work_dirs,
    expire_ready_jobs,
)


class FakePipeline:
    def __init__(self, failures=0):
        self.failures = failures
        self.calls = 0

    def build(self, job, on_status=None, on_progress=None):
        self.calls += 1
        if on_progress:
            on_progress(8, 10)
        if self.calls <= self.failures:
            raise RuntimeError("temporary worker failure")
        pack_path = Path(tempfile.gettempdir()) / f"map-123-{job.job_id}.zip"
        pack_path.write_bytes(b"zip-data")
        return "map-123", pack_path


class CancellingPipeline:
    def __init__(self, service):
        self.service = service

    def build(self, job, on_status=None, on_progress=None):
        self.service.cancel_job(job.job_id)
        if on_progress:
            on_progress(1, 10)
        return "map-123", Path("/tmp/map-123.zip")


class BlockingPipeline:
    def __init__(self):
        self.started = threading.Event()
        self.release = threading.Event()

    def build(self, job, on_status=None, on_progress=None):
        if on_status:
            on_status(JobStatus.EXTRACTING_PBF)
        self.started.set()
        if not self.release.wait(timeout=2):
            raise TimeoutError("test pipeline was not released")
        pack_path = Path(tempfile.gettempdir()) / f"map-blocking-{job.job_id}.zip"
        pack_path.write_bytes(b"zip-data")
        return "map-blocking", pack_path


class ArtifactPipeline:
    def build(self, job, on_status=None, on_progress=None):
        pack_path = Path(tempfile.gettempdir()) / f"map-artifact-{job.job_id}.zip"
        pack_path.write_bytes(b"zip-data")
        artifact = ArtifactRecord(
            format="bike-map-stream-v1",
            media_type="application/vnd.openbikecomputer.map-stream",
            filename="map-123.bmap",
            object_key=f"maps/map-123/bike-map-stream-v1/map-prod-1/{'4' * 64}.bmap",
            bytes=100,
            sha256="2" * 64,
            manifest_receipt="3" * 64,
            signed_manifest_receipt="4" * 64,
            signature_key_id="map-prod-1",
        )
        return MapBuildResult(
            map_id="map-123",
            legacy_archive_path=pack_path,
            artifacts=[artifact],
            artifact_metrics={"streamPayloadBytes": 42},
        )


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.source = SourceRegion(
            id="sg",
            provider="test",
            name="Singapore",
            url="https://example.invalid/sg.osm.pbf",
            bounds=Bounds(103.0, 1.0, 104.5, 1.8),
            local_path="map-platform/backend/data/source-pbf/sg.osm.pbf",
        )

    def test_worker_claims_and_completes_queued_job(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp)
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job({"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]})

            result = MapWorker(store, FakePipeline(), worker_id="worker-test").run_next()
            loaded = store.get(job.job_id)

            self.assertTrue(result.processed)
            self.assertEqual(loaded.status.value, "ready")
            self.assertEqual(loaded.attempts, 1)
            self.assertEqual(loaded.worker_id, "worker-test")
            self.assertEqual(loaded.pack_bytes, 8)
            response = loaded.to_dict()
            self.assertEqual(response["packBytes"], 8)
            self.assertEqual(response["progress"]["completedBlocks"], 8)
            self.assertEqual(response["progress"]["totalBlocks"], 10)
            self.assertEqual(response["progress"]["fraction"], 0.8)
            timings = response["phaseTimings"]
            self.assertTrue(any(timing["status"] == "ready" for timing in timings))
            self.assertTrue(all("durationSeconds" in timing for timing in timings))

    def test_worker_persists_immutable_artifact_metadata_and_metrics(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp)
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]}
            )

            result = MapWorker(
                store,
                ArtifactPipeline(),
                worker_id="worker-artifact",
            ).run_next()
            loaded = store.get(job.job_id)

            self.assertTrue(result.processed)
            self.assertEqual(loaded.status, JobStatus.READY)
            self.assertEqual(loaded.artifacts[0].format, "bike-map-stream-v1")
            self.assertEqual(loaded.artifacts[0].signed_manifest_receipt, "4" * 64)
            self.assertEqual(loaded.artifact_metrics["streamPayloadBytes"], 42)

    def test_worker_emits_and_persists_monitoring_timing(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp) / "jobs")
            monitoring = MapMonitoringStore(Path(tmp) / "map-monitoring.sqlite3")
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]}
            )

            result = MapWorker(
                store,
                FakePipeline(),
                worker_id="worker-monitoring",
                monitoring_store=monitoring,
            ).run_next()

            self.assertTrue(result.processed)
            self.assertEqual(result.monitoring_event["event"], "map_job_run_completed")
            self.assertTrue(result.monitoring_event["monitoringPersisted"])
            self.assertEqual(result.monitoring_event["jobId"], job.job_id)
            self.assertIsNotNone(store.get(job.job_id).to_dict()["serverTiming"]["processingSeconds"])

            reopened = MapMonitoringStore(Path(tmp) / "map-monitoring.sqlite3")
            self.assertEqual(reopened.summary()["runs"]["count"], 1)

    def test_worker_removes_stale_queue_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp, lock_stale_seconds=-1)
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job({"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]})
            (Path(tmp) / ".queue.lock").write_text("dead-worker")

            result = MapWorker(store, FakePipeline(), worker_id="worker-test").run_next()
            loaded = store.get(job.job_id)

            self.assertTrue(result.processed)
            self.assertEqual(loaded.status.value, "ready")

    def test_worker_requeues_retryable_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp)
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job({"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]})

            worker = MapWorker(store, FakePipeline(failures=1), worker_id="worker-test")
            first = worker.run_next()
            second = worker.run_next()
            loaded = store.get(job.job_id)

            self.assertTrue(first.processed)
            self.assertTrue(second.processed)
            self.assertEqual(loaded.status.value, "ready")
            self.assertEqual(loaded.attempts, 2)
            self.assertIsNotNone(loaded.finished_at)
            first_queued_event = next(event for event in first.job.events if event["status"] == "queued")
            self.assertIsNone(first.job.finished_at)
            self.assertIsNone(first.job.to_dict()["progress"])
            self.assertEqual(first.job.to_dict()["errorCode"], "map_build_failed")
            self.assertEqual(first_queued_event["message"], "queued for retry")

    def test_monitoring_skips_retryable_attempt_until_job_finishes(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp) / "jobs")
            monitoring = MapMonitoringStore(Path(tmp) / "map-monitoring.sqlite3")
            service = MapJobService(SourceIndex([self.source]), store)
            service.create_job(
                {"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]}
            )
            worker = MapWorker(
                store,
                FakePipeline(failures=1),
                worker_id="worker-retry-monitoring",
                monitoring_store=monitoring,
            )

            first = worker.run_next()
            self.assertFalse(first.monitoring_event["monitoringPersisted"])
            self.assertEqual(monitoring.summary()["runs"]["count"], 0)

            second = worker.run_next()
            self.assertTrue(second.monitoring_event["monitoringPersisted"])
            self.assertEqual(monitoring.summary()["runs"]["count"], 1)

    def test_monitoring_event_reports_store_return_value(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp) / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            service.create_job(
                {"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]}
            )
            monitoring = Mock()
            monitoring.record_job.return_value = False

            result = MapWorker(
                store,
                FakePipeline(),
                worker_id="worker-monitoring-return-value",
                monitoring_store=monitoring,
            ).run_next()

            self.assertFalse(result.monitoring_event["monitoringPersisted"])
            monitoring.record_job.assert_called_once()

    def test_worker_ignores_cancelled_job(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp)
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job({"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]})
            service.cancel_job(job.job_id)

            result = MapWorker(store, FakePipeline(), worker_id="worker-test").run_next()

            self.assertFalse(result.processed)
            self.assertEqual(store.get(job.job_id).status.value, "cancelled")

    def test_worker_does_not_overwrite_cancelled_job_at_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp)
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job({"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]})

            result = MapWorker(store, CancellingPipeline(service), worker_id="worker-test").run_next()
            loaded = store.get(job.job_id)

            self.assertTrue(result.processed)
            self.assertEqual(loaded.status.value, "cancelled")
            self.assertIsNone(loaded.map_id)

    def test_new_worker_requeues_job_interrupted_by_previous_worker(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp)
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job({"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]})
            self.assertIsNotNone(store.claim_next("worker-old"))
            store.update_status(job.job_id, JobStatus.CONVERTING_FEATURES, worker_id="worker-old")
            store.update_progress_unless_cancelled(job.job_id, 6, 10, worker_id="worker-old")

            result = MapWorker(
                store,
                FakePipeline(),
                worker_id="worker-new",
                interrupted_job_stale_seconds=0,
            ).run_next()
            loaded = store.get(job.job_id)

            self.assertTrue(result.processed)
            self.assertEqual(loaded.status, JobStatus.READY)
            self.assertEqual(loaded.attempts, 2)
            self.assertTrue(any(event["message"] == "requeued after worker restart" for event in loaded.events))

    def test_new_worker_leaves_fresh_foreign_job_running(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp)
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job({"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]})
            self.assertIsNotNone(store.claim_next("worker-old"))
            store.update_status(job.job_id, JobStatus.CONVERTING_FEATURES, worker_id="worker-old")

            claimed = store.claim_next("worker-new", interrupted_job_stale_seconds=60)
            loaded = store.get(job.job_id)

            self.assertIsNone(claimed)
            self.assertEqual(loaded.status, JobStatus.CONVERTING_FEATURES)
            self.assertEqual(loaded.worker_id, "worker-old")

    def test_previous_worker_cannot_write_after_job_is_reclaimed(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp)
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job({"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]})
            self.assertIsNotNone(store.claim_next("worker-old"))
            store.update_status(job.job_id, JobStatus.CONVERTING_FEATURES, worker_id="worker-old")
            reclaimed = store.claim_next("worker-new", interrupted_job_stale_seconds=0)
            self.assertIsNotNone(reclaimed)

            with self.assertRaisesRegex(RuntimeError, "owned by another worker"):
                store.update_progress_unless_cancelled(job.job_id, 7, 10, worker_id="worker-old")

            loaded = store.get(job.job_id)
            self.assertEqual(loaded.worker_id, "worker-new")
            self.assertIsNone(loaded.progress_completed)

    def test_previous_worker_cannot_publish_after_job_is_reclaimed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job({"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]})
            self.assertIsNotNone(store.claim_next("worker-old"))
            store.update_status(job.job_id, JobStatus.PACKAGING, worker_id="worker-old")
            old_archive = root / "old-attempt.zip"
            old_archive.write_bytes(b"old")

            reclaimed = store.claim_next("worker-new", interrupted_job_stale_seconds=0)
            self.assertIsNotNone(reclaimed)
            new_archive = root / "new-attempt.zip"
            new_archive.write_bytes(b"new")
            published = root / "packs" / "map.zip"
            store.complete_job(
                job.job_id,
                worker_id="worker-new",
                map_id="map-new",
                built_archive=new_archive,
                published_archive=published,
            )

            with self.assertRaisesRegex(RuntimeError, "owned by another worker"):
                store.complete_job(
                    job.job_id,
                    worker_id="worker-old",
                    map_id="map-old",
                    built_archive=old_archive,
                    published_archive=published,
                )

            self.assertEqual(published.read_bytes(), b"new")
            self.assertEqual(store.get(job.job_id).map_id, "map-new")

    def test_live_worker_heartbeat_prevents_reclaim_during_long_phase(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp)
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job({"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]})
            pipeline = BlockingPipeline()
            worker_heartbeat = threading.Event()
            first_worker = MapWorker(
                store,
                pipeline,
                worker_id="worker-live",
                interrupted_job_stale_seconds=0.03,
                heartbeat_interval_seconds=0.005,
                on_heartbeat=worker_heartbeat.set,
            )
            results = []
            thread = threading.Thread(target=lambda: results.append(first_worker.run_next()))
            thread.start()
            self.assertTrue(pipeline.started.wait(timeout=1))
            self.assertTrue(worker_heartbeat.wait(timeout=1))
            time.sleep(0.06)
            worker_heartbeat.clear()
            self.assertTrue(worker_heartbeat.wait(timeout=1))

            second = MapWorker(
                store,
                FakePipeline(),
                worker_id="worker-second",
                interrupted_job_stale_seconds=0.03,
                heartbeat_interval_seconds=0.005,
            ).run_next()
            pipeline.release.set()
            thread.join(timeout=2)

            self.assertFalse(second.processed)
            self.assertEqual(len(results), 1)
            self.assertEqual(store.get(job.job_id).status, JobStatus.READY)
            self.assertEqual(store.get(job.job_id).worker_id, "worker-live")

    def test_synchronous_run_preserves_cancellation_from_progress_callback(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp)
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job({"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]})

            result = run_job(store, CancellingPipeline(service), job.job_id)

            self.assertEqual(result.status, JobStatus.CANCELLED)
            self.assertEqual(store.get(job.job_id).status, JobStatus.CANCELLED)

    def test_synchronous_run_rejects_cancelled_or_owned_job(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp)
            service = MapJobService(SourceIndex([self.source]), store)
            cancelled = service.create_job({"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]})
            service.cancel_job(cancelled.job_id)

            with self.assertRaisesRegex(JobClaimError, "cancelled, not queued"):
                run_job(store, FakePipeline(), cancelled.job_id)
            self.assertEqual(store.get(cancelled.job_id).status, JobStatus.CANCELLED)

            active = service.create_job({"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]})
            self.assertIsNotNone(store.claim_next("worker-active"))
            with self.assertRaisesRegex(JobClaimError, "validating, not queued"):
                run_job(store, FakePipeline(), active.job_id)
            self.assertEqual(store.get(active.job_id).worker_id, "worker-active")

    def test_cancel_does_not_overwrite_completed_job(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp)
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job({"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]})
            ready = MapWorker(store, FakePipeline(), worker_id="worker-test").run_next().job

            cancelled = service.cancel_job(job.job_id)

            self.assertEqual(ready.status, JobStatus.READY)
            self.assertEqual(cancelled.status, JobStatus.READY)
            self.assertEqual(cancelled.map_id, "map-123")

    def test_expire_ready_jobs_and_cleanup_work_dirs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job({"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]})
            store.update_status(job.job_id, status=store.get(job.job_id).status)
            store.update_status(job.job_id, status=store.get(job.job_id).status)
            ready = MapWorker(store, FakePipeline(), worker_id="worker-test").run_next().job
            self.assertIsNotNone(ready)
            ready_pack_path = Path(ready.pack_path)
            self.assertTrue(ready_pack_path.exists())
            job_path = root / "jobs" / f"{job.job_id}.json"
            persisted = json.loads(job_path.read_text())
            persisted["updatedAt"] = "2020-01-01T00:00:00Z"
            persisted["finishedAt"] = "2020-01-01T00:00:00Z"
            job_path.write_text(json.dumps(persisted))
            expired = expire_ready_jobs(store, older_than_days=1)

            stale_dir = root / "work" / job.job_id
            stale_dir.mkdir(parents=True)
            removed = cleanup_work_dirs(root / "work", store)

            self.assertEqual(expired, 1)
            self.assertFalse(ready_pack_path.exists())
            self.assertEqual(removed, 1)
            with self.assertRaisesRegex(ValueError, "between 1 and 3650"):
                expire_ready_jobs(store, older_than_days=0)

    def test_work_cleanup_reports_partial_progress_after_attempting_all_dirs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            work_root = root / "work"
            deleted_before_path = work_root / "a-deleted-before"
            failed_path = work_root / "b-failed"
            deleted_after_path = work_root / "c-deleted-after"
            for path in (
                deleted_before_path,
                failed_path,
                deleted_after_path,
            ):
                path.mkdir(parents=True)
            original_rmtree = shutil.rmtree

            def selective_rmtree(path, *args, **kwargs):
                if (
                    path.parent.name == ".cleanup"
                    and path.name.startswith(f"{failed_path.name}-")
                ):
                    raise PermissionError("work cleanup blocked")
                return original_rmtree(path, *args, **kwargs)

            with patch("map_platform.worker.shutil.rmtree", selective_rmtree):
                with self.assertRaises(WorkDirectoryCleanupError) as context:
                    cleanup_work_dirs(work_root, store)

            self.assertEqual(context.exception.removed, 2)
            self.assertEqual(len(context.exception.failed_paths), 1)
            retained_tombstone = context.exception.failed_paths[0]
            self.assertEqual(retained_tombstone.parent.name, ".cleanup")
            self.assertTrue(
                retained_tombstone.name.startswith(f"{failed_path.name}-")
            )
            self.assertFalse(deleted_before_path.exists())
            self.assertFalse(failed_path.exists())
            self.assertFalse(deleted_after_path.exists())
            self.assertTrue(retained_tombstone.exists())

    def test_work_cleanup_aggregates_inspection_failure_and_continues(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            work_root = root / "work"
            deleted_before_path = work_root / "a-deleted-before"
            failed_path = work_root / "b-inspection-fails"
            deleted_after_path = work_root / "c-deleted-after"
            for path in (
                deleted_before_path,
                failed_path,
                deleted_after_path,
            ):
                path.mkdir(parents=True)
            original_is_dir = Path.is_dir

            def selective_is_dir(path):
                if path == failed_path:
                    raise PermissionError(13, "directory inspection blocked")
                return original_is_dir(path)

            with patch.object(Path, "is_dir", selective_is_dir):
                with self.assertRaises(WorkDirectoryCleanupError) as context:
                    cleanup_work_dirs(work_root, store)

            self.assertEqual(context.exception.removed, 2)
            self.assertEqual(context.exception.failed_paths, (failed_path,))
            self.assertFalse(deleted_before_path.exists())
            self.assertTrue(failed_path.exists())
            self.assertFalse(deleted_after_path.exists())

    def test_work_cleanup_enumerates_retained_jobs_once_per_batch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            work_root = root / "work"
            for name in ("a-stale", "b-stale", "c-stale"):
                (work_root / name).mkdir(parents=True)

            original_list_with_failures = store.list_with_failures
            with patch.object(
                store,
                "list_with_failures",
                wraps=original_list_with_failures,
            ) as enumerate_jobs:
                removed = cleanup_work_dirs(work_root, store)

            self.assertEqual(removed, 3)
            self.assertEqual(enumerate_jobs.call_count, 1)

    def test_work_cleanup_rechecks_active_status_under_job_record_fence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
            )
            store.update_status(job.job_id, JobStatus.FAILED, finished=True)
            work_root = root / "work"
            job_work_dir = work_root / job.job_id
            job_work_dir.mkdir(parents=True)
            enumerated = threading.Event()
            resume = threading.Event()
            original_iterdir = Path.iterdir
            result = []

            def paused_iterdir(path):
                entries = list(original_iterdir(path))
                if path == work_root:
                    enumerated.set()
                    self.assertTrue(resume.wait(timeout=2))
                return iter(entries)

            def run_cleanup():
                result.append(cleanup_work_dirs(work_root, store))

            with patch.object(Path, "iterdir", paused_iterdir):
                cleanup = threading.Thread(target=run_cleanup)
                cleanup.start()
                self.assertTrue(enumerated.wait(timeout=1))
                with store.lock_job_records():
                    active = store.get(job.job_id)
                    active.status = JobStatus.VALIDATING
                    store.save(active)
                    resume.set()
                cleanup.join(timeout=2)

            self.assertFalse(cleanup.is_alive())
            self.assertEqual(result, [0])
            self.assertTrue(job_work_dir.exists())

    def test_work_cleanup_deletes_tombstone_without_holding_job_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
            )
            store.update_status(job.job_id, JobStatus.FAILED, finished=True)
            work_root = root / "work"
            job_work_dir = work_root / job.job_id
            job_work_dir.mkdir(parents=True)
            delete_started = threading.Event()
            release_delete = threading.Event()
            transition_finished = threading.Event()
            original_rmtree = shutil.rmtree
            result = []

            def blocking_rmtree(path, *args, **kwargs):
                if path.parent.name == ".cleanup":
                    delete_started.set()
                    self.assertTrue(release_delete.wait(timeout=2))
                return original_rmtree(path, *args, **kwargs)

            def run_cleanup():
                result.append(cleanup_work_dirs(work_root, store))

            def reactivate_job():
                store.update_status(job.job_id, JobStatus.VALIDATING)
                job_work_dir.mkdir(parents=True)
                transition_finished.set()

            with patch("map_platform.worker.shutil.rmtree", blocking_rmtree):
                cleanup = threading.Thread(target=run_cleanup)
                cleanup.start()
                self.assertTrue(delete_started.wait(timeout=1))
                transition = threading.Thread(target=reactivate_job)
                transition.start()
                self.assertTrue(transition_finished.wait(timeout=1))
                release_delete.set()
                transition.join(timeout=2)
                cleanup.join(timeout=2)

            self.assertFalse(cleanup.is_alive())
            self.assertFalse(transition.is_alive())
            self.assertEqual(result, [1])
            self.assertTrue(job_work_dir.exists())

    def test_expiry_failure_preserves_progress_and_still_cleans_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            ready_jobs = []
            for index in range(3):
                job = service.create_job(
                    {
                        "mode": "custom_bbox",
                        "bbox": [
                            103.75 + index * 0.001,
                            1.24,
                            103.93,
                            1.37,
                        ],
                    }
                )
                ready = store.update_status(
                    job.job_id,
                    JobStatus.READY,
                    finished=True,
                )
                ready.finished_at = "2000-01-01T00:00:00Z"
                store.save(ready)
                ready_jobs.append(ready)
            ordered_ready = sorted(ready_jobs, key=lambda job: job.job_id)
            blocked_job = ordered_ready[1]

            legacy_path = root / "packs" / "already-expired.zip"
            legacy_path.parent.mkdir(parents=True)
            legacy_path.write_bytes(b"expired")
            legacy_job = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.8, 1.24, 103.93, 1.37],
                }
            )
            store.update_status(
                legacy_job.job_id,
                JobStatus.EXPIRED,
                pack_path=str(legacy_path),
                finished=True,
            )

            original_update_status = store.update_status

            def selective_update(job_id, status, *args, **kwargs):
                if job_id == blocked_job.job_id and status == JobStatus.EXPIRED:
                    raise PermissionError(13, "job status write blocked")
                return original_update_status(job_id, status, *args, **kwargs)

            with patch.object(
                store,
                "update_status",
                side_effect=selective_update,
            ):
                with self.assertRaises(ExpiredArtifactCleanupError) as context:
                    expire_ready_jobs(store, older_than_days=30)

            self.assertEqual(context.exception.expired_jobs, 2)
            self.assertEqual(context.exception.removed, 1)
            self.assertEqual(
                context.exception.failed_expiry_job_ids,
                (blocked_job.job_id,),
            )
            self.assertEqual(store.get(blocked_job.job_id).status, JobStatus.READY)
            self.assertEqual(
                [
                    store.get(job.job_id).status
                    for job in (ordered_ready[0], ordered_ready[2])
                ],
                [JobStatus.EXPIRED, JobStatus.EXPIRED],
            )
            self.assertFalse(legacy_path.exists())

    def test_corrupt_job_record_does_not_starve_valid_expiry_or_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            ready_job = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
            )
            ready = store.update_status(
                ready_job.job_id,
                JobStatus.READY,
                finished=True,
            )
            ready.finished_at = "2000-01-01T00:00:00Z"
            store.save(ready)

            legacy_path = root / "packs" / "already-expired.zip"
            legacy_path.parent.mkdir(parents=True)
            legacy_path.write_bytes(b"expired")
            legacy_job = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.8, 1.24, 103.93, 1.37],
                }
            )
            store.update_status(
                legacy_job.job_id,
                JobStatus.EXPIRED,
                pack_path=str(legacy_path),
                finished=True,
            )
            corrupt_path = root / "jobs" / "corrupt-job.json"
            corrupt_path.write_text("{\"jobId\":")

            with self.assertRaises(ExpiredArtifactCleanupError) as context:
                expire_ready_jobs(store, older_than_days=30)

            self.assertEqual(context.exception.expired_jobs, 1)
            self.assertEqual(context.exception.removed, 0)
            self.assertEqual(
                context.exception.failed_job_record_paths,
                (corrupt_path,),
            )
            self.assertEqual(store.get(ready_job.job_id).status, JobStatus.EXPIRED)
            self.assertTrue(legacy_path.exists())
            self.assertTrue(corrupt_path.exists())

    def test_corrupt_ready_record_blocks_shared_pack_and_object_deletion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            shared_path = root / "packs" / "shared.zip"
            shared_path.parent.mkdir(parents=True)
            shared_path.write_bytes(b"shared")
            object_key = "maps/map/stream/shared.bmap"
            artifact = ArtifactRecord(
                format="test-artifact-v1",
                media_type="application/octet-stream",
                filename="shared.bmap",
                object_key=object_key,
                bytes=6,
                sha256="1" * 64,
            )

            expired_job = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
            )
            expired = store.update_status(
                expired_job.job_id,
                JobStatus.EXPIRED,
                pack_path=str(shared_path),
                finished=True,
            )
            expired.artifact_gc_keys = [object_key]
            store.save(expired)

            ready_job = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.76, 1.24, 103.93, 1.37],
                }
            )
            store.update_status(
                ready_job.job_id,
                JobStatus.READY,
                pack_path=str(shared_path),
                artifacts=[artifact],
                finished=True,
            )
            ready_path = root / "jobs" / f"{ready_job.job_id}.json"
            ready_record = ready_path.read_text()
            ready_path.write_text("{\"jobId\":")

            with self.assertRaises(ExpiredArtifactCleanupError) as context:
                cleanup_expired_pack_artifacts(store)
            self.assertEqual(context.exception.removed, 0)
            self.assertTrue(shared_path.exists())

            class TrackingDeleteStore:
                def __init__(self):
                    self.deleted = []

                def delete(self, key):
                    self.deleted.append(key)
                    return True

            artifact_store = TrackingDeleteStore()
            with self.assertRaises(JobRecordEnumerationError):
                store.cleanup_artifact_garbage(artifact_store)
            self.assertEqual(artifact_store.deleted, [])

            ready_path.write_text(ready_record)
            restored = store.get(ready_job.job_id)
            self.assertEqual(restored.status, JobStatus.READY)
            self.assertEqual(restored.pack_path, str(shared_path))
            self.assertEqual(restored.artifacts[0].object_key, object_key)

    def test_malformed_nested_job_schema_isolated_at_startup_and_scan(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
            )
            job_path = root / "jobs" / f"{job.job_id}.json"
            malformed = json.loads(job_path.read_text())
            malformed["request"] = []
            job_path.write_text(json.dumps(malformed))

            reopened = JobStore(root / "jobs")
            jobs, failures = reopened.list_with_failures()

            self.assertEqual(jobs, [])
            self.assertEqual(len(failures), 1)
            self.assertEqual(failures[0][0], job_path)
            self.assertIsInstance(failures[0][1], AttributeError)

    def test_expiry_removes_only_unreferenced_pack_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            unique_path = root / "packs" / "map-unique" / "stale.zip"
            shared_path = root / "packs" / "map-shared.zip"
            unique_path.parent.mkdir(parents=True)
            unique_path.write_bytes(b"unique")
            shared_path.write_bytes(b"shared")

            stale_unique = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]}
            )
            stale_shared = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.76, 1.25, 103.94, 1.38]}
            )
            live_shared = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.77, 1.26, 103.95, 1.39]}
            )
            for job, path in [
                (stale_unique, unique_path),
                (stale_shared, shared_path),
                (live_shared, shared_path),
            ]:
                store.update_status(
                    job.job_id,
                    JobStatus.READY,
                    map_id="map-retention",
                    pack_path=str(path),
                    finished=True,
                )
            for stale in [stale_unique, stale_shared]:
                persisted = store.get(stale.job_id)
                persisted.updated_at = "2000-01-01T00:00:00Z"
                persisted.finished_at = "2000-01-01T00:00:00Z"
                store.save(persisted)

            expired = expire_ready_jobs(store, older_than_days=30)

            self.assertEqual(expired, 2)
            self.assertFalse(unique_path.exists())
            self.assertTrue(shared_path.exists())
            self.assertEqual(store.get(live_shared.job_id).status, JobStatus.READY)

    def test_ready_retention_is_not_extended_by_label_or_download_activity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]}
            )
            pack_path = root / "packs" / "retained.zip"
            pack_path.parent.mkdir(parents=True)
            pack_path.write_bytes(b"retained")
            ready = store.update_status(
                job.job_id,
                JobStatus.READY,
                map_id="map-retention-anchor",
                pack_path=str(pack_path),
                finished=True,
            )
            ready.finished_at = "2000-01-01T00:00:00Z"
            store.save(ready)

            store.update_user_label(job.job_id, "Recent label")
            store.update_status(
                job.job_id,
                JobStatus.READY,
                event="ready metadata refreshed",
            )
            store.record_download(
                job.job_id,
                MapDownloadReceipt(
                    receipt_id="receipt-recent",
                    artifact_format="zip-stored-v1",
                    bytes=len(b"retained"),
                    downloaded_at="2026-07-19T00:00:00Z",
                ),
            )
            active = store.get(job.job_id)
            self.assertNotEqual(active.updated_at, active.finished_at)

            self.assertEqual(expire_ready_jobs(store, older_than_days=30), 1)
            self.assertEqual(store.get(job.job_id).status, JobStatus.EXPIRED)
            self.assertFalse(pack_path.exists())

    def test_expiry_removes_only_unreferenced_content_addressed_objects(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            artifact_store = FileSystemArtifactStore(root / "artifacts")
            service = MapJobService(SourceIndex([self.source]), store)
            unique_source = root / "unique.bmap"
            shared_source = root / "shared.bmap"
            pending_source = root / "pending.bmap"
            unique_source.write_bytes(b"unique-object")
            shared_source.write_bytes(b"shared-object")
            pending_source.write_bytes(b"pending-object")

            def record(source: Path, key: str) -> ArtifactRecord:
                digest = sha256_file(source)
                artifact_store.put(
                    source,
                    key,
                    sha256=digest,
                    media_type="application/octet-stream",
                )
                return ArtifactRecord(
                    format="test-artifact-v1",
                    media_type="application/octet-stream",
                    filename=source.name,
                    object_key=key,
                    bytes=source.stat().st_size,
                    sha256=digest,
                )

            unique = record(unique_source, "maps/map/stream/unique.bmap")
            shared = record(shared_source, "maps/map/stream/shared.bmap")
            pending = record(pending_source, "maps/map/stream/pending.bmap")
            stale_unique = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]}
            )
            stale_shared = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.76, 1.25, 103.94, 1.38]}
            )
            live_shared = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.77, 1.26, 103.95, 1.39]}
            )
            publishing = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.78, 1.27, 103.96, 1.40]}
            )
            store.claim(publishing.job_id, "worker-publishing")
            store.add_pending_artifact_unless_cancelled(
                publishing.job_id,
                pending.object_key,
                worker_id="worker-publishing",
            )
            for job, artifacts in [
                (stale_unique, [unique]),
                (stale_shared, [shared]),
                (live_shared, [shared]),
            ]:
                ready = store.update_status(
                    job.job_id,
                    JobStatus.READY,
                    map_id="map-retention",
                    artifacts=artifacts,
                    finished=True,
                )
                if job != live_shared:
                    ready.updated_at = "2000-01-01T00:00:00Z"
                    ready.finished_at = "2000-01-01T00:00:00Z"
                    store.save(ready)

            expired = expire_ready_jobs(
                store,
                older_than_days=30,
                artifact_store=artifact_store,
            )

            self.assertEqual(expired, 2)
            self.assertIsNone(artifact_store.local_path(unique.object_key))
            self.assertIsNotNone(artifact_store.local_path(shared.object_key))
            self.assertIsNotNone(artifact_store.local_path(pending.object_key))

    def test_terminal_pending_cleanup_deletes_or_retries_unreferenced_objects(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            artifact_store = FileSystemArtifactStore(root / "artifacts")
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]}
            )
            store.claim(job.job_id, "worker-cleanup")

            source = root / "pending.bmap"
            source.write_bytes(b"pending-terminal-object")
            digest = sha256_file(source)
            object_key = f"maps/map/stream/{digest}.bmap"
            artifact_store.put(
                source,
                object_key,
                sha256=digest,
                media_type="application/octet-stream",
            )
            store.add_pending_artifact_unless_cancelled(
                job.job_id,
                object_key,
                worker_id="worker-cleanup",
            )
            store.update_status(
                job.job_id,
                JobStatus.FAILED,
                worker_id="worker-cleanup",
                finished=True,
            )

            class FailingDeleteStore:
                def delete(self, key):
                    raise RuntimeError(f"temporary delete failure for {key}")

            self.assertEqual(store.queue_terminal_pending_artifacts(job.job_id), 1)
            with self.assertRaises(ArtifactGarbageCollectionError) as context:
                store.cleanup_artifact_garbage(FailingDeleteStore())
            self.assertEqual(context.exception.removed, 0)
            self.assertEqual(context.exception.failed_object_keys, (object_key,))
            self.assertEqual(store.get(job.job_id).pending_artifact_keys, [])
            self.assertEqual(store.get(job.job_id).artifact_gc_keys, [object_key])
            self.assertIsNotNone(artifact_store.local_path(object_key))

            self.assertEqual(store.cleanup_artifact_garbage(artifact_store), 1)
            self.assertEqual(store.get(job.job_id).pending_artifact_keys, [])
            self.assertEqual(store.get(job.job_id).artifact_gc_keys, [])
            self.assertIsNone(artifact_store.local_path(object_key))

    def test_expiry_surfaces_delete_failure_after_attempting_the_full_batch(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp) / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]}
            )
            failed_key = "maps/map/stream/retention-failure.bmap"
            deleted_key = "maps/map/stream/retention-success.bmap"
            ready = store.update_status(
                job.job_id,
                JobStatus.READY,
                artifacts=[
                    ArtifactRecord(
                        format="test-artifact-v1",
                        media_type="application/octet-stream",
                        filename="retention-failure.bmap",
                        object_key=failed_key,
                        bytes=10,
                        sha256="1" * 64,
                    ),
                    ArtifactRecord(
                        format="test-artifact-v1",
                        media_type="application/octet-stream",
                        filename="retention-success.bmap",
                        object_key=deleted_key,
                        bytes=10,
                        sha256="2" * 64,
                    ),
                ],
                finished=True,
            )
            ready.finished_at = "2000-01-01T00:00:00Z"
            store.save(ready)

            class PartiallyFailingDeleteStore:
                def __init__(self):
                    self.deleted = []

                def delete(self, key):
                    if key == failed_key:
                        raise PermissionError(key)
                    self.deleted.append(key)
                    return True

            artifact_store = PartiallyFailingDeleteStore()
            with self.assertRaises(ExpiredArtifactCleanupError) as context:
                expire_ready_jobs(
                    store,
                    older_than_days=30,
                    artifact_store=artifact_store,
                )

            self.assertEqual(context.exception.removed, 1)
            self.assertIsNotNone(context.exception.object_failure)
            self.assertEqual(
                context.exception.object_failure.failed_object_keys,
                (failed_key,),
            )
            self.assertEqual(artifact_store.deleted, [deleted_key])
            expired = store.get(job.job_id)
            self.assertEqual(expired.status, JobStatus.EXPIRED)
            self.assertEqual(expired.artifacts, [])
            self.assertEqual(expired.artifact_gc_keys, [failed_key])

    def test_legacy_pack_failure_is_aggregated_after_later_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            failed_path = root / "packs" / "failed" / "map.zip"
            deleted_path = root / "packs" / "deleted" / "map.zip"
            for path in (failed_path, deleted_path):
                path.parent.mkdir(parents=True)
                path.write_bytes(path.parent.name.encode())
                job = service.create_job(
                    {
                        "mode": "custom_bbox",
                        "bbox": [103.75, 1.24, 103.93, 1.37],
                    }
                )
                store.update_status(
                    job.job_id,
                    JobStatus.EXPIRED,
                    pack_path=str(path),
                    finished=True,
                )

            original_unlink = Path.unlink

            def selective_unlink(path, *args, **kwargs):
                if path == failed_path:
                    raise PermissionError("legacy pack delete blocked")
                return original_unlink(path, *args, **kwargs)

            with patch.object(Path, "unlink", selective_unlink):
                with self.assertRaises(ExpiredArtifactCleanupError) as context:
                    cleanup_expired_pack_artifacts(store)

            self.assertEqual(context.exception.removed, 1)
            self.assertEqual(
                context.exception.failed_legacy_paths,
                (failed_path,),
            )
            self.assertTrue(failed_path.exists())
            self.assertFalse(deleted_path.exists())

    def test_unexpected_object_gc_failure_is_aggregated_after_legacy_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            legacy_path = root / "packs" / "legacy" / "map.zip"
            legacy_path.parent.mkdir(parents=True)
            legacy_path.write_bytes(b"legacy")
            job = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
            )
            store.update_status(
                job.job_id,
                JobStatus.EXPIRED,
                pack_path=str(legacy_path),
                finished=True,
            )
            failure = RuntimeError("artifact GC cursor failed")

            with patch.object(
                store,
                "cleanup_artifact_garbage",
                side_effect=failure,
            ):
                with self.assertRaises(ExpiredArtifactCleanupError) as context:
                    cleanup_expired_pack_artifacts(
                        store,
                        artifact_store=object(),
                    )

            self.assertEqual(context.exception.removed, 1)
            self.assertIs(context.exception.object_failure, failure)
            self.assertFalse(legacy_path.exists())

    def test_object_gc_counts_deletes_before_retryable_metadata_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            keys = [
                "maps/map/stream/a-deleted.bmap",
                "maps/map/stream/b-metadata-failure.bmap",
            ]
            for index, key in enumerate(keys):
                job = service.create_job(
                    {
                        "mode": "custom_bbox",
                        "bbox": [
                            103.75 + index * 0.001,
                            1.24,
                            103.93,
                            1.37,
                        ],
                    }
                )
                job.status = JobStatus.FAILED
                job.artifact_gc_keys = [key]
                store.save(job)

            class TrackingDeleteStore:
                def __init__(self, object_keys):
                    self.existing = set(object_keys)
                    self.deleted = []

                def delete(self, key):
                    existed = key in self.existing
                    self.existing.discard(key)
                    self.deleted.append(key)
                    return existed

            artifact_store = TrackingDeleteStore(keys)
            original_remove_gc_key = store._remove_gc_key_unlocked

            def selective_remove(jobs, object_key):
                if object_key == keys[1]:
                    raise PermissionError(13, "metadata update blocked")
                return original_remove_gc_key(jobs, object_key)

            with patch.object(
                store,
                "_remove_gc_key_unlocked",
                side_effect=selective_remove,
            ):
                with self.assertRaises(ArtifactGarbageCollectionError) as context:
                    store.cleanup_artifact_garbage(artifact_store)

            self.assertEqual(context.exception.removed, 2)
            self.assertEqual(
                context.exception.failed_object_keys,
                (keys[1],),
            )
            self.assertEqual(artifact_store.deleted, keys)
            remaining = {
                key
                for job in store.list()
                for key in job.artifact_gc_keys
            }
            self.assertEqual(remaining, {keys[1]})
            self.assertEqual(store.cleanup_artifact_garbage(artifact_store), 0)
            self.assertEqual(
                {
                    key
                    for job in store.list()
                    for key in job.artifact_gc_keys
                },
                set(),
            )

    def test_publication_lease_fences_cancellation_gc_through_object_put(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp) / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]}
            )
            store.claim(job.job_id, "worker-publishing")
            object_key = "maps/map/stream/in-flight.bmap"
            lease_entered = threading.Event()
            release_put = threading.Event()
            cleanup_finished = threading.Event()

            class InFlightStore:
                exists = False

                def delete(self, key):
                    self.assert_key = key
                    existed = self.exists
                    self.exists = False
                    return existed

            artifact_store = InFlightStore()

            def publish():
                with store.artifact_publication_lease(
                    job.job_id,
                    object_key,
                    worker_id="worker-publishing",
                ):
                    lease_entered.set()
                    self.assertTrue(release_put.wait(timeout=2))
                    artifact_store.exists = True

            publication = threading.Thread(target=publish)
            publication.start()
            self.assertTrue(lease_entered.wait(timeout=1))
            service.cancel_job(job.job_id)

            def cleanup():
                store.queue_terminal_pending_artifacts(job.job_id)
                store.cleanup_artifact_garbage(artifact_store)
                cleanup_finished.set()

            collector = threading.Thread(target=cleanup)
            collector.start()
            self.assertFalse(cleanup_finished.wait(timeout=0.05))
            release_put.set()
            publication.join(timeout=2)
            collector.join(timeout=2)

            self.assertTrue(cleanup_finished.is_set())
            self.assertFalse(artifact_store.exists)
            self.assertEqual(store.get(job.job_id).pending_artifact_keys, [])
            self.assertEqual(store.get(job.job_id).artifact_gc_keys, [])

    def test_successful_retry_queues_superseded_pending_artifacts_for_gc(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            artifact_store = FileSystemArtifactStore(root / "artifacts")
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]}
            )
            store.claim(job.job_id, "worker-retry")
            old_source = root / "old.zip"
            new_source = root / "new.zip"
            old_source.write_bytes(b"old-attempt")
            new_source.write_bytes(b"new-attempt")
            old_key = f"maps/map/zip/{sha256_file(old_source)}.zip"
            new_key = f"maps/map/zip/{sha256_file(new_source)}.zip"
            for source, key in [(old_source, old_key), (new_source, new_key)]:
                artifact_store.put(
                    source,
                    key,
                    sha256=sha256_file(source),
                    media_type="application/zip",
                )
                store.add_pending_artifact_unless_cancelled(
                    job.job_id,
                    key,
                    worker_id="worker-retry",
                )
            final = ArtifactRecord(
                format="zip-stored-v1",
                media_type="application/zip",
                filename="new.zip",
                object_key=new_key,
                bytes=new_source.stat().st_size,
                sha256=sha256_file(new_source),
            )
            published = root / "packs" / "new.zip"
            completed = store.complete_job(
                job.job_id,
                worker_id="worker-retry",
                map_id="map-retry",
                built_archive=new_source,
                published_archive=published,
                artifacts=[final],
            )

            self.assertEqual(completed.pending_artifact_keys, [])
            self.assertEqual(completed.artifact_gc_keys, [old_key])
            self.assertEqual(store.cleanup_artifact_garbage(artifact_store), 1)
            self.assertIsNone(artifact_store.local_path(old_key))
            self.assertIsNotNone(artifact_store.local_path(new_key))

    def test_maintenance_recovers_terminal_pending_artifact_after_worker_crash(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            artifact_store = FileSystemArtifactStore(root / "artifacts")
            service = MapJobService(SourceIndex([self.source]), store)
            job = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]}
            )
            claimed = store.claim(job.job_id, "worker-crashed")
            source = root / "crashed.bmap"
            source.write_bytes(b"crashed-attempt")
            object_key = f"maps/map/stream/{sha256_file(source)}.bmap"
            artifact_store.put(
                source,
                object_key,
                sha256=sha256_file(source),
                media_type="application/octet-stream",
            )
            store.add_pending_artifact_unless_cancelled(
                job.job_id,
                object_key,
                worker_id="worker-crashed",
            )
            claimed = store.get(job.job_id)
            claimed.max_attempts = claimed.attempts
            claimed.status = JobStatus.PACKAGING
            claimed.updated_at = "2000-01-01T00:00:00Z"
            store.save(claimed)

            self.assertIsNone(
                store.claim_next("worker-replacement", interrupted_job_stale_seconds=0)
            )
            self.assertEqual(store.get(job.job_id).status, JobStatus.FAILED)
            self.assertEqual(store.cleanup_artifact_garbage(artifact_store), 1)
            recovered = store.get(job.job_id)
            self.assertEqual(recovered.pending_artifact_keys, [])
            self.assertEqual(recovered.artifact_gc_keys, [])
            self.assertIsNone(artifact_store.local_path(object_key))

    def test_artifact_gc_enforces_a_bounded_maintenance_batch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            artifact_store = FileSystemArtifactStore(root / "artifacts")
            service = MapJobService(SourceIndex([self.source]), store)
            keys = []
            for index in range(2):
                source = root / f"garbage-{index}.bmap"
                source.write_bytes(f"garbage-{index}".encode())
                key = f"maps/map/stream/{sha256_file(source)}.bmap"
                artifact_store.put(
                    source,
                    key,
                    sha256=sha256_file(source),
                    media_type="application/octet-stream",
                )
                job = service.create_job(
                    {
                        "mode": "custom_bbox",
                        "bbox": [103.75 + index * 0.001, 1.24, 103.93, 1.37],
                    }
                )
                job.status = JobStatus.FAILED
                job.artifact_gc_keys = [key]
                store.save(job)
                keys.append(key)

            self.assertEqual(
                store.cleanup_artifact_garbage(artifact_store, max_items=1),
                1,
            )
            self.assertEqual(
                sum(artifact_store.local_path(key) is not None for key in keys),
                1,
            )
            self.assertEqual(
                store.cleanup_artifact_garbage(artifact_store, max_items=1),
                1,
            )
            self.assertTrue(
                all(artifact_store.local_path(key) is None for key in keys)
            )

    def test_artifact_gc_bounds_terminal_staging_under_the_queue_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp) / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            for index in range(3):
                job = service.create_job(
                    {
                        "mode": "custom_bbox",
                        "bbox": [103.75 + index * 0.001, 1.24, 103.93, 1.37],
                    }
                )
                worker_id = f"worker-{index}"
                store.claim(job.job_id, worker_id)
                store.add_pending_artifact_unless_cancelled(
                    job.job_id,
                    f"maps/map/stream/pending-{index}.bmap",
                    worker_id=worker_id,
                )
                store.update_status(job.job_id, JobStatus.FAILED, finished=True)

            class FailingDeleteStore:
                def delete(self, key):
                    raise RuntimeError(key)

            with self.assertRaises(ArtifactGarbageCollectionError):
                store.cleanup_artifact_garbage(FailingDeleteStore(), max_items=1)
            jobs = store.list()
            self.assertEqual(sum(bool(job.artifact_gc_keys) for job in jobs), 1)
            self.assertEqual(sum(bool(job.pending_artifact_keys) for job in jobs), 2)

    def test_artifact_gc_cursor_prevents_failed_key_starvation(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp) / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            keys = ["maps/map/stream/a.bmap", "maps/map/stream/b.bmap"]
            for index, key in enumerate(keys):
                job = service.create_job(
                    {
                        "mode": "custom_bbox",
                        "bbox": [103.75 + index * 0.001, 1.24, 103.93, 1.37],
                    }
                )
                job.status = JobStatus.FAILED
                job.artifact_gc_keys = [key]
                store.save(job)

            class PartiallyFailingStore:
                def __init__(self):
                    self.deleted = []

                def delete(self, key):
                    if key == keys[0]:
                        raise RuntimeError("object is under legal hold")
                    self.deleted.append(key)
                    return True

            artifact_store = PartiallyFailingStore()
            with self.assertRaises(ArtifactGarbageCollectionError):
                store.cleanup_artifact_garbage(artifact_store, max_items=1)
            self.assertEqual(
                store.cleanup_artifact_garbage(artifact_store, max_items=1),
                1,
            )
            self.assertEqual(artifact_store.deleted, [keys[1]])
            remaining = {key for job in store.list() for key in job.artifact_gc_keys}
            self.assertEqual(remaining, {keys[0]})


if __name__ == "__main__":
    unittest.main()
