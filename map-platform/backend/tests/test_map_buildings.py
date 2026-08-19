import hashlib
import json
from copy import deepcopy
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from map_platform.jobs import JobStore, MapJobService
from map_platform.manifest import (
    PipelineMetadata,
    build_manifest,
    stable_map_id,
    write_pack_archive,
)
from map_platform.map_stream import canonical_manifest_bytes
from map_platform.map_buildings import (
    building_block_workers,
    building_preprocessing_scope_mode,
    building_target3_generation_allowlist,
    building_target3_generation_enabled,
    load_building_calibration_window,
)
from map_platform.models import Bounds, MapJob, SourceRegion
from map_platform.pipeline import (
    MapBuildPipeline,
    PipelinePaths,
    _coalesce_projected_rectangles,
)
from map_platform.building_scope import plan_building_scope, plan_global_building_scope
from map_platform.building_tasks import BuildingTaskStore
from map_platform.building_scope import BuildingScopeError, BuildingScopePolicy
from map_platform.building_identity import (
    canonical_json as canonical_building_json,
    selected_building_block_cache_identity,
    selected_building_identity,
    selected_calibration_identity,
)
from map_platform.reuse import aligned_projected_extent
from map_platform import reuse as reuse_module
from map_platform.sources import SourceIndex
from tests.map_label_fixtures import one_building_fmb4, one_label_fma1


class CapturingRunner:
    def __init__(self):
        self.args = None

    def run(self, args, *, cwd=None):
        del cwd
        self.args = args
        return "\n".join(
            (
                'BUILDING_COMPLEXITY:{"schemaVersion":1,"sourceCount":1,'
                '"outlineCount":1,"partCount":0,"explicitParentCount":0,'
                '"unresolvedPartCount":0,"containmentCandidateProduct":0,'
                '"polygonCount":1,"ringCount":1,"holeCount":0,'
                '"sourceVertexCount":5,"maximumVerticesPerObject":5,'
                '"preparationRejectedCount":0}',
                'LABEL_STATS:{"blocks":1,"phaseTimings":{"labelFontWriting":0.5}}',
                'BUILDING_STATS:{"recordCount":1,"explicitHeightCount":1,'
                '"levelsHeightCount":0,"inheritedHeightCount":0,'
                '"localMedianHeightCount":0,"classDefaultHeightCount":0}',
            )
        )


class RecordingRunner:
    def __init__(self):
        self.calls = []

    def run(self, args, *, cwd=None):
        self.calls.append((args, cwd))
        return ""


class MapBuildingContractTests(unittest.TestCase):
    def setUp(self):
        self.source = SourceRegion(
            id="sg",
            provider="test",
            name="Singapore",
            url="https://example.invalid/sg.osm.pbf",
            bounds=Bounds(103.0, 1.0, 104.5, 1.8),
            checksum="3" * 64,
        )

    def _request(self):
        return {
            "mode": "custom_bbox",
            "bbox": [103.75, 1.24, 103.93, 1.37],
            "target": {
                "renderer": "esp32-fmb",
                "rendererFormatVersion": 3,
                "firmwareVersion": "1.2.3",
            },
            "labels": {
                "profileVersion": 1,
                "preferredLanguages": ["zh-Hant", "en"],
                "internationalFallback": "en-US",
            },
        }

    def _calibration_generation(self, source_sha, scope_plan):
        rules_path = (
            Path(__file__).resolve().parents[3]
            / "tools/OSM_Extract/conf/building_height_rules.yaml"
        )
        calibration = selected_calibration_identity(
            source_snapshot_sha256=source_sha,
            rules_path=rules_path,
            scope_plan=scope_plan,
        )
        return Path("/tmp/test-calibration-manifest.json"), {
            "calibrationKey": calibration["calibrationKey"],
            "manifestSha256": "a" * 64,
            "entrySetSha256": "b" * 64,
            "cellCount": 12,
        }

    def _service(self, store):
        return MapJobService(
            SourceIndex([self.source]),
            store,
            label_target2_enabled=True,
            building_target3_enabled=True,
        )

    def test_target_three_generation_is_disabled_by_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(SourceIndex([self.source]), JobStore(tmp))
            with self.assertRaisesRegex(
                ValueError,
                "format 3 generation is not available for this installation",
            ):
                service.create_job(self._request())

    def test_target_three_environment_gate_is_strict(self):
        with patch.dict(
            "os.environ",
            {"MAP_PLATFORM_BUILDING_TARGET3_ENABLED": "yes"},
            clear=True,
        ):
            self.assertTrue(building_target3_generation_enabled())
        with patch.dict(
            "os.environ",
            {"MAP_PLATFORM_BUILDING_TARGET3_ENABLED": "sometimes"},
            clear=True,
        ):
            with self.assertRaisesRegex(ValueError, "must be a boolean"):
                building_target3_generation_enabled()

    def test_target_three_preprocessing_scope_mode_is_strict(self):
        with patch.dict("os.environ", {}, clear=True):
            self.assertEqual(building_preprocessing_scope_mode(), "shadow")
        for mode in ("legacy", "shadow", "selected"):
            with self.subTest(mode=mode), patch.dict(
                "os.environ",
                {"MAP_PLATFORM_BUILDING_PREPROCESSING_SCOPE_MODE": mode.upper()},
                clear=True,
            ):
                self.assertEqual(building_preprocessing_scope_mode(), mode)
        with patch.dict(
            "os.environ",
            {"MAP_PLATFORM_BUILDING_PREPROCESSING_SCOPE_MODE": "automatic"},
            clear=True,
        ):
            with self.assertRaisesRegex(ValueError, "legacy, shadow, or selected"):
                building_preprocessing_scope_mode()

    def test_building_block_worker_configuration_is_bounded(self):
        with patch.dict("os.environ", {}, clear=True):
            self.assertEqual(building_block_workers(), 4)
        with patch.dict(
            "os.environ",
            {"MAP_PLATFORM_BUILDING_BLOCK_WORKERS": "8"},
            clear=True,
        ):
            self.assertEqual(building_block_workers(), 8)
        for value in ("0", "17", "many"):
            with self.subTest(value=value), patch.dict(
                "os.environ",
                {"MAP_PLATFORM_BUILDING_BLOCK_WORKERS": value},
                clear=True,
            ):
                with self.assertRaisesRegex(ValueError, "BUILDING_BLOCK_WORKERS"):
                    building_block_workers()

    def test_cache_only_assembly_forwards_fail_closed_extractor_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runner = CapturingRunner()
            pipeline = MapBuildPipeline(
                PipelinePaths(
                    Path(__file__).resolve().parents[3],
                    root / "work",
                    root / "packs",
                ),
                runner=runner,
            )
            job = self._service(JobStore(root / "jobs")).create_job(
                self._request()
            )
            pipeline._extract_features(
                job,
                root / "features",
                root / "raw",
                calibration_manifest=root / "calibration.json",
                calibration_source_sha256="3" * 64,
                building_block_cache_identity_path=root / "cache-identity.json",
                building_cache_only=True,
            )
            self.assertIn("--building-cache-only", runner.args)

    def test_chunk_assembly_rejects_missing_receipts_before_preprocessing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = self._service(JobStore(root / "jobs")).create_job(
                self._request()
            )
            global_plan = plan_global_building_scope(
                job,
                calibration_cell_size_meters=8192,
                calibration_halo_cells=1,
                calibration_minimum_samples=3,
            )
            task_store = BuildingTaskStore(root / "building-tasks.sqlite3")
            task_store.create_plan(
                parent_job_id=job.job_id,
                global_plan_sha256=global_plan.sha256,
                input_identity={},
                expected_output_block_count=len(global_plan.output_blocks),
                policy_version=1,
                resource_model_version="v1",
                stage="chunk_planning",
            )
            source_pbf = root / "source.pbf"
            source_pbf.write_bytes(b"source")
            pipeline = MapBuildPipeline(
                PipelinePaths(
                    Path(__file__).resolve().parents[3],
                    root / "work",
                    root / "packs",
                ),
                building_task_store=task_store,
            )
            with self.assertRaises(BuildingScopeError) as raised:
                pipeline.assemble_building_chunks(
                    job,
                    global_plan=global_plan,
                    source_pbf=source_pbf,
                    source_snapshot_sha256=hashlib.sha256(b"source").hexdigest(),
                    calibration_manifest=root / "missing-calibration.json",
                    calibration_generation={},
                )
            self.assertEqual(raised.exception.code, "building_chunks_incomplete")

    def test_building_block_cache_identity_is_scope_independent_and_hash_bound(self):
        with tempfile.TemporaryDirectory() as tmp:
            job = self._service(JobStore(tmp)).create_job(self._request())
            plan = plan_building_scope(
                job,
                calibration_cell_size_meters=8192,
                calibration_halo_cells=1,
                calibration_minimum_samples=3,
            )
            rules_path = (
                Path(__file__).resolve().parents[3]
                / "tools/OSM_Extract/conf/building_height_rules.yaml"
            )
            _manifest, generation = self._calibration_generation("1" * 64, plan)
            identity = selected_building_block_cache_identity(
                source_snapshot_sha256="1" * 64,
                rules_path=rules_path,
                scope_plan=plan,
                calibration_generation=generation,
            )
            body = {
                key: value
                for key, value in identity.items()
                if key != "cacheIdentitySha256"
            }

            self.assertNotIn("scopePlanSha256", canonical_building_json(identity).decode())
            self.assertEqual(identity["blockSizeMeters"], 4096)
            self.assertEqual(identity["normalizationAlgorithmVersion"], 2)
            self.assertEqual(
                identity["geometryEngine"],
                {"name": "shapely", "version": "2.0.7"},
            )
            self.assertEqual(
                identity["cacheIdentitySha256"],
                hashlib.sha256(canonical_building_json(body)).hexdigest(),
            )

    def test_target_three_allowlist_is_strict(self):
        installation_id = "inst_v2_" + "a" * 32
        with patch.dict(
            "os.environ",
            {"MAP_PLATFORM_BUILDING_TARGET3_ALLOWLIST": installation_id},
            clear=True,
        ):
            self.assertEqual(
                building_target3_generation_allowlist(),
                frozenset({installation_id}),
            )
        with patch.dict(
            "os.environ",
            {"MAP_PLATFORM_BUILDING_TARGET3_ALLOWLIST": f"{installation_id},{installation_id}"},
            clear=True,
        ):
            with self.assertRaisesRegex(ValueError, "contains duplicates"):
                building_target3_generation_allowlist()
        with patch.dict(
            "os.environ",
            {"MAP_PLATFORM_BUILDING_TARGET3_ALLOWLIST": "installation-invalid"},
            clear=True,
        ):
            with self.assertRaisesRegex(ValueError, "invalid installation ID"):
                building_target3_generation_allowlist()

    def test_target_three_allowlist_blocks_other_installations(self):
        allowed_installation = "inst_v2_" + "a" * 32
        blocked_installation = "inst_v2_" + "b" * 32
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(
                SourceIndex([self.source]),
                JobStore(tmp),
                label_target2_enabled=True,
                building_target3_enabled=True,
                building_target3_allowlist=frozenset({allowed_installation}),
            )
            request = self._request()
            request.update(
                {
                    "clientInstallationId": blocked_installation,
                    "clientRequestId": "request-blocked",
                }
            )
            with self.assertRaisesRegex(
                ValueError,
                "format 3 generation is not available for this installation",
            ):
                service.create_job(request)

    def test_target_three_allowlist_enables_explicit_canary_while_global_gate_is_off(self):
        allowed_installation = "inst_v2_" + "a" * 32
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(
                SourceIndex([self.source]),
                JobStore(tmp),
                label_target2_enabled=True,
                building_target3_enabled=False,
                building_target3_allowlist=frozenset({allowed_installation}),
            )
            request = self._request()
            request.update(
                {
                    "clientInstallationId": allowed_installation,
                    "clientRequestId": "request-canary-123",
                }
            )

            job = service.create_job(request)

            self.assertEqual(
                job.request["target"]["rendererFormatVersion"],
                3,
            )

            request.update(
                {
                    "clientInstallationId": allowed_installation,
                    "clientRequestId": "request-allowed",
                }
            )
            job = service.create_job(request)
            self.assertEqual(
                job.request["target"]["rendererFormatVersion"],
                3,
            )

    def test_target_three_idempotent_replay_survives_gate_rollback(self):
        installation_id = "inst_v2_" + "c" * 32
        request = {
            **self._request(),
            "clientInstallationId": installation_id,
            "clientRequestId": "request-target3-idempotent",
        }
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp)
            enabled = MapJobService(
                SourceIndex([self.source]),
                store,
                label_target2_enabled=True,
                building_target3_enabled=True,
                building_target3_allowlist=frozenset({installation_id}),
            )
            created = enabled.create_job(request)

            rolled_back = MapJobService(
                SourceIndex([self.source]),
                store,
                label_target2_enabled=True,
                building_target3_enabled=False,
            )
            replayed = rolled_back.create_job(dict(request))
            self.assertEqual(replayed.job_id, created.job_id)

            changed = {**request, "bbox": [103.76, 1.25, 103.94, 1.38]}
            with self.assertRaisesRegex(ValueError, "different map request"):
                enabled.create_job(changed)

    def test_target_three_retry_remains_eligible_for_target_two_fallback(self):
        installation_id = "inst_v2_" + "d" * 32
        target_three = {
            **self._request(),
            "clientInstallationId": installation_id,
            "clientRequestId": "request-target3-fallback",
        }
        target_two = json.loads(json.dumps(target_three))
        target_two["target"]["rendererFormatVersion"] = 2

        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp)
            rolled_back = MapJobService(
                SourceIndex([self.source]),
                store,
                label_target2_enabled=True,
                building_target3_enabled=False,
            )
            with self.assertRaisesRegex(ValueError, "format 3 generation"):
                rolled_back.create_job(target_three)

            fallback = rolled_back.create_job(target_two)
            recovered_while_rolled_back = rolled_back.create_job(target_three)
            self.assertEqual(recovered_while_rolled_back.job_id, fallback.job_id)
            replayed = rolled_back.create_job(dict(target_two))
            self.assertEqual(replayed.job_id, fallback.job_id)

            enabled = MapJobService(
                SourceIndex([self.source]),
                store,
                label_target2_enabled=True,
                building_target3_enabled=True,
                building_target3_allowlist=frozenset({installation_id}),
            )
            recovered_after_promotion = enabled.create_job(dict(target_three))
            self.assertEqual(recovered_after_promotion.job_id, fallback.job_id)

    def test_calibration_window_comes_from_checked_in_height_rules(self):
        repo_root = Path(__file__).resolve().parents[3]
        window = load_building_calibration_window(
            repo_root / "tools" / "OSM_Extract" / "conf" / "building_height_rules.yaml"
        )
        self.assertEqual(window.cell_size_meters, 8192)
        self.assertEqual(window.halo_cells, 1)
        self.assertEqual(window.minimum_samples, 3)

    def test_target_three_shadow_plan_is_reachable_without_changing_legacy_bounds(self):
        request = self._request()
        request["bbox"] = [103.80, 1.28, 103.83, 1.31]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = self._service(JobStore(root / "jobs")).create_job(request)
            repo_root = Path(__file__).resolve().parents[3]
            pipeline = MapBuildPipeline(
                PipelinePaths(repo_root, root / "work", root / "packs"),
                runner=CapturingRunner(),
                building_scope_mode="shadow",
            )
            observed = {}
            never_cancelled = lambda: False

            def capture_features(*args, **kwargs):
                del args
                observed["featureCancellation"] = kwargs.get(
                    "cancellation_check"
                )
                return {}

            def capture_package(*args, **kwargs):
                del args
                observed["metrics"] = kwargs["build_metrics"]
                return object()

            def capture_extract(*args, **kwargs):
                del args
                observed["sourceBounds"] = kwargs["bounds"]

            source_pbf = root / "source.pbf"
            source_pbf.write_bytes(b"shadow-source")
            generation = {
                "calibrationKey": "a" * 64,
                "manifestSha256": "b" * 64,
                "entrySetSha256": "c" * 64,
                "cellCount": 12,
            }
            dependency_metrics = {
                "sourceIndex": {"indexKey": "d" * 64},
                "closure": {
                    "candidateCount": 7,
                    "relationCount": 2,
                    "wayCount": 5,
                    "nodeCount": 18,
                    "calibrationCellCount": 9,
                },
                "calibration": {"cellsRequested": 9},
            }

            def calibration_generation(*_args, execution_sink=None, **_kwargs):
                execution_sink.update(
                    {"cacheOutcome": "hit", "durationSeconds": 0.01}
                )
                return root / "calibration.json", generation

            with patch.object(pipeline, "_source_pbf_path", return_value=root / "source.pbf"), \
                 patch.object(
                     pipeline,
                     "_ensure_selected_calibration_generation",
                     side_effect=calibration_generation,
                 ), \
                 patch.object(
                     pipeline,
                     "_selected_dependency_metrics",
                     return_value=dependency_metrics,
                 ), \
                 patch.object(pipeline, "_extract_pbf", side_effect=capture_extract), \
                 patch.object(pipeline, "_convert_to_geojson"), \
                 patch.object(pipeline, "_extract_features", side_effect=capture_features), \
                 patch.object(pipeline, "_stage_vectmap"), \
                 patch.object(pipeline, "_package_map", side_effect=capture_package):
                pipeline.build(job, cancellation_check=never_cancelled)

            preprocessing = observed["metrics"]["buildingPreprocessing"]
            self.assertEqual(preprocessing["mode"], "shadow")
            self.assertIs(
                observed["featureCancellation"], never_cancelled
            )
            self.assertRegex(preprocessing["scope"]["scopePlanSha256"], r"^[0-9a-f]{64}$")
            self.assertEqual(
                preprocessing["shadowRequirements"]["closure"]["candidateCount"],
                7,
            )
            self.assertEqual(
                preprocessing["shadowRequirements"]["closure"]["relationCount"],
                2,
            )
            self.assertEqual(
                preprocessing["shadowRequirements"][
                    "calibrationGenerationExecution"
                ]["cacheOutcome"],
                "hit",
            )
            self.assertGreaterEqual(
                preprocessing["shadowRequirements"][
                    "dependencyValidationExecution"
                ]["durationSeconds"],
                0,
            )
            self.assertGreaterEqual(
                preprocessing["shadowMeasurementExecution"]["durationSeconds"],
                preprocessing["shadowRequirements"][
                    "dependencyValidationExecution"
                ]["durationSeconds"],
            )
            calibration = load_building_calibration_window(
                repo_root
                / "tools"
                / "OSM_Extract"
                / "conf"
                / "building_height_rules.yaml"
            )
            expected_legacy_bounds = reuse_module.expanded_building_source_bounds(
                reuse_module.aligned_processing_bounds(
                    job, complete_blocks=True
                ),
                cell_size_meters=calibration.cell_size_meters,
                halo_cells=calibration.halo_cells,
            )
            self.assertEqual(observed["sourceBounds"], expected_legacy_bounds)
            scope_paths = list((root / "work" / job.job_id).glob("*/scope-plan.json"))
            self.assertEqual(len(scope_paths), 1)
            written = json.loads(scope_paths[0].read_text())
            self.assertEqual(written["scopePlanSha256"], preprocessing["scope"]["scopePlanSha256"])

    def test_target_three_shadow_metadata_failure_keeps_legacy_build(self):
        request = self._request()
        request["bbox"] = [103.80, 1.28, 103.83, 1.31]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = self._service(JobStore(root / "jobs")).create_job(request)
            repo_root = Path(__file__).resolve().parents[3]
            source_pbf = root / "source.pbf"
            source_pbf.write_bytes(b"shadow-source")
            observed = {}
            pipeline = MapBuildPipeline(
                PipelinePaths(repo_root, root / "work", root / "packs"),
                runner=CapturingRunner(),
                building_scope_mode="shadow",
            )

            def calibration_generation(*_args, **_kwargs):
                return root / "calibration.json", {
                    "calibrationKey": "a" * 64,
                    "manifestSha256": "b" * 64,
                    "entrySetSha256": "c" * 64,
                    "cellCount": 12,
                }

            def capture_package(*_args, **kwargs):
                observed["metrics"] = kwargs["build_metrics"]
                return object()

            with patch.object(
                pipeline, "_source_pbf_path", return_value=source_pbf
            ), patch.object(
                pipeline,
                "_ensure_selected_calibration_generation",
                side_effect=calibration_generation,
            ), patch.object(
                pipeline,
                "_selected_dependency_metrics",
                side_effect=KeyError("closurePlanSha256"),
            ), patch.object(
                pipeline, "_extract_pbf"
            ), patch.object(
                pipeline, "_convert_to_geojson"
            ), patch.object(
                pipeline, "_extract_features", return_value={}
            ), patch.object(
                pipeline, "_stage_vectmap"
            ), patch.object(
                pipeline, "_package_map", side_effect=capture_package
            ):
                pipeline.build(job)

            preprocessing = observed["metrics"]["buildingPreprocessing"]
            self.assertEqual(preprocessing["mode"], "shadow")
            self.assertEqual(
                preprocessing["shadowMeasurementError"]["code"],
                "building_shadow_measurement_unavailable",
            )
            self.assertGreaterEqual(
                preprocessing["shadowMeasurementExecution"]["durationSeconds"],
                0,
            )

    def test_selected_scope_mode_is_accepted_and_unknown_modes_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                building_scope_mode="selected",
            )
            self.assertEqual(pipeline.building_scope_mode, "selected")
            with self.assertRaisesRegex(ValueError, "legacy, shadow, or selected"):
                MapBuildPipeline(
                    PipelinePaths(root, root / "work", root / "packs"),
                    building_scope_mode="unknown",
                )

            serialized = self._service(JobStore(root / "jobs")).create_job(
                self._request()
            ).to_dict(include_internal=True)
            serialized["buildingPreprocessingMode"] = "unknown"
            with self.assertRaisesRegex(
                ValueError, "building preprocessing mode is invalid"
            ):
                MapJob.from_dict(serialized)

    def test_selected_inputs_are_frozen_across_retry_and_source_changes_fail_closed(self):
        request = self._request()
        request["bbox"] = [103.80, 1.28, 103.83, 1.31]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            created = self._service(store).create_job(request)
            job = store.claim(created.job_id, "worker-freeze")
            repo_root = Path(__file__).resolve().parents[3]
            pipeline = MapBuildPipeline(
                PipelinePaths(repo_root, root / "work", root / "packs"),
                building_scope_mode="selected",
                producer_build_sha256="a" * 64,
                producer_image_digest="sha256:" + "b" * 64,
            )
            source = SimpleNamespace(path=root / "source.pbf", sha256="3" * 64)
            progress = []

            def resolve_source(*_args, **_kwargs):
                self.assertEqual(progress[-1]["unit"], "source_cache_wait")
                time.sleep(0.01)
                return source

            with patch.object(
                pipeline.source_cache, "ensure", side_effect=resolve_source
            ), patch.object(
                pipeline,
                "_ensure_selected_calibration_generation",
                side_effect=lambda _path, sha, scope, **_kwargs: self._calibration_generation(
                    sha, scope
                ),
            ):
                keys = pipeline.reuse_keys(
                    job,
                    on_phase_progress=progress.append,
                )

            self.assertIsNotNone(keys)
            self.assertEqual(progress[0]["phase"], "building_preprocessing")
            self.assertEqual(progress[0]["unit"], "source_cache_wait")
            self.assertTrue(progress[0]["indeterminate"])
            self.assertGreaterEqual(
                job._building_observability["cacheWaitMilliseconds"],
                1,
            )
            self.assertIsNotNone(job.building_preprocessing_inputs)
            store.freeze_building_preprocessing_inputs_unless_cancelled(
                job.job_id,
                worker_id="worker-freeze",
                building_preprocessing_inputs=job.building_preprocessing_inputs,
            )
            reloaded = store.get(job.job_id)
            self.assertEqual(
                reloaded.building_preprocessing_inputs,
                job.building_preprocessing_inputs,
            )

            changed_source = SimpleNamespace(
                path=root / "changed-source.pbf", sha256="4" * 64
            )
            with patch.object(
                pipeline.source_cache, "ensure", return_value=changed_source
            ):
                with self.assertRaises(BuildingScopeError) as context:
                    pipeline.reuse_keys(reloaded)
            self.assertEqual(
                context.exception.code,
                "building_source_snapshot_changed",
            )

    def test_target_three_rollout_mode_cannot_change_across_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            created = self._service(store).create_job(self._request())
            job = store.claim(created.job_id, "worker-mode-freeze")
            repo_root = Path(__file__).resolve().parents[3]

            for frozen_mode, retry_mode in (
                ("selected", "legacy"),
                ("legacy", "selected"),
                ("shadow", "selected"),
            ):
                with self.subTest(
                    frozen_mode=frozen_mode,
                    retry_mode=retry_mode,
                ):
                    job.building_preprocessing_mode = frozen_mode
                    store.freeze_building_preprocessing_mode_unless_cancelled(
                        job.job_id,
                        worker_id="worker-mode-freeze",
                        building_preprocessing_mode=frozen_mode,
                    )
                    reloaded = store.get(job.job_id)
                    pipeline = MapBuildPipeline(
                        PipelinePaths(
                            repo_root,
                            root / "work",
                            root / "packs",
                        ),
                        building_scope_mode=retry_mode,
                    )
                    with self.assertRaises(BuildingScopeError) as context:
                        pipeline.uses_selected_preprocessing(reloaded)
                    self.assertEqual(
                        context.exception.code,
                        "building_scope_policy_invalid",
                    )
                    # Restore the same frozen record for the next subcase.
                    job = store.get(job.job_id)
                    job.building_preprocessing_mode = None
                    store.save(job)

    def test_selected_scope_wires_source_index_calibration_and_exact_blocks(self):
        request = self._request()
        request["bbox"] = [103.80, 1.28, 103.83, 1.31]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = self._service(JobStore(root / "jobs")).create_job(request)
            repo_root = Path(__file__).resolve().parents[3]
            pipeline = MapBuildPipeline(
                PipelinePaths(repo_root, root / "work", root / "packs"),
                runner=CapturingRunner(),
                building_scope_mode="selected",
            )
            observed = {}
            source_path = root / "source.osm.pbf"
            calibration_manifest = root / "calibration-manifest.json"
            source_index_manifest = root / "source-index-manifest.json"

            def capture_pbf(_job, _source, _output, **kwargs):
                observed["scopePlan"] = kwargs["scope_plan"]

            def capture_conversion(*_args, **kwargs):
                observed["sourceIndexManifest"] = kwargs["source_index_manifest"]

            def capture_features(*_args, **kwargs):
                observed["featureArgs"] = kwargs
                written_scope = json.loads(kwargs["scope_plan_path"].read_bytes())
                return {
                    "buildingScope": {
                        "scopePlanSha256": written_scope["scopePlanSha256"],
                        "outputBlockCount": len(written_scope["outputBlocks"]),
                    }
                }

            with patch.object(
                pipeline.source_cache,
                "ensure",
                return_value=SimpleNamespace(path=source_path, sha256="3" * 64),
            ), patch.object(
                pipeline, "_extract_pbf", side_effect=capture_pbf
            ), patch.object(
                pipeline,
                "_ensure_selected_calibration_generation",
                side_effect=lambda _path, sha, scope, **_kwargs: self._calibration_generation(
                    sha, scope
                ),
            ), patch.object(
                pipeline,
                "_prepare_selected_building_inputs",
                return_value=(
                    calibration_manifest,
                    source_index_manifest,
                    {"calibration": {"cellsHits": 1}},
                ),
            ), patch.object(
                pipeline, "_convert_to_geojson", side_effect=capture_conversion
            ), patch.object(
                pipeline, "_extract_features", side_effect=capture_features
            ), patch.object(
                pipeline, "_stage_vectmap"
            ), patch.object(
                pipeline, "_package_map", return_value=object()
            ):
                pipeline.build(job)

            scope_plan = observed["scopePlan"]
            self.assertGreater(len(scope_plan.output_blocks), 0)
            self.assertEqual(observed["sourceIndexManifest"], source_index_manifest)
            self.assertEqual(
                observed["featureArgs"]["calibration_manifest"],
                calibration_manifest,
            )
            self.assertEqual(
                observed["featureArgs"]["calibration_source_sha256"], "3" * 64
            )
            self.assertEqual(
                observed["featureArgs"]["scope_plan_path"].read_bytes(),
                (next((root / "work" / job.job_id).glob("*/scope-plan.json"))).read_bytes(),
            )

    def test_selected_build_rejects_inputs_changed_after_key_reservation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            request = self._request()
            request["bbox"] = [103.80, 1.28, 103.83, 1.31]
            job = self._service(JobStore(root / "jobs")).create_job(request)
            job.build_cache_key = "0" * 64
            job.build_compatibility_key = "1" * 64
            pipeline = MapBuildPipeline(
                PipelinePaths(
                    Path(__file__).resolve().parents[3],
                    root / "work",
                    root / "packs",
                ),
                runner=CapturingRunner(),
                producer_build_sha256="2" * 64,
                producer_image_digest="sha256:" + "4" * 64,
                building_scope_mode="selected",
            )
            with patch.object(
                pipeline.source_cache,
                "ensure",
                return_value=SimpleNamespace(
                    path=root / "source.pbf", sha256="3" * 64
                ),
            ), patch.object(
                pipeline,
                "_ensure_selected_calibration_generation",
                side_effect=lambda _path, sha, scope, **_kwargs: self._calibration_generation(
                    sha, scope
                ),
            ):
                with self.assertRaises(BuildingScopeError) as raised:
                    pipeline.build(job)

            self.assertEqual(
                raised.exception.code, "building_source_snapshot_changed"
            )

    def test_selected_source_extract_coalesces_rectangular_scope(self):
        request = self._request()
        request["bbox"] = [103.80, 1.28, 103.83, 1.31]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = self._service(JobStore(root / "jobs")).create_job(request)
            plan = plan_building_scope(
                job,
                calibration_cell_size_meters=8192,
                calibration_halo_cells=1,
                calibration_minimum_samples=3,
            )
            runner = RecordingRunner()
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=runner,
                building_scope_mode="selected",
            )
            source = root / "source.osm.pbf"
            clipped = root / "attempt" / "clipped.osm.pbf"
            clipped.parent.mkdir()
            expected_sha = "4" * 64
            with patch("map_platform.pipeline.sha256_file", return_value=expected_sha):
                metrics = pipeline._extract_pbf(
                    job,
                    source,
                    clipped,
                    scope_plan=plan,
                    source_snapshot_sha256=expected_sha,
                )

            self.assertGreater(
                len(plan.document["sourceScope"]["rectanglesMeters"]), 1
            )
            self.assertEqual(metrics["coalescedRectangleCount"], 1)
            self.assertEqual(len(runner.calls), 1)
            extract_args = runner.calls[0][0]
            self.assertEqual(extract_args[:3], ["osmium", "extract", "--strategy=smart"])
            self.assertIn("--option=types=multipolygon,building", extract_args)
            self.assertIn("-b", extract_args)
            self.assertNotIn("--config", extract_args)
            self.assertIn("-o", extract_args)
            self.assertEqual(extract_args[extract_args.index("-o") + 1], str(clipped))

    def test_rectangle_coalescing_preserves_irregular_and_disconnected_union(self):
        self.assertEqual(
            _coalesce_projected_rectangles(
                [
                    [0, 0, 2, 2],
                    [2, 0, 4, 2],
                    [0, 2, 2, 4],
                    [10, 10, 12, 12],
                ]
            ),
            (
                (0, 0, 4, 2),
                (0, 2, 2, 4),
                (10, 10, 12, 12),
            ),
        )
        self.assertEqual(
            _coalesce_projected_rectangles(
                [
                    [0, 0, 2, 2],
                    [2, 0, 4, 2],
                    [0, 2, 2, 4],
                    [2, 2, 4, 4],
                ]
            ),
            ((0, 0, 4, 4),),
        )

    def test_selected_source_extract_fails_if_snapshot_changes_before_or_during(self):
        request = self._request()
        request["bbox"] = [103.80, 1.28, 103.83, 1.31]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = self._service(JobStore(root / "jobs")).create_job(request)
            plan = plan_building_scope(
                job,
                calibration_cell_size_meters=8192,
                calibration_halo_cells=1,
                calibration_minimum_samples=3,
            )
            runner = RecordingRunner()
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=runner,
                building_scope_mode="selected",
            )
            expected_sha = "6" * 64
            with patch("map_platform.pipeline.sha256_file", return_value="7" * 64):
                with self.assertRaises(BuildingScopeError) as before:
                    pipeline._extract_pbf(
                        job, root / "source.pbf", root / "clipped.pbf",
                        scope_plan=plan,
                        source_snapshot_sha256=expected_sha,
                    )
            self.assertEqual(before.exception.code, "building_source_snapshot_changed")
            self.assertEqual(runner.calls, [])

            with patch(
                "map_platform.pipeline.sha256_file",
                side_effect=[expected_sha, "8" * 64],
            ):
                with self.assertRaises(BuildingScopeError) as during:
                    pipeline._extract_pbf(
                        job, root / "source.pbf", root / "clipped.pbf",
                        scope_plan=plan,
                        source_snapshot_sha256=expected_sha,
                    )
            self.assertEqual(during.exception.code, "building_source_snapshot_changed")
            self.assertEqual(len(runner.calls), 1)

    def test_selected_closure_rehydration_checks_source_before_and_after(self):
        class MaterializingRunner(RecordingRunner):
            def run(self, args, *, cwd=None):
                super().run(args, cwd=cwd)
                if args[:2] == ["osmium", "merge"]:
                    Path(args[args.index("-o") + 1]).write_bytes(b"merged")
                return ""

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runner = MaterializingRunner()
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=runner,
                building_scope_mode="selected",
            )
            expected_sha = "a" * 64
            with patch("map_platform.pipeline.sha256_file", return_value="b" * 64):
                with self.assertRaises(BuildingScopeError) as before:
                    pipeline._rehydrate_building_closure(
                        root / "source.pbf",
                        root / "clipped.pbf",
                        root / "ids.txt",
                        expected_sha,
                        root,
                    )
            self.assertEqual(before.exception.code, "building_source_snapshot_changed")
            self.assertEqual(runner.calls, [])

            with patch(
                "map_platform.pipeline.sha256_file",
                side_effect=[expected_sha, "c" * 64],
            ):
                with self.assertRaises(BuildingScopeError) as during:
                    pipeline._rehydrate_building_closure(
                        root / "source.pbf",
                        root / "clipped.pbf",
                        root / "ids.txt",
                        expected_sha,
                        root,
                    )
            self.assertEqual(during.exception.code, "building_source_snapshot_changed")
            self.assertEqual(len(runner.calls), 2)
            self.assertFalse((root / "clipped-with-building-closure.osm.pbf").exists())

    @unittest.skipUnless(shutil.which("osmium"), "osmium is required")
    def test_selected_multi_rectangle_extract_runs_with_real_osmium(self):
        request = self._request()
        request["bbox"] = [103.79, 1.29, 103.86, 1.31]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = self._service(JobStore(root / "jobs")).create_job(request)
            plan = plan_building_scope(
                job,
                calibration_cell_size_meters=8192,
                calibration_halo_cells=1,
                calibration_minimum_samples=3,
            )
            self.assertGreater(
                len(plan.document["sourceScope"]["rectanglesMeters"]), 1
            )
            source = (
                Path(__file__).resolve().parents[3]
                / "tools/OSM_Extract/tests/fixtures/building_relations.osm"
            )
            clipped = root / "attempt" / "clipped.osm.pbf"
            clipped.parent.mkdir()
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                building_scope_mode="selected",
            )
            source_sha = hashlib.sha256(source.read_bytes()).hexdigest()
            pipeline._extract_pbf(
                job,
                source,
                clipped,
                scope_plan=plan,
                source_snapshot_sha256=source_sha,
            )
            self.assertTrue(clipped.is_file())
            info = subprocess.run(
                ["osmium", "fileinfo", "-e", str(clipped)],
                check=True,
                text=True,
                capture_output=True,
            ).stdout
            self.assertIn("Number of ways: 6", info)
            self.assertIn("Number of relations: 5", info)

    @unittest.skipUnless(shutil.which("osmium"), "osmium is required")
    def test_selected_preprocessing_rehydrates_output_relation_and_calibration_cells(self):
        source_region = SourceRegion(
            id="equator",
            provider="test",
            name="Equator",
            url="https://example.invalid/equator.osm.pbf",
            bounds=Bounds(-1.0, -1.0, 1.0, 1.0),
            checksum=None,
        )
        request = self._request()
        request["bbox"] = [0.0005, 0.0005, 0.003, 0.003]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = MapJobService(
                SourceIndex([source_region]),
                JobStore(root / "jobs"),
                label_target2_enabled=True,
                building_target3_enabled=True,
            ).create_job(request)
            repo_root = Path(__file__).resolve().parents[3]
            source_xml = (
                repo_root
                / "tools/OSM_Extract/tests/fixtures/boundary_relation_closure.osm"
            )
            source_pbf = root / "source.osm.pbf"
            subprocess.run(
                ["osmium", "cat", str(source_xml), "-o", str(source_pbf)],
                check=True,
                capture_output=True,
                text=True,
            )
            clipped_pbf = root / "clipped.osm.pbf"
            subprocess.run(
                [
                    "osmium", "getid", "--add-referenced", str(source_pbf),
                    "w10", "-o", str(clipped_pbf),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            source_sha = hashlib.sha256(source_pbf.read_bytes()).hexdigest()
            plan = plan_building_scope(
                job,
                calibration_cell_size_meters=8192,
                calibration_halo_cells=1,
                calibration_minimum_samples=3,
            )
            job_dir = root / "attempt"
            job_dir.mkdir()
            scope_path = job_dir / "scope-plan.json"
            plan.write(scope_path)
            pipeline = MapBuildPipeline(
                PipelinePaths(repo_root, root / "work", root / "packs"),
                building_scope_mode="selected",
            )
            cold_execution = {}
            sealed_manifest_path, calibration_generation = (
                pipeline._ensure_selected_calibration_generation(
                    source_pbf,
                    source_sha,
                    plan,
                    execution_sink=cold_execution,
                )
            )
            warm_execution = {}
            with patch.object(
                pipeline.runner,
                "run",
                side_effect=AssertionError(
                    "warm calibration generation must not invoke preprocessing"
                ),
            ):
                _, repeated_generation = (
                    pipeline._ensure_selected_calibration_generation(
                        source_pbf,
                        source_sha,
                        plan,
                        execution_sink=warm_execution,
                    )
                )
            self.assertEqual(calibration_generation, repeated_generation)
            self.assertEqual(cold_execution["cacheOutcome"], "rebuilt")
            self.assertGreater(cold_execution["cellsMisses"], 0)
            self.assertGreaterEqual(cold_execution["areasSeen"], 1)
            self.assertGreaterEqual(cold_execution["durationSeconds"], 0)
            self.assertEqual(warm_execution["cacheOutcome"], "hit")
            self.assertEqual(warm_execution["cellsMisses"], 0)
            self.assertEqual(
                warm_execution["cellsHits"], warm_execution["cellsRequested"]
            )
            sealed_manifest_bytes = sealed_manifest_path.read_bytes()
            malformed_domain = json.loads(sealed_manifest_bytes)
            malformed_domain["completeDomainCellCount"] += 1
            malformed_body = {
                key: value
                for key, value in malformed_domain.items()
                if key != "manifestSha256"
            }
            malformed_domain["manifestSha256"] = hashlib.sha256(
                json.dumps(
                    malformed_body,
                    sort_keys=True,
                    separators=(",", ":"),
                    ensure_ascii=False,
                    allow_nan=False,
                ).encode("utf-8")
            ).hexdigest()
            sealed_manifest_path.write_text(
                json.dumps(
                    malformed_domain,
                    sort_keys=True,
                    separators=(",", ":"),
                ),
                encoding="utf-8",
            )
            with patch.object(
                pipeline.runner,
                "run",
                side_effect=AssertionError(
                    "invalid complete-domain proof must trigger preprocessing"
                ),
            ):
                with self.assertRaisesRegex(
                    AssertionError, "invalid complete-domain proof"
                ):
                    pipeline._ensure_selected_calibration_generation(
                        source_pbf,
                        source_sha,
                        plan,
                    )
            sealed_manifest_path.write_bytes(sealed_manifest_bytes)
            calibration_manifest, source_index_manifest, metrics = (
                pipeline._prepare_selected_building_inputs(
                    source_pbf,
                    clipped_pbf,
                    source_sha,
                    scope_path,
                    job_dir,
                    expected_calibration_generation=calibration_generation,
                )
            )

            closure = json.loads(
                (job_dir / "building-closure-plan.json").read_text()
            )
            self.assertIn("r100", closure["requiredRelationKeys"])
            self.assertIn("w20", closure["requiredWayKeys"])
            self.assertIn([1, 0], closure["calibrationTargetCells"])
            calibration = json.loads(calibration_manifest.read_text())
            bound_cells = {(cell["x"], cell["y"]) for cell in calibration["cells"]}
            self.assertIn((1, 0), bound_cells)
            self.assertEqual(metrics["closure"]["relationCount"], 1)
            identity = selected_building_identity(
                source_snapshot_sha256=source_sha,
                rules_path=(
                    repo_root / "tools/OSM_Extract/conf/building_height_rules.yaml"
                ),
                scope_plan=plan,
                calibration_generation=calibration_generation,
            )
            summary = MapBuildPipeline._building_preprocessing_summary(
                {
                    "mode": "selected",
                    "scope": plan.summary(),
                    "identity": identity,
                    **metrics,
                    "relationRetries": [],
                }
            )
            self.assertEqual(summary["identitySha256"], identity["identitySha256"])
            self.assertEqual(
                summary["calibration"]["manifestSha256"],
                calibration["manifestSha256"],
            )

            info = subprocess.run(
                ["osmium", "fileinfo", "-e", str(clipped_pbf)],
                check=True,
                text=True,
                capture_output=True,
            ).stdout
            self.assertIn("Number of nodes: 8", info)
            self.assertIn("Number of ways: 2", info)
            self.assertIn("Number of relations: 1", info)
            audit_output = job_dir / "relations.json"
            audit = subprocess.run(
                [
                    sys.executable,
                    str(repo_root / "tools/OSM_Extract/scripts/extract_building_relations.py"),
                    str(clipped_pbf),
                    str(audit_output),
                    "--source-index-manifest", str(source_index_manifest),
                    "--scope-plan", str(scope_path),
                ],
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(audit.returncode, 0, audit.stdout + audit.stderr)

    def test_selected_relation_closure_retries_with_the_bounded_policy(self):
        request = self._request()
        request["bbox"] = [103.78, 1.25, 103.86, 1.29]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = self._service(JobStore(root / "jobs")).create_job(request)
            repo_root = Path(__file__).resolve().parents[3]
            pipeline = MapBuildPipeline(
                PipelinePaths(repo_root, root / "work", root / "packs"),
                runner=CapturingRunner(),
                building_scope_mode="selected",
                producer_build_sha256="a" * 64,
                producer_image_digest="sha256:" + "b" * 64,
            )
            observed_buffers = []
            observed_retry_counts = []
            observed_metrics = {}
            failure = subprocess.CalledProcessError(
                2,
                ["pbf_to_geojson"],
                output=(
                    'BUILDING_PREPROCESS_FAILURE:{"code":"building_relation_incomplete",'
                    '"message":"missing member"}\n'
                ),
            )

            def capture_extract(_job, _source, _output, **kwargs):
                observed_buffers.append(
                    kwargs["scope_plan"].document["policy"]["geometryBufferMeters"]
                )

            def capture_conversion(*_args, **kwargs):
                observed_retry_counts.append(kwargs["relation_retry_count"])
                if len(observed_retry_counts) == 1:
                    raise failure

            def capture_package(*_args, **kwargs):
                observed_metrics.update(kwargs["build_metrics"])
                return object()

            with patch.object(
                pipeline.source_cache,
                "ensure",
                return_value=SimpleNamespace(path=root / "source.pbf", sha256="3" * 64),
            ), patch.object(
                pipeline, "_extract_pbf", side_effect=capture_extract
            ), patch.object(
                pipeline,
                "_ensure_selected_calibration_generation",
                side_effect=lambda _path, sha, scope, **_kwargs: self._calibration_generation(
                    sha, scope
                ),
            ), patch.object(
                pipeline,
                "_prepare_selected_building_inputs",
                return_value=(
                    root / "calibration.json",
                    root / "index.json",
                    {"closure": {"closurePlanSha256": "6" * 64}},
                ),
            ), patch.object(
                pipeline, "_convert_to_geojson", side_effect=capture_conversion
            ), patch.object(
                pipeline,
                "_extract_features",
                side_effect=lambda *_args, **kwargs: {
                    "buildingScope": {
                        "scopePlanSha256": json.loads(
                            kwargs["scope_plan_path"].read_bytes()
                        )["scopePlanSha256"],
                        "outputBlockCount": len(
                            json.loads(kwargs["scope_plan_path"].read_bytes())[
                                "outputBlocks"
                            ]
                        ),
                    }
                },
            ), patch.object(
                pipeline, "_stage_vectmap"
            ), patch.object(
                pipeline, "_package_map", side_effect=capture_package
            ):
                reserved_keys = pipeline.reuse_keys(job)
                base_exact_key = reserved_keys.exact
                job.build_cache_key = reserved_keys.exact
                job.build_compatibility_key = reserved_keys.compatibility
                pipeline.build(job)

            self.assertEqual(observed_buffers, [256, 512])
            self.assertEqual(observed_retry_counts, [0, 1])
            retries = observed_metrics["buildingPreprocessing"]["relationRetries"]
            self.assertEqual(len(retries), 1)
            self.assertEqual(retries[0]["reasonCode"], "building_relation_incomplete")
            self.assertEqual(retries[0]["bufferMeters"], 512)
            attempt_scope = observed_metrics["buildingPreprocessing"]["attemptScope"]
            self.assertEqual(attempt_scope["closurePlanSha256"], "6" * 64)
            self.assertEqual(
                observed_metrics["buildingPreprocessing"]["blockCacheIdentity"]
                ["geometryBufferMeters"],
                512,
            )
            self.assertEqual(job.build_cache_aliases, [base_exact_key])
            self.assertEqual(
                job.build_identity_derivation,
                {
                    "baseExactKey": base_exact_key,
                    "strategy": "bounded_relation_retry",
                    "attemptScope": attempt_scope,
                },
            )
            self.assertEqual(
                job.build_cache_key,
                hashlib.sha256(
                    json.dumps(
                        job.build_identity_derivation,
                        sort_keys=True,
                        separators=(",", ":"),
                        ensure_ascii=False,
                        allow_nan=False,
                    ).encode("utf-8")
                ).hexdigest(),
            )

    def test_selected_relation_closure_fails_typed_when_retry_scope_hits_cap(self):
        request = self._request()
        request["bbox"] = [103.80, 1.28, 103.83, 1.31]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = self._service(JobStore(root / "jobs")).create_job(request)
            repo_root = Path(__file__).resolve().parents[3]
            pipeline = MapBuildPipeline(
                PipelinePaths(repo_root, root / "work", root / "packs"),
                runner=CapturingRunner(),
                building_scope_mode="selected",
            )
            observed_buffers = []
            failure = subprocess.CalledProcessError(
                2,
                ["pbf_to_geojson"],
                output=(
                    'BUILDING_PREPROCESS_FAILURE:{"code":"building_relation_incomplete",'
                    '"message":"missing member"}\n'
                ),
            )

            def capture_extract(_job, _source, _output, **kwargs):
                observed_buffers.append(
                    kwargs["scope_plan"].document["policy"]["geometryBufferMeters"]
                )

            permissive_policy = BuildingScopePolicy(
                max_source_to_output_area_basis_points=100_000,
                max_source_area_m2=1_000_000_000,
            )

            def permissive_plan(*args, **kwargs):
                return plan_building_scope(
                    *args,
                    **kwargs,
                    policy=permissive_policy,
                )

            with patch(
                "map_platform.pipeline.plan_building_scope",
                side_effect=permissive_plan,
            ), patch.object(
                pipeline.source_cache,
                "ensure",
                return_value=SimpleNamespace(path=root / "source.pbf", sha256="9" * 64),
            ), patch.object(
                pipeline, "_extract_pbf", side_effect=capture_extract
            ), patch.object(
                pipeline,
                "_ensure_selected_calibration_generation",
                side_effect=lambda _path, sha, scope, **_kwargs: self._calibration_generation(
                    sha, scope
                ),
            ), patch.object(
                pipeline,
                "_prepare_selected_building_inputs",
                return_value=(root / "calibration.json", root / "index.json", {}),
            ), patch.object(
                pipeline, "_convert_to_geojson", side_effect=failure
            ):
                with self.assertRaises(BuildingScopeError) as raised:
                    pipeline.build(job)

            self.assertEqual(raised.exception.code, "building_relation_incomplete")
            self.assertEqual(observed_buffers, [256, 512, 2048])

    def test_target_three_is_forwarded_and_requires_both_stats_records(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = self._service(JobStore(root / "jobs")).create_job(self._request())
            runner = CapturingRunner()
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"), runner=runner
            )
            metrics = pipeline._extract_features(job, root / "features", root / "raw")
            self.assertIn("3", runner.args)
            self.assertEqual(metrics["buildingBuild"]["recordCount"], 1)
            self.assertEqual(metrics["labelBuild"]["blocks"], 1)

    def test_target_three_preserves_polygon_selection_and_completes_building_relations(self):
        request = self._request()
        request.pop("bbox")
        request["mode"] = "custom_polygon"
        request["geometry"] = {
            "type": "Polygon",
            "coordinates": [[
                [103.75, 1.24],
                [103.90, 1.24],
                [103.90, 1.35],
                [103.75, 1.24],
            ]],
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = self._service(JobStore(root / "jobs")).create_job(request)
            runner = CapturingRunner()
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"), runner=runner
            )
            pipeline._extract_features(job, root / "features", root / "raw")
            self.assertIn("--selection-geometry", runner.args)
            selection_path = Path(
                runner.args[runner.args.index("--selection-geometry") + 1]
            )
            self.assertEqual(
                json.loads(selection_path.read_text()),
                request["geometry"],
            )

            pipeline._extract_pbf(
                job,
                root / "source.pbf",
                root / "clipped.pbf",
                bounds=job.geometry.bounds,
                force_bounds=True,
            )
            self.assertIn("--option=types=multipolygon,building", runner.args)
            self.assertIn("-b", runner.args)

    def test_target_three_build_aligns_polygon_output_to_complete_blocks(self):
        request = self._request()
        request.pop("bbox")
        request["mode"] = "custom_polygon"
        request["geometry"] = {
            "type": "Polygon",
            "coordinates": [[
                [103.75, 1.24],
                [103.90, 1.24],
                [103.90, 1.35],
                [103.75, 1.24],
            ]],
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = self._service(JobStore(root / "jobs")).create_job(request)
            repo_root = Path(__file__).resolve().parents[3]
            pipeline = MapBuildPipeline(
                PipelinePaths(repo_root, root / "work", root / "packs"),
                runner=CapturingRunner(),
            )
            observed = {}

            def capture_pbf(
                _job, _source, _output, *, bounds, force_bounds, **_kwargs
            ):
                observed["source"] = bounds
                self.assertTrue(force_bounds)

            def capture_features(
                _job,
                _prefix,
                _output,
                *,
                bounds,
                on_progress,
                **_kwargs,
            ):
                del on_progress
                observed["output"] = bounds
                return {}

            with patch.object(
                pipeline,
                "_source_pbf_path",
                return_value=root / "source.pbf",
            ), patch.object(
                pipeline,
                "_extract_pbf",
                side_effect=capture_pbf,
            ), patch.object(
                pipeline,
                "_convert_to_geojson",
            ), patch.object(
                pipeline,
                "_extract_features",
                side_effect=capture_features,
            ), patch.object(
                pipeline,
                "_stage_vectmap",
            ), patch.object(
                pipeline,
                "_package_map",
                return_value=object(),
            ):
                pipeline.build(job)

            output_extent = aligned_projected_extent(observed["output"])
            self.assertEqual(
                output_extent,
                aligned_projected_extent(job.geometry.bounds),
            )
            self.assertAlmostEqual(
                reuse_module._lon_to_x(observed["output"].min_lon),
                output_extent[0],
            )
            self.assertAlmostEqual(
                reuse_module._lat_to_y(observed["output"].min_lat),
                output_extent[1],
            )
            self.assertAlmostEqual(
                reuse_module._lon_to_x(observed["output"].max_lon),
                output_extent[2],
            )
            self.assertAlmostEqual(
                reuse_module._lat_to_y(observed["output"].max_lat),
                output_extent[3],
            )
            self.assertLessEqual(
                observed["output"].min_lon,
                job.geometry.bounds.min_lon,
            )
            self.assertGreaterEqual(
                observed["output"].max_lon,
                job.geometry.bounds.max_lon,
            )
            self.assertLess(observed["source"].min_lon, observed["output"].min_lon)
            self.assertGreater(observed["source"].max_lon, observed["output"].max_lon)

    def test_manifest_derives_signed_building_summary_from_fmb4(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = self._service(JobStore(root / "jobs")).create_job(self._request())
            job.map_id = stable_map_id(job)
            block = root / "VECTMAP" / job.map_id / "+0000+0000" / "1.fmb"
            asset = root / "VECTMAP" / job.map_id / "assets" / "street-labels.fma"
            block.parent.mkdir(parents=True)
            asset.parent.mkdir(parents=True)
            block.write_bytes(one_building_fmb4())
            asset.write_bytes(one_label_fma1())
            stats = {
                "recordCount": 1,
                "explicitHeightCount": 1,
                "levelsHeightCount": 0,
                "inheritedHeightCount": 0,
                "localMedianHeightCount": 0,
                "classDefaultHeightCount": 0,
            }
            identity_body = {
                "sourceSnapshotSha256": "3" * 64,
                "scope": {"scopePlanSha256": "1" * 64},
                "sourceIndex": {"schemaVersion": 1, "algorithmVersion": 2},
                "calibration": {
                    "calibrationKey": "7" * 64,
                    "rulesSha256": "8" * 64,
                    "manifestSha256": "9" * 64,
                    "entrySetSha256": "a" * 64,
                    "generationCellCount": 20,
                },
            }
            identity_sha256 = hashlib.sha256(
                json.dumps(
                    identity_body, sort_keys=True, separators=(",", ":")
                ).encode()
            ).hexdigest()
            preprocessing = MapBuildPipeline._building_preprocessing_summary(
                {
                    "mode": "selected",
                    "scope": {
                        "scopePolicyVersion": 1,
                        "scopePlanSha256": "1" * 64,
                        "requestedApproximateAreaM2": 24_000_000,
                        "outputAreaM2": 100_000_000,
                        "sourceAreaM2": 110_000_000,
                        "sourceToOutputAreaBasisPoints": 11_000,
                        "outputBlockCount": 6,
                        "calibrationCellCount": 4,
                        "calibrationSampleCellCount": 12,
                        "geometryBufferMeters": 256,
                        "sourceBoundsE7": [1, 2, 3, 4],
                    },
                    "identity": {
                        **identity_body,
                        "identitySha256": identity_sha256,
                    },
                    "sourceIndex": {
                        "sourceSnapshotSha256": "3" * 64,
                        "indexKey": "4" * 64,
                        "databaseSha256": "5" * 64,
                        "schemaVersion": 1,
                        "algorithmVersion": 2,
                        "nodeCount": 8,
                        "wayCount": 2,
                        "relationCount": 1,
                        "relationMemberCount": 2,
                    },
                    "closure": {
                        "closurePlanSha256": "6" * 64,
                        "candidateCount": 2,
                        "relationCount": 1,
                        "wayCount": 2,
                        "nodeCount": 8,
                        "calibrationCellCount": 9,
                    },
                    "calibration": {
                        "sourceSnapshotSha256": "3" * 64,
                        "calibrationKey": "7" * 64,
                        "rulesSha256": "8" * 64,
                        "manifestSha256": "9" * 64,
                        "entrySetSha256": "a" * 64,
                        "cellCount": 20,
                        "cellsRequested": 12,
                        "cellsHits": 10,
                        "cellsMisses": 2,
                        "cellsRebuilt": 0,
                    },
                    "relationRetries": [],
                }
            )
            manifest = build_manifest(
                job,
                root,
                PipelineMetadata(),
                building_stats=stats,
                building_preprocessing=preprocessing,
            )
            self.assertEqual(manifest["target"]["formatVersion"], 3)
            self.assertEqual(manifest["target"]["buildingProfileVersion"], 1)
            self.assertEqual(manifest["buildings"], stats)
            self.assertEqual(
                manifest["buildingPreprocessing"]["identitySha256"],
                identity_sha256,
            )
            self.assertNotIn("durationMilliseconds", json.dumps(preprocessing))
            self.assertEqual(
                json.loads(canonical_manifest_bytes(manifest))[
                    "buildingPreprocessing"
                ],
                preprocessing,
            )

            repeated_root = root / "repeat"
            shutil.copytree(root / "VECTMAP", repeated_root / "VECTMAP")
            repeated_job = deepcopy(job)
            repeated_job.created_at = "2099-01-01T00:00:00Z"
            repeated_manifest = build_manifest(
                repeated_job,
                repeated_root,
                PipelineMetadata(),
                building_stats=stats,
                building_preprocessing=preprocessing,
            )
            self.assertEqual(manifest, repeated_manifest)
            first_archive = write_pack_archive(root, manifest, root / "first.zip")
            repeated_archive = write_pack_archive(
                repeated_root,
                repeated_manifest,
                repeated_root / "repeat.zip",
            )
            self.assertEqual(first_archive.read_bytes(), repeated_archive.read_bytes())

            stats["explicitHeightCount"] = 0
            stats["classDefaultHeightCount"] = 1
            with self.assertRaisesRegex(ValueError, "do not match FMB v4"):
                build_manifest(job, root, PipelineMetadata(), building_stats=stats)


if __name__ == "__main__":
    unittest.main()
