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
  command/answer scheme as the vendor's Raspberry Pi driver does (every
  transaction waits 20 ms first and is retried while the slave refuses it,
  and a request whose answer read keeps being refused is sent again, since
  the slave refuses the read for seconds while busy with new output and an
  answer belongs to its request: a one-byte dummy write to the command
  address 0x50 checks the slave, a request is written to it, and its answer
  is read from 0x54; register
  0x0008 answers with the number of buffered bytes, register 0x2000 with
  that many bytes of the NMEA stream, drained in data requests of up to
  1024 bytes each until the announced length is read, with this variant's
  bus timeout and lock wait lengthened to 150 ms so one read fits them),
  parses the stream with
  NeoGPS into the shared position record and counts raw bytes and
  checksum-valid sentences. The reader first pulses RESET so the module
  starts fresh with it (a hot start with the RTC rail on V_BCKP): the
  module runs from power-on, and a slave whose buffer overflowed before the
  reader came up refused reads until restarted. Polls run every 200 ms
  while idle, again at once after a partial drain or after a poll the
  receiver refused having answered the one before (it stalls for a few
  seconds now and then), every 2 s while the receiver keeps refusing and
  every 30 s after five misses in a row. With no byte in 15 s it pulses
  RESET again (at most three pulses in all).
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
  backlog=<largest buffered length reported> answerMs=<longest wait for a
  length answer/a data answer> nacks=<refusals of dummy writes/request
  writes/length reads/data reads> repeats=<requests sent again>
  probe=pending|retry|ok ... fixes=<parser intervals completed>
  sats=<used in the fix>/<in view> fixStatus=<NeoGPS status of the last
  interval: 0 none, 3 standard> decode=<sentences the parser completed>/<bytes
  it rejected> types=<RMC/GGA/GLL/GSA/GSV/VTG/ZDA/other sentences seen>`;
  diagnostics profiles also print `GNSS: sample n: <1200 bytes of the
  stream as text, in three lines>` once after the probe locked.
  bytes=<n> sentences=<n> invalid=<n> resetPulses=<n>`
  (the UART transport prints `transport=uart uart=2 rx=18 tx=17 baud=<rate>`
  in place of the I2C fields), printed when the receiver part starts, when
  the receiver starts or stops answering, after a RESET pulse and when the
  first checksum-valid sentences lock the probe (possibly after the ready
  stage), and in diagnostics profiles again every 30 s once the probe
  locked, so a capture ends with the stream's totals; `GNSS: first bytes: <hex>` once 32 bytes arrived and `GNSS: fix
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
| 2026-11-08 06:08 | `c15ea28d` ordinary (I2C transport) | Attested upload. Capture 4 opened the port while the board's USB was still re-enumerating after esptool's reset and read nothing in 60 s (a stale handle, not a silent board); the board then switched itself off at its two-minute no-app window and capture 5 found no device. Lesson: capture after a power-on or with `--reset` on a settled port, not seconds after an upload. |
| 2026-11-08 06:47 | `c15ea28d` ordinary (I2C transport) | Capture 6 (`--reset`): identity, PMIC and ready pass (ready 4780 ms). The receiver acknowledges its command address 0x50 (`present=1`) and the request write, but refuses the answer read at 0x54 100 ms later on every poll (`i2c_master_receive failed: [259] ESP_ERR_INVALID_STATE`, the driver's code for a NACK); `polls=6 errors=6`, one RESET pulse. First proof that the module is powered and on the bus. |
| 2026-11-08 07:01 | `f6a3ff21` ordinary (I2C transport, answer-read retries) | Capture 7 (`--reset`, 6 s after the attested upload): identity, PMIC and ready pass (ready 4788 ms). The slave acknowledges the address-only probe but refuses the request write that follows it within a millisecond (`i2c_master_transmit failed: [259] ESP_ERR_INVALID_STATE`, the driver's code for a NACK), on every poll; one RESET pulse. The answer-read retries never ran. |
| 2026-11-08 07:12 | `66acd3fb` ordinary (I2C transport, vendor driver pattern) | **Receiver gate passed** (capture 8, `--reset` 6 s after the attested upload, exit 0): identity, PMIC and ready pass (ready 4868 ms); `BOOT_GNSS transport=i2c probe=ok bytes=1024 sentences=29 invalid=0 answerMs=10`, first bytes `$PQTMVER,1,MODULE,LC76GABNR12A05…` (the module's version report). Every write was acknowledged (`nacks=0/0/…`); reads were still refused for stretches beyond the 100 ms budget (10 refusals per failed poll, roughly every other poll), and the module reported 9202 bytes buffered at the first answered poll, so the 256-byte chunks could not drain it. |
| 2026-11-08 07:25 | `e1c67f72` ordinary (I2C transport, chunked drain) | **Receiver gate passed** (capture 9, exit 0, 90 s): identity, PMIC and ready pass (ready 4855 ms). For the first 15 s the slave refused every length read (`nacks=…/500/…`, five failed polls); the firmware's 15-s RESET pulse restarted the module and from then on every poll was served on the first try: `polls=82 errors=5 backlog=4215 answerMs=20/20 bytes=14436 sentences=383 invalid=0`, no other bus device disturbed, 150 ms bus timeout in effect. Reading: the module's buffer, filling since power-on, had overflowed before the reader started, and the overflowed slave refuses reads until restarted; the next image restarts the module when the reader starts. |
| 2026-11-08 07:34 | `7c92f6c8` ordinary (I2C transport, start reset) | **Receiver gate passed** (capture 10, exit 0, 90 s): identity, PMIC and ready pass (ready 4936 ms). The reader's RESET pulse at start put the module's buffer in step with it: first contact at the second poll with the 3507-byte startup burst, then `polls=87 errors=5 backlog=3507 answerMs=20/20 nacks=0/0/500/0 bytes=22255 sentences=603 invalid=0`, no other bus device disturbed. Every served poll answered on the first try; five polls hit a stall of more than 2 s (the step budget) about every 18 s and each then waited another 2 s as if the module were absent. |
| 2026-11-08 07:46 | `ee595811` ordinary (I2C transport, requests re-sent) | Captures 11 and 12: after the attested upload the boot stalled inside the storage stage (second legacy SPI mount attempt of the absent SD card, 2.5 s uptime), before the receiver starts in the user-interface stage, and the board went USB-dead while enumerated (a warm reset read nothing, the two-minute auto-off never fired). A board fault seen before on the plain 1.75, cleared by full power removal; not the receiver code. |
| 2026-11-08 07:51 | `ee595811` ordinary (I2C transport, requests re-sent) | **Receiver gate passed** (capture 13, after a full power removal, exit 0, 90 s): identity, PMIC and ready pass (ready 4946 ms). First contact at the second poll (3119-byte startup burst, 93 sentences, 19 repeats while the module came up). With requests re-sent, the refusal stalls shrank from 3.5 s to 0.14 to 0.54 s: sixteen bursts in 90 s, each resolved by one to three repeated requests; no other bus device disturbed. |
| 2026-11-08 07:56 | `7c92f6c8` plain `WAVESHARE_AMOLED_175` (gate 3, M5) | Attested upload of the plain image from the same commit onto this unit, then a warm-reset capture with the PMIC and ready gates (exit 0): `BOOT_META target=WAVESHARE_AMOLED_175 profile=WAVESHARE_AMOLED_175`, `BOOT_PMIC mode=read-only railState=current-preserved`, ready at 4898 ms, no receiver lines (none expected). The phone-position navigation check on this image is the maintainer's. |
| 2026-11-08 08:03 | `d754777f` ordinary (I2C transport, periodic record) | **Receiver gate passed** (capture 14, exit 0, 100 s): identity, PMIC and ready pass (ready 5013 ms). Totals: `polls=64 errors=4 backlog=3119 answerMs=160/40 nacks=0/0/410/0 repeats=78 bytes=15860 sentences=465 invalid=0`; the stream keeps up with the backlog never above the startup burst; four stalls outlasted the 20-round budget, the rest resolved by repeated requests; no fix indoors. |
| 2026-11-08 08:07, 08:12 | `d754777f` ordinary, at a window | Captures 15 (180 s) and 16 (300 s), both passing the gate with the strongest streams so far (`sentences=1925 invalid=0` and `sentences=4760 invalid=0 bytes=255720`), no `GNSS: fix` line in either. |
| 2026-11-08 08:23 | `aae0348f` ordinary (record with fix, satellite and status fields), at a window | Capture 17 (300 s, gate passed): `sentences=4822 invalid=0 bytes=266014` but `fixes=0 sats=0/0 fixStatus=0` for the whole window: the NMEA parser completes no interval and sees no satellite although every sentence passes the checksum validator. A parsing problem, not a sky problem; the next image counts the parser's outcomes and prints a raw sample of the stream. |
| 2026-11-08 08:39 | `d8077c56` ordinary (parser counters, raw sample), at a window | Capture 18 (120 s, gate passed): the raw sample is NMEA 4.10 (`$GNGGA`, `$GNGLL`, four `$GNGSA` with system IDs, `$GPGSV` with signal IDs) and the parser completes the sentences (`decode=1327/2929` against `sentences=1340`; the rejected bytes are line ends and the proprietary `$PQTM` sentences), yet `fixes=0`. |
| 2026-11-08 08:49 | `23628aa8` ordinary (sentence tally, epoch sample), at a window | Capture 19 (180 s, gate passed): epoch order GGA, GLL, GSA×4, GSV per constellation, RMC, VTG; `types=140/140/140/560/1240/140/0/15` in three minutes, 25 satellites in view with weak signals, `$GNRMC,...,V,...` (no fix), still `fixes=0`. The cause is the parser's API, not the stream: the reader fed NeoGPS through `decode()`, which parses but never stores a fix; only `handle()` does, which the old serial path reached through `available(port)`. |
| 2026-11-08 08:59 | `3665e7f0` ordinary (parser fed through `handle()`), at a window | Capture 20 (240 s, gate passed): `types=210/210/210/840/1788/210/0/17`, `decode=3468/7299`, and `fixes=1`: the parser now stores a fix at each RMC, but it buffers only one and the next completed sentence pops an unread one; VTG follows RMC within the same 1 KB chunk, so the fix survived only when a chunk boundary fell between the two. The reader now drains fixes after every completed sentence. |

Reading: captures 1 to 3 ran the UART transport. The variant image boots and
passes every gate except the receiver's, and every candidate receiver line
floats, which matches the schematic's "NC/0R" link resistors R15/R16 between
the receiver's UART and GPIO18/17. Waveshare's hardware reference and LC76G
example then showed that this model reads the receiver over I2C (0x50/0x54)
and leaves the UART links unfitted, so the part gained the I2C transport,
written against that example. Capture 6 then showed the slave alive on the
bus but refusing the answer read 100 ms after a request; the vendor's
Raspberry Pi driver retries that read every 10 ms up to 20 times; with
those retries the slave refused the request write right after an
acknowledged probe instead. The driver also waits 10 ms before every
transaction and starts with a one-byte dummy write rather than an
address-only probe, so the transport now follows it step for step and
counts refusals per step (`nacks=`). Capture 8 passed the receiver gate
with that pattern: the module speaks, its sentences verify, and what is
left is draining its buffer, which the next image does the vendor driver's
way (one length query, then data requests of up to 1024 bytes until the
announced length is read) with a longer retry budget and the longest waits
reported. Capture 9 then showed the refusals were the overflowed buffer:
after the module restarted, every poll was served at once and the stream
kept up, so the reader now restarts the module when it starts. Capture 10
confirmed that: the stream keeps up from the second poll on. What is
left are refusal bursts of 3.5 s (the whole read budget) every 8 to 18 s,
in which a hundred reads of one length answer were refused in a row; the
vendor driver sends the request again after twenty refused reads, so the
reader now does the same and rides a refused poll out as busy rather than
absent. Capture 13 confirmed it: every stall resolved within half a second
by a repeated request, and the stream kept up throughout. The plain 1.75
image from the same commit boots on this unit (gate 3's boot half).
Captures 14 to 20 then chased the missing fix to the reader itself: it fed
the parser through `decode()`, which never stores a fix (`handle()` does),
and then read the stored fix only after a whole chunk, while the parser's
one-fix buffer loses it to the next sentence; fixes are now drained after
every completed sentence.

## Open items

- 1PPS and STANDBY are unconnected; power saving of the receiver is not used.
- The IceNav satellite screens read the receiver's satellite table but are
  not wired into the configurable screens.
- No command is sent to the receiver (rate, constellations, PAIR/PQTM); it
  runs its defaults.
