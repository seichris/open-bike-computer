from __future__ import annotations

import hashlib
import json
import os
import re
import struct
import time
import uuid
from copy import deepcopy
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation, ROUND_HALF_EVEN
from pathlib import Path, PurePosixPath
from typing import Any, Protocol

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
MAX_BLOCK_BYTES = 2 * 1024 * 1024
COORDINATE_E7_SCALE = Decimal("10000000")

_HEADER = struct.Struct("<8sHHIHHIQ")
_SIGNATURE_PREFIX = struct.Struct("<BBH")
FIXED_HEADER_BYTES = _HEADER.size


class MapStreamFormatError(ValueError):
    code = "map_stream_format_invalid"


class MapStreamBuildError(RuntimeError):
    code = "map_stream_build_failed"


def _coordinate_e7(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise MapStreamFormatError("map stream manifest bounds are invalid")
    try:
        decimal = Decimal(str(value))
    except InvalidOperation as exc:
        raise MapStreamFormatError("map stream manifest bounds are invalid") from exc
    if not decimal.is_finite():
        raise MapStreamFormatError("map stream manifest bounds are invalid")
    return int(
        (decimal * COORDINATE_E7_SCALE).to_integral_value(
            rounding=ROUND_HALF_EVEN
        )
    )


def _normalize_bounds_e7(manifest: dict[str, Any]) -> None:
    if "bounds" in manifest and "boundsE7" in manifest:
        raise MapStreamFormatError("map stream manifest has conflicting bounds")
    if "bounds" in manifest:
        bounds = manifest.pop("bounds")
        if not isinstance(bounds, (list, tuple)) or len(bounds) != 4:
            raise MapStreamFormatError("map stream manifest bounds are invalid")
        manifest["boundsE7"] = [_coordinate_e7(value) for value in bounds]
    if "boundsE7" not in manifest:
        return
    bounds_e7 = manifest["boundsE7"]
    if (
        not isinstance(bounds_e7, (list, tuple))
        or len(bounds_e7) != 4
        or any(isinstance(value, bool) or not isinstance(value, int) for value in bounds_e7)
    ):
        raise MapStreamFormatError("map stream manifest boundsE7 are invalid")
    minimum_longitude, minimum_latitude, maximum_longitude, maximum_latitude = bounds_e7
    if (
        not -1_800_000_000 <= minimum_longitude <= 1_800_000_000
        or not -1_800_000_000 <= maximum_longitude <= 1_800_000_000
        or not -900_000_000 <= minimum_latitude <= 900_000_000
        or not -900_000_000 <= maximum_latitude <= 900_000_000
        or minimum_longitude >= maximum_longitude
        or minimum_latitude >= maximum_latitude
    ):
        raise MapStreamFormatError("map stream manifest boundsE7 are invalid")
    manifest["boundsE7"] = list(bounds_e7)


def _reject_floating_json(value: Any) -> None:
    if isinstance(value, float):
        raise MapStreamFormatError(
            "map stream manifest floating-point JSON is unsupported"
        )
    if isinstance(value, dict):
        for child in value.values():
            _reject_floating_json(child)
    elif isinstance(value, (list, tuple)):
        for child in value:
            _reject_floating_json(child)


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


class MapStreamSigner(Protocol):
    key_id: str

    def sign(self, manifest: bytes) -> MapStreamSignatureEnvelope: ...


@dataclass(frozen=True)
class MapStreamArtifactBuild:
    path: Path
    bytes: int
    sha256: str
    manifest_receipt: str
    signed_manifest_receipt: str
    signature_key_id: str
    file_count: int
    payload_bytes: int
    timings: dict[str, float]


def canonical_manifest_bytes(manifest: dict[str, Any]) -> bytes:
    normalized = deepcopy(manifest)
    _normalize_bounds_e7(normalized)
    _reject_floating_json(normalized)
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
        if (
            isinstance(byte_count, bool)
            or not isinstance(byte_count, int)
            or not 0 < byte_count <= MAX_BLOCK_BYTES
        ):
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


def _without_redundant_text_fallbacks(manifest: dict[str, Any]) -> dict[str, Any]:
    normalized = deepcopy(manifest)
    files = normalized.get("files")
    if not isinstance(files, list):
        return normalized
    binary_stems = {
        file["path"][:-4]
        for file in files
        if isinstance(file, dict)
        and isinstance(file.get("path"), str)
        and file["path"].endswith(".fmb")
    }
    normalized["files"] = [
        file
        for file in files
        if not (
            isinstance(file, dict)
            and isinstance(file.get("path"), str)
            and file["path"].endswith(".fmp")
            and file["path"][:-4] in binary_stems
        )
    ]
    return normalized


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


def write_map_stream_artifact(
    map_root: str | Path,
    manifest: dict[str, Any],
    signer: MapStreamSigner,
    output_path: str | Path,
) -> MapStreamArtifactBuild:
    total_started = time.perf_counter()
    root = Path(map_root)
    resolved_root = root.resolve()
    destination = Path(output_path)
    canonicalization_started = time.perf_counter()
    manifest_bytes = canonical_manifest_bytes(
        _without_redundant_text_fallbacks(manifest)
    )
    canonical_manifest = json.loads(manifest_bytes)
    files = canonical_manifest["files"]
    file_count = len(files)
    payload_bytes = sum(file["bytes"] for file in files)
    canonicalization_seconds = time.perf_counter() - canonicalization_started
    signing_started = time.perf_counter()
    envelope = signer.sign(manifest_bytes)
    signing_seconds = time.perf_counter() - signing_started
    if envelope.key_id != signer.key_id:
        raise MapStreamBuildError("map signer returned an unexpected key ID")
    envelope_bytes = envelope.encode()
    prefix = build_stream_prefix(
        manifest_bytes,
        envelope,
        file_count=file_count,
        payload_bytes=payload_bytes,
    )

    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise MapStreamBuildError(f"map stream output directory is unavailable: {exc}") from exc
    temporary = destination.parent / f".{destination.name}.{uuid.uuid4().hex}.tmp"
    artifact_digest = hashlib.sha256()
    written_bytes = 0
    hashing_seconds = 0.0
    artifact_write_seconds = 0.0
    try:
        try:
            output_file = temporary.open("xb")
        except OSError as exc:
            raise MapStreamBuildError(f"map stream output file is unavailable: {exc}") from exc
        with output_file as output:
            operation_started = time.perf_counter()
            try:
                output.write(prefix)
            except OSError as exc:
                raise MapStreamBuildError(f"map stream output write failed: {exc}") from exc
            artifact_write_seconds += time.perf_counter() - operation_started
            operation_started = time.perf_counter()
            artifact_digest.update(prefix)
            hashing_seconds += time.perf_counter() - operation_started
            written_bytes += len(prefix)
            for entry in files:
                source = root.joinpath(*PurePosixPath(entry["path"]).parts)
                file_digest = hashlib.sha256()
                file_bytes = 0
                try:
                    resolved_source = source.resolve(strict=True)
                    resolved_source.relative_to(resolved_root)
                    if source.is_symlink():
                        raise MapStreamBuildError(
                            f"map payload file may not be a symlink: {entry['path']}"
                        )
                    input_file = resolved_source.open("rb")
                    with input_file:
                        while True:
                            try:
                                chunk = input_file.read(1024 * 1024)
                            except OSError as exc:
                                raise MapStreamBuildError(
                                    f"map payload file read failed: {entry['path']}"
                                ) from exc
                            if not chunk:
                                break
                            operation_started = time.perf_counter()
                            try:
                                output.write(chunk)
                            except OSError as exc:
                                raise MapStreamBuildError(
                                    f"map stream output write failed: {exc}"
                                ) from exc
                            artifact_write_seconds += time.perf_counter() - operation_started
                            operation_started = time.perf_counter()
                            artifact_digest.update(chunk)
                            file_digest.update(chunk)
                            hashing_seconds += time.perf_counter() - operation_started
                            file_bytes += len(chunk)
                            written_bytes += len(chunk)
                except (OSError, ValueError) as exc:
                    raise MapStreamBuildError(f"map payload file is unavailable: {entry['path']}") from exc
                if file_bytes != entry["bytes"]:
                    raise MapStreamBuildError(f"map payload file size changed: {entry['path']}")
                if file_digest.hexdigest() != entry["sha256"]:
                    raise MapStreamBuildError(f"map payload file digest changed: {entry['path']}")
            operation_started = time.perf_counter()
            try:
                output.flush()
                os.fsync(output.fileno())
            except OSError as exc:
                raise MapStreamBuildError(f"map stream output sync failed: {exc}") from exc
            artifact_write_seconds += time.perf_counter() - operation_started
        expected_bytes = len(prefix) + payload_bytes
        if written_bytes != expected_bytes:
            raise MapStreamBuildError("map stream artifact length is inconsistent")
        try:
            os.replace(temporary, destination)
            _fsync_directory(destination.parent)
        except OSError as exc:
            raise MapStreamBuildError(f"map stream output commit failed: {exc}") from exc
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass

    return MapStreamArtifactBuild(
        path=destination,
        bytes=written_bytes,
        sha256=artifact_digest.hexdigest(),
        manifest_receipt=manifest_receipt(manifest_bytes),
        signed_manifest_receipt=signed_manifest_receipt(manifest_bytes, envelope_bytes),
        signature_key_id=envelope.key_id,
        file_count=file_count,
        payload_bytes=payload_bytes,
        timings={
            "canonicalizationSeconds": canonicalization_seconds,
            "signingSeconds": signing_seconds,
            "hashingSeconds": hashing_seconds,
            "artifactWriteSeconds": artifact_write_seconds,
            "totalSeconds": time.perf_counter() - total_started,
        },
    )


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


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
