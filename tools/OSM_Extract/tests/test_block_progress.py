import io
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from block_progress import BlockProgressReporter


class BlockProgressReporterTests(unittest.TestCase):
    def test_reports_exact_progress_for_each_processed_block(self):
        output = io.StringIO()
        progress = BlockProgressReporter(3, stream=output)

        visited = []
        for branch in progress.track(["empty", "skipped", "rendered"]):
            visited.append(branch)
            if branch in {"empty", "skipped"}:
                continue

        self.assertEqual(visited, ["empty", "skipped", "rendered"])
        self.assertEqual(progress.completed, 3)
        self.assertEqual(
            [line for line in output.getvalue().splitlines() if line.startswith("MAP_PROGRESS:")],
            [
                "MAP_PROGRESS:0:3",
                "MAP_PROGRESS:1:3",
                "MAP_PROGRESS:2:3",
                "MAP_PROGRESS:3:3",
            ],
        )

    def test_rejects_invalid_totals_and_overflow(self):
        with self.assertRaises(ValueError):
            BlockProgressReporter(0)

        progress = BlockProgressReporter(1, stream=io.StringIO())
        progress.advance()
        with self.assertRaises(ValueError):
            progress.advance()


if __name__ == "__main__":
    unittest.main()
