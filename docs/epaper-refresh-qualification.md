# E-paper refresh and workout-stats qualification

Scope: PR #442, experimental `WAVESHARE_EPAPER_397` support. Automated checks
do not qualify glass orientation, waveform quality, longevity or ride safety.
The addressing, cadence, workout-layout, capability and merged-`main` changes
are pending physical acceptance. No board was connected while they were
implemented or merged (latest: 2026-10-29), so no image built from them has
been flashed.

## Before connecting a board

- Record the exact Git commit and clean state, selected profile, build/flash-plan
  hashes, board model, FPC/panel revision, stable USB serial and room temperature.
- Confirm the physical model before building. Use only `tools/build_firmware.py`.
  Restate those exact identities and obtain explicit approval immediately before
  flashing; record upload and independent running-image boot acceptance separately.
- Board display metadata is extended CAP2 bit 4 with its own TLV type 4 and
  minimum client version 34. Update the experimental iOS app and firmware
  together. Both earlier experimental allocations are incompatible and must not
  be aliased: bit 28/client 26 (display inactivity timeouts) and bit 31/client
  29 with TLV type 3 (terrain experiments and the extended feature word). An
  older experimental e-paper image sends an 8-byte TLV 3 that a current app
  rejects as a malformed extended feature word.
- Use the matching diagnostic image for panel tests and ordinary/power-metrics
  firmware plus the authenticated companion for navigation/workout tests.
  `DISPLAY_TEST` intentionally cannot attest pairing or be used for a ride.
- Do not open a serial port opportunistically during an SD activation/transfer.
  Arm the repository capture helper before an intentional reconnect/reset.

## Panel address and recovery tests

Record video including static landmarks; dense or centered patterns alone are
not sufficient. Use the profile's up/down clicks to select these patterns:

| Pattern | Expected result |
| --- | --- |
| 0–3: white, black, checker, edges | Correct polarity, full extent, no clipped rows/columns |
| 4: real UI | Legible text and scannable QR; correct portrait orientation |
| 5: asymmetric base | Single top-left mark, wide bottom-right mark, rulers and 1/2/3 bars |
| 6/7/8: left/center/right | Square appears under the corresponding bars; all fixed landmarks stay put |

Cycle 5→6→7→8→7→6→5 at least five times, including the count-driven full cleaning.
`DISPLAY_TEST` keeps a 20-partial cleaning for this; other profiles clean after 160.
Require no displaced/mirrored square, untouched-region movement or accumulating
ghosts. Repeat after explicit sleep/wake and a deliberate BUSY fault/recovery.
Test full-frame orientation too: the previous source used inconsistent full and
partial counters, so host equivalence alone cannot attest the physical axes.
If orientation is wrong, fix the shared raster/address contract, not one window.

In `DISPLAY_TEST`, hold up to sleep, hold down to wake, hold center to inject a
BUSY timeout, click center to clear it, and change the pattern to require a
waveform. Require bounded failure, responsive buttons/UI/BLE where applicable,
and a successful full base before subsequent partials. Recovery must not
authorize an obsolete pairing generation.

## Stationary workout and navigation replay

Keep the bike stationary. Run at least ten minutes of authenticated telemetry;
capture phone samples, `EPAPER_FRAME` records and video on one time reference.

- Speed 9.9→10.0→99.9→100.0: decimal/right anchor stays fixed; the hero keeps
  its dedicated speed font and stays centred under its caption.
- HR 99→100 and missing→present: numeric right edge and icon column stay fixed.
- Altitude 9→10, 99→100, -1→0→1: sign column and units remain stationary.
- Unchanged altitude beside 59:59→1:00:00 and 9:59:59→10:00:00: no font change.
- Ride clocks 59:59→1:00:00→9:59:59→10:00:00: same legible 48 px tier and right
  edge; nothing moves at the hour boundaries.
- Distance 999→1000 m and 9949→9950→10000 m: stable km caption, one decimal.
- Readability at arm's length on the handlebar mount, in daylight and shade:
  record which values are legible and whether any value shows `--`. An ordinary
  ride must never reach the fail-closed `--` path.
- Every configurable widget in hero and compact slots; smart-widget semantic
  changes, paused/ended sessions, missing sensors and reconnection.
- Simulated navigation with SD maps: map cadence, route changes, stale GPS,
  missing coverage, recentering and concurrent authenticated map transfer.
- Static page for over 60 seconds: no periodic cleaning; changed data after
  sleep gets a full wake frame. Verify static glass is not mistaken for live data.

`startMs - previous startMs` measures routine cadence; `startMs - previous
finishMs` measures panel rest (unsigned wrap-safe subtraction). Targets are at
least 1000 ms start spacing for routine partials, 250 ms rest after partials,
and 1000 ms rest after fulls. These are lower bounds, not a guaranteed frame rate.
`finishMs - submitMs` includes queueing/driver/waveform, not phone-to-glass latency.
Coalescing may intentionally skip superseded samples.

Full flashes remain intentional: startup, wake, bounded recovery, or cleaning
after 160 successful partials. Check the recorded reason for every flash. Do
not raise that limit further or remove full cleaning without repeated-panel
ghosting and temperature evidence. Count unchanged frames separately; no static timer should
force a cleaning refresh. Keep ghosting/contrast observations before and after
every cleaning and run longer endurance/temperature tests before production.

Partials must leave rows outside their changed area untouched. Before E397-11
was fixed, footer text, the maneuver arrow's stem and the lower part of the
distance flipped between two older images on every partial until the next
cleaning. A higher cleaning cap made that obvious. Ghosting observations taken
with a cap above 20 before that fix are confounded by it and need repeating.

Expected flash cadence: any screen whose content changes every second (moving
map, ticking ride clock, live speed) reaches 160 partials in about 3.5–4 minutes,
then cleans for about 2.5–3 s; a stop of a minute or more adds a wake frame. The
limit was 20 until 2026-10-30, which flashed every 20–25 s. With the E397-11
fix in place, the owner saw only very slight ghosting after 160 partials while
navigating, on one panel at room temperature, and chose 160. The owner then
judged ghosting acceptable at about 5 °C and about 40 °C on the same panel
(visual, 2026-10-30). Still open: a second panel, and recorded ghost ∆L (or
photographed residual contrast) for the moving-map and workout screens after
20, 40, 80 and 160 partials, before and after each cleaning. The vendor's 1.5 s fast-full waveform needs its own
tracked qualification profile and a reviewed policy change.

## Capability, map and navigation checks

Use the ordinary profile (or `POWER_METRICS` when timing records are needed)
with the coordinated client-34 companion.

- Capability handshake: the companion names the board "Waveshare ePaper 3.97"
  from CAP2 metadata, shows no brightness, tap-to-switch, display-off,
  disconnected-sleep, course-up, bird's-eye, 3D-buildings, terrain, POI or
  contour controls, and keeps the e-paper controls note.
- Durable map transfer and activation: download a durable production-signed
  `buildings-3d-v1` (target 3) map and, when a production-signed copy exists, a
  `topographic-contours-v1` (target 4) map. Both must pass the app's reader
  check, transfer, verify, activate and render after a reboot. Buildings appear
  as flat hatched footprints; no contour lines are drawn. Record the `DSTS`
  `activeRendererFormat`, `mapReader`, `streamTrust` and activation result.
  E-paper profiles compile in production signers only, so development-signed
  maps are expected to be refused as untrusted.
- Screen configuration: upload a Map + Navigation instance with bird's-eye,
  3D buildings, course-up, contours and POIs enabled. The board must keep a flat,
  north-up, contour-free map, and a download must return the stored document.
- Simulated navigation along a known route for at least 15 minutes: maneuver
  icon/text changes are urgent and readable, recentering stays silent, the rider
  marker and route redraw within the 1–2 s cadence, and every flash carries a
  `cleaning`, `wake` or `recovery` reason. Repeat with an SD map transfer running
  and confirm BLE, buttons and the display worker stay responsive.
- Missing card, removed card and a card inserted after boot: maps stay
  unavailable until restart (SD-only map storage), FFat diagnostics continue,
  and the status line explains the missing map.

## Automated evidence and acceptance record

`test_ssd1677_addressing.cpp` drives the actual adapter into an independent RAM
model for edge/off-center windows, repeated writes, resets retaining or clearing
registers, cleaning and sleep recovery. It also uses the physical diagnostic
images. `test_epaper_display.cpp` covers raster/mailbox provenance and cadence,
rest, count limits, faults, wake and clock wrap.

`epaper-workout-lvgl` compiles pinned LVGL 9.2.2, the real production rendering
helpers and real font assets at 480×800. It checks all widgets/slots, fixed label
bounds/fonts, decimal glyph positions, sign/icon columns, availability changes,
display-range endpoints, fail-closed wire maxima, hero/clock/distance font
tiers, centred groups and pixel-identical unchanged altitude beside time
rollovers. The ordinary AMOLED preview generator retains its 466×466 and
410×502 controls.

Append physical results only after testing: exact source/profile/board, measured
timings, videos, temperature and duration, each pass/failure, and unresolved
limitations. Production/release/factory allowlists remain unchanged. No new
physical, endurance, production-OTA or factory qualification is claimed here.
