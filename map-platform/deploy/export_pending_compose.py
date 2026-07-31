#!/usr/bin/env python3
"""Export a production Compose file from a promotion commit."""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path


COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")
COMPOSE_PATHS = (
    "map-platform/deploy/compose.yaml",
    "deploy/map-platform/compose.yaml",
)


def export_pending_compose(
    repo_root: Path,
    commit: str,
    output: Path,
) -> str:
    if COMMIT_PATTERN.fullmatch(commit) is None:
        raise ValueError("pending promotion commit must be a full lowercase Git SHA")

    for compose_path in COMPOSE_PATHS:
        completed = subprocess.run(
            ["git", "show", f"{commit}:{compose_path}"],
            cwd=repo_root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if completed.returncode == 0:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(completed.stdout)
            return compose_path

    raise FileNotFoundError(
        "pending promotion contains neither the relocated nor legacy Compose path"
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Export the relocated or legacy production Compose file from an "
            "existing promotion commit"
        )
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
    )
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    selected_path = export_pending_compose(
        args.repo_root.resolve(),
        args.commit,
        args.output,
    )
    print(f"Loaded pending production Compose from {selected_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
