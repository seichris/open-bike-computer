"""Partition-invariant identities for chunked building artifacts."""

from __future__ import annotations

import hashlib
import re
from typing import Any, Mapping

from .building_scope import canonical_json


PARTITION_INVARIANT_ARTIFACT_IDENTITY_SCHEMA_VERSION = 1
_SHA256 = re.compile(r"[0-9a-f]{64}")


def partition_invariant_artifact_identity(
    *,
    global_plan_sha256: str,
    source_snapshot_sha256: str,
    source_index_database_sha256: str,
    calibration_manifest_sha256: str,
    cache_identity_sha256: str,
    receipt_set_sha256: str,
) -> dict[str, Any]:
    """Return the immutable building-input identity used by final assembly.

    The identity contains only canonical source, calibration, cache, and
    block-receipt inputs.  It intentionally excludes task IDs, chunk
    boundaries, lease order, timings, and cache-hit state, so two valid
    partition layouts produce the same identity before whole-map packaging.
    """

    values = {
        "globalPlanSha256": global_plan_sha256,
        "sourceSnapshotSha256": source_snapshot_sha256,
        "sourceIndexDatabaseSha256": source_index_database_sha256,
        "calibrationManifestSha256": calibration_manifest_sha256,
        "cacheIdentitySha256": cache_identity_sha256,
        "receiptSetSha256": receipt_set_sha256,
    }
    for field, value in values.items():
        if not isinstance(value, str) or not _SHA256.fullmatch(value):
            raise ValueError(f"{field} must be a lowercase sha256")
    digest_body = {
        "schemaVersion": PARTITION_INVARIANT_ARTIFACT_IDENTITY_SCHEMA_VERSION,
        **values,
    }
    return {
        **digest_body,
        "artifactIdentitySha256": hashlib.sha256(
            canonical_json(digest_body)
        ).hexdigest(),
    }


def validate_partition_invariant_artifact_identity(
    value: Mapping[str, Any],
) -> dict[str, Any]:
    """Validate and return a canonical partition-invariant identity."""

    if not isinstance(value, Mapping):
        raise ValueError("partition-invariant artifact identity is not an object")
    expected = partition_invariant_artifact_identity(
        global_plan_sha256=value.get("globalPlanSha256"),
        source_snapshot_sha256=value.get("sourceSnapshotSha256"),
        source_index_database_sha256=value.get("sourceIndexDatabaseSha256"),
        calibration_manifest_sha256=value.get("calibrationManifestSha256"),
        cache_identity_sha256=value.get("cacheIdentitySha256"),
        receipt_set_sha256=value.get("receiptSetSha256"),
    )
    if dict(value) != expected:
        raise ValueError("partition-invariant artifact identity is not canonical")
    return expected

