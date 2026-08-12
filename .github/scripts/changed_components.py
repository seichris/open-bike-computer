#!/usr/bin/env python3
"""Classify changed repository paths for GitHub Actions CI routing."""

from __future__ import annotations

import argparse
import re
import subprocess
from collections.abc import Iterable, Sequence


COMPONENTS = ("firmware", "ios", "map_backend", "osm")
FULL_CI_PATH_PREFIXES = (".github/scripts/",)
FULL_CI_PATHS = {".github/workflows/ci.yml"}
FIRMWARE_WORKFLOW_PATHS = {
    ".github/workflows/firmware-diagnostics.yml",
    ".github/workflows/firmware-release.yml",
    ".github/workflows/firmware-runtime-performance.yml",
    ".github/workflows/firmware-runtime-publish.yml",
    ".github/workflows/firmware-runtime-refresh.yml",
    ".github/workflows/speaker-firmware.yml",
}
MAP_WORKFLOW_PATHS = {
    ".github/workflows/map-platform-ci.yml",
    ".github/workflows/map-platform-image.yml",
}
FIRMWARE_CONTRACT_PATHS = {
    "docs/device-ownership-test-vectors.json",
    "docs/firmware-battery-life-hardware-validation.md",
    "docs/firmware-build-provenance.md",
    "docs/firmware-factory-release.md",
    "docs/firmware-map-memory-diagnostics.md",
    "docs/firmware-map-render-scheduler.md",
    "docs/firmware-map-rendering-psram.md",
    "docs/firmware-runtime-maintenance.md",
}
FIRMWARE_MANIFEST_PATHS = {
    "tools/firmware_manifest.py",
    "tools/tests/test_firmware_manifest.py",
}
FIRMWARE_RELEASE_TOOL_PATHS = {
    "tools/factory_release_manifest.py",
    "tools/firmware-signing-requirements.txt",
    "tools/verify_github_release_assets.py",
}
IOS_CONTRACT_PATHS = {
    "docs/app-store-privacy-disclosures.md",
    "docs/device-ownership-test-vectors.json",
    "docs/releases/watchos-workout-companion.md",
}
SHARED_FMB_FIXTURE_PREFIX = "test-fixtures/fmb/"
SHARED_MAP_STREAM_FIXTURE_PATH = (
    "map-platform/backend/tests/fixtures/map_stream_v1_golden.txt"
)
SHA_PATTERN = re.compile(r"^[0-9a-fA-F]{40}$")
ZERO_SHA = "0" * 40


def classify_paths(paths: Iterable[str], *, run_all: bool = False) -> dict[str, bool]:
    """Return the CI components affected by a collection of Git paths."""

    selected = {component: run_all for component in COMPONENTS}
    if run_all:
        return selected

    for raw_path in paths:
        path = raw_path
        if not path:
            continue

        if path in FULL_CI_PATHS or path.startswith(FULL_CI_PATH_PREFIXES):
            return {component: True for component in COMPONENTS}

        if (
            path.startswith("esp32/")
            or path.startswith("tools/tests/")
            or path in FIRMWARE_WORKFLOW_PATHS
            or path in FIRMWARE_CONTRACT_PATHS
            or path in FIRMWARE_RELEASE_TOOL_PATHS
        ):
            selected["firmware"] = True

        if path.startswith("ios-app/") or path in IOS_CONTRACT_PATHS:
            selected["ios"] = True

        if path in FIRMWARE_MANIFEST_PATHS:
            # The release producer and the shipped iOS verifier share this contract.
            selected["firmware"] = True
            selected["ios"] = True

        if path == ".dockerignore" or path.startswith("map-platform/"):
            selected["map_backend"] = True

        if path.startswith("tools/OSM_Extract/"):
            # The production backend image copies the extractor into its image.
            selected["map_backend"] = True
            selected["osm"] = True

        if path.startswith(SHARED_FMB_FIXTURE_PREFIX):
            # Firmware, the backend, and the extractor all assert these bytes.
            selected["firmware"] = True
            selected["map_backend"] = True
            selected["osm"] = True

        if path == SHARED_MAP_STREAM_FIXTURE_PATH:
            # The same signed-stream bytes are parsed by backend, iOS, and firmware.
            selected["firmware"] = True
            selected["ios"] = True
            selected["map_backend"] = True

        if path in MAP_WORKFLOW_PATHS:
            selected["map_backend"] = True
            selected["osm"] = True

    return selected


def select_scope(scope: str) -> dict[str, bool] | None:
    """Return an explicit workflow-dispatch selection, or None for path routing."""

    if scope == "auto":
        return None
    if scope == "all":
        return {component: True for component in COMPONENTS}
    if scope == "firmware":
        return {
            "firmware": True,
            "ios": False,
            "map_backend": False,
            "osm": False,
        }
    if scope == "ios":
        return {
            "firmware": False,
            "ios": True,
            "map_backend": False,
            "osm": False,
        }
    if scope == "map":
        return {
            "firmware": False,
            "ios": False,
            "map_backend": True,
            "osm": True,
        }
    raise ValueError(f"unsupported CI scope: {scope}")


def _validated_sha(value: str, label: str) -> str:
    if not SHA_PATTERN.fullmatch(value):
        raise ValueError(f"{label} must be a 40-character Git SHA")
    return value.lower()


def git_diff_command(event: str, base: str, head: str) -> Sequence[str] | None:
    """Build the Git command that lists paths changed by a workflow event."""

    if event == "workflow_dispatch":
        return None

    head_sha = _validated_sha(head, "head")
    base_sha = _validated_sha(base, "base")
    if event == "pull_request":
        return (
            "git",
            "diff",
            "--no-renames",
            "--name-only",
            "-z",
            f"{base_sha}...{head_sha}",
            "--",
        )
    if event == "push":
        if base_sha == ZERO_SHA:
            return (
                "git",
                "diff-tree",
                "--no-renames",
                "--root",
                "--no-commit-id",
                "--name-only",
                "-r",
                "-z",
                head_sha,
                "--",
            )
        return (
            "git",
            "diff",
            "--no-renames",
            "--name-only",
            "-z",
            f"{base_sha}..{head_sha}",
            "--",
        )
    raise ValueError(f"unsupported GitHub event: {event}")


def changed_paths(event: str, base: str, head: str) -> tuple[str, ...] | None:
    """Read the changed paths for an event, or return None for a full manual run."""

    command = git_diff_command(event, base, head)
    if command is None:
        return None
    result = subprocess.run(command, check=True, capture_output=True)
    return tuple(
        entry.decode("utf-8", errors="surrogateescape")
        for entry in result.stdout.split(b"\0")
        if entry
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--event", required=True)
    parser.add_argument("--base", default=ZERO_SHA)
    parser.add_argument("--head", default=ZERO_SHA)
    parser.add_argument(
        "--scope",
        choices=("auto", "all", "firmware", "ios", "map"),
        default="auto",
    )
    args = parser.parse_args()

    try:
        selected = select_scope(args.scope)
        if selected is None:
            paths = changed_paths(args.event, args.base, args.head)
            selected = classify_paths(paths or (), run_all=paths is None)
    except (subprocess.CalledProcessError, ValueError) as error:
        parser.error(str(error))

    for component in COMPONENTS:
        value = "true" if selected[component] else "false"
        print(f"{component}={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
