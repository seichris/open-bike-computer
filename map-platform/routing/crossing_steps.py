#!/usr/bin/env python3
"""Count the false steps a terrain model gives roads where they cross water or leave a bridge or tunnel.

A lidar terrain model such as USGS 3DEP or MRDEM-30 is bare earth: it holds
the ground under a bridge deck, and where a stream runs through a culvert the
model may cut its channel through the road's fill. Valhalla grades a bridge or
tunnel edge from the heights at its two ends and clamps it to 3%, and every
other edge from the terrain sampled every 60 m along it. A bridge end that
lies on a channel bank, or a road over a culvert, then reads a step that the
road does not have.

This tool finds every place where that can happen and measures it:

- `sites` reads an OpenStreetMap extract and writes the sites: every crossing
  of a highway that bikes may use with a waterway, and every bridge and
  tunnel such a highway runs over or through, as the road's line through it.
- `measure` samples elevation tiles along each site's line, as Valhalla does
  (bilinear between posts), and writes what it finds per site. It reads a
  tile directory, or single cells of a set kept in the bucket (see
  builder/elevation_cache.py), checked against the set's cell list.
- `summary` counts false steps by kind of crossing, road class, surface and
  terrain source, and lists the worst.

A site is one of:

- `bridge-water`: a chain of bridge ways from one road end to the other that
  a waterway crosses; `bridge-other`: one that no mapped waterway crosses
  (over a road, a railway or a dry valley);
- `tunnel`: a chain of tunnel ways, portal to portal;
- `culvert`: a road over a waterway tagged as a culvert or otherwise covered;
- `untagged`: a road over a waterway with neither a bridge nor a culvert
  mapped;
- `ford`: a road and a waterway that share a node; the road goes through the
  water, so its dip is real. Fords are listed and never counted.

Its profile is the road from 150 m before the crossing (or the first end of
the bridge or tunnel) to 150 m after it (or after the other end), sampled
every 5 m. A road that ends within those 150 m is followed onto the highway
that continues it most nearly straight. A bridge or tunnel is a straight line
between the heights at its ends, as Valhalla grades it.

The rule is the one of the 2026-11-27 road check, which counted pits on the
first hybrid planet: a site has a **false step** where the road, within 60 m
of the crossing or of a bridge or tunnel end, reads a grade of 30% or more
over 30 m, and reads 20% or less once the low point is bridged. Bridging
replaces the profile within 75 m of the crossing by its upper convex hull: a
straight line from solid ground on one side to solid ground on the other that
never runs below the road. For a tunnel the hump is cut instead (the lower
hull). Windows that lie wholly on a bridge or in a tunnel are not judged,
because Valhalla clamps those edges to 3%.

Valhalla samples every 60 m, so a step may fall between its samples. The
measure also reports the steepest grade over 60 m within the same reach,
which is the worst Valhalla can store there, and a looser **false grade**:
10% or more over 60 m that is 5% or less bridged, at a dip of 3 m or more.

    python crossing_steps.py sites --pbf pennsylvania.osm.pbf --region us-pennsylvania \\
        --area usgs-3dep-13=united-states-conterminous-osm-r148838-v1054.geojson.gz --out sites/pa.npz
    python crossing_steps.py measure --sites sites/*.npz --kept releases/elevation-cache-2026-11-27.json \\
        --set hybrid-400 --token-file TOKEN --out results.json.gz
    python crossing_steps.py summary results.json.gz --out summary.json
"""

import argparse
import gzip
import hashlib
import io
import json
import math
import os
import sys
import tarfile
import time
import urllib.error
import urllib.request
import zlib
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

ROUTING = Path(__file__).resolve().parent
sys.path.insert(0, str(ROUTING))
sys.path.insert(0, str(ROUTING / "builder"))

import build_elevation  # noqa: E402

POSTS = build_elevation.POSTS
NO_DATA = build_elevation.NO_DATA

SITES_SCHEMA = "bicino-crossing-sites-v1"
RESULTS_SCHEMA = "bicino-crossing-steps-v1"

# Along the road on either side of the crossing.
REACH = 150.0
STEP = 5.0
# Grades are judged within this distance of the crossing or of a bridge or tunnel end.
NEAR = 60.0
# The low point is bridged within this distance.
BRIDGE_SPAN = 75.0
WINDOW = 30.0
WIDE_WINDOW = 60.0
STEEP = 0.30
PLAUSIBLE = 0.20
WIDE_STEEP = 0.10
WIDE_PLAUSIBLE = 0.05
WIDE_DIP = 3.0
# A road that ends is followed onto the most nearly straight highway, if it turns by at most this much.
CONTINUE_DEGREES = 60.0
CONTINUE_HOPS = 4
# A bridge or tunnel's approach is the highway that leaves its end most nearly straight, within this.
APPROACH_DEGREES = 95.0
# A bridge or tunnel chain longer than this is not followed further.
LONGEST_CHAIN = 5000.0
# Crossings of one road closer than this are one site.
SAME_SITE = 30.0
NEAR_BRIDGE = 50.0
# Points of other roads within this of a site's reach are kept with it: a fill leaves the posts around them.
GUARD = 65.0

METRES_PER_DEGREE_LATITUDE = 110_574.0
METRES_PER_DEGREE_LONGITUDE = 111_320.0

# Road classes bikes may use, grouped as the road check grouped them.
GROUPS = ("main", "minor", "service", "track", "path")
HIGHWAY_GROUP = {
    "motorway": "main", "motorway_link": "main",
    "trunk": "main", "trunk_link": "main", "primary": "main", "primary_link": "main",
    "secondary": "main", "secondary_link": "main", "tertiary": "main", "tertiary_link": "main",
    "unclassified": "minor", "residential": "minor", "living_street": "minor", "road": "minor",
    "service": "service", "track": "track",
    "cycleway": "path", "path": "path", "bridleway": "path", "pedestrian": "path", "footway": "path",
}
# These carry bikes only when a tag says so, as Valhalla's rules have it.
BIKES_IF_TAGGED = {"motorway", "motorway_link", "footway"}
BIKES_YES = {"yes", "designated", "permissive", "dismount"}
BIKES_NO = {"no", "use_sidepath"}
ACCESS_NO = {"no", "private"}
# Valhalla's tunnel table; a bridge is every value but these (build_graph.py --all-bridges).
TUNNEL_VALUES = {"yes", "1", "building_passage", "avalanche_protector"}
NOT_BRIDGE = {"no", "false", "0"}

WATERWAY_KIND = {
    "river": "river", "stream": "stream", "brook": "stream", "tidal_channel": "stream", "canal": "canal",
    "drain": "drain", "ditch": "drain", "canyon": "stream", "wadi": "stream",
}
WATER_KINDS = ("river", "stream", "canal", "drain")
COVERED_WATER = {"culvert", "yes", "1", "flooded"}

PAVED = {"paved", "asphalt", "concrete", "concrete:plates", "concrete:lanes", "paving_stones", "sett",
         "cobblestone", "unhewn_cobblestone", "metal", "wood", "chipseal", "bricks", "brick", "metal_grid"}
UNPAVED = {"unpaved", "gravel", "fine_gravel", "dirt", "ground", "earth", "grass", "sand", "compacted",
           "mud", "pebblestone", "rock", "woodchips", "grass_paver", "gravel;grass", "dirt/sand", "clay", "salt",
           "snow", "ice", "stepping_stones"}
# Without a surface tag: tracks, paths and bridleways are taken as unpaved, everything else as paved.
UNPAVED_BY_DEFAULT = {"track", "path", "bridleway"}

KINDS = ("bridge-water", "bridge-other", "tunnel", "culvert", "untagged", "ford")
SPAN_NONE, SPAN_BRIDGE, SPAN_TUNNEL = 0, 1, 2


# OpenStreetMap ---------------------------------------------------------------


def bikes_may_use(tags):
    """The road's group if bikes may use it, else None."""
    highway = tags.get("highway")
    group = HIGHWAY_GROUP.get(highway)
    if group is None:
        return None
    bicycle = tags.get("bicycle")
    if bicycle in BIKES_NO:
        return None
    if highway in BIKES_IF_TAGGED and bicycle not in BIKES_YES:
        return None
    if tags.get("access") in ACCESS_NO and bicycle not in BIKES_YES:
        return None
    if tags.get("area") == "yes":
        return None
    return group


def is_bridge(tags):
    value = tags.get("bridge")
    return value is not None and value not in NOT_BRIDGE


def is_tunnel(tags):
    return tags.get("tunnel") in TUNNEL_VALUES


def surface_of(tags):
    surface = tags.get("surface")
    if surface in PAVED:
        return "paved"
    if surface in UNPAVED:
        return "unpaved"
    if surface is not None:
        return "paved" if surface.startswith(("asphalt", "concrete", "paving")) else "unpaved"
    return "unpaved" if tags.get("highway") in UNPAVED_BY_DEFAULT else "paved"


def waterway_of(tags):
    """(kind, covered) of a waterway line, or None."""
    kind = WATERWAY_KIND.get(tags.get("waterway"))
    if kind is None:
        return None
    covered = (tags.get("tunnel") in COVERED_WATER or tags.get("culvert") == "yes" or tags.get("covered") == "yes"
               or tags.get("location") == "underground")
    return kind, covered


class Lines:
    """Ways as flat arrays: node ids, coordinates and the offset of each way's first node."""

    def __init__(self):
        from array import array

        self.nodes, self.lons, self.lats = array("q"), array("d"), array("d")
        self.offsets = array("q", [0])
        self.ids = array("q")
        self.attrs = []

    def add(self, way_id, refs, attrs):
        if len(refs) < 2:
            return
        for ref, lon, lat in refs:
            self.nodes.append(ref)
            self.lons.append(lon)
            self.lats.append(lat)
        self.offsets.append(len(self.nodes))
        self.ids.append(way_id)
        self.attrs.append(attrs)

    def finish(self):
        import numpy as np

        self.nodes = np.frombuffer(self.nodes, dtype=np.int64)
        self.lons = np.frombuffer(self.lons, dtype=np.float64)
        self.lats = np.frombuffer(self.lats, dtype=np.float64)
        self.offsets = np.frombuffer(self.offsets, dtype=np.int64)
        self.ids = np.frombuffer(self.ids, dtype=np.int64)
        return self

    def __len__(self):
        return len(self.ids)

    def coords(self, index):
        start, end = self.offsets[index], self.offsets[index + 1]
        return self.lons[start:end], self.lats[start:end]

    def way_nodes(self, index):
        return self.nodes[self.offsets[index]:self.offsets[index + 1]]


def read_ways(pbf):
    """Highways bikes may use, waterway lines and the nodes tagged as fords, with node locations."""
    import osmium
    import osmium.filter

    roads, waters, fords = Lines(), Lines(), set()
    processor = (osmium.FileProcessor(str(pbf), osmium.osm.NODE | osmium.osm.WAY)
                 .with_locations()
                 .with_filter(osmium.filter.KeyFilter("highway", "waterway", "ford")))
    for item in processor:
        tags = item.tags
        if item.is_node():
            if tags.get("ford") not in (None, "no"):
                fords.add(item.id)
            continue
        refs = []
        for node in item.nodes:
            location = node.location
            if not location.valid():
                refs = None
                break
            refs.append((node.ref, location.lon, location.lat))
        if not refs:
            continue
        if "highway" in tags:
            values = {key: tags.get(key) for key in ("highway", "bicycle", "access", "area", "bridge", "tunnel",
                                                     "surface", "ford", "name", "ref")}
            group = bikes_may_use(values)
            if group is not None:
                roads.add(item.id, refs, {
                    "highway": values["highway"], "group": group, "surface": surface_of(values),
                    "bridge": is_bridge(values), "tunnel": is_tunnel(values),
                    "ford": values["ford"] not in (None, "no"),
                    "name": values["name"] or values["ref"] or "",
                })
        elif "waterway" in tags:
            values = {key: tags.get(key) for key in ("waterway", "tunnel", "culvert", "covered", "location", "name")}
            water = waterway_of(values)
            if water is not None:
                waters.add(item.id, refs, {"kind": water[0], "covered": water[1], "name": values["name"] or ""})
    return roads.finish(), waters.finish(), fords


# Geometry ---------------------------------------------------------------------


def metres(lons, lats, lat0):
    """Local east and north metres of degrees, around latitude lat0."""
    import numpy as np

    scale = METRES_PER_DEGREE_LONGITUDE * math.cos(math.radians(lat0))
    return np.asarray(lons) * scale, np.asarray(lats) * METRES_PER_DEGREE_LATITUDE


class NodeIndex:
    """Which ways hold a node, and where."""

    def __init__(self, lines):
        import numpy as np

        counts = np.diff(lines.offsets)
        self.way = np.repeat(np.arange(len(lines), dtype=np.int64), counts)
        self.position = np.arange(len(lines.nodes), dtype=np.int64) - np.repeat(lines.offsets[:-1], counts)
        order = np.argsort(lines.nodes, kind="stable")
        self.sorted_nodes = lines.nodes[order]
        self.way, self.position = self.way[order], self.position[order]

    def at(self, node):
        import numpy as np

        start = np.searchsorted(self.sorted_nodes, node, side="left")
        end = np.searchsorted(self.sorted_nodes, node, side="right")
        return list(zip(self.way[start:end].tolist(), self.position[start:end].tolist()))


def bearing(x0, y0, x1, y1):
    return math.atan2(x1 - x0, y1 - y0)


def turn(a, b):
    """Absolute difference of two bearings, in degrees."""
    difference = abs(a - b) % (2 * math.pi)
    return math.degrees(min(difference, 2 * math.pi - difference))


class Walker:
    """Follows roads from a point for a distance, onto the most nearly straight highway where a road ends."""

    def __init__(self, roads, index):
        self.roads, self.index = roads, index

    def _vertices(self, way, position, direction):
        """The way's vertices from `position` onwards in `direction`, as (lon, lat, node)."""
        lons, lats = self.roads.coords(way)
        nodes = self.roads.way_nodes(way)
        last = len(lons) - 1
        positions = range(position, last + 1) if direction > 0 else range(position, -1, -1)
        return [(lons[i], lats[i], int(nodes[i])) for i in positions]

    def continuation(self, way, node, heading, lat0, accept=None, widest=CONTINUE_DEGREES):
        """The way and direction leaving `node` most nearly along `heading`, or None."""
        best, best_turn = None, widest
        for other, position in self.index.at(node):
            if other == way:
                continue
            if accept is not None and not accept(other):
                continue
            for direction in (1, -1):
                vertices = self._vertices(other, position, direction)
                if len(vertices) < 2:
                    continue
                x0, y0 = metres(vertices[0][0], vertices[0][1], lat0)
                x1, y1 = metres(vertices[1][0], vertices[1][1], lat0)
                angle = turn(heading, bearing(x0, y0, x1, y1))
                if angle < best_turn:
                    best, best_turn = (other, position, direction), angle
        return best

    def walk(self, start, way, position, direction, length, lat0, accept=None, stop=None):
        """Points from `start` (lon, lat) along the way from vertex `position` onwards.

        Returns the points (the first is `start`), the way of each piece between two points and, when
        `stop` ends the walk at a node, that node's index among the points. `stop(node)` is asked at
        every node passed.
        """
        points, pieces = [start], []
        travelled = 0.0
        hops = 0
        current = (way, position, direction)
        while True:
            way, position, direction = current
            vertices = self._vertices(way, position, direction)
            for lon, lat, node in vertices:
                x0, y0 = metres(points[-1][0], points[-1][1], lat0)
                x1, y1 = metres(lon, lat, lat0)
                piece = math.hypot(x1 - x0, y1 - y0)
                if piece == 0:
                    if stop is not None and len(points) > 1 and stop(node):
                        return points, pieces, len(points) - 1
                    continue
                if travelled + piece >= length:
                    share = (length - travelled) / piece
                    points.append((points[-1][0] + (lon - points[-1][0]) * share,
                                   points[-1][1] + (lat - points[-1][1]) * share))
                    pieces.append(way)
                    return points, pieces, None
                travelled += piece
                points.append((lon, lat))
                pieces.append(way)
                if stop is not None and stop(node):
                    return points, pieces, len(points) - 1
            if hops >= CONTINUE_HOPS:
                return points, pieces, None
            end_node = vertices[-1][2]
            if len(points) >= 2:
                x0, y0 = metres(points[-2][0], points[-2][1], lat0)
                x1, y1 = metres(points[-1][0], points[-1][1], lat0)
            else:
                # The walk started on the way's last node, such as a crossing at a node the stream shares:
                # head on as the way arrives there.
                lons, lats = self.roads.coords(way)
                before = position - direction
                if not 0 <= before < len(lons):
                    return points, pieces, None
                x0, y0 = metres(lons[before], lats[before], lat0)
                x1, y1 = metres(lons[position], lats[position], lat0)
            following = self.continuation(way, end_node, bearing(x0, y0, x1, y1), lat0, accept)
            if following is None:
                return points, pieces, None
            current = following
            hops += 1


def resample(points, step, lat0, pieces=None, roads=None):
    """Points every `step` metres along a polyline from its first point.

    `pieces` are the road indices of the pieces between two points, as Walker.walk gives them. Returns
    lons, lats, whether each point lies on a bridge or in a tunnel (see `interpolated`), and the OSM id
    of the way each point lies on (0 where unknown).
    """
    import numpy as np

    lons = np.array([point[0] for point in points])
    lats = np.array([point[1] for point in points])
    xs, ys = metres(lons, lats, lat0)
    lengths = np.hypot(np.diff(xs), np.diff(ys))
    along = np.concatenate([[0.0], np.cumsum(lengths)])
    marks = np.arange(0.0, float(along[-1]) + 1e-9, step)
    marked = np.zeros(len(marks), dtype=bool)
    ways = np.zeros(len(marks), dtype=np.int64)
    if pieces and len(lengths):
        flags = np.asarray(interpolated(roads, pieces), dtype=bool)
        piece_of = np.clip(np.searchsorted(along, marks, side="right") - 1, 0, len(lengths) - 1)
        marked = flags[piece_of]
        # A point on a node between a flagged piece and an unflagged one is the node: not flagged.
        on_node = np.isin(marks, along) & (marks > 0)
        marked[on_node] &= flags[np.maximum(piece_of - 1, 0)][on_node]
        marked[0] = False
        ways = roads.ids[np.asarray(pieces, dtype=np.int64)][piece_of]
    return np.interp(marks, along, lons), np.interp(marks, along, lats), marked, ways


def chain_length(points, lat0):
    import numpy as np

    lons = np.array([point[0] for point in points])
    lats = np.array([point[1] for point in points])
    xs, ys = metres(lons, lats, lat0)
    return float(np.hypot(np.diff(xs), np.diff(ys)).sum())


# Sites --------------------------------------------------------------------------


class SiteWriter:
    """Sites in arrays: for each, two sides walked outward from its ends and the span between them."""

    def __init__(self):
        self.records = []
        self.side_lons, self.side_lats, self.side_flags, self.side_ways = [], [], [], []
        self.offsets = [0]

    def add(self, record, side_a, side_b):
        import numpy as np

        record["sideA"] = len(self.offsets) - 1
        for lons, lats, flags, ways in (side_a, side_b):
            self.side_lons.append(np.asarray(lons, dtype=np.float64))
            self.side_lats.append(np.asarray(lats, dtype=np.float64))
            self.side_flags.append(np.asarray(flags, dtype=bool))
            self.side_ways.append(np.asarray(ways, dtype=np.int64))
            self.offsets.append(self.offsets[-1] + len(lons))
        self.records.append(record)

    def save(self, path, header):
        import numpy as np

        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        lons = np.concatenate(self.side_lons) if self.side_lons else np.zeros(0)
        lats = np.concatenate(self.side_lats) if self.side_lats else np.zeros(0)
        flags = np.concatenate(self.side_flags) if self.side_flags else np.zeros(0, dtype=bool)
        ways = np.concatenate(self.side_ways) if self.side_ways else np.zeros(0, dtype=np.int64)
        meta = json.dumps({**header, "schema": SITES_SCHEMA, "sites": self.records}).encode()
        temporary = path.with_name(path.name + ".partial")
        with temporary.open("wb") as stream:
            np.savez_compressed(stream, lons=lons, lats=lats, interpolated=flags, ways=ways,
                                offsets=np.asarray(self.offsets, dtype=np.int64),
                                meta=np.frombuffer(gzip.compress(meta, mtime=0), dtype=np.uint8))
        os.replace(temporary, path)


def load_sites(path):
    import numpy as np

    with np.load(path) as data:
        meta = json.loads(gzip.decompress(data["meta"].tobytes()))
        if meta.get("schema") != SITES_SCHEMA:
            raise ValueError(f"{path} is not a {SITES_SCHEMA} file")
        # A file from before the ways were recorded has none: None, not zeros.
        ways = data["ways"] if "ways" in data.files else None
        return meta, data["lons"], data["lats"], data["interpolated"], ways, data["offsets"]


def load_areas(specs):
    """NAME=PATH pairs of gzipped GeoJSON polygon features, in order; the first that holds a site names it."""
    from shapely.geometry import shape
    from shapely.prepared import prep

    areas = []
    for spec in specs:
        name, _, path = spec.partition("=")
        if not path:
            raise SystemExit(f"--area takes NAME=PATH, not {spec!r}")
        feature = json.loads(gzip.decompress(Path(path).read_bytes()))
        geometry = feature["geometry"] if feature.get("type") == "Feature" else feature
        areas.append((name, prep(shape(geometry)), hashlib.sha256(Path(path).read_bytes()).hexdigest()))
    return areas


def area_of(areas, lon, lat):
    from shapely.geometry import Point

    if not areas:
        return ""
    point = Point(lon, lat)
    for name, prepared, _ in areas:
        if prepared.contains(point):
            return name
    return None


def crossing_points(roads, waters):
    """(road, water, lon, lat, shared node or None) for every point where a road meets a waterway line."""
    import numpy as np
    import shapely

    def lines(collection):
        counts = np.diff(collection.offsets)
        coords = np.column_stack([collection.lons, collection.lats])
        return shapely.linestrings(coords, indices=np.repeat(np.arange(len(collection)), counts))

    if not len(roads) or not len(waters):
        return []
    road_lines, water_lines = lines(roads), lines(waters)
    tree = shapely.STRtree(water_lines)
    road_index, water_index = tree.query(road_lines, predicate="intersects")
    meets = shapely.intersection(road_lines[road_index], water_lines[water_index])
    found = []
    for road, water, geometry in zip(road_index.tolist(), water_index.tolist(), meets):
        for part in shapely.get_parts(geometry):
            if shapely.get_type_id(part) != 0:  # a road along a ditch: no crossing point
                continue
            lon, lat = shapely.get_x(part), shapely.get_y(part)
            # A crossing at a node both ways hold lies exactly on that node.
            lons, lats = roads.coords(road)
            shared = None
            for i in np.flatnonzero((lons == lon) & (lats == lat)).tolist():
                node = int(roads.way_nodes(road)[i])
                if node in waters.way_nodes(water):
                    shared = node
                    break
            found.append((road, water, lon, lat, shared))
    return found


def locate(roads, road, lon, lat):
    """The segment of the road nearest the point: (vertex before it, the point on it)."""
    import numpy as np

    lons, lats = roads.coords(road)
    xs, ys = metres(lons, lats, lat)
    px, py = metres(lon, lat, lat)
    dx, dy = np.diff(xs), np.diff(ys)
    lengths = dx * dx + dy * dy
    with np.errstate(invalid="ignore", divide="ignore"):
        t = np.clip(((px - xs[:-1]) * dx + (py - ys[:-1]) * dy) / lengths, 0, 1)
    t = np.nan_to_num(t)
    distance = np.hypot(xs[:-1] + t * dx - px, ys[:-1] + t * dy - py)
    segment = int(np.argmin(distance))
    return segment


def chain_sites(roads, index, walker, flag, span_type, areas):
    """Bridge or tunnel chains: (record, side A, side B, chain ways) per chain, each found once."""
    import numpy as np

    flags = np.array([attrs[flag] for attrs in roads.attrs], dtype=bool)
    if not flags.any():
        return []

    def in_chain(way):
        return bool(flags[way])

    def is_end(node):
        return any(not flags[way] for way, _ in index.at(node))

    seen, chains = set(), []
    for way in np.flatnonzero(flags).tolist():
        nodes = roads.way_nodes(way)
        lons, lats = roads.coords(way)
        for end_position, direction in ((0, 1), (len(nodes) - 1, -1)):
            node = int(nodes[end_position])
            if not is_end(node):
                continue
            lat0 = float(lats[end_position])
            start = (float(lons[end_position]), lat0)
            # Along the chain to its other end.
            chain_points, chain_ways, stopped = walker.walk(start, way, end_position, direction, LONGEST_CHAIN,
                                                             lat0, accept=in_chain, stop=is_end)
            if stopped is None or not chain_ways:
                continue
            far = chain_points[stopped]
            chain_points, chain_ways = chain_points[:stopped + 1], chain_ways[:stopped]
            far_node = _node_at(roads, chain_ways[-1], far)
            key = tuple(sorted((node, far_node)))
            if key in seen:
                continue
            seen.add(key)
            span = chain_length(chain_points, lat0)
            # Outward from each end: the highway that continues the chain most nearly straight.
            sides, zone_ways = [], set(chain_ways)
            for end_point, end_node, heading_points in ((start, node, chain_points[1::-1] if len(chain_points) > 1
                                                         else chain_points),
                                                        (far, far_node, chain_points[-2:])):
                x0, y0 = metres(heading_points[0][0], heading_points[0][1], lat0)
                x1, y1 = metres(heading_points[-1][0], heading_points[-1][1], lat0)
                following = walker.continuation(-1, end_node, bearing(x0, y0, x1, y1), lat0,
                                                accept=lambda other: not flags[other], widest=APPROACH_DEGREES)
                if following is None:
                    sides.append(([end_point[0]], [end_point[1]], [False], [roads.ids[chain_ways[0]]]))
                    continue
                other, position, other_direction = following
                points, pieces, _ = walker.walk(end_point, other, position, other_direction, REACH, lat0)
                sides.append(resample(points, STEP, lat0, pieces, roads))
                zone_ways.update(pieces)
            area = area_of(areas, *start)
            if area is None:
                continue
            first = chain_ways[0]
            record = {
                "kind": "tunnel" if span_type == SPAN_TUNNEL else "bridge",
                "span": span_type, "spanLength": round(span, 1),
                "lon": round(start[0], 7), "lat": round(start[1], 7),
                "farLon": round(far[0], 7), "farLat": round(far[1], 7),
                "way": int(roads.ids[first]), "ways": [int(roads.ids[w]) for w in dict.fromkeys(chain_ways)],
                "nodes": list(key),
                "highway": roads.attrs[first]["highway"], "group": roads.attrs[first]["group"],
                "surface": roads.attrs[first]["surface"], "name": roads.attrs[first]["name"],
                "area": area,
            }
            chains.append((record, sides[0], sides[1], set(chain_ways), zone_ways))
    return chains


def interpolated(roads, pieces):
    """Whether Valhalla grades each piece from its ends: on a bridge or in a tunnel."""
    return [roads.attrs[way]["bridge"] or roads.attrs[way]["tunnel"] for way in pieces]


def _node_at(roads, way, point):
    lons, lats = roads.coords(way)
    nodes = roads.way_nodes(way)
    for i in range(len(nodes)):
        if abs(lons[i] - point[0]) < 1e-9 and abs(lats[i] - point[1]) < 1e-9:
            return int(nodes[i])
    raise ValueError("a chain ended between nodes")


def find_sites(roads, waters, fords, areas, log=print):
    """Every site of one extract: (record, side A, side B)."""
    import numpy as np

    index = NodeIndex(roads)
    walker = Walker(roads, index)
    sites = []

    bridges = chain_sites(roads, index, walker, "bridge", SPAN_BRIDGE, areas)
    tunnels = chain_sites(roads, index, walker, "tunnel", SPAN_TUNNEL, areas)
    log(f"  {len(bridges)} bridge chains, {len(tunnels)} tunnel chains")

    meets = crossing_points(roads, waters)
    log(f"  {len(meets)} points where a road meets a waterway")
    watered = set()
    by_road = {}
    for road, water, lon, lat, shared in meets:
        attrs = roads.attrs[road]
        if attrs["bridge"]:
            watered.add(road)
            continue
        if attrs["tunnel"]:
            continue
        by_road.setdefault(road, []).append((lon, lat, water, shared))

    bridge_ends = []
    for record, side_a, side_b, chain, zone_ways in bridges:
        record["kind"] = "bridge-water" if chain & watered else "bridge-other"
        sites.append((record, side_a, side_b, zone_ways))
        bridge_ends.append((record["lon"], record["lat"]))
        bridge_ends.append((record["farLon"], record["farLat"]))
    for record, side_a, side_b, _, zone_ways in tunnels:
        sites.append((record, side_a, side_b, zone_ways))
    ends = np.array(bridge_ends) if bridge_ends else np.zeros((0, 2))

    # A stream that crosses where two ways of a road meet crosses both at their shared end: one site.
    placed_at = {}
    for road, points in by_road.items():
        attrs = roads.attrs[road]
        # One site per stretch of SAME_SITE metres: a stream mapped twice, or a river and its side channel.
        groups = []
        for point in sorted(points, key=lambda p: (p[0], p[1])):
            x, y = metres(point[0], point[1], point[1])
            for gx, gy, items in groups:
                if math.hypot(x - gx, y - gy) < SAME_SITE:
                    items.append(point)
                    break
            else:
                groups.append((x, y, [point]))
        for _, _, items in groups:
            lon, lat = items[0][0], items[0][1]
            spot = (round(lon, 6), round(lat, 6))
            if any(np.intersect1d(roads.way_nodes(other), roads.way_nodes(road)).size
                   for other in placed_at.get(spot, ())):
                continue
            placed_at.setdefault(spot, []).append(road)
            area = area_of(areas, lon, lat)
            if area is None:
                continue
            water_attrs = [waters.attrs[water] for _, _, water, _ in items]
            joined = [shared for *_, shared in items if shared is not None]
            if attrs["ford"] or any(node in fords for node in joined):
                kind = "ford"
            elif any(water["covered"] for water in water_attrs):
                kind = "culvert"
            else:
                kind = "untagged"
            water_kind = min((water["kind"] for water in water_attrs), key=WATER_KINDS.index)
            segment = locate(roads, road, lon, lat)
            start = (lon, lat)
            backward, backward_pieces, _ = walker.walk(start, road, segment, -1, REACH, lat)
            forward, forward_pieces, _ = walker.walk(start, road, segment + 1, 1, REACH, lat)
            near_bridge = None
            if len(ends):
                ex, ey = metres(ends[:, 0], ends[:, 1], lat)
                x, y = metres(lon, lat, lat)
                distance = float(np.min(np.hypot(ex - x, ey - y)))
                near_bridge = round(distance, 1) if distance <= NEAR_BRIDGE else None
            record = {
                "kind": kind, "span": SPAN_NONE, "spanLength": 0.0,
                "lon": round(lon, 7), "lat": round(lat, 7),
                "way": int(roads.ids[road]), "ways": [int(roads.ids[road])],
                "water": [int(waters.ids[water]) for _, _, water, _ in items], "waterKind": water_kind,
                "waterName": next((water["name"] for water in water_attrs if water["name"]), ""),
                "joined": bool(joined),
                "highway": attrs["highway"], "group": attrs["group"], "surface": attrs["surface"],
                "name": attrs["name"], "area": area, "nearBridge": near_bridge,
            }
            sites.append((record, resample(backward, STEP, lat, backward_pieces, roads),
                          resample(forward, STEP, lat, forward_pieces, roads),
                          {road, *backward_pieces, *forward_pieces}))
    protect(roads, sites)
    return sites


def protect(roads, sites):
    """Give every site the points of other roads that cross its reach without joining it.

    A road that passes under a bridge's end, or through a culvert, crosses the site's line at another
    level and shares no node with the site's roads there. Its points near the reach are kept with the
    site, so that a fill of the site's low point leaves the posts around them alone (crossing_fill.py).
    """
    import numpy as np
    import shapely

    if not sites:
        return
    counts = np.diff(roads.offsets)
    coords = np.column_stack([roads.lons, roads.lats])
    lines = shapely.linestrings(coords, indices=np.repeat(np.arange(len(roads)), counts))
    tree = shapely.STRtree(lines)
    reach = int(BRIDGE_SPAN / STEP) + 1
    for site in sites:
        record, side_a, side_b, zone_ways = site
        record["protected"] = []
        if record["kind"] in ("ford", "tunnel"):
            continue
        lons = np.concatenate([np.asarray(side_a[0][:reach]), np.asarray(side_b[0][:reach])])
        lats = np.concatenate([np.asarray(side_a[1][:reach]), np.asarray(side_b[1][:reach])])
        lat0 = float(lats[0])
        margin_lat = GUARD / METRES_PER_DEGREE_LATITUDE
        margin_lon = GUARD / (METRES_PER_DEGREE_LONGITUDE * math.cos(math.radians(lat0)))
        box = shapely.box(lons.min() - margin_lon, lats.min() - margin_lat, lons.max() + margin_lon,
                          lats.max() + margin_lat)
        own_nodes = np.unique(np.concatenate([roads.way_nodes(way) for way in zone_ways]))
        xs, ys = metres(lons, lats, lat0)
        # The site's line: side A in, across the span, side B out.
        reach_line = shapely.linestrings(np.column_stack([np.concatenate([np.asarray(side_a[0][:reach])[::-1],
                                                                          np.asarray(side_b[0][:reach])]),
                                                          np.concatenate([np.asarray(side_a[1][:reach])[::-1],
                                                                          np.asarray(side_b[1][:reach])])]))
        for other in tree.query(box).tolist():
            # Only a road that crosses the site's line without a node of its own there is at another level;
            # one alongside, such as a side path, lies on the same fill or deck.
            if other in zone_ways or np.isin(roads.way_nodes(other), own_nodes).any():
                continue
            if not shapely.intersects(lines[other], reach_line):
                continue
            olons, olats = roads.coords(other)
            points = list(zip(olons.tolist(), olats.tolist()))
            plons, plats, _, _ = resample(points, STEP, lat0)
            px, py = metres(plons, plats, lat0)
            distance = np.min(np.hypot(px[:, None] - xs[None, :], py[:, None] - ys[None, :]), axis=1)
            near = distance <= GUARD
            record["protected"].extend([[round(lon, 7), round(lat, 7)] for lon, lat in
                                        zip(plons[near].tolist(), plats[near].tolist())])


def write_sites(pbf, region, areas, out, log=print):
    started = time.monotonic()
    roads, waters, fords = read_ways(pbf)
    log(f"{region}: {len(roads)} roads bikes may use, {len(waters)} waterways "
        f"({time.monotonic() - started:.0f} s)")
    sites = find_sites(roads, waters, fords, areas, log)
    writer = SiteWriter()
    for record, side_a, side_b, _ in sites:
        record["region"] = region
        writer.add(record, side_a, side_b)
    data = Path(pbf).read_bytes() if Path(pbf).stat().st_size < (64 << 20) else None
    header = {
        "region": region, "source": Path(pbf).name,
        "sourceSha256": hashlib.sha256(data).hexdigest() if data is not None else _file_sha256(pbf),
        "areas": [{"name": name, "sha256": sha} for name, _, sha in areas],
        "rule": rule(),
    }
    writer.save(out, header)
    counts = {}
    for record, _, _, _ in sites:
        counts[record["kind"]] = counts.get(record["kind"], 0) + 1
    log(f"{region}: {len(sites)} sites {counts} ({time.monotonic() - started:.0f} s)")
    return counts


def _file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        while chunk := stream.read(1 << 22):
            digest.update(chunk)
    return digest.hexdigest()


def rule():
    return {
        "reachMetres": REACH, "stepMetres": STEP, "nearMetres": NEAR, "bridgeSpanMetres": BRIDGE_SPAN,
        "windowMetres": WINDOW, "steep": STEEP, "plausible": PLAUSIBLE,
        "wideWindowMetres": WIDE_WINDOW, "wideSteep": WIDE_STEEP, "widePlausible": WIDE_PLAUSIBLE,
        "wideDipMetres": WIDE_DIP, "sameSiteMetres": SAME_SITE,
    }


# Heights ------------------------------------------------------------------------


def sample_posts(posts, cell, lons, lats):
    """Bilinear heights at the points, as Valhalla's sampler gives them; NaN where it has no data."""
    import numpy as np

    longitude, latitude = cell
    u = (np.asarray(lons) - longitude) * (POSTS - 1)
    v = (1.0 - (np.asarray(lats) - latitude)) * (POSTS - 1)
    x = np.clip(np.floor(u).astype(np.int64), 0, POSTS - 1)
    y = np.clip(np.floor(v).astype(np.int64), 0, POSTS - 1)
    u_ratio, v_ratio = u - x, v - y
    x1, y1 = np.minimum(x + 1, POSTS - 1), np.minimum(y + 1, POSTS - 1)
    corners = ((y, x, (1 - u_ratio) * (1 - v_ratio)), (y, x1, u_ratio * (1 - v_ratio)),
               (y1, x, (1 - u_ratio) * v_ratio), (y1, x1, u_ratio * v_ratio))
    value = np.zeros(len(u))
    weight = np.zeros(len(u))
    for rows, columns, coefficient in corners:
        heights = posts[rows, columns]
        valid = ~np.isnan(heights)
        value += np.where(valid, heights, 0) * coefficient
        weight += np.where(valid, coefficient, 0)
    with np.errstate(invalid="ignore", divide="ignore"):
        return np.where(weight > 0, value / np.where(weight > 0, weight, 1), np.nan)


class KeptSet:
    """Single cells of a tile set kept in the bucket, fetched by byte range and checked against cells.txt."""

    def __init__(self, record_path, name, token_file, meta_tar, endpoint=None, token_command=None):
        import elevation_cache

        self.token_command = token_command

        record = json.loads(Path(record_path).read_text())
        sets = {**record.get("sets", {}), **record.get("terrainSets", {})}
        entry = sets[name]
        self.bucket, self.prefix = record["bucket"], entry["prefix"]
        self.endpoint = endpoint or elevation_cache.GOOGLE
        self.token_file = token_file
        data = Path(meta_tar).read_bytes()
        meta = next(shard for shard in entry["shards"] if shard["name"] == "meta.tar")
        if hashlib.sha256(data).hexdigest() != meta["sha256"]:
            raise ValueError(f"{meta_tar} is not the meta.tar the record pins")
        sizes, listing, manifest = {}, None, None
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            for member in archive:
                if member.name == "cells.txt":
                    listing = archive.extractfile(member).read()
                elif member.name == "elevation-manifest.json":
                    manifest = archive.extractfile(member).read()
                elif member.name.startswith("receipts/"):
                    receipt = json.loads(archive.extractfile(member).read())
                    sizes[receipt["cell"]] = receipt["fileBytes"]
        if hashlib.sha256(listing).hexdigest() != entry["cellListSha256"]:
            raise ValueError("cells.txt is not the cell list the record pins")
        if hashlib.sha256(manifest).hexdigest() != entry["manifestSha256"]:
            raise ValueError("elevation-manifest.json is not the manifest the record pins")
        self.manifest = json.loads(manifest)
        self.name = name
        self.cells = elevation_cache.parse_cells(listing, name)
        self.offsets = {}
        for shard in entry["shards"]:
            band = shard["name"][:-len(".tar")]
            if band == "meta":
                continue
            offset = 0
            for cell in sorted(cell for cell in self.cells if cell[:2] == band):
                self.offsets[cell] = (shard["name"], offset, sizes[cell])
                offset += 512 + (sizes[cell] + 511) // 512 * 512

    def token(self, refused=None):
        """The bearer token in the token file; when `refused` is the one in it, made anew by --token-command."""
        if not self.token_file:
            return None
        value = Path(self.token_file).read_text().strip()
        if refused is not None and value == refused and self.token_command:
            import shlex
            import subprocess

            made = subprocess.run(shlex.split(self.token_command), capture_output=True, text=True, check=True)
            temporary = Path(f"{self.token_file}.{os.getpid()}")
            temporary.touch(mode=0o600)
            temporary.write_text(made.stdout.strip() + "\n")
            os.replace(temporary, self.token_file)
            value = made.stdout.strip()
        return value

    def read(self, shard, start, end, attempts=6):
        """Bytes start to end (inclusive) of one of the set's tars."""
        import elevation_cache

        url = elevation_cache.object_url(self.endpoint, self.bucket, self.prefix + shard)
        token = self.token()
        for attempt in range(1, attempts + 1):
            headers = {"Range": f"bytes={start}-{end}"}
            if token:
                headers["Authorization"] = f"Bearer {token}"
            try:
                with elevation_cache._OPENER.open(urllib.request.Request(url, headers=headers),
                                                  timeout=120) as response:
                    return response.read()
            except urllib.error.HTTPError as error:
                error.close()
                if error.code == 401 and attempt < attempts:
                    token = self.token(refused=token)
                    continue
                if attempt == attempts or error.code in (403, 404):
                    raise RuntimeError(f"{shard}: HTTP {error.code}") from None
            except OSError as error:
                if attempt == attempts:
                    raise RuntimeError(f"{shard}: {error}") from None
            time.sleep(min(30, 2 ** attempt))

    def fetch(self, cell):
        """The cell's posts as float32 with NaN for no data, or None where the set has no tile."""
        import numpy as np

        if cell not in self.offsets:
            return None
        shard, offset, size = self.offsets[cell]
        data = self.read(shard, offset, offset + 512 + size - 1)
        header = tarfile.TarInfo.frombuf(data[:512], "utf-8", "surrogateescape")
        if header.name != f"{cell[:3]}/{cell}.hgt.gz" or header.size != size or len(data) != 512 + size:
            raise RuntimeError(f"{cell}: the bytes at its offset are {header.name!r}, not its tile")
        payload = zlib.decompress(data[512:], wbits=31)
        if hashlib.sha256(payload).hexdigest() != self.cells[cell]:
            raise RuntimeError(f"{cell}: the tile does not match its line in cells.txt")
        posts = np.frombuffer(payload, dtype=">i2").reshape(POSTS, POSTS).astype("float32")
        posts[posts == NO_DATA] = np.nan
        return posts


class TileDirectory:
    def __init__(self, directory):
        self.directory = Path(directory)

    def fetch(self, cell):
        path = self.directory / cell[:3] / f"{cell}.hgt.gz"
        if not path.exists():
            path = self.directory / cell[:3] / f"{cell}.hgt"
            if not path.exists():
                return None
            import numpy as np

            posts = np.fromfile(path, dtype=">i2").reshape(POSTS, POSTS).astype("float32")
            posts[posts == NO_DATA] = np.nan
            return posts
        return build_elevation.read_tile(path)[0]


_SOURCE = None


def _init_worker(source):
    global _SOURCE
    _SOURCE = source


def _sample_cell(job):
    cell, lons, lats = job
    posts = _SOURCE.fetch(cell)
    if posts is None:
        import numpy as np

        return cell, np.full(len(lons), np.nan), False
    return cell, sample_posts(posts, build_elevation.cell_of(cell), lons, lats), True


def sample_heights(source, lons, lats, jobs=6, log=print):
    """Heights at every point, each cell's tile read once."""
    import numpy as np

    lons, lats = np.asarray(lons), np.asarray(lats)
    heights = np.full(len(lons), np.nan)
    cell_x = np.floor(lons).astype(np.int64)
    cell_y = np.floor(lats).astype(np.int64)
    keys = (cell_y + 90) * 360 + (cell_x + 180)
    order = np.argsort(keys, kind="stable")
    sorted_keys = keys[order]
    boundaries = np.flatnonzero(np.diff(sorted_keys)) + 1
    groups = np.split(order, boundaries)
    work = []
    for group in groups:
        if not len(group):
            continue
        key = int(keys[group[0]])
        cell = build_elevation.hgt_name(key % 360 - 180, key // 360 - 90)
        work.append((cell, group))
    started, done, missing = time.monotonic(), 0, []

    def take(group, result):
        nonlocal done
        cell, values, present = result
        heights[group] = values
        done += 1
        if not present:
            missing.append(cell)
        if done % 25 == 0 or done == len(work):
            log(f"  {done}/{len(work)} cells sampled ({time.monotonic() - started:.0f} s)")

    if jobs <= 1:
        _init_worker(source)
        for cell, group in work:
            take(group, _sample_cell((cell, lons[group], lats[group])))
        return heights, sorted(missing)
    with ProcessPoolExecutor(max_workers=jobs, initializer=_init_worker, initargs=(source,)) as pool:
        futures = {pool.submit(_sample_cell, (cell, lons[group], lats[group])): group for cell, group in work}
        for future in as_completed(futures):
            take(futures[future], future.result())
    return heights, sorted(missing)


def restore_sample(source, bounds, out, log=print):
    """The kept set's cells inside `bounds` as a sample elevation directory, as build_graph.py --sample takes."""
    from sample_elevation import cells_in, write_hgt, write_manifest

    out = Path(out)
    out.mkdir(parents=True)
    entries = []
    for cell in cells_in(bounds):
        name = build_elevation.hgt_name(*cell)
        posts = source.fetch(name)
        if posts is None:
            log(f"{name}: not in the set")
            continue
        entry = write_hgt(out, cell, posts)
        if entry["hgtSha256"] != source.cells[name]:
            raise ValueError(f"{name} did not come out as cells.txt has it")
        entries.append(entry)
        log(f"{name}: restored")
    sources = [{key: value for key, value in item.items() if key != "cells"}
               for item in source.manifest["sources"] if item.get("cells")]
    method = {**source.manifest["method"], "kept": {"set": source.name, "prefix": source.prefix}}
    return write_manifest(out, method, sources, entries, bounds)


# Measure ------------------------------------------------------------------------


def bridge_runs(heights, flags):
    """Heights with every run of flagged points made the straight line between the points around it,
    as Valhalla grades a bridge or tunnel from its ends; a run that reaches the end has no height."""
    import numpy as np

    heights = np.array(heights, dtype=float)
    flags = np.asarray(flags, dtype=bool)
    i = 0
    while i < len(flags):
        if not flags[i]:
            i += 1
            continue
        j = i
        while j < len(flags) and flags[j]:
            j += 1
        if i == 0 or j == len(flags):
            heights[i:j] = np.nan
        else:
            heights[i:j] = np.interp(np.arange(i, j), [i - 1, j], [heights[i - 1], heights[j]])
        i = j
    return heights


def profile(side_a, side_b, span_length, flags_a=None, flags_b=None):
    """The site's profile every STEP metres: side A reversed, the span, side B.

    `side_a` and `side_b` are heights every STEP metres outward from the two ends, the first at the end
    itself. The span between the ends, and any bridge or tunnel on a side, is the straight line between
    the heights around it. Returns (positions, heights, interpolated), position 0 at the first end.
    """
    import numpy as np

    if flags_a is not None:
        side_a = bridge_runs(side_a, flags_a)
    if flags_b is not None:
        side_b = bridge_runs(side_b, flags_b)
    flags_a = np.zeros(len(side_a), bool) if flags_a is None else np.asarray(flags_a, bool)
    flags_b = np.zeros(len(side_b), bool) if flags_b is None else np.asarray(flags_b, bool)
    positions = np.concatenate([-STEP * np.arange(len(side_a))[::-1], span_length + STEP * np.arange(len(side_b))])
    heights = np.concatenate([np.asarray(side_a, float)[::-1], np.asarray(side_b, float)])
    marked = np.concatenate([flags_a[::-1], flags_b]).astype(float)
    if span_length > 0:
        # The span's two ends are graph nodes, sampled; only the points between them are interpolated.
        marked[len(side_a) - 1] = marked[len(side_a)] = 0.5
    grid = np.arange(positions[0], positions[-1] + 1e-9, STEP)
    grid_heights = np.interp(grid, positions, heights)
    nan_at = np.isnan(heights)
    if nan_at.any():
        # np.interp spreads a NaN neighbour; keep a grid point only where both points around it have height.
        right = np.clip(np.searchsorted(positions, grid, side="right"), 0, len(positions) - 1)
        left = np.clip(right - 1, 0, len(positions) - 1)
        grid_heights[nan_at[left] | nan_at[right]] = np.nan
    grid_marked = np.interp(grid, positions, marked) > 0.5 if span_length > 0 else (
        np.interp(grid, positions, marked) > 0.5)
    if span_length > 0:
        grid_marked |= (grid > 0) & (grid < span_length)
    return grid, grid_heights, grid_marked


def hull(positions, heights, upper=True):
    """The upper (or lower) convex hull of the points, evaluated at every position."""
    import numpy as np

    sign = 1 if upper else -1
    kept = []
    for i in range(len(positions)):
        while len(kept) >= 2:
            a, b = kept[-2], kept[-1]
            cross = ((positions[b] - positions[a]) * (heights[i] - heights[a])
                     - (heights[b] - heights[a]) * (positions[i] - positions[a]))
            if sign * cross >= 0:
                kept.pop()
            else:
                break
        kept.append(i)
    return np.interp(positions, positions[kept], heights[kept])


def steepest(positions, heights, marked, low, high, window):
    """The steepest grade over `window` metres among windows whose middle lies in [low, high] and that
    do not lie wholly on a bridge or in a tunnel, or None where no such window has heights."""
    import numpy as np

    steps = int(round(window / STEP))
    if len(positions) <= steps:
        return None
    starts = np.arange(len(positions) - steps)
    middles = positions[starts] + window / 2
    flagged = np.concatenate([[0], np.cumsum(marked)])
    wholly = flagged[starts + steps + 1] - flagged[starts] == steps + 1
    grades = (heights[starts + steps] - heights[starts]) / window
    usable = (middles >= low - 1e-9) & (middles <= high + 1e-9) & ~wholly & ~np.isnan(grades)
    if not usable.any():
        return None
    return float(np.max(np.abs(grades[usable])))


def measure_site(record, side_a, side_b, flags_a=None, flags_b=None, bridge_span=BRIDGE_SPAN):
    """What one site reads, as is and with its low point bridged (or its hump cut, for a tunnel)
    within `bridge_span` metres of the crossing or of the bridge's ends."""
    import numpy as np

    span_length = record["spanLength"]
    if np.isnan(side_a[0]) or np.isnan(side_b[0]):
        return {"measured": False, "why": "no height at the crossing"}
    positions, heights, marked = profile(side_a, side_b, span_length, flags_a, flags_b)
    near_low, near_high = -NEAR, span_length + NEAR
    near = (positions >= near_low - WIDE_WINDOW / 2) & (positions <= near_high + WIDE_WINDOW / 2)
    if np.isnan(heights[near]).any():
        return {"measured": False, "why": "no data near the crossing"}
    truncated = positions[0] > near_low - WIDE_WINDOW / 2 or positions[-1] < near_high + WIDE_WINDOW / 2
    zone = (positions >= -bridge_span) & (positions <= span_length + bridge_span) & ~np.isnan(heights)
    fixed = heights.copy()
    fixed[zone] = hull(positions[zone], heights[zone], upper=record["span"] != SPAN_TUNNEL)
    as_is = steepest(positions, heights, marked, near_low, near_high, WINDOW)
    if as_is is None:
        return {"measured": False, "why": "the road is too short"}
    bridged = steepest(positions, fixed, marked, near_low, near_high, WINDOW) or 0.0
    as_is_wide = steepest(positions, heights, marked, near_low, near_high, WIDE_WINDOW) or 0.0
    bridged_wide = steepest(positions, fixed, marked, near_low, near_high, WIDE_WINDOW) or 0.0
    depth = float(np.nanmax(np.abs(fixed - heights)))
    result = {
        "measured": True, "truncated": bool(truncated),
        "grade": round(as_is, 4), "bridgedGrade": round(bridged, 4),
        "grade60": round(as_is_wide, 4), "bridgedGrade60": round(bridged_wide, 4),
        "dip": round(depth, 2),
        "height": round(float(np.interp(0.0, positions, heights)), 1),
    }
    result["falseStep"] = record["kind"] != "ford" and as_is >= STEEP and bridged <= PLAUSIBLE
    result["falseGrade"] = (record["kind"] != "ford" and as_is_wide >= WIDE_STEEP
                            and bridged_wide <= WIDE_PLAUSIBLE and depth >= WIDE_DIP)
    return result


# Which sites a fix lifts -------------------------------------------------------

FIX_KINDS = ("bridge-water", "bridge-other", "culvert", "untagged")
# A site is fixed where its road reads a false step, or where it reads at least FIX_STEEP over 30 m, at most
# FIX_PLAUSIBLE once bridged within its reach and at least FIX_DROP less; in both cases the line must lift
# it by at least FIX_DIP somewhere.
FIX_STEEP = 0.12
FIX_PLAUSIBLE = PLAUSIBLE
FIX_DROP = 0.08
FIX_DIP = 2.0
# How far from a bridge's ends, or from a crossing without one, the line may reach for a site that is no
# false step. A channel the terrain cuts through a road's fill reads in posts one arc-second apart, about
# 30 m, on either side of it, and a real valley is wider; a bridge's abutments and approach fills reach
# further. A false step, 30% or more, is no road's grade, and its line reaches BRIDGE_SPAN everywhere.
BRIDGE_REACH = BRIDGE_SPAN
CROSSING_REACH = 45.0
# A point the line lifts by less than this is on solid ground.
LIFT = 0.3


def reach_of(record):
    """How far the bridging line may reach from the crossing, or from a bridge's ends, short of a false step."""
    return BRIDGE_REACH if record["span"] != SPAN_NONE else CROSSING_REACH


def selected(measured, steep=FIX_STEEP, plausible=FIX_PLAUSIBLE, drop=FIX_DROP, dip=FIX_DIP):
    """Whether a site's measure, bridged within its reach, calls for a fix short of a false step."""
    return (measured.get("measured", False) and measured["grade"] >= steep and measured["bridgedGrade"] <= plausible
            and measured["grade"] - measured["bridgedGrade"] >= drop and measured["dip"] >= dip)


def fix_reach(record, side_a, side_b, flags_a=None, flags_b=None, steep=FIX_STEEP, plausible=FIX_PLAUSIBLE,
              dip=FIX_DIP, drop=FIX_DROP):
    """(reach, measure) of a site a fix lifts, or None: a false step within BRIDGE_SPAN, else `selected`
    within the site's own reach."""
    if record["kind"] not in FIX_KINDS:
        return None
    wide = measure_site(record, side_a, side_b, flags_a, flags_b, bridge_span=BRIDGE_SPAN)
    if wide.get("falseStep") and wide["dip"] >= dip:
        return BRIDGE_SPAN, wide
    reach = reach_of(record)
    own = wide if reach == BRIDGE_SPAN else measure_site(record, side_a, side_b, flags_a, flags_b,
                                                         bridge_span=reach)
    return (reach, own) if selected(own, steep, plausible, drop, dip) else None


def site_lift(record, side_a, side_b, flags_a, flags_b, steep=FIX_STEEP, plausible=FIX_PLAUSIBLE, dip=FIX_DIP,
              drop=FIX_DROP):
    """The heights the road should have at each point of its two sides, or None when the site stays.

    Returns (lift_a, lift_b, measured): the line's height at each side point where it lifts the road by
    more than LIFT, NaN elsewhere, and the site's measure, bridged within the reach used, before the fix.
    """
    import numpy as np

    chosen = fix_reach(record, side_a, side_b, flags_a, flags_b, steep, plausible, dip, drop)
    if chosen is None:
        return None
    reach, measured = chosen
    span = record["spanLength"]
    positions, heights, _ = profile(side_a, side_b, span, flags_a, flags_b)
    zone = (positions >= -reach) & (positions <= span + reach) & ~np.isnan(heights)
    line = heights.copy()
    line[zone] = hull(positions[zone], heights[zone])
    lifts = []
    for side, flags, place in ((side_a, flags_a, -STEP * np.arange(len(side_a))),
                               (side_b, flags_b, span + STEP * np.arange(len(side_b)))):
        side = np.asarray(side, dtype=float)
        target = np.interp(place, positions, line)
        inside = (place >= -reach) & (place <= span + reach)
        lifted = inside & ~np.asarray(flags, dtype=bool) & (target - side > LIFT)
        lifts.append(np.where(lifted, target, np.nan))
    return lifts[0], lifts[1], measured


def measure(site_files, source, out, jobs=6, log=print):
    import numpy as np

    loaded = []
    point_lons, point_lats, point_flags = [], [], []
    total = 0
    for path in site_files:
        meta, lons, lats, flags, _, offsets = load_sites(path)
        loaded.append((path, meta, offsets, total))
        point_flags.append(flags)
        point_lons.append(lons)
        point_lats.append(lats)
        total += len(lons)
    lons, lats = np.concatenate(point_lons), np.concatenate(point_lats)
    flags = np.concatenate(point_flags)
    log(f"{sum(len(m['sites']) for _, m, _, _ in loaded)} sites, {len(lons)} points")
    heights, missing = sample_heights(source, lons, lats, jobs=jobs, log=log)
    seen, results, duplicates = set(), [], 0
    for path, meta, offsets, base in loaded:
        for record in meta["sites"]:
            key = site_key(record)
            if key in seen:
                duplicates += 1
                continue
            seen.add(key)
            side = record["sideA"]
            a = slice(base + offsets[side], base + offsets[side + 1])
            b = slice(base + offsets[side + 1], base + offsets[side + 2])
            entry = {key_: value for key_, value in record.items() if key_ != "sideA"}
            entry.update(measure_site(record, heights[a], heights[b], flags[a], flags[b]))
            if entry["measured"] and record["kind"] in FIX_KINDS:
                entry["fix"] = fix_reach(record, heights[a], heights[b], flags[a], flags[b]) is not None
            results.append(entry)
    document = {"schema": RESULTS_SCHEMA, "rule": rule(), "missingCells": missing, "duplicates": duplicates,
                "regions": [{"file": Path(path).name, "region": meta["region"], "source": meta["source"],
                             "sourceSha256": meta["sourceSha256"], "sites": len(meta["sites"])}
                            for path, meta, _, _ in loaded],
                "sites": results}
    data = json.dumps(document, separators=(",", ":")).encode()
    Path(out).write_bytes(gzip.compress(data, mtime=0) if str(out).endswith(".gz") else data)
    log(f"{len(results)} sites measured into {out} ({duplicates} found twice across extracts)")
    return document


def site_key(record):
    if record["span"] != SPAN_NONE:
        return ("chain", record["span"], *record["nodes"])
    return ("crossing", record["way"], round(record["lon"], 5), round(record["lat"], 5))


# What the router stores ---------------------------------------------------------


STORED_ATTRIBUTES = ["edge.way_id", "edge.length", "edge.weighted_grade", "edge.max_upward_grade",
                     "edge.max_downward_grade", "edge.bridge", "edge.tunnel", "matched.edge_index",
                     "matched.type"]


def site_shape(record, side_a, side_b):
    """The site's road as points: side A in, the span as a straight line, side B out; and each point's
    position along the site (0 at the first end)."""
    import numpy as np

    lons_a, lats_a = np.asarray(side_a[0])[::-1], np.asarray(side_a[1])[::-1]
    positions_a = -STEP * np.arange(len(lons_a))[::-1]
    span = record["spanLength"]
    pieces = max(1, int(math.ceil(span / STEP))) if span > 0 else 0
    share = np.linspace(0, 1, pieces + 1)[1:-1] if pieces else np.zeros(0)
    lons_span = side_a[0][0] + (side_b[0][0] - side_a[0][0]) * share
    lats_span = side_a[1][0] + (side_b[1][0] - side_a[1][0]) * share
    # Without a span both sides start at the crossing; it is one point.
    first = 1 if span == 0 else 0
    positions_b = span + STEP * np.arange(first, len(side_b[0]))
    lons = np.concatenate([lons_a, lons_span, np.asarray(side_b[0])[first:]])
    lats = np.concatenate([lats_a, lats_span, np.asarray(side_b[1])[first:]])
    positions = np.concatenate([positions_a, span * share, positions_b])
    return lons, lats, positions


def stored_at_site(post, origin, record, side_a, side_b):
    """The grades the graph stores on the edges the site's road is matched to within NEAR of the crossing."""
    lons, lats, positions = site_shape(record, side_a, side_b)
    status, answer = post(origin, "/trace_attributes", {
        "shape": [{"lat": round(float(lat), 7), "lon": round(float(lon), 7)} for lon, lat in zip(lons, lats)],
        "costing": "bicycle", "shape_match": "map_snap", "trace_options": {"search_radius": 20},
        "filters": {"attributes": STORED_ATTRIBUTES, "action": "include"},
    })
    if status != 200:
        return {"stored": False, "why": f"HTTP {status}/{answer.get('error_code')}"}
    edges, points = answer.get("edges", []), answer.get("matched_points", [])
    near = set()
    for position, point in zip(positions, points):
        if -NEAR <= position <= record["spanLength"] + NEAR and point.get("type") == "matched":
            near.add(point.get("edge_index"))
    near = [edges[i] for i in sorted(i for i in near if i is not None and i < len(edges))]
    if not near:
        return {"stored": False, "why": "no edge matched near the crossing"}
    up = max(edge.get("max_upward_grade", 0) for edge in near)
    down = min(edge.get("max_downward_grade", 0) for edge in near)
    return {"stored": True, "maxSlope": max(up, -down), "maxUp": up, "maxDown": down,
            "weightedGrades": [edge.get("weighted_grade") for edge in near],
            "edges": [{key: edge.get(key) for key in ("way_id", "length", "weighted_grade", "max_upward_grade",
                                                       "max_downward_grade", "bridge", "tunnel")} for edge in near]}


def stored(site_files, services, bbox, out, kinds=None, log=print):
    """For every site in `bbox`, what each Valhalla service stores near the crossing."""
    import urllib.request

    def post(origin, path, body):
        request = urllib.request.Request(origin + path, data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            try:
                return error.code, json.loads(error.read())
            except ValueError:
                return error.code, {}

    west, south, east, north = bbox
    rows = []
    for path in site_files:
        meta, lons, lats, _, _, offsets = load_sites(path)
        for record in meta["sites"]:
            if not (west <= record["lon"] <= east and south <= record["lat"] <= north):
                continue
            if kinds and record["kind"] not in kinds:
                continue
            side = record["sideA"]
            side_a = (lons[offsets[side]:offsets[side + 1]], lats[offsets[side]:offsets[side + 1]])
            side_b = (lons[offsets[side + 1]:offsets[side + 2]], lats[offsets[side + 1]:offsets[side + 2]])
            row = {key: record.get(key) for key in ("kind", "way", "name", "highway", "group", "surface", "lon",
                                                     "lat", "spanLength")}
            row["services"] = {name: stored_at_site(post, origin, record, side_a, side_b)
                               for name, origin in services}
            rows.append(row)
            if len(rows) % 200 == 0:
                log(f"  {len(rows)} sites read")
    Path(out).write_text(json.dumps({"schema": "bicino-crossing-stored-v1", "bbox": bbox,
                                     "services": [name for name, _ in services], "sites": rows}) + "\n")
    log(f"{len(rows)} sites read from {len(services)} services into {out}")
    return rows


# Summary ------------------------------------------------------------------------


def load_results(paths):
    """Every measured site of the result files, each once: extracts overlap at their borders."""
    sites, documents, seen = [], [], set()
    for path in paths:
        data = Path(path).read_bytes()
        document = json.loads(gzip.decompress(data) if data[:2] == b"\x1f\x8b" else data)
        if document.get("schema") != RESULTS_SCHEMA:
            raise SystemExit(f"{path} is not a {RESULTS_SCHEMA} file")
        documents.append(document)
        for site in document["sites"]:
            key = site_key(site)
            if key not in seen:
                seen.add(key)
                sites.append(site)
    return documents, sites


def summarise(sites, worst=40):
    def table(rows, flag):
        counts = {}
        for site in rows:
            key = site["kind"]
            entry = counts.setdefault(key, {"sites": 0, "measured": 0, flag: 0, "ways": set()})
            entry["sites"] += 1
            if site.get("measured"):
                entry["measured"] += 1
                if site.get(flag):
                    entry[flag] += 1
                    entry["ways"].add(site["way"])
        return {key: {**{k: v for k, v in value.items() if k != "ways"}, "distinctWays": len(value["ways"])}
                for key, value in sorted(counts.items(), key=lambda item: KINDS.index(item[0]))}

    def split(flag, field):
        counts = {}
        for site in sites:
            if site.get("measured") and site.get(flag):
                key = f"{site['kind']} / {site.get(field) or '-'}"
                counts[key] = counts.get(key, 0) + 1
        return dict(sorted(counts.items()))

    summary = {"sites": len(sites), "measured": sum(1 for s in sites if s.get("measured"))}
    for flag in ("falseStep", "falseGrade", "fix"):
        summary[flag] = {
            "byKind": table(sites, flag),
            "byKindAndGroup": split(flag, "group"),
            "byKindAndSurface": split(flag, "surface"),
            "byKindAndArea": split(flag, "area"),
        }
        public = [s for s in sites if s.get("measured") and s.get(flag) and s["group"] in ("main", "minor")]
        summary[flag]["publicRoads"] = {
            "sites": len(public), "distinctWays": len({s["way"] for s in public}),
            "paved": sum(1 for s in public if s["surface"] == "paved"),
            "unpaved": sum(1 for s in public if s["surface"] == "unpaved"),
        }
    untagged = [s for s in sites if s.get("measured") and s.get("falseStep") and s["kind"] == "untagged"]
    summary["falseStep"]["untaggedNearBridge"] = sum(1 for s in untagged if s.get("nearBridge") is not None)
    summary["falseStep"]["byWaterKind"] = split("falseStep", "waterKind") if any("waterKind" in s for s in sites) else {}
    steps = [s for s in sites if s.get("measured") and s.get("falseStep")]
    steps.sort(key=lambda s: (s["group"] not in ("main", "minor"), -s["grade"]))
    summary["worst"] = [
        {key: s.get(key) for key in ("kind", "group", "highway", "surface", "name", "lat", "lon", "way", "grade",
                                      "bridgedGrade", "grade60", "dip", "waterKind", "waterName", "area",
                                      "spanLength", "nearBridge", "region")}
        for s in steps[:worst]
    ]
    return summary


def print_summary(summary, stream=sys.stdout):
    print(f"{summary['sites']} sites, {summary['measured']} measured", file=stream)
    for flag in ("falseStep", "falseGrade", "fix"):
        print(f"\n{flag}", file=stream)
        for kind, row in summary[flag]["byKind"].items():
            share = row[flag] / row["measured"] * 100 if row["measured"] else 0
            print(f"  {kind:13} {row['sites']:9} sites {row['measured']:9} measured {row[flag]:7} "
                  f"({share:.2f}%) on {row['distinctWays']} ways", file=stream)
        print(f"  public roads: {summary[flag]['publicRoads']}", file=stream)


# Command line -------------------------------------------------------------------


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    finding = commands.add_parser("sites", help="Find the sites of one OpenStreetMap extract")
    finding.add_argument("--pbf", required=True, type=Path)
    finding.add_argument("--region", required=True)
    finding.add_argument("--area", action="append", default=[],
                         help="NAME=PATH of a gzipped GeoJSON polygon; sites outside every area are left out")
    finding.add_argument("--out", required=True, type=Path)
    measuring = commands.add_parser("measure", help="Sample elevation tiles along every site")
    measuring.add_argument("--sites", nargs="+", required=True, type=Path)
    tiles = measuring.add_mutually_exclusive_group(required=True)
    tiles.add_argument("--elevation", type=Path, help="A tile directory")
    tiles.add_argument("--kept", type=Path, help="A record of kept tile sets (releases/elevation-cache-*.json)")
    measuring.add_argument("--set", default="hybrid-400", help="The kept set to read")
    measuring.add_argument("--meta", type=Path, help="The set's meta.tar, downloaded")
    measuring.add_argument("--token-file", type=Path)
    measuring.add_argument("--token-command",
                           help="Makes a new token for the token file when the bucket refuses the one in it, "
                                "such as 'gcloud auth print-access-token'")
    measuring.add_argument("--jobs", type=int, default=6)
    measuring.add_argument("--out", required=True, type=Path)
    restoring = commands.add_parser("restore", help="A kept set's cells in a box, as a sample elevation directory")
    restoring.add_argument("--kept", required=True, type=Path)
    restoring.add_argument("--set", default="hybrid-400")
    restoring.add_argument("--meta", required=True, type=Path)
    restoring.add_argument("--token-file", type=Path)
    restoring.add_argument("--token-command")
    restoring.add_argument("--bounds", required=True, type=int, nargs=4, metavar=("WEST", "SOUTH", "EAST", "NORTH"))
    restoring.add_argument("--out", required=True, type=Path)
    reading = commands.add_parser("stored", help="Read the grades Valhalla services store at every site in a box")
    reading.add_argument("--sites", nargs="+", required=True, type=Path)
    reading.add_argument("--service", action="append", required=True, metavar="NAME=ORIGIN")
    reading.add_argument("--bbox", required=True, type=float, nargs=4, metavar=("WEST", "SOUTH", "EAST", "NORTH"))
    reading.add_argument("--kind", action="append", choices=KINDS)
    reading.add_argument("--out", required=True, type=Path)
    summarising = commands.add_parser("summary", help="Count false steps and list the worst")
    summarising.add_argument("results", nargs="+", type=Path)
    summarising.add_argument("--worst", type=int, default=40)
    summarising.add_argument("--out", type=Path)
    args = parser.parse_args(argv)

    if args.command == "sites":
        write_sites(args.pbf, args.region, load_areas(args.area), args.out)
    elif args.command == "stored":
        services = [tuple(item.split("=", 1)) for item in args.service]
        stored(args.sites, services, args.bbox, args.out, args.kind)
    elif args.command == "restore":
        source = KeptSet(args.kept, args.set, args.token_file, args.meta, token_command=args.token_command)
        print(f"Elevation manifest: {restore_sample(source, args.bounds, args.out)}")
    elif args.command == "measure":
        if args.kept:
            if not args.meta:
                parser.error("--kept needs --meta, the set's meta.tar")
            source = KeptSet(args.kept, args.set, args.token_file, args.meta, token_command=args.token_command)
        else:
            source = TileDirectory(args.elevation)
        measure(args.sites, source, args.out, jobs=args.jobs)
    else:
        _, sites = load_results(args.results)
        summary = summarise(sites, args.worst)
        print_summary(summary)
        if args.out:
            args.out.write_text(json.dumps(summary, indent=1) + "\n")


if __name__ == "__main__":
    main()
