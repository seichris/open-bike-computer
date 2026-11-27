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
"""

import argparse
import gzip
import hashlib
import json
import math
import re
import sys
import urllib.parse
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from build_elevation import (
    MRDEM_URL, POSTS, SONNY_ORIGIN, STEP, TERRAIN_BUCKET, TERRAIN_PREFIX, cell_of, format_cell_catalog,
    format_sonny_catalog, format_terrain_catalog, hgt_name, load_area, sonny_posts,
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
        found[cell_of(name[1])] = entry[1] + (f"/{key[1]}" if key else "")
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


def http_get(url):
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read().decode()


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
    sonny = commands.add_parser("sonny-tiles", help="Pin Sonny's tile of every cell that touches the area")
    sonny.add_argument("--area", required=True, type=Path, help="The file `countries` wrote")
    sonny.add_argument("--folder", default=SONNY_FOLDER, help="The Drive folder's embedded view")
    sonny.add_argument("--jobs", type=int, default=4)
    sonny.add_argument("--out", required=True, type=Path, help="A new catalog file")
    args = parser.parse_args()
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
