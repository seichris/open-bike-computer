#!/usr/bin/env python3
"""Terrain artifacts in a graded build's tiles, and the roads they give a false step.

    terrain_artifacts.py scan   --terrain DIR --opened DIR --hybrid DIR --out DIR [--jobs N] [CELL ...]
    terrain_artifacts.py roads  --dir DIR --url URL [--jobs N]
    terrain_artifacts.py report --dir DIR [--sample]

The planet builder's `terrain-scan` stage runs the three in turn after a graded build with terrain sources (see
builder/README.md). They read the tiles and ask one Valhalla service; they write only below --out / --dir.

Lidar terrain models carry artifacts that Copernicus does not: pits a few pixels wide on lakes and farmland,
blocks of zero heights, slots in a level plain. The hybrid carries a terrain post unchanged wherever the terrain
has one, so the graded graph stores the artifact as a grade. Found by hand on the first hybrid planet
(2026-11-27): 61 public-road ways with a false step, 5 of them at pit artifacts.

scan    For every cell with a terrain tile, a hybrid tile and an opened tile, without a network:

        - Posts far below a flat opened surface. Real ground lies under opened Copernicus by the height of the
          forest, and on steep slopes Copernicus itself is wrong by hundreds of metres, so a deep terrain post
          means a pit only where the opened surface is flat: its FLAT_POSTS by FLAT_POSTS posts differ by
          FLAT_METRES at most. Counted per source at DEPTHS, everywhere and where it is flat.
        - Closed hollows. A post of the hybrid that is a terrain post carried unchanged and has, in each of the
          eight compass directions, a post at least CLOSED metres higher within REACH posts (about 370 m; east
          and west as many more posts as make the same distance). Pit posts within GAP posts of each other form
          a group. A group is left out when it lies less than HIDDEN metres further under opened Copernicus than
          the ground around it: Copernicus shows the valleys, mines and quarries that were there in 2011 to
          2015, and no lidar pit. A group whose walls step STEEP metres or more between two neighbouring posts
          is steep; it keeps a patch of the hybrid around it for the road check. A steep group is an artifact
          candidate when it is a narrow hole in level ground: the 10th to 90th percentile spread of the patch
          outside the hollow is at most LEVEL metres, and less than NARROW of a box of BOX posts each way (about
          2.5 km) lies more than WIDE metres under the box's median. The pits found by hand lay in ground spread
          3 to 22 m (lakes, plains, farmland), canyons in 138 to 369 m; a lidar pit took under 1% of such a box,
          a mine or a quarry 2 to 45%. A hollow whose floor is at 0 m or below with ground ZEROS metres higher
          around it is a candidate however wide: a block of zero heights where a tile had no data, as 3DEP has
          on a plain in South Dakota.

        Writes scan.json (settings, totals per source, one row per cell) and pits.jsonl.gz (the steep groups of
        each cell, with their patches).

roads   For every steep group, asks the service's /locate (bicycle costing) for the edges around it, keeps each
        edge whose shape comes within NEAR metres of a post HOLE metres or more under its rims, and reads the
        patch's heights along it every SAMPLE metres, bilinearly, once as they are and once with the hollow
        filled (each such post takes the mean of its neighbours, from the rim inwards). An edge has a false step
        when the hollow lowers it by DIP metres or more, and its steepest SPAN metres read STEP_GRADE or more as
        they are and FILLED_GRADE or less filled. A road along a canyon floor keeps a smooth profile and is not
        counted; a road that dives into a pit and climbs out is. Bridges and tunnels are counted apart: Valhalla
        grades them from their ends. An edge beside several hollows counts once, with its worst.

        Writes roads.json.gz. Exits 1 when a lookup failed, after writing what it found. When STOP_AFTER hollows
        in a row fail, the service is taken to be gone and the rest are not looked up, rather than each waiting
        out its retries.

report  Writes terrain-report.json and terrain-report.md: artifact candidates per source, ways with a false step
        by road class and paved or unpaved, and the worst of both with coordinates. It judges nothing: the stage
        does not fail on what it finds.

Not found: a hollow within REACH posts of a tile's edge on that side; a hollow wider than about twice the reach,
of which only rim posts are found; hollows shallower than CLOSED metres; open channels, such as a river under a
bridge whose deck the lidar removed, which are not closed.
"""

from __future__ import annotations

import argparse
import gzip
import json
import math
import os
import sys
import threading
import time
import urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
from pathlib import Path

import build_elevation as be

SCHEMA = "bicino-terrain-scan-v1"
SOURCES = Path(__file__).resolve().parent / "elevation-sources.json"
POST = 1 / 3600
METRES = 111320.0     # metres in a degree of latitude
DEPTHS = (20, 50, 100, 200)
FLAT_POSTS = 7
FLAT_METRES = 2
REACH = 12            # posts
CLOSED = 30           # metres under the lowest rim
HIDDEN = 20           # metres further under opened Copernicus than the ground around
GAP = 3               # posts between two pit posts of one group
PATCH = 8             # posts of the hybrid kept around a steep group
MOST = 300000         # pit posts of one cell that are grouped; more are counted only
STEEP = 20            # metres between two neighbouring posts
LEVEL = 25            # metres of ground spread around an artifact candidate
BOX = 40              # posts each way from a hollow's deepest post, north and south; east and west the same metres
WIDE = 30             # metres under the box's median
NARROW = 0.01         # share of the box an artifact candidate's hollow may take
ZEROS = 100           # metres above a floor at 0 m: a block of zero heights
HOLE = 5              # metres under its rims: a patch post that is part of the hollow
NEAR = 60             # metres from an edge to a hole post
COVER = 150           # metres: every pit post lies this close to a /locate point
RADIUS = 200          # metres: /locate radius, Valhalla's default maximum
BATCH = 50            # locations in one /locate request
SAMPLE = 10           # metres between two height samples along an edge
SPAN = 30             # metres over which an edge's grade is read
DIP = 5               # metres the hollow lowers an edge
STEP_GRADE = 0.30
FILLED_GRADE = 0.20
STOP_AFTER = 25       # hollows in a row whose lookups failed: the service is gone
LISTED = 25           # rows of each list in the report
DIRECTIONS = ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1))
PAVED = ("paved_smooth", "paved", "paved_rough")
MAIN = ("motorway", "trunk", "primary", "secondary", "tertiary")
MINOR = ("unclassified", "residential")
PUBLIC_CLASSES = MAIN + MINOR
PATHS = ("cycleway", "mountain_bike", "footway", "path", "sidewalk", "pedestrian", "steps", "bridleway",
         "pedestrian_crossing", "elevator", "escalator")
SERVICE = ("service_road", "driveway", "parking_aisle", "alley", "drive_through", "emergency_access", "culdesac")
CATEGORIES = ("main road", "minor public road", "service road", "track", "bike or foot way")
PUBLIC = ("main road", "minor public road")
_STATE = {}


# ----------------------------------------------------------------------------------------------- the tiles


def spread_of(heights, size):
    """Highest minus lowest height in the size by size posts around each post; no data counts as not flat."""
    import numpy as np

    half = size // 2
    high = np.where(np.isfinite(heights), heights, np.inf)
    low = np.where(np.isfinite(heights), heights, -np.inf)
    for axis in (0, 1):
        pad = [(half, half) if a == axis else (0, 0) for a in (0, 1)]
        padded_high = np.pad(high, pad, constant_values=-np.inf)
        padded_low = np.pad(low, pad, constant_values=np.inf)
        length = heights.shape[axis]

        def part(shift):
            return tuple(slice(shift, shift + length) if a == axis else slice(None) for a in (0, 1))

        high = np.maximum.reduce([padded_high[part(shift)] for shift in range(size)])
        low = np.minimum.reduce([padded_low[part(shift)] for shift in range(size)])
    return high - low


def rim(ground, direction, reach):
    """The highest post within reach posts in one direction; beyond the tile there is none."""
    import numpy as np

    rows, columns = ground.shape
    best = np.full(ground.shape, -np.inf, dtype="float32")
    for step in range(1, reach + 1):
        dr, dc = step * direction[0], step * direction[1]
        to = (slice(max(0, -dr), rows - max(0, dr)), slice(max(0, -dc), columns - max(0, dc)))
        of = (slice(max(0, dr), rows - max(0, -dr)), slice(max(0, dc), columns - max(0, -dc)))
        np.maximum(best[to], ground[of], out=best[to])
    return best


def closed_depth(heights, reach, latitude):
    """How far each post lies under the lowest of its eight rims; NaN where it has no height."""
    import numpy as np

    ground = np.where(np.isfinite(heights), heights, -np.inf).astype("float32")
    east_west = round(reach / math.cos(math.radians(latitude)))
    lowest = None
    for direction in DIRECTIONS:
        found = rim(ground, direction, east_west if direction[0] == 0 else reach)
        lowest = found if lowest is None else np.minimum(lowest, found, out=lowest)
    with np.errstate(invalid="ignore"):
        return np.where(np.isfinite(heights), lowest - ground, np.nan)


def groups_of(rows, columns, gap=GAP):
    """Posts in groups: two posts within gap posts of each other belong to one."""
    left = set(zip(rows.tolist(), columns.tolist()))
    found = []
    while left:
        start = left.pop()
        group, queue = [start], [start]
        while queue:
            r, c = queue.pop()
            for dr in range(-gap, gap + 1):
                for dc in range(-gap, gap + 1):
                    other = (r + dr, c + dc)
                    if other in left:
                        left.remove(other)
                        group.append(other)
                        queue.append(other)
        found.append(sorted(group))
    return sorted(found)


def source_masks(cell, ids, sources):
    """Which source gave each post of a terrain tile: None for every post when the receipt names one source.

    A cell's terrain tile takes each post from the first of its sources that has data there inside its own area
    (build_elevation.build_terrain_cell), and the areas meet without overlapping but for a strip of sea, so a post
    is the first source's whose area holds it.
    """
    import numpy as np

    if len(ids) == 1:
        return {ids[0]: None}
    known = {source.id: source for source in sources}
    missing = [name for name in ids if name not in known]
    if missing:
        raise ValueError(f"{be.hgt_name(*cell)} names terrain sources the source list does not hold: {missing}")
    left = np.ones((be.POSTS, be.POSTS), dtype=bool)
    masks = {}
    for name in ids:
        source = known[name]
        inside = be.posts_in_area(cell, be.load_area(source.area, source.area_sha256))
        inside = np.full(left.shape, inside) if isinstance(inside, bool) else inside
        masks[name] = left & inside
        left &= ~inside
    return masks


def _start(terrain, opened, hybrid):
    _STATE.update(terrain=Path(terrain), opened=Path(opened), hybrid=Path(hybrid),
                  sources=be.load_terrain_sources(SOURCES))


def scan_cell(name):
    """One cell: its counts per source and its steep groups, each with its patch."""
    import numpy as np

    cell = be.cell_of(name)
    receipt = json.loads((_STATE["terrain"] / "receipts" / f"{name}.json").read_text())
    paths = {kind: be.hgt_path(_STATE[kind], *cell) for kind in ("terrain", "opened", "hybrid")}
    missing = [kind for kind, path in paths.items() if not path.exists()]
    if missing:
        return {"cell": name, "skipped": f"no {' and no '.join(missing)} tile"}, []
    ground, fill, heights = (be.read_tile(paths[kind])[0] for kind in ("terrain", "opened", "hybrid"))
    ids = [part["source"] for part in receipt["sources"]]
    masks = source_masks(cell, ids, _STATE["sources"])

    def source_at(row, column):
        # The build clips every source to its area, so a terrain post lies in one; the first is the fallback.
        return next((name for name, mask in masks.items() if mask is None or mask[row, column]), ids[0])

    terrain = np.isfinite(ground)
    carried = terrain & (heights == ground)
    both = terrain & np.isfinite(fill)
    below = np.where(both, fill - ground, 0).astype("float32")
    flat = both & (spread_of(fill, FLAT_POSTS) <= FLAT_METRES)
    row = {"cell": name, "sources": {}, "rejectedPixels": receipt.get("rejectedPixels", 0)}
    for source, mask in masks.items():
        mine = both if mask is None else both & mask
        counts = {"posts": int(mine.sum()), "flatPosts": int((mine & flat).sum())}
        for depth in DEPTHS:
            counts[f"below{depth}"] = int((mine & (below > depth)).sum())
            counts[f"flatBelow{depth}"] = int((mine & flat & (below > depth)).sum())
        # The posts that are pits by this count and that the graph is graded with.
        counts["flatBelow50Carried"] = int((mine & flat & carried & (below > 50)).sum())
        row["sources"][source] = counts
    deep = np.where(flat, below, 0)
    if deep.max() > 50:
        r, c = np.unravel_index(int(np.argmax(deep)), deep.shape)
        row["deepestBelowFlat"] = {"metres": round(float(deep[r, c]), 1), **position(cell, r, c),
                                   "terrain": round(float(ground[r, c]), 1), "opened": round(float(fill[r, c]), 1),
                                   "source": source_at(r, c)}

    depth = closed_depth(heights, REACH, cell[1] + 0.5)
    with np.errstate(invalid="ignore"):
        pit = carried & (depth >= CLOSED)
    rows, columns = np.nonzero(pit)
    row.update(closedPosts=int(len(rows)), groups={}, copernicusShows=0, untested=0)
    if len(rows) > MOST:
        row["notGrouped"] = True
        return row, []
    under = fill - ground
    last = be.POSTS - 1
    east_west_box = round(BOX / math.cos(math.radians(cell[1] + 0.5)))
    steep = []
    for group in groups_of(rows, columns):
        gr, gc = (np.array(axis) for axis in zip(*group))
        top, bottom = max(int(gr.min()) - PATCH, 0), min(int(gr.max()) + PATCH, last)
        west, east = max(int(gc.min()) - PATCH, 0), min(int(gc.max()) + PATCH, last)
        inside = np.zeros((bottom - top + 1, east - west + 1), dtype=bool)
        inside[gr - top, gc - west] = True
        window = (slice(top, bottom + 1), slice(west, east + 1))
        here, there = under[gr, gc], under[window][~inside]
        if not (np.isfinite(here).any() and np.isfinite(there).any()):
            # Opened Copernicus has no heights here or around: the group cannot be tested.
            row["untested"] += 1
            continue
        further = float(np.nanmedian(here) - np.nanmedian(there))
        if further < HIDDEN:
            row["copernicusShows"] += 1
            continue
        deepest = int(np.argmax(depth[gr, gc]))
        source = source_at(int(gr[deepest]), int(gc[deepest]))
        counted = row["groups"].setdefault(source, {"groups": 0, "steep": 0, "candidates": 0})
        counted["groups"] += 1
        steps = [abs(float(heights[r, c] - heights[r + dr, c + dc])) for r, c in group for dr, dc in DIRECTIONS[:4]
                 if 0 <= r + dr <= last and 0 <= c + dc <= last and np.isfinite(heights[r + dr, c + dc])]
        steepest = max(steps, default=0.0)
        if steepest < STEEP:
            continue
        patch, closed = heights[window], depth[window]
        with np.errstate(invalid="ignore"):
            hole = np.isfinite(patch) & (closed >= HOLE)
        outside = patch[np.isfinite(patch) & ~hole]
        spread = (float(np.percentile(outside, 90) - np.percentile(outside, 10)) if outside.size >= 10 else None)
        share = hollow_share(heights, int(gr[deepest]), int(gc[deepest]), east_west_box)
        lowest = float(ground[gr, gc].min())
        around = float(np.nanmedian(patch[~inside]))
        zeros = lowest <= 0 and around - lowest >= ZEROS
        candidate = spread is not None and spread <= LEVEL and (share < NARROW or zeros)
        counted["steep"] += 1
        counted["candidates"] += candidate
        steep.append({
            "posts": len(group), **position(cell, int(gr[deepest]), int(gc[deepest])),
            "source": source,
            "closedDepth": round(float(depth[gr[deepest], gc[deepest]]), 1),
            "lowest": round(lowest, 1),
            "aroundMedian": round(around, 1),
            "steepestStep": round(steepest, 1),
            "furtherUnderOpened": round(further, 1),
            "groundSpread": None if spread is None else round(spread, 1),
            "hollowShare": round(share, 4),
            "zeros": zeros,
            "candidate": candidate,
            "postsNorthSouth": int(gr.max() - gr.min() + 1), "postsEastWest": int(gc.max() - gc.min() + 1),
            "patch": {"north": round(cell[1] + 1 - top / last, 7), "west": round(cell[0] + west / last, 7),
                      "rows": [[None if not np.isfinite(value) else int(round(float(value))) for value in line]
                               for line in patch],
                      "closed": [[int(round(float(value))) if value > 0 else 0 for value in line]
                                 for line in np.nan_to_num(closed, nan=0.0)]},
        })
    steep.sort(key=lambda entry: -entry["closedDepth"])
    return row, steep


def hollow_share(heights, row, column, east_west):
    """The share of the posts within BOX rows and east_west columns of a post that lie WIDE metres under their median."""
    import numpy as np

    box = heights[max(row - BOX, 0):row + BOX + 1, max(column - east_west, 0):column + east_west + 1]
    box = box[np.isfinite(box)]
    if not box.size:
        return 1.0
    return float(np.count_nonzero(box < np.median(box) - WIDE)) / box.size


def position(cell, row, column):
    last = be.POSTS - 1
    return {"latitude": round(cell[1] + 1 - row / last, 5), "longitude": round(cell[0] + column / last, 5)}


def scan(terrain, opened, hybrid, out, jobs=4, cells=None, say=print):
    """Scan the cells; returns the summary written to scan.json."""
    terrain, opened, hybrid, out = Path(terrain), Path(opened), Path(hybrid), Path(out)
    names = list(cells) if cells else sorted(path.stem for path in (terrain / "receipts").glob("*.json"))
    if not names:
        raise SystemExit(f"error: {terrain} holds no terrain receipts")
    out.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    rows = []
    partial = out / "pits.jsonl.gz.partial"
    with gzip.open(partial, "wt", compresslevel=6) as pits:
        def take(results):
            for done, (row, steep) in enumerate(results, 1):
                rows.append(row)
                if steep:
                    pits.write(json.dumps({"cell": row["cell"], "groups": steep}, separators=(",", ":")) + "\n")
                if done % 200 == 0:
                    say(f"{done}/{len(names)} cells, {time.monotonic() - started:.0f} s")

        if jobs <= 1:
            _start(terrain, opened, hybrid)
            take(map(scan_cell, names))
        else:
            with ProcessPoolExecutor(jobs, initializer=_start, initargs=(terrain, opened, hybrid)) as pool:
                take(pool.map(scan_cell, names, chunksize=2))
    os.replace(partial, out / "pits.jsonl.gz")
    totals = {}
    for row in rows:
        if "skipped" in row:
            continue
        for source, counts in row["sources"].items():
            total = totals.setdefault(source, {"cells": 0, "groups": 0, "steep": 0, "candidates": 0,
                                               "cellsFlatBelow50": 0, **dict.fromkeys(counts, 0)})
            # A source counts the cells it gave posts to; a border cell's receipt names every source it read.
            total["cells"] += counts["posts"] > 0
            total["cellsFlatBelow50"] += counts["flatBelow50"] > 0
            for key, value in counts.items():
                total[key] += value
        for source, counted in row["groups"].items():
            for key in ("groups", "steep", "candidates"):
                totals[source][key] += counted[key]
    summary = {
        "schema": SCHEMA,
        "rules": {"depthsMetres": list(DEPTHS), "flatPosts": FLAT_POSTS, "flatMetres": FLAT_METRES,
                  "reachPosts": REACH, "closedMetres": CLOSED, "hiddenMetres": HIDDEN, "steepMetres": STEEP,
                  "levelMetres": LEVEL, "boxPosts": BOX, "wideMetres": WIDE, "narrowShare": NARROW,
                  "zerosMetres": ZEROS},
        "seconds": round(time.monotonic() - started),
        "jobs": jobs,
        "cells": len(rows),
        "skipped": sum(1 for row in rows if "skipped" in row),
        "notGrouped": [row["cell"] for row in rows if row.get("notGrouped")],
        # Hollows left out because opened Copernicus shows them, and those it could not test.
        "copernicusShows": sum(row.get("copernicusShows", 0) for row in rows),
        "untested": sum(row.get("untested", 0) for row in rows),
        "totals": totals,
        "rows": rows,
    }
    write_json(out / "scan.json", summary)
    say(f"{len(rows) - summary['skipped']} cells scanned, {summary['skipped']} skipped, {summary['seconds']} s "
        f"with {jobs} jobs; " + "; ".join(f"{source}: {total['candidates']} artifact candidates of {total['steep']} "
                                           f"steep hollows" for source, total in sorted(totals.items())))
    return summary


# ------------------------------------------------------------------------------------------------ the roads


def decode(shape):
    """Valhalla's encoded polyline, precision 6, as (lat, lon) pairs."""
    points, index, lat, lon = [], 0, 0, 0
    while index < len(shape):
        values = []
        for _ in range(2):
            result, bit = 0, 0
            while True:
                byte = ord(shape[index]) - 63
                index += 1
                result |= (byte & 0x1F) << bit
                bit += 5
                if byte < 0x20:
                    break
            values.append(~(result >> 1) if result & 1 else result >> 1)
        lat += values[0]
        lon += values[1]
        points.append((lat / 1e6, lon / 1e6))
    return points


def along(shape, spacing=SAMPLE):
    """Points every `spacing` metres along the shape from its first point, and its last point."""
    if not shape:
        return []
    k = math.cos(math.radians(shape[0][0]))
    points, ahead, since = [shape[0]], spacing, 0.0
    for (la1, lo1), (la2, lo2) in zip(shape, shape[1:]):
        length = math.hypot((la2 - la1) * METRES, (lo2 - lo1) * METRES * k)
        while ahead <= length:
            t = ahead / length
            points.append((la1 + t * (la2 - la1), lo1 + t * (lo2 - lo1)))
            ahead += spacing
        ahead -= length
        since = spacing - ahead
    if len(shape) > 1 and since > 0.5:
        points.append(shape[-1])
    return points


def cover(posts, latitude):
    """Points such that every post lies within COVER metres of one of them."""
    k = math.cos(math.radians(latitude))
    left = sorted(posts)
    points = []
    while left:
        lat, lon = left[0]
        points.append((lat, lon))
        left = [(a, b) for a, b in left if math.hypot((a - lat) * METRES, (b - lon) * METRES * k) > COVER]
    return points


def filled_grid(rows, holes):
    """The patch with every hole post replaced by the mean of its neighbours, from the rim inwards."""
    filled = [list(line) for line in rows]
    left = set(holes)
    while left:
        ring = {}
        for r, c in left:
            around = [filled[r + dr][c + dc] for dr in (-1, 0, 1) for dc in (-1, 0, 1)
                      if 0 <= r + dr < len(rows) and 0 <= c + dc < len(rows[0]) and (r + dr, c + dc) not in left
                      and filled[r + dr][c + dc] is not None]
            if around:
                ring[(r, c)] = sum(around) / len(around)
        if not ring:
            break
        for (r, c), value in ring.items():
            filled[r][c] = value
        left -= set(ring)
    return filled


def bilinear(grid, north, west, lat, lon):
    row, column = (north - lat) / POST, (lon - west) / POST
    if not (0 <= row <= len(grid) - 1 and 0 <= column <= len(grid[0]) - 1):
        return None
    r, c = min(int(row), len(grid) - 2), min(int(column), len(grid[0]) - 2)
    fr, fc = row - r, column - c
    four = grid[r][c], grid[r][c + 1], grid[r + 1][c], grid[r + 1][c + 1]
    if None in four:
        return None
    return four[0] * (1 - fr) * (1 - fc) + four[1] * (1 - fr) * fc + four[2] * fr * (1 - fc) + four[3] * fr * fc


def prepare(cell, index, group):
    """A steep group as the road check needs it: its hole posts, its filled patch and its /locate points."""
    patch = group["patch"]
    north, west = patch["north"], patch["west"]
    holes = {(r, c) for r, line in enumerate(patch["closed"]) for c, value in enumerate(line)
             if value >= HOLE and patch["rows"][r][c] is not None}
    own = [(north - r * POST, west + c * POST) for r, line in enumerate(patch["closed"]) for c, value in enumerate(line)
           if value >= CLOSED]
    return {"cell": cell, "index": index, "group": group, "holes": holes, "north": north, "west": west,
            "points": cover(own or [(group["latitude"], group["longitude"])], group["latitude"])}


def distance_to_holes(item, points, near):
    """Metres from the nearest of the points to a hole post, or None when it is further than near."""
    north, west, holes = item["north"], item["west"], item["holes"]
    k = math.cos(math.radians(north))
    reach_rows, reach_columns = math.ceil(near / (METRES * POST)), math.ceil(near / (METRES * POST * k))
    best = None
    for lat, lon in points:
        row, column = (north - lat) / POST, (lon - west) / POST
        for r in range(math.floor(row) - reach_rows, math.floor(row) + reach_rows + 2):
            for c in range(math.floor(column) - reach_columns, math.floor(column) + reach_columns + 2):
                if (r, c) in holes:
                    metres = math.hypot((north - r * POST - lat) * METRES, (west + c * POST - lon) * METRES * k)
                    if metres <= near and (best is None or metres < best):
                        best = metres
    return best


def effect(item, points, filled):
    """What the hollow does to an edge: its heights along the points with the hollow and with it filled."""
    patch = item["group"]["patch"]
    read = [(lat, lon, bilinear(patch["rows"], item["north"], item["west"], lat, lon),
             bilinear(filled, item["north"], item["west"], lat, lon)) for lat, lon in points]
    known = [entry for entry in read if entry[2] is not None and entry[3] is not None]
    if len(known) < 2:
        return None
    worst = max(known, key=lambda entry: entry[3] - entry[2])
    apart = round(SPAN / SAMPLE)

    def steepest(which):
        return max((abs(b[which] - a[which]) for a, b in zip(read, read[apart:])
                    if a[which] is not None and b[which] is not None), default=0.0)

    actual, filled = steepest(2), steepest(3)
    dip = worst[3] - worst[2]
    return {"dip": round(dip, 1), "dipAt": [round(worst[0], 5), round(worst[1], 5)],
            "height": round(worst[2], 1), "heightPitFilled": round(worst[3], 1),
            "grade": round(actual / SPAN, 3), "gradePitFilled": round(filled / SPAN, 3),
            "metresRead": SAMPLE * (len(known) - 1),
            "falseStep": dip >= DIP and actual >= STEP_GRADE * SPAN and filled <= FILLED_GRADE * SPAN}


def category(edge):
    use, kind = edge.get("use") or "", edge.get("class") or ""
    if use == "track":
        return "track"
    if use in PATHS:
        return "bike or foot way"
    if use in SERVICE or kind == "service_other":
        return "service road"
    if kind in MAIN:
        return "main road"
    if kind in MINOR:
        return "minor public road"
    return "other"


def locate(url, points, attempts=4, wait=2):
    body = json.dumps({"locations": [{"lat": lat, "lon": lon, "radius": RADIUS, "minimum_reachability": 0}
                                     for lat, lon in points], "costing": "bicycle", "verbose": True}).encode()
    last = None
    for attempt in range(attempts):
        try:
            request = urllib.request.Request(url.rstrip("/") + "/locate", data=body,
                                             headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=120) as response:
                answer = json.load(response)
            if not isinstance(answer, list) or len(answer) != len(points):
                raise ValueError(f"/locate answered {type(answer).__name__} of {len(answer)} for {len(points)} points")
            return answer
        except Exception as error:  # noqa: BLE001 - tried again; the last failure is reported
            last = error
            time.sleep(wait * (attempt + 1))
    raise RuntimeError(f"/locate failed {attempts} times: {type(last).__name__}: {last}")


def edges_of(answers):
    """Distinct edges of /locate answers by shape, with what the road check reports of them."""
    found = {}
    for answer in answers:
        for edge in (answer or {}).get("edges") or []:
            info, attributes = edge.get("edge_info") or {}, edge.get("edge") or {}
            shape = info.get("shape")
            if not shape or shape in found:
                continue
            kind, geo = attributes.get("classification") or {}, attributes.get("geo_attributes") or {}
            found[shape] = {"way": info.get("way_id"), "names": info.get("names") or [],
                            "class": kind.get("classification"), "use": kind.get("use"), "surface": kind.get("surface"),
                            "bridge": bool(attributes.get("bridge")), "tunnel": bool(attributes.get("tunnel")),
                            "storedSlopes": {key: geo.get(key) for key in ("weighted_grade", "max_up_slope",
                                                                           "max_down_slope")}}
    return found


class Breaker:
    """Stops the lookups once `limit` hollows in a row have failed, so that a dead service costs no more retries."""

    def __init__(self, limit):
        self.limit, self.in_a_row, self.tripped = limit, 0, False
        self.lock = threading.Lock()

    def check(self):
        if self.tripped:
            raise RuntimeError("not looked up: the service had stopped answering")

    def record(self, failed):
        with self.lock:
            self.in_a_row = self.in_a_row + 1 if failed else 0
            self.tripped = self.tripped or self.in_a_row >= self.limit


def look_up(item, url, near=NEAR, wait=2, breaker=None):
    breaker = breaker or Breaker(math.inf)
    breaker.check()
    try:
        answers = []
        for start in range(0, len(item["points"]), BATCH):
            answers += locate(url, item["points"][start:start + BATCH], wait=wait)
    except Exception:
        breaker.record(failed=True)
        raise
    breaker.record(failed=False)
    measured, filled = [], None
    group = item["group"]
    pit = {key: group[key] for key in ("latitude", "longitude", "source", "closedDepth", "lowest", "steepestStep",
                                       "furtherUnderOpened", "groundSpread", "candidate", "posts")}
    for shape, edge in edges_of(answers).items():
        points = along(decode(shape))
        metres = distance_to_holes(item, points, near)
        if metres is None:
            continue
        if filled is None:
            filled = filled_grid(group["patch"]["rows"], item["holes"])
        found = effect(item, points, filled)
        if found is None:
            continue
        measured.append({**edge, **found, "metresToPit": round(metres), "category": category(edge),
                         "paved": edge["surface"] in PAVED, "cell": item["cell"], "group": item["index"], "pit": pit,
                         "shape": shape})
    return measured


def steep_groups(directory):
    with gzip.open(Path(directory) / "pits.jsonl.gz", "rt") as stream:
        for line in stream:
            row = json.loads(line)
            for index, group in enumerate(row["groups"]):
                yield row["cell"], index, group


def roads(directory, url, jobs=4, near=NEAR, say=print, wait=2, stop_after=STOP_AFTER):
    """Look up and measure the edges beside every steep group; returns the exit status."""
    directory = Path(directory)
    started = time.monotonic()
    items = [prepare(*group) for group in steep_groups(directory)]
    say(f"{len(items)} steep groups, {sum(len(item['points']) for item in items)} /locate points")
    best, failed, done, said = {}, [], 0, False
    breaker = Breaker(stop_after)
    with ThreadPoolExecutor(max(1, jobs)) as pool:
        futures = [pool.submit(look_up, item, url, near, wait, breaker) for item in items]
        for item, future in zip(items, futures):
            try:
                measured = future.result()
            except Exception as error:  # noqa: BLE001 - every failed group is counted and named
                failed.append({"cell": item["cell"], "group": item["index"], "error": f"{error}"[:300]})
                if breaker.tripped and not said:
                    said = True
                    say(f"{stop_after} hollows in a row could not be looked up; the rest are not tried")
                continue
            done += 1
            for record in measured:
                old = best.get(record["shape"])
                if old is None or (record["falseStep"], record["dip"]) > (old["falseStep"], old["dip"]):
                    best[record["shape"]] = record
            if done % 2000 == 0:
                say(f"{done}/{len(items)} groups, {time.monotonic() - started:.0f} s")
    edges = sorted(best.values(), key=lambda record: (-record["falseStep"], -record["dip"]))
    for record in edges:
        if not record["falseStep"]:
            del record["shape"]
    result = {"schema": SCHEMA, "url": url, "nearMetres": near, "seconds": round(time.monotonic() - started),
              "groups": len(items), "lookedUp": done, "failed": failed, "edges": edges}
    with gzip.open(directory / "roads.json.gz.partial", "wt") as stream:
        json.dump(result, stream)
    os.replace(directory / "roads.json.gz.partial", directory / "roads.json.gz")
    steps = [record for record in edges if record["falseStep"]]
    say(f"{done} of {len(items)} groups looked up in {result['seconds']} s with {jobs} jobs; {len(edges)} edges within "
        f"{near:g} m of a hollow, {len(steps)} with a false step; {len(failed)} lookups failed")
    for failure in failed[:20]:
        say(f"  failed: {failure['cell']} group {failure['group']}: {failure['error']}")
    return 1 if failed else 0


# ----------------------------------------------------------------------------------------------- the report


def summarize(scan_summary, candidates, roads_result, sample=False):
    """The short report of a scan, its artifact candidates (load_candidates) and its road check."""
    totals = scan_summary["totals"]
    with_steps = set()
    edges = (roads_result or {}).get("edges", [])
    counted = [edge for edge in edges if edge["falseStep"] and not edge["bridge"] and not edge["tunnel"]]
    for edge in counted:
        with_steps.add((edge["cell"], edge["group"]))
    report = {
        "schema": SCHEMA,
        "sample": sample,
        "cells": {"scanned": scan_summary["cells"] - scan_summary["skipped"], "skipped": scan_summary["skipped"],
                  "notGrouped": scan_summary["notGrouped"]},
        "seconds": {"scan": scan_summary["seconds"], "roads": (roads_result or {}).get("seconds")},
        "sources": {source: {
            "cells": total.get("cells", 0),
            "hollowsCopernicusDoesNotShow": total["groups"], "steepHollows": total["steep"],
            "artifactCandidates": total["candidates"],
            "postsMoreThan50mBelowFlatOpened": total.get("flatBelow50", 0),
            "cellsWithSuchPosts": total.get("cellsFlatBelow50", 0),
            "suchPostsInTheGraph": total.get("flatBelow50Carried", 0),
        } for source, total in sorted(totals.items())},
        "rules": dict(scan_summary["rules"], nearMetres=NEAR, dipMetres=DIP, spanMetres=SPAN, stepGrade=STEP_GRADE,
                      filledGrade=FILLED_GRADE, paved=list(PAVED), public=list(PUBLIC_CLASSES)),
    }
    if roads_result is None:
        report["roads"] = None
    else:
        ways = defaultdict(dict)
        for edge in counted:
            ways[edge["category"]].setdefault(edge["way"], edge["paved"])
        by_class = defaultdict(dict)
        for edge in counted:
            if edge["category"] in PUBLIC:
                by_class[edge["class"]].setdefault(edge["way"], edge["paved"])

        def tally(found):
            return {"ways": len(found), "paved": sum(found.values()), "unpaved": len(found) - sum(found.values())}

        left_out = [edge for edge in edges if edge["falseStep"] and (edge["bridge"] or edge["tunnel"])]
        report["roads"] = {
            "steepHollows": roads_result["groups"], "lookedUp": roads_result["lookedUp"],
            "lookupsFailed": len(roads_result["failed"]), "edgesNearHollows": len(edges),
            "falseSteps": {name: tally(ways.get(name, {})) for name in (*CATEGORIES, "other")},
            "publicByClass": {name: tally(by_class[name]) for name in PUBLIC_CLASSES if by_class.get(name)},
            "publicAtCandidates": len({edge["way"] for edge in counted
                                       if edge["category"] in PUBLIC and edge["pit"]["candidate"]}),
            "leftOut": {"bridges": len({edge["way"] for edge in left_out if edge["bridge"]}),
                        "tunnels": len({edge["way"] for edge in left_out if edge["tunnel"] and not edge["bridge"]})},
        }
        public = tally({way: paved for name in PUBLIC for way, paved in ways.get(name, {}).items()})
        report["roads"]["public"] = public

        def row(edge):
            return {key: edge.get(key) for key in ("dip", "dipAt", "grade", "gradePitFilled", "storedSlopes", "way",
                                                   "names", "class", "use", "surface", "paved", "category", "cell")} | {
                "pit": {key: edge["pit"][key] for key in ("source", "closedDepth", "groundSpread", "candidate")}}

        report["worstPublicRoads"] = [row(edge) for edge in worst_per_way(
            edge for edge in counted if edge["category"] in PUBLIC)]
        report["worstOtherWays"] = [row(edge) for edge in worst_per_way(
            edge for edge in counted if edge["category"] not in PUBLIC)]
    listed = []
    for cell, index, group in candidates[:LISTED]:
        listed.append({key: group[key] for key in ("latitude", "longitude", "source", "closedDepth", "lowest",
                                                   "aroundMedian", "posts", "steepestStep", "furtherUnderOpened",
                                                   "groundSpread", "hollowShare", "zeros")} | {
            "cell": cell, "falseStepOnARoad": (cell, index) in with_steps})
    report["deepestCandidates"] = listed
    report["candidates"] = sum(source["artifactCandidates"] for source in report["sources"].values())
    report["headline"] = headline(report)
    return report


def worst_per_way(edges):
    """The deepest false step of each way, the deepest ways first; a way has an edge each way and often more."""
    worst = {}
    for edge in sorted(edges, key=lambda edge: -edge["dip"]):
        worst.setdefault(edge["way"], edge)
    return list(worst.values())[:LISTED]


def load_candidates(directory):
    """Every artifact candidate as (cell, index among its cell's steep groups, group without its patch), deepest first."""
    found = []
    path = Path(directory) / "pits.jsonl.gz"
    if path.exists():
        for cell, index, group in steep_groups(directory):
            if group["candidate"]:
                found.append((cell, index, {key: value for key, value in group.items() if key != "patch"}))
    return sorted(found, key=lambda entry: -entry[2]["closedDepth"])


def counted(number, thing, things=None):
    return f"{number:,} {thing if number == 1 else things or thing + 's'}"


def headline(report):
    parts = [counted(report["candidates"], "artifact candidate")]
    by_source = [f"{source} {entry['artifactCandidates']}" for source, entry in report["sources"].items()
                 if entry["artifactCandidates"]]
    if by_source:
        parts[0] += f" ({', '.join(by_source)})"
    roads_part = report.get("roads")
    if roads_part is None:
        parts.append("roads not checked")
    else:
        public = roads_part["public"]
        parts.append(f"{counted(public['ways'], 'public-road way')} with a false step ({public['paved']} paved, "
                     f"{public['unpaved']} unpaved)")
        if roads_part["lookupsFailed"]:
            parts.append(f"{counted(roads_part['lookupsFailed'], 'lookup')} FAILED")
    return "; ".join(parts)


def where(at):
    return f"{at[0]:.5f}, {at[1]:.5f}"


def markdown(report):
    lines = ["# Terrain scan", ""]
    if report["sample"]:
        lines += ["A city sample rehearsal, not release evidence.", ""]
    cells = report["cells"]
    lines += [f"{report['headline']}.", "",
              f"{cells['scanned']} cells scanned, {cells['skipped']} skipped (no hybrid or no opened tile)."
              + (f" Not grouped, more than {MOST} pit posts: {', '.join(cells['notGrouped'])}." if cells["notGrouped"]
                 else ""), "", "## Artifact candidates by source", "",
              "| Source | Cells | Hollows Copernicus does not show | Steep | In level ground: candidates "
              "| Posts more than 50 m below a flat opened surface (cells; in the graph) |",
              "|---|---|---|---|---|---|"]
    for source, entry in report["sources"].items():
        lines.append(f"| {source} | {entry['cells']:,} | {entry['hollowsCopernicusDoesNotShow']:,} | "
                     f"{entry['steepHollows']:,} | {entry['artifactCandidates']:,} | "
                     f"{entry['postsMoreThan50mBelowFlatOpened']:,} ({entry['cellsWithSuchPosts']:,}; "
                     f"{entry['suchPostsInTheGraph']:,}) |")
    roads_part = report.get("roads")
    lines += ["", "## Ways with a false step", ""]
    if roads_part is None:
        lines.append("The roads were not checked.")
    else:
        at, ways = "", roads_part["public"]["ways"]
        if ways:
            at = f" {roads_part['publicAtCandidates']} of the {counted(ways, 'public-road way')} lie at an artifact candidate."
        if roads_part["publicAtCandidates"] < ways:
            at += (" The others lie at a hollow that is no candidate: on the first hybrid planet those were stream "
                   "crossings, narrow valleys, quarries and a tunnel.")
        lines += [f"{roads_part['lookedUp']:,} of {roads_part['steepHollows']:,} steep hollows looked up, "
                  f"{roads_part['lookupsFailed']} failed; {roads_part['edgesNearHollows']:,} edges within "
                  f"{report['rules']['nearMetres']} m of one.{at}", "",
                  "| Class | Ways | Paved | Unpaved |", "|---|---|---|---|"]
        for name, entry in roads_part["publicByClass"].items():
            lines.append(f"| {name} | {entry['ways']} | {entry['paved']} | {entry['unpaved']} |")
        public = roads_part["public"]
        lines.append(f"| **public roads** | **{public['ways']}** | **{public['paved']}** | **{public['unpaved']}** |")
        for name in CATEGORIES[2:] + ("other",):
            entry = roads_part["falseSteps"][name]
            if entry["ways"] or name != "other":
                lines.append(f"| {name} | {entry['ways']} | {entry['paved']} | {entry['unpaved']} |")
        left_out = roads_part["leftOut"]
        lines += ["", f"Left out because Valhalla grades them from their ends: {left_out['bridges']} bridge and "
                      f"{left_out['tunnels']} tunnel ways with such a step.", "", "### Worst public roads", ""]
        if report["worstPublicRoads"]:
            lines += ["| Dip | Grade over 30 m (filled) | Graph stores up/down | Where | Road | Hollow |",
                      "|---|---|---|---|---|---|"]
            for edge in report["worstPublicRoads"]:
                stored = edge["storedSlopes"] or {}
                pit = edge["pit"]
                lines.append(
                    f"| {edge['dip']:.0f} m | {edge['grade']:.0%} ({edge['gradePitFilled']:.0%}) | "
                    f"{stored.get('max_up_slope')}% / {stored.get('max_down_slope')}% | {where(edge['dipAt'])} | "
                    f"{'/'.join(edge['names']) or 'unnamed'}, {edge['class']}, {edge['surface']} (way {edge['way']}) | "
                    f"{pit['source']}, {pit['closedDepth']:.0f} m deep, ground spread {pit['groundSpread']} m"
                    f"{', candidate' if pit['candidate'] else ''} |")
        else:
            lines.append("None.")
    lines += ["", "## Deepest artifact candidates", ""]
    if report["deepestCandidates"]:
        lines += ["| Depth | Posts | Where | Source | Ground spread | Under Copernicus, beyond the ground around "
                  "| False step on a road |", "|---|---|---|---|---|---|---|"]
        for entry in report["deepestCandidates"]:
            lines.append(f"| {entry['closedDepth']:.0f} m | {entry['posts']} | "
                         f"{where((entry['latitude'], entry['longitude']))} ({entry['cell']}) | {entry['source']} | "
                         f"{entry['groundSpread']} m | {entry['furtherUnderOpened']:.0f} m | "
                         f"{'yes' if entry['falseStepOnARoad'] else 'no'} |")
    else:
        lines.append("None.")
    rules = report["rules"]
    lines += ["", "## Rules", "",
              f"A hollow is a terrain post the hybrid carries, with ground at least {rules['closedMetres']} m higher "
              f"within {rules['reachPosts']} posts in all eight directions, lying {rules['hiddenMetres']} m further "
              f"under opened Copernicus than the ground around it. Steep: a step of {rules['steepMetres']} m or more "
              f"between two neighbouring posts. A candidate is a steep hollow whose ground spread (10th to 90th "
              f"percentile around it) is at most {rules['levelMetres']} m and which takes less than "
              f"{rules['narrowShare']:.0%} of a box of {rules['boxPosts']} posts each way, counting the posts "
              f"{rules['wideMetres']} m under the box's median (a mine or a quarry takes more), or whose floor is at "
              f"0 m with ground {rules['zerosMetres']} m higher around it. A way has a false step where the hollow "
              f"lowers it by {rules['dipMetres']} m or more and its steepest {rules['spanMetres']} m read "
              f"{rules['stepGrade']:.0%} or more, and {rules['filledGrade']:.0%} or less with the hollow filled. "
              f"Public roads are motorway to tertiary, unclassified and residential; paved is "
              f"{', '.join(rules['paved'])}. Written by map-platform/routing/terrain_artifacts.py.", ""]
    return "\n".join(lines)


def report(directory, sample=False, say=print):
    directory = Path(directory)
    scan_summary = json.loads((directory / "scan.json").read_text())
    roads_path = directory / "roads.json.gz"
    roads_result = None
    if roads_path.exists():
        with gzip.open(roads_path, "rt") as stream:
            roads_result = json.load(stream)
    summary = summarize(scan_summary, load_candidates(directory), roads_result, sample)
    write_json(directory / "terrain-report.json", summary)
    (directory / "terrain-report.md").write_text(markdown(summary))
    say(summary["headline"])
    return summary


def write_json(path, value):
    partial = path.with_name(f".{path.name}.partial")
    partial.write_text(json.dumps(value, indent=1) + "\n")
    os.replace(partial, path)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    scanning = commands.add_parser("scan", help="Count deep posts and list closed hollows in the tiles")
    scanning.add_argument("--terrain", required=True, type=Path)
    scanning.add_argument("--opened", required=True, type=Path)
    scanning.add_argument("--hybrid", required=True, type=Path)
    scanning.add_argument("--out", required=True, type=Path)
    scanning.add_argument("--jobs", type=int, default=4)
    scanning.add_argument("cells", nargs="*")
    looking = commands.add_parser("roads", help="Measure the graph's edges beside every steep hollow")
    looking.add_argument("--dir", required=True, type=Path)
    looking.add_argument("--url", required=True)
    looking.add_argument("--jobs", type=int, default=4)
    reporting = commands.add_parser("report", help="Write the short report")
    reporting.add_argument("--dir", required=True, type=Path)
    reporting.add_argument("--sample", action="store_true")
    args = parser.parse_args(argv)

    def say(text):
        print(text, flush=True)

    if args.command == "scan":
        scan(args.terrain, args.opened, args.hybrid, args.out, args.jobs, args.cells, say)
        return 0
    if args.command == "roads":
        return roads(args.dir, args.url, args.jobs, say=say)
    report(args.dir, args.sample, say)
    return 0


if __name__ == "__main__":
    sys.exit(main())
