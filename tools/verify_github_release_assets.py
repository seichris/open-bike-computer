#!/usr/bin/env python3
"""Fail closed unless GitHub reports the exact local release assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import sys
import tempfile


SHA256 = re.compile(r"^[0-9a-f]{64}$")
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$")


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"release JSON contains duplicate key: {key}")
        value[key] = item
    return value


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_release_assets(
    release_json: pathlib.Path,
    asset_dir: pathlib.Path,
    *,
    require_immutable: bool = False,
) -> dict[str, object]:
    if release_json.is_symlink() or not release_json.is_file():
        raise ValueError("release JSON is missing or unsafe")
    if asset_dir.is_symlink() or not asset_dir.is_dir():
        raise ValueError("release asset directory is missing or unsafe")
    try:
        release = json.loads(
            release_json.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"release JSON is invalid: {error}") from error
    if not isinstance(release, dict) or not isinstance(release.get("assets"), list):
        raise ValueError("release JSON has no asset inventory")

    local: dict[str, dict[str, object]] = {}
    for path in sorted(asset_dir.iterdir(), key=lambda item: item.name):
        if (
            path.is_symlink()
            or not path.is_file()
            or SAFE_NAME.fullmatch(path.name) is None
            or path.name in local
        ):
            raise ValueError(f"local release asset is unsafe: {path.name}")
        local[path.name] = {
            "name": path.name,
            "size": path.stat().st_size,
            "sha256": _sha256(path),
        }
    if not local:
        raise ValueError("local release asset directory is empty")

    remote: dict[str, dict[str, object]] = {}
    for record in release["assets"]:
        if not isinstance(record, dict):
            raise ValueError("GitHub release asset record is invalid")
        name = record.get("name")
        digest = record.get("digest")
        size = record.get("size")
        state = record.get("state")
        if (
            not isinstance(name, str)
            or SAFE_NAME.fullmatch(name) is None
            or name in remote
            or not isinstance(size, int)
            or isinstance(size, bool)
            or size < 0
            or not isinstance(digest, str)
            or not digest.startswith("sha256:")
            or SHA256.fullmatch(digest.removeprefix("sha256:")) is None
            or state != "uploaded"
        ):
            raise ValueError(f"GitHub release asset is invalid: {name!r}")
        remote[name] = {
            "name": name,
            "size": size,
            "sha256": digest.removeprefix("sha256:"),
        }
    if remote != local:
        raise ValueError("GitHub release assets do not exactly match local assets")

    tag = release.get("tag_name")
    release_id = release.get("id")
    if not isinstance(tag, str) or not tag or not isinstance(release_id, int):
        raise ValueError("GitHub release identity is invalid")
    immutable = release.get("immutable")
    if not isinstance(immutable, bool):
        raise ValueError("GitHub release immutable state is invalid")
    if require_immutable and not immutable:
        raise ValueError("GitHub release is not immutable")
    return {
        "schema": 1,
        "releaseId": release_id,
        "tag": tag,
        "immutable": immutable,
        "assets": [local[name] for name in sorted(local)],
    }


def _write_canonical(path: pathlib.Path, value: object) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError("publication receipt output is unsafe")
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as stream:
            temporary_name = stream.name
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
        temporary_name = None
    finally:
        if temporary_name is not None:
            pathlib.Path(temporary_name).unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-json", type=pathlib.Path, required=True)
    parser.add_argument("--asset-dir", type=pathlib.Path, required=True)
    parser.add_argument("--require-immutable", action="store_true")
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    try:
        receipt = verify_release_assets(
            args.release_json,
            args.asset_dir,
            require_immutable=args.require_immutable,
        )
        if args.output is not None:
            _write_canonical(args.output, receipt)
        print(json.dumps(receipt, sort_keys=True))
        return 0
    except (OSError, ValueError) as error:
        print(f"release asset verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
