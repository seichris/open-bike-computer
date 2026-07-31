import hashlib
import tempfile
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
