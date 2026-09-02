from __future__ import annotations

import os
from typing import Any

from .installations import INSTALLATION_ID_PREFIX
import re


POI_PROFILE_VERSION = 1
POI_RENDERER_FORMAT_VERSION = 4
POI_STATS_KEYS = {
    "recordCount",
    "shopsCount",
    "restaurantsAndCafesCount",
    "publicToiletsCount",
    "gasStationsCount",
    "bicycleServicesCount",
}
_INSTALLATION_ID_PATTERN = re.compile(
    rf"{re.escape(INSTALLATION_ID_PREFIX)}[0-9a-f]{{32}}"
)


def renderer_includes_pois(format_version: int) -> bool:
    return format_version == POI_RENDERER_FORMAT_VERSION


def poi_target4_generation_allowlist() -> frozenset[str]:
    raw = os.environ.get("MAP_PLATFORM_POI_TARGET4_ALLOWLIST", "")
    values = [value.strip() for value in raw.split(",") if value.strip()]
    if len(values) != len(set(values)):
        raise ValueError("POI target 4 allowlist contains duplicates")
    if any(_INSTALLATION_ID_PATTERN.fullmatch(value) is None for value in values):
        raise ValueError("POI target 4 allowlist contains an invalid installation ID")
    return frozenset(values)


def manifest_poi_summary(stats: dict[str, Any] | None) -> dict[str, int]:
    if not isinstance(stats, dict):
        raise ValueError("renderer format 4 is missing POI statistics")
    summary: dict[str, int] = {}
    for key in sorted(POI_STATS_KEYS):
        value = stats.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"POI statistic {key} is invalid")
        summary[key] = value
    if (
        summary["shopsCount"]
        + summary["restaurantsAndCafesCount"]
        + summary["publicToiletsCount"]
        + summary["gasStationsCount"]
        + summary["bicycleServicesCount"]
        != summary["recordCount"]
    ):
        raise ValueError("POI category counts do not match rendered records")
    return summary
