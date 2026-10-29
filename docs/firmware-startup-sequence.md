# Waveshare startup sequence

Both Waveshare AMOLED boards render the real waiting screen before map
recovery. Map recovery, the diagnostics writer, Wi-Fi preparation, BLE and boot
acceptance keep their previous relative order after it. Other boards keep the
original order because their splash screen preloads the recovered map.

| Stage | Work | Notes |
| --- | --- | --- |
| `startup` … `clock_and_sensors` | Boot history, power, I2C, PMIC, RTC, IMU | Unchanged. |
| `display` | Panel bring-up | The 1.75-inch logo is drawn at the end. About 1,015 ms in every retained capture. |
| `storage` | SD mount, backend pin, recorder start | Diagnostics events only queue here. |
| `user_interface` | Map viewport, preferences, LVGL screens, waiting screen, one refresh | `lv_refr_now(display)` renders without running LVGL timers or input. Records `boot.waiting_screen`. |
| `map_recovery` | Journal recovery, active selection, map activation, rollback | Sole SD owner. Its time grows with the installed map. |
| `application_services` | Transfer servers, GPX folders, event loop, 1.75-inch Wi-Fi preparation | Wi-Fi resources are still allocated before BLE. The legacy splash, which draws outside LVGL, is not called. |
| `speaker`, `ble`, `finalization` | Audio, NimBLE, pending activations, OTA confirmation | `markRunningAppValid()` and `markReady()` remain last. |

The waiting screen stays static while recovery runs. BLE starts after recovery,
so a phone can connect only then.

Device ownership is loaded with BLE, after that first frame. The screen
therefore starts from the same fail-closed claimed state BLE uses when
ownership storage is unavailable: "Waiting for iPhone". An owned device never
shows the add-device Welcome. An unclaimed device switches to Welcome when BLE
reports its ownership on the first `loop()` pass.

## Why the screen moved

Retained device diagnostics from 2026-10-25 to 2026-10-29 showed that time to
the waiting screen grew with the installed map, not with later code:

- The PR 643 production test build (`08c05ea6`) had no active map
  (`boot_selection_final` = `active_missing`). Twelve boots reached
  `boot.acceptance` at 2,193–2,506 ms of uptime.
- With the Shanghai map, 21 boots across seven remote-debug builds spent
  4,839–4,919 ms in the boot `renderer_probe` (probe plus root switch). They
  reached acceptance at 9,489–9,986 ms, including the diagnostics profile's
  2,000 ms serial-attach delay.
- The probe scales with the map while visiting only two directory entries:
  about 4.9 s for Shanghai, 10.3–10.7 s for larger test maps and 20.8 s for
  China.
- The same profile and map did not regress across the PSRAM boot-test and
  descriptor-I/O changes. China took 20.80 s before them and 19.94–19.97 s after.

## Map activation work

Boot and runtime activation share `activateVectorMapFolderOnStorageOwner()`.
It probes one block and the block/font contract, then switches the renderer
root on the same storage owner.

- The probe hands its validated street-label font to the root switch instead
  of validating the same file twice.
- The font's glyph index is read in 16 KiB batches instead of one read per
  32-byte record.
- POI-enabled builds validate the Nearby index as a stream without storing its
  entries, using a nibble-table CRC with the same result as the bitwise form.

A failed switch still reports `root_switch_failed` and keeps the previous root.
Boot rollback still probes the restored selection.

## Preserved safety properties

- Map recovery runs on the setup task before `markRunningAppValid()` and
  `markReady()`. A crash or hang there still counts as an early boot failure
  toward safe mode, and a pending OTA image is still rolled back.
- Recovery remains the only SD user. The diagnostics writer, transfer servers
  and render worker start after it. The UI built before recovery reads no map
  storage.
- Wi-Fi preparation still precedes BLE on the 1.75-inch board. PSRAM boot
  initialization and its memory test are unchanged.

## Timing evidence

Diagnostics profiles print:

- `BOOT_STAGE`, measured from boot-diagnostics start. `user_interface`
  completion is the waiting-screen time.
- `BOOT_VISUAL milestone=first_ui` (1.75-inch), measured in raw uptime. It is
  now the waiting screen.
- `MAP_ACTIVATION_TIMING schema=1 source=boot|boot_rollback|runtime|runtime_rollback`.
  It reports `totalMs`, `lookupMs`, `blockMs`, `fontMs`, `fontReused`,
  `switchMs`, `visited` and `format`.

Every profile, including production, retains `boot.waiting_screen`,
`map.renderer_probe` (`durationMs` and `blockLoadMs`) and `boot.acceptance`.
Their `uptimeMs` values share one origin. Uptime starts after the ROM,
bootloader and PSRAM initialization, so only an external measurement shows
time from the PWR button. Diagnostics profiles add a 2,000 ms delay before the
display; never compare them with production timings.

## Physical comparison

The 1.75-inch and 2.06-inch boards are separate qualification targets. Each
keeps its own gate, and the change is not qualified on a board until that
board's comparison passes. Run the comparison once per board, each with one
board identified by its stable serial and the same SD card and active map in
every run. Build `WAVESHARE_AMOLED_175_PRODUCTION` or
`WAVESHARE_AMOLED_206_PRODUCTION` for each arm with `tools/build_firmware.py`.

1. Unplug USB, keep the battery above 60 % and keep the same owner-paired
   iPhone with the app in the foreground about 0.5 m away.
2. Shut down with the normal PWR long press. Wait 10 s, then press PWR the
   same way each time.
3. Record five power-ons per arm (A×5, B×5, then A once more) with 240 fps
   video showing the PWR button, the panel and the iPhone.
4. From the PWR press, measure the first logo frame (1.75-inch only), the
   first real waiting screen frame and the first frame where the app shows the
   device connected and authenticated.
5. Confirm "Waiting for iPhone" stays on the panel, at normal brightness, from
   its first frame until the app connects. It must not be replaced by the
   logo, a blank panel or Welcome on an owned device.
6. Export diagnostics for each arm and confirm, per boot:
   `boot_selection_final=loaded`, `boot.acceptance` with `ready=true` and the
   `renderer_probe` timings. On the 1.75-inch board, also check the Wi-Fi
   `boot_prepared` memory values.

## Background map activation (not implemented)

Loading the map after the waiting screen, BLE and acceptance would move BLE
readiness earlier by the activation time. It is deliberately not part of this
change. Consider it only if the physical comparison above shows production
BLE readiness with the owner's map still too slow after the activation
improvements. It must then provide:

- SD ownership: the transfer server, diagnostics writer, GPX folder creation
  and storage recovery stay gated until activation completes.
- BLE status: map switch, transfer and diagnostics-export commands return a
  typed busy result. The BLE contract and `docs/ble-protocol.md` change with
  the iOS handling.
- Rollback: boot rollback runs on the storage owner, serialized with the
  transfer server. The app receives the boot selection before any map status.
- Safe mode and OTA: either confirmation waits for activation, or a durable
  attempt counter skips the map after repeated unfinished activations, so a
  map-triggered crash loop cannot bypass both protections.

## Recovery

This change adds no storage migration, persisted format or protocol change.
To undo it, revert the change and build the previous production revision with
`tools/build_firmware.py`. If the device does not start, use the documented
USB/BOOT recovery path.
