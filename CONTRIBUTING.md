# Contributing

Open Source Bike Computer is an iOS-driven bike computer: the phone plans the
route, records workout metrics, and streams navigation, GPS, route geometry,
map settings, and ride telemetry to a small handlebar display over BLE.

## Repo layout

- `esp32/` - ESP32-S3 Waveshare firmware using PlatformIO, Arduino, LVGL,
  Arduino_GFX, NimBLE, SD map rendering, BLE navigation, and board helpers.
- `xiao-nrf52840/` - lower-power Seeed XIAO nRF52840 + Round Display firmware
  target using PlatformIO, Seeed_GFX, Bluefruit BLE, serial simulation, native
  protocol tests, and hardware-evidence checkers.
- `ios-app/` - iOS companion app using SwiftUI, MapKit, CoreBluetooth,
  CoreLocation, and HealthKit.
- `OSM_Extract/` - Dockerized OpenStreetMap extraction tools that generate
  vector map blocks (`.fmb` / `.fmp`) from PBF files. This is modified from
  [aresta/OSM_Extract](https://github.com/aresta/OSM_Extract).
- `docs/` - protocol and implementation notes. The current BLE source of truth
  is [docs/ble-protocol.md](docs/ble-protocol.md).
- `hardware/` and [hardware/README.md](hardware/README.md) - board bring-up
  notes, pinouts, local vendor manuals, power/enclosure records, and hardware
  validation evidence.

## Development flow

Prerequisites:

- PlatformIO CLI (`pio`) or VS Code with the PlatformIO extension.
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
pio run -e WAVESHARE_AMOLED_175
```

Build the Waveshare ESP32-S3 2.06 firmware:

```sh
cd esp32
pio run -e WAVESHARE_AMOLED_206
```

Upload ESP32 firmware:

```sh
cd esp32
pio run -e WAVESHARE_AMOLED_175 -t upload
```

If upload fails, hold BOOT (`GPIO0`) while reconnecting USB, then retry. For the
2.06 board, use `-e WAVESHARE_AMOLED_206`.

View ESP32 serial logs:

```sh
cd esp32
pio device monitor -b 115200
```

Build the XIAO nRF52840 Round Display firmware:

```sh
cd xiao-nrf52840
pio run -e xiao_nrf52840_round
```

Upload only after verifying the connected USB device is the XIAO nRF52840, not a
Waveshare ESP32-S3:

```sh
cd xiao-nrf52840
pio run -e xiao_nrf52840_round -t upload --upload-port /dev/cu.usbmodemXXXX
```

If upload fails, double-tap reset on the XIAO to enter the bootloader and retry
against the bootloader serial port.

Run the portable XIAO/native protocol tests:

```sh
cd xiao-nrf52840
pio test -e native_protocol
python3 -m unittest discover -s tools -p 'test_*.py'
```

Run the iOS navigation/BLE protocol tests from the repo root:

```sh
ios-app/scripts/run-navigation-tests.sh
```

Run the iOS app by opening:

```text
ios-app/BikeComputer/BikeComputer.xcodeproj
```

For physical iPhone setup, developer trust, and sharing notes, see
[ios-app/README.md](ios-app/README.md).

## Hardware notes

Supported display targets:

- [Waveshare ESP32-S3-Touch-AMOLED-1.75](https://www.waveshare.com/esp32-s3-touch-amoled-1.75.htm?sku=31262)
- [Waveshare ESP32-S3-Touch-AMOLED-2.06](https://www.waveshare.com/esp32-s3-touch-amoled-2.06.htm)
- [Seeed Studio XIAO nRF52840](https://www.seeedstudio.com/Seeed-XIAO-BLE-nRF52840-p-5201.html)
  + [1.28" Round Touch Display for XIAO](https://www.seeedstudio.com/1-28-Round-Touch-Display-for-Seeed-Studio-XIAO-ESP32.html),
  tracked in [PR #31](https://github.com/seichris/open-bike-computer/pull/31).

Definitive Waveshare pinouts and known quirks live in
[hardware/README.md](hardware/README.md). Important reminders:

- The 1.75 and 2.06 Waveshare boards both use CO5300 AMOLED displays, but they
  do not share the same display, touch, or SD pinout. Keep
  `WAVESHARE_AMOLED_175` and `WAVESHARE_AMOLED_206` changes separate.
- Waveshare 1.75 display power is controlled through AXP2101, touch reset is
  via TCA9554 P0, and SD uses `CS=41, MOSI=1, MISO=3, SCK=2`.
- Waveshare 2.06 uses direct FT3168 touch reset on `GPIO9`, display clock on
  `GPIO11`, display reset on `GPIO8`, and SD `CS=17`.
- The XIAO target is intentionally separate from `esp32/` because it uses a
  different MCU, BLE stack, display library, memory budget, and power model.

Hardware validation records live under `hardware/`. For XIAO work, use the
serial simulation and evidence-checker flow in
[xiao-nrf52840/README.md](xiao-nrf52840/README.md) before treating a hardware
run as validated.

## BLE protocol

The iOS app discovers the bike computer by the BikeComputer service UUID
`9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1800`. ESP32 firmware advertises as
`BikeComputer`; the XIAO target may advertise as `BikeComputer-XIAO` while using
the same service contract.

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

When iOS has an older cached GATT table, the app falls back to framed binary
writes over authenticated `2A6E` using `MAPR`, `GPSP`, and `MSET` frame
prefixes. Keep new device firmware compatible with both the direct
characteristics and the fallback framing path.

Before changing BLE formats, update the shared builders/parsers, iOS protocol
tests, ESP32 firmware, XIAO native tests, and [docs/ble-protocol.md](docs/ble-protocol.md)
in the same change.
