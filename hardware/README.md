# Waveshare ESP32-S3 Touch AMOLED Hardware Reference

This document contains hardware pinouts and bring-up notes for the Waveshare
ESP32-S3 Touch AMOLED boards supported by this repo.

The 1.75" notes are the most thoroughly app-verified path and were extracted
from the official schematic. The 2.06" notes combine Waveshare's public
product/wiki pages, GitHub demo source, downloadable schematics/datasheets, and
connected-device bring-up tests on Chris's Mac.

## Documentation Library

The vendor PDFs are stored locally under [`reference/`](reference/). Board-only
documents live under `reference/boards/`, while manuals for components shared
by both boards live once under `reference/components/`. The ESP32-S3 manuals
remain board-specific because the 1.75 documentation and 2.06 wiki currently
link different revisions.

### ESP32-S3-Touch-AMOLED-1.75

- [Product page](https://www.waveshare.com/esp32-s3-touch-amoled-1.75.htm?sku=31262)
- [Official documentation](https://docs.waveshare.com/ESP32-S3-Touch-AMOLED-1.75)
- [Official demo repository](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75)
- [Schematic](reference/boards/waveshare-amoled-175/esp32-s3-touch-amoled-1.75-schematic.pdf)
- [Dimension drawing](reference/boards/waveshare-amoled-175/esp32-s3-touch-amoled-1.75-dimensions.pdf),
  extracted from the official [design archive](https://files.waveshare.com/wiki/ESP32-S3-Touch-AMOLED-1.75/ESP32-S3-Touch-AMOLED-1.75-3D.zip)
- [1.75-B dimension drawing](reference/boards/waveshare-amoled-175/esp32-s3-touch-amoled-1.75-b-dimensions.pdf),
  extracted from the official [1.75-B design archive](https://files.waveshare.com/wiki/ESP32-S3-Touch-AMOLED-1.75/ESP32-S3-Touch-AMOLED-1.75-B-3D.zip)

### ESP32-S3-Touch-AMOLED-2.06

- [Product page](https://www.waveshare.com/esp32-s3-touch-amoled-2.06.htm)
- [Official wiki](https://www.waveshare.com/wiki/ESP32-S3-Touch-AMOLED-2.06)
- [Official demo repository](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-2.06)
- [Schematic](reference/boards/waveshare-amoled-206/esp32-s3-touch-amoled-2.06-schematic.pdf)
- [Dimension drawing](reference/boards/waveshare-amoled-206/esp32-s3-touch-amoled-2.06-dimensions.pdf)

### ESP32-S3 Manuals

- [ESP32-S3 datasheet - current Espressif copy linked by the 1.75 documentation](reference/boards/waveshare-amoled-175/esp32-s3-datasheet-espressif.pdf)
- [ESP32-S3 technical reference manual - current Espressif copy linked by the 1.75 documentation](reference/boards/waveshare-amoled-175/esp32-s3-trm-espressif.pdf)
- [ESP32-S3 datasheet - Waveshare mirror linked by the 2.06 wiki](reference/boards/waveshare-amoled-206/esp32-s3-datasheet-waveshare.pdf)
- [ESP32-S3 technical reference manual - Waveshare mirror linked by the 2.06 wiki](reference/boards/waveshare-amoled-206/esp32-s3-trm-waveshare.pdf)

### Component Manuals

| Component | Boards | Local PDF |
| --- | --- | --- |
| QMI8658C IMU | 1.75 and 2.06 | [Datasheet](reference/components/qmi8658c-datasheet.pdf) |
| PCF85063A RTC | 1.75 and 2.06 | [Datasheet](reference/components/pcf85063a-datasheet.pdf) |
| AXP2101 PMU | 1.75 and 2.06 | [Datasheet](reference/components/axp2101-datasheet.pdf) |
| ES8311 audio codec | 1.75 and 2.06 | [Datasheet](reference/components/es8311-datasheet.pdf) and [user guide](reference/components/es8311-user-guide.pdf) |
| FT3168 touch controller | 2.06 | [Datasheet](reference/boards/waveshare-amoled-206/ft3168-datasheet.pdf) |
| ES7210 audio ADC | 2.06 | [Datasheet](reference/boards/waveshare-amoled-206/es7210-datasheet.pdf) |

### Software

- [Zimo221 Chinese character conversion software](https://files.waveshare.com/wiki/common/Zimo221.7z)
- [Image2Lcd image bitmap conversion software](https://files.waveshare.com/wiki/common/Image2Lcd2.9.zip)
- [Flash download tool](https://dl.espressif.com/public/flash_download_tool.zip)

### Other Resource Links

- [Image bitmap conversion tutorial](https://www.waveshare.com/wiki/Image_extraction)
- [Font library conversion tutorial](https://www.waveshare.com/wiki/E-Paper_Font_Tutorial)
- [MicroPython official documentation](https://docs.micropython.org/en/latest/)
- [ESP32 Arduino Core documentation](https://docs.espressif.com/projects/arduino-esp32/en/latest/index.html)
- [arduino-esp32](https://github.com/espressif/arduino-esp32)
- [ESP-IDF](https://github.com/espressif/esp-idf)

---

# ESP32-S3-Touch-AMOLED-2.06 Hardware Reference

## Primary Sources

Primary product and project pages:
- Product page: https://www.waveshare.com/esp32-s3-touch-amoled-2.06.htm
- Wiki: https://www.waveshare.com/wiki/ESP32-S3-Touch-AMOLED-2.06
- GitHub demo repository: https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-2.06

The local schematic, dimensional drawing, ESP32-S3 manuals, and component
datasheets are indexed in the [documentation library](#documentation-library).

Temporary reference clone used during bring-up:
- `/tmp/waveshare-amoled-206`
- Schematic PDF: `/tmp/waveshare-amoled-206/Schematic/ESP32-S3-Touch-AMOLED-2.06-Schematic-V1.0.pdf`
- Arduino pin macros: `/tmp/waveshare-amoled-206/examples/Arduino-v3.2.0/libraries/Mylibrary/pin_config.h`
- Display smoke test: `/tmp/waveshare-amoled-206/examples/Arduino-v3.2.0/examples/01_HelloWorld/01_HelloWorld.ino`

## 2.06 Core Components

| Component | IC / Part | Bus | Address / Notes |
|---|---|---|---|
| MCU | ESP32-S3R8 | internal | Dual-core LX7 up to 240 MHz; 8 MB PSRAM; external 32 MB flash |
| Display Driver | CO5300 | QSPI | 2.06" AMOLED, 410x502, 16.7M colors |
| Touch Controller | FT3168 | I2C | Vendor `FT3168_DEVICE_ADDRESS` is `0x38`; docs describe 10 kHz-400 kHz I2C support |
| Power Management | AXP2101 | I2C | PMU, charging, battery management; output-rail ownership is not yet electrically validated |
| RTC | PCF85063ATL | I2C | Address `0x51`; RTC rail is powered through AXP2101/battery path |
| IMU | QMI8658C | I2C | Schematic ties SDO/SAO low, so expected address is `0x6B` |
| Audio Codec | ES8311 | I2C/I2S | Audio codec used by vendor `08_ES8311` demo |
| Audio ADC / Mic Front End | ES7210 | I2S/TDM | Product page advertises dual digital microphone array; schematic includes ES7210 |
| SD Card Slot | TF / microSD | Native 1-bit SDMMC | Vendor path uses `CLK=2`, `CMD=1`, `D0=3`; the `CS`/D3 trace on GPIO17 is reserved for the post-HSPI migration fallback |
| Battery Header | MX1.25 3.7 V LiPo | PMU | Product page has battery-included and no-battery variants |
| Buttons | PWR, BOOT | GPIO / PMU | BOOT is GPIO0; PWR drives PMU power key path |

Waveshare documents this as a watch-shaped development board for wearable
prototyping. The product page and wiki both describe onboard Wi-Fi/BLE 5, a
Type-C connector, reserved I2C/UART/USB pads, TF card, IMU, RTC, audio, PMU,
and a 3.7 V lithium battery header.

## 2.06 Pin Assignments

### Shared I2C Bus

| Signal | GPIO | Devices |
|---|---:|---|
| SDA | GPIO 15 | AXP2101, FT3168, PCF85063, QMI8658, ES8311/ES7210 control |
| SCL | GPIO 14 | AXP2101, FT3168, PCF85063, QMI8658, ES8311/ES7210 control |

### Display (CO5300 QSPI AMOLED)

| Signal | GPIO | Source / Notes |
|---|---:|---|
| QSPI CS / `LCD_CS` | GPIO 12 | Vendor `pin_config.h` and schematic |
| QSPI CLK / `LCD_SCLK` | GPIO 11 | Differs from 1.75" GPIO38 |
| QSPI D0 / `LCD_SDIO0` / `QSPI_SIO0` | GPIO 4 | Vendor `pin_config.h` |
| QSPI D1 / `LCD_SDIO1` / `QSPI_SI1` | GPIO 5 | Vendor `pin_config.h` |
| QSPI D2 / `LCD_SDIO2` / `QSPI_SI2` | GPIO 6 | Vendor `pin_config.h` |
| QSPI D3 / `LCD_SDIO3` / `QSPI_SI3` | GPIO 7 | Vendor `pin_config.h` |
| Reset / `LCD_RESET` | GPIO 8 | Direct GPIO reset; differs from 1.75" GPIO39 |
| TE / `LCD_TE` | GPIO 13 | Schematic net; not required by HelloWorld |
| Panel power enable / `DSI_PWR_EN` | GPIO 39 | Schematic net; current Arduino_GFX app path works without driving it directly |

Vendor Arduino constructor baseline:

```cpp
Arduino_DataBus *bus = new Arduino_ESP32QSPI(
  LCD_CS, LCD_SCLK, LCD_SDIO0, LCD_SDIO1, LCD_SDIO2, LCD_SDIO3);

Arduino_GFX *gfx = new Arduino_CO5300(
  bus, LCD_RESET, 0, LCD_WIDTH, LCD_HEIGHT, 22, 0, 0, 0);
```

The known-good dimensions and gap are `LCD_WIDTH=410`, `LCD_HEIGHT=502`,
constructor gap `(22,0,0,0)`, rotation `0`.

Connected-device display findings on 2026-07-02:
- The board enumerated as ESP32-S3 USB CDC/JTAG on `/dev/cu.usbmodem2101`
  with VID:PID `303A:1001`.
- A standalone vendor-shaped HelloWorld test using registry Arduino_GFX `1.6.6`
  reported `gfx->begin() ok` and wrote continuous color fills.
- A second standalone test using Waveshare's bundled Arduino_GFX `1.6.0`
  also reported `gfx->begin() ok`; after full USB/battery power removal and
  USB-only replug, the physical display visibly cycled colors.
- The full app-linked display probe now visibly cycles white/red/green/blue
  after matching the vendor init order: bring up CO5300 display first, then
  configure the shared I2C/PMU stack.
- The full bike firmware boots on 2.06, initializes LVGL, advertises BLE,
  connects to the iPhone app, renders the SD-card map, and supports map drag.
- Therefore the 2.06 panel, QSPI pinout, reset pin, baseline Arduino_GFX
  constructor, and current repo app integration path are confirmed.

### Touch (FT3168)

| Signal / Field | GPIO / Value | Notes |
|---|---:|---|
| I2C SDA | GPIO 15 | Shared I2C bus |
| I2C SCL | GPIO 14 | Shared I2C bus |
| I2C address | `0x38` | Vendor `Arduino_DriveBus` constant |
| INT / `TP_INT` | GPIO 38 | Direct interrupt GPIO |
| RST / `TP_RESET` | GPIO 9 | Direct reset GPIO; no TCA9554 on 2.06 path |

The vendor Arduino LVGL examples use `Arduino_DriveBus` and construct
`Arduino_FT3x68` at `FT3168_DEVICE_ADDRESS`; our firmware should treat this as
an FT3168/FT3x68 family I2C touch controller rather than CST9217.

Connected-device touch findings:
- Direct GPIO9 reset and FT3168 I2C address `0x38` are confirmed.
- Idle FT3168 reads can produce Arduino Core 3.x I2C invalid-state errors.
  The app path gates normal reads on the GPIO38 touch interrupt and observed
  `i2c[fail=0 recover=0]` over idle serial captures.
- Map dragging works in the full bike firmware on the 2.06 board.

### SD Card (native one-bit SDMMC)

| Signal | GPIO | Notes |
|---|---:|---|
| CLK / `SDMMC_CLK` | GPIO 2 | Native SDMMC clock |
| CMD / `SDMMC_CMD` | GPIO 1 | Bidirectional command line |
| D0 / `SDMMC_DATA` | GPIO 3 | Single data line in one-bit mode |
| D3 / legacy SPI CS | GPIO 17 | Unused by native one-bit SDMMC; driven only by the migration fallback after native failure |

Waveshare's Arduino
[`07_LVGL_SD_Test`](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-2.06/blob/main/examples/arduino/07_LVGL_SD_Test/07_LVGL_SD_Test.ino)
configures these three pins with `SD_MMC.setPins()` and mounts with
`SD_MMC.begin("/sdcard", true)`. The schematic's SPI-compatible net labels do
not require the firmware to use SPI; the slot is wired for the vendor's
one-bit SDMMC path as well.

Connected-device SD findings:
- The former HSPI firmware read the card on `CS=17, MOSI=1, MISO=3, SCK=2`
  and rendered the offline map on the 2.06 board.
- Current firmware tries the native SDMMC controller on GPIO2/1/3 in one-bit
  mode first. This preserves isolation from display QSPI without owning an
  Arduino SPI controller in steady state; the old HSPI pins are used only by
  the migration fallback after native failure. Physical acceptance on 2.06
  remains pending.

### RTC And IMU

| Device | Signal | GPIO / Address | Notes |
|---|---|---:|---|
| PCF85063ATL | I2C SDA/SCL | GPIO15/GPIO14 | Expected address `0x51` |
| PCF85063ATL | `RTC_INT` | GPIO21 | Schematic net; app does not currently use this IRQ |
| QMI8658C | I2C SDA/SCL | GPIO15/GPIO14 | Schematic SDO/SAO low; expected address `0x6B` |
| QMI8658C | `QMI_INT1` | GPIO18 | Schematic interrupt net |
| QMI8658C | `QMI_INT2` | not routed for current firmware | Appears as test-point/internal schematic net |

### Audio

| Signal / Function | GPIO / Device | Notes |
|---|---:|---|
| I2S MCLK | GPIO 16 | Master clock |
| I2S SCLK / BCLK | GPIO 41 | Bit clock |
| I2S LRCK / WS | GPIO 45 | Word select |
| I2S DSDIN | GPIO 40 | ESP32 `dout` to speaker DAC |
| I2S ASDOUT | GPIO 42 | Codec/microphone data to ESP32 `din` |
| PA control | GPIO 46 | Active high |
| Speaker codec | ES8311 at I2C `0x18` | I2C control and I2S audio |
| Microphone front-end | ES7210 | Separate microphone path |

GPIO41 is audio BCLK on the 2.06; SD CS is GPIO17. Speaker playback uses the
ESP-IDF standard I2S driver and Espressif `esp_codec_dev` with:

- ESP32 I2S master and ES8311 slave DAC mode with MCLK enabled.
- Signed 16-bit little-endian stereo PCM at 16 kHz and 256x MCLK.
- Volume through `esp_codec_dev_set_out_vol()`, range `0...100`, default `70`.
- PCM output through `esp_codec_dev_write()` followed by a short silence drain.

The implementation is in `esp32/lib/speaker/`, with codec sources in
`esp32/lib/esp_codec_dev/`. It uses the shared mutex-protected I2C bus,
initializes the codec on first playback, and processes requests through a
four-entry FreeRTOS queue outside the BLE callback. It powers the codec and PA
down when the queue drains. PCM recordings are embedded
with PlatformIO `board_build.embed_files`.

#### Sounds And BLE

| Sound ID | App label | Implementation |
|---:|---|---|
| `1` | Bell Ding | Generated PCM |
| `2` | Plastic Bicycle Horn | Embedded PCM recording |
| `3` | Rotating Bicycle Bell | Embedded PCM recording |
| `5` | Squeeze Horn | Embedded PCM recording |

Authenticated playback uses:

```text
"SNDP" | SoundID: UInt8 | VolumePercent: UInt8
```

`VolumePercent` is `0...100`. A legacy frame without it uses `70%`. The command
uses settings characteristic `2A73`, with navigation characteristic `2A6E` as
a compatibility fallback. The production curve preserves the existing level
through `70%`, then ramps to `+20 dB` ES8311 DAC gain at `100%`. Playback above
the DAC's unity-gain point uses a soft limiter to prevent hard clipping.

The iOS app stores the selected sound and volume locally. The selector and
volume slider are under **Hardware Customization > Device Sounds**. Pressing
the sound button at the center-right of the main map sends the selected sound
and volume to the bike computer. Healthy serial output includes
`Speaker: playback task ready`, `Speaker: ES8311 ready at 70% default volume`,
and `Speaker: playing sound N at V% volume`.

The same settings group can enable the PWR button as a honk control. The app
sends the authenticated configuration as `"SNDH" | Enabled | SoundID | Volume`
and firmware persists it in NVS. PWR button activity is read from the AXP2101
interrupt-enable/status register pair `0x41`/`0x49`: bit `3` reports a short
press, while bits `1` and `0` report the press and release edges. Firmware polls
the latched status while awake and gives an active ownership comparison first
refusal to confirm physical access. At all other times an enabled honk is queued
on the existing speaker task. Firmware configures the PMU's hard power-off
threshold to four seconds. Versioned
capability discovery also returns the persisted honk configuration, so
reconnecting from a fresh app does not overwrite device state with app
defaults.

The local 2.06 schematic labels the AXP2101 IRQ net `EXIO5`, but does not route
that net to an ESP32 GPIO or a populated I/O expander. It therefore cannot wake
firmware through a direct GPIO interrupt on this board revision.

### Buttons, External Pads, And Power

| Function | GPIO / Net | Notes |
|---|---:|---|
| BOOT | GPIO0 | Standard ESP32-S3 boot strap / user button |
| PWR | PMU `PWRON` path | Side power key; not the same behavior as BOOT |
| UART | U0TXD/U0RXD | Exposed as reserved UART pads per product page/schematic |
| USB | USB_P/USB_N and reserved USB pads | Type-C connector plus pads |
| I2C pads | GPIO15/GPIO14 | Shared with onboard devices |
| Motor | `MOTOR` schematic net | Present in schematic; not implemented |
| Battery | 3.7 V MX1.25 LiPo header | Product page offers battery-included and battery-not-included variants |

## 2.06 Software Baseline

Waveshare's Arduino wiki path requires Espressif Arduino core `>=3.2.0`.
The wiki library table names:
- GFX Library for Arduino `1.6.0`
- LVGL `9.3.0`
- SensorLib `0.3.1`
- XPowersLib `0.2.6` in the wiki table, while the cloned repo currently
  contains XPowersLib `0.3.0`
- Arduino_DriveBus for touch
- `Mylibrary/pin_config.h` for board pin macros

Waveshare's Arduino demos:
- `01_HelloWorld`: CO5300 display/GFX smoke test; this is the known-good panel
  baseline we flashed successfully.
- `02_GFX_AsciiTable`: display character table.
- `03_LVGL_PCF85063_simpleTime`: RTC with LVGL.
- `04_LVGL_QMI8658_ui`: IMU line chart.
- `05_LVGL_AXP2101_ADC_Data`: PMU/ADC status.
- `06_LVGL_Arduino_v9`: LVGL plus touch through Arduino_DriveBus.
- `07_LVGL_SD_Test`: TF card file listing/display.
- `08_ES8311`: ES8311 audio echo/playback.

Waveshare's ESP-IDF demos include AXP2101, LVGL, esp-brookesia, an IMU
immersive block demo, microphone spectrum analyzer, video playback from TF
card, and factory firmware.

## 2.06 Current Repo Status

| Feature | Status | Notes |
|---|---|---|
| Standalone display baseline | Verified | Vendor-shaped HelloWorld and color-cycle tests work after full power removal/replug |
| App display integration | Verified | Full app boots after display-first init, BLE advertises/connects, LVGL flushes normally |
| Panel-specific UI | Implemented | 2.06 keeps the shared map path but uses board-specific GUI geometry and a lower map anchor to show more route ahead on the taller panel |
| Touch | Verified | FT3168 direct reset/address confirmed; map dragging works; idle reads are interrupt-gated |
| SD Card | Implemented / validation pending | Former HSPI map reads were verified; native one-bit SDMMC on GPIO2/1/3 requires the target-specific physical matrix |
| RTC | Partially verified | PCF85063 found at `0x51`; retention behavior still needs battery-backed power-removal validation |
| IMU | Partially verified | QMI8658 found at `0x6B` and reports motion; axis/sign tests still need validation on 2.06 |
| Audio | Verified / implemented | ES8311 speaker plays generated and embedded 16 kHz PCM; app selects the sound and `0...100%` playback volume, defaulting to 70% |
| Power / Battery | Partially verified | AXP2101 status readable; runtime and sleep paths never switch PMIC outputs. At boot, one compatibility operation may set only register `0x90` bit `0x80` to recover the established display supply after older firmware left it off; all other bits and voltage registers remain unchanged |

## 2.06 Bring-up Rules

- Keep `WAVESHARE_AMOLED_206` separate from `WAVESHARE_AMOLED_175`; the boards
  are not pin-compatible.
- Do not copy the 1.75" TCA9554/CST9217 reset path to the 2.06. Touch reset is
  direct GPIO9.
- Do not copy 1.75" display CLK/RST pins. 2.06 uses CLK GPIO11 and reset GPIO8.
- Do not drive the legacy 1.75-inch or 2.06-inch SD CS/D3 traces in one-bit
  mode. GPIO41 is audio BCLK on 2.06; native SDMMC uses only GPIO2/1/3.
- Use `esp_codec_dev` and the ES8311 driver with the audio pin assignments
  documented above.
- If the display is black, first flash the standalone vendor-shaped HelloWorld
  or color-cycle test before debugging app code. The verified baseline is
  CO5300 `410x502`, gap `(22,0,0,0)`, rotation `0`, QSPI pins
  `CS=12, SCLK=11, D0=4, D1=5, D2=6, D3=7`, reset `8`.
- The verified 2.06 LVGL flush sequence sends the RGB565 frame, then rewrites
  its first pixel through a 1x1 window to present the completed frame.
- USB CDC logging uses a 1 ms TX timeout so display rendering remains
  independent of whether a serial reader is attached.
- New firmware never turns the AXP2101 display-enable bit off. At boot it may
  set only register `0x90` bit `0x80`, preserving every other bit, so an OTA or
  rollback can recover from the state left by older 2.06 firmware. Generic PMIC
  writes to `0x90` remain blocked.
- A full USB and battery power removal can matter after failed experiments; the
  verified standalone display test became visible after power removal and
  USB-only replug.

---

## ESP32-S3-Touch-AMOLED-1.75 Core Components

| Component | IC | Bus | Address / Notes |
|---|---|---|---|
| Power Management | AXP2101 | I2C | 0x34; provides board power and charging; firmware treats output-rail registers as read-only |
| Touch Controller | CST9217 | I2C | 0x5A; interrupt on GPIO21 is a hint, not sole trigger |
| I/O Expander | TCA9554 | I2C | 0x20; controls CST9217 reset on P0 |
| RTC | PCF85063 | I2C | 0x51; on AXP2101 RTC rail, but no full power-removal retention on the tested board |
| Audio Codec | ES8311 | I2C/I2S | Address 0x18; production playback verified |
| Speaker Amplifier | NS4150B | Analog | Driven by ES8311; PA enable on GPIO46 |
| IMU | QMI8658 | I2C | 0x6B primary, 0x6A fallback |
| Display Driver | CO5300 | QSPI | 466x466 active AMOLED window |
| SD Card Slot | SD1 | Native 1-bit SDMMC | GPIO2 CLK, GPIO1 CMD, GPIO3 D0; GPIO41 D3/legacy CS is reserved for the post-HSPI migration fallback |

---

## ESP32-S3-Touch-AMOLED-1.75 Pin Assignments

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

#### CST9217 multi-contact contract

The 15-byte CST9217 point frame can report two contacts. Firmware treats
contact status `0x06` as active and `0x00` as released, acknowledges every
successfully read frame through register `0xD000`, and preserves contact IDs so
record reordering does not reverse pinch scale.

Two-contact ownership is intentionally limited to the standalone **Map** screen
on the 1.75-inch target. There it drives pinch zoom and suppresses LVGL's
single-pointer click path until every contact is released. Map + Navigation,
the destination picker, Navigation, Ride Stats, Battery, and other screens keep
their ordinary primary pointer; a second CST9217 contact must not synthesize a
release or click on those screens. The 2.06-inch FT3168 path remains
single-contact only.

GPIO21 is edge-latched with a monotonic interrupt generation counter so a short
touch indication cannot disappear while synchronous map cells are rendering.
The ISR only increments that counter. All CST9217 I2C reads and frame
acknowledgements remain in normal task context; never move I2C work into the
interrupt handler or return to rapid ungated polling.

As of 2026-07-28, two-contact parsing and standalone-Map pinch behavior have
been exercised on the 1.75-inch hardware. The complete ten-minute stability and
frame-time matrix, plus a post-change 2.06-inch single-contact smoke test, remain
required before treating the implementation plan's physical performance gates
as closed.

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

### SD Card (native one-bit SDMMC)

| Signal | GPIO | Notes |
|---|---|---|
| CLK | GPIO 2 | Native SDMMC clock |
| CMD | GPIO 1 | Bidirectional command line |
| D0 | GPIO 3 | Single data line in one-bit mode |
| D3 / legacy SPI CS | GPIO 41 | Unused by native one-bit SDMMC; driven only by the migration fallback after native failure |

> **IMPORTANT:** There is no pin conflict between native SDMMC and touch I2C.
> They use completely separate GPIO sets.

### GPS (UART Pads / Not Populated On This Model)

| Signal | GPIO |
|---|---|
| TXD | GPIO 43 |
| RXD | GPIO 44 |

This Waveshare model should be treated as no-GPS hardware. Do not add or debug
a UART GPS feature for this target unless a different assembled variant is
confirmed.

### Audio (I2S) - VERIFIED WORKING

| Signal | GPIO | Function |
|---|---|---|
| ES8311_MCLK | GPIO 42 | Master clock |
| I2S_BCLK | GPIO 9 | Bit clock |
| I2S_WS | GPIO 45 | Word select (LRCK) |
| I2S_DOUT | GPIO 8 | ESP32 data out to ES8311 `DSDIN` |
| I2S_DIN | GPIO 10 | ES8311 `ASDOUT` to ESP32 data in |
| PA_CTRL | GPIO 46 | Active-high NS4150B amplifier enable |

The production path uses the ES8311 codec and NS4150B amplifier with signed
16-bit stereo PCM at 16 kHz. Embedded horn and bell assets are available in
both the production `WAVESHARE_AMOLED_175` image and the standalone
`WAVESHARE_AMOLED_175_SPEAKER_HONK` smoke-test image.

This verified status supersedes older bring-up notes that described the 1.75"
audio path as TBD/untested or reported that the ES8311 was not detected. The
current status is backed by the physical production-image and audible-playback
validation recorded in [PR #62](https://github.com/seichris/open-bike-computer/pull/62),
the checked-in [1.75 schematic](reference/boards/waveshare-amoled-175/esp32-s3-touch-amoled-1.75-schematic.pdf),
Waveshare's [`08_ES8311` playback example](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75/tree/main/examples/arduino/08_ES8311),
the board-specific [production speaker driver](../esp32/lib/speaker/speaker.cpp),
and the dedicated smoke-test environment in [PlatformIO](../esp32/platformio.ini).

The 1.75 schematic powers the NS4150B from `VCC3V3`, so the firmware models the
PA and codec DAC rails as 3.3 V for volume calculations. This differs from the
2.06 path, whose established audio configuration models a 5 V PA rail.
The 1.75-specific volume curve maps the default `70%` setting to 0 dB DAC
gain, `90%` to +4 dB, and caps `100%` at +6 dB. This avoids the +20 dB ceiling
used by the separately calibrated 2.06 path.

The tested external speaker is marked only `F3`. That marking is not a usable
impedance or wattage rating, and neither the board schematic nor the speaker
marking establishes the speaker's electrical limits. Do not infer 4/8 ohm or a
power rating from `F3`; confirm the speaker datasheet or measure it before
changing the amplifier or gain assumptions.

[PR #223](https://github.com/seichris/open-bike-computer/pull/223) confirmed the
resource-cleanup fix and audible production playback over 12 repeated cycles;
the proposed 100-cycle soak was not completed. On 2026-08-12 the maintainer
accepted that remaining soak coverage as a non-blocking residual risk for the
1.75-inch release. This acceptance does not establish the `F3` speaker's
electrical rating or final volume calibration, and it does not qualify the
separate 2.06-inch target.

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

### 2. PMIC Rail Safety (AXP2101)

The AXP2101 provides board power and charging, but the populated load behind
every programmable output has not been electrically validated. Waveshare's
standard 1.75-inch display and ES8311 examples initialize those peripherals
without programming AXP2101 output registers. Firmware must therefore preserve
the PMIC's current output-rail configuration. That is not evidence of factory
state when an older image may have programmed a still-powered PMIC.

Safety rules:
- Probe AXP2101 at `0x34` and read status for diagnostics only.
- The generic firmware write allowlist contains exactly two addresses:
  interrupt-enable register `0x41` and write-one-to-clear interrupt-status
  register `0x49`, both used only for PWR-button events. A dedicated boot-time
  operation may read/modify/write only the PWR-button off-level bits (`3:2`) in
  register `0x27`; charger current/voltage, input limits, BATFET, DCDC, LDO,
  and every other AXP2101 register remain read-only.
- Turn the AMOLED panel off with its controller command. Do not assume an
  AXP2101 enable bit belongs exclusively to the display or another peripheral.
- A black screen is not sufficient evidence that an AXP rail should be forced;
  check the reset log, QSPI pins, build target, and panel initialization first.
- Before validating a migration from older firmware, disconnect both USB and
  battery. Reconnect only after all power is removed so the PMIC reloads its
  power-on baseline; otherwise the safe image preserves the older live state.

Verified firmware behavior:
- AXP2101 is found at `0x34`, and status plus the current LDO-enable value are
  logged without modifying them. The log labels that value as preserved current
  state, not verified factory state.
- A register-policy guard rejects generic writes to all 254 non-allowlisted
  AXP2101 addresses, with an exhaustive host test covering the complete
  address space. The dedicated off-level operation verifies that it preserves
  every bit outside register `0x27` bits `3:2`.
  A source-policy test also rejects raw `Wire.beginTransmission()` calls
  outside the guarded shared-I2C implementation.
- Deep and light sleep preserve PMIC output state; the panel, buses, and radio
  are managed independently.
- On USB, observed PMU status reports VBUS present and `battery=absent`.
- `POWER_SAVE` is intentionally not enabled for `WAVESHARE_AMOLED_175`.
  Temporary test builds with `POWER_SAVE` reproduced Bluetooth/IPC instability,
  and BOOT-button short/long presses did not produce reliable sleep/shutdown
  transitions on the waiting screen.
- The 1.75 schematic routes AXP2101 `IRQ` to TCA9554 P5 (`EXIO5`). The
  TCA9554's own `INT` pin is not routed to the ESP32, so this is readable only
  through another I2C transaction and is not a firmware wake GPIO. Keep the
  deadline-based AXP2101 status polling unless a later board revision exposes
  a direct interrupt.

These rules are intentionally strict for the 1.75-inch board implicated in the
short investigation. The 2.06-inch board has one separate, established
compatibility exception: during boot only, firmware reads register `0x90`, sets
bit `0x80` if needed, and verifies the result while preserving every other bit.
That one-way operation recovers a display supply that older 2.06 firmware could
leave disabled; it cannot turn any output off or change a voltage. Generic
AXP2101 writes remain limited to interrupt registers `0x41` and `0x49` on both
targets; the boot-time off-level operation is the only additional validated
exception.

### Boot Failure Telemetry and Safe Mode

Waveshare main-application and speaker-smoke firmware record the active and
last-completed setup stage in RTC no-init memory before touching each major
subsystem. The vendor-hello sketch remains an isolated upstream bring-up image
and does not implement this contract. The state survives panic, watchdog,
brownout, software, and USB resets. A new firmware fingerprint first emits the
prior valid record in `BOOT_PREVIOUS`, then starts fresh same-build failure
history. Full power removal or a checksum/schema failure makes the prior record
unavailable.

Diagnostic builds emit stable, machine-readable lines:

```text
BOOT_META schema=1 ... target=... profile=... git=... built=... reset=... resetCode=...
BOOT_PREVIOUS schema=1 ... fingerprint=... active=... completed=... failureCount=... failureStage=... failureAfter=... failureReset=...
BOOT_FAILURE schema=1 ... count=... stage=... after=... reset=... safeMode=...
BOOT_STAGE schema=1 ... event=enter|complete|ready|hold name=...
BOOT_PMIC schema=1 mode=read-only railState=current-preserved ... vbus=... battery=... ldo=...
BOOT_PMIC schema=1 mode=display-enable-only railState=display-enabled ... displayRecovery=1 displayChanged=...
```

`BOOT_META` is the source of truth for the image actually running; do not infer
it only from the local checkout or the upload command. `target` is the canonical
hardware/OTA identity, while `profile` distinguishes experimental and
production variants built from the same commit. An entered stage without its
matching completion marker identifies the first setup group to audit on the
next boot. `BOOT_PREVIOUS` retains the failed image fingerprint, original
failure fields, and the reset cause that ended it even when a new diagnostic
build clears the current history. On 1.75-inch firmware,
`BOOT_PMIC mode=read-only` means startup did not request an output-rail change;
the matching capture gate separately requires a successful PMIC probe and
status/LDO reads. On 2.06-inch firmware,
`BOOT_PMIC mode=display-enable-only` means the dedicated one-way compatibility
operation verified bit `0x80` enabled without changing other register bits;
its capture gate additionally requires `displayRecovery=1`. A preserved 1.75
`railState` remains unverified unless the PMIC was fully power-cycled. Any
`AXP_WRITE_BLOCKED` line is a failed safety gate and must be investigated.

After three unfinished early boots from the same exact build, the fourth boot
enters minimal safe mode before I2C, PMIC, display, storage, speaker, or BLE
initialization. Safe mode retains the original failing stage and can be cleared
by flashing a newly built image or removing all USB and battery power. A safe
mode decision is software containment evidence, not proof that a physical
short was software-caused.

Display-probe builds end in a distinct `diagnostic_hold` state after their
intended partial bring-up. That state does not satisfy full-app readiness and
does not count as a failed boot on the next reset.

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
- Use retries, short timeouts, counters, and board-appropriate recovery rather
  than rapid unchecked polling.
- On the 1.75 target, retries deliberately avoid tearing down or bit-banging
  the active controller after a failed transaction. Those recovery operations
  caused shared-bus startup failures on the tested board; a reboot remains the
  fallback for a persistent controller fault.
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

Current Waveshare firmware follows the vendor examples and uses the ESP32-S3
native SDMMC peripheral in one-bit mode on `CLK=2`, `CMD=1`, and `D0=3`.
The 1.75-inch GPIO41 and 2.06-inch GPIO17 D3/legacy-CS traces are not driven in
steady-state native mode; they are reserved for the migration fallback below.
SDMMC and the display QSPI controller are independent peripherals.

HSPI was introduced after the original global-FSPI implementation produced
post-display card read failures. It was a valid isolation fix: the verified
HSPI path avoided sharing the display's QSPI controller. Later 32 GB SDHC
testing exposed warm-reset CMD0/CRC failures even with complete HSPI teardown,
while Waveshare's maintained
[1.75](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75/blob/main/examples/arduino/07_LVGL_SD_Test/07_LVGL_SD_Test.ino)
and
[2.06](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-2.06/blob/main/examples/arduino/07_LVGL_SD_Test/07_LVGL_SD_Test.ino)
examples use native one-bit SDMMC. The migration changes the transport, not
the isolation invariant.

The transport transition has one unavoidable power-state boundary. An SD card
that entered SPI mode under older HSPI firmware cannot return to native SD mode
until the card itself loses power; `ESP.restart()` and SDMMC teardown do not
remove that power. The first boot across the HSPI-to-SDMMC transition can
therefore fail its native mount until all power sources keeping the card slot
alive are removed and the device is started again. The migration candidate
always tries bounded native SDMMC first, then uses the former isolated HSPI
transport as `legacy_spi_migration` only when native mounting fails. This keeps
the card and installed maps available during the warm migration boot. The
authenticated `DSTS` response reports that backend with
`powerCycleRequired: true`; Bicino persists a device-scoped instruction to fully
power off and disconnect USB, and clears it only after the same device reports
native SDMMC on a later boot. Bounded native retries remain useful for
controller lifecycle failures, but they cannot change the card's bus mode. See
the
[SD Association Physical Layer Simplified Specification](https://www.sdcard.org/cms/wp-content/themes/sdcard-org/dl.php?f=Part1_Physical_Layer_Simplified_Specification_Ver5.10.pdf),
section 7.2.1.

Firmware defaults:
- `WAVESHARE_SDMMC_FREQ_KHZ` default: `SDMMC_FREQ_DEFAULT` (20 MHz)
- `WAVESHARE_SD_MIGRATION_SPI_FREQ_HZ` default: 4 MHz
- `WAVESHARE_SD_LIST_ROOT` disabled by default
- `WAVESHARE_MAPIO_TIMING_LOG` disabled by default

The 20 MHz standard-speed default deliberately avoids combining the transport
migration with the vendor library's 40 MHz high-speed ceiling. Any frequency
change requires both-board, multi-card stability and throughput evidence.

Historical HSPI bench measurements on the known-good 32 GB SDHC card are kept
for comparison; they do not qualify the new SDMMC path:

| SPI Frequency | Mount | Map Read | Block Load | First Generation |
|---|---:|---:|---:|---:|
| 4 MHz | 19 ms | 395 ms | 476-477 ms | 507-513 ms |
| 8 MHz | 18 ms | 213 ms | 292 ms | 321 ms |
| 12 MHz | 17 ms | 159 ms | 237 ms | 265 ms |
| 16 MHz | 16 ms | 123 ms | 200-209 ms | 229-237 ms |

`SDIO:` mount timing is low volume and always visible. Mounting is bounded to
three attempts with full `SD_MMC.end()` teardown before each attempt and 50 ms
then 150 ms recovery delays. Success still requires a card type and root-open
health check. Native failure runs the equally bounded migration HSPI sequence;
only failure of both removable-card transports retains the existing FFat
fallback. `MAPIO:` timing is
verbose and must remain opt-in because redraw logging can add USB CDC pressure
during normal app-driven map use.

Validation recorded on 2026-08-28 for the 1.75-inch developer target at exact
Git SHA `059348754cce2c9712ff85f9a752bc2d5a7c8788`:

- a warm flash from the older HSPI firmware failed all three native SDMMC mount
  attempts, as expected for a still-powered card in SPI mode;
- after complete card power removal, the same card mounted on the first attempt
  at 20 MHz and reported type `SD` and 1914 MB capacity;
- subsequent resets while already running the SDMMC firmware mounted on the
  first attempt; and
- the 36,964,418-byte `Shanghai large` map was uploaded with SHA-256
  `24274f0641dee5614ae41955676320d9cada9680f3ba788dadb9b251021ac0cc`,
  installed, activated, read from the card, and visibly rendered on the device.

This is one board/card and one developer-profile result. It does not qualify
the 2.06-inch target, the production profiles, no-card fallback, runtime
remount, the multi-card matrix, or the current merged integration head without
a new physical run. It also predates the compatibility implementation: host
policy/protocol tests prove native-first ordering and app persistence semantics,
but an exact-head old-HSPI -> warm-reboot compatibility mount -> full-power-off
-> native-SDMMC sequence remains a physical release gate.

---

## I2C Device Scan Reference

When scanning the I2C bus, you should find:

| Address | Device |
|---|---|
| 0x18 | ES8311 audio codec |
| 0x20 | TCA9554 I/O Expander |
| 0x34 | AXP2101 PMIC |
| 0x51 | PCF85063 RTC |
| 0x5A | CST9217 Touch |
| 0x6A/0x6B | QMI8658 IMU |

---

## Status (Verified 2026-08-28)

| Feature | Status | Notes |
|---|---|---|
| Display | ✅ Working | CO5300 QSPI via Arduino_GFX; vendor 466x466 + 6px X gap; 90-degree hardware rotation disabled |
| Touch | ✅ Working | CST9217 @ 0x5A, TCA9554 P0 reset, GPIO21 hint + throttled fallback polling |
| SD Card | ⚠️ Working / qualification incomplete | One 1.75-inch board/card passed cold mount, subsequent reset, map write/install/read/render on exact SHA `059348754cce2c9712ff85f9a752bc2d5a7c8788`; the new native-first HSPI compatibility/user-flow path has host coverage but still needs exact-head physical migration validation, and the remaining target/card/fallback matrix is open |
| RTC | ✅ Integrated | PCF85063 @ 0x51; invalid/voltage-low values rejected; BLE sync and warm-reset restore verified with battery present; full USB-removal retention still needs final battery retest |
| IMU | ✅ Diagnostic | QMI8658 @ 0x6B primary / 0x6A fallback; low-rate diagnostic accel/gyro sampling only |
| I/O Expander | ✅ Working | TCA9554 @ 0x20 controls touch reset; can be missed early but recovered by shared I2C retry/recovery |
| Audio | ⚠️ Working / calibration pending | ES8311 + NS4150B playback and BLE-triggered honk verified; the external `F3` speaker's rating and final volume calibration remain unknown |
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
