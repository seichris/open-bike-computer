import json
import tempfile
import threading
import time
import unittest
from pathlib import Path

from map_platform.jobs import JobClaimError, JobStore, MapJobService
from map_platform.models import Bounds, JobStatus, SourceRegion
from map_platform.pipeline import run_job
from map_platform.sources import SourceIndex
from map_platform.worker import MapWorker, cleanup_work_dirs, expire_ready_jobs


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


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.source = SourceRegion(
            id="sg",
            provider="test",
            name="Singapore",
            url="https://example.invalid/sg.osm.pbf",
            bounds=Bounds(103.0, 1.0, 104.5, 1.8),
            local_path="backend/data/source-pbf/sg.osm.pbf",
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
            self.assertEqual(first_queued_event["message"], "queued for retry")

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
            first_worker = MapWorker(
                store,
                pipeline,
                worker_id="worker-live",
                interrupted_job_stale_seconds=0.03,
                heartbeat_interval_seconds=0.005,
            )
            results = []
            thread = threading.Thread(target=lambda: results.append(first_worker.run_next()))
            thread.start()
            self.assertTrue(pipeline.started.wait(timeout=1))
            time.sleep(0.06)

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
                store.save(persisted)

            expired = expire_ready_jobs(store, older_than_days=30)

            self.assertEqual(expired, 2)
            self.assertFalse(unique_path.exists())
            self.assertTrue(shared_path.exists())
            self.assertEqual(store.get(live_shared.job_id).status, JobStatus.READY)


if __name__ == "__main__":
    unittest.main()
