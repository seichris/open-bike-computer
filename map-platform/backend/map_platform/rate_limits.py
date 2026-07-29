from __future__ import annotations

import hashlib
import hmac
import ipaddress
import os
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable


@dataclass(frozen=True)
class RateLimitPolicy:
    scope: str
    limit: int
    window_seconds: int

    def __post_init__(self) -> None:
        if not self.scope or self.limit < 1 or self.window_seconds < 1:
            raise ValueError("rate-limit policies require a scope and positive limits")


class RateLimitExceeded(RuntimeError):
    def __init__(self, scope: str, retry_after_seconds: int):
        super().__init__(f"rate limit exceeded for {scope}")
        self.scope = scope
        self.retry_after_seconds = max(1, retry_after_seconds)


class PersistentRateLimiter:
    """Cross-process fixed-window limits without retaining raw client identifiers."""

    def __init__(
        self,
        path: Path,
        pseudonym_secret: str,
        *,
        clock: Callable[[], float] = time.time,
    ):
        if len(pseudonym_secret.encode("utf-8")) < 32:
            raise ValueError("rate-limit pseudonym secret must be at least 32 bytes")
        self._path = path
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._secret = pseudonym_secret.encode("utf-8")
        self._clock = clock
        self._schema_lock = threading.Lock()
        self._initialize()

    def consume(self, policy: RateLimitPolicy, subject: str) -> None:
        self.consume_many(((policy, subject),))

    def consume_many(
        self,
        rules: Iterable[tuple[RateLimitPolicy, str]],
    ) -> None:
        entries = list(rules)
        if not entries:
            return
        now = int(self._clock())
        prepared = [
            (
                policy,
                self._subject_hash(policy.scope, subject),
                now - (now % policy.window_seconds),
            )
            for policy, subject in entries
        ]
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                "DELETE FROM rate_limits WHERE expires_at <= ?",
                (now,),
            )
            for policy, subject_hash, window_start in prepared:
                row = connection.execute(
                    """
                    SELECT request_count
                    FROM rate_limits
                    WHERE scope = ? AND subject_hash = ? AND window_start = ?
                    """,
                    (policy.scope, subject_hash, window_start),
                ).fetchone()
                if row is not None and int(row[0]) >= policy.limit:
                    connection.rollback()
                    raise RateLimitExceeded(
                        policy.scope,
                        window_start + policy.window_seconds - now,
                    )
            for policy, subject_hash, window_start in prepared:
                connection.execute(
                    """
                    INSERT INTO rate_limits(
                        scope,
                        subject_hash,
                        window_start,
                        expires_at,
                        request_count
                    ) VALUES (?, ?, ?, ?, 1)
                    ON CONFLICT(scope, subject_hash, window_start)
                    DO UPDATE SET request_count = request_count + 1
                    """,
                    (
                        policy.scope,
                        subject_hash,
                        window_start,
                        window_start + policy.window_seconds,
                    ),
                )
            connection.commit()
        finally:
            connection.close()

    def _initialize(self) -> None:
        with self._schema_lock:
            connection = self._connect()
            try:
                connection.execute("PRAGMA journal_mode=WAL")
                connection.execute(
                    """
                    CREATE TABLE IF NOT EXISTS rate_limits(
                        scope TEXT NOT NULL,
                        subject_hash TEXT NOT NULL,
                        window_start INTEGER NOT NULL,
                        expires_at INTEGER NOT NULL,
                        request_count INTEGER NOT NULL,
                        PRIMARY KEY(scope, subject_hash, window_start)
                    )
                    """
                )
                connection.execute(
                    """
                    CREATE INDEX IF NOT EXISTS rate_limits_expiration
                    ON rate_limits(expires_at)
                    """
                )
                connection.execute(
                    "DELETE FROM rate_limits WHERE expires_at <= ?",
                    (int(self._clock()),),
                )
                connection.commit()
            finally:
                connection.close()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self._path, timeout=5)
        connection.execute("PRAGMA busy_timeout=5000")
        return connection

    def _subject_hash(self, scope: str, subject: str) -> str:
        normalized = subject.strip().lower()
        if not normalized:
            normalized = "unknown"
        return hmac.new(
            self._secret,
            f"open-bike-rate-limit-v1\0{scope}\0{normalized}".encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()


def purge_expired_rate_limits(path: Path, *, now: int | None = None) -> int:
    """Delete expired pseudonyms without requiring another client request."""
    if not path.exists():
        return 0
    connection = sqlite3.connect(path, timeout=5)
    connection.execute("PRAGMA busy_timeout=5000")
    try:
        table_exists = connection.execute(
            """
            SELECT 1
            FROM sqlite_master
            WHERE type = 'table' AND name = 'rate_limits'
            """
        ).fetchone()
        if table_exists is None:
            return 0
        cursor = connection.execute(
            "DELETE FROM rate_limits WHERE expires_at <= ?",
            (int(time.time()) if now is None else int(now),),
        )
        connection.commit()
        return max(cursor.rowcount, 0)
    finally:
        connection.close()

class ClientAddressResolver:
    """Resolve proxy chains from the right, trusting forwarded values only from known peers."""

    def __init__(self, trusted_proxy_cidrs: Iterable[str] = ()):
        self._trusted = tuple(
            ipaddress.ip_network(value.strip(), strict=False)
            for value in trusted_proxy_cidrs
            if value.strip()
        )

    @classmethod
    def from_environment(cls) -> "ClientAddressResolver":
        return cls(
            os.environ.get("MAP_PLATFORM_TRUSTED_PROXY_CIDRS", "").split(",")
        )

    def resolve(self, peer_host: str | None, forwarded_for: str | None) -> str:
        peer = self._address(peer_host)
        if peer is None:
            return (peer_host or "unknown").strip().lower()[:128] or "unknown"
        if not self._is_trusted(peer) or not forwarded_for:
            return self._rate_subject(peer)

        forwarded: list[ipaddress.IPv4Address | ipaddress.IPv6Address] = []
        for value in forwarded_for.split(","):
            address = self._address(value)
            if address is None:
                return self._rate_subject(peer)
            forwarded.append(address)

        chain = [*forwarded, peer]
        for address in reversed(chain):
            if not self._is_trusted(address):
                return self._rate_subject(address)
        return self._rate_subject(chain[0])

    def _is_trusted(
        self,
        address: ipaddress.IPv4Address | ipaddress.IPv6Address,
    ) -> bool:
        return any(address in network for network in self._trusted)

    @staticmethod
    def _address(
        value: str | None,
    ) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
        if value is None:
            return None
        try:
            return ipaddress.ip_address(value.strip())
        except ValueError:
            return None

    @staticmethod
    def _rate_subject(
        address: ipaddress.IPv4Address | ipaddress.IPv6Address,
    ) -> str:
        if isinstance(address, ipaddress.IPv4Address):
            return address.compressed
        if address.ipv4_mapped is not None:
            return address.ipv4_mapped.compressed
        network = ipaddress.ip_network((address, 64), strict=False)
        return f"{network.network_address.compressed}/64"
