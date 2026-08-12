from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path

from firmware_runtime_review_summary import create_summary
from firmware_runtime_publication import TARGETS


class FirmwareRuntimeReviewSummaryTests(unittest.TestCase):
    def test_summary_binds_both_targets_evidence_licenses_and_assets(self) -> None:
        project = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            baseline_lock = root / "baseline-lock.json"
            candidate_lock = root / "candidate-lock.json"
            source_lock = project / "tools/firmware-runtime/lock-v1.json"
            shutil.copyfile(source_lock, baseline_lock)
            shutil.copyfile(source_lock, candidate_lock)

            baseline_licenses = root / "baseline-licenses"
            baseline_licenses.mkdir()
            candidates = root / "candidates"
            validation = root / "validation"
            license_value = {
                "schema": 1,
                "wheels": [
                    {"name": "example", "version": "1.0", "license": "MIT"}
                ],
            }
            for target in TARGETS:
                (baseline_licenses / f"licenses-{target}.json").write_text(
                    json.dumps(license_value), encoding="utf-8"
                )
                candidate = candidates / f"firmware-runtime-candidate-{target}"
                candidate.mkdir(parents=True)
                (candidate / "inputs.json").write_text('{"schema":1}\n', encoding="utf-8")
                for prefix, value in (
                    ("contract", {"target": target}),
                    ("evidence", {"target": target, "runner": "native"}),
                    ("licenses", license_value),
                    ("offline-replay", {"target": target, "offline": True}),
                ):
                    (candidate / f"{prefix}-{target}.json").write_text(
                        json.dumps(value), encoding="utf-8"
                    )
                (candidate / f"open-bike-firmware-runtime-{target}.tar.gz").write_bytes(
                    target.encode("utf-8")
                )
                validation_dir = validation / f"firmware-build-validation-{target}"
                validation_dir.mkdir(parents=True)
                (validation_dir / "provenance.txt").write_text(
                    f"runtimeTarget={target}\n", encoding="utf-8"
                )

            summary = create_summary(
                project,
                baseline_lock,
                candidate_lock,
                baseline_licenses,
                candidates,
                validation,
            )

            self.assertEqual(11, len(summary["proposedAssets"]))
            self.assertEqual([], summary["licenses"]["changed"])
            self.assertEqual(set(TARGETS), set(summary["targetChanges"]))
            self.assertTrue(summary["reproducibility"]["nativeCandidateAEqualsB"])


if __name__ == "__main__":
    unittest.main()
