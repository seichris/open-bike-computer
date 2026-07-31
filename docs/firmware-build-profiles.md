# Firmware build profiles

The Waveshare firmware has four intentional profile classes for each display
target:

- `WAVESHARE_AMOLED_175` and `WAVESHARE_AMOLED_206` are developer/diagnostic
  builds. They keep USB CDC active, emit low-rate diagnostics, and pause for up
  to two seconds during boot so a serial monitor can attach.
- `*_POWER_METRICS` adds the structured `PWRMET` stream and optional timing
  pulse to the corresponding diagnostic build.
- `*_LIGHT_SLEEP` is the opt-in Phase 7B validation image. It inherits power
  metrics, enables tickless idle and automatic light sleep, and activates the
  application-managed display, map, storage, transfer, audio, and I2C locks.
  It also enables an ESP-IDF light-sleep exit callback that hands active-low
  touch/BOOT GPIO wake events to the UI task before the wake cause can be
  replaced by a later sleep cycle. On 1.75-inch hardware, the CST9217 interrupt
  is only a transient hint, so the profile also uses throttled, PM-locked frame
  sampling from tickless task deadlines. On 2.06-inch hardware, GPIO interrupt
  control remains in IRAM so each low-level live interrupt can mask itself
  until its source is released. The profile is built in CI but is never
  selected by the release workflow.
- `*_PRODUCTION` compiles with `CORE_DEBUG_LEVEL=0`, leaves `DEBUG` undefined,
  and sets `FIRMWARE_DIAGNOSTICS=0`. It does not start USB CDC at application
  boot and does not wait for a serial host. GitHub firmware releases use these
  profiles.

Production keeps native USB hardware support (`ARDUINO_USB_MODE=1`) but sets
`ARDUINO_USB_CDC_ON_BOOT=0`. The application therefore avoids the steady USB
CDC cost, while the ESP32-S3 ROM download mode remains available for recovery:
hold BOOT (GPIO0) while reconnecting USB, then flash the correct board target.

Each production profile keeps the canonical hardware target in firmware
metadata (`WAVESHARE_AMOLED_175` or `WAVESHARE_AMOLED_206`). The profile suffix
is intentionally not exposed over BLE, so released manifests and future OTA
updates continue to match the installed device.

Use a diagnostic or power-metrics build for serial capture. Do not compare its
battery runtime directly with a production build because USB and logging state
are deliberately different.

Use `WAVESHARE_AMOLED_175_LIGHT_SLEEP` or
`WAVESHARE_AMOLED_206_LIGHT_SLEEP` only for the dedicated physical validation
matrix. Ordinary and production profiles intentionally keep tickless idle and
automatic light sleep disabled until that matrix passes.
