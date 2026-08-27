from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import secrets
import sqlite3
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterator, Mapping
from urllib.parse import urlparse

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from .strict_json import loads_strict_json
from .strava_client import (
    StravaClient,
    StravaClientError,
    StravaRouteMetadata,
    StravaTokenResponse,
    StravaTransport,
    validate_strava_route_id,
)


STRAVA_ROUTE_CACHE_SECONDS = 7 * 24 * 60 * 60
STRAVA_OAUTH_SESSION_SECONDS = 10 * 60
STRAVA_REFRESH_LEASE_SECONDS = 20
STRAVA_TOKEN_REFRESH_MARGIN_SECONDS = 5 * 60
STRAVA_CONNECTION_IDLE_DAYS = 30
STRAVA_KEY_ID_PATTERN = re.compile(r"[A-Za-z0-9._-]{1,64}")
STRAVA_SESSION_ID_PATTERN = re.compile(r"oauth_[A-Za-z0-9_-]{24,128}")
STRAVA_STATE_PATTERN = re.compile(r"[A-Za-z0-9_-]{32,256}")
STRAVA_INSTALLATION_ID_PATTERN = re.compile(r"inst_v2_[0-9a-f]{32}")
_KNOWN_CALLBACK_SCOPES = frozenset({"read", "read_all"})


class StravaIntegrationError(RuntimeError):
    _MESSAGES = {
        "invalid_strava_route_id": "The Strava route URL is invalid.",
        "installation_credential_required": "A Bicino installation credential is required.",
        "strava_not_connected": "Connect Bicino to Strava to continue.",
        "strava_scope_required": "Reconnect Strava with private-route permission.",
        "strava_route_not_importable": "This route is not available for Bicino cycling navigation.",
        "strava_route_unavailable": "This Strava route is unavailable.",
        "strava_oauth_session_invalid": "The Strava authorization session expired. Try again.",
        "strava_route_too_large": "This Strava route is too large to import.",
        "strava_rate_limited": "Strava is rate limiting requests. Try again later.",
        "strava_invalid_response": "Strava returned an invalid response.",
        "strava_temporarily_unavailable": "Strava is temporarily unavailable.",
    }

    def __init__(
        self,
        code: str,
        *,
        status_code: int,
        retry_after_seconds: int | None = None,
    ):
        super().__init__(code)
        self.code = code
        self.status_code = status_code
        self.retry_after_seconds = retry_after_seconds
        self.safe_message = self._MESSAGES.get(
            code,
            "The Strava request could not be completed.",
        )


@dataclass(frozen=True)
class StravaTokenBundle:
    athlete_id: str
    granted_scopes: tuple[str, ...]
    access_token: str
    refresh_token: str
    expires_at: int


@dataclass(frozen=True)
class StravaConnectionRecord:
    installation_id: str
    bundle: StravaTokenBundle
    connected_at: float
    last_used_at: float
    token_revision: int
    state: str


@dataclass(frozen=True)
class StravaOAuthSession:
    session_id: str
    installation_id: str
    deployment_channel: str
    created_at: float
    expires_at: float


@dataclass(frozen=True)
class StravaOAuthStart:
    session_id: str
    app_authorization_url: str
    web_authorization_url: str
    callback_scheme: str
    expires_at: str


@dataclass(frozen=True)
class StravaOAuthCallbackResult:
    session_id: str | None
    result: str


@dataclass(frozen=True)
class StravaRouteDownload:
    route_id: str
    gpx: bytes
    fetched_at: str
    delete_after: str


@dataclass(frozen=True)
class StravaRouteValidation:
    route_id: str
    checked_at: str


@dataclass(frozen=True)
class StravaTokenKeyRing:
    current_key_id: str
    keys: Mapping[str, bytes]

    def __post_init__(self) -> None:
        if STRAVA_KEY_ID_PATTERN.fullmatch(self.current_key_id) is None:
            raise ValueError("Strava token key ID is invalid")
        if self.current_key_id not in self.keys:
            raise ValueError("Strava current token key is missing")
        if any(
            STRAVA_KEY_ID_PATTERN.fullmatch(key_id) is None or len(key) != 32
            for key_id, key in self.keys.items()
        ):
            raise ValueError("Strava token keys must be uniquely named 32-byte keys")

    @classmethod
    def from_environment(cls) -> StravaTokenKeyRing:
        current_key_id = os.environ.get(
            "MAP_PLATFORM_STRAVA_TOKEN_KEY_ID",
            "",
        ).strip()
        current_key = _decode_key(
            os.environ.get("MAP_PLATFORM_STRAVA_TOKEN_KEY_BASE64", "")
        )
        keys: dict[str, bytes] = {current_key_id: current_key}
        previous = os.environ.get(
            "MAP_PLATFORM_STRAVA_PREVIOUS_TOKEN_KEYS",
            "",
        ).strip()
        for key_id, encoded in _previous_key_values(previous).items():
            if key_id in keys:
                raise ValueError("Strava token key IDs must be unique")
            keys[key_id] = _decode_key(encoded)
        return cls(current_key_id=current_key_id, keys=keys)

    def encrypt(
        self,
        installation_id: str,
        bundle: StravaTokenBundle,
    ) -> tuple[str, bytes, bytes]:
        key_id = self.current_key_id
        nonce = os.urandom(12)
        plaintext = _encode_bundle(bundle)
        ciphertext = AESGCM(self.keys[key_id]).encrypt(
            nonce,
            plaintext,
            _token_aad(installation_id, key_id),
        )
        return key_id, nonce, ciphertext

    def decrypt(
        self,
        installation_id: str,
        key_id: str,
        nonce: bytes,
        ciphertext: bytes,
    ) -> StravaTokenBundle:
        try:
            key = self.keys[key_id]
            plaintext = AESGCM(key).decrypt(
                nonce,
                ciphertext,
                _token_aad(installation_id, key_id),
            )
            return _decode_bundle(plaintext)
        except (InvalidTag, KeyError, ValueError, TypeError, StravaClientError) as exc:
            raise StravaIntegrationError(
                "strava_not_connected",
                status_code=401,
            ) from exc


@dataclass(frozen=True)
class StravaIntegrationConfig:
    enabled: bool
    deployment_channel: str
    client_id: str | None
    client_secret: str | None
    redirect_uri: str | None
    return_scheme: str
    key_ring: StravaTokenKeyRing | None
    connection_idle_days: int

    @classmethod
    def from_environment(
        cls,
        deployment_channel: str,
    ) -> StravaIntegrationConfig:
        if deployment_channel not in {"development", "production"}:
            raise ValueError("Strava deployment channel is invalid")
        enabled = _environment_flag("MAP_PLATFORM_STRAVA_ENABLED", default=False)
        sensitive_names = (
            "MAP_PLATFORM_STRAVA_CLIENT_ID",
            "MAP_PLATFORM_STRAVA_CLIENT_SECRET",
            "MAP_PLATFORM_STRAVA_REDIRECT_URI",
            "MAP_PLATFORM_STRAVA_TOKEN_KEY_ID",
            "MAP_PLATFORM_STRAVA_TOKEN_KEY_BASE64",
            "MAP_PLATFORM_STRAVA_PREVIOUS_TOKEN_KEYS",
        )
        configured = enabled or any(os.environ.get(name, "").strip() for name in sensitive_names)
        return_scheme = (
            "bikecomputer-dev" if deployment_channel == "development" else "bikecomputer"
        )
        idle_days = _bounded_integer_environment(
            "MAP_PLATFORM_STRAVA_CONNECTION_IDLE_TTL_DAYS",
            default=STRAVA_CONNECTION_IDLE_DAYS,
            minimum=1,
            maximum=STRAVA_CONNECTION_IDLE_DAYS,
        )
        if not configured:
            return cls(
                enabled=False,
                deployment_channel=deployment_channel,
                client_id=None,
                client_secret=None,
                redirect_uri=None,
                return_scheme=return_scheme,
                key_ring=None,
                connection_idle_days=idle_days,
            )
        client_id = os.environ.get("MAP_PLATFORM_STRAVA_CLIENT_ID", "").strip()
        client_secret = os.environ.get("MAP_PLATFORM_STRAVA_CLIENT_SECRET", "")
        redirect_uri = os.environ.get("MAP_PLATFORM_STRAVA_REDIRECT_URI", "").strip()
        if not client_id.isascii() or not client_id.isdigit() or int(client_id) <= 0:
            raise ValueError("Strava client ID is invalid")
        if not client_secret:
            raise ValueError("Strava client secret is missing")
        expected_host = (
            "maps-dev.8o.vc" if deployment_channel == "development" else "maps.8o.vc"
        )
        parsed_redirect = urlparse(redirect_uri)
        if (
            parsed_redirect.scheme != "https"
            or parsed_redirect.hostname != expected_host
            or parsed_redirect.port is not None
            or parsed_redirect.path != "/v1/integrations/strava/oauth/callback"
            or parsed_redirect.params
            or parsed_redirect.query
            or parsed_redirect.fragment
            or parsed_redirect.username is not None
            or parsed_redirect.password is not None
        ):
            raise ValueError("Strava redirect URI does not match the deployment channel")
        return cls(
            enabled=enabled,
            deployment_channel=deployment_channel,
            client_id=client_id,
            client_secret=client_secret,
            redirect_uri=redirect_uri,
            return_scheme=return_scheme,
            key_ring=StravaTokenKeyRing.from_environment(),
            connection_idle_days=idle_days,
        )

    @property
    def is_fully_configured(self) -> bool:
        return all(
            value is not None
            for value in (
                self.client_id,
                self.client_secret,
                self.redirect_uri,
                self.key_ring,
            )
        )


class StravaIntegrationStore:
    def __init__(
        self,
        path: Path,
        *,
        key_ring: StravaTokenKeyRing | None,
        clock: Callable[[], float] = time.time,
    ):
        self.path = path
        self._key_ring = key_ring
        self._clock = clock
        self._schema_lock = threading.Lock()
        path.parent.mkdir(parents=True, exist_ok=True)
        self._initialize()

    def create_oauth_session(
        self,
        *,
        session_id: str,
        state: str,
        installation_id: str,
        deployment_channel: str,
        created_at: float,
        expires_at: float,
    ) -> None:
        _validate_session_values(session_id, state, installation_id)
        with self._transaction() as connection:
            connection.execute(
                """
                INSERT INTO oauth_sessions(
                    session_id, state_hash, installation_id,
                    deployment_channel, created_at, expires_at,
                    consumed_at, terminal_result
                ) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL)
                """,
                (
                    session_id,
                    _state_hash(state),
                    installation_id,
                    deployment_channel,
                    created_at,
                    expires_at,
                ),
            )

    def consume_oauth_session(self, state: str) -> StravaOAuthSession:
        if STRAVA_STATE_PATTERN.fullmatch(state) is None:
            raise StravaIntegrationError(
                "strava_oauth_session_invalid",
                status_code=409,
            )
        now = self._clock()
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                """
                SELECT session_id, installation_id, deployment_channel,
                       created_at, expires_at, consumed_at
                FROM oauth_sessions
                WHERE state_hash = ?
                """,
                (_state_hash(state),),
            ).fetchone()
            if row is None or row[5] is not None or float(row[4]) <= now:
                connection.rollback()
                raise StravaIntegrationError(
                    "strava_oauth_session_invalid",
                    status_code=409,
                )
            updated = connection.execute(
                """
                UPDATE oauth_sessions
                SET consumed_at = ?
                WHERE session_id = ? AND consumed_at IS NULL
                """,
                (now, row[0]),
            )
            if updated.rowcount != 1:
                connection.rollback()
                raise StravaIntegrationError(
                    "strava_oauth_session_invalid",
                    status_code=409,
                )
            connection.commit()
            return StravaOAuthSession(
                session_id=str(row[0]),
                installation_id=str(row[1]),
                deployment_channel=str(row[2]),
                created_at=float(row[3]),
                expires_at=float(row[4]),
            )
        finally:
            connection.close()

    def mark_oauth_result(self, session_id: str, result: str) -> None:
        bounded_result = result if re.fullmatch(r"[a-z_]{1,64}", result) else "failed"
        with self._transaction() as connection:
            connection.execute(
                "UPDATE oauth_sessions SET terminal_result = ? WHERE session_id = ?",
                (bounded_result, session_id),
            )

    def prune_oauth_sessions(self, *, now: float | None = None) -> int:
        cutoff = self._clock() if now is None else now
        with self._transaction() as connection:
            cursor = connection.execute(
                """
                DELETE FROM oauth_sessions
                WHERE expires_at <= ?
                   OR (consumed_at IS NOT NULL AND consumed_at <= ?)
                """,
                (cutoff, cutoff - 24 * 60 * 60),
            )
            return max(cursor.rowcount, 0)

    def put_connection(
        self,
        installation_id: str,
        bundle: StravaTokenBundle,
        *,
        connected_at: float,
    ) -> None:
        key_id, nonce, ciphertext = self._encrypt(installation_id, bundle)
        with self._transaction() as connection:
            connection.execute(
                """
                INSERT INTO connections(
                    installation_id, key_id, nonce, ciphertext,
                    token_revision, connected_at, last_used_at,
                    state, refresh_lease_id, refresh_lease_expires_at,
                    updated_at
                ) VALUES (?, ?, ?, ?, 1, ?, ?, 'active', NULL, NULL, ?)
                ON CONFLICT(installation_id) DO UPDATE SET
                    key_id = excluded.key_id,
                    nonce = excluded.nonce,
                    ciphertext = excluded.ciphertext,
                    token_revision = connections.token_revision + 1,
                    connected_at = excluded.connected_at,
                    last_used_at = excluded.last_used_at,
                    state = 'active',
                    refresh_lease_id = NULL,
                    refresh_lease_expires_at = NULL,
                    updated_at = excluded.updated_at
                """,
                (
                    installation_id,
                    key_id,
                    nonce,
                    ciphertext,
                    connected_at,
                    connected_at,
                    connected_at,
                ),
            )

    def connection(
        self,
        installation_id: str,
        *,
        include_pending: bool = False,
    ) -> StravaConnectionRecord | None:
        state_clause = "state IN ('active', 'pending_revocation')" if include_pending else "state = 'active'"
        with self._transaction() as connection:
            row = connection.execute(
                f"""
                SELECT installation_id, key_id, nonce, ciphertext,
                       token_revision, connected_at, last_used_at, state
                FROM connections
                WHERE installation_id = ? AND {state_clause}
                """,
                (installation_id,),
            ).fetchone()
        if row is None:
            return None
        bundle = self._decrypt(
            installation_id=str(row[0]),
            key_id=str(row[1]),
            nonce=bytes(row[2]),
            ciphertext=bytes(row[3]),
        )
        record = StravaConnectionRecord(
            installation_id=str(row[0]),
            bundle=bundle,
            token_revision=int(row[4]),
            connected_at=float(row[5]),
            last_used_at=float(row[6]),
            state=str(row[7]),
        )
        if self._key_ring is not None and row[1] != self._key_ring.current_key_id:
            self._reencrypt(record)
        return record

    def connection_exists(self, installation_id: str) -> bool:
        with self._transaction() as connection:
            return connection.execute(
                "SELECT 1 FROM connections WHERE installation_id = ?",
                (installation_id,),
            ).fetchone() is not None

    def touch_connection(self, installation_id: str, *, now: float) -> None:
        with self._transaction() as connection:
            connection.execute(
                """
                UPDATE connections
                SET last_used_at = ?, updated_at = ?
                WHERE installation_id = ? AND state = 'active'
                """,
                (now, now, installation_id),
            )

    def claim_refresh(
        self,
        installation_id: str,
        *,
        expected_revision: int,
        lease_id: str,
        now: float,
    ) -> bool:
        with self._transaction() as connection:
            cursor = connection.execute(
                """
                UPDATE connections
                SET refresh_lease_id = ?, refresh_lease_expires_at = ?, updated_at = ?
                WHERE installation_id = ?
                  AND state = 'active'
                  AND token_revision = ?
                  AND (
                      refresh_lease_id IS NULL
                      OR refresh_lease_expires_at IS NULL
                      OR refresh_lease_expires_at <= ?
                  )
                """,
                (
                    lease_id,
                    now + STRAVA_REFRESH_LEASE_SECONDS,
                    now,
                    installation_id,
                    expected_revision,
                    now,
                ),
            )
            return cursor.rowcount == 1

    def complete_refresh(
        self,
        installation_id: str,
        *,
        expected_revision: int,
        lease_id: str,
        bundle: StravaTokenBundle,
        now: float,
    ) -> bool:
        key_id, nonce, ciphertext = self._encrypt(installation_id, bundle)
        with self._transaction() as connection:
            cursor = connection.execute(
                """
                UPDATE connections
                SET key_id = ?, nonce = ?, ciphertext = ?,
                    token_revision = token_revision + 1,
                    refresh_lease_id = NULL,
                    refresh_lease_expires_at = NULL,
                    last_used_at = ?, updated_at = ?
                WHERE installation_id = ?
                  AND state = 'active'
                  AND token_revision = ?
                  AND refresh_lease_id = ?
                """,
                (
                    key_id,
                    nonce,
                    ciphertext,
                    now,
                    now,
                    installation_id,
                    expected_revision,
                    lease_id,
                ),
            )
            return cursor.rowcount == 1

    def release_refresh(self, installation_id: str, lease_id: str) -> None:
        with self._transaction() as connection:
            connection.execute(
                """
                UPDATE connections
                SET refresh_lease_id = NULL,
                    refresh_lease_expires_at = NULL,
                    updated_at = ?
                WHERE installation_id = ? AND refresh_lease_id = ?
                """,
                (self._clock(), installation_id, lease_id),
            )

    def mark_pending_revocation(self, installation_id: str) -> bool:
        with self._transaction() as connection:
            cursor = connection.execute(
                """
                UPDATE connections
                SET state = 'pending_revocation',
                    refresh_lease_id = NULL,
                    refresh_lease_expires_at = NULL,
                    updated_at = ?
                WHERE installation_id = ?
                """,
                (self._clock(), installation_id),
            )
            return cursor.rowcount == 1

    def delete_connection(self, installation_id: str) -> bool:
        with self._transaction() as connection:
            cursor = connection.execute(
                "DELETE FROM connections WHERE installation_id = ?",
                (installation_id,),
            )
            return cursor.rowcount == 1

    def pending_revocation_ids(self) -> tuple[str, ...]:
        with self._transaction() as connection:
            rows = connection.execute(
                """
                SELECT installation_id
                FROM connections
                WHERE state = 'pending_revocation'
                ORDER BY updated_at, installation_id
                """
            ).fetchall()
        return tuple(str(row[0]) for row in rows)

    def idle_connection_ids(self, *, cutoff: float) -> tuple[str, ...]:
        with self._transaction() as connection:
            rows = connection.execute(
                """
                SELECT installation_id
                FROM connections
                WHERE state = 'active' AND last_used_at <= ?
                ORDER BY last_used_at, installation_id
                """,
                (cutoff,),
            ).fetchall()
        return tuple(str(row[0]) for row in rows)

    def _initialize(self) -> None:
        with self._schema_lock:
            connection = self._connect()
            try:
                connection.execute("PRAGMA journal_mode=WAL")
                connection.execute(
                    """
                    CREATE TABLE IF NOT EXISTS strava_schema(
                        singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                        schema_version INTEGER NOT NULL
                    )
                    """
                )
                connection.execute(
                    "INSERT OR IGNORE INTO strava_schema(singleton, schema_version) VALUES (1, 1)"
                )
                version = connection.execute(
                    "SELECT schema_version FROM strava_schema WHERE singleton = 1"
                ).fetchone()
                if version is None or int(version[0]) != 1:
                    raise ValueError("unsupported Strava integration database schema")
                connection.execute(
                    """
                    CREATE TABLE IF NOT EXISTS oauth_sessions(
                        session_id TEXT PRIMARY KEY,
                        state_hash TEXT NOT NULL UNIQUE,
                        installation_id TEXT NOT NULL,
                        deployment_channel TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        expires_at REAL NOT NULL,
                        consumed_at REAL,
                        terminal_result TEXT
                    )
                    """
                )
                connection.execute(
                    "CREATE INDEX IF NOT EXISTS oauth_sessions_expiry ON oauth_sessions(expires_at)"
                )
                connection.execute(
                    """
                    CREATE TABLE IF NOT EXISTS connections(
                        installation_id TEXT PRIMARY KEY,
                        key_id TEXT NOT NULL,
                        nonce BLOB NOT NULL,
                        ciphertext BLOB NOT NULL,
                        token_revision INTEGER NOT NULL,
                        connected_at REAL NOT NULL,
                        last_used_at REAL NOT NULL,
                        state TEXT NOT NULL CHECK(state IN ('active', 'pending_revocation')),
                        refresh_lease_id TEXT,
                        refresh_lease_expires_at REAL,
                        updated_at REAL NOT NULL
                    )
                    """
                )
                connection.execute(
                    "CREATE INDEX IF NOT EXISTS connections_maintenance ON connections(state, last_used_at)"
                )
                connection.commit()
            finally:
                connection.close()

    def _encrypt(
        self,
        installation_id: str,
        bundle: StravaTokenBundle,
    ) -> tuple[str, bytes, bytes]:
        if self._key_ring is None:
            raise StravaIntegrationError("strava_not_connected", status_code=401)
        return self._key_ring.encrypt(installation_id, bundle)

    def _decrypt(
        self,
        *,
        installation_id: str,
        key_id: str,
        nonce: bytes,
        ciphertext: bytes,
    ) -> StravaTokenBundle:
        if self._key_ring is None:
            raise StravaIntegrationError("strava_not_connected", status_code=401)
        return self._key_ring.decrypt(installation_id, key_id, nonce, ciphertext)

    def _reencrypt(self, record: StravaConnectionRecord) -> None:
        key_id, nonce, ciphertext = self._encrypt(
            record.installation_id,
            record.bundle,
        )
        with self._transaction() as connection:
            connection.execute(
                """
                UPDATE connections
                SET key_id = ?, nonce = ?, ciphertext = ?, updated_at = ?
                WHERE installation_id = ? AND token_revision = ?
                """,
                (
                    key_id,
                    nonce,
                    ciphertext,
                    self._clock(),
                    record.installation_id,
                    record.token_revision,
                ),
            )

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5)
        connection.execute("PRAGMA busy_timeout=5000")
        return connection

    @contextmanager
    def _transaction(self) -> Iterator[sqlite3.Connection]:
        connection = self._connect()
        try:
            with connection:
                yield connection
        finally:
            connection.close()


class StravaIntegrationService:
    def __init__(
        self,
        *,
        config: StravaIntegrationConfig,
        store: StravaIntegrationStore,
        client: StravaClient | None,
        clock: Callable[[], float] = time.time,
    ):
        self.config = config
        self.store = store
        self.client = client
        self._clock = clock
        self._refresh_locks_guard = threading.Lock()
        self._refresh_locks: dict[str, threading.Lock] = {}

    @classmethod
    def from_environment(
        cls,
        *,
        data_root: Path,
        deployment_channel: str,
        transport: StravaTransport | None = None,
        clock: Callable[[], float] = time.time,
    ) -> StravaIntegrationService:
        config = StravaIntegrationConfig.from_environment(deployment_channel)
        store = StravaIntegrationStore(
            data_root / "strava-integrations.sqlite3",
            key_ring=config.key_ring,
            clock=clock,
        )
        client: StravaClient | None = None
        if config.is_fully_configured:
            assert config.client_id is not None
            assert config.client_secret is not None
            assert config.redirect_uri is not None
            client = StravaClient(
                client_id=config.client_id,
                client_secret=config.client_secret,
                redirect_uri=config.redirect_uri,
                transport=transport,
            )
        store.prune_oauth_sessions()
        return cls(config=config, store=store, client=client, clock=clock)

    def capability(self) -> dict[str, object]:
        return {
            "enabled": self.config.enabled,
            "providerID": "strava.route",
            "maximumCacheSeconds": STRAVA_ROUTE_CACHE_SECONDS,
        }

    def start_oauth(self, installation_id: str) -> StravaOAuthStart:
        client = self._require_enabled()
        _validate_installation_id(installation_id)
        now = self._clock()
        session_id = f"oauth_{secrets.token_urlsafe(32)}"
        state = secrets.token_urlsafe(48)
        expires_at = now + STRAVA_OAUTH_SESSION_SECONDS
        self.store.create_oauth_session(
            session_id=session_id,
            state=state,
            installation_id=installation_id,
            deployment_channel=self.config.deployment_channel,
            created_at=now,
            expires_at=expires_at,
        )
        urls = client.authorization_urls(state)
        return StravaOAuthStart(
            session_id=session_id,
            app_authorization_url=urls.app_url,
            web_authorization_url=urls.web_url,
            callback_scheme=self.config.return_scheme,
            expires_at=_iso_timestamp(expires_at),
        )

    def complete_oauth(
        self,
        *,
        state: str,
        code: str | None,
        scope: str | None,
        denied: bool,
    ) -> StravaOAuthCallbackResult:
        try:
            session = self.store.consume_oauth_session(state)
        except StravaIntegrationError:
            return StravaOAuthCallbackResult(session_id=None, result="invalid")
        if session.deployment_channel != self.config.deployment_channel:
            self.store.mark_oauth_result(session.session_id, "invalid")
            return StravaOAuthCallbackResult(session.session_id, "invalid")
        if denied:
            self.store.mark_oauth_result(session.session_id, "denied")
            return StravaOAuthCallbackResult(session.session_id, "denied")
        try:
            client = self._require_enabled()
            if code is None or scope is None:
                raise StravaIntegrationError(
                    "strava_oauth_session_invalid",
                    status_code=409,
                )
            scopes = _normalize_scopes(scope)
            token = client.exchange_code(code)
            if token.athlete_id is None:
                raise StravaIntegrationError(
                    "strava_invalid_response",
                    status_code=502,
                )
            bundle = StravaTokenBundle(
                athlete_id=token.athlete_id,
                granted_scopes=scopes,
                access_token=token.access_token,
                refresh_token=token.refresh_token,
                expires_at=token.expires_at,
            )
            self.store.put_connection(
                session.installation_id,
                bundle,
                connected_at=self._clock(),
            )
        except Exception:
            self.store.mark_oauth_result(session.session_id, "failed")
            return StravaOAuthCallbackResult(session.session_id, "failed")
        self.store.mark_oauth_result(session.session_id, "connected")
        return StravaOAuthCallbackResult(session.session_id, "connected")

    def connection_status(self, installation_id: str) -> dict[str, object]:
        _validate_installation_id(installation_id)
        if not self.config.enabled or self.config.key_ring is None:
            return {
                "enabled": self.config.enabled,
                "connected": False,
                "grantedScopes": [],
                "canReadPrivateRoutes": False,
            }
        record = self.store.connection(installation_id)
        if record is None:
            return {
                "enabled": True,
                "connected": False,
                "grantedScopes": [],
                "canReadPrivateRoutes": False,
            }
        self.store.touch_connection(installation_id, now=self._clock())
        return {
            "enabled": True,
            "connected": True,
            "grantedScopes": list(record.bundle.granted_scopes),
            "canReadPrivateRoutes": "read_all" in record.bundle.granted_scopes,
            "connectedAt": _iso_timestamp(record.connected_at),
        }

    def disconnect(self, installation_id: str) -> dict[str, object]:
        _validate_installation_id(installation_id)
        if not self.store.connection_exists(installation_id):
            return {"disconnected": True, "revocationPending": False}
        if self.client is None or self.config.key_ring is None:
            self.store.delete_connection(installation_id)
            return {"disconnected": True, "revocationPending": False}
        try:
            record = self.store.connection(installation_id, include_pending=True)
        except StravaIntegrationError:
            # A missing/retired key or corrupted ciphertext must not prevent an
            # installation from disabling its local connection immediately.
            # Revocation is impossible without a decryptable access token.
            self.store.delete_connection(installation_id)
            return {"disconnected": True, "revocationPending": False}
        if record is None:
            self.store.delete_connection(installation_id)
            return {"disconnected": True, "revocationPending": False}
        self.store.mark_pending_revocation(installation_id)
        try:
            self.client.revoke(record.bundle.access_token)
        except StravaClientError as exc:
            if exc.code == "strava_temporarily_unavailable" or exc.code == "strava_rate_limited":
                return {"disconnected": True, "revocationPending": True}
            self.store.delete_connection(installation_id)
            return {"disconnected": True, "revocationPending": False}
        self.store.delete_connection(installation_id)
        return {"disconnected": True, "revocationPending": False}

    def fetch_route(self, installation_id: str, route_id: str) -> StravaRouteDownload:
        client = self._require_enabled()
        route_id = validate_strava_route_id(route_id)
        record = self._usable_connection(installation_id)
        metadata = self._route_metadata(client, record, route_id)
        self._validate_owned_cycling_route(metadata, record)
        try:
            gpx = client.export_gpx(route_id, record.bundle.access_token)
        except StravaClientError as exc:
            raise self._map_client_error(exc, installation_id) from exc
        fetched_at = self._clock()
        self.store.touch_connection(installation_id, now=fetched_at)
        return StravaRouteDownload(
            route_id=route_id,
            gpx=gpx,
            fetched_at=_iso_timestamp(fetched_at),
            delete_after=_iso_timestamp(fetched_at + STRAVA_ROUTE_CACHE_SECONDS),
        )

    def validate_route(
        self,
        installation_id: str,
        route_id: str,
    ) -> StravaRouteValidation:
        client = self._require_enabled()
        route_id = validate_strava_route_id(route_id)
        record = self._usable_connection(installation_id)
        metadata = self._route_metadata(client, record, route_id)
        self._validate_owned_cycling_route(metadata, record)
        checked_at = self._clock()
        self.store.touch_connection(installation_id, now=checked_at)
        return StravaRouteValidation(
            route_id=route_id,
            checked_at=_iso_timestamp(checked_at),
        )

    def maintenance(self, *, maximum_revocations: int = 100) -> dict[str, int]:
        if not 1 <= maximum_revocations <= 1_000:
            raise ValueError("Strava maintenance batch is invalid")
        removed_sessions = self.store.prune_oauth_sessions()
        if self.client is None or self.config.key_ring is None:
            return {
                "removedOAuthSessions": removed_sessions,
                "markedIdleConnections": 0,
                "completedRevocations": 0,
                "pendingRevocations": len(self.store.pending_revocation_ids()),
            }
        cutoff = self._clock() - self.config.connection_idle_days * 24 * 60 * 60
        idle_ids = self.store.idle_connection_ids(cutoff=cutoff)
        for installation_id in idle_ids[:maximum_revocations]:
            self.store.mark_pending_revocation(installation_id)
        completed = 0
        pending = self.store.pending_revocation_ids()
        for installation_id in pending[:maximum_revocations]:
            record = self.store.connection(installation_id, include_pending=True)
            if record is None:
                self.store.delete_connection(installation_id)
                continue
            try:
                self.client.revoke(record.bundle.access_token)
            except StravaClientError as exc:
                if exc.code in {"strava_temporarily_unavailable", "strava_rate_limited"}:
                    continue
            self.store.delete_connection(installation_id)
            completed += 1
        return {
            "removedOAuthSessions": removed_sessions,
            "markedIdleConnections": min(len(idle_ids), maximum_revocations),
            "completedRevocations": completed,
            "pendingRevocations": len(self.store.pending_revocation_ids()),
        }

    def _require_enabled(self) -> StravaClient:
        if not self.config.enabled or self.client is None or self.config.key_ring is None:
            raise StravaIntegrationError(
                "strava_temporarily_unavailable",
                status_code=503,
            )
        return self.client

    def _usable_connection(self, installation_id: str) -> StravaConnectionRecord:
        _validate_installation_id(installation_id)
        record = self.store.connection(installation_id)
        if record is None:
            raise StravaIntegrationError("strava_not_connected", status_code=401)
        if record.bundle.expires_at > int(self._clock()) + STRAVA_TOKEN_REFRESH_MARGIN_SECONDS:
            return record
        lock = self._refresh_lock(installation_id)
        with lock:
            record = self.store.connection(installation_id)
            if record is None:
                raise StravaIntegrationError("strava_not_connected", status_code=401)
            if record.bundle.expires_at > int(self._clock()) + STRAVA_TOKEN_REFRESH_MARGIN_SECONDS:
                return record
            lease_id = secrets.token_urlsafe(24)
            now = self._clock()
            if not self.store.claim_refresh(
                installation_id,
                expected_revision=record.token_revision,
                lease_id=lease_id,
                now=now,
            ):
                deadline = time.monotonic() + 2.0
                while time.monotonic() < deadline:
                    time.sleep(0.05)
                    refreshed = self.store.connection(installation_id)
                    if refreshed is None:
                        raise StravaIntegrationError("strava_not_connected", status_code=401)
                    if refreshed.token_revision != record.token_revision:
                        return refreshed
                raise StravaIntegrationError(
                    "strava_temporarily_unavailable",
                    status_code=503,
                )
            try:
                client = self._require_enabled()
                token = client.refresh_token(record.bundle.refresh_token)
                if token.athlete_id is not None and token.athlete_id != record.bundle.athlete_id:
                    raise StravaIntegrationError(
                        "strava_invalid_response",
                        status_code=502,
                    )
                bundle = StravaTokenBundle(
                    athlete_id=record.bundle.athlete_id,
                    granted_scopes=record.bundle.granted_scopes,
                    access_token=token.access_token,
                    refresh_token=token.refresh_token,
                    expires_at=token.expires_at,
                )
                if not self.store.complete_refresh(
                    installation_id,
                    expected_revision=record.token_revision,
                    lease_id=lease_id,
                    bundle=bundle,
                    now=self._clock(),
                ):
                    raise StravaIntegrationError(
                        "strava_temporarily_unavailable",
                        status_code=503,
                    )
            except StravaClientError as exc:
                self.store.release_refresh(installation_id, lease_id)
                raise self._map_client_error(exc, installation_id) from exc
            except Exception:
                self.store.release_refresh(installation_id, lease_id)
                raise
            refreshed = self.store.connection(installation_id)
            if refreshed is None:
                raise StravaIntegrationError("strava_not_connected", status_code=401)
            return refreshed

    def _route_metadata(
        self,
        client: StravaClient,
        record: StravaConnectionRecord,
        route_id: str,
    ) -> StravaRouteMetadata:
        try:
            return client.route_metadata(route_id, record.bundle.access_token)
        except StravaClientError as exc:
            raise self._map_client_error(exc, record.installation_id) from exc

    @staticmethod
    def _validate_owned_cycling_route(
        metadata: StravaRouteMetadata,
        record: StravaConnectionRecord,
    ) -> None:
        if metadata.athlete_id != record.bundle.athlete_id or metadata.route_type != 1:
            raise StravaIntegrationError(
                "strava_route_not_importable",
                status_code=403,
            )

    def _map_client_error(
        self,
        error: StravaClientError,
        installation_id: str,
    ) -> StravaIntegrationError:
        if error.code == "strava_token_rejected":
            self.store.delete_connection(installation_id)
            return StravaIntegrationError("strava_not_connected", status_code=401)
        return StravaIntegrationError(
            error.code,
            status_code=error.status_code,
            retry_after_seconds=error.retry_after_seconds,
        )

    def _refresh_lock(self, installation_id: str) -> threading.Lock:
        with self._refresh_locks_guard:
            return self._refresh_locks.setdefault(installation_id, threading.Lock())


def _validate_installation_id(value: str) -> None:
    if STRAVA_INSTALLATION_ID_PATTERN.fullmatch(value) is None:
        raise StravaIntegrationError(
            "installation_credential_required",
            status_code=401,
        )


def _validate_session_values(
    session_id: str,
    state: str,
    installation_id: str,
) -> None:
    if (
        STRAVA_SESSION_ID_PATTERN.fullmatch(session_id) is None
        or STRAVA_STATE_PATTERN.fullmatch(state) is None
        or STRAVA_INSTALLATION_ID_PATTERN.fullmatch(installation_id) is None
    ):
        raise ValueError("Strava OAuth session values are invalid")


def _normalize_scopes(value: str) -> tuple[str, ...]:
    if not isinstance(value, str) or not 1 <= len(value) <= 256:
        raise StravaIntegrationError("strava_scope_required", status_code=403)
    scopes = frozenset(item.strip() for item in value.split(",") if item.strip())
    retained = scopes.intersection(_KNOWN_CALLBACK_SCOPES)
    if "read" not in retained:
        raise StravaIntegrationError("strava_scope_required", status_code=403)
    return tuple(sorted(retained))


def _encode_bundle(bundle: StravaTokenBundle) -> bytes:
    document = {
        "schemaVersion": 1,
        "athleteId": bundle.athlete_id,
        "grantedScopes": list(bundle.granted_scopes),
        "accessToken": bundle.access_token,
        "refreshToken": bundle.refresh_token,
        "expiresAt": bundle.expires_at,
    }
    return json.dumps(
        document,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def _decode_bundle(data: bytes) -> StravaTokenBundle:
    document = loads_strict_json(data, description="Strava token bundle")
    if not isinstance(document, dict) or set(document) != {
        "schemaVersion",
        "athleteId",
        "grantedScopes",
        "accessToken",
        "refreshToken",
        "expiresAt",
    }:
        raise ValueError("Strava token bundle is invalid")
    scopes = document["grantedScopes"]
    if (
        document["schemaVersion"] != 1
        or not isinstance(document["athleteId"], str)
        or not isinstance(scopes, list)
        or any(not isinstance(scope, str) for scope in scopes)
        or len(scopes) != len(set(scopes))
        or not isinstance(document["accessToken"], str)
        or not isinstance(document["refreshToken"], str)
        or isinstance(document["expiresAt"], bool)
        or not isinstance(document["expiresAt"], int)
    ):
        raise ValueError("Strava token bundle is invalid")
    normalized_scopes = tuple(sorted(set(scopes).intersection(_KNOWN_CALLBACK_SCOPES)))
    if "read" not in normalized_scopes:
        raise ValueError("Strava token bundle is invalid")
    return StravaTokenBundle(
        athlete_id=validate_strava_route_id(document["athleteId"]),
        granted_scopes=normalized_scopes,
        access_token=document["accessToken"],
        refresh_token=document["refreshToken"],
        expires_at=document["expiresAt"],
    )


def _token_aad(installation_id: str, key_id: str) -> bytes:
    return f"bicino-strava-token-v1\0{installation_id}\0{key_id}".encode("utf-8")


def _state_hash(state: str) -> str:
    return hashlib.sha256(state.encode("ascii")).hexdigest()


def _iso_timestamp(value: float) -> str:
    return datetime.fromtimestamp(value, tz=timezone.utc).isoformat(
        timespec="milliseconds"
    ).replace("+00:00", "Z")


def _decode_key(value: str) -> bytes:
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as exc:
        raise ValueError("Strava token key is invalid") from exc
    if len(decoded) != 32:
        raise ValueError("Strava token key must decode to exactly 32 bytes")
    return decoded


def _previous_key_values(value: str) -> dict[str, str]:
    if not value:
        return {}
    if value.startswith("{"):
        document = loads_strict_json(
            value,
            description="Strava previous token keys",
        )
        if not isinstance(document, dict) or any(
            not isinstance(key, str) or not isinstance(item, str)
            for key, item in document.items()
        ):
            raise ValueError("Strava previous token keys are invalid")
        return dict(document)
    result: dict[str, str] = {}
    for entry in value.split(","):
        key_id, separator, encoded = entry.partition("=")
        if not separator or not key_id or not encoded or key_id in result:
            raise ValueError("Strava previous token keys are invalid")
        result[key_id] = encoded
    return result


def _environment_flag(name: str, *, default: bool) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes"}:
        return True
    if normalized in {"0", "false", "no"}:
        return False
    raise ValueError(f"{name} must be a boolean")


def _bounded_integer_environment(
    name: str,
    *,
    default: int,
    minimum: int,
    maximum: int,
) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} is outside its allowed range")
    return value
