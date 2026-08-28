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


# The admin summary payload has its own forward-compatible schema. Keep the
# SQLite user_version at 1 because the v2 storage changes are additive: during
# a digest-pinned rollout, the previous API or worker must continue opening the
# shared database after a newer process adds the estimator columns/table.
MONITORING_SCHEMA_VERSION = 2
MONITORING_STORAGE_SCHEMA_VERSION = 1
DEFAULT_MONITORING_RETENTION_DAYS = 90
MAX_MONITORING_RETENTION_DAYS = 3_650
MAX_MONITORING_WINDOW_HOURS = 24 * 365
DEFAULT_MONITORING_SUMMARY_RUN_LIMIT = 50_000
MAX_MONITORING_SUMMARY_RUN_LIMIT = 1_000_000
DEFAULT_MAX_ESTIMATE_REVISIONS = 16
MAX_ESTIMATE_REVISIONS_LIMIT = 256
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
ESTIMATE_REVISIONS_TABLE = "map_estimate_revisions"
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
        "source_region_id",
        "source_provider",
        "preprocessing_mode",
        "scope_policy_version",
        "performance_compatibility_key",
        "estimator_model_version",
        "producer_build_sha256",
        "producer_image_digest",
        "worker_class",
        "output_block_count",
        "output_area_m2",
        "source_area_m2",
        "source_bytes",
        "source_expansion_basis_points",
        "calibration_cache_outcome",
        "building_block_cache_outcome",
        "building_block_cache_hit_count",
        "building_block_cache_miss_count",
        "closure_candidate_count",
        "closure_way_count",
        "closure_node_count",
        "closure_relation_count",
        "relation_retry_count",
        "building_source_count",
        "building_outline_count",
        "building_part_count",
        "building_unresolved_part_count",
        "building_containment_count",
        "building_point_count",
        "label_candidate_count",
        "outcome_class",
        "initial_estimate_lower_seconds",
        "initial_estimate_upper_seconds",
        "final_estimate_lower_seconds",
        "final_estimate_upper_seconds",
    }
)
MONITORING_V1_COLUMNS = frozenset(
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
MONITORING_V2_COLUMN_TYPES = {
    "source_region_id": "TEXT",
    "source_provider": "TEXT",
    "preprocessing_mode": "TEXT",
    "scope_policy_version": "INTEGER",
    "performance_compatibility_key": "TEXT",
    "estimator_model_version": "TEXT",
    "producer_build_sha256": "TEXT",
    "producer_image_digest": "TEXT",
    "worker_class": "TEXT",
    "output_block_count": "INTEGER",
    "output_area_m2": "INTEGER",
    "source_area_m2": "INTEGER",
    "source_bytes": "INTEGER",
    "source_expansion_basis_points": "INTEGER",
    "calibration_cache_outcome": "TEXT",
    "building_block_cache_outcome": "TEXT",
    "building_block_cache_hit_count": "INTEGER",
    "building_block_cache_miss_count": "INTEGER",
    "closure_candidate_count": "INTEGER",
    "closure_way_count": "INTEGER",
    "closure_node_count": "INTEGER",
    "closure_relation_count": "INTEGER",
    "relation_retry_count": "INTEGER",
    "building_source_count": "INTEGER",
    "building_outline_count": "INTEGER",
    "building_part_count": "INTEGER",
    "building_unresolved_part_count": "INTEGER",
    "building_containment_count": "INTEGER",
    "building_point_count": "INTEGER",
    "label_candidate_count": "INTEGER",
    "outcome_class": "TEXT",
    "initial_estimate_lower_seconds": "INTEGER",
    "initial_estimate_upper_seconds": "INTEGER",
    "final_estimate_lower_seconds": "INTEGER",
    "final_estimate_upper_seconds": "INTEGER",
}
ESTIMATE_REVISION_COLUMNS = frozenset(
    {
        "job_id",
        "revision",
        "generated_at",
        "generated_epoch",
        "attempt",
        "state",
        "confidence",
        "lower_seconds",
        "upper_seconds",
        "queue_lower_seconds",
        "queue_upper_seconds",
        "model_version",
        "performance_compatibility_key",
        "basis_json",
        "sample_count",
        "based_on_phase",
    }
)
RUN_RECORD_COLUMNS = (
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
    *MONITORING_V2_COLUMN_TYPES.keys(),
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
        max_estimate_revisions: int = DEFAULT_MAX_ESTIMATE_REVISIONS,
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
        if (
            isinstance(max_estimate_revisions, bool)
            or not 1 <= max_estimate_revisions <= MAX_ESTIMATE_REVISIONS_LIMIT
        ):
            raise ValueError(
                "maximum estimate revisions must be between 1 and 256"
            )
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.retention_days = retention_days
        self.summary_run_limit = summary_run_limit
        self.max_estimate_revisions = max_estimate_revisions
        self._clock = clock or time.time
        self._initialize()

    def record_job(self, job: MapJob) -> bool:
        """Upsert a terminal build record; return whether a record was written."""
        record = self._record_for_job(job)
        result = self._reconcile_records([record] if record is not None else [])
        return result["synced"] == 1

    def record_estimate_revision(self, job: MapJob) -> bool:
        """Persist one bounded advisory revision without affecting the job."""
        estimate = job.preparation_estimate
        context = job.preparation_estimator_context
        if not isinstance(estimate, dict) or not isinstance(context, dict):
            return False
        from .preparation_estimates import validate_preparation_estimate

        estimate = validate_preparation_estimate(estimate)
        generated_epoch = _timestamp_epoch(estimate["generatedAt"])
        if generated_epoch is None:
            return False
        remaining = estimate.get("remaining") or {}
        queue = estimate.get("queue") or {}
        record = (
            job.job_id,
            int(estimate["revision"]),
            estimate["generatedAt"],
            generated_epoch,
            int(estimate["attempt"]),
            estimate["state"],
            estimate.get("confidence"),
            remaining.get("lowerSeconds"),
            remaining.get("upperSeconds"),
            queue.get("lowerSeconds"),
            queue.get("upperSeconds"),
            estimate["modelVersion"],
            context.get("performanceCompatibilityKey"),
            json.dumps(
                estimate.get("basis", []),
                sort_keys=True,
                separators=(",", ":"),
                allow_nan=False,
            ),
            estimate.get("sampleCount"),
            estimate["basedOnPhase"],
        )
        # Revisions are advisory telemetry. Fail fast on writer contention so
        # an estimate cannot stall job acceptance or map progress behind the
        # monitoring database's normal five-second busy timeout.
        connection = self._connect(busy_timeout_ms=100)
        try:
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute(
                """
                SELECT 1 FROM map_estimate_revisions
                WHERE job_id = ? AND revision = ?
                """,
                (job.job_id, int(estimate["revision"])),
            ).fetchone()
            if existing is not None:
                connection.commit()
                return False
            count = int(
                connection.execute(
                    "SELECT COUNT(*) FROM map_estimate_revisions WHERE job_id = ?",
                    (job.job_id,),
                ).fetchone()[0]
            )
            if count >= self.max_estimate_revisions:
                connection.commit()
                return False
            connection.execute(
                """
                INSERT INTO map_estimate_revisions(
                    job_id, revision, generated_at, generated_epoch, attempt,
                    state, confidence, lower_seconds, upper_seconds,
                    queue_lower_seconds, queue_upper_seconds, model_version,
                    performance_compatibility_key, basis_json, sample_count,
                    based_on_phase
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                record,
            )
            connection.commit()
            return True
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def estimate_samples(
        self,
        *,
        performance_key: str,
        renderer: int,
        preprocessing_mode: str,
        outcome_class: str,
        claimed: bool,
        source_region_id: str | None = None,
        output_block_count: int | None = None,
        source_area_m2: int | None = None,
        building_source_count: int | None = None,
        cache_outcome: str | None = None,
        building_cache_outcome: str | None = None,
        minimum_samples: int = 20,
        limit: int = 500,
    ) -> list[float]:
        # Build-history cohorts model work only. Queue delay is estimated as a
        # separate current-topology component and must not be counted twice.
        del claimed
        column = "processing_seconds"
        connection = self._connect()
        try:
            rows = connection.execute(
                f"""
                SELECT {column} AS duration,
                       source_region_id,
                       output_block_count,
                       source_area_m2,
                       building_source_count,
                       calibration_cache_outcome,
                       building_block_cache_outcome
                FROM map_build_runs
                WHERE status = 'ready'
                  AND attempts = 1
                  AND performance_compatibility_key = ?
                  AND renderer_format_version = ?
                  AND preprocessing_mode = ?
                  AND outcome_class = ?
                  AND {column} IS NOT NULL
                ORDER BY completed_epoch DESC, job_id DESC
                LIMIT ?
                """,
                (
                    performance_key,
                    renderer,
                    preprocessing_mode,
                    outcome_class,
                    max(1, min(int(limit), 5_000)),
                ),
            ).fetchall()
        finally:
            connection.close()
        valid = [
            row
            for row in rows
            if _is_finite_number(row["duration"])
            and float(row["duration"]) >= 0
        ]
        # Building-block cache hits remove the dominant normalization and
        # encoding work. Never dilute a known cold, partial, or warm cohort
        # with a different cache outcome, even when the cohort is still small.
        compatible = [
            row
            for row in valid
            if building_cache_outcome is None
            or row["building_block_cache_outcome"] == building_cache_outcome
        ]
        requested_block_bucket = _block_bucket(output_block_count)
        requested_density_bucket = _density_bucket(
            building_source_count, source_area_m2
        )

        def exact(row: sqlite3.Row) -> bool:
            return (
                (source_region_id is None or row["source_region_id"] == source_region_id)
                and (
                    requested_block_bucket == "unknown"
                    or _block_bucket(row["output_block_count"])
                    == requested_block_bucket
                )
                and (
                    requested_density_bucket == "unknown"
                    or _density_bucket(
                        row["building_source_count"], row["source_area_m2"]
                    )
                    == requested_density_bucket
                )
                and (
                    cache_outcome is None
                    or row["calibration_cache_outcome"] == cache_outcome
                )
            )

        def neighboring(row: sqlite3.Row) -> bool:
            return (
                (
                    cache_outcome is None
                    or row["calibration_cache_outcome"] == cache_outcome
                )
                and _neighboring_bucket(
                    requested_block_bucket,
                    _block_bucket(row["output_block_count"]),
                    ("1", "2-4", "5-8", "9+"),
                )
                and _neighboring_bucket(
                    requested_density_bucket,
                    _density_bucket(
                        row["building_source_count"], row["source_area_m2"]
                    ),
                    ("sparse", "medium", "dense", "very_dense"),
                )
            )

        tiers = [
            [row for row in compatible if exact(row)],
            [row for row in compatible if neighboring(row)],
            compatible,
        ]
        minimum = max(1, min(int(minimum_samples), 10_000))
        selected = next((tier for tier in tiers if len(tier) >= minimum), None)
        if selected is None:
            selected = next((tier for tier in tiers if tier), [])
        return [float(row["duration"]) for row in selected]

    def queue_samples(
        self, *, performance_key: str, renderer: int, limit: int = 500
    ) -> list[float]:
        connection = self._connect()
        try:
            rows = connection.execute(
                """
                SELECT queue_wait_seconds AS duration
                FROM map_build_runs
                WHERE status = 'ready'
                  AND performance_compatibility_key = ?
                  AND renderer_format_version = ?
                  AND queue_wait_seconds IS NOT NULL
                ORDER BY completed_epoch DESC, job_id DESC
                LIMIT ?
                """,
                (performance_key, renderer, max(1, min(int(limit), 5_000))),
            ).fetchall()
        finally:
            connection.close()
        return [
            float(row["duration"])
            for row in rows
            if _is_finite_number(row["duration"])
            and float(row["duration"]) >= 0
        ]

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
                    preprocessing_mode,
                    performance_compatibility_key,
                    outcome_class,
                    calibration_cache_outcome,
                    building_block_cache_outcome,
                    output_block_count,
                    source_area_m2,
                    building_source_count,
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
            revision_rows = connection.execute(
                """
                SELECT
                    revision.job_id,
                    revision.revision,
                    revision.generated_at,
                    revision.generated_epoch,
                    revision.attempt,
                    revision.state,
                    revision.confidence,
                    revision.lower_seconds,
                    revision.upper_seconds,
                    revision.queue_lower_seconds,
                    revision.queue_upper_seconds,
                    revision.model_version,
                    revision.performance_compatibility_key,
                    revision.basis_json,
                    revision.sample_count,
                    revision.based_on_phase,
                    run.completed_epoch,
                    run.status AS terminal_status
                FROM map_estimate_revisions revision
                LEFT JOIN map_build_runs run ON run.job_id = revision.job_id
                WHERE revision.generated_epoch >= ?
                  AND revision.generated_epoch <= ?
                ORDER BY revision.generated_epoch DESC,
                         revision.job_id DESC,
                         revision.revision DESC
                LIMIT ?
                """,
                (cutoff, now, self.summary_run_limit * 16),
            ).fetchall()
        finally:
            connection.close()

        # The query intentionally reads newest-first so SQLite can use the
        # composite completion index. Restore chronological order for the
        # existing aggregate helpers and lastCompletedAt field.
        rows.reverse()
        revision_rows.reverse()
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
            "estimateCohorts": _cohort_summary(rows),
            "estimateRevisions": _revision_summary(revision_rows),
            "estimateAccuracy": _estimate_accuracy(revision_rows),
            "estimateModelComparison": _estimate_model_comparison(
                revision_rows
            ),
            "estimateExclusions": _estimate_exclusions(rows),
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

            if version > MONITORING_STORAGE_SCHEMA_VERSION:
                raise MonitoringSchemaError(
                    f"unsupported monitoring schema version {version}"
                )
            if not table_exists:
                if version != 0:
                    raise MonitoringSchemaError(
                        "monitoring schema version is set but its table is missing"
                    )
                self._create_v2_tables(connection)
                version = MONITORING_STORAGE_SCHEMA_VERSION
            else:
                columns = {
                    str(row[1])
                    for row in connection.execute(
                        f"PRAGMA table_info({MONITORING_TABLE})"
                    ).fetchall()
                }
                missing_v1 = sorted(MONITORING_V1_COLUMNS - columns)
                if missing_v1:
                    raise MonitoringSchemaError(
                        "monitoring schema is missing required columns: "
                        + ", ".join(missing_v1)
                    )
                if version == 0:
                    # PR #198 shipped this exact v1 table before user_version.
                    if columns == MONITORING_V1_COLUMNS:
                        version = MONITORING_STORAGE_SCHEMA_VERSION
                        connection.execute(
                            f"PRAGMA user_version = {MONITORING_STORAGE_SCHEMA_VERSION}"
                        )
                    elif MONITORING_COLUMNS.issubset(columns):
                        version = MONITORING_STORAGE_SCHEMA_VERSION
                        connection.execute(
                            f"PRAGMA user_version = {MONITORING_STORAGE_SCHEMA_VERSION}"
                        )
                    else:
                        raise MonitoringSchemaError(
                            "unversioned monitoring schema cannot be safely adopted"
                        )
                if version == MONITORING_STORAGE_SCHEMA_VERSION:
                    for name, column_type in MONITORING_V2_COLUMN_TYPES.items():
                        if name not in columns:
                            connection.execute(
                                f"ALTER TABLE {MONITORING_TABLE} "
                                f"ADD COLUMN {name} {column_type}"
                            )
                    self._create_revision_table(connection)
                else:
                    raise MonitoringSchemaError(
                        f"unsupported monitoring schema version {version}"
                    )
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
            self._create_revision_table(connection)
            revision_columns = {
                str(row[1])
                for row in connection.execute(
                    f"PRAGMA table_info({ESTIMATE_REVISIONS_TABLE})"
                ).fetchall()
            }
            missing_revisions = sorted(
                ESTIMATE_REVISION_COLUMNS - revision_columns
            )
            if missing_revisions:
                raise MonitoringSchemaError(
                    "estimate revision schema is missing required columns: "
                    + ", ".join(missing_revisions)
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
            connection.execute(
                """
                CREATE INDEX IF NOT EXISTS map_estimate_revisions_generated
                ON map_estimate_revisions(generated_epoch, job_id, revision)
                """
            )
            connection.execute(
                """
                CREATE INDEX IF NOT EXISTS map_build_runs_estimate_cohort
                ON map_build_runs(
                    performance_compatibility_key,
                    renderer_format_version,
                    preprocessing_mode,
                    outcome_class,
                    completed_epoch DESC
                )
                """
            )
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    @staticmethod
    def _create_v2_tables(connection: sqlite3.Connection) -> None:
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
                phase_timings_json TEXT NOT NULL,
                source_region_id TEXT,
                source_provider TEXT,
                preprocessing_mode TEXT,
                scope_policy_version INTEGER,
                performance_compatibility_key TEXT,
                estimator_model_version TEXT,
                producer_build_sha256 TEXT,
                producer_image_digest TEXT,
                worker_class TEXT,
                output_block_count INTEGER,
                output_area_m2 INTEGER,
                source_area_m2 INTEGER,
                source_bytes INTEGER,
                source_expansion_basis_points INTEGER,
                calibration_cache_outcome TEXT,
                building_block_cache_outcome TEXT,
                building_block_cache_hit_count INTEGER,
                building_block_cache_miss_count INTEGER,
                closure_candidate_count INTEGER,
                closure_way_count INTEGER,
                closure_node_count INTEGER,
                closure_relation_count INTEGER,
                relation_retry_count INTEGER,
                building_source_count INTEGER,
                building_outline_count INTEGER,
                building_part_count INTEGER,
                building_unresolved_part_count INTEGER,
                building_containment_count INTEGER,
                building_point_count INTEGER,
                label_candidate_count INTEGER,
                outcome_class TEXT,
                initial_estimate_lower_seconds INTEGER,
                initial_estimate_upper_seconds INTEGER,
                final_estimate_lower_seconds INTEGER,
                final_estimate_upper_seconds INTEGER
            )
            """
        )
        MapMonitoringStore._create_revision_table(connection)
        connection.execute(
            f"PRAGMA user_version = {MONITORING_STORAGE_SCHEMA_VERSION}"
        )

    @staticmethod
    def _create_revision_table(connection: sqlite3.Connection) -> None:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS map_estimate_revisions(
                job_id TEXT NOT NULL,
                revision INTEGER NOT NULL,
                generated_at TEXT NOT NULL,
                generated_epoch REAL NOT NULL,
                attempt INTEGER NOT NULL,
                state TEXT NOT NULL,
                confidence TEXT,
                lower_seconds INTEGER,
                upper_seconds INTEGER,
                queue_lower_seconds INTEGER,
                queue_upper_seconds INTEGER,
                model_version TEXT NOT NULL,
                performance_compatibility_key TEXT,
                basis_json TEXT NOT NULL,
                sample_count INTEGER,
                based_on_phase TEXT NOT NULL,
                PRIMARY KEY(job_id, revision)
            )
            """
        )

    def _connect(self, *, busy_timeout_ms: int = 5_000) -> sqlite3.Connection:
        connection = sqlite3.connect(
            self.path,
            timeout=max(0, busy_timeout_ms) / 1_000,
        )
        connection.execute(f"PRAGMA busy_timeout={max(0, busy_timeout_ms)}")
        connection.row_factory = sqlite3.Row
        return connection

    def _retention_cutoff(self, now: float | None = None) -> float:
        return (self._clock() if now is None else now) - self.retention_days * 86_400

    @staticmethod
    def _prune_connection(connection: sqlite3.Connection, cutoff: float) -> int:
        connection.execute(
            "DELETE FROM map_estimate_revisions WHERE generated_epoch < ?",
            (cutoff,),
        )
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
        estimator_features = _terminal_estimator_features(job)
        base = (
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
        return base + tuple(
            estimator_features.get(column)
            for column in MONITORING_V2_COLUMN_TYPES
        )

    @staticmethod
    def _upsert(connection: sqlite3.Connection, record: tuple[Any, ...]) -> None:
        if len(record) != len(RUN_RECORD_COLUMNS):
            raise ValueError("monitoring record column count is invalid")
        columns = ", ".join(RUN_RECORD_COLUMNS)
        placeholders = ", ".join("?" for _ in RUN_RECORD_COLUMNS)
        updates = ", ".join(
            f"{column} = excluded.{column}"
            for column in RUN_RECORD_COLUMNS
            if column != "job_id"
        )
        connection.execute(
            f"""
            INSERT INTO map_build_runs({columns})
            VALUES ({placeholders})
            ON CONFLICT(job_id) DO UPDATE SET {updates}
            """,
            record,
        )
        connection.execute(
            """
            UPDATE map_build_runs
            SET initial_estimate_lower_seconds = (
                    SELECT lower_seconds FROM map_estimate_revisions
                    WHERE job_id = ? ORDER BY revision ASC LIMIT 1
                ),
                initial_estimate_upper_seconds = (
                    SELECT upper_seconds FROM map_estimate_revisions
                    WHERE job_id = ? ORDER BY revision ASC LIMIT 1
                )
            WHERE job_id = ?
            """,
            (record[0], record[0], record[0]),
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
    if job.error_code is not None:
        event["errorCode"] = job.error_code
    if job.admission_cost is not None:
        event["admission"] = {
            "cost": job.admission_cost,
            "policyVersion": job.admission_policy_version,
            "partition": job.admission_partition,
        }
    if isinstance(job.preparation_estimate, dict):
        estimate = job.preparation_estimate
        event["preparationEstimate"] = {
            key: estimate[key]
            for key in (
                "revision",
                "attempt",
                "state",
                "modelVersion",
                "confidence",
                "remaining",
                "queue",
                "basis",
                "basedOnPhase",
            )
            if key in estimate
        }
    return event


def _terminal_estimator_features(job: MapJob) -> dict[str, Any]:
    context = (
        job.preparation_estimator_context
        if isinstance(job.preparation_estimator_context, dict)
        else {}
    )
    evidence = context.get("evidence")
    evidence = evidence if isinstance(evidence, dict) else {}
    metrics = job.artifact_metrics if isinstance(job.artifact_metrics, dict) else {}
    scope = evidence.get("scope")
    if not isinstance(scope, dict):
        scope = metrics.get("buildingScope")
    scope = scope if isinstance(scope, dict) else {}
    dependencies = evidence.get("dependencies")
    dependencies = dependencies if isinstance(dependencies, dict) else {}
    preprocessing = metrics.get("buildingPreprocessing")
    preprocessing = preprocessing if isinstance(preprocessing, dict) else {}
    source_index = dependencies.get("sourceIndex") or preprocessing.get("sourceIndex")
    source_index = source_index if isinstance(source_index, dict) else {}
    closure = dependencies.get("closure") or preprocessing.get("closure")
    closure = closure if isinstance(closure, dict) else {}
    complexity = evidence.get("complexity")
    if not isinstance(complexity, dict):
        complexity = metrics.get("buildingComplexity")
    complexity = complexity if isinstance(complexity, dict) else {}
    building = metrics.get("buildingBuild")
    building = building if isinstance(building, dict) else {}
    building_block_cache = building.get("blockCache")
    building_block_cache = (
        building_block_cache if isinstance(building_block_cache, dict) else {}
    )
    building_block_cache_outcome = _building_block_cache_outcome(
        building_block_cache
    )
    label = metrics.get("labelBuild")
    label = label if isinstance(label, dict) else {}
    calibration = preprocessing.get("calibrationGenerationExecution")
    if not isinstance(calibration, dict):
        calibration = preprocessing.get("calibrationExecution")
    calibration = calibration if isinstance(calibration, dict) else {}
    cache_outcome = dependencies.get("cacheOutcome") or calibration.get(
        "cacheOutcome"
    )
    relation_retries = preprocessing.get("relationRetries")
    relation_retry_count = (
        len(relation_retries) if isinstance(relation_retries, list) else None
    )
    if job.reuse_strategy == "exact":
        outcome = "exact_reuse"
    elif job.reuse_strategy == "subset":
        outcome = "subset_reuse"
    elif job.status != JobStatus.READY:
        outcome = "failure"
    elif job.attempts > 1:
        outcome = "retry"
    else:
        outcome = "full_build"
    estimate = job.preparation_estimate or {}
    remaining = estimate.get("remaining")
    remaining = remaining if isinstance(remaining, dict) else {}
    is_initial = estimate.get("revision") == 1
    selected = (job.building_preprocessing_mode or context.get("preprocessingMode"))
    return {
        "source_region_id": job.source_region.id,
        "source_provider": job.source_region.provider,
        "preprocessing_mode": selected,
        "scope_policy_version": 1 if scope else None,
        "performance_compatibility_key": context.get(
            "performanceCompatibilityKey"
        ),
        "estimator_model_version": context.get("modelVersion"),
        "producer_build_sha256": context.get("producerBuildSha256"),
        "producer_image_digest": context.get("producerImageDigest"),
        "worker_class": context.get("workerClass"),
        "output_block_count": _nonnegative_integer(scope.get("outputBlockCount")),
        "output_area_m2": _nonnegative_integer(scope.get("outputAreaM2")),
        "source_area_m2": _nonnegative_integer(scope.get("sourceAreaM2")),
        "source_bytes": _nonnegative_integer(
            dependencies.get("sourceBytes", preprocessing.get("sourceBytes"))
        ),
        "source_expansion_basis_points": _nonnegative_integer(
            scope.get("sourceToOutputAreaBasisPoints")
        ),
        "calibration_cache_outcome": (
            cache_outcome if isinstance(cache_outcome, str) else None
        ),
        "building_block_cache_outcome": building_block_cache_outcome,
        "building_block_cache_hit_count": _nonnegative_integer(
            building_block_cache.get("initialHitCount")
        ),
        "building_block_cache_miss_count": _nonnegative_integer(
            building_block_cache.get("initialMissCount")
        ),
        "closure_candidate_count": _nonnegative_integer(
            closure.get("candidateCount")
        ),
        "closure_way_count": _nonnegative_integer(closure.get("wayCount")),
        "closure_node_count": _nonnegative_integer(closure.get("nodeCount")),
        "closure_relation_count": _nonnegative_integer(
            closure.get("relationCount")
        ),
        "relation_retry_count": relation_retry_count,
        "building_source_count": _nonnegative_integer(
            complexity.get("sourceCount", building.get("sourceCount"))
        ),
        "building_outline_count": _nonnegative_integer(
            complexity.get("outlineCount", building.get("outlineCount"))
        ),
        "building_part_count": _nonnegative_integer(
            complexity.get("partCount", building.get("partCount"))
        ),
        "building_unresolved_part_count": _nonnegative_integer(
            complexity.get(
                "unresolvedPartCount", building.get("unassociatedPartCount")
            )
        ),
        "building_containment_count": _nonnegative_integer(
            building.get("containmentAssociationCount")
        ),
        "building_point_count": _nonnegative_integer(
            complexity.get("sourceVertexCount", building.get("pointCount"))
        ),
        "label_candidate_count": _nonnegative_integer(label.get("candidates")),
        "outcome_class": outcome,
        "initial_estimate_lower_seconds": (
            _nonnegative_integer(remaining.get("lowerSeconds")) if is_initial else None
        ),
        "initial_estimate_upper_seconds": (
            _nonnegative_integer(remaining.get("upperSeconds")) if is_initial else None
        ),
        "final_estimate_lower_seconds": _nonnegative_integer(
            remaining.get("lowerSeconds")
        ),
        "final_estimate_upper_seconds": _nonnegative_integer(
            remaining.get("upperSeconds")
        ),
    }


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


def _cohort_summary(rows: list[sqlite3.Row]) -> dict[str, Any]:
    groups: dict[str, int] = {}
    for row in rows:
        renderer = row["renderer_format_version"]
        mode = row["preprocessing_mode"] or "unknown"
        outcome = row["outcome_class"] or "unknown"
        cache = row["calibration_cache_outcome"] or "unknown"
        building_cache = row["building_block_cache_outcome"] or "unknown"
        blocks = row["output_block_count"]
        block_bucket = _block_bucket(blocks)
        density_bucket = _density_bucket(
            row["building_source_count"], row["source_area_m2"]
        )
        performance = row["performance_compatibility_key"]
        performance_prefix = (
            str(performance)[:12] if performance is not None else "unknown"
        )
        key = "/".join(
            [
                f"renderer-{renderer if renderer is not None else 'unknown'}",
                str(mode),
                str(outcome),
                str(cache),
                f"block-cache-{building_cache}",
                f"blocks-{block_bucket}",
                f"density-{density_bucket}",
                f"profile-{performance_prefix}",
            ]
        )
        groups[key] = groups.get(key, 0) + 1
    return {"count": len(rows), "byCohort": dict(sorted(groups.items()))}


def _revision_summary(rows: list[sqlite3.Row]) -> dict[str, Any]:
    by_state: dict[str, int] = {}
    by_confidence: dict[str, int] = {}
    by_model: dict[str, int] = {}
    by_job: dict[str, int] = {}
    latencies: list[float] = []
    for row in rows:
        state = str(row["state"])
        by_state[state] = by_state.get(state, 0) + 1
        if row["confidence"] is not None:
            confidence = str(row["confidence"])
            by_confidence[confidence] = by_confidence.get(confidence, 0) + 1
        model = str(row["model_version"])
        by_model[model] = by_model.get(model, 0) + 1
        job_id = str(row["job_id"])
        by_job[job_id] = by_job.get(job_id, 0) + 1
        if (
            row["completed_epoch"] is not None
            and _is_finite_number(row["completed_epoch"])
        ):
            latency = float(row["completed_epoch"]) - float(
                row["generated_epoch"]
            )
            if latency >= 0:
                latencies.append(latency)
    return {
        "count": len(rows),
        "jobCount": len(by_job),
        "maximumRevisionsPerJob": max(by_job.values(), default=0),
        "byState": dict(sorted(by_state.items())),
        "byConfidence": dict(sorted(by_confidence.items())),
        "byModelVersion": dict(sorted(by_model.items())),
        "revisionToReadySeconds": _statistics(latencies),
    }


def _estimate_accuracy(rows: list[sqlite3.Row]) -> dict[str, Any]:
    actuals: list[float] = []
    absolute_errors: list[float] = []
    widths: list[float] = []
    underprediction_ratios: list[float] = []
    overprediction_ratios: list[float] = []
    inside = 0
    below_upper = 0
    for row in rows:
        if (
            row["state"] != "available"
            or row["terminal_status"] != JobStatus.READY.value
            or row["completed_epoch"] is None
            or row["lower_seconds"] is None
            or row["upper_seconds"] is None
        ):
            continue
        actual = float(row["completed_epoch"]) - float(row["generated_epoch"])
        lower = float(row["lower_seconds"])
        upper = float(row["upper_seconds"])
        if actual < 0 or not all(
            _is_finite_number(value) for value in (actual, lower, upper)
        ):
            continue
        actuals.append(actual)
        absolute_errors.append(abs(actual - (lower + upper) / 2))
        widths.append(upper - lower)
        if lower <= actual <= upper:
            inside += 1
        if actual <= upper:
            below_upper += 1
        underprediction_ratios.append(actual / max(upper, 1.0))
        overprediction_ratios.append(upper / max(actual, 1.0))
    count = len(actuals)
    return {
        "count": count,
        "intervalCoverage": round(inside / count, 6) if count else None,
        "upperBoundCoverage": round(below_upper / count, 6) if count else None,
        "absoluteErrorSeconds": _statistics(absolute_errors),
        "rangeWidthSeconds": _statistics(widths),
        "underpredictionRatio": _number_statistics(underprediction_ratios),
        "overpredictionRatio": _number_statistics(overprediction_ratios),
    }


def _estimate_model_comparison(rows: list[sqlite3.Row]) -> dict[str, Any]:
    baseline_rows = []
    historical_rows = []
    for row in rows:
        try:
            basis = json.loads(row["basis_json"])
        except (json.JSONDecodeError, TypeError):
            continue
        if not isinstance(basis, list):
            continue
        if "historical_cohort" in basis:
            historical_rows.append(row)
        else:
            baseline_rows.append(row)
    return {
        "baselineOnly": _estimate_accuracy(baseline_rows),
        "historicalCohort": _estimate_accuracy(historical_rows),
    }


def _estimate_exclusions(rows: list[sqlite3.Row]) -> dict[str, int]:
    exclusions: dict[str, int] = {}
    for row in rows:
        reasons = []
        if row["status"] != JobStatus.READY.value:
            reasons.append("non_ready")
        if int(row["attempts"]) != 1:
            reasons.append("retry")
        if row["performance_compatibility_key"] is None:
            reasons.append("missing_performance_key")
        if row["preprocessing_mode"] is None:
            reasons.append("missing_preprocessing_mode")
        if row["outcome_class"] is None:
            reasons.append("missing_outcome_class")
        for reason in reasons:
            exclusions[reason] = exclusions.get(reason, 0) + 1
    return dict(sorted(exclusions.items()))


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


def _number_statistics(values: list[float]) -> dict[str, Any]:
    if not values:
        return {"count": 0, "p50": None, "p95": None, "max": None}
    ordered = sorted(values)
    return {
        "count": len(ordered),
        "p50": round(_percentile(ordered, 50), 6),
        "p95": round(_percentile(ordered, 95), 6),
        "max": round(ordered[-1], 6),
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


def _nonnegative_integer(value: Any) -> int | None:
    if (
        isinstance(value, int)
        and not isinstance(value, bool)
        and 0 <= value <= 9_000_000_000_000_000
    ):
        return value
    return None


def _building_block_cache_outcome(value: Any) -> str | None:
    if not isinstance(value, dict):
        return None
    requested = _nonnegative_integer(value.get("requestedBlockCount"))
    hits = _nonnegative_integer(value.get("initialHitCount"))
    misses = _nonnegative_integer(value.get("initialMissCount"))
    if (
        requested is None
        or requested <= 0
        or hits is None
        or misses is None
        or hits + misses != requested
    ):
        return None
    if misses == 0:
        return "full_hit"
    if hits == 0:
        return "cold_miss"
    return "partial_hit"


def _block_bucket(value: Any) -> str:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        return "unknown"
    if value <= 1:
        return "1"
    if value <= 4:
        return "2-4"
    if value <= 8:
        return "5-8"
    return "9+"


def _density_bucket(building_count: Any, area_m2: Any) -> str:
    if (
        not isinstance(building_count, int)
        or isinstance(building_count, bool)
        or building_count < 0
        or not isinstance(area_m2, int)
        or isinstance(area_m2, bool)
        or area_m2 <= 0
    ):
        return "unknown"
    per_km2 = building_count * 1_000_000 / area_m2
    if per_km2 < 100:
        return "sparse"
    if per_km2 < 500:
        return "medium"
    if per_km2 < 2_000:
        return "dense"
    return "very_dense"


def _neighboring_bucket(value: str, candidate: str, ordering: tuple[str, ...]) -> bool:
    if value == "unknown":
        return True
    if candidate == "unknown":
        return False
    try:
        return abs(ordering.index(value) - ordering.index(candidate)) <= 1
    except ValueError:
        return False


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
