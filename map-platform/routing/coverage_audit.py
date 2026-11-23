#!/usr/bin/env python3
"""Generate and run a bicycle-routing probe inventory for unlisted map units."""

import argparse
import hashlib
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from probe_graph import probe, status


# Natural Earth v5.1.2, ne_10m_populated_places_simple.geojson.
PLACES_SHA256 = "fd3fa867a320cbd5c5b6bb5bc550afeec2939fb2cef688e508007282a55ac42f"


def generate(policy_path, boundary_dir, places_path):
    # The serving image only needs the standard library for the probe phase.
    from pyproj import Geod
    from shapely.geometry import Point, shape
    from shapely.strtree import STRtree

    from coverage_mask import MAP_UNITS, load_features, polygonal

    policy = json.loads(policy_path.read_text())
    units = load_features(boundary_dir, MAP_UNITS, policy["boundaryFiles"][MAP_UNITS])
    supported = set().union(*policy["appleCyclingMapUnits"].values())
    data = places_path.read_bytes()
    if hashlib.sha256(data).hexdigest() != PLACES_SHA256:
        raise ValueError("Unexpected populated-places snapshot")
    places = json.loads(data)["features"]
    points = [shape(feature["geometry"]) for feature in places]
    lookup = STRtree(points)
    earth = Geod(ellps="WGS84")
    targets = []
    for unit in sorted(units, key=lambda unit: unit["properties"]["GU_A3"]):
        code = unit["properties"]["GU_A3"]
        if code in supported:
            continue
        area = polygonal(shape(unit["geometry"]))
        nearby = lookup.query(area, predicate="covers")
        ranked = sorted(
            nearby,
            key=lambda i: places[i]["properties"]["pop_max"] or 0,
            reverse=True,
        )[:3]
        seeds = [(places[i]["properties"]["name"], points[i]) for i in ranked]
        attrs = unit["properties"]
        if not seeds:
            label = Point(attrs["LABEL_X"], attrs["LABEL_Y"])
            if area.covers(label):
                seeds.append(("map label", label))
            elif not area.is_empty:
                seeds.append(("interior point", area.representative_point()))
        fixtures = []
        for name, origin in seeds:
            for direction in (45, 135, 225, 315):
                lon, lat, _ = earth.fwd(origin.x, origin.y, direction, 500)
                if not area.covers(Point(lon, lat)):
                    continue
                fixtures.append({
                    "name": name,
                    "points": [[origin.y, origin.x], [lat, lon]],
                    "route": True,
                })
        targets.append({"code": code, "name": attrs["GEOUNIT"], "fixtures": fixtures})
    return {"schema": "bicino-routing-inventory-v1", "units": targets}


def check(origin, inventory, workers):
    if inventory.get("schema") != "bicino-routing-inventory-v1" or not inventory.get("units"):
        raise ValueError("Expected a nonempty routing inventory")
    live = status(origin)
    if live.get("version") != "3.9.2":
        raise ValueError(f"Unexpected Valhalla version: {live.get('version')}")

    def check_unit(unit):
        result = {"code": unit["code"], "name": unit["name"], "attempts": 0}
        for fixture in unit["fixtures"]:
            outcome = probe(origin, fixture)
            result["attempts"] += 1
            if outcome["passed"]:
                result.update(state="routed", probe=outcome)
                return result
        result["state"] = "needs-review" if result["attempts"] else "no-fixture"
        return result

    with ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(check_unit, inventory["units"]))
    return {"valhalla": live, "units": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    generate_parser = commands.add_parser("generate")
    generate_parser.add_argument("--policy", type=Path, default=Path(__file__).with_name("coverage.json"))
    generate_parser.add_argument("--boundaries", type=Path, required=True)
    generate_parser.add_argument("--places", type=Path, required=True)
    check_parser = commands.add_parser("check")
    check_parser.add_argument("--origin", default="http://127.0.0.1:8002")
    check_parser.add_argument("--inventory", type=Path, required=True)
    check_parser.add_argument("--concurrency", type=int, choices=range(1, 5), default=2)
    args = parser.parse_args()
    if args.command == "generate":
        result = generate(args.policy, args.boundaries, args.places)
    else:
        result = check(args.origin, json.loads(args.inventory.read_text()), args.concurrency)
    print(json.dumps(result, indent=2))
    if args.command == "check" and any(unit["state"] != "routed" for unit in result["units"]):
        raise SystemExit(2)


if __name__ == "__main__":
    main()
