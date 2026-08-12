#!/usr/bin/env python3
"""Validate and stage reviewed firmware-runtime assets for create-only publication."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import sys
import tempfile
from collections.abc import Sequence

from firmware_runtime import FirmwareRuntimeError
from refresh_firmware_runtime import (
    _canonical,
    _clean_generator_commit,
    _load_candidate_contract,
)


TARGETS = ("linux-x86_64-cp313", "macos-arm64-cp313")
SAFE_ID = re.compile(r"^firmware-runtime-[0-9]{4}-[0-9]{2}-[0-9]{2}-[1-9][0-9]*$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
FULL_GIT_SHA = re.compile(r"^[0-9a-f]{40}$")
ASSET_TEMPLATES = (
    "open-bike-firmware-runtime-{target}.tar.gz",
    "contract-{target}.json",
    "evidence-{target}.json",
    "licenses-{target}.json",
    "offline-replay-{target}.json",
)


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_publication_identity(project_dir: pathlib.Path) -> dict[str, object]:
    path = project_dir / "tools/firmware-runtime/publication-v1.json"
    if path.is_symlink() or not path.is_file():
        raise FirmwareRuntimeError("runtime publication identity is missing or unsafe")
    try:
        value = json.loads(path.read_bytes())
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise FirmwareRuntimeError(
            f"runtime publication identity is invalid: {error}"
        ) from error
    if (
        not isinstance(value, dict)
        or set(value) != {"schema", "lockSetId", "releaseTag"}
        or value.get("schema") != 1
        or not isinstance(value.get("lockSetId"), str)
        or SAFE_ID.fullmatch(value["lockSetId"]) is None
        or value.get("releaseTag") != value["lockSetId"]
        or path.read_bytes() != _canonical(value)
    ):
        raise FirmwareRuntimeError("runtime publication identity contract is invalid")
    return value


def _candidate_dir(root: pathlib.Path, target: str) -> pathlib.Path:
    direct = root / f"firmware-runtime-candidate-{target}"
    if direct.is_dir() and not direct.is_symlink():
        return direct
    if root.name == f"firmware-runtime-candidate-{target}" and root.is_dir():
        return root
    raise FirmwareRuntimeError(f"runtime candidate directory is missing: {target}")


def _safe_file(path: pathlib.Path, label: str) -> pathlib.Path:
    if path.is_symlink() or not path.is_file() or path.stat().st_size <= 0:
        raise FirmwareRuntimeError(f"{label} is missing or unsafe: {path}")
    return path


def _asset_record(path: pathlib.Path) -> dict[str, object]:
    return {"name": path.name, "size": path.stat().st_size, "sha256": _sha256(path)}


def stage_publication(
    project_dir: pathlib.Path,
    candidates_root: pathlib.Path,
    output_dir: pathlib.Path,
) -> dict[str, object]:
    identity = load_publication_identity(project_dir)
    if (
        output_dir.is_symlink()
        or (output_dir.exists() and not output_dir.is_dir())
        or (output_dir.exists() and any(output_dir.iterdir()))
    ):
        raise FirmwareRuntimeError("runtime publication output must be a new empty directory")
    output_dir.mkdir(parents=True, exist_ok=True)
    generator_commit = _clean_generator_commit(project_dir)

    candidate_dirs = {target: _candidate_dir(candidates_root, target) for target in TARGETS}
    input_paths = [
        _safe_file(candidate_dirs[target] / "inputs.json", "candidate inputs")
        for target in TARGETS
    ]
    if input_paths[0].read_bytes() != input_paths[1].read_bytes():
        raise FirmwareRuntimeError("runtime candidates have different inspected inputs")

    source_files: list[pathlib.Path] = [input_paths[0]]
    for target in TARGETS:
        directory = candidate_dirs[target]
        contract_path = _safe_file(
            directory / f"contract-{target}.json", "candidate contract"
        )
        wrapper = _load_candidate_contract(
            project_dir, contract_path, expected_target=target
        )
        if wrapper["generator"].get("commit") != generator_commit:
            raise FirmwareRuntimeError(
                f"runtime candidate was not generated from this exact commit: {target}"
            )
        bundle_name = f"open-bike-firmware-runtime-{target}.tar.gz"
        bundle = _safe_file(directory / bundle_name, "candidate runtime bundle")
        bundle_contract = wrapper["target"].get("bundle")
        if (
            not isinstance(bundle_contract, dict)
            or bundle_contract.get("size") != bundle.stat().st_size
            or bundle_contract.get("sha256") != _sha256(bundle)
            or bundle_contract.get("url", "").split("/")[-1] != bundle_name
            or wrapper["target"].get("id") != target
        ):
            raise FirmwareRuntimeError(
                f"runtime candidate bundle disagrees with its contract: {target}"
            )
        for template in ASSET_TEMPLATES:
            source_files.append(
                _safe_file(directory / template.format(target=target), "candidate asset")
            )

    expected_names = {"inputs.json"} | {
        template.format(target=target)
        for target in TARGETS
        for template in ASSET_TEMPLATES
    }
    if len(source_files) != len(expected_names) or {path.name for path in source_files} != expected_names:
        raise FirmwareRuntimeError("runtime publication asset inventory is invalid")

    for source in source_files:
        destination = output_dir / source.name
        if destination.exists() or destination.is_symlink():
            raise FirmwareRuntimeError(f"runtime publication asset already exists: {source.name}")
        with source.open("rb") as input_stream, destination.open("xb") as output_stream:
            shutil.copyfileobj(input_stream, output_stream, 1024 * 1024)
        if _asset_record(destination) != _asset_record(source):
            raise FirmwareRuntimeError(f"runtime publication copy changed: {source.name}")

    assets = [_asset_record(output_dir / name) for name in sorted(expected_names)]
    return {
        "schema": 1,
        "lockSetId": identity["lockSetId"],
        "releaseTag": identity["releaseTag"],
        "generatorCommit": generator_commit,
        "assets": assets,
    }


def verify_staged_publication(
    project_dir: pathlib.Path,
    asset_dir: pathlib.Path,
    manifest_path: pathlib.Path,
) -> dict[str, object]:
    identity = load_publication_identity(project_dir)
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise FirmwareRuntimeError("runtime publication manifest is missing or unsafe")
    try:
        manifest = json.loads(manifest_path.read_bytes())
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise FirmwareRuntimeError(f"runtime publication manifest is invalid: {error}") from error
    if (
        not isinstance(manifest, dict)
        or set(manifest) != {"schema", "lockSetId", "releaseTag", "generatorCommit", "assets"}
        or manifest.get("schema") != 1
        or manifest.get("lockSetId") != identity["lockSetId"]
        or manifest.get("releaseTag") != identity["releaseTag"]
        or not isinstance(manifest.get("generatorCommit"), str)
        or FULL_GIT_SHA.fullmatch(manifest["generatorCommit"]) is None
        or not isinstance(manifest.get("assets"), list)
        or manifest_path.read_bytes() != _canonical(manifest)
    ):
        raise FirmwareRuntimeError("runtime publication manifest contract is invalid")
    if asset_dir.is_symlink() or not asset_dir.is_dir():
        raise FirmwareRuntimeError("runtime publication asset directory is unsafe")
    observed = []
    for path in sorted(asset_dir.iterdir(), key=lambda item: item.name):
        _safe_file(path, "staged runtime publication asset")
        observed.append(_asset_record(path))
    if observed != manifest["assets"]:
        raise FirmwareRuntimeError("staged runtime publication assets changed in transit")
    return manifest


def _write_canonical(path: pathlib.Path, value: object) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise FirmwareRuntimeError("runtime publication manifest output is unsafe")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as stream:
            temporary_name = stream.name
            stream.write(_canonical(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
        temporary_name = None
    finally:
        if temporary_name is not None:
            pathlib.Path(temporary_name).unlink(missing_ok=True)


def _parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("identity", "stage", "verify-staged"))
    parser.add_argument(
        "--project-dir", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1]
    )
    parser.add_argument("--candidates-root", type=pathlib.Path)
    parser.add_argument("--asset-dir", type=pathlib.Path)
    parser.add_argument("--manifest", type=pathlib.Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        if args.command == "identity":
            result = load_publication_identity(args.project_dir)
        elif args.command == "stage":
            if args.candidates_root is None or args.asset_dir is None or args.manifest is None:
                raise FirmwareRuntimeError("stage requires --candidates-root, --asset-dir, and --manifest")
            result = stage_publication(args.project_dir, args.candidates_root, args.asset_dir)
            _write_canonical(args.manifest, result)
        else:
            if args.asset_dir is None or args.manifest is None:
                raise FirmwareRuntimeError("verify-staged requires --asset-dir and --manifest")
            result = verify_staged_publication(args.project_dir, args.asset_dir, args.manifest)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (FirmwareRuntimeError, OSError, json.JSONDecodeError) as error:
        print(f"runtime publication failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
