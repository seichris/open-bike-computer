"""OSM bridge/tunnel structures for route-aware elevation correction.

Production metadata comes from a read-only SQLite index that an operator builds
from an OpenStreetMap extract (for example a Geofabrik ``.osm.pbf`` already
staged for map generation) with ``map-platform route-elevation-structures``.
Requests never call Overpass or another network service.

Association is deliberately conservative. A structure is used only when the
supplied route follows it (distance and heading) from one structure endpoint to
another over most of the traversed ways. Partial alignment, structures the
travel mode cannot use, and overlapping structures on different layers are
reported as ambiguous: their raw heights are kept but never force-corrected,
and grade/completeness are withheld. OSM ``layer`` orders structures; it is
never treated as an absolute height.
"""

from __future__ import annotations

import math
import os
import sqlite3
import struct
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable, Sequence

from .route_elevation import (
    EARTH_RADIUS_M,
    STRUCTURE_AMBIGUOUS,
    STRUCTURE_ESTIMATED,
    RouteGeometry,
    StructureCorrection,
    StructureSpan,
    haversine_m,
    normalize_longitude_delta,
)

STRUCTURE_INDEX_SCHEMA = "bicino-osm-structure-index-v1"
OSM_ATTRIBUTION = "Bridge and tunnel data © OpenStreetMap contributors (ODbL 1.0)"
CELL_SCALE = 100
MAXIMUM_WAY_POINTS = 2_000
MAXIMUM_WAY_LENGTH_M = 50_000.0
MAXIMUM_QUERY_WAYS = 20_000
MAXIMUM_INDEX_FILES = 64
QUERY_CHUNK_M = 2_000.0
QUERY_MARGIN_M = 60.0

PROBE_SPACING_M = 10.0
MATCH_DISTANCE_M = 15.0
MATCH_HEADING_DEG = 30.0
ENDPOINT_TOLERANCE_M = 30.0
MINIMUM_TRAVERSED_FRACTION = 0.6
MAXIMUM_MATCH_GAP_PROBES = 2
MINIMUM_SPAN_M = 20.0
STACKED_MINIMUM_OVERLAP_M = 50.0
TRAVEL_MODES = ("cycling", "any")

_METRES_PER_DEGREE = EARTH_RADIUS_M * math.pi / 180.0
_EXCLUDED_BRIDGE_VALUES = {"no", "low_water_crossing", "proposed", "construction", "abandoned"}
_EXCLUDED_TUNNEL_VALUES = {"no", "culvert", "flooded", "proposed", "construction", "abandoned"}
_EXCLUDED_HIGHWAYS = {"proposed", "construction", "abandoned", "razed", "platform"}
_NOT_CYCLABLE_HIGHWAYS = {"motorway", "motorway_link"}
_CYCLING_ALLOWED = {"yes", "designated", "permissive", "destination"}
_CYCLING_FORBIDDEN = {"no", "use_sidepath", "dismount"}


class StructureIndexError(ValueError):
    """Raised for malformed or unusable structure indexes."""


@dataclass(frozen=True)
class StructureWay:
    way_id: int
    version: int | None
    kind: str
    highway: str
    layer: int
    bicycle: str | None
    access: str | None
    lat_e7: tuple[int, ...]
    lon_e7: tuple[int, ...]

    @property
    def cyclable(self) -> bool:
        if self.bicycle in _CYCLING_FORBIDDEN:
            return False
        if self.bicycle in _CYCLING_ALLOWED:
            return True
        if self.access in {"no", "private"}:
            return False
        return self.highway not in _NOT_CYCLABLE_HIGHWAYS

    def latitude(self, index: int) -> float:
        return self.lat_e7[index] / 10_000_000.0

    def longitude(self, index: int) -> float:
        return self.lon_e7[index] / 10_000_000.0

    def length_m(self) -> float:
        return sum(
            haversine_m(self.latitude(i), self.longitude(i), self.latitude(i + 1), self.longitude(i + 1))
            for i in range(len(self.lat_e7) - 1)
        )


def structure_kind(tags: dict[str, str]) -> str | None:
    """Classify an OSM highway way as ``bridge``/``tunnel``, or ``None``."""

    highway = tags.get("highway")
    if not highway or highway in _EXCLUDED_HIGHWAYS:
        return None
    bridge = tags.get("bridge")
    tunnel = tags.get("tunnel")
    is_bridge = bridge is not None and bridge not in _EXCLUDED_BRIDGE_VALUES
    is_tunnel = tunnel is not None and tunnel not in _EXCLUDED_TUNNEL_VALUES
    if tags.get("covered") == "yes" and not is_tunnel and not is_bridge:
        return None
    if is_bridge and is_tunnel:
        return None
    if is_bridge:
        return "bridge"
    if is_tunnel:
        return "tunnel"
    return None


def parse_layer(value: str | None) -> int:
    if value is None:
        return 0
    text = value.strip()
    if text.startswith(("-", "+")):
        sign, digits = text[0], text[1:]
    else:
        sign, digits = "+", text
    if not digits.isdecimal() or len(digits) > 2:
        return 0
    layer = int(digits) * (-1 if sign == "-" else 1)
    return max(-5, min(5, layer))


def _cell(lat: float, lon: float) -> tuple[int, int]:
    return math.floor(lat * CELL_SCALE), math.floor(lon * CELL_SCALE)


def _cell_key(lat_cell: int, lon_cell: int) -> int:
    return (lat_cell + 90 * CELL_SCALE) * (360 * CELL_SCALE + 1) + (lon_cell + 180 * CELL_SCALE)


def _cells_for_bounds(min_lat: float, min_lon: float, max_lat: float, max_lon: float) -> list[int]:
    lat0, lon0 = _cell(min_lat, min_lon)
    lat1, lon1 = _cell(max_lat, max_lon)
    if (lat1 - lat0 + 1) * (lon1 - lon0 + 1) > 4096:
        raise StructureIndexError("structure query area is too large")
    return [_cell_key(lat, lon) for lat in range(lat0, lat1 + 1) for lon in range(lon0, lon1 + 1)]


def _encode_geometry(lat_e7: Sequence[int], lon_e7: Sequence[int]) -> bytes:
    return b"".join(struct.pack("<ii", lat, lon) for lat, lon in zip(lat_e7, lon_e7))


def _decode_geometry(blob: bytes) -> tuple[tuple[int, ...], tuple[int, ...]]:
    if len(blob) % 8 or not 16 <= len(blob) <= MAXIMUM_WAY_POINTS * 8:
        raise StructureIndexError("structure geometry is malformed")
    values = struct.unpack("<" + "i" * (len(blob) // 4), blob)
    return tuple(values[0::2]), tuple(values[1::2])


def build_structure_index(
    source_path: Path,
    output_path: Path,
    *,
    source_label: str,
    bounds: tuple[float, float, float, float] | None = None,
    clock: Callable[[], float] = time.time,
) -> dict[str, object]:
    """Extract highway bridge/tunnel ways from an OSM file into a new index.

    ``bounds`` is ``(west, south, east, north)``. The output must not exist;
    it is written to a temporary file and published atomically.
    """

    import osmium

    if output_path.exists():
        raise StructureIndexError("structure index output already exists")
    if not source_label or len(source_label) > 200:
        raise StructureIndexError("structure index needs a short source label")
    if bounds is not None:
        west, south, east, north = bounds
        if not (-180 <= west < east <= 180 and -90 <= south < north <= 90):
            raise StructureIndexError("invalid structure index bounds")
    processor = (
        osmium.FileProcessor(str(source_path), osmium.osm.NODE | osmium.osm.WAY)
        .with_locations()
        .with_filter(osmium.filter.KeyFilter("bridge", "tunnel"))
    )
    timestamp = processor.header.get("osmosis_replication_timestamp") or None
    output_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".structures-", suffix=".sqlite3", dir=output_path.parent)
    os.close(descriptor)
    temporary_path = Path(temporary)
    count = 0
    skipped = 0
    extent = [math.inf, math.inf, -math.inf, -math.inf]
    try:
        connection = sqlite3.connect(temporary_path)
        try:
            _create_index_schema(connection)
            for item in processor:
                if not item.is_way():
                    continue
                tags = {tag.k: tag.v for tag in item.tags}
                kind = structure_kind(tags)
                if kind is None:
                    continue
                try:
                    nodes = [(node.lat, node.lon) for node in item.nodes]
                except osmium.InvalidLocationError:
                    skipped += 1
                    continue
                if not 2 <= len(nodes) <= MAXIMUM_WAY_POINTS:
                    skipped += 1
                    continue
                lat_e7 = [int(round(lat * 10_000_000)) for lat, _ in nodes]
                lon_e7 = [int(round(lon * 10_000_000)) for _, lon in nodes]
                min_lat, max_lat = min(lat for lat, _ in nodes), max(lat for lat, _ in nodes)
                min_lon, max_lon = min(lon for _, lon in nodes), max(lon for _, lon in nodes)
                if max_lon - min_lon > 180:
                    skipped += 1
                    continue
                if bounds is not None and (
                    max_lon < bounds[0] or min_lon > bounds[2] or max_lat < bounds[1] or min_lat > bounds[3]
                ):
                    continue
                way = StructureWay(
                    way_id=int(item.id),
                    version=int(item.version) if item.version else None,
                    kind=kind,
                    highway=tags["highway"],
                    layer=parse_layer(tags.get("layer")),
                    bicycle=tags.get("bicycle"),
                    access=tags.get("access"),
                    lat_e7=tuple(lat_e7),
                    lon_e7=tuple(lon_e7),
                )
                if way.length_m() > MAXIMUM_WAY_LENGTH_M:
                    skipped += 1
                    continue
                _insert_way(connection, way, (min_lat, min_lon, max_lat, max_lon))
                extent = [min(extent[0], min_lon), min(extent[1], min_lat), max(extent[2], max_lon), max(extent[3], max_lat)]
                count += 1
            index_bounds = list(bounds) if bounds is not None else (extent if count else [0.0, 0.0, 0.0, 0.0])
            built_at = datetime.fromtimestamp(clock(), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            meta = {
                "schema": STRUCTURE_INDEX_SCHEMA,
                "sourceLabel": source_label,
                "sourceTimestamp": timestamp or "unknown",
                "builtAt": built_at,
                "wayCount": str(count),
                "bounds": ",".join(f"{value:.7f}" for value in index_bounds),
                "attribution": OSM_ATTRIBUTION,
            }
            connection.executemany("INSERT INTO meta(key, value) VALUES (?, ?)", sorted(meta.items()))
            connection.commit()
        finally:
            connection.close()
        os.replace(temporary_path, output_path)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise
    return {"wayCount": count, "skippedWays": skipped, "sourceTimestamp": timestamp, "output": str(output_path)}


def _create_index_schema(connection: sqlite3.Connection) -> None:
    connection.execute("CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    connection.execute(
        "CREATE TABLE structures(way_id INTEGER PRIMARY KEY, version INTEGER, kind TEXT NOT NULL, "
        "highway TEXT NOT NULL, layer INTEGER NOT NULL, bicycle TEXT, access TEXT, geometry BLOB NOT NULL)"
    )
    connection.execute(
        "CREATE TABLE structure_cells(cell INTEGER NOT NULL, way_id INTEGER NOT NULL, "
        "PRIMARY KEY(cell, way_id)) WITHOUT ROWID"
    )


def _insert_way(
    connection: sqlite3.Connection,
    way: StructureWay,
    bounds: tuple[float, float, float, float],
) -> None:
    connection.execute(
        "INSERT OR REPLACE INTO structures(way_id, version, kind, highway, layer, bicycle, access, geometry) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (way.way_id, way.version, way.kind, way.highway, way.layer, way.bicycle, way.access,
         _encode_geometry(way.lat_e7, way.lon_e7)),
    )
    connection.executemany(
        "INSERT OR IGNORE INTO structure_cells(cell, way_id) VALUES (?, ?)",
        [(cell, way.way_id) for cell in _cells_for_bounds(*bounds)],
    )


def write_structure_fixture_index(
    output_path: Path,
    ways: Iterable[StructureWay],
    *,
    source_label: str,
    source_timestamp: str,
    bounds: tuple[float, float, float, float],
) -> None:
    """Write an index from already-parsed ways (tests and reviewed fixtures)."""

    if output_path.exists():
        raise StructureIndexError("structure index output already exists")
    connection = sqlite3.connect(output_path)
    try:
        _create_index_schema(connection)
        count = 0
        for way in ways:
            lats = [way.latitude(i) for i in range(len(way.lat_e7))]
            lons = [way.longitude(i) for i in range(len(way.lon_e7))]
            _insert_way(connection, way, (min(lats), min(lons), max(lats), max(lons)))
            count += 1
        meta = {
            "schema": STRUCTURE_INDEX_SCHEMA,
            "sourceLabel": source_label,
            "sourceTimestamp": source_timestamp,
            "builtAt": source_timestamp,
            "wayCount": str(count),
            "bounds": ",".join(f"{value:.7f}" for value in bounds),
            "attribution": OSM_ATTRIBUTION,
        }
        connection.executemany("INSERT INTO meta(key, value) VALUES (?, ?)", sorted(meta.items()))
        connection.commit()
    finally:
        connection.close()


class StructureIndex:
    """A read-only structure index file."""

    def __init__(self, path: Path):
        self.path = path
        try:
            connection = self._connect()
        except sqlite3.Error as exc:
            raise StructureIndexError("structure index is unreadable") from exc
        try:
            rows = dict(connection.execute("SELECT key, value FROM meta").fetchall())
        except sqlite3.Error as exc:
            raise StructureIndexError("structure index is unreadable") from exc
        finally:
            connection.close()
        if rows.get("schema") != STRUCTURE_INDEX_SCHEMA:
            raise StructureIndexError("unsupported structure index schema")
        try:
            west, south, east, north = (float(value) for value in rows["bounds"].split(","))
        except (KeyError, ValueError) as exc:
            raise StructureIndexError("structure index bounds are malformed") from exc
        if not (-180 <= west <= east <= 180 and -90 <= south <= north <= 90):
            raise StructureIndexError("structure index bounds are malformed")
        self.bounds = (west, south, east, north)
        self.source_label = rows.get("sourceLabel", "unknown")
        self.source_timestamp = rows.get("sourceTimestamp", "unknown")

    @property
    def source_version(self) -> str:
        return f"{self.source_label}@{self.source_timestamp}"

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True, timeout=5)
        connection.execute("PRAGMA query_only=ON")
        return connection

    def contains(self, lat: float, lon: float) -> bool:
        west, south, east, north = self.bounds
        return south <= lat <= north and west <= lon <= east

    def query(self, cells: Sequence[int], *, limit: int = MAXIMUM_QUERY_WAYS) -> list[StructureWay]:
        if not cells:
            return []
        connection = self._connect()
        try:
            way_ids: set[int] = set()
            for start in range(0, len(cells), 500):
                chunk = list(cells[start:start + 500])
                placeholders = ",".join("?" for _ in chunk)
                for (way_id,) in connection.execute(
                    f"SELECT DISTINCT way_id FROM structure_cells WHERE cell IN ({placeholders})", chunk
                ):
                    way_ids.add(int(way_id))
                    if len(way_ids) > limit:
                        raise StructureIndexError("too-many-structures")
            ways: list[StructureWay] = []
            ordered = sorted(way_ids)
            for start in range(0, len(ordered), 500):
                chunk = ordered[start:start + 500]
                placeholders = ",".join("?" for _ in chunk)
                for row in connection.execute(
                    "SELECT way_id, version, kind, highway, layer, bicycle, access, geometry "
                    f"FROM structures WHERE way_id IN ({placeholders}) ORDER BY way_id",
                    chunk,
                ):
                    lat_e7, lon_e7 = _decode_geometry(row[7])
                    if row[2] not in ("bridge", "tunnel"):
                        raise StructureIndexError("structure kind is malformed")
                    ways.append(StructureWay(
                        way_id=int(row[0]), version=row[1], kind=row[2], highway=row[3],
                        layer=int(row[4]), bicycle=row[5], access=row[6], lat_e7=lat_e7, lon_e7=lon_e7,
                    ))
            return ways
        except sqlite3.Error as exc:
            raise StructureIndexError("structure index is unreadable") from exc
        finally:
            connection.close()


def route_query_cells(geometry: RouteGeometry) -> list[int]:
    """Cells covering the route corridor, chunked so long routes stay narrow."""

    cells: set[int] = set()
    length = geometry.length_m
    start = 0.0
    vertex = 0
    while start < length or start == 0.0:
        end = min(length, start + QUERY_CHUNK_M)
        lats: list[float] = []
        lons: list[float] = []
        for distance in (start, end):
            lat, lon = geometry.point_at_distance(distance)
            lats.append(lat)
            lons.append(lon)
        while vertex < geometry.point_count and geometry.cumulative_m[vertex] < start:
            vertex += 1
        probe = vertex
        while probe < geometry.point_count and geometry.cumulative_m[probe] <= end:
            lats.append(geometry.latitude(probe))
            lons.append(geometry.longitude(probe))
            probe += 1
        reference = lons[0]
        unwrapped = [reference + normalize_longitude_delta(value - reference) for value in lons]
        min_lat, max_lat = min(lats), max(lats)
        lat_margin = QUERY_MARGIN_M / _METRES_PER_DEGREE
        lon_margin = QUERY_MARGIN_M / (_METRES_PER_DEGREE * max(0.01, math.cos(math.radians((min_lat + max_lat) / 2))))
        west, east = min(unwrapped) - lon_margin, max(unwrapped) + lon_margin
        south, north = max(-90.0, min_lat - lat_margin), min(90.0, max_lat + lat_margin)
        for left, right in _split_longitudes(west, east):
            cells.update(_cells_for_bounds(south, left, north, right))
        if end >= length:
            break
        start = end
    return sorted(cells)


def _split_longitudes(west: float, east: float) -> list[tuple[float, float]]:
    if west < -180.0:
        return [(west + 360.0, 179.9999999), (-180.0, east)]
    if east >= 180.0:
        return [(west, 179.9999999), (-180.0, east - 360.0)]
    return [(west, east)]


@dataclass(frozen=True)
class _Segment:
    way_index: int
    lat0: float
    lon0: float
    lat1: float
    lon1: float


def _local_xy(lat: float, lon: float, ref_lat: float, ref_lon: float) -> tuple[float, float]:
    x = normalize_longitude_delta(lon - ref_lon) * math.cos(math.radians(ref_lat)) * _METRES_PER_DEGREE
    y = (lat - ref_lat) * _METRES_PER_DEGREE
    return x, y


def _distance_and_bearing(lat: float, lon: float, segment: _Segment) -> tuple[float, float | None]:
    ax, ay = _local_xy(segment.lat0, segment.lon0, lat, lon)
    bx, by = _local_xy(segment.lat1, segment.lon1, lat, lon)
    dx, dy = bx - ax, by - ay
    length_squared = dx * dx + dy * dy
    if length_squared <= 0.0:
        return math.hypot(ax, ay), None
    t = max(0.0, min(1.0, -(ax * dx + ay * dy) / length_squared))
    px, py = ax + t * dx, ay + t * dy
    bearing = (math.degrees(math.atan2(dx, dy)) + 360.0) % 360.0
    return math.hypot(px, py), bearing


def _undirected_heading_difference(first: float, second: float) -> float:
    difference = abs((first - second + 180.0) % 360.0 - 180.0)
    return min(difference, 180.0 - difference)


@dataclass
class _Group:
    kind: str
    way_indexes: list[int]
    endpoints: list[tuple[float, float]]


def _group_ways(ways: Sequence[StructureWay]) -> list[_Group]:
    parent = list(range(len(ways)))

    def find(item: int) -> int:
        while parent[item] != item:
            parent[item] = parent[parent[item]]
            item = parent[item]
        return item

    # Only same-kind, same-layer ways form one structure: a different level
    # that happens to share endpoint coordinates is a separate structure.
    endpoint_owner: dict[tuple[str, int, int, int], int] = {}
    for index, way in enumerate(ways):
        for position in (0, len(way.lat_e7) - 1):
            key = (way.kind, way.layer, way.lat_e7[position], way.lon_e7[position])
            if key in endpoint_owner:
                parent[find(index)] = find(endpoint_owner[key])
            else:
                endpoint_owner[key] = index
    members: dict[int, list[int]] = {}
    for index in range(len(ways)):
        members.setdefault(find(index), []).append(index)
    groups: list[_Group] = []
    for indexes in members.values():
        degree: dict[tuple[int, int], int] = {}
        for index in indexes:
            way = ways[index]
            for position in (0, len(way.lat_e7) - 1):
                key = (way.lat_e7[position], way.lon_e7[position])
                degree[key] = degree.get(key, 0) + 1
        endpoints = [(lat / 10_000_000.0, lon / 10_000_000.0) for (lat, lon), count in degree.items() if count == 1]
        groups.append(_Group(kind=ways[indexes[0]].kind, way_indexes=sorted(indexes), endpoints=endpoints))
    return groups


def associate_structures(
    geometry: RouteGeometry,
    ways: Sequence[StructureWay],
    *,
    travel_mode: str = "cycling",
) -> list[StructureSpan]:
    """Return bridge/tunnel spans along the route distance axis."""

    if travel_mode not in TRAVEL_MODES:
        raise ValueError("unsupported travel mode")
    if not ways:
        return []
    cell_degrees = 0.002
    segments_by_cell: dict[tuple[int, int], list[_Segment]] = {}
    margin = MATCH_DISTANCE_M / _METRES_PER_DEGREE
    for way_index, way in enumerate(ways):
        for position in range(len(way.lat_e7) - 1):
            segment = _Segment(way_index, way.latitude(position), way.longitude(position),
                               way.latitude(position + 1), way.longitude(position + 1))
            lat_low, lat_high = sorted((segment.lat0, segment.lat1))
            lon_low, lon_high = sorted((segment.lon0, segment.lon1))
            lon_margin = margin / max(0.01, math.cos(math.radians(lat_low)))
            for lat_cell in range(math.floor((lat_low - margin) / cell_degrees),
                                  math.floor((lat_high + margin) / cell_degrees) + 1):
                for lon_cell in range(math.floor((lon_low - lon_margin) / cell_degrees),
                                      math.floor((lon_high + lon_margin) / cell_degrees) + 1):
                    segments_by_cell.setdefault((lat_cell, lon_cell), []).append(segment)
    probe_count = int(math.floor(geometry.length_m / PROBE_SPACING_M)) + 1
    probe_distances = [index * PROBE_SPACING_M for index in range(probe_count)]
    matches: list[set[int]] = []
    probe_points: list[tuple[float, float]] = []
    for distance in probe_distances:
        lat, lon = geometry.point_at_distance(distance)
        probe_points.append((lat, lon))
        heading = geometry.heading_at_distance(distance)
        matched: set[int] = set()
        cell = (math.floor(lat / cell_degrees), math.floor(lon / cell_degrees))
        for segment in segments_by_cell.get(cell, ()):
            if segment.way_index in matched:
                continue
            distance_m, bearing = _distance_and_bearing(lat, lon, segment)
            if distance_m > MATCH_DISTANCE_M or bearing is None or heading is None:
                continue
            if _undirected_heading_difference(heading, bearing) <= MATCH_HEADING_DEG:
                matched.add(segment.way_index)
        matches.append(matched)
    groups = _group_ways(ways)
    group_of_way = {way_index: group_index for group_index, group in enumerate(groups) for way_index in group.way_indexes}
    raw_spans: list[tuple[int, int, int, str, str | None, tuple[int, ...]]] = []
    for group_index, group in enumerate(groups):
        matched_probes = [
            position for position, matched in enumerate(matches)
            if any(group_of_way[way_index] == group_index for way_index in matched)
        ]
        for run_start, run_end in _runs(matched_probes):
            start_m = probe_distances[run_start]
            end_m = probe_distances[run_end]
            if end_m - start_m < MINIMUM_SPAN_M:
                continue
            traversed = sorted({
                way_index
                for position in range(run_start, run_end + 1)
                for way_index in matches[position]
                if group_of_way[way_index] == group_index
            })
            classification = _classify_run(
                ways, groups, group_index, traversed, matches, probe_points,
                run_start, run_end, start_m, end_m, group_of_way, travel_mode,
            )
            if classification is None:
                continue
            resolution, reason = classification
            raw_spans.append((run_start, run_end, group_index, resolution, reason,
                              tuple(sorted(ways[index].way_id for index in traversed))))
    return _merge_spans(raw_spans, probe_distances, groups)


def _runs(positions: Sequence[int]) -> list[tuple[int, int]]:
    runs: list[tuple[int, int]] = []
    for position in positions:
        if runs and position - runs[-1][1] <= MAXIMUM_MATCH_GAP_PROBES + 1:
            runs[-1] = (runs[-1][0], position)
        else:
            runs.append((position, position))
    return runs


def _near_endpoint(point: tuple[float, float], endpoints: Sequence[tuple[float, float]]) -> int | None:
    for index, (lat, lon) in enumerate(endpoints):
        if haversine_m(point[0], point[1], lat, lon) <= ENDPOINT_TOLERANCE_M:
            return index
    return None


def _classify_run(
    ways: Sequence[StructureWay],
    groups: Sequence[_Group],
    group_index: int,
    traversed: Sequence[int],
    matches: Sequence[set[int]],
    probe_points: Sequence[tuple[float, float]],
    run_start: int,
    run_end: int,
    start_m: float,
    end_m: float,
    group_of_way: dict[int, int],
    travel_mode: str,
) -> tuple[str, str | None] | None:
    group = groups[group_index]
    if travel_mode == "cycling" and not any(ways[index].cyclable for index in traversed):
        explained = sum(
            1
            for position in range(run_start, run_end + 1)
            if any(ways[other].cyclable and ways[other].kind == group.kind for other in matches[position])
        )
        if explained * 2 >= run_end - run_start + 1:
            # A cyclable structure beside this one (for example a bridge
            # sidewalk next to motorway lanes) explains the route; it is
            # associated on its own merits.
            return None
        return STRUCTURE_AMBIGUOUS, "structure-not-usable-by-travel-mode"
    entry = _near_endpoint(probe_points[run_start], group.endpoints)
    exit_ = _near_endpoint(probe_points[run_end], group.endpoints)
    if entry is None or exit_ is None or entry == exit_:
        return STRUCTURE_AMBIGUOUS, "partial-alignment"
    traversed_length = sum(ways[index].length_m() for index in traversed)
    if traversed_length <= 0.0 or (end_m - start_m) < MINIMUM_TRAVERSED_FRACTION * traversed_length:
        return STRUCTURE_AMBIGUOUS, "partial-alignment"
    layers = {ways[index].layer for index in traversed}
    stacked = 0
    for position in range(run_start, run_end + 1):
        for other in matches[position]:
            if group_of_way[other] == group_index:
                continue
            other_way = ways[other]
            if travel_mode == "cycling" and not other_way.cyclable:
                continue
            if other_way.kind != group.kind or other_way.layer not in layers:
                stacked += 1
                break
    # A junction with a differently layered approach touches only a few
    # probes; a parallel structure on another level overlaps a real length.
    probes = run_end - run_start + 1
    if stacked * PROBE_SPACING_M >= STACKED_MINIMUM_OVERLAP_M and stacked * 4 >= probes:
        return STRUCTURE_AMBIGUOUS, "stacked-structures"
    return STRUCTURE_ESTIMATED, None


@dataclass
class _MergedSpan:
    start: int
    end: int
    kind: str
    resolution: str
    reason: str | None
    way_ids: set[int]


def _merge_spans(
    raw_spans: Sequence[tuple[int, int, int, str, str | None, tuple[int, ...]]],
    probe_distances: Sequence[float],
    groups: Sequence[_Group],
) -> list[StructureSpan]:
    """Merge overlapping runs; any ambiguity or mixed kind makes the union ambiguous."""

    merged: list[_MergedSpan] = []
    for run_start, run_end, group_index, resolution, reason, way_ids in sorted(raw_spans, key=lambda item: item[:2]):
        kind = groups[group_index].kind
        if not merged or run_start > merged[-1].end:
            merged.append(_MergedSpan(run_start, run_end, kind, resolution, reason, set(way_ids)))
            continue
        current = merged[-1]
        current.end = max(current.end, run_end)
        current.way_ids.update(way_ids)
        if current.kind != kind:
            current.resolution, current.reason = STRUCTURE_AMBIGUOUS, "stacked-structures"
        elif resolution == STRUCTURE_AMBIGUOUS and current.resolution != STRUCTURE_AMBIGUOUS:
            current.resolution, current.reason = STRUCTURE_AMBIGUOUS, reason
    return [
        StructureSpan(
            kind=span.kind,
            start_m=probe_distances[span.start],
            end_m=probe_distances[span.end],
            resolution=span.resolution,
            way_ids=tuple(sorted(span.way_ids)),
            reason=span.reason,
        )
        for span in merged
    ]


class StructureAnnotator:
    """Selects configured indexes covering a route and reports correction status."""

    def __init__(self, indexes: Sequence[StructureIndex]):
        self._indexes = tuple(indexes)

    @classmethod
    def from_directory(cls, directory: Path | None) -> "StructureAnnotator":
        if directory is None or not directory.is_dir():
            return cls(())
        paths = sorted(path for path in directory.glob("*.sqlite3") if path.is_file() and not path.is_symlink())
        if len(paths) > MAXIMUM_INDEX_FILES:
            raise StructureIndexError("too many structure index files")
        return cls(tuple(StructureIndex(path) for path in paths))

    @property
    def configured(self) -> bool:
        return bool(self._indexes)

    def public_summary(self) -> dict[str, object]:
        return {"indexes": len(self._indexes), "source": "osm-structure-index" if self._indexes else None}

    def annotate(
        self,
        geometry: RouteGeometry,
        *,
        travel_mode: str,
    ) -> tuple[list[StructureSpan], StructureCorrection]:
        if not self._indexes:
            return [], StructureCorrection(status="unavailable", reason="no-structure-index")
        probe_count = int(math.floor(geometry.length_m / PROBE_SPACING_M)) + 1
        covering: list[StructureIndex] = []
        covered = 0
        for index in range(probe_count):
            lat, lon = geometry.point_at_distance(index * PROBE_SPACING_M)
            inside = [candidate for candidate in self._indexes if candidate.contains(lat, lon)]
            if inside:
                covered += 1
            for candidate in inside:
                if candidate not in covering:
                    covering.append(candidate)
        if not covering:
            return [], StructureCorrection(status="unavailable", reason="outside-structure-index-coverage")
        try:
            cells = route_query_cells(geometry)
            ways: dict[int, StructureWay] = {}
            for candidate in covering:
                for way in candidate.query(cells):
                    ways.setdefault(way.way_id, way)
                if len(ways) > MAXIMUM_QUERY_WAYS:
                    raise StructureIndexError("too-many-structures")
        except StructureIndexError as exc:
            reason = "too-many-structures" if str(exc) == "too-many-structures" else "structure-index-error"
            return [], StructureCorrection(status="unavailable", reason=reason)
        spans = associate_structures(geometry, [ways[key] for key in sorted(ways)], travel_mode=travel_mode)
        status = "applied" if covered == probe_count else "partial-coverage"
        return spans, StructureCorrection(
            status=status,
            source="osm-structure-index",
            source_version=";".join(candidate.source_version for candidate in covering),
            attribution=(OSM_ATTRIBUTION,),
            reason=None if status == "applied" else "route-partly-outside-structure-index",
        )
