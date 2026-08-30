#!/usr/bin/env python3
"""Validate and summarize Bicino ride-diagnostics bundles."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
import zipfile
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterable


SCHEMA = 1
MAX_BUNDLE_BYTES = 100 * 1024 * 1024
MAX_ENTRY_BYTES = 12 * 1024 * 1024
MAX_LINE_BYTES = 8 * 1024
MAX_COMPRESSION_RATIO = 1_000
ALLOWED_SOURCES = {"ios", "firmware", "host"}
ALLOWED_LEVELS = {"debug", "info", "warning", "error"}
ALLOWED_CATEGORIES = {
    "lifecycle",
    "boot",
    "ble",
    "navigation",
    "gps",
    "workout",
    "rideAutomation",
    "storage",
    "map",
    "power",
    "transfer",
    "user",
    "logger",
}
REQUIRED_KEYS = {"schema", "source", "sequence", "level", "category", "event"}
OPTIONAL_KEYS = {"wallTime", "uptimeMs", "processId", "captureId", "fields"}
REQUIRED_MANIFEST_KEYS = {
    "schema",
    "manifestSchema",
    "eventFormatSchema",
    "exportedAt",
    "appProcessId",
    "sourceStreams",
    "streamMetadata",
    "captureId",
    "selectedCaptureRange",
    "appBuildIdentity",
    "firmwareBuildIdentities",
    "oldestWallTime",
    "newestWallTime",
    "clockAnchorCount",
    "uptimeEventCount",
    "truncatedTailStreamCount",
    "retainedBytes",
    "droppedEventCount",
    "deviceDroppedEventCount",
    "checksumAlgorithm",
    "checksumFile",
    "archiveValidation",
    "privacy",
}
# Fields are intentionally a closed vocabulary.  Producers must add a field
# here and to the Swift transfer validator before it can enter an exported
# bundle; this prevents a future call site from quietly widening the privacy
# boundary.
ALLOWED_FIELD_KEYS = {
    "accuracy",
    "accuracyAvailable",
    "accuracyBucket",
    "active",
    "activeStage",
    "acknowledgedKind",
    "ageMs",
    "alertMode",
    "applyErrorCode",
    "applyErrorDomain",
    "applyResult",
    "attempt",
    "autoPauseEnabled",
    "authorization",
    "authorized",
    "available",
    "background",
    "blockLoadMs",
    "bootSequence",
    "bytes",
    "chunk",
    "clockSynchronized",
    "code",
    "connectCompleted",
    "connectDurationMs",
    "connectStarted",
    "connectionReused",
    "connectionState",
    "completedStage",
    "consecutiveEarlyFailures",
    "diagnosticHold",
    "domain",
    "droppedCount",
    "durationLimit",
    "durationMs",
    "errorCode",
    "errorDomain",
    "enqueuedCount",
    "eventCount",
    "firstMissingUptimeMs",
    "firmwareBuild",
    "firmwareFingerprint",
    "firmwareTarget",
    "fixValid",
    "formatVersion",
    "importedCount",
    "lastCriticalCategory",
    "lastCriticalEvent",
    "lastFailureStage",
    "lastFailureCompletedStage",
    "lastFailureResetReason",
    "lastGapMs",
    "lastMissingUptimeMs",
    "httpStatus",
    "localAccessorySubnet",
    "mapDetail",
    "mapId",
    "mapPhase",
    "mapProgressMs",
    "maxQueueDepth",
    "maximumGapMs",
    "messageBytes",
    "messageDigest",
    "kind",
    "mode",
    "networkObservation",
    "networkProtocol",
    "networkTransport",
    "navigating",
    "outcome",
    "profileVersion",
    "pendingControl",
    "proxyConnection",
    "queueDepth",
    "reason",
    "remoteEndpointMatched",
    "resetReason",
    "rideGeneration",
    "rideDetectionArmed",
    "routeLoaded",
    "runtimeBootSequence",
    "rssiBucket",
    "ready",
    "sampleCount",
    "safeMode",
    "scope",
    "sequence",
    "sessionPresent",
    "sha256Prefix",
    "simulation",
    "sourceHealthMask",
    "speedAvailable",
    "state",
    "startMode",
    "storage",
    "storageErrorCount",
    "fallback",
    "tlsChallenge",
    "tlsCompleted",
    "tlsDurationMs",
    "tlsStarted",
    "transition",
    "uiPhase",
    "uiProgressMs",
    "underlyingErrorCode",
    "underlyingErrorDomain",
    "result",
    "origin",
    "expectedState",
    "decisionSequence",
    "viewingMap",
    "visitedEntries",
    "waitedForConnectivity",
    "watchdogCoreMask",
    "watchdogUptimeMs",
    "workoutActive",
    "writerDetail",
    "writerPhase",
    "writerProgressMs",
    "writtenCount",
}
FIRMWARE_NUMBER_FIELD_KEYS = {
    "accuracy", "activeStage", "ageMs", "alertMode", "applyErrorCode",
    "attempt", "blockLoadMs",
    "bootSequence",
    "bytes", "chunk", "completedStage", "consecutiveEarlyFailures",
    "connectDurationMs", "decisionSequence", "droppedCount", "durationMs",
    "enqueuedCount", "errorCode", "eventCount", "firmwareBuild",
    "firstMissingUptimeMs", "formatVersion", "httpStatus",
    "importedCount", "lastGapMs",
    "lastFailureStage", "lastFailureCompletedStage", "lastFailureResetReason",
    "lastMissingUptimeMs", "mapDetail", "mapProgressMs", "maxQueueDepth",
    "maximumGapMs", "messageBytes", "profileVersion", "queueDepth",
    "resetReason", "rideGeneration",
    "runtimeBootSequence", "sampleCount", "sequence", "sourceHealthMask",
    "storageErrorCount", "tlsDurationMs", "uiProgressMs",
    "underlyingErrorCode", "visitedEntries", "watchdogCoreMask",
    "watchdogUptimeMs", "writerDetail", "writerProgressMs", "writtenCount",
}
FIRMWARE_BOOLEAN_FIELD_KEYS = {
    "accuracyAvailable", "active", "autoPauseEnabled", "authorized",
    "available", "background", "clockSynchronized", "connectCompleted",
    "connectStarted", "connectionReused", "diagnosticHold", "fallback",
    "fixValid", "localAccessorySubnet", "navigating", "pendingControl",
    "proxyConnection", "ready", "remoteEndpointMatched",
    "rideDetectionArmed", "routeLoaded", "safeMode", "sessionPresent",
    "simulation", "speedAvailable", "tlsCompleted", "tlsStarted",
    "viewingMap", "waitedForConnectivity", "workoutActive",
}
UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
APP_EVENT_MEMBER_RE = re.compile(
    r"^app/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-"
    r"[0-9a-f]{12}/events-[0-9]{6}\.jsonl$"
)
APP_MANIFEST_MEMBER_RE = re.compile(
    r"^app/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-"
    r"[0-9a-f]{12}/manifest\.json$"
)
DEVICE_EVENT_MEMBER_RE = re.compile(
    r"^device/[0-9a-f]{16}/[1-9][0-9]*/"
    r"events-[0-9]{6}-[0-9a-f]{16}\.jsonl$"
)
DEVICE_HEALTH_MEMBER_RE = re.compile(
    r"^device/[0-9a-f]{16}/[1-9][0-9]*/recorder-health\.json$"
)
STREAM_METADATA_KEYS = {
    "path",
    "source",
    "bytes",
    "sha256",
    "captureIds",
    "firstSequence",
    "lastSequence",
    "truncatedTail",
    "clockAnchors",
}
APP_RECORDER_MANIFEST_KEYS = {
    "schema",
    "source",
    "processId",
    "createdAt",
    "chunkLimitBytes",
    "retentionBytes",
    "retentionCaptureCount",
    "retentionAgeDays",
    "droppedEventCount",
}
RECORDER_HEALTH_KEYS = {
    "schema",
    "processId",
    "retainedBytes",
    "retainedChunkCount",
    "retainedCaptureCount",
    "oldestWallTime",
    "newestWallTime",
    "droppedEventCount",
    "lastError",
    "detailedTraceEnabled",
    "detailedTraceExpiresAt",
}
DEVICE_RECORDER_HEALTH_KEYS = {
    "schema",
    "source",
    "bootSequence",
    "activeChunk",
    "stats",
    "chunks",
}
DEVICE_RECORDER_STATS_KEYS = {
    "enqueued",
    "written",
    "dropped",
    "storageErrors",
}
DEVICE_RECORDER_CHUNK_KEYS = {
    "bootSequence",
    "chunk",
    "bytes",
    "sha256",
}
FORBIDDEN_KEY_PARTS = (
    "latitude",
    "longitude",
    "coordinate",
    "address",
    "instruction",
    "destination",
    "password",
    "passphrase",
    "secret",
    "apikey",
    "api_key",
    "credential",
    "token",
    "ownerkey",
    "healthkit",
    "heartrate",
    "heart_rate",
    "rawimu",
    "raw_imu",
    "payload",
)


class DiagnosticError(ValueError):
    """A bundle or event violates the diagnostics contract."""


def _fail(message: str) -> None:
    raise DiagnosticError(message)


def _check_privacy(value: Any, path: str = "fields") -> None:
    if isinstance(value, dict):
        if path == "fields" and len(value) > 32:
            _fail(f"too many values at {path}")
        for key, child in value.items():
            if path == "fields" and key not in ALLOWED_FIELD_KEYS:
                _fail(f"unknown field {path}.{key}")
            if path.startswith("fields") and isinstance(child, (dict, list)):
                _fail(f"nested value at {path}.{key} is not allowed")
            normalized = str(key).replace("-", "_").lower()
            if any(part in normalized for part in FORBIDDEN_KEY_PARTS):
                _fail(f"forbidden field {path}.{key}")
            _check_privacy(child, f"{path}.{key}")
    elif isinstance(value, list):
        if path.endswith((
            ".sourceStreams",
            ".streamMetadata",
            ".captureIds",
            ".clockAnchors",
            ".selectedCaptureRange",
        )):
            limit = 1024
        elif path.endswith((".chunks", ".firmwareBuildIdentities")):
            limit = 256
        else:
            limit = 32
        if len(value) > limit:
            _fail(f"unbounded array at {path}")
        for index, child in enumerate(value):
            _check_privacy(child, f"{path}[{index}]")
    elif isinstance(value, str):
        lower = value.lower()
        if "x-bikecomputer-transfer-token" in lower or "bearer " in lower:
            _fail(f"credential-like value at {path}")
        if path.startswith("fields.") and len(value.encode("utf-8")) > 256:
            _fail(f"unbounded string at {path}")
    elif isinstance(value, float) and not math.isfinite(value):
        _fail(f"non-finite number at {path}")


def validate_event(record: Any, source_path: str = "event") -> dict[str, Any]:
    if not isinstance(record, dict):
        _fail(f"{source_path} is not an object")
    keys = set(record)
    unknown = keys - REQUIRED_KEYS - OPTIONAL_KEYS
    missing = REQUIRED_KEYS - keys
    if missing:
        _fail(f"{source_path} missing {sorted(missing)}")
    if unknown:
        _fail(f"{source_path} has unknown keys {sorted(unknown)}")
    if (
        isinstance(record["schema"], bool)
        or not isinstance(record["schema"], int)
        or record["schema"] != SCHEMA
    ):
        _fail(f"{source_path} has unsupported schema")
    if not isinstance(record["source"], str) or record["source"] not in ALLOWED_SOURCES:
        _fail(f"{source_path} has unsupported source")
    if (
        isinstance(record["sequence"], bool)
        or not isinstance(record["sequence"], int)
        or record["sequence"] < 0
    ):
        _fail(f"{source_path}.sequence is invalid")
    if not isinstance(record["level"], str) or record["level"] not in ALLOWED_LEVELS:
        _fail(f"{source_path}.level is invalid")
    if (
        not isinstance(record["category"], str)
        or record["category"] not in ALLOWED_CATEGORIES
    ):
        _fail(f"{source_path}.category is invalid")
    if not isinstance(record["event"], str) or not record["event"] or len(record["event"]) > 64:
        _fail(f"{source_path}.event is invalid")
    if "wallTime" in record:
        if not isinstance(record["wallTime"], str):
            _fail(f"{source_path}.wallTime is invalid")
        try:
            parsed_wall_time = datetime.fromisoformat(
                record["wallTime"].replace("Z", "+00:00")
            )
        except ValueError as error:
            _fail(f"{source_path}.wallTime is invalid: {error}")
        if parsed_wall_time.tzinfo is None:
            _fail(f"{source_path}.wallTime is missing a timezone")
    for key in ("uptimeMs",):
        if key in record and (
            isinstance(record[key], bool)
            or not isinstance(record[key], int)
            or record[key] < 0
        ):
            _fail(f"{source_path}.{key} is invalid")
    for key in ("processId", "captureId"):
        if key in record and (not isinstance(record[key], str) or not UUID_RE.match(record[key])):
            _fail(f"{source_path}.{key} is invalid")
    if "fields" in record and not isinstance(record["fields"], dict):
        _fail(f"{source_path}.fields is not an object")
    _check_privacy(record.get("fields", {}))
    fields = record.get("fields", {})
    if record["source"] == "ios":
        for key, value in fields.items():
            if not isinstance(value, str):
                _fail(f"{source_path}.fields.{key} must be a string for ios")
    elif record["source"] == "firmware":
        for key, value in fields.items():
            if key in FIRMWARE_NUMBER_FIELD_KEYS:
                if isinstance(value, bool) or not isinstance(value, (int, float)):
                    _fail(f"{source_path}.fields.{key} must be numeric")
            elif key in FIRMWARE_BOOLEAN_FIELD_KEYS:
                if not isinstance(value, bool):
                    _fail(f"{source_path}.fields.{key} must be boolean")
            elif not isinstance(value, str):
                _fail(f"{source_path}.fields.{key} must be a string")
        boot_sequence = fields.get("bootSequence")
        if (
            isinstance(boot_sequence, bool)
            or not isinstance(boot_sequence, int)
            or not 0 < boot_sequence <= 0xFFFF_FFFF
        ):
            _fail(f"{source_path}.fields.bootSequence is invalid")
        fingerprint = fields.get("firmwareFingerprint")
        if (
            not isinstance(fingerprint, str)
            or re.fullmatch(r"[0-9a-fA-F]{8}", fingerprint) is None
        ):
            _fail(f"{source_path}.fields.firmwareFingerprint is invalid")
    return record


@dataclass
class StreamResult:
    path: str
    events: tuple[dict[str, Any], ...]
    truncated_tail: bool = False
    dropped_sequences: int = 0
    firmware_identity: tuple[int, str] | None = None


def validate_jsonl(data: bytes, source_path: str, expected_source: str | None = None) -> StreamResult:
    if len(data) > MAX_ENTRY_BYTES:
        _fail(f"{source_path} exceeds entry size limit")
    events: list[dict[str, Any]] = []
    previous_sequence: int | None = None
    firmware_identity: tuple[int, str] | None = None
    dropped = 0
    lines = data.splitlines(keepends=True)
    truncated_tail = False
    if data and not data.endswith(b"\n") and lines:
        # A clean producer may close immediately after a complete final JSON
        # object. Only classify the tail as recoverable when it is not JSON.
        try:
            json.loads(lines[-1])
        except (json.JSONDecodeError, UnicodeDecodeError):
            truncated_tail = True
            lines = lines[:-1]
    for index, raw in enumerate(lines, 1):
        # The line ceiling applies to the JSON record, not its framing LF.
        # Swift's Data.split likewise removes the delimiter before checking.
        record_bytes = raw[:-1] if raw.endswith(b"\n") else raw
        if len(record_bytes) > MAX_LINE_BYTES:
            _fail(f"{source_path}:{index} exceeds line size limit")
        try:
            record = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            _fail(f"{source_path}:{index} is invalid JSON: {error}")
        event = validate_event(record, f"{source_path}:{index}")
        if expected_source and event["source"] != expected_source:
            _fail(f"{source_path}:{index} source mismatch")
        if previous_sequence is not None:
            if event["sequence"] <= previous_sequence:
                _fail(f"{source_path}:{index} sequence is not increasing")
            dropped += event["sequence"] - previous_sequence - 1
        previous_sequence = event["sequence"]
        if event["source"] == "firmware":
            fields = event["fields"]
            identity = (fields["bootSequence"], fields["firmwareFingerprint"])
            if firmware_identity is not None and identity != firmware_identity:
                _fail(f"{source_path}:{index} changes firmware stream identity")
            firmware_identity = identity
        events.append(event)
    if not events:
        _fail(f"{source_path} contains no complete diagnostic events")
    return StreamResult(
        source_path,
        tuple(events),
        truncated_tail,
        dropped,
        firmware_identity,
    )


def _safe_member(name: str) -> bool:
    path = PurePosixPath(name)
    components = name.split("/")
    return (
        bool(name)
        and not path.is_absolute()
        and "\\" not in name
        and all(component not in {"", ".", ".."} for component in components)
    )


def _supported_bundle_member(name: str) -> bool:
    return (
        name in {
            "manifest.json",
            "checksums.sha256",
            "summary/recorder-health.json",
        }
        or APP_EVENT_MEMBER_RE.fullmatch(name) is not None
        or APP_MANIFEST_MEMBER_RE.fullmatch(name) is not None
        or DEVICE_EVENT_MEMBER_RE.fullmatch(name) is not None
        or DEVICE_HEALTH_MEMBER_RE.fullmatch(name) is not None
    )


def _require_nonnegative_integer(value: Any, path: str) -> int:
    if type(value) is not int or value < 0:
        _fail(f"{path} is invalid")
    return value


def _require_timestamp_or_none(value: Any, path: str) -> None:
    if value is None:
        return
    if not isinstance(value, str):
        _fail(f"{path} is invalid")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        _fail(f"{path} is invalid: {error}")
    if parsed.tzinfo is None:
        _fail(f"{path} is missing a timezone")


def _validate_json_sidecar(name: str, value: Any) -> None:
    if not isinstance(value, dict):
        _fail(f"{name} is not an object")
    if APP_MANIFEST_MEMBER_RE.fullmatch(name):
        if set(value) != APP_RECORDER_MANIFEST_KEYS:
            _fail(f"{name} shape is invalid")
        if type(value["schema"]) is not int or value["schema"] != SCHEMA:
            _fail(f"{name}.schema is invalid")
        if value["source"] != "ios":
            _fail(f"{name}.source is invalid")
        process_id = value["processId"]
        path_process_id = name.split("/", 2)[1]
        if not isinstance(process_id, str) or process_id != path_process_id:
            _fail(f"{name}.processId is invalid")
        _require_timestamp_or_none(value["createdAt"], f"{name}.createdAt")
        for key in (
            "chunkLimitBytes",
            "retentionBytes",
            "retentionCaptureCount",
            "retentionAgeDays",
            "droppedEventCount",
        ):
            _require_nonnegative_integer(value[key], f"{name}.{key}")
        if (
            value["chunkLimitBytes"] == 0
            or value["retentionBytes"] == 0
            or value["retentionCaptureCount"] == 0
            or value["retentionAgeDays"] == 0
        ):
            _fail(f"{name} retention bounds are invalid")
        return
    if name == "summary/recorder-health.json":
        if set(value) != RECORDER_HEALTH_KEYS:
            _fail(f"{name} shape is invalid")
        if type(value["schema"]) is not int or value["schema"] != SCHEMA:
            _fail(f"{name}.schema is invalid")
        if (
            not isinstance(value["processId"], str)
            or UUID_RE.fullmatch(value["processId"]) is None
        ):
            _fail(f"{name}.processId is invalid")
        for key in (
            "retainedBytes",
            "retainedChunkCount",
            "retainedCaptureCount",
            "droppedEventCount",
        ):
            _require_nonnegative_integer(value[key], f"{name}.{key}")
        for key in (
            "oldestWallTime",
            "newestWallTime",
            "detailedTraceExpiresAt",
        ):
            _require_timestamp_or_none(value[key], f"{name}.{key}")
        if value["lastError"] is not None and not isinstance(value["lastError"], str):
            _fail(f"{name}.lastError is invalid")
        if not isinstance(value["detailedTraceEnabled"], bool):
            _fail(f"{name}.detailedTraceEnabled is invalid")
        return
    if DEVICE_HEALTH_MEMBER_RE.fullmatch(name):
        if set(value) != DEVICE_RECORDER_HEALTH_KEYS:
            _fail(f"{name} shape is invalid")
        if type(value["schema"]) is not int or value["schema"] != SCHEMA:
            _fail(f"{name}.schema is invalid")
        if value["source"] != "firmware":
            _fail(f"{name}.source is invalid")
        boot_sequence = _require_nonnegative_integer(
            value["bootSequence"], f"{name}.bootSequence"
        )
        path_boot_sequence = int(name.split("/", 3)[2])
        if boot_sequence == 0 or boot_sequence != path_boot_sequence:
            _fail(f"{name}.bootSequence is invalid")
        active_chunk = _require_nonnegative_integer(
            value["activeChunk"], f"{name}.activeChunk"
        )
        if active_chunk == 0:
            _fail(f"{name}.activeChunk is invalid")
        stats = value["stats"]
        if not isinstance(stats, dict) or set(stats) != DEVICE_RECORDER_STATS_KEYS:
            _fail(f"{name}.stats shape is invalid")
        for key in DEVICE_RECORDER_STATS_KEYS:
            _require_nonnegative_integer(stats[key], f"{name}.stats.{key}")
        chunks = value["chunks"]
        if not isinstance(chunks, list) or len(chunks) > 256:
            _fail(f"{name}.chunks is invalid")
        seen_chunks: set[tuple[int, int]] = set()
        for index, chunk in enumerate(chunks):
            path = f"{name}.chunks[{index}]"
            if not isinstance(chunk, dict) or set(chunk) != DEVICE_RECORDER_CHUNK_KEYS:
                _fail(f"{path} shape is invalid")
            chunk_boot = _require_nonnegative_integer(
                chunk["bootSequence"], f"{path}.bootSequence"
            )
            chunk_number = _require_nonnegative_integer(
                chunk["chunk"], f"{path}.chunk"
            )
            chunk_bytes = _require_nonnegative_integer(
                chunk["bytes"], f"{path}.bytes"
            )
            digest = chunk["sha256"]
            if (
                chunk_boot == 0
                or chunk_boot > boot_sequence
                or chunk_number == 0
                or chunk_bytes == 0
                or chunk_bytes > 256 * 1024
                or not isinstance(digest, str)
                or re.fullmatch(r"[0-9a-f]{64}", digest) is None
                or (chunk_boot, chunk_number) in seen_chunks
            ):
                _fail(f"{path} is invalid")
            seen_chunks.add((chunk_boot, chunk_number))
        return
    _fail(f"unsupported JSON sidecar: {name}")


def _read_manifest(archive: zipfile.ZipFile) -> dict[str, Any]:
    try:
        manifest = json.loads(archive.read("manifest.json"))
    except (KeyError, json.JSONDecodeError, UnicodeDecodeError) as error:
        _fail(f"manifest.json is invalid: {error}")
    schema = manifest.get("schema") if isinstance(manifest, dict) else None
    if type(schema) is not int or schema != SCHEMA:
        _fail("manifest schema is unsupported")
    if set(manifest) != REQUIRED_MANIFEST_KEYS:
        missing = sorted(REQUIRED_MANIFEST_KEYS - set(manifest))
        unknown = sorted(set(manifest) - REQUIRED_MANIFEST_KEYS)
        _fail(f"manifest shape is invalid missing={missing} unknown={unknown}")
    for key in ("manifestSchema", "eventFormatSchema"):
        if type(manifest[key]) is not int or manifest[key] != SCHEMA:
            _fail(f"manifest {key} is unsupported")
    for key in (
        "clockAnchorCount",
        "uptimeEventCount",
        "truncatedTailStreamCount",
        "retainedBytes",
        "droppedEventCount",
        "deviceDroppedEventCount",
    ):
        if type(manifest[key]) is not int or manifest[key] < 0:
            _fail(f"manifest {key} is invalid")
    for key in ("exportedAt", "appProcessId", "captureId"):
        if not isinstance(manifest[key], str) or not manifest[key]:
            _fail(f"manifest {key} is invalid")
    if not UUID_RE.fullmatch(manifest["appProcessId"]):
        _fail("manifest appProcessId is invalid")
    if not UUID_RE.fullmatch(manifest["captureId"]):
        _fail("manifest captureId is invalid")
    for key in ("oldestWallTime", "newestWallTime"):
        if manifest[key] is not None and not isinstance(manifest[key], str):
            _fail(f"manifest {key} is invalid")
    build_identity = manifest["appBuildIdentity"]
    if (
        not isinstance(build_identity, dict)
        or set(build_identity) != {"version", "build"}
        or any(not isinstance(value, str) or not value for value in build_identity.values())
    ):
        _fail("manifest appBuildIdentity is invalid")
    for key in ("selectedCaptureRange", "firmwareBuildIdentities"):
        values = manifest[key]
        if (
            not isinstance(values, list)
            or len(values) != len(set(values))
            or any(not isinstance(value, str) or not value for value in values)
        ):
            _fail(f"manifest {key} is invalid")
    if any(not UUID_RE.fullmatch(value) for value in manifest["selectedCaptureRange"]):
        _fail("manifest selectedCaptureRange is invalid")
    if (
        manifest["checksumAlgorithm"] != "sha256"
        or manifest["checksumFile"] != "checksums.sha256"
        or manifest["archiveValidation"] != "stored_zip_crc32_and_entry_bytes"
        or manifest["privacy"]
        != "coordinates_addresses_credentials_health_values_and_raw_sensors_excluded"
    ):
        _fail("manifest validation contract is invalid")
    source_streams = manifest.get("sourceStreams")
    if (
        not isinstance(source_streams, list)
        or not source_streams
        or any(not isinstance(path, str) or not _safe_member(path) for path in source_streams)
        or len(source_streams) != len(set(source_streams))
    ):
        _fail("manifest sourceStreams is invalid")
    stream_metadata = manifest["streamMetadata"]
    if (
        not isinstance(stream_metadata, list)
        or len(stream_metadata) != len(source_streams)
        or any(not isinstance(item, dict) for item in stream_metadata)
    ):
        _fail("manifest streamMetadata is invalid")
    metadata_paths = [item.get("path") for item in stream_metadata]
    if (
        any(not isinstance(path, str) or not _safe_member(path) for path in metadata_paths)
        or len(metadata_paths) != len(set(metadata_paths))
        or set(metadata_paths) != set(source_streams)
    ):
        _fail("manifest streamMetadata paths are invalid")
    for item in stream_metadata:
        if set(item) != STREAM_METADATA_KEYS:
            _fail("manifest streamMetadata shape is invalid")
        if item["source"] not in {"ios", "firmware"}:
            _fail("manifest streamMetadata source is invalid")
        if type(item["bytes"]) is not int or item["bytes"] < 0:
            _fail("manifest streamMetadata bytes is invalid")
        if (
            not isinstance(item["sha256"], str)
            or re.fullmatch(r"[0-9a-f]{64}", item["sha256"]) is None
        ):
            _fail("manifest streamMetadata sha256 is invalid")
        if (
            not isinstance(item["captureIds"], list)
            or item["captureIds"] != sorted(set(item["captureIds"]))
            or any(
                not isinstance(value, str) or not UUID_RE.fullmatch(value)
                for value in item["captureIds"]
            )
        ):
            _fail("manifest streamMetadata captureIds is invalid")
        for key in ("firstSequence", "lastSequence"):
            if item[key] is not None and (
                type(item[key]) is not int or item[key] < 0
            ):
                _fail(f"manifest streamMetadata {key} is invalid")
        if not isinstance(item["truncatedTail"], bool):
            _fail("manifest streamMetadata truncatedTail is invalid")
        if not isinstance(item["clockAnchors"], list):
            _fail("manifest streamMetadata clockAnchors is invalid")
    _check_privacy(manifest, path="manifest")
    return manifest


def validate_bundle(bundle: Path) -> tuple[dict[str, Any], tuple[StreamResult, ...]]:
    if not bundle.is_file():
        _fail(f"bundle does not exist: {bundle}")
    if bundle.stat().st_size > MAX_BUNDLE_BYTES:
        _fail("bundle exceeds size limit")
    streams: list[StreamResult] = []
    payloads: dict[str, bytes] = {}
    digests: dict[str, str] = {}
    json_members: dict[str, Any] = {}
    with zipfile.ZipFile(bundle) as archive:
        members = archive.infolist()
        if len(members) > 1024:
            _fail("bundle has too many entries")
        names = [member.filename for member in members]
        if len(names) != len(set(names)):
            _fail("bundle has duplicate entries")
        total_entry_bytes = 0
        for member in members:
            if not _safe_member(member.filename):
                _fail(f"unsafe bundle path: {member.filename}")
            if not _supported_bundle_member(member.filename):
                _fail(f"unsupported bundle member: {member.filename}")
            if member.file_size > MAX_ENTRY_BYTES:
                _fail(f"bundle entry exceeds size limit: {member.filename}")
            total_entry_bytes += member.file_size
            if total_entry_bytes > MAX_BUNDLE_BYTES:
                _fail("bundle entries exceed size limit")
            if member.file_size and (
                member.compress_size == 0
                or member.file_size > member.compress_size * MAX_COMPRESSION_RATIO
            ):
                _fail(f"bundle entry has unsafe compression ratio: {member.filename}")
        manifest = _read_manifest(archive)
        try:
            checksums = archive.read("checksums.sha256").decode("utf-8")
        except (KeyError, UnicodeDecodeError) as error:
            _fail(f"checksums.sha256 is invalid: {error}")
        checksum_names: set[str] = set()
        for line in checksums.splitlines():
            parts = line.split("  ", 1)
            if len(parts) != 2:
                _fail("invalid checksum line")
            digest, member_name = parts
            if not re.fullmatch(r"[0-9a-fA-F]{64}", digest) or not _safe_member(member_name):
                _fail("invalid checksum entry")
            if member_name in checksum_names or member_name == "checksums.sha256":
                _fail(f"duplicate checksum entry: {member_name}")
            checksum_names.add(member_name)
            try:
                payload = archive.read(member_name)
            except KeyError:
                _fail(f"checksum references missing member: {member_name}")
            if hashlib.sha256(payload).hexdigest() != digest.lower():
                _fail(f"checksum mismatch: {member_name}")
            payloads[member_name] = payload
            digests[member_name] = digest.lower()
            if member_name.endswith(".jsonl"):
                expected_source = (
                    "firmware" if member_name.startswith("device/") else
                    "ios" if member_name.startswith("app/") else None
                )
                streams.append(validate_jsonl(payload, member_name, expected_source))
            elif member_name.endswith(".json"):
                try:
                    json_member = json.loads(payload)
                except (json.JSONDecodeError, UnicodeDecodeError) as error:
                    _fail(f"{member_name} is invalid JSON: {error}")
                _check_privacy(json_member, path=member_name)
                if member_name != "manifest.json":
                    _validate_json_sidecar(member_name, json_member)
                json_members[member_name] = json_member
        expected_checksum_names = {
            member.filename for member in members if member.filename != "checksums.sha256"
        }
        if checksum_names != expected_checksum_names:
            missing = sorted(expected_checksum_names - checksum_names)
            extra = sorted(checksum_names - expected_checksum_names)
            _fail(f"checksum coverage mismatch missing={missing} extra={extra}")
        source_streams = manifest["sourceStreams"]
        actual_streams = [stream.path for stream in streams]
        if not actual_streams:
            _fail("bundle contains no diagnostic evidence streams")
        if set(source_streams) != set(actual_streams):
            missing = sorted(set(actual_streams) - set(source_streams))
            extra = sorted(set(source_streams) - set(actual_streams))
            _fail(f"manifest stream coverage mismatch missing={missing} extra={extra}")
    _validate_stream_boundaries(streams)
    _validate_manifest_inventory(
        manifest, streams, payloads, digests, json_members
    )
    return manifest, tuple(streams)


def _validate_manifest_inventory(
    manifest: dict[str, Any],
    streams: list[StreamResult],
    payloads: dict[str, bytes],
    digests: dict[str, str],
    json_members: dict[str, Any],
) -> None:
    ordered_streams = sorted(streams, key=lambda stream: stream.path)
    if manifest["sourceStreams"] != [stream.path for stream in ordered_streams]:
        _fail("manifest sourceStreams order is not canonical")
    metadata_by_path = {
        item["path"]: item for item in manifest["streamMetadata"]
    }
    if [item["path"] for item in manifest["streamMetadata"]] != manifest[
        "sourceStreams"
    ]:
        _fail("manifest streamMetadata order is not canonical")

    all_capture_ids: set[str] = set()
    firmware_build_identities: set[str] = set()
    clock_anchor_count = 0
    uptime_event_count = 0
    truncated_tail_count = 0
    for stream in ordered_streams:
        metadata = metadata_by_path[stream.path]
        captures = sorted({
            event["captureId"]
            for event in stream.events
            if isinstance(event.get("captureId"), str)
        })
        all_capture_ids.update(captures)
        anchors: list[dict[str, Any]] = []
        for event in stream.events:
            if "uptimeMs" in event:
                uptime_event_count += 1
            fields = event.get("fields", {})
            if event.get("event") == "clock_anchor":
                clock_anchor_count += 1
                anchor: dict[str, Any] = {}
                for key in ("wallTime", "uptimeMs"):
                    if key in event:
                        anchor[key] = event[key]
                for key in ("bootSequence", "firmwareFingerprint"):
                    if key in fields:
                        anchor[key] = fields[key]
                anchors.append(anchor)
            if (
                event.get("source") == "firmware"
                and isinstance(fields.get("firmwareTarget"), str)
                and isinstance(fields.get("firmwareFingerprint"), str)
            ):
                firmware_build_identities.add(
                    f"{fields['firmwareTarget']}|"
                    f"{fields.get('firmwareBuild', 'unknown')}|"
                    f"{fields['firmwareFingerprint']}"
                )
        expected = {
            "path": stream.path,
            "source": stream.events[0]["source"],
            "bytes": len(payloads[stream.path]),
            "sha256": digests[stream.path],
            "captureIds": captures,
            "firstSequence": stream.events[0]["sequence"],
            "lastSequence": stream.events[-1]["sequence"],
            "truncatedTail": stream.truncated_tail,
            "clockAnchors": anchors,
        }
        if metadata != expected:
            _fail(f"manifest streamMetadata mismatch: {stream.path}")
        if stream.truncated_tail:
            truncated_tail_count += 1

    if manifest["selectedCaptureRange"] != sorted(all_capture_ids):
        _fail("manifest selectedCaptureRange mismatch")
    if manifest["firmwareBuildIdentities"] != sorted(
        firmware_build_identities
    ):
        _fail("manifest firmwareBuildIdentities mismatch")
    for key, expected in (
        ("clockAnchorCount", clock_anchor_count),
        ("uptimeEventCount", uptime_event_count),
        ("truncatedTailStreamCount", truncated_tail_count),
    ):
        if manifest[key] != expected:
            _fail(f"manifest {key} mismatch")

    summary_path = "summary/recorder-health.json"
    summary = json_members.get(summary_path)
    if not isinstance(summary, dict):
        _fail(f"missing required sidecar: {summary_path}")
    if summary["processId"] != manifest["appProcessId"]:
        _fail("summary recorder-health processId does not match manifest")
    for key in (
        "retainedBytes",
        "droppedEventCount",
        "oldestWallTime",
        "newestWallTime",
    ):
        if summary[key] != manifest[key]:
            _fail(f"summary recorder-health {key} mismatch")

    app_manifest_path = (
        f"app/{manifest['appProcessId']}/manifest.json"
    )
    app_manifest = json_members.get(app_manifest_path)
    if not isinstance(app_manifest, dict):
        _fail(f"missing current app recorder manifest: {app_manifest_path}")
    if app_manifest["processId"] != manifest["appProcessId"]:
        _fail("current app recorder manifest processId does not match manifest")
    if app_manifest["droppedEventCount"] != manifest["droppedEventCount"]:
        _fail("current app recorder manifest droppedEventCount mismatch")

    current_app_streams = [
        stream for stream in ordered_streams
        if stream.path.startswith(f"app/{manifest['appProcessId']}/")
    ]
    for stream in current_app_streams:
        for index, event in enumerate(stream.events, 1):
            if event.get("processId") != manifest["appProcessId"]:
                _fail(
                    f"{stream.path}:{index} processId does not match "
                    "manifest appProcessId"
                )

    device_dropped = 0
    for path, value in json_members.items():
        if not path.startswith("device/") or not isinstance(value, dict):
            continue
        stats = value.get("stats")
        dropped = stats.get("dropped") if isinstance(stats, dict) else None
        if type(dropped) is int and dropped >= 0:
            device_dropped += dropped
    if manifest["deviceDroppedEventCount"] != device_dropped:
        _fail("manifest deviceDroppedEventCount mismatch")


def _validate_stream_boundaries(streams: list[StreamResult]) -> None:
    groups: dict[str, list[StreamResult]] = {}
    for stream in streams:
        if not stream.events:
            continue
        parent = str(PurePosixPath(stream.path).parent)
        groups.setdefault(parent, []).append(stream)
    chunk_pattern = re.compile(r"events-(\d+)")
    for parent, members in groups.items():
        members.sort(
            key=lambda stream: (
                int(match.group(1))
                if (match := chunk_pattern.search(PurePosixPath(stream.path).name))
                else 2**63 - 1,
                stream.path,
            )
        )
        previous: int | None = None
        previous_stream: StreamResult | None = None
        firmware_identity: tuple[int, str] | None = None
        seen_chunks: set[int] = set()
        for stream in members:
            if previous_stream is not None and previous_stream.truncated_tail:
                _fail(
                    f"{previous_stream.path} has a truncated tail before "
                    f"a later chunk in {parent}"
                )
            match = chunk_pattern.search(PurePosixPath(stream.path).name)
            if match:
                chunk = int(match.group(1))
                if chunk in seen_chunks:
                    _fail(f"{stream.path} duplicates chunk {chunk} in {parent}")
                seen_chunks.add(chunk)
            if stream.firmware_identity is not None:
                if (
                    firmware_identity is not None
                    and stream.firmware_identity != firmware_identity
                ):
                    _fail(f"{stream.path} changes firmware identity in {parent}")
                firmware_identity = stream.firmware_identity
            first = int(stream.events[0]["sequence"])
            if previous is not None and first <= previous:
                _fail(
                    f"{stream.path} sequence overlaps the previous chunk in {parent}"
                )
            if previous is not None and first > previous + 1:
                stream.dropped_sequences += first - previous - 1
            previous = int(stream.events[-1]["sequence"])
            previous_stream = stream


def _correlate_events(
    evidence: list[dict[str, Any]] | tuple[StreamResult, ...] | list[StreamResult],
) -> list[dict[str, Any]]:
    def wrapped_uptime_delta(value: int, reference: int) -> int:
        delta = (value - reference) & 0xFFFF_FFFF
        return delta - 0x1_0000_0000 if delta >= 0x8000_0000 else delta

    scoped_events: list[tuple[str, dict[str, Any]]] = []
    for item in evidence:
        if isinstance(item, StreamResult):
            stream_scope = str(PurePosixPath(item.path).parent)
            scoped_events.extend((stream_scope, event) for event in item.events)
        else:
            scoped_events.append(("", item))

    def firmware_scope(scope: str, event: dict[str, Any]) -> tuple[str, str, str]:
        fields = event.get("fields", {})
        return (
            scope,
            str(fields.get("bootSequence", "")),
            str(fields.get("firmwareFingerprint", "")),
        )

    anchors: dict[tuple[str, str, str], list[tuple[int, datetime]]] = {}
    for scope, event in scoped_events:
        if event.get("source") != "firmware" or event.get("event") != "clock_anchor":
            continue
        timestamp = _event_timestamp(event)
        uptime = event.get("uptimeMs")
        identity = firmware_scope(scope, event)
        if timestamp is not None and isinstance(uptime, int) and all(identity[1:]):
            anchors.setdefault(identity, []).append((uptime, timestamp))
    for values in anchors.values():
        values.sort()

    correlated: list[dict[str, Any]] = []
    for scope, raw in scoped_events:
        event = dict(raw)
        timestamp = _event_timestamp(raw)
        uncertainty_ms = 0
        if raw.get("source") == "firmware":
            uptime = raw.get("uptimeMs")
            candidates = anchors.get(firmware_scope(scope, raw), [])
            if isinstance(uptime, int) and candidates:
                anchor_uptime, anchor_time = min(
                    candidates,
                    key=lambda item: abs(
                        wrapped_uptime_delta(uptime, item[0])
                    ),
                )
                timestamp = anchor_time + timedelta(
                    milliseconds=wrapped_uptime_delta(uptime, anchor_uptime)
                )
                # Always correlate firmware against its nearest same-device
                # anchor. Raw wallTime remains untouched evidence, while this
                # derived value reflects later RTC corrections and uptime wrap.
                uncertainty_ms = 0 if raw.get("event") == "clock_anchor" else 1_000
        if timestamp is not None:
            event["correlatedWallTime"] = (
                timestamp.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
            )
            event["clockUncertaintyMs"] = uncertainty_ms
        correlated.append(event)
    return correlated


def _event_key(event: dict[str, Any]) -> tuple[int, str, int]:
    wall = event.get("correlatedWallTime") or event.get("wallTime")
    if wall:
        try:
            timestamp = int(datetime.fromisoformat(str(wall).replace("Z", "+00:00")).timestamp() * 1000)
        except ValueError:
            timestamp = 2**63 - 1
    else:
        timestamp = 2**63 - 1
    return timestamp, str(event.get("source", "")), int(event["sequence"])


def _event_timestamp(event: dict[str, Any]) -> datetime | None:
    wall = event.get("correlatedWallTime") or event.get("wallTime")
    if not wall:
        return None
    try:
        timestamp = datetime.fromisoformat(str(wall).replace("Z", "+00:00"))
        return timestamp if timestamp.tzinfo else timestamp.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _parse_timestamp(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        timestamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return timestamp if timestamp.tzinfo else timestamp.replace(tzinfo=timezone.utc)
    except ValueError as error:
        _fail(f"invalid timestamp filter {value!r}: {error}")


def summarize(
    bundle: Path,
    output: Path,
    category: str | None = None,
    level: str | None = None,
    capture_id: str | None = None,
    boot_sequence: int | None = None,
    since: str | None = None,
    until: str | None = None,
    around_issue_seconds: int | None = None,
) -> None:
    manifest, streams = validate_bundle(bundle)
    if output.exists():
        if not output.is_dir() or any(output.iterdir()):
            _fail("output directory must be empty")
    output.mkdir(parents=True, exist_ok=True)
    _extract_raw_entries(bundle, output / "raw")
    events = _correlate_events(streams)
    if capture_id:
        events = [event for event in events if event.get("captureId") == capture_id]
    if boot_sequence is not None:
        events = [
            event
            for event in events
            if event.get("fields", {}).get("bootSequence") == boot_sequence
            or str(event.get("fields", {}).get("bootSequence")) == str(boot_sequence)
        ]
    since_timestamp = _parse_timestamp(since)
    until_timestamp = _parse_timestamp(until)
    if since_timestamp or until_timestamp:
        events = [
            event for event in events
            if (
                (timestamp := _event_timestamp(event)) is not None and
                (since_timestamp is None or timestamp >= since_timestamp) and
                (until_timestamp is None or timestamp <= until_timestamp)
            )
        ]
    # Issue-window selection uses the correlated, identity/time-filtered event
    # set before category/level filters remove the marker itself.
    issue_markers = [
        _event_timestamp(event) for event in events
        if event.get("category") == "user" and event.get("event") == "issue_marker"
    ]
    issue_markers = [timestamp for timestamp in issue_markers if timestamp is not None]
    if category:
        events = [event for event in events if event["category"] == category]
    if level:
        events = [event for event in events if event["level"] == level]
    if around_issue_seconds is not None:
        if around_issue_seconds < 0 or around_issue_seconds > 24 * 60 * 60:
            _fail("around-issue-seconds must be between 0 and 86400")
        if not issue_markers:
            _fail("around-issue-seconds requires a timestamped issue marker")
        window = max(issue_markers, key=lambda timestamp: timestamp)
        delta = around_issue_seconds
        events = [
            event for event in events
            if (timestamp := _event_timestamp(event)) is not None and
            abs((timestamp - window).total_seconds()) <= delta
        ]
    events.sort(key=_event_key)
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    (output / "timeline.jsonl").write_text("".join(json.dumps(event, sort_keys=True) + "\n" for event in events))
    summary = {
        "eventCount": len(events),
        "correlatedEventCount": sum(
            1 for event in events if event.get("correlatedWallTime")
        ),
        "inferredClockEventCount": sum(
            1 for event in events if event.get("clockUncertaintyMs", 0) > 0
        ),
        "streams": [
            {
                "path": stream.path,
                "eventCount": len(stream.events),
                "truncatedTail": stream.truncated_tail,
                "droppedSequences": stream.dropped_sequences,
            }
            for stream in streams
        ],
    }
    (output / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    report_lines = [
        "# Bicino ride diagnostics",
        "",
        f"Events: {len(events)}",
        f"Streams: {len(streams)}",
        "",
        "Immutable raw archive entries are preserved under `raw/`. Sequence gaps and recoverable tails are reported in `summary.json`.",
        "",
    ]
    (output / "report.md").write_text("\n".join(report_lines))


def _extract_raw_entries(bundle: Path, raw_output: Path) -> None:
    """Extract validated archive members without changing their bytes."""
    with zipfile.ZipFile(bundle) as archive:
        for member in archive.infolist():
            if member.is_dir():
                continue
            payload = archive.read(member.filename)
            destination = raw_output / member.filename
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                if not destination.is_file() or destination.read_bytes() != payload:
                    _fail(f"raw extraction would overwrite different data: {member.filename}")
                continue
            destination.write_bytes(payload)


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("bundle", type=Path)
    summarize_parser = subparsers.add_parser("summarize")
    summarize_parser.add_argument("bundle", type=Path)
    summarize_parser.add_argument("--output", type=Path, required=True)
    timeline_parser = subparsers.add_parser("timeline")
    timeline_parser.add_argument("bundle", type=Path)
    timeline_parser.add_argument("--output", type=Path, required=True)
    timeline_parser.add_argument("--category")
    timeline_parser.add_argument("--level")
    timeline_parser.add_argument("--capture-id")
    timeline_parser.add_argument("--boot-sequence", type=int)
    timeline_parser.add_argument("--since")
    timeline_parser.add_argument("--until")
    timeline_parser.add_argument("--around-issue-seconds", type=int)
    args = parser.parse_args(list(argv) if argv is not None else None)
    try:
        if args.command == "validate":
            manifest, streams = validate_bundle(args.bundle)
            print(json.dumps({"ok": True, "manifest": manifest, "streams": len(streams)}, sort_keys=True))
        elif args.command == "summarize":
            summarize(args.bundle, args.output)
            print(json.dumps({"ok": True, "output": str(args.output)}, sort_keys=True))
        else:
            summarize(
                args.bundle,
                args.output,
                category=args.category,
                level=args.level,
                capture_id=args.capture_id,
                boot_sequence=args.boot_sequence,
                since=args.since,
                until=args.until,
                around_issue_seconds=args.around_issue_seconds,
            )
            print(json.dumps({"ok": True, "output": str(args.output)}, sort_keys=True))
        return 0
    except (DiagnosticError, OSError, zipfile.BadZipFile) as error:
        print(f"ride diagnostics validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
