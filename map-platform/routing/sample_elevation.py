#!/usr/bin/env python3
"""Write Valhalla HGT tiles from a candidate DEM, for development samples only.

Production elevation comes from build_elevation.py and the approved sources of
the topography source policy. This tool tries other sources on a few cells so
compare_elevation.py can judge them on regional sample graphs before anyone
asks to approve one:

- `cog` resamples one global Cloud Optimized GeoTIFF onto the HGT posts of the
  cells in --bounds. GEDTM30 v1.2 (OpenGeoHub, a bare-earth terrain model)
  is a single 432 GB COG whose pixel centres lie on whole arc-seconds, so
  its pixels land on the posts unchanged.
- `opening` takes tiles build_elevation.py wrote and applies a grey-scale
  morphological opening (an erosion, then a dilation, over an ellipse of
  --radius metres). That removes raised features narrower than the ellipse,
  such as buildings and rows of trees, and keeps terrain wider than it.
  It sizes the ellipse at the centre of --bounds and repeats the outermost
  posts beyond them. build_elevation.py --opening-radius is the production
  version: it sizes the ellipse for each post row and reads the neighbouring
  cells' posts instead. Away from the box's edges, and where the ellipse
  has the same width, both give the same posts.

Both write the same gzipped HGT layout and manifest schema as
build_elevation.py. The manifest always records `bounds`, so build_graph.py
accepts these tiles only for a `--sample` build.
"""

import argparse
import gzip
import hashlib
import json
import math
import os
import sys
import urllib.request
from pathlib import Path

from build_elevation import (
    GDAL_OPTIONS, MARGIN, METRES_PER_ARCSECOND, NO_DATA, POSTS, STEP, encode_posts, hgt_name, hgt_path,
    resample_into,
)

FORMAT = "srtm-hgt-1-arcsecond-int16-big-endian-gzip"


def cells_in(bounds):
    west, south, east, north = bounds
    if not (-180 <= west < east <= 180 and -90 <= south < north <= 90):
        raise ValueError("bounds must be whole degrees, west < east and south < north")
    return [(x, y) for y in range(south, north) for x in range(west, east)]


def post_transform(longitude, latitude):
    """Affine of the 3601 x 3601 posts of a cell, each post at a pixel centre."""
    from affine import Affine

    return Affine(STEP, 0, longitude - STEP / 2, 0, -STEP, latitude + 1 + STEP / 2)


def write_hgt(out, cell, heights):
    """Write one cell; returns the fields its manifest entry records."""
    payload, missing = encode_posts(heights)
    path = hgt_path(out, *cell)
    path.parent.mkdir(parents=True, exist_ok=True)
    compressed = gzip.compress(payload, compresslevel=1, mtime=0)
    temporary = path.with_name(path.name + ".partial")
    temporary.write_bytes(compressed)
    os.replace(temporary, path)
    return {"cell": hgt_name(*cell), "hgtSha256": hashlib.sha256(payload).hexdigest(),
            "fileBytes": len(compressed), "noDataPosts": missing}


def read_hgt(path):
    import numpy as np

    data = gzip.decompress(path.read_bytes()) if path.suffix == ".gz" else path.read_bytes()
    posts = np.frombuffer(data, dtype=">i2").reshape(POSTS, POSTS).astype("float32")
    posts[posts == NO_DATA] = np.nan
    return posts


def cog_window(dataset, longitude, latitude):
    """The COG's pixels around one cell, invalid ones as NaN."""
    import numpy as np
    from rasterio.windows import Window, from_bounds

    wanted = from_bounds(longitude - MARGIN, latitude - MARGIN, longitude + 1 + MARGIN,
                         latitude + 1 + MARGIN, dataset.transform)
    column, row = max(math.floor(wanted.col_off), 0), max(math.floor(wanted.row_off), 0)
    end_column = min(math.ceil(wanted.col_off + wanted.width), dataset.width)
    end_row = min(math.ceil(wanted.row_off + wanted.height), dataset.height)
    if end_column <= column or end_row <= row:
        return None, None
    window = Window(column, row, end_column - column, end_row - row)
    array = dataset.read(1, window=window).astype("float32")
    valid = (dataset.read_masks(1, window=window) != 0) & np.isfinite(array)
    if np.any(valid & ((array < -12000) | (array > 10000))):
        raise ValueError("valid DEM elevations exceed Earth profile bounds")
    array[~valid] = np.nan
    return array, dataset.window_transform(window)


def cog_cell(dataset, cell):
    import numpy as np

    heights = np.full((POSTS, POSTS), np.nan, dtype="float32")
    array, transform = cog_window(dataset, *cell)
    if array is not None:
        resample_into(heights, post_transform(*cell), array, transform, 0)
    return heights


def cog_identity(url):
    """The size, ETag and date that pin the COG's version."""
    request = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(request, timeout=60) as response:
        headers = response.headers
        return {"url": url, "bytes": int(headers["Content-Length"]),
                "etag": headers.get("ETag", "").strip('"'), "lastModified": headers.get("Last-Modified")}


def footprint(radius_metres, latitude):
    """Ellipse of `radius_metres` in posts: one arc-second of longitude shrinks with latitude."""
    import numpy as np

    rows = max(1, round(radius_metres / METRES_PER_ARCSECOND))
    columns = max(1, round(radius_metres / (METRES_PER_ARCSECOND * math.cos(math.radians(latitude)))))
    y, x = np.ogrid[-rows:rows + 1, -columns:columns + 1]
    return (y / rows) ** 2 + (x / columns) ** 2 <= 1


def rank_filter(array, mask, reduce):
    """Minimum or maximum over the footprint `mask`, edges repeated outward."""
    import numpy as np

    rows, columns = mask.shape[0] // 2, mask.shape[1] // 2
    padded = np.pad(array, ((rows, rows), (columns, columns)), mode="edge")
    height, width = array.shape
    result = None
    for dy, dx in zip(*np.nonzero(mask)):
        window = padded[dy:dy + height, dx:dx + width]
        result = window.copy() if result is None else reduce(result, window, out=result)
    return result


def open_heights(heights, radius_metres, latitude):
    """Grey-scale opening; no-data posts stay no data and never win the minimum."""
    import numpy as np

    missing = ~np.isfinite(heights)
    if missing.all():
        return heights.copy()
    filled = np.where(missing, np.nanmax(heights), heights).astype("float32")
    mask = footprint(radius_metres, latitude)
    opened = rank_filter(rank_filter(filled, mask, np.minimum), mask, np.maximum)
    opened[missing] = np.nan
    return opened


def mosaic(cells, load):
    """One array over all cells; neighbouring cells share their border posts."""
    import numpy as np

    west, south = min(x for x, _ in cells), min(y for _, y in cells)
    east, north = max(x for x, _ in cells) + 1, max(y for _, y in cells) + 1
    side = POSTS - 1
    array = np.full(((north - south) * side + 1, (east - west) * side + 1), np.nan, dtype="float32")
    for x, y in cells:
        row, column = (north - 1 - y) * side, (x - west) * side
        array[row:row + POSTS, column:column + POSTS] = load((x, y))
    return array, west, north


def cut(array, west, north, cell):
    side = POSTS - 1
    row, column = (north - 1 - cell[1]) * side, (cell[0] - west) * side
    return array[row:row + POSTS, column:column + POSTS]


def write_manifest(out, method, sources, entries, bounds):
    listing = "".join(f"{e['cell']} {e['hgtSha256']}\n" for e in sorted(entries, key=lambda e: e["cell"]))
    manifest = {
        "schema": "bicino-valhalla-elevation-v1",
        "format": FORMAT,
        "posts": POSTS,
        "noData": NO_DATA,
        "developmentSample": True,
        "method": method,
        "sources": [{**source, "cells": len(entries)} for source in sources],
        "bounds": list(bounds),
        "catalogCells": None,
        "cells": len(entries),
        "cellListSha256": hashlib.sha256(listing.encode()).hexdigest(),
        "fileBytes": sum(e["fileBytes"] for e in entries),
        "noDataPosts": sum(e["noDataPosts"] for e in entries),
        "cellFiles": sorted(entries, key=lambda e: e["cell"]),
    }
    (out / "cells.txt").write_text(listing)
    path = out / "elevation-manifest.json"
    path.write_text(json.dumps(manifest, indent=2) + "\n")
    return path


def run_cog(args, out):
    import rasterio

    identity = cog_identity(args.url)
    entries = []
    with rasterio.Env(**GDAL_OPTIONS), rasterio.open("/vsicurl/" + args.url) as dataset:
        for cell in cells_in(args.bounds):
            entries.append(write_hgt(out, cell, cog_cell(dataset, cell)))
            print(f"{entries[-1]['cell']}: {entries[-1]['noDataPosts']} no-data posts", flush=True)
    source = {"id": args.source_id, **identity}
    return write_manifest(out, {"name": "cog", "resampling": "bilinear"}, [source], entries, args.bounds)


def run_opening(args, out):
    source_dir = args.input.resolve(strict=True)
    source_manifest = json.loads((source_dir / "elevation-manifest.json").read_text())
    if source_manifest.get("schema") != "bicino-valhalla-elevation-v1":
        raise ValueError("--input is not an elevation directory")
    cells = cells_in(args.bounds)
    present = [cell for cell in cells if hgt_path(source_dir, *cell).exists()]
    if not present:
        raise ValueError("--input has no cell inside --bounds")
    array, west, north = mosaic(present, lambda cell: read_hgt(hgt_path(source_dir, *cell)))
    latitude = (args.bounds[1] + args.bounds[3]) / 2
    opened = open_heights(array, args.radius, latitude)
    entries = [write_hgt(out, cell, cut(opened, west, north, cell)) for cell in present]
    source = {"id": f"opening-of-{'+'.join(s['id'] for s in source_manifest['sources'] if s.get('cells'))}",
              "input": {"manifestSha256": hashlib.sha256(
                  (source_dir / "elevation-manifest.json").read_bytes()).hexdigest(),
                  "cellListSha256": source_manifest["cellListSha256"]}}
    method = {"name": "grey-opening", "radiusMetres": args.radius, "footprint": "ellipse",
              "referenceLatitude": latitude}
    return write_manifest(out, method, [source], entries, args.bounds)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    cog = commands.add_parser("cog", help="Resample a global COG onto HGT posts")
    cog.add_argument("--url", required=True, help="HTTPS URL of the COG")
    cog.add_argument("--source-id", required=True, help="Name recorded in the manifest, e.g. gedtm30-v1.2")
    opening = commands.add_parser("opening", help="Open build_elevation.py tiles")
    opening.add_argument("--input", required=True, type=Path, help="Tiles written by build_elevation.py")
    opening.add_argument("--radius", required=True, type=float, help="Ellipse radius in metres")
    for command in (cog, opening):
        command.add_argument("--out", required=True, type=Path, help="A new directory")
        command.add_argument("--bounds", required=True, type=int, nargs=4,
                             metavar=("WEST", "SOUTH", "EAST", "NORTH"))
    args = parser.parse_args()
    if len(cells_in(args.bounds)) > 16:
        parser.error("Samples are limited to 16 cells")
    if args.command == "cog" and not args.url.startswith("https://"):
        parser.error("--url must be HTTPS")
    if args.command == "opening" and not 15 <= args.radius <= 1000:
        parser.error("--radius must be between 15 and 1000 metres")
    out = args.out.resolve()
    out.mkdir(parents=True)
    path = run_cog(args, out) if args.command == "cog" else run_opening(args, out)
    print(f"Elevation manifest: {path}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
