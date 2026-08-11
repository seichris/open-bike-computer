# Contributing

Open Source Bike Computer is an iOS-driven bike computer: the phone plans the
route and streams navigation, GPS, route geometry, map settings, and ride
telemetry to a small handlebar display over BLE.

## Repo layout

- `esp32/` - ESP32-S3 Waveshare firmware using PlatformIO, Arduino, LVGL,
  Arduino_GFX, NimBLE, SD map rendering, BLE navigation, and board helpers.
- `ios-app/` - iOS companion app using SwiftUI, MapKit, CoreBluetooth, and
  CoreLocation.
- `tools/OSM_Extract/` - Dockerized OpenStreetMap extraction tools that generate
  vector map blocks (`.fmb` / `.fmp`) from PBF files. This is modified from
  [aresta/OSM_Extract](https://github.com/aresta/OSM_Extract).
- `docs/` - protocol and implementation notes. The current BLE source of truth
  is [docs/ble-protocol.md](docs/ble-protocol.md).
- `hardware/` and [hardware/README.md](hardware/README.md) - board bring-up
  notes, pinouts, local vendor manuals, power/enclosure records, and hardware
  validation evidence.

## Development flow

Prerequisites:

- A system `python3` capable of running the tracked stdlib-only bootstrap. The
  build then re-executes under the repository-locked CPython 3.13 runtime; do
  not install PlatformIO, pip packages, or uv globally for firmware builds.
- Xcode for the iOS app.
- A USB-C data cable and the correct serial port for the connected board.

List connected ports on macOS:

```sh
pio device list
ls /dev/cu.usbmodem*
```

Build the default Waveshare ESP32-S3 1.75 firmware:

```sh
cd esp32
python3 tools/build_firmware.py WAVESHARE_AMOLED_175
```

Build the Waveshare ESP32-S3 2.06 firmware:

```sh
cd esp32
python3 tools/build_firmware.py WAVESHARE_AMOLED_206
```

Upload ESP32 firmware:

```sh
cd esp32
pio device list
python3 tools/build_firmware.py WAVESHARE_AMOLED_206 \
  --device-serial SERIAL_FROM_PIO_DEVICE_LIST
```

Retry an already verified build after a transient connection failure without
recompiling:

```sh
python3 tools/build_firmware.py WAVESHARE_AMOLED_206 \
  --upload-only \
  --device-serial SERIAL_FROM_PIO_DEVICE_LIST
```

Use this helper rather than a raw Waveshare `pio run`. It verifies the tracked
pioarduino platform and executable-package archive digests, keeps pioarduino's
recursive custom-core build on the generated local config, isolates and attests
PlatformIO-installed package/tool/nested-runtime and ESP-IDF component state,
and records PlatformIO's resolved flash plan during the preceding build. The
application offset is taken from the built, attested partition table because
pioarduino can clear its corresponding environment value after custom-core reuse;
any non-empty PlatformIO value must agree. Upload revalidates that plan, its exact
uploader, and every referenced image before replaying it directly without another
PlatformIO build. The final
attested command uses esptool's `keep` values for flash mode, frequency, and
size so esptool cannot rewrite a hashed bootloader image. The original resolved
values remain in the plan provenance. The
hardware-serial selector resolves the current OS port immediately before
esptool runs and waits 60 seconds by default. USB port numbers are transient and
must not be used to distinguish multiple attached boards. The upload subprocess
also suppresses Python bytecode writes inside the attested private environment,
keeping an unchanged build eligible for upload-only retry after a connection
failure. The verified build clock is the exact Git commit's committer timestamp.
It is exported as `SOURCE_DATE_EPOCH` to the full toolchain and embedded as
`BOOT_META built=`, so that field is source commit time rather than local
compile time. The manifest attests both the epoch and its ISO UTC rendering.
Public dependency fetches use an empty isolated Git configuration so ambient
URL rewrites cannot alter the transport. The
tracked runtime lock verifies the standalone Python archive, complete runtime
bundle, exact PlatformIO/uv executables, installed distribution closures, and
canonical file inventory before any bundled code executes. Shared user cache
entries are content-addressed and read-only; every worktree receives its own
private mutable PlatformIO store. Use `--repair-runtime` to remove and recreate
only the selected lock/target subtree after a validation failure. The residual
trust boundary is the operating system and the initial Python standard library
that runs the verifier, not mutable global Python packages. Command success is
not a flash
readback; confirm the embedded Git/profile with the later boot capture.

Custom-core reuse is also content addressed, but remains project-private. A
clean miss atomically publishes SDK sidecars and an inventoried
`core-artifacts.tar`; a hit verifies the archive and hydrates the environment's
private mutable store. Cache corruption quarantines only that exact core key.
Application compiler-cache paths include both the exact source and core
identities. Dirty builds may read a verified core entry but cannot publish one
or become upload eligible, and no core entry is shared across worktrees before
the relocatability gate is recorded.

If upload fails, hold BOOT (`GPIO0`) while reconnecting USB, then use the
upload-only command. For the 2.06 board, use the `WAVESHARE_AMOLED_206`
environment. Confirm the expected target/profile/Git identity from `BOOT_META`
before reporting a physical installation as complete. Pass the same stable
hardware identity to `tools/capture_boot.py --device-serial ...`; this prevents
boot verification from following a different board after USB re-enumeration.

Optional local nicknames map only to an explicitly enrolled board family and
stable USB serial. Real serials live outside Git:

```sh
python3 tools/device_registry.py add desk-175 WAVESHARE_AMOLED_175 SERIAL
python3 tools/device_registry.py list
python3 tools/build_firmware.py WAVESHARE_AMOLED_175 --device-name desk-175
```

A nickname does not select the only attached board, infer a model, or grant
flash approval. Confirm the connected physical model immediately before any
flash as usual.

Ordinary contributors consume accepted runtime locks only. Maintainers use the
manual **Firmware runtime refresh candidate** workflow as the first bootstrap
check, then must produce and review both-host offline replay, dependency graphs,
licenses, clean/warm builds, and tamper evidence before publishing immutable
assets and marking a target accepted. The checked-in lock now references
accepted Linux x86-64 and Apple Silicon bundles in the
`firmware-runtime-2026-08-10-1` prerelease. Unsupported hosts and any runtime
whose locked bytes have changed still stop before PlatformIO.

View ESP32 serial logs:

```sh
cd esp32
pio device monitor -b 115200
```

Run the iOS navigation/BLE protocol tests from the repo root:

```sh
ios-app/scripts/run-navigation-tests.sh
```

Run the iOS app by opening:

```text
ios-app/BikeComputer/BikeComputer.xcodeproj
```

## Hardware notes

Supported display targets:

- [Waveshare ESP32-S3-Touch-AMOLED-1.75](https://www.waveshare.com/esp32-s3-touch-amoled-1.75.htm?sku=31262)
- [Waveshare ESP32-S3-Touch-AMOLED-2.06](https://www.waveshare.com/esp32-s3-touch-amoled-2.06.htm)

Definitive Waveshare pinouts and known quirks live in
[hardware/README.md](hardware/README.md). Important reminders:

- The 1.75 and 2.06 Waveshare boards both use CO5300 AMOLED displays, but they
  do not share the same display, touch, or SD pinout. Keep
  `WAVESHARE_AMOLED_175` and `WAVESHARE_AMOLED_206` changes separate.
- Waveshare 1.75 display power is supplied through AXP2101, but firmware must
  preserve its current output-rail state; touch reset is via TCA9554 P0, and SD
  uses `CS=41, MOSI=1, MISO=3, SCK=2`.
- Waveshare 2.06 uses direct FT3168 touch reset on `GPIO9`, display clock on
  `GPIO11`, display reset on `GPIO8`, and SD `CS=17`.

Hardware validation records live under `hardware/`.

## BLE protocol

The iOS app discovers the bike computer by the BikeComputer service UUID
`9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1800`. ESP32 firmware advertises as
`BikeComputer`.

All navigation, GPS, route, and settings writes require the local authenticated
session described in [docs/ble-protocol.md](docs/ble-protocol.md).

Current characteristics:

| UUID | Direction | Purpose |
| --- | --- | --- |
| `2A6E` | iOS -> device | UTF-8 navigation instruction, `IconID|DistanceMeters|Instruction` |
| `9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1002` | bidirectional | Local auth handshake |
| `2A6F` | iOS -> device | Binary route geometry |
| `2A72` | iOS -> device | GPS position, heading, time, and optional ride telemetry |
| `2A73` | iOS -> device | Runtime map/display settings |
| `9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1003` | iOS -> device | Fixed 16-byte logical Watch workout telemetry frames |

When iOS has an older cached GATT table, the app falls back to framed binary
writes over authenticated `2A6E` using `MAPR`, `GPSP`, and `MSET` frame
prefixes. Keep new device firmware compatible with both the direct
characteristics and the fallback framing path.

Workout telemetry uses the `WTLM` prefix plus the same 16-byte native payload;
the resulting fallback plaintext is exactly 20 bytes. Ownership-v2 protection
expands it to a 42-byte wire write, while a native logical frame becomes a
38-byte wire write on protected channel `6`. The ownership handshake already
requires a sufficient ATT MTU. The app also prefers acknowledged `WTLM` when
`2A6E` supports write-with-response but the native workout characteristic only
supports write-without-response, keeping each correlated pair serialized.
Devices must keep capability bit `7` clear until
their authenticated parser, RAM-only state, and Ride Stats presentation are all
available. The Waveshare targets implement that complete path and advertise bit
`7`; new targets must meet the same gate before enabling it.

Before changing BLE formats, update the shared builders/parsers, iOS protocol
tests, ESP32 firmware, and [docs/ble-protocol.md](docs/ble-protocol.md) in the
same change.

## Licensing contributions

This is a multi-license repository. Contributions to the network backend and
its configuration are made available under AGPL-3.0-only. Contributions to the
iOS app and other distributed or local project software are made available
under GPL-3.0-only. Existing component-level and third-party notices continue
to take priority. See the [root README license section](README.md#license) for
the complete mapping.

Before an external contribution can be accepted, its contributor must read and
agree to the [Contributor License Agreement](CLA.md) using the acknowledgement
in the pull request template. The CLA:

- leaves copyright ownership with the contributor;
- grants the repository owner broad copyright and patent licenses, including
  the right to sublicense; and
- promises that accepted contributions remain available under the public
  license that applied to their component when submitted, even if the
  repository owner also offers them under separate App Store, commercial, or
  proprietary terms.

You must have the right to submit the contribution and must identify any
third-party material and preserve all applicable copyright, attribution, and
license notices. If an employer or another entity owns relevant rights, obtain
its authorization before submitting.
