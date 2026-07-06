from __future__ import annotations

import math
from typing import Any

from .models import Bounds, GeometryMode, NormalizedGeometry

MAX_CUSTOM_AREA_KM2 = 250_000.0
MAX_POLYGON_VERTICES = 5_000
MAX_ROUTE_POINTS = 25_000
MAX_CORRIDOR_WIDTH_M = 50_000.0
EARTH_KM_PER_DEG_LAT = 111.32


class GeometryError(ValueError):
    """Raised when a requested map geometry is invalid or too large."""


def normalize_bbox(values: list[float] | tuple[float, float, float, float]) -> Bounds:
    bounds = Bounds.from_list(values)
    if not -180 <= bounds.min_lon <= 180 or not -180 <= bounds.max_lon <= 180:
        raise GeometryError("longitude must be between -180 and 180")
    if not -85.05112878 <= bounds.min_lat <= 85.05112878 or not -85.05112878 <= bounds.max_lat <= 85.05112878:
        raise GeometryError("latitude must be inside Web Mercator bounds")
    if bounds.min_lon >= bounds.max_lon:
        raise GeometryError("minLon must be less than maxLon")
    if bounds.min_lat >= bounds.max_lat:
        raise GeometryError("minLat must be less than maxLat")
    return bounds


def bbox_area_km2(bounds: Bounds) -> float:
    center_lat = (bounds.min_lat + bounds.max_lat) / 2.0
    km_per_deg_lon = EARTH_KM_PER_DEG_LAT * max(math.cos(math.radians(center_lat)), 0.01)
    width_km = (bounds.max_lon - bounds.min_lon) * km_per_deg_lon
    height_km = (bounds.max_lat - bounds.min_lat) * EARTH_KM_PER_DEG_LAT
    return abs(width_km * height_km)


def ensure_area_limit(bounds: Bounds, max_area_km2: float = MAX_CUSTOM_AREA_KM2) -> float:
    area = bbox_area_km2(bounds)
    if area > max_area_km2:
        raise GeometryError(f"requested area is too large: {area:.0f} km2 > {max_area_km2:.0f} km2")
    return area


def normalize_geometry(request: dict[str, Any]) -> NormalizedGeometry:
    try:
        mode = GeometryMode(str(request.get("mode", "")))
    except ValueError as exc:
        raise GeometryError(f"unsupported geometry mode: {request.get('mode')}") from exc
    if mode == GeometryMode.CUSTOM_BBOX:
        bounds = normalize_bbox(request.get("bbox", []))
        area = ensure_area_limit(bounds)
        return NormalizedGeometry(mode=mode, bounds=bounds, area_km2=area, vertex_count=4)

    if mode == GeometryMode.CUSTOM_POLYGON:
        geometry = request.get("geometry")
        return normalize_polygon_geometry(geometry)

    if mode == GeometryMode.ROUTE_CORRIDOR:
        route = request.get("route")
        width_m = float(request.get("corridorWidthM", 0))
        return normalize_route_corridor(route, width_m)

    if mode == GeometryMode.CURATED_REGION:
        bounds = normalize_bbox(request.get("bbox", []))
        area = ensure_area_limit(bounds)
        return NormalizedGeometry(mode=mode, bounds=bounds, area_km2=area, vertex_count=4)

    raise GeometryError(f"unsupported geometry mode: {mode}")


def normalize_polygon_geometry(geometry: dict[str, Any] | None) -> NormalizedGeometry:
    if not isinstance(geometry, dict):
        raise GeometryError("geometry must be a GeoJSON Polygon or MultiPolygon")
    geom_type = geometry.get("type")
    coordinates = geometry.get("coordinates")
    if geom_type == "Polygon":
        rings = _validate_polygon_coordinates(coordinates)
        bounds = _bounds_for_points([point for ring in rings for point in ring])
        area = ensure_area_limit(bounds)
        vertex_count = sum(len(ring) for ring in rings)
        _reject_self_intersection(rings[0])
        return NormalizedGeometry(
            mode=GeometryMode.CUSTOM_POLYGON,
            bounds=bounds,
            area_km2=area,
            vertex_count=vertex_count,
            geometry={"type": "Polygon", "coordinates": rings},
        )
    if geom_type == "MultiPolygon":
        polygons = []
        all_points: list[list[float]] = []
        vertex_count = 0
        for polygon in coordinates or []:
            rings = _validate_polygon_coordinates(polygon)
            _reject_self_intersection(rings[0])
            polygons.append(rings)
            vertex_count += sum(len(ring) for ring in rings)
            all_points.extend(point for ring in rings for point in ring)
        if not polygons:
            raise GeometryError("multipolygon must contain at least one polygon")
        if vertex_count > MAX_POLYGON_VERTICES:
            raise GeometryError("polygon has too many vertices")
        bounds = _bounds_for_points(all_points)
        area = ensure_area_limit(bounds)
        return NormalizedGeometry(
            mode=GeometryMode.CUSTOM_POLYGON,
            bounds=bounds,
            area_km2=area,
            vertex_count=vertex_count,
            geometry={"type": "MultiPolygon", "coordinates": polygons},
        )
    raise GeometryError("geometry must be a GeoJSON Polygon or MultiPolygon")


def normalize_route_corridor(route: dict[str, Any] | list[Any] | None, corridor_width_m: float) -> NormalizedGeometry:
    if corridor_width_m <= 0 or corridor_width_m > MAX_CORRIDOR_WIDTH_M:
        raise GeometryError("corridorWidthM must be greater than 0 and within the configured limit")
    points = _route_points(route)
    if len(points) < 2:
        raise GeometryError("route corridor needs at least two route points")
    if len(points) > MAX_ROUTE_POINTS:
        raise GeometryError("route has too many points")
    route_bounds = _bounds_for_route_points(points)
    expanded = expand_bounds_meters(route_bounds, corridor_width_m)
    area = ensure_area_limit(expanded)
    return NormalizedGeometry(
        mode=GeometryMode.ROUTE_CORRIDOR,
        bounds=expanded,
        area_km2=area,
        vertex_count=4,
        route_point_count=len(points),
        corridor_width_m=corridor_width_m,
        geometry={"type": "LineString", "coordinates": points},
    )


def expand_bounds_meters(bounds: Bounds, meters: float) -> Bounds:
    center_lat = (bounds.min_lat + bounds.max_lat) / 2.0
    lat_delta = meters / (EARTH_KM_PER_DEG_LAT * 1000.0)
    lon_delta = meters / (EARTH_KM_PER_DEG_LAT * 1000.0 * max(math.cos(math.radians(center_lat)), 0.01))
    return normalize_bbox(
        [
            max(-180.0, bounds.min_lon - lon_delta),
            max(-85.05112878, bounds.min_lat - lat_delta),
            min(180.0, bounds.max_lon + lon_delta),
            min(85.05112878, bounds.max_lat + lat_delta),
        ]
    )


def _validate_polygon_coordinates(coordinates: Any) -> list[list[list[float]]]:
    if not isinstance(coordinates, list) or not coordinates:
        raise GeometryError("polygon coordinates must contain at least one ring")
    rings: list[list[list[float]]] = []
    vertex_count = 0
    for raw_ring in coordinates:
        if not isinstance(raw_ring, list) or len(raw_ring) < 4:
            raise GeometryError("polygon ring must contain at least four positions")
        ring: list[list[float]] = []
        for raw_point in raw_ring:
            point = _normalize_point(raw_point)
            ring.append(point)
        if ring[0] != ring[-1]:
            raise GeometryError("polygon rings must be closed")
        vertex_count += len(ring)
        rings.append(ring)
    if vertex_count > MAX_POLYGON_VERTICES:
        raise GeometryError("polygon has too many vertices")
    return rings


def _route_points(route: dict[str, Any] | list[Any] | None) -> list[list[float]]:
    raw_points: Any
    if isinstance(route, dict):
        if route.get("type") != "LineString":
            raise GeometryError("route must be a GeoJSON LineString")
        raw_points = route.get("coordinates")
    else:
        raw_points = route
    if not isinstance(raw_points, list):
        raise GeometryError("route coordinates must be a list")
    return [_normalize_point(point) for point in raw_points]


def _normalize_point(raw_point: Any) -> list[float]:
    if not isinstance(raw_point, (list, tuple)) or len(raw_point) < 2:
        raise GeometryError("coordinate must contain [lon, lat]")
    lon = float(raw_point[0])
    lat = float(raw_point[1])
    normalize_bbox([lon - 0.0000001, lat - 0.0000001, lon + 0.0000001, lat + 0.0000001])
    return [lon, lat]


def _bounds_for_points(points: list[list[float]]) -> Bounds:
    if not points:
        raise GeometryError("geometry contains no points")
    return normalize_bbox(
        [
            min(point[0] for point in points),
            min(point[1] for point in points),
            max(point[0] for point in points),
            max(point[1] for point in points),
        ]
    )


def _bounds_for_route_points(points: list[list[float]]) -> Bounds:
    min_lon = min(point[0] for point in points)
    min_lat = min(point[1] for point in points)
    max_lon = max(point[0] for point in points)
    max_lat = max(point[1] for point in points)
    if min_lon == max_lon:
        min_lon -= 0.000001
        max_lon += 0.000001
    if min_lat == max_lat:
        min_lat -= 0.000001
        max_lat += 0.000001
    return normalize_bbox([min_lon, min_lat, max_lon, max_lat])


def _reject_self_intersection(ring: list[list[float]]) -> None:
    segments = list(zip(ring, ring[1:]))
    for i, segment_a in enumerate(segments):
        for j, segment_b in enumerate(segments):
            if abs(i - j) <= 1:
                continue
            if i == 0 and j == len(segments) - 1:
                continue
            if _segments_intersect(segment_a[0], segment_a[1], segment_b[0], segment_b[1]):
                raise GeometryError("polygon outer ring self-intersects")


def _segments_intersect(a: list[float], b: list[float], c: list[float], d: list[float]) -> bool:
    def orientation(p: list[float], q: list[float], r: list[float]) -> float:
        return (q[1] - p[1]) * (r[0] - q[0]) - (q[0] - p[0]) * (r[1] - q[1])

    o1 = orientation(a, b, c)
    o2 = orientation(a, b, d)
    o3 = orientation(c, d, a)
    o4 = orientation(c, d, b)
    return (o1 > 0) != (o2 > 0) and (o3 > 0) != (o4 > 0)
