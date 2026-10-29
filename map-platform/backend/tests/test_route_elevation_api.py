from __future__ import annotations

import json
import logging
import os
import sqlite3
import tempfile
import threading
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient

from app_attest_support import AppAttestTestClient
from map_platform.api import create_app
from map_platform.installations import InstallationCredentialStore
from map_platform.route_elevation import build_route_geometry
from map_platform.route_elevation_providers import ProviderHTTPResponse

SECRET_KEY = "geoapify-api-key-sentinel-0123456789abcdef"
INSTALLATION_SECRET = "test-installation-secret-32-bytes-minimum"


class ElevationTransport:
    """Fake Geoapify endpoint that answers with a gentle synthetic climb."""

    def __init__(self):
        self.requests: list[dict] = []
        self.status = 200
        self.null_every = 0
        self.gate: threading.Event | None = None
        self.inside = 0
        self.condition = threading.Condition()

    def request(self, *, method, url, headers, body, timeout_seconds, maximum_body_bytes):
        with self.condition:
            self.requests.append({"url": url, "body": body})
            self.inside += 1
            self.condition.notify_all()
        if self.gate is not None:
            self.gate.wait(5)
        if self.status != 200:
            return ProviderHTTPResponse(self.status, {"retry-after": "120"}, b"{}", url)
        locations = json.loads(body)["locations"]
        results = []
        for index, (lon, lat) in enumerate(locations):
            interior = 0 < index < len(locations) - 1
            elevation = (None if self.null_every and (self.null_every == 1 or (interior and index % self.null_every == 1))
                         else 200.0 + index * 0.5)
            results.append({"location": {"lat": lat, "lon": lon}, "elevation": elevation, "units": "m"})
        return ProviderHTTPResponse(200, {"content-type": "application/json"},
                                    json.dumps({"results": results}).encode(), url)


def route_payload(*, points=60, source="gpx", **overrides):
    lat = [45_000_000 + index * 450 for index in range(points)]
    lon = [7_000_000] * points
    geometry = build_route_geometry(lat, lon)
    payload = {
        "schema": "bicino-route-elevation-request-v1",
        "requestId": str(uuid.uuid4()),
        "geometry": {
            "crs": "EPSG:4326",
            "coordinatesE6": [[x, y] for x, y in zip(lon, lat)],
            "digest": geometry.digest,
        },
        "travelMode": "cycling",
        "routeSource": source,
    }
    payload.update(overrides)
    return payload


class RouteElevationAPITests(unittest.TestCase):
    environment_overrides: dict[str, str] = {}

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo_root = Path(__file__).resolve().parents[3]
        self.transport = ElevationTransport()
        self.environment = patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_REPO_ROOT": str(self.repo_root),
                "MAP_PLATFORM_DATA_ROOT": self.temp.name,
                "MAP_PLATFORM_SOURCE_INDEX": str(
                    self.repo_root / "map-platform" / "backend" / "config" / "source-regions.json"
                ),
                "MAP_PLATFORM_INSTALLATION_SECRET": INSTALLATION_SECRET,
                "MAP_PLATFORM_DOWNLOAD_SECRET": "test-download-secret-32-bytes-minimum",
                "MAP_PLATFORM_ARTIFACT_STORE": "filesystem",
                "MAP_PLATFORM_ARTIFACT_ROOT": str(Path(self.temp.name) / "artifacts"),
                "MAP_PLATFORM_DEPLOYMENT_CHANNEL": "development",
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE": "disabled",
                "MAP_PLATFORM_PREPARATION_ESTIMATES_MODE": "off",
                "MAP_PLATFORM_PUBLIC_REQUEST_LIMIT_PER_MINUTE": "10000",
                "MAP_PLATFORM_INSTALLATION_ISSUE_LIMIT_PER_DAY": "10000",
                "MAP_PLATFORM_GEOAPIFY_API_KEY": SECRET_KEY,
                **self.environment_overrides,
            },
            clear=True,
        )
        self.environment.start()
        self.app_attest = AppAttestTestClient()
        self.client = TestClient(create_app(
            app_attest_verifier=self.app_attest.verifier,
            route_elevation_transport=self.transport,
        ))
        self.credential = self.app_attest.issue_installation(self.client)
        self.assertIsInstance(self.credential, dict)

    def tearDown(self):
        self.client.close()
        self.environment.stop()
        self.temp.cleanup()

    def post(self, payload, credential=None):
        credential = credential or self.credential
        return self.client.post(
            "/v1/route-elevation-profiles",
            params={"clientInstallationId": credential["clientInstallationId"]},
            headers={"X-Installation-Token": credential["clientInstallationToken"]},
            json=payload,
        )


class RouteElevationEndpointTests(RouteElevationAPITests):
    def test_ready_profile_is_private_bound_to_geometry_and_attributed(self):
        payload = route_payload()
        with self.assertLogs("map_platform", level="DEBUG") as logs:
            logging.getLogger("map_platform").debug("capture")
            response = self.post(payload)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.headers["cache-control"], "private, no-store")
        body = response.json()
        self.assertEqual(body["schema"], "bicino-route-elevation-response-v1")
        self.assertEqual(body["status"], "ready")
        profile = body["profile"]
        self.assertEqual(profile["geometry"]["digest"], payload["geometry"]["digest"])
        self.assertEqual(profile["source"]["id"], "geoapify-elevation-v1")
        self.assertIsNone(profile["source"]["verticalDatum"])
        self.assertIn("Powered by Geoapify (https://www.geoapify.com/)", profile["source"]["attribution"])
        self.assertEqual(profile["quality"]["status"], "complete")
        self.assertGreater(profile["statistics"]["totalAscentM"], 0)
        self.assertNotIn("coordinatesE6", json.dumps(body))
        self.assertEqual(body["attempts"][0]["provider"], "geoapify")
        self.assertNotIn(SECRET_KEY, response.text)
        self.assertNotIn(SECRET_KEY, "\n".join(logs.output))
        self.assertTrue(self.transport.requests[0]["url"].endswith("apiKey=" + SECRET_KEY))

    def test_immediate_retry_is_served_without_new_provider_credits(self):
        payload = route_payload()
        self.assertEqual(self.post(payload).status_code, 200)
        retry = dict(payload, requestId=str(uuid.uuid4()))
        self.assertEqual(self.post(retry).json()["status"], "ready")
        self.assertEqual(len(self.transport.requests), 1)

    def test_mapkit_route_without_heights_uses_the_terrain_provider(self):
        payload = route_payload(source="mapkit")
        response = self.post(payload)
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "ready")
        self.assertEqual(body["profile"]["geometry"]["digest"], payload["geometry"]["digest"])
        self.assertGreater(body["profile"]["statistics"]["totalAscentM"], 0)
        self.assertEqual(body["attempts"][0]["provider"], "geoapify")
        self.assertEqual(len(self.transport.requests), 1)
        self.assertNotIn("coordinatesE6", response.text)
        self.assertIn("no-store", response.headers["cache-control"])

    def test_credentials_attestation_and_validation_are_checked_before_work(self):
        unauthenticated = self.client.post("/v1/route-elevation-profiles",
                                           params={"clientInstallationId": self.credential["clientInstallationId"]},
                                           json=route_payload())
        self.assertEqual(unauthenticated.status_code, 401)
        installation_id, token = InstallationCredentialStore(INSTALLATION_SECRET).issue()
        unenrolled = self.post(route_payload(), {"clientInstallationId": installation_id,
                                                 "clientInstallationToken": token})
        self.assertEqual(unenrolled.status_code, 401)
        self.assertEqual(unenrolled.json()["detail"]["code"], "installation_attestation_required")
        invalid = [
            route_payload(source="strava"),
            route_payload(source="unknown"),
            route_payload(schema="v0"),
            route_payload(requestId="not-a-uuid"),
            route_payload(travelMode="car"),
            dict(route_payload(), extra=True),
            dict(route_payload(), geometry={"coordinatesE6": [[7_000_000, 45_000_000]] * 3, "digest": "0" * 64}),
        ]
        for payload in invalid:
            with self.subTest(payload=str(payload)[:60]):
                response = self.post(payload)
                self.assertEqual(response.status_code, 400)
                self.assertEqual(response.json()["detail"]["code"], "route_elevation_invalid_request")
        self.assertEqual(self.transport.requests, [])

    def test_oversized_body_is_rejected_by_the_request_limit(self):
        payload = route_payload()
        payload["geometry"]["coordinatesE6"] = [[7_000_000, 45_000_000]] * 80_000
        response = self.post(payload)
        self.assertEqual(response.status_code, 413)
        self.assertEqual(self.transport.requests, [])

    def test_provider_failures_are_explicit_unavailable_states(self):
        self.transport.status = 401
        body = self.post(route_payload()).json()
        self.assertEqual(body["status"], "unavailable")
        self.assertIsNone(body["profile"])
        self.assertEqual(
            [(a["provider"], a["status"], a["reason"]) for a in body["attempts"]],
            [("geoapify", "failed", "provider-unauthorized"), ("copernicus", "unavailable", "dem-disabled")],
        )
        self.transport.status = 429
        limited = self.post(route_payload(points=61)).json()
        self.assertEqual(limited["retryAfterSeconds"], 120)

    def test_partial_provider_result_is_returned_honestly(self):
        self.transport.null_every = 3
        body = self.post(route_payload(points=120)).json()
        self.assertEqual(body["status"], "ready")
        self.assertEqual(body["profile"]["quality"]["status"], "complete")
        self.assertTrue(body["profile"]["statistics"]["includesEstimated"])
        self.transport.null_every = 1
        unavailable = self.post(route_payload(points=121)).json()
        self.assertEqual(unavailable["status"], "unavailable")
        self.assertEqual(unavailable["attempts"][0]["status"], "unavailable")

    def test_capability_and_health_report_configuration_without_secrets(self):
        capabilities = self.client.get(
            "/v1/capabilities",
            params={"clientInstallationId": self.credential["clientInstallationId"]},
            headers={"X-Installation-Token": self.credential["clientInstallationToken"]},
        ).json()
        self.assertEqual(capabilities["integrations"]["routeElevation"]["providers"], ["geoapify"])
        self.assertTrue(capabilities["integrations"]["routeElevation"]["available"])
        health = self.client.get("/healthz")
        self.assertEqual(health.json()["routeElevation"]["geoapify"], {"configured": True})
        self.assertEqual(health.json()["routeElevation"]["copernicus"]["reason"], "dem-disabled")
        self.assertNotIn(SECRET_KEY, health.text + json.dumps(capabilities))

    def test_concurrent_work_is_bounded(self):
        self.transport.gate = threading.Event()
        results: list[int] = []
        threads = [threading.Thread(target=lambda points=points: results.append(
            self.post(route_payload(points=points)).status_code)) for points in (70, 71)]
        for thread in threads:
            thread.start()
        with self.transport.condition:
            self.assertTrue(self.transport.condition.wait_for(lambda: self.transport.inside >= 2, timeout=5))
        busy = self.post(route_payload(points=72))
        self.transport.gate.set()
        for thread in threads:
            thread.join(10)
        self.assertEqual(busy.status_code, 503)
        self.assertEqual(busy.json()["detail"]["code"], "route_elevation_busy")
        self.assertEqual(busy.headers["retry-after"], "5")
        self.assertEqual(sorted(results), [200, 200])


class RouteElevationQuotaTests(RouteElevationAPITests):
    environment_overrides = {
        "MAP_PLATFORM_ROUTE_ELEVATION_INSTALLATION_DAILY_CREDITS": "1",
        "MAP_PLATFORM_ROUTE_ELEVATION_LIMIT_PER_HOUR": "3",
    }

    def test_credit_budget_and_request_rate_are_enforced_persistently(self):
        self.assertEqual(self.post(route_payload(points=40)).json()["status"], "ready")
        exhausted = self.post(route_payload(points=41)).json()
        self.assertEqual(exhausted["status"], "unavailable")
        self.assertEqual(exhausted["attempts"][0]["reason"], "quota-exhausted")
        self.assertGreater(exhausted["retryAfterSeconds"], 0)
        self.assertEqual(len(self.transport.requests), 1)
        self.post(route_payload(points=42))
        limited = self.post(route_payload(points=43))
        self.assertEqual(limited.status_code, 429)
        with sqlite3.connect(Path(self.temp.name) / "route-elevation.sqlite3") as connection:
            rows = connection.execute("SELECT provider, credits FROM provider_credit_days").fetchall()
        self.assertEqual(rows, [("geoapify", 1)])
        self.assertNotIn(self.credential["clientInstallationId"], json.dumps(rows))


class RouteElevationDisabledTests(RouteElevationAPITests):
    environment_overrides = {"MAP_PLATFORM_ROUTE_ELEVATION_PROVIDERS": "copernicus"}

    def test_unconfigured_internal_fallback_never_pretends_to_succeed(self):
        body = self.post(route_payload()).json()
        self.assertEqual(body["status"], "unavailable")
        self.assertEqual(body["attempts"], [{"provider": "copernicus", "status": "unavailable", "reason": "dem-disabled"}])
        self.assertEqual(self.transport.requests, [])


if __name__ == "__main__":
    unittest.main()
