#!/usr/bin/env python3
"""Record and verify the exact secretless firmware release candidate files."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import struct
import sys
import tempfile
import zipfile


TARGET_ENVIRONMENTS = {
    "WAVESHARE_AMOLED_175": "WAVESHARE_AMOLED_175_PRODUCTION",
    "WAVESHARE_AMOLED_206": "WAVESHARE_AMOLED_206_PRODUCTION",
}
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
RELEASE_TAG = re.compile(
    r"^v[0-9]+\.[0-9]+\.[0-9]+(?:[.-][A-Za-z0-9][A-Za-z0-9.-]*)?$"
)
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
MAX_FILE_BYTES = {
    ".bin": 16 * 1024 * 1024,
    ".factory.tar.gz": 64 * 1024 * 1024,
    ".factory-bundle.json": 1024 * 1024,
}
MAX_RECEIPT_BYTES = 64 * 1024
MAX_ARTIFACT_ARCHIVE_BYTES = 96 * 1024 * 1024
MAX_ZIP_METADATA_BYTES = 4096


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"JSON contains duplicate key: {key}")
        value[key] = item
    return value


def _load_json(path: pathlib.Path, maximum_bytes: int) -> dict[str, object]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"JSON file is missing or unsafe: {path}")
    encoded = path.read_bytes()
    if not encoded or len(encoded) > maximum_bytes:
        raise ValueError(f"JSON file has an invalid size: {path}")
    try:
        value = json.loads(
            encoded.decode("utf-8"), object_pairs_hook=_reject_duplicate_keys
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"JSON file is invalid: {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"JSON file must contain an object: {path}")
    return value


def _canonical(value: object) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")


def _write_atomic(path: pathlib.Path, value: object) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"output path is unsafe: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as stream:
            temporary = stream.name
            stream.write(_canonical(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            pathlib.Path(temporary).unlink(missing_ok=True)


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _identity(
    *, target: str, environment: str, repository: str, tag: str, git_sha: str
) -> None:
    if target not in TARGET_ENVIRONMENTS:
        raise ValueError(f"unsupported release target: {target}")
    if environment != TARGET_ENVIRONMENTS[target]:
        raise ValueError("candidate environment does not match its target")
    if REPOSITORY.fullmatch(repository) is None:
        raise ValueError("candidate repository is invalid")
    if RELEASE_TAG.fullmatch(tag) is None:
        raise ValueError("candidate release tag is invalid")
    if FULL_SHA.fullmatch(git_sha) is None:
        raise ValueError("candidate Git SHA is invalid")


def _expected_names(target: str) -> tuple[str, str, str]:
    return (
        f"{target}.bin",
        f"{target}.factory-bundle.json",
        f"{target}.factory.tar.gz",
    )


def _zip_entry_count(path: pathlib.Path) -> int:
    size = path.stat().st_size
    tail_size = min(size, 65_557)
    with path.open("rb") as stream:
        stream.seek(size - tail_size)
        tail = stream.read(tail_size)
    marker = tail.rfind(b"PK\x05\x06")
    if marker < 0 or marker + 22 > len(tail):
        raise ValueError("candidate artifact ZIP has no bounded end record")
    (
        signature,
        disk,
        central_disk,
        disk_entries,
        total_entries,
        central_size,
        central_offset,
        comment_size,
    ) = struct.unpack_from("<4s4H2LH", tail, marker)
    absolute_marker = size - tail_size + marker
    if (
        signature != b"PK\x05\x06"
        or disk != 0
        or central_disk != 0
        or disk_entries != total_entries
        or total_entries != 4
        or central_size in {0, 0xFFFFFFFF}
        or central_offset == 0xFFFFFFFF
        or central_offset + central_size != absolute_marker
        or absolute_marker + 22 + comment_size != size
        or comment_size > MAX_ZIP_METADATA_BYTES
    ):
        raise ValueError("candidate artifact ZIP directory is invalid")
    return total_entries


def extract_candidate_archive(
    archive: pathlib.Path, output_dir: pathlib.Path, *, target: str
) -> None:
    if target not in TARGET_ENVIRONMENTS:
        raise ValueError(f"unsupported release target: {target}")
    if archive.is_symlink() or not archive.is_file():
        raise ValueError("candidate artifact ZIP is missing or unsafe")
    archive_size = archive.stat().st_size
    if archive_size <= 0 or archive_size > MAX_ARTIFACT_ARCHIVE_BYTES:
        raise ValueError("candidate artifact ZIP has an invalid size")
    if output_dir.is_symlink() or output_dir.exists():
        raise ValueError("candidate extraction path must not already exist")
    _zip_entry_count(archive)
    expected = {*_expected_names(target), "candidate-receipt.json"}
    output_dir.mkdir(parents=True)
    try:
        with zipfile.ZipFile(archive) as bundle:
            infos = bundle.infolist()
            names = {info.filename for info in infos}
            if len(infos) != len(expected) or names != expected:
                raise ValueError("candidate artifact ZIP file set is not exact")
            for info in infos:
                maximum = (
                    MAX_RECEIPT_BYTES
                    if info.filename == "candidate-receipt.json"
                    else _file_limit(info.filename)
                )
                unix_mode = (info.external_attr >> 16) & 0xFFFF
                if (
                    info.is_dir()
                    or info.flag_bits & 0x1
                    or info.compress_type
                    not in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}
                    or info.file_size <= 0
                    or info.file_size > maximum
                    or info.compress_size > MAX_ARTIFACT_ARCHIVE_BYTES
                    or len(info.extra) > MAX_ZIP_METADATA_BYTES
                    or len(info.comment) > MAX_ZIP_METADATA_BYTES
                    or (unix_mode and not stat.S_ISREG(unix_mode))
                ):
                    raise ValueError("candidate artifact ZIP entry is unsafe")
                destination = output_dir / info.filename
                copied = 0
                with bundle.open(info, "r") as source, destination.open("xb") as output:
                    while True:
                        chunk = source.read(min(1024 * 1024, maximum - copied + 1))
                        if not chunk:
                            break
                        copied += len(chunk)
                        if copied > maximum:
                            raise ValueError(
                                "candidate artifact ZIP entry is oversized"
                            )
                        output.write(chunk)
                if copied != info.file_size:
                    raise ValueError("candidate artifact ZIP entry is truncated")
    except Exception:
        shutil.rmtree(output_dir, ignore_errors=True)
        raise


def _regular_files(directory: pathlib.Path) -> dict[str, pathlib.Path]:
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"candidate directory is missing or unsafe: {directory}")
    files: dict[str, pathlib.Path] = {}
    for path in directory.iterdir():
        if path.is_symlink() or not path.is_file() or path.name in files:
            raise ValueError(f"candidate file is unsafe: {path.name}")
        files[path.name] = path
    return files


def _file_limit(name: str) -> int:
    for suffix, maximum in MAX_FILE_BYTES.items():
        if name.endswith(suffix):
            return maximum
    raise ValueError(f"candidate filename is unsupported: {name}")


def _validate_factory_descriptor(
    descriptor_path: pathlib.Path,
    firmware_path: pathlib.Path,
    *,
    target: str,
    environment: str,
    git_sha: str,
    tag: str,
) -> dict[str, object]:
    descriptor = _load_json(descriptor_path, MAX_FILE_BYTES[".factory-bundle.json"])
    firmware_version = descriptor.get("firmwareVersion")
    if (
        descriptor.get("schemaVersion") != 2
        or descriptor.get("artifactType") != "esp32-factory-flash-bundle"
        or descriptor.get("target") != target
        or descriptor.get("environment") != environment
        or descriptor.get("sourceIdentity") != git_sha
        or not isinstance(firmware_version, dict)
    ):
        raise ValueError("factory descriptor identity does not match the candidate")
    version = firmware_version.get("version")
    build = firmware_version.get("build")
    if (
        not isinstance(version, str)
        or VERSION.fullmatch(version) is None
        or not (
            tag == f"v{version}"
            or tag.startswith(f"v{version}.")
            or tag.startswith(f"v{version}-")
        )
        or isinstance(build, bool)
        or not isinstance(build, int)
        or build < 0
    ):
        raise ValueError("factory descriptor firmware version is invalid")
    flash_plan = descriptor.get("flashPlan")
    if not isinstance(flash_plan, dict) or not isinstance(
        flash_plan.get("images"), list
    ):
        raise ValueError("factory descriptor has no flash image inventory")
    application_images = []
    for image in flash_plan["images"]:
        if not isinstance(image, dict):
            raise ValueError("factory descriptor contains an invalid image")
        name = image.get("file")
        if isinstance(name, str) and name.endswith("-firmware.bin"):
            application_images.append(image)
    if len(application_images) != 1:
        raise ValueError("factory descriptor must identify one application image")
    application = application_images[0]
    if (
        application.get("size") != firmware_path.stat().st_size
        or application.get("sha256") != _sha256(firmware_path)
    ):
        raise ValueError("OTA image does not match the factory application image")
    return {"version": version, "build": build}


def candidate_receipt(
    directory: pathlib.Path,
    *,
    target: str,
    environment: str,
    repository: str,
    tag: str,
    git_sha: str,
    allow_embedded_receipt: bool = False,
) -> dict[str, object]:
    _identity(
        target=target,
        environment=environment,
        repository=repository,
        tag=tag,
        git_sha=git_sha,
    )
    files = _regular_files(directory)
    if allow_embedded_receipt:
        files.pop("candidate-receipt.json", None)
    expected = set(_expected_names(target))
    if set(files) != expected:
        raise ValueError("candidate artifact directory has an unexpected file set")
    inventory: list[dict[str, object]] = []
    for name in sorted(expected):
        path = files[name]
        size = path.stat().st_size
        if size <= 0 or size > _file_limit(name):
            raise ValueError(f"candidate artifact size is invalid: {name}")
        inventory.append({"name": name, "size": size, "sha256": _sha256(path)})
    firmware_version = _validate_factory_descriptor(
        files[f"{target}.factory-bundle.json"],
        files[f"{target}.bin"],
        target=target,
        environment=environment,
        git_sha=git_sha,
        tag=tag,
    )
    return {
        "schemaVersion": 1,
        "repository": repository,
        "tag": tag,
        "gitSha": git_sha,
        "target": target,
        "environment": environment,
        "firmwareVersion": firmware_version,
        "files": inventory,
    }


def record_candidate(
    directory: pathlib.Path,
    output: pathlib.Path,
    *,
    target: str,
    environment: str,
    repository: str,
    tag: str,
    git_sha: str,
) -> dict[str, object]:
    receipt = candidate_receipt(
        directory,
        target=target,
        environment=environment,
        repository=repository,
        tag=tag,
        git_sha=git_sha,
    )
    _write_atomic(output, receipt)
    return receipt


def verify_candidates(
    artifact_root: pathlib.Path,
    release_assets: pathlib.Path,
    output_receipt: pathlib.Path,
    *,
    repository: str,
    tag: str,
    git_sha: str,
    run_id: int,
) -> dict[str, object]:
    if run_id <= 0:
        raise ValueError("candidate run ID is invalid")
    if artifact_root.is_symlink() or not artifact_root.is_dir():
        raise ValueError("candidate artifact root is missing or unsafe")
    directories = {path.name: path for path in artifact_root.iterdir()}
    expected_directories = {f"firmware-{target}" for target in TARGET_ENVIRONMENTS}
    if set(directories) != expected_directories or any(
        path.is_symlink() or not path.is_dir() for path in directories.values()
    ):
        raise ValueError("downloaded candidate artifact set is not exact")
    if release_assets.is_symlink() or release_assets.exists():
        raise ValueError("release asset staging path must not already exist")
    release_assets.mkdir(parents=True)

    receipts: list[dict[str, object]] = []
    try:
        for target, environment in TARGET_ENVIRONMENTS.items():
            directory = directories[f"firmware-{target}"]
            files = _regular_files(directory)
            receipt_path = files.pop("candidate-receipt.json", None)
            if receipt_path is None or receipt_path.stat().st_size > MAX_RECEIPT_BYTES:
                raise ValueError("candidate receipt is missing or oversized")
            observed = _load_json(receipt_path, MAX_RECEIPT_BYTES)
            if receipt_path.read_bytes() != _canonical(observed):
                raise ValueError("candidate receipt is not canonical")
            expected = candidate_receipt(
                directory,
                target=target,
                environment=environment,
                repository=repository,
                tag=tag,
                git_sha=git_sha,
                allow_embedded_receipt=True,
            )
            if observed != expected:
                raise ValueError("candidate receipt does not match its files")
            receipts.append(expected)
            for name in _expected_names(target):
                source = directory / name
                destination = release_assets / name
                shutil.copyfile(source, destination)
                if (
                    destination.stat().st_size != source.stat().st_size
                    or _sha256(destination) != _sha256(source)
                ):
                    raise ValueError("candidate changed while staging release assets")
    except Exception:
        shutil.rmtree(release_assets, ignore_errors=True)
        raise

    combined = {
        "schemaVersion": 1,
        "repository": repository,
        "tag": tag,
        "gitSha": git_sha,
        "candidateRunId": run_id,
        "targets": receipts,
    }
    versions = {
        (
            str(receipt["firmwareVersion"]["version"]),
            int(receipt["firmwareVersion"]["build"]),
        )
        for receipt in receipts
    }
    if len(versions) != 1:
        shutil.rmtree(release_assets, ignore_errors=True)
        raise ValueError("candidate targets do not share one firmware version")
    version, build = versions.pop()
    combined["firmwareVersion"] = {"version": version, "build": build}
    _write_atomic(output_receipt, combined)
    return combined


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    record = subparsers.add_parser("record")
    record.add_argument("--artifact-dir", type=pathlib.Path, required=True)
    record.add_argument("--output", type=pathlib.Path, required=True)
    record.add_argument("--target", required=True)
    record.add_argument("--environment", required=True)
    record.add_argument("--repository", required=True)
    record.add_argument("--tag", required=True)
    record.add_argument("--git-sha", required=True)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--artifact-root", type=pathlib.Path, required=True)
    verify.add_argument("--release-assets", type=pathlib.Path, required=True)
    verify.add_argument("--output-receipt", type=pathlib.Path, required=True)
    verify.add_argument("--repository", required=True)
    verify.add_argument("--tag", required=True)
    verify.add_argument("--git-sha", required=True)
    verify.add_argument("--run-id", type=int, required=True)
    extract = subparsers.add_parser("extract")
    extract.add_argument("--archive", type=pathlib.Path, required=True)
    extract.add_argument("--output-dir", type=pathlib.Path, required=True)
    extract.add_argument("--target", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "record":
            result = record_candidate(
                args.artifact_dir,
                args.output,
                target=args.target,
                environment=args.environment,
                repository=args.repository,
                tag=args.tag,
                git_sha=args.git_sha,
            )
        elif args.command == "verify":
            result = verify_candidates(
                args.artifact_root,
                args.release_assets,
                args.output_receipt,
                repository=args.repository,
                tag=args.tag,
                git_sha=args.git_sha,
                run_id=args.run_id,
            )
        else:
            extract_candidate_archive(
                args.archive, args.output_dir, target=args.target
            )
            result = {"target": args.target, "output": str(args.output_dir)}
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"firmware candidate validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
