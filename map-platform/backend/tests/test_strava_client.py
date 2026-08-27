import json
import unittest
from urllib.parse import parse_qs, urlparse

from map_platform.strava_client import (
    MAXIMUM_STRAVA_GPX_BYTES,
    STRAVA_API_BASE,
    STRAVA_OAUTH_REVOKE_URL,
    STRAVA_OAUTH_TOKEN_URL,
    StravaClient,
    StravaClientError,
    StravaHTTPResponse,
)


class FakeTransport:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def request(self, **request):
        self.requests.append(request)
        response = self.responses.pop(0)
        if callable(response):
            return response(request)
        return response


def response(url, body, *, status=200, content_type="application/json"):
    if isinstance(body, dict):
        body = json.dumps(body).encode("utf-8")
    return StravaHTTPResponse(
        status_code=status,
        headers={"content-type": content_type},
        body=body,
        final_url=url,
    )


class StravaClientTests(unittest.TestCase):
    def client(self, transport):
        return StravaClient(
            client_id="12345",
            client_secret="client-secret",
            redirect_uri=(
                "https://maps-dev.8o.vc/v1/integrations/strava/oauth/callback"
            ),
            transport=transport,
        )

    def test_authorization_urls_are_fixed_and_do_not_expose_secret(self):
        client = self.client(FakeTransport([]))
        urls = client.authorization_urls("a" * 48)

        web = urlparse(urls.web_url)
        native = urlparse(urls.app_url)
        self.assertEqual(web.scheme, "https")
        self.assertEqual(web.netloc, "www.strava.com")
        self.assertEqual(web.path, "/oauth/mobile/authorize")
        self.assertEqual(native.scheme, "strava")
        self.assertEqual(native.netloc, "oauth")
        query = parse_qs(web.query)
        self.assertEqual(query["client_id"], ["12345"])
        self.assertEqual(query["scope"], ["read,read_all"])
        self.assertEqual(query["state"], ["a" * 48])
        self.assertNotIn("client-secret", urls.web_url)
        self.assertNotIn("client-secret", urls.app_url)

    def test_token_exchange_and_refresh_validate_rotated_tokens(self):
        exchange = response(
            STRAVA_OAUTH_TOKEN_URL,
            {
                "token_type": "Bearer",
                "access_token": "access-one",
                "refresh_token": "refresh-one",
                "expires_at": 2_000_000_000,
                "athlete": {"id": 123456},
            },
        )
        refresh = response(
            STRAVA_OAUTH_TOKEN_URL,
            {
                "token_type": "Bearer",
                "access_token": "access-two",
                "refresh_token": "refresh-two",
                "expires_at": 2_000_003_600,
            },
        )
        transport = FakeTransport([exchange, refresh])
        client = self.client(transport)

        exchanged = client.exchange_code("oauth-code")
        refreshed = client.refresh_token(exchanged.refresh_token)

        self.assertEqual(exchanged.athlete_id, "123456")
        self.assertIsNone(refreshed.athlete_id)
        self.assertEqual(refreshed.refresh_token, "refresh-two")
        self.assertEqual(transport.requests[0]["url"], STRAVA_OAUTH_TOKEN_URL)
        self.assertNotIn("client-secret", str(transport.requests[0]["headers"]))
        self.assertIn(b"client_secret=client-secret", transport.requests[0]["body"])

    def test_revoke_uses_current_basic_authenticated_refresh_token_flow(self):
        transport = FakeTransport([response(STRAVA_OAUTH_REVOKE_URL, b"")])
        client = self.client(transport)

        client.revoke("refresh-token")

        request = transport.requests[0]
        self.assertEqual(request["url"], STRAVA_OAUTH_REVOKE_URL)
        self.assertEqual(request["method"], "POST")
        self.assertEqual(
            request["headers"]["Content-Type"],
            "application/x-www-form-urlencoded",
        )
        self.assertTrue(request["headers"]["Authorization"].startswith("Basic "))
        self.assertNotIn("refresh-token", request["headers"]["Authorization"])
        self.assertEqual(
            parse_qs(request["body"].decode("ascii")),
            {
                "token": ["refresh-token"],
                "token_type_hint": ["refresh_token"],
            },
        )

    def test_route_metadata_and_gpx_use_only_fixed_paths_and_bearer_header(self):
        route_id = "3009840108578231836"
        metadata_url = f"{STRAVA_API_BASE}/routes/{route_id}"
        gpx_url = f"{metadata_url}/export_gpx"
        transport = FakeTransport(
            [
                response(
                    metadata_url,
                    {"id": int(route_id), "athlete": {"id": 44}, "type": 1},
                ),
                response(
                    gpx_url,
                    b"<gpx><rte></rte></gpx>",
                    content_type="application/gpx+xml; charset=utf-8",
                ),
            ]
        )
        client = self.client(transport)

        metadata = client.route_metadata(route_id, "access-token")
        gpx = client.export_gpx(route_id, "access-token")

        self.assertEqual(metadata.route_id, route_id)
        self.assertEqual(metadata.athlete_id, "44")
        self.assertEqual(metadata.route_type, 1)
        self.assertEqual(gpx, b"<gpx><rte></rte></gpx>")
        self.assertEqual(
            [item["url"] for item in transport.requests],
            [metadata_url, gpx_url],
        )
        self.assertTrue(
            all(
                item["headers"]["Authorization"] == "Bearer access-token"
                for item in transport.requests
            )
        )

    def test_route_identity_mismatch_and_redirect_fail_closed(self):
        route_id = "3009840108578231836"
        url = f"{STRAVA_API_BASE}/routes/{route_id}"
        mismatch = FakeTransport(
            [response(url, {"id": 1, "athlete": {"id": 2}, "type": 1})]
        )
        with self.assertRaises(StravaClientError) as mismatch_error:
            self.client(mismatch).route_metadata(route_id, "token")
        self.assertEqual(mismatch_error.exception.code, "strava_invalid_response")

        redirected = FakeTransport(
            [
                StravaHTTPResponse(
                    status_code=200,
                    headers={"content-type": "application/json"},
                    body=b"{}",
                    final_url="https://evil.invalid/route",
                )
            ]
        )
        with self.assertRaises(StravaClientError) as redirect_error:
            self.client(redirected).route_metadata(route_id, "token")
        self.assertEqual(redirect_error.exception.code, "strava_invalid_response")

        wrong_type = FakeTransport(
            [
                response(
                    url,
                    {"id": int(route_id), "athlete": {"id": 2}, "type": 1},
                    content_type="text/html",
                )
            ]
        )
        with self.assertRaises(StravaClientError) as content_type_error:
            self.client(wrong_type).route_metadata(route_id, "token")
        self.assertEqual(
            content_type_error.exception.code,
            "strava_invalid_response",
        )

    def test_gpx_limit_content_type_and_rate_limit_are_typed(self):
        route_id = "3009840108578231836"
        url = f"{STRAVA_API_BASE}/routes/{route_id}/export_gpx"
        oversized = FakeTransport(
            [
                response(
                    url,
                    b"x" * (MAXIMUM_STRAVA_GPX_BYTES + 1),
                    content_type="application/gpx+xml",
                )
            ]
        )
        with self.assertRaises(StravaClientError) as too_large:
            self.client(oversized).export_gpx(route_id, "token")
        self.assertEqual(too_large.exception.code, "strava_route_too_large")
        self.assertEqual(too_large.exception.status_code, 413)

        wrong_type = FakeTransport([response(url, b"<html/>", content_type="text/html")])
        with self.assertRaises(StravaClientError) as invalid:
            self.client(wrong_type).export_gpx(route_id, "token")
        self.assertEqual(invalid.exception.code, "strava_invalid_response")

        limited = FakeTransport(
            [
                StravaHTTPResponse(
                    status_code=429,
                    headers={"retry-after": "120", "content-type": "application/json"},
                    body=b"{}",
                    final_url=url,
                )
            ]
        )
        with self.assertRaises(StravaClientError) as rate_limited:
            self.client(limited).export_gpx(route_id, "token")
        self.assertEqual(rate_limited.exception.code, "strava_rate_limited")
        self.assertEqual(rate_limited.exception.retry_after_seconds, 120)

    def test_invalid_route_ids_are_rejected_before_transport(self):
        transport = FakeTransport([])
        client = self.client(transport)
        for route_id in ("0", "-1", "1/2", "9223372036854775808", "abc"):
            with self.subTest(route_id=route_id):
                with self.assertRaises(StravaClientError) as raised:
                    client.route_metadata(route_id, "token")
                self.assertEqual(raised.exception.code, "invalid_strava_route_id")
        self.assertEqual(transport.requests, [])


if __name__ == "__main__":
    unittest.main()
