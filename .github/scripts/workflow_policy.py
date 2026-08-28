#!/usr/bin/env python3
"""Enforce immutable third-party identities in GitHub workflow YAML."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
from typing import Iterable


_ACTION_SHA = re.compile(
    r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*@[0-9a-f]{40}$"
)
_DOCKER_DIGEST = re.compile(
    r"^docker://[A-Za-z0-9._/-]+@sha256:[0-9a-f]{64}$"
)
_USES_KEY = re.compile(r"^uses\s*:\s*(.*)$")
_BLOCK_SCALAR = re.compile(
    r"^(?:-\s+)?[A-Za-z0-9_.-]+\s*:\s*[>|](?:[+-]?[1-9]?|[1-9]?[+-]?)?\s*(?:#.*)?$"
)
_NONCANONICAL_USES_KEY = re.compile(
    r"(?:^|[\[{,]\s*|-\s+)[\"']?uses[\"']?\s*:"
)


@dataclass(frozen=True)
class WorkflowUse:
    path: Path
    line: int
    value: str
    comment: str | None


def workflow_policy_paths(root: Path) -> Iterable[Path]:
    for directory in (root / ".github" / "workflows", root / ".github" / "actions"):
        if not directory.is_dir():
            continue
        for pattern in ("*.yml", "*.yaml"):
            yield from sorted(directory.rglob(pattern))


def _yaml_scalar_and_comment(raw: str) -> tuple[str, str | None]:
    quote: str | None = None
    escaped = False
    comment_at: int | None = None
    for index, character in enumerate(raw):
        if quote == '"':
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = None
            continue
        if quote == "'":
            if character == quote:
                if index + 1 < len(raw) and raw[index + 1] == quote:
                    continue
                quote = None
            continue
        if character in {'"', "'"}:
            quote = character
            continue
        if character == "#" and (index == 0 or raw[index - 1].isspace()):
            comment_at = index
            break

    scalar = raw[:comment_at].strip() if comment_at is not None else raw.strip()
    comment = raw[comment_at + 1 :].strip() if comment_at is not None else None
    if len(scalar) >= 2 and scalar[0] == scalar[-1] and scalar[0] in {'"', "'"}:
        scalar = scalar[1:-1]
    return scalar, comment or None


def collect_workflow_uses(path: Path) -> list[WorkflowUse]:
    results: list[WorkflowUse] = []
    block_scalar_indent: int | None = None
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        content = raw_line.lstrip()
        indentation = len(raw_line) - len(content)
        if block_scalar_indent is not None:
            if not content or indentation > block_scalar_indent:
                continue
            block_scalar_indent = None
        if not content or content.startswith("#"):
            continue
        if _BLOCK_SCALAR.fullmatch(content):
            block_scalar_indent = indentation
            continue
        if content.startswith("- "):
            content = content[2:].lstrip()
        match = _USES_KEY.fullmatch(content)
        if match is None:
            if _NONCANONICAL_USES_KEY.search(content):
                results.append(
                    WorkflowUse(
                        path=path,
                        line=line_number,
                        value=content,
                        comment=None,
                    )
                )
            continue
        value, comment = _yaml_scalar_and_comment(match.group(1))
        results.append(
            WorkflowUse(
                path=path,
                line=line_number,
                value=value,
                comment=comment,
            )
        )
    return results


def validate_workflow_use(workflow_use: WorkflowUse) -> str | None:
    value = workflow_use.value
    if value.startswith("./"):
        return None
    if not (_ACTION_SHA.fullmatch(value) or _DOCKER_DIGEST.fullmatch(value)):
        return "external uses value must be pinned to a full commit SHA or image digest"
    if workflow_use.comment is None:
        return "pinned external uses value must retain a human-readable version comment"
    return None


def validate_repository(root: Path) -> list[str]:
    errors: list[str] = []
    for path in workflow_policy_paths(root):
        for workflow_use in collect_workflow_uses(path):
            error = validate_workflow_use(workflow_use)
            if error is not None:
                errors.append(
                    f"{path.relative_to(root)}:{workflow_use.line}: {error}: "
                    f"{workflow_use.value!r}"
                )
    return errors


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    errors = validate_repository(root)
    if errors:
        print("\n".join(errors))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
