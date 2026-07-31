import json
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

from map_platform.jobs import JobStore, MapJobService
from map_platform.limits import JobLimits
from map_platform.models import Bounds, JobStatus, MapJob, SourceRegion
from map_platform.sources import SourceIndex, SourceResolutionError


class SourceAndJobTests(unittest.TestCase):
    def setUp(self):
        self.singapore = SourceRegion(
            id="sg",
            provider="test",
            name="Singapore",
            url="https://example.invalid/sg.osm.pbf",
            bounds=Bounds(103.0, 1.0, 104.5, 1.8),
            local_path="backend/data/source-pbf/sg.osm.pbf",
        )
        self.germany = SourceRegion(
            id="de",
            provider="test",
            name="Germany",
            url="https://example.invalid/de.osm.pbf",
            bounds=Bounds(5.5, 47.0, 15.5, 55.2),
            local_path="backend/data/source-pbf/de.osm.pbf",
        )

    def test_resolves_smallest_containing_source(self):
        index = SourceIndex([self.germany, self.singapore])

        source = index.resolve_for_bounds(Bounds(103.75, 1.24, 103.93, 1.37))

        self.assertEqual(source.id, "sg")

    def test_rejects_uncovered_bounds(self):
        index = SourceIndex([self.singapore])

        with self.assertRaises(SourceResolutionError):
            index.resolve_for_bounds(Bounds(-122.6, 37.6, -122.3, 37.9))

    def test_dynamic_geofabrik_source_covers_prefilled_nagoya_cutout(self):
        from map_platform.geofabrik_sources import GeofabrikSourceProvider

        with tempfile.TemporaryDirectory() as tmp:
            catalog_path = Path(tmp) / "geofabrik-index-v1.json"
            catalog_path.write_text(
                json.dumps(
                    {
                        "type": "FeatureCollection",
                        "features": [
                            {
                                "type": "Feature",
                                "properties": {
                                    "id": "asia",
                                    "name": "Asia",
                                    "urls": {"pbf": "https://download.geofabrik.de/asia-latest.osm.pbf"},
                                },
                                "geometry": {
                                    "type": "Polygon",
                                    "coordinates": [[[60, -10], [160, -10], [160, 60], [60, 60], [60, -10]]],
                                },
                            },
                            {
                                "type": "Feature",
                                "properties": {
                                    "id": "nearby-region",
                                    "parent": "japan",
                                    "name": "Nearby region with overlapping bounds",
                                    "urls": {"pbf": "https://download.geofabrik.de/asia/japan/nearby-latest.osm.pbf"},
                                },
                                "geometry": {
                                    "type": "Polygon",
                                    "coordinates": [
                                        [[136, 34], [138, 34], [138, 36], [136, 36], [136, 34]],
                                        [[136.5, 34.8], [137.2, 34.8], [137.2, 35.5], [136.5, 35.5], [136.5, 34.8]],
                                    ],
                                },
                            },
                            {
                                "type": "Feature",
                                "properties": {
                                    "id": "japan",
                                    "parent": "asia",
                                    "name": "Japan",
                                    "urls": {"pbf": "https://download.geofabrik.de/asia/japan-latest.osm.pbf"},
                                },
                                "geometry": {
                                    "type": "Polygon",
                                    "coordinates": [[[122, 20], [154.5, 20], [154.5, 46.5], [122, 46.5], [122, 20]]],
                                },
                            },
                        ],
                    }
                )
            )
            provider = GeofabrikSourceProvider(catalog_path.as_uri(), cache_path=Path(tmp) / "cache.json")
            source_index_path = Path(__file__).resolve().parents[1] / "config" / "source-regions.json"
            index = SourceIndex.from_json(source_index_path, fallback_provider=provider)

            source = index.resolve_for_bounds(Bounds(136.75, 35.05, 137.04, 35.29))

        self.assertEqual(source.id, "geofabrik-japan")
        self.assertEqual(source.local_path, "backend/data/source-pbf/geofabrik/japan-latest.osm.pbf")
        self.assertEqual(source.preview_geometry["type"], "Polygon")

    def test_static_geofabrik_preview_geometry_is_deferred_to_catalog_provider(self):
        from map_platform.geofabrik_sources import GeofabrikSourceProvider

        geometry = {
            "type": "Polygon",
            "coordinates": [[[98, -1.8], [120.2, -1.8], [120.2, 7.6], [98, 7.6], [98, -1.8]]],
        }
        with tempfile.TemporaryDirectory() as tmp:
            catalog_path = Path(tmp) / "geofabrik-index-v1.json"
            catalog_path.write_text(
                json.dumps(
                    {
                        "type": "FeatureCollection",
                        "features": [
                            {
                                "type": "Feature",
                                "properties": {
                                    "id": "asia/malaysia-singapore-brunei",
                                    "name": "Malaysia, Singapore, and Brunei",
                                    "urls": {
                                        "pbf": (
                                            "https://download.geofabrik.de/asia/"
                                            "malaysia-singapore-brunei-latest.osm.pbf"
                                        )
                                    },
                                },
                                "geometry": geometry,
                            }
                        ],
                    }
                )
            )
            provider = GeofabrikSourceProvider(catalog_path.as_uri(), cache_path=Path(tmp) / "cache.json")
            source_index_path = Path(__file__).resolve().parents[1] / "config" / "source-regions.json"
            index = SourceIndex.from_json(source_index_path, fallback_provider=provider)

            source = index.resolve_for_bounds(Bounds(103.75, 1.24, 103.93, 1.37))
            preview_geometry = provider.preview_geometry_for_source(source)

        self.assertEqual(source.id, "geofabrik-asia-malaysia-singapore-brunei")
        self.assertEqual(source.local_path, "backend/data/source-pbf/malaysia-singapore-brunei-latest.osm.pbf")
        self.assertIsNone(source.preview_geometry)
        self.assertEqual(preview_geometry, geometry)

    def test_static_source_resolution_does_not_query_preview_catalog(self):
        class UnavailableProvider:
            calls = 0

            def source_regions(self):
                self.calls += 1
                raise SourceResolutionError("catalog unavailable")

            def resolve_for_bounds(self, bounds):
                self.calls += 1
                raise SourceResolutionError("catalog unavailable")

        provider = UnavailableProvider()
        index = SourceIndex([self.singapore], fallback_provider=provider)

        source = index.resolve_for_bounds(Bounds(103.75, 1.24, 103.93, 1.37))

        self.assertEqual(source, self.singapore)
        self.assertEqual(provider.calls, 0)

    def test_dynamic_catalog_initialization_is_singleflight(self):
        from map_platform.geofabrik_sources import GeofabrikSourceProvider

        catalog = {
            "type": "FeatureCollection",
            "features": [
                {
                    "type": "Feature",
                    "properties": {
                        "id": "singapore",
                        "name": "Singapore",
                        "urls": {"pbf": "https://example.invalid/singapore.osm.pbf"},
                    },
                    "geometry": {
                        "type": "Polygon",
                        "coordinates": [
                            [[103, 1], [104, 1], [104, 2], [103, 2], [103, 1]]
                        ],
                    },
                }
            ],
        }

        class CountingProvider(GeofabrikSourceProvider):
            calls = 0
            calls_lock = threading.Lock()

            def _load_catalog(self):
                with self.calls_lock:
                    self.calls += 1
                time.sleep(0.02)
                return catalog

        with tempfile.TemporaryDirectory() as tmp:
            provider = CountingProvider(
                "https://example.invalid/index.json",
                cache_path=Path(tmp) / "cache.json",
            )
            with ThreadPoolExecutor(max_workers=8) as executor:
                results = list(executor.map(lambda _: provider.source_regions(), range(16)))

        self.assertEqual(provider.calls, 1)
        self.assertTrue(all(len(result) == 1 for result in results))

    def test_dynamic_catalog_failure_is_singleflight_during_cooldown(self):
        from map_platform.geofabrik_sources import GeofabrikSourceProvider

        class FailingProvider(GeofabrikSourceProvider):
            calls = 0
            calls_lock = threading.Lock()

            def _load_catalog(self):
                with self.calls_lock:
                    self.calls += 1
                time.sleep(0.02)
                raise OSError("catalog unavailable")

        with tempfile.TemporaryDirectory() as tmp:
            provider = FailingProvider(
                "https://example.invalid/index.json",
                cache_path=Path(tmp) / "cache.json",
                failure_cooldown_seconds=30,
            )

            def load(_):
                with self.assertRaisesRegex(SourceResolutionError, "catalog unavailable"):
                    provider.source_regions()

            with ThreadPoolExecutor(max_workers=8) as executor:
                list(executor.map(load, range(16)))

        self.assertEqual(provider.calls, 1)

    def test_geofabrik_preview_geometry_is_persisted_but_not_public(self):
        source = SourceRegion(
            id="geofabrik-sg",
            provider="geofabrik",
            name="Singapore",
            url="https://example.invalid/sg.osm.pbf",
            bounds=Bounds(103.0, 1.0, 104.5, 1.8),
            preview_geometry={
                "type": "Polygon",
                "coordinates": [[[103, 1], [104.5, 1], [104.5, 1.8], [103, 1.8], [103, 1]]],
            },
        )
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp))
            service = MapJobService(SourceIndex([source]), store)
            job = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
            )

            persisted = service.get_job(job.job_id)
            stored = json.loads((Path(tmp) / f"{job.job_id}.json").read_text())

        self.assertEqual(persisted.source_region.preview_geometry, source.preview_geometry)
        self.assertEqual(stored["sourceRegion"]["previewGeometry"], source.preview_geometry)
        self.assertNotIn("previewGeometry", job.to_dict()["sourceRegion"])

    def test_terminal_job_drops_internal_preview_geometry(self):
        source = SourceRegion(
            id="geofabrik-sg",
            provider="geofabrik",
            name="Singapore",
            url="https://example.invalid/sg.osm.pbf",
            bounds=Bounds(103.0, 1.0, 104.5, 1.8),
            preview_geometry={
                "type": "Polygon",
                "coordinates": [[[103, 1], [104.5, 1], [104.5, 1.8], [103, 1]]],
            },
        )
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp))
            job = MapJobService(SourceIndex([source]), store).create_job(
                {"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]}
            )

            retryable = store.update_status(
                job.job_id,
                JobStatus.FAILED,
                finished=True,
            )
            self.assertEqual(
                retryable.source_region.preview_geometry,
                source.preview_geometry,
            )
            terminal = store.update_status(
                job.job_id,
                JobStatus.CANCELLED,
                finished=True,
            )
            stored = json.loads((Path(tmp) / f"{job.job_id}.json").read_text())

            exhausted = MapJobService(SourceIndex([source]), store).create_job(
                {"mode": "custom_bbox", "bbox": [103.70, 1.20, 103.90, 1.35]}
            )
            exhausted.attempts = exhausted.max_attempts
            store.save(exhausted)
            terminal_failure = store.update_status(
                exhausted.job_id,
                JobStatus.FAILED,
                finished=True,
            )
            stored_failure = json.loads(
                (Path(tmp) / f"{exhausted.job_id}.json").read_text()
            )

        self.assertIsNone(terminal.source_region.preview_geometry)
        self.assertNotIn("previewGeometry", stored["sourceRegion"])
        self.assertIsNone(terminal_failure.source_region.preview_geometry)
        self.assertNotIn("previewGeometry", stored_failure["sourceRegion"])

    def test_create_job_persists_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(SourceIndex([self.singapore]), JobStore(Path(tmp)))
            job = service.create_job(
                {
                    "mode": "custom_bbox",
                    "displayName": "Singapore central",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
            )

            loaded = service.get_job(job.job_id)
            self.assertEqual(loaded.status.value, "queued")
            self.assertEqual(loaded.source_region.id, "sg")
            self.assertEqual(loaded.request["displayName"], "Singapore central")
            self.assertIsNone(loaded.to_dict()["progress"])

    def test_client_metadata_supports_filtered_recovery_and_idempotent_create(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(SourceIndex([self.singapore]), JobStore(Path(tmp)))
            request = {
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
                "clientInstallationId": "installation-12345678",
                "clientRequestId": "request-12345678",
                "installOnDevice": True,
            }

            created = service.create_job(request)
            retried = service.create_job(dict(request))
            service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.76, 1.25, 103.94, 1.38],
                    "clientInstallationId": "installation-other",
                    "clientRequestId": "request-other-123",
                }
            )

            recovered = service.list_jobs(client_installation_id="installation-12345678")
            self.assertEqual(retried.job_id, created.job_id)
            self.assertEqual(len(service.list_jobs()), 2)
            self.assertEqual([job.job_id for job in recovered], [created.job_id])
            self.assertEqual(recovered[0].client_request_id, "request-12345678")
            self.assertTrue(recovered[0].install_on_device)
            self.assertEqual(recovered[0].to_dict()["clientInstallationId"], "installation-12345678")

            legacy_shape = created.to_dict()
            legacy_shape.pop("clientInstallationId")
            legacy_shape.pop("clientRequestId")
            legacy_shape.pop("installOnDevice")
            migrated = MapJob.from_dict(legacy_shape)
            self.assertEqual(migrated.client_installation_id, "installation-12345678")
            self.assertEqual(migrated.client_request_id, "request-12345678")
            self.assertTrue(migrated.install_on_device)

    def test_client_request_id_rejects_different_retry_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(SourceIndex([self.singapore]), JobStore(Path(tmp)))
            request = {
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
                "clientInstallationId": "installation-12345678",
                "clientRequestId": "request-12345678",
            }
            service.create_job(request)

            changed = dict(request)
            changed["bbox"] = [103.76, 1.25, 103.94, 1.38]
            with self.assertRaisesRegex(ValueError, "different map request"):
                service.create_job(changed)

    def test_map_request_validates_bounded_metadata_before_persisting(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(SourceIndex([self.singapore]), JobStore(Path(tmp)))
            base = {
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
            }
            with self.assertRaisesRegex(ValueError, "target must be an object"):
                service.create_job({**base, "target": "esp32-fmb"})
            with self.assertRaisesRegex(ValueError, "renderer must be esp32-fmb"):
                service.create_job({**base, "target": {"renderer": "unknown"}})
            with self.assertRaisesRegex(ValueError, "displayName must be at most"):
                service.create_job({**base, "displayName": "x" * 81})

            job = service.create_job(
                {
                    **base,
                    "displayName": "  Singapore ride  ",
                    "target": {
                        "renderer": "esp32-fmb",
                        "firmwareVersion": " 1.2.3 ",
                    },
                }
            )

            self.assertEqual(job.request["displayName"], "Singapore ride")
            self.assertEqual(job.request["target"]["firmwareVersion"], "1.2.3")

    def test_filtered_job_list_does_not_parse_unrelated_records(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            service = MapJobService(SourceIndex([self.singapore]), JobStore(root))
            owned = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                    "clientInstallationId": "installation-12345678",
                    "clientRequestId": "request-12345678",
                }
            )
            unrelated = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.76, 1.25, 103.94, 1.38],
                    "clientInstallationId": "installation-other",
                    "clientRequestId": "request-other-123",
                }
            )
            (root / f"{unrelated.job_id}.json").write_text(
                '{\n  "clientInstallationId": "installation-other",\n  invalid\n'
            )
            owned_path = root / f"{owned.job_id}.json"
            legacy_owned = json.loads(owned_path.read_text())
            legacy_owned.pop("clientInstallationId")
            legacy_owned.pop("clientRequestId")
            owned_path.write_text(json.dumps(legacy_owned, separators=(",", ":")))

            recovered = service.list_jobs(
                client_installation_id="installation-12345678"
            )

            self.assertEqual([job.job_id for job in recovered], [owned.job_id])

    def test_idempotency_lookup_does_not_parse_unrelated_records(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            service = MapJobService(SourceIndex([self.singapore]), JobStore(root))
            request = {
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
                "clientInstallationId": "installation-12345678",
                "clientRequestId": "request-12345678",
            }
            owned = service.create_job(request)
            unrelated = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.76, 1.25, 103.94, 1.38],
                    "clientInstallationId": "installation-other",
                    "clientRequestId": "request-other-123",
                }
            )
            (root / f"{unrelated.job_id}.json").write_text("not-json")

            _, _, replay = service.resolve_client_request(dict(request))
            missing = service.find_by_client_request(
                "installation-missing",
                "request-missing-123",
            )

            self.assertEqual(replay.job_id, owned.job_id)
            self.assertIsNone(missing)

    def test_client_request_locks_use_a_bounded_stripe_set(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp))
            for index in range(600):
                with store.lock_client_request(
                    "installation-12345678",
                    f"request-{index:08d}",
                ):
                    pass

            lock_files = list((Path(tmp) / ".client-requests").glob("*.lock"))

            self.assertLessEqual(len(lock_files), 256)

    def test_map_id_lookup_does_not_parse_unrelated_records(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root)
            service = MapJobService(SourceIndex([self.singapore]), store)
            owned = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
            )
            ready = store.update_status(
                owned.job_id,
                JobStatus.READY,
                map_id="indexed-map",
            )
            unrelated = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.76, 1.25, 103.94, 1.38],
                }
            )
            (root / f"{unrelated.job_id}.json").write_text("not-json")

            found = service.find_by_map_id(
                "indexed-map",
                allow_owned_without_installation=True,
            )
            missing = service.find_by_map_id(
                "missing-map",
                allow_owned_without_installation=True,
            )

            self.assertEqual(found.job_id, ready.job_id)
            self.assertIsNone(missing)

    def test_active_job_limit_does_not_parse_terminal_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root)
            service = MapJobService(SourceIndex([self.singapore]), store)
            terminal = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
            )
            store.update_status(terminal.job_id, JobStatus.CANCELLED, finished=True)
            (root / f"{terminal.job_id}.json").write_text("not-json")

            created = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.76, 1.25, 103.94, 1.38],
                }
            )

            self.assertEqual(created.status, JobStatus.QUEUED)

    def test_concurrent_idempotent_creates_persist_one_job(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(SourceIndex([self.singapore]), JobStore(Path(tmp)))
            request = {
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
                "clientInstallationId": "installation-12345678",
                "clientRequestId": "request-12345678",
            }

            with ThreadPoolExecutor(max_workers=4) as executor:
                jobs = list(executor.map(lambda _: service.create_job(dict(request)), range(8)))

            self.assertEqual(len({job.job_id for job in jobs}), 1)
            self.assertEqual(len(service.list_jobs()), 1)

    def test_concurrent_conflicting_idempotent_creates_persist_one_intact_job(self):
        from threading import Barrier

        class BarrierService(MapJobService):
            def __init__(self, *args, barrier, **kwargs):
                super().__init__(*args, **kwargs)
                self.barrier = barrier

            def find_by_client_request(self, client_installation_id, client_request_id):
                existing = super().find_by_client_request(client_installation_id, client_request_id)
                self.barrier.wait(timeout=5)
                return existing

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            barrier = Barrier(2)
            services = [
                BarrierService(
                    SourceIndex([self.singapore]),
                    JobStore(root),
                    barrier=barrier,
                )
                for _ in range(2)
            ]
            base = {
                "mode": "custom_bbox",
                "clientInstallationId": "installation-12345678",
                "clientRequestId": "request-12345678",
            }
            requests = [
                {**base, "bbox": [103.75, 1.24, 103.93, 1.37]},
                {**base, "bbox": [103.76, 1.25, 103.94, 1.38]},
            ]

            with ThreadPoolExecutor(max_workers=2) as executor:
                futures = [
                    executor.submit(service.create_job, request)
                    for service, request in zip(services, requests)
                ]
                outcomes = []
                for future in futures:
                    try:
                        outcomes.append(future.result())
                    except ValueError as exc:
                        outcomes.append(exc)

            self.assertEqual(sum(isinstance(value, MapJob) for value in outcomes), 1)
            conflicts = [value for value in outcomes if isinstance(value, ValueError)]
            self.assertEqual(len(conflicts), 1)
            self.assertIn("different map request", str(conflicts[0]))
            reopened = JobStore(root).list()
            self.assertEqual(len(reopened), 1)
            self.assertIn(reopened[0].request["bbox"], [request["bbox"] for request in requests])

    def test_job_store_persists_generation_progress(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(Path(tmp))
            service = MapJobService(SourceIndex([self.singapore]), store)
            job = service.create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
            )

            with patch("map_platform.jobs.utc_now_iso", return_value="2026-07-12T00:00:00.000001Z"):
                updated = store.update_progress_unless_cancelled(job.job_id, 7, 10, worker_id="worker-test")
            response = service.get_job(job.job_id).to_dict()

            self.assertEqual(updated.worker_id, "worker-test")
            self.assertEqual(response["updatedAt"], "2026-07-12T00:00:00.000001Z")
            self.assertEqual(response["progress"]["completedBlocks"], 7)
            self.assertEqual(response["progress"]["totalBlocks"], 10)
            self.assertEqual(response["progress"]["fraction"], 0.7)

    def test_create_job_enforces_active_job_limit(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(SourceIndex([self.singapore]), JobStore(Path(tmp)), limits=JobLimits(max_active_jobs=1))
            service.create_job(
                {
                    "mode": "custom_bbox",
                    "displayName": "Singapore central",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                }
            )

            with self.assertRaises(ValueError):
                service.create_job(
                    {
                        "mode": "custom_bbox",
                        "displayName": "Singapore north",
                        "bbox": [103.75, 1.37, 103.93, 1.47],
                    }
                )


if __name__ == "__main__":
    unittest.main()
