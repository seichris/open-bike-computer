from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen

from .artifacts import BIKE_MAP_STREAM_FORMAT, ZIP_STORED_FORMAT, ArtifactRecord
from .generation_profiles import configured_deployment_channel
from .models import JobStatus, MapJob, utc_now_iso


CATALOG_STATES = frozenset({"pending", "finalized", "failed", "quarantined"})
CATALOG_ID_PATTERN = re.compile(r"[A-Za-z0-9._:-]{1,128}")
SERVICE_KEY_ID_PATTERN = re.compile(r"[A-Za-z0-9._-]{1,64}")
RETENTION_ARTIFACT_ID_PATTERN = re.compile(r"artifact_v1_[A-Za-z0-9_-]{43}")
RETENTION_LEASE_ID_PATTERN = re.compile(
    r"retention_lease_v1_[A-Za-z0-9_-]{32}"
)
RETENTION_OBJECT_KEY_PATTERN = re.compile(
    r"(?!/)(?!.*(?:^|/)\.\.(?:/|$))[A-Za-z0-9!_.*'()/-]{1,1024}"
)


class CatalogPublicationError(RuntimeError):
    code = "catalog_publication_failed"


def _base64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _canonical_sha256(value: Any) -> str:
    encoded = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def artifact_id(artifact: ArtifactRecord) -> str:
    return f"artifact_v1_{_base64url(bytes.fromhex(artifact.sha256))}"


def renderer_features(job: MapJob) -> tuple[str, int, list[str]]:
    target = job.request.get("target")
    if not isinstance(target, dict):
        raise CatalogPublicationError("ready map is missing renderer target metadata")
    renderer = target.get("renderer")
    format_version = target.get("rendererFormatVersion")
    if (
        not isinstance(renderer, str)
        or not re.fullmatch(r"[a-z0-9._-]{1,64}", renderer)
        or isinstance(format_version, bool)
        or not isinstance(format_version, int)
    ):
        raise CatalogPublicationError("ready map renderer target metadata is invalid")
    features_by_format = {
        1: [],
        2: ["street-labels"],
        3: ["3d-buildings", "street-labels"],
        4: ["street-labels", "3d-buildings", "map-pois"],
    }
    try:
        features = features_by_format[format_version]
    except KeyError as exc:
        raise CatalogPublicationError(
            "ready map renderer format is not catalogable"
        ) from exc
    return renderer, format_version, features


def catalog_content_receipt(job: MapJob) -> str:
    zip_receipts = {
        artifact.manifest_receipt
        for artifact in job.artifacts
        if artifact.format == ZIP_STORED_FORMAT
        and artifact.manifest_receipt is not None
    }
    if len(zip_receipts) == 1:
        # New ZIP records carry the canonical unsigned payload-manifest
        # receipt. Prefer it so a producer/signing-envelope change does not
        # split one exact final payload into different catalog map entries.
        return next(iter(zip_receipts))
    receipts = {
        artifact.manifest_receipt
        for artifact in job.artifacts
        if artifact.manifest_receipt is not None
    }
    if len(receipts) == 1:
        return next(iter(receipts))
    zip_hashes = {
        artifact.sha256
        for artifact in job.artifacts
        if artifact.format == ZIP_STORED_FORMAT
    }
    if len(zip_hashes) == 1:
        return next(iter(zip_hashes))
    raise CatalogPublicationError("ready map has no unambiguous catalog content receipt")


def map_entry_id_for_descriptor(
    *,
    content_receipt: str,
    renderer: str,
    renderer_format_version: int,
    features: list[str],
) -> str:
    if (
        not isinstance(content_receipt, str)
        or re.fullmatch(r"[0-9a-f]{64}", content_receipt) is None
    ):
        raise CatalogPublicationError("catalog content receipt is invalid")
    if (
        not isinstance(renderer, str)
        or re.fullmatch(r"[a-z0-9._-]{1,64}", renderer) is None
    ):
        raise CatalogPublicationError("catalog renderer is invalid")
    if (
        isinstance(renderer_format_version, bool)
        or not isinstance(renderer_format_version, int)
        or renderer_format_version <= 0
    ):
        raise CatalogPublicationError("catalog renderer format is invalid")
    if (
        not isinstance(features, list)
        or any(
            not isinstance(feature, str)
            or re.fullmatch(r"[a-z0-9._-]{1,64}", feature) is None
            for feature in features
        )
        or len(set(features)) != len(features)
    ):
        raise CatalogPublicationError("catalog renderer features are invalid")
    descriptor = {
        "schemaVersion": 1,
        "contentReceipt": content_receipt,
        "renderer": renderer,
        "rendererFormatVersion": renderer_format_version,
        "features": features,
    }
    digest = bytes.fromhex(_canonical_sha256(descriptor))
    return f"map_v1_{_base64url(digest)}"


def map_entry_id(job: MapJob) -> str:
    renderer, format_version, features = renderer_features(job)
    return map_entry_id_for_descriptor(
        content_receipt=catalog_content_receipt(job),
        renderer=renderer,
        renderer_format_version=format_version,
        features=features,
    )


def publication_id(job: MapJob, channel: str) -> str:
    if job.catalog_publication_id:
        return job.catalog_publication_id
    digest = hashlib.sha256(
        f"catalog-publication-v1\n{channel}\n{job.job_id}".encode("utf-8")
    ).hexdigest()
    return f"publication:{channel}:{digest}"


def catalog_delivery_requirements(channel: str) -> dict[str, Any]:
    values: dict[str, Any] = {}
    firmware: dict[str, Any] = {
        "requiredFirmwareVersion": os.environ.get(
            "MAP_PLATFORM_CATALOG_REQUIRED_FIRMWARE_VERSION"
        ),
        "requiredFirmwareBuild": os.environ.get(
            "MAP_PLATFORM_CATALOG_REQUIRED_FIRMWARE_BUILD"
        ),
        "requiredFirmwareGitSha": os.environ.get(
            "MAP_PLATFORM_CATALOG_REQUIRED_FIRMWARE_GIT_SHA"
        ),
    }
    if any(firmware.values()):
        if not all(firmware.values()):
            raise CatalogPublicationError("catalog firmware delivery identity is incomplete")
        try:
            firmware["requiredFirmwareBuild"] = int(
                firmware["requiredFirmwareBuild"]
            )
        except (TypeError, ValueError) as exc:
            raise CatalogPublicationError(
                "catalog firmware delivery build is invalid"
            ) from exc
        if firmware["requiredFirmwareBuild"] <= 0:
            raise CatalogPublicationError("catalog firmware delivery build is invalid")
        values.update(firmware)
    # App build identity is request audit context, not immutable map
    # compatibility. Reader compatibility is represented by the discrete
    # readerRequirements contract emitted with each stream artifact.
    del channel
    return values


def publication_payload(job: MapJob, channel: str) -> dict[str, Any]:
    if job.status != JobStatus.READY or not job.map_id or not job.artifacts:
        raise CatalogPublicationError("only verified READY map artifacts can be published")
    renderer, format_version, features = renderer_features(job)
    content_receipt = catalog_content_receipt(job)
    entry_id = map_entry_id(job)
    delivery_requirements = catalog_delivery_requirements(channel)
    artifact_values: list[dict[str, Any]] = []
    for artifact in job.artifacts:
        value = {
            "artifactId": artifact_id(artifact),
            "bucketSlot": channel,
            "objectKey": artifact.object_key,
            "format": artifact.format,
            "mediaType": artifact.media_type,
            "filename": artifact.filename,
            "bytes": artifact.bytes,
            "sha256": artifact.sha256,
            "deliveryTier": channel,
        }
        optional = {
            "manifestReceipt": artifact.manifest_receipt,
            "signedManifestReceipt": artifact.signed_manifest_receipt,
            "signatureKeyId": artifact.signature_key_id,
            "signatureKeySha256": artifact.signature_key_sha256,
            "producerBuildSha256": artifact.producer_build_sha256,
            "producerImageDigest": artifact.producer_image_digest,
        }
        value.update({key: item for key, item in optional.items() if item is not None})
        if artifact.format == BIKE_MAP_STREAM_FORMAT:
            value["readerRequirements"] = {
                "schemaVersion": 1,
                "streamFormat": BIKE_MAP_STREAM_FORMAT,
                "manifestSchemaVersion": 1,
                "renderer": renderer,
                "rendererFormatVersion": format_version,
                "requiredFeatures": features,
            }
            value.update(delivery_requirements)
        artifact_values.append(value)
    return {
        "publicationId": publication_id(job, channel),
        "mapEntryId": entry_id,
        "legacyMapId": job.map_id,
        "contentReceipt": content_receipt,
        "originChannel": channel,
        "canonicalName": job.artifact_display_name,
        "sourceRegionName": job.source_region.name,
        "bounds": job.geometry.bounds.to_list(),
        "renderer": renderer,
        "rendererFormatVersion": format_version,
        "features": features,
        "attribution": {
            "provider": job.source_region.provider,
            "license": job.source_region.license,
        },
        "generatedAt": job.finished_at,
        "deliveryState": channel,
        "artifacts": sorted(
            artifact_values,
            key=lambda value: (value["format"], value["artifactId"]),
        ),
    }


@dataclass(frozen=True)
class CatalogClient:
    base_url: str
    channel: str
    service_key_id: str
    service_secret: str
    timeout_seconds: float = 10.0

    def __post_init__(self) -> None:
        parsed = urlparse(self.base_url)
        if parsed.scheme != "https" or not parsed.netloc or parsed.path not in {"", "/"}:
            raise ValueError("MAP_PLATFORM_CATALOG_URL must be an HTTPS origin")
        if self.channel not in {"development", "production"}:
            raise ValueError("catalog channel must be development or production")
        if SERVICE_KEY_ID_PATTERN.fullmatch(self.service_key_id) is None:
            raise ValueError("catalog service key ID is invalid")
        if len(self.service_secret.encode("utf-8")) < 32:
            raise ValueError("catalog service secret must contain at least 32 bytes")
        if not 1 <= self.timeout_seconds <= 60:
            raise ValueError("catalog request timeout is invalid")

    @classmethod
    def from_environment(cls) -> CatalogClient | None:
        base_url = os.environ.get("MAP_PLATFORM_CATALOG_URL", "").strip().rstrip("/")
        if not base_url:
            return None
        channel = os.environ.get(
            "MAP_PLATFORM_CATALOG_CHANNEL",
            configured_deployment_channel(),
        ).strip().lower()
        return cls(
            base_url=base_url,
            channel=channel,
            service_key_id=os.environ.get(
                "MAP_PLATFORM_CATALOG_SERVICE_KEY_ID",
                "",
            ).strip(),
            service_secret=os.environ.get(
                "MAP_PLATFORM_CATALOG_SERVICE_SECRET",
                "",
            ),
            timeout_seconds=float(
                os.environ.get("MAP_PLATFORM_CATALOG_TIMEOUT_SECONDS", "10")
            ),
        )

    def finalize(self, job: MapJob) -> dict[str, Any]:
        payload = publication_payload(job, self.channel)
        result = self._request(
            "/v1/internal/publications/finalize",
            payload,
            idempotency_key=payload["publicationId"],
        )
        if (
            result.get("publicationId") != payload["publicationId"]
            or result.get("mapEntryId") != payload["mapEntryId"]
            or result.get("state") != "finalized"
        ):
            raise CatalogPublicationError("catalog finalize returned invalid identity")
        return result

    def attach_library(
        self,
        *,
        publication_id_value: str,
        library_credential: str,
        alias: str | None,
    ) -> dict[str, Any]:
        if CATALOG_ID_PATTERN.fullmatch(publication_id_value) is None:
            raise ValueError("catalog publication ID is invalid")
        payload: dict[str, Any] = {"libraryCredential": library_credential}
        if alias is not None:
            payload["alias"] = alias
        return self._request(
            "/v1/internal/publications/"
            f"{quote(publication_id_value, safe='')}/attach-library",
            payload,
            idempotency_key=(
                f"attach:{publication_id_value}:"
                f"{hashlib.sha256(library_credential.encode('utf-8')).hexdigest()}"
            ),
        )

    def promotion_grant(self, entry_id: str) -> dict[str, Any]:
        return self._request(
            f"/v1/internal/promotions/{quote(entry_id, safe='')}/grant",
            {},
            idempotency_key=f"promotion-grant:{entry_id}:{int(time.time() // 600)}",
        )

    def finalize_promotion(
        self,
        entry_id: str,
        payload: dict[str, Any],
        *,
        lease_id: str,
    ) -> dict[str, Any]:
        publication_id_value = payload.get("publicationId")
        if not isinstance(publication_id_value, str):
            raise ValueError("promotion publication ID is invalid")
        if re.fullmatch(r"promotion_lease_v1_[A-Za-z0-9_-]{32}", lease_id) is None:
            raise ValueError("promotion lease ID is invalid")
        return self._request(
            f"/v1/internal/promotions/{quote(entry_id, safe='')}/finalize",
            {"leaseId": lease_id, "publication": payload},
            idempotency_key=publication_id_value,
        )

    def renew_promotion_lease(
        self,
        entry_id: str,
        *,
        lease_id: str,
        artifact: dict[str, Any],
    ) -> dict[str, Any]:
        if re.fullmatch(r"promotion_lease_v1_[A-Za-z0-9_-]{32}", lease_id) is None:
            raise ValueError("promotion lease ID is invalid")
        payload = {
            "artifactId": artifact.get("artifactId"),
            "objectKey": artifact.get("objectKey"),
            "bytes": artifact.get("bytes"),
            "sha256": artifact.get("sha256"),
        }
        return self._request(
            f"/v1/internal/promotions/{quote(entry_id, safe='')}"
            f"/leases/{quote(lease_id, safe='')}/renew",
            payload,
            idempotency_key=(
                f"promotion-renew:{lease_id}:{int(time.time() // 300)}"
            ),
        )

    def retention_authorizations(
        self,
        *,
        maximum_artifacts: int,
    ) -> list[dict[str, Any]]:
        if not 1 <= maximum_artifacts <= 10:
            raise ValueError("catalog retention limit is invalid")
        result = self._request(
            "/v1/internal/retention/authorizations",
            {"limit": maximum_artifacts},
            idempotency_key=(
                f"retention-authorize:{self.channel}:{int(time.time() // 600)}"
            ),
        )
        artifacts = result.get("artifacts")
        if not isinstance(artifacts, list) or len(artifacts) > maximum_artifacts:
            raise CatalogPublicationError(
                "catalog retention authorization response is invalid"
            )
        if any(not isinstance(value, dict) for value in artifacts):
            raise CatalogPublicationError(
                "catalog retention authorization response is invalid"
            )
        return artifacts

    def claim_retention_deletion(
        self,
        authorization: dict[str, Any],
    ) -> dict[str, Any]:
        artifact_id_value = authorization.get("artifactId")
        if (
            not isinstance(artifact_id_value, str)
            or RETENTION_ARTIFACT_ID_PATTERN.fullmatch(artifact_id_value) is None
        ):
            raise CatalogPublicationError("catalog retention artifact ID is invalid")
        payload = {
            "bucketSlot": authorization["bucketSlot"],
            "objectKey": authorization["objectKey"],
            "bytes": authorization["bytes"],
            "sha256": authorization["sha256"],
        }
        result = self._request(
            "/v1/internal/retention/artifacts/"
            f"{quote(artifact_id_value, safe='')}/claim",
            payload,
            idempotency_key=f"retention-claim:{artifact_id_value}",
        )
        if result.get("artifactId") != artifact_id_value:
            raise CatalogPublicationError(
                "catalog retention claim response is invalid"
            )
        return result

    def confirm_retention_deletion(
        self,
        authorization: dict[str, Any],
    ) -> dict[str, Any]:
        artifact_id_value = authorization.get("artifactId")
        if (
            not isinstance(artifact_id_value, str)
            or RETENTION_ARTIFACT_ID_PATTERN.fullmatch(artifact_id_value) is None
        ):
            raise CatalogPublicationError("catalog retention artifact ID is invalid")
        payload = {
            "bucketSlot": authorization["bucketSlot"],
            "objectKey": authorization["objectKey"],
            "bytes": authorization["bytes"],
            "sha256": authorization["sha256"],
            "leaseId": authorization["leaseId"],
            "confirmedAbsent": True,
        }
        result = self._request(
            "/v1/internal/retention/artifacts/"
            f"{quote(artifact_id_value, safe='')}/deleted",
            payload,
            idempotency_key=f"retention-deleted:{artifact_id_value}",
        )
        if (
            result.get("artifactId") != artifact_id_value
            or result.get("state") != "deleted"
        ):
            raise CatalogPublicationError(
                "catalog retention confirmation response is invalid"
            )
        return result

    def _request(
        self,
        path: str,
        payload: dict[str, Any],
        *,
        idempotency_key: str,
    ) -> dict[str, Any]:
        body = json.dumps(
            payload,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        ).encode("utf-8")
        timestamp = str(int(time.time()))
        body_sha256 = hashlib.sha256(body).hexdigest()
        canonical = "\n".join(
            ("POST", path, timestamp, idempotency_key, body_sha256)
        ).encode("utf-8")
        signature = hmac.new(
            self.service_secret.encode("utf-8"),
            canonical,
            hashlib.sha256,
        ).hexdigest()
        request = Request(
            self.base_url + path,
            data=body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "BicinoMapPlatform/1.0",
                "X-Catalog-Key-Id": self.service_key_id,
                "X-Catalog-Timestamp": timestamp,
                "X-Catalog-Idempotency-Key": idempotency_key,
                "X-Catalog-Signature": signature,
            },
        )
        try:
            with urlopen(request, timeout=self.timeout_seconds) as response:
                raw = response.read(256 * 1024 + 1)
                if len(raw) > 256 * 1024:
                    raise CatalogPublicationError("catalog response is too large")
        except HTTPError as exc:
            try:
                detail = json.loads(exc.read(4096)).get("error", "catalog request failed")
            except Exception:
                detail = "catalog request failed"
            raise CatalogPublicationError(
                f"catalog request failed with HTTP {exc.code}: {detail}"
            ) from exc
        except (URLError, TimeoutError, OSError) as exc:
            raise CatalogPublicationError("catalog request failed") from exc
        try:
            result = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise CatalogPublicationError("catalog response is invalid") from exc
        if not isinstance(result, dict):
            raise CatalogPublicationError("catalog response is invalid")
        return result


def catalog_status_from_environment() -> dict[str, Any]:
    client = CatalogClient.from_environment()
    return {
        "enabled": client is not None,
        "channel": client.channel if client is not None else None,
        "host": urlparse(client.base_url).hostname if client is not None else None,
    }


def _verify_catalog_artifacts(job: MapJob, artifact_store) -> None:
    if not bool(getattr(artifact_store, "catalog_delivery_backed", False)):
        raise CatalogPublicationError(
            "catalog publication requires shared artifact storage"
        )
    if not job.artifacts:
        raise CatalogPublicationError("ready map has no recorded artifacts")
    for artifact in job.artifacts:
        if not artifact_store.verify(
            artifact.object_key,
            sha256=artifact.sha256,
            expected_bytes=artifact.bytes,
        ):
            raise CatalogPublicationError(
                "recorded artifact is missing from shared delivery storage"
            )


def backfill_ready_job_artifacts(store, artifact_store, job_id: str) -> dict[str, int]:
    """Explicitly import one filesystem-era READY job into a configured mirror."""
    job = store.get(job_id)
    if job.status != JobStatus.READY:
        raise CatalogPublicationError("only READY jobs can be backfilled")
    backfill = getattr(artifact_store, "backfill_from_primary", None)
    if not callable(backfill) or not bool(
        getattr(artifact_store, "catalog_delivery_backed", False)
    ):
        raise CatalogPublicationError(
            "catalog backfill requires mirror artifact storage"
        )
    copied = 0
    for artifact in job.artifacts:
        copied += int(
            backfill(
                artifact.object_key,
                sha256=artifact.sha256,
                expected_bytes=artifact.bytes,
                media_type=artifact.media_type,
            )
        )
    _verify_catalog_artifacts(job, artifact_store)
    return {"artifacts": len(job.artifacts), "copied": copied}


def publish_ready_job(
    store,
    client: CatalogClient | None,
    job_id: str,
    *,
    artifact_store=None,
) -> MapJob:
    if client is None:
        return store.get(job_id)
    job = store.get(job_id)
    if job.status != JobStatus.READY:
        return job
    if job.catalog_publication_state == "finalized":
        return job
    job.catalog_publication_state = "pending"
    job.catalog_publication_error = None
    job.updated_at = utc_now_iso()
    store.save(job)
    try:
        job.catalog_publication_id = publication_id(job, client.channel)
        job.catalog_map_entry_id = map_entry_id(job)
        _verify_catalog_artifacts(job, artifact_store)
        result = client.finalize(job)
    except Exception as exc:
        current = store.get(job_id)
        current.catalog_publication_state = "failed"
        current.catalog_publication_error = (
            f"{type(exc).__name__}: catalog publication failed"
        )
        current.catalog_publication_attempts += 1
        current.catalog_publication_updated_at = utc_now_iso()
        current.updated_at = current.catalog_publication_updated_at
        store.save(current)
        return current
    current = store.get(job_id)
    current.catalog_publication_id = str(result["publicationId"])
    current.catalog_map_entry_id = str(result["mapEntryId"])
    current.catalog_publication_state = "finalized"
    current.catalog_publication_error = None
    current.catalog_publication_attempts += 1
    current.catalog_publication_updated_at = utc_now_iso()
    current.updated_at = current.catalog_publication_updated_at
    store.save(current)
    return current


def retry_ready_publications(
    store,
    client: CatalogClient | None,
    *,
    artifact_store=None,
    maximum_jobs: int = 10,
) -> dict[str, int]:
    if maximum_jobs <= 0:
        raise ValueError("catalog publication retry limit must be positive")
    if client is None:
        return {"attempted": 0, "finalized": 0, "failed": 0}
    pending = sorted(
        (
            job
            for job in store.list()
            if job.status == JobStatus.READY
            and job.catalog_publication_state != "finalized"
        ),
        key=lambda value: (
            value.catalog_publication_updated_at
            or value.finished_at
            or value.created_at
        ),
    )
    candidates: list[MapJob] = []
    for job in pending:
        try:
            map_entry_id(job)
        except CatalogPublicationError:
            # READY jobs created before renderer targets became mandatory are
            # immutable but not safely catalogable. Leave their local download
            # intact without letting them consume every retry slot.
            continue
        candidates.append(job)
        if len(candidates) == maximum_jobs:
            break
    finalized = 0
    for job in candidates:
        result = publish_ready_job(
            store,
            client,
            job.job_id,
            artifact_store=artifact_store,
        )
        if result.catalog_publication_state == "finalized":
            finalized += 1
    return {
        "attempted": len(candidates),
        "finalized": finalized,
        "failed": len(candidates) - finalized,
    }


def _validated_retention_authorization(
    value: dict[str, Any],
    *,
    channel: str,
    claimed: bool = False,
) -> dict[str, Any]:
    expected_fields = {
        "artifactId",
        "bucketSlot",
        "objectKey",
        "bytes",
        "sha256",
        "authorizationExpiresAt",
    }
    if claimed:
        expected_fields.add("leaseId")
    if set(value) != expected_fields:
        raise CatalogPublicationError("catalog retention authorization is invalid")
    if (
        not isinstance(value["artifactId"], str)
        or RETENTION_ARTIFACT_ID_PATTERN.fullmatch(value["artifactId"]) is None
        or value["bucketSlot"] != channel
        or not isinstance(value["objectKey"], str)
        or RETENTION_OBJECT_KEY_PATTERN.fullmatch(value["objectKey"]) is None
        or type(value["bytes"]) is not int
        or not 1 <= value["bytes"] <= (1 << 63) - 1
        or not isinstance(value["sha256"], str)
        or re.fullmatch(r"[0-9a-f]{64}", value["sha256"]) is None
        or not isinstance(value["authorizationExpiresAt"], str)
        or (
            claimed
            and (
                not isinstance(value["leaseId"], str)
                or RETENTION_LEASE_ID_PATTERN.fullmatch(value["leaseId"])
                is None
            )
        )
    ):
        raise CatalogPublicationError("catalog retention authorization is invalid")
    try:
        expires_at = datetime.fromisoformat(
            value["authorizationExpiresAt"].replace("Z", "+00:00")
        )
    except ValueError as exc:
        raise CatalogPublicationError(
            "catalog retention authorization is invalid"
        ) from exc
    if expires_at.tzinfo is None or expires_at <= datetime.now(timezone.utc):
        raise CatalogPublicationError("catalog retention authorization has expired")
    return value


def delete_catalog_retention_artifacts(
    store,
    client: CatalogClient | None,
    artifact_store,
    *,
    maximum_artifacts: int = 100,
) -> dict[str, int]:
    if not 1 <= maximum_artifacts <= 10:
        raise ValueError("catalog retention limit is invalid")
    if client is None:
        return {"authorized": 0, "deleted": 0, "deferred": 0}
    if not bool(getattr(artifact_store, "catalog_delivery_backed", False)):
        raise CatalogPublicationError(
            "catalog retention requires shared artifact storage"
        )
    authorizations = [
        _validated_retention_authorization(value, channel=client.channel)
        for value in client.retention_authorizations(
            maximum_artifacts=maximum_artifacts
        )
    ]
    deleted = 0
    deferred = 0
    for authorization in authorizations:
        referencing_jobs = []
        for job in store.list():
            references = [
                artifact
                for artifact in job.artifacts
                if artifact.object_key == authorization["objectKey"]
            ]
            if not references:
                continue
            if any(
                artifact.sha256 != authorization["sha256"]
                or artifact.bytes != authorization["bytes"]
                for artifact in references
            ):
                raise CatalogPublicationError(
                    "catalog retention identity conflicts with a local job"
                )
            referencing_jobs.append(job)
        if any(
            job.status != JobStatus.EXPIRED
            or job.catalog_publication_state != "finalized"
            for job in referencing_jobs
        ):
            deferred += 1
            continue
        claim = _validated_retention_authorization(
            client.claim_retention_deletion(authorization),
            channel=client.channel,
            claimed=True,
        )
        artifact_store.delete(claim["objectKey"])
        if not artifact_store.absent(claim["objectKey"]):
            raise CatalogPublicationError(
                "catalog-retained artifact remains after deletion"
            )
        client.confirm_retention_deletion(claim)
        deleted += 1
    return {
        "authorized": len(authorizations),
        "deleted": deleted,
        "deferred": deferred,
    }
