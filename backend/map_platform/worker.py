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
    def __init__(
        self,
        store: JobStore,
        pipeline: MapBuildPipeline,
        *,
        worker_id: str | None = None,
        interrupted_job_stale_seconds: float = 15 * 60,
        heartbeat_interval_seconds: float = 30.0,
    ):
        self.store = store
        self.pipeline = pipeline
        self.worker_id = worker_id or f"worker-{uuid.uuid4().hex[:8]}"
        self.interrupted_job_stale_seconds = interrupted_job_stale_seconds
        self.heartbeat_interval_seconds = heartbeat_interval_seconds

    def run_next(self) -> WorkerResult:
        self.store.requeue_retryable_failures()
        job = self.store.claim_next(
            self.worker_id,
            interrupted_job_stale_seconds=self.interrupted_job_stale_seconds,
        )
        if job is None:
            return WorkerResult(worker_id=self.worker_id, job=None, processed=False)

        def update(status: JobStatus) -> None:
            self.store.update_status_unless_cancelled(job.job_id, status, worker_id=self.worker_id)

        def update_progress(completed: int, total: int) -> None:
            self.store.update_progress_unless_cancelled(
                job.job_id,
                completed,
                total,
                worker_id=self.worker_id,
            )

        try:
            with self.store.keep_worker_lease_alive(
                job.job_id,
                worker_id=self.worker_id,
                interval_seconds=self.heartbeat_interval_seconds,
            ):
                map_id, archive_path = self.pipeline.build(
                    job,
                    on_status=update,
                    on_progress=update_progress,
                )
            published_archive = (
                self.pipeline.published_archive_path(map_id, job.job_id)
                if hasattr(self.pipeline, "published_archive_path")
                else archive_path
            )
            finished = self.store.complete_job(
                job.job_id,
                worker_id=self.worker_id,
                map_id=map_id,
                built_archive=archive_path,
                published_archive=published_archive,
            )
            return WorkerResult(worker_id=self.worker_id, job=finished, processed=True)
        except Exception as exc:
            current = self.store.get(job.job_id)
            if current.status == JobStatus.CANCELLED or current.worker_id != self.worker_id:
                return WorkerResult(worker_id=self.worker_id, job=current, processed=True)
            failed = self.store.update_status_unless_cancelled(
                job.job_id,
                JobStatus.FAILED,
                error=str(exc),
                worker_id=self.worker_id,
                event=str(exc),
                finished=True,
            )
            if failed.attempts < failed.max_attempts:
                failed = self.store.update_status_unless_cancelled(
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
    if isinstance(older_than_days, bool) or not 1 <= older_than_days <= 3_650:
        raise ValueError("older_than_days must be between 1 and 3650")
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
    cleanup_expired_pack_artifacts(store)
    return count


def cleanup_expired_pack_artifacts(store: JobStore) -> int:
    jobs = store.list()
    protected_paths = {
        Path(job.pack_path)
        for job in jobs
        if job.pack_path and job.status != JobStatus.EXPIRED
    }
    removed = 0
    for pack_path in {
        Path(job.pack_path)
        for job in jobs
        if job.pack_path and job.status == JobStatus.EXPIRED
    }:
        if pack_path in protected_paths or not pack_path.exists():
            continue
        pack_path.unlink()
        removed += 1
        try:
            pack_path.parent.rmdir()
        except OSError:
            pass
    return removed


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
