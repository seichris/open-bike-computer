"""Hosted and internal terrain providers behind one route-profile contract.

Providers only return heights for the supplied WGS-84 sample points. They never
calculate or replace route geometry. Each profile is produced from one coherent
provider result; fallback recomputes the whole profile instead of mixing points
from different providers and vertical references.

The Geoapify key is a server-side secret. It is never part of a returned value,
an exception message, ``repr`` output or a log line: requests carry it only in
the URL passed to the transport, and every transport failure is reduced to a
fixed, credential-free code.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import math
import os
import socket
import sqlite3
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Mapping, Protocol, Sequence
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import HTTPRedirectHandler, Request, build_opener

from .route_elevation import ElevationSource
from .strict_json import loads_strict_json
from .topography_notices import route_elevation_notices
from .topography_sources import ElevationSource as DemSource
from .topography_sources import TopographySourcePolicy

GEOAPIFY_ELEVATION_URL = "https://api.geoapify.com/v1/geodata/elevation"
GEOAPIFY_MAXIMUM_LOCATIONS = 1000
GEOAPIFY_MAXIMUM_RESPONSE_BYTES = 512 * 1024
GEOAPIFY_ATTRIBUTION = (
    "Powered by Geoapify (https://www.geoapify.com/)",
    "Geoapify elevation data sources: USGS 3DEP, NASA SRTM, USGS GMTED2010 and NOAA ETOPO1",
    "© OpenStreetMap contributors",
)
GEOAPIFY_LOCATION_TOLERANCE_DEG = 1e-4

DEFAULT_GEOAPIFY_DAILY_CREDIT_BUDGET = 1500
DEFAULT_INSTALLATION_DAILY_CREDIT_BUDGET = 200
DEFAULT_GEOAPIFY_TIMEOUT_SECONDS = 10.0
DEFAULT_GEOAPIFY_REQUESTS_PER_SECOND = 4

DEM_MAXIMUM_TILES = 8
DEM_MAXIMUM_WINDOW_PIXELS = 1_000_000
DEM_POINTS_PER_WINDOW = 128

PROVIDER_GEOAPIFY = "geoapify"
PROVIDER_COPERNICUS = "copernicus"
KNOWN_PROVIDERS = (PROVIDER_GEOAPIFY, PROVIDER_COPERNICUS)


class ElevationProviderError(Exception):
    """A provider failure carrying only a stable, credential-free code."""

    def __init__(self, code: str, *, retry_after_seconds: int | None = None):
        super().__init__(code)
        self.code = code
        self.retry_after_seconds = retry_after_seconds


def geoapify_credits(location_count: int) -> int:
    """Documented ordinary cost: ``max(1, ceil(locations / 100))`` per request."""

    if location_count < 1:
        raise ValueError("a Geoapify request needs at least one location")
    return max(1, math.ceil(location_count / 100))


def geoapify_batches(location_count: int) -> list[tuple[int, int]]:
    """Split into full 1,000-location requests plus one remainder (minimum credits)."""

    return [
        (start, min(location_count, start + GEOAPIFY_MAXIMUM_LOCATIONS))
        for start in range(0, location_count, GEOAPIFY_MAXIMUM_LOCATIONS)
    ]


def seconds_until_utc_midnight(now: float) -> int:
    current = datetime.fromtimestamp(now, tz=timezone.utc)
    tomorrow = (current + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    return max(1, int(math.ceil((tomorrow - current).total_seconds())))


@dataclass(frozen=True)
class ProviderHTTPResponse:
    status_code: int
    headers: Mapping[str, str]
    body: bytes
    final_url: str = field(repr=False)


class ElevationTransport(Protocol):
    def request(
        self,
        *,
        method: str,
        url: str,
        headers: Mapping[str, str],
        body: bytes | None,
        timeout_seconds: float,
        maximum_body_bytes: int,
    ) -> ProviderHTTPResponse: ...


class _NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class UrllibElevationTransport:
    """Fixed-host transport that never follows redirects or leaks its URL."""

    def __init__(self):
        self._opener = build_opener(_NoRedirectHandler())

    def request(
        self,
        *,
        method: str,
        url: str,
        headers: Mapping[str, str],
        body: bytes | None,
        timeout_seconds: float,
        maximum_body_bytes: int,
    ) -> ProviderHTTPResponse:
        request = Request(url, data=body, method=method, headers=dict(headers))
        failure: str | None = None
        try:
            response = self._opener.open(request, timeout=timeout_seconds)
            try:
                payload = response.read(maximum_body_bytes + 1)
                return ProviderHTTPResponse(
                    status_code=int(response.status),
                    headers={key.lower(): value for key, value in response.headers.items()},
                    body=payload,
                    final_url=response.geturl(),
                )
            finally:
                response.close()
        except HTTPError as exc:
            try:
                payload = exc.read(min(maximum_body_bytes, 16 * 1024) + 1)
            except OSError:
                payload = b""
            finally:
                exc.close()
            return ProviderHTTPResponse(
                status_code=int(exc.code),
                headers={key.lower(): value for key, value in (exc.headers or {}).items()},
                body=payload,
                final_url=url,
            )
        except (socket.timeout, TimeoutError):
            failure = "provider-timeout"
        except (URLError, OSError, ValueError):
            failure = "provider-unavailable"
        # Raised outside the handlers so no exception context (which can hold
        # the credential-bearing request URL) is chained to the provider error.
        raise ElevationProviderError(failure)


@dataclass(frozen=True)
class ProviderSamples:
    values: tuple[float | None, ...]
    source: ElevationSource
    credits_used: int = 0
    diagnostics: Mapping[str, object] = field(default_factory=dict)


class RouteElevationProvider(Protocol):
    name: str

    def unavailable_reason(self) -> str | None: ...

    def sample(
        self,
        points: Sequence[tuple[float, float]],
        *,
        installation_id: str,
        deadline: float,
    ) -> ProviderSamples: ...


class ProviderCreditLedger:
    """Persistent UTC-day credit accounting shared by API processes.

    Credits are reserved before a provider request is sent and are refunded
    only for requests that were never sent. Installation subjects are stored as
    HMAC pseudonyms, like the persistent rate limiter.
    """

    def __init__(self, path: Path, pseudonym_secret: str, *, clock: Callable[[], float] = time.time):
        self.path = path
        self._secret = pseudonym_secret.encode("utf-8")
        self._clock = clock
        self._lock = threading.Lock()
        path.parent.mkdir(parents=True, exist_ok=True)
        with self._lock, self._connect() as connection:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute(
                "CREATE TABLE IF NOT EXISTS provider_credit_days ("
                "provider TEXT NOT NULL, subject_hash TEXT NOT NULL, day TEXT NOT NULL, "
                "credits INTEGER NOT NULL, expires_at INTEGER NOT NULL, "
                "PRIMARY KEY (provider, subject_hash, day))"
            )
            connection.execute(
                "CREATE INDEX IF NOT EXISTS provider_credit_days_expiry "
                "ON provider_credit_days(expires_at)"
            )

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.execute("PRAGMA busy_timeout=5000")
        return connection

    def _subject(self, provider: str, installation_id: str) -> str:
        return hmac.new(
            self._secret,
            f"route-elevation-credits\n{provider}\n{installation_id}".encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()

    def _day(self) -> tuple[str, int]:
        now = self._clock()
        current = datetime.fromtimestamp(now, tz=timezone.utc)
        expires = int(now) + seconds_until_utc_midnight(now) + 86_400
        return current.strftime("%Y-%m-%d"), expires

    def reserve(
        self,
        provider: str,
        installation_id: str,
        credits: int,
        *,
        daily_budget: int,
        installation_daily_budget: int,
    ) -> None:
        if credits <= 0:
            return
        day, expires_at = self._day()
        subject = self._subject(provider, installation_id)
        with self._lock, self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                connection.execute("DELETE FROM provider_credit_days WHERE expires_at <= ?", (int(self._clock()),))
                total = connection.execute(
                    "SELECT COALESCE(SUM(credits), 0) FROM provider_credit_days WHERE provider = ? AND day = ?",
                    (provider, day),
                ).fetchone()[0]
                own = connection.execute(
                    "SELECT COALESCE(credits, 0) FROM provider_credit_days "
                    "WHERE provider = ? AND subject_hash = ? AND day = ?",
                    (provider, subject, day),
                ).fetchone()
                own_credits = 0 if own is None else int(own[0])
                if total + credits > daily_budget or own_credits + credits > installation_daily_budget:
                    raise ElevationProviderError(
                        "quota-exhausted",
                        retry_after_seconds=seconds_until_utc_midnight(self._clock()),
                    )
                connection.execute(
                    "INSERT INTO provider_credit_days(provider, subject_hash, day, credits, expires_at) "
                    "VALUES (?, ?, ?, ?, ?) ON CONFLICT(provider, subject_hash, day) "
                    "DO UPDATE SET credits = credits + excluded.credits",
                    (provider, subject, day, credits, expires_at),
                )
                connection.execute("COMMIT")
            except BaseException:
                connection.execute("ROLLBACK")
                raise

    def refund(self, provider: str, installation_id: str, credits: int) -> None:
        if credits <= 0:
            return
        day, _ = self._day()
        with self._lock, self._connect() as connection:
            connection.execute(
                "UPDATE provider_credit_days SET credits = MAX(0, credits - ?) "
                "WHERE provider = ? AND subject_hash = ? AND day = ?",
                (credits, provider, self._subject(provider, installation_id), day),
            )

    def used_today(self, provider: str) -> int:
        day, _ = self._day()
        with self._lock, self._connect() as connection:
            row = connection.execute(
                "SELECT COALESCE(SUM(credits), 0) FROM provider_credit_days WHERE provider = ? AND day = ?",
                (provider, day),
            ).fetchone()
        return int(row[0])


def purge_expired_route_elevation_credits(path: Path, *, now: float | None = None) -> int:
    if not path.exists():
        return 0
    connection = sqlite3.connect(path, timeout=5, isolation_level=None)
    try:
        connection.execute("PRAGMA busy_timeout=5000")
        cursor = connection.execute(
            "DELETE FROM provider_credit_days WHERE expires_at <= ?",
            (int(time.time() if now is None else now),),
        )
        return int(cursor.rowcount or 0)
    except sqlite3.OperationalError:
        return 0
    finally:
        connection.close()


def _environment_integer(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


@dataclass(frozen=True)
class GeoapifyConfig:
    api_key: str | None = field(default=None, repr=False)
    daily_credit_budget: int = DEFAULT_GEOAPIFY_DAILY_CREDIT_BUDGET
    installation_daily_credit_budget: int = DEFAULT_INSTALLATION_DAILY_CREDIT_BUDGET
    timeout_seconds: float = DEFAULT_GEOAPIFY_TIMEOUT_SECONDS
    requests_per_second: int = DEFAULT_GEOAPIFY_REQUESTS_PER_SECOND

    @classmethod
    def from_environment(cls) -> "GeoapifyConfig":
        key = os.environ.get("MAP_PLATFORM_GEOAPIFY_API_KEY", "").strip() or None
        if key is not None and (len(key) > 256 or any(ord(character) <= 32 for character in key)):
            raise ValueError("MAP_PLATFORM_GEOAPIFY_API_KEY is malformed")
        return cls(
            api_key=key,
            daily_credit_budget=_environment_integer(
                "MAP_PLATFORM_GEOAPIFY_DAILY_CREDIT_BUDGET",
                DEFAULT_GEOAPIFY_DAILY_CREDIT_BUDGET,
                0,
                1_000_000,
            ),
            installation_daily_credit_budget=_environment_integer(
                "MAP_PLATFORM_ROUTE_ELEVATION_INSTALLATION_DAILY_CREDITS",
                DEFAULT_INSTALLATION_DAILY_CREDIT_BUDGET,
                0,
                1_000_000,
            ),
            timeout_seconds=float(
                _environment_integer("MAP_PLATFORM_GEOAPIFY_TIMEOUT_SECONDS", 10, 1, 60)
            ),
            requests_per_second=_environment_integer(
                "MAP_PLATFORM_GEOAPIFY_REQUESTS_PER_SECOND",
                DEFAULT_GEOAPIFY_REQUESTS_PER_SECOND,
                1,
                5,
            ),
        )

    @property
    def configured(self) -> bool:
        return self.api_key is not None


class _RequestPacer:
    """Process-wide sliding one-second window for provider request starts."""

    def __init__(self, per_second: int, *, clock: Callable[[], float], sleep: Callable[[float], None]):
        self._per_second = per_second
        self._clock = clock
        self._sleep = sleep
        self._lock = threading.Lock()
        self._starts: list[float] = []

    def wait(self, deadline: float) -> None:
        while True:
            with self._lock:
                now = self._clock()
                self._starts = [start for start in self._starts if now - start < 1.0]
                if len(self._starts) < self._per_second:
                    self._starts.append(now)
                    return
                delay = 1.0 - (now - self._starts[0])
            if now + delay >= deadline:
                raise ElevationProviderError("deadline-exceeded")
            self._sleep(max(0.01, delay))


class GeoapifyElevationProvider:
    name = PROVIDER_GEOAPIFY

    def __init__(
        self,
        config: GeoapifyConfig,
        ledger: ProviderCreditLedger,
        *,
        transport: ElevationTransport | None = None,
        clock: Callable[[], float] = time.monotonic,
        wall_clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
    ):
        self._config = config
        self._ledger = ledger
        self._transport = transport or UrllibElevationTransport()
        self._clock = clock
        self._wall_clock = wall_clock
        self._pacer = _RequestPacer(config.requests_per_second, clock=clock, sleep=sleep)

    def unavailable_reason(self) -> str | None:
        if not self._config.configured:
            return "provider-not-configured"
        if self._config.daily_credit_budget <= 0:
            return "provider-budget-disabled"
        return None

    def public_summary(self) -> dict[str, object]:
        # Public health output: configuration presence only, never the key or usage.
        return {"configured": self._config.configured}

    def sample(
        self,
        points: Sequence[tuple[float, float]],
        *,
        installation_id: str,
        deadline: float,
    ) -> ProviderSamples:
        reason = self.unavailable_reason()
        if reason is not None:
            raise ElevationProviderError(reason)
        batches = geoapify_batches(len(points))
        planned = [geoapify_credits(end - start) for start, end in batches]
        self._ledger.reserve(
            self.name,
            installation_id,
            sum(planned),
            daily_budget=self._config.daily_credit_budget,
            installation_daily_budget=self._config.installation_daily_credit_budget,
        )
        sent = 0
        values: list[float | None] = []
        try:
            for index, (start, end) in enumerate(batches):
                if self._clock() >= deadline:
                    raise ElevationProviderError("deadline-exceeded")
                self._pacer.wait(deadline)
                sent = index + 1
                values.extend(self._request_batch(points[start:end], deadline))
        except ElevationProviderError:
            self._ledger.refund(self.name, installation_id, sum(planned[sent:]))
            raise
        retrieved = datetime.fromtimestamp(self._wall_clock(), tz=timezone.utc)
        source = ElevationSource(
            kind="hosted-terrain",
            identifier="geoapify-elevation-v1",
            version=None,
            vertical_datum=None,
            native_resolution_m=None,
            surface_model=None,
            interpolation="provider",
            attribution=GEOAPIFY_ATTRIBUTION,
            retrieved_at=retrieved.strftime("%Y-%m-%d"),
            qualification="pending-live-qualification",
        )
        return ProviderSamples(
            values=tuple(values),
            source=source,
            credits_used=sum(planned),
            diagnostics={"requests": len(batches)},
        )

    def _request_batch(self, points: Sequence[tuple[float, float]], deadline: float) -> list[float | None]:
        body = json.dumps(
            {"locations": [[round(lon, 6), round(lat, 6)] for lat, lon in points]},
            separators=(",", ":"),
        ).encode("utf-8")
        url = GEOAPIFY_ELEVATION_URL + "?apiKey=" + quote(self._config.api_key or "", safe="")
        timeout = min(self._config.timeout_seconds, max(0.5, deadline - self._clock()))
        response = self._transport.request(
            method="POST",
            url=url,
            headers={
                "Accept": "application/json",
                "Content-Type": "application/json",
                "User-Agent": "Bicino-Route-Elevation/1",
            },
            body=body,
            timeout_seconds=timeout,
            maximum_body_bytes=GEOAPIFY_MAXIMUM_RESPONSE_BYTES,
        )
        if response.final_url != url:
            raise ElevationProviderError("provider-malformed-response")
        status = response.status_code
        if status in (401, 403):
            raise ElevationProviderError("provider-unauthorized")
        if status == 429:
            raise ElevationProviderError(
                "provider-rate-limited",
                retry_after_seconds=_bounded_retry_after(response.headers.get("retry-after")),
            )
        if status >= 500:
            raise ElevationProviderError("provider-unavailable")
        if status != 200:
            raise ElevationProviderError("provider-rejected-request")
        if len(response.body) > GEOAPIFY_MAXIMUM_RESPONSE_BYTES:
            raise ElevationProviderError("provider-malformed-response")
        return parse_geoapify_response(response.body, points)


def _bounded_retry_after(value: str | None) -> int | None:
    if value is None:
        return None
    text = value.strip()
    if not text.isdecimal() or len(text) > 7:
        return None
    return min(max(int(text), 1), 86_400)


def _finite_number(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    return number if math.isfinite(number) else None


def parse_geoapify_response(body: bytes, points: Sequence[tuple[float, float]]) -> list[float | None]:
    """Validate a Geoapify JSON response against the request, preserving nulls.

    The result count must equal the request count and every echoed location
    must match the request in order. Published examples show inconsistent axis
    order, so a consistently swapped echo is accepted; a mixed echo is not.
    """

    try:
        document = loads_strict_json(body, description="Geoapify elevation response")
    except ValueError:
        raise ElevationProviderError("provider-malformed-response") from None
    if not isinstance(document, dict) or not isinstance(document.get("results"), list):
        raise ElevationProviderError("provider-malformed-response")
    results = document["results"]
    if len(results) != len(points):
        raise ElevationProviderError("provider-malformed-response")
    all_direct = True
    all_swapped = True
    values: list[float | None] = []
    for result, (lat, lon) in zip(results, points):
        if not isinstance(result, dict):
            raise ElevationProviderError("provider-malformed-response")
        location = result.get("location")
        if not isinstance(location, dict):
            raise ElevationProviderError("provider-malformed-response")
        echoed_lat = _finite_number(location.get("lat"))
        echoed_lon = _finite_number(location.get("lon"))
        if echoed_lat is None or echoed_lon is None:
            raise ElevationProviderError("provider-malformed-response")
        all_direct = all_direct and (
            abs(echoed_lat - lat) <= GEOAPIFY_LOCATION_TOLERANCE_DEG
            and abs(echoed_lon - lon) <= GEOAPIFY_LOCATION_TOLERANCE_DEG
        )
        all_swapped = all_swapped and (
            abs(echoed_lat - lon) <= GEOAPIFY_LOCATION_TOLERANCE_DEG
            and abs(echoed_lon - lat) <= GEOAPIFY_LOCATION_TOLERANCE_DEG
        )
        if not (all_direct or all_swapped):
            raise ElevationProviderError("provider-malformed-response")
        units = result.get("units", "m")
        if units != "m":
            raise ElevationProviderError("provider-malformed-response")
        elevation = result.get("elevation")
        if elevation is None:
            values.append(None)
            continue
        number = _finite_number(elevation)
        if number is None or not -12_000.0 <= number <= 10_000.0:
            raise ElevationProviderError("provider-malformed-response")
        values.append(number)
    return values


def dem_cell(lat: float, lon: float) -> tuple[int, int]:
    return min(179, max(-180, math.floor(lon))), min(89, max(-90, math.floor(lat)))


class CopernicusRouteElevationProvider:
    """Bilinear point sampler over already-staged pinned Copernicus DEM tiles.

    Request-time sampling never downloads: operators stage tiles with the
    existing ``map-topography stage`` command. Pixels whose contributing
    corners are invalid stay missing. In the production channel the provider is
    unavailable until the pinned sources are production-approved, mirroring
    the map pipeline's source gate.
    """

    name = PROVIDER_COPERNICUS

    def __init__(
        self,
        policy: TopographySourcePolicy,
        cache_root: Path,
        *,
        enabled: bool,
        deployment_channel: str,
        clock: Callable[[], float] = time.monotonic,
    ):
        self._policy = policy
        self._cache_root = cache_root
        self._enabled = enabled
        self._deployment_channel = deployment_channel
        self._clock = clock
        self._lock = threading.Lock()
        self._indexes: dict[str, frozenset[tuple[int, int]]] = {}
        self._verified: dict[str, tuple[int, int]] = {}

    def unavailable_reason(self) -> str | None:
        if not self._enabled:
            return "dem-disabled"
        if self._deployment_channel == "production" and not all(
            source.production_approved for source in self._policy.sources
        ):
            return "dem-not-production-approved"
        try:
            import numpy  # noqa: F401
            import rasterio  # noqa: F401
        except ImportError:
            return "dem-runtime-unavailable"
        return None

    def public_summary(self) -> dict[str, object]:
        return {
            "enabled": self._enabled,
            "available": self.unavailable_reason() is None,
            "reason": self.unavailable_reason(),
            "requestTimeAcquisition": False,
        }

    def _cache(self):
        from .topography_cache import ElevationCache

        return ElevationCache(self._cache_root)

    def _index(self, source: DemSource) -> frozenset[tuple[int, int]] | None:
        with self._lock:
            cached = self._indexes.get(source.index_sha256)
        if cached is not None:
            return cached
        path = self._cache_root / "indexes" / (source.index_sha256 + ".txt")
        if not path.exists():
            return None
        index = self._cache().index(source)
        with self._lock:
            self._indexes[source.index_sha256] = index
        return index

    def _staged_tile(self, source: DemSource, cell: tuple[int, int]) -> Path | None:
        url = source.tile_url(*cell)
        key = hashlib.sha256((source.id + "\n" + source.index_sha256 + "\n" + url).encode()).hexdigest()
        receipt_path = self._cache_root / "receipts" / (key + ".json")
        if not receipt_path.exists() or receipt_path.is_symlink() or receipt_path.stat().st_size > 4096:
            return None
        receipt = loads_strict_json(receipt_path.read_bytes(), description="elevation receipt")
        if not isinstance(receipt, dict) or not isinstance(receipt.get("sha256"), str):
            raise ElevationProviderError("dem-receipt-invalid")
        blob = self._cache_root / "blobs" / (receipt["sha256"] + ".tif")
        if not blob.exists() or blob.is_symlink():
            return None
        stat = blob.stat()
        identity = (stat.st_size, stat.st_mtime_ns)
        with self._lock:
            verified = self._verified.get(receipt["sha256"]) == identity
        if not verified:
            try:
                self._cache().stage(source, cell)
            except (OSError, ValueError):
                raise ElevationProviderError("dem-receipt-invalid") from None
            with self._lock:
                self._verified[receipt["sha256"]] = identity
        return blob

    def sample(
        self,
        points: Sequence[tuple[float, float]],
        *,
        installation_id: str,
        deadline: float,
    ) -> ProviderSamples:
        del installation_id
        reason = self.unavailable_reason()
        if reason is not None:
            raise ElevationProviderError(reason)
        assignments: dict[tuple[str, tuple[int, int]], list[int]] = {}
        uncovered = 0
        unstaged: set[tuple[int, int]] = set()
        indexes = {source.id: self._index(source) for source in self._policy.sources}
        if any(index is None for index in indexes.values()):
            raise ElevationProviderError("dem-index-not-staged")
        sources = {source.id: source for source in self._policy.sources}
        for position, (lat, lon) in enumerate(points):
            cell = dem_cell(lat, lon)
            source = next(
                (candidate for candidate in self._policy.sources if cell in indexes[candidate.id]),  # type: ignore[operator]
                None,
            )
            if source is None:
                uncovered += 1
                continue
            assignments.setdefault((source.id, cell), []).append(position)
        if len(assignments) > DEM_MAXIMUM_TILES:
            raise ElevationProviderError("dem-too-many-tiles")
        values: list[float | None] = [None] * len(points)
        used_sources: set[str] = set()
        for (source_id, cell), positions in sorted(assignments.items()):
            if self._clock() >= deadline:
                raise ElevationProviderError("deadline-exceeded")
            blob = self._staged_tile(sources[source_id], cell)
            if blob is None:
                unstaged.add(cell)
                continue
            sampled = sample_copernicus_tile(blob, cell, [points[position] for position in positions],
                                             deadline=deadline, clock=self._clock)
            for position, value in zip(positions, sampled):
                values[position] = value
            used_sources.add(source_id)
        if not used_sources:
            raise ElevationProviderError("dem-no-staged-coverage")
        ordered = [source for source in self._policy.sources if source.id in used_sources]
        identifier = "+".join(source.id for source in ordered)
        source = ElevationSource(
            kind="internal-dem",
            identifier=identifier,
            version=",".join(sorted({source.dataset_release for source in ordered})),
            vertical_datum="EGM2008 (EPSG:3855)",
            native_resolution_m=float(max(source.resolution_m for source in ordered)),
            surface_model="dsm",
            interpolation="bilinear",
            attribution=route_elevation_notices([source.id for source in ordered]),
            retrieved_at=None,
            qualification=(
                "production-approved"
                if all(source.production_approved for source in ordered)
                else "development-unqualified"
            ),
        )
        return ProviderSamples(
            values=tuple(values),
            source=source,
            diagnostics={
                "tiles": len(assignments) - len(unstaged),
                "unstagedTiles": len(unstaged),
                "uncoveredPoints": uncovered,
            },
        )


def sample_copernicus_tile(
    path: Path,
    cell: tuple[int, int],
    points: Sequence[tuple[float, float]],
    *,
    deadline: float,
    clock: Callable[[], float] = time.monotonic,
) -> list[float | None]:
    """Windowed bilinear sampling with the map pipeline's pixel-centre convention."""

    import numpy as np
    import rasterio
    from rasterio.windows import Window

    from .topography_raster import validate_copernicus_dataset

    results: list[float | None] = [None] * len(points)
    with rasterio.Env(
        GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR",
        GDAL_PAM_ENABLED=False,
        GDAL_NUM_THREADS="1",
        GDAL_CACHEMAX=32 * 1024 * 1024,
        PROJ_NETWORK="OFF",
    ):
        with rasterio.open(path, driver="GTiff", sharing=False) as dataset:
            validate_copernicus_dataset(dataset, list(cell))
            transform = dataset.transform
            width, height = dataset.width, dataset.height
            for start in range(0, len(points), DEM_POINTS_PER_WINDOW):
                if clock() >= deadline:
                    raise ElevationProviderError("deadline-exceeded")
                chunk = points[start:start + DEM_POINTS_PER_WINDOW]
                columns = np.array([(lon - transform.c) / transform.a - 0.5 for _, lon in chunk])
                rows = np.array([(lat - transform.f) / transform.e - 0.5 for lat, _ in chunk])
                inside = (
                    np.isfinite(columns)
                    & np.isfinite(rows)
                    & (columns >= -0.5)
                    & (columns < width - 0.5)
                    & (rows >= -0.5)
                    & (rows < height - 0.5)
                )
                if not inside.any():
                    continue
                columns = np.clip(columns, 0, width - 1)
                rows = np.clip(rows, 0, height - 1)
                c0 = np.floor(columns).astype("int64")
                r0 = np.floor(rows).astype("int64")
                c1 = np.minimum(c0 + 1, width - 1)
                r1 = np.minimum(r0 + 1, height - 1)
                left, top = int(c0[inside].min()), int(r0[inside].min())
                right, bottom = int(c1[inside].max()) + 1, int(r1[inside].max()) + 1
                if (right - left) * (bottom - top) > DEM_MAXIMUM_WINDOW_PIXELS:
                    raise ElevationProviderError("dem-window-too-large")
                window = Window(left, top, right - left, bottom - top)
                native = dataset.read(1, window=window)
                valid = (dataset.read_masks(1, window=window) != 0) & np.isfinite(native)
                if np.any(valid & ((native < -12000) | (native > 10000))):
                    raise ElevationProviderError("dem-invalid-tile")
                dx = columns - c0
                dy = rows - r0
                for offset in np.flatnonzero(inside):
                    total = 0.0
                    usable = True
                    for rr, cc, weight in (
                        (r0[offset], c0[offset], (1 - dx[offset]) * (1 - dy[offset])),
                        (r0[offset], c1[offset], dx[offset] * (1 - dy[offset])),
                        (r1[offset], c0[offset], (1 - dx[offset]) * dy[offset]),
                        (r1[offset], c1[offset], dx[offset] * dy[offset]),
                    ):
                        if weight <= 0:
                            continue
                        if not valid[rr - top, cc - left]:
                            usable = False
                            break
                        total += float(native[rr - top, cc - left]) * float(weight)
                    if usable:
                        results[start + int(offset)] = total
    return results
