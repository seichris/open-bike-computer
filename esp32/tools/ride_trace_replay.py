#!/usr/bin/env python3
"""Replay privacy-safe JSONL ride traces through the production C++ policy."""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any, Iterable


SCHEMA_VERSION = 2
SUPPORTED_SCHEMA_VERSIONS = {1, 2}
FORBIDDEN_KEYS = {
    "latitude",
    "longitude",
    "accelerometer",
    "gyroscope",
    "raw_accel",
    "raw_gyro",
}
TRANSITIONS = {"none", "start", "pause", "resume"}
LIFECYCLES = {"idle", "running", "auto_paused", "manual_paused", "finished"}
START_MODES = {"off", "ask", "automatic"}
RECORD_KEYS = {"schema", "profile", "label", "t_ms", "lifecycle", "settings", "evidence", "expected", "output"}
SETTINGS_KEYS = {"start_mode", "auto_pause"}
EVIDENCE_KEYS = {
    "wheel_mps", "cadence_rpm", "gps_mps", "gps_fix_valid", "gps_hdop",
    "gps_source", "gps_horizontal_uncertainty_m", "gps_stationary",
    "gps_displacement_m", "imu_motion_score",
}
METRIC_KEYS = {"value", "age_ms"}
OUTPUT_KEYS = {
    "decision", "evidence_mask", "decision_sequence", "candidate_began_at_ms",
    "decided_at_ms", "counters",
}
COUNTER_KEYS = {"start", "pause", "resume", "conflict"}


class TraceError(ValueError):
    pass


def _is_nonnegative_finite_number(value: Any) -> bool:
    if not isinstance(value, (int, float)) or isinstance(value, bool) or value < 0:
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def _is_uint(value: Any, maximum: int = 0xFFFFFFFF) -> bool:
    return (
        isinstance(value, int)
        and not isinstance(value, bool)
        and 0 <= value <= maximum
    )


def _walk_keys(value: Any) -> Iterable[str]:
    if isinstance(value, dict):
        for key, child in value.items():
            yield key
            yield from _walk_keys(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk_keys(child)


def _reject_unknown_keys(
    value: dict[str, Any], allowed: set[str], path: Path, line_number: int, scope: str
) -> None:
    unknown = set(value).difference(allowed)
    if unknown:
        names = ", ".join(sorted(unknown))
        raise TraceError(f"{path}:{line_number}: unknown {scope} fields: {names}")


def load_trace(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    previous_timestamp: int | None = None
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise TraceError(f"{path}:{line_number}: invalid JSON: {error}") from error
        if not isinstance(record, dict):
            raise TraceError(f"{path}:{line_number}: record must be an object")
        _reject_unknown_keys(record, RECORD_KEYS, path, line_number, "record")
        forbidden = FORBIDDEN_KEYS.intersection(_walk_keys(record))
        if forbidden:
            names = ", ".join(sorted(forbidden))
            raise TraceError(f"{path}:{line_number}: raw/private fields forbidden: {names}")
        schema = record.get("schema")
        if not _is_uint(schema, 0xFF) or schema not in SUPPORTED_SCHEMA_VERSIONS:
            raise TraceError(
                f"{path}:{line_number}: expected schema 1 or {SCHEMA_VERSION}"
            )
        expected_profile = 1 if schema == 1 else 2
        if (not _is_uint(record.get("profile"), 0xFFFF)
                or record["profile"] != expected_profile):
            raise TraceError(f"{path}:{line_number}: unsupported or missing profile")
        if record.get("lifecycle") not in LIFECYCLES:
            raise TraceError(f"{path}:{line_number}: invalid lifecycle")
        settings = record.get("settings", {})
        evidence = record.get("evidence", {})
        if not isinstance(settings, dict) or not isinstance(evidence, dict):
            raise TraceError(f"{path}:{line_number}: settings and evidence must be objects")
        _reject_unknown_keys(settings, SETTINGS_KEYS, path, line_number, "settings")
        _reject_unknown_keys(evidence, EVIDENCE_KEYS, path, line_number, "evidence")
        if schema == 1 and ({"gps_source", "gps_horizontal_uncertainty_m"} & evidence.keys()):
            raise TraceError(f"{path}:{line_number}: schema 1 contains schema 2 GPS quality")
        if schema == 2 and "gps_hdop" in evidence:
            raise TraceError(f"{path}:{line_number}: schema 2 must use horizontal uncertainty")
        if "gps_source" in evidence and not _is_uint(evidence["gps_source"], 2):
            raise TraceError(f"{path}:{line_number}: gps_source must be 0, 1, or 2")
        for metric_name, metric in evidence.items():
            if isinstance(metric, dict):
                _reject_unknown_keys(
                    metric, METRIC_KEYS, path, line_number, f"evidence.{metric_name}"
                )
        if settings.get("start_mode", "ask") not in START_MODES:
            raise TraceError(f"{path}:{line_number}: invalid start_mode")
        if not isinstance(settings.get("auto_pause", True), bool):
            raise TraceError(f"{path}:{line_number}: auto_pause must be boolean")
        if record.get("expected", "none") not in TRANSITIONS:
            raise TraceError(f"{path}:{line_number}: invalid expected transition")
        if "label" in record and not isinstance(record["label"], str):
            raise TraceError(f"{path}:{line_number}: label must be a string")
        if (
            not isinstance(record.get("t_ms"), int)
            or isinstance(record["t_ms"], bool)
            or not 0 <= record["t_ms"] <= 0xFFFFFFFF
        ):
            raise TraceError(f"{path}:{line_number}: t_ms must be a uint32")
        if previous_timestamp is not None:
            delta = (record["t_ms"] - previous_timestamp) & 0xFFFFFFFF
            if delta > 0x7FFFFFFF:
                raise TraceError(
                    f"{path}:{line_number}: timestamp moved backwards without uint32 wrap"
                )
        previous_timestamp = record["t_ms"]
        for field in (
            "wheel_mps",
            "cadence_rpm",
            "gps_mps",
            "gps_hdop" if schema == 1 else "gps_horizontal_uncertainty_m",
            "gps_displacement_m",
            "imu_motion_score",
        ):
            _metric(evidence, field)
        for field in ("gps_fix_valid", "gps_stationary"):
            _flag(evidence, field)
        output = record.get("output")
        if output is not None:
            if not isinstance(output, dict):
                raise TraceError(f"{path}:{line_number}: output must be an object")
            _reject_unknown_keys(output, OUTPUT_KEYS, path, line_number, "output")
            counters = output.get("counters")
            if counters is not None:
                if not isinstance(counters, dict):
                    raise TraceError(f"{path}:{line_number}: output.counters must be an object")
                _reject_unknown_keys(
                    counters, COUNTER_KEYS, path, line_number, "output.counters"
                )
                if any(not _is_uint(value) for value in counters.values()):
                    raise TraceError(
                        f"{path}:{line_number}: output counters must be uint32"
                    )
            if output.get("decision", "none") not in TRANSITIONS:
                raise TraceError(f"{path}:{line_number}: invalid output decision")
            if "evidence_mask" in output and not _is_uint(
                output["evidence_mask"], 0xFFFF
            ):
                raise TraceError(f"{path}:{line_number}: evidence_mask must be uint16")
            for field in (
                "decision_sequence",
                "candidate_began_at_ms",
                "decided_at_ms",
            ):
                if field in output and not _is_uint(output[field]):
                    raise TraceError(f"{path}:{line_number}: output.{field} must be uint32")
        records.append(record)
    if not records:
        raise TraceError(f"{path}: trace is empty")
    return records


def _metric(evidence: dict[str, Any], name: str) -> tuple[str, str]:
    metric = evidence.get(name)
    if metric is None:
        return "-", "-"
    if isinstance(metric, (int, float)) and not isinstance(metric, bool):
        if not _is_nonnegative_finite_number(metric):
            raise TraceError(f"evidence.{name} must be finite and nonnegative")
        return str(float(metric)), "0"
    if not isinstance(metric, dict):
        raise TraceError(f"evidence.{name} must be a number or metric object")
    value = metric.get("value")
    age_ms = metric.get("age_ms", 0)
    if not _is_nonnegative_finite_number(value):
        raise TraceError(f"evidence.{name}.value must be numeric")
    if (
        not isinstance(age_ms, int)
        or isinstance(age_ms, bool)
        or not 0 <= age_ms <= 0xFFFFFFFF
    ):
        raise TraceError(f"evidence.{name}.age_ms must be a uint32")
    return str(float(value)), str(age_ms)


def _flag(evidence: dict[str, Any], name: str) -> tuple[str, str]:
    flag = evidence.get(name)
    if flag is None:
        return "-", "-"
    if isinstance(flag, bool):
        return str(int(flag)), "0"
    if not isinstance(flag, dict):
        raise TraceError(f"evidence.{name} must be a boolean or flag object")
    value = flag.get("value")
    age_ms = flag.get("age_ms", 0)
    if not isinstance(value, bool):
        raise TraceError(f"evidence.{name}.value must be boolean")
    if (
        not isinstance(age_ms, int)
        or isinstance(age_ms, bool)
        or not 0 <= age_ms <= 0xFFFFFFFF
    ):
        raise TraceError(f"evidence.{name}.age_ms must be a uint32")
    return str(int(value)), str(age_ms)


def encode_record(record: dict[str, Any]) -> str:
    settings = record.get("settings", {})
    evidence = record.get("evidence", {})
    if not isinstance(settings, dict) or not isinstance(evidence, dict):
        raise TraceError("settings and evidence must be objects")
    wheel, wheel_age = _metric(evidence, "wheel_mps")
    cadence, cadence_age = _metric(evidence, "cadence_rpm")
    gps, gps_age = _metric(evidence, "gps_mps")
    gps_fix, gps_fix_age = _flag(evidence, "gps_fix_valid")
    if record.get("schema") == 1:
        uncertainty, uncertainty_age = _metric(evidence, "gps_hdop")
        if uncertainty != "-":
            uncertainty = str(float(uncertainty) * 5.0)
    else:
        uncertainty, uncertainty_age = _metric(
            evidence, "gps_horizontal_uncertainty_m"
        )
    stationary, stationary_age = _flag(evidence, "gps_stationary")
    displacement, displacement_age = _metric(evidence, "gps_displacement_m")
    imu, imu_age = _metric(evidence, "imu_motion_score")
    fields = (
        record["t_ms"],
        record["lifecycle"],
        settings.get("start_mode", "ask"),
        int(bool(settings.get("auto_pause", True))),
        wheel,
        wheel_age,
        cadence,
        cadence_age,
        gps,
        gps_age,
        gps_fix,
        gps_fix_age,
        uncertainty,
        uncertainty_age,
        stationary,
        stationary_age,
        displacement,
        displacement_age,
        imu,
        imu_age,
    )
    return "\t".join(str(field) for field in fields)


def build_replay_binary(output: Path, compiler: str | None = None) -> None:
    source = Path(__file__).with_suffix(".cpp")
    command = [
        compiler or os.environ.get("CXX", "c++"),
        "-std=c++17",
        "-Wall",
        "-Wextra",
        "-Werror",
        str(source),
        "-o",
        str(output),
    ]
    subprocess.run(command, check=True)


def replay(records: list[dict[str, Any]], binary: Path) -> list[dict[str, Any]]:
    payload = "\n".join(encode_record(record) for record in records) + "\n"
    completed = subprocess.run(
        [str(binary)], input=payload, text=True, capture_output=True, check=False
    )
    if completed.returncode != 0:
        raise TraceError(completed.stderr.strip() or "C++ replay failed")
    outputs: list[dict[str, Any]] = []
    for line in completed.stdout.splitlines():
        try:
            timestamp, transition, evidence_mask, sequence, profile, candidate = line.split("\t")
            outputs.append(
                {
                    "t_ms": int(timestamp),
                    "transition": transition,
                    "evidence_mask": int(evidence_mask),
                    "sequence": int(sequence),
                    "profile": int(profile),
                    "candidate_began_at_ms": int(candidate),
                }
            )
        except ValueError as error:
            raise TraceError("malformed C++ replay output") from error
    if len(outputs) != len(records):
        raise TraceError("replay output count does not match trace input")
    return outputs


def validate_expectations(
    path: Path, records: list[dict[str, Any]], outputs: list[dict[str, Any]]
) -> dict[str, int]:
    summary = {
        "records": len(records),
        "decisions": 0,
        "mismatches": 0,
        "false_starts": 0,
        "false_pauses": 0,
        "missed_transitions": 0,
        "wrong_transitions": 0,
        "start_latency_ms_total": 0,
        "start_latency_samples": 0,
        "pause_latency_ms_total": 0,
        "pause_latency_samples": 0,
        "resume_latency_ms_total": 0,
        "resume_latency_samples": 0,
    }
    for index, (record, output) in enumerate(zip(records, outputs), 1):
        expected = record.get("expected", "none")
        actual = output["transition"]
        summary["decisions"] += actual != "none"
        if actual != "none":
            latency = (output["t_ms"] - output["candidate_began_at_ms"]) & 0xFFFFFFFF
            summary[f"{actual}_latency_ms_total"] += latency
            summary[f"{actual}_latency_samples"] += 1
        if actual != expected:
            summary["mismatches"] += 1
            summary["false_starts"] += actual == "start" and expected != "start"
            summary["false_pauses"] += actual == "pause" and expected != "pause"
            summary["missed_transitions"] += expected != "none" and actual == "none"
            summary["wrong_transitions"] += actual != "none" and expected != "none"
            print(
                f"{path}:{index}: expected {expected}, got {actual}",
                file=sys.stderr,
            )
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("traces", nargs="+", type=Path)
    parser.add_argument("--binary", type=Path, help="prebuilt ride_trace_replay binary")
    parser.add_argument("--compiler", help="C++ compiler used when --binary is absent")
    args = parser.parse_args()

    try:
        with tempfile.TemporaryDirectory(prefix="ride-trace-replay-") as temp_dir:
            binary = args.binary or Path(temp_dir) / "ride_trace_replay"
            if args.binary is None:
                build_replay_binary(binary, args.compiler)
            total: dict[str, int] = {}
            for trace_path in args.traces:
                records = load_trace(trace_path)
                outputs = replay(records, binary)
                result = validate_expectations(trace_path, records, outputs)
                for key, value in result.items():
                    total[key] = total.get(key, 0) + value
            print(json.dumps(total, sort_keys=True))
            return 1 if total["mismatches"] else 0
    except (OSError, subprocess.SubprocessError, TraceError) as error:
        print(error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
