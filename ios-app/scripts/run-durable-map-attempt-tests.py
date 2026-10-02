#!/usr/bin/env python3
"""Compile the exact production download coordinator with controlled delegates.

The stand-ins isolate unrelated app models and unsigned networking, not the
coordinator, its continuation handling, ownership persistence, or file effects.
This supplements, rather than replaces, the full Apple navigation test suite.
"""
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile


def main() -> None:
    ios = Path(__file__).resolve().parents[1]
    coordinator = ios / "BikeComputer/BikeComputer/Managers/DurableMapDownloadCoordinator.swift"
    fixtures = ios / "tests/durable-download-host"
    if platform.system() == "Darwin":
        compiler = ["xcrun", "swiftc"]
    else:
        swiftc = shutil.which("swiftc")
        if swiftc is None:
            raise RuntimeError("Swift 6 compiler is required")
        compiler = [swiftc]
    with tempfile.TemporaryDirectory(prefix="bicino-download-attempts-") as temporary:
        directory = Path(temporary)
        binary = directory / "attempt-tests"
        subprocess.run(compiler + ["-swift-version", "6", "-strict-concurrency=complete",
            "-whole-module-optimization", "-Xfrontend", "-disable-access-control", "-parse-as-library",
            str(coordinator), str(fixtures / "Support.swift"), str(fixtures / "AttemptTests.swift"),
            "-o", str(binary)], check=True, timeout=180)
        subprocess.run([str(binary)], check=True, timeout=60)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Download attempt regression failure: {error}", file=sys.stderr)
        sys.exit(1)
