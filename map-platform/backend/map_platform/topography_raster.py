"""Audit public height COGs and materialize validity before interpolation.

The public COG mirror is not the full DGED package. Do not infer water, edit,
fill or quality masks, a universal no-data sentinel, or pixel registration.
"""
from __future__ import annotations

import math


def sample_fixed_grid(native, native_valid, native_transform, grid, cancel):
    """Exact inverse projection and bounded bilinear height sampling.

    GDAL's approximate warp depends on the output envelope; rasterio 1.4.4's
    zero-tolerance WarpedVRT path fails with the pinned GDAL runtime. Project
    fixed pixel centres directly instead. Chunks bound memory/cancellation
    latency, and never influence interpolation weights or grid coordinates.
    """
    import numpy as np
    from rasterio.warp import transform

    result = np.full((grid.height, grid.width), np.nan, dtype="float32")
    flattened = result.reshape(-1)
    for start in range(0, result.size, 32768):
        cancel()
        indices = np.arange(start, min(result.size, start + 32768))
        x = grid.left + (indices % grid.width + 0.5) * grid.resolution
        y = grid.top - (indices // grid.width + 0.5) * grid.resolution
        longitude, latitude = transform(grid.crs, "EPSG:4326", x, y)
        columns = (np.asarray(longitude) - native_transform.c) / native_transform.a - 0.5
        rows = (np.asarray(latitude) - native_transform.f) / native_transform.e - 0.5
        height, width = native.shape
        inside = (np.isfinite(columns) & np.isfinite(rows) & (columns >= -0.5)
                  & (columns < width - 0.5) & (rows >= -0.5) & (rows < height - 0.5))
        positions = np.flatnonzero(inside)
        if not len(positions):
            continue
        # Edge centres extend at most half a source pixel, never beyond the
        # declared raster footprint. Source-boundary QA is still a release gate.
        columns, rows = np.clip(columns[inside], 0, width - 1), np.clip(rows[inside], 0, height - 1)
        c0, r0 = np.floor(columns).astype("int64"), np.floor(rows).astype("int64")
        c1, r1 = np.minimum(c0 + 1, width - 1), np.minimum(r0 + 1, height - 1)
        dx, dy = columns - c0, rows - r0
        values, valid = np.zeros(len(positions), dtype="float64"), np.ones(len(positions), dtype=bool)
        for rr, cc, weight in ((r0, c0, (1 - dx) * (1 - dy)), (r0, c1, dx * (1 - dy)),
                               (r1, c0, (1 - dx) * dy), (r1, c1, dx * dy)):
            contributes = weight > 0
            valid &= ~contributes | native_valid[rr, cc]
            values += np.where(contributes & native_valid[rr, cc], native[rr, cc], 0) * weight
        flattened[start + positions[valid]] = values[valid]
    return result


def audited_copernicus_pixels(dataset, cell: list[int]):
    import numpy as np

    if (dataset.count != 1 or dataset.crs is None or dataset.crs.to_epsg() != 4326
            or not 1 <= dataset.width <= 3601 or not 1 <= dataset.height <= 3601
            or dataset.dtypes != ("float32",)):
        raise ValueError("DEM dimensions, band type, or CRS differ from source contract")
    transform = dataset.transform
    if (not all(math.isfinite(v) for v in transform) or transform.a <= 0 or transform.e >= 0
            or transform.b != 0 or transform.d != 0):
        raise ValueError("DEM must have a finite north-up unrotated pixel grid")
    longitude, latitude = cell
    expected = (longitude, latitude, longitude + 1, latitude + 1)
    if any(abs(a - b) > 0.01 for a, b in zip(dataset.bounds, expected)):
        raise ValueError("DEM bounds differ from source geocell")
    if dataset.scales != (1.0,) or dataset.offsets != (0.0,):
        raise ValueError("DEM scale or offset differs from metre-valued height contract")
    if dataset.units[0] not in (None, "m", "metre", "meter"):
        raise ValueError("DEM band units differ from metre-valued height contract")
    registration = dataset.tags().get("AREA_OR_POINT", "unreported")
    if registration not in ("Area", "Point", "unreported"):
        raise ValueError("unsupported DEM pixel registration metadata")
    nodata = dataset.nodata
    if nodata is not None and math.isinf(nodata):
        raise ValueError("infinite DEM no-data metadata")
    native = dataset.read(1)
    valid = (dataset.read_masks(1) != 0) & np.isfinite(native)
    invalid_count = int(native.size - np.count_nonzero(valid))
    # Reject undeclared sentinel/invalid heights BEFORE a warp can smooth them
    # into plausible elevations. Valid negative terrain remains untouched.
    if np.any(valid & ((native < -12000) | (native > 10000))):
        raise ValueError("valid native DEM elevations exceed Earth profile bounds")
    native[~valid] = np.nan
    audit = {"dimensions": [dataset.width, dataset.height], "dtype": dataset.dtypes[0],
             "horizontalCrs": "EPSG:4326", "affine": list(transform)[:6],
             "pixelRegistration": registration, "bandUnits": dataset.units[0],
             "scale": dataset.scales[0], "offset": dataset.offsets[0],
             "declaredNoData": "nan" if nodata is not None and math.isnan(nodata) else nodata,
             "maskFlags": sorted(flag.name for flag in dataset.mask_flag_enums[0]),
             "invalidPixels": invalid_count,
             "waterMask": "unavailable-in-height-only-input",
             "qualityMasks": "unavailable-in-height-only-input",
             "verticalDatumEvidence": "source-policy-not-raster-header"}
    return native, valid, audit
