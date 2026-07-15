from __future__ import annotations

import json
import os
import re
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .geometry import bbox_area_km2
from .models import Bounds, SourceRegion
from .sources import SourceResolutionError, contains_bounds

DEFAULT_GEOFABRIK_INDEX_URL = "https://download.geofabrik.de/index-v1.json"
DEFAULT_CACHE_TTL_SECONDS = 24 * 60 * 60


@dataclass(frozen=True)
class GeofabrikCatalogRegion:
    source_region: SourceRegion
    geometry: dict[str, Any]


class GeofabrikSourceProvider:
    def __init__(
        self,
        index_url: str = DEFAULT_GEOFABRIK_INDEX_URL,
        *,
        cache_path: str | Path,
        cache_ttl_seconds: int = DEFAULT_CACHE_TTL_SECONDS,
        request_timeout_seconds: int = 60,
    ):
        self.index_url = index_url
        self.cache_path = Path(cache_path)
        self.cache_ttl_seconds = cache_ttl_seconds
        self.request_timeout_seconds = request_timeout_seconds
        self._regions: list[GeofabrikCatalogRegion] | None = None

    @classmethod
    def from_environment(cls, data_root: str | Path) -> "GeofabrikSourceProvider | None":
        enabled = os.environ.get("MAP_PLATFORM_DYNAMIC_SOURCE_DISCOVERY", "1").lower()
        if enabled in {"0", "false", "no", "off"}:
            return None
        data_root_path = Path(data_root)
        cache_path = Path(
            os.environ.get(
                "MAP_PLATFORM_GEOFABRIK_INDEX_CACHE",
                data_root_path / "source-catalogs" / "geofabrik-index-v1.json",
            )
        )
        return cls(
            os.environ.get("MAP_PLATFORM_GEOFABRIK_INDEX_URL", DEFAULT_GEOFABRIK_INDEX_URL),
            cache_path=cache_path,
            cache_ttl_seconds=int(os.environ.get("MAP_PLATFORM_GEOFABRIK_INDEX_TTL_SECONDS", DEFAULT_CACHE_TTL_SECONDS)),
            request_timeout_seconds=int(os.environ.get("MAP_PLATFORM_GEOFABRIK_TIMEOUT_SECONDS", "60")),
        )

    def source_regions(self) -> list[SourceRegion]:
        return [region.source_region for region in self._catalog_regions()]

    def resolve_for_bounds(self, bounds: Bounds) -> SourceRegion:
        containing = [
            region
            for region in self._catalog_regions()
            if contains_bounds(region.source_region.bounds, bounds) and _geometry_contains_bounds(region.geometry, bounds)
        ]
        if containing:
            return sorted(containing, key=lambda region: bbox_area_km2(region.source_region.bounds))[0].source_region
        raise SourceResolutionError("no Geofabrik source region covers the requested area")

    def preview_geometry_for_source(self, source: SourceRegion) -> dict[str, Any] | None:
        if source.preview_geometry is not None:
            return source.preview_geometry
        if source.provider != "geofabrik":
            return None
        matching = next(
            (
                region
                for region in self._catalog_regions()
                if region.source_region.url == source.url
            ),
            None,
        )
        return matching.geometry if matching is not None else None

    def _catalog_regions(self) -> list[GeofabrikCatalogRegion]:
        if self._regions is None:
            try:
                self._regions = self._parse_regions(self._load_catalog())
            except SourceResolutionError:
                raise
            except Exception as exc:
                raise SourceResolutionError(f"failed to load Geofabrik source catalog: {exc}") from exc
        return list(self._regions)

    def _load_catalog(self) -> dict[str, Any]:
        if self._cache_is_fresh():
            return json.loads(self.cache_path.read_text())

        try:
            with urllib.request.urlopen(self.index_url, timeout=self.request_timeout_seconds) as response:
                catalog = json.loads(response.read().decode("utf-8"))
        except Exception:
            if self.cache_path.exists():
                return json.loads(self.cache_path.read_text())
            raise

        self.cache_path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = self.cache_path.with_suffix(self.cache_path.suffix + ".tmp")
        tmp_path.write_text(json.dumps(catalog, indent=2, sort_keys=True) + "\n")
        tmp_path.replace(self.cache_path)
        return catalog

    def _cache_is_fresh(self) -> bool:
        if not self.cache_path.exists():
            return False
        if self.cache_ttl_seconds <= 0:
            return False
        return time.time() - self.cache_path.stat().st_mtime < self.cache_ttl_seconds

    def _parse_regions(self, catalog: dict[str, Any]) -> list[GeofabrikCatalogRegion]:
        features = catalog.get("features")
        if not isinstance(features, list):
            raise SourceResolutionError("Geofabrik catalog has no features")
        regions: list[GeofabrikCatalogRegion] = []
        for feature in features:
            try:
                region = self._region_from_feature(feature)
            except SourceResolutionError:
                continue
            if region is not None:
                regions.append(region)
        if not regions:
            raise SourceResolutionError("Geofabrik catalog has no PBF sources")
        return regions

    def _region_from_feature(self, feature: Any) -> GeofabrikCatalogRegion | None:
        if not isinstance(feature, dict):
            return None
        properties = feature.get("properties")
        geometry = feature.get("geometry")
        if not isinstance(properties, dict) or not isinstance(geometry, dict):
            return None
        source_id = str(properties.get("id", "")).strip()
        pbf_url = (properties.get("urls") or {}).get("pbf") if isinstance(properties.get("urls"), dict) else None
        if not source_id or not pbf_url:
            return None
        bounds = _bounds_for_geojson_geometry(geometry)
        safe_id = _safe_id(source_id)
        return GeofabrikCatalogRegion(
            source_region=SourceRegion(
                id=f"geofabrik-{safe_id}",
                provider="geofabrik",
                name=str(properties.get("name") or source_id),
                url=str(pbf_url),
                bounds=bounds,
                local_path=f"backend/data/source-pbf/geofabrik/{safe_id}-latest.osm.pbf",
                license="ODbL-1.0",
                preview_geometry=geometry,
            ),
            geometry=geometry,
        )


def _bounds_for_geojson_geometry(geometry: dict[str, Any]) -> Bounds:
    points = list(_iter_positions(geometry.get("coordinates")))
    if not points:
        raise SourceResolutionError("Geofabrik catalog feature has no coordinates")
    return Bounds(
        min(point[0] for point in points),
        min(point[1] for point in points),
        max(point[0] for point in points),
        max(point[1] for point in points),
    )


def _geometry_contains_bounds(geometry: dict[str, Any], bounds: Bounds) -> bool:
    points = [
        [bounds.min_lon, bounds.min_lat],
        [bounds.min_lon, bounds.max_lat],
        [bounds.max_lon, bounds.min_lat],
        [bounds.max_lon, bounds.max_lat],
        [(bounds.min_lon + bounds.max_lon) / 2.0, (bounds.min_lat + bounds.max_lat) / 2.0],
    ]
    return all(_geometry_contains_point(geometry, point) for point in points)


def _geometry_contains_point(geometry: dict[str, Any], point: list[float]) -> bool:
    geom_type = geometry.get("type")
    coordinates = geometry.get("coordinates")
    if geom_type == "Polygon":
        return _polygon_contains_point(coordinates, point)
    if geom_type == "MultiPolygon":
        return any(_polygon_contains_point(polygon, point) for polygon in coordinates or [])
    return False


def _polygon_contains_point(polygon: Any, point: list[float]) -> bool:
    if not isinstance(polygon, list) or not polygon:
        return False
    outer = polygon[0]
    holes = polygon[1:]
    return _ring_contains_point(outer, point) and not any(_ring_contains_point(hole, point) for hole in holes)


def _ring_contains_point(ring: Any, point: list[float]) -> bool:
    if not isinstance(ring, list) or len(ring) < 4:
        return False
    x, y = point
    inside = False
    previous = ring[-1]
    for current in ring:
        x1, y1 = float(previous[0]), float(previous[1])
        x2, y2 = float(current[0]), float(current[1])
        if _point_on_segment(x, y, x1, y1, x2, y2):
            return True
        crosses = (y1 > y) != (y2 > y)
        if crosses:
            x_intersection = (x2 - x1) * (y - y1) / (y2 - y1) + x1
            if x_intersection >= x:
                inside = not inside
        previous = current
    return inside


def _point_on_segment(x: float, y: float, x1: float, y1: float, x2: float, y2: float) -> bool:
    cross = (x - x1) * (y2 - y1) - (y - y1) * (x2 - x1)
    if abs(cross) > 1e-9:
        return False
    return min(x1, x2) - 1e-9 <= x <= max(x1, x2) + 1e-9 and min(y1, y2) - 1e-9 <= y <= max(y1, y2) + 1e-9


def _iter_positions(value: Any):
    if (
        isinstance(value, list)
        and len(value) >= 2
        and isinstance(value[0], (int, float))
        and isinstance(value[1], (int, float))
    ):
        yield [float(value[0]), float(value[1])]
        return
    if isinstance(value, list):
        for item in value:
            yield from _iter_positions(item)


def _safe_id(value: str) -> str:
    safe = re.sub(r"[^a-zA-Z0-9_-]+", "-", value.strip().lower()).strip("-")
    if not safe:
        raise SourceResolutionError("Geofabrik catalog feature has an invalid id")
    return safe
