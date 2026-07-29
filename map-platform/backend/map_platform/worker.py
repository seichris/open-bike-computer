from __future__ import annotations

import shutil
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .jobs import (
    ArtifactGarbageCollectionError,
    JobRecordEnumerationError,
    JobStore,
)
from .models import JobStatus, MapJob
from .pipeline import MapBuildPipeline
from .reuse import SubsetReuseUnavailable


@dataclass(frozen=True)
class WorkerResult:
    worker_id: str
    job: MapJob | None
    processed: bool


class ExpiredArtifactCleanupError(RuntimeError):
    def __init__(
        self,
        *,
        removed: int,
        legacy_failures: list[tuple[Path, Exception]],
        object_failure: Exception | None,
        expired_jobs: int = 0,
        expiry_failures: list[tuple[str, Exception]] | None = None,
        job_record_failures: list[tuple[Path, Exception]] | None = None,
    ):
        self.removed = removed
        self.expired_jobs = expired_jobs
        expiry_failures = expiry_failures or []
        job_record_failures = job_record_failures or []
        self.failed_expiry_job_ids = tuple(
            job_id for job_id, _ in expiry_failures
        )
        self.expiry_causes = tuple(exc for _, exc in expiry_failures)
        self.failed_job_record_paths = tuple(
            path for path, _ in job_record_failures
        )
        self.job_record_causes = tuple(
            exc for _, exc in job_record_failures
        )
        self.failed_legacy_paths = tuple(path for path, _ in legacy_failures)
        self.legacy_causes = tuple(exc for _, exc in legacy_failures)
        self.object_failure = object_failure
        object_failure_count = 0
        if isinstance(object_failure, ArtifactGarbageCollectionError):
            object_failure_count = len(object_failure.failed_object_keys)
        elif object_failure is not None:
            object_failure_count = 1
        failure_count = (
            len(expiry_failures)
            + len(job_record_failures)
            + len(legacy_failures)
            + object_failure_count
        )
        super().__init__(
            f"expiry maintenance failed for {failure_count} item(s) after "
            f"expiring {expired_jobs} job(s) and deleting {removed} artifact(s)"
        )


class WorkDirectoryCleanupError(RuntimeError):
    def __init__(
        self,
        *,
        removed: int,
        failures: list[tuple[Path, Exception]],
    ):
        self.removed = removed
        self.failed_paths = tuple(path for path, _ in failures)
        self.causes = tuple(exc for _, exc in failures)
        super().__init__(
            f"work-directory cleanup failed for {len(failures)} item(s) "
            f"after deleting {removed}"
        )


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
    expiry_failures: list[tuple[str, Exception]] = []
    jobs, job_record_failures = store.list_with_failures()
    for job in jobs:
        if job.status != JobStatus.READY:
            continue
        try:
            # A label change or download receipt is allowed after READY and
            # updates `updated_at`. Retention must remain anchored to
            # completion, not to later user activity. Legacy records without
            # `finished_at` fall back to their immutable creation time so
            # activity cannot extend them.
            retention_anchor = _parse_utc(job.finished_at or job.created_at)
            if retention_anchor >= cutoff:
                continue
            store.update_status(
                job.job_id,
                JobStatus.EXPIRED,
                event="expired by retention policy",
                finished=True,
            )
            count += 1
        except Exception as exc:
            # `save()` writes the job record before refreshing its indexes. If
            # a later index write fails, reconcile the persisted status so the
            # completed expiry is not undercounted.
            try:
                persisted = store.get(job.job_id)
            except Exception:
                persisted = None
            if persisted is not None and persisted.status == JobStatus.EXPIRED:
                count += 1
            expiry_failures.append((job.job_id, exc))
            continue
    cleanup_removed = 0
    cleanup_error = None
    try:
        cleanup_removed = cleanup_expired_pack_artifacts(
            store,
            artifact_store=artifact_store,
            max_gc_items=max_gc_items,
        )
    except ExpiredArtifactCleanupError as exc:
        cleanup_error = exc
    except Exception as exc:
        cleanup_error = ExpiredArtifactCleanupError(
            removed=0,
            legacy_failures=[],
            object_failure=exc,
        )
    combined_job_record_failures = list(job_record_failures)
    known_record_paths = {path for path, _ in combined_job_record_failures}
    if cleanup_error is not None:
        for path, cause in zip(
            cleanup_error.failed_job_record_paths,
            cleanup_error.job_record_causes,
        ):
            if path not in known_record_paths:
                combined_job_record_failures.append((path, cause))
                known_record_paths.add(path)
    if (
        cleanup_error is not None
        and not expiry_failures
        and not combined_job_record_failures
    ):
        cleanup_error.expired_jobs = count
        raise cleanup_error
    if expiry_failures or combined_job_record_failures or cleanup_error is not None:
        raise ExpiredArtifactCleanupError(
            removed=(
                cleanup_error.removed
                if cleanup_error
                else cleanup_removed
            ),
            legacy_failures=(
                list(
                    zip(
                        cleanup_error.failed_legacy_paths,
                        cleanup_error.legacy_causes,
                    )
                )
                if cleanup_error
                else []
            ),
            object_failure=(cleanup_error.object_failure if cleanup_error else None),
            expired_jobs=count,
            expiry_failures=expiry_failures,
            job_record_failures=combined_job_record_failures,
        ) from cleanup_error
    return count


def cleanup_expired_pack_artifacts(
    store: JobStore,
    *,
    artifact_store=None,
    max_gc_items: int | None = None,
) -> int:
    removed = 0
    legacy_failures: list[tuple[Path, Exception]] = []
    try:
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
    except JobRecordEnumerationError as exc:
        raise ExpiredArtifactCleanupError(
            removed=0,
            legacy_failures=[],
            object_failure=None,
            job_record_failures=list(zip(exc.failed_paths, exc.causes)),
        ) from exc
    for pack_path in sorted(candidates):
        try:
            if store.delete_expired_legacy_pack(pack_path):
                removed += 1
        except Exception as exc:
            legacy_failures.append((pack_path, exc))
    object_failure = None
    if artifact_store is not None:
        try:
            removed += store.cleanup_artifact_garbage(
                artifact_store,
                max_items=max_gc_items,
            )
        except ArtifactGarbageCollectionError as exc:
            removed += exc.removed
            object_failure = exc
        except Exception as exc:
            object_failure = exc
    if legacy_failures or object_failure is not None:
        raise ExpiredArtifactCleanupError(
            removed=removed,
            legacy_failures=legacy_failures,
            object_failure=object_failure,
        )
    return removed


def cleanup_work_dirs(work_root: Path, store: JobStore) -> int:
    removed = 0
    failures: list[tuple[Path, Exception]] = []
    if not work_root.exists():
        return 0
    cleanup_root = work_root / ".cleanup"
    cleanup_root.mkdir(exist_ok=True)

    # Retry tombstones left by an interrupted or failed earlier pass. They are
    # detached from active job paths, so no global job lock is required.
    for tombstone in sorted(cleanup_root.iterdir()):
        try:
            if not tombstone.is_dir():
                continue
            shutil.rmtree(tombstone)
            removed += 1
        except Exception as exc:
            failures.append((tombstone, exc))

    children = [
        child
        for child in sorted(work_root.iterdir())
        if child != cleanup_root
    ]
    detached: list[Path] = []
    # One short, fenced scan keeps maintenance linear in job history. All
    # recursive deletion remains outside the global queue lock.
    with store.lock_job_records():
        jobs, job_record_failures = store.list_with_failures()
        active = {
            job.job_id
            for job in jobs
            if job.status
            not in {
                JobStatus.READY,
                JobStatus.FAILED,
                JobStatus.EXPIRED,
                JobStatus.CANCELLED,
            }
        }
        # A corrupt record may still own a work directory. Preserve the path
        # named by that record until the record is repaired.
        active.update(path.stem for path, _ in job_record_failures)
        for child in children:
            try:
                if not child.is_dir() or child.name in active:
                    continue
                tombstone = cleanup_root / (
                    f"{child.name}-{uuid.uuid4().hex}"
                )
                child.rename(tombstone)
                detached.append(tombstone)
            except Exception as exc:
                failures.append((child, exc))

    for tombstone in detached:
        try:
            shutil.rmtree(tombstone)
            removed += 1
        except Exception as exc:
            failures.append((tombstone, exc))
    if failures:
        raise WorkDirectoryCleanupError(
            removed=removed,
            failures=failures,
        )
    return removed


def _parse_utc(value: str) -> datetime:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return datetime.fromisoformat(value)
