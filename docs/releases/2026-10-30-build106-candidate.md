# Build 106 candidate and remaining acceptance

Status: **published** on 2026-10-30 at 13:17 UTC as tag `v0.3.4-release.14` on
`1c70b556`.

- The 1.75 gates passed on the exact candidate.
- On the 1.75, the release installed over the air into app1, and a forced rollback
  also passed; see "After publication".
- The 2.06 gates were not run. The maintainer accepted that residual risk; see
  "Decisions recorded".

Record every result against the actual commit, profile, binary hash, device and
new boot. Acceptance does not carry over to a different binary.

## Candidate scope

- Base: main `6463676a37a493d7abe990e90e3c139cc25cccb4`.
- Release SHA: `1c70b5562c6417e85d1365dda8bfb99c611ec9f9`, the merge commit of #677.
- Tag that commit itself. As of main `eb1183de`, later main commits change no
  firmware input: nothing under `esp32/`, `tools/firmware-runtime/` or
  `firmware-release.yml` has changed.
  A tag on another commit would still be a different candidate, with a different
  source date.
- Firmware: 0.3.4 build 106, tag `v0.3.4-release.14`. Release 13 (build 105) was
  cut at `63054f013fc7b82866ca35be12c0f4d6ea0744a8`.
- Firmware changes since release 13:
  - #662: dual 4 MiB production OTA slots, 7 MiB FFat with ownership checks,
    `dual4m` and legacy OTA channels, signed USB recovery and migration packages.
  - #667: pairing-confirmation deadline restarts when ownership is registered.
  - #668: `STORAGE_FFAT` is printed on serial and reports `formatted`.
  - #664: "Waiting for iPhone" is shown before map recovery.
  - #661: firmware core-cache tooling.
- Release tooling since release 13: #665 publishes a signed
  `<target>.image-identity.json` per target.
- This is the first release after #662:
  - Factory images carry the dual 4 MiB table.
  - Legacy devices that update over the air keep their dual 3 MiB table and run
    the new FFat ownership policy.
  - The migration package is published with `qualificationRequired` and stays
    out of the website catalog.
- Both production images fit the 3,080,192-byte legacy limit, so the legacy
  channel carries this release on both boards. CI run 41006600367 built:
  - the 1.75 image at 3,014,224 bytes;
  - the 2.06 image at 3,007,728 bytes, 72,464 bytes under the limit.

## Evidence on the exact candidate

### 1.75, 2026-10-30

Board `waveshare-175-b` (USB serial `28:84:85:3B:75:20`). The image is a local
attested `WAVESHARE_AMOLED_175_PRODUCTION` build of `1c70b556`:

- binary SHA-256 `233fc4867d71ca4fced4cae3b7736a22d243df8ad97997ca5a426d1b3958bba2`
  (3,014,224 bytes);
- flash plan `0b0f55df…`;
- runtime fingerprint `25A166D9`.

It was uploaded with `--upload-only --device-serial` onto the dual 4 MiB table
`60ec28f8…`. Every result comes from an owner-exported support bundle that passed
two checks:

- `tools/bicino diag verify --require ios,firmware`: integrity verified, every
  expected chunk present, no sequence gaps;
- `tools/verify_firmware_boot_acceptance.py --build 106 --git-sha 1c70b556…
  --version 0.3.4`.

The results:

- **First boot:** boot 671 at 08:45:50 UTC, one second after the upload,
  `resetReason` 11 (USB), ready. Bundle `8d7523f2…`.
- **True cold boot** after removing USB and battery: boot 674.
  - `resetReason` 1 and runtime boot sequence 1, with no wall time until the
    phone set the clock.
  - Ready at 11.8 s, and the SD map loaded.
  - No battery was detected at boot, so it started on USB power; boot 664 had
    the battery.
  - Bundle `198d6f17…`.
- **FFat format-once:**
  - The 7 MiB span was erased and verified blank. It was still blank after two
    boots with the card in.
  - Without the card, the first boot formatted FFat (FAT serial `5D5E6285`), and
    the next boot left the boot sector identical.
  - FFat boots 2 to 4 carry build-106 acceptance records and were exported
    intact. Bundle `6ed63bfc…`.
- **Legacy-table FFat adoption, lab test:**
  - Erased NVS, legacy app1 and the 9 MiB legacy FFat. The NVS erase was needed
    because this board's dual 4 MiB ownership record would make the candidate
    refuse the legacy volume as relocated. No field device has that record.
  - Wrote release 13's signed factory images. The recipe signature verified with
    the production key `bicino-release-p256-1`. The descriptor, the legacy table
    `6d6e1059…` and the app `a60aa419…` chained to it.
  - Release 13 without a card: FFat boot 1 formatted the volume at `0x610000`
    (serial `5D5E680B`), boot 2 mounted it, and the app was paired during boot 3.
  - Wrote only the candidate application to app0 with esptool and verified its
    digest. The table was unchanged.
  - Build 106 without a card, FFat boots 4 to 6:
    - The boot sector stayed identical while FAT and directory sectors changed.
    - Release 13's records from boots 1 to 3 survived alongside build 106's.
    - The app kept release 13's pairing.
    - Acceptance verified for boots 4 to 6.
    - Bundle `48cc5752…`.
  - Afterwards the board was restored: `0x410000`–`0xF10000` erased, then the
    attested upload again (dual 4 MiB table, binary `233fc486…`).

Notes on this evidence:

- Boot 673 is not cold-boot evidence. After the FFat erase the board had been
  left in the esptool bootloader. It came out with `resetReason` 6 and runtime
  boot sequence 3 without losing power. Its `boot/task_watchdog_context` record
  carries the previous run's progress markers and zero watchdog fields, so no
  app watchdog fired.
- Two log downloads failed while the Bluetooth link kept dropping. The board had
  logged the same churn on `6463676a` before the candidate was flashed. The
  download worked once the board lay still.
- These are local bytes. The release workflow builds `1c70b556` in CI, so the
  gates that need the release's exact bytes (migration 1, 2 and 6) use the
  published assets.

### Before the candidate: `6463676a` on the 1.75

On `waveshare-175-b` with `WAVESHARE_AMOLED_175_PRODUCTION` from `6463676a`
(build 105 identity, binary SHA-256
`61c5fd5a606da1acb60ef4506c2f343ef6ec3e452fa6b7cf454f809a1b5fe6cf`) on the dual
4 MiB table, verified the same way:

- First USB boot: boot 662 accepted, ready, `resetReason` 11 (USB).
- True cold boot after removing USB and battery: boot 664 accepted, ready,
  `resetReason` 1 (power-on), runtime boot sequence 1, SD map loaded.
- FFat without an SD card:
  - The 7 MiB span was erased and verified blank.
  - The first boot formatted FFat (FAT serial `5D5E2B53`), and the next boot
    left the boot sector identical.
  - Diagnostics from boots 2 to 4 were recorded to FFat and exported intact
    (bundle SHA-256 `981a7070…`).

Earlier the same day, the developer layout from `54657fd0` formatted FFat once
and then mounted it, which prompted #668. These results qualify build 105 bytes
only, and the 2.06 still needs the candidate's own acceptance.

## Decisions recorded

- OTA on the new layout and the legacy-device update (partition-layout gates 4
  and 7) run after publication. Chris, 2026-10-30: "for OTA we will do it once
  its deployed in dev and prod. Its fine to do that."
- #664 merged on Chris's acceptance of a partial 1.75 timing comparison. Its
  2.06 comparison and the production boot acceptance on both boards remain
  release gates.
- On 2026-10-30, the 1.75 cold boot and FFat checks were re-run on the candidate
  instead of carrying over the `6463676a` results. The legacy-table adoption lab
  test was run instead of accepting the risk.
- Later on 2026-10-30, the maintainer authorized publication without the 2.06
  gates: "dont hold the release. we dont need to verify it working on the 2.06
  board".
  - For this candidate the 2.06 has no first-boot, cold-boot, FFat, startup or
    legacy-adoption result.
  - Its image reaches new 2.06 devices with the dual 4 MiB table and older 2.06
    devices over the legacy channel.
  - Containment and recovery if a 2.06 fails:
    - An over-the-air install confirms its trial only after setup finishes
      (`markRunningAppValid` in `esp32/src/main.cpp`). Setup includes display,
      storage and the FFat ownership decision. A reset, crash, safe mode or
      failed confirmation before that point rolls back to the previous slot.
    - A failure after confirmation is not rolled back. For example, a refused
      FFat volume leaves the device running without internal storage. The device
      needs a higher build or the website's signed USB rescue (see "Recovery").
    - Factory images flashed over USB have no previous slot. They recover only
      through the USB rescue.
    - Redeploying release 13's OTA manifests stops further distribution. It
      pauses both boards.
    - The signals are owner-exported support bundles from 2.06 devices
      (`boot/acceptance`, `boot/confirmation_failed`) and field reports.

## Before tagging

- [x] Exact-candidate CI Gate: run 41006600367 passed on PR merge ref
  `7ed6d6e8`, whose tree (`d0d06a57`) is the tree of `1c70b556`.
- [x] 1.75 on the exact candidate: first-boot acceptance, true cold boot, and
  FFat format-once with diagnostics export (above).
- [x] Legacy-table FFat adoption: the lab test passed on the 1.75 (above).
- [x] 2.06 production image size: 3,007,728 bytes, under the legacy limit. The
  2.06 legacy devices therefore receive this release too.
- [ ] 2.06, separately. Not run: publication was authorized without these
  checks (see "Decisions recorded"), so they remain residual risk for the 2.06.
  - first-boot acceptance;
  - true cold boot;
  - FFat format-once with diagnostics export;
  - the startup comparison (`WAVESHARE_AMOLED_206_PRODUCTION`, main before #664
    against the candidate);
  - legacy-table adoption: either the same lab test, or a recorded decision that
    the 1.75 result covers it. The two boards share the storage code and the
    legacy layout.

## After publication

Publication (2026-10-30):

- Firmware Release Candidate run 41058468421 passed.
- The publish job was approved in GitHub, and Firmware Release run 41060936843
  finished at 13:17 UTC.
- The GitHub release is immutable, with 24 assets, and
  `tools/verify_github_release_assets.py --require-immutable` passed.
- Published OTA images, which are CI's build of `1c70b556`:

  | Board | Image | SHA-256 | Size (bytes) |
  | --- | --- | --- | --- |
  | 1.75 | `WAVESHARE_AMOLED_175.bin` | `ebc85e6f…` | 3,014,224 |
  | 2.06 | `WAVESHARE_AMOLED_206.bin` | `48361a36…` | 3,007,728 |

  These differ byte-for-byte from the local build of the same commit tested
  above.
- All four Pages channel manifests serve build 106 and are byte-identical to the
  release's signed manifests: both boards, on both the legacy and the `dual4m`
  channels. The `dual4m` channel did not exist before this release.

- [x] `/api/firmware/identities` lists the release's four records, and the update
  page shows no "records rejected" notice.
- [x] The release SHA and build reached the map platform. Production selected the
  build-106 approval `msr-20261030-firmware-build106` (#694, #695) at 13:52 UTC.
  Durable maps are unaffected.
- [x] OTA on the 1.75, with app 1.11 (33):
  - Setup: the board ran a local build of main `3eea2c8e` in app0. Its firmware
    inputs are identical to the release; only the commit differs. The app
    offered the published build as a developer same-build install. It does not
    reinstall an identical identity, and the build-number check is the only step
    the developer flag bypasses. The update itself ran in build 106's updater
    code.
  - Install into app1 with confirmation:
    - The trial boot 678 (`resetReason` 3, ready, `otaState` valid) passed
      `verify_firmware_boot_acceptance.py --ota`.
    - App1 (`0x410000`) matches the published `WAVESHARE_AMOLED_175.bin` by
      on-device digest.
    - Otadata shows app1 `VALID`, and app0 still held main's build.
  - Forced rollback:
    - After main was reflashed, a second install was interrupted by removing USB
      power during the trial boot. The board had no battery.
    - Otadata then showed app1 `ABORTED`, and the board booted main from app0.
    - A third install confirmed again: app1 `VALID`, digest matched. The board is
      left on the published release in app1.
- [ ] OTA still open:
  - back into app0, which needs a higher published build (release 107);
  - the 2.06 (waived);
  - an app that contains #662. App 1.11 (33) predates #662: it has no "OTA Slot"
    row and fetched the legacy-channel manifest. Its `dual4m` channel choice
    is therefore untested.
  - the Bicino Dev app family.
- [ ] A legacy dual 3 MiB device receives the release over the legacy channel.
- [ ] Migration gates 1, 2 and 6 with the release's exact bytes, with read-only
  website inspections before and after; then the catalog admission PR.

## Recovery

Stop on a new failure and keep the raw support bundle and physical notes.
Redeploying an earlier immutable release's OTA manifests with
`firmware-release.yml` only stops further distribution. It does not recover
devices that already installed build 106: OTA only moves to a higher build. Those
devices recover in one of two ways:
- a new, higher build with the fix, which the firmware release owner (Chris)
  publishes through the normal release workflow;
- the website's signed USB rescue, which the owner of each device runs.

Do not erase NVS or SD, rotate trust keys or bypass anti-rollback to recover a
test.
