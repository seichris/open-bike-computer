import json
import os
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


REPO_ROOT = Path(__file__).resolve().parents[2]
COLLECTOR = REPO_ROOT / "ios-app/scripts/collect-ride-diagnostics.sh"


class CollectRideDiagnosticsTests(unittest.TestCase):
    def run_collector(
        self,
        event,
        sidecar=None,
        collector_root="app/123e4567-e89b-12d3-a456-426614174000",
        sidecar_name="manifest.json",
        event_name="events-000001.jsonl",
    ):
        temporary = TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        fixture = root / "fixture.jsonl"
        fixture.write_text(json.dumps(event) + "\n")
        sidecar_fixture = root / "manifest.json"
        if sidecar is not None:
            sidecar_fixture.write_text(json.dumps(sidecar))
        mock_bin = root / "bin"
        mock_bin.mkdir()
        xcrun = mock_bin / "xcrun"
        xcrun.write_text("""#!/bin/sh
set -eu
destination=
json_output=
while [ \"$#\" -gt 0 ]; do
  case \"$1\" in
    --destination) destination=$2; shift 2 ;;
    --json-output) json_output=$2; shift 2 ;;
    *) shift ;;
  esac
done
target=\"$destination/Library/Application Support/BicinoDiagnostics/v1/${COLLECTOR_ROOT}\"
mkdir -p \"$target\"
cp \"$COLLECTOR_FIXTURE\" \"$target/${COLLECTOR_EVENT_NAME}\"
if [ -n \"${COLLECTOR_SIDECAR_FIXTURE:-}\" ]; then
  cp \"$COLLECTOR_SIDECAR_FIXTURE\" \"$target/${COLLECTOR_SIDECAR_NAME}\"
fi
printf '{}' > \"$json_output\"
""")
        xcrun.chmod(0o755)
        destination = root / "destination"
        environment = os.environ.copy()
        environment["PATH"] = f"{mock_bin}:{environment['PATH']}"
        environment["COLLECTOR_FIXTURE"] = str(fixture)
        environment["COLLECTOR_ROOT"] = collector_root
        environment["COLLECTOR_SIDECAR_NAME"] = sidecar_name
        environment["COLLECTOR_EVENT_NAME"] = event_name
        if sidecar is not None:
            environment["COLLECTOR_SIDECAR_FIXTURE"] = str(sidecar_fixture)
        result = subprocess.run(
            [
                str(COLLECTOR),
                "--device", "test-device",
                "--bundle-id", "LetItRide.BikeComputer.dev",
                "--destination", str(destination),
            ],
            cwd=REPO_ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        return result, destination

    def valid_app_manifest(self):
        return {
            "schema": 1,
            "source": "ios",
            "processId": "123e4567-e89b-12d3-a456-426614174000",
            "createdAt": "2026-08-19T08:20:31.412Z",
            "chunkLimitBytes": 8192,
            "retentionBytes": 52428800,
            "retentionCaptureCount": 64,
            "retentionAgeDays": 14,
            "droppedEventCount": 0,
        }

    def valid_event(self):
        return {
            "schema": 1,
            "source": "ios",
            "sequence": 0,
            "level": "info",
            "category": "ble",
            "event": "connected",
            "fields": {"rssiBucket": "good"},
        }

    def test_uses_canonical_privacy_and_schema_validation(self):
        forbidden = self.valid_event()
        forbidden["fields"] = {"latitude": 1.0}
        result, _ = self.run_collector(forbidden)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown field", result.stderr)

        boolean_schema = self.valid_event()
        boolean_schema["schema"] = True
        result, _ = self.run_collector(boolean_schema)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("schema", result.stderr)

        result, _ = self.run_collector(
            self.valid_event(),
            {"schema": 1, "transferPassphrase": "must-not-be-copied"},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("forbidden field", result.stderr)

    def test_accepts_valid_tree_and_rejects_destination_reuse(self):
        result, destination = self.run_collector(self.valid_event())
        self.assertEqual(result.returncode, 0, result.stderr)
        reused = subprocess.run(
            [
                str(COLLECTOR),
                "--device", "test-device",
                "--bundle-id", "LetItRide.BikeComputer.dev",
                "--destination", str(destination),
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(reused.returncode, 64)
        self.assertIn("new or empty", reused.stderr)

    def test_validates_canonical_app_sidecar(self):
        result, _ = self.run_collector(
            self.valid_event(),
            self.valid_app_manifest(),
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_noncanonical_collected_path(self):
        temporary = TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        fixture = root / "fixture.jsonl"
        fixture.write_text(json.dumps(self.valid_event()) + "\n")
        mock_bin = root / "bin"
        mock_bin.mkdir()
        xcrun = mock_bin / "xcrun"
        xcrun.write_text("""#!/bin/sh
set -eu
destination=
json_output=
while [ \"$#\" -gt 0 ]; do
  case \"$1\" in
    --destination) destination=$2; shift 2 ;;
    --json-output) json_output=$2; shift 2 ;;
    *) shift ;;
  esac
done
target=\"$destination/Library/Application Support/BicinoDiagnostics/v1/app/not-a-uuid\"
mkdir -p \"$target\"
cp \"$COLLECTOR_FIXTURE\" \"$target/events-000001.jsonl\"
printf '{}' > \"$json_output\"
""")
        xcrun.chmod(0o755)
        destination = root / "destination"
        environment = os.environ.copy()
        environment["PATH"] = f"{mock_bin}:{environment['PATH']}"
        environment["COLLECTOR_FIXTURE"] = str(fixture)
        result = subprocess.run(
            [
                str(COLLECTOR),
                "--device", "test-device",
                "--bundle-id", "LetItRide.BikeComputer.dev",
                "--destination", str(destination),
            ],
            cwd=REPO_ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("noncanonical", result.stderr)

    def test_normalizes_imported_device_paths_before_strict_validation(self):
        event = self.valid_event()
        event.update({
            "source": "firmware",
            "fields": {
                "bootSequence": 1,
                "firmwareFingerprint": "A1B2C3D4",
                "ready": True,
            },
        })
        sidecar = {
            "schema": 1,
            "source": "firmware",
            "bootSequence": 1,
            "activeChunk": 2,
            "stats": {
                "enqueued": 1,
                "written": 1,
                "dropped": 0,
                "storageErrors": 0,
            },
            "chunks": [{
                "bootSequence": 1,
                "chunk": 1,
                "bytes": 1,
                "sha256": "a" * 64,
            }],
        }
        result, destination = self.run_collector(
            event,
            sidecar,
            collector_root="imported-device/0123456789abcdef/1",
            sidecar_name="recorder-health.json",
            event_name="events-000001-aaaaaaaaaaaaaaaa.jsonl",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(
            (destination
             / "Library/Application Support/BicinoDiagnostics/v1"
             / "device/0123456789abcdef/1"
             / "events-000001-aaaaaaaaaaaaaaaa.jsonl").is_file()
        )


if __name__ == "__main__":
    unittest.main()
