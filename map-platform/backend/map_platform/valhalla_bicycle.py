"""Shared plumbing for Bicino's internal Valhalla bicycle routing.

Both the saved-route detour endpoint and the general bicycle route endpoint
send two coordinates to the same internal Valhalla service with the
``bicycle`` costing only, and convert its answer into one route shape. This
module holds the pieces they share: request-field parsing, the upstream
transport call, Valhalla error-code mapping, the precision-6 polyline decoder
and the trip-to-route conversion that refuses any non-bicycle maneuver.

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
    """

    route: dict[str, Any] | None
    reason: str | None
    alternatives: tuple[dict[str, Any], ...] = ()
    shapes: tuple[str, ...] = ()


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
    ):
        self._route_url = route_url
        self._trace_url = route_url[: -len("/route")] + "/trace_attributes"
        self._limits = size_limits
        self._transport = transport
        self._timeout_seconds = timeout_seconds
        self._logger = logger
        self._label = log_label

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
            return ValhallaOutcome(None, "request_too_long")
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
            route = route_from_trip(decoded.get("trip"), self._limits)
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
                alternatives.append(route_from_trip(trip, self._limits))
            except ValueError as exc:
                # An unusable alternative never costs the rider the main route.
                self._logger.info("%s alternative skipped reason=%s", self._label, exc)
                continue
            shapes.append(_trip_shape(trip))
        return ValhallaOutcome(route, None, tuple(alternatives), tuple(shapes))

    def surface_breakdown(self, shape: str) -> dict[str, float] | None:
        """Metres per surface group along one route's exact edges, or None.

        A lookup that fails or answers unexpectedly returns None, so the
        route is still served without a breakdown.
        """

        body = json.dumps({
            "encoded_polyline": shape,
            "shape_match": "edge_walk",
            "costing": "bicycle",
            "filters": {"attributes": ["edge.surface", "edge.length"], "action": "include"},
        }, separators=(",", ":")).encode()
        try:
            response = self._transport.request(
                method="POST",
                url=self._trace_url,
                headers={"Content-Type": "application/json", "Accept": "application/json"},
                body=body,
                timeout_seconds=self._timeout_seconds,
                maximum_body_bytes=self._limits.upstream_bytes,
            )
        except ElevationProviderError as exc:
            self._logger.info("%s surfaces failed code=%s", self._label, exc.code)
            return None
        try:
            decoded = json.loads(response.body)
        except (ValueError, UnicodeDecodeError):
            decoded = None
        edges = decoded.get("edges") if isinstance(decoded, dict) else None
        if response.status_code != 200 or not isinstance(edges, list) or not edges:
            self._logger.info("%s surfaces unavailable status=%s", self._label, response.status_code)
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


def route_from_trip(trip: Any, limits: RouteSizeLimits = DEFAULT_SIZE_LIMITS) -> dict[str, Any]:
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
    for raw in raw_maneuvers:
        if not isinstance(raw, dict):
            raise ValueError("invalid-maneuver")
        # Never present driving, walking or transit directions as a bike route.
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
