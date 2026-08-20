#!/usr/bin/env python3
"""Plan output-candidate building closure from an immutable source index."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path

from building_calibration_cache import canonical_json
from building_source_index import BuildingSourceIndex, BuildingSourceIndexError


EARTH_RADIUS_METERS = 6_378_137


def _load_scope(path: Path) -> tuple[dict, str]:
    try:
        value = json.loads(path.read_bytes())
        digest = value.pop("scopePlanSha256")
    except (OSError, TypeError, ValueError, KeyError) as exc:
        raise BuildingSourceIndexError(
            "building_scope_policy_invalid", "scope plan is unavailable"
        ) from exc
    if (
        not isinstance(digest, str)
        or hashlib.sha256(canonical_json(value)).hexdigest() != digest
        or value.get("schemaVersion") != 1
        or value.get("policy", {}).get("relationClosureMode")
        != "source_snapshot_index"
    ):
        raise BuildingSourceIndexError(
            "building_scope_policy_invalid", "scope plan identity is invalid"
        )
    return value, digest


def _x_to_e7(value: int) -> int:
    return int(round(math.degrees(value / EARTH_RADIUS_METERS) * 10_000_000))


def _y_to_e7(value: int) -> int:
    latitude = math.degrees(
        2 * math.atan(math.exp(value / EARTH_RADIUS_METERS)) - math.pi / 2
    )
    return int(round(latitude * 10_000_000))


def output_bounds_e7(scope: dict) -> tuple[tuple[int, int, int, int], ...]:
    rectangles = []
    for block in scope.get("outputBlocks", []):
        bounds = block.get("boundsMeters") if isinstance(block, dict) else None
        if (
            not isinstance(bounds, list)
            or len(bounds) != 4
            or any(isinstance(value, bool) or not isinstance(value, int) for value in bounds)
        ):
            raise BuildingSourceIndexError(
                "building_scope_policy_invalid", "scope output blocks are invalid"
            )
        rectangles.append(
            (
                _x_to_e7(bounds[0]) - 1,
                _y_to_e7(bounds[1]) - 1,
                _x_to_e7(bounds[2]) + 1,
                _y_to_e7(bounds[3]) + 1,
            )
        )
    if not rectangles:
        raise BuildingSourceIndexError(
            "building_scope_policy_invalid", "scope has no output blocks"
        )
    return tuple(rectangles)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-index-manifest", required=True, type=Path)
    parser.add_argument("--scope-plan", required=True, type=Path)
    parser.add_argument("--closure-plan", required=True, type=Path)
    parser.add_argument("--ids-output", required=True, type=Path)
    args = parser.parse_args()
    print(
        'BUILDING_PREPROCESS_PROGRESS:{"completed":0,"indeterminate":true,"unit":"relation_closure"}',
        flush=True,
    )

    scope, scope_sha256 = _load_scope(args.scope_plan)
    policy = scope["policy"]
    calibration = scope["calibration"]
    # The source-index builder binds the exact database bytes to a stable-file
    # verification receipt. Closure workers validate that receipt and file
    # identity here without repeating the multi-gigabyte hash/audit per chunk.
    index = BuildingSourceIndex.from_manifest(
        args.source_index_manifest,
        validate_database=False,
    )
    closure = index.closure_for_bounds(
        output_bounds_e7(scope),
        maximum_objects=policy["maxRelationObjectsPerJob"],
        calibration_cell_size_meters=calibration["cellSizeMeters"],
        calibration_halo_cells=calibration["haloCells"],
    )
    body = {
        "schemaVersion": 1,
        "scopePlanSha256": scope_sha256,
        **closure,
    }
    closure_sha256 = hashlib.sha256(canonical_json(body)).hexdigest()
    document = {**body, "closurePlanSha256": closure_sha256}
    args.closure_plan.write_bytes(canonical_json(document) + b"\n")
    object_ids = sorted(
        set(closure["requiredRelationKeys"])
        | set(closure["requiredWayKeys"])
        | set(closure["requiredNodeKeys"])
    )
    args.ids_output.write_text("".join(f"{key}\n" for key in object_ids), encoding="ascii")
    print(
        "BUILDING_CLOSURE_STATS:"
        + json.dumps(
            {
                "closurePlanSha256": closure_sha256,
                "candidateCount": len(closure["candidateKeys"]),
                "relationCount": len(closure["requiredRelationKeys"]),
                "wayCount": len(closure["requiredWayKeys"]),
                "nodeCount": len(closure["requiredNodeKeys"]),
                "calibrationCellCount": len(closure["calibrationSampleCells"]),
            },
            sort_keys=True,
            separators=(",", ":"),
        ),
        flush=True,
    )
    print(
        'BUILDING_PREPROCESS_PROGRESS:{"completed":1,"indeterminate":false,"total":1,"unit":"relation_closure"}',
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
