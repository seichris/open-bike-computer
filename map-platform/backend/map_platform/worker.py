from __future__ import annotations

import shutil
import time
import uuid
from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .jobs import (
    ArtifactGarbageCollectionError,
    JobRecordEnumerationError,
    JobStore,
)
from .models import JobStatus, MapJob
from .monitoring import MapMonitoringStore, build_map_job_monitoring_event
from .pipeline import MapBuildPipeline, safe_build_failure
from .reuse import SubsetReuseUnavailable


@dataclass(frozen=True)
class WorkerResult:
    worker_id: str
    job: MapJob | None
    processed: bool
    monitoring_event: dict[str, object] | None = None


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
        monitoring_store: MapMonitoringStore | None = None,
        estimate_coordinator=None,
    ):
        self.store = store
        self.pipeline = pipeline
        self.worker_id = worker_id or f"worker-{uuid.uuid4().hex[:8]}"
        self.interrupted_job_stale_seconds = interrupted_job_stale_seconds
        self.heartbeat_interval_seconds = heartbeat_interval_seconds
        self.on_heartbeat = on_heartbeat
        self.monitoring_store = monitoring_store
        self.estimate_coordinator = estimate_coordinator

    def run_next(self) -> WorkerResult:
        self.store.requeue_retryable_failures()
        job = self.store.claim_next(
            self.worker_id,
            interrupted_job_stale_seconds=self.interrupted_job_stale_seconds,
        )
        if job is None:
            return WorkerResult(worker_id=self.worker_id, job=None, processed=False)
        attempt_started_at = job.updated_at
        attempt_started_monotonic = time.monotonic()
        if self.estimate_coordinator is not None:
            self.estimate_coordinator.publish(
                job.job_id,
                worker_id=self.worker_id,
                phase=JobStatus.VALIDATING.value,
                force=True,
            )

        def update(status: JobStatus) -> None:
            self.store.update_status_unless_cancelled(job.job_id, status, worker_id=self.worker_id)
            if self.estimate_coordinator is not None:
                self.estimate_coordinator.publish(
                    job.job_id,
                    worker_id=self.worker_id,
                    phase=status.value,
                    force=True,
                )

        def update_progress(completed: int, total: int) -> None:
            self.store.update_progress_unless_cancelled(
                job.job_id,
                completed,
                total,
                worker_id=self.worker_id,
            )

        def update_phase_progress(progress: dict) -> None:
            observability = getattr(job, "_building_observability", None)
            if observability is None:
                observability = {
                    "attemptStartedMonotonic": attempt_started_monotonic,
                }
                job._building_observability = observability
            if "firstProgressMilliseconds" not in observability:
                observability["firstProgressMilliseconds"] = max(
                    0,
                    int(round((time.monotonic() - attempt_started_monotonic) * 1_000)),
                )
            self.store.update_phase_progress_unless_cancelled(
                job.job_id,
                phase=progress["phase"],
                unit=progress["unit"],
                completed=progress.get("completed"),
                total=progress.get("total"),
                completed_blocks=progress.get("completedBlocks"),
                total_blocks=progress.get("totalBlocks"),
                indeterminate=progress["indeterminate"],
                worker_id=self.worker_id,
            )
            if self.estimate_coordinator is not None:
                raw_evidence = progress.get("estimatorEvidence")
                evidence = dict(raw_evidence) if isinstance(raw_evidence, dict) else {}
                evidence["progress"] = {
                    key: progress[key]
                    for key in ("phase", "unit", "completed", "total")
                }
                self.estimate_coordinator.publish(
                    job.job_id,
                    worker_id=self.worker_id,
                    phase=progress["phase"],
                    evidence=evidence,
                    force=isinstance(raw_evidence, dict),
                )

        def cancellation_requested() -> bool:
            current = self.store.get(job.job_id)
            return (
                current.status == JobStatus.CANCELLED
                or current.worker_id != self.worker_id
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
                    build_kwargs["on_phase_progress"] = update_phase_progress
                    build_kwargs["cancellation_check"] = cancellation_requested
                    build_kwargs["artifact_publication_lease"] = lambda object_key: (
                        self.store.artifact_publication_lease(
                            job.job_id,
                            object_key,
                            worker_id=self.worker_id,
                        )
                    )
                if isinstance(self.pipeline, MapBuildPipeline):
                    selected_preprocessing = (
                        self.pipeline.uses_selected_preprocessing(job)
                    )
                    if job.building_preprocessing_mode is not None:
                        self.store.freeze_building_preprocessing_mode_unless_cancelled(
                            job.job_id,
                            worker_id=self.worker_id,
                            building_preprocessing_mode=(
                                job.building_preprocessing_mode
                            ),
                        )
                    if selected_preprocessing:
                        update(JobStatus.CONVERTING_FEATURES)
                reuse_keys = (
                    self.pipeline.reuse_keys(
                        job,
                        on_phase_progress=update_phase_progress,
                        cancellation_check=cancellation_requested,
                    )
                    if isinstance(self.pipeline, MapBuildPipeline)
                    else None
                )
                if job.building_preprocessing_inputs is not None:
                    self.store.freeze_building_preprocessing_inputs_unless_cancelled(
                        job.job_id,
                        worker_id=self.worker_id,
                        building_preprocessing_inputs=(
                            job.building_preprocessing_inputs
                        ),
                        building_preprocessing_runtime=(
                            job.building_preprocessing_runtime
                        ),
                    )
                reuse_strategy = None
                reuse_source_job_id = None
                if reuse_keys is not None:
                    with self.pipeline.exact_reuse_identity_lease(
                        job,
                        on_phase_progress=update_phase_progress,
                        cancellation_check=cancellation_requested,
                    ) as confirmed:
                        if confirmed is None:
                            raise RuntimeError(
                                "map build identity became unavailable under source lease"
                            )
                        reuse_keys = confirmed
                        reserved = self.store.set_build_keys_unless_cancelled(
                            job.job_id,
                            worker_id=self.worker_id,
                            build_cache_key=reuse_keys.exact,
                            build_compatibility_key=reuse_keys.compatibility,
                            building_preprocessing_inputs=(
                                job.building_preprocessing_inputs
                            ),
                        )
                        job.build_cache_key = reserved.build_cache_key
                        job.build_compatibility_key = reserved.build_compatibility_key
                        exact = self.store.find_exact_reuse_candidate(
                            job_id=job.job_id,
                            build_cache_key=reuse_keys.exact,
                        )
                        if (
                            exact is not None
                            and self.pipeline.validate_exact_reuse_candidate(job, exact)
                        ):
                            if self.estimate_coordinator is not None:
                                self.estimate_coordinator.publish(
                                    job.job_id,
                                    worker_id=self.worker_id,
                                    phase="reuse_exact",
                                    outcome_class="exact_reuse",
                                    force=True,
                                )
                            finished = self.store.complete_exact_reuse(
                                job.job_id,
                                worker_id=self.worker_id,
                                source_job_id=exact.job_id,
                                build_cache_key=reuse_keys.exact,
                                build_compatibility_key=reuse_keys.compatibility,
                                building_observability=deepcopy(
                                    getattr(job, "_building_observability", {})
                                ),
                            )
                            if finished is not None:
                                monitoring_event = self._monitoring_event(
                                    finished,
                                    attempt_started_at,
                                    outcome="exact_reuse",
                                )
                                return WorkerResult(
                                    worker_id=self.worker_id,
                                    job=finished,
                                    processed=True,
                                    monitoring_event=monitoring_event,
                                )
                        build_result = None
                        if self.estimate_coordinator is not None:
                            self.estimate_coordinator.publish(
                                job.job_id,
                                worker_id=self.worker_id,
                                phase="reuse_resolved",
                                outcome_class="full_build",
                                force=True,
                            )
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
                            if self.estimate_coordinator is not None:
                                self.estimate_coordinator.publish(
                                    job.job_id,
                                    worker_id=self.worker_id,
                                    phase="reuse_subset",
                                    outcome_class="subset_reuse",
                                    force=True,
                                )
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
                build_cache_key=(
                    getattr(build_result, "build_cache_key", None)
                    or (reuse_keys.exact if reuse_keys else None)
                ),
                build_cache_aliases=(
                    getattr(build_result, "build_cache_aliases", None) or []
                ),
                build_identity_derivation=getattr(
                    build_result, "build_identity_derivation", None
                ),
                build_compatibility_key=(
                    getattr(build_result, "build_compatibility_key", None)
                    or (reuse_keys.compatibility if reuse_keys else None)
                ),
                reuse_strategy=reuse_strategy,
                reuse_source_job_id=reuse_source_job_id,
            )
            monitoring_event = self._monitoring_event(
                finished,
                attempt_started_at,
                outcome=(
                    "subset_reuse"
                    if reuse_strategy == "subset"
                    else "built"
                ),
            )
            return WorkerResult(
                worker_id=self.worker_id,
                job=finished,
                processed=True,
                monitoring_event=monitoring_event,
            )
        except Exception as exc:
            if isinstance(self.pipeline, MapBuildPipeline):
                try:
                    self.pipeline.cleanup_failed_attempt(job)
                except OSError:
                    pass
            current = self.store.get(job.job_id)
            if current.status == JobStatus.CANCELLED or current.worker_id != self.worker_id:
                if (
                    current.status == JobStatus.CANCELLED
                    and isinstance(self.pipeline, MapBuildPipeline)
                    and self.pipeline.artifact_store is not None
                ):
                    self.store.queue_terminal_pending_artifacts(job.job_id)
                monitoring_event = self._monitoring_event(
                    current,
                    attempt_started_at,
                    outcome=current.status.value,
                )
                return WorkerResult(
                    worker_id=self.worker_id,
                    job=current,
                    processed=True,
                    monitoring_event=monitoring_event,
                )
            error_message, error_code = safe_build_failure(job, exc)
            failed = self.store.update_status_unless_cancelled(
                job.job_id,
                JobStatus.FAILED,
                error=error_message,
                error_code=error_code,
                worker_id=self.worker_id,
                event=error_message,
                finished=True,
            )
            monitoring_event = self._monitoring_event(
                failed,
                attempt_started_at,
                outcome="failed",
                persist=failed.attempts >= failed.max_attempts,
            )
            if failed.attempts < failed.max_attempts:
                if self.estimate_coordinator is not None:
                    self.estimate_coordinator.publish_pending_retry(
                        job.job_id,
                        worker_id=self.worker_id,
                    )
                failed = self.store.update_status_unless_cancelled(
                    job.job_id,
                    JobStatus.QUEUED,
                    error=error_message,
                    error_code=error_code,
                    worker_id=self.worker_id,
                    event="queued for retry",
                )
            elif isinstance(self.pipeline, MapBuildPipeline) and self.pipeline.artifact_store is not None:
                self.store.queue_terminal_pending_artifacts(job.job_id)
                failed = self.store.get(job.job_id)
            return WorkerResult(
                worker_id=self.worker_id,
                job=failed,
                processed=True,
                monitoring_event=monitoring_event,
            )

    def _monitoring_event(
        self,
        job: MapJob,
        attempt_started_at: str,
        *,
        outcome: str,
        persist: bool = True,
    ) -> dict[str, object] | None:
        if self.monitoring_store is None:
            return None
        monitoring_persisted = False
        if persist:
            try:
                monitoring_persisted = bool(
                    self.monitoring_store.record_job(job)
                )
            except Exception:
                # Observability must never turn a completed map into a failed map.
                monitoring_persisted = False
        try:
            event = build_map_job_monitoring_event(
                job,
                self.worker_id,
                attempt_started_at=attempt_started_at,
                outcome=outcome,
            )
        except Exception:
            # A malformed optional telemetry field must not change job outcome.
            event = {
                "event": "map_job_run_completed",
                "jobId": job.job_id,
                "workerId": self.worker_id,
                "status": job.status.value,
                "outcome": outcome,
                "attempt": job.attempts,
            }
        event["monitoringPersisted"] = monitoring_persisted
        return event

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
