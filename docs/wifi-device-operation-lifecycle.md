# Wi-Fi device operation lifecycle

This implementation follows [planning PR #549](https://github.com/seichris/open-bike-computer/pull/549).
It preserves signed streams, pinned HTTPS, authenticated BLE, the internal-RAM
operation owner, #540 pointer recovery, and the existing renderer/full-refresh
strategy. HTTP upload completion is **not** installation success.

PSRAM-backed HTTP and renderer workers publish completion only after their
owned cleanup and callouts return, then park. Their internal-stack owner
reclaims the task with `vTaskDeleteWithCaps(worker)` before clearing its handle
or allowing restart/shutdown to finish. Self deletion through
`vTaskDeleteWithCaps(nullptr)` creates an SDK cleanup task with the minimum
stack budget; a privately recovered matching-build bench dump identified that
temporary task as the crashed task. Owner reclamation avoids that extra task
and retains the existing PSRAM worker stacks and renderer architecture.

## Implemented contract

### Existing clients and firmware

Legacy map finalization has an implicit irreversible commit grant. The parser must
verify declared body length, signed manifest, every completed file/hash, and all
counts before requesting the grant. The shared server atomically checks current
authorization, write permission, mode, shutdown admission, and unique ownership.
Revocation first means abort without parser finalization or boot-eligible writes.
Grant first makes the device responsible for completion/recovery. Socket abort,
failed response delivery, duplicate callbacks and token rotation cannot discard
accepted work. The grant lasts through renderer acknowledgement or verified
rollback; uncertain storage disposition keeps the grant, preventing unsafe sleep.

The iOS reconciler requires fresh matching terminal activation. A pointer,
changed map ID, HTTP 200, completed upload or `activating` status is insufficient.
Provisional selection cannot produce a Saved Maps installed check mark.

Legacy transfer records bind only in the BLE connection and app process that
observed the transfer; a device reboot always replaces the connection. After a
reconnect or relaunch, a matching session pointer is not pending: the app polls
only while status reports a live activation of that session, then marks the
result unknown, stops polling and re-enables the Saved Maps transfer button, so
re-sending the same signed stream produces a fresh terminal result. An
unresolved legacy record from an earlier connection or process never blocks
another map.
Even a matching terminal `installed` or `failed` status after that boundary
cannot bind the old record or skip the verifying re-send. A terminal result
remains confirmable in the original observing connection and app process.

While a foreground stream upload is awaiting the OS transport, loss of its
original authenticated BLE binding cancels only that in-memory upload attempt.
Its delegate persists transport completion and releases its network claim before
resuming the caller. This prevents the progress UI waiting for the background
session's six-hour connectivity deadline after a reboot. Cancellation does not
prove whether the device accepted or installed the map; normal fresh-status or
durable-operation reconciliation retains that uncertainty. Restored OS jobs do
not acquire a new foreground connection binding.

### Versioned map operations (qualification-gated)

`MAP_OPERATIONS_V1_ENABLED` defaults to **0**. Do not enable it in production
without the metadata/downgrade, resource and physical evidence below. Status
advertises `mapOperationsV1: true` only when the feature and device-bound storage
are ready. Absence/false means the conservative legacy contract above.

An unresolved durable operation is recovered using its journaled map, session,
artifact and operation identities, even if the last-transfer display summary
still names another map or says `unknown`. Restoring that summary does not
rewrite the operation record or its original observation binding. The client
queries the exact operation and retains its cancellation/commit intent until a
matching device receipt settles admission. Legacy history and another device's
or app's journal cannot acquire this recovery path.

When a fresh exact-operation reply starts foreground query/control recovery,
the background reconciliation poll yields until that recovery finishes. It must
not issue another query that clears the reply before precommit recovery verifies
it or replace the foreground network-connection status.

An unavailable precommit attempt can be retired locally as **unknown**, without
a terminal device receipt, only after fresh pinned HTTP reads return its exact
`result_unavailable` response and a valid admission token for a **different boot
epoch**. The journal must have cancellation intent, no commit intent and no
accepted/terminal receipt. The original epoch/revision and artifact identity are
never refreshed. The old PUT cannot be admitted in the new boot; retirement
does not claim what happened in the previous boot or bind any selected map to it.

The client stops the exact OS upload, requires all active upload tasks to finish,
and verifies fresh empty transfer status in the same authenticated device/BLE
connection after bounded transport cleanup. It atomically saves the unavailable
reply, fresh admission and cleanup observation before releasing admission. A
write failure, same boot epoch, missing/corrupt journal, identity/context change,
unfinished upload or failed cleanup keeps the attempt blocked. Late callbacks
cannot revive retired unknown history; a re-send uses a new operation ID and its
own admission token. Unknown retirement keeps the history for the same bounded
retention period as terminal tombstones and never fabricates an ACK or outcome.

If signed-stream compatibility checks reject a newly admitted operation before
any PUT, the app preserves the specific rejection in the UI and records its
bounded reason in `map.stream_compatibility_rejected`. In the same pinned
device/session it saves cancellation intent and sends the existing exact-identity
cancel request. Only a matching durable terminal receipt permits acknowledgement
and cleanup; a lost response or storage/context change keeps reconciliation
pending while the compatibility error remains visible. This automatic path
cannot cancel a prior upload or commit, or another app's operation.

An operation ID is a random 32-character lowercase hexadecimal UUID representation.
It is separate from the existing signed content session ID. A client persists
intent before entry and sends these additional signed-stream request headers:

- `X-Map-Operation-ID`: operation identity
- `X-Map-Stream-SHA256`: expected exact body digest (64 lowercase hexadecimal)
- `X-Map-Operation-Admission-Epoch`: saved 32-hex boot admission epoch
- `X-Map-Operation-Admission-Revision`: saved unsigned creation revision

The firmware independently hashes and validates the body. Same ID plus matching
identity returns the retained state rather than reactivating; conflicting
content/length/session returns conflict. An operation-aware upload persists only
nonactivatable `.operation-prepared` staging and returns a prepared receipt.
The client persists commit intent, then POSTs
`/map-transfer/operations/<id>/commit` with an empty body, matching
`X-Map-Operation-ID`, and the saved `X-Map-Stream-SHA256`. Only this request may
acquire the grant, persist accepted intent and promote ready/pending metadata.
Known accepted/installed IDs return their retained receipt on retry. A reset
between accepted intent and promotion resumes device-owned completion.

POST `/map-transfer/operations/<id>/cancel` with the same headers cancels
receiving/prepared work; accepted/installed is too late and returns its unchanged
receipt with HTTP 409. A cancellation before manifest admission includes the
full saved artifact identity headers and original admission token, creating a
cancelled record that fences the stopped original upload. See the BLE protocol
for exact headers. Lost prepared/commit/cancel responses are reconciled by exact
ID; legacy uploads without operation headers retain implicit P2 grant behavior.

Authenticated `GET /map-transfer/operations/<id>` and BLE `MOPQ|<id>` query the
same bounded receipt. BLE replies use the existing complete `MSTS` assembly and
an `operation` object. No new BLE UUID or unsigned upload route is introduced.

```json
{
  "schemaVersion": 1,
  "deviceID": "authenticated ownership device ID",
  "operationID": "32 lowercase hexadecimal characters",
  "sessionID": "existing content session",
  "mapID": "logical map ID",
  "manifestReceipt": "64 lowercase hexadecimal characters",
  "signedManifestReceipt": "64 lowercase hexadecimal characters",
  "streamSHA256": "64 lowercase hexadecimal characters",
  "streamBytes": 12345,
  "phase": "accepted",
  "revision": 3
}
```

Phases are `receiving`, `prepared`, `accepted`, `installed`, `failed`, and
`cancelled`. Unknown IDs return `status: result_unavailable` with schema, device
and operation identity. Unknown is not permission to reupload blindly. App
observation/result and network cleanup are independent.

The two-slot bounded/checksummed map journal binds records to authenticated
ownership identity. Accepted intent precedes new `.operation-ready` metadata;
new staging cannot be mistaken for old `.ready` candidates on downgrade. Legacy
records use conservative #540 recovery and do not gain historical authorization
or exact-operation receipt guarantees. Foreign-card operation records cannot
prove success for the new device. Renderer acknowledgement is followed by
storage-worker terminal receipt persistence before installed status publication.
Operation-backed journal/pending/previous-root evidence remains until that receipt;
only then does verified terminal cleanup mark consumed and remove the journal.
A monotonic internal NVS metadata-reader floor is persisted/read back on the
internal operation owner before any operation-backed prepared metadata is written.
Boot also latches existing or foreign operation ledgers before OTA maintenance;
unknown/latch-failed state blocks maintenance admission. The floor never depends
on SD presence during OTA and has no erase/downgrade override. Clean devices with
no new-format history still accept legacy schema-1 releases without mounting SD.
Once floor 1 is recorded, every OTA candidate (including newer build numbers and
developer-requested downgrades) needs a signed reader capability of at least 1.

Release manifests retain the schema-1 signature for old updaters and add
`mapMetadataReaderVersion: 1` plus `mapMetadataReaderSignature`. The additional
P-256 signature covers the canonical schema-2 payload: the same ordered target,
version, build, full Git SHA, image length/SHA, URL and updater protocol, followed
by `mapMetadataReaderVersion`. New iOS verifies and relays both signatures; new
firmware verifies the attestation before using the capability and rechecks the
NVS floor before boot selection. Old manifests and apps cannot assert compatibility
via unsigned fields or build-number comparisons. Incompatible updates fail with
`metadata_reader_incompatible`; physical USB flashing is outside this OTA guard.

Early main boot recovery binds its own installer to the exact read-only
eFuse identity derivation used by ownership, before journal recovery or map
rendering. BLE initialization still performs its normal NVS/authentication
checks; hardware identity alone never authorizes a session. An interrupted
new pointer is recovered against the accepted record before rendering, and
only a fresh renderer ACK can produce its terminal receipt.
Immediate read-back is not a FAT/card power-durability guarantee.

The ledger retains four operation records. A new attempt first requests
`GET /map-transfer/operations/admission`, returning `schemaVersion`, `deviceID`,
`admissionEpoch` and `admissionRevision`. The app persists that token with the new
intent before upload; a retry never refreshes it. The epoch is unpredictable,
128-bit and regenerated each boot. The durable revision increases with each
journal mutation; a serialized in-memory high-water mark rejects same-boot
journal rollback. Known IDs reconcile across boots by their durable identity;
an absent ID needs the exact current epoch/revision to be newly admitted.

After atomically ingesting a terminal receipt, the owner may POST
`/map-transfer/operations/<id>/acknowledge` with an empty body. This converts the
terminal record to a tombstone; it cannot acknowledge accepted/unresolved work.
A later explicit new admission may reuse that slot. Queries of tombstoned or
evicted IDs return `result_unavailable`, and saved stale admission tokens cannot
recreate them. Full unacknowledged history fails closed at capacity. Receipt
writes and acknowledgements are serialized across HTTP and storage-worker
callbacks, avoiding lost updates. Current/previous map roots remain protected;
normal pruning can remove obsolete consumed content after terminal completion.
The metadata/downgrade and physical persistence gates still apply.
OTA continues using its existing SD-independent maintenance/boot acceptance;
map journal records are never used as OTA success evidence.

## iOS ownership and restoration

The app-wide MainActor-isolated registry serializes per-device mode leases and
hotspot configuration ownership. Maps, OTA, diagnostics and remote debug are
exclusive. Root ownership spans entry, upload, confirmation and teardown;
background delegates release only their own claim. Same-SSID devices and late
OS callbacks cannot authorize a successor's configuration removal.

All entry failures use bounded cleanup independent of parent cancellation.
Unresolved remote cleanup survives relaunch and blocks conflicting admission
until fresh authenticated reconciliation. Diagnostics retains phone-reachability
LAN fallback; remote debug may retain LAN when only the browser can reach it.

Versioned app records contain device/operation/artifact, namespace and upload
attempt identity, not credentials. Durable receipt ingestion precedes callback
delivery. Legacy background records remain conservative and are not rebound to
the currently connected board. Relaunch queries the original device; it cannot
promise BLE or polling execution while iOS is force-terminated.

Background upload history serializes each read/modify/persist operation on the
main executor. Readers take an independent defaults snapshot without a shared
store lock. Defaults writes can synchronously notify SwiftUI; holding a store
lock during that callback deadlocks against Saved Maps rendering. A delegate
completion still persists its transport result before returning to the existing
background-event barrier. Duplicate or late start/progress callbacks cannot
revive a completed upload, and this history never substitutes for a device
installation receipt.

## Shutdown

Explicit shutdown/restart is a sticky request processed by a nonblocking main
loop barrier: stop admission, drain granted work/transfer workers and network,
stop renderer/storage-control work, seal diagnostics on an internal-stack task,
flush and unmount the selected storage backend, then issue the one-shot
power permit. A missing/failed/late ACK or deadline defers shutdown with admission
closed; it never forces deep sleep while late writes may remain. Manual light
suspend is conservatively deferred until a reversible barrier is available.
Automatic lock-managed IDF light sleep remains separate.

A terminal deferral emits one UI-thread callback. On a normally initialized
display it shows a preallocated, built-in-font “Shutdown deferred / Leave device
powered on” notice, hides the ordinary screen and overlay layers, and dims the
panel. It performs one refresh, not a timer/event loop; no storage opens or owner
restarts are triggered. Ordinary LVGL/input work stays paused, while a deferred
drain continues servicing operation/renderer completion mailboxes. Later-stage
deferrals retain the visible notice with bounded 50 ms idle polling and the
watchdog heartbeat. Late ACKs do not authorize forced sleep or reset.
Maintenance/early-startup paths without an initialized display do not attempt
unsafe display initialization; RTC and serial retain the failure evidence.

The only existing manual-suspend caller is the legacy non-Arduino-GFX LVGL
`gpioClickEvent`, registered with `POWER_SAVE` in T-Deck and Elecrow profiles.
Neither Waveshare profile registers that callback. This change deliberately
refuses that legacy manual MCU-suspend action too, rather than retain a storage
barrier bypass; implementing a reversible suspend/resume barrier is an explicit
remaining compatibility gate. The button's existing sleep message is replaced
with an unavailable notice so it does not promise entry into sleep.

## Selection metadata power-loss recovery

Two bounded sequence/checksum predecessor anchors retain verified selection
evidence across canonical-pointer and journal cleanup. They preserve the complete
prior selection, never create operation success, and restore only exact verified
content. Current/history retention is bounded to four roots under normal sequential
installs; candidate/staging reservations remain additional. Anchor hashing runs on
the storage owner with real-byte progress and cooperative yielding. See
[the shadow model and original counterexamples](map-metadata-power-loss-model.md)
for exact host coverage and the remaining physical/downgrade limits.

## Validation and release gates

Source, host execution, CI compilation, deployed image, ordinary reboot, and
controlled all-power-removal evidence are distinct. Each final revision needs:

- Portable Swift navigation/lease/operation-store/diagnostics tests and Xcode app build
- Firmware host grant/callback/parser/storage/recovery/shutdown suites
- Ordinary, production and remote-debug 1.75 and 2.06 builds separately
- Real iPhone background/lock/terminate/relaunch, denied/late hotspot apply and two-device races
- 100 repeated all-consumer cycles with internal/DMA/PSRAM/stack/fragmentation measurements
- First/replacement/same-ID map installs and lost-response/reconnect receipt recovery
- Every metadata/receipt/pointer mutation and recovery mutation interrupted before/after,
  with at least three FAT32 cards per board and repeated recovery
- OTA postboot/rollback, diagnostics chunk integrity and browser LAN/debug revocation
- Delayed/poisoned shutdown ACKs and real power-deferred behavior

The current cloud environment cannot establish iPhone/board/card physical gates.
Host fault models do not model every SD controller ordering behavior. No factory
image, hardware acceptance, or production promotion follows from this change.

The planning document's September 30 statement that worldwide signed-map rollout
was closed is historical. Subsequent #546/#548 approvals/promotion remain intact;
this work does not revert existing rollout configuration or grant new rollout
approval. The new operation protocol has its own disabled-by-default gate.

### SD-independent OTA operation receipts (qualification gate)

`FIRMWARE_OPERATIONS_V1_ENABLED` defaults to `0`. No shipping profile enables
this unqualified path. With the gate enabled, owner-authenticated DSTS and
firmware HTTP status include `firmwareOperation` protocol version 1. The record
binds the ownership device ID, random 32-lowercase-hex operation ID, signed image
SHA-256, exact image byte count and inactive partition address. The existing
same-image maintenance reset, fresh BLE owner authentication, pinned HTTPS,
manifest signature/target validation, inactive-slot requirement and actual
post-boot OTA validity checks remain mandatory. There is no SD dependency.

The client saves operation/image/device identity before begin/finalize. A fresh
status provides `admissionEpoch` (random 128-bit per boot) and
`admissionRevision`; begin must echo both with `operationId`. Revision advances
only on durable transitions. Epoch fences requests captured before reboot,
including a namespace reset without ownership reset. Replaying a saved request
cannot acquire a newly emptied store. A client must query an unknown operation,
not preflight the old ID as a new operation. Reconnection credentials and grants
are never written to this receipt store.

After signed bytes and ESP image validation, the internal-stack owner writes
accepted intent under the common commit grant **before** selecting the boot
partition. NVS failure/ambiguous completion cannot select the image. Finalize
response loss is unresolved on the phone, with no automatic exit/cancel or
replacement install. An accepted operation cannot be overwritten. Normal boot
hashes the exact signed byte range before cancelling bootloader rollback, and
only confirmed valid boot can persist `installed`. A return to the old slot
persists `failed` (selection failure and bootloader rollback are deliberately
not distinguished). If terminal receipt persistence fails after bootloader
validity, the usable image stays valid and receipt stays unresolved; a later
boot retries. Status polling performs no NVS writes and never turns readiness
or matching version strings into receipt success.

NVS contains two bounded versioned/checksummed blob slots and one retained
operation. Read/corruption/unknown-schema failure is unavailable, never empty.
There are at most three logical transition writes per successful operation:
accepted, terminal, acknowledged. Failures may require explicit recovery/retry;
there are no byte-progress or polling writes. POST
`/firmware-update/operation/acknowledge` requires a freshly authorized firmware
session and exact `operationId` + `imageSha256`. Only installed/failed results
can become acknowledged tombstones. A new operation then requires the new
revision. iOS keeps the completed identity locally and acknowledges it during
the next maintenance session before admitting a new operation; unknown foreign
or unmatched results cannot be silently acknowledged.

Both gate values compile/run the portable receipt policy fixture. It exercises
lost-response replay, terminal retention, mismatched ACK, pre/post-durable write
failure at all three transitions, repeated reboot recovery, unreadable/corrupt
storage and invalid IDs. Boot source/host tests preserve the actual VALID-state
boundary. Swift cases cover missing/mismatched receipts, different devices,
unauthenticated readiness, accepted-versus-installed, failure and relaunch
persistence. NVS driver power cuts, per-profile firmware builds and iOS execution
remain distinct qualification gates; host fixtures are not physical NVS/OTA
acceptance evidence. Downgrades to receipt-unaware firmware can leave a receipt
unresolved and must not be treated as installed from legacy status alone.
