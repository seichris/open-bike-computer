import json
from pathlib import Path
import unittest

from map_platform.building_scope import (
    BUILDING_MAX_RELATION_OBJECTS_PER_JOB,
    BUILDING_MAX_SOURCE_AREA_M2,
)


class Phase0BenchmarkContractTests(unittest.TestCase):
    def test_retained_evidence_keeps_production_limits_fail_closed(self):
        fixture = json.loads(
            (
                Path(__file__).parent
                / "fixtures"
                / "shanghai_phase0_benchmarks.json"
            ).read_text()
        )
        self.assertEqual(
            fixture["productionPolicy"]["sourceAreaHardM2"],
            BUILDING_MAX_SOURCE_AREA_M2,
        )
        self.assertEqual(
            fixture["productionPolicy"]["closureObjectsHard"],
            BUILDING_MAX_RELATION_OBJECTS_PER_JOB,
        )
        self.assertIsNone(fixture["productionPolicy"]["workerMemoryLimitBytes"])
        success = next(
            item
            for item in fixture["observations"]
            if item["jobId"] == "e79c891c12d44ac882f8"
        )
        self.assertGreater(success["workerCgroupPeakBytes"], 4_000_000_000)
        self.assertIsNone(success["workerCgroupMemoryLimitBytes"])

    def test_large_request_is_global_admission_evidence_not_relation_evidence(self):
        fixture = json.loads(
            (
                Path(__file__).parent
                / "fixtures"
                / "shanghai_phase0_benchmarks.json"
            ).read_text()
        )
        large = next(
            item
            for item in fixture["observations"]
            if item["jobId"] == "707d717d591145c6a731"
        )
        self.assertGreater(
            large["candidateOutputBlockCount"],
            large["maximumMonolithicOutputBlocks"],
        )
        self.assertFalse(large["sourceExtractionStarted"])
        self.assertFalse(large["closureMeasured"])


if __name__ == "__main__":
    unittest.main()
