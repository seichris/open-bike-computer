"""Exercise reported POI counts against bytes actually emitted by the CLI."""

import json
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


if __name__ == "__main__":
    unittest.main()
