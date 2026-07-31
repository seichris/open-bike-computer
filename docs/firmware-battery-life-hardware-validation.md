# Firmware battery-life hardware validation

Status: **implementation validation in progress; electrical measurements
deferred**. Physical bring-up has passed on the available 1.75-inch target;
2.06-inch hardware is unavailable.

## Operator-approved validation scope

On 2026-07-29, the operator chose not to block implementation on a source
monitor or multimeter setup. The battery-life phases may continue with both
firmware targets built and the available 1.75-inch device physically tested.
The 2.06-inch target remains build-only until hardware is available.

Practical battery use will be evaluated later by running controlled rides or
bench scenarios from comparable battery starting states and observing battery
depletion and elapsed runtime. Those observations can support practical runtime
decisions, but coarse battery percentage must not be presented as a measured
current curve or precise watt-hour saving. The source-monitor procedure below
is retained as an optional higher-precision campaign, not an implementation
gate.

## Connected display-power policy

The firmware now uses four connected operating modes:

- `active`: saved user brightness and the normal LVGL cadence;
- `dimmed`: at most 20% brightness after 15 seconds without meaningful input,
  with the main UI timer reduced from 30 ms to 250 ms and LVGL serviced at most
  every 100 ms;
- `off`: after 45 seconds idle, the panel is turned off, the main UI timer is
  paused, LVGL servicing stops, and any already-queued flush is acknowledged
  without QSPI traffic; and
- `transfer`: the panel remains active while the map/firmware transfer service
  or map activation is active. An enabled transfer service exits after five
  minutes without an authenticated request, unless an authenticated request or
  map activation is still in progress.

Active navigation guidance or a loaded route, an ownership comparison, and
active audio hold the display active. Touch, BOOT/PWR input, screen changes,
BLE connection or authentication, changed maneuver instructions/icons, closer
maneuver-distance thresholds, route changes, transfer progress, and new
actionable transfer errors restart the idle interval. Repeated GPS, workout,
and unchanged maneuver-distance samples intentionally do not. Waking restores
the saved brightness and forces one full-screen refresh before normal rendering
resumes.

Host tests cover time wraparound, inactivity boundaries, navigation/transfer/
attention holds, transfer timeouts, and 10,000 display-off/wake transitions.
Physical wake, touch, reconnect, and battery-depletion checks remain pending
until the 1.75-inch device is connected again.

This document is the source of truth for physical power measurements made
during the battery-life program. A firmware build, simulator result, PMU battery
percentage, or USB-powered observation is not a power baseline. Fill in the
tables below only from saved source-monitor traces taken at the battery input.

## Instrumentation contract

Power-metrics firmware uses schema version `2` and emits one aggregate line
every ten seconds:

```text
PWRMET v=2 intervalMs=... screen=... tile=... display=... brightness[...] loop[...] lvgl[...] flush[...] map[...] ble[...] system[...]
```

The report contains:

- active screen/tile, display state, and requested/effective panel command;
- main-loop wakes and maximum loop gap;
- LVGL call count plus total/maximum handler time;
- display flush count plus rotation, QSPI, and total time;
- completed/interrupted map renders, stage timing, and position, route, style,
  heading, zoom, screen, recovery, and other render-reason counts;
- logically classified BLE packets after authenticated transport framing is
  unwrapped, including packets later rejected by session authentication or
  application-payload validation;
- Wi-Fi mode, transfer state/mode, audio activity, CPU frequency, and the
  number of application-managed power-management locks (`appPmLocks`,
  currently zero because this firmware creates none); and
- `appQueue=ios-diagnostic`, which identifies the separate
  `PWRMET_IOS v=2` ten-second interval report produced by a Debug iOS build.

The iOS queue report includes current/maximum depth, oldest pending and active
retry age, total admissions/flushes/drops/rejections/coalesces, and packet-class
drop/coalescing counters. Queue schema-version-1 traces remain usable but do not
contain the age or packet-class fields; retain the raw version with every trace.

The accumulator schema is defined in
`esp32/lib/power_metrics/power_metrics_schema.hpp` and has a host test in
`esp32/tools/tests/test_power_metrics_schema.cpp`. Metrics builds are separate
from normal firmware builds:

Phase 0 traces remain valid schema-version-1 records. Always keep the raw
version field with a trace rather than interpreting an older reason vector as
version 2.

```sh
cd esp32
pio run -e WAVESHARE_AMOLED_175_POWER_METRICS
pio run -e WAVESHARE_AMOLED_206_POWER_METRICS
```

Metrics builds reserve a larger USB CDC transmit queue so each `PWRMET` record
is enqueued as one complete line without changing the normal firmware's memory
footprint or one-millisecond non-blocking serial timeout. Any
`PWRMET_ERROR` line means that interval was not captured intact and must not be
used for trace correlation.

To correlate display flushes and map renders with a source-monitor trace,
define `POWER_METRICS_PULSE_GPIO` in the selected metrics environment only
after confirming that the pin is electrically spare on that exact board
revision. The pulse is optional; do not guess a pin or reuse a display, touch,
SD, USB, audio, PMU, or boot-control signal.

## Required measurement setup

| Field | Required value | Recorded value |
| --- | --- | --- |
| Source monitor | PPK, Otii, Monsoon, Joulescope, or equivalent | Pending |
| Connection point | Battery terminals, including AXP2101/regulator losses | Pending |
| USB power | Physically disconnected | Pending |
| Initial fixed supply | 4.0 V | Pending |
| Sample rate | At least 10 kS/s | Pending |
| Steady scenario duration | 5-10 minutes | Pending |
| Repetitions | At least three per scenario | Pending |
| Phone placement/RF conditions | Fixed and documented | Pending |
| Route/GPS replay fixture | Fixed and versioned | Pending |
| SD card image | Fixed and checksummed | Pending |

USB serial can change power behavior and USB power invalidates the baseline.
Capture `PWRMET` over an electrically appropriate, battery-isolated UART when
available, or run a separate instrumented correlation pass. Never merge a
USB-powered trace into the battery-terminal energy results.

## Physical bring-up observations (not an electrical baseline)

These observations prove firmware identity and basic functional behavior only.
They must not be entered into the raw scenario results or used for battery-life
projections.

| Field | AMOLED 1.75 observation |
| --- | --- |
| Date/time zone | 2026-07-29, Asia/Singapore |
| Git commit SHA | `f3f703ea582725c9f5e4920eacea82a4276d65fb` |
| Firmware binary SHA-256 | `805dc163ce6caca067f207b6777e32337a2b31ff265241c638ad928a91d04cb9` |
| Physical target | Waveshare AMOLED 1.75; USB serial `28:84:85:3B:68:60` |
| Flash/boot | Exact metrics build flashed and healthy boot observed |
| Metrics transport | Four complete `PWRMET` records; zero `PWRMET_ERROR` records |
| Touch and map interaction | Operator confirmed tap, map drag, and pinch-to-zoom work |
| Inline USB meter | Operator reported `5.1 W`, unchanged from the previous firmware |
| Interpretation | Coarse USB-path observation only; includes unknown USB/charging losses and has no saved high-rate trace |
| AMOLED 2.06 | Physical hardware unavailable; build validation only |

The unchanged inline-meter reading is consistent with Phase 0 being
instrumentation-only, but its resolution and connection point cannot establish
equivalence or savings. It is retained solely as a bring-up observation.

## Trace analysis

Use `esp32/tools/power_trace_summary.py` to derive campaign statistics from
the saved raw source-monitor CSV files. The analyzer requires at least three
runs by default, records each raw file's SHA-256, integrates average current
and energy against time, calculates the exact sample p95 and peak, and reports
run-to-run standard deviation, coefficient of variation, and range. The hash
is calculated from the same byte stream that is parsed, and the analyzer fails
if a raw file changes during the read. It fails closed on missing or aliased
columns, malformed CSV, non-finite input or derived values, duplicate
timestamps, ambiguous voltage input, duplicate raw trace content, insufficient
sample cadence, an uncovered window boundary, or a window with fewer than two
samples.

The default normalized CSV header is `time_s,current_mA`. Units are never
guessed from a column name. Supply either a measured voltage column or the
fixed source-monitor voltage explicitly. For example:

```sh
cd esp32
python3 tools/power_trace_summary.py \
  traces/static-nav-175-run-1.csv \
  traces/static-nav-175-run-2.csv \
  traces/static-nav-175-run-3.csv \
  --scenario "BLE connected, static navigation" \
  --target 1.75 \
  --firmware-sha "$(git rev-parse HEAD)" \
  --supply-voltage 4.0 \
  --window-start-s 60 \
  --window-end-s 660 \
  --output traces/static-nav-175-summary.json
```

For an export containing, for example, `Timestamp` in milliseconds,
`Current` in amperes, and `Voltage` in millivolts, replace the fixed-voltage
argument with:

```text
--time-column Timestamp --time-unit ms \
--current-column Current --current-unit A \
--voltage-column Voltage --voltage-unit mV
```

The start and end window are seconds relative to the first trace sample. The
analyzer linearly interpolates current and voltage at boundaries that fall
between source samples, so an explicit end is never silently truncated. The
reported selected-sample count and sample-percentile distribution exclude
those synthetic boundaries, while the JSON records their count separately.
By default, the CLI requires an effective
sample rate of at least 10 kS/s and rejects any interval longer than two
nominal sample periods; use `--minimum-sample-rate-hz` and
`--maximum-gap-factor` only when a documented measurement protocol calls for
different limits. The p95 is a sample percentile, which is appropriate only
for a fixed, high-rate capture. Do not compare traces sampled at materially
different rates.

Keep each complete, immutable raw CSV with its generated JSON. Output is
written atomically, and the analyzer refuses a same-path, symlink, or hard-link
output that aliases any raw input. The JSON is a derived artifact and never
replaces the raw trace.

## Artifact identity

Record this block before each measurement campaign.

| Field | AMOLED 1.75 | AMOLED 2.06 |
| --- | --- | --- |
| Measurement date/time/time zone | Pending | Pending |
| Operator | Pending | Pending |
| Git commit SHA | Pending | Pending |
| PlatformIO environment | `WAVESHARE_AMOLED_175_POWER_METRICS` | `WAVESHARE_AMOLED_206_POWER_METRICS` |
| Firmware binary SHA-256 | Pending | Pending |
| Board model/revision/serial label | Pending | Pending |
| Display/panel revision | Pending | Pending |
| Battery or supply model | Pending | Pending |
| Supply voltage at board | Pending | Pending |
| SD make/model/capacity | Pending | Pending |
| SD image SHA-256 | Pending | Pending |
| iPhone model/iOS version | Pending | Pending |
| App commit/build | Pending | Pending |
| BLE RSSI range | Pending | Pending |
| Brightness command | Pending | Pending |
| Route/replay fixture SHA-256 | Pending | Pending |
| Raw trace directory | Pending | Pending |

## Scenario procedure

For every applicable scenario:

1. Flash the exact recorded metrics environment and verify a healthy boot.
2. Put the device, phone, route, SD card, brightness, and RF geometry in the
   recorded state.
3. Start the source-monitor capture before entering the scenario.
4. Mark the steady-state window; exclude setup/transitions from steady-state
   averages but retain the complete raw trace.
5. Run for 5-10 minutes, then repeat at least three times from a reproducible
   starting state.
6. Save the raw trace without smoothing or destructive export settings.
7. Record average, p95, and peak current, energy per hour, event rates, latency,
   and any visible or protocol failure.
8. Repeat the same fixture on the other target. A scenario may be marked N/A
   only with a reason.

Deep sleep must be measured after all transient shutdown work has settled.
Audio scenarios must include both active playback and the 60-second period
after playback to expose rails or clocks that remain enabled.

## Raw scenario results

All cells are intentionally pending. Use trace filenames rather than links to
temporary source-monitor sessions. `mWh/h` is derived from measured input
voltage and current; projected runtime additionally requires measured usable
battery Wh.

| # | Scenario | Target | Run traces (minimum 3) | Avg mA | p95 mA | Peak mA | mWh/h | Notes/failures |
| ---: | --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| 1 | Deep sleep | 1.75 | Pending | — | — | — | — | Pending |
| 1 | Deep sleep | 2.06 | Pending | — | — | — | — | Pending |
| 2 | Disconnected waiting, first 30 s | 1.75 | Pending | — | — | — | — | Pending |
| 2 | Disconnected waiting, first 30 s | 2.06 | Pending | — | — | — | — | Pending |
| 3 | Disconnected waiting, after 60 s | 1.75 | Pending | — | — | — | — | Pending |
| 3 | Disconnected waiting, after 60 s | 2.06 | Pending | — | — | — | — | Pending |
| 4 | BLE connected, static navigation | 1.75 | Pending | — | — | — | — | Pending |
| 4 | BLE connected, static navigation | 2.06 | Pending | — | — | — | — | Pending |
| 5 | Scripted maneuver updates | 1.75 | Pending | — | — | — | — | Pending |
| 5 | Scripted maneuver updates | 2.06 | Pending | — | — | — | — | Pending |
| 6 | North-up map, stationary | 1.75 | Pending | — | — | — | — | Pending |
| 6 | North-up map, stationary | 2.06 | Pending | — | — | — | — | Pending |
| 7 | North-up map, 1 Hz GPS replay | 1.75 | Pending | — | — | — | — | Pending |
| 7 | North-up map, 1 Hz GPS replay | 2.06 | Pending | — | — | — | — | Pending |
| 8 | Course-up map, straight | 1.75 | Pending | — | — | — | — | Pending |
| 8 | Course-up map, straight | 2.06 | Pending | — | — | — | — | Pending |
| 9 | Course-up map, repeated turns | 1.75 | Pending | — | — | — | — | Pending |
| 9 | Course-up map, repeated turns | 2.06 | Pending | — | — | — | — | Pending |
| 10 | Ride-statistics screen | 1.75 | Pending | — | — | — | — | Pending |
| 10 | Ride-statistics screen | 2.06 | Pending | — | — | — | — | Pending |
| 11 | Battery/status screen | 1.75 | Pending | — | — | — | — | Pending |
| 11 | Battery/status screen | 2.06 | Pending | — | — | — | — | Pending |
| 12 | Connected dimmed state | 1.75 | Implemented; hardware pending | — | — | — | — | Compare battery depletion later |
| 12 | Connected dimmed state | 2.06 | Build-only; hardware unavailable | — | — | — | — | Hardware deferred |
| 13 | Connected display-off state | 1.75 | Implemented; hardware pending | — | — | — | — | Verify touch/BOOT/PWR wake later |
| 13 | Connected display-off state | 2.06 | Build-only; hardware unavailable | — | — | — | — | Hardware deferred |
| 14 | Transfer AP enabled, idle | 1.75 | Pending | — | — | — | — | Pending |
| 14 | Transfer AP enabled, idle | 2.06 | Pending | — | — | — | — | Pending |
| 15 | Map upload in progress | 1.75 | Pending | — | — | — | — | Pending |
| 15 | Map upload in progress | 2.06 | Pending | — | — | — | — | Pending |
| 16 | Audio playback | 1.75 | Pending | — | — | — | — | Pending |
| 16 | Audio playback | 2.06 | Pending | — | — | — | — | Pending |
| 17 | Sixty seconds after audio | 1.75 | Pending | — | — | — | — | Pending |
| 17 | Sixty seconds after audio | 2.06 | Pending | — | — | — | — | Pending |

## Performance and reliability results

Record values from the same run windows used for the electrical results.

| Metric | AMOLED 1.75 | AMOLED 2.06 | Gate |
| --- | --- | --- | --- |
| LVGL calls/min, static navigation | Pending | Pending | Baseline only |
| Display flushes/min, static navigation | Pending | Pending | Baseline only |
| Map renders/min, 1 Hz north-up replay | Pending | Pending | Baseline only |
| SD/map read time/min | Pending | Pending | Baseline only |
| Main-loop wakes/s | Pending | Pending | Baseline only |
| GPS-to-visible latency p50/p95 | Pending | Pending | p95 no worse than baseline; target <250 ms |
| Maneuver-to-visible latency p50/p95 | Pending | Pending | p95 no worse than baseline; target <250 ms |
| BLE reconnect p50/p95 | Pending | Pending | Fast <2 s p95; slow <5 s p95 |
| Queue depth/max/drops/retries/coalesces | Pending | Pending | No lost maneuver transition |
| Touch/button misses | Pending | Pending | Zero in scripted run |
| Display corruption/black wake | Pending | Pending | Zero observed |
| SD/route/catalog/transfer errors | Pending | Pending | Zero corruption |

## Baseline summary

| Target | Repeatable baseline? | Run-to-run variance | Usable battery Wh measured? | Runtime projection permitted? |
| --- | --- | --- | --- | --- |
| AMOLED 1.75 | **No — pending** | Pending | No | No |
| AMOLED 2.06 | **No — pending** | Pending | No | No |

No phase may claim measured current or energy savings without trace-quality
measurements whose observed difference exceeds measurement noise. Continuing
implementation does not depend on that campaign. Later battery-depletion tests
must report their starting state, elapsed runtime, scenario, and limitations
without converting coarse percentages into precise electrical savings.

## Campaign review checklist

- [ ] Every result names an immutable firmware SHA and binary SHA-256.
- [ ] USB power was physically absent from electrical baseline runs.
- [ ] Both board targets used the same controlled scenario fixture.
- [ ] Three or more raw traces exist for every claimed comparison.
- [ ] Steady-state windows and excluded transitions are documented.
- [ ] Average, p95, peak, and energy were computed from raw samples.
- [ ] `PWRMET` event rates agree with visible trace bursts where correlated.
- [ ] iOS queue metrics show no lost maneuver transition.
- [ ] Failures and anomalous runs remain recorded rather than silently removed.
- [ ] Savings exceed run-to-run variance and instrument noise.
- [ ] Actual-battery runtime uses measured usable Wh, not label capacity.
