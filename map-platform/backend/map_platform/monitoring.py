from __future__ import annotations

import json
import math
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from .map_labels import renderer_format_version
from .models import JobStatus, MapJob, utc_now_iso


MONITORING_SCHEMA_VERSION = 1
DEFAULT_MONITORING_RETENTION_DAYS = 90
MAX_MONITORING_RETENTION_DAYS = 3_650
MAX_MONITORING_WINDOW_HOURS = 24 * 365
DEFAULT_MONITORING_SUMMARY_RUN_LIMIT = 50_000
MAX_MONITORING_SUMMARY_RUN_LIMIT = 1_000_000
SUMMARY_SAMPLING_STRATEGY = "most_recent_completion_desc"
MONITORED_TERMINAL_STATUSES = frozenset(
    {JobStatus.READY, JobStatus.FAILED, JobStatus.CANCELLED}
)
NON_WORK_PHASES = frozenset(
    {
        JobStatus.QUEUED.value,
        JobStatus.READY.value,
        JobStatus.FAILED.value,
        JobStatus.EXPIRED.value,
        JobStatus.CANCELLED.value,
    }
)
MONITORING_TABLE = "map_build_runs"
MONITORING_COLUMNS = frozenset(
    {
        "job_id",
        "status",
        "completed_at",
        "completed_epoch",
        "created_at",
        "started_at",
        "finished_at",
        "queue_wait_seconds",
        "processing_seconds",
        "total_seconds",
        "attempts",
        "renderer_format_version",
        "geometry_mode",
        "area_km2",
        "reuse_strategy",
        "phase_timings_json",
    }
)


class MonitoringSchemaError(RuntimeError):
    """The durable monitoring database cannot be safely used by this release."""


class MapMonitoringStore:
    """Persist completed map-build timings and expose bounded aggregate summaries."""

    def __init__(
        self,
        path: str | Path,
        *,
        retention_days: int = DEFAULT_MONITORING_RETENTION_DAYS,
        summary_run_limit: int = DEFAULT_MONITORING_SUMMARY_RUN_LIMIT,
        clock=None,
    ):
        if (
            isinstance(retention_days, bool)
            or not 1 <= retention_days <= MAX_MONITORING_RETENTION_DAYS
        ):
            raise ValueError(
                "monitoring retention days must be between 1 and 3650"
            )
        if (
            isinstance(summary_run_limit, bool)
            or not 1 <= summary_run_limit <= MAX_MONITORING_SUMMARY_RUN_LIMIT
        ):
            raise ValueError(
                "monitoring summary run limit must be between 1 and 1000000"
            )
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.retention_days = retention_days
        self.summary_run_limit = summary_run_limit
        self._clock = clock or time.time
        self._initialize()

    def record_job(self, job: MapJob) -> bool:
        """Upsert a terminal build record; return whether a record was written."""
        record = self._record_for_job(job)
        result = self._reconcile_records([record] if record is not None else [])
        return result["synced"] == 1

    def sync_jobs(self, jobs: Iterable[MapJob]) -> int:
        """Reconcile terminal job records after worker/API restarts."""
        return int(self.reconcile_jobs(jobs)["synced"])

    def reconcile_jobs(self, jobs: Iterable[MapJob]) -> dict[str, int]:
        """Atomically prune expired rows and reconcile terminal job records."""
        records = [
            record
            for job in jobs
            if (record := self._record_for_job(job)) is not None
        ]
        return self._reconcile_records(records)

    def _reconcile_records(self, records: list[tuple[Any, ...]]) -> dict[str, int]:
        cutoff = self._retention_cutoff()
        eligible_records = [
            record for record in records if float(record[3]) >= cutoff
        ]
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            removed = self._prune_connection(connection, cutoff)
            for record in eligible_records:
                self._upsert(connection, record)
            connection.commit()
            return {"synced": len(eligible_records), "removed": removed}
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def prune(self, *, older_than_days: int | None = None) -> int:
        days = self.retention_days if older_than_days is None else older_than_days
        if isinstance(days, bool) or not 1 <= days <= MAX_MONITORING_RETENTION_DAYS:
            raise ValueError("monitoring retention days must be between 1 and 3650")
        cutoff = self._clock() - days * 86_400
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            removed = self._prune_connection(connection, cutoff)
            connection.commit()
            return removed
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def summary(self, *, window_hours: int = 168) -> dict[str, Any]:
        if (
            isinstance(window_hours, bool)
            or not 1 <= window_hours <= MAX_MONITORING_WINDOW_HOURS
        ):
            raise ValueError(
                "monitoring window hours must be between 1 and 8760"
            )
        now = self._clock()
        effective_window_hours = min(window_hours, self.retention_days * 24)
        requested_cutoff = now - window_hours * 3_600
        retention_cutoff = self._retention_cutoff(now)
        cutoff = max(requested_cutoff, retention_cutoff)
        connection = self._connect()
        try:
            rows = connection.execute(
                """
                SELECT
                    job_id,
                    status,
                    completed_at,
                    completed_epoch,
                    queue_wait_seconds,
                    processing_seconds,
                    total_seconds,
                    attempts,
                    renderer_format_version,
                    phase_timings_json
                FROM map_build_runs
                WHERE completed_epoch >= ? AND completed_epoch <= ?
                ORDER BY completed_epoch DESC, job_id DESC
                LIMIT ?
                """,
                (cutoff, now, self.summary_run_limit),
            ).fetchall()
            matching_count = int(
                connection.execute(
                    """
                    SELECT COUNT(*)
                    FROM map_build_runs
                    WHERE completed_epoch >= ? AND completed_epoch <= ?
                    """,
                    (cutoff, now),
                ).fetchone()[0]
            )
            retained_count = int(
                connection.execute(
                    """
                    SELECT COUNT(*)
                    FROM map_build_runs
                    WHERE completed_epoch >= ? AND completed_epoch <= ?
                    """,
                    (retention_cutoff, now),
                ).fetchone()[0]
            )
        finally:
            connection.close()

        # The query intentionally reads newest-first so SQLite can use the
        # composite completion index. Restore chronological order for the
        # existing aggregate helpers and lastCompletedAt field.
        rows.reverse()
        sampled_count = len(rows)

        return {
            "schemaVersion": MONITORING_SCHEMA_VERSION,
            "generatedAt": utc_now_iso(),
            "windowHours": effective_window_hours,
            "windowStartedAt": _iso_from_epoch(cutoff),
            "retentionDays": self.retention_days,
            "retainedRunCount": retained_count,
            "matchingRunCount": matching_count,
            "sampledRunCount": sampled_count,
            "configuredRunLimit": self.summary_run_limit,
            "truncated": matching_count > sampled_count,
            "samplingStrategy": SUMMARY_SAMPLING_STRATEGY,
            "runs": _run_counts(rows),
            "serverTiming": _timing_summary(rows),
            "phaseTimings": _phase_summary(rows),
            "byRendererFormat": _renderer_summary(rows),
            "lastCompletedAt": rows[-1]["completed_at"] if rows else None,
        }

    def _initialize(self) -> None:
        connection = self._connect()
        try:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("BEGIN IMMEDIATE")
            version = int(connection.execute("PRAGMA user_version").fetchone()[0])
            table_exists = connection.execute(
                """
                SELECT 1
                FROM sqlite_master
                WHERE type = 'table' AND name = ?
                """,
                (MONITORING_TABLE,),
            ).fetchone() is not None

            if version > MONITORING_SCHEMA_VERSION:
                raise MonitoringSchemaError(
                    f"unsupported monitoring schema version {version}"
                )
            if not table_exists:
                if version != 0:
                    raise MonitoringSchemaError(
                        "monitoring schema version is set but its table is missing"
                    )
                connection.execute(
                    """
                    CREATE TABLE map_build_runs(
                        job_id TEXT PRIMARY KEY,
                        status TEXT NOT NULL,
                        completed_at TEXT NOT NULL,
                        completed_epoch REAL NOT NULL,
                        created_at TEXT NOT NULL,
                        started_at TEXT,
                        finished_at TEXT,
                        queue_wait_seconds REAL,
                        processing_seconds REAL,
                        total_seconds REAL,
                        attempts INTEGER NOT NULL,
                        renderer_format_version INTEGER,
                        geometry_mode TEXT NOT NULL,
                        area_km2 REAL NOT NULL,
                        reuse_strategy TEXT,
                        phase_timings_json TEXT NOT NULL
                    )
                    """
                )
                connection.execute(
                    f"PRAGMA user_version = {MONITORING_SCHEMA_VERSION}"
                )
            else:
                columns = {
                    str(row[1])
                    for row in connection.execute(
                        f"PRAGMA table_info({MONITORING_TABLE})"
                    ).fetchall()
                }
                missing = sorted(MONITORING_COLUMNS - columns)
                if missing:
                    raise MonitoringSchemaError(
                        "monitoring schema is missing required columns: "
                        + ", ".join(missing)
                    )
                if version == 0:
                    # PR #198 shipped this exact table before user_version was
                    # introduced. Adopt it only after validating every column.
                    connection.execute(
                        f"PRAGMA user_version = {MONITORING_SCHEMA_VERSION}"
                    )
                elif version != MONITORING_SCHEMA_VERSION:
                    raise MonitoringSchemaError(
                        f"unsupported monitoring schema version {version}"
                    )
            connection.execute(
                """
                CREATE INDEX IF NOT EXISTS map_build_runs_completed
                ON map_build_runs(completed_epoch)
                """
            )
            connection.execute(
                """
                CREATE INDEX IF NOT EXISTS map_build_runs_completed_desc
                ON map_build_runs(completed_epoch DESC, job_id DESC)
                """
            )
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5)
        connection.execute("PRAGMA busy_timeout=5000")
        connection.row_factory = sqlite3.Row
        return connection

    def _retention_cutoff(self, now: float | None = None) -> float:
        return (self._clock() if now is None else now) - self.retention_days * 86_400

    @staticmethod
    def _prune_connection(connection: sqlite3.Connection, cutoff: float) -> int:
        cursor = connection.execute(
            "DELETE FROM map_build_runs WHERE completed_epoch < ?",
            (cutoff,),
        )
        return max(cursor.rowcount, 0)

    def _record_for_job(self, job: MapJob) -> tuple[Any, ...] | None:
        if job.status not in MONITORED_TERMINAL_STATUSES or not job.finished_at:
            return None
        completed_epoch = _timestamp_epoch(job.finished_at)
        if completed_epoch is None:
            return None
        timing = job.server_timing()
        phase_timings = json.dumps(
            job.phase_timings(),
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
        return (
            job.job_id,
            job.status.value,
            job.finished_at,
            completed_epoch,
            job.created_at,
            job.started_at,
            job.finished_at,
            _finite_or_none(timing["queueWaitSeconds"]),
            _finite_or_none(timing["processingSeconds"]),
            _finite_or_none(timing["totalSeconds"]),
            int(job.attempts),
            renderer_format_version(job.request),
            job.geometry.mode.value,
            float(job.geometry.area_km2),
            job.reuse_strategy,
            phase_timings,
        )

    @staticmethod
    def _upsert(connection: sqlite3.Connection, record: tuple[Any, ...]) -> None:
        connection.execute(
            """
            INSERT INTO map_build_runs(
                job_id,
                status,
                completed_at,
                completed_epoch,
                created_at,
                started_at,
                finished_at,
                queue_wait_seconds,
                processing_seconds,
                total_seconds,
                attempts,
                renderer_format_version,
                geometry_mode,
                area_km2,
                reuse_strategy,
                phase_timings_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(job_id) DO UPDATE SET
                status = excluded.status,
                completed_at = excluded.completed_at,
                completed_epoch = excluded.completed_epoch,
                created_at = excluded.created_at,
                started_at = excluded.started_at,
                finished_at = excluded.finished_at,
                queue_wait_seconds = excluded.queue_wait_seconds,
                processing_seconds = excluded.processing_seconds,
                total_seconds = excluded.total_seconds,
                attempts = excluded.attempts,
                renderer_format_version = excluded.renderer_format_version,
                geometry_mode = excluded.geometry_mode,
                area_km2 = excluded.area_km2,
                reuse_strategy = excluded.reuse_strategy,
                phase_timings_json = excluded.phase_timings_json
            """,
            record,
        )


def build_map_job_monitoring_event(
    job: MapJob,
    worker_id: str,
    *,
    attempt_started_at: str | None = None,
    attempt_finished_at: str | None = None,
    outcome: str | None = None,
) -> dict[str, Any]:
    """Build a safe, structured event suitable for worker stdout logs."""
    finished_at = attempt_finished_at or job.finished_at or job.updated_at
    attempt_duration = _duration_seconds(attempt_started_at, finished_at)
    event: dict[str, Any] = {
        "event": "map_job_run_completed",
        "jobId": job.job_id,
        "workerId": worker_id,
        "status": job.status.value,
        "outcome": outcome or job.status.value,
        "attempt": job.attempts,
        "completedAt": finished_at,
        "attemptTiming": {
            "startedAt": attempt_started_at,
            "finishedAt": finished_at,
            "durationSeconds": attempt_duration,
        },
        "serverTiming": job.server_timing(),
        "phaseTimings": job.phase_timings(),
        "rendererFormatVersion": renderer_format_version(job.request),
        "geometryMode": job.geometry.mode.value,
        "areaKm2": round(float(job.geometry.area_km2), 6),
    }
    if job.reuse_strategy is not None:
        event["reuseStrategy"] = job.reuse_strategy
    return event


def _run_counts(rows: list[sqlite3.Row]) -> dict[str, Any]:
    by_status: dict[str, int] = {}
    for row in rows:
        status = str(row["status"])
        by_status[status] = by_status.get(status, 0) + 1
    return {
        "count": len(rows),
        "byStatus": dict(sorted(by_status.items())),
    }


def _timing_summary(rows: list[sqlite3.Row]) -> dict[str, Any]:
    return {
        output_name: _statistics(
            [
                float(row[column])
                for row in rows
                if row[column] is not None and _is_finite_number(row[column])
            ]
        )
        for output_name, column in (
            ("queueWaitSeconds", "queue_wait_seconds"),
            ("processingSeconds", "processing_seconds"),
            ("totalSeconds", "total_seconds"),
        )
    }


def _phase_summary(rows: list[sqlite3.Row]) -> dict[str, Any]:
    durations: dict[str, list[float]] = {}
    for row in rows:
        try:
            phases = json.loads(row["phase_timings_json"])
        except (TypeError, ValueError):
            continue
        if not isinstance(phases, list):
            continue
        for phase in phases:
            if not isinstance(phase, dict):
                continue
            name = phase.get("status")
            duration = phase.get("durationSeconds")
            if (
                isinstance(name, str)
                and name not in NON_WORK_PHASES
                and _is_finite_number(duration)
                and float(duration) >= 0
            ):
                durations.setdefault(name, []).append(float(duration))
    return {
        name: _statistics(values)
        for name, values in sorted(durations.items())
    }


def _renderer_summary(rows: list[sqlite3.Row]) -> dict[str, Any]:
    groups: dict[str, list[sqlite3.Row]] = {}
    for row in rows:
        value = row["renderer_format_version"]
        key = str(value) if value is not None else "unknown"
        groups.setdefault(key, []).append(row)
    return {
        key: {
            "runs": _run_counts(group),
            "serverTiming": _timing_summary(group),
        }
        for key, group in sorted(groups.items())
    }


def _statistics(values: list[float]) -> dict[str, Any]:
    if not values:
        return {
            "count": 0,
            "minSeconds": None,
            "p50Seconds": None,
            "p95Seconds": None,
            "avgSeconds": None,
            "maxSeconds": None,
        }
    ordered = sorted(values)
    return {
        "count": len(ordered),
        "minSeconds": _round_seconds(ordered[0]),
        "p50Seconds": _round_seconds(_percentile(ordered, 50)),
        "p95Seconds": _round_seconds(_percentile(ordered, 95)),
        "avgSeconds": _round_seconds(sum(ordered) / len(ordered)),
        "maxSeconds": _round_seconds(ordered[-1]),
    }


def _percentile(values: list[float], percentile: float) -> float:
    if len(values) == 1:
        return values[0]
    position = (len(values) - 1) * percentile / 100
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return values[lower]
    fraction = position - lower
    return values[lower] + (values[upper] - values[lower]) * fraction


def _round_seconds(value: float) -> float:
    return round(float(value), 6)


def _finite_or_none(value: Any) -> float | None:
    if not _is_finite_number(value):
        return None
    return float(value)


def _is_finite_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
    )


def _timestamp_epoch(value: str | None) -> float | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(
            value[:-1] + "+00:00" if value.endswith("Z") else value
        )
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def _iso_from_epoch(value: float) -> str:
    return (
        datetime.fromtimestamp(value, timezone.utc)
        .isoformat(timespec="microseconds")
        .replace("+00:00", "Z")
    )


def _duration_seconds(started_at: str | None, finished_at: str | None) -> float | None:
    start = _timestamp_epoch(started_at)
    finish = _timestamp_epoch(finished_at)
    if start is None or finish is None:
        return None
    return max(finish - start, 0.0)
