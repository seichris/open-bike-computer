#!/usr/bin/env python3
"""Generate and sign firmware release manifests."""

from __future__ import annotations

import argparse
import base64
import configparser
import hashlib
import json
import pathlib
import sys
from dataclasses import dataclass

try:
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ec
except ImportError as exc:  # pragma: no cover - exercised in CI by dependency install
    raise SystemExit(
        "cryptography is required: python -m pip install cryptography"
    ) from exc


SIGNATURE_FIELDS = (
    "schemaVersion",
    "target",
    "version",
    "build",
    "gitSha",
    "size",
    "sha256",
    "url",
    "minUpdaterProtocol",
)


@dataclass(frozen=True)
class FirmwareMetadata:
    version: str
    build: int


def read_firmware_metadata(platformio_ini: pathlib.Path) -> FirmwareMetadata:
    config = configparser.ConfigParser()
    with platformio_ini.open("r", encoding="utf-8") as handle:
        config.read_file(handle)
    return FirmwareMetadata(
        version=config.get("common", "version"),
        build=config.getint("common", "revision"),
    )


def sha256_hex(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_payload(manifest: dict[str, object]) -> bytes:
    lines = []
    for field in SIGNATURE_FIELDS:
        if field not in manifest:
            raise ValueError(f"manifest is missing {field}")
        lines.append(f"{field}={manifest[field]}")
    return ("\n".join(lines) + "\n").encode("utf-8")


def _private_key(private_key_base64: str) -> ec.EllipticCurvePrivateKey:
    key_bytes = base64.b64decode(private_key_base64, validate=True)
    if len(key_bytes) != 32:
        raise ValueError("P-256 private scalar must be 32 raw bytes encoded as base64")
    private_value = int.from_bytes(key_bytes, byteorder="big")
    if private_value <= 0:
        raise ValueError("P-256 private scalar must be greater than zero")
    return ec.derive_private_key(private_value, ec.SECP256R1())


def _sign_payload(
    payload: bytes, private_key: ec.EllipticCurvePrivateKey
) -> str:
    signature = private_key.sign(payload, ec.ECDSA(hashes.SHA256()))
    return base64.b64encode(signature).decode("ascii")


def sign_payload(payload: bytes, private_key_base64: str) -> str:
    """Sign an already canonicalized release payload with the release key."""
    return _sign_payload(payload, _private_key(private_key_base64))


def sign_manifest(manifest: dict[str, object], private_key_base64: str) -> str:
    # Validate the private scalar before the payload to preserve the fail-closed
    # key-validation behavior used by release tooling and tests.
    private_key = _private_key(private_key_base64)
    return _sign_payload(canonical_payload(manifest), private_key)


def write_manifest(args: argparse.Namespace) -> None:
    firmware = args.firmware.resolve()
    if not firmware.is_file():
        raise SystemExit(f"firmware image not found: {firmware}")

    metadata = read_firmware_metadata(args.platformio_ini)
    version = args.version or metadata.version
    build = args.build if args.build is not None else metadata.build
    tag = args.tag or f"v{version}"
    asset_name = args.asset_name or f"{args.target}.bin"
    release_url = (
        f"https://github.com/{args.repository}/releases/download/{tag}/{asset_name}"
    )

    manifest: dict[str, object] = {
        "schemaVersion": 1,
        "target": args.target,
        "version": version,
        "build": build,
        "gitSha": args.git_sha,
        "size": firmware.stat().st_size,
        "sha256": sha256_hex(firmware),
        "url": release_url,
        "minUpdaterProtocol": args.min_updater_protocol,
    }
    manifest["signature"] = sign_manifest(manifest, args.private_key_base64)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--firmware", type=pathlib.Path, required=True)
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
    parser.add_argument("--asset-name")
    parser.add_argument("--min-updater-protocol", type=int, default=1)
    args = parser.parse_args(argv)
    write_manifest(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
