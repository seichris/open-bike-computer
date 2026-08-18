import json
import unittest
from pathlib import Path

from map_platform.building_benchmark import (
    BuildingBenchmarkError,
    REQUIRED_RUNS,
    validate_benchmark_evidence,
)


def fixture():
    return json.loads(
        (
            Path(__file__).parent / "fixtures" / "shanghai_24km2_scope.json"
        ).read_text(encoding="utf-8")
    )


def run_record(name):
    selected = name.startswith("selected")
    warm = name.endswith("Warm")
    preprocessing = None
    if selected:
        preprocessing = {
            "scope": {
                "requestedApproximateAreaM2": 23_840_377,
                "outputAreaM2": 100_663_296,
                "sourceAreaM2": 111_411_200,
                "sourceToOutputAreaBasisPoints": 11_068,
            },
            "calibration": {
                "calibrationKey": "a" * 64,
                "manifestSha256": "b" * 64,
                "entrySetSha256": "c" * 64,
            },
            "calibrationGenerationExecution": {
                "cacheOutcome": "hit" if warm else "rebuilt"
            },
        }
    return {
        "sourceIdentity": {
            "url": "https://download.geofabrik.de/pinned.osm.pbf",
            "publishedAt": "2026-08-06T22:46:41Z",
            "sha256": "1" * 64,
            "bytes": 25_000_000,
        },
        "workerIdentity": {
            "gitHead": "2" * 40,
            "workspaceContentSha256": "3" * 64,
            "workerFingerprintSha256": "4" * 64,
        },
        "peakResidentBytes": 100_000_000,
        "sourceQueryBytes": 2_000_000 if selected else 12_000_000,
        "sourceQueryObjects": {"nodes": 10, "ways": 5, "relations": 1},
        "timings": {
            "wallMilliseconds": 2_000 if selected else 4_000,
            "firstPreprocessingProgressMilliseconds": 20,
            "firstBlockProgressMilliseconds": 1_000 if selected else 3_000,
        },
        "fmbSha256ByPath": {"VECTMAP/map/1/2.fmb": "5" * 64},
        "artifactMetrics": {"buildingPreprocessing": preprocessing},
        "artifacts": [
            {
                "format": "bike-map-stream-v1",
                "manifestReceipt": "6" * 64,
                "signedManifestReceipt": "7" * 64,
            }
        ],
    }


class BuildingBenchmarkTests(unittest.TestCase):
    def test_complete_evidence_passes_and_records_proposals(self):
        runs = {name: run_record(name) for name in REQUIRED_RUNS}

        report = validate_benchmark_evidence(fixture(), runs)

        self.assertEqual(report["status"], "pass")
        self.assertEqual(
            report["measurements"]["sourceReductionBasisPoints"], 8616
        )
        self.assertEqual(
            report["cache"], {"coldOutcome": "rebuilt", "warmOutcome": "hit"}
        )
        self.assertEqual(
            report["proposedThresholds"][
                "minimumFirstBlockImprovementBasisPoints"
            ],
            5_000,
        )
        self.assertEqual(
            report["proposedThresholds"]["maximumSourceAreaM2"],
            1_200_000_000,
        )

    def test_selected_policy_may_differ_from_legacy_but_is_self_deterministic(self):
        runs = {name: run_record(name) for name in REQUIRED_RUNS}
        for name in ("selectedCold", "selectedWarm"):
            runs[name]["fmbSha256ByPath"]["VECTMAP/map/1/2.fmb"] = "8" * 64

        report = validate_benchmark_evidence(fixture(), runs)

        self.assertEqual(report["status"], "pass")

    def test_byte_mismatch_and_missing_memory_fail_closed(self):
        runs = {name: run_record(name) for name in REQUIRED_RUNS}
        runs["selectedWarm"]["fmbSha256ByPath"]["VECTMAP/map/1/2.fmb"] = "8" * 64
        with self.assertRaisesRegex(BuildingBenchmarkError, "selected FMB bytes changed"):
            validate_benchmark_evidence(fixture(), runs)
        runs = {name: run_record(name) for name in REQUIRED_RUNS}
        del runs["legacyCold"]["peakResidentBytes"]
        with self.assertRaisesRegex(BuildingBenchmarkError, "peak resident"):
            validate_benchmark_evidence(fixture(), runs)

    def test_cache_and_progress_thresholds_fail_closed(self):
        runs = {name: run_record(name) for name in REQUIRED_RUNS}
        runs["selectedWarm"]["artifactMetrics"]["buildingPreprocessing"][
            "calibrationGenerationExecution"
        ]["cacheOutcome"] = "rebuilt"
        with self.assertRaisesRegex(BuildingBenchmarkError, "did not hit cache"):
            validate_benchmark_evidence(fixture(), runs)
        runs = {name: run_record(name) for name in REQUIRED_RUNS}
        runs["selectedWarm"]["timings"]["firstBlockProgressMilliseconds"] = 1_501
        with self.assertRaisesRegex(BuildingBenchmarkError, "50 percent"):
            validate_benchmark_evidence(fixture(), runs)


if __name__ == "__main__":
    unittest.main()
