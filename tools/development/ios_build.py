#!/usr/bin/env python3
"""Build and validate iOS containers with exclusively leased per-worktree state."""
from __future__ import annotations

import contextlib
import fcntl
import os
import stat
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


@contextlib.contextmanager
def build_state(root):
    for path in (root, *root.parents):
        if path.is_symlink():
            raise RuntimeError("iOS build state must not traverse a symlink")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = root.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise RuntimeError("unsafe iOS build state directory")
    descriptor = os.open(root / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
            raise RuntimeError("unsafe iOS build state lease")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("another build owns this worktree's iOS build state") from error
        yield root
    finally:
        os.close(descriptor)


def build_containers(root):
    ios = ROOT / "ios-app"
    with build_state(root):
        print(f"IOS_BUILD_STATE derivedRoot={root}", flush=True)
        for configuration in ("Debug", "Release"):
            derived = root / configuration
            if derived.is_symlink():
                raise RuntimeError("configuration build state must not be a symlink")
            subprocess.run([str(ios / "scripts/xcodebuild-cli.sh"),
                "-project", "BikeComputer/BikeComputer.xcodeproj", "-scheme", "BikeComputer",
                "-configuration", configuration, "-destination", "generic/platform=iOS",
                "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO", "build"], cwd=ios, check=True)
            app = derived / f"Build/Products/{configuration}-iphoneos/BikeComputer.app"
            verifier = "verify-development-container.sh" if configuration == "Debug" else "verify-release-container.sh"
            subprocess.run(["bash", str(ios / "scripts" / verifier), str(app)], cwd=ios, check=True)
            if configuration == "Release" and b"Start Remote Debugging" in (app / "BikeComputer").read_bytes():
                raise RuntimeError("Release app contains Debug-only remote device settings")


def main():
    try:
        if os.environ.get("BICINO_FRESH_BUILD") == "1":
            with tempfile.TemporaryDirectory(prefix="bicino-ios-containers-") as temporary:
                build_containers(Path(temporary).resolve())
        else:
            build_containers(ROOT / "ios-app/DerivedData/development-checks")
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"iOS container validation failed: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
