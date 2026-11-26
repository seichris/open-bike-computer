#!/usr/bin/env python3
"""Compare bicycle graphs graded with different elevation sources.

Elevation lets Valhalla's ``use_hills`` steer bicycle routes around climbs.
A good source changes routes where there are real hills and nothing where the
ground is flat. A surface model (Copernicus GLO-30) reads buildings and trees
as terrain: on 2026-11-24 it lengthened flat-city Everyday legs by up to 21%.

``run`` routes every leg of elevation-probes.json on an ungraded graph and on
one or more graded graphs of the same OSM data, with the backend's exact
Road and Everyday request bodies (``upstream_body``):

- the graded route's length against the ungraded route's;
- the share of each route's length on edges whose steepest 60 m section has a
  grade of 6% or more, read back from the graded graph with
  ``/trace_attributes`` (``walk_or_snap``). The ungraded route is measured on
  the graded graph too, to show how steep the source thinks the streets are
  even where the router went around them;
- for legs in hilly cities, the Everyday route with ``use_hills`` 0 and 1 on
  every graph. Valhalla's ``use_hills`` is the rider's willingness to climb:
  0 avoids hills hardest, 1 not at all. Both routes are measured on every
  graded graph: the 6%+ share, and the climb from ``/height`` every 20 m,
  counting a rise once it reaches 3 m so that DEM noise does not add up.
  Hill avoidance works when the two routes differ and the ``use_hills`` 0
  route has less of its length on 6%+ grades. Valhalla penalises grade, not
  total ascent, so that route may climb as much or more, more gently; climb
  is reported, not judged. A source judged on its own heights always looks
  good, so routes are judged on the mean over every graded graph, or on one
  graph with ``summary --referee``. The ungraded graph must give the same
  route for both.

``summary`` reads one or more ``run`` reports, prints a table per source and
city, and fails when a source misses the targets:

- flat cities: median length change at most 1%, no leg more than 5% longer,
  median 6%+ share at most 5%;
- hilly cities: at least half the legs change with ``use_hills``, and over
  the legs that change, the hill-avoiding route has less of its length on
  6%+ grades at the median. The table also counts the legs where it has
  more than 2 points more; on 2026-11-25 every source, Copernicus included,
  had one or two such legs out of 16;
- every measurement: a route, ``/trace_attributes`` lookup or changed hilly
  leg that could not be measured is a missed target, so a failing service
  cannot hide a detour.

A city marked ``reportOnly`` is routed and tabulated like the others but
never counts toward a target: hilly high-rise cores such as Hong Kong, where
a longer graded route can be right, are left for a person to judge.

Run it from the map-backend environment against private Valhalla services that
serve each graph and, for graded graphs, its elevation tiles (for /height):

    tools/dev-env --map-backend python map-platform/routing/compare_elevation.py run \\
        --city Amsterdam --ungraded http://127.0.0.1:18100 \\
        --graded copernicus=http://127.0.0.1:18101 --graded gedtm30=http://127.0.0.1:18102 \\
        --out amsterdam.json
    tools/dev-env --map-backend python map-platform/routing/compare_elevation.py summary *.json

Coordinates are synthetic fixtures; reports contain no rider data.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Callable

BACKEND = Path(__file__).resolve().parents[1] / "backend"
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))

from map_platform.bicycle_route_service import parse_request, upstream_body  # noqa: E402

PROFILES = ("road", "everyday")
HILL_PROFILE = "everyday"
STEEP_GRADE = 6
CLIMB_SAMPLE_METRES = 20
CLIMB_HYSTERESIS_METRES = 3
GRADE_ATTRIBUTES = ["edge.length", "edge.max_upward_grade", "edge.max_downward_grade", "edge.weighted_grade"]
TARGETS = {
    "flatMedianLengthChange": 0.01,
    "flatMaximumLengthChange": 0.05,
    "flatMedianSteepShare": 0.05,
    "hillyChangedShare": 0.5,
    "steepShareTolerance": 0.02,
}

Post = Callable[[str, str, dict], tuple[int, dict]]


def http_post(origin: str, path: str, body: dict, timeout: float = 60) -> tuple[int, dict]:
    request = urllib.request.Request(origin.rstrip("/") + path, json.dumps(body).encode(),
                                     {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        try:
            return error.code, json.load(error)
        except ValueError:
            return error.code, {}


def decode_polyline6(encoded: str) -> list[tuple[float, float]]:
    points, index, latitude, longitude = [], 0, 0, 0
    while index < len(encoded):
        deltas = []
        for _ in range(2):
            shift = result = 0
            while True:
                byte = ord(encoded[index]) - 63
                index += 1
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20:
                    break
            deltas.append(~(result >> 1) if result & 1 else result >> 1)
        latitude += deltas[0]
        longitude += deltas[1]
        points.append((latitude / 1e6, longitude / 1e6))
    return points


def route_body(leg: dict, profile: str, use_hills: float | None = None) -> dict:
    """The backend's exact /route body for one leg, optionally with another use_hills."""
    def point(value):
        return {"latitudeE6": round(value[0] * 1_000_000), "longitudeE6": round(value[1] * 1_000_000)}

    request = parse_request({
        "schema": "bicino-bicycle-route-request-v1", "requestId": str(uuid.uuid4()),
        "origin": point(leg["origin"]), "destination": point(leg["destination"]),
        "profile": profile, "locale": "en-US",
    }, maximum_separation_meters=150_000)
    body = json.loads(upstream_body(request))
    if use_hills is not None:
        body["costing_options"]["bicycle"]["use_hills"] = use_hills
    return body


def route(post: Post, origin: str, body: dict) -> dict:
    status, answer = post(origin, "/route", body)
    if status != 200:
        return {"error": f"{status}/{answer.get('error_code')}"}
    trip = answer["trip"]
    shape = trip["legs"][0]["shape"]
    return {"km": round(trip["summary"]["length"], 3), "minutes": round(trip["summary"]["time"] / 60, 1),
            "shape": shape}


def steep_share(edges: list[dict], threshold: float = STEEP_GRADE) -> dict:
    """Share of length on edges with a 60 m section at `threshold`% or steeper, up or down."""
    total = sum(edge.get("length", 0) for edge in edges)
    if total <= 0:
        return {"share": None, "meanAbsWeightedGrade": None}
    steep = sum(edge.get("length", 0) for edge in edges
                if edge.get("max_upward_grade", 0) >= threshold or edge.get("max_downward_grade", 0) <= -threshold)
    weighted = sum(abs(edge.get("weighted_grade", 0)) * edge.get("length", 0) for edge in edges)
    return {"share": round(steep / total, 4), "meanAbsWeightedGrade": round(weighted / total, 2)}


def grades(post: Post, origin: str, shape: str, costing_options: dict) -> dict:
    status, answer = post(origin, "/trace_attributes", {
        "encoded_polyline": shape, "shape_match": "walk_or_snap", "costing": "bicycle",
        "costing_options": costing_options,
        "filters": {"attributes": GRADE_ATTRIBUTES, "action": "include"},
    })
    if status != 200:
        return {"share": None, "error": f"{status}/{answer.get('error_code')}"}
    return steep_share(answer.get("edges", []))


def total_climb(heights: list[float], hysteresis: float = CLIMB_HYSTERESIS_METRES) -> float:
    """Metres climbed, counting a rise only once it is `hysteresis` above the lowest point since."""
    gained, low = 0.0, heights[0]
    for height in heights[1:]:
        if height - low >= hysteresis:
            gained += height - low
            low = height
        elif height < low:
            low = height
    return round(gained, 1)


def climb(post: Post, origin: str, shape: str) -> float | None:
    """Metres climbed along the shape, from the graph's heights every 20 m."""
    points = [{"lat": latitude, "lon": longitude} for latitude, longitude in decode_polyline6(shape)]
    status, answer = post(origin, "/height", {"shape": points, "resample_distance": CLIMB_SAMPLE_METRES,
                                              "range": False})
    heights = [h for h in answer.get("height", []) if h is not None] if status == 200 else []
    return total_climb(heights) if len(heights) >= 2 else None


def length_change(graded: dict, ungraded: dict) -> float | None:
    if "km" not in graded or not ungraded.get("km"):
        return None
    return round(graded["km"] / ungraded["km"] - 1, 4)


def compare_leg(post: Post, city: dict, leg: dict, ungraded: str, graded: dict[str, str]) -> dict:
    row: dict[str, Any] = {"city": city["city"], "terrain": city["terrain"], "leg": leg["name"], "profiles": {}}
    if city.get("reportOnly"):
        row["reportOnly"] = True
    for profile in PROFILES:
        body = route_body(leg, profile)
        options = body["costing_options"]
        base = route(post, ungraded, body)
        item: dict[str, Any] = {"ungraded": {k: v for k, v in base.items() if k != "shape"}, "sources": {}}
        for name, origin in graded.items():
            answer = route(post, origin, body)
            result = {k: v for k, v in answer.items() if k != "shape"}
            if "shape" in answer:
                result["lengthChange"] = length_change(answer, base)
                result["sameRoute"] = answer["shape"] == base.get("shape")
                result["grades"] = grades(post, origin, answer["shape"], options)
            if "shape" in base:
                result["ungradedRouteGrades"] = grades(post, origin, base["shape"], options)
            item["sources"][name] = result
        row["profiles"][profile] = item
    if city["terrain"] == "hilly":
        row["hills"] = {}
        for name, origin in {"ungraded": ungraded, **graded}.items():
            bodies = [route_body(leg, HILL_PROFILE, hills) for hills in (0.0, 1.0)]
            routes = [route(post, origin, body) for body in bodies]
            result: dict[str, Any] = {"differs": None}
            if all("shape" in answer for answer in routes):
                result["differs"] = routes[0]["shape"] != routes[1]["shape"]
                result["km"] = [answer["km"] for answer in routes]
                # Each route on each graded graph: how steep and how much climb that DEM sees.
                result["measures"] = {
                    judge: {"steepShare": [grades(post, judge_origin, answer["shape"],
                                                  body["costing_options"]).get("share")
                                           for answer, body in zip(routes, bodies)],
                            "climb": [climb(post, judge_origin, answer["shape"]) for answer in routes]}
                    for judge, judge_origin in graded.items()
                } if name != "ungraded" else {}
            else:
                result["error"] = next(answer["error"] for answer in routes if "error" in answer)
            row["hills"][name] = result
    return row


def run(post: Post, cities: list[dict], ungraded: str, graded: dict[str, str],
        progress: Callable[[str], None] = lambda line: None) -> dict:
    rows = []
    for city in cities:
        for leg in city["legs"]:
            rows.append(compare_leg(post, city, leg, ungraded, graded))
            progress(f"{city['city']}: {leg['name']}")
    return {"schema": "bicino-elevation-comparison-v1", "sources": list(graded), "rows": rows}


def _median(values: list[float]) -> float | None:
    return round(statistics.median(values), 4) if values else None


def hill_effect(hills: dict, judges: list[str] | None, targets: dict = TARGETS) -> dict | None:
    """What avoiding hills (use_hills 0 instead of 1) saved on one leg.

    Averaged over the heights of `judges`, or of every graded graph when None.
    """
    measures = hills.get("measures", {})
    chosen = [measures[judge] for judge in (judges or measures) if judge in measures]
    steep = [m["steepShare"] for m in chosen if None not in m["steepShare"]]
    if not hills.get("differs") or not steep:
        return None
    # Climb needs /height; the judged 6%+ share does not.
    climbs = [m["climb"] for m in chosen if None not in m["climb"]]
    steep_saved = statistics.mean(after - before for before, after in steep)
    climb_saved = round(statistics.mean(after - before for before, after in climbs), 1) if climbs else None
    return {"climbSaved": climb_saved, "steepShareSaved": round(steep_saved, 4),
            "worse": steep_saved < -targets["steepShareTolerance"]}


def summarize(reports: list[dict], targets: dict = TARGETS,
              referee: str | None = None) -> tuple[list[dict], dict[str, list[str]]]:
    """Per source and city figures, and each source's missed targets.

    Hill avoidance is judged on the `referee` graph's heights, or on the mean
    over every graded graph when there is no referee. Report-only cities are
    tabulated but never judged.
    """
    rows = [row for report in reports for row in report["rows"]]
    sources = sorted({name for report in reports for name in report["sources"]})
    table, failures = [], {}
    for source in sources:
        missed = []
        pooled: dict[str, list[float]] = {"flatChange": [], "flatShare": []}
        changed = hilly = route_errors = trace_errors = hill_errors = unmeasured = 0
        steep_saved: list[float] = []
        for city in dict.fromkeys(row["city"] for row in rows):
            city_rows = [row for row in rows if row["city"] == city]
            judged = not any(row.get("reportOnly") for row in city_rows)
            changes, shares, base_shares, city_route_errors, city_trace_errors = [], [], [], 0, 0
            for row in city_rows:
                for item in row["profiles"].values():
                    result = item["sources"].get(source)
                    if result is None:
                        continue
                    if result.get("lengthChange") is None:
                        city_route_errors += 1
                        continue
                    changes.append(result["lengthChange"])
                    for key, values in (("grades", shares), ("ungradedRouteGrades", base_shares)):
                        share = (result.get(key) or {}).get("share")
                        if share is None:
                            city_trace_errors += 1
                        else:
                            values.append(share)
            entry = {"source": source, "city": city, "terrain": city_rows[0]["terrain"], "routes": len(changes),
                     "errors": city_route_errors + city_trace_errors, "medianLengthChange": _median(changes),
                     "maximumLengthChange": max(changes) if changes else None,
                     "medianSteepShare": _median(shares), "medianUngradedRouteSteepShare": _median(base_shares)}
            if not judged:
                entry["reportOnly"] = True
            hills = [row["hills"][source] for row in city_rows if source in row.get("hills", {})]
            effects = [hill_effect(h, [referee] if referee else None, targets) for h in hills]
            if hills:
                entry["errors"] += sum(1 for h in hills if h.get("error"))
                measured = [effect for effect in effects if effect]
                entry.update({"hillLegs": len(hills), "hillLegsChanged": sum(1 for h in hills if h.get("differs")),
                              "medianClimbSaved": _median([e["climbSaved"] for e in measured
                                                           if e["climbSaved"] is not None]),
                              "medianSteepShareSaved": _median([e["steepShareSaved"] for e in measured]),
                              "hillLegsWorse": sum(e["worse"] for e in measured)})
            table.append(entry)
            if not judged:
                continue
            route_errors += city_route_errors
            trace_errors += city_trace_errors
            if entry["terrain"] == "flat":
                pooled["flatChange"] += changes
                pooled["flatShare"] += shares
            if hills:
                unmeasured += sum(1 for h, e in zip(hills, effects) if h.get("differs") and e is None)
                hill_errors += sum(1 for h in hills if h.get("error"))
                hilly += len(hills)
                changed += entry["hillLegsChanged"]
                steep_saved += [e["steepShareSaved"] for e in effects if e]
        if route_errors:
            missed.append(f"{route_errors} routes failed on the graded or ungraded graph")
        if trace_errors:
            missed.append(f"{trace_errors} grade lookups failed")
        if hill_errors:
            missed.append(f"{hill_errors} hilly legs failed to route")
        if unmeasured:
            missed.append(f"{unmeasured} changed hilly legs have no 6%+ share on "
                          f"{referee or 'any graded graph'}")
        if pooled["flatChange"]:
            median_change = statistics.median(pooled["flatChange"])
            if abs(median_change) > targets["flatMedianLengthChange"]:
                missed.append(f"flat median length change {median_change:+.1%}")
            if max(pooled["flatChange"]) > targets["flatMaximumLengthChange"]:
                missed.append(f"a flat leg is {max(pooled['flatChange']):+.1%} longer")
        if pooled["flatShare"] and statistics.median(pooled["flatShare"]) > targets["flatMedianSteepShare"]:
            missed.append(f"flat median 6%+ share {statistics.median(pooled['flatShare']):.0%}")
        if hilly:
            if changed < targets["hillyChangedShare"] * hilly:
                missed.append(f"use_hills changed {changed} of {hilly} hilly legs")
            if steep_saved and statistics.median(steep_saved) <= 0:
                missed.append(f"avoiding hills did not lower the 6%+ share (median "
                              f"{statistics.median(steep_saved) * 100:+.0f} pts on "
                              f"{referee or 'the mean of all heights'})")
        failures[source] = missed
    # Without elevation use_hills has nothing to act on; a change means the
    # comparison itself is broken (different OSM data or costing).
    ungraded_hills = [row["hills"]["ungraded"] for row in rows
                      if "ungraded" in row.get("hills", {}) and not row.get("reportOnly")]
    ungraded = [f"use_hills changed {n} hilly legs without elevation"
                for n in [sum(1 for h in ungraded_hills if h.get("differs"))] if n]
    ungraded += [f"{n} hilly legs failed to route without elevation"
                 for n in [sum(1 for h in ungraded_hills if h.get("error"))] if n]
    if ungraded:
        failures["ungraded"] = ungraded
    return table, failures


def format_table(table: list[dict]) -> str:
    def percent(value):
        return "–" if value is None else f"{value:+.1%}" if value else "0.0%"

    def share(value):
        return "–" if value is None else f"{value:.0%}"

    lines = ["| Source | City | Routes | Median length | Longest | 6%+ share | 6%+ on ungraded route"
             " | use_hills changed | Worse | Median climb saved | Median 6%+ share saved |",
             "|---|---|---|---|---|---|---|---|---|---|---|"]
    for entry in table:
        hilly = "hillLegs" in entry
        climb_saved, steep_saved = entry.get("medianClimbSaved"), entry.get("medianSteepShareSaved")
        lines.append(" | ".join([
            f"| {entry['source']}", entry["city"] + (" (report only)" if entry.get("reportOnly") else ""),
            f"{entry['routes']}" + (f" ({entry['errors']} failed)" if entry["errors"] else ""),
            percent(entry["medianLengthChange"]), percent(entry["maximumLengthChange"]),
            share(entry["medianSteepShare"]), share(entry["medianUngradedRouteSteepShare"]),
            f"{entry['hillLegsChanged']}/{entry['hillLegs']}" if hilly else "–",
            f"{entry['hillLegsWorse']}" if hilly else "–",
            "–" if climb_saved is None else f"{climb_saved:.0f} m",
            "–" if steep_saved is None else f"{steep_saved * 100:+.0f} pts",
        ]) + " |")
    return "\n".join(lines)


def parse_graded(values: list[str]) -> dict[str, str]:
    graded = {}
    for value in values:
        name, separator, origin = value.partition("=")
        if not separator or not name or not origin.startswith("http") or name in graded or name == "ungraded":
            raise ValueError(f"--graded takes a unique NAME=http://origin, got {value!r}")
        graded[name] = origin
    return graded


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    runner = commands.add_parser("run", help="Route every leg and write a report")
    runner.add_argument("--probes", type=Path, default=Path(__file__).with_name("elevation-probes.json"))
    runner.add_argument("--city", action="append", help="Only these cities (repeatable)")
    runner.add_argument("--ungraded", required=True, help="Valhalla serving the graph built without elevation")
    runner.add_argument("--graded", action="append", required=True, help="NAME=origin of a graded graph")
    runner.add_argument("--out", type=Path, required=True)
    summary = commands.add_parser("summary", help="Tabulate reports and check the targets")
    summary.add_argument("reports", nargs="+", type=Path)
    summary.add_argument("--referee", help="Judge hill avoidance on this source's heights")
    summary.add_argument("--json", type=Path, help="Also write the table and verdicts here")
    args = parser.parse_args()
    if args.command == "run":
        try:
            graded = parse_graded(args.graded)
        except ValueError as error:
            parser.error(str(error))
        cities = json.loads(args.probes.read_text())
        if args.city:
            unknown = set(args.city) - {city["city"] for city in cities}
            if unknown:
                parser.error(f"Unknown cities: {', '.join(sorted(unknown))}")
            cities = [city for city in cities if city["city"] in args.city]
        report = run(http_post, cities, args.ungraded, graded,
                     lambda line: print(line, file=sys.stderr, flush=True))
        args.out.write_text(json.dumps(report, indent=1) + "\n")
        return
    reports = [json.loads(path.read_text()) for path in args.reports]
    if any(report.get("schema") != "bicino-elevation-comparison-v1" for report in reports):
        parser.error("Every report must come from compare_elevation.py run")
    if args.referee and any(args.referee not in report["sources"] for report in reports):
        parser.error(f"--referee {args.referee} is not a source of every report")
    table, failures = summarize(reports, referee=args.referee)
    print(format_table(table))
    for source, missed in failures.items():
        print(f"{source}: {'meets the targets' if not missed else 'misses: ' + '; '.join(missed)}")
    if args.json:
        args.json.write_text(json.dumps({"table": table, "failures": failures}, indent=1) + "\n")
    if any(failures.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
