from __future__ import annotations

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
