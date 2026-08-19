import unittest

from map_platform.building_artifact_identity import (
    partition_invariant_artifact_identity,
    validate_partition_invariant_artifact_identity,
)


class BuildingArtifactIdentityTests(unittest.TestCase):
    def identity(self, receipt="f" * 64):
        return partition_invariant_artifact_identity(
            global_plan_sha256="a" * 64,
            source_snapshot_sha256="b" * 64,
            source_index_database_sha256="c" * 64,
            calibration_manifest_sha256="d" * 64,
            cache_identity_sha256="e" * 64,
            receipt_set_sha256=receipt,
        )

    def test_identity_excludes_partition_layout_and_validates_canonical_digest(self):
        first = self.identity()
        second = self.identity()
        self.assertEqual(first, second)
        self.assertEqual(
            validate_partition_invariant_artifact_identity(first),
            first,
        )

    def test_receipt_set_changes_identity(self):
        self.assertNotEqual(self.identity(), self.identity("0" * 64))

    def test_tampering_fails_closed(self):
        value = self.identity()
        value["cacheIdentitySha256"] = "0" * 64
        with self.assertRaises(ValueError):
            validate_partition_invariant_artifact_identity(value)


if __name__ == "__main__":
    unittest.main()

