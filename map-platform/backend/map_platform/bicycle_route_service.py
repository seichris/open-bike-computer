"""General point-to-point bicycle routes with a rider-chosen profile.

Create a Route builds a multi-stop route one leg at a time. For bicycle legs
the app offers four Valhalla bicycle profiles (road, gravel, everyday,
mountain); each leg is one request to this endpoint carrying exactly two
coordinates, the leg's origin and destination. A request may also ask for up
to two alternative routes and a surface breakdown of each route. They are forwarded to Bicino's internal Valhalla
service with the ``bicycle`` costing and the profile's costing options; the
response is a bicycle route whose maneuvers are all ``travel_mode ==
"bicycle"``.

The service shares the upstream with saved-route detours but has its own
concurrency slots, timeout and rate limits, so leg planning cannot take the
detour slots a rider needs mid-ride.

Neither coordinates nor routes are stored or logged. Logs carry only outcome
codes and the profile name. The upstream URL is an internal service address
and never leaves the server.
"""

from __future__ import annotations

import logging
import os
import threading
from dataclasses import dataclass
from types import MappingProxyType
from typing import Any, Mapping

from .route_elevation_providers import ElevationTransport, UrllibElevationTransport
from .valhalla_bicycle import (
    ATTRIBUTION,
    MINIMUM_SEPARATION_METERS,
    PROVIDER_ID,
    DEFAULT_SIZE_LIMITS,
    MapPoint,
    RouteSizeLimits,
    ValhallaBicycleRouter,
    ValhallaUnavailableError,
    bicycle_route_body,
    break_location,
    environment_enabled,
    environment_integer,
    haversine_meters,
    parse_locale,
    parse_point,
    parse_request_id,
    upstream_route_url,
)

REQUEST_SCHEMA = "bicino-bicycle-route-request-v1"
RESPONSE_SCHEMA = "bicino-bicycle-route-response-v1"
REQUEST_FIELDS = frozenset({
    "schema", "requestId", "origin", "destination", "profile", "locale", "alternatives", "surfaces",
})
MAXIMUM_ALTERNATIVES = 2
POINT_FIELDS = frozenset({"latitudeE6", "longitudeE6"})

# Rider-facing profile -> Valhalla bicycle costing options. Valhalla 3.9.2
# lowercases bicycle_type and treats anything other than road, cross or
# mountain as hybrid, so only these exact values are sent. The type also sets
# the default speed (road 25, cross 20, hybrid 18 km/h), the per-surface speed
# factors and the worst surface the bike tolerates before avoid_bad_surfaces
# applies (road: compacted, cross: gravel, hybrid: dirt).
# - road: smooth surfaces first. avoid_bad_surfaces 0.9 penalises unpaved
#   surfaces heavily without making them impassable (1.0 would), so a leg that
#   starts or ends on a short unpaved stretch still routes.
# - gravel: a cyclocross/gravel bike that tolerates unpaved surfaces and
#   prefers quieter ways over roads.
# - everyday: a city/hybrid bike, low-stress streets, mild hill avoidance,
#   moderate dislike of rough surfaces.
# - mountain: a mountain bike (default 16 km/h) that accepts any surface the
#   graph allows bicycles on and prefers paths and tracks over roads.
# Ferries are never used. use_hills has no effect on graphs built without
# elevation (the current graphs).
PROFILES: Mapping[str, Mapping[str, Any]] = MappingProxyType({
    "road": MappingProxyType({
        "bicycle_type": "road",
        "use_roads": 0.5,
        "use_hills": 0.5,
        "use_ferry": 0.0,
        "avoid_bad_surfaces": 0.9,
    }),
    "gravel": MappingProxyType({
        "bicycle_type": "cross",
        "use_roads": 0.2,
        "use_hills": 0.5,
        "use_ferry": 0.0,
        "avoid_bad_surfaces": 0.0,
    }),
    "everyday": MappingProxyType({
        "bicycle_type": "hybrid",
        "use_roads": 0.25,
        "use_hills": 0.25,
        "use_ferry": 0.0,
        "avoid_bad_surfaces": 0.5,
    }),
    "mountain": MappingProxyType({
        "bicycle_type": "mountain",
        "use_roads": 0.1,
        "use_hills": 0.5,
        "use_ferry": 0.0,
        "avoid_bad_surfaces": 0.0,
    }),
})
PROFILE_NAMES = ("road", "gravel", "everyday", "mountain")
DEFAULT_MAXIMUM_SEPARATION_METERS = 150_000
DEFAULT_TIMEOUT_SECONDS = 15
DEFAULT_MAXIMUM_CONCURRENT = 2
_LOGGER = logging.getLogger(__name__)


def route_size_limits(maximum_separation_meters: float) -> RouteSizeLimits:
    """Answer-size caps that grow with the longest leg the service accepts.

    Measured 2026-11-24 on UAE, Oman, Saudi and Argentina legs of 60-218 km:
    at most 30 shape points, 1.8 maneuvers and 1 KiB of Valhalla JSON per
    route kilometre, with routes up to about 1.5 times the straight-line
    separation. The per-straight-line-kilometre budgets below leave roughly a
    five- to tenfold margin and never fall below the detour caps. A route that
    still exceeds them is ``request_too_long``.
    """

    kilometres = maximum_separation_meters / 1000
    return RouteSizeLimits(
        upstream_bytes=max(DEFAULT_SIZE_LIMITS.upstream_bytes, int(kilometres * 10 * 1024)),
        shape_points=max(DEFAULT_SIZE_LIMITS.shape_points, int(kilometres * 300)),
        maneuvers=max(DEFAULT_SIZE_LIMITS.maneuvers, int(kilometres * 20)),
    )


class BicycleRouteRequestError(ValueError):
    def __init__(self, message: str):
        super().__init__(message)
        self.code = "bicycle_route_invalid_request"


class BicycleRouteBusyError(RuntimeError):
    retry_after_seconds = 5


class BicycleRouteUnavailableError(RuntimeError):
    """The internal routing service is unreachable or misbehaving."""

    retry_after_seconds = 30

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


@dataclass(frozen=True)
class BicycleRouteRequest:
    request_id: str
    origin: MapPoint
    destination: MapPoint
    profile: str
    locale: str
    alternatives: int = 0
    surfaces: bool = False


def parse_request(payload: Any, *, maximum_separation_meters: float) -> BicycleRouteRequest:
    error = BicycleRouteRequestError
    if not isinstance(payload, dict):
        raise error("request body must be a JSON object")
    unknown = set(payload) - REQUEST_FIELDS
    if unknown:
        raise error("request has invalid fields: " + ", ".join(sorted(unknown)))
    if payload.get("schema") != REQUEST_SCHEMA:
        raise error("unsupported request schema")
    request_id = parse_request_id(payload, error)
    origin, _ = parse_point(payload.get("origin"), POINT_FIELDS, "origin", error)
    destination, _ = parse_point(payload.get("destination"), POINT_FIELDS, "destination", error)
    profile = payload.get("profile")
    if not isinstance(profile, str) or profile not in PROFILES:
        raise error("profile must be one of " + ", ".join(PROFILE_NAMES))
    locale = parse_locale(payload, error)
    alternatives = payload.get("alternatives", 0)
    if type(alternatives) is not int or not 0 <= alternatives <= MAXIMUM_ALTERNATIVES:
        raise error(f"alternatives must be an integer from 0 to {MAXIMUM_ALTERNATIVES}")
    surfaces = payload.get("surfaces", False)
    if type(surfaces) is not bool:
        raise error("surfaces must be true or false")
    separation = haversine_meters(origin, destination)
    if separation < MINIMUM_SEPARATION_METERS:
        raise error("origin and destination are too close for a route")
    if separation > maximum_separation_meters:
        raise error("origin and destination are too far apart for a route")
    return BicycleRouteRequest(
        request_id=request_id,
        origin=origin,
        destination=destination,
        profile=profile,
        locale=locale,
        alternatives=alternatives,
        surfaces=surfaces,
    )


def upstream_body(request: BicycleRouteRequest) -> bytes:
    return bicycle_route_body(
        break_location(request.origin),
        request.destination,
        PROFILES[request.profile],
        request.locale,
        alternates=request.alternatives,
    )


class BicycleRouteService:
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
                log_label="bicycle route",
                size_limits=route_size_limits(maximum_separation_meters),
            )
            if route_url is not None
            else None
        )
        self._slots = threading.BoundedSemaphore(maximum_concurrent)
        self._maximum_separation_meters = maximum_separation_meters

    @classmethod
    def from_environment(cls, *, transport: ElevationTransport | None = None) -> "BicycleRouteService":
        upstream = os.environ.get("MAP_PLATFORM_BICYCLE_ROUTING_UPSTREAM_URL") or None
        if not environment_enabled("MAP_PLATFORM_BICYCLE_ROUTE_ENABLED"):
            upstream = None
        return cls(
            upstream,
            transport=transport,
            timeout_seconds=float(environment_integer(
                "MAP_PLATFORM_BICYCLE_ROUTE_TIMEOUT_SECONDS", DEFAULT_TIMEOUT_SECONDS, 2, 60,
            )),
            maximum_concurrent=environment_integer(
                "MAP_PLATFORM_BICYCLE_ROUTE_MAX_CONCURRENT", DEFAULT_MAXIMUM_CONCURRENT, 1, 32,
            ),
            maximum_separation_meters=float(environment_integer(
                "MAP_PLATFORM_BICYCLE_ROUTE_MAX_SEPARATION_METERS",
                DEFAULT_MAXIMUM_SEPARATION_METERS, 1_000, 500_000,
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
            "profiles": list(PROFILE_NAMES),
            "maximumAlternatives": MAXIMUM_ALTERNATIVES,
            "surfaces": True,
            "maximumSeparationMeters": int(self._maximum_separation_meters),
        }

    def public_summary(self) -> dict[str, Any]:
        return {"enabled": self.enabled, "provider": PROVIDER_ID}

    def create_route(self, payload: Any) -> dict[str, Any]:
        request = parse_request(payload, maximum_separation_meters=self._maximum_separation_meters)
        if self._router is None:
            return _unavailable("service_disabled")
        if not self._slots.acquire(blocking=False):
            raise BicycleRouteBusyError()
        try:
            return self._route(request)
        finally:
            self._slots.release()

    def _route(self, request: BicycleRouteRequest) -> dict[str, Any]:
        assert self._router is not None
        try:
            outcome = self._router.route(upstream_body(request))
        except ValhallaUnavailableError as exc:
            raise BicycleRouteUnavailableError(exc.reason) from None
        if outcome.route is None:
            return _unavailable(outcome.reason or "no_bicycle_route")
        routes = [outcome.route, *outcome.alternatives[: request.alternatives]]
        answered = []
        for route, shape in zip(routes, outcome.shapes):
            item = {**route, "profile": request.profile}
            if request.surfaces:
                breakdown = self._router.surface_breakdown(shape)
                if breakdown is not None:
                    item["surfaces"] = breakdown
            answered.append(item)
        _LOGGER.info(
            "bicycle route outcome=ready profile=%s maneuvers=%d alternatives=%d surfaces=%d",
            request.profile,
            len(answered[0]["maneuvers"]),
            len(answered) - 1,
            sum(1 for item in answered if "surfaces" in item),
        )
        body: dict[str, Any] = {"schema": RESPONSE_SCHEMA, "status": "ready", "route": answered[0], "reason": None}
        if request.alternatives:
            body["alternatives"] = answered[1:]
        return body


def _unavailable(reason: str) -> dict[str, Any]:
    return {"schema": RESPONSE_SCHEMA, "status": "unavailable", "route": None, "reason": reason}
