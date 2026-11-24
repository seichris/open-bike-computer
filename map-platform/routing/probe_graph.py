#!/usr/bin/env python3
"""Probe one private Valhalla service with fixed synthetic bicycle requests."""

import argparse
import json
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


NO_ROUTE = {170, 171, 442, 443}


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


def probe(origin, fixture):
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
    length = trip.get("summary", {}).get("length", 0)
    error_code = result.get("error_code")
    if fixture["route"]:
        passed = length > 0 and modes == ["bicycle"] and all(leg.get("shape") for leg in legs)
    else:
        passed = error_code in NO_ROUTE
    return {
        "name": fixture["name"], "passed": passed, "seconds": round(elapsed, 3),
        "distanceKm": length, "modes": modes, "upstreamError": error_code,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--origin", default="http://127.0.0.1:8002")
    parser.add_argument("--version", default="3.9.2")
    parser.add_argument("--probes", type=Path, default=Path(__file__).with_name("probes.json"))
    parser.add_argument("--concurrency", type=int, choices=range(1, 5), default=1)
    args = parser.parse_args()
    fixtures = json.loads(args.probes.read_text())
    if not fixtures:
        parser.error("At least one probe is required")
    live = status(args.origin)
    if live.get("version") != args.version:
        raise SystemExit(f"Expected Valhalla {args.version}, got {live.get('version')}")
    with ThreadPoolExecutor(max_workers=args.concurrency) as workers:
        results = list(workers.map(lambda item: probe(args.origin, item), fixtures))
    print(json.dumps({"valhalla": live, "probes": results}, indent=2))
    if not all(item["passed"] for item in results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
