"""Read-only operator alerts for durable building-map plans."""

from __future__ import annotations

import json
import time
from typing import Any, Mapping

from .building_tasks import BuildingTaskStore


ALERT_SCHEMA_VERSION = 1
DEFAULT_STALE_HEARTBEAT_SECONDS = 60.0
DEFAULT_MEMORY_WARNING_FRACTION = 0.85


def building_plan_alerts(
    store: BuildingTaskStore,
    parent_job_id: str,
    *,
    now: float | None = None,
    stale_heartbeat_seconds: float = DEFAULT_STALE_HEARTBEAT_SECONDS,
    memory_warning_fraction: float = DEFAULT_MEMORY_WARNING_FRACTION,
    limit: int = 100,
    offset: int = 0,
) -> dict[str, Any]:
    """Return one bounded page of secret-free alerts without mutating state.

    The coordinator remains the source of truth for recovery.  This report
    only points an operator at stale leases, failed/split work, memory
    headroom violations, and incomplete receipts; it never retries or
    cancels a task implicitly. The cursor applies to each retained evidence
    collection in ``BuildingTaskStore.diagnostic_page`` so no task, attempt,
    receipt, or reservation query is unbounded.
    """

    if stale_heartbeat_seconds <= 0:
        raise ValueError("stale heartbeat threshold must be positive")
    if not 0 < memory_warning_fraction <= 1:
        raise ValueError("memory warning fraction must be between 0 and 1")
    plan = store.get_plan(parent_job_id)
    if plan is None:
        raise ValueError(f"building plan not found: {parent_job_id}")
    page = store.diagnostic_page(parent_job_id, limit=limit, offset=offset)
    current = time.time() if now is None else now
    alerts: list[dict[str, Any]] = []

    def add(
        code: str,
        severity: str,
        *,
        subject: str,
        detail: Mapping[str, Any],
    ) -> None:
        alerts.append(
            {
                "schemaVersion": ALERT_SCHEMA_VERSION,
                "code": code,
                "severity": severity,
                "subject": subject,
                "detail": dict(detail),
            }
        )

    if plan.get("state") == "failed":
        add(
            "plan_failed",
            "critical",
            subject=parent_job_id,
            detail={"state": plan.get("state"), "stage": plan.get("stage")},
        )

    for task in page["tasks"]:
        if task.state == "leased":
            if task.lease_expires_at is not None and task.lease_expires_at <= current:
                add(
                    "stale_lease",
                    "critical",
                    subject=task.task_id,
                    detail={
                        "parentJobId": parent_job_id,
                        "leaseExpiresAt": task.lease_expires_at,
                        "now": current,
                    },
                )
            if task.heartbeat_at is not None:
                heartbeat_age = max(0.0, current - task.heartbeat_at)
                if heartbeat_age > stale_heartbeat_seconds:
                    add(
                        "stale_heartbeat",
                        "warning",
                        subject=task.task_id,
                        detail={
                            "parentJobId": parent_job_id,
                            "heartbeatAt": task.heartbeat_at,
                            "heartbeatAgeSeconds": round(heartbeat_age, 3),
                            "thresholdSeconds": stale_heartbeat_seconds,
                        },
                    )
        if task.state == "failed":
            add(
                "task_failed",
                "critical",
                subject=task.task_id,
                detail={
                    "parentJobId": parent_job_id,
                    "typedFailure": task.typed_error,
                    "splitDepth": task.split_depth,
                },
            )
        if task.state == "split":
            add(
                "task_split",
                "warning",
                subject=task.task_id,
                detail={
                    "parentJobId": parent_job_id,
                    "typedFailure": task.typed_error,
                    "splitDepth": task.split_depth,
                },
            )

    for reservation in page["parentPhaseReservations"]:
        phase = str(reservation.get("phase") or "unknown")
        subject = f"{parent_job_id}:{phase}"
        expires_at = _number(reservation.get("expires_at"))
        if expires_at is not None and expires_at <= current:
            add(
                "parent_phase_lease_expired",
                "critical",
                subject=subject,
                detail={
                    "parentJobId": parent_job_id,
                    "phase": phase,
                    "workerId": reservation.get("worker_id"),
                    "leaseExpiresAt": expires_at,
                    "now": current,
                },
            )
        heartbeat_at = _number(reservation.get("heartbeat_at"))
        if heartbeat_at is not None:
            heartbeat_age = max(0.0, current - heartbeat_at)
            if heartbeat_age > stale_heartbeat_seconds:
                add(
                    "parent_phase_stale_heartbeat",
                    "warning",
                    subject=subject,
                    detail={
                        "parentJobId": parent_job_id,
                        "phase": phase,
                        "workerId": reservation.get("worker_id"),
                        "heartbeatAt": heartbeat_at,
                        "heartbeatAgeSeconds": round(heartbeat_age, 3),
                        "thresholdSeconds": stale_heartbeat_seconds,
                    },
                )

    for attempt in page["attempts"]:
        typed_failure = attempt.get("typed_failure")
        actual_resource = _json_object(attempt.get("actual_resource_json"))
        root_failure = actual_resource.get("rootFailureCode")
        if isinstance(typed_failure, str):
            lowered = typed_failure.lower()
            if (
                "oom" in lowered
                or "out of memory" in lowered
                or "memory" in lowered
                or root_failure == "building_worker_oom"
            ):
                add(
                    "worker_oom",
                    "critical",
                    subject=str(attempt.get("task_id")),
                    detail={
                        "attemptNumber": attempt.get("attempt_number"),
                        "typedFailure": typed_failure,
                        "outcome": attempt.get("outcome"),
                    },
                )
            elif "cache" in lowered and (
                "corrupt" in lowered or "invalid" in lowered or "missing" in lowered
            ):
                add(
                    "cache_integrity",
                    "critical",
                    subject=str(attempt.get("task_id")),
                    detail={
                        "attemptNumber": attempt.get("attempt_number"),
                        "typedFailure": typed_failure,
                    },
                )
        peak = _nonnegative_int(attempt.get("peak_rss_bytes"))
        capability = _json_object(attempt.get("worker_capability_json"))
        if peak is None or not capability:
            continue
        limit = _memory_limit(capability)
        if limit is not None and peak > limit * memory_warning_fraction:
            add(
                "memory_headroom",
                "critical" if peak > limit else "warning",
                subject=str(attempt.get("task_id")),
                detail={
                    "attemptNumber": attempt.get("attempt_number"),
                    "peakRssBytes": peak,
                    "memoryLimitBytes": limit,
                    "fractionOfLimit": round(peak / limit, 6),
                    "warningFraction": memory_warning_fraction,
                },
            )

    expected = _nonnegative_int(plan.get("expected_output_block_count"))
    receipt_count = int(page["counts"]["receipts"])
    if expected is not None and receipt_count > expected:
        add(
            "receipt_overflow",
            "critical",
            subject=parent_job_id,
            detail={"expectedBlocks": expected, "receiptCount": receipt_count},
        )
    elif (
        expected is not None
        and receipt_count < expected
        and plan.get("stage")
        in {
            "map_assembly",
            "assembly",
            "artifact_validation",
            "artifact_publication",
            "ready",
        }
    ):
        add(
            "missing_receipts",
            "critical",
            subject=parent_job_id,
            detail={"expectedBlocks": expected, "receiptCount": receipt_count},
        )

    alerts.sort(key=lambda item: (item["severity"], item["code"], item["subject"]))
    return {
        "schemaVersion": ALERT_SCHEMA_VERSION,
        "parentJobId": parent_job_id,
        "generatedAt": current,
        "alertCount": len(alerts),
        "page": {
            key: page[key]
            for key in ("limit", "offset", "counts", "hasMore")
        },
        "alerts": alerts,
    }


def _json_object(value: Any) -> dict[str, Any]:
    if not isinstance(value, str):
        return {}
    try:
        parsed = json.loads(value)
    except (TypeError, ValueError, json.JSONDecodeError):
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _memory_limit(capability_document: Mapping[str, Any]) -> int | None:
    capability = capability_document.get("capability", capability_document)
    if not isinstance(capability, Mapping):
        return None
    limits = [
        value
        for key in (
            "memoryLimitBytes",
            "cgroupMemoryLimitBytes",
            "configuredMemoryLimitBytes",
        )
        if (value := _nonnegative_int(capability.get(key))) is not None
        and value > 0
    ]
    return min(limits) if limits else None


def _nonnegative_int(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)
