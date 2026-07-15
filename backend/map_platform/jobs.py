from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import threading
import uuid
from contextlib import contextmanager
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .artifacts import ArtifactRecord
from .geometry import GeometryError, normalize_geometry
from .limits import JobLimits, LimitError
from .models import JobStatus, MapDownloadReceipt, MapJob, utc_now_iso
from .reuse import parent_contains_child_blocks
from .sources import SourceIndex, SourceResolutionError


class JobStore:
    _local_queue_locks_guard = threading.Lock()
    _local_queue_locks: dict[str, threading.Lock] = {}
    _local_artifact_locks_guard = threading.Lock()
    _local_artifact_locks: dict[str, threading.Lock] = {}

    def __init__(self, root: str | Path, *, lock_stale_seconds: float = 300.0):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.lock_path = self.root / ".queue.lock"
        self.artifact_lock_root = self.root / ".artifact-locks"
        self.artifact_lock_root.mkdir(exist_ok=True)
        self.artifact_gc_cursor_path = self.root / ".artifact-gc-cursor"
        self.lock_stale_seconds = lock_stale_seconds

    def save(self, job: MapJob) -> None:
        path = self._path(job.job_id)
        tmp_path = path.with_suffix(".json.tmp")
        tmp_path.write_text(
            json.dumps(job.to_dict(include_internal=True), indent=2, sort_keys=True) + "\n"
        )
        tmp_path.replace(path)

    def get(self, job_id: str) -> MapJob:
        path = self._path(job_id)
        if not path.exists():
            raise KeyError(job_id)
        return MapJob.from_dict(json.loads(path.read_text()))

    def list(self) -> list[MapJob]:
        return [MapJob.from_dict(json.loads(path.read_text())) for path in sorted(self.root.glob("*.json"))]

    @contextmanager
    def lock_artifact_references(self):
        """Hold the queue lock while artifact references are inspected and pruned."""
        with self._queue_lock():
            yield self.list()

    def save_if_client_request_absent(self, job: MapJob) -> MapJob:
        if not job.client_installation_id or not job.client_request_id:
            raise ValueError("job is missing client idempotency metadata")
        with self._queue_lock():
            for existing in self.list():
                if (
                    existing.client_installation_id == job.client_installation_id
                    and existing.client_request_id == job.client_request_id
                ):
                    if existing.request != job.request:
                        raise ValueError("clientRequestId was already used for a different map request")
                    return existing
            self.save(job)
            return job

    def update_status(
        self,
        job_id: str,
        status: JobStatus,
        *,
        error: str | None = None,
        error_code: str | None = None,
        map_id: str | None = None,
        pack_path: str | None = None,
        pack_bytes: int | None = None,
        artifacts: list[ArtifactRecord] | None = None,
        artifact_metrics: dict[str, Any] | None = None,
        build_cache_key: str | None = None,
        build_compatibility_key: str | None = None,
        reuse_strategy: str | None = None,
        reuse_source_job_id: str | None = None,
        worker_id: str | None = None,
        event: str | None = None,
        finished: bool = False,
    ) -> MapJob:
        with self._queue_lock():
            return self._update_status_unlocked(
                job_id,
                status,
                error=error,
                error_code=error_code,
                map_id=map_id,
                pack_path=pack_path,
                pack_bytes=pack_bytes,
                artifacts=artifacts,
                artifact_metrics=artifact_metrics,
                build_cache_key=build_cache_key,
                build_compatibility_key=build_compatibility_key,
                reuse_strategy=reuse_strategy,
                reuse_source_job_id=reuse_source_job_id,
                worker_id=worker_id,
                event=event,
                finished=finished,
            )

    def update_status_unless_cancelled(
        self,
        job_id: str,
        status: JobStatus,
        *,
        error: str | None = None,
        error_code: str | None = None,
        map_id: str | None = None,
        pack_path: str | None = None,
        pack_bytes: int | None = None,
        artifacts: list[ArtifactRecord] | None = None,
        artifact_metrics: dict[str, Any] | None = None,
        build_cache_key: str | None = None,
        build_compatibility_key: str | None = None,
        reuse_strategy: str | None = None,
        reuse_source_job_id: str | None = None,
        worker_id: str | None = None,
        event: str | None = None,
        finished: bool = False,
    ) -> MapJob:
        with self._queue_lock():
            current = self.get(job_id)
            if current.status == JobStatus.CANCELLED:
                raise RuntimeError("job was cancelled")
            if worker_id is not None and current.worker_id not in {None, worker_id}:
                raise RuntimeError("job is owned by another worker")
            return self._update_status_unlocked(
                job_id,
                status,
                error=error,
                error_code=error_code,
                map_id=map_id,
                pack_path=pack_path,
                pack_bytes=pack_bytes,
                artifacts=artifacts,
                artifact_metrics=artifact_metrics,
                build_cache_key=build_cache_key,
                build_compatibility_key=build_compatibility_key,
                reuse_strategy=reuse_strategy,
                reuse_source_job_id=reuse_source_job_id,
                worker_id=worker_id,
                event=event,
                finished=finished,
            )

    def _update_status_unlocked(
        self,
        job_id: str,
        status: JobStatus,
        *,
        error: str | None = None,
        error_code: str | None = None,
        map_id: str | None = None,
        pack_path: str | None = None,
        pack_bytes: int | None = None,
        artifacts: list[ArtifactRecord] | None = None,
        artifact_metrics: dict[str, Any] | None = None,
        build_cache_key: str | None = None,
        build_compatibility_key: str | None = None,
        reuse_strategy: str | None = None,
        reuse_source_job_id: str | None = None,
        pending_artifact_keys: list[str] | None = None,
        artifact_gc_keys: list[str] | None = None,
        worker_id: str | None = None,
        event: str | None = None,
        finished: bool = False,
    ) -> MapJob:
        job = self.get(job_id)
        previous_status = job.status
        job.status = status
        job.updated_at = utc_now_iso()
        job.error = error
        job.error_code = error_code
        if previous_status != status and status in {JobStatus.QUEUED, JobStatus.VALIDATING}:
            job.progress_completed = None
            job.progress_total = None
        if status in {JobStatus.VALIDATING, JobStatus.RESOLVING_SOURCE, JobStatus.EXTRACTING_PBF} and job.started_at is None:
            job.started_at = job.updated_at
        if finished or status in {JobStatus.READY, JobStatus.FAILED, JobStatus.EXPIRED, JobStatus.CANCELLED}:
            job.finished_at = job.updated_at
        else:
            job.finished_at = None
        if map_id is not None:
            job.map_id = map_id
        if pack_path is not None:
            job.pack_path = pack_path
        if pack_bytes is not None:
            job.pack_bytes = pack_bytes
        if artifacts is not None:
            job.artifacts = list(artifacts)
        if artifact_metrics is not None:
            job.artifact_metrics = dict(artifact_metrics)
        if build_cache_key is not None:
            job.build_cache_key = build_cache_key
        if build_compatibility_key is not None:
            job.build_compatibility_key = build_compatibility_key
        if reuse_strategy is not None:
            job.reuse_strategy = reuse_strategy
        if reuse_source_job_id is not None:
            job.reuse_source_job_id = reuse_source_job_id
        if pending_artifact_keys is not None:
            job.pending_artifact_keys = list(pending_artifact_keys)
        if artifact_gc_keys is not None:
            job.artifact_gc_keys = list(artifact_gc_keys)
        if worker_id is not None:
            job.worker_id = worker_id
        should_drop_preview_geometry = status in {
            JobStatus.READY,
            JobStatus.EXPIRED,
            JobStatus.CANCELLED,
        } or (
            status == JobStatus.FAILED
            and job.attempts >= job.max_attempts
        )
        if should_drop_preview_geometry and job.source_region.preview_geometry is not None:
            job.source_region = replace(
                job.source_region,
                preview_geometry=None,
            )
        if event or previous_status != status:
            job.events.append(
                {
                    "at": job.updated_at,
                    "status": status.value,
                    "message": event or f"entered {status.value}",
                }
            )
        self.save(job)
        return job

    def update_progress_unless_cancelled(
        self,
        job_id: str,
        completed: int,
        total: int,
        *,
        worker_id: str | None = None,
    ) -> MapJob:
        if total <= 0:
            raise ValueError("progress total must be positive")
        with self._queue_lock():
            job = self.get(job_id)
            if job.status == JobStatus.CANCELLED:
                raise RuntimeError("job was cancelled")
            if worker_id is not None and job.worker_id not in {None, worker_id}:
                raise RuntimeError("job is owned by another worker")
            job.progress_completed = max(0, min(int(completed), int(total)))
            job.progress_total = int(total)
            job.updated_at = utc_now_iso()
            if worker_id is not None:
                job.worker_id = worker_id
            self.save(job)
            return job

    def add_pending_artifact_unless_cancelled(
        self,
        job_id: str,
        object_key: str,
        *,
        worker_id: str,
    ) -> MapJob:
        with self._artifact_key_lock(object_key):
            with self._queue_lock():
                job = self.get(job_id)
                if job.status == JobStatus.CANCELLED:
                    raise RuntimeError("job was cancelled")
                if job.worker_id != worker_id:
                    raise RuntimeError("job is owned by another worker")
                if object_key not in job.pending_artifact_keys:
                    job.pending_artifact_keys.append(object_key)
                    job.artifact_gc_keys = [
                        key for key in job.artifact_gc_keys if key != object_key
                    ]
                    job.updated_at = utc_now_iso()
                    self.save(job)
                return job

    @contextmanager
    def artifact_publication_lease(
        self,
        job_id: str,
        object_key: str,
        *,
        worker_id: str,
    ):
        """Fence publication against GC from registration through object PUT."""
        with self._artifact_key_lock(object_key):
            with self._queue_lock():
                job = self.get(job_id)
                if job.status == JobStatus.CANCELLED:
                    raise RuntimeError("job was cancelled")
                if job.worker_id != worker_id:
                    raise RuntimeError("job is owned by another worker")
                if object_key not in job.pending_artifact_keys:
                    job.pending_artifact_keys.append(object_key)
                job.artifact_gc_keys = [
                    key for key in job.artifact_gc_keys if key != object_key
                ]
                job.updated_at = utc_now_iso()
                self.save(job)
            yield

    def queue_terminal_pending_artifacts(self, job_id: str) -> int:
        terminal_statuses = {JobStatus.FAILED, JobStatus.CANCELLED, JobStatus.EXPIRED}
        with self._queue_lock():
            target = self.get(job_id)
            if target.status not in terminal_statuses:
                raise RuntimeError("pending artifacts may only be cleaned for a terminal job")
            candidates = set(target.pending_artifact_keys) | set(target.artifact_gc_keys)
            target.artifact_gc_keys = sorted(
                set(target.artifact_gc_keys) | candidates
            )
            target.pending_artifact_keys = []
            self.save(target)
        return len(candidates)

    def cleanup_artifact_garbage(
        self,
        artifact_store,
        *,
        object_keys=None,
        max_items: int | None = None,
    ) -> int:
        """Retry durable object GC without holding the global job queue lock."""
        if max_items is not None and max_items <= 0:
            raise ValueError("artifact GC item limit must be positive")
        terminal_statuses = {JobStatus.FAILED, JobStatus.CANCELLED, JobStatus.EXPIRED}
        with self._queue_lock():
            jobs = self.list()
            staging_budget = max_items
            for job in jobs:
                if staging_budget == 0:
                    break
                changed = False
                if job.status in terminal_statuses and job.pending_artifact_keys:
                    pending_to_stage = job.pending_artifact_keys[
                        :staging_budget
                    ] if staging_budget is not None else job.pending_artifact_keys
                    job.artifact_gc_keys = sorted(
                        set(job.artifact_gc_keys) | set(pending_to_stage)
                    )
                    job.pending_artifact_keys = job.pending_artifact_keys[
                        len(pending_to_stage):
                    ]
                    if staging_budget is not None:
                        staging_budget -= len(pending_to_stage)
                    changed = True
                if (
                    job.status == JobStatus.EXPIRED
                    and job.artifacts
                    and staging_budget != 0
                ):
                    artifacts_to_stage = job.artifacts[
                        :staging_budget
                    ] if staging_budget is not None else job.artifacts
                    expired_keys = {
                        artifact.object_key for artifact in artifacts_to_stage
                    }
                    job.artifact_gc_keys = sorted(
                        set(job.artifact_gc_keys) | expired_keys
                    )
                    job.artifacts = job.artifacts[len(artifacts_to_stage):]
                    if staging_budget is not None:
                        staging_budget -= len(artifacts_to_stage)
                    changed = True
                if changed:
                    self.save(job)
            durable_candidates = {
                key for job in jobs for key in job.artifact_gc_keys
            }
            candidates = (
                durable_candidates
                if object_keys is None
                else durable_candidates & set(object_keys)
            )
            ordered_candidates = sorted(candidates)
            if max_items is not None and ordered_candidates:
                try:
                    cursor = self.artifact_gc_cursor_path.read_text().strip()
                except OSError:
                    cursor = ""
                after_cursor = [key for key in ordered_candidates if key > cursor]
                through_cursor = [key for key in ordered_candidates if key <= cursor]
                ordered_candidates = (after_cursor + through_cursor)[:max_items]
                self.artifact_gc_cursor_path.write_text(ordered_candidates[-1])

        removed = 0
        for object_key in ordered_candidates:
            with self._artifact_key_lock(object_key):
                with self._queue_lock():
                    jobs = self.list()
                    protected = any(
                        object_key in job.pending_artifact_keys
                        or (
                            job.status != JobStatus.EXPIRED
                            and any(
                                artifact.object_key == object_key
                                for artifact in job.artifacts
                            )
                        )
                        for job in jobs
                    )
                    if protected:
                        self._remove_gc_key_unlocked(jobs, object_key)
                        continue
                try:
                    deleted = artifact_store.delete(object_key)
                except Exception:
                    continue
                with self._queue_lock():
                    self._remove_gc_key_unlocked(self.list(), object_key)
                if deleted:
                    removed += 1
        return removed

    def _remove_gc_key_unlocked(self, jobs: list[MapJob], object_key: str) -> None:
        for job in jobs:
            if object_key not in job.artifact_gc_keys:
                continue
            job.artifact_gc_keys = [
                key for key in job.artifact_gc_keys if key != object_key
            ]
            self.save(job)

    def set_build_keys_unless_cancelled(
        self,
        job_id: str,
        *,
        worker_id: str,
        build_cache_key: str,
        build_compatibility_key: str,
    ) -> MapJob:
        with self._queue_lock():
            job = self.get(job_id)
            if job.status == JobStatus.CANCELLED:
                raise RuntimeError("job was cancelled")
            if job.worker_id != worker_id:
                raise RuntimeError("job is owned by another worker")
            job.build_cache_key = build_cache_key
            job.build_compatibility_key = build_compatibility_key
            job.updated_at = utc_now_iso()
            self.save(job)
            return job

    def find_exact_reuse_candidate(
        self,
        *,
        job_id: str,
        build_cache_key: str,
    ) -> MapJob | None:
        with self._queue_lock():
            candidates = [
                job
                for job in self.list()
                if job.job_id != job_id
                and job.status == JobStatus.READY
                and job.build_cache_key == build_cache_key
                and job.map_id
                and job.pack_path
                and Path(job.pack_path).is_file()
            ]
            return max(candidates, key=lambda value: value.created_at) if candidates else None

    def find_subset_reuse_candidates(
        self,
        child: MapJob,
        *,
        build_compatibility_key: str,
    ) -> list[MapJob]:
        with self._queue_lock():
            candidates = [
                job
                for job in self.list()
                if job.job_id != child.job_id
                and job.status == JobStatus.READY
                and job.build_compatibility_key == build_compatibility_key
                and job.map_id
                and job.pack_path
                and Path(job.pack_path).is_file()
                and parent_contains_child_blocks(job, child)
            ]
        return sorted(
            candidates,
            key=lambda value: (value.geometry.area_km2, value.created_at),
        )

    def complete_exact_reuse(
        self,
        job_id: str,
        *,
        worker_id: str,
        source_job_id: str,
        build_cache_key: str,
        build_compatibility_key: str,
    ) -> MapJob | None:
        """Atomically reference a compatible ready job, or return None if it vanished."""
        with self._queue_lock():
            job = self.get(job_id)
            source = self.get(source_job_id)
            if job.status == JobStatus.CANCELLED:
                raise RuntimeError("job was cancelled")
            if job.worker_id != worker_id:
                raise RuntimeError("job is owned by another worker")
            if (
                source.status != JobStatus.READY
                or source.build_cache_key != build_cache_key
                or source.build_compatibility_key != build_compatibility_key
                or not source.map_id
                or not source.pack_path
                or not Path(source.pack_path).is_file()
            ):
                return None
            return self._update_status_unlocked(
                job_id,
                JobStatus.READY,
                map_id=source.map_id,
                pack_path=source.pack_path,
                pack_bytes=source.pack_bytes,
                artifacts=source.artifacts,
                artifact_metrics={"reuseStrategy": "exact"},
                build_cache_key=build_cache_key,
                build_compatibility_key=build_compatibility_key,
                reuse_strategy="exact",
                reuse_source_job_id=source.job_id,
                pending_artifact_keys=[],
                worker_id=worker_id,
                event="reused an identical ready map pack",
                finished=True,
            )

    def complete_job(
        self,
        job_id: str,
        *,
        worker_id: str,
        map_id: str,
        built_archive: Path,
        published_archive: Path,
        artifacts: list[ArtifactRecord] | None = None,
        artifact_metrics: dict[str, Any] | None = None,
        build_cache_key: str | None = None,
        build_compatibility_key: str | None = None,
        reuse_strategy: str | None = None,
        reuse_source_job_id: str | None = None,
    ) -> MapJob:
        with self._legacy_pack_lock(published_archive):
            with self._queue_lock():
                job = self.get(job_id)
                if job.status == JobStatus.CANCELLED:
                    raise RuntimeError("job was cancelled")
                if job.worker_id != worker_id:
                    raise RuntimeError("job is owned by another worker")
                published_archive.parent.mkdir(parents=True, exist_ok=True)
                if built_archive != published_archive:
                    built_archive.replace(published_archive)
                final_artifact_keys = {
                    artifact.object_key for artifact in (artifacts or [])
                }
                obsolete_pending = set(job.pending_artifact_keys) - final_artifact_keys
                artifact_gc_keys = sorted(
                    (set(job.artifact_gc_keys) | obsolete_pending) - final_artifact_keys
                )
                return self._update_status_unlocked(
                    job_id,
                    JobStatus.READY,
                    map_id=map_id,
                    pack_path=str(published_archive),
                    pack_bytes=published_archive.stat().st_size,
                    artifacts=artifacts,
                    artifact_metrics=artifact_metrics,
                    build_cache_key=build_cache_key,
                    build_compatibility_key=build_compatibility_key,
                    reuse_strategy=reuse_strategy,
                    reuse_source_job_id=reuse_source_job_id,
                    pending_artifact_keys=[],
                    artifact_gc_keys=artifact_gc_keys,
                    worker_id=worker_id,
                    event=(
                        "map pack ready from compatible parent blocks"
                        if reuse_strategy == "subset"
                        else "map pack ready"
                    ),
                    finished=True,
                )

    def delete_expired_legacy_pack(self, pack_path: Path) -> bool:
        with self._legacy_pack_lock(pack_path):
            with self._queue_lock():
                if any(
                    job.pack_path == str(pack_path)
                    and job.status != JobStatus.EXPIRED
                    for job in self.list()
                ):
                    return False
            try:
                if not pack_path.exists():
                    return False
                pack_path.unlink()
                try:
                    pack_path.parent.rmdir()
                except OSError:
                    pass
                return True
            except OSError:
                return False

    def cancel_if_active(self, job_id: str) -> MapJob:
        terminal_statuses = {
            JobStatus.READY,
            JobStatus.FAILED,
            JobStatus.EXPIRED,
            JobStatus.CANCELLED,
        }
        with self._queue_lock():
            job = self.get(job_id)
            if job.status in terminal_statuses:
                return job
            return self._update_status_unlocked(
                job_id,
                JobStatus.CANCELLED,
                event="cancelled by request",
                finished=True,
            )

    def update_user_label(self, job_id: str, user_label: str) -> MapJob:
        with self._queue_lock():
            job = self.get(job_id)
            job.user_label = user_label
            job.updated_at = utc_now_iso()
            self.save(job)
            return job

    def record_download(
        self,
        job_id: str,
        receipt: MapDownloadReceipt,
    ) -> MapJob:
        with self._queue_lock():
            job = self.get(job_id)
            if any(
                existing.receipt_id == receipt.receipt_id
                for existing in job.download_receipts
            ):
                return job
            job.download_receipts.append(receipt)
            job.download_receipts.sort(key=lambda value: value.downloaded_at)
            job.updated_at = utc_now_iso()
            self.save(job)
            return job

    def heartbeat_unless_cancelled(self, job_id: str, *, worker_id: str) -> MapJob:
        with self._queue_lock():
            job = self.get(job_id)
            if job.status == JobStatus.CANCELLED:
                raise RuntimeError("job was cancelled")
            if job.worker_id != worker_id:
                raise RuntimeError("job is owned by another worker")
            job.updated_at = utc_now_iso()
            self.save(job)
            return job

    @contextmanager
    def keep_worker_lease_alive(
        self,
        job_id: str,
        *,
        worker_id: str,
        interval_seconds: float = 30.0,
        on_heartbeat=None,
    ):
        if interval_seconds <= 0:
            raise ValueError("heartbeat interval must be positive")
        stop = threading.Event()

        def heartbeat_loop() -> None:
            while not stop.wait(interval_seconds):
                try:
                    self.heartbeat_unless_cancelled(job_id, worker_id=worker_id)
                    if on_heartbeat is not None:
                        on_heartbeat()
                except (KeyError, RuntimeError):
                    return

        thread = threading.Thread(target=heartbeat_loop, name=f"map-job-heartbeat-{job_id}", daemon=True)
        thread.start()
        try:
            yield
        finally:
            stop.set()
            thread.join(timeout=max(interval_seconds, 1.0))

    def claim(self, job_id: str, worker_id: str) -> MapJob:
        with self._queue_lock():
            job = self.get(job_id)
            if job.status != JobStatus.QUEUED:
                raise JobClaimError(f"job is {job.status.value}, not queued")
            return self._claim_unlocked(job, worker_id)

    def claim_next(self, worker_id: str, *, interrupted_job_stale_seconds: float | None = None) -> MapJob | None:
        with self._queue_lock():
            for job in self.list():
                if job.status != JobStatus.QUEUED:
                    continue
                claimed = self._claim_unlocked(job, worker_id)
                if claimed.status == JobStatus.VALIDATING:
                    return claimed
            if interrupted_job_stale_seconds is None:
                return None
            for job in self.list():
                if not self._is_interrupted(job, worker_id, interrupted_job_stale_seconds):
                    continue
                job.status = JobStatus.QUEUED
                job.updated_at = utc_now_iso()
                job.finished_at = None
                job.progress_completed = None
                job.progress_total = None
                job.events.append(
                    {
                        "at": job.updated_at,
                        "status": JobStatus.QUEUED.value,
                        "message": "requeued after worker restart",
                    }
                )
                claimed = self._claim_unlocked(job, worker_id)
                if claimed.status == JobStatus.VALIDATING:
                    return claimed
            return None

    def _claim_unlocked(self, job: MapJob, worker_id: str) -> MapJob:
        if job.attempts >= job.max_attempts:
            return self._update_status_unlocked(
                job.job_id,
                JobStatus.FAILED,
                error="maximum retry attempts exceeded",
                finished=True,
            )
        job.status = JobStatus.VALIDATING
        job.updated_at = utc_now_iso()
        job.started_at = job.started_at or job.updated_at
        job.worker_id = worker_id
        job.attempts += 1
        job.error = None
        job.error_code = None
        job.progress_completed = None
        job.progress_total = None
        job.events.append(
            {
                "at": job.updated_at,
                "status": job.status.value,
                "message": f"claimed by worker {worker_id}",
            }
        )
        self.save(job)
        return job

    def requeue_retryable_failures(self) -> int:
        count = 0
        with self._queue_lock():
            for job in self.list():
                if job.status == JobStatus.FAILED and job.attempts < job.max_attempts:
                    job.status = JobStatus.QUEUED
                    job.updated_at = utc_now_iso()
                    job.finished_at = None
                    job.progress_completed = None
                    job.progress_total = None
                    job.events.append({"at": job.updated_at, "status": job.status.value, "message": "requeued for retry"})
                    self.save(job)
                    count += 1
        return count

    def _is_interrupted(self, job: MapJob, worker_id: str, stale_after_seconds: float) -> bool:
        active_statuses = {
            JobStatus.VALIDATING,
            JobStatus.RESOLVING_SOURCE,
            JobStatus.EXTRACTING_PBF,
            JobStatus.CONVERTING_FEATURES,
            JobStatus.PACKAGING,
        }
        return (
            job.status in active_statuses
            and bool(job.worker_id)
            and job.worker_id != worker_id
            and _age_seconds(job.updated_at) >= stale_after_seconds
        )

    def _path(self, job_id: str) -> Path:
        if not re.match(r"^[a-zA-Z0-9_-]+$", job_id):
            raise ValueError("invalid job id")
        return self.root / f"{job_id}.json"

    @contextmanager
    def _queue_lock(self):
        local_key = str(self.lock_path.resolve())
        with self._local_queue_locks_guard:
            local_lock = self._local_queue_locks.setdefault(
                local_key,
                threading.Lock(),
            )
        with local_lock:
            descriptor = os.open(self.lock_path, os.O_CREAT | os.O_RDWR, 0o600)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX)
                yield
            finally:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
                os.close(descriptor)

    @contextmanager
    def _artifact_key_lock(self, object_key: str):
        digest = hashlib.sha256(object_key.encode("utf-8")).hexdigest()
        lock_path = self.artifact_lock_root / f"{digest[:2]}.lock"
        local_key = str(lock_path.resolve())
        with self._local_artifact_locks_guard:
            local_lock = self._local_artifact_locks.setdefault(
                local_key,
                threading.Lock(),
            )
        with local_lock:
            descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX)
                yield
            finally:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
                os.close(descriptor)

    def _legacy_pack_lock(self, pack_path: Path):
        return self._artifact_key_lock(
            f"legacy-pack:{pack_path.resolve(strict=False)}"
        )


class MapJobService:
    def __init__(self, source_index: SourceIndex, store: JobStore, limits: JobLimits | None = None):
        self.source_index = source_index
        self.store = store
        self.limits = limits or JobLimits()

    def create_job(self, request: dict[str, Any]) -> MapJob:
        client_installation_id = _client_identifier(request, "clientInstallationId")
        client_request_id = _client_identifier(request, "clientRequestId")
        if bool(client_installation_id) != bool(client_request_id):
            raise ValueError("clientInstallationId and clientRequestId must be provided together")
        install_on_device = request.get("installOnDevice", False)
        if not isinstance(install_on_device, bool):
            raise ValueError("installOnDevice must be a boolean")
        if client_installation_id and client_request_id:
            existing = self.find_by_client_request(client_installation_id, client_request_id)
            if existing is not None:
                if existing.request != request:
                    raise ValueError("clientRequestId was already used for a different map request")
                return existing
        try:
            geometry = normalize_geometry(request)
            self.limits.validate_geometry(geometry)
            self.limits.validate_active_jobs(self.store.list())
            source = self.source_index.resolve_for_bounds(geometry.bounds)
        except (GeometryError, LimitError, SourceResolutionError) as exc:
            raise ValueError(str(exc)) from exc
        job = MapJob(
            job_id=self._new_job_id(),
            status=JobStatus.QUEUED,
            request=dict(request),
            geometry=geometry,
            source_region=source,
            client_installation_id=client_installation_id,
            client_request_id=client_request_id,
            install_on_device=install_on_device,
        )
        if client_installation_id and client_request_id:
            return self.store.save_if_client_request_absent(job)
        self.store.save(job)
        return job

    def get_job(self, job_id: str) -> MapJob:
        return self.store.get(job_id)

    def get_job_for_installation(
        self,
        job_id: str,
        client_installation_id: str | None,
    ) -> MapJob:
        job = self.get_job(job_id)
        if job.client_installation_id is None:
            return job
        if client_installation_id is None:
            raise KeyError(job_id)
        normalized = _validate_identifier(client_installation_id, "clientInstallationId")
        if job.client_installation_id != normalized:
            raise KeyError(job_id)
        return job

    def list_jobs(self, *, client_installation_id: str | None = None) -> list[MapJob]:
        jobs = self.store.list()
        if client_installation_id is None:
            return jobs
        normalized = _validate_identifier(client_installation_id, "clientInstallationId")
        return [job for job in jobs if job.client_installation_id == normalized]

    def find_by_client_request(self, client_installation_id: str, client_request_id: str) -> MapJob | None:
        for job in self.store.list():
            if (
                job.client_installation_id == client_installation_id
                and job.client_request_id == client_request_id
            ):
                return job
        return None

    def find_by_map_id(
        self,
        map_id: str,
        *,
        client_installation_id: str | None = None,
        allow_owned_without_installation: bool = False,
    ) -> MapJob | None:
        normalized = (
            _validate_identifier(client_installation_id, "clientInstallationId")
            if client_installation_id is not None
            else None
        )
        candidates = [
            job
            for job in self.store.list()
            if job.map_id == map_id and job.status == JobStatus.READY
        ]
        if normalized is not None:
            owned = [job for job in candidates if job.client_installation_id == normalized]
            candidates = owned or [job for job in candidates if job.client_installation_id is None]
        elif not allow_owned_without_installation:
            candidates = [job for job in candidates if job.client_installation_id is None]
        if not candidates:
            return None
        return max(candidates, key=lambda job: job.created_at)

    def cancel_job(self, job_id: str) -> MapJob:
        return self.store.cancel_if_active(job_id)

    def update_user_label_for_installation(
        self,
        job_id: str,
        client_installation_id: str,
        display_name: Any,
    ) -> MapJob:
        job = self.get_job_for_installation(job_id, client_installation_id)
        if job.client_installation_id is None:
            raise ValueError("legacy unowned jobs cannot store user labels")
        return self.store.update_user_label(job_id, _normalize_user_label(display_name))

    def record_download_for_installation(
        self,
        job_id: str,
        client_installation_id: str,
        payload: dict[str, Any],
    ) -> MapJob:
        job = self.get_job_for_installation(job_id, client_installation_id)
        if job.client_installation_id is None:
            raise ValueError("legacy unowned jobs cannot store download receipts")
        if job.status != JobStatus.READY:
            raise ValueError("map job is not ready")
        required_fields = {"receiptId", "artifactFormat", "bytes"}
        if not required_fields.issubset(payload) or not set(payload).issubset(
            required_fields | {"sha256"}
        ):
            raise ValueError("download receipt has invalid fields")
        receipt_id = payload.get("receiptId")
        artifact_format = payload.get("artifactFormat")
        sha256 = payload.get("sha256")
        byte_count = payload.get("bytes")
        if not isinstance(receipt_id, str) or not _DOWNLOAD_RECEIPT_ID_RE.fullmatch(receipt_id):
            raise ValueError("receiptId is invalid")
        if not isinstance(artifact_format, str) or not _ARTIFACT_FORMAT_RE.fullmatch(artifact_format):
            raise ValueError("artifactFormat is invalid")
        if sha256 is not None and (
            not isinstance(sha256, str) or not _SHA256_RE.fullmatch(sha256)
        ):
            raise ValueError("sha256 is invalid")
        if isinstance(byte_count, bool) or not isinstance(byte_count, int) or byte_count <= 0:
            raise ValueError("bytes must be a positive integer")

        artifact = next(
            (value for value in job.artifacts if value.format == artifact_format),
            None,
        )
        if artifact is not None:
            if sha256 != artifact.sha256 or byte_count != artifact.bytes:
                raise ValueError("download receipt does not match the ready artifact")
        elif artifact_format == "zip-stored-v1" and job.pack_path:
            if job.pack_bytes is not None and byte_count != job.pack_bytes:
                raise ValueError("download receipt does not match the ready pack")
        else:
            raise ValueError("download receipt references an unknown artifact")

        return self.store.record_download(
            job_id,
            MapDownloadReceipt(
                receipt_id=receipt_id,
                artifact_format=artifact_format,
                bytes=byte_count,
                sha256=sha256,
                downloaded_at=utc_now_iso(),
            ),
        )

    def _new_job_id(self) -> str:
        return uuid.uuid4().hex[:20]


class JobClaimError(RuntimeError):
    pass


_CLIENT_IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9_-]{8,128}$")
_DOWNLOAD_RECEIPT_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{8,160}$")
_ARTIFACT_FORMAT_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{2,63}$")
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def _client_identifier(request: dict[str, Any], key: str) -> str | None:
    value = request.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError(f"{key} must be a string")
    return _validate_identifier(value, key)


def _validate_identifier(value: str, key: str) -> str:
    if not _CLIENT_IDENTIFIER_RE.fullmatch(value):
        raise ValueError(f"{key} must contain 8-128 letters, numbers, hyphens, or underscores")
    return value


def _normalize_user_label(value: Any) -> str:
    if not isinstance(value, str):
        raise ValueError("displayName must be a string")
    label = value.strip()
    if not label:
        raise ValueError("displayName must not be empty")
    if len(label) > 80:
        raise ValueError("displayName must be at most 80 characters")
    if any(ord(character) < 32 or ord(character) == 127 for character in label):
        raise ValueError("displayName must not contain control characters")
    return label


def _age_seconds(value: str) -> float:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return float("inf")
    return max((datetime.now(timezone.utc) - parsed).total_seconds(), 0)
