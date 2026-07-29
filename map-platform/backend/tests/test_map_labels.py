import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from map_platform.jobs import JobStore, MapJobService
from map_platform.manifest import PipelineMetadata, build_manifest, stable_map_id
from map_platform.map_labels import label_target2_generation_enabled
from map_platform.models import Bounds, SourceRegion
from map_platform.pipeline import MapBuildPipeline, PipelinePaths
from map_platform.reuse import reuse_keys
from map_platform.sources import SourceIndex
from tests.map_label_fixtures import empty_fma1, empty_fmb3


PRODUCER_BUILD = "1" * 64
PRODUCER_IMAGE = "sha256:" + "2" * 64


class CapturingRunner:
    def __init__(self):
        self.args = None

    def run(self, args, *, cwd=None):
        del cwd
        self.args = args
        return (
            'LABEL_STATS:{"blocks":1,"phaseTimings":'
            '{"labelCandidateGeneration":0.25,"labelFontWriting":0.5}}'
        )


class MapLabelContractTests(unittest.TestCase):
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
                "rendererFormatVersion": 2,
                "firmwareVersion": "1.2.3",
            },
            "labels": {
                "profileVersion": 1,
                "preferredLanguages": ["zh_hant", "EN", "en"],
                "internationalFallback": "en_us",
            },
        }

    def _service(self, store: JobStore) -> MapJobService:
        return MapJobService(
            SourceIndex([self.source]),
            store,
            label_target2_enabled=True,
        )

    def test_target_two_generation_is_disabled_by_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(SourceIndex([self.source]), JobStore(tmp))
            with self.assertRaisesRegex(ValueError, "format 2 generation is not enabled"):
                service.create_job(self._request())

    def test_target_two_environment_gate_is_strict(self):
        with patch.dict(
            "os.environ",
            {"MAP_PLATFORM_LABEL_TARGET2_ENABLED": "yes"},
            clear=True,
        ):
            self.assertTrue(label_target2_generation_enabled())
        with patch.dict(
            "os.environ",
            {"MAP_PLATFORM_LABEL_TARGET2_ENABLED": "sometimes"},
            clear=True,
        ):
            with self.assertRaisesRegex(ValueError, "must be a boolean"):
                label_target2_generation_enabled()

    def test_target_two_request_is_normalized_and_forwarded(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            service = self._service(JobStore(root / "jobs"))
            job = service.create_job(self._request())
            self.assertEqual(job.request["labels"]["preferredLanguages"], ["zh-Hant", "en"])
            self.assertEqual(job.request["labels"]["internationalFallback"], "en-US")

            runner = CapturingRunner()
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"), runner=runner
            )
            metrics = pipeline._extract_features(job, root / "features", root / "raw")
            self.assertEqual(
                runner.args[-8:],
                [
                    "--renderer-format",
                    "2",
                    "--preferred-language",
                    "zh-Hant",
                    "--preferred-language",
                    "en",
                    "--international-fallback",
                    "en-US",
                ],
            )
            self.assertEqual(metrics["labelBuild"]["blocks"], 1)
            self.assertEqual(
                metrics["labelPhaseTimings"]["labelFontWriting"], 0.5
            )

    def test_labels_and_target_two_are_mutually_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = self._service(JobStore(tmp))
            missing_labels = self._request()
            missing_labels.pop("labels")
            with self.assertRaisesRegex(ValueError, "requires labels"):
                service.create_job(missing_labels)
            legacy_with_labels = self._request()
            legacy_with_labels["target"]["rendererFormatVersion"] = 1
            with self.assertRaisesRegex(ValueError, "require renderer format 2"):
                service.create_job(legacy_with_labels)
            implicit_renderer = self._request()
            implicit_renderer["target"].pop("renderer")
            with self.assertRaisesRegex(ValueError, "explicit esp32-fmb"):
                service.create_job(implicit_renderer)

    def test_manifest_requires_and_records_the_exact_font_asset(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            service = self._service(JobStore(root / "jobs"))
            job = service.create_job(self._request())
            map_id = stable_map_id(job)
            job.map_id = map_id
            block = root / "VECTMAP" / map_id / "+0000+0000" / "1.fmb"
            block.parent.mkdir(parents=True)
            block.write_bytes(empty_fmb3())
            with self.assertRaisesRegex(ValueError, "missing street-labels"):
                build_manifest(job, root, PipelineMetadata())
            asset = root / "VECTMAP" / map_id / "assets" / "street-labels.fma"
            asset.parent.mkdir(parents=True)
            asset.write_bytes(empty_fma1())
            manifest = build_manifest(job, root, PipelineMetadata())
            self.assertEqual(manifest["target"]["formatVersion"], 2)
            self.assertEqual(manifest["target"]["labelProfileVersion"], 1)
            self.assertEqual(manifest["target"]["labelLanguages"], ["zh-Hant", "en"])
            self.assertIn(str(asset.relative_to(root)), [entry["path"] for entry in manifest["files"]])

            corrupted = bytearray(asset.read_bytes())
            corrupted[-1] = 0
            asset.write_bytes(corrupted)
            with self.assertRaisesRegex(ValueError, "face metadata"):
                build_manifest(job, root, PipelineMetadata())

    def test_label_profile_changes_reuse_identity_but_not_map_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = self._service(JobStore(tmp))
            first = service.create_job(self._request())
            changed_request = self._request()
            changed_request["labels"]["preferredLanguages"] = ["ja", "en"]
            second = service.create_job(changed_request)
            self.assertEqual(stable_map_id(first), stable_map_id(second))
            first_keys = reuse_keys(
                first,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            second_keys = reuse_keys(
                second,
                producer_build_sha256=PRODUCER_BUILD,
                producer_image_digest=PRODUCER_IMAGE,
            )
            self.assertNotEqual(first_keys.compatibility, second_keys.compatibility)


if __name__ == "__main__":
    unittest.main()
