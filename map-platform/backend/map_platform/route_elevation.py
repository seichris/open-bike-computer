"""Canonical route elevation profiles (``bicino-route-elevation-v1``).

One versioned contract serves the iPhone preview and the Bicino device. The
backend produces profiles from hosted or internal terrain providers; the iPhone
implements the same steps for trusted GPX ``<ele>`` values. Shared fixtures in
``protocol/fixtures/route-elevation-v1/`` keep the Python and Swift
implementations in agreement. Precision of samples or statistics never implies
source accuracy: provider datum, resolution and road-surface semantics are
reported separately and remain ``None`` when unknown.

Geometry is WGS-84 in integer microdegrees, exactly as supplied. Mainland-China
MapKit coordinates must be converted to WGS-84 by the client before submission;
this module never applies display-coordinate transformations.
"""

from __future__ import annotations

import bisect
import hashlib
import math
import struct
from dataclasses import dataclass, field
from typing import Any, Iterable, Sequence

PROFILE_SCHEMA = "bicino-route-elevation-profile-v1"
PROCESSING_VERSION = "bicino-route-elevation-v1"
GEOMETRY_DIGEST_DOMAIN = b"bicino-route-geometry-v1\n"

EARTH_RADIUS_M = 6_371_008.8
NOMINAL_SPACING_M = 50.0
SPACING_STEP_M = 10.0
MAXIMUM_SAMPLES = 4001
MINIMUM_ROUTE_POINTS = 2
MAXIMUM_ROUTE_POINTS = 20_000
MINIMUM_ROUTE_LENGTH_M = 1.0
MAXIMUM_ROUTE_LENGTH_M = 1_000_000.0
MAXIMUM_SEGMENT_LENGTH_M = 100_000.0

MINIMUM_VALID_ELEVATION_M = -500.0
MAXIMUM_VALID_ELEVATION_M = 9_000.0
MAXIMUM_INTERPOLATED_GAP_M = 200.0
SMOOTHING_MAXIMUM_SPACING_M = 75.0
ASCENT_HYSTERESIS_M = 5.0
GRADE_HALF_WINDOW_M = 100.0
UNAVAILABLE_COVERAGE = 0.1

STRUCTURE_ANCHOR_CLEARANCE_M = 30.0
STRUCTURE_ANCHOR_SEARCH_M = 150.0
MAXIMUM_STRUCTURE_GRADE = 0.15
MAXIMUM_STRUCTURE_LENGTH_M = 15_000.0

_DISTANCE_EPSILON_M = 1e-6

# Per-sample flags. The numeric values are part of the v1 contract and the
# compact device encoding; append new bits rather than renumbering.
FLAG_RAW_MISSING = 1 << 0
FLAG_INTERPOLATED_GAP = 1 << 1
FLAG_STRUCTURE_ESTIMATED = 1 << 2
FLAG_STRUCTURE_UNRESOLVED = 1 << 3
FLAG_STRUCTURE_AMBIGUOUS = 1 << 4
FLAG_BRIDGE = 1 << 5
FLAG_TUNNEL = 1 << 6
FLAG_GRADE_ESTIMATED = 1 << 7
FLAG_ESTIMATED = FLAG_INTERPOLATED_GAP | FLAG_STRUCTURE_ESTIMATED
KNOWN_SAMPLE_FLAGS = (
    FLAG_RAW_MISSING
    | FLAG_INTERPOLATED_GAP
    | FLAG_STRUCTURE_ESTIMATED
    | FLAG_STRUCTURE_UNRESOLVED
    | FLAG_STRUCTURE_AMBIGUOUS
    | FLAG_BRIDGE
    | FLAG_TUNNEL
    | FLAG_GRADE_ESTIMATED
)

QUALITY_COMPLETE = "complete"
QUALITY_PARTIAL = "partial"
QUALITY_UNAVAILABLE = "unavailable"

STRUCTURE_ESTIMATED = "estimated"
STRUCTURE_UNRESOLVED = "unresolved"
STRUCTURE_AMBIGUOUS = "ambiguous"
STRUCTURE_KINDS = ("bridge", "tunnel")


class RouteElevationError(ValueError):
    """Raised when a route or provider result violates the v1 contract."""


def round_half_away(value: float, digits: int = 1) -> float:
    """Round like Swift's ``.toNearestOrAwayFromZero`` (Python rounds half-even)."""

    scale = 10.0**digits
    scaled = abs(value) * scale
    rounded = math.floor(scaled + 0.5) / scale
    return math.copysign(rounded, value) if rounded else 0.0


def _optional_round(value: float | None, digits: int = 1) -> float | None:
    return None if value is None else round_half_away(value, digits)


def normalize_longitude_delta(delta: float) -> float:
    if delta > 180.0:
        return delta - 360.0
    if delta < -180.0:
        return delta + 360.0
    return delta


def normalize_longitude(value: float) -> float:
    if value >= 180.0:
        return value - 360.0
    if value < -180.0:
        return value + 360.0
    return value


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_phi = phi2 - phi1
    delta_lambda = math.radians(normalize_longitude_delta(lon2 - lon1))
    sin_phi = math.sin(delta_phi / 2.0)
    sin_lambda = math.sin(delta_lambda / 2.0)
    a = sin_phi * sin_phi + math.cos(phi1) * math.cos(phi2) * sin_lambda * sin_lambda
    a = min(1.0, max(0.0, a))
    return EARTH_RADIUS_M * 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))


@dataclass(frozen=True)
class RouteGeometry:
    """Ordered WGS-84 route vertices in integer microdegrees."""

    lat_e6: tuple[int, ...]
    lon_e6: tuple[int, ...]
    cumulative_m: tuple[float, ...]
    digest: str

    @property
    def point_count(self) -> int:
        return len(self.lat_e6)

    @property
    def length_m(self) -> float:
        return self.cumulative_m[-1]

    def latitude(self, index: int) -> float:
        return self.lat_e6[index] / 1_000_000.0

    def longitude(self, index: int) -> float:
        return self.lon_e6[index] / 1_000_000.0

    def point_at_distance(self, distance_m: float) -> tuple[float, float]:
        """Return ``(lat, lon)`` by linear interpolation along the polyline."""

        if distance_m <= 0.0:
            return self.latitude(0), self.longitude(0)
        last = self.point_count - 1
        if distance_m >= self.length_m:
            return self.latitude(last), self.longitude(last)
        index = bisect.bisect_right(self.cumulative_m, distance_m) - 1
        index = max(0, min(index, last - 1))
        start = self.cumulative_m[index]
        segment = self.cumulative_m[index + 1] - start
        fraction = 0.0 if segment <= 0.0 else (distance_m - start) / segment
        lat0, lon0 = self.latitude(index), self.longitude(index)
        lat1, lon1 = self.latitude(index + 1), self.longitude(index + 1)
        lat = lat0 + fraction * (lat1 - lat0)
        lon = normalize_longitude(lon0 + fraction * normalize_longitude_delta(lon1 - lon0))
        return lat, lon

    def heading_at_distance(self, distance_m: float) -> float | None:
        """Initial bearing in degrees of the segment containing ``distance_m``."""

        last = self.point_count - 1
        index = bisect.bisect_right(self.cumulative_m, max(0.0, distance_m)) - 1
        index = max(0, min(index, last - 1))
        # Zero-length segments have no direction; search forward, then back.
        for candidate in list(range(index, last)) + list(range(index - 1, -1, -1)):
            if self.cumulative_m[candidate + 1] - self.cumulative_m[candidate] > 0.0:
                return initial_bearing_deg(
                    self.latitude(candidate),
                    self.longitude(candidate),
                    self.latitude(candidate + 1),
                    self.longitude(candidate + 1),
                )
        return None


def initial_bearing_deg(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_lambda = math.radians(normalize_longitude_delta(lon2 - lon1))
    y = math.sin(delta_lambda) * math.cos(phi2)
    x = math.cos(phi1) * math.sin(phi2) - math.sin(phi1) * math.cos(phi2) * math.cos(delta_lambda)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


def geometry_digest(lat_e6: Sequence[int], lon_e6: Sequence[int]) -> str:
    digest = hashlib.sha256()
    digest.update(GEOMETRY_DIGEST_DOMAIN)
    digest.update(struct.pack("<I", len(lat_e6)))
    for lat, lon in zip(lat_e6, lon_e6):
        digest.update(struct.pack("<ii", lat, lon))
    return digest.hexdigest()


def _strict_int(value: Any, *, description: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise RouteElevationError(f"{description} must be an integer")
    return value


def build_route_geometry(lat_e6: Sequence[int], lon_e6: Sequence[int]) -> RouteGeometry:
    if len(lat_e6) != len(lon_e6):
        raise RouteElevationError("latitude and longitude arrays differ in length")
    count = len(lat_e6)
    if count < MINIMUM_ROUTE_POINTS:
        raise RouteElevationError("route must contain at least two points")
    if count > MAXIMUM_ROUTE_POINTS:
        raise RouteElevationError(f"route exceeds {MAXIMUM_ROUTE_POINTS} points")
    for lat, lon in zip(lat_e6, lon_e6):
        lat = _strict_int(lat, description="latitude")
        lon = _strict_int(lon, description="longitude")
        if not -90_000_000 <= lat <= 90_000_000:
            raise RouteElevationError("latitude outside WGS-84 bounds")
        if not -180_000_000 <= lon <= 180_000_000:
            raise RouteElevationError("longitude outside WGS-84 bounds")
    cumulative = [0.0]
    for index in range(1, count):
        step = haversine_m(
            lat_e6[index - 1] / 1_000_000.0,
            lon_e6[index - 1] / 1_000_000.0,
            lat_e6[index] / 1_000_000.0,
            lon_e6[index] / 1_000_000.0,
        )
        if step > MAXIMUM_SEGMENT_LENGTH_M:
            raise RouteElevationError("route contains an implausibly long segment")
        cumulative.append(cumulative[-1] + step)
    length = cumulative[-1]
    if length < MINIMUM_ROUTE_LENGTH_M:
        raise RouteElevationError("route is too short for an elevation profile")
    if length > MAXIMUM_ROUTE_LENGTH_M:
        raise RouteElevationError("route is too long for an elevation profile")
    return RouteGeometry(
        lat_e6=tuple(int(value) for value in lat_e6),
        lon_e6=tuple(int(value) for value in lon_e6),
        cumulative_m=tuple(cumulative),
        digest=geometry_digest(lat_e6, lon_e6),
    )


def parse_route_geometry(payload: Any) -> RouteGeometry:
    """Parse ``{"coordinatesE6": [[lonE6, latE6], ...]}`` (GeoJSON axis order)."""

    if not isinstance(payload, dict):
        raise RouteElevationError("geometry must be an object")
    if payload.get("crs", "EPSG:4326") != "EPSG:4326":
        raise RouteElevationError("geometry must use EPSG:4326 (WGS-84)")
    coordinates = payload.get("coordinatesE6")
    if not isinstance(coordinates, list):
        raise RouteElevationError("geometry.coordinatesE6 must be an array")
    if len(coordinates) > MAXIMUM_ROUTE_POINTS:
        raise RouteElevationError(f"route exceeds {MAXIMUM_ROUTE_POINTS} points")
    lat_e6: list[int] = []
    lon_e6: list[int] = []
    for pair in coordinates:
        if not isinstance(pair, list) or len(pair) != 2:
            raise RouteElevationError("each coordinate must be [lonE6, latE6]")
        lon_e6.append(_strict_int(pair[0], description="longitude"))
        lat_e6.append(_strict_int(pair[1], description="latitude"))
    geometry = build_route_geometry(lat_e6, lon_e6)
    expected = payload.get("digest")
    if expected is not None and expected != geometry.digest:
        raise RouteElevationError("geometry digest does not match coordinates")
    return geometry


@dataclass(frozen=True)
class SamplingPlan:
    spacing_m: float
    distances_m: tuple[float, ...]

    @property
    def count(self) -> int:
        return len(self.distances_m)


def sampling_spacing_m(length_m: float) -> float:
    spacing = NOMINAL_SPACING_M
    required = length_m / (MAXIMUM_SAMPLES - 1)
    if required > spacing:
        spacing = math.ceil(required / SPACING_STEP_M - 1e-9) * SPACING_STEP_M
    return spacing


def plan_sampling(length_m: float) -> SamplingPlan:
    if not math.isfinite(length_m) or length_m < MINIMUM_ROUTE_LENGTH_M:
        raise RouteElevationError("route length is too short for sampling")
    spacing = sampling_spacing_m(length_m)
    intervals = max(1, math.ceil(length_m / spacing - 1e-9))
    distances = [index * spacing for index in range(intervals)]
    distances.append(length_m)
    if len(distances) > MAXIMUM_SAMPLES:
        raise RouteElevationError("sampling plan exceeds the sample bound")
    return SamplingPlan(spacing_m=spacing, distances_m=tuple(distances))


def sample_coordinates(geometry: RouteGeometry, plan: SamplingPlan) -> list[tuple[float, float]]:
    return [geometry.point_at_distance(distance) for distance in plan.distances_m]


def resample_vertex_elevations(
    geometry: RouteGeometry,
    plan: SamplingPlan,
    vertex_elevations: Sequence[float | None],
    *,
    maximum_bridge_m: float = 250.0,
) -> list[float | None]:
    """Linearly resample per-vertex elevations (for example GPX ``<ele>``).

    A sample between two valid vertices more than ``maximum_bridge_m`` apart
    remains missing rather than inventing a long straight line.
    """

    if len(vertex_elevations) != geometry.point_count:
        raise RouteElevationError("vertex elevation count does not match geometry")
    valid_indices = [
        index
        for index, value in enumerate(vertex_elevations)
        if value is not None and math.isfinite(value)
    ]
    valid_distances = [geometry.cumulative_m[index] for index in valid_indices]
    result: list[float | None] = []
    for distance in plan.distances_m:
        position = bisect.bisect_right(valid_distances, distance + _DISTANCE_EPSILON_M) - 1
        if position < 0:
            result.append(None)
            continue
        previous_index = valid_indices[position]
        previous_distance = valid_distances[position]
        previous_value = float(vertex_elevations[previous_index])  # type: ignore[arg-type]
        if abs(distance - previous_distance) <= _DISTANCE_EPSILON_M:
            result.append(previous_value)
            continue
        if position + 1 >= len(valid_indices):
            result.append(None)
            continue
        next_distance = valid_distances[position + 1]
        next_value = float(vertex_elevations[valid_indices[position + 1]])  # type: ignore[arg-type]
        span = next_distance - previous_distance
        if span > maximum_bridge_m or span <= 0.0:
            result.append(None)
            continue
        fraction = (distance - previous_distance) / span
        result.append(previous_value + fraction * (next_value - previous_value))
    return result


@dataclass(frozen=True)
class StructureSpan:
    """A bridge or tunnel span along the route distance axis."""

    kind: str
    start_m: float
    end_m: float
    resolution: str
    way_ids: tuple[int, ...] = ()
    reason: str | None = None
    anchor_start_m: float | None = None
    anchor_end_m: float | None = None

    def to_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "kind": self.kind,
            "startM": round_half_away(self.start_m, 1),
            "endM": round_half_away(self.end_m, 1),
            "resolution": self.resolution,
            "osmWayIds": list(self.way_ids),
        }
        if self.reason is not None:
            data["reason"] = self.reason
        if self.anchor_start_m is not None:
            data["anchorStartM"] = round_half_away(self.anchor_start_m, 1)
        if self.anchor_end_m is not None:
            data["anchorEndM"] = round_half_away(self.anchor_end_m, 1)
        return data


@dataclass(frozen=True)
class ElevationSource:
    """Provenance of the base elevation values. Unknown metadata stays ``None``."""

    kind: str
    identifier: str
    version: str | None = None
    vertical_datum: str | None = None
    native_resolution_m: float | None = None
    surface_model: str | None = None
    interpolation: str | None = None
    attribution: tuple[str, ...] = ()
    retrieved_at: str | None = None
    qualification: str = "unqualified"

    def to_dict(self) -> dict[str, Any]:
        return {
            "kind": self.kind,
            "id": self.identifier,
            "version": self.version,
            "verticalDatum": self.vertical_datum,
            "nativeResolutionM": self.native_resolution_m,
            "surfaceModel": self.surface_model,
            "interpolation": self.interpolation,
            "attribution": list(self.attribution),
            "retrievedAt": self.retrieved_at,
            "qualification": self.qualification,
        }


@dataclass(frozen=True)
class StructureCorrection:
    status: str
    source: str | None = None
    source_version: str | None = None
    attribution: tuple[str, ...] = ()
    reason: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "source": self.source,
            "sourceVersion": self.source_version,
            "attribution": list(self.attribution),
            "reason": self.reason,
        }


@dataclass(frozen=True)
class ProfileStatistics:
    total_ascent_m: float | None
    total_descent_m: float | None
    minimum_elevation_m: float | None
    maximum_elevation_m: float | None
    complete: bool
    includes_estimated: bool

    def to_dict(self) -> dict[str, Any]:
        return {
            "totalAscentM": _optional_round(self.total_ascent_m),
            "totalDescentM": _optional_round(self.total_descent_m),
            "minimumElevationM": _optional_round(self.minimum_elevation_m),
            "maximumElevationM": _optional_round(self.maximum_elevation_m),
            "complete": self.complete,
            "includesEstimated": self.includes_estimated,
        }


@dataclass(frozen=True)
class ProfileQuality:
    status: str
    coverage: float
    valid_distance_m: float
    estimated_distance_m: float
    unknown_distance_m: float
    longest_gap_m: float
    reasons: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "coverage": round_half_away(self.coverage, 4),
            "validDistanceM": round_half_away(self.valid_distance_m, 1),
            "estimatedDistanceM": round_half_away(self.estimated_distance_m, 1),
            "unknownDistanceM": round_half_away(self.unknown_distance_m, 1),
            "longestGapM": round_half_away(self.longest_gap_m, 1),
            "reasons": list(self.reasons),
        }


@dataclass(frozen=True)
class RouteElevationProfile:
    geometry_digest: str
    geometry_point_count: int
    length_m: float
    spacing_m: float
    distances_m: tuple[float, ...]
    elevation_m: tuple[float | None, ...]
    raw_elevation_m: tuple[float | None, ...]
    grade_percent: tuple[float | None, ...]
    cumulative_ascent_m: tuple[float | None, ...]
    flags: tuple[int, ...]
    source: ElevationSource
    statistics: ProfileStatistics
    quality: ProfileQuality
    structures: tuple[StructureSpan, ...] = ()
    structure_correction: StructureCorrection = field(
        default_factory=lambda: StructureCorrection(status="unavailable", reason="not-requested")
    )

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema": PROFILE_SCHEMA,
            "processingVersion": PROCESSING_VERSION,
            "geometry": {
                "digest": self.geometry_digest,
                "pointCount": self.geometry_point_count,
                "lengthM": round_half_away(self.length_m, 1),
                "crs": "EPSG:4326",
                "precision": "microdegrees",
            },
            "sampling": {
                "method": "uniform-distance",
                "spacingM": self.spacing_m,
                "sampleCount": len(self.distances_m),
                "smoothingHalfSamples": smoothing_half_samples(self.spacing_m),
                "ascentHysteresisM": ASCENT_HYSTERESIS_M,
                "gradeHalfWindowM": grade_half_window_m(self.spacing_m),
                "maximumInterpolatedGapM": MAXIMUM_INTERPOLATED_GAP_M,
            },
            "source": self.source.to_dict(),
            "samples": {
                "distanceM": [round_half_away(value, 1) for value in self.distances_m],
                "elevationM": [_optional_round(value) for value in self.elevation_m],
                "rawElevationM": [_optional_round(value) for value in self.raw_elevation_m],
                "gradePercent": [_optional_round(value) for value in self.grade_percent],
                "cumulativeAscentM": [_optional_round(value) for value in self.cumulative_ascent_m],
                "flags": list(self.flags),
            },
            "structures": [span.to_dict() for span in self.structures],
            "structureCorrection": self.structure_correction.to_dict(),
            "statistics": self.statistics.to_dict(),
            "quality": self.quality.to_dict(),
        }


def smoothing_half_samples(spacing_m: float) -> int:
    return 1 if spacing_m <= SMOOTHING_MAXIMUM_SPACING_M else 0


def grade_half_window_m(spacing_m: float) -> float:
    return max(GRADE_HALF_WINDOW_M, spacing_m)


def _valid_elevation(value: float | None) -> float | None:
    if value is None:
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(number):
        return None
    if number < MINIMUM_VALID_ELEVATION_M or number > MAXIMUM_VALID_ELEVATION_M:
        return None
    return number


def _first_valid_at_or_before(
    distances: Sequence[float], values: Sequence[float | None], limit_m: float, floor_m: float
) -> int | None:
    index = bisect.bisect_right(distances, limit_m + _DISTANCE_EPSILON_M) - 1
    while index >= 0 and distances[index] >= floor_m - _DISTANCE_EPSILON_M:
        if values[index] is not None:
            return index
        index -= 1
    return None


def _first_valid_at_or_after(
    distances: Sequence[float], values: Sequence[float | None], limit_m: float, ceiling_m: float
) -> int | None:
    index = bisect.bisect_left(distances, limit_m - _DISTANCE_EPSILON_M)
    while index < len(distances) and distances[index] <= ceiling_m + _DISTANCE_EPSILON_M:
        if values[index] is not None:
            return index
        index += 1
    return None


def apply_structure_spans(
    distances: Sequence[float],
    values: list[float | None],
    flags: list[int],
    spans: Iterable[StructureSpan],
) -> list[StructureSpan]:
    """Interpolate confident spans between anchors; mark others unknown/ambiguous.

    ``spans`` carry the association result. A confident ("estimated") span is
    downgraded to unresolved when anchors are missing, implausibly steep, or
    the span is too long. Ambiguous spans keep their raw values but are flagged
    so grade and completeness are withheld.
    """

    raw_values = list(values)
    resolved: list[StructureSpan] = []
    for span in sorted(spans, key=lambda item: (item.start_m, item.end_m)):
        kind_flag = FLAG_BRIDGE if span.kind == "bridge" else FLAG_TUNNEL
        inside = [
            index
            for index, distance in enumerate(distances)
            if span.start_m - _DISTANCE_EPSILON_M <= distance <= span.end_m + _DISTANCE_EPSILON_M
        ]
        if span.resolution == STRUCTURE_AMBIGUOUS:
            for index in inside:
                flags[index] |= FLAG_STRUCTURE_AMBIGUOUS | kind_flag
            resolved.append(span)
            continue
        reason: str | None = None
        anchor_start = _first_valid_at_or_before(
            distances,
            raw_values,
            span.start_m - STRUCTURE_ANCHOR_CLEARANCE_M,
            span.start_m - STRUCTURE_ANCHOR_SEARCH_M,
        )
        anchor_end = _first_valid_at_or_after(
            distances,
            raw_values,
            span.end_m + STRUCTURE_ANCHOR_CLEARANCE_M,
            span.end_m + STRUCTURE_ANCHOR_SEARCH_M,
        )
        if span.end_m - span.start_m > MAXIMUM_STRUCTURE_LENGTH_M:
            reason = "structure-too-long"
        elif anchor_start is None or anchor_end is None:
            reason = "missing-anchor"
        else:
            run = distances[anchor_end] - distances[anchor_start]
            rise = raw_values[anchor_end] - raw_values[anchor_start]  # type: ignore[operator]
            if run <= 0.0 or abs(rise) / run > MAXIMUM_STRUCTURE_GRADE:
                reason = "implausible-anchor-grade"
        if span.resolution == STRUCTURE_UNRESOLVED and reason is None:
            reason = span.reason or "unresolved-association"
        if reason is not None:
            for index in inside:
                values[index] = None
                flags[index] |= FLAG_STRUCTURE_UNRESOLVED | kind_flag
            resolved.append(
                StructureSpan(
                    kind=span.kind,
                    start_m=span.start_m,
                    end_m=span.end_m,
                    resolution=STRUCTURE_UNRESOLVED,
                    way_ids=span.way_ids,
                    reason=reason,
                )
            )
            continue
        start_distance = distances[anchor_start]  # type: ignore[index]
        end_distance = distances[anchor_end]  # type: ignore[index]
        start_value = raw_values[anchor_start]  # type: ignore[index]
        end_value = raw_values[anchor_end]  # type: ignore[index]
        for index in range(anchor_start + 1, anchor_end):  # type: ignore[operator]
            fraction = (distances[index] - start_distance) / (end_distance - start_distance)
            values[index] = start_value + fraction * (end_value - start_value)  # type: ignore[operator]
            flags[index] |= FLAG_STRUCTURE_ESTIMATED | kind_flag
            flags[index] &= ~FLAG_STRUCTURE_UNRESOLVED
        resolved.append(
            StructureSpan(
                kind=span.kind,
                start_m=span.start_m,
                end_m=span.end_m,
                resolution=STRUCTURE_ESTIMATED,
                way_ids=span.way_ids,
                anchor_start_m=start_distance,
                anchor_end_m=end_distance,
            )
        )
    return resolved


def fill_short_gaps(distances: Sequence[float], values: list[float | None], flags: list[int]) -> None:
    count = len(values)
    index = 0
    while index < count:
        if values[index] is not None:
            index += 1
            continue
        start = index
        while index < count and values[index] is None:
            index += 1
        end = index  # first valid after the gap, or count
        if start == 0 or end >= count:
            continue
        if any(flags[position] & FLAG_STRUCTURE_UNRESOLVED for position in range(start, end)):
            continue
        before = start - 1
        span = distances[end] - distances[before]
        if span > MAXIMUM_INTERPOLATED_GAP_M + _DISTANCE_EPSILON_M:
            continue
        start_value = values[before]
        end_value = values[end]
        for position in range(start, end):
            fraction = (distances[position] - distances[before]) / span
            values[position] = start_value + fraction * (end_value - start_value)  # type: ignore[operator]
            flags[position] |= FLAG_INTERPOLATED_GAP


def smooth(values: Sequence[float | None], spacing_m: float) -> list[float | None]:
    half = smoothing_half_samples(spacing_m)
    if half == 0:
        return list(values)
    result: list[float | None] = []
    for index, value in enumerate(values):
        if value is None:
            result.append(None)
            continue
        total = value
        count = 1
        for neighbor in (index - 1, index + 1):
            if 0 <= neighbor < len(values) and values[neighbor] is not None:
                total += values[neighbor]  # type: ignore[operator]
                count += 1
        result.append(total / count)
    return result


@dataclass(frozen=True)
class HysteresisResult:
    ascent_m: float
    descent_m: float
    cumulative_ascent_m: tuple[float | None, ...]


def hysteresis_totals(values: Sequence[float | None], threshold_m: float = ASCENT_HYSTERESIS_M) -> HysteresisResult:
    """Sum confirmed rises/falls between turning points that exceed ``threshold_m``.

    Each contiguous run of known values is processed independently: the change
    across an unknown gap is never counted. ``cumulative_ascent_m`` is the
    monotonic climbed amount at each sample (``None`` inside gaps), ending at
    the total ascent, so "ascent remaining" uses the same definition.
    """

    count = len(values)
    descent = 0.0
    climbs: list[tuple[int, int]] = []
    index = 0
    while index < count:
        if values[index] is None:
            index += 1
            continue
        run_start = index
        while index < count and values[index] is not None:
            index += 1
        run = [float(values[position]) for position in range(run_start, index)]  # type: ignore[arg-type]
        run_climbs, run_descent = _hysteresis_run(run, threshold_m)
        descent += run_descent
        climbs.extend((run_start + start, run_start + peak) for start, peak in run_climbs)
    cumulative: list[float | None] = []
    climb_position = 0
    completed = 0.0
    running_max: float | None = None
    for position in range(count):
        while climb_position < len(climbs) and position > climbs[climb_position][1]:
            start, peak = climbs[climb_position]
            completed += float(values[peak]) - float(values[start])  # type: ignore[arg-type]
            climb_position += 1
            running_max = None
        value = values[position]
        if value is None:
            cumulative.append(None)
            continue
        partial = 0.0
        if climb_position < len(climbs):
            start, peak = climbs[climb_position]
            if start <= position <= peak:
                base = float(values[start])  # type: ignore[arg-type]
                running_max = value if running_max is None else max(running_max, value)
                gain = float(values[peak]) - base  # type: ignore[arg-type]
                partial = min(max(running_max - base, 0.0), gain)
        cumulative.append(completed + partial)
    ascent = 0.0
    for start, peak in climbs:
        ascent += float(values[peak]) - float(values[start])  # type: ignore[arg-type]
    return HysteresisResult(ascent_m=ascent, descent_m=descent, cumulative_ascent_m=tuple(cumulative))


def _hysteresis_run(run: Sequence[float], threshold_m: float) -> tuple[list[tuple[int, int]], float]:
    climbs: list[tuple[int, int]] = []
    descent = 0.0
    if not run:
        return climbs, descent
    direction = 0
    low = high = run[0]
    low_index = high_index = 0
    anchor = run[0]
    anchor_index = 0
    extreme = run[0]
    extreme_index = 0
    for position in range(1, len(run)):
        value = run[position]
        if direction == 0:
            if value < low:
                low, low_index = value, position
            if value > high:
                high, high_index = value, position
            if high - low >= threshold_m:
                if high_index > low_index:
                    direction = 1
                    anchor, anchor_index = low, low_index
                    extreme, extreme_index = high, high_index
                else:
                    direction = -1
                    anchor, anchor_index = high, high_index
                    extreme, extreme_index = low, low_index
        elif direction == 1:
            if value > extreme:
                extreme, extreme_index = value, position
            elif extreme - value >= threshold_m:
                climbs.append((anchor_index, extreme_index))
                anchor, anchor_index = extreme, extreme_index
                direction = -1
                extreme, extreme_index = value, position
        else:
            if value < extreme:
                extreme, extreme_index = value, position
            elif value - extreme >= threshold_m:
                descent += anchor - extreme
                anchor, anchor_index = extreme, extreme_index
                direction = 1
                extreme, extreme_index = value, position
    if direction == 1:
        climbs.append((anchor_index, extreme_index))
    elif direction == -1:
        descent += anchor - extreme
    return climbs, descent


def compute_grades(
    distances: Sequence[float],
    values: Sequence[float | None],
    flags: list[int],
    spacing_m: float,
) -> list[float | None]:
    """Least-squares slope over a centred distance window, in percent.

    A grade whose window touches an unknown or ambiguous sample is withheld; a
    window containing estimated samples sets ``FLAG_GRADE_ESTIMATED``.
    """

    half_window = grade_half_window_m(spacing_m)
    count = len(values)
    grades: list[float | None] = []
    for index in range(count):
        if values[index] is None or flags[index] & FLAG_STRUCTURE_AMBIGUOUS:
            grades.append(None)
            continue
        centre = distances[index]
        window: list[int] = []
        valid = True
        position = index
        while position >= 0 and distances[position] >= centre - half_window - _DISTANCE_EPSILON_M:
            if values[position] is None or flags[position] & FLAG_STRUCTURE_AMBIGUOUS:
                valid = False
                break
            window.append(position)
            position -= 1
        position = index + 1
        while valid and position < count and distances[position] <= centre + half_window + _DISTANCE_EPSILON_M:
            if values[position] is None or flags[position] & FLAG_STRUCTURE_AMBIGUOUS:
                valid = False
                break
            window.append(position)
            position += 1
        if not valid or len(window) < 3:
            grades.append(None)
            continue
        window.sort()
        span = distances[window[-1]] - distances[window[0]]
        if span < half_window - _DISTANCE_EPSILON_M:
            grades.append(None)
            continue
        # Explicit left-to-right sums: Python 3.12+ ``sum`` compensates float
        # error, which would make results differ from Swift and older runtimes.
        total_x = 0.0
        total_y = 0.0
        for position in window:
            total_x += distances[position]
            total_y += values[position]  # type: ignore[operator]
        mean_x = total_x / len(window)
        mean_y = total_y / len(window)
        numerator = 0.0
        denominator = 0.0
        for position in window:
            dx = distances[position] - mean_x
            numerator += dx * (values[position] - mean_y)  # type: ignore[operator]
            denominator += dx * dx
        if denominator <= 0.0:
            grades.append(None)
            continue
        if any(flags[position] & FLAG_ESTIMATED for position in window):
            flags[index] |= FLAG_GRADE_ESTIMATED
        grades.append(numerator / denominator * 100.0)
    return grades


def _coverage_weights(distances: Sequence[float]) -> list[float]:
    count = len(distances)
    weights: list[float] = []
    for index in range(count):
        lower = distances[0] if index == 0 else (distances[index - 1] + distances[index]) / 2.0
        upper = distances[-1] if index == count - 1 else (distances[index] + distances[index + 1]) / 2.0
        weights.append(upper - lower)
    return weights


def assess_quality(
    distances: Sequence[float],
    values: Sequence[float | None],
    flags: Sequence[int],
    structures: Sequence[StructureSpan],
) -> ProfileQuality:
    weights = _coverage_weights(distances)
    length = distances[-1] - distances[0]
    valid = 0.0
    estimated = 0.0
    longest_gap = 0.0
    current_gap = 0.0
    for weight, value, flag in zip(weights, values, flags):
        if value is None:
            current_gap += weight
            longest_gap = max(longest_gap, current_gap)
            continue
        current_gap = 0.0
        valid += weight
        if flag & FLAG_ESTIMATED:
            estimated += weight
    unknown = max(0.0, length - valid)
    coverage = 0.0 if length <= 0.0 else min(1.0, valid / length)
    reasons: list[str] = []
    valid_count = sum(1 for value in values if value is not None)
    if unknown > 0.5:
        reasons.append("missing-elevation")
    if any(span.resolution == STRUCTURE_UNRESOLVED for span in structures):
        reasons.append("unresolved-structure")
    if any(span.resolution == STRUCTURE_AMBIGUOUS for span in structures):
        reasons.append("ambiguous-structure")
    if valid_count < 2 or coverage < UNAVAILABLE_COVERAGE:
        status = QUALITY_UNAVAILABLE
    elif reasons:
        status = QUALITY_PARTIAL
    else:
        status = QUALITY_COMPLETE
    if estimated > 0.0:
        reasons.append("estimated-elevation")
    return ProfileQuality(
        status=status,
        coverage=coverage,
        valid_distance_m=valid,
        estimated_distance_m=estimated,
        unknown_distance_m=unknown,
        longest_gap_m=longest_gap,
        reasons=tuple(reasons),
    )


def process_profile(
    geometry: RouteGeometry,
    plan: SamplingPlan,
    raw_elevations: Sequence[float | None],
    source: ElevationSource,
    *,
    structures: Sequence[StructureSpan] = (),
    structure_correction: StructureCorrection | None = None,
) -> RouteElevationProfile:
    """Run validation, structure correction, gap filling, smoothing and statistics."""

    if len(raw_elevations) != plan.count:
        raise RouteElevationError("raw elevation count does not match the sampling plan")
    distances = plan.distances_m
    raw = [_valid_elevation(value) for value in raw_elevations]
    flags = [FLAG_RAW_MISSING if value is None else 0 for value in raw]
    working = list(raw)
    resolved = apply_structure_spans(distances, working, flags, structures)
    fill_short_gaps(distances, working, flags)
    processed = smooth(working, plan.spacing_m)
    grades = compute_grades(distances, processed, flags, plan.spacing_m)
    totals = hysteresis_totals(processed)
    quality = assess_quality(distances, processed, flags, resolved)
    known = [value for value in processed if value is not None]
    available = quality.status != QUALITY_UNAVAILABLE
    statistics = ProfileStatistics(
        total_ascent_m=totals.ascent_m if available else None,
        total_descent_m=totals.descent_m if available else None,
        minimum_elevation_m=min(known) if available and known else None,
        maximum_elevation_m=max(known) if available and known else None,
        complete=quality.status == QUALITY_COMPLETE,
        includes_estimated=quality.estimated_distance_m > 0.0,
    )
    if structure_correction is None:
        structure_correction = StructureCorrection(status="unavailable", reason="no-structure-source")
    return RouteElevationProfile(
        geometry_digest=geometry.digest,
        geometry_point_count=geometry.point_count,
        length_m=geometry.length_m,
        spacing_m=plan.spacing_m,
        distances_m=distances,
        elevation_m=tuple(processed),
        raw_elevation_m=tuple(raw),
        grade_percent=tuple(grades),
        cumulative_ascent_m=totals.cumulative_ascent_m,
        flags=tuple(flags),
        source=source,
        statistics=statistics,
        quality=quality,
        structures=tuple(resolved),
        structure_correction=structure_correction,
    )
