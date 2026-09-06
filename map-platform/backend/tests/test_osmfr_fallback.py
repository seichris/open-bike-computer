import errno
import hashlib
import http.client
import io
import os
import ssl
import tempfile
import unittest
import urllib.error
import urllib.request
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from map_platform.models import Bounds, SourceRegion
from map_platform.osmfr_fallback import (
    GEOFABRIK_BASE, OSMFR_BASE, fallback_url, is_upstream_unavailable,
    validate_pbf_header,
)
from map_platform.source_cache import (
    SourceCache, SourceCacheCancelled, SourceCacheError, SourceCacheStorageError,
)

PRIMARY = GEOFABRIK_BASE + "asia/china/shanghai-latest.osm.pbf"
ALTERNATIVE = OSMFR_BASE + "asia/china/shanghai-latest.osm.pbf"


def pbf_bytes(marker=b"fixture"):
    # Synthetic complete first Blob; tests do not claim a routable map fixture.
    blob = b"\x0a" + bytes([len(marker)]) + marker
    header = b"\x0a\x09OSMHeader\x18" + bytes([len(blob)])
    return len(header).to_bytes(4, "big") + header + blob


class Response(io.BytesIO):
    def __init__(self, data, url=PRIMARY, headers=None, status=200):
        super().__init__(data)
        self.headers = {"Content-Length": str(len(data)), **(headers or {})}
        self.url = url
        self.status = status

    def geturl(self):
        return self.url


def request_url(request):
    return request.full_url if isinstance(request, urllib.request.Request) else request


def request_headers(request):
    return dict(request.header_items()) if isinstance(request, urllib.request.Request) else {}


class FallbackTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.environment = patch.dict(os.environ, {"MAP_PLATFORM_OSMFR_FALLBACK": "1"})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.region = SourceRegion(
            id="geofabrik-shanghai", provider="geofabrik", name="Shanghai",
            url=PRIMARY, bounds=Bounds(120.8, 30.6, 122.0, 31.9),
            local_path="backend/data/source-pbf/shanghai-latest.osm.pbf",
        )
        self.cache = SourceCache(self.root, data_root=self.root / "data")
        self.target = self.cache._target_path(self.region)
        self.temporary = self.target.with_suffix(self.target.suffix + ".tmp")

    def download(self, responses, **kwargs):
        with patch("map_platform.source_cache.urllib.request.urlopen", side_effect=responses) as opener:
            cached = self.cache.ensure(self.region, **kwargs)
        return cached, opener

    def seed(self, fallback=False):
        data = pbf_bytes(b"previous")
        responses = [Response(data)]
        if fallback:
            responses = [TimeoutError("primary down"), Response(data, ALTERNATIVE, {"ETag": '"fr-old"'})]
        cached, _ = self.download(responses)
        return cached

    def assert_clean(self):
        self.assertFalse(self.temporary.exists())
        self.assertFalse(self.cache.metadata_path.with_suffix(".json.tmp").exists())

    def test_http_error_response_is_closed_before_fallback(self):
        body = io.BytesIO(b"Service unavailable")
        error = urllib.error.HTTPError(PRIMARY, 503, "down", {}, body)
        def open_url(request, timeout):
            if request_url(request) == PRIMARY:
                raise error
            self.assertTrue(body.closed)
            return Response(pbf_bytes(b"fr"), ALTERNATIVE)
        self.download(open_url)

    def test_primary_304_still_reuses_primary_cache(self):
        previous, _ = self.download([
            Response(pbf_bytes(b"primary"), PRIMARY, {"ETag": '\"geo\"'}),
        ])
        self.cache.revalidate_after_seconds = 0
        body = io.BytesIO()
        unchanged = urllib.error.HTTPError(PRIMARY, 304, "Not Modified", {}, body)
        cached, opener = self.download([unchanged])
        self.assertEqual(opener.call_count, 1)
        self.assertEqual(cached.source_url, PRIMARY)
        self.assertEqual(cached.sha256, previous.sha256)
        self.assertTrue(body.closed)

    def test_cancellation_during_fallback_preserves_previous_source(self):
        previous = self.seed()
        old_bytes = previous.path.read_bytes()
        old_metadata = self.cache.metadata_path.read_bytes()
        cancelled = False
        class Cancelling(Response):
            def read(self, size=-1):
                nonlocal cancelled
                cancelled = True
                return super().read(size)
        with self.assertRaises(SourceCacheCancelled):
            self.download([TimeoutError(), Cancelling(pbf_bytes(b"fr"), ALTERNATIVE)],
                          force=True, cancellation_check=lambda: cancelled)
        self.assertEqual(previous.path.read_bytes(), old_bytes)
        self.assertEqual(self.cache.metadata_path.read_bytes(), old_metadata)
        self.assert_clean()

    def test_fallback_is_enabled_by_default(self):
        os.environ.pop("MAP_PLATFORM_OSMFR_FALLBACK", None)
        cache = SourceCache(self.root, data_root=self.root / "default")
        self.assertTrue(cache.osmfr_fallback_enabled)

    def test_primary_success_and_redirect_do_not_contact_fallback(self):
        dated = PRIMARY.replace("latest", "260905")
        data = pbf_bytes(b"primary")
        cached, opener = self.download([Response(data, dated)])
        self.assertEqual(opener.call_count, 1)
        self.assertEqual(cached.source_url, PRIMARY)
        self.assertEqual(cached.resolved_url, dated)
        self.assertEqual(self.target.read_bytes(), data)

    def test_availability_errors_fail_over_once_and_record_actual_source(self):
        errors = [TimeoutError("timeout"), ConnectionResetError("reset"),
                  urllib.error.URLError("DNS failed"), http.client.IncompleteRead(b"", 10)]
        errors += [urllib.error.HTTPError(PRIMARY, code, "unavailable", {}, None)
                   for code in (404, 408, 410, 429, 500, 502, 503, 504)]
        data = pbf_bytes(b"fr")
        for error in errors:
            with self.subTest(error=repr(error)):
                cached, opener = self.download([
                    error, Response(data, ALTERNATIVE, {"ETag": '"fr"'}),
                ], force=True)
                self.assertEqual([request_url(call.args[0]) for call in opener.call_args_list],
                                 [PRIMARY, ALTERNATIVE])
                self.assertEqual(cached.source_url, ALTERNATIVE)
                self.assertEqual(cached.resolved_url, ALTERNATIVE)
                self.assertEqual(cached.sha256, hashlib.sha256(data).hexdigest())
                self.assertIsNone(cached.source_published_at)
                recorded = self.cache.metadata()["sources"][self.region.id]
                self.assertEqual(recorded["sourceUrl"], ALTERNATIVE)
                self.assertEqual(recorded["sha256"], cached.sha256)
                with self.cache.verified_lease(self.region) as leased:
                    self.assertEqual(leased.sha256, cached.sha256)
                self.assert_clean()

    def test_partial_primary_is_removed_before_fallback_and_not_appended(self):
        data = pbf_bytes(b"fr")
        class Interrupted(Response):
            def read(self, size=-1):
                if self.tell():
                    raise TimeoutError("read timed out")
                return super().read(5)
        primary = Interrupted(pbf_bytes(b"unfinished primary"), headers={"ETag": '"geo"'})
        def open_url(request, timeout):
            if request_url(request) == PRIMARY:
                return primary
            self.assertTrue(primary.closed)
            self.assertFalse(self.temporary.exists())
            self.assertEqual(request_headers(request), {})
            return Response(data, ALTERNATIVE)
        cached, opener = self.download(open_url)
        self.assertEqual(opener.call_count, 2)
        self.assertEqual(cached.path.read_bytes(), data)
        self.assert_clean()

    def test_failed_same_provider_resume_restarts_fallback_without_range(self):
        data = pbf_bytes(b"unfinished")
        first = Response(data[:6], PRIMARY, {"Content-Length": str(len(data)), "ETag": '"geo"'})
        cached, opener = self.download([
            first, TimeoutError("resume down"), Response(pbf_bytes(b"fr"), ALTERNATIVE),
        ])
        resumed = request_headers(opener.call_args_list[1].args[0])
        self.assertEqual(resumed["Range"], "bytes=6-")
        self.assertEqual(resumed["If-range"], '"geo"')
        self.assertEqual(request_headers(opener.call_args_list[2].args[0]), {})
        self.assertEqual(cached.path.read_bytes(), pbf_bytes(b"fr"))
        self.assert_clean()

    def test_normal_same_provider_resume_is_unchanged(self):
        data = pbf_bytes(b"primary")
        cached, opener = self.download([
            Response(data[:6], PRIMARY, {"Content-Length": str(len(data)), "ETag": '"geo"'}),
            Response(data[6:], PRIMARY, {"Content-Range": f"bytes 6-{len(data)-1}/{len(data)}",
                                        "ETag": '"geo"'}, status=206),
        ])
        self.assertEqual(opener.call_count, 2)
        self.assertEqual(cached.path.read_bytes(), data)
        self.assertEqual(cached.source_url, PRIMARY)

    def test_fresh_fallback_cache_obeys_ttl_without_repeated_primary_timeout(self):
        previous = self.seed(fallback=True)
        cached, opener = self.download([])
        opener.assert_not_called()
        self.assertEqual(cached, previous)

    def test_stale_fallback_retries_primary_without_leaking_fallback_validators(self):
        self.seed(fallback=True)
        self.cache.revalidate_after_seconds = 0
        cached, opener = self.download([Response(pbf_bytes(b"recovered"))])
        self.assertEqual(opener.call_count, 1)
        self.assertEqual(request_headers(opener.call_args.args[0]), {})
        self.assertEqual(cached.source_url, PRIMARY)

    def test_primary_validators_are_not_sent_to_fallback(self):
        self.download([Response(pbf_bytes(b"old"), PRIMARY, {"ETag": '"geo-old"'})])
        self.cache.revalidate_after_seconds = 0
        _, opener = self.download([TimeoutError(), Response(pbf_bytes(b"fr"), ALTERNATIVE)])
        self.assertEqual(request_headers(opener.call_args_list[0].args[0])["If-none-match"], '"geo-old"')
        self.assertEqual(request_headers(opener.call_args_list[1].args[0]), {})

    def test_fallback_304_revalidates_only_its_own_bytes_and_metadata(self):
        previous = self.seed(fallback=True)
        self.cache.revalidate_after_seconds = 0
        not_modified = urllib.error.HTTPError(ALTERNATIVE, 304, "Not Modified", {"ETag": '"fr-old"'}, None)
        cached, opener = self.download([TimeoutError(), not_modified])
        self.assertEqual(request_headers(opener.call_args_list[0].args[0]), {})
        self.assertEqual(request_headers(opener.call_args_list[1].args[0])["If-none-match"], '"fr-old"')
        self.assertEqual(cached.source_url, ALTERNATIVE)
        self.assertEqual(cached.sha256, previous.sha256)
        self.assertEqual(cached.downloaded_at, previous.downloaded_at)
        self.assertGreaterEqual(cached.validated_at, previous.validated_at)
        self.assert_clean()

    def test_both_down_preserves_previous_file_and_metadata(self):
        self.seed()
        old_bytes = self.target.read_bytes()
        old_metadata = self.cache.metadata_path.read_bytes()
        self.cache.revalidate_after_seconds = 0
        with self.assertRaisesRegex(SourceCacheError, "both source providers failed.*Geofabrik:.*OpenStreetMap France:"):
            self.download([TimeoutError("primary down"), urllib.error.URLError("fallback down")])
        self.assertEqual(self.target.read_bytes(), old_bytes)
        self.assertEqual(self.cache.metadata_path.read_bytes(), old_metadata)
        self.assert_clean()

    def test_force_refresh_bypasses_fallback_cache_and_validators(self):
        self.seed(fallback=True)
        _, opener = self.download([TimeoutError(), Response(pbf_bytes(b"new"), ALTERNATIVE)], force=True)
        self.assertEqual(opener.call_count, 2)
        self.assertTrue(all(not request_headers(call.args[0]) for call in opener.call_args_list))

    def test_disabled_fallback_is_not_attempted(self):
        for value in ("0", "false", "no", "off", "FALSE"):
            with self.subTest(value=value), patch.dict(os.environ, {"MAP_PLATFORM_OSMFR_FALLBACK": value}):
                cache = SourceCache(self.root, data_root=self.root / "data")
                with patch("map_platform.source_cache.urllib.request.urlopen", side_effect=TimeoutError()) as opener:
                    with self.assertRaises(SourceCacheError):
                        cache.ensure(self.region)
                self.assertEqual(opener.call_count, 1)

    def test_disabling_fallback_does_not_keep_using_fresh_fallback_cache(self):
        self.seed(fallback=True)
        self.cache.osmfr_fallback_enabled = False
        cached, opener = self.download([Response(pbf_bytes(b"primary"))])
        self.assertEqual(opener.call_count, 1)
        self.assertEqual(cached.source_url, PRIMARY)

    def test_pinned_or_unmapped_sources_never_fail_over(self):
        variants = [
            replace(self.region, checksum="a" * 64),
            replace(self.region, published_at="2026-09-05T00:00:00Z"),
            replace(self.region, url=PRIMARY.replace("latest", "260905")),
            replace(self.region, provider="custom"),
            replace(self.region, url=GEOFABRIK_BASE + "asia/malaysia-singapore-brunei-latest.osm.pbf"),
        ]
        for region in variants:
            with self.subTest(region=region), patch("map_platform.source_cache.urllib.request.urlopen", side_effect=TimeoutError()) as opener:
                with self.assertRaises(SourceCacheError):
                    self.cache.ensure(region, force=True)
                self.assertEqual(opener.call_count, 1)
                self.assert_clean()

    def test_checksum_mismatch_does_not_fail_over(self):
        with patch("map_platform.source_cache.urllib.request.urlopen", return_value=Response(pbf_bytes())) as opener:
            with self.assertRaisesRegex(SourceCacheError, "checksum mismatch"):
                self.cache.ensure(replace(self.region, checksum="a" * 64))
        self.assertEqual(opener.call_count, 1)
        self.assertFalse(self.target.exists())
        self.assert_clean()

    def test_auth_tls_and_local_failures_are_not_outages(self):
        errors = [
            urllib.error.HTTPError(PRIMARY, code, "not an outage", {}, None)
            for code in (304, 400, 401, 403, 416)
        ] + [urllib.error.URLError(ssl.SSLCertVerificationError("invalid certificate")),
             OSError(errno.ENOSPC, "disk full"), ValueError("invalid local configuration")]
        for error in errors:
            with self.subTest(error=repr(error)), patch("map_platform.source_cache.urllib.request.urlopen", side_effect=error) as opener:
                with self.assertRaises(SourceCacheError):
                    self.cache.ensure(self.region)
                self.assertEqual(opener.call_count, 1)
                self.assert_clean()

    def test_storage_admission_never_becomes_fallback(self):
        with patch("map_platform.source_cache.shutil.disk_usage", return_value=SimpleNamespace(free=1)), \
             patch("map_platform.source_cache.urllib.request.urlopen") as opener:
            with self.assertRaises(SourceCacheStorageError):
                self.cache.ensure(self.region, minimum_free_bytes=100)
        opener.assert_not_called()

    def test_cancellation_between_providers_stops_fallback(self):
        cancelled = False
        def fail_primary(*args, **kwargs):
            nonlocal cancelled
            cancelled = True
            raise TimeoutError()
        with patch("map_platform.source_cache.urllib.request.urlopen", side_effect=fail_primary) as opener:
            with self.assertRaises(SourceCacheCancelled):
                self.cache.ensure(self.region, cancellation_check=lambda: cancelled)
        self.assertEqual(opener.call_count, 1)
        self.assert_clean()

    def test_fallback_still_enforces_disk_reserve(self):
        with patch("map_platform.source_cache.shutil.disk_usage", return_value=SimpleNamespace(free=1000)), \
             patch("map_platform.source_cache.urllib.request.urlopen", side_effect=[
                 TimeoutError(), Response(pbf_bytes(), ALTERNATIVE, {"Content-Length": "1000"}),
             ]) as opener:
            with self.assertRaises(SourceCacheStorageError):
                self.cache.ensure(self.region, minimum_free_bytes=100)
        self.assertEqual(opener.call_count, 2)
        self.assertFalse(self.target.exists())
        self.assert_clean()

    def test_invalid_fallback_body_does_not_replace_existing_source(self):
        self.seed()
        old_bytes = self.target.read_bytes()
        old_metadata = self.cache.metadata_path.read_bytes()
        for body in (b"", b"<html>Maintenance</html>", pbf_bytes()[:-1], b"\x00\x01\x00\x00"):
            with self.subTest(body=body), self.assertRaises(SourceCacheError):
                self.download([TimeoutError(), Response(body, ALTERNATIVE)], force=True)
            self.assertEqual(self.target.read_bytes(), old_bytes)
            self.assertEqual(self.cache.metadata_path.read_bytes(), old_metadata)
            self.assert_clean()

    def test_untrusted_fallback_redirect_is_rejected(self):
        for url in ("http://download.openstreetmap.fr/extracts/shanghai.osm.pbf", "https://example.invalid/map.osm.pbf"):
            with self.subTest(url=url), self.assertRaisesRegex(SourceCacheError, "trusted HTTPS source"):
                self.download([TimeoutError(), Response(pbf_bytes(), url)], force=True)
            self.assertFalse(self.target.exists())
            self.assert_clean()

    def test_url_mapping_is_explicit_and_preserves_region(self):
        self.assertEqual(fallback_url(self.region), ALTERNATIVE)
        for source, destination in (("asia/china/jiangsu", "asia/china/jiangsu"),
                                    ("europe/germany", "europe/germany"),
                                    ("asia/china/xizang", "asia/china/tibet")):
            region = replace(self.region, url=GEOFABRIK_BASE + source + "-latest.osm.pbf")
            self.assertEqual(fallback_url(region), OSMFR_BASE + destination + "-latest.osm.pbf")
        for url in (PRIMARY + "?x=1", PRIMARY + "#fragment", PRIMARY.replace("https:", "http:"),
                    PRIMARY.replace(".de/", ".de.evil/"), PRIMARY.replace(".de/", ".de:443/"),
                    PRIMARY.replace("https://", "https://user:pass@"),
                    GEOFABRIK_BASE + "europe/ireland-and-northern-ireland-latest.osm.pbf",
                    GEOFABRIK_BASE + "asia/taiwan-latest.osm.pbf"):
            self.assertIsNone(fallback_url(replace(self.region, url=url)), url)

    def test_error_classifier_does_not_retry_unrelated_errors(self):
        for error in (None, RuntimeError("local"), OSError(errno.ENOSPC, "disk"), ssl.SSLError("TLS")):
            self.assertFalse(is_upstream_unavailable(error))

    def test_pbf_header_validation_accepts_reordered_fields(self):
        blob = b"\x0a\x01x"
        header = b"\x18\x03\x12\x02ab\x0a\x09OSMHeader"
        path = self.root / "header.pbf"
        path.write_bytes(len(header).to_bytes(4, "big") + header + blob)
        validate_pbf_header(path)

    def test_pbf_header_validation_rejects_malformed_protobuf(self):
        headers = (b"\x80", b"\x00", b"\x0f", b"\x0a\xff\x01x", b"\x0a\x07OSMData\x18\x01",
                   b"\x0a\x09OSMHeader", b"\x0a\x09OSMHeader\x18\x00")
        path = self.root / "bad-header.pbf"
        for header in headers:
            with self.subTest(header=header):
                path.write_bytes(len(header).to_bytes(4, "big") + header + b"x")
                with self.assertRaises(ValueError):
                    validate_pbf_header(path)


if __name__ == "__main__":
    unittest.main()
