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
replays the esptool plan captured from PlatformIO during that build. The plan
includes PlatformIO's chip, reset, speed, resolved flash settings, non-application
offsets, and every referenced image. Because pioarduino can clear its application
offset after custom-core reuse, the helper resolves that one offset from the built,
attested partition table and rejects any non-empty PlatformIO value that disagrees.
Before attestation, the helper normalizes only
esptool's flash-mode, frequency, and size arguments to `keep`; otherwise esptool
can rewrite the bootloader header after it was hashed. This avoids a second
PlatformIO build and keeps the bytes and flash layout crossing the upload
boundary identical to the verified build:

```sh
python3 tools/build_firmware.py WAVESHARE_AMOLED_175 \
  --upload-port /dev/cu.usbmodemXXXX
```

Archive the emitted `FIRMWARE_BUILD_PROVENANCE` and
`FIRMWARE_UPLOAD_PROVENANCE` lines with physical test results. They bind the
clean Git/profile identity to PlatformIO's complete resolved flash plan and the
hash of every referenced image, plus the content-pinned pioarduino platform
archive and executable-package bootstraps, PlatformIO-installed
compiler/uploader/nested runtime trees through `coreAttestationSha256`, and
ignored generated dependency inputs presented for that upload. The helper
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
