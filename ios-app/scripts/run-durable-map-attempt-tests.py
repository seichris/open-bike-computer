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
    manager = ios / "BikeComputer/BikeComputer/Managers/OfflineMapManager.swift"
    text = manager.read_text()
    start = "@MainActor\nfinal class DurableMapDownloadCoordinator:"
    end = "\nfinal class OfflineMapPackDownloader:"
    if text.count(start) != 1 or text.count(end) != 1:
        raise RuntimeError("production coordinator extraction boundary changed")
    coordinator = text[text.index(start):text.index(end)]
    # The dynamic tests exercise the private resume admission policy. Also
    # ensure actual download creation uses it rather than bypassing that policy.
    if coordinator.count("if allowResume, let data = resumeData(for: descriptor)") != 1:
        raise RuntimeError("production task creation bypasses resume ownership policy")
    fixtures = ios / "tests/durable-download-host"
    source = "\n".join([
        (fixtures / "Support.swift").read_text(), coordinator,
        (fixtures / "AttemptTests.swift").read_text(),
    ])
    if platform.system() == "Darwin":
        compiler = ["xcrun", "swiftc"]
    else:
        swiftc = shutil.which("swiftc")
        if swiftc is None:
            raise RuntimeError("Swift 6 compiler is required")
        compiler = [swiftc]
    with tempfile.TemporaryDirectory(prefix="bicino-download-attempts-") as temporary:
        directory = Path(temporary)
        swift = directory / "AttemptTests.swift"
        binary = directory / "attempt-tests"
        swift.write_text(source)
        subprocess.run(compiler + ["-swift-version", "6", "-strict-concurrency=complete",
            "-parse-as-library", str(swift), "-o", str(binary)], check=True, timeout=180)
        subprocess.run([str(binary)], check=True, timeout=60)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Download attempt regression failure: {error}", file=sys.stderr)
        sys.exit(1)
