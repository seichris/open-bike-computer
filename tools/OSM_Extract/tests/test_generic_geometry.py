import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image
from shapely import Point, Polygon, box, set_precision
from shapely.ops import unary_union


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from funcs import (  # noqa: E402
    BACKGROUND_COLOR,
    GenericGeometryError,
    GenericGeometryLimitError,
    _validate_quantized_decomposition,
    clip_polygons,
    clip_polygons_to_tile_budget,
    fit_polygons_to_feature_budget,
    get_geoms,
    render_map,
)
import funcs  # noqa: E402
from map_format import MAX_BLOCK_FEATURES, MapFormatLimitError, write_fmb  # noqa: E402


def styled_feature(geometry, identifier="source"):
    return {
        "id": identifier,
        "type": "landuse.grass",
        "geom_type": "polygon",
        "color": "0x07E0",
        "width": None,
        "maxzoom": "",
        "bbox": geometry.bounds,
        "geom": geometry,
        "_source_geometry_key": identifier,
    }


class GenericGeometryTests(unittest.TestCase):
    def test_overfull_tile_keeps_lines_and_complete_polygon_components(self):
        small_building = {
            **styled_feature(box(0, 0, 2, 2), "small"), "type": "building.yes",
        }
        large_building = {
            **styled_feature(box(10, 0, 20, 10), "large"), "type": "building.yes",
        }
        park_halves = [
            styled_feature(box(20, 0, 50, 30), "park"),
            styled_feature(box(50, 0, 80, 30), "park"),
        ]
        polygons = [small_building, park_halves[0], large_building, park_halves[1]]
        self.assertIs(fit_polygons_to_feature_budget(polygons, 2, 6), polygons)
        self.assertEqual(
            fit_polygons_to_feature_budget(polygons, 2, 5),
            [park_halves[0], large_building, park_halves[1]],
        )
        self.assertEqual(fit_polygons_to_feature_budget(polygons, 2, 3), [large_building])
        with self.assertRaisesRegex(GenericGeometryLimitError, "tile has 4 lines"):
            fit_polygons_to_feature_budget(polygons, 4, 3)

    def test_aggregate_piece_limit_prioritizes_areas_before_buildings(self):
        block = box(0, 0, 80, 80)
        buildings = [
            {**styled_feature(geom, name), "type": "building.yes"}
            for name, geom in (
                ("small", box(0, 0, 3, 3)),
                ("large", box(10, 10, 30, 30)),
                ("medium", box(0, 10, 5, 15)),
            )
        ]
        park = styled_feature(box(0, 40, 4, 42), "park")
        water = styled_feature(box(0, 50, 4, 54), "water")
        features = [*buildings, park, water]
        diagnostics = {}
        with self.assertRaises(GenericGeometryLimitError):
            clip_polygons(features, block, max_pieces_per_block=4)
        selected = clip_polygons_to_tile_budget(
            features, block, 5, 8,
            max_pieces_per_block=4, geometry_diagnostics=diagnostics,
        )
        self.assertEqual([feat["id"] for feat in selected], ["large", "park", "water"])
        self.assertEqual(diagnostics["tileFeatureBudget"]["overfullTiles"], 1)
        self.assertEqual(diagnostics["tileFeatureBudget"]["omittedComponents"], 2)

    def test_aggregate_piece_limit_never_writes_part_of_a_component(self):
        block = box(0, 0, 80, 80)
        large_park = styled_feature(
            Polygon(box(0, 0, 30, 30).exterior.coords, [box(5, 5, 25, 25).exterior.coords]),
            "large park",
        )
        small_park = styled_feature(box(40, 0, 45, 5), "small park")
        with patch("funcs._decompose_hole_free", wraps=funcs._decompose_hole_free) as decompose:
            selected = clip_polygons_to_tile_budget(
                [large_park, small_park], block, 5, 6, max_pieces_per_block=2,
            )
        self.assertEqual([feat["id"] for feat in selected], ["small park"])
        self.assertEqual([call.args[1] for call in decompose.call_args_list], [2, 1, 1])

    def test_tile_budget_does_not_duplicate_invalid_geometry_samples(self):
        feature = styled_feature(Point(5, 5), "invalid")
        for block_limit in (2, 5):
            with self.subTest(block_limit=block_limit):
                diagnostics = {}
                selected = clip_polygons_to_tile_budget(
                    [
                        feature,
                        styled_feature(box(1, 10, 2, 13), "first"),
                        styled_feature(box(5, 10, 8, 13), "second"),
                        styled_feature(box(10, 10, 12, 13), "third"),
                    ],
                    box(0, 0, 30, 30), 1, 2,
                    max_pieces_per_block=block_limit, geometry_diagnostics=diagnostics,
                )
                self.assertEqual([feat["id"] for feat in selected], ["second"])
                self.assertEqual(diagnostics["droppedGeometryCount"], 1)
                self.assertEqual(len(diagnostics["droppedGeometrySamples"]), 1)

    def test_writer_rejects_combined_count_over_firmware_limit(self):
        polygon = styled_feature(box(0, 0, 2, 2))
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "oversized.fmb"
            with self.assertRaisesRegex(MapFormatLimitError, "tile feature limit"):
                write_fmb(path, [polygon] * MAX_BLOCK_FEATURES, [None], 0, 0, renderer_target=1)
            self.assertFalse(path.exists())

    def test_polygon_and_multipolygon_preserve_holes_and_all_components(self):
        polygon = get_geoms(
            {
                "type": "Polygon",
                "coordinates": [
                    [[0, 0], [20, 0], [20, 20], [0, 20], [0, 0]],
                    [[5, 5], [5, 15], [15, 15], [15, 5], [5, 5]],
                ],
            }
        )
        self.assertEqual(len(polygon), 1)
        self.assertEqual(len(polygon[0].interiors), 1)
        self.assertEqual(polygon[0].area, 300)

        multipolygon = get_geoms(
            {
                "type": "MultiPolygon",
                "coordinates": [
                    [[[30, 0], [40, 0], [40, 10], [30, 10], [30, 0]]],
                    [
                        [[0, 0], [20, 0], [20, 20], [0, 20], [0, 0]],
                        [[5, 5], [5, 15], [15, 15], [15, 5], [5, 5]],
                    ],
                ],
            }
        )
        self.assertEqual(len(multipolygon), 2)
        self.assertEqual([part.bounds[0] for part in multipolygon], [0, 30])
        self.assertEqual(sum(part.area for part in multipolygon), 400)

    def test_invalid_and_nonfinite_components_emit_typed_drop_diagnostics(self):
        diagnostics = {}
        geometries = get_geoms(
            {
                "type": "MultiPolygon",
                "coordinates": [
                    [[[0, 0], [10, 0], [10, 10], [0, 0]]],
                    [[[0, 0], [float("nan"), 0], [0, 10], [0, 0]]],
                    [[[0, 0], [1, 1], [0, 0]]],
                ],
            },
            geometry_diagnostics=diagnostics,
        )
        self.assertEqual(len(geometries), 1)
        self.assertEqual(
            diagnostics,
            {
                "droppedGeometryCount": 2,
                "droppedByCode": {"invalid_polygon_component": 2},
            },
        )

    def test_clipping_decomposes_holes_without_area_loss_or_overlap(self):
        source = Polygon(
            [(0, 0), (30, 0), (30, 30), (0, 30), (0, 0)],
            [
                [(4, 4), (12, 4), (12, 12), (4, 12), (4, 4)],
                [(18, 16), (28, 16), (28, 26), (18, 26), (18, 16)],
            ],
        )
        clipping_box = box(0, 0, 24, 24)
        expected = source.intersection(clipping_box)
        pieces = clip_polygons([styled_feature(source)], clipping_box)
        geometries = [feature["geom"] for feature in pieces]
        merged = unary_union(geometries)

        self.assertGreater(len(geometries), 1)
        self.assertTrue(all(not geometry.interiors for geometry in geometries))
        self.assertLess(expected.symmetric_difference(merged).area, 1e-7)
        self.assertLess(abs(sum(item.area for item in geometries) - merged.area), 1e-7)
        for interior in expected.interiors:
            self.assertLess(merged.intersection(Polygon(interior)).area, 1e-7)

    def test_decomposition_is_stable_and_writes_identical_fmb_bytes(self):
        source = Polygon(
            [(0, 0), (30, 0), (30, 30), (0, 30), (0, 0)],
            [[(5, 5), (25, 5), (25, 25), (5, 25), (5, 5)]],
        )
        clipping_box = box(0, 0, 30, 30)
        first = clip_polygons([styled_feature(source)], clipping_box)
        second = clip_polygons([styled_feature(source)], clipping_box)
        self.assertEqual(
            [geometry["geom"].wkb for geometry in first],
            [geometry["geom"].wkb for geometry in second],
        )

        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            write_fmb(root / "first.fmb", first, [], 0, 0, renderer_target=1)
            write_fmb(root / "second.fmb", second, [], 0, 0, renderer_target=1)
            self.assertEqual(
                (root / "first.fmb").read_bytes(),
                (root / "second.fmb").read_bytes(),
            )

    def test_fmb_precision_preserves_representable_real_world_hole(self):
        # Reduced EPSG:3857 coordinates from an ordinary parking relation that
        # previously failed after its hole-free pieces were rounded to FMB.
        source = Polygon(
            [
                (552.031362, 2224.15555),
                (613.379533, 2240.867527),
                (622.38528, 2209.812423),
                (613.969526, 2207.378518),
                (625.902976, 2166.236491),
                (620.748883, 2164.73971),
                (610.407303, 2200.376164),
                (564.076131, 2186.94415),
                (560.847865, 2196.835942),
                (558.220725, 2204.931599),
                (552.031362, 2224.15555),
            ],
            [[
                (575.219212, 2194.558226),
                (606.711496, 2204.319869),
                (606.56678, 2209.278786),
                (608.615059, 2213.365664),
                (604.96378, 2223.569851),
                (601.178917, 2224.74125),
                (569.820216, 2215.552275),
                (575.219212, 2194.558226),
            ]],
        )
        expected = set_precision(source, 1.0, mode="valid_output")
        pieces = clip_polygons(
            [styled_feature(source)],
            box(0, 0, 4095, 4096),
        )
        geometries = [feature["geom"] for feature in pieces]
        merged = unary_union(geometries)

        self.assertGreater(len(geometries), 1)
        self.assertTrue(all(not geometry.interiors for geometry in geometries))
        self.assertLess(expected.symmetric_difference(merged).area, 1e-7)
        self.assertGreater(expected.area, 1_700)
        encoded = unary_union(
            [
                Polygon(
                    [(round(x), round(y)) for x, y in geometry.exterior.coords]
                )
                for geometry in geometries
            ]
        )
        hole = Polygon(expected.interiors[0])
        self.assertFalse(encoded.covers(hole.representative_point()))

    def test_fmb_precision_repairs_boundary_and_submetre_slivers(self):
        sources = (
            Polygon(
                [
                    (256.833672, 84.313821),
                    (315.064898, 124.343063),
                    (373.10688, 39.910804),
                    (314.875655, -0.118164),
                    (256.833672, 84.313821),
                ]
            ),
            Polygon(
                [
                    (1430.786758, 158.878966),
                    (1430.931474, 157.941692),
                    (1440.059672, 158.644647),
                    (1449.032023, 152.955915),
                    (1449.321453, 153.424552),
                    (1440.004012, 159.347603),
                    (1430.786758, 158.878966),
                ]
            ),
        )

        for index, source in enumerate(sources):
            with self.subTest(index=index):
                pieces = clip_polygons(
                    [styled_feature(source, f"precision-{index}")],
                    box(0, 0, 4095, 4096),
                )
                self.assertTrue(pieces)
                self.assertTrue(all(item["geom"].is_valid for item in pieces))

    def test_fmb_precision_tolerance_still_rejects_filled_holes(self):
        source = Polygon(
            [(0, 0), (100, 0), (100, 100), (0, 100), (0, 0)],
            [[(35, 35), (65, 35), (65, 65), (35, 65), (35, 35)]],
        )
        filled = Polygon(source.exterior)

        with self.assertRaises(GenericGeometryError):
            _validate_quantized_decomposition(source, [filled], 0, 0)

    def test_invalid_block_polygon_is_dropped_with_bounded_diagnostics(self):
        invalid = styled_feature(
            Polygon([(0, 0), (10, 0), (10, 10), (0, 0)]),
            "w123",
        )
        invalid["_source_geometry_component"] = 2
        valid = styled_feature(
            Polygon([(20, 0), (30, 0), (30, 10), (20, 0)]),
            "w456",
        )
        diagnostics = {}
        snap_to_fmb_precision = funcs._snap_to_fmb_precision

        def fail_one_source(polygon):
            if polygon.bounds[0] < 20:
                raise GenericGeometryError(
                    "generic polygon becomes invalid at FMB coordinate precision"
                )
            return snap_to_fmb_precision(polygon)

        with patch(
            "funcs._snap_to_fmb_precision",
            side_effect=fail_one_source,
        ):
            pieces = clip_polygons(
                [invalid, valid],
                box(0, 0, 40, 40),
                geometry_diagnostics=diagnostics,
            )

        self.assertEqual([item["id"] for item in pieces], ["w456"])
        self.assertEqual(diagnostics["droppedGeometryCount"], 1)
        self.assertEqual(
            diagnostics["droppedByCode"],
            {"invalid_block_polygon": 1},
        )
        self.assertEqual(
            diagnostics["droppedGeometrySamples"],
            [
                {
                    "blockOrigin": [0, 0],
                    "component": 2,
                    "reason": (
                        "generic polygon becomes invalid at FMB coordinate precision"
                    ),
                    "sourceGeometryKey": "w123",
                }
            ],
        )

    def test_amplification_limit_fails_closed(self):
        source = Polygon(
            [(0, 0), (30, 0), (30, 30), (0, 30), (0, 0)],
            [[(5, 5), (25, 5), (25, 25), (5, 25), (5, 5)]],
        )
        with self.assertRaises(GenericGeometryLimitError) as raised:
            clip_polygons(
                [styled_feature(source)],
                box(0, 0, 30, 30),
                max_pieces_per_source=2,
            )
        self.assertEqual(raised.exception.code, "generic_geometry_amplification_limit")

        second = Polygon(
            [(40, 0), (50, 0), (50, 10), (40, 10), (40, 0)]
        )
        with self.assertRaises(GenericGeometryLimitError):
            clip_polygons(
                [styled_feature(source), styled_feature(second, "second")],
                box(0, 0, 60, 60),
                max_pieces_per_block=8,
            )

    def test_dense_polygon_with_hole_fits_source_budget_without_area_loss(self):
        # A detailed outer ring plus one hole needs over 2,048 triangles, even
        # though the encoded polygon data still fits comfortably in one block.
        shell = Point(2048, 2048).buffer(1600, quad_segs=600)
        source = Polygon(
            shell.exterior.coords,
            [[(2000, 2000), (2100, 2000), (2100, 2100),
              (2000, 2100), (2000, 2000)]],
        )
        block = box(0, 0, 4095, 4096)
        with self.assertRaises(GenericGeometryLimitError):
            clip_polygons(
                [styled_feature(source)], block,
                max_pieces_per_source=2048,
            )

        pieces = clip_polygons([styled_feature(source)], block)
        self.assertGreater(len(pieces), 2048)
        self.assertLessEqual(len(pieces), 4096)
        self.assertTrue(all(not item["geom"].interiors for item in pieces))
        expected = set_precision(source, 1.0, mode="valid_output")
        merged = unary_union([item["geom"] for item in pieces])
        self.assertLess(expected.symmetric_difference(merged).area, 1e-7)

        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp) / "dense.fmb"
            write_fmb(output, pieces, [], 0, 0, renderer_target=1)
            self.assertLess(output.stat().st_size, 2 * 1024 * 1024)

    def test_explicit_debug_render_keeps_hole_transparent(self):
        source = Polygon(
            [(8, 8), (56, 8), (56, 56), (8, 56), (8, 8)],
            [[(24, 24), (40, 24), (40, 40), (24, 40), (24, 24)]],
        )
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp) / "debug.png"
            render_map(
                [styled_feature(source)],
                output,
                min_x=0,
                min_y=0,
                image_size=(64, 64),
            )
            with Image.open(output) as rendered:
                background = (
                    (BACKGROUND_COLOR >> 16) & 0xFF,
                    (BACKGROUND_COLOR >> 8) & 0xFF,
                    BACKGROUND_COLOR & 0xFF,
                )
                self.assertEqual(rendered.getpixel((32, 32)), background)
                self.assertNotEqual(rendered.getpixel((16, 32)), background)

    def test_cli_defaults_to_no_debug_artifacts_and_rejects_output_subdirectory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            prefix = root / "features"
            output = root / "map"
            (root / "features_lines.geojson").write_text(
                json.dumps({"type": "FeatureCollection", "features": []}),
                encoding="utf-8",
            )
            (root / "features_polygons.geojson").write_text(
                json.dumps(
                    {
                        "type": "FeatureCollection",
                        "features": [
                            {
                                "type": "Feature",
                                "properties": {
                                    "osm_way_id": 1,
                                    "landuse": "grass",
                                },
                                "geometry": {
                                    "type": "Polygon",
                                    "coordinates": [
                                        [[0, 0], [100, 0], [100, 100], [0, 100], [0, 0]]
                                    ],
                                },
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            command = [
                sys.executable,
                str(ROOT / "scripts" / "extract_features.py"),
                "0",
                "0",
                "0.01",
                "0.01",
                str(prefix),
                str(output),
            ]
            result = subprocess.run(
                command,
                cwd=ROOT / "scripts",
                text=True,
                capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(list(output.rglob("*.fmb")))
            self.assertFalse((output / "test_imgs").exists())
            self.assertFalse(list(output.rglob("*.png")))

            rejected = subprocess.run(
                command
                + [
                    "--debug-image-dir",
                    str(output / "debug"),
                    "--debug-image-limit",
                    "1",
                ],
                cwd=ROOT / "scripts",
                text=True,
                capture_output=True,
            )
            self.assertEqual(rejected.returncode, 2)
            self.assertIn(
                "--debug-image-dir must be outside the map output",
                rejected.stderr,
            )


if __name__ == "__main__":
    unittest.main()
