import json
import tempfile
import unittest
import zipfile
from dataclasses import replace
from pathlib import Path

from map_platform.artifacts import ArtifactRecord, sha256_file
from map_platform.jobs import JobStore, MapJobService
from map_platform.manifest import PipelineMetadata, build_manifest, stable_map_id, write_pack_archive
from map_platform.models import Bounds, JobStatus, SourceRegion
from map_platform.pipeline import MapBuildPipeline, MapBuildResult, PipelinePaths
from map_platform.reuse import (
    SubsetReuseUnavailable,
    aligned_processing_bounds,
    block_from_pack_path,
    child_pack_path,
    parent_contains_child_blocks,
    required_blocks,
    reuse_keys,
)
from map_platform.sources import SourceIndex
from map_platform.worker import MapWorker


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
            pack = root / "ready.zip"
            pack.write_bytes(b"ready-pack")
            store.update_status(
                parent.job_id,
                JobStatus.READY,
                map_id="parent-map",
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
            with zipfile.ZipFile(result.job.pack_path) as archive:
                manifest = json.loads(archive.read("manifest.json"))
                copied_blocks = {
                    block_from_pack_path(entry["path"])
                    for entry in manifest["files"]
                }
            self.assertEqual(copied_blocks, required_blocks(child.geometry.bounds))

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
        parent.map_id = "parent-map"
        pack_root = root / f"pack-{parent.job_id}"
        child_blocks = required_blocks(child.geometry.bounds)
        for block in child_blocks:
            for extension in ("fmb", "fmp"):
                path = pack_root / child_pack_path(parent.map_id, block, extension)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(f"{block.x}:{block.y}:{extension}".encode())
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
