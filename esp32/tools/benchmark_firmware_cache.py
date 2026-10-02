#!/usr/bin/env python3
"""Qualify core relocation and library reuse with real, build-only worktrees."""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


IMAGE_FIELDS = (
    "firmwareBinSha256", "bootloaderBinSha256", "partitionTableBinSha256", "bootApp0Sha256",
)


def _run(command, *, cwd=None, env=None):
    return subprocess.run(command, cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()


def _writable_tree(root):
    if root.is_symlink() or not root.is_dir():
        raise RuntimeError("unsafe benchmark cleanup directory")
    root.chmod(0o700)
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs:
            path = Path(directory) / name
            if not path.is_symlink():
                path.chmod(path.stat().st_mode | 0o700)
        for name in files:
            path = Path(directory) / name
            if not path.is_symlink():
                path.chmod(path.stat().st_mode | 0o600)


def benchmark(repo, environment, output):
    revision = _run(["git", "rev-parse", "HEAD"], cwd=repo)
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    sandbox = Path(tempfile.mkdtemp(prefix="firmware-cache-qualification-")).resolve()
    cache_environment = {**os.environ, "OPEN_BIKE_FIRMWARE_BUILD_CACHE": str(sandbox / "transport")}
    cache_environment.pop("LD_LIBRARY_PATH", None)
    active = []
    results = {}

    def add(name, ref):
        checkout = sandbox / name
        _run(["git", "worktree", "add", "--detach", str(checkout), ref], cwd=repo)
        active.append(checkout)
        return checkout

    def remove(checkout):
        _writable_tree(checkout)
        _run(["git", "worktree", "remove", "--force", str(checkout)], cwd=repo)
        active.remove(checkout)

    def build(checkout, phase):
        print(f"Firmware cache qualification: {phase}", flush=True)
        started = time.monotonic()
        log = output.parent / f"{output.stem}-{phase}.log"
        with log.open("w") as stream:
            result = subprocess.run(
                [sys.executable, "tools/build_firmware.py", environment],
                cwd=checkout / "esp32", env=cache_environment,
                stdout=stream, stderr=subprocess.STDOUT,
            )
        if result.returncode:
            raise RuntimeError(f"{phase} build failed; inspect {log}")
        manifest_path = checkout / "esp32/.pio/open-bike-build/builds" / environment / "current.json"
        manifest = json.loads(manifest_path.read_text())
        contents = log.read_text()
        if not (checkout / "esp32/.pio/build" / environment / "firmware.map").is_file():
            raise RuntimeError(f"{phase} did not generate linker evidence")
        record = {
            "wallMs": round((time.monotonic() - started) * 1000),
            "git": _run(["git", "rev-parse", "HEAD"], cwd=checkout),
            "coreCache": manifest["coreCache"], "coreInputKey": manifest["coreInputKey"],
            "phaseTimingsMs": manifest["phaseTimingsMs"],
            "cacheObjectHits": contents.count("Retrieved"),
            "firmwareElfSha256": manifest["firmwareElfSha256"],
            "flashPlanSha256": manifest["flashPlanSha256"],
            **{key: manifest[key] for key in IMAGE_FIELDS},
        }
        results[phase] = record
        output.write_text(json.dumps({"schema": 1, "environment": environment, "revision": revision, "builds": results}, indent=2) + "\n")
        return record

    try:
        producer = add("producer", revision)
        cold = build(producer, "cold")
        warm = build(producer, "warm")
        if warm["coreCache"] != "hit" or any(cold[key] != warm[key] for key in (*IMAGE_FIELDS, "firmwareElfSha256", "flashPlanSha256")):
            raise RuntimeError("same-head warm rebuild changed its artifacts")
        source = producer / "esp32/lib/firmware_metadata/firmware_metadata.cpp"
        with source.open("a") as stream:
            stream.write("\n// Source-only cache qualification commit.\n")
        _run(["git", "add", str(source)], cwd=producer)
        _run(["git", "-c", "user.name=Firmware cache qualification", "-c", "user.email=cache@example.invalid", "commit", "--no-gpg-sign", "-m", "Qualify source-only compilation reuse"], cwd=producer)
        changed = build(producer, "source-only")
        if changed["coreCache"] != "hit" or changed["coreInputKey"] != cold["coreInputKey"] or changed["cacheObjectHits"] == 0:
            raise RuntimeError("source-only commit did not reuse core and object caches")
        # Bound peak disk use; the next build must work after the producer vanishes.
        remove(producer)
        consumer = add("consumer with a longer path", revision)
        relocated = build(consumer, "new-worktree")
        if relocated["coreCache"] != "hit" or relocated["phaseTimingsMs"]["customCoreBootstrap"] != 0 or any(cold[key] != relocated[key] for key in IMAGE_FIELDS):
            raise RuntimeError("cross-worktree core restore changed the firmware images")
        print(f"Firmware cache qualification passed: {output}", flush=True)
    finally:
        for checkout in list(active):
            remove(checkout)
        _writable_tree(sandbox)
        shutil.rmtree(sandbox)
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("environment", choices=("WAVESHARE_AMOLED_175", "WAVESHARE_AMOLED_175_PRODUCTION", "WAVESHARE_AMOLED_206", "WAVESHARE_AMOLED_206_PRODUCTION"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    benchmark(Path(__file__).resolve().parents[2], args.environment, args.output)
