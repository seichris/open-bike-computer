#!/usr/bin/env python3

import hashlib
import unittest
from pathlib import Path


ASSET_DIR = Path(__file__).resolve().parents[2] / "lib" / "speaker" / "assets"
ORIGINAL_STEREO_SHA256 = {
    "real_bike_horn.pcm": "89c52c4817f2aa8510d8c66e750d62253b3e5163fd89df1e23ac2afbbf540f88",
    "rotating_bike_bell.pcm": "5719bd0f505722c9372b4425c61b1b05d810814e847df5967406b7d5a4b2d298",
    "squeeze_horn_a.pcm": "d833cb0d3f582fef4f2aa58b4b6946cf654be1442d9d84c6537efcb6c88e075d",
}


class SpeakerPcmAssetTests(unittest.TestCase):
    def test_mono_assets_expand_to_the_original_stereo_streams(self):
        for name, expected_digest in ORIGINAL_STEREO_SHA256.items():
            with self.subTest(asset=name):
                mono = (ASSET_DIR / name).read_bytes()
                self.assertGreater(len(mono), 0)
                self.assertEqual(len(mono) % 2, 0)
                stereo = b"".join(
                    mono[offset : offset + 2] * 2
                    for offset in range(0, len(mono), 2)
                )
                self.assertEqual(
                    hashlib.sha256(stereo).hexdigest(), expected_digest
                )


if __name__ == "__main__":
    unittest.main()
