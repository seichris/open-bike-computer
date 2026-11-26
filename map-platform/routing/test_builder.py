"""Tests for the planet builder's chain, its status command and its scripts."""

import contextlib
import fcntl
import io
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

ROUTING = Path(__file__).resolve().parent
BUILDER = ROUTING / "builder"
sys.path.insert(0, str(BUILDER))

import build_graph  # noqa: E402
import builder_status  # noqa: E402
import chain_state  # noqa: E402
import prepare_sample  # noqa: E402
import qualification  # noqa: E402
import rehearse  # noqa: E402
import run_stage  # noqa: E402

SHELL_SCRIPTS = sorted(BUILDER.glob("*.sh")) + sorted((BUILDER / "stages").glob("*.sh"))
GRADED_ENV = "BICINO_PLANET_DATE=261116\nBICINO_OPENING_RADIUS=400\n"


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
        self.assertEqual(rehearse.ordered(self.UNITS)[-1], rehearse.RESULT)

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
        self.stub("download.sh", "sleep 30")
        self.assertEqual(self.start(kill_stage="download", kill_after=1.5), 1)
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
        for tool in ("chain_state.py", "run_stage.py", "builder_status.py", "qualification.py", "rehearse.py"):
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
                if source.startswith("/var/run/docker.sock") or source == '"$root:$root"':
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
            for line in ("BICINO_PLANET_DATE=$(touch pwned)", "PATH=/tmp", "BICINO_X='quoted'", "echo hello"):
                env.write_text(line + "\n")
                rejected = self.source_config("echo unreachable", BICINO_SCRATCH=directory)
                self.assertEqual((rejected.returncode, rejected.stdout), (64, ""), line)
            self.assertFalse((Path(directory) / "pwned").exists())

    def test_a_run_is_validated_before_any_stage_works(self):
        with tempfile.TemporaryDirectory() as directory:
            routing = Path(directory) / "tools" / "repo" / "map-platform" / "routing"
            routing.mkdir(parents=True)
            cases = {"BICINO_PLANET_DATE=261116\nBICINO_OPENING_RADIUS=400\n": 0,
                     "BICINO_PLANET_DATE=261116\n": 0,
                     "BICINO_PLANET_DATE=2026-11-16\n": 1,
                     "BICINO_PLANET_DATE=261116\nBICINO_OPENING_RADIUS=4e2\n": 1,
                     "BICINO_PLANET_DATE=261116\nBICINO_MAP_PLATFORM_IMAGE=ghcr.io/seichris/open-bike-computer-map-platform:latest\n": 1,
                     "BICINO_SAMPLE_CITY=Berlin\n": 1,
                     "BICINO_SAMPLE_CITY=Berlin\nBICINO_SAMPLE_REGION_URL=https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf\n": 0}
            for env, expected in cases.items():
                (Path(directory) / "builder.env").write_text(env)
                checked = self.source_config("bicino_validate_run", BICINO_SCRATCH=directory)
                self.assertEqual(checked.returncode, expected, env + checked.stderr)

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
                          f'case "$*" in *" list "*) cat "{self.directory}/left" 2>/dev/null; exit "${{LIST_STATUS:-0}}";; esac\n')
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
            # New York State's boundary lacks one way in the extract.
            self.assertEqual(commands[2], ["osmium", "merge", str(out / "admin-region.osm.pbf"),
                                           str(out / "way-29307896.osm"), "-o", str(out / "admin.osm.pbf"), "--overwrite"])
            self.assertEqual((out / "way-29307896.osm").read_bytes(), b"https://api.openstreetmap.org/api/0.6/way/29307896/full")
            self.assertEqual(json.loads((out / "sample.json").read_text()), sample)
            self.assertEqual((sample["elevationBounds"], sample["region"]["url"], sample["adminWays"]), ([-75, 40, -73, 41], url, [29307896]))
            probes = json.loads((out / "probes.json").read_text())
            self.assertEqual(len(probes), len(city["legs"]))
            self.assertEqual(probes[0]["points"], [city["legs"][0]["origin"], city["legs"][0]["destination"]])
            with self.assertRaises(ValueError):
                prepare_sample.prepare(city, region, url.replace("new-york", "new-jersey"), out, run=fake_run)

    def test_every_city_is_a_sample_or_planet_only(self):
        for city in self.CITIES:
            self.assertNotEqual(bool(city.get("planetOnly")), bool(city.get("extract")), city["city"])
            if city.get("extract"):
                self.assertRegex(city["extract"], r"^[a-z-]+(/[a-z-]+)+$")
                prepare_sample.check_region_url(city, prepare_sample.region_url(city))
                self.assertEqual(len(prepare_sample.smoke_probes(city)), len(city["legs"]))
            self.assertTrue(all(isinstance(way, int) for way in city.get("adminWays", [])))
            self.assertTrue(city.get("extract") or "adminWays" not in city, city["city"])

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


if __name__ == "__main__":
    unittest.main()
