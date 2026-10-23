from __future__ import annotations

import hashlib
import json
import tempfile
import time
import unittest
from dataclasses import replace
from pathlib import Path

from map_platform.route_elevation_providers import (
    GEOAPIFY_ELEVATION_URL,
    CopernicusRouteElevationProvider,
    ElevationProviderError,
    GeoapifyConfig,
    GeoapifyElevationProvider,
    ProviderCreditLedger,
    ProviderHTTPResponse,
    UrllibElevationTransport,
    geoapify_batches,
    geoapify_credits,
    parse_geoapify_response,
    purge_expired_route_elevation_credits,
)
from map_platform.topography_sources import TopographySourcePolicy, load_topography_source_policy

try:
    import numpy  # noqa: F401
    import rasterio  # noqa: F401
    HAS_RASTER = True
except ImportError:  # pragma: no cover - the topography extra is installed in CI
    HAS_RASTER = False

ROOT = Path(__file__).resolve().parents[3]
SECRET_KEY = "geoapify-secret-key-for-tests-0123456789"


def geoapify_body(points, *, elevations=None, swap=False, units="m"):
    results = []
    for index, (lat, lon) in enumerate(points):
        location = {"lat": lon, "lon": lat} if swap else {"lat": lat, "lon": lon}
        value = 100.0 + index if elevations is None else elevations[index]
        results.append({"location": location, "elevation": value, "units": units})
    return json.dumps({"results": results}).encode()


class FakeTransport:
    def __init__(self):
        self.requests: list[dict] = []
        self.responses: list[object] = []

    def queue(self, response):
        self.responses.append(response)

    def request(self, *, method, url, headers, body, timeout_seconds, maximum_body_bytes):
        self.requests.append({"method": method, "url": url, "headers": headers, "body": body,
                              "timeout": timeout_seconds, "maximum": maximum_body_bytes})
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        if callable(response):
            return response(url, body)
        return response


def ok(points, **kwargs):
    def respond(url, body):
        return ProviderHTTPResponse(200, {"content-type": "application/json"}, geoapify_body(points, **kwargs), url)
    return respond


class ManualClock:
    def __init__(self, now=1_700_000_000.0):
        self.now = now
        self.sleeps: list[float] = []

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


class GeoapifyCostTests(unittest.TestCase):
    def test_documented_credit_formula_and_minimal_batching(self):
        self.assertEqual([geoapify_credits(n) for n in (1, 100, 101, 1000)], [1, 1, 2, 10])
        self.assertEqual(geoapify_batches(4001), [(0, 1000), (1000, 2000), (2000, 3000), (3000, 4000), (4000, 4001)])
        self.assertEqual(sum(geoapify_credits(end - start) for start, end in geoapify_batches(4001)), 41)
        with self.assertRaises(ValueError):
            geoapify_credits(0)


class GeoapifyParsingTests(unittest.TestCase):
    points = [(37.81, -122.47), (37.82, -122.48), (37.83, -122.49)]

    def test_preserves_order_nulls_and_negative_heights(self):
        body = geoapify_body(self.points, elevations=[12.5, None, -97.0])
        self.assertEqual(parse_geoapify_response(body, self.points), [12.5, None, -97.0])

    def test_accepts_only_a_consistently_swapped_echo(self):
        self.assertEqual(len(parse_geoapify_response(geoapify_body(self.points, swap=True), self.points)), 3)
        mixed = json.loads(geoapify_body(self.points))
        mixed["results"][1]["location"] = {"lat": -122.48, "lon": 37.82}
        with self.assertRaises(ElevationProviderError):
            parse_geoapify_response(json.dumps(mixed).encode(), self.points)

    def test_rejects_malformed_responses(self):
        cases = [
            b"not json",
            json.dumps({"results": []}).encode(),
            geoapify_body(self.points[:2]),
            geoapify_body(self.points, units="ft"),
            geoapify_body(self.points, elevations=[1.0, 2.0, 99999.0]),
            geoapify_body(self.points, elevations=[1.0, True, 2.0]),
            json.dumps({"results": [{"location": {"lat": 0, "lon": 0}, "elevation": 1}] * 3}).encode(),
            b'{"results": [], "results": []}',
        ]
        for body in cases:
            with self.subTest(body=body[:40]), self.assertRaises(ElevationProviderError) as raised:
                parse_geoapify_response(body, self.points)
            self.assertEqual(raised.exception.code, "provider-malformed-response")


class GeoapifyProviderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.clock = ManualClock()
        self.ledger = ProviderCreditLedger(Path(self.tmp.name) / "route-elevation.sqlite3", "pseudonym-secret",
                                           clock=self.clock)
        self.transport = FakeTransport()

    def provider(self, **config):
        return GeoapifyElevationProvider(
            GeoapifyConfig(api_key=SECRET_KEY, **config), self.ledger, transport=self.transport,
            clock=self.clock, wall_clock=self.clock, sleep=self.clock.sleep,
        )

    def test_success_batches_requests_and_keeps_the_key_server_side(self):
        points = [(45.0 + index * 0.0001, 7.0) for index in range(1001)]
        self.transport.queue(ok(points[:1000]))
        self.transport.queue(ok(points[1000:]))
        samples = self.provider().sample(points, installation_id="inst_a", deadline=self.clock() + 20)
        self.assertEqual(len(samples.values), 1001)
        self.assertEqual(samples.credits_used, 11)
        self.assertEqual(self.ledger.used_today("geoapify"), 11)
        first = self.transport.requests[0]
        self.assertEqual(first["method"], "POST")
        self.assertTrue(first["url"].startswith(GEOAPIFY_ELEVATION_URL + "?apiKey="))
        self.assertEqual(json.loads(first["body"])["locations"][0], [7.0, 45.0])
        self.assertIsNone(samples.source.vertical_datum)
        self.assertIsNone(samples.source.native_resolution_m)
        self.assertIn("Powered by Geoapify (https://www.geoapify.com/)", samples.source.attribution)
        self.assertNotIn(SECRET_KEY, json.dumps(samples.source.to_dict()))
        self.assertNotIn(SECRET_KEY, repr(GeoapifyConfig(api_key=SECRET_KEY)))

    def test_http_failures_map_to_fixed_codes_and_refund_unsent_batches(self):
        points = [(45.0 + index * 0.0001, 7.0) for index in range(1500)]
        cases = [
            (401, "provider-unauthorized"),
            (403, "provider-unauthorized"),
            (429, "provider-rate-limited"),
            (500, "provider-unavailable"),
            (400, "provider-rejected-request"),
        ]
        for status, code in cases:
            with self.subTest(status=status):
                self.transport.queue(lambda url, body, status=status: ProviderHTTPResponse(
                    status, {"retry-after": "30"}, b"{}", url))
                before = self.ledger.used_today("geoapify")
                with self.assertRaises(ElevationProviderError) as raised:
                    self.provider().sample(points, installation_id=f"inst_{status}", deadline=self.clock() + 20)
                self.assertEqual(raised.exception.code, code)
                self.assertNotIn(SECRET_KEY, str(raised.exception))
                if status == 429:
                    self.assertEqual(raised.exception.retry_after_seconds, 30)
                # The first batch (10 credits) was sent; the unsent 5-credit batch is refunded.
                self.assertEqual(self.ledger.used_today("geoapify") - before, 10)

    def test_redirect_oversize_and_transport_errors_never_leak_the_key(self):
        points = [(45.0, 7.0)]
        self.transport.queue(lambda url, body: ProviderHTTPResponse(200, {}, geoapify_body(points), url + "&x=1"))
        with self.assertRaises(ElevationProviderError) as raised:
            self.provider().sample(points, installation_id="inst_r", deadline=self.clock() + 20)
        self.assertEqual(raised.exception.code, "provider-malformed-response")
        self.transport.queue(lambda url, body: ProviderHTTPResponse(200, {}, b" " * (600 * 1024), url))
        with self.assertRaises(ElevationProviderError):
            self.provider().sample(points, installation_id="inst_r", deadline=self.clock() + 20)

        transport = UrllibElevationTransport()
        with self.assertRaises(ElevationProviderError) as raised:
            transport.request(method="POST", url=f"https://127.0.0.1:9/elevation?apiKey={SECRET_KEY}",
                              headers={}, body=b"{}", timeout_seconds=0.5, maximum_body_bytes=10)
        self.assertIn(raised.exception.code, {"provider-unavailable", "provider-timeout"})
        self.assertIsNone(raised.exception.__cause__)
        self.assertIsNone(raised.exception.__context__)
        self.assertNotIn(SECRET_KEY, repr(raised.exception) + str(raised.exception))

    def test_quota_is_shared_bounded_per_installation_and_resets_daily(self):
        points = [(45.0 + index * 0.0001, 7.0) for index in range(100)]
        provider = self.provider(daily_credit_budget=3, installation_daily_credit_budget=2)
        for _ in range(2):
            self.transport.queue(ok(points))
            provider.sample(points, installation_id="inst_a", deadline=self.clock() + 20)
        with self.assertRaises(ElevationProviderError) as raised:
            provider.sample(points, installation_id="inst_a", deadline=self.clock() + 20)
        self.assertEqual(raised.exception.code, "quota-exhausted")
        self.assertGreater(raised.exception.retry_after_seconds, 0)
        self.transport.queue(ok(points))
        provider.sample(points, installation_id="inst_b", deadline=self.clock() + 20)
        with self.assertRaises(ElevationProviderError):
            provider.sample(points, installation_id="inst_c", deadline=self.clock() + 20)
        self.assertEqual(len(self.transport.requests), 3)
        self.clock.now += 86_400
        self.transport.queue(ok(points))
        provider.sample(points, installation_id="inst_a", deadline=self.clock() + 20)
        self.clock.now += 3 * 86_400
        self.assertGreaterEqual(
            purge_expired_route_elevation_credits(self.ledger.path, now=self.clock.now), 1)

    def test_requests_are_paced_below_the_free_plan_rate(self):
        points = [(45.0 + index * 0.00001, 7.0) for index in range(3500)]
        for start in range(0, 3500, 1000):
            self.transport.queue(ok(points[start:start + 1000]))
        provider = self.provider(requests_per_second=2)
        provider.sample(points, installation_id="inst_p", deadline=self.clock() + 20)
        self.assertGreaterEqual(sum(self.clock.sleeps), 0.99)

    def test_unconfigured_or_disabled_budget_is_unavailable_without_requests(self):
        missing = GeoapifyElevationProvider(GeoapifyConfig(api_key=None), self.ledger, transport=self.transport)
        self.assertEqual(missing.unavailable_reason(), "provider-not-configured")
        zero = GeoapifyElevationProvider(GeoapifyConfig(api_key=SECRET_KEY, daily_credit_budget=0), self.ledger,
                                         transport=self.transport)
        self.assertEqual(zero.unavailable_reason(), "provider-budget-disabled")
        self.assertEqual(self.transport.requests, [])

    def test_configuration_rejects_malformed_keys(self):
        import os
        from unittest.mock import patch
        with patch.dict(os.environ, {"MAP_PLATFORM_GEOAPIFY_API_KEY": "bad key"}):
            with self.assertRaises(ValueError) as raised:
                GeoapifyConfig.from_environment()
            self.assertNotIn("bad key", str(raised.exception))
        with patch.dict(os.environ, {"MAP_PLATFORM_GEOAPIFY_API_KEY": SECRET_KEY,
                                     "MAP_PLATFORM_GEOAPIFY_DAILY_CREDIT_BUDGET": "250"}):
            config = GeoapifyConfig.from_environment()
            self.assertEqual(config.daily_credit_budget, 250)
            self.assertNotIn(SECRET_KEY, repr(config))


def fixture_source(source, cells):
    raw = ("\r\n".join(source.tile_name(*cell) for cell in cells) + "\r\n").encode()
    return replace(source, index_sha256=hashlib.sha256(raw).hexdigest(),
                   index_bytes=len(raw), tile_count=len(cells)), raw


@unittest.skipUnless(HAS_RASTER, "requires the topography extra")
class CopernicusProviderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        policy = load_topography_source_policy(ROOT)
        glo30, glo90 = policy.sources
        self.glo30, raw30 = fixture_source(glo30, [(7, 45)])
        self.glo90, raw90 = fixture_source(glo90, [(7, 45), (8, 45)])
        self.policy = TopographySourcePolicy((self.glo30, self.glo90), policy.sha256, policy.version)
        (self.root / "indexes").mkdir(parents=True)
        (self.root / "indexes" / (self.glo30.index_sha256 + ".txt")).write_bytes(raw30)
        (self.root / "indexes" / (self.glo90.index_sha256 + ".txt")).write_bytes(raw90)
        self.stage_tile(self.glo30, (7, 45), lambda row, column: 1000.0 + column - row, invalid=(10, 10))

    def stage_tile(self, source, cell, height, *, size=120, invalid=None):
        import numpy as np
        from rasterio.io import MemoryFile
        from rasterio.transform import from_origin

        lon, lat = cell
        values = np.fromfunction(lambda r, c: height(r, c), (size, size), dtype="float32").astype("float32")
        mask = np.full((size, size), 255, dtype="uint8")
        if invalid is not None:
            mask[invalid] = 0
        with MemoryFile() as memory:
            with memory.open(driver="GTiff", width=size, height=size, count=1, dtype="float32",
                             crs="EPSG:4326", transform=from_origin(lon, lat + 1, 1 / size, 1 / size)) as dataset:
                dataset.write(values, 1)
                dataset.write_mask(mask)
            data = memory.read()
        digest = hashlib.sha256(data).hexdigest()
        (self.root / "blobs").mkdir(exist_ok=True)
        (self.root / "receipts").mkdir(exist_ok=True)
        (self.root / "blobs" / (digest + ".tif")).write_bytes(data)
        url = source.tile_url(*cell)
        key = hashlib.sha256((source.id + "\n" + source.index_sha256 + "\n" + url).encode()).hexdigest()
        receipt = {"sourceId": source.id, "indexSha256": source.index_sha256, "url": url,
                   "bytes": len(data), "sha256": digest, "cell": list(cell)}
        (self.root / "receipts" / (key + ".json")).write_text(json.dumps(receipt, sort_keys=True))

    def provider(self, *, channel="development", enabled=True):
        return CopernicusRouteElevationProvider(self.policy, self.root, enabled=enabled, deployment_channel=channel)

    def test_gates_are_explicit(self):
        self.assertEqual(self.provider(enabled=False).unavailable_reason(), "dem-disabled")
        self.assertEqual(self.provider(channel="production").unavailable_reason(), "dem-not-production-approved")
        self.assertIsNone(self.provider().unavailable_reason())

    def test_bilinear_sampling_of_staged_tiles_and_honest_gaps(self):
        size = 120
        def point(row, column):
            return 46.0 - (row + 0.5) / size, 7.0 + (column + 0.5) / size
        points = [point(50, 50), point(50, 50.25), point(10, 10), (45.5, 8.5), (10.0, 10.0)]
        samples = self.provider().sample(points, installation_id="inst", deadline=time.monotonic() + 20)
        self.assertAlmostEqual(samples.values[0], 1000.0, places=3)
        self.assertAlmostEqual(samples.values[1], 1000.25, places=3)
        self.assertIsNone(samples.values[2])
        self.assertIsNone(samples.values[3])
        self.assertIsNone(samples.values[4])
        self.assertEqual(samples.diagnostics["unstagedTiles"], 1)
        self.assertEqual(samples.diagnostics["uncoveredPoints"], 1)
        self.assertEqual(samples.source.vertical_datum, "EGM2008 (EPSG:3855)")
        self.assertEqual(samples.source.native_resolution_m, 30.0)
        self.assertEqual(samples.source.surface_model, "dsm")
        self.assertEqual(samples.source.qualification, "development-unqualified")
        self.assertTrue(any("Copernicus WorldDEM-30" in line for line in samples.source.attribution))

    def test_missing_index_or_tiles_fail_without_downloading(self):
        for path in (self.root / "indexes").iterdir():
            path.unlink()
        with self.assertRaises(ElevationProviderError) as raised:
            self.provider().sample([(45.5, 7.5)], installation_id="inst", deadline=time.monotonic() + 20)
        self.assertEqual(raised.exception.code, "dem-index-not-staged")

    def test_corrupt_staged_tile_is_rejected(self):
        for blob in (self.root / "blobs").iterdir():
            blob.write_bytes(b"II*\x00corrupt")
        with self.assertRaises(ElevationProviderError) as raised:
            self.provider().sample([(45.5, 7.5)], installation_id="inst", deadline=time.monotonic() + 20)
        self.assertEqual(raised.exception.code, "dem-receipt-invalid")


if __name__ == "__main__":
    unittest.main()
