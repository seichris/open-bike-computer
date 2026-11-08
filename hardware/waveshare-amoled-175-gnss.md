# Waveshare ESP32-S3-Touch-AMOLED-1.75 with the GNSS receiver (`WAVESHARE_AMOLED_175_GNSS`)

Status: **experimental**. The variant is its own firmware target, image and
OTA identity; release, factory and core-warm flows exclude it until its
physical gates pass. Everything electrical that it shares with the plain 1.75
is in [README.md](README.md); this page records what the receiver adds.

## Identity

- Board data: `esp32/lib/board/boards/waveshare_amoled_175_gnss.hpp`, which
  includes the shared `waveshare_amoled_175_common.hpp` and sets
  `board::gnss` (fitted, Quectel LC76G, UART 2, ESP32 receive GPIO18, ESP32
  transmit GPIO17, 115200 bps, RESET through expander pin EXIO7) and
  `BOARD_GNSS_FITTED 1`.
- Build: the variant defines the 1.75 board macro `WAVESHARE_AMOLED_175`
  (every 1.75 whole-file gate and arm applies) plus its own
  `WAVESHARE_AMOLED_175_GNSS`, which selects its board file. Its
  `custom_firmware_target`, `BOOT_META target` and `board::identity::target`
  are `WAVESHARE_AMOLED_175_GNSS`. Profiles: ordinary, `_REMOTE_DEBUG` and
  `_PRODUCTION` (compile and size qualification only, never packaged).
- Bench board: enroll the unit with `tools/device_registry.py add
  waveshare-175-gnss WAVESHARE_AMOLED_175_GNSS <serial>`; `pio device list`
  cannot tell the variant from a plain 1.75, so identify it by the enrolled
  serial before flashing.

## Receiver wiring (vendor schematic, Q1 `LC76GABMD`)

| Signal | Route |
|---|---|
| TXD1 | R15 (0R) to GPIO18 |
| RXD1 | R16 (0R) to GPIO17 |
| RESET (active low) | TCA9554 EXIO7 |
| VCC | VCC3V3 |
| V_BCKP | VCC-RTC through R33 |
| 1PPS, STANDBY, FORCE_ON | not connected |
| SCL/SDA | shared I2C bus (reserved) |

No PMIC write is involved: the variant keeps the 1.75 read-only AXP2101 policy
and its `--require-pmic-read-only` gate.

## Firmware behaviour

- `lib/position_source/gnss_receiver.cpp` releases RESET through the expander
  (drives EXIO7 high; the module keeps running), opens a private UART at the
  board rate, parses NMEA with NeoGPS into the shared position record and
  counts checksum-valid sentences. The serial-rate probe tries the board rate
  first, then 115200 and 9600 bps, four seconds each, until a valid sentence
  locks it.
- `position_source` lets a valid receiver fix populate the shared position for
  3 s after each fix; the phone's positions apply otherwise and keep feeding
  ride automation throughout. A fresh receiver fix counts as navigation input
  like a phone position.
- Serial evidence: `BOOT_GNSS schema=1 fitted=1 module=lc76g uart=2 rx=18
  tx=17 reset=expander baud=<rate> probe=pending|retry|ok sentences=<n>
  invalid=<n>`, printed when the port opens, on each rate switch and when the
  probe locks (possibly after the ready stage); `GNSS: fix sats=...` every
  30 s in diagnostics profiles. Diagnostics events `gnss/probe`, `gnss/fix`
  and `gnss/fix_checkpoint` carry the same counts.
- CAP2 advertises the position-source record (extended bit 5, TLV type 5)
  with flags `3` and module `1`; the app shows "Position Source: Device GNSS
  (Quectel LC76G), iPhone when no fix" in its firmware section.

## Build and flash

```sh
cd esp32
python3 tools/build_firmware.py WAVESHARE_AMOLED_175_GNSS
python3 tools/build_firmware.py WAVESHARE_AMOLED_175_GNSS \
  --device-serial SERIAL_FROM_THE_REGISTRY
python3 tools/build_firmware.py WAVESHARE_AMOLED_175_GNSS_REMOTE_DEBUG \
  --device-serial SERIAL_FROM_THE_REGISTRY
```

## Physical gates

1. Boot capture with the 1.75 PMIC gate and the receiver gate:

   ```sh
   python3 tools/capture_boot.py --device-serial SERIAL --duration 45 \
     --expected-target WAVESHARE_AMOLED_175_GNSS \
     --expected-profile WAVESHARE_AMOLED_175_GNSS \
     --expected-git "$(git rev-parse HEAD)" \
     --require-pmic-read-only --require-ready --require-gnss
   ```

   `--require-gnss` needs `BOOT_GNSS probe=ok` with at least one
   checksum-valid sentence. It proves the module is fitted, powered, out of
   reset and wired at the probed rate; it does not need a position fix.
2. Fix evidence: `GNSS: fix sats=N` on serial (or the `gnss/fix` event in a
   diagnostics export) with the board near a window or outdoors, and the
   device map following the receiver's position with the phone's position
   service off or the phone disconnected.
3. The phone path unchanged: the plain `WAVESHARE_AMOLED_175` image from the
   same commit boots and navigates on this unit with phone positions (the M5
   gate), and the variant image falls back to phone positions when the
   receiver has no fix.

## Physical evidence

None yet. Record each run here with the exact Git SHA, image hash, board
serial, the capture log and the result, as `README.md` does for the plain
boards.

## Open items

- Confirm the receiver's factory serial rate on the bench (the probe handles
  115200 and 9600 bps).
- 1PPS and STANDBY are unconnected; power saving of the receiver is not used.
- The IceNav satellite screens read the receiver's satellite table but are
  not wired into the configurable screens.
