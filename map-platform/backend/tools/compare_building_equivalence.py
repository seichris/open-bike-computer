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
    build_equivalence_record_from_zip,
    validate_partition_equivalence,
)


def main() -> int:
    parser = argparse.ArgumentParser()
    reference = parser.add_mutually_exclusive_group(required=True)
    reference.add_argument("--reference", type=Path)
    reference.add_argument("--reference-zip", type=Path)
    candidate = parser.add_mutually_exclusive_group(required=True)
    candidate.add_argument("--candidate", type=Path)
    candidate.add_argument("--candidate-zip", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        reference_record = (
            build_equivalence_record_from_zip(args.reference_zip)
            if args.reference_zip is not None
            else json.loads(args.reference.read_text(encoding="utf-8"))
        )
        candidate_record = (
            build_equivalence_record_from_zip(args.candidate_zip)
            if args.candidate_zip is not None
            else json.loads(args.candidate.read_text(encoding="utf-8"))
        )
        report = validate_partition_equivalence(reference_record, candidate_record)
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
