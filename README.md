# Open Source Bike Computer

Navigate your bike rides with a compact ESP32 display, for ~$30.

- **Device**: [Waveshare ESP32-S3-Touch-AMOLED-1.75](https://www.waveshare.com/esp32-s3-touch-amoled-1.75.htm?sku=31262)
- **iOS app**: Route planning + workout metrics; sends navigation + telemetry to the device over BLE.

We used [IceNav-v3](https://github.com/jgauchia/IceNav-v3) as a reference for this project. If you want a **self-contained** ESP32 GPS navigator with **offline OSM maps** (no phone required), IceNav-v3 is highly recommended.

## Repo layout

- `esp32/` — firmware (PlatformIO + Arduino + LVGL + NimBLE).
- `ios-app/` — iOS companion app (SwiftUI + MapKit + CoreBluetooth + HealthKit).
- `OSM_Extract/` — tools to generate vector map blocks (`.fmb` / `.fmp`) from OpenStreetMap PBF. Modified from [this repo](https://github.com/aresta/OSM_Extract).

## Development flow

### 1) Flash ESP32 firmware

Prereqs:
- PlatformIO CLI (`pio`) or VS Code + PlatformIO extension
- USB-C data cable

Build + upload:
```bash
cd esp32
pio run -t upload
```

If upload fails, force bootloader mode: **hold BOOT (GPIO0)** while re-plugging the USB cable, then retry.

### 2) Find the device port (macOS)

PlatformIO:
```bash
pio device list
```

Or directly:
```bash
ls /dev/cu.usbmodem*
```

### 3) View serial logs (macOS)

PlatformIO monitor:
```bash
cd esp32
pio device monitor -b 115200
```

Or with `screen`:
```bash
screen /dev/cu.usbmodem1101 115200
```

### 4) Run the iOS app

Open the Xcode project:
- `ios-app/BikeComputer/BikeComputer.xcodeproj`

For “run on a real iPhone / trust the developer / sharing to others”, see:
- `ios-app/README.md`

## BLE protocol (current)

- Peripheral name: `BikeComputer`
- Service UUID: `1819`
- Characteristic UUID: `2A6E` (write without response)
- Payload (UTF-8): `IconID|DistanceMeters|Instruction`
  - Example: `2|150|Turn Left onto Main St`
  - Icon IDs: `1` straight, `2` left, `3` right, `4` u-turn.

## Create a new offline map (OSM_Extract)

The recommended path is using the provided Docker toolchain (includes `osmium` + `ogr2ogr` + Python deps).

### 1) Download a PBF extract

Use BBBike Extract (PBF format): https://extract.bbbike.org/

Save the resulting file to:
- `OSM_Extract/pbf/<your-area>.osm.pbf`

### 2) Run the extractor in Docker

```bash
cd OSM_Extract
docker compose run --rm tools bash
```

(If you have an older Docker install, use `docker-compose` instead of `docker compose`.)

Inside the container:
```bash
cd /scripts

# Get the file's bounding box (copy values into the vars below)
osmium fileinfo -g header.box /pbf/<your-area>.osm.pbf

min_lon=...
min_lat=...
max_lon=...
max_lat=...

# Generates: /maps/<your-area>_lines.geojson + /maps/<your-area>_polygons.geojson
./pbf_to_geojson.sh "$min_lon" "$min_lat" "$max_lon" "$max_lat" "/pbf/<your-area>.osm.pbf" "/maps/<your-area>"

# Generates folder tree of vector blocks under /maps/<output-name>/
./extract_features.py "$min_lon" "$min_lat" "$max_lon" "$max_lat" "/maps/<your-area>" "/maps/<output-name>"
```

Outputs on the host machine:
- `OSM_Extract/maps/<output-name>/` (folder tree of `*.fmb` / `*.fmp`)

Config knobs:
- feature selection: `OSM_Extract/conf/conf_extract.yaml`
- styling: `OSM_Extract/conf/conf_styles.yaml`

### 3) Copy maps to SD card

For the upstream `IceNav-v3` project, these typically go under `VECTMAP/` on the SD card (excluding `test_imgs/`).

For the firmware in `esp32/` today, SD support is still basic (it lists files and reads test files), but the same folder structure will be used when the vector map renderer lands.

## Hardware notes

Definitive pinout + known quirks live in:
- `WAVESHARE_HARDWARE.md`
- Official board links:
  - https://www.waveshare.com/esp32-s3-touch-amoled-1.75.htm?sku=31262
  - https://www.waveshare.com/wiki/ESP32-S3-Touch-AMOLED-1.75

Highlights:
- display power must be enabled via **AXP2101** (I2C `0x34`)
- touch reset is via **TCA9554 P0** (I2C `0x20`) — **do not** toggle GPIO20 (USB D+)
- SD is SPI on `CS=41, MOSI=1, MISO=3, SCK=2` (uses HSPI in `esp32/src/main.cpp`)
