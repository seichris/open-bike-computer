"""Pre-execution storage admission for city-scale building orchestration."""

from __future__ import annotations

from typing import Any


DEFAULT_BUILDING_BLOCK_CACHE_MAX_BYTES = 20 * 1024 * 1024 * 1024
DEFAULT_BUILDING_ATTEMPT_STORAGE_MAX_BYTES = 20 * 1024 * 1024 * 1024
DEFAULT_BUILDING_STORAGE_RESERVE_BYTES = 1024 * 1024 * 1024
BUILDING_CACHE_EXPANSION_FACTOR = 2
BUILDING_TEMPORARY_EXPANSION_FACTOR = 3
BUILDING_SOURCE_WORKING_COPIES = 2


class BuildingStorageAdmissionError(ValueError):
    code = "building_storage_admission"


def building_storage_admission(
    *,
    estimated_archive_bytes: int,
    source_bytes: int,
    free_bytes: int,
    cache_max_bytes: int = DEFAULT_BUILDING_BLOCK_CACHE_MAX_BYTES,
    attempt_max_bytes: int = DEFAULT_BUILDING_ATTEMPT_STORAGE_MAX_BYTES,
    reserve_bytes: int = DEFAULT_BUILDING_STORAGE_RESERVE_BYTES,
) -> dict[str, Any]:
    """Require both retention quota and live disk headroom before preparation.

    The estimate deliberately includes two retained cache copies' worth of
    canonical block data, three archive-sized temporary assembly/conversion
    copies, and two source-sized PBF/index working copies. Final exact limits
    remain authoritative; this gate prevents predictably unretainable work.
    """

    values = {
        "estimatedArchiveBytes": estimated_archive_bytes,
        "sourceBytes": source_bytes,
        "freeBytes": free_bytes,
        "cacheMaxBytes": cache_max_bytes,
        "attemptMaxBytes": attempt_max_bytes,
        "reserveBytes": reserve_bytes,
    }
    if any(
        isinstance(value, bool) or not isinstance(value, int) or value < 0
        for value in values.values()
    ) or any(
        values[name] <= 0
        for name in ("estimatedArchiveBytes", "sourceBytes", "cacheMaxBytes", "attemptMaxBytes")
    ):
        raise BuildingStorageAdmissionError("storage admission inputs are invalid")
    predicted_cache_bytes = (
        estimated_archive_bytes * BUILDING_CACHE_EXPANSION_FACTOR
    )
    predicted_attempt_bytes = (
        predicted_cache_bytes
        + estimated_archive_bytes * BUILDING_TEMPORARY_EXPANSION_FACTOR
        + source_bytes * BUILDING_SOURCE_WORKING_COPIES
    )
    report = {
        "schemaVersion": 1,
        **values,
        "predictedCacheBytes": predicted_cache_bytes,
        "predictedAttemptBytes": predicted_attempt_bytes,
        "requiredFreeBytes": predicted_attempt_bytes + reserve_bytes,
    }
    if predicted_cache_bytes > cache_max_bytes:
        raise BuildingStorageAdmissionError(
            "predicted canonical block cache exceeds the retention quota"
        )
    if predicted_attempt_bytes > attempt_max_bytes:
        raise BuildingStorageAdmissionError(
            "predicted source/cache working set exceeds the attempt quota"
        )
    if report["requiredFreeBytes"] > free_bytes:
        raise BuildingStorageAdmissionError(
            "insufficient disk headroom for the predicted building attempt"
        )
    return {**report, "admitted": True}
