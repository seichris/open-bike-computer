#!/usr/bin/env python3
"""Prepare bounded, reproducible UNSIGNED resident audio for measurement.

BPK0 is deliberately not BSPK and is not installable. No signing keys, system
voices, downloads, firmware, or device access. Final codec/trust/installation
choices remain gated on the implementation plan's physical measurements.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import struct
import wave

MANEUVERS = (
    "straight", "slight_left", "left", "sharp_left", "slight_right",
    "right", "sharp_right", "u_turn", "roundabout",
)
SEMANTICS = tuple(sorted(
    [f"{direction}.{phase}" for direction in MANEUVERS
     for phase in ("50m", "100m", "200m", "action")]
    + ["arrive", "rerouting", "continue"]
))
MAX_MANIFEST = 32768
MAX_WAV = 128000 * 2 + 65536
MAX_PAYLOAD = 4 * 1024 * 1024  # host safety ceiling, NOT a qualified free-space reserve
HEADER = struct.Struct("<4sBBHII")


class InvalidPack(ValueError):
    pass


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
                      allow_nan=False).encode("ascii")


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidPack("duplicate JSON key")
        result[key] = value
    return result


def read_bounded(path: Path, limit: int) -> bytes:
    with path.open("rb") as source:
        data = source.read(limit + 1)
    if len(data) > limit:
        raise InvalidPack("input exceeds limit")
    return data


def child(root: Path, name: object) -> Path:
    if not isinstance(name, str) or not name or len(name) > 128:
        raise InvalidPack("invalid input path")
    relative = Path(name)
    if relative.is_absolute() or ".." in relative.parts:
        raise InvalidPack("input must be beneath specification directory")
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise InvalidPack("symlink input rejected")
    return current


def text(value: object, field: str, maximum: int = 128) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum or not value.isascii():
        raise InvalidPack(f"invalid {field}")
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise InvalidPack(f"control character in {field}")
    return value


def prepare(specification: Path, maximum_bytes: int) -> bytes:
    if type(maximum_bytes) is not int or not 1 <= maximum_bytes <= MAX_PAYLOAD:
        raise InvalidPack("maximum_bytes outside host safety ceiling")
    spec = json.loads(read_bounded(specification, MAX_MANIFEST), object_pairs_hook=unique_object)
    required = {"schemaVersion", "packID", "version", "locale", "units", "provenance",
                "noticesFile", "assets"}
    if not isinstance(spec, dict) or set(spec) != required or type(spec["schemaVersion"]) is not int:
        raise InvalidPack("invalid specification fields")
    if spec["schemaVersion"] != 0 or spec["locale"] != "en-GB" or spec["units"] != "metric":
        raise InvalidPack("unsupported specification schema/locale/units")
    pack_id = text(spec["packID"], "packID", 48)
    version = text(spec["version"], "version", 32)
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,47}", pack_id):
        raise InvalidPack("invalid pack ID")
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
        raise InvalidPack("invalid semantic version")
    provenance = text(spec["provenance"], "provenance")
    assets = spec["assets"]
    if not isinstance(assets, dict) or set(assets) != set(SEMANTICS):
        raise InvalidPack("all 39 semantic prompts must appear exactly once")
    root = specification.resolve().parent
    notices = read_bounded(child(root, spec["noticesFile"]), MAX_MANIFEST)
    if not notices.strip():
        raise InvalidPack("provenance notices are empty")
    records = []
    payload = bytearray()
    for semantic in SEMANTICS:
        entry = assets[semantic]
        if not isinstance(entry, dict) or set(entry) != {"file", "sourceSHA256"}:
            raise InvalidPack("invalid asset fields")
        source = read_bounded(child(root, entry["file"]), MAX_WAV)
        if not isinstance(entry["sourceSHA256"], str) or not re.fullmatch(r"[0-9a-f]{64}", entry["sourceSHA256"]):
            raise InvalidPack("invalid source hash")
        if hashlib.sha256(source).hexdigest() != entry["sourceSHA256"]:
            raise InvalidPack("recording does not match declared source hash")
        with wave.open(io.BytesIO(source), "rb") as wav:
            frames = wav.getnframes()
            if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getcomptype()) != (1, 2, 16000, "NONE"):
                raise InvalidPack("recording must be mono PCM16LE at 16 kHz")
            if not 1 <= frames <= 128000:
                raise InvalidPack("recording must be nonempty and at most eight seconds")
            pcm = wav.readframes(frames + 1)
        if len(pcm) != frames * 2:
            raise InvalidPack("truncated recording")
        if len(payload) + len(pcm) > maximum_bytes:
            raise InvalidPack("recordings exceed caller's payload budget")
        records.append({"semantic": semantic, "offset": len(payload), "bytes": len(pcm),
                        "frames": frames, "sha256": hashlib.sha256(pcm).hexdigest()})
        payload.extend(pcm)
    manifest = canonical({
        "schemaVersion": 0, "purpose": "unsigned-measurement-only", "packID": pack_id,
        "version": version, "locale": "en-GB", "units": "metric", "codec": "pcm16le",
        "sampleRate": 16000, "channels": 1, "provenance": provenance,
        "noticesSHA256": hashlib.sha256(notices).hexdigest(), "payloadBytes": len(payload),
        "assets": records,
    })
    if len(manifest) > MAX_MANIFEST:
        raise InvalidPack("manifest exceeds bound")
    return HEADER.pack(b"BPK0", 0, 1, 0, len(manifest), len(payload)) + manifest + payload


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("specification", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--maximum-bytes", required=True, type=int,
                        help="explicit payload budget, at most 4 MiB; not a device qualification")
    args = parser.parse_args()
    data = prepare(args.specification, args.maximum_bytes)
    # Exclusive create: never overwrite recordings, another pack, or a symlink.
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(data)
    print(f"unsigned_measurement_pack_bytes={len(data)} installable=false")


if __name__ == "__main__":
    main()
