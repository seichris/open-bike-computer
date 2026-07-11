import pathlib
import struct
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from map_format import write_fmb


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


if __name__ == "__main__":
    unittest.main()
