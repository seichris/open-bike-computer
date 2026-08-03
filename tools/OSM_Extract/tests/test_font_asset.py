import pathlib
import struct
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from font_asset import (
    FMA_MAGIC,
    FMA_VERSION,
    FontFaceSpec,
    FontPackBuilder,
    rle_decode,
    rle_encode,
)


FONT_PATH = pathlib.Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf")


@unittest.skipUnless(FONT_PATH.is_file(), "host font fixture is unavailable")
class FontAssetTests(unittest.TestCase):
    def builder(self):
        return FontPackBuilder(
            preferred_languages=["zh-Hant", "en"],
            faces=(FontFaceSpec(0, FONT_PATH, 0, "latin-cjk"),),
        )

    def test_multilingual_runs_share_map_wide_glyph_ids(self):
        builder = self.builder()
        latin = builder.shape("Main Street", "en")
        chinese = builder.shape("皇后大道東", "zh-Hant")

        self.assertEqual(len(latin), 3)
        self.assertEqual(len(chinese), 3)
        self.assertGreater(builder.glyph_count, 5)
        self.assertEqual(
            [glyph.glyph_id for glyph in latin[0].glyphs],
            [glyph.glyph_id for glyph in latin[1].glyphs],
        )

    def test_measurement_matches_runtime_advance_and_reuses_shaping(self):
        builder = self.builder()

        widths = builder.measure_widths("Main Street", "en")
        shaped = builder.shape("Main Street", "en")

        expected = tuple(
            abs(sum(glyph.x_advance for glyph in run.glyphs)) / 64.0
            for run in shaped
        )
        self.assertEqual(widths, expected)
        self.assertEqual(builder.shape_calls, 2)
        self.assertEqual(builder.shape_cache_hits, 1)

    def test_fma1_output_is_deterministic_and_self_describing(self):
        def generate(path):
            builder = self.builder()
            builder.shape("Queen's Road East", "en")
            builder.shape("皇后大道東", "zh-Hant")
            metadata = builder.write(path)
            return path.read_bytes(), metadata

        with tempfile.TemporaryDirectory() as directory:
            first, first_metadata = generate(pathlib.Path(directory) / "first.fma")
            second, second_metadata = generate(pathlib.Path(directory) / "second.fma")

        self.assertEqual(first, second)
        self.assertEqual(first_metadata, second_metadata)
        self.assertEqual(first[:4], FMA_MAGIC)
        self.assertEqual(first[4], FMA_VERSION)
        self.assertEqual(struct.unpack_from("<I", first, 8)[0], first_metadata["profileFingerprint"])
        self.assertGreater(first_metadata["uncompressedBitmapBytes"], 0)
        self.assertGreater(first_metadata["compressedBitmapBytes"], 0)
        self.assertGreater(first_metadata["compressionRatio"], 0)
        self.assertEqual(first_metadata["shapeCalls"], 2)
        self.assertEqual(first_metadata["shapingFailures"], 0)

    def test_rle_round_trip_and_truncation(self):
        values = [0] * 20 + [1, 2, 3, 4] + [15] * 18
        encoded = rle_encode(values)

        self.assertEqual(rle_decode(encoded, len(values)), values)
        with self.assertRaises(ValueError):
            rle_decode(encoded[:-1], len(values))

    def test_rle_literal_run_never_crosses_128_byte_boundary(self):
        values = [index % 16 for index in range(127)] + [7, 7, 8, 9]

        encoded = rle_encode(values)

        self.assertEqual(encoded[0], 127)
        self.assertEqual(rle_decode(encoded, len(values)), values)

    def test_rle_round_trips_long_literal_sequences(self):
        for length in (128, 129, 255, 256, 257, 1024):
            with self.subTest(length=length):
                values = [index % 16 for index in range(length)]
                encoded = rle_encode(values)

                self.assertEqual(rle_decode(encoded, length), values)


if __name__ == "__main__":
    unittest.main()
