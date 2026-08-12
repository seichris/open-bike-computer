#!/usr/bin/env python3
"""Package an attested production build as a portable factory-flash bundle."""

from __future__ import annotations

import argparse
import configparser
import gzip
import hashlib
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
from pathlib import Path

from firmware_build_identity import build_timestamp_from_source_date_epoch
from generated_sdkconfig import (
    BUILD_MANIFEST_SCHEMA,
    FLASH_PLAN_SCHEMA,
    current_source_identity,
)


BUNDLE_SCHEMA = 1
BUNDLE_ARTIFACT_TYPE = "esp32-factory-flash-bundle"
SUPPORTED_BUILD_MANIFEST_SCHEMA = BUILD_MANIFEST_SCHEMA
SUPPORTED_FLASH_PLAN_SCHEMA = FLASH_PLAN_SCHEMA
SUPPORTED_TARGETS = {
    "WAVESHARE_AMOLED_175",
    "WAVESHARE_AMOLED_206",
}
FULL_GIT_SHA = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SAFE_FILENAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
FLASH_SIZE = re.compile(r"^(?P<count>[1-9][0-9]*)(?P<unit>KB|MB)$")
MAX_MANIFEST_BYTES = 8 * 1024 * 1024
MAX_FACTORY_IMAGE_BYTES = 64 * 1024 * 1024
COPY_CHUNK_BYTES = 1024 * 1024
REQUIRED_IMAGE_HASH_FIELDS = {
    "firmware.bin": "firmwareBinSha256",
    "bootloader.bin": "bootloaderBinSha256",
    "partitions.bin": "partitionTableBinSha256",
    "boot_app0.bin": "bootApp0Sha256",
}


class BundleError(ValueError):
    """Raised when build evidence cannot produce a trustworthy bundle."""


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise BundleError(f"JSON contains duplicate key: {key}")
        value[key] = item
    return value


def _load_json(path: Path) -> tuple[dict[str, object], bytes]:
    if path.is_symlink() or not path.is_file():
        raise BundleError(f"build manifest is missing or unsafe: {path}")
    try:
        encoded = path.read_bytes()
        if not encoded or len(encoded) > MAX_MANIFEST_BYTES:
            raise BundleError(f"build manifest has an invalid size: {path}")
        value = json.loads(
            encoded.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise BundleError(f"could not read build manifest: {error}") from error
    if not isinstance(value, dict):
        raise BundleError("build manifest must contain a JSON object")
    return value, encoded


def _canonical_json(value: object) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def _pretty_json(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(COPY_CHUNK_BYTES), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _parse_offset(value: object) -> int:
    if not isinstance(value, str):
        raise BundleError("flash image offset must be a string")
    try:
        offset = int(value, 0)
    except ValueError as error:
        raise BundleError(f"invalid flash image offset: {value!r}") from error
    if offset < 0 or offset > 0xFFFFFFFF:
        raise BundleError(f"flash image offset is out of range: {value!r}")
    return offset


def _parse_flash_size(value: object) -> int:
    if not isinstance(value, str):
        raise BundleError("PlatformIO flash size must be a string")
    match = FLASH_SIZE.fullmatch(value.upper())
    if match is None:
        raise BundleError(f"unsupported PlatformIO flash size: {value!r}")
    multiplier = 1024 if match.group("unit") == "KB" else 1024 * 1024
    size = int(match.group("count")) * multiplier
    if size > MAX_FACTORY_IMAGE_BYTES:
        raise BundleError(f"PlatformIO flash size is too large: {value!r}")
    return size


def _inherited_config_value(
    config: configparser.ConfigParser,
    section: str,
    option: str,
    stack: tuple[str, ...] = (),
) -> str | None:
    if section in stack:
        raise BundleError(
            "PlatformIO configuration contains an inheritance cycle: "
            + " -> ".join((*stack, section))
        )
    if not config.has_section(section):
        raise BundleError(f"PlatformIO configuration is missing section {section}")
    value = None
    raw_parents = config.get(section, "extends", fallback="")
    parents = [
        token
        for token in re.split(r"[\s,]+", raw_parents.strip())
        if token
    ]
    for parent in parents:
        inherited = _inherited_config_value(
            config, parent, option, (*stack, section)
        )
        if inherited is not None:
            value = inherited
    if config.has_option(section, option):
        value = config.get(section, option)
    return value


def _read_release_metadata(
    platformio_ini: Path,
    expected_sha256: object,
    environment: str,
) -> tuple[dict[str, object], int]:
    if platformio_ini.is_symlink() or not platformio_ini.is_file():
        raise BundleError(f"PlatformIO configuration is unsafe: {platformio_ini}")
    config = configparser.ConfigParser(interpolation=None)
    try:
        encoded = platformio_ini.read_bytes()
        if _sha256_bytes(encoded) != expected_sha256:
            raise BundleError(
                "PlatformIO configuration changed after the verified build"
            )
        config.read_string(encoded.decode("utf-8"))
        version = config.get("common", "version")
        build = config.getint("common", "revision")
    except (OSError, UnicodeError, configparser.Error, ValueError) as error:
        raise BundleError(
            f"could not read firmware release metadata: {error}"
        ) from error
    if not version or build < 0:
        raise BundleError("firmware release metadata is invalid")
    raw_flash_capacity = _inherited_config_value(
        config,
        f"env:{environment}",
        "board_upload.flash_size",
    )
    if raw_flash_capacity is None:
        raise BundleError(
            "production environment does not define a flash capacity"
        )
    return (
        {"version": version, "build": build},
        _parse_flash_size(raw_flash_capacity),
    )


def _require_keep_write_options(command: object) -> None:
    if not isinstance(command, list) or not all(
        isinstance(token, str) for token in command
    ):
        raise BundleError("flash plan command is invalid")
    if command.count("write-flash") != 1:
        raise BundleError("flash plan must contain one write-flash command")
    for option in ("--flash-mode", "--flash-freq", "--flash-size"):
        if command.count(option) != 1:
            raise BundleError(f"flash plan must contain one {option} option")
        index = command.index(option)
        if index + 1 >= len(command) or command[index + 1] != "keep":
            raise BundleError(f"flash plan {option} must preserve attested bytes")


def _validated_images(
    project_dir: Path,
    manifest: dict[str, object],
    flash_plan: dict[str, object],
) -> list[dict[str, object]]:
    raw_images = flash_plan.get("images")
    if not isinstance(raw_images, list) or not 1 <= len(raw_images) <= 32:
        raise BundleError("flash plan image set is invalid")

    images: list[dict[str, object]] = []
    basenames: set[str] = set()
    ranges: list[tuple[int, int, str]] = []
    for raw_image in raw_images:
        if not isinstance(raw_image, dict):
            raise BundleError("flash plan contains an invalid image")
        offset = _parse_offset(raw_image.get("offset"))
        raw_path = raw_image.get("path")
        size = raw_image.get("size")
        digest = raw_image.get("sha256")
        if not isinstance(raw_path, str) or not isinstance(size, int) or size <= 0:
            raise BundleError("flash image path or size is invalid")
        if not isinstance(digest, str) or SHA256.fullmatch(digest) is None:
            raise BundleError("flash image SHA-256 is invalid")
        path = Path(raw_path)
        try:
            path.relative_to(project_dir)
        except ValueError as error:
            raise BundleError(
                f"flash image is outside the firmware project: {path}"
            ) from error
        if (
            not path.is_absolute()
            or path != path.resolve()
            or path.is_symlink()
            or not path.is_file()
        ):
            raise BundleError(f"flash image is missing or unsafe: {path}")
        if path.stat().st_size != size:
            raise BundleError(f"flash image size changed after attestation: {path}")
        if _sha256_file(path) != digest:
            raise BundleError(f"flash image changed after attestation: {path}")
        basename = path.name
        if SAFE_FILENAME.fullmatch(basename) is None or basename in basenames:
            raise BundleError(
                f"flash image basename is unsafe or duplicated: {basename}"
            )
        basenames.add(basename)
        if offset + size > 0x1_0000_0000:
            raise BundleError(f"flash image exceeds the address space: {path}")
        ranges.append((offset, offset + size, basename))
        images.append(
            {
                "offset": offset,
                "source": path,
                "basename": basename,
                "size": size,
                "sha256": digest,
            }
        )

    sorted_ranges = sorted(ranges)
    for previous, current in zip(sorted_ranges, sorted_ranges[1:]):
        if previous[1] > current[0]:
            raise BundleError(
                f"flash images overlap: {previous[2]} and {current[2]}"
            )

    missing = set(REQUIRED_IMAGE_HASH_FIELDS) - basenames
    if missing:
        missing_names = ", ".join(sorted(missing))
        raise BundleError(
            f"flash plan is missing required factory images: {missing_names}"
        )
    for image in images:
        basename = str(image["basename"])
        manifest_field = REQUIRED_IMAGE_HASH_FIELDS.get(basename)
        if (
            manifest_field is not None
            and manifest.get(manifest_field) != image["sha256"]
        ):
            raise BundleError(
                f"build manifest {manifest_field} does not match {basename}"
            )
    return sorted(images, key=lambda image: int(image["offset"]))


def _copy_images_and_merge(
    bundle_root: Path,
    target: str,
    images: list[dict[str, object]],
    flash_capacity: int,
) -> tuple[list[dict[str, object]], dict[str, object]]:
    images_dir = bundle_root / "images"
    images_dir.mkdir(parents=True)
    portable_images: list[dict[str, object]] = []
    copied_images: list[tuple[int, int, Path]] = []
    for image in images:
        offset = int(image["offset"])
        relative = Path("images") / f"{offset:08x}-{image['basename']}"
        destination = bundle_root / relative
        shutil.copyfile(Path(image["source"]), destination)
        if (
            destination.stat().st_size != image["size"]
            or _sha256_file(destination) != image["sha256"]
        ):
            raise BundleError(
                f"flash image changed while packaging: {image['source']}"
            )
        copied_images.append((offset, int(image["size"]), destination))
        portable_images.append(
            {
                "offset": hex(offset),
                "file": relative.as_posix(),
                "size": image["size"],
                "sha256": image["sha256"],
            }
        )

    merged_size = max(int(image["offset"]) + int(image["size"]) for image in images)
    if merged_size > flash_capacity:
        raise BundleError(
            "factory image exceeds the configured flash capacity: "
            f"{merged_size} > {flash_capacity}"
        )
    merged_name = f"{target}.factory.bin"
    merged_path = bundle_root / merged_name
    with merged_path.open("wb") as stream:
        remaining = merged_size
        fill = b"\xff" * COPY_CHUNK_BYTES
        while remaining:
            chunk_size = min(remaining, len(fill))
            stream.write(fill[:chunk_size])
            remaining -= chunk_size
        for offset, _, source_path in copied_images:
            stream.seek(offset)
            with source_path.open("rb") as source:
                shutil.copyfileobj(source, stream, COPY_CHUNK_BYTES)
    return portable_images, {
        "offset": "0x0",
        "file": merged_name,
        "size": merged_size,
        "sha256": _sha256_file(merged_path),
    }


def _write_checksums(bundle_root: Path) -> None:
    checksum_path = bundle_root / "SHA256SUMS"
    files = sorted(
        path
        for path in bundle_root.rglob("*")
        if path.is_file() and path != checksum_path
    )
    lines = [
        f"{_sha256_file(path)}  {path.relative_to(bundle_root).as_posix()}"
        for path in files
    ]
    checksum_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _tar_info(name: str, *, size: int, mode: int, mtime: int) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.size = size
    info.mode = mode
    info.mtime = mtime
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    return info


def _write_deterministic_archive(
    bundle_root: Path, archive_path: Path, source_date_epoch: int
) -> None:
    root_name = bundle_root.name
    with archive_path.open("wb") as raw_stream:
        with gzip.GzipFile(
            filename="",
            mode="wb",
            fileobj=raw_stream,
            mtime=source_date_epoch,
        ) as gzip_stream:
            with tarfile.open(
                fileobj=gzip_stream,
                mode="w",
                format=tarfile.PAX_FORMAT,
            ) as archive:
                directories = [bundle_root]
                directories.extend(
                    sorted(path for path in bundle_root.rglob("*") if path.is_dir())
                )
                for directory in directories:
                    relative = directory.relative_to(bundle_root)
                    name = (
                        root_name
                        if relative == Path(".")
                        else f"{root_name}/{relative.as_posix()}"
                    )
                    info = _tar_info(
                        name + "/", size=0, mode=0o755, mtime=source_date_epoch
                    )
                    info.type = tarfile.DIRTYPE
                    archive.addfile(info)
                files = sorted(
                    candidate
                    for candidate in bundle_root.rglob("*")
                    if candidate.is_file()
                )
                for path in files:
                    relative = path.relative_to(bundle_root).as_posix()
                    info = _tar_info(
                        f"{root_name}/{relative}",
                        size=path.stat().st_size,
                        mode=0o644,
                        mtime=source_date_epoch,
                    )
                    with path.open("rb") as stream:
                        archive.addfile(info, stream)


def package_factory_bundle(
    *,
    project_dir: Path,
    environment: str,
    target: str,
    expected_git_sha: str,
    output_dir: Path,
) -> tuple[Path, Path]:
    """Create and return the deterministic archive and portable bundle manifest."""
    project_dir = project_dir.resolve()
    output_dir = output_dir.resolve()
    expected_git_sha = expected_git_sha.lower()
    if target not in SUPPORTED_TARGETS:
        raise BundleError(f"unsupported factory target: {target}")
    if environment != f"{target}_PRODUCTION":
        raise BundleError(
            "factory bundles require the matching production environment"
        )
    if FULL_GIT_SHA.fullmatch(expected_git_sha) is None:
        raise BundleError("expected Git SHA must contain 40 lowercase hex characters")
    if not project_dir.is_dir() or project_dir.is_symlink():
        raise BundleError(f"PlatformIO project directory is unsafe: {project_dir}")

    manifest_path = (
        project_dir
        / ".pio"
        / "open-bike-build"
        / "builds"
        / environment
        / "current.json"
    )
    manifest, manifest_bytes = _load_json(manifest_path)
    if manifest.get("schema") != SUPPORTED_BUILD_MANIFEST_SCHEMA:
        raise BundleError("unsupported verified build-manifest schema")
    if manifest.get("environment") != environment:
        raise BundleError("verified build references another environment")
    if manifest.get("sourceIdentity") != expected_git_sha:
        raise BundleError("verified build does not match the expected Git SHA")
    if manifest.get("uploadEligible") is not True:
        raise BundleError("verified build is not upload eligible")
    if current_source_identity(project_dir, environment) != expected_git_sha:
        raise BundleError(
            "firmware source changed after the upload-eligible build"
        )
    source_date_epoch = manifest.get("sourceDateEpoch")
    build_timestamp = manifest.get("buildTimestamp")
    try:
        if not isinstance(source_date_epoch, str):
            raise ValueError("SOURCE_DATE_EPOCH must be a string")
        expected_build_timestamp = build_timestamp_from_source_date_epoch(
            source_date_epoch
        )
        archive_mtime = int(source_date_epoch)
    except ValueError as error:
        raise BundleError("verified build clock is invalid") from error
    if (
        build_timestamp != expected_build_timestamp
        or archive_mtime > 0xFFFFFFFF
    ):
        raise BundleError("verified build clock is invalid")

    flash_plan = manifest.get("flashPlan")
    if not isinstance(flash_plan, dict):
        raise BundleError("verified build is missing its flash plan")
    if (
        flash_plan.get("schema") != SUPPORTED_FLASH_PLAN_SCHEMA
        or flash_plan.get("environment") != environment
        or flash_plan.get("applicationOffsetSource") != "partition-table"
    ):
        raise BundleError("verified flash-plan identity is invalid")
    flash_plan_digest = _sha256_bytes(_canonical_json(flash_plan))
    if manifest.get("flashPlanSha256") != flash_plan_digest:
        raise BundleError("verified flash-plan SHA-256 does not match")
    _require_keep_write_options(flash_plan.get("command"))
    resolved_parameters = flash_plan.get("platformioFlashParameters")
    if not isinstance(resolved_parameters, dict) or set(resolved_parameters) != {
        "mode",
        "frequency",
        "size",
    }:
        raise BundleError("PlatformIO flash parameters are invalid")
    if not all(
        isinstance(value, str) and value
        for value in resolved_parameters.values()
    ):
        raise BundleError("PlatformIO flash parameter values are invalid")
    images = _validated_images(project_dir, manifest, flash_plan)
    release, flash_capacity = _read_release_metadata(
        project_dir / "platformio.ini",
        manifest.get("platformioIniSha256"),
        environment,
    )

    archive_output = output_dir / f"{target}.factory.tar.gz"
    manifest_output = output_dir / f"{target}.factory-bundle.json"
    output_dir.mkdir(parents=True, exist_ok=True)
    for path in (archive_output, manifest_output):
        if os.path.lexists(path):
            raise BundleError(f"refusing to overwrite factory release artifact: {path}")

    with tempfile.TemporaryDirectory(
        prefix=".factory-bundle-", dir=output_dir
    ) as temporary:
        temporary_root = Path(temporary)
        bundle_root = temporary_root / f"{target}.factory"
        bundle_root.mkdir()
        attestation_dir = bundle_root / "attestation"
        attestation_dir.mkdir()
        attestation_path = attestation_dir / "build-manifest.json"
        attestation_path.write_bytes(manifest_bytes)
        portable_images, merged_image = _copy_images_and_merge(
            bundle_root, target, images, flash_capacity
        )
        descriptor = {
            "schemaVersion": BUNDLE_SCHEMA,
            "artifactType": BUNDLE_ARTIFACT_TYPE,
            "target": target,
            "environment": environment,
            "firmwareVersion": release,
            "sourceIdentity": expected_git_sha,
            "sourceDateEpoch": source_date_epoch,
            "buildTimestamp": build_timestamp,
            "buildAttestation": {
                "schema": SUPPORTED_BUILD_MANIFEST_SCHEMA,
                "file": "attestation/build-manifest.json",
                "size": attestation_path.stat().st_size,
                "sha256": _sha256_file(attestation_path),
                "flashPlanSha256": flash_plan_digest,
            },
            "flashPlan": {
                "schemaVersion": BUNDLE_SCHEMA,
                "chip": "esp32s3",
                "applicationOffsetSource": "partition-table",
                "flashCapacity": flash_capacity,
                "writeParameters": {
                    "flashMode": "keep",
                    "flashFrequency": "keep",
                    "flashSize": "keep",
                },
                "platformioResolvedParameters": resolved_parameters,
                "images": portable_images,
                "mergedImage": merged_image,
            },
        }
        descriptor_bytes = _pretty_json(descriptor)
        (bundle_root / "factory-bundle.json").write_bytes(descriptor_bytes)
        _write_checksums(bundle_root)

        temporary_archive = temporary_root / archive_output.name
        _write_deterministic_archive(
            bundle_root, temporary_archive, archive_mtime
        )
        temporary_manifest = temporary_root / manifest_output.name
        temporary_manifest.write_bytes(descriptor_bytes)
        os.replace(temporary_archive, archive_output)
        os.replace(temporary_manifest, manifest_output)

    return archive_output, manifest_output


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", type=Path, default=Path.cwd())
    parser.add_argument("--environment", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--expected-git-sha", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        archive, descriptor = package_factory_bundle(
            project_dir=args.project_dir,
            environment=args.environment,
            target=args.target,
            expected_git_sha=args.expected_git_sha,
            output_dir=args.output_dir,
        )
    except (BundleError, OSError) as error:
        print(f"factory bundle error: {error}", file=sys.stderr)
        return 1
    print(f"FACTORY_BUNDLE archive={archive} sha256={_sha256_file(archive)}")
    print(
        "FACTORY_BUNDLE_MANIFEST "
        f"path={descriptor} sha256={_sha256_file(descriptor)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
