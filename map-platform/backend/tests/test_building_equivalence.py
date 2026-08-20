import unittest
import hashlib
from pathlib import Path
import tempfile
import zipfile

from map_platform.building_equivalence import (
    BuildingEquivalenceError,
    build_equivalence_record_from_zip,
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
    def test_published_zip_materializes_a_byte_level_equivalence_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "map.zip"
            with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as value:
                value.writestr("manifest.json", b"{}")
                value.writestr("VECTMAP/map/0/0.fmb", b"FMB4-reference")
                value.writestr("VECTMAP/map/0/1.fmb", b"FMB4-candidate")

            record_from_zip = build_equivalence_record_from_zip(archive)
            expected = record()
            expected["fmbSha256ByPath"] = {
                "VECTMAP/map/0/0.fmb": hashlib.sha256(
                    b"FMB4-reference"
                ).hexdigest(),
                "VECTMAP/map/0/1.fmb": hashlib.sha256(
                    b"FMB4-candidate"
                ).hexdigest(),
            }
            expected["artifacts"] = record_from_zip["artifacts"]

            self.assertEqual(
                validate_partition_equivalence(record_from_zip, expected)["status"],
                "pass",
            )

    def test_zip_without_fmb_entries_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "labels-only.zip"
            with zipfile.ZipFile(archive, "w") as value:
                value.writestr("manifest.json", b"{}")
            with self.assertRaisesRegex(BuildingEquivalenceError, "no FMB"):
                build_equivalence_record_from_zip(archive)

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
