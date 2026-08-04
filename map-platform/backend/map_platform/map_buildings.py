from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
from typing import Any

import yaml


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


@dataclass(frozen=True)
class BuildingCalibrationWindow:
    cell_size_meters: int
    halo_cells: int


def load_building_calibration_window(path: Path) -> BuildingCalibrationWindow:
    try:
        value = yaml.safe_load(path.read_text(encoding="utf-8"))
        local = value["localMedian"]
        cell_size = local["cellSizeMeters"]
        halo_cells = local["haloCells"]
    except (OSError, TypeError, KeyError, yaml.YAMLError) as exc:
        raise ValueError("building height rules are invalid") from exc
    if (
        isinstance(cell_size, bool)
        or not isinstance(cell_size, int)
        or cell_size <= 0
        or isinstance(halo_cells, bool)
        or not isinstance(halo_cells, int)
        or not 0 <= halo_cells <= 8
    ):
        raise ValueError("building calibration window is invalid")
    return BuildingCalibrationWindow(cell_size, halo_cells)


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
