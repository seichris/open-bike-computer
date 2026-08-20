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


class RideDiagnosticsTests(unittest.TestCase):
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

        swift_validator = (
            REPO_ROOT
            / "ios-app/BikeComputer/BikeComputer/Managers/DeviceDiagnosticsTransferManager.swift"
        ).read_text()
        for cpp_name, swift_name, expected in (
            ("kNumberKeys", "numberKeys", ride_diagnostics.FIRMWARE_NUMBER_FIELD_KEYS),
            ("kBooleanKeys", "booleanKeys", ride_diagnostics.FIRMWARE_BOOLEAN_FIELD_KEYS),
        ):
            cpp_types = re.search(
                rf"{cpp_name}\[\] = \{{(.*?)\n\s*\}};",
                cpp_source,
                flags=re.DOTALL,
            )
            swift_types = re.search(
                rf"{swift_name}: Set<String> = \[(.*?)\n\s*\]",
                swift_validator,
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

    def test_rejects_sequence_overlap_across_chunk_boundaries(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            first = (json.dumps(firmware_event(sequence=10)) + "\n").encode()
            second = (json.dumps(firmware_event(sequence=10)) + "\n").encode()
            manifest_data = json.dumps({
                "schema": 1,
                "sourceStreams": [
                    "device/7/events-000001-a.jsonl",
                    "device/7/events-000002-b.jsonl",
                ],
            }).encode()
            members = {
                "manifest.json": manifest_data,
                "device/7/events-000001-a.jsonl": first,
                "device/7/events-000002-b.jsonl": second,
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

    def test_rejects_duplicate_chunk_numbers(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            paths = [
                "device/7/events-000001-a.jsonl",
                "device/7/events-000001-b.jsonl",
            ]
            members = {
                paths[0]: (json.dumps(firmware_event(sequence=10)) + "\n").encode(),
                paths[1]: (json.dumps(firmware_event(sequence=11)) + "\n").encode(),
            }
            manifest_data = json.dumps({
                "schema": 1,
                "sourceStreams": paths,
            }).encode()
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
                "device/7/events-000001-a.jsonl",
                "device/7/events-000002-b.jsonl",
            ]
            members = {
                paths[0]: (json.dumps(firmware_event(sequence=10)) + "\n").encode(),
                paths[1]: (json.dumps(firmware_event(sequence=13)) + "\n").encode(),
            }
            members["manifest.json"] = json.dumps({
                "schema": 1,
                "sourceStreams": paths,
            }).encode()
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
            stream_path = "app/events.jsonl"
            stream = (json.dumps(event()) + "\n").encode()
            manifest_data = json.dumps({
                "schema": 1,
                "sourceStreams": [],
            }).encode()
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

    def test_bundle_hashes_and_summary(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            stream = (json.dumps(event()) + "\n").encode()
            manifest = {"schema": 1, "sourceStreams": ["app/events.jsonl"]}
            manifest_data = json.dumps(manifest).encode()
            checksum = hashlib.sha256(stream).hexdigest()
            manifest_checksum = hashlib.sha256(manifest_data).hexdigest()
            bundle = root / "bundle.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("manifest.json", manifest_data)
                archive.writestr("app/events.jsonl", stream)
                archive.writestr(
                    "checksums.sha256",
                    f"{manifest_checksum}  manifest.json\n{checksum}  app/events.jsonl\n",
                )
            output = root / "summary"
            ride_diagnostics.summarize(bundle, output)
            self.assertIn('"event": "connected"', (output / "timeline.jsonl").read_text())
            self.assertEqual(json.loads((output / "summary.json").read_text())["eventCount"], 1)
            self.assertEqual((output / "raw" / "manifest.json").read_bytes(), manifest_data)
            self.assertEqual((output / "raw" / "app" / "events.jsonl").read_bytes(), stream)

    def test_timeline_filters_by_time_window(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            stream = b"\n".join(
                json.dumps(event(sequence, fields={"rssiBucket": "good"})).encode()
                for sequence in (0, 1)
            ) + b"\n"
            manifest = {"schema": 1, "sourceStreams": ["app/events.jsonl"]}
            manifest_data = json.dumps(manifest).encode()
            checksum = hashlib.sha256(stream).hexdigest()
            manifest_checksum = hashlib.sha256(manifest_data).hexdigest()
            bundle = root / "bundle.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("manifest.json", manifest_data)
                archive.writestr("app/events.jsonl", stream)
                archive.writestr(
                    "checksums.sha256",
                    f"{manifest_checksum}  manifest.json\n{checksum}  app/events.jsonl\n",
                )
            output = root / "timeline"
            ride_diagnostics.summarize(
                bundle,
                output,
                since="2026-08-19T08:20:31Z",
                until="2026-08-19T08:20:32Z",
            )
            self.assertEqual(json.loads((output / "summary.json").read_text())["eventCount"], 2)

    def test_rejects_checksum_tampering(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / "bundle.zip"
            with zipfile.ZipFile(bundle, "w") as archive:
                manifest_data = json.dumps({
                    "schema": 1,
                    "sourceStreams": ["app/events.jsonl"],
                }).encode()
                archive.writestr("manifest.json", manifest_data)
                archive.writestr("app/events.jsonl", json.dumps(event()) + "\n")
                manifest_checksum = hashlib.sha256(manifest_data).hexdigest()
                archive.writestr(
                    "checksums.sha256",
                    f"{manifest_checksum}  manifest.json\n{'0' * 64}  app/events.jsonl\n",
                )
            with self.assertRaises(ride_diagnostics.DiagnosticError):
                ride_diagnostics.validate_bundle(bundle)


if __name__ == "__main__":
    unittest.main()
