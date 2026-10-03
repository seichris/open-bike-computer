#!/usr/bin/env python3
"""Publish preservation-safe USB recovery inputs from an attested factory bundle.

This deliberately supports only the existing dual-3-MiB production layout.
A layout migration requires a new reviewed recipe, never a permissive fallback.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import tarfile

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils

from factory_release_manifest import FULL_GIT_SHA, _validated_release_tag, read_bundle_manifest, verify_factory_bundle
from firmware_manifest import _private_key

DOMAIN = b"bicino-web-flasher-v1\n"
LAYOUT_ID = "esp32s3-16m-dual3m-ffat9m-v1"
FLASH_BYTES = 0x1000000
SECTOR = 0x1000
# Explicit independent allowlist, checked against the artifact's actual table.
# Unknown data partitions (including additional credentials) must fail closed.
PARTITIONS = [
    ("nvs", 1, 2, 0x9000, 0x5000),
    ("otadata", 1, 0, 0xE000, 0x2000),
    ("app0", 0, 16, 0x10000, 0x300000),
    ("app1", 0, 17, 0x310000, 0x300000),
    ("ffat", 1, 129, 0x610000, 0x900000),
    ("coredump", 1, 3, 0xF10000, 0xF0000),
]


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode("ascii")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def partition_inventory(data: bytes) -> list[dict]:
    if len(data) != 0xC00:
        raise ValueError("partition artifact must contain exactly 3072 bytes")
    records = []
    checksum_seen = False
    for offset in range(0, len(data), 32):
        entry = data[offset:offset + 32]
        if entry == b"\xff" * 32:
            if any(byte != 255 for byte in data[offset:]):
                raise ValueError("partition table has data after its terminator")
            break
        if entry[:2] == b"\xeb\xeb":
            if checksum_seen or entry[2:16] != b"\xff" * 14 or entry[16:] != hashlib.md5(data[:offset]).digest():
                raise ValueError("partition table checksum is invalid")
            checksum_seen = True
            continue
        if checksum_seen:
            raise ValueError("partition after checksum")
        magic, kind, subtype, start, size, label, flags = struct.unpack("<HBBII16sI", entry)
        if magic != 0x50AA or flags != 0:
            raise ValueError("unsupported partition entry/security flags")
        name = label.rstrip(b"\0").decode("ascii")
        records.append((name, kind, subtype, start, size))
    if not checksum_seen or records != PARTITIONS:
        raise ValueError("USB recovery requires the exact production dual-3-MiB layout")
    return [{"name": name, "offset": start, "length": size, "preserve": name not in {"app0", "otadata"}}
            for name, _, _, start, size in records]


def recovery_payload(descriptor: dict, images: dict[str, bytes]) -> tuple[dict, dict[str, bytes]]:
    target = descriptor["target"]
    if target not in {"WAVESHARE_AMOLED_175", "WAVESHARE_AMOLED_206"}:
        raise ValueError("unsupported hardware target")
    if descriptor["environment"] != f"{target}_PRODUCTION":
        raise ValueError("recovery requires production firmware")
    plan = descriptor["flashPlan"]
    if plan["flashCapacity"] != FLASH_BYTES:
        raise ValueError("unsupported flash capacity")
    by_name = {}
    for record in plan["images"]:
        name = Path(record["file"]).name.split("-", 1)[1]
        if name in by_name:
            raise ValueError("duplicate image")
        raw = images[record["file"]]
        if len(raw) != record["size"] or digest(raw) != record["sha256"]:
            raise ValueError("image differs from attested descriptor")
        by_name[name] = (int(record["offset"], 16), raw)
    if set(by_name) != {"bootloader.bin", "partitions.bin", "boot_app0.bin", "firmware.bin"}:
        raise ValueError("unexpected factory image inventory")
    if [by_name[n][0] for n in ("bootloader.bin", "partitions.bin", "boot_app0.bin", "firmware.bin")] != [0, 0x8000, 0xE000, 0x10000]:
        raise ValueError("factory image offsets do not match the supported layout")
    regions = [{"name": "bootloader", "offset": 0, "length": 0x8000, "preserve": True},
               {"name": "partition-table", "offset": 0x8000, "length": SECTOR, "preserve": True}]
    regions += partition_inventory(by_name["partitions.bin"][1])
    firmware = by_name["firmware.bin"][1]
    bootstrap = by_name["boot_app0.bin"][1]
    if len(firmware) < 256 or len(firmware) > 0x300000 - 65536 or firmware[0] != 0xE9:
        raise ValueError("invalid application or missing 64-KiB slot reserve")
    # Pin the Arduino bootstrap (sequence 1, app0) instead of generating OTA
    # CRC/state records in the browser. A changed bootstrap needs explicit review.
    if len(bootstrap) != 0x2000 or digest(bootstrap) != "f94c5d786a7a8fab06ac5d10e33bf37711a6697636dc037559ea19cc410a17f0":
        raise ValueError("unsupported OTA bootstrap")
    assets = {}
    writes = []
    for name in ("firmware.bin", "boot_app0.bin"):
        offset, data = by_name[name]
        asset = f"{target}.web-{digest(data)}.bin"
        assets[asset] = data
        writes.append({"asset": asset, "offset": offset, "length": len(data),
                       "eraseLength": ((len(data) + SECTOR - 1) // SECTOR) * SECTOR,
                       "sha256": digest(data), "role": "application" if name == "firmware.bin" else "ota-selection"})
    value = {
        "schemaVersion": 1, "artifactType": "bicino-web-recovery", "operation": "recover",
        "minFlasherVersion": 2, "target": target, "environment": descriptor["environment"],
        "chip": "ESP32-S3", "flashBytes": FLASH_BYTES,
        "version": descriptor["firmwareVersion"]["version"], "build": descriptor["firmwareVersion"]["build"],
        "gitSha": descriptor["sourceIdentity"], "layoutId": LAYOUT_ID,
        "partitionTableSha256": digest(by_name["partitions.bin"][1]),
        "bootloaderSha256": digest(by_name["bootloader.bin"][1]),
        "bootloaderLength": len(by_name["bootloader.bin"][1]),
        "regions": regions, "writes": writes, "allowSameBuild": True,
        "unknownBuildPolicy": "rescue", "qualificationRequired": False,
        "dataImpact": "Preserves ownership, TLS identity, calibration, maps, app1 and diagnostics. Replaces app0 and resets OTA selection to app0.",
        "factoryDescriptorSha256": digest(canonical(descriptor)),
    }
    return value, assets


def sign(payload: dict, scalar: str) -> dict:
    data = canonical(payload)
    key = _private_key(scalar)
    r, s = utils.decode_dss_signature(key.sign(DOMAIN + data, ec.ECDSA(hashes.SHA256())))
    return {"schemaVersion": 1, "keyId": "bicino-release-p256-1", "algorithm": "ES256-P1363",
            "payload": base64.b64encode(data).decode("ascii"),
            "signature": base64.b64encode(r.to_bytes(32, "big") + s.to_bytes(32, "big")).decode("ascii")}


def publish(args: argparse.Namespace) -> None:
    if FULL_GIT_SHA.fullmatch(args.git_sha) is None:
        raise ValueError("full source SHA required")
    _validated_release_tag(args.tag, args.version)
    if args.bundle.is_symlink() or not args.bundle.is_file() or args.bundle.stat().st_size > 64 * 1024 * 1024:
        raise ValueError("unsafe factory archive")
    archive_digest = digest(args.bundle.read_bytes())
    descriptor_bytes = args.bundle_manifest.read_bytes()
    descriptor = read_bundle_manifest(args.bundle_manifest)
    verify_factory_bundle(args.bundle, args.bundle_manifest, descriptor, target=args.target,
                          environment=f"{args.target}_PRODUCTION", git_sha=args.git_sha,
                          version=args.version, build=args.build)
    # Read only the exact validated regular-file image members; never extract
    # candidate code or execute any file from its archive in the publisher.
    with tarfile.open(args.bundle, "r:gz") as archive:
        images = {}
        for record in descriptor["flashPlan"]["images"]:
            member = archive.getmember(f"{args.target}.factory/{record['file']}")
            if not member.isfile() or member.size != record["size"]:
                raise ValueError("unsafe factory image member")
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError("missing image")
            images[record["file"]] = stream.read(member.size + 1)
    payload, assets = recovery_payload(descriptor, images)
    if args.bundle_manifest.read_bytes() != descriptor_bytes or digest(args.bundle.read_bytes()) != archive_digest:
        raise ValueError("factory inputs changed during validation")
    payload["factoryDescriptorSha256"] = digest(descriptor_bytes)
    payload["factoryArchiveSha256"] = archive_digest
    payload["releaseTag"] = args.tag
    assets[f"{args.target}.web-recovery.json"] = canonical(sign(payload, os.environ["FIRMWARE_MANIFEST_SIGNING_PRIVATE_KEY"]))
    if args.output_dir.is_symlink():
        raise ValueError("unsafe output directory")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for name in assets:
        if (args.output_dir / name).exists() or (args.output_dir / name).is_symlink():
            raise ValueError("web release assets are create-only")
    for name, content in assets.items():
        with (args.output_dir / name).open("xb") as stream:
            stream.write(content)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--bundle-manifest", type=Path, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--git-sha", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    try:
        publish(parser.parse_args())
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        print(f"web recovery manifest error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
