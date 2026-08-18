"""Canonical target-3 scope planning and legacy-scope diagnostics."""

from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass
from typing import Any, Iterable, Sequence

from .models import Bounds, GeometryMode, MapJob
from .reuse import (
    EARTH_RADIUS_METERS,
    MAP_BLOCK_SIZE_METERS,
    WEB_MERCATOR_LIMIT_METERS,
    MapBlock,
    aligned_projected_extent,
    expanded_building_source_bounds,
)


BUILDING_SCOPE_POLICY_VERSION = 3
BUILDING_BLOCK_GRID_VERSION = 1
BUILDING_GEOMETRY_BUFFER_METERS = 256
BUILDING_RELATION_RETRY_BUFFER_METERS = 512
BUILDING_MAX_GEOMETRY_BUFFER_METERS = 2_048
BUILDING_MAX_SOURCE_TO_OUTPUT_AREA_BASIS_POINTS = 13_500
BUILDING_MAX_SOURCE_AREA_M2 = 800_000_000
BUILDING_MAX_RELATION_OBJECTS_PER_JOB = 200_000
BUILDING_SELECTION_SEMANTICS = "complete_blocks_no_selection_edge_clipping"
BUILDING_RELATION_CLOSURE_MODE = "source_snapshot_index"
BUILDING_SCOPE_SCHEMA_VERSION = 1


class BuildingScopeError(RuntimeError):
    """A target-3 scope cannot be planned without violating its policy."""

    def __init__(self, code: str, message: str):
        self.code = code
        super().__init__(message)


@dataclass(frozen=True)
class BuildingScopePolicy:
    policy_version: int = BUILDING_SCOPE_POLICY_VERSION
    block_grid_version: int = BUILDING_BLOCK_GRID_VERSION
    block_size_meters: int = MAP_BLOCK_SIZE_METERS
    geometry_buffer_meters: int = BUILDING_GEOMETRY_BUFFER_METERS
    relation_retry_buffer_meters: int = BUILDING_RELATION_RETRY_BUFFER_METERS
    max_geometry_buffer_meters: int = BUILDING_MAX_GEOMETRY_BUFFER_METERS
    max_source_to_output_area_basis_points: int = BUILDING_MAX_SOURCE_TO_OUTPUT_AREA_BASIS_POINTS
    max_source_area_m2: int = BUILDING_MAX_SOURCE_AREA_M2
    max_relation_objects_per_job: int = BUILDING_MAX_RELATION_OBJECTS_PER_JOB
    relation_closure_mode: str = BUILDING_RELATION_CLOSURE_MODE
    selection_semantics: str = BUILDING_SELECTION_SEMANTICS

    def validate(self) -> None:
        values = (
            self.policy_version, self.block_grid_version, self.block_size_meters,
            self.geometry_buffer_meters, self.relation_retry_buffer_meters,
            self.max_geometry_buffer_meters,
            self.max_source_to_output_area_basis_points, self.max_source_area_m2,
            self.max_relation_objects_per_job,
        )
        if any(isinstance(value, bool) or not isinstance(value, int) for value in values):
            raise BuildingScopeError("building_scope_policy_invalid", "scope policy numeric values must be integers")
        if self.policy_version != BUILDING_SCOPE_POLICY_VERSION:
            raise BuildingScopeError("building_scope_policy_invalid", f"unsupported scope policy version {self.policy_version}")
        if self.block_grid_version != BUILDING_BLOCK_GRID_VERSION:
            raise BuildingScopeError("building_scope_policy_invalid", f"unsupported block grid version {self.block_grid_version}")
        if self.block_size_meters != MAP_BLOCK_SIZE_METERS:
            raise BuildingScopeError("building_scope_policy_invalid", "scope block size is incompatible with the FMB grid")
        if not 0 <= self.geometry_buffer_meters <= self.relation_retry_buffer_meters <= self.max_geometry_buffer_meters:
            raise BuildingScopeError("building_scope_policy_invalid", "geometry and relation buffers are inconsistent")
        if self.max_source_to_output_area_basis_points < 10_000 or self.max_source_area_m2 <= 0:
            raise BuildingScopeError("building_scope_policy_invalid", "scope area limits are invalid")
        if self.max_relation_objects_per_job <= 0:
            raise BuildingScopeError("building_scope_policy_invalid", "relation object limit must be positive")
        if self.relation_closure_mode != BUILDING_RELATION_CLOSURE_MODE or self.selection_semantics != BUILDING_SELECTION_SEMANTICS:
            raise BuildingScopeError("building_scope_policy_invalid", "unsupported scope policy semantics")

    def to_document(self) -> dict[str, Any]:
        return {
            "policyVersion": self.policy_version,
            "blockGridVersion": self.block_grid_version,
            "blockSizeMeters": self.block_size_meters,
            "geometryBufferMeters": self.geometry_buffer_meters,
            "relationRetryBufferMeters": self.relation_retry_buffer_meters,
            "maxGeometryBufferMeters": self.max_geometry_buffer_meters,
            "maxSourceToOutputAreaBasisPoints": self.max_source_to_output_area_basis_points,
            "maxSourceAreaM2": self.max_source_area_m2,
            "maxRelationObjectsPerJob": self.max_relation_objects_per_job,
            "relationClosureMode": self.relation_closure_mode,
            "selectionSemantics": self.selection_semantics,
        }


@dataclass(frozen=True)
class ScopePlan:
    _canonical_payload: bytes
    sha256: str
    output_blocks: tuple[MapBlock, ...]
    output_projected_bounds: tuple[int, int, int, int]
    source_projected_bounds: tuple[int, int, int, int]
    source_bounds: Bounds
    calibration_cells: tuple[tuple[int, int], ...]
    calibration_sample_cells: tuple[tuple[int, int], ...]

    @property
    def document(self) -> dict[str, Any]:
        """Return a defensive copy so the frozen plan identity cannot drift."""
        return json.loads(self._canonical_payload)

    def canonical_bytes(self) -> bytes:
        return self._canonical_payload

    def write(self, path) -> None:
        if hashlib.sha256(self._canonical_payload).hexdigest() != self.sha256:
            raise BuildingScopeError("building_scope_policy_invalid", "scope plan identity changed before serialization")
        serialized = {**json.loads(self._canonical_payload), "scopePlanSha256": self.sha256}
        path.write_bytes(canonical_json(serialized) + b"\n")

    def summary(self) -> dict[str, Any]:
        document = json.loads(self._canonical_payload)
        metrics = document["metrics"]
        policy = document["policy"]
        return {
            "schemaVersion": BUILDING_SCOPE_SCHEMA_VERSION,
            "scopePolicyVersion": policy["policyVersion"],
            "scopePlanSha256": self.sha256,
            **metrics,
            "geometryBufferMeters": policy["geometryBufferMeters"],
            "sourceBoundsE7": document["sourceScope"]["boundsE7"],
        }


def plan_building_scope(
    job: MapJob,
    *,
    calibration_cell_size_meters: int,
    calibration_halo_cells: int,
    calibration_minimum_samples: int,
    policy: BuildingScopePolicy | None = None,
    geometry_buffer_meters: int | None = None,
) -> ScopePlan:
    policy = policy or BuildingScopePolicy()
    policy.validate()
    if any(isinstance(value, bool) or not isinstance(value, int) for value in (
        calibration_cell_size_meters, calibration_halo_cells, calibration_minimum_samples
    )) or calibration_cell_size_meters <= 0 or not 0 <= calibration_halo_cells <= 8 or calibration_minimum_samples <= 0:
        raise BuildingScopeError("building_scope_policy_invalid", "calibration scope settings are invalid")
    buffer_meters = policy.geometry_buffer_meters if geometry_buffer_meters is None else geometry_buffer_meters
    if isinstance(buffer_meters, bool) or not isinstance(buffer_meters, int) or not 0 <= buffer_meters <= policy.max_geometry_buffer_meters:
        raise BuildingScopeError("building_scope_policy_invalid", "geometry buffer is outside the policy range")

    canonical_geometry = canonical_selection_geometry(job.geometry.geometry)
    corridor_width_mm = (
        None
        if job.geometry.corridor_width_m is None
        else int(round(job.geometry.corridor_width_m * 1_000))
    )
    selection = _projected_selection(job, canonical_geometry, corridor_width_mm)
    min_x, min_y, max_x, max_y = aligned_projected_extent(job.geometry.bounds)
    maximum_blocks = max(1, policy.max_source_area_m2 // (MAP_BLOCK_SIZE_METERS ** 2))
    if job.geometry.mode in {GeometryMode.CUSTOM_BBOX, GeometryMode.CURATED_REGION}:
        candidate_count = (
            (max_x - min_x) // MAP_BLOCK_SIZE_METERS
            * (max_y - min_y) // MAP_BLOCK_SIZE_METERS
        )
        if candidate_count > maximum_blocks:
            raise BuildingScopeError("building_scope_exceeded", "output scope exceeds configured area policy")
        blocks = tuple(
            MapBlock(x, y)
            for x in range(min_x // MAP_BLOCK_SIZE_METERS, max_x // MAP_BLOCK_SIZE_METERS)
            for y in range(min_y // MAP_BLOCK_SIZE_METERS, max_y // MAP_BLOCK_SIZE_METERS)
        )
    elif selection["type"] == "line":
        blocks = blocks_for_route(selection, maximum_blocks)
    else:
        blocks = blocks_for_polygons(selection, maximum_blocks)
    if not blocks:
        raise BuildingScopeError("building_scope_policy_invalid", "selection does not intersect an output block")

    output = (
        min(block.x for block in blocks) * MAP_BLOCK_SIZE_METERS,
        min(block.y for block in blocks) * MAP_BLOCK_SIZE_METERS,
        (max(block.x for block in blocks) + 1) * MAP_BLOCK_SIZE_METERS,
        (max(block.y for block in blocks) + 1) * MAP_BLOCK_SIZE_METERS,
    )
    region = project_bounds(job.source_region.bounds)
    if region[0] > output[0] or region[1] > output[1] or region[2] < output[2] or region[3] < output[3]:
        raise BuildingScopeError("building_scope_exceeded", "source region does not cover complete output blocks")
    limit = math.floor(WEB_MERCATOR_LIMIT_METERS)
    source_rectangles = tuple(sorted({(
        max(-limit, block.x * MAP_BLOCK_SIZE_METERS - buffer_meters),
        max(-limit, block.y * MAP_BLOCK_SIZE_METERS - buffer_meters),
        min(limit, (block.x + 1) * MAP_BLOCK_SIZE_METERS + buffer_meters),
        min(limit, (block.y + 1) * MAP_BLOCK_SIZE_METERS + buffer_meters),
    ) for block in blocks}))
    if any(
        region[0] > rect[0]
        or region[1] > rect[1]
        or region[2] < rect[2]
        or region[3] < rect[3]
        for rect in source_rectangles
    ):
        raise BuildingScopeError(
            "building_scope_exceeded",
            "source region does not cover the configured correctness buffer",
        )
    source = (
        min(rect[0] for rect in source_rectangles),
        min(rect[1] for rect in source_rectangles),
        max(rect[2] for rect in source_rectangles),
        max(rect[3] for rect in source_rectangles),
    )
    if source[2] <= source[0] or source[3] <= source[1]:
        raise BuildingScopeError("building_scope_exceeded", "source region does not cover output scope")
    output_area = len(blocks) * MAP_BLOCK_SIZE_METERS * MAP_BLOCK_SIZE_METERS
    source_area = rectangle_union_area(source_rectangles)
    ratio = ceil_ratio_basis_points(source_area, output_area)
    if source_area > policy.max_source_area_m2 or ratio > policy.max_source_to_output_area_basis_points:
        raise BuildingScopeError("building_scope_exceeded", "source scope exceeds configured area policy")

    target_cells = cells_for_rectangles(source_rectangles, calibration_cell_size_meters)
    sample_cells = cells_with_halo(target_cells, calibration_halo_cells)
    source_bounds = Bounds(x_to_lon(source[0]), y_to_lat(source[1]), x_to_lon(source[2]), y_to_lat(source[3]))
    document = {
        "schemaVersion": BUILDING_SCOPE_SCHEMA_VERSION,
        "policy": {**policy.to_document(), "geometryBufferMeters": buffer_meters},
        "requestedSelection": {
            "mode": job.geometry.mode.value,
            "boundsE7": bounds_e7(job.geometry.bounds),
            "geometry": canonical_geometry,
            "corridorWidthMillimeters": corridor_width_mm,
            "areaSemantics": "normalized_request_bounds_approximation",
        },
        "outputBlocks": [
            {"x": block.x, "y": block.y, "boundsMeters": [
                block.x * MAP_BLOCK_SIZE_METERS, block.y * MAP_BLOCK_SIZE_METERS,
                (block.x + 1) * MAP_BLOCK_SIZE_METERS, (block.y + 1) * MAP_BLOCK_SIZE_METERS,
            ]} for block in blocks
        ],
        "outputScope": {"boundsMeters": list(output)},
        "sourceScope": {
            "mode": "buffered_block_rectangles",
            "boundsMeters": list(source),
            "boundsE7": bounds_e7(source_bounds),
            "rectanglesMeters": [list(rect) for rect in source_rectangles],
        },
        "calibration": {
            "cellSizeMeters": calibration_cell_size_meters,
            "haloCells": calibration_halo_cells,
            "minimumSamples": calibration_minimum_samples,
            "targetCells": [list(cell) for cell in target_cells],
            "sampleCells": [list(cell) for cell in sample_cells],
        },
        "metrics": {
            "requestedApproximateAreaM2": max(1, int(round(job.geometry.area_km2 * 1_000_000))),
            "outputAreaM2": output_area,
            "sourceAreaM2": source_area,
            "sourceToOutputAreaBasisPoints": ratio,
            "outputBlockCount": len(blocks),
            "calibrationCellCount": len(target_cells),
            "calibrationSampleCellCount": len(sample_cells),
        },
    }
    encoded = canonical_json(document)
    return ScopePlan(
        encoded, hashlib.sha256(encoded).hexdigest(), blocks, output, source,
        source_bounds, target_cells, sample_cells,
    )


def legacy_building_scope_diagnostics(job: MapJob, *, calibration_cell_size_meters: int, calibration_halo_cells: int) -> dict[str, Any]:
    output = aligned_projected_extent(job.geometry.bounds)
    output_area = (output[2] - output[0]) * (output[3] - output[1])
    aligned = Bounds(x_to_lon(output[0]), y_to_lat(output[1]), x_to_lon(output[2]), y_to_lat(output[3]))
    legacy = expanded_building_source_bounds(aligned, cell_size_meters=calibration_cell_size_meters, halo_cells=calibration_halo_cells)
    projected = project_bounds(legacy)
    source_area = (projected[2] - projected[0]) * (projected[3] - projected[1])
    return {
        "requestedApproximateAreaM2": max(1, int(round(job.geometry.area_km2 * 1_000_000))),
        "outputAreaM2": output_area,
        "legacySourceAreaM2": source_area,
        "legacySourceToOutputAreaBasisPoints": ceil_ratio_basis_points(source_area, output_area),
        "legacySourceBoundsE7": bounds_e7(legacy),
    }


def _projected_selection(
    job: MapJob,
    geometry: dict[str, Any] | None,
    corridor_width_mm: int | None,
) -> dict[str, Any]:
    if job.geometry.mode == GeometryMode.CUSTOM_BBOX or geometry is None:
        return {"type": "bbox", "bounds": project_bounds(job.geometry.bounds)}
    if geometry.get("type") == "LineString":
        coordinates = geometry["coordinates"]
        physical_buffer = (corridor_width_mm or 0) / 1_000
        points, segment_buffers = projected_route_segments(
            coordinates, physical_buffer
        )
        return {
            "type": "line",
            "points": points,
            "segmentBuffers": segment_buffers,
        }
    polygons = geometry["coordinates"]
    if geometry.get("type") == "Polygon":
        polygons = [polygons]
    return {"type": "polygon", "polygons": tuple(
        tuple(tuple(project_point(point) for point in ring) for ring in polygon)
        for polygon in polygons
    )}


def _block_intersects_selection(block: MapBlock, selection: dict[str, Any]) -> bool:
    left, bottom = block.x * MAP_BLOCK_SIZE_METERS, block.y * MAP_BLOCK_SIZE_METERS
    rect = (left, bottom, left + MAP_BLOCK_SIZE_METERS, bottom + MAP_BLOCK_SIZE_METERS)
    if selection["type"] == "bbox":
        return rectangles_intersect(rect, selection["bounds"])
    if selection["type"] == "line":
        return any(
            segment_rectangle_distance(a, b, rect) <= buffer_meters
            for a, b, buffer_meters in zip(
                selection["points"],
                selection["points"][1:],
                selection["segmentBuffers"],
            )
        )
    return any(polygon_intersects_rectangle(polygon, rect) for polygon in selection["polygons"])


def polygon_intersects_rectangle(polygon: Sequence[Sequence[tuple[float, float]]], rect) -> bool:
    if not polygon or not polygon[0]:
        return False
    corners = ((rect[0], rect[1]), (rect[2], rect[1]), (rect[2], rect[3]), (rect[0], rect[3]))
    if any(point_in_polygon(corner, polygon) for corner in corners):
        return True
    if any(rect[0] <= point[0] <= rect[2] and rect[1] <= point[1] <= rect[3] for point in polygon[0]):
        return True
    return any(segment_intersects_rectangle(a, b, rect) for ring in polygon for a, b in zip(ring, ring[1:]))


def point_in_polygon(point, polygon) -> bool:
    return point_in_ring(point, polygon[0]) and not any(point_in_ring(point, hole) for hole in polygon[1:])


def point_in_ring(point, ring) -> bool:
    x, y, inside = point[0], point[1], False
    for a, b in zip(ring, ring[1:]):
        if point_on_segment(point, a, b):
            return True
        if (a[1] > y) != (b[1] > y) and x <= (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]) + a[0]:
            inside = not inside
    return inside


def segment_intersects_rectangle(a, b, rect) -> bool:
    if any(rect[0] <= p[0] <= rect[2] and rect[1] <= p[1] <= rect[3] for p in (a, b)):
        return True
    corners = ((rect[0], rect[1]), (rect[2], rect[1]), (rect[2], rect[3]), (rect[0], rect[3]))
    return any(segments_intersect(a, b, corner, corners[(i + 1) % 4]) for i, corner in enumerate(corners))


def segments_intersect(a, b, c, d) -> bool:
    def orientation(p, q, r):
        value = (q[1] - p[1]) * (r[0] - q[0]) - (q[0] - p[0]) * (r[1] - q[1])
        return 0 if math.isclose(value, 0.0, abs_tol=1e-7) else 1 if value > 0 else 2
    values = orientation(a, b, c), orientation(a, b, d), orientation(c, d, a), orientation(c, d, b)
    return (values[0] != values[1] and values[2] != values[3]) or any((
        values[0] == 0 and point_on_segment(c, a, b), values[1] == 0 and point_on_segment(d, a, b),
        values[2] == 0 and point_on_segment(a, c, d), values[3] == 0 and point_on_segment(b, c, d),
    ))


def point_on_segment(point, a, b) -> bool:
    cross = (point[0] - a[0]) * (b[1] - a[1]) - (point[1] - a[1]) * (b[0] - a[0])
    scale = max(1.0, abs(b[0] - a[0]), abs(b[1] - a[1]))
    return (
        abs(cross) <= 1e-9 * scale * scale
        and min(a[0], b[0]) - 1e-7 <= point[0] <= max(a[0], b[0]) + 1e-7
        and min(a[1], b[1]) - 1e-7 <= point[1] <= max(a[1], b[1]) + 1e-7
    )


def segment_rectangle_distance(a, b, rect) -> float:
    if segment_intersects_rectangle(a, b, rect):
        return 0.0
    corners = ((rect[0], rect[1]), (rect[2], rect[1]), (rect[2], rect[3]), (rect[0], rect[3]))
    return min(
        point_rectangle_distance(a, rect),
        point_rectangle_distance(b, rect),
        *(point_segment_distance(corner, a, b) for corner in corners),
    )


def point_rectangle_distance(point, rect) -> float:
    dx = max(rect[0] - point[0], 0.0, point[0] - rect[2])
    dy = max(rect[1] - point[1], 0.0, point[1] - rect[3])
    return math.hypot(dx, dy)


def point_segment_distance(point, a, b) -> float:
    dx, dy = b[0] - a[0], b[1] - a[1]
    denominator = dx * dx + dy * dy
    if denominator == 0:
        return math.hypot(point[0] - a[0], point[1] - a[1])
    projection = max(0.0, min(1.0, ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / denominator))
    return math.hypot(point[0] - (a[0] + projection * dx), point[1] - (a[1] + projection * dy))


def blocks_for_route(selection: dict[str, Any], maximum_blocks: int) -> tuple[MapBlock, ...]:
    selected: set[MapBlock] = set()
    for a, b, buffer_meters in zip(
        selection["points"], selection["points"][1:], selection["segmentBuffers"]
    ):
        radius = math.ceil(buffer_meters / MAP_BLOCK_SIZE_METERS)
        candidates = {
            MapBlock(block.x + dx, block.y + dy)
            for block in grid_cells_for_segment(a, b)
            for dx in range(-radius, radius + 1)
            for dy in range(-radius, radius + 1)
        }
        for block in candidates:
            if _block_intersects_selection(block, {
                "type": "line",
                "points": (a, b),
                "segmentBuffers": (buffer_meters,),
            }):
                selected.add(block)
                if len(selected) > maximum_blocks:
                    raise BuildingScopeError("building_scope_exceeded", "route output scope exceeds configured area policy")
    return tuple(sorted(selected))


def blocks_for_polygons(selection: dict[str, Any], maximum_blocks: int) -> tuple[MapBlock, ...]:
    selected: set[MapBlock] = set()
    for polygon in selection["polygons"]:
        edge_blocks = {
            block
            for ring in polygon
            for a, b in zip(ring, ring[1:])
            for block in grid_cells_for_segment(a, b)
        }
        for block in edge_blocks:
            if _block_intersects_selection(block, {"type": "polygon", "polygons": (polygon,)}):
                selected.add(block)
                if len(selected) > maximum_blocks:
                    raise BuildingScopeError("building_scope_exceeded", "polygon output scope exceeds configured area policy")
        for block in scanline_interior_blocks(polygon):
            if block not in selected and _block_intersects_selection(
                block, {"type": "polygon", "polygons": (polygon,)}
            ):
                selected.add(block)
                if len(selected) > maximum_blocks:
                    raise BuildingScopeError("building_scope_exceeded", "polygon output scope exceeds configured area policy")
    return tuple(sorted(selected))


def scanline_interior_blocks(polygon) -> Iterable[MapBlock]:
    """Yield interior candidates by row without scanning empty bbox columns."""
    outer = polygon[0]
    min_y = math.floor(min(point[1] for point in outer) / MAP_BLOCK_SIZE_METERS)
    max_y = math.floor(max(point[1] for point in outer) / MAP_BLOCK_SIZE_METERS)
    for block_y in range(min_y, max_y + 1):
        scan_y = (block_y + 0.5) * MAP_BLOCK_SIZE_METERS
        crossings = sorted(
            a[0] + (scan_y - a[1]) * (b[0] - a[0]) / (b[1] - a[1])
            for a, b in zip(outer, outer[1:])
            if (a[1] <= scan_y < b[1]) or (b[1] <= scan_y < a[1])
        )
        for left, right in zip(crossings[::2], crossings[1::2]):
            for block_x in range(
                math.floor(left / MAP_BLOCK_SIZE_METERS),
                math.floor(right / MAP_BLOCK_SIZE_METERS) + 1,
            ):
                yield MapBlock(block_x, block_y)


def grid_cells_for_segment(a, b) -> tuple[MapBlock, ...]:
    """Return every grid cell traversed by a segment in bounded linear time."""
    start_x = math.floor(a[0] / MAP_BLOCK_SIZE_METERS)
    start_y = math.floor(a[1] / MAP_BLOCK_SIZE_METERS)
    end_x = math.floor(b[0] / MAP_BLOCK_SIZE_METERS)
    end_y = math.floor(b[1] / MAP_BLOCK_SIZE_METERS)
    x, y = start_x, start_y
    result = [MapBlock(x, y)]
    dx, dy = b[0] - a[0], b[1] - a[1]
    step_x = 0 if dx == 0 else 1 if dx > 0 else -1
    step_y = 0 if dy == 0 else 1 if dy > 0 else -1
    t_delta_x = math.inf if dx == 0 else MAP_BLOCK_SIZE_METERS / abs(dx)
    t_delta_y = math.inf if dy == 0 else MAP_BLOCK_SIZE_METERS / abs(dy)
    next_x = (x + (1 if step_x > 0 else 0)) * MAP_BLOCK_SIZE_METERS
    next_y = (y + (1 if step_y > 0 else 0)) * MAP_BLOCK_SIZE_METERS
    t_max_x = math.inf if dx == 0 else (next_x - a[0]) / dx
    t_max_y = math.inf if dy == 0 else (next_y - a[1]) / dy
    while x != end_x or y != end_y:
        if t_max_x < t_max_y:
            x += step_x
            t_max_x += t_delta_x
        elif t_max_y < t_max_x:
            y += step_y
            t_max_y += t_delta_y
        else:
            result.append(MapBlock(x + step_x, y))
            result.append(MapBlock(x, y + step_y))
            x += step_x
            y += step_y
            t_max_x += t_delta_x
            t_max_y += t_delta_y
        result.append(MapBlock(x, y))
    return tuple(dict.fromkeys(result))


def canonical_selection_geometry(geometry: dict[str, Any] | None) -> dict[str, Any] | None:
    if geometry is None:
        return None
    geometry_type = geometry.get("type")
    if geometry_type == "LineString":
        points = tuple(_canonical_point(point) for point in geometry.get("coordinates", ()))
        reversed_points = tuple(reversed(points))
        return {"type": "LineString", "coordinates": [list(point) for point in min(points, reversed_points)]}
    polygons = geometry.get("coordinates", ())
    if geometry_type == "Polygon":
        polygons = [polygons]
    canonical_polygons = sorted(_canonical_polygon(polygon) for polygon in polygons)
    coordinates = [
        [[list(point) for point in ring] for ring in polygon]
        for polygon in canonical_polygons
    ]
    return {
        "type": geometry_type,
        "coordinates": coordinates[0] if geometry_type == "Polygon" else coordinates,
    }


def _canonical_polygon(polygon) -> tuple:
    outer = _canonical_ring(polygon[0])
    holes = tuple(sorted(_canonical_ring(ring) for ring in polygon[1:]))
    return (outer, *holes)


def _canonical_ring(ring) -> tuple[tuple[float, float], ...]:
    points = tuple(_canonical_point(point) for point in ring)
    if points and points[0] == points[-1]:
        points = points[:-1]
    if not points:
        return ()
    candidates = []
    for oriented in (points, tuple(reversed(points))):
        for index in range(len(oriented)):
            candidates.append(oriented[index:] + oriented[:index])
    canonical = min(candidates)
    return (*canonical, canonical[0])


def _canonical_point(point) -> tuple[float, float]:
    return tuple(0.0 if float(value) == 0 else float(value) for value in point[:2])


def rectangle_union_area(rectangles: Iterable[tuple[int, int, int, int]]) -> int:
    rectangles = tuple(rectangles)
    x_values = sorted({value for rectangle in rectangles for value in (rectangle[0], rectangle[2])})
    area = 0
    for left, right in zip(x_values, x_values[1:]):
        intervals = sorted(
            (rectangle[1], rectangle[3])
            for rectangle in rectangles
            if rectangle[0] < right and rectangle[2] > left
        )
        covered = 0
        if intervals:
            start, end = intervals[0]
            for interval_start, interval_end in intervals[1:]:
                if interval_start > end:
                    covered += end - start
                    start, end = interval_start, interval_end
                else:
                    end = max(end, interval_end)
            covered += end - start
        area += (right - left) * covered
    return area


def cells_for_rectangles(rectangles: Iterable[tuple[int, int, int, int]], cell_size: int) -> tuple[tuple[int, int], ...]:
    cells = set()
    for min_x, min_y, max_x, max_y in rectangles:
        for x in range(math.floor(min_x / cell_size), math.floor((max_x - 1) / cell_size) + 1):
            for y in range(math.floor(min_y / cell_size), math.floor((max_y - 1) / cell_size) + 1):
                cells.add((x, y))
    return tuple(sorted(cells))


def cells_for_blocks(blocks: Iterable[MapBlock], cell_size: int) -> tuple[tuple[int, int], ...]:
    cells = set()
    for block in blocks:
        min_x, min_y = block.x * MAP_BLOCK_SIZE_METERS, block.y * MAP_BLOCK_SIZE_METERS
        max_x, max_y = (block.x + 1) * MAP_BLOCK_SIZE_METERS - 1, (block.y + 1) * MAP_BLOCK_SIZE_METERS - 1
        for x in range(math.floor(min_x / cell_size), math.floor(max_x / cell_size) + 1):
            for y in range(math.floor(min_y / cell_size), math.floor(max_y / cell_size) + 1):
                cells.add((x, y))
    return tuple(sorted(cells))


def cells_with_halo(cells: Iterable[tuple[int, int]], halo: int) -> tuple[tuple[int, int], ...]:
    return tuple(sorted({(x + dx, y + dy) for x, y in cells for dx in range(-halo, halo + 1) for dy in range(-halo, halo + 1)}))


def project_bounds(bounds: Bounds) -> tuple[int, int, int, int]:
    return math.floor(lon_to_x(bounds.min_lon)), math.floor(lat_to_y(bounds.min_lat)), math.ceil(lon_to_x(bounds.max_lon)), math.ceil(lat_to_y(bounds.max_lat))


def project_point(point: Sequence[float]) -> tuple[float, float]:
    return lon_to_x(float(point[0])), lat_to_y(float(point[1]))


def lon_to_x(lon: float) -> float:
    return math.radians(lon) * EARTH_RADIUS_METERS


def lat_to_y(lat: float) -> float:
    return math.log(math.tan(math.radians(lat) / 2 + math.pi / 4)) * EARTH_RADIUS_METERS


def mercator_scale(lat: float) -> float:
    return 1.0 / max(math.cos(math.radians(lat)), 1e-9)


def projected_route_segments(coordinates, physical_buffer: float):
    points: list[tuple[float, float]] = []
    buffers: list[float] = []
    for start, end in zip(coordinates, coordinates[1:]):
        projected_start, projected_end = project_point(start), project_point(end)
        projected_length = math.hypot(
            projected_end[0] - projected_start[0],
            projected_end[1] - projected_start[1],
        )
        divisions = max(
            1,
            math.ceil(projected_length / MAP_BLOCK_SIZE_METERS),
            math.ceil(abs(float(end[1]) - float(start[1])) / 0.01),
        )
        for index in range(divisions):
            fraction_start = index / divisions
            fraction_end = (index + 1) / divisions
            segment_start = (
                float(start[0]) + (float(end[0]) - float(start[0])) * fraction_start,
                float(start[1]) + (float(end[1]) - float(start[1])) * fraction_start,
            )
            segment_end = (
                float(start[0]) + (float(end[0]) - float(start[0])) * fraction_end,
                float(start[1]) + (float(end[1]) - float(start[1])) * fraction_end,
            )
            if not points:
                points.append(project_point(segment_start))
            points.append(project_point(segment_end))
            buffers.append(
                physical_buffer
                * max(mercator_scale(segment_start[1]), mercator_scale(segment_end[1]))
            )
    return tuple(points), tuple(buffers)


def x_to_lon(x: float) -> float:
    return math.degrees(x / EARTH_RADIUS_METERS)


def y_to_lat(y: float) -> float:
    return math.degrees(2 * math.atan(math.exp(y / EARTH_RADIUS_METERS)) - math.pi / 2)


def bounds_e7(bounds: Bounds) -> list[int]:
    return [int(round(value * 10_000_000)) for value in bounds.to_list()]


def ceil_ratio_basis_points(numerator: int, denominator: int) -> int:
    return (numerator * 10_000 + denominator - 1) // denominator


def rectangles_intersect(first, second) -> bool:
    return not (first[2] < second[0] or second[2] < first[0] or first[3] < second[1] or second[3] < first[1])


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")
