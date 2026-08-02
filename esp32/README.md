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

The helper handles pioarduino's one-time tool-package conversion and
custom-core bootstrap, keeps pioarduino's recursive build on the verified
local project config, and confirms that PlatformIO produced the requested
firmware rather than its generated bootstrap sketch. The speaker test profiles
remain available through the manual **Speaker firmware builds** GitHub Actions
workflow.

After confirming the connected hardware profile, use the same helper for
upload. It revalidates the exact Git identity, toolchain, and image hashes, then
invokes the attested esptool runtime directly with the ESP32-S3 bootloader and
partition-derived OTA offsets. This avoids a second PlatformIO build and keeps
the bytes crossing the upload boundary identical to the verified build:

```sh
python3 tools/build_firmware.py WAVESHARE_AMOLED_175 \
  --upload-port /dev/cu.usbmodemXXXX
```

Archive the emitted `FIRMWARE_BUILD_PROVENANCE` and
`FIRMWARE_UPLOAD_PROVENANCE` lines with physical test results. They bind the
clean Git/profile identity to the exact firmware, bootloader, partition-table,
and OTA-bootstrap image set plus the content-pinned pioarduino platform archive
and executable-package bootstraps, PlatformIO-installed compiler/uploader/nested
runtime trees through `coreAttestationSha256`, and ignored generated dependency
inputs presented for that upload. The helper
also isolates ESP-IDF Component Manager state, rejects or scrubs ambient source
overrides, and requires strict component checksums. This is upload-input
preflight evidence, not flash readback: a later `BOOT_META` confirms the
embedded Git/profile independently but does not contain the artifact SHA-256s.
The host Python interpreter, top-level `pio` launcher, and pioarduino's first-run
online Python dependency resolver (its registries, external `uv`, private
`penv`, and ESP-IDF venv before their resulting trees are attested) are part of
the trusted workstation or CI boundary and are not pre-execution-proven by
`coreAttestationSha256`. The digest records the resulting installed trees and
rejects later mutation or mismatched reuse; it is not a Python dependency lock.

The available production, diagnostics, and test profiles are defined in
[`platformio.ini`](platformio.ini).

## License

This firmware retains its existing GNU General Public License version 3 terms.
See [`LICENSE`](LICENSE) and the repository's
[license summary](../README.md#license) for inherited and third-party licensing
details.
