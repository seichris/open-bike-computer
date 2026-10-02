# E-paper refresh and workout-stats qualification

Scope: PR #442, experimental `WAVESHARE_EPAPER_397` support. Automated checks
do not qualify glass orientation, waveform quality, longevity or ride safety.
The new addressing/cadence/layout changes are pending physical acceptance.
No board was connected during their implementation.

## Before connecting a board

- Record the exact Git commit and clean state, selected profile, build/flash-plan
  hashes, board model, FPC/panel revision, stable USB serial and room temperature.
- Confirm the physical model before building. Use only `tools/build_firmware.py`.
  Restate those exact identities and obtain explicit approval immediately before
  flashing; record upload and independent running-image boot acceptance separately.
- The merge preserves published CAP2 bits 28–30 and assigns experimental board
  metadata bit 31, minimum client version 29. Update the experimental iOS app and
  firmware together. The older experimental bit-28/client-26 pair is incompatible;
  do not alias that bit, which now belongs to the published inactivity setting.
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

- Speed 9.9→10.0→99.9→100.0: decimal/right anchor stays fixed.
- HR 99→100 and missing→present: numeric right edge and icon column stay fixed.
- Altitude 9→10, 99→100, -1→0→1: sign column and units remain stationary.
- Unchanged altitude beside 59:59→1:00:00 and 9:59:59→10:00:00: no font change.
- Distance 999→1000 m and 9949→9950→10000 m: stable km caption, one decimal.
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
after 20 successful partials. Check the recorded reason for every flash. Do not
raise that limit or remove full cleaning without repeated-panel ghosting and
temperature evidence. Count unchanged frames separately; no static timer should
force a cleaning refresh. Keep ghosting/contrast observations before and after
every cleaning and run longer endurance/temperature tests before production.

## Automated evidence and acceptance record

`test_ssd1677_addressing.cpp` drives the actual adapter into an independent RAM
model for edge/off-center windows, repeated writes, resets retaining or clearing
registers, cleaning and sleep recovery. It also uses the physical diagnostic
images. `test_epaper_display.cpp` covers raster/mailbox provenance and cadence,
rest, count limits, faults, wake and clock wrap.

`epaper-workout-lvgl` compiles pinned LVGL 9.2.2, the real production rendering
helpers and real font assets at 480×800. It checks all widgets/slots, fixed label
bounds/fonts, decimal glyph positions, sign/icon columns, availability changes,
wire-range endpoints and pixel-identical unchanged altitude beside time rollovers.
The ordinary AMOLED preview generator retains its 466×466 and 410×502 controls.

Append physical results only after testing: exact source/profile/board, measured
timings, videos, temperature and duration, each pass/failure, and unresolved
limitations. Production/release/factory allowlists remain unchanged. No new
physical, endurance, production-OTA or factory qualification is claimed here.
