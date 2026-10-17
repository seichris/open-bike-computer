#!/usr/bin/env python3
"""Per-worktree development environments shared by every local agent app.

`tools/dev-setup` creates or updates ignored virtual environments inside this
worktree and reports dev-check prerequisites that are still blocked.
`tools/dev-env` runs one command with such an environment first on PATH.

Neither command installs global packages, changes Xcode, accepts licenses,
flashes or uploads firmware, opens serial ports, installs apps or reads signing
keys. Firmware keeps its own locked runtime below `esp32/.pio/open-bike-build/`.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import NamedTuple

ROOT = Path(__file__).resolve().parents[2]
STAMP = ".open-bike-dev-setup.json"
INTERPRETERS = ("python3.13", "python3.12", "python3.11", "python3.10", "python3")
SUPPORTED_PYTHON = ((3, 10), (3, 14))
PROBE = "import ensurepip, ssl, sys, venv; print('.'.join(map(str, sys.version_info[:3])))"


class Environment(NamedTuple):
    name: str
    venv: str
    install: tuple[str, ...]
    inputs: tuple[str, ...]
    setup_flag: str = ""


# Host checks and the map backend pin incompatible cryptography versions, so
# each gets its own ignored environment; pip's user download cache is shared.
HOST = Environment("host", ".venv", ("-r", "tools/development/requirements.txt"),
                   ("tools/development/requirements.txt",))
MAP_BACKEND = Environment("map-backend", "map-platform/backend/.venv",
                          ("-e", "./map-platform/backend[api,test]"),
                          ("map-platform/backend/pyproject.toml",), " --map-backend")


class SetupError(Exception):
    pass


def requirement_files(path: Path) -> list[Path]:
    files = [path]
    for line in path.read_text().splitlines():
        words = line.split("#", 1)[0].split()
        if len(words) == 2 and words[0] in ("-r", "--requirement"):
            files += requirement_files((path.parent / words[1]).resolve())
    return files


def fingerprint(environment: Environment, root: Path = ROOT) -> str:
    digest = hashlib.sha256()
    for name in environment.inputs:
        paths = requirement_files(root / name) if name.endswith(".txt") else [root / name]
        for path in paths:
            digest.update(os.fsencode(os.path.relpath(path, root)) + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def probe(executable: str) -> tuple[int, ...] | None:
    """Return a healthy interpreter's version; a hung or broken install is None."""
    try:
        result = subprocess.run([executable, "-I", "-c", PROBE], capture_output=True, text=True, timeout=20)
        version = tuple(int(part) for part in result.stdout.strip().split("."))
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    if result.returncode or len(version) != 3:
        return None
    return version if SUPPORTED_PYTHON[0] <= version[:2] <= SUPPORTED_PYTHON[1] else None


def choose_interpreter() -> tuple[str, tuple[int, ...]]:
    requested = os.environ.get("OPEN_BIKE_PYTHON")
    if requested:
        version = probe(requested)
        if version is None:
            raise SetupError(f"OPEN_BIKE_PYTHON={requested} is not a healthy Python 3.10-3.14")
        return requested, version
    seen = set()
    for name in INTERPRETERS:
        found = shutil.which(name)
        if not found or os.path.realpath(found) in seen:
            continue
        seen.add(os.path.realpath(found))
        version = probe(found)
        if version is not None:
            return found, version
    raise SetupError("no healthy Python 3.10-3.14 found; install one (for example "
                     "`brew install python@3.13`) or set OPEN_BIKE_PYTHON")


def read_stamp(venv: Path) -> dict:
    try:
        return json.loads((venv / STAMP).read_text())
    except (OSError, ValueError):
        return {}


def state(environment: Environment, root: Path = ROOT) -> tuple[str, str | None]:
    """Return (missing|broken|stale|ready, venv Python version)."""
    venv = root / environment.venv
    if not venv.exists():
        return "missing", None
    version = probe(str(venv / "bin/python"))
    if version is None:
        return "broken", None
    current = ".".join(map(str, version))
    stamp = read_stamp(venv)
    if stamp.get("inputs") != fingerprint(environment, root) or stamp.get("python") != current:
        return "stale", current
    return "ready", current


def pip_install(python: Path, environment: Environment, root: Path, quiet: bool) -> None:
    command = [str(python), "-m", "pip", "install", "--disable-pip-version-check", *environment.install]
    result = subprocess.run(command, cwd=root, text=True, capture_output=quiet)
    if result.returncode:
        if quiet:
            sys.stderr.write((result.stdout or "")[-4000:] + (result.stderr or "")[-4000:])
        raise SetupError(f"pip install failed for {environment.venv}: {' '.join(command[1:])}")


def ensure(environment: Environment, *, root: Path = ROOT, recreate: bool = False,
           quiet: bool = False) -> str:
    venv = root / environment.venv
    status, version = state(environment, root)
    if status == "broken" and not recreate:
        raise SetupError(f"{environment.venv} exists but its Python does not run; rerun "
                         f"`tools/dev-setup{environment.setup_flag} --recreate` "
                         f"(the old environment is moved aside, not deleted)")
    if recreate and venv.exists():
        kept = venv.with_name(f"{venv.name}.previous-{time.strftime('%Y%m%d-%H%M%S')}")
        venv.rename(kept)
        print(f"dev-setup: moved {environment.venv} to {os.path.relpath(kept, root)}", flush=True)
        status, version = "missing", None
    if status == "ready":
        return f"{environment.venv} up to date (Python {version})"
    if status == "missing":
        interpreter, chosen = choose_interpreter()
        subprocess.run([interpreter, "-m", "venv", str(venv)], cwd=root, check=True)
        version = ".".join(map(str, chosen))
    pip_install(venv / "bin/python", environment, root, quiet)
    (venv / STAMP).write_text(json.dumps({"schema": 1, "python": version,
                                          "inputs": fingerprint(environment, root)}, indent=2) + "\n")
    return f"{environment.venv} {'created' if status == 'missing' else 'updated'} (Python {version})"


def lock_path(root: Path = ROOT) -> Path:
    # Git's per-worktree directory: separate worktrees never wait for each other.
    path = subprocess.check_output(["git", "rev-parse", "--git-path", "open-bike-dev-setup.lock"],
                                   cwd=root, text=True).strip()
    return (root / path).resolve()


def acquire_lock(path: Path, *, wait: bool = True):
    stream = path.open("a")
    try:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        if not wait:
            stream.close()
            raise
        print("dev-setup: waiting for another tools/dev-setup in this worktree", flush=True)
        fcntl.flock(stream, fcntl.LOCK_EX)
    return stream


def blocked_checks(environment: Environment, suite: str, root: Path = ROOT) -> list[dict]:
    """Ask the registry runner, not a copied list, which checks are blocked."""
    registry = json.loads((root / "tools/development/checks.json").read_text())["checks"]
    component = {check["id"]: check["component"] for check in registry}
    with tempfile.TemporaryDirectory(prefix="open-bike-dev-setup-") as temporary:
        report = Path(temporary) / "results.json"
        result = subprocess.run([str(root / environment.venv / "bin/python"), str(root / "tools/dev_check.py"),
                                 "--plan", "--suite", suite, "--report", str(report)],
                                cwd=root, capture_output=True, text=True, timeout=600)
        if not report.exists():
            raise SetupError("tools/dev_check.py --plan failed: " + (result.stderr or result.stdout)[-2000:])
        checks = json.loads(report.read_text())["checks"]
    blocked = []
    for check in checks:
        # Board selection is a deliberate per-task choice, not a missing prerequisite.
        reasons = [r for r in check["reasons"] if not r.startswith("select the identified board")]
        if check["status"] == "blocked" and reasons and (
                suite == "map" or component.get(check["id"]) != "map_backend"):
            blocked.append({**check, "reasons": reasons})
    return blocked


def setup(args) -> int:
    environments = [HOST, MAP_BACKEND] if args.map_backend else [HOST]
    try:
        with acquire_lock(lock_path()):
            for environment in environments:
                if args.check:
                    status, _ = state(environment)
                    print(f"dev-setup: {environment.venv} is {status}")
                    if status != "ready":
                        return 3
                else:
                    print("dev-setup: " + ensure(environment, recreate=args.recreate, quiet=args.quiet),
                          flush=True)
            blocked = blocked_checks(HOST, "all")
            if args.map_backend:
                blocked += blocked_checks(MAP_BACKEND, "map")
    except (SetupError, subprocess.CalledProcessError) as error:
        print(f"dev-setup: FAILED: {error}", file=sys.stderr)
        return 1
    if not args.map_backend:
        print("dev-setup: map backend checks use a separate environment: tools/dev-setup --map-backend")
    reasons: dict[str, list[str]] = {}
    for check in blocked:
        for reason in check["reasons"]:
            reasons.setdefault(reason, []).append(check["id"])
    for reason, ids in sorted(reasons.items()):
        print(f"dev-setup: BLOCKED ({len(ids)} checks): {reason}")
    print("dev-setup: run commands with tools/dev-env, e.g. `tools/dev-env tools/dev-check --plan`")
    return 0


def run(args) -> int:
    environment = MAP_BACKEND if args.map_backend else HOST
    if not args.command:
        print("usage: tools/dev-env [--map-backend] COMMAND [ARGUMENT ...]", file=sys.stderr)
        return 2
    status, _ = state(environment)
    if status != "ready":
        recreate = " --recreate" if status == "broken" else ""
        print(f"dev-env: {environment.venv} is {status}; run tools/dev-setup{environment.setup_flag}{recreate}",
              file=sys.stderr)
        return 3
    # PATH alone selects the venv, like tools/dev_check.py. The firmware wrapper
    # rejects VIRTUAL_ENV and PYTHONHOME as ambient build overrides.
    variables = {**os.environ, "PATH": str(ROOT / environment.venv / "bin") + os.pathsep + os.environ.get("PATH", "")}
    variables.pop("VIRTUAL_ENV", None)
    variables.pop("PYTHONHOME", None)
    try:
        os.execvpe(args.command[0], args.command, variables)
    except OSError as error:
        print(f"dev-env: cannot run {args.command[0]}: {error}", file=sys.stderr)
        return 127


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="action", required=True)
    setup_parser = commands.add_parser("setup", help="create or update this worktree's environments")
    setup_parser.add_argument("--map-backend", action="store_true",
                              help="also prepare map-platform/backend/.venv for map checks")
    setup_parser.add_argument("--recreate", action="store_true",
                              help="move existing environments aside and create them again")
    setup_parser.add_argument("--check", action="store_true", help="report state without installing")
    setup_parser.add_argument("--quiet", action="store_true", help="show pip output only on failure")
    run_parser = commands.add_parser("run", help="run a command inside an environment")
    run_parser.add_argument("--map-backend", action="store_true", help="use map-platform/backend/.venv")
    run_parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    return setup(args) if args.action == "setup" else run(args)


if __name__ == "__main__":
    raise SystemExit(main())
