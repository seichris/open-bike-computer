from __future__ import annotations

import json
from pathlib import Path
from typing import Any


class DuplicateJSONKeyError(ValueError):
    pass


MAXIMUM_JSON_NESTING = 64


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateJSONKeyError(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


def _require_bounded_nesting(value: object, *, description: str) -> None:
    pending: list[tuple[object, int]] = [(value, 0)]
    while pending:
        current, depth = pending.pop()
        if not isinstance(current, (dict, list)):
            continue
        if depth >= MAXIMUM_JSON_NESTING:
            raise ValueError(
                f"{description} exceeds maximum JSON nesting"
            )
        children = current.values() if isinstance(current, dict) else current
        pending.extend((child, depth + 1) for child in children)


def loads_strict_json(data: str | bytes, *, description: str) -> object:
    try:
        if isinstance(data, bytes):
            data = data.decode("utf-8")
        document = json.loads(data, object_pairs_hook=_unique_object)
    except (
        UnicodeDecodeError,
        json.JSONDecodeError,
        DuplicateJSONKeyError,
        RecursionError,
    ) as exc:
        raise ValueError(f"{description} is unreadable: {exc}") from exc
    _require_bounded_nesting(document, description=description)
    return document


def load_strict_json(path: Path, *, description: str) -> object:
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise ValueError(f"{description} is unreadable: {exc}") from exc
    return loads_strict_json(data, description=description)
