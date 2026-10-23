"""Bounded, installation-scoped route elevation profile service.

The service never persists route geometry. A request's coordinates exist only
for the duration of the request; the short replay cache below holds the
derived profile (distances and heights, no coordinates) in process memory so
an immediate client retry does not spend provider credits again.
"""

from __future__ import annotations

import logging
import os
import re
import threading
import time
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from .route_elevation import (
    QUALITY_COMPLETE,
    QUALITY_UNAVAILABLE,
    RouteElevationError,
    RouteElevationProfile,
    StructureCorrection,
    parse_route_geometry,
    plan_sampling,
    process_profile,
    sample_coordinates,
)
from .route_elevation_providers import (
    KNOWN_PROVIDERS,
    PROVIDER_COPERNICUS,
    PROVIDER_GEOAPIFY,
    CopernicusRouteElevationProvider,
    ElevationProviderError,
    ElevationTransport,
    GeoapifyConfig,
    GeoapifyElevationProvider,
    ProviderCreditLedger,
    RouteElevationProvider,
)
from .route_elevation_structures import TRAVEL_MODES, StructureAnnotator, StructureIndexError
from .topography_sources import TopographySourcePolicy

REQUEST_SCHEMA = "bicino-route-elevation-request-v1"
RESPONSE_SCHEMA = "bicino-route-elevation-response-v1"
REQUEST_FIELDS = frozenset({"schema", "requestId", "geometry", "travelMode", "routeSource"})
GEOMETRY_FIELDS = frozenset({"crs", "coordinatesE6", "digest"})
# Apple Maps routes use the same transient processing as imported GPX routes.
# Strava API routes remain excluded by the app's provider policy.
PERMITTED_ROUTE_SOURCES = frozenset({"gpx", "mapkit", "saved", "other"})
REJECTED_ROUTE_SOURCES = frozenset({"strava"})
DEFAULT_PROVIDER_ORDER = (PROVIDER_GEOAPIFY, PROVIDER_COPERNICUS)
DEFAULT_DEADLINE_SECONDS = 25.0
DEFAULT_MAXIMUM_CONCURRENT = 2
REPLAY_TTL_SECONDS = 600.0
REPLAY_ENTRIES = 32
_UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
_LOGGER = logging.getLogger(__name__)


class RouteElevationRequestError(ValueError):
    def __init__(self, message: str):
        super().__init__(message)
        self.code = "route_elevation_invalid_request"


class RouteElevationBusyError(RuntimeError):
    retry_after_seconds = 5


@dataclass(frozen=True)
class RouteElevationRequest:
    request_id: str
    travel_mode: str
    route_source: str
    geometry_payload: Mapping[str, Any]


def parse_request(payload: Any) -> RouteElevationRequest:
    if not isinstance(payload, dict):
        raise RouteElevationRequestError("request body must be a JSON object")
    unknown = set(payload) - REQUEST_FIELDS
    if unknown:
        raise RouteElevationRequestError("request has invalid fields: " + ", ".join(sorted(unknown)))
    if payload.get("schema") != REQUEST_SCHEMA:
        raise RouteElevationRequestError("unsupported request schema")
    request_id = payload.get("requestId")
    if not isinstance(request_id, str) or _UUID.fullmatch(request_id) is None:
        raise RouteElevationRequestError("requestId must be a lowercase UUID")
    travel_mode = payload.get("travelMode", "cycling")
    if travel_mode not in TRAVEL_MODES:
        raise RouteElevationRequestError("unsupported travelMode")
    route_source = payload.get("routeSource")
    if route_source in REJECTED_ROUTE_SOURCES:
        raise RouteElevationRequestError("route source is not permitted for elevation processing")
    if route_source not in PERMITTED_ROUTE_SOURCES:
        raise RouteElevationRequestError("unsupported routeSource")
    geometry = payload.get("geometry")
    if not isinstance(geometry, dict) or set(geometry) - GEOMETRY_FIELDS:
        raise RouteElevationRequestError("geometry has invalid fields")
    if not isinstance(geometry.get("digest"), str):
        raise RouteElevationRequestError("geometry.digest is required")
    return RouteElevationRequest(request_id, travel_mode, route_source, geometry)


def _environment_flag(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    value = raw.strip().lower()
    if value in {"1", "true", "yes"}:
        return True
    if value in {"0", "false", "no"}:
        return False
    raise ValueError(f"{name} must be true or false")


def _environment_integer(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    value = int(raw)
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


def configured_provider_order() -> tuple[str, ...]:
    raw = os.environ.get("MAP_PLATFORM_ROUTE_ELEVATION_PROVIDERS")
    if raw is None or raw.strip() == "":
        return DEFAULT_PROVIDER_ORDER
    names = tuple(name.strip() for name in raw.split(",") if name.strip())
    if not names or len(set(names)) != len(names) or any(name not in KNOWN_PROVIDERS for name in names):
        raise ValueError("MAP_PLATFORM_ROUTE_ELEVATION_PROVIDERS must list geoapify and/or copernicus once")
    return names


class RouteElevationService:
    def __init__(
        self,
        providers: Sequence[RouteElevationProvider],
        annotator: StructureAnnotator,
        *,
        enabled: bool = True,
        maximum_concurrent: int = DEFAULT_MAXIMUM_CONCURRENT,
        deadline_seconds: float = DEFAULT_DEADLINE_SECONDS,
        clock: Callable[[], float] = time.monotonic,
    ):
        self._providers = tuple(providers)
        self._annotator = annotator
        self._enabled = enabled
        self._deadline_seconds = deadline_seconds
        self._clock = clock
        self._slots = threading.BoundedSemaphore(maximum_concurrent)
        self._replay: OrderedDict[tuple[str, str, str], tuple[float, dict[str, Any]]] = OrderedDict()
        self._replay_lock = threading.Lock()

    @classmethod
    def from_environment(
        cls,
        *,
        data_root: Path,
        pseudonym_secret: str,
        topography_policy: TopographySourcePolicy,
        deployment_channel: str,
        transport: ElevationTransport | None = None,
    ) -> "RouteElevationService":
        ledger = ProviderCreditLedger(data_root / "route-elevation.sqlite3", pseudonym_secret)
        available: dict[str, RouteElevationProvider] = {
            PROVIDER_GEOAPIFY: GeoapifyElevationProvider(
                GeoapifyConfig.from_environment(), ledger, transport=transport,
            ),
            PROVIDER_COPERNICUS: CopernicusRouteElevationProvider(
                topography_policy,
                Path(os.environ.get("MAP_PLATFORM_ROUTE_ELEVATION_DEM_CACHE") or data_root / "topography-cache"),
                enabled=_environment_flag("MAP_PLATFORM_ROUTE_ELEVATION_DEM_ENABLED", False),
                deployment_channel=deployment_channel,
            ),
        }
        structure_directory = os.environ.get("MAP_PLATFORM_ROUTE_ELEVATION_STRUCTURE_INDEX_DIR")
        try:
            annotator = StructureAnnotator.from_directory(Path(structure_directory) if structure_directory else None)
        except StructureIndexError as exc:
            raise ValueError(f"route elevation structure indexes are invalid: {exc}") from exc
        return cls(
            [available[name] for name in configured_provider_order()],
            annotator,
            enabled=_environment_flag("MAP_PLATFORM_ROUTE_ELEVATION_ENABLED", True),
            maximum_concurrent=_environment_integer("MAP_PLATFORM_ROUTE_ELEVATION_MAX_CONCURRENT", 2, 1, 8),
            deadline_seconds=float(_environment_integer("MAP_PLATFORM_ROUTE_ELEVATION_DEADLINE_SECONDS", 25, 5, 60)),
        )

    @property
    def enabled(self) -> bool:
        return self._enabled

    def available_providers(self) -> list[str]:
        if not self._enabled:
            return []
        return [provider.name for provider in self._providers if provider.unavailable_reason() is None]

    def capability(self) -> dict[str, Any]:
        providers = self.available_providers()
        return {
            "available": bool(providers),
            "schema": REQUEST_SCHEMA,
            "providers": providers,
            "structureCorrection": self._annotator.configured,
        }

    def public_summary(self) -> dict[str, Any]:
        summary: dict[str, Any] = {
            "enabled": self._enabled,
            "providerOrder": [provider.name for provider in self._providers],
            "availableProviders": self.available_providers(),
            "structureCorrection": self._annotator.public_summary(),
        }
        for provider in self._providers:
            describe = getattr(provider, "public_summary", None)
            if callable(describe):
                summary[provider.name] = describe()
        return summary

    def _replay_key(self, installation_id: str, digest: str, travel_mode: str) -> tuple[str, str, str]:
        return installation_id, digest, travel_mode

    def _cached(self, key: tuple[str, str, str]) -> dict[str, Any] | None:
        now = self._clock()
        with self._replay_lock:
            for stale in [item for item, (expires, _) in self._replay.items() if expires <= now]:
                del self._replay[stale]
            entry = self._replay.get(key)
            if entry is None:
                return None
            self._replay.move_to_end(key)
            return entry[1]

    def _remember(self, key: tuple[str, str, str], response: dict[str, Any]) -> None:
        with self._replay_lock:
            self._replay[key] = (self._clock() + REPLAY_TTL_SECONDS, response)
            self._replay.move_to_end(key)
            while len(self._replay) > REPLAY_ENTRIES:
                self._replay.popitem(last=False)

    def create_profile(self, payload: Any, *, installation_id: str) -> dict[str, Any]:
        request = parse_request(payload)
        try:
            geometry = parse_route_geometry(dict(request.geometry_payload))
            plan = plan_sampling(geometry.length_m)
        except RouteElevationError as exc:
            raise RouteElevationRequestError(str(exc)) from exc
        key = self._replay_key(installation_id, geometry.digest, request.travel_mode)
        cached = self._cached(key)
        if cached is not None:
            return cached
        if not self._enabled:
            return _unavailable([{"provider": None, "status": "unavailable", "reason": "service-disabled"}], None)
        if not self._slots.acquire(blocking=False):
            raise RouteElevationBusyError()
        try:
            response = self._resolve(geometry, plan, request, installation_id)
        finally:
            self._slots.release()
        if response["status"] == "ready":
            self._remember(key, response)
        return response

    def _resolve(self, geometry, plan, request: RouteElevationRequest, installation_id: str) -> dict[str, Any]:
        deadline = self._clock() + self._deadline_seconds
        points = sample_coordinates(geometry, plan)
        try:
            spans, correction = self._annotator.annotate(geometry, travel_mode=request.travel_mode)
        except (StructureIndexError, ValueError):
            spans, correction = [], StructureCorrection(status="unavailable", reason="structure-index-error")
        attempts: list[dict[str, Any]] = []
        best: RouteElevationProfile | None = None
        retry_after: int | None = None
        for provider in self._providers:
            reason = provider.unavailable_reason()
            if reason is not None:
                attempts.append({"provider": provider.name, "status": "unavailable", "reason": reason})
                continue
            if self._clock() >= deadline:
                attempts.append({"provider": provider.name, "status": "skipped", "reason": "deadline-exceeded"})
                continue
            try:
                samples = provider.sample(points, installation_id=installation_id, deadline=deadline)
            except ElevationProviderError as exc:
                attempts.append({"provider": provider.name, "status": "failed", "reason": exc.code})
                if exc.retry_after_seconds is not None:
                    retry_after = max(retry_after or 0, exc.retry_after_seconds)
                _LOGGER.info("route elevation provider=%s failed code=%s", provider.name, exc.code)
                continue
            profile = process_profile(
                geometry,
                plan,
                samples.values,
                samples.source,
                structures=spans,
                structure_correction=correction,
            )
            attempts.append({
                "provider": provider.name,
                "status": profile.quality.status,
                "coverage": round(profile.quality.coverage, 4),
                "creditsUsed": samples.credits_used,
            })
            if best is None or profile.quality.coverage > best.quality.coverage:
                best = profile
            if profile.quality.status == QUALITY_COMPLETE:
                break
            if profile.quality.unknown_distance_m <= 0.5:
                # Only structure ambiguity remains; another terrain source
                # cannot resolve which road level the route uses.
                break
        if best is None or best.quality.status == QUALITY_UNAVAILABLE:
            return _unavailable(attempts, retry_after)
        return {
            "schema": RESPONSE_SCHEMA,
            "status": "ready",
            "profile": best.to_dict(),
            "attempts": attempts,
            "retryAfterSeconds": None,
        }


def _unavailable(attempts: list[dict[str, Any]], retry_after: int | None) -> dict[str, Any]:
    return {
        "schema": RESPONSE_SCHEMA,
        "status": "unavailable",
        "profile": None,
        "attempts": attempts,
        "retryAfterSeconds": retry_after,
    }
