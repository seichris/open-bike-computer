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
            # A grid over the whole cell and one grid cell more on every side, with one district of towers.
            heights = np.zeros((1202, 1202), dtype="float32")
            heights[336:366, 336:366] = 60       # posts 1005 to 1094, both ways
            file = root / "GHS_BUILT_H_ANBH_test.tif"
            with grid(heights, -74 - 3 / 3600, 41 + 3 / 3600) as memory:
                file.write_bytes(memory.read())
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
                            ["--input", str(root)], ["--threshold", "0"], ["--margin", "5"],
                            ["--bounds", "-74", "40", "-66", "44"]):
                refused = root / "refused"
                with self.subTest(changed=changed), patch("sys.argv", arguments[:-1] + [str(refused)] + changed), \
                        patch("sys.stderr"), self.assertRaises(SystemExit):
                    tower_mask.main()
                self.assertFalse(refused.exists())


if __name__ == "__main__":
    unittest.main()
