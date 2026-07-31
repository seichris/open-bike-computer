# Firmware build profiles

The Waveshare firmware has three intentional profile classes for each display
target:

- `WAVESHARE_AMOLED_175` and `WAVESHARE_AMOLED_206` are developer/diagnostic
  builds. They keep USB CDC active, emit low-rate diagnostics, and pause for up
  to two seconds during boot so a serial monitor can attach.
- `*_POWER_METRICS` adds the structured `PWRMET` stream and optional timing
  pulse to the corresponding diagnostic build.
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
