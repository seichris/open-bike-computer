import fcntl
import os
from pathlib import Path
import tempfile
import unittest

from map_platform.building_cache_maintenance import prune_building_block_cache


class BuildingBlockCacheMaintenanceTests(unittest.TestCase):
    def _namespace(self, root, source, identity, *, age_seconds, size):
        namespace = (
            root
            / "building-block-v1"
            / source
            / ("2" * 64)
            / identity
        )
        namespace.mkdir(parents=True)
        (namespace / "section.bin").write_bytes(b"x" * size)
        marker = namespace / ".last-access"
        marker.touch()
        timestamp = 2_000_000_000 - age_seconds
        os.utime(marker, (timestamp, timestamp))
        return namespace

    def test_prunes_expired_namespaces_and_retains_recent_ones(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            expired = self._namespace(
                root,
                "1" * 64,
                "3" * 64,
                age_seconds=20 * 86_400,
                size=100,
            )
            recent = self._namespace(
                root,
                "4" * 64,
                "5" * 64,
                age_seconds=2 * 86_400,
                size=200,
            )

            result = prune_building_block_cache(
                root,
                older_than_days=14,
                max_bytes=10_000,
                max_items=10,
                now=2_000_000_000,
            )

            self.assertFalse(expired.exists())
            self.assertTrue(recent.exists())
            self.assertEqual(result["removedNamespaces"], 1)
            self.assertGreaterEqual(result["removedBytes"], 100)

    def test_size_cap_removes_oldest_namespace_first(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            oldest = self._namespace(
                root,
                "1" * 64,
                "3" * 64,
                age_seconds=5 * 86_400,
                size=200,
            )
            newest = self._namespace(
                root,
                "4" * 64,
                "5" * 64,
                age_seconds=1 * 86_400,
                size=200,
            )

            result = prune_building_block_cache(
                root,
                older_than_days=14,
                max_bytes=300,
                max_items=10,
                now=2_000_000_000,
            )

            self.assertFalse(oldest.exists())
            self.assertTrue(newest.exists())
            self.assertEqual(result["removedNamespaces"], 1)

    def test_active_namespace_lease_prevents_deletion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            namespace = self._namespace(
                root,
                "1" * 64,
                "3" * 64,
                age_seconds=20 * 86_400,
                size=100,
            )
            lease_path = namespace.parent / f".{namespace.name}.lease.lock"
            with lease_path.open("a+b") as lease:
                fcntl.flock(lease.fileno(), fcntl.LOCK_SH)
                result = prune_building_block_cache(
                    root,
                    older_than_days=14,
                    max_bytes=10_000,
                    max_items=10,
                    now=2_000_000_000,
                )

            self.assertTrue(namespace.exists())
            self.assertEqual(result["removedNamespaces"], 0)
            self.assertEqual(result["skippedLeasedNamespaces"], 1)

    def test_missing_cache_is_a_quiet_noop(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(
                prune_building_block_cache(Path(tmp)),
                {
                    "removedNamespaces": 0,
                    "removedBytes": 0,
                    "retainedBytes": 0,
                    "skippedLeasedNamespaces": 0,
                },
            )


if __name__ == "__main__":
    unittest.main()
