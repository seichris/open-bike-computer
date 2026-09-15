# Waveshare ESP32-S3 ePaper 3.97

This is an experimental firmware port with its core path physically proven. The
canonical firmware target is `WAVESHARE_EPAPER_397`. The source supports the
800 × 480 SSD1677 panel in a 480 × 800 portrait presentation. One physical unit
has completed USB identification, flashing, boot, visible panel patterns,
ordinary UI, button navigation, authenticated BLE, SD map rendering and screen
cycling. Sensor, sleep, long-run, battery and production update measurements
still require qualification. Production release and factory publishing continue
to exclude this target.

## Hardware contract

The [reference collection](reference/boards/waveshare-epaper-397/README.md)
contains the schematic, panel/component PDFs, and vendor examples pinned to
`9b12d40731a80213b927ee8a421cae4082952819`. See its
[source manifest](reference/boards/waveshare-epaper-397/SOURCES.json) for hashes.
The authoritative upstream entry points are the
[board documentation](https://docs.waveshare.com/ESP32-S3-ePaper-3.97) and
[resources](https://docs.waveshare.com/ESP32-S3-ePaper-3.97/Resources-And-Documents).
Installers and flash tools are intentionally excluded.

| Function | GPIO / device | Implementation |
| --- | --- | --- |
| CPU/memory | ESP32-S3 N16R8; 16 MB flash, 8 MB OPI PSRAM | Locked shared S3 toolchain |
| E-paper SPI | CLK 11, MOSI 12, CS 10, DC 9 | SPI2, 4 MHz, internal DMA staging |
| Panel control | RESET 46, BUSY 3 (high while busy) | Dedicated display task; bounded waits |
| Shared I2C | SDA 41, SCL 42 | Serialized existing board bus |
| SDMMC | CLK 16, CMD 17, D0 15 | One-bit mode; AMOLED SPI migration disabled |
| Contacts | Up 4, center 5, down 6 | Independent active-low contacts, pull-ups |
| BOOT | 0 | Existing deliberate recovery gesture; no fake touch |
| PMIC | AXP2101 at 0x34, ID register 0x03 = 0x4A | Verified ALDO3-only 3.3 V panel supply setup |
| RTC | PCF85063 at 0x51 | Shared RTC path |
| QMI8658 / SHTC3 | 0x6B / 0x70 | Opt-in low-rate diagnostic profile; ordinary and production keep sampling off |
| Audio | MCLK 13, BCLK 14, LRCK 47, DOUT 48, DIN 21, PA 39 | Disabled pending qualification |
| USB | Native S3 USB | No use of GPIO19/20 for touch/reset |

The product screenshots name the PMIC “TG28”; the schematic, AXP identity read
and vendor firmware identify AXP2101. The schematic connects ALDO3 through the
panel-supply switch as `EPD_VCC_AXP`; Waveshare's firmware programs ALDO3 to
3.3 V and enables it before panel reset. The port performs that same bounded,
readback-verified operation while preserving every unrelated enable and voltage
bit. Charging, PWR events, shutdown and all other rails remain unchanged. An
absent or unrecognized chip cannot authorize any write. GPIO39 is both PA enable
in the schematic and an IMU interrupt in an example: no IMU interrupt or audio
driver is enabled. Touch and onboard GNSS are absent; navigation/GPS data come
from the existing authenticated BLE companion connection.

## Display and input

LVGL retains a full RGB565 composition buffer. Its flush callback copies and
thresholds into a packed one-bit buffer, then returns without waiting for the
panel. Three 48,000-byte slots separate pending, transmitting and last-visible
pixels. New submissions replace only the pending slot. The worker compares
against the last successful visible image, aligns partial windows to bytes,
and records completion only after observing BUSY assert and deassert.

The SSD1677 adapter follows Waveshare's full-refresh data-entry, window and RAM
counter sequence, including its descending full-frame Y window. Partial updates
retain that mode and use the vendor's byte-start X endpoint. Address orientation
and differential base retention still require the edge-pattern and
repeated-partial physical tests below. A failed operation retries once with full
initialization/base history, then latches a fault.
Controller waits are individually limited to 10 seconds; the worker yields
throughout. A permanently low BUSY signal also fails completion. BLE/UI code
never waits for that worker. A waveform already started cannot be cancelled;
its actual pixels remain the comparison base, but its old semantic generation
cannot authorize the new screen or pairing code.

Candidate scheduling defaults are one second between routine presentations,
250 ms minimum rest for priority changes, and a full cleaning after 20 successful
partial waveforms. The vendor documentation does not specify an elapsed-time
cleaning interval, so static content does not trigger a cleaning waveform. These
are **unqualified values**, not panel lifetime or visible-latency promises. The
panel controller enters deep sleep after 60 seconds without a waveform; changed
content reinitializes it with a full base frame while unchanged content remains
visible without waking it. Map pose/presentation runs at four-second cadence,
with explicit screen/route/settings requests allowed sooner. Maps use a white
background, hatched areas, black roads and a black route with a white halo.
Bird's-eye, 3D and continuous course-up camera settings are disabled.

| Gesture | Action |
| --- | --- |
| Up/down click | Previous/next enabled screen |
| Center click | Actions menu; select the focused action/control |
| Up/down in menu | Move focus (held keys may repeat) |
| Center hold | Open actions, or leave screen-control focus |
| Actions | Zoom in/out, recenter, screen controls, back |
| Pairing center click | Confirm only after that code's physical completion |
| Pairing up/down hold | Cancel the comparison |

Buttons are debounced for 40 ms. Ordinary builds poll with a maximum scheduler
wait of 20 ms. The opt-in light-sleep profile configures BOOT and all three
active-low contacts as wake sources and uses the regular scheduler deadline.
Pairing requires a fresh release/press after the current code becomes
visible. Presses held through refresh, cancelled generations and failed
waveforms cannot confirm. Existing BOOT ownership recovery remains separate.
The screen-control focus list dispatches semantic click events to actual LVGL
controls, including destination rows; it does not synthesize coordinates.
Scrolling labels wrap, screen transitions remain immediate, and the destination
calculation spinner is replaced by its static status text for this board.

The bottom status line distinguishes disconnected, unauthenticated and stale
GPS state. Abrupt power loss may retain any old image, including a comparison
code; the next boot must replace it. A display fault can also retain the old
image, so the authenticated `DSTS` display object and serial `EPAPER_FAULT`
records provide independent fault evidence.

## Profiles and qualification procedure

Build through `python3 esp32/tools/build_firmware.py <profile>` from the repo
root. Device identification and exact-image approval requirements in
`AGENTS.md` still apply to subsequent physical work.

| Profile | Purpose |
| --- | --- |
| `WAVESHARE_EPAPER_397` | Ordinary firmware, USB diagnostics, 6 MiB single-app layout |
| `WAVESHARE_EPAPER_397_DISPLAY_TEST` | Explicit panel diagnostic image; same layout |
| `WAVESHARE_EPAPER_397_POWER_METRICS` | Ordinary behavior plus e-paper waveform/sleep and system power telemetry |
| `WAVESHARE_EPAPER_397_IMU_DIAGNOSTICS` | Power metrics plus QMI8658 and SHTC3 identification and low-rate sampling |
| `WAVESHARE_EPAPER_397_LIGHT_SLEEP` | Power metrics plus opt-in tickless automatic light sleep and button wake sources |
| `WAVESHARE_EPAPER_397_PRODUCTION` | Compile/size qualification only, USB logging off, two 3 MiB OTA slots |

All profiles advertise the canonical target; profile identity remains in build
provenance. Power metrics, sensors and automatic light sleep are separate
qualification images and are excluded from production. Automatic disconnected
shutdown, brightness, audio, and PMIC writes beyond the ALDO3 panel supply remain
disabled. The ordinary image automatically sleeps only the SSD1677 controller
after a static minute. Changed content wakes it, invalidates differential history
and requires a full base frame.

In `DISPLAY_TEST`, boot presents a high-contrast checkerboard. Up/down clicks
select white, black, checkerboard, one-pixel edges, or the normal monochrome UI
(for text and QR inspection). Hold up to sleep; hold down to wake and re-present.
Hold center to inject a BUSY timeout; click center to clear injection and
reinitialize. Serial output identifies the pattern, BUSY timing and completed
generation. This profile never attests pairing and must not be used for
onboarding or rides. Use ordinary firmware for pairing/BLE qualification. Fault
injection is not compiled into ordinary or production profiles. A fault request
needs changed pixels or a due cleaning waveform; advance a pattern after
requesting it if the current image is unchanged.

The LVGL buffer and three packed frames total 912,000 raw bytes in PSRAM.
The proposed full map/foreground surfaces bring the estimated total to
4,730,496 bytes before fonts, map blocks, BLE, TLS, alignment and workspaces.
That is allocation arithmetic, not a measured high-water mark. Keep the shared
64 KiB internal/DMA reserve and measure largest free blocks under concurrent
map, display and transfer load before release.

CI's explicit `397` selector compiles all six e-paper profiles. Default automatic
CI and the existing `all` release selection remain
the AMOLED families. Release-candidate/history and factory-package allowlists
exclude e-paper; changing them requires a separate qualification change.
The companion and firmware still compare exact canonical update targets, and
historical short-SHA exceptions remain restricted to old AMOLED releases.

## Recorded physical evidence

The ordinary image from exact Git commit `820cd073` was flashed to the identified
Waveshare ESP32-S3-ePaper-3.97 with device serial/MAC `44:B1:76:B7:69:68`.
The display diagnostic showed dense black/white output, white and black states,
then the Bicino UI. The ordinary image showed Welcome, Waiting for iPhone, the
missing-map state without an SD card, and a rendered map after inserting the
card. Authenticated BLE updates and physical-button screen cycling were observed
working. This proves the core path for that exact image; it does not qualify the
new sensor/light-sleep profiles or production OTA behavior.

## Evidence required before publication

Host tests exercise raster rotation/polarity/stride, frame ownership/coalescing,
busy/failure policy, pairing generations, button debounce, CAP2 metadata and CI
selection. They establish source behavior only. Record each physical result
against the exact attested image, physical board/FPC revision and test setup:

- Cold boot, white/black/checker/text/QR/edge patterns, repeated partials, full
  cleaning, orientation and ghosting across the supported temperature range.
- Measured data-receipt-to-glass latency during GPS/ride traffic, SD rendering
  and authenticated map transfer; held-key/new-code/cancel/re-pair scenarios.
- Missing/removed/corrupt SD behavior without GPIO3 migration or formatting;
  every screen and destination control usable with gloves and no touch.
- Largest internal/DMA/PSRAM blocks under concurrent workload, watchdog/BLE
  liveness during stuck-BUSY recovery, reset mid-waveform and stale-state display.
- RTC retention/battery accuracy; qualify the opt-in IMU/SHTC3 profiles and
  separately qualify audio and rail/charging policies before enabling them.
- Panel sleep/wake and whole-device current; separately qualify disconnected
  shutdown and automatic light sleep before enabling either.
- Production slot fit, cross-target image rejection, interrupted OTA, rollback,
  boot acceptance, then stationary replay and a controlled ride.

No cycling, endurance, sensor, light-sleep-current, battery-only or production
OTA result is claimed by this record.
