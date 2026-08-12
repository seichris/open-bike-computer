#!/usr/bin/env python3
"""Create the canonical human-review summary for a runtime refresh candidate."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import sys
import tempfile
from typing import Any

from firmware_runtime import FirmwareRuntimeError, load_lock
from firmware_runtime_publication import TARGETS, load_publication_identity
from refresh_firmware_runtime import _canonical


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _load_json(path: pathlib.Path, label: str) -> dict[str, object]:
    if path.is_symlink() or not path.is_file():
        raise FirmwareRuntimeError(f"{label} is missing or unsafe: {path}")
    try:
        value = json.loads(path.read_bytes())
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise FirmwareRuntimeError(f"{label} is invalid: {error}") from error
    if not isinstance(value, dict):
        raise FirmwareRuntimeError(f"{label} must be a JSON object")
    return value


def _target_map(lock: dict[str, object]) -> dict[str, dict[str, object]]:
    targets = lock.get("targets")
    if not isinstance(targets, list):
        raise FirmwareRuntimeError("runtime lock target inventory is invalid")
    result = {}
    for target in targets:
        if not isinstance(target, dict) or not isinstance(target.get("id"), str):
            raise FirmwareRuntimeError("runtime lock target is invalid")
        if target["id"] in result:
            raise FirmwareRuntimeError("runtime lock target identity is ambiguous")
        result[target["id"]] = target
    return result


def _wheel_map(target: dict[str, object]) -> dict[str, dict[str, object]]:
    contents = target.get("contents")
    wheels = contents.get("wheels") if isinstance(contents, dict) else None
    if not isinstance(wheels, list):
        raise FirmwareRuntimeError("runtime wheel inventory is invalid")
    result = {}
    for wheel in wheels:
        if not isinstance(wheel, dict) or not isinstance(wheel.get("normalizedName"), str):
            raise FirmwareRuntimeError("runtime wheel record is invalid")
        version = wheel.get("version")
        if not isinstance(version, str):
            raise FirmwareRuntimeError("runtime wheel version is invalid")
        key = f"{wheel['normalizedName']}=={version}"
        if key in result:
            raise FirmwareRuntimeError(f"runtime wheel identity is ambiguous: {key}")
        result[key] = wheel
    return result


def _changes(before: dict[str, Any], after: dict[str, Any]) -> dict[str, object]:
    before_keys = set(before)
    after_keys = set(after)
    return {
        "added": [{"name": key, "candidate": after[key]} for key in sorted(after_keys - before_keys)],
        "removed": [{"name": key, "baseline": before[key]} for key in sorted(before_keys - after_keys)],
        "changed": [
            {"name": key, "baseline": before[key], "candidate": after[key]}
            for key in sorted(before_keys & after_keys)
            if before[key] != after[key]
        ],
    }


def _license_map(directory: pathlib.Path) -> dict[str, dict[str, object]]:
    result: dict[str, dict[str, object]] = {}
    for target in TARGETS:
        report = _load_json(directory / f"licenses-{target}.json", "runtime license report")
        wheels = report.get("wheels")
        if not isinstance(wheels, list):
            raise FirmwareRuntimeError("runtime license report wheel inventory is invalid")
        for wheel in wheels:
            if not isinstance(wheel, dict):
                raise FirmwareRuntimeError("runtime license record is invalid")
            name = wheel.get("name")
            version = wheel.get("version")
            if not isinstance(name, str) or not isinstance(version, str):
                raise FirmwareRuntimeError("runtime license identity is invalid")
            key = f"{target}:{name}=={version}"
            if key in result:
                raise FirmwareRuntimeError(f"runtime license identity is ambiguous: {key}")
            result[key] = wheel
    return result


def _candidate_license_map(candidate_root: pathlib.Path) -> dict[str, dict[str, object]]:
    result: dict[str, dict[str, object]] = {}
    for target in TARGETS:
        directory = candidate_root / f"firmware-runtime-candidate-{target}"
        report = _load_json(directory / f"licenses-{target}.json", "candidate license report")
        wheels = report.get("wheels")
        if not isinstance(wheels, list):
            raise FirmwareRuntimeError("candidate license report wheel inventory is invalid")
        for wheel in wheels:
            if not isinstance(wheel, dict):
                raise FirmwareRuntimeError("candidate license record is invalid")
            name, version = wheel.get("name"), wheel.get("version")
            if not isinstance(name, str) or not isinstance(version, str):
                raise FirmwareRuntimeError("candidate license identity is invalid")
            key = f"{target}:{name}=={version}"
            if key in result:
                raise FirmwareRuntimeError(
                    f"candidate license identity is ambiguous: {key}"
                )
            result[key] = wheel
    return result


def create_summary(
    project_dir: pathlib.Path,
    baseline_lock_path: pathlib.Path,
    candidate_lock_path: pathlib.Path,
    baseline_license_dir: pathlib.Path,
    candidate_root: pathlib.Path,
    validation_root: pathlib.Path,
) -> dict[str, object]:
    load_lock(baseline_lock_path)
    load_lock(candidate_lock_path)
    baseline = _load_json(baseline_lock_path, "baseline runtime lock")
    candidate = _load_json(candidate_lock_path, "candidate runtime lock")
    identity = load_publication_identity(project_dir)
    if candidate.get("lockSetId") != identity["lockSetId"]:
        raise FirmwareRuntimeError("candidate lock does not match publication identity")
    baseline_targets = _target_map(baseline)
    candidate_targets = _target_map(candidate)
    if set(candidate_targets) != set(TARGETS):
        raise FirmwareRuntimeError("candidate summary requires both supported targets")

    target_changes: dict[str, object] = {}
    evidence: dict[str, object] = {}
    proposed_assets: list[dict[str, object]] = []
    for target in TARGETS:
        before = baseline_targets.get(target)
        after = candidate_targets[target]
        if before is None:
            raise FirmwareRuntimeError(f"baseline target is missing: {target}")
        before_contents = before["contents"]
        after_contents = after["contents"]
        target_changes[target] = {
            "targetIdentityChanged": {
                "baseline": {key: before.get(key) for key in ("os", "architecture", "abi", "pythonVersion", "minimumPlatformTag")},
                "candidate": {key: after.get(key) for key in ("os", "architecture", "abi", "pythonVersion", "minimumPlatformTag")},
            },
            "bundleChanged": {"baseline": before.get("bundle"), "candidate": after.get("bundle")},
            "platformChanged": {"baseline": before_contents.get("platform"), "candidate": after_contents.get("platform")},
            "distributionSets": _changes(
                before_contents.get("distributionSets", {}),
                after_contents.get("distributionSets", {}),
            ),
            "wheels": _changes(_wheel_map(before), _wheel_map(after)),
        }
        candidate_dir = candidate_root / f"firmware-runtime-candidate-{target}"
        validation_dir = validation_root / f"firmware-build-validation-{target}"
        if candidate_dir.is_symlink() or not candidate_dir.is_dir() or validation_dir.is_symlink() or not validation_dir.is_dir():
            raise FirmwareRuntimeError(f"runtime review evidence is incomplete: {target}")
        validation_paths = sorted(validation_dir.rglob("*"))
        if any(path.is_symlink() for path in validation_paths):
            raise FirmwareRuntimeError(
                f"runtime review evidence contains a symlink: {target}"
            )
        evidence[target] = {
            "candidate": _load_json(candidate_dir / f"evidence-{target}.json", "candidate evidence"),
            "offlineReplay": _load_json(candidate_dir / f"offline-replay-{target}.json", "offline replay evidence"),
            "validationFiles": [
                {
                    "name": path.relative_to(validation_dir).as_posix(),
                    "size": path.stat().st_size,
                    "sha256": _sha256(path),
                }
                for path in validation_paths
                if path.is_file()
            ],
        }
        for template in (
            "open-bike-firmware-runtime-{target}.tar.gz",
            "contract-{target}.json",
            "evidence-{target}.json",
            "licenses-{target}.json",
            "offline-replay-{target}.json",
        ):
            path = candidate_dir / template.format(target=target)
            if path.is_symlink() or not path.is_file():
                raise FirmwareRuntimeError(f"proposed publication asset is missing: {path.name}")
            proposed_assets.append({"name": path.name, "size": path.stat().st_size, "sha256": _sha256(path)})
    input_paths = [
        candidate_root / f"firmware-runtime-candidate-{target}" / "inputs.json"
        for target in TARGETS
    ]
    for input_path in input_paths:
        if input_path.is_symlink() or not input_path.is_file():
            raise FirmwareRuntimeError("candidate input report is missing or unsafe")
    if input_paths[0].read_bytes() != input_paths[1].read_bytes():
        raise FirmwareRuntimeError("candidate input reports are not identical")
    proposed_assets.append(
        {
            "name": "inputs.json",
            "size": input_paths[0].stat().st_size,
            "sha256": _sha256(input_paths[0]),
        }
    )

    return {
        "schema": 1,
        "baseline": {"lockSetId": baseline.get("lockSetId"), "generator": baseline.get("generator")},
        "candidate": {"lockSetId": candidate.get("lockSetId"), "releaseTag": identity["releaseTag"], "generator": candidate.get("generator")},
        "reproducibility": {"nativeCandidateAEqualsB": True, "nativeBuildValidation": True},
        "targetChanges": target_changes,
        "licenses": _changes(
            _license_map(baseline_license_dir),
            _candidate_license_map(candidate_root),
        ),
        "evidence": evidence,
        "proposedAssets": sorted(proposed_assets, key=lambda item: item["name"]),
    }
def _write(path: pathlib.Path, value: object) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise FirmwareRuntimeError("runtime review summary output is unsafe")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(mode="wb", dir=path.parent, prefix=f".{path.name}.", delete=False) as stream:
            temporary_name = stream.name
            stream.write(_canonical(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
        temporary_name = None
    finally:
        if temporary_name is not None:
            pathlib.Path(temporary_name).unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-dir", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument("--baseline-lock", type=pathlib.Path, required=True)
    parser.add_argument("--candidate-lock", type=pathlib.Path, required=True)
    parser.add_argument("--baseline-license-dir", type=pathlib.Path, required=True)
    parser.add_argument("--candidate-root", type=pathlib.Path, required=True)
    parser.add_argument("--validation-root", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        value = create_summary(
            args.project_dir,
            args.baseline_lock,
            args.candidate_lock,
            args.baseline_license_dir,
            args.candidate_root,
            args.validation_root,
        )
        _write(args.output, value)
        print(json.dumps(value, sort_keys=True))
        return 0
    except (FirmwareRuntimeError, OSError, json.JSONDecodeError) as error:
        print(f"runtime review summary failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
