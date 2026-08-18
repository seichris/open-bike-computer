from __future__ import annotations

import json
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from map_platform.cli import (
    MaintenanceIterationError,
    _perform_maintenance,
    _pipeline_producer_identity,
    _safe_error_summary,
)
from map_platform.jobs import ArtifactGarbageCollectionError
from map_platform.map_stream_build_identity import MapStreamBuildIdentity
from map_platform.worker import (
    ExpiredArtifactCleanupError,
    WorkDirectoryCleanupError,
)


class PipelineProducerIdentityTests(unittest.TestCase):
    @patch("map_platform.cli.verify_map_stream_build_identity")
    @patch("map_platform.cli.image_digest_from_reference")
    def test_loads_identity_when_map_stream_signing_is_disabled(
        self,
        image_digest_from_reference,
        verify_map_stream_build_identity,
    ):
        image_digest_from_reference.return_value = "sha256:" + "2" * 64
        verify_map_stream_build_identity.return_value = MapStreamBuildIdentity(
            producer_build_sha256="1" * 64
        )

        result = _pipeline_producer_identity(
            Path("/app"),
            "registry.example/map@sha256:" + "2" * 64,
            required=False,
        )

        self.assertEqual(result, ("1" * 64, "sha256:" + "2" * 64))
        verify_map_stream_build_identity.assert_called_once_with(
            Path("/app/map-platform/config/map-stream-build-identity.json"),
            Path("/app"),
        )

    @patch("map_platform.cli.image_digest_from_reference")
    def test_optional_identity_fails_closed_without_blocking_builds(
        self,
        image_digest_from_reference,
    ):
        image_digest_from_reference.side_effect = ValueError("not pinned")

        self.assertEqual(
            _pipeline_producer_identity(
                Path("/app"),
                "open-bike-map-platform:local",
                required=False,
            ),
            (None, None),
        )

    @patch("map_platform.cli.image_digest_from_reference")
    def test_signed_streams_still_require_a_valid_identity(
        self,
        image_digest_from_reference,
    ):
        image_digest_from_reference.side_effect = ValueError("not pinned")

        with self.assertRaisesRegex(ValueError, "not pinned"):
            _pipeline_producer_identity(
                Path("/app"),
                "open-bike-map-platform:local",
                required=True,
            )


class MaintenanceTests(unittest.TestCase):
    def test_error_summary_never_logs_arbitrary_exception_text(self):
        sentinel = "supersecretvalue"
        messages = [
            f"Authorization: Bearer {sentinel}",
            f"X-Authorization: Basic {sentinel}",
            f"AWS_SECRET_ACCESS_KEY={sentinel}",
            f"access_token={sentinel}",
            f"client-secret='{sentinel}'",
            f"token {sentinel}",
            f"https://user:{sentinel}@example.invalid/delete",
            f"https://example.invalid/delete?signature={sentinel}",
            f"token={sentinel} password={sentinel}",
        ]
        for message in messages:
            with self.subTest(message=message):
                summary = _safe_error_summary(RuntimeError(message))
                self.assertNotIn(sentinel, json.dumps(summary))
                self.assertNotIn("message", summary)

        inner = PermissionError(13, f"Authorization: Bearer {sentinel}")
        outer = RuntimeError(f"credential={sentinel}")
        outer.__cause__ = inner
        summary = _safe_error_summary(outer)
        self.assertEqual(summary["category"], "permission_denied")
        self.assertEqual(summary["causeTypes"], ["PermissionError"])
        self.assertEqual(summary["errno"], 13)
        self.assertNotIn(sentinel, json.dumps(summary))

    @patch(
        "map_platform.cli.prune_building_block_cache",
        return_value={
            "removedNamespaces": 1,
            "removedBytes": 200,
            "retainedBytes": 300,
            "skippedLeasedNamespaces": 0,
        },
    )
    @patch("map_platform.cli.purge_expired_rate_limits", return_value=3)
    @patch("map_platform.cli.cleanup_work_dirs", return_value=2)
    @patch("map_platform.cli.expire_ready_jobs", return_value=1)
    def test_iteration_runs_retention_work_and_idle_rate_limit_cleanup(
        self,
        expire_ready_jobs,
        cleanup_work_dirs,
        purge_expired_rate_limits,
        prune_building_block_cache,
    ):
        store = Mock()
        artifact_store = Mock()
        result = _perform_maintenance(
            store,
            Path("/data"),
            retention_days=30,
            artifact_store=artifact_store,
            max_gc_items=100,
        )

        self.assertEqual(
            result,
            {
                "maintenance": True,
                "expired": 1,
                "removedWorkDirs": 2,
                "removedRateLimits": 3,
                "buildingBlockCache": {
                    "removedNamespaces": 1,
                    "removedBytes": 200,
                    "retainedBytes": 300,
                    "skippedLeasedNamespaces": 0,
                },
            },
        )
        expire_ready_jobs.assert_called_once_with(
            store,
            older_than_days=30,
            artifact_store=artifact_store,
            max_gc_items=100,
        )
        cleanup_work_dirs.assert_called_once_with(Path("/data/work"), store)
        purge_expired_rate_limits.assert_called_once_with(
            Path("/data/rate-limits.sqlite3")
        )
        prune_building_block_cache.assert_called_once_with(
            Path("/data/building-cache"),
            older_than_days=14,
            max_bytes=20 * 1024 * 1024 * 1024,
            max_items=100,
        )

    @patch("map_platform.cli.purge_expired_rate_limits", return_value=3)
    @patch("map_platform.cli.cleanup_work_dirs", return_value=2)
    @patch(
        "map_platform.cli.expire_ready_jobs",
        side_effect=ExpiredArtifactCleanupError(
            removed=1,
            expired_jobs=2,
            legacy_failures=[
                (
                    Path("/data/packs/legacy-failed.zip"),
                    PermissionError("token=private legacy delete blocked"),
                )
            ],
            object_failure=ArtifactGarbageCollectionError(
                removed=1,
                failures=[
                    (
                        "maps/map/stream/failed.bmap",
                        PermissionError(
                            "https://objects.invalid/delete?signature=private "
                            "artifact delete blocked"
                        ),
                    )
                ],
            ),
        ),
    )
    def test_artifact_delete_failure_still_runs_privacy_cleanup_and_fails_health(
        self,
        expire_ready_jobs,
        cleanup_work_dirs,
        purge_expired_rate_limits,
    ):
        with self.assertRaises(MaintenanceIterationError) as context:
            _perform_maintenance(
                Mock(),
                Path("/data"),
                retention_days=30,
                artifact_store=Mock(),
                max_gc_items=100,
            )

        result = context.exception.result
        self.assertEqual(result["expired"], 2)
        self.assertEqual(result["removedWorkDirs"], 2)
        self.assertEqual(result["removedRateLimits"], 3)
        failure = result["failures"]["expired"]
        self.assertEqual(
            failure["failedLegacyPacks"][0]["path"],
            "packs/legacy-failed.zip",
        )
        self.assertEqual(
            failure["failedLegacyPacks"][0]["cause"]["type"],
            "PermissionError",
        )
        self.assertEqual(
            failure["failedObjects"][0]["key"],
            "maps/map/stream/failed.bmap",
        )
        self.assertNotIn("private", json.dumps(failure))
        expire_ready_jobs.assert_called_once()
        cleanup_work_dirs.assert_called_once()
        purge_expired_rate_limits.assert_called_once()

    @patch("map_platform.cli.purge_expired_rate_limits", return_value=3)
    @patch("map_platform.cli.cleanup_work_dirs", return_value=2)
    @patch(
        "map_platform.cli.expire_ready_jobs",
        side_effect=ExpiredArtifactCleanupError(
            removed=1,
            expired_jobs=2,
            legacy_failures=[
                (
                    Path("/data/packs/legacy-failed.zip"),
                    PermissionError("legacy delete blocked"),
                )
            ],
            object_failure=PermissionError("artifact GC cursor blocked"),
        ),
    )
    def test_non_delete_gc_failure_preserves_expiry_and_legacy_diagnostics(
        self,
        expire_ready_jobs,
        cleanup_work_dirs,
        purge_expired_rate_limits,
    ):
        with self.assertRaises(MaintenanceIterationError) as context:
            _perform_maintenance(
                Mock(),
                Path("/data"),
                retention_days=30,
                artifact_store=Mock(),
                max_gc_items=100,
            )

        result = context.exception.result
        self.assertEqual(result["expired"], 2)
        self.assertEqual(result["removedWorkDirs"], 2)
        self.assertEqual(result["removedRateLimits"], 3)
        failure = result["failures"]["expired"]
        self.assertEqual(
            failure["failedLegacyPacks"][0]["path"],
            "packs/legacy-failed.zip",
        )
        self.assertEqual(
            failure["artifactCleanupFailure"]["category"],
            "permission_denied",
        )
        purge_expired_rate_limits.assert_called_once()

    @patch("map_platform.cli.purge_expired_rate_limits", return_value=3)
    @patch("map_platform.cli.cleanup_work_dirs", return_value=2)
    @patch(
        "map_platform.cli.expire_ready_jobs",
        side_effect=ExpiredArtifactCleanupError(
            removed=1,
            expired_jobs=2,
            expiry_failures=[
                (
                    "job-blocked",
                    PermissionError(13, "job status write blocked"),
                )
            ],
            job_record_failures=[
                (
                    Path("/data/jobs/corrupt.json"),
                    json.JSONDecodeError("invalid", "{", 1),
                )
            ],
            legacy_failures=[],
            object_failure=None,
        ),
    )
    def test_expiry_write_failure_preserves_progress_and_independent_cleanup(
        self,
        expire_ready_jobs,
        cleanup_work_dirs,
        purge_expired_rate_limits,
    ):
        with self.assertRaises(MaintenanceIterationError) as context:
            _perform_maintenance(
                Mock(),
                Path("/data"),
                retention_days=30,
                artifact_store=Mock(),
                max_gc_items=100,
            )

        result = context.exception.result
        self.assertEqual(result["expired"], 2)
        self.assertEqual(result["removedWorkDirs"], 2)
        self.assertEqual(result["removedRateLimits"], 3)
        self.assertEqual(
            result["failures"]["expired"]["failedJobExpirations"],
            [
                {
                    "jobId": "job-blocked",
                    "cause": {
                        "type": "PermissionError",
                        "category": "permission_denied",
                        "errno": 13,
                    },
                }
            ],
        )
        self.assertEqual(
            result["failures"]["expired"]["failedJobRecords"],
            [
                {
                    "path": "jobs/corrupt.json",
                    "cause": {
                        "type": "JSONDecodeError",
                        "category": "external_error",
                    },
                }
            ],
        )
        cleanup_work_dirs.assert_called_once()
        purge_expired_rate_limits.assert_called_once()

    @patch("map_platform.cli.purge_expired_rate_limits", return_value=3)
    @patch(
        "map_platform.cli.cleanup_work_dirs",
        side_effect=WorkDirectoryCleanupError(
            removed=1,
            failures=[
                (
                    Path("/data/work/blocked"),
                    PermissionError("work cleanup blocked"),
                )
            ],
        ),
    )
    @patch("map_platform.cli.expire_ready_jobs", return_value=1)
    def test_failure_is_reported_after_every_independent_task_runs(
        self,
        expire_ready_jobs,
        cleanup_work_dirs,
        purge_expired_rate_limits,
    ):
        with self.assertRaises(MaintenanceIterationError) as context:
            _perform_maintenance(
                Mock(),
                Path("/data"),
                retention_days=30,
                artifact_store=Mock(),
                max_gc_items=100,
            )

        self.assertEqual(context.exception.result["expired"], 1)
        self.assertEqual(context.exception.result["removedWorkDirs"], 1)
        self.assertEqual(context.exception.result["removedRateLimits"], 3)
        self.assertEqual(
            context.exception.result["failures"]["removedWorkDirs"]
            ["failedWorkDirectories"][0],
            {
                "path": "work/blocked",
                "cause": {
                    "type": "PermissionError",
                    "category": "permission_denied",
                },
            },
        )
        expire_ready_jobs.assert_called_once()
        cleanup_work_dirs.assert_called_once()
        purge_expired_rate_limits.assert_called_once_with(
            Path("/data/rate-limits.sqlite3")
        )


if __name__ == "__main__":
    unittest.main()
