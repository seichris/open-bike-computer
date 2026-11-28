import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import build_elevation
import sample_elevation
import tower_mask
from build_graph import elevation_identity

POSTS = build_elevation.POSTS
# GHS-BUILT-H on its 3 arc-second grid: pixel edges lie half an arc-second off whole arc-seconds.
PIXEL = 3 / 3600
HALF = 0.5 / 3600


def grid(heights, west, north, crs="EPSG:4326", pixel=PIXEL):
    """An in-memory GeoTIFF of building heights whose north-west pixel edge is half a second off (west, north)."""
    from affine import Affine
    from rasterio.io import MemoryFile

    memory = MemoryFile()
    with memory.open(driver="GTiff", width=heights.shape[1], height=heights.shape[0], count=1, dtype="float32",
                     crs=crs, transform=Affine(pixel, 0, west - HALF, 0, -pixel, north + HALF)) as dataset:
        dataset.write(heights.astype("float32"), 1)
    return memory


class TowerMaskTests(unittest.TestCase):
    def test_a_post_takes_the_height_of_the_grid_cell_it_lies_in(self):
        import numpy as np

        # Four grid cells of 3 x 3 posts each, starting at post (30, 60) of cell N40W074.
        heights = np.array([[10, 20], [-5, np.nan]], dtype="float32")
        west, north = -74 + 60 / 3600, 41 - 30 / 3600
        with grid(heights, west, north) as memory, memory.open() as dataset:
            posts = tower_mask.building_heights([dataset], (-74, 40), 0, 0)
            # With a margin the same posts move by the margin and keep their heights.
            wide = tower_mask.building_heights([dataset], (-74, 40), 7, 11)
        self.assertEqual(posts.shape, (POSTS, POSTS))
        np.testing.assert_array_equal(posts[30:33, 60:63], 10)
        np.testing.assert_array_equal(posts[30:33, 63:66], 20)
        # No height, a negative one and everything the grid does not cover count as no building.
        self.assertEqual(float(posts[33:36, 60:66].max()), 0)
        self.assertEqual(int(np.count_nonzero(posts)), 18)
        self.assertEqual(wide.shape, (POSTS + 14, POSTS + 22))
        np.testing.assert_array_equal(wide[7:-7, 11:-11], posts)

    def test_grids_tile_the_window_and_must_be_plain_geographic_rasters(self):
        import numpy as np

        left = np.full((4, 4), 30, dtype="float32")
        right = np.full((4, 4), 50, dtype="float32")
        north = 41 - 300 / 3600
        with grid(left, -74 + 600 / 3600, north) as first, grid(right, -74 + 612 / 3600, north) as second, \
                first.open() as one, second.open() as two:
            posts = tower_mask.building_heights([one, two], (-74, 40), 0, 0)
        np.testing.assert_array_equal(posts[300:312, 600:612], 30)
        np.testing.assert_array_equal(posts[300:312, 612:624], 50)
        self.assertEqual(int(np.count_nonzero(posts)), 2 * 144)
        with grid(left, 500000, 4500000, crs="EPSG:32618", pixel=90) as memory, memory.open() as dataset:
            with self.assertRaisesRegex(ValueError, "geographic"):
                tower_mask.building_heights([dataset], (-74, 40), 0, 0)
        with grid(np.full((2, 2), 4000, dtype="float32"), -73.5, 40.5) as memory, memory.open() as dataset:
            with self.assertRaisesRegex(ValueError, "not a grid of heights"):
                tower_mask.building_heights([dataset], (-74, 40), 0, 0)

    def test_ellipse_mean_is_the_mean_over_each_rows_own_ellipse(self):
        import numpy as np

        values = np.random.default_rng(3).uniform(0, 60, (14, 23)).astype("float32")
        rows = 2
        columns = np.array([3] * 6 + [5] * 8)
        mean = tower_mask.ellipse_mean(values, rows, columns)
        for row, column in ((0, 0), (5, 11), (6, 11), (13, 22), (9, 2)):
            half = int(columns[row])
            y, x = np.ogrid[-rows:rows + 1, -half:half + 1]
            inside = (y / rows) ** 2 + (x / half) ** 2 <= 1
            padded = np.pad(values, ((rows, rows), (half, half)), mode="edge")
            window = padded[row:row + 2 * rows + 1, column:column + 2 * half + 1]
            self.assertAlmostEqual(float(mean[row, column]), float(window[inside].mean()), places=4)
        np.testing.assert_allclose(tower_mask.ellipse_mean(np.full((9, 9), 7.5, dtype="float32"), 3,
                                                           np.full(9, 2)), 7.5, rtol=1e-6)

    def test_one_tower_is_left_alone_and_a_district_is_masked_with_its_margin(self):
        import numpy as np

        latitudes = np.full(200, 0.0)
        heights = np.zeros((200, 200), dtype="float32")
        heights[20:23, 20:23] = 120          # one tower: a single 90 m grid cell
        heights[100:140, 100:140] = 40       # a district 1.2 km wide
        zone = tower_mask.tower_zone(heights, latitudes, 25, 150, 200)
        self.assertFalse(zone[:60, :60].any())
        self.assertTrue(zone[100:140, 100:140].all())
        # 200 m is 6 posts at the equator: the mask reaches that far beyond the posts the mean calls tall.
        tall = tower_mask.ellipse_mean(heights, 5, np.full(200, 5)) >= 25
        north_edge = int(np.nonzero(tall[:, 120])[0].min())
        self.assertTrue(zone[north_edge - 6, 120] and not zone[north_edge - 7, 120])
        # Without the mean each grid cell is judged alone and the tower is masked as well.
        alone = tower_mask.tower_zone(heights, latitudes, 25, 0, 0)
        np.testing.assert_array_equal(alone, heights >= 25)
        # At 60 degrees an arc-second of longitude is half as long, so the margin is twice as many columns.
        north = tower_mask.tower_zone(heights, np.full(200, 60.0), 25, 0, 200)
        self.assertEqual((int(north[120].sum()), int(north[:, 120].sum())), (40 + 2 * 13, 40 + 2 * 6))
        self.assertFalse(tower_mask.tower_zone(np.full((50, 50), 24.9, dtype="float32"), np.zeros(50), 25, 150,
                                               200).any())

    def test_two_cells_give_their_shared_border_posts_the_same_answer(self):
        import numpy as np

        # A district across the meridian between N40W075 and N40W074, 20 x 24 grid cells.
        heights = np.full((20, 24), 45, dtype="float32")
        with grid(heights, -74 - 36 / 3600, 41 - 900 / 3600) as memory, memory.open() as dataset:
            west = tower_mask.cell_zone([dataset], (-75, 40))
            east = tower_mask.cell_zone([dataset], (-74, 40))
        np.testing.assert_array_equal(west[:, -1], east[:, 0])
        self.assertTrue(west[930, -1] and west[930, -20] and east[930, 20])
        # The margin reaches further than the district's own 36 posts west of the border, and stops.
        self.assertTrue(west[930, POSTS - 1 - 40])
        self.assertFalse(west[930, POSTS - 1 - 60])
        self.assertFalse(west[:800].any() or east[1100:].any())

    def test_a_cell_outside_every_grid_is_named(self):
        import numpy as np

        # One file over N40W074 and the west half of N40W073, as two files of the grid meet inside a cell.
        with grid(np.zeros((1202, 1802), dtype="float32"), -74 - 3 / 3600, 41 + 3 / 3600) as first, \
                grid(np.zeros((1202, 700), dtype="float32"), -73 + 1800 / 3600, 41 + 3 / 3600) as second, \
                first.open() as west, second.open() as east:
            self.assertEqual(tower_mask.uncovered_cells([west], [(-74, 40), (-73, 40), (-74, 41)]),
                             ["N40W073", "N41W074"])
            self.assertEqual(tower_mask.uncovered_cells([west, east], [(-74, 40), (-73, 40)]), [])
            self.assertEqual(tower_mask.uncovered_cells([], [(8, 47)]), ["N47E008"])
            # The file reaches one grid cell past N40W074: enough for the cell, not for the margin of its zone.
            self.assertEqual(tower_mask.uncovered_cells([west], [(-74, 40)], 150, 200), ["N40W074"])
            self.assertEqual(tower_mask.uncovered_cells([west], [(-74, 40)], 0, 60), [])

    def test_masked_posts_lose_their_height_and_the_rest_keep_theirs(self):
        import numpy as np

        heights = np.array([[1, 2, np.nan], [4, 5, 6]], dtype="float32")
        zone = np.array([[True, False, True], [False, False, True]])
        masked, lost = tower_mask.mask_posts(heights, zone)
        self.assertEqual(lost, 2)
        np.testing.assert_array_equal(masked, np.array([[np.nan, 2, np.nan], [4, 5, np.nan]], dtype="float32"))

    def test_command_masks_a_sample_and_records_the_rule_and_its_inputs(self):
        import numpy as np

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            opened = root / "opened"
            terrain = np.full((POSTS, POSTS), 12, dtype="float32")
            terrain[0, 0] = np.nan
            terrain[1000:1100, 1000:1100] = 55   # the plateau the opening left
            sample_elevation.write_manifest(
                opened, {"name": "grey-opening", "radiusMetres": 200}, [{"id": "copernicus-glo30"}],
                [sample_elevation.write_hgt(opened, (-74, 40), terrain)], [-74, 40, -73, 41])
            # A grid over the whole cell and six grid cells more on every side, with one district of towers.
            heights = np.zeros((1212, 1212), dtype="float32")
            heights[341:371, 341:371] = 60       # posts 1005 to 1094, both ways
            file = root / "GHS_BUILT_H_ANBH_test.tif"
            with grid(heights, -74 - 18 / 3600, 41 + 18 / 3600) as memory:
                file.write_bytes(memory.read())
            # The same grid without the margin a cell's zone is judged with, and one that holds no heights.
            tight_file, surface_file = root / "tight.tif", root / "surface.tif"
            with grid(heights[5:-5, 5:-5], -74 - 3 / 3600, 41 + 3 / 3600) as memory:
                tight_file.write_bytes(memory.read())
            surface = heights.copy()
            surface[900:910, 900:910] = 8100     # built square metres, as GHS-BUILT-S holds them
            with grid(surface, -74 - 18 / 3600, 41 + 18 / 3600) as memory:
                surface_file.write_bytes(memory.read())
            # The same district in a file that covers nothing else of the cell.
            patch_file = root / "patch.tif"
            with grid(np.full((30, 30), 60, dtype="float32"), -74 + 1005 / 3600, 41 - 1005 / 3600) as memory:
                patch_file.write_bytes(memory.read())
            out = root / "masked"
            arguments = ["tower_mask.py", "--input", str(opened), "--heights", str(file), "--bounds", "-74", "40",
                         "-73", "41", "--out", str(out)]
            with patch("sys.argv", arguments), patch("builtins.print"):
                tower_mask.main()
            posts = sample_elevation.read_hgt(build_elevation.hgt_path(out, -74, 40))
            # The district and its margin are no data; the plain around them keeps its heights.
            self.assertTrue(np.isnan(posts[1005:1095, 1005:1095]).all())
            self.assertTrue(np.isnan(posts[1000, 1050]) and np.isnan(posts[1050, 1099]))
            self.assertEqual((float(posts[1120, 1120]), float(posts[990, 1050]), float(posts[3000, 3000])),
                             (12, 12, 12))
            unmasked = np.isfinite(posts)
            np.testing.assert_array_equal(posts[unmasked], terrain[unmasked])
            manifest = json.loads((out / "elevation-manifest.json").read_text())
            method = manifest["method"]
            self.assertEqual((method["name"], method["of"], method["masked"]),
                             ("tower-mask", {"name": "grey-opening", "radiusMetres": 200}, "no data"))
            self.assertEqual((method["thresholdMetres"], method["smoothMetres"], method["marginMetres"]),
                             (tower_mask.THRESHOLD_METRES, tower_mask.SMOOTH_METRES, tower_mask.MARGIN_METRES))
            entry, = manifest["cellFiles"]
            self.assertEqual(entry["maskedPosts"], int(np.isnan(posts).sum()) - 1)
            self.assertEqual((method["maskedPosts"], manifest["noDataPosts"]),
                             (entry["maskedPosts"], entry["maskedPosts"] + 1))
            self.assertAlmostEqual(entry["maskedKm2"], entry["maskedPosts"] * tower_mask.post_area_km2(40.5), places=2)
            masked, heights_source = manifest["sources"]
            self.assertEqual(masked["id"], "tower-mask-of-copernicus-glo30")
            self.assertEqual(masked["input"]["manifestSha256"],
                             hashlib.sha256((opened / "elevation-manifest.json").read_bytes()).hexdigest())
            self.assertEqual(heights_source["files"], [{"file": file.name, "bytes": file.stat().st_size,
                                                        "sha256": hashlib.sha256(file.read_bytes()).hexdigest()}])
            self.assertIn("CC BY 4.0", heights_source["licence"])
            # A masked set is a development sample: only a sample graph may be graded with it.
            self.assertEqual(elevation_identity(out, sample=True)["sources"],
                             ["tower-mask-of-copernicus-glo30", tower_mask.SOURCE_ID])
            self.assertEqual(elevation_identity(out, sample=True)["method"]["name"], "tower-mask")
            with self.assertRaisesRegex(ValueError, "part of the source"):
                elevation_identity(out)
            for changed in (["--bounds", "-73", "40", "-72", "41"], ["--heights", str(root / "missing.tif")],
                            ["--heights", str(patch_file)], ["--heights", str(opened / "elevation-manifest.json")],
                            ["--heights", str(tight_file)], ["--heights", str(surface_file)],
                            ["--input", str(root)], ["--threshold", "0"], ["--margin", "5"],
                            ["--bounds", "-74", "40", "-66", "44"]):
                refused = root / "refused"
                with self.subTest(changed=changed), patch("sys.argv", arguments[:-1] + [str(refused)] + changed), \
                        patch("sys.stderr"), self.assertRaises(SystemExit):
                    tower_mask.main()
                self.assertFalse(refused.exists())


class MembraneTests(unittest.TestCase):
    @staticmethod
    def plane(rows, columns, latitude):
        """A plane in metres: 4% up to the north and 2% up to the east."""
        import math

        import numpy as np

        row, column = np.mgrid[0:rows, 0:columns]
        east = column * build_elevation.METRES_PER_ARCSECOND * math.cos(math.radians(latitude))
        north = (rows - row) * build_elevation.METRES_PER_ARCSECOND
        return (50 + 0.04 * north + 0.02 * east).astype("float32")

    def test_a_slope_across_a_zone_stays_and_a_plateau_on_it_goes(self):
        import numpy as np

        for latitude in (0.0, 40.0, -60.0):
            with self.subTest(latitude=latitude):
                plane = self.plane(120, 160, latitude)
                heights = plane.copy()
                heights[50:70, 60:100] += 40     # the towers the opening kept
                heights[5, 5] = np.nan
                zone = np.zeros(heights.shape, dtype=bool)
                zone[30:90, 40:130] = True
                filled, count, unfilled, guarded = tower_mask.membrane_fill(heights, zone, np.full(120, latitude))
                self.assertEqual((count, unfilled, guarded), (int(zone.sum()), 0, []))
                # A plane in metres is its own membrane, whatever an arc-second of longitude measures.
                np.testing.assert_allclose(filled[zone], plane[zone], atol=0.02)
                outside = ~zone & np.isfinite(heights)
                np.testing.assert_array_equal(filled[outside], heights[outside])
                self.assertTrue(np.isnan(filled[5, 5]))

    def test_distances_are_in_metres(self):
        import math

        import numpy as np

        # x^2 - y^2 in metres is harmonic, and a five-post stencil holds it exactly when east and west
        # neighbours weigh 1/cos^2 of the latitude more: a plane would pass with any weights.
        latitude = 60.0
        row, column = np.mgrid[0:80, 0:100]
        east = (column - 50) * build_elevation.METRES_PER_ARCSECOND * math.cos(math.radians(latitude))
        north = (40 - row) * build_elevation.METRES_PER_ARCSECOND
        saddle = ((east ** 2 - north ** 2) / 1000).astype("float32")
        zone = np.zeros(saddle.shape, dtype=bool)
        zone[10:70, 15:85] = True
        heights = saddle.copy()
        heights[zone] += 30
        filled, _, _, _ = tower_mask.membrane_fill(heights, zone, np.full(80, latitude))
        np.testing.assert_allclose(filled[zone], saddle[zone], atol=0.05)
        # Spanned as if an arc-second measured the same both ways, the saddle bends by metres.
        flat, _, _, _ = tower_mask.membrane_fill(heights, zone, np.zeros(80))
        self.assertGreater(float(np.abs(flat - saddle)[zone].max()), 5)

    def test_posts_without_data_take_no_part(self):
        import numpy as np

        # A street between a quay at 10 m and a terrace at 20 m, with no data north and south of it.
        heights = np.full((7, 12), np.nan, dtype="float32")
        heights[2:5, 0] = 10
        heights[2:5, 11] = 20
        heights[2:5, 1:11] = 99
        zone = np.zeros(heights.shape, dtype=bool)
        zone[2:5, 1:11] = True
        # A zone part no height touches stays no data, and so does a zone post without data.
        zone[0, 3:6] = True
        heights[0, 3:6] = 50
        zone[6, 0] = True
        filled, count, unfilled, _ = tower_mask.membrane_fill(heights, zone, np.zeros(7))
        self.assertEqual((count, unfilled), (30, 3))
        np.testing.assert_allclose(filled[3, 1:11], 10 + np.arange(1, 11) * 10 / 11, atol=0.02)
        np.testing.assert_allclose(filled[2], filled[4])
        self.assertTrue(np.isnan(filled[0]).all() and np.isnan(filled[6]).all())

    def test_a_part_with_a_steep_edge_takes_the_fallback_raised_to_meet_it(self):
        import numpy as np

        # A hillside rising 20% to the north in the west half, a plain at 30 m in the east half,
        # with a plateau of towers in a zone part on each.
        row, column = np.mgrid[0:120, 0:160]
        north = (120 - row) * build_elevation.METRES_PER_ARCSECOND
        ground = np.where(column < 80, 10 + 0.2 * north, 30).astype("float32")
        hill, plain = np.zeros(ground.shape, dtype=bool), np.zeros(ground.shape, dtype=bool)
        hill[30:90, 10:60] = True
        plain[30:90, 100:150] = True
        heights = ground + 40 * (hill | plain)
        # The fallback lies 6 m lower and keeps a terrace on the hillside that a membrane cannot.
        fallback = ground - 6
        fallback[50:70, 20:50] = fallback[60, 35]
        fallback[40, 30] = np.nan
        latitudes = np.zeros(120)
        filled, count, unfilled, guarded = tower_mask.membrane_fill(heights, hill | plain, latitudes,
                                                                    fallback=fallback, span_limit=100)
        hill_posts = hill.copy()
        hill_posts[40, 30] = False
        np.testing.assert_allclose(filled[hill_posts], fallback[hill_posts] + 6, atol=0.02)
        self.assertTrue(np.isnan(filled[40, 30]))
        # The plain's edge is level: it keeps the membrane, which lies on the plain, not on the fallback.
        np.testing.assert_allclose(filled[plain], 30, atol=0.02)
        self.assertEqual((count, unfilled), (int(hill.sum() + plain.sum()) - 1, 1))
        (posts, span), = guarded
        self.assertEqual(posts, int(hill.sum()) - 1)
        self.assertGreater(span, 300)
        outside = ~(hill | plain)
        np.testing.assert_array_equal(filled[outside], heights[outside])
        # Above the hillside's span both parts get a membrane.
        _, _, _, none = tower_mask.membrane_fill(heights, hill | plain, latitudes, fallback=fallback,
                                                 span_limit=span + 1)
        self.assertEqual(none, [])

    def test_zone_parts_join_only_across_edges(self):
        import numpy as np

        zone = np.array([[1, 1, 0, 0, 0],
                         [0, 1, 0, 1, 1],
                         [1, 0, 0, 1, 0],
                         [1, 1, 1, 1, 0]], dtype=bool)
        parts = tower_mask.zone_parts(zone)
        self.assertEqual(sorted((top, left, posts.astype(int).tolist()) for top, left, posts in parts),
                         [(0, 0, [[1, 1], [0, 1]]),
                          (1, 0, [[0, 0, 0, 1, 1], [1, 0, 0, 1, 0], [1, 1, 1, 1, 0]])])
        rebuilt = np.zeros(zone.shape, dtype=bool)
        for top, left, posts in parts:
            rebuilt[top:top + posts.shape[0], left:left + posts.shape[1]] |= posts
        np.testing.assert_array_equal(rebuilt, zone)

    def test_command_spans_one_membrane_over_two_cells(self):
        import numpy as np

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            opened = root / "opened"
            # One plane over N40W075 and N40W074, a plateau of towers on it across the meridian between them.
            plane = 100 + np.round(self.plane(POSTS, 2 * POSTS - 1, 40.5) - 50)
            raised = plane.copy()
            raised[880:930, 3540:3660] += 40
            entries = [sample_elevation.write_hgt(opened, cell, sample_elevation.cut(raised, -75, 41, cell))
                       for cell in ((-75, 40), (-74, 40))]
            sample_elevation.write_manifest(opened, {"name": "grey-opening", "radiusMetres": 200},
                                            [{"id": "copernicus-glo30"}], entries, [-75, 40, -73, 41])
            heights = np.zeros((1212, 2412), dtype="float32")
            heights[294:320, 1186:1226] = 50     # posts 864 to 941 down, 3540 to 3659 across
            file = root / "GHS_BUILT_H_ANBH_test.tif"
            with grid(heights, -75 - 18 / 3600, 41 + 18 / 3600) as memory:
                file.write_bytes(memory.read())
            out = root / "membrane"
            arguments = ["tower_mask.py", "--input", str(opened), "--heights", str(file), "--bounds", "-75", "40",
                         "-73", "41", "--fill", "membrane", "--out", str(out)]
            with patch("sys.argv", arguments), patch("builtins.print"):
                tower_mask.main()
            west = sample_elevation.read_hgt(build_elevation.hgt_path(out, -75, 40))
            east = sample_elevation.read_hgt(build_elevation.hgt_path(out, -74, 40))
            np.testing.assert_array_equal(west[:, -1], east[:, 0])
            # The plateau is gone: the membrane lies on the plane, within the metre a tile rounds to.
            self.assertLessEqual(float(np.abs(west[870:940, 3530:] - plane[870:940, 3530:3601]).max()), 1)
            self.assertLessEqual(float(np.abs(east[870:940, :70] - plane[870:940, 3600:3670]).max()), 1)
            self.assertTrue(np.isfinite(west).all() and np.isfinite(east).all())
            manifest = json.loads((out / "elevation-manifest.json").read_text())
            method = manifest["method"]
            self.assertEqual((method["masked"], method["membrane"]["name"]), ("membrane", "membrane"))
            # Without --threshold a membrane takes its own default, the one that met the gate.
            self.assertEqual(method["thresholdMetres"], tower_mask.MEMBRANE_THRESHOLD_METRES)
            self.assertEqual(method["membrane"]["unfilledPosts"], 0)
            self.assertEqual(manifest["noDataPosts"], 0)
            # Each cell counts the zone's posts on the border column they share; the membrane counts them once.
            import rasterio

            with rasterio.open(file) as dataset:
                shared = int(tower_mask.cell_zone([dataset], (-74, 40), tower_mask.MEMBRANE_THRESHOLD_METRES)[:, 0].sum())
            masked = [entry["maskedPosts"] for entry in manifest["cellFiles"]]
            self.assertTrue(70 < shared < 100)
            self.assertEqual(sum(masked) - method["membrane"]["filledPosts"], shared)

    def test_command_guards_a_part_with_a_steep_edge_and_records_its_input(self):
        import numpy as np

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            # A hillside rising 10% to the north, the plateau of a district on it, and a wider opening
            # that lies 5 m lower and keeps a terrace inside the district.
            row = np.mgrid[0:POSTS, 0:POSTS][0]
            ground = 100 + np.round(0.1 * (POSTS - 1 - row) * build_elevation.METRES_PER_ARCSECOND)
            terrain = ground.copy()
            terrain[1005:1095, 1005:1095] += 40
            wider = ground - 5
            wider[1030:1070, 1030:1070] = wider[1069, 1050]
            sets = {}
            for name, values in (("opened", terrain), ("wider", wider)):
                sets[name] = root / name
                sample_elevation.write_manifest(
                    sets[name], {"name": "grey-opening", "radiusMetres": 200 if name == "opened" else 400},
                    [{"id": "copernicus-glo30"}], [sample_elevation.write_hgt(sets[name], (-74, 40), values)],
                    [-74, 40, -73, 41])
            other = root / "other"
            sample_elevation.write_manifest(
                other, {"name": "grey-opening", "radiusMetres": 400}, [{"id": "copernicus-glo30"}],
                [sample_elevation.write_hgt(other, (-73, 40), wider)], [-73, 40, -72, 41])
            heights = np.zeros((1212, 1212), dtype="float32")
            heights[341:371, 341:371] = 60       # posts 1005 to 1094, both ways
            file = root / "GHS_BUILT_H_ANBH_test.tif"
            with grid(heights, -74 - 18 / 3600, 41 + 18 / 3600) as memory:
                file.write_bytes(memory.read())
            out = root / "guarded"
            arguments = ["tower_mask.py", "--input", str(sets["opened"]), "--heights", str(file), "--bounds", "-74",
                         "40", "-73", "41", "--fill", "membrane", "--edge-span", "100", "--edge-span-input",
                         str(sets["wider"]), "--out", str(out)]
            with patch("sys.argv", arguments), patch("builtins.print"):
                tower_mask.main()
            posts = sample_elevation.read_hgt(build_elevation.hgt_path(out, -74, 40))
            # The district takes the wider opening with its terrace, raised the 5 m it lies lower at the edge.
            changed = posts != terrain
            self.assertTrue(changed[1005:1095, 1005:1095].all())
            self.assertLessEqual(float(np.abs(posts[1005:1095, 1005:1095] - wider[1005:1095, 1005:1095] - 5).max()), 1)
            self.assertEqual(float(posts[3000, 3000]), float(terrain[3000, 3000]))
            membrane = json.loads((out / "elevation-manifest.json").read_text())["method"]["membrane"]
            guard = membrane["guard"]
            self.assertEqual((guard["edgeSpanMetres"], guard["percentiles"], guard["guardedParts"]), (100, [5, 95], 1))
            # The margin around the plateau lay on the hillside already and keeps its heights.
            self.assertEqual(guard["guardedPosts"], membrane["filledPosts"])
            self.assertTrue(90 * 90 == int(changed.sum()) < guard["guardedPosts"])
            self.assertEqual(guard["input"]["manifestSha256"],
                             hashlib.sha256((sets["wider"] / "elevation-manifest.json").read_bytes()).hexdigest())
            self.assertEqual(guard["input"]["method"]["radiusMetres"], 400)
            self.assertGreater(guard["edgeSpansMetres"][0], 100)
            plain = arguments[:arguments.index("--edge-span")] + ["--out"]
            for refused_arguments in (plain + ["refused", "--edge-span", "100"],
                                      plain + ["refused", "--edge-span-input", str(sets["wider"])],
                                      [a for a in arguments if a not in ("--fill", "membrane")],
                                      arguments + ["--edge-span", "0"],
                                      arguments + ["--edge-span-input", str(other)]):
                refused = root / "refused"
                refused_arguments = [str(refused) if a in (str(out), "refused") else a for a in refused_arguments]
                with self.subTest(arguments=refused_arguments[9:]), patch("sys.argv", refused_arguments), \
                        patch("sys.stderr"), self.assertRaises(SystemExit):
                    tower_mask.main()
                self.assertFalse(refused.exists())


if __name__ == "__main__":
    unittest.main()
