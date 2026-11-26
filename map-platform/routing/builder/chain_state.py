#!/usr/bin/env python3
"""State of the planet builder's stage chain, kept as marker files.

Each stage of the build runs under `run_stage.py`, which records what happened
in `export/chain/<stage>.json`: running, done, skipped or failed, with the
exit status, the times and, for a failure, the reason and the end of the log.
While a stage runs, its wrapper holds a lock on `export/chain/<stage>.lock`.
A marker that says running without that lock is an interrupted stage (the
wrapper was killed or the machine restarted), never a running one.

A marker also records the settings its stage ran under: the planet snapshot,
the opening radius, the map-platform image and the sample, as far as the
stage or a stage it needs depends on them, and the tools commit. A finished
stage whose settings differ from `builder.env` is stale: its work is not
reused under the new settings, and nothing deletes it. Only the tools commit
may differ; the result then names the commit of every stage.

`status` reads the markers and locks and prints where the chain stands.
`result` writes the same, with the archive manifests, the qualification
summaries and the gate summary, to `export/result.json`; `result --final`
also puts the manifests and hard links to the archives below `export/`.

The chain's state is one of:

- not-started: no stage has a marker;
- running: a stage is running, or the next one is about to start;
- failed: a stage failed, was interrupted or is stale. Stages that need it
  never start; a stage that does not need it and was already running finishes
  its work;
- stalled: nothing is running, nothing failed, and stages are still waiting.
  systemd is not driving the chain any more;
- complete: every stage is done or skipped. `verdict` then holds the gate's
  answer: met, missed, or not-run for a build without elevation.

Only the standard library is used: this runs on the bare builder.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import shutil
import socket
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = "bicino-planet-builder-result-v1"
STAGE_SCHEMA = "bicino-planet-stage-v1"
# Stage: the stages it needs, in chain order. run_stage.py enforces them. The
# systemd units repeat them as Wants= and After=; test_builder.py keeps the
# two in step.
STAGES = {
    "images": (),
    "download": (),
    "inputs": ("images",),
    "elevation": ("images",),
    "build-ungraded": ("images", "download"),
    "build-graded": ("images", "download", "elevation"),
    "qualify-ungraded": ("build-ungraded", "inputs"),
    "qualify-graded": ("build-graded", "inputs"),
    "gate": ("qualify-ungraded", "qualify-graded"),
}
# The settings a stage's work depends on, beyond those of the stages it needs.
STAGE_SETTINGS = {
    "images": ("BICINO_MAP_PLATFORM_IMAGE",),
    "download": ("BICINO_PLANET_DATE", "BICINO_SAMPLE_CITY", "BICINO_SAMPLE_REGION_URL"),
    "elevation": ("BICINO_OPENING_RADIUS", "BICINO_SAMPLE_CITY"),
}
MARKED = ("running", "done", "skipped", "failed")
FINISHED = ("done", "skipped")
BROKEN = ("failed", "interrupted", "stale")
# systemd starts the next stage within a moment of the last one ending. After
# this long with nothing running and nothing failed, the chain has stalled.
STALL_SECONDS = 120
LOG_TAIL_LINES = 25
ENV_KEYS = {
    "BICINO_PLANET_DATE": "planetDate",
    "BICINO_OPENING_RADIUS": "openingRadiusMetres",
    "BICINO_TOOLS_COMMIT": "toolsCommit",
    "BICINO_MAP_PLATFORM_IMAGE": "mapPlatformImage",
    "BICINO_SAMPLE_CITY": "sampleCity",
    "BICINO_SAMPLE_REGION_URL": "sampleRegionUrl",
}


def now_text(clock=time.time):
    return datetime.fromtimestamp(clock(), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(text):
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()


def scratch_root(environ=os.environ):
    root = Path(environ.get("BICINO_SCRATCH", "/srv/bicino-routing-scratch"))
    if not root.is_absolute():
        raise SystemExit(f"BICINO_SCRATCH must be an absolute path, got: {root}")
    return root


def write_json(path, value):
    """Replace the file in one step, so a reader never sees half of it."""
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_name(f".{path.name}.{os.getpid()}.partial")
    partial.write_text(json.dumps(value, indent=1) + "\n")
    partial.chmod(0o644)
    partial.replace(path)


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def read_env(path):
    """builder.env as config.sh reads it: plain KEY=value lines."""
    values = {}
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return values
    for line in lines:
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            values[key] = value
    return values


def stage_settings(stage, env):
    """The settings the stage's work depends on: its own and those of every stage it needs."""
    keys = set(STAGE_SETTINGS.get(stage, ()))
    for need in STAGES[stage]:
        keys.update(stage_settings(need, env))
    return {key: env.get(key, "") for key in sorted(keys)}


def read_marker(chain, stage):
    marker = read_json(chain / f"{stage}.json")
    if not isinstance(marker, dict) or marker.get("stage") != stage or marker.get("state") not in MARKED:
        return None
    return marker


def lock_is_held(chain, stage):
    """Whether the stage's wrapper is alive: it holds this lock while it runs."""
    try:
        with (chain / f"{stage}.lock").open("rb") as lock:
            try:
                # A shared lock: two status readers never block each other.
                fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(lock, fcntl.LOCK_UN)
            return False
    except OSError:
        return False


def log_tail(path, lines=LOG_TAIL_LINES):
    try:
        with path.open("rb") as stream:
            stream.seek(0, os.SEEK_END)
            stream.seek(max(0, stream.tell() - 16384))
            text = stream.read().decode(errors="replace")
    except OSError:
        return []
    return [line[:400] for line in text.splitlines()[-lines:]]


def mark(root, stage, state, *, exit_status=None, reason=None, note=None, clock=time.time):
    """Record a stage's new state; returns the marker."""
    if stage not in STAGES or state not in MARKED:
        raise ValueError(f"unknown stage or state: {stage} {state}")
    chain = root / "export" / "chain"
    previous = read_marker(chain, stage) or {}
    now = now_text(clock)
    log = root / "export" / "logs" / f"{stage}.log"
    env = read_env(root / "builder.env")
    marker = {
        "schema": STAGE_SCHEMA, "stage": stage, "state": state,
        "attempt": previous.get("attempt", 0), "startedAt": previous.get("startedAt"),
        "finishedAt": None, "seconds": None, "exitStatus": None,
        "reason": reason, "note": note, "log": f"logs/{stage}.log",
        # What the stage ran under. A stage that ends keeps what it started with.
        "settings": stage_settings(stage, env), "toolsCommit": env.get("BICINO_TOOLS_COMMIT") or None,
    }
    if state in ("done", "failed") and previous.get("state") == "running":
        marker.update(settings=previous.get("settings"), toolsCommit=previous.get("toolsCommit"))
    if state == "running":
        marker.update(attempt=previous.get("attempt", 0) + 1, startedAt=now)
    else:
        # A skipped stage never ran, and a wrapper that died may leave no start.
        started = previous.get("startedAt") if previous.get("state") == "running" else None
        marker.update(startedAt=started or now, finishedAt=now, exitStatus=exit_status)
        marker["seconds"] = round(parse_time(now) - parse_time(marker["startedAt"]))
        if state == "failed":
            marker["logTail"] = log_tail(log)
    write_json(chain / f"{stage}.json", marker)
    return marker


def changed_settings(marker, current):
    """How the settings a finished stage ran under differ from today's, as text."""
    ran = marker.get("settings")
    if not isinstance(ran, dict):
        return "its marker does not say what settings it ran under"
    changes = [f"{key} was '{ran.get(key, '')}', is now '{value}'" for key, value in current.items()
               if ran.get(key, "") != value]
    return "; ".join(changes)


def stage_states(root):
    """Every stage with its state: marked states, interrupted, stale, blocked or waiting."""
    chain = root / "export" / "chain"
    env = read_env(root / "builder.env")
    stages = {}
    for stage, needs in STAGES.items():
        marker = read_marker(chain, stage)
        entry = {"stage": stage, "state": "waiting", "needs": list(needs)}
        if marker:
            entry.update({key: value for key, value in marker.items() if key != "schema"})
            if marker["state"] == "running" and not lock_is_held(chain, stage):
                entry["state"] = "interrupted"
                entry["reason"] = "the stage's wrapper is gone and left no result"
            elif marker["state"] in FINISHED:
                changes = changed_settings(marker, stage_settings(stage, env))
                if changes:
                    entry.update(state="stale", was=marker["state"], reason=f"{marker['state']} under other settings: {changes}")
        stages[stage] = entry
    for stage, entry in stages.items():
        # STAGES is in chain order, so a stage's needs are settled before it.
        if entry["state"] == "waiting":
            broken = [need for need in STAGES[stage] if stages[need]["state"] in (*BROKEN, "blocked")]
            if broken:
                entry.update(state="blocked", blockedBy=broken)
    return list(stages.values())


def gate_verdict(root, stages):
    """met, missed or not-run once the gate stage has finished; else None."""
    gate = next(entry for entry in stages if entry["stage"] == "gate")
    if gate["state"] == "skipped":
        return "not-run", None
    if gate["state"] != "done":
        return None, None
    summary = read_json(root / "export" / "evidence" / "gate" / "gate-summary.json")
    if not isinstance(summary, dict) or not isinstance(summary.get("failures"), dict):
        return "missed", {"failures": {"gate": ["the gate stage left no summary"]}}
    return ("missed" if any(summary["failures"].values()) else "met"), summary


def chain_status(root, clock=time.time):
    stages = stage_states(root)
    states = [entry["state"] for entry in stages]
    times = [entry[key] for entry in stages for key in ("startedAt", "finishedAt") if entry.get(key)]
    now = clock()
    if all(state == "waiting" for state in states):
        state = "not-started"
    elif any(state in BROKEN for state in states):
        state = "failed"
    elif all(state in FINISHED for state in states):
        state = "complete"
    elif "running" in states or now - max(map(parse_time, times)) < STALL_SECONDS:
        state = "running"
    else:
        state = "stalled"
    verdict, summary = gate_verdict(root, stages) if state == "complete" else (None, None)
    env = read_env(root / "builder.env")
    run = {name: env.get(key) or None for key, name in ENV_KEYS.items()}
    status = {
        "schema": SCHEMA,
        "state": state,
        "verdict": verdict,
        "sample": bool(run["sampleCity"]),
        "now": now_text(clock),
        "host": socket.gethostname(),
        "startedAt": min(times) if times else None,
        "finishedAt": max(times) if times and state in ("complete", "failed") and "running" not in states else None,
        "run": run,
        "stages": stages,
        "sampler": read_json(root / "export" / "chain" / "sampler.json"),
    }
    return status, summary


def describe(status):
    """The status as text: one headline, one line per stage."""
    headline = f"chain: {status['state']}"
    if status["state"] == "complete":
        headline += f", gate {status['verdict']}"
    if status.get("sample"):
        headline += " (SAMPLE REHEARSAL, not release evidence)"
    lines = [headline + f"  [{status['host']} at {status['now']}]"]
    for entry in status["stages"]:
        detail = ""
        if entry["state"] == "running":
            detail = f"since {entry['startedAt']}, attempt {entry['attempt']}"
        elif entry["state"] in ("done", "failed"):
            detail = f"{entry['finishedAt']}, {entry['seconds']} s"
            if entry["exitStatus"] is not None:
                detail += f", exit {entry['exitStatus']}"
        elif entry["state"] == "blocked":
            detail = "needs " + ", ".join(entry["blockedBy"])
        if entry.get("reason"):
            detail += f": {entry['reason']}" if detail else entry["reason"]
        elif entry.get("note"):
            detail += f" ({entry['note']})" if detail else entry["note"]
        lines.append(f"  {entry['stage']:<17} {entry['state']:<12} {detail}".rstrip())
        if entry["state"] == "failed":
            lines += [f"      | {line}" for line in entry.get("logTail", [])[-8:]]
    commits = {}
    for entry in status["stages"]:
        if entry.get("toolsCommit") and entry["state"] != "waiting":
            commits.setdefault(entry["toolsCommit"], []).append(entry["stage"])
    if len(commits) > 1:
        lines.append("  NOTE: the stages ran with different tools: "
                     + "; ".join(f"{commit[:12]} ({', '.join(stages)})" for commit, stages in commits.items()))
    sampler = status.get("sampler")
    if sampler:
        lines.append(f"  scratch {sampler.get('diskUsedBytes', 0) / 1e9:.0f} GB (peak {sampler.get('peakDiskBytes', 0) / 1e9:.0f}),"
                     f" memory {sampler.get('memoryUsedBytes', 0) / 1e9:.0f} GB (peak {sampler.get('peakMemoryBytes', 0) / 1e9:.0f}),"
                     f" sampled {sampler.get('sampledAt')}")
    return "\n".join(lines)


def build_result(root, final=False, clock=time.time):
    status, gate_summary = chain_status(root, clock)
    evidence = root / "export" / "evidence"
    result = dict(status, final=final)
    result["archives"] = {
        label: read_json(root / "build" / f"planet-{label}" / "manifest.json") for label in ("ungraded", "graded")
    }
    result["qualification"] = {
        label: read_json(evidence / f"qualify-{label}" / "summary.json") for label in ("ungraded", "graded")
    }
    result["elevation"] = {
        "opened": read_json(root / "elevation" / "elevation-manifest.json"),
        "raw": read_json(root / "elevation-raw" / "elevation-manifest.json"),
    }
    result["gate"] = gate_summary
    return result


def collect_evidence(root):
    """Put the manifests beside the logs and hard-link the archives into export/.

    Hard links cost no space on the scratch volume, and the VPS pulls
    `export/<label>/valhalla_tiles.tar` with its read-only identity.
    """
    export = root / "export"
    copies = [(root / "elevation" / name, export / "evidence" / "elevation-opened" / name)
              for name in ("elevation-manifest.json", "cells.txt")]
    copies += [(root / "elevation-raw" / name, export / "evidence" / "elevation-raw" / name)
               for name in ("elevation-manifest.json", "cells.txt")]
    copies += [(path, export / "evidence" / "input" / path.name)
               for path in sorted((root / "input").glob("*.osm.pbf.*")) if path.stat().st_size < 4096]
    for label in ("ungraded", "graded"):
        build = root / "build" / f"planet-{label}"
        copies += [(build / name, export / label / name) for name in ("manifest.json", "valhalla-build.log")]
        archive, link = build / "valhalla_tiles.tar", export / label / "valhalla_tiles.tar"
        if (build / "manifest.json").exists() and archive.exists():
            link.parent.mkdir(parents=True, exist_ok=True)
            if not (link.exists() and link.samefile(archive)):
                link.unlink(missing_ok=True)
                os.link(archive, link)
    for source, target in copies:
        if source.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            target.chmod(0o644)


def write_result(root, final=False, clock=time.time):
    if final:
        collect_evidence(root)
    result = build_result(root, final, clock)
    write_json(root / "export" / "result.json", result)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    status = commands.add_parser("status", help="Print where the chain stands")
    status.add_argument("--json", action="store_true")
    result = commands.add_parser("result", help="Write export/result.json")
    result.add_argument("--final", action="store_true", help="Also collect the manifests and link the archives")
    args = parser.parse_args(argv)
    root = scratch_root()
    if args.command == "status":
        current, _ = chain_status(root)
        # builder_status.py prints `text`, so both ends show the same lines.
        print(json.dumps(dict(current, text=describe(current)), indent=1) if args.json else describe(current))
    else:
        final = write_result(root, final=args.final)
        print(describe(final))
        print(f"Result: {root / 'export' / 'result.json'}")
        # The last unit of the chain fails with the chain, for `systemctl status`.
        return 1 if args.final and final["state"] != "complete" else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
