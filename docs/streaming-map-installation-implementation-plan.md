# Streaming Map Installation Implementation Plan

## Goal

Replace the slow retained-ZIP activation path with the long-term production map
installation architecture:

- the cloud produces a signed, deterministic, device-native map stream;
- iOS downloads and validates that stream, then transfers it in one background
  upload;
- firmware writes every final map byte exactly once into an inactive map root;
- firmware calculates each file's SHA-256 during that unavoidable write;
- interruption recovery uses one compact durable checkpoint;
- activation finalizes bounded metadata and atomically switches the active-map
  pointer;
- the previous map remains usable until the new map is completely verified.

There must be no later archive scan, extraction copy, second device hash pass,
mass move of staged files, screen-on dependency, or generic activation timeout.

The new path is **map install protocol v2**. The merged retained-ZIP path remains
**protocol v1** only for compatibility during a measured rollout.

## Implementation Status

Status as of 2026-07-12:

- Protocol v1 recovery, background archive upload, five-step progress, durable
  activation state, and atomic active-map selection are merged on `main` through
  PR #54.
- Protocol v2 implementation is in progress on PR #55. Phase 1 freezes the
  signed stream contract and cross-language vectors; Phase 2 adds deterministic
  production signing, dual artifacts, content-addressed filesystem/S3 storage,
  persisted artifact metadata, stable errors/metrics, retention-safe publication
  leases, bounded out-of-process garbage collection, stateless
  installation-bound authorization, and identity-bound URL refresh.
- Phase 3 adds the host-tested transport-independent firmware parser, exact-byte
  P-256 trust verification with rotation support, hardware-backed SHA-256,
  canonical UTF-8 manifest validation, checked PSRAM ownership, and compact
  Shanghai-scale file descriptors.
- Phase 4 adds the direct inactive-root writer, one compact receipt-bound
  checkpoint, exact-size retry skipping, atomic ready/pending/active journals,
  consumed-intent replay protection, current/previous-root rollback identity,
  metadata-only activation, bounded-memory filesystem enumeration, three-step
  progress, stable recovery states, and fault-injected crash-boundary coverage.
  The host suite, ASan/UBSan, and both Waveshare firmware builds pass. Protocol
  v2 remains unadvertised until the Phase 5 HTTP and Phase 6 iOS paths are
  complete.
- No production capability should advertise v2 until the signed stream parser,
  one-pass writer, checkpoint recovery, and pointer transaction all exist and
  pass the acceptance gate below.

## Non-Negotiable Long-Term Requirements

This is not an MVP design. Every implementation phase must contribute directly
to the final production architecture.

- Use a versioned device-native stream, not ZIP with device-side extraction.
- Authenticate cloud-generated map metadata with a server signature.
- Verify each map file once on the device as it is written.
- Do not also hash the entire stream on the device.
- Never write a full temporary archive to the SD card in v2.
- Never create thousands of receipt files.
- Never move thousands of completed files during activation.
- Make upload, checkpoint, finalization, and pointer recovery power-loss safe.
- Keep the old active map untouched until the final atomic switch.
- Support both Waveshare firmware targets from the start.
- Preserve background upload when iOS is suspended or the display is off.
- Negotiate protocol versions and retain v1 compatibility until telemetry and
  hardware tests show that it is safe to retire.
- Use stable error codes, structured state, and phase timings instead of relying
  on fixed waits.
- Do not add an unsigned production mode, a foreground-only fallback, or a
  device-specific shortcut that would later need replacement.

## Why the Current Five Steps Are Not Fundamental

The current pack is `ZIP_STORED`; it is not compressed. The expensive work is
caused by the retained-archive layout:

1. Scan ZIP headers.
2. Read every entry from the ZIP, hash it, and write it elsewhere on SD.
3. Validate thousands of staged files and receipts.
4. Move thousands of files into an installed root.
5. Switch the active-map pointer.

Only two safety properties are fundamental:

1. The complete new map must be durably written and match authenticated
   metadata.
2. Selecting the new map must be atomic and recoverable.

Protocol v2 presents three concise user-visible steps:

1. Transfer and verify.
2. Finalize installed metadata.
3. Activate the new map.

Internally, the state machine is more precise, but those internal states do not
need to become user-facing steps.

## Final Architecture Decision

Create a purpose-built **Bike Map Stream** artifact with extension `.bmap` and
media type:

```text
application/vnd.openbikecomputer.map-stream
```

The stream contains:

1. a small fixed binary header;
2. the canonical map manifest bytes;
3. a signature envelope for those exact manifest bytes;
4. the raw `.fmb`/`.fmp` payloads concatenated in manifest order.

The manifest already declares each path, size, and SHA-256. Therefore the
payload needs no repeated filenames, per-entry headers, central directory, or
trailer. Firmware reads the signed manifest first, then knows exactly how many
bytes belong to each destination file.

This format is intentionally simpler than ZIP and simpler than a generic custom
archive. It contains only what safe streaming installation requires.

### Why not keep ZIP for v2?

Using the existing uncompressed ZIP would reduce migration work, but it would
make firmware permanently support ZIP flags, local headers, extras, central
directories, truncation rules, and format variants that provide no value to the
renderer. It would also require either a preliminary manifest upload or a
manifest-first ZIP convention.

A device-native stream gives firmware a smaller parser, fewer attack surfaces,
deterministic ordering, immediate access to authenticated metadata, and a stable
format that can be shared by backend, iOS, and host-test fixtures.

### Why not upload thousands of files separately?

Per-file HTTP requests add connection overhead, interact poorly with iOS
background execution, and make completion dependent on app orchestration. A
single file-backed background request is the correct transport unit.

### Why not render directly from one bundle?

The current renderer opens individual paths with POSIX file APIs. A permanent
random-access map bundle may be worth a future renderer project, but it would
change runtime map I/O and performance characteristics. V2 removes installation
duplication without coupling that work to a renderer rewrite.

## Bike Map Stream Format v1

Map install protocol v2 initially carries Bike Map Stream format v1. Protocol
and artifact versions are separate so transport/recovery can evolve without
silently changing artifact parsing.

The normative byte-level source of truth is
[`map-stream-format-v1.md`](map-stream-format-v1.md). This section records the
architectural rationale and must remain consistent with that specification.

All integers are unsigned little-endian. The fixed header contains:

| Field | Width | Requirement |
| --- | ---: | --- |
| Magic | 8 bytes | ASCII `BIKEMAP1` |
| Format version | 2 bytes | `1` |
| Header flags | 2 bytes | `0`; reject unknown required flags |
| Manifest length | 4 bytes | Nonzero and within the firmware limit |
| Signature envelope length | 2 bytes | Nonzero and bounded |
| Reserved | 2 bytes | Must be zero |
| File count | 4 bytes | Must equal `manifest.files.count` |
| Payload byte count | 8 bytes | Must equal the sum of manifest file sizes |

Immediately following the fixed header:

```text
canonical manifest JSON bytes
signature envelope bytes
file 0 payload
file 1 payload
...
file N-1 payload
```

The HTTP `Content-Length` must equal:

```text
fixed header bytes
+ manifest length
+ signature envelope length
+ payload byte count
```

Reject trailing data as well as truncation.

### Canonical manifest

Define canonical JSON once in the backend and provide cross-language golden
fixtures. At minimum:

- UTF-8;
- sorted object keys;
- no insignificant whitespace;
- deterministic number and string encoding;
- no trailing newline;
- stable file ordering by normalized relative path.

The existing manifest semantics remain:

- stable map ID;
- renderer and format compatibility;
- geographic bounds and source attribution;
- file path, publish path, byte count, and SHA-256 for every map file;
- pipeline provenance and minimum firmware requirements.

Paths remain restricted to the supported `VECTMAP/<mapId>/...fm[bp]` shape.
The stream contains file payloads in exactly the order declared by
`manifest.files`; there is no second source of truth for ordering or size.

### Signature envelope

Use a dedicated P-256 map-artifact signing key, RFC 6979 deterministic nonces,
and domain-separated signatures. Do not reuse the firmware release private key
even if verification code is shared. Deterministic signing is required so the
same canonical inputs and signing key produce byte-identical artifacts.

Sign:

```text
"open-bike-computer-map-manifest-v1\0" || canonicalManifestBytes
```

The envelope is binary rather than JSON/base64/DER:

| Field | Width | Requirement |
| --- | ---: | --- |
| Algorithm ID | 1 byte | `1` = P-256/SHA-256 |
| Key ID length | 1 byte | Nonzero and bounded |
| Signature length | 2 bytes | `64` |
| Key ID | Variable | Restricted ASCII identifier |
| Signature | 64 bytes | Fixed-width big-endian `r || s` |

The signer uses RFC 6979, but verifiers only need standard P-256/SHA-256
verification after converting the fixed-width signature to the representation
required by their crypto library.

iOS and firmware contain a small trust store keyed by `keyId`. Key rotation is
an explicit rollout:

1. ship the new public key to app and firmware;
2. begin signing with the new key after adoption;
3. retain the previous verification key during the compatibility window;
4. remove an old key only after artifacts signed by it no longer need transfer.

The backend private key is supplied through production secret management and is
never committed, returned by an API, or stored in generated job directories.

### Artifact identity

Calculate two identities:

- `manifestReceipt`: SHA-256 of the exact canonical manifest bytes;
- `signedManifestReceipt`: SHA-256 of the signature domain, canonical manifest
  bytes, and exact binary signature-envelope bytes.

Firmware checkpoints and transfer sessions bind to `signedManifestReceipt` so
the signing key and signature are part of the resumable identity. The manifest
receipt remains useful for comparing equivalent map content across resigning or
key rotation.

The backend also publishes the complete `.bmap` SHA-256 for iOS cache and
download verification. The ESP32 does not calculate that whole-artifact hash:

- signature verification authenticates the manifest and all declared hashes;
- per-file SHA-256 verifies every map byte actually written to SD;
- format parsing and exact `Content-Length` verify structure and completeness;
- avoiding a whole-stream SHA removes a duplicate hash calculation over the
  same payload bytes.

## End-to-End Flow

1. Backend generates final `.fmb`/`.fmp` files.
2. Backend creates canonical manifest bytes.
3. Backend signs those exact bytes with the active map signing key.
4. Backend writes the `.bmap` header, manifest, signature envelope, and payloads
   in one deterministic pass.
5. Backend stores the immutable artifact in durable object storage using a
   content-addressed key.
6. Backend returns signed artifact metadata and a stable download URL.
7. iOS downloads `.bmap` and verifies artifact size/SHA-256, manifest signature,
   manifest constraints, and every file hash.
8. iOS persists the verified artifact and its manifest receipt as a saved map.
9. When the user chooses Upload, iOS enters authenticated map-transfer mode and
   joins the device Wi-Fi.
10. iOS queries full HTTP status and negotiates protocol v2.
11. iOS uploads the unchanged `.bmap` file in one background `URLSession` task.
12. Firmware parses and authenticates the header/manifest before accepting map
   payloads into an inactive root.
13. Firmware writes and hashes each file once, checkpointing durable progress.
14. Firmware finalizes installed metadata and a ready marker.
15. Firmware atomically switches the active-map pointer and reloads the map.
16. iOS later reconciles the active map over BLE; it need not remain open during
   steps 11-15.

## Backend Plan

### Generate both production artifacts during migration

For each completed map job, publish:

- canonical v2 `.bmap` artifact;
- legacy v1 `.zip` artifact while compatibility requires it.

Both artifacts derive from the same final map files and manifest semantics.
The v2 artifact is canonical for new apps. The ZIP is a compatibility product,
not the basis of the new architecture.

### Durable artifact storage

Move completed artifacts and their metadata to durable object storage rather
than relying on process-local job directories. Use content-addressed object keys
based on map ID, signed manifest receipt, artifact format, and signing key ID.

The completed job response exposes an artifact list rather than one implicit
pack URL:

```json
{
  "artifacts": [
    {
      "format": "bike-map-stream-v1",
      "url": "https://.../map.bmap",
      "bytes": 123,
      "sha256": "...",
      "manifestReceipt": "...",
      "signedManifestReceipt": "...",
      "signatureKeyId": "map-prod-2026-01"
    },
    {
      "format": "zip-stored-v1",
      "url": "https://.../map.zip",
      "bytes": 456,
      "sha256": "..."
    }
  ]
}
```

Artifact URLs may be signed and time-limited, but artifact identity and recovery
must not depend on one expired URL. The app can request a refreshed URL for the
same immutable artifact identity.

### Signing service boundaries

- Keep canonicalization and format serialization in a deterministic library.
- Keep private-key access in a narrow signing adapter.
- Fail the job if production signing is unavailable; do not emit unsigned v2
  artifacts.
- Allow explicit test keys only in tests and local development environments.
- Log key ID and manifest receipt, never private key material.
- Include golden fixtures created by a fixed test key for Python, Swift, and C++
  verification tests.

### Backend observability

Record:

- file count and payload bytes;
- canonicalization, hashing, signing, and artifact-write timings;
- artifact format/version and signing key ID;
- object storage key and checksum;
- stable error code for generation/signing/storage failures.

## iOS Plan

### Saved map model

Make saved maps artifact-aware. Persist:

- map ID and user-editable display name separately;
- artifact format/version;
- manifest receipt;
- signed manifest receipt;
- local artifact URL;
- artifact bytes and SHA-256;
- signature key ID;
- server artifact identity for URL refresh;
- last transfer protocol/session/outcome.

Renaming a map never rewrites or invalidates the signed artifact.

New jobs download and store `.bmap` as their canonical local artifact. Existing
saved ZIP maps continue using v1; they are not silently converted into unsigned
v2 artifacts.

### Validation

Add a streaming `.bmap` reader that never loads the full artifact or a full map
file into memory. It verifies:

- fixed header and exact length;
- supported format version and flags;
- bounded manifest and signature envelope;
- canonical manifest receipt;
- signed manifest receipt and signing key identity;
- P-256 signature and trusted key ID;
- expected map ID and renderer compatibility;
- safe paths, unique paths, file count, and summed sizes;
- every file SHA-256;
- no trailing bytes.

Return a typed verified-artifact value. Upload APIs accept that type rather than
an arbitrary file URL, preventing unvalidated files from entering the transfer
path accidentally.

### Protocol negotiation

After entering transfer mode and joining device Wi-Fi, request full HTTP status:

```json
{
  "mapInstallProtocol": 2,
  "supportedMapInstallProtocols": [1, 2],
  "supportedMapStreamFormats": [1]
}
```

Choose v2 only when both protocol and stream format are supported. Otherwise:

- existing saved ZIP: use v1 directly;
- new map with durable legacy artifact: fetch and verify that artifact, then use
  v1;
- no compatible artifact available: explain the firmware compatibility issue
  rather than attempting an unsafe conversion.

Persist the selected protocol with the attempt so app relaunch cannot reinterpret
an in-progress session.

### Background upload

Use one authenticated file-backed background request:

```http
PUT /map-transfer/sessions/<sessionId>/install-stream
X-BikeComputer-Transfer-Token: <token>
Content-Type: application/vnd.openbikecomputer.map-stream
Content-Length: <artifactBytes>
```

Do not put the manifest or hash in caller-controlled HTTP headers as a trust
boundary. Firmware derives authenticated metadata from the signed stream.

The existing background-upload coordinator owns progress, task restoration, and
completion delivery. Once the request begins, firmware owns finalization and
activation; iOS suspension or termination does not stop device work after bytes
have arrived.

### Reconciliation

Persist and reconcile:

- map ID;
- manifest receipt;
- signed manifest receipt;
- session ID;
- transfer protocol and stream format;
- background task identifier;
- last device sequence/state;
- expected active-map identity.

On foreground or BLE reconnect, report installed, receiving, paused, finalizing,
activating, failed, or idle-on-another-map accurately. Never turn an idle old map
into “activation continues on device.”

## Firmware Plan

### Protocol capability

Advertise v2 only when all production pieces are compiled in:

- signed manifest verification;
- stream parser v1;
- direct-to-inactive-root writer;
- durable checkpoint/recovery;
- atomic ready/pointer transaction.

There is no partially enabled v2 mode.

### Incremental stream parser

Create a transport-independent parser under `esp32/lib/map_transfer/`. It
accepts arbitrary byte spans and must not depend on TCP packet or HTTP buffer
boundaries.

States include:

- fixed header;
- manifest body;
- signature envelope;
- signature verification;
- current file payload;
- final length verification;
- complete/error.

Before writing payload bytes, validate:

- magic, format version, flags, reserved fields, and integer arithmetic;
- exact HTTP/body length;
- manifest/signature bounds;
- trusted signature algorithm and key ID;
- signature over the exact manifest bytes;
- map ID, renderer, firmware compatibility, path safety, uniqueness, file count,
  individual sizes, total payload size, and SHA-256 syntax.

Put parsing and sink behavior behind host-testable interfaces. Networking only
feeds bytes and receives structured status/errors.

### One-pass hashing

For every new file:

1. Open `<destination>.part` in the inactive root.
2. Feed each incoming payload span to one SHA-256 context.
3. Write the same span once to SD.
4. Yield according to a measured scheduling policy.
5. At the declared boundary, flush and `fsync` where supported.
6. Finalize SHA-256 and compare it with the authenticated manifest value.
7. Close and rename `.part` to the final inactive path.
8. Advance checkpoint state only after durable completion.

Do not hash that file again during finalization, activation, normal boot, or
retry of a checkpointed prefix.

Use the ESP-IDF/mbedTLS hardware-accelerated SHA-256 implementation on device,
with a portable implementation behind the same interface for host tests. Do not
retain a slower custom software SHA implementation on production hardware merely
because it is convenient for unit tests.

### Direct inactive root

Write v2 files directly to:

```text
/VECTMAP/.maps/<sessionId>/
  .installing
  .stream-checkpoint
  <final .fmb/.fmp files>
```

The active map points elsewhere throughout reception. There is no complete
duplicate under `.staging`, and activation does not move map payload files.

### Compact checkpoint

Use one atomic, versioned checkpoint instead of per-file receipt files:

```json
{
  "schemaVersion": 1,
  "protocolVersion": 2,
  "streamFormatVersion": 1,
  "sessionId": "...",
  "mapId": "...",
  "manifestReceipt": "...",
  "signedManifestReceipt": "...",
  "completedFilePrefix": 1200,
  "completedPayloadBytes": 456,
  "totalFiles": 5505,
  "totalPayloadBytes": 789,
  "sequence": 7
}
```

The completed prefix is valid only for the exact `signedManifestReceipt`. A
different artifact, signature, signing key, or map cannot reuse it.

Checkpoint according to a wear-aware policy expressed in both bytes and time,
not once per file. Start from measured SD behavior and choose a maximum amount of
rework after power loss. Checkpoint updates use the existing atomic temp/backup
pattern and are flushed before the HTTP request is acknowledged as complete.

### Retry behavior

iOS background uploads may restart the request at byte zero. Firmware:

1. parses and authenticates the stream again;
2. requires the same signed manifest receipt;
3. consumes payloads before the durable prefix without rewriting or rehashing
   their stored files;
4. confirms checkpointed destination sizes;
5. rewrites from the first uncheckpointed file onward;
6. removes any stale `.part` file before rewriting it.

Files completed after the last checkpoint may be rewritten. Files inside the
durable prefix are never rewritten merely because the network upload restarted.

### Finalization and activation

After the last declared payload byte:

1. Confirm exact body length and that every declared file completed.
2. Remove stale `.part` files.
3. Write `.manifest.json` from the authenticated manifest bytes.
4. Write the existing installed-manifest receipt.
5. Write a signed-manifest-bound `.ready` marker atomically.
6. Persist the pending activation marker.
7. Acknowledge the completed HTTP request and queue device-owned activation.
8. Reuse the current activation transaction journal to update `active-map.json`.
9. Reload the renderer from the new root.
10. Clear pending/checkpoint state only after the active selection is readable.

Activation validates bounded metadata and receipts only. It does not scan the
stream, hash map files, or move map payloads.

### Power-loss recovery

During transfer:

- old active map remains selected;
- `.installing` and the last checkpoint remain;
- boot reports the v2 session as paused;
- the next matching upload resumes from the durable prefix.

After `.ready` but before pointer switch:

- pending activation remains device-owned;
- boot verifies authenticated bounded metadata and completes the pointer
  transaction without iOS.

During pointer transaction:

- reuse previous-map fields and transaction phases;
- boot completes the new selection or restores the previous valid selection.

After pointer switch but before cleanup:

- boot recognizes the new root as installed;
- cleanup is retried without rolling back a readable new map.

Update pruning and root validation so directory existence alone never makes an
incomplete v2 root active. Preserve roots referenced by active, previous,
installing, ready, pending, or transaction state.

## Progress and UX Contract

V2 uses three dynamic steps:

| Step | Firmware state | Percentage source |
| --- | --- | --- |
| 1 | Receiving, writing, and verifying | Consumed payload bytes |
| 2 | Finalizing metadata and ready marker | Bounded finalization operations |
| 3 | Pointer transaction and map reload | Transaction milestones |

iOS Settings:

```text
Status                         Step 1/3 - 50%
```

Device overlay:

```text
Map Upload Progress:
Step 1 - 50%
```

Expose structured state and monotonic counters over HTTP and BLE. The UI derives
labels from protocol state; firmware does not send user-facing English strings.

There is no 600-second failure boundary. If progress stops, status retains the
last structured phase and timestamp. After disconnect/reboot, reconciliation
reports receiving, paused, ready, activating, installed, failed, or idle based
on durable device state.

## Security Model

- BLE authentication gates entry into transfer mode.
- A short-lived session token authorizes local HTTP requests.
- The server signs exact canonical manifest bytes with a dedicated P-256 key.
- iOS verifies the signature before offering/uploading the artifact.
- Firmware independently verifies the same signature before writing payloads.
- Firmware validates all paths, counts, sizes, sums, versions, and integer
  operations before use.
- Every file hash is authenticated by the signed manifest and checked against
  bytes written to SD.
- The active map changes only after every file and completion marker succeeds.
- Invalid signatures, unknown production key IDs, or malformed streams are hard
  failures and never fall back to v1 automatically.
- Legacy v1 remains available only through explicit capability selection, not as
  an integrity-error escape hatch.

Map data is not executable firmware, but it is parsed by privileged device code.
Authenticating it is part of reducing the renderer's untrusted-input surface.

## Resource, Performance, and Thermal Design

- Fixed-size streaming buffers; benchmark 4, 8, and 16 KiB on both targets.
- No full artifact or full map file in RAM.
- Bound manifest bytes, file count, path length, payload bytes, and nesting.
- Hardware-accelerated SHA-256 on ESP32.
- Progress notification throttling independent from hashing/write loops.
- Explicit task yields based on measured UI/BLE responsiveness.
- One payload write per map byte.
- One SHA-256 calculation per map byte on device.
- One compact checkpoint journal, updated with a measured wear/rework policy.
- No retained `.bmap` on SD, thousands of receipts, or activation moves.

Instrument time spent in network reads, SD writes, SHA, flush/rename,
checkpointing, metadata finalization, pointer transaction, and renderer reload.
Do not remove integrity checks based on total Step 1 duration without measuring
which component is actually dominant.

For hardware validation, record external board/enclosure temperature rather than
guessing a safe value from internal chip readings. Define rollout thresholds
from component limits and measured v1/v2 behavior before enabling v2 generally.

## Observability

Expose and log stable fields:

- protocol and stream format version;
- state and sequence;
- session ID, map ID, and signed manifest receipt prefix;
- received/total stream bytes;
- completed/total payload bytes;
- completed/total files;
- last durable checkpoint prefix;
- phase timing counters;
- bytes written and bytes skipped on retry;
- stable error code and bounded message.

Do not log transfer tokens, complete signatures, full manifests, or private data
that is not needed for diagnosis.

## Compatibility and Rollout

### Server first

- Deploy deterministic `.bmap` generation, signing, durable storage, and
  artifact-list APIs.
- Continue generating v1 ZIP artifacts.
- Existing apps ignore the new artifact.

### Firmware second

- Add full v2 parser, signature verification, writer, checkpoint, recovery, and
  endpoint behind capability advertisement.
- Do not advertise v2 until every component initializes successfully.
- Keep v1 unchanged.

### iOS third

- Add `.bmap` download, validation, saved-map persistence, negotiation,
  background upload, and reconciliation.
- Prefer v2 only when device protocol and format capabilities match.
- Preserve existing ZIP maps and v1 device support.

### Measured promotion

- Developer devices first.
- Both Waveshare targets and interruption matrix.
- Shanghai-scale repeated installs and smaller regression maps.
- Compare timings, SD writes, retry behavior, and thermal measurements.
- Enable v2 by default only after acceptance criteria pass repeatedly.
- Retire v1 artifact generation only after supported app/firmware adoption and a
  defined rollback window; removal is a separate decision and PR.

## Implementation Sequence

Every phase lands production-quality code and permanent tests; there is no
throwaway MVP parser or unsigned interim protocol.

### Phase 1: Specification and golden vectors

- Freeze canonical JSON, binary header, signature domain, and limits.
- Generate fixed test-key valid/invalid artifacts.
- Add Python, Swift, and C++ readers for golden-vector agreement.
- Document versioning and key rotation.

### Phase 2: Backend artifact and trust pipeline

- Add signing-key adapter and production secret wiring.
- Add deterministic `.bmap` writer and artifact checksums.
- Add durable content-addressed object storage.
- Return artifact list and URL refresh identity.
- Keep ZIP generation and existing APIs compatible.

### Phase 3: Firmware parser and crypto

- Add host-tested incremental parser.
- Add P-256 verification trust store and rotation support.
- Add hardware-backed SHA abstraction.
- Add all malformed-input and limit tests.

### Phase 4: Firmware installation state machine

- Add direct inactive-root writer.
- Add compact checkpoint and retry skip behavior.
- Add ready marker, recovery, pruning, and transaction integration.
- Add v2 status/progress and stable errors.
- Keep capability disabled until the complete state machine is present.

### Phase 5: Firmware HTTP integration

- Add authenticated `install-stream` endpoint.
- Feed network chunks into the parser/writer without transport assumptions.
- Restore device-owned finalization after request completion or reboot.
- Advertise v2 only after initialization and SD capability checks.

### Phase 6: iOS artifact and transfer path

- Add artifact-aware saved-map model.
- Add streaming validation and trust store.
- Add capability negotiation and v2 background upload.
- Add persisted recovery/reconciliation and dynamic three-step UX.
- Preserve v1 explicitly.

### Phase 7: Hardware validation and rollout controls

- Run full interruption, power-loss, screen-off, compatibility, and thermal
  tests on both targets.
- Add measured feature rollout control if staged enablement is needed.
- Document operational key rotation and artifact retention.
- Promote v2 after the complete acceptance gate, not after one successful map.

## Test Plan

### Cross-language format tests

- Python writer output is accepted identically by Swift and C++ readers.
- Canonical manifest bytes, manifest receipt, signature envelope, and signed
  manifest receipt match in all languages.
- P-256 golden signatures verify in backend tests, CryptoKit, and firmware.
- Any byte change to signed manifest data fails verification.
- Unknown key ID and algorithm fail closed.
- Header, counts, sums, ordering, trailing bytes, and truncation agree across
  implementations.

### Backend tests

- Identical input produces byte-identical `.bmap` output.
- Payload ordering matches canonical manifest order.
- Artifact size/SHA metadata matches stored object bytes.
- Signing failure never publishes an unsigned v2 artifact.
- Object storage retry is idempotent by content identity.
- URL refresh returns the same immutable artifact.
- ZIP compatibility output remains valid.

### Firmware host tests

- Valid stream parsed one byte at a time.
- Randomized input chunk boundaries.
- Maximum allowed manifest/file-count/path/payload boundaries.
- Reject bad magic/version/flags/reserved fields/length arithmetic.
- Reject unsafe, duplicate, missing, reordered, oversized, and truncated files.
- Reject malformed envelope, bad signature, unknown key, and file hash mismatch.
- Never create active pointer state from an invalid stream.
- Checkpoint interruption after every parser/file/finalization transition.
- Retry skips durable prefix and rewrites only uncheckpointed work.
- Different manifest receipt cannot reuse an existing session.
- Ready/pointer/cleanup recovery preserves a valid old or new map.
- Pruning preserves every referenced recovery root.
- V1 tests remain green.

### iOS tests

- Streaming validation without whole-file memory loading.
- Signature trust and key rotation behavior.
- Artifact metadata/cache mismatch rejection.
- Artifact-aware saved map migration.
- Correct v2 capability and format selection.
- Explicit v1 selection for legacy ZIP/device combinations.
- One file-backed background request with token and media type.
- Task restoration after app suspension/termination.
- Reconciliation of receiving, paused, ready, activating, installed, failed, and
  idle-on-old-map states.
- Dynamic `Step n/3 - x%` presentation.

### Real-device tests

Run on both `WAVESHARE_AMOLED_206` and `WAVESHARE_AMOLED_175`:

- Small map clean install.
- Shanghai-scale clean install repeated multiple times.
- Display off for the entire local upload.
- App suspended and force-terminated after upload begins.
- Wi-Fi interruption near 10%, 50%, and 90%, followed by retry.
- Power loss during header, manifest, early/middle/late file, finalization,
  ready marker, pointer transaction, and cleanup.
- Wrong signature, wrong map ID, corrupted payload, truncated stream, and extra
  trailing data.
- Low SD free space and SD removal/failure.
- Replug/reboot and active-map discovery.
- New app to old firmware, old app to new firmware, and new-to-new matrices.
- Previous map remains usable until successful switch and after every failure.

Record phase times, payload bytes written, retry bytes skipped, free-space delta,
maximum observed temperature, UI/BLE responsiveness, and final active map.

## Acceptance Criteria

V2 may become the default only when:

- Backend, iOS, and firmware agree on permanent golden format vectors.
- Every production artifact has a valid trusted signature.
- iOS and firmware independently verify that signature.
- Device performs exactly one SHA-256 pass and one SD write per newly installed
  map payload byte.
- Device stores no full transfer artifact and creates no per-file receipts.
- Activation performs no payload scan, payload hash, extraction, or mass move.
- Screen-off and app-suspension uploads complete reliably.
- Retry never rewrites the durable completed prefix.
- Every tested power-loss point leaves the previous or fully verified new map
  recoverable.
- Integrity failures never trigger silent v1 fallback.
- Both Waveshare targets pass CI and repeated hardware tests.
- Shanghai measurements show a material reduction in post-transfer delay, SD
  write amplification, and sustained heat relative to v1.
- Operational signing-key rotation and artifact retention are documented and
  tested.
- V1 compatibility remains intact for the defined migration window.

## Non-Goals

- Direct ESP32 cloud downloads or TLS credentials on the device.
- Treating the iPhone as the signing authority.
- Rendering directly from `.bmap` in this project.
- Changing `.fmb`/`.fmp` map rendering semantics.
- Repartitioning or replacing the SD filesystem.
- Removing v1 during initial v2 implementation.
- Shipping an unsigned, foreground-only, one-board, or non-resumable interim
  implementation.
