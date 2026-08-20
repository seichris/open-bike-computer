import unittest

from map_platform.building_storage_admission import (
    BuildingStorageAdmissionError,
    building_storage_admission,
)


class BuildingStorageAdmissionTests(unittest.TestCase):
    def test_admission_accounts_for_cache_source_work_and_reserve(self):
        report = building_storage_admission(
            estimated_archive_bytes=100,
            source_bytes=200,
            free_bytes=1_001,
            cache_max_bytes=200,
            attempt_max_bytes=900,
            reserve_bytes=100,
        )

        self.assertEqual(report["predictedCacheBytes"], 200)
        self.assertEqual(report["predictedAttemptBytes"], 900)
        self.assertEqual(report["requiredFreeBytes"], 1_000)
        self.assertTrue(report["admitted"])

    def test_cache_retention_quota_rejects_before_execution(self):
        with self.assertRaisesRegex(
            BuildingStorageAdmissionError,
            "retention quota",
        ):
            building_storage_admission(
                estimated_archive_bytes=101,
                source_bytes=1,
                free_bytes=10_000,
                cache_max_bytes=200,
                attempt_max_bytes=10_000,
                reserve_bytes=0,
            )

    def test_live_disk_headroom_rejects_before_execution(self):
        with self.assertRaisesRegex(
            BuildingStorageAdmissionError,
            "disk headroom",
        ):
            building_storage_admission(
                estimated_archive_bytes=100,
                source_bytes=200,
                free_bytes=999,
                cache_max_bytes=200,
                attempt_max_bytes=900,
                reserve_bytes=100,
            )


if __name__ == "__main__":
    unittest.main()
