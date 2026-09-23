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

For maintenance-boot qualification also record the stable USB serial, exact Git
SHA, production profile, build provenance, upload provenance and flash-plan
identity, partition table, running partition, iPhone build identity, maintenance
correlation, boot sequence/fingerprint, and every resource sample. Keep build,
upload, running-image, and physical observations as separate evidence.

## Maintenance resource qualification

Run this matrix independently on `WAVESHARE_AMOLED_175_PRODUCTION` and
`WAVESHARE_AMOLED_206_PRODUCTION`, using the exact production bytes under test.
Do not use a diagnostic build as production acceptance evidence.

1. Capture internal 8-bit and DMA free/minimum-free/largest-block values, PSRAM
   use, firmware-worker stack high-water bytes, allocation failures, and crypto
   headroom rejections at boot baseline, worker creation, AP startup, phone
   association, TLS handshake, manifest verification, erase, sustained upload,
   finalize, cancellation, and teardown.
2. Repeat the successful path without an SD card. SD absence must not prevent
   maintenance entry, transfer, or the authenticated boot checkpoint.
3. Verify the pre-worker and pre-listener resource floors admit every successful
   run with a documented margin. Raise candidate floors when the evidence
   supports it; never lower them below the emergency authenticated-control
   reserve merely to make a run pass.
4. Confirm two-minute unauthenticated exit, 90-second inactive-transfer exit,
   and ten-minute overall exit reclaim the listener, clients, Wi-Fi, worker, OTA
   handle, and transfer power lock, then return to a normal usable boot.
5. Run success, cancellation, timeout, malformed request, failed authentication,
   Wi-Fi interruption, and repeated-session paths. Compare teardown values with
   the baseline and investigate any accumulating loss or largest-block decline.

Record the chosen worker stack, each enforced floor, worst observed value, and
margin for both targets. A compile, simulator, or host-policy test does not close
this gate.

## Maintenance lifecycle matrix

- Complete at least ten consecutive signed OTA cycles per target, alternating
  slots. Then update once more from the newly installed candidate.
- Interrupt power during erase/write/verification and around boot selection.
  The old or new complete image may boot according to ESP-IDF state; a partial
  image must never be accepted.
- Disconnect BLE during erase/write and race cancellation against commit. A
  pre-commit cancellation must preserve the running slot. A post-boundary cancel
  must reconcile through the resulting boot and must not concurrently abort the
  OTA handle.
- Lose the maintenance acknowledgement, terminate/relaunch the app, lose the
  finalize response, and interrupt Wi-Fi. The app must query authoritative state,
  avoid blind replay, and distinguish cancelled, rolled back, failed, installed,
  and unresolved outcomes.
- Exercise invalid signature, wrong target, oversized image, bad hash, invalid
  image, missing/identical inactive slot, active ride, and active map activation.
  Each case must fail before unsafe mutation and preserve the usable image.
- After successful normal-ready confirmation, verify display, maps, audio,
  navigation, riding behavior, BLE pairing, normal reboot, rollback behavior,
  USB rescue, and a subsequent OTA from the accepted image.

### 2026-09-22 1.75-inch failed handshake evidence

The first `WAVESHARE_AMOLED_175_PRODUCTION` downgrade attempt reached the
maintenance reboot but failed before firmware upload. The iPhone reconnected,
completed owner authentication, and reported successful ATT writes for transfer
control, but received no correlated `DSTS` maintenance response. The device
exited maintenance after the two-minute authentication deadline and returned to
the original normal-ready image; no candidate image was finalized or selected.

Source analysis found two independent faults: maintenance omitted Route, GPS,
and Settings, so CoreBluetooth's cached native Settings handle no longer mapped
to the intended characteristic; and the maintenance loop passed a constant
unauthenticated state to its deadline policy. Regression tests and a clean build
are software evidence only. Repeat the exact physical path on the fixed
production artifact before closing any 1.75-inch gate; the 2.06-inch gate is
separate and remains open.

A later build-99 attempt used an iPhone build that paused ordinary navigation,
settings, GPS, diagnostics, and map-status traffic across the maintenance
reconnect. The authenticated reconnect sent only fresh device-transfer status
and firmware-entry control, but firmware never published a maintenance transfer
session, uploaded zero image bytes, and returned to the original build 98. This
isolated the remaining failure to device-side transfer startup rather than the
iPhone's background BLE traffic or Wi-Fi state.

Review of the first build-100 candidate found that moving only direct OTA calls
was incomplete. The PSRAM worker still initialized and stopped Wi-Fi, while the
hotspot-only path retained Arduino's default flash-backed Wi-Fi persistence.
The same review found that a timed-out owner command could complete late, leave
an untagged result for the next caller, and outlive protection of the shared
write buffer. These are source-derived hazards; neither was reproduced as the
cause of the build-98 reset.

The corrected build-100 candidate moves the firmware-maintenance TLS worker
stack to PSRAM and delegates Wi-Fi initialization/configuration/teardown plus
every cache-disabling OTA begin/write/end/abort/description/boot-selection call
to one serialized internal-stack owner. Wi-Fi persistence is disabled before
either station or hotspot initialization. The owner uses a bounded 2 KiB staging
buffer and enters a terminal poisoned state after a command timeout or mismatched
result, so a late operation cannot be paired with or have its buffer overwritten
by a later caller in the same boot. DSTS and app logs retain phase, correlation,
boot identity, memory extrema, and both worker stack margins. A successful
compile is not hardware evidence. The 1.75-inch gate remains open until the
production bytes start a fresh session, complete signed OTA, and pass the boot
acceptance validator; the independent 2.06-inch gate also remains open.

### 2026-09-23 build-100 signed OTA trial

The connected 1.75-inch board (USB serial `28:84:85:3B:75:20`) ran production
build 100 at Git `2676867dd192c689d987ad219c1b8823078d1aa2`. Bicino Dev
1.9 (23) verified the signed build-99 image
(`11bf6ebf0d4e130fe9a4698dd5888179fca7bb03447b47584fe1bc4ed5430922`)
and requested a developer downgrade. The app recorder shows an authenticated
maintenance reconnect followed by the firmware-transfer request at
04:07:32 UTC. BLE disconnected at 04:07:34 UTC. The next retained device boot
(sequence 348) started at 04:07:35 UTC with software-reset reason 3 and reached
normal-ready build 100 at 04:07:45 UTC; its OTA state was `undefined`. The app
waited until 04:08:35 UTC, reported “Device did not report a firmware transfer
session,” and had uploaded no image bytes. The device-log import and support
bundle passed `tools/ride_diagnostics.py validate` after a fresh app reconnect.

The maintenance boot deliberately skips SD recording, so its transfer-start
error is absent from that bundle. The two-minute authentication, 90-second
transfer-inactivity, and ten-minute overall deadlines cannot explain a return
to normal within seconds. A transient BLE disconnect or explicit exit is a
possible source-derived path; the exact trigger still needs a live serial and
iPhone log capture. This trial does not satisfy the 1.75-inch OTA gate. No USB
restore was needed because build 99 was never installed.

A second, separately approved attempt with the same signed image reproduced the
failure. The live iPhone log received maintenance correlation `3828212039`
with 129,027 bytes of free internal memory and 121,395 bytes of free DMA memory
immediately before the firmware-entry command. It received no `worker_created`
status afterward. The USB trace recorded the maintenance reset and the rapid
software reset back to normal, while the retained device log identified that
normal boot as sequence 350, build 100, reset reason 3, ready, and OTA state
`undefined`. The app again uploaded zero bytes and reported no transfer session.
Production disables USB CDC application logging, so this trace has boot ROM
reset headers but no application `Serial` messages.

The next candidate keeps maintenance running after a pre-session BLE disconnect
while revoking its credentials and partial transfer. The unauthenticated
two-minute deadline now also covers failed and cancelling pre-transfer stages.
This is a source-level repair and still needs a fresh physical test before any
OTA success claim.

The 1.75-inch production image from Git
`d566c5ce9bedd9cd692123addfe2fe41eff70c8b` (image SHA-256
`949e67d351dc83fa59b2aa5992ee4468cf76c3feef71878e78426c1e4256c442`,
attested flash-plan SHA-256
`9516cffd6b74ad474e1eee8505ba894c28a97cd65826da91aeb2e3faf218d161`)
was flashed with verified esptool hashes. The iPhone reconnected and reported
production build 100 with that full Git SHA. Retained boot 351 recorded the
same production identity and a ready acceptance checkpoint.

A separately approved signed build-99 OTA still failed before uploading image
bytes. The app sent `enter|firmware` at 04:54:34.841 UTC and lost BLE at
04:54:36.219 UTC. Retained boot 352 started at 04:54:37 UTC with software-reset
reason 3, then reached normal-ready build 100 with OTA state `undefined`. Its
`storage_gap` from the maintenance interval retained two missing events and
named `ble/authenticated` as the last critical event; it did not retain the new
`maintenance_ble_detached` warning. The validated support bundle was exported
at 05:02:10 UTC (SHA-256
`b56e854fde109a34a2df547ea345c7df20dde18b662783733be00cdc0e2aa961`).
The BLE disconnect may therefore follow the software reset rather than cause
it. The exact maintenance exit trigger is still unknown.

The next source candidate requires GPIO0 to be observed released before a
two-second BOOT hold can exit maintenance. It also records each explicit exit
path in the retained fault capsule, so a further software reset can be
distinguished from a transport drop. Neither this source change nor the
previous candidate qualifies OTA until tested on the device.

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
