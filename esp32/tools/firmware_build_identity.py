from __future__ import annotations

import re
import subprocess
from pathlib import Path
from typing import Iterable


FULL_GIT_SHA = re.compile(r"[0-9a-f]{40}")


def firmware_git_identity(
    repo_root: Path, *, allowed_untracked_paths: Iterable[Path] = ()
) -> str:
    """Return a release-grade source identity, or a fail-closed dirty marker."""
    try:
        git_sha = subprocess.check_output(
            ["git", "rev-parse", "--verify", "HEAD"],
            cwd=repo_root,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if not FULL_GIT_SHA.fullmatch(git_sha):
            return "unidentified"
        tracked = subprocess.check_output(
            ["git", "ls-files", "-v", "-z"],
            cwd=repo_root,
            stderr=subprocess.DEVNULL,
        )
        for entry in tracked.split(b"\0"):
            if not entry:
                continue
            marker = chr(entry[0])
            # `git status` deliberately trusts both of these index hints, so
            # either can hide working-tree bytes from the dirty-tree gate.
            if marker == "S" or marker.islower():
                return f"dirty-{git_sha}"
        dirty = subprocess.check_output(
            [
                "git",
                "status",
                "--porcelain=v1",
                "-z",
                "--untracked-files=normal",
            ],
            cwd=repo_root,
            stderr=subprocess.DEVNULL,
        )
        allowed = {
            path.resolve().relative_to(repo_root.resolve()).as_posix()
            for path in allowed_untracked_paths
        }
        entries = [entry for entry in dirty.split(b"\0") if entry]
        for entry in entries:
            decoded = entry.decode("utf-8", errors="surrogateescape")
            if decoded.startswith("?? ") and decoded[3:] in allowed:
                continue
            return f"dirty-{git_sha}"
        return git_sha
    except (OSError, subprocess.CalledProcessError):
        return "unidentified"
