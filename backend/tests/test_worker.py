import tempfile
import unittest
from pathlib import Path

from map_platform.jobs import JobStore, MapJobService
from map_platform.models import Bounds, SourceRegion
from map_platform.sources import SourceIndex
from map_platform.worker import MapWorker, cleanup_work_dirs, expire_ready_jobs


class FakePipeline:
    def __init__(self, failures=0):
        self.failures = failures
        self.calls = 0

    def build(self, job, on_status=None):
        self.calls += 1
        if self.calls <= self.failures:
            raise RuntimeError("temporary worker failure")
        return "map-123", Path("/tmp/map-123.zip")


class CancellingPipeline:
    def __init__(self, service):
        self.service = service

    def build(self, job, on_status=None):
        self.service.cancel_job(job.job_id)
        return "map-123", Path("/tmp/map-123.zip")


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
            expired = expire_ready_jobs(store, older_than_days=0)

            stale_dir = root / "work" / job.job_id
            stale_dir.mkdir(parents=True)
            removed = cleanup_work_dirs(root / "work", store)

            self.assertEqual(expired, 1)
            self.assertEqual(removed, 1)


if __name__ == "__main__":
    unittest.main()
