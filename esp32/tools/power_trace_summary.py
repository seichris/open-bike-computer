from __future__ import annotations

import argparse
import codecs
import csv
import hashlib
import json
import math
import os
import random
import re
import statistics
import tempfile
from array import array
from collections.abc import Iterator, MutableSequence, Sequence
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import BinaryIO, Protocol


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


class _HashDigest(Protocol):
    def update(self, data: bytes, /) -> None: ...


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
    minimum_sample_rate_hz: float | None = None
    maximum_gap_factor: float = 2.0

    def validate(self) -> None:
        configured_columns = [self.time_column, self.current_column]
        if self.voltage_column is not None:
            configured_columns.append(self.voltage_column)
        if any(
            not isinstance(column, str) or not column.strip()
            for column in configured_columns
        ):
            raise ValueError("configured column names must be non-empty")
        if len(configured_columns) != len(set(configured_columns)):
            raise ValueError("configured column names must be distinct")
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
        if self.supply_voltage_v is not None and (
            not math.isfinite(self.supply_voltage_v)
            or self.supply_voltage_v <= 0
        ):
            raise ValueError("supply_voltage_v must be finite and positive")
        if not math.isfinite(self.window_start_s) or self.window_start_s < 0:
            raise ValueError("window_start_s must be finite and non-negative")
        if (
            self.window_end_s is not None
            and (
                not math.isfinite(self.window_end_s)
                or self.window_end_s <= self.window_start_s
            )
        ):
            raise ValueError(
                "window_end_s must be finite and greater than window_start_s"
            )
        if self.minimum_sample_rate_hz is not None and (
            not math.isfinite(self.minimum_sample_rate_hz)
            or self.minimum_sample_rate_hz <= 0
        ):
            raise ValueError(
                "minimum_sample_rate_hz must be finite and positive"
            )
        if (
            not math.isfinite(self.maximum_gap_factor)
            or self.maximum_gap_factor < 1.0
        ):
            raise ValueError("maximum_gap_factor must be finite and at least 1")


@dataclass(frozen=True)
class TraceSummary:
    trace: str
    raw_sha256: str
    total_samples: int
    selected_samples: int
    interpolated_boundary_samples: int
    first_sample_elapsed_s: float
    last_sample_elapsed_s: float
    duration_s: float
    effective_sample_rate_hz: float
    max_sample_interval_s: float
    average_current_mA: float
    p95_current_mA: float
    peak_current_mA: float
    average_voltage_v: float
    average_power_mW: float
    energy_mWh: float
    mWh_per_hour: float


def _hashed_text_lines(handle: BinaryIO, digest: _HashDigest) -> Iterator[str]:
    """Yield UTF-8 CSV lines while hashing the exact bytes being parsed."""
    decoder = codecs.getincrementaldecoder("utf-8-sig")()
    for raw_line in handle:
        digest.update(raw_line)
        decoded = decoder.decode(raw_line)
        if decoded:
            yield decoded
    trailing_text = decoder.decode(b"", final=True)
    if trailing_text:
        yield trailing_text


def _stat_identity(stat_result: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        stat_result.st_dev,
        stat_result.st_ino,
        stat_result.st_size,
        stat_result.st_mtime_ns,
        stat_result.st_ctime_ns,
    )


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


def _scaled_finite_number(
    raw_value: str | None,
    column: str,
    row_number: int,
    scale: float,
) -> float:
    value = _finite_number(raw_value, column, row_number) * scale
    if not math.isfinite(value):
        raise TraceFormatError(
            f"row {row_number}: scaled {column!r} value is non-finite"
        )
    return value


def _select(values: MutableSequence[float], rank: int) -> float:
    """Return an exact order statistic with an introspective quickselect."""
    if rank < 0 or rank >= len(values):
        raise IndexError("order-statistic rank is outside the sample array")

    left = 0
    right = len(values) - 1
    partition_work = 0
    work_budget = max(64, len(values) * 8)
    while True:
        if left == right:
            return values[left]

        span = right - left + 1
        if partition_work + span > work_budget:
            ordered = sorted(values[left : right + 1])
            return ordered[rank - left]
        partition_work += span

        pivot = values[random.randrange(left, right + 1)]
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
    return lower_value * (1.0 - fraction) + upper_value * fraction


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
    integration_point_count = 0
    interpolated_boundary_samples = 0
    trace_origin_s: float | None = None
    previous_trace_time_s: float | None = None
    previous_raw_elapsed_s: float | None = None
    previous_raw_current_a: float | None = None
    previous_raw_voltage_v: float | None = None
    first_selected_s: float | None = None
    previous_selected_s: float | None = None
    previous_selected_current_a: float | None = None
    previous_selected_voltage_v: float | None = None
    current_area_a_s = 0.0
    voltage_area_v_s = 0.0
    power_area_w_s = 0.0
    peak_current_a = -math.inf
    current_samples_mA = array("d")
    cadence_interval_count = 0
    cadence_total_s = 0.0
    max_sample_interval_s = 0.0
    start_covered = False
    end_covered = configuration.window_end_s is None
    digest = hashlib.sha256()

    def append_selected_point(
        elapsed_s: float,
        current_a: float,
        voltage_v: float,
        *,
        interpolated: bool,
    ) -> None:
        nonlocal current_area_a_s
        nonlocal first_selected_s
        nonlocal integration_point_count
        nonlocal interpolated_boundary_samples
        nonlocal peak_current_a
        nonlocal power_area_w_s
        nonlocal previous_selected_current_a
        nonlocal previous_selected_s
        nonlocal previous_selected_voltage_v
        nonlocal selected_samples
        nonlocal start_covered
        nonlocal end_covered
        nonlocal voltage_area_v_s

        current_ma = current_a * 1_000.0
        if not math.isfinite(current_ma):
            raise TraceFormatError("selected current is outside the supported range")
        if first_selected_s is None:
            first_selected_s = elapsed_s
        if previous_selected_s is not None:
            interval_s = elapsed_s - previous_selected_s
            if not math.isfinite(interval_s) or interval_s <= 0:
                raise TraceFormatError(
                    "selected window points must be strictly increasing"
                )
            assert previous_selected_current_a is not None
            assert previous_selected_voltage_v is not None
            current_area_a_s += (
                previous_selected_current_a * 0.5 + current_a * 0.5
            ) * interval_s
            voltage_area_v_s += (
                previous_selected_voltage_v * 0.5 + voltage_v * 0.5
            ) * interval_s
            previous_power_w = (
                previous_selected_current_a * previous_selected_voltage_v
            )
            current_power_w = current_a * voltage_v
            power_area_w_s += (
                previous_power_w * 0.5 + current_power_w * 0.5
            ) * interval_s

        previous_selected_s = elapsed_s
        previous_selected_current_a = current_a
        previous_selected_voltage_v = voltage_v
        integration_point_count += 1
        if interpolated:
            interpolated_boundary_samples += 1
        else:
            peak_current_a = max(peak_current_a, current_a)
            current_samples_mA.append(current_ma)
            selected_samples += 1
        if elapsed_s == configuration.window_start_s:
            start_covered = True
        if (
            configuration.window_end_s is not None
            and elapsed_s == configuration.window_end_s
        ):
            end_covered = True

    def append_interpolated_boundary(boundary_s: float) -> None:
        assert previous_raw_elapsed_s is not None
        assert previous_raw_current_a is not None
        assert previous_raw_voltage_v is not None
        assert current_elapsed_s > previous_raw_elapsed_s
        fraction = (
            (boundary_s - previous_raw_elapsed_s)
            / (current_elapsed_s - previous_raw_elapsed_s)
        )
        boundary_current_a = (
            previous_raw_current_a * (1.0 - fraction)
            + current_current_a * fraction
        )
        boundary_voltage_v = (
            previous_raw_voltage_v * (1.0 - fraction)
            + current_voltage_v * fraction
        )
        if not math.isfinite(boundary_current_a) or not math.isfinite(
            boundary_voltage_v
        ):
            raise TraceFormatError("interpolated boundary value is non-finite")
        append_selected_point(
            boundary_s,
            boundary_current_a,
            boundary_voltage_v,
            interpolated=True,
        )

    current_elapsed_s = 0.0
    current_current_a = 0.0
    current_voltage_v = 0.0
    try:
        with path.open("rb") as handle:
            initial_identity = _stat_identity(os.fstat(handle.fileno()))
            reader = csv.DictReader(
                _hashed_text_lines(handle, digest),
                strict=True,
            )
            if reader.fieldnames is None:
                raise TraceFormatError("trace is missing a CSV header")
            if len(reader.fieldnames) != len(set(reader.fieldnames)):
                raise TraceFormatError("trace CSV header contains duplicate columns")
            missing_columns = sorted(required_columns.difference(reader.fieldnames))
            if missing_columns:
                raise TraceFormatError(
                    "trace is missing required column(s): "
                    + ", ".join(missing_columns)
                )

            for row_number, row in enumerate(reader, start=2):
                if None in row:
                    raise TraceFormatError(
                        f"row {row_number}: contains more fields than the CSV header"
                    )
                trace_time_s = _scaled_finite_number(
                    row.get(configuration.time_column),
                    configuration.time_column,
                    row_number,
                    TIME_UNIT_SECONDS[configuration.time_unit],
                )
                current_current_a = _scaled_finite_number(
                    row.get(configuration.current_column),
                    configuration.current_column,
                    row_number,
                    CURRENT_UNIT_AMPS[configuration.current_unit],
                )
                if configuration.voltage_column is None:
                    current_voltage_v = configuration.supply_voltage_v
                    assert current_voltage_v is not None
                else:
                    current_voltage_v = _scaled_finite_number(
                        row.get(configuration.voltage_column),
                        configuration.voltage_column,
                        row_number,
                        VOLTAGE_UNIT_VOLTS[configuration.voltage_unit],
                    )
                    if current_voltage_v <= 0:
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
                current_elapsed_s = trace_time_s - trace_origin_s
                if not math.isfinite(current_elapsed_s):
                    raise TraceFormatError(
                        f"row {row_number}: elapsed timestamp is non-finite"
                    )

                if previous_raw_elapsed_s is None:
                    if current_elapsed_s == configuration.window_start_s:
                        append_selected_point(
                            current_elapsed_s,
                            current_current_a,
                            current_voltage_v,
                            interpolated=False,
                        )
                else:
                    raw_interval_s = current_elapsed_s - previous_raw_elapsed_s
                    segment_intersects_window = (
                        current_elapsed_s > configuration.window_start_s
                        and (
                            configuration.window_end_s is None
                            or previous_raw_elapsed_s < configuration.window_end_s
                        )
                    )
                    if segment_intersects_window:
                        cadence_interval_count += 1
                        cadence_total_s += raw_interval_s
                        max_sample_interval_s = max(
                            max_sample_interval_s, raw_interval_s
                        )

                    if (
                        previous_raw_elapsed_s
                        < configuration.window_start_s
                        < current_elapsed_s
                    ):
                        append_interpolated_boundary(
                            configuration.window_start_s
                        )

                    if (
                        current_elapsed_s >= configuration.window_start_s
                        and (
                            configuration.window_end_s is None
                            or current_elapsed_s <= configuration.window_end_s
                        )
                    ):
                        append_selected_point(
                            current_elapsed_s,
                            current_current_a,
                            current_voltage_v,
                            interpolated=False,
                        )

                    if (
                        configuration.window_end_s is not None
                        and previous_raw_elapsed_s
                        < configuration.window_end_s
                        < current_elapsed_s
                    ):
                        append_interpolated_boundary(configuration.window_end_s)

                previous_raw_elapsed_s = current_elapsed_s
                previous_raw_current_a = current_current_a
                previous_raw_voltage_v = current_voltage_v

            final_handle_identity = _stat_identity(os.fstat(handle.fileno()))
            final_path_identity = _stat_identity(path.stat())
            if (
                initial_identity != final_handle_identity
                or initial_identity != final_path_identity
            ):
                raise TraceFormatError("trace changed while it was being analyzed")
    except UnicodeError as error:
        raise TraceFormatError("trace is not valid UTF-8") from error
    except csv.Error as error:
        raise TraceFormatError(f"trace contains invalid CSV: {error}") from error

    if total_samples == 0:
        raise TraceFormatError("trace contains no data rows")
    if not start_covered:
        raise TraceFormatError("trace does not cover the requested window start")
    if not end_covered:
        raise TraceFormatError("trace does not cover the requested window end")
    if selected_samples < 2:
        raise TraceFormatError("selected window must contain at least two samples")
    if integration_point_count < 2:
        raise TraceFormatError("selected window has fewer than two integration points")
    assert first_selected_s is not None
    assert previous_selected_s is not None
    duration_s = previous_selected_s - first_selected_s
    if not math.isfinite(duration_s) or duration_s <= 0:
        raise TraceFormatError("selected window has no positive finite duration")
    if cadence_interval_count < 1 or cadence_total_s <= 0:
        raise TraceFormatError("selected window contains no source sample intervals")

    effective_sample_rate_hz = cadence_interval_count / cadence_total_s
    if configuration.minimum_sample_rate_hz is not None:
        minimum_rate_hz = configuration.minimum_sample_rate_hz
        if effective_sample_rate_hz < minimum_rate_hz * (1.0 - 1e-9):
            raise TraceFormatError(
                "effective sample rate "
                f"{effective_sample_rate_hz:.6g} Hz is below required "
                f"{minimum_rate_hz:.6g} Hz"
            )
        maximum_interval_s = configuration.maximum_gap_factor / minimum_rate_hz
        if max_sample_interval_s > maximum_interval_s * (1.0 + 1e-9):
            raise TraceFormatError(
                "source trace contains a sample gap of "
                f"{max_sample_interval_s:.9g} s; maximum allowed is "
                f"{maximum_interval_s:.9g} s"
            )

    average_current_a = current_area_a_s / duration_s
    average_voltage_v = voltage_area_v_s / duration_s
    average_power_w = power_area_w_s / duration_s
    summary_values = {
        "effective_sample_rate_hz": effective_sample_rate_hz,
        "max_sample_interval_s": max_sample_interval_s,
        "average_current_mA": average_current_a * 1_000.0,
        "p95_current_mA": sample_percentile(current_samples_mA, 95.0),
        "peak_current_mA": peak_current_a * 1_000.0,
        "average_voltage_v": average_voltage_v,
        "average_power_mW": average_power_w * 1_000.0,
        "energy_mWh": power_area_w_s * 1_000.0 / 3_600.0,
        "mWh_per_hour": average_power_w * 1_000.0,
    }
    non_finite_fields = [
        field for field, value in summary_values.items() if not math.isfinite(value)
    ]
    if non_finite_fields:
        raise TraceFormatError(
            "derived result is non-finite: " + ", ".join(non_finite_fields)
        )

    return TraceSummary(
        trace=str(path),
        raw_sha256=digest.hexdigest(),
        total_samples=total_samples,
        selected_samples=selected_samples,
        interpolated_boundary_samples=interpolated_boundary_samples,
        first_sample_elapsed_s=first_selected_s,
        last_sample_elapsed_s=previous_selected_s,
        duration_s=duration_s,
        effective_sample_rate_hz=summary_values["effective_sample_rate_hz"],
        max_sample_interval_s=summary_values["max_sample_interval_s"],
        average_current_mA=summary_values["average_current_mA"],
        p95_current_mA=summary_values["p95_current_mA"],
        peak_current_mA=summary_values["peak_current_mA"],
        average_voltage_v=summary_values["average_voltage_v"],
        average_power_mW=summary_values["average_power_mW"],
        energy_mWh=summary_values["energy_mWh"],
        mWh_per_hour=summary_values["mWh_per_hour"],
    )


def _metric_statistics(runs: Sequence[TraceSummary], field: str) -> dict:
    values = [float(getattr(run, field)) for run in runs]
    if not all(math.isfinite(value) for value in values):
        raise ValueError(f"campaign metric {field!r} contains a non-finite value")
    try:
        mean = statistics.fmean(values)
        sample_stddev = statistics.stdev(values) if len(values) > 1 else 0.0
    except OverflowError as error:
        raise ValueError(
            f"campaign statistics for {field!r} exceed the supported range"
        ) from error
    result = {
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
    if any(
        value is not None and not math.isfinite(value)
        for value in result.values()
    ):
        raise ValueError(f"campaign statistics for {field!r} are non-finite")
    return result


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
    configuration.validate()
    if not scenario.strip():
        raise ValueError("scenario must be non-empty")
    if target not in {"1.75", "2.06"}:
        raise ValueError("target must be 1.75 or 2.06")
    raw_hashes = [run.raw_sha256 for run in runs]
    if any(not re.fullmatch(r"[0-9a-f]{64}", value) for value in raw_hashes):
        raise ValueError("each run must contain a lowercase SHA-256 raw hash")
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


def _reject_output_alias(output: Path, traces: Sequence[Path]) -> None:
    for trace in traces:
        try:
            aliases_trace = output.samefile(trace)
        except FileNotFoundError:
            aliases_trace = output.resolve(strict=False) == trace.resolve(
                strict=False
            )
        if aliases_trace:
            raise ValueError(
                f"output path aliases raw trace input and is refused: {trace}"
            )


def _write_text_atomic(
    output: Path,
    rendered: str,
    *,
    traces: Sequence[Path],
) -> None:
    _reject_output_alias(output, traces)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="",
            dir=output.parent,
            prefix=f".{output.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary_path = Path(handle.name)
            handle.write(rendered)
            handle.flush()
            os.fsync(handle.fileno())
        _reject_output_alias(output, traces)
        os.replace(temporary_path, output)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


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
    parser.add_argument("--minimum-sample-rate-hz", type=float, default=10_000.0)
    parser.add_argument("--maximum-gap-factor", type=float, default=2.0)
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
    if args.output is not None:
        try:
            _reject_output_alias(args.output, args.traces)
        except (OSError, ValueError) as error:
            parser.error(str(error))

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
        minimum_sample_rate_hz=args.minimum_sample_rate_hz,
        maximum_gap_factor=args.maximum_gap_factor,
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
        rendered = json.dumps(
            summary,
            indent=2,
            sort_keys=True,
            allow_nan=False,
        ) + "\n"
        if args.output is not None:
            _write_text_atomic(args.output, rendered, traces=args.traces)
    except (OSError, TraceFormatError, ValueError) as error:
        parser.error(str(error))

    if args.output is None:
        print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
