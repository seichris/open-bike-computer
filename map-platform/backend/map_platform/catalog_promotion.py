from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import tempfile
import threading
import zipfile
from pathlib import Path
from typing import Any
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from .artifacts import (
    BIKE_MAP_STREAM_FORMAT,
    BIKE_MAP_STREAM_MEDIA_TYPE,
    ZIP_MEDIA_TYPE,
    ZIP_STORED_FORMAT,
    ArtifactRecord,
    map_stream_object_key,
)
from .catalog import (
    CatalogClient,
    artifact_id,
    catalog_delivery_requirements,
    map_entry_id_for_descriptor,
)
from .map_artifact_validation import validate_renderer_artifacts
from .map_stream import (
    canonical_stream_manifest_bytes,
    manifest_receipt,
    write_map_stream_artifact,
)
from .pipeline import validate_final_assembly_artifact


class CatalogPromotionError(RuntimeError):
    code = "catalog_promotion_failed"


class _PromotionLeaseHeartbeat:
    def __init__(
        self,
        *,
        catalog_client: CatalogClient,
        entry_id: str,
        lease_id: str,
        artifact: dict[str, Any],
        interval_seconds: float = 300.0,
    ) -> None:
        self.catalog_client = catalog_client
        self.entry_id = entry_id
        self.lease_id = lease_id
        self.artifact = artifact
        self.interval_seconds = interval_seconds
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._error: Exception | None = None

    def __enter__(self) -> _PromotionLeaseHeartbeat:
        self._thread = threading.Thread(
            target=self._run,
            name=f"promotion-lease-{self.entry_id[-8:]}",
            daemon=True,
        )
        self._thread.start()
        return self

    def __exit__(self, exception_type, *_: Any) -> None:
        self.stop()
        if exception_type is None:
            self.check()

    def _run(self) -> None:
        while not self._stop.wait(self.interval_seconds):
            try:
                result = self.catalog_client.renew_promotion_lease(
                    self.entry_id,
                    lease_id=self.lease_id,
                    artifact=self.artifact,
                )
                if (
                    result.get("mapEntryId") != self.entry_id
                    or result.get("leaseId") != self.lease_id
                    or not isinstance(result.get("leaseExpiresAt"), str)
                ):
                    raise CatalogPromotionError(
                        "promotion lease renewal returned invalid identity"
                    )
            except Exception as exc:  # noqa: BLE001 - surfaced on the main thread
                self._error = exc
                self._stop.set()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join()
            self._thread = None

    def check(self) -> None:
        if self._error is not None:
            raise CatalogPromotionError("promotion lease renewal failed") from self._error


def _require_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise CatalogPromotionError(f"promotion {field} is invalid")
    return value


def already_production_result(
    entry_id: str,
    grant: dict[str, Any],
) -> dict[str, Any] | None:
    if grant.get("state") != "already_production":
        return None
    artifact = grant.get("artifact")
    if grant.get("mapEntryId") != entry_id or not isinstance(artifact, dict):
        raise CatalogPromotionError("existing production promotion is invalid")
    artifact_id_value = _require_string(artifact.get("artifactId"), "artifact ID")
    object_key = _require_string(artifact.get("objectKey"), "object key")
    sha256 = _require_string(artifact.get("sha256"), "artifact receipt")
    byte_count = artifact.get("bytes")
    if (
        artifact.get("format") != BIKE_MAP_STREAM_FORMAT
        or artifact.get("deliveryTier") != "production"
        or type(byte_count) is not int
        or byte_count <= 0
        or len(sha256) != 64
    ):
        raise CatalogPromotionError("existing production artifact is invalid")
    publication_id = grant.get("publicationId")
    if publication_id is not None and not isinstance(publication_id, str):
        raise CatalogPromotionError("existing production publication is invalid")
    return {
        "mapEntryId": entry_id,
        "publicationId": publication_id,
        "artifactId": artifact_id_value,
        "objectKey": object_key,
        "bytes": byte_count,
        "sha256": sha256,
        "state": "already_production",
    }


def _download_exact_zip(
    url: str,
    destination: Path,
    *,
    expected_bytes: int,
    expected_sha256: str,
    catalog_origin: str,
    r2_endpoint: str,
    timeout_seconds: float,
) -> None:
    initial = urlparse(url)
    catalog = urlparse(catalog_origin)
    r2 = urlparse(r2_endpoint)
    if (
        initial.scheme != "https"
        or (initial.hostname, initial.port) != (catalog.hostname, catalog.port)
        or initial.username is not None
        or initial.password is not None
        or r2.scheme != "https"
        or not r2.hostname
    ):
        raise CatalogPromotionError("promotion download endpoint is invalid")
    digest = hashlib.sha256()
    written = 0
    request = Request(url, headers={"Accept": ZIP_MEDIA_TYPE})
    try:
        with urlopen(request, timeout=timeout_seconds) as response:
            final = urlparse(response.geturl())
            if (
                final.scheme != "https"
                or final.hostname != r2.hostname
                or final.port != r2.port
            ):
                raise CatalogPromotionError("promotion download redirect is invalid")
            with destination.open("xb") as output:
                while True:
                    chunk = response.read(min(1024 * 1024, expected_bytes - written + 1))
                    if not chunk:
                        break
                    written += len(chunk)
                    if written > expected_bytes:
                        raise CatalogPromotionError("promotion ZIP exceeds its receipt")
                    output.write(chunk)
                    digest.update(chunk)
                output.flush()
                os.fsync(output.fileno())
    except CatalogPromotionError:
        raise
    except OSError as exc:
        raise CatalogPromotionError("promotion ZIP download failed") from exc
    if written != expected_bytes or digest.hexdigest() != expected_sha256:
        raise CatalogPromotionError("promotion ZIP receipt does not match")


def _extract_validated_archive(archive_path: Path, root: Path) -> dict[str, Any]:
    try:
        with zipfile.ZipFile(archive_path) as archive:
            manifest = json.loads(archive.read("manifest.json"))
            for info in archive.infolist():
                destination = root.joinpath(*Path(info.filename).parts)
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(info) as source, destination.open("xb") as output:
                    shutil.copyfileobj(source, output, length=1024 * 1024)
    except (OSError, ValueError, zipfile.BadZipFile, json.JSONDecodeError) as exc:
        raise CatalogPromotionError("promotion ZIP extraction failed") from exc
    return manifest


def promote_catalog_map(
    entry_id: str,
    *,
    catalog_client: CatalogClient,
    artifact_store: Any,
    signer: Any,
    producer_build_sha256: str,
    producer_image_digest: str,
    work_root: Path,
    grant: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Repackage one validated development ZIP as a production-signed stream."""

    if catalog_client.channel != "production":
        raise CatalogPromotionError("catalog promotion requires the production channel")
    if grant is None:
        grant = catalog_client.promotion_grant(entry_id)
    existing = already_production_result(entry_id, grant)
    if existing is not None:
        return existing
    if grant.get("state") != "granted":
        raise CatalogPromotionError("promotion grant state is invalid")
    lease_id = _require_string(grant.get("leaseId"), "lease ID")
    if re.fullmatch(r"promotion_lease_v1_[A-Za-z0-9_-]{32}", lease_id) is None:
        raise CatalogPromotionError("promotion lease ID is invalid")
    artifact = grant.get("artifact")
    map_value = grant.get("map")
    if not isinstance(artifact, dict) or not isinstance(map_value, dict):
        raise CatalogPromotionError("promotion grant is incomplete")
    if artifact.get("format") != ZIP_STORED_FORMAT or artifact.get("deliveryTier") != "development":
        raise CatalogPromotionError("promotion grant is not a development ZIP")
    expected_bytes = artifact.get("bytes")
    expected_sha256 = artifact.get("sha256")
    if (
        type(expected_bytes) is not int
        or expected_bytes <= 0
        or not isinstance(expected_sha256, str)
        or len(expected_sha256) != 64
    ):
        raise CatalogPromotionError("promotion ZIP identity is invalid")
    r2_endpoint = os.environ.get("MAP_PLATFORM_S3_ENDPOINT_URL", "").rstrip("/")
    work_root.mkdir(parents=True, exist_ok=True)
    heartbeat = _PromotionLeaseHeartbeat(
        catalog_client=catalog_client,
        entry_id=entry_id,
        lease_id=lease_id,
        artifact=artifact,
    )
    with heartbeat, tempfile.TemporaryDirectory(
        prefix="catalog-promotion-",
        dir=work_root,
    ) as temporary:
        temporary_root = Path(temporary)
        archive_path = temporary_root / "source.zip"
        _download_exact_zip(
            _require_string(grant.get("downloadURL"), "download URL"),
            archive_path,
            expected_bytes=expected_bytes,
            expected_sha256=expected_sha256,
            catalog_origin=catalog_client.base_url,
            r2_endpoint=r2_endpoint,
            timeout_seconds=catalog_client.timeout_seconds,
        )
        heartbeat.check()
        zip_record = ArtifactRecord(
            format=ZIP_STORED_FORMAT,
            media_type=ZIP_MEDIA_TYPE,
            filename=_require_string(artifact.get("filename"), "ZIP filename"),
            object_key=_require_string(artifact.get("objectKey"), "ZIP object key"),
            bytes=expected_bytes,
            sha256=expected_sha256,
            manifest_receipt=artifact.get("manifestReceipt"),
        )
        validate_final_assembly_artifact(archive_path, (zip_record,))
        pack_root = temporary_root / "pack"
        pack_root.mkdir()
        manifest = _extract_validated_archive(archive_path, pack_root)
        heartbeat.check()

        map_id = _require_string(map_value.get("mapId"), "map ID")
        format_version = map_value.get("rendererFormatVersion")
        features = map_value.get("features")
        target = manifest.get("target")
        if (
            map_value.get("mapEntryId") != entry_id
            or map_value.get("originChannel") != "development"
            or manifest.get("mapId") != map_id
            or not isinstance(format_version, int)
            or not isinstance(target, dict)
            or target.get("renderer") != map_value.get("renderer")
            or target.get("formatVersion") != format_version
            or features not in ([], ["street-labels"], ["3d-buildings", "street-labels"])
        ):
            raise CatalogPromotionError("promotion map metadata does not match its ZIP")
        expected_features = {
            1: [],
            2: ["street-labels"],
            3: ["3d-buildings", "street-labels"],
        }.get(format_version)
        if expected_features is None or features != expected_features:
            raise CatalogPromotionError("promotion renderer features are unsupported")
        canonical_content_receipt = manifest_receipt(
            canonical_stream_manifest_bytes(manifest)
        )
        if (
            artifact.get("manifestReceipt") != canonical_content_receipt
            or map_value.get("contentReceipt") != canonical_content_receipt
        ):
            raise CatalogPromotionError(
                "promotion content receipt does not match its ZIP"
            )
        expected_entry_id = map_entry_id_for_descriptor(
            content_receipt=canonical_content_receipt,
            renderer=map_value.get("renderer"),
            renderer_format_version=format_version,
            features=features,
        )
        if entry_id != expected_entry_id:
            raise CatalogPromotionError(
                "promotion map entry identity does not match its ZIP"
            )
        source = manifest.get("source")
        attribution = map_value.get("attribution")
        if (
            not isinstance(source, dict)
            or not isinstance(attribution, dict)
            or source.get("provider") != attribution.get("provider")
            or source.get("license") != attribution.get("license")
            or manifest.get("bounds") != map_value.get("bounds")
        ):
            raise CatalogPromotionError("promotion attribution or bounds do not match")
        validate_renderer_artifacts(
            pack_root,
            map_id,
            manifest["files"],
            format_version,
        )
        heartbeat.check()
        stream_manifest = dict(manifest)
        stream_manifest["producer"] = {
            "buildSha256": producer_build_sha256,
            "imageDigest": producer_image_digest,
        }
        stream_path = temporary_root / f"{map_id}.bmap"
        stream = write_map_stream_artifact(
            pack_root,
            stream_manifest,
            signer,
            stream_path,
        )
        heartbeat.check()
        object_key = map_stream_object_key(
            map_id,
            stream.signed_manifest_receipt,
            stream.signature_key_id,
            signer.public_key_sha256,
            producer_build_sha256,
            producer_image_digest,
        )
        artifact_store.put(
            stream_path,
            object_key,
            sha256=stream.sha256,
            media_type=BIKE_MAP_STREAM_MEDIA_TYPE,
        )
        stream_record = ArtifactRecord(
            format=BIKE_MAP_STREAM_FORMAT,
            media_type=BIKE_MAP_STREAM_MEDIA_TYPE,
            filename=f"{map_id}.bmap",
            object_key=object_key,
            bytes=stream.bytes,
            sha256=stream.sha256,
            manifest_receipt=stream.manifest_receipt,
            signed_manifest_receipt=stream.signed_manifest_receipt,
            signature_key_id=stream.signature_key_id,
            signature_key_sha256=signer.public_key_sha256,
            producer_build_sha256=producer_build_sha256,
            producer_image_digest=producer_image_digest,
        )
        if not bool(getattr(artifact_store, "catalog_delivery_backed", False)):
            raise CatalogPromotionError(
                "promotion requires shared artifact storage"
            )
        if not artifact_store.verify(
            stream_record.object_key,
            sha256=stream_record.sha256,
            expected_bytes=stream_record.bytes,
        ):
            raise CatalogPromotionError(
                "promotion artifact is missing from shared delivery storage"
            )
        heartbeat.check()
        delivery = catalog_delivery_requirements("production")
        if not delivery:
            raise CatalogPromotionError("production catalog delivery identity is not configured")
        publication_id = f"promotion:production:{stream.sha256}"
        publication = {
            "publicationId": publication_id,
            "mapEntryId": entry_id,
            "legacyMapId": map_id,
            "contentReceipt": _require_string(
                map_value.get("contentReceipt"), "content receipt"
            ),
            "originChannel": "development",
            "canonicalName": _require_string(
                map_value.get("canonicalName"), "canonical name"
            ),
            "sourceRegionName": map_value.get("sourceRegionName"),
            "bounds": map_value.get("bounds"),
            "renderer": map_value.get("renderer"),
            "rendererFormatVersion": format_version,
            "features": features,
            "attribution": attribution,
            "generatedAt": map_value.get("generatedAt"),
            "deliveryState": "production",
            "artifacts": [
                {
                    "artifactId": artifact_id(stream_record),
                    "bucketSlot": "production",
                    "objectKey": object_key,
                    "format": stream_record.format,
                    "mediaType": stream_record.media_type,
                    "filename": stream_record.filename,
                    "bytes": stream_record.bytes,
                    "sha256": stream_record.sha256,
                    "manifestReceipt": stream_record.manifest_receipt,
                    "signedManifestReceipt": stream_record.signed_manifest_receipt,
                    "signatureKeyId": stream_record.signature_key_id,
                    "signatureKeySha256": stream_record.signature_key_sha256,
                    "producerBuildSha256": stream_record.producer_build_sha256,
                    "producerImageDigest": stream_record.producer_image_digest,
                    **delivery,
                    "deliveryTier": "production",
                }
            ],
        }
        heartbeat.stop()
        heartbeat.check()
        result = catalog_client.finalize_promotion(
            entry_id,
            publication,
            lease_id=lease_id,
        )
        if result.get("mapEntryId") != entry_id or result.get("state") != "finalized":
            raise CatalogPromotionError("promotion finalize returned invalid identity")
        return {
            "mapEntryId": entry_id,
            "publicationId": publication_id,
            "artifactId": artifact_id(stream_record),
            "objectKey": object_key,
            "bytes": stream.bytes,
            "sha256": stream.sha256,
            "state": "finalized",
        }
