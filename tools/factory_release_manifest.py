#!/usr/bin/env python3
"""Generate a signed release manifest for a factory-flash bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
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
    "url",
)
FULL_GIT_SHA = re.compile(r"^[0-9a-f]{40}$")
TARGET = re.compile(r"^WAVESHARE_AMOLED_(?:175|206)$")
MAX_BUNDLE_MANIFEST_BYTES = 1024 * 1024
MAX_FACTORY_BUNDLE_BYTES = 64 * 1024 * 1024
MAX_FACTORY_CONTENT_BYTES = 128 * 1024 * 1024
MAX_FACTORY_ARCHIVE_MEMBERS = 128
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
    expected_identity = {
        "schemaVersion": 1,
        "artifactType": ARTIFACT_TYPE,
        "target": args.target,
        "environment": environment,
        "sourceIdentity": args.git_sha,
        "firmwareVersion": {"version": version, "build": build},
    }
    for field, expected in expected_identity.items():
        if bundle_manifest.get(field) != expected:
            raise ValueError(
                f"factory bundle manifest {field} does not match the release"
            )
    expected_asset_name = f"{args.target}.factory.tar.gz"
    if bundle.name != expected_asset_name:
        raise ValueError(
            f"factory bundle must use the release asset name {expected_asset_name}"
        )
    bundle_sha256 = sha256_hex(bundle)
    _validate_factory_archive(
        bundle,
        target=args.target,
        bundle_manifest_bytes=bundle_manifest_bytes,
        bundle_manifest=bundle_manifest,
    )
    if bundle.stat().st_size != bundle_size or sha256_hex(bundle) != bundle_sha256:
        raise ValueError("factory bundle changed while it was being validated")

    release_url = (
        f"https://github.com/{args.repository}/releases/download/{tag}/{bundle.name}"
    )
    manifest: dict[str, object] = {
        "schemaVersion": 1,
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
        "url": release_url,
    }
    manifest["signature"] = sign_payload(
        canonical_payload(manifest), args.private_key_base64
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
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
