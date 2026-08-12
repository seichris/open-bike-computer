#!/usr/bin/env python3
"""Determine whether a Git range changes signed worker build inputs."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "map-platform" / "backend"))

from map_platform.map_stream_build_identity import WORKER_SOURCE_ROOTS  # noqa: E402


COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")
WORKER_CLASSIFICATION_ROOTS = WORKER_SOURCE_ROOTS + (
    # Docker applies this file before copying and hashing the worker source.
    # Treat every change conservatively because a rule can alter the effective
    # worker tree without changing a path under WORKER_SOURCE_ROOTS.
    ".dockerignore",
)
IMAGE_INPUT_ROOTS = (
    ".dockerignore",
    ".github/workflows/map-platform-image.yml",
    "map-platform/backend",
    "tools/OSM_Extract/conf",
    "tools/OSM_Extract/scripts",
    "map-platform/config/map-stream-hardware-gate.json",
    "map-platform/config/map-stream-rollout-approvals.json",
    "map-platform/config/map-stream-trust.json",
    "map-platform/config/generation-profile-policy-v1.json",
)
PROMOTION_INPUT_ROOTS = IMAGE_INPUT_ROOTS + (
    ".github/workflows/map-platform-ci.yml",
    "map-platform/deploy/detect_worker_change.py",
    "map-platform/deploy/export_pending_compose.py",
    "map-platform/deploy/select_worker_promotion.py",
    "map-platform/deploy/update_image.py",
    "map-platform/deploy/verify_registry_images.py",
)


def normalize_repo_path(value: str) -> str:
    path = PurePosixPath(value.strip())
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"changed path is outside the repository: {value}")
    return path.as_posix()


def worker_inputs_changed(paths: Iterable[str]) -> bool:
    roots = tuple(root.rstrip("/") for root in WORKER_CLASSIFICATION_ROOTS)
    for raw_path in paths:
        path = normalize_repo_path(raw_path)
        if any(path == root or path.startswith(f"{root}/") for root in roots):
            return True
    return False


def image_inputs_changed(paths: Iterable[str]) -> bool:
    roots = tuple(root.rstrip("/") for root in IMAGE_INPUT_ROOTS)
    for raw_path in paths:
        path = normalize_repo_path(raw_path)
        if any(path == root or path.startswith(f"{root}/") for root in roots):
            return True
    return False


def promotion_inputs_changed(paths: Iterable[str]) -> bool:
    roots = tuple(root.rstrip("/") for root in PROMOTION_INPUT_ROOTS)
    for raw_path in paths:
        path = normalize_repo_path(raw_path)
        if any(path == root or path.startswith(f"{root}/") for root in roots):
            return True
    return False


def git_changed_paths(repo_root: Path, before: str, after: str) -> list[str] | None:
    if (
        COMMIT_PATTERN.fullmatch(before) is None
        or set(before) == {"0"}
        or COMMIT_PATTERN.fullmatch(after) is None
    ):
        return None
    ancestor = subprocess.run(
        ["git", "merge-base", "--is-ancestor", before, after],
        cwd=repo_root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if ancestor.returncode != 0:
        return None
    completed = subprocess.run(
        ["git", "diff", "--no-renames", "--name-only", "-z", before, after],
        cwd=repo_root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return [
        value.decode("utf-8")
        for value in completed.stdout.split(b"\0")
        if value
    ]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Print true when a Git range changes map worker identity inputs",
    )
    parser.add_argument("--before", default="")
    parser.add_argument("--after", required=True)
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument(
        "--scope",
        choices=("worker", "image", "promotion"),
        default="worker",
    )
    args = parser.parse_args()

    paths = git_changed_paths(args.repo_root.resolve(), args.before, args.after)
    # Unknown ranges, including manual dispatches, conservatively propose the
    # candidate as both control plane and worker for explicit human review.
    classifiers = {
        "worker": worker_inputs_changed,
        "image": image_inputs_changed,
        "promotion": promotion_inputs_changed,
    }
    classifier = classifiers[args.scope]
    changed = True if paths is None else classifier(paths)
    print("true" if changed else "false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
