import base64
import json
import os
import tempfile
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from unittest.mock import patch

from fastapi.testclient import TestClient

from app_attest_support import AppAttestTestClient
from map_platform.api import create_app
from map_platform.strava_client import StravaHTTPResponse
from map_platform.strava_development import DEVELOPMENT_HEADER


ROUTE_ID = "3009840108578231836"


class FakeTransport:
    def __init__(self):
        self.requests = []
        self.responses = []

    def queue_json(self, document, *, status=200):
        self.responses.append((status, "application/json", json.dumps(document).encode()))

    def queue_gpx(self, data=b"<gpx><rte></rte></gpx>"):
        self.responses.append((200, "application/gpx+xml", data))

    def request(self, **request):
        self.requests.append(request)
        status, content_type, body = self.responses.pop(0)
        return StravaHTTPResponse(
            status_code=status,
            headers={"content-type": content_type},
            body=body,
            final_url=request["url"],
        )


class StravaAPITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo_root = Path(__file__).resolve().parents[3]
        self.transport = FakeTransport()
        self.environment = patch.dict(
            os.environ,
            {
                "MAP_PLATFORM_REPO_ROOT": str(self.repo_root),
                "MAP_PLATFORM_DATA_ROOT": self.temp.name,
                "MAP_PLATFORM_SOURCE_INDEX": str(
                    self.repo_root
                    / "map-platform"
                    / "backend"
                    / "config"
                    / "source-regions.json"
                ),
                "MAP_PLATFORM_INSTALLATION_SECRET": (
                    "test-installation-secret-32-bytes-minimum"
                ),
                "MAP_PLATFORM_DOWNLOAD_SECRET": "test-download-secret-32-bytes-minimum",
                "MAP_PLATFORM_ARTIFACT_STORE": "filesystem",
                "MAP_PLATFORM_ARTIFACT_ROOT": str(Path(self.temp.name) / "artifacts"),
                "MAP_PLATFORM_DEPLOYMENT_CHANNEL": "development",
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE": "disabled",
                "MAP_PLATFORM_PREPARATION_ESTIMATES_MODE": "off",
                "MAP_PLATFORM_PUBLIC_REQUEST_LIMIT_PER_MINUTE": "10000",
                "MAP_PLATFORM_INSTALLATION_ISSUE_LIMIT_PER_DAY": "10000",
                "MAP_PLATFORM_STRAVA_ENABLED": "1",
                "MAP_PLATFORM_STRAVA_CLIENT_ID": "12345",
                "MAP_PLATFORM_STRAVA_CLIENT_SECRET": "client-secret",
                "MAP_PLATFORM_STRAVA_REDIRECT_URI": (
                    "https://maps-dev.8o.vc/v1/integrations/strava/oauth/callback"
                ),
                "MAP_PLATFORM_STRAVA_TOKEN_KEY_ID": "test-key",
                "MAP_PLATFORM_STRAVA_TOKEN_KEY_BASE64": base64.b64encode(
                    b"k" * 32
                ).decode("ascii"),
                "MAP_PLATFORM_STRAVA_PREVIOUS_TOKEN_KEYS": "",
                "MAP_PLATFORM_STRAVA_CONNECTION_IDLE_TTL_DAYS": "30",
                "MAP_PLATFORM_STRAVA_OAUTH_START_LIMIT_PER_HOUR": "10000",
                "MAP_PLATFORM_STRAVA_ROUTE_IMPORT_LIMIT_PER_HOUR": "10000",
                "MAP_PLATFORM_STRAVA_ROUTE_LIST_LIMIT_PER_HOUR": "10000",
                "MAP_PLATFORM_STRAVA_ROUTE_VALIDATION_LIMIT_PER_HOUR": "10000",
                "MAP_PLATFORM_STRAVA_DISCONNECT_LIMIT_PER_HOUR": "10000",
            },
            clear=True,
        )
        self.environment.start()
        self.app_attest = AppAttestTestClient()
        self.client = TestClient(
            create_app(
                strava_transport=self.transport,
                app_attest_verifier=self.app_attest.verifier,
            )
        )
        self.credential = self.app_attest.issue_installation(self.client)
        self.assertIsInstance(self.credential, dict)
        self.params = {
            "clientInstallationId": self.credential["clientInstallationId"]
        }
        self.headers = {
            "X-Installation-Token": self.credential["clientInstallationToken"]
        }

    def tearDown(self):
        self.client.close()
        self.environment.stop()
        self.temp.cleanup()

    def connect(self, *, scope="read,read_all"):
        started = self.client.post(
            "/v1/integrations/strava/oauth/start",
            params=self.params,
            headers=self.headers,
        )
        self.assertEqual(started.status_code, 200)
        start = started.json()
        state = parse_qs(urlparse(start["webAuthorizationUrl"]).query)["state"][0]
        self.transport.queue_json(
            {
                "token_type": "Bearer",
                "access_token": "access-token",
                "refresh_token": "refresh-token",
                "expires_at": 2_100_000_000,
                "athlete": {"id": 44},
            }
        )
        callback = self.client.get(
            "/v1/integrations/strava/oauth/callback",
            params={"state": state, "code": "oauth-code", "scope": scope},
        )
        self.assertEqual(callback.status_code, 200)
        self.assertIn("result=connected", callback.text)
        return start

    def test_shared_registration_restricts_development_and_shares_owner_grant(self):
        prefix = "/v1/integrations/strava"
        bridge_secret = "a" * 43
        bridge_environment = {
            "MAP_PLATFORM_STRAVA_DEVELOPMENT_BRIDGE_SECRET": bridge_secret,
            "MAP_PLATFORM_STRAVA_DEVELOPMENT_INSTALLATION": self.params["clientInstallationId"],
        }
        other_credential = self.app_attest.issue_installation(self.client)
        other_params = {"clientInstallationId": other_credential["clientInstallationId"]}
        other_headers = {"X-Installation-Token": other_credential["clientInstallationToken"]}

        with patch.dict(os.environ, bridge_environment | {
            "MAP_PLATFORM_DATA_ROOT": str(Path(self.temp.name) / "production"),
            "MAP_PLATFORM_DEPLOYMENT_CHANNEL": "production",
            "MAP_PLATFORM_STRAVA_REDIRECT_URI": f"https://maps.8o.vc{prefix}/oauth/callback",
            "MAP_PLATFORM_STRAVA_DEVELOPMENT_ATHLETE": "44",
        }):
            production_app = create_app(
                strava_transport=self.transport, app_attest_verifier=self.app_attest.verifier
            )
        with patch.dict(os.environ, bridge_environment | {
            "MAP_PLATFORM_STRAVA_ENABLED": "0",
            "MAP_PLATFORM_STRAVA_CLIENT_ID": "",
            "MAP_PLATFORM_STRAVA_CLIENT_SECRET": "",
            "MAP_PLATFORM_STRAVA_REDIRECT_URI": "",
            "MAP_PLATFORM_STRAVA_TOKEN_KEY_ID": "",
            "MAP_PLATFORM_STRAVA_TOKEN_KEY_BASE64": "",
        }):
            development_app = create_app(
                strava_transport=self.transport, app_attest_verifier=self.app_attest.verifier
            )

        def queue_oauth(athlete_id, access_token):
            self.transport.queue_json({
                "token_type": "Bearer",
                "access_token": access_token,
                "refresh_token": f"refresh-{access_token}",
                "expires_at": 2_100_000_000,
                "athlete": {"id": athlete_id},
            })

        def finish_oauth(production, started, athlete_id, access_token, *, scope="read,read_all"):
            self.assertEqual(started.status_code, 200)
            start = started.json()
            query = parse_qs(urlparse(start["webAuthorizationUrl"]).query)
            self.assertEqual(query["redirect_uri"], [f"https://maps.8o.vc{prefix}/oauth/callback"])
            queue_oauth(athlete_id, access_token)
            return production.get(
                f"{prefix}/oauth/callback",
                params={"state": query["state"][0], "code": "code", "scope": scope},
            )

        with TestClient(production_app) as production, TestClient(development_app) as development:
            prod_credential = self.app_attest.issue_installation(production)
            prod_params = {"clientInstallationId": prod_credential["clientInstallationId"]}
            prod_headers = {"X-Installation-Token": prod_credential["clientInstallationToken"]}

            def route_to_production(transport, **request):
                target = urlparse(request["url"])
                self.assertEqual((target.scheme, target.netloc), ("https", "maps.8o.vc"))
                self.assertEqual(dict(request["headers"]), {DEVELOPMENT_HEADER: bridge_secret})
                reply = production.request(
                    request["method"], f"{target.path}?{target.query}", headers=request["headers"]
                )
                return StravaHTTPResponse(
                    reply.status_code, dict(reply.headers), reply.content, request["url"]
                )

            with patch("map_platform.strava_development.UrllibStravaTransport.request",
                       autospec=True, side_effect=route_to_production):
                for params, headers, enabled in (
                    (self.params, self.headers, True), (other_params, other_headers, False)
                ):
                    cap = development.get("/v1/capabilities", params=params, headers=headers)
                    self.assertEqual(cap.status_code, 200)
                    self.assertEqual(cap.json()["integrations"]["stravaRouteImport"]["enabled"], enabled)
                not_owner = development.post(
                    f"{prefix}/oauth/start", params=other_params, headers=other_headers
                )
                self.assertEqual(not_owner.status_code, 404)
                forged = production.post(
                    f"{prefix}/oauth/start", params=self.params,
                    headers={DEVELOPMENT_HEADER: "incorrect"},
                )
                self.assertEqual(forged.status_code, 404)
                wrong_installation = production.post(
                    f"{prefix}/oauth/start", params=other_params,
                    headers={DEVELOPMENT_HEADER: bridge_secret},
                )
                self.assertEqual(wrong_installation.status_code, 404)

                other_login = development.post(
                    f"{prefix}/oauth/start", params=self.params, headers=self.headers
                )
                rejected = finish_oauth(production, other_login, 45, "other-account")
                self.assertIn("bikecomputer-dev://strava/oauth-complete?result=failed", rejected.text)
                self.assertFalse(development.get(
                    f"{prefix}/connection", params=self.params, headers=self.headers
                ).json()["connected"])

                dev_login = development.post(
                    f"{prefix}/oauth/start", params=self.params, headers=self.headers
                )
                self.assertEqual(dev_login.json()["callbackScheme"], "bikecomputer-dev")
                self.assertIn("bikecomputer-dev://strava/oauth-complete?result=connected",
                              finish_oauth(production, dev_login, 44, "dev-login", scope="read").text)
                self.assertFalse(production.get(
                    f"{prefix}/connection", params=prod_params, headers=prod_headers
                ).json()["connected"])

                prod_login = production.post(
                    f"{prefix}/oauth/start", params=prod_params, headers=prod_headers
                )
                self.assertIn("bikecomputer://strava/oauth-complete?result=connected",
                              finish_oauth(production, prod_login, 44, "prod-login").text)
                dev_status = development.get(
                    f"{prefix}/connection", params=self.params, headers=self.headers
                ).json()
                self.assertEqual(dev_status["grantedScopes"], ["read"])
                self.assertFalse(dev_status["canReadPrivateRoutes"])
                self.assertEqual(development.get(
                    f"{prefix}/routes", params=self.params, headers=self.headers
                ).status_code, 403)
                route = {"id": int(ROUTE_ID), "athlete": {"id": 44}, "type": 1}
                self.transport.queue_json(route | {"private": True})
                denied = development.post(
                    f"{prefix}/routes/{ROUTE_ID}/gpx",
                    params=self.params, headers=self.headers,
                )
                self.assertEqual(denied.status_code, 404)
                self.assertEqual(denied.json()["code"], "strava_route_unavailable")
                self.transport.queue_json(route | {"private": False})
                self.assertEqual(development.post(
                    f"{prefix}/routes/{ROUTE_ID}/validate",
                    params=self.params, headers=self.headers,
                ).status_code, 200)

                reconnect = development.post(
                    f"{prefix}/oauth/start", params=self.params, headers=self.headers
                )
                self.assertIn("bikecomputer-dev://strava/oauth-complete?result=connected",
                              finish_oauth(production, reconnect, 44, "latest-login").text)
                self.transport.queue_json([])
                listed = development.get(f"{prefix}/routes", params=self.params, headers=self.headers)
                self.assertEqual(listed.status_code, 200)
                self.assertEqual(listed.headers["cache-control"], "private, no-store")
                self.assertEqual(self.transport.requests[-1]["headers"]["Authorization"],
                                 "Bearer latest-login")
                before = len(self.transport.requests)
                disconnected = development.delete(
                    f"{prefix}/connection", params=self.params, headers=self.headers
                )
                self.assertEqual(disconnected.json(), {"disconnected": True, "revocationPending": False})
                self.assertEqual(len(self.transport.requests), before)
                self.assertTrue(production.get(
                    f"{prefix}/connection", params=prod_params, headers=prod_headers
                ).json()["connected"])
                last_link = production.delete(
                    f"{prefix}/connection", params=prod_params, headers=prod_headers
                )
                self.assertEqual(last_link.json(), {"disconnected": True, "revocationPending": True})
                self.assertEqual(len(self.transport.requests), before)
                self.transport.queue_json({}, status=200)
                maint = production_app.state.strava_integration.maintenance()
                self.assertEqual(maint["completedRevocations"], 1)
                self.assertEqual(len(self.transport.requests), before + 1)
                self.assertTrue(self.transport.requests[-1]["url"].endswith("/oauth/revoke"))

    def test_capability_oauth_status_import_validate_and_disconnect(self):
        capabilities = self.client.get(
            "/v1/capabilities",
            params=self.params,
            headers=self.headers,
        )
        self.assertEqual(capabilities.status_code, 200)
        strava = capabilities.json()["integrations"]["stravaRouteImport"]
        self.assertTrue(strava["enabled"])
        self.assertEqual(strava["maximumCacheSeconds"], 604800)

        start = self.connect()
        self.assertEqual(start["callbackScheme"], "bikecomputer-dev")
        self.assertNotIn("client-secret", json.dumps(start))
        status = self.client.get(
            "/v1/integrations/strava/connection",
            params=self.params,
            headers=self.headers,
        )
        self.assertEqual(status.status_code, 200)
        self.assertEqual(status.headers["Cache-Control"], "private, no-store")
        self.assertTrue(status.json()["connected"])
        self.assertNotIn("athlete", status.text.lower())
        self.assertNotIn("access-token", status.text)

        self.transport.queue_json(
            [
                {
                    "id": int(ROUTE_ID),
                    "name": "Morning Ride",
                    "distance": 42_195.5,
                    "elevation_gain": 612.25,
                    "type": 1,
                    "private": True,
                    "description": "server-only upstream field",
                },
                {
                    "id": 101,
                    "name": "Trail Run",
                    "distance": 10_000,
                    "elevation_gain": 240,
                    "type": 2,
                },
            ]
        )
        routes = self.client.get(
            "/v1/integrations/strava/routes",
            params={**self.params, "page": 1},
            headers=self.headers,
        )
        self.assertEqual(routes.status_code, 200)
        self.assertEqual(routes.headers["Cache-Control"], "private, no-store")
        self.assertEqual(
            routes.json(),
            {
                "page": 1,
                "nextPage": None,
                "routes": [
                    {
                        "routeId": ROUTE_ID,
                        "name": "Morning Ride",
                        "distanceMeters": 42_195.5,
                        "elevationGainMeters": 612.25,
                        "type": "ride",
                    },
                    {
                        "routeId": "101",
                        "name": "Trail Run",
                        "distanceMeters": 10_000.0,
                        "elevationGainMeters": 240.0,
                        "type": "run",
                    },
                ],
            },
        )
        self.assertNotIn("athlete", routes.text.lower())
        self.assertNotIn("token", routes.text.lower())
        list_request = self.transport.requests[-1]
        self.assertIn("/athletes/44/routes?", list_request["url"])
        self.assertIn("page=1", list_request["url"])
        self.assertIn("per_page=200", list_request["url"])

        self.transport.queue_json(
            {"id": int(ROUTE_ID), "athlete": {"id": 44}, "type": 1}
        )
        self.transport.queue_gpx()
        imported = self.client.post(
            f"/v1/integrations/strava/routes/{ROUTE_ID}/gpx",
            params=self.params,
            headers=self.headers,
        )
        self.assertEqual(imported.status_code, 200)
        self.assertEqual(imported.headers["X-Bicino-Route-Provider"], "strava.route")
        self.assertEqual(imported.headers["X-Bicino-External-Route-ID"], ROUTE_ID)
        self.assertEqual(imported.headers["Cache-Control"], "private, no-store")

        self.transport.queue_json(
            {"id": int(ROUTE_ID), "athlete": {"id": 44}, "type": 1}
        )
        validated = self.client.post(
            f"/v1/integrations/strava/routes/{ROUTE_ID}/validate",
            params=self.params,
            headers=self.headers,
        )
        self.assertEqual(validated.status_code, 200)
        self.assertEqual(set(validated.json()), {"available", "checkedAt"})

        self.transport.responses.append((204, "application/json", b""))
        disconnected = self.client.delete(
            "/v1/integrations/strava/connection",
            params=self.params,
            headers=self.headers,
        )
        self.assertEqual(disconnected.status_code, 200)
        self.assertTrue(disconnected.json()["disconnected"])
        status = self.client.get(
            "/v1/integrations/strava/connection",
            params=self.params,
            headers=self.headers,
        )
        self.assertFalse(status.json()["connected"])

    def test_every_non_callback_endpoint_requires_installation_auth(self):
        endpoints = (
            ("post", "/v1/integrations/strava/oauth/start"),
            ("get", "/v1/integrations/strava/connection"),
            ("delete", "/v1/integrations/strava/connection"),
            ("get", "/v1/integrations/strava/routes"),
            ("post", f"/v1/integrations/strava/routes/{ROUTE_ID}/gpx"),
            ("post", f"/v1/integrations/strava/routes/{ROUTE_ID}/validate"),
        )
        for method, path in endpoints:
            with self.subTest(path=path):
                response = getattr(self.client, method)(path, params=self.params)
                self.assertEqual(response.status_code, 401)

    def test_callback_rejects_duplicate_or_inconsistent_parameters_without_exchange(self):
        started = self.client.post(
            "/v1/integrations/strava/oauth/start",
            params=self.params,
            headers=self.headers,
        ).json()
        state = parse_qs(urlparse(started["webAuthorizationUrl"]).query)["state"][0]
        invalid = self.client.get(
            "/v1/integrations/strava/oauth/callback"
            f"?state={state}&state={state}&code=one&scope=read",
        )
        self.assertEqual(invalid.status_code, 200)
        self.assertIn("result=invalid", invalid.text)
        self.assertEqual(self.transport.requests, [])

        inconsistent = self.client.get(
            "/v1/integrations/strava/oauth/callback",
            params={
                "state": state,
                "code": "one",
                "scope": "read",
                "error": "access_denied",
            },
        )
        self.assertIn("result=invalid", inconsistent.text)
        self.assertEqual(self.transport.requests, [])

    def test_typed_upstream_failures_do_not_expose_response_body(self):
        self.connect()
        sentinel = "upstream-private-body"
        self.transport.responses.append(
            (404, "application/json", sentinel.encode("utf-8"))
        )
        unavailable = self.client.post(
            f"/v1/integrations/strava/routes/{ROUTE_ID}/gpx",
            params=self.params,
            headers=self.headers,
        )
        self.assertEqual(unavailable.status_code, 404)
        self.assertEqual(unavailable.json()["code"], "strava_route_unavailable")
        self.assertNotIn(sentinel, unavailable.text)

    def test_route_listing_maps_expired_authorization_and_missing_scope(self):
        self.connect()
        self.transport.queue_json({}, status=401)
        expired = self.client.get(
            "/v1/integrations/strava/routes",
            params=self.params,
            headers=self.headers,
        )
        self.assertEqual(expired.status_code, 401)
        self.assertEqual(expired.json()["code"], "strava_not_connected")
        status = self.client.get(
            "/v1/integrations/strava/connection",
            params=self.params,
            headers=self.headers,
        )
        self.assertFalse(status.json()["connected"])

        self.connect(scope="read")
        request_count = len(self.transport.requests)
        missing_scope = self.client.get(
            "/v1/integrations/strava/routes",
            params=self.params,
            headers=self.headers,
        )
        self.assertEqual(missing_scope.status_code, 403)
        self.assertEqual(missing_scope.json()["code"], "strava_scope_required")
        self.assertEqual(len(self.transport.requests), request_count)

    def test_route_listing_rejects_out_of_range_page_before_upstream(self):
        self.connect()
        request_count = len(self.transport.requests)
        invalid = self.client.get(
            "/v1/integrations/strava/routes",
            params={**self.params, "page": 101},
            headers=self.headers,
        )
        self.assertEqual(invalid.status_code, 422)
        self.assertEqual(len(self.transport.requests), request_count)


if __name__ == "__main__":
    unittest.main()
