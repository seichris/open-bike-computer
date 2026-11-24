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
from map_platform.bicycle_route_service import (
    PROFILES,
    BicycleRouteBusyError,
    BicycleRouteRequestError,
    BicycleRouteService,
    parse_request,
    route_size_limits,
)
from map_platform.valhalla_bicycle import RouteSizeLimits
from map_platform.installations import InstallationCredentialStore
from map_platform.route_elevation_providers import ElevationProviderError, ProviderHTTPResponse

INSTALLATION_SECRET = "test-installation-secret-32-bytes-minimum"
UPSTREAM = "http://bicino-valhalla-test:8002"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "bicycle_detour"
# Recorded with Valhalla 3.9.2 (valhalla-scripted@sha256:b523b803…) from the
# verified GCC States graph; see test_bicycle_detour_api.
DUBAI_ROUTE = (FIXTURES / "valhalla-dubai-bicycle-route.json").read_bytes()
NO_PATH = (FIXTURES / "valhalla-no-path.json").read_bytes()
NO_EDGES = (FIXTURES / "valhalla-no-edges.json").read_bytes()
EXPECTED_COSTING = {
    "road": {"bicycle_type": "road", "use_roads": 0.5, "use_hills": 0.5, "use_ferry": 0.0,
             "avoid_bad_surfaces": 0.9},
    "gravel": {"bicycle_type": "cross", "use_roads": 0.2, "use_hills": 0.5, "use_ferry": 0.0,
               "avoid_bad_surfaces": 0.0},
    "everyday": {"bicycle_type": "hybrid", "use_roads": 0.25, "use_hills": 0.25, "use_ferry": 0.0,
                 "avoid_bad_surfaces": 0.5},
}


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


def route_payload(**overrides):
    payload = {
        "schema": "bicino-bicycle-route-request-v1",
        "requestId": str(uuid.uuid4()),
        "origin": {"latitudeE6": 25_206_600, "longitudeE6": 55_269_200},
        "destination": {"latitudeE6": 25_225_800, "longitudeE6": 55_263_100},
        "profile": "road",
        "locale": "en_AE",
    }
    payload.update(overrides)
    return payload


def detour_payload():
    return {
        "schema": "bicino-bicycle-detour-request-v1",
        "requestId": str(uuid.uuid4()),
        "origin": {"latitudeE6": 25_206_600, "longitudeE6": 55_269_200},
        "rejoin": {"latitudeE6": 25_225_800, "longitudeE6": 55_263_100},
        "routeSource": "mapkit",
    }


def oversized_trip(*, points: int = 2, maneuvers: int = 1) -> bytes:
    """A syntactically valid Valhalla trip with the given shape and maneuver counts."""

    # Precision-6 polyline: the first point, then zero deltas ("??") per point.
    shape = "_izlhA~rlgdF" + "??" * (points - 1)
    steps = [{"type": 8, "instruction": "Continue.", "begin_shape_index": 0, "end_shape_index": 0,
              "length": 0, "time": 0, "travel_mode": "bicycle"} for _ in range(maneuvers - 1)]
    steps.append({"type": 4, "instruction": "Arrive.", "begin_shape_index": 0, "end_shape_index": points - 1,
                  "length": 1, "time": 1, "travel_mode": "bicycle"})
    return json.dumps({"trip": {"status": 0, "summary": {"length": 1, "time": 1},
                                "legs": [{"shape": shape, "maneuvers": steps}]}}).encode()


def valhalla_error(code: int) -> bytes:
    return json.dumps({"error_code": code, "error": "synthetic", "status_code": 400,
                       "status": "Bad Request"}).encode()


class BicycleRouteAPITests(unittest.TestCase):
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
        self.client = self.make_client()
        self.credential = self.app_attest.issue_installation(self.client)

    def make_client(self) -> TestClient:
        return TestClient(create_app(
            app_attest_verifier=self.app_attest.verifier,
            bicycle_routing_transport=self.transport,
        ))

    def tearDown(self):
        self.client.close()
        self.environment.stop()
        self.temp.cleanup()

    def post(self, payload, credential=None, client=None, path="/v1/bicycle-routes"):
        credential = credential or self.credential
        return (client or self.client).post(
            path,
            params={"clientInstallationId": credential["clientInstallationId"]},
            headers={"X-Installation-Token": credential["clientInstallationToken"]},
            json=payload,
        )


class BicycleRouteEndpointTests(BicycleRouteAPITests):
    def test_ready_route_is_private_bicycle_only_attributed_and_echoes_the_profile(self):
        with self.assertLogs("map_platform", level="DEBUG") as logs:
            logging.getLogger("map_platform").debug("capture")
            response = self.post(route_payload(profile="gravel"))
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.headers["cache-control"], "private, no-store")
        body = response.json()
        self.assertEqual(set(body), {"schema", "status", "route", "reason"})
        self.assertEqual(body["schema"], "bicino-bicycle-route-response-v1")
        self.assertEqual(body["status"], "ready")
        self.assertIsNone(body["reason"])
        route = body["route"]
        self.assertEqual(set(route), {"provider", "travelMode", "distanceMeters", "durationSeconds",
                                      "pointsE6", "maneuvers", "profile"})
        self.assertEqual(route["provider"], {"id": "bicino.valhalla", "attribution": "© OpenStreetMap contributors"})
        self.assertEqual(route["travelMode"], "bicycle")
        self.assertEqual(route["profile"], "gravel")
        self.assertEqual(route["distanceMeters"], 3194.0)
        self.assertEqual(route["durationSeconds"], 680.8)
        self.assertEqual(len(route["pointsE6"]), 137)
        self.assertEqual(route["pointsE6"][0], [25_206_617, 55_269_262])
        self.assertEqual(len(route["maneuvers"]), 13)
        self.assertEqual(route["maneuvers"][0]["beginShapeIndex"], 0)
        self.assertEqual(route["maneuvers"][-1]["endShapeIndex"], 136)
        for previous, current in zip(route["maneuvers"], route["maneuvers"][1:]):
            self.assertEqual(previous["endShapeIndex"], current["beginShapeIndex"])
        # The upstream receives exactly two break locations, no heading, and
        # the bicycle costing with the profile's options.
        self.assertEqual(len(self.transport.requests), 1)
        upstream = self.transport.requests[0]
        self.assertEqual(upstream["url"], UPSTREAM + "/route")
        self.assertEqual(upstream["timeout"], 15)
        self.assertEqual(upstream["body"]["costing"], "bicycle")
        self.assertEqual(upstream["body"]["costing_options"], {"bicycle": EXPECTED_COSTING["gravel"]})
        self.assertEqual(upstream["body"]["locations"], [
            {"lat": 25.2066, "lon": 55.2692, "type": "break"},
            {"lat": 25.2258, "lon": 55.2631, "type": "break"},
        ])
        self.assertEqual(upstream["body"]["language"], "en-AE")
        self.assertEqual(upstream["body"]["directions_type"], "instructions")
        # Only outcome codes and the profile reach the logs.
        joined = "\n".join(logs.output)
        self.assertIn("bicycle route outcome=ready profile=gravel", joined)
        self.assertNotIn("25.2", joined)
        self.assertNotIn("55.26", joined)
        self.assertNotIn("25206", joined)
        self.assertNotIn("bicino-valhalla-test", joined)
        self.assertNotIn("bicino-valhalla-test", response.text)

    def test_each_profile_maps_to_its_valhalla_bicycle_costing(self):
        self.assertEqual({name: dict(options) for name, options in PROFILES.items()}, EXPECTED_COSTING)
        for profile in ("road", "gravel", "everyday"):
            with self.subTest(profile=profile):
                response = self.post(route_payload(profile=profile))
                self.assertEqual(response.status_code, 200, response.text)
                self.assertEqual(response.json()["route"]["profile"], profile)
                sent = self.transport.requests[-1]["body"]["costing_options"]
                self.assertEqual(sent, {"bicycle": EXPECTED_COSTING[profile]})
        # Valhalla 3.9.2 only recognises these lowercase types; anything else
        # silently becomes hybrid.
        self.assertEqual({options["bicycle_type"] for options in PROFILES.values()}, {"road", "cross", "hybrid"})

    def test_locale_defaults_and_is_normalised(self):
        payload = route_payload()
        del payload["locale"]
        self.assertEqual(self.post(payload).status_code, 200)
        self.assertEqual(self.transport.requests[-1]["body"]["language"], "en-US")

    def test_no_route_too_long_and_non_bicycle_answers_are_unavailable_outcomes(self):
        cases = [
            (400, NO_PATH, "no_bicycle_route"),
            (400, NO_EDGES, "no_bicycle_route"),
            (400, valhalla_error(170), "no_bicycle_route"),
            (400, valhalla_error(443), "no_bicycle_route"),
            (400, valhalla_error(154), "request_too_long"),
        ]
        # A long walk is not a bike route; neither is a car stretch.
        for mode, kilometres in (("pedestrian", 0.101), ("auto", 0.02)):
            trip = json.loads(DUBAI_ROUTE)
            trip["trip"]["legs"][0]["maneuvers"][3]["travel_mode"] = mode
            trip["trip"]["legs"][0]["maneuvers"][3]["length"] = kilometres
            cases.append((200, json.dumps(trip).encode(), "no_bicycle_route"))
        walk_only = json.loads(DUBAI_ROUTE)
        for maneuver in walk_only["trip"]["legs"][0]["maneuvers"]:
            maneuver["travel_mode"] = "pedestrian"
            maneuver["length"] = 0.05
        cases.append((200, json.dumps(walk_only).encode(), "no_bicycle_route"))
        for status, body, reason in cases:
            with self.subTest(reason=reason, body=body[:40]):
                self.transport.status = status
                self.transport.body = body
                with self.assertLogs("map_platform", level="INFO") as logs:
                    response = self.post(route_payload())
                self.assertEqual(response.status_code, 200, response.text)
                self.assertEqual(response.headers["cache-control"], "private, no-store")
                self.assertEqual(response.json(), {
                    "schema": "bicino-bicycle-route-response-v1",
                    "status": "unavailable",
                    "route": None,
                    "reason": reason,
                })
                self.assertNotIn("25.2", "\n".join(logs.output))

    def test_short_push_stretches_stay_in_the_bike_route(self):
        trip = json.loads(DUBAI_ROUTE)
        # Valhalla reports short push-the-bike stretches as pedestrian maneuvers.
        trip["trip"]["legs"][0]["maneuvers"][3]["travel_mode"] = "pedestrian"
        trip["trip"]["legs"][0]["maneuvers"][3]["length"] = 0.1
        self.transport.body = json.dumps(trip).encode()
        response = self.post(route_payload(profile="gravel"))
        self.assertEqual(response.status_code, 200, response.text)
        body = response.json()
        self.assertEqual(body["status"], "ready", body)
        self.assertEqual(body["route"]["travelMode"], "bicycle")
        self.assertEqual(body["route"]["maneuvers"][3]["lengthMeters"], 100.0)
        self.assertEqual(body["route"]["profile"], "gravel")

    def test_detours_never_accept_push_stretches(self):
        trip = json.loads(DUBAI_ROUTE)
        trip["trip"]["legs"][0]["maneuvers"][3]["travel_mode"] = "pedestrian"
        trip["trip"]["legs"][0]["maneuvers"][3]["length"] = 0.02
        self.transport.body = json.dumps(trip).encode()
        response = self.post(detour_payload(), path="/v1/bicycle-detours")
        self.assertEqual(response.json()["reason"], "no_bicycle_route")

    def test_answers_beyond_the_size_caps_are_terminal_request_too_long(self):
        limits = route_size_limits(150_000)
        self.assertEqual(limits, RouteSizeLimits(upstream_bytes=2 * 1024 * 1024, shape_points=45_000,
                                                 maneuvers=3_000))
        within = oversized_trip(points=limits.shape_points, maneuvers=limits.maneuvers)
        self.transport.body = within
        response = self.post(route_payload())
        self.assertEqual(response.json()["status"], "ready", response.text)
        self.assertEqual(len(response.json()["route"]["pointsE6"]), 45_000)
        cases = {
            "too-many-points": oversized_trip(points=limits.shape_points + 1),
            "too-many-maneuvers": oversized_trip(points=10, maneuvers=limits.maneuvers + 1),
            "response-too-large": within + b" " * (limits.upstream_bytes - len(within) + 1),
        }
        for reason, body in cases.items():
            with self.subTest(reason=reason):
                self.transport.body = body
                with self.assertLogs("map_platform", level="INFO") as logs:
                    response = self.post(route_payload())
                self.assertEqual(response.status_code, 200, response.text)
                self.assertEqual(response.json()["status"], "unavailable")
                self.assertEqual(response.json()["reason"], "request_too_long")
                self.assertIn(f"outcome=request_too_long reason={reason}", "\n".join(logs.output))
        self.assertEqual(self.transport.requests[-1]["body"]["costing"], "bicycle")

    def test_size_caps_scale_with_the_configured_separation_and_keep_the_detour_floor(self):
        self.assertEqual(route_size_limits(1_000), RouteSizeLimits())
        self.assertEqual(route_size_limits(500_000), RouteSizeLimits(upstream_bytes=5_120_000,
                                                                     shape_points=150_000, maneuvers=10_000))
        # Detours keep their own caps; their overflow is terminal too.
        self.transport.body = oversized_trip(points=20_001)
        detour = self.post(detour_payload(), path="/v1/bicycle-detours")
        self.assertEqual(detour.status_code, 200, detour.text)
        self.assertEqual(detour.json()["reason"], "request_too_long")

    def test_upstream_failures_are_retryable_service_errors(self):
        self.transport.failure = "provider-timeout"
        response = self.post(route_payload())
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["detail"]["code"], "bicycle_route_unavailable")
        self.assertEqual(response.headers["retry-after"], "30")
        self.assertEqual(response.headers["cache-control"], "private, no-store")
        self.assertNotIn("bicino-valhalla-test", response.text)
        self.transport.failure = None
        for status, body in ((500, b"{}"), (200, b"not json"), (400, valhalla_error(100)),
                             (200, json.dumps({"trip": {"legs": []}}).encode())):
            with self.subTest(status=status, body=body[:20]):
                self.transport.status = status
                self.transport.body = body
                response = self.post(route_payload())
                self.assertEqual(response.status_code, 503)
                self.assertEqual(response.json()["detail"]["code"], "bicycle_route_unavailable")

    def test_busy_route_slots_return_503_and_leave_detours_available(self):
        service = self.client.app.state.bicycle_route_service
        self.assertTrue(service._slots.acquire(blocking=False))
        self.assertTrue(service._slots.acquire(blocking=False))
        try:
            response = self.post(route_payload())
            self.assertEqual(response.status_code, 503)
            self.assertEqual(response.json()["detail"]["code"], "bicycle_route_busy")
            self.assertEqual(response.headers["retry-after"], "5")
            self.assertEqual(response.headers["cache-control"], "private, no-store")
            detour = self.post(detour_payload(), path="/v1/bicycle-detours")
            self.assertEqual(detour.status_code, 200, detour.text)
            self.assertEqual(detour.json()["status"], "ready")
        finally:
            service._slots.release()
            service._slots.release()
        self.assertEqual(self.post(route_payload()).status_code, 200)

    def test_credentials_attestation_and_validation_are_checked_before_routing(self):
        unauthenticated = self.client.post(
            "/v1/bicycle-routes",
            params={"clientInstallationId": self.credential["clientInstallationId"]},
            json=route_payload(),
        )
        self.assertEqual(unauthenticated.status_code, 401)
        wrong_token = self.post(route_payload(), {
            "clientInstallationId": self.credential["clientInstallationId"],
            "clientInstallationToken": self.credential["clientInstallationToken"][:-2] + "xx",
        })
        self.assertEqual(wrong_token.status_code, 401)
        installation_id, token = InstallationCredentialStore(INSTALLATION_SECRET).issue()
        unenrolled = self.post(route_payload(), {"clientInstallationId": installation_id,
                                                 "clientInstallationToken": token})
        self.assertEqual(unenrolled.status_code, 401)
        self.assertEqual(unenrolled.json()["detail"]["code"], "installation_attestation_required")
        payload_without_profile = route_payload()
        del payload_without_profile["profile"]
        invalid = [
            route_payload(schema="bicino-bicycle-detour-request-v1"),
            route_payload(requestId="not-a-uuid"),
            route_payload(requestId=str(uuid.uuid4()).upper()),
            route_payload(profile="mountain"),
            route_payload(profile="Road"),
            route_payload(profile=None),
            payload_without_profile,
            route_payload(locale="not a locale"),
            dict(route_payload(), routeSource="gpx"),
            dict(route_payload(), waypoints=[[1, 2]]),
            route_payload(origin={"latitudeE6": 25_206_600, "longitudeE6": 55_269_200, "courseDegrees": 1}),
            route_payload(origin={"latitudeE6": 25.2066, "longitudeE6": 55.2692}),
            route_payload(origin={"latitudeE6": True, "longitudeE6": 55_269_200}),
            route_payload(destination=None),
            route_payload(destination={"latitudeE6": 91_000_000, "longitudeE6": 0}),
            route_payload(destination={"latitudeE6": 25_206_650, "longitudeE6": 55_269_200}),
            route_payload(destination={"latitudeE6": 26_606_600, "longitudeE6": 55_269_200}),
        ]
        for payload in invalid:
            with self.subTest(payload=str(payload)[:100]):
                response = self.post(payload)
                self.assertEqual(response.status_code, 400, response.text)
                self.assertEqual(response.headers["cache-control"], "private, no-store")
                self.assertEqual(response.json()["detail"]["code"], "bicycle_route_invalid_request")
        self.assertEqual(self.transport.requests, [])

    def test_oversized_body_is_rejected_by_the_request_limit(self):
        payload = route_payload(locale="en-AE")
        payload["padding"] = "x" * (17 * 1024)
        response = self.post(payload)
        self.assertEqual(response.status_code, 413)
        self.assertEqual(self.transport.requests, [])

    def test_installation_and_ip_limits_apply_separately_from_detours(self):
        for variable, limit in (("MAP_PLATFORM_BICYCLE_ROUTE_LIMIT_PER_HOUR", "2"),
                                ("MAP_PLATFORM_BICYCLE_ROUTE_LIMIT_PER_DAY", "2"),
                                ("MAP_PLATFORM_BICYCLE_ROUTE_IP_LIMIT_PER_HOUR", "2")):
            # Counters persist in the data root, so each case gets its own.
            with self.subTest(variable=variable), tempfile.TemporaryDirectory() as data_root, \
                    patch.dict(os.environ, {variable: limit, "MAP_PLATFORM_DATA_ROOT": data_root,
                                            "MAP_PLATFORM_ARTIFACT_ROOT": str(Path(data_root) / "artifacts")}):
                client = self.make_client()
                credential = self.app_attest.issue_installation(client)
                statuses = [self.post(route_payload(), credential, client).status_code for _ in range(3)]
                detour = self.post(detour_payload(), credential, client, path="/v1/bicycle-detours")
                client.close()
                self.assertEqual(statuses, [200, 200, 429])
                self.assertEqual(detour.status_code, 200, detour.text)

    def test_capability_advertises_profiles_and_limits(self):
        response = self.client.get(
            "/v1/capabilities",
            params={"clientInstallationId": self.credential["clientInstallationId"]},
            headers={"X-Installation-Token": self.credential["clientInstallationToken"]},
        )
        self.assertEqual(response.status_code, 200, response.text)
        integrations = response.json()["integrations"]
        self.assertEqual(integrations["bicycleRoute"], {
            "available": True,
            "schema": "bicino-bicycle-route-request-v1",
            "provider": "bicino.valhalla",
            "attribution": "© OpenStreetMap contributors",
            "profiles": ["road", "gravel", "everyday"],
            "maximumSeparationMeters": 150000,
        })
        self.assertEqual(integrations["bicycleDetour"]["maximumSeparationMeters"], 15000)
        health = self.client.get("/healthz").json()
        self.assertEqual(health["bicycleRoute"], {"enabled": True, "provider": "bicino.valhalla"})
        self.assertNotIn("bicino-valhalla-test", json.dumps(health))


class ConfiguredLimitsTests(BicycleRouteAPITests):
    environment_overrides = {
        "MAP_PLATFORM_BICYCLE_ROUTE_MAX_SEPARATION_METERS": "200000",
        "MAP_PLATFORM_BICYCLE_ROUTE_TIMEOUT_SECONDS": "20",
    }

    def test_separation_and_timeout_follow_the_environment(self):
        response = self.post(route_payload(destination={"latitudeE6": 26_606_600, "longitudeE6": 55_269_200}))
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.transport.requests[-1]["timeout"], 20)
        capability = self.client.app.state.bicycle_route_service.capability()
        self.assertEqual(capability["maximumSeparationMeters"], 200000)


class TokenOnlyDevelopmentTests(BicycleRouteAPITests):
    environment_overrides = {"MAP_PLATFORM_BICYCLE_ROUTE_REQUIRE_APP_ATTEST": "0"}

    def test_token_only_installation_is_accepted_when_attestation_is_not_required(self):
        installation_id, token = InstallationCredentialStore(INSTALLATION_SECRET).issue()
        response = self.post(route_payload(), {"clientInstallationId": installation_id,
                                               "clientInstallationToken": token})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["status"], "ready")
        # The detour endpoint keeps its own App Attest requirement.
        detour = self.post(detour_payload(), {"clientInstallationId": installation_id,
                                              "clientInstallationToken": token}, path="/v1/bicycle-detours")
        self.assertEqual(detour.status_code, 401)


class DisabledRouteServiceTests(BicycleRouteAPITests):
    environment_overrides = {"MAP_PLATFORM_BICYCLE_ROUTE_ENABLED": "0"}

    def test_disabled_routes_report_unavailable_while_detours_stay_on(self):
        response = self.post(route_payload())
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["reason"], "service_disabled")
        self.assertEqual(self.transport.requests, [])
        capability = self.client.app.state.bicycle_route_service.capability()
        self.assertFalse(capability["available"])
        self.assertIsNone(capability["provider"])
        self.assertEqual(self.post(detour_payload(), path="/v1/bicycle-detours").json()["status"], "ready")


class UnconfiguredUpstreamTests(BicycleRouteAPITests):
    environment_overrides = {"MAP_PLATFORM_BICYCLE_ROUTING_UPSTREAM_URL": ""}

    def test_unconfigured_service_reports_unavailable_without_routing(self):
        response = self.post(route_payload())
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["reason"], "service_disabled")
        self.assertEqual(self.transport.requests, [])


class ServiceTests(unittest.TestCase):
    def test_concurrency_cap_is_enforced_inside_the_service(self):
        nested: list[BaseException] = []

        class ReentrantTransport(RoutingTransport):
            def request(self, **kwargs):
                try:
                    service.create_route(route_payload())
                except BicycleRouteBusyError as exc:
                    nested.append(exc)
                return super().request(**kwargs)

        service = BicycleRouteService(UPSTREAM, transport=ReentrantTransport(), maximum_concurrent=1)
        self.assertEqual(service.create_route(route_payload())["status"], "ready")
        self.assertEqual(len(nested), 1)

    def test_environment_bounds_are_validated(self):
        for variable, value in (("MAP_PLATFORM_BICYCLE_ROUTE_MAX_SEPARATION_METERS", "600000"),
                                ("MAP_PLATFORM_BICYCLE_ROUTE_MAX_CONCURRENT", "0"),
                                ("MAP_PLATFORM_BICYCLE_ROUTE_TIMEOUT_SECONDS", "1"),
                                ("MAP_PLATFORM_BICYCLE_ROUTE_MAX_PUSH_METERS", "501"),
                                ("MAP_PLATFORM_BICYCLE_ROUTE_ENABLED", "maybe")):
            with self.subTest(variable=variable), patch.dict(os.environ, {variable: value}), \
                    self.assertRaises(ValueError):
                BicycleRouteService.from_environment()

    def test_separation_limits(self):
        with self.assertRaises(BicycleRouteRequestError):
            parse_request(route_payload(destination={"latitudeE6": 25_206_650, "longitudeE6": 55_269_200}),
                          maximum_separation_meters=150_000)
        parsed = parse_request(route_payload(profile="everyday"), maximum_separation_meters=150_000)
        self.assertEqual(parsed.profile, "everyday")
        self.assertEqual(parsed.locale, "en-AE")


if __name__ == "__main__":
    unittest.main()


class StrictPushRouteTests(BicycleRouteAPITests):
    environment_overrides = {"MAP_PLATFORM_BICYCLE_ROUTE_MAX_PUSH_METERS": "0"}

    def test_push_allowance_can_be_turned_off(self):
        trip = json.loads(DUBAI_ROUTE)
        trip["trip"]["legs"][0]["maneuvers"][3]["travel_mode"] = "pedestrian"
        trip["trip"]["legs"][0]["maneuvers"][3]["length"] = 0.02
        self.transport.body = json.dumps(trip).encode()
        response = self.post(route_payload())
        self.assertEqual(response.json()["reason"], "no_bicycle_route")
