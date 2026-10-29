"""Publish and consume verified firmware core entries as workflow artifacts.

The Actions cache is scoped to a branch and capped per repository, so cores
built on pull requests never warm other pull requests and five 1.75-inch cores
do not fit the cap. Workflow artifacts have neither limit. The firmware scope
on ``main`` publishes each verified core entry as an artifact; a pull request
whose cache misses restores that entry before building. Only artifacts that a
run of this repository's own ``main`` branch uploaded are consumed, and
``build_firmware.py`` still verifies every restored entry before using it.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import stat
import subprocess
import sys
import tarfile
from pathlib import Path

KEY_PATTERN = re.compile(r"[0-9a-f]{64}")
ENTRY_FILES = {"transport.json", "core"}


def parse_timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else None


def select_artifact(artifacts, *, name, repository_id, branch, now, max_age):
    """Return the newest non-expired artifact that a run of ``branch`` in this repository uploaded."""
    candidates = []
    for artifact in artifacts:
        run = artifact.get("workflow_run")
        if not isinstance(run, dict):
            continue
        created = parse_timestamp(artifact.get("created_at"))
        if (
            artifact.get("name") != name
            or artifact.get("expired") is not False
            or type(artifact.get("id")) is not int
            or type(run.get("id")) is not int
            or run.get("head_branch") != branch
            # A fork keeps its own repository id, so its artifacts never match.
            or run.get("head_repository_id") != repository_id
            or run.get("repository_id") != repository_id
            or created is None
        ):
            continue
        candidates.append((created, run["id"], artifact["id"]))
    if not candidates:
        return None
    created, run_id, artifact_id = max(candidates)
    return {
        "run_id": run_id,
        "artifact_id": artifact_id,
        "created_at": created.isoformat(),
        "fresh": now - created <= max_age,
    }


def list_artifacts(repository, name):
    output = subprocess.check_output(
        ["gh", "api", "--paginate", f"repos/{repository}/actions/artifacts?name={name}&per_page=100",
         "--jq", ".artifacts[]"],
        text=True,
    )
    return [json.loads(line) for line in output.splitlines() if line.strip()]


def outputs(values):
    return "".join(f"{key}={value}\n" for key, value in values.items())


def select(args):
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,200}", args.name):
        raise SystemExit("invalid artifact name")
    chosen = select_artifact(
        list_artifacts(args.repository, args.name), name=args.name, repository_id=args.repository_id,
        branch=args.branch, now=dt.datetime.now(dt.timezone.utc), max_age=dt.timedelta(days=args.max_age_days),
    )
    if chosen is None:
        return outputs({"found": "false", "fresh": "false", "run-id": "", "artifact-id": "", "created-at": ""})
    return outputs({"found": "true", "fresh": "true" if chosen["fresh"] else "false", "run-id": chosen["run_id"],
                    "artifact-id": chosen["artifact_id"], "created-at": chosen["created_at"]})


def _entry_members(archive: tarfile.TarFile):
    """Validate that an archive holds exactly one shared core entry and return its key."""
    keys = set()
    for member in archive.getmembers():
        parts = Path(member.name).parts
        if (
            not parts or member.name.startswith("/") or ".." in parts or "." in parts[1:]
            or not (member.isdir() or member.isreg())
            or not KEY_PATTERN.fullmatch(parts[0])
            or (len(parts) > 1 and parts[1] not in ENTRY_FILES)
            or (parts[1:2] == ("transport.json",) and (len(parts) != 2 or not member.isreg()))
            or (parts[1:2] == ("core",) and (len(parts) > 3 or (len(parts) == 2 and not member.isdir())))
            or (len(parts) == 1 and not member.isdir())
        ):
            raise SystemExit(f"core artifact contains an unexpected member: {member.name}")
        keys.add(parts[0])
    if len(keys) != 1:
        raise SystemExit("core artifact must contain exactly one core entry")
    return keys.pop()


def _seal(path: Path):
    for child in sorted(path.rglob("*"), reverse=True):
        if child.is_symlink():
            raise SystemExit(f"core entry contains a symlink: {child}")
        child.chmod(0o555 if child.is_dir() else 0o444)
    path.chmod(0o555)


def install(args):
    root = Path(args.root)
    if root.exists() and (root.is_symlink() or not root.is_dir()):
        raise SystemExit("core cache root is not a directory")
    for directory in (root.parent.parent, root.parent, root):
        directory.mkdir(parents=True, exist_ok=True)
        directory.chmod(0o755)
    with tarfile.open(args.archive, "r:") as archive:
        key = _entry_members(archive)
        destination = root / key
        if os.path.lexists(destination):
            return outputs({"installed": "false", "core-input-key": key})
        archive.extractall(root, filter="data")
    if {child.name for child in destination.iterdir()} != ENTRY_FILES:
        raise SystemExit("core entry is incomplete")
    _seal(destination)
    return outputs({"installed": "true", "core-input-key": key})


def pack(args):
    if not KEY_PATTERN.fullmatch(args.key):
        raise SystemExit("invalid core input key")
    entry = Path(args.root) / args.key
    if entry.is_symlink() or not entry.is_dir() or {child.name for child in entry.iterdir()} != ENTRY_FILES:
        raise SystemExit("verified core entry is missing or incomplete")
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    # Store modes only: the receiving runner owns whatever it extracts.
    with tarfile.open(output, "w:") as archive:
        for path in sorted(entry.rglob("*")):
            if path.is_symlink() or not (path.is_dir() or path.is_file()):
                raise SystemExit(f"core entry contains an unsupported file: {path}")
        archive.add(entry, arcname=args.key, recursive=True)
    return outputs({"archive": str(output), "bytes": output.stat().st_size})


def identity(args):
    manifest_path = Path(args.project) / ".pio/open-bike-build/builds" / args.environment / "current.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    key = manifest.get("coreInputKey")
    if (
        manifest.get("environment") != args.environment or manifest.get("uploadEligible") is not True
        or not isinstance(key, str) or not KEY_PATTERN.fullmatch(key)
    ):
        raise SystemExit("requires a successful attested build manifest with a core identity")
    label = manifest.get("coreCache")
    return outputs({"core-input-key": key, "core-cache": label if isinstance(label, str) and label else "unknown"})


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    select_parser = commands.add_parser("select", help="find the newest core entry published from the trusted branch")
    select_parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    select_parser.add_argument("--repository-id", type=int, required=True)
    select_parser.add_argument("--name", required=True)
    select_parser.add_argument("--branch", default="main")
    select_parser.add_argument("--max-age-days", type=int, default=7)
    select_parser.set_defaults(run=select)
    install_parser = commands.add_parser("install", help="place a downloaded core entry into the shared cache root")
    install_parser.add_argument("--archive", required=True)
    install_parser.add_argument("--root", required=True, help="cores-v1/<environment> directory")
    install_parser.set_defaults(run=install)
    pack_parser = commands.add_parser("pack", help="archive one verified core entry for upload")
    pack_parser.add_argument("--root", required=True)
    pack_parser.add_argument("--key", required=True)
    pack_parser.add_argument("--output", required=True)
    pack_parser.set_defaults(run=pack)
    identity_parser = commands.add_parser("identity", help="read the core identity of the attested build")
    identity_parser.add_argument("--project", default="esp32")
    identity_parser.add_argument("--environment", required=True)
    identity_parser.set_defaults(run=identity)
    args = parser.parse_args(argv)
    sys.stdout.write(args.run(args))
    return 0


if __name__ == "__main__":
    sys.exit(main())
