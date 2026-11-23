#!/usr/bin/env python3
"""Build the pinned inclusion mask and record the disposition of each map unit."""

import argparse
import hashlib
import json
import math
from collections import defaultdict
from html.parser import HTMLParser
from pathlib import Path

from pyproj import Transformer
from shapely import make_valid
from shapely.geometry import Polygon, box, mapping, shape
from shapely.ops import transform, unary_union


WORLD = box(-180, -90, 180, 90)
PROJECT = Transformer.from_crs(4326, 3857, always_xy=True).transform
UNPROJECT = Transformer.from_crs(3857, 4326, always_xy=True).transform
MAP_UNITS = "ne_10m_admin_0_map_units.geojson"
DISPUTES = "ne_10m_admin_0_disputed_areas.geojson"


class AppleCyclingSection(HTMLParser):
    def __init__(self):
        super().__init__()
        self.sections = 0
        self.active = False
        self.item = None
        self.labels = []

    def handle_starttag(self, tag, attrs):
        if tag == "section" and dict(attrs).get("id") == "maps-cycling":
            self.sections += 1
            self.active = True
        elif self.active and tag == "li":
            self.item = []

    def handle_data(self, data):
        if self.item is not None:
            self.item.append(data)

    def handle_endtag(self, tag):
        if tag == "li" and self.item is not None:
            self.labels.append(" ".join("".join(self.item).split()))
            self.item = None
        elif tag == "section" and self.active:
            self.active = False


def check_apple_list(html, expected_labels):
    parser = AppleCyclingSection()
    parser.feed(html)
    actual = set(parser.labels)
    expected = set(expected_labels)
    if parser.sections != 1 or len(actual) != len(parser.labels) or actual != expected:
        raise ValueError(
            f"Apple Maps Cycling changed or could not be parsed. "
            f"New entries: {sorted(actual - expected)}. Missing entries: {sorted(expected - actual)}."
        )


def polygonal(geometry):
    valid = make_valid(geometry)
    if valid.geom_type in {"Polygon", "MultiPolygon"}:
        return valid
    if valid.geom_type == "GeometryCollection":
        return unary_union([polygonal(part) for part in valid.geoms])
    return Polygon()


def erode_map_unit(geometry, meters):
    """Keep at least the nominal corridor width using conservative Mercator bands."""
    geometry = geometry.intersection(box(-180, -85, 180, 85))
    if geometry.is_empty:
        return geometry
    projected = transform(PROJECT, geometry)
    _, lowest, _, highest = geometry.bounds
    cores = []
    for bottom in range(math.floor(lowest / 5) * 5, math.ceil(highest / 5) * 5, 5):
        top = bottom + 5
        # Mercator scale rises with latitude. Include an extra degree for the
        # corridor around this band and a margin for the ellipsoid.
        latitude = min(89, max(abs(bottom), abs(top)) + 1)
        distance = 1.01 * meters / math.cos(math.radians(latitude))
        band = transform(PROJECT, box(-180, bottom, 180, top))
        cores.append(projected.buffer(-distance).intersection(band))
    return polygonal(transform(UNPROJECT, unary_union(cores)))


def load_features(directory, filename, checksum):
    data = (directory / filename).read_bytes()
    if hashlib.sha256(data).hexdigest() != checksum:
        raise ValueError(f"Boundary checksum mismatch: {filename}")
    return json.loads(data)["features"]


def build_mask(policy, boundaries, corridors=None):
    if policy["schema"] != "bicino-bicycle-coverage-v1":
        raise ValueError("Unsupported coverage policy schema")
    map_units = defaultdict(list)
    for feature in load_features(boundaries, MAP_UNITS, policy["boundaryFiles"][MAP_UNITS]):
        properties = feature["properties"]
        map_units[properties["GU_A3"]].append(polygonal(shape(feature["geometry"])))
    units = {code: unary_union(geometries) for code, geometries in map_units.items()}
    supported = {
        code for codes in policy["appleCyclingMapUnits"].values() for code in codes
    }
    if missing := supported - units.keys():
        raise ValueError(f"Apple coverage refers to unknown map units: {sorted(missing)}")
    distance = policy["borderBufferMeters"]
    if type(distance) is not int or not 30000 <= distance <= 60000:
        raise ValueError("Expected a 30–60 km border buffer")
    exclusions = unary_union([erode_map_unit(units[code], distance) for code in sorted(supported)])
    disputes = load_features(boundaries, DISPUTES, policy["boundaryFiles"][DISPUTES])
    retained = [polygonal(shape(item["geometry"])) for item in disputes]
    retained.extend(units[code] for code in sorted(units.keys() - supported))
    if corridors is not None:
        retained.extend(polygonal(shape(item["geometry"])) for item in corridors["features"])
    exclusions = polygonal(exclusions.difference(unary_union(retained)))
    inclusion = polygonal(WORLD.difference(exclusions))
    inventory = {
        code: {
            "appleListed": code in supported,
            "excludedArea": geography.relate_pattern(exclusions, "2********"),
        }
        for code, geography in sorted(units.items())
    }
    return inclusion, inventory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", type=Path, default=Path(__file__).with_name("coverage.json"))
    parser.add_argument("--boundaries", type=Path, required=True)
    parser.add_argument("--apple-html", type=Path)
    parser.add_argument("--corridors", type=Path, help="Additional retained polygons as GeoJSON features")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--inventory", type=Path, required=True)
    args = parser.parse_args()
    policy = json.loads(args.policy.read_text())
    if args.apple_html:
        check_apple_list(args.apple_html.read_text(), policy["appleCyclingMapUnits"])
    corridors = json.loads(args.corridors.read_text()) if args.corridors else None
    mask, inventory = build_mask(policy, args.boundaries, corridors)
    args.output.write_text(json.dumps(mapping(mask), separators=(",", ":")) + "\n")
    args.inventory.write_text(json.dumps(inventory, indent=2) + "\n")


if __name__ == "__main__":
    main()
