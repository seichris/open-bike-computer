"""Deterministic, bounded contour evidence from staged global DEMs.

This produces an inspection intermediate, not an FMB or app-download artifact.
Production eligibility requires the remaining byte/reader/quality gates.
"""
from __future__ import annotations

import json
import math
import platform
from typing import Any

from .topography_cache import ElevationCache
from .topography_sources import TopographySourcePolicy, plan_elevation

MAX_GRID_PIXELS = 4_000_000
MAX_CONTOUR_POINTS = 200_000
MAX_CONTOUR_RECORDS = 10_000


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()


def _minimum_rotation(points: tuple) -> tuple:
    # Booth's algorithm: linear even for repeated vertices on a closed line.
    doubled = points + points
    size, first, second, offset = len(points), 0, 1, 0
    while first < size and second < size and offset < size:
        left, right = doubled[first + offset], doubled[second + offset]
        if left == right:
            offset += 1
            continue
        if left > right:
            first += offset + 1
            if first == second:
                first += 1
        else:
            second += offset + 1
            if first == second:
                second += 1
        offset = 0
    start = min(first, second)
    return doubled[start:start + size]


def canonical_line(points) -> tuple[tuple[int, int], ...]:
    unique = []
    for x, y in points:
        point = (round(float(x) * 1000), round(float(y) * 1000))
        if not unique or unique[-1] != point:
            unique.append(point)
    if len(unique) < 2:
        return ()
    if unique[0] == unique[-1]:
        ring = tuple(unique[:-1])
        if len(ring) < 3:
            return ()
        canonical = min(_minimum_rotation(ring), _minimum_rotation(tuple(reversed(ring))))
        return canonical + (canonical[0],)
    line = tuple(unique)
    return min(line, tuple(reversed(line)))


def contour_sample(policy: TopographySourcePolicy, cache: ElevationCache,
                   bounds: list[float], *, maximum_tiles: int = 8) -> dict[str, Any]:
    # Import optional native libraries only for this explicit operator command.
    import contourpy
    import numpy as np
    import rasterio
    from rasterio.transform import from_origin
    from rasterio.warp import Resampling, reproject, transform_bounds

    indexes = {source.id: cache.index(source) for source in policy.sources}
    plan = plan_elevation(policy, indexes, bounds)
    if not plan["coverageComplete"]:
        raise ValueError("sample has uncovered geocells; missing tiles are not zero elevation")
    if type(maximum_tiles) is not int or not 1 <= maximum_tiles <= 256 or len(plan["tiles"]) > maximum_tiles:
        raise ValueError("sample exceeds its tile acquisition limit")
    west, south, east, north = bounds
    if east <= west:
        raise ValueError("split antimeridian sample into two jobs; coverage planning supports wrapped bounds")
    if east - west > 6 or north - south > 6:
        raise ValueError("sample exceeds local projection extent")
    center_lon, center_lat = (west + east) / 2, (south + north) / 2
    if center_lat >= 84:
        epsg = 3413
    elif center_lat <= -80:
        epsg = 3031
    else:
        epsg = (32600 if center_lat >= 0 else 32700) + min(60, math.floor((center_lon + 180) / 6) + 1)
    crs = f"EPSG:{epsg}"
    left, bottom, right, top = transform_bounds("EPSG:4326", crs, west, south, east, north, densify_pts=21)
    if not all(math.isfinite(value) for value in (left, bottom, right, top)):
        raise ValueError("sample bounds cannot be represented by its local projection")
    resolution = plan["nominalResolutionM"]
    left, bottom = math.floor(left / resolution) * resolution, math.floor(bottom / resolution) * resolution
    right, top = math.ceil(right / resolution) * resolution, math.ceil(top / resolution) * resolution
    width, height = round((right - left) / resolution), round((top - bottom) / resolution)
    if min(width, height) < 2 or width * height > MAX_GRID_PIXELS:
        raise ValueError("sample exceeds raster pixel bounds or is too small")
    grid_transform = from_origin(left, top, resolution, resolution)
    sources = {source.id: source for source in policy.sources}
    receipts = [cache.stage(sources[tile["sourceId"]], tuple(tile["cell"])) for tile in plan["tiles"]]
    receipts.sort(key=lambda r: (-sources[r["sourceId"]].priority, r["sourceId"], r["cell"]))
    mosaic = np.full((height, width), np.nan, dtype="float32")
    source_pixels: dict[str, int] = {}
    with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", GDAL_PAM_ENABLED=False,
                      GDAL_NUM_THREADS="1", GDAL_CACHEMAX=32 * 1024 * 1024,
                      PROJ_NETWORK="OFF"):
        for receipt in receipts:
            cache.cancel()
            path = cache.verify(receipt)
            with rasterio.open(path, driver="GTiff", sharing=False) as dataset:
                if (dataset.count != 1 or dataset.crs is None or dataset.crs.to_epsg() != 4326
                        or not 1 <= dataset.width <= 3601 or not 1 <= dataset.height <= 3601
                        or dataset.dtypes != ("float32",)):
                    raise ValueError("DEM dimensions, band type, or CRS differ from source contract")
                longitude, latitude = receipt["cell"]
                expected = (longitude, latitude, longitude + 1, latitude + 1)
                if any(abs(a - b) > 0.01 for a, b in zip(dataset.bounds, expected)):
                    raise ValueError("DEM bounds differ from source geocell")
                tile = np.full_like(mosaic, np.nan)
                reproject(source=rasterio.band(dataset, 1), destination=tile,
                          src_transform=dataset.transform, src_crs=dataset.crs,
                          src_nodata=dataset.nodata, dst_transform=grid_transform,
                          dst_crs=crs, dst_nodata=float("nan"), resampling=Resampling.bilinear,
                          num_threads=1, warp_mem_limit=32)
                valid = np.isnan(mosaic) & np.isfinite(tile)
                mosaic[valid] = tile[valid]
                source_pixels[receipt["sourceId"]] = source_pixels.get(receipt["sourceId"], 0) + int(np.count_nonzero(valid))
    valid = np.isfinite(mosaic)
    missing = int(mosaic.size - np.count_nonzero(valid))
    if not np.any(valid):
        raise ValueError("sample has no valid elevation pixels")
    # Missing pixels are masked, never filled with zero or interpolated across.
    minimum, maximum = float(mosaic[valid].min()), float(mosaic[valid].max())
    if minimum < -12000 or maximum > 10000:
        raise ValueError("sample elevation range exceeds Earth profile bounds")
    minor, index = plan["minorIntervalM"], plan["indexIntervalM"]
    levels = range(math.ceil(minimum / minor) * minor, math.floor(maximum / minor) * minor + 1, minor)
    if len(levels) > 2000:
        raise ValueError("sample contour level count exceeds bound")
    generator = contourpy.contour_generator(
        x=left + (np.arange(width) + 0.5) * resolution,
        y=top - (np.arange(height) + 0.5) * resolution,
        z=np.ma.masked_invalid(mosaic), name="serial", line_type="Separate", corner_mask=False,
    )
    records, point_count = [], 0
    for elevation in levels:
        cache.cancel()
        for line in generator.lines(elevation):
            cache.cancel()
            point_count += len(line)
            if point_count > MAX_CONTOUR_POINTS or len(records) >= MAX_CONTOUR_RECORDS:
                raise ValueError("sample contour complexity exceeds bound")
            points = canonical_line(line)
            if points:
                records.append((elevation, elevation % index == 0, points))
    records = sorted(set(records))
    return {
        "schemaVersion": 1, "kind": "bicino-contour-evidence-v1", "access": "free",
        "productionEligible": False, "sourcePolicySha256": policy.sha256,
        "boundsE7": [round(value * 10_000_000) for value in bounds], "workingCrs": crs,
        "verticalDatum": "EPSG:3855", "surfaceModel": "dsm", "qualityMode": plan["qualityMode"],
        "gridResolutionM": resolution, "gridSize": [width, height],
        "noDataMillionths": round(missing * 1_000_000 / mosaic.size),
        "minorIntervalM": minor, "indexIntervalM": index, "sourcePixels": dict(sorted(source_pixels.items())),
        "inputs": receipts, "algorithm": "bilinear-mosaic-serial-contours-mm-v1",
        "sources": [{"sourceId": source.id, "datasetRelease": source.dataset_release,
                     "termsUrl": source.terms_url, "attributionUrl": source.attribution_url,
                     "accessReviewedAt": source.access_reviewed_at}
                    for source in policy.sources if source.id in source_pixels],
        "runtime": {"rasterio": rasterio.__version__, "gdal": rasterio.__gdal_version__,
                    "proj": rasterio.__proj_version__, "contourpy": contourpy.__version__, "numpy": np.__version__,
                    "machine": platform.machine(), "system": platform.system(), "python": platform.python_version()},
        "contours": [{"elevationM": elevation, "index": is_index, "pointsMm": points}
                     for elevation, is_index, points in records],
    }
