"""Fast generated-asset drift and Swift composition checks; no network required.

Actual LVGL pixel regeneration is performed by generate_ride_stats_preview.py
--check against its pinned source. This fast suite needs only Python's standard
library (and optionally the Swift compiler), including on fresh CI runners.
"""
from __future__ import annotations
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / 'ios-app/BikeComputer/BikeComputer/Assets.xcassets'
SPEC_PATH = ASSETS / 'RideStatsPreview.dataset/preview.json'


class RideStatsPreviewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec = json.loads(SPEC_PATH.read_text())
        contract = json.loads((ROOT / 'protocol/ride-ble-contract-v1.json').read_text())
        cls.widget_ids = set(contract['ride_stats_widgets'].values())

    def test_generated_renderer_inputs_are_current(self):
        module_spec = importlib.util.spec_from_file_location(
            'ride_preview_generator', ROOT / 'tools/generate_ride_stats_preview.py')
        generator = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(generator)
        self.assertEqual(self.spec['sourceHashes'], generator.source_hashes(),
                         'Regenerate the Ride Stats preview after renderer changes')
        self.assertEqual(self.spec['lvglCommit'], generator.LVGL_COMMIT)

    def test_complete_widget_and_row_pair_coverage(self):
        self.assertEqual(self.spec['schema'], 1)
        self.assertEqual(len(self.spec['boards']), 8)
        for target, width, height, round_screen in [
            ('175', 466, 466, True), ('206', 410, 502, False)
        ]:
            for sensors in range(4):
                board = self.spec['boards'][f'WAVESHARE_AMOLED_{target}:{sensors}']
                self.assertEqual((board['width'], board['height'], board['round']),
                                 (width, height, round_screen))
                self.assertEqual(set(board['normal']),
                                 {f'{slot}:{widget}' for slot in range(7) for widget in self.widget_ids})
                self.assertEqual(set(board['pairs']),
                                 {f'{row}:{left}:{right}' for row in range(3)
                                  for left in self.widget_ids for right in (7, 16)})
                for row in range(3):
                    for left in (1, 2, 4, 5, 6, 8, 11, 12, 13, 14, 15):
                        pair = board['pairs'][f'{row}:{left}:7']
                        a, b = pair['fonts'][row * 2 + 1:row * 2 + 3]
                        self.assertGreater(a, 0)
                        self.assertEqual(a, b, 'Altitude must use the same font as its left peer')
                if sensors == 0:
                    pair = board['pairs']['2:15:16']
                    self.assertEqual(pair['fonts'][5], pair['fonts'][6])

    def test_sprite_references_and_native_pixel_bounds(self):
        png = (ASSETS / 'RideStatsPreviewAtlas.imageset/atlas.png').read_bytes()
        self.assertEqual(png[:8], b'\x89PNG\r\n\x1a\n')
        atlas_width, atlas_height = struct.unpack('>II', png[16:24])
        self.assertLess(len(png), 1024 * 1024)
        for x, y, width, height in self.spec['sprites'].values():
            self.assertGreater(width, 0)
            self.assertGreater(height, 0)
            self.assertGreaterEqual(x, 0)
            self.assertGreaterEqual(y, 0)
            self.assertLessEqual(x + width, atlas_width)
            self.assertLessEqual(y + height, atlas_height)
        for board in self.spec['boards'].values():
            for tile in list(board['normal'].values()) + list(board['pairs'].values()):
                self.assertEqual(len(tile['fonts']), 7)
                x, y, width, height = tile['bounds']
                self.assertGreaterEqual(x, 0)
                self.assertGreaterEqual(y, 0)
                self.assertLessEqual(x + width, board['width'])
                self.assertLessEqual(y + height, board['height'])
                if tile['sprite'] is not None:
                    source = self.spec['sprites'][tile['sprite']]
                    self.assertEqual(source[2:], [width, height])

    def test_swift_preview_composition(self):
        compiler = shutil.which('swiftc')
        if not compiler:
            self.skipTest('Swift compiler is not installed on this host')
        with tempfile.TemporaryDirectory(prefix='ride-preview-spec-') as directory:
            binary = str(Path(directory) / 'spec')
            subprocess.run([
                compiler, '-parse-as-library', '-o', binary,
                str(ROOT / 'ios-app/BikeComputer/RideShared/RideBLEProtocol.generated.swift'),
                str(ROOT / 'ios-app/BikeComputer/BikeComputer/Models/RideStatsPreviewSpec.swift'),
                str(ROOT / 'tools/ride_stats_preview/spec_contract.swift')
            ], check=True, timeout=90)
            subprocess.run([binary, str(SPEC_PATH)], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
