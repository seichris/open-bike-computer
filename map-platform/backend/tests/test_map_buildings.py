import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from map_platform.jobs import JobStore, MapJobService
from map_platform.manifest import PipelineMetadata, build_manifest, stable_map_id
from map_platform.map_buildings import (
    building_target3_generation_allowlist,
    building_target3_generation_enabled,
    load_building_calibration_window,
)
from map_platform.models import Bounds, SourceRegion
from map_platform.pipeline import MapBuildPipeline, PipelinePaths
from map_platform.sources import SourceIndex
from tests.map_label_fixtures import one_building_fmb4, one_label_fma1


class CapturingRunner:
    def __init__(self):
        self.args = None

    def run(self, args, *, cwd=None):
        del cwd
        self.args = args
        return "\n".join(
            (
                'LABEL_STATS:{"blocks":1,"phaseTimings":{"labelFontWriting":0.5}}',
                'BUILDING_STATS:{"recordCount":1,"explicitHeightCount":1,'
                '"levelsHeightCount":0,"inheritedHeightCount":0,'
                '"localMedianHeightCount":0,"classDefaultHeightCount":0}',
            )
        )


class MapBuildingContractTests(unittest.TestCase):
    def setUp(self):
        self.source = SourceRegion(
            id="sg",
            provider="test",
            name="Singapore",
            url="https://example.invalid/sg.osm.pbf",
            bounds=Bounds(103.0, 1.0, 104.5, 1.8),
            checksum="3" * 64,
        )

    def _request(self):
        return {
            "mode": "custom_bbox",
            "bbox": [103.75, 1.24, 103.93, 1.37],
            "target": {
                "renderer": "esp32-fmb",
                "rendererFormatVersion": 3,
                "firmwareVersion": "1.2.3",
            },
            "labels": {
                "profileVersion": 1,
                "preferredLanguages": ["zh-Hant", "en"],
                "internationalFallback": "en-US",
            },
        }

    def _service(self, store):
        return MapJobService(
            SourceIndex([self.source]),
            store,
            label_target2_enabled=True,
            building_target3_enabled=True,
        )

    def test_target_three_generation_is_disabled_by_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(SourceIndex([self.source]), JobStore(tmp))
            with self.assertRaisesRegex(
                ValueError,
                "format 3 generation is not available for this installation",
            ):
                service.create_job(self._request())

    def test_target_three_environment_gate_is_strict(self):
        with patch.dict(
            "os.environ",
            {"MAP_PLATFORM_BUILDING_TARGET3_ENABLED": "yes"},
            clear=True,
        ):
            self.assertTrue(building_target3_generation_enabled())
        with patch.dict(
            "os.environ",
            {"MAP_PLATFORM_BUILDING_TARGET3_ENABLED": "sometimes"},
            clear=True,
        ):
            with self.assertRaisesRegex(ValueError, "must be a boolean"):
                building_target3_generation_enabled()

    def test_target_three_allowlist_is_strict(self):
        installation_id = "inst_v2_" + "a" * 32
        with patch.dict(
            "os.environ",
            {"MAP_PLATFORM_BUILDING_TARGET3_ALLOWLIST": installation_id},
            clear=True,
        ):
            self.assertEqual(
                building_target3_generation_allowlist(),
                frozenset({installation_id}),
            )
        with patch.dict(
            "os.environ",
            {"MAP_PLATFORM_BUILDING_TARGET3_ALLOWLIST": f"{installation_id},{installation_id}"},
            clear=True,
        ):
            with self.assertRaisesRegex(ValueError, "contains duplicates"):
                building_target3_generation_allowlist()
        with patch.dict(
            "os.environ",
            {"MAP_PLATFORM_BUILDING_TARGET3_ALLOWLIST": "installation-invalid"},
            clear=True,
        ):
            with self.assertRaisesRegex(ValueError, "invalid installation ID"):
                building_target3_generation_allowlist()

    def test_target_three_allowlist_blocks_other_installations(self):
        allowed_installation = "inst_v2_" + "a" * 32
        blocked_installation = "inst_v2_" + "b" * 32
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(
                SourceIndex([self.source]),
                JobStore(tmp),
                label_target2_enabled=True,
                building_target3_enabled=True,
                building_target3_allowlist=frozenset({allowed_installation}),
            )
            request = self._request()
            request.update(
                {
                    "clientInstallationId": blocked_installation,
                    "clientRequestId": "request-blocked",
                }
            )
            with self.assertRaisesRegex(
                ValueError,
                "format 3 generation is not available for this installation",
            ):
                service.create_job(request)

            request.update(
                {
                    "clientInstallationId": allowed_installation,
                    "clientRequestId": "request-allowed",
                }
            )
            job = service.create_job(request)
            self.assertEqual(
                job.request["target"]["rendererFormatVersion"],
                3,
            )

    def test_target_three_idempotent_replay_survives_gate_rollback(self):
        installation_id = "inst_v2_" + "c" * 32
        request = {
            **self._request(),
            "clientInstallationId": installation_id,
            "clientRequestId": "request-target3-idempotent",
        }
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp)
            enabled = MapJobService(
                SourceIndex([self.source]),
                store,
                label_target2_enabled=True,
                building_target3_enabled=True,
                building_target3_allowlist=frozenset({installation_id}),
            )
            created = enabled.create_job(request)

            rolled_back = MapJobService(
                SourceIndex([self.source]),
                store,
                label_target2_enabled=True,
                building_target3_enabled=False,
            )
            replayed = rolled_back.create_job(dict(request))
            self.assertEqual(replayed.job_id, created.job_id)

            changed = {**request, "bbox": [103.76, 1.25, 103.94, 1.38]}
            with self.assertRaisesRegex(ValueError, "different map request"):
                rolled_back.create_job(changed)

    def test_calibration_window_comes_from_checked_in_height_rules(self):
        repo_root = Path(__file__).resolve().parents[3]
        window = load_building_calibration_window(
            repo_root / "tools" / "OSM_Extract" / "conf" / "building_height_rules.yaml"
        )
        self.assertEqual(window.cell_size_meters, 8192)
        self.assertEqual(window.halo_cells, 1)

    def test_target_three_is_forwarded_and_requires_both_stats_records(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = self._service(JobStore(root / "jobs")).create_job(self._request())
            runner = CapturingRunner()
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"), runner=runner
            )
            metrics = pipeline._extract_features(job, root / "features", root / "raw")
            self.assertIn("3", runner.args)
            self.assertEqual(metrics["buildingBuild"]["recordCount"], 1)
            self.assertEqual(metrics["labelBuild"]["blocks"], 1)

    def test_target_three_preserves_polygon_selection_and_completes_building_relations(self):
        request = self._request()
        request.pop("bbox")
        request["mode"] = "custom_polygon"
        request["geometry"] = {
            "type": "Polygon",
            "coordinates": [[
                [103.75, 1.24],
                [103.90, 1.24],
                [103.90, 1.35],
                [103.75, 1.24],
            ]],
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = self._service(JobStore(root / "jobs")).create_job(request)
            runner = CapturingRunner()
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"), runner=runner
            )
            pipeline._extract_features(job, root / "features", root / "raw")
            self.assertIn("--selection-geometry", runner.args)
            selection_path = Path(
                runner.args[runner.args.index("--selection-geometry") + 1]
            )
            self.assertEqual(
                json.loads(selection_path.read_text()),
                request["geometry"],
            )

            pipeline._extract_pbf(
                job,
                root / "source.pbf",
                root / "clipped.pbf",
                bounds=job.geometry.bounds,
                force_bounds=True,
            )
            self.assertIn("--option=types=multipolygon,building", runner.args)
            self.assertIn("-b", runner.args)

    def test_manifest_derives_signed_building_summary_from_fmb4(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = self._service(JobStore(root / "jobs")).create_job(self._request())
            job.map_id = stable_map_id(job)
            block = root / "VECTMAP" / job.map_id / "+0000+0000" / "1.fmb"
            asset = root / "VECTMAP" / job.map_id / "assets" / "street-labels.fma"
            block.parent.mkdir(parents=True)
            asset.parent.mkdir(parents=True)
            block.write_bytes(one_building_fmb4())
            asset.write_bytes(one_label_fma1())
            stats = {
                "recordCount": 1,
                "explicitHeightCount": 1,
                "levelsHeightCount": 0,
                "inheritedHeightCount": 0,
                "localMedianHeightCount": 0,
                "classDefaultHeightCount": 0,
            }
            manifest = build_manifest(
                job, root, PipelineMetadata(), building_stats=stats
            )
            self.assertEqual(manifest["target"]["formatVersion"], 3)
            self.assertEqual(manifest["target"]["buildingProfileVersion"], 1)
            self.assertEqual(manifest["buildings"], stats)

            stats["explicitHeightCount"] = 0
            stats["classDefaultHeightCount"] = 1
            with self.assertRaisesRegex(ValueError, "do not match FMB v4"):
                build_manifest(job, root, PipelineMetadata(), building_stats=stats)


if __name__ == "__main__":
    unittest.main()
