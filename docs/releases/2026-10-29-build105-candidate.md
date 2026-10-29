# Build 105 candidate and remaining acceptance

Status: candidate preparation; **release held**. This checklist does not authorize
flashing, installation, production deployment, merging, tagging or publication.
Record each result against the actual commit, profile, binary hash, device and
new boot. A source change after qualification requires impact review and new
exact-image evidence. Do not carry acceptance to a different release binary.

## Candidate scope

- Base: freshly fetched main `cb9e17aa709ec9390e026f1c459a7ee5a0d13913`.
- Tested integration: `3ba96a4c23e4d4bb4065be1da94aa4049af12708`, including
  PRs #650/#651, the completed-download row fix, GPIO11 touch IRQ correction,
  bounded follow-up reads and release acknowledgement.
- Reviewed concurrency fixes: #653 at
  `62cab11fa34bf80f56109218c34f878c47c867fc`.
- Reviewed map recovery fixes: #654 at
  `1b20424b821bc3f6a6e6ca24bbff06e131cb12bc`.
- Firmware: 0.3.4 build 105 (the allocation proposed in #617).
- Companion candidate: 1.11 (32), with separate Bicino Dev and Bicino families.
- Production backend image pins, approval registry and rollout flags remain as
  on the base. Experimental protocols remain disabled in shipping profiles.
- Caching, workout changes and unrelated renderer work are outside this candidate.

The build report records the final commit and hashes; this document cannot name
its own containing commit. Keep the report with attestation, flash plan, symbols,
CI URLs and physical logs. Production and remote-debug artifacts are distinct.

## Evidence already obtained, with its limits

On the 1.75, firmware `3ba96a4c` **REMOTE_DEBUG**, binary SHA-256
`bec216430abea10f6ee83feeec0e8e8ab9cb81fcce6131fde51035c4b92458ef`,
and Bicino Dev 1.11 (31):

- Touch wake, controls, hold, dragging, pinch, staggered finger release and quick
  taps worked on the physical bike; captures are retained.
- Wi-Fi installation reached an installed receipt and cleared its progress row.
- Two diagnostics exports passed chunk/hash verification. Recording coverage
  limitations remain recorded separately from transport integrity.
- Cold power-off/on restored Shanghai streets/buildings for the earlier map.
- The last conservative 78-second hands-off interval had stable touch counters.
  Two earlier recovered CST9217 transactions remain observation I2C-OBS-001;
  this is not evidence of zero I2C errors.

After the development backend rollout, contract-1 map
`shanghai-3a18bd4ae1`, 1,354,324 bytes, SHA-256
`e57378ef06126e0162dccdee98140c91bee4f7aaa99d856cbb5d7086cb8de65c`,
passed signature/manifest/payload verification, Wi-Fi installation, confirmed
terminal journal state and progress-row removal. Chris confirmed streets,
buildings and dragging. **This newest map has not yet had a cold-cycle test.**

These results qualify the named development artifacts only. They do not cover
this integrated candidate, production trust, the 2.06 or future firmware.

## Test order for the 1.75

Run one stage at a time, retaining a result before proceeding. The operator
confirms visible behavior; the assistant validates identities, receipts and logs.

### 1. Preserve the working baseline

- [ ] Confirm the same 1.75 (Feifei; enrolled USB serial `28:84:85:3B:67:88`),
  SD card and paired phone; re-discover the actual USB endpoint before writing.
- [ ] Save the current support bundle, installed-map identity and operation
  journal. Preserve the current app data, SD contents and owner credentials.
- [ ] Cold-cycle the **existing** contract-1 Shanghai map on the current image:
  wait for capture to be armed before reconnecting USB, then confirm streets and
  buildings. This provides the before-upgrade baseline.

### 2. Qualify the new development pair

- [ ] Obtain explicit authorization for the named new firmware artifact and app
  install. Use the attested upload-only path after revalidation, never raw pio or
  esptool. Install the matching signed Bicino Dev 1.11 (32) artifact.
- [ ] Verify the running SHA/profile/build and installed app identity separately.
- [ ] First test touch wake and one control, then standalone Map hold/drag/pinch
  and release. Stop if touch fails; do not continue a long transfer test.
- [ ] Open the preserved contract-1 Shanghai map after the firmware change with
  network unavailable. Confirm streets/buildings, drag and no redownload needed.
- [ ] Download a new contract-1 map over Wi-Fi. Require exact installed receipt,
  one library entry and no stuck 99% row; re-open the preserved map as well.
- [ ] Export app and device diagnostics; independently check chunk identities,
  hashes, firmware source, drop counters, touch retry phases and memory reserves.
- [ ] Cold-cycle the candidate with the new map active and confirm persistence.
  Capture a hands-off interval separately from the gesture interval.

### 3. Exact production image and production maps

**The existing Shanghai map is development-signed. Production firmware must
reject that trust key. Do not treat its absence after a production flash as a
compatibility regression, or weaken trust to make this test pass.**

- [ ] Prepare a production-signed contract-1 map using an approved worker and
  compatible app/backend admission record. Production currently admits exact
  build-104 identities; preparing build 105 does not update that admission.
- [ ] Coordinate the production app, catalog and backend approval/deployment
  through their normal reviewed flow before exposing build 105 to users.
  Record the exact worker digest, producer build, app build and firmware SHA.
- [ ] Obtain authorization for the exact `WAVESHARE_AMOLED_175_PRODUCTION`
  artifact; preserve files and pairing. Confirm its flash plan/hash and readback.
- [ ] Collect the **new boot's authenticated `boot/acceptance`** from diagnostics
  with SD available and validate using `tools/verify_firmware_boot_acceptance.py`.
  Production disables serial boot logging; debug serial is not a substitute.
- [ ] Verify production-signed map installation, visible rendering and cold
  persistence on exact production bytes. Verify Dev selects a production-trusted
  catalog copy for this bike; ordinary Bicino stays on production trust.
- [ ] Demonstrate the forward-compatibility case with the same immutable
  contract-1 production map on two supported firmware/app versions: retain and
  open it offline after upgrade, then select/reinstall/redownload it. Record
  both identities. Legacy maps have no newly promised compatibility guarantee.
- [ ] Confirm malformed, unsupported-contract and wrong-key maps fail safely,
  while the previous valid map remains usable. Do not rebuild an old map in place.

### 4. Storage, recovery and endurance gates

- [ ] SD at boot: map installation/rendering and diagnostics use the card.
- [ ] No SD at boot: maps clearly unavailable; bounded FFat diagnostics export
  still completes. Do not format or erase the card to create this case.
- [ ] Insert/remove a card during a session: no live backend switch or FFat map
  access; restart guidance is accurate. Power off before normal card handling;
  deliberate live-removal fault tests require their own controlled fixture.
- [ ] Interrupted download, lost final response, cancel, phone lock/background,
  force-quit/relaunch and reconnect recover without deleting a valid library map,
  duplicating rows or leaving a false 99% transfer.
- [ ] Recovery from a torn primary marker uses the verified backup. Exercise
  reuse/rollback and ambiguous-journal cases with retained fixtures; host fault
  injection does not replace the controlled physical recovery matrix.
- [ ] OTA accept/reject/rollback without SD; never label a debug image or an
  unsigned test payload as a production OTA acceptance.
- [ ] Complete the existing lifecycle matrix: 100 completed sessions per
  qualified board/profile, at least 20 per supported mode; map, firmware and
  diagnostics for ordinary/production, plus debug for remote-debug. Analyze
  complete five-record checkpoints, drops, reserve minima, fragmentation and
  trends. Counts alone do not prove stable memory or safe shutdown.
- [ ] Complete contention, shutdown/commit interruption, repeated recovery and
  at least three FAT32-card gates in
  [Wi-Fi lifecycle qualification](../wifi-lifecycle-resource-qualification.md).
- [ ] Resolve or explicitly record a maintainer disposition for I2C-OBS-001,
  resource/recovery observations and any new failure; preserve prior evidence.

## Gates beyond the 1.75

- [ ] Exact candidate CI: all relevant host/Swift/map checks, app Debug/Release
  container builds and both-board firmware profile matrix. Earlier-head CI does
  not qualify this integration. Keep skipped and blocked checks visible.
- [ ] Separate 2.06 qualification for every affected shipping hardware path.
  The 1.75 operator results do not transfer to the 2.06.
- [ ] Production-compatible app/catalog/backend rollout verified; existing maps
  still usable and new production map installation admitted for the final SHA.
- [ ] Review final merge/tag identity and any changes since candidate testing;
  rebuild/requalify the actual release artifact as required.
- [ ] Recheck increasing published build allocation, protected-main ancestry,
  release controls and signed two-target artifacts. Obtain final release
  authorization; only then use the protected candidate/publisher workflows.

Untested mandatory physical gates stay pending unless the maintainer explicitly
accepts and records the specific residual risk. Such acceptance is not a test
pass and does not make an image factory/golden-qualified.

## Recovery

Stop on a new failure and retain the raw support bundle, operation journal,
artifact manifest and physical observation before retrying. Keep the working
`3ba96a4c` artifact and app-31 evidence as a separately authorized lab recovery
option; a source rollback does not restore app state or qualify an older release.
Do not erase NVS, FFat or SD, rotate trust keys, bypass firmware anti-rollback, or
change production pins to recover a test. Production rollback must follow the
documented increasing-build and coordinated backend approval process.
