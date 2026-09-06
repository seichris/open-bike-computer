"""Cache regressions for per-source candidates; all HTTP responses are synthetic."""
import hashlib
import io
import os
import tempfile
import unittest
import urllib.error
import urllib.request
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from map_platform.models import Bounds, SourceRegion
from map_platform.source_cache import SourceCache, SourceCacheError

GEO = "https://download.geofabrik.de/"
FR = "https://download.openstreetmap.fr/extracts/"
SUFFIX = "-latest.osm.pbf"


def fixture_pbf(marker=b"fixture"):
    blob = b"\x0a" + bytes([len(marker)]) + marker
    header = b"\x0a\x09OSMHeader\x18" + bytes([len(blob)])
    return len(header).to_bytes(4, "big") + header + blob


class Response(io.BytesIO):
    def __init__(self, data, url, etag=None):
        super().__init__(data)
        self.headers = {"Content-Length": str(len(data))}
        if etag:
            self.headers["ETag"] = etag
        self.url = url
        self.status = 200

    def geturl(self):
        return self.url


def url_of(request):
    return request.full_url if isinstance(request, urllib.request.Request) else request


class OsmfrPerSourceCacheTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        env = patch.dict(os.environ, {"MAP_PLATFORM_OSMFR_FALLBACK": "1"})
        env.start()
        self.addCleanup(env.stop)
        self.cache = SourceCache(self.root, data_root=self.root / "data")
        self.region = SourceRegion(
            id="fixture-source", provider="geofabrik", name="Fixture",
            url=GEO + "africa/kenya" + SUFFIX,
            bounds=Bounds(33, -5, 43, 6),
            local_path="backend/data/source-pbf/fixture.osm.pbf",
        )

    def test_unlisted_same_path_download_uses_no_head_probe(self):
        alternate = FR + "africa/kenya" + SUFFIX
        data = fixture_pbf()
        with patch("map_platform.source_cache.urllib.request.urlopen", side_effect=[
            TimeoutError("primary outage"), Response(data, alternate),
        ]) as opener:
            cached = self.cache.ensure(self.region)
        self.assertEqual([url_of(c.args[0]) for c in opener.call_args_list],
                         [self.region.url, alternate])
        for call in opener.call_args_list:
            request = call.args[0]
            if isinstance(request, urllib.request.Request):
                self.assertEqual(request.get_method(), "GET")
        self.assertEqual(cached.region_id, self.region.id)
        self.assertEqual(cached.path, self.cache._target_path(self.region))
        self.assertEqual(cached.path.read_bytes(), data)
        self.assertEqual(cached.source_url, alternate)
        self.assertEqual(cached.sha256, hashlib.sha256(data).hexdigest())

    def test_exact_alias_download_records_actual_url(self):
        region = replace(self.region, url=GEO + "north-america/us/new-york" + SUFFIX)
        alternate = FR + "north-america/us-northeast/new-york" + SUFFIX
        with patch("map_platform.source_cache.urllib.request.urlopen", side_effect=[
            urllib.error.HTTPError(region.url, 503, "down", {}, None),
            Response(fixture_pbf(), alternate),
        ]) as opener:
            cached = self.cache.ensure(region)
        self.assertEqual([url_of(c.args[0]) for c in opener.call_args_list], [region.url, alternate])
        self.assertEqual(cached.source_url, alternate)
        self.assertEqual(self.cache.metadata()["sources"][region.id]["sourceUrl"], alternate)

    def test_primary_success_does_not_probe_new_candidate(self):
        with patch("map_platform.source_cache.urllib.request.urlopen", return_value=
                   Response(fixture_pbf(), self.region.url)) as opener:
            self.cache.ensure(self.region)
        self.assertEqual(opener.call_count, 1)
        self.assertEqual(url_of(opener.call_args.args[0]), self.region.url)

    def test_coverage_block_only_contacts_primary(self):
        region = replace(self.region, url=GEO + "asia/china/guangdong" + SUFFIX)
        with patch("map_platform.source_cache.urllib.request.urlopen", side_effect=TimeoutError("down")) as opener:
            with self.assertRaises(SourceCacheError):
                self.cache.ensure(region)
        self.assertEqual(opener.call_count, 1)
        self.assertEqual(url_of(opener.call_args.args[0]), region.url)

    def test_missing_candidate_preserves_stable_bytes_and_does_not_guess(self):
        with patch("map_platform.source_cache.urllib.request.urlopen", return_value=
                   Response(fixture_pbf(b"old"), self.region.url)):
            previous = self.cache.ensure(self.region)
        old_bytes = previous.path.read_bytes()
        old_metadata = self.cache.metadata_path.read_bytes()
        alternate = FR + "africa/kenya" + SUFFIX
        error_body = io.BytesIO(b"Not found")
        missing = urllib.error.HTTPError(alternate, 404, "missing", {}, error_body)
        with patch("map_platform.source_cache.urllib.request.urlopen", side_effect=[
            TimeoutError("primary down"), missing,
        ]) as opener:
            with self.assertRaisesRegex(SourceCacheError, "both source providers failed"):
                self.cache.ensure(self.region, force=True)
        self.assertEqual(opener.call_count, 2)
        self.assertEqual(url_of(opener.call_args_list[1].args[0]), alternate)
        self.assertEqual(previous.path.read_bytes(), old_bytes)
        self.assertEqual(self.cache.metadata_path.read_bytes(), old_metadata)
        self.assertFalse(previous.path.with_suffix(previous.path.suffix + ".tmp").exists())
        self.assertTrue(error_body.closed)

    def test_new_alias_cache_reuse_and_primary_recovery(self):
        region = replace(self.region, url=GEO + "central-america/costa-rica" + SUFFIX)
        alternate = FR + "central-america/costa_rica" + SUFFIX
        with patch("map_platform.source_cache.urllib.request.urlopen", side_effect=[
            TimeoutError(), Response(fixture_pbf(), alternate, etag='"fr"'),
        ]):
            previous = self.cache.ensure(region)
        with patch("map_platform.source_cache.urllib.request.urlopen") as opener:
            self.assertEqual(self.cache.ensure(region), previous)
            opener.assert_not_called()
        self.cache.revalidate_after_seconds = 0
        with patch("map_platform.source_cache.urllib.request.urlopen", return_value=
                   Response(fixture_pbf(b"recovered"), region.url)) as opener:
            recovered = self.cache.ensure(region)
        self.assertEqual(opener.call_count, 1)
        request = opener.call_args.args[0]
        self.assertEqual(url_of(request), region.url)
        if isinstance(request, urllib.request.Request):
            self.assertEqual(dict(request.header_items()), {})
        self.assertEqual(recovered.source_url, region.url)

    def test_new_coverage_hold_invalidates_previously_accepted_fallback_cache(self):
        # Seed bytes as if downloaded using the previous PR's Guangdong allowlist.
        region = replace(self.region, url=GEO + "asia/china/guangdong" + SUFFIX)
        alternate = FR + "asia/china/guangdong" + SUFFIX
        with patch("map_platform.source_cache.urllib.request.urlopen", return_value=
                   Response(fixture_pbf(), alternate)):
            previous = self.cache.ensure(replace(region, url=alternate))
        metadata = self.cache.metadata_path.read_bytes()
        with patch("map_platform.source_cache.urllib.request.urlopen", side_effect=TimeoutError("down")) as opener:
            with self.assertRaises(SourceCacheError):
                self.cache.ensure(region)
        self.assertEqual(opener.call_count, 1)
        self.assertEqual(url_of(opener.call_args.args[0]), region.url)
        self.assertEqual(previous.path.read_bytes(), fixture_pbf())
        self.assertEqual(self.cache.metadata_path.read_bytes(), metadata)


if __name__ == "__main__":
    unittest.main()
