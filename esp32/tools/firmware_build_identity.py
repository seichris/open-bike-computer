from __future__ import annotations

import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


FULL_GIT_SHA = re.compile(r"[0-9a-f]{40}")
SOURCE_DATE_EPOCH = re.compile(r"0|[1-9][0-9]*")


def build_timestamp_from_source_date_epoch(source_date_epoch: str) -> str:
    """Return the canonical UTC firmware timestamp for SOURCE_DATE_EPOCH."""
    if SOURCE_DATE_EPOCH.fullmatch(source_date_epoch) is None:
        raise ValueError(
            "SOURCE_DATE_EPOCH must be a canonical nonnegative integer"
        )
    try:
        timestamp = datetime.fromtimestamp(int(source_date_epoch), timezone.utc)
    except (OverflowError, OSError, ValueError) as error:
        raise ValueError(
            "SOURCE_DATE_EPOCH is outside the supported UTC range"
        ) from error
    return timestamp.strftime("%Y-%m-%dT%H:%M:%SZ")


def git_commit_source_date_epoch(repo_root: Path, git_sha: str) -> str:
    """Return the exact commit time for ``git_sha`` as SOURCE_DATE_EPOCH."""
    if FULL_GIT_SHA.fullmatch(git_sha) is None:
        raise ValueError("a full Git commit SHA is required for SOURCE_DATE_EPOCH")
    try:
        source_date_epoch = subprocess.check_output(
            [
                "git",
                "--no-replace-objects",
                "show",
                "--no-patch",
                "--format=%ct",
                git_sha,
            ],
            cwd=repo_root,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError(
            f"could not resolve SOURCE_DATE_EPOCH for Git commit {git_sha}"
        ) from error
    build_timestamp_from_source_date_epoch(source_date_epoch)
    return source_date_epoch


def git_head_identity(repo_root: Path) -> str:
    """Return the repository's exact HEAD commit SHA."""
    try:
        git_sha = subprocess.check_output(
            ["git", "rev-parse", "--verify", "HEAD"],
            cwd=repo_root,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError("could not resolve the repository HEAD commit") from error
    if FULL_GIT_SHA.fullmatch(git_sha) is None:
        raise ValueError("repository HEAD is not a full Git commit SHA")
    return git_sha


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
