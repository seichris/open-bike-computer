from __future__ import annotations

from contextlib import redirect_stdout
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from map_platform.cli import (
    MaintenanceIterationError,
    _perform_maintenance,
    _pipeline_producer_identity,
    _safe_error_summary,
    main,
)
from map_platform.building_tasks import BuildingTaskSpec, BuildingTaskStore
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


class BuildingPlanCLITests(unittest.TestCase):
    def test_inspect_and_alerts_expose_bounded_parent_phase_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            data_root = Path(directory)
            store = BuildingTaskStore(data_root / "building-tasks.sqlite3")
            store.create_plan(
                parent_job_id="job-cli-parent-phase",
                global_plan_sha256="a" * 64,
                input_identity={},
                expected_output_block_count=1,
                policy_version=1,
                resource_model_version="v1",
            )
            store.add_tasks(
                [
                    BuildingTaskSpec(
                        task_id="task-cli-parent-phase",
                        parent_job_id="job-cli-parent-phase",
                        kind="building_chunk",
                        blocks=((1, 2),),
                        chunk_plan_sha256="a" * 64,
                    )
                ]
            )
            capability = {
                "memoryLimitBytes": 12_000_000_000,
                "cpuCount": 1,
                "resourcePool": "cli",
                "maxConcurrentTasks": 1,
            }
            reservation = store.acquire_parent_phase_reservation(
                parent_job_id="job-cli-parent-phase",
                phase="source_preparation",
                worker_id="worker-cli",
                worker_capability=capability,
                lease_seconds=1,
                now=1.0,
            )
            self.assertIsNotNone(reservation)
            repo_root = Path(__file__).resolve().parents[3]

            inspect_output = io.StringIO()
            with (
                patch(
                    "sys.argv",
                    [
                        "map-platform",
                        "--repo-root",
                        str(repo_root),
                        "--data-root",
                        str(data_root),
                        "build-plan",
                        "inspect",
                        "job-cli-parent-phase",
                        "--limit",
                        "1",
                    ],
                ),
                redirect_stdout(inspect_output),
            ):
                self.assertEqual(main(), 0)
            inspect_document = json.loads(inspect_output.getvalue())
            self.assertEqual(len(inspect_document["parentPhaseReservations"]), 1)
            self.assertNotIn(
                "lease_token", inspect_document["parentPhaseReservations"][0]
            )
            self.assertNotIn(reservation.lease_token, inspect_output.getvalue())

            alerts_output = io.StringIO()
            with (
                patch(
                    "sys.argv",
                    [
                        "map-platform",
                        "--repo-root",
                        str(repo_root),
                        "--data-root",
                        str(data_root),
                        "build-plan",
                        "alerts",
                        "job-cli-parent-phase",
                        "--limit",
                        "1",
                    ],
                ),
                redirect_stdout(alerts_output),
            ):
                self.assertEqual(main(), 0)
            alerts_document = json.loads(alerts_output.getvalue())
            self.assertEqual(alerts_document["page"]["limit"], 1)
            self.assertIn(
                "parent_phase_lease_expired",
                {alert["code"] for alert in alerts_document["alerts"]},
            )

            claimed = store.claim_next(
                worker_id="worker-cli-child",
                parent_job_id="job-cli-parent-phase",
                worker_capability=capability,
            )
            self.assertIsNotNone(claimed)
            assert claimed is not None
            active_output = io.StringIO()
            with (
                patch(
                    "sys.argv",
                    [
                        "map-platform",
                        "--repo-root",
                        str(repo_root),
                        "--data-root",
                        str(data_root),
                        "build-plan",
                        "inspect",
                        "job-cli-parent-phase",
                        "--limit",
                        "1",
                    ],
                ),
                redirect_stdout(active_output),
            ):
                self.assertEqual(main(), 0)
            active_document = json.loads(active_output.getvalue())
            self.assertNotIn("lease_token", active_document["tasks"][0])
            self.assertEqual(len(active_document["resourceReservations"]), 1)
            self.assertNotIn(
                "lease_token", active_document["resourceReservations"][0]
            )
            self.assertNotIn(claimed.lease_token, active_output.getvalue())
            self.assertEqual(
                store.get_task(claimed.task.task_id).lease_token,
                claimed.lease_token,
            )

            with (
                patch(
                    "sys.argv",
                    [
                        "map-platform",
                        "--repo-root",
                        str(repo_root),
                        "--data-root",
                        str(data_root),
                        "build-plan",
                        "alerts",
                        "job-cli-parent-phase",
                        "--limit",
                        "101",
                    ],
                ),
                self.assertRaises(SystemExit) as context,
            ):
                main()
            self.assertIn("limit/offset", str(context.exception))

    def test_complete_workload_scan_help_marks_internal_mutation(self):
        output = io.StringIO()
        with (
            patch(
                "sys.argv",
                [
                    "map-platform",
                    "build-plan",
                    "complete-workload-scan",
                    "--help",
                ],
            ),
            redirect_stdout(output),
            self.assertRaises(SystemExit) as context,
        ):
            main()

        self.assertEqual(context.exception.code, 0)
        self.assertIn("INTERNAL MUTATING", output.getvalue())


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
