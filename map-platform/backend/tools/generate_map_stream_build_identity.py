#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


BACKEND_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = BACKEND_ROOT.parents[1]
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))

from map_platform.map_stream_build_identity import (  # noqa: E402
    derive_producer_build_sha256,
)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Derive the immutable map-stream worker component identity."
    )
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument(
        "--output",
        type=Path,
        default=REPO_ROOT / "map-platform" / "config" / "map-stream-build-identity.json",
    )
    args = parser.parse_args()
    build_sha256 = derive_producer_build_sha256(args.repo_root.resolve())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(
            {"schemaVersion": 1, "producerBuildSha256": build_sha256},
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )
    print(build_sha256)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
