#!/usr/bin/env python3
"""Validate and summarize Bicino ride-diagnostics bundles."""

from __future__ import annotations

import argparse
import hashlib
import json
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
    "autoPauseEnabled",
    "authorization",
    "authorized",
    "available",
    "background",
    "bootSequence",
    "bytes",
    "chunk",
    "clockSynchronized",
    "code",
    "connectionState",
    "completedStage",
    "consecutiveEarlyFailures",
    "diagnosticHold",
    "domain",
    "droppedCount",
    "durationLimit",
    "eventCount",
    "firstMissingUptimeMs",
    "firmwareBuild",
    "firmwareFingerprint",
    "firmwareTarget",
    "fixValid",
    "importedCount",
    "lastCriticalCategory",
    "lastCriticalEvent",
    "lastGapMs",
    "lastMissingUptimeMs",
    "maximumGapMs",
    "messageBytes",
    "messageDigest",
    "kind",
    "mode",
    "networkTransport",
    "navigating",
    "profileVersion",
    "pendingControl",
    "reason",
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
    "transition",
    "result",
    "origin",
    "expectedState",
    "decisionSequence",
    "viewingMap",
    "workoutActive",
}
FIRMWARE_NUMBER_FIELD_KEYS = {
    "accuracy", "activeStage", "ageMs", "alertMode", "bootSequence",
    "bytes", "chunk", "completedStage", "consecutiveEarlyFailures",
    "decisionSequence", "droppedCount", "eventCount", "firmwareBuild",
    "firstMissingUptimeMs", "importedCount", "lastGapMs",
    "lastMissingUptimeMs", "maximumGapMs", "messageBytes",
    "profileVersion", "resetReason", "rideGeneration",
    "runtimeBootSequence", "sampleCount", "sequence", "sourceHealthMask",
    "storageErrorCount",
}
FIRMWARE_BOOLEAN_FIELD_KEYS = {
    "accuracyAvailable", "active", "autoPauseEnabled", "authorized",
    "available", "background", "clockSynchronized", "diagnosticHold",
    "fallback", "fixValid", "navigating", "pendingControl", "ready",
    "rideDetectionArmed", "routeLoaded", "safeMode", "sessionPresent",
    "simulation", "speedAvailable", "viewingMap", "workoutActive",
}
UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
FORBIDDEN_KEY_PARTS = (
    "latitude",
    "longitude",
    "coordinate",
    "address",
    "instruction",
    "destination",
    "password",
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
        limit = 1024 if path == "manifest.sourceStreams" else 32
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
    return record


@dataclass
class StreamResult:
    path: str
    events: tuple[dict[str, Any], ...]
    truncated_tail: bool = False
    dropped_sequences: int = 0


def validate_jsonl(data: bytes, source_path: str, expected_source: str | None = None) -> StreamResult:
    if len(data) > MAX_ENTRY_BYTES:
        _fail(f"{source_path} exceeds entry size limit")
    events: list[dict[str, Any]] = []
    previous_sequence: int | None = None
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
        if len(raw) > MAX_LINE_BYTES:
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
        events.append(event)
    return StreamResult(source_path, tuple(events), truncated_tail, dropped)


def _safe_member(name: str) -> bool:
    path = PurePosixPath(name)
    components = name.split("/")
    return (
        bool(name)
        and not path.is_absolute()
        and "\\" not in name
        and all(component not in {"", ".", ".."} for component in components)
    )


def _read_manifest(archive: zipfile.ZipFile) -> dict[str, Any]:
    try:
        manifest = json.loads(archive.read("manifest.json"))
    except (KeyError, json.JSONDecodeError, UnicodeDecodeError) as error:
        _fail(f"manifest.json is invalid: {error}")
    if not isinstance(manifest, dict) or manifest.get("schema") != SCHEMA:
        _fail("manifest schema is unsupported")
    source_streams = manifest.get("sourceStreams")
    if (
        not isinstance(source_streams, list)
        or any(not isinstance(path, str) or not _safe_member(path) for path in source_streams)
        or len(source_streams) != len(set(source_streams))
    ):
        _fail("manifest sourceStreams is invalid")
    _check_privacy(manifest, path="manifest")
    return manifest


def validate_bundle(bundle: Path) -> tuple[dict[str, Any], tuple[StreamResult, ...]]:
    if not bundle.is_file():
        _fail(f"bundle does not exist: {bundle}")
    if bundle.stat().st_size > MAX_BUNDLE_BYTES:
        _fail("bundle exceeds size limit")
    streams: list[StreamResult] = []
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
            if member_name.endswith(".jsonl"):
                expected_source = (
                    "firmware" if member_name.startswith("device/") else
                    "ios" if member_name.startswith("app/") else None
                )
                streams.append(validate_jsonl(payload, member_name, expected_source))
        expected_checksum_names = {
            member.filename for member in members if member.filename != "checksums.sha256"
        }
        if checksum_names != expected_checksum_names:
            missing = sorted(expected_checksum_names - checksum_names)
            extra = sorted(checksum_names - expected_checksum_names)
            _fail(f"checksum coverage mismatch missing={missing} extra={extra}")
        source_streams = manifest["sourceStreams"]
        actual_streams = [stream.path for stream in streams]
        if set(source_streams) != set(actual_streams):
            missing = sorted(set(actual_streams) - set(source_streams))
            extra = sorted(set(source_streams) - set(actual_streams))
            _fail(f"manifest stream coverage mismatch missing={missing} extra={extra}")
    _validate_stream_boundaries(streams)
    return manifest, tuple(streams)


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
        seen_chunks: set[int] = set()
        for stream in members:
            match = chunk_pattern.search(PurePosixPath(stream.path).name)
            if match:
                chunk = int(match.group(1))
                if chunk in seen_chunks:
                    _fail(f"{stream.path} duplicates chunk {chunk} in {parent}")
                seen_chunks.add(chunk)
            first = int(stream.events[0]["sequence"])
            if previous is not None and first <= previous:
                _fail(
                    f"{stream.path} sequence overlaps the previous chunk in {parent}"
                )
            if previous is not None and first > previous + 1:
                stream.dropped_sequences += first - previous - 1
            previous = int(stream.events[-1]["sequence"])


def _correlate_events(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    anchors: dict[str, list[tuple[int, datetime]]] = {}
    for event in events:
        if event.get("source") != "firmware" or event.get("event") != "clock_anchor":
            continue
        timestamp = _event_timestamp(event)
        uptime = event.get("uptimeMs")
        boot = str(event.get("fields", {}).get("bootSequence", ""))
        if timestamp is not None and isinstance(uptime, int) and boot:
            anchors.setdefault(boot, []).append((uptime, timestamp))
    for values in anchors.values():
        values.sort()

    correlated: list[dict[str, Any]] = []
    for raw in events:
        event = dict(raw)
        timestamp = _event_timestamp(raw)
        uncertainty_ms = 0
        if timestamp is None and raw.get("source") == "firmware":
            boot = str(raw.get("fields", {}).get("bootSequence", ""))
            uptime = raw.get("uptimeMs")
            candidates = anchors.get(boot, [])
            if isinstance(uptime, int) and candidates:
                anchor_uptime, anchor_time = min(
                    candidates, key=lambda item: abs(item[0] - uptime)
                )
                timestamp = anchor_time + timedelta(milliseconds=uptime - anchor_uptime)
                # RTC synchronization and one-second capture cadence bound the
                # inferred pre-anchor placement; raw evidence remains unchanged.
                uncertainty_ms = 1_000
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
    output.mkdir(parents=True, exist_ok=True)
    _extract_raw_entries(bundle, output / "raw")
    events = _correlate_events(
        [event for stream in streams for event in stream.events]
    )
    if category:
        events = [event for event in events if event["category"] == category]
    if level:
        events = [event for event in events if event["level"] == level]
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
    if around_issue_seconds is not None:
        if around_issue_seconds < 0 or around_issue_seconds > 24 * 60 * 60:
            _fail("around-issue-seconds must be between 0 and 86400")
        markers = [
            _event_timestamp(event) for event in events
            if event.get("category") == "user" and event.get("event") == "issue_marker"
        ]
        markers = [timestamp for timestamp in markers if timestamp is not None]
        if markers:
            window = max(markers, key=lambda timestamp: timestamp)
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
