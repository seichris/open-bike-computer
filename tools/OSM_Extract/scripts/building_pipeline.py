"""Typed OSM building normalization, height resolution, and seam-safe clipping."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, replace
import hashlib
import json
import math
from pathlib import Path
import statistics
from typing import Any, Iterable, Mapping

import yaml
from shapely.geometry import LineString, MultiPolygon, Polygon, shape
from shapely.geometry.polygon import orient
from shapely.prepared import prep

from building_height import (
    HeightProvenance,
    HeightRules,
    PROVENANCE_NAMES,
    ResolvedHeight,
    direct_height,
    normalized_building_class,
    resolve_height,
)
from feature_types import get_type_id
from funcs import parse_tags


BUILDING_PROFILE_VERSION = 1
BUILDING_FLAG_PART = 1 << 0
RING_FLAG_HOLE = 1 << 0


@dataclass(frozen=True)
class SourceBuilding:
    object_key: str
    building_class: str
    is_part: bool
    geometry: Polygon | MultiPolygon
    tags: dict[str, str]
    resolved: ResolvedHeight | None = None
    association: str = "none"
    parent_key: str | None = None
    extrude: bool = True


def load_rules(path: str | Path) -> tuple[HeightRules, str]:
    path = Path(path)
    raw = path.read_bytes()
    rules = HeightRules.from_mapping(yaml.safe_load(raw))
    return rules, hashlib.sha256(raw).hexdigest()


def load_relation_index(path: str | Path) -> dict[str, Any]:
    path = Path(path)
    if not path.is_file():
        return {"schemaVersion": 1, "partParents": {}, "relations": 0, "ambiguousParts": 0}
    value = json.loads(path.read_text(encoding="utf-8"))
    if (
        not isinstance(value, dict)
        or value.get("schemaVersion") != 1
        or not isinstance(value.get("partParents"), dict)
    ):
        raise ValueError("building relation index is invalid")
    return value


def prepare_buildings(
    features: Iterable[Mapping[str, Any]],
    rules: HeightRules,
    relation_index: Mapping[str, Any] | None = None,
) -> tuple[list[SourceBuilding], dict[str, Any], set[str]]:
    diagnostics: dict[str, int] = {}
    sources: list[SourceBuilding] = []
    for feature in features:
        source = _source_building(feature, rules, diagnostics)
        if source is not None:
            sources.append(source)
    sources.sort(key=lambda item: item.object_key)
    by_key = {source.object_key: source for source in sources}
    part_parents = dict((relation_index or {}).get("partParents", {}))

    associated: list[SourceBuilding] = []
    outlines = [source for source in sources if not source.is_part]
    prepared_outlines = [
        (outline, prep(outline.geometry.buffer(0.05))) for outline in outlines
    ]
    for source in sources:
        if not source.is_part:
            associated.append(source)
            continue
        parent_key = part_parents.get(source.object_key)
        association = "relation" if parent_key in by_key else "none"
        if association == "none":
            parent_key = _containment_parent(source, prepared_outlines)
            association = "containment" if parent_key is not None else "none"
        associated.append(replace(source, parent_key=parent_key, association=association))
    sources = associated
    by_key = {source.object_key: source for source in sources}

    direct: dict[str, ResolvedHeight] = {}
    calibration: dict[tuple[int, int, str], list[float]] = defaultdict(list)
    for source in sources:
        candidate = direct_height(source.tags, rules, diagnostics)
        if candidate is None:
            continue
        resolved = resolve_height(source.tags, rules, diagnostics=diagnostics)
        direct[source.object_key] = resolved
        cell_x, cell_y = _calibration_cell(source.geometry, rules.cell_size_meters)
        calibration[(cell_x, cell_y, source.building_class)].append(candidate[0])

    resolved_sources: list[SourceBuilding] = []
    for source in sources:
        parent = direct.get(source.parent_key or "")
        local_median = _local_median(source, calibration, rules)
        resolved = resolve_height(
            source.tags,
            rules,
            parent=parent,
            local_median=local_median,
            diagnostics=diagnostics,
        )
        resolved_sources.append(replace(source, resolved=resolved))

    part_parent_keys = {
        source.parent_key
        for source in resolved_sources
        if source.is_part and source.parent_key is not None
    }
    resolved_sources = [
        replace(source, extrude=source.object_key not in part_parent_keys)
        for source in resolved_sources
    ]
    flat_outline_keys = {key for key in part_parent_keys if key is not None}

    provenance_counts = {name + "Count": 0 for name in PROVENANCE_NAMES.values()}
    holes = 0
    for source in resolved_sources:
        if source.extrude and source.resolved is not None:
            provenance_counts[
                PROVENANCE_NAMES[source.resolved.provenance] + "Count"
            ] += 1
        holes += sum(len(polygon.interiors) for polygon in _polygons(source.geometry))
    report = {
        "profileVersion": BUILDING_PROFILE_VERSION,
        "sourceCount": len(resolved_sources),
        "outlineCount": sum(not source.is_part for source in resolved_sources),
        "partCount": sum(source.is_part for source in resolved_sources),
        "extrudedSourceCount": sum(source.extrude for source in resolved_sources),
        "flatOutlineCount": len(flat_outline_keys),
        "holeCount": holes,
        "relationAssociationCount": sum(source.association == "relation" for source in resolved_sources),
        "containmentAssociationCount": sum(source.association == "containment" for source in resolved_sources),
        "unassociatedPartCount": sum(source.is_part and source.parent_key is None for source in resolved_sources),
        "rejectedTags": dict(sorted(diagnostics.items())),
        **provenance_counts,
    }
    return resolved_sources, report, flat_outline_keys


def clip_buildings(
    buildings: Iterable[SourceBuilding],
    block: Polygon,
    min_x: int,
    min_y: int,
    *,
    tolerance: float = 0.05,
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    records: list[dict[str, Any]] = []
    suppressed_walls = 0
    emitted_walls = 0
    points = 0
    provenance_counts = {name + "Count": 0 for name in PROVENANCE_NAMES.values()}
    for source in buildings:
        if not source.extrude or source.resolved is None:
            continue
        if not source.geometry.intersects(block) or source.geometry.touches(block):
            continue
        clipped = source.geometry.intersection(block)
        for fragment in _polygons(clipped):
            if fragment.is_empty or not fragment.is_valid:
                continue
            oriented = orient(fragment, sign=1.0)
            original_boundary = source.geometry.boundary
            rings: list[dict[str, Any]] = []
            for ring_index, ring in enumerate([oriented.exterior, *oriented.interiors]):
                coordinates = list(ring.coords)
                if len(coordinates) > 1 and coordinates[0] == coordinates[-1]:
                    coordinates.pop()
                local = _rounded_ring(coordinates, min_x, min_y)
                if len(local) < 3:
                    continue
                local, _rotation = _canonical_rotation(local)
                source_coordinates = [
                    (point[0] + min_x, point[1] + min_y) for point in local
                ]
                walls: list[bool] = []
                for index, start in enumerate(source_coordinates):
                    end = source_coordinates[(index + 1) % len(source_coordinates)]
                    segment = LineString((start, end))
                    is_original = original_boundary.buffer(
                        tolerance, cap_style=2, join_style=2
                    ).covers(segment)
                    walls.append(bool(is_original))
                    if is_original:
                        emitted_walls += 1
                    else:
                        suppressed_walls += 1
                rings.append(
                    {
                        "flags": RING_FLAG_HOLE if ring_index > 0 else 0,
                        "points": local,
                        "walls": walls,
                    }
                )
                points += len(local)
            if not rings or rings[0]["flags"] != 0:
                continue
            bounds = [coordinate for ring in rings for coordinate in ring["points"]]
            records.append(
                {
                    "type_id": get_type_id(f"building.{source.building_class}"),
                    "flags": BUILDING_FLAG_PART if source.is_part else 0,
                    "provenance": int(source.resolved.provenance),
                    "height_dm": source.resolved.height_dm,
                    "minimum_height_dm": source.resolved.minimum_height_dm,
                    "bbox": (
                        min(point[0] for point in bounds),
                        min(point[1] for point in bounds),
                        max(point[0] for point in bounds),
                        max(point[1] for point in bounds),
                    ),
                    "rings": rings,
                    "source_key": source.object_key,
                }
            )
            provenance_counts[
                PROVENANCE_NAMES[source.resolved.provenance] + "Count"
            ] += 1
    records.sort(
        key=lambda item: (
            item["bbox"], item["height_dm"], item["source_key"], item["flags"]
        )
    )
    return records, {
        "recordCount": len(records),
        "pointCount": points,
        "emittedWallCount": emitted_walls,
        "suppressedWallCount": suppressed_walls,
        **provenance_counts,
    }


def source_object_key(properties: Mapping[str, Any]) -> str:
    if properties.get("osm_way_id") not in (None, ""):
        return f"w{properties['osm_way_id']}"
    raw = properties.get("osm_id")
    if raw in (None, ""):
        return ""
    # GDAL uses osm_id for assembled multipolygon relations and osm_way_id for
    # closed ways in the multipolygons layer.
    return f"r{raw}"


def _source_building(
    feature: Mapping[str, Any],
    rules: HeightRules,
    diagnostics: dict[str, int],
) -> SourceBuilding | None:
    properties = feature.get("properties")
    if not isinstance(properties, Mapping):
        return None
    tags = parse_tags(properties.get("other_tags"))
    for key in (
        "building", "building:part", "height", "min_height",
        "building:levels", "building:min_level", "roof:height", "roof:levels",
    ):
        if properties.get(key) not in (None, ""):
            tags[key] = str(properties[key])
    if tags.get("building") in (None, "no") and tags.get("building:part") in (None, "no"):
        return None
    object_key = source_object_key(properties)
    if not object_key:
        diagnostics["missingObjectIdentity"] = diagnostics.get("missingObjectIdentity", 0) + 1
        return None
    try:
        geometry = shape(feature.get("geometry"))
    except (TypeError, ValueError):
        diagnostics["invalidGeometry"] = diagnostics.get("invalidGeometry", 0) + 1
        return None
    if not isinstance(geometry, (Polygon, MultiPolygon)) or geometry.is_empty or not geometry.is_valid:
        diagnostics["invalidGeometry"] = diagnostics.get("invalidGeometry", 0) + 1
        return None
    return SourceBuilding(
        object_key=object_key,
        building_class=normalized_building_class(tags, rules),
        is_part=tags.get("building:part") not in (None, "", "no"),
        geometry=geometry,
        tags=dict(sorted(tags.items())),
    )


def _containment_parent(part: SourceBuilding, outlines) -> str | None:
    candidates = [
        outline
        for outline, prepared in outlines
        if outline.geometry.envelope.covers(part.geometry.envelope)
        and prepared.covers(part.geometry)
    ]
    if not candidates:
        return None
    return min(candidates, key=lambda item: (item.geometry.area, item.object_key)).object_key


def _calibration_cell(geometry: Polygon | MultiPolygon, size: int) -> tuple[int, int]:
    point = geometry.representative_point()
    return math.floor(point.x / size), math.floor(point.y / size)


def _local_median(
    source: SourceBuilding,
    calibration: Mapping[tuple[int, int, str], list[float]],
    rules: HeightRules,
) -> float | None:
    cell_x, cell_y = _calibration_cell(source.geometry, rules.cell_size_meters)
    samples: list[float] = []
    for x in range(cell_x - rules.halo_cells, cell_x + rules.halo_cells + 1):
        for y in range(cell_y - rules.halo_cells, cell_y + rules.halo_cells + 1):
            samples.extend(calibration.get((x, y, source.building_class), ()))
    return statistics.median(sorted(samples)) if len(samples) >= rules.minimum_samples else None


def _polygons(geometry) -> list[Polygon]:
    if isinstance(geometry, Polygon):
        return [geometry]
    if isinstance(geometry, MultiPolygon):
        return list(geometry.geoms)
    return []


def _rounded_ring(
    coordinates: Iterable[tuple[float, float]], min_x: int, min_y: int
) -> list[tuple[int, int]]:
    result: list[tuple[int, int]] = []
    for x, y in coordinates:
        point = (int(math.floor(x - min_x + 0.5)), int(math.floor(y - min_y + 0.5)))
        if not result or result[-1] != point:
            result.append(point)
    if len(result) > 1 and result[0] == result[-1]:
        result.pop()
    if any(not -32768 <= value <= 32767 for point in result for value in point):
        raise ValueError("building coordinate exceeds int16")
    return result


def _canonical_rotation(
    points: list[tuple[int, int]],
) -> tuple[list[tuple[int, int]], int]:
    rotation = min(range(len(points)), key=lambda index: (points[index], points[(index + 1) % len(points)]))
    return points[rotation:] + points[:rotation], rotation
