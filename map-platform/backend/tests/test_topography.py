from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from map_platform.topography_cache import ElevationCache, _SourceRedirects
from map_platform.topography_sources import (
    TopographySourcePolicy, geocells, load_topography_source_policy,
    parse_tile_index, plan_elevation,
)
from map_platform.topography_pipeline import canonical_bytes, canonical_line, contour_sample
from map_platform.topography_grid import contour_grid, processing_region, region_resolution
from map_platform.topography_cli import main as cli_main

ROOT = Path(__file__).resolve().parents[3]
POLICY = ROOT / "map-platform/config/topography-source-policy-v1.json"


def fixture_source(source, cells):
    raw = ("\r\n".join(source.tile_name(*cell) for cell in cells) + "\r\n").encode()
    return replace(source, index_sha256=hashlib.sha256(raw).hexdigest(),
                   index_bytes=len(raw), tile_count=len(cells)), raw


class Response(io.BytesIO):
    def __init__(self, body, url, headers=None, status=200):
        super().__init__(body)
        self.url, self.status = url, status
        self.headers = headers if headers is not None else {"Content-Length": str(len(body))}

    def geturl(self):
        return self.url


class TopographyPolicyTests(unittest.TestCase):
    def setUp(self):
        self.policy = load_topography_source_policy(ROOT)

    def test_global_sources_are_free_and_cannot_advertise_generation(self):
        self.assertEqual([s.resolution_m for s in self.policy.sources], [30, 90])
        self.assertEqual(self.policy.public_summary()["access"], "free")
        self.assertFalse(self.policy.public_summary()["generationEnabled"])

    def test_invalid_configuration_fails_closed(self):
        mutations = [
            lambda p: p.update(schemaVersion=True),
            lambda p: p.update(access="premium"),
            lambda p: p.update(extra=1),
            lambda p: p["sources"][0].update(productionApproved=True),
            lambda p: p["sources"][0].update(priority=True),
            lambda p: p["sources"][1].update(priority=100),
            lambda p: p["sources"][0].update(origin="http://localhost"),
            lambda p: p["sources"][0].update(verticalDatum="unknown"),
            lambda p: p["sources"][0].update(tileIndexSha256="A" * 64),
            lambda p: p["sources"][0].update(termsUrl="https://user:secret@example.com"),
            lambda p: p["sources"][0].update(accessReviewedAt="20260912"),
            lambda p: p["sources"].reverse(),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "policy.json"
            for mutate in mutations:
                payload = json.loads(POLICY.read_bytes())
                mutate(payload)
                target.write_text(json.dumps(payload))
                with self.subTest(payload=payload), self.assertRaises(ValueError):
                    TopographySourcePolicy.load(target)
            target.write_text('{"schemaVersion":1,"schemaVersion":1}')
            with self.assertRaisesRegex(ValueError, "duplicate"):
                TopographySourcePolicy.load(target)

    def test_half_open_cells_negative_coordinates_dateline_and_poles(self):
        self.assertEqual(geocells([-1, -1, 0, 0]), ((-1, -1),))
        self.assertEqual(geocells([179.5, 0, -179.5, 1]), ((-180, 0), (179, 0)))
        self.assertEqual(geocells([5, 89.5, 6, 90]), ((5, 89),))
        for bounds in ([0, 0, 0, 1], [0, 0, 361, 1], [True, 0, 1, 1],
                       [0, 0, float("nan"), 1], [-180, -90, 180, 90]):
            with self.subTest(bounds=bounds), self.assertRaises(ValueError):
                geocells(bounds)
        for maximum in (True, 0, 257):
            with self.assertRaises(ValueError):
                geocells([0, 0, 1, 1], maximum=maximum)

    def test_priority_fallback_gaps_and_quality_are_deterministic(self):
        primary, fallback = self.policy.sources
        indexes = {fallback.id: frozenset({(0, 0), (1, 0)}), primary.id: frozenset({(0, 0)})}
        plan = plan_elevation(self.policy, indexes, [0, 0, 3, 1])
        self.assertEqual([t["sourceId"] for t in plan["tiles"]], [primary.id, fallback.id])
        self.assertEqual(plan["uncoveredCells"], [[2, 0]])
        self.assertEqual(plan["qualityMode"], "coarse-50m-v1")
        self.assertEqual(plan["minorIntervalM"], 50)
        self.assertFalse(plan["coverageComplete"])
        self.assertEqual(canonical_bytes(plan), canonical_bytes(plan_elevation(self.policy, dict(reversed(list(indexes.items()))), [0, 0, 3, 1])))
        with self.assertRaisesRegex(ValueError, "all pinned"):
            plan_elevation(self.policy, {primary.id: indexes[primary.id]}, [0, 0, 1, 1])

    def test_index_integrity_and_canonical_tile_names(self):
        source, raw = fixture_source(self.policy.sources[0], [(6, 0), (-1, -1)])
        self.assertEqual(parse_tile_index(source, raw), frozenset({(6, 0), (-1, -1)}))
        with self.assertRaises(ValueError):
            parse_tile_index(source, raw[:-1])
        duplicate, raw = fixture_source(source, [(6, 0), (6, 0)])
        with self.assertRaisesRegex(ValueError, "duplicate"):
            parse_tile_index(duplicate, raw)
        for name in (source.tile_name(0, 0).replace("N00", "S00"),
                     source.tile_name(0, 0).replace("COG_10", "COG_30"), "../other"):
            with self.assertRaises(ValueError):
                source.parse_tile_name(name)

    def test_download_authority_is_exact(self):
        source = self.policy.sources[0]
        url = source.tile_url(6, 0)
        self.assertEqual(source.validate_url(url), url)
        for invalid in (url.replace("https:", "http:"), url + "?token=a", url + "#x",
                        url.replace(".com/", ".com.evil/"), source.origin + "/anything.tif",
                        url.replace(".com/", ".com:443/")):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                source.validate_url(invalid)


class TopographyCacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.source, self.index = fixture_source(load_topography_source_policy(ROOT).sources[0], [(6, 0)])
        self.body = b"II*\0" + b"data" * 100
        self.urls = []
        self.response_factory = Response
        self.cache = ElevationCache(Path(self.tmp.name), opener=self.open)

    def open(self, request, timeout):
        self.urls.append(request.full_url)
        data = self.index if request.full_url == self.source.index_url else self.body
        return self.response_factory(data, request.full_url)

    def test_repeat_staging_rehashes_without_network(self):
        first = self.cache.stage(self.source, (6, 0))
        self.assertEqual(first, self.cache.stage(self.source, (6, 0)))
        self.assertEqual(len(self.urls), 2)
        self.assertEqual(self.cache.verify(first).read_bytes(), self.body)
        self.cache.verify(first).write_bytes(b"X" * len(self.body))
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.cache.stage(self.source, (6, 0))
        self.assertEqual(len(self.urls), 2)

    def test_corrupt_index_does_not_replace_or_publish(self):
        self.index = b"bad"
        with self.assertRaisesRegex(ValueError, "receipt"):
            self.cache.index(self.source)
        self.assertEqual(list((self.cache.root / "indexes").iterdir()), [])

    def test_concurrent_staging_publishes_one_receipt(self):
        with ThreadPoolExecutor(max_workers=2) as executor:
            receipts = list(executor.map(lambda _: self.cache.stage(self.source, (6, 0)), range(2)))
        self.assertEqual(receipts[0], receipts[1])
        self.assertEqual(len(self.urls), 2)

    def test_receipt_authority_and_types_are_revalidated(self):
        self.cache.stage(self.source, (6, 0))
        path = next((self.cache.root / "receipts").iterdir())
        original = json.loads(path.read_text())
        for mutation in ({"cell": [6, False]}, {"bytes": True}, {"sourceId": "other"},
                         {"url": self.source.tile_url(7, 0)}, {"extra": 1}):
            path.write_text(json.dumps({**original, **mutation}))
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.cache.stage(self.source, (6, 0))
        self.assertEqual(len(self.urls), 2)

    def test_mid_stream_cancellation_does_not_publish(self):
        self.cache.index(self.source)
        original = self.open

        def opened(request, timeout):
            response = original(request, timeout)
            read = response.read

            def cancelled():
                raise RuntimeError("cancelled during download")

            def first_chunk(size):
                chunk = read(size)
                self.cache.cancel = cancelled
                return chunk

            response.read = first_chunk
            return response

        self.cache.opener = opened
        with self.assertRaisesRegex(RuntimeError, "during download"):
            self.cache.stage(self.source, (6, 0))
        self.assertEqual(list((self.cache.root / "receipts").iterdir()), [])
        self.assertEqual(list((self.cache.root / "blobs").iterdir()), [])

    def test_truncation_invalid_tiff_and_size_limit_leave_no_receipt(self):
        self.cache.index(self.source)
        for body, factory in [(b"<html>oops</html>", Response),
                              (self.body, lambda data, url: Response(data, url, {"Content-Length": "999"})),
                              (self.body, lambda data, url: Response(data, url, {"Content-Length": str(2**30)})),
                              (self.body, lambda data, url: Response(data, url, status=206))]:
            self.body, self.response_factory = body, factory
            with self.subTest(body=body[:4]), self.assertRaises(ValueError):
                self.cache.stage(self.source, (6, 0))
            self.assertEqual(list((self.cache.root / "receipts").iterdir()), [])
            self.assertFalse(any(p.name.startswith("tile-") for p in self.cache.root.iterdir()))

    def test_oversize_without_content_length_is_rejected(self):
        self.cache.index(self.source)
        self.response_factory = lambda data, url: Response(data, url, {})
        with patch("map_platform.topography_cache.MAX_TILE_BYTES", 16), self.assertRaisesRegex(ValueError, "exceeds bound"):
            self.cache.stage(self.source, (6, 0))

    def test_cancellation_and_space_admission_before_io(self):
        with patch.object(self.cache, "cancel", side_effect=RuntimeError("cancelled")):
            with self.assertRaisesRegex(RuntimeError, "cancelled"):
                self.cache.stage(self.source, (6, 0))
        self.assertFalse(self.urls)
        with patch("map_platform.topography_cache.shutil.disk_usage") as disk:
            disk.return_value.free = 1
            with self.assertRaisesRegex(ValueError, "space"):
                self.cache.index(self.source)
        self.assertFalse(self.urls)

    def test_redirect_and_missing_index_never_trigger_fallback(self):
        import urllib.request
        source = self.source
        with self.assertRaises(ValueError):
            _SourceRedirects(source).redirect_request(urllib.request.Request(source.tile_url(6, 0)), None,
                                                     302, "", {}, source.tile_url(7, 0))
        with self.assertRaisesRegex(ValueError, "absent"):
            self.cache.stage(source, (7, 0))
        self.assertEqual(self.urls, [source.index_url])


class ContourCanonicalizationTests(unittest.TestCase):
    def test_open_and_closed_line_order(self):
        points = [(0, 0), (1, 0), (1, 1), (0, 0)]
        expected = canonical_line(points)
        self.assertEqual(expected, canonical_line(list(reversed(points))))
        self.assertEqual(expected, canonical_line([(1, 1), (0, 0), (1, 0), (1, 1)]))
        self.assertEqual(canonical_line([(0, 0), (0, 0), (1, 1)]), ((0, 0), (1000, 1000)))
        self.assertEqual(canonical_line([(0, 0), (0, 0)]), ())


class ProcessingRegionTests(unittest.TestCase):
    def test_regions_are_fixed_and_boundary_crossing_is_explicit(self):
        self.assertEqual(processing_region([6, 0, 12, 1]), "EPSG:32632")
        self.assertEqual(processing_region([6, -1, 12, 0]), "EPSG:32732")
        self.assertEqual(processing_region([6, 84, 7, 85]), "EPSG:3413")
        self.assertEqual(processing_region([6, -81, 7, -80]), "EPSG:3031")
        self.assertEqual(processing_region([174, 1, 180, 2]), "EPSG:32660")
        for bounds in ([5.9, 1, 6.1, 2], [6, -.1, 7, .1], [6, 83.9, 7, 84.1],
                       [6, -80.1, 7, -79.9], [179, 0, -179, 1], [True, 0, 2, 1]):
            with self.subTest(bounds=bounds), self.assertRaises(ValueError):
                processing_region(bounds)

    def test_coarse_profile_is_region_wide_not_request_dependent(self):
        policy = load_topography_source_policy(ROOT)
        primary, fallback = policy.sources
        indexes = {primary.id: frozenset({(6, 0)}), fallback.id: frozenset({(6, 0), (9, 60)})}
        self.assertEqual(region_resolution(policy, indexes, "EPSG:32632"), 90)
        self.assertEqual(region_resolution(policy, indexes, "EPSG:32631"), 30)
        indexes[fallback.id] = frozenset({(6, 0)})
        self.assertEqual(region_resolution(policy, indexes, "EPSG:32632"), 30)


class TopographyCLITests(unittest.TestCase):
    def test_coverage_reports_union_and_incremental_fallback(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(ElevationCache, "index") as index:
            index.side_effect = [frozenset({(0, 0)}), frozenset({(0, 0), (1, 0)})]
            output = io.StringIO()
            with redirect_stdout(output):
                self.assertEqual(cli_main(["--repo-root", str(ROOT), "--cache", tmp, "coverage"]), 0)
            report = json.loads(output.getvalue())
            self.assertEqual(report["coveredGeocells"], 2)
            self.assertEqual([s["additionalGeocells"] for s in report["sources"]], [1, 1])
            self.assertFalse(report["generationEnabled"])

    def test_uncovered_plan_reports_nonzero_status_without_staging(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(ElevationCache, "index", return_value=frozenset()), \
                patch.object(ElevationCache, "stage", side_effect=AssertionError("must not stage")):
            output = io.StringIO()
            with redirect_stdout(output):
                status = cli_main(["--repo-root", str(ROOT), "--cache", tmp, "plan", "--bounds", "0", "0", "1", "1"])
            self.assertEqual(status, 2)
            self.assertEqual(json.loads(output.getvalue())["uncoveredCells"], [[0, 0]])

    def test_sample_is_atomic_canonical_and_never_overwrites(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(ElevationCache, "index", return_value=frozenset({(0, 0)})), \
                patch("map_platform.topography_cli.contour_sample", return_value={"productionEligible": False, "test": 1}):
            output = Path(tmp) / "result.json"
            args = ["--repo-root", str(ROOT), "--cache", tmp, "sample", "--bounds", "0", "0", "1", "1", "--output", str(output)]
            with redirect_stdout(io.StringIO()):
                self.assertEqual(cli_main(args), 0)
            first = output.read_bytes()
            self.assertEqual(first, canonical_bytes({"productionEligible": False, "test": 1}))
            with patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit):
                cli_main(args)
            self.assertEqual(output.read_bytes(), first)


HAS_RASTER = all(importlib.util.find_spec(name) is not None for name in ("contourpy", "numpy", "rasterio"))
if HAS_RASTER:
    # A missing optional extra may skip integration tests; a broken installed
    # native library must fail the suite, not silently turn its checks green.
    import contourpy
    import numpy as np
    import rasterio


@unittest.skipUnless(HAS_RASTER, "install the topography extra for raster integration")
class TopographyPipelineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        source, raw = fixture_source(load_topography_source_policy(ROOT).sources[0], [(6, 0)])
        self.policy = TopographySourcePolicy((source,), "a" * 64, 1)
        from rasterio.io import MemoryFile
        from rasterio.transform import from_bounds
        data = (np.indices((100, 100))[0] * 5 + np.indices((100, 100))[1] * 3 - 100).astype("float32")
        with MemoryFile() as memory:
            with memory.open(driver="GTiff", width=100, height=100, count=1, dtype="float32",
                             crs="EPSG:4326", transform=from_bounds(6, 0, 7, 1, 100, 100), nodata=-32767) as dataset:
                dataset.write(data, 1)
            self.tiff = memory.read()
        self.cache = ElevationCache(Path(self.tmp.name), opener=lambda request, timeout: Response(
            raw if request.full_url == source.index_url else self.tiff, request.full_url))

    def test_real_raster_reprojection_and_contours_are_byte_identical(self):
        bounds = [6.2, 0.2, 6.25, 0.25]
        first = contour_sample(self.policy, self.cache, bounds)
        second = contour_sample(self.policy, self.cache, bounds)
        self.assertEqual(canonical_bytes(first), canonical_bytes(second))
        self.assertTrue(first["contours"])
        self.assertFalse(first["productionEligible"])
        self.assertEqual(first["noDataMillionths"], 0)
        self.assertTrue(all(record["elevationM"] % 20 == 0 for record in first["contours"]))
        self.assertEqual(first["processingGrid"]["haloPixels"], 4)
        self.assertEqual(first["processingGrid"]["originM"], [0, 0])
        audit = first["nativeRasterAudits"][0]
        self.assertEqual(audit["declaredNoData"], -32767)
        self.assertEqual(audit["dimensions"], [100, 100])
        self.assertEqual(audit["waterMask"], "unavailable-in-height-only-input")

    def test_fractional_e7_selection_remains_inside_contour_mosaic(self):
        from shapely.geometry import box, mapping
        from map_platform.topography_geometry import compile_contours

        # Real map requests retain sub-E7 coordinates. Rounding the sample
        # envelope inward makes a valid selection fail at contour compilation.
        bounds = [6.20000004184229, .20000003870287, 6.25000003839369, .250000007377274]
        sample = contour_sample(self.policy, self.cache, bounds)
        west, south, east, north = [value / 10_000_000 for value in sample["boundsE7"]]
        self.assertLessEqual(west, bounds[0])
        self.assertLessEqual(south, bounds[1])
        self.assertGreaterEqual(east, bounds[2])
        self.assertGreaterEqual(north, bounds[3])
        self.assertGreater(compile_contours(sample, mapping(box(*bounds))).record_count, 0)

    def test_overlapping_grids_have_the_same_pixel_lattice(self):
        a = contour_grid([6.2, .2, 6.25, .25], 30, 4_000_000)
        b = contour_grid([6.22, .22, 6.27, .27], 30, 4_000_000)
        self.assertEqual(a.crs, b.crs)
        self.assertEqual((a.left - b.left) % 30, 0)
        self.assertEqual((a.top - b.top) % 30, 0)
        self.assertLess(a.acquisition_bounds[0], 6.2)
        self.assertGreater(a.acquisition_bounds[2], 6.25)

    def test_overlapping_samples_produce_matching_interior_contours(self):
        from shapely.geometry import box, mapping
        from map_platform.topography_geometry import compile_contours
        from map_platform.topography_artifacts import encode_contour_section
        a = contour_sample(self.policy, self.cache, [6.20, .20, 6.25, .25])
        b = contour_sample(self.policy, self.cache, [6.21, .21, 6.26, .26])
        selection = mapping(box(6.215, .215, 6.245, .245))
        left, right = (compile_contours(sample, selection) for sample in (a, b))
        self.assertTrue(left.sections)
        self.assertEqual({k: encode_contour_section(v) for k, v in left.sections.items()},
                         {k: encode_contour_section(v) for k, v in right.sections.items()})

    def test_missing_halo_rejected_before_native_download(self):
        with patch.object(self.cache, "stage", side_effect=AssertionError("must not download")):
            with self.assertRaisesRegex(ValueError, "halo has uncovered"):
                contour_sample(self.policy, self.cache, [6.999, .2, 7, .201])

    def test_internal_validity_mask_precedes_interpolation(self):
        receipt = self.cache.stage(self.policy.sources[0], (6, 0))
        path = self.cache.verify(receipt)
        with rasterio.Env(GDAL_TIFF_INTERNAL_MASK=True), rasterio.open(path, "r+") as dataset:
            data = dataset.read(1)
            data[:, 25:] = 999999  # Must never bleed into otherwise valid heights.
            dataset.write(data, 1)
            mask = np.full((100, 100), 255, dtype="uint8")
            mask[:, 25:] = 0
            dataset.write_mask(mask)
        with patch.object(self.cache, "stage", return_value=receipt), patch.object(self.cache, "verify", return_value=path):
            sample = contour_sample(self.policy, self.cache, [6.2, .2, 6.3, .3])
        self.assertGreater(sample["noDataMillionths"], 0)
        self.assertEqual(sample["nativeRasterAudits"][0]["invalidPixels"], 7500)
        self.assertTrue(sample["contours"])
        self.assertTrue(all(record["elevationM"] < 1000 for record in sample["contours"]))

    def test_undeclared_sentinel_and_units_cannot_be_smoothed_away(self):
        receipt = self.cache.stage(self.policy.sources[0], (6, 0))
        path = self.cache.verify(receipt)
        with rasterio.open(path, "r+") as dataset:
            data = dataset.read(1)
            data[50, 50] = -32768
            dataset.write(data, 1)
        with patch.object(self.cache, "stage", return_value=receipt), patch.object(self.cache, "verify", return_value=path):
            with self.assertRaisesRegex(ValueError, "native DEM elevations"):
                contour_sample(self.policy, self.cache, [6.2, .2, 6.25, .25])
            with rasterio.open(path, "r+") as dataset:
                dataset.scales = (0.3048,)
            with self.assertRaisesRegex(ValueError, "scale or offset"):
                contour_sample(self.policy, self.cache, [6.2, .2, 6.25, .25])

    def test_nan_and_ordinary_negative_heights_are_distinguished(self):
        receipt = self.cache.stage(self.policy.sources[0], (6, 0))
        path = self.cache.verify(receipt)
        with rasterio.open(path, "r+") as dataset:
            data = dataset.read(1) - 600
            data[:, 25:] = np.nan
            dataset.nodata = np.nan
            dataset.write(data, 1)
        with patch.object(self.cache, "stage", return_value=receipt), patch.object(self.cache, "verify", return_value=path):
            sample = contour_sample(self.policy, self.cache, [6.2, .2, 6.3, .3])
        self.assertEqual(sample["nativeRasterAudits"][0]["declaredNoData"], "nan")
        self.assertTrue(any(record["elevationM"] < 0 for record in sample["contours"]))

    def test_large_grid_rejected_before_tile_download(self):
        with patch.object(self.cache, "stage", side_effect=AssertionError("must not download")):
            with self.assertRaisesRegex(ValueError, "pixel bounds"):
                contour_sample(self.policy, self.cache, [6, 0, 7, 1])

    def test_contour_complexity_limit(self):
        with patch("map_platform.topography_pipeline.MAX_CONTOUR_POINTS", 1), self.assertRaisesRegex(ValueError, "complexity"):
            contour_sample(self.policy, self.cache, [6.2, 0.2, 6.25, 0.25])

    def test_partial_no_data_is_reported_without_zero_filling(self):
        receipt = self.cache.stage(self.policy.sources[0], (6, 0))
        path = self.cache.verify(receipt)
        with rasterio.open(path, "r+") as dataset:
            data = dataset.read(1)
            data[:, 25:] = -32767
            dataset.write(data, 1)
        with patch.object(self.cache, "stage", return_value=receipt), patch.object(self.cache, "verify", return_value=path):
            sample = contour_sample(self.policy, self.cache, [6.2, 0.2, 6.3, 0.3])
        self.assertGreater(sample["noDataMillionths"], 0)
        self.assertLess(sample["noDataMillionths"], 1_000_000)
        self.assertTrue(sample["contours"])

    def test_no_data_is_masked_and_invalid_crs_is_rejected(self):
        source = self.policy.sources[0]
        receipt = self.cache.stage(source, (6, 0))
        path = self.cache.verify(receipt)
        with rasterio.open(path, "r+") as dataset:
            dataset.write(np.full((100, 100), -32767, dtype="float32"), 1)
        with patch.object(self.cache, "stage", return_value=receipt), patch.object(self.cache, "verify", return_value=path):
            with self.assertRaisesRegex(ValueError, "no valid"):
                contour_sample(self.policy, self.cache, [6.2, 0.2, 6.25, 0.25])
            with rasterio.open(path, "r+") as dataset:
                dataset.crs = "EPSG:3857"
            with self.assertRaisesRegex(ValueError, "CRS"):
                contour_sample(self.policy, self.cache, [6.2, 0.2, 6.25, 0.25])


if __name__ == "__main__":
    unittest.main()
