from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import statistics
from array import array
from collections.abc import MutableSequence, Sequence
from dataclasses import asdict, dataclass
from pathlib import Path


ANALYSIS_SCHEMA_VERSION = 1
FULL_GIT_SHA = re.compile(r"[0-9a-f]{40}")

TIME_UNIT_SECONDS = {
    "s": 1.0,
    "ms": 1e-3,
    "us": 1e-6,
    "ns": 1e-9,
}
CURRENT_UNIT_AMPS = {
    "A": 1.0,
    "mA": 1e-3,
    "uA": 1e-6,
}
VOLTAGE_UNIT_VOLTS = {
    "V": 1.0,
    "mV": 1e-3,
}


class TraceFormatError(ValueError):
    """Raised when a trace cannot produce trustworthy power statistics."""


@dataclass(frozen=True)
class TraceConfiguration:
    time_column: str = "time_s"
    current_column: str = "current_mA"
    voltage_column: str | None = None
    time_unit: str = "s"
    current_unit: str = "mA"
    voltage_unit: str = "V"
    supply_voltage_v: float | None = None
    window_start_s: float = 0.0
    window_end_s: float | None = None

    def validate(self) -> None:
        if self.time_unit not in TIME_UNIT_SECONDS:
            raise ValueError(f"unsupported time unit: {self.time_unit}")
        if self.current_unit not in CURRENT_UNIT_AMPS:
            raise ValueError(f"unsupported current unit: {self.current_unit}")
        if self.voltage_unit not in VOLTAGE_UNIT_VOLTS:
            raise ValueError(f"unsupported voltage unit: {self.voltage_unit}")
        if (self.voltage_column is None) == (self.supply_voltage_v is None):
            raise ValueError(
                "set exactly one of voltage_column or supply_voltage_v"
            )
        if self.supply_voltage_v is not None and self.supply_voltage_v <= 0:
            raise ValueError("supply_voltage_v must be positive")
        if self.window_start_s < 0:
            raise ValueError("window_start_s must be non-negative")
        if (
            self.window_end_s is not None
            and self.window_end_s <= self.window_start_s
        ):
            raise ValueError("window_end_s must be greater than window_start_s")


@dataclass(frozen=True)
class TraceSummary:
    trace: str
    raw_sha256: str
    total_samples: int
    selected_samples: int
    first_sample_elapsed_s: float
    last_sample_elapsed_s: float
    duration_s: float
    effective_sample_rate_hz: float
    average_current_mA: float
    p95_current_mA: float
    peak_current_mA: float
    average_voltage_v: float
    average_power_mW: float
    energy_mWh: float
    mWh_per_hour: float


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _finite_number(raw_value: str | None, column: str, row_number: int) -> float:
    if raw_value is None or not raw_value.strip():
        raise TraceFormatError(f"row {row_number}: empty {column!r} value")
    try:
        value = float(raw_value)
    except ValueError as error:
        raise TraceFormatError(
            f"row {row_number}: non-numeric {column!r} value {raw_value!r}"
        ) from error
    if not math.isfinite(value):
        raise TraceFormatError(
            f"row {row_number}: non-finite {column!r} value {raw_value!r}"
        )
    return value


def _select(values: MutableSequence[float], rank: int) -> float:
    """Return one exact order statistic using in-place three-way partitioning."""
    if rank < 0 or rank >= len(values):
        raise IndexError("order-statistic rank is outside the sample array")

    left = 0
    right = len(values) - 1
    while True:
        if left == right:
            return values[left]

        middle = left + (right - left) // 2
        pivot = sorted((values[left], values[middle], values[right]))[1]
        lower = left
        cursor = left
        upper = right
        while cursor <= upper:
            if values[cursor] < pivot:
                values[lower], values[cursor] = values[cursor], values[lower]
                lower += 1
                cursor += 1
            elif values[cursor] > pivot:
                values[cursor], values[upper] = values[upper], values[cursor]
                upper -= 1
            else:
                cursor += 1

        if rank < lower:
            right = lower - 1
        elif rank > upper:
            left = upper + 1
        else:
            return pivot


def sample_percentile(values: MutableSequence[float], percentile: float) -> float:
    """Return an exact R-type-7 percentile, reordering values in place."""
    if not values:
        raise ValueError("a percentile requires at least one sample")
    if percentile < 0 or percentile > 100:
        raise ValueError("percentile must be between 0 and 100")

    position = (len(values) - 1) * percentile / 100.0
    lower_rank = math.floor(position)
    upper_rank = math.ceil(position)
    lower_value = _select(values, lower_rank)
    if upper_rank == lower_rank:
        return lower_value
    upper_value = _select(values, upper_rank)
    fraction = position - lower_rank
    return lower_value + (upper_value - lower_value) * fraction


def analyze_trace(path: Path, configuration: TraceConfiguration) -> TraceSummary:
    configuration.validate()
    if not path.is_file():
        raise TraceFormatError(f"trace does not exist or is not a file: {path}")

    required_columns = {
        configuration.time_column,
        configuration.current_column,
    }
    if configuration.voltage_column is not None:
        required_columns.add(configuration.voltage_column)

    total_samples = 0
    selected_samples = 0
    trace_origin_s: float | None = None
    previous_trace_time_s: float | None = None
    first_selected_s: float | None = None
    previous_selected_s: float | None = None
    previous_current_a: float | None = None
    previous_voltage_v: float | None = None
    current_area_a_s = 0.0
    voltage_area_v_s = 0.0
    power_area_w_s = 0.0
    peak_current_a = -math.inf
    current_samples_mA = array("d")

    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise TraceFormatError("trace is missing a CSV header")
        if len(reader.fieldnames) != len(set(reader.fieldnames)):
            raise TraceFormatError("trace CSV header contains duplicate columns")
        missing_columns = sorted(required_columns.difference(reader.fieldnames))
        if missing_columns:
            raise TraceFormatError(
                "trace is missing required column(s): " + ", ".join(missing_columns)
            )

        for row_number, row in enumerate(reader, start=2):
            trace_time_s = (
                _finite_number(
                    row.get(configuration.time_column),
                    configuration.time_column,
                    row_number,
                )
                * TIME_UNIT_SECONDS[configuration.time_unit]
            )
            current_a = (
                _finite_number(
                    row.get(configuration.current_column),
                    configuration.current_column,
                    row_number,
                )
                * CURRENT_UNIT_AMPS[configuration.current_unit]
            )
            if configuration.voltage_column is None:
                voltage_v = configuration.supply_voltage_v
                assert voltage_v is not None
            else:
                voltage_v = (
                    _finite_number(
                        row.get(configuration.voltage_column),
                        configuration.voltage_column,
                        row_number,
                    )
                    * VOLTAGE_UNIT_VOLTS[configuration.voltage_unit]
                )
                if voltage_v <= 0:
                    raise TraceFormatError(
                        f"row {row_number}: voltage must be positive"
                    )

            total_samples += 1
            if trace_origin_s is None:
                trace_origin_s = trace_time_s
            if (
                previous_trace_time_s is not None
                and trace_time_s <= previous_trace_time_s
            ):
                raise TraceFormatError(
                    f"row {row_number}: timestamps must be strictly increasing"
                )
            previous_trace_time_s = trace_time_s
            elapsed_s = trace_time_s - trace_origin_s

            if elapsed_s < configuration.window_start_s:
                continue
            if (
                configuration.window_end_s is not None
                and elapsed_s > configuration.window_end_s
            ):
                continue

            if first_selected_s is None:
                first_selected_s = elapsed_s
            if previous_selected_s is not None:
                interval_s = elapsed_s - previous_selected_s
                assert previous_current_a is not None
                assert previous_voltage_v is not None
                current_area_a_s += (
                    (previous_current_a + current_a) * 0.5 * interval_s
                )
                voltage_area_v_s += (
                    (previous_voltage_v + voltage_v) * 0.5 * interval_s
                )
                power_area_w_s += (
                    (
                        previous_current_a * previous_voltage_v
                        + current_a * voltage_v
                    )
                    * 0.5
                    * interval_s
                )

            previous_selected_s = elapsed_s
            previous_current_a = current_a
            previous_voltage_v = voltage_v
            peak_current_a = max(peak_current_a, current_a)
            current_samples_mA.append(current_a * 1_000.0)
            selected_samples += 1

    if total_samples == 0:
        raise TraceFormatError("trace contains no data rows")
    if selected_samples < 2:
        raise TraceFormatError(
            "selected window must contain at least two samples"
        )
    assert first_selected_s is not None
    assert previous_selected_s is not None
    duration_s = previous_selected_s - first_selected_s
    if duration_s <= 0:
        raise TraceFormatError("selected window has no positive duration")

    average_current_a = current_area_a_s / duration_s
    average_voltage_v = voltage_area_v_s / duration_s
    average_power_w = power_area_w_s / duration_s
    energy_mwh = power_area_w_s * 1_000.0 / 3_600.0

    return TraceSummary(
        trace=str(path),
        raw_sha256=_sha256(path),
        total_samples=total_samples,
        selected_samples=selected_samples,
        first_sample_elapsed_s=first_selected_s,
        last_sample_elapsed_s=previous_selected_s,
        duration_s=duration_s,
        effective_sample_rate_hz=(selected_samples - 1) / duration_s,
        average_current_mA=average_current_a * 1_000.0,
        p95_current_mA=sample_percentile(current_samples_mA, 95.0),
        peak_current_mA=peak_current_a * 1_000.0,
        average_voltage_v=average_voltage_v,
        average_power_mW=average_power_w * 1_000.0,
        energy_mWh=energy_mwh,
        mWh_per_hour=average_power_w * 1_000.0,
    )


def _metric_statistics(runs: Sequence[TraceSummary], field: str) -> dict:
    values = [float(getattr(run, field)) for run in runs]
    mean = statistics.fmean(values)
    sample_stddev = statistics.stdev(values) if len(values) > 1 else 0.0
    return {
        "mean": mean,
        "minimum": min(values),
        "maximum": max(values),
        "sample_stddev": sample_stddev,
        "coefficient_of_variation_percent": (
            sample_stddev / abs(mean) * 100.0 if mean != 0 else None
        ),
        "range_percent_of_mean": (
            (max(values) - min(values)) / abs(mean) * 100.0
            if mean != 0
            else None
        ),
    }


def summarize_campaign(
    runs: Sequence[TraceSummary],
    *,
    scenario: str,
    target: str,
    firmware_sha: str,
    configuration: TraceConfiguration,
) -> dict:
    if not runs:
        raise ValueError("campaign summary requires at least one run")
    raw_hashes = [run.raw_sha256 for run in runs]
    if len(raw_hashes) != len(set(raw_hashes)):
        raise ValueError("campaign contains duplicate raw trace content")
    if not FULL_GIT_SHA.fullmatch(firmware_sha):
        raise ValueError("firmware_sha must be a full lowercase Git SHA")
    return {
        "analysis_schema_version": ANALYSIS_SCHEMA_VERSION,
        "scenario": scenario,
        "target": target,
        "firmware_sha": firmware_sha,
        "configuration": asdict(configuration),
        "run_count": len(runs),
        "runs": [asdict(run) for run in runs],
        "run_statistics": {
            field: _metric_statistics(runs, field)
            for field in (
                "average_current_mA",
                "p95_current_mA",
                "peak_current_mA",
                "mWh_per_hour",
            )
        },
    }


def _full_git_sha(value: str) -> str:
    if not FULL_GIT_SHA.fullmatch(value):
        raise argparse.ArgumentTypeError(
            "expected a full 40-character lowercase Git SHA"
        )
    return value


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Summarize battery-terminal source-monitor CSV traces without "
            "discarding raw evidence."
        )
    )
    parser.add_argument("traces", nargs="+", type=Path)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--target", required=True, choices=("1.75", "2.06"))
    parser.add_argument("--firmware-sha", required=True, type=_full_git_sha)
    parser.add_argument("--time-column", default="time_s")
    parser.add_argument("--current-column", default="current_mA")
    parser.add_argument("--voltage-column")
    parser.add_argument("--time-unit", choices=tuple(TIME_UNIT_SECONDS), default="s")
    parser.add_argument(
        "--current-unit", choices=tuple(CURRENT_UNIT_AMPS), default="mA"
    )
    parser.add_argument(
        "--voltage-unit", choices=tuple(VOLTAGE_UNIT_VOLTS), default="V"
    )
    parser.add_argument("--supply-voltage", type=float)
    parser.add_argument("--window-start-s", type=float, default=0.0)
    parser.add_argument("--window-end-s", type=float)
    parser.add_argument("--minimum-runs", type=int, default=3)
    parser.add_argument("--output", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_argument_parser()
    args = parser.parse_args(argv)
    if args.minimum_runs < 1:
        parser.error("--minimum-runs must be at least 1")
    if len(args.traces) < args.minimum_runs:
        parser.error(
            f"expected at least {args.minimum_runs} trace files, "
            f"received {len(args.traces)}"
        )
    if (args.voltage_column is None) == (args.supply_voltage is None):
        parser.error(
            "set exactly one of --voltage-column or --supply-voltage"
        )

    configuration = TraceConfiguration(
        time_column=args.time_column,
        current_column=args.current_column,
        voltage_column=args.voltage_column,
        time_unit=args.time_unit,
        current_unit=args.current_unit,
        voltage_unit=args.voltage_unit,
        supply_voltage_v=args.supply_voltage,
        window_start_s=args.window_start_s,
        window_end_s=args.window_end_s,
    )
    try:
        runs = [analyze_trace(path, configuration) for path in args.traces]
        summary = summarize_campaign(
            runs,
            scenario=args.scenario,
            target=args.target,
            firmware_sha=args.firmware_sha,
            configuration=configuration,
        )
    except (OSError, TraceFormatError, ValueError) as error:
        parser.error(str(error))

    rendered = json.dumps(summary, indent=2, sort_keys=True) + "\n"
    if args.output is None:
        print(rendered, end="")
    else:
        args.output.write_text(rendered, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
