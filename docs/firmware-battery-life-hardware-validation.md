# Firmware battery-life hardware validation

Status: **baseline measurements pending on both hardware targets**.

This document is the source of truth for physical power measurements made
during the battery-life program. A firmware build, simulator result, PMU battery
percentage, or USB-powered observation is not a power baseline. Fill in the
tables below only from saved source-monitor traces taken at the battery input.

## Instrumentation contract

Power-metrics firmware uses schema version `1` and emits one aggregate line
every ten seconds:

```text
PWRMET v=1 intervalMs=... screen=... tile=... display=... brightness[...] loop[...] lvgl[...] flush[...] map[...] ble[...] system[...]
```

The report contains:

- active screen/tile, display state, and requested/effective panel command;
- main-loop wakes and maximum loop gap;
- LVGL call count plus total/maximum handler time;
- display flush count plus rotation, QSPI, and total time;
- completed/interrupted map renders, stage timing, and render-reason counts;
- accepted BLE packets by class;
- Wi-Fi mode, transfer state/mode, audio activity, CPU frequency, and the
  number of active power-management locks; and
- `appQueue=ios-diagnostic`, which identifies the separate
  `PWRMET_IOS v=1` queue report produced by a Debug iOS build.

The accumulator schema is defined in
`esp32/lib/power_metrics/power_metrics_schema.hpp` and has a host test in
`esp32/tools/tests/test_power_metrics_schema.cpp`. Metrics builds are separate
from normal firmware builds:

```sh
cd esp32
pio run -e WAVESHARE_AMOLED_175_POWER_METRICS
pio run -e WAVESHARE_AMOLED_206_POWER_METRICS
```

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
| 12 | Connected dimmed state | 1.75 | Not implemented | — | — | — | — | Measure after state exists |
| 12 | Connected dimmed state | 2.06 | Not implemented | — | — | — | — | Measure after state exists |
| 13 | Connected display-off state | 1.75 | Not implemented | — | — | — | — | Measure after state exists |
| 13 | Connected display-off state | 2.06 | Not implemented | — | — | — | — | Measure after state exists |
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

No later phase may claim measured savings until both targets have three
repeatable baseline runs for the relevant comparison scenario and the observed
difference exceeds measurement noise. Update this summary only after reviewing
the raw traces and documenting exclusions.

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
