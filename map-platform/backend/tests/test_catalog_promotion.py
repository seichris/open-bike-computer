from __future__ import annotations

import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from map_platform.catalog import map_entry_id_for_descriptor
from map_platform.catalog_promotion import (
    CatalogPromotionError,
    _download_exact_zip,
    promote_catalog_map,
)
from map_platform.map_stream import canonical_stream_manifest_bytes, manifest_receipt


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


class FakePromotionCatalog:
    channel = "production"
    base_url = "https://maps-share.8o.vc"
    timeout_seconds = 10

    def __init__(self, grant):
        self.grant = grant

    def promotion_grant(self, entry_id):
        del entry_id
        return self.grant


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


class CatalogPromotionIdentityTests(unittest.TestCase):
    @staticmethod
    def manifest():
        payload = b"legacy-map-block"
        return {
            "schemaVersion": 1,
            "mapId": "promotion-map",
            "bounds": [120.0, 30.0, 121.0, 31.0],
            "target": {"renderer": "esp32-fmb", "formatVersion": 1},
            "source": {"provider": "geofabrik", "license": "ODbL-1.0"},
            "files": [
                {
                    "path": "VECTMAP/promotion-map/+0000+0000/1.fmb",
                    "bytes": len(payload),
                    "sha256": hashlib.sha256(payload).hexdigest(),
                }
            ],
        }

    @staticmethod
    def grant(*, content_receipt, entry_id):
        return {
            "downloadURL": (
                "https://maps-share.8o.vc/v1/internal/promotions/downloads/token"
            ),
            "artifact": {
                "format": "zip-stored-v1",
                "deliveryTier": "development",
                "filename": "promotion-map.zip",
                "objectKey": f"maps/promotion-map/zip-stored-v1/{'1' * 64}.zip",
                "bytes": 100,
                "sha256": "1" * 64,
                "manifestReceipt": content_receipt,
            },
            "map": {
                "mapEntryId": entry_id,
                "mapId": "promotion-map",
                "contentReceipt": content_receipt,
                "originChannel": "development",
                "canonicalName": "Promotion map",
                "sourceRegionName": "China",
                "bounds": [120.0, 30.0, 121.0, 31.0],
                "renderer": "esp32-fmb",
                "rendererFormatVersion": 1,
                "features": [],
                "attribution": {
                    "provider": "geofabrik",
                    "license": "ODbL-1.0",
                },
                "generatedAt": "2026-08-25T00:00:00Z",
            },
        }

    def promote_until_identity_validation(self, grant, manifest):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(
            "os.environ",
            {
                "MAP_PLATFORM_S3_ENDPOINT_URL": (
                    "https://a" + "1" * 31 + ".r2.cloudflarestorage.com"
                )
            },
            clear=True,
        ), patch(
            "map_platform.catalog_promotion._download_exact_zip"
        ), patch(
            "map_platform.catalog_promotion.validate_final_assembly_artifact"
        ), patch(
            "map_platform.catalog_promotion._extract_validated_archive",
            return_value=manifest,
        ):
            return promote_catalog_map(
                grant["map"]["mapEntryId"],
                catalog_client=FakePromotionCatalog(grant),
                artifact_store=object(),
                signer=object(),
                producer_build_sha256="2" * 64,
                producer_image_digest="sha256:" + "3" * 64,
                work_root=Path(temporary),
            )

    def test_promotion_rejects_catalog_content_receipt_not_derived_from_zip(self):
        manifest = self.manifest()
        forged_receipt = "4" * 64
        forged_entry_id = map_entry_id_for_descriptor(
            content_receipt=forged_receipt,
            renderer="esp32-fmb",
            renderer_format_version=1,
            features=[],
        )
        grant = self.grant(
            content_receipt=forged_receipt,
            entry_id=forged_entry_id,
        )

        with self.assertRaisesRegex(CatalogPromotionError, "content receipt"):
            self.promote_until_identity_validation(grant, manifest)

    def test_promotion_rejects_map_entry_id_not_derived_from_zip(self):
        manifest = self.manifest()
        receipt = manifest_receipt(canonical_stream_manifest_bytes(manifest))
        forged_entry_id = "map_v1_" + "A" * 43
        expected_entry_id = map_entry_id_for_descriptor(
            content_receipt=receipt,
            renderer="esp32-fmb",
            renderer_format_version=1,
            features=[],
        )
        self.assertNotEqual(forged_entry_id, expected_entry_id)
        grant = self.grant(
            content_receipt=receipt,
            entry_id=forged_entry_id,
        )

        with self.assertRaisesRegex(CatalogPromotionError, "map entry identity"):
            self.promote_until_identity_validation(grant, manifest)

if __name__ == "__main__":
    unittest.main()
