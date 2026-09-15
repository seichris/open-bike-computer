# Firmware battery-life hardware validation

Status: **Phase 9 implementation validation passed on the available 1.75-inch
target; electrical measurements deferred**. Automatic light sleep remains
opt-in, ordinary and production profiles remain DFS-only, and 2.06-inch
hardware is unavailable.

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
On 2026-07-29, the first Phase 9 light-sleep image was flashed and brought up on
the available 1.75-inch device. On 2026-07-30, operator testing found that a tap
did not restore full brightness from dimmed state or wake the display-off
state. Two subsequent interrupt-only handoff candidates also failed the clean
physical wake test, including commit
`8d2f4a2e1d039321f155d99105e01dbf9c87b389`. Commit
`6b6deff4dacb1c20ef96ad88cc9973d6b9f178ad` added an ESP-IDF light-sleep exit
callback, but the callback recorded zero GPIO wake events during failed taps
and the low-level live interrupt also regressed map drag and pinch. The later
light-sleep candidate at `37b97626e3bf0fd3f51c8e1b5b977c8df31a9336`
restored the falling-edge path but still failed tap wake, active drag, and
pinch. Flashing the ordinary DFS-only profile from that same commit restored
drag and pinch, proving that automatic light sleep caused the active-touch
regression. Tap wake still failed because the ordinary profile trusted the
missed GPIO edge and did not consult the CST9217's asserted INT line. The
candidate at `07d8b2c8c19325a63fdacf628b0f1004801d3690` promoted that
held-low fallback to every 1.75-inch profile, but physical retest still failed.
A diagnostic capture then established that GPIO21 remained `HIGH` even while
the ordinary profile decoded valid press/release frames. Those frames were
delivered to LVGL while dimmed but were not counted by the inactivity policy;
after display-off paused LVGL, the controller was not read at all. Commit
`a94a0633f7edd5e6c4ef5143dbcab1a6231febd8` therefore tracks decoded touch
activity directly, keeps only the proven throttled touch reader running while
dimmed/off in the ordinary non-light-sleep profile, and suppresses the wake
contact until release so it cannot activate a hidden control. Its clean
`WAVESHARE_AMOLED_175` image, SHA-256
`886a6bd5510302a462f0f70b8550a53b6043d905135c14ac0dd8f78bb801ed42`, was
flashed with the serial monitor closed. On 2026-07-31, the operator confirmed
active map drag and pinch, tap wake from dimmed state, tap wake from the fully
black display-off state, and working drag and pinch again after wake. This
passes the basic single-cycle connected wake and gesture gate for the ordinary
DFS-only profile. At that point, repeated wake cycles and the
automatic-light-sleep profile remained open.
The host-only 10,000-cycle test is not a substitute for the physical wake-cycle
release gate.

## Event-driven UI scheduling

LVGL now reads the monotonic ESP timer directly instead of waking a periodic
5 ms timer only to advance its tick. The Arduino UI-owner task uses the delay
returned by `lv_timer_handler()` together with explicit housekeeping deadlines,
then blocks on a FreeRTOS task notification. Live navigation has a conservative
50 ms maximum wait; connected-idle, disconnected, and display-off states have a
250 ms maximum wait. An actual LVGL or housekeeping deadline can always shorten
those waits.

BLE state publication, touch and BOOT interrupts, display changes, audio state,
and transfer completion notify the UI owner immediately. BLE callbacks continue
to publish mailbox/state changes and never mutate LVGL objects directly. BLE
ownership/timeout processing, disconnected shutdown, transfer completion, and
PMU button polling now have explicit deadlines instead of running on every loop.
The existing `PWRMET` `loop[count=...]` and `lvgl[count=...]` fields provide the
software wakeup counters for later before/after battery-depletion runs.

Host tests cover deadline selection, immediate deadlines, event-bit
coalescing, wraparound, and the 50/250 ms maximum-wait policy. Active map
gestures, connected dim/off wake, and BLE reconnect have passed on the
available 1.75-inch device; physical maneuver and long-running transfer
latency remain pending.

## Dynamic frequency scaling

All ordinary Waveshare firmware profiles compile ESP-IDF power-management
support and explicitly request 80-240 MHz dynamic frequency scaling during
setup. Automatic light sleep and FreeRTOS tickless idle remain disabled in
those profiles. The firmware reads the effective configuration back from
ESP-IDF and exposes its enabled, error, minimum, maximum, and light-sleep fields
in the ten-second `PWRMET` report. A rejected configuration request leaves the
prior framework setting intact. Readback failure or an unexpected effective
configuration is reported instead of making assumptions about the active
frequency range.

This is Phase 7 Step A only. The minimum frequency must remain at 80 MHz until
physical map-render, display-flush, BLE, touch, transfer, audio, and overnight
connected-navigation checks pass. Do not enable 40 MHz from build
configuration alone.

On 2026-07-29, `WAVESHARE_AMOLED_175_POWER_METRICS` was flashed to the available
1.75-inch board at `/dev/cu.usbmodem101` (USB serial
`28:84:85:3B:68:60`). Boot, AXP2101, touch reset, display, SD, BLE advertising,
iPhone connection/authentication, GPS-driven map loading, vector rendering,
and the 15-second dim transition all completed. The effective configuration
reported `min=80MHz`, `max=240MHz`, `lightSleep=0`, `pmError=0`, and zero
application PM locks. This passes the initial Step A board gate; longer audio,
transfer, RF, wake-cycle, and overnight checks remain part of the final matrix.

## Automatic light-sleep experiment

`WAVESHARE_AMOLED_175_LIGHT_SLEEP` and
`WAVESHARE_AMOLED_206_LIGHT_SLEEP` are dedicated validation profiles built by
the weekly, release-validation, and manual **Firmware Diagnostic Builds**
workflow.
They inherit power metrics, enable FreeRTOS tickless idle, and request automatic
light sleep while retaining the 80-240 MHz DFS range. Ordinary, metrics-only,
and production profiles continue to compile with tickless idle off and never
request automatic light sleep.

The experiment creates named `ESP_PM_NO_LIGHT_SLEEP` locks for startup,
display/rotation/QSPI, map rendering, storage/GPX access, transfer and map
activation, audio/codec/I2S work, and shared I2C operations. The startup lock is
held before automatic light sleep is configured and released only after a
valid wake source is configured, setup finishes, and pending-activation resume
completes. A failed wake-source setup retains that guard. A failed power-policy
readback or mismatch first restores and verifies DFS-only operation; if
rollback or lock release itself fails, the startup lock is deliberately
retained so the device fails awake. Active, peak, and failed application-lock
counts, wake-source state/failures, and startup completion are emitted in
`PWRMET`.

The 1.75-inch experiment arms active-low EXT1 wake for BOOT/GPIO0 and the
CST9217 interrupt on RTC-capable GPIO21. Its normal BOOT and touch handlers stay
falling-edge triggered, preserving the active gesture path. An ESP-IDF
light-sleep exit callback reads the EXT1 status and posts the corresponding
touch/BOOT reason to the UI task. Waveshare's reference driver notes that the
CST9217 interrupt is transient rather than a continuously asserted touch
level, and physical capture found valid frames while GPIO21 was high. EXT1 and
the falling-edge ISR therefore remain best-effort hints. The current candidate
also runs the existing throttled, PM-locked controller read from tickless task
deadlines so decoded touch activity can restore the panel.

The 2.06-inch experiment uses EXT1 for RTC-capable BOOT/GPIO0 and retains the
one-shot low-level digital-GPIO wake path for its non-RTC FT3168 interrupt on
GPIO38. That handler masks itself after its first assertion and re-arms only
after the source returns high. This path remains build-only until 2.06-inch
hardware is available. Startup retains its no-sleep guard unless the wake
sources, callback, and UI notifier are all ready. `PWRMET` reports the EXT1 and
digital-GPIO masks, last captured wake mask, event count, and callback/notifier
readiness. The 1.75-inch reader retains its 400 ms idle cadence and bounded
failure backoff when the interrupt is inactive; the CPU remains eligible for
automatic light sleep between those deadlines. The 2.06-inch path remains
interrupt-gated pending physical hardware.

On 2026-07-29, the first 1.75-inch light-sleep candidate booted, connected and
authenticated over BLE, rendered the vector map, dimmed, and turned the display
off. It then accumulated repeated recovered `ESP_ERR_INVALID_STATE` I2C
failures during speculative idle CST9217 reads, so that candidate failed the
gate. After adding the GPIO21 EXT1 wake source and interrupt-gated idle
sampling, a fresh 86-second capture on the same board and port completed the
connected, map-loaded, dimmed, and display-off sequence with `lightSleep=1`,
`appPmLocks=0`, `peakPmLocks=2`, `pmLockFailures=0`,
`ext1WakeMask=0x200001`, `pmWakeFailures=0`, `startupComplete=1`, and zero I2C
failures or recoveries throughout. BLE remained connected and authenticated,
but the later manual test showed that EXT1 wake did not reliably deliver the
GPIO interrupt notification needed to restore the display. That predecessor
therefore failed despite its clean idle capture.

The current 1.75-inch light-sleep target builds at 91.1% flash and 53.0% RAM;
the build-only 2.06-inch target builds at 90.9% flash and 52.9% RAM. The
ordinary 1.75-inch target also builds after the shared-lock changes, and CI
builds the complete ordinary, metrics, light-sleep, and production matrix.

The exact committed image at
`97f26bda4489ecdf50973a15707c80fb253834d7` was then rebuilt and flashed to
the same 1.75-inch board. Its firmware binary SHA-256 is
`18f13ba6a24637e14f9c32476f3f5b6615543e8e17270adba82158b187693a12`.
A 96-second reset-to-idle capture reached BLE advertising, active, dimmed, and
display-off states with `lightSleep=1`, `pmError=0`, zero active application
locks at idle, peak lock count two, zero lock or wake-source failures, EXT1
mask `0x200001`, startup complete, and zero I2C failures or recoveries. The
iPhone did not connect and no operator gesture was performed during that
capture. On 2026-07-30, manual taps from dimmed and display-off state both
failed to restore the panel, so this exact predecessor image did not pass the
wake gate.

Commit `8d2f4a2e1d039321f155d99105e01dbf9c87b389` replaced the edge-only
handoff with one-shot low-level GPIO interrupt gates and was flashed to the
same board. A clean display-off test performed with the serial port closed
still did not wake on touch. This established that automatic GPIO wake did not
reliably replay the Arduino interrupt into the UI task on this hardware.

Commit `6b6deff4dacb1c20ef96ad88cc9973d6b9f178ad` kept those low-level gates and
added an exit-callback handoff. It was flashed to the same board, but manual
touch still did not wake the display. The final pre-reset metrics showed
`gpioWakeMask=0x200001`, `gpioWakeLast=0x0`, `gpioWakeEvents=0`,
`wakeCapture=1`, `wakeNotifier=1`, and zero wake-source failures. The operator
also found that map drag and pinch-to-zoom no longer worked while the display
was active. Commit `37b97626e3bf0fd3f51c8e1b5b977c8df31a9336`
therefore restored falling-edge live input on 1.75-inch hardware and confined
the low-level gate to the build-only 2.06-inch GPIO38 path. Its light-sleep
profile still failed active gestures and tap wake. The ordinary profile from
the same commit restored drag and pinch but not tap wake. Commit
`07d8b2c8c19325a63fdacf628b0f1004801d3690` kept automatic light sleep
disabled and promoted the raw INT fallback to every 1.75-inch build, but it
also failed physical tap wake. Its diagnostic capture showed valid decoded
touch frames with GPIO21 still `HIGH` while dimmed, followed by no controller
reads after LVGL paused in display-off mode. The successor ordinary candidate,
`a94a0633f7edd5e6c4ef5143dbcab1a6231febd8`, uses decoded touch activity as
the policy input and performs the existing throttled controller read while the
display is inactive. Manual validation passed for active drag and pinch,
dimmed-state tap wake, display-off tap wake, and drag and pinch after wake.

At that stage, BLE reconnect, transfer, audio, extended soak, repeated
wake-cycle checks, and equivalent automatic-light-sleep wake remained open.
The experiment must not be enabled in production until the production gates
pass; the 2.06-inch profile remains build-only until that board is available.

The next 1.75-inch light-sleep candidate therefore extended the physically
proven decoded-frame fallback to tickless builds and was subjected to a clean
build, serial I2C/PM capture, and the same active-gesture and dim/off wake
retest.

Before that manual retest, a 105-second reset-to-idle capture of commit
`790b4c9a9cbc5ab40c1d93bf0486ff3377ec66f0` reached connected active, dimmed,
and display-off states with automatic light sleep enabled, but recorded 15
recovered `ESP_ERR_INVALID_STATE` I2C failures. The ordinary DFS-only profile
from the same source recorded at least 20 of the same recovered failures,
showing that speculative CST9217 sampling, rather than the sleep boundary,
caused the noise. Most failures occurred when the reader sent the host
acknowledgement after bytes without the controller's `0xAB` ready marker.

The successor reader decodes that marker first and acknowledges only a frame
the controller marked ready. A counted 105-second ordinary-profile capture
then completed active, dimmed, and display-off states with no panic or touch
initialization loss and 12 recovered read failures. An A/B experiment using a
combined write/read transaction produced 11 failures in a repeated run, which
was not a meaningful improvement, so the known-good 1.75-inch stop-separated
read sequence remains intact. The remaining failures are bounded speculative
read NACKs; their count remains part of the light-sleep serial gate and must
not be reported as zero.

The exact final light-sleep candidate at
`63a1d40ea37f2c373d6387ee3c83fead04540268` was clean-built and app-flashed
to the same 1.75-inch board. Its firmware binary SHA-256 is
`ce2a8cfa3a7c0f637cecb99a412945238a24713482ad495ad3cec900cc86315d`.
A 105-second reset-to-idle capture remained connected and authenticated while
moving through active, dimmed, and display-off states with `lightSleep=1`,
`pmError=0`, zero active application locks at idle, peak lock count two, zero
lock failures, EXT1 mask `0x200001`, ready wake capture and notifier paths,
zero wake-source failures, and startup complete. It did not panic. The capture
recorded 15 instances of the already characterized
`ESP_ERR_INVALID_STATE` speculative-read failure; 14 had completed recovery
before the capture ended. This is the same bounded failure class seen in the
ordinary-profile baseline, not a new sleep-boundary regression.

On 2026-07-31, the operator then confirmed repeated wake cycles from both the
dimmed and fully black display-off states, map drag and pinch-to-zoom after
wake, BLE reconnect, and PWR-button wake. This passes the Phase 9 physical
implementation gate on the available 1.75-inch board. Automatic light sleep
remains confined to the opt-in validation profile: ordinary and production
profiles still use DFS without automatic light sleep. Longer audio, transfer,
maneuver, connected-navigation, and practical battery-runtime trials, plus
physical validation on the unavailable 2.06-inch board, remain required before
automatic light sleep can be considered for production enablement.

## BLE, PMU, and SD characterization harness

Production defaults remain unchanged: BLE TX power is P9, NimBLE owns its
default advertising and connection policy. Native one-bit SDMMC defaults to
20 MHz; only legacy SPI recovery uses 4 MHz. Record the effective backend and
`freqKHz` from the `SDIO` boot marker for each run. Runtime power paths do not switch PMU outputs, and the AXP2101 button status
remains on the 250 ms housekeeping deadline. No lower-power radio, rail, or SD
setting is selected without physical evidence. The 2.06-inch boot-only
display-enable compatibility operation is not a power-saving setting.

Power-metrics and diagnostic builds now record the connected interval in
1.25 ms units, slave latency, supervision timeout in 10 ms units, sample count,
configured TX power, advertising mode, and requested experimental profile.
The initial connection descriptor is captured immediately and the effective
parameters are resampled every five seconds because iOS may negotiate values
different from the firmware request.

An explicitly opt-in build enables the Phase 8 radio matrix without changing
ordinary firmware. Add each flag combination to a dedicated, clearly named
PlatformIO environment in a measurement branch and commit it before building.
Ambient `PLATFORMIO_BUILD_FLAGS` are intentionally rejected because they would
let a physically tested image advertise a clean Git/profile identity that does
not describe its effective inputs. Then build the tracked environment through
the deterministic helper:

```sh
cd esp32
python3 tools/build_firmware.py TRACKED_BLE_POWER_METRICS_ENVIRONMENT
```

Repeat with `BLE_TX_POWER_DBM=3` and `0`. The experimental policy uses
100-200 ms advertising for 30 seconds after boot, disconnect, or physical
touch/BOOT wake, then 900-1100 ms advertising. It requests 30-50 ms with zero
latency during navigation and 60-100 ms with latency four while connected-idle.
These are requests only; the recorded effective values are authoritative.

For the SD matrix, keep the card image and scenario fixed and repeat both
targets at 4, 8, 12, and 16 MHz. Put each frequency and the timing-log flag in
a named, tracked environment before running the helper:

```sh
python3 tools/build_firmware.py TRACKED_SD_POWER_METRICS_ENVIRONMENT
```

The checked-in schematics close the PMU-interrupt routing question for current
board revisions. On 1.75, AXP2101 `IRQ` reaches TCA9554 P5 (`EXIO5`), while the
expander's `INT` output is not routed to the ESP32. On 2.06, `EXIO5` has no
populated receiver or ESP32 connection. Neither board exposes a direct usable
PMU IRQ GPIO, so replacing deadline-based polling would add I2C work rather
than create an interrupt-driven path.

On 1.75-inch hardware, audio-rail toggling and every PMU output-rail change
remain prohibited until the schematic mapping is verified against physical
codec, display, touch, RTC, battery, SD, reboot, and wake tests. The 2.06-inch
runtime and sleep paths likewise do not switch PMU outputs; its sole exception
is the one-way boot compatibility operation that may set register `0x90` bit
`0x80` while preserving all other bits.

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
  application-payload validation, plus configured radio power/advertising mode
  and the latest effective connection interval, latency, and timeout;
- Wi-Fi mode, transfer state/mode, audio activity, current CPU frequency,
  effective DFS range, power-management error code, automatic-light-sleep
  state, active and peak application-managed power-management locks, lock
  failures, configured and last-captured GPIO wake masks, GPIO wake count,
  callback/notifier readiness, and startup-lock completion (Step A reports
  zero locks; the opt-in light-sleep profile reports live values); and
- `appQueue=ios-diagnostic`, which identifies the separate
  `PWRMET_IOS v=3` ten-second interval report produced by a Debug iOS build.

The iOS queue report includes current/maximum frame depth, current/maximum
pending bytes, oldest pending and active retry age, total
admissions/flushes/drops/rejections/coalesces, and packet-class drop/coalescing
counters. Queue schema-version-1 traces remain usable but do not contain the
age or packet-class fields; schema-version-2 traces do not contain byte
high-water fields. Retain the raw version with every trace.

The accumulator schema is defined in
`esp32/lib/power_metrics/power_metrics_schema.hpp` and has a host test in
`esp32/tools/tests/test_power_metrics_schema.cpp`. Metrics builds are separate
from normal firmware builds:

Phase 0 traces remain valid schema-version-1 records. Always keep the raw
version field with a trace rather than interpreting an older reason vector as
version 2.

```sh
cd esp32
python3 tools/build_firmware.py WAVESHARE_AMOLED_175_POWER_METRICS
python3 tools/build_firmware.py WAVESHARE_AMOLED_206_POWER_METRICS
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

### Connected wake validation (ordinary DFS-only profile)

| Field | AMOLED 1.75 observation |
| --- | --- |
| Validation date/time zone | 2026-07-31, Asia/Singapore |
| Git commit SHA | `a94a0633f7edd5e6c4ef5143dbcab1a6231febd8` |
| PlatformIO environment | `WAVESHARE_AMOLED_175` |
| Firmware binary SHA-256 | `886a6bd5510302a462f0f70b8550a53b6043d905135c14ac0dd8f78bb801ed42` |
| Power policy | DFS 80-240 MHz; automatic light sleep and tickless idle disabled |
| Flash procedure | Esptool verified the image; serial monitor remained closed for the manual test |
| Active interaction | Map drag and pinch-to-zoom passed |
| Dimmed wake | One tap restored the display; subsequent drag and pinch passed |
| Display-off wake | One tap restored the fully black display; subsequent drag and pinch passed |
| Interpretation | Basic single-cycle functional gate passed; repeated cycles, soak, and automatic-light-sleep wake remain pending |

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
| 12 | Connected dimmed state | 1.75 | Pending | — | — | — | — | Manual single-cycle wake passed at `a94a0633`; electrical traces and repeated cycles pending |
| 12 | Connected dimmed state | 2.06 | Build-only; hardware unavailable | — | — | — | — | Hardware deferred |
| 13 | Connected display-off state | 1.75 | Pending | — | — | — | — | Manual single-cycle touch wake passed at `a94a0633`; BOOT/PWR, electrical traces, and repeated cycles pending |
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
| Touch/button misses | Basic manual map/touch-wake pass; scripted run pending | Pending | Zero in scripted run |
| Display corruption/black wake | Basic dim/off wake pass; repeated run pending | Pending | Zero observed |
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
