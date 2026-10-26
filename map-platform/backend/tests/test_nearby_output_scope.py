"""Target-5 output blocks are exactly the signed Nearby coverage."""

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from map_platform.building_scope import (
    BuildingScopeError,
    nearby_output_blocks,
    plan_building_scope,
    plan_global_building_scope,
    x_to_lon,
    y_to_lat,
)
from map_platform.geometry import normalize_geometry
from map_platform.jobs import JobStore, MapJobService, NearbyCoverageLimitError
from map_platform.models import Bounds, JobStatus, MapJob, SourceRegion
from map_platform.pipeline import MapBuildPipeline, PipelinePaths
from map_platform.reuse import (
    MAP_BLOCK_SIZE_METERS,
    MapBlock,
    aligned_processing_bounds,
    aligned_projected_extent,
)
from map_platform.sources import SourceIndex
from map_platform.topography_artifacts import Contour, ContourSection
from map_platform.topography_geometry import CompiledTopography
from map_platform.topography_pack import assemble_topographic_pack
from map_platform.topography_pipeline import canonical_bytes
from tests.map_label_fixtures import fmb6_with_pois, one_label_fma1


BLOCK = MAP_BLOCK_SIZE_METERS
SOURCE = SourceRegion(
    id="fixture",
    provider="test",
    name="Fixture",
    url="https://example.invalid/fixture.osm.pbf",
    bounds=Bounds(-10.0, -5.0, 40.0, 65.0),
    checksum="3" * 64,
)
# Corridor endpoints whose physical buffer reaches one block past the request
# bounds, which expand by the centre latitude's metre scale.
HIGH_LATITUDE_ROUTE = [[2.735716262946571, 50.89758310994018],
                       [2.7296008526976983, 51.99507737402439]]


def point(x_meters, y_meters):
    return [x_to_lon(x_meters), y_to_lat(y_meters)]


def block_bbox(min_x, min_y, max_x, max_y):
    """Bounds strictly inside the [min, max) block range."""
    return [*point(min_x * BLOCK + 1, min_y * BLOCK + 1),
            *point(max_x * BLOCK - 1, max_y * BLOCK - 1)]


def triangle_geometry():
    return {"type": "Polygon", "coordinates": [[
        point(100, 100), point(12_000, 100), point(100, 12_000), point(100, 100),
    ]]}


def target5_request(**geometry):
    return {
        **geometry,
        "target": {
            "renderer": "esp32-fmb",
            "rendererFormatVersion": 5,
            "firmwareVersion": "1.2.3",
            "requestedFeatures": ["3d-buildings", "map-pois", "street-labels"],
        },
        "labels": {"profileVersion": 1, "preferredLanguages": ["en"],
                   "internationalFallback": "en"},
    }


def grid_blocks(bounds):
    min_x, min_y, max_x, max_y = aligned_projected_extent(bounds)
    return {
        MapBlock(x, y)
        for x in range(min_x // BLOCK, max_x // BLOCK)
        for y in range(min_y // BLOCK, max_y // BLOCK)
    }


def persisted_job(request):
    request = json.loads(json.dumps(request))
    return MapJob(
        job_id="nearby-scope",
        status=JobStatus.QUEUED,
        request=request,
        geometry=normalize_geometry(request),
        source_region=SOURCE,
    )


class RecordingRunner:
    def __init__(self, output=""):
        self.calls = []
        self.output = output

    def run(self, args, *, cwd=None):
        self.calls.append((args, cwd))
        return self.output


TARGET5_EXTRACTION_OUTPUT = "\n".join((
    'LABEL_STATS:{"blocks":1,"phaseTimings":{}}',
    'BUILDING_STATS:{"recordCount":0,"explicitHeightCount":0,'
    '"levelsHeightCount":0,"inheritedHeightCount":0,'
    '"localMedianHeightCount":0,"classDefaultHeightCount":0}',
    'POI_STATS:{"recordCount":1,"phaseTimings":{}}',
))


class NearbyAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.store = JobStore(Path(self.temporary.name) / "jobs")
        self.service = MapJobService(
            SourceIndex([SOURCE]),
            self.store,
            poi_target5_enabled=True,
        )

    def test_exact_limit_is_admitted_and_one_more_column_is_never_persisted(self):
        exact = self.service.create_job(
            target5_request(mode="custom_bbox", bbox=block_bbox(0, 0, 32, 32))
        )
        self.assertEqual(len(nearby_output_blocks(exact)), 1024)

        with self.assertRaises(NearbyCoverageLimitError) as raised:
            self.service.create_job(
                target5_request(mode="custom_bbox", bbox=block_bbox(0, 0, 33, 32))
            )
        self.assertEqual(raised.exception.code, "nearby_coverage_exceeded")
        self.assertIsInstance(raised.exception, ValueError)
        self.assertIn("1024", str(raised.exception))
        self.assertEqual([job.job_id for job in self.store.list()], [exact.job_id])

        # The bound is specific to signed target-5 coverage.
        legacy = self.service.create_job(
            {"mode": "custom_bbox", "bbox": block_bbox(0, 0, 33, 32)}
        )
        self.assertEqual(
            {job.job_id for job in self.store.list()}, {exact.job_id, legacy.job_id}
        )

    def test_admission_counts_selected_blocks_not_the_request_rectangle(self):
        band = {"type": "Polygon", "coordinates": [[
            point(10, 10),
            point(40 * BLOCK - 10, 40 * BLOCK - 110),
            point(40 * BLOCK - 10, 40 * BLOCK - 10),
            point(10, 110),
            point(10, 10),
        ]]}
        job = self.service.create_job(target5_request(mode="custom_polygon", geometry=band))
        self.assertLess(len(nearby_output_blocks(job)), 1024)
        self.assertGreater(len(grid_blocks(job.geometry.bounds)), 1024)


class NearbyBuildGuardTests(unittest.TestCase):
    def test_every_scope_mode_rejects_oversized_persisted_jobs_before_extraction(self):
        request = target5_request(mode="custom_bbox", bbox=block_bbox(0, 0, 33, 32))
        for mode in ("legacy", "shadow", "selected", "chunked"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                runner = RecordingRunner()
                pipeline = MapBuildPipeline(
                    PipelinePaths(root, root / "work", root / "packs"),
                    runner=runner,
                    building_scope_mode=mode,
                )
                with self.assertRaises(BuildingScopeError) as raised:
                    pipeline.build(persisted_job(request))
                self.assertEqual(raised.exception.code, "building_scope_exceeded")
                self.assertEqual(runner.calls, [])
                self.assertFalse((root / "work").exists() and any((root / "work").iterdir()))


class NearbyOutputBlockTests(unittest.TestCase):
    def test_bbox_coverage_is_the_aligned_request_grid(self):
        job = persisted_job(target5_request(mode="custom_bbox", bbox=block_bbox(3, 4, 6, 9)))
        coverage = nearby_output_blocks(job)
        self.assertEqual(set(coverage), grid_blocks(job.geometry.bounds))
        self.assertEqual(len(coverage), 15)
        self.assertEqual(
            aligned_processing_bounds(job, complete_blocks=True, output_blocks=coverage),
            aligned_processing_bounds(job, complete_blocks=True),
        )

    def test_triangle_coverage_excludes_off_selection_grid_blocks(self):
        job = persisted_job(target5_request(mode="custom_polygon", geometry=triangle_geometry()))
        coverage = {(block.x, block.y) for block in nearby_output_blocks(job)}
        self.assertEqual(coverage, {(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (2, 0)})
        grid = {(block.x, block.y) for block in grid_blocks(job.geometry.bounds)}
        self.assertEqual(grid - coverage, {(1, 2), (2, 1), (2, 2)})

    def test_corridor_processing_grid_contains_coverage_beyond_request_bounds(self):
        job = persisted_job(target5_request(
            mode="route_corridor",
            route={"type": "LineString", "coordinates": HIGH_LATITUDE_ROUTE},
            corridorWidthM=3000,
        ))
        coverage = set(nearby_output_blocks(job))
        self.assertTrue(coverage - grid_blocks(job.geometry.bounds))
        processing = aligned_processing_bounds(
            job, complete_blocks=True, output_blocks=tuple(sorted(coverage))
        )
        self.assertLessEqual(coverage, grid_blocks(processing))
        self.assertLessEqual(grid_blocks(job.geometry.bounds), grid_blocks(processing))

    def test_selected_and_chunked_plans_emit_exactly_the_coverage(self):
        small_corridor = target5_request(
            mode="route_corridor",
            route={"type": "LineString", "coordinates": [point(100, 100), point(30_000, 9_000)]},
            corridorWidthM=500,
        )
        for request in (
            target5_request(mode="custom_polygon", geometry=triangle_geometry()),
            small_corridor,
            target5_request(mode="custom_bbox", bbox=block_bbox(0, 0, 4, 3)),
        ):
            job = persisted_job(request)
            with self.subTest(mode=request["mode"]):
                coverage = nearby_output_blocks(job)
                selected = plan_building_scope(
                    job,
                    calibration_cell_size_meters=512,
                    calibration_halo_cells=1,
                    calibration_minimum_samples=16,
                )
                self.assertEqual(tuple(sorted(selected.output_blocks)), coverage)
                chunked = plan_global_building_scope(
                    job,
                    calibration_cell_size_meters=512,
                    calibration_halo_cells=1,
                    calibration_minimum_samples=16,
                )
                self.assertEqual(tuple(sorted(chunked.output_blocks)), coverage)

    def test_only_target5_extraction_receives_the_coverage_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = RecordingRunner(TARGET5_EXTRACTION_OUTPUT)
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"), runner=runner
            )
            job = persisted_job(
                target5_request(mode="custom_polygon", geometry=triangle_geometry())
            )
            metrics = pipeline._extract_features(job, root / "features", root / "raw")
            self.assertEqual(metrics["poiBuild"]["recordCount"], 1)
            args = runner.calls[-1][0]
            path = Path(args[args.index("--output-blocks") + 1])
            self.assertEqual(json.loads(path.read_text()), {
                "blockSizeMeters": 4096,
                "blocks": [[0, 0], [0, 1], [0, 2], [1, 0], [1, 1], [2, 0]],
                "schemaVersion": 1,
            })
            self.assertIn("--selection-geometry", args)

            runner.output = "\n".join(TARGET5_EXTRACTION_OUTPUT.splitlines()[:2])
            target3 = persisted_job({
                **target5_request(mode="custom_polygon", geometry=triangle_geometry()),
                "target": {"renderer": "esp32-fmb", "rendererFormatVersion": 3,
                           "firmwareVersion": "1.2.3"},
            })
            pipeline._extract_features(target3, root / "features3", root / "raw3")
            self.assertNotIn("--output-blocks", runner.calls[-1][0])


class NearbyContourCompositionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sample = {
            "kind": "bicino-contour-evidence-v1", "workingCrs": "EPSG:3857",
            "verticalDatum": "EPSG:3855", "minorIntervalM": 20, "indexIntervalM": 100,
            "boundsE7": [-1000000, -1000000, 1000000, 1000000], "noDataMillionths": 0,
            "qualityMode": "standard-20m-v1", "surfaceModel": "dsm",
            "horizontalCrs": "EPSG:4326", "sourcePixels": {"fixture": 1},
            "gridSize": [2, 2], "sources": [], "inputs": [], "sourcePolicySha256": "a" * 64,
            "contours": [],
        }
        # One index contour crossing blocks (-1, 0), (0, 0) and (1, 0), in the
        # block-local metres compile_contours emits; it needs no raster stack.
        crossing = Contour(100, 3, tuple((x, 2000) for x in range(0, 4097, 512)))
        self.compiled = CompiledTopography(
            sections={
                key: ContourSection(20, 100, (crossing,))
                for key in ((-1, 0), (0, 0), (1, 0))
            },
            intermediate_sha256="d" * 64,
            sample_sha256=hashlib.sha256(canonical_bytes(self.sample)).hexdigest(),
            selection_sha256="e" * 64,
        )
        self.source = self.root / "source"
        block = self.source / "VECTMAP/test-map/+000+000/0_0.fmb"
        block.parent.mkdir(parents=True)
        block.write_bytes(fmb6_with_pois())
        font = self.source / "VECTMAP/test-map/assets/street-labels.fma"
        font.parent.mkdir()
        font.write_bytes(one_label_fma1())

    def assemble(self, name, **kwargs):
        return assemble_topographic_pack(
            self.source, self.root / name, "test-map", self.compiled, self.sample,
            b"Test fixture notices only\n", **kwargs,
        )

    def device_blocks(self, name):
        return {
            path.relative_to(self.root / name / "device").as_posix()
            for path in (self.root / name / "device").rglob("*.fmb")
        }

    def test_contour_only_blocks_outside_coverage_are_not_device_blocks(self):
        self.assemble("unbounded", renderer_format_version=5)
        self.assertEqual(len(self.device_blocks("unbounded")), 3)
        self.assemble("bounded", renderer_format_version=5, output_blocks={(0, 0), (1, 0)})
        self.assertEqual(self.device_blocks("bounded"), {
            "VECTMAP/test-map/+000+000/0_0.fmb",
            "VECTMAP/test-map/+000+000/1_0.fmb",
        })

    def test_vector_blocks_outside_coverage_and_noncombined_targets_fail(self):
        with self.assertRaisesRegex(ValueError, "outside the target-5 output blocks"):
            self.assemble("vector", renderer_format_version=5, output_blocks={(1, 0)})
        with self.assertRaisesRegex(ValueError, "combined POI target"):
            self.assemble("target4", renderer_format_version=4, output_blocks={(0, 0)})
        with self.assertRaisesRegex(ValueError, "combined POI target"):
            self.assemble("empty", renderer_format_version=5, output_blocks=set())


if __name__ == "__main__":
    unittest.main()
