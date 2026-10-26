"""The contours layer, not a renderer version, decides the iPhone companion.

These tests run the real target-5 packaging/signing/catalog path for a combined
POI+contour map and an explicitly contour-free POI map, and check the committed
fixture the iPhone contract tests consume against the same validators.
"""
from __future__ import annotations

import importlib.util
import json
import shutil
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from map_platform.artifacts import (
    BIKE_MAP_STREAM_FORMAT,
    TOPOGRAPHY_COMPANION_FORMAT,
    ZIP_STORED_FORMAT,
    FileSystemArtifactStore,
)
from map_platform.catalog import CatalogPublicationError, publication_payload
from map_platform.map_stream import FIXED_HEADER_BYTES, MapStreamHeader, manifest_receipt
from map_platform.pipeline import MapBuildPipeline, PipelinePaths
from map_platform.topography_companion import validate_companion
from tests.contour_companion_fixture import build_target5_maps, load_fixture


def stream_manifest(stream: bytes) -> dict:
    header = MapStreamHeader.decode(stream[:FIXED_HEADER_BYTES])
    return json.loads(stream[FIXED_HEADER_BYTES:FIXED_HEADER_BYTES + header.manifest_bytes])


@unittest.skipUnless(importlib.util.find_spec("rasterio"), "topography native dependencies required")
class ContourCompanionContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        cls.maps = build_target5_maps(cls.root)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_combined_map_packages_one_companion_bound_to_its_signed_contours(self):
        built = self.maps["combined"]
        stream = built.artifact(BIKE_MAP_STREAM_FORMAT)
        signed = stream_manifest(built.artifact_bytes(stream))
        self.assertEqual(signed["target"]["formatVersion"], 5)
        self.assertEqual(signed["layers"], {"contours": "included"})
        topography = signed["topography"]
        companion = built.artifact(TOPOGRAPHY_COMPANION_FORMAT)
        content_receipt = built.artifact(ZIP_STORED_FORMAT).manifest_receipt
        self.assertEqual(companion.filename, f"{built.job.map_id}.btopo")
        self.assertEqual(companion.map_content_receipt, content_receipt)
        self.assertEqual(
            (companion.intermediate_sha256, companion.source_policy_sha256, companion.attribution_sha256),
            (topography["intermediateSha256"], topography["sourcePolicySha256"],
             topography["attributionSha256"]),
        )
        path = self.root / "combined-companion.btopo"
        path.write_bytes(built.artifact_bytes(companion))
        metadata = validate_companion(
            path, expected_map_id=built.job.map_id,
            expected_intermediate=topography["intermediateSha256"],
        )
        self.assertEqual(metadata["attributionSha256"], topography["attributionSha256"])
        published = [value for value in built.publication["artifacts"]
                     if value["format"] == TOPOGRAPHY_COMPANION_FORMAT]
        self.assertIn("contours", built.publication["features"])
        self.assertEqual(len(published), 1)
        self.assertEqual(published[0]["sha256"], companion.sha256)
        self.assertEqual(published[0]["companionRequirements"]["mapContentReceipt"], content_receipt)

    def test_contour_free_map_declares_no_contours_and_carries_no_companion(self):
        built = self.maps["plain"]
        signed = stream_manifest(built.artifact_bytes(built.artifact(BIKE_MAP_STREAM_FORMAT)))
        self.assertEqual(signed["target"]["formatVersion"], 5)
        self.assertEqual(signed["layers"], {"contours": "not-included"})
        self.assertNotIn("topography", signed)
        self.assertFalse(any(value.format == TOPOGRAPHY_COMPANION_FORMAT for value in built.artifacts))
        self.assertNotIn("contours", built.publication["features"])
        self.assertFalse(any(value["format"] == TOPOGRAPHY_COMPANION_FORMAT
                             for value in built.publication["artifacts"]))

    def test_publication_rejects_missing_foreign_or_undeclared_companions(self):
        combined, plain = self.maps["combined"], self.maps["plain"]
        companion = combined.artifact(TOPOGRAPHY_COMPANION_FORMAT)
        cases = {
            "missing": (combined, [value for value in combined.artifacts if value != companion]),
            "duplicate": (combined, [*combined.artifacts, companion]),
            "undeclared": (plain, [*plain.artifacts, companion]),
        }
        for name, (built, artifacts) in cases.items():
            with self.subTest(name), patch.object(built.job, "artifacts", artifacts):
                with self.assertRaisesRegex(CatalogPublicationError, "companion artifact"):
                    publication_payload(built.job, "development")

    def test_exact_reuse_of_a_contour_free_map_rejects_a_companion(self):
        plain, combined = self.maps["plain"], self.maps["combined"]
        companion = combined.artifact(TOPOGRAPHY_COMPANION_FORMAT)
        store_root = self.root / "reuse-artifacts"
        shutil.copytree(plain.artifact_root, store_root)
        (store_root / companion.object_key).parent.mkdir(parents=True, exist_ok=True)
        (store_root / companion.object_key).write_bytes(combined.artifact_bytes(companion))
        pipeline = MapBuildPipeline(
            PipelinePaths(Path(__file__).resolve().parents[3], self.root / "reuse-work", self.root / "reuse-packs"),
            artifact_store=FileSystemArtifactStore(store_root),
        )
        class ReachedStaging(Exception):
            pass

        with patch("map_platform.pipeline.stable_map_id", return_value=plain.job.map_id), \
                patch.object(MapBuildPipeline, "_stage_subset_pack", side_effect=ReachedStaging):
            # Without a companion the exact candidate proceeds to pack staging.
            with self.assertRaises(ReachedStaging):
                pipeline.validate_exact_reuse_candidate(plain.job, plain.job)
            with patch.object(plain.job, "artifacts", [*plain.artifacts, companion]):
                self.assertFalse(pipeline.validate_exact_reuse_candidate(plain.job, plain.job))

    def test_committed_fixture_is_the_real_contract(self):
        fixture = load_fixture()
        for variant in ("combined", "plain"):
            artifacts = json.loads(fixture[f"{variant}_artifacts_json"])
            stream_record = next(value for value in artifacts if value["format"] == BIKE_MAP_STREAM_FORMAT)
            stream = bytes.fromhex(fixture[f"{variant}_stream_hex"])
            signed = stream_manifest(stream)
            header = MapStreamHeader.decode(stream[:FIXED_HEADER_BYTES])
            self.assertEqual(
                manifest_receipt(stream[FIXED_HEADER_BYTES:FIXED_HEADER_BYTES + header.manifest_bytes]),
                stream_record["manifestReceipt"],
            )
            companions = [value for value in artifacts if value["format"] == TOPOGRAPHY_COMPANION_FORMAT]
            publication = json.loads(fixture[f"{variant}_publication_json"])
            self.assertEqual("contours" in publication["features"], "topography" in signed)
            self.assertEqual(len(companions), 1 if "topography" in signed else 0)
            if not companions:
                continue
            path = self.root / f"fixture-{variant}.btopo"
            path.write_bytes(bytes.fromhex(fixture[f"{variant}_companion_hex"]))
            metadata = validate_companion(
                path, expected_map_id=signed["mapId"],
                expected_intermediate=signed["topography"]["intermediateSha256"],
            )
            self.assertEqual(metadata["sourcePolicySha256"], companions[0]["sourcePolicySha256"])
            zip_record = next(value for value in artifacts if value["format"] == ZIP_STORED_FORMAT)
            self.assertEqual(companions[0]["mapContentReceipt"], zip_record["manifestReceipt"])


if __name__ == "__main__":
    unittest.main()
