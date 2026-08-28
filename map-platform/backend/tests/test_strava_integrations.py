import base64
import os
import sqlite3
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from unittest.mock import patch

from map_platform.strava_client import (
    StravaAuthorizationURLs,
    StravaAthleteRoute,
    StravaAthleteRoutePage,
    StravaClientError,
    StravaRouteMetadata,
    StravaTokenResponse,
)
from map_platform.strava_integrations import (
    STRAVA_PENDING_REVOCATION_SECONDS,
    STRAVA_ROUTE_CACHE_SECONDS,
    StravaConnectionRecord,
    StravaIntegrationConfig,
    StravaIntegrationError,
    StravaIntegrationService,
    StravaIntegrationStore,
    StravaTokenBundle,
    StravaTokenKeyRing,
)


INSTALLATION_ID = "inst_v2_" + "a" * 32
ROUTE_ID = "3009840108578231836"


class MutableClock:
    def __init__(self, value=1_900_000_000.0):
        self.value = value

    def __call__(self):
        return self.value


class FakeStravaClient:
    def __init__(self):
        self.exchange_result = StravaTokenResponse(
            access_token="access-one",
            refresh_token="refresh-one",
            expires_at=2_000_000_000,
            athlete_id="44",
        )
        self.refresh_result = StravaTokenResponse(
            access_token="access-two",
            refresh_token="refresh-two",
            expires_at=2_100_000_000,
            athlete_id=None,
        )
        self.metadata = StravaRouteMetadata(
            route_id=ROUTE_ID,
            athlete_id="44",
            route_type=1,
        )
        self.gpx = b"<gpx><rte><rtept lat='1' lon='2'/></rte></gpx>"
        self.routes_page = StravaAthleteRoutePage(
            page=1,
            next_page=None,
            routes=(
                StravaAthleteRoute(
                    route_id=ROUTE_ID,
                    name="Morning Ride",
                    distance_meters=42_195.5,
                    elevation_gain_meters=612.0,
                    route_kind="ride",
                ),
            ),
        )
        self.exchange_error = None
        self.refresh_error = None
        self.metadata_error = None
        self.gpx_error = None
        self.routes_error = None
        self.revoke_error = None
        self.refresh_count = 0
        self.metadata_count = 0
        self.routes_calls = []
        self.revoke_count = 0
        self._lock = threading.Lock()

    def authorization_urls(self, state):
        return StravaAuthorizationURLs(
            app_url=f"strava://oauth/mobile/authorize?state={state}",
            web_url=f"https://www.strava.com/oauth/mobile/authorize?state={state}",
        )

    def exchange_code(self, code):
        if self.exchange_error:
            raise self.exchange_error
        return self.exchange_result

    def refresh_token(self, refresh_token):
        with self._lock:
            self.refresh_count += 1
        if self.refresh_error:
            raise self.refresh_error
        return self.refresh_result

    def route_metadata(self, route_id, access_token):
        with self._lock:
            self.metadata_count += 1
        if self.metadata_error:
            raise self.metadata_error
        return self.metadata

    def export_gpx(self, route_id, access_token):
        if self.gpx_error:
            raise self.gpx_error
        return self.gpx

    def athlete_routes(self, athlete_id, access_token, *, page):
        self.routes_calls.append((athlete_id, access_token, page))
        if self.routes_error:
            raise self.routes_error
        return self.routes_page

    def revoke(self, access_token):
        with self._lock:
            self.revoke_count += 1
        if self.revoke_error:
            raise self.revoke_error


def key_ring(key_byte=1, *, current_id="key-current", previous=None):
    keys = {current_id: bytes([key_byte]) * 32}
    keys.update(previous or {})
    return StravaTokenKeyRing(current_key_id=current_id, keys=keys)


def config(ring, *, enabled=True):
    return StravaIntegrationConfig(
        enabled=enabled,
        deployment_channel="development",
        client_id="12345",
        client_secret="secret",
        redirect_uri=(
            "https://maps-dev.8o.vc/v1/integrations/strava/oauth/callback"
        ),
        return_scheme="bikecomputer-dev",
        key_ring=ring,
        connection_idle_days=30,
    )


def bundle(*, expires_at=2_000_000_000):
    return StravaTokenBundle(
        athlete_id="44",
        granted_scopes=("read", "read_all"),
        access_token="access-secret",
        refresh_token="refresh-secret",
        expires_at=expires_at,
    )


class StravaConfigurationTests(unittest.TestCase):
    strava_environment = {
        "MAP_PLATFORM_STRAVA_ENABLED": "0",
        "MAP_PLATFORM_STRAVA_CLIENT_ID": "",
        "MAP_PLATFORM_STRAVA_CLIENT_SECRET": "",
        "MAP_PLATFORM_STRAVA_REDIRECT_URI": "",
        "MAP_PLATFORM_STRAVA_TOKEN_KEY_ID": "",
        "MAP_PLATFORM_STRAVA_TOKEN_KEY_BASE64": "",
        "MAP_PLATFORM_STRAVA_PREVIOUS_TOKEN_KEYS": "",
        "MAP_PLATFORM_STRAVA_CONNECTION_IDLE_TTL_DAYS": "30",
    }

    def test_disabled_configuration_needs_no_strava_secrets(self):
        with patch.dict(os.environ, self.strava_environment, clear=False):
            value = StravaIntegrationConfig.from_environment("development")
        self.assertFalse(value.enabled)
        self.assertIsNone(value.key_ring)
        self.assertEqual(value.return_scheme, "bikecomputer-dev")

    def test_enabled_configuration_is_channel_bound_and_key_is_exact(self):
        environment = {
            **self.strava_environment,
            "MAP_PLATFORM_STRAVA_ENABLED": "1",
            "MAP_PLATFORM_STRAVA_CLIENT_ID": "12345",
            "MAP_PLATFORM_STRAVA_CLIENT_SECRET": "client-secret",
            "MAP_PLATFORM_STRAVA_REDIRECT_URI": (
                "https://maps-dev.8o.vc/v1/integrations/strava/oauth/callback"
            ),
            "MAP_PLATFORM_STRAVA_TOKEN_KEY_ID": "current",
            "MAP_PLATFORM_STRAVA_TOKEN_KEY_BASE64": base64.b64encode(
                b"a" * 32
            ).decode("ascii"),
            "MAP_PLATFORM_STRAVA_PREVIOUS_TOKEN_KEYS": (
                "previous=" + base64.b64encode(b"b" * 32).decode("ascii")
            ),
        }
        with patch.dict(os.environ, environment, clear=False):
            value = StravaIntegrationConfig.from_environment("development")
        self.assertTrue(value.enabled)
        self.assertEqual(set(value.key_ring.keys), {"current", "previous"})

        environment["MAP_PLATFORM_STRAVA_REDIRECT_URI"] = (
            "https://maps.8o.vc/v1/integrations/strava/oauth/callback"
        )
        with patch.dict(os.environ, environment, clear=False):
            with self.assertRaises(ValueError):
                StravaIntegrationConfig.from_environment("development")

        environment["MAP_PLATFORM_STRAVA_REDIRECT_URI"] = (
            "https://maps-dev.8o.vc/v1/integrations/strava/oauth/callback"
        )
        environment["MAP_PLATFORM_STRAVA_TOKEN_KEY_BASE64"] = base64.b64encode(
            b"short"
        ).decode("ascii")
        with patch.dict(os.environ, environment, clear=False):
            with self.assertRaises(ValueError):
                StravaIntegrationConfig.from_environment("development")


class StravaIntegrationStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "strava.sqlite3"
        self.clock = MutableClock()
        self.store = StravaIntegrationStore(
            self.path,
            key_ring=key_ring(),
            clock=self.clock,
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_tokens_are_encrypted_and_ciphertext_is_installation_bound(self):
        self.store.put_connection(
            INSTALLATION_ID,
            bundle(),
            connected_at=self.clock(),
        )
        raw = self.path.read_bytes()
        self.assertNotIn(b"access-secret", raw)
        self.assertNotIn(b"refresh-secret", raw)
        self.assertNotIn(b'"athleteId":"44"', raw)

        record = self.store.connection(INSTALLATION_ID)
        self.assertEqual(record.bundle, bundle())
        with sqlite3.connect(self.path) as connection:
            connection.execute(
                "UPDATE connections SET installation_id = ? WHERE installation_id = ?",
                ("inst_v2_" + "b" * 32, INSTALLATION_ID),
            )
        with self.assertRaises(StravaIntegrationError):
            self.store.connection("inst_v2_" + "b" * 32)

    def test_key_rotation_reencrypts_on_read_without_changing_token_revision(self):
        old_ring = key_ring(1, current_id="old")
        old_store = StravaIntegrationStore(
            self.path,
            key_ring=old_ring,
            clock=self.clock,
        )
        old_store.put_connection(INSTALLATION_ID, bundle(), connected_at=self.clock())
        rotated = StravaIntegrationStore(
            self.path,
            key_ring=key_ring(
                2,
                current_id="new",
                previous={"old": bytes([1]) * 32},
            ),
            clock=self.clock,
        )

        record = rotated.connection(INSTALLATION_ID)

        self.assertEqual(record.token_revision, 1)
        with sqlite3.connect(self.path) as connection:
            stored_key_id = connection.execute(
                "SELECT key_id FROM connections WHERE installation_id = ?",
                (INSTALLATION_ID,),
            ).fetchone()[0]
        self.assertEqual(stored_key_id, "new")

    def test_oauth_state_is_hashed_expiring_and_one_time(self):
        state = "s" * 48
        self.store.create_oauth_session(
            session_id="oauth_" + "x" * 32,
            state=state,
            installation_id=INSTALLATION_ID,
            deployment_channel="development",
            created_at=self.clock(),
            expires_at=self.clock() + 600,
        )
        self.assertNotIn(state.encode("ascii"), self.path.read_bytes())
        session = self.store.consume_oauth_session(state)
        self.assertEqual(session.installation_id, INSTALLATION_ID)
        with self.assertRaises(StravaIntegrationError):
            self.store.consume_oauth_session(state)

        expired_state = "e" * 48
        self.store.create_oauth_session(
            session_id="oauth_" + "y" * 32,
            state=expired_state,
            installation_id=INSTALLATION_ID,
            deployment_channel="development",
            created_at=self.clock(),
            expires_at=self.clock() + 1,
        )
        self.clock.value += 2
        with self.assertRaises(StravaIntegrationError):
            self.store.consume_oauth_session(expired_state)

    def test_repeated_pending_mark_does_not_extend_revocation_deadline(self):
        self.store.put_connection(
            INSTALLATION_ID,
            bundle(),
            connected_at=self.clock(),
        )
        self.store.mark_pending_revocation(INSTALLATION_ID)
        self.clock.value += 10 * 24 * 60 * 60
        self.store.mark_pending_revocation(INSTALLATION_ID)
        self.clock.value += 20 * 24 * 60 * 60

        expired = self.store.expired_pending_revocation_ids(
            cutoff=self.clock() - STRAVA_PENDING_REVOCATION_SECONDS
        )

        self.assertEqual(expired, (INSTALLATION_ID,))


class StravaIntegrationServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.clock = MutableClock()
        self.ring = key_ring()
        self.store = StravaIntegrationStore(
            Path(self.temp.name) / "strava.sqlite3",
            key_ring=self.ring,
            clock=self.clock,
        )
        self.client = FakeStravaClient()
        self.service = StravaIntegrationService(
            config=config(self.ring),
            store=self.store,
            client=self.client,
            clock=self.clock,
        )

    def tearDown(self):
        self.temp.cleanup()

    def connect(self):
        self.store.put_connection(
            INSTALLATION_ID,
            bundle(expires_at=int(self.clock()) + 3_600),
            connected_at=self.clock(),
        )

    def test_oauth_connection_and_scope_status(self):
        start = self.service.start_oauth(INSTALLATION_ID)
        state = parse_qs(urlparse(start.web_authorization_url).query)["state"][0]

        callback = self.service.complete_oauth(
            state=state,
            code="oauth-code",
            scope="read,read_all",
            denied=False,
        )
        status = self.service.connection_status(INSTALLATION_ID)

        self.assertEqual(callback.session_id, start.session_id)
        self.assertEqual(callback.result, "connected")
        self.assertTrue(status["connected"])
        self.assertTrue(status["canReadPrivateRoutes"])
        replay = self.service.complete_oauth(
            state=state,
            code="oauth-code",
            scope="read,read_all",
            denied=False,
        )
        self.assertEqual(replay.result, "invalid")

    def test_fetch_and_validation_allow_other_athletes_cycling_route(self):
        self.connect()
        self.client.metadata = StravaRouteMetadata(
            route_id=ROUTE_ID,
            athlete_id="45",
            route_type=1,
        )
        download = self.service.fetch_route(INSTALLATION_ID, ROUTE_ID)
        validation = self.service.validate_route(INSTALLATION_ID, ROUTE_ID)

        self.assertEqual(download.gpx, self.client.gpx)
        self.assertEqual(
            _timestamp(download.delete_after) - _timestamp(download.fetched_at),
            STRAVA_ROUTE_CACHE_SECONDS,
        )
        self.assertEqual(validation.route_id, ROUTE_ID)

    def test_athlete_routes_require_read_all_and_keep_credentials_server_side(self):
        self.connect()

        page = self.service.athlete_routes(INSTALLATION_ID, page=1)

        self.assertEqual(page, self.client.routes_page)
        self.assertEqual(
            self.client.routes_calls,
            [("44", "access-secret", 1)],
        )

        self.store.put_connection(
            INSTALLATION_ID,
            StravaTokenBundle(
                athlete_id="44",
                granted_scopes=("read",),
                access_token="access-secret",
                refresh_token="refresh-secret",
                expires_at=int(self.clock()) + 3_600,
            ),
            connected_at=self.clock(),
        )
        with self.assertRaises(StravaIntegrationError) as scope_error:
            self.service.athlete_routes(INSTALLATION_ID, page=1)
        self.assertEqual(scope_error.exception.code, "strava_scope_required")
        self.assertEqual(len(self.client.routes_calls), 1)

    def test_athlete_route_token_rejection_disconnects_connection(self):
        self.connect()
        self.client.routes_error = StravaClientError(
            "strava_token_rejected",
            status_code=401,
        )
        with self.assertRaises(StravaIntegrationError) as raised:
            self.service.athlete_routes(INSTALLATION_ID, page=1)
        self.assertEqual(raised.exception.code, "strava_not_connected")
        self.assertFalse(self.store.connection_exists(INSTALLATION_ID))

    def test_fetch_and_validation_reject_non_cycling_route(self):
        self.connect()
        self.client.metadata = StravaRouteMetadata(
            route_id=ROUTE_ID,
            athlete_id="45",
            route_type=2,
        )
        with self.assertRaises(StravaIntegrationError) as type_error:
            self.service.validate_route(INSTALLATION_ID, ROUTE_ID)
        self.assertEqual(type_error.exception.code, "strava_route_not_importable")

    def test_concurrent_expired_token_use_performs_one_rotating_refresh(self):
        self.store.put_connection(
            INSTALLATION_ID,
            bundle(expires_at=int(self.clock()) - 1),
            connected_at=self.clock(),
        )
        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(
                executor.map(
                    lambda _: self.service.validate_route(INSTALLATION_ID, ROUTE_ID),
                    range(2),
                )
            )

        self.assertEqual(len(results), 2)
        self.assertEqual(self.client.refresh_count, 1)
        refreshed = self.store.connection(INSTALLATION_ID)
        self.assertEqual(refreshed.bundle.refresh_token, "refresh-two")
        self.assertEqual(refreshed.token_revision, 2)

    def test_authoritative_token_rejection_disconnects_connection(self):
        self.connect()
        self.client.metadata_error = StravaClientError(
            "strava_token_rejected",
            status_code=401,
        )
        with self.assertRaises(StravaIntegrationError) as raised:
            self.service.validate_route(INSTALLATION_ID, ROUTE_ID)
        self.assertEqual(raised.exception.code, "strava_not_connected")
        self.assertFalse(self.store.connection_exists(INSTALLATION_ID))

    def test_disconnect_is_immediate_and_retryable_revocation_is_maintained(self):
        self.connect()
        self.client.revoke_error = StravaClientError(
            "strava_temporarily_unavailable",
            status_code=503,
        )
        result = self.service.disconnect(INSTALLATION_ID)
        self.assertTrue(result["disconnected"])
        self.assertTrue(result["revocationPending"])
        self.assertIsNone(self.store.connection(INSTALLATION_ID))
        self.assertEqual(self.store.pending_revocation_ids(), (INSTALLATION_ID,))

        self.client.revoke_error = None
        maintenance = self.service.maintenance()
        self.assertEqual(maintenance["completedRevocations"], 1)
        self.assertEqual(maintenance["expiredPendingRevocations"], 0)
        self.assertFalse(self.store.connection_exists(INSTALLATION_ID))

    def test_failed_revocation_credential_is_deleted_at_thirty_day_limit(self):
        self.connect()
        self.client.revoke_error = StravaClientError(
            "strava_temporarily_unavailable",
            status_code=503,
        )
        self.service.disconnect(INSTALLATION_ID)
        self.clock.value += STRAVA_PENDING_REVOCATION_SECONDS

        maintenance = self.service.maintenance()

        self.assertEqual(maintenance["completedRevocations"], 0)
        self.assertEqual(maintenance["expiredPendingRevocations"], 1)
        self.assertEqual(maintenance["pendingRevocations"], 0)
        self.assertFalse(self.store.connection_exists(INSTALLATION_ID))

    def test_expired_revocation_credential_is_deleted_without_strava_client(self):
        self.connect()
        self.client.revoke_error = StravaClientError(
            "strava_temporarily_unavailable",
            status_code=503,
        )
        self.service.disconnect(INSTALLATION_ID)
        self.clock.value += STRAVA_PENDING_REVOCATION_SECONDS
        self.service.client = None

        maintenance = self.service.maintenance()

        self.assertEqual(maintenance["expiredPendingRevocations"], 1)
        self.assertEqual(maintenance["pendingRevocations"], 0)
        self.assertFalse(self.store.connection_exists(INSTALLATION_ID))

    def test_disconnect_removes_an_undecryptable_local_connection(self):
        self.connect()
        with sqlite3.connect(self.store.path) as connection:
            connection.execute(
                "UPDATE connections SET ciphertext = ? WHERE installation_id = ?",
                (b"corrupted", INSTALLATION_ID),
            )

        result = self.service.disconnect(INSTALLATION_ID)

        self.assertTrue(result["disconnected"])
        self.assertFalse(result["revocationPending"])
        self.assertFalse(self.store.connection_exists(INSTALLATION_ID))
        self.assertEqual(self.client.revoke_count, 0)

    def test_idle_connection_is_revoked_by_maintenance(self):
        self.connect()
        self.clock.value += 31 * 24 * 60 * 60
        result = self.service.maintenance()
        self.assertEqual(result["markedIdleConnections"], 1)
        self.assertEqual(result["completedRevocations"], 1)
        self.assertFalse(self.store.connection_exists(INSTALLATION_ID))

    def test_idle_connection_credential_is_deleted_if_revocation_is_unavailable(self):
        self.connect()
        self.client.revoke_error = StravaClientError(
            "strava_temporarily_unavailable",
            status_code=503,
        )
        self.clock.value += 31 * 24 * 60 * 60

        result = self.service.maintenance()

        self.assertEqual(result["markedIdleConnections"], 1)
        self.assertEqual(result["completedRevocations"], 0)
        self.assertEqual(result["expiredPendingRevocations"], 1)
        self.assertFalse(self.store.connection_exists(INSTALLATION_ID))


def _timestamp(value):
    from datetime import datetime

    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


if __name__ == "__main__":
    unittest.main()
