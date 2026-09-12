# Waveshare 3.97-inch e-paper firmware implementation plan

## Outcome and baseline

Add the **Waveshare ESP32-S3-ePaper-3.97** as a separately identified Bicino
firmware target. It should pair with the existing companion app, show navigation
and ride data, render installed offline maps, accept physical-button input, and
support the existing authenticated transfer and update flows. Its presentation
must suit a slow, reflective, monochrome display.

This is an implementation proposal, prepared on 2026-09-12 from freshly fetched
GitHub `main` at `ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157`. The branch adds this
plan and reference material; it does not implement or physically qualify the
board. Rebase the implementation assessment onto current main before coding.

The supplied `IMG_1132.PNG` through `IMG_1135.PNG` identify this product family.
They show battery, battery-free `-EN`, and kit options; they do not establish
which PCB revision or battery is physically available. The listing and reference
files are hardware evidence, not instructions to execute their example programs.

Primary references:

- [Official board documentation](https://docs.waveshare.com/ESP32-S3-ePaper-3.97)
  and [product specifications](https://www.waveshare.com/product/displays/e-paper/esp32-s3-epaper-3.97.htm).
- [Downloaded reference index](../../hardware/reference/boards/waveshare-epaper-397/README.md),
  including every PDF linked on the English resources page and the complete
  official example repository expanded from its downloaded archive.
- [Vendor example source](https://github.com/waveshareteam/ESP32-S3-ePaper-3.97/tree/9b12d40731a80213b927ee8a421cae4082952819),
  pinned at `9b12d40731a80213b927ee8a421cae4082952819` for this assessment.

## Hardware contract to establish

| Item | Evidence and implementation consequence |
| --- | --- |
| Processor and memory | ESP32-S3-WROOM-1-N16R8, 16 MB flash and 8 MB PSRAM. Keep the existing ESP32-S3 Arduino/pioarduino runtime and verify detected capacities during bring-up. One English product-page sentence reverses the memory sizes; the module designation, screenshots, and board documentation agree. |
| Display | 3.97-inch reflective e-paper, 800 × 480 native driver buffer, black/white with a separate four-gray mode. The linked panel datasheet identifies SSD1677. Use the exact vendor panel sequence as the starting point. |
| Controls | Three active-low up/center/down contacts and BOOT; PWR uses the power-management path. No touch controller is documented for this product. |
| Storage and sensors | microSD, PCF85063 RTC, QMI8658 IMU, and SHTC3 temperature/humidity sensor. Position continues to come from the current phone/Watch protocol; an onboard GNSS receiver is not documented. |
| Audio | ES8311 codec, NS4150B amplifier, microphone, and speaker connector. Existing sound assets and playback service are reusable after pin and gain qualification. |
| Power | The listing says **TG28**, while the downloadable schematic labels the PMIC **AXP2101** and the official integrated demo uses an AXP2101 driver. Register compatibility and populated rail routing remain unresolved for the actual board. |

The [panel datasheet](../../hardware/reference/boards/waveshare-epaper-397/3.97inch-epaper-datasheet.pdf)
gives 23°C typical full/fast/partial/four-gray updates of 3/1.5/0.3/3 seconds;
the board product page lists 3.5/2.8/0.6/3.5 seconds. Use the slower board figures
for initial planning, then measure end-to-end latency. Neither table establishes
a safe continuous refresh duty cycle or a whole-device battery-life figure.
The panel lists a 0–50°C operating range; outdoor qualification must also cover
sun exposure, moisture protection, vibration, and readability without a backlight.

### Candidate pin map

These are **vendor source values**, to be reconciled with the schematic and the
physical PCB before being treated as a verified hardware contract.

| Function | GPIO / value | Vendor source within the pinned archive |
| --- | --- | --- |
| E-paper SPI | SCK 11, MOSI 12, CS 10, DC 9 | `Arduino/examples/02_E-Paper_Example/DEV_Config.h` |
| E-paper control | RST 46, BUSY 3; HIGH means busy | Same header and `EPD_3in97.cpp` |
| Shared I2C | SDA 41, SCL 42 | `Arduino/examples/03_I2C_PCF85063/user_config.h` |
| Known I2C addresses | RTC `0x51`, SHTC3 `0x70`, ES8311 `0x18` | RTC configuration and `Arduino/examples/01_Audio_Test/es8311.h` |
| SDMMC | CLK 16, CMD 17, D0 15; optional D1 7, D2 8, D3 18 | `Arduino/examples/05_SD_Test/05_SD_Test.ino` |
| Three-way switch | Up 4, center 5, down 6; input pull-ups | `ESP-IDF/08_ESP32-S3_e-Paper-3.97/components/button_bsp/button_bsp.c` |
| BOOT | GPIO0, active low | Same button source |
| Audio | MCLK 13, BCLK 14, LRCK 47, DOUT 48, DIN 21, amplifier control 39 | `Arduino/examples/01_Audio_Test/01_Audio_Test.ino` |
| USB | GPIO19/20 | Board schematic; reserve for USB |
| PMIC, RTC, and IMU interrupt routing | Unresolved | Reconcile the full schematic, populated straps, and examples before enabling IRQ or wake paths |

Specific traps to resolve in the hardware record:

- `06_QMI8658A.ino` declares `SENSOR_IRQ=39`, overlapping the audio demo's
  amplifier control. Do not enable both based only on those examples.
- The Arduino SD example selects one-bit operation even though it supplies all
  six pins; the integrated ESP-IDF demo selects four-bit. Start with one-bit
  SDMMC on the new pins and qualify four-bit separately if useful.
- The Arduino display example bit-bangs SPI, waits for BUSY without a timeout,
  and enables a code path whose `EPD_PWR_PIN` is `-1`. Port the necessary panel
  behavior, not those application assumptions. Never drive an absent pin.
- The integrated vendor PMIC example changes rails, charging, watchdog, and RTC
  backup charging. Those settings must not be copied into the bike firmware.
  Battery chemistry, limits, connector polarity, and backup-cell type must be
  known before charge configuration or output-rail writes are permitted.

## Current firmware integration points

The code at the baseline already separates map rendering from LVGL presentation,
but hardware selection and several services explicitly recognize only the two
AMOLED boards. Adding a PlatformIO environment alone will not enable the port.

| Area | Current source | Required change |
| --- | --- | --- |
| Build and pins | [`platformio.ini`](../../esp32/platformio.ini), [`hal.hpp`](../../esp32/include/hal.hpp), [`panelSelect.hpp`](../../esp32/lib/panel/panelSelect.hpp) | Add a distinct target and explicit board traits; remove accidental fallback to 1.75/2.06 behavior for the new target. |
| Display and touch | [`WAVESHARE_AMOLED_175.cpp`](../../esp32/lib/panel/WAVESHARE_AMOLED_175.cpp), [`display.hpp`](../../esp32/lib/waveshare_board/display.hpp) | Introduce an e-paper backend and input backend. Preserve the AMOLED full RGB565 buffer and `LV_DISPLAY_RENDER_MODE_FULL` behavior. |
| Startup and pairing | [`main.cpp`](../../esp32/src/main.cpp), [`ble_navigation.cpp`](../../esp32/lib/ble_navigation/ble_navigation.cpp) | Generalize initialization and presentation completion, retaining ownership confirmation and ready-state ordering. |
| UI and maps | [`mainScr.cpp`](../../esp32/lib/gui/src/mainScr.cpp), [`maps.cpp`](../../esp32/lib/maps/src/maps.cpp), [`map render scheduler`](../firmware-map-render-scheduler.md) | Add rectangular layouts, monochrome styling, and an e-paper presentation cadence while preserving renderer ownership and cancellation rules. |
| Peripherals | [`waveshare_board/`](../../esp32/lib/waveshare_board/), [`storage.cpp`](../../esp32/lib/storage/storage.cpp), [`speaker.cpp`](../../esp32/lib/speaker/speaker.cpp), [`battery.cpp`](../../esp32/lib/battery/battery.cpp) | Reuse chip-level logic through explicit pins, capabilities, and qualified power policy. |
| Sleep and display policy | [`display_power.cpp`](../../esp32/lib/display_power/display_power.cpp), [`power_management/`](../../esp32/lib/power_management/), [`power documentation`](../firmware-power-management.md) | Replace direct CO5300 brightness/on/off assumptions with display operations appropriate to each backend. |
| Capability contract | [`device_capabilities_protocol.hpp`](../../esp32/lib/ble_navigation/device_capabilities_protocol.hpp), [`ride-ble-contract-v1.json`](../../protocol/ride-ble-contract-v1.json), [`BLEManager.swift`](../../ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift) | Describe the display/input capabilities and supported settings without changing existing navigation framing. |
| Delivery | [`build_firmware.py`](../../esp32/tools/build_firmware.py), [`prebuild.py`](../../esp32/prebuild.py), [`device_registry.py`](../../esp32/tools/device_registry.py), [CI target selection](../../.github/scripts/changed_components.py) | Extend the explicit verified-target policy, provenance, device identity, tests, and CI matrix. Current prefix checks are AMOLED-specific. |

Audit direct AMOLED header includes and `#if`/`#else` branches across these areas.
For example, the existing speaker fallback selects the 2.06 pin/gain set, and
display power calls `gfx->setBrightness()` directly. Neither is valid for 3.97.
The current screen contract is an enabled-screen mask plus default-screen
selection; retain those semantics rather than assuming an unmerged screen-model
proposal is present.

## Design decisions

### 1. One firmware core, explicit board capabilities

Use `WAVESHARE_EPAPER_397` as the canonical new hardware target. Introduce a
small board description covering geometry, display kind, input kind, I2C pins,
SDMMC pins/width, audio pins, and available peripherals. Share only services
that have the same contract. Keep CO5300, touch reset, and existing AMOLED
power policy in their current backend.

Add narrow proposed modules such as `lib/epaper_display/` and
`lib/board_input/`, with a display interface for initialization, frame intake,
presentation status, idle/sleep, wake, and diagnostics. The interface must not
pretend e-paper has brightness or touch. Avoid a wholesale renderer rewrite or
upgrading LVGL/Arduino as part of the port.

The e-paper target should use the repository's pinned runtime, source identity,
custom-core configuration, dependency attestation, and flash-plan pipeline.
Factor the neutral parts of `waveshare_amoled_common` into a shared base, then
inherit panel-specific flags separately. Do not define an AMOLED macro just to
get through the existing build wrapper.

### 2. Asynchronous physical presentation

Keep LVGL 9 and RGB565 composition initially. For this board, convert a completed
logical frame into a packed one-bit image, applying the portrait transform in
that pass. Compute dirty regions from **packed pixels versus the last physically
presented image**, so an LVGL invalidation alone cannot trigger panel wear.

Use a dedicated display worker with bounded states:

```text
Idle -> Prepare immutable frame -> SPI transfer -> Wait for BUSY release
     -> Record presentation completion -> Idle
                           failure -> bounded recovery -> Idle or Fault
```

Contract:

1. The LVGL task owns LVGL and its draw buffer. It may acknowledge
   `lv_display_flush_ready()` only after conversion/copy has finished consuming
   that buffer; the worker must never retain an LVGL-owned buffer afterward.
2. Keep a fixed pool for desired, in-flight, and last-presented monochrome
   images. Transfer exclusive ownership under a short handoff; never read a
   desired buffer while the UI is writing it. Coalesce pending ordinary updates
   to the latest complete frame instead of growing a queue.
3. Use hardware SPI with bounded transfers and a small internal DMA staging
   buffer. BUSY waits must yield and have deadlines; hold neither the LVGL nor
   shared I2C/storage lock while waiting. Preserve watchdog coverage.
4. Track queued, transmitted, and presented generations separately. Record a
   presented generation only after the matching waveform completes successfully.
   SPI completion and LVGL flush acknowledgement are insufficient.
5. Give pairing, navigation-state changes, disconnect/stale-data messages, and
   explicit page changes priority over routine metrics. An active waveform
   completes before another starts. Revalidate semantic generations before
   transfer and after completion; late frames must never confirm a newer state.
6. On uncertain panel RAM history, reset/reinitialize and establish the vendor
   full/base image before partial refresh. Preserve the old/new RAM-plane
   relationship required by the controller. Re-establish it after deep sleep,
   a failed transfer, or a grayscale-mode change.
7. Clip dirty rectangles in native coordinates and align the packed axis to
   byte boundaries. Pack each partial window with the correct stride and
   exclusive-end convention; do not reuse the demo's unchecked rounding logic.
8. Start with one bounded reset/reinitialize retry after a timeout, then expose
   a display fault through diagnostics and the app while allowing BLE/control
   work to continue. Never mark the unseen frame presented or reboot endlessly.

Port and retain the license notices of the vendor driver files actually reused.
Keep the expanded vendor snapshot as reference; it is not a build dependency
and its example firmware binaries are not Bicino images.

### 3. Preserve physical pairing confirmation

The current ownership flow waits for the comparison screen to be rendered and
then requires fresh BOOT/PWR input. Adapt that gate to the e-paper worker's
**successful physical presentation generation**, rather than the earlier LVGL
flush acknowledgement.

The center key can confirm the displayed comparison. Require a released state
after the matching code becomes visible and then a fresh press. Discard keys
queued while the old image was visible. Pairing cancellation, timeout, code
replacement, display failure, and wake invalidate the armed generation. Keep
recovery/reset gestures deliberate and exclude ordinary screen-navigation
presses from ownership recovery. Never bypass this gate to simplify bring-up.

### 4. A complete e-paper screen and control profile

Use **480 × 800 portrait** as the initial logical layout, matching the handheld
orientation in the screenshots; implement and test the conversion to the vendor's
800 × 480 buffer. Landscape can use the same layout constraints later without
changing transport or panel memory identity.

Required screens are welcome/pairing, waiting/connection status, navigation,
ride statistics, map, map plus guidance, battery/status, and transfer/update
progress. Use black text on white, stable positions, sufficiently large digits,
and explicit text/symbols for state. Keep QR codes and pairing digits strictly
binary. Replace round clipping and fixed 466/410-pixel assumptions with tested
rectangular layout constraints.

| Control | Normal behavior | Context behavior |
| --- | --- | --- |
| Up / down | Previous / next enabled screen | Move focus in an explicit menu; bounded auto-repeat after debounce |
| Center press | Open/activate the current screen action | Confirm a visible pairing code or select the focused action |
| Center hold | Open contextual actions | Map actions include zoom in/out, recenter, and return; provide a visible cancel/back action |
| BOOT | Retain existing short-press screen-cycle behavior | Preserve bootloader and deliberate ownership-recovery behavior |
| PWR | Retain configured sound/power behavior after PMIC qualification | Consume pairing input through the same fresh-event gate; do not also honk |

Represent these as semantic actions shared with existing screen handlers.
Use LVGL focus groups for interactive controls where appropriate. Do not invent
a quadrature encoder protocol for the three independent contacts, and do not
simulate touch coordinates to reach otherwise inaccessible actions. Pairing and
core navigation must remain usable through GPIO buttons if PMIC events are
unavailable.

### 5. Map and refresh policy

Retain the IceNav-derived map formats, signed map installation, storage worker,
route handling, and render-ahead ownership model. An e-paper presentation policy
captures one coherent base map, route, and rider pose for each visible map
update. Do not keep animating transforms, heading, or inertia between physical
refreshes. Preserve the existing style/navigation/map-root epochs so a late
worker result cannot overwrite a new screen or route.

Default to a stable 2D map with a strong route line, white route halo, distinct
rider symbol, readable labels, and sparse road/building detail. Color-dependent
meaning must become line weight, pattern, or explicit symbols before one-bit
conversion. Keep 3D/perspective and continuous course-up animation unavailable
on this target until a useful, measured e-paper presentation is established.
The capability response must agree with these limits.

Initial **tuning candidates**, subject to panel duty-cycle and physical tests:

| Content | Scheduling policy |
| --- | --- |
| Changed speed, distance, elapsed time | Batch into stable partial-update regions; initially at most one presentation request per second |
| New maneuver, reroute, stale GPS, disconnect | Prioritize at the next legal panel opportunity; continue ingesting fresh navigation and telemetry while the panel is busy |
| Base map, route, rider pose | Begin with a coherent update every 3–5 seconds while moving, with movement/heading thresholds; explicit zoom/recenter requests bypass ordinary cadence when legal |
| Static screen | No refresh if packed pixels are unchanged |
| Full cleaning | Required on initialization or lost base history, plus a measured maximum partial-count/elapsed-time policy; schedule opportunistically before its hard limit |
| Four-gray rendering | Optional static overview after black/white qualification; do not switch waveform modes for live ride digits |

Decouple receive timestamps and ride accounting from presentation timestamps.
Frozen e-paper content must not imply fresh GPS or an active connection; reserve
an explicit stale/disconnected treatment and prioritize it when detected. Never
predict a live turn solely to hide display latency. Measure input-to-visible
latency during a worst-case full refresh before claiming the device is suitable
for on-road navigation.

### 6. Memory and resource budget

The larger display makes memory qualification part of implementation:

| Allocation | Raw bytes before allocator overhead |
| --- | ---: |
| 800 × 480 RGB565 LVGL draw buffer | 768,000 |
| One native one-bit frame | 48,000 |
| Three one-bit ownership buffers | 144,000 |
| Optional two-bit grayscale frame | 96,000 |
| Two full-portrait map buffers with the current 96-pixel overscan on every edge | 2,666,496 |
| 480 × 800 RGB565+A8 route foreground | 1,152,000 |

The LVGL buffer, three monochrome buffers, two example map buffers, and foreground
already total **4,730,496 bytes**, excluding map blocks, fonts, stacks, TLS, BLE,
diagnostics, alignment, and transient workspaces. This is a calculation for a
proposed full-height viewport, not a measurement of an implemented allocation.

Keep large surfaces in PSRAM and retain the current internal/DMA reserve and TLS
allocation policy. Capture largest free blocks as well as total free memory
during concurrent display, map, BLE, and transfer work. Do not multiply surfaces
for each selectable screen. Reduce the e-paper map viewport or implement a
bounded presentation-specific surface budget if needed; do not weaken existing
renderer coverage checks to make allocations fit.

### 7. Peripheral and sleep integration

Parameterize shared I2C access and chip drivers, preserving serialization,
timeouts, and error recovery. Boot with PMIC discovery and diagnostics that do
not change rails or charge settings. The existing AMOLED PMIC policies are not
proof that this board has the same populated power network.

Use one-bit SDMMC on GPIO16/17/15 first. Keep filesystem paths, map-root
activation, integrity checks, and failure behavior compatible. Disable the
AMOLED-specific legacy SPI migration pin path for this board; a missing card
must not lead to formatting or driving GPIO3, which is e-paper BUSY here.
Keep navigation/ride screens available when maps cannot be mounted.

Bring up RTC retention and battery reporting once the component identity is
confirmed. Reuse speaker assets and the ES8311 service with explicit new pins
and a conservative board-specific gain limit. Qualify sound independently of
display refresh and I2C sensor access. SHTC3 reporting and IMU diagnostics are
useful additions after core operation; IMU-based ride automation remains behind
its existing qualification policy. Microphone/AI voice functionality is outside
the bike-computer compatibility requirement.

For e-paper, connected inactivity means stopping unnecessary updates and safely
idling the panel, while BLE can remain active. Do not issue brightness commands
or force periodic redraws merely because the AMOLED policy dims after a timeout.
Before deep sleep, finish or abandon display work through a bounded shutdown,
persist/close storage work, and clear an active ride/pairing presentation when
the panel can still update. Configure a verified released GPIO wake source;
BOOT is the initial candidate. Wake must rebuild controller base history before
partial updates. Keep whole-board rail shutdown and automatic light sleep
disabled until separately qualified. Abrupt power loss can retain an old image;
the next boot must replace it before claiming current state.

## Implementation sequence and exit gates

### Phase 0 — Pin the hardware contract

Confirm physical model, PCB revision, panel/FPC identity, battery and backup-cell
type. Reconcile the PMIC and GPIO39 conflicts, trace populated panel/audio power
straps, and record a board-specific pin/rail table under `hardware/`. Record the
vendor revision, source URLs, license notices, and reference hashes already
provided by this branch. Obtain or measure safe refresh cadence/cleaning bounds.

**Exit:** no unresolved pin conflict or speculative power write is required for
USB-powered display, GPIO input, BLE, and SD bring-up. Remaining peripheral
limitations are explicit and disabled.

### Phase 1 — Target identity and build support

Add `WAVESHARE_EPAPER_397` and an opt-in bring-up profile. Generalize explicit
target allowlists in the locked build wrapper, prebuild identity checks, device
registry, flash-plan validation, and profile tests. Add the board/backend
selection seam and host tests before attempting a firmware build.

Retain 16 MB flash accounting. Assess the current 3 MiB production OTA slots
against the linked image; ordinary diagnostic builds currently use a separate
6 MiB single-app layout. Keep those meanings distinct. If the new target needs
a different production partition layout, define it before release, preserve NVS
and required filesystem behavior, and document first-install/migration rules.
Do not change existing boards' partition offsets to make this target fit.

**Exit:** verified build provenance names the new target and exact profile; the
new environment cannot select AMOLED pins or escape attestation. Existing
AMOLED profiles still build with their intended configuration.

### Phase 2 — Display transport and physical completion

Implement SSD1677 initialization, full/base, partial, sleep/wake, packed-window
conversion, and the worker state machine. Use a named repository diagnostic
profile for patterns, text, rotation, boundary rectangles, and stuck-BUSY faults.
Build the host fake-panel and conversion tests before physical qualification.

**Exit:** actual panel observations match generation-completion logs; BLE remains
responsive during full refresh; a BUSY fault terminates within the configured
bound; no unsupported GPIO or PMIC write occurs.

### Phase 3 — Buttons, pairing, and essential screens

Add debounced up/center/down input, semantic screen actions, rectangular layouts,
monochrome assets, and the physical pairing gate. Cover every supported screen
and interactive operation without relying on touch. Disable transition
animations and unnecessary LVGL invalidations for the e-paper profile.

**Exit:** an unclaimed device can be paired, cancelled, re-paired, and used for
navigation and ride statistics; old/held keys never confirm an unseen code.

### Phase 4 — Offline maps, peripherals, and power

Parameterize storage and shared peripheral drivers; implement the stable map
presentation policy and memory budget. Qualify map installation/activation,
missing-card behavior, route changes, battery/RTC, sound, connected idle, deep
sleep, and wake. Add SHTC3/IMU support only through their verified interfaces.

**Exit:** maps and guidance are readable at the full logical size; renderer epochs
and storage ownership hold under updates; concurrent workload fits memory; all
advertised peripherals and sleep paths have evidence or remain disabled.

### Phase 5 — Companion capability and update integration

Extend the existing capability contract with versioned, backward-compatible
display/input metadata and supported-setting flags. Allocate identifiers in
`protocol/ride-ble-contract-v1.json`, regenerate both sides, and test parsing of
old, new, unknown, and truncated payloads. Audit the existing CAP2 fixed output
capacity before adding metadata. Keep BLE UUIDs and route/GPS/ride wire formats
stable unless an independently justified protocol change is required.

Update the app to name the new board and hide unsupported brightness, touch,
rotation, and 3D controls. Firmware must reject or safely normalize unsupported
settings from older apps; UI hiding alone is insufficient. Preserve existing
screen-mask/default-screen persistence and recover to an enabled screen after
invalid configuration.

Keep the canonical new target in firmware metadata, signed manifests, and app
update selection. Extend release-candidate/history/factory-package allowlists
and tests deliberately; the iOS historical short-SHA exceptions remain specific
to the old releases. Both app and firmware must reject an AMOLED image for this
board and an e-paper image for either AMOLED board. Do not publish an OTA entry
until this target has completed its production qualification.

**Exit:** compatible app/device pairs expose usable settings, older clients fail
safely, and target mismatch/invalid signature/oversize images are rejected before
flash writes. Production update rollback and post-boot acceptance are exercised
on the exact new-target image.

### Phase 6 — CI, ride qualification, and delivery

Add an explicit `397` hardware selection to CI planning and workflow tests, with
ordinary/diagnostic/production profile coverage appropriate to each job. Current
automatic CI selects 1.75 profiles; a green aggregate gate cannot be treated as
3.97 or 2.06 build evidence. Shared backend changes need explicit regression
coverage on all affected boards. Keep diagnostics out of released images.

Record exact-source build, CI, device identity, upload, boot acceptance, physical
panel observations, and power results separately. Update `hardware/README.md`,
firmware profile/provenance/factory-release documentation, and the protocol
document as those features land. A release is complete only when the target's
hardware gate, production image identity, and recovery path are all recorded.

## Verification matrix

| Layer | Required cases and evidence |
| --- | --- |
| Host: raster and layout | Native/portrait coordinate round trips; corners and all edges; byte alignment and padded partial stride; polarity; unchanged-frame suppression; readable QR/pairing digits; long/localized text; no round-screen clipping. |
| Host: worker and priority | Updates arriving during transfer/BUSY; bounded latest-frame queue; timeout/recovery; cancellation on page/route change; cleaning deadline; completion recorded only for the correct generation; no borrowed buffer lifetime violation. |
| Host: ownership/input | Press before code presentation, held key through refresh, new code while old frame is in flight, cancellation, timeout, display failure, debounce/repeat, PWR/BOOT/center collisions, and recovery gesture separation. |
| Host: resources and contract | New/old board pin tables; memory sizing overflow checks; missing optional hardware; SD migration exclusion; capability compatibility; update target/signature/partition checks; build-profile and CI target allowlists. |
| Build | Locked verified builds for new 397 profiles and affected existing 175/206 profiles. Run existing firmware host suites, generated BLE contract check, and portable Swift navigation/BLE tests for companion changes. |
| Physical: panel | Cold initialization, black/white patterns, partial edges, many updates, full cleaning, temperature-dependent behavior, sleep/wake, measured ghosting and visible latency. Confirm controller base-history recovery. |
| Physical: concurrency | Sustained GPS/ride telemetry while full/partial refresh, SD rendering, sound, and authenticated transfer run; no watchdog resets, lost control events, growing queues, or unexplained BLE disconnects. |
| Physical: recovery | USB-only and battery-only cold starts, reset during display activity, missing/corrupt/removed SD, lost phone/GPS, low battery, interrupted map transfer, interrupted update, rollback, and deliberate ownership recovery. |
| Physical: cycling | Stationary replay first, then a controlled ride: short-spaced turns, reroute, speed changes, glove operation, sunlight/night readability, vibration, and stale-state visibility. Log data receipt and photograph/video actual display completion. |
| Power | Whole-device current in active navigation, static connected display, map transfer, sound, disconnected idle, and deep sleep; specify battery capacity and conditions before stating endurance. |

Proposed responsiveness gates: ordinary input processing and BLE callbacks must
not wait for a waveform; pending frame storage stays bounded; a latest priority
update is presented at the next legal opportunity without waiting behind routine
frames. Record p50/p95/max visible delay and missed/late maneuver observations.
Set numeric release thresholds and panel duty-cycle limits from Phase 0/2
measurements, then require them to pass; the advertised partial time alone is
not a release criterion.

Any later physical work follows the repository's device-identification and
exact-image flash-confirmation procedure. This planning/reference branch does
not authorize a build, flash, PMIC modification, or physical test, and provides
no such evidence.
