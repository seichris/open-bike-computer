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


BUILDING_TASK_SCHEMA_VERSION = 3
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
    "ready": 7,
    "failed": 7,
    "cancelled": 7,
}
_TERMINAL_PLAN_STATES = {"ready", "failed", "cancelled"}
_MEMORY_ADMISSION_FRACTION = 0.85
_MEMORY_ADMISSION_PERCENT = 85
_DEFAULT_RESOURCE_POOL = "default"
_DEFAULT_MAX_CONCURRENT_TASKS = 1


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
        now = self._clock()
        payload = _canonical_json(dict(input_identity))
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute(
                "SELECT global_plan_sha256, input_identity_json, expected_output_block_count, policy_version, resource_model_version FROM map_build_plans WHERE parent_job_id = ?",
                (parent_job_id,),
            ).fetchone()
            if existing is not None:
                if tuple(existing) != (
                    global_plan_sha256,
                    payload.decode("utf-8"),
                    expected_output_block_count,
                    policy_version,
                    resource_model_version,
                ):
                    raise BuildingTaskStoreError("parent plan identity changed")
            else:
                connection.execute(
                    """
                    INSERT INTO map_build_plans(
                        parent_job_id, global_plan_sha256, input_identity_json,
                        stage, state, expected_output_block_count,
                        policy_version, resource_model_version,
                        cancellation_generation, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
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
            where = [
                "task.state = 'pending'",
                "(task.next_eligible_at IS NULL OR task.next_eligible_at <= ?)",
                "plan.state NOT IN ('cancelled', 'failed', 'ready')",
            ]
            params: list[Any] = [now]
            if parent_job_id is not None:
                where.append("task.parent_job_id = ?")
                params.append(parent_job_id)
            rows = connection.execute(
                f"""
                SELECT task.* FROM map_build_tasks task
                JOIN map_build_plans plan ON plan.parent_job_id = task.parent_job_id
                WHERE {' AND '.join(where)}
                ORDER BY task.parent_job_id, task.created_at, task.task_id
                """,
                params,
            ).fetchall()
            row = None
            resource_request = None
            for candidate in rows:
                if not _worker_can_admit(candidate, worker_capability):
                    continue
                request = _resource_request(candidate, worker_capability)
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
            row = self._locked_task(connection, task_id, worker_id, lease_token)
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
            task = self._locked_task(connection, task_id, worker_id, lease_token)
            plan = connection.execute(
                "SELECT state, cancellation_generation FROM map_build_plans WHERE parent_job_id=?",
                (task.parent_job_id,),
            ).fetchone()
            if plan is None or plan["state"] in {"cancelled", "failed", "ready"}:
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
            task = self._locked_task(connection, task_id, worker_id, lease_token)
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
            task = self._locked_task(connection, task_id, worker_id, lease_token)
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
            if not child_blocks or not child_blocks.issubset(parent_blocks):
                raise BuildingTaskStoreError(
                    "split children must be a subset of the parent block set"
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

    def cancel_plan(self, parent_job_id: str, *, now: float | None = None) -> None:
        now = self._clock() if now is None else now
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                "UPDATE map_build_plans SET state='cancelled', stage='cancelled', cancellation_generation=cancellation_generation+1, updated_at=? WHERE parent_job_id=?",
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
            connection.commit()
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
            rows = connection.execute(
                "SELECT task_id, parent_job_id, transient_attempts FROM map_build_tasks WHERE state='leased' AND lease_expires_at IS NOT NULL AND lease_expires_at <= ?",
                (now,),
            ).fetchall()
            for row in rows:
                plan = connection.execute(
                    "SELECT state FROM map_build_plans WHERE parent_job_id=?",
                    (row["parent_job_id"],),
                ).fetchone()
                new_state = "cancelled" if plan is not None and plan["state"] == "cancelled" else "pending"
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
            connection.commit()
            return len(rows)
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

    def list_receipts(self, parent_job_id: str) -> tuple[dict[str, Any], ...]:
        connection = self._connect()
        try:
            return tuple(dict(row) for row in connection.execute(
                "SELECT * FROM map_build_block_receipts WHERE parent_job_id=? ORDER BY block_x, block_y",
                (parent_job_id,),
            ).fetchall())
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
            task = self._locked_task(connection, task_id, worker_id, lease_token)
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
    ) -> BuildingTaskRecord:
        row = connection.execute(
            "SELECT * FROM map_build_tasks WHERE task_id=?", (task_id,)
        ).fetchone()
        if row is None or row["state"] != "leased" or row["lease_owner"] != worker_id or row["lease_token"] != lease_token:
            raise StaleLeaseError("task lease is no longer valid")
        plan = connection.execute(
            "SELECT state FROM map_build_plans WHERE parent_job_id=?",
            (row["parent_job_id"],),
        ).fetchone()
        if plan is None or plan["state"] in {"cancelled", "failed", "ready"}:
            raise StaleLeaseError("parent plan is no longer active")
        return self._row_to_task(row)

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
            connection.execute("PRAGMA journal_mode=WAL")
            version = int(connection.execute("PRAGMA user_version").fetchone()[0])
            if version > BUILDING_TASK_SCHEMA_VERSION:
                raise BuildingTaskStoreError("unsupported building task schema")
            connection.execute("BEGIN IMMEDIATE")
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


def _predicted_memory(row: sqlite3.Row) -> int:
    predicted = row["predicted_resource_json"]
    if not predicted:
        return 0
    try:
        document = json.loads(predicted)
    except (TypeError, ValueError) as exc:
        raise BuildingTaskStoreError("task predicted resource is invalid") from exc
    if not isinstance(document, dict):
        raise BuildingTaskStoreError("task predicted resource is invalid")
    estimate = document.get("estimatedPeakMemoryBytes")
    if estimate is None:
        return 0
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
               COALESCE(SUM(cpu_weight), 0) AS cpu_weight
        FROM map_build_resource_reservations
        WHERE {where}
        """,
        params,
    ).fetchone()
    return {
        "count": int(row["count"] or 0),
        "memoryBytes": int(row["memory_bytes"] or 0),
        "cpuWeight": float(row["cpu_weight"] or 0),
    }


def _resource_capacity_available(
    connection: sqlite3.Connection,
    request: Mapping[str, Any],
    *,
    now: float,
) -> bool:
    active = _resource_capacity_snapshot(
        connection, request["resourcePool"], now=now
    )
    if active["count"] >= request["maxConcurrentTasks"]:
        return False
    limit = request["memoryLimitBytes"]
    if limit is not None:
        if (
            active["memoryBytes"] + request["memoryReservationBytes"]
            > _memory_admission_limit(limit)
        ):
            return False
    capacity = request["cpuCapacity"]
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
        return value
    nested = capability.get("cgroupMemory")
    if isinstance(nested, Mapping):
        for field in ("limitBytes", "configuredLimitBytes"):
            value = nested.get(field)
            if value is None:
                continue
            if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
                raise BuildingTaskStoreError("worker memory capability is invalid")
            return value
    return None


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
