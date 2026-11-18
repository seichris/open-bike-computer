import os
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
    FONT_SIZES,
    FontFaceSpec,
    FontPackBuilder,
    default_font_faces,
    rle_decode,
    rle_encode,
)


FONT_PATH = pathlib.Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf")


class FontAssetPolicyTests(unittest.TestCase):
    def test_font_tiers_start_at_the_previous_large_size(self):
        self.assertEqual(FONT_SIZES, (18, 22, 26))

    def test_native_arabic_road_labels_work_with_latin_and_cjk_preferences(self):
        if (
            os.getenv("OBC_REQUIRE_WORKER_FONTS") != "1"
            and not pathlib.Path(
                "/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf"
            ).is_file()
        ):
            self.skipTest("Linux map worker fonts are unavailable")
        faces = {face.name: face.face_id for face in default_font_faces()}
        for text, language, face, visual_prefix in (
            ("Main Street", "en", "latin", ""),
            ("皇后大道東", "zh-Hans", "cjk-sc", ""),
            ("قناة دبي", None, "arabic", ""),
            ("قناة دبي D92", None, "arabic-latin", "D92"),
            ("E11 شارع الشيخ زايد", None, "arabic-latin", "E11"),
            ("شارع ١٥", None, "arabic", "١٥"),
        ):
            with self.subTest(text=text):
                builder = FontPackBuilder(preferred_languages=["en-US", "zh-Hans-US"])
                runs = builder.shape(text, language)

                self.assertEqual(len(runs), len(FONT_SIZES))
                self.assertTrue(all(run.glyphs for run in runs))
                self.assertEqual(
                    {face_id for face_id, _ in builder._asset_id_by_key},
                    {faces[face]},
                )
                if visual_prefix:
                    for run, size in zip(runs, FONT_SIZES):
                        font = builder._harfbuzz_font(builder._face_by_id[faces[face]], size)
                        expected = [
                            builder._asset_id_by_key[
                                (faces[face], font.get_nominal_glyph(ord(char)))
                            ]
                            for char in visual_prefix
                        ]
                        actual = [glyph.glyph_id for glyph in run.glyphs]
                        self.assertEqual(actual[:len(expected)], expected)


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

    def test_uncached_labels_reuse_scaled_harfbuzz_fonts(self):
        builder = self.builder()

        builder.shape("Main Street", "en")
        builder.shape("Queen's Road", "en")

        self.assertEqual(len(builder._hb_faces), len(FONT_SIZES))
        self.assertEqual(len(builder._hb_fonts), len(FONT_SIZES))
        self.assertEqual(builder.shape_cache_hits, 0)
        self.assertEqual(builder.shaping_failures, 0)

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
