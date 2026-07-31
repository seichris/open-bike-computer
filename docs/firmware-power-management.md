# Firmware power management

This document describes the firmware power-management architecture currently
implemented for the Waveshare AMOLED 1.75-inch and 2.06-inch boards. It is a
record of the current code and validation status, not an implementation plan.

The main design principle is to stop doing work that cannot change what the
rider sees, while keeping navigation, touch, BLE, transfers, and audio
responsive. Power saving is therefore layered:

1. reduce display brightness and turn the panel off during connected inactivity;
2. update UI, maps, and BLE data only when their inputs change;
3. block the UI task until an event or real deadline needs it;
4. use ESP32 dynamic frequency scaling (DFS);
5. deep-sleep after a configurable disconnected timeout; and
6. keep automatic light sleep available as an opt-in validation profile until
   its remaining hardware gates pass.

## Current production status

- Ordinary developer and production builds use DFS between 80 MHz and 240 MHz.
- Connected display dimming and display-off behavior are enabled.
- UI updates, map rendering, and iPhone BLE writes are change-driven and
  coalesced.
- Disconnected deep sleep is enabled according to the user's timeout setting.
- Automatic light sleep and FreeRTOS tickless idle are **not** enabled in
  ordinary or production builds.
- The `*_LIGHT_SLEEP` profiles are built in CI for continued validation but are
  never selected by the firmware release workflow.
- The Phase 9 light-sleep interaction gate has passed on the available
  1.75-inch board. The 2.06-inch path is build-tested only.
- No battery-life percentage or runtime improvement has been measured yet.

The distinction between DFS and automatic light sleep is important. DFS lowers
the CPU clock while the chip is awake. Automatic light sleep can suspend more
of the chip between scheduled work, but it also makes every wake source and
peripheral transaction part of the correctness boundary.

## Runtime power states

| State | Entry policy | What remains active | Exit |
| --- | --- | --- | --- |
| Connected, active display | Default connected state, meaningful activity, navigation, transfer, pairing, or audio attention | Display at saved brightness, BLE, UI scheduler, required peripherals | Inactivity can dim the display |
| Connected, dimmed display | 15 seconds without meaningful activity | BLE and touch remain available; display brightness is capped at 20%; UI work is throttled | Meaningful activity restores the saved brightness; continued inactivity turns the display off |
| Connected, display off | 45 seconds without meaningful activity | BLE remains connected; the display and ordinary LVGL timer work are stopped; touch wake detection remains available | Touch, BLE/UI activity, or another wake reason restores the display and forces one full refresh |
| Transfer or attention hold | Device transfer, activation, pairing, or audio needs immediate feedback | Display stays awake and required PM locks protect the operation | Hold ends when the operation ends |
| Disconnected countdown | BLE is disconnected and the configured timeout is nonzero | Firmware remains available for reconnection | Reconnection cancels the countdown; expiry enters deep sleep |
| Deep sleep | Disconnected timeout expires | RTC wake configuration only; panel and peripheral rails, buses, and radio are shut down | BOOT/PWR button on GPIO0 |

Display-off while connected is not deep sleep. The BLE connection is retained,
and touch can wake the UI without requiring a reboot or reconnection.

### Disconnected timeout

The disconnected sleep timeout is BLE setting `15`. Supported values are 60,
120, 300, or 600 seconds; `0` disables automatic disconnected sleep. The
default is 120 seconds. An unclaimed device receives a minimum 600-second
registration grace period unless the feature is disabled.

Before deep sleep, firmware turns off the panel and peripheral rails, stops the
SPI and I2C buses, and shuts down the radio. This existing deep-sleep path
provides the lowest-power state and is independent of the connected light-sleep
experiment.

## Display inactivity policy

The connected display state machine lives in the UI task. Its fixed thresholds
are:

- dim after 15 seconds;
- display off after 45 seconds; and
- transfer inactivity timeout after 300 seconds.

The user's active brightness is stored in NVS under namespace
`deviceSettings`, key `brightnessPct`. It is clamped to 5–100%, restored after
reboot and display wake, and capped at 20% while dimmed.

Navigation, transfer, and attention states deliberately hold the display awake:

- navigation requires an authenticated BLE connection plus a route or active
  maneuver;
- transfer includes the transfer service and device-activation work; and
- attention includes pairing and audio.

Meaningful activity includes touch, screen or tile changes, BLE
connect/authentication, route revisions, audio transitions, pairing and
transfer state changes, new transfer progress/errors, and materially changed
maneuver information. Repeated GPS fixes, routine workout samples, and an
unchanged maneuver-distance update do not keep the panel awake by themselves.

When the display is dimmed, the legacy UI timer runs at 250 ms and LVGL work is
bounded to at most once per 100 ms. When the display is off, the main LVGL timer
and ordinary LVGL processing are paused. Waking from display-off requests one
full-screen refresh so the panel cannot expose stale contents.

The touch that wakes a dimmed or off display is consumed until release. It does
not also activate a hidden control or start navigation. Subsequent drag and
pinch gestures are delivered normally.

## Work reduction while awake

### Change-driven UI updates

UI sources have stable signatures for navigation, GPS, route, workout, phone
battery, settings, and device battery state. Widgets are updated only when the
corresponding signature changes or a slower housekeeping cadence becomes due.

Current housekeeping cadences are:

| Work | Cadence |
| --- | --- |
| Ride statistics | 1 second |
| Status polling | 1 second |
| Device battery | 5 seconds |
| Battery while waiting/static | 30 seconds |
| Clock | Aligned to the next minute |

The disconnected waiting screen uses a static status badge instead of a
continuously animated spinner.

### Bounded map rendering

Every GPS fix is retained for position-marker and telemetry accuracy, but it
does not automatically trigger an expensive base-map render. The map scheduler
requires:

- at least 750 ms since the previous base-map render;
- at least 8 metres of movement; or
- at least 12 degrees of heading change in course-up mode.

Route, style, zoom, screen, and recovery changes force a render. North-up mode
ignores heading-only changes, and manual pan can move the lightweight position
marker without recentering the base map. An interrupted or failed render keeps
a recovery request pending.

The full-screen LVGL buffer plus `full_refresh` strategy remains intentional.
It prevents partial-update corruption on these AMOLED panels. Power work should
optimize when rendering happens, not replace that buffer strategy without
measured evidence.

See [Firmware map-render scheduler](firmware-map-render-scheduler.md) for the
detailed contract and test cases.

### BLE write coalescing

The iPhone-side navigation queue prevents stale high-rate data from creating
avoidable radio and CPU work:

- a newer complete maneuver snapshot replaces an older pending snapshot;
- the newest GPS position replaces an older pending position, with native and
  fallback position formats treated as the same logical key; and
- route, catalog, destination, transfer, workout, and other atomic/reliable
  payloads retain their ordering and delivery semantics.

The priority lane is bounded, and schema-v2 iOS metrics expose queue age,
coalescing, and drop counts. Coalescing removes obsolete work; it does not turn
reliable transfer classes into lossy messages.

### Event-driven UI scheduling

BLE callbacks publish thread-safe state and notify the UI task; they never
mutate LVGL directly. Touch, boot, display, transfer, and audio paths use the
same notification mechanism.

The UI task blocks on a FreeRTOS task notification until an event or the next
real deadline. Its maximum wait is 50 ms during connected navigation and 250 ms
for static screens. LVGL uses the monotonic ESP timer, so elapsed time remains
correct without the former 5 ms polling/tick loop.

This scheduler reduces needless wakeups in every build and creates longer idle
windows that the opt-in light-sleep profile can use.

## ESP32 power management

### Dynamic frequency scaling

All current build profiles configure:

- maximum CPU frequency: 240 MHz;
- minimum CPU frequency: 80 MHz; and
- automatic light sleep: disabled, except in `*_LIGHT_SLEEP`.

The 80 MHz floor is deliberate. A lower floor has not passed the longer
hardware and peripheral validation required for production.

Firmware reads the effective ESP-IDF power configuration back after applying
it. A requested configuration is not considered active unless the readback
matches.

### Automatic light-sleep experiment

`WAVESHARE_AMOLED_175_LIGHT_SLEEP` and
`WAVESHARE_AMOLED_206_LIGHT_SLEEP` additionally enable:

- FreeRTOS tickless idle;
- ESP-IDF automatic light sleep;
- a light-sleep exit callback;
- board-specific touch and BOOT wake sources; and
- application-managed no-light-sleep locks around unsafe work.

This can save additional CPU idle power between deadlines, especially while the
display is off or a screen is static. It has no end-user battery impact until a
light-sleep profile is promoted into the release workflow.

If light-sleep configuration or wake setup cannot be verified, firmware
attempts a verified DFS-only rollback. If it cannot establish a safe fallback,
it keeps the startup guard and fails awake rather than entering an
unrecoverable sleep state.

### Power-management locks

The light-sleep profiles protect these domains:

- startup;
- display/panel transactions;
- map rendering;
- storage and GPX access;
- device transfer and activation;
- audio, codec, and I2S work; and
- I2C transactions.

These locks prevent automatic light sleep while a peripheral or timing-critical
operation is in progress. They are intentionally no-ops in DFS-only builds,
where there is no automatic light sleep to block.

The startup lock is released only after wake sources, callbacks, the UI
notifier, and setup are ready.

### Board-specific wake behavior

The two display boards cannot share an identical touch-wake implementation:

| Board | BOOT wake | Touch wake | Status |
| --- | --- | --- | --- |
| 1.75-inch / CST9217 | Active-low RTC GPIO0 via EXT1 | Active-low RTC GPIO21 via EXT1, plus throttled decoded frame sampling | Physically validated |
| 2.06-inch / FT3168 | Active-low RTC GPIO0 via EXT1 | Active-low digital GPIO38 wake with a one-shot low-level interrupt that rearms after release | Build-tested only |

On the 1.75-inch board, the CST9217 interrupt is a transient hint rather than a
stable assertion. Firmware therefore continues a PM-locked decoded touch-frame
sample on an idle deadline, currently every 400 ms, while the display is dimmed
or off. Tickless idle can still sleep between those deadlines. A frame is
acknowledged only when the controller reports the ready marker `0xAB`; an idle
or invalid marker is not acknowledged.

Normal live touch remains interrupt-gated. Do not reintroduce rapid polling:
attempting an I2C read when the CST9217 has no ready data can fail inside the
Arduino Core 3.x path.

The 2.06-inch build keeps GPIO interrupt control in IRAM so the live touch
interrupt can mask itself until the active-low source is released.

## Build profiles and release boundary

Each board has four profile classes:

| Profile class | DFS | Tickless idle | Automatic light sleep | Diagnostics | Release artifact |
| --- | --- | --- | --- | --- | --- |
| `WAVESHARE_AMOLED_175` / `206` | Yes | No | No | Low-rate developer diagnostics; USB CDC at boot | No |
| `*_POWER_METRICS` | Yes | No | No | Structured `PWRMET` and optional timing pulse | No |
| `*_LIGHT_SLEEP` | Yes | Yes | Yes | `PWRMET`, wake capture, and PM-lock telemetry | No; CI validation only |
| `*_PRODUCTION` | Yes | No | No | Disabled; USB CDC not started at application boot | Yes |

Production retains native USB hardware support for ROM download recovery, but
sets `ARDUINO_USB_CDC_ON_BOOT=0`. Holding BOOT while reconnecting USB still
allows the correct board target to be flashed.

Do not compare the runtime of a diagnostic build directly with a production
build. USB CDC and logging intentionally create different power loads.

See [Firmware build profiles](firmware-build-profiles.md) for the canonical
profile definitions.

## Instrumentation and characterization

The firmware `PWRMET` schema v2 emits a low-rate aggregate rather than a
high-frequency trace. It covers:

- display state and effective brightness;
- loop, LVGL, flush, and map-render activity;
- map render reasons and timing;
- BLE message classes and effective negotiated link parameters;
- Wi-Fi, transfer, and audio state;
- effective CPU/DFS/light-sleep configuration;
- active power-lock domains; and
- configured and observed wake sources.

Debug iOS builds emit the corresponding `PWRMET_IOS v=2` queue metrics.
`esp32/tools/power_trace_summary.py` validates and summarizes captured traces.

The characterization harness also supports controlled BLE transmit-power,
connection-policy, and SD-clock experiments. Their candidate values are not
production defaults. Effective iOS-negotiated BLE parameters, rather than
requested values, are authoritative when comparing runs.

Production currently keeps the known-good BLE TX power, NimBLE policy, 4 MHz SD
clock, PMU rails, and 250 ms AXP power-button polling. See
[Firmware battery-life hardware validation](firmware-battery-life-hardware-validation.md)
for the measurement procedure, trace schema, experiment matrix, and detailed
evidence.

## Hardware validation status

The opt-in light-sleep image has passed the available 1.75-inch interaction
gate:

- wake from the dimmed display by touch;
- wake from the black/display-off state by touch;
- map drag and pinch-to-zoom before and after sleep/wake;
- BLE disconnect and reconnect;
- PWR/BOOT wake; and
- repeated cycles without a panic.

The first touch after wake is consumed as designed, so it wakes the display
without activating the control underneath it. Drag and pinch work again after
the wake release.

Only the 1.75-inch board was available for physical validation. The 2.06-inch
light-sleep path compiles in CI but remains physically unvalidated.

## Expected battery impact

The architecture should affect operating states differently:

| Scenario | Main mechanisms | Expected relative effect |
| --- | --- | --- |
| Connected but idle | Dimming, panel off, paused LVGL/display work, event-driven scheduler, DFS | Largest expected improvement in ordinary and production builds |
| Active navigation | Change-only UI, bounded map renders, BLE coalescing, event-driven scheduling, DFS | Smaller but continuous savings while preserving live navigation |
| Transfer, pairing, or audio | Awake holds and PM locks prioritize correctness | Limited savings during the operation; savings resume afterward |
| Disconnected past timeout | Peripheral/radio shutdown and deep sleep | Existing lowest-power steady state |
| Opt-in light-sleep validation image | Tickless idle and automatic light sleep between deadlines | Additional CPU idle savings, especially with the display off; not a production benefit today |

These are directional expectations, not measured battery-life results. A USB
meter reading for the powered development setup and coarse battery percentage
changes are not sufficient to derive device current, watt-hours, or a runtime
percentage.

## Remaining production gates

Before making a quantitative claim or enabling automatic light sleep in
releases:

1. Run repeatable battery rundown tests on the 1.75-inch production image with
   the same starting charge, brightness, route, BLE/radio state, interaction
   script, and elapsed time.
2. Compare like-for-like production builds; do not use a diagnostic image as
   the baseline.
3. Repeat long-duration wake, touch, drag, pinch, BLE reconnect, maneuver,
   connected-navigation, transfer, and audio validation on 1.75-inch hardware.
4. Run the complete physical matrix on a 2.06-inch board.
5. Characterize BLE and SD candidates one variable at a time and retain only
   changes backed by trace and runtime evidence.
6. Promote tickless idle/automatic light sleep to ordinary and production
   profiles only in a dedicated reviewed change.

Until then, DFS, display policy, work coalescing, event-driven scheduling, and
disconnected deep sleep are the production architecture; automatic light sleep
remains an experiment.

## Implementation history

The current architecture was introduced as a sequence of independently
reviewable pull requests:

| Pull request | Result |
| --- | --- |
| [#152](https://github.com/seichris/open-bike-computer/pull/152) | Phase 0 power instrumentation and baseline procedure |
| [#161](https://github.com/seichris/open-bike-computer/pull/161) | Persistent user brightness control |
| [#162](https://github.com/seichris/open-bike-computer/pull/162) | Static/change-driven UI and production profiles |
| [#163](https://github.com/seichris/open-bike-computer/pull/163) | Bounded map-render scheduling |
| [#164](https://github.com/seichris/open-bike-computer/pull/164) | iPhone BLE write coalescing and queue metrics |
| [#165](https://github.com/seichris/open-bike-computer/pull/165) | Connected display dim/off policy |
| [#166](https://github.com/seichris/open-bike-computer/pull/166) | Event-driven UI scheduling |
| [#167](https://github.com/seichris/open-bike-computer/pull/167) | Verified dynamic frequency scaling and PM-lock framework |
| [#168](https://github.com/seichris/open-bike-computer/pull/168) | Hardware characterization harness |
| [#171](https://github.com/seichris/open-bike-computer/pull/171) | Opt-in automatic light-sleep validation profiles and wake handling |

## Source map

When changing this architecture, keep the documentation and these contracts in
sync:

| Concern | Primary source |
| --- | --- |
| Build/release profiles | `esp32/platformio.ini`, `.github/workflows/ci.yml`, `.github/workflows/firmware-release.yml` |
| Display state machine | `esp32/lib/display_power/`, `esp32/src/main.cpp` |
| UI change tracking | `esp32/lib/gui/src/uiUpdatePolicy.hpp` |
| UI task deadlines and notifications | `esp32/lib/ui_scheduler/` |
| Map render policy | `esp32/lib/gui/src/mapRenderPolicy.hpp` |
| ESP32 DFS, light sleep, locks, and wake | `esp32/lib/power_management/` |
| Board touch behavior | `esp32/lib/panel/` |
| Disconnected deep sleep | `esp32/lib/ble_navigation/disconnected_shutdown_policy.hpp`, `esp32/lib/power/` |
| BLE queue/coalescing | `ios-app/BikeComputer/BikeComputer/Utilities/NavigationWriteQueue.swift`, `ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift` |
| Settings protocol | `docs/ble-protocol.md` |
| Test and measurement procedure | `docs/firmware-battery-life-hardware-validation.md` |
