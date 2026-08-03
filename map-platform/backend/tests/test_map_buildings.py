import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from map_platform.jobs import JobStore, MapJobService
from map_platform.manifest import PipelineMetadata, build_manifest, stable_map_id
from map_platform.map_buildings import building_target3_generation_enabled
from map_platform.models import Bounds, SourceRegion
from map_platform.pipeline import MapBuildPipeline, PipelinePaths
from map_platform.sources import SourceIndex
from tests.map_label_fixtures import empty_fma1, one_building_fmb4


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
            with self.assertRaisesRegex(ValueError, "format 3 generation is not enabled"):
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
            asset.write_bytes(empty_fma1())
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
