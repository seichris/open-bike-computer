"""Durable SQLite coordinator primitives for internal building chunks."""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

from .building_resource_model import (
    CONSERVATIVE_WALL_MODEL_VERSION,
    CONSERVATIVE_MEMORY_MODEL_VERSION,
    DEFAULT_UNKNOWN_WORKLOAD_MEMORY_RESERVATION_BYTES,
    conservative_peak_memory_bytes,
    conservative_wall_seconds,
    summarize_resource_observations,
)

BUILDING_TASK_SCHEMA_VERSION = 6
DEFAULT_BUILDING_TASK_RETENTION_DAYS = 30
_SHA256 = re.compile(r"[0-9a-f]{64}")
_TASK_STATES = {"pending", "leased", "ready", "split", "failed", "cancelled"}
_PLAN_STATES = {
    "global_scope_planning",
    "source_preparation",
    "chunk_planning",
    "planning",
    "building_chunks",
    "map_assembly",
    "assembly",
    "artifact_validation",
    "artifact_publication",
    "observed",
    "ready",
    "failed",
    "cancelled",
}
_PLAN_STAGE_ORDER = {
    "global_scope_planning": 0,
    "source_preparation": 1,
    "chunk_planning": 2,
    "planning": 2,
    "building_chunks": 3,
    "map_assembly": 4,
    "assembly": 4,
    "artifact_validation": 5,
    "artifact_publication": 6,
    "observed": 7,
    "ready": 7,
    "failed": 7,
    "cancelled": 7,
}
_TERMINAL_PLAN_STATES = {"observed", "ready", "failed", "cancelled"}
_MEMORY_ADMISSION_FRACTION = 0.85
_MEMORY_ADMISSION_PERCENT = 85
_DEFAULT_RESOURCE_POOL = "default"
_DEFAULT_MAX_CONCURRENT_TASKS = 1
_DEFAULT_SPLIT_DEPTH_LIMIT = 16
_DEFAULT_SCHEDULING_WEIGHT = 1
_DEFAULT_ADMISSION_PRIORITY = 0
_PARENT_RESOURCE_PHASES = frozenset({"source_preparation", "map_assembly"})


class BuildingTaskStoreError(RuntimeError):
    pass


class StaleLeaseError(BuildingTaskStoreError):
    pass


@dataclass(frozen=True)
class BuildingTaskRecord:
    task_id: str
    parent_job_id: str
    kind: str
    blocks: tuple[tuple[int, int], ...]
    chunk_plan_sha256: str
    closure_plan_sha256: str | None
    state: str
    split_depth: int
    transient_attempts: int
    lease_owner: str | None
    lease_token: str | None
    lease_expires_at: float | None
    heartbeat_at: float | None
    typed_error: str | None
    next_eligible_at: float | None
    output_receipt_set_sha256: str | None
    predicted_resource: Mapping[str, Any] | None


@dataclass(frozen=True)
class ClaimedBuildingTask:
    task: BuildingTaskRecord
    lease_token: str
    attempt_number: int


@dataclass(frozen=True)
class BuildingTaskSpec:
    task_id: str
    parent_job_id: str
    kind: str
    blocks: tuple[tuple[int, int], ...]
    chunk_plan_sha256: str
    closure_plan_sha256: str | None = None
    split_depth: int = 0
    predicted_resource: Mapping[str, Any] | None = None


@dataclass(frozen=True)
class ParentPhaseReservation:
    parent_job_id: str
    phase: str
    worker_id: str
    lease_token: str
    resource_pool: str
    expires_at: float


def deterministic_building_task_id(
    *,
    parent_job_id: str,
    kind: str,
    blocks: Sequence[tuple[int, int]],
    chunk_plan_sha256: str,
    split_depth: int = 0,
) -> str:
    """Return the stable ID used for one planned child task."""

    if not parent_job_id or not kind:
        raise BuildingTaskStoreError("task identity is incomplete")
    _require_sha(chunk_plan_sha256, "chunk_plan_sha256")
    normalized = tuple(sorted(set(blocks)))
    if not normalized:
        raise BuildingTaskStoreError("task must own at least one block")
    for block in normalized:
        _validate_block(block)
    if isinstance(split_depth, bool) or not isinstance(split_depth, int) or split_depth < 0:
        raise BuildingTaskStoreError("task split depth is invalid")
    payload = _canonical_json(
        {
            "parentJobId": parent_job_id,
            "kind": kind,
            "blocks": [[x, y] for x, y in normalized],
            "chunkPlanSha256": chunk_plan_sha256,
            "splitDepth": split_depth,
        }
    )
    return f"building-task-{hashlib.sha256(payload).hexdigest()[:32]}"


class BuildingTaskStore:
    """Transactional parent/task/attempt/receipt store for one host.

    SQLite WAL is supported only while all workers share the same persistent
    local volume.  Task publication is fenced by both lease token and parent
    cancellation generation.
    """

    def __init__(self, path: str | Path, *, clock=None):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._clock = clock or time.time
        self._initialize()

    def create_plan(
        self,
        *,
        parent_job_id: str,
        global_plan_sha256: str,
        input_identity: Mapping[str, Any],
        expected_output_block_count: int,
        policy_version: int,
        resource_model_version: str,
        stage: str = "planning",
        scheduling_weight: int = _DEFAULT_SCHEDULING_WEIGHT,
        admission_priority: int = _DEFAULT_ADMISSION_PRIORITY,
        active_task_quota: int | None = None,
    ) -> None:
        _require_sha(global_plan_sha256, "global_plan_sha256")
        if not isinstance(parent_job_id, str) or not parent_job_id:
            raise BuildingTaskStoreError("parent job ID is required")
        if (
            isinstance(expected_output_block_count, bool)
            or not isinstance(expected_output_block_count, int)
            or expected_output_block_count <= 0
        ):
            raise BuildingTaskStoreError("expected output block count is invalid")
        if stage not in _PLAN_STATES:
            raise BuildingTaskStoreError("plan stage is invalid")
        _validate_scheduling_policy(
            scheduling_weight=scheduling_weight,
            admission_priority=admission_priority,
            active_task_quota=active_task_quota,
        )
        now = self._clock()
        payload = _canonical_json(dict(input_identity))
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute(
                "SELECT global_plan_sha256, input_identity_json, expected_output_block_count, policy_version, resource_model_version, scheduling_weight, admission_priority, active_task_quota FROM map_build_plans WHERE parent_job_id = ?",
                (parent_job_id,),
            ).fetchone()
            if existing is not None:
                if tuple(existing) != (
                    global_plan_sha256,
                    payload.decode("utf-8"),
                    expected_output_block_count,
                    policy_version,
                    resource_model_version,
                    scheduling_weight,
                    admission_priority,
                    active_task_quota,
                ):
                    raise BuildingTaskStoreError("parent plan identity changed")
            else:
                connection.execute(
                    """
                    INSERT INTO map_build_plans(
                        parent_job_id, global_plan_sha256, input_identity_json,
                        stage, state, expected_output_block_count,
                        policy_version, resource_model_version,
                        cancellation_generation, scheduling_weight,
                        admission_priority, active_task_quota,
                        virtual_finish, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, 0, ?, ?)
                    """,
                    (
                        parent_job_id,
                        global_plan_sha256,
                        payload.decode("utf-8"),
                        stage,
                        stage,
                        expected_output_block_count,
                        policy_version,
                        resource_model_version,
                        scheduling_weight,
                        admission_priority,
                        active_task_quota,
                        now,
                        now,
                    ),
                )
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def add_tasks(self, tasks: Sequence[BuildingTaskSpec]) -> None:
        if not tasks:
            return
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            for spec in tasks:
                existing = connection.execute(
                    "SELECT * FROM map_build_tasks WHERE task_id=?",
                    (spec.task_id,),
                ).fetchone()
                if existing is not None:
                    self._validate_existing_task(existing, spec)
                    continue
                self._insert_task(connection, spec)
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def set_plan_stage(
        self,
        parent_job_id: str,
        *,
        stage: str,
        state: str | None = None,
        now: float | None = None,
    ) -> dict[str, Any]:
        """Advance the parent coordinator stage without permitting regression."""

        if stage not in _PLAN_STATES:
            raise BuildingTaskStoreError("plan stage is invalid")
        next_state = stage if state is None else state
        if next_state not in _PLAN_STATES:
            raise BuildingTaskStoreError("plan state is invalid")
        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT stage, state FROM map_build_plans WHERE parent_job_id=?",
                (parent_job_id,),
            ).fetchone()
            if row is None:
                raise BuildingTaskStoreError("parent plan not found")
            current_stage = row["stage"]
            current_state = row["state"]
            if (
                current_state in _TERMINAL_PLAN_STATES
                and (current_state != next_state or current_stage != stage)
            ):
                raise BuildingTaskStoreError("parent plan is terminal")
            if _PLAN_STAGE_ORDER[stage] < _PLAN_STAGE_ORDER[current_stage]:
                raise BuildingTaskStoreError("plan stage cannot move backwards")
            connection.execute(
                "UPDATE map_build_plans SET stage=?, state=?, updated_at=? WHERE parent_job_id=?",
                (stage, next_state, now, parent_job_id),
            )
            connection.commit()
            return dict(
                connection.execute(
                    "SELECT * FROM map_build_plans WHERE parent_job_id=?",
                    (parent_job_id,),
                ).fetchone()
            )
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def advance_plan_stage(
        self,
        parent_job_id: str,
        *,
        stage: str,
        state: str | None = None,
        now: float | None = None,
    ) -> dict[str, Any]:
        """Advance a resumable plan, treating an already-later stage as done.

        Job and coordinator state are persisted in separate stores. A worker
        can therefore restart after the coordinator advanced but before the
        public job record did. Retry callers use this method for idempotent
        forward progress; terminal states remain fenced.
        """

        if stage not in _PLAN_STATES:
            raise BuildingTaskStoreError("plan stage is invalid")
        next_state = stage if state is None else state
        if next_state not in _PLAN_STATES:
            raise BuildingTaskStoreError("plan state is invalid")
        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT * FROM map_build_plans WHERE parent_job_id=?",
                (parent_job_id,),
            ).fetchone()
            if row is None:
                raise BuildingTaskStoreError("parent plan not found")
            if row["state"] in _TERMINAL_PLAN_STATES:
                if row["state"] == next_state and row["stage"] == stage:
                    connection.commit()
                    return dict(row)
                raise BuildingTaskStoreError("parent plan is terminal")
            if _PLAN_STAGE_ORDER[stage] <= _PLAN_STAGE_ORDER[row["stage"]]:
                connection.commit()
                return dict(row)
            connection.execute(
                "UPDATE map_build_plans SET stage=?, state=?, updated_at=? WHERE parent_job_id=?",
                (stage, next_state, now, parent_job_id),
            )
            result = connection.execute(
                "SELECT * FROM map_build_plans WHERE parent_job_id=?",
                (parent_job_id,),
            ).fetchone()
            connection.commit()
            return dict(result)
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def reopen_failed_plan(
        self,
        parent_job_id: str,
        *,
        stage: str = "chunk_planning",
        now: float | None = None,
    ) -> dict[str, Any] | None:
        """Requeue a failed parent for a bounded job-level retry.

        Job retries keep the same parent identity.  Reopening only a failed
        plan preserves ready receipts, split history, and all attempt
        observations while making failed child tasks eligible for a fresh
        lease.  Cancelled and ready plans remain terminal by design.
        """

        if stage not in _PLAN_STATES or stage in _TERMINAL_PLAN_STATES:
            raise BuildingTaskStoreError("plan stage is invalid")
        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT * FROM map_build_plans WHERE parent_job_id=?",
                (parent_job_id,),
            ).fetchone()
            if row is None:
                connection.commit()
                return None
            if row["state"] == "failed":
                connection.execute(
                    """
                    UPDATE map_build_plans
                    SET stage=?, state=?, updated_at=?
                    WHERE parent_job_id=?
                    """,
                    (stage, stage, now, parent_job_id),
                )
                connection.execute(
                    """
                    UPDATE map_build_tasks
                    SET state='pending', typed_error=NULL,
                        lease_owner=NULL, lease_token=NULL,
                        lease_expires_at=NULL, heartbeat_at=NULL,
                        next_eligible_at=?, updated_at=?
                    WHERE parent_job_id=? AND state='failed'
                    """,
                    (now, now, parent_job_id),
                )
                connection.execute(
                    "DELETE FROM map_build_resource_reservations WHERE parent_job_id=?",
                    (parent_job_id,),
                )
                connection.execute(
                    "DELETE FROM map_build_parent_phase_reservations WHERE parent_job_id=?",
                    (parent_job_id,),
                )
            result = connection.execute(
                "SELECT * FROM map_build_plans WHERE parent_job_id=?",
                (parent_job_id,),
            ).fetchone()
            connection.commit()
            return dict(result) if result is not None else None
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def mark_plan_observed(
        self,
        parent_job_id: str,
        *,
        now: float | None = None,
    ) -> dict[str, Any]:
        """Terminalize a shadow-only plan without making its tasks claimable."""

        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            plan = connection.execute(
                "SELECT * FROM map_build_plans WHERE parent_job_id=?",
                (parent_job_id,),
            ).fetchone()
            if plan is None:
                raise BuildingTaskStoreError("parent plan not found")
            if plan["state"] == "observed":
                connection.commit()
                return dict(plan)
            if plan["state"] in _TERMINAL_PLAN_STATES:
                raise BuildingTaskStoreError("parent plan is terminal")
            non_pending = connection.execute(
                "SELECT 1 FROM map_build_tasks WHERE parent_job_id=? AND state!='pending' LIMIT 1",
                (parent_job_id,),
            ).fetchone()
            if non_pending is not None:
                raise BuildingTaskStoreError(
                    "shadow plan contains executable task history"
                )
            connection.execute(
                "UPDATE map_build_tasks SET state='cancelled', typed_error='building_shadow_observed', updated_at=? WHERE parent_job_id=?",
                (now, parent_job_id),
            )
            connection.execute(
                "UPDATE map_build_plans SET stage='observed', state='observed', updated_at=? WHERE parent_job_id=?",
                (now, parent_job_id),
            )
            result = connection.execute(
                "SELECT * FROM map_build_plans WHERE parent_job_id=?",
                (parent_job_id,),
            ).fetchone()
            connection.commit()
            return dict(result)
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def activate_observed_plan(
        self,
        parent_job_id: str,
        *,
        stage: str = "chunk_planning",
        now: float | None = None,
    ) -> dict[str, Any] | None:
        """Replace disposable shadow tasks before executing the same parent."""

        if stage not in _PLAN_STATES or stage in _TERMINAL_PLAN_STATES:
            raise BuildingTaskStoreError("plan stage is invalid")
        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            plan = connection.execute(
                "SELECT * FROM map_build_plans WHERE parent_job_id=?",
                (parent_job_id,),
            ).fetchone()
            if plan is None:
                connection.commit()
                return None
            if plan["state"] != "observed":
                connection.commit()
                return dict(plan)
            evidence = connection.execute(
                """
                SELECT 1
                FROM map_build_tasks tasks
                WHERE tasks.parent_job_id=? AND (
                    EXISTS(SELECT 1 FROM map_build_task_attempts attempts WHERE attempts.task_id=tasks.task_id)
                    OR EXISTS(SELECT 1 FROM map_build_workload_receipts workloads WHERE workloads.task_id=tasks.task_id)
                    OR EXISTS(SELECT 1 FROM map_build_block_receipts receipts WHERE receipts.task_id=tasks.task_id)
                    OR EXISTS(SELECT 1 FROM map_build_resource_reservations reservations WHERE reservations.task_id=tasks.task_id)
                )
                LIMIT 1
                """,
                (parent_job_id,),
            ).fetchone()
            if evidence is not None:
                raise BuildingTaskStoreError(
                    "observed plan unexpectedly contains execution evidence"
                )
            task_ids = [
                row["task_id"]
                for row in connection.execute(
                    "SELECT task_id FROM map_build_tasks WHERE parent_job_id=?",
                    (parent_job_id,),
                ).fetchall()
            ]
            if task_ids:
                placeholders = ",".join("?" for _ in task_ids)
                connection.execute(
                    f"DELETE FROM map_build_task_blocks WHERE task_id IN ({placeholders})",
                    task_ids,
                )
                connection.execute(
                    f"DELETE FROM map_build_tasks WHERE task_id IN ({placeholders})",
                    task_ids,
                )
            connection.execute(
                "UPDATE map_build_plans SET stage=?, state=?, updated_at=? WHERE parent_job_id=?",
                (stage, stage, now, parent_job_id),
            )
            result = connection.execute(
                "SELECT * FROM map_build_plans WHERE parent_job_id=?",
                (parent_job_id,),
            ).fetchone()
            connection.commit()
            return dict(result)
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def reconcile_ready_plans(
        self,
        parent_job_ids: Iterable[str],
        *,
        now: float | None = None,
    ) -> int:
        """Finalize coordinator publication after the public jobs are ready."""

        parent_ids = tuple(dict.fromkeys(str(value) for value in parent_job_ids))
        if not parent_ids:
            return 0
        now = self._clock() if now is None else now
        placeholders = ",".join("?" for _ in parent_ids)
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            rows = connection.execute(
                f"""
                SELECT parent_job_id
                FROM map_build_plans
                WHERE parent_job_id IN ({placeholders})
                  AND state='artifact_publication'
                """,
                parent_ids,
            ).fetchall()
            ready_ids = tuple(str(row["parent_job_id"]) for row in rows)
            if ready_ids:
                ready_placeholders = ",".join("?" for _ in ready_ids)
                connection.execute(
                    f"""
                    UPDATE map_build_plans
                    SET stage='ready', state='ready', updated_at=?
                    WHERE parent_job_id IN ({ready_placeholders})
                      AND state='artifact_publication'
                    """,
                    (now, *ready_ids),
                )
            connection.commit()
            return len(ready_ids)
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def claim_next(
        self,
        *,
        worker_id: str,
        parent_job_id: str | None = None,
        lease_seconds: float = 60.0,
        now: float | None = None,
        worker_capability: Mapping[str, Any] | None = None,
    ) -> ClaimedBuildingTask | None:
        if not worker_id or lease_seconds <= 0:
            raise BuildingTaskStoreError("worker and lease are required")
        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            self._recover_expired_locked(connection, now=now)
            where = [
                "task.state = 'pending'",
                "(task.next_eligible_at IS NULL OR task.next_eligible_at <= ?)",
                "plan.state NOT IN ('observed', 'cancelled', 'failed', 'ready')",
            ]
            params: list[Any] = [now]
            if parent_job_id is not None:
                where.append("task.parent_job_id = ?")
                params.append(parent_job_id)
            rows = connection.execute(
                f"""
                SELECT task.*, plan.scheduling_weight,
                       plan.admission_priority, plan.active_task_quota,
                       plan.virtual_finish
                FROM map_build_tasks task
                JOIN map_build_plans plan ON plan.parent_job_id = task.parent_job_id
                WHERE {' AND '.join(where)}
                ORDER BY
                    plan.admission_priority DESC,
                    plan.virtual_finish,
                    CASE WHEN plan.last_claimed_at IS NULL THEN 0 ELSE 1 END,
                    plan.last_claimed_at,
                    plan.parent_job_id,
                    task.created_at,
                    task.task_id
                """,
                params,
            ).fetchall()
            row = None
            resource_request = None
            fair_parent_ids = {
                candidate["parent_job_id"]
                for candidate in rows
                if _worker_can_admit(candidate, worker_capability)
            }
            active_parent_ids: set[str] = set()
            if worker_capability is not None:
                active_parent_ids = _active_reservation_parent_ids(
                    connection,
                    resource_pool=str(
                        worker_capability.get("resourcePool", _DEFAULT_RESOURCE_POOL)
                    ),
                    now=now,
                )
            for candidate in rows:
                if not _worker_can_admit(candidate, worker_capability):
                    continue
                active_task_quota = candidate["active_task_quota"]
                if active_task_quota is not None:
                    active_for_parent = connection.execute(
                        "SELECT COUNT(*) FROM map_build_tasks WHERE parent_job_id=? AND state='leased'",
                        (candidate["parent_job_id"],),
                    ).fetchone()[0]
                    if int(active_for_parent) >= int(active_task_quota):
                        continue
                request = _resource_request(candidate, worker_capability)
                if request is not None and request["maxConcurrentTasks"] > 1:
                    if (
                        len(fair_parent_ids) > 1
                        and candidate["parent_job_id"] in active_parent_ids
                        and fair_parent_ids - active_parent_ids
                    ):
                        continue
                if request is None:
                    row = candidate
                    break
                if _resource_capacity_available(
                    connection, request, now=now
                ):
                    row = candidate
                    resource_request = request
                    break
            if row is None:
                connection.commit()
                return None
            lease_token = uuid.uuid4().hex
            attempt_number = int(row["transient_attempts"]) + 1
            expires = now + lease_seconds
            connection.execute(
                """
                UPDATE map_build_tasks
                SET state='leased', lease_owner=?, lease_token=?,
                    lease_expires_at=?, heartbeat_at=?, transient_attempts=?,
                    updated_at=?
                WHERE task_id=? AND state='pending'
                """,
                (
                    worker_id,
                    lease_token,
                    expires,
                    now,
                    attempt_number,
                    now,
                    row["task_id"],
                ),
            )
            connection.execute(
                "UPDATE map_build_plans SET last_claimed_at=?, virtual_finish=? WHERE parent_job_id=?",
                (
                    now,
                    float(row["virtual_finish"] or 0.0)
                    + _dispatch_cost(row) / float(row["scheduling_weight"]),
                    row["parent_job_id"],
                ),
            )
            admission = _resource_admission(row, worker_capability)
            if resource_request is not None:
                active = _resource_capacity_snapshot(
                    connection, resource_request["resourcePool"], now=now
                )
                admission.update(
                    {
                        "activeReservations": active["count"],
                        "activeMemoryReservationBytes": active["memoryBytes"],
                        "activeCpuWeight": active["cpuWeight"],
                        "reservationAccepted": True,
                    }
                )
                connection.execute(
                    """
                    INSERT INTO map_build_resource_reservations(
                        task_id, parent_job_id, lease_token, worker_id,
                        resource_pool, memory_reservation_bytes,
                        memory_limit_bytes, cpu_weight, cpu_capacity,
                        max_concurrent_tasks, capability_json,
                        reserved_at, expires_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        row["task_id"],
                        row["parent_job_id"],
                        lease_token,
                        worker_id,
                        resource_request["resourcePool"],
                        resource_request["memoryReservationBytes"],
                        resource_request["memoryLimitBytes"],
                        resource_request["cpuWeight"],
                        resource_request["cpuCapacity"],
                        resource_request["maxConcurrentTasks"],
                        _canonical_json(dict(worker_capability or {})).decode(
                            "utf-8"
                        ),
                        now,
                        expires,
                    ),
                )
            connection.execute(
                """
                INSERT INTO map_build_task_attempts(
                    task_id, attempt_number, worker_capability_json,
                    started_at, outcome, predicted_resource_json,
                    actual_resource_json, phase_timings_json, peak_rss_bytes,
                    typed_failure
                ) VALUES (?, ?, ?, ?, 'leased', ?, NULL, NULL, NULL, NULL)
                """,
                (
                    row["task_id"],
                    attempt_number,
                    _canonical_json(
                        {
                            "workerId": worker_id,
                            "capability": dict(worker_capability or {}),
                            "admission": admission,
                        }
                    ).decode("utf-8"),
                    now,
                    row["predicted_resource_json"],
                ),
            )
            connection.commit()
            task = self._row_to_task(
                connection.execute(
                    "SELECT * FROM map_build_tasks WHERE task_id=?",
                    (row["task_id"],),
                ).fetchone()
            )
            return ClaimedBuildingTask(task, lease_token, attempt_number)
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def acquire_parent_phase_reservation(
        self,
        *,
        parent_job_id: str,
        phase: str,
        worker_id: str,
        worker_capability: Mapping[str, Any] | None,
        lease_seconds: float = 60.0,
        estimated_peak_memory_bytes: int = (
            DEFAULT_UNKNOWN_WORKLOAD_MEMORY_RESERVATION_BYTES
        ),
        now: float | None = None,
    ) -> ParentPhaseReservation | None:
        """Atomically reserve the shared heavy-work pool for a parent phase.

        Parent source preparation can run before its chunk plan exists, so
        these leases intentionally live outside the task/plan foreign-key
        graph. They still participate in the exact same pool capacity snapshot
        as child leases. Parent phases are always concurrency-one: an active
        parent lease therefore excludes both other parent phases and children,
        even if a differently configured worker reports a larger concurrency.
        """

        if not isinstance(parent_job_id, str) or not parent_job_id:
            raise BuildingTaskStoreError("parent job ID is required")
        if phase not in _PARENT_RESOURCE_PHASES:
            raise BuildingTaskStoreError("parent resource phase is invalid")
        if not isinstance(worker_id, str) or not worker_id or lease_seconds <= 0:
            raise BuildingTaskStoreError("worker and lease are required")
        request, effective_capability = _parent_phase_resource_request(
            worker_capability,
            estimated_peak_memory_bytes=estimated_peak_memory_bytes,
        )
        now = self._clock() if now is None else now
        expires = now + lease_seconds
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            self._recover_expired_locked(connection, now=now)
            plan = connection.execute(
                "SELECT state FROM map_build_plans WHERE parent_job_id=?",
                (parent_job_id,),
            ).fetchone()
            if plan is not None and plan["state"] in {
                "observed",
                "cancelled",
                "failed",
            }:
                raise BuildingTaskStoreError("parent plan is terminal")
            if not _resource_capacity_available(connection, request, now=now):
                connection.commit()
                return None
            lease_token = uuid.uuid4().hex
            connection.execute(
                """
                INSERT INTO map_build_parent_phase_reservations(
                    parent_job_id, phase, lease_token, worker_id,
                    resource_pool, memory_reservation_bytes,
                    memory_limit_bytes, cpu_weight, cpu_capacity,
                    max_concurrent_tasks, capability_json,
                    reserved_at, heartbeat_at, expires_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    parent_job_id,
                    phase,
                    lease_token,
                    worker_id,
                    request["resourcePool"],
                    request["memoryReservationBytes"],
                    request["memoryLimitBytes"],
                    request["cpuWeight"],
                    request["cpuCapacity"],
                    request["maxConcurrentTasks"],
                    _canonical_json(effective_capability).decode("utf-8"),
                    now,
                    now,
                    expires,
                ),
            )
            connection.commit()
            return ParentPhaseReservation(
                parent_job_id=parent_job_id,
                phase=phase,
                worker_id=worker_id,
                lease_token=lease_token,
                resource_pool=request["resourcePool"],
                expires_at=expires,
            )
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def heartbeat_parent_phase_reservation(
        self,
        *,
        parent_job_id: str,
        phase: str,
        worker_id: str,
        lease_token: str,
        lease_seconds: float = 60.0,
        now: float | None = None,
    ) -> ParentPhaseReservation:
        if phase not in _PARENT_RESOURCE_PHASES or lease_seconds <= 0:
            raise BuildingTaskStoreError("parent resource lease is invalid")
        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            row = _locked_parent_phase_reservation(
                connection,
                parent_job_id=parent_job_id,
                phase=phase,
                worker_id=worker_id,
                lease_token=lease_token,
                now=now,
            )
            plan = connection.execute(
                "SELECT state FROM map_build_plans WHERE parent_job_id=?",
                (parent_job_id,),
            ).fetchone()
            if plan is not None and plan["state"] in {
                "observed",
                "cancelled",
                "failed",
            }:
                raise StaleLeaseError("parent plan is no longer active")
            expires = now + lease_seconds
            connection.execute(
                """
                UPDATE map_build_parent_phase_reservations
                SET heartbeat_at=?, expires_at=?
                WHERE parent_job_id=? AND phase=? AND lease_token=?
                """,
                (now, expires, parent_job_id, phase, lease_token),
            )
            connection.commit()
            return ParentPhaseReservation(
                parent_job_id=parent_job_id,
                phase=phase,
                worker_id=worker_id,
                lease_token=lease_token,
                resource_pool=str(row["resource_pool"]),
                expires_at=expires,
            )
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def release_parent_phase_reservation(
        self,
        *,
        parent_job_id: str,
        phase: str,
        worker_id: str,
        lease_token: str,
        now: float | None = None,
    ) -> None:
        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            _locked_parent_phase_reservation(
                connection,
                parent_job_id=parent_job_id,
                phase=phase,
                worker_id=worker_id,
                lease_token=lease_token,
                now=now,
            )
            connection.execute(
                """
                DELETE FROM map_build_parent_phase_reservations
                WHERE parent_job_id=? AND phase=? AND lease_token=?
                """,
                (parent_job_id, phase, lease_token),
            )
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def resource_capacity_occupied(
        self,
        *,
        worker_capability: Mapping[str, Any] | None,
        now: float | None = None,
    ) -> bool:
        """Return whether a live lease temporarily occupies this worker pool."""

        request, _ = _parent_phase_resource_request(
            worker_capability,
            estimated_peak_memory_bytes=(
                DEFAULT_UNKNOWN_WORKLOAD_MEMORY_RESERVATION_BYTES
            ),
        )
        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            self._recover_expired_locked(connection, now=now)
            occupied = (
                _resource_capacity_snapshot(
                    connection,
                    request["resourcePool"],
                    now=now,
                )["count"]
                > 0
            )
            connection.commit()
            return occupied
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def next_pending_parent(
        self,
        *,
        worker_capability: Mapping[str, Any] | None = None,
        now: float | None = None,
    ) -> str | None:
        """Return the parent currently favored by the global task scheduler."""

        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            self._recover_expired_locked(connection, now=now)
            rows = connection.execute(
                """
                SELECT task.*, plan.scheduling_weight,
                       plan.admission_priority, plan.active_task_quota,
                       plan.virtual_finish
                FROM map_build_tasks task
                JOIN map_build_plans plan
                  ON plan.parent_job_id = task.parent_job_id
                WHERE task.state='pending'
                  AND (task.next_eligible_at IS NULL OR task.next_eligible_at <= ?)
                  AND plan.state NOT IN ('observed', 'cancelled', 'failed', 'ready')
                ORDER BY plan.admission_priority DESC,
                         plan.virtual_finish,
                         CASE WHEN plan.last_claimed_at IS NULL THEN 0 ELSE 1 END,
                         plan.last_claimed_at,
                         plan.parent_job_id,
                         task.created_at,
                         task.task_id
                """,
                (now,),
            ).fetchall()
            parent_job_id = next(
                (
                    str(row["parent_job_id"])
                    for row in rows
                    if _worker_can_admit(row, worker_capability)
                ),
                None,
            )
            connection.commit()
            return parent_job_id
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def heartbeat(
        self,
        task_id: str,
        *,
        worker_id: str,
        lease_token: str,
        lease_seconds: float = 60.0,
        now: float | None = None,
    ) -> BuildingTaskRecord:
        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            row = self._locked_task(
                connection, task_id, worker_id, lease_token, now=now
            )
            expires = now + lease_seconds
            connection.execute(
                "UPDATE map_build_tasks SET lease_expires_at=?, heartbeat_at=?, updated_at=? WHERE task_id=?",
                (expires, now, now, task_id),
            )
            connection.execute(
                "UPDATE map_build_resource_reservations SET expires_at=? WHERE task_id=? AND lease_token=?",
                (expires, task_id, lease_token),
            )
            connection.commit()
            return self._row_to_task(
                connection.execute(
                    "SELECT * FROM map_build_tasks WHERE task_id=?", (task_id,)
                ).fetchone()
            )
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def publish_receipt(
        self,
        task_id: str,
        *,
        worker_id: str,
        lease_token: str,
        block: tuple[int, int],
        cache_identity_sha256: str,
        content_sha256: str,
        producer_identity: Mapping[str, Any],
        validation: Mapping[str, Any],
        now: float | None = None,
    ) -> None:
        _require_sha(cache_identity_sha256, "cache_identity_sha256")
        _require_sha(content_sha256, "content_sha256")
        _validate_block(block)
        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            task = self._locked_task(
                connection, task_id, worker_id, lease_token, now=now
            )
            plan = connection.execute(
                "SELECT state, cancellation_generation FROM map_build_plans WHERE parent_job_id=?",
                (task.parent_job_id,),
            ).fetchone()
            if plan is None or plan["state"] in _TERMINAL_PLAN_STATES:
                raise StaleLeaseError("parent plan is no longer active")
            assigned = connection.execute(
                "SELECT 1 FROM map_build_task_blocks WHERE parent_job_id=? AND block_x=? AND block_y=? AND task_id=?",
                (task.parent_job_id, block[0], block[1], task_id),
            ).fetchone()
            if assigned is None:
                raise BuildingTaskStoreError("receipt block is not assigned to task")
            existing = connection.execute(
                "SELECT cache_identity_sha256, content_sha256 FROM map_build_block_receipts WHERE parent_job_id=? AND block_x=? AND block_y=?",
                (task.parent_job_id, block[0], block[1]),
            ).fetchone()
            if existing is not None:
                if tuple(existing) != (cache_identity_sha256, content_sha256):
                    raise BuildingTaskStoreError("block receipt identity changed")
            else:
                connection.execute(
                    """
                    INSERT INTO map_build_block_receipts(
                        parent_job_id, task_id, block_x, block_y,
                        cache_identity_sha256, content_sha256,
                        producer_identity_json, validation_json, published_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        task.parent_job_id,
                        task_id,
                        block[0],
                        block[1],
                        cache_identity_sha256,
                        content_sha256,
                        _canonical_json(dict(producer_identity)).decode("utf-8"),
                        _canonical_json(dict(validation)).decode("utf-8"),
                        now,
                    ),
                )
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def complete_workload_scan(
        self,
        task_id: str,
        *,
        worker_id: str,
        lease_token: str,
        workload_receipt: Mapping[str, Any],
        actual_resource: Mapping[str, Any] | None = None,
        phase_timings: Mapping[str, Any] | None = None,
        peak_rss_bytes: int | None = None,
        worker_capability: Mapping[str, Any] | None = None,
        split_depth_limit: int = _DEFAULT_SPLIT_DEPTH_LIMIT,
        now: float | None = None,
    ) -> BuildingTaskRecord:
        """Persist an exact source-index workload and release the scan task.

        A workload scan is a planning task, not a build result.  Once the
        immutable receipt is committed, the deterministic task is converted
        to a pending ``building_chunk`` so the future executor can claim it
        using the same block set and closure identity.  The receipt itself is
        retained separately for audit and runtime closure validation.
        """

        receipt = _validate_workload_receipt(workload_receipt)
        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            task = self._locked_task(
                connection, task_id, worker_id, lease_token, now=now
            )
            if task.kind != "building_workload_scan":
                raise BuildingTaskStoreError(
                    "task is not an exact workload scan"
                )
            payload = _canonical_json(receipt).decode("utf-8")
            source_identity = _canonical_json(
                {
                    "sourceIndexKey": receipt["sourceIndexKey"],
                    "sourceSnapshotSha256": receipt["sourceSnapshotSha256"],
                }
            ).decode("utf-8")
            existing = connection.execute(
                "SELECT closure_plan_sha256, source_index_identity_json, workload_json FROM map_build_workload_receipts WHERE task_id=?",
                (task_id,),
            ).fetchone()
            if existing is not None:
                if tuple(existing) != (
                    receipt["closurePlanSha256"],
                    source_identity,
                    payload,
                ):
                    raise BuildingTaskStoreError(
                        "workload receipt identity changed"
                    )
            else:
                connection.execute(
                    """
                    INSERT INTO map_build_workload_receipts(
                        task_id, parent_job_id, closure_plan_sha256,
                        source_index_identity_json, workload_json, recorded_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (
                        task_id,
                        task.parent_job_id,
                        receipt["closurePlanSha256"],
                        source_identity,
                        payload,
                        now,
                    ),
                )
            row = connection.execute(
                "SELECT predicted_resource_json FROM map_build_tasks WHERE task_id=?",
                (task_id,),
            ).fetchone()
            predicted: dict[str, Any] = {}
            if row is not None and row["predicted_resource_json"]:
                try:
                    existing_predicted = json.loads(row["predicted_resource_json"])
                    if isinstance(existing_predicted, dict):
                        predicted.update(existing_predicted)
                except (TypeError, ValueError) as exc:
                    raise BuildingTaskStoreError(
                        "task predicted resource is invalid"
                    ) from exc
            predicted["workloadReceipt"] = {
                key: receipt[key]
                for key in (
                    "relationCount",
                    "wayCount",
                    "nodeCount",
                    "totalObjectCount",
                    "storedRelationMemberCount",
                    "wayNodeReferenceCount",
                    "vertexCount",
                    "candidateOutlineCount",
                    "candidatePartCount",
                    "ringCount",
                    "holeCount",
                )
            }
            predicted["estimatedPeakMemoryBytes"] = conservative_peak_memory_bytes(
                receipt
            )
            predicted["memoryEstimateSource"] = CONSERVATIVE_MEMORY_MODEL_VERSION
            predicted["estimatedWallSeconds"] = conservative_wall_seconds(receipt)
            predicted["wallEstimateSource"] = CONSERVATIVE_WALL_MODEL_VERSION
            memory_limit = _capability_memory_limit(worker_capability or {})
            from .building_orchestration import (
                BuildingChunkPolicy,
                deterministic_runtime_bisection,
            )

            policy = BuildingChunkPolicy(split_depth_limit=split_depth_limit)
            memory_target_exceeded = (
                memory_limit is not None
                and predicted["estimatedPeakMemoryBytes"]
                > (memory_limit * 70) // 100
            )
            memory_hard_exceeded = (
                memory_limit is not None
                and predicted["estimatedPeakMemoryBytes"]
                > _memory_admission_limit(memory_limit)
            )
            wall_target_exceeded = (
                predicted["estimatedWallSeconds"]
                > policy.wall_time_target_seconds
            )
            wall_hard_exceeded = (
                predicted["estimatedWallSeconds"]
                > policy.wall_time_hard_seconds
            )
            target_violations = [
                name
                for name, exceeded in (
                    ("estimated_peak_memory", memory_target_exceeded),
                    ("wall_time", wall_target_exceeded),
                )
                if exceeded
            ]
            hard_violations = [
                name
                for name, exceeded in (
                    ("estimated_peak_memory", memory_hard_exceeded),
                    ("wall_time", wall_hard_exceeded),
                )
                if exceeded
            ]
            predicted["targetViolations"] = target_violations
            predicted["hardViolations"] = hard_violations
            can_split = (
                bool(target_violations)
                and len(task.blocks) >= 2
                and task.split_depth < split_depth_limit
            )
            if can_split:
                from .reuse import MapBlock

                left, right = deterministic_runtime_bisection(
                    tuple(MapBlock(x, y) for x, y in task.blocks)
                )
                child_specs = tuple(
                    BuildingTaskSpec(
                        task_id=deterministic_building_task_id(
                            parent_job_id=task.parent_job_id,
                            kind="building_workload_scan",
                            blocks=tuple((block.x, block.y) for block in blocks),
                            chunk_plan_sha256=task.chunk_plan_sha256,
                            split_depth=task.split_depth + 1,
                        ),
                        parent_job_id=task.parent_job_id,
                        kind="building_workload_scan",
                        blocks=tuple((block.x, block.y) for block in blocks),
                        chunk_plan_sha256=task.chunk_plan_sha256,
                        split_depth=task.split_depth + 1,
                        predicted_resource={
                            "estimatedPeakMemoryBytes": (
                                DEFAULT_UNKNOWN_WORKLOAD_MEMORY_RESERVATION_BYTES
                            ),
                            "memoryEstimateSource": (
                                CONSERVATIVE_MEMORY_MODEL_VERSION
                            ),
                            "wallEstimateSource": CONSERVATIVE_WALL_MODEL_VERSION,
                            "requiresExactWorkloadScan": True,
                        },
                    )
                    for blocks in (left, right)
                )
                connection.execute(
                    "DELETE FROM map_build_task_blocks WHERE task_id=?",
                    (task_id,),
                )
                connection.execute(
                    """
                    UPDATE map_build_tasks
                    SET state='split', typed_error='building_resource_admission',
                        lease_owner=NULL, lease_token=NULL,
                        lease_expires_at=NULL, heartbeat_at=NULL,
                        predicted_resource_json=?, updated_at=?
                    WHERE task_id=?
                    """,
                    (
                        _canonical_json(predicted).decode("utf-8"),
                        now,
                        task_id,
                    ),
                )
                connection.execute(
                    "DELETE FROM map_build_resource_reservations WHERE task_id=? AND lease_token=?",
                    (task_id, lease_token),
                )
                self._finish_attempt(
                    connection,
                    task_id,
                    task.transient_attempts,
                    outcome="split",
                    typed_failure="building_resource_admission",
                    actual_resource=actual_resource,
                    phase_timings=phase_timings,
                    peak_rss_bytes=peak_rss_bytes,
                    now=now,
                )
                for child in child_specs:
                    self._insert_task(connection, child)
                connection.commit()
                return self._row_to_task(
                    connection.execute(
                        "SELECT * FROM map_build_tasks WHERE task_id=?",
                        (task_id,),
                    ).fetchone()
                )
            if hard_violations:
                connection.execute(
                    """
                    UPDATE map_build_tasks
                    SET state='failed', typed_error='building_pathological_block',
                        lease_owner=NULL, lease_token=NULL,
                        lease_expires_at=NULL, heartbeat_at=NULL,
                        predicted_resource_json=?, updated_at=?
                    WHERE task_id=?
                    """,
                    (
                        _canonical_json(predicted).decode("utf-8"),
                        now,
                        task_id,
                    ),
                )
                connection.execute(
                    "DELETE FROM map_build_resource_reservations WHERE task_id=? AND lease_token=?",
                    (task_id, lease_token),
                )
                self._finish_attempt(
                    connection,
                    task_id,
                    task.transient_attempts,
                    outcome="failed",
                    typed_failure="building_pathological_block",
                    actual_resource=actual_resource,
                    phase_timings=phase_timings,
                    peak_rss_bytes=peak_rss_bytes,
                    now=now,
                )
                connection.commit()
                return self._row_to_task(
                    connection.execute(
                        "SELECT * FROM map_build_tasks WHERE task_id=?",
                        (task_id,),
                    ).fetchone()
                )
            connection.execute(
                """
                UPDATE map_build_tasks
                SET kind='building_chunk', closure_plan_sha256=?, state='pending',
                    predicted_resource_json=?, typed_error=NULL,
                    lease_owner=NULL, lease_token=NULL, lease_expires_at=NULL,
                    heartbeat_at=NULL, next_eligible_at=?, updated_at=?
                WHERE task_id=?
                """,
                (
                    receipt["closurePlanSha256"],
                    _canonical_json(predicted).decode("utf-8"),
                    now,
                    now,
                    task_id,
                ),
            )
            connection.execute(
                "DELETE FROM map_build_resource_reservations WHERE task_id=? AND lease_token=?",
                (task_id, lease_token),
            )
            self._finish_attempt(
                connection,
                task_id,
                task.transient_attempts,
                outcome="workload_scanned",
                actual_resource=actual_resource,
                phase_timings=phase_timings,
                peak_rss_bytes=peak_rss_bytes,
                now=now,
            )
            connection.commit()
            return self._row_to_task(
                connection.execute(
                    "SELECT * FROM map_build_tasks WHERE task_id=?", (task_id,)
                ).fetchone()
            )
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def mark_ready(
        self,
        task_id: str,
        *,
        worker_id: str,
        lease_token: str,
        actual_resource: Mapping[str, Any] | None = None,
        phase_timings: Mapping[str, Any] | None = None,
        peak_rss_bytes: int | None = None,
        now: float | None = None,
    ) -> BuildingTaskRecord:
        return self._finish_task(
            task_id,
            worker_id=worker_id,
            lease_token=lease_token,
            state="ready",
            outcome="ready",
            actual_resource=actual_resource,
            phase_timings=phase_timings,
            peak_rss_bytes=peak_rss_bytes,
            now=now,
            require_receipts=True,
        )

    def fail(
        self,
        task_id: str,
        *,
        worker_id: str,
        lease_token: str,
        typed_failure: str,
        transient: bool = True,
        actual_resource: Mapping[str, Any] | None = None,
        phase_timings: Mapping[str, Any] | None = None,
        peak_rss_bytes: int | None = None,
        now: float | None = None,
    ) -> BuildingTaskRecord:
        if not typed_failure:
            raise BuildingTaskStoreError("typed failure is required")
        return self._finish_task(
            task_id,
            worker_id=worker_id,
            lease_token=lease_token,
            state="failed" if not transient else "pending",
            outcome="failed_transient" if transient else "failed",
            typed_failure=typed_failure,
            actual_resource=actual_resource,
            phase_timings=phase_timings,
            peak_rss_bytes=peak_rss_bytes,
            now=now,
            require_receipts=False,
        )

    def split(
        self,
        task_id: str,
        *,
        worker_id: str,
        lease_token: str,
        children: Sequence[BuildingTaskSpec],
        reason: str,
        now: float | None = None,
    ) -> tuple[BuildingTaskRecord, ...]:
        if not children or not reason:
            raise BuildingTaskStoreError("split children and reason are required")
        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            task = self._locked_task(
                connection, task_id, worker_id, lease_token, now=now
            )
            parent_blocks = {
                (int(row["block_x"]), int(row["block_y"]))
                for row in connection.execute(
                    "SELECT block_x, block_y FROM map_build_task_blocks WHERE task_id=?",
                    (task_id,),
                ).fetchall()
            }
            child_blocks = {
                block
                for child in children
                for block in child.blocks
            }
            if not child_blocks or child_blocks != parent_blocks:
                raise BuildingTaskStoreError(
                    "split children must exactly cover the parent block set"
                )
            if len(child_blocks) != sum(len(set(child.blocks)) for child in children):
                raise BuildingTaskStoreError("split children overlap")
            connection.execute(
                "DELETE FROM map_build_task_blocks WHERE task_id=?",
                (task_id,),
            )
            connection.execute(
                "UPDATE map_build_tasks SET state='split', typed_error=?, lease_owner=NULL, lease_token=NULL, lease_expires_at=NULL, heartbeat_at=NULL, updated_at=? WHERE task_id=?",
                (reason, now, task_id),
            )
            connection.execute(
                "DELETE FROM map_build_resource_reservations WHERE task_id=? AND lease_token=?",
                (task_id, lease_token),
            )
            self._finish_attempt(
                connection,
                task_id,
                task.transient_attempts,
                outcome="split",
                typed_failure=reason,
                now=now,
            )
            for child in children:
                if child.parent_job_id != task.parent_job_id:
                    raise BuildingTaskStoreError("split child parent mismatch")
                self._insert_task(connection, child)
            connection.commit()
            return tuple(
                self._row_to_task(row)
                for row in connection.execute(
                    "SELECT * FROM map_build_tasks WHERE parent_job_id=? AND task_id IN (%s) ORDER BY task_id"
                    % ",".join("?" for _ in children),
                    (task.parent_job_id, *(child.task_id for child in children)),
                ).fetchall()
            )
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def split_runtime_task(
        self,
        task_id: str,
        *,
        worker_id: str,
        lease_token: str,
        reason: str,
        now: float | None = None,
        split_depth_limit: int = _DEFAULT_SPLIT_DEPTH_LIMIT,
    ) -> tuple[BuildingTaskRecord, ...]:
        """Convert a deterministic multi-block failure into scan children.

        The parent task is fenced and marked ``split`` by :meth:`split` in the
        same transaction that inserts the children.  Children deliberately
        begin as workload scans so their exact closure receipt is refreshed
        before another building attempt; this is not a transient retry.
        """

        if (
            isinstance(split_depth_limit, bool)
            or not isinstance(split_depth_limit, int)
            or split_depth_limit <= 0
        ):
            raise BuildingTaskStoreError("split depth limit is invalid")
        task = self.get_task(task_id)
        if task is None:
            raise BuildingTaskStoreError("task not found")
        if (
            task.state != "leased"
            or task.lease_owner != worker_id
            or task.lease_token != lease_token
        ):
            raise StaleLeaseError("task lease is no longer valid")
        if task.kind not in {"building_chunk", "building_workload_scan"}:
            raise BuildingTaskStoreError(
                "only building chunks or workload scans can be runtime split"
            )
        if task.split_depth >= split_depth_limit:
            raise BuildingTaskStoreError("building task split depth limit reached")
        from .building_orchestration import deterministic_runtime_bisection
        from .reuse import MapBlock

        left, right = deterministic_runtime_bisection(
            tuple(MapBlock(x, y) for x, y in task.blocks)
        )
        children: list[BuildingTaskSpec] = []
        for child_blocks in (left, right):
            blocks = tuple((block.x, block.y) for block in child_blocks)
            children.append(
                BuildingTaskSpec(
                    task_id=deterministic_building_task_id(
                        parent_job_id=task.parent_job_id,
                        kind="building_workload_scan",
                        blocks=blocks,
                        chunk_plan_sha256=task.chunk_plan_sha256,
                        split_depth=task.split_depth + 1,
                    ),
                    parent_job_id=task.parent_job_id,
                    kind="building_workload_scan",
                    blocks=blocks,
                    chunk_plan_sha256=task.chunk_plan_sha256,
                    split_depth=task.split_depth + 1,
                    predicted_resource={
                        "requiresExactWorkloadScan": True,
                        "splitFromTaskId": task.task_id,
                        "splitReason": reason,
                    },
                )
            )
        return self.split(
            task_id,
            worker_id=worker_id,
            lease_token=lease_token,
            children=children,
            reason=reason,
            now=now,
        )

    def cancel_plan(self, parent_job_id: str, *, now: float | None = None) -> None:
        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                "UPDATE map_build_plans SET state='cancelled', stage='cancelled', cancellation_generation=cancellation_generation+1, updated_at=? WHERE parent_job_id=? AND state NOT IN ('observed', 'cancelled', 'ready')",
                (now, parent_job_id),
            )
            connection.execute(
                """
                UPDATE map_build_task_attempts
                SET finished_at=?, outcome='cancelled',
                    typed_failure=COALESCE(typed_failure, 'building_task_cancelled')
                WHERE task_id IN (
                    SELECT task_id FROM map_build_tasks
                    WHERE parent_job_id=? AND state='leased'
                ) AND finished_at IS NULL
                """,
                (now, parent_job_id),
            )
            connection.execute(
                "UPDATE map_build_tasks SET state='cancelled', lease_owner=NULL, lease_token=NULL, lease_expires_at=NULL, heartbeat_at=NULL, updated_at=? WHERE parent_job_id=? AND state IN ('pending','leased')",
                (now, parent_job_id),
            )
            connection.execute(
                "DELETE FROM map_build_resource_reservations WHERE parent_job_id=?",
                (parent_job_id,),
            )
            connection.execute(
                "DELETE FROM map_build_parent_phase_reservations WHERE parent_job_id=?",
                (parent_job_id,),
            )
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def reconcile_cancelled_plans(
        self,
        parent_job_ids: Iterable[str],
        *,
        now: float | None = None,
    ) -> int:
        """Fence coordinator state for parents cancelled outside the worker.

        API cancellation normally calls :meth:`cancel_plan` synchronously,
        but maintenance is the backstop for an interrupted API request,
        legacy/direct ``JobStore`` cancellation, or a coordinator store that
        was temporarily unavailable.  Reconciliation is idempotent and
        releases leases/reservations without touching ready plans.
        """

        parent_ids = tuple(dict.fromkeys(str(value) for value in parent_job_ids))
        if not parent_ids:
            return 0
        now = self._clock() if now is None else now
        placeholders = ",".join("?" for _ in parent_ids)
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            active = connection.execute(
                f"SELECT parent_job_id FROM map_build_plans "
                f"WHERE parent_job_id IN ({placeholders}) "
                "AND state NOT IN ('observed', 'cancelled', 'ready')",
                parent_ids,
            ).fetchall()
            active_ids = tuple(row[0] for row in active)
            if active_ids:
                active_placeholders = ",".join("?" for _ in active_ids)
                connection.execute(
                    f"UPDATE map_build_plans SET state='cancelled', stage='cancelled', "
                    f"cancellation_generation=cancellation_generation+1, updated_at=? "
                    f"WHERE parent_job_id IN ({active_placeholders})",
                    (now, *active_ids),
                )
            cancelled_placeholders = ",".join("?" for _ in parent_ids)
            connection.execute(
                f"""
                UPDATE map_build_task_attempts
                SET finished_at=?, outcome='cancelled',
                    typed_failure=COALESCE(typed_failure, 'building_task_cancelled')
                WHERE task_id IN (
                    SELECT task_id FROM map_build_tasks
                    WHERE parent_job_id IN ({cancelled_placeholders})
                ) AND finished_at IS NULL AND task_id IN (
                    SELECT t.task_id FROM map_build_tasks t
                    JOIN map_build_plans p ON p.parent_job_id=t.parent_job_id
                    WHERE p.state='cancelled'
                )
                """,
                (now, *parent_ids),
            )
            connection.execute(
                f"UPDATE map_build_tasks SET state='cancelled', lease_owner=NULL, "
                f"lease_token=NULL, lease_expires_at=NULL, heartbeat_at=NULL, "
                f"updated_at=? WHERE parent_job_id IN ({cancelled_placeholders}) "
                "AND state IN ('pending','leased') AND parent_job_id IN "
                f"(SELECT parent_job_id FROM map_build_plans WHERE state='cancelled')",
                (now, *parent_ids),
            )
            connection.execute(
                f"DELETE FROM map_build_resource_reservations "
                f"WHERE parent_job_id IN ({cancelled_placeholders})",
                parent_ids,
            )
            connection.execute(
                f"DELETE FROM map_build_parent_phase_reservations "
                f"WHERE parent_job_id IN ({cancelled_placeholders})",
                parent_ids,
            )
            connection.commit()
            return len(active_ids)
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def recover_expired(self, *, now: float | None = None) -> int:
        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            recovered = self._recover_expired_locked(connection, now=now)
            connection.commit()
            return recovered
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def list_tasks(self, parent_job_id: str) -> tuple[BuildingTaskRecord, ...]:
        connection = self._connect()
        try:
            return tuple(
                self._row_to_task(row)
                for row in connection.execute(
                    "SELECT * FROM map_build_tasks WHERE parent_job_id=? ORDER BY created_at, task_id",
                    (parent_job_id,),
                ).fetchall()
            )
        finally:
            connection.close()

    def get_task(self, task_id: str) -> BuildingTaskRecord | None:
        connection = self._connect()
        try:
            row = connection.execute(
                "SELECT * FROM map_build_tasks WHERE task_id=?", (task_id,)
            ).fetchone()
            return self._row_to_task(row) if row is not None else None
        finally:
            connection.close()

    def list_receipts(self, parent_job_id: str) -> tuple[dict[str, Any], ...]:
        connection = self._connect()
        try:
            return tuple(dict(row) for row in connection.execute(
                "SELECT * FROM map_build_block_receipts WHERE parent_job_id=? ORDER BY block_x, block_y",
                (parent_job_id,),
            ).fetchall())
        finally:
            connection.close()

    def cache_retention_protection(self) -> dict[str, Any]:
        """Snapshot cache identities still required by nonterminal plans.

        Cache-hit tasks created before the identity field was persisted cannot
        be tied to one namespace. Such legacy active tasks fail closed by
        protecting the complete cache until they become terminal or are
        recovered through normal execution.
        """

        connection = self._connect()
        try:
            connection.execute("BEGIN")
            protected: set[str] = set()
            protect_all = False
            receipt_rows = connection.execute(
                """
                SELECT receipts.cache_identity_sha256
                FROM map_build_block_receipts AS receipts
                JOIN map_build_plans AS plans
                  ON plans.parent_job_id = receipts.parent_job_id
                WHERE plans.state NOT IN ('observed', 'ready', 'failed', 'cancelled')
                """
            ).fetchall()
            for row in receipt_rows:
                identity = row["cache_identity_sha256"]
                if not isinstance(identity, str) or not _SHA256.fullmatch(identity):
                    protect_all = True
                else:
                    protected.add(identity)
            task_rows = connection.execute(
                """
                SELECT tasks.predicted_resource_json
                FROM map_build_tasks AS tasks
                JOIN map_build_plans AS plans
                  ON plans.parent_job_id = tasks.parent_job_id
                WHERE plans.state NOT IN ('observed', 'ready', 'failed', 'cancelled')
                """
            ).fetchall()
            for row in task_rows:
                payload = row["predicted_resource_json"]
                if payload is None:
                    continue
                try:
                    predicted = json.loads(payload)
                except (TypeError, ValueError, json.JSONDecodeError):
                    protect_all = True
                    continue
                if not isinstance(predicted, dict):
                    protect_all = True
                    continue
                if predicted.get("cacheHit") is not True:
                    continue
                identity = predicted.get("cacheIdentitySha256")
                if not isinstance(identity, str) or not _SHA256.fullmatch(identity):
                    protect_all = True
                else:
                    protected.add(identity)
            connection.commit()
            return {
                "protectedCacheIdentitySha256s": tuple(sorted(protected)),
                "protectAll": protect_all,
            }
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def invalidate_cache_for_retry(
        self,
        parent_job_id: str,
        *,
        blocks: Iterable[tuple[int, int]],
        cache_identity_sha256: str,
        typed_failure: str,
        task_id: str | None = None,
        worker_id: str | None = None,
        lease_token: str | None = None,
        now: float | None = None,
    ) -> tuple[BuildingTaskRecord, ...]:
        """Atomically discard stale cache receipts and requeue their tasks."""

        if not isinstance(parent_job_id, str) or not parent_job_id:
            raise BuildingTaskStoreError("parent job ID is required")
        _require_sha(cache_identity_sha256, "cache_identity_sha256")
        if not isinstance(typed_failure, str) or not typed_failure:
            raise BuildingTaskStoreError("typed failure is required")
        requested_blocks = tuple(sorted(set(blocks)))
        if not requested_blocks:
            raise BuildingTaskStoreError("cache invalidation requires blocks")
        for block in requested_blocks:
            _validate_block(block)
        if task_id is not None and (not worker_id or not lease_token):
            raise BuildingTaskStoreError(
                "leased cache invalidation requires worker and lease"
            )
        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            plan = connection.execute(
                "SELECT state FROM map_build_plans WHERE parent_job_id=?",
                (parent_job_id,),
            ).fetchone()
            if plan is None:
                raise BuildingTaskStoreError("parent plan not found")
            if plan["state"] in _TERMINAL_PLAN_STATES:
                raise BuildingTaskStoreError("parent plan is terminal")
            current_task = None
            if task_id is not None:
                current_task = self._locked_task(
                    connection,
                    task_id,
                    str(worker_id),
                    str(lease_token),
                    now=now,
                )
                if current_task.parent_job_id != parent_job_id:
                    raise BuildingTaskStoreError("cache task parent mismatch")

            requested = set(requested_blocks)
            ownership_rows = connection.execute(
                """
                SELECT task_id, block_x, block_y
                FROM map_build_task_blocks
                WHERE parent_job_id=?
                """,
                (parent_job_id,),
            ).fetchall()
            affected_task_ids = {
                str(row["task_id"])
                for row in ownership_rows
                if (int(row["block_x"]), int(row["block_y"])) in requested
            }
            if not affected_task_ids:
                raise BuildingTaskStoreError(
                    "cache invalidation blocks are not assigned"
                )
            if task_id is not None and task_id not in affected_task_ids:
                raise BuildingTaskStoreError(
                    "cache invalidation task does not own requested blocks"
                )
            placeholders = ",".join("?" for _ in affected_task_ids)
            rows = connection.execute(
                f"SELECT * FROM map_build_tasks WHERE task_id IN ({placeholders}) ORDER BY task_id",
                tuple(sorted(affected_task_ids)),
            ).fetchall()
            for row in rows:
                if row["state"] == "leased" and row["task_id"] != task_id:
                    raise StaleLeaseError(
                        "another worker owns an affected cache task"
                    )
                if row["kind"] not in {
                    "building_chunk",
                    "building_workload_scan",
                }:
                    raise BuildingTaskStoreError(
                        "cache invalidation found an unsupported task"
                    )

            connection.execute(
                f"DELETE FROM map_build_block_receipts WHERE task_id IN ({placeholders})",
                tuple(sorted(affected_task_ids)),
            )
            for row in rows:
                try:
                    predicted = json.loads(row["predicted_resource_json"] or "{}")
                except (TypeError, ValueError, json.JSONDecodeError):
                    predicted = {}
                if not isinstance(predicted, dict):
                    predicted = {}
                predicted.pop("cacheHit", None)
                predicted.pop("cacheIdentitySha256", None)
                estimate = predicted.get("estimatedPeakMemoryBytes")
                if (
                    isinstance(estimate, bool)
                    or not isinstance(estimate, int)
                    or estimate <= 0
                ):
                    predicted["estimatedPeakMemoryBytes"] = (
                        DEFAULT_UNKNOWN_WORKLOAD_MEMORY_RESERVATION_BYTES
                    )
                    predicted["memoryEstimateSource"] = (
                        CONSERVATIVE_MEMORY_MODEL_VERSION
                    )
                predicted["cacheInvalidatedReason"] = typed_failure
                connection.execute(
                    """
                    UPDATE map_build_tasks
                    SET state='pending', typed_error=?, next_eligible_at=?,
                        output_receipt_set_sha256=NULL,
                        predicted_resource_json=?, lease_owner=NULL,
                        lease_token=NULL, lease_expires_at=NULL,
                        heartbeat_at=NULL, updated_at=?
                    WHERE task_id=?
                    """,
                    (
                        typed_failure,
                        now,
                        _canonical_json(predicted).decode("utf-8"),
                        now,
                        row["task_id"],
                    ),
                )
            connection.execute(
                f"DELETE FROM map_build_resource_reservations WHERE task_id IN ({placeholders})",
                tuple(sorted(affected_task_ids)),
            )
            if current_task is not None:
                self._finish_attempt(
                    connection,
                    current_task.task_id,
                    current_task.transient_attempts,
                    outcome="cache_invalidated",
                    typed_failure=typed_failure,
                    now=now,
                )
            connection.execute(
                """
                UPDATE map_build_plans
                SET stage='building_chunks', state='building_chunks', updated_at=?
                WHERE parent_job_id=?
                """,
                (now, parent_job_id),
            )
            updated_rows = connection.execute(
                f"SELECT * FROM map_build_tasks WHERE task_id IN ({placeholders}) ORDER BY task_id",
                tuple(sorted(affected_task_ids)),
            ).fetchall()
            connection.commit()
            return tuple(self._row_to_task(row) for row in updated_rows)
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def receipt_set_sha256(self, parent_job_id: str) -> str | None:
        """Return the partition-invariant identity of a complete receipt set."""

        connection = self._connect()
        try:
            plan = connection.execute(
                "SELECT expected_output_block_count FROM map_build_plans WHERE parent_job_id=?",
                (parent_job_id,),
            ).fetchone()
            if plan is None:
                return None
            rows = connection.execute(
                """
                SELECT block_x, block_y, cache_identity_sha256, content_sha256
                FROM map_build_block_receipts
                WHERE parent_job_id=?
                ORDER BY block_x, block_y
                """,
                (parent_job_id,),
            ).fetchall()
            if len(rows) != int(plan["expected_output_block_count"]):
                return None
            return hashlib.sha256(
                _canonical_json(
                    [
                        [
                            int(row["block_x"]),
                            int(row["block_y"]),
                            row["cache_identity_sha256"],
                            row["content_sha256"],
                        ]
                        for row in rows
                    ]
                )
            ).hexdigest()
        finally:
            connection.close()

    def list_workload_receipts(self, parent_job_id: str) -> tuple[dict[str, Any], ...]:
        connection = self._connect()
        try:
            return tuple(
                dict(row)
                for row in connection.execute(
                    """
                    SELECT * FROM map_build_workload_receipts
                    WHERE parent_job_id=? ORDER BY recorded_at, task_id
                    """,
                    (parent_job_id,),
                ).fetchall()
            )
        finally:
            connection.close()

    def workload_receipt(self, task_id: str) -> dict[str, Any] | None:
        """Return one validated durable workload receipt by task identity."""

        connection = self._connect()
        try:
            row = connection.execute(
                "SELECT workload_json FROM map_build_workload_receipts WHERE task_id=?",
                (task_id,),
            ).fetchone()
            if row is None:
                return None
            value = json.loads(row["workload_json"])
            return _validate_workload_receipt(value)
        except (TypeError, ValueError, json.JSONDecodeError) as exc:
            raise BuildingTaskStoreError(
                "stored workload receipt is invalid"
            ) from exc
        finally:
            connection.close()

    def prune_terminal_evidence(
        self,
        *,
        older_than_days: int = DEFAULT_BUILDING_TASK_RETENTION_DAYS,
        max_plans: int = 100,
        now: float | None = None,
    ) -> dict[str, int]:
        """Bound failed/cancelled coordinator history without touching caches.

        Successful plans and all canonical block receipts remain available for
        calibration and operator diagnostics.  Only terminal failed/cancelled
        plans older than the retention window are removed, and a candidate is
        skipped if a lease or reservation is still present.  The external
        building-block cache is deliberately outside this transaction and is
        retained by its own lease-aware cache policy.
        """

        if (
            isinstance(older_than_days, bool)
            or not isinstance(older_than_days, int)
            or older_than_days < 1
            or isinstance(max_plans, bool)
            or not isinstance(max_plans, int)
            or max_plans < 1
        ):
            raise ValueError("building task retention settings are invalid")
        current_time = self._clock() if now is None else now
        cutoff = current_time - older_than_days * 86_400
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            self._recover_expired_locked(connection, now=current_time)
            candidates = connection.execute(
                """
                SELECT parent_job_id
                FROM map_build_plans
                WHERE state IN ('observed', 'failed', 'cancelled') AND updated_at < ?
                ORDER BY updated_at, parent_job_id
                LIMIT ?
                """,
                (cutoff, max_plans),
            ).fetchall()
            removed_plans = 0
            removed_tasks = 0
            removed_attempts = 0
            skipped_active = 0
            for candidate in candidates:
                parent_job_id = candidate["parent_job_id"]
                active = connection.execute(
                    """
                    SELECT 1 FROM (
                        SELECT tasks.parent_job_id
                        FROM map_build_tasks AS tasks
                        LEFT JOIN map_build_resource_reservations AS reservations
                          ON reservations.task_id = tasks.task_id
                        WHERE tasks.parent_job_id=?
                          AND (tasks.state='leased' OR reservations.task_id IS NOT NULL)
                        UNION ALL
                        SELECT parent_job_id
                        FROM map_build_parent_phase_reservations
                        WHERE parent_job_id=?
                    )
                    LIMIT 1
                    """,
                    (parent_job_id, parent_job_id),
                ).fetchone()
                if active is not None:
                    skipped_active += 1
                    continue
                task_ids = [
                    row["task_id"]
                    for row in connection.execute(
                        "SELECT task_id FROM map_build_tasks WHERE parent_job_id=?",
                        (parent_job_id,),
                    ).fetchall()
                ]
                if task_ids:
                    placeholders = ",".join("?" for _ in task_ids)
                    attempt_count = connection.execute(
                        f"SELECT COUNT(*) FROM map_build_task_attempts WHERE task_id IN ({placeholders})",
                        task_ids,
                    ).fetchone()[0]
                    connection.execute(
                        f"DELETE FROM map_build_resource_reservations WHERE task_id IN ({placeholders})",
                        task_ids,
                    )
                    connection.execute(
                        f"DELETE FROM map_build_workload_receipts WHERE task_id IN ({placeholders})",
                        task_ids,
                    )
                    connection.execute(
                        f"DELETE FROM map_build_block_receipts WHERE task_id IN ({placeholders})",
                        task_ids,
                    )
                    connection.execute(
                        f"DELETE FROM map_build_task_attempts WHERE task_id IN ({placeholders})",
                        task_ids,
                    )
                    connection.execute(
                        f"DELETE FROM map_build_task_blocks WHERE task_id IN ({placeholders})",
                        task_ids,
                    )
                    connection.execute(
                        f"DELETE FROM map_build_tasks WHERE task_id IN ({placeholders})",
                        task_ids,
                    )
                connection.execute(
                    "DELETE FROM map_build_parent_phase_reservations WHERE parent_job_id=?",
                    (parent_job_id,),
                )
                connection.execute(
                    "DELETE FROM map_build_plans WHERE parent_job_id=?",
                    (parent_job_id,),
                )
                removed_plans += 1
                removed_tasks += len(task_ids)
                removed_attempts += int(attempt_count if task_ids else 0)
            connection.commit()
            return {
                "removedPlans": removed_plans,
                "removedTasks": removed_tasks,
                "removedAttempts": removed_attempts,
                "skippedActive": skipped_active,
            }
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def list_attempts(self, parent_job_id: str) -> tuple[dict[str, Any], ...]:
        connection = self._connect()
        try:
            return tuple(
                dict(row)
                for row in connection.execute(
                    """
                    SELECT attempts.*, tasks.parent_job_id, tasks.kind
                    FROM map_build_task_attempts attempts
                    JOIN map_build_tasks tasks ON tasks.task_id = attempts.task_id
                    WHERE tasks.parent_job_id=?
                    ORDER BY attempts.started_at, attempts.task_id, attempts.attempt_number
                    """,
                    (parent_job_id,),
                ).fetchall()
            )
        finally:
            connection.close()

    def resource_model_observations(
        self, parent_job_id: str | None = None
    ) -> tuple[dict[str, Any], ...]:
        """Return successful, identity-bound observations for model review."""

        connection = self._connect()
        try:
            where = [
                "attempts.outcome='ready'",
                # Cache-only children record zero work rather than a measured
                # worker peak; they must not train the execution model.
                "attempts.peak_rss_bytes IS NOT NULL",
                "attempts.peak_rss_bytes > 0",
            ]
            params: list[Any] = []
            if parent_job_id is not None:
                where.append("tasks.parent_job_id=?")
                params.append(parent_job_id)
            rows = connection.execute(
                f"""
                SELECT attempts.task_id, attempts.peak_rss_bytes,
                       attempts.worker_capability_json,
                       tasks.parent_job_id, tasks.predicted_resource_json,
                       plans.resource_model_version
                FROM map_build_task_attempts attempts
                JOIN map_build_tasks tasks ON tasks.task_id=attempts.task_id
                JOIN map_build_plans plans ON plans.parent_job_id=tasks.parent_job_id
                WHERE {' AND '.join(where)}
                ORDER BY attempts.started_at, attempts.task_id, attempts.attempt_number
                """,
                params,
            ).fetchall()
            observations: list[dict[str, Any]] = []
            for row in rows:
                try:
                    capability_document = json.loads(
                        row["worker_capability_json"]
                    )
                    predicted_document = json.loads(
                        row["predicted_resource_json"] or "{}"
                    )
                except (TypeError, ValueError):
                    continue
                if not isinstance(capability_document, dict):
                    continue
                capability = capability_document.get("capability", {})
                if not isinstance(capability, dict):
                    continue
                if not isinstance(predicted_document, dict):
                    continue
                predicted = predicted_document.get("estimatedPeakMemoryBytes")
                actual = row["peak_rss_bytes"]
                if (
                    isinstance(predicted, bool)
                    or not isinstance(predicted, int)
                    or predicted < 0
                    or isinstance(actual, bool)
                    or not isinstance(actual, int)
                    or actual < 0
                ):
                    continue
                observations.append(
                    {
                        "taskId": row["task_id"],
                        "parentJobId": row["parent_job_id"],
                        "resourceModelVersion": row["resource_model_version"],
                        "workerCapability": capability,
                        "predictedPeakMemoryBytes": predicted,
                        "actualPeakMemoryBytes": actual,
                    }
                )
            return tuple(observations)
        finally:
            connection.close()

    def resource_model_summary(
        self,
        parent_job_id: str | None = None,
        *,
        minimum_observations: int = 8,
    ) -> dict[str, Any]:
        return summarize_resource_observations(
            self.resource_model_observations(parent_job_id),
            minimum_observations=minimum_observations,
        )

    def list_resource_reservations(
        self, parent_job_id: str | None = None
    ) -> tuple[dict[str, Any], ...]:
        connection = self._connect()
        try:
            if parent_job_id is None:
                rows = connection.execute(
                    "SELECT * FROM map_build_resource_reservations ORDER BY reserved_at, task_id"
                ).fetchall()
            else:
                rows = connection.execute(
                    "SELECT * FROM map_build_resource_reservations WHERE parent_job_id=? ORDER BY reserved_at, task_id",
                    (parent_job_id,),
                ).fetchall()
            return tuple(dict(row) for row in rows)
        finally:
            connection.close()

    def list_parent_phase_reservations(
        self, parent_job_id: str | None = None
    ) -> tuple[dict[str, Any], ...]:
        connection = self._connect()
        try:
            if parent_job_id is None:
                rows = connection.execute(
                    "SELECT * FROM map_build_parent_phase_reservations "
                    "ORDER BY reserved_at, parent_job_id, phase"
                ).fetchall()
            else:
                rows = connection.execute(
                    "SELECT * FROM map_build_parent_phase_reservations "
                    "WHERE parent_job_id=? "
                    "ORDER BY reserved_at, parent_job_id, phase",
                    (parent_job_id,),
                ).fetchall()
            return tuple(dict(row) for row in rows)
        finally:
            connection.close()

    def diagnostic_page(
        self,
        parent_job_id: str,
        *,
        limit: int = 100,
        offset: int = 0,
    ) -> dict[str, Any]:
        """Return bounded operator diagnostics without large workload JSON.

        Exact workload documents can contain hundreds of thousands of object
        keys. They remain durable in SQLite for execution/audit, while this
        ordinary API/CLI surface returns only identity and byte-count metadata.
        """

        if (
            isinstance(limit, bool)
            or not isinstance(limit, int)
            or not 1 <= limit <= 100
            or isinstance(offset, bool)
            or not isinstance(offset, int)
            or offset < 0
        ):
            raise ValueError("diagnostic page limit/offset is invalid")
        connection = self._connect()
        try:
            if connection.execute(
                "SELECT 1 FROM map_build_plans WHERE parent_job_id=?",
                (parent_job_id,),
            ).fetchone() is None:
                raise BuildingTaskStoreError("parent plan not found")

            def count(table: str, where: str = "parent_job_id=?") -> int:
                return int(
                    connection.execute(
                        f"SELECT COUNT(*) FROM {table} WHERE {where}",
                        (parent_job_id,),
                    ).fetchone()[0]
                )

            tasks = tuple(
                self._row_to_task(row)
                for row in connection.execute(
                    "SELECT * FROM map_build_tasks WHERE parent_job_id=? ORDER BY created_at, task_id LIMIT ? OFFSET ?",
                    (parent_job_id, limit, offset),
                ).fetchall()
            )
            workload_receipts = tuple(
                dict(row)
                for row in connection.execute(
                    """
                    SELECT task_id, parent_job_id, closure_plan_sha256,
                           source_index_identity_json,
                           length(CAST(workload_json AS BLOB)) AS workload_bytes,
                           recorded_at
                    FROM map_build_workload_receipts
                    WHERE parent_job_id=?
                    ORDER BY recorded_at, task_id
                    LIMIT ? OFFSET ?
                    """,
                    (parent_job_id, limit, offset),
                ).fetchall()
            )
            receipts = tuple(
                dict(row)
                for row in connection.execute(
                    "SELECT * FROM map_build_block_receipts WHERE parent_job_id=? ORDER BY block_x, block_y LIMIT ? OFFSET ?",
                    (parent_job_id, limit, offset),
                ).fetchall()
            )
            attempts = tuple(
                dict(row)
                for row in connection.execute(
                    """
                    SELECT attempts.*, tasks.parent_job_id, tasks.kind
                    FROM map_build_task_attempts attempts
                    JOIN map_build_tasks tasks ON tasks.task_id=attempts.task_id
                    WHERE tasks.parent_job_id=?
                    ORDER BY attempts.started_at, attempts.task_id,
                             attempts.attempt_number
                    LIMIT ? OFFSET ?
                    """,
                    (parent_job_id, limit, offset),
                ).fetchall()
            )
            reservations = tuple(
                dict(row)
                for row in connection.execute(
                    "SELECT * FROM map_build_resource_reservations WHERE parent_job_id=? ORDER BY reserved_at, task_id LIMIT ? OFFSET ?",
                    (parent_job_id, limit, offset),
                ).fetchall()
            )
            parent_phase_reservations = tuple(
                dict(row)
                for row in connection.execute(
                    "SELECT * FROM map_build_parent_phase_reservations "
                    "WHERE parent_job_id=? "
                    "ORDER BY reserved_at, phase LIMIT ? OFFSET ?",
                    (parent_job_id, limit, offset),
                ).fetchall()
            )
            counts = {
                "tasks": count("map_build_tasks"),
                "workloadReceipts": count("map_build_workload_receipts"),
                "receipts": count("map_build_block_receipts"),
                "attempts": count(
                    "map_build_task_attempts",
                    "task_id IN (SELECT task_id FROM map_build_tasks WHERE parent_job_id=?)",
                ),
                "resourceReservations": count("map_build_resource_reservations"),
                "parentPhaseReservations": count(
                    "map_build_parent_phase_reservations"
                ),
            }
            return {
                "limit": limit,
                "offset": offset,
                "counts": counts,
                "tasks": tasks,
                "workloadReceipts": workload_receipts,
                "receipts": receipts,
                "attempts": attempts,
                "resourceReservations": reservations,
                "parentPhaseReservations": parent_phase_reservations,
                "hasMore": any(offset + limit < value for value in counts.values()),
            }
        finally:
            connection.close()

    def get_plan(self, parent_job_id: str) -> dict[str, Any] | None:
        connection = self._connect()
        try:
            row = connection.execute(
                "SELECT * FROM map_build_plans WHERE parent_job_id=?", (parent_job_id,)
            ).fetchone()
            return dict(row) if row is not None else None
        finally:
            connection.close()

    def progress(self, parent_job_id: str) -> dict[str, Any] | None:
        """Return additive parent-facing progress from validated receipts."""

        connection = self._connect()
        try:
            plan = connection.execute(
                "SELECT stage, state, expected_output_block_count FROM map_build_plans WHERE parent_job_id=?",
                (parent_job_id,),
            ).fetchone()
            if plan is None:
                return None
            completed_blocks = int(
                connection.execute(
                    "SELECT COUNT(*) FROM map_build_block_receipts WHERE parent_job_id=?",
                    (parent_job_id,),
                ).fetchone()[0]
            )
            task_counts = connection.execute(
                """
                SELECT
                    SUM(CASE WHEN state='leased' THEN 1 ELSE 0 END) AS active_chunks,
                    SUM(CASE WHEN state='ready' THEN 1 ELSE 0 END) AS ready_chunks,
                    SUM(CASE WHEN state NOT IN ('split', 'cancelled') THEN 1 ELSE 0 END) AS total_chunks
                FROM map_build_tasks
                WHERE parent_job_id=? AND kind IN ('building_chunk', 'building_workload_scan')
                """,
                (parent_job_id,),
            ).fetchone()
            expected = int(plan["expected_output_block_count"])
            return {
                "phase": plan["stage"],
                "unit": "blocks",
                "completed": min(completed_blocks, expected),
                "total": expected,
                "completedBlocks": min(completed_blocks, expected),
                "totalBlocks": expected,
                "activeChunks": int(task_counts["active_chunks"] or 0),
                "readyChunks": int(task_counts["ready_chunks"] or 0),
                "totalChunks": int(task_counts["total_chunks"] or 0),
                "indeterminate": False,
                "state": plan["state"],
            }
        finally:
            connection.close()

    def _finish_task(
        self,
        task_id: str,
        *,
        worker_id: str,
        lease_token: str,
        state: str,
        outcome: str,
        typed_failure: str | None = None,
        actual_resource: Mapping[str, Any] | None = None,
        phase_timings: Mapping[str, Any] | None = None,
        peak_rss_bytes: int | None = None,
        now: float | None = None,
        require_receipts: bool,
    ) -> BuildingTaskRecord:
        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            task = self._locked_task(
                connection, task_id, worker_id, lease_token, now=now
            )
            if require_receipts:
                expected = int(connection.execute(
                    "SELECT COUNT(*) FROM map_build_task_blocks WHERE task_id=?", (task_id,)
                ).fetchone()[0])
                actual = int(connection.execute(
                    """
                    SELECT COUNT(*)
                    FROM map_build_task_blocks blocks
                    JOIN map_build_block_receipts receipts
                      ON receipts.parent_job_id = blocks.parent_job_id
                     AND receipts.block_x = blocks.block_x
                     AND receipts.block_y = blocks.block_y
                    WHERE blocks.task_id=?
                    """,
                    (task_id,),
                ).fetchone()[0])
                if expected != actual:
                    raise BuildingTaskStoreError("task cannot become ready without all block receipts")
            connection.execute(
                "UPDATE map_build_tasks SET state=?, typed_error=?, lease_owner=NULL, lease_token=NULL, lease_expires_at=NULL, heartbeat_at=NULL, updated_at=? WHERE task_id=?",
                (state, typed_failure, now, task_id),
            )
            receipt_set_sha256 = None
            if require_receipts:
                receipt_rows = connection.execute(
                    """
                    SELECT blocks.block_x, blocks.block_y,
                           receipts.cache_identity_sha256, receipts.content_sha256
                    FROM map_build_task_blocks blocks
                    JOIN map_build_block_receipts receipts
                      ON receipts.parent_job_id = blocks.parent_job_id
                     AND receipts.block_x = blocks.block_x
                     AND receipts.block_y = blocks.block_y
                    WHERE blocks.task_id=?
                    ORDER BY blocks.block_x, blocks.block_y
                    """,
                    (task_id,),
                ).fetchall()
                receipt_set_sha256 = hashlib.sha256(
                    _canonical_json(
                        [
                            [
                                int(row["block_x"]),
                                int(row["block_y"]),
                                row["cache_identity_sha256"],
                                row["content_sha256"],
                            ]
                            for row in receipt_rows
                        ]
                    )
                ).hexdigest()
            connection.execute(
                "UPDATE map_build_tasks SET output_receipt_set_sha256=? WHERE task_id=?",
                (receipt_set_sha256, task_id),
            )
            connection.execute(
                "DELETE FROM map_build_resource_reservations WHERE task_id=? AND lease_token=?",
                (task_id, lease_token),
            )
            self._finish_attempt(
                connection,
                task_id,
                task.transient_attempts,
                outcome=outcome,
                typed_failure=typed_failure,
                actual_resource=actual_resource,
                phase_timings=phase_timings,
                peak_rss_bytes=peak_rss_bytes,
                now=now,
            )
            connection.commit()
            return self._row_to_task(
                connection.execute(
                    "SELECT * FROM map_build_tasks WHERE task_id=?", (task_id,)
                ).fetchone()
            )
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def _locked_task(
        self,
        connection: sqlite3.Connection,
        task_id: str,
        worker_id: str,
        lease_token: str,
        *,
        now: float | None = None,
    ) -> BuildingTaskRecord:
        row = connection.execute(
            "SELECT * FROM map_build_tasks WHERE task_id=?", (task_id,)
        ).fetchone()
        if row is None or row["state"] != "leased" or row["lease_owner"] != worker_id or row["lease_token"] != lease_token:
            raise StaleLeaseError("task lease is no longer valid")
        checked_at = self._clock() if now is None else now
        if (
            row["lease_expires_at"] is None
            or float(row["lease_expires_at"]) <= checked_at
        ):
            raise StaleLeaseError("task lease has expired")
        plan = connection.execute(
            "SELECT state FROM map_build_plans WHERE parent_job_id=?",
            (row["parent_job_id"],),
        ).fetchone()
        if plan is None or plan["state"] in _TERMINAL_PLAN_STATES:
            raise StaleLeaseError("parent plan is no longer active")
        return self._row_to_task(row)

    def _recover_expired_locked(
        self,
        connection: sqlite3.Connection,
        *,
        now: float,
    ) -> int:
        expired_parent_phases = connection.execute(
            "DELETE FROM map_build_parent_phase_reservations WHERE expires_at <= ?",
            (now,),
        ).rowcount
        rows = connection.execute(
            "SELECT task_id, parent_job_id, transient_attempts FROM map_build_tasks WHERE state='leased' AND lease_expires_at IS NOT NULL AND lease_expires_at <= ?",
            (now,),
        ).fetchall()
        for row in rows:
            plan = connection.execute(
                "SELECT state FROM map_build_plans WHERE parent_job_id=?",
                (row["parent_job_id"],),
            ).fetchone()
            new_state = (
                "cancelled"
                if plan is not None and plan["state"] in _TERMINAL_PLAN_STATES
                else "pending"
            )
            connection.execute(
                "UPDATE map_build_tasks SET state=?, lease_owner=NULL, lease_token=NULL, lease_expires_at=NULL, heartbeat_at=NULL, updated_at=? WHERE task_id=?",
                (new_state, now, row["task_id"]),
            )
            connection.execute(
                "DELETE FROM map_build_resource_reservations WHERE task_id=?",
                (row["task_id"],),
            )
            self._finish_attempt(
                connection,
                row["task_id"],
                row["transient_attempts"],
                outcome="lease_expired",
                typed_failure="building_task_lease_expired",
                now=now,
            )
        return len(rows) + max(0, int(expired_parent_phases))

    def _finish_attempt(
        self,
        connection: sqlite3.Connection,
        task_id: str,
        attempt_number: int,
        *,
        outcome: str,
        typed_failure: str | None = None,
        actual_resource: Mapping[str, Any] | None = None,
        phase_timings: Mapping[str, Any] | None = None,
        peak_rss_bytes: int | None = None,
        now: float,
    ) -> None:
        connection.execute(
            """
            UPDATE map_build_task_attempts
            SET finished_at=?, outcome=?, actual_resource_json=?,
                phase_timings_json=?, peak_rss_bytes=?, typed_failure=?
            WHERE task_id=? AND attempt_number=?
            """,
            (
                now,
                outcome,
                _json_or_none(actual_resource),
                _json_or_none(phase_timings),
                peak_rss_bytes,
                typed_failure,
                task_id,
                attempt_number,
            ),
        )

    def _insert_task(self, connection: sqlite3.Connection, spec: BuildingTaskSpec) -> None:
        if not spec.task_id or not spec.parent_job_id or not spec.kind:
            raise BuildingTaskStoreError("task identity is incomplete")
        _require_sha(spec.chunk_plan_sha256, "chunk_plan_sha256")
        if spec.closure_plan_sha256 is not None:
            _require_sha(spec.closure_plan_sha256, "closure_plan_sha256")
        if not spec.blocks:
            raise BuildingTaskStoreError("task must own at least one block")
        normalized_blocks = tuple(sorted(set(spec.blocks)))
        if len(normalized_blocks) != len(spec.blocks):
            raise BuildingTaskStoreError("task block set contains duplicates")
        for block in normalized_blocks:
            _validate_block(block)
        if spec.split_depth < 0:
            raise BuildingTaskStoreError("task split depth is invalid")
        now = self._clock()
        predicted = _json_or_none(spec.predicted_resource)
        connection.execute(
            """
            INSERT INTO map_build_tasks(
                task_id, parent_job_id, kind, blocks_json, chunk_plan_sha256,
                closure_plan_sha256, state, split_depth, transient_attempts,
                lease_owner, lease_token, lease_expires_at, heartbeat_at,
                typed_error, next_eligible_at, output_receipt_set_sha256,
                predicted_resource_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?, ?, ?)
            """,
            (
                spec.task_id,
                spec.parent_job_id,
                spec.kind,
                _canonical_json([[x, y] for x, y in normalized_blocks]).decode("utf-8"),
                spec.chunk_plan_sha256,
                spec.closure_plan_sha256,
                spec.split_depth,
                predicted,
                now,
                now,
            ),
        )
        for x, y in normalized_blocks:
            connection.execute(
                "INSERT INTO map_build_task_blocks(parent_job_id, block_x, block_y, task_id) VALUES (?, ?, ?, ?)",
                (spec.parent_job_id, x, y, spec.task_id),
            )

    def _validate_existing_task(
        self,
        row: sqlite3.Row,
        spec: BuildingTaskSpec,
    ) -> None:
        normalized_blocks = tuple(sorted(set(spec.blocks)))
        expected_blocks = _canonical_json(
            [[x, y] for x, y in normalized_blocks]
        ).decode("utf-8")
        if (
            row["parent_job_id"] != spec.parent_job_id
            or row["kind"] != spec.kind
            or row["blocks_json"] != expected_blocks
            or row["chunk_plan_sha256"] != spec.chunk_plan_sha256
            or row["closure_plan_sha256"] != spec.closure_plan_sha256
            or row["split_depth"] != spec.split_depth
        ):
            raise BuildingTaskStoreError("task identity changed")

    def _row_to_task(self, row: sqlite3.Row) -> BuildingTaskRecord:
        return BuildingTaskRecord(
            task_id=row["task_id"],
            parent_job_id=row["parent_job_id"],
            kind=row["kind"],
            blocks=tuple(tuple(value) for value in json.loads(row["blocks_json"])),
            chunk_plan_sha256=row["chunk_plan_sha256"],
            closure_plan_sha256=row["closure_plan_sha256"],
            state=row["state"],
            split_depth=row["split_depth"],
            transient_attempts=row["transient_attempts"],
            lease_owner=row["lease_owner"],
            lease_token=row["lease_token"],
            lease_expires_at=row["lease_expires_at"],
            heartbeat_at=row["heartbeat_at"],
            typed_error=row["typed_error"],
            next_eligible_at=row["next_eligible_at"],
            output_receipt_set_sha256=row["output_receipt_set_sha256"],
            predicted_resource=(
                json.loads(row["predicted_resource_json"])
                if row["predicted_resource_json"]
                else None
            ),
        )

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5.0)
        connection.execute("PRAGMA busy_timeout=5000")
        connection.execute("PRAGMA foreign_keys=ON")
        connection.row_factory = sqlite3.Row
        return connection

    def _initialize(self) -> None:
        connection = self._connect()
        try:
            # SQLite does not consistently honor busy_timeout while changing
            # journal mode. API, worker, and maintenance may all open the same
            # freshly upgraded store, so retry only this idempotent lock race.
            for attempt in range(100):
                try:
                    connection.execute("PRAGMA journal_mode=WAL")
                    break
                except sqlite3.OperationalError as exc:
                    if "locked" not in str(exc).lower() or attempt == 99:
                        raise
                    time.sleep(0.01)
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS map_build_plans(
                    parent_job_id TEXT PRIMARY KEY,
                    global_plan_sha256 TEXT NOT NULL,
                    input_identity_json TEXT NOT NULL,
                    stage TEXT NOT NULL,
                    state TEXT NOT NULL,
                    expected_output_block_count INTEGER NOT NULL,
                    policy_version INTEGER NOT NULL,
                    resource_model_version TEXT NOT NULL,
                    cancellation_generation INTEGER NOT NULL,
                    scheduling_weight INTEGER NOT NULL DEFAULT 1,
                    admission_priority INTEGER NOT NULL DEFAULT 0,
                    active_task_quota INTEGER,
                    virtual_finish REAL NOT NULL DEFAULT 0,
                    last_claimed_at REAL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS map_build_tasks(
                    task_id TEXT PRIMARY KEY,
                    parent_job_id TEXT NOT NULL REFERENCES map_build_plans(parent_job_id),
                    kind TEXT NOT NULL,
                    blocks_json TEXT NOT NULL,
                    chunk_plan_sha256 TEXT NOT NULL,
                    closure_plan_sha256 TEXT,
                    state TEXT NOT NULL,
                    split_depth INTEGER NOT NULL,
                    transient_attempts INTEGER NOT NULL,
                    lease_owner TEXT,
                    lease_token TEXT,
                    lease_expires_at REAL,
                    heartbeat_at REAL,
                    typed_error TEXT,
                    next_eligible_at REAL,
                    output_receipt_set_sha256 TEXT,
                    predicted_resource_json TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS map_build_task_blocks(
                    parent_job_id TEXT NOT NULL REFERENCES map_build_plans(parent_job_id),
                    block_x INTEGER NOT NULL,
                    block_y INTEGER NOT NULL,
                    task_id TEXT NOT NULL REFERENCES map_build_tasks(task_id),
                    PRIMARY KEY(parent_job_id, block_x, block_y)
                );
                CREATE TABLE IF NOT EXISTS map_build_block_receipts(
                    parent_job_id TEXT NOT NULL REFERENCES map_build_plans(parent_job_id),
                    task_id TEXT NOT NULL REFERENCES map_build_tasks(task_id),
                    block_x INTEGER NOT NULL,
                    block_y INTEGER NOT NULL,
                    cache_identity_sha256 TEXT NOT NULL,
                    content_sha256 TEXT NOT NULL,
                    producer_identity_json TEXT NOT NULL,
                    validation_json TEXT NOT NULL,
                    published_at REAL NOT NULL,
                    PRIMARY KEY(parent_job_id, block_x, block_y)
                );
                CREATE TABLE IF NOT EXISTS map_build_task_attempts(
                    task_id TEXT NOT NULL REFERENCES map_build_tasks(task_id),
                    attempt_number INTEGER NOT NULL,
                    worker_capability_json TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    finished_at REAL,
                    outcome TEXT NOT NULL,
                    predicted_resource_json TEXT,
                    actual_resource_json TEXT,
                    phase_timings_json TEXT,
                    peak_rss_bytes INTEGER,
                    typed_failure TEXT,
                    PRIMARY KEY(task_id, attempt_number)
                );
                CREATE TABLE IF NOT EXISTS map_build_workload_receipts(
                    task_id TEXT PRIMARY KEY REFERENCES map_build_tasks(task_id),
                    parent_job_id TEXT NOT NULL REFERENCES map_build_plans(parent_job_id),
                    closure_plan_sha256 TEXT NOT NULL,
                    source_index_identity_json TEXT NOT NULL,
                    workload_json TEXT NOT NULL,
                    recorded_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS map_build_resource_reservations(
                    task_id TEXT PRIMARY KEY REFERENCES map_build_tasks(task_id),
                    parent_job_id TEXT NOT NULL REFERENCES map_build_plans(parent_job_id),
                    lease_token TEXT NOT NULL,
                    worker_id TEXT NOT NULL,
                    resource_pool TEXT NOT NULL,
                    memory_reservation_bytes INTEGER NOT NULL,
                    memory_limit_bytes INTEGER,
                    cpu_weight REAL NOT NULL,
                    cpu_capacity REAL,
                    max_concurrent_tasks INTEGER NOT NULL,
                    capability_json TEXT NOT NULL,
                    reserved_at REAL NOT NULL,
                    expires_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS map_build_parent_phase_reservations(
                    parent_job_id TEXT NOT NULL,
                    phase TEXT NOT NULL,
                    lease_token TEXT NOT NULL,
                    worker_id TEXT NOT NULL,
                    resource_pool TEXT NOT NULL,
                    memory_reservation_bytes INTEGER NOT NULL,
                    memory_limit_bytes INTEGER,
                    cpu_weight REAL NOT NULL,
                    cpu_capacity REAL,
                    max_concurrent_tasks INTEGER NOT NULL,
                    capability_json TEXT NOT NULL,
                    reserved_at REAL NOT NULL,
                    heartbeat_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    PRIMARY KEY(parent_job_id, phase)
                );
                CREATE INDEX IF NOT EXISTS map_build_tasks_pending
                    ON map_build_tasks(state, next_eligible_at, created_at);
                CREATE INDEX IF NOT EXISTS map_build_tasks_parent
                    ON map_build_tasks(parent_job_id, created_at);
                CREATE INDEX IF NOT EXISTS map_build_task_attempts_started
                    ON map_build_task_attempts(started_at);
                CREATE INDEX IF NOT EXISTS map_build_workload_receipts_parent
                    ON map_build_workload_receipts(parent_job_id, recorded_at);
                CREATE INDEX IF NOT EXISTS map_build_resource_reservations_pool
                    ON map_build_resource_reservations(resource_pool, expires_at);
                CREATE INDEX IF NOT EXISTS map_build_parent_phase_reservations_pool
                    ON map_build_parent_phase_reservations(resource_pool, expires_at);
                """
            )
            # sqlite3.executescript() commits any open transaction. Acquire
            # the migration write lock only after the idempotent base schema
            # exists, then re-read the version and columns while serialized.
            connection.execute("BEGIN IMMEDIATE")
            version = int(connection.execute("PRAGMA user_version").fetchone()[0])
            if version > BUILDING_TASK_SCHEMA_VERSION:
                raise BuildingTaskStoreError("unsupported building task schema")
            plan_columns = {
                row["name"]
                for row in connection.execute("PRAGMA table_info(map_build_plans)")
            }
            if "last_claimed_at" not in plan_columns:
                connection.execute(
                    "ALTER TABLE map_build_plans ADD COLUMN last_claimed_at REAL"
                )
            if "scheduling_weight" not in plan_columns:
                connection.execute(
                    "ALTER TABLE map_build_plans ADD COLUMN scheduling_weight INTEGER NOT NULL DEFAULT 1"
                )
            if "admission_priority" not in plan_columns:
                connection.execute(
                    "ALTER TABLE map_build_plans ADD COLUMN admission_priority INTEGER NOT NULL DEFAULT 0"
                )
            if "active_task_quota" not in plan_columns:
                connection.execute(
                    "ALTER TABLE map_build_plans ADD COLUMN active_task_quota INTEGER"
                )
            if "virtual_finish" not in plan_columns:
                connection.execute(
                    "ALTER TABLE map_build_plans ADD COLUMN virtual_finish REAL NOT NULL DEFAULT 0"
                )
            connection.execute(
                """
                CREATE INDEX IF NOT EXISTS map_build_plans_fair_claim
                    ON map_build_plans(last_claimed_at, parent_job_id)
                """
            )
            connection.execute(f"PRAGMA user_version={BUILDING_TASK_SCHEMA_VERSION}")
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()


def _canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def _validate_scheduling_policy(
    *,
    scheduling_weight: int,
    admission_priority: int,
    active_task_quota: int | None,
) -> None:
    if (
        isinstance(scheduling_weight, bool)
        or not isinstance(scheduling_weight, int)
        or not 1 <= scheduling_weight <= 1_000
    ):
        raise BuildingTaskStoreError("scheduling weight is invalid")
    if (
        isinstance(admission_priority, bool)
        or not isinstance(admission_priority, int)
        or not 0 <= admission_priority <= 1_000
    ):
        raise BuildingTaskStoreError("admission priority is invalid")
    if active_task_quota is not None and (
        isinstance(active_task_quota, bool)
        or not isinstance(active_task_quota, int)
        or active_task_quota <= 0
    ):
        raise BuildingTaskStoreError("active task quota is invalid")


def _dispatch_cost(row: sqlite3.Row) -> float:
    """Return a bounded virtual-finish cost for weighted fair dispatch.

    A chunk with more blocks represents more work than a one-block chunk, so
    it advances its parent's virtual finish by that block count.  Callers may
    provide a reviewed ``quotaUnits`` override in the predicted resource
    document, but malformed values fail closed to the deterministic block
    count.  The cost is never zero, which prevents a cache-heavy parent from
    getting an unbounded sequence of claims at the same virtual finish.
    """

    try:
        blocks = json.loads(row["blocks_json"])
        block_count = len(blocks) if isinstance(blocks, list) else 1
    except (TypeError, ValueError, json.JSONDecodeError):
        block_count = 1
    cost = float(max(1, block_count))
    predicted = row["predicted_resource_json"]
    if predicted:
        try:
            document = json.loads(predicted)
        except (TypeError, ValueError, json.JSONDecodeError):
            document = None
        if isinstance(document, dict):
            override = document.get("quotaUnits")
            if (
                isinstance(override, int)
                and not isinstance(override, bool)
                and override > 0
            ):
                cost = float(min(1_000_000, override))
    return cost


def _worker_can_admit(
    row: sqlite3.Row,
    worker_capability: Mapping[str, Any] | None,
) -> bool:
    if worker_capability is None:
        return True
    if not isinstance(worker_capability, Mapping):
        raise BuildingTaskStoreError("worker capability is invalid")
    if not {
        "memoryLimitBytes",
        "configuredMemoryLimitBytes",
        "cgroupMemoryLimitBytes",
        "cgroupMemory",
        "cpuCount",
        "cpuCapacity",
        "maxConcurrentTasks",
        "resourcePool",
    }.intersection(worker_capability):
        return True
    return _resource_request(row, worker_capability) is not None


def _resource_request(
    row: sqlite3.Row,
    worker_capability: Mapping[str, Any] | None,
) -> dict[str, Any] | None:
    """Normalize a worker/task pair into a reservation request.

    A capability without any resource fields keeps the legacy unbounded
    admission behavior. Once a worker reports a resource pool, memory, CPU,
    or concurrency limit, every claimed task consumes a reservation in that
    pool. The default concurrency is intentionally one for this heavy-task
    coordinator.
    """

    if worker_capability is None:
        return None
    if not isinstance(worker_capability, Mapping):
        raise BuildingTaskStoreError("worker capability is invalid")
    resource_fields = {
        "memoryLimitBytes",
        "configuredMemoryLimitBytes",
        "cgroupMemoryLimitBytes",
        "cgroupMemory",
        "cpuCount",
        "cpuCapacity",
        "maxConcurrentTasks",
        "resourcePool",
    }
    if not resource_fields.intersection(worker_capability):
        return None
    limit = _capability_memory_limit(worker_capability)
    predicted = _predicted_memory(row)
    if limit is not None and predicted > _memory_admission_limit(limit):
        return None
    pool = worker_capability.get("resourcePool", _DEFAULT_RESOURCE_POOL)
    if not isinstance(pool, str) or not pool or len(pool) > 128:
        raise BuildingTaskStoreError("worker resource pool is invalid")
    max_concurrent = worker_capability.get(
        "maxConcurrentTasks", _DEFAULT_MAX_CONCURRENT_TASKS
    )
    if (
        isinstance(max_concurrent, bool)
        or not isinstance(max_concurrent, int)
        or max_concurrent <= 0
    ):
        raise BuildingTaskStoreError("worker concurrency capability is invalid")
    cpu_weight = worker_capability.get("cpuWeight", 1.0)
    if isinstance(cpu_weight, bool) or not isinstance(cpu_weight, (int, float)):
        raise BuildingTaskStoreError("worker CPU reservation is invalid")
    if cpu_weight <= 0:
        raise BuildingTaskStoreError("worker CPU reservation is invalid")
    cpu_capacity = worker_capability.get(
        "cpuCapacity", worker_capability.get("cpuCount")
    )
    if cpu_capacity is not None:
        if isinstance(cpu_capacity, bool) or not isinstance(cpu_capacity, (int, float)):
            raise BuildingTaskStoreError("worker CPU capacity is invalid")
        if cpu_capacity <= 0:
            raise BuildingTaskStoreError("worker CPU capacity is invalid")
    return {
        "resourcePool": pool,
        "memoryReservationBytes": predicted,
        "memoryLimitBytes": limit,
        "cpuWeight": float(cpu_weight),
        "cpuCapacity": float(cpu_capacity) if cpu_capacity is not None else None,
        "maxConcurrentTasks": max_concurrent,
    }


def _parent_phase_resource_request(
    worker_capability: Mapping[str, Any] | None,
    *,
    estimated_peak_memory_bytes: int,
) -> tuple[dict[str, Any], dict[str, Any]]:
    if (
        isinstance(estimated_peak_memory_bytes, bool)
        or not isinstance(estimated_peak_memory_bytes, int)
        or estimated_peak_memory_bytes < 0
    ):
        raise BuildingTaskStoreError("parent phase memory estimate is invalid")
    if worker_capability is None:
        effective_capability: dict[str, Any] = {}
    elif isinstance(worker_capability, Mapping):
        effective_capability = dict(worker_capability)
    else:
        raise BuildingTaskStoreError("worker capability is invalid")
    # New parent-phase coordination is always durable. If an older caller has
    # no resource report, it still enters the default concurrency-one pool;
    # reported memory/CPU limits retain the child admission semantics below.
    effective_capability.setdefault("resourcePool", _DEFAULT_RESOURCE_POOL)
    effective_capability["maxConcurrentTasks"] = 1
    request = _resource_request(
        {
            "predicted_resource_json": _canonical_json(
                {"estimatedPeakMemoryBytes": estimated_peak_memory_bytes}
            ).decode("utf-8")
        },
        effective_capability,
    )
    if request is None:
        raise BuildingTaskStoreError(
            "worker capacity cannot admit the parent resource phase"
        )
    return request, effective_capability


def _locked_parent_phase_reservation(
    connection: sqlite3.Connection,
    *,
    parent_job_id: str,
    phase: str,
    worker_id: str,
    lease_token: str,
    now: float,
) -> sqlite3.Row:
    row = connection.execute(
        """
        SELECT * FROM map_build_parent_phase_reservations
        WHERE parent_job_id=? AND phase=?
        """,
        (parent_job_id, phase),
    ).fetchone()
    if (
        row is None
        or row["worker_id"] != worker_id
        or row["lease_token"] != lease_token
    ):
        raise StaleLeaseError("parent resource lease is no longer valid")
    if float(row["expires_at"]) <= now:
        raise StaleLeaseError("parent resource lease has expired")
    return row


def _predicted_memory(row: sqlite3.Row) -> int:
    predicted = row["predicted_resource_json"]
    if not predicted:
        return DEFAULT_UNKNOWN_WORKLOAD_MEMORY_RESERVATION_BYTES
    try:
        document = json.loads(predicted)
    except (TypeError, ValueError) as exc:
        raise BuildingTaskStoreError("task predicted resource is invalid") from exc
    if not isinstance(document, dict):
        raise BuildingTaskStoreError("task predicted resource is invalid")
    estimate = document.get("estimatedPeakMemoryBytes")
    if estimate is None:
        return DEFAULT_UNKNOWN_WORKLOAD_MEMORY_RESERVATION_BYTES
    if isinstance(estimate, bool) or not isinstance(estimate, int) or estimate < 0:
        raise BuildingTaskStoreError("task memory estimate is invalid")
    return estimate


def _resource_capacity_snapshot(
    connection: sqlite3.Connection,
    resource_pool: str,
    *,
    now: float | None = None,
) -> dict[str, Any]:
    where = "resource_pool=?"
    params: list[Any] = [resource_pool]
    if now is not None:
        where += " AND expires_at > ?"
        params.append(now)
    row = connection.execute(
        f"""
        SELECT COUNT(*) AS count,
               COALESCE(SUM(memory_reservation_bytes), 0) AS memory_bytes,
               COALESCE(SUM(cpu_weight), 0) AS cpu_weight,
               MIN(memory_limit_bytes) AS memory_limit_bytes,
               MIN(cpu_capacity) AS cpu_capacity,
               MIN(max_concurrent_tasks) AS max_concurrent_tasks
        FROM (
            SELECT memory_reservation_bytes, memory_limit_bytes, cpu_weight,
                   cpu_capacity, max_concurrent_tasks
            FROM map_build_resource_reservations
            WHERE {where}
            UNION ALL
            SELECT memory_reservation_bytes, memory_limit_bytes, cpu_weight,
                   cpu_capacity, max_concurrent_tasks
            FROM map_build_parent_phase_reservations
            WHERE {where}
        )
        """,
        (*params, *params),
    ).fetchone()
    return {
        "count": int(row["count"] or 0),
        "memoryBytes": int(row["memory_bytes"] or 0),
        "cpuWeight": float(row["cpu_weight"] or 0),
        "memoryLimitBytes": (
            int(row["memory_limit_bytes"])
            if row["memory_limit_bytes"] is not None
            else None
        ),
        "cpuCapacity": (
            float(row["cpu_capacity"])
            if row["cpu_capacity"] is not None
            else None
        ),
        "maxConcurrentTasks": (
            int(row["max_concurrent_tasks"])
            if row["max_concurrent_tasks"] is not None
            else None
        ),
    }


def _active_reservation_parent_ids(
    connection: sqlite3.Connection,
    *,
    resource_pool: str,
    now: float,
) -> set[str]:
    rows = connection.execute(
        """
        SELECT DISTINCT parent_job_id
        FROM (
            SELECT parent_job_id
            FROM map_build_resource_reservations
            WHERE resource_pool=? AND expires_at > ?
            UNION ALL
            SELECT parent_job_id
            FROM map_build_parent_phase_reservations
            WHERE resource_pool=? AND expires_at > ?
        )
        """,
        (resource_pool, now, resource_pool, now),
    ).fetchall()
    return {str(row["parent_job_id"]) for row in rows}


def _resource_capacity_available(
    connection: sqlite3.Connection,
    request: Mapping[str, Any],
    *,
    now: float,
) -> bool:
    active = _resource_capacity_snapshot(
        connection, request["resourcePool"], now=now
    )
    active_concurrency = active["maxConcurrentTasks"]
    effective_concurrency = request["maxConcurrentTasks"]
    if active_concurrency is not None:
        effective_concurrency = min(effective_concurrency, active_concurrency)
    if active["count"] >= effective_concurrency:
        return False
    limits = tuple(
        value
        for value in (
            request["memoryLimitBytes"],
            active["memoryLimitBytes"],
        )
        if value is not None
    )
    limit = min(limits) if limits else None
    if limit is not None:
        if (
            active["memoryBytes"] + request["memoryReservationBytes"]
            > _memory_admission_limit(limit)
        ):
            return False
    capacities = tuple(
        value
        for value in (request["cpuCapacity"], active["cpuCapacity"])
        if value is not None
    )
    capacity = min(capacities) if capacities else None
    if capacity is not None and active["cpuWeight"] + request["cpuWeight"] > capacity:
        return False
    return True


def _resource_admission(
    row: sqlite3.Row,
    worker_capability: Mapping[str, Any] | None,
) -> dict[str, Any]:
    request = _resource_request(row, worker_capability)
    predicted = _predicted_memory(row)
    if request is None:
        return {
            "memoryLimitBytes": _capability_memory_limit(worker_capability or {}),
            "memoryReservationBytes": predicted,
            "memoryHeadroomFraction": _MEMORY_ADMISSION_FRACTION,
            "reservationAccepted": False,
        }
    return {
        "resourcePool": request["resourcePool"],
        "memoryLimitBytes": request["memoryLimitBytes"],
        "memoryReservationBytes": request["memoryReservationBytes"],
        "memoryHeadroomFraction": _MEMORY_ADMISSION_FRACTION,
        "cpuWeight": request["cpuWeight"],
        "cpuCapacity": request["cpuCapacity"],
        "maxConcurrentTasks": request["maxConcurrentTasks"],
        "reservationAccepted": False,
    }


def _memory_admission_limit(limit: int) -> int:
    return (limit * _MEMORY_ADMISSION_PERCENT) // 100


def _capability_memory_limit(capability: Mapping[str, Any]) -> int | None:
    values: list[int] = []
    for field in (
        "memoryLimitBytes",
        "configuredMemoryLimitBytes",
        "cgroupMemoryLimitBytes",
    ):
        value = capability.get(field)
        if value is None:
            continue
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            raise BuildingTaskStoreError("worker memory capability is invalid")
        values.append(value)
    nested = capability.get("cgroupMemory")
    if isinstance(nested, Mapping):
        for field in ("limitBytes", "configuredLimitBytes"):
            value = nested.get(field)
            if value is None:
                continue
            if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
                raise BuildingTaskStoreError("worker memory capability is invalid")
            values.append(value)
    return min(values) if values else None


def _json_or_none(value: Mapping[str, Any] | None) -> str | None:
    return None if value is None else _canonical_json(dict(value)).decode("utf-8")


def _validate_workload_receipt(value: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise BuildingTaskStoreError("workload receipt is invalid")
    receipt = dict(value)
    required_strings = (
        "sourceIndexKey",
        "sourceSnapshotSha256",
        "closurePlanSha256",
    )
    for field in required_strings:
        if not isinstance(receipt.get(field), str) or not _SHA256.fullmatch(
            receipt[field]
        ):
            raise BuildingTaskStoreError(
                f"workload receipt {field} is not a lowercase sha256"
            )
    counters = (
        "relationCount",
        "wayCount",
        "nodeCount",
        "totalObjectCount",
        "storedRelationMemberCount",
        "wayNodeReferenceCount",
        "vertexCount",
        "candidateOutlineCount",
        "candidatePartCount",
    )
    for field in counters:
        counter = receipt.get(field)
        if (
            isinstance(counter, bool)
            or not isinstance(counter, int)
            or counter < 0
        ):
            raise BuildingTaskStoreError(
                f"workload receipt {field} is invalid"
            )
    if receipt["totalObjectCount"] != sum(
        receipt[field] for field in ("relationCount", "wayCount", "nodeCount")
    ):
        raise BuildingTaskStoreError(
            "workload receipt totalObjectCount is inconsistent"
        )
    for field in ("ringCount", "holeCount"):
        counter = receipt.get(field)
        if counter is not None and (
            isinstance(counter, bool)
            or not isinstance(counter, int)
            or counter < 0
        ):
            raise BuildingTaskStoreError(
                f"workload receipt {field} is invalid"
            )
    for field in (
        "candidateKeys",
        "requiredRelationKeys",
        "requiredWayKeys",
        "requiredNodeKeys",
        "calibrationTargetCells",
        "calibrationSampleCells",
    ):
        entries = receipt.get(field)
        if not isinstance(entries, list):
            raise BuildingTaskStoreError(
                f"workload receipt {field} is invalid"
            )
    if receipt["relationCount"] != len(receipt["requiredRelationKeys"]):
        raise BuildingTaskStoreError(
            "workload receipt relation count is inconsistent"
        )
    if receipt["wayCount"] != len(receipt["requiredWayKeys"]):
        raise BuildingTaskStoreError("workload receipt way count is inconsistent")
    if receipt["nodeCount"] != len(receipt["requiredNodeKeys"]):
        raise BuildingTaskStoreError("workload receipt node count is inconsistent")
    return receipt


def _require_sha(value: str, field: str) -> None:
    if not isinstance(value, str) or not _SHA256.fullmatch(value):
        raise BuildingTaskStoreError(f"{field} must be a lowercase sha256")


def _validate_block(block: tuple[int, int]) -> None:
    if (
        not isinstance(block, tuple)
        or len(block) != 2
        or any(isinstance(value, bool) or not isinstance(value, int) for value in block)
    ):
        raise BuildingTaskStoreError("block coordinate is invalid")
