"""Tests for the planet builder's chain, its status command and its scripts."""

import contextlib
import fcntl
import gzip
import hashlib
import http.server
import io
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from unittest.mock import patch

ROUTING = Path(__file__).resolve().parent
BUILDER = ROUTING / "builder"
sys.path.insert(0, str(BUILDER))

import build_graph  # noqa: E402
import builder_status  # noqa: E402
import chain_state  # noqa: E402
import elevation_cache  # noqa: E402
import prepare_sample  # noqa: E402
import qualification  # noqa: E402
import rehearse  # noqa: E402
import run_stage  # noqa: E402

SHELL_SCRIPTS = sorted(BUILDER.glob("*.sh")) + sorted((BUILDER / "stages").glob("*.sh"))
GRADED_ENV = "BICINO_PLANET_DATE=261116\nBICINO_OPENING_RADIUS=400\n"


def make_tile_set(directory, cells, method=None, seed=b""):
    """A finished tile set as build_elevation.py leaves it, with small tiles."""
    listing = ""
    (directory / "receipts").mkdir(parents=True)
    for cell in sorted(cells):
        payload = (cell.encode() + seed) * 512
        digest = hashlib.sha256(payload).hexdigest()
        tile = directory / cell[:3] / f"{cell}.hgt.gz"
        tile.parent.mkdir(exist_ok=True)
        tile.write_bytes(gzip.compress(payload, mtime=0))
        (directory / "receipts" / f"{cell}.json").write_text(json.dumps({"cell": cell, "hgtSha256": digest}) + "\n")
        listing += f"{cell} {digest}\n"
    (directory / "cells.txt").write_text(listing)
    manifest = {"schema": "bicino-valhalla-elevation-v1", "method": method, "cells": len(cells),
                "cellListSha256": hashlib.sha256(listing.encode()).hexdigest(), "fileBytes": 1,
                "sources": [{"id": "copernicus-test", "indexSha256": "0" * 64, "cells": len(cells)}],
                "policy": {"sha256": "1" * 64}, "runtime": {"rasterio": "1.4.4"}}
    (directory / "elevation-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if method is None:
        (directory / "index").mkdir()
        (directory / "index" / "copernicus-test.tileList.txt").write_text("the source's own list\n")


def files_of(directory):
    return {str(path.relative_to(directory)): path.read_bytes() for path in sorted(directory.rglob("*")) if path.is_file()}


class Clock:
    def __init__(self, start=1_795_000_000):
        self.now = start

    def __call__(self):
        return self.now


class ScratchCase(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        (self.root / "builder.env").write_text(GRADED_ENV)
        self.chain = self.root / "export" / "chain"
        self.clock = Clock()

    def finish(self, *stages, state="done"):
        for stage in stages:
            chain_state.mark(self.root, stage, "running", clock=self.clock)
            self.clock.now += 60
            chain_state.mark(self.root, stage, state, exit_status=0 if state == "done" else 1, clock=self.clock)

    def states(self):
        return {entry["stage"]: entry["state"] for entry in chain_state.stage_states(self.root)}

    def hold_lock(self, stage):
        """Stand in for a live wrapper."""
        self.chain.mkdir(parents=True, exist_ok=True)
        lock = (self.chain / f"{stage}.lock").open("ab")
        fcntl.flock(lock, fcntl.LOCK_EX)
        self.addCleanup(lock.close)
        return lock

    def write_gate_summary(self, failures):
        gate = self.root / "export" / "evidence" / "gate"
        gate.mkdir(parents=True, exist_ok=True)
        (gate / "gate-summary.json").write_text(json.dumps({"table": [], "failures": failures}))


class ChainStateTests(ScratchCase):
    def test_a_marker_records_attempts_times_and_the_exit_status(self):
        started = chain_state.mark(self.root, "download", "running", clock=self.clock)
        self.assertEqual((started["attempt"], started["finishedAt"], started["exitStatus"]), (1, None, None))
        self.clock.now += 2100
        done = chain_state.mark(self.root, "download", "done", exit_status=0, clock=self.clock)
        self.assertEqual((done["state"], done["attempt"], done["seconds"], done["exitStatus"]), ("done", 1, 2100, 0))
        self.assertEqual(done["startedAt"], started["startedAt"])
        self.assertEqual(chain_state.read_marker(self.chain, "download"), done)

    def test_a_failure_keeps_the_reason_and_the_end_of_the_log(self):
        logs = self.root / "export" / "logs"
        logs.mkdir(parents=True)
        (logs / "elevation.log").write_text("".join(f"line {number}\n" for number in range(100)))
        chain_state.mark(self.root, "elevation", "running", clock=self.clock)
        failed = chain_state.mark(self.root, "elevation", "failed", exit_status=1, reason="exited 1", clock=self.clock)
        self.assertEqual(failed["logTail"][-1], "line 99")
        self.assertEqual(len(failed["logTail"]), chain_state.LOG_TAIL_LINES)
        again = chain_state.mark(self.root, "elevation", "running", clock=self.clock)
        self.assertEqual((again["attempt"], again["reason"]), (2, None))
        self.assertNotIn("logTail", again)

    def test_a_failed_stage_blocks_only_what_needs_it(self):
        self.finish("images", "download", "inputs", "build-ungraded")
        self.finish("elevation", state="failed")
        states = self.states()
        self.assertEqual(states["elevation"], "failed")
        self.assertEqual({states[stage] for stage in ("build-graded", "qualify-graded", "gate")}, {"blocked"})
        self.assertEqual(states["qualify-ungraded"], "waiting")
        status, _ = chain_state.chain_status(self.root, self.clock)
        self.assertEqual(status["state"], "failed")
        blocked = next(entry for entry in status["stages"] if entry["stage"] == "gate")
        self.assertEqual(blocked["blockedBy"], ["qualify-graded"])

    def test_running_needs_a_live_wrapper(self):
        chain_state.mark(self.root, "download", "running", clock=self.clock)
        self.assertEqual(self.states()["download"], "interrupted")
        status, _ = chain_state.chain_status(self.root, self.clock)
        self.assertEqual(status["state"], "failed")
        self.hold_lock("download")
        self.assertEqual(self.states()["download"], "running")
        self.assertEqual(chain_state.chain_status(self.root, self.clock)[0]["state"], "running")

    def test_a_chain_nobody_drives_is_stalled_not_running(self):
        self.assertEqual(chain_state.chain_status(self.root, self.clock)[0]["state"], "not-started")
        self.finish("images", "download")
        # systemd starts the next stage within a moment.
        self.clock.now += chain_state.STALL_SECONDS - 1
        self.assertEqual(chain_state.chain_status(self.root, self.clock)[0]["state"], "running")
        self.clock.now += 2
        self.assertEqual(chain_state.chain_status(self.root, self.clock)[0]["state"], "stalled")

    def test_a_complete_chain_reports_the_gate(self):
        self.finish(*chain_state.STAGES)
        status, summary = chain_state.chain_status(self.root, self.clock)
        # A gate stage that left no summary is never a pass.
        self.assertEqual((status["state"], status["verdict"]), ("complete", "missed"))
        self.write_gate_summary({"opened-400": [], "ungraded": []})
        self.assertEqual(chain_state.chain_status(self.root, self.clock)[0]["verdict"], "met")
        self.write_gate_summary({"opened-400": ["a flat leg is +28.2% longer"]})
        status, summary = chain_state.chain_status(self.root, self.clock)
        self.assertEqual(status["verdict"], "missed")
        self.assertEqual(summary["failures"]["opened-400"], ["a flat leg is +28.2% longer"])
        self.assertIsNotNone(status["finishedAt"])

    def test_an_ungraded_run_completes_without_a_gate(self):
        self.finish("images", "download", "inputs", "build-ungraded", "qualify-ungraded")
        for stage in run_stage.GRADED_ONLY:
            chain_state.mark(self.root, stage, "skipped", note="no opening radius", clock=self.clock)
        status, _ = chain_state.chain_status(self.root, self.clock)
        self.assertEqual((status["state"], status["verdict"]), ("complete", "not-run"))

    def test_the_result_holds_manifests_and_links_the_archives(self):
        self.finish(*chain_state.STAGES)
        self.write_gate_summary({"opened-400": []})
        for label in ("ungraded", "graded"):
            build = self.root / "build" / f"planet-{label}"
            build.mkdir(parents=True)
            (build / "manifest.json").write_text(json.dumps({"archive": {"sha256": label}}))
            (build / "valhalla_tiles.tar").write_bytes(label.encode())
        (self.root / "elevation").mkdir()
        (self.root / "elevation" / "elevation-manifest.json").write_text('{"cells": 26475}')
        (self.root / "elevation" / "cells.txt").write_text("N52E013 abc\n")
        result = chain_state.write_result(self.root, final=True, clock=self.clock)
        export = self.root / "export"
        self.assertEqual(json.loads((export / "result.json").read_text()), result)
        self.assertEqual((result["schema"], result["state"], result["verdict"], result["final"]),
                         (chain_state.SCHEMA, "complete", "met", True))
        self.assertEqual(result["archives"]["graded"], {"archive": {"sha256": "graded"}})
        self.assertEqual(result["elevation"]["opened"], {"cells": 26475})
        self.assertEqual(result["run"]["openingRadiusMetres"], "400")
        self.assertTrue((export / "graded" / "valhalla_tiles.tar").samefile(
            self.root / "build" / "planet-graded" / "valhalla_tiles.tar"))
        self.assertEqual((export / "evidence" / "elevation-opened" / "cells.txt").read_text(), "N52E013 abc\n")
        # A second collection keeps the links.
        chain_state.write_result(self.root, final=True, clock=self.clock)
        self.assertEqual((export / "ungraded" / "valhalla_tiles.tar").stat().st_nlink, 2)

    def test_the_text_names_the_failure(self):
        self.finish("images", "download")
        self.finish("elevation", state="failed")
        text = chain_state.describe(chain_state.chain_status(self.root, self.clock)[0])
        self.assertTrue(text.startswith("chain: failed"), text)
        self.assertRegex(text, r"elevation\s+failed\s+\S+, 60 s, exit 1")
        self.assertRegex(text, r"build-graded\s+blocked\s+needs elevation")

    def test_a_marker_records_the_settings_its_stage_depends_on(self):
        (self.root / "builder.env").write_text(GRADED_ENV + "BICINO_TOOLS_COMMIT=abc123\nBICINO_UNGRADED_THREADS=8\n")
        self.finish("images", "download", "elevation", "build-graded")
        markers = {stage: chain_state.read_marker(self.chain, stage) for stage in ("download", "elevation", "build-graded")}
        self.assertEqual(markers["download"]["settings"], {"BICINO_PLANET_DATE": "261116", "BICINO_SAMPLE_CITY": "",
                                                           "BICINO_SAMPLE_REGION_URL": ""})
        # A terrain source changes the tagging rules of both graphs, so the ungraded build depends on it too.
        self.assertEqual(chain_state.stage_settings("build-ungraded", {}),
                         {**dict.fromkeys(markers["download"]["settings"], ""), "BICINO_TERRAIN": ""})
        self.assertEqual(markers["elevation"]["settings"], {"BICINO_MAP_PLATFORM_IMAGE": "", "BICINO_OPENING_RADIUS": "400",
                                                            "BICINO_TERRAIN": "", "BICINO_SAMPLE_CITY": ""})
        # A graph build depends on everything the stages it needs depend on.
        self.assertEqual(set(markers["build-graded"]["settings"]),
                         set(markers["download"]["settings"]) | set(markers["elevation"]["settings"]))
        self.assertEqual({marker["toolsCommit"] for marker in markers.values()}, {"abc123"})

    def test_a_terrain_source_makes_both_graph_builds_and_the_elevation_stale(self):
        self.finish("images", "download", "inputs", "elevation", "build-ungraded", "build-graded")
        (self.root / "builder.env").write_text(GRADED_ENV + "BICINO_TERRAIN=usgs-3dep-13\n")
        states = self.states()
        self.assertEqual({states[stage] for stage in ("elevation", "build-ungraded", "build-graded")}, {"stale"})
        self.assertEqual({states[stage] for stage in ("images", "download", "inputs")}, {"done"})
        status = chain_state.chain_status(self.root, self.clock)[0]
        self.assertEqual(status["run"]["terrainSource"], "usgs-3dep-13")
        stale = next(entry for entry in status["stages"] if entry["stage"] == "build-ungraded")
        self.assertEqual(stale["reason"], "done under other settings: BICINO_TERRAIN was '', is now 'usgs-3dep-13'")

    def test_a_hybrid_run_records_every_tile_set(self):
        (self.root / "builder.env").write_text(GRADED_ENV + "BICINO_TERRAIN=usgs-3dep-13\n")
        self.finish(*chain_state.STAGES)
        self.write_gate_summary({"usgs-3dep-13-over-opened-400": []})
        sets = {"elevation-raw": "elevation-manifest.json", "elevation-opened": "elevation-manifest.json",
                "elevation-terrain": "terrain-manifest.json", "elevation": "elevation-manifest.json"}
        for directory, manifest in sets.items():
            (self.root / directory).mkdir()
            (self.root / directory / manifest).write_text(json.dumps({"set": directory}))
            (self.root / directory / "cells.txt").write_text(f"{directory}\n")
        result = chain_state.write_result(self.root, final=True, clock=self.clock)
        self.assertEqual(result["elevation"], {"raw": {"set": "elevation-raw"}, "opened": {"set": "elevation-opened"},
                                               "terrain": {"set": "elevation-terrain"}, "hybrid": {"set": "elevation"}})
        evidence = self.root / "export" / "evidence"
        self.assertEqual({kind: (evidence / f"elevation-{kind}" / "cells.txt").read_text().strip()
                          for kind in ("raw", "opened", "terrain", "hybrid")},
                         {"raw": "elevation-raw", "opened": "elevation-opened", "terrain": "elevation-terrain",
                          "hybrid": "elevation"})
        self.assertEqual(json.loads((evidence / "elevation-terrain" / "terrain-manifest.json").read_text()),
                         {"set": "elevation-terrain"})
        # The next run on this scratch has no terrain source. The earlier run's directories are still
        # there, but `elevation/` now holds the opened tiles its graph is graded with, and nothing else counts.
        (self.root / "builder.env").write_text(GRADED_ENV)
        (self.root / "elevation" / "elevation-manifest.json").write_text('{"set": "opened again"}')
        for marker in self.chain.glob("*.json"):
            marker.unlink()
        self.finish(*chain_state.STAGES)
        result = chain_state.write_result(self.root, final=True, clock=self.clock)
        self.assertEqual(result["elevation"], {"raw": {"set": "elevation-raw"}, "opened": {"set": "opened again"}})
        self.assertEqual(sorted(path.name for path in evidence.glob("elevation-*")), ["elevation-opened", "elevation-raw"])
        self.assertEqual(json.loads((evidence / "elevation-opened" / "elevation-manifest.json").read_text()),
                         {"set": "opened again"})

    def test_work_done_under_other_settings_is_stale_not_reused(self):
        self.finish("images", "download", "inputs", "elevation", "build-ungraded", "build-graded")
        (self.root / "builder.env").write_text("BICINO_PLANET_DATE=261116\nBICINO_OPENING_RADIUS=300\n")
        states = self.states()
        # The download and the ungraded build do not depend on the radius.
        self.assertEqual((states["download"], states["build-ungraded"], states["inputs"]), ("done", "done", "done"))
        self.assertEqual((states["elevation"], states["build-graded"]), ("stale", "stale"))
        self.assertEqual((states["qualify-ungraded"], states["qualify-graded"], states["gate"]), ("waiting", "blocked", "blocked"))
        status, _ = chain_state.chain_status(self.root, self.clock)
        self.assertEqual(status["state"], "failed")
        stale = next(entry for entry in status["stages"] if entry["stage"] == "elevation")
        self.assertEqual(stale["reason"], "done under other settings: BICINO_OPENING_RADIUS was '400', is now '300'")
        self.assertRegex(chain_state.describe(status), r"elevation\s+stale\s+done under other settings")
        # The settings it ran under are still in its marker, and restoring them restores it.
        self.assertEqual(chain_state.read_marker(self.chain, "elevation")["settings"]["BICINO_OPENING_RADIUS"], "400")
        (self.root / "builder.env").write_text(GRADED_ENV)
        self.assertEqual(self.states()["elevation"], "done")
        # Another planet snapshot keeps what does not read the planet.
        (self.root / "builder.env").write_text("BICINO_PLANET_DATE=261123\nBICINO_OPENING_RADIUS=400\n")
        self.assertEqual([stage for stage, state in self.states().items() if state == "done"], ["images", "inputs", "elevation"])
        # Another map-platform image keeps the download and the graph it did not touch.
        (self.root / "builder.env").write_text(GRADED_ENV + "BICINO_MAP_PLATFORM_IMAGE=ghcr.io/x@sha256:1\n")
        self.assertEqual([stage for stage, state in self.states().items() if state == "done"], ["download", "build-ungraded"])
        self.assertEqual({self.states()[stage] for stage in ("images", "inputs", "elevation", "build-graded")}, {"stale"})

    def test_newer_tools_keep_finished_work_and_the_result_says_so(self):
        (self.root / "builder.env").write_text(GRADED_ENV + "BICINO_TOOLS_COMMIT=" + "a" * 40 + "\n")
        self.finish("images", "download")
        (self.root / "builder.env").write_text(GRADED_ENV + "BICINO_TOOLS_COMMIT=" + "b" * 40 + "\n")
        self.finish("elevation")
        self.assertEqual({self.states()[stage] for stage in ("images", "download", "elevation")}, {"done"})
        status, _ = chain_state.chain_status(self.root, self.clock)
        commits = {entry["stage"]: entry.get("toolsCommit") for entry in status["stages"]}
        self.assertEqual((commits["download"], commits["elevation"], status["run"]["toolsCommit"]),
                         ("a" * 40, "b" * 40, "b" * 40))
        self.assertIn("NOTE: the stages ran with different tools: aaaaaaaaaaaa (images, download); bbbbbbbbbbbb (elevation)",
                      chain_state.describe(status))

    def test_the_status_says_what_was_restored_and_a_record_makes_no_work_stale(self):
        self.finish("images", "download", "inputs", "elevation", "build-ungraded", "build-graded")
        record = "elevation-cache-2026-11-26.json"
        report = self.root / "export" / "evidence" / "elevation-cache.json"
        chain_state.write_json(report, {"record": record, "sets": {
            "raw": {"restored": True, "seconds": 412, "tilesAsRecorded": True},
            "opened-400": {"restored": False, "kept": True, "reason": "may not read N0.tar (HTTP 403)"},
            "opened-200": {"restored": False, "kept": False, "reason": "holds no set"}}})
        # Without the setting, the report is an earlier run's.
        self.assertIsNone(chain_state.chain_status(self.root, self.clock)[0]["elevationRestore"])
        (self.root / "builder.env").write_text(GRADED_ENV + f"BICINO_ELEVATION_CACHE={record}\n")
        status, _ = chain_state.chain_status(self.root, self.clock)
        # The tiles are the same tiles however they arrived: the finished stages stand.
        self.assertEqual(self.states()["elevation"], "done")
        self.assertEqual(self.states()["build-graded"], "done")
        self.assertEqual(status["run"]["elevationCache"], record)
        self.assertEqual(status["elevationRestore"]["sets"]["raw"]["seconds"], 412)
        self.assertIn(f"  kept tiles of {record}: raw restored in 412 s; opened-400 NOT restored and built instead "
                      "(may not read N0.tar (HTTP 403)); opened-200 not kept, built", chain_state.describe(status))
        self.assertEqual(chain_state.build_result(self.root, clock=self.clock)["elevationRestore"]["record"], record)
        (self.root / "builder.env").write_text(GRADED_ENV + "BICINO_ELEVATION_CACHE=elevation-cache-2027-01-01.json\n")
        self.assertIsNone(chain_state.chain_status(self.root, self.clock)[0]["elevationRestore"])

    def test_a_marker_without_settings_is_never_trusted(self):
        self.finish("download")
        marker = json.loads((self.chain / "download.json").read_text())
        del marker["settings"]
        (self.chain / "download.json").write_text(json.dumps(marker))
        self.assertEqual(self.states()["download"], "stale")

    def test_a_sample_run_is_marked_as_one(self):
        (self.root / "builder.env").write_text("BICINO_SAMPLE_CITY=New York\nBICINO_OPENING_RADIUS=200\n")
        status, _ = chain_state.chain_status(self.root, self.clock)
        self.assertEqual((status["sample"], status["run"]["sampleCity"]), (True, "New York"))
        self.assertIn("SAMPLE REHEARSAL", chain_state.describe(status))


class RunStageTests(ScratchCase):
    def setUp(self):
        super().setUp()
        self.stages = self.root / "stub-stages"
        self.stages.mkdir()
        self.ran = self.root / "ran.txt"
        self.script("exit 0")

    def script(self, body, names=("images.sh", "download.sh", "inputs.sh", "elevation.sh", "build.sh", "qualify.sh", "gate.sh")):
        for name in names:
            path = self.stages / name
            path.write_text(f'#!/bin/bash\necho "$BICINO_STAGE $*" >> "{self.ran}"\necho "output of $BICINO_STAGE"\n{body}\n')
            path.chmod(0o755)

    def run_stage(self, stage):
        self.said = io.StringIO()
        with patch.object(run_stage.shutil, "which", return_value=None), \
                contextlib.redirect_stdout(self.said), contextlib.redirect_stderr(self.said):
            return run_stage.run(self.root, stage, self.stages)

    def ran_stages(self):
        return self.ran.read_text().splitlines() if self.ran.exists() else []

    def test_a_stage_is_logged_marked_done_and_never_run_twice(self):
        self.assertEqual(self.run_stage("download"), 0)
        marker = chain_state.read_marker(self.chain, "download")
        self.assertEqual((marker["state"], marker["exitStatus"], marker["attempt"]), ("done", 0, 1))
        log = (self.root / "export" / "logs" / "download.log").read_text()
        self.assertIn("output of download", log)
        self.assertRegex(log, r"== download end=\S+ exit=0")
        # A restarted unit finds the marker and leaves the finished work alone.
        self.assertEqual(self.run_stage("download"), 0)
        self.assertEqual(self.ran_stages(), ["download "])
        self.assertEqual(json.loads((self.root / "export" / "result.json").read_text())["state"], "running")

    def test_a_failure_is_marked_with_its_status_and_can_be_retried(self):
        self.script("echo broken >&2; exit 3", names=("download.sh",))
        self.assertEqual(self.run_stage("download"), 3)
        marker = chain_state.read_marker(self.chain, "download")
        self.assertEqual((marker["state"], marker["exitStatus"]), ("failed", 3))
        self.assertIn("status 3", marker["reason"])
        self.assertIn("broken", marker["logTail"])
        self.script("exit 0", names=("download.sh",))
        self.assertEqual(self.run_stage("download"), 0)
        self.assertEqual(chain_state.read_marker(self.chain, "download")["attempt"], 2)

    def test_a_stage_does_not_start_before_what_it_needs(self):
        self.assertEqual(self.run_stage("build-graded"), run_stage.BLOCKED)
        self.assertIsNone(chain_state.read_marker(self.chain, "build-graded"))
        self.assertEqual(self.ran_stages(), [])
        self.finish("images", "download")
        self.finish("elevation", state="failed")
        self.assertEqual(self.run_stage("build-graded"), run_stage.BLOCKED)
        self.assertIn("build-graded: not started, it needs elevation (failed)", self.said.getvalue())
        self.assertEqual(self.states()["build-graded"], "blocked")
        self.assertEqual(self.run_stage("build-ungraded"), 0)
        self.assertEqual(self.ran_stages(), ["build-ungraded ungraded"])

    def test_graded_stages_are_skipped_without_an_opening_radius(self):
        (self.root / "builder.env").write_text("BICINO_PLANET_DATE=261116\nBICINO_OPENING_RADIUS=\n")
        for stage in run_stage.GRADED_ONLY:
            self.assertEqual(self.run_stage(stage), 0)
            self.assertEqual(chain_state.read_marker(self.chain, stage)["state"], "skipped")
        self.assertEqual(self.ran_stages(), [])
        self.assertIsNone(run_stage.skip_reason("build-ungraded", {}))
        self.assertIsNone(run_stage.skip_reason("inputs", {"BICINO_OPENING_RADIUS": "400"}))
        self.assertIn("sample", run_stage.skip_reason("inputs", {"BICINO_SAMPLE_CITY": "Berlin"}))

    def test_stale_work_is_neither_reused_nor_run_over(self):
        self.finish("images", "download")
        self.assertEqual(self.run_stage("elevation"), 0)
        (self.root / "builder.env").write_text("BICINO_PLANET_DATE=261116\nBICINO_OPENING_RADIUS=300\n")
        self.assertEqual(self.run_stage("elevation"), run_stage.STALE)
        self.assertIn("BICINO_OPENING_RADIUS was '400', is now '300'", self.said.getvalue())
        self.assertIn("delete", self.said.getvalue())
        # The script did not run again, and the marker still tells what the tiles are.
        self.assertEqual(self.ran_stages(), ["elevation "])
        marker = chain_state.read_marker(self.chain, "elevation")
        self.assertEqual((marker["state"], marker["settings"]["BICINO_OPENING_RADIUS"]), ("done", "400"))
        self.assertEqual(self.run_stage("build-graded"), run_stage.BLOCKED)
        # With its marker deleted the stage runs under the new settings.
        (self.chain / "elevation.json").unlink()
        self.assertEqual(self.run_stage("elevation"), 0)
        self.assertEqual(chain_state.read_marker(self.chain, "elevation")["settings"]["BICINO_OPENING_RADIUS"], "300")

    def test_a_stage_skipped_under_other_settings_runs_when_they_ask_for_it(self):
        self.finish("images", "download")
        (self.root / "builder.env").write_text("BICINO_PLANET_DATE=261116\nBICINO_OPENING_RADIUS=\n")
        self.assertEqual(self.run_stage("elevation"), 0)
        self.assertEqual(chain_state.read_marker(self.chain, "elevation")["state"], "skipped")
        (self.root / "builder.env").write_text(GRADED_ENV)
        self.assertEqual(self.states()["elevation"], "stale")
        self.assertEqual(self.run_stage("elevation"), 0)
        self.assertEqual((chain_state.read_marker(self.chain, "elevation")["state"], self.ran_stages()), ("done", ["elevation "]))

    def test_a_second_wrapper_for_a_running_stage_refuses(self):
        self.hold_lock("download")
        with patch.object(run_stage, "LOCK_WAIT_SECONDS", 0.3):
            self.assertEqual(run_stage.take_lock(self.chain / "download.lock", 0.3), None)
            self.assertEqual(self.run_stage("download"), run_stage.ALREADY_RUNNING)
        self.assertEqual(self.ran_stages(), [])

    def test_the_stage_does_not_inherit_the_wrappers_lock(self):
        self.script(f'sleep 30 &\necho $! > "{self.root}/orphan.pid"\nexit 0', names=("download.sh",))
        self.assertEqual(self.run_stage("download"), 0)
        self.addCleanup(lambda: os.kill(int((self.root / "orphan.pid").read_text()), signal.SIGKILL))
        # The orphan is alive, yet nothing holds the lock that means "running".
        self.assertFalse(chain_state.lock_is_held(self.chain, "download"))

    def test_a_stopped_stage_is_recorded_as_stopped(self):
        self.script("sleep 30", names=("download.sh",))
        timer = threading.Timer(0.5, os.kill, (os.getpid(), signal.SIGTERM))
        timer.start()
        self.addCleanup(timer.cancel)
        self.assertEqual(self.run_stage("download"), 128 + signal.SIGTERM)
        marker = chain_state.read_marker(self.chain, "download")
        self.assertEqual((marker["state"], marker["reason"]), ("failed", "stopped by SIGTERM"))

    def test_finalize_records_a_wrapper_that_was_killed(self):
        chain_state.mark(self.root, "elevation", "running", clock=self.clock)
        with patch.object(run_stage.shutil, "which", return_value=None):
            run_stage.finalize(self.root, "elevation",
                               {"SERVICE_RESULT": "timeout", "EXIT_CODE": "killed", "EXIT_STATUS": "KILL"})
        marker = chain_state.read_marker(self.chain, "elevation")
        self.assertEqual((marker["state"], marker["exitStatus"]), ("failed", None))
        self.assertEqual(marker["reason"], "systemd ended the stage: timeout (killed KILL)")
        # A stage that recorded its own result is left as it is.
        self.finish("download")
        with patch.object(run_stage.shutil, "which", return_value=None):
            run_stage.finalize(self.root, "download", {"SERVICE_RESULT": "success"})
        self.assertEqual(chain_state.read_marker(self.chain, "download")["state"], "done")

    def test_leftover_containers_are_removed_by_their_label(self):
        calls = []

        def fake_run(command, **_kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, stdout="abc123\ndef456\n", stderr="")

        with patch.object(run_stage.shutil, "which", return_value="/usr/bin/docker"), \
                patch.object(run_stage.subprocess, "run", fake_run), (self.root / "log").open("w") as log:
            run_stage.remove_containers(self.root, "gate", log)
            self.assertEqual(calls, [["docker", "ps", "-aq", "--filter", "label=bicino.stage=gate"],
                                     ["docker", "rm", "-f", "abc123", "def456"]])
            # A killed graph build leaves build_graph.py's container, labelled with its work directory.
            del calls[:]
            run_stage.remove_containers(self.root, "build-graded", log)
        self.assertEqual([call[-1] for call in calls[:2]],
                         ["label=bicino.stage=build-graded", f"label=bicino.work={self.root}/build/planet-graded"])
        self.assertEqual(calls[2], ["docker", "rm", "-f", "abc123", "def456", "abc123", "def456"])


class UnitFileTests(unittest.TestCase):
    UNITS = rehearse.load_units(BUILDER / "units")
    RUN = "/usr/bin/python3 /srv/bicino-routing-scratch/tools/repo/map-platform/routing/builder/"

    def test_every_stage_has_a_unit_that_follows_what_it_needs(self):
        stage_units = {name for name in self.UNITS if name not in (rehearse.RESULT, rehearse.SAMPLER)}
        self.assertEqual(stage_units, {f"bicino-planet-{stage}.service" for stage in chain_state.STAGES})
        for stage, needs in chain_state.STAGES.items():
            unit = self.UNITS[f"bicino-planet-{stage}.service"]
            needed = [f"bicino-planet-{need}.service" for need in needs]
            for key in ("Wants", "After"):
                ours = [name for name in unit[key][0].split() if name.startswith("bicino-planet-")]
                self.assertEqual(ours, needed, f"{stage} {key}")
            # Requires= would stop a running stage when a unit it needs is restarted.
            self.assertNotIn("Requires", unit, stage)
            self.assertEqual(unit["ExecStart"], [f"{self.RUN}run_stage.py {stage}"])
            self.assertEqual(unit["ExecStopPost"], [f"{self.RUN}run_stage.py --finalize {stage}"])
            self.assertEqual((unit["Type"], unit["RemainAfterExit"], unit["User"]), (["oneshot"], ["yes"], ["bicino"]))
            self.assertEqual(unit["EnvironmentFile"], ["/srv/bicino-routing-scratch/builder.env"])
            self.assertRegex(unit["TimeoutStartSec"][0], r"^[0-9]+(min|h)$")

    def test_the_result_unit_runs_after_every_stage_whatever_happened(self):
        unit = self.UNITS[rehearse.RESULT]
        stages = [f"bicino-planet-{stage}.service" for stage in chain_state.STAGES]
        self.assertEqual(unit["After"][0].split(), stages)
        self.assertEqual(unit["Wants"][0].split(), [rehearse.SAMPLER, *stages])
        self.assertNotIn("Requires", unit)
        self.assertEqual(unit["ExecStart"], [f"{self.RUN}chain_state.py result --final"])
        order = rehearse.ordered(self.UNITS)
        self.assertEqual(order[-1], rehearse.RESULT)
        # The rehearsal runs a stage ahead of those it does not wait for, so a
        # stage that reads the download's output without waiting for it fails there.
        self.assertLess(order.index("bicino-planet-elevation.service"), order.index("bicino-planet-download.service"))
        for stage, needs in chain_state.STAGES.items():
            for need in needs:
                self.assertLess(order.index(f"bicino-planet-{need}.service"), order.index(f"bicino-planet-{stage}.service"))

    def test_every_stage_has_an_executable_script(self):
        self.assertEqual(set(run_stage.SCRIPTS), set(chain_state.STAGES))
        for script, *_ in run_stage.SCRIPTS.values():
            self.assertTrue(os.access(BUILDER / "stages" / script, os.X_OK), script)
        for stage in run_stage.GRADED_ONLY:
            self.assertIn(stage, chain_state.STAGES)


class ChainRehearsalTests(unittest.TestCase):
    """The checked-in units, run in order as systemd would, over stub stages."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.builder = self.root / "tools" / "repo" / "map-platform" / "routing" / "builder"
        (self.builder / "stages").mkdir(parents=True)
        for name in ("chain_state.py", "run_stage.py"):
            shutil.copy(BUILDER / name, self.builder / name)
        shutil.copytree(BUILDER / "units", self.builder / "units")
        (self.root / "builder.env").write_text(GRADED_ENV)
        self.ran = self.root / "ran.txt"
        for script in {script for script, *_ in run_stage.SCRIPTS.values()}:
            self.stub(script)
        self.messages = []
        # A stand-in Docker with no containers, wherever the tests run.
        self.tools = self.root / "bin"
        self.tools.mkdir()
        (self.tools / "docker").write_text(f'#!/bin/bash\necho "$*" >> "{self.root}/docker.txt"\n')
        (self.tools / "docker").chmod(0o755)

    def stub(self, script, body="exit 0"):
        path = self.builder / "stages" / script
        path.write_text(f'#!/bin/bash\necho "$BICINO_STAGE" >> "{self.ran}"\n{body}\n')
        path.chmod(0o755)

    def start(self, **options):
        with patch.dict(os.environ, {"PATH": f"{self.tools}:/usr/bin:/bin"}):
            return rehearse.start_chain(self.root, self.builder / "units", out=self.messages.append,
                                        interpreter=sys.executable, output=subprocess.DEVNULL, **options)

    def result(self):
        return json.loads((self.root / "export" / "result.json").read_text())

    def test_the_chain_runs_every_stage_in_order_and_writes_the_result(self):
        (self.root / "export" / "evidence" / "gate").mkdir(parents=True)
        (self.root / "export" / "evidence" / "gate" / "gate-summary.json").write_text('{"failures": {"opened-400": []}}')
        self.assertEqual(self.start(), 0)
        ran = self.ran.read_text().split()
        self.assertEqual(sorted(ran), sorted(chain_state.STAGES))
        for stage, needs in chain_state.STAGES.items():
            for need in needs:
                self.assertLess(ran.index(need), ran.index(stage))
        result = self.result()
        self.assertEqual((result["state"], result["verdict"], result["final"]), ("complete", "met", True))
        self.assertEqual({entry["state"] for entry in result["stages"]}, {"done"})

    def test_a_failed_stage_stops_what_needs_it_and_a_restart_resumes(self):
        self.stub("elevation.sh", "echo 'third round lost a worker'; exit 1")
        self.assertEqual(self.start(), 1)
        result = self.result()
        states = {entry["stage"]: entry["state"] for entry in result["stages"]}
        self.assertEqual(result["state"], "failed")
        self.assertEqual(states["elevation"], "failed")
        self.assertEqual({states[stage] for stage in ("build-graded", "qualify-graded", "gate")}, {"blocked"})
        # The branch that does not need elevation finished its own work.
        self.assertEqual((states["build-ungraded"], states["qualify-ungraded"]), ("done", "done"))
        failed = next(entry for entry in result["stages"] if entry["stage"] == "elevation")
        self.assertEqual((failed["exitStatus"], failed["logTail"][-2]), (1, "third round lost a worker"))
        first = self.ran.read_text().split()
        self.assertNotIn("build-graded", first)

        self.stub("elevation.sh")
        (self.root / "export" / "evidence" / "gate").mkdir(parents=True)
        (self.root / "export" / "evidence" / "gate" / "gate-summary.json").write_text('{"failures": {"x": ["missed"]}}')
        self.assertEqual(self.start(), 0)
        second = self.ran.read_text().split()[len(first):]
        self.assertEqual(second, ["elevation", "build-graded", "qualify-graded", "gate"])
        self.assertEqual((self.result()["state"], self.result()["verdict"]), ("complete", "missed"))

    def test_a_killed_stage_is_recorded_and_a_restart_finishes(self):
        beat = self.root / "beat.txt"
        self.stub("download.sh", f'( while true; do date +%s%N > "{beat}"; sleep 0.1; done ) &\nsleep 30')
        self.assertEqual(self.start(kill_stage="download", kill_after=1.5), 1)
        # Like a unit's control group, the kill takes the stage script and what it started.
        last = beat.read_text()
        time.sleep(0.5)
        self.assertEqual(beat.read_text(), last)
        failed = next(entry for entry in self.result()["stages"] if entry["stage"] == "download")
        self.assertEqual((failed["state"], failed["reason"]),
                         ("failed", "systemd ended the stage: timeout (killed KILL)"))
        # The wrapper looked for leftover containers before the stage; it was
        # killed before it could look again, so ExecStopPost did.
        looked = (self.root / "docker.txt").read_text().splitlines()
        self.assertEqual(looked.count("ps -aq --filter label=bicino.stage=download"), 2)
        self.stub("download.sh")
        self.assertEqual(self.start(), 0)
        self.assertEqual(self.result()["state"], "complete")


def status_report(state="running", verdict=None, **extra):
    report = {"schema": builder_status.SCHEMA, "state": state, "verdict": verdict, "host": "builder",
              "now": "2026-11-26T12:00:00Z", "text": f"chain: {state}",
              "stages": [{"stage": "download", "state": "done"}, {"stage": "elevation", "state": state}]}
    return dict(report, **extra)


class FakeSsh:
    """Answers each call with the next reply: a report, text, an exit status or a timeout."""

    def __init__(self, *replies):
        self.replies = list(replies)
        self.commands = []

    def __call__(self, command, **options):
        self.commands.append(command)
        self.options = options
        reply = self.replies.pop(0)
        if isinstance(reply, subprocess.TimeoutExpired):
            raise reply
        if isinstance(reply, dict):
            reply = (0, json.dumps(reply), "")
        return subprocess.CompletedProcess(command, *reply)


class StatusCommandTests(unittest.TestCase):
    ARGUMENTS = ["--ssh-config", "/root/.ssh/job.d/config"]

    def status(self, *replies, arguments=()):
        ssh = FakeSsh(*replies)
        out, err = [], []
        def fake_print(*parts, file=None, flush=False):
            (err if file is sys.stderr else out).append(" ".join(map(str, parts)))

        with patch("builtins.print", fake_print):
            code = builder_status.main([*self.ARGUMENTS, *arguments], runner=ssh, sleep=lambda _seconds: None)
        return code, "\n".join(out), "\n".join(err), ssh

    def test_each_state_has_its_own_exit_status(self):
        cases = [(status_report("running"), builder_status.EXIT_RUNNING),
                 (status_report("complete", "met"), builder_status.EXIT_PASSED),
                 (status_report("complete", "not-run"), builder_status.EXIT_PASSED),
                 (status_report("complete", "missed"), builder_status.EXIT_MISSED),
                 (status_report("failed"), builder_status.EXIT_FAILED),
                 (status_report("stalled"), builder_status.EXIT_FAILED),
                 (status_report("not-started"), builder_status.EXIT_NOT_STARTED)]
        for report, expected in cases:
            with self.subTest(state=report["state"], verdict=report["verdict"]):
                code, out, err, _ = self.status(report)
                self.assertEqual((code, out, err), (expected, f"chain: {report['state']}", ""))
        self.assertEqual(len({code for _, code in cases} | {builder_status.EXIT_UNREACHABLE}), 6)

    def test_no_usable_answer_is_never_read_as_running(self):
        tailscale = "# Tailscale SSH requires an additional check.\n# To authenticate, visit: https://login.tailscale.com/a/1"
        silent = [
            ((255, "", "ssh: connect to host 100.64.0.1 port 22: Operation timed out"), "ssh exited with status 255"),
            ((0, "", ""), "returned nothing"),
            ((0, "  \n", "Warning: Permanently added"), "returned nothing"),
            ((0, "Welcome to Ubuntu 24.04\n", ""), "not a status report"),
            ((0, json.dumps({"schema": "something-else", "state": "running"}), ""), "not a bicino-planet-builder-result-v1"),
            ((0, json.dumps(status_report(text=None)), ""), "not a bicino-planet-builder-result-v1"),
            ((1, json.dumps(status_report()), ""), "ssh exited with status 1"),
            (subprocess.TimeoutExpired("ssh", 60, output=tailscale.encode()), "no answer within 60 s"),
            (subprocess.TimeoutExpired("ssh", 60), "no answer within 60 s"),
        ]
        for reply, expected in silent:
            with self.subTest(expected=expected):
                code, out, err, _ = self.status(reply)
                self.assertEqual((code, out), (builder_status.EXIT_UNREACHABLE, ""))
                self.assertIn("UNREACHABLE, not known to be running", err)
                self.assertIn(expected, err)
        self.assertIn("login.tailscale.com", self.status(silent[-2][0])[2])
        # A state this version does not know is not running either.
        self.assertEqual(self.status(status_report("paused"))[0], builder_status.EXIT_UNREACHABLE)

    def test_ssh_is_asked_once_with_no_prompt_and_a_deadline(self):
        code, _, _, ssh = self.status(status_report(), arguments=["--timeout", "45"])
        remote = f"/usr/bin/python3 {builder_status.REMOTE} status --json"
        self.assertEqual(ssh.commands, [["ssh", "-F", "/root/.ssh/job.d/config", "-o", "BatchMode=yes",
                                         "-o", "ConnectTimeout=20", "builder", remote]])
        self.assertEqual(ssh.options["timeout"], 45)
        self.assertEqual(ssh.options["stdin"], subprocess.DEVNULL)

    def test_a_laptop_asks_through_the_vps(self):
        _, _, _, ssh = self.status(status_report(), arguments=["--via", "root@vps"])
        command = ssh.commands[0]
        self.assertEqual(command[:6], ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "root@vps"])
        # The VPS's shell must see the builder's command as one argument again.
        inner = subprocess.run(["sh", "-c", f"printf '%s\\n' {command[6]}"], capture_output=True, text=True).stdout
        self.assertEqual(inner.splitlines()[-1], f"/usr/bin/python3 {builder_status.REMOTE} status --json")

    def test_waiting_stops_at_the_first_answer_that_is_not_running(self):
        later = status_report(stages=[{"stage": "download", "state": "done"}, {"stage": "elevation", "state": "done"}])
        code, out, err, ssh = self.status(status_report(), status_report(), later, (255, "", "Connection refused"),
                                          status_report("complete", "met"), arguments=["--wait"])
        self.assertEqual(code, builder_status.EXIT_UNREACHABLE)
        self.assertEqual(len(ssh.commands), 4)
        # One line per change, none for the poll that changed nothing.
        self.assertEqual(len(out.splitlines()), 2)
        self.assertIn("Connection refused", err)
        code, out, _, _ = self.status(status_report(), status_report("complete", "missed"), arguments=["--wait"])
        self.assertEqual((code, out.splitlines()[-1]), (builder_status.EXIT_MISSED, "chain: complete"))

    def test_an_old_heartbeat_is_called_out(self):
        report = status_report(sampler={"sampledAt": "2026-11-26T11:50:00Z"})
        self.assertIn("WARNING: the sampler has written nothing for 600 s", self.status(report)[1])
        self.assertNotIn("WARNING", self.status(status_report(sampler={"sampledAt": "2026-11-26T11:59:40Z"}))[1])

    def test_the_builders_own_report_is_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            chain_state.mark(root, "images", "running")
            chain_state.mark(root, "images", "failed", exit_status=1, reason="no network")
            with patch.dict(os.environ, {"BICINO_SCRATCH": str(root)}):
                reply = subprocess.run([sys.executable, str(BUILDER / "chain_state.py"), "status", "--json"],
                                       capture_output=True, text=True, check=True)
        code, out, _, _ = self.status((0, reply.stdout, ""))
        self.assertEqual(code, builder_status.EXIT_FAILED)
        self.assertRegex(out, r"images\s+failed\s+.*no network")


class QualificationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        units = [{"code": f"U{number:02}", "state": "routed"} for number in range(281)]
        units += [{"code": code, "state": "needs-review"} for code in qualification.KNOWN_AUDIT_EXCEPTIONS]
        self.write("smoke", {"probes": [{"name": "Dubai", "passed": True}] * 17}, 0)
        self.write("cross-border", {"probes": [{"name": "Berg", "passed": True}] * 4}, 0)
        self.write("audit", {"units": units}, 2)
        self.write("profiles", {"probes": [{}] * 5, "failures": []}, 0)

    def write(self, name, report, code):
        if report is not None:
            (self.directory / f"{name}.json").write_text(json.dumps(report))
        codes = self.directory / "exit-codes.txt"
        kept = [line for line in (codes.read_text().splitlines() if codes.exists() else []) if not line.startswith(name + " ")]
        codes.write_text("\n".join([*kept, f"{name} {code}"]) + "\n")

    def test_the_known_planet_exceptions_qualify(self):
        self.assertEqual(len(qualification.KNOWN_AUDIT_EXCEPTIONS), 17)
        summary = qualification.summarize(self.directory, "ungraded")
        self.assertTrue(summary["passed"])
        self.assertEqual((summary["checks"]["audit"]["routed"], summary["checks"]["audit"]["units"]), (281, 298))
        self.assertEqual((summary["checks"]["smoke"]["routed"], summary["checks"]["cross-border"]["probes"]), (17, 4))
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(qualification.main(["--dir", str(self.directory), "--label", "ungraded"]), 0)
        self.assertEqual(json.loads((self.directory / "summary.json").read_text()), summary)

    def test_a_unit_that_stops_routing_fails_the_audit(self):
        units = json.loads((self.directory / "audit.json").read_text())["units"]
        units[0]["state"] = "needs-review"
        units[-1]["state"] = "routed"
        self.write("audit", {"units": units}, 2)
        audit = qualification.summarize(self.directory, "graded")["checks"]["audit"]
        self.assertEqual((audit["passed"], audit["unexpected"]), (False, ["U00"]))
        self.assertEqual(audit["knownExceptionsNowRouting"], [units[-1]["code"]])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(qualification.main(["--dir", str(self.directory), "--label", "graded"]), 1)

    def test_failed_missing_and_crashed_checks_do_not_qualify(self):
        self.write("smoke", {"probes": [{"name": "Dubai", "passed": True}, {"name": "Hatta", "passed": False}]}, 1)
        self.assertEqual(qualification.summarize(self.directory, "ungraded")["checks"]["smoke"]["failed"], ["Hatta"])
        self.write("smoke", {"probes": [{"name": "Dubai", "passed": True}]}, 125)
        self.assertFalse(qualification.summarize(self.directory, "ungraded")["checks"]["smoke"]["passed"])
        (self.directory / "profiles.json").write_text("")
        profiles = qualification.summarize(self.directory, "ungraded")["checks"]["profiles"]
        self.assertEqual((profiles["passed"], profiles["error"]), (False, "the check left no report"))
        self.write("profiles", {"probes": [{}], "failures": ["no pair produced different road and gravel geometry"]}, 1)
        self.assertFalse(qualification.summarize(self.directory, "ungraded")["checks"]["profiles"]["passed"])
        self.write("audit", {"units": []}, 0)
        self.assertFalse(qualification.summarize(self.directory, "ungraded")["checks"]["audit"]["passed"])

    def test_a_sample_runs_only_the_smoke_probes(self):
        for name in ("cross-border", "audit", "profiles"):
            (self.directory / f"{name}.json").unlink()
        (self.directory / "exit-codes.txt").write_text("smoke 0\n")
        summary = qualification.summarize(self.directory, "graded", sample=True)
        self.assertTrue(summary["passed"] and summary["sample"])
        self.assertEqual(summary["checks"]["audit"], {"skipped": "not run on a city sample"})
        self.assertFalse(qualification.summarize(self.directory, "graded")["passed"])


class ScriptTests(unittest.TestCase):
    def test_every_script_parses_and_is_executable(self):
        self.assertGreaterEqual(len(SHELL_SCRIPTS), 14)
        for script in SHELL_SCRIPTS:
            with self.subTest(script=script.name):
                subprocess.run(["bash", "-n", str(script)], check=True)
                if script.name != "config.sh":
                    self.assertTrue(script.stat().st_mode & stat.S_IXUSR, script.name)
        for tool in ("chain_state.py", "run_stage.py", "builder_status.py", "qualification.py", "rehearse.py",
                     "elevation_cache.py"):
            self.assertTrue((BUILDER / tool).stat().st_mode & stat.S_IXUSR, tool)

    @unittest.skipUnless(shutil.which("shellcheck") or os.environ.get("BICINO_REQUIRE_SHELLCHECK"),
                         "shellcheck is not installed")
    def test_shellcheck_finds_nothing(self):
        checked = subprocess.run(["shellcheck", "--external-sources", "--source-path", str(BUILDER),
                                  *map(str, SHELL_SCRIPTS)], capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)

    def test_docker_only_ever_mounts_absolute_paths(self):
        # On 2026-11-25 Docker took build/planet/valhalla_tiles.tar for a volume name.
        absolute = re.compile(r'"\$(BICINO_[A-Z_]+|archive|out|elevation)[/:"]')
        mounts = 0
        for script in SHELL_SCRIPTS:
            for source in re.findall(r"(?<!printf )(?:-v|--volume)\s+(\"\S+)", script.read_text()):
                # rehearse.sh takes only absolute paths for its root and its directory of packed tiles.
                if source.startswith("/var/run/docker.sock") or source in ('"$root:$root"', '"$directory:$directory")'):
                    continue
                mounts += 1
                self.assertRegex(source, absolute, f"{script.name}: {source}")
        self.assertGreaterEqual(mounts, 12)
        for script in sorted((BUILDER / "stages").glob("*.sh")):
            text = script.read_text()
            self.assertNotRegex(text, r"(?m)^\s*cd [^\"$(]", script.name)
            self.assertIn('. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.sh"', text, script.name)
            self.assertIn("set -euo pipefail", text, script.name)

    def source_config(self, command, **environment):
        return subprocess.run(["bash", "-c", f'. "{BUILDER}/config.sh"; {command}'], capture_output=True, text=True,
                              env={"PATH": os.environ["PATH"], **environment})

    def test_the_scratch_path_must_be_absolute(self):
        relative = self.source_config("echo unreachable", BICINO_SCRATCH="scratch")
        self.assertEqual((relative.returncode, relative.stdout), (64, ""))
        self.assertIn("absolute", relative.stderr)
        default = self.source_config('echo "$BICINO_CHAIN $BICINO_LOGS"')
        self.assertEqual(default.stdout.split(), ["/srv/bicino-routing-scratch/export/chain",
                                                  "/srv/bicino-routing-scratch/export/logs"])

    def test_the_env_file_is_read_not_run(self):
        with tempfile.TemporaryDirectory() as directory:
            env = Path(directory) / "builder.env"
            env.write_text("# a run\nBICINO_SAMPLE_CITY=New York\nBICINO_OPENING_RADIUS=400\n")
            loaded = self.source_config('echo "$BICINO_SAMPLE_CITY|$BICINO_OPENING_RADIUS|$(bicino_graded_name)"',
                                        BICINO_SCRATCH=directory, BICINO_OPENING_RADIUS="200")
            self.assertEqual(loaded.stdout.strip(), "New York|400|opened-400")
            env.write_text("BICINO_OPENING_RADIUS=400\nBICINO_TERRAIN=usgs-3dep-13\n")
            hybrid = self.source_config('echo "$(bicino_graded_name)|$BICINO_ELEVATION|$BICINO_ELEVATION_OPENED|'
                                        '$BICINO_ELEVATION_TERRAIN"; bicino_is_hybrid', BICINO_SCRATCH=directory)
            self.assertEqual((hybrid.returncode, hybrid.stdout.strip()),
                             (0, f"usgs-3dep-13-over-opened-400|{directory}/elevation|{directory}/elevation-opened|"
                                 f"{directory}/elevation-terrain"))
            for line in ("BICINO_PLANET_DATE=$(touch pwned)", "PATH=/tmp", "BICINO_X='quoted'", "echo hello"):
                env.write_text(line + "\n")
                rejected = self.source_config("echo unreachable", BICINO_SCRATCH=directory)
                self.assertEqual((rejected.returncode, rejected.stdout), (64, ""), line)
            self.assertFalse((Path(directory) / "pwned").exists())

    def test_a_run_is_validated_before_any_stage_works(self):
        with tempfile.TemporaryDirectory() as directory:
            routing = Path(directory) / "tools" / "repo" / "map-platform" / "routing"
            (routing / "releases").mkdir(parents=True)
            (routing / "releases" / "elevation-cache-2026-11-26.json").write_text("{}")
            kept = "BICINO_OPENING_RADIUS=400\nBICINO_ELEVATION_CACHE=elevation-cache-2026-11-26.json\n"
            sample = ("BICINO_SAMPLE_CITY=Berlin\n"
                      "BICINO_SAMPLE_REGION_URL=https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf\n")
            cases = {"BICINO_PLANET_DATE=261116\nBICINO_OPENING_RADIUS=400\n": 0,
                     # Kept tiles: a record of this checkout, for a graded run; only a rehearsal asks elsewhere than Google.
                     "BICINO_PLANET_DATE=261116\n" + kept: 0,
                     "BICINO_PLANET_DATE=261116\nBICINO_ELEVATION_CACHE=elevation-cache-2026-11-26.json\n": 1,
                     "BICINO_PLANET_DATE=261116\nBICINO_OPENING_RADIUS=400\nBICINO_ELEVATION_CACHE=elevation-cache-2099.json\n": 1,
                     "BICINO_PLANET_DATE=261116\nBICINO_OPENING_RADIUS=400\nBICINO_ELEVATION_CACHE=../builder.env\n": 1,
                     "BICINO_PLANET_DATE=261116\n" + kept + "BICINO_ELEVATION_CACHE_ENDPOINT=http://127.0.0.1:8123\n": 1,
                     sample + kept + "BICINO_ELEVATION_CACHE_ENDPOINT=http://127.0.0.1:8123\n": 0,
                     sample + kept + "BICINO_ELEVATION_CACHE_ENDPOINT=http://tiles.example:8123\n": 1,
                     sample + "BICINO_OPENING_RADIUS=400\nBICINO_ELEVATION_CACHE_ENDPOINT=http://127.0.0.1:8123\n": 1,
                     "BICINO_PLANET_DATE=261116\n": 0,
                     "BICINO_PLANET_DATE=2026-11-16\n": 1,
                     "BICINO_PLANET_DATE=261116\nBICINO_OPENING_RADIUS=4e2\n": 1,
                     "BICINO_PLANET_DATE=261116\nBICINO_OPENING_RADIUS=400\nBICINO_TERRAIN=usgs-3dep-13\n": 0,
                     "BICINO_PLANET_DATE=261116\nBICINO_TERRAIN=usgs-3dep-13\n": 1,
                     "BICINO_PLANET_DATE=261116\nBICINO_OPENING_RADIUS=400\nBICINO_TERRAIN=USGS 3DEP\n": 1,
                     "BICINO_PLANET_DATE=261116\nBICINO_MAP_PLATFORM_IMAGE=ghcr.io/seichris/open-bike-computer-map-platform:latest\n": 1,
                     "BICINO_SAMPLE_CITY=Berlin\n": 1,
                     "BICINO_SAMPLE_CITY=Berlin\nBICINO_SAMPLE_REGION_URL=https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf\n": 0}
            for env, expected in cases.items():
                (Path(directory) / "builder.env").write_text(env)
                checked = self.source_config("bicino_validate_run", BICINO_SCRATCH=directory)
                self.assertEqual(checked.returncode, expected, env + checked.stderr)

    def run_elevation_stage(self, directory, env):
        """Run the real elevation stage with stand-ins for Docker and the GNU tools; returns it and Docker's calls."""
        root = Path(directory)
        (root / "tools" / "repo" / "map-platform").mkdir(parents=True, exist_ok=True)
        routing = root / "tools" / "repo" / "map-platform" / "routing"
        if not routing.exists():
            routing.symlink_to(ROUTING)
        (root / "builder.env").write_text(env)
        tools = root / "bin"
        tools.mkdir(exist_ok=True)
        calls = root / "docker.txt"
        calls.write_text("")
        # The stand-in Docker writes the manifest of every tile set it is given a directory for.
        (tools / "docker").write_text(f'''#!/bin/bash
echo "$*" >> "{calls}"
[ "$1" = run ] || exit 0
while [ $# -gt 0 ]; do
  if [ "$1" = -v ]; then
    case "$2" in
      *:/terrain) echo '{{}}' > "${{2%%:*}}/terrain-manifest.json" ;;
      *:/raw|*:/out|*:/opened) echo '{{}}' > "${{2%%:*}}/elevation-manifest.json" ;;
    esac
  fi
  shift
done
''')
        for name in ("sha256sum", "du"):
            (tools / name).write_text('#!/bin/bash\necho "$0 $*"\n')
        for tool in tools.iterdir():
            tool.chmod(0o755)
        ran = subprocess.run(["bash", str(BUILDER / "stages" / "elevation.sh")], capture_output=True, text=True,
                             env={"PATH": f"{tools}:{os.environ['PATH']}", "BICINO_SCRATCH": str(root),
                                  "BICINO_STAGE": "elevation"})
        return ran, [line for line in calls.read_text().splitlines() if line.startswith("run ")]

    def test_the_elevation_stage_builds_the_hybrid_only_for_a_terrain_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            plain, runs = self.run_elevation_stage(root, "BICINO_PLANET_DATE=261116\nBICINO_OPENING_RADIUS=400\n")
            self.assertEqual(plain.returncode, 0, plain.stdout + plain.stderr)
            self.assertEqual(len(runs), 1)
            self.assertNotIn("terrain", runs[0])
            self.assertFalse((root / "elevation-terrain").exists())
            hybrid, runs = self.run_elevation_stage(
                root, "BICINO_PLANET_DATE=261116\nBICINO_OPENING_RADIUS=400\nBICINO_TERRAIN=usgs-3dep-13\n")
            self.assertEqual(hybrid.returncode, 0, hybrid.stdout + hybrid.stderr)
            self.assertIn("terrain source usgs-3dep-13: 955 tiles", hybrid.stdout)
            self.assertIn(f"-v {root}/elevation-opened:/opened -v {root}/elevation-terrain:/terrain", runs[0])
            self.assertIn("/routing/build_elevation.py --raw /raw --out /out --opening-radius 400 "
                          "--terrain-sources /routing/elevation-sources.json --terrain /terrain --opened /opened "
                          "--jobs 20", runs[0])
            for manifest in ("elevation-raw/elevation-manifest.json", "elevation/elevation-manifest.json",
                             "elevation-opened/elevation-manifest.json", "elevation-terrain/terrain-manifest.json"):
                self.assertIn(f"sha256sum {root}/{manifest}", hybrid.stdout)
            # A terrain source the source list does not hold stops the stage before anything is built.
            unknown, runs = self.run_elevation_stage(
                root, "BICINO_PLANET_DATE=261116\nBICINO_OPENING_RADIUS=400\nBICINO_TERRAIN=other-dtm\n")
            self.assertEqual((unknown.returncode, runs), (1, []))
            self.assertIn("elevation-sources.json holds usgs-3dep-13, not BICINO_TERRAIN=other-dtm", unknown.stderr)

    def kept_tiles_scratch(self, directory, bucket="rehearsal-elevation"):
        """A scratch root whose tools hold a record of two small kept sets; returns it and the bucket's address."""
        root = Path(directory).resolve()
        routing = root / "tools" / "repo" / "map-platform" / "routing"
        (routing / "releases").mkdir(parents=True)
        for entry in ROUTING.iterdir():
            if entry.name != "releases":
                (routing / entry.name).symlink_to(entry)
        make_tile_set(root / "built" / "raw", ("N52E013", "N52E014"))
        make_tile_set(root / "built" / "opened", ("N52E013",), {"name": "grey-opening", "radiusMetres": 400.0}, b"opened")
        elevation_cache.pack(routing / "releases" / "elevation-cache-rehearsal.json", root / "bucket",
                             "rehearsal-elevation", "rehearsal",
                             [("raw", root / "built" / "raw"), ("opened-400", root / "built" / "opened")])
        server, endpoint = rehearse.serve_bucket(root / "bucket", bucket)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return root, endpoint

    KEPT_ENV = ("BICINO_SAMPLE_CITY=Berlin\n"
                "BICINO_SAMPLE_REGION_URL=https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf\n"
                "BICINO_OPENING_RADIUS=400\nBICINO_ELEVATION_CACHE=elevation-cache-rehearsal.json\n")

    def test_the_elevation_stage_restores_kept_tiles_before_it_builds(self):
        with tempfile.TemporaryDirectory() as directory:
            root, endpoint = self.kept_tiles_scratch(directory)
            ran, runs = self.run_elevation_stage(root, self.KEPT_ENV + f"BICINO_ELEVATION_CACHE_ENDPOINT={endpoint}\n")
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
            self.assertLess(ran.stdout.index("cache: every kept set is restored"), ran.stdout.index("attempt=1 start="))
            # build_elevation.py still runs: it finds a receipt for every restored cell.
            self.assertEqual(len(runs), 1)
            report = json.loads((root / "export" / "evidence" / "elevation-cache.json").read_text())
            self.assertEqual({name: (entry["restored"], entry["directory"]) for name, entry in report["sets"].items()},
                             {"raw": (True, f"{root}/elevation-raw"), "opened-400": (True, f"{root}/elevation")})
            self.assertEqual(files_of(root / "elevation-raw" / "N52"), files_of(root / "built" / "raw" / "N52"))
            # The stand-in build wrote the manifests again and left the tiles alone.
            self.assertIn("raw: the tiles are the recorded ones; the build wrote the manifest again", ran.stdout)
            self.assertEqual((report["sets"]["raw"]["tilesAsRecorded"], report["sets"]["raw"]["manifestAsRecorded"]),
                             (True, False))
            # A run without a record keeps neither an earlier run's report nor what a killed restore left.
            for name in ("elevation-raw", "elevation", "elevation-opened"):
                (root / f"{name}.restoring" / "N52").mkdir(parents=True)
            plain, _ = self.run_elevation_stage(root, self.KEPT_ENV.replace("BICINO_ELEVATION_CACHE=elevation-cache-rehearsal.json\n", ""))
            self.assertEqual(plain.returncode, 0, plain.stdout + plain.stderr)
            self.assertNotIn("cache:", plain.stdout)
            self.assertFalse((root / "export" / "evidence" / "elevation-cache.json").exists())
            self.assertEqual(sorted(path.name for path in root.glob("*.restoring")), [])
        with tempfile.TemporaryDirectory() as directory:
            # Under a terrain source the opened tiles lie beside the hybrid, which is always built.
            root, endpoint = self.kept_tiles_scratch(directory)
            ran, runs = self.run_elevation_stage(root, self.KEPT_ENV + "BICINO_TERRAIN=usgs-3dep-13\n"
                                                 f"BICINO_ELEVATION_CACHE_ENDPOINT={endpoint}\n")
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
            self.assertTrue((root / "elevation-opened" / "N52" / "N52E013.hgt.gz").exists())
            self.assertFalse((root / "elevation" / "N52").exists())
            # What a restore for a run without the terrain source left beside elevation/ is not this run's.
            (root / "elevation.restoring" / "N52").mkdir(parents=True)
            (root / "elevation-opened.restoring").mkdir()
            again, _ = self.run_elevation_stage(root, self.KEPT_ENV + "BICINO_TERRAIN=usgs-3dep-13\n"
                                                f"BICINO_ELEVATION_CACHE_ENDPOINT={endpoint}\n")
            self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
            self.assertFalse((root / "elevation.restoring").exists())
            self.assertFalse((root / "elevation" / "restore.json").exists())

    def test_the_elevation_stage_builds_the_tiles_it_cannot_restore(self):
        with tempfile.TemporaryDirectory() as directory:
            # The address serves another bucket: every object is missing.
            root, endpoint = self.kept_tiles_scratch(directory, bucket="another-bucket")
            env = self.KEPT_ENV + f"BICINO_ELEVATION_CACHE_ENDPOINT={endpoint}\n"
            ran, runs = self.run_elevation_stage(root, env)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
            self.assertIn("cache: restore exit=3; building the tiles that were not restored", ran.stdout)
            self.assertEqual(len(runs), 1)
            report_path = root / "export" / "evidence" / "elevation-cache.json"
            report = json.loads(report_path.read_text())
            self.assertEqual([entry["restored"] for entry in report["sets"].values()], [False, False])
            self.assertIn("the bucket holds no rehearsal/raw-", report["sets"]["raw"]["reason"])
            # Nothing of the record reached the directories the build then wrote to.
            for name in ("elevation-raw", "elevation"):
                self.assertEqual(sorted(path.name for path in (root / name).iterdir()), ["elevation-manifest.json"])
                self.assertFalse((root / f"{name}.restoring").exists())
            # A second attempt finds the built tiles, leaves them alone and keeps why they were built.
            server, good = rehearse.serve_bucket(root / "bucket", "rehearsal-elevation")
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            again, _ = self.run_elevation_stage(root, env.replace(endpoint, good))
            self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
            self.assertIn("the bucket holds no rehearsal/raw-", json.loads(report_path.read_text())["sets"]["raw"]["reason"])
            self.assertEqual(sorted(path.name for path in (root / "elevation-raw").iterdir()), ["elevation-manifest.json"])

    def test_a_terrain_source_marks_every_bridge_in_both_builds_and_the_gate_checks_it(self):
        build = (BUILDER / "stages" / "build.sh").read_text()
        rule = build.index("if bicino_is_hybrid; then\n  arguments+=(--all-bridges)\nfi")
        # After the label's own arguments, for ungraded and graded alike, and before the build runs.
        self.assertLess(build.index('*) bicino_fail "usage: build.sh ungraded|graded" ;;'), rule)
        self.assertLess(rule, build.index('python3 "$BICINO_ROUTING/build_graph.py"'))
        gate = (BUILDER / "stages" / "gate.sh").read_text()
        check = gate[gate.index("python3 - \"$BICINO_BUILD/planet-ungraded/manifest.json\""):gate.index("mkdir -p \"$out\"")]
        script = check[check.index("<<'PY'\n") + 6:check.index("\nPY\n")]
        with tempfile.TemporaryDirectory() as directory:
            manifests = []
            for name, rules in (("plain", None), ("bridges", {"sha256": "abc"}), ("bridges-too", {"sha256": "abc"})):
                path = Path(directory) / f"{name}.json"
                path.write_text(json.dumps({"builder": {"graphLua": rules}}))
                manifests.append(str(path))
            same = subprocess.run([sys.executable, "-", manifests[1], manifests[2]], input=script, capture_output=True, text=True)
            self.assertEqual(same.returncode, 0, same.stderr)
            mixed = subprocess.run([sys.executable, "-", manifests[0], manifests[1]], input=script, capture_output=True, text=True)
            self.assertNotEqual(mixed.returncode, 0)
            self.assertIn("different tagging rules", mixed.stderr)

    def test_setup_and_the_rehearsal_pass_the_terrain_source_on(self):
        setup = (BUILDER / "setup.sh").read_text()
        self.assertIn('--terrain) terrain=${2:-}; shift 2 ;;', setup)
        self.assertIn('[[ -z "$terrain" || -n "$opening_radius" ]] || fail "--terrain needs --opening-radius"', setup)
        self.assertIn('echo "BICINO_TERRAIN=$terrain"', setup)
        self.assertIn('--elevation-cache) cache=${2:-}; shift 2 ;;', setup)
        self.assertIn('[[ -z "$cache" || -n "$opening_radius" ]] || fail "--elevation-cache needs --opening-radius"', setup)
        self.assertIn('echo "BICINO_ELEVATION_CACHE=$cache"', setup)
        with tempfile.TemporaryDirectory() as directory:
            rehearse.write_env(Path(directory), "Chicago", "https://example/illinois.osm.pbf", 400, None, 4, 4,
                               "usgs-3dep-13")
            self.assertIn("BICINO_TERRAIN=usgs-3dep-13\n", (Path(directory) / "builder.env").read_text())
            rehearse.write_env(Path(directory), "Berlin", "https://example/berlin.osm.pbf", 200, None, 4, 4)
            self.assertIn("BICINO_TERRAIN=\nBICINO_ELEVATION_CACHE=\nBICINO_ELEVATION_CACHE_ENDPOINT=\n",
                          (Path(directory) / "builder.env").read_text())
            rehearse.write_env(Path(directory), "Berlin", "https://example/berlin.osm.pbf", 200, None, 4, 4,
                               cache="elevation-cache-rehearsal.json", endpoint="http://127.0.0.1:8123")
            self.assertIn("BICINO_ELEVATION_CACHE=elevation-cache-rehearsal.json\n"
                          "BICINO_ELEVATION_CACHE_ENDPOINT=http://127.0.0.1:8123\n",
                          (Path(directory) / "builder.env").read_text())

    def test_setup_masks_package_upgrades_before_it_installs_anything(self):
        setup = (BUILDER / "setup.sh").read_text()
        mask = setup.index("systemctl mask --now apt-daily.timer apt-daily-upgrade.timer")
        self.assertLess(mask, setup.index("apt-get"))
        self.assertLess(mask, setup.index("install-chain.sh"))
        self.assertIn("apt-daily.service apt-daily-upgrade.service unattended-upgrades.service", setup)
        self.assertIn("$nrconf{restart} = 'l';", setup)
        self.assertIn("is not masked", (BUILDER / "install-chain.sh").read_text())


class CloudScriptTests(unittest.TestCase):
    """provision.sh and teardown.sh against a gcloud that only records its calls."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.calls = self.directory / "calls.txt"
        gcloud = self.directory / "gcloud"
        gcloud.write_text(f'#!/bin/bash\necho "$*" >> "{self.calls}"\n'
                          f'case "$*" in *" list "*) cat "{self.directory}/left" 2>/dev/null; exit "${{LIST_STATUS:-0}}";;\n'
                          f'  *"service-accounts describe"*) exit "${{ACCOUNT_MISSING:-1}}";;\n'
                          f'  *add-iam-policy-binding*) exit "${{GRANT_STATUS:-0}}";; esac\n')
        gcloud.chmod(0o755)
        self.key = self.directory / "job.pub"
        self.key.write_text("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHh6X2Lu1ulBCwpzdwyYyqDhKH0LWrDbC6i7LmmQVY8m job\n")

    def run_script(self, script, *arguments, **environment):
        return subprocess.run([str(BUILDER / script), *arguments], capture_output=True, text=True,
                              env={"PATH": f"{self.directory}:/usr/bin:/bin", **environment})

    def gcloud_calls(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def test_the_plan_creates_nothing(self):
        planned = self.run_script("provision.sh", "--job", "r400-261116", "--ssh-source", "203.0.113.7/32",
                                  "--ssh-key", str(self.key))
        self.assertEqual(planned.returncode, 0, planned.stderr)
        self.assertEqual(self.gcloud_calls(), [])
        self.assertIn("plan only: nothing was created", planned.stdout)
        self.assertEqual(planned.stdout.count("+ gcloud compute"), 4)
        deleted = self.run_script("teardown.sh", "--job", "r400-261116")
        self.assertEqual((deleted.returncode, self.gcloud_calls()), (0, []))
        self.assertIn("plan only: nothing was deleted", deleted.stdout)

    def test_the_builder_is_alone_short_lived_and_holds_no_credentials(self):
        created = self.run_script("provision.sh", "--job", "r400-261116", "--ssh-source", "203.0.113.7/32",
                                  "--ssh-key", str(self.key), "--create")
        self.assertEqual(created.returncode, 0, created.stderr)
        network, subnet, firewall, instance, _describe = self.gcloud_calls()
        name = "bicino-valhalla-r400-261116"
        self.assertTrue(network.startswith(f"compute networks create {name} "))
        self.assertIn(f"--network={name}", subnet)
        self.assertIn("--allow=tcp:22 --source-ranges=203.0.113.7/32", firewall)
        for flag in (f"--subnet={name}", "--machine-type=c4-highmem-24-lssd", "--max-run-duration=24h",
                     "--instance-termination-action=DELETE", "--no-service-account", "--no-scopes",
                     "--image-family=ubuntu-2404-lts-amd64", "--metadata=ssh-keys=bicino:ssh-ed25519 "):
            self.assertIn(flag, instance)

    def test_a_builder_that_restores_kept_tiles_may_read_storage_and_nothing_else(self):
        reader = "bicino-routing-builder@chiho-prod.iam.gserviceaccount.com"
        created = self.run_script("provision.sh", "--job", "r400-261116", "--ssh-source", "203.0.113.7/32",
                                  "--ssh-key", str(self.key), "--cache-reader", reader, "--create")
        self.assertEqual(created.returncode, 0, created.stderr)
        instance = self.gcloud_calls()[3]
        self.assertIn(f"--service-account={reader} --scopes=https://www.googleapis.com/auth/devstorage.read_only ", instance)
        self.assertNotIn("--no-service-account", instance)
        self.assertEqual(instance.count("--scopes"), 1)
        self.calls.unlink()
        for bad in ("default", "someone@gmail.com", f"{reader} --scopes=cloud-platform"):
            refused = self.run_script("provision.sh", "--job", "r400", "--ssh-source", "203.0.113.7/32",
                                      "--ssh-key", str(self.key), "--cache-reader", bad, "--create")
            self.assertEqual(refused.returncode, 1, bad)
        self.assertEqual(self.gcloud_calls(), [])

    def test_bucket_access_is_one_keyless_account_that_reads_one_bucket(self):
        planned = self.run_script("cache-access.sh")
        self.assertEqual((planned.returncode, self.gcloud_calls()), (0, []))
        self.assertIn("plan only: nothing was created", planned.stdout)
        created = self.run_script("cache-access.sh", "--create")
        self.assertEqual(created.returncode, 0, created.stderr)
        asked, account, grant = self.gcloud_calls()
        self.assertTrue(asked.startswith("iam service-accounts describe bicino-routing-builder@chiho-prod.iam.gserviceaccount.com "))
        self.assertTrue(account.startswith("iam service-accounts create bicino-routing-builder --project chiho-prod "))
        self.assertTrue(grant.startswith("storage buckets add-iam-policy-binding gs://bicino-routing-elevation "))
        self.assertIn("--member=serviceAccount:bicino-routing-builder@chiho-prod.iam.gserviceaccount.com "
                      "--role=roles/storage.objectViewer", grant)
        text = (BUILDER / "cache-access.sh").read_text()
        for never in ("keys create", "projects add-iam-policy-binding", "objectAdmin", "objectCreator"):
            self.assertNotIn(never, text)
        self.assertIn("--cache-reader bicino-routing-builder@chiho-prod.iam.gserviceaccount.com", created.stdout)
        # A grant that fails says to run it again, and a second run keeps the account and makes the grant.
        self.calls.unlink()
        failed = self.run_script("cache-access.sh", "--create", GRANT_STATUS="1")
        self.assertEqual(failed.returncode, 1)
        self.assertIn("run cache-access.sh --create again", failed.stderr)
        self.calls.unlink()
        again = self.run_script("cache-access.sh", "--create", ACCOUNT_MISSING="0")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual([call.split(" --project")[0].split(" gs://")[0] for call in self.gcloud_calls()],
                         ["iam service-accounts describe bicino-routing-builder@chiho-prod.iam.gserviceaccount.com",
                          "storage buckets add-iam-policy-binding"])
        self.assertIn("exists already", again.stdout)
        self.calls.unlink()
        self.assertEqual(self.run_script("cache-access.sh", "--account", "x", "--create").returncode, 1)
        self.assertEqual(self.gcloud_calls(), [])

    def test_bad_arguments_stop_before_gcloud(self):
        cases = [["--job", "R400", "--ssh-source", "203.0.113.7/32", "--ssh-key", str(self.key)],
                 ["--job", "r400", "--ssh-source", "0.0.0.0/0", "--ssh-key", str(self.key)],
                 ["--job", "r400", "--ssh-source", "203.0.113.7/32", "--ssh-key", str(self.directory / "missing")]]
        (self.directory / "rsa.pub").write_text("ssh-rsa AAAA job\n")
        cases.append(["--job", "r400", "--ssh-source", "203.0.113.7/32", "--ssh-key", str(self.directory / "rsa.pub")])
        for arguments in cases:
            self.assertEqual(self.run_script("provision.sh", *arguments, "--create").returncode, 1, arguments)
        self.assertEqual(self.gcloud_calls(), [])

    def test_teardown_deletes_in_order_and_fails_while_anything_is_left(self):
        gone = self.run_script("teardown.sh", "--job", "r400-261116", "--delete")
        self.assertEqual(gone.returncode, 0, gone.stderr)
        deletes = [call.split(" --project")[0] for call in self.gcloud_calls() if " delete " in call]
        name = "bicino-valhalla-r400-261116"
        self.assertEqual(deletes, [f"compute instances delete {name}", f"compute firewall-rules delete {name}-ssh",
                                   f"compute networks subnets delete {name}", f"compute networks delete {name}"])
        (self.directory / "left").write_text(f"{name}\n")
        left = self.run_script("teardown.sh", "--job", "r400-261116", "--delete")
        self.assertEqual(left.returncode, 1)
        self.assertIn(f"instance {name}", left.stderr)
        # A listing that fails proves nothing.
        (self.directory / "left").unlink()
        unknown = self.run_script("teardown.sh", "--job", "r400-261116", "--delete", LIST_STATUS="1")
        self.assertEqual(unknown.returncode, 1)
        self.assertIn("could not list", unknown.stderr)
        self.assertNotIn("are gone", unknown.stdout)


class SampleTests(unittest.TestCase):
    CITIES = json.loads((ROUTING / "elevation-probes.json").read_text())

    def city(self, name):
        return next(city for city in self.CITIES if city["city"] == name)

    def test_bounds_hold_every_cell_the_box_touches(self):
        self.assertEqual(prepare_sample.elevation_bounds(self.city("Berlin")["bbox"]), [13, 52, 14, 53])
        self.assertEqual(prepare_sample.elevation_bounds(self.city("Buenos Aires")["bbox"]), [-59, -35, -58, -34])
        self.assertEqual(prepare_sample.elevation_bounds(self.city("New York")["bbox"]), [-75, 40, -73, 41])
        self.assertEqual(prepare_sample.elevation_bounds([4.0, 52.0, 5.0, 53.0]), [4, 52, 6, 54])

    def test_a_city_is_cut_only_from_its_own_extract(self):
        chicago = {"city": "Chicago", "extract": "north-america/us/illinois"}
        latest = "https://download.geofabrik.de/north-america/us/illinois-latest.osm.pbf"
        dated = "https://download.geofabrik.de/north-america/us/illinois/illinois-261124.osm.pbf"
        self.assertEqual((prepare_sample.region_url(chicago), prepare_sample.region_url(chicago, "261124")), (latest, dated))
        for url in (latest, dated, dated.replace("261124", "latest")):
            prepare_sample.check_region_url(chicago, url)
        for url in (latest.replace("illinois", "indiana"), latest.replace("https://download.geofabrik.de", "http://example.org"),
                    dated.replace("261124", "2611"), latest + ".md5"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                prepare_sample.check_region_url(chicago, url)

    def test_a_city_without_an_extract_is_not_a_sample(self):
        with self.assertRaisesRegex(ValueError, "not been built as a sample"):
            prepare_sample.find_city([{"city": "Tokyo", "planetOnly": True}], "Tokyo")
        with self.assertRaisesRegex(ValueError, "Unknown city"):
            prepare_sample.find_city(self.CITIES, "Atlantis")

    def test_the_sample_is_the_box_with_the_regions_boundaries(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "sample"
            region = Path(directory) / "new-york-latest.osm.pbf"
            region.write_bytes(b"region")
            commands = []

            def fake_run(*command):
                commands.append([str(part) for part in command])
                Path(command[command.index("-o") + 1]).write_bytes(command[1].encode())

            city = self.city("New York")
            url = prepare_sample.region_url(city)
            sample = prepare_sample.prepare(city, region, url, out, run=fake_run, fetch=lambda url: url.encode())
            self.assertEqual(commands[0][:6], ["osmium", "extract", "-b", "-74.05,40.65,-73.9,40.8", "--strategy", "complete_ways"])
            self.assertEqual(commands[1][:4], ["osmium", "tags-filter", str(region), "r/boundary=administrative"])
            # The extract lacks one way of New York State's boundary and cuts
            # the United States relation. Both come from the API, sorted.
            api = "https://api.openstreetmap.org/api/0.6/"
            self.assertEqual((out / "way-29307896.osm").read_bytes(), f"{api}way/29307896/full".encode())
            self.assertEqual((out / "relation-148838.osm").read_bytes(), f"{api}relation/148838/full".encode())
            fetched = [str(out / "way-29307896.osm.pbf"), str(out / "relation-148838.osm.pbf")]
            self.assertEqual([command[:2] + command[3:5] for command in commands[2:4]],
                             [["osmium", "sort", "-o", name] for name in fetched])
            patch, kept = str(out / "admin-patch.osm.pbf"), str(out / "admin-kept.osm.pbf")
            self.assertEqual(commands[4], ["osmium", "merge", *fetched, "-o", patch, "--overwrite"])
            # The extract's older copies of those objects go, then the two are merged.
            self.assertEqual(commands[5], ["osmium", "removeid", str(out / "admin-region.osm.pbf"), "-I", patch,
                                           "-o", kept, "--overwrite"])
            self.assertEqual(commands[6], ["osmium", "merge", kept, patch, "-o", str(out / "admin.osm.pbf"), "--overwrite"])
            self.assertEqual(json.loads((out / "sample.json").read_text()), sample)
            self.assertEqual((sample["elevationBounds"], sample["region"]["url"]), ([-75, 40, -73, 41], url))
            self.assertEqual((sample["adminWays"], sample["adminRelations"]), ([29307896], [148838]))
            probes = json.loads((out / "probes.json").read_text())
            self.assertEqual(len(probes), len(city["legs"]))
            self.assertEqual(probes[0]["points"], [city["legs"][0]["origin"], city["legs"][0]["destination"]])
            with self.assertRaises(ValueError):
                prepare_sample.prepare(city, region, url.replace("new-york", "new-jersey"), out, run=fake_run)
            # A city whose extract holds its whole country needs nothing from the API.
            del commands[:]
            whole = dict(self.city("Singapore"))
            prepare_sample.prepare(whole, region, prepare_sample.region_url(whole), out, run=fake_run, fetch=self.fail)
            self.assertEqual([command[1] for command in commands], ["extract", "tags-filter"])
            self.assertEqual(commands[1][commands[1].index("-o") + 1], str(out / "admin.osm.pbf"))

    def test_every_city_is_a_sample_or_planet_only(self):
        for city in self.CITIES:
            self.assertNotEqual(bool(city.get("planetOnly")), bool(city.get("extract")), city["city"])
            if city.get("extract"):
                self.assertRegex(city["extract"], r"^[a-z-]+(/[a-z-]+)+$")
                prepare_sample.check_region_url(city, prepare_sample.region_url(city))
                self.assertEqual(len(prepare_sample.smoke_probes(city)), len(city["legs"]))
            for key in ("adminWays", "adminRelations"):
                self.assertTrue(all(isinstance(number, int) for number in city.get(key, [])))
                self.assertTrue(city.get("extract") or key not in city, city["city"])
            # builder.env takes plain values only; a city's name goes into it as it is.
            self.assertRegex(city["city"], r"^[A-Za-z0-9_.:/@+, -]+$")
        # Every sample city in the United States carries the country's relation.
        united_states = {city["city"] for city in self.CITIES if 148838 in city.get("adminRelations", [])}
        self.assertEqual(united_states, {"New York", "Chicago", "Houston", "San Francisco"})

    def test_a_sample_build_takes_boundaries_from_the_region_and_skips_the_relation_check(self):
        commands = []
        with patch.object(build_graph, "run", lambda *command: commands.append([str(part) for part in command])):
            build_graph.prepare_inputs(Path("/in/box.osm.pbf"), Path("/work"), None, Path("/in/region.osm.pbf"), sample=True)
            sample, commands[:] = list(commands), []
            build_graph.prepare_inputs(Path("/in/planet.osm.pbf"), Path("/work"), None)
        self.assertEqual(sample[0][:3], ["osmium", "tags-filter", "/in/region.osm.pbf"])
        self.assertIn(["osmium", "check-refs", "/in/box.osm.pbf"], sample)
        self.assertFalse(any("--check-relations" in command for command in sample))
        self.assertEqual(commands[0][:3], ["osmium", "tags-filter", "/in/planet.osm.pbf"])
        self.assertTrue(any("--check-relations" in command for command in commands))

    def test_the_build_container_is_labelled_with_its_work_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            with patch.object(build_graph.subprocess, "run") as run:
                build_graph.run_valhalla(work, "true", 4, "valhalla-build.log", [])
            command = run.call_args.args[0]
            self.assertEqual(command[command.index("--label") + 1], f"bicino.work={work}")


class ElevationCacheTests(unittest.TestCase):
    """Restoring kept elevation tiles, from a stand-in for the bucket."""

    CELLS = ("N52E013", "N52E014", "N53E013", "S01W001", "S10E120")
    BUCKET = "test-elevation"

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.built = {"raw": self.root / "built" / "raw", "opened-400": self.root / "built" / "opened"}
        make_tile_set(self.built["raw"], self.CELLS)
        make_tile_set(self.built["opened-400"], self.CELLS, {"name": "grey-opening", "radiusMetres": 400.0}, b"opened")
        self.bucket = self.root / "bucket"
        self.record = self.root / "elevation-cache-test.json"
        elevation_cache.pack(self.record, self.bucket, self.BUCKET, "family", list(self.built.items()))
        self.raw = self.root / "scratch" / "elevation-raw"
        self.opened = self.root / "scratch" / "elevation"
        self.report = self.root / "scratch" / "export" / "evidence" / "elevation-cache.json"
        # What the stand-in was asked: (set/tar, Range, Authorization). `refuse` and `cut` make it misbehave.
        self.requests, self.refuse, self.cut, self.lines = [], {}, {}, []
        test = self

        class Bucket(rehearse.BucketHandler):
            def key(self):
                name = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
                return f"{name.split('/')[-2].rpartition('-')[0]}/{name.split('/')[-1]}"

            def do_GET(self):
                test.requests.append((self.key(), self.headers.get("Range"), self.headers.get("Authorization")))
                if self.key() in test.refuse:
                    self.send_error(test.refuse[self.key()])
                else:
                    super().do_GET()

            def send_body(self, stream):
                # Send only the first bytes once, as a connection that drops.
                self.wfile.write(stream.read(test.cut.pop(self.key()))) if self.key() in test.cut else super().send_body(stream)

        server, self.endpoint = rehearse.serve_bucket(self.bucket, self.BUCKET, Bucket)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        pause = patch.object(elevation_cache.time, "sleep", lambda seconds: None)
        pause.start()
        self.addCleanup(pause.stop)

    def restore(self, wanted=None, jobs=1):
        return elevation_cache.restore(self.record, wanted or [("raw", self.raw, True)], self.report,
                                       endpoint=self.endpoint, jobs=jobs, log=self.lines.append)

    def reason(self, name="raw", directory=None):
        """Why the set was not restored; nothing of it may be left on disk."""
        directory = directory or self.raw
        report = self.restore([(name, directory, True)])
        self.assertFalse(report["sets"][name]["restored"])
        self.assertEqual(elevation_cache.failed_sets(report), [name])
        self.assertFalse(directory.exists() and any(directory.iterdir()))
        self.assertFalse(elevation_cache.staging_of(directory).exists())
        return report["sets"][name]["reason"]

    def tar_path(self, set_name, shard):
        return self.bucket / json.loads(self.record.read_text())["sets"][set_name]["prefix"] / shard

    def repack(self, set_name, shard, change, count=False):
        """Rewrite one tar in the bucket and pin the record to the new bytes, as a bucket that lies would hold it."""
        path = self.tar_path(set_name, shard)
        with tarfile.open(path) as archive:
            members = {member.name: archive.extractfile(member).read() for member in archive}
        others = change(members) or []
        with tarfile.open(path, "w", format=tarfile.GNU_FORMAT) as archive:
            for name, data in members.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            for info in others:
                archive.addfile(info)
        record = json.loads(self.record.read_text())
        entry = next(entry for entry in record["sets"][set_name]["shards"] if entry["name"] == shard)
        entry.update(bytes=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        if count:
            entry["files"] = len(members)
        self.record.write_text(json.dumps(record))

    def test_a_restored_set_is_the_built_set_file_for_file(self):
        report = self.restore([("raw", self.raw, True), ("opened-400", self.opened, False),
                               ("opened-200", self.root / "scratch" / "other", False)], jobs=2)
        self.assertEqual(elevation_cache.failed_sets(report), [])
        for name, directory in (("raw", self.raw), ("opened-400", self.opened)):
            restored = files_of(directory)
            receipt = json.loads(restored.pop("restore.json"))
            self.assertEqual(restored, files_of(self.built[name]))
            self.assertFalse(elevation_cache.staging_of(directory).exists())
            entry = json.loads(self.record.read_text())["sets"][name]
            self.assertEqual((receipt["manifestSha256"], receipt["cellListSha256"], receipt["cells"], receipt["record"]),
                             (entry["manifestSha256"], entry["cellListSha256"], 5, "elevation-cache-test.json"))
            self.assertEqual(report["sets"][name]["directory"], str(directory))
        # A set the record does not keep is no failure: it is built.
        self.assertEqual((report["sets"]["opened-200"]["restored"], report["sets"]["opened-200"]["kept"]), (False, False))
        self.assertFalse((self.root / "scratch" / "other").exists())
        self.assertEqual(json.loads(self.report.read_text()), report)
        # Four tars a set: its bands and meta.tar. The stand-in is not Google and got no token.
        self.assertEqual(sorted(key for key, _, _ in self.requests),
                         sorted(f"{name}/{tar}" for name in ("raw", "opened-400")
                                for tar in ("N5.tar", "S0.tar", "S1.tar", "meta.tar")))
        self.assertEqual({token for _, _, token in self.requests}, {None})
        # A second run finds the receipts and asks the bucket for nothing.
        self.requests.clear()
        again = self.restore([("raw", self.raw, True), ("opened-400", self.opened, False)])
        self.assertEqual(([entry["restored"] for entry in again["sets"].values()], self.requests), ([True, True], []))

    def test_a_tar_that_is_not_the_pinned_file_is_refused(self):
        path = self.tar_path("raw", "N5.tar")
        data = bytearray(path.read_bytes())
        data[700] ^= 1
        path.write_bytes(data)
        self.assertRegex(self.reason(), r"N5\.tar is not the pinned file: SHA-256 [0-9a-f]{64}, the record has")
        path.write_bytes(bytes(data) + b"\0" * 512)
        self.assertIn("N5.tar is longer than its pinned", self.reason())
        path.write_bytes(bytes(data)[:-1024])
        self.assertIn("N5.tar: the transfer ended at byte", self.reason())

    def test_a_tile_is_checked_against_the_cell_list_whatever_its_tar_claims(self):
        other = gzip.compress(b"heights of somewhere else", mtime=0)
        self.repack("raw", "N5.tar", lambda members: members.update({"N52/N52E014.hgt.gz": other}))
        self.assertIn("N5.tar: the tile N52E014 does not match its line in cells.txt", self.reason())
        self.repack("raw", "N5.tar", lambda members: members.update({"N52/N52E014.hgt.gz": b"not gzip at all"}))
        self.assertIn("N52E014 is not a gzipped tile", self.reason())
        twice = gzip.compress(b"x", mtime=0) * 2
        self.repack("raw", "N5.tar", lambda members: members.update({"N52/N52E014.hgt.gz": twice}))
        self.assertIn("N52E014 is not one gzipped tile", self.reason())

    def test_a_band_holds_its_own_tiles_once_and_nothing_else(self):
        tile = self.built["raw"] / "S01" / "S01W001.hgt.gz"
        link = tarfile.TarInfo("N52/N52E015.hgt.gz")
        link.type, link.linkname = tarfile.SYMTYPE, "/etc/passwd"
        cases = {
            "'N52/notes.txt' is not a tile of this band": lambda members: members.update({"N52/notes.txt": b"x"}),
            "'../N52E013.hgt.gz' is not a tile": lambda members: members.update({"../N52E013.hgt.gz": b"x"}),
            "'/tmp/N52/N52E013.hgt.gz' is not a tile": lambda members: members.update({"/tmp/N52/N52E013.hgt.gz": b"x"}),
            "'S01/S01W001.hgt.gz' is not a tile of this band": lambda members: members.update({"S01/S01W001.hgt.gz": tile.read_bytes()}),
            "'N52/N52E015.hgt.gz' is not a plain file": lambda members: [link],
            "N5.tar holds 2 tiles; the record has 3": lambda members: members.pop("N53/N53E013.hgt.gz") and None,
        }
        pristine = (self.tar_path("raw", "N5.tar").read_bytes(), self.record.read_text())
        for expected, change in cases.items():
            with self.subTest(expected=expected):
                self.tar_path("raw", "N5.tar").write_bytes(pristine[0])
                self.record.write_text(pristine[1])
                self.repack("raw", "N5.tar", change)
                self.assertIn(expected, self.reason())
        self.assertFalse((self.root / "scratch" / "N52E013.hgt.gz").exists())

    def test_the_manifest_the_cell_list_and_the_receipts_must_be_the_pinned_ones(self):
        pristine = (self.tar_path("raw", "meta.tar").read_bytes(), self.record.read_text())
        listing = (self.built["raw"] / "cells.txt").read_text()
        moved = listing.replace("N52E013 ", "N51E013 ")
        receipt = json.dumps({"cell": "N52E013", "hgtSha256": "0" * 64}).encode()
        cases = {
            "elevation-manifest.json is not the manifest the record pins":
                lambda members: members.update({"elevation-manifest.json": members["elevation-manifest.json"] + b" "}),
            "cells.txt does not hash to the cellListSha256": lambda members: members.update({"cells.txt": moved.encode()}),
            "the receipt of N52E013 does not name the tile cells.txt names":
                lambda members: members.update({"receipts/N52E013.json": receipt}),
            "1 cells have a receipt or a line in cells.txt, not both": lambda members: members.pop("receipts/S10E120.json") and None,
            "unexpected member 'receipts/../../escape.json'": lambda members: members.update({"receipts/../../escape.json": b"{}"}),
            "meta.tar holds no cells.txt": lambda members: members.pop("cells.txt") and None,
        }
        for expected, change in cases.items():
            with self.subTest(expected=expected):
                self.tar_path("raw", "meta.tar").write_bytes(pristine[0])
                self.record.write_text(pristine[1])
                self.repack("raw", "meta.tar", change, count=True)
                self.assertIn(expected, self.reason())
        # The record's word is what counts: a manifest that is whole but another one is refused.
        self.tar_path("raw", "meta.tar").write_bytes(pristine[0])
        record = json.loads(pristine[1])
        record["sets"]["raw"]["manifestSha256"] = "0" * 64
        self.record.write_text(json.dumps(record))
        self.assertIn("is not the manifest the record pins", self.reason())
        self.assertFalse((self.root / "escape.json").exists() or (self.root / "scratch" / "escape.json").exists())

    def test_a_transfer_that_drops_is_taken_up_where_it_stopped(self):
        self.cut["raw/N5.tar"] = 1000
        report = self.restore()
        self.assertTrue(report["sets"]["raw"]["restored"], self.lines)
        self.assertEqual([(key, wanted) for key, wanted, _ in self.requests if key == "raw/N5.tar"],
                         [("raw/N5.tar", None), ("raw/N5.tar", "bytes=1000-")])
        restored = files_of(self.raw)
        del restored["restore.json"]
        self.assertEqual(restored, files_of(self.built["raw"]))

    def test_a_bucket_that_refuses_says_what_the_builder_lacks(self):
        self.refuse["raw/meta.tar"] = 403
        self.assertIn("may not read family/raw-", self.reason())
        self.assertIn("roles/storage.objectViewer on the bucket", self.reason())
        self.refuse["raw/meta.tar"] = 404
        self.assertIn("the bucket holds no family/raw-", self.reason())
        # A server in trouble is asked again, six times in all, and then given up on.
        self.requests.clear()
        self.refuse["raw/meta.tar"] = 503
        self.assertIn("meta.tar: HTTP 503, after 6 attempts", self.reason())
        self.assertEqual(len(self.requests), 6)
        # The first request of a restore tells: nothing else was asked for.
        self.assertEqual({key for key, _, _ in self.requests}, {"raw/meta.tar"})

    def test_the_token_is_the_builders_own_and_goes_only_to_google(self):
        asked = []

        class Metadata(http.server.BaseHTTPRequestHandler):
            answer = (200, {"access_token": "t0ken", "expires_in": 3599, "token_type": "Bearer"})

            def do_GET(self):
                asked.append(self.headers.get("Metadata-Flavor"))
                status, body = type(self).answer
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *arguments):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Metadata)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        metadata = f"http://127.0.0.1:{server.server_address[1]}/token"
        token = elevation_cache.Token(metadata=metadata)
        self.assertEqual((token.header(), token.header()), ({"Authorization": "Bearer t0ken"},) * 2)
        self.assertEqual(asked, ["Google"])
        token.header(refresh=True)
        self.assertEqual(len(asked), 2)
        saved = self.root / "token"
        saved.write_text("from-a-laptop\n")
        self.assertEqual(elevation_cache.Token(token_file=saved).header(), {"Authorization": "Bearer from-a-laptop"})
        # Any other address gets no token, whatever this machine could give.
        self.assertEqual(elevation_cache.Token(self.endpoint, metadata=metadata).header(), {})
        self.assertEqual(elevation_cache.Token(self.endpoint, token_file=saved).header(), {})
        # A builder without a service account says how to get one.
        Metadata.answer = (404, {})
        with self.assertRaisesRegex(elevation_cache.CacheError, r"no service account.*provision\.sh --cache-reader"):
            elevation_cache.Token(metadata=metadata).header()
        with self.assertRaisesRegex(elevation_cache.CacheError, "gave no token"):
            elevation_cache.Token(metadata="http://127.0.0.1:9/token").header()

    def test_a_redirect_is_an_error_not_a_second_address(self):
        elsewhere = []

        class Redirect(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.startswith("/storage/"):
                    self.send_response(302)
                    self.send_header("Location", f"http://127.0.0.1:{self.server.server_address[1]}/elsewhere")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                else:
                    elsewhere.append(self.path)
                    self.send_error(500)

            def log_message(self, *arguments):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Redirect)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        url = elevation_cache.object_url(f"http://127.0.0.1:{server.server_address[1]}", self.BUCKET, "family/meta.tar")
        with self.assertRaisesRegex(elevation_cache.CacheError, "family/meta.tar: HTTP 302"):
            elevation_cache.fetch_object(url, elevation_cache.Token(self.endpoint), self.root / "download", 10, "0" * 64)
        self.assertEqual(elsewhere, [])

    def test_a_directory_that_holds_other_files_is_left_alone(self):
        self.raw.mkdir(parents=True)
        (self.raw / "N52").mkdir()
        (self.raw / "N52" / "N52E013.hgt.gz").write_bytes(b"a tile this build wrote")
        report = self.restore()
        self.assertIn("holds files that were not restored from this set; it is left alone", report["sets"]["raw"]["reason"])
        self.assertEqual(files_of(self.raw), {"N52/N52E013.hgt.gz": b"a tile this build wrote"})
        self.assertEqual(self.requests, [])
        # An empty directory, as setup.sh leaves it, is fine.
        self.opened.mkdir(parents=True)
        self.assertTrue(self.restore([("opened-400", self.opened, True)])["sets"]["opened-400"]["restored"])

    def test_restored_tiles_a_later_build_wrote_over_are_not_called_restored(self):
        self.assertTrue(self.restore()["sets"]["raw"]["restored"])
        # A build under other settings wrote its own tiles and cell list into the directory,
        # and its run reported on other sets.
        (self.raw / "cells.txt").write_text("N52E013 " + "0" * 64 + "\n")
        self.restore([("opened-400", self.opened, False)])
        self.requests.clear()
        report = self.restore()
        self.assertFalse(report["sets"]["raw"]["restored"])
        self.assertIn("holds files that were not restored from this set", report["sets"]["raw"]["reason"])
        self.assertEqual(self.requests, [])
        self.assertTrue((self.raw / "restore.json").exists())

    def test_a_second_attempt_keeps_that_the_set_was_restored_when_the_build_wrote_cells_again(self):
        first = self.restore()["sets"]["raw"]
        # A source had moved: this run's build wrote a cell again, and the stage is then run a second time.
        (self.raw / "cells.txt").write_text((self.raw / "cells.txt").read_text().replace("N52E013 ", "N52E013 0")[:-2] + "\n")
        elevation_cache.compare(self.report, log=self.lines.append)
        self.requests.clear()
        again = self.restore()["sets"]["raw"]
        self.assertEqual((again["restored"], again["restoredAt"], again["tilesAsRecorded"]), (True, first["restoredAt"], False))
        self.assertEqual(self.requests, [])
        self.assertIn("raw: restored by an earlier attempt; the build has written cells again since", self.lines)
        self.assertEqual(elevation_cache.failed_sets(self.restore()), [])
        # Tiles that were never restored there are not called restored on the word of an old report.
        (self.raw / "restore.json").unlink()
        self.assertFalse(self.restore()["sets"]["raw"]["restored"])

    def test_every_failure_is_reported_and_leaves_nothing_behind(self):
        # A fault of the tool itself is no reason to stop the build, and no secret either.
        with patch.object(elevation_cache, "restore_meta", side_effect=RuntimeError("a bug")), \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertIn("the restore tool failed: RuntimeError: a bug", self.reason())
        self.assertIn("Traceback", errors.getvalue())
        # A record that cannot be used: every set says so, and the bucket is not asked.
        self.requests.clear()
        usable = self.record.read_text()
        self.record.write_text(usable.replace("bicino-routing-elevation-cache-v1", "v0"))
        report = self.restore([("raw", self.raw, True), ("opened-400", self.opened, False)])
        self.assertEqual(elevation_cache.failed_sets(report), ["raw", "opened-400"])
        self.assertIn("is not a usable record: its schema is not", report["sets"]["opened-400"]["reason"])
        self.assertEqual(json.loads(self.report.read_text()), report)
        self.assertEqual(self.requests, [])
        # What an attempt at a set the record no longer keeps left beside its directory is removed.
        self.record.write_text(usable)
        left = elevation_cache.staging_of(self.opened)
        (left / "N52").mkdir(parents=True)
        report = self.restore([("opened-200", self.opened, False)])
        self.assertEqual((report["sets"]["opened-200"]["kept"], left.exists()), (False, False))

    def test_a_proxy_named_by_the_environment_is_not_used(self):
        # urllib reads the proxies when the tool starts, so this needs a process of its own.
        # Through this proxy nothing would arrive.
        environment = {key: value for key, value in os.environ.items() if key.lower() != "no_proxy"}
        environment.update(http_proxy="http://127.0.0.1:9", HTTP_PROXY="http://127.0.0.1:9", all_proxy="http://127.0.0.1:9")
        ran = subprocess.run([sys.executable, str(BUILDER / "elevation_cache.py"), "verify", "--record", str(self.record),
                              "--set", "raw", "--band", "S0.tar", "--work", str(self.root / "work"),
                              "--endpoint", self.endpoint], capture_output=True, text=True, env=environment, timeout=60)
        self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
        self.assertIn("meta.tar, S0.tar of gs://test-elevation/family/raw-", ran.stdout)

    def test_a_killed_restore_keeps_its_finished_bands_and_no_others(self):
        record = elevation_cache.load_record(self.record)
        self.refuse["raw/S1.tar"] = 403
        with self.assertRaises(elevation_cache.CacheError):
            # restore_set alone leaves what it assembled, as a kill does.
            elevation_cache.restore_set(record, "raw", self.raw, endpoint=self.endpoint, jobs=1, log=self.lines.append)
        staging = elevation_cache.staging_of(self.raw)
        self.assertTrue((staging / "N52" / "N52E013.hgt.gz").exists())
        (staging / "S10").mkdir()
        (staging / "S10" / "S10E120.hgt.gz.partial").write_bytes(b"half a tile")
        self.assertFalse(self.raw.exists())
        self.refuse.clear()
        self.requests.clear()
        self.assertTrue(self.restore()["sets"]["raw"]["restored"])
        self.assertEqual([key for key, _, _ in self.requests], ["raw/meta.tar", "raw/S1.tar"])
        restored = files_of(self.raw)
        del restored["restore.json"]
        self.assertEqual(restored, files_of(self.built["raw"]))
        # A finished band that has since lost a tile is not moved into place.
        with self.assertRaises(elevation_cache.CacheError):
            self.refuse["opened-400/S1.tar"] = 403
            elevation_cache.restore_set(record, "opened-400", self.opened, endpoint=self.endpoint, jobs=1,
                                        log=self.lines.append)
        self.refuse.clear()
        (elevation_cache.staging_of(self.opened) / "N52" / "N52E014.hgt.gz").unlink()
        report = self.restore([("opened-400", self.opened, True)])
        self.assertIn("opened-400: 1 cells are missing and 0 are extra", report["sets"]["opened-400"]["reason"])
        self.assertFalse(self.opened.exists() or elevation_cache.staging_of(self.opened).exists())
        # What an attempt at another set left is not built on.
        other = self.root / "scratch" / "other"
        left = elevation_cache.staging_of(other) / ".shards"
        left.mkdir(parents=True)
        (left / "state.json").write_text(json.dumps({"set": "raw", "manifestSha256": "0" * 64, "cellListSha256": "0" * 64}))
        (left / "N5.tar.done").write_text(json.dumps({"sha256": record.sets["raw"]["shards"][0]["sha256"]}))
        self.requests.clear()
        self.assertTrue(self.restore([("raw", other, True)])["sets"]["raw"]["restored"])
        self.assertEqual(len(self.requests), 4)

    def test_after_the_build_the_report_says_whether_the_tiles_are_still_the_recorded_ones(self):
        self.restore()
        entry = elevation_cache.compare(self.report, log=self.lines.append)["sets"]["raw"]
        self.assertEqual((entry["tilesAsRecorded"], entry["manifestAsRecorded"]), (True, True))
        # The build writes the manifest again; with another runtime it is other bytes over the same tiles.
        manifest = self.raw / "elevation-manifest.json"
        manifest.write_text(manifest.read_text().replace("1.4.4", "1.5.0"))
        entry = elevation_cache.compare(self.report, log=self.lines.append)["sets"]["raw"]
        self.assertEqual((entry["tilesAsRecorded"], entry["manifestAsRecorded"]), (True, False))
        self.assertIn("raw: the tiles are the recorded ones; the build wrote the manifest again", self.lines[-1])
        # A source that moved makes the build write cells again.
        (self.raw / "cells.txt").write_text("N52E013 " + "0" * 64 + "\n")
        entry = elevation_cache.compare(self.report, log=self.lines.append)["sets"]["raw"]
        self.assertIs(entry["tilesAsRecorded"], False)
        self.assertIn("the tiles are no longer the ones elevation-cache-test.json pins", self.lines[-1])
        self.assertIs(json.loads(self.report.read_text())["sets"]["raw"]["tilesAsRecorded"], False)

    def test_verify_checks_the_bucket_and_keeps_nothing(self):
        work = self.root / "work"
        elevation_cache.verify(self.record, "raw", work, endpoint=self.endpoint, jobs=1, log=self.lines.append)
        self.assertIn("every tar of gs://test-elevation/family/raw-", self.lines[-1])
        elevation_cache.verify(self.record, "raw", work, only=["S0.tar"], endpoint=self.endpoint, log=self.lines.append)
        self.assertEqual([key for key, _, _ in self.requests[-2:]], ["raw/meta.tar", "raw/S0.tar"])
        self.assertEqual(list(work.iterdir()), [])
        with self.assertRaisesRegex(elevation_cache.CacheError, "no band tar N9.tar"):
            elevation_cache.verify(self.record, "raw", work, only=["N9.tar"], endpoint=self.endpoint, log=self.lines.append)
        path = self.tar_path("raw", "S0.tar")
        path.write_bytes(path.read_bytes()[:-1] + b"x")
        with self.assertRaisesRegex(elevation_cache.CacheError, "S0.tar is not the pinned file"):
            elevation_cache.verify(self.record, "raw", work, endpoint=self.endpoint, jobs=1, log=self.lines.append)
        self.assertEqual(list(work.iterdir()), [])

    def test_a_record_must_be_whole_to_be_used(self):
        pristine = json.loads(self.record.read_text())
        self.assertEqual(elevation_cache.record_problems(pristine), [])

        def broken(change):
            record = json.loads(json.dumps(pristine))
            change(record)
            self.record.write_text(json.dumps(record))
            with self.assertRaises(elevation_cache.CacheError) as raised:
                elevation_cache.load_record(self.record)
            return str(raised.exception)

        raw = lambda record: record["sets"]["raw"]  # noqa: E731
        self.assertIn("schema", broken(lambda record: record.update(schema="other")))
        self.assertIn("bucket", broken(lambda record: record.update(bucket="gs://Bucket/")))
        self.assertIn("holds no sets", broken(lambda record: record.update(sets={})))
        self.assertIn("prefix", broken(lambda record: raw(record).update(prefix="../other")))
        self.assertIn("manifestSha256", broken(lambda record: raw(record).pop("manifestSha256")))
        self.assertIn("one meta.tar", broken(lambda record: raw(record)["shards"].pop()))
        self.assertIn("neither meta.tar nor a band", broken(lambda record: raw(record)["shards"][0].update(name="../N5.tar")))
        self.assertIn("has no SHA-256", broken(lambda record: raw(record)["shards"][0].update(sha256="abc")))
        self.assertIn("the bands hold 4 tiles for 5 cells", broken(lambda record: raw(record)["shards"].pop(1)))
        self.record.write_text("not json")
        with self.assertRaisesRegex(elevation_cache.CacheError, "cannot read the record"):
            elevation_cache.load_record(self.record)

    def test_only_a_finished_set_is_packed_and_the_same_bytes_every_time(self):
        first = json.loads(self.record.read_text())
        self.assertEqual([shard["name"] for shard in first["sets"]["raw"]["shards"]],
                         ["N5.tar", "S0.tar", "S1.tar", "meta.tar"])
        self.assertEqual([shard["files"] for shard in first["sets"]["raw"]["shards"]], [3, 1, 1, 8])
        self.assertTrue(first["sets"]["opened-400"]["prefix"].startswith("family/opened-400-"))
        again = elevation_cache.pack(self.root / "again.json", self.root / "again", self.BUCKET, "family",
                                     list(self.built.items()))
        self.assertEqual(again["sets"], first["sets"])
        (self.built["raw"] / "S10" / "S10E120.hgt.gz").unlink()
        with self.assertRaisesRegex(elevation_cache.CacheError, "the tiles on disk are not the cells of cells.txt"):
            elevation_cache.pack(self.root / "bad.json", self.root / "bad", self.BUCKET, "family", [("raw", self.built["raw"])])

    def test_the_command_tells_restored_from_not_restored(self):
        arguments = ["restore", "--record", str(self.record), "--report", str(self.report), "--jobs", "1",
                     "--endpoint", self.endpoint + "/", "--set", "raw", str(self.raw)]
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(elevation_cache.main([*arguments, "--set-if-kept", "opened-200", str(self.opened)]), 0)
            self.assertIn("raw: restored 5 cells into", output.getvalue())
            self.refuse["opened-400/meta.tar"] = 403
            self.assertEqual(elevation_cache.main([*arguments, "--set-if-kept", "opened-400", str(self.opened)]),
                             elevation_cache.NOT_RESTORED)
            # A set that must be there and is not kept is a failure too.
            self.assertEqual(elevation_cache.main([*arguments, "--set", "opened-200", str(self.opened)]),
                             elevation_cache.NOT_RESTORED)
            self.assertEqual(elevation_cache.main(["compare", "--report", str(self.report)]), 0)
            self.assertEqual(elevation_cache.main(["check", "--record", str(self.record)]), 0)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            elevation_cache.main(["restore", "--record", str(self.record), "--set", "raw", "relative/dir"])

    def test_the_script_restores_several_bands_in_processes_of_their_own(self):
        # As the stage runs it: the file itself, with more than one tar to take at once.
        ran = subprocess.run([sys.executable, str(BUILDER / "elevation_cache.py"), "restore", "--record", str(self.record),
                              "--report", str(self.report), "--jobs", "3", "--endpoint", self.endpoint,
                              "--set", "raw", str(self.raw), "--set-if-kept", "opened-400", str(self.opened)],
                             capture_output=True, text=True, timeout=120)
        self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
        for tar in ("N5.tar", "S0.tar", "S1.tar"):
            self.assertRegex(ran.stdout, rf"raw: {tar} \d+ bytes, \d tiles checked")
        restored = files_of(self.raw)
        del restored["restore.json"]
        self.assertEqual(restored, files_of(self.built["raw"]))
        # A worker's refusal comes back to the report as the bucket's, not as a fault of the tool.
        shutil.rmtree(self.opened)
        self.refuse["opened-400/S1.tar"] = 403
        ran = subprocess.run([sys.executable, str(BUILDER / "elevation_cache.py"), "restore", "--record", str(self.record),
                              "--report", str(self.report), "--jobs", "3", "--endpoint", self.endpoint,
                              "--set", "opened-400", str(self.opened)], capture_output=True, text=True, timeout=120)
        self.assertEqual(ran.returncode, elevation_cache.NOT_RESTORED, ran.stdout + ran.stderr)
        reason = json.loads(self.report.read_text())["sets"]["opened-400"]["reason"]
        self.assertIn("may not read family/opened-400-", reason)
        self.assertNotIn("the restore tool failed", reason)
        self.assertFalse(self.opened.exists() or elevation_cache.staging_of(self.opened).exists())

    def test_the_stand_in_serves_only_the_buckets_own_files(self):
        (self.root / "secret").write_text("outside the bucket")
        for path in (f"/storage/v1/b/{self.BUCKET}/o/..%2Fsecret?alt=media",
                     f"/storage/v1/b/other/o/{urllib.parse.quote(str(self.tar_path('raw', 'S0.tar').relative_to(self.bucket)), safe='')}?alt=media",
                     "/secret"):
            with self.assertRaises(urllib.error.HTTPError) as refused:
                urllib.request.urlopen(self.endpoint + path)
            refused.exception.close()
            self.assertEqual(refused.exception.code, 404, path)


class ElevationCacheRecordTests(unittest.TestCase):
    """The pinned record of the tiles kept in the bucket must stay checkable."""

    RECORD = json.loads((ROUTING / "releases" / "elevation-cache-2026-11-26.json").read_text())
    BANDS = [f"N{band}.tar" for band in range(9)] + [f"S{band}.tar" for band in range(10)] + ["meta.tar"]

    def test_every_shard_of_both_sets_is_pinned(self):
        self.assertEqual((self.RECORD["schema"], self.RECORD["bucket"]),
                         ("bicino-routing-elevation-cache-v1", "bicino-routing-elevation"))
        self.assertEqual(set(self.RECORD["sets"]), {"raw", "opened-400"})
        for name, tiles in self.RECORD["sets"].items():
            with self.subTest(set=name):
                self.assertEqual([shard["name"] for shard in tiles["shards"]], self.BANDS)
                self.assertEqual(sum(shard["bytes"] for shard in tiles["shards"]), tiles["shardBytes"])
                # One file per cell in the bands; the receipts are in meta.tar.
                self.assertEqual(sum(shard["files"] for shard in tiles["shards"][:-1]), tiles["cells"])
                self.assertEqual(tiles["cells"], 26475)
                self.assertGreater(tiles["shardBytes"], tiles["tileBytes"])
                for shard in tiles["shards"]:
                    self.assertRegex(shard["sha256"], r"^[0-9a-f]{64}$")
                    self.assertRegex(shard["md5"], r"^[A-Za-z0-9+/]{22}==$")
                # The prefix names the set by its manifest.
                self.assertTrue(tiles["prefix"].endswith(f"-{tiles['manifestSha256'][:12]}/"), tiles["prefix"])
                self.assertRegex(tiles["cellListSha256"], r"^[0-9a-f]{64}$")

    def test_the_restore_tool_accepts_the_record(self):
        record = elevation_cache.load_record(ROUTING / "releases" / "elevation-cache-2026-11-26.json")
        self.assertEqual((record.bucket, sorted(record.sets)), ("bicino-routing-elevation", ["opened-400", "raw"]))
        self.assertEqual(elevation_cache.object_url(elevation_cache.GOOGLE, record.bucket,
                                                    record.sets["raw"]["prefix"] + "N0.tar"),
                         "https://storage.googleapis.com/storage/v1/b/bicino-routing-elevation/o/"
                         "copernicus-2021%2Fraw-d53d9beb3206%2FN0.tar?alt=media")

    def test_the_opened_set_names_the_raw_set_it_was_opened_from(self):
        raw, opened = self.RECORD["sets"]["raw"], self.RECORD["sets"]["opened-400"]
        self.assertIsNone(raw["method"])
        self.assertEqual((opened["method"]["name"], opened["method"]["radiusMetres"]), ("grey-opening", 400.0))
        self.assertEqual(opened["method"]["input"],
                         {"manifestSha256": raw["manifestSha256"], "cellListSha256": raw["cellListSha256"]})


if __name__ == "__main__":
    unittest.main()
