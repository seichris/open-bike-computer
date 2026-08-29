import pathlib
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
import zlib


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from map_format import (
    MAX_BLOCK_BUILDINGS,
    MapFormatError,
    MapFormatLimitError,
    encode_building_section,
    write_fmb,
)
from font_asset import FontFaceSpec, FontPackBuilder


FONT_PATH = pathlib.Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf")
GOLDEN_FIXTURE_PATH = (
    pathlib.Path(__file__).resolve().parents[3]
    / "tools"
    / "tests"
    / "fixtures"
    / "fmb"
    / "golden_blocks.txt"
)


def golden_fmb_blocks():
    fixtures = {}
    for raw_line in GOLDEN_FIXTURE_PATH.read_text(encoding="ascii").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        name, encoded = line.split("=", 1)
        fixtures[name] = bytes.fromhex(encoded)
    return fixtures


class PolygonGeometry:
    def __init__(self, coordinates):
        self.exterior = self
        self.coords = coordinates


class LineGeometry:
    def __init__(self, coordinates):
        self.coords = coordinates


class GoldenFontBuilder:
    languages = []
    profile_fingerprint = 0x12345678

    @staticmethod
    def shape(_text, _language):
        return tuple(
            SimpleNamespace(
                size_id=size_id,
                glyphs=(
                    SimpleNamespace(
                        glyph_id=1,
                        x_offset=0,
                        y_offset=0,
                        x_advance=640,
                    ),
                ),
            )
            for size_id in range(3)
        )


def feature(feature_type, geometry, width=None):
    return {
        "type": feature_type,
        "color": "0x1234",
        "width": width,
        "maxzoom": "",
        "bbox": (0, 0, 10, 10),
        "geom": geometry,
    }


def skip_coordinates(data, offset):
    coordinate_count = struct.unpack_from("<H", data, offset)[0]
    return offset + 2 + coordinate_count * 4


def golden_features():
    polygon = feature(
        "building.residential",
        PolygonGeometry([(0, 0), (10, 0), (10, 10), (0, 10)]),
    )
    road = feature(
        "highway.residential",
        LineGeometry([(0, 0), (10, 10)]),
        2,
    )
    road.update(
        {
            "label_rank": 1,
            "label_variants": [{"kind": "local", "text": "Main"}],
            "label_candidates": [
                {
                    "start": (0, 0),
                    "end": (10, 10),
                    "quality": 240,
                    "flags": 0,
                }
            ],
        }
    )
    building = {
        "type_id": 100,
        "flags": 1,
        "provenance": 0,
        "height_dm": 123,
        "minimum_height_dm": 20,
        "bbox": (0, 0, 10, 10),
        "rings": [
            {
                "flags": 0,
                "points": [(0, 0), (10, 0), (10, 10), (0, 10)],
                "walls": [True, True, True, True],
            }
        ],
    }
    return polygon, road, building


class BinaryMapFormatTests(unittest.TestCase):
    def test_shared_golden_blocks_match_producer_bytes(self):
        fixtures = golden_fmb_blocks()
        self.assertEqual(set(fixtures), {"fmb_v1", "fmb_v2", "fmb_v3", "fmb_v4"})
        self.assertEqual(fixtures["fmb_v1"][:4], b"FMB\x01")

        polygon, road, building = golden_features()
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            expected_versions = {
                "fmb_v2": write_fmb(root / "v2.fmb", [polygon], [road], 0, 0),
                "fmb_v3": write_fmb(
                    root / "v3.fmb",
                    [polygon],
                    [road],
                    0,
                    0,
                    font_builder=GoldenFontBuilder(),
                ),
                "fmb_v4": write_fmb(
                    root / "v4.fmb",
                    [polygon],
                    [road],
                    0,
                    0,
                    font_builder=GoldenFontBuilder(),
                    building_records=[building],
                ),
            }
            generated = {
                "fmb_v2": (root / "v2.fmb").read_bytes(),
                "fmb_v3": (root / "v3.fmb").read_bytes(),
                "fmb_v4": (root / "v4.fmb").read_bytes(),
            }

        for name, version in (("fmb_v2", 2), ("fmb_v3", 3), ("fmb_v4", 4)):
            self.assertEqual(expected_versions[name]["version"], version)
            self.assertEqual(generated[name], fixtures[name])

    def test_fmb_records_use_classified_feature_type_bytes(self):
        polygon = feature(
            "building.residential",
            PolygonGeometry([(0, 0), (10, 0), (10, 10), (0, 0)]),
        )
        polylines = [
            feature("highway.residential", LineGeometry([(0, 0), (10, 10)]), 2),
            feature("highway.service", LineGeometry([(0, 10), (10, 0)]), 1),
        ]

        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "0_0.fmb"
            write_fmb(path, [polygon], polylines, min_x=0, min_y=0)
            data = path.read_bytes()

        self.assertEqual(data[:4], b"FMB\x02")
        self.assertEqual(struct.unpack_from("<H", data, 4)[0], 1)

        polygon_offset = 6
        self.assertEqual(data[polygon_offset + 3], 100)
        offset = skip_coordinates(data, polygon_offset + 12)

        self.assertEqual(struct.unpack_from("<H", data, offset)[0], 2)
        offset += 2
        self.assertEqual(data[offset + 4], 7)
        offset = skip_coordinates(data, offset + 13)
        self.assertEqual(data[offset + 4], 10)

    @unittest.skipUnless(FONT_PATH.is_file(), "host font fixture is unavailable")
    def test_fmb_v3_has_deduplicated_utf8_runs_and_label_candidates(self):
        road = feature(
            "highway.residential",
            LineGeometry([(0, 0), (180, 0)]),
            4,
        )
        road.update(
            {
                "label_rank": 3,
                "label_variants": [
                    {"kind": "local", "text": "皇后大道東"},
                    {"kind": "preferred", "language": "en", "text": "Queen's Road East"},
                ],
                "label_candidates": [
                    {
                        "start": (10, 0),
                        "end": (170, 0),
                        "midpoint": (90, 0),
                        "quality": 240,
                        "flags": 0,
                    }
                ],
            }
        )
        builder = FontPackBuilder(
            preferred_languages=["en"],
            faces=(FontFaceSpec(0, FONT_PATH, 0, "latin-cjk"),),
        )

        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "0_0.fmb"
            metadata = write_fmb(
                path,
                [],
                [road],
                min_x=0,
                min_y=0,
                font_builder=builder,
            )
            data = path.read_bytes()

        self.assertEqual(data[:4], b"FMB\x03")
        self.assertEqual(metadata["labels"], 1)
        self.assertEqual(metadata["strings"], 2)
        self.assertEqual(metadata["runs"], 6)
        self.assertEqual(metadata["candidates"], 1)

        offset = 6  # magic + zero polygons
        self.assertEqual(struct.unpack_from("<H", data, offset)[0], 1)
        offset += 2
        offset = skip_coordinates(data, offset + 13)
        self.assertEqual(data[offset : offset + 4], b"EXT3")
        section_count = data[offset + 4]
        self.assertEqual(section_count, 3)
        offset += 8
        sections = {}
        for _ in range(section_count):
            section_type, flags, reserved, section_offset, length, crc = struct.unpack_from(
                "<BBHIII", data, offset
            )
            self.assertEqual(flags, 1)
            self.assertEqual(reserved, 0)
            body = data[section_offset : section_offset + length]
            self.assertEqual(zlib.crc32(body) & 0xFFFFFFFF, crc)
            sections[section_type] = body
            offset += 16

        self.assertIn("皇后大道東".encode("utf-8"), sections[1])
        self.assertIn(b"Queen's Road East", sections[1])
        self.assertEqual(struct.unpack_from("<H", sections[2], 0)[0], 6)
        self.assertEqual(struct.unpack_from("<H", sections[3], 4)[0], 1)

    def test_fmb_v3_keeps_language_specific_runs_for_identical_text(self):
        road = feature(
            "highway.residential",
            LineGeometry([(0, 0), (180, 0)]),
            4,
        )
        road.update(
            {
                "label_rank": 3,
                "label_variants": [
                    {"kind": "local", "text": "道路"},
                    {"kind": "preferred", "language": "ja", "text": "道路"},
                ],
                "label_candidates": [
                    {
                        "start": (10, 0),
                        "end": (170, 0),
                        "midpoint": (90, 0),
                        "quality": 240,
                        "flags": 0,
                    }
                ],
            }
        )

        class LanguageAwareBuilder:
            languages = ["ja"]
            profile_fingerprint = 0x12345678

            @staticmethod
            def shape(_text, language):
                glyph_base = 100 if language == "ja" else 1
                return tuple(
                    SimpleNamespace(
                        size_id=size_id,
                        glyphs=(
                            SimpleNamespace(
                                glyph_id=glyph_base + size_id,
                                x_offset=0,
                                y_offset=0,
                                x_advance=64,
                            ),
                        ),
                    )
                    for size_id in range(3)
                )

        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "0_0.fmb"
            metadata = write_fmb(
                path,
                [],
                [road],
                min_x=0,
                min_y=0,
                font_builder=LanguageAwareBuilder(),
            )
            data = path.read_bytes()

        self.assertEqual(metadata["strings"], 1)
        self.assertEqual(metadata["runs"], 6)

        offset = skip_coordinates(data, 8 + 13)
        self.assertEqual(data[offset : offset + 4], b"EXT3")
        section_count = data[offset + 4]
        offset += 8
        sections = {}
        for _ in range(section_count):
            section_type, _flags, _reserved, section_offset, length, _crc = (
                struct.unpack_from("<BBHIII", data, offset)
            )
            sections[section_type] = data[section_offset : section_offset + length]
            offset += 16

        labels = sections[3]
        first_variant_runs = struct.unpack_from("<HHH", labels, 6 + 9 + 4)
        second_variant_runs = struct.unpack_from("<HHH", labels, 6 + 9 + 10 + 4)
        self.assertNotEqual(first_variant_runs, second_variant_runs)

    def test_fmb_v4_retains_labels_and_adds_canonical_building_section(self):
        class EmptyBuilder:
            languages = []
            profile_fingerprint = 0x12345678

            @staticmethod
            def shape(_text, _language):
                return ()

        building = {
            "type_id": 100,
            "flags": 2,
            "provenance": 0,
            "height_dm": 125,
            "minimum_height_dm": 0,
            "bbox": (0, 0, 10, 10),
            "rings": [
                {
                    "flags": 0,
                    "points": [(0, 0), (10, 0), (10, 10), (0, 10)],
                    "walls": [False, False, False, False],
                }
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "0_0.fmb"
            metadata = write_fmb(
                path,
                [],
                [],
                min_x=0,
                min_y=0,
                font_builder=EmptyBuilder(),
                building_records=[building],
            )
            data = path.read_bytes()
            section, section_metadata = encode_building_section([building])
            cached_path = pathlib.Path(directory) / "cached.fmb"
            cached_metadata = write_fmb(
                cached_path,
                [],
                [],
                min_x=0,
                min_y=0,
                font_builder=EmptyBuilder(),
                building_section=section,
                building_metadata=section_metadata,
            )
            cached_data = cached_path.read_bytes()

        self.assertEqual(data[:4], b"FMB\x04")
        self.assertEqual(cached_data, data)
        self.assertEqual(cached_metadata, metadata)
        self.assertEqual(metadata["buildings"], 1)
        self.assertEqual(metadata["buildingPoints"], 4)
        directory_offset = 8
        self.assertEqual(data[directory_offset:directory_offset + 4], b"EXT4")
        self.assertEqual(data[directory_offset + 4], 4)
        entry = directory_offset + 8 + 3 * 16
        section_type, flags, reserved, offset, length, crc = struct.unpack_from(
            "<BBHIII", data, entry
        )
        self.assertEqual((section_type, flags, reserved), (4, 1, 0))
        body = data[offset:offset + length]
        self.assertEqual(zlib.crc32(body) & 0xFFFFFFFF, crc)
        self.assertEqual(struct.unpack_from("<HHI", body, 0), (1, 0, 4))
        self.assertEqual(body[9], 2)
        self.assertEqual(body[-1], 0)

        building["flags"] = 3
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(MapFormatError, "metadata is invalid"):
                write_fmb(
                    pathlib.Path(directory) / "0_0.fmb",
                    [],
                    [],
                    min_x=0,
                    min_y=0,
                    font_builder=EmptyBuilder(),
                    building_records=[building],
                )

    def test_fmb_v4_admits_measured_dense_singapore_record_pressure(self):
        _polygon, _road, building = golden_features()
        measured_record_count = 9265

        self.assertEqual(MAX_BLOCK_BUILDINGS, 12288)
        section, metadata = encode_building_section(
            [building] * measured_record_count
        )

        self.assertGreater(len(section), 0)
        self.assertEqual(metadata["buildings"], measured_record_count)
        self.assertEqual(metadata["buildingPoints"], measured_record_count * 4)
        with self.assertRaisesRegex(
            MapFormatLimitError,
            "building record count exceeds FMB v4 limits",
        ) as raised:
            encode_building_section([building] * (MAX_BLOCK_BUILDINGS + 1))
        self.assertEqual(raised.exception.code, "building_artifact_too_large")


if __name__ == "__main__":
    unittest.main()
