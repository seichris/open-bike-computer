#!/usr/bin/env python3
"""Generate shared route-elevation fixtures for backend, Swift and firmware tests.

The canonical processing reference is ``map_platform.route_elevation``. This
script adds the reference compact device encoding (display simplification,
ELV1 frames and EAK1 acknowledgements) and writes:

* ``protocol/fixtures/route-elevation-v1/processing.json`` — processing inputs
  and expected outputs consumed by the Python and Swift test suites;
* ``protocol/fixtures/route-elevation-v1/transfer-v1.txt`` — ``name hex``
  device frames consumed by the Swift encoder and C++ decoder tests;
* ``protocol/fixtures/route-elevation-v1/service-response-v1.json`` — a ready
  ``POST /v1/route-elevation-profiles`` answer decoded by the Swift client.

Terrain values are synthetic unless a case's ``provenance`` names an
observation. Run ``--check`` in CI to detect drift.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "map-platform" / "backend"))

from map_platform import route_elevation as rel  # noqa: E402
from map_platform.route_elevation_providers import GEOAPIFY_ATTRIBUTION  # noqa: E402
from map_platform.route_elevation_service import RESPONSE_SCHEMA  # noqa: E402

OUTPUT = ROOT / "protocol" / "fixtures" / "route-elevation-v1"
FIXTURE_SCHEMA = "bicino-route-elevation-fixtures-v1"

DISPLAY_MAXIMUM_POINTS = 160
PROTOCOL_MAXIMUM_POINTS = 192
BODY_VERSION = 1
BODY_HEADER_BYTES = 32
POINT_BYTES = 7
UNKNOWN_ELEVATION = -32768
FRAME_VERSION = 1
OP_STATE = 1
OP_BEGIN = 2
OP_CHUNK = 3
OP_COMMIT = 4
OP_PROGRESS = 5
SOURCE_CODES = {"gpx": 1, "hosted-terrain": 2, "internal-dem": 3}


def destination(lat: float, lon: float, bearing_deg: float, distance_m: float) -> tuple[float, float]:
    radius = rel.EARTH_RADIUS_M
    delta = distance_m / radius
    theta = math.radians(bearing_deg)
    phi1 = math.radians(lat)
    lambda1 = math.radians(lon)
    phi2 = math.asin(math.sin(phi1) * math.cos(delta) + math.cos(phi1) * math.sin(delta) * math.cos(theta))
    lambda2 = lambda1 + math.atan2(
        math.sin(theta) * math.sin(delta) * math.cos(phi1),
        math.cos(delta) - math.sin(phi1) * math.sin(phi2),
    )
    return math.degrees(phi2), (math.degrees(lambda2) + 540.0) % 360.0 - 180.0


def straight_route(lat: float, lon: float, bearing: float, length_m: float, step_m: float) -> list[list[int]]:
    count = int(round(length_m / step_m))
    points = []
    for index in range(count + 1):
        point_lat, point_lon = destination(lat, lon, bearing, index * step_m)
        points.append([round(point_lon * 1_000_000), round(point_lat * 1_000_000)])
    return points


def noise(index: int, amplitude: float) -> float:
    """Deterministic, bounded pseudo-noise without a random-number generator."""

    return ((index * 7919 + 13) % 17 - 8) / 8.0 * amplitude


def geometry_from(points: list[list[int]]) -> rel.RouteGeometry:
    return rel.build_route_geometry([lat for _, lat in points], [lon for lon, _ in points])


def processing_case(name: str, description: str, provenance: str, points: list[list[int]],
                    raw: list[float | None] | None = None, *, vertex_elevations: list[float | None] | None = None,
                    structures: list[dict] | None = None, queries: list[float] = ()) -> dict:
    geometry = geometry_from(points)
    plan = rel.plan_sampling(geometry.length_m)
    if vertex_elevations is not None:
        samples = rel.resample_vertex_elevations(geometry, plan, vertex_elevations)
        source = rel.ElevationSource(kind="gpx", identifier="gpx-ele", interpolation="linear-vertex",
                                     qualification="user-supplied")
        input_payload = {"kind": "vertices", "vertexElevationM": vertex_elevations}
    else:
        assert raw is not None and len(raw) == plan.count, name
        samples = raw
        source = rel.ElevationSource(kind="internal-dem", identifier="fixture-terrain",
                                     interpolation="fixture", qualification="fixture")
        input_payload = {"kind": "samples", "rawElevationM": [rel._optional_round(value, 3) for value in raw]}
        samples = input_payload["rawElevationM"]
    spans = [
        rel.StructureSpan(kind=item["kind"], start_m=item["startM"], end_m=item["endM"],
                          resolution=item["resolution"], way_ids=tuple(item.get("osmWayIds", ())),
                          reason=item.get("reason"))
        for item in structures or []
    ]
    profile = rel.process_profile(geometry, plan, samples, source, structures=spans)
    document = profile.to_dict()
    return {
        "name": name,
        "description": description,
        "provenance": provenance,
        "geometryE6": points,
        "input": input_payload,
        "structures": structures or [],
        "expected": {
            "geometryDigest": document["geometry"]["digest"],
            "lengthM": document["geometry"]["lengthM"],
            "spacingM": document["sampling"]["spacingM"],
            "sampleCount": document["sampling"]["sampleCount"],
            "samples": document["samples"],
            "statistics": document["statistics"],
            "quality": document["quality"],
            "structures": document["structures"],
            "queries": [progress_query(document, distance) for distance in queries],
            "display": display_points(document),
        },
    }


# --- Reference phone-side queries ------------------------------------------------

def _bracket(distances: list[float], distance: float) -> int:
    low, high = 0, len(distances) - 1
    while low < high - 1:
        middle = (low + high) // 2
        if distances[middle] <= distance:
            low = middle
        else:
            high = middle
    return low


def progress_query(document: dict, distance: float) -> dict:
    samples = document["samples"]
    distances = samples["distanceM"]
    elevations = samples["elevationM"]
    grades = samples["gradePercent"]
    cumulative = samples["cumulativeAscentM"]
    flags = samples["flags"]
    total = document["geometry"]["lengthM"]
    distance = min(max(distance, 0.0), total)
    index = _bracket(distances, distance)
    following = min(index + 1, len(distances) - 1)
    span = distances[following] - distances[index]
    fraction = 0.0 if span <= 0 else (distance - distances[index]) / span
    elevation = None
    if elevations[index] is not None and elevations[following] is not None:
        elevation = elevations[index] + fraction * (elevations[following] - elevations[index])
    elevation_estimated = bool((flags[index] | flags[following]) & rel.FLAG_ESTIMATED)
    nearest = following if (distance - distances[index]) > (distances[following] - distance) else index
    grade = grades[nearest]
    grade_estimated = bool(flags[nearest] & rel.FLAG_GRADE_ESTIMATED)
    climbed = None
    if cumulative[index] is not None and cumulative[following] is not None:
        climbed = cumulative[index] + fraction * (cumulative[following] - cumulative[index])
    else:
        for position in range(index, -1, -1):
            if cumulative[position] is not None:
                climbed = cumulative[position]
                break
    total_ascent = document["statistics"]["totalAscentM"]
    remaining = None if total_ascent is None else max(0.0, total_ascent - (climbed or 0.0))
    return {
        "distanceM": distance,
        "elevationM": rel._optional_round(elevation),
        "elevationEstimated": elevation_estimated,
        "gradePercent": grade,
        "gradeEstimated": grade_estimated,
        "ascentRemainingM": rel._optional_round(remaining),
        "ascentRemainingLowerBound": not document["statistics"]["complete"],
    }


# --- Reference device encoding ---------------------------------------------------

def grade_band(grade: float | None) -> int:
    if grade is None:
        return 0
    if grade < -2.0:
        return 1
    if grade < 2.0:
        return 2
    if grade < 4.0:
        return 3
    if grade < 6.0:
        return 4
    if grade < 8.0:
        return 5
    if grade < 10.0:
        return 6
    return 7


def _whole(value: float) -> int:
    return int(rel.round_half_away(value, 0))


def display_points(document: dict, maximum: int = DISPLAY_MAXIMUM_POINTS) -> list[dict]:
    samples = document["samples"]
    distances = samples["distanceM"]
    elevations = samples["elevationM"]
    count = len(distances)
    if count <= maximum:
        selected = list(range(count))
    else:
        buckets = maximum // 2
        while True:
            chosen = {0, count - 1}
            for bucket in range(buckets):
                low = bucket * count // buckets
                high = (bucket + 1) * count // buckets
                position = low
                while position < high:
                    known = elevations[position] is not None
                    end = position
                    while end < high and (elevations[end] is not None) == known:
                        end += 1
                    if not known:
                        chosen.add(position)
                    else:
                        run = range(position, end)
                        chosen.add(min(run, key=lambda item: (elevations[item], item)))
                        chosen.add(max(run, key=lambda item: (elevations[item], -item)))
                        if position > 0 and elevations[position - 1] is None:
                            chosen.add(position)
                        if end < count and elevations[end] is None:
                            chosen.add(end - 1)
                    position = end
            if len(chosen) <= maximum or buckets == 1:
                break
            buckets = max(1, buckets * 9 // 10)
        selected = sorted(chosen)
    points = []
    previous = -1
    for index in selected:
        aggregated = 0
        for position in range(previous + 1, index + 1):
            aggregated |= samples["flags"][position]
        previous = index
        point_flags = grade_band(samples["gradePercent"][index])
        if aggregated & rel.FLAG_ESTIMATED:
            point_flags |= 1 << 3
        if aggregated & rel.FLAG_STRUCTURE_AMBIGUOUS:
            point_flags |= 1 << 4
        if aggregated & (rel.FLAG_BRIDGE | rel.FLAG_TUNNEL):
            point_flags |= 1 << 5
        elevation = elevations[index]
        points.append({
            "sampleIndex": index,
            "distanceM": _whole(distances[index]),
            "elevationM": None if elevation is None else _whole(elevation),
            "flags": point_flags,
        })
    return points


def encode_body(document: dict, route_token: int, revision: int, points: list[dict]) -> bytes:
    statistics = document["statistics"]
    quality = document["quality"]
    flags = 0
    if statistics["complete"]:
        flags |= 1 << 0
    if statistics["includesEstimated"]:
        flags |= 1 << 1
    if quality["status"] == rel.QUALITY_PARTIAL:
        flags |= 1 << 2
    if any(span["resolution"] == rel.STRUCTURE_AMBIGUOUS for span in document["structures"]):
        flags |= 1 << 3
    if statistics["totalAscentM"] is not None:
        flags |= 1 << 4
    if statistics["minimumElevationM"] is not None:
        flags |= 1 << 5
    length = document["geometry"]["lengthM"]
    estimated_permille = 0 if length <= 0 else min(1000, _whole(quality["estimatedDistanceM"] / length * 1000))
    body = struct.pack(
        "<BBBBIHHIIIhhHH",
        BODY_VERSION,
        flags,
        SOURCE_CODES.get(document["source"]["kind"], 0),
        len(points),
        route_token,
        revision,
        min(1000, _whole(quality["coverage"] * 1000)),
        _whole(length),
        _whole(statistics["totalAscentM"] or 0.0),
        _whole(statistics["totalDescentM"] or 0.0),
        _whole(statistics["minimumElevationM"] or 0.0),
        _whole(statistics["maximumElevationM"] or 0.0),
        estimated_permille,
        0,
    )
    assert len(body) == BODY_HEADER_BYTES
    for point in points:
        elevation = UNKNOWN_ELEVATION if point["elevationM"] is None else point["elevationM"]
        body += struct.pack("<IhB", point["distanceM"], elevation, point["flags"])
    return body


def frame_header(op: int) -> bytes:
    return b"ELV1" + bytes([FRAME_VERSION, op])


def state_frame(route_token: int, revision: int, state: int, reason: int) -> bytes:
    return frame_header(OP_STATE) + struct.pack("<IHBB", route_token, revision, state, reason)


def transfer_frames(body: bytes, route_token: int, revision: int, transfer_id: int, chunk_bytes: int) -> list[bytes]:
    chunks = [body[start:start + chunk_bytes] for start in range(0, len(body), chunk_bytes)]
    frames = [frame_header(OP_BEGIN) + struct.pack(
        "<IHHHBBI", route_token, revision, transfer_id, len(body), len(chunks), 0,
        zlib.crc32(body) & 0xFFFFFFFF,
    )]
    for index, chunk in enumerate(chunks):
        frames.append(frame_header(OP_CHUNK) + struct.pack("<HB", transfer_id, index) + chunk)
    frames.append(frame_header(OP_COMMIT) + struct.pack("<H", transfer_id))
    return frames


def progress_frame(route_token: int, revision: int, sequence: int, progress_m: int, query: dict | None,
                   *, on_route: bool) -> bytes:
    flags = 0
    elevation = 0
    grade = 0
    remaining = 0
    if on_route:
        flags |= 1 << 0
    if query is not None and query["elevationM"] is not None:
        flags |= 1 << 1
        elevation = _whole(query["elevationM"])
        if query["elevationEstimated"]:
            flags |= 1 << 2
    if query is not None and query["gradePercent"] is not None:
        flags |= 1 << 3
        grade = _whole(query["gradePercent"] * 10)
        if query["gradeEstimated"]:
            flags |= 1 << 4
    if query is not None and query["ascentRemainingM"] is not None:
        flags |= 1 << 5
        remaining = min(0xFFFF, _whole(query["ascentRemainingM"]))
        if query["ascentRemainingLowerBound"]:
            flags |= 1 << 6
    return frame_header(OP_PROGRESS) + struct.pack(
        "<IHHIBBhhH", route_token, revision, sequence, progress_m, flags, 0, elevation, grade, remaining,
    )


def acknowledgement(op: int, result: int, route_token: int, revision: int, transfer_id: int) -> bytes:
    return b"EAK1" + struct.pack("<BBBBIHH", FRAME_VERSION, op, result, 0, route_token, revision, transfer_id)


# --- Cases ----------------------------------------------------------------------

def build_processing_cases() -> list[dict]:
    cases: list[dict] = []
    hill = straight_route(44.1740, 5.2780, 35.0, 6000.0, 60.0)
    geometry = geometry_from(hill)
    plan = rel.plan_sampling(geometry.length_m)
    raw = [420.0 + 380.0 * math.sin(math.pi * d / geometry.length_m) ** 2 + noise(i, 2.5)
           for i, d in enumerate(plan.distances_m)]
    cases.append(processing_case(
        "ordinary-hill",
        "Single climb and descent with +/-2.5 m terrain noise; hysteresis must not count the noise.",
        "synthetic terrain on a synthetic straight line near Bedoin, France",
        hill, raw, queries=[0.0, 1234.5, 3000.0, 5999.0],
    ))
    flat = straight_route(52.3700, 4.8900, 90.0, 5000.0, 50.0)
    geometry = geometry_from(flat)
    plan = rel.plan_sampling(geometry.length_m)
    raw = [1.0 + noise(i, 1.2) for i in range(plan.count)]
    cases.append(processing_case(
        "flat-low-relief",
        "Low-relief route where sub-threshold noise must produce no ascent.",
        "synthetic terrain on a synthetic line in Amsterdam",
        flat, raw, queries=[2500.0],
    ))
    dead_sea = straight_route(31.5600, 35.4700, 180.0, 4000.0, 40.0)
    geometry = geometry_from(dead_sea)
    plan = rel.plan_sampling(geometry.length_m)
    raw = [-410.0 + 25.0 * d / geometry.length_m + noise(i, 0.8) for i, d in enumerate(plan.distances_m)]
    cases.append(processing_case(
        "below-sea-level",
        "Negative elevations are valid heights, never missing data.",
        "synthetic terrain near the Dead Sea shore",
        dead_sea, raw, queries=[100.0, 3900.0],
    ))
    gaps = straight_route(46.5000, 8.0000, 120.0, 5000.0, 50.0)
    geometry = geometry_from(gaps)
    plan = rel.plan_sampling(geometry.length_m)
    raw: list[float | None] = [1200.0 + 0.04 * d + noise(i, 1.0) for i, d in enumerate(plan.distances_m)]
    raw[12] = None
    raw[13] = None
    raw[40:52] = [None] * 12
    raw[70] = 99999.0
    raw[-3:] = [None, None, None]
    cases.append(processing_case(
        "missing-data",
        "A 150 m gap is interpolated (estimated); a 650 m gap and the route tail stay unknown; "
        "an out-of-range sentinel is rejected. Statistics are partial lower bounds.",
        "synthetic terrain",
        gaps, raw, queries=[650.0, 2300.0, 4990.0],
    ))
    gpx = straight_route(37.7700, -122.4500, 10.0, 3000.0, 15.0)
    vertex_elevations: list[float | None] = []
    for index, _ in enumerate(gpx):
        vertex_elevations.append(
            None if index in (40, 41, 42) else round(60.0 + 0.03 * index * 15.0 + noise(index, 0.6), 3)
        )
    cases.append(processing_case(
        "gpx-vertices",
        "Trusted GPX <ele> values are resampled by distance; a short vertex gap is bridged linearly.",
        "synthetic GPX track",
        gpx, vertex_elevations=vertex_elevations, queries=[500.0, 2999.0],
    ))
    bridge_route = straight_route(44.0950, 3.0205, 172.0, 3200.0, 40.0)
    geometry = geometry_from(bridge_route)
    plan = rel.plan_sampling(geometry.length_m)
    bridge_raw = []
    for i, d in enumerate(plan.distances_m):
        valley = 155.0 * math.sin(math.pi * (d - 600.0) / 2000.0) if 600.0 <= d <= 2600.0 else 0.0
        bridge_raw.append(585.0 + 0.03 * max(0.0, d - 2600.0) - valley + noise(i, 1.0))
    cases.append(processing_case(
        "bridge-estimated",
        "A confidently associated bridge span is interpolated between approach anchors and flagged "
        "estimated, replacing a valley-floor terrain dip.",
        "synthetic valley terrain; geometry is a synthetic line, not the Millau OSM way",
        bridge_route, bridge_raw,
        structures=[{"kind": "bridge", "startM": 600.0, "endM": 2600.0, "resolution": "estimated", "osmWayIds": [1]}],
        queries=[1600.0],
    ))
    tunnel_route = straight_route(47.0000, 9.0000, 45.0, 4000.0, 50.0)
    geometry = geometry_from(tunnel_route)
    plan = rel.plan_sampling(geometry.length_m)
    tunnel_raw = [800.0 + 0.02 * d + (180.0 * math.sin(math.pi * (d - 1200.0) / 1600.0) if 1200.0 <= d <= 2800.0 else 0.0)
                  + noise(i, 1.5) for i, d in enumerate(plan.distances_m)]
    cases.append(processing_case(
        "tunnel-estimated",
        "Terrain above a tunnel is replaced by portal-to-portal interpolation, flagged estimated.",
        "synthetic mountain terrain",
        tunnel_route, tunnel_raw,
        structures=[{"kind": "tunnel", "startM": 1200.0, "endM": 2800.0, "resolution": "estimated", "osmWayIds": [2]}],
        queries=[2000.0],
    ))
    cases.append(processing_case(
        "ambiguous-crossing",
        "An ambiguous stacked crossing keeps raw heights but withholds grade and completeness.",
        "synthetic terrain",
        tunnel_route, tunnel_raw,
        structures=[{"kind": "bridge", "startM": 1900.0, "endM": 2100.0, "resolution": "ambiguous",
                     "osmWayIds": [3, 4], "reason": "stacked-structures"}],
        queries=[2000.0],
    ))
    cases.append(processing_case(
        "unresolved-structure",
        "A bridge starting at the route start has no approach anchor and becomes unknown.",
        "synthetic terrain",
        bridge_route, bridge_raw,
        structures=[{"kind": "bridge", "startM": 0.0, "endM": 400.0, "resolution": "estimated", "osmWayIds": [5]}],
        queries=[200.0],
    ))
    long_route = straight_route(45.0, 7.0, 90.0, 260_000.0, 2_000.0)
    geometry = geometry_from(long_route)
    plan = rel.plan_sampling(geometry.length_m)
    raw = [300.0 + 200.0 * math.sin(d / 9000.0) for d in plan.distances_m]
    cases.append(processing_case(
        "long-route-spacing",
        "Routes beyond 200 km use a wider, 10 m-rounded spacing to stay within 4001 samples; "
        "display simplification must keep peaks and valleys.",
        "synthetic terrain",
        long_route, raw, queries=[130_000.0],
    ))
    return cases


def build_transfer_fixture(cases: list[dict]) -> str:
    by_name = {case["name"]: case for case in cases}
    lines = [
        "# Route elevation ELV1/EAK1 v1 frames. Generated by tools/generate_route_elevation_fixtures.py",
        "# from processing.json cases; Swift (encoder) and C++ (decoder) are checked against these bytes.",
    ]
    hill = by_name["ordinary-hill"]
    document = _profile_document(hill)
    points = hill["expected"]["display"]
    body = encode_body(document, 0x12345678, 3, points)
    lines.append(f"hill_body {body.hex()}")
    lines.append(f"hill_body_crc32 {zlib.crc32(body) & 0xFFFFFFFF:08x}")
    for index, frame in enumerate(transfer_frames(body, 0x12345678, 3, 0x0102, 150)):
        lines.append(f"hill_frame_{index} {frame.hex()}")
    gaps = by_name["missing-data"]
    gap_document = _profile_document(gaps)
    gap_body = encode_body(gap_document, 0xCAFEF00D, 1, gaps["expected"]["display"])
    lines.append(f"gaps_body {gap_body.hex()}")
    long_case = by_name["long-route-spacing"]
    long_body = encode_body(_profile_document(long_case), 0x00000001, 65535, long_case["expected"]["display"])
    lines.append(f"long_body {long_body.hex()}")
    query = hill["expected"]["queries"][1]
    lines.append(f"hill_progress {progress_frame(0x12345678, 3, 7, 1235, query, on_route=True).hex()}")
    lines.append(f"hill_progress_off_route {progress_frame(0x12345678, 3, 8, 1235, None, on_route=False).hex()}")
    lines.append(f"state_loading {state_frame(0x12345678, 3, 1, 0).hex()}")
    lines.append(f"state_unavailable_source {state_frame(0x12345678, 4, 2, 2).hex()}")
    lines.append(f"state_cleared {state_frame(0, 0, 0, 0).hex()}")
    lines.append(f"ack_commit_applied {acknowledgement(OP_COMMIT, 0, 0x12345678, 3, 0x0102).hex()}")
    lines.append(f"ack_commit_crc {acknowledgement(OP_COMMIT, 3, 0x12345678, 3, 0x0102).hex()}")
    corrupted = bytearray(body)
    corrupted[BODY_HEADER_BYTES + 5] ^= 0x01
    lines.append(f"invalid_body_crc_mismatch {bytes(corrupted).hex()}")
    bad_version = bytearray(body)
    bad_version[0] = 2
    lines.append(f"invalid_body_version {bytes(bad_version).hex()}")
    reserved = bytearray(body)
    reserved[BODY_HEADER_BYTES + 6] |= 0x40
    lines.append(f"invalid_body_reserved_point_flags {bytes(reserved).hex()}")
    descending = bytearray(body)
    struct.pack_into("<I", descending, BODY_HEADER_BYTES + POINT_BYTES, 0xFFFFFFF0)
    lines.append(f"invalid_body_distance_order {bytes(descending).hex()}")
    truncated = body[:-1]
    lines.append(f"invalid_body_truncated {truncated.hex()}")
    count_overflow = bytearray(body)
    count_overflow[3] = PROTOCOL_MAXIMUM_POINTS + 1
    lines.append(f"invalid_body_point_count {bytes(count_overflow).hex()}")
    token_mismatch = bytearray(body)
    struct.pack_into("<I", token_mismatch, 4, 0x12345679)
    lines.append(f"invalid_body_token {bytes(token_mismatch).hex()}")
    lines.append(f"invalid_frame_version {(b'ELV1' + bytes([2, OP_STATE]) + bytes(8)).hex()}")
    return "\n".join(lines) + "\n"


def _profile_document(case: dict) -> dict:
    expected = case["expected"]
    return {
        "geometry": {"lengthM": expected["lengthM"]},
        "samples": expected["samples"],
        "statistics": expected["statistics"],
        "quality": expected["quality"],
        "structures": expected["structures"],
        "source": {"kind": "gpx" if case["input"]["kind"] == "vertices" else "internal-dem"},
    }


def service_response_document(cases: list[dict]) -> dict:
    """The ordinary-hill case as the endpoint serializes a ready answer.

    Source metadata matches the Geoapify provider, so a key renamed on the
    backend or in the Swift model fails the Swift decoding test.
    """
    hill = next(case for case in cases if case["name"] == "ordinary-hill")
    geometry = geometry_from(hill["geometryE6"])
    source = rel.ElevationSource(
        kind="hosted-terrain",
        identifier="geoapify-elevation-v1",
        interpolation="provider",
        attribution=GEOAPIFY_ATTRIBUTION,
        retrieved_at="2026-10-23",
        qualification="pending-live-qualification",
    )
    profile = rel.process_profile(
        geometry,
        rel.plan_sampling(geometry.length_m),
        hill["input"]["rawElevationM"],
        source,
        structure_correction=rel.StructureCorrection(status="unavailable", reason="no-structure-index"),
    )
    return {
        "schema": RESPONSE_SCHEMA,
        "status": "ready",
        "profile": profile.to_dict(),
        "attempts": [{"provider": "geoapify", "status": "complete", "coverage": 1.0, "creditsUsed": 2}],
        "retryAfterSeconds": None,
    }


def processing_document(cases: list[dict]) -> dict:
    return {
        "schema": FIXTURE_SCHEMA,
        "processingVersion": rel.PROCESSING_VERSION,
        "profileSchema": rel.PROFILE_SCHEMA,
        "displayMaximumPoints": DISPLAY_MAXIMUM_POINTS,
        "tolerances": TOLERANCES,
        "cases": cases,
    }


TOLERANCES = {"elevationM": 0.11, "gradePercent": 0.11, "ascentM": 0.11, "distanceM": 0.11, "coverage": 0.0002}


def render() -> dict[Path, str]:
    cases = build_processing_cases()
    # Byte fixtures derive from the rounded JSON values, so they are a pure
    # function of the committed processing document on every platform.
    rounded = json.loads(json.dumps(cases))
    return {
        OUTPUT / "processing.json": json.dumps(processing_document(cases), sort_keys=True, separators=(",", ":")) + "\n",
        OUTPUT / "transfer-v1.txt": build_transfer_fixture(rounded),
        OUTPUT / "service-response-v1.json": json.dumps(
            service_response_document(cases), sort_keys=True, separators=(",", ":")
        ) + "\n",
    }


def numbers_close(expected: object, actual: object, tolerance: float, path: str = "") -> list[str]:
    """Compare JSON values; floats may differ by ``tolerance`` (libm/last-digit rounding)."""

    if isinstance(expected, dict) and isinstance(actual, dict):
        if set(expected) != set(actual):
            return [f"{path}: keys differ"]
        problems: list[str] = []
        for key in expected:
            problems.extend(numbers_close(expected[key], actual[key], tolerance, f"{path}.{key}"))
        return problems
    if isinstance(expected, list) and isinstance(actual, list):
        if len(expected) != len(actual):
            return [f"{path}: length {len(actual)} != {len(expected)}"]
        problems = []
        for index, (left, right) in enumerate(zip(expected, actual)):
            problems.extend(numbers_close(left, right, tolerance, f"{path}[{index}]"))
        return problems
    if isinstance(expected, float) or isinstance(actual, float):
        if isinstance(expected, bool) or isinstance(actual, bool) or expected is None or actual is None:
            return [] if expected == actual else [f"{path}: {actual!r} != {expected!r}"]
        return [] if abs(float(expected) - float(actual)) <= tolerance else [f"{path}: {actual!r} != {expected!r}"]
    return [] if expected == actual else [f"{path}: {actual!r} != {expected!r}"]


def check() -> list[str]:
    problems: list[str] = []
    processing_path = OUTPUT / "processing.json"
    transfer_path = OUTPUT / "transfer-v1.txt"
    if not processing_path.exists() or not transfer_path.exists():
        return ["route elevation fixtures are missing"]
    committed = json.loads(processing_path.read_text(encoding="utf-8"))
    fresh = json.loads(json.dumps(processing_document(build_processing_cases())))
    # Display points and flags are compared exactly; they are derived from the
    # committed rounded samples below, so only the processing numbers float.
    for case in committed.get("cases", []) + fresh.get("cases", []):
        case.get("expected", {}).pop("display", None)
    problems.extend(numbers_close(fresh, committed, max(TOLERANCES.values())))
    committed_cases = json.loads(processing_path.read_text(encoding="utf-8"))["cases"]
    for case in committed_cases:
        document = _profile_document(case)
        if display_points(document) != case["expected"]["display"]:
            problems.append(f"{case['name']}: display points are stale")
    if transfer_path.read_text(encoding="utf-8") != build_transfer_fixture(committed_cases):
        problems.append("transfer-v1.txt is stale")
    response_path = OUTPUT / "service-response-v1.json"
    if not response_path.exists():
        problems.append("service-response-v1.json is missing")
    else:
        fresh_response = json.loads(json.dumps(service_response_document(build_processing_cases())))
        committed_response = json.loads(response_path.read_text(encoding="utf-8"))
        problems.extend(numbers_close(fresh_response, committed_response, max(TOLERANCES.values()), "response"))
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail when committed fixtures are stale")
    args = parser.parse_args()
    if args.check:
        problems = check()
        for problem in problems[:20]:
            print(f"route elevation fixture drift: {problem}")
        return 1 if problems else 0
    for path, content in render().items():
        existing = path.read_text(encoding="utf-8") if path.exists() else None
        if existing == content:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        print(f"generated {path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
