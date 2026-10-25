# PR #378 isolated Nearby qualification

This is a nonshipping physical test, not a production deployment or a merge.
Use a separate local OrbStack image, data root, installation credentials and
P-256 signing key. Never copy production signing material into the lab.

## Current delivery status — October 25

Latest authorization is **prepare only**: publish the independently verified
physical-feedback/marker repairs, check exact-head CI, then build and retain the
exact clean POI-enabled 175 image for approval. **Do not flash or merge.**
Earlier image approvals do not authorize these new bytes. The PR description
will record the new commit, binary/flash-plan hashes, size and reserve. Dirty
measurements and historical physical observations below are not that approval.
The latest dirty POI measurement was 3,070,032 bytes (10,160 bytes beyond the
full reserve); final clean bytes must be measured independently. Map+Navigation
and mixed-category Nearby behavior require a new physical test after approval.

The following delivery checkpoint is historical:

The user selected this isolated POI profile for the next 175 delivery, after
publishing the verified fixes and checking exact-head CI. This supersedes the
older no-further-flash checkpoint below only for that requested delivery.
It does not authorize different device/profile bytes, a production rollout,
an iPhone installation, or deletion of transfer evidence. Identify the same
1.75-inch device, retain pending transaction evidence if present, rebuild from
the clean published commit and record exact image/flash-plan hashes, then
obtain exact-image/device approval before writing. CI pending or a dirty
build is not a passed delivery gate. Map+Navigation remains undiagnosed.

The R71 repair inventories primary/backup/temporary journal evidence before
legacy fallback: malformed primary bytes cannot hide a foreign signed/durable
backup and cause its deletion. Independent host confirmation preserves both
variants with POIs off/on; orphan-temporary and single-cut liveness remain
covered. This does not claim recovery from arbitrary multi-fault card damage.

Keep dual 3 MiB slots and the full 65,536-byte reserve. The independently
measured uncommitted candidate was 3,068,736 bytes (11,456 beyond reserve);
the clean delivery image must establish its own size/provenance. Earlier
physical observations and maps below do not qualify new bytes.

The public qualification key is compiled only by
`WAVESHARE_AMOLED_175_POI_ISOLATED_LIFECYCLE_QUALIFICATION`. It inherits the enabled-POI
lifecycle profile's production behavior, dual 3 MiB OTA slots and 65,536-byte
reserve. Ordinary, personal, remote-debug, production and release profiles
retain their existing trust sets. The private key remains outside Git.

The matching Bicino Dev qualification build overrides only the public Debug
map-signer build settings; production configuration and credentials are not
changed. Keep the app sandbox and bike ownership intact. Use the existing
server-origin-scoped registration path against the isolated LAN endpoint.

For that Debug build, explicitly pass both `-offlineMap.serverURL` and
`-offlineMap.qualificationOrigin` with the same `.local` origin and port.
The latter enables the normal App Attest enrollment/assertion path for that
one LAN origin only. It does not add a managed host or alter production URL
selection. Release ignores this opt-in; other custom origins retain their
existing behavior. No backend authentication bypass is used.

Map entry has its own 30-second monotonic deadline for the storage checkpoint,
network startup and complete authenticated status response. Partial map mode is
not readiness and cannot extend the deadline. Polls are paced at two seconds;
cancellation, owner/connection fencing, device rejection handling and all secure
session checks remain enforced. This is an iOS-only change: the approved 175
firmware bytes, dual 3 MiB slots and reserve are unchanged. The regression suite
executes the real manager with readiness delayed beyond the former eight-second
cutoff, plus virtual-clock deadline, cancellation and rejection checks.

The physical trial reached a durable Installed receipt while the 175 remained
at activation step 3, 66%, with cleanup pending. Installed is renderer/probe
acknowledgement, not proof of a displayed frame or completed teardown. The
terminal worker now exposes a failed finalizer's first recovery code and current
error without releasing its commit grant. Each report pushes a full BLE status
stream, so after the first failure it reports at most one change every five
seconds, and only when the device's current error differs; alternating storage
failures cannot stream status, and the cleanup code returns after a refused exit
replaced it with `commit_in_progress`. This is diagnostic visibility, not a claimed
repair of the unidentified physical cleanup failure. Obtain the actual recovery
code and preserve the card's transaction/selection/ledger evidence before
claiming a root cause; a generic `commit_in_progress` is not that evidence.

The preserved test card reproduced `operation_cleanup_conflict`: a 1,479-byte
transaction had a 1,024-byte zero prefix while the manifest and all payload
hashes remained valid. This rules out the 2,048-byte limit for that incident;
the original SDK/card corruption mechanism and its timing remain unproven.

Metadata publication now requires checked flush, VFS fsync, close and byte-hash
readback before rename, followed by publication readback. A previous backup is
not discarded until the new publication is verified. A temporary that fails
verification is removed, and a publication that fails readback puts back the
version it replaced (or leaves no file). Primary and backup both survive only
after an interrupted publication, whose primary is the newer version; the next
write drops that stale backup as main did. Refusing there made every later
write of that file fail, which latched activations and pointer recovery.
Fsync and immediate readback do not prove arbitrary card power-loss durability.

Terminal recovery inventories primary, backup and temporary journals. Only an
exact same-device Installed ledger receipt, matching ready/selected identities,
verified selected payloads and no conflicting Accepted operation can retire a
corrupt journal; a legacy archive predecessor does not block retirement.
Original bytes remain until a synced, verified quarantine copy exists. Four
bounded 4-KiB quarantine slots retain failure evidence; a full or conflicting
archive stays unresolved rather than overwriting older evidence.
An interrupted copy can retry its own slot without consuming another slot.

A temporary-only journal was never published. Activation writes its journal
before any other mutation, so such bytes carry no committed state; recovery
removes them as main did, and the ledger, ready identity and pending intent
resume the work. Treating them as interrupted state left a single power cut
after the temporary's creation unrecoverable without SD repair. Journal bytes
with signed or durable evidence (receipts, operation ID, ledger or operation
markers) still need a verified owner; other unreadable bytes keep main's legacy
recovery, which verifies or rolls back the selection and clears the journal.
Transaction readers share a bounded 4-KiB limit for valid larger metadata.

Regression gates include silent temporary/publication corruption, stale and
retried backups, a single power cut at every activation mutation (legacy and
durable, POSIX and FAT) followed by recovery and another activation, quarantine
copy/readback failures and cuts, partial cleanup, bounded-capacity retry,
missing/corrupt ledger/ready/selection, non-NUL header corruption, legacy
predecessors, and public activation/pending routes with temporary-only
journals. Keep the existing stack, reserve and power-loss gates unchanged.

Qualification gates:

1. Identify the connected 175 and iPhone; record the exact source, public-key
   fingerprint, worker content identity, app build and firmware image hashes.
2. Generate real OSM target-5 data covering the rider's requested area, using
   the repository extractor and signed-stream writer. Retain the source hash,
   category/coverage counts and encoded-POI validation. No invented POIs.
3. Prove production/default trust rejects the qualification signer and the
   explicit qualification profile accepts it; retain signature verification.
4. Build through the locked helpers. Require the unchanged firmware reserve
   and explicit approval of the exact image/device before flashing.
5. Download through the isolated service, transfer from the real iPhone using
   the authenticated device flow, and verify target-5 activation on the 175.
6. On the real 175, select one category, then several; observe actual nearby
   results, category icons, distances, direction/edge indicators and return to
   Categories. Distinguish operator observations from retained device evidence.
7. Check repeat search, freshness/disconnection behavior and persistence where
   safely measurable. Do not invent movement or cold-start evidence. Record
   remaining gates explicitly; 206 is a separate, untested board.

Existing maps are preserved. This test does not promote the local image,
change the live production/development services, waive rollout gates, relax
signature verification or enable POIs in shipping firmware.

## Physical feedback and next candidate (24 October 2026)

The user observed the recovered map render on the 175, disappearance of the
step-3/66% overlay, successful single-category Nearby results, and successful
two-category results with a working return/repeat flow. This is operator
evidence, not complete retained firmware acquisition or framebuffer proof.

A distinct isolated map download succeeded, but its fresh upload returned HTTP
503 `operation_prepare` before commit. The phone's cached Receiving receipt
predates that response and cannot establish the current on-card ledger phase.
Do not retry, reboot or replace the image to infer a result. Preserve the raw
ledger slots and preparation/manifest/checkpoint variants, then reconcile the
exact operation. Two diagnostics acquisitions failed `missing_session` before
inventory delivery. The phone was detached for the user's absence; hardware
interaction is stopped. Fresh-install acceptance remains open.

The next UI candidate implements the requested black picker, transparent fields,
selected-only borders (no checkboxes), larger category-specific symbols, and no
direct-distance explanatory text. The map has no Categories button: either
hardware short press returns to the picker, with normal cycling from the picker
and pairing/long-press behavior unchanged. POIs use the actual displayed canvas
position, pivot, scale and rotation throughout drag and settlement. A fresh
stationary fix clears a latched stale warning by refreshing the query, without
widening the source-freshness horizon or treating a retained blue dot as a fix.

Give test artifacts distinct visible names through the app when the phone
returns: `Nearby 00 - Old Build`, `Nearby 01 - Recovery`, and
`Nearby 02 - Fresh Install`. Do not rename unrelated user maps or claim these
labels were applied while the phone is detached. A newly built image requires
its own exact-image approval and physical validation; no further flash is
authorized by the earlier 17138063 approval.
