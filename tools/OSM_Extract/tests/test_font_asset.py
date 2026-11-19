import json
import os
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


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

    def require_worker_fonts(self):
        if (
            os.getenv("OBC_REQUIRE_WORKER_FONTS") != "1"
            and not pathlib.Path(
                "/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf"
            ).is_file()
        ):
            self.skipTest("Linux map worker fonts are unavailable")

    def test_native_arabic_road_labels_work_with_latin_and_cjk_preferences(self):
        self.require_worker_fonts()
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

    def test_packaged_fonts_build_multilingual_map_with_unrenderable_labels(self):
        self.require_worker_fonts()
        unsupported = "Unrenderable \U0010fffd"
        names = ["Οδός Αθηνάς", "ถนนสุขุมวิท", "नई दिल्ली", "דרך יפו", "улица Арбат"]
        roads = [
            ("1", unsupported, {"other_tags": f'"name:el"=>"{names[0]}"', "ref": "A1"}),
            *((str(index), name, {}) for index, name in enumerate(names[1:], 2)),
            ("6", unsupported, {}),
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            features = [
                {
                    "type": "Feature",
                    "properties": {"osm_id": key, "highway": "primary", "name": name, **tags},
                    "geometry": {
                        "type": "LineString",
                        "coordinates": [[100, index * 300], [3000, index * 300]],
                    },
                }
                for index, (key, name, tags) in enumerate(roads, 1)
            ]
            for layer, features_for_layer in (("lines", features), ("polygons", [])):
                (root / f"map_{layer}.geojson").write_text(
                    json.dumps({"type": "FeatureCollection", "features": features_for_layer}),
                    encoding="utf-8",
                )
            finished = subprocess.run(
                [
                    sys.executable, "extract_features.py",
                    "0", "0", "0.03", "0.03", str(root / "map"), str(root / "out"),
                    "--renderer-format", "2", "--preferred-language", "el",
                ],
                cwd=ROOT / "scripts", text=True, capture_output=True, timeout=120,
            )
            self.assertEqual(finished.returncode, 0, finished.stdout + finished.stderr)
            block, = (root / "out").rglob("*.fmb")
            block_data = block.read_bytes()
            for name in (*names, "A1"):
                self.assertIn(name.encode(), block_data)
            self.assertNotIn(unsupported.encode(), block_data)
            stats = next(line for line in finished.stdout.splitlines() if line.startswith("LABEL_STATS:"))
            self.assertEqual(json.loads(stats.partition(":")[2])["diagnostics"]["unsupportedLabelVariants"], 2)
            font = (root / "out" / "assets" / "street-labels.fma").read_bytes()
            self.assertGreater(len(default_font_faces()), 16)
            self.assertTrue(1 <= font[7] <= 16)
            self.assertIn(b"NotoSansThai", font)
            self.assertIn(b"NotoSansDevanagari", font)

    def test_glyph_budget_rejects_a_variant_without_partially_allocating_it(self):
        self.require_worker_fonts()
        builder = FontPackBuilder(faces=(default_font_faces()[0],))
        builder.shape("A")
        with patch("font_asset.MAX_DISTINCT_GLYPHS", 2):
            self.assertIsNone(builder.measure_supported_widths("ABC"))
            self.assertEqual(builder.glyph_count, 1)
            self.assertIsNotNone(builder.measure_supported_widths("AB"))
            self.assertEqual(builder.glyph_count, 2)


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
