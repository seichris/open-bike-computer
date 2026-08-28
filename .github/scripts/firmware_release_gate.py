#!/usr/bin/env python3
"""Validate an unprivileged firmware candidate before privileged publication."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import sys
import tempfile


EXPECTED_WORKFLOW_NAME = "Firmware Release Candidate"
EXPECTED_ARTIFACTS = {
    "firmware-WAVESHARE_AMOLED_175",
    "firmware-WAVESHARE_AMOLED_206",
}
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
SHA256_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
RELEASE_TAG = re.compile(
    r"^v[0-9]+\.[0-9]+\.[0-9]+(?:[.-][A-Za-z0-9][A-Za-z0-9.-]*)?$"
)
WORKFLOW_PATH = re.compile(r"^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$")
MAX_EVENT_BYTES = 2 * 1024 * 1024
MAX_API_BYTES = 1024 * 1024
MAX_ARTIFACT_BYTES = 96 * 1024 * 1024


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"JSON contains duplicate key: {key}")
        value[key] = item
    return value


def _load_json(path: pathlib.Path, maximum_bytes: int) -> dict[str, object]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"JSON input is missing or unsafe: {path}")
    encoded = path.read_bytes()
    if not encoded or len(encoded) > maximum_bytes:
        raise ValueError(f"JSON input has an invalid size: {path}")
    try:
        value = json.loads(
            encoded.decode("utf-8"), object_pairs_hook=_reject_duplicate_keys
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"JSON input is invalid: {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"JSON input must contain an object: {path}")
    return value


def _canonical(value: object) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")


def _write_atomic(path: pathlib.Path, value: object) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"output path is unsafe: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as stream:
            temporary = stream.name
            stream.write(_canonical(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            pathlib.Path(temporary).unlink(missing_ok=True)


def _positive_int(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ValueError(f"{label} must be a positive integer")
    return value


def _object(value: object, label: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    return value


def validate_gate(
    event: dict[str, object],
    workflow: dict[str, object],
    artifacts: dict[str, object],
    *,
    repository: str,
    expected_workflow_path: str,
) -> dict[str, object]:
    """Return a canonical gate receipt or reject the workflow-run boundary."""

    if REPOSITORY.fullmatch(repository) is None:
        raise ValueError("expected repository is invalid")
    if WORKFLOW_PATH.fullmatch(expected_workflow_path) is None:
        raise ValueError("expected workflow path is invalid")
    if event.get("action") != "completed":
        raise ValueError("candidate workflow event is not completed")
    event_repository = _object(event.get("repository"), "event repository")
    if event_repository.get("full_name") != repository:
        raise ValueError("candidate event repository does not match")

    workflow_id = _positive_int(workflow.get("id"), "expected workflow ID")
    if (
        workflow.get("name") != EXPECTED_WORKFLOW_NAME
        or workflow.get("path") != expected_workflow_path
        or workflow.get("state") != "active"
    ):
        raise ValueError("expected candidate workflow identity does not match")

    run = _object(event.get("workflow_run"), "candidate workflow run")
    run_id = _positive_int(run.get("id"), "candidate run ID")
    run_repository = _object(
        run.get("head_repository"), "candidate head repository"
    )
    event_path = str(run.get("path", "")).split("@", 1)[0]
    tag = run.get("head_branch")
    git_sha = run.get("head_sha")
    if (
        run.get("workflow_id") != workflow_id
        or run.get("name") != EXPECTED_WORKFLOW_NAME
        or event_path != expected_workflow_path
        or run.get("event") != "push"
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
        or run.get("run_attempt") != 1
        or run_repository.get("full_name") != repository
        or not isinstance(tag, str)
        or RELEASE_TAG.fullmatch(tag) is None
        or not isinstance(git_sha, str)
        or FULL_SHA.fullmatch(git_sha) is None
    ):
        raise ValueError("candidate workflow run identity does not match")

    artifact_values = artifacts.get("artifacts")
    if not isinstance(artifact_values, list):
        raise ValueError("candidate artifact response has no artifact list")
    if artifacts.get("total_count") != len(artifact_values):
        raise ValueError("candidate artifact response is incomplete")
    inventory: list[dict[str, object]] = []
    names: set[str] = set()
    ids: set[int] = set()
    for raw_artifact in artifact_values:
        artifact = _object(raw_artifact, "candidate artifact")
        name = artifact.get("name")
        if name not in EXPECTED_ARTIFACTS:
            continue
        artifact_id = _positive_int(artifact.get("id"), "candidate artifact ID")
        size = artifact.get("size_in_bytes")
        digest = artifact.get("digest")
        artifact_run = _object(
            artifact.get("workflow_run"), "candidate artifact workflow run"
        )
        if (
            name in names
            or artifact_id in ids
            or isinstance(size, bool)
            or not isinstance(size, int)
            or size <= 0
            or size > MAX_ARTIFACT_BYTES
            or not isinstance(digest, str)
            or SHA256_DIGEST.fullmatch(digest) is None
            or artifact.get("expired") is not False
            or artifact_run.get("id") != run_id
            or artifact_run.get("head_sha") != git_sha
        ):
            raise ValueError("candidate artifact identity does not match")
        names.add(name)
        ids.add(artifact_id)
        inventory.append(
            {
                "id": artifact_id,
                "name": name,
                "size": size,
                "digest": digest,
            }
        )
    if names != EXPECTED_ARTIFACTS:
        raise ValueError("candidate artifact set is not exact")

    return {
        "schemaVersion": 1,
        "repository": repository,
        "workflowId": workflow_id,
        "candidateRunId": run_id,
        "candidateRunAttempt": 1,
        "tag": tag,
        "gitSha": git_sha,
        "artifacts": sorted(inventory, key=lambda item: str(item["name"])),
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", type=pathlib.Path, required=True)
    parser.add_argument("--workflow", type=pathlib.Path, required=True)
    parser.add_argument("--artifacts", type=pathlib.Path, required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--expected-workflow-path", required=True)
    parser.add_argument("--github-output", type=pathlib.Path, required=True)
    parser.add_argument("--output-receipt", type=pathlib.Path, required=True)
    args = parser.parse_args(argv)
    try:
        receipt = validate_gate(
            _load_json(args.event, MAX_EVENT_BYTES),
            _load_json(args.workflow, MAX_API_BYTES),
            _load_json(args.artifacts, MAX_API_BYTES),
            repository=args.repository,
            expected_workflow_path=args.expected_workflow_path,
        )
        _write_atomic(args.output_receipt, receipt)
        if args.github_output.is_symlink() or not args.github_output.is_file():
            raise ValueError("GitHub output path is missing or unsafe")
        with args.github_output.open("a", encoding="utf-8", newline="\n") as stream:
            stream.write(f"candidate_run_id={receipt['candidateRunId']}\n")
            stream.write(f"release_tag={receipt['tag']}\n")
            stream.write(f"git_sha={receipt['gitSha']}\n")
        print(json.dumps(receipt, sort_keys=True))
        return 0
    except (OSError, ValueError) as error:
        print(f"firmware release gate failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
