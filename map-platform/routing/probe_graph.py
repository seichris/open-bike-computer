#!/usr/bin/env python3
"""Probe one private Valhalla service with fixed synthetic bicycle requests.

A fixture's `route` is its expectation on the worldwide-gap graph; an optional
`planet` value overrides it on a planet graph, and `coverages` limits where it
runs. `pushAllowed` accepts pedestrian push segments of at most
`PUSH_LIMIT_METERS` each alongside bicycle, the same rule the bicycle route
service applies.
"""

import argparse
import json
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


NO_ROUTE = {170, 171, 442, 443}
COVERAGES = ("worldwide-gap", "planet")
PUSH_LIMIT_METERS = 100


def status(origin):
    deadline = time.monotonic() + 75
    while True:
        try:
            with urlopen(origin + "/status", timeout=5) as response:
                return json.load(response)
        except URLError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.5)


def applies(fixture, coverage):
    return coverage in fixture.get("coverages", COVERAGES)


def expects_route(fixture, coverage):
    return fixture.get(coverage, fixture["route"]) if coverage == "planet" else fixture["route"]


def passed(fixture, coverage, legs, modes, length, error_code, longest_push_meters=0.0):
    if not expects_route(fixture, coverage):
        return error_code in NO_ROUTE
    allowed = {"bicycle", "pedestrian"} if fixture.get("pushAllowed") else {"bicycle"}
    return (
        length > 0 and "bicycle" in modes and set(modes) <= allowed
        and longest_push_meters <= PUSH_LIMIT_METERS
        and bool(legs) and all(leg.get("shape") for leg in legs)
    )


def probe(origin, fixture, coverage="worldwide-gap"):
    points = [{"lat": lat, "lon": lon} for lat, lon in fixture["points"]]
    request = Request(
        origin + "/route",
        data=json.dumps({"locations": points, "costing": "bicycle", "units": "kilometers"}).encode(),
        headers={"Content-Type": "application/json"},
    )
    started = time.monotonic()
    try:
        with urlopen(request, timeout=8) as response:
            result = json.load(response)
    except HTTPError as error:
        result = json.load(error)
        error.close()
    elapsed = time.monotonic() - started
    trip = result.get("trip", {})
    legs = trip.get("legs", [])
    maneuvers = [step for leg in legs for step in leg.get("maneuvers", [])]
    modes = sorted({step.get("travel_mode", "missing") for step in maneuvers})
    longest_push = max(
        (step.get("length", 0) * 1000 for step in maneuvers if step.get("travel_mode") == "pedestrian"),
        default=0.0,
    )
    length = trip.get("summary", {}).get("length", 0)
    error_code = result.get("error_code")
    return {
        "name": fixture["name"],
        "passed": passed(fixture, coverage, legs, modes, length, error_code, longest_push),
        "seconds": round(elapsed, 3),
        "distanceKm": length, "modes": modes, "longestPushMeters": round(longest_push),
        "upstreamError": error_code,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--origin", default="http://127.0.0.1:8002")
    parser.add_argument("--version", default="3.9.2")
    parser.add_argument("--probes", type=Path, default=Path(__file__).with_name("probes.json"))
    parser.add_argument("--concurrency", type=int, choices=range(1, 5), default=1)
    parser.add_argument("--coverage", choices=COVERAGES, default="worldwide-gap")
    args = parser.parse_args()
    fixtures = [item for item in json.loads(args.probes.read_text()) if applies(item, args.coverage)]
    if not fixtures:
        parser.error("At least one probe is required")
    live = status(args.origin)
    if live.get("version") != args.version:
        raise SystemExit(f"Expected Valhalla {args.version}, got {live.get('version')}")
    with ThreadPoolExecutor(max_workers=args.concurrency) as workers:
        results = list(workers.map(lambda item: probe(args.origin, item, args.coverage), fixtures))
    print(json.dumps({"valhalla": live, "probes": results}, indent=2))
    if not all(item["passed"] for item in results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
