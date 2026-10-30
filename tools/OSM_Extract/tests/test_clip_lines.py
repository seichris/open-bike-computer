import json
import math
import os
import pathlib
import random
import subprocess
import sys
import tempfile
import unittest
from collections import Counter

from shapely import LineString, box, intersection


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from funcs import clip_lines  # noqa: E402


EARTH_RADIUS_METERS = 6_378_137
HOST_FONT_CANDIDATES = (
    pathlib.Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
    pathlib.Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf"),
)
# Enters block (4096, 4096) from the left, leaves through its bottom edge and
# then touches that edge again only at (4296, 4096).
TOUCHING_ROAD = [
    (4086, 4196), (4196, 4196), (4196, 4086),
    (4296, 4086), (4296, 4096), (4396, 4086),
]


def block_box(min_x, min_y):
    # The exact block geometry extract_features.py clips with.
    return box(min_x, min_y, min_x + 4095, min_y + 4096)


def expected_line_parts(line, block):
    """Line parts the clip must emit: the whole result when it is a line or
    multiline, otherwise only the LineString components, in GEOS order."""
    if not block.intersects(line) or block.touches(line):
        return []
    result = intersection(line, block)
    if not result.is_valid:
        return []
    parts = [result] if result.geom_type == "LineString" else [
        part for part in result.geoms if part.geom_type == "LineString"
    ]
    return [part.wkb for part in parts if part.is_valid]


class ClipLinesTests(unittest.TestCase):
    def test_boundary_touch_points_are_dropped_beside_line_parts(self):
        block = block_box(0, 0)
        line = LineString(
            [(-10, 100), (100, 100), (100, -10), (200, -10), (200, 0), (300, -10)]
        )
        self.assertEqual(intersection(line, block).geom_type, "GeometryCollection")
        diagnostics = {}
        clipped = clip_lines(
            [
                {
                    "id": 1,
                    "geom": line,
                    "label_tags": {"name": "Spike Road"},
                    "label_candidates": [
                        {"midpoint": (50.0, 100.0)},
                        {"midpoint": (200.0, 0.0)},
                    ],
                }
            ],
            block,
            label_diagnostics=diagnostics,
        )
        self.assertEqual(
            [feature["geom"].wkt for feature in clipped],
            ["LINESTRING (0 100, 100 100, 100 0)"],
        )
        self.assertEqual(clipped[0]["bbox"], (0.0, 0.0, 100.0, 100.0))
        # The touch point owns no label: its candidate is rejected, not drawn.
        self.assertEqual(clipped[0]["label_candidates"], [{"midpoint": (50.0, 100.0)}])
        self.assertEqual(
            diagnostics,
            {
                "namedRoadsClipped": 1,
                "clippedCandidates": 1,
                "candidatesRejectedByBlockOwnership": 1,
            },
        )

    def test_every_line_result_keeps_its_line_parts_in_order(self):
        # Integer coordinates on a coarse grid make exact boundary contacts
        # common, so every GEOS result shape is exercised.
        random_source = random.Random(20261030)
        block = box(0, 0, 100, 101)
        shapes = Counter()
        for _ in range(4_000):
            line = LineString(
                [
                    (random_source.randint(-8, 28) * 5, random_source.randint(-8, 28) * 5)
                    for _ in range(random_source.randint(2, 7))
                ]
            )
            if line.is_empty or not line.is_valid:
                continue
            if block.intersects(line) and not block.touches(line):
                shapes[intersection(line, block).geom_type] += 1
            with self.subTest(line=line.wkt):
                self.assertEqual(
                    [feature["geom"].wkb for feature in clip_lines([{"geom": line}], block)],
                    expected_line_parts(line, block),
                )
        for shape in ("LineString", "MultiLineString", "GeometryCollection"):
            self.assertGreater(shapes[shape], 10, shape)

    def test_extract_features_keeps_a_road_that_touches_a_block_edge(self):
        host_font = next(
            (path for path in HOST_FONT_CANDIDATES if path.is_file()),
            None,
        )
        self.assertIsNotNone(host_font, "host font fixture is unavailable")
        self.assertEqual(
            intersection(LineString(TOUCHING_ROAD), block_box(4096, 4096)).geom_type,
            "GeometryCollection",
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "features_lines.geojson").write_text(
                json.dumps(
                    {
                        "type": "FeatureCollection",
                        "features": [
                            {
                                "type": "Feature",
                                "properties": {
                                    "osm_id": 1,
                                    "highway": "residential",
                                    "name": "Edge Road",
                                },
                                "geometry": {
                                    "type": "LineString",
                                    "coordinates": [list(point) for point in TOUCHING_ROAD],
                                },
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            (root / "features_polygons.geojson").write_text(
                json.dumps({"type": "FeatureCollection", "features": []}),
                encoding="utf-8",
            )
            environment = os.environ.copy()
            environment.update(
                {
                    "OBC_LABEL_LATIN_FONT": str(host_font),
                    "OBC_LABEL_CJK_FONT": str(host_font),
                }
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "extract_features.py"),
                    str(math.degrees(100 / EARTH_RADIUS_METERS)),
                    str(mercator_latitude(100)),
                    str(math.degrees(8_000 / EARTH_RADIUS_METERS)),
                    str(mercator_latitude(8_000)),
                    str(root / "features"),
                    str(root / "map"),
                    "--renderer-format",
                    "3",
                    "--preferred-language",
                    "en",
                ],
                cwd=ROOT / "scripts",
                env=environment,
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )
            # Block (1, 1) holds the clipped road beside the touch point.
            self.assertTrue((root / "map" / "+000+000" / "1_1.fmb").is_file())


def mercator_latitude(y):
    return math.degrees(2 * math.atan(math.exp(y / EARTH_RADIUS_METERS)) - math.pi / 2)


if __name__ == "__main__":
    unittest.main()
