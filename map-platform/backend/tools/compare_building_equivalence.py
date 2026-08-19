#!/usr/bin/env python3
"""Compare retained monolithic and partitioned target-3 build records."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from map_platform.building_equivalence import (  # noqa: E402
    BuildingEquivalenceError,
    validate_partition_equivalence,
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        reference = json.loads(args.reference.read_text(encoding="utf-8"))
        candidate = json.loads(args.candidate.read_text(encoding="utf-8"))
        report = validate_partition_equivalence(reference, candidate)
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as exc:
        print(f"partition equivalence failed: {exc}", file=sys.stderr)
        return 2
    serialized = json.dumps(report, sort_keys=True, indent=2) + "\n"
    if args.output is not None:
        args.output.write_text(serialized, encoding="utf-8")
    print(serialized, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

