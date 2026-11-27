#!/usr/bin/env python3
"""Rehearse the build chain on one city, without systemd or a builder.

`rehearse.sh` runs this inside a small Ubuntu container that reaches the
host's Docker. It stands in for systemd: it reads the chain's unit files,
orders them by their After= lines and runs each unit's ExecStart exactly as
written, with the scratch path replaced. A unit whose command fails gets its
ExecStopPost, as systemd would run it. Every stage script, every container
they start and the result file are the real ones.

The run is a city sample (`BICINO_SAMPLE_CITY`): the city's Geofabrik extract
instead of the planet, the elevation cells around its box, two sample graphs
and the gate on that city alone. The territory audit, the cross-border probes
and the profile probe need a planet and are left out. A sample is never
release evidence, and its result file says so.

`--kill-stage` proves the failure path: after `--kill-after` seconds every
process of the named stage is killed, as a systemd timeout kills a unit's
control group, and the chain is then started a second time, which must
finish the build.

`--pack-cache DIR` packs the run's raw and opened tiles as they would be kept
in a bucket, with a record. `--elevation-cache DIR` then rehearses a build
that restores them: DIR is served on this machine in the bucket's place, and
the elevation stage must restore both sets and build no cell.

Units run one after another here, where systemd starts independent stages
together. Of the units that may start, the one that became startable last
runs first, so a stage runs ahead of the stages it does not wait for: the
elevation stage before the download. A stage that reads another's output
without naming it in its After= line then fails here too.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.parse
from pathlib import Path

DEFAULT_SCRATCH = "/srv/bicino-routing-scratch"
PREFIX = "bicino-planet-"
RESULT = "bicino-planet-result.service"
SAMPLER = "bicino-planet-sampler.service"
CACHE_RECORD = "elevation-cache-rehearsal.json"
CACHE_BUCKET = "rehearsal-elevation"


def parse_unit(path):
    """The unit's settings; a key given twice keeps every value."""
    settings = {}
    for line in path.read_text().splitlines():
        if line and not line.startswith(("#", "[")) and "=" in line:
            key, _, value = line.partition("=")
            settings.setdefault(key, []).append(value)
    return settings


def load_units(units_dir):
    return {path.name: parse_unit(path) for path in sorted(units_dir.glob(f"{PREFIX}*.service"))}


def ordered(units):
    """Unit names with every unit after those its After= names, latest startable first."""
    after = {name: [other for value in unit.get("After", []) for other in value.split() if other in units]
             for name, unit in units.items()}
    order, startable = [], []
    while len(order) < len(after):
        startable += [name for name in after if name not in order and name not in startable
                      and all(other in order for other in after[name])]
        if not startable:
            raise ValueError("the units' After= lines form a cycle")
        order.append(startable.pop())
    return order


def unit_environment(unit, root):
    environment = dict(os.environ)
    for value in unit.get("Environment", []):
        key, _, setting = value.partition("=")
        environment[key] = setting.replace(DEFAULT_SCRATCH, str(root))
    for value in unit.get("EnvironmentFile", []):
        for line in Path(value.replace(DEFAULT_SCRATCH, str(root))).read_text().splitlines():
            if line and not line.startswith("#") and "=" in line:
                key, _, setting = line.partition("=")
                environment[key] = setting
    return environment


def command_of(unit, key, root, interpreter=None):
    """The unit's command with the scratch path, and for tests the interpreter, replaced."""
    values = unit.get(key, [])
    if not values:
        return None
    command = shlex.split(values[0].replace(DEFAULT_SCRATCH, str(root)))
    if interpreter and command[0] == "/usr/bin/python3":
        command[0] = interpreter
    return command


def kill_session(session):
    """Kill every process of a session, as systemd kills a unit's control group."""
    for _ in range(20):
        if Path("/proc/self").exists():
            candidates = [int(entry.name) for entry in Path("/proc").iterdir() if entry.name.isdigit()]
        else:
            listing = subprocess.run(["ps", "-axo", "pid="], capture_output=True, text=True).stdout
            candidates = [int(pid) for pid in listing.split()]
        members = []
        for pid in candidates:
            try:
                if os.getsid(pid) == session:
                    members.append(pid)
            except OSError:
                continue
        if not members:
            return
        for pid in members:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        time.sleep(0.1)


def start_unit(name, unit, root, kill_after=None, out=print, interpreter=None, output=None):
    """Run the unit as systemd would; returns its ExecStart's exit status."""
    environment = unit_environment(unit, root)
    command = command_of(unit, "ExecStart", root, interpreter)
    out(f"[{time.strftime('%H:%M:%S')}] start {name}")
    child = subprocess.Popen(command, env=environment, start_new_session=True, stdout=output, stderr=output)
    result, code = "exit-code", "exited"
    try:
        status = child.wait(timeout=kill_after)
    except subprocess.TimeoutExpired:
        # A systemd timeout ends in SIGKILL for the whole control group: the
        # wrapper, the stage script and everything they started. Here those
        # are the processes of the wrapper's session. Containers are in
        # neither; the wrapper's --finalize removes them.
        kill_session(child.pid)
        child.wait()
        status, result, code = "KILL", "timeout", "killed"
    if status != 0:
        finalize = command_of(unit, "ExecStopPost", root, interpreter)
        if finalize:
            subprocess.run(finalize, stdout=output, stderr=output,
                           env={**environment, "SERVICE_RESULT": result, "EXIT_CODE": code, "EXIT_STATUS": str(status)})
    out(f"[{time.strftime('%H:%M:%S')}] {name}: {'ok' if status == 0 else f'failed ({status})'}")
    return status


def start_chain(root, units_dir, kill_stage=None, kill_after=None, out=print, interpreter=None, output=None):
    """One `systemctl start bicino-planet-result.service`; returns the result unit's status."""
    units = load_units(units_dir)
    status = None
    for name in ordered(units):
        if name == SAMPLER:
            continue
        stage = name[len(PREFIX):-len(".service")]
        status = start_unit(name, units[name], root, kill_after if stage == kill_stage else None, out,
                            interpreter, output)
    return status


class BucketHandler(http.server.BaseHTTPRequestHandler):
    """The one request a restore makes of the storage API, answered from a directory."""

    root = None
    bucket = None

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        prefix = f"/storage/v1/b/{self.bucket}/o/"
        path = self.root / urllib.parse.unquote(url.path[len(prefix):]) if url.path.startswith(prefix) else None
        if path is None or url.query != "alt=media" or self.root not in path.resolve().parents or not path.is_file():
            self.send_error(404)
            return
        size, start = path.stat().st_size, 0
        wanted = re.fullmatch(r"bytes=(\d+)-", self.headers.get("Range") or "")
        if wanted:
            start = min(int(wanted[1]), size)
        self.send_response(206 if wanted else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size - start))
        if wanted:
            self.send_header("Content-Range", f"bytes {start}-{size - 1}/{size}")
        self.end_headers()
        with path.open("rb") as stream:
            stream.seek(start)
            self.send_body(stream)

    def send_body(self, stream):
        shutil.copyfileobj(stream, self.wfile)

    def log_message(self, *arguments):
        pass


def serve_bucket(root, bucket, handler=BucketHandler):
    """Serve `root` as `bucket` on a free local port; returns the server and its address."""
    served = type("Served", (handler,), {"root": Path(root).resolve(), "bucket": bucket})
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), served)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


def write_env(root, city, region_url, radius, image, jobs, threads, terrain=None, *, cache=None, endpoint=None):
    lines = [f"BICINO_SAMPLE_CITY={city}", f"BICINO_SAMPLE_REGION_URL={region_url}",
             f"BICINO_OPENING_RADIUS={radius or ''}", f"BICINO_TERRAIN={terrain or ''}",
             f"BICINO_ELEVATION_CACHE={cache or ''}", f"BICINO_ELEVATION_CACHE_ENDPOINT={endpoint or ''}",
             f"BICINO_ELEVATION_JOBS={jobs}",
             f"BICINO_UNGRADED_THREADS={threads}", f"BICINO_GRADED_THREADS={threads}",
             "BICINO_TOOLS_COMMIT=rehearsal"]
    if image:
        lines.append(f"BICINO_MAP_PLATFORM_IMAGE={image}")
    (root / "builder.env").write_text("\n".join(lines) + "\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", required=True, type=Path, help="The rehearsal's scratch directory")
    parser.add_argument("--city", required=True, help="A city of elevation-probes.json that names an extract")
    parser.add_argument("--radius", type=int, help="Opening radius in metres; without it only the ungraded sample is built")
    parser.add_argument("--terrain", help="A terrain source id of elevation-sources.json, such as usgs-3dep-13, "
                                          "to put over the opened tiles; needs --radius")
    parser.add_argument("--date", help="The extract's YYMMDD date on Geofabrik instead of the latest")
    parser.add_argument("--map-platform-image", help="A digest-pinned map-platform image already on this host")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--pack-cache", type=Path, metavar="DIR",
                        help="After the run, pack its raw and opened tiles into DIR as a bucket would hold them")
    parser.add_argument("--elevation-cache", type=Path, metavar="DIR",
                        help="Restore the elevation tiles from DIR, which an earlier --pack-cache wrote")
    parser.add_argument("--kill-stage", help="Kill this stage's wrapper once, then start the chain again")
    parser.add_argument("--kill-after", type=float, default=20, help="Seconds before the kill")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    builder = root / "tools" / "repo" / "map-platform" / "routing" / "builder"
    sys.path.insert(0, str(builder.parent))
    import prepare_sample
    cities = json.loads((builder.parent / "elevation-probes.json").read_text())
    try:
        city = prepare_sample.find_city(cities, args.city)
    except ValueError as error:
        parser.error(str(error))
    if args.terrain and not args.radius:
        parser.error("--terrain needs --radius")
    if (args.pack_cache or args.elevation_cache) and not args.radius:
        parser.error("--pack-cache and --elevation-cache need --radius")
    cache = endpoint = None
    if args.elevation_cache and not (args.elevation_cache / CACHE_RECORD).is_file():
        parser.error(f"--elevation-cache: {args.elevation_cache} holds no {CACHE_RECORD}; write it with --pack-cache")
    if args.elevation_cache:
        # The record goes where a real one is, in the tools' releases/; the tars are served from DIR.
        shutil.copyfile(args.elevation_cache / CACHE_RECORD, builder.parent / "releases" / CACHE_RECORD)
        _, endpoint = serve_bucket(args.elevation_cache, CACHE_BUCKET)
        cache = CACHE_RECORD
    write_env(root, args.city, prepare_sample.region_url(city, args.date), args.radius,
              args.map_platform_image, args.jobs, args.threads, args.terrain, cache=cache, endpoint=endpoint)
    os.environ["BICINO_SCRATCH"] = str(root)
    if args.kill_stage:
        start_chain(root, builder / "units", args.kill_stage, args.kill_after)
        print(f"== {args.kill_stage} was killed; starting the chain again")
    status = start_chain(root, builder / "units")
    print(f"Result: {root / 'export' / 'result.json'}")
    if args.pack_cache and status == 0:
        sys.path.insert(0, str(builder))
        import elevation_cache
        opened = root / ("elevation-opened" if args.terrain else "elevation")
        elevation_cache.pack(args.pack_cache / CACHE_RECORD, args.pack_cache, CACHE_BUCKET, "rehearsal",
                             [("raw", root / "elevation-raw"), (f"opened-{args.radius}", opened)])
        print(f"Packed tiles: {args.pack_cache / CACHE_RECORD}")
    return status


if __name__ == "__main__":
    sys.exit(main())
