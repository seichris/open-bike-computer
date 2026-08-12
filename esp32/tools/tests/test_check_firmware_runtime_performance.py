from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from check_firmware_runtime_performance import check_performance
from firmware_runtime import FirmwareRuntimeError
from refresh_firmware_runtime import _canonical


TARGET = "linux-x86_64-cp313"
LOCK = "firmware-runtime-2026-08-10-1"


class FirmwareRuntimePerformanceTests(unittest.TestCase):
    def make_baseline(self, root: Path, baseline_ms: int = 1000) -> Path:
        path = root / "baseline.json"
        path.write_bytes(
            _canonical(
                {
                    "schema": 1,
                    "lockSetId": LOCK,
                    "targets": {
                        TARGET: {
                            "baselineSource": "unit test",
                            "maxRegressionPercent": 20,
                            "runner": "ubuntu-24.04",
                            "sampleCount": 5,
                            "warmHandoffMedianMs": baseline_ms,
                        }
                    },
                }
            )
        )
        return path

    def make_samples(self, root: Path, values: list[int]) -> Path:
        path = root / "samples.log"
        path.write_text(
            "".join(
                f"FIRMWARE_RUNTIME_CHECK schema=1 target={TARGET} lockSetId={LOCK} "
                f"bootstrapMs={value} sharedMs=200 hydrationMs=300 verificationMs=100\n"
                for value in values
            ),
            encoding="utf-8",
        )
        return path

    def test_five_sample_median_passes_at_twenty_percent_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            result = check_performance(
                self.make_baseline(root),
                self.make_samples(root, [900, 1100, 1200, 1199, 800]),
                TARGET,
            )
            self.assertEqual(1100, result["medians"]["bootstrapMs"])
            self.assertEqual(1200, result["maximumMs"])

    def test_regression_wrong_count_and_identity_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            baseline = self.make_baseline(root)
            with self.assertRaisesRegex(FirmwareRuntimeError, "regressed"):
                check_performance(
                    baseline,
                    self.make_samples(root, [1300, 1301, 1302, 1303, 1304]),
                    TARGET,
                )
            with self.assertRaisesRegex(FirmwareRuntimeError, "exactly five"):
                check_performance(
                    baseline,
                    self.make_samples(root, [900, 901, 902, 903]),
                    TARGET,
                )
            samples = self.make_samples(root, [900, 901, 902, 903, 904])
            samples.write_text(
                samples.read_text(encoding="utf-8").replace(LOCK, "other-lock"),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(FirmwareRuntimeError, "identity changed"):
                check_performance(baseline, samples, TARGET)


if __name__ == "__main__":
    unittest.main()
