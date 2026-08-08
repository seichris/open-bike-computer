import hashlib
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from map_platform.models import Bounds, SourceRegion
from map_platform.source_cache import (
    SourceCache,
    SourceCacheError,
    default_backend_data_root,
)


class SourceCacheTests(unittest.TestCase):
    def test_default_data_root_reuses_pre_relocation_local_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            relocated = root / "map-platform" / "backend" / "data"
            relocated.mkdir(parents=True)
            (relocated / ".gitkeep").touch()
            (relocated / ".DS_Store").touch()
            legacy_jobs = root / "backend" / "data" / "jobs"
            legacy_jobs.mkdir(parents=True)
            (legacy_jobs / "existing.json").write_text("{}")

            self.assertEqual(
                default_backend_data_root(root),
                root / "backend" / "data",
            )
            self.assertEqual(
                SourceCache(root).data_root,
                root / "backend" / "data",
            )

    def test_default_data_root_ignores_legacy_finder_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            legacy = root / "backend" / "data"
            legacy.mkdir(parents=True)
            (legacy / ".DS_Store").touch()

            self.assertEqual(
                default_backend_data_root(root),
                root / "map-platform" / "backend" / "data",
            )

    def test_default_data_root_rejects_ambiguous_local_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            legacy_jobs = root / "backend" / "data" / "jobs"
            legacy_jobs.mkdir(parents=True)
            (legacy_jobs / "existing.json").write_text("{}")
            relocated_jobs = root / "map-platform" / "backend" / "data" / "jobs"
            relocated_jobs.mkdir(parents=True)
            (relocated_jobs / "new.json").write_text("{}")

            with self.assertRaisesRegex(
                RuntimeError,
                "set MAP_PLATFORM_DATA_ROOT explicitly",
            ):
                default_backend_data_root(root)

    def test_maps_legacy_backend_data_paths_to_the_data_volume(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "remote.osm.pbf"
            source.write_bytes(b"pbf-data")
            region = SourceRegion(
                id="legacy-region",
                provider="test",
                name="Legacy",
                url=source.as_uri(),
                bounds=Bounds(0, 0, 1, 1),
                local_path="backend/data/source-pbf/legacy.osm.pbf",
            )

            cache = SourceCache(
                root / "repo",
                root / "cache.json",
                data_root=root / "data",
            )

            self.assertEqual(
                cache.ensure(region).path,
                root / "data" / "source-pbf" / "legacy.osm.pbf",
            )

    def test_downloads_file_url_into_data_root_and_records_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "remote.osm.pbf"
            source.write_bytes(b"pbf-data")
            digest = hashlib.sha256(b"pbf-data").hexdigest()
            region = SourceRegion(
                id="test-region",
                provider="test",
                name="Test",
                url=source.as_uri(),
                bounds=Bounds(0, 0, 1, 1),
                local_path="map-platform/backend/data/source-pbf/test.osm.pbf",
                checksum=digest,
            )

            cache = SourceCache(root / "repo", root / "cache.json", data_root=root / "data")
            cached = cache.ensure(region)

            self.assertEqual(cached.path, root / "data" / "source-pbf" / "test.osm.pbf")
            self.assertEqual(cached.sha256, digest)
            self.assertEqual(cache.metadata()["sources"]["test-region"]["sha256"], digest)

    def test_rejects_checksum_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "remote.osm.pbf"
            source.write_bytes(b"pbf-data")
            region = SourceRegion(
                id="test-region",
                provider="test",
                name="Test",
                url=source.as_uri(),
                bounds=Bounds(0, 0, 1, 1),
                local_path="map-platform/backend/data/source-pbf/test.osm.pbf",
                checksum="0" * 64,
            )

            cache = SourceCache(root / "repo", root / "cache.json", data_root=root / "data")

            with self.assertRaises(SourceCacheError):
                cache.ensure(region)

    def test_redownloads_existing_file_when_checksum_mismatches(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "remote.osm.pbf"
            source.write_bytes(b"fresh-pbf-data")
            digest = hashlib.sha256(b"fresh-pbf-data").hexdigest()
            cached_path = root / "data" / "source-pbf" / "test.osm.pbf"
            cached_path.parent.mkdir(parents=True)
            cached_path.write_bytes(b"stale-data")
            region = SourceRegion(
                id="test-region",
                provider="test",
                name="Test",
                url=source.as_uri(),
                bounds=Bounds(0, 0, 1, 1),
                local_path="map-platform/backend/data/source-pbf/test.osm.pbf",
                checksum=digest,
            )

            cache = SourceCache(root / "repo", root / "cache.json", data_root=root / "data")
            cached = cache.ensure(region)

            self.assertEqual(cached.sha256, digest)
            self.assertEqual(cached_path.read_bytes(), b"fresh-pbf-data")

    def test_removes_stale_source_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "remote.osm.pbf"
            source.write_bytes(b"pbf-data")
            digest = hashlib.sha256(b"pbf-data").hexdigest()
            cached_path = root / "data" / "source-pbf" / "test.osm.pbf"
            cached_path.parent.mkdir(parents=True)
            cached_path.with_suffix(cached_path.suffix + ".lock").write_text("dead-worker")
            region = SourceRegion(
                id="test-region",
                provider="test",
                name="Test",
                url=source.as_uri(),
                bounds=Bounds(0, 0, 1, 1),
                local_path="map-platform/backend/data/source-pbf/test.osm.pbf",
                checksum=digest,
            )

            cache = SourceCache(root / "repo", root / "cache.json", data_root=root / "data", lock_stale_seconds=-1)
            cached = cache.ensure(region)

            self.assertEqual(cached.sha256, digest)

    def test_active_verified_lease_cannot_be_stolen_as_stale(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            remote = root / "remote.osm.pbf"
            remote.write_bytes(b"replacement")
            cached_path = root / "data" / "source-pbf" / "test.osm.pbf"
            cached_path.parent.mkdir(parents=True)
            cached_path.write_bytes(b"leased")
            region = SourceRegion(
                id="test-region",
                provider="test",
                name="Test",
                url=remote.as_uri(),
                bounds=Bounds(0, 0, 1, 1),
                local_path="map-platform/backend/data/source-pbf/test.osm.pbf",
            )
            first = SourceCache(
                root / "repo",
                root / "cache-a.json",
                data_root=root / "data",
                lock_stale_seconds=-1,
            )
            second = SourceCache(
                root / "repo",
                root / "cache-b.json",
                data_root=root / "data",
                lock_stale_seconds=-1,
            )
            refresh_finished = threading.Event()

            def refresh():
                second.ensure(region, force=True)
                refresh_finished.set()

            with first.verified_lease(region):
                worker = threading.Thread(target=refresh)
                worker.start()
                time.sleep(0.2)
                self.assertFalse(refresh_finished.is_set())
                self.assertEqual(cached_path.read_bytes(), b"leased")
            worker.join(timeout=2)

            self.assertTrue(refresh_finished.is_set())
            self.assertEqual(cached_path.read_bytes(), b"replacement")

    def test_verified_leases_overlap_for_the_same_cached_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cached_path = root / "data" / "source-pbf" / "test.osm.pbf"
            cached_path.parent.mkdir(parents=True)
            cached_path.write_bytes(b"leased")
            region = SourceRegion(
                id="test-region",
                provider="test",
                name="Test",
                url="https://example.invalid/test.osm.pbf",
                bounds=Bounds(0, 0, 1, 1),
                local_path="map-platform/backend/data/source-pbf/test.osm.pbf",
            )
            first = SourceCache(root / "repo", root / "a.json", data_root=root / "data")
            second = SourceCache(root / "repo", root / "b.json", data_root=root / "data")
            acquired = threading.Event()

            def take_shared_lease():
                with second.verified_lease(region):
                    acquired.set()

            with first.verified_lease(region):
                worker = threading.Thread(target=take_shared_lease)
                worker.start()
                self.assertTrue(acquired.wait(timeout=1))
            worker.join(timeout=2)

            self.assertFalse(worker.is_alive())

    def test_waiting_exclusive_refresh_can_be_cancelled(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cached_path = root / "data" / "source-pbf" / "test.osm.pbf"
            cached_path.parent.mkdir(parents=True)
            cached_path.write_bytes(b"leased")
            region = SourceRegion(
                id="test-region",
                provider="test",
                name="Test",
                url="https://example.invalid/test.osm.pbf",
                bounds=Bounds(0, 0, 1, 1),
                local_path="map-platform/backend/data/source-pbf/test.osm.pbf",
            )
            first = SourceCache(root / "repo", root / "a.json", data_root=root / "data")
            second = SourceCache(root / "repo", root / "b.json", data_root=root / "data")
            cancelled = threading.Event()
            observed = []

            def refresh():
                try:
                    second.ensure(
                        region,
                        force=True,
                        cancellation_check=cancelled.is_set,
                    )
                except SourceCacheError as exc:
                    observed.append(str(exc))

            with first.verified_lease(region):
                worker = threading.Thread(target=refresh)
                worker.start()
                time.sleep(0.2)
                cancelled.set()
                worker.join(timeout=2)

            self.assertFalse(worker.is_alive())
            self.assertEqual(observed, ["source cache wait was cancelled"])

    def test_download_cancellation_removes_partial_snapshot(self):
        class CancellingResponse:
            def __init__(self, cancelled):
                self.cancelled = cancelled

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self, _size):
                self.cancelled.set()
                return b"partial"

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cancelled = threading.Event()
            region = SourceRegion(
                id="test-region",
                provider="test",
                name="Test",
                url="https://example.invalid/test.osm.pbf",
                bounds=Bounds(0, 0, 1, 1),
                local_path="map-platform/backend/data/source-pbf/test.osm.pbf",
            )
            cache = SourceCache(root / "repo", root / "cache.json", data_root=root / "data")
            with patch(
                "map_platform.source_cache.urllib.request.urlopen",
                return_value=CancellingResponse(cancelled),
            ), self.assertRaisesRegex(SourceCacheError, "operation was cancelled"):
                cache.ensure(region, cancellation_check=cancelled.is_set)

            target = root / "data" / "source-pbf" / "test.osm.pbf"
            self.assertFalse(target.exists())
            self.assertFalse(target.with_suffix(target.suffix + ".tmp").exists())

    def test_hash_cancellation_preserves_existing_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cached_path = root / "data" / "source-pbf" / "test.osm.pbf"
            cached_path.parent.mkdir(parents=True)
            cached_path.write_bytes(b"stable")
            region = SourceRegion(
                id="test-region",
                provider="test",
                name="Test",
                url="https://example.invalid/test.osm.pbf",
                bounds=Bounds(0, 0, 1, 1),
                local_path="map-platform/backend/data/source-pbf/test.osm.pbf",
            )
            cache = SourceCache(root / "repo", root / "cache.json", data_root=root / "data")
            checks = iter((False, True))

            with self.assertRaisesRegex(SourceCacheError, "operation was cancelled"):
                cache.ensure(region, cancellation_check=lambda: next(checks, True))

            self.assertEqual(cached_path.read_bytes(), b"stable")


if __name__ == "__main__":
    unittest.main()
