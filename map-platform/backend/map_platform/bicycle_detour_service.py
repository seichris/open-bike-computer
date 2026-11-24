"""Temporary bicycle detours back to a saved route.

The app asks Apple MapKit for cycling directions first. Only when MapKit has
no cycling route for that request (for example outside Apple's cycling
coverage, such as the United Arab Emirates) does it ask this endpoint. The
request carries exactly two coordinates: the rider's current position and one
rejoin point on the saved route. They are forwarded to Bicino's own internal
Valhalla service with the bicycle costing only; the response is a bicycle
route whose maneuvers are all ``travel_mode == "bicycle"``.

Neither coordinates nor routes are stored or logged. Logs carry only outcome
codes. The upstream URL is an internal service address and never leaves the
server.
"""

from __future__ import annotations

import logging
import os
import threading
from dataclasses import dataclass
from typing import Any

from .route_elevation_providers import ElevationTransport, UrllibElevationTransport
from .valhalla_bicycle import (  # noqa: F401 - decode_polyline6 is re-exported
    ATTRIBUTION,
    MINIMUM_SEPARATION_METERS,
    PROVIDER_ID,
    MapPoint,
    ValhallaBicycleRouter,
    ValhallaUnavailableError,
    bicycle_route_body,
    decode_polyline6,
    environment_enabled,
    environment_integer,
    haversine_meters,
    parse_locale,
    parse_point,
    parse_request_id,
    upstream_route_url,
)

REQUEST_SCHEMA = "bicino-bicycle-detour-request-v1"
RESPONSE_SCHEMA = "bicino-bicycle-detour-response-v1"
REQUEST_FIELDS = frozenset({"schema", "requestId", "origin", "rejoin", "routeSource", "locale"})
ORIGIN_FIELDS = frozenset({"latitudeE6", "longitudeE6", "courseDegrees"})
REJOIN_FIELDS = frozenset({"latitudeE6", "longitudeE6"})
# Provenance of the saved route the rider is returning to. Strava API imports
# were approved by the maintainer on 2026-11-21 on the same terms as GPX and
# saved Apple Maps routes; only the two points above are sent.
ROUTE_SOURCES = frozenset({"gpx", "strava", "mapkit"})
# Valhalla 3.9.2 lowercases bicycle_type, so "hybrid" selects the hybrid
# (city) bicycle explicitly; see valhalla_bicycle.
BICYCLE_COSTING_OPTIONS = {
    "bicycle_type": "hybrid",
    "use_roads": 0.25,
    "use_hills": 0.5,
    "use_ferry": 0.0,
    "avoid_bad_surfaces": 0.25,
}
DEFAULT_MAXIMUM_SEPARATION_METERS = 15_000
DEFAULT_TIMEOUT_SECONDS = 8
DEFAULT_MAXIMUM_CONCURRENT = 4
_LOGGER = logging.getLogger(__name__)


class BicycleDetourRequestError(ValueError):
    def __init__(self, message: str):
        super().__init__(message)
        self.code = "bicycle_detour_invalid_request"


class BicycleDetourBusyError(RuntimeError):
    retry_after_seconds = 5


class BicycleDetourUnavailableError(RuntimeError):
    """The internal routing service is unreachable or misbehaving."""

    retry_after_seconds = 30

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


@dataclass(frozen=True)
class BicycleDetourRequest:
    request_id: str
    origin: MapPoint
    origin_course: float | None
    rejoin: MapPoint
    route_source: str
    locale: str


def parse_request(payload: Any, *, maximum_separation_meters: float) -> BicycleDetourRequest:
    error = BicycleDetourRequestError
    if not isinstance(payload, dict):
        raise error("request body must be a JSON object")
    unknown = set(payload) - REQUEST_FIELDS
    if unknown:
        raise error("request has invalid fields: " + ", ".join(sorted(unknown)))
    if payload.get("schema") != REQUEST_SCHEMA:
        raise error("unsupported request schema")
    request_id = parse_request_id(payload, error)
    origin, origin_payload = parse_point(payload.get("origin"), ORIGIN_FIELDS, "origin", error)
    rejoin, _ = parse_point(payload.get("rejoin"), REJOIN_FIELDS, "rejoin", error)
    course = origin_payload.get("courseDegrees")
    if course is not None:
        if isinstance(course, bool) or not isinstance(course, (int, float)) or not 0 <= course < 360:
            raise error("origin.courseDegrees must be in [0, 360)")
        course = float(course)
    route_source = payload.get("routeSource")
    if route_source not in ROUTE_SOURCES:
        raise error("unsupported routeSource")
    locale = parse_locale(payload, error)
    separation = haversine_meters(origin, rejoin)
    if separation < MINIMUM_SEPARATION_METERS:
        raise error("origin and rejoin are too close for a detour")
    if separation > maximum_separation_meters:
        raise error("origin and rejoin are too far apart for a detour")
    return BicycleDetourRequest(
        request_id=request_id,
        origin=origin,
        origin_course=course,
        rejoin=rejoin,
        route_source=route_source,
        locale=locale,
    )


class BicycleDetourService:
    def __init__(
        self,
        upstream_url: str | None,
        *,
        transport: ElevationTransport | None = None,
        timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
        maximum_concurrent: int = DEFAULT_MAXIMUM_CONCURRENT,
        maximum_separation_meters: float = DEFAULT_MAXIMUM_SEPARATION_METERS,
    ):
        route_url = upstream_route_url(upstream_url) if upstream_url else None
        self._router = (
            ValhallaBicycleRouter(
                route_url,
                transport=transport or UrllibElevationTransport(),
                timeout_seconds=timeout_seconds,
                logger=_LOGGER,
                log_label="bicycle detour",
            )
            if route_url is not None
            else None
        )
        self._slots = threading.BoundedSemaphore(maximum_concurrent)
        self._maximum_separation_meters = maximum_separation_meters

    @classmethod
    def from_environment(cls, *, transport: ElevationTransport | None = None) -> "BicycleDetourService":
        upstream = os.environ.get("MAP_PLATFORM_BICYCLE_ROUTING_UPSTREAM_URL") or None
        if not environment_enabled("MAP_PLATFORM_BICYCLE_DETOUR_ENABLED"):
            upstream = None
        return cls(
            upstream,
            transport=transport,
            timeout_seconds=float(environment_integer(
                "MAP_PLATFORM_BICYCLE_ROUTING_TIMEOUT_SECONDS", DEFAULT_TIMEOUT_SECONDS, 2, 30,
            )),
            maximum_concurrent=environment_integer(
                "MAP_PLATFORM_BICYCLE_DETOUR_MAX_CONCURRENT", DEFAULT_MAXIMUM_CONCURRENT, 1, 32,
            ),
            maximum_separation_meters=float(environment_integer(
                "MAP_PLATFORM_BICYCLE_DETOUR_MAX_SEPARATION_METERS",
                DEFAULT_MAXIMUM_SEPARATION_METERS, 1_000, 50_000,
            )),
        )

    @property
    def enabled(self) -> bool:
        return self._router is not None

    def capability(self) -> dict[str, Any]:
        return {
            "available": self.enabled,
            "schema": REQUEST_SCHEMA,
            "provider": PROVIDER_ID if self.enabled else None,
            "attribution": ATTRIBUTION if self.enabled else None,
            "maximumSeparationMeters": int(self._maximum_separation_meters),
        }

    def public_summary(self) -> dict[str, Any]:
        return {"enabled": self.enabled, "provider": PROVIDER_ID}

    def create_detour(self, payload: Any) -> dict[str, Any]:
        request = parse_request(payload, maximum_separation_meters=self._maximum_separation_meters)
        if self._router is None:
            return _unavailable("service_disabled")
        if not self._slots.acquire(blocking=False):
            raise BicycleDetourBusyError()
        try:
            return self._route(request)
        finally:
            self._slots.release()

    def _upstream_body(self, request: BicycleDetourRequest) -> bytes:
        origin: dict[str, Any] = {
            "lat": request.origin.latitude,
            "lon": request.origin.longitude,
            "type": "break",
        }
        if request.origin_course is not None:
            origin["heading"] = round(request.origin_course)
            origin["heading_tolerance"] = 60
        return bicycle_route_body(origin, request.rejoin, BICYCLE_COSTING_OPTIONS, request.locale)

    def _route(self, request: BicycleDetourRequest) -> dict[str, Any]:
        assert self._router is not None
        try:
            outcome = self._router.route(self._upstream_body(request))
        except ValhallaUnavailableError as exc:
            raise BicycleDetourUnavailableError(exc.reason) from None
        if outcome.route is None:
            return _unavailable(outcome.reason or "no_bicycle_route")
        _LOGGER.info("bicycle detour outcome=ready maneuvers=%d", len(outcome.route["maneuvers"]))
        return {"schema": RESPONSE_SCHEMA, "status": "ready", "route": outcome.route, "reason": None}


def _unavailable(reason: str) -> dict[str, Any]:
    return {"schema": RESPONSE_SCHEMA, "status": "unavailable", "route": None, "reason": reason}
