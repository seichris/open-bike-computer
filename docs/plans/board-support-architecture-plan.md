# Board support architecture and migration plan

## Outcome and baseline

One firmware codebase supports several ESP32-S3 boards and board variants
without naming boards in shared code. Each board or variant stays its own
attested image with its own OTA target, partition layout, CI matrix and physical
gates. Adding a variant means adding data and per-board files, not editing
shared sources.

Prepared on 2026-10-30 from GitHub `main` at
`6e9ad040be4c28a74d79706723a0aac56115089b`, with the experimental e-paper
support in PR #442 (`feature/waveshare-epaper-397`, head `532a6678`) still
pending; #442 merged on 2026-11-07 (see Progress). Measurements below were
taken on that PR head because it was the first tree with three
display-bearing boards; `main` had two until #442 merged.

Boards in scope:

| Board | Status | Notes |
| --- | --- | --- |
| Waveshare ESP32-S3-Touch-AMOLED-1.75 | Production | Round 466×466 AMOLED, touch, AXP2101 read-only policy |
| Waveshare ESP32-S3-Touch-AMOLED-2.06 | Production | 410×502 AMOLED, touch, display-enable-only PMIC recovery |
| Waveshare ESP32-S3-ePaper-3.97 | Experimental (#442, merged 2026-11-07; excluded from release CI) | 480×800 e-paper, buttons, ALDO3-only PMIC writes |
| 1.75 with a GNSS module | Candidate | The 1.75 has unpopulated GPS pads; a fitted variant would be a new target |
| Other ESP32-S3 boards | Candidate | Different display, power chip, sensors or radios on the same SoC |
| IceNav-era boards (T-Deck, Elecrow, MakerFabs, N16R4, N16R8, IceNav) | To be removed (M0) | Not built by CI; images stamp `unverified-…`; removal decided 2026-10-30 |

This is a plan, not a contract change. Nothing here alters the BLE contract,
partition layouts, release gates or physical acceptance rules; it says where
future changes should land and in what order.

## Current state

This section describes the tree as it was on 2026-10-30, when the plan was
written. Progress, below, records what the milestones have changed since.

### What the code does today

Shared firmware code distinguishes boards with preprocessor conditionals on
board macros (`WAVESHARE_AMOLED_175`, `WAVESHARE_AMOLED_206`,
`WAVESHARE_EPAPER_397`, plus six legacy macros). Excluding e-paper-only and
panel files:

- On `main` at `6e9ad040`, 43 shared files contain 211 board-macro conditional
  lines: 163 mention the 2.06, 154 the 1.75 and 24 a legacy board. `main.cpp`
  alone has 62.
- On #442 at `532a6678`, 57 shared files contain 313: 209 mention the e-paper
  board, 168 the 2.06, 158 the 1.75 and 24 a legacy board. One more display
  family added about a hundred conditionals to shared code.
- The heaviest files on #442: `esp32/src/main.cpp` (76), `lib/gui/src/mainScr.cpp`
  (26), `lib/storage/storage.cpp` (24), `lib/ride_diagnostics/ride_diagnostics.cpp`
  (21), `lib/maps/src/maps.cpp` (20), `lib/waveshare_board/axp2101.cpp` (13),
  `lib/ble_navigation/ble_navigation.cpp` (13), `lib/waveshare_board/i2c_bus.cpp`
  (12), `include/hal.hpp` (11), `lib/settings/settings.cpp` (9).

Three patterns account for nearly all of it:

1. **Membership lists.** `#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206) || defined(WAVESHARE_EPAPER_397)`
   appears 31 times in `storage.cpp` alone. Every new variant edits every list,
   even when it differs from its base board in one part. This is what made the
   e-paper port touch 36 shared files whose 1.75 build then changed only in
   membership lists, include paths or unused helpers.
2. **Alternative code paths inline.** `main.cpp` interleaves two boot sequences
   (PMIC handling, display bring-up, input, sleep, maintenance mode) under
   conditionals. `mainScr.cpp` and `maps.cpp` hold both the AMOLED map scheduler
   (`map_render_policy`) and the e-paper one (`epaper_navigation_policy`) with
   the selection made per call site.
3. **Build-time selection by file.** `lib/panel/panelSelect.hpp` includes one
   panel header per board family and fails the build when no board is defined.
   This is the pattern that scales; it is used only for the panel.

Partial precedents already exist and should be extended rather than replaced:

- `esp32/include/board_traits.hpp` (#442): compile-time facts (`epaper`,
  `touch`, `brightness`, `qualifiedPowerControl`, dimensions, e-paper pins).
  Four files use it. It mixes capability flags with one board's pin table.
- `changed_components.FIRMWARE_TARGETS` and `ci_scopes.firmware_targets`: the
  per-board profile list is data, and board-named paths (`206`, `epaper`)
  select only their board.
- `esp32/partition_layouts.json`: versioned, validated layouts with migrations;
  a board's layout is a reference to an id.
- The CAP2 board-display TLV (#442): the app learns what a display can do from
  the device instead of recognising a model.
- The e-paper guard test (#442): every e-paper-named translation unit and
  include sits behind its board macro, enforced in CI.

### Legacy boards

`platformio.ini` still defines six environments inherited from IceNav
(`ICENAV_BOARD`, `TDECK_ESP32S3`, `ELECROW_ESP32`, `MAKERF_ESP32S3`,
`ESP32_N16R4`, `ESP32S3_N16R8`). CI never builds them, `build_firmware.py`
stamps them `unverified-…`, and their macros appear in `hal.hpp` and ten other
files. Their features (CLI, Wi-Fi CLI, web server, compass, gestures, LovyanGFX
sprites, hardware GPS) are compiled out of every Waveshare build through
`DISABLE_*` flags and `HAS_HARDWARE_GPS`, which only the legacy `common`
section defines. They are the clearest evidence that a board nobody builds
accumulates dead conditionals.

### Cost of a board today

Measured on this machine and in CI during the e-paper work: a cold firmware
build takes 8–18 minutes per profile in CI and about 14 GB of local disk per
environment; a verified core artifact is about 2 GB. A board family carries up
to five regular profiles. The structure below does not reduce that cost; only
the number of variants and the path-based routing do.

## Principles

These are decisions, with the reasons they were made.

1. **One codebase, one image per board variant.** Shared behaviour (BLE,
   navigation, maps, workouts, storage, updates) is most of the firmware and
   must not fork. Anything electrical (pins, power rails, display controller,
   partition layout, memory) is fixed at build time. The running image's
   identity (`BOOT_META target`, `custom_firmware_target`) is what OTA
   compatibility, factory packaging and the per-board hardware gates rely on; a
   board detected at runtime would give one image two tested behaviours and
   blur all of them. Optional parts on harmless buses may be probed at runtime
   only when a variant count makes separate images impractical, and never for
   power or display.
2. **Boards are data, parts have interfaces, features ask capabilities.** A
   board file states what is fitted and where. Each part (power chip, input,
   position source, sensors, SD wiring) has one small interface and one
   implementation per part, selected at build time from the board file. Shared
   features consult `board::` data or part interfaces, never board macros.
3. **Do not abstract the display stack.** The AMOLED and e-paper stacks differ
   in kind, not only in driver: partial-render LVGL with touch and dimming
   versus a frame mailbox with full and partial waveforms, cleaning cadence,
   sleep without RAM retention and button navigation. A common display
   interface would shrink to LVGL's flush callback, which already exists, or
   leak e-paper concepts into AMOLED code. The useful boundary is one layer up:
   shared decisions (what to show, when a base render is due, what a stat
   means) with one presentation stack per display family. The repository
   already does this where it went well: `rideTelemetryPresenter` and
   `ride_stats_widget` are shared, `epaperRideStats` is e-paper-only;
   `map_render_policy` and `epaper_navigation_policy` are family policies behind
   the same scheduler.
4. **Safety policy stays explicit per board.** Which PMIC registers an image may
   write (1.75 read-only, 2.06 display-enable-only, e-paper ALDO3-only) is
   policy, not pin data. It lives in the board's own policy file and in that
   board's `capture_boot.py` gate, never behind a generic power interface that
   could widen writes by default.
5. **Supported means built and gated.** A board is supported when CI builds its
   regular profiles on every relevant change and it has a documented physical
   gate. Unbuilt boards are removed or frozen; they do not keep conditionals
   alive in shared code.
6. **Capabilities cross the air as TLVs.** New board capabilities join CAP2 as
   their own TLV records, like the board-display TLV, not as feature bits. The
   app decides from capabilities and never from a model name.
7. **The architecture is a test, not a convention.** A ratchet test confines
   board macros to an allowlist of files and lets each file's count only fall.
   Without it the migration stalls halfway, as `board_traits.hpp` with four
   users and `hal.hpp` with six legacy boards show.

## Target structure

### Layer 1: board definitions

```
esp32/lib/board/
  board.hpp                 includes exactly one definition from the target macro; #error otherwise
  boards/
    waveshare_amoled_175.hpp
    waveshare_amoled_206.hpp
    waveshare_epaper_397.hpp
    waveshare_amoled_175_gnss.hpp   includes the 1.75 file and adds the GNSS part
  policy/
    waveshare_amoled_175.hpp        allowed PMIC writes, rail expectations
    …
esp32/lib/board_startup/            the startup part (M2), its own library so that
  board_startup.hpp                 lib/board stays a leaf of the dependency finder
  amoled.cpp                        the AMOLED family's bodies of the boot and loop steps
  epaper.cpp                        the e-paper family's
```

A definition is data only: nested namespaces of plain `constexpr` values and
no logic. M1 chose values over structs so that host tests and every C++17
translation unit can read a board file without shared type definitions. The
1.75 file, abbreviated:

```cpp
namespace board {
namespace identity { constexpr const char *target = "WAVESHARE_AMOLED_175"; }
namespace display {
constexpr uint16_t width = 466, height = 466;
constexpr bool round = true, touch = true, brightness = true;
constexpr uint8_t cs = 12, clk = 38, reset = 39, d0 = 4, d1 = 5, d2 = 6, d3 = 7;
}
namespace i2c { constexpr uint8_t sda = 15, scl = 14; }
namespace touch { constexpr uint8_t address = 0x5A, interrupt = 11; constexpr bool resetOnGpio = false; }
namespace sd { constexpr uint8_t clk = 2, cmd = 1, d0 = 3; }
namespace power { constexpr bool axp2101 = true, qualifiedPowerControl = true; }
namespace gnss { constexpr bool fitted = false; constexpr uint8_t tx = 43, rx = 44; }
}  // namespace board
```

An optional pin a board does not route is `board::noPin`. `include/hal.hpp`
keeps the old pin names (`TFT_QSPI_CLK`, `TCH_I2C_INT`, `WAVESHARE_SDMMC_CLK`
and the rest) as aliases of this data until their users read `board::`
directly. A board file may also define a few `BOARD_*` capability macros for
the places only the preprocessor can gate (PMIC write paths that must not
exist on a board without the capability, C configuration headers); each one
is `static_assert`ed equal to its `board::` value. The first is
`BOARD_PMIC_DISPLAY_ENABLE_RECOVERY`.

The AMOLED definitions take their values from `hardware/README.md`, which stays
the authoritative pinout. `board.hpp` replaces `board_traits.hpp` and absorbs
`panelSelect.hpp`'s role; the target macros keep their names, because
`custom_firmware_target`, `BOOT_META`, OTA compatibility and the release
tooling already depend on them. A target macro may appear only in
`platformio.ini`, `lib/board/`, a file whose single conditional gates all of
it, `panelSelect.hpp` until it is absorbed, CI routing and tests.

A variant file includes its base and overrides the parts that differ. The
variant is still its own target (`WAVESHARE_AMOLED_175_GNSS`), with its own
environments, `BOOT_META target`, partition layout reference and gate.

### Layer 2: parts

Each part has one header with a small interface and one implementation per
fitted device, chosen at build time from the board definition the way
`panelSelect.hpp` chooses the panel today.

| Part | Interface | Implementations | Today |
| --- | --- | --- | --- |
| Power | begin, status, rail state, allowed-writes policy from the board policy file | AXP2101; none | `waveshare_board/axp2101*.cpp` with per-board conditionals |
| Input | emits screen intents (next, previous, activate, context, cancel) | touch gestures; three buttons; boot button only | touch in `mainScr.cpp`, buttons in `board_input` (#442) |
| Position source | fixes with timestamp, speed, heading, quality, origin | phone over BLE; onboard GNSS (NeoGPS); fusion later | `gpsFromApp` path and `gps.cpp` under `HAS_HARDWARE_GPS` |
| SD storage | mount, unmount, card identity from board wiring | SDMMC one-bit; SPI shared | membership lists in `storage.cpp` |
| Sensors | present, sample, identity | QMI8658, SHTC3, RTC; none | `waveshare_board/*`, `WAVESHARE_*_DIAGNOSTICS` flags |
| Audio | present, play, mute | ES8311 speaker path; none | `speaker` library behind AMOLED conditionals |
| Startup | the body of each boot stage for this family | AMOLED; e-paper | `lib/board_startup/` behind `board::startup` (M2); `main.cpp` keeps the stage order |

The boot-stage list (the normal sequence `startup` through `ready`, ids 1–15,
plus the safe-mode, diagnostic-hold and firmware-maintenance states) is a
diagnostic contract read by `capture_boot.py` and the boot-failure counters.
The startup part implements the contents of each stage for its family; it does
not change the stage ids, names or order.

### Layer 3: presentation and features

Shared, display-independent:

- screen configuration and the screen registry;
- navigation data, route overlay geometry, workout telemetry and its presenter;
- map scene building and render results;
- the decision contract the main-screen scheduler uses: a frame was published,
  a render failed, a base render is requested, a frame should be presented.

Per display family, behind that contract:

- **AMOLED:** LVGL partial rendering, touch, dimming and display-off policy,
  `map_render_policy`, the CO5300 panel driver.
- **E-paper:** the frame mailbox, full and partial waveforms, cleaning and
  sleep policy, button navigation, `epaper_navigation_policy`, the SSD1677
  driver, and screens whose layout differs (`epaperRideStats`).

New UI for one family goes into that family's presentation files. New UI for
both goes into the shared layer and is drawn by each stack. A `#ifdef` on a
board macro inside `gui/` or `maps/` is the signal that something is in the
wrong layer.

Since M4 the contracts are `map_scheduler` (`lib/gui/src/mapSchedulerFamily.hpp`)
for the main screen's base-render decisions, `ride_stats_family`
(`lib/gui/src/rideStatsFamily.hpp`) for the Ride Stats slots, and the three
`Maps` members defined per family in `lib/maps/src/mapCamera{Amoled,Epaper}.cpp`;
a family file is named after its family and gated as a whole.

### Capabilities

- **Compile time:** shared code reads `board::display.touch`,
  `board::gnss.fitted`, `board::power.pmic` and similar constants. Dead
  branches compile out exactly as the macros do today.
- **Over BLE:** CAP2 keeps its feature bits for behaviour the app already
  negotiates. Board facts join as TLV records: the display TLV exists; a
  position-source TLV would tell the app that the board has its own GNSS so it
  can stop streaming position, and an input TLV would let the app phrase
  on-device instructions for buttons or touch. Each record is versioned on its
  own, so a new board adds a record instead of renumbering bits across firmware,
  iOS, the generator, the protocol document and the tests.

### Build, CI and qualification per variant

A variant is complete when all of these exist:

1. `lib/board/boards/<variant>.hpp`, its policy file and a `board.hpp` entry.
2. A `platformio.ini` base section with `custom_firmware_target`, the partition
   layout from `partition_layouts.json` and the profiles it needs (ordinary,
   remote-debug, production, lifecycle, POI lifecycle, diagnostics), inheriting
   everything else from its family.
3. A `changed_components.FIRMWARE_TARGETS` entry, a `ci_scopes` routing rule so
   paths named after the variant select only that variant, and coverage in
   `test_firmware_profile_coverage.py`.
4. A `capture_boot.py` identity gate and, where the board writes a PMIC, its own
   write-policy gate.
5. A `hardware/<board>.md` with pinout sources and physical evidence, and an
   entry in the qualification checklist.
6. A release decision: `tools/firmware_release_history.py TARGETS`, the
   `firmware-release.yml` target loops and the factory allowlists admit a target
   only after its physical gates pass.
7. App changes only if the variant adds a capability the app must react to, as a
   TLV.

The GNSS 1.75 as a worked example: a board file that includes the 1.75 file and
sets `gnss{fitted=true, module, transport, ...}`; environments
`WAVESHARE_AMOLED_175_GNSS*` extending the 1.75 base with the new target; the
position-source part compiled with both the phone and the GNSS implementation;
a position-source TLV; routing that `175_gnss` paths select only that target;
its own boot capture with the 1.75 read-only PMIC gate; and an entry in
`hardware/README.md` for the fitted module. No file under `src/`, `gui/`,
`maps/`, `storage/` or `ble_navigation/` changes.

## Migration

M0 and M1 ran from `main` before #442 merged, by the maintainer's decision on
2026-11-06. M3 followed on 2026-11-06 and merged on 2026-11-07. #442
reconciled its `board_traits.hpp` and e-paper traits against `lib/board/`
when it merged `main` through #767 the same day: `board.hpp` selects the
third target, `boards/waveshare_epaper_397.hpp` carries the e-paper data
(including the `epd`, `audio` and side-key values that
`include/board_traits.hpp` now aliases), the storage migration path is
skipped by data (`sd::legacySpiCs == noPin`), and the confinement baseline
was raised once for the e-paper branches in shared files, to 204
conditionals in 32 files. M2 and M4 were built on #442's branch and merged
after it on 2026-11-07 (#442 as `208ba571`, M2 as #770 `023e7fbd`, M4 as
#772 `b6d032c0`): the e-paper PR changed `main.cpp`, `mainScr.cpp` and
`maps.cpp` heavily, and migrating them on `main` first would only have
created conflicts.
Each milestone is a separate pull request with the REVIEW.md record, its own
host tests and, where it touches boot or power, a boot capture per affected
board. A milestone that preserves behaviour still needs that capture: boot
sequencing is where the PMIC policies live.

| # | Milestone | Scope | Done when | Hardware |
| --- | --- | --- | --- | --- |
| M0 | Prune legacy boards | Remove the six legacy environments, their `hal.hpp` blocks and the 24 conditionals in ten files; drop the now-dead `DISABLE_*` branches and legacy `lib_deps` that no Waveshare build uses | No legacy macro anywhere under `esp32/`; Waveshare images unchanged in behaviour | None (nothing built changes); confirm with the CI matrix |
| M1 | Confinement test and board selector | Add `lib/board/board.hpp` and move `board_traits.hpp` into it; add the ratchet test with a baseline of today's counts; register it in `checks.json` and CI routing | Test fails on any new board macro outside the allowlist or any count above baseline | None |
| M2 | Startup split | Move the family-specific bodies of `main.cpp`'s boot and loop steps into `lib/board_startup/{amoled,epaper}.cpp` behind `board::startup`; `main.cpp` keeps the stage order, and differences between the boards of one family become board data | `main.cpp` has zero board macros; `BOOT_STAGE` sequence identical | Boot capture per board with its PMIC gate: 1.75 read-only, 2.06 display-enable-only, e-paper ALDO3-only |
| M3 | Membership lists to board data | `storage.cpp`, `ride_diagnostics.cpp`, `axp2101.cpp`, `i2c_bus.cpp`, `settings.cpp`, `display_power.cpp`, `lv_conf.h`, `task_data_placement.hpp`, `ipc_stack_budget.hpp` read `board::` constants | Those files have zero board macros | SD mount and boot smoke per board |
| M4 | Presentation split | Move the e-paper branches of `mainScr.cpp`, `maps.cpp`, `rideTelemetryScr.cpp` into family presentation modules behind the scheduler contract | Zero board macros under `gui/` and `maps/`; both policy host tests pass unchanged | Navigation and workout smoke per board |
| M5 | Position source | Put `gps.cpp` behind the position-source interface as the GNSS implementation; the phone path becomes the default implementation; retire `HAS_HARDWARE_GPS` and `AT6558D_GPS` | Navigation consumes one interface; AMOLED behaviour unchanged | None until a GNSS board exists |
| M6 | First variant through the checklist | Add one new variant (the GNSS 1.75 or another board) using only the per-variant steps above | The ratchet test's allowlist gains no entry; CI builds the variant automatically | The variant's own gates |

M0 and M1 shipped in one pull request, M2 and M4 as a stack on #442 (see
Progress). M2 was the largest and riskiest and merged within its three-pass
limit without a split. M5 has no user-visible effect on its own and waits
until a GNSS board is real; the fitted 1.75 on the maintainer's bench is
that board once it is tested (see Decisions).

### Progress

- **M0, done 2026-11-06** from `main` at `0f2d209d`. The six legacy
  environments, `[esp32_common]`, the legacy `hal.hpp` blocks and their
  conditionals are gone, together with the `DISABLE_*` and `USE_ARDUINO_GFX`
  flags and the feature branches no Waveshare build compiled: compass, BME and
  IMU sensors, the serial CLI, the web server, touch gestures, the IceNav SD
  firmware-upgrade screen and the EasyPreferences store. The device-settings
  screen lost its inert "Firmware Upgrade" button; everything else builds the
  same.
- **M1, done 2026-11-06** in the same pull request. `esp32/lib/board/board.hpp`
  selects `boards/waveshare_amoled_175.hpp` or `boards/waveshare_amoled_206.hpp`
  and rejects any other target set; `include/hal.hpp` keeps the old pin names
  as aliases of that data. The confinement test froze 189 conditionals in 29
  shared files; 11 more files are exempt as whole-file gates. `panelSelect.hpp` keeps
  its role until M3 and M4 move the panel choice. #442's `board_traits.hpp` is
  not on `main`; the e-paper branch adds `boards/waveshare_epaper_397.hpp` when
  it merges. Merged as #766 on 2026-11-06.
- **M3, done 2026-11-06, merged as #767 on 2026-11-07.** `storage.cpp`, `ride_diagnostics.cpp`,
  `axp2101.cpp`, `i2c_bus.cpp`/`.hpp`, `settings.cpp`, `display.hpp`,
  `touch.hpp`, `lv_conf.h`, `task_data_placement.hpp`,
  `ipc_stack_budget.hpp`, `battery.cpp`, `runtime_watchdog_diagnostics.cpp`
  and the whole-file gates of `lib/waveshare_board` hold no board macro. The
  always-true membership lists are gone with their legacy else branches,
  per-board constants read `board::display`, `board::i2c`, `board::power` and
  `board::layout`, and the 2.06 display-enable recovery follows
  `BOARD_PMIC_DISPLAY_ENABLE_RECOVERY`. Baseline: 109 conditionals in 17
  files. Two deliberate unifications in `i2c_bus.cpp`: the 2.06
  `configureBus` keeps the result of `Wire.begin` (a failed driver install
  no longer pretends the bus is up; `recoverAfterFailure` re-begins it on the
  next failed transaction, as the 2.06 always did, and records the result),
  and the 1.75 `probe()` goes through
  `withRetries` like the 2.06 (same steps, plus the recovered-transaction
  count). The 1.75 boot smoke passed on the merged head (`BOOT_META`, the I2C
  configured line, `BOOT_PMIC mode=read-only`, the same-boot `SDIO: summary
  ok=1 backend=sdmmc` and the ready stage); the 2.06 smoke is deferred on the
  maintainer's recorded acceptance and stays owed. Review pass 3 found that the
  pinned TwoWire keeps its mutex taken when a transaction runs on a bus whose
  driver install failed (`endTransmission()` returns before releasing it once
  `begin()` has freed the buffers), so the next `begin()` or `end()` waited
  forever; `ensureBusConfigured()` now reinstalls the driver before any
  transaction and skips it when that fails, on both boards, with a
  fault-injection host test. For #442: the e-paper board
  file needs `board::i2c::stopBetweenWriteAndRead = false` and
  `recoverOnFailure = false` (its reads used a repeated start and never
  recovered), `board::power::displayEnableRecovery = false` with
  `BOARD_PMIC_DISPLAY_ENABLE_RECOVERY 0`, `board::display::defaultRotation =
  0` and `rotation90Enabled = false`, and the 1.75 `board::layout` values;
  `display.hpp` conflicts outright. The AMOLED-only guards that #442 keeps (`touch.hpp`'s whole-file
  gate, `speaker.cpp`, `sleep_audit`, `route_elevation_config.hpp`,
  `firmware_update_http.cpp`, `device_debug`, three `ble_navigation.cpp`
  sites) wait for the part interfaces of M4.
- **#442 reconciled with `main`, 2026-11-07.** The e-paper branch merged
  `main` through #767: `board.hpp` requires exactly one of the three targets,
  `boards/waveshare_epaper_397.hpp` carries the e-paper data (display, I2C
  with repeated-start reads and no recovery, SDMMC, side keys, SSD1677 and
  codec pins, the ALDO3-only PMIC policy, the 1.75 layout values and
  `sd::legacySpiCs = noPin`), `include/board_traits.hpp` aliases it, and the
  storage migration path is selected by that data instead of the target
  macro. The branch's confinement baseline rose once, to 204 conditionals in
  32 files, for its e-paper branches in shared files. Merged as `208ba571`
  on 2026-11-07 on the maintainer's recorded risk acceptance ("Merge, accept
  risk"): the second-panel and generation-2 layout checks on the 3.97 board
  stay owed, the e-paper profiles remain experimental and excluded from
  release CI, and the AMOLED builds of the merged head passed CI.
- **Include-path guard, #768, merged 2026-11-07.** Not a milestone, but it
  closes the failure class that bit M0 and the #442 merge:
  `esp32/tools/tests/test_ldf_include_paths.py` replays PlatformIO's
  dependency finder, so a header that includes another library's header by
  bare name fails in the host suite instead of in a cold build. It reproduces
  the `WiFi.h` loss M0's review found and the `storage.hpp` loss of the #442
  merge; framework and `lib_deps` libraries come from
  `ldf_external_libraries.json`, tied to the runtime lock.

- **M2, done 2026-11-07, merged as #770 (`023e7fbd`).** `main.cpp` holds no
  board macro; the baseline is 127 conditionals in 31 files. The always-true
  membership guards went with their legacy else branches, and the
  family-specific bodies of the boot and loop steps live in
  `lib/board_startup/` behind `board::startup`, each compiled for its family
  only: `amoled.cpp` owns the wake sources, the firmware maintenance mode,
  the speaker and PWR-key start and the PWR-key pairing input; `epaper.cpp`
  owns the side-key wake sources and reader, the panel and key polling, the
  20 ms wait cap and the asynchronous comparison gate. `main.cpp` keeps the
  stage order and enters and completes every stage, so the `BOOT_STAGE`
  sequence is unchanged. Differences between the two AMOLED boards became
  board data: `i2c::recoverAtBoot` (the 2.06 bit-bangs the bus before PMIC
  inspection), `touch::ext1WakeSource` and `touch::wakePolling` (the 1.75's
  RTC-capable TP_INT) and `wifi::prepareBeforeBle` (the 1.75's early
  transfer Wi-Fi preparation); the e-paper's disconnected-shutdown opt-out
  reads `power::qualifiedPowerControl`, the deferred-notice dimming reads
  `display::brightness`, and the 2.06 display-probe hold after PMIC
  inspection reads `power::displayEnableRecovery` (only the 2.06
  `_DISPLAY_TEST` profile defines the probe flag). Two e-paper guards that
  only skipped no-op stubs are gone: the speaker shutdown poll and the
  ride-automation shadow start run on every board. The startup part is its own library,
  `lib/board_startup/`, rather than `lib/board/startup/`, so that the data
  library stays a leaf of PlatformIO's dependency finder (see #768).
  Hardware gate: the 1.75 boot capture passed on the stack head `f8b31c83`
  (M4 stacked on this milestone) on 2026-11-07 at 14:21Z, board
  `waveshare-175-c`:
  attested build and upload-only, then `capture_boot.py
  --require-pmic-read-only --require-ready` exit 0 with `BOOT_META
  git=f8b31c83…`, `BOOT_PMIC mode=read-only railState=current-preserved`,
  the same-boot `SDIO: summary ok=1 backend=sdmmc` and the ready stage at
  11803 ms, zero blocked PMIC writes and zero diagnostic errors. The 2.06
  display-enable-only capture and the e-paper ALDO3-only capture were not
  run: merged on the maintainer's recorded risk acceptance, and both stay
  owed.

- **M4, done 2026-11-07, merged as #772 (`b6d032c0`).** `gui/` and `maps/`
  hold no board macro; the baseline is 61 conditionals in 22 files. Board facts
  became data: `display::round` sizes the map overscan floor, the POI clip
  radius and the social badge; `display::monochrome` (new) selects the
  e-paper's white background, black lines, hatched areas and marker backing;
  `display::animations` (new) gates the destination-picker spinner;
  `board::layout` carries the map toolbar and reserved-height geometry;
  `touch::multiTouch` (new) drives the 1.75's pinch zoom, zoom-out backdrop,
  contact count and multi-touch suppression; the pairing copy follows the
  routed centre key (`buttons::center`; the side keys are `noPin` on the
  AMOLED boards) through a `ConfirmInput` argument. The two presentation stacks sit behind
  two contracts: `map_scheduler` (`lib/gui/src/mapSchedulerFamily.hpp`;
  `mapSchedulerAmoled.cpp` wraps `map_render_policy::Scheduler`,
  `mapSchedulerEpaper.cpp` the e-paper policy with its heading filter,
  disposition ledger and frame provenance) and `ride_stats_family`
  (`lib/gui/src/rideStatsFamily.hpp`; the AMOLED widget set with fonts paired
  across columns versus the e-paper set with its sign column). In `lib/maps`
  the e-paper-only `Maps` members are family-neutral (`CameraState`,
  `FramePublication`, `captureCameraState`, `setCameraHeading`, the request
  provenance) and three members are defined per family in
  `mapCameraAmoled.cpp` / `mapCameraEpaper.cpp`: `serviceStableCamera`,
  `readyFrameCovered` and `captureRequestProvenance`. `mainScr.cpp` keeps
  the LVGL tick, the pipeline calls and the shared decision effects. Both
  policy host tests (`test_map_render_policy.cpp`,
  `test_epaper_navigation_policy.cpp`) are unchanged. Hardware gate: the
  1.75 smoke passed on `f8b31c83` after the M2 boot capture, in the
  maintainer's app-driven runs: screen cycling between guidance, map and
  Ride Stats, the SD map rendering, pinch zoom and the display modes with a
  clean device log (14:35–14:44Z), then Test Navigation route guidance and a
  short workout with Ride Stats (maintainer-reported, about 15:00Z). The
  2.06 smoke and the e-paper's base-render admission, Ride Stats cells and
  pairing copy on the 3.97 panel were not run: merged on the maintainer's
  recorded risk acceptance, and they stay owed.
- **Stack merged 2026-11-07.** `main` at `b6d032c0` carries #442
  (`208ba571`, 14:58Z), M2 (#770, `023e7fbd`, 15:21Z) and M4 (#772,
  `b6d032c0`, 15:42Z), each merged from a `main`-synced head with its own
  green CI Gate. The 1.75 gate for M2 and M4 ran once on the stack head
  `f8b31c83` and is recorded in the evidence comments of #770 and #772. The
  maintainer accepted the untested items in writing on each pull request
  ("Merge, accept risk"); the recovery for any of them is a revert of its
  merge commit. Still owed on hardware, in order: the 2.06 boot capture
  with the display-enable-only gate plus its SD-mount and navigation and
  workout smoke, which cover M2, M3 and M4 together; the e-paper panel
  checks (second panel, generation-2 layout, base-render admission, Ride
  Stats cells, pairing copy). `lib/panel/panelSelect.hpp` still selects the
  panel header by target macro and keeps its exemption in the confinement
  test; moving that choice into `lib/board/` is open and belongs to no
  milestone yet. M5 and M6 wait for the GNSS 1.75 session.
- **M5, 2026-11-08, merged as `0b51d611` (#775).** The position source is one part.
  `lib/position_source/` arbitrates between the phone's BLE positions and an
  onboard receiver (`position_source_policy.hpp`: a fitted receiver holds the
  shared position record for 3 s after each valid fix, the phone's positions
  apply otherwise and keep feeding ride automation throughout);
  `gnss_receiver.cpp` carries the NMEA reader behind the board file's
  `BOARD_GNSS_FITTED` with no-op stubs elsewhere, on the transport the board
  data names (a UART with a rate probe, or the receiver's I2C slave polled
  with Quectel's command/answer scheme, which is what Waveshare's "-G" 1.75
  wires) plus the expander-driven reset release; the board data gained
  `gnss::{module, transport, i2cCommandAddress, i2cDataAddress, uart, rx, tx,
  baud, resetViaExpander, resetExpanderPin}` and no longer claims the H2
  header's UART0 pads (GPIO43/44) as a receiver footprint, since the vendor
  schematic routes the LC76G footprint's optional UART links to GPIO18/17
  and its RESET to EXIO7. `HAS_HARDWARE_GPS`
  and `AT6558D_GPS` are gone with the IceNav GPS task and mutex, the baud and
  update-rate settings rows and the `GPS_TX`/`GPS_RX` globals; the TCA9554
  helpers moved out of the panel driver into `waveshare_board::tca9554`.
  CAP2 gained extended bit `5` with the position-source record (TLV type `5`,
  client version `35`), which the app parses and shows in its firmware
  section. Baseline: 59 conditionals in 22 files (two always-true guards left
  `ble_navigation.cpp`). AMOLED behaviour is unchanged by construction: no
  board declares a receiver yet, so the arbiter always accepts the phone.
  Hardware gate: none of its own; the first fitted receiver is M6's board,
  whose boot capture also covers this part. Merged on the maintainer's
  recorded risk acceptance after the plain 1.75 image built from M6 booted on
  the GNSS bench unit with the read-only PMIC and ready gates; the
  phone-navigation check on that image stays owed.
- **M6, 2026-11-08, in review (#776, against `main` since M5 merged).** The first variant through the
  checklist is the 1.75 with the Quectel LC76G populated,
  `WAVESHARE_AMOLED_175_GNSS`: `boards/waveshare_amoled_175_gnss.hpp` (the
  shared 1.75 data moved to `waveshare_amoled_175_common.hpp`, the plain and
  variant files add identity and `gnss`), three environments on the 1.75 SDK
  policy, `changed_components`/`ci_scopes` routing (the pair on shared
  changes, the three profiles for the variant's board file, manual selector
  `175_gnss`, never packaged, never in `all`), the device registry family
  with longest-match ownership, a `capture_boot.py --require-gnss` gate
  (`BOOT_GNSS probe=ok` with checksum-valid sentences), and the hardware
  pages. One checklist assumption did not hold: the AMOLED whole-file gates
  key on the board macros, so a variant that defined only its own macro lost
  the panel, touch and RTC. The rule is now that a variant defines its base
  board's macro and its own, `board.hpp` requires the base and selects the
  most specific file, and the ratchet gained no entry (the variant macro
  appears only in `lib/board`). No file under `src/`, `gui/`, `maps/` or
  `storage/` changed; `ble_navigation.cpp` gained the `DSTS` position-source
  report that the app's Developer Settings show. Hardware gate: owed on the bench
  unit (boot capture with the read-only PMIC and receiver gates, fix evidence,
  the plain 1.75 image on the same unit for M5). The first three bench
  captures ran the UART transport and passed identity, PMIC and ready while
  every candidate receiver line floated; Waveshare's hardware reference and
  LC76G example put the receiver on the I2C bus, so the part gained the I2C
  transport and the board data a `transport` field before the fourth capture.
  Capture 8 (`66acd3fb`, 2026-11-08 07:12Z) passed the receiver gate over
  I2C once the transport followed the vendor driver's transaction pattern
  (`$PQTMVER` first, 29 checksum-valid sentences, no other bus device
  disturbed). Captures 9 to 13 then settled the stream: the reader restarts
  the module when it starts (an overflowed slave refuses reads until
  restarted), drains the announced length in 1 KB chunks and sends a request
  again when its answer keeps being refused, after which every stall
  resolved within half a second and the stream kept up. The plain 1.75
  image from the same commit (`7c92f6c8`) boots on this unit with the
  read-only PMIC and ready gates (the M5 gate's boot half; the phone
  navigation check is the maintainer's). Fix evidence passed at a window on
  2026-11-08 09:10Z (capture 21, `8b79e947`): standard fixes with 13 to 14
  satellites, one per epoch, once the reader fed the parser through
  NeoGPS's `handle()` (only it stores a fix) and read each fix before the
  next sentence (the one-fix buffer loses it otherwise; a UART reader never
  met either). Still the maintainer's: the device following the receiver
  with the phone off, and the phone-navigation check on the plain image.

### The confinement test

`esp32/tools/tests/test_board_macro_confinement.py`, registered inside the
display power and redraw policy host check, which every `esp32/` change
selects:

- Scans `esp32/src`, `esp32/lib` and `esp32/include` for preprocessor
  conditionals naming a target macro; the targets are the
  `custom_firmware_target` values in `platformio.ini`, so a new board is
  covered as soon as it has an environment.
- Allows them without limit in `lib/board/**`, `lib/panel/panelSelect.hpp`
  (still exempt after M4; the panel header choice has not moved into
  `lib/board/`) and in any file whose single target conditional
  is a positive gate around all of its code with no else branch. That
  whole-file gate is how a translation unit stays
  out of the other boards' images, and it is what keeps #442's e-paper-named
  sources out of AMOLED builds.
- Holds `board_macro_baseline.json` mapping every other file to its exact
  count. A count above or below the baseline fails; `--update-baseline`
  records a lower count so it cannot grow back, and reaching zero removes the
  entry. The e-paper branches inside shared files that #442 added raised the
  baseline once, visibly, to 204 conditionals in 32 files when it merged; M2
  lowered it to 127 in 31 and M4 to 61 in 22, the count on `main` since
  `b6d032c0`.

## Costs and limits

- CI minutes and disk scale with the number of variants, not with the code
  structure. Path-based routing keeps a pull request's matrix tied to what it
  touched; the `Firmware core warm` workflow warms only the 1.75 family today
  and should warm each supported family, or pull-request builds of other
  families stay cold.
- Every variant needs its own hardware for its gates. A variant without a
  board on the bench cannot be supported, whatever the code allows.
- The shared presentation contract is the one new abstraction with design
  risk. Keep it to the few hooks the scheduler already uses, and let the two
  stacks stay different rather than forcing symmetry.

## Decisions

1. **Legacy boards: remove them.** Decided by the maintainer on 2026-10-30.
   M0 deletes the six environments, their `hal.hpp` blocks, the conditionals in
   the ten other files, the `DISABLE_*` branches no Waveshare build compiles and
   the `lib_deps` only they used (LovyanGFX, EasyPreferences, ESP32 Wifi CLI,
   AsyncTCP, ESPAsyncWebServer). It runs after #442 merges, as the first
   milestone, in one pull request with M1 where practical. Nothing is frozen or
   kept as reference; Git history holds the removed code. Done 2026-11-06 from
   `main` at `0f2d209d`, before #442 merged, on the maintainer's instruction.

2. **The GNSS 1.75 is a real target.** Decided 2026-11-08 with M6: a 1.75
   with the Quectel LC76G populated on the vendor footprint (Waveshare's "-G"
   model) is on the bench (USB serial enrolled as `waveshare-175-gnss`). The
   ESP32 reads the receiver over the shared I2C bus (0x50/0x54) and resets it
   through expander pin EXIO7; the schematic's UART links to GPIO18/17 are
   optional and unfitted, and the header's UART0 pads the plan assumed are
   not involved at all.
3. **A variant is always its own image**, including for an optional module:
   its own `custom_firmware_target`, OTA identity, environments, CI routing
   and gates. Confirmed with M6.
4. **Naming and macros.** Variant targets append the module to the base
   board (`WAVESHARE_AMOLED_175_GNSS`). A variant defines its base board's
   macro and its own: the base macro keeps every whole-file gate and arm of
   the board, the variant macro selects the variant's board file in
   `board.hpp` (which requires the base) and names the image. Board files
   live in `esp32/lib/board/boards/`; shared board data of a family goes in a
   `*_common.hpp` the base and variant files include.

Still open: none.

## Related documents

- [hardware/README.md](../../hardware/README.md): authoritative pinouts and
  bring-up rules per board.
- [hardware/waveshare-epaper-397.md](../../hardware/waveshare-epaper-397.md)
  (merged with #442): the e-paper implementation and qualification record.
- [docs/development-checks.md](../development-checks.md): CI selection and the
  per-board scope table.
- [docs/partition-layout-migration.md](../partition-layout-migration.md):
  layout generations and migration rules.
- [docs/firmware-factory-release.md](../firmware-factory-release.md): release
  and factory allowlists.
- [docs/ble-protocol.md](../ble-protocol.md): CAP2 and the board-display TLV.
- [REVIEW.md](../../REVIEW.md): the review record each milestone must carry.
