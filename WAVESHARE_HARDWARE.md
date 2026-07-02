# Waveshare ESP32-S3 Touch AMOLED 1.75" Hardware Reference

This document contains the definitive hardware pinout for the Waveshare ESP32-S3-Touch-AMOLED-1.75 board, extracted directly from the official schematic.

Official links:
- https://www.waveshare.com/esp32-s3-touch-amoled-1.75.htm?sku=31262
- https://www.waveshare.com/wiki/ESP32-S3-Touch-AMOLED-1.75

---

## Core Components

| Component | IC | Bus | Address / Notes |
|---|---|---|---|
| Power Management | AXP2101 | I2C | 0x34; controls display/peripheral/RTC rails |
| Touch Controller | CST9217 | I2C | 0x5A; interrupt on GPIO21 is a hint, not sole trigger |
| I/O Expander | TCA9554 | I2C | 0x20; controls CST9217 reset on P0 |
| RTC | PCF85063 | I2C | 0x51; on AXP2101 RTC rail, but no full power-removal retention on the tested board |
| Audio Codec | ES8311 | I2C/I2S | Schematic shows codec nets; not detected in current firmware scan |
| IMU | QMI8658 | I2C | 0x6B primary, 0x6A fallback |
| Display Driver | CO5300 | QSPI | 466x466 active AMOLED window |
| SD Card Slot | SD1 | SPI | Dedicated HSPI bus in firmware |

---

## Pin Assignments

### I2C Bus (Shared by AXP2101, CST9217, TCA9554, RTC, IMU)

| Signal | GPIO |
|---|---|
| SDA | GPIO 15 |
| SCL | GPIO 14 |

### Touch Controller (CST9217) - VERIFIED WORKING

| Signal | GPIO | Notes |
|---|---|---|
| I2C SDA | GPIO 15 | Shared I2C bus |
| I2C SCL | GPIO 14 | Shared I2C bus |
| INT | GPIO 21 | Touch interrupt (optional for polling) |
| RST | **TCA9554 P0** | **DO NOT USE GPIO 20** - see quirks below |

### Display (CO5300 QSPI AMOLED)

| Signal | GPIO |
|---|---|
| QSPI CS | GPIO 12 |
| QSPI CLK | GPIO 38 |
| QSPI D0 | GPIO 4 |
| QSPI D1 | GPIO 5 |
| QSPI D2 | GPIO 6 |
| QSPI D3 | GPIO 7 |
| RST | GPIO 39 |

### SD Card (SPI) - CONFIRMED FROM SCHEMATIC

| Signal | GPIO | Notes |
|---|---|---|
| CS | GPIO 41 | SPI Chip Select |
| MOSI | GPIO 1 | SPI Data Out |
| MISO | GPIO 3 | SPI Data In |
| SCK | GPIO 2 | SPI Clock |

> **IMPORTANT:** There is NO pin conflict between SD Card (SPI) and Touch (I2C). They use completely separate GPIO sets.

### GPS (UART Pads / Not Populated On This Model)

| Signal | GPIO |
|---|---|
| TXD | GPIO 43 |
| RXD | GPIO 44 |

This Waveshare model should be treated as no-GPS hardware. Do not add or debug
a UART GPS feature for this target unless a different assembled variant is
confirmed.

### Audio (I2S) - TO BE VERIFIED

| Signal | GPIO | Function |
|---|---|---|
| I2S_BCLK | TBD | Bit Clock |
| I2S_WS | TBD | Word Select (LRCK) |
| I2S_DOUT | TBD | Data Out (Speaker) |
| I2S_DIN | TBD | Data In (Mic) |
| ES8311_MCLK | TBD | Master Clock |

### User Buttons

| Signal | GPIO |
|---|---|
| BOOT | GPIO 0 |

### Breakout Pads (Bottom Edge of PCB)

- `IO18`, `IO17`, `IO16`
- `RXD`, `TXD`
- `3V3`, `GND`, `VBUS`
- `SDA`, `SCL`
- `EX0`, `EX1`, `EX2` (TCA9554 GPIO expansion outputs)

---

## Known Hardware Quirks

### 1. Touch Reset / GPIO 20 Conflict (CRITICAL)

**Observation:** GPIO 20 is physically the **USB D+ pin** on ESP32-S3. Toggling it as an output will immediately kill the USB-CDC/JTAG connection.

**Solution:** The Touch Reset is controlled by **TCA9554 Pin 0** (I2C address 0x20), NOT GPIO 20. Firmware must:
1. Initialize Wire on GPIO 15/14.
2. Send commands to TCA9554 to toggle P0 low → high for reset.
3. Never call `pinMode(20, OUTPUT)`.

**Verified:** This approach successfully initializes the CST9217 touch controller.

### 2. Power Sequencing (AXP2101)

The touch screen and display backlight are powered by the AXP2101 PMU. You **must** initialize the AXP2101 via I2C and enable the relevant ALDO/DLDO voltage rails before the screen or touch will respond.

**Initialization sequence:**
```cpp
Wire.beginTransmission(0x34);
Wire.write(0x90); Wire.write(0x9C); // Enable DLDO1
Wire.endTransmission();
// Enable ALDO1-4, BLDO1-2 similarly on registers 0x92-0x97
```

If the screen is black, it is likely an AXP2101 configuration issue, not a pinout error.

Verified firmware behavior:
- AXP2101 is found at `0x34`.
- Enable register `0x90` should read back `0x9C` after display/peripheral
  rails are enabled.
- Voltage register readback can be noisy on this shared I2C bus; treat final
  enable-register readback and successful peripheral initialization as the
  stronger boot signal.
- On USB, observed PMU status reports VBUS present and `battery=absent`.
- `POWER_SAVE` is intentionally not enabled for `WAVESHARE_AMOLED_175`.
  Temporary test builds with `POWER_SAVE` reproduced Bluetooth/IPC instability,
  and BOOT-button short/long presses did not produce reliable sleep/shutdown
  transitions on the waiting screen.

### 3. Touch Coordinate Mirroring

The CST9217 reports coordinates in native panel orientation. Depending on physical mounting, you may need to apply:
- `x = 465 - x` (Mirror X)
- `y = 465 - y` (Mirror Y)
- Or swap X/Y if rotated 90°

Current firmware keeps GPIO21 as an active-low touch hint and uses throttled
fallback polling. Do not make GPIO21 the only touch trigger: connected-device
tests showed idle/no-ACK touch reads and intermittent Arduino Core 3.x
`ESP_ERR_INVALID_STATE` failures, while the hint-plus-fallback policy kept tap,
drag, and long-press usable.

### 4. Display Window / Rotation (CO5300)

Use Waveshare's vendor geometry as the baseline:
- logical size: `466x466`
- active window: `466x466`
- constructor gap: `(6, 0, 0, 0)`
- normal firmware rotation: `0`

The diagnostic red/green/blue fill test no longer clips with this geometry.
Do not reintroduce 90-degree hardware rotation by default: earlier rotation
experiments showed green-edge/window artifacts. The slight clockwise angular
skew seen against the USB connector is also present in PR10, PR11, PR12, PR13,
and Waveshare's factory image, so it is treated as physical panel/lens/case
alignment rather than a firmware regression.

### 5. Shared I2C Bus Policy

All AXP2101, TCA9554, CST9217, PCF85063, and QMI8658 access shares `Wire` on
GPIO15/GPIO14. Keep the bus conservative:
- `100 kHz` is the known-good baseline.
- Use the Waveshare shared I2C helper for new board devices.
- Keep the FreeRTOS mutex around shared transactions; BLE callbacks can sync
  RTC time while LVGL/touch code is polling.
- Use retries, short timeouts, counters, and bus recovery rather than rapid
  unchecked polling.
- Avoid large burst reads on this bus unless tested on the connected board.

### 6. RTC (PCF85063)

The PCF85063 is detected at `0x51`. Firmware must reject invalid time when the
voltage-low flag is set or when decoded registers are outside the supported
range.

Full USB power-removal/replug without a battery was tested. On replug, AXP2101
reported `battery=absent`, the PCF85063 voltage-low flag was set, and the RTC
time was correctly rejected.

Battery-connected testing later showed `battery=present`. The first driver
version sometimes left the year byte at `0x07` while the other time fields
updated. The fixed path stops the divider while writing time, explicitly writes
the year register, and retries sync/readback and boot restore around transient
shared-I2C failures.

Verified after the fix:
- BLE/iPhone timestamp sync succeeds after retry.
- Warm reset restores system time from RTC before BLE reconnect.
- A first boot read can still fail due to shared-I2C instability, so restore
  must keep retrying before declaring RTC time invalid.
- Full USB-removal retention with battery connected still needs a final
  unplug/replug validation after this fix.

### 7. IMU (QMI8658)

QMI8658 identifies at primary address `0x6B` with `WHO_AM_I=0x05` after the
SensorLib-style reset-before-ID sequence. Keep `0x6A` only as a fallback probe.

Stable diagnostic configuration from PR15:
- accelerometer: `8g @ 125 Hz`
- gyroscope: `512 dps @ 112 Hz`
- enable accel + gyro via `CTRL7`
- read accel and gyro as separate 6-byte repeated-start reads at low rate

Avoid the earlier 17-byte timestamp/temp/accel/gyro burst read path: it caused
frequent I2C recovery on the connected board. The IMU is currently diagnostic
only; navigation, heading, wake, and ride-state behavior must not depend on it
until separately validated.

Observed axis signs:
- face-down: mostly `-Z`
- face-up: mostly `+Z`
- right-edge-up: mostly `+X`
- left-edge-up: mostly `-X`
- USB-up: mostly `+Y`
- USB-down: mostly `-Y`

### 8. SD Card / Map I/O

The SD card uses a dedicated HSPI bus, not the display QSPI bus. Verified pins
are `CS=41`, `MOSI=1`, `MISO=3`, `SCK=2`.

Firmware defaults:
- `WAVESHARE_SD_SPI_FREQ_HZ` default: `4000000`
- `WAVESHARE_SD_LIST_ROOT` disabled by default
- `WAVESHARE_MAPIO_TIMING_LOG` disabled by default

Bench measurements on the known-good 32 GB SDHC card showed faster SPI can
improve map block read time, but source still keeps 4 MHz until more cards and
cold boots are tested:

| SPI Frequency | Mount | Map Read | Block Load | First Generation |
|---|---:|---:|---:|---:|
| 4 MHz | 19 ms | 395 ms | 476-477 ms | 507-513 ms |
| 8 MHz | 18 ms | 213 ms | 292 ms | 321 ms |
| 12 MHz | 17 ms | 159 ms | 237 ms | 265 ms |
| 16 MHz | 16 ms | 123 ms | 200-209 ms | 229-237 ms |

`SDIO:` mount timing is low volume and always visible. `MAPIO:` timing is
verbose and must remain opt-in because redraw logging can add USB CDC pressure
during normal app-driven map use.

---

## I2C Device Scan Reference

When scanning the I2C bus, you should find:

| Address | Device |
|---|---|
| 0x20 | TCA9554 I/O Expander |
| 0x34 | AXP2101 PMIC |
| 0x51 | PCF85063 RTC |
| 0x5A | CST9217 Touch |
| 0x6A/0x6B | QMI8658 IMU |

---

## Status (Verified 2026-07-02)

| Feature | Status | Notes |
|---|---|---|
| Display | ✅ Working | CO5300 QSPI via Arduino_GFX; vendor 466x466 + 6px X gap; 90-degree hardware rotation disabled |
| Touch | ✅ Working | CST9217 @ 0x5A, TCA9554 P0 reset, GPIO21 hint + throttled fallback polling |
| SD Card | ✅ Working | Pins verified: CS=41, MOSI=1, MISO=3, SCK=2; 32 GB SDHC tested; 4 MHz default |
| RTC | ✅ Integrated | PCF85063 @ 0x51; invalid/voltage-low values rejected; BLE sync and warm-reset restore verified with battery present; full USB-removal retention still needs final battery retest |
| IMU | ✅ Diagnostic | QMI8658 @ 0x6B primary / 0x6A fallback; low-rate diagnostic accel/gyro sampling only |
| I/O Expander | ✅ Working | TCA9554 @ 0x20 controls touch reset; can be missed early but recovered by shared I2C retry/recovery |
| Audio | ⏳ Untested | ES8311 not detected in scan; treat as separate future bring-up |
| GPS | ❌ Not populated | This board model should be treated as no-GPS hardware despite UART pads |

## Known Issue: I2C Bus Instability

The I2C bus occasionally enters an invalid state (`ESP_ERR_INVALID_STATE`), causing:
- Phantom devices appearing in scan (93 instead of ~6)
- Touch read failures until bus is reset

**Possible causes:**
1. Touch controller (CST9217) holding SDA low
2. I2C clock stretching issues at 100kHz
3. Bus contention during rapid polling

**Workaround:** Use the shared Waveshare I2C helper, retry/recovery counters,
short transaction timeouts, and conservative `100 kHz` bus speed. Touch reads
must be interrupt-hinted and throttled rather than rapid-polled. New RTC/IMU
drivers should use the same shared helper and mutex instead of direct raw
`Wire` access.
