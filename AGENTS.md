# Agent Notes (esp32-bike-computer)

This repo contains:
- `esp32/`: ESP32-S3 firmware (PlatformIO + Arduino + LVGL + NimBLE), currently based on the local IceNav-v3 map-renderer snapshot.
- `ios-app/`: iOS companion app (SwiftUI + MapKit + CoreBluetooth + HealthKit).
- `OSM_Extract/`: offline vector-map build pipeline (Docker-based).
- `waveshare_test/`: hardware bring-up sketches for the Waveshare board.

## Quick commands

### ESP32 (PlatformIO)

- Build: `cd esp32 && pio run`
- Flash: `cd esp32 && pio run -t upload`
- Serial monitor: `cd esp32 && pio device monitor -b 115200`
- List ports (macOS): `pio device list` or `ls /dev/cu.usbmodem*`

Bootloader mode: if upload fails, hold **BOOT (GPIO0)** while re-plugging USB.
For Python/pyserial captures on `/dev/cu.usbmodem*`, open at `115200` and set
`ser.dtr = False` plus `ser.rts = False` immediately after opening. Leaving
RTS/DTR asserted can reset or hold the ESP32-S3 USB serial path and produce an
empty monitor.

#### ESP32 on Chris's Mac over USB-C

Before the first device action in a thread (build/upload/serial capture/device
debugging), ask which physical device is currently connected. Do not assume
`WAVESHARE_AMOLED_175` vs `WAVESHARE_AMOLED_206`; flashing the wrong
environment can leave the screen black even when upload succeeds.

Observed working device/port:
- ESP32-S3 USB CDC/JTAG enumerated as `/dev/cu.usbmodem2101`.
- `pio device list` described it as `USB JTAG/serial debug unit` with VID:PID `303A:1001`.
- Working upload shape: `cd esp32 && pio run -e WAVESHARE_AMOLED_175 -t upload --upload-port /dev/cu.usbmodem2101`.

Local PlatformIO/Python gotcha seen on 2026-06-30:
- The global `pio` at `/Library/Frameworks/Python.framework/Versions/3.11/bin/pio` hung because that Python 3.11 install was unhealthy.
- The global `~/.platformio/penv` also pointed at that broken Python, which caused pioarduino dependency setup to hang.
- Prefer a healthy Python in the pioarduino-supported range, currently Python 3.10-3.13 for the cached platform.
- If only Python 3.14 is available, a temporary PlatformIO install plus temporary `PLATFORMIO_CORE_DIR` worked, reusing existing `~/.platformio` packages/platforms via symlinks. If the cached pioarduino platform rejects Python 3.14, temporarily widen `~/.platformio/platforms/espressif32/platform.py` from `< (3, 14)` to `< (3, 15)`, run build/upload, then restore that cached file.

Temporary setup pattern:
```sh
rm -rf /tmp/esp32-bike-pio-314 /tmp/esp32-bike-pio-core-314
/opt/homebrew/bin/python3.14 -m venv /tmp/esp32-bike-pio-314
/tmp/esp32-bike-pio-314/bin/python -m pip install --upgrade pip setuptools wheel platformio
mkdir -p /tmp/esp32-bike-pio-core-314
ln -s ~/.platformio/packages /tmp/esp32-bike-pio-core-314/packages
ln -s ~/.platformio/platforms /tmp/esp32-bike-pio-core-314/platforms
ln -s ~/.platformio/.cache /tmp/esp32-bike-pio-core-314/.cache
cd esp32
PLATFORMIO_CORE_DIR=/tmp/esp32-bike-pio-core-314 /tmp/esp32-bike-pio-314/bin/pio run -e WAVESHARE_AMOLED_175
PLATFORMIO_CORE_DIR=/tmp/esp32-bike-pio-core-314 /tmp/esp32-bike-pio-314/bin/pio run -e WAVESHARE_AMOLED_175 -t upload --upload-port /dev/cu.usbmodem2101
```

`pio device monitor` can fail inside non-interactive PTYs with
`termios.error: (19, 'Operation not supported by device')`. Use pyserial
instead. To capture from reset:
```sh
/tmp/esp32-bike-pio-314/bin/python - <<'PY'
import serial, time, sys
port = "/dev/cu.usbmodem2101"
ser = serial.Serial(port, 115200, timeout=0.05)
print(f"--- reset + serial capture {port} @ 115200 ---")
ser.dtr = False
ser.rts = True
time.sleep(0.25)
ser.rts = False
start = time.time()
while time.time() - start < 35:
    data = ser.read(8192)
    if data:
        sys.stdout.write(data.decode("utf-8", errors="replace"))
        sys.stdout.flush()
ser.close()
print("\n--- end serial capture ---")
PY
```

Healthy boot log checkpoints from the Waveshare board:
- AXP2101 found and display power enabled.
- TCA9554 found and touch reset completed.
- Display, LVGL, and UI initialized.
- BLE host started and server advertising.
- SD card initialized, or a clear SD init failure.
- `Setup complete!` followed by `Waiting for iPhone connection...`.

### iOS

- Open: `ios-app/BikeComputer/BikeComputer.xcodeproj`
- Real-device testing / trust / sharing notes: `ios-app/README.md`

## BLE contract

Current firmware implements BLE service UUID
`9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1800` in `esp32/lib/ble_navigation/`.
The full protocol is documented in `docs/ble-protocol.md`.

Core navigation characteristic:
- Characteristic UUID `2A6E` (write without response)
- Payload (UTF-8): `IconID|DistanceMeters|Instruction`

Map-view characteristics:
- Route geometry UUID `2A6F`
- GPS position UUID `2A72`
- Map settings UUID `2A73`
- Auth UUID `9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1002`

If you add/remove/rename BLE characteristics, update both:
- `esp32/lib/ble_navigation/ble_navigation.cpp`
- `esp32/lib/ble_navigation/ble_navigation.hpp`
- `ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift`

## Hardware gotchas (Waveshare ESP32-S3-Touch-AMOLED-1.75)

Definitive pinout + quirks: [hardware/README.md](hardware/README.md)

Highlights:
- Display power must be enabled via **AXP2101** (I2C `0x34`) or the screen stays black.
- Touch reset is via **TCA9554 P0** (I2C `0x20`) — do **not** toggle GPIO20 (USB D+).
- SD card is SPI on `CS=41, MOSI=1, MISO=3, SCK=2` (firmware uses HSPI to avoid the display QSPI bus).
- Touch input is interrupt-gated on CST9217 `INT=GPIO21`; do not return to rapid polling. Arduino Core 3.x `Wire.requestFrom()` failures against the CST9217 can crash the I2C ISR if reads are attempted while no touch data is ready.

## Offline maps (OSM_Extract)

Preferred workflow is Docker:
- `cd OSM_Extract && docker compose run --rm tools bash`
- Run scripts from `/scripts` in the container; outputs land in `OSM_Extract/maps/` on the host.

Config:
- feature selection: `OSM_Extract/conf/conf_extract.yaml`
- styling: `OSM_Extract/conf/conf_styles.yaml`

## Change hygiene

- Keep edits focused: avoid sweeping refactors/reformatting.
- Keep the restored IceNav-derived renderer architecture intact unless a task explicitly targets a refactor.
- When touching LVGL/display code, preserve the “full screen buffer + full_refresh” strategy unless you have a measured reason to change it (it was chosen to avoid partial-update corruption on this AMOLED panel).
