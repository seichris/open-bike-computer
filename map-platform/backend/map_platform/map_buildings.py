from __future__ import annotations

import os
from typing import Any


BUILDING_PROFILE_VERSION = 1
BUILDING_RENDERER_FORMAT_VERSION = 3
BUILDING_STATS_KEYS = {
    "recordCount",
    "explicitHeightCount",
    "levelsHeightCount",
    "inheritedHeightCount",
    "localMedianHeightCount",
    "classDefaultHeightCount",
}


def building_target3_generation_enabled() -> bool:
    value = os.environ.get(
        "MAP_PLATFORM_BUILDING_TARGET3_ENABLED",
        "0",
    ).strip().lower()
    if value in {"1", "true", "yes"}:
        return True
    if value in {"0", "false", "no"}:
        return False
    raise ValueError("MAP_PLATFORM_BUILDING_TARGET3_ENABLED must be a boolean")


def manifest_building_summary(stats: dict[str, Any] | None) -> dict[str, int]:
    if not isinstance(stats, dict):
        raise ValueError("renderer format 3 is missing building statistics")
    summary: dict[str, int] = {}
    for key in sorted(BUILDING_STATS_KEYS):
        value = stats.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"building statistic {key} is invalid")
        summary[key] = value
    provenance_total = sum(
        summary[key]
        for key in BUILDING_STATS_KEYS
        if key != "recordCount"
    )
    if provenance_total != summary["recordCount"]:
        raise ValueError("building provenance counts do not match rendered records")
    return summary
