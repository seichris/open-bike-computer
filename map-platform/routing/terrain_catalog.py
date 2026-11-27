#!/usr/bin/env python3
"""Pin the areas, tiles and cells the terrain sources of a routing elevation build may use.

elevation-sources.json approves two bare-earth sources for routing, each for
its own country. The USGS 3DEP 1/3 arc-second tiles are the lidar terrain
model of the conterminous United States; the city samples of 2026-11-26
tested it there, Alaska's tiles come from radar, and Hawaii and the
territories use other height datums. Natural Resources Canada's MRDEM-30 is
a terrain model of all Canada: lidar where Canada has it, and elsewhere
Copernicus GLO-30 with forests and settlements taken out.

`area` writes a country's area as a gzipped GeoJSON polygon.
build_elevation.py drops every post of a source outside its area: 3DEP's
newest tiles hold no data beyond the border, but older ones carry fill for
Mexico and Canada from other sources (the 2013 tile of cell N30W107 lies
wholly in Chihuahua and has a height at every post), and MRDEM-30 holds
heights beyond Canada's border. The polygons are OpenStreetMap's boundaries
of the two countries, relations 148838 and 1428125, which follow the
surveyed border and take in the territorial sea. They share the border's
ways, so no land lies in both or in neither:

    curl -o us.osm https://api.openstreetmap.org/api/0.6/relation/148838/full
    osmium export us.osm --geometry-types=polygon -o us.geojson
    python terrain_catalog.py area --osm-geojson us.geojson --box -126 23 -65 51 \\
        --source "OpenStreetMap relation 148838 version 1054, 2026-11-11, ODbL" \\
        --out united-states-conterminous-osm-r148838-v1054.geojson.gz

    curl -o canada.osm https://api.openstreetmap.org/api/0.6/relation/1428125/full
    osmium export canada.osm --geometry-types=polygon -o canada.geojson
    python terrain_catalog.py area --osm-geojson canada.geojson --name Canada \\
        --source "OpenStreetMap relation 1428125 version 649, 2026-11-01, ODbL" \\
        --out canada-osm-r1428125-v649.geojson.gz

`tiles` pins 3DEP's tiles. The USGS replaces a tile whenever new lidar
arrives and keeps every dated version under `historical/`, so a build names
dated files. This lists that prefix of the public bucket and writes one line
per cell that touches the area, with the newest version of its tile:

    N40W074 n41w074 20260917 165776270 02fe0b7c39d43b570742e25e02c0462c

That is the HGT cell, the tile (named by its north-west corner), the version's
date, its size in bytes and its S3 ETag. build_elevation.py downloads exactly
those files and stops when a size or an ETag differs.

    python terrain_catalog.py tiles --area united-states-conterminous-osm-r148838-v1054.geojson.gz \\
        --out usgs-3dep-13-tiles-20261126.txt

`cells` pins MRDEM-30's cells. MRDEM-30 is one object with no dated copies,
so its catalog names only the cells that touch the area, one per line, and
the source list pins the object's size and ETag, which this prints.
build_elevation.py stops when either differs.

    python terrain_catalog.py cells --area canada-osm-r1428125-v649.geojson.gz \\
        --out nrcan-mrdem-30-cells-20261127.txt

Sonny's LiDAR Digital Terrain Models of Europe are approved for the
countries they build wholly from national lidar or photogrammetry, and for
mainland Portugal outside a patch that holds SRTM. `srtm-fill` finds such a
patch: it compares Sonny's tiles post by post with SRTM's 1 arc-second tiles
(the Tilezen copy on AWS, `skadi/N41/N41W009.hgt.gz`) and returns the
stretches where nine posts in ten are exactly SRTM's, holes filled and
widened by one block. Elsewhere about one post in six matches by chance.

    python terrain_catalog.py srtm-fill --sonny sonny-zips/ --srtm skadi/ --out srtm-fill-portugal.geojson

`countries` writes the union of several countries' areas from their
relations' `osmium export --attributes type,id`, each cut to a box where
`--cut` gives one, less the polygons of `--without`. `sonny-tiles` lists the
Europe folder on Google Drive, downloads the tile of every cell that touches
the area, and writes one line per cell with the file's id (and, for a file
made before 2021, its resource key), date, size and SHA-256:

    python terrain_catalog.py countries --country r16239.geojson=16239 ... \\
        --cut 295480=-10,36.5,-6,42.5 --without srtm-fill-portugal.geojson --box -32 27 45 82 \\
        --source "OpenStreetMap relations ..., ODbL" --out sonny-europe-....geojson.gz
    python terrain_catalog.py sonny-tiles --area sonny-europe-....geojson.gz --out sonny-dtm-europe-1s-v25-tiles-....txt

Then record the files' names, sizes and SHA-256, the tile or cell count and,
for MRDEM-30, the object's size, ETag and date in elevation-sources.json.

A source whose list entry names a `mirror` is read from that copy in the
elevation bucket first (builder/elevation_cache.py fetch-terrain). `mirror`
fills the copy, with gcloud signed in as someone who may write to the bucket:
it downloads each file of the catalog the copy lacks from the source's origin,
checks its size and SHA-256 against the catalog and uploads it under the
cell's name. It never replaces an object; one of another size stops it.

    python terrain_catalog.py mirror --source sonny-dtm-europe-1s-v25
"""

import argparse
import functools
import gzip
import hashlib
import io
import json
import math
import re
import subprocess
import sys
import urllib.parse
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from build_elevation import (
    CEDD_EPSG, CEDD_HEIGHTS, CEDD_PIXEL, CEDD_REJECT_MARGIN, KEPT_RULES, LINZ_EPSG, LINZ_GEOGRAPHIC_EPSG, LINZ_ORIGIN,
    MRDEM_URL, POSTS, SONNY_ORIGIN, STEP, TERRAIN_BUCKET, TERRAIN_PREFIX, cell_of, clip_to_area, drop_beyond,
    format_cell_catalog, format_kept_catalog, format_linz_catalog, format_sonny_catalog, format_terrain_catalog,
    hgt_name, hgt_path, linz_box, linz_url, load_area, load_terrain_sources, post_transform, sonny_posts, write_tile,
)

KEY = re.compile(r"/([ns])(\d{2})([ew])(\d{3})/USGS_13_\1\2\3\4_(\d{8})\.tif$")
ENTRY = re.compile(r"<Contents>(.*?)</Contents>", re.DOTALL)
# North edges 25 to 50 and west edges 66 to 125: the conterminous United States.
CONTERMINOUS = (25, 50, 66, 125)
# What the polygon of the United States is cut to: west, south, east, north. It leaves Alaska, Hawaii and the
# territories out.
CONTERMINOUS_BOX = (-126, 23, -65, 51)


def parse_listing(xml):
    """(key, bytes, ETag) of every object on one page of an S3 listing, and the next page's token."""
    objects = []
    for entry in ENTRY.findall(xml):
        fields = {name: re.search(rf"<{name}>([^<]*)</{name}>", entry) for name in ("Key", "Size", "ETag")}
        if not all(fields.values()):
            raise ValueError("an S3 listing entry lacks its key, size or ETag")
        objects.append((fields["Key"][1], int(fields["Size"][1]), fields["ETag"][1].replace("&quot;", "").strip('"')))
    token = re.search(r"<NextContinuationToken>([^<]+)</NextContinuationToken>", xml)
    if "<IsTruncated>true</IsTruncated>" in xml and token is None:
        raise ValueError("a truncated S3 listing names no next page")
    return objects, token[1] if token else None


def area_feature(collection, name, source, cut=None):
    """The country's polygon from an `osmium export` as a GeoJSON feature, cut to the box `cut` when one is given."""
    from shapely.geometry import box, mapping, shape

    found = [feature for feature in collection.get("features", [])
             if feature["properties"].get("name") == name and feature["properties"].get("admin_level") == "2"
             and feature["geometry"]["type"] in ("Polygon", "MultiPolygon")]
    if len(found) != 1:
        raise ValueError(f"the export holds {len(found)} country polygons named {name!r}, not one")
    polygon = shape(found[0]["geometry"])
    properties = {"name": name, "source": source}
    if cut is not None:
        polygon = polygon.intersection(box(*cut))
        properties["box"] = list(cut)
    if polygon.is_empty or not polygon.is_valid or polygon.geom_type not in ("Polygon", "MultiPolygon"):
        raise ValueError(f"{name!r} leaves no valid polygon" + (f" inside {tuple(cut)}" if cut is not None else ""))
    return {"type": "Feature", "properties": properties, "geometry": mapping(polygon)}


def relation_polygon(collection, relation):
    """The polygon `osmium export --attributes type,id` made of one relation."""
    from shapely.geometry import shape

    found = [feature for feature in collection.get("features", [])
             if feature["properties"].get("@type") == "relation" and feature["properties"].get("@id") == relation
             and feature["geometry"]["type"] in ("Polygon", "MultiPolygon")]
    if len(found) != 1:
        raise ValueError(f"the export holds {len(found)} polygons of relation {relation}, not one")
    return found[0]["properties"].get("name"), shape(found[0]["geometry"])


def countries_feature(polygons, source, cuts=None, without=(), cut=None):
    """The union of `polygons` ({relation: (name, polygon)}), each cut to its box of `cuts`, less `without`."""
    from shapely.geometry import box, mapping
    from shapely.ops import unary_union

    cuts = cuts or {}
    parts = [polygon.intersection(box(*cuts[relation])) if relation in cuts else polygon
             for relation, (_, polygon) in sorted(polygons.items())]
    polygon = unary_union(parts)
    for other in without:
        polygon = polygon.difference(other)
    properties = {"names": sorted(name for name, _ in polygons.values()), "relations": sorted(polygons),
                  "source": source, "cuts": {str(relation): list(value) for relation, value in sorted(cuts.items())}}
    if cut is not None:
        polygon = polygon.intersection(box(*cut))
        properties["box"] = list(cut)
    if polygon.is_empty or not polygon.is_valid or polygon.geom_type not in ("Polygon", "MultiPolygon"):
        raise ValueError("the countries leave no valid polygon")
    return {"type": "Feature", "properties": properties, "geometry": mapping(polygon)}


# Blocks of this many posts on a side are judged together; a block is SRTM where this share of its land posts is.
FILL_BLOCK = 10
FILL_SHARE = 0.9
# A patch of fewer blocks, about 70 km2, is taken for chance: flat ground and lake surfaces where two models agree
# on whole metres. Lake Annecy's surface matches over 275 blocks and the Guadalquivir's marshes over 54, while
# Portugal's patch is 112,812. Look at every patch found before using it.
FILL_MIN_BLOCKS = 1000


def hgt_posts(data):
    import numpy as np

    if len(data) != POSTS * POSTS * 2:
        raise ValueError("not an HGT file of 3601 x 3601 posts")
    return np.frombuffer(data, dtype=">i2").reshape(POSTS, POSTS)


def srtm_fill_blocks(sonny, srtm, cell):
    """Polygons of the blocks of a cell where Sonny's posts are SRTM's, nine in ten land posts exactly."""
    import numpy as np
    from affine import Affine
    from rasterio.features import shapes
    from shapely.geometry import shape

    sonny, srtm = sonny.astype("int32"), srtm.astype("int32")
    land = (sonny != 0) & (srtm != 0) & (sonny != -32768) & (srtm != -32768)
    equal = (sonny == srtm) & land
    side = (POSTS - 1) // FILL_BLOCK
    land_blocks = land[:-1, :-1].reshape(side, FILL_BLOCK, side, FILL_BLOCK).sum(axis=(1, 3))
    equal_blocks = equal[:-1, :-1].reshape(side, FILL_BLOCK, side, FILL_BLOCK).sum(axis=(1, 3))
    fill = ((land_blocks >= FILL_BLOCK * FILL_BLOCK // 5)
            & (equal_blocks >= FILL_SHARE * np.maximum(land_blocks, 1))).astype("uint8")
    longitude, latitude = cell
    transform = Affine(FILL_BLOCK * STEP, 0, longitude - STEP / 2, 0, -FILL_BLOCK * STEP, latitude + 1 + STEP / 2)
    return [shape(geometry) for geometry, value in shapes(fill, mask=fill.astype(bool), transform=transform)
            if value == 1]


def srtm_fill(blocks):
    """The patches of SRTM among the blocks: holes filled, widened by one block, chance blocks left out."""
    from shapely.geometry import Polygon
    from shapely.ops import unary_union

    merged = unary_union(blocks)
    parts = list(getattr(merged, "geoms", [merged])) if not merged.is_empty else []
    size = (FILL_BLOCK * STEP) ** 2
    kept = [Polygon(part.exterior) for part in parts if part.area > (FILL_MIN_BLOCKS - 0.5) * size]
    return unary_union(kept).buffer(FILL_BLOCK * STEP, join_style=2) if kept else None


def area_bytes(feature):
    """The feature as the file's bytes: the same polygon always gives the same file."""
    return gzip.compress(json.dumps(feature, separators=(",", ":"), sort_keys=True).encode(), 9, mtime=0)


def touches_area(cell, area):
    """Whether any post of the cell can lie in the area, as build_elevation.posts_in_area sees it."""
    from shapely.geometry import box

    longitude, latitude = cell
    return area[1].intersects(box(longitude - STEP / 2, latitude - STEP / 2,
                                  longitude + 1 + STEP / 2, latitude + 1 + STEP / 2))


def newest_tiles(objects, selection=CONTERMINOUS, area=None):
    """{cell: (tile, date, bytes, ETag)} with the newest dated version of every selected tile.

    With `area`, only the cells that touch it: a tile wholly outside would be dropped post by post.
    """
    south, north, east, west = selection
    tiles = {}
    for key, size, etag in objects:
        match = KEY.search(key)
        if match is None:
            continue
        hemisphere, top, side, left, date = match[1], int(match[2]), match[3], int(match[4]), match[5]
        if hemisphere != "n" or side != "w" or not (south <= top <= north and east <= left <= west):
            continue
        cell = (-left, top - 1)
        if cell not in tiles or date > tiles[cell][1]:
            tiles[cell] = (f"n{top:02d}w{left:03d}", date, size, etag)
    if area is not None:
        tiles = {cell: tile for cell, tile in tiles.items() if touches_area(cell, area)}
    return tiles


def area_cells(area):
    """Every one-degree cell with a post that can lie in the area."""
    west, south, east, north = area[0].bounds
    return [(x, y) for x in range(math.floor(west) - 1, math.floor(east) + 1)
            for y in range(math.floor(south) - 1, math.floor(north) + 1) if touches_area((x, y), area)]


def object_identity(url):
    """Size, ETag and date of the object at `url`."""
    with urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=120) as response:
        return (int(response.headers["Content-Length"]), response.headers.get("ETag", "").strip('"'),
                response.headers.get("Last-Modified", ""))


def list_bucket(fetch):
    objects, token = [], None
    while True:
        query = {"list-type": "2", "prefix": TERRAIN_PREFIX + "/", "max-keys": "1000"}
        if token:
            query["continuation-token"] = token
        page, token = parse_listing(fetch(f"{TERRAIN_BUCKET}/?{urllib.parse.urlencode(query)}"))
        objects += page
        if token is None:
            return objects


SONNY_FOLDER = ("https://drive.google.com/embeddedfolderview?id=0BxphPoRgwhnoWkRoTFhMbTM3RDA"
                "&resourcekey=0-wRe5bWl96pwvQ9tAfI9cQg")
FOLDER_ENTRY = re.compile(r'<div class="flip-entry" id="entry-([^"]+)".*?<a href="([^"]+)".*?'
                          r'<div class="flip-entry-title">([^<]+)</div>', re.DOTALL)


def sonny_listing(html):
    """{cell: Drive file} of the tiles a folder page lists; a file with a resource key is `id/key`."""
    found = {}
    for entry in FOLDER_ENTRY.finditer(html):
        name = re.fullmatch(r"([NS]\d{2}[EW]\d{3})\.zip", entry[3])
        if name is None:
            continue
        key = re.search(r"resourcekey=([A-Za-z0-9_-]+)", entry[2].replace("&amp;", "&"))
        cell = cell_of(name[1])
        # Drive allows two files of one name, such as a corrected tile beside the old one: pin neither.
        if cell in found:
            raise ValueError(f"the folder lists {name[1]}.zip twice")
        found[cell] = entry[1] + (f"/{key[1]}" if key else "")
    return found


def sonny_tile(cell, drive_file, fetch):
    """(Drive file, date, bytes, SHA-256) of a cell's tile and what its posts are, from one download."""
    from email.utils import parsedate_to_datetime

    file_id, _, key = drive_file.partition("/")
    url = f"{SONNY_ORIGIN}?id={file_id}&export=download&confirm=t" + (f"&resourcekey={key}" if key else "")
    data, modified = fetch(url)
    _, read = sonny_posts(data, cell)
    date = parsedate_to_datetime(modified).strftime("%Y%m%d")
    return (drive_file, date, len(data), hashlib.sha256(data).hexdigest()), read


def http_download(url):
    """A file's bytes and Last-Modified header."""
    with urllib.request.urlopen(url, timeout=300) as response:
        data = response.read()
        if len(data) != int(response.headers["Content-Length"]):
            raise OSError(f"short read of {url}")
        return data, response.headers["Last-Modified"]


VERSION_ENTRY = re.compile(r"<Version>(.*?)</Version>", re.DOTALL)


def parse_versions(xml):
    """(key, version, bytes, ETag) of the latest version of every object on a page of an S3 version listing."""
    found = []
    for entry in VERSION_ENTRY.findall(xml):
        fields = {name: re.search(rf"<{name}>([^<]*)</{name}>", entry)
                  for name in ("Key", "VersionId", "IsLatest", "Size", "ETag")}
        if not all(fields.values()):
            raise ValueError("an S3 version listing entry lacks its key, version, size or ETag")
        if fields["IsLatest"][1] == "true":
            found.append((fields["Key"][1], fields["VersionId"][1], int(fields["Size"][1]),
                          fields["ETag"][1].replace("&quot;", "").strip('"')))
    key = re.search(r"<NextKeyMarker>([^<]+)</NextKeyMarker>", xml)
    version = re.search(r"<NextVersionIdMarker>([^<]+)</NextVersionIdMarker>", xml)
    if "<IsTruncated>true</IsTruncated>" in xml and key is None:
        raise ValueError("a truncated S3 version listing names no next page")
    return found, (key[1], version[1] if version else "") if key else None


def linz_cells(bounds, area):
    """The cells whose box of 8 m pixels meets the sheet's bounds and that touch the area."""
    from rasterio.crs import CRS
    from rasterio.warp import transform_bounds

    west, south, east, north = transform_bounds(CRS.from_epsg(LINZ_EPSG), CRS.from_epsg(LINZ_GEOGRAPHIC_EPSG),
                                                *bounds, densify_pts=256)
    cells = []
    for x in range(math.floor(west) - 1, math.floor(east) + 1):
        for y in range(math.floor(south) - 1, math.floor(north) + 1):
            left, bottom, right, top = linz_box((x, y))
            if left < bounds[2] and right > bounds[0] and bottom < bounds[3] and top > bounds[1] \
                    and touches_area((x, y), area):
                cells.append((x, y))
    return cells


def http_get(url):
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read().decode()


def mirror_files(source, held, read, upload, jobs=6):
    """Copy each file of the source's catalog that its bucket copy lacks; {name: "held" or "copied"}.

    `held` maps the names the copy holds to their sizes and `read(cell,
    name)` gives a file's bytes. A kept source's provenance files go beside
    its tiles. A file is uploaded only with the size and SHA-256 the catalog
    pins (a provenance file's SHA-256 alone).
    """
    wanted = {}
    for cell in sorted(source.tiles):
        name, size, sha256 = source.mirror_file(cell)
        wanted[name] = (cell, size, sha256)
        if source.adapter in KEPT_RULES:
            name, sha256 = source.provenance_file(cell)
            wanted[name] = (cell, None, sha256)
    for name, (_, size, _) in wanted.items():
        if name in held and size is not None and held[name] != size:
            raise ValueError(f"{source.mirror}{name} holds {held[name]} bytes, not the catalog's {size}")

    def copy(name):
        if name in held:
            return "held"
        cell, size, sha256 = wanted[name]
        data = read(cell, name)
        found = hashlib.sha256(data).hexdigest()
        if (size is not None and len(data) != size) or found != sha256:
            raise ValueError(f"{name} is not the catalog's: {len(data)} bytes with SHA-256 {found}, the catalog pins "
                             f"{size or 'any size'} with SHA-256 {sha256}")
        upload(data, f"{source.mirror}{name}")
        return "copied"

    with ThreadPoolExecutor(jobs) as pool:
        return dict(zip(wanted, pool.map(copy, wanted)))


def cedd_zip_pixels(data, name):
    """The CEDD_PIXEL means of one CEDD zip's 0.5 m GeoTIFF and the HK1980 Grid corner (west, north) they start at.

    A 5 m pixel is the mean of the 0.5 m pixels in it that have data, and
    has none where none of them has. The zip must hold one GeoTIFF on
    HK1980 Grid with 0.5 m pixels and whole 5 m blocks.
    """
    import numpy as np
    from rasterio.io import MemoryFile

    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        members = [member for member in archive.namelist() if member.lower().endswith((".tif", ".tiff"))]
        if len(members) != 1 or len(archive.namelist()) != 1:
            raise ValueError(f"{name} holds {archive.namelist()}, not one GeoTIFF")
        raster = archive.read(members[0])
    factor = round(CEDD_PIXEL / 0.5)
    with MemoryFile(raster) as memory, memory.open() as dataset:
        transform = dataset.transform
        # Some files place their corner a fraction of a micrometre off the grid.
        corner = (round(transform.c / CEDD_PIXEL) * CEDD_PIXEL, round(transform.f / CEDD_PIXEL) * CEDD_PIXEL)
        if (dataset.crs is None or dataset.crs.to_epsg() != CEDD_EPSG or dataset.count != 1
                or max(abs(value - wanted) for value, wanted in zip(
                    (transform.a, transform.b, transform.d, transform.e), (0.5, 0.0, 0.0, -0.5))) > 1e-9
                or dataset.width % factor or dataset.height % factor
                or abs(transform.c - corner[0]) > 0.001 or abs(transform.f - corner[1]) > 0.001):
            raise ValueError(f"{name} is not a 0.5 m GeoTIFF on HK1980 Grid in whole {CEDD_PIXEL:g} m blocks")
        # Files mark the pixels without data with -9999 or with 0; one that marks none would pass its fill as heights.
        if dataset.nodata is None:
            raise ValueError(f"{name} declares no value for pixels without data")
        pixels = dataset.read(1, masked=True).astype("float64")
    blocks = pixels.reshape(pixels.shape[0] // factor, factor, pixels.shape[1] // factor, factor)
    return np.asarray(blocks.mean(axis=(1, 3)).filled(np.nan), dtype="float32"), corner


def cedd_cells(entries, area, out, fetch, jobs=8, log=functools.partial(print, flush=True)):
    """Write Hong Kong's kept tiles from CEDD's zips, `entries` being (name, URL) of each; the cells' records.

    Every zip is downloaded into memory, pinned and averaged to 5 m. The
    5 m pixels go into one mosaic on HK1980 Grid, the pixels that are not
    ground are dropped with their margin, and each cell of the area is
    resampled from it onto its posts and cut to the area. Beside each tile,
    `provenance/CELL.txt` names the zips whose pixels reach the cell, with
    their bytes and SHA-256, and `receipts/CELL.json` records the tile.
    """
    import numpy as np
    from affine import Affine
    from pyproj import Transformer
    from rasterio.crs import CRS
    from rasterio.warp import Resampling, reproject

    def one(entry):
        name, url = entry
        data = fetch(url)
        try:
            pixels, corner = cedd_zip_pixels(data, name)
        except (ValueError, zipfile.BadZipFile) as error:
            return str(error)
        return {"name": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}, pixels, corner

    read, refused = [], []
    with ThreadPoolExecutor(jobs) as pool:
        for index, found in enumerate(pool.map(one, entries), 1):
            (refused if isinstance(found, str) else read).append(found)
            if index % 250 == 0:
                log(f"{index} of {len(entries)} zips, {sum(pin['bytes'] for pin, _, _ in read)} bytes")
    # Every zip is read before any is refused, so that one run names them all.
    if refused:
        raise ValueError(f"{len(refused)} zips refused: {'; '.join(refused[:10])}")
    west = min(corner[0] for _, _, corner in read)
    north = max(corner[1] for _, _, corner in read)
    east = max(corner[0] + pixels.shape[1] * CEDD_PIXEL for _, pixels, corner in read)
    south = min(corner[1] - pixels.shape[0] * CEDD_PIXEL for _, pixels, corner in read)
    mosaic = np.full((round((north - south) / CEDD_PIXEL), round((east - west) / CEDD_PIXEL)), np.nan, dtype="float32")
    to_degrees = Transformer.from_crs(CEDD_EPSG, 4326, always_xy=True)
    for pin, pixels, (left, top) in read:
        row, column = round((north - top) / CEDD_PIXEL), round((left - west) / CEDD_PIXEL)
        window = mosaic[row:row + pixels.shape[0], column:column + pixels.shape[1]]
        has = np.isfinite(pixels)
        if np.isfinite(window[has]).any():
            raise ValueError(f"{pin['name']} overlaps another zip's pixels")
        window[has] = pixels[has]
        right, bottom = left + pixels.shape[1] * CEDD_PIXEL, top - pixels.shape[0] * CEDD_PIXEL
        corners = [to_degrees.transform(x, y) for x in (left, right) for y in (top, bottom)]
        pin["degrees"] = (min(x for x, _ in corners), min(y for _, y in corners),
                          max(x for x, _ in corners), max(y for _, y in corners))
    valid = np.isfinite(mosaic)
    dropped = drop_beyond(mosaic, valid, CEDD_HEIGHTS, CEDD_REJECT_MARGIN)
    mosaic[~valid] = np.nan
    log(json.dumps({"zips": len(read), "bytes": sum(pin["bytes"] for pin, _, _ in read), **dropped}))
    records = []
    out.mkdir(parents=True, exist_ok=True)
    for cell in sorted(area_cells(area), key=lambda cell: hgt_name(*cell)):
        longitude, latitude = cell
        # The zips whose pixels reach the posts of the cell or the resampling's margin.
        under = sorted((pin for pin, _, _ in read if pin["degrees"][0] <= longitude + 1.01
                        and pin["degrees"][2] >= longitude - 0.01 and pin["degrees"][1] <= latitude + 1.01
                        and pin["degrees"][3] >= latitude - 0.01), key=lambda pin: pin["name"])
        if not under:
            continue
        posts = np.full((POSTS, POSTS), np.nan, dtype="float32")
        reproject(mosaic, posts, src_transform=Affine(CEDD_PIXEL, 0, west, 0, -CEDD_PIXEL, north),
                  src_crs=CRS.from_epsg(CEDD_EPSG), src_nodata=float("nan"), dst_transform=post_transform(*cell),
                  dst_crs=CRS.from_epsg(4326), dst_nodata=float("nan"), init_dest_nodata=False,
                  resampling=Resampling.bilinear, num_threads=1)
        outside = clip_to_area(posts, cell, area)
        if not np.isfinite(posts).any():
            continue
        entry = write_tile(out, cell, posts)
        text = "".join(f"{pin['name']} {pin['bytes']} {pin['sha256']}\n" for pin in under)
        name = hgt_name(*cell)
        (out / "provenance").mkdir(parents=True, exist_ok=True)
        (out / "provenance" / f"{name}.txt").write_text(text)
        record = {"cell": name, "zips": len(under), "outsidePosts": outside, **entry, **dropped,
                  "fileSha256": hashlib.sha256(hgt_path(out, *cell).read_bytes()).hexdigest(),
                  "provenanceSha256": hashlib.sha256(text.encode()).hexdigest()}
        (out / "receipts").mkdir(exist_ok=True)
        (out / "receipts" / f"{name}.json").write_text(json.dumps(record, indent=1, sort_keys=True) + "\n")
        records.append(record)
    return records


def kept_catalog(cells, date):
    """The catalog of a directory of kept tiles, from the receipts their maker wrote."""
    tiles = {}
    for path in sorted((cells / "receipts").glob("*.json")):
        record = json.loads(path.read_text())
        if record.get("empty"):
            continue
        tiles[cell_of(record["cell"])] = (record["provenanceSha256"], date, record["fileBytes"], record["fileSha256"])
    return format_kept_catalog(tiles)


def gcloud_sizes(prefix):
    """{name: bytes} of the objects directly under a gs:// prefix."""
    listed = subprocess.run(["gcloud", "storage", "ls", "-l", prefix], capture_output=True, text=True)
    if listed.returncode != 0 and "matched no objects" not in listed.stderr:
        raise OSError(f"gcloud storage ls {prefix}: {listed.stderr.strip()}")
    sizes = {}
    for line in listed.stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2].startswith(prefix):
            sizes[parts[2][len(prefix):]] = int(parts[0])
    return sizes


def gcloud_upload(data, url):
    """Upload `data` to a gs:// URL that holds no object yet."""
    import tempfile

    with tempfile.NamedTemporaryFile() as handle:
        handle.write(data)
        handle.flush()
        subprocess.run(["gcloud", "storage", "cp", "--if-generation-match=0", "--quiet", handle.name, url],
                       check=True, capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    area = commands.add_parser("area", help="Write the area the source is approved for")
    area.add_argument("--osm-geojson", required=True, type=Path, help="`osmium export` of the country's relation")
    area.add_argument("--name", default="United States", help="The country polygon's name in the export")
    area.add_argument("--box", type=float, nargs=4, metavar=("WEST", "SOUTH", "EAST", "NORTH"),
                      help=f"Cut the polygon to this box; the conterminous United States is {CONTERMINOUS_BOX}")
    area.add_argument("--source", required=True, help="Where the polygon comes from, recorded in the file")
    area.add_argument("--out", required=True, type=Path, help="A new .geojson.gz file")
    tiles = commands.add_parser("tiles", help="Pin the newest dated 3DEP tile of every cell that touches the area")
    tiles.add_argument("--area", required=True, type=Path, help="The file `area` wrote")
    tiles.add_argument("--out", required=True, type=Path, help="A new catalog file")
    cells = commands.add_parser("cells", help="Pin the cells that touch the area, for a source of one object")
    cells.add_argument("--area", required=True, type=Path, help="The file `area` wrote")
    cells.add_argument("--origin", default=MRDEM_URL, help="The source's object, whose size and ETag are printed")
    cells.add_argument("--out", required=True, type=Path, help="A new catalog file")
    fill = commands.add_parser("srtm-fill", help="Find the patches of Sonny's tiles that are SRTM's posts")
    fill.add_argument("--sonny", required=True, type=Path, help="Sonny's zips, named as the cells")
    fill.add_argument("--srtm", required=True, type=Path, help="SRTM's 1 arc-second .hgt.gz tiles, named as the cells")
    fill.add_argument("--out", required=True, type=Path, help="A new GeoJSON file")
    union = commands.add_parser("countries", help="Write the area of several countries")
    union.add_argument("--country", required=True, action="append", metavar="EXPORT=RELATION",
                       help="`osmium export --attributes type,id` of a country's relation and the relation's id")
    union.add_argument("--cut", action="append", default=[], metavar="RELATION=W,S,E,N", help="Cut a country to a box")
    union.add_argument("--without", action="append", default=[], type=Path, help="A GeoJSON of polygons to leave out")
    union.add_argument("--box", type=float, nargs=4, metavar=("WEST", "SOUTH", "EAST", "NORTH"))
    union.add_argument("--source", required=True, help="Where the polygons come from, recorded in the file")
    union.add_argument("--out", required=True, type=Path, help="A new .geojson.gz file")
    polygon = commands.add_parser("polygon", help="Write an area from a publisher's GeoJSON polygon")
    polygon.add_argument("--geojson", required=True, type=Path, help="A GeoJSON Feature or FeatureCollection")
    polygon.add_argument("--source", required=True, help="Where the polygon comes from, recorded in the file")
    polygon.add_argument("--out", required=True, type=Path, help="A new .geojson.gz file")
    linz = commands.add_parser("linz-sheets", help="Pin the latest version of every LINZ sheet a cell of the area reads")
    linz.add_argument("--area", required=True, type=Path, help="The file `polygon` wrote")
    linz.add_argument("--out", required=True, type=Path, help="A new catalog file")
    sonny = commands.add_parser("sonny-tiles", help="Pin Sonny's tile of every cell that touches the area")
    sonny.add_argument("--area", required=True, type=Path, help="The file `countries` wrote")
    sonny.add_argument("--folder", default=SONNY_FOLDER, help="The Drive folder's embedded view")
    sonny.add_argument("--jobs", type=int, default=4)
    sonny.add_argument("--out", required=True, type=Path, help="A new catalog file")
    copy = commands.add_parser("mirror", help="Copy a source's pinned files to its copy in the elevation bucket")
    copy.add_argument("--sources", type=Path, default=Path(__file__).with_name("elevation-sources.json"))
    copy.add_argument("--source", required=True, help="The id of a source whose entry names a mirror")
    copy.add_argument("--jobs", type=int, default=6)
    copy.add_argument("--from", dest="made", type=Path,
                      help="For a kept source: the directory its maker, such as cedd-cells, wrote the tiles to")
    cedd = commands.add_parser("cedd-cells", help="Make Hong Kong's kept tiles from CEDD's 2020 lidar DTM zips")
    cedd.add_argument("--index", required=True, type=Path, help="CSDI's tile index of the DTM_2020 layer, GeoJSON")
    cedd.add_argument("--area", required=True, type=Path, help="The file `countries` wrote")
    cedd.add_argument("--jobs", type=int, default=8)
    cedd.add_argument("--out", required=True, type=Path, help="A new directory")
    kept = commands.add_parser("kept-catalog", help="Write the catalog of kept tiles from their maker's receipts")
    kept.add_argument("--cells", required=True, type=Path, help="The directory the maker wrote")
    kept.add_argument("--date", required=True, help="The day the tiles were made, YYYYMMDD")
    kept.add_argument("--out", required=True, type=Path, help="A new catalog file")
    args = parser.parse_args()
    if args.command == "mirror":
        found = [source for source in load_terrain_sources(args.sources) if source.id == args.source]
        if not found or found[0].mirror is None:
            parser.error(f"{args.sources.name} lists no source {args.source} with a mirror")
        source = found[0]
        if source.adapter in KEPT_RULES:
            if args.made is None:
                parser.error(f"{source.id} is made, not downloaded: name its maker's directory with --from")

            def read(cell, name):
                return (hgt_path(args.made, *cell) if name.endswith(".hgt.gz") else args.made / "provenance" / name
                        ).read_bytes()
        else:
            def read(cell, name):
                return http_download(source.tile_url(*cell))[0]
        done = mirror_files(source, gcloud_sizes(source.mirror), read, gcloud_upload, args.jobs)
        print(f"{found[0].mirror}: {sum(state == 'copied' for state in done.values())} copied, "
              f"{sum(state == 'held' for state in done.values())} held already")
        return
    if args.command == "kept-catalog":
        if re.fullmatch(r"\d{8}", args.date) is None:
            parser.error("--date must be YYYYMMDD")
        text = kept_catalog(args.cells, args.date)
        with args.out.open("x") as stream:
            stream.write(text)
        print(f"{args.out.name}: {len(text.splitlines())} tiles, {len(text.encode())} bytes, "
              f"sha256 {hashlib.sha256(text.encode()).hexdigest()}")
        return
    if args.command == "srtm-fill":
        blocks = []
        for path in sorted(args.sonny.glob("*.zip")):
            cell = cell_of(path.stem)
            srtm = args.srtm / f"{path.stem}.hgt.gz"
            if not srtm.exists():
                continue
            with zipfile.ZipFile(path) as archive:
                sonny_heights = hgt_posts(archive.read(f"{path.stem}.hgt"))
            blocks += srtm_fill_blocks(sonny_heights, hgt_posts(gzip.decompress(srtm.read_bytes())), cell)
        patches = srtm_fill(blocks)
        if patches is None:
            parser.error("no patch of SRTM found")
        from shapely.geometry import mapping
        with args.out.open("x") as stream:
            json.dump({"type": "Feature", "properties": {"block": FILL_BLOCK, "share": FILL_SHARE,
                                                         "minimumBlocks": FILL_MIN_BLOCKS},
                       "geometry": mapping(patches)}, stream)
        size = (FILL_BLOCK * STEP) ** 2
        for part in getattr(patches, "geoms", [patches]):
            print(f"patch of {part.area / size:.0f} blocks, bounds {[round(v, 4) for v in part.bounds]}")
        return
    if args.command == "countries":
        from shapely.geometry import shape
        polygons = {}
        for value in args.country:
            path, _, relation = value.rpartition("=")
            polygons[int(relation)] = relation_polygon(json.loads(Path(path).read_text()), int(relation))
        cuts = {int(relation): tuple(float(v) for v in bounds.split(","))
                for relation, _, bounds in (value.partition("=") for value in args.cut)}
        without = [shape(json.loads(path.read_text())["geometry"]) for path in args.without]
        try:
            data = area_bytes(countries_feature(polygons, args.source, cuts, without,
                                                None if args.box is None else tuple(args.box)))
        except ValueError as error:
            parser.error(str(error))
        with args.out.open("xb") as stream:
            stream.write(data)
        print(f"{args.out.name}: {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()}")
        return
    if args.command == "polygon":
        from shapely.geometry import mapping, shape
        from shapely.ops import unary_union
        document = json.loads(args.geojson.read_text())
        features = document["features"] if document.get("type") == "FeatureCollection" else [document]
        merged = unary_union([shape(feature["geometry"]) for feature in features])
        if merged.is_empty or not merged.is_valid or merged.geom_type not in ("Polygon", "MultiPolygon"):
            parser.error("the GeoJSON holds no valid polygon")
        data = area_bytes({"type": "Feature", "properties": {"source": args.source}, "geometry": mapping(merged)})
        with args.out.open("xb") as stream:
            stream.write(data)
        print(f"{args.out.name}: {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()}")
        return
    if args.command == "area":
        cut = None if args.box is None else tuple(int(value) if value.is_integer() else value for value in args.box)
        try:
            data = area_bytes(area_feature(json.loads(args.osm_geojson.read_text()), args.name, args.source, cut))
        except ValueError as error:
            parser.error(str(error))
        with args.out.open("xb") as stream:
            stream.write(data)
        print(f"{args.out.name}: {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()}")
        return
    pinned = args.area.resolve(strict=True)
    area = load_area(pinned, hashlib.sha256(pinned.read_bytes()).hexdigest())
    if args.command == "linz-sheets":
        import rasterio
        from build_elevation import GDAL_OPTIONS, LINZ_GDAL_OPTIONS
        bucket, _, prefix = LINZ_ORIGIN.partition(".amazonaws.com/")
        bucket += ".amazonaws.com"
        objects, marker = [], None
        while True:
            query = {"versions": "", "prefix": prefix + "/", "max-keys": "1000"}
            if marker:
                query.update({"key-marker": marker[0], "version-id-marker": marker[1]})
            page, marker = parse_versions(http_get(f"{bucket}/?{urllib.parse.urlencode(query)}"))
            objects += page
            if marker is None:
                break
        tiles = {}
        with rasterio.Env(**{**GDAL_OPTIONS, **LINZ_GDAL_OPTIONS}):
            for key, version, size, etag in sorted(objects):
                name = re.fullmatch(re.escape(prefix) + r"/([A-Z]{2}\d{2})\.tiff", key)
                if name is None:
                    continue
                with rasterio.open("/vsicurl/" + linz_url(LINZ_ORIGIN, name[1], version)) as dataset:
                    bounds = tuple(round(value) for value in dataset.bounds)
                for cell in linz_cells(bounds, area):
                    tiles.setdefault(cell, []).append((name[1], version, size, etag, bounds))
                print(f"{name[1]} {size} bytes {bounds}", flush=True)
        text = format_linz_catalog({cell: tuple(sorted(found)) for cell, found in tiles.items()})
        with args.out.open("x") as stream:
            stream.write(text)
        sheets = {sheet[0]: sheet for found in tiles.values() for sheet in found}
        print(f"{args.out.name}: {len(tiles)} cells, {len(sheets)} sheets, "
              f"{sum(sheet[2] for sheet in sheets.values())} source bytes, {len(text.encode())} bytes, "
              f"sha256 {hashlib.sha256(text.encode()).hexdigest()}")
        return
    if args.command == "cedd-cells":
        features = json.loads(args.index.read_text())["features"]
        entries = [(feature["properties"]["Filename"], feature["properties"]["URL"]) for feature in features]
        if len({name for name, _ in entries}) != len(entries):
            parser.error("the index names a zip twice")
        args.out.mkdir()
        for record in cedd_cells(entries, area, args.out, lambda url: http_download(
                urllib.parse.quote(url, safe=":/"))[0], args.jobs):
            print(json.dumps({key: value for key, value in record.items() if key != "hgtSha256"}), flush=True)
        return
    if args.command == "sonny-tiles":
        listed = sonny_listing(http_get(args.folder))
        wanted = {cell: drive_file for cell, drive_file in listed.items() if touches_area(cell, area)}
        tiles, rejected = {}, {}
        with ThreadPoolExecutor(args.jobs) as pool:
            for cell, (tile, read) in zip(wanted, pool.map(lambda item: sonny_tile(*item, http_download),
                                                           wanted.items())):
                tiles[cell] = tile
                if read["rejectedPixels"] or read["invalidPixels"]:
                    rejected[hgt_name(*cell)] = read
                print(f"{hgt_name(*cell)} {tile[2]} bytes", flush=True)
        text = format_sonny_catalog(tiles)
        with args.out.open("x") as stream:
            stream.write(text)
        print(f"{args.out.name}: {len(tiles)} tiles, {sum(t[2] for t in tiles.values())} source bytes, "
              f"{len(text.encode())} bytes, sha256 {hashlib.sha256(text.encode()).hexdigest()}")
        print(json.dumps({"tilesWithPostsDroppedOrMissing": rejected}, indent=1))
        return
    if args.command == "cells":
        text = format_cell_catalog(area_cells(area))
        with args.out.open("x") as stream:
            stream.write(text)
        print(f"{args.out.name}: {len(text.splitlines())} cells, {len(text.encode())} bytes, "
              f"sha256 {hashlib.sha256(text.encode()).hexdigest()}")
        size, etag, modified = object_identity(args.origin)
        print(f"{args.origin}: {size} bytes, ETag {etag}, last modified {modified}")
        return
    found = newest_tiles(list_bucket(http_get), area=area)
    if not found:
        parser.error("the bucket listed no tile that touches the area")
    text = format_terrain_catalog(found)
    with args.out.open("x") as stream:
        stream.write(text)
    total = sum(size for _, _, size, _ in found.values())
    print(f"{args.out.name}: {len(found)} tiles, {total} source bytes, {len(text.encode())} bytes, "
          f"sha256 {hashlib.sha256(text.encode()).hexdigest()}")
    print(f"first {hgt_name(*min(found))}, newest version {max(date for _, date, _, _ in found.values())}")


if __name__ == "__main__":
    sys.exit(main())
