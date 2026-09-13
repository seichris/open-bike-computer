"""Regional TIFF -> explicitly normalized EGM2008 contour evidence.

Development operator flow, not a provider approval or production job route.
Native rasters are read through bounded local windows, never GDAL HTTP/VRT.
"""
from __future__ import annotations

import math
import platform
from contextlib import ExitStack
from pathlib import Path

from .strict_json import loads_strict_json
from .topography_cache import ElevationCache
from .topography_grid import contour_grid
from .topography_pipeline import MAX_GRID_PIXELS, extract_contours
from .topography_discovery import REGIONAL_SOURCES, _allowed_url
from .topography_transform import _sha
from .topography_transform import load_transform_contract, open_regional_transform

MAX_NATIVE_WINDOW_PIXELS = 4_000_000
MAX_NATIVE_DIMENSION = 1_000_000


def _audit(dataset, native: dict) -> dict:
    transform = dataset.transform
    nodata = dataset.nodata
    nodata = "nan" if nodata is not None and math.isnan(nodata) else nodata
    if (dataset.count != 1 or dataset.crs is None or dataset.crs.to_epsg() != native["horizontalEpsg"]
            or dataset.dtypes != (native["dtype"],) or dataset.units != (native["bandUnits"],)
            or nodata != native["noData"] or dataset.scales != (1.0,) or dataset.offsets != (0.0,)
            or not 1 <= dataset.width <= MAX_NATIVE_DIMENSION or not 1 <= dataset.height <= MAX_NATIVE_DIMENSION
            or not all(math.isfinite(v) for v in transform) or transform.a <= 0 or transform.e >= 0
            or transform.b != 0 or transform.d != 0):
        raise ValueError("regional raster header differs from exact native contract")
    return {"dimensions": [dataset.width, dataset.height], "affine": list(transform)[:6],
            "dtype": dataset.dtypes[0], "horizontalEpsg": dataset.crs.to_epsg(),
            "declaredNoData": nodata, "bandUnits": dataset.units[0],
            "pixelRegistration": dataset.tags().get("AREA_OR_POINT", "unreported"),
            "maskFlags": sorted(flag.name for flag in dataset.mask_flag_enums[0]),
            "waterQualityMasks": "not-supplied"}


def regional_mosaic(dataset, transform, grid, cancel=lambda: None):
    import numpy as np
    from rasterio.warp import transform as project
    from rasterio.windows import Window

    result = np.full((grid.height, grid.width), np.nan, dtype="float32")
    flat = result.reshape(-1)
    affine = dataset.transform
    # Small target chunks prevent a high-resolution national DTM from being
    # materialized in RAM. Recursively split any native window exceeding budget.
    def sample(indices):
        cancel()
        x = grid.left + (indices % grid.width + 0.5) * grid.resolution
        y = grid.top - (indices // grid.width + 0.5) * grid.resolution
        lon, lat = project(grid.crs, "EPSG:4326", x, y)
        lon, lat = np.asarray(lon), np.asarray(lat)
        native_x, native_y = transform.native_xy(lon, lat)
        col = (np.asarray(native_x) - affine.c) / affine.a - 0.5
        row = (np.asarray(native_y) - affine.f) / affine.e - 0.5
        inside = ((col >= -0.5) & (row >= -0.5) & (col < dataset.width - 0.5)
                  & (row < dataset.height - 0.5))
        if not np.any(inside):
            return
        selected = indices[inside]
        col, row = np.clip(col[inside], 0, dataset.width - 1), np.clip(row[inside], 0, dataset.height - 1)
        c0, r0 = np.floor(col).astype("int64"), np.floor(row).astype("int64")
        c1, r1 = np.minimum(c0 + 1, dataset.width - 1), np.minimum(r0 + 1, dataset.height - 1)
        left, top, right, bottom = int(c0.min()), int(r0.min()), int(c1.max()) + 1, int(r1.max()) + 1
        if (right - left) * (bottom - top) > MAX_NATIVE_WINDOW_PIXELS:
            middle = len(indices) // 2
            if middle == 0:
                raise ValueError("native interpolation window exceeds budget")
            sample(indices[:middle])
            sample(indices[middle:])
            return
        window = Window(left, top, right - left, bottom - top)
        pixels = dataset.read(1, window=window, out_dtype="float64")
        valid = (dataset.read_masks(1, window=window) != 0) & np.isfinite(pixels)
        if np.any(valid & ((pixels < -12000) | (pixels > 10000))):
            raise ValueError("valid native regional heights exceed Earth bounds")
        dx, dy = col - c0, row - r0
        heights, supported = np.zeros(len(selected)), np.ones(len(selected), dtype=bool)
        for rr, cc, weight in ((r0, c0, (1-dx)*(1-dy)), (r0, c1, dx*(1-dy)),
                               (r1, c0, (1-dx)*dy), (r1, c1, dx*dy)):
            has_value = valid[rr - top, cc - left]
            contributes = weight > 0
            supported &= ~contributes | has_value
            heights += np.where(has_value & contributes, pixels[rr - top, cc - left], 0) * weight
        if np.any(supported):
            normalized = transform.egm2008(lon[inside][supported], lat[inside][supported], heights[supported])
            flat[selected[supported]] = normalized

    for start in range(0, result.size, 2048):
        sample(np.arange(start, min(start + 2048, result.size)))
    return result


def _read_receipt(receipt_path: Path) -> dict:
    if receipt_path.is_symlink() or not receipt_path.is_file() or receipt_path.stat().st_size > 16384:
        raise ValueError("invalid regional raster receipt")
    receipt = loads_strict_json(receipt_path.read_bytes(), description="regional raster receipt")
    fields = {"kind", "sourceId", "discoverySha256", "itemId", "assetKey", "url", "providerSha256", "bytes", "sha256"}
    if not isinstance(receipt, dict) or set(receipt) != fields or receipt["kind"] != "bicino-regional-elevation-receipt-v1":
        raise ValueError("unsupported regional raster receipt")
    if receipt["sourceId"] not in REGIONAL_SOURCES:
        raise ValueError("unsupported regional raster source")
    _sha(receipt["discoverySha256"])
    _allowed_url(receipt["url"], REGIONAL_SOURCES[receipt["sourceId"]].asset_prefixes)
    if receipt["providerSha256"] is not None and _sha(receipt["providerSha256"]) != receipt["sha256"]:
        raise ValueError("regional raster differs from published provider checksum")
    return receipt


def inspect_regional_asset(cache: ElevationCache, receipt_path: Path) -> dict:
    import rasterio

    receipt = _read_receipt(receipt_path)
    path = cache.verify(receipt)
    with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", GDAL_PAM_ENABLED=False, PROJ_NETWORK="OFF"):
        with rasterio.open(path, driver="GTiff", sharing=False) as dataset:
            nodata = dataset.nodata
            nodata = "nan" if nodata is not None and math.isnan(nodata) else nodata
            native = {"horizontalEpsg": dataset.crs.to_epsg() if dataset.crs else None,
                      "dtype": dataset.dtypes[0], "noData": nodata, "bandUnits": dataset.units[0]}
            return {"schemaVersion": 1, "kind": "bicino-regional-native-inspection-v1",
                    "productionEligible": False, "receipt": receipt,
                    "observed": {"dimensions": [dataset.width, dataset.height], "bands": dataset.count,
                                 "crsWkt": dataset.crs.to_wkt() if dataset.crs else None,
                                 "affine": list(dataset.transform)[:6], "bounds": list(dataset.bounds),
                                 "scales": list(dataset.scales), "offsets": list(dataset.offsets),
                                 "pixelRegistration": dataset.tags().get("AREA_OR_POINT", "unreported"),
                                 "maskFlags": [[flag.name for flag in flags] for flags in dataset.mask_flag_enums]},
                    "draftContract": {"schemaVersion": 1, "sourceId": receipt["sourceId"], "assetSha256": receipt["sha256"],
                                      "sourceReviewSha256": None, "sourceVerticalDatum": None,
                                      "targetVerticalDatum": "EPSG:3855", "native": native, "areaOfUse": None,
                                      "horizontalPipeline": {"proj": None, "sha256": None},
                                      "verticalPipeline": {"proj": None, "sha256": None}, "grids": [],
                                      "productionApproved": False},
                    "warning": "Draft cannot be used until reviewed datum, operations, grids and area of use are supplied."}


def regional_contour_sample(cache: ElevationCache, receipt_path: Path | list[Path], contract_path: Path | list[Path],
                            grid_directory: Path, bounds: list[float]) -> dict:
    import contourpy
    import numpy as np
    import pyproj
    import rasterio
    from .topography_regional_tiles import MAX_REGIONAL_TILES, RegionalRasterCollection, load_transform_set

    receipt_paths = receipt_path if isinstance(receipt_path, list) else [receipt_path]
    contract_paths = contract_path if isinstance(contract_path, list) else [contract_path]
    if not 1 <= len(receipt_paths) <= MAX_REGIONAL_TILES or len(receipt_paths) != len(contract_paths):
        raise ValueError("regional sampling requires 1 to 16 receipts and exactly one contract per asset")
    receipts = sorted((_read_receipt(path) for path in receipt_paths), key=lambda value: value["sha256"])
    multiple = len(receipts) > 1
    contract = load_transform_set(contract_paths) if multiple else load_transform_contract(contract_paths[0])
    contracts = contract["contracts"] if multiple else [contract]
    if (len({receipt["sha256"] for receipt in receipts}) != len(receipts)
            or any(receipt["sourceId"] != native["sourceId"] or receipt["sha256"] != native["assetSha256"]
                   for receipt, native in zip(receipts, contracts))):
        raise ValueError("regional raster does not belong to its transformation contract")
    paths = [cache.verify(receipt) for receipt in receipts]
    common = contracts[0]
    grid = contour_grid(bounds, 30, MAX_GRID_PIXELS)
    audits, collection_evidence = [], {}
    with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", GDAL_PAM_ENABLED=False,
                      GDAL_NUM_THREADS="1", GDAL_CACHEMAX=32 * 1024 * 1024, PROJ_NETWORK="OFF"):
        with ExitStack() as stack:
            datasets = []
            for path, receipt, native in zip(paths, receipts, contracts):
                cache.cancel()
                dataset = stack.enter_context(rasterio.open(path, driver="GTiff", sharing=False))
                datasets.append(dataset)
                audits.append({**_audit(dataset, native["native"]), "sourceId": receipt["sourceId"], "sha256": receipt["sha256"]})
            source = RegionalRasterCollection(datasets, cache.cancel) if multiple else datasets[0]
            if multiple:
                collection_evidence = {"nativeTileCollection": source.evidence()}
            operation = stack.enter_context(open_regional_transform(common, grid_directory, cache.cancel))
            mosaic = regional_mosaic(source, operation, grid, cache.cancel)
    records, missing = extract_contours(mosaic, grid, 20, 100, cache.cancel)
    return {"schemaVersion": 1, "kind": "bicino-contour-evidence-v1", "access": "free",
            "productionEligible": False, "sourcePolicySha256": contract["contractSha256"],
            "sourceContractKind": "regional-transform-set-v1" if multiple else "regional-transform-v1", "sourceContract": contract,
            "boundsE7": [round(value * 10_000_000) for value in bounds], "workingCrs": grid.crs,
            "verticalDatum": "EPSG:3855", "surfaceModel": "dtm", "qualityMode": "regional-dtm-20m-v1",
            "processingGrid": grid.evidence(), "gridResolutionM": 30, "gridSize": [grid.width, grid.height],
            "noDataMillionths": round(missing * 1_000_000 / mosaic.size),
            "minorIntervalM": 20, "indexIntervalM": 100,
            "nativeRasterAudits": audits, **collection_evidence,
            "sourcePixels": {common["sourceId"]: int(mosaic.size - missing)}, "inputs": receipts,
            "algorithm": ("pinned-regional-native-tile-mosaic-v1" if multiple
                          else "pinned-regional-windowed-bilinear-height-normalization-v1"),
            "sources": [{"sourceId": common["sourceId"], "sourceReviewSha256": common["sourceReviewSha256"]}],
            "runtime": {"rasterio": rasterio.__version__, "gdal": rasterio.__gdal_version__,
                        "rasterioProj": rasterio.__proj_version__, "pyproj": pyproj.__version__,
                        "transformProj": pyproj.proj_version_str, "numpy": np.__version__, "contourpy": contourpy.__version__,
                        "machine": platform.machine(), "system": platform.system(), "python": platform.python_version()},
            "contours": [{"elevationM": elevation, "index": is_index, "pointsMm": points}
                         for elevation, is_index, points in records]}
