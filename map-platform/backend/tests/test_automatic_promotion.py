import subprocess
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

source = Path(os.environ.get("PROMOTION_SCHEDULER_SOURCE", Path(__file__).resolve().parents[1] / "map_platform" / "automatic_promotion.py"))
spec = importlib.util.spec_from_file_location("automatic_promotion", source)
promotion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(promotion)
JOB_TIMEOUT, PromotionQueue, run_promotion = promotion.JOB_TIMEOUT, promotion.PromotionQueue, promotion.run_promotion


class AutomaticPromotionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "queue.db"
        self.catalog = Mock(channel="production")
        self.ids = ["map_v1_" + char * 43 for char in "ab"]
        self.catalog._request.return_value = {"mapEntryIds": self.ids, "nextCursor": None}
        self.runner = Mock()
        self.queue = PromotionQueue(self.path, self.catalog, self.runner)
        self.addCleanup(lambda: self.queue.close())

    def test_success_removes_job_and_uses_existing_cli(self):
        self.queue.discover()
        self.assertTrue(self.queue.process_one(100))
        self.runner.assert_called_once_with(self.ids[0])
        with patch.object(promotion.subprocess, "run") as run:
            run_promotion(self.ids[1])
        self.assertEqual(run.call_args.args[0], ["map-platform", "promote-catalog-map", self.ids[1]])
        self.assertEqual(run.call_args.kwargs["timeout"], JOB_TIMEOUT)
        self.assertTrue(run.call_args.kwargs["check"])
        self.assertEqual(run.call_args.kwargs["stderr"], subprocess.DEVNULL)

    def test_failure_backoff_survives_discovery_restart_and_does_not_starve(self):
        self.queue.discover()
        self.runner.side_effect = RuntimeError("secret URL must not be logged")
        with self.assertLogs("automatic_promotion") as logs:
            self.queue.process_one(100)
        self.assertNotIn("secret URL", " ".join(logs.output))
        self.queue.close()
        self.queue = PromotionQueue(self.path, self.catalog, self.runner)
        self.queue.discover()
        row = self.queue.db.execute("SELECT attempts, next_attempt FROM jobs WHERE id=?", (self.ids[0],)).fetchone()
        self.assertEqual(row[0], 1)
        self.assertAlmostEqual(row[1], 160, delta=1)
        self.runner.side_effect = None
        self.queue.process_one(101)
        self.assertEqual(self.runner.call_args.args, (self.ids[1],))
        self.assertFalse(self.queue.process_one(102))
        self.assertTrue(self.queue.process_one(161))

    def test_invalid_pages_do_not_change_queue_or_cursor(self):
        for page in (
            {"mapEntryIds": list(reversed(self.ids)), "nextCursor": None},
            {"mapEntryIds": [self.ids[0]] * 2, "nextCursor": None},
            {"mapEntryIds": ["--help"], "nextCursor": None},
            {"mapEntryIds": [], "nextCursor": self.ids[0]},
        ):
            self.catalog._request.return_value = page
            with self.assertRaises(ValueError):
                self.queue.discover()
        self.assertEqual(self.queue.db.execute("SELECT COUNT(*) FROM jobs").fetchone()[0], 0)

    def test_development_credentials_rejected(self):
        with self.assertRaises(ValueError):
            PromotionQueue(self.path, Mock(channel="development"))

    def test_cursor_persists_and_wraps_to_discover_older_ids(self):
        ids = ["map_v1_" + f"{number:043d}" for number in range(50)]
        self.catalog._request.return_value = {"mapEntryIds": ids, "nextCursor": ids[-1]}
        self.queue.discover()
        self.queue.close()
        self.queue = PromotionQueue(self.path, self.catalog, self.runner)
        self.catalog._request.return_value = {"mapEntryIds": [], "nextCursor": None}
        self.queue.discover()
        self.assertEqual(self.catalog._request.call_args.args[1]["cursor"], ids[-1])
        self.queue.discover()
        self.assertIsNone(self.catalog._request.call_args.args[1]["cursor"])

    def test_crash_reservation_and_lost_success_are_recoverable(self):
        self.queue.discover()
        self.runner.side_effect = KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt):
            self.queue.process_one(100)
        row = self.queue.db.execute("SELECT next_attempt FROM jobs WHERE id=?", (self.ids[0],)).fetchone()
        self.assertEqual(row[0], 100 + JOB_TIMEOUT + 60)
        # An idempotent already-production replay is successful on the next try.
        self.runner.side_effect = None
        self.queue.process_one(101)
        self.queue.process_one(row[0])
        self.assertEqual(self.queue.db.execute("SELECT COUNT(*) FROM jobs").fetchone()[0], 0)


if __name__ == "__main__":
    unittest.main()
