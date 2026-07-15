from __future__ import annotations

import shutil
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .jobs import JobStore
from .models import JobStatus, MapJob
from .pipeline import MapBuildPipeline
from .reuse import SubsetReuseUnavailable


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
        on_heartbeat=None,
    ):
        self.store = store
        self.pipeline = pipeline
        self.worker_id = worker_id or f"worker-{uuid.uuid4().hex[:8]}"
        self.interrupted_job_stale_seconds = interrupted_job_stale_seconds
        self.heartbeat_interval_seconds = heartbeat_interval_seconds
        self.on_heartbeat = on_heartbeat

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
                on_heartbeat=self.on_heartbeat,
            ):
                build_kwargs = {
                    "on_status": update,
                    "on_progress": update_progress,
                }
                if isinstance(self.pipeline, MapBuildPipeline):
                    build_kwargs["artifact_publication_lease"] = lambda object_key: (
                        self.store.artifact_publication_lease(
                            job.job_id,
                            object_key,
                            worker_id=self.worker_id,
                        )
                    )
                reuse_keys = (
                    self.pipeline.reuse_keys(job)
                    if isinstance(self.pipeline, MapBuildPipeline)
                    else None
                )
                reuse_strategy = None
                reuse_source_job_id = None
                if reuse_keys is not None:
                    self.store.set_build_keys_unless_cancelled(
                        job.job_id,
                        worker_id=self.worker_id,
                        build_cache_key=reuse_keys.exact,
                        build_compatibility_key=reuse_keys.compatibility,
                    )
                    exact = self.store.find_exact_reuse_candidate(
                        job_id=job.job_id,
                        build_cache_key=reuse_keys.exact,
                    )
                    if exact is not None:
                        finished = self.store.complete_exact_reuse(
                            job.job_id,
                            worker_id=self.worker_id,
                            source_job_id=exact.job_id,
                            build_cache_key=reuse_keys.exact,
                            build_compatibility_key=reuse_keys.compatibility,
                        )
                        if finished is not None:
                            return WorkerResult(
                                worker_id=self.worker_id,
                                job=finished,
                                processed=True,
                            )
                    build_result = None
                    for parent in self.store.find_subset_reuse_candidates(
                        job,
                        build_compatibility_key=reuse_keys.compatibility,
                    ):
                        try:
                            build_result = self.pipeline.build_subset(
                                job,
                                parent,
                                **build_kwargs,
                            )
                        except SubsetReuseUnavailable:
                            continue
                        reuse_strategy = "subset"
                        reuse_source_job_id = parent.job_id
                        break
                    if build_result is None:
                        build_result = self.pipeline.build(job, **build_kwargs)
                else:
                    build_result = self.pipeline.build(job, **build_kwargs)
                map_id, archive_path = build_result
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
                artifacts=getattr(build_result, "artifacts", None),
                artifact_metrics=getattr(build_result, "artifact_metrics", None),
                build_cache_key=(reuse_keys.exact if reuse_keys else None),
                build_compatibility_key=(reuse_keys.compatibility if reuse_keys else None),
                reuse_strategy=reuse_strategy,
                reuse_source_job_id=reuse_source_job_id,
            )
            return WorkerResult(worker_id=self.worker_id, job=finished, processed=True)
        except Exception as exc:
            current = self.store.get(job.job_id)
            if current.status == JobStatus.CANCELLED or current.worker_id != self.worker_id:
                if (
                    current.status == JobStatus.CANCELLED
                    and isinstance(self.pipeline, MapBuildPipeline)
                    and self.pipeline.artifact_store is not None
                ):
                    self.store.queue_terminal_pending_artifacts(job.job_id)
                return WorkerResult(worker_id=self.worker_id, job=current, processed=True)
            failed = self.store.update_status_unless_cancelled(
                job.job_id,
                JobStatus.FAILED,
                error=str(exc),
                error_code=getattr(exc, "code", "map_build_failed"),
                worker_id=self.worker_id,
                event=str(exc),
                finished=True,
            )
            if failed.attempts < failed.max_attempts:
                failed = self.store.update_status_unless_cancelled(
                    job.job_id,
                    JobStatus.QUEUED,
                    error=str(exc),
                    error_code=getattr(exc, "code", "map_build_failed"),
                    worker_id=self.worker_id,
                    event="queued for retry",
                )
            elif isinstance(self.pipeline, MapBuildPipeline) and self.pipeline.artifact_store is not None:
                self.store.queue_terminal_pending_artifacts(job.job_id)
                failed = self.store.get(job.job_id)
            return WorkerResult(worker_id=self.worker_id, job=failed, processed=True)

    def run_until_empty(self, *, max_jobs: int | None = None) -> list[WorkerResult]:
        results: list[WorkerResult] = []
        while max_jobs is None or len(results) < max_jobs:
            result = self.run_next()
            if not result.processed:
                break
            results.append(result)
        return results


def expire_ready_jobs(
    store: JobStore,
    *,
    older_than_days: int,
    artifact_store=None,
    max_gc_items: int | None = None,
) -> int:
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
    cleanup_expired_pack_artifacts(
        store,
        artifact_store=artifact_store,
        max_gc_items=max_gc_items,
    )
    return count


def cleanup_expired_pack_artifacts(
    store: JobStore,
    *,
    artifact_store=None,
    max_gc_items: int | None = None,
) -> int:
    removed = 0
    with store.lock_artifact_references() as jobs:
        protected_paths = {
            Path(job.pack_path)
            for job in jobs
            if job.pack_path and job.status != JobStatus.EXPIRED
        }
        candidates = {
            Path(job.pack_path)
            for job in jobs
            if job.pack_path and job.status == JobStatus.EXPIRED
        } - protected_paths
    for pack_path in candidates:
        if store.delete_expired_legacy_pack(pack_path):
            removed += 1
    if artifact_store is not None:
        removed += store.cleanup_artifact_garbage(
            artifact_store,
            max_items=max_gc_items,
        )
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
