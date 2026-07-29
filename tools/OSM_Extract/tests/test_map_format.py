import pathlib
import struct
import sys
import tempfile
import unittest
import zlib


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from map_format import write_fmb
from font_asset import FontFaceSpec, FontPackBuilder


FONT_PATH = pathlib.Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf")


class PolygonGeometry:
    def __init__(self, coordinates):
        self.exterior = self
        self.coords = coordinates


class LineGeometry:
    def __init__(self, coordinates):
        self.coords = coordinates


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


class BinaryMapFormatTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
