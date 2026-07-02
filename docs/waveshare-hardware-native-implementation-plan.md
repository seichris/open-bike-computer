# Waveshare Hardware-Native Implementation Plan

This plan covers follow-up firmware work for the Waveshare ESP32-S3 Touch
AMOLED 1.75 board based on the verified hardware reference in
`WAVESHARE_HARDWARE.md`.

The work should be split into small PRs. These changes touch boot sequencing,
power rails, shared I2C behavior, display addressing, input handling, storage,
and new hardware devices. Keeping them separate makes hardware regressions
easier to bisect and keeps review focused.

## Current Baseline

Already implemented:

- Correct shared I2C pins: SDA `GPIO15`, SCL `GPIO14`.
- Correct CO5300 QSPI display pins.
- Correct CST9217 touch address and TCA9554 P0 reset path.
- Correct SD card SPI pins: CS `GPIO41`, MOSI `GPIO1`, MISO `GPIO3`, SCK
  `GPIO2`.
- SD card isolated on HSPI instead of the display QSPI path.
- Boot-time I2C bus recovery.
- Boot-time AXP2101 rail enable sequence.
- Full-screen LVGL buffer in PSRAM to avoid AMOLED partial-update artifacts.

Known remaining gaps:

- AXP2101 is handled with raw boot-time writes instead of a real PMU module.
- I2C recovery is boot-only and not shared by all I2C clients.
- PCF85063 RTC integration is in progress in PR 14; BLE sync and warm-reset
  retention are verified. Full USB power removal does not retain RTC time on
  the current board because AXP2101 reports `battery=absent` and the PCF85063
  voltage-low flag is set after replug.
- QMI8658 IMU integration is in progress in PR 15. The first pass detects,
  configures, and samples the sensor at low rate for diagnostics only;
  navigation behavior does not depend on it.
- CO5300 90-degree rotation still has a green-edge/window artifact.
- CST9217 touch correctly treats GPIO21 as an active-low hint plus throttled
  polling fallback; the next work should measure and centralize that policy, not
  make GPIO21 the only source of truth.
- Storage debug logging and SPI speed are not tuned for production use.
- Audio should be treated as a later bring-up track. The official schematic
  exposes codec/audio nets, but the local hardware reference says ES8311 was
  not detected in the reference scan.

## PR Strategy

Use a stacked sequence, not one large PR.

Recommended order:

1. PR 8: Board support cleanup.
2. PR 10: AXP2101 PMU integration.
3. PR 11: Shared I2C resilience.
4. PR 12: CST9217 touch hint/fallback optimization.
5. PR 13: CO5300 display window and rotation fix.
6. PR 14: PCF85063 RTC integration.
7. PR 15: QMI8658 IMU integration.
8. PR 16: SD and map I/O tuning.

GitHub PR #9 is unrelated to this hardware-native sequence, so the AXP2101 PMU
work is numbered as PR 10 in this plan.

Only combine changes when they are mechanically related and low risk. In
practice, PR 8 may include small comments/build cleanup, but PRs 10-16 should
remain separate.

GPS is intentionally excluded from this sequence because this hardware model
does not have GPS populated. Audio is also excluded from the core sequence: it
needs separate codec-enable and I2S bring-up after the board basics are stable.

## Researched Answers

Internet research against the official Waveshare docs/schematic and vendor
datasheets narrows several questions:

- This board model should be treated as no-GPS hardware. Do not spend a PR on
  UART GPS bring-up for this target.
- The AXP2101 rail names are visible in the official schematic. Known nets
  include `VCC3V3`, `VCC-RTC`, `A3V3`, `CPUSLDO`, `DCDC1-5`, `ALDO1-4`, and
  `BLDO1-2`. The first PMU PR should preserve the current broad rail-enable
  behavior, then add readback and named rail helpers before any rail is turned
  off aggressively.
- The AXP2101 datasheet exposes battery/charger state and ADC-style telemetry,
  including battery voltage, VBUS/VSYS readings, charging status, and fuel-gauge
  percentage registers. PMU integration can use these instead of ESP32 ADC
  battery estimation once register reads are confirmed on the board.
- The PCF85063 RTC is shown as powered from the AXP2101-backed RTC rail. That
  supports the RTC integration plan, but retention across full power removal
  still needs a real board test.
- The QMI8658 datasheet allows `0x6A` or `0x6B` depending on the address pin;
  the Waveshare schematic points to `0x6B` for this board. Treat `0x6B` as the
  primary address and keep `0x6A` as a fallback/probe only.
- QMI8658 supports standard/fast I2C modes, so `100 kHz` and `400 kHz` are both
  plausible from the IMU side. Board-level stability still decides the final
  bus speed because AXP2101, CST9217, TCA9554, PCF85063, and QMI8658 share the
  bus.
- PR #6/PR #7 bring-up found `100 kHz` I2C plus bus recovery/backoff and
  throttled touch reads to be the stable baseline on Arduino Core 3.x.
- PR #6/PR #7 confirmed CO5300 0-degree mode is clean, 90-degree mode works for
  map/touch but can show a thin green edge, and explicit Arduino_CO5300
  constructor offsets made the edge worse. Preserve driver defaults until
  CASET/PASET experiments are isolated in the display PR.
- PR #6/PR #7 confirmed a 32 GB SDHC card works at the current 4 MHz SPI
  setting on HSPI. Treat 4 MHz/32 GB SDHC as the known-good storage baseline.
- `pio device monitor` can fail in non-interactive PTYs on this setup; use the
  pyserial reset/capture workflow documented in `AGENTS.md` when serial monitor
  capture is unreliable.
- Audio is not blocked purely by unknown pins: the official schematic includes
  codec/audio control and I2S nets. It should remain a separate later bring-up
  because codec enable, I2C detection, and exact I2S mapping need focused
  validation.

Research sources:

- Merged PR #6 bring-up notes:
  `https://github.com/seichris/esp32-bike-computer/pull/6`
- Waveshare product docs:
  `https://docs.waveshare.com/ESP32-S3-Touch-AMOLED-1.75`
- Waveshare schematic PDF:
  `https://files.waveshare.com/wiki/ESP32-S3-Touch-AMOLED-1.75/ESP32-S3-Touch-AMOLED-1.75.pdf`
- AXP2101 datasheet:
  `https://files.waveshare.com/wiki/common/X-power-AXP2101_SWcharge_V1.0.pdf`
- QMI8658C datasheet:
  `https://qstcorp.com/upload/pdf/202202/QMI8658C%20datasheet%20rev%200.9.pdf`
- PCF85063A datasheet:
  `https://www.nxp.com/docs/en/data-sheet/PCF85063A.pdf`

## Live Baseline: 2026-07-01

Connected-device baseline on Chris's Mac:

- `pio run -e WAVESHARE_AMOLED_175` succeeded.
- Upload succeeded over ESP32-S3 USB CDC/JTAG. The board appeared as
  `/dev/cu.usbmodem101` before upload and `/dev/cu.usbmodem2101` after replug.
- Upload detected ESP32-S3, 16 MB flash, and 8 MB embedded PSRAM.
- After upload, the board temporarily disappeared from macOS USB enumeration
  until manually unplugged/replugged.
- Serial capture via pyserial on `/dev/cu.usbmodem2101` reached the expected
  boot path:
  - AXP2101 found.
  - Peripheral power reset/enabled.
  - Arduino_GFX display initialized.
  - SD mounted on HSPI with pins `CS=41`, `MOSI=1`, `MISO=3`, `SCK=2`.
  - SD root listed `.Spotlight-V100`, `.fseventsd`, `MAP`, `WPT`, `VECTMAP`,
    `TRK`, and `.Trashes`.
  - LVGL initialized with full-screen PSRAM buffer.
  - Touch driver registered.
  - BLE server started and advertised as `BikeComputer`.
  - Runtime stayed on the waiting screen with periodic `SYS` heartbeats.

Live symptoms observed:

- First touch initialization attempt reported `TCA9554 not found`, then a later
  attempt found TCA9554 and reset touch successfully.
- Touch interrupt stayed `HIGH(idle)` during capture.
- Touch fallback reads periodically returned `FF FF FF FF FF FF FF` with no ACK.
- Intermittent Arduino Core 3.x I2C failures appeared as
  `ESP_ERR_INVALID_STATE` from `Wire.requestFrom()`.
- USB CDC logging periodically reported `HWCDC write failed due to waiting USB
  Host - timeout`; boot and runtime still progressed.

## PR 10 Connected-Device Findings: 2026-07-01

Validated on branch `axp2101-pmu-integration` with the Waveshare board on
`/dev/cu.usbmodem2101`:

- Upload works normally once the board is out of BOOT/download mode.
- App boot reaches `SPI_FAST_FLASH_BOOT` and stays alive on the waiting screen.
- AXP2101 is found at `0x34`.
- AXP2101 status registers read as `status1=0x20`, `status2=0x15` on USB:
  VBUS good, battery absent, current direction standby, charge status
  `5`/not charging.
- PMU enable register `0x90` readback works:
  - baseline reset `0x1C`
  - baseline on `0x9C`
  - final peripheral/display enable `0x9C`
- AXP2101 voltage registers `0x93` through `0x97` read back as `0x1C`.
- AXP2101 voltage register `0x92` / ALDO1 did not reliably read back `0x1C`;
  captures saw `0x15` and `0x1F`, with one Arduino Core I2C
  `ESP_ERR_INVALID_STATE`. Because final enable register `0x90` verified and
  display, SD, touch, LVGL, and BLE all initialized, PR 10 treats voltage
  readback mismatches as warnings while still requiring final enable readback.
- Display initialization succeeded and the loading/waiting UI appeared.
- SD mounted on HSPI using `CS=41`, `MOSI=1`, `MISO=3`, `SCK=2`.
- LVGL initialized with the full-screen PSRAM buffer.
- TCA9554 touch reset succeeded in the final captures.
- BLE advertised as `BikeComputer`.
- Touch fallback still occasionally logs no-ACK/raw idle bytes and
  `ESP_ERR_INVALID_STATE`; this remains PR 11 shared-I2C work, not a PMU
  blocker.
- `WAVESHARE_AMOLED_175` does not define `POWER_SAVE`, so the BOOT short-press
  light-sleep and long-press deep-sleep UI handlers are not reachable in the
  normal Waveshare firmware. PR 10 test builds that enabled `POWER_SAVE` built
  and flashed, but repeatedly reproduced an IPC task stack-canary panic during
  Bluetooth interrupt allocation. After one test build did reach the waiting
  screen, short-press and long-press BOOT tests did not trigger any visible
  sleep/shutdown transition; the display stayed on the `Bike Computer. Start
  the app...` screen and serial capture produced no PMU/sleep/shutdown logs.
  Do not enable `POWER_SAVE` for Waveshare in PR 10; sleep/wake needs a focused
  follow-up with Bluetooth stack sizing/startup order reviewed and explicit
  GPIO0/button instrumentation.
- Final pre-merge test on the normal `WAVESHARE_AMOLED_175` firmware built and
  uploaded successfully on 2026-07-01. The first reset capture immediately after
  flashing hit one IPC task stack-canary panic during NimBLE initialization, then
  the automatic reboot reached the waiting screen and stayed alive through the
  25-second heartbeat. Three subsequent explicit USB reset captures were clean:
  no panic, PMU enable `0x90` readback `0x9C`, display ready, SD mounted, LVGL
  initialized, BLE advertising, TCA9554 touch reset found, and SYS heartbeats
  through 20 seconds.
- Real USB power-removal/reconnect was tested by watching `/dev/cu.usbmodem*`
  disappear, waiting for reconnect, and capturing serial boot without asserting
  RTS/DTR. The reconnect boot was clean through 30 seconds: AXP2101 was found,
  all voltage registers `0x92` through `0x97` read back `0x1C`, PMU enable
  `0x90` read back `0x9C`, display initialized, SD mounted, LVGL initialized,
  BLE advertised, TCA9554 reset succeeded, and SYS heartbeats continued through
  30 seconds. Touch still showed intermittent idle-read I2C errors, which remain
  PR 11 scope.
- Battery-only cold boot was visually confirmed by unplugging USB and powering
  the board from battery only. The board reached the expected screen. This was
  not serial-captured because connecting USB would add VBUS and change the PMU
  state being tested.
- After the final `POWER_SAVE` long-press test, the temporary firmware stayed on
  the waiting screen and serial reset could not enter the uploader
  (`Failed to connect to ESP32-S3: No serial data received`). Normal firmware
  restoration may require manually entering BOOT/download mode if the board is
  left on a `POWER_SAVE` test image.
- Normal PR 10 firmware was restored after manually entering BOOT/download mode.
  The upload completed and verified successfully. A follow-up pyserial capture
  still reset the chip into `DOWNLOAD(USB/UART0)`, so final visual boot
  verification should use a plain USB-C unplug/replug without holding BOOT
  instead of another serial-reset capture.

Implementation status:

- Implemented `esp32/lib/waveshare_board/axp2101.hpp` and `.cpp`.
- `waveshare_board::enablePowerRails()` now delegates to the AXP2101 helper
  instead of raw register writes.
- AXP2101 register writes now include retry and readback logging.
- PMU status readback logs VBUS/battery/charge state during setup.
- Voltage register readback mismatches are warning-only; final enable register
  readback remains required.
- Waveshare `Power::powerOffPeripherals()` and `Power::deviceSuspend()` now call
  the AXP2101 helper for display/peripheral rail control when compiled for
  `WAVESHARE_AMOLED_175`.
- `POWER_SAVE` remains disabled for `WAVESHARE_AMOLED_175`; sleep and deep
  sleep validation are deferred.
- Latest local verification before opening PR 10:
  - `PLATFORMIO_CORE_DIR=/tmp/esp32-bike-pio-core-313 /tmp/esp32-bike-pio-313/bin/pio run -e WAVESHARE_AMOLED_175`
    passed on 2026-07-01.
  - `git diff --check` passed on 2026-07-01.
  - Normal firmware upload passed after manual BOOT/download mode; final
    no-BOOT visual boot confirmation is the remaining device-side check because
    serial reset can force `DOWNLOAD(USB/UART0)` on this setup.

Implications:

- The PR #6/PR #7 touch/I2C conclusions remain current on the connected device.
- PR 11 can proceed without more hardware discovery, as long as it preserves
  boot behavior.
- PR 11 should include a post-boot I2C recovery path, retry policy, and counters
  because TCA9554 can be missed during early touch init and later become
  reachable.
- PR 12 should keep GPIO21 as a hint plus fallback polling; do not make it the
  only touch trigger.
- PR 16 should gate SD root listing behind debug output because normal boot logs
  currently include macOS metadata entries from the SD card.
- BOOT-button sleep/shutdown should not be treated as validated for PR 10. The
  PMU helper functions compile, but the user-facing sleep/shutdown route is
  currently disabled for the Waveshare env, and a temporary `POWER_SAVE` build
  did not visibly react to short or long BOOT presses while on the waiting
  screen.
- The one post-flash NimBLE panic should be tracked as Bluetooth startup
  robustness work. It was not reproduced in three immediate follow-up USB reset
  captures, so it is not treated as a PR 10 PMU regression by itself.

## Remaining Test Questions

These still need bench validation:

- Which AXP2101 rails can be turned off safely without losing touch, SD, RTC,
  IMU, or display resume behavior?
- Does PCF85063 RTC time survive full battery/USB removal on this assembled
  board?
- Is GPIO21 reliable across multiple boards/firmware states as a hint, and what
  fallback polling cadence gives the best latency/I2C-load tradeoff?
- Is any I2C clock above the known-good `100 kHz` stable under real touch, PMU,
  RTC, and IMU traffic?
- Is the CO5300 controller address space effectively 480x480 with a centered
  466x466 active window, and do rotation-specific CASET/PASET offsets fix the
  green edge?
- Which SD cards and capacities should be part of the mount/speed test matrix?

Hard answers from `WAVESHARE_HARDWARE.md` that should not be reopened unless
new schematic evidence appears:

- Shared I2C is `GPIO15` SDA and `GPIO14` SCL.
- Touch reset is TCA9554 P0 at I2C address `0x20`; never use GPIO20.
- CST9217 touch is at `0x5A`.
- AXP2101 PMU is at `0x34`.
- PCF85063 RTC is at `0x51`.
- SD card is SPI on CS `GPIO41`, MOSI `GPIO1`, MISO `GPIO3`, SCK `GPIO2`.
- SD and touch do not have a pin conflict.
- CO5300 QSPI display pins are CS `GPIO12`, CLK `GPIO38`, D0-D3
  `GPIO4`/`GPIO5`/`GPIO6`/`GPIO7`, reset `GPIO39`.

## PR 8: Board Support Cleanup

Goal: centralize Waveshare-specific board primitives without changing runtime
behavior.

Scope:

- Add a small Waveshare board module, for example:
  - `esp32/lib/waveshare_board/waveshare_board.hpp`
  - `esp32/lib/waveshare_board/waveshare_board.cpp`
- Move boot-time I2C recovery out of `esp32/src/main.cpp`.
- Move raw AXP2101 boot rail writes behind named functions, even if the first
  implementation still writes the same registers.
- Define named constants for:
  - `AXP2101_ADDR = 0x34`
  - `TCA9554_ADDR = 0x20`
  - `CST9217_ADDR = 0x5A`
  - `PCF85063_ADDR = 0x51`
  - `QMI8658_ADDR_PRIMARY = 0x6B`
  - `QMI8658_ADDR_FALLBACK = 0x6A`
- Replace stale comments that point to `.agent/workflows/WAVESHARE_HARDWARE.md`
  with `WAVESHARE_HARDWARE.md`.
- Fix stale `platformio.ini` comments that still describe SDMMC pins for this
  board.

Out of scope:

- Changing PMU behavior.
- Changing touch polling behavior.
- Changing display rotation or LVGL buffer mode.

Validation:

- `cd esp32 && pio run`
- Cold boot on USB.
- Capture serial boot log and compare against the 2026-07-01 live baseline.
- Confirm display powers on.
- Confirm touch still works.
- Confirm SD card still mounts.
- Confirm expected I2C devices are still visible if scanner/debug output is
  enabled.

Acceptance criteria:

- `main.cpp` no longer owns Waveshare low-level boot details.
- Hardware behavior matches the current baseline.
- No new feature flags are required to boot the Waveshare env.

## PR 10: AXP2101 PMU Integration

Goal: treat the AXP2101 as the board PMU rather than a one-time display power
enable sequence.

Scope:

- Add a dedicated AXP2101 helper module or class.
- Implement named rail setup functions:
  - `begin()`
  - `enableDisplayRails()`
  - `enablePeripheralRails()`
  - `setDisplayPower(bool enabled)`
  - `setPeripheralPower(bool enabled)`
  - `restoreDefaultRails()`
- Preserve the currently working rail values until the board schematic/register
  map has been verified.
- Add register readback after writes so boot logs can show whether requested
  rail states actually latched.
- Add battery/charge status primitives if the AXP2101 register map is confirmed:
  - battery present
  - charging/discharging
  - VBUS present
  - battery voltage if supported/configured
- Update `Power::deviceSuspend()` and `Power::deviceShutdown()` to use PMU
  rail control where safe.

Out of scope:

- Aggressive low-power tuning.
- Wake-on-motion.
- RTC alarm wake.

Validation:

- Required before merging PR 10:
  - Build `WAVESHARE_AMOLED_175`.
  - Upload to the connected board over USB CDC/JTAG.
  - Reset/capture serial boot on USB.
  - Confirm AXP2101 is found at `0x34`.
  - Confirm PMU enable register `0x90` reaches/readbacks `0x9C`.
  - Confirm display, LVGL, SD, touch reset, and BLE still initialize.
- Explicitly deferred from PR 10:
  - Full low-voltage/brownout behavior under battery load. Real USB
    power-removal/reconnect passed, and USB reset coverage is enough for PR 10.
  - Display off/on cycle from user-facing sleep; `POWER_SAVE` is disabled for
    `WAVESHARE_AMOLED_175`.
  - Light sleep and wake by BOOT button; enabling `POWER_SAVE` for testing
    reproduced an IPC stack-canary panic during Bluetooth interrupt allocation,
    and short BOOT press did not produce a visible/logged sleep transition.
  - Deep sleep and wake by BOOT button; same `POWER_SAVE` blocker as light
    sleep, and long BOOT press left the device on the waiting screen with no
    visible shutdown warning.

Acceptance criteria:

- PMU writes are named and read back.
- Display and peripherals can be powered down through board-specific code.
- Existing boot stability is not worse than baseline.

## PR 11: Shared I2C Resilience

Goal: make the known I2C instability manageable for all devices on the shared
bus, not just touch.

Implementation status:

- In progress on branch `shared-i2c-resilience`, based on merged PR 10 commit
  `b853488`.
- Added a Waveshare-only shared I2C helper with explicit `100 kHz` default
  clock, `50 ms` transaction timeout, retry wrappers, post-boot bus recovery,
  optional probe/debug-scan helpers, and counters for failed transactions,
  recovery attempts, recovered transactions, and missing devices.
- Migrated current Waveshare AXP2101, TCA9554, and CST9217 register access to
  the shared helper.
- PCF85063 and QMI8658 should use the shared helper when PR 14 and PR 15 add
  RTC/IMU drivers, rather than adding unused reads in PR 11.
- Local build passed on 2026-07-01:
  `PLATFORMIO_CORE_DIR=/tmp/esp32-bike-pio-core-313 /tmp/esp32-bike-pio-313/bin/pio run -e WAVESHARE_AMOLED_175`.
- Connected-device upload passed four times on 2026-07-01 without manually
  entering BOOT/download mode:
  `PLATFORMIO_CORE_DIR=/tmp/esp32-bike-pio-core-313 /tmp/esp32-bike-pio-313/bin/pio run -e WAVESHARE_AMOLED_175 -t upload --upload-port /dev/cu.usbmodem2101`.
- First passive serial capture after PR 11 boot showed AXP2101, display, SD,
  LVGL, BLE advertising, and TCA9554 touch reset initialized successfully
  through a 30-second idle run. It also showed recurring Arduino Core
  `ESP_ERR_INVALID_STATE` touch-read failures while the firmware kept running;
  those failures are now measurable through the PR 11 I2C counters.
- A later passive serial capture saw the USB CDC device re-enumerate/drop with
  `Device not configured`. Treat serial-capture resets as a local USB CDC
  testing caveat, and use plain unplug/replug visual boot confirmation as the
  final practical check before merging.
- Final connected-device check after unplug/replug and reflashing the review-loop
  build passed on 2026-07-01. The device reached the waiting screen and stayed
  running through a 35-second passive serial capture. The `SYS:` heartbeat now
  reports I2C counters on the same line, ending at
  `i2c[fail=8 recover=8 recovered=8 missing=0]`; this confirms the known
  Arduino Core touch-read failures are counted and the bus recovers during
  normal idle operation.

Scope:

- Add a shared I2C helper for Waveshare:
  - bus recovery
  - transaction retry
  - transaction timeout handling
  - optional device probe
  - optional debug scan
- Use helper functions for current AXP2101, TCA9554, and CST9217 access.
- Keep PCF85063 and QMI8658 on the same helper path as their RTC/IMU drivers
  are added.
- Keep polling/logging rate limited to avoid making bus contention worse.
- Add counters for:
  - recovery attempts
  - failed transactions
  - recovered transactions
  - detected missing devices
- Make `100 kHz` the explicit default I2C speed because that was the stable
  bring-up baseline from PR #6/PR #7.
- Consider `Wire.setClock()` experiments behind a single board constant only
  after shared recovery/counters exist. Validate `200 kHz` and `400 kHz` on
  hardware before changing the default.

Out of scope:

- Rewriting each device driver completely.
- Changing touch UX.
- Adding RTC/IMU features.

Validation:

- Long idle run with touch enabled.
- Repeated map pan/touch gestures.
- Repeated suspend/wake.
- Run with I2C scan/debug enabled and confirm no phantom-device storm.
- Confirm failures recover without requiring device reset.

Acceptance criteria:

- I2C recovery is callable after boot.
- Touch failures no longer permanently wedge the bus.
- PMU and touch code share the same transaction policy.

## PR 12: CST9217 Touch Hint/Fallback Optimization

Goal: reduce shared I2C load while preserving the PR #6/PR #7 finding that
GPIO21 is a useful active-low hint, not a perfect sole source of truth.

Implementation status:

- Implemented on branch `touch-hint-fallback-optimization` in PR 12, based on
  merged PR 11.
- Merged into `main` on 2026-07-01 before starting PR 13.
- Added `esp32/lib/waveshare_board/touch.hpp` for CST9217/TCA9554 registers,
  dimensions, GPIO21 hint pin, and touch polling/backoff timing constants.
- Panel touch code now tracks GPIO21 active-low hint level and edges without
  doing I2C work from an ISR.
- Active hint edges can bypass current backoff and trigger an immediate read;
  active/recent hints keep a fast read cadence.
- Idle fallback polling is still present for boards or states where GPIO21
  remains high despite available CST9217 data, but the idle cadence is slower
  than PR 11 to reduce shared I2C load.
- Repeated idle I2C failures now use a bounded increasing retry backoff.
- Dormant non-Arduino_GFX touch config no longer points reset at GPIO20 and uses
  the correct shared I2C SCL pin.

Device validation on 2026-07-01:

- Built and flashed successfully to the connected Waveshare board on
  `/dev/cu.usbmodem2101`.
- Boot stayed healthy after flash: AXP2101 display power, Arduino_GFX display,
  SD card, LVGL, BLE advertising, and TCA9554 touch reset all initialized.
- 45-second no-touch serial capture stayed up without reboot or I2C wedge.
  CST9217 reads still intermittently returned `ESP_ERR_INVALID_STATE`, but PR 11
  I2C recovery kept the bus usable. The latest periodic `SYS` line during that
  capture showed `i2c[fail=5 recover=5 recovered=5]`, followed by two additional
  read errors before the capture ended.
- Tap, drag, and long-press testing produced valid CST9217 touch packets and
  `Touch: press`/`Touch: release` events on the device.
- During tap, drag, and long-press testing, GPIO21 remained `HIGH(idle)`.
  Therefore this hardware/firmware state must keep fallback reads; GPIO21 cannot
  be used as the sole touch readiness source on this unit.
- The fallback path read valid points such as `(204,297)` and `(285,279)` while
  the hint line stayed idle, confirming the fallback path remains necessary and
  functional.
- 10-minute no-touch idle summary capture stayed alive to `SYS: up=599s` with
  zero touch press/release events and zero GPIO21 `LOW(active)` observations.
  The capture saw 76 Arduino Wire `ESP_ERR_INVALID_STATE` lines, but no runtime
  reboot, phantom touch, or visible bus wedge. The only reset lines were the
  expected USB serial reset banner from opening the capture.
- Integrated iPhone navigation smoke test passed. The iPhone connected over BLE,
  sent settings, GPS, route geometry, and navigation instructions; the ESP32
  transitioned to the main map screen with route overlay active. Touch tap/drag
  activity continued to produce valid CST9217 press/release packets while the map
  redrew and BLE stayed connected/authenticated. GPIO21 still remained
  `HIGH(idle)`, so the fallback path remains required under navigation load too.
  The final heartbeat stayed on `screen=main` with `routePts=25`,
  `ble[conn=1 auth=1 nav=2 route=1 gps=1 settings=7]`, and recovering I2C
  counters (`i2c[fail=11 recover=11 recovered=10 missing=0]`).

Scope:

- Move CST9217/TCA9554 constants out of the panel implementation into board or
  touch-specific headers.
- Configure GPIO21 as active-low hint input.
- Track hint edge or level state without doing I2C work inside the ISR.
- Read touch packets promptly after hint activity.
- Keep a throttled polling fallback because observed states can stay idle even
  when touch data exists.
- Tune polling cadence around:
  - idle/no-touch state
  - active touch state
  - recent touch release confirmation
  - repeated I2C failures/backoff
- Keep current coordinate validation and glitch filtering.
- Keep TCA9554 P0 reset path and never use GPIO20.

Out of scope:

- Multi-touch gestures unless packet format is verified.
- UI gesture redesign.

Validation:

- Tap.
- Drag/pan map.
- Long press.
- No-touch idle for at least 10 minutes.
- Repeated suspend/wake.
- Confirm no phantom touches at corners.
- Compare I2C transaction count before/after if counters exist from PR 11.

Acceptance criteria:

- Normal touch interaction uses GPIO21 as a hint where it works.
- Boards or firmware states with unreliable GPIO21 behavior remain usable
  through fallback.
- I2C traffic decreases during idle.

## PR 13: CO5300 Display Window And Rotation Fix

Goal: resolve the 90-degree green-edge artifact and make the 466x466 active
window explicit.

Implementation status:

- In progress on branch `co5300-window-rotation-fix`, based on merged PR 12.
- Re-read `WAVESHARE_HARDWARE.md` and followed its official links. The Waveshare
  wiki confirms this model is a 466x466 CO5300 AMOLED.
- Researched the official Waveshare demo repository. Every Arduino display/LVGL
  demo instantiates `Arduino_CO5300` as `466x466` with constructor offsets
  `6,0,0,0`.
- Researched the official Waveshare ESP-IDF BSP. It applies the same effective
  gap with `esp_lcd_panel_set_gap(panel_handle, 0x06, 0)`.
- Found an ESPHome report for this exact 466x466 CO5300 Waveshare model where a
  missing 6-pixel gap produced a green-line/wrap artifact. That matches our
  symptoms better than the earlier centered-window hypothesis.
- Rejected the earlier `480x480` controller plus centered `466x466` active
  window assumption. The board-local constants now model the vendor baseline:
  logical/active `466x466`, constructor gap `6,0,0,0`, and named MADCTL
  constants for the still-experimental hardware-rotation path.
- Updated the normal CO5300 constructor to match Waveshare's Arduino demos:
  `Arduino_CO5300(..., 466, 466, 6, 0, 0, 0)`.
- Normal Waveshare firmware now clamps unsupported display rotations to `0`.
  Rotation `1`/90-degree requests are also clamped to `0` unless the build sets
  `WAVESHARE_ENABLE_EXPERIMENTAL_90_ROTATION`, because the last verified 90
  degree path had a green-edge artifact.
- BLE map-setting writes and startup NVS loads apply the same Waveshare rotation
  clamp, so an iPhone setting or stale saved value cannot leave normal firmware
  using the known-bad 90-degree display path.
- Added `WAVESHARE_AMOLED_175_DISPLAY_TEST`, which now draws vendor-baseline
  black/white/red/green/blue fills plus a `466x466` border and corner markers at
  0 degrees before LVGL starts. The default diagnostic no longer enables the raw
  90-degree path.
- Preserved the full-screen LVGL PSRAM buffer/full render strategy.

Device validation on 2026-07-01 and 2026-07-02:

- Earlier pre-vendor diagnostic display-test build/upload to
  `/dev/cu.usbmodem2101` passed. That diagnostic exercised guessed offsets and
  raw 90-degree MADCTL rotation before we found the official 6-pixel gap.
- User-provided photos `/Users/chris/Downloads/IMG_8885.jpg` and
  `/Users/chris/Downloads/IMG_8886.jpg` show solid green and blue fill passes
  without an obvious thin green-edge band or stale-pixel strip. The square
  active area remains visibly clipped by the round lens/bezel, which is expected
  for a `466x466` active window under the circular cover.
- The same photos show the visible black margin is not symmetric: the green
  fill has the margin mostly on the left, while the blue/rotated state shows
  margins at the top and bottom. That suggests the current MADCTL-only rotation
  changes the coordinate scan direction without applying the matching
  per-rotation CASET/PASET active-window offsets.
- User-provided photos `/Users/chris/Downloads/IMG_8892.jpg`,
  `/Users/chris/Downloads/IMG_8893.jpg`, and
  `/Users/chris/Downloads/IMG_8894.jpg` show that the guessed-offset diagnostic
  remained slightly rotated/clipped in different positions. Combined with the
  vendor research, this confirms the guessed `0/7/14` offset test was the wrong
  direction.
- The square active area also appeared slightly rotated clockwise relative to
  the USB-C connector/case during the experimental diagnostic. Later regression
  checks showed the same slight clockwise skew on older project firmware and on
  Waveshare's official factory firmware, so this is treated as physical
  panel/lens/case alignment rather than a PR 13 firmware regression.
- After the vendor-baseline patch, `git diff --check` passed.
- After the vendor-baseline patch, normal firmware build passed:
  `PLATFORMIO_CORE_DIR=/tmp/esp32-bike-pio-core-313 /tmp/esp32-bike-pio-313/bin/pio run -e WAVESHARE_AMOLED_175`.
- After the vendor-baseline patch, display-test build passed:
  `PLATFORMIO_CORE_DIR=/tmp/esp32-bike-pio-core-313 /tmp/esp32-bike-pio-313/bin/pio run -e WAVESHARE_AMOLED_175_DISPLAY_TEST`.
- Normal vendor-baseline firmware upload to `/dev/cu.usbmodem2101` passed:
  `PLATFORMIO_CORE_DIR=/tmp/esp32-bike-pio-core-313 /tmp/esp32-bike-pio-313/bin/pio run -e WAVESHARE_AMOLED_175 -t upload --upload-port /dev/cu.usbmodem2101`.
- Serial reset capture confirmed the normal firmware logs
  `CO5300: logical=466x466 active=466x466 constructorGap=(6,0,0,0) rotation=0
  experimental90=0`.
- First post-upload serial reset capture hit one BLE startup reboot:
  `Stack canary watchpoint triggered (ipc0)` while ESP-IDF Bluetooth interrupt
  allocation was running. The decoded backtrace pointed into ESP-IDF/BT
  interrupt allocation (`btdm_intr_alloc`/`esp_intr_alloc`) and not display,
  LVGL, or the new constructor path. The automatic reboot then reached BLE
  advertising and heartbeat logs.
- A second 25-second reset capture did not reproduce the BLE reboot. It reached
  SD init, LVGL init, touch reset, BLE advertising, waiting screen, and repeated
  heartbeat logs with the vendor display geometry.
- Exact historical firmware checks:
  - PR 12 merge commit `d52cb85` was flashed from a detached temp worktree and
    still showed the slight clockwise skew.
  - PR 11 merge commit `3fb1f6a` was flashed from a detached temp worktree and
    still showed the slight clockwise skew. Device readback of the app partition
    matched the PR 11 firmware SHA-256 exactly:
    `393f093daaa3982231634c4d9cdd7ce6a91a4f3f3fe4680edb79019f64b55305`.
  - PR 10 merge commit `b853488` was flashed from a detached temp worktree and
    still showed the slight clockwise skew.
- Waveshare's official factory image
  `/tmp/waveshare-esp32-s3-touch-amoled-175/Firmware/ESP32-S3-Touch-AMOLED-1.75-FactoryOnly.bin`
  was flashed at `0x0` and verified by esptool. The factory UI also showed the
  same slight clockwise skew. This confirms the angular skew is not caused by
  PR 13, PR 12, PR 11, or PR 10.
- Reflashing PR 13 normal firmware after the factory image confirmed the vendor
  display geometry in serial logs:
  `CO5300: logical=466x466 active=466x466 constructorGap=(6,0,0,0) rotation=0
  experimental90=0`. A physical unplug/replug restored stable PMU/touch-expander
  detection after the factory-image test.
- PR 13 `WAVESHARE_AMOLED_175_DISPLAY_TEST` was flashed again on 2026-07-02.
  The user confirmed the red/green/blue color-rotation diagnostic no longer
  showed clipping. That is the final display-window validation: the vendor
  `466x466` geometry plus 6-pixel X gap removes the observed address-window
  clipping/wrap issue. The remaining slight angular skew is hardware alignment.
- Normal PR 13 firmware was restored after the display-test run on 2026-07-02.
  Upload completed with esptool hash verification. A reset serial capture
  reached AXP2101 power setup, CO5300 vendor-window init, SD mount, LVGL init,
  BLE advertising, TCA9554 touch reset, and waiting-screen heartbeats. The
  final capture showed the known recoverable Arduino I2C touch-read failure once
  after startup (`i2c[fail=1 recover=1 recovered=1 missing=0]`), with no reboot
  or display regression.
- PR 13 should keep 90-degree hardware rotation disabled and leave software
  rotation as a later, separate experiment if the product still needs a rotated
  UI.

Scope:

- Isolate CO5300 panel setup behind a small board-local wrapper.
- Use Waveshare's official Arduino/ESP-IDF display geometry as the baseline:
  466x466 with a 6-pixel X gap.
- Keep raw 90-degree MADCTL rotation behind an explicit experimental build flag.
- Defer software rotation as a follow-up if the product still needs portrait or
  landscape switching after the baseline is stable.
- Add a hardware test mode or simple helper that draws:
  - full black
  - full white
  - red/green/blue fills
  - 1 px border
  - corner markers
- Keep LVGL full-screen PSRAM buffer and full render mode unless measurement
  proves another mode is stable.

Out of scope:

- Replacing Arduino_GFX entirely.
- Changing map renderer behavior.
- Re-enabling unsupported 180/270 rotations unless verified.

Validation:

- 0-degree fill tests.
- 90-degree fill tests only in an explicit experimental build.
- LVGL full-screen invalidation.
- Map render in the normal supported orientation.
- Touch coordinate alignment in the normal supported orientation.
- No green strip or stale pixels after repeated redraws.

Acceptance criteria:

- Active display window is documented in code.
- 90-degree mode either has no green edge or is explicitly disabled until a
  verified fix exists.
- Touch transform matches final display rotation behavior.

## PR 14: PCF85063 RTC Integration

Goal: use the onboard RTC for real time before BLE/iOS time is available.

Implementation status:

- In progress on branch `pcf85063-rtc-integration`.
- Added a Waveshare-local PCF85063 helper that probes `0x51`, clears the stop
  bit if needed, rejects voltage-low/invalid timestamps, restores ESP32 system
  time from RTC on boot, and writes UTC time back to the RTC.
- Extended the existing GPS-position BLE packet with an optional trailing
  `UInt32` Unix timestamp. Firmware remains backward compatible with the older
  8-byte and 10-byte payloads.
- The iOS app now appends current phone Unix time to GPS-position writes. The
  firmware throttles RTC writes to the first valid phone timestamp and then at
  most once every 10 minutes.
- `SYS` heartbeat logs include RTC presence, validity, source, and Unix time.
- The shared Waveshare I2C helper now serializes transactions with a FreeRTOS
  mutex. This is required because RTC sync can run from the BLE callback while
  LVGL/touch is also polling the CST9217 on the same `Wire` bus.
- RTC sync now reads the PCF85063 back before reporting success, so a failed or
  corrupted I2C write cannot mark the RTC valid in firmware state.
- BLE advertising uses a persisted random static identity by default, with
  bonding disabled and local bonds cleared on boot because this protocol uses
  app-level authentication. This avoids stale iOS/CoreBluetooth pairing state
  tied to the ESP32 public address while keeping normal reconnects stable. A
  commented `BLE_DEV_RANDOM_IDENTITY` build flag remains as a deliberate
  dev-only escape hatch for repeated firmware reflashes.
- Local verification on 2026-07-02:
  - `pio run -e WAVESHARE_AMOLED_175` passed.
  - iOS simulator build for the `BikeComputer` scheme passed.
  - Flash to `/dev/cu.usbmodem2101` passed.
  - Boot logs showed `PCF85063: found`.
  - The RTC had its voltage-low flag set, so firmware rejected the stored value
    and heartbeats reported `rtc[present=1 valid=0 source=unknown unix=0]`.
  - Local Mac BLE injection could not be used because macOS denied Bluetooth
    access to the Python/Bleak process.
  - The iPhone dev app initially failed to reconnect with `Peer removed pairing
    information`; temporarily switching the firmware to a random BLE own-address
    path allowed the iPhone to connect, authenticate, send settings, and send
    GPS. The long-term code path now generates one random static BLE identity,
    persists it in NVS, and gates per-boot fresh identity behind
    `BLE_DEV_RANDOM_IDENTITY`.
  - The persisted random static identity path was flashed and tested. First
    boot created the identity and authenticated from iOS. A reset then logged
    `BLE: Using existing persisted random static identity`, restored RTC time
    before BLE, and authenticated from iOS again.
  - BLE GPS timestamp sync succeeded from the iPhone app:
    `PCF85063: synced RTC from BLE GPS timestamp`.
  - A first RTC write path logged success but failed warm-reset restore because
    the RTC still contained invalid year register `0x07`; this exposed the need
    for shared I2C serialization plus RTC readback verification.
  - After adding I2C serialization/readback, reset restore succeeded before BLE
    reconnect: `PCF85063: restored system time from RTC:
    2026-07-02T01:23:59Z`, and heartbeats reported
    `rtc[present=1 valid=1 source=rtc ...]`.
  - Full USB unplug/replug was tested after a successful BLE RTC sync. On the
    next boot AXP2101 reported `battery=absent`, PCF85063 reported
    `voltage-low flag set; RTC time invalid`, and firmware correctly rejected
    RTC restore. The iPhone then reconnected and resynced the RTC over BLE.

Scope:

- Add a small PCF85063 driver.
- Probe RTC at `0x51`.
- Read current RTC time on boot.
- Sync RTC from trusted time sources:
  - iOS app time over BLE
  - BLE-injected location timestamp if available
- Store time validity/source in logs.
- Use RTC time for:
  - boot timestamps
  - ride start/resume before BLE/iOS location arrives
  - GPX metadata when phone-provided time is unavailable

Out of scope:

- RTC alarm wake unless PMU/sleep behavior is already stable.
- Timezone UI changes.

Validation:

- Build the Waveshare firmware. Done on 2026-07-02.
- Flash to the connected board and confirm `PCF85063: found` appears at boot.
  Done on 2026-07-02.
- Confirm invalid RTC values are rejected safely by the voltage-low flag/range
  checks. Done on 2026-07-02 for a voltage-low RTC and an invalid 2007 RTC
  register set.
- Connect from iOS, send a route/location update, and confirm the log shows an
  RTC sync from the BLE GPS timestamp. Done on 2026-07-02.
- Reboot with the phone disconnected and confirm the ESP32 restores system time
  from RTC before BLE/iOS reconnects. Warm reset done on 2026-07-02; a
  phone-disconnected capture is still useful if we want a stricter proof.
- Boot after full USB power removal. Tested on 2026-07-02: current board does
  not retain RTC time because no battery/backup source is present.

Acceptance criteria:

- System can start with sane time before BLE/iOS.
- RTC sync does not disturb other I2C devices.
- Logs show RTC status and source.

## PR 15: QMI8658 IMU Integration

Goal: bring up the onboard IMU safely, then decide which product behaviors are
worth enabling.

Implementation status:

- In progress on branch `qmi8658-imu-integration`.
- Added a Waveshare-local QMI8658 helper that:
  - probes primary address `0x6B`, then fallback `0x6A`
  - validates `WHO_AM_I == 0x05`
  - records revision/address/configuration status
  - configures accelerometer to `8g @ 125 Hz`
  - configures gyroscope to `512 dps @ 112 Hz`
  - enables accel + gyro via `CTRL7`
  - reads accel and gyro registers through the shared I2C helper
- Added a 2 Hz background sample path from the main loop. This is diagnostic
  only and does not change map, heading, ride, sleep, or navigation behavior.
- Added derived diagnostic fields:
  - acceleration magnitude
  - rough gyro vibration magnitude
  - rough moving/no-moving flag
  - preliminary dominant-axis orientation label
- Added a compact `IMU:` heartbeat before the rate-limited `SYS` heartbeat:
  `present`, `configured`, latest-sample validity, address, sample count,
  failed reads, latest accel/gyro values, acceleration magnitude, vibration
  magnitude, orientation label, and moving flag.
- Added optional `WAVESHARE_IMU_DEBUG_LOG` build flag for direct QMI8658 sample
  logs and successful raw register diagnostics. Normal builds keep the sensor
  visible through the compact `IMU:` heartbeat and keep raw diagnostics for
  failure cases.
- Axis orientation was checked on the connected board. The coarse orientation
  labels match the physical device positions, and product behavior can use this
  mapping later if we add an IMU-dependent feature.
- Connected-device notes from PR 15 bring-up:
  - QMI8658 identifies at `0x6B` with `WHO_AM_I=0x05` and `REVISION=0x7C`
    after a soft reset.
  - The Waveshare Arduino SensorLib also expects `WHO_AM_I=0x05`; the earlier
    observed `0x26` was resolved by matching SensorLib's reset-before-ID order.
  - A 17-byte timestamp/temp/accel/gyro burst read at 10 Hz caused frequent I2C
    recovery, so PR 15 narrowed sampling to separate 6-byte accel and gyro reads
    at 2 Hz.
  - STOP-style block reads matched SensorLib source shape but caused repeated
    `i2cRead()` invalid-state failures in this firmware; the shared repeated
    start helper was safer on the connected board.
  - The final read path uses repeated-start register reads locally for the
    QMI8658. STOP-style reads and read/modify/write config preserved stale or
    garbage bytes after `CTRL1.ADDR_AI` was enabled.
  - Final connected-device capture showed `CTRL1=0x40`, `CTRL2=0x26`,
    `CTRL3=0x56`, `CTRL7=0x03`, `STATUS0=0x03`, no zero samples, no IMU read
    failures, and a static gravity vector around `956 mg`.
  - Orientation capture showed stable axis signs:
    - face-down: roughly `+X small`, `+Y small`, `-Z`
    - right-edge-up: roughly `+X`, `+Y small`, `-Z partial`
    - left-edge-up: roughly `-X`, `+Y small`, `-Z partial`
    - USB-up: roughly `+Y`
    - USB-down: roughly `-Y`
    - face-up: roughly `+Z`
  - During the 90-second orientation capture the IMU stayed at `valid=1`,
    `zero=0`, and `fail=0`.

Scope:

- Add QMI8658 probe for primary address `0x6B`, with `0x6A` as fallback.
- Implement basic readout:
  - accelerometer
  - gyroscope
  - chip ID/status if available
- Add sample-rate and range configuration.
- Add debug logging behind a flag or rate limit.
- Characterize board orientation and axis signs.
- Add optional derived signals:
  - device orientation
  - motion/no-motion
  - rough vibration level

Out of scope for first IMU PR:

- Course-up fusion with BLE/iOS location heading.
- Wake-on-motion.
- Ride auto-start/stop.

Follow-up candidates:

- Wake-on-motion after PMU/sleep is stable.
- BLE/iOS heading smoothing at low speed.
- Auto pause/resume based on sustained motion state.
- Crash/impact detection if sensor data is reliable.

Validation:

- Build the Waveshare firmware.
- Flash to the connected board and confirm `QMI8658: found`.
- Static board reports a stable gravity vector near `1000 mg` in the final
  connected-device capture.
- Rotating board changes expected axes and the coarse orientation labels match
  physical device positions.
- Touch still works while the low-rate sensor read loop is active.
- Long run should not increase I2C failures materially versus the PR14 baseline;
  17-byte burst reads failed this, while the reduced 2 Hz path is much safer.

Acceptance criteria:

- IMU is detected and configured reliably.
- IMU sampling is stable enough for diagnostics.
- Axis orientation is documented after connected-device testing.
- No user-facing navigation behavior depends on IMU until the signal is proven.

## PR 16: SD And Map I/O Tuning

Goal: improve storage startup and map load performance without destabilizing SD
mounting.

Scope:

- Remove or gate normal boot root-directory listing.
- Add timing around:
  - SD mount
  - map file open
  - map block read
  - vector parse
  - canvas draw
- Test SD SPI frequencies:
  - 4 MHz baseline
  - 8 MHz
  - 12 MHz
  - 16 MHz
- Keep HSPI isolation from the CO5300 QSPI display.
- Keep 32 GB SDHC at 4 MHz as the known-good baseline from PR #6/PR #7.
- Add map-block cache/read-ahead only after measurements show I/O is a real
  bottleneck.

Out of scope:

- Filesystem format migration.
- Large map pipeline changes.
- Display renderer rewrites.

Validation:

- Mount the known-good 32 GB SDHC card first, then test additional cards if
  available.
- Load known map tiles repeatedly.
- Pan map across tile boundaries.
- Long ride simulation with route overlay.
- Confirm no display corruption during SD reads.

Acceptance criteria:

- Boot logs are quieter.
- Chosen SPI frequency is documented with test result.
- Map I/O timing is visible enough to guide future optimization.

## Cross-Cutting Rules

- Do not touch `IceNav-v3/` unless a task explicitly targets the vendored
  reference.
- Preserve full-screen LVGL buffer plus full render mode until the CO5300
  artifact work proves a safer alternative.
- Never configure GPIO20 as touch reset; it is USB D+.
- Keep SD on the verified SPI pins and isolated from display QSPI.
- Keep all hardware-feature changes guarded by `WAVESHARE_AMOLED_175`.
- Do not add a UART GPS implementation for this no-GPS Waveshare model.
- Prefer named device helpers over raw `Wire` writes in application code.
- Add debug counters before making behavioral tuning decisions.

## Suggested Milestones

Milestone 1: stable board layer

- PR 8 board support cleanup.
- PR 10 PMU integration.
- PR 11 shared I2C resilience.

Milestone 2: input and display polish

- PR 12 touch hint/fallback optimization.
- PR 13 CO5300 window/rotation fix.

Milestone 3: onboard sensors

- PR 14 RTC integration.
- PR 15 IMU integration.

Milestone 4: performance tuning

- PR 16 SD and map I/O tuning.

## Hardware Test Checklist

Run this checklist for every PR that changes boot, PMU, I2C, display, touch, or
storage behavior:

- Build: `cd esp32 && pio run`.
- USB cold boot.
- Battery cold boot if battery is connected.
- Display powers on.
- Touch tap works.
- Touch drag works.
- SD card mounts.
- Map loads from SD or FFat fallback behaves as expected.
- BLE still advertises/connects.
- Suspend/wake still works if the PR touches power.
- Serial logs do not show repeated I2C invalid-state storms.

## PR Grouping Decision

Do not put all improvements in one PR.

Safe to combine:

- PR 8 with nonfunctional comments/build cleanup.

Keep separate:

- PMU integration and I2C resilience.
- Touch hint/fallback changes and display rotation changes.
- RTC and IMU support.
- Storage tuning and map renderer changes.

Reasoning:

- PMU and I2C bugs can look identical during hardware testing.
- Display and touch regressions need isolated visual/input validation.
- RTC and IMU are independent devices with separate failure modes.
- Storage performance tuning should be measurement-driven and easy to revert.
