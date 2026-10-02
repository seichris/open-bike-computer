#!/usr/bin/env python3
"""Run a command in an owned simulator, or lease an explicitly selected one."""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path


def simctl(*arguments, json_result=False):
    result = subprocess.check_output(["xcrun", "simctl", *arguments], text=True)
    return json.loads(result) if json_result else result.strip()


@contextlib.contextmanager
def lease(identifier):
    root = Path.home() / "Library/Caches/OpenBikeComputer/simulator-leases"
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = root.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise RuntimeError("unsafe simulator lease directory")
    descriptor = os.open(root / (str(uuid.UUID(identifier)) + ".lock"), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
            raise RuntimeError("unsafe simulator lease file")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("selected simulator is already leased by another check") from error
        yield
    finally:
        os.close(descriptor)


def selected_type(platform):
    family = "iPhone" if platform == "ios" else "Apple Watch"
    fragment = ".iOS-" if platform == "ios" else ".watchOS-"
    runtimes = simctl("list", "runtimes", "--json", json_result=True)["runtimes"]
    sdk = "iphonesimulator" if platform == "ios" else "watchsimulator"
    sdk_version = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-version"], text=True).strip()
    def version(value):
        parts = tuple(int(component) for component in value.split("."))
        return parts + (0,) * (3 - len(parts))
    # An installed beta runtime can be newer than the selected Xcode toolchain.
    # Prefer the SDK's runtime, then the newest compatible older runtime.
    candidates = sorted((r for r in runtimes if r.get("isAvailable") and fragment in r["identifier"]
                         and version(r["version"]) <= version(sdk_version)),
                        key=lambda r: version(r["version"]), reverse=True)
    for runtime in candidates:
        device_types = [t for t in runtime.get("supportedDeviceTypes", []) if t.get("productFamily") == family]
        if device_types:
            return device_types[0]["identifier"], runtime["identifier"]
    raise RuntimeError(f"no available {platform} simulator runtime/device type compatible with SDK {sdk_version} is installed")


def create(platform):
    device, runtime = selected_type(platform)
    return simctl("create", "Bicino check " + str(uuid.uuid4()), device, runtime)


def run(platform, command, *, identifier=None):
    owned = identifier is None
    identifier = create(platform) if owned else str(uuid.UUID(identifier))
    print(f"SIMULATOR_SESSION owned={int(owned)} platform={platform} udid={identifier}", flush=True)
    child = None
    previous_handlers = {}
    def interrupted(signum, _frame):
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
        raise KeyboardInterrupt
    stack = contextlib.ExitStack()
    try:
        stack.enter_context(lease(identifier))
        for signum in (signal.SIGTERM, signal.SIGINT):
            previous_handlers[signum] = signal.signal(signum, interrupted)
        devices = simctl("list", "devices", "available", "--json", json_result=True)["devices"]
        fragment = ".iOS-" if platform == "ios" else ".watchOS-"
        matches = [d for runtime, group in devices.items() if fragment in runtime
                   for d in group if d["udid"].upper() == identifier.upper() and d.get("isAvailable")]
        if len(matches) != 1:
            raise RuntimeError("selected simulator is unavailable or belongs to the wrong platform")
        if matches[0].get("state") != "Booted":
            simctl("boot", identifier)
        simctl("bootstatus", identifier, "-b")
        environment = os.environ.copy()
        environment["BICINO_SIMULATOR_UDID"] = identifier
        child = subprocess.Popen([value.replace("{simulator}", identifier) for value in command], env=environment, start_new_session=True)
        return child.wait()
    finally:
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        try:
            if owned:
                # Cleanup may touch only the fresh simulator returned by create.
                subprocess.run(["xcrun", "simctl", "shutdown", identifier], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                subprocess.run(["xcrun", "simctl", "delete", identifier], check=True)
        finally:
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)
            stack.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=("ios", "watchos"))
    parser.add_argument("--simulator", default=os.environ.get("BICINO_SIMULATOR_UDID"))
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command and not args.check_only:
        parser.error("a command is required")
    try:
        if args.check_only:
            device, runtime = selected_type(args.platform)
            print(f"Simulator prerequisites available: {runtime} {device}")
            return 0
        return run(args.platform, command, identifier=args.simulator)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"Simulator session blocked: {error}", file=sys.stderr)
        return 69
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
