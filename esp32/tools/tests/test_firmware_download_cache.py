import hashlib
import io
import os
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import Mock, patch

from build_firmware import _download_verified_archive
from generated_sdkconfig import GeneratedSdkconfigError
from firmware_runtime import Artifact, FirmwareRuntimeError, download_verified


class FirmwareDownloadCacheTests(unittest.TestCase):
    def test_runtime_transport_retries_only_transient_http_failures(self):
        artifact = Artifact("https://example.invalid/runtime", len(self.contents), self.sha256)
        unavailable = urllib.error.HTTPError(artifact.url, 504, "gateway timeout", None, None)
        with patch("firmware_runtime.time.sleep") as sleep:
            opener = Mock(side_effect=[unavailable, io.BytesIO(self.contents)])
            destination = self.root / "runtime.tar"
            download_verified(artifact, destination, opener=opener)
            self.assertEqual(destination.read_bytes(), self.contents)
            self.assertEqual(opener.call_count, 2)
            sleep.assert_called_once_with(1)

    def test_runtime_digest_failure_is_not_retried(self):
        artifact = Artifact("https://example.invalid/runtime", len(self.contents), "0" * 64)
        opener = Mock(return_value=io.BytesIO(self.contents))
        destination = self.root / "runtime.tar"
        with self.assertRaisesRegex(FirmwareRuntimeError, "SHA-256"):
            download_verified(artifact, destination, opener=opener)
        opener.assert_called_once()
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.root.iterdir()), [])

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        override = patch.dict(os.environ, {"OPEN_BIKE_FIRMWARE_BUILD_CACHE": str(self.root / "shared")})
        override.start()
        self.addCleanup(override.stop)
        self.contents = b"content-pinned dependency archive"
        self.sha256 = hashlib.sha256(self.contents).hexdigest()

    def download(self, directory):
        directory.mkdir()
        return _download_verified_archive(directory, label="test", url="https://example.invalid/archive", sha256=self.sha256, size=len(self.contents), filename="test.tar")

    def test_second_worktree_restores_without_network_access(self):
        with patch("build_firmware.urllib.request.urlopen", return_value=io.BytesIO(self.contents)) as transport:
            first = self.download(self.root / "first")
            self.assertEqual(first.read_bytes(), self.contents)
            transport.assert_called_once()
        with patch("build_firmware.urllib.request.urlopen", side_effect=AssertionError("network must not be used")):
            second = self.download(self.root / "second")
            self.assertEqual(second.read_bytes(), self.contents)
        self.assertNotEqual(first, second)

    def test_corrupt_shared_archive_is_rejected_before_use(self):
        with patch("build_firmware.urllib.request.urlopen", return_value=io.BytesIO(self.contents)):
            self.download(self.root / "first")
        payload = next((self.root / "shared").rglob("archive"))
        payload.chmod(0o644)
        payload.write_bytes(b"wrong bytes")
        payload.chmod(0o444)
        with patch("build_firmware.urllib.request.urlopen", side_effect=AssertionError("network must not be used")):
            with self.assertRaisesRegex(GeneratedSdkconfigError, "corrupt or unsafe"):
                self.download(self.root / "second")
        self.assertEqual(list((self.root / "second").iterdir()), [])
