import base64
import hashlib
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from map_platform.geometry import normalize_geometry
from map_platform.manifest import PipelineMetadata, build_identity_manifest, build_manifest, stable_map_id, validate_pack_path, write_pack_archive
from map_platform.map_stream import canonical_manifest_bytes
from map_platform.models import Bounds, GeometryMode, JobStatus, MapJob, NormalizedGeometry, SourceRegion
from map_platform.preview import render_boundary_preview


def fake_job() -> MapJob:
    return MapJob(
        job_id="job123",
        status=JobStatus.QUEUED,
        request={"displayName": "Singapore central", "target": {"firmwareVersion": "1.2.3"}},
        geometry=NormalizedGeometry(
            mode=GeometryMode.CUSTOM_BBOX,
            bounds=Bounds(103.75, 1.24, 103.93, 1.37),
            area_km2=250.0,
            vertex_count=4,
        ),
        source_region=SourceRegion(
            id="sg",
            provider="test",
            name="Singapore",
            url="https://example.invalid/sg.osm.pbf",
            bounds=Bounds(103.0, 1.0, 104.5, 1.8),
        ),
    )


class ManifestTests(unittest.TestCase):
    def test_derived_identity_must_hash_to_its_primary_key(self):
        job = fake_job()
        derivation = {
            "baseExactKey": "1" * 64,
            "strategy": "subset",
            "parentIdentitySha256": "2" * 64,
            "parentZipSha256": "3" * 64,
        }
        job.build_cache_aliases = [derivation["baseExactKey"]]
        job.build_identity_derivation = derivation
        job.build_cache_key = "4" * 64
        job.build_compatibility_key = "5" * 64

        with self.assertRaisesRegex(ValueError, "derived map build identity"):
            build_identity_manifest(job)

        job.build_cache_key = hashlib.sha256(
            json.dumps(
                derivation,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
                allow_nan=False,
            ).encode("utf-8")
        ).hexdigest()
        identity = build_identity_manifest(job)
        self.assertEqual(identity["aliases"], [derivation["baseExactKey"]])

    def test_retry_identity_must_match_signed_attempt_scope(self):
        job = fake_job()
        attempt_scope = {
            "scopePlanSha256": "1" * 64,
            "sourceAreaM2": 100,
            "sourceToOutputAreaBasisPoints": 12_000,
            "geometryBufferMeters": 512,
            "sourceBoundsE7": [1, 2, 3, 4],
            "closurePlanSha256": "2" * 64,
        }
        derivation = {
            "baseExactKey": "3" * 64,
            "strategy": "bounded_relation_retry",
            "attemptScope": attempt_scope,
        }
        job.build_cache_aliases = [derivation["baseExactKey"]]
        job.build_identity_derivation = derivation
        job.build_cache_key = hashlib.sha256(
            json.dumps(
                derivation,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
                allow_nan=False,
            ).encode("utf-8")
        ).hexdigest()
        job.build_compatibility_key = "4" * 64

        with self.assertRaisesRegex(ValueError, "does not match preprocessing"):
            build_identity_manifest(
                job,
                {"attemptScope": {**attempt_scope, "geometryBufferMeters": 2048}},
            )

    def test_rejects_path_traversal(self):
        with self.assertRaises(ValueError):
            validate_pack_path("../VECTMAP/map/+0000+0000/1_1.fmb")

    def test_builds_manifest_and_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = fake_job()
            map_id = stable_map_id(job)
            job.map_id = map_id
            folder = root / "VECTMAP" / map_id / "+0032+0008"
            folder.mkdir(parents=True)
            (folder / "123_456.fmb").write_bytes(b"FMB\x02")
            (folder / "123_456.fmp").write_text("map-preview")
            test_image_folder = root / "VECTMAP" / map_id / "test_imgs"
            test_image_folder.mkdir()
            (test_image_folder / "block_232_63-10_10.png").write_bytes(b"not-for-device")

            manifest = build_manifest(job, root, PipelineMetadata(osmium_version="osmium 1.0"))
            archive = write_pack_archive(root, manifest, root / "out.zip")

            self.assertEqual(manifest["mapId"], map_id)
            self.assertEqual(len(manifest["files"]), 2)
            self.assertEqual(manifest["preview"]["type"], "boundary-png")
            self.assertEqual(manifest["preview"]["path"], "preview.png")
            self.assertTrue(
                base64.b64decode(manifest["preview"]["dataBase64"]).startswith(
                    b"\x89PNG\r\n\x1a\n"
                )
            )
            stream_manifest = json.loads(canonical_manifest_bytes(manifest))
            self.assertEqual(
                stream_manifest["preview"]["dataBase64"],
                manifest["preview"]["dataBase64"],
            )
            self.assertNotIn(
                f"VECTMAP/{map_id}/test_imgs/block_232_63-10_10.png",
                [file["path"] for file in manifest["files"]],
            )
            self.assertTrue(archive.exists())
            self.assertGreater(archive.stat().st_size, 0)
            with zipfile.ZipFile(archive) as zip_archive:
                compress_types = {info.filename: info.compress_type for info in zip_archive.infolist()}
                archived_manifest = json.loads(zip_archive.read("manifest.json"))
            self.assertEqual(compress_types["manifest.json"], zipfile.ZIP_STORED)
            self.assertEqual(compress_types["preview.png"], zipfile.ZIP_STORED)
            self.assertNotIn("dataBase64", archived_manifest["preview"])
            self.assertNotIn(f"VECTMAP/{map_id}/test_imgs/block_232_63-10_10.png", compress_types)
            self.assertEqual(
                compress_types[f"VECTMAP/{map_id}/+0032+0008/123_456.fmb"],
                zipfile.ZIP_STORED,
            )

    def test_source_name_is_the_default_pack_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = fake_job()
            job.request.pop("displayName")
            map_id = stable_map_id(job)
            job.map_id = map_id
            folder = root / "VECTMAP" / map_id / "+0032+0008"
            folder.mkdir(parents=True)
            (folder / "123_456.fmb").write_bytes(b"FMB\x02")

            manifest = build_manifest(job, root, PipelineMetadata())

            self.assertTrue(map_id.startswith("singapore-"))
            self.assertNotIn("custom-map", map_id)
            self.assertEqual(manifest["displayName"], "Singapore")
            self.assertEqual(manifest["source"]["name"], "Singapore")

    def test_explicit_pack_name_overrides_source_name(self):
        job = fake_job()
        job.request["displayName"] = "  Marina Bay rides  "

        self.assertEqual(job.artifact_display_name, "Marina Bay rides")
        self.assertTrue(stable_map_id(job).startswith("marina-bay-rides-"))

    def test_archive_remains_compatible_without_optional_preview(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = fake_job()
            map_id = stable_map_id(job)
            job.map_id = map_id
            folder = root / "VECTMAP" / map_id / "+0032+0008"
            folder.mkdir(parents=True)
            (folder / "123_456.fmb").write_bytes(b"FMB\x02")

            manifest = build_manifest(job, root, PipelineMetadata())
            manifest.pop("preview")
            archive = write_pack_archive(root, manifest, root / "legacy.zip")

            with zipfile.ZipFile(archive) as zip_archive:
                self.assertNotIn("preview.png", zip_archive.namelist())

    def test_preview_uses_requested_geometry_and_bounds_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = fake_job()
            map_id = stable_map_id(job)
            job.map_id = map_id
            folder = root / "VECTMAP" / map_id / "+0032+0008"
            folder.mkdir(parents=True)
            (folder / "123_456.fmb").write_bytes(b"FMB\x02")
            requested_geometry = {
                "type": "Polygon",
                "coordinates": [[
                    [103.75, 1.24],
                    [103.93, 1.24],
                    [103.84, 1.37],
                    [103.75, 1.24],
                ]],
            }
            job.geometry = NormalizedGeometry(
                mode=GeometryMode.CUSTOM_POLYGON,
                bounds=job.geometry.bounds,
                area_km2=job.geometry.area_km2,
                vertex_count=3,
                geometry=requested_geometry,
            )

            requested_manifest = build_manifest(job, root, PipelineMetadata())
            requested_data = base64.b64decode(requested_manifest["preview"]["dataBase64"])
            self.assertEqual(
                requested_data,
                render_boundary_preview(requested_geometry, job.geometry.bounds),
            )
            self.assertNotEqual(
                requested_data,
                render_boundary_preview(None, job.geometry.bounds),
            )

            source_geometry = {
                "type": "Polygon",
                "coordinates": [[
                    [103.0, 1.0],
                    [104.5, 1.0],
                    [103.75, 1.8],
                    [103.0, 1.0],
                ]],
            }
            job.source_region = SourceRegion(
                id=job.source_region.id,
                provider=job.source_region.provider,
                name=job.source_region.name,
                url=job.source_region.url,
                bounds=job.source_region.bounds,
                preview_geometry=source_geometry,
            )
            source_manifest = build_manifest(job, root, PipelineMetadata())
            source_data = base64.b64decode(source_manifest["preview"]["dataBase64"])
            self.assertEqual(
                source_data,
                render_boundary_preview(requested_geometry, job.geometry.bounds),
            )
            self.assertNotEqual(
                source_data,
                render_boundary_preview(source_geometry, job.geometry.bounds),
            )

            bbox_job = fake_job()
            bbox_job.map_id = stable_map_id(bbox_job)
            bbox_job.source_region = SourceRegion(
                id=bbox_job.source_region.id,
                provider=bbox_job.source_region.provider,
                name=bbox_job.source_region.name,
                url=bbox_job.source_region.url,
                bounds=bbox_job.source_region.bounds,
                preview_geometry=source_geometry,
            )
            bbox_manifest = build_manifest(bbox_job, root, PipelineMetadata())
            bbox_data = base64.b64decode(bbox_manifest["preview"]["dataBase64"])
            self.assertEqual(
                bbox_data,
                render_boundary_preview(None, bbox_job.geometry.bounds),
            )

    def test_map_id_includes_custom_polygon_geometry(self):
        first = fake_job()
        first.geometry = normalize_geometry(
            {
                "mode": "custom_polygon",
                "geometry": {
                    "type": "Polygon",
                    "coordinates": [
                        [
                            [103.0, 1.0],
                            [104.0, 1.0],
                            [104.0, 2.0],
                            [103.0, 2.0],
                            [103.0, 1.0],
                        ]
                    ],
                },
            }
        )

        second = fake_job()
        second.geometry = normalize_geometry(
            {
                "mode": "custom_polygon",
                "geometry": {
                    "type": "Polygon",
                    "coordinates": [
                        [
                            [103.0, 1.0],
                            [104.0, 1.0],
                            [103.5, 1.5],
                            [104.0, 2.0],
                            [103.0, 2.0],
                            [103.0, 1.0],
                        ]
                    ],
                },
            }
        )

        self.assertEqual(first.geometry.bounds, second.geometry.bounds)
        self.assertNotEqual(stable_map_id(first), stable_map_id(second))

    def test_stable_map_id_truncates_long_name_but_preserves_digest(self):
        short = fake_job()
        short.request["displayName"] = "a" * 53
        long = fake_job()
        long.request["displayName"] = "a" * 500

        short_id = stable_map_id(short)
        long_id = stable_map_id(long)
        self.assertEqual(len(short_id.encode("ascii")), 64)
        self.assertEqual(len(long_id.encode("ascii")), 64)
        self.assertEqual(long_id, short_id)
        canonical_manifest_bytes(
            {
                "schemaVersion": 1,
                "mapId": long_id,
                "files": [
                    {
                        "path": f"VECTMAP/{long_id}/+0000+0000/1.fmb",
                        "bytes": 1,
                        "sha256": "0" * 64,
                    }
                ],
            }
        )


if __name__ == "__main__":
    unittest.main()
