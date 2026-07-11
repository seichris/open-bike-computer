# Waveshare AMOLED 2.06 Audio Bring-Up

Date: 2026-07-09

Device under test: `WAVESHARE_AMOLED_206`

Observed USB port: `/dev/cu.usbmodem101`

## Result

The speaker works when driven through the ESP-IDF `esp_codec_dev` ES8311 path.
The production `WAVESHARE_AMOLED_206` firmware now includes the working codec
path and four selectable alert sounds controlled by the iOS app over BLE.

The working test was built in a temporary ESP-IDF PlatformIO project:

```sh
cd /tmp/ws206-honk-idf
pio run -e ws206_honk_idf
pio run -e ws206_honk_idf -t upload --upload-port /dev/cu.usbmodem101
```

Serial confirmation from the working path:

```text
ws206_honk: Waveshare BSP esp_codec_dev honk test, volume 40%
ES8311: Work in Slave mode
I2S_IF: STD: TX, data_bit: 16, slot_bit: 16, ws_width: 16, slot_mode: STEREO, slot_mask: 0x3
I2S_IF: STD: TX, sample_rate_hz: 16000, mclk_multiple: 256
Adev_Codec: Open codec device OK
[play] BSP codec honk 1/3
[play] BSP codec honk 2/3
[play] BSP codec honk 3/3
[play] BSP codec test done
```

## Confirmed Hardware Pins

These are the 2.06 audio pins from the Waveshare BSP and schematic:

| Signal | GPIO |
| --- | ---: |
| I2C SCL | 14 |
| I2C SDA | 15 |
| I2S MCLK | 16 |
| I2S BCLK/SCLK | 41 |
| I2S LRCK/WS | 45 |
| I2S DOUT | 40 |
| I2S DIN | 42 |
| Speaker PA control | 46 |

The ES8311 responds on I2C address `0x18` in 7-bit Arduino-style addressing. The `esp_codec_dev` driver uses the ES8311 default address definition internally.

## Working Audio Stack

The reliable path uses:

- ESP-IDF, not Arduino `ESP_I2S`.
- `esp_codec_dev` with the ES8311 codec driver.
- I2S master mode, ES8311 slave mode.
- MCLK enabled on GPIO16.
- PA control on GPIO46, active high.
- `esp_codec_dev_set_out_vol(spk, 40)`.
- `esp_codec_dev_open()` with:

```c
esp_codec_dev_sample_info_t fs = {
    .bits_per_sample = 16,
    .channel = 2,
    .sample_rate = 16000,
    .mclk_multiple = 256,
};
```

The temporary project carries a local copy of `esp_codec_dev` because the ESP component registry was not reachable from the build environment during testing.

## Failed Or Misleading Paths

Several Arduino-level and manual-register tests did not produce valid audio:

- Official pins with Arduino `ESP_I2S` and manual ES8311 register init: silence.
- TX-only Arduino/IDF-driver hybrid with manual ES8311 register init: silence.
- Pin-guess tests produced `pf pfff` or long `pffff` sounds. These were not valid codec audio; they were likely PA/clock/data artifacts.
- Earlier three-block pin tests seemed to produce a good honk once, but that result was not reproducible.

Important conclusion: the `pf pfff` sound should not be treated as partial success. The working signal is the clean honk from the `esp_codec_dev` path.

## Volume Notes

`esp_codec_dev_set_out_vol()` uses a nominal `0` to `100` volume range. Earlier direct ES8311 tests mapped volume to DAC register `0x32`, but the working path should use the codec API instead of direct register writes.

Confirmed tested volumes:

- `30%`: clean three honks.
- `40%`: flashed and serial-confirmed.
- `60%`: audition sampler confirmed.
- `70%`: current production default; each app request can select `0...100%`.

The production curve keeps `0...70%` at the previously tested levels and ramps
the upper range so `100%` targets `+20 dB` in the ES8311 DAC volume register.
A soft limiter protects positive-gain playback from hard clipping. Values above
`100%` remain unsupported.

## Current Temporary Test Shape

The successful temporary test initializes:

1. I2C bus on GPIO15/GPIO14.
2. I2S TX/RX channels on the official 2.06 pins.
3. `audio_codec_new_i2s_data()`.
4. `audio_codec_new_i2c_ctrl()`.
5. `es8311_codec_new()` with:

```c
es8311_codec_cfg_t es8311_cfg = {
    .codec_mode = ESP_CODEC_DEV_WORK_MODE_DAC,
    .pa_pin = GPIO_NUM_46,
    .pa_reverted = false,
    .master_mode = false,
    .use_mclk = true,
    .digital_mic = false,
    .invert_mclk = false,
    .invert_sclk = false,
};
```

Then it writes generated PCM honk samples through `esp_codec_dev_write()`.

## Integration Guidance

For production firmware, do not port the failed manual ES8311 register sequence. Integrate the same abstraction used by the successful test:

- Add/use `esp_codec_dev` for the 2.06 audio path.
- Add a board-specific audio init for `WAVESHARE_AMOLED_206`.
- Keep audio volume controlled via `esp_codec_dev_set_out_vol()`.
- Route generated alert PCM through `esp_codec_dev_write()`.
- Keep the display power and UI work separate from speaker bring-up; the screen was black during audio tests because the audio-only test firmware did not initialize the display.

Useful alternate alert sounds to test after integration:

- Short beep
- Double beep
- Rising chirp
- Descending chirp
- Bell ding
- Siren blip
- Train/air horn variant
- Click plus honk

## Production Integration

The production implementation is in `esp32/lib/speaker/` and uses a minimal
vendored copy of Espressif `esp_codec_dev` in `esp32/lib/esp_codec_dev/`.

The selected sounds are:

| BLE ID | App label | Implementation |
| ---: | --- | --- |
| `1` | Bell Ding | Generated 16 kHz PCM |
| `2` | Bicycle Horn | Embedded CC0 recording |
| `3` | Rotating Bicycle Bell | Embedded CC0 recording |
| `5` | Squeeze Horn | Embedded CC0 recording |

Recorded assets are signed 16-bit little-endian PCM at 16 kHz with two
channels. Their source and license information is recorded in
`esp32/lib/speaker/assets/LICENSE.md`.

Playback uses a dedicated FreeRTOS task and a four-entry request queue. This
keeps ES8311 initialization and PCM writes out of the NimBLE callback. The
codec is initialized lazily on the first request and uses the shared Waveshare
I2C helpers for register access.

The authenticated BLE command is `SNDP` followed by a `UInt8` sound ID and a
`UInt8` volume percentage in the range `0...100`. Legacy requests containing
only the sound ID use the `70%` default. The app stores the selection under
**Hardware Customization > Device Sounds** and the center-right button on the
main map sends the selected sound and volume.

## Hardware Regression Checklist

1. Build and flash `WAVESHARE_AMOLED_206`, then leave the serial port closed.
2. Power-cycle by removing and reconnecting USB; confirm the splash screen
   advances to the normal UI and remains responsive for at least two minutes.
3. Connect the iOS app and confirm the map sound button appears only after the
   authenticated device-capability status is received.
4. Select each sound and test volumes `0`, `70`, and `100`; confirm one tap
   produces one requested sound and the amplifier is quiet after playback.
5. Build `WAVESHARE_AMOLED_175`; confirm the Device Sounds settings are disabled
   and the map sound button is absent for that target.
