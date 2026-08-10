from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
WORKFLOW_ROOT = REPO_ROOT / ".github" / "workflows"
CORE_FIRMWARE_TARGETS = {
    "WAVESHARE_AMOLED_175",
    "WAVESHARE_AMOLED_175_PRODUCTION",
    "WAVESHARE_AMOLED_206",
    "WAVESHARE_AMOLED_206_PRODUCTION",
}
DIAGNOSTIC_FIRMWARE_TARGETS = {
    "WAVESHARE_AMOLED_175_MAPIO_DIAGNOSTICS",
    "WAVESHARE_AMOLED_175_POWER_METRICS",
    "WAVESHARE_AMOLED_175_LIGHT_SLEEP",
    "WAVESHARE_AMOLED_206_MAPIO_DIAGNOSTICS",
    "WAVESHARE_AMOLED_206_DISPLAY_TEST",
    "WAVESHARE_AMOLED_206_POWER_METRICS",
    "WAVESHARE_AMOLED_206_LIGHT_SLEEP",
}


def workflow_source(filename: str) -> str:
    return (WORKFLOW_ROOT / filename).read_text(encoding="utf-8")


def matrix_targets(source: str) -> set[str]:
    return set(
        re.findall(r"^\s+- (WAVESHARE_AMOLED_[A-Z0-9_]+)$", source, re.MULTILINE)
    )


class WorkflowPolicyTests(unittest.TestCase):
    def test_default_and_diagnostic_firmware_matrices_stay_separate(self) -> None:
        default_targets = matrix_targets(workflow_source("ci.yml"))
        diagnostic_targets = matrix_targets(
            workflow_source("firmware-diagnostics.yml")
        )

        self.assertEqual(CORE_FIRMWARE_TARGETS, default_targets)
        self.assertEqual(DIAGNOSTIC_FIRMWARE_TARGETS, diagnostic_targets)

    def test_feature_branch_pushes_do_not_duplicate_pull_request_ci(self) -> None:
        general_ci = workflow_source("ci.yml")

        self.assertIn("  push:\n    branches:\n      - main\n", general_ci)
        self.assertIn("  pull_request:\n", general_ci)
        self.assertIn("  cancel-in-progress: true\n", general_ci)

    def test_every_firmware_builder_reuses_verified_downloads(self) -> None:
        for workflow in (
            "ci.yml",
            "firmware-diagnostics.yml",
            "firmware-release.yml",
            "speaker-firmware.yml",
        ):
            with self.subTest(workflow=workflow):
                source = workflow_source(workflow)
                self.assertIn("uses: actions/cache@v6", source)
                self.assertIn(".pio/open-bike-build/downloads", source)


if __name__ == "__main__":
    unittest.main()
