#!/usr/bin/env python3
"""Publish signed USB recovery and migration recipes from an attested factory bundle.

Layouts come only from esp32/partition_layouts.json. Each release may emit:

* ``<target>.web-recovery.json``: the unchanged dual-3-MiB rescue contract,
  only while the application still fits a legacy slot with its 64 KiB reserve;
* ``<target>.web-recovery-dual4m.json``: the same app0 + OTA-selection rescue
  for devices that already carry the current dual-4-MiB table;
* ``<target>.web-migration-dual3m-dual4m.json``: the explicit, ordered and
  bounded migration recipe. It is signed ``qualificationRequired`` so the
  website admits it only after per-target physical qualification;
* ``<target>.image-identity.json``: the release image's size, SHA-256, first
  4 KiB digest and appended-digest tail, signed under its own domain so the
  website can recognise installed slots without reading them whole.

There is no permissive or unknown-layout fallback.
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

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "esp32" / "tools"))
import partition_layouts  # noqa: E402

DOMAIN = b"bicino-web-flasher-v1\n"
# Separate domain: an image identity signature can never verify as a recipe.
IDENTITY_DOMAIN = b"bicino-image-identity-v1\n"
IDENTITY_HEAD = 4096
IDENTITY_TAIL = 32
FLASH_BYTES = partition_layouts.FLASH_BYTES
SECTOR = partition_layouts.SECTOR
RESERVE = partition_layouts.APPLICATION_RESERVE_BYTES
BOOTLOADER_SPAN = partition_layouts.TABLE_OFFSET
LAYOUTS = partition_layouts.load()
LEGACY = LAYOUTS.legacy("production")
CURRENT = LAYOUTS.current("production")
MIGRATION = LAYOUTS.migration(LEGACY, CURRENT)
# Kept for callers that still name the original rescue contract.
LAYOUT_ID = LEGACY.id
PARTITIONS = [partition.record() for partition in LEGACY.partitions]
BOOTSTRAP_SHA256 = "f94c5d786a7a8fab06ac5d10e33bf37711a6697636dc037559ea19cc410a17f0"
RECOVERY_IMPACT = ("Preserves ownership, TLS identity, calibration, maps, app1 and diagnostics. "
                   "Replaces app0 and resets OTA selection to app0.")
MIGRATION_IMPACT = (
    "Moves this device to dual 4 MiB firmware slots. Keeps ownership, TLS identity, settings, "
    "calibration, coredump and everything on the SD card. Permanently erases internal storage "
    "(diagnostics recorded without an SD card, internal GPX/device files and unused old maps) "
    "and the previous rollback firmware. Export internal diagnostics first if you need them.")


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode("ascii")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def short_name(layout: partition_layouts.Layout) -> str:
    """``esp32s3-16m-dual4m-ffat7m-v1`` -> ``dual4m`` for asset names."""
    return layout.id.split("-")[2]


def asset_names(target: str) -> dict[str, str]:
    return {
        "legacy-recovery": f"{target}.web-recovery.json",
        "recovery": f"{target}.web-recovery-{short_name(CURRENT)}.json",
        "migration": f"{target}.web-migration-{short_name(LEGACY)}-{short_name(CURRENT)}.json",
    }


def partition_inventory(data: bytes, layout: partition_layouts.Layout = LEGACY) -> list[dict]:
    """Return the rescue region list after requiring the exact layout table."""
    try:
        records = partition_layouts.parse_table(data)
    except partition_layouts.LayoutError as error:
        raise ValueError(str(error)) from error
    if records != layout.partitions or digest(data) != layout.table_sha256:
        raise ValueError(f"USB recovery requires the exact {layout.id} layout")
    return [{"name": p.name, "offset": p.offset, "length": p.size, "preserve": p.name not in {"app0", "otadata"}}
            for p in records]


def _regions(layout: partition_layouts.Layout) -> list[dict]:
    return ([{"name": "bootloader", "offset": 0, "length": BOOTLOADER_SPAN, "preserve": True},
             {"name": "partition-table", "offset": partition_layouts.TABLE_OFFSET, "length": SECTOR, "preserve": True}]
            + partition_inventory(layout.table_bytes(), layout))


def _layout_regions(layout: partition_layouts.Layout) -> list[dict]:
    return [{"name": p.name, "offset": p.offset, "length": p.size} for p in layout.partitions]


def _span(length: int) -> int:
    return ((length + SECTOR - 1) // SECTOR) * SECTOR


def _release_images(descriptor: dict, images: dict[str, bytes]) -> dict[str, tuple[int, bytes]]:
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
    # A release is always built for the current production table. A legacy
    # table here would mean an unreviewed or unmigrated build input.
    partition_inventory(by_name["partitions.bin"][1], CURRENT)
    firmware = by_name["firmware.bin"][1]
    if len(firmware) < 256 or len(firmware) > CURRENT.max_application_bytes or firmware[0] != 0xE9:
        raise ValueError("invalid application or missing 64-KiB slot reserve")
    bootloader = by_name["bootloader.bin"][1]
    if not 0 < len(bootloader) <= BOOTLOADER_SPAN:
        raise ValueError("bootloader exceeds its region")
    # Pin the Arduino bootstrap (sequence 1, app0) instead of generating OTA
    # CRC/state records in the browser. A changed bootstrap needs explicit review.
    bootstrap = by_name["boot_app0.bin"][1]
    if len(bootstrap) != 0x2000 or digest(bootstrap) != BOOTSTRAP_SHA256:
        raise ValueError("unsupported OTA bootstrap")
    return by_name


def _write(target: str, role: str, offset: int, data: bytes) -> tuple[dict, str]:
    asset = f"{target}.web-{digest(data)}.bin"
    return ({"asset": asset, "offset": offset, "length": len(data), "eraseLength": _span(len(data)),
             "sha256": digest(data), "role": role}, asset)


def _common(descriptor: dict, by_name: dict[str, tuple[int, bytes]]) -> dict:
    bootloader = by_name["bootloader.bin"][1]
    return {
        "target": descriptor["target"], "environment": descriptor["environment"],
        "chip": "ESP32-S3", "flashBytes": FLASH_BYTES,
        "version": descriptor["firmwareVersion"]["version"], "build": descriptor["firmwareVersion"]["build"],
        "gitSha": descriptor["sourceIdentity"],
        "bootloaderSha256": digest(bootloader), "bootloaderLength": len(bootloader),
        "unknownBuildPolicy": "rescue",
        "factoryDescriptorSha256": digest(canonical(descriptor)),
    }


def recovery_payload(descriptor: dict, images: dict[str, bytes],
                     layout: partition_layouts.Layout = LEGACY) -> tuple[dict, dict[str, bytes]]:
    """Signed app0 + OTA-selection rescue that preserves the device's own table."""
    by_name = _release_images(descriptor, images)
    if layout not in (LEGACY, CURRENT):
        raise ValueError("unsupported recovery layout")
    target = descriptor["target"]
    firmware = by_name["firmware.bin"][1]
    if len(firmware) > layout.max_application_bytes:
        raise ValueError(f"application does not fit {layout.id} with its 64-KiB reserve")
    assets, writes = {}, []
    for name, role in (("firmware.bin", "application"), ("boot_app0.bin", "ota-selection")):
        offset, data = by_name[name]
        write, asset = _write(target, role, offset, data)
        writes.append(write)
        assets[asset] = data
    value = dict(_common(descriptor, by_name), **{
        "schemaVersion": 1, "artifactType": "bicino-web-recovery", "operation": "recover",
        # Version 2 keeps the dual-3-MiB contract readable by today's website.
        # The dual-4-MiB layout needs a flasher that knows its regions.
        "minFlasherVersion": 2 if layout is LEGACY else 3,
        "layoutId": layout.id, "partitionTableSha256": layout.table_sha256,
        "regions": _regions(layout), "writes": writes, "allowSameBuild": True,
        "qualificationRequired": False, "dataImpact": RECOVERY_IMPACT,
    })
    return value, assets


def app_descriptor(image: bytes) -> dict | None:
    """The ESP-IDF app description as the publisher reads it; informational."""
    if len(image) < 0x120 or image[0] != 0xE9 or struct.unpack_from("<I", image, 0x20)[0] != 0xABCD5432:
        return None

    def text(offset: int, length: int) -> str:
        raw = image[0x20 + offset:0x20 + offset + length].split(b"\0", 1)[0]
        return "".join(chr(b) if 0x20 <= b < 0x7F else "?" for b in raw)

    return {"version": text(0x10, 32), "projectName": text(0x30, 32),
            "elfSha256": image[0xB0:0xD0].hex()}


def identity_payload(value: dict, firmware: bytes) -> dict:
    """Bind the exact application bytes a device may hold to this release.

    The browser rules an image out of a slot from its first 4 KiB and last 32
    bytes (the ESP appended image digest) and only then reads the whole slot.
    """
    if value["writes"][0]["sha256"] != digest(firmware) or len(firmware) != value["writes"][0]["length"]:
        raise ValueError("identity image differs from the signed recovery recipe")
    head = firmware[:IDENTITY_HEAD]
    return {
        "schemaVersion": 1, "artifactType": "bicino-image-identity",
        "target": value["target"], "environment": value["environment"],
        "version": value["version"], "build": value["build"], "gitSha": value["gitSha"],
        "releaseTag": value["releaseTag"],
        "image": {"size": len(firmware), "sha256": digest(firmware), "headLength": len(head),
                  "headSha256": digest(head), "tail": firmware[-IDENTITY_TAIL:].hex()},
        "descriptor": app_descriptor(firmware),
    }


def migration_payload(descriptor: dict, images: dict[str, bytes]) -> tuple[dict, dict[str, bytes]]:
    """Ordered dual-3-MiB to dual-4-MiB recipe; the table is the last write.

    Until the table commit the device keeps its legacy table. App0 and OTA
    selection are written first, so an interrupted run can still boot the new
    image on the old table when it fits there. App1 and FFat are then erased:
    the firmware formats only fully erased FFat. The destination table is
    written last, so a retried run either restarts from the legacy table or
    finds every earlier step verified and only the table missing.
    """
    by_name = _release_images(descriptor, images)
    target = descriptor["target"]
    destination_table = CURRENT.table_bytes()
    if by_name["partitions.bin"][1] != destination_table:
        raise ValueError("migration requires the release's own destination table")
    steps, assets = [], {}
    for name, role in (("firmware.bin", "application"), ("boot_app0.bin", "ota-selection")):
        offset, data = by_name[name]
        step, asset = _write(target, role, offset, data)
        steps.append(step)
        assets[asset] = data
    for name, role in (("app1", "erase-app1"), ("ffat", "erase-ffat")):
        partition = CURRENT.partition(name)
        steps.append({"role": role, "offset": partition.offset, "length": partition.size,
                      "eraseLength": partition.size, "fill": 255,
                      "sha256": digest(b"\xff" * partition.size)})
    step, asset = _write(target, "partition-table", partition_layouts.TABLE_OFFSET, destination_table)
    steps.append(step)
    assets[asset] = destination_table
    preserve = [{"name": "bootloader", "offset": 0, "length": BOOTLOADER_SPAN}] + [
        {"name": name, "offset": CURRENT.partition(name).offset, "length": CURRENT.partition(name).size}
        for name in ("nvs", "coredump")]
    for step in steps:
        end = step["offset"] + step["eraseLength"]
        if step["offset"] % SECTOR or end > FLASH_BYTES or any(
                step["offset"] < p["offset"] + p["length"] and end > p["offset"] for p in preserve):
            raise ValueError("migration step would erase protected data")
    value = dict(_common(descriptor, by_name), **{
        "schemaVersion": 1, "artifactType": "bicino-web-migration", "operation": "migrate",
        "migrationId": MIGRATION.id, "minFlasherVersion": 3,
        "source": {"layoutId": LEGACY.id, "partitionTableSha256": LEGACY.table_sha256,
                   "regions": _layout_regions(LEGACY)},
        "destination": {"layoutId": CURRENT.id, "partitionTableSha256": CURRENT.table_sha256,
                        "regions": _layout_regions(CURRENT)},
        "preserve": preserve, "steps": steps,
        # Signed as gated: no browser may run it before physical qualification.
        "qualificationRequired": True, "dataImpact": MIGRATION_IMPACT,
    })
    return value, assets


def release_packages(descriptor: dict, images: dict[str, bytes]) -> tuple[dict[str, dict], dict[str, bytes]]:
    """Return every signed web payload this release supports, keyed by asset name."""
    by_name = _release_images(descriptor, images)
    names = asset_names(descriptor["target"])
    payloads, assets = {}, {}
    builders = [("recovery", lambda: recovery_payload(descriptor, images, CURRENT)),
                ("migration", lambda: migration_payload(descriptor, images))]
    if len(by_name["firmware.bin"][1]) <= LEGACY.max_application_bytes:
        builders.insert(0, ("legacy-recovery", lambda: recovery_payload(descriptor, images, LEGACY)))
    for kind, build in builders:
        payload, package_assets = build()
        payloads[names[kind]] = payload
        assets.update(package_assets)
    return payloads, assets


def sign(payload: dict, scalar: str, domain: bytes = DOMAIN) -> dict:
    data = canonical(payload)
    key = _private_key(scalar)
    r, s = utils.decode_dss_signature(key.sign(domain + data, ec.ECDSA(hashes.SHA256())))
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
    payloads, assets = release_packages(descriptor, images)
    if args.bundle_manifest.read_bytes() != descriptor_bytes or digest(args.bundle.read_bytes()) != archive_digest:
        raise ValueError("factory inputs changed during validation")
    key = os.environ["FIRMWARE_MANIFEST_SIGNING_PRIVATE_KEY"]
    for name, payload in payloads.items():
        payload["factoryDescriptorSha256"] = digest(descriptor_bytes)
        payload["factoryArchiveSha256"] = archive_digest
        payload["releaseTag"] = args.tag
        assets[name] = canonical(sign(payload, key))
    # Every release carries the dual-4-MiB rescue, while the legacy rescue is
    # skipped once the image outgrows a 3 MiB slot. All packages write the
    # same application image, so the identity binds that image.
    recovery = payloads[asset_names(args.target)["recovery"]]
    firmware = assets[recovery["writes"][0]["asset"]]
    assets[f"{args.target}.image-identity.json"] = canonical(
        sign(identity_payload(recovery, firmware), key, IDENTITY_DOMAIN))
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
