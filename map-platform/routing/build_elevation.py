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
is written once every cell has one. A cell that runs past CELL_DEADLINE ends its
worker, and the cells left without a receipt are built again, up to ROUNDS times.

Copernicus is a surface model: it measures the tops of buildings and trees.
`--opening-radius` removes them with a grey-scale morphological opening, an
erosion and then a dilation over an ellipse of that many metres. The raw tiles
go to `--raw` first, then each cell is opened from its own raw posts and a
margin of its eight neighbours' raw posts into `--out`, so the ellipse spans
cell borders and no cell depends on the order the cells were opened in.
"""

import argparse
import functools
import gzip
import hashlib
import json
import math
import os
import signal
import sys
import time
import urllib.request
from concurrent.futures import ProcessPoolExecutor, as_completed
from concurrent.futures.process import BrokenProcessPool
from dataclasses import dataclass
from pathlib import Path

POSTS = 3601
STEP = 1 / 3600
NO_DATA = -32768
MARGIN = 2 * STEP
CELL_DEADLINE = 900
ROUNDS = 3
METRES_PER_ARCSECOND = 30.87
OPENING_RADII = (15, 1000)
# Memory for one block of power-of-two runs in the opening, in float32 posts.
RUN_TABLE_POSTS = 1 << 24
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
    return write_receipt(out, {
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
        **write_tile(out, cell, heights),
    })


def write_tile(out, cell, heights):
    """Write one cell's posts; returns the receipt fields that identify the file."""
    payload, missing = encode_posts(heights)
    path = hgt_path(out, *cell)
    path.parent.mkdir(exist_ok=True)
    compressed = gzip.compress(payload, compresslevel=1, mtime=0)
    temporary = path.with_name(path.name + ".partial")
    temporary.write_bytes(compressed)
    os.replace(temporary, path)
    return {"hgtSha256": hashlib.sha256(payload).hexdigest(), "fileBytes": len(compressed), "noDataPosts": missing}


def write_receipt(out, receipt):
    receipt_path = out / "receipts" / f"{receipt['cell']}.json"
    temporary = receipt_path.with_suffix(".partial")
    temporary.write_text(json.dumps(receipt, sort_keys=True) + "\n")
    os.replace(temporary, receipt_path)
    return receipt


def read_tile(path):
    """A gzipped tile's posts as float32, no data as NaN, and its payload's SHA-256."""
    import numpy as np

    payload = gzip.decompress(path.read_bytes())
    posts = np.frombuffer(payload, dtype=">i2").reshape(POSTS, POSTS).astype("float32")
    posts[posts == NO_DATA] = np.nan
    return posts, hashlib.sha256(payload).hexdigest()


def footprint_rows(radius):
    """Half-height of the opening's ellipse in posts: one arc-second of latitude is 30.87 m."""
    return max(1, round(radius / METRES_PER_ARCSECOND))


def footprint_columns(radius, latitude, widest):
    """Half-width in posts at `latitude`, where an arc-second of longitude is cos(latitude) shorter.

    Capped at `widest` near the poles, where the ellipse would wrap the Earth.
    """
    stretch = abs(math.cos(math.radians(latitude)))
    if radius >= widest * METRES_PER_ARCSECOND * stretch:
        return widest
    return max(1, round(radius / (METRES_PER_ARCSECOND * stretch)))


@functools.lru_cache(maxsize=None)
def ellipse_spans(rows, columns):
    """Half-width of each row of the ellipse, from `-rows` to `rows`.

    The same posts as sample_elevation.footprint: (y / rows)^2 + (x / columns)^2 <= 1.
    """
    import numpy as np

    y, x = np.ogrid[-rows:rows + 1, -columns:columns + 1]
    mask = (y / rows) ** 2 + (x / columns) ** 2 <= 1
    return tuple(int(count) // 2 for count in mask.sum(axis=1))


def _bands(columns, start, stop):
    """Runs of rows in [start, stop) that share a half-width."""
    while start < stop:
        end = start + 1
        while end < stop and columns[end] == columns[start]:
            end += 1
        yield start, end, int(columns[start])
        start = end


def _run_table(block, depth, reduce):
    """Level k reduces runs of 2^k posts along each row of `block`."""
    levels = [block]
    for level in range(1, depth):
        shift = 1 << (level - 1)
        levels.append(reduce(levels[-1][:, :-shift], levels[-1][:, shift:]))
    return levels


def _run(levels, rows, span, offset, width, reduce):
    """Reduce over columns [j - span, j + span] of the padded rows, for j in [0, width)."""
    length = 2 * span + 1
    level = length.bit_length() - 1
    table, left = levels[level], offset - span
    right = left + length - (1 << level)
    return reduce(table[rows, left:left + width], table[rows, right:right + width])


def _block_rows(depth, padded_width):
    return max(1, RUN_TABLE_POSTS // (depth * padded_width))


def erode_rows(array, rows, columns):
    """Minimum over each post's ellipse, its half-width taken from its own row.

    Each row of an ellipse is a run of posts, and the minimum of any run is the
    minimum of two overlapping power-of-two runs. This gives exactly the
    minimum over every post of the ellipse without visiting each one. Edges
    repeat outward, as in sample_elevation.rank_filter.
    """
    import numpy as np

    height, width = array.shape
    widest = int(columns.max())
    padded = np.pad(array, ((rows, rows), (widest, widest)), mode="edge")
    depth = (2 * widest + 1).bit_length()
    step = _block_rows(depth, padded.shape[1])
    result = np.empty_like(array)
    for start in range(0, height, step):
        stop = min(start + step, height)
        levels = _run_table(padded[start:stop + 2 * rows], depth, np.minimum)
        for first, last, half_width in _bands(columns, start, stop):
            spans = ellipse_spans(rows, half_width)
            low = None
            for dy, span in enumerate(spans):
                part = _run(levels, slice(first - start + dy, last - start + dy), span, widest, width, np.minimum)
                low = part if low is None else np.minimum(low, part, out=low)
            result[first:last] = low
    return result


def dilate_rows(array, rows, columns):
    """Spread each post's value over its own ellipse, keeping the maximum.

    The ellipse belongs to the post it is centred on, as in the erosion, so a
    post is raised only by ellipses that cover it. That keeps the opening from
    ever raising a post, also where the half-width changes between rows.
    """
    import numpy as np

    height, width = array.shape
    widest = int(columns.max())
    padded = np.pad(array, ((rows, rows), (widest, widest)), mode="edge")
    padded_columns = np.pad(columns, rows, mode="edge")
    depth = (2 * widest + 1).bit_length()
    step = _block_rows(depth, padded.shape[1])
    result = np.full_like(array, -np.inf)
    for start in range(0, padded.shape[0], step):
        stop = min(start + step, padded.shape[0])
        levels = _run_table(padded[start:stop], depth, np.maximum)
        for first, last, half_width in _bands(padded_columns, start, stop):
            for dy, span in enumerate(ellipse_spans(rows, half_width)):
                # Padded row r is row r - rows; dy - rows rows below it.
                top, bottom = first + dy - 2 * rows, last + dy - 2 * rows
                low, high = max(top, 0), min(bottom, height)
                if low >= high:
                    continue
                source = slice(first - start + low - top, first - start + high - top)
                part = _run(levels, source, span, widest, width, np.maximum)
                np.maximum(result[low:high], part, out=result[low:high])
    return result


def open_posts(heights, rows, columns):
    """Grey-scale opening of `heights`: each post becomes the highest ellipse placed under the surface that covers it.

    Row i uses an ellipse of `rows` x `columns[i]` posts. No-data posts stay no
    data and take no part. An opening never raises a post, and it equals
    sample_elevation.open_heights when every row has the same half-width.
    """
    import numpy as np

    columns = np.asarray(columns)
    missing = ~np.isfinite(heights)
    eroded = erode_rows(np.where(missing, np.inf, heights).astype("float32"), rows, columns)
    eroded[np.isposinf(eroded)] = -np.inf  # an ellipse with no data at all
    opened = dilate_rows(eroded, rows, columns)
    opened[missing] = np.nan
    return opened


def row_latitudes(north, first_row, count):
    """Latitude of `count` post rows from `first_row` below the post row at whole degree `north`."""
    import numpy as np

    side = POSTS - 1
    return (north * side - (first_row + np.arange(count))) / side


def opening_window(cell, load, row_margin, column_margin):
    """The cell's raw posts with margins of its neighbours' raw posts around them.

    Neighbouring tiles share their border posts. The southern tile's posts
    win, then the eastern one's: their own Copernicus pixels gave those posts.
    Every window that holds a post therefore gives it the same height.
    """
    import numpy as np

    longitude, latitude = cell
    side = POSTS - 1
    window = np.full((POSTS + 2 * row_margin, POSTS + 2 * column_margin), np.nan, dtype="float32")
    for dy in (1, 0, -1):
        for dx in (-1, 0, 1):
            found = (cell, 0) if dx == dy == 0 else neighbour(longitude, latitude, dx, dy)
            tile = None if found is None else load(found[0])
            if tile is None:
                if dx == dy == 0:
                    raise ValueError(f"{hgt_name(*cell)} has no raw tile")
                continue
            top, left = row_margin - dy * side, column_margin + dx * side
            first_row, first_column = max(0, -top), max(0, -left)
            last_row, last_column = min(POSTS, window.shape[0] - top), min(POSTS, window.shape[1] - left)
            window[top + first_row:top + last_row, left + first_column:left + last_column] = \
                tile[first_row:last_row, first_column:last_column]
    return window


def opened_cell(cell, load, radius):
    """The cell's posts after an opening of `radius` metres, with margins from its neighbours.

    A post's opened height depends on raw posts up to two half-heights and two
    half-widths away, so a window of that margin gives every post the height
    it has in an opening of the whole mosaic. Half-widths stay below half a
    cell, so the margin never reaches past the neighbouring tiles.
    """
    import numpy as np

    rows = footprint_rows(radius)
    widest = (POSTS - 1) // 2 - 1
    row_margin = 2 * rows
    latitudes = row_latitudes(cell[1] + 1, -row_margin, POSTS + 2 * row_margin)
    columns = np.array([footprint_columns(radius, latitude, widest) for latitude in latitudes])
    column_margin = 2 * int(columns.max())
    window = opening_window(cell, load, row_margin, column_margin)
    opened = open_posts(window, rows, columns)
    return opened[row_margin:row_margin + POSTS, column_margin:column_margin + POSTS]


@dataclass(frozen=True)
class Opening:
    radius: float
    raw: Path

    def method(self):
        return {"name": "grey-opening", "radiusMetres": self.radius, "footprint": "ellipse",
                "footprintLatitude": "post row", "metresPerArcsecond": METRES_PER_ARCSECOND,
                "maximumHalfWidthPosts": (POSTS - 1) // 2 - 1, "noData": "kept, never part of an ellipse"}


def opening_inputs(cell, chosen, raw):
    """SHA-256 of every raw tile the cell's opening reads, by cell name; None while one is missing."""
    inputs = {}
    for other in [cell] + [found[0] for found in (neighbour(*cell, dx, dy) for dx, dy in NEIGHBOURS) if found]:
        if other not in chosen:
            continue
        receipt = current_receipt(raw, other, chosen)
        if receipt is None:
            return None
        inputs[hgt_name(*other)] = receipt["hgtSha256"]
    return inputs


def open_cell(cell, chosen, out, opening):
    expected = opening_inputs(cell, chosen, opening.raw)
    if expected is None:
        raise ValueError(f"{hgt_name(*cell)} or a neighbour has no current raw tile")
    read = {}

    def load(other):
        if other not in chosen:
            return None
        posts, sha256 = read_tile(hgt_path(opening.raw, *other))
        read[hgt_name(*other)] = sha256
        return posts

    heights = opened_cell(cell, load, opening.radius)
    if read != expected:
        raise ValueError(f"raw tiles around {hgt_name(*cell)} do not match their receipts")
    raw = current_receipt(opening.raw, cell, chosen)
    return write_receipt(out, {
        "cell": hgt_name(*cell),
        "source": raw["source"],
        "url": raw["url"],
        "bytes": raw["bytes"],
        "method": opening.method(),
        "inputTiles": read,
        "raw": raw,
        **write_tile(out, cell, heights),
    })


_WORKER = {}


def _start_worker(chosen, out, opening=None):
    _WORKER.update(chosen=chosen, out=out, opening=opening)


def _build(cell):
    # urlopen's timeout does not cover the name lookup. On 2026-11-24 two of the
    # planet's 26,475 cells blocked in it for good, with no socket open. With no
    # handler installed, SIGALRM ends the worker, which breaks the pool so
    # build_pending retries.
    signal.alarm(CELL_DEADLINE)
    try:
        if _WORKER.get("opening") is not None:
            return open_cell(cell, _WORKER["chosen"], _WORKER["out"], _WORKER["opening"])
        return build_cell(cell, _WORKER["chosen"], _WORKER["out"])
    finally:
        signal.alarm(0)


def run_pool(pending, chosen, out, jobs, opening=None):
    started = time.monotonic()
    with ProcessPoolExecutor(jobs, initializer=_start_worker, initargs=(chosen, out, opening)) as pool:
        futures = {pool.submit(_build, cell): cell for cell in pending}
        for done, future in enumerate(as_completed(futures), 1):
            future.result()
            if done % 100 == 0 or done == len(futures):
                rate = done / max(time.monotonic() - started, 1)
                print(f"{done}/{len(futures)} cells, {rate:.2f}/s", flush=True)


def build_pending(cells, chosen, out, jobs, rounds=ROUNDS, opening=None):
    """Build (or open) the cells without a current receipt, again after a worker dies."""
    current = current_receipt if opening is None else functools.partial(current_opened_receipt, opening=opening)
    for attempt in range(1, rounds + 1):
        pending = [cell for cell in cells if current(out, cell, chosen) is None]
        print(f"{len(cells)} cells, {len(pending)} to {'build' if opening is None else 'open'}", flush=True)
        try:
            run_pool(pending, chosen, out, jobs, opening)
            return
        except BrokenProcessPool as error:
            if attempt == rounds:
                raise
            print(f"A worker died ({error}); building the cells without a receipt again", flush=True)


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


def current_opened_receipt(out, cell, chosen, opening):
    """The opened cell's receipt if it used this method and the raw tiles there are now."""
    receipt = current_receipt(out, cell, chosen)
    if receipt is None or receipt.get("method") != opening.method():
        return None
    if receipt.get("inputTiles") != opening_inputs(cell, chosen, opening.raw):
        return None
    return receipt


def with_neighbours(cells, chosen):
    """The cells and every catalog cell next to one of them: an opening reads their raw posts."""
    found = set(cells)
    for cell in cells:
        for dx, dy in NEIGHBOURS:
            other = neighbour(*cell, dx, dy)
            if other is not None and other[0] in chosen:
                found.add(other[0])
    return sorted(found)


def write_manifest(out, policy_path, policy, chosen, cells, bounds=None, opening=None):
    """`bounds` and `catalogCells` tell a partial run from a complete one.

    `method` is null for raw tiles. Opened tiles record the opening and the
    raw manifest they were opened from.
    """
    import rasterio

    if opening is None:
        receipts, method = [current_receipt(out, cell, chosen) for cell in cells], None
    else:
        receipts = [current_opened_receipt(out, cell, chosen, opening) for cell in cells]
        raw_manifest = opening.raw / "elevation-manifest.json"
        method = {**opening.method(), "input": {
            "manifestSha256": hashlib.sha256(raw_manifest.read_bytes()).hexdigest(),
            "cellListSha256": json.loads(raw_manifest.read_text())["cellListSha256"]}}
    if not all(receipts):
        raise ValueError("a cell has no receipt for its current source")
    listing = "".join(f"{r['cell']} {r['hgtSha256']}\n" for r in sorted(receipts, key=lambda r: r["cell"]))
    manifest = {
        "schema": "bicino-valhalla-elevation-v1",
        "format": "srtm-hgt-1-arcsecond-int16-big-endian-gzip",
        "posts": POSTS,
        "noData": NO_DATA,
        "resampling": "bilinear",
        "method": method,
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
    parser.add_argument("--opening-radius", type=float, metavar="METRES",
                        help="Write raw tiles to --raw, then open them over an ellipse of this radius into --out")
    parser.add_argument("--raw", type=Path, help="Raw tiles for --opening-radius, outside --out")
    args = parser.parse_args()
    if not 1 <= args.jobs <= 64:
        parser.error("--jobs must be between 1 and 64")
    if (args.opening_radius is None) != (args.raw is None):
        parser.error("--opening-radius and --raw go together")
    if args.opening_radius is not None and not OPENING_RADII[0] <= args.opening_radius <= OPENING_RADII[1]:
        parser.error(f"--opening-radius must be between {OPENING_RADII[0]} and {OPENING_RADII[1]} metres")
    out = args.out.resolve()
    raw = args.raw.resolve() if args.raw else out
    # Valhalla reads every tile below its elevation directory.
    if args.raw and (raw.is_relative_to(out) or out.is_relative_to(raw)):
        parser.error("--raw and --out must be separate directories, neither inside the other")
    policy = TopographySourcePolicy.load(args.policy)
    (raw / "receipts").mkdir(parents=True, exist_ok=True)
    (raw / "index").mkdir(exist_ok=True)
    indexes = load_indexes(policy, raw / "index")
    chosen = choose_sources(policy.sources, indexes)
    cells = sorted(chosen)
    raw_cells, raw_bounds = cells, args.bounds
    if args.bounds:
        west, south, east, north = args.bounds
        cells = raw_cells = [(x, y) for x, y in cells if west <= x < east and south <= y < north]
        if args.raw:
            raw_cells, raw_bounds = with_neighbours(cells, chosen), [west - 1, south - 1, east + 1, north + 1]
    build_pending(raw_cells, chosen, raw, args.jobs)
    manifest = write_manifest(raw, args.policy, policy, chosen, raw_cells, raw_bounds)
    if args.raw:
        print(f"Raw elevation manifest: {manifest}", flush=True)
        opening = Opening(args.opening_radius, raw)
        (out / "receipts").mkdir(parents=True, exist_ok=True)
        build_pending(cells, chosen, out, args.jobs, opening=opening)
        manifest = write_manifest(out, args.policy, policy, chosen, cells, args.bounds, opening)
    print(f"Elevation manifest: {manifest}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
