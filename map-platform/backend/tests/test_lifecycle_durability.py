import errno
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from map_platform.geofabrik_sources import GeofabrikSourceProvider
from map_platform.jobs import JobStore, MapJobService
from map_platform.models import Bounds, SourceRegion
from map_platform.sources import SourceIndex, SourceResolutionError
from map_platform.source_http import ProviderRedirectHandler, validate_geofabrik_url
import urllib.request


class LifecycleDurabilityTests(unittest.TestCase):
    def test_process_death_after_canonical_publish_is_repaired_by_existing_peer(self):
        with tempfile.TemporaryDirectory() as directory:
            peer = JobStore(directory)
            script = """
import os, sys
from map_platform.jobs import JobStore, MapJobService
from map_platform.models import Bounds, SourceRegion
from map_platform.sources import SourceIndex
store = JobStore(sys.argv[1])
store._index_job_ownership = lambda job: os._exit(91)
source = SourceRegion(id="sg", provider="test", name="Singapore", url="https://example.invalid/sg.pbf",
    bounds=Bounds(103, 1, 104.5, 1.8), local_path="sg.pbf")
MapJobService(SourceIndex([source]), store).create_job({
    "mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37],
    "clientInstallationId": "installation-12345678", "clientRequestId": "request-12345678"})
"""
            result = subprocess.run([sys.executable, "-c", script, directory], timeout=30)
            self.assertEqual(result.returncode, 91)
            self.assertEqual(len(peer.list_for_installation("installation-12345678")), 1)
            self.assertIsNotNone(peer.get_by_client_request("installation-12345678", "request-12345678"))
            self.assertEqual(len(peer.list_active()), 1)

    def test_existing_peer_repairs_every_interrupted_index_before_idempotent_retry(self):
        source = SourceRegion(id="sg", provider="test", name="Singapore",
                              url="https://example.invalid/sg.pbf",
                              bounds=Bounds(103, 1, 104.5, 1.8), local_path="sg.pbf")
        request = {"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37],
                   "clientInstallationId": "installation-12345678",
                   "clientRequestId": "request-12345678"}
        for boundary in ("_index_job_ownership", "_index_map_id", "_index_client_request", "_index_active_status"):
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory() as directory:
                writer, peer = JobStore(directory), JobStore(directory)
                service = MapJobService(SourceIndex([source]), writer)
                with patch.object(writer, boundary, side_effect=OSError(errno.ENOSPC, "injected")):
                    with self.assertRaises(OSError):
                        service.create_job(request)
                self.assertEqual(len(list(Path(directory).glob("*.json"))), 1)
                recovered = peer.get_by_client_request(request["clientInstallationId"], request["clientRequestId"])
                self.assertIsNotNone(recovered)
                self.assertEqual([job.job_id for job in peer.list_active()], [recovered.job_id])
                self.assertEqual(len(peer.list_for_installation(request["clientInstallationId"])), 1)
                retry = MapJobService(SourceIndex([source]), peer).create_job(request)
                self.assertEqual(retry.job_id, recovered.job_id)
                self.assertFalse(list(peer.pending_write_root.glob("*.json")))

    def test_corrupt_intent_fails_closed_in_already_running_reader(self):
        with tempfile.TemporaryDirectory() as directory:
            store = JobStore(directory)
            (store.pending_write_root / "broken.json").write_text("{broken")
            with self.assertRaises(ValueError):
                store.list_active()

    def test_provider_primary_and_redirect_origin_policy(self):
        handler = ProviderRedirectHandler()
        request = urllib.request.Request("https://download.geofabrik.de/index-v1.json")
        for url in ("http://download.geofabrik.de/x", "https://127.0.0.1/x",
                    "https://download.geofabrik.de.evil.invalid/x",
                    "https://user@download.geofabrik.de/x",
                    "https://download.geofabrik.de:444/x",
                    "https://download.geofabrik.de/%2e%2e/x"):
            with self.subTest(url=url):
                with self.assertRaises(ValueError):
                    validate_geofabrik_url(url)
                with self.assertRaises(ValueError):
                    handler.redirect_request(request, None, 302, "", {}, url)
        self.assertIsNotNone(handler.redirect_request(
            request, None, 302, "", {}, "https://download.geofabrik.de/asia-latest.osm.pbf"))

    def test_catalog_limits_preserve_last_good_cache(self):
        good = {"features": [{"properties": {"id": "sg", "urls": {
            "pbf": "https://download.geofabrik.de/asia/singapore-latest.osm.pbf"}},
            "geometry": {"type": "Polygon", "coordinates": [[[103, 1], [104, 1], [104, 2], [103, 1]]]}}]}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.json"
            original = json.dumps(good)
            path.write_text(original)
            provider = GeofabrikSourceProvider(cache_path=path, cache_ttl_seconds=0)
            with patch("map_platform.geofabrik_sources.MAX_CATALOG_BYTES", 1024), patch(
                "map_platform.geofabrik_sources.open_geofabrik_url", return_value=io.BytesIO(b"x" * 1025)
            ):
                self.assertEqual(len(provider.source_regions()), 1)
            self.assertEqual(path.read_text(), original)
            with patch("map_platform.geofabrik_sources.MAX_CATALOG_NODES", 4):
                with self.assertRaises(SourceResolutionError):
                    provider._read_catalog(io.BytesIO(original.encode()))
            with patch("map_platform.geofabrik_sources.MAX_CATALOG_FEATURES", 0):
                with self.assertRaises(SourceResolutionError):
                    provider._read_catalog(io.BytesIO(original.encode()))


if __name__ == "__main__":
    unittest.main()
