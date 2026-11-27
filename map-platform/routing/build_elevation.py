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

`--terrain-sources` adds the bare-earth sources that elevation-sources.json
approves for routing, each inside its own area: the USGS 3DEP 1/3 arc-second
tiles for the conterminous United States, Natural Resources Canada's
MRDEM-30 terrain model for Canada, and Sonny's LiDAR Digital Terrain Models
of Europe for the countries it builds from national terrain models. A 3DEP
cell is one dated tile of the source's catalog, downloaded and checked
against the catalog's size and ETag. MRDEM-30 is one raster of all Canada
on a 30 m Lambert grid; a cell reads the part of it under its posts in HTTP
ranges, and the object's size and ETag must be the pinned ones before and
after. Both are resampled onto the cell's posts. Sonny's tile of a cell is
a zip of its HGT file, already on the cell's posts, checked against the
catalog's size and SHA-256. Every source is cut to its area: 3DEP's older
tiles carry fill for Mexico and Canada from other sources, MRDEM-30 holds
heights beyond Canada's border, and Sonny's tiles hold SRTM beyond the
countries it covers and in a patch of northern Portugal. A cell on a border
takes each post from the source whose area holds it; the result is one
terrain tile per cell in `--terrain`.

The opened Copernicus tiles then go to `--opened`, and `--out` gets the
hybrid: a post is the terrain's where a terrain source has data and opened
Copernicus's elsewhere. The opened surface lies under the ground, so the two
would meet in a step. The difference between them at the terrain's edge is
therefore carried into the Copernicus side and fades to zero over
BLEND_POSTS posts. The terrain's own posts are never changed, and the two
terrain sources meet at the border as they are.
"""

import argparse
import faulthandler
import functools
import gzip
import hashlib
import http.client
import io
import json
import math
import os
import re
import signal
import sys
import tempfile
import threading
import time
import urllib.request
import zipfile
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor, as_completed
from concurrent.futures.process import BrokenProcessPool
from dataclasses import dataclass, replace
from pathlib import Path

POSTS = 3601
STEP = 1 / 3600
NO_DATA = -32768
MARGIN = 2 * STEP
CELL_DEADLINE = 900
# So long before its deadline a cell that has had no answer says so, and its worker's stack is written.
HANG_NOTICE = 20
# A 3DEP tile is up to 500 MB, twenty times a Copernicus cell: its download gets an hour. A cell that reads
# only a part of one object, as MRDEM-30's do, keeps the cell deadline.
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
# Natural Resources Canada's MRDEM-30 terrain model: one cloud-optimised GeoTIFF of all Canada, 30 m pixels on
# NAD83(CSRS) / Canada Atlas Lambert, heights in CGVD2013.
MRDEM_ADAPTER = "nrcan-mrdem-30-cog-v1"
MRDEM_URL = "https://canelevation-dem.s3.ca-central-1.amazonaws.com/mrdem-30/mrdem-30-dtm.tif"
MRDEM_EPSG = 3979
MRDEM_PIXEL = 30.0
MRDEM_NO_DATA = -32767.0
# NAD83(CSRS) in degrees, the datum of MRDEM-30's grid: posts are placed in it so that no datum shift is applied.
MRDEM_GEOGRAPHIC_EPSG = 4617
# Heights beyond these are not ground in MRDEM-30. The Bay of Fundy's flats fall dry down to about 9 m under
# the datum, and Mount Logan is 5,959 m high. The lidar part has pits at shorelines: at Holberg Inlet the
# heights fall from the sea's -1 m to -695 m within ten pixels. Such pixels are dropped with the pixels
# within MRDEM_REJECT_MARGIN of them, which are the walls of the pit.
MRDEM_HEIGHTS = (-10, 7000)
MRDEM_REJECT_MARGIN = 4
# A read that stalls ends with an error after a minute, in place of the worker's death at the cell deadline.
MRDEM_HTTP_OPTIONS = {
    "GDAL_HTTP_CONNECTTIMEOUT": "30",
    "GDAL_HTTP_LOW_SPEED_TIME": "60",
    "GDAL_HTTP_LOW_SPEED_LIMIT": "1000",
}
# Sonny's LiDAR Digital Terrain Models of Europe: one zip per one-degree cell in a public Google Drive folder,
# holding the cell's SRTM-style HGT file. Its posts are the cell's own, in whole metres of each country's own
# height datum. A Drive file has no ETag, so the catalog pins each zip's SHA-256 in its place.
SONNY_ADAPTER = "sonny-dtm-europe-1s-hgt-v1"
SONNY_ORIGIN = "https://drive.usercontent.google.com/download"
# A copy of a source's files in a storage bucket, named by cell: `gs://BUCKET/PREFIX/` with a slash at the end.
MIRROR = re.compile(r"gs://([a-z0-9][a-z0-9._-]{1,61}[a-z0-9])/((?:[A-Za-z0-9_-][A-Za-z0-9._-]*/)+)")
# Heights beyond these are not ground, as in MRDEM-30. The polders of the Netherlands lie down to about 7 m under
# the datum and the Alps reach 4,808 m. Such posts are dropped with the posts within SONNY_REJECT_MARGIN of them.
SONNY_HEIGHTS = (-10, 7000)
SONNY_REJECT_MARGIN = 4
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


# A Drive file is named by its id; files made before 2021 also need their resource key, after a slash.
SONNY_CATALOG_LINE = re.compile(
    r"([NS]\d{2}[EW]\d{3}) ([A-Za-z0-9_-]{20,64}(?:/0-[A-Za-z0-9_-]{10,40})?) (\d{8}) ([1-9]\d*) ([0-9a-f]{64})")


def format_sonny_catalog(tiles):
    """One line per cell: HGT cell, Drive file (id, and resource key after a slash), its date, bytes and SHA-256."""
    return "".join(f"{hgt_name(*cell)} {file_id} {date} {size} {sha256}\n"
                   for cell, (file_id, date, size, sha256) in sorted(tiles.items(), key=lambda item: hgt_name(*item[0])))


def parse_sonny_catalog(text):
    """{cell: (Drive file, date, bytes, SHA-256)} of Sonny's tiles."""
    tiles = {}
    for line in text.splitlines():
        match = SONNY_CATALOG_LINE.fullmatch(line)
        if match is None:
            raise ValueError(f"invalid terrain catalog line: {line!r}")
        cell = cell_of(match[1])
        if cell in tiles:
            raise ValueError(f"terrain catalog line repeats a cell: {line!r}")
        tiles[cell] = (match[2], match[3], int(match[4]), match[5])
    if format_sonny_catalog(tiles) != text:
        raise ValueError("the terrain catalog is not sorted by cell")
    return tiles


def format_cell_catalog(cells):
    """One HGT cell name per line: the cells a source of one object has a tile for."""
    return "".join(f"{name}\n" for name in sorted(hgt_name(*cell) for cell in cells))


def parse_cell_catalog(text):
    """{cell: None} of a catalog that names cells only."""
    try:
        cells = dict.fromkeys(cell_of(line) for line in text.splitlines())
    except ValueError as error:
        raise ValueError(f"invalid terrain catalog line: {error}") from None
    if format_cell_catalog(cells) != text:
        raise ValueError("the terrain catalog repeats a cell or is not sorted by cell")
    return cells


TERRAIN_FIELDS = {
    "id", "adapter", "title", "surfaceModel", "horizontalCrs", "verticalDatum", "verticalUnits", "origin",
    "coverage", "area", "areaBytes", "areaSha256", "areaSource", "catalog", "catalogBytes", "catalogSha256",
    "tileCount", "license", "attribution", "termsUrl", "attributionUrl", "modifications", "approvedForRouting",
    "approvedAt", "approvedBy",
}
# What each adapter's source must say besides: (origin, horizontal CRS, further fields, catalog parser).
# A source of one object pins that object's size and ETag, as a tile catalog pins every tile's.
TERRAIN_ADAPTERS = {
    TERRAIN_ADAPTER: (f"{TERRAIN_BUCKET}/{TERRAIN_PREFIX}", "EPSG:4269", set(), parse_terrain_catalog),
    MRDEM_ADAPTER: (MRDEM_URL, f"EPSG:{MRDEM_EPSG}", {"originBytes", "originEtag", "originModified"},
                    parse_cell_catalog),
    SONNY_ADAPTER: (SONNY_ORIGIN, "EPSG:4326", {"mirror"}, parse_sonny_catalog),
}
OBJECT_ETAG = re.compile(r"[0-9a-f]{32}(-\d+)?")
OBJECT_DATE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")


@dataclass(frozen=True)
class TerrainSource:
    """A bare-earth source of the routing elevation source list.

    `tiles` maps each cell the source has a tile for to its dated tile, or to
    None when the source is one object that every cell reads a part of;
    `origin_object` is then that object's size and ETag. `area` is the gzipped
    GeoJSON polygon the source is approved for. Posts outside it are dropped,
    whatever the source holds there.
    """
    id: str
    origin: str
    tiles: dict
    catalog_sha256: str
    terms_url: str
    attribution_url: str
    area: Path
    area_sha256: str
    adapter: str = TERRAIN_ADAPTER
    origin_object: tuple = None
    # The bucket copy, and the directory a build fetched it into before it started (see elevation_cache.py).
    mirror: str = None
    files: Path = None

    def tile_url(self, longitude, latitude):
        if self.origin_object is not None:
            return self.origin
        tile, date, _, _ = self.tiles[(longitude, latitude)]
        if self.adapter == SONNY_ADAPTER:
            file_id, _, key = tile.partition("/")
            return f"{self.origin}?id={file_id}&export=download&confirm=t" + (f"&resourcekey={key}" if key else "")
        return f"{self.origin}/{tile}/USGS_13_{tile}_{date}.tif"

    def pin(self, cell):
        """What a terrain tile's receipt names when this source, as pinned and read now, gave it posts.

        `rejects` is the rule by which a source's pixels are dropped as not
        ground, or None. A tile read under another rule is built again. For
        Sonny's tiles `etag` is the zip's SHA-256, which the catalog pins.
        """
        size, etag = self.origin_object or self.tiles[cell][2:]
        rejects = None
        if self.adapter == MRDEM_ADAPTER:
            rejects = {"below": MRDEM_HEIGHTS[0], "above": MRDEM_HEIGHTS[1], "pixelsAround": MRDEM_REJECT_MARGIN}
        elif self.adapter == SONNY_ADAPTER:
            rejects = {"below": SONNY_HEIGHTS[0], "above": SONNY_HEIGHTS[1], "pixelsAround": SONNY_REJECT_MARGIN}
        return {"source": self.id, "url": self.tile_url(*cell), "bytes": size, "etag": etag,
                "areaSha256": self.area_sha256, "rejects": rejects}

    def mirror_file(self, cell):
        """The name, bytes and SHA-256 of the cell's file in the mirror."""
        if self.adapter == SONNY_ADAPTER:
            _, _, size, sha256 = self.tiles[cell]
            return f"{hgt_name(*cell)}.zip", size, sha256
        raise ValueError(f"{self.id} keeps no copy of its files")

    def identity(self):
        identity = {"id": self.id, "catalogSha256": self.catalog_sha256, "areaSha256": self.area_sha256,
                    "termsUrl": self.terms_url, "attributionUrl": self.attribution_url}
        if self.origin_object is not None:
            identity["originBytes"], identity["originEtag"] = self.origin_object
        return identity


def load_terrain_sources(path):
    """The terrain sources of elevation-sources.json in its order, each catalog and area checked against its pin."""
    document = json.loads(path.read_text())
    values = document.get("terrain") if isinstance(document, dict) else None
    if not isinstance(values, list) or not values or document.get("schemaVersion") != 2:
        raise ValueError("the elevation source list must hold terrain sources under schemaVersion 2")
    sources = [_terrain_source(path, value) for value in values]
    if len({source.id for source in sources}) != len(sources):
        raise ValueError("the elevation source list names a terrain source twice")
    return tuple(sources)


def _terrain_source(path, value):
    named = value.get("adapter") if isinstance(value, dict) else None
    adapter = TERRAIN_ADAPTERS.get(named) if isinstance(named, str) else None
    if adapter is None:
        raise ValueError("unsupported terrain source adapter")
    origin, crs, further, parse_catalog = adapter
    if set(value) != TERRAIN_FIELDS | further:
        raise ValueError("invalid terrain source fields")
    if (value["origin"] != origin or value["surfaceModel"] != "dtm" or value["horizontalCrs"] != crs
            or value["verticalUnits"] != "m"
            or not isinstance(value["id"], str) or re.fullmatch(r"[a-z][a-z0-9-]{2,63}", value["id"]) is None):
        raise ValueError("unsupported terrain source contract")
    if value["approvedForRouting"] is not True:
        raise ValueError(f"{value['id']} is not approved for routing")
    origin_object = None
    if "originBytes" in further:
        size, etag, modified = value["originBytes"], value["originEtag"], value["originModified"]
        if (type(size) is not int or size <= 0 or not isinstance(etag, str) or OBJECT_ETAG.fullmatch(etag) is None
                or not isinstance(modified, str) or OBJECT_DATE.fullmatch(modified) is None):
            raise ValueError(f"{value['id']} must pin its origin's size, ETag and date")
        origin_object = (size, etag)
    mirror = value.get("mirror")
    if "mirror" in further and (not isinstance(mirror, str) or MIRROR.fullmatch(mirror) is None):
        raise ValueError(f"{value['id']} must name its copy as gs://BUCKET/PREFIX/")
    pinned = {}
    for kind in ("catalog", "area"):
        name = value[kind]
        if not isinstance(name, str) or Path(name).name != name:
            raise ValueError(f"the terrain {kind} must be a file beside the source list")
        pinned[kind] = (path.parent / name).read_bytes()
        if (len(pinned[kind]) != value[f"{kind}Bytes"]
                or hashlib.sha256(pinned[kind]).hexdigest() != value[f"{kind}Sha256"]):
            raise ValueError(f"{name} is not the {kind} the source list pins")
    tiles = parse_catalog(pinned["catalog"].decode())
    if len(tiles) != value["tileCount"]:
        raise ValueError(f"{value['catalog']} holds {len(tiles)} tiles, not {value['tileCount']}")
    for field in ("termsUrl", "attributionUrl"):
        if not isinstance(value[field], str) or not value[field].startswith("https://"):
            raise ValueError(f"terrain source {field} must be HTTPS")
    return TerrainSource(value["id"], value["origin"], tiles, value["catalogSha256"], value["termsUrl"],
                         value["attributionUrl"], path.parent / value["area"], value["areaSha256"],
                         value["adapter"], origin_object, mirror)


@dataclass(frozen=True)
class Terrain:
    """The terrain sources of a build, in the order of the source list, and the cells they have tiles for.

    `cells` maps a cell to the sources with a tile for it. The cell's terrain
    tile takes each post from the first of them that has data there inside
    its own area. The areas of the checked-in sources overlap only in the
    sea around Machias Seal Island, which both countries claim.
    """
    sources: tuple
    cells: dict

    @classmethod
    def over(cls, sources, keep):
        """The sources over the cells of `keep` that one of them has a tile for."""
        cells = {cell: tuple(source for source in sources if cell in source.tiles) for cell in keep}
        return cls(tuple(sources), {cell: found for cell, found in cells.items() if found})

    def ids(self):
        return [source.id for source in self.sources]


@functools.lru_cache(maxsize=4)
def load_area(path, sha256):
    """The area of a terrain source: its polygon, and the same prepared for containment tests."""
    from shapely.geometry import shape
    from shapely.prepared import prep

    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != sha256:
        raise ValueError(f"{path.name} is not the area the source list pins")
    feature = json.loads(gzip.decompress(data))
    if feature.get("type") != "Feature" or feature["geometry"]["type"] not in ("Polygon", "MultiPolygon"):
        raise ValueError(f"{path.name} must hold one GeoJSON polygon feature")
    polygon = shape(feature["geometry"])
    if polygon.is_empty or not polygon.is_valid:
        raise ValueError(f"{path.name} holds no valid polygon")
    return polygon, prep(polygon)


def posts_in_area(cell, area):
    """Which of a cell's posts lie in the area: True for all, False for none, or a mask of the posts.

    A post is in when its own position is, not when the square around it touches the area.
    """
    from rasterio.features import rasterize
    from shapely.geometry import box

    polygon, prepared = area
    longitude, latitude = cell
    posts = box(longitude - STEP / 2, latitude - STEP / 2, longitude + 1 + STEP / 2, latitude + 1 + STEP / 2)
    if prepared.contains(posts):
        return True
    part = polygon.intersection(posts)
    if part.is_empty:
        return False
    return rasterize([(part, 1)], out_shape=(POSTS, POSTS), transform=post_transform(longitude, latitude),
                     fill=0, dtype="uint8").astype(bool)


def clip_to_area(heights, cell, area):
    """Drop the posts outside the area; returns how many held data."""
    import numpy as np

    inside = posts_in_area(cell, area)
    if inside is True:
        return 0
    outside = np.isfinite(heights) if inside is False else np.isfinite(heights) & ~inside
    heights[outside] = np.nan
    return int(outside.sum())


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
    failed = threading.Event()
    with path.open("wb") as stream:
        stream.truncate(size)

        def part(bounds):
            # Once a part has failed for good, the rest are not asked for: the tile is not read to its end first.
            if failed.is_set():
                return None
            try:
                data, total, etag = fetch_range(url, *bounds)
                if total != size:
                    raise ValueError(f"{url} holds {total} bytes, not the catalog's {size}")
            except BaseException:
                failed.set()
                raise
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


def read_usgs_cell(source, cell, out):
    """The cell's posts from its dated 3DEP tile, downloaded and checked against the catalog, and what was read."""
    import rasterio

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
    return heights, {"sha256": sha256, "readBytes": size, "tileDate": date, "invalidPixels": invalid}


def object_identity(url, attempts=6):
    """Size and ETag of the object at `url`, from a HEAD request."""
    request = urllib.request.Request(url, method="HEAD")
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return int(response.headers["Content-Length"]), response.headers.get("ETag", "").strip('"')
        except TRANSFER_ERRORS:
            if attempt == attempts - 1:
                raise
            time.sleep(2 ** attempt)


def mrdem_window(dataset, cell):
    """The pixels of the MRDEM-30 raster under the cell's posts and a margin around them; None for none.

    The raster is refused unless it is laid out as MRDEM-30 is: float32,
    Canada Atlas Lambert on NAD83(CSRS), 30 m pixels, -32767 for no data.
    A cell's box of longitudes and latitudes is no rectangle on that grid,
    so its edges are followed point by point.

    The margin is two posts and two pixels for the resampling, and
    MRDEM_REJECT_MARGIN pixels more: a pixel that a post is made of is then
    read with every pixel that can have it dropped, so two cells give the
    posts on their shared border the same heights.
    """
    from rasterio.crs import CRS
    from rasterio.warp import transform_bounds
    from rasterio.windows import Window, from_bounds

    transform, crs = dataset.transform, dataset.crs
    if (dataset.driver != "GTiff" or dataset.count != 1 or dataset.dtypes[0] != "float32"
            or dataset.nodata != MRDEM_NO_DATA or crs is None or crs.to_epsg() != MRDEM_EPSG
            or transform.b or transform.d or not math.isclose(transform.a, MRDEM_PIXEL, rel_tol=1e-9)
            or not math.isclose(transform.e, -MRDEM_PIXEL, rel_tol=1e-9)):
        raise ValueError("not the MRDEM-30 raster")
    longitude, latitude = cell
    span = (POSTS - 1) * STEP
    left, bottom, right, top = transform_bounds(
        CRS.from_epsg(MRDEM_GEOGRAPHIC_EPSG), crs, longitude - MARGIN, latitude + 1 - span - MARGIN,
        longitude + span + MARGIN, latitude + 1 + MARGIN, densify_pts=256)
    wanted = from_bounds(left, bottom, right, top, transform)
    pad = 2 + MRDEM_REJECT_MARGIN
    column, row = max(math.floor(wanted.col_off) - pad, 0), max(math.floor(wanted.row_off) - pad, 0)
    end_column = min(math.ceil(wanted.col_off + wanted.width) + pad, dataset.width)
    end_row = min(math.ceil(wanted.row_off + wanted.height) + pad, dataset.height)
    if end_column <= column or end_row <= row:
        return None
    return Window(column, row, end_column - column, end_row - row)


def spread(mask, margin):
    """The mask with every pixel marked that lies within `margin` rows and columns of a marked one."""
    for axis in (0, 1):
        grown = mask.copy()
        for shift in range(1, margin + 1):
            ahead = [slice(None), slice(None)]
            behind = [slice(None), slice(None)]
            ahead[axis], behind[axis] = slice(shift, None), slice(None, -shift)
            grown[tuple(behind)] |= mask[tuple(ahead)]
            grown[tuple(ahead)] |= mask[tuple(behind)]
        mask = grown
    return mask


def mrdem_posts(dataset, cell):
    """A cell's posts from the MRDEM-30 raster, the window that was read and what its pixels were.

    A post is the bilinear mean of the pixels around it. The grid's 30 m are
    the posts' spacing from north to south and more than their spacing from
    east to west, so nothing is averaged away. NAD83(CSRS) is read as WGS 84,
    which is a metre or two from it. The heights stay in CGVD2013.

    Pixels outside MRDEM_HEIGHTS are not ground. They are dropped with the
    pixels around them and counted; their posts have no data, which the
    hybrid fills from opened Copernicus like any other hole. The raster is
    pinned, so stopping on them would stop every build.
    """
    import numpy as np
    from rasterio.crs import CRS
    from rasterio.warp import Resampling, reproject

    heights = np.full((POSTS, POSTS), np.nan, dtype="float32")
    window = mrdem_window(dataset, cell)
    read = {"sha256": hashlib.sha256(b"").hexdigest(), "invalidPixels": 0, "rejectedPixels": 0,
            "rejectedHeights": None}
    if window is None:
        return heights, None, read
    array = dataset.read(1, window=window)
    read["sha256"] = hashlib.sha256(array.tobytes()).hexdigest()
    valid = (dataset.read_masks(1, window=window) != 0) & np.isfinite(array) & (array != MRDEM_NO_DATA)
    read["invalidPixels"] = int((~valid).sum())
    read.update(drop_beyond(array, valid, MRDEM_HEIGHTS, MRDEM_REJECT_MARGIN))
    array[~valid] = np.nan
    reproject(
        array, heights,
        src_transform=dataset.window_transform(window), src_crs=dataset.crs, src_nodata=float("nan"),
        dst_transform=post_transform(*cell), dst_crs=CRS.from_epsg(MRDEM_GEOGRAPHIC_EPSG), dst_nodata=float("nan"),
        init_dest_nodata=False, resampling=Resampling.bilinear, num_threads=1,
    )
    return heights, window, read


def read_mrdem_cell(source, cell, out):
    """The cell's posts from the one MRDEM-30 object, read in ranges, and what was read.

    The object has no dated copies, so it is the pinned one only while its
    size and ETag say so. They are asked for before and after the read: a
    cell never mixes two versions unseen.
    """
    import rasterio

    url = source.tile_url(*cell)

    def check():
        found = object_identity(url)
        if found != source.origin_object:
            raise ValueError(f"{url} is {found[0]} bytes with ETag {found[1]}, not the pinned "
                             f"{source.origin_object[0]} bytes with ETag {source.origin_object[1]}")

    check()
    with rasterio.Env(**GDAL_OPTIONS, **MRDEM_HTTP_OPTIONS), rasterio.open("/vsicurl/" + url) as dataset:
        heights, window, read = mrdem_posts(dataset, cell)
    check()
    if read["rejectedPixels"]:
        low, high = read["rejectedHeights"]
        print(f"{hgt_name(*cell)}: dropped {read['rejectedPixels']} MRDEM-30 pixels at and around heights from "
              f"{low:.0f} to {high:.0f} m, which are not ground", flush=True)
    pixels = 0 if window is None else window.width * window.height
    return heights, {**read, "readBytes": 4 * pixels,
                     "window": None if window is None else [window.col_off, window.row_off, window.width, window.height]}


def drop_beyond(array, valid, heights, margin):
    """Mark invalid the pixels outside `heights` and those within `margin` of them; what was dropped."""
    import numpy as np

    read = {"rejectedPixels": 0, "rejectedHeights": None}
    beyond = valid & ((array < heights[0]) | (array > heights[1]))
    if beyond.any():
        read["rejectedHeights"] = [float(array[beyond].min()), float(array[beyond].max())]
        rows, columns = np.nonzero(beyond)
        box = (slice(max(int(rows.min()) - margin, 0), int(rows.max()) + margin + 1),
               slice(max(int(columns.min()) - margin, 0), int(columns.max()) + margin + 1))
        dropped = spread(beyond[box], margin) & valid[box]
        read["rejectedPixels"] = int(dropped.sum())
        valid[box] &= ~dropped
    return read


def sonny_posts(data, cell):
    """A cell's posts from Sonny's zip of its HGT file, and what its posts were.

    The zip must hold the cell's HGT file and nothing else: 3601 x 3601
    big-endian int16 posts on the cell's own grid, -32768 for no data.
    Posts outside SONNY_HEIGHTS are not ground; they are dropped with the
    posts around them, and the hybrid fills them from opened Copernicus. A
    pit within SONNY_REJECT_MARGIN posts of a cell's edge drops posts on one
    side of the edge only, so the two cells can give the shared posts
    different heights there.
    """
    import numpy as np

    name = f"{hgt_name(*cell)}.hgt"
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        members = archive.infolist()
        if [member.filename for member in members] != [name] or members[0].file_size != POSTS * POSTS * 2:
            raise ValueError(f"not Sonny's tile of {hgt_name(*cell)}")
        raw = archive.read(name)
    array = np.frombuffer(raw, dtype=">i2").reshape(POSTS, POSTS).astype("float32")
    valid = array != NO_DATA
    read = {"invalidPixels": int((~valid).sum()), **drop_beyond(array, valid, SONNY_HEIGHTS, SONNY_REJECT_MARGIN)}
    array[~valid] = np.nan
    return array, read


def read_sonny_cell(source, cell, out):
    """The cell's posts from its zip, checked against the catalog, and what was read.

    The zip is the copy the build fetched from the bucket where there is one,
    and otherwise downloaded from Google Drive. Drive answers a file it will
    not serve, for one with too many recent downloads, with a page of its
    own; the size and SHA-256 catch it.
    """
    _, date, size, sha256 = source.tiles[cell]
    copy = None if source.files is None else source.files / source.mirror_file(cell)[0]
    if copy is not None and copy.is_file():
        url, data, via = str(copy), copy.read_bytes(), "mirror"
    else:
        url = source.tile_url(*cell)
        data, via = fetch(url)[0], "origin"
    found = hashlib.sha256(data).hexdigest()
    if len(data) != size or found != sha256:
        raise ValueError(f"{url} gave {len(data)} bytes with SHA-256 {found}, not the catalog's {size} bytes "
                         f"with SHA-256 {sha256}")
    heights, read = sonny_posts(data, cell)
    if read["rejectedPixels"]:
        low, high = read["rejectedHeights"]
        print(f"{hgt_name(*cell)}: dropped {read['rejectedPixels']} posts of Sonny's tile at and around heights "
              f"from {low:.0f} to {high:.0f} m, which are not ground", flush=True)
    return heights, {"sha256": found, "readBytes": size, "tileDate": date, "via": via, **read}


TERRAIN_READERS = {TERRAIN_ADAPTER: read_usgs_cell, MRDEM_ADAPTER: read_mrdem_cell, SONNY_ADAPTER: read_sonny_cell}


def terrain_deadline(sources):
    """Seconds a cell may take to read these sources: longer when it downloads a whole tile."""
    return TERRAIN_DEADLINE if any(source.origin_object is None for source in sources) else CELL_DEADLINE


PIN_FIELDS = ("source", "url", "bytes", "etag", "areaSha256", "rejects")


def build_terrain_cell(cell, chosen, out):
    """Write the cell's terrain tile: each source's posts inside its own area, the first source's where two give one.

    The receipt names, for each source, what it read (`sha256` is the
    downloaded tile's, or that of the pixels read from an object), how many
    of its pixels were dropped as not ground, how many of its posts lay
    outside its area and how many posts it gave the tile.
    """
    import numpy as np

    heights = np.full((POSTS, POSTS), np.nan, dtype="float32")
    parts = []
    for source in chosen[cell]:
        posts, part = TERRAIN_READERS[source.adapter](source, cell, out)
        outside = clip_to_area(posts, cell, load_area(source.area, source.area_sha256))
        gives = np.isfinite(posts) & ~np.isfinite(heights)
        heights[gives] = posts[gives]
        parts.append({**source.pin(cell), **part, "outsidePosts": outside, "posts": int(gives.sum())})
    return write_receipt(out, {
        "cell": hgt_name(*cell),
        "sources": parts,
        "bytes": sum(part["readBytes"] for part in parts),
        "outsidePosts": sum(part["outsidePosts"] for part in parts),
        "rejectedPixels": sum(part.get("rejectedPixels", 0) for part in parts),
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
    terrain: Terrain
    tiles: Path
    opened: Path
    opening: Opening
    band: int = BLEND_POSTS

    def method(self):
        return {"name": "terrain-over-opening", "terrain": self.terrain.ids(), "blendPosts": self.band,
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
        if other in hybrid.terrain.cells:
            receipt = current_terrain_receipt(hybrid.tiles, other, hybrid.terrain.cells)
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


def _say_hung(name, seconds, left):
    """Say that a cell has had no answer, with its worker's stack; every line begins with the cell's name.

    Twenty workers write to one log, so a stack without a name could be
    anyone's. The stack is taken into a file first and written with the
    notice in one piece.
    """
    with tempfile.TemporaryFile("w+") as dump:
        faulthandler.dump_traceback(file=dump, all_threads=True)
        dump.seek(0)
        stack = dump.read().splitlines()
    # This has said it; the watchdog that would write the stack without a name is called off.
    faulthandler.cancel_dump_traceback_later()
    lines = [f"no answer for {seconds:g} s in worker {os.getpid()}; unless it gets one within {left:g} s its worker "
             "ends, and the cells left are built again", *stack]
    sys.stderr.write("".join(f"{name}: {line}\n" for line in lines))
    sys.stderr.flush()


def _build(cell):
    # urlopen's timeout does not cover the name lookup. On 2026-11-24 two of the
    # planet's 26,475 cells blocked in it for good, with no socket open. With no
    # handler installed, SIGALRM ends the worker, which breaks the pool so
    # build_pending retries.
    #
    # A worker that ends this way says nothing, so shortly before the deadline
    # the cell names itself and writes its worker's stack: on 2026-11-27 a
    # cell of the MRDEM-30 stage got no answer about once in a round, and no
    # log said where. That needs the interpreter, which a thread blocked in
    # some C calls keeps to itself. So a watchdog that needs nothing from the
    # worker's threads writes the stack a little later, without a name, unless
    # the notice was given. A cell is never lost to these two: without a
    # standard error to write to, the watchdog is left out.
    stage = _WORKER.get("stage")
    deadline = terrain_deadline(_WORKER["chosen"].get(cell, ())) if stage == TERRAIN else CELL_DEADLINE
    notice = threading.Timer(deadline - HANG_NOTICE, _say_hung, (hgt_name(*cell), deadline - HANG_NOTICE, HANG_NOTICE))
    notice.daemon = True
    try:
        notice.start()
        try:
            faulthandler.dump_traceback_later(deadline - HANG_NOTICE / 2, exit=False)
        except (AttributeError, OSError, RuntimeError, ValueError):
            pass
        signal.alarm(deadline)
        if isinstance(stage, Hybrid):
            return hybrid_cell(cell, _WORKER["chosen"], _WORKER["out"], stage)
        if stage == TERRAIN:
            return build_terrain_cell(cell, _WORKER["chosen"], _WORKER["out"])
        if _WORKER.get("opening") is not None:
            return open_cell(cell, _WORKER["chosen"], _WORKER["out"], _WORKER["opening"])
        return build_cell(cell, _WORKER["chosen"], _WORKER["out"])
    finally:
        signal.alarm(0)
        faulthandler.cancel_dump_traceback_later()
        notice.cancel()


class CellsFailed(RuntimeError):
    """Cells of a run failed. Every other cell of the run was still built."""


def run_pool(pending, chosen, out, jobs, opening=None, stage=None):
    """Build the cells in worker processes; every cell gets its turn, and the failed ones are named together.

    A pool works through every queued cell whatever one of them does. So a
    cell's error is noted and the run goes on, and at the end all failed
    cells are reported at once: a second run does not stop at the next of
    them. A worker that dies breaks the pool and is raised as it is, for
    build_pending to start another round.
    """
    started = time.monotonic()
    failed = []
    with ProcessPoolExecutor(jobs, initializer=_start_worker, initargs=(chosen, out, opening, stage)) as pool:
        futures = {pool.submit(_build, cell): cell for cell in pending}
        for done, future in enumerate(as_completed(futures), 1):
            try:
                future.result()
            except BrokenProcessPool:
                raise
            except Exception as error:  # noqa: BLE001 - whatever a cell raises, the others still run
                name = hgt_name(*futures[future])
                if not failed and error.__cause__ is not None:
                    # The worker's own traceback, once.
                    print(error.__cause__, flush=True)
                failed.append(name)
                print(f"{name} failed: {type(error).__name__}: {error}", flush=True)
            if done % 100 == 0 or done == len(futures):
                rate = done / max(time.monotonic() - started, 1)
                print(f"{done}/{len(futures)} cells, {rate:.2f}/s" + (f", {len(failed)} failed" if failed else ""),
                      flush=True)
    if failed:
        raise CellsFailed(f"{len(failed)} of {len(pending)} cells failed: {' '.join(sorted(failed))}")


def build_pending(cells, chosen, out, jobs, rounds=ROUNDS, opening=None, stage=None):
    """Build, open or blend the cells without a current receipt, again after a worker dies.

    `stage` is TERRAIN for the terrain tiles, where `chosen` maps each cell to
    the terrain sources with a tile for it, or a Hybrid for the final blend.
    """
    if isinstance(stage, Hybrid):
        current, verb = functools.partial(current_hybrid_receipt, hybrid=stage), "blend"
    elif stage == TERRAIN:
        current, verb = current_terrain_receipt, "build"
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


def current_terrain_receipt(out, cell, chosen):
    """The terrain tile's receipt if its sources are the cell's now, each as pinned and cut to its area now."""
    path = out / "receipts" / f"{hgt_name(*cell)}.json"
    if not path.exists():
        return None
    receipt = json.loads(path.read_text())
    parts = receipt.get("sources")
    if not isinstance(parts, list) or not all(isinstance(part, dict) for part in parts):
        return None
    if [{field: part.get(field) for field in PIN_FIELDS} for part in parts] != [s.pin(cell) for s in chosen[cell]]:
        return None
    return receipt


def terrain_shares(terrain, receipts):
    """Each source's identity with the tiles it gave posts to and those posts, from terrain tile receipts."""
    shares = []
    for source in terrain.sources:
        parts = [part for receipt in receipts for part in receipt["sources"] if part["source"] == source.id]
        shares.append({**source.identity(), "cells": sum(1 for part in parts if part["posts"]),
                       "posts": sum(part["posts"] for part in parts),
                       "rejectedPixels": sum(part.get("rejectedPixels", 0) for part in parts)})
    return shares


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
    """The terrain tiles' own manifest. Its schema keeps build_graph.py from taking them for a whole set.

    `terrain` holds every cell the sources list; `cells` are the ones this run built.
    """
    receipts = [current_terrain_receipt(out, cell, terrain.cells) for cell in cells]
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
        "sources": terrain_shares(terrain, receipts),
        "bounds": bounds,
        "catalogCells": len(terrain.cells),
        "cells": len(receipts),
        "cellListSha256": hashlib.sha256(listing.encode()).hexdigest(),
        "sourceBytes": sum(r["bytes"] for r in receipts),
        "fileBytes": sum(r["fileBytes"] for r in receipts),
        "noDataPosts": sum(r["noDataPosts"] for r in receipts),
        "outsidePosts": sum(r["outsidePosts"] for r in receipts),
        "rejectedPixels": sum(r.get("rejectedPixels", 0) for r in receipts),
    }
    (out / "cells.txt").write_text(listing)
    path = out / "terrain-manifest.json"
    path.write_text(json.dumps(manifest, indent=2) + "\n")
    return path


def write_manifest(out, policy_path, policy, chosen, cells, bounds=None, opening=None, hybrid=None):
    """`bounds` and `catalogCells` tell a partial run from a complete one.

    `method` is null for raw tiles. Opened tiles record the opening and the
    raw manifest they were opened from. Hybrid tiles record the blend, the
    opened and terrain manifests they read and the terrain sources: each
    with the terrain tiles of these cells it gave posts to, and `terrain`
    with the posts the blend took from terrain tiles and the fill posts it
    lifted. A cell without a terrain tile still takes the border posts it
    shares with one that has.
    """
    import rasterio

    terrain_sources, blend = [], {}
    if hybrid is not None:
        receipts = [current_hybrid_receipt(out, cell, chosen, hybrid) for cell in cells]
        method = {**hybrid.method(), "inputs": {
            "opened": manifest_identity(hybrid.opened),
            "terrain": manifest_identity(hybrid.tiles, "terrain-manifest.json")}}
        if all(receipts):
            tiles = [current_terrain_receipt(hybrid.tiles, cell, hybrid.terrain.cells)
                     for cell in cells if cell in hybrid.terrain.cells]
            if not all(tiles):
                raise ValueError("a cell has no receipt for its current terrain tile")
            terrain_sources = terrain_shares(hybrid.terrain, tiles)
            blend = {"terrain": {"cells": sum(1 for r in receipts if r["terrainPosts"]),
                                 "posts": sum(r["terrainPosts"] for r in receipts),
                                 "blendedPosts": sum(r["blendedPosts"] for r in receipts)}}
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
        **blend,
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
                        help="elevation-sources.json: put its terrain sources over the opened tiles")
    parser.add_argument("--terrain", type=Path, help="The terrain tiles for --terrain-sources")
    parser.add_argument("--opened", type=Path, help="The opened tiles when --terrain-sources makes --out the hybrid")
    parser.add_argument("--terrain-files", type=Path, metavar="DIR",
                        help="Copies of terrain sources' files, fetched from their mirror by elevation_cache.py, "
                             "under DIR/SOURCE-ID/; a source reads its own origin for a file that is not there")
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
    if args.terrain_files is not None and args.terrain_sources is None:
        parser.error("--terrain-files needs --terrain-sources")
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
        sources = load_terrain_sources(args.terrain_sources) if args.terrain_sources else None
    except (OSError, ValueError) as error:
        parser.error(f"--terrain-sources: {error}")
    if args.terrain_files is not None:
        files = args.terrain_files.resolve()
        sources = tuple(replace(source, files=files / source.id) for source in sources)
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
        if sources is not None:
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
    if sources is not None:
        print(f"Opened elevation manifest: {manifest}", flush=True)
        for source in sources:
            outside = sorted(hgt_name(*cell) for cell in source.tiles if cell not in chosen)
            if outside:
                print(f"{len(outside)} cells of {source.id} have no Copernicus cell and are left out: "
                      f"{' '.join(outside)}", flush=True)
        listed = Terrain.over(sources, sorted(chosen))
        # A bounded run builds only the terrain tiles around its cells, which is all its blends read.
        terrain = Terrain.over(sources, opened_cells)
        tiles = separate["--terrain"]
        (tiles / "receipts").mkdir(parents=True, exist_ok=True)
        terrain_cells = sorted(terrain.cells)
        build_pending(terrain_cells, terrain.cells, tiles, args.jobs, stage=TERRAIN)
        manifest = write_terrain_manifest(tiles, args.terrain_sources, listed, terrain_cells, opened_bounds)
        print(f"Terrain manifest: {manifest}", flush=True)
        hybrid = Hybrid(terrain, tiles, opened, opening)
        (out / "receipts").mkdir(parents=True, exist_ok=True)
        build_pending(cells, chosen, out, args.jobs, stage=hybrid)
        manifest = write_manifest(out, args.policy, policy, chosen, cells, args.bounds, opening, hybrid)
    print(f"Elevation manifest: {manifest}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
