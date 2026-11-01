import json
import math
import os
import pathlib
import random
import subprocess
import sys
import tempfile
import unittest

from shapely import LinearRing, LineString, Polygon, box


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from funcs import BlockFeatureIndex, clip_lines, clip_polygons  # noqa: E402


EARTH_RADIUS_METERS = 6_378_137
BLOCK = 4096
MASK = BLOCK - 1
HOST_FONT_CANDIDATES = (
    pathlib.Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
    pathlib.Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf"),
)
# Runs extract_features.py with the pre-index behaviour: every block clip
# receives the complete feature list, exactly as the loop did before.
FULL_SCAN_RUNNER = """
import runpy
import sys

scripts = sys.argv[1]
sys.path.insert(0, scripts)
import funcs


class FullScan:
    calls = 0

    def __init__(self, features):
        self.features = features

    @classmethod
    def for_lines(cls, features):
        return cls(features)

    @classmethod
    def for_polygons(cls, features):
        return cls(features)

    def candidates(self, block):
        FullScan.calls += 1
        return self.features


funcs.BlockFeatureIndex = FullScan
script = scripts + "/extract_features.py"
sys.argv = [script, *sys.argv[2:]]
try:
    runpy.run_path(script, run_name="__main__")
finally:
    print(f"FULL_SCAN_REFERENCE_CALLS:{FullScan.calls}", flush=True)
"""


def block_box(min_x, min_y):
    # The exact block geometry extract_features.py clips with.
    return box(min_x, min_y, min_x + MASK, min_y + MASK + 1)


# The two lines test_clip_lines.py counts instead of drawing: one ULP long
# inside block (0, 0), and crossing the corner of block (4096, 4096) within
# a nanometre.
ULP_SHORT_ROAD = [
    (2815.860862137019, 3797.2024186666486),
    (2815.8608621370204, 3797.2024186666486),
]
CORNER_CONTACT_ROAD = [
    (4096.000000001, 4095.999999999),
    (4095.999999999, 4096.000000001),
]


def line_feature(identifier, geometry, label_candidates=()):
    return {
        "id": identifier,
        "type": "highway.residential",
        "geom_type": "line",
        "label_tags": {"name": f"Road {identifier}"} if label_candidates else {},
        "label_candidates": list(label_candidates),
        "geom": geometry,
    }


def polygon_feature(identifier, geometry):
    return {
        "id": identifier,
        "type": "landuse.grass",
        "geom_type": "polygon",
        "_source_geometry_key": f"w{identifier}",
        "_source_geometry_component": 0,
        "geom": geometry,
    }


def regular_polygon(center_x, center_y, radius, vertices, holes=()):
    shell = [
        (
            center_x + radius * math.cos(2 * math.pi * index / vertices),
            center_y + radius * math.sin(2 * math.pi * index / vertices),
        )
        for index in range(vertices)
    ]
    return Polygon(shell, holes)


def synthetic_features(seed):
    random_source = random.Random(seed)
    lines = []
    for index in range(400):
        x = random_source.uniform(-500, 13_000)
        y = random_source.uniform(-500, 13_000)
        points = [(x, y)]
        heading = random_source.uniform(0, 2 * math.pi)
        for _ in range(random_source.randint(1, 12)):
            heading += random_source.uniform(-0.7, 0.7)
            step = random_source.uniform(30, 2_500)
            x += step * math.cos(heading)
            y += step * math.sin(heading)
            points.append((x, y))
        geometry = LineString(points)
        candidates = []
        if index % 3 == 0:
            for fraction in (0.25, 0.5, 0.75):
                midpoint = geometry.interpolate(fraction, normalized=True)
                candidates.append({"midpoint": (midpoint.x, midpoint.y), "rank": index})
        lines.append(line_feature(index, geometry, candidates))
    # Lines on, and touching, block edges and corners.
    lines.extend(
        [
            line_feature("left-edge", LineString([(4096, 100), (4096, 3000)])),
            line_feature("right-edge", LineString([(4095, 100), (4095, 3000)])),
            line_feature("corner", LineString([(4096, 8192), (5000, 9000)])),
            line_feature(
                "edge-label",
                LineString([(4000, 2000), (4192, 2000)]),
                [{"midpoint": (4096.0, 2000.0), "rank": -1}],
            ),
            # Reach a block only within half a metre of its clip box, including
            # the extra metre above min_y + 4095 that extract_features adds.
            line_feature("edge-graze", LineString([(4094.5, 500), (4100, 520)])),
            line_feature("top-strip", LineString([(1000, 4095.4), (1300, 4095.6)])),
            line_feature("empty", LineString()),
            # Pass the block test but leave nothing to draw: counted, not drawn.
            line_feature("ulp-short", LineString(ULP_SHORT_ROAD)),
            line_feature("corner-contact", LineString(CORNER_CONTACT_ROAD)),
        ]
    )

    polygons = []
    for index in range(300):
        polygons.append(
            polygon_feature(
                index,
                regular_polygon(
                    random_source.uniform(-500, 13_000),
                    random_source.uniform(-500, 13_000),
                    random_source.uniform(5, 900),
                    random_source.randint(3, 20),
                ),
            )
        )
    polygons.extend(
        [
            # Spans several blocks and needs hole-free decomposition in each.
            polygon_feature(
                "lake",
                Polygon(
                    [(1000, 1000), (11_000, 1200), (10_500, 9000), (1500, 10_000)],
                    [
                        [(3000, 3000), (3500, 3000), (3500, 3500), (3000, 3500)],
                        [(6000, 5000), (7000, 5200), (6500, 6100)],
                    ],
                ),
            ),
            # The block at (4096, 4096) lies inside the hole: an envelope
            # candidate that never intersects it.
            polygon_feature(
                "ring",
                Polygon(
                    [(3000, 3000), (9300, 3000), (9300, 9300), (3000, 9300)],
                    [[(4000, 4000), (8300, 4000), (8300, 8300), (4000, 8300)]],
                ),
            ),
            polygon_feature(
                "shared-edge",
                Polygon([(4096, 4096), (4500, 4096), (4500, 4500), (4096, 4500)]),
            ),
            polygon_feature(
                "top-strip",
                Polygon([(2000, 4095), (2050, 4095), (2050, 4097), (2000, 4097)]),
            ),
            # Collapses to nothing at FMB precision.
            polygon_feature(
                "sliver",
                Polygon([(2000.1, 2000.1), (2000.4, 2000.1), (2000.4, 2000.4)]),
            ),
            # Rejected by type in every block, so it must stay in every block.
            polygon_feature("line-in-polygons", LineString([(0, 0), (10, 10)])),
            polygon_feature("empty", Polygon()),
        ]
    )
    return lines, polygons


def canonical(features):
    return [
        {
            key: value.wkb if key == "geom" else value
            for key, value in sorted(feature.items())
        }
        for feature in features
    ]


class BlockFeatureIndexTests(unittest.TestCase):
    def test_candidates_reproduce_full_scan_clip_output_and_diagnostics(self):
        lines, polygons = synthetic_features(seed=20261030)
        line_index = BlockFeatureIndex.for_lines(lines)
        polygon_index = BlockFeatureIndex.for_polygons(polygons)
        full_label_diagnostics = {}
        full_geometry_diagnostics = {}
        indexed_label_diagnostics = {}
        indexed_geometry_diagnostics = {}
        offered = 0
        blocks = [
            (x * BLOCK, y * BLOCK)
            for x in range(-1, 5)
            for y in range(-1, 5)
        ]
        for min_x, min_y in blocks:
            block = block_box(min_x, min_y)
            with self.subTest(block=(min_x, min_y)):
                line_candidates = line_index.candidates(block)
                polygon_candidates = polygon_index.candidates(block)
                offered += len(line_candidates) + len(polygon_candidates)
                for features, candidates in (
                    (lines, line_candidates),
                    (polygons, polygon_candidates),
                ):
                    positions = [
                        next(
                            position
                            for position, feature in enumerate(features)
                            if feature is candidate
                        )
                        for candidate in candidates
                    ]
                    self.assertEqual(positions, sorted(set(positions)))
                self.assertEqual(
                    canonical(
                        clip_lines(
                            line_candidates,
                            block,
                            label_diagnostics=indexed_label_diagnostics,
                            geometry_diagnostics=indexed_geometry_diagnostics,
                        )
                    ),
                    canonical(
                        clip_lines(
                            lines,
                            block,
                            label_diagnostics=full_label_diagnostics,
                            geometry_diagnostics=full_geometry_diagnostics,
                        )
                    ),
                )
                self.assertEqual(
                    canonical(
                        clip_polygons(
                            polygon_candidates,
                            block,
                            geometry_diagnostics=indexed_geometry_diagnostics,
                        )
                    ),
                    canonical(
                        clip_polygons(
                            polygons,
                            block,
                            geometry_diagnostics=full_geometry_diagnostics,
                        )
                    ),
                )
        self.assertEqual(indexed_label_diagnostics, full_label_diagnostics)
        self.assertEqual(indexed_geometry_diagnostics, full_geometry_diagnostics)
        # The index offers the two undrawable lines to the blocks that count
        # them, and nothing else is counted.
        self.assertEqual(
            full_geometry_diagnostics["lineClipsWithoutLengthByResult"],
            {"empty": 1, "Point": 1},
        )
        # The fixture exercises label ownership, both drop reasons and pruning.
        self.assertGreater(full_label_diagnostics["clippedCandidates"], 0)
        self.assertGreater(
            full_label_diagnostics["candidatesRejectedByBlockOwnership"], 0
        )
        # The misplaced LineString is offered to, and dropped by, every block.
        self.assertGreaterEqual(
            full_geometry_diagnostics["droppedByCode"]["invalid_block_polygon"],
            len(blocks),
        )
        self.assertLess(offered, (len(lines) + len(polygons)) * len(blocks) // 4)

    def test_type_rejected_line_fails_at_the_first_block_like_full_scan(self):
        lines = [
            line_feature("road", LineString([(10, 10), (20, 20)])),
            line_feature("far-ring", LinearRing([(50_000, 0), (50_010, 0), (50_010, 10)])),
        ]
        index = BlockFeatureIndex.for_lines(lines)
        block = block_box(0, 0)
        with self.assertRaises(AssertionError) as full_scan:
            clip_lines(lines, block)
        with self.assertRaises(AssertionError) as indexed:
            clip_lines(index.candidates(block), block)
        self.assertEqual(str(indexed.exception), str(full_scan.exception))

    def test_without_indexable_features_every_block_gets_the_full_list(self):
        self.assertEqual(BlockFeatureIndex.for_polygons([]).candidates(block_box(0, 0)), [])
        polygons = [
            polygon_feature("line", LineString([(50_000, 0), (50_010, 10)])),
            polygon_feature("empty", Polygon()),
        ]
        index = BlockFeatureIndex.for_polygons(polygons)
        for min_x, min_y in ((0, 0), (BLOCK, 3 * BLOCK)):
            block = block_box(min_x, min_y)
            candidates = index.candidates(block)
            self.assertEqual([feature["id"] for feature in candidates], ["line", "empty"])
            full_scan_diagnostics = {}
            indexed_diagnostics = {}
            self.assertEqual(
                clip_polygons(candidates, block, geometry_diagnostics=indexed_diagnostics),
                clip_polygons(polygons, block, geometry_diagnostics=full_scan_diagnostics),
            )
            self.assertEqual(indexed_diagnostics, full_scan_diagnostics)

    def test_extract_features_cli_output_is_byte_identical_to_full_scan(self):
        host_font = next(
            (path for path in HOST_FONT_CANDIDATES if path.is_file()),
            None,
        )
        self.assertIsNotNone(host_font, "host font fixture is unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            write_cli_fixture(root, seed=7)
            runner = root / "full_scan_runner.py"
            runner.write_text(FULL_SCAN_RUNNER, encoding="utf-8")
            environment = os.environ.copy()
            environment.update(
                {
                    "OBC_LABEL_LATIN_FONT": str(host_font),
                    "OBC_LABEL_CJK_FONT": str(host_font),
                }
            )
            bounds = [
                str(math.degrees(100 / EARTH_RADIUS_METERS)),
                str(mercator_latitude(100)),
                str(math.degrees(12_000 / EARTH_RADIUS_METERS)),
                str(mercator_latitude(12_000)),
            ]
            options = ["--renderer-format", "3", "--preferred-language", "en"]
            indexed = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "extract_features.py"),
                    *bounds,
                    str(root / "features"),
                    str(root / "indexed"),
                    *options,
                ],
                cwd=ROOT / "scripts",
                env=environment,
                check=False,
                text=True,
                capture_output=True,
            )
            full_scan = subprocess.run(
                [
                    sys.executable,
                    str(runner),
                    str(ROOT / "scripts"),
                    *bounds,
                    str(root / "features"),
                    str(root / "full-scan"),
                    *options,
                ],
                cwd=ROOT / "scripts",
                env=environment,
                check=False,
                text=True,
                capture_output=True,
            )
            for result in (indexed, full_scan):
                self.assertEqual(
                    result.returncode,
                    0,
                    f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
                )
            reference_calls = stats_line(full_scan.stdout, "FULL_SCAN_REFERENCE_CALLS")
            self.assertEqual(int(reference_calls), 2 * 9)

            indexed_files = output_files(root / "indexed")
            self.assertEqual(indexed_files, output_files(root / "full-scan"))
            self.assertGreater(
                sum(1 for name in indexed_files if name.endswith(".fmb")), 4
            )
            self.assertIn("assets/street-labels.fma", indexed_files)
            for marker in ("GEOMETRY_DIAGNOSTICS", "LABEL_STATS", "BUILDING_STATS"):
                with self.subTest(marker=marker):
                    self.assertEqual(
                        without_timings(json.loads(stats_line(indexed.stdout, marker))),
                        without_timings(json.loads(stats_line(full_scan.stdout, marker))),
                    )
            label_stats = json.loads(stats_line(indexed.stdout, "LABEL_STATS"))
            self.assertGreater(label_stats["labels"], 0)
            building_stats = json.loads(stats_line(indexed.stdout, "BUILDING_STATS"))
            self.assertGreater(building_stats["recordCount"], 0)


def mercator_latitude(y):
    return math.degrees(2 * math.atan(math.exp(y / EARTH_RADIUS_METERS)) - math.pi / 2)


def write_cli_fixture(root, *, seed):
    random_source = random.Random(seed)
    lines = []
    for index in range(160):
        x = random_source.uniform(-300, 12_600)
        y = random_source.uniform(-300, 12_600)
        coordinates = [[x, y]]
        heading = random_source.uniform(0, 2 * math.pi)
        for _ in range(random_source.randint(2, 10)):
            heading += random_source.uniform(-0.5, 0.5)
            step = random_source.uniform(80, 1_800)
            x += step * math.cos(heading)
            y += step * math.sin(heading)
            coordinates.append([x, y])
        properties = {
            "osm_id": 1_000 + index,
            "highway": random_source.choice(
                ["residential", "primary", "secondary", "tertiary", "service"]
            ),
        }
        if index % 2 == 0:
            properties["name"] = f"Fixture Road {index}"
        lines.append(feature(properties, "LineString", coordinates))
    lines.append(
        feature(
            {"osm_id": 2_000, "waterway": "river", "name": "Fixture River"},
            "LineString",
            [[-200, 6_100], [3_000, 5_800], [6_500, 7_400], [12_500, 6_900]],
        )
    )

    polygons = []
    for index in range(90):
        center_x = random_source.uniform(-300, 12_600)
        center_y = random_source.uniform(-300, 12_600)
        radius = random_source.uniform(20, 1_400)
        vertices = random_source.randint(4, 16)
        shell = ring(center_x, center_y, radius, vertices)
        rings = [shell]
        if radius > 900:
            rings.append(list(reversed(ring(center_x, center_y, radius / 3, 6))))
        polygons.append(
            feature(
                {
                    "osm_way_id": 3_000 + index,
                    "landuse": random_source.choice(["grass", "forest", "farmland"]),
                },
                "MultiPolygon",
                [rings],
            )
        )
    polygons.append(
        feature(
            {"osm_id": 4_000, "natural": "water"},
            "MultiPolygon",
            [
                [
                    ring(6_000, 6_000, 5_000, 24),
                    list(reversed(ring(4_096, 4_096, 300, 8))),
                ]
            ],
        )
    )
    for index in range(40):
        x = random_source.uniform(0, 12_000)
        y = random_source.uniform(0, 12_000)
        size = random_source.uniform(8, 40)
        polygons.append(
            feature(
                {"osm_way_id": 5_000 + index, "building": "yes"},
                "MultiPolygon",
                [[[[x, y], [x + size, y], [x + size, y + size], [x, y + size], [x, y]]]],
            )
        )

    for name, collection in (("lines", lines), ("polygons", polygons)):
        (root / f"features_{name}.geojson").write_text(
            json.dumps({"type": "FeatureCollection", "features": collection}),
            encoding="utf-8",
        )


def ring(center_x, center_y, radius, vertices):
    coordinates = [
        [
            center_x + radius * math.cos(2 * math.pi * index / vertices),
            center_y + radius * math.sin(2 * math.pi * index / vertices),
        ]
        for index in range(vertices)
    ]
    return coordinates + [coordinates[0]]


def feature(properties, geometry_type, coordinates):
    return {
        "type": "Feature",
        "properties": properties,
        "geometry": {"type": geometry_type, "coordinates": coordinates},
    }


def stats_line(stdout, marker):
    return next(
        line.split(":", 1)[1]
        for line in stdout.splitlines()
        if line.startswith(f"{marker}:")
    )


def output_files(root):
    return {
        path.relative_to(root).as_posix(): path.read_bytes()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def without_timings(value):
    if isinstance(value, dict):
        return {
            key: without_timings(item)
            for key, item in value.items()
            if key != "phaseTimings" and not key.endswith("Seconds")
        }
    if isinstance(value, list):
        return [without_timings(item) for item in value]
    return value


if __name__ == "__main__":
    unittest.main()
