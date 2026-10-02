#!/usr/bin/env python3
"""Read extracted ride-diagnostics JSONL without modifying it.

This is a viewer, not a substitute for the existing bundle/checksum validator.
It never estimates mA, watt-hours, component current, or battery runtime.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any, Iterable


def decode_state(state: str) -> dict[str, str | None]:
    if not isinstance(state, str) or len(state) > 256:
        raise ValueError("invalid or oversized sleep-audit state")
    decoded: dict[str, str | None] = {}
    for field in state.split(";"):
        key, separator, value = field.partition("=")
        if not separator or not key or key in decoded:
            raise ValueError("invalid or duplicate sleep-audit state key")
        decoded[key] = None if value in ("unknown", "??") else value
    return decoded


def summarize(records: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    attempts: dict[str, dict[str, Any]] = {}
    for record in records:
        if (record.get("source") != "firmware" or record.get("category") != "power"
                or record.get("event") != "sleep_audit"):
            continue
        fields = record.get("fields")
        if not isinstance(fields, dict) or type(fields.get("schemaVersion")) is not int:
            raise ValueError("missing sleep-audit schema")
        if fields["schemaVersion"] != 1:
            raise ValueError("unsupported sleep-audit schema")
        phase, domain, attempt_id = (fields.get(key) for key in ("phase", "domain", "attemptId"))
        if not all(isinstance(value, str) and len(value) <= 64
                   for value in (phase, domain, attempt_id)):
            raise ValueError("invalid sleep-audit identity")
        if type(fields.get("available")) is not bool:
            raise ValueError("invalid sleep-audit availability")
        # An absent retained request must not join unrelated cold boots.
        key = attempt_id
        if key == "none":
            key = f"unmatched:{record.get('processId', '')}:{fields.get('bootSequence', '')}"
        attempt = attempts.setdefault(key, {"attemptId": attempt_id, "observations": []})
        state = decode_state(fields.get("state"))
        observation = {"phase": phase, "domain": domain,
                       "available": fields["available"], "state": state,
                       "bootSequence": fields.get("bootSequence"),
                       "sequence": record.get("sequence")}
        attempt["observations"].append(observation)
        if phase == "wake" and domain == "resume":
            attempt["classification"] = state.get("classification")
            attempt["entryToEarlyBootMs"] = (
                int(state["interval_ms"])
                if state.get("interval_valid") == "1" and state.get("interval_ms") is not None
                else None)
    for attempt in attempts.values():
        attempt.setdefault("classification", "request_without_correlated_wake")
        attempt.setdefault("entryToEarlyBootMs", None)
        attempt["currentMeasurement"] = "unsupported"
    return list(attempts.values())


def read_records(paths: list[Path]) -> Iterable[dict[str, Any]]:
    files: set[Path] = set()
    for path in paths:
        if path.is_dir():
            files.update(child.resolve() for child in path.rglob("*.jsonl") if child.is_file())
        elif path.is_file():
            files.add(path.resolve())
        else:
            raise ValueError(f"not a file or directory: {path}")
    if not files:
        raise ValueError("no JSONL files found")
    for path in sorted(files):
        with path.open(encoding="utf-8") as stream:
            for number, line in enumerate(stream, 1):
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError as error:
                    # Do not silently turn a truncated/corrupt log into a
                    # successful-looking audit. The bundle validator can salvage it.
                    raise ValueError(f"invalid JSON at {path}:{number}") from error
                if not isinstance(record, dict):
                    raise ValueError(f"non-object record at {path}:{number}")
                yield record


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path, help="extracted JSONL files or directories")
    args = parser.parse_args()
    try:
        print(json.dumps(summarize(read_records(args.paths)), indent=2, ensure_ascii=True))
    except (OSError, UnicodeError, ValueError) as error:
        print(f"sleep audit: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
