import unittest

from map_platform.building_equivalence import (
    BuildingEquivalenceError,
    validate_partition_equivalence,
)


def record(block_hash="1"):
    return {
        "fmbSha256ByPath": {
            "VECTMAP/map/0/0.fmb": block_hash * 64,
            "VECTMAP/map/0/1.fmb": "2" * 64,
        },
        "artifacts": [
            {
                "format": "zip-stored-v1",
                "bytes": 128,
                "sha256": "3" * 64,
            },
            {
                "format": "bike-map-stream-v1",
                "bytes": 256,
                "sha256": "4" * 64,
            },
        ],
        "taskIds": ["ignored"],
    }


class BuildingEquivalenceTests(unittest.TestCase):
    def test_task_layout_and_worker_metadata_are_ignored(self):
        reference = record()
        candidate = record()
        candidate["taskIds"] = ["different", "partitioned"]
        candidate["timings"] = {"wallMilliseconds": 42}

        report = validate_partition_equivalence(reference, candidate)

        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["blockCount"], 2)
        self.assertRegex(report["fmbSha256ByPathDigest"], r"^[0-9a-f]{64}$")

    def test_changed_block_bytes_fail_closed(self):
        candidate = record()
        candidate["fmbSha256ByPath"]["VECTMAP/map/0/1.fmb"] = "9" * 64

        with self.assertRaisesRegex(BuildingEquivalenceError, "changed blocks"):
            validate_partition_equivalence(record(), candidate)

    def test_changed_artifact_payload_fails_closed(self):
        candidate = record()
        candidate["artifacts"][0]["sha256"] = "8" * 64

        with self.assertRaisesRegex(BuildingEquivalenceError, "artifact payload"):
            validate_partition_equivalence(record(), candidate)


if __name__ == "__main__":
    unittest.main()

