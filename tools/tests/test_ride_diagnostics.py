import hashlib
import json
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


class RideDiagnosticsTests(unittest.TestCase):
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

    def test_rejects_unknown_event_fields(self):
        payload = event()
        payload["secret"] = "no"
        with self.assertRaises(ride_diagnostics.DiagnosticError):
            ride_diagnostics.validate_event(payload)

    def test_bundle_hashes_and_summary(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            stream = (json.dumps(event()) + "\n").encode()
            manifest = {"schema": 1, "sourceStreams": ["app/events.jsonl"]}
            checksum = hashlib.sha256(stream).hexdigest()
            bundle = root / "bundle.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("manifest.json", json.dumps(manifest))
                archive.writestr("app/events.jsonl", stream)
                archive.writestr("checksums.sha256", f"{checksum}  app/events.jsonl\n")
            output = root / "summary"
            ride_diagnostics.summarize(bundle, output)
            self.assertIn('"event": "connected"', (output / "timeline.jsonl").read_text())
            self.assertEqual(json.loads((output / "summary.json").read_text())["eventCount"], 1)

    def test_timeline_filters_by_time_window(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            stream = b"\n".join(
                json.dumps(event(sequence, fields={"rssiBucket": "good"})).encode()
                for sequence in (0, 1)
            ) + b"\n"
            manifest = {"schema": 1, "sourceStreams": ["app/events.jsonl"]}
            checksum = hashlib.sha256(stream).hexdigest()
            bundle = root / "bundle.zip"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("manifest.json", json.dumps(manifest))
                archive.writestr("app/events.jsonl", stream)
                archive.writestr("checksums.sha256", f"{checksum}  app/events.jsonl\n")
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
                archive.writestr("manifest.json", '{"schema":1}')
                archive.writestr("app/events.jsonl", json.dumps(event()) + "\n")
                archive.writestr("checksums.sha256", "0" * 64 + "  app/events.jsonl\n")
            with self.assertRaises(ride_diagnostics.DiagnosticError):
                ride_diagnostics.validate_bundle(bundle)


if __name__ == "__main__":
    unittest.main()
