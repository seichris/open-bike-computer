import hashlib
import importlib.util
import json
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from cryptography.hazmat.primitives.asymmetric import ec
from shapely.geometry import box, mapping

from map_platform.artifacts import (
    ArtifactRecord, FileSystemArtifactStore, ZIP_MEDIA_TYPE, ZIP_STORED_FORMAT, zip_object_key,
)
from map_platform.building_scope import BuildingScopeError
from map_platform.topography_artifacts import encode_contour_section
from map_platform.topography_companion import validate_companion, write_companion
from map_platform.topography_geometry import compile_contours
from map_platform.topography_pack import assemble_topographic_pack
from map_platform.map_artifact_validation import validate_fmb5
from map_platform.map_signing import P256MapArtifactSigner
from map_platform.map_stream import write_map_stream_artifact
from map_platform.manifest import PipelineMetadata, build_manifest, write_pack_archive
from map_platform.models import Bounds, GeometryMode, JobStatus, MapJob, NormalizedGeometry, SourceRegion
from map_platform.pipeline import MapBuildPipeline, PipelinePaths, validate_final_assembly_artifact
from tests.map_label_fixtures import one_building_fmb4, one_label_fma1


@unittest.skipUnless(importlib.util.find_spec("rasterio"), "topography native dependencies required")
class TopographyGeometryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.sample = {
            "kind": "bicino-contour-evidence-v1", "workingCrs": "EPSG:3857",
            "verticalDatum": "EPSG:3855", "minorIntervalM": 20, "indexIntervalM": 100,
            "boundsE7": [-1000000, -1000000, 1000000, 1000000], "noDataMillionths": 0,
            "qualityMode": "standard-20m-v1", "surfaceModel": "dsm",
            "horizontalCrs": "EPSG:4326", "sourcePixels": {"fixture": 1},
            "gridSize": [2, 2], "sources": [], "inputs": [], "sourcePolicySha256": "a" * 64,
            "contours": [{"elevationM": 100, "index": True, "pointsMm": [[-1000000, 2000000], [6000000, 2000000]]}],
        }
        self.selection = mapping(box(-0.09, -0.09, 0.09, 0.09))

    def test_shared_boundary_endpoints_and_bounded_segments(self):
        compiled = compile_contours(self.sample, self.selection)
        self.assertEqual(set(compiled.sections), {(-1, 0), (0, 0), (1, 0)})
        left = compiled.sections[0, 0].contours[0]
        right = compiled.sections[1, 0].contours[0]
        self.assertIn((4096, 2000), left.points)
        self.assertIn((0, 2000), right.points)
        for section in compiled.sections.values():
            encode_contour_section(section)
        self.assertEqual(compiled, compile_contours(self.sample, self.selection))

    def test_coincident_boundary_line_has_one_owner(self):
        self.sample["contours"][0]["pointsMm"] = [[4096000, 1000000], [4096000, 3000000]]
        compiled = compile_contours(self.sample, self.selection)
        self.assertEqual(set(compiled.sections), {(1, 0)})
        self.assertTrue(all(x == 0 for x, _ in compiled.sections[1, 0].contours[0].points))

    def test_polygon_hole_clips_without_bridge(self):
        selected = box(-0.09, -0.09, 0.09, 0.09).difference(box(0.01, 0.01, 0.03, 0.03))
        compiled = compile_contours(self.sample, mapping(selected))
        for (bx, _), section in compiled.sections.items():
            for record in section.contours:
                xs = [bx * 4096 + x for x, _ in record.points]
                self.assertFalse(min(xs) < 1113 and max(xs) > 3340)
                self.assertFalse(any(1114 < x < 3339 for x in xs))

    def test_axis_aligned_route_corridor_and_insufficient_mosaic(self):
        route = {"type": "LineString", "coordinates": [[0.02, -0.02], [0.02, 0.04]]}
        compiled = compile_contours(self.sample, route, corridor_width_m=200)
        self.assertGreater(compiled.record_count, 0)
        for (bx, _), section in compiled.sections.items():
            for record in section.contours:
                self.assertTrue(all(2126 <= bx * 4096 + x <= 2327 for x, _ in record.points))
        with self.assertRaises(ValueError):
            compile_contours(self.sample, route, corridor_width_m=50000)

    def test_cancellation_does_not_return_partial_content(self):
        def cancelled():
            raise InterruptedError("cancelled")
        with self.assertRaises(InterruptedError):
            compile_contours(self.sample, self.selection, cancel=cancelled)

    def test_dense_intermediate_above_previous_point_limit_is_accepted(self):
        # The line is inside the sampled bounds but outside this selection.
        # It exercises the input budget without creating a huge device block.
        self.sample["contours"][0]["pointsMm"] = [
            [5_000_000 if index % 2 else 6_000_000, 10_500_000]
            for index in range(200_001)
        ]
        self.assertEqual(compile_contours(self.sample, self.selection).point_count, 0)

    def test_compiled_point_budget_still_rejects_oversized_output(self):
        with patch("map_platform.topography_geometry.MAX_COMPILED_POINTS", 1):
            with self.assertRaisesRegex(ValueError, "compiled contours exceed"):
                compile_contours(self.sample, self.selection)

    def test_intermediate_record_budget_matches_extraction(self):
        self.sample["contours"].append(dict(self.sample["contours"][0]))
        with patch("map_platform.topography_geometry.MAX_CONTOUR_RECORDS", 1):
            with self.assertRaisesRegex(ValueError, "oversized contour intermediate"):
                compile_contours(self.sample, self.selection)

    def test_pack_preserves_vector_input_and_adds_terrain_only_blocks(self):
        source = self.root / "source"
        block = source / "VECTMAP/test-map/+000+000/0_0.fmb"
        block.parent.mkdir(parents=True)
        block.write_bytes(one_building_fmb4())
        font = source / "VECTMAP/test-map/assets/street-labels.fma"
        font.parent.mkdir()
        font.write_bytes(one_label_fma1())
        compiled = compile_contours(self.sample, self.selection)
        output = self.root / "pair"
        receipt = assemble_topographic_pack(source, output, "test-map", compiled, self.sample, b"Test fixture notices only\n")
        self.assertEqual(block.read_bytes(), one_building_fmb4())
        self.assertEqual(receipt["buildingCount"], 1)
        self.assertEqual(receipt["recordCount"], compiled.record_count)
        self.assertEqual(receipt["pointCount"], compiled.point_count)
        self.assertFalse(receipt["productionEligible"])
        self.assertTrue((output / "topography-receipt.json").is_file())
        outputs = list((output / "device").rglob("*.fmb"))
        self.assertEqual(len(outputs), 3)
        self.assertEqual(sum(validate_fmb5(path).building_records for path in outputs), 1)
        self.assertFalse(list((output / "device").rglob("*.btopo")))
        with self.assertRaises(FileExistsError):
            assemble_topographic_pack(source, output, "test-map", compiled, self.sample, b"Test notices\n")

    def test_generated_topography_receipt_survives_full_packaging(self):
        self.sample["sources"] = [{
            "sourceId": "fixture", "datasetRelease": "test-release",
            "termsUrl": "https://example.invalid/terms",
            "attributionUrl": "https://example.invalid/attribution",
            "accessReviewedAt": "2026-09-24",
        }]
        self.sample["inputs"] = [{"sourceId": "fixture", "cell": [0, 0], "sha256": "b" * 64}]
        source = self.root / "source"
        block = source / "VECTMAP/test-map/+000+000/0_0.fmb"
        block.parent.mkdir(parents=True)
        block.write_bytes(one_building_fmb4())
        font = source / "VECTMAP/test-map/assets/street-labels.fma"
        font.parent.mkdir()
        font.write_bytes(one_label_fma1())
        output = self.root / "pair"
        notice = b"Test fixture notices only\n"
        receipt = assemble_topographic_pack(
            source, output, "test-map", compile_contours(self.sample, self.selection), self.sample, notice,
        )
        device = output / "device"
        license_dir = device / "LICENSES"
        license_dir.mkdir()
        (license_dir / "Elevation-Sources.txt").write_bytes(notice)
        job = MapJob(
            job_id="topography-test", status=JobStatus.QUEUED,
            request={"target": {"renderer": "esp32-fmb", "rendererFormatVersion": 4},
                     "labels": {"profileVersion": 1, "preferredLanguages": ["en"],
                                "internationalFallback": "en"}},
            geometry=NormalizedGeometry(mode=GeometryMode.CUSTOM_BBOX,
                                        bounds=Bounds(-.09, -.09, .09, .09),
                                        area_km2=400, vertex_count=4),
            source_region=SourceRegion(id="fixture", provider="test", name="Fixture",
                                       url="https://example.invalid/map.osm.pbf",
                                       bounds=Bounds(-1, -1, 1, 1)),
        )
        job.map_id = "test-map"
        manifest = build_manifest(job, device, PipelineMetadata(), topography=receipt)
        archive = write_pack_archive(device, manifest, self.root / "topography.zip")
        stream = write_map_stream_artifact(
            device, {**manifest, "producer": {"buildSha256": "a" * 64,
                                              "imageDigest": "sha256:" + "b" * 64}},
            P256MapArtifactSigner("topography-test", ec.derive_private_key(4, ec.SECP256R1())),
            self.root / "topography.bmap",
        )
        archive_sha256 = hashlib.sha256(archive.read_bytes()).hexdigest()
        validation = validate_final_assembly_artifact(archive, [ArtifactRecord(
            format=ZIP_STORED_FORMAT, media_type=ZIP_MEDIA_TYPE, filename=archive.name,
            object_key=zip_object_key("test-map", archive_sha256),
            bytes=archive.stat().st_size, sha256=archive_sha256,
        )])
        self.assertEqual(manifest["target"]["topographyProfileVersion"], 1)
        self.assertEqual(manifest["topography"]["recordCount"], receipt["recordCount"])
        self.assertTrue(archive.is_file())
        self.assertGreater(stream.bytes, 0)
        self.assertTrue(validation["zipReceiptValidated"])
        with zipfile.ZipFile(archive) as original:
            entries = {name: original.read(name) for name in original.namelist()}
        entries["LICENSES/Elevation-Sources.txt"] = b"Different source notice\n"
        tampered = self.root / "tampered.zip"
        with zipfile.ZipFile(tampered, "w", compression=zipfile.ZIP_STORED) as changed:
            for name, body in entries.items():
                changed.writestr(name, body)
        tampered_sha256 = hashlib.sha256(tampered.read_bytes()).hexdigest()
        with self.assertRaisesRegex(BuildingScopeError, "elevation source notice differs"):
            validate_final_assembly_artifact(tampered, [ArtifactRecord(
                format=ZIP_STORED_FORMAT, media_type=ZIP_MEDIA_TYPE, filename=tampered.name,
                object_key=zip_object_key("test-map", tampered_sha256),
                bytes=tampered.stat().st_size, sha256=tampered_sha256,
            )])

        pipeline = MapBuildPipeline(
            PipelinePaths(Path(__file__).resolve().parents[3], self.root / "work", self.root / "packs"),
            artifact_store=FileSystemArtifactStore(self.root / "artifacts"),
            map_signer=P256MapArtifactSigner("topography-test", ec.derive_private_key(4, ec.SECP256R1())),
            producer_build_sha256="a" * 64, producer_image_digest="sha256:" + "b" * 64,
            topography_builder=lambda *_args, **_kwargs: (receipt, output / receipt["companion"]["filename"]),
        )
        packaged = pipeline._package_map(job, device, self.root / "pipeline.zip", validate_final_artifact=True)
        self.assertEqual({artifact.format for artifact in packaged.artifacts},
                         {"zip-stored-v1", "bike-map-stream-v1", "topography-ios-v1"})
        self.assertTrue(packaged.artifact_metrics["finalArtifactValidation"]["zipReceiptValidated"])

    def companion(self, path):
        compiled = compile_contours(self.sample, self.selection)
        metadata = write_companion(path, compiled, map_id="test-map", source_policy_sha256="a" * 64,
                                  attribution_sha256="b" * 64, bounds_e7=self.sample["boundsE7"])
        return compiled, metadata

    def test_companion_is_deterministic_and_bound_to_exact_intermediate(self):
        first, second = self.root / "first.btopo", self.root / "second.btopo"
        compiled, metadata = self.companion(first)
        self.companion(second)
        self.assertEqual(hashlib.sha256(first.read_bytes()).digest(), hashlib.sha256(second.read_bytes()).digest())
        self.assertGreater(metadata["tileCount"], 0)
        self.assertEqual(validate_companion(first, expected_map_id="test-map", expected_intermediate=compiled.intermediate_sha256), metadata)
        with self.assertRaises(ValueError):
            validate_companion(first, expected_map_id="another-map")
        with self.assertRaises(ValueError):
            validate_companion(first, expected_intermediate="f" * 64)
        with self.assertRaises(FileExistsError):
            self.companion(first)

    def test_companion_rejects_corruption_and_unexpected_schema(self):
        original = self.root / "original.btopo"
        self.companion(original)
        for sql in ("UPDATE tiles SET sha256 = 'bad'", "DELETE FROM tiles WHERE scale = 2",
                    "CREATE VIEW untrusted AS SELECT * FROM tiles", "UPDATE metadata SET json = '{}'",
                    "PRAGMA user_version=2", "UPDATE tiles SET png = X'89504e47'"):
            path = self.root / "mutated.btopo"
            path.write_bytes(original.read_bytes())
            with sqlite3.connect(path) as database:
                database.execute(sql)
            with self.subTest(sql=sql), self.assertRaises(ValueError):
                validate_companion(path)

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "Apple Swift/ImageIO compiler required")
    def test_iphone_companion_reader_accepts_python_artifact_and_rejects_mutations(self):
        root = Path(__file__).resolve().parents[3]
        executable = self.root / "companion-validator"
        subprocess.run(["swiftc", "-parse-as-library",
                        str(root / "ios-app/BikeComputer/BikeComputer/Models/TopographyCompanionStore.swift"),
                        str(Path(__file__).with_name("companion_validator_cli.swift")), "-o", str(executable)], check=True)
        original = self.root / "original.btopo"
        compiled, metadata = self.companion(original)
        receipt = {"mapEntryID": "entry-123", "mapContentReceipt": "c" * 64, "mapID": "test-map",
                   "sha256": hashlib.sha256(original.read_bytes()).hexdigest(), "bytes": original.stat().st_size,
                   "intermediateSha256": compiled.intermediate_sha256, "sourcePolicySha256": "a" * 64,
                   "attributionSha256": "b" * 64}
        receipt_path = self.root / "receipt.json"
        receipt_path.write_text(json.dumps(receipt))
        def read(path):
            return subprocess.run([str(executable), str(path), str(receipt_path)], check=True, text=True, capture_output=True).stdout.strip()
        self.assertEqual(read(original), f"ok {metadata['tileCount']}")
        receipt["intermediateSha256"] = "f" * 64
        receipt_path.write_text(json.dumps(receipt))
        self.assertEqual(read(original), "invalid")
        receipt["intermediateSha256"] = compiled.intermediate_sha256
        for sql in ("UPDATE tiles SET sha256 = 'bad'", "DELETE FROM tiles WHERE scale = 2",
                    "CREATE VIEW untrusted AS SELECT * FROM tiles", "UPDATE metadata SET json = '{}'",
                    "PRAGMA user_version=2"):
            path = self.root / "mutation.btopo"
            path.write_bytes(original.read_bytes())
            with sqlite3.connect(path) as database:
                database.execute(sql)
            # Rehash the outer receipt to test inner semantic validation too.
            receipt["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
            receipt["bytes"] = path.stat().st_size
            receipt_path.write_text(json.dumps(receipt))
            with self.subTest(sql=sql):
                self.assertEqual(read(path), "invalid")

    def test_empty_companion_is_valid_and_cancelled_write_is_not_published(self):
        self.sample["contours"] = []
        path = self.root / "empty.btopo"
        compiled, metadata = self.companion(path)
        self.assertEqual(metadata["tileCount"], 0)
        def cancelled():
            raise InterruptedError("cancelled")
        cancelled_path = self.root / "cancelled.btopo"
        with self.assertRaises((InterruptedError, sqlite3.OperationalError)):
            write_companion(cancelled_path, compiled, map_id="test-map", source_policy_sha256="a" * 64,
                            attribution_sha256="b" * 64, bounds_e7=self.sample["boundsE7"], cancel=cancelled)
        self.assertFalse(cancelled_path.exists())
