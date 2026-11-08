# Waveshare ESP32-S3-Touch-AMOLED-1.75 with the GNSS receiver (`WAVESHARE_AMOLED_175_GNSS`)

Status: **experimental**. The variant is its own firmware target, image and
OTA identity; release, factory and core-warm flows exclude it until its
physical gates pass. Everything electrical that it shares with the plain 1.75
is in [README.md](README.md); this page records what the receiver adds.

This is Waveshare's "-G" model (`ESP32-S3-Touch-AMOLED-1.75-G`, SKU 31264):
the plain board with the Quectel LC76G populated on footprint Q1 and a
ceramic antenna. Vendor material (the product wiki, the board repository's
hardware reference and `09_LC76G_I2C` Arduino example, the LC76G protocol
specification and module manual, and the vendor I2C driver sources) is
collected with provenance in
[reference/boards/waveshare-amoled-175-gnss/](reference/boards/waveshare-amoled-175-gnss/README.md).

## Identity

- Board data: `esp32/lib/board/boards/waveshare_amoled_175_gnss.hpp`, which
  includes the shared `waveshare_amoled_175_common.hpp` and sets
  `board::gnss` (fitted, Quectel LC76G, transport I2C with command address
  0x50 and data address 0x54, RESET through expander pin EXIO7, and the
  optional unfitted UART link to GPIO18/17) and `BOARD_GNSS_FITTED 1`.
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
| SCL/SDA | shared I2C bus; the receiver's I2C slave answers at 0x50 (requests) and 0x54 (answers) |
| TXD1 | R15 (0R) to GPIO18, an optional link, unfitted on this model |
| RXD1 | R16 (0R) to GPIO17, an optional link, unfitted on this model |
| RESET (active low) | TCA9554 EXIO7 |
| VCC | VCC3V3 |
| V_BCKP | VCC-RTC through R33 |
| 1PPS, STANDBY, FORCE_ON | not connected |

No PMIC write is involved: the variant keeps the 1.75 read-only AXP2101 policy
and its `--require-pmic-read-only` gate.

## Firmware behaviour

- `lib/position_source/gnss_receiver.cpp` releases RESET through the expander
  (drives EXIO7 high; the module keeps running) and reads the receiver over
  the transport the board data names. On this variant that is the I2C
  transport: a reader task polls the receiver's I2C slave with Quectel's
  command/answer scheme as the vendor examples do (the slave's command
  address 0x50 is checked for an acknowledge, a request is written to it,
  and its answer is read from 0x54, retried every 10 ms for up to 200 ms
  because the slave refuses the read until the answer is ready; register
  0x0008 answers with the number of buffered bytes, register 0x2000 with
  that many bytes of the NMEA stream, read in chunks of up to 256 bytes so
  one read stays inside the bus timeout the touch controller shares),
  parses the stream with
  NeoGPS into the shared position record and counts raw bytes and
  checksum-valid sentences. Polls run every 200 ms while idle, back to back
  while the receiver still has buffered bytes, every 2 s while the receiver
  does not answer and every 30 s after five misses in a row. With no byte in
  15 s it pulses RESET through the expander (at most three times).
- The UART transport, for a receiver whose TXD reaches an ESP32 pin (no
  current board), opens a private UART and probes the board rate first, then
  115200, 9600, 38400, 57600 and 230400 bps, four seconds each, until a valid
  sentence locks it; after a complete round without a single byte it pulses
  RESET. Diagnostics profiles on that transport first print `BOOT_GNSS_LINES
  schema=1 pin18=<level>:<edges> pin17=... pin43=... pin44=...`, a passive
  look at the receive and transmit pins and at the H2 header's UART0 pads:
  `driven_high` or `driven_low` means something drives the line, `floating`
  means nothing is connected, and the edge count over 300 ms shows traffic.
- `position_source` lets a valid receiver fix populate the shared position for
  3 s after each fix; the phone's positions apply otherwise and keep feeding
  ride automation throughout. A fresh receiver fix counts as navigation input
  like a phone position.
- Serial evidence: `BOOT_GNSS schema=1 fitted=1 module=lc76g transport=i2c
  reset=expander i2c=0x50/0x54 present=0|1 polls=<n> errors=<n>
  backlog=<largest buffered length reported> answerMs=<longest wait for an
  answer> probe=pending|retry|ok
  bytes=<n> sentences=<n> invalid=<n> resetPulses=<n>`
  (the UART transport prints `transport=uart uart=2 rx=18 tx=17 baud=<rate>`
  in place of the I2C fields), printed when the receiver part starts, when
  the receiver starts or stops answering, after a RESET pulse and when the
  first checksum-valid sentences lock the probe (possibly after the ready
  stage); `GNSS: first bytes: <hex>` once 32 bytes arrived and `GNSS: fix
  sats=...` every 30 s in diagnostics profiles; `GNSS: reset pulse n` with
  its reason. Diagnostics events `gnss/probe`, `gnss/fix` and
  `gnss/fix_checkpoint` carry the sentence counts.
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
   reset and answering on the bus; it does not need a position fix.
2. Fix evidence: `GNSS: fix sats=N` on serial (or the `gnss/fix` event in a
   diagnostics export) with the board near a window or outdoors, and the
   device map following the receiver's position with the phone's position
   service off or the phone disconnected.
3. The phone path unchanged: the plain `WAVESHARE_AMOLED_175` image from the
   same commit boots and navigates on this unit with phone positions (the M5
   gate), and the variant image falls back to phone positions when the
   receiver has no fix.

## Physical evidence

Bench unit: USB serial `B8:1F:3F:CF:9C:D0`, enrolled as `waveshare-175-gnss`,
no SD card fitted. Logs and the ledger live in
`~/Library/Application Support/OpenBikeComputer/boot-captures/waveshare-175-gnss/`
on the maintainer's Mac.

| Date (UTC) | Image | Result |
|---|---|---|
| 2026-11-08 03:29 | `3c287530` ordinary (UART transport) | Attested upload. `BOOT_META target=WAVESHARE_AMOLED_175_GNSS profile=WAVESHARE_AMOLED_175_GNSS`, `BOOT_PMIC mode=read-only railState=current-preserved`, ready at 7113 ms, 0 blocked writes, 0 diagnostic errors, reset line released through the expander. Receiver gate failed: no sentence at 115200 or 9600 bps in 75 s. |
| 2026-11-08 ~03:50 | `231f9ac4` ordinary (UART transport) | Identity, PMIC and ready pass (ready 4671 ms). Receiver line silent: `bytes=0` at 115200, 9600, 38400, 57600 and 230400 bps over 100 s, three RESET pulses issued. |
| 2026-11-08 ~04:40 | `6c842f00` ordinary (UART transport) | `BOOT_GNSS_LINES pin18=floating:0 pin17=floating:0 pin43=floating:0 pin44=floating:0`: nothing drives the board's receive or transmit pin or the H2 header's UART0 pads. Identity, PMIC and ready pass (ready 5934 ms). |

Reading: captures 1 to 3 ran the UART transport. The variant image boots and
passes every gate except the receiver's, and every candidate receiver line
floats, which matches the schematic's "NC/0R" link resistors R15/R16 between
the receiver's UART and GPIO18/17. Waveshare's hardware reference and LC76G
example then showed that this model reads the receiver over I2C (0x50/0x54)
and leaves the UART links unfitted, so the part gained the I2C transport,
written against that example. Its capture follows.

## Open items

- 1PPS and STANDBY are unconnected; power saving of the receiver is not used.
- The IceNav satellite screens read the receiver's satellite table but are
  not wired into the configurable screens.
- No command is sent to the receiver (rate, constellations, PAIR/PQTM); it
  runs its defaults.
