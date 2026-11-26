#!/usr/bin/env python3
"""Cut one city of elevation-probes.json out of a regional extract.

A city sample is a small graph of one city's box, built in minutes on a
laptop, on which an elevation source can be judged before a planet is graded.
This writes the inputs `build_graph.py --sample` needs:

- `roads.osm.pbf`: the city's `bbox`, cut with complete ways;
- `admin.osm.pbf`: the administrative boundaries of the whole extract.
  Valhalla keeps only whole country and state polygons, and the box cuts
  them, so `build_graph.py` takes them from here (`--admin-source`). The
  extract itself can cut them too, and the city then lists what to fetch
  from the OpenStreetMap API and merge in:
  - `adminWays`: members the state's boundary lacks. New York State lacks
    one and Illinois five. Valhalla's build log names them one at a time
    ("Illinois (122586) is missing way member 814758098"), and with no
    boundary at all the build fails;
  - `adminRelations`: the country's relation, complete, where the extract
    is a part of the country. Without it Valhalla writes no `admin_access`
    row, the country's default access rules, and the sample takes other
    ungraded routes than a planet graph (see the refresh runbook, "A sample
    needs the country relation");
- `probes.json`: the city's legs as smoke probes for `probe_graph.py`;
- `sample.json`: what was cut from what, and `elevationBounds`, the
  whole-degree bounds to pass to `build_elevation.py --bounds`.

The city names its Geofabrik extract as `extract`, for example
`north-america/us/illinois`. A city without one is `planetOnly`: nobody has
built it as a sample yet.

    python prepare_sample.py --city Chicago --region illinois-latest.osm.pbf \\
        --region-url https://download.geofabrik.de/north-america/us/illinois-latest.osm.pbf \\
        --out "$scratch/chicago"
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

SCHEMA = "bicino-routing-sample-v1"
GEOFABRIK = "https://download.geofabrik.de/"
OSM_API = "https://api.openstreetmap.org/api/0.6/{}/{}/full"


def file_identity(path):
    with path.open("rb") as stream:
        sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"bytes": path.stat().st_size, "sha256": sha256}


def find_city(cities, name):
    city = next((city for city in cities if city["city"] == name), None)
    if city is None:
        raise ValueError(f"Unknown city: {name}")
    if not city.get("extract"):
        raise ValueError(f"{name} names no Geofabrik extract: it has not been built as a sample")
    return city


def region_url(city, date=None):
    """The city's extract on Geofabrik: the latest, or the one of a YYMMDD date.

    Geofabrik keeps `illinois-latest.osm.pbf` beside the region's folder and
    the dated files, kept for some weeks, inside it.
    """
    extract = city["extract"]
    if date is None:
        return f"{GEOFABRIK}{extract}-latest.osm.pbf"
    return f"{GEOFABRIK}{extract}/{extract.rsplit('/', 1)[-1]}-{date}.osm.pbf"


def check_region_url(city, url):
    extract = city["extract"]
    name = re.escape(extract.rsplit("/", 1)[-1])
    pattern = re.escape(GEOFABRIK + extract) + rf"(-latest|/{name}-(latest|[0-9]{{6}}))\.osm\.pbf"
    if not re.fullmatch(pattern, url):
        raise ValueError(f"{city['city']} is cut from {extract}, not from {url}")


def elevation_bounds(bbox):
    """Whole-degree bounds holding every one-degree cell the box touches."""
    west, south, east, north = bbox
    return [math.floor(west), math.floor(south), math.floor(east) + 1, math.floor(north) + 1]


def smoke_probes(city):
    """The city's legs as probe_graph.py fixtures."""
    return [{"name": f"{city['city']}: {leg['name']}", "points": [leg["origin"], leg["destination"]],
             "route": True, "pushAllowed": True} for leg in city["legs"]]


def run(*command):
    print(f"+ {' '.join(map(str, command))}", flush=True)
    subprocess.run(command, check=True)


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "osm-sample-prep/1"})
    with urllib.request.urlopen(request, timeout=300) as response:
        return response.read()


def prepare(city, region, url, out, run=run, fetch=fetch):
    check_region_url(city, url)
    out.mkdir(parents=True, exist_ok=True)
    west, south, east, north = city["bbox"]
    roads, admin = out / "roads.osm.pbf", out / "admin.osm.pbf"
    run("osmium", "extract", "-b", f"{west},{south},{east},{north}", "--strategy", "complete_ways",
        region, "-o", roads, "--overwrite")
    wanted = [("way", way) for way in city.get("adminWays", [])]
    wanted += [("relation", relation) for relation in city.get("adminRelations", [])]
    boundaries = out / "admin-region.osm.pbf" if wanted else admin
    run("osmium", "tags-filter", region, "r/boundary=administrative", "-o", boundaries, "--overwrite")
    if wanted:
        fetched = []
        for kind, number in wanted:
            answer = out / f"{kind}-{number}.osm"
            answer.write_bytes(fetch(OSM_API.format(kind, number)))
            # The API does not order its answer the way osmium merge needs it.
            run("osmium", "sort", answer, "-o", answer.with_suffix(".osm.pbf"), "--overwrite")
            fetched.append(answer.with_suffix(".osm.pbf"))
        patch, kept = out / "admin-patch.osm.pbf", out / "admin-kept.osm.pbf"
        run("osmium", "merge", *fetched, "-o", patch, "--overwrite")
        # The API's objects are newer than the extract's. Drop the extract's
        # copies so that no object is in the input twice.
        run("osmium", "removeid", boundaries, "-I", patch, "-o", kept, "--overwrite")
        run("osmium", "merge", kept, patch, "-o", admin, "--overwrite")
    (out / "probes.json").write_text(json.dumps(smoke_probes(city), indent=1) + "\n")
    sample = {
        "schema": SCHEMA,
        "city": city["city"],
        "bbox": city["bbox"],
        "elevationBounds": elevation_bounds(city["bbox"]),
        "region": {"url": url, **file_identity(region)},
        "roads": file_identity(roads),
        "admin": file_identity(admin),
        "adminWays": city.get("adminWays", []),
        "adminRelations": city.get("adminRelations", []),
    }
    (out / "sample.json").write_text(json.dumps(sample, indent=1) + "\n")
    return sample


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--city", required=True)
    parser.add_argument("--region", required=True, type=Path, help="The city's Geofabrik extract")
    parser.add_argument("--region-url", required=True, help="Where the extract was downloaded from")
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--probes", type=Path, default=Path(__file__).with_name("elevation-probes.json"))
    args = parser.parse_args(argv)
    try:
        city = find_city(json.loads(args.probes.read_text()), args.city)
        sample = prepare(city, args.region.resolve(strict=True), args.region_url, args.out.resolve())
    except ValueError as error:
        parser.error(str(error))
    print(f"Sample inputs: {args.out.resolve()} (elevation bounds {' '.join(map(str, sample['elevationBounds']))})")


if __name__ == "__main__":
    sys.exit(main())
