#!/usr/bin/env python3
"""Validate a five-sample warm runtime handoff against its reviewed baseline."""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import re
import statistics
import sys

from firmware_runtime import FirmwareRuntimeError
from refresh_firmware_runtime import _canonical


PREFIX = "FIRMWARE_RUNTIME_CHECK "
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
FIELDS = {
    "schema",
    "target",
    "lockSetId",
    "bootstrapMs",
    "sharedMs",
    "hydrationMs",
    "verificationMs",
}
TIMINGS = ("bootstrapMs", "sharedMs", "hydrationMs", "verificationMs")


def _load_baseline(path: pathlib.Path, target: str) -> tuple[str, dict[str, object]]:
    if path.is_symlink() or not path.is_file():
        raise FirmwareRuntimeError("runtime performance baseline is missing or unsafe")
    try:
        value = json.loads(path.read_bytes())
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise FirmwareRuntimeError(f"runtime performance baseline is invalid: {error}") from error
    if (
        not isinstance(value, dict)
        or set(value) != {"schema", "lockSetId", "targets"}
        or value.get("schema") != 1
        or not isinstance(value.get("lockSetId"), str)
        or SAFE_ID.fullmatch(value["lockSetId"]) is None
        or not isinstance(value.get("targets"), dict)
        or path.read_bytes() != _canonical(value)
    ):
        raise FirmwareRuntimeError("runtime performance baseline contract is invalid")
    record = value["targets"].get(target)
    if (
        not isinstance(record, dict)
        or set(record)
        != {
            "baselineSource",
            "maxRegressionPercent",
            "runner",
            "sampleCount",
            "warmHandoffMedianMs",
        }
        or record.get("sampleCount") != 5
        or record.get("maxRegressionPercent") != 20
        or not isinstance(record.get("warmHandoffMedianMs"), int)
        or isinstance(record["warmHandoffMedianMs"], bool)
        or record["warmHandoffMedianMs"] <= 0
        or not all(isinstance(record.get(field), str) and record[field] for field in ("baselineSource", "runner"))
    ):
        raise FirmwareRuntimeError(f"runtime performance target baseline is invalid: {target}")
    return value["lockSetId"], record


def _parse_samples(path: pathlib.Path, target: str, lock_set_id: str) -> list[dict[str, int]]:
    if path.is_symlink() or not path.is_file():
        raise FirmwareRuntimeError("runtime performance samples are missing or unsafe")
    samples = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if not raw_line.startswith(PREFIX):
            if raw_line.strip():
                raise FirmwareRuntimeError("runtime performance log contains unexpected output")
            continue
        fields: dict[str, str] = {}
        for item in raw_line.removeprefix(PREFIX).split():
            if item.count("=") != 1:
                raise FirmwareRuntimeError("runtime performance sample field is invalid")
            key, value = item.split("=", 1)
            if key in fields:
                raise FirmwareRuntimeError("runtime performance sample repeats a field")
            fields[key] = value
        if set(fields) != FIELDS or fields["schema"] != "1":
            raise FirmwareRuntimeError("runtime performance sample schema is invalid")
        if fields["target"] != target or fields["lockSetId"] != lock_set_id:
            raise FirmwareRuntimeError("runtime performance sample identity changed")
        timings: dict[str, int] = {}
        for field in TIMINGS:
            try:
                timings[field] = int(fields[field])
            except ValueError as error:
                raise FirmwareRuntimeError("runtime performance timing is invalid") from error
            if timings[field] < 0:
                raise FirmwareRuntimeError("runtime performance timing is negative")
        if timings["bootstrapMs"] < sum(timings[field] for field in TIMINGS[1:]):
            raise FirmwareRuntimeError("runtime performance phases exceed total bootstrap time")
        samples.append(timings)
    if len(samples) != 5:
        raise FirmwareRuntimeError("runtime performance gate requires exactly five samples")
    return samples


def check_performance(
    baseline_path: pathlib.Path,
    samples_path: pathlib.Path,
    target: str,
) -> dict[str, object]:
    lock_set_id, baseline = _load_baseline(baseline_path, target)
    samples = _parse_samples(samples_path, target, lock_set_id)
    medians = {
        field: int(statistics.median(sample[field] for sample in samples))
        for field in TIMINGS
    }
    maximum = math.floor(
        baseline["warmHandoffMedianMs"]
        * (100 + baseline["maxRegressionPercent"])
        / 100
    )
    if medians["bootstrapMs"] > maximum:
        raise FirmwareRuntimeError(
            "warm runtime handoff median regressed beyond the reviewed 20% limit: "
            f"{medians['bootstrapMs']}ms > {maximum}ms"
        )
    return {
        "schema": 1,
        "target": target,
        "lockSetId": lock_set_id,
        "sampleCount": 5,
        "samples": samples,
        "medians": medians,
        "baselineMs": baseline["warmHandoffMedianMs"],
        "maximumMs": maximum,
        "passed": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=pathlib.Path, required=True)
    parser.add_argument("--samples", type=pathlib.Path, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        result = check_performance(args.baseline, args.samples, args.target)
        if args.output.is_symlink() or (args.output.exists() and not args.output.is_file()):
            raise FirmwareRuntimeError("runtime performance output is unsafe")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(_canonical(result))
        print(json.dumps(result, sort_keys=True))
        return 0
    except (FirmwareRuntimeError, OSError, json.JSONDecodeError) as error:
        print(f"runtime performance gate failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
