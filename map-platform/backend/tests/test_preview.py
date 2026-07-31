import io
import unittest

from PIL import Image

from map_platform.models import Bounds
from map_platform.preview import render_boundary_preview


class BoundaryPreviewTests(unittest.TestCase):
    def assert_valid_preview(self, data: bytes):
        self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertGreater(len(data), 100)
        with Image.open(io.BytesIO(data)) as image:
            self.assertEqual(image.format, "PNG")
            self.assertEqual(image.mode, "RGBA")
            self.assertEqual(image.size, (160, 96))
            self.assertIsNotNone(image.getbbox())

    def test_renders_polygon_with_hole(self):
        data = render_boundary_preview(
            {
                "type": "Polygon",
                "coordinates": [
                    [[100, 0], [110, 0], [110, 10], [100, 10], [100, 0]],
                    [[103, 3], [107, 3], [107, 7], [103, 7], [103, 3]],
                ],
            },
            Bounds(100, 0, 110, 10),
        )

        self.assert_valid_preview(data)
        with Image.open(io.BytesIO(data)) as image:
            self.assertEqual(image.getpixel((80, 48))[3], 0)

    def test_renders_multipolygon(self):
        data = render_boundary_preview(
            {
                "type": "MultiPolygon",
                "coordinates": [
                    [[[100, 0], [104, 0], [104, 4], [100, 4], [100, 0]]],
                    [[[106, 6], [110, 6], [110, 10], [106, 10], [106, 6]]],
                ],
            },
            Bounds(100, 0, 110, 10),
        )

        self.assert_valid_preview(data)
        with Image.open(io.BytesIO(data)) as image:
            self.assertGreater(image.getpixel((56, 72))[3], 0)
            self.assertEqual(image.getpixel((80, 48))[3], 0)
            self.assertGreater(image.getpixel((104, 24))[3], 0)

    def test_invalid_and_antimeridian_geometry_fall_back_to_bounds(self):
        invalid = render_boundary_preview(
            {"type": "LineString", "coordinates": [[0, 0], [1, 1]]},
            Bounds(100, 0, 110, 10),
        )
        antimeridian = render_boundary_preview(
            {
                "type": "Polygon",
                "coordinates": [[
                    [179, 0], [-179, 0], [-179, 2], [179, 2], [179, 0],
                ]],
            },
            Bounds(170, 0, 180, 2),
        )

        self.assert_valid_preview(invalid)
        self.assert_valid_preview(antimeridian)
        self.assertEqual(invalid, render_boundary_preview(None, Bounds(100, 0, 110, 10)))
        self.assertEqual(antimeridian, render_boundary_preview(None, Bounds(170, 0, 180, 2)))


if __name__ == "__main__":
    unittest.main()
