"""Immutable Contabo object storage for verified map preparation inputs.

The public map artifact bucket and credentials are deliberately separate.
This store is worker-only and disabled unless explicitly configured.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

from .artifacts import ArtifactStoreError, S3ArtifactStore
from .strict_json import loads_strict_json

_SHA256 = re.compile(r"[0-9a-f]{64}")
_KIND = re.compile(r"[a-z][a-z0-9-]{0,31}")
MAX_DOCUMENT_BYTES = 4096


def _canonical(value: dict) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()


class PreparationObjectStore:
    def __init__(self, client, bucket: str, *, prefix: str = "map-preparation-v1", checksum_mode: str = "md5"):
        self.store = S3ArtifactStore(client, bucket, prefix=prefix, checksum_mode=checksum_mode)
        self.client = client
        self.bucket = bucket

    @staticmethod
    def _key(kind: str, digest: str, *, document: bool = False) -> str:
        if not _KIND.fullmatch(kind) or not _SHA256.fullmatch(digest):
            raise ValueError("preparation object identity is invalid")
        return f"{kind}/{'documents' if document else 'blobs'}/{digest}"

    def publish_blob(self, kind: str, path: Path, *, sha256: str, media_type: str) -> None:
        self.store.put(path, self._key(kind, sha256), sha256=sha256, media_type=media_type)

    def restore_blob(self, kind: str, destination: Path, *, sha256: str, expected_bytes: int) -> bool:
        key = self._key(kind, sha256)
        if not self.store.verify(key, sha256=sha256, expected_bytes=expected_bytes):
            return False
        self.store.fetch_to(key, destination, sha256=sha256, expected_bytes=expected_bytes)
        return True

    def publish_document(self, kind: str, slot: str, body: dict) -> None:
        document = {**body, "documentSha256": hashlib.sha256(_canonical(body)).hexdigest()}
        raw = _canonical(document)
        if len(raw) > MAX_DOCUMENT_BYTES:
            raise ValueError("preparation document exceeds its size limit")
        with tempfile.TemporaryDirectory(prefix="preparation-document-") as temporary:
            path = Path(temporary) / "document.json"
            path.write_bytes(raw)
            self.store.put(path, self._key(kind, slot, document=True),
                           sha256=hashlib.sha256(raw).hexdigest(),
                           media_type="application/json")

    def read_document(self, kind: str, slot: str) -> dict | None:
        key = self.store._key(self._key(kind, slot, document=True))
        try:
            response = self.client.get_object(Bucket=self.bucket, Key=key)
        except Exception as exc:
            details = getattr(exc, "response", {})
            code = details.get("Error", {}).get("Code") if isinstance(details, dict) else None
            if code in {"404", "NoSuchKey", "NotFound"}:
                return None
            raise ArtifactStoreError(f"failed to read preparation document: {exc}") from exc
        stream = response["Body"]
        try:
            raw = stream.read(MAX_DOCUMENT_BYTES + 1)
        finally:
            close = getattr(stream, "close", None)
            if close is not None:
                close()
        if len(raw) > MAX_DOCUMENT_BYTES:
            raise ArtifactStoreError("preparation document exceeds its size limit")
        try:
            document = loads_strict_json(raw, description="preparation document")
            if not isinstance(document, dict):
                raise ValueError("preparation document is not an object")
            digest = document.pop("documentSha256")
            if not isinstance(digest, str) or not _SHA256.fullmatch(digest):
                raise ValueError("preparation document digest is invalid")
            if hashlib.sha256(_canonical(document)).hexdigest() != digest:
                raise ValueError("preparation document content changed")
            if _canonical({**document, "documentSha256": digest}) != raw:
                raise ValueError("preparation document is not canonical")
            return document
        except (KeyError, TypeError, ValueError) as exc:
            raise ArtifactStoreError(f"invalid preparation document: {exc}") from exc


def create_preparation_store_from_environment() -> PreparationObjectStore | None:
    mode = os.environ.get("MAP_PLATFORM_PREPARATION_STORE", "disabled").strip().lower()
    if mode == "disabled":
        return None
    if mode != "contabo-s3":
        raise ValueError("MAP_PLATFORM_PREPARATION_STORE must be disabled or contabo-s3")
    endpoint = os.environ.get("MAP_PLATFORM_PREPARATION_S3_ENDPOINT_URL", "")
    parsed = urlsplit(endpoint)
    if (parsed.scheme != "https" or not parsed.hostname
            or not parsed.hostname.endswith(".contabostorage.com")
            or parsed.username or parsed.password or parsed.port
            or parsed.path not in {"", "/"} or parsed.query or parsed.fragment):
        raise ValueError("preparation storage requires a Contabo HTTPS endpoint")
    bucket = os.environ.get("MAP_PLATFORM_PREPARATION_S3_BUCKET", "")
    access = os.environ.get("MAP_PLATFORM_PREPARATION_S3_ACCESS_KEY_ID", "")
    secret = os.environ.get("MAP_PLATFORM_PREPARATION_S3_SECRET_ACCESS_KEY", "")
    if not bucket or not access or not secret:
        raise ValueError("preparation storage bucket and worker credentials are required")
    try:
        import boto3
        from botocore.config import Config
    except ImportError as exc:
        raise RuntimeError("Install backend object-storage dependencies for preparation storage") from exc
    client = boto3.client(
        "s3", endpoint_url=endpoint.rstrip("/"), region_name="default",
        aws_access_key_id=access, aws_secret_access_key=secret,
        config=Config(s3={"addressing_style": "path"}),
    )
    return PreparationObjectStore(client, bucket)
