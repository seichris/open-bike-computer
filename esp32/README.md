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

Do not install or select an ambient PlatformIO, pip, or uv. Run the tracked
stdlib bootstrap; it verifies the repository-owned runtime lock and re-executes
under its private CPython 3.13 and PlatformIO closure:

```sh
python3 tools/build_firmware.py WAVESHARE_AMOLED_175
python3 tools/build_firmware.py WAVESHARE_AMOLED_206
```

If the host has no usable `python3`, use
`tools/build_firmware_bootstrap.sh` with the same arguments. It obtains only the
exact tracked standalone-Python archive and then delegates to the same verifier.
The checked-in `firmware-runtime-2026-08-10-1` lock accepts exact Linux x86-64
and Apple Silicon bundles from the matching immutable tooling prerelease.
Unsupported hosts and any runtime whose locked bytes have changed fail before
PlatformIO.

The helper handles pioarduino's one-time tool-package conversion and
custom-core bootstrap, keeps pioarduino's recursive build on the verified
local project config, and confirms that PlatformIO produced the requested
firmware rather than its generated bootstrap sketch. The speaker test profiles
remain available through the manual **Speaker firmware builds** GitHub Actions
workflow.

Runtime bundles are immutable release assets selected by
[`tools/firmware-runtime/lock-v1.json`](tools/firmware-runtime/lock-v1.json).
The user cache transports reverified read-only bytes; mutable host and
PlatformIO stores remain under this worktree's `.pio/open-bike-build/`. If the
exact target is missing or corrupt, the build fails before PlatformIO executes.
Repair the selected subtree with the same command plus `--repair-runtime`; it
never resolves newer dependencies or falls back to another worktree or `/tmp`.

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
pio device list
python3 tools/build_firmware.py WAVESHARE_AMOLED_206 \
  --device-serial SERIAL_FROM_PIO_DEVICE_LIST
```

USB port names can change whenever an ESP32-S3 resets or reconnects. Prefer the
hardware serial reported by `pio device list`, especially when multiple boards
are attached. The helper resolves that serial immediately before flashing and
waits up to 60 seconds for it to appear; use `--device-timeout` to change the
wait. `--upload-port` remains available when stable serial metadata is not.

If the verified build succeeded but the upload failed because the selected
device disappeared, entered the wrong USB mode, or needed a cable reconnect,
retry the same attested build without compiling again:

```sh
python3 tools/build_firmware.py WAVESHARE_AMOLED_206 \
  --upload-only \
  --device-serial SERIAL_FROM_PIO_DEVICE_LIST
```

Upload-only still rechecks the clean Git/profile identity, generated SDK state,
installed toolchain, flash plan, and every image hash. Any change fails closed
and requires a new full build. Successful esptool completion is not enough to
identify the running firmware; confirm the expected target, profile, and Git SHA
from `BOOT_META` after reset. Use the same stable hardware identity with
`tools/capture_boot.py --device-serial ...` so verification cannot follow a
different attached board after USB re-enumeration.

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
The upload subprocess suppresses Python bytecode writes inside the attested
private environment so a missing-port failure remains eligible for an unchanged
upload-only retry.
Verified builds also export the exact Git commit's committer timestamp as
`SOURCE_DATE_EPOCH` to PlatformIO and ESP-IDF. Firmware `built=` metadata is
therefore the reproducible source commit time, not the local compilation time;
the manifest records both the epoch and ISO UTC timestamp. Public dependency
fetches use an empty isolated Git configuration so workstation URL rewrites do
not change the transport.
The initial OS and system-Python standard library remain trusted to run the
verifier. All subsequently executed Python, PlatformIO, uv, pioarduino root
environment, ESP-IDF environment, and esptool distributions are selected by
the content-pinned runtime bundle and re-attested after installation.

Custom-core reuse and upload eligibility are separate. A source-only change may
reuse a validated project-private core entry, while the firmware build manifest
is always regenerated for the exact Git SHA, commit clock, runtime/core
identity, generated state, artifacts, and flash plan. Dirty builds may consume
an existing core but never publish one or become upload eligible. Each clean
miss atomically publishes generated SDK sidecars plus an inventoried
`core-artifacts.tar`; each hit rehashes the entry and hydrates a private mutable
PlatformIO store. Corruption or post-build mutation quarantines only the exact
core key. Cross-worktree core sharing stays disabled until the recorded
artifacts pass the absolute-path relocatability gate.

The available production, diagnostics, and test profiles are defined in
[`platformio.ini`](platformio.ini).

## Internal ride-detection builds

The ordinary Waveshare development profiles compile the detector in shadow
mode and enable the internal end-to-end RAUT control gate. They can show
candidate progress, **Start Ride** / **Not Now**, confirmation progress,
**Auto-Paused**, separate elapsed/moving time, and actionable iPhone/Watch or
sensor errors on Ride Stats. The corresponding production profiles omit the
RAUT capability and control macro until both boards pass the physical
false-start, recovery, touch/I2C/BLE, and long-run soak matrix.

Ride detection controls and annotates the Watch-owned HealthKit workout. It
does not create standalone device recordings or ride history. Synthetic trace
replay and trace-scrubbing instructions are in
[`../docs/ride-automation-traces.md`](../docs/ride-automation-traces.md).

## License

This firmware retains its existing GNU General Public License version 3 terms.
See [`LICENSE`](LICENSE) and the repository's
[license summary](../README.md#license) for inherited and third-party licensing
details.
