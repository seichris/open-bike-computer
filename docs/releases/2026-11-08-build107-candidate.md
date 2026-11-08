# Build 107 candidate and remaining acceptance

Status: **candidate**, not published. The tag `v0.3.4-release.15` waits for the
gates in "Before tagging".

Record every result against the actual commit, profile, binary hash, device and
new boot. Acceptance does not carry over to a different binary.

## Candidate scope

- Base: main `58f6c92f732f38f1d9138bf0ef49b486bc36fb51`, the merge of #776.
- Release SHA: the merge commit of the pull request that adds this document and
  allocates the build. Tag that commit itself; a tag on another commit is a
  different candidate with a different source date.
- Firmware: 0.3.4 build 107, tag `v0.3.4-release.15`. Release 14 (build 106)
  was cut at `1c70b5562c6417e85d1365dda8bfb99c611ec9f9`.
- Release targets: `WAVESHARE_AMOLED_175_PRODUCTION` and
  `WAVESHARE_AMOLED_206_PRODUCTION`. The e-paper and the GNSS 1.75 variant are
  experimental targets that no release, factory or core-warm flow admits.
- Firmware changes since release 14 (93 first-parent commits on main; these
  pull requests changed `esp32/src`, `esp32/lib` or `esp32/platformio.ini`):
  - Board-support architecture (plan #672): #766 (M0 and M1, IceNav-era boards
    removed, board definition files), #767 (M3, board data instead of board
    names), #770 (M2, family startup code out of `main.cpp`), #772 (M4, the
    presentation split), #775 (M5, the position-source part and the CAP2
    position-source record), #776 (M6, the GNSS 1.75 variant; shared with the
    release targets: the TCA9554 expander lock, the I2C helper's raw transfers
    with unchanged bus constants, and the `DSTS` `positionSource` object), and
    #442 (experimental 3.97-inch e-paper support, shared files only for the
    release targets).
  - Map installs and storage: #689, #712, #721, #722, #726, #727.
  - BLE transfer reliability: #735, #737, #742, #747, #750, #751.
  - Image size: #714, #717, #718, #720, #728, #733 (compressed Montserrat
    fonts, lwIP IPv6 off), #734 (horn recordings removed).
  - Features: #706 (elevation and friend markers in dev and production).
- Production image sizes against the 3,080,192-byte legacy limit: recorded from
  the candidate's CI run before tagging.

## Evidence on the exact candidate

None yet. Each board needs a local attested `<target>_PRODUCTION` build of the
release SHA, an attested `--upload-only` with the stable device serial, and the
owner-authenticated production boot checkpoint from an app support bundle,
verified with `tools/verify_firmware_boot_acceptance.py --build 107 --git-sha
<release SHA> --version 0.3.4` (production has no serial logging; see
`docs/firmware-factory-release.md`).

## Decisions recorded

- The release is cut on the maintainer's request of 2026-11-08, after #776
  merged.
- The 2.06 gates are skipped on the maintainer's recorded acceptance of the
  residual risk. Chris, 2026-11-08, asked whether the 2.06 should run its
  production boot check for release 15: "Skip 2.06, accept risk".
  - This candidate changes much more of the 2.06's code path than release 14
    did: the board-support milestones moved its panel, touch, startup and
    presentation code into board files, and none of that has run on a 2.06. For
    this candidate the 2.06 has no first-boot, cold-boot, display, touch or
    navigation result.
  - Containment: an over-the-air install confirms its trial only after setup
    finishes (`markRunningAppValid` in `esp32/src/main.cpp`), so a reset, crash
    or safe mode during setup rolls back to the previous slot. A failure after
    confirmation, such as broken touch or a blank panel on a device that
    otherwise boots, is not rolled back; that device needs a higher build or the
    website's signed USB rescue (see "Recovery"). Redeploying release 14's OTA
    manifests stops further distribution.
  - Signals: owner-exported support bundles from 2.06 devices
    (`boot/acceptance`, `boot/confirmation_failed`) and field reports.

## Before tagging

- [ ] Exact-candidate CI Gate on the release SHA (or a merge ref with its tree).
- [ ] Both production images under the legacy limit, from that CI run.
- [ ] 1.75 on the exact candidate: first-boot acceptance and a true cold boot
  (all power removed) with the production boot checkpoint, map display and
  phone navigation.
- [x] 2.06: skipped on the maintainer's recorded acceptance (see "Decisions
  recorded"); its first-boot, cold-boot, display, touch and navigation checks
  remain residual risk.

## After publication

- [ ] Firmware Release Candidate and Firmware Release runs pass, the publish job
  approved in GitHub by the release owner.
- [ ] The GitHub release is immutable and
  `tools/verify_github_release_assets.py --require-immutable` passes.
- [ ] `/api/firmware/identities` lists the release's records, and an
  over-the-air update installs on a 1.75 (and on a 2.06 if one is available).

## Recovery

Stop on a new failure and keep the raw support bundle and physical notes.
Redeploying an earlier immutable release's OTA manifests with
`firmware-release.yml` only stops further distribution; it does not recover
devices that already installed build 107. Those recover through a new, higher
build published by the release owner (Chris), or through the website's signed
USB rescue run by each device's owner. An over-the-air install confirms its
trial only after setup finishes (`markRunningAppValid`), so a failure during
setup rolls back to the previous slot; a failure after confirmation does not.
Do not erase NVS or SD, rotate trust keys or bypass anti-rollback to recover a
test.
