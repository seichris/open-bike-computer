import base64
import json
import os
import tempfile
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from unittest.mock import patch

from fastapi.testclient import TestClient

from map_platform.api import create_app
from map_platform.strava_client import StravaHTTPResponse


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
                "MAP_PLATFORM_STRAVA_ROUTE_VALIDATION_LIMIT_PER_HOUR": "10000",
                "MAP_PLATFORM_STRAVA_DISCONNECT_LIMIT_PER_HOUR": "10000",
            },
            clear=True,
        )
        self.environment.start()
        self.client = TestClient(create_app(strava_transport=self.transport))
        self.credential = self.client.post("/v1/installations").json()
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


if __name__ == "__main__":
    unittest.main()
