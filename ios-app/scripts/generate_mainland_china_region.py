#!/usr/bin/env python3
"""Generate the region in which Apple Maps uses GCJ-02 coordinates.

Apple Maps uses GCJ-02 only in mainland China; Hong Kong, Macau, Taiwan and
every other place use WGS-84. The generated region is:

- Natural Earth's mainland China: the admin-0 "China" feature, which excludes
  Hong Kong, Macau and Taiwan, and
- the sea whose nearest coastline is mainland China's, so coastal roads,
  reclaimed land and ferries stay with the mainland while Deep Bay, the Macau
  channels and the Kinmen strait are split along their midlines.

Natural Earth is in the public domain. Its 1:10m borders are generalized and
may lie a few hundred metres from the true border, more in remote mountains;
near border towns such as Gongbei and Mong Cai the difference can reach about
a kilometre. Simplification moves them by at most SIMPLIFY_METERS more. A few
islands Natural Earth omits, such as Matsu, are added as approximate discs.

The script needs shapely 2.1 or later, which the development environment
does not install. Download the pinned source and regenerate with:

    curl -LO https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_10m_admin_0_countries.geojson
    python3 ios-app/scripts/generate_mainland_china_region.py \\
        --source ne_10m_admin_0_countries.geojson
"""
import argparse
import base64
import hashlib
import json
import math
import random
import sys
from pathlib import Path

try:
    import numpy as np
    import shapely
    from shapely.geometry import Point, Polygon, box, shape
except ImportError:  # pragma: no cover - generator-only dependency
    sys.exit("shapely 2.1 or later is required to regenerate the region")

ROOT = Path(__file__).resolve().parents[2]
SWIFT_OUTPUT = ROOT / "ios-app/BikeComputer/RideShared/MainlandChinaRegion.generated.swift"
PROBE_OUTPUT = ROOT / "ios-app/BikeComputerTests/Fixtures/mainland-china-region-probes.json"

SOURCE_NAME = "Natural Earth 1:10m Admin 0 - Countries, version 5.1.2"
SOURCE_URL = (
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/"
    "geojson/ne_10m_admin_0_countries.geojson"
)
SOURCE_SHA256 = "239eec57ac17f100a11e2536cffc56752c318b50ae765b0918ff7aab4ce8f255"
MAINLAND = "CHN"

# West, south, east, north in degrees.
EXTENT = (70.0, 15.0, 140.0, 56.0)
# Other land here can be nearer to a sea point in EXTENT than China is.
NEIGHBOURHOOD = (55.0, -12.0, 165.0, 66.0)
COAST_SPACING_METERS = 500.0
DENSE_SPACING_METERS = 100.0
# Other coasts farther than this from mainland China only bound the open sea.
FAR_COAST_METERS = 300_000.0
FAR_SPACING_METERS = 5_000.0
# Where mainland and other coasts are a few kilometres apart, the midline needs
# denser coastline samples.
DENSE_WINDOWS = (
    (113.3, 21.9, 114.6, 22.8),  # Hong Kong, Shenzhen, Macau and Zhuhai
    (117.9, 24.2, 118.6, 24.7),  # Kinmen and Xiamen
    (119.4, 25.8, 120.6, 26.5),  # Matsu and Fuzhou
    (123.9, 39.6, 124.9, 40.4),  # Yalu estuary: Dandong and Sinuiju
    (107.8, 21.3, 108.3, 21.7),  # Beilun estuary: Dongxing and Mong Cai
    (130.3, 42.2, 130.9, 42.8),  # Tumen estuary
)
# Inhabited or visited islands that Natural Earth 1:10m omits and whose
# administration differs from the nearest coast's. They are approximate discs
# (name, latitude, longitude, radius in metres); each lies kilometres from the
# other side's coast, so the midline hardly depends on its exact outline.
OTHER_ISLANDS = (
    ("Nangan, Matsu", 26.155, 119.935, 1_800),
    ("Beigan, Matsu", 26.225, 119.995, 1_400),
    ("Xiju, Matsu", 25.970, 119.930, 900),
    ("Dongju, Matsu", 25.955, 119.983, 900),
    ("Dongyin, Matsu", 26.367, 120.490, 1_000),
    ("Lieyu, Kinmen", 24.430, 118.240, 2_000),
    ("Tung Ping Chau, Hong Kong", 22.545, 114.432, 800),
)
MAINLAND_ISLANDS = (
    ("Neilingding, Shenzhen", 22.418, 113.793, 1_300),
)
SIMPLIFY_METERS = 30.0
UNITS_PER_DEGREE = 100_000
PROBE_SEED = 20261030
PROBE_MARGIN_METERS = 20.0

# Places the region must classify correctly, at least MINIMUM_MARGIN_METERS
# from its edge.
NAMED_PROBES = (
    ("Shenzhen Civic Center", 22.5431, 114.0579, True),
    ("Sheung Shui, Hong Kong", 22.5011, 114.1281, False),
    ("Central, Hong Kong", 22.2810, 114.1600, False),
    ("Xiangzhou, Zhuhai", 22.2700, 113.5650, True),
    ("Senado Square, Macau", 22.1935, 113.5398, False),
    ("Taipa, Macau", 22.1560, 113.5560, False),
    ("Xiamen Island", 24.4798, 118.0894, True),
    ("Jincheng, Kinmen", 24.4340, 118.3180, False),
    ("Lieyu, Kinmen", 24.4300, 118.2400, False),
    ("Nangan, Matsu", 26.1550, 119.9350, False),
    ("Tung Ping Chau, Hong Kong", 22.5450, 114.4320, False),
    ("Dandong", 40.1600, 124.3800, True),
    ("Sinuiju", 40.0700, 124.4400, False),
    ("Taipei", 25.0330, 121.5654, False),
    ("Singapore", 1.3050, 103.8550, False),
    ("Seoul", 37.5665, 126.9780, False),
    ("Bangkok", 13.7563, 100.5018, False),
    ("Chengdu", 30.6586, 104.0648, True),
    ("Lanzhou", 36.0611, 103.8343, True),
    ("The Bund, Shanghai", 31.2400, 121.4900, True),
    ("East China Sea off Shanghai", 31.0000, 122.6000, True),
    ("Taiwan Strait off Fujian", 24.8000, 119.0000, True),
    ("Taiwan Strait off Taiwan", 24.3000, 120.3000, False),
    ("Haikou", 20.0440, 110.3417, True),
    ("Kashgar", 39.4704, 75.9898, True),
    ("Hanoi", 21.0278, 105.8342, False),
    ("Ulaanbaatar", 47.8864, 106.9057, False),
    ("Pyongyang", 39.0392, 125.7625, False),
    ("Vladivostok", 43.1155, 131.8855, False),
    ("Almaty", 43.2220, 76.8512, False),
    ("Kathmandu", 27.7172, 85.3240, False),
    ("Delhi", 28.6139, 77.2090, False),
    ("Fukuoka", 33.5904, 130.4017, False),
    ("Manila", 14.5995, 120.9842, False),
)
MINIMUM_MARGIN_METERS = 1_000.0

# Azimuthal equidistant projection centred on China. Within the extent its
# scale error stays below about 6%, which shifts a midline in a channel a few
# kilometres wide by metres.
EARTH_RADIUS = 6_371_008.8
CENTRE_LONGITUDE = math.radians(105.0)
CENTRE_LATITUDE = math.radians(35.0)


def project_xy(xy):
    lam = np.radians(xy[:, 0]) - CENTRE_LONGITUDE
    phi = np.radians(xy[:, 1])
    cos_c = (math.sin(CENTRE_LATITUDE) * np.sin(phi) +
             math.cos(CENTRE_LATITUDE) * np.cos(phi) * np.cos(lam))
    c = np.arccos(np.clip(cos_c, -1.0, 1.0))
    k = np.where(c < 1e-12, 1.0, c / np.where(c < 1e-12, 1.0, np.sin(c)))
    x = EARTH_RADIUS * k * np.cos(phi) * np.sin(lam)
    y = EARTH_RADIUS * k * (math.cos(CENTRE_LATITUDE) * np.sin(phi) -
                            math.sin(CENTRE_LATITUDE) * np.cos(phi) * np.cos(lam))
    return np.column_stack((x, y))


def unproject_xy(xy):
    x, y = xy[:, 0], xy[:, 1]
    rho = np.hypot(x, y)
    c = rho / EARTH_RADIUS
    safe = np.where(rho == 0, 1.0, rho)
    phi = np.arcsin(np.cos(c) * math.sin(CENTRE_LATITUDE) +
                    np.where(rho == 0, 0.0, y * np.sin(c) * math.cos(CENTRE_LATITUDE) / safe))
    lam = CENTRE_LONGITUDE + np.arctan2(
        x * np.sin(c),
        rho * math.cos(CENTRE_LATITUDE) * np.cos(c) - y * math.sin(CENTRE_LATITUDE) * np.sin(c))
    return np.column_stack((np.degrees(lam), np.degrees(phi)))


def project(geometry):
    return shapely.transform(geometry, project_xy)


def unproject(geometry):
    return shapely.transform(geometry, unproject_xy)


def degree_box(bounds):
    return shapely.segmentize(box(*bounds), 0.05)


def load_land(path):
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != SOURCE_SHA256:
        sys.exit(f"unexpected source SHA-256 {digest}; expected {SOURCE_SHA256}")
    neighbourhood = box(*NEIGHBOURHOOD)
    mainland, others = [], []
    for feature in json.loads(data)["features"]:
        geometry = shape(feature["geometry"])
        if feature["properties"]["ADM0_A3"] == MAINLAND:
            mainland.append(geometry)
        elif geometry.intersects(neighbourhood):
            others.append(geometry.intersection(neighbourhood))
    if len(mainland) != 1:
        sys.exit("the source must contain exactly one mainland China feature")
    return mainland[0], shapely.union_all(others)


def coast_samples(coast, dense_area, near_area):
    rest = shapely.difference(coast, dense_area)
    far = shapely.difference(rest, near_area)
    parts = (
        shapely.segmentize(shapely.intersection(coast, dense_area), DENSE_SPACING_METERS),
        shapely.segmentize(shapely.intersection(rest, near_area), COAST_SPACING_METERS),
        shapely.segmentize(shapely.simplify(far, FAR_SPACING_METERS / 10), FAR_SPACING_METERS),
    )
    return np.vstack([shapely.get_coordinates(part) for part in parts])


def union_cells(cells):
    # Seeds a few metres apart can yield invalid slivers, which the overlay
    # rejects; repair them and fall back to snapping if the union still fails.
    invalid = ~shapely.is_valid(cells)
    cells[invalid] = shapely.make_valid(cells[invalid], method="structure", keep_collapsed=False)
    for grid_size in (None, 0.01, 1.0):
        try:
            return shapely.union_all(cells, grid_size=grid_size)
        except shapely.errors.GEOSException:
            continue
    sys.exit("the mainland sea cells could not be merged")


def islands(entries):
    return shapely.union_all([
        shapely.buffer(project(Point(longitude, latitude)), radius)
        for _, latitude, longitude, radius in entries
    ])


def build_region(mainland, others):
    extent = project(degree_box(EXTENT))
    neighbourhood_edge = project(degree_box(NEIGHBOURHOOD)).exterior
    dense_area = shapely.union_all([project(degree_box(window)) for window in DENSE_WINDOWS])
    land = project(mainland)
    other_land = project(others)
    other_islands, mainland_islands = islands(OTHER_ISLANDS), islands(MAINLAND_ISLANDS)
    if other_islands.intersects(land) or mainland_islands.intersects(other_land):
        sys.exit("an added island overlaps the other side's land")
    land = shapely.union(land, mainland_islands)
    other_land = shapely.union(other_land, other_islands)

    # Seeds lie on coastlines only: shared land borders are settled by the land
    # polygons themselves, and clipping edges are not coast.
    mainland_coast = shapely.difference(land.boundary, shapely.buffer(other_land, 10.0))
    other_coast = shapely.difference(
        shapely.difference(other_land.boundary, shapely.buffer(land, 10.0)),
        shapely.buffer(neighbourhood_edge, 10.0))
    near_area = shapely.buffer(shapely.simplify(land, 2_000.0), FAR_COAST_METERS)
    mainland_seeds = coast_samples(mainland_coast, dense_area, extent)
    other_seeds = coast_samples(other_coast, dense_area, near_area)

    seeds = np.vstack([mainland_seeds, other_seeds])
    owners = np.concatenate([np.ones(len(mainland_seeds), bool), np.zeros(len(other_seeds), bool)])
    _, first = np.unique(np.round(seeds), axis=0, return_index=True)
    first.sort()
    seeds, owners = seeds[first], owners[first]
    cells = shapely.get_parts(shapely.voronoi_polygons(
        shapely.multipoints(seeds), extend_to=extent, ordered=True))
    if len(cells) != len(seeds):
        sys.exit("Voronoi cells do not match their coastline seeds")
    mainland_sea = union_cells(cells[owners])

    region = shapely.union(land, shapely.difference(mainland_sea, other_land))
    region = shapely.intersection(region, extent)
    region = shapely.make_valid(region)
    polygons = [part for part in shapely.get_parts(region) if part.geom_type == "Polygon"]
    region = shapely.simplify(shapely.multipolygons(polygons), SIMPLIFY_METERS, preserve_topology=True)
    return unproject(region), len(mainland_seeds), len(other_seeds)


def quantized_rings(region):
    rings = []
    polygons = sorted(shapely.get_parts(region), key=lambda part: part.bounds)
    for polygon in polygons:
        for ring in [polygon.exterior, *polygon.interiors]:
            units = np.round(np.asarray(ring.coords) * UNITS_PER_DEGREE).astype(np.int64)
            kept = [units[0]]
            for point in units[1:]:
                if (point != kept[-1]).any():
                    kept.append(point)
            if (kept[0] == kept[-1]).all():
                kept.pop()
            if len(kept) >= 3:
                rings.append(np.array(kept))
    return rings


def rings_geometry(rings):
    # Even-odd rule, which the app's ray casting uses too.
    result = shapely.Polygon()
    for ring in rings:
        result = shapely.symmetric_difference(result, Polygon(ring / UNITS_PER_DEGREE))
    return result


def varint(value, out):
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return


def zigzag(value):
    return (value << 1) ^ (value >> 63)


def encode(rings):
    out = bytearray()
    varint(len(rings), out)
    for ring in rings:
        varint(len(ring), out)
        previous_longitude = previous_latitude = 0
        for longitude, latitude in ring.tolist():
            varint(zigzag(latitude - previous_latitude), out)
            varint(zigzag(longitude - previous_longitude), out)
            previous_latitude, previous_longitude = latitude, longitude
    return bytes(out)


def meters_from_edge(geometry, latitude, longitude):
    point = project(Point(longitude, latitude))
    return shapely.distance(project(geometry.boundary), point)


def probes(geometry):
    rng = random.Random(PROBE_SEED)
    boundary = project(geometry.boundary)
    shapely.prepare(boundary)
    shapely.prepare(geometry)
    candidates = []
    west, south, east, north = EXTENT
    for _ in range(600):
        candidates.append((rng.uniform(south, north), rng.uniform(west, east)))
    # Points near the edge test the ray casting where it matters.
    lines = list(shapely.get_parts(boundary))
    weights = [line.length for line in lines]
    for _ in range(600):
        line = rng.choices(lines, weights)[0]
        anchor = line.interpolate(rng.uniform(0, line.length))
        offset = rng.choice((-1, 1)) * rng.uniform(40, 3_000)
        angle = rng.uniform(0, 2 * math.pi)
        moved = Point(anchor.x + offset * math.cos(angle), anchor.y + offset * math.sin(angle))
        longitude, latitude = unproject(moved).coords[0]
        candidates.append((latitude, longitude))
    rows = []
    for latitude, longitude in candidates:
        latitude, longitude = round(latitude, 6), round(longitude, 6)
        point = Point(longitude, latitude)
        if shapely.distance(boundary, project(point)) < PROBE_MARGIN_METERS:
            continue
        rows.append([latitude, longitude, 1 if geometry.contains(point) else 0])
    return rows


def swift_source(encoded, rings, bounds, counts):
    text = base64.b64encode(encoded).decode("ascii")
    lines = [text[index:index + 100] for index in range(0, len(text), 100)]
    west, south, east, north = bounds
    body = "\n".join(lines)
    vertex_count = sum(len(ring) for ring in rings)
    return f"""// Generated by ios-app/scripts/generate_mainland_china_region.py. Do not edit.
// Source: {SOURCE_NAME} (public domain),
// {SOURCE_URL}
// SHA-256 {SOURCE_SHA256}.
// Land borders are Natural Earth's, simplified by at most {SIMPLIFY_METERS:g} m; the sea is
// split by the nearest coastline ({counts[0]} mainland and {counts[1]} other coastline samples).

nonisolated extension MainlandChinaRegion {{
    enum Generated {{
        static let unitsPerDegree = {UNITS_PER_DEGREE}.0
        static let ringCount = {len(rings)}
        static let vertexCount = {vertex_count}
        static let south = {south / UNITS_PER_DEGREE:.5f}
        static let west = {west / UNITS_PER_DEGREE:.5f}
        static let north = {north / UNITS_PER_DEGREE:.5f}
        static let east = {east / UNITS_PER_DEGREE:.5f}

        /// Base64 of: varint ring count; per ring, varint vertex count and
        /// zigzag varint latitude and longitude deltas, in units per degree.
        static let rings = \"\"\"
{body}
\"\"\"
    }}
}}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()

    mainland, others = load_land(args.source)
    region, mainland_count, other_count = build_region(mainland, others)
    rings = quantized_rings(region)
    geometry = rings_geometry(rings)
    if not geometry.is_valid:
        sys.exit("the quantized region is not a valid polygon")

    failures = []
    for name, latitude, longitude, inside in NAMED_PROBES:
        contained = geometry.contains(Point(longitude, latitude))
        margin = meters_from_edge(geometry, latitude, longitude)
        print(f"{name:32s} {'in' if contained else 'out':3s} {margin / 1000:8.2f} km from edge")
        if contained != inside or margin < MINIMUM_MARGIN_METERS:
            failures.append(name)
    if failures:
        sys.exit("named probes failed: " + ", ".join(failures))

    all_units = np.vstack(rings)
    bounds = (all_units[:, 0].min(), all_units[:, 1].min(), all_units[:, 0].max(), all_units[:, 1].max())
    encoded = encode(rings)
    SWIFT_OUTPUT.write_text(swift_source(encoded, rings, bounds, (mainland_count, other_count)))
    rows = probes(geometry)
    PROBE_OUTPUT.write_text(json.dumps({
        "generator": "ios-app/scripts/generate_mainland_china_region.py",
        "seed": PROBE_SEED,
        "points": rows,
    }, separators=(",", ":")) + "\n")
    print(f"{len(rings)} rings, {len(all_units)} vertices, {len(encoded)} bytes; {len(rows)} probes")


if __name__ == "__main__":
    main()
