import unittest

from map_platform.building_resource_model import summarize_resource_observations


class BuildingResourceModelTests(unittest.TestCase):
    def test_summary_is_grouped_by_stable_capability_and_conservative(self):
        observations = [
            {
                "resourceModelVersion": "model-v1",
                "workerCapability": {
                    "schemaVersion": 1,
                    "workerClass": "large",
                    "resourcePool": "coolify",
                    "identitySha256": "a" * 64,
                },
                "predictedPeakMemoryBytes": 100,
                "actualPeakMemoryBytes": 125,
            },
            {
                "resourceModelVersion": "model-v1",
                "workerCapability": {
                    "schemaVersion": 1,
                    "workerClass": "large",
                    "resourcePool": "coolify",
                    "identitySha256": "a" * 64,
                },
                "predictedPeakMemoryBytes": 200,
                "actualPeakMemoryBytes": 150,
            },
        ]

        summary = summarize_resource_observations(
            observations,
            minimum_observations=3,
        )

        self.assertEqual(summary["observationCount"], 2)
        group = summary["groups"][0]
        self.assertEqual(group["status"], "insufficient_observations")
        self.assertEqual(group["workerCapabilityIdentitySha256"], "a" * 64)
        self.assertEqual(group["p95ActualPeakMemoryBytes"], 150)
        self.assertEqual(group["p95PredictedPeakMemoryBytes"], 200)
        self.assertEqual(group["underpredictionCount"], 1)
        self.assertEqual(group["conservativeMemoryMultiplier"], 1.0)

    def test_invalid_observations_are_excluded(self):
        summary = summarize_resource_observations(
            [
                {
                    "resourceModelVersion": "model-v1",
                    "workerCapability": {},
                    "predictedPeakMemoryBytes": -1,
                    "actualPeakMemoryBytes": 10,
                }
            ]
        )

        self.assertEqual(summary["observationCount"], 0)
        self.assertEqual(summary["groups"], [])


if __name__ == "__main__":
    unittest.main()
