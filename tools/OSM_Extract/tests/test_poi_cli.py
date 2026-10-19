"""Exercise reported POI counts against bytes actually emitted by the CLI."""

import json
import math
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PoiCLITests(unittest.TestCase):
    def test_source_halo_is_not_counted_as_emitted_pois(self):
        font = next((path for path in (
            Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
            Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf"),
        ) if path.is_file()), None)
        self.assertIsNotNone(font, "host font fixture is required")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefix = root / "features"
            for layer in ("lines", "polygons", "points"):
                features = []
                if layer == "points":
                    for identifier, x, tags in (
                        (1, 10, {"shop": "books"}),
                        (2, 9000, {"amenity": "cafe"}),
                    ):
                        features.append({
                            "type": "Feature",
                            "geometry": {"type": "Point", "coordinates": [x, 10]},
                            "properties": {"osm_id": str(identifier), **tags},
                        })
                Path(f"{prefix}_{layer}.geojson").write_text(json.dumps({
                    "type": "FeatureCollection", "features": features,
                }))
            result = subprocess.run([
                sys.executable, str(ROOT / "scripts/extract_features.py"),
                "0", "0", "0.02", "0.02", str(prefix), str(root / "map"),
                "--renderer-format", "5",
            ], env={**os.environ, "OBC_LABEL_LATIN_FONT": str(font),
                    "OBC_LABEL_CJK_FONT": str(font)},
                cwd=ROOT / "scripts", text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            stats = json.loads(next(line.removeprefix("POI_STATS:")
                for line in result.stdout.splitlines() if line.startswith("POI_STATS:")))
            blocks = list((root / "map").rglob("*.fmb"))
            self.assertEqual(len(blocks), 1)
            data = blocks[0].read_bytes()
            self.assertEqual(data[:8], b"FMB\x06\x00\x00\x00\x00")
            # Empty geometry puts EXT6 at byte 8; section 6 is its last entry.
            offset, length = struct.unpack_from("<II", data, 8 + 8 + 5 * 16 + 4)
            count = struct.unpack_from("<H", data, offset)[0]
            self.assertEqual(length, 8 + count * 8)
            self.assertEqual(count, 1)
            self.assertEqual(stats["recordCount"], count)
            self.assertEqual(stats["shopsCount"], 1)
            self.assertEqual(stats["restaurantsAndCafesCount"], 0)

    def test_output_blocks_bound_target5_selection_edge_features(self):
        font = next((path for path in (
            Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
            Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf"),
        ) if path.is_file()), None)
        self.assertIsNotNone(font, "host font fixture is required")
        radius = 6_378_137

        def lon(x):
            return math.degrees(x / radius)

        def lat(y):
            return math.degrees(2 * math.atan(math.exp(y / radius)) - math.pi / 2)

        def fmb_blocks(folder):
            blocks = set()
            for path in folder.rglob("*.fmb"):
                name = path.parent.name
                split = 1 + min(index for index, value in enumerate(name[1:]) if value in "+-")
                local_x, local_y = (int(value) for value in path.stem.split("_"))
                blocks.add((int(name[:split]) * 16 + local_x, int(name[split:]) * 16 + local_y))
            return blocks

        # Its 3x3 bbox grid includes blocks (1, 2), (2, 1) and (2, 2), none of
        # which intersects the triangle. The road starts inside the triangle,
        # so the whole-feature selection mask keeps it as it crosses (2, 2).
        coverage = [[0, 0], [0, 1], [0, 2], [1, 0], [1, 1], [2, 0]]
        triangle = [[lon(x), lat(y)] for x, y in ((100, 100), (12000, 100), (100, 12000), (100, 100))]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefix = root / "features"
            layers = {
                "lines": [{
                    "type": "Feature",
                    "geometry": {"type": "LineString", "coordinates": [[6000, 6000], [10000, 10000]]},
                    "properties": {"osm_id": "7", "highway": "primary"},
                }],
                "polygons": [],
                "points": [{
                    "type": "Feature",
                    "geometry": {"type": "Point", "coordinates": [500, 500]},
                    "properties": {"osm_id": "1", "shop": "books"},
                }],
            }
            for layer, features in layers.items():
                Path(f"{prefix}_{layer}.geojson").write_text(json.dumps({
                    "type": "FeatureCollection", "features": features,
                }))
            Path(f"{prefix}_building_relations.json").write_text(json.dumps({
                "schemaVersion": 1, "partParents": {}, "relations": 0, "ambiguousParts": 0,
            }))
            selection = root / "selection.geojson"
            selection.write_text(json.dumps({"type": "Polygon", "coordinates": [triangle]}))

            def extract(name, *extra, renderer="5"):
                return subprocess.run([
                    sys.executable, str(ROOT / "scripts/extract_features.py"),
                    str(lon(100)), str(lat(100)), str(lon(12000)), str(lat(12000)),
                    str(prefix), str(root / name), "--renderer-format", renderer,
                    "--selection-geometry", str(selection), *extra,
                ], env={**os.environ, "OBC_LABEL_LATIN_FONT": str(font),
                        "OBC_LABEL_CJK_FONT": str(font), "PYTHONDONTWRITEBYTECODE": "1"},
                    cwd=ROOT / "scripts", text=True, capture_output=True)

            def output_blocks(name, document):
                path = root / f"{name}.json"
                path.write_text(json.dumps(document))
                return path

            # Reproduction: the legacy grid emits the off-selection block.
            legacy = extract("legacy")
            self.assertEqual(legacy.returncode, 0, legacy.stdout + legacy.stderr)
            self.assertEqual(fmb_blocks(root / "legacy"), {(0, 0), (1, 1), (2, 2)})

            valid = {"schemaVersion": 1, "blockSizeMeters": 4096, "blocks": coverage}
            bounded = extract("bounded", "--output-blocks", output_blocks("coverage", valid))
            self.assertEqual(bounded.returncode, 0, bounded.stdout + bounded.stderr)
            self.assertEqual(fmb_blocks(root / "bounded"), {(0, 0), (1, 1)})
            stats = json.loads(next(line.removeprefix("POI_STATS:")
                for line in bounded.stdout.splitlines() if line.startswith("POI_STATS:")))
            self.assertEqual(stats["recordCount"], 1)

            for name, document in (
                ("unsorted", {**valid, "blocks": [[0, 1], [0, 0]]}),
                ("duplicate", {**valid, "blocks": [[0, 0], [0, 0]]}),
                ("boolean", {**valid, "blocks": [[0, True]]}),
                ("empty", {**valid, "blocks": []}),
                ("block-size", {**valid, "blockSizeMeters": 2048}),
                ("schema", {**valid, "schemaVersion": True}),
                ("extra-field", {**valid, "bounds": []}),
                ("outside-grid", {**valid, "blocks": [[0, 0], [3, 3]]}),
            ):
                with self.subTest(name):
                    rejected = extract(name, "--output-blocks", output_blocks(name, document))
                    self.assertEqual(rejected.returncode, 2, rejected.stdout + rejected.stderr)
                    failure = json.loads(next(line.removeprefix("POI_FAILURE:")
                        for line in rejected.stdout.splitlines() if line.startswith("POI_FAILURE:")))
                    self.assertEqual(failure["code"], "poi_artifact_validation_failed")
                    self.assertFalse(list((root / name).rglob("*.fmb")))

            missing = extract("missing", "--output-blocks", str(root / "absent.json"))
            self.assertEqual(missing.returncode, 2, missing.stdout + missing.stderr)
            self.assertIn("POI_FAILURE:", missing.stdout)
            target3 = extract("target3", "--output-blocks", output_blocks("coverage", valid),
                              renderer="3")
            self.assertEqual(target3.returncode, 2)
            self.assertIn("--output-blocks requires renderer format 5", target3.stderr)


if __name__ == "__main__":
    unittest.main()
