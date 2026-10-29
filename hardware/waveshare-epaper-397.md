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

The SSD1677 adapter retains Waveshare's waveforms but uses one address mapping
for full and partial writes: software row `y` maps to RAM row `479-y`, in
X-increasing/Y-decreasing mode. Every window reasserts that mode after reset,
uses inclusive X endpoints, and starts the counter at its first streamed row.
An independent RAM-address model checks asymmetric, off-center and edge windows
against full-frame writes.

A partial waveform writes two complete planes, not just the dirty window: the
new frame to RAM `0x24` and the frame on the glass to RAM `0x26`. The dirty
window only decides whether a waveform runs. On 2026-10-30 the glass showed why
(E397-11). With window-only writes, rows outside later windows (the footer, the
arrow stem, the bottom of the distance) flipped between two older images on
every partial until the next full cleaning. That happens if the controller
swaps the two RAM roles after each differential update. A host glass model
reproduces the flip for that history and checks the complete-plane writes
against swap, copy and keep histories. The extra transfer is about 96 KB per
partial, roughly 0.2 s at the 4 MHz SPI clock. Physical orientation and
differential base retention still require the pattern and repeated-partial
tests below. These new addressing
changes are **not yet physically qualified**. A failed operation retries once with full
initialization/base history, then latches a fault.
Controller waits are individually limited to 10 seconds; the worker yields
throughout. A permanently low BUSY signal also fails completion. BLE/UI code
never waits for that worker. A waveform already started cannot be cancelled;
its actual pixels remain the comparison base, but its old semantic generation
cannot authorize the new screen or pairing code.

Candidate scheduling defaults are one second **start-to-start** between routine
presentations, with at least 250 ms rest after a partial waveform and one second
after a full waveform. Priority changes may bypass the routine interval but not
the rest floor. Slow panels extend the interval rather than losing their rest.
There is still a full cleaning after 20 successful
partial waveforms. The vendor documentation does not specify an elapsed-time
cleaning interval, so static content does not trigger a cleaning waveform. These
are **unqualified values**, not panel lifetime or visible-latency promises. The
panel controller enters deep sleep after 60 seconds without a waveform; the
panel datasheet states that deep sleep does not retain RAM, so changed content
reinitializes it with a full base frame while unchanged content remains visible
without waking it.

This cleaning cap is the remaining cause of the reported black/white flash.
Any screen whose content changes every second (a moving map, a ticking ride
clock, live speed) reaches 20 partial waveforms in roughly 20–25 seconds at the
one-second routine cadence, then performs one full cleaning (about 2.5–3 s at
23 °C). Waking after a minute without a waveform adds another full frame. Do not
raise the cap, disable cleaning or switch to the vendor's 1.5 s fast-full
waveform without the ghosting and temperature evidence in the
[qualification checklist](../docs/epaper-refresh-qualification.md). The
`EPAPER_FRAME` reason field attributes every flash.

While moving, navigation re-renders the base map when the rider drifts at least
6 px from the anchor (or after a 2 s deferral with any drift), no more often
than once per second, and redraws the rider foreground in between. Screen,
route-session, map-context and recovery requests may be served sooner. Maps use
a white background, hatched areas, black roads and a black route with a white
halo.

Bird's-eye, LoD1 3D walls and roofs, and continuous course-up camera settings
are disabled at every entry point (BLE settings, persisted profiles and screen
configuration). CAP2 keeps the reader bits for street labels (8), OSM
buildings/renderer target 3 (12) and topographic contours (30) because this
board installs and reads durable renderer targets 1–4 exactly as `mapReader`
reports; buildings are drawn as flat hatched footprints. It never advertises
bird's-eye bits 9–11, orientation bit 24, display-off bits 19/28, terrain
bit 31 or extended POI bit 3. Contour, terrain and POI visibility is removed
from every stored or written profile, because a one-bit threshold would turn
index contours into road-like strokes and drop minor contours. A companion
toggle alone therefore never establishes e-paper 3D, contour or POI support;
current iOS hides those controls for this board. A compile-time policy in
`device_capabilities_protocol.hpp` must classify every new CAP2 bit for this
board.

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

Workout stats have a board-specific 480 × 800 grid of 222 px cells. Each
widget's font and box are fixed by its widest supported display format (for
example 999.9 km/h, 9999.9 km, 99:59:59 and -9999 m), not by the live sample,
availability or a neighbour. Tabular values are right-aligned inside that box,
and the box, the reserved altitude sign column and the fixed heart-icon column
are centred under the centred title. The hero speed uses the dedicated speed
font and ride clocks use the 48 px tier. A value beyond its format still renders
when it fits the box and otherwise fails closed to `--`; the cell never resizes.
Missing sensors do not resize the cell. Distance and remaining distance stay in
kilometres with one decimal and a stationary unit caption. The AMOLED layouts
and their row-pairing behavior remain unchanged. Normal map recentering is
silent; coverage, connectivity, stale-GPS and actual recovery states remain
visible.

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
select white, black, checkerboard, one-pixel edges, the normal monochrome UI
(for text and QR inspection), an asymmetric ruler base, then left, center and
right square updates. The last four patterns share fixed landmarks so a shifted
partial window cannot hide in a symmetric image. Hold up to sleep; hold down to wake and re-present.
Hold center to inject a BUSY timeout; click center to clear injection and
reinitialize. Serial output identifies the pattern, BUSY timing and completed
generation. This profile never attests pairing and must not be used for
onboarding or rides. Use ordinary firmware for pairing/BLE qualification. Fault
injection is not compiled into ordinary or production profiles. A fault request
needs changed pixels or a due cleaning waveform; advance a pattern after
requesting it if the current image is unchanged.

`DISPLAY_TEST` and `POWER_METRICS` emit `EPAPER_FRAME schema=1` records with
`reason=startup|partial|cleaning|wake|recovery`, generation, submit/start/finish
timestamps, duration, changed-byte count, native dirty bounds (exclusive end),
and partials since full. Submit time is LVGL-to-mailbox submission, **not** phone
sample time or proof of when the glass became readable. The final attempt's
timing is recorded after recovery; `EPAPER_BUSY` provides diagnostic BUSY edges.
An unchanged full-cleaning frame has zero dirty bounds and changed bytes; the
actual waveform still covers the whole panel. Use the
[refresh qualification checklist](../docs/epaper-refresh-qualification.md).

The LVGL composition buffer and three packed frames total 912,000 raw bytes in
PSRAM, and LVGL's fixed 192 KiB TLSF pool also lives in PSRAM (the first build
aborted before `setup()` with it in internal RAM). The proposed full
map/foreground surfaces bring the estimated total to 4,730,496 bytes before the
LVGL pool, fonts, map blocks, BLE, TLS, alignment and workspaces. That is
allocation arithmetic, not a measured high-water mark. The board inherits the
shared Waveshare SDK contract, including the unqualified 96 KiB internal/DMA
reserve, the 1536-byte IPC stack and boot-initialized external BSS for task
workspaces. Measure largest free blocks under concurrent map, display and
transfer load before release.

Automatic PR and merge-group CI compiles the ordinary and production e-paper
profiles for any firmware, build or CI change that can reach this image, and all
six when e-paper-named sources change. The explicit `397` selector compiles all
six on demand. The `all` release selection remains the AMOLED families, and a
green automatic build is compile and size evidence, not physical qualification.
Release-candidate/history and factory-package allowlists
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
