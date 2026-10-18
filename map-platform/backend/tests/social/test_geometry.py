import unittest
from map_platform.social.geometry import distance, route_progress, sanitize_track
from map_platform.social.route_archive import validate_archive


def point(lat, lon, **extra):
    return dict(latitude=lat, longitude=lon, **extra)


class GeometryTest(unittest.TestCase):
    def test_direction_off_route_and_crossing_are_not_false_gaps(self):
        route = [point(0, 0), point(0, .02)]
        self.assertAlmostEqual(route_progress(route, point(0, .01, course=90)), 1112, delta=5)
        self.assertIsNone(route_progress(route, point(0, .01, course=270)))
        self.assertIsNone(route_progress(route, point(.01, .01)))
        loop = [point(-.01,-.01),point(.01,.01),point(.01,-.01),point(-.01,.01)]
        self.assertIsNone(route_progress(loop, point(0,0)))
        self.assertIsNotNone(route_progress(loop, point(0,0), previous=1500, elapsed=3))

    def test_privacy_segments_never_bridge_zones_or_antimeridian(self):
        points = [point(0, 179.97), point(0, 179.99), point(0,-179.99), point(0,-179.97)]
        zone = point(0,180,radius=300)
        result = sanitize_track(points, [zone])
        self.assertEqual(len(result['segments']), 2)
        for segment in result['segments']:
            for p in segment:
                self.assertGreater(distance(p,zone),325)
                self.assertGreater(distance(p,points[0]),225)
                self.assertGreater(distance(p,points[-1]),225)
            for a,b in zip(segment,segment[1:]):
                self.assertLessEqual(distance(a,b),25.01)

    def test_route_fingerprint_is_direction_insensitive_and_matches_native_vectors(self):
        from map_platform.social.route_archive import route_fingerprint
        # The same vectors are asserted by the native Swift runtime tests.
        points = [point(51.5, -0.1), point(51.502, -0.1), point(51.504, -0.1000004)]
        expected = '57424a01bcdb7b9435cd88b98d443c20878d901434ddfdc93085886de4794bb7'
        self.assertEqual(route_fingerprint(points), expected)
        self.assertEqual(route_fingerprint(list(reversed(points))), expected)
        self.assertEqual(route_fingerprint([point(-33.8688, 151.2093), point(-33.86885, 151.20935)]),
                         '643bc165b37ae90cd785b174bcb26db6016f7c90cca19c8a5b41516bfc7ff8bf')
        self.assertNotEqual(route_fingerprint(points[:2]), expected)

if __name__ == '__main__': unittest.main()
