from __future__ import annotations

import copy
import hashlib
import io
import tempfile
import unittest
from contextlib import ExitStack, redirect_stdout
from pathlib import Path
from unittest.mock import patch

from map_platform.topography_cache import ElevationCache
from map_platform.topography_discovery import REGIONAL_SOURCES
from map_platform.topography_pipeline import canonical_bytes
from map_platform.topography_regional import regional_contour_sample, regional_mosaic
from map_platform.topography_regional_tiles import RegionalRasterCollection, load_transform_set
from map_platform.topography_transform import load_transform_contract, open_regional_transform
from tests.test_topography_regional import HAS_NATIVE, contract, operation


@unittest.skipUnless(HAS_NATIVE, "install pinned topography dependencies")
class RegionalTileCollectionTests(unittest.TestCase):
    def setUp(self):
        import numpy as np
        from rasterio.transform import from_bounds

        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.cache = ElevationCache(self.root / "cache")
        self.affine = from_bounds(6, 0, 7, 1, 100, 100)
        self.pixels = (np.indices((100, 100))[0] * 5 + np.indices((100, 100))[1] * 3 - 100).astype("float32")
        self.bounds = [6.48, .48, 6.52, .52]
        self.whole = self.stage(self.pixels, self.affine, "whole")

    def stage(self, pixels, affine, name, *, point=False):
        import rasterio

        path = self.root / (name + ".tif")
        with rasterio.open(path, "w", driver="GTiff", width=pixels.shape[1], height=pixels.shape[0], count=1,
                           dtype="float32", crs="EPSG:4326", transform=affine, nodata=-9999) as dataset:
            dataset.write(pixels, 1)
            if point:
                dataset.update_tags(AREA_OR_POINT="Point")
        raw = path.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        (self.cache.root / "blobs" / (digest + ".tif")).write_bytes(raw)
        receipt = {"kind": "bicino-regional-elevation-receipt-v1", "sourceId": "swissalti3d-2m",
                   "discoverySha256": "b" * 64, "itemId": name, "assetKey": name + ".tif",
                   "url": REGIONAL_SOURCES["swissalti3d-2m"].asset_prefixes[0] + name + ".tif",
                   "providerSha256": digest, "sha256": digest, "bytes": len(raw)}
        receipt_path, contract_path = self.root / (name + "-receipt.json"), self.root / (name + "-contract.json")
        receipt_path.write_bytes(canonical_bytes(receipt))
        contract_path.write_bytes(canonical_bytes(contract(digest)))
        return receipt_path, contract_path, path

    def tiles(self, rectangles):
        from rasterio.windows import Window, transform
        return [self.stage(self.pixels[r0:r1, c0:c1], transform(Window(c0, r0, c1-c0, r1-r0), self.affine), str(number))
                for number, (c0, r0, c1, r1) in enumerate(rectangles)]

    def sample(self, tiles):
        return regional_contour_sample(self.cache, [tile[0] for tile in tiles], [tile[1] for tile in tiles], self.root, self.bounds)

    def test_four_tile_interpolation_contours_and_device_sections_match_untiled_raster(self):
        import numpy as np
        import rasterio
        from shapely.geometry import box, mapping
        from map_platform.topography_geometry import compile_contours
        from map_platform.topography_grid import contour_grid

        tiles = self.tiles([(0, 0, 50, 50), (50, 0, 100, 50), (0, 50, 50, 100), (50, 50, 100, 100)])
        with ExitStack() as stack:
            datasets = [stack.enter_context(rasterio.open(tile[2])) for tile in tiles]
            whole = stack.enter_context(rasterio.open(self.whole[2]))
            operation = stack.enter_context(open_regional_transform(load_transform_contract(self.whole[1]), self.root))
            grid = contour_grid(self.bounds, 30, 1_000_000)
            joined = RegionalRasterCollection(datasets)
            np.testing.assert_array_equal(regional_mosaic(joined, operation, grid), regional_mosaic(whole, operation, grid))
        expected, actual = self.sample([self.whole]), self.sample(tiles)
        self.assertEqual(expected["contours"], actual["contours"])
        self.assertEqual(actual["noDataMillionths"], 0)
        selection = mapping(box(6.485, .485, 6.515, .515))
        self.assertGreater(compile_contours(actual, selection).record_count, 0)
        self.assertEqual(compile_contours(expected, selection).sections, compile_contours(actual, selection).sections)
        self.assertEqual(actual["nativeTileCollection"]["tileCount"], 4)

    def test_input_order_and_window_subdivision_cannot_change_evidence(self):
        tiles = self.tiles([(0, 0, 50, 100), (50, 0, 100, 100)])
        expected = self.sample(tiles)
        with patch("map_platform.topography_regional.MAX_NATIVE_WINDOW_PIXELS", 9):
            actual = self.sample(list(reversed(tiles)))
        self.assertEqual(canonical_bytes(expected), canonical_bytes(actual))
        self.assertEqual(load_transform_set([tile[1] for tile in tiles]), load_transform_set([tile[1] for tile in reversed(tiles)]))

    def test_missing_native_tiles_stay_masked_and_do_not_bridge_contours(self):
        tiles = self.tiles([(0, 0, 49, 100), (51, 0, 100, 100)])
        self.pixels[:, 49:51] = -9999
        masked = self.stage(self.pixels, self.affine, "masked-whole")
        expected, actual = self.sample([masked]), self.sample(tiles)
        self.assertGreater(actual["noDataMillionths"], 0)
        self.assertEqual(actual["noDataMillionths"], expected["noDataMillionths"])
        self.assertEqual(actual["contours"], expected["contours"])
        self.assertEqual(actual["sourcePixels"], expected["sourcePixels"])

    def test_masked_neighbors_across_a_tile_boundary_do_not_get_interpolated(self):
        self.pixels[49, 49] = -9999
        masked = self.stage(self.pixels, self.affine, "masked-whole")
        tiles = self.tiles([(0, 0, 50, 100), (50, 0, 100, 100)])
        actual, expected = self.sample(tiles), self.sample([masked])
        self.assertGreater(actual["noDataMillionths"], 0)
        self.assertEqual(actual["noDataMillionths"], expected["noDataMillionths"])
        self.assertEqual(actual["contours"], expected["contours"])

    def test_overlapping_editions_are_rejected_even_if_pixels_agree(self):
        tiles = self.tiles([(0, 0, 60, 100), (50, 0, 100, 100)])
        with self.assertRaisesRegex(ValueError, "footprints overlap"):
            self.sample(tiles)

    def test_resolution_registration_and_origin_mismatch_are_rejected(self):
        from affine import Affine
        from rasterio.windows import Window, transform

        tiles = self.tiles([(0, 0, 50, 100)])
        native = transform(Window(50, 0, 50, 100), self.affine)
        for name, affine, point in (("shift", native * Affine.translation(.1, 0), False),
                                    ("resolution", native * Affine.scale(1.1, 1), False),
                                    ("registration", native, True)):
            tile = self.stage(self.pixels[:, 50:], affine, name, point=point)
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "pixel lattice"):
                self.sample(tiles + [tile])

    def test_mixed_source_review_native_header_and_operations_fail_before_any_raster_open(self):
        tiles = self.tiles([(0, 0, 50, 100), (50, 0, 100, 100)])
        base = load_transform_contract(tiles[1][1])
        base.pop("contractSha256")
        for mutate in (lambda value: value.update(sourceReviewSha256="c" * 64),
                       lambda value: value.update(sourceId="canada-hrdem-lidar"),
                       lambda value: value.update(areaOfUse=[6.1, 0, 7, 1]),
                       lambda value: value.update(horizontalPipeline=operation("+proj=pipeline +step +proj=noop")),
                       lambda value: value["native"].update(noData=None)):
            value = copy.deepcopy(base)
            mutate(value)
            tiles[1][1].write_bytes(canonical_bytes(value))
            with patch("rasterio.open") as opened, self.assertRaisesRegex(ValueError, "identical source review"):
                self.sample(tiles)
            opened.assert_not_called()

    def test_duplicate_missing_extra_contracts_and_collection_limits_fail(self):
        tiles = self.tiles([(0, 0, 50, 100), (50, 0, 100, 100)])
        for receipts, contracts in (([tiles[0][0]] * 2, [tiles[0][1]] * 2),
                                    ([tile[0] for tile in tiles], [tiles[0][1], self.whole[1]]),
                                    ([tile[0] for tile in tiles], [tiles[0][1]]),
                                    ([tiles[0][0]] * 17, [tiles[0][1]] * 17)):
            with self.subTest(counts=(len(receipts), len(contracts))), self.assertRaises(ValueError):
                regional_contour_sample(self.cache, receipts, contracts, self.root, self.bounds)

    def test_native_read_budget_and_cancellation(self):
        import rasterio
        from rasterio.windows import Window

        tiles = self.tiles([(0, 0, 50, 100), (50, 0, 100, 100)])
        with ExitStack() as stack:
            datasets = [stack.enter_context(rasterio.open(tile[2])) for tile in tiles]
            joined = RegionalRasterCollection(datasets)
            with patch("map_platform.topography_regional_tiles.MAX_COLLECTION_WINDOW_PIXELS", 100), self.assertRaisesRegex(ValueError, "bounds"):
                joined.read(1, window=Window(0, 0, 11, 10))
            with self.assertRaisesRegex(ValueError, "integer"):
                joined.read_masks(1, window=Window(.5, 0, 1, 1))
            joined.cancel = lambda: (_ for _ in ()).throw(InterruptedError("cancelled"))
            with self.assertRaises(InterruptedError):
                joined.read(1, window=Window(0, 0, 10, 10))
        self.cache.cancel = lambda: (_ for _ in ()).throw(InterruptedError("cancelled"))
        with self.assertRaises(InterruptedError):
            self.sample(tiles)

    def test_cli_sampling_and_pair_encoding_require_every_exact_contract(self):
        from map_platform.topography_cli import main
        from map_platform.topography_companion import validate_companion
        from tests.map_label_fixtures import one_building_fmb4, one_label_fma1

        tiles = self.tiles([(0, 0, 50, 100), (50, 0, 100, 100)])
        sample_path = self.root / "sample.json"
        source_args = [argument for tile in tiles for argument in ("--source-contract", str(tile[1]))]
        receipt_args = [argument for tile in reversed(tiles) for argument in ("--receipt", str(tile[0]))]
        with redirect_stdout(io.StringIO()):
            self.assertEqual(main(["--cache", str(self.cache.root), "regional-sample", *source_args, *receipt_args,
                                   "--grid-directory", str(self.root), "--bounds", *map(str, self.bounds),
                                   "--output", str(sample_path)]), 0)
        self.assertEqual(sample_path.read_bytes(), canonical_bytes(self.sample(tiles)))
        selected = self.root / "selection.json"
        selected.write_bytes(canonical_bytes({"type": "Polygon", "coordinates": [
            [[6.485, .485], [6.515, .485], [6.515, .515], [6.485, .515], [6.485, .485]]]}))
        vector = self.root / "vector"
        font = vector / "VECTMAP/test/assets/street-labels.fma"
        font.parent.mkdir(parents=True)
        font.write_bytes(one_label_fma1())
        block = vector / "VECTMAP/test/+000+000/0_0.fmb"
        block.parent.mkdir(parents=True)
        block.write_bytes(one_building_fmb4())
        notices = self.root / "notices.txt"
        notices.write_text("Synthetic tiled elevation fixture. Not for distribution.\n")
        output = self.root / "pair"
        args = ["--cache", str(self.cache.root), "encode", "--sample", str(sample_path), "--selection", str(selected),
                "--vector-pack", str(vector), "--map-id", "test", "--attribution", str(notices), "--output", str(output)]
        for wrong in ([], source_args[:2], source_args + ["--source-contract", str(self.whole[1])]):
            with patch("sys.stderr", io.StringIO()), self.assertRaises((SystemExit, ValueError)):
                main(args + wrong)
            self.assertFalse(output.exists())
        with redirect_stdout(io.StringIO()):
            self.assertEqual(main(args + source_args), 0)
        self.assertTrue((output / "topography-receipt.json").is_file())
        validate_companion(next(output.glob("*.btopo")))


if __name__ == "__main__":
    unittest.main()
