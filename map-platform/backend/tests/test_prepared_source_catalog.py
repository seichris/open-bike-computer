from __future__ import annotations

import sys
import io
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from map_platform.preparation_objects import PreparationObjectStore
from map_platform.prepared_source_catalog import PreparedSourceCatalog
from tests.test_artifacts import FakeS3Client

SCRIPTS = Path(__file__).resolve().parents[3] / "tools" / "OSM_Extract" / "scripts"
sys.path.insert(0, str(SCRIPTS))
from building_calibration_cache import CalibrationCache, CalibrationIdentity, CalibrationSample  # noqa: E402
from building_source_index import BuildingSourceIndex  # noqa: E402


class PreparedSourceCatalogTests(unittest.TestCase):
    def test_cold_restore_uses_the_same_source_and_calibration_identities(self):
        client = FakeS3Client()
        catalog = PreparedSourceCatalog(PreparationObjectStore(client, "test-bucket"), chunk_bytes=1024)
        source_sha = "a" * 64
        identity = CalibrationIdentity(source_sha, "b" * 64, 1, 8192, 1, 3)
        with tempfile.TemporaryDirectory() as temporary, patch(
            "map_platform.prepared_source_transfer.MIN_FREE_BYTES", 0
        ), patch("map_platform.prepared_source_catalog.MIN_FREE_BYTES", 0):
            first = Path(temporary) / "first"
            second = Path(temporary) / "second"
            source = BuildingSourceIndex(first, source_sha)
            source.build(nodes=[], ways=[], relations=[])
            calibration = CalibrationCache(first, identity)
            calibration.materialize_cells(
                [(0, 0)], {(0, 0): [CalibrationSample("w1", "office", 100)]},
                complete_source_snapshot=True, complete_domain_cells=[(0, 0)],
            )
            source_manifest = catalog.publish_index(first, source_sha)
            calibration_manifest = catalog.publish_calibration(
                first, {**identity.document(), "calibrationKey": identity.key},
            )
            self.assertEqual(catalog.publish_calibration(
                first, {**identity.document(), "calibrationKey": identity.key},
            ), calibration_manifest)
            restored_source = catalog.restore_index(second, source_sha, max_bytes=10_000_000)
            restored_calibration = catalog.restore_calibration(
                second, {**identity.document(), "calibrationKey": identity.key},
                max_bytes=10_000_000,
            )
            self.assertEqual(BuildingSourceIndex.from_manifest(restored_source).validate_ready()["manifestSha256"],
                             source_manifest["manifestSha256"])
            self.assertEqual(CalibrationCache.from_manifest(restored_calibration).validate_complete_generation()["manifestSha256"],
                             calibration_manifest["manifestSha256"])

    def test_calibration_archive_rejects_an_unlisted_path(self):
        client = FakeS3Client()
        catalog = PreparedSourceCatalog(PreparationObjectStore(client, "test-bucket"), chunk_bytes=1024)
        identity = CalibrationIdentity("a" * 64, "b" * 64, 1, 8192, 1, 3)
        document = {**identity.document(), "calibrationKey": identity.key}
        with tempfile.TemporaryDirectory() as temporary, patch(
            "map_platform.prepared_source_transfer.MIN_FREE_BYTES", 0
        ), patch("map_platform.prepared_source_catalog.MIN_FREE_BYTES", 0):
            root = Path(temporary)
            cache = CalibrationCache(root / "first", identity)
            cache.materialize_cells(
                [(0, 0)], {(0, 0): [CalibrationSample("w1", "office", 100)]},
                complete_source_snapshot=True, complete_domain_cells=[(0, 0)],
            )
            archive = root / "malicious.tar"
            with tarfile.open(archive, "w") as output:
                manifest = (cache.key_root / "manifest.json").read_bytes()
                header = tarfile.TarInfo("manifest.json")
                header.size = len(manifest)
                output.addfile(header, io.BytesIO(manifest))
                header = tarfile.TarInfo("../escape")
                header.size = 1
                output.addfile(header, io.BytesIO(b"X"))
            catalog.transfer.publish_file("source-calibration", identity.key, archive)
            with self.assertRaisesRegex(ValueError, "cells differ"):
                catalog.restore_calibration(root / "second", document, max_bytes=10_000_000)
            self.assertFalse((root / "escape").exists())
