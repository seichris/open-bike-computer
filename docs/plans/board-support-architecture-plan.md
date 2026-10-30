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
pending. Measurements below were taken on that PR head because it is the first
tree with three display-bearing boards; `main` today has two.

Boards in scope:

| Board | Status | Notes |
| --- | --- | --- |
| Waveshare ESP32-S3-Touch-AMOLED-1.75 | Production | Round 466×466 AMOLED, touch, AXP2101 read-only policy |
| Waveshare ESP32-S3-Touch-AMOLED-2.06 | Production | 410×502 AMOLED, touch, display-enable-only PMIC recovery |
| Waveshare ESP32-S3-ePaper-3.97 | Experimental (#442) | 480×800 e-paper, buttons, ALDO3-only PMIC writes |
| 1.75 with a GNSS module | Candidate | The 1.75 has unpopulated GPS pads; a fitted variant would be a new target |
| Other ESP32-S3 boards | Candidate | Different display, power chip, sensors or radios on the same SoC |
| IceNav-era boards (T-Deck, Elecrow, MakerFabs, N16R4, N16R8, IceNav) | To be removed (M0) | Not built by CI; images stamp `unverified-…`; removal decided 2026-10-30 |

This is a plan, not a contract change. Nothing here alters the BLE contract,
partition layouts, release gates or physical acceptance rules; it says where
future changes should land and in what order.

## Current state

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
  startup/
    amoled.cpp                      bring-up sequence for the AMOLED family
    epaper.cpp                      bring-up sequence for the e-paper family
```

A definition is data only: `constexpr` structs with no logic. Using the
e-paper values already verified in `board_traits.hpp` as the example:

```cpp
namespace board {
constexpr Identity identity{"WAVESHARE_EPAPER_397", Family::Epaper};
constexpr Display display{DisplayController::Ssd1677, 480, 800, /*round=*/false,
                          /*touch=*/false, /*brightness=*/false};
constexpr I2c i2c{/*sda=*/41, /*scl=*/42};
constexpr Sd sd{SdBus::Sdmmc1Bit, /*clk=*/16, /*cmd=*/17, /*d0=*/15};
constexpr Buttons buttons{/*up=*/4, /*center=*/5, /*down=*/6, /*boot=*/0};
constexpr Power power{Pmic::Axp2101};
constexpr Gnss gnss{/*fitted=*/false};
constexpr Memory memory{16 * MiB, 8 * MiB, PartitionLayout::current};
}  // namespace board
```

The AMOLED definitions take their values from `hardware/README.md`, which stays
the authoritative pinout. `board.hpp` replaces `board_traits.hpp` and absorbs
`panelSelect.hpp`'s role; the target macros keep their names, because
`custom_firmware_target`, `BOOT_META`, OTA compatibility and the release
tooling already depend on them. A target macro may appear only in
`platformio.ini`, `lib/board/board.hpp`, the board's own files, CI routing and
tests.

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
| Startup | the body of each boot stage for this family | AMOLED; e-paper | interleaved in `main.cpp` |

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
sets `gnss{fitted=true, uart, rx, tx, module}`; environments
`WAVESHARE_AMOLED_175_GNSS*` extending the 1.75 base with the new target; the
position-source part compiled with both the phone and the GNSS implementation;
a position-source TLV; routing that `175_gnss` paths select only that target;
its own boot capture with the 1.75 read-only PMIC gate; and an entry in
`hardware/README.md` for the fitted module. No file under `src/`, `gui/`,
`maps/`, `storage/` or `ble_navigation/` changes.

## Migration

Run these after #442 merges. The e-paper PR changes `main.cpp`, `mainScr.cpp`
and `maps.cpp` heavily, and migrating them first would only create conflicts.
Each milestone is a separate pull request with the REVIEW.md record, its own
host tests and, where it touches boot or power, a boot capture per affected
board. A milestone that preserves behaviour still needs that capture: boot
sequencing is where the PMIC policies live.

| # | Milestone | Scope | Done when | Hardware |
| --- | --- | --- | --- | --- |
| M0 | Prune legacy boards | Remove the six legacy environments, their `hal.hpp` blocks and the 24 conditionals in ten files; drop the now-dead `DISABLE_*` branches and legacy `lib_deps` that no Waveshare build uses | No legacy macro anywhere under `esp32/`; Waveshare images unchanged in behaviour | None (nothing built changes); confirm with the CI matrix |
| M1 | Confinement test and board selector | Add `lib/board/board.hpp` and move `board_traits.hpp` into it; add the ratchet test with a baseline of today's counts; register it in `checks.json` and CI routing | Test fails on any new board macro outside the allowlist or any count above baseline | None |
| M2 | Startup split | Move `main.cpp`'s boot sequencing into `lib/board/startup/{amoled,epaper}.cpp` behind `board::startup::stage(...)`; keep stage ids and names | `main.cpp` has zero board macros; `BOOT_STAGE` sequence identical | Boot capture per board with its PMIC gate: 1.75 read-only, 2.06 display-enable-only, e-paper ALDO3-only |
| M3 | Membership lists to board data | `storage.cpp`, `ride_diagnostics.cpp`, `axp2101.cpp`, `i2c_bus.cpp`, `settings.cpp`, `display_power.cpp`, `lv_conf.h`, `task_data_placement.hpp`, `ipc_stack_budget.hpp` read `board::` constants | Those files have zero board macros | SD mount and boot smoke per board |
| M4 | Presentation split | Move the e-paper branches of `mainScr.cpp`, `maps.cpp`, `rideTelemetryScr.cpp` into family presentation modules behind the scheduler contract | Zero board macros under `gui/` and `maps/`; both policy host tests pass unchanged | Navigation and workout smoke per board |
| M5 | Position source | Put `gps.cpp` behind the position-source interface as the GNSS implementation; the phone path becomes the default implementation; retire `HAS_HARDWARE_GPS` and `AT6558D_GPS` | Navigation consumes one interface; AMOLED behaviour unchanged | None until a GNSS board exists |
| M6 | First variant through the checklist | Add one new variant (the GNSS 1.75 or another board) using only the per-variant steps above | The ratchet test's allowlist gains no entry; CI builds the variant automatically | The variant's own gates |

M0 is decided (see Decisions) and starts once #442 has merged. M0 and M1 can
share one pull request. M2 is the largest and riskiest; split it
by family if the review grows past the three-pass limit. M5 has no user-visible
effect on its own and can wait until a GNSS board is real.

### The confinement test

`esp32/tools/tests/test_board_macro_confinement.py`, registered under an
existing esp32 host check so CI runs it:

- Scans `esp32/src`, `esp32/lib` and `esp32/include` for preprocessor lines
  naming a target macro.
- Allows them without limit in `platformio.ini`, `lib/board/**`,
  `lib/panel/panelSelect.hpp` (until M1 absorbs it) and test files.
- Holds a baseline file mapping every other file to its current count. A file
  above its baseline, or a new file with any count, fails the test. Lowering a
  baseline is the only permitted edit, and reaching zero removes the entry.
- Keeps #442's e-paper guard: e-paper-named translation units and includes stay
  behind their board macro, which is what lets e-paper-only changes skip AMOLED
  builds.

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
   kept as reference; Git history holds the removed code.

Still open:

2. Whether a GNSS 1.75 is a real target. The 1.75 pads are unpopulated, so it
   needs a fitted module and its own bench board before M5 and M6 are worth
   doing.
3. Confirm the rule that a variant is always its own image, including for an
   optional GNSS module.
4. Target naming for variants (`WAVESHARE_AMOLED_175_GNSS`) and the location of
   board files (`esp32/lib/board/`).

## Related documents

- [hardware/README.md](../../hardware/README.md): authoritative pinouts and
  bring-up rules per board.
- `hardware/waveshare-epaper-397.md` (lands with #442): the e-paper
  implementation and qualification record.
- [docs/development-checks.md](../development-checks.md): CI selection and the
  per-board scope table.
- [docs/partition-layout-migration.md](../partition-layout-migration.md):
  layout generations and migration rules.
- [docs/firmware-factory-release.md](../firmware-factory-release.md): release
  and factory allowlists.
- [docs/ble-protocol.md](../ble-protocol.md): CAP2 and the board-display TLV.
- [REVIEW.md](../../REVIEW.md): the review record each milestone must carry.
