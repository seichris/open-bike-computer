from __future__ import annotations

import base64
import hashlib
import json
import tempfile
import threading
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from map_platform.catalog import map_entry_id_for_descriptor
from map_platform.catalog_promotion import (
    CatalogPromotionError,
    _PromotionLeaseHeartbeat,
    _download_exact_zip,
    _extract_validated_archive,
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

    def renew_promotion_lease(self, entry_id, *, lease_id, artifact):
        del artifact
        return {
            "mapEntryId": entry_id,
            "leaseId": lease_id,
            "leaseExpiresAt": "2026-08-25T01:00:00Z",
        }


class CatalogPromotionDownloadTests(unittest.TestCase):
    def test_extract_restores_the_verified_archive_preview_identity(self):
        preview_bytes = b"verified-preview-png"
        manifest = {
            "preview": {
                "path": "preview.png",
                "bytes": len(preview_bytes),
                "sha256": hashlib.sha256(preview_bytes).hexdigest(),
            }
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "source.zip"
            extract_root = root / "extract"
            extract_root.mkdir()
            with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("manifest.json", json.dumps(manifest))
                archive.writestr("preview.png", preview_bytes)

            extracted = _extract_validated_archive(archive_path, extract_root)

        self.assertEqual(
            extracted["preview"]["dataBase64"],
            base64.b64encode(preview_bytes).decode("ascii"),
        )

    def test_extract_rejects_a_preview_that_does_not_match_its_identity(self):
        manifest = {
            "preview": {
                "path": "preview.png",
                "bytes": 8,
                "sha256": hashlib.sha256(b"expected").hexdigest(),
            }
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "source.zip"
            extract_root = root / "extract"
            extract_root.mkdir()
            with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("manifest.json", json.dumps(manifest))
                archive.writestr("preview.png", b"tampered")

            with self.assertRaisesRegex(CatalogPromotionError, "preview identity"):
                _extract_validated_archive(archive_path, extract_root)

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
            ) as open_url:
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
            request = open_url.call_args.args[0]
            self.assertEqual(request.get_header("User-agent"), "BicinoMapPlatform/1.0")

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


class PromotionLeaseHeartbeatTests(unittest.TestCase):
    def test_renews_the_exact_lease_during_long_running_promotion(self):
        renewed = threading.Event()
        catalog = Mock()

        def renew(entry_id, *, lease_id, artifact):
            renewed.set()
            self.assertEqual(entry_id, "map_v1_" + "m" * 43)
            self.assertEqual(lease_id, "promotion_lease_v1_" + "L" * 32)
            self.assertEqual(artifact["artifactId"], "artifact_v1_" + "A" * 43)
            return {
                "mapEntryId": entry_id,
                "leaseId": lease_id,
                "leaseExpiresAt": "2026-08-25T01:00:00Z",
            }

        catalog.renew_promotion_lease.side_effect = renew
        heartbeat = _PromotionLeaseHeartbeat(
            catalog_client=catalog,
            entry_id="map_v1_" + "m" * 43,
            lease_id="promotion_lease_v1_" + "L" * 32,
            artifact={"artifactId": "artifact_v1_" + "A" * 43},
            interval_seconds=0.01,
        )
        with heartbeat:
            self.assertTrue(renewed.wait(1))
            heartbeat.check()
        catalog.renew_promotion_lease.assert_called()

    def test_surfaces_lease_loss_on_the_promotion_thread(self):
        attempted = threading.Event()
        catalog = Mock()

        def fail(*_args, **_kwargs):
            attempted.set()
            raise RuntimeError("lease lost")

        catalog.renew_promotion_lease.side_effect = fail
        heartbeat = _PromotionLeaseHeartbeat(
            catalog_client=catalog,
            entry_id="map_v1_" + "m" * 43,
            lease_id="promotion_lease_v1_" + "L" * 32,
            artifact={"artifactId": "artifact_v1_" + "A" * 43},
            interval_seconds=0.01,
        )
        heartbeat.__enter__()
        self.assertTrue(attempted.wait(1))
        with self.assertRaisesRegex(CatalogPromotionError, "renewal failed"):
            heartbeat.check()
        heartbeat.stop()

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
            "state": "granted",
            "leaseId": "promotion_lease_v1_" + "L" * 32,
            "leaseExpiresAt": "2026-08-25T01:00:00Z",
            "downloadURL": (
                "https://maps-share.8o.vc/v1/internal/promotions/downloads/token"
            ),
            "artifact": {
                "artifactId": "artifact_v1_" + "A" * 43,
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
                artifact_store=SimpleNamespace(catalog_delivery_backed=True),
                signer=object(),
                producer_build_sha256="2" * 64,
                producer_image_digest="sha256:" + "3" * 64,
                work_root=Path(temporary),
            )

    def test_promotion_rejects_unshared_storage_before_acquiring_a_grant(self):
        catalog = Mock(channel="production")

        with self.assertRaisesRegex(CatalogPromotionError, "shared artifact storage"):
            promote_catalog_map(
                "map_v1_" + "M" * 43,
                catalog_client=catalog,
                artifact_store=SimpleNamespace(catalog_delivery_backed=False),
                signer=object(),
                producer_build_sha256="2" * 64,
                producer_image_digest="sha256:" + "3" * 64,
                work_root=Path("/path/that/must/not/be/created"),
            )

        catalog.promotion_grant.assert_not_called()

    def test_already_production_short_circuits_all_local_work(self):
        entry_id = "map_v1_" + "M" * 43
        grant = {
            "state": "already_production",
            "mapEntryId": entry_id,
            "publicationId": "promotion:production:" + "9" * 64,
            "artifact": {
                "artifactId": "artifact_v1_" + "P" * 43,
                "format": "bike-map-stream-v1",
                "deliveryTier": "production",
                "objectKey": "maps/promotion-map/production.bmap",
                "bytes": 123,
                "sha256": "8" * 64,
            },
        }
        artifact_store = Mock()
        signer = Mock()

        result = promote_catalog_map(
            entry_id,
            catalog_client=FakePromotionCatalog(grant),
            artifact_store=artifact_store,
            signer=signer,
            producer_build_sha256="2" * 64,
            producer_image_digest="sha256:" + "3" * 64,
            work_root=Path("/path/that/must/not/be/created"),
        )

        self.assertEqual(result["state"], "already_production")
        artifact_store.assert_not_called()
        signer.assert_not_called()

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

    def test_promotion_never_finalizes_an_unverified_shared_object(self):
        manifest = self.manifest()
        receipt = manifest_receipt(canonical_stream_manifest_bytes(manifest))
        entry_id = map_entry_id_for_descriptor(
            content_receipt=receipt,
            renderer="esp32-fmb",
            renderer_format_version=1,
            features=[],
        )
        catalog = FakePromotionCatalog(
            self.grant(content_receipt=receipt, entry_id=entry_id)
        )
        catalog.finalize_promotion = Mock()
        artifact_store = SimpleNamespace(
            catalog_delivery_backed=True,
            put=Mock(),
            verify=Mock(return_value=False),
        )
        stream = SimpleNamespace(
            signed_manifest_receipt="5" * 64,
            signature_key_id="production",
            sha256="6" * 64,
            bytes=123,
            manifest_receipt=receipt,
        )
        signer = SimpleNamespace(public_key_sha256="7" * 64)
        environment = {
            "MAP_PLATFORM_S3_ENDPOINT_URL": (
                "https://a" + "1" * 31 + ".r2.cloudflarestorage.com"
            ),
        }
        with tempfile.TemporaryDirectory() as temporary, patch.dict(
            "os.environ",
            environment,
            clear=True,
        ), patch(
            "map_platform.catalog_promotion._download_exact_zip"
        ), patch(
            "map_platform.catalog_promotion.validate_final_assembly_artifact"
        ), patch(
            "map_platform.catalog_promotion._extract_validated_archive",
            return_value=manifest,
        ), patch(
            "map_platform.catalog_promotion.validate_renderer_artifacts"
        ), patch(
            "map_platform.catalog_promotion.write_map_stream_artifact",
            return_value=stream,
        ):
            with self.assertRaisesRegex(CatalogPromotionError, "missing"):
                promote_catalog_map(
                    entry_id,
                    catalog_client=catalog,
                    artifact_store=artifact_store,
                    signer=signer,
                    producer_build_sha256="2" * 64,
                    producer_image_digest="sha256:" + "3" * 64,
                    work_root=Path(temporary),
                )
        artifact_store.verify.assert_called_once()
        catalog.finalize_promotion.assert_not_called()

if __name__ == "__main__":
    unittest.main()
