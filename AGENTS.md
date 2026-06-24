# Agent Notes (esp32-bike-computer)

This repo contains:
- `esp32/`: ESP32-S3 firmware (PlatformIO + Arduino + LVGL + NimBLE).
- `ios-app/`: iOS companion app (SwiftUI + MapKit + CoreBluetooth + HealthKit).
- `OSM_Extract/`: offline vector-map build pipeline (Docker-based).
- `waveshare_test/`: hardware bring-up sketches for the Waveshare board.
- `IceNav-v3/`: vendored upstream reference project (treat as read-only unless explicitly asked to modify).

## Quick commands

### ESP32 (PlatformIO)

- Build: `cd esp32 && pio run`
- Flash: `cd esp32 && pio run -t upload`
- Serial monitor: `cd esp32 && pio device monitor -b 115200`
- List ports (macOS): `pio device list` or `ls /dev/cu.usbmodem*`

Bootloader mode: if upload fails, hold **BOOT (GPIO0)** while re-plugging USB.

### iOS

- Open: `ios-app/BikeComputer/BikeComputer.xcodeproj`
- Real-device testing / trust / sharing notes: `ios-app/README.md`

## BLE contract

Current firmware (`esp32/src/main.cpp`) implements:
- Service UUID `1819`
- Characteristic UUID `2A6E` (write without response)
- Payload (UTF-8): `IconID|DistanceMeters|Instruction`

The iOS app currently uses only that navigation characteristic. If you add/remove/rename BLE characteristics, update both:
- `esp32/src/main.cpp`
- `ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift`

## Hardware gotchas (Waveshare ESP32-S3-Touch-AMOLED-1.75)

Definitive pinout + quirks: `WAVESHARE_HARDWARE.md`

Highlights:
- Display power must be enabled via **AXP2101** (I2C `0x34`) or the screen stays black.
- Touch reset is via **TCA9554 P0** (I2C `0x20`) — do **not** toggle GPIO20 (USB D+).
- SD card is SPI on `CS=41, MOSI=1, MISO=3, SCK=2` (firmware uses HSPI to avoid the display QSPI bus).

## Offline maps (OSM_Extract)

Preferred workflow is Docker:
- `cd OSM_Extract && docker compose run --rm tools bash`
- Run scripts from `/scripts` in the container; outputs land in `OSM_Extract/maps/` on the host.

Config:
- feature selection: `OSM_Extract/conf/conf_extract.yaml`
- styling: `OSM_Extract/conf/conf_styles.yaml`

## Change hygiene

- Keep edits focused: avoid sweeping refactors/reformatting.
- Treat `IceNav-v3/` as a reference snapshot unless a task explicitly targets it.
- When touching LVGL/display code, preserve the “full screen buffer + full_refresh” strategy unless you have a measured reason to change it (it was chosen to avoid partial-update corruption on this AMOLED panel).
