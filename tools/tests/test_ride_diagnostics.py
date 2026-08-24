import hashlib
import json
import re
import sys
import unittest
import zipfile
from pathlib import Path
from tempfile import TemporaryDirectory


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools"))
import ride_diagnostics  # noqa: E402


APP_PROCESS_ID = "123e4567-e89b-12d3-a456-426614174000"
APP_CAPTURE_ID = "123e4567-e89b-12d3-a456-426614174001"
APP_STREAM_PATH = f"app/{APP_PROCESS_ID}/events-000001.jsonl"
DEVICE_DIGEST = "0123456789abcdef"


def device_stream_path(boot, chunk, digest_prefix="a"):
    return (
        f"device/{DEVICE_DIGEST}/{boot}/events-{chunk:06d}-"
        f"{digest_prefix * 16}.jsonl"
    )


def event(sequence=0, source="ios", fields=None):
    return {
        "schema": 1,
        "source": source,
        "sequence": sequence,
        "level": "info",
        "category": "ble",
        "event": "connected",
        "wallTime": "2026-08-19T08:20:31.412Z",
        "uptimeMs": 42,
        "processId": "123e4567-e89b-12d3-a456-426614174000",
        "captureId": "123e4567-e89b-12d3-a456-426614174001",
        "fields": fields or {"rssiBucket": "good"},
    }


def firmware_event(sequence=0, fields=None):
    return event(
        sequence=sequence,
        source="firmware",
        fields=fields
        or {
            "bootSequence": 7,
            "firmwareFingerprint": "A1B2C3D4",
            "ready": True,
            "safeMode": False,
            "storageErrorCount": 2,
        },
    )


def bundle_manifest(source_payloads):
    source_streams = sorted(source_payloads)
    metadata = []
    capture_ids = set()
    firmware_build_identities = set()
    clock_anchor_count = 0
    uptime_event_count = 0
    truncated_tail_count = 0
    for path in source_streams:
        payload = source_payloads[path]
        try:
            result = ride_diagnostics.validate_jsonl(
                payload,
                path,
                "firmware" if path.startswith("device/") else "ios",
            )
        except ride_diagnostics.DiagnosticError:
            result = None
        events = result.events if result is not None else ()
        stream_captures = sorted({
            item["captureId"]
            for item in events
            if isinstance(item.get("captureId"), str)
        })
        capture_ids.update(stream_captures)
        anchors = []
        for item in events:
            if "uptimeMs" in item:
                uptime_event_count += 1
            fields = item.get("fields", {})
            if item.get("event") == "clock_anchor":
                clock_anchor_count += 1
                anchor = {
                    key: item[key]
                    for key in ("wallTime", "uptimeMs")
                    if key in item
                }
                anchor.update({
                    key: fields[key]
                    for key in ("bootSequence", "firmwareFingerprint")
                    if key in fields
                })
                anchors.append(anchor)
            if (
                item.get("source") == "firmware"
                and isinstance(fields.get("firmwareTarget"), str)
                and isinstance(fields.get("firmwareFingerprint"), str)
            ):
                firmware_build_identities.add(
                    f"{fields['firmwareTarget']}|"
                    f"{fields.get('firmwareBuild', 'unknown')}|"
                    f"{fields['firmwareFingerprint']}"
                )
        truncated = result.truncated_tail if result is not None else False
        truncated_tail_count += int(truncated)
        metadata.append({
            "path": path,
            "source": "firmware" if path.startswith("device/") else "ios",
            "bytes": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
            "captureIds": stream_captures,
            "firstSequence": events[0]["sequence"] if events else None,
            "lastSequence": events[-1]["sequence"] if events else None,
            "truncatedTail": truncated,
            "clockAnchors": anchors,
        })
    return {
        "schema": 1,
        "manifestSchema": 1,
        "eventFormatSchema": 1,
        "exportedAt": "2026-08-19T08:20:31.412Z",
        "appProcessId": APP_PROCESS_ID,
        "sourceStreams": source_streams,
        "streamMetadata": metadata,
        "captureId": APP_CAPTURE_ID,
        "selectedCaptureRange": sorted(capture_ids),
        "appBuildIdentity": {"version": "1.4", "build": "14"},
        "firmwareBuildIdentities": sorted(firmware_build_identities),
        "oldestWallTime": "2026-08-19T08:20:31.412Z",
        "newestWallTime": "2026-08-19T08:20:31.412Z",
        "clockAnchorCount": clock_anchor_count,
        "uptimeEventCount": uptime_event_count,
        "truncatedTailStreamCount": truncated_tail_count,
        "retainedBytes": 1,
        "droppedEventCount": 0,
        "deviceDroppedEventCount": 0,
        "checksumAlgorithm": "sha256",
        "checksumFile": "checksums.sha256",
        "archiveValidation": "stored_zip_crc32_and_entry_bytes",
        "privacy": (
            "coordinates_addresses_credentials_health_values_"
            "and_raw_sensors_excluded"
        ),
    }


def required_sidecars(manifest):
    process_id = manifest["appProcessId"]
    sidecars = {
        f"app/{process_id}/manifest.json": {
            "schema": 1,
            "source": "ios",
            "processId": process_id,
            "createdAt": manifest["exportedAt"],
            "chunkLimitBytes": 8192,
            "retentionBytes": 50 * 1024 * 1024,
            "retentionCaptureCount": 64,
            "retentionAgeDays": 14,
            "droppedEventCount": manifest["droppedEventCount"],
        },
        "summary/recorder-health.json": {
            "schema": 1,
            "processId": process_id,
            "retainedBytes": manifest["retainedBytes"],
            "retainedChunkCount": len(manifest["sourceStreams"]),
            "retainedCaptureCount": len(manifest["selectedCaptureRange"]) or 1,
            "oldestWallTime": manifest["oldestWallTime"],
            "newestWallTime": manifest["newestWallTime"],
            "droppedEventCount": manifest["droppedEventCount"],
            "lastError": None,
            "detailedTraceEnabled": False,
            "detailedTraceExpiresAt": None,
        },
    }
    return {
        path: json.dumps(value).encode()
        for path, value in sidecars.items()
    }


class RideDiagnosticsTests(unittest.TestCase):
    def test_remote_debug_partition_preserves_fallback_offset(self):
        def rows(name):
            parsed = []
            for raw in (REPO_ROOT / "esp32" / name).read_text().splitlines():
                if not raw.strip() or raw.lstrip().startswith("#"):
                    continue
                fields = [field.strip() for field in raw.split(",")]
                parsed.append(fields)
            return parsed

        ordinary = rows("partitions.csv")
        remote = rows("partitions_remote_debug.csv")
        self.assertEqual(
            [(row[0], row[1]) for row in ordinary[:2]],
            [(row[0], row[1]) for row in remote[:2]],
        )
        ordinary_app_bytes = sum(
            int(row[4], 0) for row in ordinary if row[1] == "app"
        )
        remote_app_bytes = sum(
            int(row[4], 0) for row in remote if row[1] == "app"
        )
        self.assertEqual(remote_app_bytes, ordinary_app_bytes)
        self.assertEqual(
            next(row[4] for row in remote if row[0] == "ffat"),
            next(row[4] for row in ordinary if row[0] == "ffat"),
        )

    def test_swift_and_python_field_allowlists_stay_in_sync(self):
        swift_source = (
            REPO_ROOT
            / "ios-app/BikeComputer/BikeComputer/Utilities/RideDiagnostics.swift"
        ).read_text()
        match = re.search(
            r"allowedKeys: Set<String> = \[(.*?)\n\s*\]",
            swift_source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match)
        swift_keys = set(re.findall(r'"([A-Za-z][A-Za-z0-9]*)"', match.group(1)))
        self.assertEqual(swift_keys, ride_diagnostics.ALLOWED_FIELD_KEYS)
        cpp_source = (
            REPO_ROOT
            / "esp32/lib/ride_diagnostics/ride_diagnostics_format.hpp"
        ).read_text()
        cpp_match = re.search(
            r"kAllowedFieldKeys\[\] = \{(.*?)\n\};",
            cpp_source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(cpp_match)
        cpp_keys = set(re.findall(r'"([A-Za-z][A-Za-z0-9]*)"', cpp_match.group(1)))
        self.assertEqual(cpp_keys, ride_diagnostics.ALLOWED_FIELD_KEYS)

        for cpp_name, swift_name, expected in (
            (
                "kNumberKeys",
                "firmwareNumberKeys",
                ride_diagnostics.FIRMWARE_NUMBER_FIELD_KEYS,
            ),
            (
                "kBooleanKeys",
                "firmwareBooleanKeys",
                ride_diagnostics.FIRMWARE_BOOLEAN_FIELD_KEYS,
            ),
        ):
            cpp_types = re.search(
                rf"{cpp_name}\[\] = \{{(.*?)\n\s*\}};",
                cpp_source,
                flags=re.DOTALL,
            )
            swift_types = re.search(
                rf"{swift_name}: Set<String> = \[(.*?)\n\s*\]",
                swift_source,
                flags=re.DOTALL,
            )
            self.assertIsNotNone(cpp_types)
            self.assertIsNotNone(swift_types)
            self.assertEqual(
                set(re.findall(r'"([A-Za-z][A-Za-z0-9]*)"', cpp_types.group(1))),
                expected,
            )
            self.assertEqual(
                set(re.findall(r'"([A-Za-z][A-Za-z0-9]*)"', swift_types.group(1))),
                expected,
            )

    def test_valid_stream_reports_sequence_gaps_and_tail(self):
        data = (json.dumps(event(2)) + "\n" + json.dumps(event(4)) + "\n" + "partial").encode()
        result = ride_diagnostics.validate_jsonl(data, "app/events.jsonl")
        self.assertTrue(result.truncated_tail)
        self.assertEqual(result.dropped_sequences, 1)
        self.assertEqual(len(result.events), 2)

    def test_complete_final_line_without_newline_is_not_truncated(self):
        result = ride_diagnostics.validate_jsonl(
            json.dumps(event()).encode(), "app/events.jsonl"
        )
        self.assertFalse(result.truncated_tail)
        self.assertEqual(len(result.events), 1)

    def test_line_limit_excludes_jsonl_delimiter(self):
        record = json.dumps(event(), separators=(",", ":")).encode()
        at_limit = record + b" " * (ride_diagnostics.MAX_LINE_BYTES - len(record))
        result = ride_diagnostics.validate_jsonl(
            at_limit + b"\n", "app/events.jsonl"
        )
        self.assertEqual(len(result.events), 1)
        with self.assertRaisesRegex(
            ride_diagnostics.DiagnosticError, "line size limit"
        ):
            ride_diagnostics.validate_jsonl(
                at_limit + b" \n", "app/events.jsonl"
            )

    def test_rejects_forbidden_fields(self):
        with self.assertRaises(ride_diagnostics.DiagnosticError):
            ride_diagnostics.validate_event(event(fields={"latitude": 1.0}))

    def test_rejects_unknown_nested_fields(self):
        with self.assertRaises(ride_diagnostics.DiagnosticError):
            ride_diagnostics.validate_event(event(fields={"futureField": "no"}))

    def test_rejects_unknown_event_fields(self):
        payload = event()
        payload["secret"] = "no"
        with self.assertRaises(ride_diagnostics.DiagnosticError):
            ride_diagnostics.validate_event(payload)

    def test_rejects_unbounded_fields_and_invalid_utf8(self):
        with self.assertRaises(ride_diagnostics.DiagnosticError):
            ride_diagnostics.validate_event(
                event(fields={
                    key: "x"
                    for key in sorted(ride_diagnostics.ALLOWED_FIELD_KEYS)[:33]
                })
            )
        with self.assertRaises(ride_diagnostics.DiagnosticError):
            ride_diagnostics.validate_event(
                event(fields={"rssiBucket": "x" * 257})
            )
        result = ride_diagnostics.validate_jsonl(
            (json.dumps(event()) + "\n").encode() + b"\xff",
            "app/events.jsonl",
        )
        self.assertTrue(result.truncated_tail)
        self.assertEqual(len(result.events), 1)

    def test_rejects_ambiguous_archive_paths(self):
        self.assertFalse(ride_diagnostics._safe_member("app//events.jsonl"))
        self.assertFalse(ride_diagnostics._safe_member("app/./events.jsonl"))
        self.assertFalse(ride_diagnostics._safe_member("app/../events.jsonl"))

    def test_rejects_noncanonical_ids_and_boolean_counters(self):
        malformed_id = event()
        malformed_id["captureId"] = "123e4567"
        with self.assertRaises(ride_diagnostics.DiagnosticError):
            ride_diagnostics.validate_event(malformed_id)

        boolean_sequence = event()
        boolean_sequence["sequence"] = True
        with self.assertRaises(ride_diagnostics.DiagnosticError):
            ride_diagnostics.validate_event(boolean_sequence)

        boolean_uptime = event()
        boolean_uptime["uptimeMs"] = False
        with self.assertRaises(ride_diagnostics.DiagnosticError):
            ride_diagnostics.validate_event(boolean_uptime)

        boolean_schema = event()
        boolean_schema["schema"] = True
        with self.assertRaises(ride_diagnostics.DiagnosticError):
            ride_diagnostics.validate_event(boolean_schema)

        numeric_wall_time = event()
        numeric_wall_time["wallTime"] = 2026
        with self.assertRaises(ride_diagnostics.DiagnosticError):
            ride_diagnostics.validate_event(numeric_wall_time)

        naive_wall_time = event()
        naive_wall_time["wallTime"] = "2026-08-19T08:20:31"
        with self.assertRaises(ride_diagnostics.DiagnosticError):
            ride_diagnostics.validate_event(naive_wall_time)

        collection_source = event()
        collection_source["source"] = ["ios"]
        with self.assertRaises(ride_diagnostics.DiagnosticError):
            ride_diagnostics.validate_event(collection_source)

    def test_accepts_firmware_boot_and_storage_gap_fields(self):
        boot = ride_diagnostics.validate_event(firmware_event())
        self.assertEqual(boot["source"], "firmware")
        gap = ride_diagnostics.validate_event(
            firmware_event(
                fields={
                    "bootSequence": 6,
                    "firmwareFingerprint": "A1B2C3D4",
                    "firstMissingUptimeMs": 100,
                    "lastMissingUptimeMs": 200,
                    "eventCount": 3,
                    "droppedCount": 1,
                    "storageErrorCount": 2,
                    "resetReason": 5,
                    "activeStage": 4,
                    "completedStage": 3,
                    "lastCriticalCategory": "storage",
                    "lastCriticalEvent": "write_failed",
                }
            )
        )
        self.assertEqual(gap["fields"]["storageErrorCount"], 2)

    def test_rejects_source_specific_field_type_mismatches(self):
        with self.assertRaises(ride_diagnostics.DiagnosticError):
            ride_diagnostics.validate_event(
                firmware_event(fields={"bootSequence": "7"})
            )
        with self.assertRaises(ride_diagnostics.DiagnosticError):
            ride_diagnostics.validate_event(
                event(fields={"sampleCount": 7})
            )

    def test_firmware_stream_requires_stable_boot_identity(self):
        for fields in (
            {"firmwareFingerprint": "A1B2C3D4"},
            {"bootSequence": 7},
            {"bootSequence": 0, "firmwareFingerprint": "A1B2C3D4"},
            {"bootSequence": True, "firmwareFingerprint": "A1B2C3D4"},
            {"bootSequence": 7, "firmwareFingerprint": "not-hex!"},
        ):
            with self.subTest(fields=fields), self.assertRaises(
                ride_diagnostics.DiagnosticError
            ):
                ride_diagnostics.validate_event(firmware_event(fields=fields))

        mixed = (
            json.dumps(firmware_event(sequence=1))
            + "\n"
            + json.dumps(
                firmware_event(
                    sequence=2,
                    fields={
                        "bootSequence": 8,
                        "firmwareFingerprint": "A1B2C3D4",
                    },
                )
            )
            + "\n"
        ).encode()
        with self.assertRaises(ride_diagnostics.DiagnosticError):
            ride_diagnostics.validate_jsonl(mixed, "device/events.jsonl")

    def test_rejects_cross_chunk_firmware_identity_change(self):
        first = ride_diagnostics.validate_jsonl(
            (json.dumps(firmware_event(sequence=0)) + "\n").encode(),
            "device/board/7/events-000001.jsonl",
            "firmware",
        )
        changed = firmware_event(
            sequence=1,
            fields={
                "bootSequence": 7,
                "firmwareFingerprint": "DEADBEEF",
            },
        )
        second = ride_diagnostics.validate_jsonl(
            (json.dumps(changed) + "\n").encode(),
            "device/board/7/events-000002.jsonl",
            "firmware",
        )
        with self.assertRaisesRegex(
            ride_diagnostics.DiagnosticError, "changes firmware identity"
        ):
            ride_diagnostics._validate_stream_boundaries([first, second])

    def test_rejects_sequence_overlap_across_chunk_boundaries(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            first = (json.dumps(firmware_event(sequence=10)) + "\n").encode()
            second = (json.dumps(firmware_event(sequence=10)) + "\n").encode()
            paths = [
                device_stream_path(7, 1, "a"),
                device_stream_path(7, 2, "b"),
            ]
            source_payloads = {paths[0]: first, paths[1]: second}
            manifest_data = json.dumps(
                bundle_manifest(source_payloads)
            ).encode()
            members = {
                "manifest.json": manifest_data,
                **source_payloads,
            }
            checksums = "".join(
                f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
                for name, payload in members.items()
            ).encode()
            bundle = root / "overlap.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                for name, payload in members.items():
                    archive.writestr(name, payload)
                archive.writestr("checksums.sha256", checksums)
            with self.assertRaises(ride_diagnostics.DiagnosticError):
                ride_diagnostics.validate_bundle(bundle)

    def test_rejects_truncated_tail_before_later_chunk(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            paths = [
                device_stream_path(7, 1, "a"),
                device_stream_path(7, 2, "b"),
            ]
            members = {
                paths[0]: (
                    json.dumps(firmware_event(sequence=10)) + "\n{\"schema\":"
                ).encode(),
                paths[1]: (
                    json.dumps(firmware_event(sequence=11)) + "\n"
                ).encode(),
            }
            members["manifest.json"] = json.dumps(
                bundle_manifest({path: members[path] for path in paths})
            ).encode()
            members.update(
                required_sidecars(json.loads(members["manifest.json"]))
            )
            checksums = "".join(
                f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
                for name, payload in members.items()
            ).encode()
            bundle = root / "interior-tail.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                for name, payload in members.items():
                    archive.writestr(name, payload)
                archive.writestr("checksums.sha256", checksums)
            with self.assertRaisesRegex(
                ride_diagnostics.DiagnosticError, "truncated tail before"
            ):
                ride_diagnostics.validate_bundle(bundle)

    def test_rejects_duplicate_chunk_numbers(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            paths = [
                device_stream_path(7, 1, "a"),
                device_stream_path(7, 1, "b"),
            ]
            members = {
                paths[0]: (json.dumps(firmware_event(sequence=10)) + "\n").encode(),
                paths[1]: (json.dumps(firmware_event(sequence=11)) + "\n").encode(),
            }
            manifest_data = json.dumps(bundle_manifest({
                path: members[path] for path in paths
            })).encode()
            members["manifest.json"] = manifest_data
            checksums = "".join(
                f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
                for name, payload in members.items()
            ).encode()
            bundle = root / "duplicate-chunk.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                for name, payload in members.items():
                    archive.writestr(name, payload)
                archive.writestr("checksums.sha256", checksums)
            with self.assertRaisesRegex(
                ride_diagnostics.DiagnosticError, "duplicates chunk"
            ):
                ride_diagnostics.validate_bundle(bundle)

    def test_counts_sequence_gaps_across_chunk_boundaries(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            paths = [
                device_stream_path(7, 1, "a"),
                device_stream_path(7, 2, "b"),
            ]
            members = {
                paths[0]: (json.dumps(firmware_event(sequence=10)) + "\n").encode(),
                paths[1]: (json.dumps(firmware_event(sequence=13)) + "\n").encode(),
            }
            members["manifest.json"] = json.dumps(
                bundle_manifest({path: members[path] for path in paths})
            ).encode()
            members.update(
                required_sidecars(json.loads(members["manifest.json"]))
            )
            checksums = "".join(
                f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
                for name, payload in members.items()
            ).encode()
            bundle = root / "chunk-gap.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                for name, payload in members.items():
                    archive.writestr(name, payload)
                archive.writestr("checksums.sha256", checksums)
            _, streams = ride_diagnostics.validate_bundle(bundle)
            self.assertEqual(streams[1].dropped_sequences, 2)

    def test_rejects_manifest_stream_coverage_mismatch(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            stream_path = APP_STREAM_PATH
            stream = (json.dumps(event()) + "\n").encode()
            missing_path = device_stream_path(7, 1, "a")
            manifest_data = json.dumps(
                bundle_manifest({missing_path: stream})
            ).encode()
            members = {
                "manifest.json": manifest_data,
                stream_path: stream,
            }
            checksums = "".join(
                f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
                for name, payload in members.items()
            ).encode()
            bundle = root / "stream-coverage.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                for name, payload in members.items():
                    archive.writestr(name, payload)
                archive.writestr("checksums.sha256", checksums)
            with self.assertRaisesRegex(
                ride_diagnostics.DiagnosticError, "manifest stream coverage mismatch"
            ):
                ride_diagnostics.validate_bundle(bundle)

    def test_rejects_private_fields_in_non_manifest_json(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            stream_path = APP_STREAM_PATH
            members = {
                stream_path: (json.dumps(event()) + "\n").encode(),
                f"device/{DEVICE_DIGEST}/1/recorder-health.json": json.dumps({
                    "schema": 1,
                    "password": "should-never-export",
                }).encode(),
            }
            members["manifest.json"] = json.dumps(
                bundle_manifest({stream_path: members[stream_path]})
            ).encode()
            checksums = "".join(
                f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
                for name, payload in members.items()
            ).encode()
            bundle = root / "private-json.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                for name, payload in members.items():
                    archive.writestr(name, payload)
                archive.writestr("checksums.sha256", checksums)
            with self.assertRaisesRegex(
                ride_diagnostics.DiagnosticError, "forbidden field"
            ):
                ride_diagnostics.validate_bundle(bundle)

    def test_rejects_unknown_fields_in_canonical_json_sidecar(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            stream_path = APP_STREAM_PATH
            stream = (json.dumps(event()) + "\n").encode()
            members = {
                stream_path: stream,
                "summary/recorder-health.json": json.dumps({
                    "schema": 1,
                    "processId": APP_PROCESS_ID,
                    "retainedBytes": len(stream),
                    "retainedChunkCount": 1,
                    "retainedCaptureCount": 1,
                    "oldestWallTime": None,
                    "newestWallTime": None,
                    "droppedEventCount": 0,
                    "lastError": None,
                    "detailedTraceEnabled": False,
                    "detailedTraceExpiresAt": None,
                    "wifi": "hunter2",
                }).encode(),
            }
            members["manifest.json"] = json.dumps(
                bundle_manifest({stream_path: stream})
            ).encode()
            checksums = "".join(
                f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
                for name, payload in members.items()
            ).encode()
            bundle = root / "unknown-sidecar-field.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                for name, payload in members.items():
                    archive.writestr(name, payload)
                archive.writestr("checksums.sha256", checksums)
            with self.assertRaisesRegex(
                ride_diagnostics.DiagnosticError,
                "summary/recorder-health.json shape is invalid",
            ):
                ride_diagnostics.validate_bundle(bundle)

    def test_rejects_bundle_without_evidence_streams(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_data = json.dumps(bundle_manifest({})).encode()
            bundle = root / "empty.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("manifest.json", manifest_data)
                archive.writestr(
                    "checksums.sha256",
                    f"{hashlib.sha256(manifest_data).hexdigest()}  manifest.json\n",
                )
            with self.assertRaisesRegex(
                ride_diagnostics.DiagnosticError,
                "sourceStreams|no diagnostic evidence",
            ):
                ride_diagnostics.validate_bundle(bundle)

    def test_rejects_boolean_manifest_schema(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            stream_path = APP_STREAM_PATH
            stream = (json.dumps(event()) + "\n").encode()
            members = {
                stream_path: stream,
                "manifest.json": json.dumps({
                    **bundle_manifest({stream_path: stream}),
                    "schema": True,
                }).encode(),
            }
            checksums = "".join(
                f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
                for name, payload in members.items()
            ).encode()
            bundle = root / "boolean-schema.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                for name, payload in members.items():
                    archive.writestr(name, payload)
                archive.writestr("checksums.sha256", checksums)
            with self.assertRaisesRegex(
                ride_diagnostics.DiagnosticError, "manifest schema is unsupported"
            ):
                ride_diagnostics.validate_bundle(bundle)

    def test_rejects_incomplete_manifest_contract(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            stream_path = APP_STREAM_PATH
            stream = (json.dumps(event()) + "\n").encode()
            manifest_data = json.dumps({
                "schema": 1,
                "sourceStreams": [stream_path],
            }).encode()
            members = {
                "manifest.json": manifest_data,
                stream_path: stream,
            }
            checksums = "".join(
                f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
                for name, payload in members.items()
            ).encode()
            bundle = root / "incomplete-manifest.zip"
            with zipfile.ZipFile(
                bundle, "w", compression=zipfile.ZIP_STORED
            ) as archive:
                for name, payload in members.items():
                    archive.writestr(name, payload)
                archive.writestr("checksums.sha256", checksums)
            with self.assertRaisesRegex(
                ride_diagnostics.DiagnosticError, "manifest shape is invalid"
            ):
                ride_diagnostics.validate_bundle(bundle)

    def test_rejects_opaque_bundle_member(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            stream_path = APP_STREAM_PATH
            stream = (json.dumps(event()) + "\n").encode()
            members = {
                "manifest.json": json.dumps(
                    bundle_manifest({stream_path: stream})
                ).encode(),
                stream_path: stream,
                "secrets.txt": b"opaque evidence is not an allowed member",
            }
            checksums = "".join(
                f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
                for name, payload in members.items()
            ).encode()
            bundle = root / "opaque-member.zip"
            with zipfile.ZipFile(
                bundle, "w", compression=zipfile.ZIP_STORED
            ) as archive:
                for name, payload in members.items():
                    archive.writestr(name, payload)
                archive.writestr("checksums.sha256", checksums)
            with self.assertRaisesRegex(
                ride_diagnostics.DiagnosticError, "unsupported bundle member"
            ):
                ride_diagnostics.validate_bundle(bundle)

    def test_rejects_non_finite_firmware_number(self):
        invalid = firmware_event(fields={
            "bootSequence": 7,
            "firmwareFingerprint": "A1B2C3D4",
            "storageErrorCount": float("nan"),
        })
        with self.assertRaisesRegex(
            ride_diagnostics.DiagnosticError, "non-finite number"
        ):
            ride_diagnostics.validate_jsonl(
                (json.dumps(invalid) + "\n").encode(),
                "device/7/events-000001.jsonl",
                "firmware",
            )

    def test_rejects_listed_but_empty_evidence_stream(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            stream_path = APP_STREAM_PATH
            members = {
                stream_path: b"",
                "manifest.json": json.dumps(
                    bundle_manifest({stream_path: b""})
                ).encode(),
            }
            checksums = "".join(
                f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
                for name, payload in members.items()
            ).encode()
            bundle = root / "empty-stream.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                for name, payload in members.items():
                    archive.writestr(name, payload)
                archive.writestr("checksums.sha256", checksums)
            with self.assertRaisesRegex(
                ride_diagnostics.DiagnosticError, "no complete diagnostic events"
            ):
                ride_diagnostics.validate_bundle(bundle)

    def test_manifest_allows_bounded_multi_chunk_stream_inventory(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            members = {
                device_stream_path(7, index + 1, "a"): (
                    json.dumps(firmware_event(sequence=index)) + "\n"
                ).encode()
                for index in range(40)
            }
            stream_paths = sorted(members)
            members["manifest.json"] = json.dumps(
                bundle_manifest({path: members[path] for path in stream_paths})
            ).encode()
            members.update(
                required_sidecars(json.loads(members["manifest.json"]))
            )
            checksums = "".join(
                f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
                for name, payload in members.items()
            ).encode()
            bundle = root / "many-streams.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                for name, payload in members.items():
                    archive.writestr(name, payload)
                archive.writestr("checksums.sha256", checksums)
            _, streams = ride_diagnostics.validate_bundle(bundle)
            self.assertEqual(len(streams), 40)

    def test_clock_anchor_correlates_pre_sync_firmware_event(self):
        before = firmware_event(sequence=0)
        before.pop("wallTime")
        before["uptimeMs"] = 100
        anchor = firmware_event(
            sequence=1,
            fields={
                "bootSequence": 7,
                "firmwareFingerprint": "A1B2C3D4",
                "clockSynchronized": True,
            },
        )
        anchor["category"] = "lifecycle"
        anchor["event"] = "clock_anchor"
        anchor["uptimeMs"] = 200
        correlated = ride_diagnostics._correlate_events([before, anchor])
        self.assertEqual(correlated[0]["clockUncertaintyMs"], 1000)
        self.assertLess(
            ride_diagnostics._event_timestamp(correlated[0]),
            ride_diagnostics._event_timestamp(correlated[1]),
        )

    def test_clock_anchor_correlation_handles_uint32_uptime_wrap(self):
        before_wrap = firmware_event(sequence=0)
        before_wrap.pop("wallTime")
        before_wrap["uptimeMs"] = 0xFFFF_FFF0
        anchor = firmware_event(
            sequence=1,
            fields={
                "bootSequence": 7,
                "firmwareFingerprint": "A1B2C3D4",
                "clockSynchronized": True,
            },
        )
        anchor["category"] = "lifecycle"
        anchor["event"] = "clock_anchor"
        anchor["uptimeMs"] = 20
        correlated = ride_diagnostics._correlate_events([before_wrap, anchor])
        delta = (
            ride_diagnostics._event_timestamp(correlated[1])
            - ride_diagnostics._event_timestamp(correlated[0])
        )
        self.assertAlmostEqual(delta.total_seconds(), 0.036, places=6)

    def test_clock_anchor_is_scoped_to_device_stream_and_corrects_raw_clock(self):
        event_a = firmware_event(sequence=0)
        event_a["uptimeMs"] = 100
        event_a["wallTime"] = "2030-01-01T00:00:00Z"
        anchor_a = firmware_event(sequence=1)
        anchor_a.update({
            "category": "lifecycle",
            "event": "clock_anchor",
            "uptimeMs": 200,
            "wallTime": "2026-01-01T00:00:01Z",
        })
        anchor_b = firmware_event(sequence=1)
        anchor_b.update({
            "category": "lifecycle",
            "event": "clock_anchor",
            "uptimeMs": 105,
            "wallTime": "2027-01-01T00:00:01Z",
        })
        streams = [
            ride_diagnostics.StreamResult(
                "device/board-a/7/events-000001.jsonl",
                (event_a, anchor_a),
            ),
            ride_diagnostics.StreamResult(
                "device/board-b/7/events-000001.jsonl",
                (anchor_b,),
            ),
        ]
        correlated = ride_diagnostics._correlate_events(streams)
        self.assertEqual(
            correlated[0]["correlatedWallTime"],
            "2026-01-01T00:00:00.900000Z",
        )
        self.assertEqual(correlated[0]["wallTime"], "2030-01-01T00:00:00Z")

    def test_bundle_hashes_and_summary(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            stream = (json.dumps(event()) + "\n").encode()
            manifest = bundle_manifest({APP_STREAM_PATH: stream})
            manifest_data = json.dumps(manifest).encode()
            members = {
                "manifest.json": manifest_data,
                APP_STREAM_PATH: stream,
                **required_sidecars(manifest),
            }
            bundle = root / "bundle.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                for name, payload in members.items():
                    archive.writestr(name, payload)
                archive.writestr(
                    "checksums.sha256",
                    "".join(
                        f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
                        for name, payload in members.items()
                    ),
                )
            output = root / "summary"
            ride_diagnostics.summarize(bundle, output)
            self.assertIn('"event": "connected"', (output / "timeline.jsonl").read_text())
            self.assertEqual(json.loads((output / "summary.json").read_text())["eventCount"], 1)
            self.assertEqual((output / "raw" / "manifest.json").read_bytes(), manifest_data)
            self.assertEqual(
                (output / "raw" / APP_STREAM_PATH).read_bytes(),
                stream,
            )
            with self.assertRaisesRegex(
                ride_diagnostics.DiagnosticError, "output directory must be empty"
            ):
                ride_diagnostics.summarize(bundle, output)

    def test_reconciles_manifest_and_current_recorder_sidecars(self):
        stream = (json.dumps(event()) + "\n").encode()

        def write_bundle(root, name, members):
            bundle = root / name
            with zipfile.ZipFile(
                bundle, "w", compression=zipfile.ZIP_STORED
            ) as archive:
                for member, payload in members.items():
                    archive.writestr(member, payload)
                archive.writestr(
                    "checksums.sha256",
                    "".join(
                        f"{hashlib.sha256(payload).hexdigest()}  {member}\n"
                        for member, payload in members.items()
                    ),
                )
            return bundle

        with TemporaryDirectory() as directory:
            root = Path(directory)

            def base_members(stream_data=stream):
                manifest = bundle_manifest({APP_STREAM_PATH: stream_data})
                return {
                    "manifest.json": json.dumps(manifest).encode(),
                    APP_STREAM_PATH: stream_data,
                    **required_sidecars(manifest),
                }

            members = base_members()
            summary_path = "summary/recorder-health.json"
            summary = json.loads(members[summary_path])
            summary["retainedBytes"] += 1
            members[summary_path] = json.dumps(summary).encode()
            with self.assertRaisesRegex(
                ride_diagnostics.DiagnosticError, "retainedBytes mismatch"
            ):
                ride_diagnostics.validate_bundle(
                    write_bundle(root, "summary-mismatch.zip", members)
                )

            members = base_members()
            app_path = f"app/{APP_PROCESS_ID}/manifest.json"
            app_manifest = json.loads(members[app_path])
            app_manifest["droppedEventCount"] = 1
            members[app_path] = json.dumps(app_manifest).encode()
            with self.assertRaisesRegex(
                ride_diagnostics.DiagnosticError,
                "current app recorder manifest droppedEventCount mismatch",
            ):
                ride_diagnostics.validate_bundle(
                    write_bundle(root, "app-manifest-mismatch.zip", members)
                )

            mismatched_event = event()
            mismatched_event["processId"] = (
                "123e4567-e89b-12d3-a456-426614174099"
            )
            mismatched_stream = (json.dumps(mismatched_event) + "\n").encode()
            with self.assertRaisesRegex(
                ride_diagnostics.DiagnosticError,
                "processId does not match manifest appProcessId",
            ):
                ride_diagnostics.validate_bundle(
                    write_bundle(
                        root,
                        "app-event-mismatch.zip",
                        base_members(mismatched_stream),
                    )
                )

    def test_timeline_filters_by_time_window(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            stream = b"\n".join(
                json.dumps(event(sequence, fields={"rssiBucket": "good"})).encode()
                for sequence in (0, 1)
            ) + b"\n"
            manifest = bundle_manifest({APP_STREAM_PATH: stream})
            manifest_data = json.dumps(manifest).encode()
            members = {
                "manifest.json": manifest_data,
                APP_STREAM_PATH: stream,
                **required_sidecars(manifest),
            }
            bundle = root / "bundle.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                for name, payload in members.items():
                    archive.writestr(name, payload)
                archive.writestr(
                    "checksums.sha256",
                    "".join(
                        f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
                        for name, payload in members.items()
                    ),
                )
            output = root / "timeline"
            ride_diagnostics.summarize(
                bundle,
                output,
                since="2026-08-19T08:20:31Z",
                until="2026-08-19T08:20:32Z",
            )
            self.assertEqual(json.loads((output / "summary.json").read_text())["eventCount"], 2)

    def test_around_issue_window_precedes_category_filter_and_requires_marker(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            marker = event(0, fields={"code": "connection_drop"})
            marker.update({"category": "user", "event": "issue_marker"})
            nearby = event(1, fields={"accuracyBucket": "good"})
            nearby.update({
                "category": "gps",
                "event": "fix_quality",
                "wallTime": "2026-08-19T08:20:41.412Z",
            })
            distant = event(2, fields={"accuracyBucket": "good"})
            distant.update({
                "category": "gps",
                "event": "fix_quality",
                "wallTime": "2026-08-19T08:22:31.412Z",
            })
            stream = "".join(
                json.dumps(item) + "\n" for item in (marker, nearby, distant)
            ).encode()
            manifest_data = json.dumps(
                bundle_manifest({APP_STREAM_PATH: stream})
            ).encode()
            members = {
                "manifest.json": manifest_data,
                APP_STREAM_PATH: stream,
                **required_sidecars(json.loads(manifest_data)),
            }
            checksums = "".join(
                f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
                for name, payload in members.items()
            )
            bundle = root / "issue-window.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                for name, payload in members.items():
                    archive.writestr(name, payload)
                archive.writestr("checksums.sha256", checksums)
            output = root / "with-marker"
            ride_diagnostics.summarize(
                bundle,
                output,
                category="gps",
                around_issue_seconds=60,
            )
            timeline = (output / "timeline.jsonl").read_text().splitlines()
            self.assertEqual(len(timeline), 1)
            self.assertEqual(json.loads(timeline[0])["sequence"], 1)

            no_marker_stream = (json.dumps(nearby) + "\n").encode()
            no_marker_manifest = json.dumps(bundle_manifest({
                APP_STREAM_PATH: no_marker_stream
            })).encode()
            no_marker_members = {
                "manifest.json": no_marker_manifest,
                APP_STREAM_PATH: no_marker_stream,
                **required_sidecars(json.loads(no_marker_manifest)),
            }
            no_marker_checksums = "".join(
                f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
                for name, payload in no_marker_members.items()
            )
            no_marker_bundle = root / "no-marker.zip"
            with zipfile.ZipFile(no_marker_bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                for name, payload in no_marker_members.items():
                    archive.writestr(name, payload)
                archive.writestr("checksums.sha256", no_marker_checksums)
            with self.assertRaisesRegex(
                ride_diagnostics.DiagnosticError,
                "requires a timestamped issue marker",
            ):
                ride_diagnostics.summarize(
                    no_marker_bundle,
                    root / "without-marker",
                    around_issue_seconds=60,
                )

    def test_rejects_checksum_tampering(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / "bundle.zip"
            with zipfile.ZipFile(bundle, "w") as archive:
                manifest_data = json.dumps(
                    bundle_manifest({
                        APP_STREAM_PATH:
                            (json.dumps(event()) + "\n").encode()
                    })
                ).encode()
                archive.writestr("manifest.json", manifest_data)
                archive.writestr(
                    APP_STREAM_PATH, json.dumps(event()) + "\n"
                )
                manifest_checksum = hashlib.sha256(manifest_data).hexdigest()
                archive.writestr(
                    "checksums.sha256",
                    f"{manifest_checksum}  manifest.json\n"
                    f"{'0' * 64}  {APP_STREAM_PATH}\n",
                )
            with self.assertRaises(ride_diagnostics.DiagnosticError):
                ride_diagnostics.validate_bundle(bundle)


if __name__ == "__main__":
    unittest.main()
