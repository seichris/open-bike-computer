from pathlib import Path
import tempfile
import unittest

from tools.sleep_audit_summary import decode_state, read_records, summarize


def event(state, phase="wake", domain="resume", attempt="ABC"):
    return {"source": "firmware", "category": "power", "event": "sleep_audit",
            "sequence": 1, "fields": {"schemaVersion": 1, "phase": phase,
            "domain": domain, "attemptId": attempt, "state": state, "available": True}}


class SleepAuditSummaryTests(unittest.TestCase):
    def test_unknown_is_not_zero(self):
        result = summarize([event("classification=confirmed_deep_sleep;interval_valid=0;interval_ms=unknown")])
        self.assertIsNone(result[0]["entryToEarlyBootMs"])
        self.assertEqual(result[0]["classification"], "confirmed_deep_sleep")
        self.assertEqual(result[0]["currentMeasurement"], "unsupported")
        self.assertEqual(decode_state("00=00;01=??"), {"00": "00", "01": None})

    def test_valid_interval_and_unmatched_request(self):
        result = summarize([event("classification=confirmed_deep_sleep;interval_valid=1;interval_ms=172800000"),
                            event("present=1;percent=72", "request", "battery", "DEF")])
        self.assertEqual(result[0]["entryToEarlyBootMs"], 172800000)
        self.assertEqual(result[1]["classification"], "request_without_correlated_wake")
        self.assertIsNone(result[1]["entryToEarlyBootMs"])

    def test_rejects_bad_or_future_schema(self):
        for state in ("x=1;x=2", "broken", "x=" + "a"*257):
            with self.assertRaises(ValueError):
                decode_state(state)
        record = event("x=1")
        record["fields"]["schemaVersion"] = 2
        with self.assertRaises(ValueError):
            summarize([record])

    def test_does_not_silently_ignore_corrupt_log(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.jsonl"
            path.write_text('{"truncated":')
            with self.assertRaisesRegex(ValueError, "invalid JSON"):
                list(read_records([path]))
        with self.assertRaises(ValueError):
            list(read_records([Path("/not-a-sleep-audit-file")]))


if __name__ == "__main__":
    unittest.main()
