#!/usr/bin/env python3
"""Build Valhalla elevation tiles from the production-approved Copernicus DEM.

Valhalla grades edges from one-degree SRTM-style HGT files: 3601 x 3601
big-endian int16 posts one arc-second apart, both edges included, -32768 for
no data, stored as `N47/N47E008.hgt.gz`. This writes one file for every cell in
the approved sources of the topography source policy (GLO-30 first, GLO-90
where GLO-30 has no cell). Heights are bilinear-resampled onto the posts from
the cell and the edges of its eight neighbours, which supply the posts on the
shared borders. The cell's own pixels win where both cover a post.

Run it in the map-platform image (rasterio 1.4.4) with network access. Each
cell is downloaded in full and hashed; neighbour edges are read with HTTP range
requests. A receipt per cell makes the run resumable; `elevation-manifest.json`
is written once every cell has one.
"""

import argparse
import gzip
import hashlib
import json
import math
import os
import sys
import time
import urllib.request
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

POSTS = 3601
STEP = 1 / 3600
NO_DATA = -32768
MARGIN = 2 * STEP
NEIGHBOURS = tuple((dx, dy) for dy in (1, 0, -1) for dx in (-1, 0, 1) if (dx, dy) != (0, 0))
GDAL_OPTIONS = {
    "GDAL_DISABLE_READDIR_ON_OPEN": "EMPTY_DIR",
    "CPL_VSIL_CURL_ALLOWED_EXTENSIONS": ".tif",
    "GDAL_HTTP_MAX_RETRY": "6",
    "GDAL_HTTP_RETRY_DELAY": "2",
    "GDAL_NUM_THREADS": "1",
}


def hgt_name(longitude, latitude):
    return (f"{'S' if latitude < 0 else 'N'}{abs(latitude):02d}"
            f"{'W' if longitude < 0 else 'E'}{abs(longitude):03d}")


def hgt_path(out, longitude, latitude):
    """Gzipped, which Valhalla reads like plain HGT and halves the planet's 690 GB."""
    name = hgt_name(longitude, latitude)
    return out / name[:3] / f"{name}.hgt.gz"


def neighbour(longitude, latitude, dx, dy):
    """Neighbouring cell and the longitude shift that puts it next to this one."""
    y = latitude + dy
    if not -90 <= y <= 89:
        return None
    x = longitude + dx
    shift = 0
    if x > 179:
        x, shift = x - 360, 360
    elif x < -180:
        x, shift = x + 360, -360
    return (x, y), shift


def choose_sources(sources, indexes):
    """Map every catalog cell to the highest-priority source that has it."""
    chosen = {}
    for source in sorted(sources, key=lambda s: -s.priority):
        for cell in indexes[source.id]:
            chosen.setdefault(cell, source)
    return chosen


def encode_posts(heights):
    import numpy as np

    if heights.shape != (POSTS, POSTS):
        raise ValueError("HGT posts must be 3601 x 3601")
    missing = ~np.isfinite(heights)
    posts = np.clip(np.rint(np.where(missing, 0, heights)), -32767, 32767).astype(">i2")
    posts[missing] = NO_DATA
    return posts.tobytes(), int(missing.sum())


def fetch(url, attempts=6):
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=120) as response:
                expected = int(response.headers["Content-Length"])
                data = response.read()
                if len(data) != expected:
                    raise OSError(f"short read {len(data)} of {expected}")
                return data, response.headers.get("ETag", "").strip('"')
        except OSError:
            if attempt == attempts - 1:
                raise
            time.sleep(2 ** attempt)


def resample_into(heights, transform, array, source_transform, shift):
    from affine import Affine
    from rasterio.crs import CRS
    from rasterio.warp import Resampling, reproject

    crs = CRS.from_epsg(4326)
    reproject(
        array, heights,
        src_transform=Affine.translation(shift, 0) @ source_transform, src_crs=crs, src_nodata=float("nan"),
        dst_transform=transform, dst_crs=crs, dst_nodata=float("nan"),
        init_dest_nodata=False, resampling=Resampling.bilinear, num_threads=1,
    )


def edge_window(dataset, longitude, latitude, cell, shift):
    """Pixels of a neighbour within two posts of this cell, invalid ones as NaN.

    None when the neighbour's footprint holds no post of this cell. With the
    point registration of the 2021 tiles only the east, south and south-east
    neighbours hold border posts.
    """
    import numpy as np
    from rasterio.windows import Window, from_bounds

    from map_platform.topography_raster import validate_copernicus_dataset

    validate_copernicus_dataset(dataset, list(cell))
    left, bottom, right, top = dataset.bounds
    if (right + shift <= longitude or left + shift > longitude + 1
            or top <= latitude or bottom > latitude + 1):
        return None, None
    west, south = longitude - MARGIN - shift, latitude - MARGIN
    east, north = longitude + 1 + MARGIN - shift, latitude + 1 + MARGIN
    wanted = from_bounds(west, south, east, north, dataset.transform)
    column, row = max(math.floor(wanted.col_off), 0), max(math.floor(wanted.row_off), 0)
    end_column = min(math.ceil(wanted.col_off + wanted.width), dataset.width)
    end_row = min(math.ceil(wanted.row_off + wanted.height), dataset.height)
    if end_column <= column or end_row <= row:
        return None, None
    window = Window(column, row, end_column - column, end_row - row)
    array = dataset.read(1, window=window).astype("float32")
    valid = (dataset.read_masks(1, window=window) != 0) & np.isfinite(array)
    if np.any(valid & ((array < -12000) | (array > 10000))):
        raise ValueError("valid neighbour DEM elevations exceed Earth profile bounds")
    array[~valid] = np.nan
    return array, dataset.window_transform(window)


def build_cell(cell, chosen, out):
    import numpy as np
    import rasterio
    from affine import Affine
    from rasterio.io import MemoryFile

    from map_platform.topography_raster import audited_copernicus_pixels

    longitude, latitude = cell
    source = chosen[cell]
    url = source.tile_url(longitude, latitude)
    heights = np.full((POSTS, POSTS), np.nan, dtype="float32")
    transform = Affine(STEP, 0, longitude - STEP / 2, 0, -STEP, latitude + 1 + STEP / 2)
    used = []
    with rasterio.Env(**GDAL_OPTIONS):
        for dx, dy in NEIGHBOURS:
            found = neighbour(longitude, latitude, dx, dy)
            if found is None or found[0] not in chosen:
                continue
            other, shift = found
            other_url = chosen[other].tile_url(*other)
            with rasterio.open("/vsicurl/" + other_url) as dataset:
                array, window_transform = edge_window(dataset, longitude, latitude, other, shift)
            if array is not None:
                resample_into(heights, transform, array, window_transform, shift)
                used.append(other_url)
        data, etag = fetch(url)
        with MemoryFile(data) as memory, memory.open() as dataset:
            native, _, audit = audited_copernicus_pixels(dataset, [longitude, latitude])
            resample_into(heights, transform, native, dataset.transform, 0)
    payload, missing = encode_posts(heights)
    path = hgt_path(out, longitude, latitude)
    path.parent.mkdir(exist_ok=True)
    compressed = gzip.compress(payload, compresslevel=1, mtime=0)
    temporary = path.with_name(path.name + ".partial")
    temporary.write_bytes(compressed)
    os.replace(temporary, path)
    receipt = {
        "cell": hgt_name(longitude, latitude),
        "source": source.id,
        "url": url,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "etag": etag,
        "pixelRegistration": audit["pixelRegistration"],
        "dimensions": audit["dimensions"],
        "invalidPixels": audit["invalidPixels"],
        "neighbourEdges": used,
        "hgtSha256": hashlib.sha256(payload).hexdigest(),
        "fileBytes": len(compressed),
        "noDataPosts": missing,
    }
    receipt_path = out / "receipts" / f"{receipt['cell']}.json"
    temporary = receipt_path.with_suffix(".partial")
    temporary.write_text(json.dumps(receipt, sort_keys=True) + "\n")
    os.replace(temporary, receipt_path)
    return receipt


_WORKER = {}


def _start_worker(chosen, out):
    _WORKER.update(chosen=chosen, out=out)


def _build(cell):
    return build_cell(cell, _WORKER["chosen"], _WORKER["out"])


def load_indexes(policy, index_dir):
    from map_platform.topography_sources import parse_tile_index

    indexes = {}
    for source in policy.sources:
        if not source.production_approved:
            raise ValueError(f"{source.id} is not approved for production")
        path = index_dir / f"{source.id}.tileList.txt"
        if not path.exists():
            data, _ = fetch(source.index_url)
            path.write_bytes(data)
        indexes[source.id] = parse_tile_index(source, path.read_bytes())
    return indexes


def file_identity(path):
    data = path.read_bytes()
    return {"name": path.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def current_receipt(out, cell, chosen):
    """The cell's receipt if it was built from the source the policy picks now."""
    path = out / "receipts" / f"{hgt_name(*cell)}.json"
    if not path.exists():
        return None
    receipt = json.loads(path.read_text())
    source = chosen[cell]
    if receipt.get("source") != source.id or receipt.get("url") != source.tile_url(*cell):
        return None
    return receipt


def write_manifest(out, policy_path, policy, chosen, cells, bounds=None):
    """`bounds` and `catalogCells` tell a partial run from a complete one."""
    import rasterio

    receipts = [current_receipt(out, cell, chosen) for cell in cells]
    if not all(receipts):
        raise ValueError("a cell has no receipt for its current source")
    listing = "".join(f"{r['cell']} {r['hgtSha256']}\n" for r in sorted(receipts, key=lambda r: r["cell"]))
    manifest = {
        "schema": "bicino-valhalla-elevation-v1",
        "format": "srtm-hgt-1-arcsecond-int16-big-endian-gzip",
        "posts": POSTS,
        "noData": NO_DATA,
        "resampling": "bilinear",
        "policy": {**file_identity(policy_path), "policyVersion": policy.version},
        "sources": [
            {"id": s.id, "indexSha256": s.index_sha256, "termsUrl": s.terms_url,
             "attributionUrl": s.attribution_url,
             "cells": sum(1 for r in receipts if r["source"] == s.id)}
            for s in policy.sources
        ],
        "runtime": {"rasterio": rasterio.__version__, "gdal": rasterio.__gdal_version__},
        "bounds": bounds,
        "catalogCells": len(chosen),
        "cells": len(receipts),
        "cellListSha256": hashlib.sha256(listing.encode()).hexdigest(),
        "sourceBytes": sum(r["bytes"] for r in receipts),
        "fileBytes": sum(r["fileBytes"] for r in receipts),
        "noDataPosts": sum(r["noDataPosts"] for r in receipts),
    }
    (out / "cells.txt").write_text(listing)
    path = out / "elevation-manifest.json"
    path.write_text(json.dumps(manifest, indent=2) + "\n")
    return path


def main():
    from map_platform.topography_sources import TopographySourcePolicy

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", required=True, type=Path, help="topography-source-policy-v2.json")
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--bounds", type=int, nargs=4, metavar=("WEST", "SOUTH", "EAST", "NORTH"),
                        help="Only cells whose south-west corner lies in these whole-degree bounds")
    args = parser.parse_args()
    if not 1 <= args.jobs <= 64:
        parser.error("--jobs must be between 1 and 64")
    policy = TopographySourcePolicy.load(args.policy)
    out = args.out.resolve()
    (out / "receipts").mkdir(parents=True, exist_ok=True)
    (out / "index").mkdir(exist_ok=True)
    indexes = load_indexes(policy, out / "index")
    chosen = choose_sources(policy.sources, indexes)
    cells = sorted(chosen)
    if args.bounds:
        west, south, east, north = args.bounds
        cells = [(x, y) for x, y in cells if west <= x < east and south <= y < north]
    pending = [cell for cell in cells if current_receipt(out, cell, chosen) is None]
    print(f"{len(cells)} cells, {len(pending)} to build", flush=True)
    started = time.monotonic()
    with ProcessPoolExecutor(args.jobs, initializer=_start_worker, initargs=(chosen, out)) as pool:
        futures = {pool.submit(_build, cell): cell for cell in pending}
        for done, future in enumerate(as_completed(futures), 1):
            future.result()
            if done % 100 == 0 or done == len(futures):
                rate = done / max(time.monotonic() - started, 1)
                print(f"{done}/{len(futures)} cells, {rate:.2f}/s", flush=True)
    manifest = write_manifest(out, args.policy, policy, chosen, cells, args.bounds)
    print(f"Elevation manifest: {manifest}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
