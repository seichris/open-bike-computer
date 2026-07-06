from __future__ import annotations

import shutil
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .jobs import JobStore
from .models import JobStatus, MapJob
from .pipeline import MapBuildPipeline


@dataclass(frozen=True)
class WorkerResult:
    worker_id: str
    job: MapJob | None
    processed: bool


class MapWorker:
    def __init__(self, store: JobStore, pipeline: MapBuildPipeline, *, worker_id: str | None = None):
        self.store = store
        self.pipeline = pipeline
        self.worker_id = worker_id or f"worker-{uuid.uuid4().hex[:8]}"

    def run_next(self) -> WorkerResult:
        self.store.requeue_retryable_failures()
        job = self.store.claim_next(self.worker_id)
        if job is None:
            return WorkerResult(worker_id=self.worker_id, job=None, processed=False)

        def update(status: JobStatus) -> None:
            self.store.update_status_unless_cancelled(job.job_id, status, worker_id=self.worker_id)

        try:
            map_id, archive_path = self.pipeline.build(job, on_status=update)
            finished = self.store.update_status_unless_cancelled(
                job.job_id,
                JobStatus.READY,
                map_id=map_id,
                pack_path=str(archive_path),
                worker_id=self.worker_id,
                event="map pack ready",
                finished=True,
            )
            return WorkerResult(worker_id=self.worker_id, job=finished, processed=True)
        except Exception as exc:
            current = self.store.get(job.job_id)
            if current.status == JobStatus.CANCELLED:
                return WorkerResult(worker_id=self.worker_id, job=current, processed=True)
            failed = self.store.update_status(
                job.job_id,
                JobStatus.FAILED,
                error=str(exc),
                worker_id=self.worker_id,
                event=str(exc),
                finished=True,
            )
            if failed.attempts < failed.max_attempts:
                failed = self.store.update_status(
                    job.job_id,
                    JobStatus.QUEUED,
                    error=str(exc),
                    worker_id=self.worker_id,
                    event="queued for retry",
                )
            return WorkerResult(worker_id=self.worker_id, job=failed, processed=True)

    def run_until_empty(self, *, max_jobs: int | None = None) -> list[WorkerResult]:
        results: list[WorkerResult] = []
        while max_jobs is None or len(results) < max_jobs:
            result = self.run_next()
            if not result.processed:
                break
            results.append(result)
        return results


def expire_ready_jobs(store: JobStore, *, older_than_days: int) -> int:
    cutoff = datetime.now(timezone.utc) - timedelta(days=older_than_days)
    count = 0
    for job in store.list():
        if job.status != JobStatus.READY:
            continue
        updated = _parse_utc(job.updated_at)
        if updated >= cutoff:
            continue
        store.update_status(job.job_id, JobStatus.EXPIRED, event="expired by retention policy", finished=True)
        count += 1
    return count


def cleanup_work_dirs(work_root: Path, store: JobStore) -> int:
    active = {job.job_id for job in store.list() if job.status not in {JobStatus.READY, JobStatus.FAILED, JobStatus.EXPIRED, JobStatus.CANCELLED}}
    removed = 0
    if not work_root.exists():
        return 0
    for child in work_root.iterdir():
        if not child.is_dir() or child.name in active:
            continue
        shutil.rmtree(child)
        removed += 1
    return removed


def _parse_utc(value: str) -> datetime:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return datetime.fromisoformat(value)
