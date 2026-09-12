import pathlib
import sys
import unittest

from shapely.geometry import MultiPolygon, Point, Polygon, mapping


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from poi_pipeline import (  # noqa: E402
    PoiPipelineError,
    classify_poi,
    load_poi_config,
    prepare_pois,
    records_by_block,
)


CONFIG_PATH = ROOT / "conf" / "poi_categories.yaml"


def feature(geometry, *, osm_id=None, osm_way_id=None, **properties):
    values = dict(properties)
    if osm_id is not None:
        values["osm_id"] = osm_id
    if osm_way_id is not None:
        values["osm_way_id"] = osm_way_id
    return {
        "type": "Feature",
        "properties": values,
        "geometry": mapping(geometry),
    }


class PoiPipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = load_poi_config(CONFIG_PATH)

    def test_profile_configuration_is_strict_and_canonical(self):
        self.assertEqual(self.config.profile_version, 1)
        self.assertEqual(self.config.block_size_meters, 4096)
        self.assertEqual(
            [(item.category_id, item.key, item.maximum_zoom, item.rank) for item in self.config.categories],
            [
                (1, "shops", 2, 3),
                (2, "restaurants_and_cafes", 3, 2),
                (3, "public_toilets", 3, 1),
                (4, "gas_stations", 3, 1),
                (5, "bicycle_services", 3, 0),
            ],
        )
        self.assertRegex(self.config.sha256, r"^[0-9a-f]{64}$")

    def test_category_precedence_and_inactive_values(self):
        cases = (
            ({"shop": "bakery"}, 1),
            ({"shop": "bakery", "amenity": "cafe"}, 2),
            ({"shop": "bakery", "amenity": "toilets"}, 3),
            ({"shop": "bakery", "amenity": "fuel"}, 4),
            ({"shop": "bicycle", "amenity": "restaurant"}, 5),
            ({"amenity": "bicycle_repair_station"}, 5),
            ({"shop": "no"}, None),
            ({"shop": "vacant"}, None),
            ({"shop": "closed"}, None),
            ({"disused:shop": "bicycle"}, None),
        )
        for tags, expected in cases:
            with self.subTest(tags=tags):
                category = classify_poi(tags, self.config)
                self.assertEqual(
                    category.category_id if category is not None else None,
                    expected,
                )

    def test_points_and_area_components_have_one_deterministic_owner(self):
        concave_with_hole = Polygon(
            [(10, 10), (110, 10), (110, 110), (60, 60), (10, 110), (10, 10)],
            [[(25, 25), (45, 25), (45, 45), (25, 45), (25, 25)]],
        )
        multi = MultiPolygon(
            [
                Polygon([(5000, 10), (5010, 10), (5010, 20), (5000, 20), (5000, 10)]),
                Polygon([(6000, 10), (6010, 10), (6010, 20), (6000, 20), (6000, 10)]),
            ]
        )
        points = [
            feature(Point(4096, 2), osm_id=1, shop="bakery"),
            feature(Point(-0.1, 2), osm_id=2, amenity="toilets"),
        ]
        areas = [
            feature(concave_with_hole, osm_way_id=3, amenity="cafe"),
            feature(multi, osm_id=4, amenity="fuel"),
        ]

        records, report = prepare_pois(points, areas, self.config)
        blocks = records_by_block(records)

        self.assertEqual(report["recordCount"], 5)
        self.assertEqual(report["pointRecordCount"], 2)
        self.assertEqual(report["areaRecordCount"], 3)
        self.assertEqual(report["shopsCount"], 1)
        self.assertEqual(report["restaurantsAndCafesCount"], 1)
        self.assertEqual(report["publicToiletsCount"], 1)
        self.assertEqual(report["gasStationsCount"], 2)
        self.assertIn((4096, 0), blocks)
        negative = next(record for record in records if record.object_key == "n2")
        self.assertEqual((negative.block_x, negative.local_x), (-4096, 4095))
        boundary = next(record for record in records if record.object_key == "n1")
        self.assertEqual((boundary.block_x, boundary.local_x), (4096, 0))
        area_anchor = next(record for record in records if record.object_key == "w3")
        self.assertTrue(
            concave_with_hole.covers(
                Point(area_anchor.block_x + area_anchor.local_x, area_anchor.block_y + area_anchor.local_y)
            )
        )
        self.assertEqual(
            sorted(record.component_index for record in records if record.object_key == "r4"),
            [0, 1],
        )

    def test_exact_duplicates_are_removed_without_fuzzy_merging(self):
        first = feature(Point(10, 10), osm_id=10, shop="bakery")
        adjacent = feature(Point(10.1, 10), osm_id=11, shop="bakery")
        records, report = prepare_pois(
            [first, first, adjacent],
            [],
            self.config,
        )

        self.assertEqual(len(records), 2)
        self.assertEqual(report["exactIdentityDuplicatesRemoved"], 1)
        self.assertEqual({record.object_key for record in records}, {"n10", "n11"})

    def test_malformed_and_outside_selection_records_are_diagnostic(self):
        records, report = prepare_pois(
            [
                feature(Point(5, 5), osm_id=1, other_tags='"shop"=>"bakery","bad"'),
                feature(Point(50, 50), osm_id=2, shop="vacant"),
                feature(Point(500, 500), osm_id=3, shop="books"),
                feature(Point(5, 5), shop="books"),
            ],
            [],
            self.config,
            selection_geometry=Polygon([(0, 0), (100, 0), (100, 100), (0, 100), (0, 0)]),
        )

        self.assertEqual(len(records), 1)
        self.assertEqual(report["malformedOtherTags"], 1)
        self.assertEqual(report["inactiveRecords"], 1)
        self.assertEqual(report["outsideSelection"], 1)
        self.assertEqual(report["missingObjectIdentity"], 1)

    def test_invalid_configuration_fails_closed(self):
        with self.assertRaises(PoiPipelineError):
            load_poi_config(ROOT / "conf" / "missing-pois.yaml")


if __name__ == "__main__":
    unittest.main()
