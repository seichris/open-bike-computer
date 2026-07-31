from __future__ import annotations

import hashlib
import io
import json
import math
import os
import random
import tempfile
import time
import unittest
from array import array
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

import power_trace_summary

from power_trace_summary import (
    TraceConfiguration,
    TraceFormatError,
    analyze_trace,
    main,
    sample_percentile,
    summarize_campaign,
)


class PowerTraceSummaryTests(unittest.TestCase):
    def write_trace(self, root: Path, name: str, contents: str) -> Path:
        path = root / name
        path.write_text(contents, encoding="utf-8")
        return path

    def cli_arguments(self, traces: list[Path]) -> list[str]:
        return [
            *(str(trace) for trace in traces),
            "--scenario",
            "test scenario",
            "--target",
            "1.75",
            "--firmware-sha",
            "a" * 40,
            "--supply-voltage",
            "4.0",
            "--minimum-sample-rate-hz",
            "1",
            "--minimum-runs",
            str(len(traces)),
        ]

    def assert_cli_error(self, arguments: list[str], message: str) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), self.assertRaises(SystemExit) as raised:
            main(arguments)
        self.assertEqual(raised.exception.code, 2)
        self.assertRegex(stderr.getvalue(), message)

    def test_constant_voltage_trace_uses_time_weighted_integration(self):
        with tempfile.TemporaryDirectory() as directory:
            trace = self.write_trace(
                Path(directory),
                "run.csv",
                "time_s,current_mA\n"
                "0,1\n"
                "1,2\n"
                "2,3\n"
                "3,4\n"
                "4,5\n",
            )
            result = analyze_trace(
                trace,
                TraceConfiguration(supply_voltage_v=4.0),
            )

            self.assertEqual(result.total_samples, 5)
            self.assertEqual(result.selected_samples, 5)
            self.assertAlmostEqual(result.duration_s, 4.0)
            self.assertAlmostEqual(result.effective_sample_rate_hz, 1.0)
            self.assertAlmostEqual(result.average_current_mA, 3.0)
            self.assertAlmostEqual(result.p95_current_mA, 4.8)
            self.assertAlmostEqual(result.peak_current_mA, 5.0)
            self.assertAlmostEqual(result.average_voltage_v, 4.0)
            self.assertAlmostEqual(result.average_power_mW, 12.0)
            self.assertAlmostEqual(result.energy_mWh, 12.0 * 4.0 / 3_600.0)
            self.assertAlmostEqual(result.mWh_per_hour, 12.0)
            self.assertRegex(result.raw_sha256, r"^[0-9a-f]{64}$")

    def test_voltage_column_and_units_are_applied_before_integration(self):
        with tempfile.TemporaryDirectory() as directory:
            trace = self.write_trace(
                Path(directory),
                "variable.csv",
                "time_ms,current_A,voltage_mV\n"
                "0,1,3000\n"
                "1000,1,4000\n"
                "2000,1,5000\n",
            )
            result = analyze_trace(
                trace,
                TraceConfiguration(
                    time_column="time_ms",
                    current_column="current_A",
                    voltage_column="voltage_mV",
                    time_unit="ms",
                    current_unit="A",
                    voltage_unit="mV",
                ),
            )

            self.assertAlmostEqual(result.duration_s, 2.0)
            self.assertAlmostEqual(result.average_current_mA, 1_000.0)
            self.assertAlmostEqual(result.average_voltage_v, 4.0)
            self.assertAlmostEqual(result.average_power_mW, 4_000.0)
            self.assertAlmostEqual(result.energy_mWh, 4_000.0 * 2.0 / 3_600.0)
            self.assertAlmostEqual(result.mWh_per_hour, 4_000.0)

    def test_window_is_relative_to_first_trace_timestamp(self):
        with tempfile.TemporaryDirectory() as directory:
            trace = self.write_trace(
                Path(directory),
                "window.csv",
                "time_s,current_mA\n"
                "100,10\n"
                "101,20\n"
                "102,30\n"
                "103,40\n"
                "104,50\n",
            )
            result = analyze_trace(
                trace,
                TraceConfiguration(
                    supply_voltage_v=4.0,
                    window_start_s=1.0,
                    window_end_s=3.0,
                ),
            )

            self.assertEqual(result.total_samples, 5)
            self.assertEqual(result.selected_samples, 3)
            self.assertAlmostEqual(result.first_sample_elapsed_s, 1.0)
            self.assertAlmostEqual(result.last_sample_elapsed_s, 3.0)
            self.assertAlmostEqual(result.average_current_mA, 30.0)

    def test_nonincreasing_timestamps_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            trace = self.write_trace(
                Path(directory),
                "invalid.csv",
                "time_s,current_mA\n0,1\n1,2\n1,3\n",
            )
            with self.assertRaisesRegex(
                TraceFormatError, "timestamps must be strictly increasing"
            ):
                analyze_trace(
                    trace,
                    TraceConfiguration(supply_voltage_v=4.0),
                )

    def test_duplicate_csv_columns_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            trace = self.write_trace(
                Path(directory),
                "duplicate.csv",
                "time_s,current_mA,current_mA\n0,1,2\n1,2,3\n",
            )
            with self.assertRaisesRegex(TraceFormatError, "duplicate columns"):
                analyze_trace(
                    trace,
                    TraceConfiguration(supply_voltage_v=4.0),
                )

    def test_unterminated_quoted_field_cannot_swallow_later_samples(self):
        with tempfile.TemporaryDirectory() as directory:
            trace = self.write_trace(
                Path(directory),
                "unterminated.csv",
                "time_s,current_mA,note\n"
                "0,1,ok\n"
                "1,2,ok\n"
                '2,3,"unterminated\n'
                "3,100,swallowed\n",
            )
            with self.assertRaisesRegex(TraceFormatError, "invalid CSV"):
                analyze_trace(
                    trace,
                    TraceConfiguration(supply_voltage_v=4.0),
                )

    def test_percentile_handles_duplicates_and_linear_interpolation(self):
        self.assertEqual(sample_percentile(array("d", [2.0] * 100), 95), 2.0)
        values = array("d", [5.0, 1.0, 4.0, 2.0, 3.0])
        self.assertAlmostEqual(sample_percentile(values, 95), 4.8)

    def test_percentile_matches_sorted_reference_across_sample_shapes(self):
        random_source = random.Random(42)
        for sample_count in (1, 2, 3, 10, 101):
            for _ in range(20):
                raw_values = [
                    float(random_source.randrange(-5, 6))
                    for _ in range(sample_count)
                ]
                ordered = sorted(raw_values)
                position = (sample_count - 1) * 0.95
                lower_rank = math.floor(position)
                upper_rank = math.ceil(position)
                fraction = position - lower_rank
                expected = ordered[lower_rank] + (
                    ordered[upper_rank] - ordered[lower_rank]
                ) * fraction
                actual = sample_percentile(array("d", raw_values), 95)
                self.assertAlmostEqual(actual, expected)

    def test_campaign_summary_reports_run_to_run_variance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            traces = [
                self.write_trace(
                    root,
                    f"run-{index}.csv",
                    "time_s,current_mA,run_id\n"
                    f"0,10,{index}\n"
                    f"1,10,{index}\n",
                )
                for index in range(3)
            ]
            configuration = TraceConfiguration(supply_voltage_v=4.0)
            runs = [analyze_trace(trace, configuration) for trace in traces]
            summary = summarize_campaign(
                runs,
                scenario="static navigation",
                target="1.75",
                firmware_sha="a" * 40,
                configuration=configuration,
            )

            average_stats = summary["run_statistics"]["average_current_mA"]
            self.assertEqual(summary["run_count"], 3)
            self.assertAlmostEqual(average_stats["mean"], 10.0)
            self.assertAlmostEqual(average_stats["sample_stddev"], 0.0)
            self.assertAlmostEqual(
                average_stats["coefficient_of_variation_percent"], 0.0
            )

    def test_campaign_rejects_duplicate_raw_trace_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            traces = [
                self.write_trace(
                    root,
                    f"duplicate-{index}.csv",
                    "time_s,current_mA\n0,10\n1,10\n",
                )
                for index in range(3)
            ]
            configuration = TraceConfiguration(supply_voltage_v=4.0)
            runs = [analyze_trace(trace, configuration) for trace in traces]
            with self.assertRaisesRegex(ValueError, "duplicate raw trace"):
                summarize_campaign(
                    runs,
                    scenario="static navigation",
                    target="1.75",
                    firmware_sha="a" * 40,
                    configuration=configuration,
                )

    def test_cli_requires_and_writes_a_three_run_campaign(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            traces = [
                self.write_trace(
                    root,
                    f"cli-{index}.csv",
                    "time_s,current_mA,run_id\n"
                    f"0,10,{index}\n"
                    f"1,12,{index}\n",
                )
                for index in range(3)
            ]
            output = root / "summary.json"
            exit_code = main(
                [
                    *(str(trace) for trace in traces),
                    "--scenario",
                    "deep sleep",
                    "--target",
                    "2.06",
                    "--firmware-sha",
                    "b" * 40,
                    "--supply-voltage",
                    "4.0",
                    "--minimum-sample-rate-hz",
                    "1",
                    "--output",
                    str(output),
                ]
            )

            self.assertEqual(exit_code, 0)
            rendered = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(rendered["analysis_schema_version"], 1)
            self.assertEqual(rendered["run_count"], 3)
            self.assertEqual(rendered["target"], "2.06")
            self.assertEqual(rendered["firmware_sha"], "b" * 40)
            self.assertEqual(
                list(root.glob(f".{output.name}.*.tmp")),
                [],
            )

    def test_missing_required_column_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            trace = self.write_trace(
                Path(directory),
                "missing.csv",
                "time_s,amps\n0,1\n1,2\n",
            )
            with self.assertRaisesRegex(TraceFormatError, "missing required column"):
                analyze_trace(trace, TraceConfiguration(supply_voltage_v=4.0))

    def test_nonfinite_samples_fail_closed(self):
        for raw_value in ("nan", "inf", "-inf"):
            with self.subTest(raw_value=raw_value), tempfile.TemporaryDirectory() as directory:
                trace = self.write_trace(
                    Path(directory),
                    "nonfinite.csv",
                    "time_s,current_mA\n"
                    "0,1\n"
                    f"1,{raw_value}\n",
                )
                with self.assertRaisesRegex(TraceFormatError, "non-finite"):
                    analyze_trace(
                        trace,
                        TraceConfiguration(supply_voltage_v=4.0),
                    )

    def test_voltage_source_must_be_unambiguous(self):
        with self.assertRaisesRegex(ValueError, "exactly one"):
            TraceConfiguration().validate()
        with self.assertRaisesRegex(ValueError, "exactly one"):
            TraceConfiguration(
                voltage_column="voltage_v",
                supply_voltage_v=4.0,
            ).validate()

    def test_configured_column_names_must_be_distinct(self):
        with self.assertRaisesRegex(ValueError, "must be distinct"):
            TraceConfiguration(
                time_column="value",
                current_column="value",
                supply_voltage_v=4.0,
            ).validate()

    def test_nonfinite_configuration_fails_closed_in_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            trace = self.write_trace(
                Path(directory),
                "valid.csv",
                "time_s,current_mA\n0,1\n1,2\n",
            )
            base_arguments = self.cli_arguments([trace])
            cases = (
                ("--supply-voltage", "nan"),
                ("--window-start-s", "inf"),
                ("--minimum-sample-rate-hz", "nan"),
                ("--maximum-gap-factor", "inf"),
            )
            for option, value in cases:
                with self.subTest(option=option):
                    self.assert_cli_error(
                        [*base_arguments, option, value],
                        "finite",
                    )

    def test_window_with_only_one_sample_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            trace = self.write_trace(
                Path(directory),
                "one.csv",
                "time_s,current_mA\n0,1\n1,2\n",
            )
            with self.assertRaisesRegex(TraceFormatError, "at least two samples"):
                analyze_trace(
                    trace,
                    TraceConfiguration(
                        supply_voltage_v=4.0,
                        window_start_s=1.0,
                    ),
                )

    def test_explicit_window_end_must_be_covered(self):
        with tempfile.TemporaryDirectory() as directory:
            trace = self.write_trace(
                Path(directory),
                "short.csv",
                "time_s,current_mA\n0,1\n1,2\n2,3\n",
            )
            with self.assertRaisesRegex(TraceFormatError, "requested window end"):
                analyze_trace(
                    trace,
                    TraceConfiguration(
                        supply_voltage_v=4.0,
                        window_start_s=0.5,
                        window_end_s=3.0,
                    ),
                )

    def test_window_boundaries_are_interpolated_exactly(self):
        with tempfile.TemporaryDirectory() as directory:
            trace = self.write_trace(
                Path(directory),
                "interpolate.csv",
                "time_s,current_mA\n0,0\n1,10\n2,20\n3,30\n",
            )
            result = analyze_trace(
                trace,
                TraceConfiguration(
                    supply_voltage_v=4.0,
                    window_start_s=0.5,
                    window_end_s=2.5,
                ),
            )

            self.assertEqual(result.selected_samples, 2)
            self.assertEqual(result.interpolated_boundary_samples, 2)
            self.assertAlmostEqual(result.first_sample_elapsed_s, 0.5)
            self.assertAlmostEqual(result.last_sample_elapsed_s, 2.5)
            self.assertAlmostEqual(result.duration_s, 2.0)
            self.assertAlmostEqual(result.average_current_mA, 15.0)
            self.assertAlmostEqual(result.average_power_mW, 60.0)

    def test_capture_rate_and_large_sample_gaps_are_enforced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            slow_trace = self.write_trace(
                root,
                "slow.csv",
                "time_s,current_mA\n0,1\n1,1\n2,1\n",
            )
            with self.assertRaisesRegex(TraceFormatError, "below required"):
                analyze_trace(
                    slow_trace,
                    TraceConfiguration(
                        supply_voltage_v=4.0,
                        minimum_sample_rate_hz=10.0,
                    ),
                )

            dense_prefix = "".join(
                f"{index / 10_000:.4f},1\n" for index in range(101)
            )
            gap_trace = self.write_trace(
                root,
                "gap.csv",
                "time_s,current_mA\n" + dense_prefix + "0.1000,1\n",
            )
            with self.assertRaisesRegex(TraceFormatError, "sample gap"):
                analyze_trace(
                    gap_trace,
                    TraceConfiguration(
                        supply_voltage_v=4.0,
                        minimum_sample_rate_hz=1_000.0,
                        maximum_gap_factor=2.0,
                    ),
                )

    def test_raw_sha_is_for_the_exact_parsed_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            trace = Path(directory) / "bom.csv"
            raw_bytes = (
                b"\xef\xbb\xbftime_s,current_mA\r\n"
                b"0,1\r\n"
                b"1,2\r\n"
            )
            trace.write_bytes(raw_bytes)
            result = analyze_trace(
                trace,
                TraceConfiguration(supply_voltage_v=4.0),
            )
            self.assertEqual(
                result.raw_sha256,
                hashlib.sha256(raw_bytes).hexdigest(),
            )

    def test_trace_mutation_during_analysis_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            trace = self.write_trace(
                Path(directory),
                "mutated.csv",
                "time_s,current_mA\n0,1\n1,2\n",
            )
            initial_identity = (1, 2, 3, 4, 5)
            changed_identity = (1, 2, 4, 4, 5)
            with mock.patch.object(
                power_trace_summary,
                "_stat_identity",
                side_effect=(
                    initial_identity,
                    changed_identity,
                    initial_identity,
                ),
            ):
                with self.assertRaisesRegex(TraceFormatError, "trace changed"):
                    analyze_trace(
                        trace,
                        TraceConfiguration(supply_voltage_v=4.0),
                    )

    def test_output_cannot_alias_raw_evidence(self):
        for alias_kind in ("same-path", "symlink", "hardlink"):
            with self.subTest(alias_kind=alias_kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                trace = self.write_trace(
                    root,
                    "raw.csv",
                    "time_s,current_mA\n0,1\n1,2\n",
                )
                original_bytes = trace.read_bytes()
                if alias_kind == "same-path":
                    output = trace
                elif alias_kind == "symlink":
                    output = root / "summary.json"
                    output.symlink_to(trace)
                else:
                    output = root / "summary.json"
                    os.link(trace, output)

                self.assert_cli_error(
                    [*self.cli_arguments([trace]), "--output", str(output)],
                    "aliases raw trace input",
                )
                self.assertEqual(trace.read_bytes(), original_bytes)

    def test_nonfinite_derived_results_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            trace = self.write_trace(
                Path(directory),
                "overflow.csv",
                "time_s,current_A\n0,1e300\n1,1e300\n",
            )
            with self.assertRaisesRegex(TraceFormatError, "derived result"):
                analyze_trace(
                    trace,
                    TraceConfiguration(
                        current_column="current_A",
                        current_unit="A",
                        supply_voltage_v=1e300,
                    ),
                )

    def test_percentile_stays_fast_for_large_monotonic_inputs(self):
        sample_count = 200_000
        started_at = time.monotonic()
        for values in (
            array("d", range(sample_count)),
            array("d", reversed(range(sample_count))),
        ):
            self.assertAlmostEqual(
                sample_percentile(values, 95.0),
                (sample_count - 1) * 0.95,
            )
        self.assertLess(time.monotonic() - started_at, 8.0)


if __name__ == "__main__":
    unittest.main()
