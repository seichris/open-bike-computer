# ESP32 firmware

Firmware for ESP32-powered Open Bike Computer devices. It receives navigation
and workout data from the iPhone app over Bluetooth and shows live ride stats,
turn-by-turn directions, and offline maps on the handlebar display.

## Supported devices

- [Waveshare ESP32-S3-Touch-AMOLED 1.75](https://www.waveshare.com/esp32-s3-touch-amoled-1.75.htm)
- [Waveshare ESP32-S3-Touch-AMOLED 2.06](https://www.waveshare.com/esp32-s3-touch-amoled-2.06.htm)

The firmware uses device-specific hardware profiles so it can grow beyond
today's AMOLED builds. We plan to support more ESP32 devices and display
technologies, including low-power e-ink bike computers.

See the [hardware guide](../hardware/README.md) for board details and verified
pinouts.

## Build

Install [PlatformIO](https://platformio.org/), then build the profile matching
your device:

```sh
python3 tools/build_firmware.py WAVESHARE_AMOLED_175
python3 tools/build_firmware.py WAVESHARE_AMOLED_206
```

The helper handles pioarduino's one-time custom-core bootstrap and confirms
that PlatformIO produced the requested firmware rather than its generated
bootstrap sketch. The speaker test profiles remain available through the
manual **Speaker firmware builds** GitHub Actions workflow.

The available production, diagnostics, and test profiles are defined in
[`platformio.ini`](platformio.ini).

## License

This firmware retains its existing GNU General Public License version 3 terms.
See [`LICENSE`](LICENSE) and the repository's
[license summary](../README.md#license) for inherited and third-party licensing
details.
