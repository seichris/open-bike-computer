#!/usr/bin/env python3
"""Generate a signed release manifest for a factory-flash bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import shutil
import sys
import tarfile
import tempfile

from firmware_manifest import read_firmware_metadata, sha256_hex, sign_payload


ARTIFACT_TYPE = "esp32-factory-flash-bundle"
SIGNATURE_FIELDS = (
    "schemaVersion",
    "artifactType",
    "target",
    "environment",
    "version",
    "build",
    "gitSha",
    "assetName",
    "size",
    "sha256",
    "bundleManifestName",
    "bundleManifestSha256",
    "buildAttestationSha256",
    "runtimeProvenanceSha256",
    "url",
)
BUNDLE_SCHEMA = 2
RELEASE_SCHEMA = 2
FULL_GIT_SHA = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
TARGET = re.compile(r"^WAVESHARE_AMOLED_(?:175|206)$")
SAFE_RUNTIME_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
CANONICAL_OFFSET = re.compile(r"^0x(?:0|[1-9a-f][0-9a-f]*)$")
PORTABLE_IMAGE_NAME = re.compile(r"^([0-9a-f]{8})-([A-Za-z0-9._-]+)$")
REQUIRED_IMAGE_NAMES = {
    "bootloader.bin",
    "partitions.bin",
    "boot_app0.bin",
    "firmware.bin",
}
MAX_BUNDLE_MANIFEST_BYTES = 1024 * 1024
MAX_FACTORY_BUNDLE_BYTES = 64 * 1024 * 1024
MAX_FACTORY_CONTENT_BYTES = 128 * 1024 * 1024
MAX_FACTORY_ARCHIVE_MEMBERS = 128
MAX_EXTRACTED_BUNDLE_BYTES = 128 * 1024 * 1024
MAX_BUILD_ATTESTATION_BYTES = 8 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 64
COPY_CHUNK_BYTES = 1024 * 1024


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"JSON contains duplicate key: {key}")
        value[key] = item
    return value


def _parse_bundle_manifest(encoded: bytes) -> dict[str, object]:
    try:
        if not encoded or len(encoded) > MAX_BUNDLE_MANIFEST_BYTES:
            raise ValueError("factory bundle manifest has an invalid size")
        value = json.loads(
            encoded.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"could not read factory bundle manifest: {error}") from error
    if not isinstance(value, dict):
        raise ValueError("factory bundle manifest must contain a JSON object")
    return value


def read_bundle_manifest(path: pathlib.Path) -> dict[str, object]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"factory bundle manifest is missing or unsafe: {path}")
    return _parse_bundle_manifest(path.read_bytes())


def _safe_relative_path(value: object, label: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or value.startswith("/")
        or "\\" in value
        or "\0" in value
        or any(part in {"", ".", ".."} for part in value.split("/"))
    ):
        raise ValueError(f"{label} is unsafe: {value!r}")
    return value


def _descriptor_file_contracts(
    bundle_manifest: dict[str, object],
) -> dict[str, tuple[int, str]]:
    build_attestation = bundle_manifest.get("buildAttestation")
    flash_plan = bundle_manifest.get("flashPlan")
    if not isinstance(build_attestation, dict) or not isinstance(flash_plan, dict):
        raise ValueError("factory bundle manifest is missing packaged file contracts")
    images = flash_plan.get("images")
    merged_image = flash_plan.get("mergedImage")
    if (
        not isinstance(images, list)
        or not 1 <= len(images) <= 32
        or not isinstance(merged_image, dict)
    ):
        raise ValueError("factory bundle manifest has an invalid flash image set")

    contracts: dict[str, tuple[int, str]] = {}
    for label, record in (
        ("build attestation", build_attestation),
        *(("flash image", image) for image in images),
        ("merged image", merged_image),
    ):
        if not isinstance(record, dict):
            raise ValueError(f"factory bundle manifest {label} is invalid")
        relative = _safe_relative_path(record.get("file"), label)
        size = record.get("size")
        digest = record.get("sha256")
        if (
            not isinstance(size, int)
            or isinstance(size, bool)
            or size <= 0
            or not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None
            or relative in contracts
        ):
            raise ValueError(f"factory bundle manifest {label} contract is invalid")
        contracts[relative] = (size, digest)
    return contracts


def _validate_factory_archive(
    bundle: pathlib.Path,
    *,
    target: str,
    bundle_manifest_bytes: bytes,
    bundle_manifest: dict[str, object],
) -> None:
    root_name = f"{target}.factory"
    files: dict[str, tuple[int, str, bytes | None]] = {}
    seen_names: set[str] = set()
    total_size = 0
    try:
        with tarfile.open(bundle, mode="r:gz") as archive:
            member_count = 0
            for member in archive:
                member_count += 1
                if member_count > MAX_FACTORY_ARCHIVE_MEMBERS:
                    raise ValueError(
                        "factory bundle archive has an invalid member count"
                    )
                raw_name = member.name.rstrip("/") if member.isdir() else member.name
                if raw_name in seen_names:
                    raise ValueError(
                        f"factory bundle archive repeats member: {raw_name}"
                    )
                seen_names.add(raw_name)
                _safe_relative_path(raw_name, "factory bundle archive member")
                if raw_name != root_name and not raw_name.startswith(
                    f"{root_name}/"
                ):
                    raise ValueError(
                        f"factory bundle archive member is outside {root_name}: "
                        f"{raw_name}"
                    )
                if member.isdir():
                    continue
                if not member.isfile():
                    raise ValueError(
                        f"factory bundle archive contains a link or special file: "
                        f"{raw_name}"
                    )
                relative = raw_name[len(root_name) + 1 :]
                if not relative:
                    raise ValueError("factory bundle archive root must be a directory")
                total_size += member.size
                if (
                    member.size <= 0
                    or member.size > MAX_FACTORY_CONTENT_BYTES
                    or total_size > MAX_FACTORY_CONTENT_BYTES
                    or (
                        relative in {"factory-bundle.json", "SHA256SUMS"}
                        and member.size > MAX_BUNDLE_MANIFEST_BYTES
                    )
                ):
                    raise ValueError("factory bundle archive content is too large")
                stream = archive.extractfile(member)
                if stream is None:
                    raise ValueError(
                        f"factory bundle archive member cannot be read: {raw_name}"
                    )
                digest = hashlib.sha256()
                captured = (
                    bytearray()
                    if relative in {"factory-bundle.json", "SHA256SUMS"}
                    else None
                )
                size = 0
                for chunk in iter(lambda: stream.read(COPY_CHUNK_BYTES), b""):
                    size += len(chunk)
                    digest.update(chunk)
                    if captured is not None:
                        captured.extend(chunk)
                if size != member.size:
                    raise ValueError(
                        f"factory bundle archive member is truncated: {raw_name}"
                    )
                files[relative] = (
                    size,
                    digest.hexdigest(),
                    bytes(captured) if captured is not None else None,
                )
            if member_count == 0:
                raise ValueError("factory bundle archive has an invalid member count")
    except (OSError, EOFError, tarfile.TarError) as error:
        raise ValueError(f"factory bundle archive is invalid: {error}") from error

    embedded = files.get("factory-bundle.json")
    if embedded is None or embedded[2] != bundle_manifest_bytes:
        raise ValueError(
            "factory bundle archive does not contain the supplied bundle manifest"
        )

    checksums = files.get("SHA256SUMS")
    if checksums is None or checksums[2] is None:
        raise ValueError("factory bundle archive is missing SHA256SUMS")
    try:
        checksum_lines = checksums[2].decode("utf-8").splitlines()
    except UnicodeError as error:
        raise ValueError("factory bundle SHA256SUMS is not UTF-8") from error
    declared_checksums: dict[str, str] = {}
    for line in checksum_lines:
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if match is None:
            raise ValueError("factory bundle SHA256SUMS contains an invalid line")
        relative = _safe_relative_path(match.group(2), "factory checksum path")
        if relative == "SHA256SUMS" or relative in declared_checksums:
            raise ValueError("factory bundle SHA256SUMS contains an invalid path")
        declared_checksums[relative] = match.group(1)
    actual_checksums = {
        relative: digest
        for relative, (_, digest, _) in files.items()
        if relative != "SHA256SUMS"
    }
    if declared_checksums != actual_checksums:
        raise ValueError("factory bundle SHA256SUMS does not match archive contents")

    for relative, (expected_size, expected_digest) in _descriptor_file_contracts(
        bundle_manifest
    ).items():
        actual = files.get(relative)
        if actual is None or actual[:2] != (expected_size, expected_digest):
            raise ValueError(
                f"factory bundle archive does not match {relative} in its manifest"
            )


def _validated_release_tag(tag: str, version: str) -> str:
    expected = f"v{version}"
    if tag != expected and not tag.startswith(f"{expected}-"):
        raise ValueError(
            f"release tag {tag!r} does not match firmware version {version!r}"
        )
    return tag


def canonical_payload(manifest: dict[str, object]) -> bytes:
    lines = []
    for field in SIGNATURE_FIELDS:
        if field not in manifest:
            raise ValueError(f"factory release manifest is missing {field}")
        value = manifest[field]
        if isinstance(value, str) and ("\n" in value or "\r" in value):
            raise ValueError(f"factory release manifest {field} contains a newline")
        lines.append(f"{field}={value}")
    return ("\n".join(lines) + "\n").encode("utf-8")


def _canonical_json(value: object) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _validated_bundle_descriptor(
    value: dict[str, object],
    *,
    target: str,
    environment: str,
    git_sha: str,
    version: str,
    build: int,
) -> tuple[dict[str, object], dict[str, object]]:
    required = {
        "schemaVersion",
        "artifactType",
        "target",
        "environment",
        "firmwareVersion",
        "sourceIdentity",
        "sourceDateEpoch",
        "buildTimestamp",
        "buildAttestation",
        "runtimeAttestation",
        "flashPlan",
    }
    if set(value) != required:
        raise ValueError("factory bundle manifest fields are invalid")
    expected_identity = {
        "schemaVersion": BUNDLE_SCHEMA,
        "artifactType": ARTIFACT_TYPE,
        "target": target,
        "environment": environment,
        "sourceIdentity": git_sha,
        "firmwareVersion": {"version": version, "build": build},
    }
    for field, expected in expected_identity.items():
        if value.get(field) != expected:
            raise ValueError(
                f"factory bundle manifest {field} does not match the release"
            )
    if not isinstance(value.get("sourceDateEpoch"), str) or not value[
        "sourceDateEpoch"
    ].isdigit():
        raise ValueError("factory bundle sourceDateEpoch is invalid")
    if not isinstance(value.get("buildTimestamp"), str) or not value[
        "buildTimestamp"
    ].endswith("Z"):
        raise ValueError("factory bundle buildTimestamp is invalid")

    build_attestation = value.get("buildAttestation")
    if (
        not isinstance(build_attestation, dict)
        or set(build_attestation)
        != {"schema", "file", "size", "sha256", "flashPlanSha256"}
        or not isinstance(build_attestation.get("schema"), int)
        or isinstance(build_attestation.get("schema"), bool)
        or build_attestation.get("file") != "attestation/build-manifest.json"
        or not isinstance(build_attestation.get("size"), int)
        or isinstance(build_attestation.get("size"), bool)
        or not 0 < build_attestation["size"] <= MAX_BUILD_ATTESTATION_BYTES
        or not isinstance(build_attestation.get("sha256"), str)
        or SHA256.fullmatch(build_attestation["sha256"]) is None
        or not isinstance(build_attestation.get("flashPlanSha256"), str)
        or SHA256.fullmatch(build_attestation["flashPlanSha256"]) is None
    ):
        raise ValueError("factory bundle build attestation is invalid")

    runtime_attestation = value.get("runtimeAttestation")
    if (
        not isinstance(runtime_attestation, dict)
        or set(runtime_attestation)
        != {
            "lockSetId",
            "target",
            "manifestSha256",
            "bundleSha256",
            "runtimeProvenanceSha256",
        }
        or any(
            not isinstance(runtime_attestation.get(field), str)
            or SHA256.fullmatch(runtime_attestation[field]) is None
            for field in (
                "manifestSha256",
                "bundleSha256",
                "runtimeProvenanceSha256",
            )
        )
        or any(
            not isinstance(runtime_attestation.get(field), str)
            or SAFE_RUNTIME_ID.fullmatch(runtime_attestation[field]) is None
            for field in ("lockSetId", "target")
        )
    ):
        raise ValueError("factory bundle runtime attestation is invalid")
    _validate_portable_flash_plan(value.get("flashPlan"), target=target)
    return build_attestation, runtime_attestation


def _validate_portable_flash_plan(value: object, *, target: str) -> None:
    if (
        not isinstance(value, dict)
        or set(value)
        != {
            "schemaVersion",
            "chip",
            "applicationOffsetSource",
            "flashCapacity",
            "writeParameters",
            "platformioResolvedParameters",
            "images",
            "mergedImage",
        }
        or value.get("schemaVersion") != BUNDLE_SCHEMA
        or value.get("chip") != "esp32s3"
        or value.get("applicationOffsetSource") != "partition-table"
        or not isinstance(value.get("flashCapacity"), int)
        or isinstance(value.get("flashCapacity"), bool)
        or not 0 < value["flashCapacity"] <= 0x1_0000_0000
        or value.get("writeParameters")
        != {
            "flashMode": "keep",
            "flashFrequency": "keep",
            "flashSize": "keep",
        }
    ):
        raise ValueError("factory bundle flash plan is invalid")
    resolved = value.get("platformioResolvedParameters")
    if (
        not isinstance(resolved, dict)
        or set(resolved) != {"mode", "frequency", "size"}
        or not all(isinstance(item, str) and item for item in resolved.values())
    ):
        raise ValueError("factory bundle resolved flash parameters are invalid")
    images = value.get("images")
    merged = value.get("mergedImage")
    if (
        not isinstance(images, list)
        or not 4 <= len(images) <= 32
        or not isinstance(merged, dict)
        or set(merged) != {"offset", "file", "size", "sha256"}
    ):
        raise ValueError("factory bundle flash image inventory is invalid")

    image_names: set[str] = set()
    image_files: set[str] = set()
    ranges: list[tuple[int, int]] = []
    for record in images:
        if not isinstance(record, dict) or set(record) != {
            "offset",
            "file",
            "size",
            "sha256",
        }:
            raise ValueError("factory bundle flash image record is invalid")
        offset_text = record.get("offset")
        relative = _safe_relative_path(record.get("file"), "factory flash image")
        size = record.get("size")
        digest = record.get("sha256")
        if (
            not isinstance(offset_text, str)
            or CANONICAL_OFFSET.fullmatch(offset_text) is None
            or not isinstance(size, int)
            or isinstance(size, bool)
            or size <= 0
            or not isinstance(digest, str)
            or SHA256.fullmatch(digest) is None
            or relative in image_files
        ):
            raise ValueError("factory bundle flash image contract is invalid")
        offset = int(offset_text, 16)
        portable_name = PORTABLE_IMAGE_NAME.fullmatch(
            pathlib.PurePosixPath(relative).name
        )
        if (
            pathlib.PurePosixPath(relative).parent.as_posix() != "images"
            or portable_name is None
            or int(portable_name.group(1), 16) != offset
            or offset + size > value["flashCapacity"]
        ):
            raise ValueError("factory bundle flash image path is invalid")
        image_files.add(relative)
        image_names.add(portable_name.group(2))
        ranges.append((offset, offset + size))
    if not REQUIRED_IMAGE_NAMES.issubset(image_names):
        raise ValueError("factory bundle is missing a required flash image")
    sorted_ranges = sorted(ranges)
    if any(previous[1] > current[0] for previous, current in zip(sorted_ranges, sorted_ranges[1:])):
        raise ValueError("factory bundle flash images overlap")

    merged_offset = merged.get("offset")
    merged_file = _safe_relative_path(merged.get("file"), "factory merged image")
    merged_size = merged.get("size")
    merged_digest = merged.get("sha256")
    if (
        merged_offset != "0x0"
        or merged_file != f"{target}.factory.bin"
        or not isinstance(merged_size, int)
        or isinstance(merged_size, bool)
        or merged_size != max(end for _, end in ranges)
        or merged_size > value["flashCapacity"]
        or not isinstance(merged_digest, str)
        or SHA256.fullmatch(merged_digest) is None
    ):
        raise ValueError("factory bundle merged image contract is invalid")


def _portable_image_bindings(
    flash_plan: dict[str, object],
) -> list[tuple[int, str, str, int, str]]:
    bindings = []
    for record in flash_plan["images"]:
        relative = str(record["file"])
        match = PORTABLE_IMAGE_NAME.fullmatch(
            pathlib.PurePosixPath(relative).name
        )
        if match is None:
            raise ValueError("factory portable image binding is invalid")
        bindings.append(
            (
                int(str(record["offset"]), 16),
                match.group(2),
                relative,
                int(record["size"]),
                str(record["sha256"]),
            )
        )
    return sorted(bindings)


def _embedded_image_bindings(
    embedded_manifest: dict[str, object],
    *,
    environment: str,
    expected_digest: str,
) -> list[tuple[int, str, int, str]]:
    flash_plan = embedded_manifest.get("flashPlan")
    if (
        not isinstance(flash_plan, dict)
        or flash_plan.get("schema") != 2
        or flash_plan.get("environment") != environment
        or flash_plan.get("applicationOffsetSource") != "partition-table"
        or _sha256_bytes(_canonical_json(flash_plan)) != expected_digest
        or embedded_manifest.get("flashPlanSha256") != expected_digest
        or not isinstance(flash_plan.get("images"), list)
        or not 4 <= len(flash_plan["images"]) <= 32
    ):
        raise ValueError("embedded factory flash plan is invalid")
    command = flash_plan.get("command")
    if not isinstance(command, list) or not all(
        isinstance(item, str) for item in command
    ):
        raise ValueError("embedded factory flash command is invalid")
    if (
        command.count("write-flash") != 1
        or command.count("--chip") != 1
        or command.index("--chip") + 1 >= len(command)
        or command[command.index("--chip") + 1] != "esp32s3"
    ):
        raise ValueError("embedded factory flash command targets another chip")
    for flag in ("--flash-mode", "--flash-freq", "--flash-size"):
        positions = [index for index, item in enumerate(command) if item == flag]
        if (
            len(positions) != 1
            or positions[0] + 1 >= len(command)
            or command[positions[0] + 1] != "keep"
        ):
            raise ValueError("embedded factory flash command is not immutable")

    bindings: list[tuple[int, str, int, str]] = []
    command_tail: list[str] = []
    for record in flash_plan["images"]:
        if not isinstance(record, dict):
            raise ValueError("embedded factory flash image is invalid")
        offset_text = record.get("offset")
        source_path = record.get("path")
        size = record.get("size")
        digest = record.get("sha256")
        if (
            not isinstance(offset_text, str)
            or CANONICAL_OFFSET.fullmatch(offset_text) is None
            or not isinstance(source_path, str)
            or not source_path
            or not isinstance(size, int)
            or isinstance(size, bool)
            or size <= 0
            or not isinstance(digest, str)
            or SHA256.fullmatch(digest) is None
        ):
            raise ValueError("embedded factory flash image contract is invalid")
        basename = pathlib.PurePath(source_path).name
        if not basename or basename in {".", ".."}:
            raise ValueError("embedded factory flash image path is invalid")
        bindings.append((int(offset_text, 16), basename, size, digest))
        command_tail.extend((offset_text, source_path))
    if len(set(bindings)) != len(bindings):
        raise ValueError("embedded factory flash image binding is ambiguous")
    if command[-len(command_tail) :] != command_tail:
        raise ValueError(
            "embedded factory flash command does not match its image set"
        )
    return sorted(bindings)


def _verify_merged_image(
    extracted: pathlib.Path,
    flash_plan: dict[str, object],
) -> None:
    portable = _portable_image_bindings(flash_plan)
    merged_record = flash_plan["mergedImage"]
    merged_path = extracted / str(merged_record["file"])
    if merged_path.is_symlink() or not merged_path.is_file():
        raise ValueError("factory merged image is missing or unsafe")
    cursor = 0
    with merged_path.open("rb") as merged:
        for offset, _, relative, size, _ in portable:
            gap = offset - cursor
            while gap:
                chunk = merged.read(min(gap, COPY_CHUNK_BYTES))
                if not chunk or any(value != 0xFF for value in chunk):
                    raise ValueError("factory merged image gap is not erased")
                gap -= len(chunk)
                cursor += len(chunk)
            image_path = extracted.joinpath(
                *pathlib.PurePosixPath(relative).parts
            )
            remaining = size
            with image_path.open("rb") as image:
                while remaining:
                    expected = image.read(min(remaining, COPY_CHUNK_BYTES))
                    actual = merged.read(len(expected))
                    if not expected or actual != expected:
                        raise ValueError(
                            "factory merged image does not match component images"
                        )
                    remaining -= len(expected)
                    cursor += len(expected)
                if image.read(1):
                    raise ValueError("factory component image size is inconsistent")
        if cursor != merged_record["size"] or merged.read(1):
            raise ValueError("factory merged image size is inconsistent")


def _safe_archive_path(name: str, root_name: str) -> pathlib.PurePosixPath:
    if not name or "\\" in name or name.startswith("/") or "\0" in name:
        raise ValueError(f"factory archive contains an unsafe path: {name!r}")
    path = pathlib.PurePosixPath(name.rstrip("/"))
    if (
        not path.parts
        or path.parts[0] != root_name
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise ValueError(f"factory archive contains an unsafe path: {name!r}")
    return path


def _load_strict_json(path: pathlib.Path, label: str) -> dict[str, object]:
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is invalid: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{label} must contain a JSON object")
    return value


def verify_factory_bundle(
    bundle: pathlib.Path,
    bundle_manifest_path: pathlib.Path,
    bundle_manifest: dict[str, object],
    *,
    target: str,
    environment: str,
    git_sha: str,
    version: str,
    build: int,
) -> tuple[str, str]:
    """Verify the complete portable archive/attestation chain before signing."""
    build_attestation, runtime_attestation = _validated_bundle_descriptor(
        bundle_manifest,
        target=target,
        environment=environment,
        git_sha=git_sha,
        version=version,
        build=build,
    )
    external_descriptor = bundle_manifest_path.read_bytes()
    root_name = f"{target}.factory"
    with tempfile.TemporaryDirectory(prefix=".factory-release-preflight-") as root:
        extraction_root = pathlib.Path(root)
        try:
            with tarfile.open(bundle, mode="r:gz") as archive:
                members = archive.getmembers()
                if not members or len(members) > MAX_ARCHIVE_MEMBERS:
                    raise ValueError("factory archive member count is invalid")
                names: set[str] = set()
                total_size = 0
                for member in members:
                    relative = _safe_archive_path(member.name, root_name)
                    normalized_name = relative.as_posix()
                    if normalized_name in names:
                        raise ValueError(
                            f"factory archive contains a duplicate path: {normalized_name}"
                        )
                    names.add(normalized_name)
                    if not (member.isdir() or member.isfile()):
                        raise ValueError(
                            f"factory archive contains an unsupported member: {normalized_name}"
                        )
                    if member.isfile():
                        if member.size < 0 or member.size > MAX_FACTORY_BUNDLE_BYTES:
                            raise ValueError(
                                f"factory archive member size is invalid: {normalized_name}"
                            )
                        total_size += member.size
                        if total_size > MAX_EXTRACTED_BUNDLE_BYTES:
                            raise ValueError("factory archive expands beyond the size limit")

                for member in members:
                    relative = _safe_archive_path(member.name, root_name)
                    destination = extraction_root.joinpath(*relative.parts)
                    if member.isdir():
                        destination.mkdir(parents=True, exist_ok=True)
                        continue
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    source = archive.extractfile(member)
                    if source is None:
                        raise ValueError(
                            f"factory archive member could not be read: {relative.as_posix()}"
                        )
                    with source, destination.open("xb") as output:
                        shutil.copyfileobj(source, output, COPY_CHUNK_BYTES)
                    if destination.stat().st_size != member.size:
                        raise ValueError(
                            f"factory archive member was truncated: {relative.as_posix()}"
                        )
        except (OSError, tarfile.TarError) as error:
            raise ValueError(f"factory archive is invalid: {error}") from error

        extracted = extraction_root / root_name
        internal_descriptor = extracted / "factory-bundle.json"
        if (
            not internal_descriptor.is_file()
            or internal_descriptor.is_symlink()
            or internal_descriptor.read_bytes() != external_descriptor
        ):
            raise ValueError(
                "factory archive and external bundle manifests are not identical"
            )

        checksum_path = extracted / "SHA256SUMS"
        if checksum_path.is_symlink() or not checksum_path.is_file():
            raise ValueError("factory archive is missing SHA256SUMS")
        try:
            checksum_lines = checksum_path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError) as error:
            raise ValueError(f"factory archive checksums are invalid: {error}") from error
        expected_files = {
            path.relative_to(extracted).as_posix()
            for path in extracted.rglob("*")
            if path.is_file() and path != checksum_path
        }
        observed_files: set[str] = set()
        for line in checksum_lines:
            if "  " not in line:
                raise ValueError("factory archive checksum line is invalid")
            digest, relative_name = line.split("  ", maxsplit=1)
            relative = pathlib.PurePosixPath(relative_name)
            if (
                SHA256.fullmatch(digest) is None
                or not relative.parts
                or any(part in {"", ".", ".."} for part in relative.parts)
                or relative_name in observed_files
            ):
                raise ValueError("factory archive checksum identity is invalid")
            observed_files.add(relative_name)
            candidate = extracted.joinpath(*relative.parts)
            if candidate.is_symlink() or not candidate.is_file():
                raise ValueError(
                    f"factory archive checksum target is invalid: {relative_name}"
                )
            if sha256_hex(candidate) != digest:
                raise ValueError(
                    f"factory archive checksum mismatch: {relative_name}"
                )
        if observed_files != expected_files:
            raise ValueError("factory archive checksum inventory is incomplete")

        attestation_path = extracted.joinpath(
            *pathlib.PurePosixPath(str(build_attestation["file"])).parts
        )
        if (
            attestation_path.is_symlink()
            or not attestation_path.is_file()
            or attestation_path.stat().st_size != build_attestation["size"]
            or sha256_hex(attestation_path) != build_attestation["sha256"]
        ):
            raise ValueError("factory build attestation digest does not match")
        embedded_manifest = _load_strict_json(
            attestation_path, "factory embedded build attestation"
        )
        runtime_provenance = embedded_manifest.get("runtimeProvenance")
        if (
            embedded_manifest.get("schema") != build_attestation["schema"]
            or embedded_manifest.get("sourceIdentity") != git_sha
            or not isinstance(runtime_provenance, dict)
            or runtime_provenance.get("lockSetId")
            != runtime_attestation["lockSetId"]
            or runtime_provenance.get("target") != runtime_attestation["target"]
            or runtime_provenance.get("manifestSha256")
            != runtime_attestation["manifestSha256"]
            or runtime_provenance.get("bundleSha256")
            != runtime_attestation["bundleSha256"]
            or _sha256_bytes(_canonical_json(runtime_provenance))
            != runtime_attestation["runtimeProvenanceSha256"]
        ):
            raise ValueError(
                "factory runtime attestation does not match the embedded build"
            )
        portable_bindings = [
            (offset, basename, size, digest)
            for offset, basename, _, size, digest in _portable_image_bindings(
                bundle_manifest["flashPlan"]
            )
        ]
        embedded_bindings = _embedded_image_bindings(
            embedded_manifest,
            environment=environment,
            expected_digest=str(build_attestation["flashPlanSha256"]),
        )
        if embedded_bindings != portable_bindings:
            raise ValueError(
                "factory portable images do not match the attested flash plan"
            )
        _verify_merged_image(extracted, bundle_manifest["flashPlan"])

    return (
        str(build_attestation["sha256"]),
        str(runtime_attestation["runtimeProvenanceSha256"]),
    )


def write_manifest(args: argparse.Namespace) -> None:
    bundle_input = args.bundle
    bundle_manifest_input = args.bundle_manifest
    if bundle_input.is_symlink() or not bundle_input.is_file():
        raise ValueError(f"factory bundle is missing or unsafe: {bundle_input}")
    if bundle_manifest_input.is_symlink() or not bundle_manifest_input.is_file():
        raise ValueError(
            "factory bundle manifest is missing or unsafe: "
            f"{bundle_manifest_input}"
        )
    bundle = bundle_input.resolve()
    bundle_manifest_path = bundle_manifest_input.resolve()
    bundle_size = bundle.stat().st_size
    if bundle_size <= 0 or bundle_size > MAX_FACTORY_BUNDLE_BYTES:
        raise ValueError("factory bundle has an invalid size")
    if FULL_GIT_SHA.fullmatch(args.git_sha) is None:
        raise ValueError("Git SHA must contain 40 lowercase hex characters")
    if TARGET.fullmatch(args.target) is None:
        raise ValueError(f"unsupported factory target: {args.target}")
    environment = f"{args.target}_PRODUCTION"
    expected_bundle_manifest_name = f"{args.target}.factory-bundle.json"
    if bundle_manifest_path.name != expected_bundle_manifest_name:
        raise ValueError(
            "factory bundle manifest must use the release asset name "
            f"{expected_bundle_manifest_name}"
        )
    metadata = read_firmware_metadata(args.platformio_ini)
    version = args.version or metadata.version
    build = args.build if args.build is not None else metadata.build
    tag = _validated_release_tag(args.tag or f"v{version}", version)
    bundle_manifest_bytes = bundle_manifest_path.read_bytes()
    bundle_manifest = _parse_bundle_manifest(bundle_manifest_bytes)
    expected_asset_name = f"{args.target}.factory.tar.gz"
    if bundle.name != expected_asset_name:
        raise ValueError(
            f"factory bundle must use the release asset name {expected_asset_name}"
        )
    bundle_sha256 = sha256_hex(bundle)
    build_attestation_sha256, runtime_provenance_sha256 = verify_factory_bundle(
        bundle,
        bundle_manifest_path,
        bundle_manifest,
        target=args.target,
        environment=environment,
        git_sha=args.git_sha,
        version=version,
        build=build,
    )
    _validate_factory_archive(
        bundle,
        target=args.target,
        bundle_manifest_bytes=bundle_manifest_bytes,
        bundle_manifest=bundle_manifest,
    )
    if bundle.stat().st_size != bundle_size or sha256_hex(bundle) != bundle_sha256:
        raise ValueError("factory bundle changed while it was being validated")
    if bundle_manifest_path.read_bytes() != bundle_manifest_bytes:
        raise ValueError(
            "factory bundle manifest changed while it was being validated"
        )

    release_url = (
        f"https://github.com/{args.repository}/releases/download/{tag}/{bundle.name}"
    )
    manifest: dict[str, object] = {
        "schemaVersion": RELEASE_SCHEMA,
        "artifactType": ARTIFACT_TYPE,
        "target": args.target,
        "environment": environment,
        "version": version,
        "build": build,
        "gitSha": args.git_sha,
        "assetName": bundle.name,
        "size": bundle_size,
        "sha256": bundle_sha256,
        "bundleManifestName": bundle_manifest_path.name,
        "bundleManifestSha256": hashlib.sha256(
            bundle_manifest_bytes
        ).hexdigest(),
        "buildAttestationSha256": build_attestation_sha256,
        "runtimeProvenanceSha256": runtime_provenance_sha256,
        "url": release_url,
    }
    manifest["signature"] = sign_payload(
        canonical_payload(manifest), args.private_key_base64
    )

    if args.output.is_symlink() or args.output.exists():
        raise ValueError("factory release manifest output must not already exist")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.parent.is_symlink() or not args.output.parent.is_dir():
        raise ValueError("factory release manifest output directory is unsafe")
    temporary_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=args.output.parent,
            prefix=f".{args.output.name}.",
            delete=False,
        ) as stream:
            temporary_name = stream.name
            json.dump(manifest, stream, indent=2)
            stream.write("\n")
        pathlib.Path(temporary_name).replace(args.output)
        temporary_name = None
    finally:
        if temporary_name is not None:
            try:
                pathlib.Path(temporary_name).unlink()
            except OSError:
                pass


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=pathlib.Path, required=True)
    parser.add_argument("--bundle-manifest", type=pathlib.Path, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--git-sha", required=True)
    parser.add_argument("--private-key-base64", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument(
        "--platformio-ini",
        type=pathlib.Path,
        default=pathlib.Path("esp32/platformio.ini"),
    )
    parser.add_argument("--version")
    parser.add_argument("--build", type=int)
    parser.add_argument("--tag")
    args = parser.parse_args(argv)
    try:
        write_manifest(args)
    except (OSError, ValueError) as error:
        print(f"factory release manifest error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
