#!/usr/bin/env python3
"""Pin the USGS 3DEP 1/3 arc-second tiles a routing elevation build may read.

3DEP is the lidar terrain model that elevation-sources.json approves for
routing. The USGS replaces a tile whenever new lidar arrives and keeps every
dated version under `historical/`, so a build names dated files. This lists
that prefix of the public bucket and writes one line per tile, the newest
version of each:

    N40W074 n41w074 20260917 165776270 02fe0b7c39d43b570742e25e02c0462c

That is the HGT cell, the tile (named by its north-west corner), the version's
date, its size in bytes and its S3 ETag. build_elevation.py downloads exactly
those files and stops when a size or an ETag differs.

Only the conterminous United States is listed. The city samples of 2026-11-26
tested 3DEP there; Alaska's tiles come from radar, and Hawaii and the
territories use other height datums.

    python terrain_catalog.py --out usgs-3dep-13-tiles-20261126.txt

Then record the file's name, size, SHA-256 and tile count in
elevation-sources.json.
"""

import argparse
import hashlib
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

from build_elevation import TERRAIN_BUCKET, TERRAIN_PREFIX, format_terrain_catalog, hgt_name

KEY = re.compile(r"/([ns])(\d{2})([ew])(\d{3})/USGS_13_\1\2\3\4_(\d{8})\.tif$")
ENTRY = re.compile(r"<Contents>(.*?)</Contents>", re.DOTALL)
# North edges 25 to 50 and west edges 66 to 125: the conterminous United States.
CONTERMINOUS = (25, 50, 66, 125)


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


def newest_tiles(objects, selection=CONTERMINOUS):
    """{cell: (tile, date, bytes, ETag)} with the newest dated version of every selected tile."""
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
    parser.add_argument("--out", required=True, type=Path, help="A new catalog file")
    args = parser.parse_args()
    tiles = newest_tiles(list_bucket(http_get))
    if not tiles:
        parser.error("the bucket listed no tile")
    text = format_terrain_catalog(tiles)
    with args.out.open("x") as stream:
        stream.write(text)
    total = sum(size for _, _, size, _ in tiles.values())
    print(f"{args.out.name}: {len(tiles)} tiles, {total} source bytes, {len(text.encode())} bytes, "
          f"sha256 {hashlib.sha256(text.encode()).hexdigest()}")
    print(f"first {hgt_name(*min(tiles))}, newest version {max(date for _, date, _, _ in tiles.values())}")


if __name__ == "__main__":
    sys.exit(main())
