# Read-only sleep audit

The Waveshare 1.75-inch and 2.06-inch firmware records `power.sleep_audit`
events through the existing local `ride_diagnostics` recorder. This helps
investigate standby battery loss without changing PMIC outputs, ADC settings,
peripheral sleep commands, disconnected timeouts, or wake-source policy.

It is not a current meter. Neither register-enable bits nor software shutdown
results establish a component's current consumption or physical supply voltage.
The audit adds bounded work at boot/shutdown; it adds no periodic wakeups and
runs no application logger during ESP32 deep sleep.

## Evidence and lifecycle

1. `Power::begin()` consumes a versioned, checksummed RTC no-init record and
   captures reset/wakeup evidence before the normal wake setup and hardware-RTC
   restoration. A successful same-firmware deep-sleep reset with a wake cause
   and retained final-entry checkpoint is `confirmed_deep_sleep`. A shutdown
   request alone is never described as confirmed entry.
2. A bounded boot-stage observer samples AXP2101 immediately after the shared
   I2C bus is configured, **before** PMIC initialization on either board. It
   saves this early sample in RAM. Standalone probes/speaker smoke tests do not
   register the observer; safe-mode initialization remains untouched.
3. At boot Ready, the normal recorder receives the saved wake/early sample and
   any retained pre-sleep snapshot. This late publication does not reread the
   now-initialized peripherals. Boot failure before Ready can prevent export
   of that wake snapshot; use existing boot/fault evidence as well.
4. `deviceShutdown()` records intent, context and a PMIC sample **before** the
   existing diagnostic seal. After sealing, only RTC-memory checkpoints are
   updated. There are no audit I2C/SD accesses, log flushes or new timer wakes
   in the final entry hook.
5. The next boot reports the seal result, which observations were enqueued,
   software shutdown stages reached, actual radio-stop / wake-configuration
   return codes, requested GPIO wake mask and GPIO0 input level at entry.

`reason=device_shutdown` intentionally identifies the shared shutdown path,
not a proven manual-versus-timeout reason. `timeout_s` is the configured timeout,
not the elapsed disconnected time or the unclaimed-device grace timeout.
`connected` and `audio_playing` are software snapshots at request time.
`display_policy` is the manager's requested policy (0 active, 1 dimmed, 2 off),
not electrical readback. In the existing manager, a failed lock can return its
active fallback. Idle audio is not proof that its external codec is off.

## What is sampled

The register whitelist is explicit in `sleep_audit_policy.hpp`:

- `00,01`: PMIC status, including battery presence, VBUS and current direction.
- `18,27`: gauge enable and PWR-button configuration.
- `30,34,35,36`: ADC configuration, battery-voltage bytes and debug-mode bits.
- `80..85,90..9A`: regulator enable/control/voltage configuration, kept raw.
- `A4`: battery state-of-charge estimate.

Each raw byte has an independent validity bit and prints `??` when unread.
A zero-valued *successful read* remains `00`, not unknown. The audit stops after
its first failed transfer, or before starting another group once 150 ms has
elapsed. An in-flight transfer still has the existing bus/Wire timeout; 150 ms
is not a strict wall-clock upper bound. The one-shot bus helper takes the shared
lock, never retries or resets the bus, and leaves its output untouched on a
short read. It does not consume touch frames or acknowledge PMIC interrupts.

Battery percentage requires observed battery presence, gauge enable, a valid
A4 read and a value in 0..100. Battery millivolts require observed battery
presence, an enabled voltage ADC, normal (not debug-remapped) ADC mode, and
successful voltage reads. Zero/unconverted or implausible values are unknown.
The existing ADC/gauge is never enabled just to obtain a sample. Even a
plausible reading has **unknown sample age**; it can be cached/low-rate data.
No discharge-current register or per-output current measurement is invented.

The raw regulator configuration does not assign loads to rails. The populated
rail/load mapping still needs separate electrical validation. The audit does
not claim to measure SD-card, touch, amplifier or sensor sleep state, and does
not read an output-only GPIO as though it were a voltmeter.

## Timing, retention and uncertainty

Elapsed time is emitted only for a correlated same-image deep-sleep wake,
when the build explicitly uses RTC-backed IDF system time and both observations
are plausible and monotonic. Backwards/uninitialized time and intervals above
366 days are unknown. The reported interval is **entry to early boot**, not a
precise duration spent asleep: it includes reset/startup overhead and the
existing diagnostic serial-attach delay. The audit reads boot time before
`restoreSystemTimeFromRtc()` can overwrite it. It does not set any clock.

RTC memory is not persistent storage. Battery removal, PMIC hard-off, changed
firmware layout, corruption or an interrupted checkpoint can leave no usable
record. `no_retained_request` is inconclusive, not proof that the device never
slept. A different image is classified `firmware_changed` rather than compared
as the same experiment. Records are consumed once to avoid stale wake claims.
A request without a later wake can reflect power loss or missing logs, not
necessarily a failed sleep transition.

`panel_update_applied=1` only means software dispatched the panel update.
Zero means no pending update **or** failure. `spi_end_called` and
`wire_end_called` mean those calls returned; they do not mean peripheral power
was removed or native SDMMC was shut down. Return code `-2147483648` means an
API was not attempted; other codes are the actual ESP-IDF return values.
`requested_wake_mask` is the mask passed to the existing final EXT1 call, not
an invented inventory of every possible enabled source. Wake pins are meaningful
for an EXT1 wake only.

The request enqueue mask has bits 0 raw registers, 1 battery, 2 read metadata,
3 context. Enqueued does not mean durable. `recorder_sealed=1` records the
existing seal result; inspect `logger.health`, dropped records and storage
errors too. Logging remains best effort through the existing bounded queues.
The audit neither reopens storage after shutdown nor guarantees delivery after
power loss. It does not upload anything automatically.

## Export and interpretation

Use the normal device diagnostic export and existing bundle/checksum validator.
Then inspect the extracted JSONL or run, from the repository root:

```sh
python3 tools/sleep_audit_summary.py /path/to/extracted/device
```

The viewer groups by sleep attempt, preserves all observations, renders unread
bytes and invalid timing as unknown/null, and never computes mA or watt-hours.
It fails visibly on malformed JSON instead of silently claiming a complete log.
It is not a replacement for the existing authenticated transfer/bundle validator.

The event uses the **existing closed field vocabulary** (`schemaVersion`,
`phase`, `domain`, `attemptId`, `state`, `available`). `state` is a bounded,
versioned semicolon-separated `key=value` hardware-state record, at most 256
characters. No new fields need to be accepted by an older companion app.
Domain values are `context`, `pmic_registers`, `pmic_read`, `battery`, `resume`,
`checkpoint`, and `api_results`. Phases are `request`, `retained_request`,
`early_boot`, and `wake`. Existing boot identifiers and firmware metadata remain
part of the recorder envelope. The C++/Swift/Python field allowlists are not
relaxed or extended.

For a battery experiment, start charged, unplug USB, let the actual disconnected
timeout expire, leave the board untouched, and wake with BOOT. Compare logs only
after the test; attaching USB can alter power state/reset the device. Repeated
confirmed short intervals suggest wakeups; a confirmed long interval with a
large gauge change warrants battery-side current measurement. A hardware PWR-off
comparison is useful but may intentionally destroy retained ESP32 evidence.

## Validation boundary

Portable policy tests cover failed/partial reads, timeout/wrap behavior,
invalid ADC/gauge data, corrupted/changed RTC envelopes, cold/reset/wake
classification, and invalid clocks. Host stubs exercise the actual audit runtime
and one-shot bus function for both board macros, including no duplicate boot
publication, no post-seal bus/log calls, queue rejection, and field limits.
The root test suite also checks the current C++/Swift/Python field vocabulary.

Run `python3 -m unittest tools.tests.test_sleep_audit tools.tests.test_sleep_audit_summary`
from the repository root. Existing ESP32 Host Tests CI discovers these tests;
no new workflow or permissions are needed. Automatic PR firmware CI builds the
1.75-inch ordinary/production targets only. Mocked 2.06 execution is not an
Xtensa build or hardware validation. No physical standby/ADC/retention test or
current measurement was performed while implementing this change. Existing
per-board release qualification and explicit residual-risk acceptance still apply.

Sources: [AXP2101 SWcharge v1.0](https://files.waveshare.com/wiki/common/X-power-AXP2101_SWcharge_V1.0.pdf),
[ESP-IDF sleep modes](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-reference/system/sleep_modes.html),
[hardware safety policy](../hardware/README.md), and
[existing diagnostics format](ride-diagnostics-format.md).
