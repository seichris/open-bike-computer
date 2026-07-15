from __future__ import annotations

import tempfile
import unittest
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
from map_platform.sources import SourceIndex


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
        del job, geojson_prefix, bounds
        directory = raw_output_dir / "+0000+0000"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "1.fmb").write_bytes(b"first-map-block")
        (directory / "2.fmp").write_bytes(b"second-map-block")
        if on_progress:
            on_progress(2, 2)


class PipelineArtifactTests(unittest.TestCase):
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
                    repo_root=Path(__file__).resolve().parents[2],
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
            self.assertEqual(first.artifact_metrics["streamFileCount"], 2)
            self.assertEqual(first.artifact_metrics["streamPayloadBytes"], 31)
            self.assertEqual(set(pending_keys), {artifact.object_key for artifact in first.artifacts})


if __name__ == "__main__":
    unittest.main()
