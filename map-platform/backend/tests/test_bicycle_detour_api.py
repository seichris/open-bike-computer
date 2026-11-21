from __future__ import annotations

import json
import logging
import os
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient

from app_attest_support import AppAttestTestClient
from map_platform.api import create_app
from map_platform.bicycle_detour_service import (
    BicycleDetourRequestError,
    BicycleDetourService,
    decode_polyline6,
    parse_request,
)
from map_platform.installations import InstallationCredentialStore
from map_platform.route_elevation_providers import ElevationProviderError, ProviderHTTPResponse

INSTALLATION_SECRET = "test-installation-secret-32-bytes-minimum"
UPSTREAM = "http://bicino-valhalla-test:8002"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "bicycle_detour"
# Recorded with Valhalla 3.9.2 (valhalla-scripted@sha256:b523b803…) from the
# verified GCC States graph (archive SHA-256 a1911ad2…, source
# gcc-states-261117.osm.pbf), networking disabled.
DUBAI_ROUTE = (FIXTURES / "valhalla-dubai-bicycle-route.json").read_bytes()
NO_PATH = (FIXTURES / "valhalla-no-path.json").read_bytes()
NO_EDGES = (FIXTURES / "valhalla-no-edges.json").read_bytes()


class RoutingTransport:
    """Fake internal Valhalla service."""

    def __init__(self):
        self.requests: list[dict] = []
        self.status = 200
        self.body = DUBAI_ROUTE
        self.failure: str | None = None

    def request(self, *, method, url, headers, body, timeout_seconds, maximum_body_bytes):
        self.requests.append({"method": method, "url": url, "body": json.loads(body), "timeout": timeout_seconds})
        if self.failure:
            raise ElevationProviderError(self.failure)
        return ProviderHTTPResponse(self.status, {"content-type": "application/json"}, self.body, url)


def detour_payload(**overrides):
    payload = {
        "schema": "bicino-bicycle-detour-request-v1",
        "requestId": str(uuid.uuid4()),
        "origin": {"latitudeE6": 25_206_600, "longitudeE6": 55_269_200, "courseDegrees": 182.5},
        "rejoin": {"latitudeE6": 25_225_800, "longitudeE6": 55_263_100},
        "routeSource": "gpx",
        "locale": "en_AE",
    }
    payload.update(overrides)
    return payload


class BicycleDetourAPITests(unittest.TestCase):
    environment_overrides: dict[str, str] = {}

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo_root = Path(__file__).resolve().parents[3]
        self.transport = RoutingTransport()
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
                "MAP_PLATFORM_BICYCLE_ROUTING_UPSTREAM_URL": UPSTREAM,
                **self.environment_overrides,
            },
            clear=True,
        )
        self.environment.start()
        self.app_attest = AppAttestTestClient()
        self.client = TestClient(create_app(
            app_attest_verifier=self.app_attest.verifier,
            bicycle_routing_transport=self.transport,
        ))
        self.credential = self.app_attest.issue_installation(self.client)

    def tearDown(self):
        self.client.close()
        self.environment.stop()
        self.temp.cleanup()

    def post(self, payload, credential=None):
        credential = credential or self.credential
        return self.client.post(
            "/v1/bicycle-detours",
            params={"clientInstallationId": credential["clientInstallationId"]},
            headers={"X-Installation-Token": credential["clientInstallationToken"]},
            json=payload,
        )


class BicycleDetourEndpointTests(BicycleDetourAPITests):
    def test_ready_detour_is_private_bicycle_only_and_attributed(self):
        with self.assertLogs("map_platform", level="DEBUG") as logs:
            logging.getLogger("map_platform").debug("capture")
            response = self.post(detour_payload())
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.headers["cache-control"], "private, no-store")
        body = response.json()
        self.assertEqual(body["schema"], "bicino-bicycle-detour-response-v1")
        self.assertEqual(body["status"], "ready")
        route = body["route"]
        self.assertEqual(route["provider"], {"id": "bicino.valhalla", "attribution": "© OpenStreetMap contributors"})
        self.assertEqual(route["travelMode"], "bicycle")
        self.assertEqual(route["distanceMeters"], 3194.0)
        self.assertEqual(len(route["pointsE6"]), 137)
        self.assertEqual(route["pointsE6"][0], [25_206_617, 55_269_262])
        self.assertEqual(len(route["maneuvers"]), 13)
        self.assertEqual(route["maneuvers"][-1]["type"], 5)
        self.assertEqual(route["maneuvers"][0]["beginShapeIndex"], 0)
        self.assertEqual(route["maneuvers"][-1]["endShapeIndex"], 136)
        # The upstream receives exactly two locations and the bicycle costing.
        self.assertEqual(len(self.transport.requests), 1)
        upstream = self.transport.requests[0]
        self.assertEqual(upstream["url"], UPSTREAM + "/route")
        self.assertEqual(upstream["body"]["costing"], "bicycle")
        self.assertEqual(set(upstream["body"]["costing_options"]), {"bicycle"})
        self.assertEqual(len(upstream["body"]["locations"]), 2)
        self.assertEqual(upstream["body"]["locations"][0]["heading"], 182)
        self.assertEqual(upstream["body"]["language"], "en-AE")
        # No coordinates, routes or the upstream address reach the logs.
        joined = "\n".join(logs.output)
        self.assertNotIn("25.2066", joined)
        self.assertNotIn("55.26", joined)
        self.assertNotIn("bicino-valhalla-test", joined)
        self.assertNotIn("bicino-valhalla-test", response.text)

    def test_strava_and_mapkit_sources_are_accepted_with_their_provenance(self):
        for source in ("strava", "mapkit"):
            with self.subTest(source=source):
                response = self.post(detour_payload(routeSource=source))
                self.assertEqual(response.status_code, 200, response.text)
                self.assertEqual(response.json()["status"], "ready")

    def test_no_bicycle_route_and_outside_graph_are_unavailable_outcomes(self):
        for body, reason in ((NO_PATH, "no_bicycle_route"), (NO_EDGES, "no_bicycle_route")):
            with self.subTest(reason=reason, body=body[:40]):
                self.transport.status = 400
                self.transport.body = body
                response = self.post(detour_payload())
                self.assertEqual(response.status_code, 200, response.text)
                self.assertEqual(response.json(), {
                    "schema": "bicino-bicycle-detour-response-v1",
                    "status": "unavailable",
                    "route": None,
                    "reason": reason,
                })

    def test_non_bicycle_maneuvers_are_never_returned(self):
        trip = json.loads(DUBAI_ROUTE)
        trip["trip"]["legs"][0]["maneuvers"][3]["travel_mode"] = "drive"
        self.transport.body = json.dumps(trip).encode()
        response = self.post(detour_payload())
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "unavailable")
        self.assertEqual(response.json()["reason"], "no_bicycle_route")

    def test_upstream_failures_are_retryable_service_errors(self):
        self.transport.failure = "provider-timeout"
        response = self.post(detour_payload())
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["detail"]["code"], "bicycle_detour_unavailable")
        self.assertEqual(response.headers["retry-after"], "30")
        self.assertEqual(response.headers["cache-control"], "private, no-store")
        self.transport.failure = None
        self.transport.status = 500
        self.transport.body = b"{}"
        self.assertEqual(self.post(detour_payload()).status_code, 503)
        self.transport.status = 200
        self.transport.body = b"not json"
        self.assertEqual(self.post(detour_payload()).status_code, 503)

    def test_credentials_attestation_and_validation_are_checked_before_routing(self):
        unauthenticated = self.client.post(
            "/v1/bicycle-detours",
            params={"clientInstallationId": self.credential["clientInstallationId"]},
            json=detour_payload(),
        )
        self.assertEqual(unauthenticated.status_code, 401)
        installation_id, token = InstallationCredentialStore(INSTALLATION_SECRET).issue()
        unenrolled = self.post(detour_payload(), {"clientInstallationId": installation_id,
                                                  "clientInstallationToken": token})
        self.assertEqual(unenrolled.status_code, 401)
        self.assertEqual(unenrolled.json()["detail"]["code"], "installation_attestation_required")
        invalid = [
            detour_payload(schema="v0"),
            detour_payload(requestId="not-a-uuid"),
            detour_payload(routeSource="unknown"),
            detour_payload(locale="not a locale"),
            dict(detour_payload(), route=[[1, 2]]),
            detour_payload(origin={"latitudeE6": 25_206_600, "longitudeE6": 55_269_200, "extra": 1}),
            detour_payload(origin={"latitudeE6": 25.2066, "longitudeE6": 55.2692}),
            detour_payload(origin={"latitudeE6": 25_206_600, "longitudeE6": 55_269_200, "courseDegrees": 360}),
            detour_payload(rejoin={"latitudeE6": 25_206_600, "longitudeE6": 55_269_200}),
            detour_payload(rejoin={"latitudeE6": 26_206_600, "longitudeE6": 55_269_200}),
            detour_payload(rejoin={"latitudeE6": 91_000_000, "longitudeE6": 0}),
        ]
        for payload in invalid:
            with self.subTest(payload=str(payload)[:80]):
                response = self.post(payload)
                self.assertEqual(response.status_code, 400, response.text)
                self.assertEqual(response.json()["detail"]["code"], "bicycle_detour_invalid_request")
        self.assertEqual(self.transport.requests, [])

    def test_installation_limits_apply(self):
        with patch.dict(os.environ, {"MAP_PLATFORM_BICYCLE_DETOUR_LIMIT_PER_HOUR": "2"}):
            client = TestClient(create_app(
                app_attest_verifier=self.app_attest.verifier,
                bicycle_routing_transport=self.transport,
            ))
            credential = self.app_attest.issue_installation(client)
            statuses = []
            for _ in range(3):
                statuses.append(client.post(
                    "/v1/bicycle-detours",
                    params={"clientInstallationId": credential["clientInstallationId"]},
                    headers={"X-Installation-Token": credential["clientInstallationToken"]},
                    json=detour_payload(),
                ).status_code)
            client.close()
        self.assertEqual(statuses, [200, 200, 429])

    def test_capability_reports_the_provider(self):
        response = self.client.get(
            "/v1/capabilities",
            params={"clientInstallationId": self.credential["clientInstallationId"]},
            headers={"X-Installation-Token": self.credential["clientInstallationToken"]},
        )
        self.assertEqual(response.status_code, 200, response.text)
        capability = response.json()["integrations"]["bicycleDetour"]
        self.assertTrue(capability["available"])
        self.assertEqual(capability["provider"], "bicino.valhalla")
        self.assertEqual(capability["schema"], "bicino-bicycle-detour-request-v1")
        health = self.client.get("/healthz").json()
        self.assertEqual(health["bicycleDetour"], {"enabled": True, "provider": "bicino.valhalla"})
        self.assertNotIn("bicino-valhalla-test", json.dumps(health))


class TokenOnlyDevelopmentTests(BicycleDetourAPITests):
    environment_overrides = {"MAP_PLATFORM_BICYCLE_DETOUR_REQUIRE_APP_ATTEST": "0"}

    def test_token_only_installation_is_accepted_when_attestation_is_not_required(self):
        installation_id, token = InstallationCredentialStore(INSTALLATION_SECRET).issue()
        response = self.post(detour_payload(), {"clientInstallationId": installation_id,
                                                "clientInstallationToken": token})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["status"], "ready")
        bad = self.post(detour_payload(), {"clientInstallationId": installation_id,
                                           "clientInstallationToken": token[:-2] + "xx"})
        self.assertEqual(bad.status_code, 401)


class DisabledServiceTests(BicycleDetourAPITests):
    environment_overrides = {"MAP_PLATFORM_BICYCLE_ROUTING_UPSTREAM_URL": ""}

    def test_unconfigured_service_reports_unavailable_without_routing(self):
        response = self.post(detour_payload())
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["reason"], "service_disabled")
        self.assertEqual(self.transport.requests, [])


class ParsingTests(unittest.TestCase):
    def test_polyline6_round_trip_of_known_values(self):
        # Google's reference example scaled to precision 6.
        self.assertEqual(decode_polyline6("_izlhA~rlgdF_{geC~ywl@_kwzCn`{nI"),
                         [(38_500_000, -120_200_000), (40_700_000, -120_950_000), (43_252_000, -126_453_000)])
        with self.assertRaises(ValueError):
            decode_polyline6("_izlhA~rlgd")

    def test_upstream_url_must_be_an_origin(self):
        for value in ("ftp://valhalla:8002", "http://user:pw@valhalla:8002", "http://valhalla:8002/route",
                      "http://valhalla:8002?x=1"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                BicycleDetourService(value)
        self.assertTrue(BicycleDetourService("http://valhalla:8002/").enabled)

    def test_separation_limits(self):
        with self.assertRaises(BicycleDetourRequestError):
            parse_request(detour_payload(rejoin={"latitudeE6": 25_206_650, "longitudeE6": 55_269_200}),
                          maximum_separation_meters=15_000)
        parsed = parse_request(detour_payload(), maximum_separation_meters=15_000)
        self.assertEqual(parsed.route_source, "gpx")
        self.assertEqual(parsed.locale, "en-AE")


if __name__ == "__main__":
    unittest.main()
