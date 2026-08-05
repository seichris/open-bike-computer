import json
import math
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
EARTH_RADIUS_METERS = 6_378_137
HOST_FONT_CANDIDATES = (
    pathlib.Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
    pathlib.Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf"),
)


class Target3CLITests(unittest.TestCase):
    def test_target_three_cli_emits_closed_line_parts_and_edge_blocks(self):
        host_font = next(
            (path for path in HOST_FONT_CANDIDATES if path.is_file()),
            None,
        )
        self.assertIsNotNone(host_font, "host font fixture is unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            prefix = root / "features"
            output = root / "map"
            (root / "features_lines.geojson").write_text(
                json.dumps(
                    {
                        "type": "FeatureCollection",
                        "features": [
                            {
                                "type": "Feature",
                                "properties": {
                                    "osm_id": 20,
                                    "other_tags": (
                                        '"building:part"=>"yes",'
                                        '"height"=>"12"'
                                    ),
                                },
                                "geometry": {
                                    "type": "LineString",
                                    "coordinates": [
                                        [200, 200],
                                        [800, 200],
                                        [800, 800],
                                        [200, 800],
                                        [200, 200],
                                    ],
                                },
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            (root / "features_polygons.geojson").write_text(
                json.dumps(
                    {
                        "type": "FeatureCollection",
                        "features": [
                            {
                                "type": "Feature",
                                "properties": {
                                    "osm_way_id": 10,
                                    "building": "yes",
                                    "other_tags": '"height"=>"20"',
                                },
                                "geometry": {
                                    "type": "MultiPolygon",
                                    "coordinates": [[[
                                        [100, 100],
                                        [900, 100],
                                        [900, 900],
                                        [100, 900],
                                        [100, 100],
                                    ]]],
                                },
                            },
                            {
                                "type": "Feature",
                                "properties": {
                                    "osm_way_id": 30,
                                    "building": "yes",
                                    "other_tags": '"height"=>"10"',
                                },
                                "geometry": {
                                    "type": "MultiPolygon",
                                    "coordinates": [[[
                                        [8193, 100],
                                        [8199, 100],
                                        [8199, 106],
                                        [8193, 106],
                                        [8193, 100],
                                    ]]],
                                },
                            },
                        ],
                    }
                ),
                encoding="utf-8",
            )
            (root / "features_building_relations.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "partParents": {"w20": "w10"},
                        "relations": 1,
                        "ambiguousParts": 0,
                    }
                ),
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
                    "0",
                    str(math.degrees(8200 / EARTH_RADIUS_METERS)),
                    str(
                        math.degrees(
                            2 * math.atan(math.exp(1000 / EARTH_RADIUS_METERS))
                            - math.pi / 2
                        )
                    ),
                    str(prefix),
                    str(output),
                    "--renderer-format",
                    "3",
                    "--preferred-language",
                    "en",
                ],
                cwd=ROOT / "scripts",
                check=False,
                env=environment,
                text=True,
                capture_output=True,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )

            stats_line = next(
                line for line in result.stdout.splitlines()
                if line.startswith("BUILDING_STATS:")
            )
            stats = json.loads(stats_line.removeprefix("BUILDING_STATS:"))
            self.assertEqual(stats["partCount"], 1)
            self.assertEqual(stats["relationAssociationCount"], 1)
            self.assertEqual(stats["recordCount"], 3)
            blocks = list(output.rglob("*.fmb"))
            self.assertEqual(len(blocks), 2)
            self.assertTrue(
                all(block.read_bytes()[:4] == b"FMB\x04" for block in blocks)
            )
            self.assertTrue((output / "assets" / "street-labels.fma").is_file())


if __name__ == "__main__":
    unittest.main()
