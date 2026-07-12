from __future__ import annotations

import hashlib
import json
import re
import struct
from copy import deepcopy
from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import Any

from .manifest import (
    MAX_PACK_MAP_ID_BYTES,
    MAX_PACK_PATH_COMPONENT_BYTES,
    MAX_PACK_RELATIVE_PATH_BYTES,
    validate_pack_path,
)


MAGIC = b"BIKEMAP1"
FORMAT_VERSION = 1
ALGORITHM_P256_SHA256 = 1
RAW_P256_SIGNATURE_BYTES = 64
SIGNATURE_DOMAIN = b"open-bike-computer-map-manifest-v1\0"
P256_ORDER = int("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551", 16)
P256_HALF_ORDER = P256_ORDER // 2

MAX_MANIFEST_BYTES = 2 * 1024 * 1024
MAX_KEY_ID_BYTES = 64
MAX_MAP_ID_BYTES = MAX_PACK_MAP_ID_BYTES
MAX_PATH_COMPONENT_BYTES = MAX_PACK_PATH_COMPONENT_BYTES
MAX_RELATIVE_PATH_BYTES = MAX_PACK_RELATIVE_PATH_BYTES
MAX_FILE_COUNT = 100_000
MAX_PAYLOAD_BYTES = 512 * 1024 * 1024

_HEADER = struct.Struct("<8sHHIHHIQ")
_SIGNATURE_PREFIX = struct.Struct("<BBH")
FIXED_HEADER_BYTES = _HEADER.size


class MapStreamFormatError(ValueError):
    pass


@dataclass(frozen=True)
class MapStreamHeader:
    manifest_bytes: int
    signature_envelope_bytes: int
    file_count: int
    payload_bytes: int
    format_version: int = FORMAT_VERSION
    flags: int = 0

    @property
    def total_bytes(self) -> int:
        return (
            FIXED_HEADER_BYTES
            + self.manifest_bytes
            + self.signature_envelope_bytes
            + self.payload_bytes
        )

    def encode(self) -> bytes:
        _validate_header(self)
        return _HEADER.pack(
            MAGIC,
            self.format_version,
            self.flags,
            self.manifest_bytes,
            self.signature_envelope_bytes,
            0,
            self.file_count,
            self.payload_bytes,
        )

    @classmethod
    def decode(cls, data: bytes) -> MapStreamHeader:
        if len(data) != FIXED_HEADER_BYTES:
            raise MapStreamFormatError("map stream header must be exactly 32 bytes")
        magic, version, flags, manifest_bytes, envelope_bytes, reserved, file_count, payload_bytes = (
            _HEADER.unpack(data)
        )
        if magic != MAGIC:
            raise MapStreamFormatError("map stream magic is invalid")
        if reserved != 0:
            raise MapStreamFormatError("map stream reserved header bits are nonzero")
        header = cls(
            manifest_bytes=manifest_bytes,
            signature_envelope_bytes=envelope_bytes,
            file_count=file_count,
            payload_bytes=payload_bytes,
            format_version=version,
            flags=flags,
        )
        _validate_header(header)
        return header


@dataclass(frozen=True)
class MapStreamLayout:
    manifest_offset: int
    signature_envelope_offset: int
    payload_offset: int
    end_offset: int

    @classmethod
    def from_header(cls, header: MapStreamHeader, content_bytes: int) -> MapStreamLayout:
        if content_bytes != header.total_bytes:
            raise MapStreamFormatError("map stream content length is invalid")
        manifest_offset = FIXED_HEADER_BYTES
        envelope_offset = manifest_offset + header.manifest_bytes
        payload_offset = envelope_offset + header.signature_envelope_bytes
        return cls(manifest_offset, envelope_offset, payload_offset, header.total_bytes)


@dataclass(frozen=True)
class MapStreamSignatureEnvelope:
    key_id: str
    raw_signature: bytes
    algorithm_id: int = ALGORITHM_P256_SHA256

    def encode(self) -> bytes:
        try:
            key_id = self.key_id.encode("ascii")
        except UnicodeEncodeError as exc:
            raise MapStreamFormatError("map stream signing key id must be ASCII") from exc
        if not key_id or len(key_id) > MAX_KEY_ID_BYTES:
            raise MapStreamFormatError("map stream signing key id length is invalid")
        if any(
            not (
                48 <= character <= 57
                or 65 <= character <= 90
                or 97 <= character <= 122
                or character in b"._-"
            )
            for character in key_id
        ):
            raise MapStreamFormatError("map stream signing key id contains unsafe characters")
        if self.algorithm_id != ALGORITHM_P256_SHA256:
            raise MapStreamFormatError("map stream signature algorithm is unsupported")
        if len(self.raw_signature) != RAW_P256_SIGNATURE_BYTES:
            raise MapStreamFormatError("map stream P-256 signature must be 64 bytes")
        r = int.from_bytes(self.raw_signature[:32], "big")
        s = int.from_bytes(self.raw_signature[32:], "big")
        if not 0 < r < P256_ORDER or not 0 < s <= P256_HALF_ORDER:
            raise MapStreamFormatError("map stream P-256 signature is not canonical low-S")
        return (
            _SIGNATURE_PREFIX.pack(self.algorithm_id, len(key_id), len(self.raw_signature))
            + key_id
            + self.raw_signature
        )

    @classmethod
    def decode(cls, data: bytes) -> MapStreamSignatureEnvelope:
        if len(data) < _SIGNATURE_PREFIX.size:
            raise MapStreamFormatError("map stream signature envelope is truncated")
        algorithm_id, key_id_bytes, signature_bytes = _SIGNATURE_PREFIX.unpack_from(data)
        expected_bytes = _SIGNATURE_PREFIX.size + key_id_bytes + signature_bytes
        if len(data) != expected_bytes:
            raise MapStreamFormatError("map stream signature envelope length is invalid")
        key_start = _SIGNATURE_PREFIX.size
        try:
            key_id = data[key_start : key_start + key_id_bytes].decode("ascii")
        except UnicodeDecodeError as exc:
            raise MapStreamFormatError("map stream signing key id must be ASCII") from exc
        return cls(
            key_id=key_id,
            raw_signature=data[key_start + key_id_bytes :],
            algorithm_id=algorithm_id,
        ).validated()

    def validated(self) -> MapStreamSignatureEnvelope:
        self.encode()
        return self


def canonical_manifest_bytes(manifest: dict[str, Any]) -> bytes:
    normalized = deepcopy(manifest)
    if normalized.get("schemaVersion") != 1:
        raise MapStreamFormatError("map stream manifest schema version is unsupported")
    map_id = normalized.get("mapId")
    if (
        not isinstance(map_id, str)
        or not re.fullmatch(r"[A-Za-z0-9._-]+", map_id)
        or map_id in {".", ".."}
        or len(map_id.encode("ascii")) > MAX_MAP_ID_BYTES
    ):
        raise MapStreamFormatError("map stream manifest map id is invalid")
    files = normalized.get("files")
    if not isinstance(files, list) or not 0 < len(files) <= MAX_FILE_COUNT:
        raise MapStreamFormatError("map stream manifest files are missing")
    payload_bytes = 0
    for file in files:
        if not isinstance(file, dict) or not isinstance(file.get("path"), str):
            raise MapStreamFormatError("map stream manifest file path is invalid")
        path = file["path"]
        try:
            validate_pack_path(path)
        except ValueError as exc:
            raise MapStreamFormatError("map stream manifest file path is invalid") from exc
        if PurePosixPath(path).as_posix() != path or not path.startswith(f"VECTMAP/{map_id}/"):
            raise MapStreamFormatError("map stream manifest file path is not canonical")
        byte_count = file.get("bytes")
        if isinstance(byte_count, bool) or not isinstance(byte_count, int) or byte_count <= 0:
            raise MapStreamFormatError("map stream manifest file size is invalid")
        payload_bytes += byte_count
        if payload_bytes > MAX_PAYLOAD_BYTES:
            raise MapStreamFormatError("map stream manifest payload length is invalid")
        sha256 = file.get("sha256")
        if not isinstance(sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", sha256):
            raise MapStreamFormatError("map stream manifest file digest is invalid")
    normalized_files = sorted(files, key=lambda file: file["path"])
    paths = [file["path"] for file in normalized_files]
    if len(set(paths)) != len(paths):
        raise MapStreamFormatError("map stream manifest file paths are duplicated")
    normalized["files"] = normalized_files
    try:
        text = json.dumps(
            normalized,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    except (TypeError, ValueError) as exc:
        raise MapStreamFormatError("map stream manifest is not canonicalizable JSON") from exc
    encoded = text.encode("utf-8")
    if not encoded or len(encoded) > MAX_MANIFEST_BYTES:
        raise MapStreamFormatError("map stream manifest length is invalid")
    return encoded


def manifest_receipt(manifest: bytes) -> str:
    return hashlib.sha256(manifest).hexdigest()


def signed_manifest_receipt(manifest: bytes, envelope: bytes) -> str:
    digest = hashlib.sha256()
    digest.update(SIGNATURE_DOMAIN)
    digest.update(manifest)
    digest.update(envelope)
    return digest.hexdigest()


def signed_manifest_payload(manifest: bytes) -> bytes:
    return SIGNATURE_DOMAIN + manifest


def build_stream_prefix(
    manifest: bytes,
    envelope: MapStreamSignatureEnvelope,
    *,
    file_count: int,
    payload_bytes: int,
) -> bytes:
    encoded_envelope = envelope.encode()
    header = MapStreamHeader(
        manifest_bytes=len(manifest),
        signature_envelope_bytes=len(encoded_envelope),
        file_count=file_count,
        payload_bytes=payload_bytes,
    )
    return header.encode() + manifest + encoded_envelope


def _validate_header(header: MapStreamHeader) -> None:
    if header.format_version != FORMAT_VERSION:
        raise MapStreamFormatError("map stream format version is unsupported")
    if header.flags != 0:
        raise MapStreamFormatError("map stream header flags are unsupported")
    if not 0 < header.manifest_bytes <= MAX_MANIFEST_BYTES:
        raise MapStreamFormatError("map stream manifest length is invalid")
    maximum_envelope = _SIGNATURE_PREFIX.size + MAX_KEY_ID_BYTES + RAW_P256_SIGNATURE_BYTES
    if not _SIGNATURE_PREFIX.size < header.signature_envelope_bytes <= maximum_envelope:
        raise MapStreamFormatError("map stream signature envelope length is invalid")
    if not 0 < header.file_count <= MAX_FILE_COUNT:
        raise MapStreamFormatError("map stream file count is invalid")
    if not 0 < header.payload_bytes <= MAX_PAYLOAD_BYTES:
        raise MapStreamFormatError("map stream payload length is invalid")
