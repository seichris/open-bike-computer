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
from .topography_grid import contour_grid, enclosing_bounds_e7, processing_region, region_resolution
from .topography_raster import audited_copernicus_pixels, sample_fixed_grid
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


def extract_contours(mosaic, grid, minor: int, index: int, cancel=lambda: None):
    """Shared global/regional extraction; no interpolation across masked voids."""
    import contourpy
    import numpy as np

    if mosaic.shape != (grid.height, grid.width) or mosaic.size > MAX_GRID_PIXELS:
        raise ValueError("invalid or oversized contour raster")
    if (minor, index) not in ((20, 100), (50, 250)):
        raise ValueError("unsupported contour display profile")
    valid = np.isfinite(mosaic)
    missing = int(mosaic.size - np.count_nonzero(valid))
    if not np.any(valid):
        raise ValueError("sample has no valid elevation pixels")
    minimum, maximum = float(mosaic[valid].min()), float(mosaic[valid].max())
    if minimum < -12000 or maximum > 10000:
        raise ValueError("sample elevation range exceeds Earth profile bounds")
    levels = range(math.ceil(minimum / minor) * minor, math.floor(maximum / minor) * minor + 1, minor)
    if len(levels) > 2000:
        raise ValueError("sample contour level count exceeds bound")
    generator = contourpy.contour_generator(
        x=grid.left + (np.arange(grid.width) + 0.5) * grid.resolution,
        y=grid.top - (np.arange(grid.height) + 0.5) * grid.resolution,
        z=np.ma.masked_invalid(mosaic), name="serial", line_type="Separate", corner_mask=False,
    )
    records, point_count = [], 0
    for elevation in levels:
        cancel()
        for line in generator.lines(elevation):
            cancel()
            point_count += len(line)
            if point_count > MAX_CONTOUR_POINTS or len(records) >= MAX_CONTOUR_RECORDS:
                raise ValueError("sample contour complexity exceeds bound")
            points = canonical_line(line)
            if points:
                records.append((elevation, elevation % index == 0, points))
    return sorted(set(records)), missing


def contour_sample(policy: TopographySourcePolicy, cache: ElevationCache,
                   bounds: list[float], *, maximum_tiles: int = 8) -> dict[str, Any]:
    # Import optional native libraries only for this explicit operator command.
    import contourpy
    import numpy as np
    import rasterio

    region = processing_region(bounds)
    indexes = {source.id: cache.index(source) for source in policy.sources}
    resolution = region_resolution(policy, indexes, region)
    grid = contour_grid(bounds, resolution, MAX_GRID_PIXELS)
    plan = plan_elevation(policy, indexes, list(grid.acquisition_bounds))
    if not plan["coverageComplete"]:
        raise ValueError("sample or halo has uncovered geocells; missing tiles are not zero elevation")
    if type(maximum_tiles) is not int or not 1 <= maximum_tiles <= 256 or len(plan["tiles"]) > maximum_tiles:
        raise ValueError("sample exceeds its tile acquisition limit")
    crs, left, top = grid.crs, grid.left, grid.top
    width, height = grid.width, grid.height
    sources = {source.id: source for source in policy.sources}
    receipts = [cache.stage(sources[tile["sourceId"]], tuple(tile["cell"])) for tile in plan["tiles"]]
    receipts.sort(key=lambda r: (-sources[r["sourceId"]].priority, r["sourceId"], r["cell"]))
    mosaic = np.full((height, width), np.nan, dtype="float32")
    source_pixels: dict[str, int] = {}
    raster_audits = []
    with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", GDAL_PAM_ENABLED=False,
                      GDAL_NUM_THREADS="1", GDAL_CACHEMAX=32 * 1024 * 1024,
                      PROJ_NETWORK="OFF"):
        for receipt in receipts:
            cache.cancel()
            path = cache.verify(receipt)
            with rasterio.open(path, driver="GTiff", sharing=False) as dataset:
                native, native_valid, audit = audited_copernicus_pixels(dataset, receipt["cell"])
                raster_audits.append({"sourceId": receipt["sourceId"], "cell": receipt["cell"],
                                      "sha256": receipt["sha256"], **audit})
                tile = sample_fixed_grid(native, native_valid, dataset.transform, grid, cache.cancel)
                valid = np.isnan(mosaic) & np.isfinite(tile)
                mosaic[valid] = tile[valid]
                source_pixels[receipt["sourceId"]] = source_pixels.get(receipt["sourceId"], 0) + int(np.count_nonzero(valid))
    minor, index = (50, 250) if resolution == 90 else (20, 100)
    records, missing = extract_contours(mosaic, grid, minor, index, cache.cancel)
    return {
        "schemaVersion": 1, "kind": "bicino-contour-evidence-v1", "access": "free",
        "productionEligible": False, "sourcePolicySha256": policy.sha256,
        "boundsE7": enclosing_bounds_e7(bounds), "workingCrs": crs,
        "verticalDatum": "EPSG:3855", "surfaceModel": "dsm",
        "qualityMode": "coarse-50m-v1" if resolution == 90 else "standard-20m-v1",
        "processingGrid": grid.evidence(), "nativeRasterAudits": raster_audits,
        "gridResolutionM": resolution, "gridSize": [width, height],
        "noDataMillionths": round(missing * 1_000_000 / mosaic.size),
        "minorIntervalM": minor, "indexIntervalM": index, "sourcePixels": dict(sorted(source_pixels.items())),
        "inputs": receipts, "algorithm": "masked-fixed-region-halo-serial-contours-mm-v2",
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
