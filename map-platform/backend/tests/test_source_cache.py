import hashlib
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from map_platform.models import Bounds, SourceRegion
from map_platform.source_cache import (
    SourceCache,
    SourceCacheCancelled,
    SourceCacheError,
    SourceCacheStorageError,
    default_backend_data_root,
)


class SourceCacheTests(unittest.TestCase):
    def test_cold_download_checks_disk_reserve_before_opening_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            region = SourceRegion(
                id="test-region",
                provider="test",
                name="Test",
                url="https://example.invalid/test.osm.pbf",
                bounds=Bounds(0, 0, 1, 1),
                local_path="map-platform/backend/data/source-pbf/test.osm.pbf",
            )
            cache = SourceCache(
                root / "repo",
                root / "cache.json",
                data_root=root / "data",
            )
            with patch(
                "map_platform.source_cache.shutil.disk_usage",
                return_value=SimpleNamespace(free=99),
            ), patch(
                "map_platform.source_cache.urllib.request.urlopen"
            ) as download, self.assertRaises(SourceCacheStorageError):
                cache.ensure(region, minimum_free_bytes=100)

            download.assert_not_called()

    def test_different_sources_cannot_spend_the_same_volume_reserve(self):
        download_bytes = 60
        minimum_free_bytes = 50
        initial_free_bytes = 150

        for declared_length in (True, False):
            with self.subTest(declared_length=declared_length), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                regions = {
                    name: SourceRegion(
                        id=f"region-{name}",
                        provider="test",
                        name=name.title(),
                        url=f"https://example.invalid/{name}.osm.pbf",
                        bounds=Bounds(0, 0, 1, 1),
                        local_path=(
                            "map-platform/backend/data/source-pbf/"
                            f"{name}.osm.pbf"
                        ),
                    )
                    for name in ("first", "second")
                }
                cache = SourceCache(
                    root / "repo",
                    root / "cache.json",
                    data_root=root / "data",
                )
                state_lock = threading.Lock()
                state = {
                    "free": initial_free_bytes,
                    "active": 0,
                    "max_active": 0,
                }
                capacity_calls = {"first": 0, "second": 0}
                chunk_checks = {
                    "first": threading.Event(),
                    "second": threading.Event(),
                }
                start = threading.Barrier(3)
                results = {}
                errors = {}

                class Response:
                    def __init__(self, name):
                        self.name = name
                        self.headers = (
                            {"Content-Length": str(download_bytes)}
                            if declared_length
                            else {}
                        )
                        self.delivered = False
                        self.charged = False

                    def __enter__(self):
                        with state_lock:
                            state["active"] += 1
                            state["max_active"] = max(
                                state["max_active"], state["active"]
                            )
                        return self

                    def __exit__(self, *_args):
                        with state_lock:
                            state["active"] -= 1
                        return False

                    def read(self, _size):
                        if not self.delivered:
                            self.delivered = True
                            return b"x" * download_bytes
                        if not self.charged:
                            with state_lock:
                                state["free"] -= download_bytes
                            self.charged = True
                        return b""

                def disk_usage(_directory):
                    name = threading.current_thread().name.removeprefix(
                        "source-"
                    )
                    with state_lock:
                        capacity_calls[name] += 1
                        call_number = capacity_calls[name]
                        free_bytes = state["free"]
                    chunk_call = 3 if declared_length else 2
                    if call_number == chunk_call:
                        chunk_checks[name].set()
                        other = "second" if name == "first" else "first"
                        chunk_checks[other].wait(timeout=0.25)
                    return SimpleNamespace(free=free_bytes)

                def urlopen(url, timeout):
                    self.assertEqual(timeout, 60)
                    name = Path(url).name.removesuffix(".osm.pbf")
                    return Response(name)

                def download(name):
                    start.wait(timeout=2)
                    try:
                        results[name] = cache.ensure(
                            regions[name],
                            minimum_free_bytes=minimum_free_bytes,
                        )
                    except Exception as exc:  # Captured for the main test thread.
                        errors[name] = exc

                workers = [
                    threading.Thread(
                        target=download,
                        args=(name,),
                        name=f"source-{name}",
                    )
                    for name in regions
                ]
                with patch(
                    "map_platform.source_cache.shutil.disk_usage",
                    side_effect=disk_usage,
                ), patch(
                    "map_platform.source_cache.urllib.request.urlopen",
                    side_effect=urlopen,
                ):
                    for worker in workers:
                        worker.start()
                    start.wait(timeout=2)
                    for worker in workers:
                        worker.join(timeout=3)

                self.assertTrue(all(not worker.is_alive() for worker in workers))
                self.assertEqual(len(results), 1)
                self.assertEqual(len(errors), 1)
                self.assertTrue(
                    all(isinstance(exc, SourceCacheStorageError) for exc in errors.values())
                )
                self.assertEqual(state["max_active"], 1)
                self.assertEqual(state["free"], initial_free_bytes - download_bytes)
                self.assertGreaterEqual(state["free"], minimum_free_bytes)
                targets = [cache._target_path(region) for region in regions.values()]
                self.assertEqual(sum(target.exists() for target in targets), 1)
                self.assertTrue(
                    all(
                        not target.with_suffix(target.suffix + ".tmp").exists()
                        for target in targets
                    )
                )

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

            target = root / "data" / "source-pbf" / "test.osm.pbf"
            self.assertFalse(target.exists())
            self.assertFalse(target.with_suffix(target.suffix + ".tmp").exists())

    def test_fresh_checksum_failure_preserves_stable_target_and_removes_tmp(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            remote = root / "remote.osm.pbf"
            remote.write_bytes(b"replacement")
            target = root / "data" / "source-pbf" / "test.osm.pbf"
            target.parent.mkdir(parents=True)
            target.write_bytes(b"stable")
            region = SourceRegion(
                id="test-region",
                provider="test",
                name="Test",
                url=remote.as_uri(),
                bounds=Bounds(0, 0, 1, 1),
                local_path="map-platform/backend/data/source-pbf/test.osm.pbf",
                checksum="0" * 64,
            )
            cache = SourceCache(root / "repo", root / "cache.json", data_root=root / "data")

            with self.assertRaisesRegex(SourceCacheError, "checksum mismatch"):
                cache.ensure(region, force=True)

            self.assertEqual(target.read_bytes(), b"stable")
            self.assertFalse(target.with_suffix(target.suffix + ".tmp").exists())

    def test_fresh_hash_cancellation_preserves_stable_target_and_removes_tmp(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            remote = root / "remote.osm.pbf"
            remote.write_bytes(b"replacement")
            target = root / "data" / "source-pbf" / "test.osm.pbf"
            target.parent.mkdir(parents=True)
            target.write_bytes(b"stable")
            region = SourceRegion(
                id="test-region",
                provider="test",
                name="Test",
                url=remote.as_uri(),
                bounds=Bounds(0, 0, 1, 1),
                local_path="map-platform/backend/data/source-pbf/test.osm.pbf",
            )
            cache = SourceCache(root / "repo", root / "cache.json", data_root=root / "data")

            with patch(
                "map_platform.source_cache._hash_file",
                side_effect=SourceCacheCancelled("operation was cancelled"),
            ), self.assertRaisesRegex(SourceCacheError, "operation was cancelled"):
                cache.ensure(region, force=True)

            self.assertEqual(target.read_bytes(), b"stable")
            self.assertFalse(target.with_suffix(target.suffix + ".tmp").exists())

    def test_fresh_replace_failure_preserves_stable_target_and_removes_tmp(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            remote = root / "remote.osm.pbf"
            remote.write_bytes(b"replacement")
            target = root / "data" / "source-pbf" / "test.osm.pbf"
            target.parent.mkdir(parents=True)
            target.write_bytes(b"stable")
            region = SourceRegion(
                id="test-region",
                provider="test",
                name="Test",
                url=remote.as_uri(),
                bounds=Bounds(0, 0, 1, 1),
                local_path="map-platform/backend/data/source-pbf/test.osm.pbf",
            )
            cache = SourceCache(root / "repo", root / "cache.json", data_root=root / "data")

            with patch.object(Path, "replace", side_effect=OSError("replace failed")), self.assertRaisesRegex(OSError, "replace failed"):
                cache.ensure(region, force=True)

            self.assertEqual(target.read_bytes(), b"stable")
            self.assertFalse(target.with_suffix(target.suffix + ".tmp").exists())

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
