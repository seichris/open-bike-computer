from __future__ import annotations

import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from map_platform.catalog_promotion import CatalogPromotionError, _download_exact_zip


class FakeResponse:
    def __init__(self, body: bytes, final_url: str):
        self.body = body
        self.final_url = final_url
        self.offset = 0

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return None

    def geturl(self) -> str:
        return self.final_url

    def read(self, amount: int) -> bytes:
        value = self.body[self.offset : self.offset + amount]
        self.offset += len(value)
        return value


class CatalogPromotionDownloadTests(unittest.TestCase):
    def test_download_streams_exact_receipt_from_configured_r2_host(self):
        body = b"validated final ZIP bytes"
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "source.zip"
            with patch(
                "map_platform.catalog_promotion.urlopen",
                return_value=FakeResponse(
                    body,
                    "https://a" + "1" * 31 + ".r2.cloudflarestorage.com/map-artifacts/source.zip",
                ),
            ):
                _download_exact_zip(
                    "https://maps-share.8o.vc/v1/internal/promotions/downloads/token",
                    destination,
                    expected_bytes=len(body),
                    expected_sha256=hashlib.sha256(body).hexdigest(),
                    catalog_origin="https://maps-share.8o.vc",
                    r2_endpoint="https://a" + "1" * 31 + ".r2.cloudflarestorage.com",
                    timeout_seconds=10,
                )
            self.assertEqual(destination.read_bytes(), body)

    def test_download_rejects_redirect_away_from_configured_r2_host(self):
        body = b"untrusted"
        with tempfile.TemporaryDirectory() as temporary:
            with patch(
                "map_platform.catalog_promotion.urlopen",
                return_value=FakeResponse(body, "https://evil.invalid/source.zip"),
            ):
                with self.assertRaisesRegex(CatalogPromotionError, "redirect"):
                    _download_exact_zip(
                        "https://maps-share.8o.vc/v1/internal/promotions/downloads/token",
                        Path(temporary) / "source.zip",
                        expected_bytes=len(body),
                        expected_sha256=hashlib.sha256(body).hexdigest(),
                        catalog_origin="https://maps-share.8o.vc",
                        r2_endpoint="https://a" + "1" * 31 + ".r2.cloudflarestorage.com",
                        timeout_seconds=10,
                    )

    def test_download_rejects_receipt_mismatch(self):
        body = b"changed"
        with tempfile.TemporaryDirectory() as temporary:
            with patch(
                "map_platform.catalog_promotion.urlopen",
                return_value=FakeResponse(
                    body,
                    "https://a" + "1" * 31 + ".r2.cloudflarestorage.com/source.zip",
                ),
            ):
                with self.assertRaisesRegex(CatalogPromotionError, "receipt"):
                    _download_exact_zip(
                        "https://maps-share.8o.vc/v1/internal/promotions/downloads/token",
                        Path(temporary) / "source.zip",
                        expected_bytes=len(body),
                        expected_sha256="0" * 64,
                        catalog_origin="https://maps-share.8o.vc",
                        r2_endpoint="https://a" + "1" * 31 + ".r2.cloudflarestorage.com",
                        timeout_seconds=10,
                    )


if __name__ == "__main__":
    unittest.main()
