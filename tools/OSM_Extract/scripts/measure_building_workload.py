#!/usr/bin/env python3
"""Read-only exact workload scan for a proposed building chunk."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from building_source_index import BuildingSourceIndex, BuildingSourceIndexError
from building_calibration_cache import canonical_json


def _bounds(value: str):
    try:
        parsed = json.loads(value)
    except (TypeError, ValueError) as exc:
        raise BuildingSourceIndexError(
            "building_scope_policy_invalid", "bounds JSON is invalid"
        ) from exc
    if not isinstance(parsed, list) or not parsed:
        raise BuildingSourceIndexError(
            "building_scope_policy_invalid", "bounds JSON must contain rectangles"
        )
    result = []
    for rectangle in parsed:
        if (
            not isinstance(rectangle, list)
            or len(rectangle) != 4
            or any(isinstance(item, bool) or not isinstance(item, int) for item in rectangle)
        ):
            raise BuildingSourceIndexError(
                "building_scope_policy_invalid", "bounds rectangle is invalid"
            )
        result.append(tuple(rectangle))
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-index-manifest", required=True, type=Path)
    parser.add_argument("--bounds-e7-json", required=True)
    parser.add_argument("--maximum-objects", required=True, type=int)
    parser.add_argument("--calibration-cell-size-meters", required=True, type=int)
    parser.add_argument("--calibration-halo-cells", required=True, type=int)
    parser.add_argument("--result-json", required=True, type=Path)
    args = parser.parse_args()
    # The source-index builder validates and seals this immutable manifest
    # before publication. Reusing it per chunk must not rehash and audit the
    # multi-gigabyte SQLite database.
    index = BuildingSourceIndex.from_manifest(
        args.source_index_manifest,
        validate_database=False,
    )
    workload = index.workload_for_bounds(
        _bounds(args.bounds_e7_json),
        maximum_objects=args.maximum_objects,
        calibration_cell_size_meters=args.calibration_cell_size_meters,
        calibration_halo_cells=args.calibration_halo_cells,
    )
    args.result_json.write_bytes(canonical_json(workload) + b"\n")
    print(
        "BUILDING_WORKLOAD_STATS:"
        + json.dumps(
            {
                key: workload[key]
                for key in (
                    "closurePlanSha256",
                    "relationCount",
                    "wayCount",
                    "nodeCount",
                    "totalObjectCount",
                    "storedRelationMemberCount",
                    "wayNodeReferenceCount",
                    "vertexCount",
                    "candidateOutlineCount",
                    "candidatePartCount",
                )
            },
            sort_keys=True,
            separators=(",", ":"),
        ),
        flush=True,
    )


if __name__ == "__main__":
    try:
        main()
    except BuildingSourceIndexError as exc:
        print(
            "BUILDING_PREPROCESS_FAILURE:"
            + json.dumps(
                {"code": exc.code, "message": str(exc)},
                sort_keys=True,
                separators=(",", ":"),
            ),
            flush=True,
        )
        raise SystemExit(2) from exc
