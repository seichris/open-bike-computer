"""Compile one map-wide contour mosaic into seam-safe device block records.

This stage never regenerates contours per block. It clips in the mosaic's
metric CRS, projects to the renderer's Web Mercator grid, then quantizes once.
The companion consumes these same quantized lines, not another DEM rendering.
"""
from __future__ import annotations

import hashlib
import math
from dataclasses import dataclass
from typing import Callable

from shapely.geometry import LineString, box, shape
from shapely.ops import transform

from .topography_artifacts import Contour, ContourSection, encode_contour_section
from .topography_pipeline import canonical_bytes, canonical_line

BLOCK_METRES = 4096
MAX_BLOCKS = 256
MAX_COMPILED_POINTS = 400_000
MAX_WORLD_METRES = math.pi * 6378137


@dataclass(frozen=True)
class CompiledTopography:
    sections: dict[tuple[int, int], ContourSection]
    intermediate_sha256: str
    sample_sha256: str
    selection_sha256: str

    @property
    def record_count(self) -> int:
        return sum(len(section.contours) for section in self.sections.values())

    @property
    def point_count(self) -> int:
        return sum(section.point_count for section in self.sections.values())


def _lines(geometry):
    if geometry.is_empty:
        return
    if geometry.geom_type == "LineString":
        yield geometry
    elif geometry.geom_type in {"MultiLineString", "GeometryCollection"}:
        for part in geometry.geoms:
            yield from _lines(part)


def compile_contours(sample: dict, selection: dict, *, corridor_width_m: int = 0,
                     cancel: Callable[[], None] = lambda: None) -> CompiledTopography:
    from rasterio.warp import transform as warp

    if (sample.get("kind") != "bicino-contour-evidence-v1"
            or sample.get("verticalDatum") != "EPSG:3855"
            or len(sample.get("contours", [])) > 10_000):
        raise ValueError("unsupported or oversized contour intermediate")
    minor, index = sample["minorIntervalM"], sample["indexIntervalM"]
    encode_contour_section(ContourSection(minor, index, ()))
    working_crs = sample["workingCrs"]
    allowed_crs = {"EPSG:3413", "EPSG:3031", "EPSG:3857"} | {
        f"EPSG:{hemisphere + zone}" for hemisphere in (32600, 32700) for zone in range(1, 61)
    }
    if working_crs not in allowed_crs:
        raise ValueError("intermediate has no declared working CRS")
    if type(sample.get("noDataMillionths")) is not int or not 0 <= sample["noDataMillionths"] <= 1_000_000:
        raise ValueError("invalid intermediate no-data fraction")
    region = shape(selection)
    if region.is_empty or not region.is_valid or region.geom_type not in {"Polygon", "MultiPolygon", "LineString"}:
        raise ValueError("topography selection must be a valid polygon or route")
    west, south, east, north = region.bounds
    if not (-180 <= west <= east <= 180 and -85.05112878 <= south <= north <= 85.05112878):
        raise ValueError("selection is outside the device Web Mercator domain")
    bounds = [value / 10_000_000 for value in sample["boundsE7"]]
    if not box(*bounds).covers(region):
        raise ValueError("contour mosaic does not cover the requested selection")

    def project(source, target):
        return lambda x, y, z=None: warp(source, target, x, y)

    selected = transform(project("EPSG:4326", working_crs), region)
    if region.geom_type == "LineString":
        if type(corridor_width_m) is not int or not 1 <= corridor_width_m <= 50_000:
            raise ValueError("route requires a bounded full corridor width in metres")
        selected = selected.buffer(corridor_width_m / 2, resolution=8)
        if not transform(project("EPSG:4326", working_crs), box(*bounds)).covers(selected):
            raise ValueError("contour mosaic does not cover the buffered route")
    elif corridor_width_m:
        raise ValueError("polygon must not have a corridor width")
    records: dict[tuple[int, int], set[Contour]] = {}
    total_points = 0
    input_points = 0
    for record in sample["contours"]:
        cancel()
        points = record["pointsMm"]
        input_points += len(points)
        if not 2 <= len(points) or input_points > 200_000:
            raise ValueError("contour intermediate exceeds input point bounds")
        if any(len(point) != 2 or any(type(value) is not int or abs(value) > 100_000_000_000 for value in point) for point in points):
            raise ValueError("invalid millimetre contour coordinates")
        elevation = record["elevationM"]
        if (type(elevation) is not int or not -12000 <= elevation <= 10000
                or elevation % minor or type(record["index"]) is not bool
                or record["index"] != (elevation % index == 0)):
            raise ValueError("intermediate contour classification differs from interval policy")
        source = LineString([(x / 1000, y / 1000) for x, y in points])
        clipped = source.intersection(selected)
        for part in _lines(clipped):
            cancel()
            world = transform(project(working_crs, "EPSG:3857"), part)
            coordinates = []
            for x, y in world.coords:
                if not all(math.isfinite(v) and abs(v) <= MAX_WORLD_METRES + 1 for v in (x, y)):
                    raise ValueError("contour cannot be represented by the device grid")
                point = (round(x), round(y))
                if not coordinates or coordinates[-1] != point:
                    coordinates.append(point)
            if len(coordinates) < 2:
                continue
            world = LineString(coordinates)
            min_x, min_y, max_x, max_y = world.bounds
            first_x, first_y = math.floor(min_x / BLOCK_METRES), math.floor(min_y / BLOCK_METRES)
            last_x, last_y = math.floor(max_x / BLOCK_METRES), math.floor(max_y / BLOCK_METRES)
            if (last_x - first_x + 1) * (last_y - first_y + 1) > MAX_BLOCKS:
                raise ValueError("contour exceeds block traversal budget")
            for by in range(first_y, last_y + 1):
                for bx in range(first_x, last_x + 1):
                    cancel()
                    left, bottom = bx * BLOCK_METRES, by * BLOCK_METRES
                    for segment in _lines(world.intersection(box(left, bottom, left + BLOCK_METRES, bottom + BLOCK_METRES))):
                        local = [(round(x - left), round(y - bottom)) for x, y in segment.coords]
                        # A line coincident with a north/east edge belongs to
                        # its neighbouring block, never to both blocks.
                        if all(x == BLOCK_METRES for x, _ in local) or all(y == BLOCK_METRES for _, y in local):
                            continue
                        dense = [local[0]]
                        for endpoint in local[1:]:
                            start = dense[-1]
                            count = max(1, math.ceil(math.dist(start, endpoint) / 500))
                            for step in range(1, count + 1):
                                point = tuple(round(a + (b - a) * step / count) for a, b in zip(start, endpoint))
                                if point != dense[-1]:
                                    dense.append(point)
                        if len(dense) < 2:
                            continue
                        # Canonicalize BEFORE splitting so reversal/ring start
                        # cannot change the record partition or duplicate set.
                        canonical = tuple((x // 1000, y // 1000) for x, y in canonical_line(dense))
                        flags = int(record["index"])
                        if not selected.covers(source) or any(x in (0, BLOCK_METRES) or y in (0, BLOCK_METRES) for x, y in canonical):
                            flags |= 2
                        if sample["noDataMillionths"]:
                            flags |= 4
                        for start in range(0, len(canonical) - 1, 255):
                            contour = Contour(elevation, flags, canonical[start:start + 256])
                            bucket = records.setdefault((bx, by), set())
                            if contour not in bucket:
                                total_points += len(contour.points)
                                bucket.add(contour)
                            if len(records) > MAX_BLOCKS or total_points > MAX_COMPILED_POINTS:
                                raise ValueError("compiled contours exceed job geometry budget")
    sections = {key: ContourSection(minor, index, tuple(sorted(value, key=lambda r: (r.elevation_m, r.flags, r.points))))
                for key, value in sorted(records.items())}
    sample_sha = hashlib.sha256(canonical_bytes(sample)).hexdigest()
    selection_sha = hashlib.sha256(canonical_bytes({"geometry": selection, "corridorWidthM": corridor_width_m})).hexdigest()
    identity = {"algorithm": "metric-clip-webmercator-half-open-v1", "sampleSha256": sample_sha,
                "selectionSha256": selection_sha,
                "sections": [[*key, hashlib.sha256(encode_contour_section(section)).hexdigest()]
                             for key, section in sections.items()]}
    return CompiledTopography(sections, hashlib.sha256(canonical_bytes(identity)).hexdigest(), sample_sha, selection_sha)
