#!/usr/bin/env python3
"""Grade the roads over crossings from their ends, for a whole planet, before its graded build.

A terrain model reads the ground under a bridge's deck and the channel a
stream cuts through a road's fill, so the road beside a bridge or over a
culvert reads a step it does not have (refresh-runbook.md, "False steps at
crossings"). crossing_split.py fixes such a site by grading the road's
stretch over it from its ends, as Valhalla grades a bridge; this runs it
where the build's terrain lies:

1. `osmium tags-filter` keeps what crossing_steps.py reads: ways tagged
   highway or waterway, and nodes tagged ford.
2. The terrain manifest's cells (the cells of this build that hold terrain
   posts) are grouped into blocks of `--block` degrees; blocks that touch
   make a region. `osmium extract` cuts each region, then each region's
   blocks, every one `--margin` degrees wider on each side, with complete
   ways. A site near a block's edge is then found whole in both blocks, and
   crossing_split.py takes it once.
3. `crossing_steps.py sites` finds the sites of every block, `--jobs` at a
   time, keeping those inside a terrain source's area.
4. crossing_split.py reads every site's profile from the build's hybrid
   tiles, rewrites the input once with osmium and writes the record that
   build_graph.py --crossings-from checks.

Output in `--out`: roads-crossings.osm.pbf, crossings.json (the record),
fixed-sites.json.gz and sites/. The filtered input and the extracts are
deleted once the roads are written.

Needs pyosmium, numpy, shapely and the osmium command: the map-platform image
has them, the builder's host does not.
"""

from __future__ import annotations

import argparse
import gzip
import json
import math
import shutil
import subprocess
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

ROUTING = Path(__file__).resolve().parent
sys.path.insert(0, str(ROUTING))

import build_elevation  # noqa: E402
import crossing_split  # noqa: E402
import crossing_steps  # noqa: E402

SCHEMA = "bicino-crossing-stage-v1"
RECORD = "crossings.json"
ROADS = "roads-crossings.osm.pbf"
# What crossing_steps.read_ways reads; a way keeps its nodes.
FILTER = ("w/highway", "w/waterway", "n/ford")
# Degrees. A 4-degree block of the densest stream networks (Oregon, British
# Columbia) holds well under a million waterways, a few GB in `sites`.
BLOCK_DEGREES = 4
# About 5 km: far more than the 150 m a site's profile reaches.
MARGIN_DEGREES = 0.05
# Extracts per osmium run.
BATCH = 48


def log(message):
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {message}", flush=True)


def terrain_cells(terrain_dir):
    """The (longitude, latitude) cells of cells.txt, the cells this build gave terrain posts."""
    cells = set()
    for line in (Path(terrain_dir) / "cells.txt").read_text().splitlines():
        if line.strip():
            cells.add(build_elevation.cell_of(line.split()[0]))
    return cells


def blocks_of(cells, size=BLOCK_DEGREES):
    """The south-west corners of the blocks of `size` degrees that hold a cell."""
    return sorted({(math.floor(lon / size) * size, math.floor(lat / size) * size) for lon, lat in cells})


def block_name(block, size=BLOCK_DEGREES):
    return f"{build_elevation.hgt_name(*block)}-{size}"


def bbox_of(blocks, size=BLOCK_DEGREES, margin=MARGIN_DEGREES):
    """[west, south, east, north] around the blocks, `margin` degrees wider, within the world."""
    west = min(lon for lon, _ in blocks) - margin
    south = min(lat for _, lat in blocks) - margin
    east = max(lon for lon, _ in blocks) + size + margin
    north = max(lat for _, lat in blocks) + size + margin
    return [round(max(west, -180.0), 6), round(max(south, -90.0), 6),
            round(min(east, 180.0), 6), round(min(north, 90.0), 6)]


def regions_of(blocks, size=BLOCK_DEGREES):
    """Groups of blocks that touch, sides or corners, each sorted, in the order of their first block."""
    parent = {block: block for block in blocks}

    def root(block):
        while parent[block] != block:
            parent[block] = parent[parent[block]]
            block = parent[block]
        return block

    for lon, lat in blocks:
        for dx in (-size, 0, size):
            for dy in (-size, 0, size):
                other = (lon + dx, lat + dy)
                if other in parent:
                    parent[root(other)] = root((lon, lat))
    groups = {}
    for block in blocks:
        groups.setdefault(root(block), []).append(block)
    return sorted((sorted(group) for group in groups.values()), key=lambda group: group[0])


def run(*command):
    subprocess.run([str(part) for part in command], check=True)


def extract(source, extracts, directory, batch=BATCH):
    """Cut `source` into the named boxes, complete ways only: [(file name, bbox)]."""
    directory.mkdir(parents=True, exist_ok=True)
    for start in range(0, len(extracts), batch):
        part = extracts[start:start + batch]
        config = directory / f"extracts-{start // batch}.json"
        config.write_text(json.dumps({"directory": str(directory),
                                      "extracts": [{"output": name, "bbox": bbox} for name, bbox in part]}))
        run("osmium", "extract", "--strategy", "complete_ways", "--config", config, "--overwrite", source)
        config.unlink()


_AREAS = None


def _load_areas(specs):
    global _AREAS
    _AREAS = crossing_steps.load_areas(specs)


def _sites(task):
    pbf, region, out = task
    counts = crossing_steps.write_sites(pbf, region, _AREAS, out, log=log)
    return region, counts


def find_sites(blocks, area_specs, out, jobs):
    """Site files of every block file, `jobs` processes at a time; returns their paths and counts."""
    out.mkdir(parents=True, exist_ok=True)
    tasks = [(pbf, pbf.name.removesuffix(".osm.pbf"), out / f"{pbf.name.removesuffix('.osm.pbf')}.npz")
             for pbf in blocks]
    counts = {}
    with ProcessPoolExecutor(max_workers=jobs, initializer=_load_areas, initargs=(area_specs,)) as pool:
        for region, found in pool.map(_sites, tasks):
            counts[region] = found
    return [task[2] for task in tasks], counts


def stage(source, source_sha256, elevation, terrain, area_specs, out, block=BLOCK_DEGREES,
          margin=MARGIN_DEGREES, jobs=6):
    """Write `out`'s roads, record and fixed sites; returns the record."""
    if out.exists() and any(out.iterdir()):
        raise ValueError(f"{out} is not empty")
    out.mkdir(parents=True, exist_ok=True)
    work = out / "work"
    started = time.monotonic()
    cells = terrain_cells(terrain)
    blocks = blocks_of(cells, block)
    regions = regions_of(blocks, block)
    log(f"{len(cells)} terrain cells in {len(blocks)} blocks of {block} degrees, {len(regions)} regions")

    filtered = work / "filtered.osm.pbf"
    work.mkdir()
    run("osmium", "tags-filter", source, *FILTER, "-o", filtered)
    log(f"filtered: {filtered.stat().st_size} bytes")
    region_files = [(f"region-{index}.osm.pbf", bbox_of(group, block, margin)) for index, group in enumerate(regions)]
    extract(filtered, region_files, work / "regions")
    filtered.unlink()
    block_files = []
    for (region_file, _), group in zip(region_files, regions):
        named = [(f"{block_name(corner, block)}.osm.pbf", bbox_of([corner], block, margin)) for corner in group]
        if len(named) == 1:
            (work / "regions" / region_file).rename(work / "regions" / named[0][0])
            block_files.append(work / "regions" / named[0][0])
            continue
        extract(work / "regions" / region_file, named, work / "blocks")
        (work / "regions" / region_file).unlink()
        block_files.extend(work / "blocks" / name for name, _ in named)
    log(f"{len(block_files)} block extracts")

    site_files, counts = find_sites(block_files, area_specs, out / "sites", jobs)
    shutil.rmtree(work / "regions", ignore_errors=True)
    shutil.rmtree(work / "blocks", ignore_errors=True)
    by_kind = {}
    for found in counts.values():
        for kind, number in found.items():
            by_kind[kind] = by_kind.get(kind, 0) + number
    log(f"sites (before the blocks' overlaps are merged): {by_kind}")

    roads_identity = {"file": Path(source).name, "bytes": Path(source).stat().st_size, "sha256": source_sha256}
    record, fixed = crossing_split.run(source, site_files, elevation, out / ROADS, work=work, jobs=jobs, log=log,
                                       roads_identity=roads_identity)
    record["stage"] = {
        "schema": SCHEMA, "filter": list(FILTER), "blockDegrees": block, "marginDegrees": margin,
        "terrainCells": len(cells), "blocks": len(blocks), "regions": [bbox for _, bbox in region_files],
        "areas": [spec.partition("=")[0] for spec in area_specs], "sitesFound": by_kind,
        "seconds": round(time.monotonic() - started),
    }
    (out / RECORD).write_text(json.dumps(record, indent=1) + "\n")
    with gzip.open(out / "fixed-sites.json.gz", "wt") as stream:
        json.dump(fixed, stream)
    shutil.rmtree(work)
    log(f"done in {record['stage']['seconds']} s: {record['fixedSites']} sites fixed, "
        f"{record['waysChanged']} ways changed")
    return record


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", required=True, type=Path, help="The OSM file the graded graph is built from")
    parser.add_argument("--source-sha256", required=True, help="Its SHA-256, checked by the download")
    parser.add_argument("--elevation", required=True, type=Path, help="The hybrid tiles the graph is graded with")
    parser.add_argument("--terrain", required=True, type=Path, help="The terrain tiles, with cells.txt")
    parser.add_argument("--sources", required=True, type=Path,
                        help="elevation-sources.json: a site counts only inside a terrain source's area")
    parser.add_argument("--out", required=True, type=Path, help="An empty directory")
    parser.add_argument("--block", type=int, default=BLOCK_DEGREES)
    parser.add_argument("--margin", type=float, default=MARGIN_DEGREES)
    parser.add_argument("--jobs", type=int, default=6)
    args = parser.parse_args(argv)
    if not 1 <= args.block <= 30 or 180 % args.block or not 0 < args.margin < 1:
        parser.error("--block must divide 180 and --margin lie between 0 and 1 degree")
    if len(args.source_sha256) != 64 or set(args.source_sha256) - set("0123456789abcdef"):
        parser.error("--source-sha256 takes the 64 hex digits of the source's SHA-256")
    if not 1 <= args.jobs <= 64:
        parser.error("--jobs must be between 1 and 64")
    sources = build_elevation.load_terrain_sources(args.sources)
    stage(args.source, args.source_sha256, args.elevation, args.terrain,
          [f"{source.id}={source.area}" for source in sources], args.out, args.block, args.margin, args.jobs)


if __name__ == "__main__":
    main()
