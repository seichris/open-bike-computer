#!/usr/bin/env python3
"""Run one stage of the planet build and record what happened to it.

    run_stage.py STAGE             run the stage (the units' ExecStart)
    run_stage.py --finalize STAGE  record a stage systemd had to end (ExecStopPost)

The stage's output goes to `export/logs/STAGE.log` and its state to
`export/chain/STAGE.json` (see chain_state.py). The wrapper holds the stage's
lock for as long as the stage runs, so a marker that says running can be told
from one a dead wrapper left behind.

A stage starts only when every stage it needs is done or skipped
(`chain_state.STAGES`). The units order the stages with After= and pull them
in with Wants=; they do not use Requires=, which would also stop a running
stage when a unit it needs is restarted. So a failed stage stops everything
that needs it here, and the same rule holds without systemd.

A stage that is already done is not run again, so restarting a unit or the
whole chain is harmless. On 2026-11-26 a package upgrade restarted the
hand-started units of a planet build, and every script ran again from its
first line beside its own half-finished work. To run a finished stage again,
delete its marker first.

Containers a stage starts carry the label `bicino.stage=STAGE`, and a graph
build's the label `bicino.work=DIRECTORY`. They are not in the unit's control
group, so systemd cannot stop them; the wrapper removes them before and after
the stage and when systemd had to end it.
"""

from __future__ import annotations

import argparse
import fcntl
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

import chain_state

SCRIPTS = {
    "images": ("images.sh",),
    "download": ("download.sh",),
    "inputs": ("inputs.sh",),
    "elevation": ("elevation.sh",),
    "build-ungraded": ("build.sh", "ungraded"),
    "build-graded": ("build.sh", "graded"),
    "qualify-ungraded": ("qualify.sh", "ungraded"),
    "qualify-graded": ("qualify.sh", "graded"),
    "gate": ("gate.sh",),
}
GRADED_ONLY = ("elevation", "build-graded", "qualify-graded", "gate")
ALREADY_RUNNING = 75
BLOCKED = 69
LOCK_WAIT_SECONDS = 15


def skip_reason(stage, env):
    """Why this run leaves the stage out, or None."""
    if stage in GRADED_ONLY and not env.get("BICINO_OPENING_RADIUS"):
        return "no opening radius: this run builds only the ungraded planet"
    if stage == "inputs" and env.get("BICINO_SAMPLE_CITY"):
        return "a city sample has no territory audit"
    return None


def container_labels(root, stage):
    """The labels of the containers a stage starts.

    build_graph.py labels its Valhalla build with the work directory instead:
    it knows nothing of stages.
    """
    labels = [f"bicino.stage={stage}"]
    if stage.startswith("build-"):
        labels.append(f"bicino.work={root / 'build' / ('planet-' + stage[len('build-'):])}")
    return labels


def remove_containers(root, stage, log):
    """Remove the stage's containers; a dead wrapper's would block the next attempt."""
    if shutil.which("docker") is None:
        return
    containers = []
    for label in container_labels(root, stage):
        found = subprocess.run(["docker", "ps", "-aq", "--filter", f"label={label}"], capture_output=True, text=True)
        containers += found.stdout.split()
    if containers:
        log.write(f"removing containers of {stage}: {' '.join(containers)}\n")
        log.flush()
        subprocess.run(["docker", "rm", "-f", *containers], stdout=log, stderr=log)


def take_lock(path, wait=LOCK_WAIT_SECONDS):
    """The stage's lock, or None while another wrapper holds it.

    A status reader holds the lock shared for an instant, hence the wait.
    """
    lock = path.open("ab")
    deadline = time.monotonic() + wait
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return lock
        except BlockingIOError:
            if time.monotonic() >= deadline:
                lock.close()
                return None
            time.sleep(0.2)


def run(root, stage, stages_dir=None):
    """Run the stage's script once; returns the wrapper's exit status."""
    export = root / "export"
    (export / "chain").mkdir(parents=True, exist_ok=True)
    (export / "logs").mkdir(parents=True, exist_ok=True)
    lock = take_lock(export / "chain" / f"{stage}.lock")
    if lock is None:
        print(f"{stage} is already running under another wrapper", file=sys.stderr)
        return ALREADY_RUNNING
    with lock:
        marker = chain_state.read_marker(export / "chain", stage)
        if marker and marker["state"] in chain_state.FINISHED:
            print(f"{stage}: already {marker['state']}, nothing to do")
            return 0
        reason = skip_reason(stage, chain_state.read_env(root / "builder.env"))
        if reason:
            chain_state.mark(root, stage, "skipped", note=reason)
            chain_state.write_result(root)
            print(f"{stage}: skipped, {reason}")
            return 0
        states = {entry["stage"]: entry["state"] for entry in chain_state.stage_states(root)}
        unmet = [f"{need} ({states[need]})" for need in chain_state.STAGES[stage]
                 if states[need] not in chain_state.FINISHED]
        if unmet:
            # No marker: the stage never ran. chain_state.py reports it as blocked.
            print(f"{stage}: not started, it needs {', '.join(unmet)}", file=sys.stderr)
            return BLOCKED
        script, *arguments = SCRIPTS[stage]
        stages_dir = stages_dir or Path(__file__).resolve().parent / "stages"
        with (export / "logs" / f"{stage}.log").open("a") as log:
            remove_containers(root, stage, log)
            started = chain_state.mark(root, stage, "running")
            chain_state.write_result(root)
            log.write(f"== {stage} attempt {started['attempt']} start={started['startedAt']}\n")
            log.flush()
            stopped = []
            child = subprocess.Popen(
                [str(stages_dir / script), *arguments], stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                env={**os.environ, "BICINO_SCRATCH": str(root), "BICINO_STAGE": stage},
                start_new_session=True,
            )

            def stop(number, _frame):
                stopped.append(signal.Signals(number).name)
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass

            previous = {number: signal.signal(number, stop) for number in (signal.SIGTERM, signal.SIGINT)}
            try:
                status = child.wait()
            finally:
                for number, handler in previous.items():
                    signal.signal(number, handler)
            status = 128 - status if status < 0 else status
            remove_containers(root, stage, log)
            log.write(f"== {stage} end={chain_state.now_text()} exit={status}\n")
        if status == 0:
            chain_state.mark(root, stage, "done", exit_status=0)
            print(f"{stage}: done")
        else:
            reason = f"stopped by {stopped[0]}" if stopped else f"the stage script exited with status {status}"
            chain_state.mark(root, stage, "failed", exit_status=status, reason=reason)
            print(f"{stage}: failed with status {status}, see {export / 'logs' / f'{stage}.log'}", file=sys.stderr)
        chain_state.write_result(root)
        return status


def finalize(root, stage, environ=os.environ):
    """Record a stage whose wrapper was killed before it could write a result.

    systemd runs this after the unit stops, whatever stopped it: a timeout,
    an out-of-memory kill, a restart. EXIT_STATUS is a number or a signal name.
    """
    export = root / "export"
    (export / "logs").mkdir(parents=True, exist_ok=True)
    with (export / "logs" / f"{stage}.log").open("a") as log:
        remove_containers(root, stage, log)
        entry = next(entry for entry in chain_state.stage_states(root) if entry["stage"] == stage)
        if entry["state"] != "interrupted":
            return 0
        result, code, status = (environ.get(key, "?") for key in ("SERVICE_RESULT", "EXIT_CODE", "EXIT_STATUS"))
        chain_state.mark(root, stage, "failed", exit_status=int(status) if status.isdigit() else None,
                         reason=f"systemd ended the stage: {result} ({code} {status})")
        log.write(f"== {stage} ended by systemd at {chain_state.now_text()}: {result} ({code} {status})\n")
    chain_state.write_result(root)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--finalize", action="store_true", help="Record a stage systemd had to end")
    parser.add_argument("stage", choices=list(SCRIPTS))
    args = parser.parse_args(argv)
    root = chain_state.scratch_root()
    return finalize(root, args.stage) if args.finalize else run(root, args.stage)


if __name__ == "__main__":
    sys.exit(main())
