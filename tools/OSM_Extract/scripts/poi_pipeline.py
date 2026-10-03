"""Deterministic OSM point-of-interest normalization for FMB v5."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
import hashlib
import math
from pathlib import Path
from typing import Any, Iterable, Mapping

import yaml
from shapely.geometry import MultiPolygon, Point, Polygon, shape
from shapely.geometry.base import BaseGeometry


POI_PROFILE_VERSION = 1
MAX_BLOCK_POIS = 16_384
_EXPECTED_CATEGORY_KEYS = (
    "shops",
    "restaurants_and_cafes",
    "public_toilets",
    "gas_stations",
    "bicycle_services",
)
_EXPECTED_CATEGORY_IDS = tuple(range(1, 6))


class PoiPipelineError(ValueError):
    code = "poi_artifact_validation_failed"


class PoiPipelineLimitError(PoiPipelineError):
    code = "poi_artifact_too_large"


@dataclass(frozen=True)
class PoiCategory:
    category_id: int
    key: str
    maximum_zoom: int
    rank: int


@dataclass(frozen=True)
class PoiConfig:
    profile_version: int
    block_size_meters: int
    inactive_shop_values: frozenset[str]
    categories: tuple[PoiCategory, ...]
    sha256: str

    @property
    def by_id(self) -> dict[int, PoiCategory]:
        return {category.category_id: category for category in self.categories}


@dataclass(frozen=True)
class PoiRecord:
    block_x: int
    block_y: int
    local_x: int
    local_y: int
    category: int
    maximum_zoom: int
    rank: int
    object_key: str
    component_index: int
    source_kind: str

    def encoded(self) -> dict[str, int]:
        return {
            "local_x": self.local_x,
            "local_y": self.local_y,
            "category": self.category,
            "maximum_zoom": self.maximum_zoom,
            "rank": self.rank,
            "flags": 0,
        }


def _strict_integer(value: Any, *, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise PoiPipelineError("POI configuration integer is invalid")
    if not minimum <= value <= maximum:
        raise PoiPipelineError("POI configuration integer is out of range")
    return value


def _string_list(value: Any) -> tuple[str, ...]:
    if (
        not isinstance(value, list)
        or not value
        or any(not isinstance(item, str) or not item for item in value)
        or len(value) != len(set(value))
    ):
        raise PoiPipelineError("POI configuration string list is invalid")
    return tuple(value)


def load_poi_config(path: str | Path) -> PoiConfig:
    path = Path(path)
    try:
        raw = path.read_bytes()
        value = yaml.safe_load(raw)
    except (OSError, yaml.YAMLError) as exc:
        raise PoiPipelineError("POI category configuration is unavailable") from exc
    if not isinstance(value, dict) or set(value) != {
        "schemaVersion",
        "profileVersion",
        "blockSizeMeters",
        "inactiveShopValues",
        "categories",
    }:
        raise PoiPipelineError("POI category configuration fields are invalid")
    if value["schemaVersion"] != 1 or value["profileVersion"] != POI_PROFILE_VERSION:
        raise PoiPipelineError("POI category configuration version is unsupported")
    block_size = _strict_integer(
        value["blockSizeMeters"], minimum=1, maximum=32_767
    )
    if block_size != 4096:
        raise PoiPipelineError("POI block size must match the FMB grid")
    inactive = frozenset(item.strip().lower() for item in _string_list(value["inactiveShopValues"]))
    if inactive != {"closed", "no", "vacant"}:
        raise PoiPipelineError("POI inactive shop values do not match profile 1")
    raw_categories = value["categories"]
    if not isinstance(raw_categories, list) or len(raw_categories) != 5:
        raise PoiPipelineError("POI category configuration requires five categories")
    categories: list[PoiCategory] = []
    expected_match_shapes = (
        ({"match", "exclude"}, {"shop": "*"}, {"shop": ["bicycle"]}),
        ({"match"}, {"amenity": ["cafe", "fast_food", "restaurant"]}, None),
        ({"match"}, {"amenity": ["toilets"]}, None),
        ({"match"}, {"amenity": ["fuel"]}, None),
        (
            {"matchAny"},
            [
                {"shop": ["bicycle"]},
                {"amenity": ["bicycle_repair_station"]},
            ],
            None,
        ),
    )
    for index, raw_category in enumerate(raw_categories):
        if not isinstance(raw_category, dict):
            raise PoiPipelineError("POI category entry is invalid")
        common = {"id", "key", "maximumZoom", "rank"}
        match_fields, expected_match, expected_exclude = expected_match_shapes[index]
        if set(raw_category) != common | match_fields:
            raise PoiPipelineError("POI category entry fields are invalid")
        category_id = _strict_integer(raw_category["id"], minimum=1, maximum=5)
        key = raw_category["key"]
        if category_id != index + 1 or key != _EXPECTED_CATEGORY_KEYS[index]:
            raise PoiPipelineError("POI category IDs and keys are not canonical")
        match_key = next(iter(match_fields - {"exclude"}))
        if raw_category[match_key] != expected_match:
            raise PoiPipelineError("POI category match rules do not match profile 1")
        if expected_exclude is not None and raw_category["exclude"] != expected_exclude:
            raise PoiPipelineError("POI category exclusions do not match profile 1")
        categories.append(
            PoiCategory(
                category_id=category_id,
                key=key,
                maximum_zoom=_strict_integer(
                    raw_category["maximumZoom"], minimum=0, maximum=5
                ),
                rank=_strict_integer(raw_category["rank"], minimum=0, maximum=3),
            )
        )
    return PoiConfig(
        profile_version=POI_PROFILE_VERSION,
        block_size_meters=block_size,
        inactive_shop_values=inactive,
        categories=tuple(categories),
        sha256=hashlib.sha256(raw).hexdigest(),
    )


def _parse_other_tags(value: Any) -> tuple[dict[str, str], int]:
    if value in (None, ""):
        return {}, 0
    if not isinstance(value, str):
        return {}, 1
    tags: dict[str, str] = {}
    malformed = 0
    for item in value.split('\",\"'):
        normalized = item.replace('"', "")
        parts = normalized.split("=>", 1)
        if len(parts) != 2 or not parts[0]:
            malformed += 1
            continue
        tags[parts[0].strip().lower()] = parts[1].strip().lower()
    return tags, malformed


def _normalized_tags(properties: Mapping[str, Any]) -> tuple[dict[str, str], int]:
    tags, malformed = _parse_other_tags(properties.get("other_tags"))
    for key in ("amenity", "shop", "name"):
        raw = properties.get(key)
        if raw not in (None, ""):
            tags[key] = str(raw).strip().lower()
    return tags, malformed


def classify_poi(tags: Mapping[str, str], config: PoiConfig) -> PoiCategory | None:
    amenity = tags.get("amenity", "").strip().lower()
    shop = tags.get("shop", "").strip().lower()
    categories = config.by_id
    if shop == "bicycle" or amenity == "bicycle_repair_station":
        return categories[5]
    if amenity in {"restaurant", "cafe", "fast_food"}:
        return categories[2]
    if amenity == "toilets":
        return categories[3]
    if amenity == "fuel":
        return categories[4]
    if shop and shop not in config.inactive_shop_values:
        return categories[1]
    return None


def _positive_osm_id(value: Any) -> str | None:
    if isinstance(value, bool) or value in (None, ""):
        return None
    text = str(value)
    if not text.isdigit() or int(text) <= 0:
        return None
    return str(int(text))


def _object_key(properties: Mapping[str, Any], source_kind: str) -> str | None:
    if source_kind == "point":
        identifier = _positive_osm_id(properties.get("osm_id"))
        return f"n{identifier}" if identifier else None
    way_id = _positive_osm_id(properties.get("osm_way_id"))
    if way_id:
        return f"w{way_id}"
    relation_id = _positive_osm_id(properties.get("osm_id"))
    return f"r{relation_id}" if relation_id else None


def _polygon_components(geometry: BaseGeometry) -> tuple[Polygon, ...]:
    if isinstance(geometry, Polygon):
        return (geometry,)
    if not isinstance(geometry, MultiPolygon):
        return ()
    return tuple(
        sorted(
            geometry.geoms,
            key=lambda item: (item.bounds, item.area, item.wkb),
        )
    )


def _quantize_anchor(
    point: Point, block_size: int
) -> tuple[int, int, int, int] | None:
    x = float(point.x)
    y = float(point.y)
    if not math.isfinite(x) or not math.isfinite(y):
        return None
    block_x = math.floor(x / block_size) * block_size
    block_y = math.floor(y / block_size) * block_size
    local_x = math.floor(x) - block_x
    local_y = math.floor(y) - block_y
    if not 0 <= local_x < block_size or not 0 <= local_y < block_size:
        return None
    return block_x, block_y, local_x, local_y


def prepare_pois(
    point_features: Iterable[Mapping[str, Any]],
    area_features: Iterable[Mapping[str, Any]],
    config: PoiConfig,
    *,
    selection_geometry: BaseGeometry | None = None,
) -> tuple[tuple[PoiRecord, ...], dict[str, Any]]:
    records: list[PoiRecord] = []
    diagnostics: Counter[str] = Counter()
    seen: set[tuple[str, int]] = set()

    for source_kind, features in (("point", point_features), ("area", area_features)):
        for feature in features:
            diagnostics["sourceFeatures"] += 1
            properties = feature.get("properties")
            if not isinstance(properties, Mapping):
                diagnostics["malformedProperties"] += 1
                continue
            tags, malformed_tags = _normalized_tags(properties)
            diagnostics["malformedOtherTags"] += malformed_tags
            category = classify_poi(tags, config)
            if category is None:
                if tags.get("shop") in config.inactive_shop_values:
                    diagnostics["inactiveRecords"] += 1
                continue
            object_key = _object_key(properties, source_kind)
            if object_key is None:
                diagnostics["missingObjectIdentity"] += 1
                continue
            try:
                geometry = shape(feature.get("geometry"))
            except (TypeError, ValueError):
                diagnostics["invalidGeometry"] += 1
                continue
            if geometry.is_empty or not geometry.is_valid:
                diagnostics["invalidGeometry"] += 1
                continue
            if source_kind == "point":
                if not isinstance(geometry, Point):
                    diagnostics["invalidGeometryType"] += 1
                    continue
                components: tuple[BaseGeometry, ...] = (geometry,)
            else:
                components = _polygon_components(geometry)
                if not components:
                    diagnostics["invalidGeometryType"] += 1
                    continue
            for component_index, component in enumerate(components):
                if (
                    selection_geometry is not None
                    and not component.intersects(selection_geometry)
                ):
                    diagnostics["outsideSelection"] += 1
                    continue
                identity = (object_key, component_index)
                if identity in seen:
                    diagnostics["exactIdentityDuplicatesRemoved"] += 1
                    continue
                seen.add(identity)
                anchor = component if isinstance(component, Point) else component.representative_point()
                quantized = _quantize_anchor(anchor, config.block_size_meters)
                if quantized is None:
                    diagnostics["invalidCoordinate"] += 1
                    continue
                block_x, block_y, local_x, local_y = quantized
                records.append(
                    PoiRecord(
                        block_x=block_x,
                        block_y=block_y,
                        local_x=local_x,
                        local_y=local_y,
                        category=category.category_id,
                        maximum_zoom=category.maximum_zoom,
                        rank=category.rank,
                        object_key=object_key,
                        component_index=component_index,
                        source_kind=source_kind,
                    )
                )

    records.sort(
        key=lambda item: (
            item.block_x,
            item.block_y,
            item.local_x,
            item.local_y,
            item.category,
            item.rank,
            item.object_key[0],
            int(item.object_key[1:]),
            item.component_index,
        )
    )
    per_block = Counter((record.block_x, record.block_y) for record in records)
    if per_block and max(per_block.values()) > MAX_BLOCK_POIS:
        raise PoiPipelineLimitError("POI record count exceeds the FMB v5 block limit")
    category_counts = Counter(record.category for record in records)
    return tuple(records), {
        "profileVersion": config.profile_version,
        "configSha256": config.sha256,
        "recordCount": len(records),
        "shopsCount": category_counts[1],
        "restaurantsAndCafesCount": category_counts[2],
        "publicToiletsCount": category_counts[3],
        "gasStationsCount": category_counts[4],
        "bicycleServicesCount": category_counts[5],
        "pointRecordCount": sum(record.source_kind == "point" for record in records),
        "areaRecordCount": sum(record.source_kind == "area" for record in records),
        "blocksWithPois": len(per_block),
        "maximumBlockRecords": max(per_block.values(), default=0),
        **dict(sorted(diagnostics.items())),
    }


def records_by_block(records: Iterable[PoiRecord]) -> dict[tuple[int, int], tuple[PoiRecord, ...]]:
    grouped: dict[tuple[int, int], list[PoiRecord]] = {}
    for record in records:
        grouped.setdefault((record.block_x, record.block_y), []).append(record)
    return {key: tuple(value) for key, value in sorted(grouped.items())}
