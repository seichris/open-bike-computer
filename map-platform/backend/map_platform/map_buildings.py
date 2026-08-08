from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import re
from typing import Any

import yaml

from .installations import INSTALLATION_ID_PREFIX


BUILDING_PROFILE_VERSION = 1
BUILDING_RENDERER_FORMAT_VERSION = 3
INSTALLATION_ID_PATTERN = re.compile(
    rf"{re.escape(INSTALLATION_ID_PREFIX)}[0-9a-f]{{32}}"
)
BUILDING_STATS_KEYS = {
    "recordCount",
    "explicitHeightCount",
    "levelsHeightCount",
    "inheritedHeightCount",
    "localMedianHeightCount",
    "classDefaultHeightCount",
}


@dataclass(frozen=True)
class BuildingCalibrationWindow:
    cell_size_meters: int
    halo_cells: int
    minimum_samples: int


def load_building_calibration_window(path: Path) -> BuildingCalibrationWindow:
    try:
        value = yaml.safe_load(path.read_text(encoding="utf-8"))
        local = value["localMedian"]
        cell_size = local["cellSizeMeters"]
        halo_cells = local["haloCells"]
        minimum_samples = local["minimumSamples"]
    except (OSError, TypeError, KeyError, yaml.YAMLError) as exc:
        raise ValueError("building height rules are invalid") from exc
    if (
        isinstance(cell_size, bool)
        or not isinstance(cell_size, int)
        or cell_size <= 0
        or isinstance(halo_cells, bool)
        or not isinstance(halo_cells, int)
        or not 0 <= halo_cells <= 8
        or isinstance(minimum_samples, bool)
        or not isinstance(minimum_samples, int)
        or minimum_samples <= 0
    ):
        raise ValueError("building calibration window is invalid")
    return BuildingCalibrationWindow(cell_size, halo_cells, minimum_samples)


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


def building_target3_generation_allowlist() -> frozenset[str]:
    raw_allowlist = os.environ.get(
        "MAP_PLATFORM_BUILDING_TARGET3_ALLOWLIST",
        "",
    )
    values = [value.strip() for value in raw_allowlist.split(",") if value.strip()]
    if len(values) != len(set(values)):
        raise ValueError("building target 3 allowlist contains duplicates")
    if any(not INSTALLATION_ID_PATTERN.fullmatch(value) for value in values):
        raise ValueError("building target 3 allowlist contains an invalid installation ID")
    return frozenset(values)


def building_preprocessing_scope_mode() -> str:
    """Return the rollout mode for target-3 source preprocessing.

    ``shadow`` preserves the legacy artifact while recording the proposed
    selected-area plan. ``selected`` enables the bounded source/index/cache
    path. ``legacy`` disables even shadow planning for emergency rollback.
    """
    value = os.environ.get(
        "MAP_PLATFORM_BUILDING_PREPROCESSING_SCOPE_MODE",
        "shadow",
    ).strip().lower()
    if value not in {"legacy", "shadow", "selected"}:
        raise ValueError(
            "MAP_PLATFORM_BUILDING_PREPROCESSING_SCOPE_MODE must be "
            "legacy, shadow, or selected"
        )
    return value


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
