"""Executable cross-language producer contract, plus generation drift gates."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import ride_diagnostics
import generate_diagnostics_contract as generator


class DiagnosticsRegistryTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("c++"), "C++ compiler unavailable")
    def test_actual_gps_quality_formatter_roundtrips_to_host(self):
        # Compile the actual producer's formatter, including every field it
        # currently emits. A hand-written fixture missed this registry drift.
        producer = (ROOT / "esp32/lib/ble_navigation/ble_navigation.cpp").read_text()
        start = producer.index("    char fields[320] = {};",
                               producer.index("lastRideDiagnosticsGpsLogMs.load"))
        end = producer.index("    ride_diagnostics::record", start)
        formatter = producer[start:end]
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "gps.cpp"
            source.write_text(r'''#include "esp32/lib/ride_diagnostics/ride_diagnostics_format.hpp"
#include <cassert>
#include <iostream>
struct Packet { bool fixValid=true, hasSpeed=true, hasHorizontalAccuracy=true; } packet;
struct Sample { bool ageKnown=true; unsigned capturedAtMs=100; } sourceSample;
struct Stats { unsigned lastGpsPacketGapMs=1000, maximumGpsPacketGapMs=1000; };
struct Debug { Stats read() { return {}; } } bleDebugStats;
struct Arrival { unsigned lastPacketMs=200; } arrivals;
int main() {
  unsigned nowMs=300;
''' + formatter + r'''
  assert(ride_diagnostics::detail::validateFieldsJson(fields, std::strlen(fields)));
  std::cout << fields;
}''')
            executable = Path(directory) / "gps"
            subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(ROOT), str(source), "-o", str(executable)], check=True)
            fields = json.loads(subprocess.check_output([str(executable)]))
            registry = generator.load_registry()
            self.assertEqual(set(fields), set(registry["events"]["gps.quality_checkpoint"]["required"]))
            fields.update(bootSequence=1, firmwareFingerprint="A1B2C3D4")
            event = dict(schema=1, source="firmware", sequence=1, level="info",
                         category="gps", event="quality_checkpoint", fields=fields)
            result = ride_diagnostics.validate_jsonl((json.dumps(event) + "\n").encode(), "gps.jsonl", "firmware")
            self.assertEqual(len(result.events), 1)
            self.assertIs(result.events[0]["fields"]["sourceAgeKnown"], True)

    def test_generated_contract_is_current(self):
        subprocess.run([sys.executable, str(ROOT / "tools/generate_diagnostics_contract.py"), "--check"], check=True)

    def test_registry_rejects_unreviewed_payload(self):
        registry = generator.load_registry()
        self.assertNotIn("password", registry["fields"])
        self.assertNotIn("latitude", registry["fields"])
        self.assertEqual(registry["fields"]["recorderReady"]["firmwareType"], "boolean")

    @unittest.skipUnless(shutil.which("c++"), "C++ compiler unavailable")
    def test_actual_health_formatter_roundtrips_to_host(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "health.cpp"
            source.write_text(r'''#include "esp32/lib/ride_diagnostics/ride_diagnostics_format.hpp"
#include <cassert>
#include <iostream>
struct Stats { unsigned enqueued=10, written=8, dropped=2, storageErrors=1;
  unsigned queueDepth=2, maxQueueDepth=5; bool storageAvailable=true, recorderReady=true; };
int main() {
  char text[288]; Stats stats;
  assert(ride_diagnostics::detail::formatRecorderHealthFields(text, sizeof(text), "ready", stats));
  assert(ride_diagnostics::detail::validateFieldsJson(text, std::strlen(text)));
  char shortBuffer[8];
  assert(!ride_diagnostics::detail::formatRecorderHealthFields(shortBuffer, sizeof(shortBuffer), "ready", stats));
  assert(!ride_diagnostics::detail::formatRecorderHealthFields(text, sizeof(text), "bad\"reason", stats));
  assert(ride_diagnostics::detail::formatRecorderHealthFields(text, sizeof(text), "ready", stats));
  std::cout << text;
}''')
            executable = Path(directory) / "health"
            subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT), str(source), "-o", str(executable)], check=True)
            fields = json.loads(subprocess.check_output([str(executable)]))
            fields.update(bootSequence=1, firmwareFingerprint="A1B2C3D4")
            event = dict(schema=1, source="firmware", sequence=1, level="info", category="logger", event="health", fields=fields)
            result = ride_diagnostics.validate_jsonl((json.dumps(event) + "\n").encode(), "health.jsonl", "firmware")
            self.assertEqual(len(result.events), 1)
            self.assertIs(result.events[0]["fields"]["recorderReady"], True)
