#!/usr/bin/env python3
"""Run the issue #210 renderer profile experiment against one debug session."""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import getpass
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import statistics
import struct
import sys
import time
from typing import Any, Iterable
import uuid
from urllib import parse
import zipfile

from device_debug import (
    DebugClient,
    DebugClientError,
    TARGET_ROTATIONS,
    TOKEN_ENV,
    _load_session,
    write_rgb565_png,
)


SCHEMA_VERSION = 1
PROFILES = ("flat", "current", "medium", "high")
EXPECTED_TUNING = {
    "flat": (0, 0, 0),
    "current": (32, 3072, 90000),
    "medium": (40, 3840, 112500),
    "high": (48, 4608, 135000),
}
EXPECTED_TOTAL_QUOTA = (96, 8192, 220000)
PROFILE_VALUES = {name: index for index, name in enumerate(PROFILES)}
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ROUTE_FIXTURE = (
    REPO_ROOT
    / "ios-app/BikeComputer/BikeComputer/Resources"
    / "renderer-benchmark-shanghai-v1.json"
)
DEFAULT_GATES = Path(__file__).with_name("renderer_benchmark_gates.json")
PINNED_ROUTE_ID = "shanghai-center-renderer-v1"
PINNED_ROUTE_SHA256 = (
    "d5171f6b30478a09948381bbdb86da33752bc646fa6077153f69a4bd840eb36e"
)


class BenchmarkError(RuntimeError):
    pass


def valid_identity_text(value: Any, maximum_bytes: int = 48) -> bool:
    return (
        isinstance(value, str)
        and 0 < len(value.encode("utf-8")) <= maximum_bytes
        and all(
            character.isascii()
            and (character.isalnum() or character in "-_.:")
            for character in value
        )
    )


def valid_lowercase_hex(value: Any, length: int) -> bool:
    return (
        isinstance(value, str)
        and len(value) == length
        and all(character in "0123456789abcdef" for character in value)
    )


def valid_lowercase_sha256(value: Any) -> bool:
    return valid_lowercase_hex(value, 64)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BenchmarkError(f"could not read {label}: {exc}") from exc
    if not isinstance(value, dict):
        raise BenchmarkError(f"{label} must contain a JSON object")
    return value


def load_map_fixture(path: Path) -> dict[str, Any]:
    """Load a retained ZIP/manifest or signed stream and reproduce its receipt."""
    artifact_bytes = path.stat().st_size
    signed_manifest_receipt: str | None = None
    stream_header: dict[str, int] | None = None
    stream_payload_offset: int | None = None
    try:
        if zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as archive:
                matches = [info for info in archive.infolist()
                           if info.filename == "manifest.json"]
                if len(matches) != 1:
                    raise BenchmarkError(
                        "map fixture ZIP must contain exactly one root manifest.json"
                    )
                if matches[0].file_size == 0 or matches[0].file_size > 2 * 1024 * 1024:
                    raise BenchmarkError("map fixture manifest size is invalid")
                manifest_bytes = archive.read(matches[0])
            source_type = "zip-artifact"
        else:
            with path.open("rb") as source:
                prefix = source.read(8)
                if prefix == b"BIKEMAP1":
                    header = prefix + source.read(24)
                    if len(header) != 32:
                        raise BenchmarkError("map stream header is truncated")
                    (
                        magic,
                        format_version,
                        flags,
                        manifest_length,
                        envelope_length,
                        reserved,
                        file_count,
                        payload_bytes,
                    ) = struct.unpack("<8sHHIHHIQ", header)
                    if (
                        magic != b"BIKEMAP1"
                        or format_version != 1
                        or flags != 0
                        or reserved != 0
                        or not 1 <= manifest_length <= 2 * 1024 * 1024
                        or not 5 <= envelope_length <= 132
                        or not 1 <= file_count <= 100_000
                        or not 1 <= payload_bytes <= 512 * 1024 * 1024
                        or artifact_bytes
                        != 32 + manifest_length + envelope_length + payload_bytes
                    ):
                        raise BenchmarkError("map stream header or length is invalid")
                    manifest_bytes = source.read(manifest_length)
                    envelope = source.read(envelope_length)
                    if len(manifest_bytes) != manifest_length or len(envelope) != envelope_length:
                        raise BenchmarkError("map stream metadata is truncated")
                    algorithm, key_id_length, signature_length = struct.unpack(
                        "<BBH", envelope[:4]
                    )
                    key_id = envelope[4 : 4 + key_id_length]
                    if (
                        algorithm != 1
                        or not 1 <= key_id_length <= 64
                        or signature_length != 64
                        or envelope_length != 4 + key_id_length + signature_length
                        or any(
                            not (
                                48 <= value <= 57
                                or 65 <= value <= 90
                                or 97 <= value <= 122
                                or value in (45, 46, 95)
                            )
                            for value in key_id
                        )
                    ):
                        raise BenchmarkError("map stream signature envelope is invalid")
                    signed_manifest_receipt = hashlib.sha256(
                        b"open-bike-computer-map-manifest-v1\0"
                        + manifest_bytes
                        + envelope
                    ).hexdigest()
                    stream_header = {
                        "fileCount": file_count,
                        "payloadBytes": payload_bytes,
                    }
                    stream_payload_offset = (
                        32 + manifest_length + envelope_length
                    )
                    source_type = "bike-map-stream-v1"
                else:
                    if artifact_bytes == 0 or artifact_bytes > 2 * 1024 * 1024:
                        raise BenchmarkError("map fixture manifest size is invalid")
                    source.seek(0)
                    manifest_bytes = source.read()
                    source_type = "manifest"
        manifest = json.loads(manifest_bytes.decode("utf-8"))
    except BenchmarkError:
        raise
    except (
        OSError,
        UnicodeDecodeError,
        json.JSONDecodeError,
        zipfile.BadZipFile,
        KeyError,
    ) as exc:
        raise BenchmarkError(f"could not read map fixture: {exc}") from exc
    if not isinstance(manifest, dict):
        raise BenchmarkError("map fixture manifest must be a JSON object")

    map_id = manifest.get("mapId")
    files = manifest.get("files")
    target = manifest.get("target")
    if (
        manifest.get("schemaVersion") != 1
        or not valid_identity_text(map_id)
        or not isinstance(files, list)
        or not files
        or not isinstance(target, dict)
        or target.get("renderer") != "esp32-fmb"
        or target.get("formatVersion") not in (1, 2, 3)
    ):
        raise BenchmarkError(
            "map fixture must be a device-compatible schema-1 manifest"
        )

    publish_prefix = f"VECTMAP/{map_id}/"
    canonical_files: list[tuple[str, str, int, str]] = []
    for entry in files:
        if not isinstance(entry, dict):
            raise BenchmarkError("map fixture has an invalid file entry")
        file_path = entry.get("path")
        byte_count = entry.get("bytes")
        digest = entry.get("sha256")
        if (
            not isinstance(file_path, str)
            or not file_path.startswith(publish_prefix)
            or isinstance(byte_count, bool)
            or not isinstance(byte_count, int)
            or byte_count <= 0
            or not isinstance(digest, str)
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
        ):
            raise BenchmarkError("map fixture has an invalid file identity")
        publish_path = "VECTMAP/" + file_path[len(publish_prefix) :]
        canonical_files.append((file_path, publish_path, byte_count, digest))

    if stream_header is not None and (
        stream_header["fileCount"] != len(canonical_files)
        or stream_header["payloadBytes"]
        != sum(value[2] for value in canonical_files)
    ):
        raise BenchmarkError("map stream header disagrees with its manifest")

    def hash_chunks(source: Any, byte_count: int) -> str:
        digest = hashlib.sha256()
        remaining = byte_count
        while remaining:
            chunk = source.read(min(1024 * 1024, remaining))
            if not chunk:
                raise BenchmarkError("map fixture payload is truncated")
            digest.update(chunk)
            remaining -= len(chunk)
        return digest.hexdigest()

    if source_type == "zip-artifact":
        try:
            with zipfile.ZipFile(path) as archive:
                members: dict[str, list[zipfile.ZipInfo]] = {}
                for info in archive.infolist():
                    members.setdefault(info.filename, []).append(info)
                for file_path, _publish_path, byte_count, digest in canonical_files:
                    matches = members.get(file_path, [])
                    if len(matches) != 1 or matches[0].file_size != byte_count:
                        raise BenchmarkError(
                            "map fixture ZIP payload identity is invalid"
                        )
                    with archive.open(matches[0]) as source:
                        if hash_chunks(source, byte_count) != digest:
                            raise BenchmarkError(
                                "map fixture ZIP payload digest does not match its manifest"
                            )
        except BenchmarkError:
            raise
        except (OSError, zipfile.BadZipFile, RuntimeError) as exc:
            raise BenchmarkError(f"could not verify map fixture ZIP: {exc}") from exc
    elif stream_header is not None:
        if stream_payload_offset is None:
            raise BenchmarkError("map stream payload offset is unavailable")
        try:
            with path.open("rb") as source:
                source.seek(stream_payload_offset)
                for _file_path, _publish_path, byte_count, digest in canonical_files:
                    if hash_chunks(source, byte_count) != digest:
                        raise BenchmarkError(
                            "map stream payload digest does not match its manifest"
                        )
        except BenchmarkError:
            raise
        except OSError as exc:
            raise BenchmarkError(f"could not verify map stream payload: {exc}") from exc

    labels = target.get("labelLanguages", [])
    buildings = manifest.get("buildings", {})
    if not isinstance(labels, list) or any(
        not isinstance(value, str) for value in labels
    ):
        raise BenchmarkError("map fixture label languages are invalid")
    if not isinstance(buildings, dict):
        raise BenchmarkError("map fixture building summary is invalid")
    building_keys = (
        "explicitHeightCount",
        "levelsHeightCount",
        "inheritedHeightCount",
        "localMedianHeightCount",
        "classDefaultHeightCount",
    )
    canonical_lines: list[str] = [
        str(manifest["schemaVersion"]),
        map_id,
        target["renderer"],
        str(target["formatVersion"]),
        str(target.get("labelProfileVersion", 0)),
        *labels,
        str(target.get("internationalFallback", "")),
        str(target.get("buildingProfileVersion", 0)),
        str(buildings.get("recordCount", 0)),
        *(str(buildings.get(key, 0)) for key in building_keys),
        str(target.get("minFirmwareVersion", "")),
    ]
    for file_path, publish_path, byte_count, digest in canonical_files:
        canonical_lines.extend(
            (file_path, publish_path, str(byte_count), digest)
        )
    canonical = ("\n".join(canonical_lines) + "\n").encode("utf-8")
    result = {
        "id": map_id,
        "manifestReceipt": hashlib.sha256(
            manifest_bytes if stream_header is not None else canonical
        ).hexdigest(),
        "manifestSha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "artifactSha256": sha256_file(path),
        "artifactBytes": artifact_bytes,
        "sourceName": path.name,
        "sourceType": source_type,
    }
    if signed_manifest_receipt is not None:
        result["signedManifestReceipt"] = signed_manifest_receipt
    return result


def validate_route_fixture(path: Path) -> dict[str, Any]:
    fixture = load_json_object(path, "route fixture")
    points = fixture.get("points")
    if (
        fixture.get("schema") != 1
        or fixture.get("cadenceHz") != 1
        or not valid_identity_text(fixture.get("id"))
        or not isinstance(points, list)
        or not 60 <= len(points) <= 120
        or isinstance(fixture.get("nominalSpeedMetersPerSecond"), bool)
        or not isinstance(fixture.get("nominalSpeedMetersPerSecond"), (int, float))
        or not math.isfinite(fixture["nominalSpeedMetersPerSecond"])
        or fixture["nominalSpeedMetersPerSecond"] <= 0
    ):
        raise BenchmarkError(
            "route fixture must be schema 1 with 60-120 exact 1 Hz samples"
        )
    for point in points:
        if (
            not isinstance(point, dict)
            or isinstance(point.get("latitude"), bool)
            or not isinstance(point.get("latitude"), (int, float))
            or isinstance(point.get("longitude"), bool)
            or not isinstance(point.get("longitude"), (int, float))
            or not math.isfinite(point["latitude"])
            or not math.isfinite(point["longitude"])
            or not -90 <= point["latitude"] <= 90
            or not -180 <= point["longitude"] <= 180
        ):
            raise BenchmarkError("route fixture contains an invalid coordinate")
    return fixture


def load_gates(path: Path) -> dict[str, Any]:
    gates = load_json_object(path, "renderer benchmark gates")
    required = {
        "schema",
        "warmupSeconds",
        "pollIntervalSeconds",
        "comparisonDurationSeconds",
        "checkpointFractions",
        "checkpointToleranceSamples",
        "absolute",
        "trend",
        "candidateRelativeToCurrent",
    }
    if gates.get("schema") != SCHEMA_VERSION or set(gates) != required:
        raise BenchmarkError("renderer benchmark gate schema is invalid")
    absolute_keys = {
        "minimumMetricsSampleFraction",
        "minimumRenderSamples",
        "minimumBuildingCandidates",
        "minimumSelectedBuildings",
        "minimumExtrudedBuildingsFor3DProfile",
        "minimumGpsPacketsPerMinute",
        "minimumRouteMarkersPerMinute",
        "maximumRouteMarkerAgeMs",
        "maximumRouteMarkerStallMs",
        "minimumInternalFreeBytes",
        "minimumInternalLargestBlockBytes",
        "minimumPsramFreeBytes",
        "minimumPsramLargestBlockBytes",
        "maximumRenderP95Ms",
        "maximumUiGapMs",
        "maximumFlushP95Ms",
        "maximumFlushMs",
        "maximumGpsPacketGapMs",
        "maximumStaleRenders",
        "maximumCancelledRenders",
        "maximumInterruptedRenders",
        "maximumCoverageRejectedRenders",
        "maximumPredictionExhaustionEntries",
        "maximumInvariantFailures",
        "maximumRemoteDebugCaptureErrors",
    }
    trend_keys = {
        "minimumSamples",
        "internalFreeAllowedDeclineBytes",
        "internalLargestAllowedDeclineBytes",
        "psramFreeAllowedDeclineBytes",
        "psramLargestAllowedDeclineBytes",
        "crossRunInternalAllowedDeclineBytes",
        "crossRunPsramAllowedDeclineBytes",
    }
    relative_keys = {
        "maximumRenderP95Multiplier",
        "maximumUiGapMultiplier",
        "maximumInternalHeadroomLossBytes",
        "maximumPsramHeadroomLossBytes",
        "minimumReachGainFraction",
    }
    absolute = gates.get("absolute")
    trend = gates.get("trend")
    relative = gates.get("candidateRelativeToCurrent")
    if (
        not isinstance(absolute, dict)
        or set(absolute) != absolute_keys
        or not isinstance(trend, dict)
        or set(trend) != trend_keys
        or not isinstance(relative, dict)
        or set(relative) != relative_keys
    ):
        raise BenchmarkError("renderer benchmark nested gate schema is invalid")

    def nonnegative_integer(value: Any) -> bool:
        return isinstance(value, int) and not isinstance(value, bool) and value >= 0

    if (
        not nonnegative_integer(gates.get("warmupSeconds"))
        or not isinstance(gates.get("pollIntervalSeconds"), (int, float))
        or isinstance(gates.get("pollIntervalSeconds"), bool)
        or not math.isfinite(gates["pollIntervalSeconds"])
        or gates["pollIntervalSeconds"] <= 0
        or not nonnegative_integer(gates.get("comparisonDurationSeconds"))
        or gates["comparisonDurationSeconds"] == 0
        or not nonnegative_integer(gates.get("checkpointToleranceSamples"))
        or not isinstance(absolute["minimumMetricsSampleFraction"], (int, float))
        or isinstance(absolute["minimumMetricsSampleFraction"], bool)
        or not 0 < absolute["minimumMetricsSampleFraction"] <= 1
        or any(
            not nonnegative_integer(value)
            for key, value in absolute.items()
            if key != "minimumMetricsSampleFraction"
        )
        or absolute["maximumRouteMarkerStallMs"]
        < absolute["maximumRouteMarkerAgeMs"]
        or not nonnegative_integer(trend["minimumSamples"])
        or trend["minimumSamples"] < 3
        or any(
            not nonnegative_integer(value)
            for key, value in trend.items()
            if key != "minimumSamples"
        )
        or any(
            not isinstance(relative[key], (int, float))
            or isinstance(relative[key], bool)
            or not math.isfinite(relative[key])
            or relative[key] <= 0
            for key in (
                "maximumRenderP95Multiplier",
                "maximumUiGapMultiplier",
            )
        )
        or not nonnegative_integer(relative["maximumInternalHeadroomLossBytes"])
        or not nonnegative_integer(relative["maximumPsramHeadroomLossBytes"])
        or not isinstance(relative["minimumReachGainFraction"], (int, float))
        or isinstance(relative["minimumReachGainFraction"], bool)
        or not math.isfinite(relative["minimumReachGainFraction"])
        or relative["minimumReachGainFraction"] < 0
    ):
        raise BenchmarkError("renderer benchmark gate values are invalid")
    fractions = gates["checkpointFractions"]
    if (
        not isinstance(fractions, list)
        or not fractions
        or any(
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not 0 <= value < 1
            for value in fractions
        )
    ):
        raise BenchmarkError("checkpoint fractions must be numbers in [0, 1)")
    return gates


def validate_acceptance_inputs(
    *,
    route_fixture: dict[str, Any],
    route_fixture_sha256: str,
    gates: dict[str, Any],
    allow_partial: bool,
) -> None:
    if allow_partial:
        return
    if (
        route_fixture.get("id") != PINNED_ROUTE_ID
        or route_fixture_sha256 != PINNED_ROUTE_SHA256
    ):
        raise BenchmarkError(
            "full issue #210 evidence requires the checked-in Shanghai route fixture"
        )
    if gates != load_gates(DEFAULT_GATES):
        raise BenchmarkError(
            "full issue #210 evidence requires the checked-in benchmark gates"
        )


def balanced_profile_schedule(
    repeats: int, profiles: Iterable[str] = PROFILES
) -> list[list[str]]:
    values = list(profiles)
    if repeats <= 0 or not values or len(set(values)) != len(values):
        raise ValueError("repeats and unique profiles are required")
    if len(values) == 1:
        return [values.copy() for _ in range(repeats)]
    first_row: list[int] = [0]
    low, high = 1, len(values) - 1
    while len(first_row) < len(values):
        first_row.append(low)
        low += 1
        if len(first_row) < len(values):
            first_row.append(high)
            high -= 1
    return [
        [values[(index + repeat) % len(values)] for index in first_row]
        for repeat in range(repeats)
    ]


def expected_tuning_fingerprint(profile: str) -> int:
    value = 1469598103934665603
    for part in (
        PROFILE_VALUES[profile],
        *EXPECTED_TOTAL_QUOTA,
        *EXPECTED_TUNING[profile],
        6,
    ):
        value ^= part
        value = (value * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return value


def nested(value: dict[str, Any], *path: str) -> Any:
    current: Any = value
    for part in path:
        if not isinstance(current, dict) or part not in current:
            raise BenchmarkError(f"metrics snapshot is missing {'.'.join(path)}")
        current = current[part]
    return current


def median_number(values: Iterable[float | int]) -> float:
    selected = [float(value) for value in values]
    return statistics.median(selected) if selected else 0.0


def circular_sample_distance(left: int, right: int, count: int) -> int:
    direct = abs(left - right)
    return min(direct, count - direct)


def monotonic_decline(
    values: list[int], *, minimum_samples: int, allowed_decline: int
) -> bool:
    if len(values) < minimum_samples:
        return False
    width = max(3, len(values) // 5)
    sections = [
        median_number(values[index : index + width])
        for index in range(0, len(values) - width + 1, width)
    ]
    if len(sections) < 3:
        return False
    total_decline = sections[0] - sections[-1]
    nonincreasing = sum(
        right <= left for left, right in zip(sections, sections[1:])
    )
    mean_x = (len(values) - 1) / 2
    mean_y = sum(values) / len(values)
    denominator = sum((index - mean_x) ** 2 for index in range(len(values)))
    slope = (
        sum(
            (index - mean_x) * (value - mean_y)
            for index, value in enumerate(values)
        )
        / denominator
        if denominator
        else 0
    )
    return (
        total_decline > allowed_decline
        and nonincreasing >= len(sections) - 2
        and slope < -(allowed_decline / max(len(values) - 1, 1))
    )


def expected_checkpoint_indexes(
    sample_count: int, fractions: Iterable[float]
) -> list[int]:
    return sorted({int(round(sample_count * value)) % sample_count for value in fractions})


def validate_snapshot_identity(
    snapshot: dict[str, Any],
    *,
    baseline: dict[str, Any],
    profile: str,
    run_id: str,
    repeat: int,
    map_fixture_id: str,
    map_fixture_sha256: str,
    route_fixture_id: str,
    route_fixture_sha256: str,
    route_mode: str,
    window_id: int,
) -> list[str]:
    failures: list[str] = []
    sequence = snapshot.get("sequence")
    timestamp_ms = snapshot.get("timestampMs")
    if (
        snapshot.get("ok") is not True
        or snapshot.get("schema") != SCHEMA_VERSION
        or isinstance(sequence, bool)
        or not isinstance(sequence, int)
        or not 0 <= sequence <= 0xFFFFFFFF
        or isinstance(timestamp_ms, bool)
        or not isinstance(timestamp_ms, int)
        or not 0 <= timestamp_ms <= 0xFFFFFFFF
    ):
        failures.append("stale_identity:snapshot_envelope")
    identity = nested(snapshot, "identity")
    window = nested(snapshot, "window")
    tuning = nested(snapshot, "tuning")
    expected_identity = {
        key: baseline[key]
        for key in (
            "deviceId",
            "firmwareCommit",
            "board",
            "buildProfile",
            "bootId",
            "resetReason",
        )
    }
    for key, expected in expected_identity.items():
        if identity.get(key) != expected:
            failures.append(f"stale_identity:{key}")
    if window.get("id") != window_id:
        failures.append("stale_window:id")
    if window.get("runId") != run_id:
        failures.append("stale_window:runId")
    if window.get("repeat") != repeat:
        failures.append("stale_window:repeat")
    if tuning.get("profile") != profile:
        failures.append("stale_tuning:profile")
    total = tuning.get("total")
    extrusion = tuning.get("extrusion")
    if not isinstance(total, dict) or (
        total.get("records"), total.get("points"), total.get("projectedPixels")
    ) != EXPECTED_TOTAL_QUOTA:
        failures.append("stale_tuning:total_quota")
    if not isinstance(extrusion, dict) or (
        extrusion.get("records"),
        extrusion.get("points"),
        extrusion.get("projectedPixels"),
    ) != EXPECTED_TUNING[profile]:
        failures.append("stale_tuning:extrusion_quota")
    if tuning.get("minimumExtrusionAreaPx2") != 6:
        failures.append("stale_tuning:minimum_area")
    if tuning.get("fingerprint") != expected_tuning_fingerprint(profile):
        failures.append("stale_tuning:fingerprint")
    map_fixture = identity.get("mapFixture")
    route_fixture = identity.get("routeFixture")
    if map_fixture != {"id": map_fixture_id, "sha256": map_fixture_sha256}:
        failures.append("stale_identity:map_fixture")
    if route_fixture != {
        "id": route_fixture_id,
        "sha256": route_fixture_sha256,
        "mode": route_mode,
    }:
        failures.append("stale_identity:route_fixture")
    return failures


def compact_sample(snapshot: dict[str, Any], elapsed: float) -> dict[str, Any]:
    memory = nested(snapshot, "memory")
    render = nested(snapshot, "render")
    return {
        "elapsedSeconds": round(elapsed, 3),
        "sequence": snapshot["sequence"],
        "timestampMs": snapshot["timestampMs"],
        "internalFree": nested(memory, "internalHeap", "free"),
        "internalLargest": nested(memory, "internalHeap", "largestBlock"),
        "psramFree": nested(memory, "psram", "free"),
        "psramLargest": nested(memory, "psram", "largestBlock"),
        "renderCount": nested(render, "timings", "total", "count"),
        "buildings": nested(render, "buildings"),
        "routeReplay": nested(snapshot, "routeReplay"),
    }


def summarize_run(
    snapshots: list[dict[str, Any]], samples: list[dict[str, Any]]
) -> dict[str, Any]:
    final = snapshots[-1]
    memory = nested(final, "memory")
    render = nested(final, "render")
    timings = nested(render, "timings")
    jobs = nested(render, "jobs")
    changing_building_samples: list[dict[str, Any]] = []
    previous_render_count = -1
    for sample in samples:
        if sample["renderCount"] != previous_render_count:
            changing_building_samples.append(sample["buildings"])
            previous_render_count = sample["renderCount"]

    def building_median(key: str) -> float:
        return median_number(
            sample.get(key, 0) for sample in changing_building_samples
        )

    return {
        "profile": nested(final, "tuning", "profile"),
        "repeat": nested(final, "window", "repeat"),
        "renderCount": nested(timings, "total", "count"),
        "renderP50Ms": nested(timings, "total", "p50Ms"),
        "renderP95Ms": nested(timings, "total", "p95Ms"),
        "renderMaximumMs": nested(timings, "total", "maximumMs"),
        "blockLoadP95Ms": nested(timings, "blockLoad", "p95Ms"),
        "drawP95Ms": nested(timings, "draw", "p95Ms"),
        "buildingP95Ms": nested(timings, "buildingTotal", "p95Ms"),
        "buildingProjectionP95Ms": nested(
            timings, "buildingProjection", "p95Ms"
        ),
        "buildingDrawP95Ms": nested(timings, "buildingDraw", "p95Ms"),
        "uiMaximumGapMs": nested(final, "ui", "maximumGapMs"),
        "flushP50Ms": nested(final, "displayFlush", "p50Ms"),
        "flushP95Ms": nested(final, "displayFlush", "p95Ms"),
        "flushMaximumMs": nested(final, "displayFlush", "maximumMs"),
        "minimumInternalFree": nested(
            memory, "internalHeap", "windowMinimumFree"
        ),
        "minimumInternalLargest": nested(
            memory, "internalHeap", "windowMinimumLargestBlock"
        ),
        "minimumPsramFree": nested(memory, "psram", "windowMinimumFree"),
        "minimumPsramLargest": nested(
            memory, "psram", "windowMinimumLargestBlock"
        ),
        "candidateBuildings": building_median("candidates"),
        "selectedBuildings": building_median("selected"),
        "extrudedBuildings": building_median("extruded"),
        "flatBuildings": building_median("flat"),
        "deferredBuildings": building_median("deferred"),
        "oversizedBuildings": building_median("oversized"),
        "renderedBuildings": building_median("rendered"),
        "extrudedP90DistancePx": building_median("extrudedP90DistancePx"),
        "extrudedFarthestDistancePx": building_median(
            "extrudedFarthestDistancePx"
        ),
        "requestedRenders": jobs["requested"],
        "completedRenders": jobs["completed"],
        "publishedRenders": jobs["published"],
        "staleRenders": jobs["stale"],
        "cancelledRenders": jobs["cancelled"],
        "interruptedRenders": jobs["interrupted"],
        "coverageRejectedRenders": jobs["coverageRejected"],
        "invariantFailures": jobs["invariantFailed"],
        "maximumGpsPacketGapMs": nested(final, "gps", "maximumPacketGapMs"),
        "gpsPackets": nested(final, "gps", "packets"),
        "predictionGraceEntries": nested(
            final, "gps", "predictionGraceEntries"
        ),
        "predictionExhaustionEntries": nested(
            final, "gps", "predictionExhaustionEntries"
        ),
        "routeMarkersAccepted": nested(final, "routeReplay", "accepted"),
        "routeMarkersRejected": nested(final, "routeReplay", "rejected"),
        "remoteDebugCaptureErrors": nested(
            final, "remoteDebug", "captureErrors"
        ),
    }


def evaluate_run(
    *,
    snapshots: list[dict[str, Any]],
    samples: list[dict[str, Any]],
    summary: dict[str, Any],
    duration_seconds: int,
    poll_interval_seconds: float,
    screenshots: list[dict[str, Any]],
    checkpoint_count: int,
    expected_route_sample_count: int,
    gates: dict[str, Any],
    expect_remote_debug: bool = True,
) -> list[str]:
    absolute = gates["absolute"]
    trend = gates["trend"]
    failures: list[str] = []
    minimum_metrics_samples = math.floor(
        duration_seconds
        / poll_interval_seconds
        * absolute["minimumMetricsSampleFraction"]
    )
    if len(samples) < minimum_metrics_samples:
        failures.append(
            f"missing_metrics_samples:{len(samples)}<{minimum_metrics_samples}"
        )
    if summary["renderCount"] < absolute["minimumRenderSamples"]:
        failures.append("missing_render_samples")
    if summary["candidateBuildings"] < absolute["minimumBuildingCandidates"]:
        failures.append("building_fixture_not_dense_enough")
    if summary["selectedBuildings"] < absolute["minimumSelectedBuildings"]:
        failures.append("insufficient_selected_buildings")
    if (
        summary["profile"] != "flat"
        and summary["extrudedBuildings"]
        < absolute["minimumExtrudedBuildingsFor3DProfile"]
    ):
        failures.append("insufficient_extruded_buildings")
    if summary["profile"] == "flat" and summary["extrudedBuildings"] != 0:
        failures.append("flat_control_extruded_buildings")
    required_gps_packets = math.floor(
        duration_seconds
        / 60
        * absolute["minimumGpsPacketsPerMinute"]
    )
    if summary["gpsPackets"] < required_gps_packets:
        failures.append("missing_gps_packets")
    required_markers = math.floor(
        duration_seconds
        / 60
        * absolute["minimumRouteMarkersPerMinute"]
    )
    if summary["routeMarkersAccepted"] < required_markers:
        failures.append("missing_route_markers")
    if summary["routeMarkersRejected"] != 0:
        failures.append("rejected_route_marker")
    if len(screenshots) != checkpoint_count:
        failures.append("missing_checkpoint_screenshot")

    comparisons = (
        ("minimumInternalFree", "minimumInternalFreeBytes", "internal_free_floor", False),
        (
            "minimumInternalLargest",
            "minimumInternalLargestBlockBytes",
            "internal_largest_floor",
            False,
        ),
        ("minimumPsramFree", "minimumPsramFreeBytes", "psram_free_floor", False),
        (
            "minimumPsramLargest",
            "minimumPsramLargestBlockBytes",
            "psram_largest_floor",
            False,
        ),
        ("renderP95Ms", "maximumRenderP95Ms", "render_p95", True),
        ("uiMaximumGapMs", "maximumUiGapMs", "ui_gap", True),
        ("flushP95Ms", "maximumFlushP95Ms", "flush_p95", True),
        ("flushMaximumMs", "maximumFlushMs", "flush_maximum", True),
        (
            "maximumGpsPacketGapMs",
            "maximumGpsPacketGapMs",
            "gps_packet_gap",
            True,
        ),
        ("staleRenders", "maximumStaleRenders", "stale_renders", True),
        (
            "cancelledRenders",
            "maximumCancelledRenders",
            "cancelled_renders",
            True,
        ),
        (
            "interruptedRenders",
            "maximumInterruptedRenders",
            "interrupted_renders",
            True,
        ),
        (
            "coverageRejectedRenders",
            "maximumCoverageRejectedRenders",
            "coverage_rejections",
            True,
        ),
        (
            "predictionExhaustionEntries",
            "maximumPredictionExhaustionEntries",
            "prediction_exhaustion",
            True,
        ),
        (
            "invariantFailures",
            "maximumInvariantFailures",
            "invariant_failure",
            True,
        ),
        (
            "remoteDebugCaptureErrors",
            "maximumRemoteDebugCaptureErrors",
            "remote_debug_capture_error",
            True,
        ),
    )
    for metric, gate, label, maximum in comparisons:
        value = summary[metric]
        limit = absolute[gate]
        if (maximum and value > limit) or (not maximum and value < limit):
            failures.append(f"{label}:{value}")

    if any(
        nested(snapshot, "render", "buildings", "allocationFallback") is True
        for snapshot in snapshots
    ):
        failures.append("allocation_fallback")
    if any(
        nested(snapshot, "routeReplay", "valid") is True
        and nested(snapshot, "routeReplay", "fixtureMatches") is not True
        for snapshot in snapshots
    ):
        failures.append("route_fixture_mismatch")

    maximum_marker_age_ms = absolute["maximumRouteMarkerAgeMs"]
    maximum_marker_stall_ms = absolute["maximumRouteMarkerStallMs"]
    last_marker_position: int | None = None
    last_marker_progress_ms: int | None = None
    for snapshot, sample in zip(snapshots, samples):
        replay = nested(snapshot, "routeReplay")
        sample_index = replay.get("sampleIndex")
        sample_count = replay.get("sampleCount")
        loop = replay.get("loop")
        received_at_ms = replay.get("receivedAtMs")
        timestamp_ms = snapshot.get("timestampMs")
        marker_fields_valid = (
            replay.get("valid") is True
            and replay.get("fixtureMatches") is True
            and isinstance(sample_index, int)
            and not isinstance(sample_index, bool)
            and isinstance(sample_count, int)
            and not isinstance(sample_count, bool)
            and sample_count == expected_route_sample_count
            and 0 <= sample_index < sample_count
            and isinstance(loop, int)
            and not isinstance(loop, bool)
            and 0 <= loop <= 0xFFFFFFFF
            and isinstance(received_at_ms, int)
            and not isinstance(received_at_ms, bool)
            and isinstance(timestamp_ms, int)
            and not isinstance(timestamp_ms, bool)
        )
        if not marker_fields_valid:
            if sample["elapsedSeconds"] * 1000 > maximum_marker_age_ms:
                failures.append("missing_or_invalid_route_marker")
            continue
        marker_age_ms = _uint32_forward_delta(timestamp_ms, received_at_ms)
        if marker_age_ms >= 0x80000000 or marker_age_ms > maximum_marker_age_ms:
            failures.append("stale_route_marker")
        marker_position = loop * sample_count + sample_index
        if last_marker_position is None or marker_position > last_marker_position:
            last_marker_position = marker_position
            last_marker_progress_ms = timestamp_ms
        elif marker_position < last_marker_position:
            failures.append("route_marker_regressed")
        elif last_marker_progress_ms is not None:
            stalled_ms = _uint32_forward_delta(timestamp_ms, last_marker_progress_ms)
            if stalled_ms >= 0x80000000 or stalled_ms > maximum_marker_stall_ms:
                failures.append("stalled_route_marker")
    if any(
        nested(snapshot, "remoteDebug", "active") is not expect_remote_debug
        for snapshot in snapshots
    ):
        failures.append(
            "remote_debug_inactive"
            if expect_remote_debug
            else "remote_debug_overhead_present"
        )

    trends = (
        ("internalFree", "internalFreeAllowedDeclineBytes", "internal_free_decline"),
        (
            "internalLargest",
            "internalLargestAllowedDeclineBytes",
            "internal_largest_decline",
        ),
        ("psramFree", "psramFreeAllowedDeclineBytes", "psram_free_decline"),
        (
            "psramLargest",
            "psramLargestAllowedDeclineBytes",
            "psram_largest_decline",
        ),
    )
    if len(samples) < trend["minimumSamples"]:
        failures.append(
            f"missing_memory_trend_samples:{len(samples)}<"
            f"{trend['minimumSamples']}"
        )
    for field, allowed_key, label in trends:
        if monotonic_decline(
            [sample[field] for sample in samples],
            minimum_samples=trend["minimumSamples"],
            allowed_decline=trend[allowed_key],
        ):
            failures.append(label)
    return sorted(set(failures))


def apply_cross_run_memory_gates(
    runs: list[dict[str, Any]], gates: dict[str, Any]
) -> None:
    trend = gates["trend"]
    checks = (
        (
            "minimumInternalFree",
            "crossRunInternalAllowedDeclineBytes",
            "cross_run_internal_decline",
        ),
        (
            "minimumInternalLargest",
            "crossRunInternalAllowedDeclineBytes",
            "cross_run_internal_largest_decline",
        ),
        (
            "minimumPsramFree",
            "crossRunPsramAllowedDeclineBytes",
            "cross_run_psram_decline",
        ),
        (
            "minimumPsramLargest",
            "crossRunPsramAllowedDeclineBytes",
            "cross_run_psram_largest_decline",
        ),
    )
    for profile in PROFILES:
        profile_runs = [run for run in runs if run["profile"] == profile]
        if len(profile_runs) < 3:
            continue
        for metric, allowed_key, label in checks:
            values = [run["summary"][metric] for run in profile_runs]
            if (
                all(right < left for left, right in zip(values, values[1:]))
                and values[0] - values[-1] > trend[allowed_key]
            ):
                for run in profile_runs:
                    run["failures"] = sorted(set(run["failures"] + [label]))
                    run["passed"] = False


def aggregate_profiles(runs: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    aggregate: dict[str, dict[str, Any]] = {}
    numeric_fields = (
        "renderP95Ms",
        "buildingP95Ms",
        "uiMaximumGapMs",
        "flushP95Ms",
        "minimumInternalFree",
        "minimumInternalLargest",
        "minimumPsramFree",
        "minimumPsramLargest",
        "candidateBuildings",
        "selectedBuildings",
        "extrudedBuildings",
        "flatBuildings",
        "deferredBuildings",
        "oversizedBuildings",
        "renderedBuildings",
        "extrudedP90DistancePx",
        "extrudedFarthestDistancePx",
    )
    for profile in PROFILES:
        selected = [run for run in runs if run["profile"] == profile]
        if not selected:
            continue
        value: dict[str, Any] = {
            "passed": all(run["passed"] for run in selected),
            "runCount": len(selected),
            "failedRuns": sum(not run["passed"] for run in selected),
        }
        for field in numeric_fields:
            value[field] = median_number(run["summary"][field] for run in selected)
        aggregate[profile] = value
    return aggregate


def choose_pareto_candidate(
    aggregate: dict[str, dict[str, Any]], gates: dict[str, Any]
) -> dict[str, Any]:
    exclusions: dict[str, list[str]] = {}
    current = aggregate.get("current")
    if current is None or not current["passed"]:
        return {
            "selected": None,
            "frontier": [],
            "exclusions": {"all": ["current baseline did not pass"]},
        }
    relative = gates["candidateRelativeToCurrent"]
    candidates: list[str] = []
    for profile in ("current", "medium", "high"):
        value = aggregate.get(profile)
        reasons: list[str] = []
        if value is None or not value["passed"]:
            reasons.append("absolute gates failed")
        else:
            if value["renderP95Ms"] > (
                current["renderP95Ms"] * relative["maximumRenderP95Multiplier"]
            ):
                reasons.append("render p95 regressed beyond current multiplier")
            if value["uiMaximumGapMs"] > (
                current["uiMaximumGapMs"] * relative["maximumUiGapMultiplier"]
            ):
                reasons.append("UI gap regressed beyond current multiplier")
            if value["minimumInternalFree"] < (
                current["minimumInternalFree"]
                - relative["maximumInternalHeadroomLossBytes"]
            ):
                reasons.append("internal headroom loss exceeded")
            if value["minimumPsramFree"] < (
                current["minimumPsramFree"]
                - relative["maximumPsramHeadroomLossBytes"]
            ):
                reasons.append("PSRAM headroom loss exceeded")
            if profile != "current":
                reach_gain = max(
                    value["extrudedBuildings"]
                    / max(current["extrudedBuildings"], 1)
                    - 1,
                    value["extrudedP90DistancePx"]
                    / max(current["extrudedP90DistancePx"], 1)
                    - 1,
                    value["extrudedFarthestDistancePx"]
                    / max(current["extrudedFarthestDistancePx"], 1)
                    - 1,
                )
                deferred_improved = (
                    value["flatBuildings"] + value["deferredBuildings"]
                    < current["flatBuildings"] + current["deferredBuildings"]
                )
                if (
                    reach_gain < relative["minimumReachGainFraction"]
                    and not deferred_improved
                ):
                    reasons.append("no material measured reach gain")
        if reasons:
            exclusions[profile] = reasons
        else:
            candidates.append(profile)

    def benefits(profile: str) -> tuple[float, ...]:
        value = aggregate[profile]
        return (
            value["extrudedBuildings"],
            value["extrudedP90DistancePx"],
            value["extrudedFarthestDistancePx"],
            -(value["flatBuildings"] + value["deferredBuildings"]),
        )

    def costs(profile: str) -> tuple[float, ...]:
        value = aggregate[profile]
        return (
            value["renderP95Ms"],
            value["buildingP95Ms"],
            value["uiMaximumGapMs"],
            -value["minimumInternalFree"],
            -value["minimumPsramFree"],
        )

    frontier: list[str] = []
    for profile in candidates:
        dominated = False
        for other in candidates:
            if other == profile:
                continue
            benefit_better = all(
                left >= right
                for left, right in zip(benefits(other), benefits(profile))
            )
            cost_better = all(
                left <= right for left, right in zip(costs(other), costs(profile))
            )
            strictly_better = benefits(other) != benefits(profile) or costs(
                other
            ) != costs(profile)
            if benefit_better and cost_better and strictly_better:
                dominated = True
                break
        if not dominated:
            frontier.append(profile)

    if not frontier:
        return {"selected": None, "frontier": [], "exclusions": exclusions}

    benefit_rows = {profile: benefits(profile) for profile in frontier}
    cost_rows = {profile: costs(profile) for profile in frontier}

    def normalized_average(
        profile: str, rows: dict[str, tuple[float, ...]]
    ) -> float:
        values: list[float] = []
        for index in range(len(rows[profile])):
            column = [row[index] for row in rows.values()]
            low, high = min(column), max(column)
            values.append(0.5 if high == low else (rows[profile][index] - low) / (high - low))
        return sum(values) / len(values)

    distances: dict[str, float] = {}
    for profile in frontier:
        benefit_score = normalized_average(profile, benefit_rows)
        cost_score = normalized_average(profile, cost_rows)
        distances[profile] = math.hypot(1 - benefit_score, cost_score)
    selected = min(frontier, key=lambda profile: (distances[profile], PROFILES.index(profile)))
    return {
        "selected": selected,
        "frontier": frontier,
        "idealDistances": distances,
        "exclusions": exclusions,
    }


class BenchmarkRunner:
    def __init__(
        self,
        *,
        client: DebugClient,
        output: Path,
        gates: dict[str, Any],
        map_fixture_id: str,
        map_fixture_sha256: str,
        route_fixture: dict[str, Any],
        route_fixture_sha256: str,
        route_mode: str,
        warmup_seconds: int,
        poll_interval_seconds: float,
        capture_screenshots: bool,
    ) -> None:
        self.client = client
        self.output = output
        self.gates = gates
        self.map_fixture_id = map_fixture_id
        self.map_fixture_sha256 = map_fixture_sha256
        self.route_fixture = route_fixture
        self.route_fixture_sha256 = route_fixture_sha256
        self.route_mode = route_mode
        self.warmup_seconds = warmup_seconds
        self.poll_interval_seconds = poll_interval_seconds
        self.capture_screenshots = capture_screenshots
        self.root_run_id = (
            datetime.now(timezone.utc).strftime("rb-%Y%m%dT%H%M%SZ-")
            + uuid.uuid4().hex[:4]
        )
        self.baseline_identity: dict[str, Any] | None = None
        self.last_frame_sequence = 0
        self.view_rotation = 0

    def _metrics(self, timeout_seconds: float = 5) -> dict[str, Any]:
        deadline = time.monotonic() + timeout_seconds
        last_error: Exception | None = None
        while time.monotonic() < deadline:
            try:
                return self.client.metrics()
            except DebugClientError as exc:
                last_error = exc
                time.sleep(0.3)
        raise BenchmarkError(
            f"device metrics became unavailable: {last_error or 'timeout'}"
        )

    def preflight(self) -> dict[str, Any]:
        info = self.client.info()
        metrics = self._metrics()
        identity = nested(metrics, "identity")
        required_identity = (
            "deviceId",
            "firmwareCommit",
            "board",
            "buildProfile",
            "bootId",
            "resetReason",
        )
        if any(key not in identity for key in required_identity):
            raise BenchmarkError("renderer metrics lack exact build/boot identity")
        firmware = info.get("firmware")
        session = info.get("session")
        target = info.get("target")
        if (
            info.get("ok") is not True
            or info.get("schema") != SCHEMA_VERSION
            or not isinstance(session, dict)
            or session.get("active") is not True
            or session.get("mode") != "debug"
            or target not in TARGET_ROTATIONS
            or info.get("viewRotation") != TARGET_ROTATIONS.get(target)
            or info.get("pixelFormat") != "rgb565le"
            or not isinstance(info.get("deviceId"), str)
            or len(info["deviceId"]) != 16
            or any(value not in "0123456789abcdef" for value in info["deviceId"])
            or not isinstance(firmware, dict)
            or firmware.get("target") != target
            or not valid_lowercase_hex(firmware.get("gitSha"), 40)
            or not isinstance(firmware.get("version"), str)
            or not firmware["version"]
            or isinstance(firmware.get("build"), bool)
            or not isinstance(firmware.get("build"), int)
        ):
            raise BenchmarkError("remote-debug info identity is invalid")
        if identity["deviceId"] != info["deviceId"]:
            raise BenchmarkError("info and renderer metrics device IDs disagree")
        if identity["board"] != info["target"]:
            raise BenchmarkError("info and renderer metrics targets disagree")
        if (
            not valid_lowercase_hex(identity["firmwareCommit"], 40)
            or identity["firmwareCommit"] != firmware.get("gitSha")
            or identity["buildProfile"] != info.get("buildProfile")
            or identity["board"] != target
            or identity["buildProfile"] != f"{target}_REMOTE_DEBUG"
        ):
            raise BenchmarkError(
                "info and renderer metrics build identities disagree"
            )
        if (
            isinstance(identity["bootId"], bool)
            or not isinstance(identity["bootId"], int)
            or not 0 <= identity["bootId"] <= 0xFFFFFFFF
            or isinstance(identity["resetReason"], bool)
            or not isinstance(identity["resetReason"], int)
            or not 0 <= identity["resetReason"] <= 0xFFFFFFFF
        ):
            raise BenchmarkError("renderer metrics boot identity is invalid")
        if "REMOTE_DEBUG" not in str(identity["buildProfile"]).upper():
            raise BenchmarkError("renderer sweep requires a remote-debug build")
        self.baseline_identity = {
            key: identity[key] for key in required_identity
        }
        self.view_rotation = info["viewRotation"]
        return {"info": info, "metrics": metrics}

    def _window_matches(
        self, snapshot: dict[str, Any], *, window_id: int, run_id: str, profile: str
    ) -> bool:
        return (
            nested(snapshot, "window", "id") == window_id
            and nested(snapshot, "window", "runId") == run_id
            and nested(snapshot, "tuning", "profile") == profile
        )

    def _wait_for_window(
        self,
        *,
        window_id: int,
        run_id: str,
        profile: str,
        timeout_seconds: float = 10,
    ) -> dict[str, Any]:
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            remaining = max(0.1, deadline - time.monotonic())
            snapshot = self._metrics(timeout_seconds=min(1, remaining))
            if self._window_matches(
                snapshot, window_id=window_id, run_id=run_id, profile=profile
            ):
                return snapshot
            time.sleep(0.35)
        raise BenchmarkError("device did not apply the requested renderer window")

    def _begin_window(self, *, profile: str, run_id: str, repeat: int) -> int:
        return self.client.begin_renderer_window(
            profile=profile,
            run_id=run_id,
            repeat=repeat,
            map_fixture_id=self.map_fixture_id,
            map_fixture_sha256=self.map_fixture_sha256,
            route_fixture_id=self.route_fixture["id"],
            route_fixture_sha256=self.route_fixture_sha256,
            route_mode=self.route_mode,
        )

    def restore_current_profile(self) -> None:
        """Best-effort safety cleanup for completed or interrupted sweeps."""
        run_id = f"{self.root_run_id}-cleanup"
        deadline = time.monotonic() + 5
        last_error: Exception | None = None
        while time.monotonic() < deadline:
            try:
                window_id = self._begin_window(
                    profile="current", run_id=run_id, repeat=1
                )
                self._wait_for_window(
                    window_id=window_id,
                    run_id=run_id,
                    profile="current",
                    timeout_seconds=1.5,
                )
                return
            except (BenchmarkError, DebugClientError) as exc:
                last_error = exc
                time.sleep(0.4)
        raise BenchmarkError(
            "could not restore the current renderer profile: "
            f"{last_error or 'timeout'}"
        )

    def _warm_up(self, *, profile: str, repeat: int) -> None:
        run_id = f"{self.root_run_id}-w-{profile[0]}{repeat}"
        window_id = self._begin_window(
            profile=profile, run_id=run_id, repeat=repeat
        )
        self._wait_for_window(
            window_id=window_id, run_id=run_id, profile=profile
        )
        deadline = time.monotonic() + 12
        marker_confirmed_at: float | None = None
        while time.monotonic() < deadline:
            snapshot = self._metrics()
            replay = nested(snapshot, "routeReplay")
            if replay.get("valid") is True and replay.get("fixtureMatches") is True:
                marker_confirmed_at = time.monotonic()
                break
            time.sleep(0.5)
        if marker_confirmed_at is None:
            raise BenchmarkError(
                "no matching 1 Hz iPhone replay marker; start Pinned Replay in Developer settings"
            )
        while time.monotonic() - marker_confirmed_at < self.warmup_seconds:
            self._metrics()
            time.sleep(self.poll_interval_seconds)

    def _capture_screenshot(
        self, *, profile: str, repeat: int, checkpoint: int, sample_index: int
    ) -> dict[str, Any]:
        filename = (
            f"{profile}-repeat-{repeat:02d}-checkpoint-{checkpoint:03d}"
            f"-sample-{sample_index:03d}.png"
        )
        path = self.output / "screenshots" / filename
        deadline = time.monotonic() + 4
        last_error: Exception | None = None
        while time.monotonic() < deadline:
            try:
                metadata, pixels = self.client.frame(after=self.last_frame_sequence)
                self.last_frame_sequence = metadata["sequence"]
                write_rgb565_png(
                    path,
                    metadata["width"],
                    metadata["height"],
                    metadata["stride"],
                    pixels,
                    self.view_rotation,
                )
                return {
                    "checkpointSampleIndex": checkpoint,
                    "observedSampleIndex": sample_index,
                    "frameSequence": metadata["sequence"],
                    "capturedAtMs": metadata["capturedAtMs"],
                    "path": f"screenshots/{filename}",
                    "bytes": path.stat().st_size,
                    "sha256": sha256_file(path),
                }
            except DebugClientError as exc:
                last_error = exc
                time.sleep(0.25)
        raise BenchmarkError(f"checkpoint screenshot failed: {last_error}")

    def execute_run(
        self, *, profile: str, repeat: int, duration_seconds: int, soak: bool = False
    ) -> dict[str, Any]:
        if self.baseline_identity is None:
            raise BenchmarkError("preflight was not completed")
        self._warm_up(profile=profile, repeat=repeat)
        run_id = f"{self.root_run_id}-{'s' if soak else 'r'}-{profile[0]}{repeat}"
        window_id = self._begin_window(
            profile=profile, run_id=run_id, repeat=repeat
        )
        first = self._wait_for_window(
            window_id=window_id, run_id=run_id, profile=profile
        )
        failures = validate_snapshot_identity(
            first,
            baseline=self.baseline_identity,
            profile=profile,
            run_id=run_id,
            repeat=repeat,
            map_fixture_id=self.map_fixture_id,
            map_fixture_sha256=self.map_fixture_sha256,
            route_fixture_id=self.route_fixture["id"],
            route_fixture_sha256=self.route_fixture_sha256,
            route_mode=self.route_mode,
            window_id=window_id,
        )
        if failures:
            raise BenchmarkError(", ".join(failures))

        checkpoint_indexes = expected_checkpoint_indexes(
            len(self.route_fixture["points"]), self.gates["checkpointFractions"]
        )
        pending_checkpoints = set(checkpoint_indexes)
        screenshots: list[dict[str, Any]] = []
        snapshots: list[dict[str, Any]] = []
        samples: list[dict[str, Any]] = []
        started = time.monotonic()
        deadline = started + duration_seconds
        previous_sequence: int | None = None
        previous_timestamp: int | None = None
        while time.monotonic() < deadline:
            snapshot = self._metrics()
            identity_failures = validate_snapshot_identity(
                snapshot,
                baseline=self.baseline_identity,
                profile=profile,
                run_id=run_id,
                repeat=repeat,
                map_fixture_id=self.map_fixture_id,
                map_fixture_sha256=self.map_fixture_sha256,
                route_fixture_id=self.route_fixture["id"],
                route_fixture_sha256=self.route_fixture_sha256,
                route_mode=self.route_mode,
                window_id=window_id,
            )
            if identity_failures:
                raise BenchmarkError(", ".join(identity_failures))
            sequence = snapshot["sequence"]
            timestamp = snapshot["timestampMs"]
            if previous_sequence is not None:
                sequence_delta = _uint32_forward_delta(
                    sequence, previous_sequence
                )
                if sequence_delta == 0 or sequence_delta >= 0x80000000:
                    raise BenchmarkError(
                        "metrics sequence regressed; reset or stale response"
                    )
            if previous_timestamp is not None:
                timestamp_delta = _uint32_forward_delta(
                    timestamp, previous_timestamp
                )
                if timestamp_delta == 0 or timestamp_delta >= 0x80000000:
                    raise BenchmarkError(
                        "device timestamp regressed; reset detected"
                    )
            previous_sequence = sequence
            previous_timestamp = timestamp
            elapsed = time.monotonic() - started
            snapshots.append(snapshot)
            samples.append(compact_sample(snapshot, elapsed))

            replay = nested(snapshot, "routeReplay")
            sample_index = replay.get("sampleIndex")
            sample_count = replay.get("sampleCount")
            if (
                replay.get("valid") is True
                and replay.get("fixtureMatches") is True
                and sample_count == len(self.route_fixture["points"])
                and isinstance(sample_index, int)
            ):
                tolerance = self.gates["checkpointToleranceSamples"]
                for checkpoint in sorted(pending_checkpoints):
                    if circular_sample_distance(
                        sample_index, checkpoint, sample_count
                    ) <= tolerance:
                        if self.capture_screenshots:
                            try:
                                screenshots.append(
                                    self._capture_screenshot(
                                        profile=profile,
                                        repeat=repeat,
                                        checkpoint=checkpoint,
                                        sample_index=sample_index,
                                    )
                                )
                            except BenchmarkError as exc:
                                failures.append(str(exc))
                        else:
                            screenshots.append(
                                {
                                    "checkpointSampleIndex": checkpoint,
                                    "observedSampleIndex": sample_index,
                                    "path": None,
                                }
                            )
                        pending_checkpoints.remove(checkpoint)
            sleep_seconds = min(
                self.poll_interval_seconds,
                max(0, deadline - time.monotonic()),
            )
            if sleep_seconds > 0:
                time.sleep(sleep_seconds)

        if not snapshots:
            raise BenchmarkError("measurement window produced no metrics")
        summary = summarize_run(snapshots, samples)
        failures.extend(
            evaluate_run(
                snapshots=snapshots,
                samples=samples,
                summary=summary,
                duration_seconds=duration_seconds,
                poll_interval_seconds=self.poll_interval_seconds,
                screenshots=screenshots,
                checkpoint_count=len(checkpoint_indexes),
                expected_route_sample_count=len(self.route_fixture["points"]),
                gates=self.gates,
            )
        )
        post_info = self.client.info()
        if post_info.get("deviceId") != self.baseline_identity["deviceId"]:
            failures.append("device_reset_or_replaced")
        result = {
            "schema": SCHEMA_VERSION,
            "runId": run_id,
            "windowId": window_id,
            "profile": profile,
            "repeat": repeat,
            "durationSeconds": duration_seconds,
            "soak": soak,
            "passed": not failures,
            "failures": sorted(set(failures)),
            "summary": summary,
            "samples": samples,
            "screenshots": screenshots,
            "finalSnapshot": snapshots[-1],
        }
        return result


def write_reports(report: dict[str, Any], output: Path) -> None:
    json_path = output / "renderer-benchmark.json"
    json_path.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    rows = report["runs"] + ([report["soakRun"]] if report.get("soakRun") else [])
    csv_fields = [
        "runId",
        "profile",
        "repeat",
        "durationSeconds",
        "soak",
        "passed",
        "failures",
        "renderCount",
        "renderP95Ms",
        "buildingP95Ms",
        "uiMaximumGapMs",
        "flushP95Ms",
        "minimumInternalFree",
        "minimumInternalLargest",
        "minimumPsramFree",
        "minimumPsramLargest",
        "candidateBuildings",
        "selectedBuildings",
        "extrudedBuildings",
        "flatBuildings",
        "deferredBuildings",
        "oversizedBuildings",
        "renderedBuildings",
        "extrudedP90DistancePx",
        "extrudedFarthestDistancePx",
        "staleRenders",
        "cancelledRenders",
        "invariantFailures",
        "gpsPackets",
    ]
    with (output / "renderer-benchmark.csv").open(
        "w", encoding="utf-8", newline=""
    ) as destination:
        writer = csv.DictWriter(destination, fieldnames=csv_fields)
        writer.writeheader()
        for run in rows:
            row = {
                "runId": run["runId"],
                "profile": run["profile"],
                "repeat": run["repeat"],
                "durationSeconds": run["durationSeconds"],
                "soak": run["soak"],
                "passed": run["passed"],
                "failures": ";".join(run["failures"]),
            }
            row.update(
                {
                    key: run["summary"].get(key)
                    for key in csv_fields
                    if key in run["summary"]
                }
            )
            writer.writerow(row)

    lines = [
        "# Renderer benchmark",
        "",
        f"- Result: **{'PASS' if report['passed'] else 'FAIL'}**",
        f"- Device: `{report['identity']['deviceId']}`",
        f"- Firmware: `{report['identity']['firmwareCommit']}`",
        f"- Target/build: `{report['identity']['board']}` / `{report['identity']['buildProfile']}`",
        f"- Map fixture: `{report['fixtures']['map']['id']}` / `{report['fixtures']['map']['sha256']}`",
        f"- Route fixture: `{report['fixtures']['route']['id']}` / `{report['fixtures']['route']['sha256']}`",
        f"- Pareto candidate for soak: `{report['pareto']['selected'] or 'none'}`",
        "",
        "## Comparison runs",
        "",
        "| Profile | Repeat | Pass | Render p95 | Building p95 | UI max | Flush p95 | Internal min | PSRAM min | Candidates | Selected | Extruded | Flat | Deferred | Reach p90/farthest |",
        "|---|---:|:---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for run in report["runs"]:
        summary = run["summary"]
        lines.append(
            f"| {run['profile']} | {run['repeat']} | {'yes' if run['passed'] else 'no'} | "
            f"{summary['renderP95Ms']} ms | {summary['buildingP95Ms']} ms | "
            f"{summary['uiMaximumGapMs']} ms | {summary['flushP95Ms']} ms | "
            f"{summary['minimumInternalFree']} | {summary['minimumPsramFree']} | "
            f"{summary['candidateBuildings']:.1f} | {summary['selectedBuildings']:.1f} | "
            f"{summary['extrudedBuildings']:.1f} | {summary['flatBuildings']:.1f} | "
            f"{summary['deferredBuildings']:.1f} | "
            f"{summary['extrudedP90DistancePx']:.1f}/{summary['extrudedFarthestDistancePx']:.1f} px |"
        )
    lines.extend(["", "## Soak", ""])
    soak = report.get("soakRun")
    if soak is None:
        lines.append("No soak run completed.")
    else:
        soak_summary = soak["summary"]
        lines.append(
            f"`{soak['profile']}` ran for {soak['durationSeconds']} seconds: "
            f"**{'PASS' if soak['passed'] else 'FAIL'}**; render p95 "
            f"{soak_summary['renderP95Ms']} ms, internal minimum "
            f"{soak_summary['minimumInternalFree']} bytes, PSRAM minimum "
            f"{soak_summary['minimumPsramFree']} bytes."
        )
    failed = [run for run in rows if not run["passed"]]
    lines.extend(["", "## Gate failures", ""])
    if report.get("cleanupFailure"):
        lines.append(
            "- `profile_cleanup`: " + str(report["cleanupFailure"])
        )
    if failed:
        for run in failed:
            lines.append(
                f"- `{run['runId']}`: " + ", ".join(run["failures"])
            )
    elif not report.get("cleanupFailure"):
        lines.append("None.")
    lines.extend(["", "## Checkpoint screenshots", ""])
    screenshot_count = 0
    for run in rows:
        for screenshot in run["screenshots"]:
            if screenshot.get("path"):
                screenshot_count += 1
                lines.extend(
                    [
                        f"### {run['profile']} repeat {run['repeat']} — sample {screenshot['checkpointSampleIndex']}",
                        "",
                        f"![checkpoint]({screenshot['path']})",
                        "",
                    ]
                )
    if screenshot_count == 0:
        lines.append("Screenshots were disabled for this partial run.")
    lines.extend(
        [
            "",
            "## Remaining physical acceptance",
            "",
            "This report ranks and rejects profiles; it does not establish AMOLED motion/tearing, daylight readability, touch behavior, natural Core Location/BLE jitter, battery/thermal impact, ordinary-firmware overhead, or acceptance on both display targets.",
            "",
        ]
    )
    (output / "renderer-benchmark.md").write_text(
        "\n".join(lines), encoding="utf-8"
    )


def _uint32_forward_delta(current: int, previous: int) -> int:
    if (
        isinstance(current, bool)
        or not isinstance(current, int)
        or isinstance(previous, bool)
        or not isinstance(previous, int)
        or not 0 <= current <= 0xFFFFFFFF
        or not 0 <= previous <= 0xFFFFFFFF
    ):
        raise BenchmarkError("ordinary capture has an invalid uint32 clock")
    return (current - previous) & 0xFFFFFFFF


def is_full_comparison_evidence(
    comparison: dict[str, Any],
    *,
    comparison_root: Path,
    expected_profile: str | None,
    gates: dict[str, Any],
    gates_sha256: str,
) -> bool:
    configuration = comparison.get("configuration")
    soak = comparison.get("soakRun")
    runs = comparison.get("runs")
    tool = comparison.get("tool")
    if not all(
        isinstance(value, dict)
        for value in (configuration, soak, tool)
    ) or not isinstance(runs, list):
        return False

    profiles = configuration.get("profiles")
    repeats = configuration.get("repeats")
    comparison_seconds = configuration.get("comparisonSeconds")
    soak_seconds = configuration.get("soakSeconds")
    route = nested(comparison, "fixtures", "route")
    route_sample_count = route.get("sampleCount")
    if (
        isinstance(route_sample_count, bool)
        or not isinstance(route_sample_count, int)
        or not 60 <= route_sample_count <= 120
    ):
        return False
    if (
        configuration.get("partial") is not False
        or not isinstance(profiles, list)
        or len(profiles) != len(PROFILES)
        or any(not isinstance(profile, str) for profile in profiles)
        or set(profiles) != set(PROFILES)
        or isinstance(repeats, bool)
        or not isinstance(repeats, int)
        or not 3 <= repeats <= 100
        or isinstance(comparison_seconds, bool)
        or not isinstance(comparison_seconds, int)
        or comparison_seconds != route_sample_count
        or isinstance(soak_seconds, bool)
        or not isinstance(soak_seconds, int)
        or soak_seconds < 300
        or configuration.get("gates") != gates
        or configuration.get("schedule")
        != balanced_profile_schedule(repeats, profiles)
        or tool.get("sha256") != sha256_file(Path(__file__))
        or tool.get("gatesSha256") != gates_sha256
        or comparison.get("profileRestoredToCurrent") is not True
        or comparison.get("cleanupFailure") is not None
        or expected_profile not in PROFILES
    ):
        return False

    expected_checkpoints = set(
        expected_checkpoint_indexes(
            route_sample_count, gates["checkpointFractions"]
        )
    )
    seen_screenshot_paths: set[str] = set()

    def screenshots_are_complete(value: Any) -> bool:
        if not isinstance(value, list) or len(value) != len(expected_checkpoints):
            return False
        observed_checkpoints: set[int] = set()
        for screenshot in value:
            if not isinstance(screenshot, dict):
                return False
            checkpoint = screenshot.get("checkpointSampleIndex")
            observed = screenshot.get("observedSampleIndex")
            path_text = screenshot.get("path")
            byte_count = screenshot.get("bytes")
            digest = screenshot.get("sha256")
            if (
                isinstance(checkpoint, bool)
                or not isinstance(checkpoint, int)
                or checkpoint not in expected_checkpoints
                or isinstance(observed, bool)
                or not isinstance(observed, int)
                or not 0 <= observed < route_sample_count
                or circular_sample_distance(
                    checkpoint, observed, route_sample_count
                ) > gates["checkpointToleranceSamples"]
                or not isinstance(path_text, str)
                or not path_text
                or len(path_text) > 255
                or "\\" in path_text
                or path_text in seen_screenshot_paths
                or isinstance(byte_count, bool)
                or not isinstance(byte_count, int)
                or not 0 < byte_count <= 8 * 1024 * 1024
                or not valid_lowercase_sha256(digest)
            ):
                return False
            relative = PurePosixPath(path_text)
            if (
                relative.is_absolute()
                or not relative.parts
                or relative.parts[0] != "screenshots"
                or any(part in ("", ".", "..") for part in relative.parts)
            ):
                return False
            candidate = comparison_root.joinpath(*relative.parts)
            try:
                if (
                    not candidate.is_file()
                    or candidate.stat().st_size != byte_count
                    or sha256_file(candidate) != digest
                ):
                    return False
            except OSError:
                return False
            seen_screenshot_paths.add(path_text)
            observed_checkpoints.add(checkpoint)
        return observed_checkpoints == expected_checkpoints

    expected_pairs = {
        (profile, repeat)
        for profile in profiles
        for repeat in range(1, repeats + 1)
    }
    observed_pairs: set[tuple[str, int]] = set()
    for run in runs:
        if not isinstance(run, dict):
            return False
        profile = run.get("profile")
        repeat = run.get("repeat")
        screenshots = run.get("screenshots")
        if (
            profile not in PROFILES
            or isinstance(repeat, bool)
            or not isinstance(repeat, int)
            or run.get("schema") != SCHEMA_VERSION
            or run.get("passed") is not True
            or run.get("soak") is not False
            or run.get("durationSeconds") != comparison_seconds
            or not screenshots_are_complete(screenshots)
        ):
            return False
        observed_pairs.add((profile, repeat))
    if len(runs) != len(expected_pairs) or observed_pairs != expected_pairs:
        return False

    return (
        soak.get("schema") == SCHEMA_VERSION
        and soak.get("passed") is True
        and soak.get("soak") is True
        and soak.get("profile") == expected_profile
        and soak.get("repeat") == repeats + 1
        and soak.get("durationSeconds") == soak_seconds
        and screenshots_are_complete(soak.get("screenshots"))
    )


def evaluate_ordinary_capture(
    *,
    capture_path: Path,
    comparison_path: Path | None,
    map_fixture: dict[str, Any],
    route_fixture: dict[str, Any],
    route_fixture_sha256: str,
    gates: dict[str, Any],
    gates_sha256: str,
    allow_partial: bool,
) -> dict[str, Any]:
    capture = load_json_object(capture_path, "ordinary diagnostics capture")
    snapshots = capture.get("snapshots")
    declared_route = capture.get("routeFixture")
    if (
        capture.get("schema") != SCHEMA_VERSION
        or capture.get("kind") != "ordinary-renderer-diagnostics"
        or not isinstance(snapshots, list)
        or not snapshots
        or len(snapshots) > 128
        or declared_route
        != {
            "id": route_fixture["id"],
            "sha256": route_fixture_sha256,
            "mode": "ordinary-ble-1hz",
        }
        or any(not isinstance(snapshot, dict) for snapshot in snapshots)
    ):
        raise BenchmarkError("ordinary diagnostics capture schema is invalid")

    first = snapshots[0]
    identity = nested(first, "identity")
    window = nested(first, "window")
    profile = nested(first, "tuning", "profile")
    if profile not in PROFILES:
        raise BenchmarkError("ordinary capture has an unknown tuning profile")
    baseline = {
        key: identity.get(key)
        for key in (
            "deviceId",
            "firmwareCommit",
            "board",
            "buildProfile",
            "bootId",
            "resetReason",
        )
    }
    if (
        not valid_lowercase_hex(baseline["deviceId"], 16)
        or not valid_lowercase_hex(baseline["firmwareCommit"], 40)
        or baseline["board"] not in TARGET_ROTATIONS
        or not isinstance(baseline["buildProfile"], str)
        or baseline["buildProfile"] != baseline["board"]
        or isinstance(baseline["bootId"], bool)
        or not isinstance(baseline["bootId"], int)
        or not 0 <= baseline["bootId"] <= 0xFFFFFFFF
        or isinstance(baseline["resetReason"], bool)
        or not isinstance(baseline["resetReason"], int)
        or not 0 <= baseline["resetReason"] <= 0xFFFFFFFF
    ):
        raise BenchmarkError("ordinary capture lacks exact build identity")
    window_id = window.get("id")
    run_id = window.get("runId")
    repeat = window.get("repeat")
    if (
        isinstance(window_id, bool)
        or not isinstance(window_id, int)
        or not 0x80000000 <= window_id <= 0xFFFFFFFF
        or not isinstance(run_id, str)
        or len(run_id) != 20
        or not run_id.startswith("ble-")
        or not valid_lowercase_hex(run_id[4:], 16)
        or isinstance(repeat, bool)
        or not isinstance(repeat, int)
        or not 1 <= repeat <= 0xFFFF
    ):
        raise BenchmarkError("ordinary capture lacks a BLE measurement window")

    failures: list[str] = []
    samples: list[dict[str, Any]] = []
    previous_sequence: int | None = None
    previous_timestamp: int | None = None
    total_elapsed_ms = 0
    gap_ms: list[int] = []
    for snapshot in snapshots:
        failures.extend(
            validate_snapshot_identity(
                snapshot,
                baseline=baseline,
                profile=profile,
                run_id=run_id,
                repeat=repeat,
                map_fixture_id=map_fixture["id"],
                map_fixture_sha256=map_fixture["manifestReceipt"],
                route_fixture_id=route_fixture["id"],
                route_fixture_sha256=route_fixture_sha256,
                route_mode="ordinary-ble-1hz",
                window_id=window_id,
            )
        )
        sequence = snapshot.get("sequence")
        timestamp = snapshot.get("timestampMs")
        if previous_sequence is not None:
            sequence_delta = _uint32_forward_delta(sequence, previous_sequence)
            if sequence_delta == 0 or sequence_delta >= 0x80000000:
                failures.append("stale_metrics_sequence")
        if previous_timestamp is not None:
            delta = _uint32_forward_delta(timestamp, previous_timestamp)
            if delta == 0 or delta >= 0x80000000:
                failures.append("stale_device_timestamp")
            else:
                total_elapsed_ms += delta
                gap_ms.append(delta)
        samples.append(compact_sample(snapshot, total_elapsed_ms / 1000))
        previous_sequence = sequence
        previous_timestamp = timestamp

    duration_seconds = total_elapsed_ms // 1000
    if any(value > 8000 for value in gap_ms):
        failures.append("missing_ordinary_snapshot")
    if not allow_partial and total_elapsed_ms < 60_000:
        failures.append("ordinary_capture_shorter_than_60_seconds")
    summary = summarize_run(snapshots, samples)
    failures.extend(
        evaluate_run(
            snapshots=snapshots,
            samples=samples,
            summary=summary,
            duration_seconds=duration_seconds,
            poll_interval_seconds=5,
            screenshots=[],
            checkpoint_count=0,
            expected_route_sample_count=len(route_fixture["points"]),
            gates=gates,
            expect_remote_debug=False,
        )
    )

    comparison: dict[str, Any] | None = None
    expected_profile: str | None = None
    if comparison_path is not None:
        comparison = load_json_object(
            comparison_path, "remote-debug comparison report"
        )
        expected_profile = nested(comparison, "pareto", "selected")
        if comparison.get("schema") != SCHEMA_VERSION:
            failures.append("comparison_schema")
        if comparison.get("passed") is not True:
            failures.append("comparison_did_not_pass")
        if expected_profile != profile:
            failures.append("ordinary_profile_is_not_pareto_candidate")
        comparison_identity = comparison.get("identity")
        if not isinstance(comparison_identity, dict):
            failures.append("comparison_identity")
        else:
            for key in ("deviceId", "firmwareCommit", "board"):
                if comparison_identity.get(key) != baseline[key]:
                    failures.append(f"comparison_identity:{key}")
        comparison_map = nested(comparison, "fixtures", "map")
        comparison_route = nested(comparison, "fixtures", "route")
        if not allow_partial and not is_full_comparison_evidence(
            comparison,
            comparison_root=comparison_path.parent,
            expected_profile=expected_profile,
            gates=gates,
            gates_sha256=gates_sha256,
        ):
            failures.append("comparison_is_not_full_acceptance_evidence")
        if (
            comparison_map.get("id") != map_fixture["id"]
            or comparison_map.get("manifestReceipt")
            != map_fixture["manifestReceipt"]
            or comparison_map.get("artifactSha256")
            != map_fixture["artifactSha256"]
        ):
            failures.append("comparison_map_fixture")
        if (
            comparison_route.get("id") != route_fixture["id"]
            or comparison_route.get("sha256") != route_fixture_sha256
        ):
            failures.append("comparison_route_fixture")
    elif not allow_partial:
        failures.append("missing_remote_debug_comparison")

    failures = sorted(set(failures))
    return {
        "schema": SCHEMA_VERSION,
        "kind": "ordinary-renderer-confirmation",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "passed": not failures,
        "failures": failures,
        "identity": baseline,
        "window": {
            "id": window_id,
            "runId": run_id,
            "repeat": repeat,
            "profile": profile,
        },
        "fixtures": {
            "map": map_fixture,
            "route": {
                "id": route_fixture["id"],
                "sha256": route_fixture_sha256,
                "mode": "ordinary-ble-1hz",
            },
        },
        "durationSeconds": duration_seconds,
        "snapshotCount": len(snapshots),
        "maximumCaptureGapMs": max(gap_ms, default=0),
        "summary": summary,
        "samples": samples,
        "expectedProfile": expected_profile,
        "comparisonReport": (
            comparison_path.name if comparison_path is not None else None
        ),
        "comparisonReportSha256": (
            sha256_file(comparison_path) if comparison_path is not None else None
        ),
        "partial": allow_partial,
        "tool": {
            "sha256": sha256_file(Path(__file__)),
            "gatesSha256": gates_sha256,
        },
    }


def write_ordinary_report(report: dict[str, Any], output: Path) -> None:
    (output / "ordinary-renderer-confirmation.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    summary = report["summary"]
    lines = [
        "# Ordinary renderer confirmation",
        "",
        f"- Result: **{'PASS' if report['passed'] else 'FAIL'}**",
        f"- Device: `{report['identity']['deviceId']}`",
        f"- Firmware: `{report['identity']['firmwareCommit']}`",
        f"- Target/build: `{report['identity']['board']}` / "
        f"`{report['identity']['buildProfile']}`",
        f"- Profile: `{report['window']['profile']}` "
        f"(expected `{report['expectedProfile'] or 'not supplied'}`)",
        f"- Capture: {report['durationSeconds']} seconds / "
        f"{report['snapshotCount']} snapshots / "
        f"{report['maximumCaptureGapMs']} ms maximum gap",
        f"- Render p95: {summary['renderP95Ms']} ms",
        f"- UI maximum gap: {summary['uiMaximumGapMs']} ms",
        f"- Flush p95: {summary['flushP95Ms']} ms",
        f"- Internal heap minimum/largest: "
        f"{summary['minimumInternalFree']} / "
        f"{summary['minimumInternalLargest']} bytes",
        f"- PSRAM minimum/largest: {summary['minimumPsramFree']} / "
        f"{summary['minimumPsramLargest']} bytes",
        f"- Buildings candidate/selected/extruded/flat/deferred: "
        f"{summary['candidateBuildings']:.1f} / "
        f"{summary['selectedBuildings']:.1f} / "
        f"{summary['extrudedBuildings']:.1f} / "
        f"{summary['flatBuildings']:.1f} / "
        f"{summary['deferredBuildings']:.1f}",
        "",
        "## Gate failures",
        "",
    ]
    if report["failures"]:
        lines.extend(f"- `{failure}`" for failure in report["failures"])
    else:
        lines.append("None.")
    lines.extend(
        [
            "",
            "This confirms the selected profile without remote-debug Wi-Fi "
            "or framebuffer overhead. Physical visual, ride, battery, thermal, "
            "and second-board acceptance remain separate gates.",
            "",
        ]
    )
    (output / "ordinary-renderer-confirmation.md").write_text(
        "\n".join(lines), encoding="utf-8"
    )


def resolve_session(args: argparse.Namespace) -> tuple[str, str]:
    stored: dict[str, Any] = {}
    if args.session_file:
        stored = _load_session(args.session_file)
    base_url = args.base_url or stored.get("baseUrl")
    if not isinstance(base_url, str) or not base_url:
        raise BenchmarkError("provide --base-url or a mode-0600 session file")
    parsed = parse.urlsplit(base_url)
    if parsed.scheme != "http" or not parsed.netloc or parsed.username or parsed.password:
        raise BenchmarkError("base URL must be absolute HTTP without credentials")
    clean_url = parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", ""))
    token = os.environ.get(TOKEN_ENV) or stored.get("token")
    if token is None:
        token = getpass.getpass("Transfer token: ")
    if not isinstance(token, str) or not token or any(value.isspace() for value in token):
        raise BenchmarkError("transfer token is missing or invalid")
    return clean_url.rstrip("/"), token


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--base-url")
    result.add_argument("--session-file", type=Path)
    result.add_argument("--map-fixture", required=True, type=Path)
    result.add_argument("--route-fixture", type=Path, default=DEFAULT_ROUTE_FIXTURE)
    result.add_argument("--gates", type=Path, default=DEFAULT_GATES)
    result.add_argument("--output", type=Path)
    result.add_argument(
        "--ordinary-capture",
        type=Path,
        help="evaluate an iPhone BLE capture instead of running HTTP profiles",
    )
    result.add_argument(
        "--comparison-report",
        type=Path,
        help="remote-debug renderer-benchmark.json used to bind the winner",
    )
    result.add_argument("--profiles", nargs="+", choices=PROFILES, default=list(PROFILES))
    result.add_argument("--repeats", type=int, default=3)
    result.add_argument("--comparison-seconds", type=int)
    result.add_argument("--soak-seconds", type=int, default=600)
    result.add_argument("--timeout", type=float, default=8)
    result.add_argument("--skip-screenshots", action="store_true")
    result.add_argument(
        "--allow-partial",
        action="store_true",
        help="allow shortened/developer runs that do not satisfy issue #210",
    )
    return result


def main() -> int:
    args = parser().parse_args()
    token = ""
    runner: BenchmarkRunner | None = None
    cleanup_attempted = False
    try:
        gates = load_gates(args.gates)
        duration = (
            args.comparison_seconds
            if args.comparison_seconds is not None
            else gates["comparisonDurationSeconds"]
        )
        if not args.map_fixture.is_file():
            raise BenchmarkError("map fixture must be an existing artifact or manifest file")
        if not args.route_fixture.is_file():
            raise BenchmarkError("route fixture file does not exist")
        route_fixture = validate_route_fixture(args.route_fixture)
        route_fixture_sha256 = sha256_file(args.route_fixture)
        map_fixture = load_map_fixture(args.map_fixture)
        validate_acceptance_inputs(
            route_fixture=route_fixture,
            route_fixture_sha256=route_fixture_sha256,
            gates=gates,
            allow_partial=args.allow_partial,
        )
        if args.ordinary_capture is not None:
            if not args.ordinary_capture.is_file():
                raise BenchmarkError("ordinary capture file does not exist")
            if (
                args.comparison_report is not None
                and not args.comparison_report.is_file()
            ):
                raise BenchmarkError("comparison report file does not exist")
            output = args.output or Path(
                "ordinary-renderer-confirmation-"
                + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            )
            if output.exists() and any(output.iterdir()):
                raise BenchmarkError("output directory already contains files")
            report = evaluate_ordinary_capture(
                capture_path=args.ordinary_capture,
                comparison_path=args.comparison_report,
                map_fixture=map_fixture,
                route_fixture=route_fixture,
                route_fixture_sha256=route_fixture_sha256,
                gates=gates,
                gates_sha256=sha256_file(args.gates),
                allow_partial=args.allow_partial,
            )
            output.mkdir(parents=True, exist_ok=True)
            write_ordinary_report(report, output)
            print(
                "renderer benchmark: wrote "
                f"{output / 'ordinary-renderer-confirmation.md'}"
            )
            return 0 if report["passed"] else 2
        if args.comparison_report is not None:
            raise BenchmarkError(
                "--comparison-report is only valid with --ordinary-capture"
            )
        if args.timeout <= 0:
            raise BenchmarkError("timeout must be positive")
        if not args.allow_partial and (
            args.repeats < 3
            or set(args.profiles) != set(PROFILES)
            or duration != len(route_fixture["points"])
            or args.soak_seconds < 300
            or args.skip_screenshots
        ):
            raise BenchmarkError(
                "full issue #210 runs require all profiles, 3+ repeats, one complete pinned-route loop, screenshots, and a 300+ second soak"
            )
        if (
            args.repeats <= 0
            or args.repeats > 100
            or duration <= 0
            or args.soak_seconds < 0
        ):
            raise BenchmarkError("repeat and duration values are invalid")
        if len(set(args.profiles)) != len(args.profiles):
            raise BenchmarkError("profiles must not be repeated")
        output = args.output or Path(
            "renderer-benchmark-"
            + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        )
        if output.exists() and any(output.iterdir()):
            raise BenchmarkError("output directory already contains files")
        base_url, token = resolve_session(args)
        runner = BenchmarkRunner(
            client=DebugClient(base_url, token, timeout=args.timeout),
            output=output,
            gates=gates,
            map_fixture_id=map_fixture["id"],
            map_fixture_sha256=map_fixture["manifestReceipt"],
            route_fixture=route_fixture,
            route_fixture_sha256=route_fixture_sha256,
            route_mode="ios-fixture-1hz",
            warmup_seconds=gates["warmupSeconds"],
            poll_interval_seconds=gates["pollIntervalSeconds"],
            capture_screenshots=not args.skip_screenshots,
        )
        preflight = runner.preflight()
        output.mkdir(parents=True, exist_ok=True)
        (output / "screenshots").mkdir(exist_ok=True)
        runs: list[dict[str, Any]] = []
        schedule = balanced_profile_schedule(args.repeats, args.profiles)
        for repeat_index, order in enumerate(schedule, start=1):
            for profile in order:
                print(
                    f"renderer benchmark: repeat {repeat_index}/{args.repeats} profile={profile}",
                    flush=True,
                )
                runs.append(
                    runner.execute_run(
                        profile=profile,
                        repeat=repeat_index,
                        duration_seconds=duration,
                    )
                )
        apply_cross_run_memory_gates(runs, gates)
        aggregate = aggregate_profiles(runs)
        pareto = choose_pareto_candidate(aggregate, gates)
        soak_run: dict[str, Any] | None = None
        if args.soak_seconds:
            selected = pareto["selected"]
            if selected is not None:
                print(
                    f"renderer benchmark: soak profile={selected} seconds={args.soak_seconds}",
                    flush=True,
                )
                soak_run = runner.execute_run(
                    profile=selected,
                    repeat=args.repeats + 1,
                    duration_seconds=args.soak_seconds,
                    soak=True,
                )
        cleanup_attempted = True
        cleanup_failure: str | None = None
        try:
            runner.restore_current_profile()
        except (BenchmarkError, DebugClientError) as exc:
            cleanup_failure = str(exc)
        report = {
            "schema": SCHEMA_VERSION,
            "generatedAt": datetime.now(timezone.utc).isoformat(),
            "passed": all(run["passed"] for run in runs)
            and (soak_run is None or soak_run["passed"])
            and (args.soak_seconds == 0 or soak_run is not None)
            and cleanup_failure is None,
            "identity": runner.baseline_identity,
            "initialResetReason": runner.baseline_identity["resetReason"],
            "fixtures": {
                "map": {
                    **map_fixture,
                    "sha256": runner.map_fixture_sha256,
                },
                "route": {
                    "id": route_fixture["id"],
                    "sha256": runner.route_fixture_sha256,
                    "mode": runner.route_mode,
                    "cadenceHz": 1,
                    "sampleCount": len(route_fixture["points"]),
                },
            },
            "configuration": {
                "profiles": args.profiles,
                "repeats": args.repeats,
                "schedule": schedule,
                "comparisonSeconds": duration,
                "soakSeconds": args.soak_seconds,
                "gates": gates,
                "partial": args.allow_partial,
            },
            "tool": {
                "sha256": sha256_file(Path(__file__)),
                "gatesSha256": sha256_file(args.gates),
            },
            "preflight": {
                "target": preflight["info"]["target"],
                "width": preflight["info"]["width"],
                "height": preflight["info"]["height"],
            },
            "runs": runs,
            "profileAggregates": aggregate,
            "pareto": pareto,
            "soakRun": soak_run,
            "profileRestoredToCurrent": cleanup_failure is None,
            "cleanupFailure": cleanup_failure,
            "manualAcceptanceRequired": [
                "AMOLED motion, tearing, color, and brightness",
                "daylight usefulness versus 3D clutter",
                "physical capacitive touch",
                "natural Core Location and BLE jitter ride",
                "battery and thermal impact",
                "ordinary diagnostics firmware confirmation",
                "Waveshare 1.75-inch physical acceptance",
                "Waveshare 2.06-inch physical acceptance",
            ],
        }
        write_reports(report, output)
        print(f"renderer benchmark: wrote {output / 'renderer-benchmark.md'}")
        return 0 if report["passed"] else 2
    except (
        BenchmarkError,
        DebugClientError,
        KeyError,
        OSError,
        TypeError,
        ValueError,
    ) as exc:
        message = str(exc).replace(token, "<redacted>") if token else str(exc)
        print(f"renderer_benchmark: {message}", file=sys.stderr)
        return 1
    finally:
        if runner is not None and not cleanup_attempted:
            try:
                runner.restore_current_profile()
            except (BenchmarkError, DebugClientError) as exc:
                message = (
                    str(exc).replace(token, "<redacted>")
                    if token
                    else str(exc)
                )
                print(
                    f"renderer_benchmark: cleanup warning: {message}",
                    file=sys.stderr,
                )


if __name__ == "__main__":
    raise SystemExit(main())
