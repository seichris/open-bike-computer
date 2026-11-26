#!/usr/bin/env python3
"""Pin the area and the USGS 3DEP 1/3 arc-second tiles a routing elevation build may use.

3DEP is the lidar terrain model that elevation-sources.json approves for
routing, for the conterminous United States. The city samples of 2026-11-26
tested it there; Alaska's tiles come from radar, and Hawaii and the
territories use other height datums.

`area` writes that area as a gzipped GeoJSON polygon. The newest 3DEP tiles
hold no data beyond the border, but older ones carry fill for Mexico and
Canada from other sources (the 2013 tile of cell N30W107 lies wholly in
Chihuahua and has a height at every post), so build_elevation.py drops every
post outside the area. The polygon is OpenStreetMap's boundary of the United
States, relation 148838, which follows the surveyed border and takes in the
territorial sea:

    curl -o us.osm https://api.openstreetmap.org/api/0.6/relation/148838/full
    osmium export us.osm --geometry-types=polygon -o us.geojson
    python terrain_catalog.py area --osm-geojson us.geojson \\
        --source "OpenStreetMap relation 148838 version 1054, 2026-11-11, ODbL" \\
        --out united-states-conterminous-osm-r148838-v1054.geojson.gz

`tiles` pins the tiles. The USGS replaces a tile whenever new lidar arrives
and keeps every dated version under `historical/`, so a build names dated
files. This lists that prefix of the public bucket and writes one line per
cell that touches the area, with the newest version of its tile:

    N40W074 n41w074 20260917 165776270 02fe0b7c39d43b570742e25e02c0462c

That is the HGT cell, the tile (named by its north-west corner), the version's
date, its size in bytes and its S3 ETag. build_elevation.py downloads exactly
those files and stops when a size or an ETag differs.

    python terrain_catalog.py tiles --area united-states-conterminous-osm-r148838-v1054.geojson.gz \\
        --out usgs-3dep-13-tiles-20261126.txt

Then record both files' names, sizes and SHA-256 and the tile count in
elevation-sources.json.
"""

import argparse
import gzip
import hashlib
import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

from build_elevation import STEP, TERRAIN_BUCKET, TERRAIN_PREFIX, format_terrain_catalog, hgt_name, load_area

KEY = re.compile(r"/([ns])(\d{2})([ew])(\d{3})/USGS_13_\1\2\3\4_(\d{8})\.tif$")
ENTRY = re.compile(r"<Contents>(.*?)</Contents>", re.DOTALL)
# North edges 25 to 50 and west edges 66 to 125: the conterminous United States.
CONTERMINOUS = (25, 50, 66, 125)
# What the country's polygon is cut to: west, south, east, north. It leaves Alaska, Hawaii and the territories out.
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


def area_feature(collection, name, source):
    """The country's polygon from an `osmium export`, cut to the conterminous box, as a GeoJSON feature."""
    from shapely.geometry import box, mapping, shape

    found = [feature for feature in collection.get("features", [])
             if feature["properties"].get("name") == name and feature["properties"].get("admin_level") == "2"
             and feature["geometry"]["type"] in ("Polygon", "MultiPolygon")]
    if len(found) != 1:
        raise ValueError(f"the export holds {len(found)} country polygons named {name!r}, not one")
    polygon = shape(found[0]["geometry"]).intersection(box(*CONTERMINOUS_BOX))
    if polygon.is_empty or not polygon.is_valid or polygon.geom_type not in ("Polygon", "MultiPolygon"):
        raise ValueError(f"{name!r} leaves no valid polygon inside {CONTERMINOUS_BOX}")
    return {"type": "Feature", "properties": {"name": name, "source": source, "box": list(CONTERMINOUS_BOX)},
            "geometry": mapping(polygon)}


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


def http_get(url):
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read().decode()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    area = commands.add_parser("area", help="Write the area the source is approved for")
    area.add_argument("--osm-geojson", required=True, type=Path, help="`osmium export` of the country's relation")
    area.add_argument("--name", default="United States", help="The country polygon's name in the export")
    area.add_argument("--source", required=True, help="Where the polygon comes from, recorded in the file")
    area.add_argument("--out", required=True, type=Path, help="A new .geojson.gz file")
    tiles = commands.add_parser("tiles", help="Pin the newest dated tile of every cell that touches the area")
    tiles.add_argument("--area", required=True, type=Path, help="The file `area` wrote")
    tiles.add_argument("--out", required=True, type=Path, help="A new catalog file")
    args = parser.parse_args()
    if args.command == "area":
        try:
            data = area_bytes(area_feature(json.loads(args.osm_geojson.read_text()), args.name, args.source))
        except ValueError as error:
            parser.error(str(error))
        with args.out.open("xb") as stream:
            stream.write(data)
        print(f"{args.out.name}: {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()}")
        return
    pinned = args.area.resolve(strict=True)
    found = newest_tiles(list_bucket(http_get), area=load_area(pinned, hashlib.sha256(pinned.read_bytes()).hexdigest()))
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
