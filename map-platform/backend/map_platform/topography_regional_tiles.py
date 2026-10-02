"""Bounded, non-overlapping tiles on one reviewed native elevation lattice.

This is not a cross-provider mosaic or survey-edition selector. Joining native
pixels before bilinear interpolation lets the sampler use the actual neighbor
across a tile boundary. Unstaged tiles remain masked; no edge feathering occurs.
"""
from __future__ import annotations

import hashlib
import math
from pathlib import Path

from .topography_pipeline import canonical_bytes
from .topography_transform import load_transform_contract

MAX_REGIONAL_TILES = 16
MAX_COLLECTION_DIMENSION = 1_000_000
MAX_COLLECTION_WINDOW_PIXELS = 4_000_000


def load_transform_set(paths: list[Path]) -> dict:
    if not 2 <= len(paths) <= MAX_REGIONAL_TILES:
        raise ValueError("regional transform set requires 2 to 16 contracts")
    contracts = sorted((load_transform_contract(path) for path in paths), key=lambda value: value["assetSha256"])
    if len({value["assetSha256"] for value in contracts}) != len(contracts):
        raise ValueError("duplicate native asset in regional transform set")
    def common(value):
        return {key: field for key, field in value.items() if key not in {"assetSha256", "contractSha256"}}

    if any(common(value) != common(contracts[0]) for value in contracts[1:]):
        raise ValueError("regional tiles require identical source review, native header and transformation contracts")
    value = {"schemaVersion": 1, "kind": "bicino-regional-transform-set-v1",
             "contracts": contracts, "productionApproved": False}
    return {**value, "contractSha256": hashlib.sha256(canonical_bytes(value)).hexdigest()}


class RegionalRasterCollection:
    """Dataset-like local window reader; callers own the open TIFF lifetimes.

    All headers must have passed the regional native contract audit first.
    Geometry checks are repeated here so overlaps cannot depend on input order.
    No allocation is proportional to the collection's full bounding rectangle.
    """

    def __init__(self, datasets, cancel=lambda: None):
        from affine import Affine

        if not 2 <= len(datasets) <= MAX_REGIONAL_TILES:
            raise ValueError("regional raster collection requires 2 to 16 tiles")
        self.cancel = cancel
        self.tiles = []
        reference = datasets[0]
        a, e = reference.transform.a, reference.transform.e
        left = min(dataset.transform.c for dataset in datasets)
        top = max(dataset.transform.f for dataset in datasets)
        self.transform = Affine(a, 0, left, 0, e, top)
        self.width = self.height = 0
        for dataset in datasets:
            cancel()
            affine = dataset.transform
            if (not all(math.isfinite(v) for v in affine) or a <= 0 or e >= 0
                    or affine.b != 0 or affine.d != 0
                    or not math.isclose(affine.a, a, rel_tol=1e-12, abs_tol=0)
                    or not math.isclose(affine.e, e, rel_tol=1e-12, abs_tol=0)
                    or dataset.crs != reference.crs
                    or dataset.tags().get("AREA_OR_POINT") != reference.tags().get("AREA_OR_POINT")):
                raise ValueError("regional tiles do not share one native pixel lattice")
            col, row = (affine.c - left) / a, (affine.f - top) / e
            c0, r0 = round(col), round(row)
            # Permit only sub-micropixel floating representation noise, not a
            # resampling/alignment policy. Record the canonical affine below.
            if abs(col - c0) > 1e-7 or abs(row - r0) > 1e-7:
                raise ValueError("regional tile origins are not aligned on the native pixel lattice")
            c1, r1 = c0 + dataset.width, r0 + dataset.height
            if not 0 <= c0 < c1 <= MAX_COLLECTION_DIMENSION or not 0 <= r0 < r1 <= MAX_COLLECTION_DIMENSION:
                raise ValueError("regional collection exceeds native dimension bounds")
            for _, other in self.tiles:
                if max(c0, other[0]) < min(c1, other[2]) and max(r0, other[1]) < min(r1, other[3]):
                    raise ValueError("regional tile footprints overlap; select a single non-overlapping edition")
            self.tiles.append((dataset, (c0, r0, c1, r1)))
            self.width, self.height = max(self.width, c1), max(self.height, r1)
        self.tiles.sort(key=lambda tile: tile[1])

    def evidence(self):
        return {"policy": "nonoverlapping-native-lattice-v1", "tileCount": len(self.tiles),
                "dimensions": [self.width, self.height], "affine": list(self.transform)[:6],
                "tiles": [{"offsetPixels": list(rect[:2]), "dimensions": [dataset.width, dataset.height]}
                          for dataset, rect in self.tiles],
                "missingTilePolicy": "masked-no-interpolation", "overlapPolicy": "reject"}

    def _read(self, window, masks, out_dtype="float64"):
        import numpy as np
        from rasterio.windows import Window

        values = (window.col_off, window.row_off, window.width, window.height)
        if any(not math.isfinite(value) or int(value) != value for value in values):
            raise ValueError("regional collection requires integer pixel windows")
        left, top, width, height = map(int, values)
        if (width <= 0 or height <= 0 or width * height > MAX_COLLECTION_WINDOW_PIXELS
                or left < 0 or top < 0 or left + width > self.width or top + height > self.height):
            raise ValueError("regional collection window exceeds bounds")
        self.cancel()
        output = np.zeros((height, width), dtype="uint8" if masks else out_dtype)
        for dataset, (c0, r0, c1, r1) in self.tiles:
            self.cancel()
            x0, y0, x1, y1 = max(left, c0), max(top, r0), min(left + width, c1), min(top + height, r1)
            if x0 >= x1 or y0 >= y1:
                continue
            native = Window(x0 - c0, y0 - r0, x1 - x0, y1 - y0)
            data = (dataset.read_masks(1, window=native) if masks else dataset.read(1, window=native, out_dtype=out_dtype))
            output[y0 - top:y1 - top, x0 - left:x1 - left] = data
        return output

    def read(self, band, *, window, out_dtype="float64"):
        if band != 1 or out_dtype != "float64":
            raise ValueError("unsupported regional collection band or output type")
        return self._read(window, False, out_dtype)

    def read_masks(self, band, *, window):
        if band != 1:
            raise ValueError("unsupported regional collection mask band")
        return self._read(window, True)
