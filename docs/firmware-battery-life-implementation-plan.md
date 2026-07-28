# Firmware Battery-Life Implementation Plan

## Outcome

Reduce measured energy use on both Waveshare AMOLED bike-computer targets while
preserving navigation reliability, display stability, touch safety, map-transfer
integrity, and wake behavior.

The first release should deliver four user-visible improvements:

1. Make the existing iPhone brightness setting control the device.
2. Stop refreshing full-frame UI content when nothing visible changed.
3. Decouple incoming GPS frequency from vector-map rendering frequency.
4. Add dimmed and display-off states for disconnected and connected-idle use.

Scheduler, CPU-frequency, BLE, SD-card, and PMU improvements follow only after
the display workload is controlled and measurable idle windows exist.

This plan does not promise a percentage increase in runtime. Battery effects
must be measured on physical 1.75-inch and 2.06-inch units. Estimates from the
architecture review are prioritization hypotheses, are state-specific, and are
not additive.

## Baseline

This plan was prepared from `origin/main` at
`e2f9d0ad76b9d15c0c24def0302d16ff4d31ff32`.

The external architecture review was performed against the same commit. Its
claims were checked again against the repository before this plan was written.

### Current runtime architecture

```text
iPhone
  CoreLocation / MapKit / HealthKit
      -> NavigationEngine and BikeComputerCoordinator
      -> BLEManager and bounded NavigationWriteQueue
      -> authenticated BLE GPS, navigation, route, settings, workout,
         destination, and transfer traffic

ESP32-S3
  NimBLE callbacks
      -> update shared navigation, GPS, route, settings, and transfer state
      -> set screen/map redraw state

  Arduino loop
      -> pending map/screen transitions
      -> lv_timer_handler()
      -> BLE and ownership housekeeping
      -> disconnected shutdown policy
      -> BOOT and AXP2101 button processing
      -> transfer-server processing

  LVGL
      -> 30 ms main-screen timer
      -> one-second notification timer
      -> waiting/status animations and screen-specific events
      -> full RGB565 framebuffer in PSRAM
      -> whole-frame rotation on the 1.75-inch target
      -> QSPI transfer to the CO5300 AMOLED

  Storage and peripherals
      -> vector maps on SD, with internal-storage fallback
      -> QMI8658 disabled in normal Waveshare builds
      -> speaker worker blocks when idle and starts codec/I2S lazily
      -> Wi-Fi enabled only for device transfer or firmware update
      -> AXP2101 owns display/peripheral rails and battery status

  Existing shutdown
      -> configurable disconnected timeout
      -> display and peripheral rails off
      -> deep sleep
      -> BOOT/GPIO0 wake
```

### Confirmed battery-relevant behavior

1. `esp32/lib/panel/WAVESHARE_AMOLED_175.cpp` initializes the AMOLED at
   `gfx->setBrightness(255)`.
2. `esp32/lib/power/power.cpp` restores brightness to `255` after suspend.
3. The iPhone sends brightness setting ID `12`, including after BLE
   authentication, but `handleMapSetting()` in
   `esp32/lib/ble_navigation/ble_navigation.cpp` has no `case 12`.
4. Every handled map-setting path that reaches the end of `handleMapSetting()`
   calls `triggerMapRedraw()`, including nonvisual settings.
5. The main LVGL timer runs every 30 ms and the Arduino loop waits only 5 ms.
6. LVGL uses a separate 5 ms periodic `esp_timer` to advance its tick.
7. The disconnected waiting screen has a continuous spinner and a one-second
   battery timer.
8. The notification bar updates every second, renders seconds in the clock,
   and toggles the GPS-fix LED.
9. Each accepted phone GPS packet calls `triggerMapRedraw()`.
10. Course-up mode can redraw after a heading change greater than 5 degrees.
11. The native GPS path uses the ordinary bounded iOS navigation queue even
    though that queue already supports latest-value coalescing.
12. The normal Waveshare build config uses a 240 MHz board configuration,
    debug logging, USB CDC on boot, and a two-second USB startup delay. ESP-IDF
    power management and tickless idle are not configured.
13. BLE transmit power is fixed at `ESP_PWR_LVL_P9`; advertising and connection
    timing are not tuned for active versus idle use.

### Existing behavior to preserve

- Full-screen buffering and `LV_DISPLAY_RENDER_MODE_FULL` are deliberate
  stability choices for the AMOLED panel. Reduce invalidations before changing
  render mode.
- The 1.75-inch target performs whole-frame software rotation. Its display cost
  must be measured separately from the 2.06-inch target.
- Waveshare touch input is interrupt-gated. Do not restore rapid touch polling.
- The IMU is explicitly disabled in normal Waveshare builds.
- Wi-Fi is normally off outside transfer/update mode.
- The speaker task blocks indefinitely while idle and releases codec/I2S
  resources after playback.
- Auth, ownership, route batches, settings, and transfer commands require
  ordered and reliable delivery.
- Existing disconnected deep sleep and BOOT/GPIO0 wake remain the terminal
  low-power state.

## Scope

### Included

- reproducible current and energy measurement;
- firmware power/display diagnostics;
- brightness protocol, persistence, and restore behavior;
- change-only and active-screen-only UI updates;
- static disconnected waiting UI;
- production versus diagnostic logging profiles;
- GPS ingestion and vector-map render scheduling;
- iOS GPS write coalescing and message-class queue policy;
- active, dimmed, display-off, transfer, and deep-sleep states;
- event-driven LVGL/main-loop scheduling;
- dynamic frequency scaling and, later, coordinated automatic light sleep;
- BLE advertising, connection-parameter, and TX-power experiments;
- PMU rail, SD-card, SPI-clock, and audio-rail characterization; and
- physical validation on both Waveshare targets.

### Not included in the first release

- changing away from full-frame LVGL rendering;
- active-navigation explicit `esp_light_sleep_start()` calls;
- blind AXP2101 rail changes without schematic and current measurements;
- routinely unmounting or power-cycling the SD card between map reads;
- changing the touch-controller polling contract;
- a hardware redesign; or
- marketing claims based on estimated rather than measured runtime.

## Decisions locked into this plan

1. Land the work as small, independently measurable PRs in the order below.
2. Capture a baseline before changing power behavior.
3. Run the standard scenario matrix on both board targets after every phase
   that changes runtime behavior.
4. Preserve 100% brightness as the migration default until a saved value or
   explicit iPhone setting exists; evaluate a lower factory default separately.
5. Apply panel changes from the main/LVGL owner context, not directly from a BLE
   callback during a possible display flush.
6. A brightness change does not invalidate the vector map.
7. Receive current GPS state immediately, but schedule expensive base-map
   renders separately.
8. Maneuver instructions remain immediate and take priority over replaceable
   GPS state.
9. Only complete, replaceable state snapshots may be coalesced.
10. Active navigation remains fully visible by default. Active-ride dimming is
    opt-in until outdoor UX testing proves it safe.
11. GPS packets do not count as user activity and must not keep the display
    awake indefinitely.
12. Introduce event-driven waits before dynamic frequency scaling, and dynamic
    frequency scaling before automatic light sleep.
13. Do not enable automatic light sleep without explicit power-management locks
    around display, map, SD, transfer, audio, and other timing-sensitive work.
14. PMU and SD experiments change one variable at a time and have a documented
    rollback.
15. Product behavior is gated by reliability and latency, not battery savings
    alone.

## Success metrics and acceptance gates

Collect these metrics for every baseline and comparison run:

- average current;
- peak and 95th-percentile current;
- mWh per hour;
- projected runtime from measured usable battery watt-hours;
- LVGL handler calls and actual display flushes per minute;
- rotation, QSPI, and total flush time;
- map renders and SD-read time per minute;
- BLE packets by class, queue depth, drops, retries, and coalesces;
- main-loop/task wakeups per second;
- GPS-to-visible-position latency, p50 and p95;
- maneuver-to-visible-instruction latency, p50 and p95;
- BLE reconnect latency;
- touch/button misses;
- black-screen wakes or display corruption; and
- SD, route, catalog, or transfer errors.

The following gates apply across the program:

| Gate | Required result |
| --- | --- |
| Navigation | No lost maneuver transitions in scripted repeated-route tests. |
| Maneuver latency | p95 no worse than baseline; target below 250 ms. |
| GPS freshness | No replay of visibly stale queued GPS positions after link recovery. |
| Reconnect | Fast-advertising p95 below 2 s; slow-advertising p95 below 5 s. |
| Stability | No touch crash or unintended BLE disconnect in an overnight soak. |
| Display wake | No corruption or black screen across 10,000 dim/off/wake cycles before general release. |
| Transfer | No route, catalog, map, or firmware corruption under deliberately degraded BLE/Wi-Fi conditions. |
| Energy | A result must exceed measurement noise and be reproducible on three runs; PMU battery percentage is not an energy metric. |
| Compatibility | Both `WAVESHARE_AMOLED_175` and `WAVESHARE_AMOLED_206` build and pass their physical scenario subset. |

## Phase 0: instrumentation and physical baseline

### Objective

Make power and performance changes attributable before changing behavior.

### Firmware work

Add a low-rate, compile-time-gated `POWER_METRICS` report containing:

- active screen and display power state;
- requested and effective brightness;
- LVGL handler count and time;
- flush count, rotation time, QSPI time, total flush time, and maximums;
- map render count, duration, and reason;
- GPS packets received;
- BLE queue depth/drops/coalesces as reported by the app or debug protocol;
- main-loop wake count and longest gap;
- Wi-Fi/transfer/audio state; and
- current CPU frequency and active power-management locks once those exist.

Instrument at least these boundaries:

- `esp32/src/main.cpp` for loop and state counters;
- `esp32/lib/panel/WAVESHARE_AMOLED_175.cpp` for rotation and flush timing;
- `esp32/lib/maps/src/maps.cpp` and `esp32/lib/gui/src/mainScr.cpp` for map
  render count/reason;
- `esp32/lib/ble_navigation/ble_navigation.cpp` for packet-class counters; and
- `ios-app/BikeComputer/BikeComputer/Utilities/NavigationWriteQueue.swift` for
  queue metrics in diagnostic builds.

Prefer a ten-second aggregate report over per-packet USB logging. Add an
optional spare-GPIO pulse around map renders and display flushes so a source
monitor trace can be correlated without USB.

### Measurement setup

- Use a Nordic PPK, Otii, Monsoon, Joulescope, or equivalent source monitor.
- Measure at the battery terminals so AXP2101 and regulator losses are present.
- Disconnect USB power completely.
- Use a fixed repeatable supply voltage, initially 4.0 V.
- Sample fast enough to capture display, BLE, SD, and audio bursts; target at
  least 10 kS/s.
- Keep board, firmware, SD card, phone position, brightness, route, and screen
  identical across an A/B comparison.
- Run steady scenarios for 5-10 minutes and repeat each at least three times.
- Repeat final runtime tests with the actual battery and measured usable Wh.

### Standard scenario matrix

1. Deep sleep.
2. Disconnected waiting, first 30 seconds.
3. Disconnected waiting after 60 seconds.
4. BLE connected, static navigation screen.
5. Navigation with scripted maneuver updates.
6. North-up map, stationary.
7. North-up map with 1 Hz GPS replay.
8. Course-up map, straight section.
9. Course-up map with repeated turns.
10. Ride-statistics screen.
11. Battery/status screen.
12. Connected dimmed state, after that state exists.
13. Connected display-off state, after that state exists.
14. Transfer AP enabled but idle.
15. Map upload in progress.
16. Audio playback.
17. Sixty seconds after audio playback.

### Deliverables

- A versioned metrics schema and host tests for counters/aggregation.
- `docs/firmware-battery-life-hardware-validation.md` containing the setup,
  firmware SHA, board revisions, SD cards, raw scenario results, and summary.
- Baseline traces for both targets.

### Exit gate

Do not assign measured savings to later phases until both boards have a
repeatable baseline and observed run-to-run variance.

## Phase 1: brightness protocol and display-power ownership

### Objective

Fix the existing brightness control and establish one owner for all display
brightness, dim, off, and restore decisions.

### Firmware design

Add `esp32/lib/display_power/` with a small `DisplayPowerManager` that owns:

- saved user brightness percent;
- effective brightness after state-based dimming;
- active/dimmed/off state;
- pending panel changes;
- whether a full refresh is required on wake; and
- conversion from 5-100% UI values to the panel's 0-255 command range.

Add firmware setting ID `12` to `handleMapSetting()`:

- reject malformed values and clamp valid values to 5-100;
- persist to an NVS `deviceSettings` namespace;
- enqueue a brightness request for the display owner;
- return without calling `triggerMapRedraw()`; and
- log only in diagnostic builds.

At boot, load the saved value before the display's final brightness is applied.
If no value exists, use 100% for upgrade compatibility. Replace hard-coded
brightness restoration in:

- `esp32/lib/panel/WAVESHARE_AMOLED_175.cpp`; and
- `esp32/lib/power/power.cpp`.

Apply pending brightness changes from the main/LVGL context. Do not issue panel
commands from BLE callbacks while a QSPI flush could be active.

Refactor `handleMapSetting()` to make redraw intent explicit. Only visual map
and navigation-profile settings should invalidate the map. Tap-to-switch,
screen masks, default screen, disconnected timeout, brightness, phone battery,
and charging state must not trigger a map render.

Update `docs/ble-protocol.md` so setting ID `12`, units, valid range,
persistence, default, and acknowledgement behavior are explicit.

### Tests

- Host tests for percentage clamping and 0-255 conversion.
- Host tests for first-boot default and persisted restore.
- Setting-policy tests proving ID `12` does not request a map redraw.
- Firmware builds for both targets.
- iOS test proving the existing slider sends ID `12` after editing and after
  authenticated reconnect.
- Physical sweep at 100%, 75%, 50%, 25%, and 5% on a mostly black navigation
  screen, a typical vector map, and the waiting screen.
- Reboot, suspend/wake, and disconnected deep-sleep/wake restore tests.

### Exit gate

- Slider changes are visible on both boards without corruption.
- Saved brightness survives reboot and wake.
- No brightness operation triggers a map render.
- A measured current-versus-command curve exists for each display target.

## Phase 2: static UI, change-only updates, and production logging

### Objective

Drive display flushes toward zero when visible content is static.

### Waiting screen

- Remove the continuous LVGL spinner.
- Use a static BLE/pairing state icon and honest connection text.
- Update device battery only when its cached value changes, with a 30-60 second
  maximum cadence while waiting.
- Preserve immediate pairing-code and ownership-state changes.

### Notification and status UI

- Show `HH:MM` rather than seconds and schedule the next update at the minute
  boundary.
- Remove the one-second blinking GPS indicator.
- Update GPS count/fix only when GPS state changes.
- Update Wi-Fi and SD indicators only when their states change.
- Update device battery only when the cached value changes.
- Stop screen-specific timers when their screen is inactive.
- Reduce ride-statistics cadence to 1 Hz unless a metric has a demonstrated
  need for a faster visible update.
- Reduce device-battery UI cadence to the existing five-second PMU cache or
  slower.

### Main-screen update contract

Introduce change detection or revisions for navigation, GPS, route, workout,
phone battery, settings, and device battery. `updateMainScreen()` must update
only active-screen widgets whose source revision changed.

Avoid repeatedly calling `lv_label_set_text*()`, `lv_img_set_src()`,
`lv_img_set_angle()`, or `lv_arc_set_value()` with unchanged values.

### Production and diagnostic environments

Keep a diagnostic environment with USB CDC and low-rate metrics. Add explicit
production environments for both Waveshare targets that:

- set `CORE_DEBUG_LEVEL=0` and `DEBUG=0`;
- do not perform per-packet or high-frequency serial logging;
- omit the unconditional two-second USB attachment delay; and
- decide explicitly whether USB CDC remains available for recovery rather than
  changing it incidentally.

Build both production and diagnostic environments in CI so power work does not
remove the field-debug path.

### Tests

- Host tests for revision/change detection and timer policy.
- Screenshot or layout tests confirming the static waiting state remains clear.
- Static-screen instrumentation proving update calls and flushes stop after
  content settles.
- Diagnostic-versus-production boot and navigation tests.
- Overnight static waiting and connected-idle soak on both boards.

### Exit gate

After visible content settles, static screens produce no periodic full-frame
flush merely for a spinner, seconds clock, unchanged battery value, or
unchanged status icon.

## Phase 3: dirty-model UI and map-render scheduler

### Objective

Retain every useful incoming state update without treating each update as a
request to regenerate the vector map.

### Shared-state revisions

BLE callbacks should update data and atomically publish narrow dirty bits or
revision counters. The LVGL owner consumes them. Initial categories:

- GPS/position;
- maneuver/navigation;
- route geometry;
- map profile/style;
- workout telemetry;
- phone battery/charging;
- device battery; and
- screen/ownership state.

Inactive screens retain the latest model revision but perform no widget work.
Loading a screen applies the latest complete model once.

### Map scheduler

Separate these operations:

1. ingest and retain the latest GPS fix;
2. update lightweight telemetry/position state;
3. update maneuver and position overlays; and
4. regenerate the vector-map background.

An immediate base-map render remains mandatory for route, style, zoom, map
selection, screen, and explicit force-redraw changes.

For ordinary GPS movement, start with a policy that renders only when:

- at least 750 ms has elapsed since the last base-map render; and
- position moved at least 8 m or course-up heading changed at least 12 degrees.

These are test defaults, not product constants. A/B test 1 Hz and 2 Hz caps,
5-10 m movement thresholds, and 10-15 degree heading thresholds on both
targets. Use route-derived heading where the existing renderer already prefers
it, and prevent GPS course noise from repeatedly crossing the threshold.

Maneuver instruction, distance-to-turn, and current-position overlays must be
able to update without rereading SD map data and regenerating the full base
map. A new maneuver always bypasses the base-map rate limit for its overlay.

Record a reason for every map render so instrumentation can distinguish forced,
movement, heading, style, route, zoom, screen, and recovery work.

### Tests

- Add a pure `MapRenderPolicy` with host tests for time, movement, heading
  wraparound, forced redraw, and noisy stationary heading.
- Replay the same GPX trace before and after the change.
- Assert map-render counts, current position freshness, and maneuver latency.
- Test north-up and course-up independently.
- Test both display sizes and the 1.75-inch rotation path.

### Exit gate

- GPS packets no longer map one-to-one with base-map renders.
- A static/noisy GPS feed does not cause continuous regeneration.
- Maneuver and position freshness meet the global latency gates.
- Map visuals remain correct after route, zoom, style, and screen changes.

## Phase 4: BLE queue semantics for replaceable state

### Objective

Prevent stale GPS replay and prioritize current navigation state after BLE
congestion without weakening ordered protocol traffic.

### Queue policy

Use the existing `NavigationWriteQueue.enqueueCoalescing()` primitive and make
message-class policy explicit:

| Message class | Queue behavior | Reliability |
| --- | --- | --- |
| Authentication, ownership, settings, commands | Ordered; never coalesced | With response |
| Route, catalog, destination, and transfer batches | Atomic and ordered | With response |
| Complete maneuver/navigation snapshot | Priority lane; newest complete snapshot may replace older snapshot | With response |
| GPS position | Latest pending value wins | Without response when the native endpoint supports it |
| Workout telemetry | Preserve existing coalescing and retry semantics | Existing class policy |

Extend `enqueueNavigationWrite()` to accept an optional coalescing key and
priority flag. Use `gps-position` for native and fallback GPS writes. A new
unsent GPS value replaces only an older unsent GPS value.

Do not coalesce fragmented routes, catalogs, authentication, ownership,
settings, transfer control, or any message that is not a complete state
snapshot.

Use `.withoutResponse` only for replaceable high-rate GPS state and only when
the characteristic supports it and CoreBluetooth reports that it can send.
Keep reliable traffic acknowledged. Do not globally change characteristic
write type.

Add queue metrics for maximum depth, packet-class drops, coalesces, retry age,
and oldest pending age.

### Tests

- Unit tests proving repeated GPS writes collapse to the newest value.
- Tests proving priority maneuver state is delivered ahead of GPS backlog.
- Tests proving atomic route/catalog batches are never split or coalesced.
- Tests for write-without-response backpressure and retry behavior.
- Deliberately stall the BLE transport, enqueue changing GPS, recover it, and
  confirm only the latest pending position is sent.
- Repeat with degraded RF conditions and authenticated framing enabled.

### Exit gate

No stale GPS burst is visible after a short BLE stall, no protected traffic is
lost, and maneuver latency meets the global acceptance gate.

## Phase 5: connected display-power state machine

### Objective

Add useful low-power states between fully awake and disconnected deep sleep.

### States

```text
ACTIVE
  saved user brightness
  normal navigation and touch response

DIMMED
  10-25% effective brightness
  reduced UI cadence

DISPLAY_OFF
  panel off or brightness zero
  BLE remains connected or advertising
  nonessential UI work paused
  one full refresh required on wake

TRANSFER
  Wi-Fi/SD/HTTP active
  explicit inactivity timeout
  optional reduced brightness

DEEP_SLEEP
  existing disconnected timeout
  display/peripheral rails off
  BOOT/GPIO0 wake
```

### Initial policy

- Disconnected waiting: dim after 10-15 seconds and turn the display off after
  30-60 seconds.
- Connected but not navigating: use the same initial policy.
- Active navigation: remain visible at saved brightness by default.
- Transfer: remain awake while traffic or activation is active and exit after
  3-5 minutes without useful traffic.
- Active-ride dimming during long straight segments remains an opt-in
  experiment until outdoor testing establishes safe wake thresholds.

Reset inactivity on meaningful events only:

- touch or BOOT interaction;
- screen change;
- navigation start;
- new maneuver;
- pairing code or actionable error;
- entry into a configured distance-to-turn wake threshold; or
- active transfer traffic.

Do not reset inactivity for every GPS or workout packet.

### Display-off integration

When display state is off, the flush callback must acknowledge LVGL flushes
without issuing QSPI traffic and remember that a refresh is needed. On wake:

1. restore the required display rail/state;
2. turn the panel controller on;
3. apply effective brightness;
4. invalidate the active screen; and
5. perform one synchronized full refresh.

Coordinate shutdown and display-off ordering. If black must be written before
panel shutdown, render/flush black before `gfx->displayOff()`. Do not call
`displayOff()` and then attempt to clear panel RAM.

Before any light-sleep work, fix or remove the ineffective declaration in
`Power::powerLightSleepTimer()` and move radio/hardware shutdown out of the
global `Power` constructor into an explicit setup-time method.

### Wake sources

- BLE connection and authenticated navigation start;
- new maneuver or pairing/error state;
- BOOT button;
- touch interrupt; and
- transfer/update state transition.

Verify separately which events can wake only a display-off task versus the
ESP32 from automatic light sleep. Existing deep sleep remains BOOT/GPIO0 only.

### Tests

- Pure state-machine and inactivity-timer tests.
- Prove GPS traffic alone does not prevent dim/off.
- Prove navigation start and maneuver events wake immediately.
- Thousands of panel off/wake cycles during development, then 10,000 cycles as
  a release gate.
- Test display-off while BLE remains connected and while advertising.
- Test pairing, ownership, route start, transfer entry/exit, audio, and error
  presentation from every state.

### Exit gate

Disconnected and connected-idle states show a reproducible current reduction,
wake reliably, and meet the reconnect, touch, display, and maneuver gates.

## Phase 6: event-driven LVGL and main-loop scheduling

### Objective

Remove fixed 5 ms wakeups when there is no work while retaining immediate event
response.

### Implementation sequence

1. Replace the periodic `lv_tick_inc()` timer with an LVGL tick callback backed
   by a monotonic ESP timer source.
2. Use the delay returned by `lv_timer_handler()` to calculate the next UI
   deadline.
3. Start with conservative maximum waits: 50 ms during connected navigation and
   250 ms while disconnected/static.
4. Retain the UI task handle and block on a task notification with the computed
   timeout.
5. Notify the UI task from BLE state publication, touch/BOOT events, display
   state changes, and transfer completion.
6. Give ownership expiry, disconnected shutdown, transfer processing, and PMU
   button handling explicit deadlines instead of running all housekeeping on
   every loop.
7. Preserve interrupt-gated touch behavior and its required fallback cadence.

Callbacks publish state and wake the owner task; they do not mutate LVGL
objects directly.

### Tests

- Host tests for deadline selection and maximum-wait policy.
- Measure loop/UI wakeups per second in every standard scenario.
- Inject a maneuver just after the UI task blocks and verify immediate wake.
- Soak BLE, touch, ownership, disconnected shutdown, transfer, and display wake
  behavior.

### Exit gate

Static scenarios have materially fewer task wakeups, with no latency or
reliability regression.

## Phase 7: dynamic frequency scaling and coordinated automatic light sleep

### Objective

Use the idle windows created by earlier phases without destabilizing BLE,
display, SD, touch, audio, or transfers.

### Step A: dynamic frequency scaling only

Enable ESP-IDF power management with:

- maximum frequency 240 MHz;
- initial minimum frequency 80 MHz; and
- automatic light sleep disabled.

Measure render/flush latency, BLE behavior, and energy. Test 40 MHz only after
80 MHz is stable on both boards.

### Step B: tickless idle and automatic light sleep

Enable tickless idle and automatic light sleep only after Step A passes.
Introduce explicit power-management locks around:

- display rotation and QSPI flush;
- vector-map rendering;
- SD reads/writes and map activation;
- map/firmware transfer;
- audio playback and codec/I2S transitions; and
- any I2C/touch/PMU operation proven sensitive in physical testing.

Do not use the current explicit `powerLightSleep()` path during active BLE
navigation. Coordinated automatic light sleep must be evaluated separately from
deep sleep and display-off.

### Tests

- Build-time configuration tests for both targets.
- Static, map-heavy, transfer, and audio current traces.
- Map render and display flush latency at each minimum CPU frequency.
- Overnight connected-navigation soak with automatic light sleep.
- BLE body-blocking and reconnect tests.
- Touch latency and missed-interrupt tests.

### Exit gate

Dynamic frequency scaling and automatic light sleep land as separate changes.
Each must show reproducible energy savings and independently pass all global
gates.

## Phase 8: BLE and board-level characterization

### BLE experiments

After queue cleanup, test state-dependent radio policy:

- fast advertising for the first 30 seconds after boot, disconnect, or user
  wake, starting with 100-200 ms;
- slow advertising near one second after that window;
- connected-navigation interval experiments near 30-50 ms with zero latency;
- connected-idle interval experiments near 60-100 ms with latency 2-4; and
- TX power P9 versus P3 and P0.

Treat these as requests that iOS may negotiate differently. Record actual
connection parameters where the stack exposes them.

Validate at 0.5 m, 5 m, phone in a jersey pocket with body blocking, outdoors,
and in a busy 2.4 GHz environment. Use the lowest TX power that passes the
body-blocked reliability matrix.

### PMU and audio rail

The 1.75-inch known-good LDO mask includes a bit named as the audio rail. Do not
disable it based on naming alone. With the board schematic and source monitor,
toggle one candidate rail at a time and verify:

- display and touch;
- RTC and battery reporting;
- SD card;
- codec startup and speaker output;
- reboot and wake; and
- idle current before, during, and after audio.

Verify 2.06-inch rail restoration after shutdown/deep-sleep reset. Its current
safe path deliberately preserves PMU state and explicitly forces only the
display rail in normal builds.

### PMU interrupt

Determine from each schematic and physical board whether AXP2101 IRQ is routed
to an ESP32 GPIO usable by firmware. If so, replace periodic I2C event polling
with an interrupt-driven path. If not, retain a deadline-based polling cadence
and document the hardware limitation.

### SD-card characterization

Test at least two or three SD cards. Measure standby current and energy per
identical map render. Test SPI clocks at 4, 8, 12, and 16 MHz for:

- energy per render;
- read errors;
- render latency;
- signal-integrity failures; and
- long-soak behavior on both boards.

Do not unmount or rail-gate SD in the first release unless the measurement
benefit clearly outweighs renderer and filesystem risk.

### Exit gate

Ship only individually measured settings that pass the full RF, display,
storage, audio, wake, and navigation matrices. Preserve conservative defaults
for any board revision that has not been characterized.

## Implementation and PR sequence

Use one focused branch/PR per row unless a phase is split further during
implementation:

| Order | Change | Primary deliverable |
| --- | --- | --- |
| 1 | Instrumentation | Baseline metrics and hardware report |
| 2 | Brightness | Working persisted setting ID 12 and display owner |
| 3 | Static UI/logging | Near-zero static flushes and production build profile |
| 4 | Dirty model/map scheduler | Bounded base-map renders with immediate overlays |
| 5 | BLE queue semantics | Latest-value GPS and prioritized maneuver state |
| 6 | Display state machine | Dim/off connected-idle behavior and reliable wake |
| 7 | Event-driven scheduler | Deadline/task-notification-based UI loop |
| 8 | DFS | 80-240 MHz scaling without automatic light sleep |
| 9 | Automatic light sleep | Tickless idle, locks, and soak validation |
| 10 | BLE/PMU/SD tuning | Measured target-specific tuning only |

Each implementation PR must include:

- the exact baseline commit and tested head commit;
- tests and build results;
- physical board(s), board revision(s), SD card(s), and measurement equipment;
- before/after scenario results with variance;
- navigation and reconnect latency results;
- known risks and rollback method; and
- an update to the hardware-validation document when behavior or measurements
  change.

## File map

Expected areas of change:

```text
docs/
  ble-protocol.md
  firmware-battery-life-hardware-validation.md

esp32/
  platformio.ini
  sdkconfig or target-specific sdkconfig fragments
  src/main.cpp
  lib/display_power/
  lib/panel/WAVESHARE_AMOLED_175.cpp
  lib/power/power.cpp
  lib/ble_navigation/ble_navigation.cpp
  lib/gui/src/mainScr.cpp
  lib/gui/src/waitingScr.cpp
  lib/gui/src/notifyBar.cpp
  lib/gui/src/batteryStatusScr.cpp
  lib/lvgl/src/lvglSetup.cpp
  lib/maps/src/maps.cpp
  lib/tasks/tasks.hpp
  lib/waveshare_board/axp2101.cpp
  lib/waveshare_board/waveshare_board.hpp
  tools/tests/

ios-app/BikeComputer/
  BikeComputer/Managers/BLEManager.swift
  BikeComputer/Utilities/NavigationWriteQueue.swift
  BikeComputerTests/
```

The exact layout may change during implementation, but display-power ownership,
map-render policy, and queue policy should remain independently testable rather
than accumulating in `main.cpp`, `mainScr.cpp`, or `BLEManager.swift`.

## Final release checklist

- [ ] Brightness works, persists, and restores on both boards.
- [ ] Nonvisual BLE settings do not redraw the map.
- [ ] Static waiting and status screens do not generate periodic full-frame
      flushes for unchanged content.
- [ ] GPS ingestion is independent from base-map render cadence.
- [ ] GPS writes coalesce without weakening protected message classes.
- [ ] Dim/off policies do not treat GPS traffic as user activity.
- [ ] Display wake is corruption-free across 10,000 cycles.
- [ ] Both production and diagnostic builds remain available.
- [ ] Event-driven scheduling passes navigation, BLE, touch, and transfer soak
      tests.
- [ ] DFS and automatic light sleep are measured and landed separately.
- [ ] BLE/PMU/SD tuning is backed by target-specific physical evidence.
- [ ] The complete scenario matrix and usable-battery runtime projection are
      recorded for both targets.
- [ ] No published battery-life claim relies on estimated or additive
      percentages.

## Technical references

- [LVGL 9 tick interface](https://docs.lvgl.io/9.2/porting/tick.html)
- [ESP-IDF ESP32-S3 power management](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-reference/system/power_management.html)
- [ESP-IDF sleep modes](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-reference/system/sleep_modes.html)
- [NimBLE-Arduino server API](https://h2zero.github.io/NimBLE-Arduino/class_nim_b_l_e_server.html)
- [Waveshare ESP32-S3 Touch AMOLED 1.75 schematic](https://files.waveshare.com/wiki/ESP32-S3-Touch-AMOLED-1.75/ESP32-S3-Touch-AMOLED-1.75.pdf)
