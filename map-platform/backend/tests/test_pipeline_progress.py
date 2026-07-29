import sys
import tempfile
import unittest
from pathlib import Path

from map_platform.jobs import JobStore, MapJobService
from map_platform.models import Bounds, SourceRegion
from map_platform.pipeline import CommandRunner, MapBuildPipeline, PipelinePaths, ProgressCoalescer, parse_map_progress
from map_platform.sources import SourceIndex


class FakeStreamingRunner:
    def run_streaming(self, args, *, cwd=None, on_output=None):
        for line in ["MAP_PROGRESS:1:100\n", "noise\n", "MAP_PROGRESS:100:100\n"]:
            on_output(line)
        return "complete"


class PipelineProgressTests(unittest.TestCase):
    def test_pipeline_uses_relocated_osm_extract_tool(self):
        repo_root = Path("/repo")
        paths = PipelinePaths(
            repo_root=repo_root,
            work_root=repo_root / "work",
            pack_root=repo_root / "packs",
        )

        self.assertEqual(paths.osm_extract_root, repo_root / "tools" / "OSM_Extract")

    def test_parse_map_progress(self):
        self.assertEqual(parse_map_progress("MAP_PROGRESS:24:100\n"), (24, 100))
        self.assertEqual(parse_map_progress("building\rMAP_PROGRESS:100:100\n"), (100, 100))
        self.assertIsNone(parse_map_progress("MAP_PROGRESS:101:100\n"))
        self.assertIsNone(parse_map_progress("unrelated output\n"))

    def test_streaming_runner_reports_output_before_completion(self):
        lines = []
        output = CommandRunner().run_streaming(
            [sys.executable, "-c", "print('MAP_PROGRESS:1:2', flush=True); print('MAP_PROGRESS:2:2', flush=True)"],
            on_output=lines.append,
        )

        self.assertEqual(
            [parse_map_progress(line) for line in lines],
            [(1, 2), (2, 2)],
        )
        self.assertIn("MAP_PROGRESS:2:2", output)

    def test_progress_coalescer_throttles_fast_updates_and_forces_final(self):
        now = [0.0]
        coalescer = ProgressCoalescer(clock=lambda: now[0])

        self.assertTrue(coalescer.should_emit(1, 1_000))
        self.assertFalse(coalescer.should_emit(2, 1_000))
        self.assertTrue(coalescer.should_emit(11, 1_000))
        now[0] = 2.0
        self.assertTrue(coalescer.should_emit(12, 1_000))
        self.assertTrue(coalescer.should_emit(1_000, 1_000))

    def test_streamed_extractor_progress_reaches_job_store(self):
        source = SourceRegion(
            id="sg",
            provider="test",
            name="Singapore",
            url="https://example.invalid/sg.osm.pbf",
            bounds=Bounds(103.0, 1.0, 104.5, 1.8),
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            service = MapJobService(SourceIndex([source]), store)
            created = service.create_job({"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]})
            job = store.claim(created.job_id, "worker-test")
            pipeline = MapBuildPipeline(
                PipelinePaths(repo_root=root, work_root=root / "work", pack_root=root / "packs"),
                runner=FakeStreamingRunner(),
            )

            pipeline._extract_features(
                job,
                root / "features",
                root / "raw-map",
                on_progress=lambda completed, total: store.update_progress_unless_cancelled(
                    job.job_id,
                    completed,
                    total,
                    worker_id="worker-test",
                ),
            )

            persisted = store.get(job.job_id)
            self.assertEqual(persisted.progress_completed, 100)
            self.assertEqual(persisted.progress_total, 100)


if __name__ == "__main__":
    unittest.main()
