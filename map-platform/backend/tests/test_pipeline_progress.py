import hashlib
import json
import sys
import subprocess
import tempfile
import threading
import time
import unittest
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from map_platform.jobs import JobStore, MapJobService
from map_platform.building_scope import BuildingScopeError
from map_platform.models import Bounds, SourceRegion
from map_platform.pipeline import (
    CommandRunner,
    MapBuildPipeline,
    PipelinePaths,
    ProgressCoalescer,
    parse_label_stats,
    parse_building_preprocess_progress,
    parse_building_block_cache,
    parse_building_complexity,
    parse_building_scope,
    parse_map_progress,
)
from map_platform.sources import SourceIndex


class FakeStreamingRunner:
    def run_streaming(self, args, *, cwd=None, on_output=None):
        for line in ["MAP_PROGRESS:1:100\n", "noise\n", "MAP_PROGRESS:100:100\n"]:
            on_output(line)
        return "complete"


class BuildingStreamingRunner:
    def run_streaming(self, args, *, cwd=None, on_output=None):
        del args, cwd
        on_output(
            'BUILDING_PREPROCESS_PROGRESS:{"unit":"calibration_cells",'
            '"completed":2,"total":5,"indeterminate":false}\n'
        )
        return "complete"


class FailingBuildingStreamingRunner:
    def __init__(self, output):
        self.output = output

    def run_streaming(self, args, *, cwd=None, on_output=None):
        del cwd, on_output
        raise subprocess.CalledProcessError(2, args, output=self.output)


class DuplicateBuildingScopeRunner:
    def run(self, args, *, cwd=None):
        del args, cwd
        return "\n".join(
            (
                'BUILDING_SCOPE:{"scopePlanSha256":"a","outputBlockCount":1}',
                'BUILDING_SCOPE:{"scopePlanSha256":"a","outputBlockCount":1}',
                'LABEL_STATS:{"blocks":1,"phaseTimings":{}}',
                'BUILDING_STATS:{"recordCount":0}',
            )
        )


class BuildingPhaseStreamingRunner:
    def __init__(self):
        self.args = None

    def run_streaming(self, args, *, cwd=None, on_output=None):
        del cwd
        self.args = args
        for line in (
            'BUILDING_PREPROCESS_PROGRESS:{"completed":0,"indeterminate":true,'
            '"unit":"building_normalization"}',
            'BUILDING_BLOCK_CACHE:{"schemaVersion":1,'
            '"cacheIdentitySha256":"' + "a" * 64 + '",'
            '"requestedBlockCount":1,"initialHitCount":1,'
            '"initialMissCount":0,"workerCount":1}',
            'BUILDING_PREPROCESS_PROGRESS:{"completed":1,"indeterminate":false,'
            '"total":1,"unit":"building_normalization"}',
            'BUILDING_COMPLEXITY:{"schemaVersion":1,"sourceCount":0,'
            '"outlineCount":0,"partCount":0,"explicitParentCount":0,'
            '"unresolvedPartCount":0,"containmentCandidateProduct":0,'
            '"polygonCount":0,"ringCount":0,"holeCount":0,'
            '"sourceVertexCount":0,"maximumVerticesPerObject":0,'
            '"preparationRejectedCount":0}',
            "MAP_PROGRESS:0:1",
            "MAP_PROGRESS:1:1",
            'LABEL_STATS:{"blocks":1,"phaseTimings":{}}',
            'BUILDING_STATS:{"recordCount":0,"phaseTimings":'
            '{"buildingNormalization":0.25,"blockEncoding":0.5}}',
        ):
            on_output(line + "\n")
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

    def test_parse_label_stats(self):
        self.assertEqual(
            parse_label_stats(
                'progress LABEL_STATS:{"blocks":2,"phaseTimings":{"labelFmbWriting":0.75}}\n'
            ),
            {"blocks": 2, "phaseTimings": {"labelFmbWriting": 0.75}},
        )
        self.assertIsNone(parse_label_stats("LABEL_STATS:not-json\n"))

    def test_parse_building_scope_and_preprocessing_progress(self):
        self.assertEqual(
            parse_building_scope(
                'BUILDING_SCOPE:{"outputBlockCount":12,"scopePlanSha256":"abc"}\n'
            ),
            {"outputBlockCount": 12, "scopePlanSha256": "abc"},
        )
        self.assertEqual(
            parse_building_preprocess_progress(
                'BUILDING_PREPROCESS_PROGRESS:{"unit":"calibration_cells",'
                '"completed":2,"total":5,"indeterminate":false}\n'
            ),
            {
                "unit": "calibration_cells",
                "completed": 2,
                "total": 5,
                "indeterminate": False,
            },
        )
        complexity = (
            'BUILDING_COMPLEXITY:{"schemaVersion":1,"sourceCount":10,'
            '"outlineCount":8,"partCount":2,"explicitParentCount":1,'
            '"unresolvedPartCount":1,"containmentCandidateProduct":8,'
            '"polygonCount":10,"ringCount":11,"holeCount":1,'
            '"sourceVertexCount":100,"maximumVerticesPerObject":20,'
            '"preparationRejectedCount":0}'
        )
        self.assertEqual(
            parse_building_complexity(complexity)["containmentCandidateProduct"],
            8,
        )
        self.assertIsNone(
            parse_building_complexity(
                complexity.replace('"containmentCandidateProduct":8',
                                   '"containmentCandidateProduct":true')
            )
        )
        cache_marker = (
            'BUILDING_BLOCK_CACHE:{"schemaVersion":1,'
            '"cacheIdentitySha256":"' + "a" * 64 + '",'
            '"requestedBlockCount":16,"initialHitCount":12,'
            '"initialMissCount":4,"workerCount":4}'
        )
        self.assertEqual(
            parse_building_block_cache(cache_marker)["initialHitCount"],
            12,
        )
        self.assertIsNone(
            parse_building_block_cache(
                cache_marker.replace('"initialMissCount":4', '"initialMissCount":3')
            )
        )
        self.assertEqual(
            parse_building_preprocess_progress(
                'BUILDING_PREPROCESS_PROGRESS:{"unit":"source_index",'
                '"completed":5000,"indeterminate":true}\n'
            ),
            {
                "unit": "source_index",
                "completed": None,
                "total": None,
                "indeterminate": True,
            },
        )
        self.assertIsNone(
            parse_building_preprocess_progress(
                'BUILDING_PREPROCESS_PROGRESS:{"unit":"source_index",'
                '"completed":1,"indeterminate":false}\n'
            )
        )

    def test_streaming_runner_reports_output_before_completion(self):
        lines = []
        runner = CommandRunner()
        output = runner.run_streaming(
            [sys.executable, "-c", "print('MAP_PROGRESS:1:2', flush=True); print('MAP_PROGRESS:2:2', flush=True)"],
            on_output=lines.append,
        )

        self.assertEqual(
            [parse_map_progress(line) for line in lines],
            [(1, 2), (2, 2)],
        )
        self.assertIn("MAP_PROGRESS:2:2", output)
        self.assertIn("wallSeconds", runner.last_execution_metrics)
        self.assertGreaterEqual(runner.last_execution_metrics["wallSeconds"], 0)

    def test_streaming_runner_cancels_silent_preprocessing_promptly(self):
        with tempfile.TemporaryDirectory() as tmp:
            result_path = Path(tmp) / "published.json"
            cancelled = threading.Event()

            def cancel_later():
                time.sleep(0.2)
                cancelled.set()

            canceller = threading.Thread(target=cancel_later)
            canceller.start()
            started = time.monotonic()
            with self.assertRaisesRegex(RuntimeError, "command was cancelled"):
                CommandRunner().run_streaming(
                    [
                        sys.executable,
                        "-c",
                        (
                            "import pathlib,time; "
                            "print('BUILDING_PREPROCESS_PROGRESS:{\"completed\":0,'"
                            "'\"indeterminate\":true,\"unit\":\"source_index\"}',"
                            "flush=True); time.sleep(10); "
                            f"pathlib.Path({str(result_path)!r}).write_text('published')"
                        ),
                    ],
                    cancellation_check=cancelled.is_set,
                )
            elapsed = time.monotonic() - started
            canceller.join(timeout=1)

            self.assertLess(elapsed, 2.0)
            self.assertFalse(result_path.exists())

    def test_streaming_runner_keeps_polling_cancellation_after_stdout_eof(self):
        cancelled = threading.Event()

        def cancel_later():
            time.sleep(0.2)
            cancelled.set()

        canceller = threading.Thread(target=cancel_later)
        canceller.start()
        started = time.monotonic()
        with self.assertRaisesRegex(RuntimeError, "command was cancelled"):
            CommandRunner().run_streaming(
                [
                    sys.executable,
                    "-c",
                    "import os,time; os.close(1); os.close(2); time.sleep(10)",
                ],
                cancellation_check=cancelled.is_set,
            )
        elapsed = time.monotonic() - started
        canceller.join(timeout=1)

        self.assertLess(elapsed, 2.0)

    def test_cancelled_source_index_command_cleans_persistent_scan_debris(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo_root = Path(__file__).resolve().parents[3]
            pipeline = MapBuildPipeline(
                PipelinePaths(repo_root, root / "work", root / "packs")
            )
            source_sha256 = "1" * 64
            identity = {
                "schemaVersion": 1,
                "algorithmVersion": 2,
                "creationTool": "open-bike-building-source-index",
                "sourceSnapshotSha256": source_sha256,
            }
            index_key = hashlib.sha256(
                json.dumps(
                    identity, sort_keys=True, separators=(",", ":")
                ).encode()
            ).hexdigest()
            index_root = (
                pipeline.paths.building_cache_root
                / "building-source-index-v1"
                / source_sha256
                / index_key
            )
            index_root.mkdir(parents=True)
            partial = index_root / ".scan.cancelled.sqlite"
            cancelled = threading.Event()

            def cancel_later():
                time.sleep(0.2)
                cancelled.set()

            canceller = threading.Thread(target=cancel_later)
            canceller.start()
            with self.assertRaisesRegex(RuntimeError, "command was cancelled"):
                pipeline._run_preprocessing_command(
                    [
                        sys.executable,
                        "-c",
                        (
                            "import pathlib,time; "
                            f"pathlib.Path({str(partial)!r}).write_bytes(b'x'); "
                            "time.sleep(10)"
                        ),
                        "--cache-root",
                        str(pipeline.paths.building_cache_root),
                        "--source-sha256",
                        source_sha256,
                    ],
                    cwd=repo_root / "tools" / "OSM_Extract" / "scripts",
                    on_phase_progress=None,
                    default_unit="source_index",
                    total_blocks=1,
                    cancellation_check=cancelled.is_set,
                )
            canceller.join(timeout=1)

            self.assertEqual(list(index_root.glob(".scan.*")), [])

    def test_progress_coalescer_throttles_fast_updates_and_forces_final(self):
        now = [0.0]
        coalescer = ProgressCoalescer(clock=lambda: now[0])

        self.assertTrue(coalescer.should_emit(1, 1_000))
        self.assertFalse(coalescer.should_emit(2, 1_000))
        self.assertTrue(coalescer.should_emit(11, 1_000))
        now[0] = 2.0
        self.assertTrue(coalescer.should_emit(12, 1_000))
        self.assertTrue(coalescer.should_emit(1_000, 1_000))

    def test_selected_preprocessing_streams_nested_units_before_block_encoding(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=BuildingStreamingRunner(),
            )
            progress = []

            pipeline._run_preprocessing_command(
                ["preprocess"],
                cwd=root,
                on_phase_progress=progress.append,
                default_unit="calibration_cells",
                total_blocks=12,
            )

            self.assertEqual(progress[1]["phase"], "building_preprocessing")
            self.assertEqual(progress[1]["unit"], "calibration_cells")
            self.assertEqual(progress[1]["completed"], 2)
            self.assertEqual(progress[1]["total"], 5)
            self.assertEqual(progress[1]["completedBlocks"], 0)
            self.assertEqual(progress[1]["totalBlocks"], 12)
            self.assertFalse(progress[1]["indeterminate"])
            self.assertEqual(
                [
                    (item["unit"], item["completed"], item["total"])
                    for item in progress
                ],
                [
                    ("calibration_cells", 0, 1),
                    ("calibration_cells", 2, 5),
                    ("calibration_cells", 1, 1),
                ],
            )

    def test_extractor_reports_normalization_before_real_block_encoding(self):
        source = SourceRegion(
            id="sg",
            provider="test",
            name="Singapore",
            url="https://example.invalid/sg.osm.pbf",
            bounds=Bounds(103.0, 1.0, 104.5, 1.8),
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = MapJobService(
                SourceIndex([source]),
                JobStore(root / "jobs"),
                label_target2_enabled=True,
                building_target3_enabled=True,
            ).create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                    "target": {
                        "renderer": "esp32-fmb",
                        "rendererFormatVersion": 3,
                    },
                    "labels": {
                        "profileVersion": 1,
                        "preferredLanguages": ["en"],
                        "internationalFallback": "en",
                    },
                }
            )
            runner = BuildingPhaseStreamingRunner()
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=runner,
            )
            phase_progress = []
            block_progress = []
            marker = {"scopePlanSha256": "a" * 64, "outputBlockCount": 1}

            metrics = pipeline._extract_features(
                job,
                root / "features",
                root / "map",
                scope_plan_path=root / "scope-plan.json",
                planned_scope_marker=marker,
                on_phase_progress=phase_progress.append,
                on_progress=lambda completed, total: block_progress.append(
                    (completed, total)
                ),
            )

            self.assertIn("--suppress-scope-marker", runner.args)
            self.assertEqual(
                [item["phase"] for item in phase_progress],
                [
                    "building_preprocessing",
                    "building_preprocessing",
                    "building_preprocessing",
                    "building_preprocessing",
                    "block_encoding",
                    "block_encoding",
                ],
            )
            self.assertEqual(
                phase_progress[3]["estimatorEvidence"]["complexity"][
                    "schemaVersion"
                ],
                1,
            )
            self.assertEqual(
                phase_progress[1]["estimatorEvidence"]["buildingBlockCache"][
                    "initialHitCount"
                ],
                1,
            )
            self.assertEqual(block_progress, [(0, 1), (1, 1)])
            self.assertEqual(
                metrics["buildingScriptPhaseTimings"],
                {"buildingNormalization": 0.25, "blockEncoding": 0.5},
            )
            self.assertEqual(metrics["buildingScope"], marker)

    def test_preprocessing_command_translates_typed_and_default_failures(self):
        typed_output = (
            'BUILDING_PREPROCESS_FAILURE:{"code":"building_source_snapshot_changed",'
            '"message":"source changed"}\n'
        )
        cases = (
            (typed_output, "source_index", "building_source_snapshot_changed"),
            (
                'BUILDING_PREPROCESS_FAILURE:{"code":'
                '"building_object_limit_exceeded","message":"too many"}\n',
                "relation_closure",
                "building_object_limit_exceeded",
            ),
            ("tool failed\n", "source_index", "building_relation_incomplete"),
            ("tool failed\n", "calibration_cells", "building_calibration_unavailable"),
        )
        for output, unit, expected_code in cases:
            with self.subTest(unit=unit, expected_code=expected_code), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                pipeline = MapBuildPipeline(
                    PipelinePaths(root, root / "work", root / "packs"),
                    runner=FailingBuildingStreamingRunner(output),
                )
                with self.assertRaises(BuildingScopeError) as context:
                    pipeline._run_preprocessing_command(
                        ["preprocess"],
                        cwd=root,
                        on_phase_progress=lambda _progress: None,
                        default_unit=unit,
                        total_blocks=12,
                    )
                self.assertEqual(context.exception.code, expected_code)

    def test_unpinned_legacy_target_does_not_emit_building_cache_progress(self):
        source = SourceRegion(
            id="sg",
            provider="test",
            name="Singapore",
            url="https://example.invalid/sg.osm.pbf",
            bounds=Bounds(103.0, 1.0, 104.5, 1.8),
            local_path="map-platform/backend/data/source-pbf/sg.osm.pbf",
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root / "jobs")
            job = MapJobService(SourceIndex([source]), store).create_job(
                {"mode": "custom_bbox", "bbox": [103.75, 1.24, 103.93, 1.37]}
            )
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
            )
            cached = SimpleNamespace(path=root / "source.pbf", sha256="a" * 64)
            progress = []
            with patch.object(
                pipeline.source_cache,
                "verified_lease",
                return_value=nullcontext(cached),
            ), patch.object(
                pipeline, "_reuse_keys_for_cached_source", return_value=None
            ):
                with pipeline.exact_reuse_identity_lease(
                    job,
                    on_phase_progress=progress.append,
                ):
                    pass
            self.assertEqual(progress, [])

    def test_nonfinite_or_boolean_phase_timings_are_rejected_at_ingestion(self):
        for value in (True, float("nan"), float("inf"), float("-inf"), -1.0):
            with self.subTest(value=value), self.assertRaisesRegex(
                RuntimeError, "invalid phase timings"
            ):
                MapBuildPipeline._build_metrics(
                    2,
                    {"blocks": 1, "phaseTimings": {"phase": value}},
                    None,
                )

    def test_missing_building_complexity_marker_is_advisory(self):
        metrics = MapBuildPipeline._build_metrics(
            3,
            {"blocks": 1, "phaseTimings": {}},
            {
                "recordCount": 0,
                "phaseTimings": {
                    "buildingNormalization": 0.25,
                    "blockEncoding": 0.5,
                },
            },
        )
        self.assertNotIn("buildingComplexity", metrics)

    def test_selected_extraction_rejects_duplicate_scope_markers(self):
        source = SourceRegion(
            id="sg",
            provider="test",
            name="Singapore",
            url="https://example.invalid/sg.osm.pbf",
            bounds=Bounds(103.0, 1.0, 104.5, 1.8),
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = MapJobService(
                SourceIndex([source]),
                JobStore(root / "jobs"),
                label_target2_enabled=True,
                building_target3_enabled=True,
            ).create_job(
                {
                    "mode": "custom_bbox",
                    "bbox": [103.75, 1.24, 103.93, 1.37],
                    "target": {
                        "renderer": "esp32-fmb",
                        "rendererFormatVersion": 3,
                    },
                    "labels": {
                        "profileVersion": 1,
                        "preferredLanguages": ["en"],
                        "internationalFallback": "en",
                    },
                }
            )
            pipeline = MapBuildPipeline(
                PipelinePaths(root, root / "work", root / "packs"),
                runner=DuplicateBuildingScopeRunner(),
            )
            with self.assertRaisesRegex(RuntimeError, "BUILDING_SCOPE more than once"):
                pipeline._extract_features(
                    job,
                    root / "features",
                    root / "map",
                    scope_plan_path=root / "scope-plan.json",
                )

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
