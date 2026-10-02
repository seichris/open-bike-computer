#!/usr/bin/env python3
"""The local/CI entry point for repository-defined development checks."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "tools/development/checks.json"


def git(*arguments):
    return subprocess.check_output(["git", *arguments], cwd=ROOT).decode().strip()


def source_identity():
    status = subprocess.check_output(["git", "status", "--porcelain=v1", "-z"], cwd=ROOT)
    digest = hashlib.sha256(status)
    # Include file content, not just the names of modified paths. Never emit it.
    paths = subprocess.check_output(["git", "ls-files", "-m", "-o", "--exclude-standard", "-z"], cwd=ROOT)
    for raw in sorted(set(paths.split(b"\0")) - {b""}):
        path = ROOT / os.fsdecode(raw)
        digest.update(raw)
        if path.is_symlink():
            digest.update(os.fsencode(os.readlink(path)))
        elif path.is_file():
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
    # The index can differ from both HEAD and the worktree.
    digest.update(subprocess.check_output(["git", "diff", "--cached", "--binary"], cwd=ROOT))
    return {"commit": git("rev-parse", "HEAD"), "tree": git("rev-parse", "HEAD^{tree}"),
            "dirty": bool(status), "workingStateSha256": digest.hexdigest()}


def changed_paths(base):
    merge_base = git("merge-base", "HEAD", base)
    commands = (["diff", "--name-only", "-z", merge_base, "HEAD"],
                ["diff", "--name-only", "-z", "HEAD"],
                ["ls-files", "-o", "--exclude-standard", "-z"])
    return sorted({os.fsdecode(p) for command in commands
                   for p in subprocess.check_output(["git", *command], cwd=ROOT).split(b"\0") if p})


def components(paths):
    spec = importlib.util.spec_from_file_location("changed_components", ROOT / ".github/scripts/changed_components.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    result = module.classify_paths(paths)
    if any(p.startswith(("tools/development/", "tools/dev_check.py")) for p in paths):
        result = dict.fromkeys(result, True)
    return {key for key, value in result.items() if value}


def prerequisites(check):
    reasons = []
    if check.get("host") and platform.system() not in check["host"]:
        reasons.append("requires host: " + ", ".join(check["host"]))
    for command in check.get("tools", []):
        if shutil.which(command) is None:
            reasons.append(f"missing executable: {command}")
    for module in check.get("pythonImports", []):
        try:
            found = importlib.util.find_spec(module)
        except (ImportError, ValueError):
            found = None
        if found is None:
            reasons.append(f"missing Python module: {module} (interpreter {sys.executable})")
    if not reasons:
        for probe in check.get("probes", []):
            try:
                result = subprocess.run(probe["command"], input=probe.get("input"),
                    cwd=ROOT, text=True, capture_output=True, timeout=15)
                if result.returncode:
                    reasons.append("prerequisite probe failed: " + " ".join(probe["command"]) +
                                   " — " + result.stderr[-1000:].strip())
            except (OSError, subprocess.TimeoutExpired) as error:
                reasons.append("prerequisite probe blocked: " + str(error))
    return reasons


def run_checks(checks, report_path, **options):
    report_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(str(report_path) + ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("another check owns this report path") from error
        return _run_checks(checks, report_path, **options)
    finally:
        os.close(descriptor)


def _run_checks(checks, report_path, *, plan=False, board=None, base=None, selection=None, skipped=None):
    before = source_identity()
    results = []
    report = {"schema": 1, "source": before, "base": base, "host": platform.system(),
              "architecture": platform.machine(), "python": sys.executable, "pythonVersion": sys.version,
              "board": board, "planOnly": plan, "selection": selection, "checks": results,
              "skippedChecks": skipped or []}
    report_path.parent.mkdir(parents=True, exist_ok=True)

    def save():
        temporary = report_path.with_name(report_path.name + ".tmp")
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(report_path)

    # Find every prerequisite problem before starting expensive checks.
    readiness = {check["id"]: prerequisites(check) for check in checks}
    for check in checks:
        reasons = readiness[check["id"]]
        if check.get("requiresCleanSource") and before["dirty"]:
            reasons.append("exact-build symbol retention requires clean committed source")
        if check.get("requiresBoard") and board is None:
            reasons.append("select the identified board with --board 175 or --board 206")
        entry = {"id": check["id"], "name": check["name"], "status": "blocked" if reasons else "planned",
                 "reasons": reasons, "durationMs": 0}
        results.append(entry)
        save()
        if reasons or plan:
            print(f'{entry["status"].upper()}: {check["name"]}' + (" — " + "; ".join(reasons) if reasons else ""), flush=True)
            continue
        print(f'RUN: {check["name"]}', flush=True)
        started = time.monotonic()
        log = report_path.parent / (report_path.stem + "-logs") / (check["id"] + ".log")
        log.parent.mkdir(parents=True, exist_ok=True)
        entry["log"] = str(log)
        with tempfile.TemporaryDirectory(prefix="bicino-check-") as temporary:
            environment = os.environ.copy()
            environment.update({"TMPDIR": temporary + "/", "CLANG_MODULE_CACHE_PATH": temporary + "/clang-modules",
                                "SWIFT_MODULE_CACHE_PATH": temporary + "/swift-modules",
                                "DEV_CHECK_ARTIFACTS": str(report_path.parent),
                                "PATH": str(Path(sys.executable).parent) + os.pathsep + environment.get("PATH", "")})
            command = check["command"].replace("{board}", board or "")
            with log.open("w") as stream:
                child = None
                try:
                    child = subprocess.Popen(["bash", "-euo", "pipefail", "-c", command],
                        cwd=ROOT / check.get("cwd", "."), env=environment, stdout=stream,
                        stderr=subprocess.STDOUT, start_new_session=True)
                    code = child.wait(timeout=check.get("timeoutSeconds", 1800))
                    entry["status"] = "passed" if code == 0 else "failed"
                    entry["exitCode"] = code
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait()
                    entry.update(status="failed", reasons=["check exceeded its timeout"])
                finally:
                    if child is not None and child.poll() is None:
                        os.killpg(child.pid, signal.SIGTERM)
                        try:
                            child.wait(timeout=15)
                        except subprocess.TimeoutExpired:
                            os.killpg(child.pid, signal.SIGKILL)
                            child.wait()
        entry["durationMs"] = round((time.monotonic() - started) * 1000)
        save()
        print(f'{entry["status"].upper()}: {check["name"]} ({entry["durationMs"]/1000:.1f}s)', flush=True)
        if entry["status"] != "passed":
            print(log.read_text(errors="replace")[-12000:], flush=True)
    after = source_identity()
    report["sourceUnchanged"] = before == after
    report["status"] = "planned" if plan else (
        "failed" if before != after or any(r["status"] == "failed" for r in results) else
        "blocked" if any(r["status"] == "blocked" for r in results) else "passed")
    if before != after:
        report["sourceAfter"] = after
        print("FAILED: source changed during checks; report cannot attest the final source", flush=True)
    save()
    print(f'Report: {report_path}', flush=True)
    return 0 if plan or report["status"] == "passed" else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", default="auto", choices=("auto", "all", "firmware", "ios", "map", "development"))
    parser.add_argument("--level", default="fast", choices=("fast", "full"))
    parser.add_argument("--check", action="append", default=[])
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--board", choices=("175", "206"))
    parser.add_argument("--plan", action="store_true")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args(argv)
    registry = json.loads(REGISTRY.read_text())
    checks = registry["checks"]
    ids = {c["id"] for c in checks}
    if set(args.check) - ids:
        parser.error("unknown checks: " + ", ".join(sorted(set(args.check) - ids)))
    selected_components = components(changed_paths(args.base)) if args.suite == "auto" and not args.check else set()
    if args.suite == "auto" and not args.check:
        selected_components.add("development")
    suites = {"firmware": {"firmware_host", "firmware_build"}, "ios": {"ios"},
              "map": {"map_backend", "osm"}, "development": {"development"}}
    if args.check:
        selected = [c for c in checks if c["id"] in args.check]
    else:
        selected_components |= suites.get(args.suite, set())
        selected = [c for c in checks if (args.suite == "all" or c["component"] in selected_components)
                    and (args.level == "full" or c.get("level", "fast") == "fast")]
    path = args.report or Path(git("rev-parse", "--git-path", "development-checks")) / str(uuid.uuid4()) / "results.json"
    try:
        return run_checks(selected, path.resolve(), plan=args.plan, board=args.board, base=args.base,
            selection={"suite": args.suite, "level": args.level, "explicitChecks": args.check},
            skipped=[{"id": c["id"], "status": "skipped", "reason": "outside the requested component/check/level selection"}
                     for c in checks if c not in selected])
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print(f"Development check failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
