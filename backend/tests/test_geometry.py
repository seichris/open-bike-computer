import unittest

from map_platform.geometry import GeometryError, normalize_geometry


class GeometryTests(unittest.TestCase):
    def test_custom_bbox_normalizes(self):
        geometry = normalize_geometry(
            {
                "mode": "custom_bbox",
                "bbox": [103.75, 1.24, 103.93, 1.37],
            }
        )

        self.assertEqual(geometry.mode.value, "custom_bbox")
        self.assertGreater(geometry.area_km2, 0)
        self.assertEqual(geometry.vertex_count, 4)

    def test_rejects_inverted_bbox(self):
        with self.assertRaises(GeometryError):
            normalize_geometry(
                {
                    "mode": "custom_bbox",
                    "bbox": [104.0, 1.0, 103.0, 2.0],
                }
            )

    def test_polygon_detects_self_intersection(self):
        with self.assertRaises(GeometryError):
            normalize_geometry(
                {
                    "mode": "custom_polygon",
                    "geometry": {
                        "type": "Polygon",
                        "coordinates": [
                            [
                                [0, 0],
                                [1, 1],
                                [1, 0],
                                [0, 1],
                                [0, 0],
                            ]
                        ],
                    },
                }
            )

    def test_route_corridor_expands_thin_route(self):
        geometry = normalize_geometry(
            {
                "mode": "route_corridor",
                "corridorWidthM": 1000,
                "route": {
                    "type": "LineString",
                    "coordinates": [[103.8, 1.3], [103.8, 1.4]],
                },
            }
        )

        self.assertEqual(geometry.route_point_count, 2)
        self.assertLess(geometry.bounds.min_lon, 103.8)
        self.assertGreater(geometry.bounds.max_lon, 103.8)


if __name__ == "__main__":
    unittest.main()
