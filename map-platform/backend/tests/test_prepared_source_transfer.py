from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from map_platform.preparation_objects import PreparationObjectStore
from map_platform.prepared_source_transfer import PreparedSourceTransfer
from tests.test_artifacts import FakeS3Client


class PreparedSourceTransferTests(unittest.TestCase):
    def test_manifest_last_chunked_round_trip_and_corruption(self):
        client = FakeS3Client()
        remote = PreparationObjectStore(client, "preparation-test")
        transfer = PreparedSourceTransfer(remote, chunk_bytes=8)
        with tempfile.TemporaryDirectory() as temporary, patch(
            "map_platform.prepared_source_transfer.MIN_FREE_BYTES", 0
        ):
            root = Path(temporary)
            source = root / "source.sqlite"
            source.write_bytes(b"sealed-preparation-source")
            slot = "a" * 64
            self.assertIsNone(transfer.restore_file("source-index", slot, root / "absent", max_bytes=100))
            manifest = transfer.publish_file("source-index", slot, source)
            self.assertGreater(len(manifest["chunks"]), 1)
            restored = root / "restored.sqlite"
            transfer.restore_file("source-index", slot, restored, max_bytes=100)
            self.assertEqual(restored.read_bytes(), source.read_bytes())
            restored.unlink()
            chunk = manifest["chunks"][0]["sha256"]
            client.objects[("preparation-test", f"map-preparation-v1/source-index-chunk/blobs/{chunk}")]["body"] = b"X" * 8
            with self.assertRaises(Exception):
                transfer.restore_file("source-index", slot, restored, max_bytes=100)
            self.assertFalse(restored.exists())

    def test_restore_rejects_local_change_and_limit(self):
        client = FakeS3Client()
        remote = PreparationObjectStore(client, "preparation-test")
        transfer = PreparedSourceTransfer(remote, chunk_bytes=8)
        with tempfile.TemporaryDirectory() as temporary, patch(
            "map_platform.prepared_source_transfer.MIN_FREE_BYTES", 0
        ):
            root = Path(temporary)
            source = root / "source"
            source.write_bytes(b"abcdefghijk")
            slot = "b" * 64
            transfer.publish_file("source-index", slot, source)
            with self.assertRaisesRegex(ValueError, "limit|pointer"):
                transfer.restore_file("source-index", slot, root / "restored", max_bytes=10)
            restored = root / "restored"
            restored.write_bytes(b"X" * 11)
            with self.assertRaisesRegex(ValueError, "differs"):
                transfer.restore_file("source-index", slot, restored, max_bytes=100)
