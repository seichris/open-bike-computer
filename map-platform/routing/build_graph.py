#!/usr/bin/env python3
"""Build one Valhalla bicycle archive from a checksum-verified OSM snapshot.

`worldwide-gap` clips the planet to the coverage mask (the places Apple Maps
has no cycling directions, plus border bands). `planet` keeps the whole planet
for Create a Route's Road, Gravel and Everyday routes everywhere.
"""

import argparse
import hashlib
import json
import os
import re
import sqlite3
import struct
import subprocess
import tarfile
from pathlib import Path


IMAGE = "ghcr.io/valhalla/valhalla-scripted@sha256:b523b803483d1b0e5f3cd506e8b55b010d0477e614a152c1f833c4451ede8228"
PLATFORM = "linux/amd64"
ARCHIVE_NAME = "valhalla_tiles.tar"
INDEX_ENTRY = struct.Struct("<QLL")
TILE_PATH = re.compile(r"([0-2])/([0-9]{3}(?:/[0-9]{3}){1,2})\.gph")
ROUTING_RELATIONS = ("r/type=restriction,restriction:bicycle", "r/route=ferry,bicycle")
COVERAGES = ("worldwide-gap", "planet")
PLANET_URL = re.compile(r"https://planet\.openstreetmap\.org/pbf/planet-[0-9]{6}\.osm\.pbf")


def file_identity(path):
    with path.open("rb") as stream:
        sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"bytes": path.stat().st_size, "sha256": sha256}


def archive_tile_count(path):
    archive_size = path.stat().st_size
    with tarfile.open(path, "r:") as archive:
        index = archive.next()
        if (
            index is None or not index.isfile() or index.name != "index.bin"
            or index.offset_data != tarfile.BLOCKSIZE
            or index.size == 0 or index.size >= archive_size or index.size % INDEX_ENTRY.size
        ):
            raise ValueError("Archive must start with a nonempty Valhalla index")
        records = archive.extractfile(index).read()
        locations = {}
        tile_ids = set()
        for member in archive:
            if member is index:
                continue
            match = TILE_PATH.fullmatch(member.name)
            if not member.isfile() or not match or not member.size:
                raise ValueError(f"Unexpected Valhalla archive member: {member.name}")
            level, tile = match.groups()
            tile_id = (int(tile.replace("/", "")) << 3) | int(level)
            if tile_id in tile_ids or member.offset_data + member.size > archive_size:
                raise ValueError(f"Duplicate or truncated Valhalla tile: {member.name}")
            locations[member.offset_data] = (tile_id, member.size)
            tile_ids.add(tile_id)
        for offset, tile_id, size in INDEX_ENTRY.iter_unpack(records):
            if locations.pop(offset, None) != (tile_id, size):
                raise ValueError(f"Invalid Valhalla index at tile {tile_id}")
        if locations:
            raise ValueError("Valhalla index does not cover every tile")
        return len(tile_ids)


def run(*command):
    print(f"+ {' '.join(map(str, command))}", flush=True)
    subprocess.run(command, check=True)


def valhalla_build(work, admin_input, roads, threads):
    log_path = work / "valhalla-build.log"
    # Every mounted input is local. The container has no network or cloud credentials.
    script = """
valhalla_build_config --mjolnir-tile-dir /work/tiles \\
  --mjolnir-tile-extract /work/valhalla_tiles.tar --mjolnir-admin /work/admin.sqlite \\
  --mjolnir-concurrency "$1" > /work/valhalla.json
valhalla_build_admins -c /work/valhalla.json /input/admin.osm.pbf
test -s /work/admin.sqlite
valhalla_build_tiles -c /work/valhalla.json -j "$1" /input/roads.osm.pbf
valhalla_build_extract -c /work/valhalla.json
"""
    with log_path.open("w") as log:
        subprocess.run(
            [
                "docker", "run", "--rm", "--network", "none", "--platform", PLATFORM,
                "--user", f"{os.getuid()}:{os.getgid()}",
                "--volume", f"{work}:/work",
                "--volume", f"{admin_input}:/input/admin.osm.pbf:ro",
                "--volume", f"{roads}:/input/roads.osm.pbf:ro",
                "--entrypoint", "/bin/bash", IMAGE, "-euc", script, "_", str(threads),
            ],
            check=True, stdout=log, stderr=subprocess.STDOUT,
        )
    log = log_path.read_text(errors="replace")
    if re.search(r"Admin db.*not found|Not saving admin information", log, re.IGNORECASE):
        raise ValueError(f"Valhalla did not use the administrative database: {log_path}")
    with sqlite3.connect(f"file:{work / 'admin.sqlite'}?mode=ro", uri=True) as database:
        count = database.execute("SELECT count(*) FROM admins").fetchone()[0]
    if count == 0:
        raise ValueError("Valhalla administrative database contains no boundaries")


def prepare_inputs(source, work, mask):
    admin = work / "admin.osm.pbf"
    run("osmium", "tags-filter", source, "r/boundary=administrative", "-o", admin)
    roads = source
    if mask is not None:
        clipped = work / "complete-ways.osm.pbf"
        relation_ids = work / "routing-relation-ids.osm.pbf"
        closure = work / "routing-relation-closure.osm.pbf"
        roads = work / "roads.osm.pbf"
        run(
            "osmium", "extract", "-p", mask, "--strategy", "complete_ways",
            source, "-o", clipped,
        )
        run("osmium", "tags-filter", "--omit-referenced", clipped, *ROUTING_RELATIONS, "-o", relation_ids)
        run("osmium", "getid", "--add-referenced", source, "-I", relation_ids, "-o", closure)
        # Both files came from the same immutable snapshot. Every copy of an
        # object therefore has the same version and tags.
        run("osmium", "merge", clipped, closure, "-o", roads)
    run("osmium", "check-refs", roads)
    relations = work / "routing-relations.osm.pbf"
    run("osmium", "tags-filter", roads, *ROUTING_RELATIONS, "-o", relations)
    run("osmium", "check-refs", "--check-relations", relations)
    return admin, roads


def argument_error(coverage, sample, mask, source_url):
    """Why this combination cannot build a release, or None."""
    if sample:
        return None
    if not PLANET_URL.fullmatch(source_url):
        return "Release builds require a dated OpenStreetMap planet snapshot"
    if coverage == "worldwide-gap" and mask is None:
        return "Worldwide-gap builds require a mask"
    if coverage == "planet" and mask is not None:
        return "Planet builds keep the whole planet and take no mask"
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--source-url", required=True, help="Dated source or source receipt")
    parser.add_argument("--work", required=True, type=Path, help="A new build directory on scratch")
    parser.add_argument("--threads", type=int, default=8)
    parser.add_argument("--mask", type=Path, help="Inclusion mask")
    parser.add_argument("--coverage", choices=COVERAGES, default="worldwide-gap")
    parser.add_argument("--sample", action="store_true", help="Build a development sample")
    parser.add_argument("--policy", type=Path, default=Path(__file__).with_name("coverage.json"))
    args = parser.parse_args()
    if not 1 <= args.threads <= 64:
        parser.error("--threads must be between 1 and 64")
    error = argument_error(args.coverage, args.sample, args.mask, args.source_url)
    if error:
        parser.error(error)
    source = args.source.resolve(strict=True)
    source_identity = file_identity(source)
    if source_identity["sha256"] != args.source_sha256:
        parser.error("Source SHA-256 does not match")
    work = args.work.resolve()
    mask = args.mask.resolve(strict=True) if args.mask else None
    mask_identity = file_identity(mask) if mask else None
    policy_identity = file_identity(args.policy) if mask else None
    work.mkdir(mode=0o700)
    admin, roads = prepare_inputs(source, work, mask)
    print(f"Building Valhalla graph. Log: {work / 'valhalla-build.log'}", flush=True)
    valhalla_build(work, admin, roads, args.threads)
    archive = work / ARCHIVE_NAME
    manifest = {
        "schema": "bicino-valhalla-graph-v1",
        "coverage": "development-sample" if args.sample else args.coverage,
        "source": {"url": args.source_url, **source_identity},
        "mask": mask_identity,
        "policy": policy_identity,
        "builder": {"image": IMAGE, "platform": PLATFORM, "threads": args.threads},
        "configuration": file_identity(work / "valhalla.json"),
        "admin": file_identity(work / "admin.sqlite"),
        "maskedInputBytes": roads.stat().st_size,
        "archive": {"name": ARCHIVE_NAME, "tiles": archive_tile_count(archive), **file_identity(archive)},
    }
    report = work / "manifest.json"
    with report.open("x") as stream:
        json.dump(manifest, stream, indent=2)
        stream.write("\n")
    print(f"Verified archive manifest: {report}", flush=True)


if __name__ == "__main__":
    main()
