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

`--terrain-sources` adds a bare-earth source on top: the USGS 3DEP 1/3
arc-second tiles that elevation-sources.json approves for routing. Each
dated tile of its catalog is downloaded, checked against the catalog's size
and ETag, and resampled onto its cell's posts in `--terrain`. The opened
Copernicus tiles then go to `--opened`, and `--out` gets the hybrid: a post
is 3DEP's where 3DEP has data and opened Copernicus's elsewhere. 3DEP stops
at the border of the United States, and the opened surface lies under the
ground, so the two would meet in a step. The difference between them at
3DEP's edge is therefore carried into the Copernicus side and fades to zero
over BLEND_POSTS posts. 3DEP's own posts are never changed.
"""

import argparse
import functools
import gzip
import hashlib
import http.client
import json
import math
import os
import re
import signal
import sys
import time
import urllib.request
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor, as_completed
from concurrent.futures.process import BrokenProcessPool
from dataclasses import dataclass, replace
from pathlib import Path

POSTS = 3601
STEP = 1 / 3600
NO_DATA = -32768
MARGIN = 2 * STEP
CELL_DEADLINE = 900
# A 3DEP tile is up to 500 MB, twenty times a Copernicus cell: its download gets an hour.
TERRAIN_DEADLINE = 3600
ROUNDS = 3
# A connection that closes in the middle of a body raises IncompleteRead, which is no OSError.
TRANSFER_ERRORS = (OSError, http.client.HTTPException)
METRES_PER_ARCSECOND = 30.87
OPENING_RADII = (15, 1000)
# Memory for one block of power-of-two runs in the opening, in float32 posts.
RUN_TABLE_POSTS = 1 << 24
NEIGHBOURS = tuple((dx, dy) for dy in (1, 0, -1) for dx in (-1, 0, 1) if (dx, dy) != (0, 0))
# The USGS 3DEP 1/3 arc-second tiles: three pixels per post, six pixels of overlap on every side.
TERRAIN_BUCKET = "https://prd-tnm.s3.amazonaws.com"
TERRAIN_PREFIX = "StagedProducts/Elevation/13/TIFF/historical"
TERRAIN_ADAPTER = "usgs-3dep-13-geotiff-v1"
TERRAIN_PIXELS_PER_POST = 3
TERRAIN_OVERLAP = 6
TERRAIN_HEIGHTS = (-500, 7000)
TERRAIN = "terrain"
# Posts over which the fill is lifted to meet the terrain at its edge: about 500 m north to south.
BLEND_POSTS = 16
FETCH_CONNECTIONS = 8
FETCH_PART = 32 << 20
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


def cell_of(name):
    """South-west corner (longitude, latitude) of an HGT cell name such as N40W074."""
    match = re.fullmatch(r"([NS])(\d{2})([EW])(\d{3})", name)
    if match:
        cell = (int(match[4]) * (1 if match[3] == "E" else -1), int(match[2]) * (1 if match[1] == "N" else -1))
        if hgt_name(*cell) == name:
            return cell
    raise ValueError(f"{name!r} is not an HGT cell name such as N40W074")


def post_transform(longitude, latitude):
    """Affine of the posts of a cell, each post at a pixel centre."""
    from affine import Affine

    return Affine(STEP, 0, longitude - STEP / 2, 0, -STEP, latitude + 1 + STEP / 2)


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
        except TRANSFER_ERRORS:
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


CATALOG_LINE = re.compile(r"([NS]\d{2}W\d{3}) (n\d{2}w\d{3}) (\d{8}) ([1-9]\d*) ([0-9a-f]{32}(?:-\d+)?)")


def format_terrain_catalog(tiles):
    """One line per cell: HGT cell, 3DEP tile, version date, bytes, S3 ETag."""
    return "".join(f"{hgt_name(*cell)} {tile} {date} {size} {etag}\n"
                   for cell, (tile, date, size, etag) in sorted(tiles.items(), key=lambda item: hgt_name(*item[0])))


def parse_terrain_catalog(text):
    """{cell: (tile, date, bytes, ETag)}; a 3DEP tile is named by its north-west corner."""
    tiles = {}
    for line in text.splitlines():
        match = CATALOG_LINE.fullmatch(line)
        if match is None:
            raise ValueError(f"invalid terrain catalog line: {line!r}")
        cell = cell_of(match[1])
        if match[2] != f"n{cell[1] + 1:02d}w{-cell[0]:03d}" or cell in tiles:
            raise ValueError(f"terrain catalog line names the wrong tile or repeats a cell: {line!r}")
        tiles[cell] = (match[2], match[3], int(match[4]), match[5])
    if format_terrain_catalog(tiles) != text:
        raise ValueError("the terrain catalog is not sorted by cell")
    return tiles


TERRAIN_FIELDS = {
    "id", "adapter", "title", "surfaceModel", "horizontalCrs", "verticalDatum", "verticalUnits", "origin",
    "coverage", "catalog", "catalogBytes", "catalogSha256", "tileCount", "license", "attribution", "termsUrl",
    "attributionUrl", "modifications", "approvedForRouting", "approvedAt", "approvedBy",
}


@dataclass(frozen=True)
class TerrainSource:
    """A bare-earth source of the routing elevation source list, one dated tile per cell."""
    id: str
    origin: str
    tiles: dict
    catalog_sha256: str
    terms_url: str
    attribution_url: str

    def tile_url(self, longitude, latitude):
        tile, date, _, _ = self.tiles[(longitude, latitude)]
        return f"{self.origin}/{tile}/USGS_13_{tile}_{date}.tif"

    def identity(self):
        return {"id": self.id, "catalogSha256": self.catalog_sha256, "termsUrl": self.terms_url,
                "attributionUrl": self.attribution_url}


def load_terrain_source(path):
    """The one terrain source of elevation-sources.json, with its catalog checked against its pin."""
    document = json.loads(path.read_text())
    sources = document.get("terrain") if isinstance(document, dict) else None
    if not isinstance(sources, list) or len(sources) != 1 or document.get("schemaVersion") != 1:
        raise ValueError("the elevation source list must hold exactly one terrain source")
    value = sources[0]
    if not isinstance(value, dict) or set(value) != TERRAIN_FIELDS:
        raise ValueError("invalid terrain source fields")
    if (value["adapter"] != TERRAIN_ADAPTER or value["origin"] != f"{TERRAIN_BUCKET}/{TERRAIN_PREFIX}"
            or value["surfaceModel"] != "dtm" or value["horizontalCrs"] != "EPSG:4269"
            or value["verticalUnits"] != "m"
            or not isinstance(value["id"], str) or re.fullmatch(r"[a-z][a-z0-9-]{2,63}", value["id"]) is None):
        raise ValueError("unsupported terrain source contract")
    if value["approvedForRouting"] is not True:
        raise ValueError(f"{value['id']} is not approved for routing")
    name = value["catalog"]
    if not isinstance(name, str) or Path(name).name != name:
        raise ValueError("the terrain catalog must be a file beside the source list")
    catalog = (path.parent / name).read_bytes()
    if len(catalog) != value["catalogBytes"] or hashlib.sha256(catalog).hexdigest() != value["catalogSha256"]:
        raise ValueError(f"{name} is not the catalog the source list pins")
    tiles = parse_terrain_catalog(catalog.decode())
    if len(tiles) != value["tileCount"]:
        raise ValueError(f"{name} holds {len(tiles)} tiles, not {value['tileCount']}")
    for field in ("termsUrl", "attributionUrl"):
        if not isinstance(value[field], str) or not value[field].startswith("https://"):
            raise ValueError(f"terrain source {field} must be HTTPS")
    return TerrainSource(value["id"], value["origin"], tiles, value["catalogSha256"], value["termsUrl"],
                         value["attributionUrl"])


def fetch_range(url, start, end, attempts=6):
    """Bytes [start, end) of `url`, the size of the whole object and its ETag."""
    request = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end - 1}"})
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                data = response.read()
                total = response.headers.get("Content-Range", "").rpartition("/")[2]
                if response.status != 206 or len(data) != end - start or not total.isdigit():
                    raise OSError(f"range {start}-{end} of {url} came back as {response.status} with {len(data)} bytes")
                return data, int(total), response.headers.get("ETag", "").strip('"')
        except TRANSFER_ERRORS:
            if attempt == attempts - 1:
                raise
            time.sleep(2 ** attempt)


def fetch_to_file(url, path, size, connections=FETCH_CONNECTIONS):
    """Download the `size` bytes of `url` into `path` over parallel ranges; returns its SHA-256 and ETag.

    One connection to the USGS bucket carried about 1 MB/s on 2026-11-26, and
    a tile is up to 500 MB.
    """
    parts = [(start, min(start + FETCH_PART, size)) for start in range(0, size, FETCH_PART)]
    with path.open("wb") as stream:
        stream.truncate(size)

        def part(bounds):
            data, total, etag = fetch_range(url, *bounds)
            if total != size:
                raise ValueError(f"{url} holds {total} bytes, not the catalog's {size}")
            os.pwrite(stream.fileno(), data, bounds[0])
            return etag

        with ThreadPoolExecutor(connections) as pool:
            etags = set(pool.map(part, parts))
    if len(etags) != 1:
        raise ValueError(f"{url} changed while it was read")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 22), b""):
            digest.update(block)
    return digest.hexdigest(), etags.pop()


def terrain_posts(dataset, cell):
    """A cell's posts from its own 3DEP tile, and how many of the tile's pixels hold no data.

    The tile is refused unless it is laid out as the cell's tile is: float32,
    NAD 83, three pixels per post and six pixels of overlap, so that a post
    lies on a pixel corner. GDAL widens the bilinear kernel by the ratio of
    the grids, so each post is a weighted mean of the six by six pixels around
    it. NAD 83 is read as WGS 84: the two differ by a metre or two, far less
    than the 30 m between posts.
    """
    import numpy as np

    longitude, latitude = cell
    fine = STEP / TERRAIN_PIXELS_PER_POST
    edge = TERRAIN_OVERLAP * fine
    side = (POSTS - 1) * TERRAIN_PIXELS_PER_POST + 2 * TERRAIN_OVERLAP
    transform, crs = dataset.transform, dataset.crs
    if (dataset.driver != "GTiff" or dataset.count != 1 or dataset.dtypes[0] != "float32" or dataset.nodata is None
            or (dataset.width, dataset.height) != (side, side) or crs is None or crs.to_epsg() != 4269
            or transform.b or transform.d
            or not math.isclose(transform.a, fine, rel_tol=1e-6) or not math.isclose(transform.e, -fine, rel_tol=1e-6)
            or abs(transform.c - (longitude - edge)) > fine / 100
            or abs(transform.f - (latitude + 1 + edge)) > fine / 100):
        raise ValueError(f"not the 3DEP 1/3 arc-second tile of {hgt_name(*cell)}")
    array = dataset.read(1)
    valid = (dataset.read_masks(1) != 0) & np.isfinite(array)
    if np.any(valid & ((array < TERRAIN_HEIGHTS[0]) | (array > TERRAIN_HEIGHTS[1]))):
        raise ValueError(f"3DEP elevations of {hgt_name(*cell)} lie outside {TERRAIN_HEIGHTS} m")
    array[~valid] = np.nan
    heights = np.full((POSTS, POSTS), np.nan, dtype="float32")
    resample_into(heights, post_transform(longitude, latitude), array, transform, 0)
    return heights, int((~valid).sum())


def build_terrain_cell(cell, chosen, out):
    """Download the cell's dated 3DEP tile, check it against the catalog and write its posts."""
    import rasterio

    source = chosen[cell]
    _, date, size, etag = source.tiles[cell]
    url = source.tile_url(*cell)
    scratch = out / "downloads" / f"{hgt_name(*cell)}.tif"
    scratch.parent.mkdir(exist_ok=True)
    try:
        sha256, found = fetch_to_file(url, scratch, size)
        if found != etag:
            raise ValueError(f"{url} has ETag {found}, not the catalog's {etag}")
        with rasterio.Env(**GDAL_OPTIONS), rasterio.open(scratch) as dataset:
            heights, invalid = terrain_posts(dataset, cell)
    finally:
        scratch.unlink(missing_ok=True)
    return write_receipt(out, {
        "cell": hgt_name(*cell),
        "source": source.id,
        "url": url,
        "bytes": size,
        "sha256": sha256,
        "etag": etag,
        "tileDate": date,
        "invalidPixels": invalid,
        **write_tile(out, cell, heights),
    })


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
    from rasterio.io import MemoryFile

    from map_platform.topography_raster import audited_copernicus_pixels

    longitude, latitude = cell
    source = chosen[cell]
    url = source.tile_url(longitude, latitude)
    heights = np.full((POSTS, POSTS), np.nan, dtype="float32")
    transform = post_transform(longitude, latitude)
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


def opening_window(cell, load, row_margin, column_margin, required=True):
    """The cell's posts with margins of its neighbours' posts around them.

    Neighbouring tiles share their border posts. The southern tile's posts
    win, then the eastern one's: for raw tiles, their own Copernicus pixels
    gave those posts. Every window that holds a post therefore gives it the
    same height. Without `required` the cell itself may have no tile, as a
    cell beside the terrain source's coverage has none of its tiles.
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
                if dx == dy == 0 and required:
                    raise ValueError(f"{hgt_name(*cell)} has no tile")
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


def _beside(array, outside):
    """The array as seen from each post's four neighbours; `outside` beyond its edges."""
    import numpy as np

    padded = np.pad(array, 1, constant_values=outside)
    return padded[:-2, 1:-1], padded[2:, 1:-1], padded[1:-1, :-2], padded[1:-1, 2:]


def blend_fill(terrain, fill, band):
    """Terrain posts where the terrain has data; elsewhere the fill, lifted to meet it at its edge.

    The fill is another surface, so it differs from the terrain where the two
    meet. A fill post one step from the terrain takes the mean difference
    (terrain minus fill) of the terrain posts beside it; each further step
    takes the mean of the posts a step nearer. That difference is added with a
    weight falling linearly from the edge to nothing beyond `band` steps. A
    post's result depends only on posts within `band` steps of it, so a window
    with that margin gives every post what a blend of the whole planet would.
    Returns the heights, the posts the terrain gave and the posts that were
    lifted.
    """
    import numpy as np

    known = np.isfinite(terrain)
    heights = np.where(known, terrain, fill).astype("float32")
    carried = np.where(known, terrain - fill, np.nan).astype("float32")
    done = known.copy()
    blended = np.zeros(known.shape, dtype=bool)
    for step in range(1, band + 1):
        up, down, left, right = _beside(done, False)
        new = ~done & (up | down | left | right)
        if not new.any():
            break
        finite = np.isfinite(carried)
        up, down, left, right = _beside(np.where(finite, carried, np.float32(0)), np.float32(0))
        total = up + down + left + right
        up, down, left, right = _beside(finite.astype("int8"), 0)
        count = up + down + left + right
        reached = new & (count > 0)
        carried[reached] = total[reached] / count[reached]
        lifted = reached & np.isfinite(fill)
        heights[lifted] = fill[lifted] + np.float32((band + 1 - step) / (band + 1)) * carried[lifted]
        blended |= lifted
        # A post beside terrain posts that carry nothing (the fill has no data under them) waits a step
        # for the posts beside it, so no row is left out of the lift.
        done |= reached
    return heights, known, blended


@dataclass(frozen=True)
class Hybrid:
    """Terrain tiles over opened Copernicus tiles, the fill blended at the terrain's edge."""
    terrain: TerrainSource
    tiles: Path
    opened: Path
    opening: Opening
    band: int = BLEND_POSTS

    def method(self):
        return {"name": "terrain-over-opening", "terrain": self.terrain.id, "blendPosts": self.band,
                "blend": "terrain minus fill at the terrain's edge, carried into the fill and faded linearly",
                "fill": self.opening.method()}


def hybrid_inputs(cell, chosen, hybrid):
    """SHA-256 of every opened and terrain tile the cell's blend reads, by cell name; None while one is missing.

    A cell with no terrain tile of its own or beside it is its opened tile
    unchanged, and reads nothing else.
    """
    opened, terrain = {}, {}
    for other in [cell] + [found[0] for found in (neighbour(*cell, dx, dy) for dx, dy in NEIGHBOURS) if found]:
        if other in chosen:
            receipt = _sourced_receipt(hybrid.opened, other, chosen)
            if receipt is None or receipt.get("method") != hybrid.opening.method():
                return None
            opened[hgt_name(*other)] = receipt["hgtSha256"]
        if other in hybrid.terrain.tiles:
            receipt = current_receipt(hybrid.tiles, other, {other: hybrid.terrain})
            if receipt is None:
                return None
            terrain[hgt_name(*other)] = receipt["hgtSha256"]
    if not terrain:
        opened = {hgt_name(*cell): opened[hgt_name(*cell)]}
    return {"opened": opened, "terrain": terrain}


def hybrid_cell(cell, chosen, out, hybrid):
    name = hgt_name(*cell)
    expected = None if cell not in chosen else hybrid_inputs(cell, chosen, hybrid)
    if expected is None:
        raise ValueError(f"{name} or a neighbour has no current opened or terrain tile")
    read = {"opened": {}, "terrain": {}}

    def loader(root, kind):
        def load(other):
            if hgt_name(*other) not in expected[kind]:
                return None
            posts, sha256 = read_tile(hgt_path(root, *other))
            read[kind][hgt_name(*other)] = sha256
            return posts
        return load

    margin = hybrid.band if expected["terrain"] else 0
    inner = (slice(margin, margin + POSTS),) * 2
    opened = opening_window(cell, loader(hybrid.opened, "opened"), margin, margin)
    counts = {"terrainPosts": 0, "blendedPosts": 0}
    if expected["terrain"]:
        terrain = opening_window(cell, loader(hybrid.tiles, "terrain"), margin, margin, required=False)
        heights, known, blended = blend_fill(terrain, opened, hybrid.band)
        counts = {"terrainPosts": int(known[inner].sum()), "blendedPosts": int(blended[inner].sum())}
        opened = heights
    if read != expected:
        raise ValueError(f"tiles around {name} do not match their receipts")
    receipt = _sourced_receipt(hybrid.opened, cell, chosen)
    return write_receipt(out, {
        "cell": name,
        "source": receipt["source"],
        "url": receipt["url"],
        "bytes": receipt["bytes"],
        "method": hybrid.method(),
        "inputTiles": read,
        **counts,
        **write_tile(out, cell, opened[inner]),
    })


_WORKER = {}


def _start_worker(chosen, out, opening=None, stage=None):
    _WORKER.update(chosen=chosen, out=out, opening=opening, stage=stage)


def _build(cell):
    # urlopen's timeout does not cover the name lookup. On 2026-11-24 two of the
    # planet's 26,475 cells blocked in it for good, with no socket open. With no
    # handler installed, SIGALRM ends the worker, which breaks the pool so
    # build_pending retries.
    stage = _WORKER.get("stage")
    signal.alarm(TERRAIN_DEADLINE if stage == TERRAIN else CELL_DEADLINE)
    try:
        if isinstance(stage, Hybrid):
            return hybrid_cell(cell, _WORKER["chosen"], _WORKER["out"], stage)
        if stage == TERRAIN:
            return build_terrain_cell(cell, _WORKER["chosen"], _WORKER["out"])
        if _WORKER.get("opening") is not None:
            return open_cell(cell, _WORKER["chosen"], _WORKER["out"], _WORKER["opening"])
        return build_cell(cell, _WORKER["chosen"], _WORKER["out"])
    finally:
        signal.alarm(0)


def run_pool(pending, chosen, out, jobs, opening=None, stage=None):
    started = time.monotonic()
    with ProcessPoolExecutor(jobs, initializer=_start_worker, initargs=(chosen, out, opening, stage)) as pool:
        futures = {pool.submit(_build, cell): cell for cell in pending}
        for done, future in enumerate(as_completed(futures), 1):
            future.result()
            if done % 100 == 0 or done == len(futures):
                rate = done / max(time.monotonic() - started, 1)
                print(f"{done}/{len(futures)} cells, {rate:.2f}/s", flush=True)


def build_pending(cells, chosen, out, jobs, rounds=ROUNDS, opening=None, stage=None):
    """Build, open or blend the cells without a current receipt, again after a worker dies.

    `stage` is TERRAIN for the terrain source's tiles, where `chosen` maps each
    cell to that source, or a Hybrid for the final blend.
    """
    if isinstance(stage, Hybrid):
        current, verb = functools.partial(current_hybrid_receipt, hybrid=stage), "blend"
    elif opening is not None:
        current, verb = functools.partial(current_opened_receipt, opening=opening), "open"
    else:
        current, verb = current_receipt, "build"
    for attempt in range(1, rounds + 1):
        pending = [cell for cell in cells if current(out, cell, chosen) is None]
        print(f"{len(cells)} cells, {len(pending)} to {verb}", flush=True)
        try:
            run_pool(pending, chosen, out, jobs, opening, stage)
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


def _sourced_receipt(out, cell, chosen):
    """The cell's receipt if its tile came from the source the policy picks now."""
    path = out / "receipts" / f"{hgt_name(*cell)}.json"
    if not path.exists():
        return None
    receipt = json.loads(path.read_text())
    source = chosen[cell]
    if receipt.get("source") != source.id or receipt.get("url") != source.tile_url(*cell):
        return None
    return receipt


def current_receipt(out, cell, chosen):
    """The cell's raw receipt if it was built from the source the policy picks now.

    An opened tile's receipt names the same source, but its `method` keeps
    it from ever counting as a raw tile.
    """
    receipt = _sourced_receipt(out, cell, chosen)
    return receipt if receipt is not None and receipt.get("method") is None else None


def current_opened_receipt(out, cell, chosen, opening):
    """The opened cell's receipt if it used this method and the raw tiles there are now."""
    receipt = _sourced_receipt(out, cell, chosen)
    if receipt is None or receipt.get("method") != opening.method():
        return None
    if receipt.get("inputTiles") != opening_inputs(cell, chosen, opening.raw):
        return None
    return receipt


def current_hybrid_receipt(out, cell, chosen, hybrid):
    """The blended cell's receipt if it used this method and the opened and terrain tiles there are now."""
    receipt = _sourced_receipt(out, cell, chosen)
    if receipt is None or receipt.get("method") != hybrid.method():
        return None
    if receipt.get("inputTiles") != hybrid_inputs(cell, chosen, hybrid):
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


TERRAIN_SCHEMA = "bicino-valhalla-terrain-tiles-v1"


def manifest_identity(directory, name="elevation-manifest.json"):
    manifest = directory / name
    return {"manifestSha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
            "cellListSha256": json.loads(manifest.read_text())["cellListSha256"]}


def write_terrain_manifest(out, list_path, terrain, cells, bounds=None):
    """The terrain tiles' own manifest. Its schema keeps build_graph.py from taking them for a whole set."""
    receipts = [current_receipt(out, cell, {cell: terrain}) for cell in cells]
    if not all(receipts):
        raise ValueError("a cell has no receipt for its current terrain tile")
    listing = "".join(f"{r['cell']} {r['hgtSha256']}\n" for r in sorted(receipts, key=lambda r: r["cell"]))
    manifest = {
        "schema": TERRAIN_SCHEMA,
        "format": "srtm-hgt-1-arcsecond-int16-big-endian-gzip",
        "posts": POSTS,
        "noData": NO_DATA,
        "resampling": "bilinear",
        "sourceList": file_identity(list_path),
        "source": terrain.identity(),
        "bounds": bounds,
        "catalogCells": len(terrain.tiles),
        "cells": len(receipts),
        "cellListSha256": hashlib.sha256(listing.encode()).hexdigest(),
        "sourceBytes": sum(r["bytes"] for r in receipts),
        "fileBytes": sum(r["fileBytes"] for r in receipts),
        "noDataPosts": sum(r["noDataPosts"] for r in receipts),
    }
    (out / "cells.txt").write_text(listing)
    path = out / "terrain-manifest.json"
    path.write_text(json.dumps(manifest, indent=2) + "\n")
    return path


def write_manifest(out, policy_path, policy, chosen, cells, bounds=None, opening=None, hybrid=None):
    """`bounds` and `catalogCells` tell a partial run from a complete one.

    `method` is null for raw tiles. Opened tiles record the opening and the
    raw manifest they were opened from. Hybrid tiles record the blend, the
    opened and terrain manifests they read and the terrain source.
    """
    import rasterio

    terrain_sources = []
    if hybrid is not None:
        receipts = [current_hybrid_receipt(out, cell, chosen, hybrid) for cell in cells]
        method = {**hybrid.method(), "inputs": {
            "opened": manifest_identity(hybrid.opened),
            "terrain": manifest_identity(hybrid.tiles, "terrain-manifest.json")}}
        if all(receipts):
            terrain_sources = [{**hybrid.terrain.identity(),
                                "cells": sum(1 for r in receipts if r["terrainPosts"]),
                                "posts": sum(r["terrainPosts"] for r in receipts),
                                "blendedPosts": sum(r["blendedPosts"] for r in receipts)}]
    elif opening is None:
        receipts, method = [current_receipt(out, cell, chosen) for cell in cells], None
    else:
        receipts = [current_opened_receipt(out, cell, chosen, opening) for cell in cells]
        method = {**opening.method(), "input": manifest_identity(opening.raw)}
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
        ] + terrain_sources,
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
    parser.add_argument("--terrain-sources", type=Path, metavar="FILE",
                        help="elevation-sources.json: put its terrain source over the opened tiles")
    parser.add_argument("--terrain", type=Path, help="The terrain source's tiles for --terrain-sources")
    parser.add_argument("--opened", type=Path, help="The opened tiles when --terrain-sources makes --out the hybrid")
    args = parser.parse_args()
    if not 1 <= args.jobs <= 64:
        parser.error("--jobs must be between 1 and 64")
    if (args.opening_radius is None) != (args.raw is None):
        parser.error("--opening-radius and --raw go together")
    if args.opening_radius is not None and not OPENING_RADII[0] <= args.opening_radius <= OPENING_RADII[1]:
        parser.error(f"--opening-radius must be between {OPENING_RADII[0]} and {OPENING_RADII[1]} metres")
    hybrid_arguments = (args.terrain_sources, args.terrain, args.opened)
    if any(value is not None for value in hybrid_arguments) and (None in hybrid_arguments or args.raw is None):
        parser.error("--terrain-sources, --terrain and --opened go together and need --opening-radius")
    out = args.out.resolve()
    raw = args.raw.resolve() if args.raw else out
    separate = {"--out": out, "--raw": raw if args.raw else None,
                "--terrain": args.terrain and args.terrain.resolve(), "--opened": args.opened and args.opened.resolve()}
    separate = {name: path for name, path in separate.items() if path is not None}
    # Valhalla reads every tile below its elevation directory.
    for name, path in separate.items():
        for other, other_path in separate.items():
            if name < other and (path.is_relative_to(other_path) or other_path.is_relative_to(path)):
                parser.error(f"{name} and {other} must be separate directories, neither inside the other")
    try:
        terrain = load_terrain_source(args.terrain_sources) if args.terrain_sources else None
    except (OSError, ValueError) as error:
        parser.error(f"--terrain-sources: {error}")
    policy = TopographySourcePolicy.load(args.policy)
    (raw / "receipts").mkdir(parents=True, exist_ok=True)
    (raw / "index").mkdir(exist_ok=True)
    indexes = load_indexes(policy, raw / "index")
    chosen = choose_sources(policy.sources, indexes)
    cells = sorted(chosen)
    # A blend reads the opened tiles of the cells beside it, and an opening the raw tiles beside those.
    raw_cells, raw_bounds = opened_cells, opened_bounds = cells, args.bounds
    if args.bounds:
        west, south, east, north = args.bounds
        cells = raw_cells = opened_cells = [(x, y) for x, y in cells if west <= x < east and south <= y < north]
        if terrain is not None:
            opened_cells, opened_bounds = with_neighbours(cells, chosen), [west - 1, south - 1, east + 1, north + 1]
            raw_cells, raw_bounds = with_neighbours(opened_cells, chosen), [west - 2, south - 2, east + 2, north + 2]
        elif args.raw:
            raw_cells, raw_bounds = with_neighbours(cells, chosen), [west - 1, south - 1, east + 1, north + 1]
    build_pending(raw_cells, chosen, raw, args.jobs)
    manifest = write_manifest(raw, args.policy, policy, chosen, raw_cells, raw_bounds)
    if args.raw:
        print(f"Raw elevation manifest: {manifest}", flush=True)
        opening = Opening(args.opening_radius, raw)
        opened = separate.get("--opened", out)
        (opened / "receipts").mkdir(parents=True, exist_ok=True)
        build_pending(opened_cells, chosen, opened, args.jobs, opening=opening)
        manifest = write_manifest(opened, args.policy, policy, chosen, opened_cells, opened_bounds, opening)
    if terrain is not None:
        print(f"Opened elevation manifest: {manifest}", flush=True)
        outside = sorted(hgt_name(*cell) for cell in terrain.tiles if cell not in chosen)
        if outside:
            print(f"{len(outside)} terrain tiles have no Copernicus cell and are left out: {' '.join(outside)}",
                  flush=True)
        terrain = replace(terrain, tiles={cell: tile for cell, tile in terrain.tiles.items() if cell in chosen})
        tiles = separate["--terrain"]
        (tiles / "receipts").mkdir(parents=True, exist_ok=True)
        terrain_cells = [cell for cell in opened_cells if cell in terrain.tiles]
        build_pending(terrain_cells, dict.fromkeys(terrain_cells, terrain), tiles, args.jobs, stage=TERRAIN)
        manifest = write_terrain_manifest(tiles, args.terrain_sources, terrain, terrain_cells, opened_bounds)
        print(f"Terrain manifest: {manifest}", flush=True)
        # A bounded run built only the terrain tiles around its cells, which is all its blends read.
        hybrid = Hybrid(replace(terrain, tiles={cell: terrain.tiles[cell] for cell in terrain_cells}),
                        tiles, opened, opening)
        (out / "receipts").mkdir(parents=True, exist_ok=True)
        build_pending(cells, chosen, out, args.jobs, stage=hybrid)
        manifest = write_manifest(out, args.policy, policy, chosen, cells, args.bounds, opening, hybrid)
    print(f"Elevation manifest: {manifest}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
