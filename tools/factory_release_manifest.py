#!/usr/bin/env python3
"""Generate a signed release manifest for a factory-flash bundle."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
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


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"JSON contains duplicate key: {key}")
        value[key] = item
    return value


def read_bundle_manifest(path: pathlib.Path) -> dict[str, object]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"factory bundle manifest is missing or unsafe: {path}")
    try:
        encoded = path.read_bytes()
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
    bundle_manifest = read_bundle_manifest(bundle_manifest_path)
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

    tag = args.tag or f"v{version}"
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
        "sha256": sha256_hex(bundle),
        "bundleManifestName": bundle_manifest_path.name,
        "bundleManifestSha256": sha256_hex(bundle_manifest_path),
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
