"""Canonical target-3 preprocessing identities shared by reuse and manifests."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
from typing import Any

from .building_scope import ScopePlan
from .map_buildings import BUILDING_PROFILE_VERSION


BUILDING_PREPROCESSING_IDENTITY_SCHEMA_VERSION = 1
BUILDING_EXTRACTION_ALGORITHM_VERSION = 1
BUILDING_SOURCE_INDEX_SCHEMA_VERSION = 1
BUILDING_SOURCE_INDEX_ALGORITHM_VERSION = 2
BUILDING_CLOSURE_ALGORITHM_VERSION = 1
BUILDING_CALIBRATION_SCHEMA_VERSION = 1
BUILDING_CALIBRATION_ALGORITHM_VERSION = 1
BUILDING_CALIBRATION_CREATION_TOOL = "open-bike-building-calibration"
BUILDING_BLOCK_CACHE_SCHEMA_VERSION = 1
BUILDING_NORMALIZATION_ALGORITHM_VERSION = 2
BUILDING_BLOCK_ENCODING_ALGORITHM_VERSION = 1
BUILDING_FMB_VERSION = 4
BUILDING_GEOMETRY_ENGINE_VERSION = "2.0.7"
_SHA256_RE = re.compile(r"[0-9a-f]{64}")


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")


def selected_building_identity(
    *,
    source_snapshot_sha256: str,
    rules_path: Path,
    scope_plan: ScopePlan,
    calibration_generation: dict[str, Any],
) -> dict[str, Any]:
    calibration_document = selected_calibration_identity(
        source_snapshot_sha256=source_snapshot_sha256,
        rules_path=rules_path,
        scope_plan=scope_plan,
    )
    calibration_key = calibration_document.pop("calibrationKey")
    scope = scope_plan.document
    if (
        not isinstance(calibration_generation, dict)
        or calibration_generation.get("calibrationKey") != calibration_key
        or not _SHA256_RE.fullmatch(
            str(calibration_generation.get("manifestSha256") or "")
        )
        or not _SHA256_RE.fullmatch(
            str(calibration_generation.get("entrySetSha256") or "")
        )
        or isinstance(calibration_generation.get("cellCount"), bool)
        or not isinstance(calibration_generation.get("cellCount"), int)
        or calibration_generation["cellCount"] <= 0
    ):
        raise ValueError("building calibration generation identity is invalid")
    body = {
        "schemaVersion": BUILDING_PREPROCESSING_IDENTITY_SCHEMA_VERSION,
        "sourceSnapshotSha256": source_snapshot_sha256,
        "buildingProfileVersion": BUILDING_PROFILE_VERSION,
        "extractionAlgorithmVersion": BUILDING_EXTRACTION_ALGORITHM_VERSION,
        "sourceIndex": {
            "schemaVersion": BUILDING_SOURCE_INDEX_SCHEMA_VERSION,
            "algorithmVersion": BUILDING_SOURCE_INDEX_ALGORITHM_VERSION,
        },
        "closureAlgorithmVersion": BUILDING_CLOSURE_ALGORITHM_VERSION,
        "scope": {
            "scopePlanSha256": scope_plan.sha256,
            "scopePolicyVersion": scope["policy"]["policyVersion"],
            "blockGridVersion": scope["policy"]["blockGridVersion"],
            "blockSizeMeters": scope["policy"]["blockSizeMeters"],
            "geometryBufferMeters": scope["policy"]["geometryBufferMeters"],
            "relationRetryBufferMeters": scope["policy"]["relationRetryBufferMeters"],
            "maxGeometryBufferMeters": scope["policy"]["maxGeometryBufferMeters"],
            "relationClosureMode": scope["policy"]["relationClosureMode"],
            "selectionSemantics": scope["policy"]["selectionSemantics"],
            "maxSourceToOutputAreaBasisPoints": scope["policy"][
                "maxSourceToOutputAreaBasisPoints"
            ],
            "maxSourceAreaM2": scope["policy"]["maxSourceAreaM2"],
            "maxRelationObjectsPerJob": scope["policy"][
                "maxRelationObjectsPerJob"
            ],
        },
        "calibration": {
            **calibration_document,
            "calibrationKey": calibration_key,
            "manifestSha256": calibration_generation["manifestSha256"],
            "entrySetSha256": calibration_generation["entrySetSha256"],
            "generationCellCount": calibration_generation["cellCount"],
        },
    }
    return {
        **body,
        "identitySha256": hashlib.sha256(canonical_json(body)).hexdigest(),
    }


def selected_calibration_identity(
    *,
    source_snapshot_sha256: str,
    rules_path: Path,
    scope_plan: ScopePlan,
) -> dict[str, Any]:
    if not _SHA256_RE.fullmatch(source_snapshot_sha256):
        raise ValueError("building source snapshot identity is invalid")
    rules_sha256 = hashlib.sha256(rules_path.read_bytes()).hexdigest()
    scope = scope_plan.document
    calibration = scope["calibration"]
    calibration_document = {
        "schemaVersion": BUILDING_CALIBRATION_SCHEMA_VERSION,
        "sourceSnapshotSha256": source_snapshot_sha256,
        "rulesSha256": rules_sha256,
        "buildingProfileVersion": BUILDING_PROFILE_VERSION,
        "algorithmVersion": BUILDING_CALIBRATION_ALGORITHM_VERSION,
        "cellSizeMeters": calibration["cellSizeMeters"],
        "haloCells": calibration["haloCells"],
        "minimumSamples": calibration["minimumSamples"],
        "creationTool": BUILDING_CALIBRATION_CREATION_TOOL,
    }
    calibration_key = hashlib.sha256(canonical_json(calibration_document)).hexdigest()
    return {**calibration_document, "calibrationKey": calibration_key}


def selected_building_block_cache_identity(
    *,
    source_snapshot_sha256: str,
    rules_path: Path,
    scope_plan: ScopePlan,
    calibration_generation: dict[str, Any],
) -> dict[str, Any]:
    """Return the request-independent identity for canonical building blocks."""
    calibration = selected_calibration_identity(
        source_snapshot_sha256=source_snapshot_sha256,
        rules_path=rules_path,
        scope_plan=scope_plan,
    )
    calibration_key = calibration["calibrationKey"]
    if (
        not isinstance(calibration_generation, dict)
        or calibration_generation.get("calibrationKey") != calibration_key
        or not _SHA256_RE.fullmatch(
            str(calibration_generation.get("manifestSha256") or "")
        )
        or not _SHA256_RE.fullmatch(
            str(calibration_generation.get("entrySetSha256") or "")
        )
    ):
        raise ValueError("building block cache calibration identity is invalid")
    scope = scope_plan.document
    body = {
        "schemaVersion": BUILDING_BLOCK_CACHE_SCHEMA_VERSION,
        "sourceSnapshotSha256": source_snapshot_sha256,
        "rulesSha256": calibration["rulesSha256"],
        "buildingProfileVersion": BUILDING_PROFILE_VERSION,
        "rendererFormatVersion": 3,
        "fmbVersion": BUILDING_FMB_VERSION,
        "blockGridVersion": scope["policy"]["blockGridVersion"],
        "blockSizeMeters": scope["policy"]["blockSizeMeters"],
        "selectionSemantics": scope["policy"]["selectionSemantics"],
        "geometryBufferMeters": scope["policy"]["geometryBufferMeters"],
        "relationRetryBufferMeters": scope["policy"]["relationRetryBufferMeters"],
        "maxGeometryBufferMeters": scope["policy"]["maxGeometryBufferMeters"],
        "normalizationAlgorithmVersion": BUILDING_NORMALIZATION_ALGORITHM_VERSION,
        "blockEncodingAlgorithmVersion": BUILDING_BLOCK_ENCODING_ALGORITHM_VERSION,
        "geometryEngine": {
            "name": "shapely",
            "version": BUILDING_GEOMETRY_ENGINE_VERSION,
        },
        "sourceIndex": {
            "schemaVersion": BUILDING_SOURCE_INDEX_SCHEMA_VERSION,
            "algorithmVersion": BUILDING_SOURCE_INDEX_ALGORITHM_VERSION,
        },
        "closureAlgorithmVersion": BUILDING_CLOSURE_ALGORITHM_VERSION,
        "calibration": {
            "algorithmVersion": BUILDING_CALIBRATION_ALGORITHM_VERSION,
            "calibrationKey": calibration_key,
            "manifestSha256": calibration_generation["manifestSha256"],
            "entrySetSha256": calibration_generation["entrySetSha256"],
        },
    }
    return {
        **body,
        "cacheIdentitySha256": hashlib.sha256(canonical_json(body)).hexdigest(),
    }


def calibration_generation_from_manifest(
    path: Path,
    *,
    source_snapshot_sha256: str,
    calibration_key: str | None = None,
    calibration_identity: dict[str, Any] | None = None,
) -> dict[str, Any]:
    try:
        raw = json.loads(path.read_bytes())
    except (OSError, TypeError, ValueError) as exc:
        raise ValueError("building calibration generation manifest is unavailable") from exc
    if not isinstance(raw, dict):
        raise ValueError("building calibration generation manifest is invalid")
    manifest_sha256 = raw.get("manifestSha256")
    body = {key: value for key, value in raw.items() if key != "manifestSha256"}
    cells = raw.get("cells")
    identity_keys = {
        "schemaVersion",
        "sourceSnapshotSha256",
        "rulesSha256",
        "buildingProfileVersion",
        "algorithmVersion",
        "cellSizeMeters",
        "haloCells",
        "minimumSamples",
        "creationTool",
    }
    expected_keys = identity_keys | {
        "calibrationKey",
        "completeSourceSnapshot",
        "completeDomainCellCount",
        "completeDomainSha256",
        "cells",
        "manifestSha256",
    }
    manifest_identity = {key: raw.get(key) for key in identity_keys}
    derived_calibration_key = hashlib.sha256(
        canonical_json(manifest_identity)
    ).hexdigest()
    previous = None
    if (
        set(raw) != expected_keys
        or not _SHA256_RE.fullmatch(str(manifest_sha256 or ""))
        or hashlib.sha256(canonical_json(body)).hexdigest() != manifest_sha256
        or raw.get("sourceSnapshotSha256") != source_snapshot_sha256
        or raw.get("schemaVersion") != BUILDING_CALIBRATION_SCHEMA_VERSION
        or raw.get("buildingProfileVersion") != BUILDING_PROFILE_VERSION
        or raw.get("algorithmVersion") != BUILDING_CALIBRATION_ALGORITHM_VERSION
        or raw.get("creationTool") != BUILDING_CALIBRATION_CREATION_TOOL
        or raw.get("calibrationKey") != derived_calibration_key
        or raw.get("completeSourceSnapshot") is not True
        or (calibration_key is not None and raw.get("calibrationKey") != calibration_key)
        or (
            calibration_identity is not None
            and any(
                raw.get(key) != value
                for key, value in calibration_identity.items()
            )
        )
        or not isinstance(cells, list)
        or not cells
    ):
        raise ValueError("building calibration generation manifest is invalid")
    for entry in cells:
        if (
            not isinstance(entry, dict)
            or set(entry) != {"x", "y", "entrySha256"}
            or isinstance(entry.get("x"), bool)
            or not isinstance(entry.get("x"), int)
            or isinstance(entry.get("y"), bool)
            or not isinstance(entry.get("y"), int)
            or not _SHA256_RE.fullmatch(str(entry.get("entrySha256") or ""))
        ):
            raise ValueError("building calibration generation cell is invalid")
        coordinate = (entry["x"], entry["y"])
        if previous is not None and coordinate <= previous:
            raise ValueError("building calibration generation cells are not canonical")
        previous = coordinate
    coordinates = [[entry["x"], entry["y"]] for entry in cells]
    if (
        isinstance(raw.get("completeDomainCellCount"), bool)
        or raw.get("completeDomainCellCount") != len(cells)
        or not _SHA256_RE.fullmatch(str(raw.get("completeDomainSha256") or ""))
        or raw["completeDomainSha256"]
        != hashlib.sha256(canonical_json(coordinates)).hexdigest()
    ):
        raise ValueError("building calibration generation domain is invalid")
    return {
        "calibrationKey": raw["calibrationKey"],
        "manifestSha256": manifest_sha256,
        "entrySetSha256": hashlib.sha256(canonical_json(cells)).hexdigest(),
        "cellCount": len(cells),
    }


def calibration_generation_manifest_path(
    cache_root: Path,
    calibration_identity: dict[str, Any],
) -> Path:
    return (
        cache_root
        / f"building-calibration-v{BUILDING_CALIBRATION_SCHEMA_VERSION}"
        / calibration_identity["sourceSnapshotSha256"]
        / calibration_identity["rulesSha256"]
        / f"algorithm-{calibration_identity['algorithmVersion']}"
        / calibration_identity["calibrationKey"]
        / "manifest.json"
    )


def legacy_building_identity() -> dict[str, Any]:
    body = {
        "schemaVersion": BUILDING_PREPROCESSING_IDENTITY_SCHEMA_VERSION,
        "mode": "legacy_cell_expanded_request_calibration",
        "buildingProfileVersion": BUILDING_PROFILE_VERSION,
    }
    return {**body, "identitySha256": hashlib.sha256(canonical_json(body)).hexdigest()}
