import unittest

from map_platform.building_resource_model import (
    CALIBRATED_RESOURCE_MODEL_VERSION,
    apply_calibrated_memory_prediction,
    summarize_resource_observations,
    train_resource_model,
)


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

    def test_training_is_reviewable_and_requires_sample_floor(self):
        capability = {
            "schemaVersion": 1,
            "workerClass": "large",
            "resourcePool": "coolify",
            "identitySha256": "a" * 64,
        }
        observations = [
            {
                "resourceModelVersion": "model-v1",
                "workerCapability": capability,
                "predictedPeakMemoryBytes": 100,
                "actualPeakMemoryBytes": 150,
            }
            for _ in range(8)
        ]

        model = train_resource_model(
            observations,
            minimum_observations=8,
            safety_margin=1.1,
        )

        self.assertEqual(model["modelVersion"], CALIBRATED_RESOURCE_MODEL_VERSION)
        self.assertEqual(model["observationCount"], 8)
        group = model["groups"][0]
        self.assertEqual(group["status"], "trained")
        self.assertEqual(group["rawMemoryMultiplier"], 1.5)
        self.assertEqual(group["effectiveMemoryMultiplier"], 1.65)

        prediction = apply_calibrated_memory_prediction(
            1_000,
            worker_capability=capability,
            calibrated_model=model,
            resource_model_version="model-v1",
        )
        self.assertEqual(prediction, 1_650)

    def test_calibrated_model_fails_closed_for_unknown_capability_or_insufficient_data(self):
        capability = {
            "schemaVersion": 1,
            "workerClass": "large",
            "resourcePool": "coolify",
            "identitySha256": "a" * 64,
        }
        model = train_resource_model(
            [
                {
                    "resourceModelVersion": "model-v1",
                    "workerCapability": capability,
                    "predictedPeakMemoryBytes": 100,
                    "actualPeakMemoryBytes": 200,
                }
            ],
            minimum_observations=8,
        )
        self.assertEqual(model["groups"][0]["status"], "insufficient_observations")
        self.assertEqual(
            apply_calibrated_memory_prediction(
                1_000,
                worker_capability={**capability, "identitySha256": "b" * 64},
                calibrated_model=model,
            ),
            1_000,
        )


if __name__ == "__main__":
    unittest.main()
