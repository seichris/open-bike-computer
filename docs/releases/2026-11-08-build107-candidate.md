# Build 107 candidate and remaining acceptance

Status: **published** on 2026-11-08 at 15:38 UTC as tag `v0.3.4-release.15` on
`5f76f445`.

- No binary of this release has physical acceptance. The maintainer waived the
  1.75 and 2.06 checks; see "Decisions recorded".
- The release, its assets and the four over-the-air channel manifests are
  verified; see "After publication".

Record every result against the actual commit, profile, binary hash, device and
new boot. Acceptance does not carry over to a different binary.

## Candidate scope

- Base: main `58f6c92f732f38f1d9138bf0ef49b486bc36fb51`, the merge of #776.
- Release SHA: `5f76f445d4943c0984ed08eb299bba14a8b12cfd`, the merge commit of
  #780, which adds this document and allocates the build. The annotated tag
  `v0.3.4-release.15` (`4824b0cf`) points at that commit itself; a tag on
  another commit is a different candidate with a different source date.
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
- Production image sizes against the 3,080,192-byte legacy limit: the
  candidate's CI run (see "Before tagging") reports a total image size of
  2,593,051 bytes for the 1.75 and 2,581,387 bytes for the 2.06 in the ESP-IDF
  size report. The published `.bin` sizes are under "After publication".

## Evidence on the exact candidate

None. The maintainer waived the physical checks on both boards (see
"Decisions recorded"), so no binary of this release has physical acceptance.

Acceptance added later must name the published bytes listed under "After
publication". For example: an over-the-air install of the published image, a
flash readback that matches its SHA-256, and the owner-authenticated production
boot checkpoint from an app support bundle, verified with
`tools/verify_firmware_boot_acceptance.py --build 107 --git-sha <release SHA>
--version 0.3.4` (production has no serial logging; see
`docs/firmware-factory-release.md`). A local attested `<target>_PRODUCTION`
build of the release SHA is a different binary, so its result does not carry
over.

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
- The 1.75 production boot check is skipped as well. Chris, 2026-11-08, while a
  plain 1.75 (`waveshare-175-b`) was being prepared for it: "skip the boot
  check. Release everything first", and "we tested enough already".
  - Nothing ran on this exact candidate or on a production profile. The
    closest evidence is on earlier commits with ordinary profiles: the 1.75
    boot capture and the maintainer's app-driven smoke on the board-support
    stack head `f8b31c83` (2026-11-07, `waveshare-175-c`; see
    `docs/plans/board-support-architecture-plan.md`), and the plain 1.75 image
    built from M6 booting on the GNSS bench unit with the read-only PMIC and
    ready gates before #775 merged. The phone-navigation check on an M5/M6
    image is still owed.
  - Containment and signals are the same as for the 2.06 above.

## Before tagging

- [x] Exact-candidate CI Gate: run 42491856007 passed on #780's merge ref
  `822a5f0f`, whose tree (`16043316`) is the tree of `5f76f445`.
- [x] Both production images under the legacy limit, from that CI run: total
  image size 2,593,051 bytes (1.75) and 2,581,387 bytes (2.06).
- [ ] 1.75 on the exact candidate. Not run: the maintainer waived it (see
  "Decisions recorded"), so first-boot acceptance, a true cold boot with the
  production boot checkpoint, map display and phone navigation on this
  candidate remain residual risk for the 1.75.
- [x] 2.06: skipped on the maintainer's recorded acceptance (see "Decisions
  recorded"); its first-boot, cold-boot, display, touch and navigation checks
  remain residual risk.

## After publication

Publication (2026-11-08):

- Firmware Release Candidate run 42493860223 passed (15:15 to 15:36 UTC).
- The `seichris` account approved the publish job at 15:37 UTC under the
  maintainer's written instructions, quoted in the approval comment.
  `docs/firmware-factory-release.md` allows that account to approve its own
  run; it is not independent review. Firmware Release run 42495631248 published
  the release at 15:38 UTC and deployed the over-the-air Pages.
- Published OTA images, which are CI's build of `5f76f445`. No physical
  acceptance exists for these bytes:

  | Board | Image | Size (bytes) |
  | --- | --- | --- |
  | 1.75 | `WAVESHARE_AMOLED_175.bin` | 2,593,216 |
  | 2.06 | `WAVESHARE_AMOLED_206.bin` | 2,581,552 |

  SHA-256, as GitHub reports for the immutable release assets and as the
  verifier recomputed from the downloaded bytes:

  - 1.75: `abff373b798492c14669bbec128c315de1166460b370503b35161fb5235513a3`
  - 2.06: `d96fd7054c6cf0affeb984c8e88f27bdd260d5414c326d582dde5c6949de118a`

  Both are under the legacy limit, so devices on the legacy channel receive this
  release too.

- [x] Firmware Release Candidate and Firmware Release runs pass. The publish job
  was approved in GitHub by the release owner's `seichris` account, on the
  release owner's written instructions (above).
- [x] The GitHub release is immutable, with 24 assets, and
  `tools/verify_github_release_assets.py --require-immutable` passed.
- [x] All four Pages channel manifests serve build 107 and are byte-identical to
  the release's signed manifests: both boards, on both the legacy and the
  `dual4m` channels.
- [x] `/api/firmware/identities` on bicino.com lists the release's four records
  at 15:42 UTC, each identical to its release asset.
- [ ] An over-the-air update of the published image installs on a 1.75. Not
  run: waived with the 1.75 boot check (see "Decisions recorded").
- [ ] An over-the-air update of the published image installs on a 2.06. Not
  run: waived with the 2.06 checks (see "Decisions recorded").
- [x] The production map platform requires build 107 for non-durable maps:
  - record `msr-20261108-firmware-build107` (#781, merged as `5c8e9c13`), with
    the worker, producer, iOS identity and signing key of the previous record;
  - control-plane image `f415ab93…`, built and attested from `5c8e9c13`;
  - the hand-authored lock #782, merged as `b53bb680` at 15:50 UTC. `/healthz`
    reported the record, requiredFirmwareBuild 107 and the unchanged worker
    `d4394952…` at 15:59 UTC, after about 80 seconds of unavailability during
    the redeploy.

  The development promotion #778 merged at 15:54 UTC. The automation's
  production proposal #779 was closed as superseded, because it moved the
  control-plane pin without the promotion ID. Devices still on build 106 cannot
  install non-durable maps until they update; durable maps are unaffected.

Companion app: Bicino 1.13 (35), built from main `58f6c92f`, was submitted for
App Store review at 15:09 UTC, with release after approval and a phased
rollout. It carries the app changes merged since 1.12 (34); build 107 does not
require it.

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

To return production maps to the build-106 identity, restore the complete
previous lock in a pull request: `map-platform/deploy/compose.yaml` as of
`5c8e9c131e16eab769975170ee8b652cbe1d7fd8`, the first parent of the lock merge
`b53bb680`. That lock has:

- control-plane marker `bc7451ebfbbcf1ba86382855c7b2d4464d4f1b4b` and anchor
  `sha256:3cd641df582e31e3650fac9b398fa98e1c27f6de463437930c6225b895598348`;
- promotion ID `msr-20261105-topo-production`;
- worker marker `8baaf9804ebba273cfce3a7397ec6db341f49260` and anchor
  `sha256:d43949528703c4e7319ce0907f16ca00c9dde425ee085e90ef2bc183bbf85e00`,
  which #782 did not change.

Nothing rewrites signed map bytes.
