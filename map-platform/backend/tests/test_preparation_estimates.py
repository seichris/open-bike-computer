from __future__ import annotations

import json
import math
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from map_platform.jobs import JobStore, MapJobService
from map_platform.manifest import stable_map_id
from map_platform.models import (
    Bounds,
    GeometryMode,
    JobStatus,
    MapJob,
    NormalizedGeometry,
    SourceRegion,
)
from map_platform.preparation_estimates import (
    BaselineProfile,
    PreparationEstimateConfig,
    PreparationEstimateCoordinator,
    PreparationEstimateMode,
    PreparationEstimator,
    WorkerCapabilityStore,
    load_estimate_coordinator,
    performance_compatibility_key,
    validate_estimator_context,
    validate_preparation_estimate,
)
from map_platform.monitoring import MapMonitoringStore
from map_platform.sources import SourceIndex
from map_platform.worker import MapWorker


ROOT = Path(__file__).resolve().parents[3]
PROFILE_PATH = (
    ROOT
    / "map-platform"
    / "backend"
    / "config"
    / "preparation-estimate-profile-v1.json"
)


def build_job(job_id: str = "estimate-job") -> MapJob:
    return MapJob(
        job_id=job_id,
        status=JobStatus.QUEUED,
        request={
            "mode": "custom_bbox",
            "target": {
                "renderer": "esp32-fmb",
                "rendererFormatVersion": 3,
            },
        },
        geometry=NormalizedGeometry(
            mode=GeometryMode.CUSTOM_BBOX,
            bounds=Bounds(121.45, 31.18, 121.50, 31.23),
            area_km2=23.840377,
            vertex_count=4,
        ),
        source_region=SourceRegion(
            id="china/shanghai",
            provider="geofabrik",
            name="Shanghai",
            url="https://example.invalid/shanghai.osm.pbf",
            bounds=Bounds(120.8, 30.6, 122.2, 31.9),
        ),
        created_at="2026-08-10T00:00:00Z",
        updated_at="2026-08-10T00:00:00Z",
    )


class FakeHistory:
    def __init__(self, durations=None, queue=None):
        self.durations = list(durations or [])
        self.queue = list(queue or [])
        self.revisions = []

    def estimate_samples(self, **_kwargs):
        return list(self.durations)

    def queue_samples(self, **_kwargs):
        return list(self.queue)

    def record_estimate_revision(self, job):
        self.revisions.append(job.preparation_estimate["revision"])
        return True


class RetryPipeline:
    def __init__(self, root: Path):
        self.root = root
        self.calls = 0

    def build(self, job, on_status=None, on_progress=None):
        self.calls += 1
        if self.calls == 1:
            raise RuntimeError("temporary failure")
        archive = self.root / f"{job.job_id}.zip"
        archive.write_bytes(b"stable-map-bytes")
        return "stable-map-id", archive


class FailingCapabilityStore:
    def publish(self, **_kwargs):
        raise OSError("capability sidecar unavailable")


class PreparationEstimateTests(unittest.TestCase):
    def setUp(self):
        self.profile = BaselineProfile.load(PROFILE_PATH)
        self.config = PreparationEstimateConfig(
            mode=PreparationEstimateMode.PUBLIC,
            worker_class="test-worker",
            worker_concurrency_class="single",
            validated_confidence_cap="high",
        )

    def estimator(self, history=None):
        return PreparationEstimator(
            self.profile,
            self.config,
            history,
            clock=lambda: 1_786_330_000.0,
        )

    def context(self, estimator, job):
        return estimator.initial_context(
            job,
            preprocessing_mode="selected",
            rules_sha256="a" * 64,
            queue_depth=0,
        )

    def test_off_mode_does_not_require_profile_or_rules_files(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(
            "os.environ",
            {
                "MAP_PLATFORM_PREPARATION_ESTIMATES_MODE": "off",
                "MAP_PLATFORM_ESTIMATOR_WORKER_CLASS": "invalid worker class",
                "MAP_PLATFORM_ESTIMATE_MIN_HISTORY_SAMPLES": "50",
                "MAP_PLATFORM_ESTIMATE_HIGH_CONFIDENCE_SAMPLES": "1",
            },
            clear=False,
        ):
            coordinator = load_estimate_coordinator(
                repo_root=Path(temporary) / "missing-repository",
                data_root=Path(temporary) / "data",
                store=None,
                monitoring_store=None,
                preprocessing_mode="selected",
            )
        self.assertEqual(coordinator.mode, PreparationEstimateMode.OFF)

    def test_fixed_inputs_produce_identical_valid_json(self):
        job = build_job()
        estimator = self.estimator()
        context = self.context(estimator, job)
        first = estimator.estimate(job, context, revision=1)
        second = estimator.estimate(job, context, revision=1)
        self.assertEqual(first, second)
        self.assertEqual(first["state"], "available")
        self.assertEqual(first["basis"], ["baseline_profile", "queue_baseline"])
        self.assertLessEqual(
            first["remaining"]["lowerSeconds"],
            first["remaining"]["upperSeconds"],
        )

    def test_profile_rejects_stale_and_negative_performance_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "profile.json"
            value = json.loads(PROFILE_PATH.read_text())
            value["algorithmVersions"]["buildingSourceIndex"] = 1
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "algorithm profile is stale"):
                BaselineProfile.load(path)
            value = json.loads(PROFILE_PATH.read_text())
            value["baselines"]["3"]["selected"]["referenceAreaM2"] = -1
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "reference is invalid"):
                BaselineProfile.load(path)

    def test_complexity_and_scope_scaling_are_monotonic(self):
        job = build_job()
        estimator = self.estimator()
        context = self.context(estimator, job)
        context["evidence"] = {
            "scope": {
                "outputBlockCount": 6,
                "sourceAreaM2": 111_411_200,
            },
            "complexity": {
                "outlineCount": 16_493,
                "partCount": 279,
                "containmentCandidateProduct": 3_450_000,
                "sourceVertexCount": 115_781,
            },
        }
        baseline = estimator.estimate(job, context, revision=1)
        context["evidence"]["complexity"]["containmentCandidateProduct"] *= 10
        dense = estimator.estimate(job, context, revision=1)
        self.assertGreaterEqual(
            dense["remaining"]["lowerSeconds"],
            baseline["remaining"]["lowerSeconds"],
        )
        self.assertGreaterEqual(
            dense["remaining"]["upperSeconds"],
            baseline["remaining"]["upperSeconds"],
        )

    def test_block_progress_reduces_only_remaining_encoding_component(self):
        job = build_job()
        estimator = self.estimator()
        context = self.context(estimator, job)
        context["evidence"] = {
            "scope": {"outputBlockCount": 6, "sourceAreaM2": 111_411_200},
            "progress": {
                "phase": "block_encoding",
                "unit": "blocks",
                "completed": 1,
                "total": 6,
            },
        }
        early = estimator.estimate(
            job, context, revision=1, based_on_phase="block_encoding"
        )
        context["evidence"]["progress"]["completed"] = 5
        late = estimator.estimate(
            job, context, revision=2, based_on_phase="block_encoding"
        )
        self.assertLessEqual(
            late["remaining"]["lowerSeconds"],
            early["remaining"]["lowerSeconds"],
        )
        self.assertLess(
            late["remaining"]["upperSeconds"],
            early["remaining"]["upperSeconds"],
        )

    def test_history_only_narrows_after_minimum_sample_gate(self):
        sparse = self.estimator(FakeHistory([100.0] * 19))
        job = build_job()
        sparse_estimate = sparse.estimate(
            job, self.context(sparse, job), revision=1
        )
        self.assertEqual(sparse_estimate["confidence"], "low")
        dense = self.estimator(FakeHistory([100.0] * 20))
        dense_estimate = dense.estimate(
            job, self.context(dense, job), revision=1
        )
        self.assertEqual(dense_estimate["confidence"], "medium")
        self.assertEqual(dense_estimate["remaining"], {
            "lowerSeconds": 100,
            "upperSeconds": 100,
        })

    def test_confidence_thresholds_cannot_be_inverted(self):
        with self.assertRaisesRegex(
            ValueError,
            "high-confidence samples must be at least the history minimum",
        ):
            PreparationEstimateConfig(
                mode=PreparationEstimateMode.PUBLIC,
                worker_class="test-worker",
                worker_concurrency_class="single",
                minimum_history_samples=20,
                high_confidence_samples=1,
            )

    def test_reuse_range_above_configured_ceiling_becomes_unavailable(self):
        config = PreparationEstimateConfig(
            mode=PreparationEstimateMode.PUBLIC,
            worker_class="test-worker",
            worker_concurrency_class="single",
            max_seconds=60,
        )
        estimator = PreparationEstimator(
            self.profile,
            config,
            clock=lambda: 1_786_330_000.0,
        )
        job = build_job("bounded-reuse")
        context = self.context(estimator, job)
        context["outcomeClass"] = "subset_reuse"
        estimate = estimator.estimate(job, context, revision=1)
        self.assertEqual(estimate["state"], "unavailable")
        self.assertEqual(estimate["reason"], "temporarily_unavailable")

    def test_queue_topology_counts_each_active_job_once(self):
        estimator = self.estimator()
        estimates = []
        first_range = None
        for index in range(4):
            job = build_job(f"queue-{index}")
            context = estimator.initial_context(
                job,
                preprocessing_mode="selected",
                rules_sha256="a" * 64,
                queue_depth=index,
                queued_estimates=estimates,
                compatible_worker_count=1,
            )
            estimate = estimator.estimate(job, context, revision=1)
            estimates.append(estimate)
            if first_range is None:
                first_range = estimate["remaining"]
                self.assertNotIn("queue", estimate)
                continue
            self.assertEqual(
                estimate["queue"],
                {
                    "lowerSeconds": first_range["lowerSeconds"] * index,
                    "upperSeconds": first_range["upperSeconds"] * index,
                },
            )
            self.assertEqual(
                estimate["remaining"],
                {
                    "lowerSeconds": first_range["lowerSeconds"] * (index + 1),
                    "upperSeconds": first_range["upperSeconds"] * (index + 1),
                },
            )

    def test_queue_topology_keeps_a_fallback_for_jobs_without_estimates(self):
        estimator = self.estimator()
        existing = build_job("known-queue-job")
        existing_context = self.context(estimator, existing)
        known = estimator.estimate(existing, existing_context, revision=1)
        context = estimator.initial_context(
            build_job("mixed-queue"),
            preprocessing_mode="selected",
            rules_sha256="a" * 64,
            queue_depth=2,
            queued_estimates=[known],
            compatible_worker_count=1,
        )
        self.assertEqual(
            context["queueRange"],
            {
                "lowerSeconds": known["remaining"]["lowerSeconds"],
                "upperSeconds": known["remaining"]["upperSeconds"] + 900,
            },
        )

    def test_empty_queue_does_not_inherit_historical_congestion(self):
        estimator = self.estimator(FakeHistory(queue=[600.0, 1_200.0]))
        job = build_job("empty-queue")
        context = estimator.initial_context(
            job,
            preprocessing_mode="selected",
            rules_sha256="a" * 64,
            queue_depth=0,
            compatible_worker_count=1,
        )
        self.assertEqual(
            context["queueRange"],
            {"lowerSeconds": 0, "upperSeconds": 0},
        )
        self.assertNotIn(
            "queue", estimator.estimate(job, context, revision=1)
        )

    def test_building_progress_removes_only_completed_components(self):
        estimator = self.estimator()
        job = build_job("component-progress")
        context = self.context(estimator, job)
        queued = estimator.estimate(job, context, revision=1)
        context["evidence"] = {
            "progress": {
                "phase": "building_preprocessing",
                "unit": "scope_plan",
                "completed": 1,
                "total": 1,
            }
        }
        scope_planned = estimator.estimate(
            job,
            context,
            revision=2,
            based_on_phase="building_preprocessing",
        )
        context["evidence"]["progress"]["unit"] = "dependency_snapshot"
        dependencies_done = estimator.estimate(
            job,
            context,
            revision=3,
            based_on_phase="building_preprocessing",
        )
        context["evidence"]["progress"]["unit"] = "building_complexity"
        normalization_pending = estimator.estimate(
            job,
            context,
            revision=4,
            based_on_phase="building_preprocessing",
        )
        context["evidence"]["progress"]["unit"] = "building_normalization"
        normalization_done = estimator.estimate(
            job,
            context,
            revision=5,
            based_on_phase="building_preprocessing",
        )
        self.assertEqual(scope_planned["remaining"], queued["remaining"])
        self.assertLess(
            dependencies_done["remaining"]["upperSeconds"],
            queued["remaining"]["upperSeconds"],
        )
        self.assertEqual(
            normalization_pending["remaining"],
            dependencies_done["remaining"],
        )
        self.assertLess(
            normalization_done["remaining"]["upperSeconds"],
            dependencies_done["remaining"]["upperSeconds"],
        )

    def test_full_build_history_scales_only_remaining_components(self):
        estimator = self.estimator(FakeHistory([10_000.0] * 50))
        job = build_job("historical-progress")
        context = self.context(estimator, job)
        queued = estimator.estimate(job, context, revision=1)
        packaging = estimator.estimate(
            job,
            context,
            revision=2,
            based_on_phase="packaging",
        )
        self.assertEqual(
            queued["remaining"],
            {"lowerSeconds": 10_000, "upperSeconds": 10_000},
        )
        self.assertLess(
            packaging["remaining"]["upperSeconds"],
            queued["remaining"]["upperSeconds"],
        )
        self.assertGreaterEqual(
            packaging["remaining"]["lowerSeconds"],
            0,
        )

    def test_unvalidated_confidence_cap_prevents_history_from_narrowing(self):
        config = PreparationEstimateConfig(
            mode=PreparationEstimateMode.SHADOW,
            worker_class="test-worker",
            worker_concurrency_class="single",
            validated_confidence_cap="low",
        )
        estimator = PreparationEstimator(
            self.profile,
            config,
            FakeHistory([100.0] * 50),
            clock=lambda: 1_786_330_000.0,
        )
        job = build_job()
        baseline = PreparationEstimator(
            self.profile,
            config,
            clock=lambda: 1_786_330_000.0,
        ).estimate(job, self.context(estimator, job), revision=1)
        estimate = estimator.estimate(
            job, self.context(estimator, job), revision=1
        )
        self.assertEqual(estimate["confidence"], "low")
        self.assertLessEqual(
            estimate["remaining"]["lowerSeconds"],
            baseline["remaining"]["lowerSeconds"],
        )
        self.assertGreaterEqual(
            estimate["remaining"]["upperSeconds"],
            baseline["remaining"]["upperSeconds"],
        )

    def test_ranges_reject_boolean_nonfinite_and_inverted_values(self):
        estimator = self.estimator()
        job = build_job()
        valid = estimator.estimate(job, self.context(estimator, job), revision=1)
        for value in (True, -1, 604_801):
            malformed = dict(valid)
            malformed["remaining"] = {
                "lowerSeconds": value,
                "upperSeconds": 100,
            }
            with self.assertRaises(ValueError):
                validate_preparation_estimate(malformed)
        malformed_context = self.context(estimator, job)
        malformed_context["evidence"] = {"complexity": {"value": math.inf}}
        with self.assertRaises(ValueError):
            validate_estimator_context(malformed_context)

    def test_context_accepts_signed_bounds_but_rejects_invalid_counters(self):
        estimator = self.estimator()
        job = build_job()
        context = self.context(estimator, job)
        context["evidence"] = {
            "scope": {
                "outputBlockCount": 6,
                "sourceAreaM2": 111_411_200,
                "sourceBoundsE7": [
                    -1_224_500_000,
                    377_000_000,
                    -1_223_000_000,
                    378_000_000,
                ],
            }
        }
        self.assertEqual(
            validate_estimator_context(context)["evidence"]["scope"][
                "sourceBoundsE7"
            ][0],
            -1_224_500_000,
        )
        for invalid in (True, -1, 1.5):
            with self.subTest(invalid=invalid):
                context["evidence"]["scope"]["sourceAreaM2"] = invalid
                with self.assertRaises(ValueError):
                    validate_estimator_context(context)

    def test_future_advisory_schema_does_not_break_persisted_job_decode(self):
        serialized = build_job("future-estimate").to_dict(include_internal=True)
        serialized["preparationEstimate"] = {"schemaVersion": 2}
        serialized["preparationEstimatorContext"] = {"schemaVersion": 2}
        restored = MapJob.from_dict(serialized)
        self.assertIsNone(restored.preparation_estimate)
        self.assertIsNone(restored.preparation_estimator_context)

    def test_performance_key_changes_with_rules_renderer_and_worker_class(self):
        base = performance_compatibility_key(
            profile=self.profile,
            config=self.config,
            renderer=3,
            preprocessing_mode="selected",
            rules_sha256="a" * 64,
        )
        changed_rules = performance_compatibility_key(
            profile=self.profile,
            config=self.config,
            renderer=3,
            preprocessing_mode="selected",
            rules_sha256="b" * 64,
        )
        changed_renderer = performance_compatibility_key(
            profile=self.profile,
            config=self.config,
            renderer=2,
            preprocessing_mode="legacy",
            rules_sha256="a" * 64,
        )
        self.assertEqual(len(base), 64)
        self.assertNotEqual(base, changed_rules)
        self.assertNotEqual(base, changed_renderer)

    def test_worker_rebinds_context_when_api_performance_profile_differs(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = JobStore(Path(temporary) / "jobs")
            job = build_job("profile-rebind")
            api_estimator = self.estimator()
            api_coordinator = PreparationEstimateCoordinator(
                store,
                api_estimator,
                preprocessing_mode="selected",
                rules_sha256="a" * 64,
            )
            api_coordinator.prepare_initial(job, [])
            old_key = job.preparation_estimator_context[
                "performanceCompatibilityKey"
            ]
            store.save(job)
            store.claim(job.job_id, "worker-profile")
            worker_config = PreparationEstimateConfig(
                mode=PreparationEstimateMode.PUBLIC,
                worker_class="different-worker",
                worker_concurrency_class="single",
                validated_confidence_cap="low",
            )
            worker_coordinator = PreparationEstimateCoordinator(
                store,
                PreparationEstimator(
                    self.profile,
                    worker_config,
                    clock=lambda: 1_786_330_000.0,
                ),
                preprocessing_mode="selected",
                rules_sha256="a" * 64,
            )
            updated = worker_coordinator.publish(
                job.job_id,
                worker_id="worker-profile",
                phase="validating",
                force=True,
            )
            self.assertNotEqual(
                updated.preparation_estimator_context[
                    "performanceCompatibilityKey"
                ],
                old_key,
            )
            self.assertEqual(updated.preparation_estimate["confidence"], "low")

    def test_atomic_revision_checks_worker_attempt_and_identity_invariance(self):
        history = FakeHistory()
        with tempfile.TemporaryDirectory() as temporary:
            store = JobStore(Path(temporary) / "jobs")
            job = build_job()
            estimator = self.estimator(history)
            events = []
            coordinator = PreparationEstimateCoordinator(
                store,
                estimator,
                preprocessing_mode="selected",
                rules_sha256="a" * 64,
                event_sink=events.append,
                clock=lambda: 1_786_330_000.0,
            )
            stable_identity = stable_map_id(job)
            coordinator.prepare_initial(job, [])
            store.save(job)
            coordinator.record_prepared(job)
            map_identity = (job.map_id, job.build_cache_key, job.artifacts)
            claimed = store.claim(job.job_id, "worker-test")
            updated = coordinator.publish(
                job.job_id,
                worker_id="worker-test",
                phase="scope_plan",
                evidence={
                    "scope": {
                        "outputBlockCount": 6,
                        "sourceAreaM2": 111_411_200,
                    }
                },
                force=True,
            )
            self.assertIsNotNone(updated)
            self.assertEqual(updated.preparation_estimate["revision"], 2)
            self.assertEqual(updated.preparation_estimate["attempt"], claimed.attempts)
            self.assertEqual(
                (updated.map_id, updated.build_cache_key, updated.artifacts),
                map_identity,
            )
            self.assertEqual(stable_map_id(updated), stable_identity)
            self.assertEqual(
                [event["revision"] for event in events],
                [1, 2],
            )
            self.assertEqual(
                events[-1]["event"], "map_preparation_estimate_updated"
            )
            self.assertNotIn("bbox", events[-1])
            self.assertNotIn("sourceRegion", events[-1])
            self.assertIsNone(
                coordinator.publish(
                    job.job_id,
                    worker_id="different-worker",
                    phase="scope_plan",
                    force=True,
                )
            )

    def test_capabilities_expire_and_do_not_change_heartbeat_contract(self):
        now = [1_000.0]
        with tempfile.TemporaryDirectory() as temporary:
            store = WorkerCapabilityStore(
                temporary, max_age_seconds=120, clock=lambda: now[0]
            )
            store.publish(
                worker_id="worker-one",
                performance_compatibility_key="a" * 64,
                worker_class="test-worker",
                preprocessing_modes={"selected"},
                renderer_formats={1, 2, 3},
                model_version="map-preparation-v1",
                profile_sha256="c" * 64,
            )
            self.assertEqual(
                len(
                    store.compatible(
                        model_version="map-preparation-v1",
                        performance_compatibility_key="a" * 64,
                        profile_sha256="c" * 64,
                    )
                ),
                1,
            )
            self.assertEqual(
                store.compatible(
                    model_version="map-preparation-v1",
                    performance_compatibility_key="b" * 64,
                    profile_sha256="c" * 64,
                ),
                [],
            )
            self.assertEqual(
                store.compatible(
                    model_version="map-preparation-v1",
                    performance_compatibility_key="a" * 64,
                    profile_sha256="d" * 64,
                ),
                [],
            )
            now[0] += 121
            self.assertEqual(
                store.compatible(model_version="map-preparation-v1"), []
            )

    def test_capability_sidecar_failure_does_not_break_worker_heartbeat(self):
        coordinator = PreparationEstimateCoordinator(
            None,
            self.estimator(),
            preprocessing_mode="selected",
            rules_sha256="a" * 64,
            capability_store=FailingCapabilityStore(),
        )
        self.assertIsNone(coordinator.publish_worker_capability("worker-one"))

    def test_forced_phase_updates_cannot_bypass_revision_cap(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = JobStore(Path(temporary) / "jobs")
            job = build_job("revision-cap")
            estimator = PreparationEstimator(
                self.profile,
                PreparationEstimateConfig(
                    mode=PreparationEstimateMode.PUBLIC,
                    worker_class="test-worker",
                    worker_concurrency_class="single",
                    max_revisions_per_job=2,
                ),
                clock=lambda: 1_786_330_000.0,
            )
            coordinator = PreparationEstimateCoordinator(
                store,
                estimator,
                preprocessing_mode="selected",
                rules_sha256="a" * 64,
            )
            coordinator.prepare_initial(job, [])
            store.save(job)
            store.claim(job.job_id, "worker-cap")
            coordinator.publish(
                job.job_id,
                worker_id="worker-cap",
                phase="validating",
                force=True,
            )
            capped = coordinator.publish(
                job.job_id,
                worker_id="worker-cap",
                phase="converting_features",
                force=True,
            )
            self.assertEqual(capped.preparation_estimate["revision"], 2)

    def test_worker_retry_reestimates_without_failing_or_changing_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = JobStore(root / "jobs")
            monitoring = MapMonitoringStore(root / "monitoring.sqlite3")
            estimator = self.estimator(monitoring)
            coordinator = PreparationEstimateCoordinator(
                store,
                estimator,
                preprocessing_mode="selected",
                rules_sha256="a" * 64,
            )
            source = build_job().source_region
            service = MapJobService(
                SourceIndex([source]),
                store,
                estimate_coordinator=coordinator,
            )
            job = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [121.45, 31.18, 121.50, 31.23],
                }
            )
            pipeline = RetryPipeline(root)
            worker = MapWorker(
                store,
                pipeline,
                worker_id="worker-retry",
                monitoring_store=monitoring,
                estimate_coordinator=coordinator,
            )

            first = worker.run_next().job
            self.assertEqual(first.status, JobStatus.QUEUED)
            self.assertEqual(first.preparation_estimate["state"], "pending")
            self.assertEqual(first.preparation_estimate["attempt"], 1)
            second = worker.run_next().job

            self.assertEqual(second.status, JobStatus.READY)
            self.assertEqual(second.attempts, 2)
            self.assertEqual(second.preparation_estimate["attempt"], 2)
            self.assertEqual(Path(second.pack_path).read_bytes(), b"stable-map-bytes")
            summary = monitoring.summary(window_hours=24 * 365)
            self.assertGreaterEqual(summary["estimateRevisions"]["count"], 4)
            self.assertIn("retry", summary["estimateExclusions"])


if __name__ == "__main__":
    unittest.main()
