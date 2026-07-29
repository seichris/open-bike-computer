import tempfile
import unittest
from pathlib import Path

from map_platform.downloads import DownloadSigner, DownloadTokenError


class DownloadSignerTests(unittest.TestCase):
    def test_signs_and_verifies_pack_download(self):
        signer = DownloadSigner("secret")
        with tempfile.TemporaryDirectory() as tmp:
            pack = Path(tmp) / "map.zip"
            pack.write_bytes(b"zip")

            signed = signer.sign("map-id", pack, ttl_seconds=60, now=100)

            signer.verify("map-id", pack, expires_at=signed.expires_at, signature=signed.signature, now=120)

    def test_rejects_expired_signature(self):
        signer = DownloadSigner("secret")
        signed = signer.sign("map-id", "/tmp/map.zip", ttl_seconds=60, now=100)

        with self.assertRaises(DownloadTokenError):
            signer.verify("map-id", "/tmp/map.zip", expires_at=signed.expires_at, signature=signed.signature, now=200)

    def test_rejects_tampered_path(self):
        signer = DownloadSigner("secret")
        signed = signer.sign("map-id", "/tmp/map.zip", ttl_seconds=60, now=100)

        with self.assertRaises(DownloadTokenError):
            signer.verify("map-id", "/tmp/other.zip", expires_at=signed.expires_at, signature=signed.signature, now=120)


if __name__ == "__main__":
    unittest.main()
