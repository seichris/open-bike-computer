from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric import ec

from map_platform.artifacts import (
    BIKE_MAP_STREAM_FORMAT,
    ZIP_STORED_FORMAT,
    FileSystemArtifactStore,
)
from map_platform.jobs import JobStore, MapJobService
from map_platform.map_signing import P256MapArtifactSigner
from map_platform.models import Bounds, SourceRegion
from map_platform.pipeline import MapBuildPipeline, PipelinePaths
from map_platform.preview import render_boundary_preview
from map_platform.reuse import required_blocks
from map_platform.sources import SourceIndex
from map_platform.sources import SourceResolutionError


class FixtureMapBuildPipeline(MapBuildPipeline):
    def _source_pbf_path(self, job):
        return self.paths.work_root / "source.osm.pbf"

    def _extract_pbf(self, job, source_pbf, clipped_pbf, *, bounds=None):
        del job, source_pbf, bounds
        clipped_pbf.parent.mkdir(parents=True, exist_ok=True)
        clipped_pbf.write_bytes(b"pbf")

    def _convert_to_geojson(self, job, clipped_pbf, geojson_prefix, *, bounds=None):
        del job, clipped_pbf, geojson_prefix, bounds
        pass

    def _extract_features(
        self,
        job,
        geojson_prefix,
        raw_output_dir,
        *,
        bounds=None,
        on_progress=None,
    ):
        del geojson_prefix, bounds
        blocks = sorted(required_blocks(job.geometry.bounds))
        for block in blocks:
            directory = raw_output_dir / block.folder_name
            directory.mkdir(parents=True, exist_ok=True)
            (directory / f"{block.filename_stem}.fmb").write_bytes(
                b"FMB\x02" + b"x" * 11
            )
            (directory / f"{block.filename_stem}.fmp").write_bytes(
                b"redundant-text-fallback"
            )
        if on_progress:
            on_progress(len(blocks), len(blocks))


class PipelineArtifactTests(unittest.TestCase):
    def test_preview_resolution_fallback_is_frozen_at_key_reservation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = SourceRegion(
                id="sg",
                provider="test",
                name="Singapore",
                url="https://example.invalid/sg.osm.pbf",
                bounds=Bounds(103.0, 1.0, 104.5, 1.8),
                checksum="3" * 64,
            )
            job = MapJobService(
                SourceIndex([source]), JobStore(root / "jobs")
            ).create_job(
                {"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]}
            )
            calls = []

            def resolver(source_region):
                calls.append(source_region.id)
                if len(calls) == 1:
                    raise SourceResolutionError("transient catalog failure")
                return {
                    "type": "Polygon",
                    "coordinates": [[[103, 1], [104, 1], [103, 2], [103, 1]]],
                }

            pipeline = FixtureMapBuildPipeline(
                PipelinePaths(
                    repo_root=Path(__file__).resolve().parents[3],
                    work_root=root / "work",
                    pack_root=root / "packs",
                ),
                producer_build_sha256="1" * 64,
                producer_image_digest="sha256:" + "2" * 64,
                source_preview_geometry_resolver=resolver,
            )
            keys = pipeline.reuse_keys(job)
            job.build_cache_key = keys.exact
            job.build_compatibility_key = keys.compatibility

            result = pipeline.build(job)

            self.assertEqual(calls, ["sg"])
            expected_sha256 = hashlib.sha256(
                render_boundary_preview(None, job.geometry.bounds)
            ).hexdigest()
            with zipfile.ZipFile(result.legacy_archive_path) as archive:
                manifest = json.loads(archive.read("manifest.json"))
            self.assertEqual(manifest["preview"]["sha256"], expected_sha256)

    def test_pipeline_publishes_stream_and_zip_with_stable_stream_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = SourceRegion(
                id="sg",
                provider="test",
                name="Singapore",
                url="https://example.invalid/sg.osm.pbf",
                bounds=Bounds(103.0, 1.0, 104.5, 1.8),
            )
            store = JobStore(root / "jobs")
            job = MapJobService(SourceIndex([source]), store).create_job(
                {
                    "mode": "custom_bbox",
                    "displayName": "Pipeline map",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
            )
            job.worker_id = "worker-test"
            artifact_store = FileSystemArtifactStore(root / "artifacts")
            preview_geometry = {
                "type": "Polygon",
                "coordinates": [[[103, 1], [104.5, 1], [103.75, 1.8], [103, 1]]],
            }
            preview_resolution_calls = []

            def resolve_preview_geometry(source_region):
                preview_resolution_calls.append(source_region.id)
                return preview_geometry

            signer = P256MapArtifactSigner(
                "map-pipeline-test",
                ec.derive_private_key(5, ec.SECP256R1()),
            )
            pipeline = FixtureMapBuildPipeline(
                PipelinePaths(
                    repo_root=Path(__file__).resolve().parents[3],
                    work_root=root / "work",
                    pack_root=root / "packs",
                ),
                artifact_store=artifact_store,
                map_signer=signer,
                producer_build_sha256="1" * 64,
                producer_image_digest="sha256:" + "2" * 64,
                source_preview_geometry_resolver=resolve_preview_geometry,
            )

            pending_keys = []
            first = pipeline.build(job, on_artifact_pending=pending_keys.append)
            second = pipeline.build(job)
            self.assertEqual(job.source_region.preview_geometry, preview_geometry)
            self.assertEqual(preview_resolution_calls, ["sg"])
            first_stream = next(
                artifact for artifact in first.artifacts if artifact.format == BIKE_MAP_STREAM_FORMAT
            )
            second_stream = next(
                artifact for artifact in second.artifacts if artifact.format == BIKE_MAP_STREAM_FORMAT
            )
            first_zip = next(
                artifact for artifact in first.artifacts if artifact.format == ZIP_STORED_FORMAT
            )
            second_zip = next(
                artifact for artifact in second.artifacts if artifact.format == ZIP_STORED_FORMAT
            )

            self.assertEqual(
                [artifact.format for artifact in first.artifacts],
                [BIKE_MAP_STREAM_FORMAT, ZIP_STORED_FORMAT],
            )
            self.assertEqual(first_stream.sha256, second_stream.sha256)
            self.assertEqual(first_stream.object_key, second_stream.object_key)
            self.assertEqual(first_zip.sha256, second_zip.sha256)
            self.assertEqual(first_zip.object_key, second_zip.object_key)
            self.assertIsNotNone(artifact_store.local_path(first_stream.object_key))
            self.assertEqual(first_stream.signature_key_id, "map-pipeline-test")
            self.assertEqual(
                first_stream.signature_key_sha256,
                signer.public_key_sha256,
            )
            self.assertEqual(first_stream.producer_build_sha256, "1" * 64)
            self.assertEqual(first_stream.producer_image_digest, "sha256:" + "2" * 64)
            job.map_id = first.map_id
            job.pack_path = str(first.legacy_archive_path)
            job.pack_bytes = first.legacy_archive_path.stat().st_size
            job.artifacts = first.artifacts
            child = MapJobService(SourceIndex([source]), store).create_job(
                {
                    "mode": "custom_bbox",
                    "displayName": "Pipeline map",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
            )
            child.source_region = job.source_region
            self.assertTrue(pipeline.validate_exact_reuse_candidate(child, job))
            block_count = len(required_blocks(job.geometry.bounds))
            self.assertEqual(first.artifact_metrics["streamFileCount"], block_count)
            self.assertEqual(
                first.artifact_metrics["streamPayloadBytes"], 15 * block_count
            )
            self.assertEqual(set(pending_keys), {artifact.object_key for artifact in first.artifacts})
            zip_path = artifact_store.local_path(first_zip.object_key)
            self.assertIsNotNone(zip_path)
            with zipfile.ZipFile(zip_path) as archive:
                first_block = min(required_blocks(job.geometry.bounds))
                self.assertIn(
                    f"VECTMAP/{job.map_id}/{first_block.folder_name}/"
                    f"{first_block.filename_stem}.fmp",
                    archive.namelist(),
                )


if __name__ == "__main__":
    unittest.main()
