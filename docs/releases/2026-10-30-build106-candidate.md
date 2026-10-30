# Build 106 candidate and remaining acceptance

Status: candidate preparation; **release held** until the gates under "Before
tagging" pass. Record every result against the actual commit, profile, binary
hash, device and new boot. Acceptance does not carry over to a different binary.

## Candidate scope

- Base: main `6463676a37a493d7abe990e90e3c139cc25cccb4`. The release SHA is the
  merge commit that brings this allocation into main.
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
- This is the first release after #662. Factory images carry the dual 4 MiB
  table; legacy devices that update over the air keep their dual 3 MiB table and
  run the new FFat ownership policy. The migration package is published with
  `qualificationRequired` and stays out of the website catalog.
- The 1.75 production image of `6463676a` is 3,014,224 bytes, below the
  3,080,192-byte legacy limit, so the legacy channel also carries this release.
  Record the 2.06 size before tagging.

## Evidence already obtained, with its limits

On the 1.75 `waveshare-175-b` (USB serial `28:84:85:3B:75:20`) with
`WAVESHARE_AMOLED_175_PRODUCTION` from `6463676a` (build 105 identity, binary
SHA-256 `61c5fd5a606da1acb60ef4506c2f343ef6ec3e452fa6b7cf454f809a1b5fe6cf`) on
the dual 4 MiB table, verified with `tools/verify_firmware_boot_acceptance.py`
from owner-exported support bundles:

- First USB boot: boot 662 accepted, ready, `resetReason` 11 (USB).
- True cold boot after removing USB and battery: boot 664 accepted, ready,
  `resetReason` 1 (power-on), runtime boot sequence 1, SD map loaded.
- FFat without an SD card: the 7 MiB span was erased and verified blank. The
  first boot formatted FFat (FAT serial `5D5E2B53`). The next boot left the boot
  sector identical. Diagnostics from boots 2 to 4 were recorded to FFat and
  exported intact (bundle SHA-256 `981a7070…`).

Earlier the same day, the developer layout from `54657fd0` formatted FFat once
and then mounted it, which prompted #668. These results qualify build 105 bytes
only: the candidate needs its own boot acceptance on each board.

## Decisions recorded

- OTA on the new layout and the legacy-device update (partition-layout gates 4
  and 7) run after publication. Chris, 2026-10-30: "for OTA we will do it once
  its deployed in dev and prod. Its fine to do that."
- #664 merged on Chris's acceptance of a partial 1.75 timing comparison. Its
  2.06 comparison and the production boot acceptance on both boards remain
  release gates.

## Before tagging

- [ ] Exact-candidate CI Gate on the merge commit.
- [ ] 1.75, on the candidate's exact production image: first-boot acceptance
  with `--build 106` and the release SHA, true cold boot, and FFat format-once
  with diagnostics export. The `6463676a` results above differ from the candidate
  only in the revision constant, but they carry over only by a recorded
  maintainer decision.
- [ ] 2.06, separately: first-boot acceptance, true cold boot, FFat format-once
  with diagnostics export, and the startup comparison
  (`WAVESHARE_AMOLED_206_PRODUCTION`, main before #664 against the candidate).
- [ ] Record the 2.06 production image size against the legacy limit.
- [ ] Legacy-table FFat adoption. The 1.75 image fits the legacy limit, so this
  release reaches legacy dual 3 MiB devices over the legacy channel. There it
  runs the new FFat ownership policy against a volume at `0x610000` that release
  13 formatted, with no ownership record. Every result above comes from the dual
  4 MiB table. Either run a lab test on a 1.75 before tagging, or record the
  maintainer's acceptance that the field is the first run:
  - restore release 13 with the website's legacy rescue;
  - record diagnostics on FFat with no SD card;
  - write only the candidate application to app0;
  - confirm a no-card boot adopts the volume and keeps those diagnostics.

## After publication

- [ ] OTA into app1 (`0x410000`) and back, with boot confirmation and forced
  rollback, on both boards and both app families. Use an app build that contains
  #662. The exports above came from app 1.11 (33), and bundles do not record the
  app's commit, so confirm that build before using it for OTA.
- [ ] A legacy dual 3 MiB device receives the release over the legacy channel.
- [ ] `/api/firmware/identities` lists the release's four records, and the update
  page shows no "records rejected" notice.
- [ ] Send the release SHA and build to the map platform so non-durable
  direct-job maps can be approved for build 106. Durable maps are unaffected.
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
