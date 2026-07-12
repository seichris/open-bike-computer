# Streaming Map Installation Implementation Plan

## Goal

Remove the long, hot post-upload extraction phase from offline-map installation
without losing background transfer, integrity validation, interruption recovery,
or atomic rollback to the previously active map.

The server already generates the final `.fmb` and `.fmp` files before it creates
the downloadable map pack. The new path should therefore prepare a streamable
artifact in the cloud and have the firmware write each final file exactly once
as that artifact arrives. When the upload finishes, activation should only need
to finalize metadata and switch the active-map pointer.

This plan calls the new path **streaming install v2**. The current retained-ZIP
path remains **archive install v1** until v2 has passed hardware testing and is
widely deployed.

## Why the Current Step 2 Is Slow

The current pack is a `ZIP_STORED` archive. It is not compressed, so the ESP32
is not spending minutes decompressing it. The expensive path is SD-card and
filesystem work:

1. iOS uploads `pack.zip`, which the firmware writes to SD.
2. Firmware scans the ZIP and locates its entries.
3. Firmware reads every map entry from `pack.zip`, hashes it, writes it to a
   second SD-card location, and creates a durable verification receipt.
4. Activation checks thousands of staged files and receipts.
5. Activation moves thousands of files into the inactive installed-map root.
6. Firmware atomically switches `active-map.json` to the new root.

For the Shanghai test this means processing roughly 5,500 small files after the
large upload has already completed. It causes duplicate payload writes, many
small metadata operations, and sustained hashing and SD activity.

Cloud extraction alone would not solve this: the renderer still needs the files
on the device. The device must perform one SD write per final file. The design
goal is to combine that unavoidable write with the incoming background upload
and remove all later full-payload copies and scans.

## Architecture Decision

Use the existing uncompressed ZIP as a single background-upload artifact, but
add a firmware endpoint that parses it while receiving it instead of storing it
as `pack.zip` first.

The selected design is:

- Backend continues producing ordinary, uncompressed ZIP packs.
- Backend makes the archive deterministic and publishes artifact size and
  SHA-256 metadata.
- iOS validates the downloaded pack as it does today.
- iOS uploads `manifest.json` first, then sends the ZIP once through the new
  streaming endpoint using the existing background `URLSession` machinery.
- Firmware parses local ZIP headers incrementally across arbitrary network
  chunk boundaries.
- Firmware writes each verified map entry directly into an inactive installed
  root under `/VECTMAP/.maps/<sessionId>`.
- Firmware hashes each new file while writing it and checkpoints a contiguous
  completed prefix in one compact session journal.
- Firmware never stores a second full `pack.zip` on SD for v2.
- On completion, firmware writes installed metadata and a durable ready marker,
  then atomically changes the active-map pointer.

### Why not use thousands of per-file HTTP requests?

The existing compatibility path can upload individual files, but a Shanghai
pack produces thousands of requests. That increases connection overhead,
weakens background-transfer reliability, and makes interruption recovery more
dependent on the app process. V2 keeps one large background request.

### Why not render directly from ZIP?

The current renderer opens normal paths with POSIX `open`, `fstat`, `read`, and
`close`. Rendering directly from an indexed bundle could remove small files,
but it would require a new storage abstraction throughout the renderer and
careful random-access performance testing. That is a separate, larger map-format
project and is not required to eliminate the current activation bottleneck.

### Why not download a complete FAT filesystem image?

Replacing or mounting a generated filesystem image would couple cloud output to
SD layout and filesystem details, make capacity handling brittle, and increase
the blast radius of a failed install. Versioned inactive directories preserve
the existing rollback model.

## Compatibility Contract

Streaming install must be negotiated. No app or firmware release may assume the
other side has already updated.

Add this field to the full map-transfer HTTP status response:

```json
{
  "mapInstallProtocol": 2,
  "supportedMapInstallProtocols": [1, 2]
}
```

The compact BLE status does not need the protocol list unless it fits within the
existing notification budget. iOS can query HTTP status after joining the
device Wi-Fi and before choosing the upload endpoint.

Selection rules:

- Device advertises v2: iOS uses streaming install.
- Field absent or maximum version is 1: iOS uses the existing `pack.zip` path.
- A v2 request rejected as unsupported before its body starts: iOS may fall back
  to v1 once.
- Integrity, SD, timeout, or partial-write failures must not silently fall back
  to v1; they should remain resumable v2 failures with specific error codes.

The backend archive remains readable by current apps and firmware. Reordering
entries or adding artifact metadata must not invalidate v1 ZIP readers.

## User-Visible Progress

V2 exposes three concise steps across the transfer and activation lifecycle:

1. **Transfer**: receive the ZIP and write verified map files directly into the
   inactive root.
2. **Finalize**: consume the central directory, verify the full stream, close
   the checkpoint, and publish installed metadata.
3. **Activate**: atomically switch the active-map pointer and reload the map.

The iOS Settings row remains:

```text
Status                         Step 1/3 - 50%
```

The device overlay remains in one box:

```text
Map Upload Progress:
Step 1 - 50%
```

V1 continues reporting its existing five activation steps. Step counts are
therefore supplied by the active protocol, not hard-coded in the app.

During Step 1:

- iOS uses background upload bytes for its percentage.
- Firmware uses received request bytes for the device percentage.
- Both values are monotonic and may differ slightly because their observations
  occur on opposite sides of the connection.

## Backend Changes

### 1. Publish artifact metadata

After `write_pack_archive` closes the ZIP, calculate and store:

- `packFormat`: `zip-stored-v1`
- `packBytes`
- `packSha256`
- `mapFileCount`
- `mapPayloadBytes`

Return these fields with the completed job/download metadata. Existing clients
ignore them. If a cached older job lacks them, iOS may calculate the archive
size and SHA-256 locally before transfer.

Do not place the archive SHA inside `manifest.json`; that creates a self-hash
cycle because the manifest is itself an archive entry.

### 2. Make ZIP output deterministic and stream-friendly

Continue requiring:

- `ZIP_STORED` entries only.
- no encryption.
- no data descriptors.
- bounded, safe relative paths.
- one `manifest.json`.
- only declared `.fmb`/`.fmp` map entries plus approved attribution/license
  metadata.

Write entries in this order for newly generated packs:

1. `manifest.json`
2. map entries in the same sorted order as `manifest.files`
3. attribution and license entries

V2 uploads the manifest separately so it can still install existing cached
packs where the manifest appears later. Manifest-first ordering makes new packs
easier to inspect and leaves open a future direct-stream path.

Control ZIP timestamps and metadata so identical inputs produce identical pack
bytes and SHA-256 values. Add a regression test that builds the same fixture
twice and compares bytes.

### 3. Keep download behavior unchanged

The phone remains the internet-facing client. Do not connect the ESP32 directly
to the cloud and do not put backend credentials or public TLS work on the
device. The backend-to-iPhone download and iPhone-to-device local upload remain
separate operations.

## iOS Changes

### 1. Extend pack metadata

Add optional artifact metadata to the job/download models. Continue validating:

- expected `mapId`.
- manifest and archive file lists match exactly.
- every entry size matches.
- every file SHA-256 matches.
- paths are safe and supported.

Compare the locally observed pack size/hash with server metadata when the fields
are present. A mismatch is a server-pack error and must be rejected before
connecting to the device.

### 2. Negotiate the install protocol

After entering map transfer mode and joining the device Wi-Fi:

1. Fetch full map-transfer status.
2. Read `supportedMapInstallProtocols`.
3. Choose v2 when available; otherwise choose v1.
4. Persist the selected protocol with the transfer attempt so app relaunch does
   not reinterpret an in-progress session.

### 3. Begin a v2 session

Before the large background upload:

1. Upload `manifest.json` through the existing authenticated session endpoint.
2. Confirm the device accepted the manifest and expected map ID.
3. Start the background request:

```http
PUT /map-transfer/sessions/<sessionId>/install-stream
X-BikeComputer-Transfer-Token: <token>
X-Map-Pack-SHA256: <hex>
Content-Type: application/zip
Content-Length: <packBytes>
```

Do not load the full archive into `Data`. Continue using an upload-from-file
background task.

### 4. Reconcile without keeping the app open

Once the request body is accepted, the device owns finalization and activation.
The app may be suspended or terminated.

Persist:

- session ID.
- expected map ID.
- local pack URL and identity.
- selected protocol version.
- background task identifier.
- last acknowledged device state.

On foreground/BLE reconnect, reconcile against active map ID, active session,
stream state, and activation sequence. Never label an idle old map as continuing.

### 5. Preserve v1 fallback

Keep the existing background `pack.zip` upload unchanged for firmware that does
not advertise v2. V1 and v2 should share UI presentation and reconciliation,
but their endpoint choice and device state must remain explicit in the model.

## Firmware HTTP Protocol

### `PUT /map-transfer/sessions/<sessionId>/install-stream`

Preconditions:

- authenticated short-lived transfer token.
- map-transfer mode active.
- SD mounted and writable.
- no other activation running.
- valid staged `manifest.json` already accepted for the same session.
- safe session ID and map ID.
- bounded nonzero `Content-Length`.
- valid `X-Map-Pack-SHA256`.

Success response is sent only after the full request was consumed, all new map
entries were hashed and durably closed, the archive hash matched, the completion
marker was persisted, and device-owned activation was queued.

Return stable errors such as:

- `stream_protocol_unsupported`
- `stream_manifest_missing`
- `stream_identity_mismatch`
- `stream_archive_format`
- `stream_archive_truncated`
- `stream_entry_order`
- `stream_entry_duplicate`
- `stream_file_size`
- `stream_file_sha256`
- `stream_archive_sha256`
- `stream_sd_write`
- `stream_checkpoint`
- `stream_busy`

### Status fields

Expose v2 state through HTTP and the compact BLE activation object where space
allows:

```json
{
  "stream": {
    "status": "receiving",
    "sessionId": "...",
    "mapId": "...",
    "receivedBytes": 123,
    "totalBytes": 456,
    "completedFiles": 1200,
    "totalFiles": 5505,
    "sequence": 7
  }
}
```

Allowed status values:

- `idle`
- `receiving`
- `paused`
- `finalizing`
- `ready`
- `activating`
- `installed`
- `failed`

## Firmware Streaming Parser

Implement the ZIP parser as a transport-independent state machine that accepts
arbitrary byte spans. Do not make parsing correctness depend on Wi-Fi packet or
1,024-byte HTTP read boundaries.

Parser states should cover:

- local header fixed fields.
- entry name and extra fields.
- entry body.
- central-directory consumption.
- end-of-central-directory validation.
- complete/error.

For every local entry:

1. Reject encryption, compression, data descriptors, ZIP64, unsafe paths,
   unsupported flags, oversized names/extras, and integer overflow.
2. Require sizes from the local header and ensure they remain inside the HTTP
   body length.
3. For map entries, require an exact manifest declaration and deterministic
   manifest order.
4. Reject missing, duplicate, undeclared, or size-mismatched map entries.
5. Ignore approved metadata bodies after validating their paths and bounds.
6. Hash every received archive byte for final comparison with the request
   header.

Put the parser and its file-sink interface in host-testable code under
`esp32/lib/map_transfer/`; keep Arduino networking in `map_transfer_http`.

## Direct-to-Inactive-Root Installation

V2 must not write into the active map root or first create a complete duplicate
under `.staging`.

Use:

```text
/VECTMAP/.maps/<sessionId>/
  .installing
  .stream-checkpoint
  <final .fmb/.fmp paths>
```

The root is invisible to the renderer until `active-map.json` points to it.
The current active root remains untouched throughout transfer.

For each uncommitted map entry:

1. Write to `<destination>.part`.
2. Hash while writing.
3. Flush and `fsync` the file where supported, then close it.
4. Compare size and SHA-256 with the manifest.
5. Rename `.part` to the final inactive-root path.
6. Advance the in-memory contiguous completed prefix.

Never mark the prefix complete before the corresponding final file rename is
durable.

## Compact Checkpoint and Resume Model

Do not create one 64-byte receipt file per map block in v2. Thousands of receipt
files amplify filesystem metadata work.

Persist one atomic checkpoint containing at least:

```json
{
  "schemaVersion": 1,
  "sessionId": "...",
  "mapId": "...",
  "manifestReceipt": "...",
  "archiveBytes": 123,
  "archiveSha256": "...",
  "completedEntryPrefix": 1200,
  "completedMapBytes": 456,
  "sequence": 7
}
```

Checkpoint policy:

- Update after a bounded batch, initially every 16 files or 1 MiB of newly
  committed payload, whichever occurs first.
- Use the existing atomic temp/backup write strategy.
- Flush immediately before acknowledging the whole stream as complete.
- Files written after the last checkpoint may be safely rewritten after a
  power loss.

Because iOS background uploads restart from byte zero, retry behavior is:

1. Require the retry to use the same manifest receipt, archive size, and archive
   SHA-256.
2. Parse and consume entries from the beginning.
3. For entries before the durable completed prefix, verify destination size and
   skip rewriting their bodies.
4. Continue hashing all incoming archive bytes.
5. Rewrite from the first uncheckpointed entry onward.

A different pack cannot reuse the same checkpoint. It must receive a new
session or explicitly discard the old incomplete session.

## Completion and Atomic Activation

After the final ZIP record is consumed:

1. Confirm the request byte count and archive SHA-256.
2. Confirm every declared map entry was seen and verified.
3. Remove any `.part` files.
4. Write `.manifest.json` and the existing installed-manifest receipt into the
   inactive root.
5. Atomically replace `.installing` with a `.ready` marker bound to the manifest
   receipt and archive identity.
6. Persist the pending activation marker.
7. Return success and queue device-owned activation.
8. Atomically update `active-map.json` to the ready root.
9. Reload the renderer from the newly selected root.
10. Clear pending/checkpoint markers after the new selection is readable.

V2 activation must not rescan or rehash every payload file. Integrity was
established while bytes were received, and the completion marker binds that
verified stream to the exact inactive root. Activation may validate the bounded
manifest, completion marker, root identity, and installed receipt before the
pointer switch.

## Power-Loss Recovery

Recovery rules by interruption point:

### During stream reception

- Old active map remains selected.
- `.installing` and the last atomic checkpoint remain.
- Boot reports the session as `paused`.
- The next matching upload restarts from byte zero and skips the durable prefix.

### After stream completion but before pointer switch

- `.ready` and the pending activation marker remain.
- Boot verifies bounded metadata and completes the pointer switch without
  requiring iOS to stay open.

### During pointer transaction

- Reuse the current activation transaction journal and previous-map fields.
- Boot either completes the new pointer or restores the previous valid pointer.

### After pointer switch but before cleanup

- Boot sees the new active root and treats activation as installed.
- Cleanup removes obsolete staging/checkpoint state later.

An incomplete v2 root must never be considered active merely because its
directory exists.

Update current recovery helpers accordingly:

- Active-root validation for v2 requires installed metadata and the matching
  completion receipt, not only an existing directory.
- Transaction recovery uses the v2 completion receipt instead of rehashing all
  installed files.
- Installed-root pruning preserves the active root, previous rollback root,
  current `.installing` session, and pending `.ready` session.
- Pruning may delete other stale incomplete roots only after confirming they are
  not referenced by the stream checkpoint, pending marker, or activation
  journal.

## Resource and Thermal Controls

The streaming parser must use bounded memory and yield regularly:

- fixed-size I/O buffer; start with 4-16 KiB and benchmark.
- no full archive or full map file in RAM.
- no manifest-proportional allocations beyond the already bounded file list.
- periodic `delay`/task yield during sustained reads and writes.
- progress notification throttling to avoid BLE/UI churn.
- optional short pause between file batches if hardware measurements show a
  useful thermal reduction with acceptable transfer time.

Do not guess a safe temperature threshold. Add a hardware-test measurement for
board/enclosure temperature and compare v2 against the recorded v1 Shanghai
baseline before rollout.

## Implementation Sequence

### Phase 1: Backend metadata and deterministic packs

- Add pack size/hash/file-count fields.
- Make pack entry order and ZIP metadata deterministic.
- Keep all current download URLs and v1 compatibility.
- Add backend fixture and reproducibility tests.

### Phase 2: Host-tested firmware stream parser

- Add incremental ZIP parser and sink interfaces.
- Add malformed-input, chunk-boundary, path, size, duplicate, and hash tests.
- Add direct-to-inactive-root writer behind unit-testable filesystem helpers.
- Do not expose the endpoint yet.

### Phase 3: Firmware checkpoint and activation recovery

- Add compact prefix checkpoint.
- Add `.installing`, `.ready`, and pending activation semantics.
- Reuse the current active-map transaction journal.
- Add boot recovery and pruning rules.
- Add protocol capability/status fields.

### Phase 4: Firmware v2 HTTP endpoint

- Add authenticated `install-stream` handling.
- Connect HTTP chunks to the stream parser.
- Report device progress while receiving.
- Queue activation only after durable completion.
- Retain archive install v1 unchanged.

### Phase 5: iOS negotiation and background upload

- Add protocol negotiation and persisted attempt version.
- Upload manifest first.
- Reuse the background upload coordinator for `install-stream`.
- Show three-step v2 progress.
- Preserve v1 fallback and later BLE reconciliation.

### Phase 6: Hardware benchmark and rollout

- Deploy server changes first.
- Flash v2-capable firmware to developer devices.
- Install the v2-capable app.
- Repeat Shanghai and smaller-map tests.
- Keep v2 developer-scoped until interruption and thermal tests pass.
- Prefer v2 by default only after both Waveshare targets pass.

Each phase should be its own focused commit and should keep both v1 and v2 CI
green. Do not remove v1 extraction in the same change that introduces v2.

## Test Plan

### Backend tests

- Pack is `ZIP_STORED` and uses no data descriptors.
- Manifest is first for new packs.
- Map entry order matches `manifest.files`.
- Identical fixture inputs produce byte-identical archives.
- Published size and SHA-256 match the downloadable bytes.
- Current pack parser still accepts the output.

### Firmware host tests

- Parse a valid stream one byte at a time.
- Parse with randomized chunk boundaries.
- Reject compressed, encrypted, descriptor-based, ZIP64, truncated, oversized,
  duplicate, undeclared, and traversal entries.
- Reject manifest order, size, per-file hash, archive hash, and total-length
  mismatches.
- Preserve completed prefix across restart.
- Reject checkpoint reuse with another manifest/archive.
- Resume without rewriting checkpointed files.
- Safely rewrite uncheckpointed completed files.
- Recover at each transition between installing, ready, pointer transaction,
  installed, and cleanup.
- Never change the active pointer for incomplete or invalid streams.
- Keep all archive install v1 tests passing.

### iOS tests

- Select v2 only when advertised.
- Fall back to v1 when capability is absent.
- Persist the selected protocol across relaunch.
- Upload manifest before starting the stream task.
- Build the v2 URL and headers correctly.
- Reject server metadata/local pack mismatches.
- Continue transfer with the display off.
- Reconcile installed, paused, failed, and old-active-map states correctly.
- Present `Step n/3 - x%` for v2 and retain dynamic v1 step counts.

### Real-device tests

Run on both `WAVESHARE_AMOLED_206` and `WAVESHARE_AMOLED_175`:

- Small map clean install.
- Shanghai-scale map clean install.
- Screen off for the complete background upload.
- Force Wi-Fi loss at approximately 10%, 50%, and 90%, then retry.
- Power off during reception, after completion, during pointer switch, and after
  pointer switch before cleanup.
- Verify the previous map remains usable until the final switch.
- Verify a failed new map never removes the previous map.
- Replug/reboot without losing SD detection or installed-map selection.
- Record total bytes written, time per phase, maximum observed temperature, and
  free SD space before/after.

## Acceptance Criteria

Streaming install v2 is ready to become the default when:

- The iPhone display can remain off throughout transfer.
- The device writes map payload bytes only once; no retained full ZIP is stored
  for v2.
- There is no post-upload full archive extraction or full-file hash pass.
- Activation after the upload consists only of bounded metadata finalization
  and an atomic pointer switch.
- An interrupted upload resumes without rewriting the durable completed prefix.
- Power loss at every tested transition leaves either the previous map or the
  fully verified new map selectable.
- App and device show monotonic, protocol-correct progress.
- V1 app/firmware compatibility remains intact.
- Both Waveshare firmware targets and all existing backend/iOS/host tests pass.
- Shanghai hardware measurements show a material reduction in post-upload time,
  duplicate SD writes, and sustained heat compared with the recorded v1 run.

## Non-Goals

- Direct ESP32 internet downloads.
- Rendering map blocks directly from ZIP.
- Changing `.fmb`/`.fmp` renderer formats.
- Replacing the SD filesystem or repartitioning the card.
- Removing archive install v1 before a measured compatibility rollout.
- Treating cloud-generated hashes as a substitute for device-side validation of
  bytes actually received.
