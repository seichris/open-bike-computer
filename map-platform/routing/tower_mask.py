#!/usr/bin/env python3
"""Write no data into elevation tiles where tall buildings dominate, for development samples only.

Copernicus measures roofs, and the opening of build_elevation.py removes only
what is narrower than its ellipse. Among towers no post within the ellipse
reaches the street, so the opened tiles keep the towers as a plateau and
Valhalla grades the streets across its edge as hills. A wider ellipse reaches
more streets but flattens real hills too.

This step leaves the radius alone and switches elevation off inside tower
zones instead. Valhalla samples an edge every 60 m and gives a section with a
no-data end the grade 0, so a street there is graded as the graph without
elevation grades it. Checked on the pinned image on 2026-11-27 (see the
refresh runbook): edges inside a no-data area read flat, edges outside are
unchanged and a street across the boundary reads no cliff. A bridge, tunnel or
ferry is graded from its two ends, and with one end in the area it reads 3%.

Tower zones come from a grid of building heights, not from the elevation:
GHS-BUILT-H R2023A of the European Commission's Joint Research Centre, the
average net building height (ANBH) of 2018 on a 3 arc-second grid in WGS 84
(CC BY 4.0, (c) European Union; credit the GHSL and say that it was changed).
The rule, per post:

1. the post's building height is that of the grid cell it lies in, 0 where
   the grid has none;
2. the mean of those heights over an ellipse of `--smooth` metres is at
   least `--threshold` metres: tall buildings dominate there, where one
   tower among low roofs does not;
3. every post within `--margin` metres of such a post is masked too, which
   covers the slope the plateau's edge left in the opened tiles.

The ellipses are sized per post row, as the opening's are, and each cell is
judged with a margin of the grid around it, so the two tiles that share a
border post give it the same answer.

    python tower_mask.py --input "$scratch/dem/new-york/open-200" --bounds -75 40 -73 41 \\
        --heights GHS_BUILT_H_ANBH_E2018_GLOBE_R2023A_4326_3ss_V1_0_R5_C11.tif \\
        --out "$scratch/dem/new-york/open-200-mask"

`--input` is a directory build_elevation.py or sample_elevation.py wrote. The
manifest records the rule, the input and every height file, and always
`bounds`, so build_graph.py accepts these tiles only for a `--sample` build.
"""

import argparse
import contextlib
import hashlib
import json
import math
import sys
from pathlib import Path

from build_elevation import (
    METRES_PER_ARCSECOND, POSTS, _bands, dilate_rows, ellipse_spans, footprint_columns, footprint_rows, hgt_name,
    hgt_path, row_latitudes,
)
from sample_elevation import cells_in, read_hgt, write_hgt, write_manifest

SCHEMA = "bicino-valhalla-elevation-v1"
SOURCE_ID = "ghs-built-h-anbh-r2023a"
# Chosen on eight city samples on 2026-11-27; see the refresh runbook, "Switching elevation off in tower zones".
THRESHOLD_METRES = 30.0
SMOOTH_METRES = 150.0
MARGIN_METRES = 200.0
# The widest ellipse a row may get, as in the opening: it stays inside the neighbouring cells.
WIDEST = (POSTS - 1) // 2 - 1


def window_shape(row_margin, column_margin):
    return POSTS + 2 * row_margin, POSTS + 2 * column_margin


def check_grid(dataset):
    """A height grid must be a north-up raster in geographic coordinates."""
    if dataset.crs is None or not dataset.crs.is_geographic:
        raise ValueError("a height grid must be in geographic coordinates")
    transform = dataset.transform
    if transform.b or transform.d or transform.a <= 0 or transform.e >= 0:
        raise ValueError("a height grid must be north-up")


def uncovered_cells(datasets, cells):
    """Names of the cells with a corner that no height grid covers.

    The grid is global and reads 0 where nothing is built, so a cell outside
    every file is a wrong file, not a place without towers: it would come out
    unmasked and look masked. A cell is far smaller than a file of the grid,
    so four covered corners mean a covered cell.
    """
    def covered(longitude, latitude):
        return any(dataset.bounds.left <= longitude <= dataset.bounds.right
                   and dataset.bounds.bottom <= latitude <= dataset.bounds.top for dataset in datasets)

    return [hgt_name(longitude, latitude) for longitude, latitude in cells
            if not all(covered(longitude + dx, latitude + dy) for dx in (0, 1) for dy in (0, 1))]


def building_heights(datasets, cell, row_margin, column_margin):
    """Building height at every post of `cell` and of a margin around it, 0 where no grid has a height.

    A post takes the grid cell it lies in: the grid is three times coarser
    than the posts and its heights are averages over a cell already. Each
    dataset is north-up in geographic coordinates; several may tile the area,
    and where two cover a post the later one wins. A margin that reaches
    past every file counts as unbuilt there, so pass the files beside a
    cell at the edge of one too.
    """
    import numpy as np

    longitude, latitude = cell
    rows, columns = window_shape(row_margin, column_margin)
    heights = np.zeros((rows, columns), dtype="float32")
    # From whole arc-seconds, so that a post gets the same coordinates, and the same grid cell, in every window.
    side = POSTS - 1
    post_longitudes = (longitude * side + np.arange(columns) - column_margin) / side
    post_latitudes = ((latitude + 1) * side - np.arange(rows) + row_margin) / side
    for dataset in datasets:
        check_grid(dataset)
        transform = dataset.transform
        pixel_columns = np.floor((post_longitudes - transform.c) / transform.a).astype("int64")
        pixel_rows = np.floor((post_latitudes - transform.f) / transform.e).astype("int64")
        inside_columns = np.nonzero((pixel_columns >= 0) & (pixel_columns < dataset.width))[0]
        inside_rows = np.nonzero((pixel_rows >= 0) & (pixel_rows < dataset.height))[0]
        if not inside_columns.size or not inside_rows.size:
            continue
        first_row, last_row = int(pixel_rows[inside_rows].min()), int(pixel_rows[inside_rows].max())
        first_column, last_column = (int(pixel_columns[inside_columns].min()),
                                     int(pixel_columns[inside_columns].max()))
        block = dataset.read(1, window=((first_row, last_row + 1), (first_column, last_column + 1)),
                             masked=True).astype("float32").filled(np.nan)
        values = block[np.ix_(pixel_rows[inside_rows] - first_row, pixel_columns[inside_columns] - first_column)]
        if np.any(values[np.isfinite(values)] > 1000):
            raise ValueError("building heights above 1000 m: not a grid of heights in metres")
        target = heights[np.ix_(inside_rows, inside_columns)]
        heights[np.ix_(inside_rows, inside_columns)] = np.where(np.isfinite(values) & (values > 0), values, target)
    return heights


def ellipse_mean(array, rows, columns):
    """Mean over each post's ellipse, its half-width taken from its own row; edges repeat outward."""
    import numpy as np

    columns = np.asarray(columns)
    height, width = array.shape
    widest = int(columns.max())
    padded = np.pad(array.astype("float64"), ((rows, rows), (widest, widest)), mode="edge")
    # sums[r, j] is the sum of padded row r left of column j.
    sums = np.concatenate([np.zeros((padded.shape[0], 1)), np.cumsum(padded, axis=1)], axis=1)
    result = np.empty((height, width), dtype="float32")
    for first, last, half_width in _bands(columns, 0, height):
        spans = ellipse_spans(rows, half_width)
        total = np.zeros((last - first, width))
        for dy, span in enumerate(spans):
            band = sums[first + dy:last + dy]
            total += band[:, widest + span + 1:widest + span + 1 + width] - band[:, widest - span:widest - span + width]
        result[first:last] = total / sum(2 * span + 1 for span in spans)
    return result


def zone_columns(radius, latitudes):
    import numpy as np

    return np.array([footprint_columns(radius, latitude, WIDEST) for latitude in latitudes])


def tower_zone(heights, latitudes, threshold, smooth, margin):
    """Posts to mask: where the mean building height over `smooth` metres reaches `threshold`, grown by `margin`."""
    import numpy as np

    dominated = heights >= threshold
    if not dominated.any():
        # A mean reaches the threshold only where some height does: most of the planet ends here.
        return dominated
    if smooth > 0:
        dominated = ellipse_mean(heights, footprint_rows(smooth), zone_columns(smooth, latitudes)) >= threshold
    if margin > 0 and dominated.any():
        grown = dilate_rows(dominated.astype("float32"), footprint_rows(margin), zone_columns(margin, latitudes))
        dominated = grown > 0
    return dominated


def zone_margins(cell, smooth, margin):
    """Posts of margin a cell's window needs so that every post of the cell gets its final answer."""
    row_margin = (footprint_rows(smooth) if smooth > 0 else 0) + (footprint_rows(margin) if margin > 0 else 0)
    latitudes = row_latitudes(cell[1] + 1, -row_margin, POSTS + 2 * row_margin)
    widest = [int(zone_columns(radius, latitudes).max()) for radius in (smooth, margin) if radius > 0]
    return row_margin, sum(widest), latitudes


def cell_zone(datasets, cell, threshold=THRESHOLD_METRES, smooth=SMOOTH_METRES, margin=MARGIN_METRES):
    """The tower zone of one cell as a boolean array over its posts."""
    row_margin, column_margin, latitudes = zone_margins(cell, smooth, margin)
    heights = building_heights(datasets, cell, row_margin, column_margin)
    zone = tower_zone(heights, latitudes, threshold, smooth, margin)
    return zone[row_margin:row_margin + POSTS, column_margin:column_margin + POSTS]


def mask_posts(heights, zone):
    """`heights` with no data inside `zone`; returns them and how many posts lost a height."""
    import numpy as np

    lost = zone & np.isfinite(heights)
    return np.where(zone, np.nan, heights).astype("float32"), int(lost.sum())


def post_area_km2(latitude):
    return METRES_PER_ARCSECOND ** 2 * math.cos(math.radians(latitude)) / 1e6


def file_identity(path):
    with path.open("rb") as stream:
        sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"file": path.name, "bytes": path.stat().st_size, "sha256": sha256}


def load_input(directory, bounds):
    """The input's directory, manifest path and manifest, and its cells inside `bounds`."""
    source_dir = directory.resolve(strict=True)
    manifest_path = source_dir / "elevation-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("schema") != SCHEMA:
        raise ValueError("--input is not an elevation directory")
    present = [cell for cell in cells_in(bounds) if hgt_path(source_dir, *cell).exists()]
    if not present:
        raise ValueError("--input has no cell inside --bounds")
    return source_dir, manifest_path, manifest, present


def run(args, out, source_dir, manifest_path, source_manifest, present, files, datasets):
    entries = []
    for cell in present:
        zone = cell_zone(datasets, cell, args.threshold, args.smooth, args.margin)
        heights, lost = mask_posts(read_hgt(hgt_path(source_dir, *cell)), zone)
        entry = {**write_hgt(out, cell, heights), "maskedPosts": lost,
                 "maskedKm2": round(lost * post_area_km2(cell[1] + 0.5), 2)}
        entries.append(entry)
        print(f"{entry['cell']}: {lost} posts masked, about {entry['maskedKm2']} km2", flush=True)
    ids = "+".join(source["id"] for source in source_manifest["sources"] if source.get("cells"))
    masked = {"id": f"tower-mask-of-{ids}",
              "input": {"manifestSha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
                        "cellListSha256": source_manifest["cellListSha256"]}}
    grid = {"id": SOURCE_ID, "licence": "CC BY 4.0, (c) European Union", "files": [file_identity(path) for path in files]}
    method = {"name": "tower-mask", "of": source_manifest.get("method"), "heights": SOURCE_ID,
              "thresholdMetres": args.threshold, "smoothMetres": args.smooth, "marginMetres": args.margin,
              "footprint": "ellipse", "footprintLatitude": "post row", "metresPerArcsecond": METRES_PER_ARCSECOND,
              "masked": "no data", "maskedPosts": sum(entry["maskedPosts"] for entry in entries)}
    return write_manifest(out, method, [masked, grid], entries, args.bounds)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", required=True, type=Path, help="Elevation tiles to mask, with their manifest")
    parser.add_argument("--heights", required=True, type=Path, nargs="+", metavar="GEOTIFF",
                        help="GHS-BUILT-H ANBH GeoTIFFs in WGS 84 that cover the cells")
    parser.add_argument("--out", required=True, type=Path, help="A new directory")
    parser.add_argument("--bounds", required=True, type=int, nargs=4, metavar=("WEST", "SOUTH", "EAST", "NORTH"))
    parser.add_argument("--threshold", type=float, default=THRESHOLD_METRES,
                        help="Mean building height in metres from which a post is in a tower zone")
    parser.add_argument("--smooth", type=float, default=SMOOTH_METRES,
                        help="Radius in metres of the ellipse the mean is taken over; 0 judges each grid cell alone")
    parser.add_argument("--margin", type=float, default=MARGIN_METRES, help="Metres a tower zone is grown by")
    args = parser.parse_args()
    try:
        cells = cells_in(args.bounds)
    except ValueError as error:
        parser.error(str(error))
    if len(cells) > 16:
        parser.error("Samples are limited to 16 cells")
    if not 1 <= args.threshold <= 500:
        parser.error("--threshold must be between 1 and 500 metres")
    for name, value in (("--smooth", args.smooth), ("--margin", args.margin)):
        if value != 0 and not 15 <= value <= 2000:
            parser.error(f"{name} must be 0 or between 15 and 2000 metres")
    import rasterio

    # The input and the height files are checked before --out exists.
    with contextlib.ExitStack() as stack:
        try:
            source = load_input(args.input, args.bounds)
            files = [path.resolve(strict=True) for path in args.heights]
            stack.enter_context(rasterio.Env())
            datasets = [stack.enter_context(rasterio.open(path)) for path in files]
            for dataset in datasets:
                check_grid(dataset)
            missing = uncovered_cells(datasets, source[-1])
            if missing:
                raise ValueError(f"no file of --heights covers {', '.join(missing)}")
        except (OSError, ValueError) as error:
            parser.error(str(error))
        out = args.out.resolve()
        out.mkdir(parents=True)
        path = run(args, out, *source, files, datasets)
    print(f"Elevation manifest: {path}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
