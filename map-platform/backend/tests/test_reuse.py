import hashlib
import json
import tempfile
import unittest
import zipfile
from contextlib import nullcontext
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from map_platform.artifacts import ArtifactRecord, sha256_file
from map_platform.jobs import JobStore, MapJobService
from map_platform.manifest import PipelineMetadata, build_identity_manifest, build_manifest, stable_map_id, write_pack_archive
from map_platform.models import Bounds, JobStatus, SourceRegion
from map_platform.pipeline import MapBuildPipeline, MapBuildResult, PipelinePaths, run_job
from map_platform.building_identity import (
    canonical_json as canonical_building_json,
    selected_building_identity,
    selected_calibration_identity,
)
from map_platform.building_scope import plan_building_scope
from map_platform.map_buildings import load_building_calibration_window
from map_platform.reuse import (
    SubsetReuseUnavailable,
    aligned_processing_bounds,
    block_from_pack_path,
    child_pack_path,
    expanded_building_source_bounds,
    parent_contains_child_blocks,
    required_blocks,
    reuse_keys,
)
from map_platform import reuse as reuse_module
from map_platform.sources import SourceIndex
from map_platform.worker import MapWorker
from tests.map_label_fixtures import (
    empty_fma1,
    empty_fmb3,
    one_building_fmb4,
    one_label_fma1,
)


PRODUCER_BUILD = "1" * 64
PRODUCER_IMAGE = "sha256:" + "2" * 64


class VersionRunner:
    def run(self, args, *, cwd=None):
        del cwd
        if args == ["osmium", "--version"]:
            return "osmium test"
        raise AssertionError(f"unexpected command: {args}")


class NoFullBuildPipeline(MapBuildPipeline):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.full_build_calls = 0

    def build(self, job, **kwargs):
        del job, kwargs
        self.full_build_calls += 1
        raise AssertionError("full map build should not run")


class TrackingSubsetPipeline(NoFullBuildPipeline):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.subset_build_calls = 0

    def build_subset(self, job, parent, **kwargs):
        self.subset_build_calls += 1
        return MapBuildPipeline.build_subset(self, job, parent, **kwargs)


class FullBuildFallbackPipeline(MapBuildPipeline):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.full_build_calls = 0

    def build(self, job, **kwargs):
        del kwargs
        self.full_build_calls += 1
        map_id = stable_map_id(job)
        archive = self.paths.work_root / job.job_id / "fallback" / f"{map_id}.zip"
        archive.parent.mkdir(parents=True, exist_ok=True)
        archive.write_bytes(b"full-build-fallback")
        return MapBuildResult(map_id, archive, [])


class TrackingFullBuildFallbackPipeline(FullBuildFallbackPipeline):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.subset_build_calls = 0

    def build_subset(self, job, parent, **kwargs):
        self.subset_build_calls += 1
        return MapBuildPipeline.build_subset(self, job, parent, **kwargs)


class MapReuseTests(unittest.TestCase):
    def setUp(self):
        self.source = SourceRegion(
            id="asia/singapore",
            provider="geofabrik",
            name="Singapore",
            url="https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf",
            bounds=Bounds(100.0, -2.0, 106.0, 4.0),
            published_at="2026-07-15T00:00:00Z",
            checksum="3" * 64,
        )

    @staticmethod
    def _renderer_request(format_version: int) -> dict:
        return {
            "target": {
                "renderer": "esp32-fmb",
                "rendererFormatVersion": format_version,
                "firmwareVersion": "1.2.3",
            },
            "labels": {
                "profileVersion": 1,
                "preferredLanguages": ["zh-Hant", "en"],
                "internationalFallback": "en",
            },
        }

    def test_exact_key_ignores_ownership_but_not_geometry_or_pack_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(SourceIndex([self.source]), JobStore(tmp))
            first = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.70, 1.20, 104.00, 1.50],
                    "displayName": "Pack name",
                }
            )
            second = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.70, 1.20, 104.00, 1.50],
                    "displayName": "Pack name",
                }
            )
            different = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.75, 1.25, 103.90, 1.40]}
            )
            renamed_pack = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.70, 1.20, 104.00, 1.50],
                    "displayName": "Another pack name",
                }
            )

            first_keys = reuse_keys(
                first,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            second_keys = reuse_keys(
                second,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            different_keys = reuse_keys(
                different,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            renamed_pack_keys = reuse_keys(
                renamed_pack,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )

            self.assertEqual(first_keys, second_keys)
            self.assertEqual(first_keys.compatibility, different_keys.compatibility)
            self.assertNotEqual(first_keys.exact, different_keys.exact)
            self.assertEqual(first_keys.compatibility, renamed_pack_keys.compatibility)
            self.assertNotEqual(first_keys.exact, renamed_pack_keys.exact)
            first.source_region = replace(
                first.source_region,
                preview_geometry={
                    "type": "Polygon",
                    "coordinates": [[
                        [103.76, 1.25],
                        [103.90, 1.25],
                        [103.82, 1.35],
                        [103.76, 1.25],
                    ]],
                },
            )
            preview_keys = reuse_keys(
                first,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            self.assertEqual(first_keys.compatibility, preview_keys.compatibility)
            self.assertEqual(first_keys.exact, preview_keys.exact)
            first.source_region = replace(
                first.source_region,
                name="Renamed source",
                license="Different attribution license",
            )
            source_metadata_keys = reuse_keys(
                first,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            self.assertEqual(preview_keys.compatibility, source_metadata_keys.compatibility)
            self.assertNotEqual(preview_keys.exact, source_metadata_keys.exact)
            self.assertIsNone(
                reuse_keys(
                    first,
                    producer_build_sha256=None,
                    producer_image_digest=PRODUCER_IMAGE,
                )
            )
            changed_producer = reuse_keys(
                first,
                producer_build_sha256="4" * 64,
                producer_image_digest=PRODUCER_IMAGE,
            )
            self.assertNotEqual(first_keys, changed_producer)
            first.source_region = replace(first.source_region, checksum=None)
            first_source_snapshot = reuse_keys(
                first,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
                source_snapshot_sha256="5" * 64,
            )
            changed_source_snapshot = reuse_keys(
                first,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
                source_snapshot_sha256="6" * 64,
            )
            self.assertIsNotNone(first_source_snapshot)
            self.assertIsNotNone(changed_source_snapshot)
            self.assertNotEqual(first_source_snapshot, changed_source_snapshot)

    def test_exact_key_uses_source_name_when_request_has_no_pack_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(SourceIndex([self.source]), JobStore(tmp))
            unnamed = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.70, 1.20, 104.00, 1.50]}
            )
            explicitly_named = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.70, 1.20, 104.00, 1.50],
                    "displayName": "Singapore",
                }
            )

            self.assertEqual(
                reuse_keys(
                    unnamed,
                    producer_build_sha256=PRODUCER_BUILD,
                    producer_image_digest=PRODUCER_IMAGE,
                ),
                reuse_keys(
                    explicitly_named,
                    producer_build_sha256=PRODUCER_BUILD,
                    producer_image_digest=PRODUCER_IMAGE,
                ),
            )

    def test_bbox_processing_bounds_are_complete_blocks(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(SourceIndex([self.source]), JobStore(tmp))
            parent = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.70, 1.20, 104.00, 1.50]}
            )
            child = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.80, 1.30, 103.90, 1.40]}
            )

            aligned = aligned_processing_bounds(child)
            self.assertLessEqual(aligned.min_lon, child.geometry.bounds.min_lon)
            self.assertLessEqual(aligned.min_lat, child.geometry.bounds.min_lat)
            self.assertGreaterEqual(aligned.max_lon, child.geometry.bounds.max_lon)
            self.assertGreaterEqual(aligned.max_lat, child.geometry.bounds.max_lat)
            self.assertTrue(parent_contains_child_blocks(parent, child))
            self.assertTrue(required_blocks(child.geometry.bounds))

    def test_building_source_bounds_cover_complete_calibration_halo_cells(self):
        bounds = Bounds(
            reuse_module._x_to_lon(4096),
            reuse_module._y_to_lat(4096),
            reuse_module._x_to_lon(8192),
            reuse_module._y_to_lat(8192),
        )
        expanded = expanded_building_source_bounds(
            bounds,
            cell_size_meters=8192,
            halo_cells=1,
        )
        self.assertAlmostEqual(reuse_module._lon_to_x(expanded.min_lon), -8192)
        self.assertAlmostEqual(reuse_module._lat_to_y(expanded.min_lat), -8192)
        self.assertAlmostEqual(reuse_module._lon_to_x(expanded.max_lon), 16384)
        self.assertAlmostEqual(reuse_module._lat_to_y(expanded.max_lat), 16384)

    def test_calibration_bounds_preserve_sub_meter_cell_crossings(self):
        bounds = Bounds(
            reuse_module._x_to_lon(8191.6),
            reuse_module._y_to_lat(8191.6),
            reuse_module._x_to_lon(8192.4),
            reuse_module._y_to_lat(8192.4),
        )

        expanded = expanded_building_source_bounds(
            bounds,
            cell_size_meters=8192,
            halo_cells=1,
        )

        self.assertAlmostEqual(reuse_module._lon_to_x(expanded.min_lon), -8192)
        self.assertAlmostEqual(reuse_module._lat_to_y(expanded.min_lat), -8192)
        self.assertAlmostEqual(reuse_module._lon_to_x(expanded.max_lon), 24576)
        self.assertAlmostEqual(reuse_module._lat_to_y(expanded.max_lat), 24576)

    def test_worker_reuses_identical_ready_pack_without_building(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            parent = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.70, 1.20, 104.00, 1.50],
                }
            )
            child = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.70, 1.20, 104.00, 1.50],
                }
            )
            parent = store.update_user_label(parent.job_id, "Parent")
            store.update_user_label(child.job_id, "My local name")
            keys = reuse_keys(
                parent,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            parent.build_cache_key = keys.exact
            parent.build_compatibility_key = keys.compatibility
            pack = self._make_parent_archive(root, parent, child)
            store.update_status(
                parent.job_id,
                JobStatus.READY,
                map_id=parent.map_id,
                pack_path=str(pack),
                pack_bytes=pack.stat().st_size,
                build_cache_key=keys.exact,
                build_compatibility_key=keys.compatibility,
                artifacts=parent.artifacts,
                finished=True,
            )
            pipeline = NoFullBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=VersionRunner(),
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )

            result = MapWorker(store, pipeline, worker_id="worker-reuse").run_next()

            self.assertTrue(result.processed)
            self.assertEqual(result.job.job_id, child.job_id)
            self.assertEqual(result.job.status, JobStatus.READY)
            self.assertEqual(result.job.reuse_strategy, "exact")
            self.assertEqual(result.job.reuse_source_job_id, parent.job_id)
            self.assertEqual(result.job.pack_path, str(pack))
            self.assertEqual(pipeline.full_build_calls, 0)

    def test_worker_rediscovers_persisted_bounded_retry_artifact_by_alias(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(
                SourceIndex([self.source]),
                store,
                label_target2_enabled=True,
                building_target3_enabled=True,
            )
            request = {
                "mode": "custom_bbox",
                "bbox": [103.80, 1.28, 103.86, 1.34],
                **self._renderer_request(3),
            }
            parent = service.create_job(request)
            child = service.create_job(request)
            repo_root = Path(__file__).resolve().parents[3]
            rules_path = repo_root / "tools/OSM_Extract/conf/building_height_rules.yaml"
            calibration = load_building_calibration_window(rules_path)

            def scope(job, buffer=None):
                return plan_building_scope(
                    job,
                    calibration_cell_size_meters=calibration.cell_size_meters,
                    calibration_halo_cells=calibration.halo_cells,
                    calibration_minimum_samples=calibration.minimum_samples,
                    geometry_buffer_meters=buffer,
                )

            initial_plan = scope(parent)
            retry_plan = scope(parent, 512)
            calibration_identity = selected_calibration_identity(
                source_snapshot_sha256="3" * 64,
                rules_path=rules_path,
                scope_plan=initial_plan,
            )
            generation = {
                "calibrationKey": calibration_identity["calibrationKey"],
                "manifestSha256": "4" * 64,
                "entrySetSha256": "5" * 64,
                "cellCount": 12,
            }
            identity = selected_building_identity(
                source_snapshot_sha256="3" * 64,
                rules_path=rules_path,
                scope_plan=initial_plan,
                calibration_generation=generation,
            )
            base_keys = reuse_keys(
                parent,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
                building_preprocessing_identity=identity,
            )
            retry_summary = retry_plan.summary()
            attempt_scope = {
                "scopePlanSha256": retry_plan.sha256,
                "sourceAreaM2": retry_summary["sourceAreaM2"],
                "sourceToOutputAreaBasisPoints": retry_summary[
                    "sourceToOutputAreaBasisPoints"
                ],
                "geometryBufferMeters": 512,
                "sourceBoundsE7": retry_summary["sourceBoundsE7"],
                "closurePlanSha256": "6" * 64,
            }
            preprocessing = MapBuildPipeline._building_preprocessing_summary(
                {
                    "mode": "selected",
                    "scope": initial_plan.summary(),
                    "identity": identity,
                    "sourceIndex": {
                        "indexKey": "7" * 64,
                        "sourceSnapshotSha256": "3" * 64,
                        "databaseSha256": "8" * 64,
                        "schemaVersion": 1,
                        "algorithmVersion": 2,
                        "nodeCount": 8,
                        "wayCount": 2,
                        "relationCount": 1,
                        "relationMemberCount": 2,
                    },
                    "closure": {
                        "closurePlanSha256": "9" * 64,
                        "candidateCount": 2,
                        "relationCount": 1,
                        "wayCount": 2,
                        "nodeCount": 8,
                        "calibrationCellCount": 9,
                    },
                    "calibration": {
                        "calibrationKey": generation["calibrationKey"],
                        "sourceSnapshotSha256": "3" * 64,
                        "rulesSha256": calibration_identity["rulesSha256"],
                        "manifestSha256": generation["manifestSha256"],
                        "entrySetSha256": generation["entrySetSha256"],
                        "cellCount": generation["cellCount"],
                        "cellsRequested": 9,
                        "cellsHits": 9,
                        "cellsMisses": 0,
                        "cellsRebuilt": 0,
                    },
                    "attemptScope": attempt_scope,
                }
            )
            derivation = {
                "baseExactKey": base_keys.exact,
                "strategy": "bounded_relation_retry",
                "attemptScope": attempt_scope,
            }
            derived_key = hashlib.sha256(
                canonical_building_json(derivation)
            ).hexdigest()
            parent.map_id = stable_map_id(parent)
            parent.build_cache_key = derived_key
            parent.build_cache_aliases = [base_keys.exact]
            parent.build_identity_derivation = derivation
            parent.build_compatibility_key = base_keys.compatibility
            pack_root = root / "retry-pack"
            for block in initial_plan.output_blocks:
                path = pack_root / child_pack_path(parent.map_id, block, "fmb")
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(one_building_fmb4())
            font_path = (
                pack_root / "VECTMAP" / parent.map_id / "assets" / "street-labels.fma"
            )
            font_path.parent.mkdir(parents=True, exist_ok=True)
            font_path.write_bytes(one_label_fma1())
            manifest = build_manifest(
                parent,
                pack_root,
                PipelineMetadata(
                    osmium_version="producer-image-pinned",
                    osm_extract_revision=PRODUCER_BUILD,
                    image_digest=PRODUCER_IMAGE,
                ),
                building_preprocessing=preprocessing,
            )
            archive = write_pack_archive(pack_root, manifest, root / "retry.zip")
            artifacts = [
                ArtifactRecord(
                    format="zip-stored-v1",
                    media_type="application/zip",
                    filename=archive.name,
                    object_key=f"test/{archive.name}",
                    bytes=archive.stat().st_size,
                    sha256=sha256_file(archive),
                )
            ]
            store.update_status(
                parent.job_id,
                JobStatus.READY,
                map_id=parent.map_id,
                pack_path=str(archive),
                pack_bytes=archive.stat().st_size,
                artifacts=artifacts,
                build_cache_key=derived_key,
                build_cache_aliases=[base_keys.exact],
                build_identity_derivation=derivation,
                build_compatibility_key=base_keys.compatibility,
                artifact_metrics={
                    "buildingPreprocessing": preprocessing,
                    "buildingPhaseTimings": {"blockEncoding": 9.0},
                },
                finished=True,
            )
            pipeline = NoFullBuildPipeline(
                PipelinePaths(repo_root, root / "work", root / "packs"),
                runner=VersionRunner(),
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
                building_scope_mode="selected",
            )
            cached_source = SimpleNamespace(path=root / "source.pbf", sha256="3" * 64)

            def ensure_calibration(*_args, execution_sink=None, **_kwargs):
                execution_sink.update(
                    {
                        "cacheOutcome": "rebuilt",
                        "cellsRequested": 12,
                        "cellsHits": 0,
                        "cellsMisses": 12,
                        "cellsRebuilt": 12,
                        "durationSeconds": 1.25,
                    }
                )
                return root / "calibration.json", generation

            with patch.object(
                pipeline.source_cache, "ensure", return_value=cached_source
            ), patch.object(
                pipeline,
                "_ensure_selected_calibration_generation",
                side_effect=ensure_calibration,
            ):
                result = MapWorker(
                    store, pipeline, worker_id="worker-retry-alias"
                ).run_next()

            reloaded = store.get(child.job_id)
            self.assertEqual(result.job.status, JobStatus.READY)
            self.assertEqual(result.job.reuse_strategy, "exact")
            self.assertEqual(reloaded.build_cache_key, derived_key)
            self.assertEqual(reloaded.build_cache_aliases, [base_keys.exact])
            self.assertEqual(reloaded.build_identity_derivation, derivation)
            self.assertEqual(reloaded.reuse_source_job_id, parent.job_id)
            self.assertEqual(
                reloaded.artifact_metrics["sourceArtifactMetrics"][
                    "buildingPreprocessing"
                ],
                preprocessing,
            )
            self.assertEqual(
                reloaded.artifact_metrics["buildingPhaseTimings"],
                {"calibrationGeneration": 1.25},
            )
            self.assertEqual(
                reloaded.artifact_metrics["exactReuse"][
                    "calibrationGeneration"
                ]["cacheOutcome"],
                "rebuilt",
            )
            self.assertEqual(
                reloaded.artifact_metrics["exactReuse"]["sourceJobId"],
                parent.job_id,
            )
            self.assertIn(
                "firstProgressMilliseconds",
                reloaded.artifact_metrics["buildingObservability"],
            )
            self.assertIn(
                "cacheWaitMilliseconds",
                reloaded.artifact_metrics["buildingObservability"],
            )
            self.assertIn(
                "building_calibrationGeneration",
                {timing["status"] for timing in reloaded.phase_timings()},
            )
            self.assertEqual(pipeline.full_build_calls, 0)

    def test_exact_validation_rejects_alias_present_only_in_job_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            request = {"mode": "custom_bbox", "bbox": [103.70, 1.20, 104.00, 1.50]}
            parent = service.create_job(request)
            child = service.create_job(request)
            base_keys = reuse_keys(
                child,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            parent.build_cache_key = base_keys.exact
            parent.build_compatibility_key = base_keys.compatibility
            self._make_parent_archive(root, parent, child)
            derivation = {
                "baseExactKey": base_keys.exact,
                "strategy": "subset",
                "parentIdentitySha256": "4" * 64,
                "parentZipSha256": "5" * 64,
            }
            parent.build_cache_key = hashlib.sha256(
                canonical_building_json(derivation)
            ).hexdigest()
            parent.build_cache_aliases = [base_keys.exact]
            parent.build_identity_derivation = derivation
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=VersionRunner(),
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )

            self.assertFalse(pipeline.validate_exact_reuse_candidate(child, parent))

    def test_worker_repackages_only_child_blocks_from_smallest_parent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            parent = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.70, 1.20, 104.00, 1.50]}
            )
            child = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.80, 1.30, 103.90, 1.40]}
            )
            parent_archive = self._make_parent_archive(root, parent, child)
            keys = reuse_keys(
                parent,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            store.update_status(
                parent.job_id,
                JobStatus.READY,
                map_id=parent.map_id,
                pack_path=str(parent_archive),
                pack_bytes=parent_archive.stat().st_size,
                build_cache_key=keys.exact,
                build_compatibility_key=keys.compatibility,
                artifacts=parent.artifacts,
                finished=True,
            )
            pipeline = TrackingSubsetPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=VersionRunner(),
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )

            result = MapWorker(store, pipeline, worker_id="worker-subset").run_next()

            self.assertEqual(result.job.status, JobStatus.READY)
            self.assertEqual(result.job.reuse_strategy, "subset")
            self.assertEqual(result.job.reuse_source_job_id, parent.job_id)
            self.assertEqual(pipeline.subset_build_calls, 1)
            self.assertEqual(pipeline.full_build_calls, 0)

    def test_corrupt_exact_candidate_falls_back_to_full_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            request = {
                "mode": "custom_bbox",
                "bbox": [103.70, 1.20, 104.00, 1.50],
            }
            parent = service.create_job(request)
            child = service.create_job(request)
            keys = reuse_keys(
                parent,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            parent.build_cache_key = keys.exact
            parent.build_compatibility_key = keys.compatibility
            archive = self._make_parent_archive(root, parent, child)
            archive.write_bytes(b"truncated exact artifact")
            parent.artifacts = [
                ArtifactRecord(
                    format="zip-stored-v1",
                    media_type="application/zip",
                    filename=archive.name,
                    object_key=f"test/{archive.name}",
                    bytes=archive.stat().st_size,
                    sha256=sha256_file(archive),
                )
            ]
            store.update_status(
                parent.job_id,
                JobStatus.READY,
                map_id=parent.map_id,
                pack_path=str(archive),
                pack_bytes=archive.stat().st_size,
                build_cache_key=keys.exact,
                build_compatibility_key=keys.compatibility,
                artifacts=parent.artifacts,
                finished=True,
            )
            pipeline = FullBuildFallbackPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=VersionRunner(),
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )

            result = MapWorker(
                store, pipeline, worker_id="worker-exact-corrupt"
            ).run_next()

            self.assertEqual(result.job.status, JobStatus.READY)
            self.assertIsNone(result.job.reuse_strategy)
            self.assertEqual(pipeline.full_build_calls, 1)
            self.assertEqual(
                Path(result.job.pack_path).read_bytes(), b"full-build-fallback"
            )

    def test_reuse_rejects_stream_not_bound_to_zip_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            service = MapJobService(SourceIndex([self.source]), JobStore(root / "jobs"))
            parent = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.70, 1.20, 104.00, 1.50]}
            )
            child = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.80, 1.30, 103.90, 1.40]}
            )
            archive_path = self._make_parent_archive(root, parent, child)
            with zipfile.ZipFile(archive_path) as archive:
                manifest = json.loads(archive.read("manifest.json"))
                preview_bytes = archive.read("preview.png")
            stream = ArtifactRecord(
                format="bike-map-stream-v1",
                media_type="application/vnd.openbikecomputer.map-stream",
                filename=f"{parent.map_id}.bmap",
                object_key=(
                    f"maps/{parent.map_id}/bike-map-stream-v1/test-key/"
                    + "4" * 64
                    + ".bmap"
                ),
                bytes=100,
                sha256="2" * 64,
                manifest_receipt="3" * 64,
                signed_manifest_receipt="4" * 64,
                signature_key_id="test-key",
            )
            parent.artifacts.append(stream)
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=VersionRunner(),
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )

            with self.assertRaisesRegex(
                SubsetReuseUnavailable, "does not match the ZIP manifest"
            ):
                pipeline._validate_reuse_artifact_records(
                    parent, manifest, preview_bytes
                )

            parent.artifacts[-1] = replace(
                stream,
                filename="different-map.bmap",
                object_key=(
                    "maps/different-map/bike-map-stream-v1/test-key/"
                    + "4" * 64
                    + ".bmap"
                ),
            )
            with self.assertRaisesRegex(
                SubsetReuseUnavailable, "stream identity is invalid"
            ):
                pipeline._validate_reuse_artifact_records(
                    parent, manifest, preview_bytes
                )

    def test_exact_reuse_rechecks_unpinned_source_under_identity_lease(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            unpinned = replace(self.source, checksum=None)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([unpinned]), store)
            request = {"mode": "custom_bbox", "bbox": [103.70, 1.20, 104.00, 1.50]}
            parent = service.create_job(request)
            child = service.create_job(request)
            initial_source = SimpleNamespace(path=root / "source-a.pbf", sha256="4" * 64)
            changed_source = SimpleNamespace(path=root / "source-b.pbf", sha256="5" * 64)
            keys = reuse_keys(
                parent,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
                source_snapshot_sha256=initial_source.sha256,
            )
            parent.build_cache_key = keys.exact
            parent.build_compatibility_key = keys.compatibility
            archive = self._make_parent_archive(root, parent, child)
            store.update_status(
                parent.job_id,
                JobStatus.READY,
                map_id=parent.map_id,
                pack_path=str(archive),
                pack_bytes=archive.stat().st_size,
                artifacts=parent.artifacts,
                build_cache_key=keys.exact,
                build_compatibility_key=keys.compatibility,
                finished=True,
            )
            pipeline = FullBuildFallbackPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=VersionRunner(),
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            with patch.object(
                pipeline.source_cache, "ensure", return_value=initial_source
            ), patch.object(
                pipeline.source_cache,
                "verified_lease",
                return_value=nullcontext(changed_source),
            ):
                result = MapWorker(
                    store, pipeline, worker_id="worker-source-toctou"
                ).run_next()

            changed_keys = reuse_keys(
                child,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
                source_snapshot_sha256=changed_source.sha256,
            )
            self.assertEqual(result.job.status, JobStatus.READY)
            self.assertIsNone(result.job.reuse_strategy)
            self.assertEqual(pipeline.full_build_calls, 1)
            self.assertEqual(result.job.build_cache_key, changed_keys.exact)
            self.assertEqual(
                result.job.build_compatibility_key, changed_keys.compatibility
            )

    def test_synchronous_build_reserves_the_leased_unpinned_source_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            unpinned = replace(self.source, checksum=None)
            store = JobStore(root / "jobs")
            job = MapJobService(SourceIndex([unpinned]), store).create_job(
                {"mode": "custom_bbox", "bbox": [103.70, 1.20, 104.00, 1.50]}
            )
            initial_source = SimpleNamespace(path=root / "source-a.pbf", sha256="4" * 64)
            leased_source = SimpleNamespace(path=root / "source-b.pbf", sha256="5" * 64)
            pipeline = FullBuildFallbackPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=VersionRunner(),
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            with patch.object(
                pipeline.source_cache, "ensure", return_value=initial_source
            ), patch.object(
                pipeline.source_cache,
                "verified_lease",
                return_value=nullcontext(leased_source),
            ):
                result = run_job(store, pipeline, job.job_id)

            leased_keys = reuse_keys(
                job,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
                source_snapshot_sha256=leased_source.sha256,
            )
            self.assertEqual(result.status, JobStatus.READY)
            self.assertEqual(result.build_cache_key, leased_keys.exact)
            self.assertEqual(
                result.build_compatibility_key, leased_keys.compatibility
            )

    def test_exact_reuse_key_ignores_resolved_source_preview_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_without_preview = replace(self.source, preview_geometry=None)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([source_without_preview]), store)
            request = {
                "mode": "custom_bbox",
                "bbox": [103.70, 1.20, 104.00, 1.50],
                "displayName": "Stable display name",
            }
            parent = service.create_job(request)
            child = service.create_job(request)
            preview_a = {
                "type": "Polygon",
                "coordinates": [[
                    [103.72, 1.22], [103.88, 1.22], [103.80, 1.42], [103.72, 1.22]
                ]],
            }
            preview_b = {
                "type": "Polygon",
                "coordinates": [[
                    [103.74, 1.24], [103.96, 1.24], [103.90, 1.46], [103.74, 1.24]
                ]],
            }
            parent.source_region = replace(parent.source_region, preview_geometry=preview_a)
            keys = reuse_keys(
                parent,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            parent.build_cache_key = keys.exact
            parent.build_compatibility_key = keys.compatibility
            archive = self._make_parent_archive(root, parent, child)
            store.update_status(
                parent.job_id,
                JobStatus.READY,
                map_id=parent.map_id,
                pack_path=str(archive),
                pack_bytes=archive.stat().st_size,
                artifacts=parent.artifacts,
                build_cache_key=keys.exact,
                build_compatibility_key=keys.compatibility,
                finished=True,
            )
            pipeline = FullBuildFallbackPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=VersionRunner(),
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
                source_preview_geometry_resolver=lambda _source: preview_b,
            )

            result = MapWorker(
                store, pipeline, worker_id="worker-preview-change"
            ).run_next()

            self.assertEqual(result.job.status, JobStatus.READY)
            self.assertEqual(result.job.reuse_strategy, "exact")
            self.assertEqual(pipeline.full_build_calls, 0)

    def test_subset_rejects_a_corrupt_selected_block(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            parent = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.70, 1.20, 104.00, 1.50]}
            )
            child = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.80, 1.30, 103.90, 1.40]}
            )
            archive_path = self._make_parent_archive(root, parent, child)
            corrupt_path = root / "corrupt.zip"
            with zipfile.ZipFile(archive_path, "r") as source_archive:
                selected = next(
                    path for path in source_archive.namelist() if path.endswith(".fmb")
                )
                with zipfile.ZipFile(
                    corrupt_path,
                    "w",
                    compression=zipfile.ZIP_STORED,
                ) as corrupt_archive:
                    for info in source_archive.infolist():
                        data = source_archive.read(info)
                        corrupt_archive.writestr(
                            info,
                            b"corrupt" if info.filename == selected else data,
                        )
            corrupt_path.replace(archive_path)
            parent.artifacts = [
                ArtifactRecord(
                    format="zip-stored-v1",
                    media_type="application/zip",
                    filename=archive_path.name,
                    object_key=f"test/{archive_path.name}",
                    bytes=archive_path.stat().st_size,
                    sha256=sha256_file(archive_path),
                )
            ]
            parent.pack_path = str(archive_path)
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=VersionRunner(),
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )

            with self.assertRaises(SubsetReuseUnavailable):
                pipeline.build_subset(child, parent)

    def test_subset_rejects_semantically_omitted_required_block(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            service = MapJobService(SourceIndex([self.source]), JobStore(root / "jobs"))
            parent = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.70, 1.20, 104.00, 1.50]}
            )
            child = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.80, 1.30, 103.90, 1.40]}
            )
            archive_path = self._make_parent_archive(root, parent, child)
            omitted_path = root / "omitted-block.zip"
            with zipfile.ZipFile(archive_path, "r") as source_archive:
                omitted = next(
                    path for path in source_archive.namelist() if path.endswith(".fmb")
                )
                manifest = json.loads(source_archive.read("manifest.json"))
                manifest["files"] = [
                    entry for entry in manifest["files"] if entry["path"] != omitted
                ]
                with zipfile.ZipFile(
                    omitted_path, "w", compression=zipfile.ZIP_STORED
                ) as output:
                    for info in source_archive.infolist():
                        if info.filename in {"manifest.json", omitted}:
                            continue
                        output.writestr(info, source_archive.read(info))
                    output.writestr(
                        "manifest.json",
                        json.dumps(
                            manifest,
                            sort_keys=True,
                            separators=(",", ":"),
                        ).encode("utf-8"),
                    )
            omitted_path.replace(archive_path)
            parent.artifacts = [
                ArtifactRecord(
                    format="zip-stored-v1",
                    media_type="application/zip",
                    filename=archive_path.name,
                    object_key=f"test/{archive_path.name}",
                    bytes=archive_path.stat().st_size,
                    sha256=sha256_file(archive_path),
                )
            ]
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=VersionRunner(),
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )

            with self.assertRaisesRegex(
                SubsetReuseUnavailable, "every required binary block"
            ):
                pipeline._stage_subset_pack(child, parent, root / "child-pack")

    def test_target_two_subset_copies_the_exact_font_asset(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            service = MapJobService(
                SourceIndex([self.source]),
                JobStore(root / "jobs"),
                label_target2_enabled=True,
            )
            label_target = {
                "target": {
                    "renderer": "esp32-fmb",
                    "rendererFormatVersion": 2,
                    "firmwareVersion": "1.2.3",
                },
                "labels": {
                    "profileVersion": 1,
                    "preferredLanguages": ["zh-Hant", "en"],
                    "internationalFallback": "en",
                },
            }
            parent = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.70, 1.20, 104.00, 1.50],
                    **label_target,
                }
            )
            child = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.80, 1.30, 103.90, 1.40],
                    **label_target,
                }
            )
            self._make_parent_archive(root, parent, child)
            pack_root = root / "child-pack"
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=VersionRunner(),
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )

            pipeline._stage_subset_pack(child, parent, pack_root)

            asset = (
                pack_root
                / "VECTMAP"
                / stable_map_id(child)
                / "assets"
                / "street-labels.fma"
            )
            self.assertEqual(asset.read_bytes(), empty_fma1())

    def test_target_three_subset_reuse_preserves_v4_blocks_font_and_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(
                SourceIndex([self.source]),
                store,
                label_target2_enabled=True,
                building_target3_enabled=True,
            )
            target = self._renderer_request(3)
            parent = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.70, 1.20, 104.00, 1.50],
                    **target,
                }
            )
            child = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.80, 1.30, 103.90, 1.40],
                    **target,
                }
            )
            parent_archive = self._make_parent_archive(root, parent, child)
            keys = reuse_keys(
                parent,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            store.update_status(
                parent.job_id,
                JobStatus.READY,
                map_id=parent.map_id,
                pack_path=str(parent_archive),
                pack_bytes=parent_archive.stat().st_size,
                build_cache_key=keys.exact,
                build_compatibility_key=keys.compatibility,
                artifacts=parent.artifacts,
                finished=True,
            )
            pipeline = TrackingSubsetPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=VersionRunner(),
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )

            result = MapWorker(store, pipeline, worker_id="worker-target3-subset").run_next()

            self.assertEqual(result.job.status, JobStatus.READY)
            self.assertEqual(result.job.reuse_strategy, "subset")
            self.assertEqual(result.job.reuse_source_job_id, parent.job_id)
            self.assertEqual(pipeline.subset_build_calls, 1)
            self.assertEqual(pipeline.full_build_calls, 0)
            with zipfile.ZipFile(result.job.pack_path) as archive:
                manifest = json.loads(archive.read("manifest.json"))
                fmb_paths = [
                    entry["path"]
                    for entry in manifest["files"]
                    if entry["path"].endswith(".fmb")
                ]
                font_paths = [
                    entry["path"]
                    for entry in manifest["files"]
                    if entry["path"].endswith(".fma")
                ]
                self.assertTrue(
                    all(archive.read(path)[:4] == b"FMB\x04" for path in fmb_paths)
                )
                self.assertEqual(archive.read(font_paths[0]), one_label_fma1())
            expected_blocks = required_blocks(child.geometry.bounds)
            self.assertEqual(
                {block_from_pack_path(path) for path in fmb_paths},
                expected_blocks,
            )
            self.assertEqual(len(font_paths), 1)
            self.assertFalse(any(entry["path"].endswith(".fmp") for entry in manifest["files"]))
            self.assertEqual(manifest["target"]["formatVersion"], 3)
            self.assertEqual(manifest["target"]["buildingProfileVersion"], 1)
            self.assertEqual(manifest["buildings"]["recordCount"], len(expected_blocks))
            self.assertEqual(
                manifest["buildings"]["explicitHeightCount"],
                len(expected_blocks),
            )

    def test_selected_polygon_subset_stages_only_semantic_output_blocks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            service = MapJobService(
                SourceIndex([self.source]),
                JobStore(root / "jobs"),
                label_target2_enabled=True,
                building_target3_enabled=True,
            )
            target = self._renderer_request(3)
            parent = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.23, 103.91, 1.39],
                    **target,
                }
            )
            child = service.create_job(
                {
                    "mode": "custom_polygon",
                    "geometry": {
                        "type": "Polygon",
                        "coordinates": [[
                            [103.80, 1.28],
                            [103.86, 1.28],
                            [103.86, 1.34],
                            [103.80, 1.28],
                        ]],
                    },
                    **target,
                }
            )
            self._make_parent_archive(root, parent, child)
            pipeline = MapBuildPipeline(
                PipelinePaths(
                    Path(__file__).resolve().parents[3],
                    root / "work",
                    root / "packs",
                ),
                runner=VersionRunner(),
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
                building_scope_mode="selected",
            )
            calibration = load_building_calibration_window(
                pipeline.paths.osm_extract_root
                / "conf"
                / "building_height_rules.yaml"
            )
            scope_plan = plan_building_scope(
                child,
                calibration_cell_size_meters=calibration.cell_size_meters,
                calibration_halo_cells=calibration.halo_cells,
                calibration_minimum_samples=calibration.minimum_samples,
            )
            envelope_blocks = required_blocks(child.geometry.bounds)
            self.assertLess(len(scope_plan.output_blocks), len(envelope_blocks))
            pack_root = root / "selected-child-pack"

            pipeline._stage_subset_pack(child, parent, pack_root)

            staged_blocks = {
                block_from_pack_path(path.relative_to(pack_root).as_posix())
                for path in pack_root.rglob("*.fmb")
            }
            self.assertEqual(staged_blocks, set(scope_plan.output_blocks))
            self.assertTrue(parent_contains_child_blocks(parent, child))

    def test_corrupt_target_three_subset_falls_back_to_full_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(
                SourceIndex([self.source]),
                store,
                label_target2_enabled=True,
                building_target3_enabled=True,
            )
            target = self._renderer_request(3)
            parent = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.70, 1.20, 104.00, 1.50],
                    **target,
                }
            )
            child = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.80, 1.30, 103.90, 1.40],
                    **target,
                }
            )
            archive_path = self._make_parent_archive(root, parent, child)
            corrupt_path = root / "corrupt-target3.zip"
            with zipfile.ZipFile(archive_path, "r") as source_archive:
                selected = next(
                    path for path in source_archive.namelist() if path.endswith(".fmb")
                )
                with zipfile.ZipFile(
                    corrupt_path,
                    "w",
                    compression=zipfile.ZIP_STORED,
                ) as corrupt_archive:
                    for info in source_archive.infolist():
                        data = source_archive.read(info)
                        corrupt_archive.writestr(
                            info,
                            b"corrupt" if info.filename == selected else data,
                        )
            corrupt_path.replace(archive_path)
            parent.artifacts = [
                ArtifactRecord(
                    format="zip-stored-v1",
                    media_type="application/zip",
                    filename=archive_path.name,
                    object_key=f"test/{archive_path.name}",
                    bytes=archive_path.stat().st_size,
                    sha256=sha256_file(archive_path),
                )
            ]
            keys = reuse_keys(
                parent,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            store.update_status(
                parent.job_id,
                JobStatus.READY,
                map_id=parent.map_id,
                pack_path=str(archive_path),
                pack_bytes=archive_path.stat().st_size,
                build_cache_key=keys.exact,
                build_compatibility_key=keys.compatibility,
                artifacts=parent.artifacts,
                finished=True,
            )
            pipeline = TrackingFullBuildFallbackPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=VersionRunner(),
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )

            result = MapWorker(store, pipeline, worker_id="worker-target3-fallback").run_next()

            self.assertEqual(result.job.status, JobStatus.READY)
            self.assertIsNone(result.job.reuse_strategy)
            self.assertEqual(pipeline.subset_build_calls, 1)
            self.assertEqual(pipeline.full_build_calls, 1)
            self.assertEqual(Path(result.job.pack_path).read_bytes(), b"full-build-fallback")

    def test_target_three_reuse_identity_is_separate_from_target_two(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp) / "jobs")
            service = MapJobService(
                SourceIndex([self.source]),
                store,
                label_target2_enabled=True,
                building_target3_enabled=True,
            )
            target_two = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.70, 1.20, 104.00, 1.50],
                    **self._renderer_request(2),
                }
            )
            target_three = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.80, 1.30, 103.90, 1.40],
                    **self._renderer_request(3),
                }
            )
            target_two_keys = reuse_keys(
                target_two,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            target_three_keys = reuse_keys(
                target_three,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            store.update_status(
                target_two.job_id,
                JobStatus.READY,
                map_id="target-two",
                pack_path=str(Path(tmp) / "target-two.zip"),
                pack_bytes=0,
                build_cache_key=target_two_keys.exact,
                build_compatibility_key=target_two_keys.compatibility,
                finished=True,
            )

            self.assertNotEqual(
                target_two_keys.compatibility,
                target_three_keys.compatibility,
            )
            self.assertEqual(
                store.find_subset_reuse_candidates(
                    target_three,
                    build_compatibility_key=target_three_keys.compatibility,
                ),
                [],
            )

    def test_selected_target_three_identity_binds_rules_scope_and_subset_compatibility(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            service = MapJobService(
                SourceIndex([self.source]),
                JobStore(root / "jobs"),
                label_target2_enabled=True,
                building_target3_enabled=True,
            )
            parent = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.80, 1.28, 103.88, 1.34],
                    **self._renderer_request(3),
                }
            )
            child = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.81, 1.29, 103.84, 1.32],
                    **self._renderer_request(3),
                }
            )
            rules_path = (
                Path(__file__).resolve().parents[3]
                / "tools/OSM_Extract/conf/building_height_rules.yaml"
            )
            calibration = load_building_calibration_window(rules_path)

            def identity(job, path=rules_path, generation_suffix="a"):
                scope = plan_building_scope(
                    job,
                    calibration_cell_size_meters=calibration.cell_size_meters,
                    calibration_halo_cells=calibration.halo_cells,
                    calibration_minimum_samples=calibration.minimum_samples,
                )
                calibration_identity = selected_calibration_identity(
                    source_snapshot_sha256="3" * 64,
                    rules_path=path,
                    scope_plan=scope,
                )
                return selected_building_identity(
                    source_snapshot_sha256="3" * 64,
                    rules_path=path,
                    scope_plan=scope,
                    calibration_generation={
                        "calibrationKey": calibration_identity["calibrationKey"],
                        "manifestSha256": generation_suffix * 64,
                        "entrySetSha256": "b" * 64,
                        "cellCount": 12,
                    },
                )

            parent_identity = identity(parent)
            child_identity = identity(child)
            parent_keys = reuse_keys(
                parent,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
                building_preprocessing_identity=parent_identity,
            )
            child_keys = reuse_keys(
                child,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
                building_preprocessing_identity=child_identity,
            )
            self.assertEqual(parent_keys.compatibility, child_keys.compatibility)
            self.assertNotEqual(parent_keys.exact, child_keys.exact)

            changed_rules = root / "rules.yaml"
            changed_rules.write_bytes(rules_path.read_bytes() + b"\n")
            changed_keys = reuse_keys(
                parent,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
                building_preprocessing_identity=identity(parent, changed_rules),
            )
            self.assertNotEqual(parent_keys.compatibility, changed_keys.compatibility)
            changed_generation_keys = reuse_keys(
                parent,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
                building_preprocessing_identity=identity(
                    parent, generation_suffix="c"
                ),
            )
            self.assertNotEqual(
                parent_keys.compatibility, changed_generation_keys.compatibility
            )
            legacy_keys = reuse_keys(
                parent,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            self.assertNotEqual(parent_keys.compatibility, legacy_keys.compatibility)

            tampered = json.loads(json.dumps(parent_identity))
            tampered["scope"]["geometryBufferMeters"] += 1
            self.assertIsNone(
                reuse_keys(
                    parent,
                    producer_build_sha256=PRODUCER_BUILD,
                    producer_image_digest=PRODUCER_IMAGE,
                    building_preprocessing_identity=tampered,
                )
            )

    def test_selected_subset_manifest_derives_child_scope_from_compatible_parent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            service = MapJobService(
                SourceIndex([self.source]),
                JobStore(root / "jobs"),
                label_target2_enabled=True,
                building_target3_enabled=True,
            )
            parent = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.80, 1.28, 103.88, 1.34],
                    **self._renderer_request(3),
                }
            )
            child = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.81, 1.29, 103.84, 1.32],
                    **self._renderer_request(3),
                }
            )
            repo_root = Path(__file__).resolve().parents[3]
            rules_path = repo_root / "tools/OSM_Extract/conf/building_height_rules.yaml"
            calibration = load_building_calibration_window(rules_path)

            def plan(job):
                return plan_building_scope(
                    job,
                    calibration_cell_size_meters=calibration.cell_size_meters,
                    calibration_halo_cells=calibration.halo_cells,
                    calibration_minimum_samples=calibration.minimum_samples,
                )

            parent_plan = plan(parent)
            child_plan = plan(child)
            calibration_identity = selected_calibration_identity(
                source_snapshot_sha256="3" * 64,
                rules_path=rules_path,
                scope_plan=parent_plan,
            )
            calibration_generation = {
                "calibrationKey": calibration_identity["calibrationKey"],
                "manifestSha256": "a" * 64,
                "entrySetSha256": "b" * 64,
                "cellCount": 12,
            }
            parent_identity = selected_building_identity(
                source_snapshot_sha256="3" * 64,
                rules_path=rules_path,
                scope_plan=parent_plan,
                calibration_generation=calibration_generation,
            )
            child_identity = selected_building_identity(
                source_snapshot_sha256="3" * 64,
                rules_path=rules_path,
                scope_plan=child_plan,
                calibration_generation=calibration_generation,
            )
            parent_keys = reuse_keys(
                parent,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
                building_preprocessing_identity=parent_identity,
            )
            child_keys = reuse_keys(
                child,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
                building_preprocessing_identity=child_identity,
            )
            parent.map_id = "parent-map"
            parent.build_cache_key = parent_keys.exact
            parent.build_compatibility_key = parent_keys.compatibility
            child.build_cache_key = child_keys.exact
            child.build_compatibility_key = child_keys.compatibility
            parent.artifacts = [
                ArtifactRecord(
                    format="zip-stored-v1",
                    media_type="application/zip",
                    filename="parent.zip",
                    object_key="test/parent.zip",
                    bytes=1,
                    sha256="d" * 64,
                )
            ]
            calibration_identity = parent_identity["calibration"]
            parent_summary = {
                "schemaVersion": 1,
                "identitySha256": parent_identity["identitySha256"],
                "sourceSnapshotSha256": "3" * 64,
                "scope": parent_plan.summary(),
                "sourceIndex": {
                    "indexKey": "4" * 64,
                    "sourceSnapshotSha256": "3" * 64,
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
                    "calibrationKey": calibration_identity["calibrationKey"],
                    "sourceSnapshotSha256": "3" * 64,
                    "rulesSha256": calibration_identity["rulesSha256"],
                    "manifestSha256": "a" * 64,
                    "entrySetSha256": "b" * 64,
                    "cellCount": 12,
                    "cellsRequested": 9,
                    "cellsHits": 9,
                    "cellsMisses": 0,
                    "cellsRebuilt": 0,
                },
            }
            parent_summary = MapBuildPipeline._building_preprocessing_summary(
                {
                    "mode": "selected",
                    "scope": parent_plan.summary(),
                    "identity": parent_identity,
                    "sourceIndex": parent_summary["sourceIndex"],
                    "closure": parent_summary["closure"],
                    "calibration": parent_summary["calibration"],
                }
            )
            pipeline = MapBuildPipeline(
                PipelinePaths(repo_root, root / "work", root / "packs"),
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
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
                "_selected_dependency_metrics",
                return_value={
                    "sourceIndex": parent_summary["sourceIndex"],
                    "closure": parent_summary["closure"],
                    "calibration": parent_summary["calibration"],
                },
            ):
                metrics = pipeline._subset_build_metrics(
                    child,
                    parent,
                    {
                        "buildingPreprocessing": parent_summary,
                        "buildIdentity": {
                            "exactKey": parent_keys.exact,
                            "compatibilityKey": parent_keys.compatibility,
                        },
                    },
                )
                corrupt_parent_summary = json.loads(json.dumps(parent_summary))
                corrupt_parent_summary["calibration"]["manifestSha256"] = "invalid"
                with self.assertRaises(SubsetReuseUnavailable):
                    pipeline._subset_build_metrics(
                        child,
                        parent,
                        {
                            "buildingPreprocessing": corrupt_parent_summary,
                            "buildIdentity": {
                                "exactKey": parent_keys.exact,
                                "compatibilityKey": parent_keys.compatibility,
                            },
                        },
                    )
                parent_derivation = {
                    "baseExactKey": parent_keys.exact,
                    "strategy": "subset",
                    "parentIdentitySha256": "7" * 64,
                    "parentZipSha256": "8" * 64,
                }
                parent.build_cache_key = hashlib.sha256(
                    canonical_building_json(parent_derivation)
                ).hexdigest()
                parent.build_cache_aliases = [parent_keys.exact]
                parent.build_identity_derivation = parent_derivation
                derived_metrics = pipeline._subset_build_metrics(
                    child,
                    parent,
                    {
                        "buildingPreprocessing": parent_summary,
                        "buildIdentity": build_identity_manifest(
                            parent, parent_summary
                        ),
                    },
                )
            child_summary = MapBuildPipeline._building_preprocessing_summary(
                metrics["buildingPreprocessing"]
            )
            dependency_duration = child.building_preprocessing_runtime[
                "dependencyValidation"
            ]["durationSeconds"]
            child.building_preprocessing_runtime["calibrationGeneration"] = {
                "cacheOutcome": "hit",
                "durationSeconds": 0.75,
            }
            child._building_observability = {
                "firstProgressMilliseconds": 12,
                "cacheWaitMilliseconds": 34,
            }
            pipeline._add_current_building_attempt_metrics(metrics, child)
            self.assertEqual(
                child_summary["scope"]["scopePlanSha256"], child_plan.sha256
            )
            self.assertEqual(
                child_summary["identitySha256"], child_identity["identitySha256"]
            )
            self.assertEqual(
                metrics["buildingReuse"]["parentMapId"], "parent-map"
            )
            self.assertNotEqual(
                metrics["subsetBuildCacheKey"], child_keys.exact
            )
            self.assertEqual(
                derived_metrics["subsetBuildCacheAlias"], child_keys.exact
            )
            self.assertEqual(
                metrics["buildingPhaseTimings"]["calibrationGeneration"],
                0.75,
            )
            self.assertEqual(
                metrics["buildingPhaseTimings"]["dependencyValidation"],
                dependency_duration,
            )
            self.assertEqual(
                metrics["buildingPreprocessing"][
                    "dependencyValidationExecution"
                ]["durationSeconds"],
                dependency_duration,
            )
            self.assertEqual(
                metrics["buildingObservability"],
                {
                    "firstProgressMilliseconds": 12,
                    "cacheWaitMilliseconds": 34,
                },
            )
            self.assertEqual(
                metrics["buildingPreprocessing"][
                    "calibrationGenerationExecution"
                ]["cacheOutcome"],
                "hit",
            )

    def test_corrupt_subset_candidate_falls_back_to_full_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([self.source]), store)
            parent = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.70, 1.20, 104.00, 1.50]}
            )
            child = service.create_job(
                {"mode": "custom_bbox", "bbox": [103.80, 1.30, 103.90, 1.40]}
            )
            archive_path = self._make_parent_archive(root, parent, child)
            archive_path.write_bytes(b"not a zip")
            keys = reuse_keys(
                parent,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            store.update_status(
                parent.job_id,
                JobStatus.READY,
                map_id=parent.map_id,
                pack_path=str(archive_path),
                pack_bytes=archive_path.stat().st_size,
                build_cache_key=keys.exact,
                build_compatibility_key=keys.compatibility,
                artifacts=parent.artifacts,
                finished=True,
            )
            pipeline = FullBuildFallbackPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=VersionRunner(),
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )

            result = MapWorker(store, pipeline, worker_id="worker-fallback").run_next()

            self.assertEqual(result.job.status, JobStatus.READY)
            self.assertIsNone(result.job.reuse_strategy)
            self.assertEqual(pipeline.full_build_calls, 1)
            self.assertEqual(Path(result.job.pack_path).read_bytes(), b"full-build-fallback")

    def _make_parent_archive(self, root: Path, parent, child) -> Path:
        parent.map_id = stable_map_id(parent)
        pack_root = root / f"pack-{parent.job_id}"
        child_blocks = required_blocks(child.geometry.bounds)
        format_version = parent.request.get("target", {}).get(
            "rendererFormatVersion", 1
        )
        extensions = (
            ("fmb",)
            if format_version in {2, 3}
            else ("fmb", "fmp")
        )
        for block in child_blocks:
            for extension in extensions:
                path = pack_root / child_pack_path(parent.map_id, block, extension)
                path.parent.mkdir(parents=True, exist_ok=True)
                if format_version == 3:
                    data = one_building_fmb4()
                elif format_version == 2:
                    data = empty_fmb3()
                elif extension == "fmb":
                    data = b"FMB\x02"
                else:
                    data = f"{block.x}:{block.y}:{extension}".encode()
                path.write_bytes(data)
        if format_version in {2, 3}:
            asset = (
                pack_root
                / "VECTMAP"
                / parent.map_id
                / "assets"
                / "street-labels.fma"
            )
            asset.parent.mkdir(parents=True, exist_ok=True)
            asset.write_bytes(
                one_label_fma1() if format_version == 3 else empty_fma1()
            )
        manifest = build_manifest(
            parent,
            pack_root,
            PipelineMetadata(osmium_version="osmium test"),
        )
        archive_path = root / f"{parent.job_id}.zip"
        write_pack_archive(pack_root, manifest, archive_path)
        parent.pack_path = str(archive_path)
        parent.artifacts = [
            ArtifactRecord(
                format="zip-stored-v1",
                media_type="application/zip",
                filename=archive_path.name,
                object_key=f"test/{archive_path.name}",
                bytes=archive_path.stat().st_size,
                sha256=sha256_file(archive_path),
            )
        ]
        return archive_path


if __name__ == "__main__":
    unittest.main()
