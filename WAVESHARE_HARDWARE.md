# Waveshare ESP32-S3 Touch AMOLED 1.75" Hardware Reference

This document contains the definitive hardware pinout for the Waveshare ESP32-S3-Touch-AMOLED-1.75 board, extracted directly from the official schematic.

Official links:
- https://www.waveshare.com/esp32-s3-touch-amoled-1.75.htm?sku=31262
- https://www.waveshare.com/wiki/ESP32-S3-Touch-AMOLED-1.75

---

## Core Components

| Component | IC | Bus | Address / Notes |
|---|---|---|---|
| Power Management | AXP2101 | I2C | 0x34 (Controls bus power) |
| Touch Controller | CST9217 | I2C | 0x5A (Verified working) |
| I/O Expander | TCA9554 | I2C | 0x20 (Controls Touch Reset) |
| RTC | PCF85063 | I2C | 0x51 (Battery backed via AXP2101) |
| Audio Codec | ES8311 | I2C/I2S | 0x18 (I2C Ctrl) + I2S Data |
| IMU | QMI8658 | I2C | 0x6A or 0x6B |
| Display Driver | CO5300 | QSPI | N/A |
| SD Card Slot | SD1 | SPI | N/A |

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

### GPS (UART)

| Signal | GPIO |
|---|---|
| TXD | GPIO 43 |
| RXD | GPIO 44 |

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

### 3. Touch Coordinate Mirroring

The CST9217 reports coordinates in native panel orientation. Depending on physical mounting, you may need to apply:
- `x = 465 - x` (Mirror X)
- `y = 465 - y` (Mirror Y)
- Or swap X/Y if rotated 90°

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

## Status (Verified 2024-12-20)

| Feature | Status | Notes |
|---|---|---|
| Display | ✅ Working | CO5300 QSPI via Arduino_GFX |
| Touch | ✅ Working | CST9217 @ 0x5A, TCA9554 reset, coordinate mirroring |
| SD Card | ✅ Working | **Pins verified: CS=41, MOSI=1, MISO=3, SCK=2** (32GB SDHC tested) |
| RTC | ✅ Integrated | PCF85063 @ 0x51; PR14 driver added, BLE sync + warm-reset restore verified; full USB power removal loses RTC on current board (`battery=absent`) |
| IMU | ✅ Diagnostic | QMI8658 @ 0x6B primary / 0x6A fallback; PR15 detects/configures it and samples accel/gyro for diagnostics only |
| I/O Expander | ✅ Working | TCA9554 @ 0x20 (controls touch reset) |
| Audio | ⏳ Untested | ES8311 not detected in scan |
| GPS | ⏳ Untested | UART on 43/44 |

## Known Issue: I2C Bus Instability

The I2C bus occasionally enters an invalid state (`ESP_ERR_INVALID_STATE`), causing:
- Phantom devices appearing in scan (93 instead of ~6)
- Touch read failures until bus is reset

**Possible causes:**
1. Touch controller (CST9217) holding SDA low
2. I2C clock stretching issues at 100kHz
3. Bus contention during rapid polling

**Workaround:** The touch driver silently ignores failed reads, so touch still works functionally despite the errors.
