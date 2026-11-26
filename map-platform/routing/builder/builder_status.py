#!/usr/bin/env python3
"""Ask the planet builder where its build chain stands, and never guess.

Run it on the map VPS, which holds the builder's SSH configuration:

    python3 builder_status.py --ssh-config /root/.ssh/bicino-valhalla-JOB.d/config

or from a laptop, through the VPS:

    python3 builder_status.py --via root@VPS --ssh-config /root/.ssh/bicino-valhalla-JOB.d/config

It runs `chain_state.py status --json` on the builder, prints the chain's
state and every stage, and exits with:

    0   the chain is complete and the gate met its targets (or was not run)
    3   the chain is running
    4   the chain is complete and the gate missed a target
    5   a stage failed, or the chain stalled
    6   the chain has not started
    7   no usable answer: SSH failed, timed out, or returned something else

The builder runs the chain under systemd and needs nobody watching. A watcher
that cannot tell "busy" from "unreachable" is worse than none: on 2026-11-25
a wait loop threw away SSH's errors and read every empty reply as "still
running", while the VPS was asking for a Tailscale re-authentication. Both
builds finished and the builder then sat idle for eight hours. So anything
but a well-formed answer is exit 7, with whatever SSH printed. `--wait`
polls while the chain is running and stops at the first other answer,
including exit 7.

Only the standard library is used, so the file runs on the VPS as it is.
"""

from __future__ import annotations

import argparse
import calendar
import json
import shlex
import subprocess
import sys
import time

SCHEMA = "bicino-planet-builder-result-v1"
REMOTE = "/srv/bicino-routing-scratch/tools/repo/map-platform/routing/builder/chain_state.py"
EXIT_PASSED, EXIT_RUNNING, EXIT_MISSED, EXIT_FAILED, EXIT_NOT_STARTED, EXIT_UNREACHABLE = 0, 3, 4, 5, 6, 7
STATE_EXITS = {"running": EXIT_RUNNING, "failed": EXIT_FAILED, "stalled": EXIT_FAILED,
               "not-started": EXIT_NOT_STARTED}
# The sampler writes a heartbeat every 30 seconds.
STALE_SAMPLER_SECONDS = 300
SSH_OPTIONS = ("-o", "BatchMode=yes", "-o", "ConnectTimeout=20")


class Unreachable(Exception):
    """The builder gave no usable answer."""


def ssh_command(ssh_config, host, via=None):
    """The command that asks the builder, directly or through the VPS."""
    remote = f"/usr/bin/python3 {REMOTE} status --json"
    builder = ["ssh", "-F", ssh_config, *SSH_OPTIONS, host, remote]
    if via is None:
        return builder
    return ["ssh", *SSH_OPTIONS, via, shlex.join(builder)]


def tail(text, lines=6):
    return "\n".join(f"    {line}" for line in text.strip().splitlines()[-lines:])


def ask(command, timeout, runner=subprocess.run):
    """The builder's status, or Unreachable with everything SSH said."""
    try:
        reply = runner(command, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired as error:
        said = "".join(part.decode(errors="replace") if isinstance(part, bytes) else part or ""
                       for part in (error.stdout, error.stderr))
        raise Unreachable(f"no answer within {timeout} s" + (f"; so far:\n{tail(said)}" if said.strip() else ""))
    except OSError as error:
        raise Unreachable(f"could not run ssh: {error}")
    if reply.returncode != 0:
        said = reply.stderr.strip() or reply.stdout.strip() or "it printed nothing"
        raise Unreachable(f"ssh exited with status {reply.returncode}:\n{tail(said)}")
    if not reply.stdout.strip():
        raise Unreachable("ssh succeeded but returned nothing" + (f":\n{tail(reply.stderr)}" if reply.stderr.strip() else ""))
    try:
        status = json.loads(reply.stdout)
    except ValueError:
        raise Unreachable(f"the reply is not a status report:\n{tail(reply.stdout)}")
    if (not isinstance(status, dict) or status.get("schema") != SCHEMA or not isinstance(status.get("stages"), list)
            or not isinstance(status.get("state"), str) or not isinstance(status.get("text"), str)):
        raise Unreachable(f"the reply is not a {SCHEMA} report:\n{tail(reply.stdout)}")
    return status


def exit_code(status):
    if status["state"] == "complete":
        return EXIT_MISSED if status.get("verdict") == "missed" else EXIT_PASSED
    # A state this version does not know is not "running".
    return STATE_EXITS.get(status["state"], EXIT_UNREACHABLE)


def seconds_between(earlier, later):
    form = "%Y-%m-%dT%H:%M:%SZ"
    return calendar.timegm(time.strptime(later, form)) - calendar.timegm(time.strptime(earlier, form))


def describe(status):
    """The builder's own rendering, and a warning when its heartbeat is old."""
    lines = [status["text"]]
    sampler = status.get("sampler") or {}
    if status["state"] == "running" and sampler.get("sampledAt") and status.get("now"):
        age = seconds_between(sampler["sampledAt"], status["now"])
        if age > STALE_SAMPLER_SECONDS:
            lines.append(f"  WARNING: the sampler has written nothing for {age:.0f} s")
    return "\n".join(lines)


def stage_line(status):
    return ", ".join(f"{entry['stage']}={entry['state']}" for entry in status["stages"])


def watch(command, timeout, interval, runner=subprocess.run, sleep=time.sleep):
    """Poll while the chain runs; return at the first other answer."""
    last = None
    while True:
        status = ask(command, timeout, runner)
        code = exit_code(status)
        if code != EXIT_RUNNING:
            return status
        line = stage_line(status)
        if line != last:
            print(f"{status.get('now')} running: {line}", flush=True)
            last = line
        sleep(interval)


def main(argv=None, runner=subprocess.run, sleep=time.sleep):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ssh-config", required=True, help="The job's SSH configuration (a path on the VPS with --via)")
    parser.add_argument("--host", default="builder", help="The builder's Host entry in that configuration")
    parser.add_argument("--via", help="Reach the VPS first, as USER@HOST (from a laptop)")
    parser.add_argument("--timeout", type=int, default=60, help="Seconds to wait for one answer")
    parser.add_argument("--wait", action="store_true", help="Poll until the chain is no longer running")
    parser.add_argument("--interval", type=int, default=300, help="Seconds between polls with --wait")
    parser.add_argument("--json", action="store_true", help="Print the builder's report as JSON")
    args = parser.parse_args(argv)
    if args.timeout < 5 or args.interval < 10:
        parser.error("--timeout must be at least 5 and --interval at least 10 seconds")
    command = ssh_command(args.ssh_config, args.host, args.via)
    try:
        status = watch(command, args.timeout, args.interval, runner, sleep) if args.wait \
            else ask(command, args.timeout, runner)
    except Unreachable as error:
        print(f"chain: UNREACHABLE, not known to be running. {error}", file=sys.stderr)
        print(f"  asked with: {shlex.join(command)}", file=sys.stderr)
        return EXIT_UNREACHABLE
    print(json.dumps(status, indent=1) if args.json else describe(status))
    return exit_code(status)


if __name__ == "__main__":
    sys.exit(main())
