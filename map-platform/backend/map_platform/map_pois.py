from __future__ import annotations

import os
from typing import Any

from .installations import INSTALLATION_ID_PREFIX
import re


POI_PROFILE_VERSION = 1
POI_RENDERER_FORMAT_VERSION = 5
POI_INDEX_PROFILE_VERSION = 1
POI_REQUIRED_FEATURES = ("3d-buildings", "map-pois", "street-labels")
POI_OPTIONAL_FEATURES = ("contours",)
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


def requested_poi_features(request: dict[str, Any]) -> tuple[str, ...]:
    target = request.get("target", {})
    values = target.get("requestedFeatures")
    if (target.get("rendererFormatVersion") != POI_RENDERER_FORMAT_VERSION
            or not isinstance(values, list) or any(not isinstance(value, str) for value in values)
            or len(values) != len(set(values))
            or set(values) not in (set(POI_REQUIRED_FEATURES),
                                  set(POI_REQUIRED_FEATURES + POI_OPTIONAL_FEATURES))):
        raise ValueError("renderer target 5 requires explicit valid requestedFeatures")
    return tuple(sorted(values))


def request_has_contours(request: dict[str, Any]) -> bool:
    version = request.get("target", {}).get("rendererFormatVersion", 1)
    return version == 4 or (version == POI_RENDERER_FORMAT_VERSION
                            and "contours" in requested_poi_features(request))


def poi_target5_generation_allowlist() -> frozenset[str]:
    return _allowlist("MAP_PLATFORM_POI_TARGET5_ALLOWLIST")


def poi_contours_generation_allowlist() -> frozenset[str]:
    return _allowlist("MAP_PLATFORM_POI_CONTOURS_ALLOWLIST")


def _allowlist(variable: str) -> frozenset[str]:
    raw = os.environ.get(variable, "")
    values = [value.strip() for value in raw.split(",") if value.strip()]
    if len(values) != len(set(values)):
        raise ValueError(f"{variable} contains duplicates")
    if any(_INSTALLATION_ID_PATTERN.fullmatch(value) is None for value in values):
        raise ValueError(f"{variable} contains an invalid installation ID")
    return frozenset(values)


def manifest_poi_summary(stats: dict[str, Any] | None) -> dict[str, int]:
    if not isinstance(stats, dict):
        raise ValueError("renderer format 5 is missing POI statistics")
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
