#!/usr/bin/env python3
"""Maintainer-only validation and packaging helpers for runtime candidates."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
from pathlib import Path
from typing import Sequence

from firmware_runtime import FirmwareRuntimeError, download_verified, load_lock


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_inputs(project_dir: Path) -> dict[str, object]:
    runtime_dir = project_dir / "tools/firmware-runtime"
    lock = load_lock(runtime_dir / "lock-v1.json")
    refresh = runtime_dir / "refresh-inputs.json"
    licenses = runtime_dir / "licenses.json"
    for path in (refresh, licenses):
        if path.is_symlink() or not path.is_file():
            raise FirmwareRuntimeError(f"runtime refresh input is missing or unsafe: {path}")
        json.loads(path.read_text(encoding="utf-8"))
    return {
        "schema": 1,
        "lockSetId": lock.lock_set_id,
        "lockManifestSha256": lock.manifest_sha256,
        "refreshInputsSha256": _sha256(refresh),
        "licensesSha256": _sha256(licenses),
        "targets": [
            {"id": target.target_id, "accepted": target.accepted}
            for target in lock.targets
        ],
    }


def verify_python_input(project_dir: Path, target_id: str, output: Path) -> dict[str, object]:
    lock = load_lock(project_dir / "tools/firmware-runtime/lock-v1.json")
    matches = [target for target in lock.targets if target.target_id == target_id]
    if len(matches) != 1:
        raise FirmwareRuntimeError(f"unknown runtime refresh target: {target_id}")
    target = matches[0]
    download_verified(target.python, output)
    return {
        "schema": 1,
        "target": target.target_id,
        "pythonVersion": target.python_version,
        "size": output.stat().st_size,
        "sha256": _sha256(output),
        "sourceUrl": target.python.url,
    }


def _parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("inspect-inputs", "verify-python"))
    parser.add_argument(
        "--project-dir", type=Path, default=Path(__file__).resolve().parents[1]
    )
    parser.add_argument("--target")
    parser.add_argument("--output", type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        if args.command == "inspect-inputs":
            print(json.dumps(inspect_inputs(args.project_dir), sort_keys=True))
        elif args.command == "verify-python":
            if not args.target or args.output is None:
                raise FirmwareRuntimeError("verify-python requires --target and --output")
            print(json.dumps(
                verify_python_input(args.project_dir, args.target, args.output),
                sort_keys=True,
            ))
        return 0
    except (FirmwareRuntimeError, OSError, json.JSONDecodeError) as error:
        print(f"Runtime refresh failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
