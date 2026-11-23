#!/usr/bin/env python3
"""Pull and verify a graph without changing the running service."""

import argparse
import fcntl
import json
import os
import re
import shlex
import shutil
import subprocess
from pathlib import Path

from build_graph import ARCHIVE_NAME, IMAGE, archive_tile_count, file_identity


def verify_archive(archive, expected):
    if file_identity(archive) != {"bytes": expected["bytes"], "sha256": expected["sha256"]}:
        raise ValueError(f"Archive size or SHA-256 differs from the approved manifest: {archive}")
    if archive_tile_count(archive) != expected["tiles"]:
        raise ValueError("Valhalla tile count differs from the approved manifest")


def stage(root, manifest, source, reserve, bandwidth, ssh_config=None, *, compress_transfer=False):
    root.mkdir(parents=True, exist_ok=True)
    expected = manifest["archive"]
    digest = expected["sha256"]
    target = root / digest
    partial = root / f".{digest}.incoming"
    with (root / ".install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if target.exists():
            verify_archive(target / ARCHIVE_NAME, expected)
            return target
        partial.mkdir(mode=0o700, exist_ok=True)
        destination = partial / ARCHIVE_NAME
        already_allocated = destination.stat().st_blocks * 512 if destination.exists() else 0
        required = max(0, expected["bytes"] - already_allocated)
        if shutil.disk_usage(root).free < required + reserve:
            raise ValueError("Staging the candidate would violate the required disk reserve")
        if source is None:
            if not destination.is_file():
                raise ValueError("Expected an existing incoming archive")
        else:
            ssh = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes"]
            if ssh_config is not None:
                ssh.extend(["-F", str(ssh_config)])
            compression = ["--compress", "--compress-choice=zstd"] if compress_transfer else []
            subprocess.run(
                [
                    "rsync", "--partial", "--inplace", "--ignore-times", *compression, f"--bwlimit={bandwidth}",
                    f"--max-size={expected['bytes']}",
                    "-e", shlex.join(ssh),
                    "--", source, str(destination),
                ],
                check=True,
            )
        if shutil.disk_usage(root).free < reserve:
            raise ValueError("Shared disk free space fell below the reserve during transfer")
        try:
            verify_archive(destination, expected)
        except (ValueError, OSError):
            # Discard only the invalid staging copy so a retry starts clean.
            destination.unlink(missing_ok=True)
            raise
        destination.chmod(0o444)
        with destination.open("rb") as archive:
            os.fsync(archive.fileno())
        receipt = partial / "manifest.json"
        with receipt.open("w") as stream:
            json.dump(manifest, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        receipt.chmod(0o444)
        partial.chmod(0o755)
        partial.rename(target)
        descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True, help="Shared directory of graph digests")
    transfer = parser.add_mutually_exclusive_group(required=True)
    transfer.add_argument("--source", help="Builder's rsync source, user@host:/path/archive")
    transfer.add_argument("--verify-incoming", action="store_true", help="Verify an archive already transferred into the incoming directory")
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--expected-sha256", required=True, help="Archive digest from the reviewed release")
    parser.add_argument("--ssh-config", type=Path, help="Isolated SSH configuration for pulling from the builder")
    parser.add_argument("--reserve-bytes", type=int, default=50_000_000_000)
    parser.add_argument("--bandwidth-kib", type=int, default=20_480)
    parser.add_argument("--compress-transfer", action="store_true", help="Use rsync Zstandard compression")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    expected = manifest["archive"]
    if (
        manifest["schema"] != "bicino-valhalla-graph-v1"
        or manifest["builder"]["image"] != IMAGE
        or expected["name"] != ARCHIVE_NAME
        or not re.fullmatch(r"[0-9a-f]{64}", args.expected_sha256)
        or args.expected_sha256 != expected["sha256"]
        or not isinstance(expected["bytes"], int)
        or expected["bytes"] <= 0
        or args.reserve_bytes < 0
        or args.bandwidth_kib <= 0
    ):
        parser.error("Invalid manifest, approved digest, disk reserve, or transfer limit")
    print(stage(
        args.root, manifest, args.source, args.reserve_bytes, args.bandwidth_kib, args.ssh_config,
        compress_transfer=args.compress_transfer,
    ))


if __name__ == "__main__":
    main()
