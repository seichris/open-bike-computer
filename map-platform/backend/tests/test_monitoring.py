from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from map_platform.models import (
    Bounds,
    GeometryMode,
    JobStatus,
    MapJob,
    NormalizedGeometry,
    SourceRegion,
)
from map_platform.monitoring import (
    MapMonitoringStore,
    MonitoringSchemaError,
    build_map_job_monitoring_event,
)


def iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="microseconds").replace(
        "+00:00", "Z"
    )


def build_job(
    job_id: str,
    *,
    now: datetime,
    processing_seconds: float,
    renderer_format: int = 3,
    status: JobStatus = JobStatus.READY,
) -> MapJob:
    finished = now - timedelta(seconds=processing_seconds)
    started = finished - timedelta(seconds=processing_seconds)
    created = started - timedelta(seconds=3)
    return MapJob(
        job_id=job_id,
        status=status,
        request={
            "mode": "custom_bbox",
            "target": {
                "renderer": "esp32-fmb",
                "rendererFormatVersion": renderer_format,
            },
        },
        geometry=NormalizedGeometry(
            mode=GeometryMode.CUSTOM_BBOX,
            bounds=Bounds(103.75, 1.24, 103.93, 1.37),
            area_km2=123.4,
            vertex_count=4,
        ),
        source_region=SourceRegion(
            id="sg",
            provider="test",
            name="Singapore",
            url="https://example.invalid/singapore.osm.pbf",
            bounds=Bounds(103.0, 1.0, 104.5, 1.8),
        ),
        created_at=iso(created),
        updated_at=iso(finished),
        started_at=iso(started),
        finished_at=iso(finished),
        attempts=1,
        events=[
            {"at": iso(started), "status": JobStatus.VALIDATING.value},
            {
                "at": iso(finished - timedelta(seconds=1)),
                "status": JobStatus.CONVERTING_FEATURES.value,
            },
            {"at": iso(finished), "status": status.value},
        ],
    )


class MapMonitoringStoreTests(unittest.TestCase):
    def test_history_prefers_exact_region_scope_density_and_cache_cohort(self):
        now = datetime(2026, 8, 10, 4, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            store = MapMonitoringStore(
                Path(tmp) / "map-monitoring.sqlite3",
                clock=lambda: now.timestamp(),
            )
            singapore = build_job(
                "cohort-singapore", now=now, processing_seconds=90
            )
            shanghai = build_job(
                "cohort-shanghai", now=now, processing_seconds=30
            )
            shanghai.source_region = SourceRegion(
                id="china/shanghai",
                provider="geofabrik",
                name="Shanghai",
                url="https://example.invalid/shanghai.osm.pbf",
                bounds=Bounds(120.8, 30.6, 122.2, 31.9),
            )
            for job in (singapore, shanghai):
                job.building_preprocessing_mode = "selected"
                job.preparation_estimator_context = {
                    "performanceCompatibilityKey": "a" * 64,
                    "preprocessingMode": "selected",
                    "modelVersion": "map-preparation-v1",
                    "workerClass": "test",
                    "evidence": {
                        "scope": {
                            "outputBlockCount": 6,
                            "sourceAreaM2": 100_000_000,
                        },
                        "dependencies": {"cacheOutcome": "hit"},
                        "complexity": {"sourceCount": 50_000},
                    },
                }
                self.assertTrue(store.record_job(job))

            samples = store.estimate_samples(
                performance_key="a" * 64,
                renderer=3,
                preprocessing_mode="selected",
                outcome_class="full_build",
                claimed=True,
                source_region_id="sg",
                output_block_count=6,
                source_area_m2=100_000_000,
                building_source_count=50_000,
                cache_outcome="hit",
                minimum_samples=1,
            )
            queued_samples = store.estimate_samples(
                performance_key="a" * 64,
                renderer=3,
                preprocessing_mode="selected",
                outcome_class="full_build",
                claimed=False,
                source_region_id="sg",
                output_block_count=6,
                source_area_m2=100_000_000,
                building_source_count=50_000,
                cache_outcome="hit",
                minimum_samples=1,
            )

        self.assertEqual(samples, [90.0])
        self.assertEqual(
            queued_samples,
            [90.0],
            "queued estimates keep historical work separate from queue delay",
        )

    def test_estimate_revisions_and_accuracy_are_bounded_and_aggregated(self):
        now = datetime(2026, 8, 10, 4, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            store = MapMonitoringStore(
                Path(tmp) / "map-monitoring.sqlite3",
                clock=lambda: now.timestamp(),
            )
            job = build_job(
                "estimate-accuracy",
                now=now,
                processing_seconds=30,
            )
            generated = now - timedelta(seconds=50)
            job.preparation_estimate = {
                "schemaVersion": 1,
                "modelVersion": "map-preparation-v1",
                "revision": 1,
                "state": "available",
                "generatedAt": iso(generated),
                "attempt": 1,
                "basedOnPhase": "building_complexity",
                "confidence": "medium",
                "remaining": {"lowerSeconds": 10, "upperSeconds": 30},
                "basis": ["baseline_profile", "feature_complexity"],
                "sampleCount": 24,
            }
            job.preparation_estimator_context = {
                "performanceCompatibilityKey": "a" * 64,
                "preprocessingMode": "selected",
                "modelVersion": "map-preparation-v1",
                "workerClass": "test",
                "evidence": {},
            }
            self.assertTrue(store.record_estimate_revision(job))
            self.assertFalse(store.record_estimate_revision(job))
            job.preparation_estimate = {
                **job.preparation_estimate,
                "revision": 2,
                "generatedAt": iso(now - timedelta(seconds=35)),
                "remaining": {"lowerSeconds": 5, "upperSeconds": 10},
            }
            self.assertTrue(store.record_estimate_revision(job))
            self.assertTrue(store.record_job(job))
            summary = store.summary(window_hours=24)
            with sqlite3.connect(store.path) as connection:
                initial_lower, initial_upper, final_lower, final_upper = (
                    connection.execute(
                        """
                        SELECT initial_estimate_lower_seconds,
                               initial_estimate_upper_seconds,
                               final_estimate_lower_seconds,
                               final_estimate_upper_seconds
                        FROM map_build_runs WHERE job_id = ?
                        """,
                        (job.job_id,),
                    ).fetchone()
                )

        self.assertEqual(summary["schemaVersion"], 2)
        self.assertEqual(summary["estimateRevisions"]["count"], 2)
        self.assertEqual(summary["estimateAccuracy"]["count"], 2)
        self.assertEqual(summary["estimateAccuracy"]["intervalCoverage"], 1.0)
        self.assertEqual(summary["estimateAccuracy"]["upperBoundCoverage"], 1.0)
        self.assertEqual(
            summary["estimateModelComparison"]["baselineOnly"]["count"], 2
        )
        self.assertEqual(
            summary["estimateModelComparison"]["historicalCohort"]["count"], 0
        )
        self.assertEqual((initial_lower, initial_upper), (10, 30))
        self.assertEqual((final_lower, final_upper), (5, 10))

    def test_revision_summary_samples_the_most_recent_bounded_window(self):
        now = datetime(2026, 8, 10, 4, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            store = MapMonitoringStore(
                Path(tmp) / "map-monitoring.sqlite3",
                summary_run_limit=1,
                max_estimate_revisions=16,
                clock=lambda: now.timestamp(),
            )
            for sequence, model in enumerate(("older-model", "newer-model")):
                job = build_job(
                    f"revision-window-{sequence}",
                    now=now,
                    processing_seconds=30,
                )
                job.preparation_estimator_context = {
                    "performanceCompatibilityKey": "a" * 64,
                    "preprocessingMode": "selected",
                    "modelVersion": model,
                    "workerClass": "test",
                    "evidence": {},
                }
                for revision in range(1, 17):
                    generated = now - timedelta(
                        hours=2 - sequence,
                        seconds=17 - revision,
                    )
                    job.preparation_estimate = {
                        "schemaVersion": 1,
                        "modelVersion": model,
                        "revision": revision,
                        "state": "available",
                        "generatedAt": iso(generated),
                        "attempt": 1,
                        "basedOnPhase": "block_encoding",
                        "confidence": "low",
                        "remaining": {
                            "lowerSeconds": 10,
                            "upperSeconds": 20,
                        },
                        "basis": ["baseline_profile"],
                        "sampleCount": 0,
                    }
                    self.assertTrue(store.record_estimate_revision(job))

            summary = store.summary(window_hours=24)

        self.assertEqual(summary["estimateRevisions"]["count"], 16)
        self.assertEqual(
            summary["estimateRevisions"]["byModelVersion"],
            {"newer-model": 16},
        )

    def test_job_timing_and_summary_survive_store_reopen(self):
        now = datetime(2026, 8, 6, 4, 0, tzinfo=timezone.utc)
        now_epoch = now.timestamp()
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "map-monitoring.sqlite3"
            store = MapMonitoringStore(path, clock=lambda: now_epoch)
            jobs = [
                build_job(
                    f"job-{duration}",
                    now=now,
                    processing_seconds=duration,
                    renderer_format=3 if duration != 20 else 1,
                )
                for duration in (10, 20, 40)
            ]

            self.assertEqual(store.sync_jobs(jobs), 3)
            reopened = MapMonitoringStore(path, clock=lambda: now_epoch)
            summary = reopened.summary(window_hours=24)

        self.assertEqual(summary["runs"]["count"], 3)
        self.assertEqual(summary["serverTiming"]["processingSeconds"]["p50Seconds"], 20.0)
        self.assertEqual(summary["serverTiming"]["processingSeconds"]["p95Seconds"], 38.0)
        self.assertEqual(summary["byRendererFormat"]["3"]["runs"]["count"], 2)
        self.assertEqual(
            summary["phaseTimings"]["converting_features"]["count"],
            3,
        )

    def test_prune_removes_only_old_monitoring_samples(self):
        now = datetime(2026, 8, 6, 4, 0, tzinfo=timezone.utc)
        now_epoch = now.timestamp()
        with tempfile.TemporaryDirectory() as tmp:
            store = MapMonitoringStore(
                Path(tmp) / "map-monitoring.sqlite3",
                retention_days=3_650,
                clock=lambda: now_epoch,
            )
            self.assertTrue(
                store.record_job(
                    build_job(
                        "old",
                        now=now - timedelta(days=100),
                        processing_seconds=10,
                    )
                )
            )
            self.assertTrue(
                store.record_job(
                    build_job("new", now=now, processing_seconds=10)
                )
            )

            self.assertEqual(store.prune(older_than_days=90), 1)
            self.assertEqual(store.summary(window_hours=24)["runs"]["count"], 1)

    def test_retention_prune_cannot_be_undone_by_later_reconciliation(self):
        now = datetime(2026, 8, 6, 4, 0, tzinfo=timezone.utc)
        clock = [now.timestamp()]
        with tempfile.TemporaryDirectory() as tmp:
            store = MapMonitoringStore(
                Path(tmp) / "map-monitoring.sqlite3",
                retention_days=1,
                clock=lambda: clock[0],
            )
            job = build_job("old-after-clock-advance", now=now, processing_seconds=10)
            self.assertTrue(store.record_job(job))

            clock[0] += 2 * 86_400
            self.assertEqual(
                store.reconcile_jobs([job]),
                {"synced": 0, "removed": 1},
            )
            self.assertEqual(store.summary(window_hours=24)["runs"]["count"], 0)
            self.assertEqual(store.summary(window_hours=24)["retainedRunCount"], 0)

    def test_summary_clamps_to_retention_and_samples_recent_runs(self):
        now = datetime(2026, 8, 6, 4, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            store = MapMonitoringStore(
                Path(tmp) / "map-monitoring.sqlite3",
                retention_days=10,
                summary_run_limit=2,
                clock=lambda: now.timestamp(),
            )
            for duration in (1, 2, 3, 4):
                self.assertTrue(
                    store.record_job(
                        build_job(
                            f"sample-{duration}",
                            now=now,
                            processing_seconds=duration,
                        )
                    )
                )

            summary = store.summary(window_hours=24 * 365)

        self.assertEqual(summary["windowHours"], 10 * 24)
        self.assertEqual(summary["matchingRunCount"], 4)
        self.assertEqual(summary["sampledRunCount"], 2)
        self.assertEqual(summary["configuredRunLimit"], 2)
        self.assertTrue(summary["truncated"])
        self.assertEqual(summary["samplingStrategy"], "most_recent_completion_desc")
        self.assertEqual(summary["runs"]["count"], 2)

    def test_schema_version_adopts_unversioned_v2_and_rejects_future_schema(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "map-monitoring.sqlite3"
            MapMonitoringStore(path)
            with sqlite3.connect(path) as connection:
                connection.execute("PRAGMA user_version = 0")

            MapMonitoringStore(path)
            with sqlite3.connect(path) as connection:
                self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 1)
                indexes = {
                    row[1] for row in connection.execute(
                        "PRAGMA index_list(map_build_runs)"
                    )
                }
                self.assertIn("map_build_runs_completed_desc", indexes)
                connection.execute("PRAGMA user_version = 3")

            with self.assertRaises(MonitoringSchemaError):
                MapMonitoringStore(path)

    def test_v1_schema_migrates_transactionally_and_preserves_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "map-monitoring.sqlite3"
            with sqlite3.connect(path) as connection:
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
                    """
                    INSERT INTO map_build_runs VALUES(
                        'legacy-job', 'ready', '2026-08-10T00:00:00Z',
                        1786320000, '2026-08-09T23:59:00Z',
                        '2026-08-09T23:59:10Z', '2026-08-10T00:00:00Z',
                        10, 50, 60, 1, 3, 'custom_bbox', 23.84, NULL, '[]'
                    )
                    """
                )
                connection.execute("PRAGMA user_version = 1")

            MapMonitoringStore(path, clock=lambda: 1_786_320_100)
            with sqlite3.connect(path) as connection:
                self.assertEqual(
                    connection.execute("PRAGMA user_version").fetchone()[0], 1
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT status FROM map_build_runs WHERE job_id = 'legacy-job'"
                    ).fetchone()[0],
                    "ready",
                )
                revision_columns = {
                    row[1]
                    for row in connection.execute(
                        "PRAGMA table_info(map_estimate_revisions)"
                    )
                }
                self.assertIn("performance_compatibility_key", revision_columns)

    def test_schema_validation_rejects_incompatible_legacy_database(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "map-monitoring.sqlite3"
            with sqlite3.connect(path) as connection:
                connection.execute("CREATE TABLE map_build_runs(job_id TEXT PRIMARY KEY)")

            with self.assertRaises(MonitoringSchemaError):
                MapMonitoringStore(path)

    def test_phase_history_is_ordered_across_retries_and_legacy_records(self):
        now = datetime(2026, 8, 6, 4, 0, tzinfo=timezone.utc)
        job = build_job("retry-history", now=now, processing_seconds=10)
        job.started_at = "2026-08-06T00:05:00+00:00"
        job.finished_at = "2026-08-06T00:20:00Z"
        job.events = [
            {"at": "2026-08-06T00:00:00Z", "status": "queued"},
            {"at": "2026-08-06T00:05:00Z", "status": "validating"},
            {"at": "2026-08-06T00:06:00Z", "status": "validating"},
            {"at": "2026-08-06T00:07:00Z", "status": "queued"},
            {"at": "2026-08-06T00:08:00Z", "status": "validating"},
            {"at": "2026-08-06T00:10:00Z", "status": "converting_features"},
            {"at": "2026-08-06T00:20:00Z", "status": "ready"},
        ]

        timings = job.phase_timings()
        self.assertEqual(
            [timing["status"] for timing in timings],
            ["queued", "validating", "queued", "validating", "converting_features", "ready"],
        )
        self.assertTrue(
            all(
                timing.get("durationSeconds", 0) >= 0
                for timing in timings
            )
        )

        legacy = build_job("legacy-history", now=now, processing_seconds=10)
        legacy.events = [{"at": "2026-08-06T00:00:00Z", "status": "queued"}]
        legacy.started_at = "2026-08-06T00:05:00Z"
        legacy.finished_at = "2026-08-06T00:10:00Z"
        self.assertEqual(
            [timing["status"] for timing in legacy.phase_timings()],
            ["queued", "validating"],
        )

    def test_legacy_naive_timestamps_are_treated_as_utc(self):
        job = build_job(
            "naive-timestamps",
            now=datetime(2026, 8, 6, 4, 0, tzinfo=timezone.utc),
            processing_seconds=10,
        )
        job.created_at = "2026-08-06T00:00:00"
        job.started_at = "2026-08-06T00:00:05+00:00"
        job.finished_at = "2026-08-06T00:00:10"

        response = job.to_dict()
        self.assertEqual(response["serverTiming"]["queueWaitSeconds"], 5.0)
        self.assertEqual(response["serverTiming"]["processingSeconds"], 5.0)
        self.assertEqual(response["serverTiming"]["totalSeconds"], 10.0)

    def test_nonfinite_optional_phase_metrics_are_ignored(self):
        job = build_job(
            "nonfinite-metrics",
            now=datetime(2026, 8, 6, 4, 0, tzinfo=timezone.utc),
            processing_seconds=10,
        )
        job.artifact_metrics = {
            "labelPhaseTimings": {
                "nan": float("nan"),
                "infinity": float("inf"),
                "negative": -1,
                "boolean": True,
                "valid": 1.25,
            },
            "buildingPhaseTimings": {
                "preprocessing": 2.5,
                "bad": float("nan"),
            },
        }

        phases = job.phase_timings()
        self.assertEqual(
            [phase["status"] for phase in phases if phase["status"] in {
                "nan", "infinity", "negative", "boolean", "valid"
            }],
            ["valid"],
        )
        self.assertIn(
            {"status": "building_preprocessing", "durationSeconds": 2.5},
            phases,
        )
        with tempfile.TemporaryDirectory() as tmp:
            store = MapMonitoringStore(Path(tmp) / "map-monitoring.sqlite3")
            self.assertTrue(store.record_job(job))
            json.dumps(store.summary(), allow_nan=False)

    def test_monitoring_event_contains_safe_structured_timing(self):
        now = datetime(2026, 8, 6, 4, 0, tzinfo=timezone.utc)
        job = build_job("event-job", now=now, processing_seconds=10)
        event = build_map_job_monitoring_event(
            job,
            "worker-test",
            attempt_started_at=job.started_at,
            outcome="built",
        )

        self.assertEqual(event["event"], "map_job_run_completed")
        self.assertEqual(event["jobId"], "event-job")
        self.assertEqual(event["rendererFormatVersion"], 3)
        self.assertEqual(event["outcome"], "built")
        self.assertNotIn("request", event)
        self.assertGreater(event["attemptTiming"]["durationSeconds"], 0)


if __name__ == "__main__":
    unittest.main()
