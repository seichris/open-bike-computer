"""Deterministic, OSM-only building-height parsing and resolution."""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum
import math
import re
from typing import Any, Mapping


class HeightProvenance(IntEnum):
    EXPLICIT_HEIGHT = 0
    LEVELS = 1
    PARENT_INHERITANCE = 2
    LOCAL_OSM_MEDIAN = 3
    CLASS_DEFAULT = 4


PROVENANCE_NAMES = {
    HeightProvenance.EXPLICIT_HEIGHT: "explicitHeight",
    HeightProvenance.LEVELS: "levelsHeight",
    HeightProvenance.PARENT_INHERITANCE: "inheritedHeight",
    HeightProvenance.LOCAL_OSM_MEDIAN: "localMedianHeight",
    HeightProvenance.CLASS_DEFAULT: "classDefaultHeight",
}


@dataclass(frozen=True)
class HeightRules:
    minimum_meters: float
    maximum_meters: float
    maximum_levels: float
    floor_height_meters: float
    roof_level_height_meters: float
    cell_size_meters: int
    halo_cells: int
    minimum_samples: int
    class_ranges: dict[str, tuple[float, float]]
    class_defaults: dict[str, float]

    @classmethod
    def from_mapping(cls, value: Mapping[str, Any]) -> "HeightRules":
        if value.get("schemaVersion") != 1:
            raise ValueError("building-height rules schemaVersion must be 1")
        height = value.get("height")
        local = value.get("localMedian")
        ranges = value.get("classRangesMeters")
        defaults = value.get("classDefaultsMeters")
        if not all(isinstance(item, Mapping) for item in (height, local, ranges, defaults)):
            raise ValueError("building-height rules are incomplete")

        normalized_ranges: dict[str, tuple[float, float]] = {}
        normalized_defaults: dict[str, float] = {}
        for key, bounds in ranges.items():
            if (
                not isinstance(key, str)
                or not isinstance(bounds, list)
                or len(bounds) != 2
            ):
                raise ValueError("building class range is invalid")
            minimum, maximum = (float(bounds[0]), float(bounds[1]))
            if not math.isfinite(minimum) or not minimum < maximum:
                raise ValueError("building class range is invalid")
            normalized_ranges[key] = (minimum, maximum)
        for key, raw in defaults.items():
            number = float(raw)
            if not isinstance(key, str) or not math.isfinite(number) or number <= 0:
                raise ValueError("building class default is invalid")
            normalized_defaults[key] = number
        if "generic" not in normalized_ranges or "generic" not in normalized_defaults:
            raise ValueError("building-height rules require generic values")
        if set(normalized_defaults) - set(normalized_ranges):
            raise ValueError("building class default has no range")

        result = cls(
            minimum_meters=float(height["minimumMeters"]),
            maximum_meters=float(height["maximumMeters"]),
            maximum_levels=float(height["maximumLevels"]),
            floor_height_meters=float(height["floorHeightMeters"]),
            roof_level_height_meters=float(height["roofLevelHeightMeters"]),
            cell_size_meters=int(local["cellSizeMeters"]),
            halo_cells=int(local["haloCells"]),
            minimum_samples=int(local["minimumSamples"]),
            class_ranges=normalized_ranges,
            class_defaults=normalized_defaults,
        )
        if (
            not 0 < result.minimum_meters < result.maximum_meters
            or result.maximum_meters > 6553.5
            or result.maximum_levels <= 0
            or result.floor_height_meters <= 0
            or result.roof_level_height_meters <= 0
            or result.cell_size_meters <= 0
            or not 0 <= result.halo_cells <= 8
            or result.minimum_samples <= 0
        ):
            raise ValueError("building-height rules contain unsafe limits")
        return result


@dataclass(frozen=True)
class ResolvedHeight:
    height_dm: int
    minimum_height_dm: int
    provenance: HeightProvenance

    @property
    def height_meters(self) -> float:
        return self.height_dm / 10.0


_NUMBER = r"(?:\d+(?:\.\d+)?|\.\d+)"
_METERS_RE = re.compile(rf"^\s*({_NUMBER})\s*(?:m|meter|meters|metre|metres)?\s*$", re.I)
_LEVELS_RE = re.compile(rf"^\s*({_NUMBER})\s*$")
_FEET_RE = re.compile(
    rf"^\s*({_NUMBER})\s*(?:ft|feet|')\s*(?:({_NUMBER})\s*(?:in|inch|inches|\"))?\s*$",
    re.I,
)


def parse_length_meters(value: Any) -> float | None:
    """Parse one unambiguous OSM length; ranges/lists/descriptions fail closed."""
    if not isinstance(value, str) or not value or any(mark in value for mark in (";", "–", "—")):
        return None
    stripped = value.strip()
    if re.search(r"\d\s*-\s*\d", stripped):
        return None
    match = _METERS_RE.fullmatch(stripped)
    if match:
        result = float(match.group(1))
        return result if math.isfinite(result) else None
    match = _FEET_RE.fullmatch(stripped)
    if match:
        feet = float(match.group(1))
        inches = float(match.group(2) or 0.0)
        if inches >= 12:
            return None
        result = feet * 0.3048 + inches * 0.0254
        return result if math.isfinite(result) else None
    return None


def parse_levels(value: Any, maximum: float) -> float | None:
    if not isinstance(value, str) or not _LEVELS_RE.fullmatch(value.strip()):
        return None
    levels = float(_LEVELS_RE.fullmatch(value.strip()).group(1))
    return levels if math.isfinite(levels) and 0 < levels <= maximum else None


def normalized_building_class(tags: Mapping[str, Any], rules: HeightRules) -> str:
    raw = tags.get("building:part") or tags.get("building") or "generic"
    candidate = str(raw).strip().lower()
    return candidate if candidate in rules.class_defaults else "generic"


def direct_height(
    tags: Mapping[str, Any],
    rules: HeightRules,
    diagnostics: dict[str, int] | None = None,
) -> tuple[float, HeightProvenance] | None:
    explicit = parse_length_meters(tags.get("height"))
    if explicit is not None:
        if rules.minimum_meters <= explicit <= rules.maximum_meters:
            return explicit, HeightProvenance.EXPLICIT_HEIGHT
        _reject(diagnostics, "heightOutsideBounds")
    elif tags.get("height") not in (None, ""):
        _reject(diagnostics, "heightMalformed")

    levels = parse_levels(tags.get("building:levels"), rules.maximum_levels)
    if levels is None:
        if tags.get("building:levels") not in (None, ""):
            _reject(diagnostics, "levelsMalformed")
        return None
    roof = parse_length_meters(tags.get("roof:height"))
    if roof is None:
        if tags.get("roof:height") not in (None, ""):
            _reject(diagnostics, "roofHeightMalformed")
        roof_levels = parse_levels(tags.get("roof:levels"), rules.maximum_levels)
        if roof_levels is None and tags.get("roof:levels") not in (None, ""):
            _reject(diagnostics, "roofLevelsMalformed")
        roof = (roof_levels or 0.0) * rules.roof_level_height_meters
    result = levels * rules.floor_height_meters + roof
    if rules.minimum_meters <= result <= rules.maximum_meters:
        return result, HeightProvenance.LEVELS
    _reject(diagnostics, "levelsHeightOutsideBounds")
    return None


def resolve_height(
    tags: Mapping[str, Any],
    rules: HeightRules,
    *,
    parent: ResolvedHeight | None = None,
    local_median: float | None = None,
    diagnostics: dict[str, int] | None = None,
) -> ResolvedHeight:
    resolved = direct_height(tags, rules, diagnostics)
    building_class = normalized_building_class(tags, rules)
    class_minimum, class_maximum = rules.class_ranges.get(
        building_class, rules.class_ranges["generic"]
    )
    has_own_height_fields = any(
        tags.get(key) not in (None, "")
        for key in ("height", "building:levels", "roof:height", "roof:levels")
    )
    if (
        resolved is None
        and not has_own_height_fields
        and parent is not None
        and parent.provenance in {
            HeightProvenance.EXPLICIT_HEIGHT,
            HeightProvenance.LEVELS,
        }
    ):
        resolved = (parent.height_meters, HeightProvenance.PARENT_INHERITANCE)
    if resolved is None and local_median is not None and math.isfinite(local_median):
        resolved = (
            min(class_maximum, max(class_minimum, local_median)),
            HeightProvenance.LOCAL_OSM_MEDIAN,
        )
    if resolved is None:
        resolved = (
            min(class_maximum, max(class_minimum, rules.class_defaults[building_class])),
            HeightProvenance.CLASS_DEFAULT,
        )

    height_dm = _decimeters(resolved[0])
    minimum = parse_length_meters(tags.get("min_height"))
    if minimum is None:
        if tags.get("min_height") not in (None, ""):
            _reject(diagnostics, "minimumHeightMalformed")
        minimum_levels = parse_levels(tags.get("building:min_level"), rules.maximum_levels)
        if minimum_levels is None and tags.get("building:min_level") not in (None, ""):
            _reject(diagnostics, "minimumLevelsMalformed")
        minimum = (minimum_levels or 0.0) * rules.floor_height_meters
    minimum_dm = max(0, _decimeters(minimum))
    if minimum_dm >= height_dm:
        _reject(diagnostics, "minimumHeightNotBelowHeight")
        minimum_dm = 0
    return ResolvedHeight(height_dm, minimum_dm, resolved[1])


def _decimeters(value: float) -> int:
    return max(0, min(65535, int(math.floor(value * 10.0 + 0.5))))


def _reject(diagnostics: dict[str, int] | None, reason: str) -> None:
    if diagnostics is not None:
        diagnostics[reason] = diagnostics.get(reason, 0) + 1
