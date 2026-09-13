from __future__ import annotations

import copy
import hashlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from contextlib import redirect_stdout
from unittest.mock import patch

from map_platform.topography_cache import ElevationCache
from map_platform.topography_discovery import REGIONAL_SOURCES, discover_regional
from map_platform.topography_pipeline import canonical_bytes
from map_platform.topography_regional_cache import stage_regional_asset, verified_discovery
from map_platform.topography_transform import load_transform_contract, open_regional_transform, pipeline_grid_names
from tests.test_topography import Response
from tests.test_topography_discovery import feature


def operation(proj):
    return {"proj": proj, "sha256": hashlib.sha256(proj.encode()).hexdigest()}


def contract(asset_sha):
    return {"schemaVersion": 1, "sourceId": "swissalti3d-2m", "assetSha256": asset_sha,
            "sourceReviewSha256": "a" * 64, "sourceVerticalDatum": "EPSG:3855", "targetVerticalDatum": "EPSG:3855",
            "native": {"horizontalEpsg": 4326, "dtype": "float32", "noData": -9999, "bandUnits": None},
            "areaOfUse": [6, 0, 7, 1], "horizontalPipeline": operation("+proj=noop"),
            "verticalPipeline": operation("+proj=noop"), "grids": [], "productionApproved": False}


class RegionalStagingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.body = b"II*\0" + b"native" * 50
        source = REGIONAL_SOURCES["swissalti3d-2m"]
        item = feature("swissalti3d-2m")
        item["assets"]["tile-1_2_2056_5728.tif"]["file:checksum"] = "1220" + hashlib.sha256(self.body).hexdigest()
        docs = iter([{"id": source.collection_id, "license": "proprietary"},
                     {"type": "FeatureCollection", "features": [item], "links": []}])
        snapshot = discover_regional("swissalti3d-2m", [6.1, 45.1, 6.2, 45.2],
                                     fetch=lambda *a: canonical_bytes(next(docs)))
        self.discovery = self.root / "discovery.json"
        self.discovery.write_bytes(canonical_bytes(snapshot))
        self.calls = []

        def fetch(request, timeout):
            self.calls.append(request.full_url)
            return Response(self.body, request.full_url)

        self.cache = ElevationCache(self.root / "cache", opener=fetch)

    def test_native_staging_is_immutable_rehashed_and_bound_to_discovery(self):
        receipt = stage_regional_asset(self.cache, self.discovery, "tile-1")
        self.assertEqual(receipt, stage_regional_asset(self.cache, self.discovery, "tile-1"))
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(receipt["providerSha256"], receipt["sha256"])
        self.cache.verify(receipt).write_bytes(b"X" * receipt["bytes"])
        with self.assertRaisesRegex(ValueError, "does not match"):
            stage_regional_asset(self.cache, self.discovery, "tile-1")
        self.assertEqual(len(self.calls), 1)

    def test_normalized_claims_are_replayed_not_trusted(self):
        value = json.loads(self.discovery.read_bytes())
        value["assets"][0]["url"] = value["assets"][0]["url"].replace("tile-1", "tile-2")
        self.discovery.write_bytes(canonical_bytes(value))
        with self.assertRaisesRegex(ValueError, "claims differ"):
            stage_regional_asset(self.cache, self.discovery, "tile-1")
        self.assertFalse(self.calls)

    def test_bad_provider_checksum_publishes_no_receipt(self):
        self.body = self.body[:-1] + b"!"
        with self.assertRaisesRegex(ValueError, "does not match"):
            stage_regional_asset(self.cache, self.discovery, "tile-1")
        self.assertFalse(list((self.cache.root / "receipts").iterdir()))

    def test_missing_page_and_changed_metadata_hash_fail_before_network(self):
        value = json.loads(self.discovery.read_bytes())
        value["documents"][1]["utf8"] += " "
        self.discovery.write_bytes(canonical_bytes(value))
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            verified_discovery(self.discovery)
        self.assertFalse(self.calls)


class TransformContractTests(unittest.TestCase):
    def test_implicit_optional_remote_and_unlisted_grid_operations_are_rejected(self):
        for pipeline in ("EPSG:4326", "+proj=vgridshift +grids=@missing.gtx", "+proj=vgridshift +grids=null",
                         "+proj=vgridshift +grids=https://example.com/grid", "+init=epsg:4326",
                         "+proj=longlat +datum=WGS84", "+proj=pipeline +step +proj=unknown",
                         "+proj=noop +misspelled_option=1"):
            with self.subTest(pipeline=pipeline), self.assertRaises(ValueError):
                pipeline_grid_names(pipeline)

    def test_missing_datum_grid_wrong_hash_and_unknown_approval_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "contract.json"
            base = contract("b" * 64)
            changes = [lambda d: d.update(sourceVerticalDatum="EGM96"),
                       lambda d: d.update(productionApproved=True),
                       lambda d: d["horizontalPipeline"].update(sha256="c" * 64),
                       lambda d: d.update(verticalPipeline=operation("+proj=vgridshift +grids={missing.tif}")),
                       lambda d: d["native"].update(horizontalEpsg=True),
                       lambda d: d["native"].update(noData=True)]
            for mutate in changes:
                value = copy.deepcopy(base)
                mutate(value)
                path.write_bytes(canonical_bytes(value))
                with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                    load_transform_contract(path)


HAS_NATIVE = all(importlib.util.find_spec(name) is not None for name in ("pyproj", "numpy", "rasterio", "contourpy"))


@unittest.skipUnless(HAS_NATIVE, "install pinned topography dependencies")
class RegionalPipelineTests(unittest.TestCase):
    def setUp(self):
        import numpy as np
        import rasterio
        from rasterio.transform import from_bounds
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.cache = ElevationCache(self.root / "cache")
        self.tiff = self.root / "height.tif"
        with rasterio.open(self.tiff, "w", driver="GTiff", width=100, height=100, count=1, dtype="float32",
                           crs="EPSG:4326", transform=from_bounds(6, 0, 7, 1, 100, 100), nodata=-9999) as dataset:
            dataset.write((np.indices((100, 100))[0] * 5 + np.indices((100, 100))[1] * 3 - 100).astype("float32"), 1)
        raw = self.tiff.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        (self.cache.root / "blobs" / (digest + ".tif")).write_bytes(raw)
        self.receipt = {"kind": "bicino-regional-elevation-receipt-v1", "sourceId": "swissalti3d-2m",
                        "discoverySha256": "b" * 64, "itemId": "synthetic", "assetKey": "synthetic.tif",
                        "url": REGIONAL_SOURCES["swissalti3d-2m"].asset_prefixes[0] + "synthetic.tif",
                        "providerSha256": digest, "sha256": digest, "bytes": len(raw)}
        self.receipt_path = self.root / "receipt.json"
        self.receipt_path.write_bytes(canonical_bytes(self.receipt))
        self.contract = contract(digest)
        self.contract_path = self.root / "contract.json"
        self.contract_path.write_bytes(canonical_bytes(self.contract))

    def sample(self):
        from map_platform.topography_regional import regional_contour_sample
        return regional_contour_sample(self.cache, self.receipt_path, self.contract_path, self.root, [6.2, .2, 6.25, .25])

    def test_regional_pipeline_feeds_same_contour_compiler_repeatably(self):
        from shapely.geometry import box, mapping
        from map_platform.topography_geometry import compile_contours
        first, second = self.sample(), self.sample()
        self.assertEqual(canonical_bytes(first), canonical_bytes(second))
        self.assertEqual(first["surfaceModel"], "dtm")
        self.assertEqual(first["verticalDatum"], "EPSG:3855")
        self.assertEqual(first["noDataMillionths"], 0)
        self.assertGreater(compile_contours(first, mapping(box(6.205, .205, 6.245, .245))).record_count, 0)

    def test_native_inspection_draft_cannot_masquerade_as_reviewed_contract(self):
        from map_platform.topography_regional import inspect_regional_asset
        inspection = inspect_regional_asset(self.cache, self.receipt_path)
        self.assertEqual(inspection["draftContract"]["native"], self.contract["native"])
        self.assertIsNone(inspection["draftContract"]["sourceVerticalDatum"])
        self.assertFalse(inspection["productionEligible"])
        self.contract_path.write_bytes(canonical_bytes(inspection["draftContract"]))
        with self.assertRaises(ValueError):
            load_transform_contract(self.contract_path)

    def test_projected_native_grid_uses_pinned_horizontal_operation(self):
        import numpy as np
        import rasterio
        from rasterio.transform import from_origin
        from map_platform.topography_grid import contour_grid
        from map_platform.topography_regional import regional_mosaic
        projected = self.root / "projected.tif"
        grid = contour_grid([6.2, .2, 6.25, .25], 30, 4_000_000)
        with rasterio.open(projected, "w", driver="GTiff", width=grid.width, height=grid.height, count=1,
                           dtype="float32", crs=grid.crs, transform=from_origin(grid.left, grid.top, 30, 30), nodata=-9999) as dataset:
            dataset.write(np.full((grid.height, grid.width), -20, dtype="float32"), 1)
        self.contract["horizontalPipeline"] = operation("+proj=pipeline +step +proj=unitconvert +xy_in=deg +xy_out=rad "
                                                        "+step +proj=utm +zone=32 +ellps=WGS84")
        self.contract_path.write_bytes(canonical_bytes(self.contract))
        loaded = load_transform_contract(self.contract_path)
        with rasterio.open(projected) as dataset, open_regional_transform(loaded, self.root) as operation_context:
            output = regional_mosaic(dataset, operation_context, grid)
        self.assertTrue(np.all(output == -20))

    def test_bounded_native_windows_preserve_results(self):
        first = self.sample()
        with patch("map_platform.topography_regional.MAX_NATIVE_WINDOW_PIXELS", 9):
            second = self.sample()
        self.assertEqual(canonical_bytes(first), canonical_bytes(second))

    def test_wrong_header_area_and_asset_identity_are_rejected(self):
        for mutate in (lambda d: d["native"].update(horizontalEpsg=2056),
                       lambda d: d.update(areaOfUse=[6.22, .22, 6.23, .23]),
                       lambda d: d.update(assetSha256="c" * 64)):
            value = copy.deepcopy(self.contract)
            mutate(value)
            self.contract_path.write_bytes(canonical_bytes(value))
            with self.assertRaises(ValueError):
                self.sample()

    def test_implicit_network_context_and_cancelled_work_are_rejected(self):
        loaded = load_transform_contract(self.contract_path)
        with patch("pyproj.network.is_network_enabled", return_value=True), self.assertRaisesRegex(ValueError, "network must be disabled"):
            with open_regional_transform(loaded, self.root):
                self.fail("network enabled")
        self.cache.cancel = lambda: (_ for _ in ()).throw(InterruptedError("cancelled"))
        with self.assertRaises(InterruptedError):
            self.sample()

    def test_regional_cli_encodes_device_companion_with_exact_contract(self):
        from map_platform.topography_cli import main
        from tests.map_label_fixtures import one_building_fmb4, one_label_fma1
        from map_platform.topography_companion import validate_companion
        sample = self.sample()
        sample_path = self.root / "sample.json"
        sample_path.write_bytes(canonical_bytes(sample))
        selected = self.root / "selection.json"
        selected.write_bytes(canonical_bytes({"type": "Polygon", "coordinates": [
            [[6.205, .205], [6.245, .205], [6.245, .245], [6.205, .245], [6.205, .205]]]}))
        vector = self.root / "vector"
        font = vector / "VECTMAP/test/assets/street-labels.fma"
        font.parent.mkdir(parents=True)
        font.write_bytes(one_label_fma1())
        block = vector / "VECTMAP/test/+000+000/0_0.fmb"
        block.parent.mkdir(parents=True)
        block.write_bytes(one_building_fmb4())
        notices = self.root / "notices.txt"
        notices.write_text("Synthetic test source, no distribution approval.\n")
        output = self.root / "pair"
        args = ["--cache", str(self.cache.root), "encode", "--sample", str(sample_path),
                "--selection", str(selected), "--vector-pack", str(vector), "--map-id", "test",
                "--attribution", str(notices), "--output", str(output)]
        with patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit):
            main(args)
        self.assertFalse(output.exists())
        with redirect_stdout(io.StringIO()):
            self.assertEqual(main(args + ["--source-contract", str(self.contract_path)]), 0)
        self.assertTrue((output / "topography-receipt.json").is_file())
        self.assertEqual(len(list(output.glob("*.btopo"))), 1)
        validate_companion(next(output.glob("*.btopo")))

    def test_vertical_grid_is_real_offline_hashed_and_area_bounded(self):
        import numpy as np
        import rasterio
        from rasterio.transform import from_bounds
        grid = self.root / "offset.tif"
        with rasterio.open(grid, "w", driver="GTiff", width=8, height=8, count=1, dtype="float32",
                           crs="EPSG:4326", transform=from_bounds(5, -1, 8, 2, 8, 8)) as dataset:
            dataset.write(np.full((8, 8), 10, dtype="float32"), 1)
            dataset.update_tags(TYPE="VERTICAL_OFFSET")
        self.contract["sourceVerticalDatum"] = "synthetic-test-datum"
        self.contract["grids"] = [{"name": grid.name, "sha256": hashlib.sha256(grid.read_bytes()).hexdigest(), "bytes": grid.stat().st_size}]
        self.contract["verticalPipeline"] = operation("+proj=pipeline +step +proj=unitconvert +xy_in=deg +xy_out=rad "
                                                       "+step +proj=vgridshift +grids={offset.tif} +multiplier=1 "
                                                       "+step +proj=unitconvert +xy_in=rad +xy_out=deg")
        self.contract_path.write_bytes(canonical_bytes(self.contract))
        loaded = load_transform_contract(self.contract_path)
        with open_regional_transform(loaded, self.root) as transform:
            self.assertAlmostEqual(transform.egm2008([6.2], [.2], [100.0])[0], 110.0, places=5)
            with self.assertRaisesRegex(ValueError, "outside"):
                transform.egm2008([0], [0], [100])
            # The open transform holds private copies, not these mutable bytes.
            grid.write_bytes(b"bad")
            self.assertAlmostEqual(transform.egm2008([6.2], [.2], [100.0])[0], 110.0, places=5)
        with self.assertRaisesRegex(ValueError, "missing or changed"):
            with open_regional_transform(loaded, self.root):
                self.fail("changed grid must not open")
        with self.assertRaisesRegex(ValueError, "context is closed"):
            transform.egm2008([6.2], [.2], [100.0])
