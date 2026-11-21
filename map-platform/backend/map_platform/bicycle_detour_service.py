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

import json
import logging
import math
import os
import re
import threading
from dataclasses import dataclass
from typing import Any, Mapping
from urllib.parse import urlsplit

from .route_elevation_providers import (
    ElevationProviderError,
    ElevationTransport,
    UrllibElevationTransport,
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
PROVIDER_ID = "bicino.valhalla"
ATTRIBUTION = "© OpenStreetMap contributors"
BICYCLE_COSTING_OPTIONS = {
    "bicycle_type": "hybrid",
    "use_roads": 0.25,
    "use_hills": 0.5,
    "use_ferry": 0.0,
    "avoid_bad_surfaces": 0.25,
}
MINIMUM_SEPARATION_METERS = 10.0
DEFAULT_MAXIMUM_SEPARATION_METERS = 15_000
DEFAULT_TIMEOUT_SECONDS = 8
DEFAULT_MAXIMUM_CONCURRENT = 4
MAXIMUM_UPSTREAM_BYTES = 2 * 1024 * 1024
MAXIMUM_SHAPE_POINTS = 20_000
MAXIMUM_MANEUVERS = 1_000
NO_ROUTE_ERROR_CODES = frozenset({170, 171, 442, 443})
TOO_LONG_ERROR_CODES = frozenset({154})
_UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
_LOCALE = re.compile(r"[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8}){0,3}")
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
class DetourPoint:
    latitude_e6: int
    longitude_e6: int

    @property
    def latitude(self) -> float:
        return self.latitude_e6 / 1_000_000

    @property
    def longitude(self) -> float:
        return self.longitude_e6 / 1_000_000


@dataclass(frozen=True)
class BicycleDetourRequest:
    request_id: str
    origin: DetourPoint
    origin_course: float | None
    rejoin: DetourPoint
    route_source: str
    locale: str


def _point(value: Any, allowed: frozenset[str], name: str) -> tuple[DetourPoint, Mapping[str, Any]]:
    if not isinstance(value, dict) or set(value) - allowed:
        raise BicycleDetourRequestError(f"{name} has invalid fields")
    latitude = value.get("latitudeE6")
    longitude = value.get("longitudeE6")
    if (
        type(latitude) is not int or type(longitude) is not int
        or not -90_000_000 <= latitude <= 90_000_000
        or not -180_000_000 <= longitude <= 180_000_000
    ):
        raise BicycleDetourRequestError(f"{name} must hold integer microdegrees")
    return DetourPoint(latitude, longitude), value


def haversine_meters(a: DetourPoint, b: DetourPoint) -> float:
    radius = 6_371_008.8
    lat1, lat2 = math.radians(a.latitude), math.radians(b.latitude)
    d_lat = lat2 - lat1
    d_lon = math.radians(b.longitude - a.longitude)
    h = math.sin(d_lat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(d_lon / 2) ** 2
    return 2 * radius * math.asin(min(1.0, math.sqrt(h)))


def parse_request(payload: Any, *, maximum_separation_meters: float) -> BicycleDetourRequest:
    if not isinstance(payload, dict):
        raise BicycleDetourRequestError("request body must be a JSON object")
    unknown = set(payload) - REQUEST_FIELDS
    if unknown:
        raise BicycleDetourRequestError("request has invalid fields: " + ", ".join(sorted(unknown)))
    if payload.get("schema") != REQUEST_SCHEMA:
        raise BicycleDetourRequestError("unsupported request schema")
    request_id = payload.get("requestId")
    if not isinstance(request_id, str) or _UUID.fullmatch(request_id) is None:
        raise BicycleDetourRequestError("requestId must be a lowercase UUID")
    origin, origin_payload = _point(payload.get("origin"), ORIGIN_FIELDS, "origin")
    rejoin, _ = _point(payload.get("rejoin"), REJOIN_FIELDS, "rejoin")
    course = origin_payload.get("courseDegrees")
    if course is not None:
        if isinstance(course, bool) or not isinstance(course, (int, float)) or not 0 <= course < 360:
            raise BicycleDetourRequestError("origin.courseDegrees must be in [0, 360)")
        course = float(course)
    route_source = payload.get("routeSource")
    if route_source not in ROUTE_SOURCES:
        raise BicycleDetourRequestError("unsupported routeSource")
    locale = payload.get("locale", "en-US")
    if not isinstance(locale, str) or len(locale) > 35 or _LOCALE.fullmatch(locale) is None:
        raise BicycleDetourRequestError("locale must be a BCP 47 language tag")
    separation = haversine_meters(origin, rejoin)
    if separation < MINIMUM_SEPARATION_METERS:
        raise BicycleDetourRequestError("origin and rejoin are too close for a detour")
    if separation > maximum_separation_meters:
        raise BicycleDetourRequestError("origin and rejoin are too far apart for a detour")
    return BicycleDetourRequest(
        request_id=request_id,
        origin=origin,
        origin_course=course,
        rejoin=rejoin,
        route_source=route_source,
        locale=locale.replace("_", "-"),
    )


def decode_polyline6(encoded: str) -> list[tuple[int, int]]:
    """Decodes a Valhalla precision-6 polyline into (latE6, lonE6) pairs."""

    points: list[tuple[int, int]] = []
    index = latitude = longitude = 0
    length = len(encoded)
    while index < length:
        deltas = []
        for _ in range(2):
            shift = result = 0
            while True:
                if index >= length:
                    raise ValueError("truncated polyline")
                byte = ord(encoded[index]) - 63
                index += 1
                if byte < 0 or byte > 63:
                    raise ValueError("invalid polyline byte")
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20:
                    break
                if shift > 35:
                    raise ValueError("polyline value overflow")
            deltas.append(~(result >> 1) if result & 1 else result >> 1)
        latitude += deltas[0]
        longitude += deltas[1]
        if not -90_000_000 <= latitude <= 90_000_000 or not -180_000_000 <= longitude <= 180_000_000:
            raise ValueError("polyline coordinate out of range")
        points.append((latitude, longitude))
        if len(points) > MAXIMUM_SHAPE_POINTS:
            raise ValueError("polyline has too many points")
    return points


def _upstream_route_url(raw: str) -> str:
    parts = urlsplit(raw.strip())
    if (
        parts.scheme not in {"http", "https"} or not parts.hostname or parts.username
        or parts.password or parts.query or parts.fragment or parts.path not in {"", "/"}
    ):
        raise ValueError(
            "MAP_PLATFORM_BICYCLE_ROUTING_UPSTREAM_URL must be an internal http(s) origin without a path"
        )
    return f"{parts.scheme}://{parts.netloc}/route"


def _environment_integer(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    value = int(raw)
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


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
        self._route_url = _upstream_route_url(upstream_url) if upstream_url else None
        self._transport = transport or UrllibElevationTransport()
        self._timeout_seconds = timeout_seconds
        self._slots = threading.BoundedSemaphore(maximum_concurrent)
        self._maximum_separation_meters = maximum_separation_meters

    @classmethod
    def from_environment(cls, *, transport: ElevationTransport | None = None) -> "BicycleDetourService":
        upstream = os.environ.get("MAP_PLATFORM_BICYCLE_ROUTING_UPSTREAM_URL") or None
        enabled = os.environ.get("MAP_PLATFORM_BICYCLE_DETOUR_ENABLED", "1").strip().lower()
        if enabled in {"0", "false", "no"}:
            upstream = None
        elif enabled not in {"1", "true", "yes", ""}:
            raise ValueError("MAP_PLATFORM_BICYCLE_DETOUR_ENABLED must be true or false")
        return cls(
            upstream,
            transport=transport,
            timeout_seconds=float(_environment_integer("MAP_PLATFORM_BICYCLE_ROUTING_TIMEOUT_SECONDS", 8, 2, 30)),
            maximum_concurrent=_environment_integer("MAP_PLATFORM_BICYCLE_DETOUR_MAX_CONCURRENT", 4, 1, 32),
            maximum_separation_meters=float(_environment_integer(
                "MAP_PLATFORM_BICYCLE_DETOUR_MAX_SEPARATION_METERS",
                DEFAULT_MAXIMUM_SEPARATION_METERS, 1_000, 50_000,
            )),
        )

    @property
    def enabled(self) -> bool:
        return self._route_url is not None

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
        if self._route_url is None:
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
        body = {
            "locations": [
                origin,
                {"lat": request.rejoin.latitude, "lon": request.rejoin.longitude, "type": "break"},
            ],
            "costing": "bicycle",
            "costing_options": {"bicycle": dict(BICYCLE_COSTING_OPTIONS)},
            "units": "kilometers",
            "language": request.locale,
            "directions_type": "instructions",
        }
        return json.dumps(body, separators=(",", ":")).encode()

    def _route(self, request: BicycleDetourRequest) -> dict[str, Any]:
        assert self._route_url is not None
        try:
            response = self._transport.request(
                method="POST",
                url=self._route_url,
                headers={"Content-Type": "application/json", "Accept": "application/json"},
                body=self._upstream_body(request),
                timeout_seconds=self._timeout_seconds,
                maximum_body_bytes=MAXIMUM_UPSTREAM_BYTES,
            )
        except ElevationProviderError as exc:
            _LOGGER.info("bicycle detour upstream failed code=%s", exc.code)
            raise BicycleDetourUnavailableError("routing-unavailable") from None
        if len(response.body) > MAXIMUM_UPSTREAM_BYTES:
            raise BicycleDetourUnavailableError("routing-response-too-large")
        try:
            decoded = json.loads(response.body)
        except (ValueError, UnicodeDecodeError):
            decoded = None
        if response.status_code == 400 and isinstance(decoded, dict):
            code = decoded.get("error_code")
            if code in NO_ROUTE_ERROR_CODES:
                _LOGGER.info("bicycle detour outcome=no_bicycle_route upstream_code=%s", code)
                return _unavailable("no_bicycle_route")
            if code in TOO_LONG_ERROR_CODES:
                return _unavailable("request_too_long")
            _LOGGER.info("bicycle detour upstream rejected code=%s", code)
            raise BicycleDetourUnavailableError("routing-rejected")
        if response.status_code != 200 or not isinstance(decoded, dict):
            _LOGGER.info("bicycle detour upstream status=%s", response.status_code)
            raise BicycleDetourUnavailableError("routing-unavailable")
        try:
            route = _route_from_trip(decoded.get("trip"))
        except ValueError as exc:
            _LOGGER.info("bicycle detour upstream answer rejected reason=%s", exc)
            if str(exc) == "non-bicycle-maneuver":
                return _unavailable("no_bicycle_route")
            raise BicycleDetourUnavailableError("routing-invalid-response") from None
        _LOGGER.info("bicycle detour outcome=ready maneuvers=%d", len(route["maneuvers"]))
        return {"schema": RESPONSE_SCHEMA, "status": "ready", "route": route, "reason": None}


def _number(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"invalid-{name}")
    return float(value)


def _route_from_trip(trip: Any) -> dict[str, Any]:
    if not isinstance(trip, dict) or trip.get("status") not in (0, None):
        raise ValueError("invalid-trip")
    legs = trip.get("legs")
    if not isinstance(legs, list) or len(legs) != 1 or not isinstance(legs[0], dict):
        raise ValueError("invalid-legs")
    leg = legs[0]
    shape = leg.get("shape")
    if not isinstance(shape, str) or not shape:
        raise ValueError("invalid-shape")
    points = decode_polyline6(shape)
    if len(points) < 2:
        raise ValueError("invalid-shape")
    raw_maneuvers = leg.get("maneuvers")
    if not isinstance(raw_maneuvers, list) or not raw_maneuvers or len(raw_maneuvers) > MAXIMUM_MANEUVERS:
        raise ValueError("invalid-maneuvers")
    maneuvers: list[dict[str, Any]] = []
    previous_end = 0
    for raw in raw_maneuvers:
        if not isinstance(raw, dict):
            raise ValueError("invalid-maneuver")
        # Never present driving, walking or transit directions as a bike detour.
        if raw.get("travel_mode") != "bicycle":
            raise ValueError("non-bicycle-maneuver")
        maneuver_type = raw.get("type")
        begin = raw.get("begin_shape_index")
        end = raw.get("end_shape_index")
        instruction = raw.get("instruction")
        if (
            type(maneuver_type) is not int or type(begin) is not int or type(end) is not int
            or not 0 <= begin <= end < len(points) or begin != previous_end
            or not isinstance(instruction, str) or not instruction.strip() or len(instruction) > 512
        ):
            raise ValueError("invalid-maneuver")
        previous_end = end
        item: dict[str, Any] = {
            "type": maneuver_type,
            "instruction": instruction.strip(),
            "beginShapeIndex": begin,
            "endShapeIndex": end,
            "lengthMeters": round(_number(raw.get("length", 0), "length") * 1000, 1),
            "timeSeconds": round(_number(raw.get("time", 0), "time"), 1),
        }
        for source, target in (("bearing_before", "bearingBefore"), ("bearing_after", "bearingAfter")):
            value = raw.get(source)
            if type(value) is int and 0 <= value <= 360:
                item[target] = value
        maneuvers.append(item)
    if previous_end != len(points) - 1:
        raise ValueError("invalid-maneuver-coverage")
    summary = trip.get("summary") if isinstance(trip.get("summary"), dict) else {}
    return {
        "provider": {"id": PROVIDER_ID, "attribution": ATTRIBUTION},
        "travelMode": "bicycle",
        "distanceMeters": round(_number(summary.get("length", 0), "length") * 1000, 1),
        "durationSeconds": round(_number(summary.get("time", 0), "time"), 1),
        # [latitudeE6, longitudeE6], in travel order.
        "pointsE6": [[latitude, longitude] for latitude, longitude in points],
        "maneuvers": maneuvers,
    }


def _unavailable(reason: str) -> dict[str, Any]:
    return {"schema": RESPONSE_SCHEMA, "status": "unavailable", "route": None, "reason": reason}
