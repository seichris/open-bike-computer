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

## Findings from the first successful 1.75-inch trial

- A signed build-99 image transferred from Bicino Dev and booted on the
  `WAVESHARE_AMOLED_175_PRODUCTION` board with `otaState=valid`. This proves one
  downgrade cycle, not an OTA upgrade or repeatability across boards.
- Maintenance startup needed distinct internal-stack ownership for Wi-Fi and
  flash operations, while the TLS worker used PSRAM and bounded response writes
  against DMA headroom. Earlier trials failed before any firmware bytes were
  uploaded, so those failures alone do not establish which single source change
  resolved transfer startup.
- The device's inactivity clock must be sampled after processing BLE transfer
  commands; an earlier sample could underflow against freshly updated traffic
  time and cause an immediate exit. A pre-session BLE drop must not silently
  end maintenance. Both behaviors were repaired before the successful trial.
- The iPhone's `BikeComputer-Transfer` system Join prompt was the final observed
  blocker. The app now allows 60 seconds for the first hotspot configuration
  and avoids an overlapping retry while that prompt is unresolved. The user
  accepted Join during the successful trial, after which pinned HTTPS and the
  firmware upload proceeded.
- Boot acceptance, app status, and verified USB recovery are separate checks.
  The board was restored to build 100 over USB and passed its ready checkpoint;
  the ten-cycle, fault-injection, SD-absence, resource-margin, 2.06-inch, and
  build-99-to-100 OTA tests remain open.
- A later signed build-97-to-99 upgrade trial failed before a firmware session
  appeared. The successful build-100-to-99 downgrade therefore does not prove
  that older installed firmware can upgrade over OTA.

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

The 1.75-inch production candidate from Git
`3f96c89a8aaf39e6165182d9422fccfe40532d27` (firmware image SHA-256
`cbf2d927d6a7b8f45925c1e40df042aacdd65c71a58bae104b138adc14a4b942`,
attested flash-plan SHA-256
`e1fa91a988c0ec15d921e297bdb684bddce2ca4f7eb662b144258ec5db9f88c5`)
was flashed over USB to serial `28:84:85:3B:75:20`. Esptool verified all four
written image hashes and reset the board. Bicino Dev reconnected and reported
build 100 and the same full Git SHA. This confirms the candidate's USB upload
and running identity.

A separately approved signed build-99 OTA from Bicino Dev 1.9 (23) still failed
before uploading image bytes. The app requested maintenance at 05:23:31 UTC,
reconnected to the maintenance boot with correlation `2192991118`, and sent
`enter|firmware`. It then lost BLE and reconnected to normal build 100. The
retained boot 354 began at 05:23:33 UTC with software-reset reason 3 and later
published a ready acceptance checkpoint for Git `3f96c89a8aaf39e6165182d9422fccfe40532d27`;
OTA state was `undefined`. Its retained `storage_gap` named
`maintenance/exit_inactivity` as the last critical event. Bicino Dev ended with
“Device did not report a firmware transfer session.” The support bundle passed
`tools/ride_diagnostics.py validate` (ZIP SHA-256
`9f0b4c2bdb1865afb70ee33120105b71f3f9164f3ea3d16ddf9e911cc3074dc7`).

Source inspection identified a clock-sampling race: the maintenance loop read
`millis()` before processing the BLE transfer command, which could update
`lastUsefulTrafficMs` to a later value. Unsigned subtraction then treated that
future timestamp as nearly 49 days of inactivity. The follow-up source fix
samples time after processing and rejects a future timestamp in the inactivity
policy. This fix needs its own exact production build and physical OTA test;
the 1.75-inch gate remains open.

The 1.75-inch production image from Git
`77d68e1e6b6a6a581d097712d7bdf1927d643d0d` (firmware image SHA-256
`3c3b39a9a004764ca45114de462800cc52dab75385e838c7152e9f4082b4be2d`,
attested flash-plan SHA-256
`6ab4d5bc99f67b66704b5540cc6f7be431be4fd0a93e8c9e1bdb66f9d23cb0ad`)
was flashed to USB serial `28:84:85:3B:75:20`. Esptool verified all four
written hashes. Bicino Dev reconnected and reported production build 100 with
the full Git SHA. The signed OTA gate remains open until this image completes
an approved update trial.

A separately approved build-99 OTA from Bicino Dev 1.9 (23) reached a new
boundary. The app requested transfer at 05:51:16 UTC, authenticated after the
maintenance reboot, and received correlation `55426110`. The device reported
`maintenance_boot_baseline`, then `network_ready` with an active `firmware`
transfer session and worker stack margin of 12,324 bytes. This physically
confirms that the earlier immediate `exit_inactivity` no longer prevented
maintenance transfer startup on the 1.75-inch board.

The iPhone did not associate with `BikeComputer-Transfer`. Its first hotspot
configuration waited the full 20-second app deadline; the recorder logged
`Bicino.DeviceNetworkJoin 1` at 05:51:38 UTC. A second application returned
`NEHotspotConfigurationErrorDomain 8`, with both network observations reporting
another network. The system's Join prompt was still visible after the app had
already reported failure. The app sent the transfer exit, uploaded zero image
bytes, and the device returned to normal production build 100. Retained boot
356 recorded `maintenance/exit_ble_command`, reset reason 3, a ready acceptance
checkpoint for Git `77d68e1e6b6a6a581d097712d7bdf1927d643d0d`, and OTA state
`undefined`. The support bundle passed `tools/ride_diagnostics.py validate`
(ZIP SHA-256
`c2a1e2b658e97e04fa438fc93b0cabc779e123678b83ccb45b696e5feb4055ff`).
This trial verifies maintenance startup but not image upload or OTA acceptance.
The 1.75-inch and 2.06-inch signed OTA gates both remain open.

An independently approved retry with the same signed build 99 reached
`network_ready` again, this time with correlation `1980752790` and a 12,324-byte
worker stack margin. The system Join prompt was visible, but the iPhone UI
automation runner remained busy while probing the modal. The app's first Wi-Fi
application timed out after 20 seconds and the second returned iOS internal
error 8. The user accepted the visible prompt after the app had already exited
firmware transfer. The subsequent BLE status identified normal build 100 at Git
`77d68e1e6b6a6a581d097712d7bdf1927d643d0d`. No firmware upload was reported.
Both attempts isolate the current physical blocker to confirming the iPhone's
accessory Wi-Fi join within the app's bounded deadline; they do not show an OTA
image or boot acceptance failure. Source review found that an observation of
another network cleared the typed timeout and allowed a second configuration
request while the first system prompt was unresolved. An iOS follow-up extends
the foreground callback window to 60 seconds, within the firmware's 90-second
pre-upload inactivity deadline, and prevents that overlapping retry. These
source changes still need a separately approved physical retry with the updated
app.

The next separately approved downgrade succeeded with the signed build-99 image
(`11bf6ebf0d4e130fe9a4698dd5888179fca7bb03447b47584fe1bc4ed5430922`)
and Bicino Dev 1.9 (23) from Git
`31be90cd114dbef0c117daa45213659d03504d64`. On the same 1.75-inch board,
the app requested firmware transfer at 06:19:30 UTC. The user accepted the
iPhone's `BikeComputer-Transfer` system prompt; the first Wi-Fi observation at
06:19:39 UTC was `target` with an accepted configuration. Two early pinned HTTPS
probes saw the route before it was ready. The third probe at 06:19:43 UTC
reached the accessory subnet, accepted the pinned TLS challenge, and received
the authenticated server response. The app displayed `uploading firmware`,
then `device rebooting`, and after BLE reconnect showed current build 99 with
Git prefix `ef18f363b281` and status `firmware is current`.

The new retained boot sequence 358 recorded production target
`WAVESHARE_AMOLED_175`, version 0.3.4, build 99, full Git
`ef18f363b281528192e7fe5215434eb374e59f5c`, `ready=true`, and
`otaState=valid`. The exported support bundle passed
`tools/ride_diagnostics.py validate` (ZIP SHA-256
`ea034ced73fab897f010aaf3240116e2ac1dc9b54b6d0fb9bd3bf1f8d25451e4`),
and `tools/verify_firmware_boot_acceptance.py --ota` passed for that exact boot.
This closes the single signed downgrade trial on the 1.75-inch board. It does
not close the ten-cycle, fault-injection, SD-absence, resource-margin, or
2.06-inch production gates above. A return to build 100 over USB is a separate
physical firmware write requiring its own exact approval.

### 2026-09-23 build-100 USB restore after the signed OTA trial

With separate user approval, the attested upload-only helper restored production
build 100 from Git `77d68e1e6b6a6a581d097712d7bdf1927d643d0d` to the
same Waveshare AMOLED 1.75, USB serial `28:84:85:3B:75:20` on
`/dev/cu.usbmodem2101`. The `WAVESHARE_AMOLED_175_PRODUCTION` firmware image
SHA-256 was `3c3b39a9a004764ca45114de462800cc52dab75385e838c7152e9f4082b4be2d`;
the attested flash-plan SHA-256 was
`6ab4d5bc99f67b66704b5540cc6f7be431be4fd0a93e8c9e1bdb66f9d23cb0ad`.
Esptool verified the written bootloader, partition table, boot app, and firmware
regions. Bicino Dev reconnected over BLE and reported current version 0.3.4,
build 100, Git prefix `77d68e1e6b6a`, and target `WAVESHARE_AMOLED_175`.

The post-restore support bundle passed `tools/ride_diagnostics.py validate`
(ZIP SHA-256
`e0153ad198b4c54e4d888546b8997d990c6e7791b313ca3acc844c482517619d`).
Retained boot sequence 359 reached its acceptance checkpoint at 06:32:12 UTC
with the full Git SHA above, production profile, `ready=true`, and
`otaState=undefined`. `tools/verify_firmware_boot_acceptance.py` passed for
that exact USB boot without `--ota`. The board is back on build 100. This USB
restore does not establish a build-99-to-100 OTA upgrade.

### 2026-09-23 signed build-97-to-99 upgrade trial

With separate user approval, the same 1.75-inch board (USB serial
`28:84:85:3B:75:20`) received production build 97 from release.6 Git
`6c30a4e89f0ebf5d6c9802eb8f9b04aa9fd8f249`. The local Mac build image
SHA-256 was `f9df5b872afe9fa528ed6902a076b6463bf53eaf52ef92b034edb79515355e93`;
the attested flash-plan SHA-256 was
`0ecfac838cc2d5d84e79c9a1dbe72de0be39dde33f3c308f7d71464a1b4bc013`.
Esptool verified the written regions. Bicino Dev 1.9 (23), from Git
`31be90cd114dbef0c117daa45213659d03504d64`, showed current build 97,
Git prefix `6c30a4e89f0`, target `WAVESHARE_AMOLED_175`, and
available signed build 99. Retained board boot sequence 360 independently
recorded the full build-97 Git SHA, production profile, and `ready=true`.

The exact signed target was release.7 build 99, Git
`ef18f363b281528192e7fe5215434eb374e59f5c`, image SHA-256
`11bf6ebf0d4e130fe9a4698dd5888179fca7bb03447b47584fe1bc4ed5430922`,
and manifest SHA-256
`9b4f6f68fe00e0817085c76ece03c2f7e0c2f84e53b48a6b7ca6a58e510a4842`.
At 08:57:21 UTC the iPhone requested firmware transfer. BLE disconnected,
reconnected, and authenticated by 08:57:37 UTC. Transfer-control ATT writes
continued for about a minute, but the app never observed a secure firmware
transfer session. It reported "Device did not report a firmware transfer
session" and `transfer_entry_failed` at 08:58:24 UTC. No image upload began;
the app still reported current build 97 afterward. This is a failed OTA
upgrade test, not an installed update.

The pre-upload signature resembles the previously documented build-98
transfer-startup failure. Build 97 predates the later device-side worker and
maintenance fixes, but this trial did not capture the maintenance boot's
serial output, so it does not isolate one failed allocation or command. The
board's retained log found the Shanghai map and loaded its renderer; its GPS
quality checkpoint had `fixValid=false`. A user also observed the physical
`iPhone connected` waiting screen, so map display acceptance remains unproven
for this build-97 baseline.

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
