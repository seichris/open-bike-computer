"""Shared plumbing for Bicino's internal Valhalla bicycle routing.

Both the saved-route detour endpoint and the general bicycle route endpoint
send two coordinates to the same internal Valhalla service with the
``bicycle`` costing only, and convert its answer into one route shape. This
module holds the pieces they share: request-field parsing, the upstream
transport call, Valhalla error-code mapping, the precision-6 polyline decoder
and the trip-to-route conversion that refuses non-bicycle maneuvers (a router
may allow short pedestrian push segments; detours allow none).

An answer larger than the caller's size limits is a deterministic outcome
(``request_too_long``), never a retryable service error.

Neither coordinates nor routes are stored or logged here. Log lines carry
outcome and upstream codes only, and the upstream URL never leaves the server.

Valhalla 3.9.2 lowercases ``bicycle_type`` before matching ``road``,
``cross``, ``hybrid`` or ``mountain`` and silently treats any other value as
``hybrid`` (``ParseBicycleCostOptions`` in ``src/sif/bicyclecost.cc``). Every
maneuver reports the type actually applied as ``travel_type``.
"""

from __future__ import annotations

import json
import logging
import math
import os
import re
import time
from dataclasses import dataclass
from typing import Any, Callable, Mapping
from urllib.parse import urlsplit

from .route_elevation_providers import ElevationProviderError, ElevationTransport

PROVIDER_ID = "bicino.valhalla"
ATTRIBUTION = "© OpenStreetMap contributors"
MINIMUM_SEPARATION_METERS = 10.0
MAXIMUM_UPSTREAM_BYTES = 2 * 1024 * 1024
MAXIMUM_SHAPE_POINTS = 20_000
MAXIMUM_MANEUVERS = 1_000
NO_ROUTE_ERROR_CODES = frozenset({170, 171, 442, 443})
TOO_LONG_ERROR_CODES = frozenset({154})
_UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
_LOCALE = re.compile(r"[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8}){0,3}")

RequestErrorFactory = Callable[[str], Exception]


@dataclass(frozen=True)
class RouteSizeLimits:
    """Largest Valhalla answer a caller accepts."""

    upstream_bytes: int = MAXIMUM_UPSTREAM_BYTES
    shape_points: int = MAXIMUM_SHAPE_POINTS
    maneuvers: int = MAXIMUM_MANEUVERS


DEFAULT_SIZE_LIMITS = RouteSizeLimits()


class RouteTooLargeError(ValueError):
    """The route exceeds the caller's size limits; asking again cannot help."""


@dataclass(frozen=True)
class MapPoint:
    latitude_e6: int
    longitude_e6: int

    @property
    def latitude(self) -> float:
        return self.latitude_e6 / 1_000_000

    @property
    def longitude(self) -> float:
        return self.longitude_e6 / 1_000_000


def parse_point(
    value: Any,
    allowed: frozenset[str],
    name: str,
    error: RequestErrorFactory,
) -> tuple[MapPoint, Mapping[str, Any]]:
    if not isinstance(value, dict) or set(value) - allowed:
        raise error(f"{name} has invalid fields")
    latitude = value.get("latitudeE6")
    longitude = value.get("longitudeE6")
    if (
        type(latitude) is not int or type(longitude) is not int
        or not -90_000_000 <= latitude <= 90_000_000
        or not -180_000_000 <= longitude <= 180_000_000
    ):
        raise error(f"{name} must hold integer microdegrees")
    return MapPoint(latitude, longitude), value


def parse_request_id(payload: Mapping[str, Any], error: RequestErrorFactory) -> str:
    request_id = payload.get("requestId")
    if not isinstance(request_id, str) or _UUID.fullmatch(request_id) is None:
        raise error("requestId must be a lowercase UUID")
    return request_id


def parse_locale(payload: Mapping[str, Any], error: RequestErrorFactory) -> str:
    locale = payload.get("locale", "en-US")
    if not isinstance(locale, str) or len(locale) > 35 or _LOCALE.fullmatch(locale) is None:
        raise error("locale must be a BCP 47 language tag")
    return locale.replace("_", "-")


def haversine_meters(a: MapPoint, b: MapPoint) -> float:
    radius = 6_371_008.8
    lat1, lat2 = math.radians(a.latitude), math.radians(b.latitude)
    d_lat = lat2 - lat1
    d_lon = math.radians(b.longitude - a.longitude)
    h = math.sin(d_lat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(d_lon / 2) ** 2
    return 2 * radius * math.asin(min(1.0, math.sqrt(h)))


def decode_polyline6(encoded: str, maximum_points: int = MAXIMUM_SHAPE_POINTS) -> list[tuple[int, int]]:
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
        if len(points) > maximum_points:
            raise RouteTooLargeError("too-many-points")
    return points


def upstream_route_url(raw: str) -> str:
    parts = urlsplit(raw.strip())
    if (
        parts.scheme not in {"http", "https"} or not parts.hostname or parts.username
        or parts.password or parts.query or parts.fragment or parts.path not in {"", "/"}
    ):
        raise ValueError(
            "MAP_PLATFORM_BICYCLE_ROUTING_UPSTREAM_URL must be an internal http(s) origin without a path"
        )
    return f"{parts.scheme}://{parts.netloc}/route"


def environment_integer(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    value = int(raw)
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


def environment_enabled(name: str) -> bool:
    value = os.environ.get(name, "1").strip().lower()
    if value in {"0", "false", "no"}:
        return False
    if value in {"1", "true", "yes", ""}:
        return True
    raise ValueError(f"{name} must be true or false")


def bicycle_route_body(
    origin: Mapping[str, Any],
    destination: MapPoint,
    costing_options: Mapping[str, Any],
    locale: str,
    alternates: int = 0,
) -> bytes:
    """The Valhalla ``/route`` body for one two-point bicycle request.

    ``origin`` is a Valhalla location (``lat``/``lon`` plus optional heading).
    ``alternates`` asks for up to that many alternative routes as well.
    """

    body = {
        "locations": [
            dict(origin),
            {"lat": destination.latitude, "lon": destination.longitude, "type": "break"},
        ],
        "costing": "bicycle",
        "costing_options": {"bicycle": dict(costing_options)},
        "units": "kilometers",
        "language": locale,
        "directions_type": "instructions",
    }
    if alternates > 0:
        body["alternates"] = alternates
    return json.dumps(body, separators=(",", ":")).encode()


def break_location(point: MapPoint) -> dict[str, Any]:
    return {"lat": point.latitude, "lon": point.longitude, "type": "break"}


class ValhallaUnavailableError(RuntimeError):
    """The internal routing service is unreachable or misbehaving."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


@dataclass(frozen=True)
class ValhallaOutcome:
    """Either ``route`` (ready) or ``reason`` (an unavailable outcome).

    ``alternatives`` holds the usable alternative routes Valhalla also
    returned. ``shapes`` holds the encoded shapes of ``route`` and then of
    each alternative, in the same order, for a surface lookup.
    ``response_too_large`` marks a ``request_too_long`` caused only by the
    answer's size, which asking for fewer alternatives may avoid.
    """

    route: dict[str, Any] | None
    reason: str | None
    alternatives: tuple[dict[str, Any], ...] = ()
    shapes: tuple[str, ...] = ()
    response_too_large: bool = False


# Valhalla edge surfaces (``baldr::Surface``) by rider-facing group.
SURFACE_GROUPS = {
    "paved_smooth": "pavedMeters",
    "paved": "pavedMeters",
    "paved_rough": "pavedMeters",
    "compacted": "gravelMeters",
    "gravel": "gravelMeters",
    "dirt": "unpavedMeters",
    "path": "unpavedMeters",
    "impassable": "unpavedMeters",
}
# trace_attributes with shape_match edge_walk answers 400 / 443 ("edge_walk
# algorithm failed to find exact route match") on some of Valhalla's own
# route shapes. On the 2026-11-24 planet graph that was 13 of 206 routes
# (24 legs x 4 profiles, with alternatives), and walk_or_snap matched all 13.
EDGE_WALK_NO_MATCH_ERROR_CODE = 443
# A surface lookup with less time than this left is not started.
MINIMUM_SURFACE_TIMEOUT_SECONDS = 1.0
# A walk_or_snap match counts only if its edges add up to the route length
# within max(30 m, 0.1 %). Measured on the same 206 routes (dev, 2026-11-25):
# - exact edge_walk edges fall short of the route length by at most 13 m;
# - map_snap answers fall short by at most 17 m (0.04 % of a 39.5 km route,
#   0.5 % of a 3 km one), including all 13 walk_or_snap fallbacks (5-15 m);
# - where map_snap's edges differ from edge_walk's, it cuts a junction
#   corner over 4-54 m of other ways or drops a final 13 m edge.
# The 30 m floor is twice the worst short-route shortfall, and 0.1 % is 2.5
# times the worst long-route one, leaving room for edge rounding on legs of
# up to 150 km. A match that skips part of the shape, ends early, or leaves
# the route along other ways and comes back differs by more and is refused.
# A parallel way of the same length cannot be told apart by length alone;
# such a stretch has been at most tens of metres in the samples.
MATCHED_LENGTH_TOLERANCE_METERS = 30.0
MATCHED_LENGTH_TOLERANCE_FRACTION = 0.001


class ValhallaBicycleRouter:
    """Posts one bicycle request to the internal Valhalla ``/route`` URL."""

    def __init__(
        self,
        route_url: str,
        *,
        transport: ElevationTransport,
        timeout_seconds: float,
        logger: logging.Logger,
        log_label: str,
        size_limits: RouteSizeLimits = DEFAULT_SIZE_LIMITS,
        maximum_push_meters: float = 0.0,
    ):
        self._route_url = route_url
        self._trace_url = route_url[: -len("/route")] + "/trace_attributes"
        self._limits = size_limits
        self._maximum_push_meters = maximum_push_meters
        self._transport = transport
        self._timeout_seconds = timeout_seconds
        self._logger = logger
        self._label = log_label

    @property
    def timeout_seconds(self) -> float:
        return self._timeout_seconds

    def route(self, body: bytes) -> ValhallaOutcome:
        try:
            response = self._transport.request(
                method="POST",
                url=self._route_url,
                headers={"Content-Type": "application/json", "Accept": "application/json"},
                body=body,
                timeout_seconds=self._timeout_seconds,
                maximum_body_bytes=self._limits.upstream_bytes,
            )
        except ElevationProviderError as exc:
            self._logger.info("%s upstream failed code=%s", self._label, exc.code)
            raise ValhallaUnavailableError("routing-unavailable") from None
        if response.status_code == 200 and len(response.body) > self._limits.upstream_bytes:
            self._logger.info("%s outcome=request_too_long reason=response-too-large", self._label)
            return ValhallaOutcome(None, "request_too_long", response_too_large=True)
        try:
            decoded = json.loads(response.body)
        except (ValueError, UnicodeDecodeError):
            decoded = None
        if response.status_code == 400 and isinstance(decoded, dict):
            code = decoded.get("error_code")
            if code in NO_ROUTE_ERROR_CODES:
                self._logger.info("%s outcome=no_bicycle_route upstream_code=%s", self._label, code)
                return ValhallaOutcome(None, "no_bicycle_route")
            if code in TOO_LONG_ERROR_CODES:
                self._logger.info("%s outcome=request_too_long upstream_code=%s", self._label, code)
                return ValhallaOutcome(None, "request_too_long")
            self._logger.info("%s upstream rejected code=%s", self._label, code)
            raise ValhallaUnavailableError("routing-rejected")
        if response.status_code != 200 or not isinstance(decoded, dict):
            self._logger.info("%s upstream status=%s", self._label, response.status_code)
            raise ValhallaUnavailableError("routing-unavailable")
        try:
            route = route_from_trip(decoded.get("trip"), self._limits, self._maximum_push_meters)
        except RouteTooLargeError as exc:
            self._logger.info("%s outcome=request_too_long reason=%s", self._label, exc)
            return ValhallaOutcome(None, "request_too_long")
        except ValueError as exc:
            self._logger.info("%s upstream answer rejected reason=%s", self._label, exc)
            if str(exc) == "non-bicycle-maneuver":
                return ValhallaOutcome(None, "no_bicycle_route")
            raise ValhallaUnavailableError("routing-invalid-response") from None
        alternatives: list[dict[str, Any]] = []
        shapes = [_trip_shape(decoded.get("trip"))]
        raw_alternates = decoded.get("alternates")
        for raw in raw_alternates if isinstance(raw_alternates, list) else []:
            trip = raw.get("trip") if isinstance(raw, dict) else None
            try:
                alternatives.append(route_from_trip(trip, self._limits, self._maximum_push_meters))
            except ValueError as exc:
                # An unusable alternative never costs the rider the main route.
                self._logger.info("%s alternative skipped reason=%s", self._label, exc)
                continue
            shapes.append(_trip_shape(trip))
        return ValhallaOutcome(route, None, tuple(alternatives), tuple(shapes))

    def surface_breakdown(
        self,
        shape: str,
        route_length_meters: float,
        timeout_seconds: float | None = None,
    ) -> dict[str, float] | None:
        """Metres per surface group along one route's exact edges, or None.

        The lookup walks the route's own shape along the graph (``edge_walk``).
        When Valhalla cannot walk it (HTTP 400, error 443), the lookup is
        asked once more with ``walk_or_snap``, within what is left of
        ``timeout_seconds``. That map-matched answer counts only when its
        edges add up to ``route_length_meters`` within
        ``matched_length_tolerance_meters``, so a match that strays onto other
        ways or skips part of the shape never becomes a breakdown.

        An answer without usable edges, a fallback that fails or strays, and a
        443 with too little time left for the fallback return None. A
        transport failure or any other error status raises
        ``ValhallaUnavailableError``, so the caller can stop asking for the
        other routes' surfaces. Either way the route is still served, without
        a breakdown.
        """

        timeout = self._timeout_seconds if timeout_seconds is None else timeout_seconds
        started = time.monotonic()
        status, decoded = self._trace_attributes(shape, "edge_walk", timeout)
        if status == 400 and _error_code(decoded) == EDGE_WALK_NO_MATCH_ERROR_CODE:
            remaining = timeout - (time.monotonic() - started)
            if remaining < MINIMUM_SURFACE_TIMEOUT_SECONDS:
                self._logger.info("%s surfaces unavailable reason=edge-walk-no-match-budget", self._label)
                return None
            self._logger.info("%s surfaces edge_walk no match; retrying walk_or_snap", self._label)
            status, decoded = self._trace_attributes(shape, "walk_or_snap", remaining)
            if status == 400:
                # The shape cannot be matched; the other routes still can be.
                self._logger.info(
                    "%s surfaces unavailable reason=walk-or-snap-rejected upstream_code=%s",
                    self._label, _error_code(decoded),
                )
                return None
            snapped = True
        else:
            snapped = False
        if status != 200:
            self._logger.info("%s surfaces unavailable status=%s", self._label, status)
            raise ValhallaUnavailableError("surfaces-unavailable")
        totals = _surface_totals(decoded)
        if totals is None:
            self._logger.info("%s surfaces unavailable reason=no-edges", self._label)
            return None
        if snapped:
            matched = sum(totals.values())
            if abs(matched - route_length_meters) > matched_length_tolerance_meters(route_length_meters):
                self._logger.info("%s surfaces unavailable reason=walk-or-snap-length-mismatch", self._label)
                return None
            self._logger.info("%s surfaces matched with walk_or_snap", self._label)
        return totals

    def _trace_attributes(self, shape: str, shape_match: str, timeout_seconds: float) -> tuple[int, Any]:
        """Status and decoded JSON (or None) of one ``trace_attributes`` call."""

        body = json.dumps({
            "encoded_polyline": shape,
            "shape_match": shape_match,
            "costing": "bicycle",
            "filters": {"attributes": ["edge.surface", "edge.length"], "action": "include"},
        }, separators=(",", ":")).encode()
        try:
            response = self._transport.request(
                method="POST",
                url=self._trace_url,
                headers={"Content-Type": "application/json", "Accept": "application/json"},
                body=body,
                timeout_seconds=timeout_seconds,
                maximum_body_bytes=self._limits.upstream_bytes,
            )
        except ElevationProviderError as exc:
            self._logger.info("%s surfaces failed code=%s", self._label, exc.code)
            raise ValhallaUnavailableError("surfaces-unavailable") from None
        try:
            decoded = json.loads(response.body)
        except (ValueError, UnicodeDecodeError):
            decoded = None
        return response.status_code, decoded


def matched_length_tolerance_meters(route_length_meters: float) -> float:
    """How far a ``walk_or_snap`` match's edge length may stray from the route's.

    The comment above ``MATCHED_LENGTH_TOLERANCE_METERS`` gives the measurements.
    """

    return max(MATCHED_LENGTH_TOLERANCE_METERS, MATCHED_LENGTH_TOLERANCE_FRACTION * route_length_meters)


def _error_code(decoded: Any) -> Any:
    return decoded.get("error_code") if isinstance(decoded, dict) else None


def _surface_totals(decoded: Any) -> dict[str, float] | None:
    """Metres per surface group from a ``trace_attributes`` answer, or None."""

    edges = decoded.get("edges") if isinstance(decoded, dict) else None
    if not isinstance(edges, list) or not edges:
        return None
    totals = {"pavedMeters": 0.0, "gravelMeters": 0.0, "unpavedMeters": 0.0, "unknownMeters": 0.0}
    for edge in edges:
        if not isinstance(edge, dict):
            return None
        try:
            length = _number(edge.get("length", 0), "length")
        except ValueError:
            return None
        group = SURFACE_GROUPS.get(edge.get("surface"), "unknownMeters")
        totals[group] += max(length, 0) * 1000
    return {key: round(value, 1) for key, value in totals.items()}


def _number(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"invalid-{name}")
    return float(value)


def _trip_shape(trip: Any) -> str:
    """The encoded shape of a trip ``route_from_trip`` already accepted."""

    return trip["legs"][0]["shape"]


def route_from_trip(
    trip: Any,
    limits: RouteSizeLimits = DEFAULT_SIZE_LIMITS,
    maximum_push_meters: float = 0.0,
) -> dict[str, Any]:
    """Convert a one-leg Valhalla trip into the app's route shape.

    Every maneuver must be ``bicycle``, except that a pedestrian maneuver of at
    most ``maximum_push_meters`` is accepted as a short push-the-bike stretch.
    A route still needs at least one bicycle maneuver.
    """
    if not isinstance(trip, dict) or trip.get("status") not in (0, None):
        raise ValueError("invalid-trip")
    legs = trip.get("legs")
    if not isinstance(legs, list) or len(legs) != 1 or not isinstance(legs[0], dict):
        raise ValueError("invalid-legs")
    leg = legs[0]
    shape = leg.get("shape")
    if not isinstance(shape, str) or not shape:
        raise ValueError("invalid-shape")
    points = decode_polyline6(shape, limits.shape_points)
    if len(points) < 2:
        raise ValueError("invalid-shape")
    raw_maneuvers = leg.get("maneuvers")
    if not isinstance(raw_maneuvers, list) or not raw_maneuvers:
        raise ValueError("invalid-maneuvers")
    if len(raw_maneuvers) > limits.maneuvers:
        raise RouteTooLargeError("too-many-maneuvers")
    maneuvers: list[dict[str, Any]] = []
    previous_end = 0
    cycles = False
    push_meters = 0.0
    for raw in raw_maneuvers:
        if not isinstance(raw, dict):
            raise ValueError("invalid-maneuver")
        # Never present driving, transit or long walking directions as a bike
        # route. A short pedestrian stretch is pushing the bike; Valhalla
        # splits one stretch into a maneuver per turn, so back-to-back
        # pedestrian maneuvers count as one stretch.
        mode = raw.get("travel_mode")
        if mode == "bicycle":
            cycles = True
            push_meters = 0.0
        elif mode == "pedestrian" and maximum_push_meters > 0:
            push_meters += _number(raw.get("length", 0), "length") * 1000
            if push_meters > maximum_push_meters:
                raise ValueError("non-bicycle-maneuver")
        else:
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
    if not cycles:
        raise ValueError("non-bicycle-maneuver")
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
