# Wi-Fi device operation lifecycle

This implementation follows [planning PR #549](https://github.com/seichris/open-bike-computer/pull/549).
It preserves signed streams, pinned HTTPS, authenticated BLE, the internal-RAM
operation owner, #540 pointer recovery, and the existing renderer/full-refresh
strategy. HTTP upload completion is **not** installation success.

## Implemented contract

### Existing clients and firmware

Map finalization has an implicit irreversible commit grant. The parser must
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

### Versioned map operations (qualification-gated)

`MAP_OPERATIONS_V1_ENABLED` defaults to **0**. Do not enable it in production
without the metadata/downgrade, resource and physical evidence below. Status
advertises `mapOperationsV1: true` only when the feature and device-bound storage
are ready. Absence/false means the conservative legacy contract above.

An operation ID is a random 32-character lowercase hexadecimal UUID representation.
It is separate from the existing signed content session ID. A client persists
intent before entry and sends these additional signed-stream request headers:

- `X-Map-Operation-ID`: operation identity
- `X-Map-Stream-SHA256`: expected exact body digest (64 lowercase hexadecimal)

The firmware independently hashes and validates the body. Same ID plus matching
identity returns the retained state rather than reactivating; conflicting
content/length/session returns conflict. This version uses the implicit grant
after verified preparation; it does not expose a separate commit POST.

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
Immediate read-back is not a FAT/card power-durability guarantee.

Retention fails closed at capacity rather than evicting unresolved/replay
history. An operational acknowledgement/pruning and downgrade process must be
qualified before enabling this finite-capacity experimental contract broadly.
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

## Shutdown

Explicit shutdown/restart is a sticky request processed by a nonblocking main
loop barrier: stop admission, drain granted work/transfer workers and network,
stop renderer/storage-control work, seal diagnostics, then issue the one-shot
power permit. A missing/failed/late ACK or deadline defers shutdown with admission
closed; it never forces deep sleep while late writes may remain. Manual light
suspend is conservatively deferred until a reversible barrier is available.
Automatic lock-managed IDF light sleep remains separate.

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
