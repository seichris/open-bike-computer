# Firmware OTA Hardware Validation

Use this checklist after the firmware OTA branch is installed on the iPhone app
and the ESP32 device. These tests are the remaining proof that cannot be covered
by local builds or CI.

## Preconditions

- iPhone has the branch build installed.
- Device is running firmware built from this branch.
- GitHub Pages has a signed target manifest for the device target:
  - `WAVESHARE_AMOLED_175`
  - `WAVESHARE_AMOLED_206`
- GitHub Release has the matching target `.bin` asset.
- Device has enough battery or external power.
- USB flashing remains available as recovery.

Record before each test:

- Device model.
- Current firmware target/version/build shown in Developer Settings.
- Manifest target/version/build shown by Check Latest.
- Whether Developer Downgrade is enabled.
- Result and any device/app error message.

## Test 1: Foreground Update

1. Open the iPhone app.
2. Connect to the device over BLE.
3. Open Developer Settings.
4. Tap Refresh Device.
5. Tap Check Latest.
6. Verify the manifest target matches the connected device target.
7. Tap Install Update and keep the app foregrounded.
8. Wait for download, SoftAP transfer, finalize, reboot, and BLE reconnect.

Pass criteria:

- App reports firmware update installed.
- Device reconnects without manual BLE repair.
- Developer Settings shows the new version/build.
- Device remains usable after reboot.

## Test 2: Retry After Interrupted Upload

1. Start Install Update.
2. During upload, interrupt the transfer by locking the iPhone, disabling Wi-Fi,
   or moving out of range.
3. Confirm the app reports failure or unknown status.
4. Reconnect to the device.
5. Refresh Device and confirm the old firmware is still running.
6. Run Install Update again without interruption.

Pass criteria:

- Interrupted upload does not boot partial firmware.
- Retry starts from a full-image upload, not a partial resume.
- Retry can complete successfully.

## Test 3: Wrong Target Rejection

Run once for each cross-target direction when both devices or test manifests are
available:

- 1.75 device with a 2.06 manifest/image.
- 2.06 device with a 1.75 manifest/image.

Pass criteria:

- iOS refuses to offer or install the mismatched target.
- If the request reaches the device, ESP32 returns `target_mismatch`.
- Running firmware target/version/build remains unchanged.

## Test 4: Hash Mismatch Rejection

Use a test-only manifest or asset where the signed manifest SHA-256 does not
match the downloaded image.

Pass criteria:

- iOS rejects the image before upload with download hash mismatch, or ESP32
  rejects it with `sha256_mismatch`.
- Running firmware target/version/build remains unchanged.

## Test 5: Developer Downgrade

1. Publish or point the manifest URL at an older signed build for the same
   target.
2. Disable Developer Downgrade.
3. Tap Check Latest and verify install is blocked.
4. Enable Developer Downgrade.
5. Install the older signed build.

Pass criteria:

- Downgrade is blocked while the toggle is off.
- Downgrade succeeds only when the toggle is on.
- Target and signature checks still apply.

## Test 6: SD Card Independence

Run the foreground update on a 1.75 device:

- once with SD card inserted.
- once without SD card inserted.

Pass criteria:

- Firmware update does not depend on map storage being available.
- Existing map transfer behavior still reports SD-card availability correctly.

## Test 7: USB Recovery

After all normal OTA tests pass, verify the fallback path still works:

1. Flash known-good firmware over USB.
2. Boot the device.
3. Confirm BLE reconnects and Developer Settings reports the flashed build.

Pass criteria:

- USB flashing can recover the device.
- BLE identity/reconnect behavior remains acceptable after USB flash.

## Completion

### Open gate: application-owned boot confirmation

The firmware trust-chain fix defers Arduino's pre-`setup()` confirmation and
confirms only after finalization, pending map activation recovery and startup
power handoff. Confirmation failure must never publish a ready checkpoint;
pending-image rejection/reboot leaves rollback selection with ESP-IDF. Missing
SD media remains an allowed degraded mode, not a boot-failure criterion.

**Both 1.75 and 2.06 physical gates are OPEN.** Host stubs and compile checks do
not establish bootloader or flash behavior. Before release (or merge under an
explicit maintainer risk acceptance), record separately for each exact production
artifact:

- Effective SDK rollback flags and the linked strong `verifyRollbackLater`
  symbol; no pre-setup VALID transition.
- Inject crashes/hangs before Arduino init, during critical setup phases,
  during pending-map activation recovery, and just before confirmation.
  Reboot must select the previous usable partition, not inert safe mode.
- Inject confirmation-write failure and loss of power during OTA metadata
  changes; no false ready/acceptance record and a recoverable next boot.
- Prove successful confirmation, then a normal later reboot/crash does not
  roll back the already confirmed image. Verify first USB boot and USB rescue.
- Capture exact production `boot/acceptance` evidence with
  `tools/verify_firmware_boot_acceptance.py --ota` via authenticated device-log
  export. Test no-SD operation separately; the persistent log acceptance path
  itself needs working SD storage.
- Verify full-SHA iOS reconnect/relaunch completion and the exact immutable
  build-92/build-93 migration tuples, plus rejection of unrelated prefixes.

Do not tag, distribute, or call either target factory/golden before its gate
passes. A PR is source delivery, not hardware qualification.

Firmware OTA hardware validation is complete when:

- Foreground update succeeds on each supported target.
- Cross-target firmware is rejected in both directions.
- Interrupted upload leaves the old firmware active and retry succeeds.
- Hash mismatch is rejected.
- Developer downgrade policy behaves as configured.
- USB recovery is confirmed.
