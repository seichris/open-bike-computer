#!/usr/bin/env python3
"""Prove that the bicycle route profiles reach Valhalla and change its answer.

Runs every pair in profile-probes.json through the backend's own
``BicycleRouteService`` (the request parser, the exact upstream body and the
response conversion used by ``POST /v1/bicycle-routes``) against one private
Valhalla origin, once per profile. The raw Valhalla answer is kept beside the
app-facing response so the report shows which bicycle type Valhalla applied
(each maneuver's ``travel_type``) and any push-the-bike maneuvers that make a
route ``no_bicycle_route``.

Run it from the map-backend environment against a local, archive-only
Valhalla, for example:

    tools/dev-env --map-backend python map-platform/routing/probe_profiles.py \
        --origin http://127.0.0.1:8002

The probe fails if a profile's maneuvers report a different bicycle type, if a
pair marked ``ready`` is not ready for every profile, or if no pair yields
different road and gravel geometry. Coordinates are synthetic fixtures; the
report contains no rider data.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Callable
from urllib.request import urlopen

BACKEND = Path(__file__).resolve().parents[1] / "backend"
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))

from map_platform.bicycle_route_service import (  # noqa: E402
    PROFILE_NAMES,
    PROFILES,
    REQUEST_SCHEMA,
    BicycleRouteService,
)
from map_platform.route_elevation_providers import UrllibElevationTransport  # noqa: E402


class RecordingTransport:
    """Keeps the last raw upstream answer and its latency."""

    def __init__(self, inner: Any):
        self._inner = inner
        self.last_body: bytes = b""
        self.last_seconds = 0.0

    def request(self, **kwargs: Any) -> Any:
        started = time.monotonic()
        response = self._inner.request(**kwargs)
        self.last_seconds = time.monotonic() - started
        self.last_body = response.body
        return response


def _point(value: list[float]) -> dict[str, int]:
    latitude, longitude = value
    return {"latitudeE6": round(latitude * 1_000_000), "longitudeE6": round(longitude * 1_000_000)}


def _raw_maneuvers(body: bytes) -> list[dict[str, Any]]:
    try:
        trip = json.loads(body).get("trip") or {}
    except (ValueError, AttributeError):
        return []
    return [step for leg in trip.get("legs", []) for step in leg.get("maneuvers", [])]


def probe_pair(service: BicycleRouteService, transport: RecordingTransport, fixture: dict) -> dict[str, Any]:
    results: dict[str, Any] = {}
    for profile in PROFILE_NAMES:
        response = service.create_route({
            "schema": REQUEST_SCHEMA,
            "requestId": str(uuid.uuid4()),
            "origin": _point(fixture["origin"]),
            "destination": _point(fixture["destination"]),
            "profile": profile,
            "locale": "en-US",
        })
        raw = _raw_maneuvers(transport.last_body)
        bicycle_types = sorted({step.get("travel_type") for step in raw if step.get("travel_mode") == "bicycle"})
        pushes = [step for step in raw if step.get("travel_mode") != "bicycle"]
        item: dict[str, Any] = {
            "status": response["status"],
            "reason": response["reason"],
            "upstreamSeconds": round(transport.last_seconds, 3),
            "bicycleTypes": bicycle_types,
            "nonBicycleManeuvers": len(pushes),
            "nonBicycleMeters": round(sum(step.get("length", 0) for step in pushes) * 1000),
        }
        route = response["route"]
        if route is not None:
            item.update({
                "distanceMeters": route["distanceMeters"],
                "durationSeconds": route["durationSeconds"],
                "points": len(route["pointsE6"]),
                "maneuvers": len(route["maneuvers"]),
                "geometrySha256": hashlib.sha256(
                    json.dumps(route["pointsE6"], separators=(",", ":")).encode()
                ).hexdigest()[:16],
            })
        results[profile] = item
    return results


def evaluate(fixture: dict, results: dict[str, Any]) -> list[str]:
    failures = []
    for profile, item in results.items():
        expected_type = PROFILES[profile]["bicycle_type"]
        if item["bicycleTypes"] and item["bicycleTypes"] != [expected_type]:
            failures.append(f"{fixture['name']}: {profile} ran as {item['bicycleTypes']}, expected {expected_type}")
        if fixture.get("ready", True) and item["status"] != "ready":
            failures.append(f"{fixture['name']}: {profile} was {item['reason']}")
    return failures


def geometry_differs(results: dict[str, Any], first: str, second: str) -> bool:
    a, b = results.get(first, {}), results.get(second, {})
    return "geometrySha256" in a and "geometrySha256" in b and a["geometrySha256"] != b["geometrySha256"]


def run(
    origin: str,
    fixtures: list[dict],
    *,
    transport_factory: Callable[[], Any] = UrllibElevationTransport,
    timeout_seconds: float = 15,
) -> tuple[dict[str, Any], list[str]]:
    transport = RecordingTransport(transport_factory())
    service = BicycleRouteService(
        origin,
        transport=transport,
        timeout_seconds=timeout_seconds,
        maximum_concurrent=1,
        maximum_separation_meters=150_000,
    )
    probes, failures = [], []
    for fixture in fixtures:
        results = probe_pair(service, transport, fixture)
        failures.extend(evaluate(fixture, results))
        probes.append({
            "name": fixture["name"],
            "roadGravelGeometryDiffers": geometry_differs(results, "road", "gravel"),
            "profiles": results,
        })
    if not any(item["roadGravelGeometryDiffers"] for item in probes):
        failures.append("no pair produced different road and gravel geometry")
    return {"probes": probes, "failures": failures}, failures


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--origin", default="http://127.0.0.1:8002")
    parser.add_argument("--version", default="3.9.2")
    parser.add_argument("--probes", type=Path, default=Path(__file__).with_name("profile-probes.json"))
    args = parser.parse_args()
    fixtures = json.loads(args.probes.read_text())
    if not fixtures:
        parser.error("At least one probe is required")
    with urlopen(args.origin.rstrip("/") + "/status", timeout=10) as response:
        status = json.load(response)
    if status.get("version") != args.version:
        raise SystemExit(f"Expected Valhalla {args.version}, got {status.get('version')}")
    report, failures = run(args.origin, fixtures)
    print(json.dumps({"valhalla": status, "profiles": {name: dict(PROFILES[name]) for name in PROFILE_NAMES},
                      **report}, indent=2))
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
