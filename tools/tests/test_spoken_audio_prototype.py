"""Slice-0 host evidence only; deliberately no product capability changes."""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/spoken_directions/prepare_pack.py"
SPEC = importlib.util.spec_from_file_location("speech_pack_preparation", SCRIPT)
assert SPEC and SPEC.loader
pack = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pack)


class SpokenPrototypeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="spoken-pack-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        stream = io.BytesIO()
        with wave.open(stream, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16000)
            wav.writeframes(b"\0\0" * 160)
        self.wav = stream.getvalue()
        (self.root / "sample.wav").write_bytes(self.wav)
        (self.root / "NOTICES").write_text("Synthetic silence for unit tests, not production voice audio.")
        self.spec = {"schemaVersion": 0, "packID": "test-only", "version": "0.0.1",
                     "locale": "en-GB", "units": "metric", "provenance": "synthetic-test-only",
                     "noticesFile": "NOTICES", "assets": {
                         key: {"file": "sample.wav", "sourceSHA256": hashlib.sha256(self.wav).hexdigest()}
                         for key in pack.SEMANTICS}}
        self.path = self.root / "spec.json"

    def prepare(self, budget=1_000_000):
        self.path.write_text(json.dumps(self.spec))
        return pack.prepare(self.path, budget)

    def test_bounded_cpp_decoder(self):
        subprocess.run([sys.executable, ROOT / "tools/spoken_directions/run_tests.py", "--cpp-only"], check=True)

    def test_reproducible_complete_unsigned_pack(self):
        first = self.prepare()
        self.assertEqual(first, self.prepare())
        magic, version, flags, reserved, manifest_size, payload_size = pack.HEADER.unpack_from(first)
        self.assertEqual((magic, version, flags, reserved), (b"BPK0", 0, 1, 0))
        manifest = json.loads(first[16:16 + manifest_size])
        self.assertEqual(manifest["purpose"], "unsigned-measurement-only")
        self.assertEqual(len(manifest["assets"]), 39)
        self.assertEqual(payload_size, 39 * 320)
        self.assertEqual(len(first), 16 + manifest_size + payload_size)
        payload = first[16 + manifest_size:]
        for record in manifest["assets"]:
            pcm = payload[record["offset"]:record["offset"] + record["bytes"]]
            self.assertEqual(hashlib.sha256(pcm).hexdigest(), record["sha256"])

    def test_missing_semantic(self):
        del self.spec["assets"]["continue"]
        with self.assertRaises(pack.InvalidPack): self.prepare()

    def test_duplicate_json_key(self):
        self.path.write_text('{"schemaVersion":0,"schemaVersion":0}')
        with self.assertRaises(pack.InvalidPack): pack.prepare(self.path, 1000)

    def test_wrong_locale(self):
        self.spec["locale"] = "de-DE"
        with self.assertRaises(pack.InvalidPack): self.prepare()

    def test_missing_provenance(self):
        self.spec["provenance"] = ""
        with self.assertRaises(pack.InvalidPack): self.prepare()

    def test_budget(self):
        for budget in (-1, 0, 100, pack.MAX_PAYLOAD + 1):
            with self.subTest(budget=budget), self.assertRaises(pack.InvalidPack): self.prepare(budget)

    def test_changed_recording(self):
        (self.root / "sample.wav").write_bytes(self.wav + b"changed")
        with self.assertRaises(pack.InvalidPack): self.prepare()

    def replace_recording(self, data):
        (self.root / "sample.wav").write_bytes(data)
        for entry in self.spec["assets"].values():
            entry["sourceSHA256"] = hashlib.sha256(data).hexdigest()

    def test_format_and_duration(self):
        for channels, rate, width, frames in [(2,16000,2,160), (1,22050,2,160),
                                               (1,16000,1,160), (1,16000,2,0),
                                               (1,16000,2,128001)]:
            stream = io.BytesIO()
            with wave.open(stream, "wb") as wav:
                wav.setnchannels(channels)
                wav.setsampwidth(width)
                wav.setframerate(rate)
                wav.writeframes(bytes(channels * width * frames))
            self.replace_recording(stream.getvalue())
            with self.subTest(channels=channels, rate=rate, frames=frames), self.assertRaises(pack.InvalidPack):
                self.prepare()

    def test_truncated_and_oversized_input(self):
        for data in (self.wav[:-2], self.wav + bytes(pack.MAX_WAV)):
            self.replace_recording(data)
            with self.assertRaises(pack.InvalidPack): self.prepare()

    def test_manifest_rejects_unbounded_and_extra_fields(self):
        self.spec["provenance"] = "x" * 129
        with self.assertRaises(pack.InvalidPack): self.prepare()
        self.spec["provenance"] = "test"
        self.spec["extra"] = "unexpected"
        with self.assertRaises(pack.InvalidPack): self.prepare()
        del self.spec["extra"]
        self.spec["version"] = "00.1.0"
        with self.assertRaises(pack.InvalidPack): self.prepare()

    def test_path_escape_and_symlink(self):
        for name in ("../sample.wav", "/tmp/sample.wav", "link.wav"):
            if name == "link.wav": (self.root / name).symlink_to(self.root / "sample.wav")
            self.spec["assets"]["continue"]["file"] = name
            with self.subTest(name=name), self.assertRaises(pack.InvalidPack): self.prepare()

    def test_no_overwrite(self):
        self.prepare()
        output = self.root / "existing"
        output.write_bytes(b"preserve me")
        result = subprocess.run([sys.executable, SCRIPT, self.path, output,
                                 "--maximum-bytes", "1000000"], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output.read_bytes(), b"preserve me")


if __name__ == "__main__": unittest.main()
