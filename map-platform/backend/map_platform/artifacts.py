from __future__ import annotations

import base64
import hashlib
import os
import re
import uuid
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import quote


BIKE_MAP_STREAM_FORMAT = "bike-map-stream-v1"
BIKE_MAP_STREAM_MEDIA_TYPE = "application/vnd.openbikecomputer.map-stream"
ZIP_STORED_FORMAT = "zip-stored-v1"
ZIP_MEDIA_TYPE = "application/zip"
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
OCI_DIGEST_PATTERN = re.compile(r"sha256:([0-9a-f]{64})")
MAXIMUM_ARTIFACT_BYTES = (1 << 63) - 1
MAXIMUM_STREAM_ARTIFACT_BYTES = (
    32  # fixed header
    + 2 * 1024 * 1024  # canonical manifest
    + 4 + 64 + 64  # signature prefix, maximum key ID, and raw signature
    + 512 * 1024 * 1024  # payload
)


class ArtifactStoreError(RuntimeError):
    code = "artifact_storage_failed"


@dataclass(frozen=True)
class ArtifactRecord:
    format: str
    media_type: str
    filename: str
    object_key: str
    bytes: int
    sha256: str
    manifest_receipt: str | None = None
    signed_manifest_receipt: str | None = None
    signature_key_id: str | None = None
    signature_key_sha256: str | None = None
    producer_build_sha256: str | None = None
    producer_image_digest: str | None = None

    def __post_init__(self) -> None:
        _validate_object_key(self.object_key)
        if not self.format or not self.media_type or not self.filename:
            raise ValueError("artifact metadata contains an empty identifier")
        if not re.fullmatch(r"[a-z0-9._-]{1,64}", self.format):
            raise ValueError("artifact format identifier is invalid")
        if not re.fullmatch(r"[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+", self.media_type):
            raise ValueError("artifact media type is invalid")
        if (
            len(self.filename.encode("ascii", errors="ignore")) != len(self.filename)
            or len(self.filename) > 128
            or PurePosixPath(self.filename).name != self.filename
            or any(ord(character) < 32 or ord(character) == 127 for character in self.filename)
        ):
            raise ValueError("artifact filename is invalid")
        if type(self.bytes) is not int or not 1 <= self.bytes <= MAXIMUM_ARTIFACT_BYTES:
            raise ValueError("artifact byte count is outside the client range")
        if not SHA256_PATTERN.fullmatch(self.sha256):
            raise ValueError("artifact SHA-256 is invalid")
        for receipt in (self.manifest_receipt, self.signed_manifest_receipt):
            if receipt is not None and not SHA256_PATTERN.fullmatch(receipt):
                raise ValueError("artifact receipt is invalid")
        if self.signature_key_id is not None and not re.fullmatch(
            r"[A-Za-z0-9._-]{1,64}", self.signature_key_id
        ):
            raise ValueError("artifact signature key ID is invalid")
        if self.signature_key_sha256 is not None and not SHA256_PATTERN.fullmatch(
            self.signature_key_sha256
        ):
            raise ValueError("artifact signature key fingerprint is invalid")
        if self.producer_build_sha256 is not None and not SHA256_PATTERN.fullmatch(
            self.producer_build_sha256
        ):
            raise ValueError("artifact producer build SHA-256 is invalid")
        if self.producer_image_digest is not None and not OCI_DIGEST_PATTERN.fullmatch(
            self.producer_image_digest
        ):
            raise ValueError("artifact producer image digest is invalid")
        if self.format == BIKE_MAP_STREAM_FORMAT:
            if self.bytes > MAXIMUM_STREAM_ARTIFACT_BYTES:
                raise ValueError("map stream artifact byte count exceeds the format limit")
            if not self.filename.endswith(".bmap"):
                raise ValueError("map stream artifact filename is invalid")
            map_id = self.filename.removesuffix(".bmap")
            _validate_map_id(map_id)
            if not (
                self.manifest_receipt
                and self.signed_manifest_receipt
                and self.signature_key_id
            ):
                raise ValueError("map stream artifact is missing signed identity metadata")
            producer_identity_fields = (
                self.signature_key_sha256,
                self.producer_build_sha256,
                self.producer_image_digest,
            )
            if any(producer_identity_fields) and not all(producer_identity_fields):
                raise ValueError("map stream artifact producer identity is incomplete")
            image_digest_match = (
                OCI_DIGEST_PATTERN.fullmatch(self.producer_image_digest)
                if self.producer_image_digest
                else None
            )
            expected_key = (
                f"maps/{map_id}/{BIKE_MAP_STREAM_FORMAT}/{self.signature_key_id}/"
                + (
                    f"{self.signature_key_sha256}/"
                    f"{self.producer_build_sha256}/"
                    f"{image_digest_match.group(1)}/"
                    if image_digest_match
                    else ""
                )
                + f"{self.signed_manifest_receipt}.bmap"
            )
            if self.object_key != expected_key:
                raise ValueError("map stream artifact object key does not match its identity")

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "format": self.format,
            "mediaType": self.media_type,
            "filename": self.filename,
            "objectKey": self.object_key,
            "bytes": self.bytes,
            "sha256": self.sha256,
        }
        if self.manifest_receipt is not None:
            result["manifestReceipt"] = self.manifest_receipt
        if self.signed_manifest_receipt is not None:
            result["signedManifestReceipt"] = self.signed_manifest_receipt
        if self.signature_key_id is not None:
            result["signatureKeyId"] = self.signature_key_id
        if self.signature_key_sha256 is not None:
            result["signatureKeySha256"] = self.signature_key_sha256
        if self.producer_build_sha256 is not None:
            result["producerBuildSha256"] = self.producer_build_sha256
        if self.producer_image_digest is not None:
            result["producerImageDigest"] = self.producer_image_digest
        return result

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> ArtifactRecord:
        def optional_string(key: str) -> str | None:
            field = value.get(key)
            if field is not None and not isinstance(field, str):
                raise ValueError(f"artifact field {key} must be a string")
            return field

        required_fields = {
            "format",
            "mediaType",
            "filename",
            "objectKey",
            "bytes",
            "sha256",
        }
        optional_fields = {
            "manifestReceipt",
            "signedManifestReceipt",
            "signatureKeyId",
            "signatureKeySha256",
            "producerBuildSha256",
            "producerImageDigest",
        }
        if set(value) - required_fields - optional_fields or not required_fields.issubset(value):
            raise ValueError("artifact metadata has invalid fields")
        if any(not isinstance(value[field], str) for field in required_fields - {"bytes"}):
            raise ValueError("artifact metadata has invalid field types")
        if type(value["bytes"]) is not int:
            raise ValueError("artifact byte count must be an integer")

        return cls(
            format=value["format"],
            media_type=value["mediaType"],
            filename=value["filename"],
            object_key=value["objectKey"],
            bytes=value["bytes"],
            sha256=value["sha256"],
            manifest_receipt=optional_string("manifestReceipt"),
            signed_manifest_receipt=optional_string("signedManifestReceipt"),
            signature_key_id=optional_string("signatureKeyId"),
            signature_key_sha256=optional_string("signatureKeySha256"),
            producer_build_sha256=optional_string(
                "producerBuildSha256"
            ),
            producer_image_digest=optional_string("producerImageDigest"),
        )


class FileSystemArtifactStore:
    def __init__(self, root: str | Path):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)

    def put(
        self,
        source: str | Path,
        object_key: str,
        *,
        sha256: str,
        media_type: str,
    ) -> None:
        del media_type
        if not SHA256_PATTERN.fullmatch(sha256):
            raise ValueError("artifact SHA-256 is invalid")
        try:
            source_path = Path(source)
            source_bytes = source_path.stat().st_size
            destination = self._path(object_key)
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                _verify_file(destination, sha256, source_bytes)
                return

            temporary = destination.parent / f".{destination.name}.{uuid.uuid4().hex}.tmp"
            digest = hashlib.sha256()
            copied = 0
            with source_path.open("rb") as input_file, temporary.open("xb") as output_file:
                for chunk in iter(lambda: input_file.read(1024 * 1024), b""):
                    output_file.write(chunk)
                    digest.update(chunk)
                    copied += len(chunk)
                output_file.flush()
                os.fsync(output_file.fileno())
            if digest.hexdigest() != sha256 or copied != source_bytes:
                raise ArtifactStoreError("artifact source changed while publishing")
            try:
                os.link(temporary, destination)
            except FileExistsError:
                _verify_file(destination, sha256, copied)
            _fsync_directory(destination.parent)
        except ArtifactStoreError:
            raise
        except OSError as exc:
            raise ArtifactStoreError(f"failed to publish filesystem artifact: {exc}") from exc
        finally:
            if "temporary" in locals():
                try:
                    temporary.unlink(missing_ok=True)
                except OSError:
                    pass

    def local_path(self, object_key: str) -> Path | None:
        path = self._path(object_key)
        return path if path.is_file() else None

    def create_download_url(
        self,
        object_key: str,
        *,
        expires_in_seconds: int,
        filename: str,
        media_type: str,
    ) -> str | None:
        del object_key, expires_in_seconds, filename, media_type
        return None

    def delete(self, object_key: str) -> bool:
        try:
            path = self._path(object_key)
            if not path.exists():
                return False
            path.unlink()
            parent = path.parent
            while parent != self.root:
                try:
                    parent.rmdir()
                except OSError:
                    break
                parent = parent.parent
            return True
        except OSError as exc:
            raise ArtifactStoreError(f"failed to delete filesystem artifact: {exc}") from exc

    def _path(self, object_key: str) -> Path:
        _validate_object_key(object_key)
        return self.root.joinpath(*PurePosixPath(object_key).parts)


class S3ArtifactStore:
    def __init__(self, client, bucket: str, *, prefix: str = "map-artifacts"):
        if not bucket:
            raise ValueError("S3 artifact bucket must not be empty")
        self.client = client
        self.bucket = bucket
        self.prefix = prefix.strip("/")
        if self.prefix:
            _validate_object_key(self.prefix)

    def put(
        self,
        source: str | Path,
        object_key: str,
        *,
        sha256: str,
        media_type: str,
    ) -> None:
        _validate_object_key(object_key)
        if not SHA256_PATTERN.fullmatch(sha256):
            raise ValueError("artifact SHA-256 is invalid")
        source_path = Path(source)
        try:
            source_bytes = source_path.stat().st_size
            _verify_file(source_path, sha256, source_bytes)
        except ArtifactStoreError:
            raise
        except OSError as exc:
            raise ArtifactStoreError(f"failed to read artifact source: {exc}") from exc
        key = self._key(object_key)
        checksum = base64.b64encode(bytes.fromhex(sha256)).decode("ascii")
        for attempt in range(3):
            existing = self._head(key)
            if existing is not None:
                self._verify_head(existing, sha256, source_bytes)
                return
            try:
                with source_path.open("rb") as body:
                    self.client.put_object(
                        Bucket=self.bucket,
                        Key=key,
                        Body=body,
                        ContentLength=source_bytes,
                        ContentType=media_type,
                        ChecksumSHA256=checksum,
                        Metadata={"sha256": sha256},
                        IfNoneMatch="*",
                    )
                break
            except Exception as exc:
                status = _error_status(exc)
                if status == 412:
                    break
                if status == 409 and attempt < 2:
                    continue
                raise ArtifactStoreError(f"failed to publish artifact object: {exc}") from exc
        head = self._head(key)
        if head is None:
            raise ArtifactStoreError("artifact object is missing after publish")
        self._verify_head(head, sha256, source_bytes)

    def local_path(self, object_key: str) -> Path | None:
        _validate_object_key(object_key)
        return None

    def create_download_url(
        self,
        object_key: str,
        *,
        expires_in_seconds: int,
        filename: str,
        media_type: str,
    ) -> str | None:
        _validate_object_key(object_key)
        disposition = f"attachment; filename*=UTF-8''{quote(filename, safe='')}"
        try:
            return self.client.generate_presigned_url(
                "get_object",
                Params={
                    "Bucket": self.bucket,
                    "Key": self._key(object_key),
                    "ResponseContentType": media_type,
                    "ResponseContentDisposition": disposition,
                },
                ExpiresIn=expires_in_seconds,
                HttpMethod="GET",
            )
        except Exception as exc:
            raise ArtifactStoreError(f"failed to sign artifact download URL: {exc}") from exc

    def delete(self, object_key: str) -> bool:
        _validate_object_key(object_key)
        key = self._key(object_key)
        if self._head(key) is None:
            return False
        try:
            self.client.delete_object(Bucket=self.bucket, Key=key)
        except Exception as exc:
            raise ArtifactStoreError(f"failed to delete artifact object: {exc}") from exc
        return True

    def _key(self, object_key: str) -> str:
        return f"{self.prefix}/{object_key}" if self.prefix else object_key

    def _head(self, key: str) -> dict[str, Any] | None:
        try:
            return self.client.head_object(Bucket=self.bucket, Key=key)
        except Exception as exc:
            if _error_status(exc) == 404 or _error_code(exc) in {"404", "NoSuchKey", "NotFound"}:
                return None
            raise ArtifactStoreError(f"failed to inspect artifact object: {exc}") from exc

    @staticmethod
    def _verify_head(head: dict[str, Any], sha256: str, expected_bytes: int) -> None:
        metadata = {str(key).lower(): str(value) for key, value in head.get("Metadata", {}).items()}
        if int(head.get("ContentLength", -1)) != expected_bytes or metadata.get("sha256") != sha256:
            raise ArtifactStoreError("immutable artifact object conflicts with expected content")


def create_artifact_store_from_environment(
    data_root: str | Path,
    *,
    credential_scope: str = "worker",
):
    if credential_scope not in {"api", "worker"}:
        raise ValueError("artifact credential scope must be api or worker")
    backend = os.environ.get("MAP_PLATFORM_ARTIFACT_STORE", "filesystem").strip().lower()
    if backend == "filesystem":
        root = Path(os.environ.get("MAP_PLATFORM_ARTIFACT_ROOT", Path(data_root) / "artifacts"))
        return FileSystemArtifactStore(root)
    if backend != "s3":
        raise ValueError("MAP_PLATFORM_ARTIFACT_STORE must be filesystem or s3")
    try:
        import boto3
    except ImportError as exc:
        raise RuntimeError("Install backend object-storage dependencies for S3 artifacts") from exc
    bucket = os.environ.get("MAP_PLATFORM_S3_BUCKET", "")
    if not bucket:
        raise ValueError("MAP_PLATFORM_S3_BUCKET is required for S3 artifact storage")
    endpoint_url = os.environ.get("MAP_PLATFORM_S3_ENDPOINT_URL") or None
    region_name = (
        os.environ.get("AWS_REGION")
        or os.environ.get("AWS_DEFAULT_REGION")
        or ("auto" if endpoint_url else "us-east-1")
    )
    client_options = {
        "endpoint_url": endpoint_url,
        "region_name": region_name,
    }
    if credential_scope == "api":
        access_key = os.environ.get("MAP_PLATFORM_S3_API_ACCESS_KEY_ID")
        secret_key = os.environ.get("MAP_PLATFORM_S3_API_SECRET_ACCESS_KEY")
        session_token = os.environ.get("MAP_PLATFORM_S3_API_SESSION_TOKEN")
        use_default_chain = os.environ.get(
            "MAP_PLATFORM_S3_API_USE_DEFAULT_CREDENTIAL_CHAIN",
            "0",
        ).strip().lower()
        if use_default_chain not in {"0", "1", "false", "true", "no", "yes"}:
            raise ValueError(
                "MAP_PLATFORM_S3_API_USE_DEFAULT_CREDENTIAL_CHAIN must be a boolean"
            )
        use_default_chain_enabled = use_default_chain in {"1", "true", "yes"}
        if bool(access_key) != bool(secret_key):
            raise ValueError("both API S3 access-key fields must be configured together")
        if not access_key and not use_default_chain_enabled:
            raise ValueError(
                "API S3 credentials or an explicit default credential chain are required"
            )
        if access_key and use_default_chain_enabled:
            raise ValueError(
                "configure explicit API S3 credentials or the default chain, not both"
            )
        if access_key and secret_key:
            client_options["aws_access_key_id"] = access_key
            client_options["aws_secret_access_key"] = secret_key
            if session_token:
                client_options["aws_session_token"] = session_token
    client = boto3.client("s3", **client_options)
    return S3ArtifactStore(
        client,
        bucket,
        prefix=os.environ.get("MAP_PLATFORM_S3_PREFIX", "map-artifacts"),
    )


def zip_object_key(map_id: str, sha256: str) -> str:
    _validate_map_id(map_id)
    if not SHA256_PATTERN.fullmatch(sha256):
        raise ValueError("artifact SHA-256 is invalid")
    return f"maps/{map_id}/{ZIP_STORED_FORMAT}/{sha256}.zip"


def map_stream_object_key(
    map_id: str,
    signed_manifest_receipt: str,
    signature_key_id: str,
    signature_key_sha256: str,
    producer_build_sha256: str,
    producer_image_digest: str,
) -> str:
    _validate_map_id(map_id)
    if not SHA256_PATTERN.fullmatch(signed_manifest_receipt):
        raise ValueError("signed manifest receipt is invalid")
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", signature_key_id):
        raise ValueError("signature key ID is invalid")
    if not SHA256_PATTERN.fullmatch(signature_key_sha256):
        raise ValueError("signature key fingerprint is invalid")
    if not SHA256_PATTERN.fullmatch(producer_build_sha256):
        raise ValueError("producer build SHA-256 is invalid")
    image_digest_match = OCI_DIGEST_PATTERN.fullmatch(producer_image_digest)
    if not image_digest_match:
        raise ValueError("producer image digest is invalid")
    return (
        f"maps/{map_id}/{BIKE_MAP_STREAM_FORMAT}/"
        f"{signature_key_id}/{signature_key_sha256}/"
        f"{producer_build_sha256}/{image_digest_match.group(1)}/"
        f"{signed_manifest_receipt}.bmap"
    )


def sha256_file(path: str | Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _validate_object_key(object_key: str) -> None:
    if not object_key or "\\" in object_key:
        raise ValueError("artifact object key is invalid")
    parsed = PurePosixPath(object_key)
    if parsed.is_absolute() or parsed.as_posix() != object_key or ".." in parsed.parts:
        raise ValueError("artifact object key is invalid")


def _validate_map_id(map_id: str) -> None:
    if map_id in {".", ".."} or not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", map_id):
        raise ValueError("artifact map ID is invalid")


def _verify_file(path: Path, sha256: str, expected_bytes: int) -> None:
    if path.stat().st_size != expected_bytes or sha256_file(path) != sha256:
        raise ArtifactStoreError("immutable artifact conflicts with expected content")


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _error_status(exc: Exception) -> int | None:
    response = getattr(exc, "response", None)
    if not isinstance(response, dict):
        return None
    metadata = response.get("ResponseMetadata", {})
    try:
        return int(metadata.get("HTTPStatusCode"))
    except (TypeError, ValueError):
        return None


def _error_code(exc: Exception) -> str | None:
    response = getattr(exc, "response", None)
    if not isinstance(response, dict):
        return None
    error = response.get("Error", {})
    value = error.get("Code")
    return str(value) if value is not None else None
