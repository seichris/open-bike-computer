from __future__ import annotations

import io
import math
from typing import Any

from PIL import Image, ImageDraw

from .models import Bounds

DEFAULT_PREVIEW_WIDTH = 160
DEFAULT_PREVIEW_HEIGHT = 96
DEFAULT_PREVIEW_PATH = "preview.png"
DEFAULT_PREVIEW_TYPE = "boundary-png"

_SUPERSAMPLE_SCALE = 4
_FILL_COLOR = (76, 139, 168, 210)
_STROKE_COLOR = (40, 96, 124, 255)
_TRANSPARENT = (0, 0, 0, 0)

Point = tuple[float, float]
Ring = list[Point]
Polygon = list[Ring]


def render_boundary_preview(
    geometry: dict[str, Any] | None,
    bounds: Bounds,
    *,
    width: int = DEFAULT_PREVIEW_WIDTH,
    height: int = DEFAULT_PREVIEW_HEIGHT,
    padding: int = 8,
) -> bytes:
    """Render a small transparent PNG from Polygon/MultiPolygon geometry.

    Invalid, unsupported, or antimeridian-spanning geometry falls back to the
    requested bounds so preview generation cannot make an otherwise valid map
    pack unusable.
    """

    if width <= 0 or height <= 0:
        raise ValueError("preview dimensions must be positive")
    if padding < 0 or padding * 2 >= min(width, height):
        raise ValueError("preview padding leaves no drawable area")

    polygons = _polygons_from_geometry(geometry)
    if not polygons or _crosses_antimeridian(polygons):
        polygons = [_bounds_polygon(bounds)]

    projected = _project_polygons(polygons)
    if projected is None:
        projected = _project_polygons([_bounds_polygon(bounds)])
    if projected is None:
        raise ValueError("preview geometry has no drawable area")

    projected_polygons, min_x, min_y, max_x, max_y = projected
    canvas_width = width * _SUPERSAMPLE_SCALE
    canvas_height = height * _SUPERSAMPLE_SCALE
    canvas_padding = padding * _SUPERSAMPLE_SCALE
    available_width = canvas_width - canvas_padding * 2
    available_height = canvas_height - canvas_padding * 2
    shape_width = max_x - min_x
    shape_height = max_y - min_y
    scale = min(available_width / shape_width, available_height / shape_height)
    rendered_width = shape_width * scale
    rendered_height = shape_height * scale
    offset_x = (canvas_width - rendered_width) / 2.0
    offset_y = (canvas_height - rendered_height) / 2.0

    def pixel(point: Point) -> Point:
        return (
            offset_x + (point[0] - min_x) * scale,
            offset_y + (point[1] - min_y) * scale,
        )

    image = Image.new("RGBA", (canvas_width, canvas_height), _TRANSPARENT)
    draw = ImageDraw.Draw(image)
    stroke_width = max(1, _SUPERSAMPLE_SCALE * 2)
    for polygon in projected_polygons:
        outer = [pixel(point) for point in polygon[0]]
        draw.polygon(outer, fill=_FILL_COLOR, outline=_STROKE_COLOR, width=stroke_width)
        for hole in polygon[1:]:
            hole_pixels = [pixel(point) for point in hole]
            draw.polygon(
                hole_pixels,
                fill=_TRANSPARENT,
                outline=_STROKE_COLOR,
                width=stroke_width,
            )

    resampling = getattr(Image, "Resampling", Image)
    image = image.resize((width, height), resample=resampling.LANCZOS)
    output = io.BytesIO()
    image.save(output, format="PNG", optimize=True)
    return output.getvalue()


def _polygons_from_geometry(geometry: dict[str, Any] | None) -> list[Polygon]:
    if not isinstance(geometry, dict):
        return []
    geometry_type = geometry.get("type")
    coordinates = geometry.get("coordinates")
    if geometry_type == "Polygon":
        polygon = _parse_polygon(coordinates)
        return [polygon] if polygon else []
    if geometry_type == "MultiPolygon" and isinstance(coordinates, list):
        return [polygon for value in coordinates if (polygon := _parse_polygon(value))]
    return []


def _parse_polygon(value: Any) -> Polygon | None:
    if not isinstance(value, list) or not value:
        return None
    outer = _parse_ring(value[0])
    if outer is None:
        return None
    holes = [ring for candidate in value[1:] if (ring := _parse_ring(candidate))]
    return [outer, *holes]


def _parse_ring(value: Any) -> Ring | None:
    if not isinstance(value, list):
        return None
    ring: Ring = []
    for position in value:
        if not isinstance(position, (list, tuple)) or len(position) < 2:
            return None
        longitude, latitude = position[0], position[1]
        if (
            isinstance(longitude, bool)
            or isinstance(latitude, bool)
            or not isinstance(longitude, (int, float))
            or not isinstance(latitude, (int, float))
        ):
            return None
        point = (float(longitude), float(latitude))
        if (
            not math.isfinite(point[0])
            or not math.isfinite(point[1])
            or not -180.0 <= point[0] <= 180.0
            or not -90.0 <= point[1] <= 90.0
        ):
            return None
        ring.append(point)
    if len(ring) < 3:
        return None
    if ring[0] != ring[-1]:
        ring.append(ring[0])
    return ring


def _bounds_polygon(bounds: Bounds) -> Polygon:
    return [[
        (bounds.min_lon, bounds.min_lat),
        (bounds.max_lon, bounds.min_lat),
        (bounds.max_lon, bounds.max_lat),
        (bounds.min_lon, bounds.max_lat),
        (bounds.min_lon, bounds.min_lat),
    ]]


def _crosses_antimeridian(polygons: list[Polygon]) -> bool:
    longitudes = [point[0] for polygon in polygons for ring in polygon for point in ring]
    return bool(longitudes) and max(longitudes) - min(longitudes) > 180.0


def _project_polygons(
    polygons: list[Polygon],
) -> tuple[list[Polygon], float, float, float, float] | None:
    points = [point for polygon in polygons for ring in polygon for point in ring]
    if not points:
        return None
    center_latitude = (min(point[1] for point in points) + max(point[1] for point in points)) / 2.0
    longitude_scale = max(0.1, math.cos(math.radians(center_latitude)))

    projected: list[Polygon] = []
    for polygon in polygons:
        projected.append([
            [(longitude * longitude_scale, -latitude) for longitude, latitude in ring]
            for ring in polygon
        ])
    projected_points = [
        point for polygon in projected for ring in polygon for point in ring
    ]
    min_x = min(point[0] for point in projected_points)
    min_y = min(point[1] for point in projected_points)
    max_x = max(point[0] for point in projected_points)
    max_y = max(point[1] for point in projected_points)
    if max_x <= min_x or max_y <= min_y:
        return None
    return projected, min_x, min_y, max_x, max_y
