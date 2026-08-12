import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "ride_trace_replay.py"
SPEC = importlib.util.spec_from_file_location("ride_trace_replay", SCRIPT)
assert SPEC and SPEC.loader
replay_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(replay_module)


class RideTraceReplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._temp = tempfile.TemporaryDirectory(prefix="ride-trace-test-")
        cls.binary = Path(cls._temp.name) / "ride_trace_replay"
        replay_module.build_replay_binary(cls.binary)
        cls.emitter = Path(cls._temp.name) / "emit_ride_trace_fixture"
        subprocess.run(
            [
                "c++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                str(Path(__file__).parent / "emit_ride_trace_fixture.cpp"),
                "-o", str(cls.emitter),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls):
        cls._temp.cleanup()

    def test_synthetic_regression_trace(self):
        trace = Path(__file__).parent / "fixtures" / "ride_automation" / "synthetic-regression.jsonl"
        records = replay_module.load_trace(trace)
        outputs = replay_module.replay(records, self.binary)
        summary = replay_module.validate_expectations(trace, records, outputs)
        self.assertEqual(summary["mismatches"], 0)
        self.assertEqual(summary["decisions"], 3)
        self.assertEqual(summary["false_starts"], 0)
        self.assertEqual(summary["false_pauses"], 0)
        self.assertEqual(summary["missed_transitions"], 0)
        self.assertEqual(summary["start_latency_ms_total"], 8_000)
        self.assertEqual(summary["pause_latency_ms_total"], 5_000)
        self.assertEqual(summary["resume_latency_ms_total"], 2_000)

    def test_rejects_private_and_raw_sensor_fields(self):
        for forbidden in sorted(replay_module.FORBIDDEN_KEYS):
            with self.subTest(forbidden=forbidden), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "bad.jsonl"
                record = {
                    "schema": 1,
                    "profile": 1,
                    "t_ms": 0,
                    "lifecycle": "idle",
                    "evidence": {forbidden: [1, 2, 3]},
                }
                path.write_text(json.dumps(record) + "\n", encoding="utf-8")
                with self.assertRaises(replay_module.TraceError):
                    replay_module.load_trace(path)

    def test_missing_metric_is_not_encoded_as_zero(self):
        row = replay_module.encode_record(
            {"schema": 1, "t_ms": 42, "lifecycle": "idle", "evidence": {}}
        )
        fields = row.split("\t")
        self.assertEqual(fields[4:10], ["-", "-", "-", "-", "-", "-"])

    def test_schema_one_hdop_migrates_to_schema_two_uncertainty(self):
        legacy = {
            "schema": 1,
            "profile": 1,
            "t_ms": 42,
            "lifecycle": "idle",
            "evidence": {"gps_hdop": {"value": 2.5, "age_ms": 7}},
        }
        fields = replay_module.encode_record(legacy).split("\t")
        self.assertEqual(fields[12:14], ["12.5", "7"])

        modern = {
            "schema": 2,
            "profile": 2,
            "t_ms": 43,
            "lifecycle": "idle",
            "evidence": {
                "gps_source": 2,
                "gps_horizontal_uncertainty_m": 7.3,
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "modern.jsonl"
            path.write_text(json.dumps(modern) + "\n", encoding="utf-8")
            self.assertEqual(replay_module.load_trace(path), [modern])

    def test_schema_rejects_wrong_types_and_nonfinite_values(self):
        invalid_records = [
            {"schema": 1, "profile": 1, "t_ms": 0, "lifecycle": "idle", "settings": []},
            {"schema": 1, "profile": 1, "t_ms": 0, "lifecycle": "idle", "settings": {"auto_pause": "false"}},
            {"schema": 1, "profile": 1, "t_ms": 0, "lifecycle": "idle", "evidence": {"gps_fix_valid": 1}},
            {"schema": 1, "profile": 1, "t_ms": 0, "lifecycle": "idle", "evidence": {"gps_hdop": float("nan")}},
            {"schema": 1, "profile": 1, "t_ms": 0x1_0000_0000, "lifecycle": "idle"},
        ]
        for record in invalid_records:
            with self.subTest(record=record), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "bad.jsonl"
                path.write_text(json.dumps(record) + "\n", encoding="utf-8")
                with self.assertRaises(replay_module.TraceError):
                    replay_module.load_trace(path)

    def test_schema_rejects_unknown_fields_bad_ages_and_backwards_time(self):
        invalid_sequences = [
            [{"schema": 1, "profile": 1, "t_ms": 0, "lifecycle": "idle", "coordinates": [1, 2]}],
            [{"schema": 1, "profile": 1, "t_ms": 0, "lifecycle": "idle", "evidence": {"imu_samples": [1]}}],
            [{"schema": 1, "profile": 1, "t_ms": 0, "lifecycle": "idle", "evidence": {"wheel_mps": {"value": 1, "age_ms": True}}}],
            [{"schema": 1, "profile": 1, "t_ms": 0, "lifecycle": "idle", "evidence": {"wheel_mps": {"value": 1, "age_ms": 0x1_0000_0000}}}],
            [
                {"schema": 1, "profile": 1, "t_ms": 5_000, "lifecycle": "running"},
                {"schema": 1, "profile": 1, "t_ms": 4_000, "lifecycle": "running"},
            ],
        ]
        for records in invalid_sequences:
            with self.subTest(records=records), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "bad.jsonl"
                path.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")
                with self.assertRaises(replay_module.TraceError):
                    replay_module.load_trace(path)

    def test_uint32_timestamp_wrap_is_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "wrap.jsonl"
            records = [
                {"schema": 1, "profile": 1, "t_ms": 0xFFFF_FF00, "lifecycle": "idle"},
                {"schema": 1, "profile": 1, "t_ms": 0x0000_0100, "lifecycle": "idle"},
            ]
            path.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")
            self.assertEqual(len(replay_module.load_trace(path)), 2)

    def test_firmware_formatter_output_round_trips_through_replay(self):
        emitted = subprocess.run(
            [str(self.emitter)], text=True, capture_output=True, check=True
        ).stdout
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "captured.jsonl"
            path.write_text(emitted, encoding="utf-8")
            records = replay_module.load_trace(path)
            outputs = replay_module.replay(records, self.binary)
            self.assertEqual(outputs[0]["transition"], "none")

    def test_shipped_cli_exit_codes(self):
        fixture = Path(__file__).parent / "fixtures" / "ride_automation" / "synthetic-regression.jsonl"
        success = subprocess.run(
            [sys.executable, str(SCRIPT), "--binary", str(self.binary), str(fixture)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(success.returncode, 0, success.stderr)

        with tempfile.TemporaryDirectory() as directory:
            mismatch = Path(directory) / "mismatch.jsonl"
            mismatch.write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "profile": 1,
                        "t_ms": 0,
                        "lifecycle": "idle",
                        "expected": "start",
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            mismatched = subprocess.run(
                [sys.executable, str(SCRIPT), "--binary", str(self.binary), str(mismatch)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(mismatched.returncode, 1)
            self.assertIn("expected start, got none", mismatched.stderr)

            invalid = Path(directory) / "invalid.jsonl"
            invalid.write_text(
                '{"schema":1,"profile":1,"t_ms":0,"lifecycle":"idle","lat":1}\n',
                encoding="utf-8",
            )
            rejected = subprocess.run(
                [sys.executable, str(SCRIPT), "--binary", str(self.binary), str(invalid)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(rejected.returncode, 2)
            self.assertIn("unknown record fields", rejected.stderr)


if __name__ == "__main__":
    unittest.main()
