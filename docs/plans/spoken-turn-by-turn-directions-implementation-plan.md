# Spoken turn-by-turn directions implementation plan

## Status and baseline

Status: **Slice 0 host codec proof and unsigned pack preparation implemented;
product integration and physical validation remain pending**.

The implementation branch `feature/spoken-directions` starts at freshly fetched
GitHub main `ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157`. Its first PR deliberately
does not claim issue #77 complete. See the
[codec/pack preparation evidence and remaining gates](../spoken-directions-codec-prototype.md).
The user confirmed a 1.75-inch device and asked to prepare tooling while
production recordings remain pending; no flash authorization is inferred.

This plan addresses [GitHub issue
#77](https://github.com/seichris/open-bike-computer/issues/77). The issue was
re-read on 2026-08-31 and refreshed on 2026-09-12 together with its linked speaker work, the current iOS,
firmware, protocol, storage, diagnostics, and test implementations, and the
relevant Apple platform APIs. At that point the issue was open, had no
comments, and had no linked implementation branch or pull request.

The planning branch is based on GitHub `main` fetched on 2026-09-12 at commit
`ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157`. The branch is
`plan/issue-77-spoken-directions`.

### Integration refresh — 2026-09-12

The original research baseline was
`9ef7f09fce0e0d95e349e6ef9c54da137fcff286`. This revision audits the full
August-to-September diff against the pinned main above, not just the branch
ancestry. A second fetch on 2026-09-12 returned the same main SHA; there is no
additional unreviewed main commit hidden by this refresh.

The navigation runtime, `NavigationEngine`, and speaker implementation did not
change between those baselines. Their 20 m transition and non-preemptible FIFO
remain implementation work. The surrounding integration contracts did change:

| New main integration | Required adjustment to this plan |
| --- | --- |
| BLE feature bits 23–25, client 23, motion freshness at dispatch, and transactional route replacement | Reserve only still-free bits 26/27; reuse the single writer, defer freshness checks and protection to dispatch, and preserve route/command barriers. |
| ATT submission-stage evidence and Watch shutdown fixes | Extend real-adapter tests and existing transport metrics; do not assume every stale CoreBluetooth callback is already fenced. |
| Coherent runtime snapshots, HTTP worker-owned cleanup, and socket interrupt leases | Publish bounded speech state coherently; revoke admission before cleanup and leave file/decoder disposal with its owner. |
| Saved-map replacement journals, immutable-identity downloads, and verification of checkpointed SD bytes | Give pack activation explicit recovery states; reject corrupt resumed bytes even when file lengths match. Reuse the download principles only if remote pack delivery is later added. |
| Development-only map trust and locked firmware build/release tooling | Keep speech signing domain-separated, test development-key exclusion, and use the attested build wrapper instead of raw PlatformIO. |
| Default-off Device Sounds visibility toggle | Add an independent default-off speech preference; do not interpret the existing toggle as hardware readiness or a firmware-wide mute. |
| Durable GPX/Strava route library and provider storage policy | Keep this release on the existing iPhone `MKRoute` navigation path; saved-route previews and Watch routes do not automatically authorize speech or durable storage of MapKit-derived audio. |

These adjustments are integrated into the implementation slices and regression
gates below. Current implementation evidence is linked in the source notes;
historical review ledgers are context, not fresh build or device proof.[^9][^10][^11]

Firmware builds and physical validation remain separate evidence gates. In particular,
the two Waveshare targets must eventually be built and tested from the exact
implementation head; source inspection of their shared speaker path is not a
substitute for audible validation.

## Outcome

During iPhone-owned navigation, Bicino should announce timely, intelligible
turn instructions through its own speaker without becoming an iPhone audio
output and without weakening navigation, workout, horn, or bell reliability.

Delivery has two product stages:

1. **Resident generic prompts.** A signed `en-GB` metric prompt pack is
   installed on the device. Normal riding sends only small authenticated cue
   commands. This stage remains fully offline once the pack is installed.
2. **Dynamic full instructions.** The iPhone renders the full, untruncated
   MapKit instruction, converts and transfers it before its deadline, and
   triggers the cached asset. Every dynamic cue retains the generic resident
   prompt as its fallback.

The rider-visible behavior should be:

- a long enough maneuver gets one useful distance warning, such as “In 50
  metres, turn right”, followed by one short action cue near the turn;
- short adjacent steps are not flooded with catch-up prompts;
- a reroute or user cancellation cannot speak an instruction from the old
  route;
- an uncertain cue is omitted rather than replayed late after reconnect;
- a horn or bell interrupts guidance promptly and is never queued behind a
  sentence;
- a missing, late, corrupt, or incompatible dynamic asset falls back to the
  matching resident generic prompt;
- the visual navigation flow remains usable when spoken directions are muted,
  unsupported, or temporarily unavailable; and
- both Waveshare 1.75 and 2.06 use the same cue, asset, cache, and priority
  behavior, retaining only their existing board-specific pins, power, and gain
  profiles.

## Research conclusions from current `main`

Issue #77 was written against an older transport and navigation baseline.
Several proposed prerequisites now exist and should be reused, while other
current behaviors make a direct implementation unsafe. The source inventory
below anchors these observations to the recorded Git commit.[^1][^2][^3][^4]

| Area | Current `main` evidence | Planning consequence |
| --- | --- | --- |
| Along-route progress | `NavigationRuntimeV1` projects fixes onto route geometry and exposes along-step remaining distance. It advances a step inside a 20 m maneuver band. | Do not create another geometry tracker. Schedule from `NavigationSnapshotV1.distanceToManeuverMeters` and fire action cues before the 20 m advance band. |
| Route identity | `NavigationRuntimeV1` advances a nonzero `generation` on start, replacement, and stop; route steps have stable `UInt32` IDs within a route. | Use the runtime generation and step ID. Do not introduce a third navigation epoch just for speech. |
| Instruction text | The runtime retains the full route instruction, but `NavigationEngine.displayInstruction` cleans it and truncates it to 30 characters for the device display. | Feed speech before display normalization. Dynamic speech must never use `currentInstruction` or the legacy BLE display string. |
| Arrival lifecycle | `NavigationEngine` currently stops navigation when the arrival step is inside 20 m. | Make stop reason-aware so an accepted terminal arrival cue may finish, while user cancel and reroute cancel immediately. |
| Maneuver classification | `MapKitRouteAdapter` uses `ManeuverV1.infer`, whose English substring matching defaults to `.straight`, not `.unknown`. | Add confidence-aware spoken classification; an unrecognized instruction must not become a spoken straight-ahead command. Locale gating alone is insufficient. |
| Speaker | Both targets share `esp32/lib/speaker/`. The sink is signed 16-bit little-endian stereo PCM at 16 kHz. A four-entry FIFO plays each request synchronously and has no guidance cancellation or priority. | Preserve the codec/power/gain layer, but add a priority audio engine above it. Guidance must be chunked and preemptible; all existing `requestPlay` callers remain safety-priority callers. |
| Embedded audio size | The three current sound assets occupy about 166 KiB in each application image; each OTA slot is 3 MiB. | Do not embed a phrase catalog in the OTA application. Keep only existing device sounds and, if desired, one tiny nonverbal failure tone in firmware. |
| Storage | `/sdcard` names either removable SD or the 9 MiB FFat fallback for the whole boot. They are not simultaneously available. | Install the active pack on the currently mounted backend, expose which backend owns it, and treat an SD swap as a possible pack removal. Reserve space for maps and diagnostics. |
| Local transfer | Authenticated, BLE-bound HTTPS already supports map, firmware, debug, and diagnostics modes. The HTTP handler registry is a fixed four-entry array and all four entries are used. | Add a fifth bounded handler and a dedicated `speech-pack` transfer mode, with registration failure treated as boot capability failure. Use this path for pack install, not navigation-time dynamic prefetch. |
| BLE capabilities | The generated contract uses a `UInt32` `CAP2` feature mask, current client version 23, occupied feature bits 0–25, seven protected channels, and 22 bytes of protected-frame overhead. | Propose bits 26/27 and client versions 24/25, then recheck availability immediately before implementation. Add a protected speech channel and golden fixtures in the JSON source of truth. |
| Reliable commands | `RCM1`/`RAK1` provides application-level acknowledgement and bounded idempotent replay for critical navigation/workout commands. | Extend this mechanism for cue admission and route cancellation instead of inventing an unrelated acknowledgement scheme. ATT completion alone is insufficient. |
| BLE queueing | The iPhone writer queries CoreBluetooth maximum lengths and write-without-response credit. Its bounded queue now also supports deferred `prepareData` and transactional route-snapshot replacement. | Keep one physical writer and prepare authenticated bytes at submission. Dynamic audio must be a pull-based lowest-priority source with a small credit window; preserve current route coalescing and application-command boundaries. |
| Background navigation | The app declares location and Bluetooth background modes. Navigation enables continuous background location updates when Always authorization is available. | Replenish the rolling speech window from the existing navigation/location lifecycle. Do not add background-audio playback merely to render buffers. Test suspension and screen-lock behavior rather than assuming background execution. |
| Diagnostics | Privacy-bounded ride diagnostics already exist on phone and firmware. | Extend the existing typed event path. Do not log instruction text, audio bytes, exact asset digests derived from text, route names, or coordinates. |

The physical speaker baselines remain the merged [1.75-inch speaker
work](https://github.com/seichris/open-bike-computer/pull/62) and [2.06-inch
device-sound work](https://github.com/seichris/open-bike-computer/pull/45).
They prove that the board-specific audio paths exist; they do not validate the
new scheduler, storage reader, decoder, priority behavior, or riding
intelligibility.

## Product and architecture decisions

### Version A ships first and remains mandatory

Dynamic speech is not a replacement for resident prompts. Firmware advertises
dynamic speech only when the generic prompt engine is also working and a
compatible resident fallback pack is active. The dynamic phase cannot merge
until Version A has passed both-board physical validation.

### Split durable installation from ride-time prefetch

Use two transports for two different jobs:

- **Prompt-pack installation:** the existing owner-authenticated, TLS-pinned
  local HTTPS transfer service. A pack is relatively large, durable, and
  installed outside a ride.
- **Dynamic route assets:** a dedicated, protected, resumable BLE stream. A
  route asset is small, private, short-lived, and must work away from a LAN or
  hotspot.

Do not send the durable catalog through the ride BLE queue. Do not make a
spoken maneuver depend on entering a Wi-Fi transfer mode while navigating.

### One compact spoken-asset format

The preferred candidate for measurement is:

```text
codec                 IMA ADPCM, 4-bit, independently decodable fixed blocks
source channels       mono
source sample rate    16,000 Hz
speaker sink          signed PCM16LE, stereo, 16,000 Hz
playback conversion   decode one bounded block, duplicate mono to L/R
maximum duration      8 seconds per asset
```

At 16 kHz, current stereo PCM consumes 64,000 bytes per second. The proposed
mono ADPCM representation is approximately 8,000 bytes per second before its
small block headers, so a three-second phrase is about 24 kB instead of
192 kB (decimal units). This is a size calculation, not measured BLE throughput.
IMA variants differ in block layout and nibble ordering; freeze one precisely
specified variant and cross-language fixtures before asset production.[^8]

Phase 0 compares the existing PCM sink, mono PCM storage/transfer, and ADPCM.
Select ADPCM only if measurements justify its decoder complexity. The following
ADPCM sections describe that candidate; if PCM meets the size, latency, and
storage budgets, retain PCM and update those sections before implementation.
Neither choice permits live audio streaming at the cue deadline.

### Initial language and user default

- The first resident pack is `en-GB`, metric, with complete recorded phrases.
- It may be used for `en-*` route locales only after fixture coverage confirms
  the maneuver classifier. Other locales remain visual-only unless a dynamic
  instruction is ready and the rider has explicitly accepted an English
  fallback.
- Existing installations default spoken directions to Off after upgrade. The
  app presents an installation/onboarding choice rather than unexpectedly
  making the device speak.
- Guidance volume is separate from the existing horn/bell selection and
  volume. The initial guidance default is 70%, subject to both-board acoustic
  validation.
- The app never redistributes audio rendered from Apple system voices as the
  resident pack. Resident recordings or generated assets need documented
  ownership/license provenance.

### Initial controller scope

The release scope is iPhone-owner navigation, matching issue #77. Put the pure
scheduler and wire model in `RideShared` so a future direct-Watch implementation
does not fork semantics. A scoped Watch may not install packs, stream dynamic
assets, or trigger speech in this release. Firmware rejects all channel-8
messages from that role. Controller handoff cancels phone guidance immediately.

## Non-negotiable invariants

1. **At most once per cue phase.** A cue is identified by speech-route token,
   runtime generation, step ID, and phase. A retry of the same logical command
   cannot start a second playback.
2. **Never stale.** Reroute and user cancellation invalidate queued guidance,
   active guidance, partial dynamic transfers, and old route-to-asset
   associations. A new route token supersedes the old token atomically.
3. **Omit rather than replay late.** If disconnect occurs after send but before
   acknowledgement, do not recreate that cue after its deadline or on a new
   firmware boot. Continue from future threshold crossings.
4. **Safety audio wins.** PWR-button honk and existing app horn/bell requests
   use a queue that guidance cannot fill. They preempt guidance at the next
   bounded audio block and do not resume the interrupted sentence.
5. **One BLE writer.** Cue controls and dynamic chunks use the existing
   serialized CoreBluetooth writer and protected-session rules.
6. **Bulk never starves ride traffic.** Dynamic audio is below auth, control,
   navigation clear, terminal workout, cue trigger, navigation snapshot,
   workout, GPS, and settings traffic. Its bounded credit window cannot occupy
   critical queue reserve.
7. **Resident-before-trigger.** Neither version streams live audio at the
   maneuver. Firmware acknowledges a cue only after it resolves a verified
   resident or dynamic asset and admits the guidance request.
8. **Bounded memory and storage.** Every pack record, phrase, transfer,
   decoder buffer, queue, cache, manifest, and diagnostic field has a checked
   maximum. No BLE callback performs file I/O or waits for playback.
9. **Visual navigation is independent.** Muting, missing assets, transfer
   failure, decoder failure, or speaker failure cannot stop route progress or
   suppress the existing display instruction.
10. **Privacy by design.** Dynamic speech text and audio remain local. Logs and
    support bundles contain no instruction, street, route name, coordinates,
    audio bytes, or stable text-derived digest.
11. **Board behavior is shared.** Protocol, manager, decoder, cache, queue, and
    tests are identical on 1.75 and 2.06. Only the established speaker pins,
    power rails, PA model, and gain curve differ.
12. **Evidence stays separated.** Host tests, CI builds, installed artifacts,
    BLE traces, audible output, and riding results are reported as separate
    evidence classes tied to exact SHAs.

## Target architecture

```text
MapKit route + Core Location
        |
        v
NavigationRuntimeV1
  generation, step ID, full instruction, along-step distance, speed
        |
        +------------------------------+
        |                              |
        v                              v
SpokenCueSchedulerV1             DynamicSpeechPrefetcher (Version B)
  threshold crossings             AVSpeechSynthesizer.write
  consumed phase ledger           AVAudioConverter -> mono 16 kHz
  fallback semantic key           IMA ADPCM encoder
        |                              |
        | small protected cue          | bounded low-priority BLE stream
        v                              v
                 one CoreBluetooth writer
                           |
                    protected channel 8
                           |
                           v
                 SpokenDirectionsManager
                  generation + dedupe
                  asset resolve/fallback
                  transfer/cache worker
                           |
                           v
                    PriorityAudioEngine
            safety queue > guidance queue, preemptible blocks
                           |
                           v
          existing ES8311 / NS4150B board-specific output
```

Resident packs use a separate setup path:

```text
signed .bspk resource in app or approved catalog
        -> app verification
        -> owner-authenticated BLE transfer-mode request
        -> TLS-pinned local HTTPS stream
        -> device streaming verification and staging
        -> atomic active-pack switch on /sdcard backend
```

## Shared cue model and scheduler

### Cue identity

Create pure, versioned types in
`ios-app/BikeComputer/RideShared/SpokenDirectionsContract.swift` and matching
generated constants in firmware.

Each navigation start or replacement creates a random 64-bit
`speechRouteToken` paired with `NavigationRuntimeV1.generation`. It is not a
user or route identifier. Each emitted cue has a monotonic nonzero
`cueSequence` within that token and contains:

- runtime generation;
- speech-route token;
- step ID, with step index included only as bounded diagnostics metadata;
- cue sequence;
- phase: `prepare`, `action`, or `arrival` in Version 1, with `advance`
  reserved in the schema;
- generic semantic key: maneuver plus distance bucket or action form;
- optional 128-bit dynamic asset key;
- requested guidance volume;
- bounded playback-start lifetime and current-step progress revision;
- terminal-arrival flag; and
- contract/audio-format versions.

Firmware tracks the active route token and highest admitted cue sequence. The
existing `RCM1` replay window handles transport retries; the speech sequence
rejects an older logical cue that arrives after progress. A new route token
atomically cancels the old guidance domain.

Route activation is an acknowledged control operation, not an implicit side
effect of receiving an unfamiliar cue token. Within an authenticated connection,
control revisions increase monotonically; old activate/cancel operations cannot
replace a newer token. After reconnect, clear firmware guidance and synchronize
the current token before admitting future cues. Reject unknown tokens on cue and
asset frames. Retire the token on counter wrap rather than comparing wrapped
sequence numbers as ordinary integers.

Do not put instruction text, locale strings, filenames, or unbounded IDs in a
cue frame. Keep the complete protected write within the 182-byte ATT payload
available at the ownership protocol's required MTU 185; target no more than 96
plaintext bytes so future framing changes retain margin.

Expiry must be enforced at both queue boundaries. The phone drops a cue whose
monotonic deadline or step has passed before the physical write; firmware drops
a queued cue when its remaining start lifetime expires or newer step progress
arrives. Send a coalesced speech progress/lease update from fresh navigation
fixes (one per second maximum), with a five-second firmware expiry. Loss of
the BLE connection, controller lease, or fresh progress stops guidance. The
five-second value is a proposed bound to validate, not a freshness guarantee
under every radio failure. No command can cancel audio before firmware receives
it or detects expiry; measure that detection-to-stop latency explicitly.

Use one pending guidance slot. An action cue supersedes its own unfinished
prepare cue, and a new step invalidates every pending cue from the old step.
If multiple phases cross in one fix, consume all crossed phases but emit only
the latest still-valid phase. This prevents an eight-second sentence from
delaying a turn cue.

### Default threshold policy

Implement the scheduler as a pure state machine in
`RideShared/SpokenCueScheduler.swift`. It consumes the runtime snapshot, the
current route step, a fresh normalized speed, and capability/settings state.
It must detect threshold crossings between the previous and current remaining
distance rather than waiting for equality.

Version 1 defaults are:

```text
supported distance buckets     50 m, 100 m, 200 m
prepare target lead            clamp(max(smoothedSpeed * 8 s, action lead + minimum gap), 50 m, 200 m)
prepare spoken bucket          smallest supported bucket >= target lead
action lead                    clamp(smoothedSpeed * 3 s, 25 m, 60 m)
runtime step-advance band      20 m
minimum prepare/action gap     max(35 m, smoothedSpeed * 5 s)
maximum ordinary cues/step     2 (one prepare, one action)
```

Rules:

- Implementation consistency correction: select the prepare bucket only after
  calculating the action lead and minimum gap. At the 5 m/s fallback speed,
  the original 50 m bucket left only 25 m before action, which could never
  satisfy the mandatory 35 m gap. The corrected default selects 100 m;
  50 m remains supported on the wire and in the resident pack. These are
  provisional timing defaults, not physically qualified acoustic results.

- Clamp valid measured speed to `2...15 m/s`; use `5 m/s` when speed is absent,
  stale, negative, or non-finite. Smooth speed for threshold selection, but do
  not smooth along-route remaining distance.
- Suppress speech for stale or inaccurate fixes, off-route/rerouting state,
  and stationary/paused navigation; valid speed zero is stationary, not missing.
  Proposed fix limits are age at most five seconds and accuracy at most 30 m,
  with tighter maneuver-specific rejection when uncertainty exceeds the
  remaining distance. Reuse existing navigation freshness policy where stricter.
- Select one prepare bucket per step when the step first becomes current. Do
  not change the spoken distance after crossing into a different speed band.
- Freeze the action threshold at the same time. Its 25–60 m lead is an early
  action reminder, not a precise instruction to turn immediately at 60 m;
  phrase wording must reflect this during acoustic/timing trials.
- Suppress prepare when the observed start of the step is already below its
  threshold or when it cannot maintain the minimum gap to action. Never emit
  multiple skipped distance buckets as catch-up.
- `advance` remains encoded but disabled by default. Field trials may enable a
  200 m advance cue only for long, isolated steps without changing the wire
  schema.
- Action may emit on the first fresh observation of a newly started route if
  remaining distance is between the 20 m step-advance band and the action
  threshold. This exception does not apply to reconnect or app restoration.
- Process the speech decision before `NavigationEngine` applies display
  truncation or its arrival stop check.
- On a GPS jump that advances one step, mark all unobserved phases from the old
  step suppressed. Do not speak them after the step changes.
- Repeated identical snapshots, readiness changes, and BLE reconnects cannot
  recreate consumed decisions.
- If a route starts after app restoration without a durable consumed-phase
  ledger, seed the current step as observed and wait for a future crossing.
  This deliberately prefers a missed cue to a duplicate.

The policy constants live in one type, are included in diagnostics as a
version number, and are tuneable by code/configuration—not scattered through
`NavigationEngine`.

### Stop, reroute, and arrival semantics

Replace the undifferentiated speech-facing stop path with these logical
reasons:

- `userCancelled`: cancel active/queued guidance and dynamic route assets now;
- `rerouted`: cancel the old token before admitting any cue for the replacement
  token;
- `connectionLost`: retain local scheduler state, stop dynamic transmission,
  and do not replay expired cues after reconnect;
- `arrived`: allow the one already-admitted terminal arrival cue to complete
  for a bounded grace period, then retire the token; and
- `appTerminated` or unrecoverable route failure: fail closed as cancellation.

A later new route always preempts an arrival grace period. Safety audio always
preempts it as well.

## Resident prompt-pack design

### Pack contents

The first pack contains complete phrases rather than word fragments. At
minimum it covers:

- straight, slight left/right, left/right, sharp left/right, U-turn, and a
  generic roundabout instruction;
- 50 m, 100 m, and 200 m prepare forms for applicable maneuvers;
- short action forms for each maneuver;
- destination arrival;
- one rerouting announcement per reroute attempt, suppressed if a new valid
  maneuver already needs speaking;
- a generic “Continue” fallback; and
- a nonverbal unavailable/error fallback only if acoustic testing shows it is
  useful rather than confusing.

Roundabout exit numbers, road names, imperial units, and non-English phrases
are not implied by the first pack. Unknown maneuver semantics resolve to
`continue`, never to a guessed left or right.

### Manifest and stream format

Add `docs/spoken-directions-protocol.md` and a deterministic pack builder under
`tools/`. A signed `.bspk` stream has bounded header/index records and asset
payloads; it is not a ZIP archive and does not accept paths from the producer.
Its signed manifest includes:

- pack schema, pack ID, semantic version, BCP-47 locale, and metric/imperial
  system;
- audio codec ID, sample rate, channels, block size, and decoder version;
- minimum firmware contract version;
- every semantic cue key exactly once;
- encoded byte length, decoded frame count, duration, and SHA-256 for each
  asset;
- total stream length and total installed length;
- signing key ID and P-256 signature envelope;
- provenance/license identifier and a release-time notices digest; and
- optional replacement/supersedes metadata.

Reuse the map stream's bounded streaming, canonical-P256, and compiled-trust
patterns, but use a distinct signature domain and a speech-pack key namespace.
A signature valid for a map must not be valid for a voice pack. Generate iOS
and firmware trust data from one checked source and fail CI on drift.

Builder validation rejects duplicate semantics, unsupported locale/unit
combinations, noncanonical signatures, excess duration, excess decoded frames,
invalid ADPCM state, nonfinite generation inputs, and any pack that exceeds
the configured FFat installation budget.

### Installation and atomic activation

Add `speechPack` to `DeviceTransferSession.Mode`, a corresponding authenticated
control action, and `/speech-pack/` HTTP handler. Installation is owner-only,
unavailable during active navigation or audio playback, and mutually exclusive
with map, firmware, debug, and diagnostics transfer modes.

Firmware streams into a fixed staging namespace such as:

```text
/sdcard/SPEECH/v1/staging/<pack-id>/
/sdcard/SPEECH/v1/packs/<pack-id>/
/sdcard/SPEECH/v1/active
```

Preserve the current transfer worker's generation checks, active-client
interruption, `responseDidAbort`, and `workerWillStop` ownership boundaries.
HTTP completion is not proof of installed-pack activation; the final receipt
must identify the verified active manifest after reopen.

In particular, disable/disconnect must revoke the transfer generation and
interrupt the active client before network teardown. The HTTP worker alone
aborts/finalizes the pack session after its request unwinds; UI/BLE callbacks
must not reset a handler or close its files concurrently. Preserve
`SocketInterruptLease` withdrawal before descriptor close/reuse. Use
object-owned static handler mutex storage, as the current map/firmware handlers
do, and reject re-entry while the previous worker is stopping.[^9]

On iOS, generalize the current map-mode handshake for the new mode: wait for a
fresh, mode-matching DSTS session and generation, not an empty ride queue.
Capture the initial status revision/error sequence and reuse
`DeviceTransferFreshFailurePolicy`; an old `lastError` must not reject a new
install, and a delayed status from a prior generation must not authorize one.

The receiver:

1. checks the declared size against free space and preserves a board-tested
   reserve for maps, diagnostics, and filesystem metadata;
2. parses and hashes incrementally without loading the pack into RAM;
3. writes only generated numeric/semantic filenames beneath the staging root;
4. fsyncs each completed record and the verified manifest;
5. verifies the signature, full layout, individual hashes, and coverage;
6. atomically renames staging to its final immutable directory;
7. atomically replaces the small active-pack marker; and
8. deletes an older pack only after the new marker survives reopen and
   revalidation.

Define a bounded, versioned activation journal with old/new pack identities
and an explicit committed decision before deleting anything. Replay recovery
idempotently on every boot; an interruption during recovery must remain
recoverable. Do not assume a rename plus `fsync` is a multi-file transaction on
both FFat and SD. Model the phone's optional downloaded-pack metadata update on
`SavedMapReplacementJournal` rather than overwriting artifact and metadata
independently. Test filesystem failures at each journal/rename/marker boundary.

For resumable durable pack installation, a checkpoint is a resume hint, not
proof that SD bytes are still valid. Follow `MapStreamInstallSession`'s current
`VerifyAndConsume` pattern: compare stored completed-record bytes against the
retransmitted, incrementally hashed stream before skipping writes. Equal-length
corruption, short reads, changed cards, or mismatched pack identity must reject
the resume without touching the old active pack. Final verification must cover
the bytes that will actually be activated, not only the network input.[^10]

Power loss at every step must leave either the old valid pack active or no
active pack, never a partially trusted pack. Boot cleans abandoned staging
directories under a strict size/count bound. A removable-card change may make
the previous pack disappear; firmware reports `pack_missing` and the app offers
installation on the newly active backend.

The iOS app initially bundles the signed `en-GB` pack so installation works
without Internet access. Future downloadable catalogs must pass the same local
signature and manifest verification before the app asks the device to enter
transfer mode.

Remote catalogs are not a Version A prerequisite. If introduced, extract a
bounded generic artifact downloader from the map-specific
`DurableMapDownloadCoordinator` or reuse its tested primitives: immutable
digest/length identity, separate attempt ownership, cancellation tombstones,
retained completion, bounded opaque resume data, HTTPS/allowed-host checks, and
hash/signature validation. Do not put speech into map artifact namespaces or
map-specific manifests. Keep durable packs in backup-excluded Application
Support; route-private generated audio remains ephemeral. OS-owned background
transfers do not guarantee execution after user force-quit.[^10]

The pack builder needs its own signed schema/domain and approved trust
namespace, not a copied map or firmware signing key. Production must exclude
development speech keys even when development packs are supported in an
explicit opt-in profile. Add rejection fixtures for cross-domain, unknown,
revoked, and development-only keys, and document an approved release/signing
workflow before distributing the bundled pack. This plan does not authorize
provisioning or moving signing secrets.[^11]

## Firmware implementation

### `SpokenDirectionsManager`

Add a manager above the physical speaker driver. It owns:

- active speech-route token and runtime generation;
- cue sequence/deduplication state;
- pack manifest and semantic lookup;
- dynamic asset transfer state and route cache;
- cue admission, fallback selection, cancellation, and completion status;
- separate guidance enable/volume state received from the app;
- bounded counters and privacy-safe diagnostics; and
- capability health: engine available, active pack ready, and dynamic cache
  ready are separate states.

BLE callbacks only validate/decrypt and copy fixed-size messages into bounded
control or transfer queues. Pack parsing, file writes, hashing, cache work,
decoding, and playback occur on their owner tasks.

Use the current `runtime_ownership::Snapshot` pattern for coherent bounded
status publication. Formatting, allocation, filesystem work, and audio work
stay outside its lock. Cancellation first revokes admission atomically, then
the owning worker drains/disposes pending work; never free decoder/cache state
from a BLE callback while the audio task uses it. Report task/queue/lock
allocation failures as unavailable capabilities without disturbing navigation
or boot acceptance. Extend the existing runtime ownership harness to stress
publication versus disconnect, stop, and worker retirement.[^9]

### Priority audio engine

Refactor `esp32/lib/speaker/` without changing existing call-site semantics:

- keep `requestPlay` and `requestPlayTracked` as safety-priority APIs for all
  existing horn, bell, and PWR-button callers;
- use separate fixed-capacity safety and guidance queues so speech cannot
  consume safety reserve;
- let a PWR-button honk take the front of the safety queue;
- make the playback loop check a lock-free safety/preempt flag at most every
  10 ms of decoded guidance audio;
- abort guidance, drain its decoder state, report `preempted`, and begin safety
  playback within a physical target of 100 ms from the request reaching the
  firmware audio API;
- never resume a preempted guidance phrase;
- retain current codec lazy-open, audio power lock, UI wake notification,
  limiter, board gain curve, silence drain, and cleanup guarantees;
- represent queued work with fixed POD descriptors, not `String`, `std::vector`,
  closures, or whole decoded phrases in a FreeRTOS queue; and
- expose completion reasons `played`, `preempted`, `cancelled`, `missing`,
  `decode_failed`, `output_failed`, and `stale` rather than one Boolean.

The decoder reads verified ADPCM blocks into a double buffer, validates every
block header and exact decoded-frame ceiling, expands mono to stereo, applies
the existing limiter, and writes small chunks to `esp_codec_dev`. It never
allocates per block in the playback loop.

### Asset stores and storage behavior

Expose one `SpokenAssetStore` interface with two implementations:

- a durable read-only active-pack store on the mounted `/sdcard` backend; and
- a route-scoped dynamic store backed by a fixed PSRAM pool when the Phase 0
  headroom gate passes, with a bounded storage-backed fallback only if its
  latency and wear gates pass.

The preferred dynamic pool stores encoded ADPCM, not decoded PCM. Start with
128 KiB total, a 64 KiB per-asset ceiling, one partial transfer, and enough
metadata for three upcoming prompts. Allocate the pool once during capability
initialization; if allocation or measured map/BLE headroom fails, do not
advertise dynamic support for that boot.

Do not reserve optional speech memory ahead of required display buffers. Main
now enforces all-or-nothing full-frame PSRAM admission; preserve that behavior
on both dimensions and rotation modes. Measure remaining largest allocatable
blocks as well as total free bytes under the current renderer, authentication,
and TLS workloads. Failure to admit optional speech memory disables dynamic
speech, not required rendering or the resident fallback.

Dynamic assets are private and route-scoped. They survive a BLE reconnect in
the same boot so transfer can resume, but are removed on route cancellation,
replacement, owner change, device reboot cleanup, or bounded route expiry.
Filenames and diagnostics never contain speech text. A storage-backed fallback
uses opaque random/token-scoped names and the same cleanup rules.

The PSRAM option is a proposed deviation from the issue's storage-backed cache,
intended to reduce flash writes and retain route privacy. Phase 0 must compare
both. A current-plus-three-step prefetch window is a scheduling horizon, not a
promise that four maximum-size assets fit in 128 KiB: pin the next deadline,
evict unneeded encoded assets by deadline/LRU, and fall back when admission
would exceed the budget. Oversized output fails to a resident cue. Reboot
invalidates all prior dynamic readiness, including file-backed remnants.

Audio read-ahead wins over speech transfer writes. The transfer worker returns
zero credit while its bounded ring is full, pack activation is in progress, or
audio needs the storage path. It may not hold a global storage lock while
blocking on BLE, I2S, LVGL, or network work.

## BLE contract and delivery behavior

### Generated contract changes

Update `protocol/ride-ble-contract-v1.json` first, then regenerate Swift and
C++ artifacts. Proposed additions are:

```text
characteristic spoken_directions  new 128-bit service-local UUID
protected channel                 8
CAP2 bit 26                       resident_spoken_prompts
CAP2 bit 27                       dynamic_spoken_cache
client version 24                 Version A
client version 25                 Version B
RCM1 command type 3               spoken_route_control
RCM1 command type 4               spoken_cue
```

The actual UUID is allocated once in the JSON contract and never duplicated by
hand. The new characteristic supports write, write-without-response, and
notify. Native speech writes are preferred. A fallback over the existing
navigation characteristic is allowed only for Version A cue/control frames,
only when explicitly capability-gated, and still unwraps protected channel 8.
Bulk dynamic frames never use the navigation fallback.

Capability meaning is strict:

- bit 26 means the speaker task, speech manager, cue parser, selected decoder, and
  active compatible pack are all ready at runtime;
- bit 27 means bit 26 is ready plus the bounded dynamic cache and stream worker
  passed initialization;
- code compiled into firmware is not enough to set either bit; and
- pack status/version/locale/backend is reported separately through a bounded
  speech-status response, not encoded as more feature bits.

Avoid a first-install discovery deadlock: add a bounded CAP2 TLV describing
speech protocol/installer support, even when no pack is installed and both
readiness bits are clear. The app uses that TLV to expose install/repair and
query pack status. Installation must never require the resident-ready bit.
Re-query readiness after activation, failure, or storage changes; firmware
validates readiness on every admission even if the app's last status is stale.

The proposed numbers are unallocated at the recorded baseline only. Keep their
allocation and corresponding client-version gating in one implementation change.

### Cue acknowledgement and status

Wrap route-control and cue commands in the existing `RCM1` application
delivery envelope. Firmware returns `RAK1 success` only after it has:

- authenticated and authorized the controller role;
- validated contract version, route token, generation, cue sequence, semantic
  key, and volume;
- rejected stale/duplicate logical cues without replay;
- resolved the dynamic asset or its verified generic fallback; and
- admitted the guidance descriptor into its bounded queue.

Add a protected bounded status notification for lifecycle outcomes. It carries
route token, cue sequence, disposition enum, selected source
`dynamic|resident|none`, and stable error code. It contains no text or raw
asset digest. Admission acknowledgement is required for transport recovery;
playback completion status is observability and UI state, not permission to
block route progress.

Retries use the same `RCM1` command ID and cue sequence. They are allowed only
inside the same logical deadline and compatible firmware boot/session. After a
disconnect with ambiguous admission, the scheduler records the cue consumed
and does not recreate it. This is how the implementation meets “at most once”
without a dangerous late replay.

### Dynamic asset stream

Version B adds bounded binary frames on channel 8:

```text
SAB1  begin: route token, transfer ID, asset key, codec, sizes, frames, SHA-256
SAQ1  query/resume: route token, transfer ID or asset key
SAD1  data: transfer ID, contiguous byte offset, bounded bytes
SAC1  commit: transfer ID and expected digest
SAX1  cancel: route token or transfer ID
SAS1  status notification: state, contiguous offset, receive credit, error
```

Exact layouts, endian rules, maximums, and golden hex fixtures belong in
`docs/spoken-directions-protocol.md` and the generated contract. Requirements:

- the iPhone derives each data payload from
  `maximumWriteValueLength(for:)` minus protected and speech-frame overhead;[^6]
- data uses write without response only while
  `canSendWriteWithoutResponse` is true and firmware-reported credit is
  nonzero;
- control/begin/commit/query uses acknowledged writes and typed timeouts;
- firmware accepts one active partial transfer and advertises a small byte
  credit matching its fixed receive ring;
- chunks enter a worker queue; the NimBLE callback never writes a file or
  decodes audio;
- offset is contiguous, identical duplicate data at or below the committed
  offset is idempotent, conflicting duplicates and gaps are rejected, and
  final SHA-256 is mandatory;
- a `.part` asset is invisible to cue lookup until commit succeeds;
- resume after reconnect queries the device's contiguous offset and rewraps
  plaintext chunks in the new authenticated session;
- route cancellation and a new token cancel partial work immediately; and
- malformed length, overflow, wrong codec, excess duration, bad block state,
  digest mismatch, storage failure, and stale token have distinct bounded
  result codes.

Do not enqueue an entire asset into `NavigationWriteQueue`. Add a
`SpeechBulkFrameSource` that materializes at most one or a small fixed number
of MTU-sized frames when the single writer has no higher-priority work. Give it
a hard pending-byte ceiling and reset it on connection generation changes.

`prepareData` must recheck the route token, settings, owner, connection
generation, and monotonic start deadline immediately before submission. Like
current motion dispatch, it returns `nil` to drop stale work. Encode the
remaining TTL then, never renew the original deadline on retry. Protection
belongs in the existing `writeDeviceData`/`devicePayload` path after plaintext
preparation; do not consume authenticated sequence numbers while prebuilding
or coalescing queued frames. Preserve the global acknowledged-ATT and RAK1
barriers, including for bulk writes without response. Route snapshot
replacement is specifically for replaceable geometry, not speech cues or
route-control commands; cue supersession must retain its own consumed ledger.

Use explicit speech-control/bulk write classes and extend all exhaustive
priority, drop, protected-channel, and diagnostic mappings. Do not hide bulk
under `.other` and thereby bypass admission accounting. The current Bluetooth
follow-up document still identifies same-peripheral stale delegate callbacks
and phone readiness coordination as open audit work. Fence speech operations
against terminal phases/generation changes in the real adapter, suppress
ambiguous late completion, and do not claim that shared reducer tests already
prove this boundary.[^12]

## iOS implementation

### Version A scheduling and delivery

`NavigationEngine` owns the scheduler lifecycle but not its policy. On route
start it supplies the runtime route/generation and fresh initial location. On
each accepted runtime snapshot it:

1. passes full instruction, step identity, along-step distance, and speed to
   the pure scheduler;
2. sends any returned logical cue through a small `SpokenDirectionsTransport`;
3. then derives the truncated display instruction and sends the existing
   navigation snapshot; and
4. applies arrival/stop behavior with the explicit stop reason.

The scheduler's consumed ledger changes before asynchronous enqueue. The
transport owns idempotent retry of the same cue; reconnect does not ask the
scheduler to generate it again.

`BLEManager` remains the public facade initially, but speech protocol encoding,
status decoding, and stream state live in focused files rather than adding a
large block of ad hoc parsing to the facade. Integrate with the existing
connection-generation checks, authenticated write session, queue priority,
application acknowledgement, and diagnostics sink.

Add a focused `SpokenManeuverClassifier` with an explicit unknown/confidence
result. The existing English matcher can interpret street names containing
“left”, “right”, or “destination” as directions and defaults all other text to
`.straight`. For speech, recognize tested instruction patterns and provider
semantics, not arbitrary substrings. Unsupported/ambiguous instructions must
use the documented nondirectional fallback or visual-only behavior; test that
path with actual adapter-produced routes. Do not silently change archived
`ManeuverV1` values or the existing visual icon contract to repair speech.

The current iPhone navigation entry remains `startNavigation(with: MKRoute)`.
`PhoneRouteLibrary` and `NavigationRouteArchiveV1` now support durable,
provider-policy-gated routes, but previewing/saving one is not starting this
runtime. Do not add GPX/Strava/Watch navigation ownership as an incidental part
of issue #77. Keep speech models compatible with `NavigationRouteV1` for future
adapters; any later integration must honor provider expiry/deletion and create
a new runtime generation/token. Never persist MapKit-derived utterances in the
durable route library or use speech caching to bypass its storage policy.[^13]

### Settings and pack UI

Add a **Spoken Directions** section near, but separate from, **Device Sounds**:

- enable toggle;
- mode: `Generic` or `Full instructions` when dynamic capability exists;
- guidance volume;
- active pack locale/version/backend/health;
- **Install** or **Repair voice pack** action with size and transfer warning;
- dynamic voice and rate controls in Version B; and
- a concise fallback status when full instructions are unavailable.

Pack installation requires a connected authenticated owner, no active
navigation, sufficient device storage, and an idle device-transfer service.
The app verifies the bundled/downloaded signature before entering transfer
mode and verifies the device's final active-pack receipt before enabling the
toggle.

Persist settings per paired device identity so one device's missing pack does
not disable another. Firmware still decides runtime availability. Existing
horn sound, horn volume, and PWR-button configuration keys are never reused.

`deviceSoundsEnabled` currently defaults to false and only reveals sound
controls and the app honk button. It neither proves a speaker is connected nor
acts as a firmware-wide audio mute. Keep its meaning and stored key unchanged.
Expose speech enablement independently when installer support exists; explain
that it is a separate opt-in. Turning Device Sounds off must not silently
change speech or PWR-button behavior; turning speech off cancels guidance only.
Test all four sound-controls/speech-toggle combinations and existing-user
migration with a missing pack.

### Dynamic rendering and prefetch

Apple provides
[`AVSpeechSynthesizer.write(_:toBufferCallback:)`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:))
for rendered speech buffers and
[`AVAudioConverter`](https://developer.apple.com/documentation/avfaudio/avaudioconverter)
for PCM format/sample-rate/channel conversion. Encapsulate both behind a
serial `SpeechRenderer` so scheduler and transfer tests use deterministic
fakes.[^5] Sample-rate conversion must use the input-block conversion API
described in Apple's TN3136, drain converter output at end of input, and inspect
the actual format of incoming speech buffers rather than assuming 16 kHz.

For each upcoming maneuver:

1. build a localized prepare utterance from the full, untruncated MapKit
   instruction and chosen distance bucket;
2. resolve and record the exact system voice identifier and speech rate;
3. render complete buffers, detect the documented end-of-stream condition,
   and enforce an eight-second decoded limit;
4. convert to 16 kHz mono PCM with explicit channel mixing and clipping rules;
5. encode deterministic IMA ADPCM blocks with a pure Swift encoder shared with
   golden fixtures;
6. derive a 128-bit asset key from schema, normalized utterance, locale, voice
   identifier, rate, and codec version; volume is not part of the key;
7. transfer and commit before the step's prepare deadline; and
8. retain the generic semantic key in the eventual cue command.

The prepare bucket is frozen by the scheduler; prefetch may predict one for an
upcoming step, but it must regenerate or choose the generic asset if the actual
bucket differs on step entry. Never play a cached utterance for the wrong
distance. If the full phrase's duration exceeds the measured runway to action,
use the short generic phrase instead of truncating a street instruction midway.

Render one dynamic full prepare phrase per step. Keep the near-turn action cue
short and resident in Version 1. This bounds transfer volume and still gives
the rider the street name early plus an immediate generic action reminder.

Maintain a rolling window of the current and next three steps. Prioritize by
deadline, cancel work for a replaced route, and never wait until a threshold
crossing to begin synthesis. A route with very short steps may deliberately
skip dynamic work and use generic cues.

Phone-side temporary assets live under a backup-excluded, file-protected cache
with opaque filenames, a 20 MiB/24-hour bound, and route-manifest cleanup on
stop. Do not put instruction text in filenames, UserDefaults, diagnostics, or
support exports.

The existing app already enables location and Bluetooth background modes and
keeps background location active for authorized navigation. Use route creation
in the foreground to fill the initial window, then replenish from navigation
location callbacks. Apple's [background location
guidance](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)
does not guarantee unlimited arbitrary processing, so screen-lock and
suspension tests are release gates. Do not add the audio background mode: the
phone is rendering data, not playing audio.[^7] Unsupported or unavailable system
voices fall back locally; this feature does not initiate a network voice
download during a ride.

## Delivery slices

Implement as reviewable slices. Do not combine the speaker priority refactor,
pack installer, scheduler, and dynamic stream in one change.

### Slice 0: measurement and contract proof

Before product implementation:

- record the fetched implementation baseline and rebase if GitHub `main` has
  advanced;
- build a host Swift encoder/C++ decoder golden prototype for the proposed
  ADPCM blocks;
- prepare owned/licensed representative short, long, sibilant, quiet, and
  high-amplitude phrases;
- measure encoded sizes and full decode time;
- measure real iPhone-to-each-board protected BLE throughput at negotiated MTU
  and 30-50 ms navigation connection intervals, with navigation/GPS/workout
  traffic present;
- measure speaker preemption granularity using bounded output chunks;
- record internal/DMA/PSRAM minima with map rendering, BLE authentication,
  TLS, audio decode, and the proposed 128 KiB cache allocation;
- measure active-backend read latency while maps render and while the local
  transfer worker writes another file; and
- decide the exact free-space reserve and dynamic cache backend from those
  measurements.

Gate:

- a three-second phrase can be encoded near the expected 24 kB size, decoded
  faster than real time with bounded memory, and prefetched early without
  violating existing ride-message latency;
- safety preemption can meet the 100 ms firmware-API-to-audio-start target;
- the selected cache allocation preserves the existing BLE crypto and map
  headroom gates; and
- any failed assumption updates this document and codec/cache contract before
  Slice 1.

Initial host result: the 160-frame independent-block prototype produces
26,416 bytes for three seconds and 70,416 bytes for eight seconds, including
its container. Thus the proposed 64 KiB dynamic asset ceiling cannot hold every
eight-second candidate. Keep the ceiling and fall back for oversized assets
unless measurements justify another codec/block size or an explicitly reviewed
budget change. Host decode speed and synthetic signal tests do not select the
production codec or satisfy the radio/acoustic/resource gates.

### Slice 1: generated protocol and priority audio foundation

Primary files:

- `protocol/ride-ble-contract-v1.json`
- `tools/generate_ride_ble_contract.py`
- `docs/ble-protocol.md`
- new `docs/spoken-directions-protocol.md`
- `ios-app/BikeComputer/RideShared/RideBLEProtocol.generated.swift`
- `esp32/lib/ble_navigation/ride_ble_protocol.generated.hpp`
- `esp32/lib/ble_navigation/ble_navigation.cpp/.hpp`
- `esp32/lib/speaker/speaker.cpp/.hpp`
- new `esp32/lib/speaker/spoken_audio_decoder.*`

Work:

- allocate characteristic/channel/capability/command constants in the JSON
  source and generate golden fixtures;
- add the speech characteristic with role-aware protected dispatch;
- implement cue/control/status parsers with fixed limits but keep capabilities
  off;
- add the ADPCM decoder and byte-exact host fixtures;
- refactor the speaker into separate safety/guidance admission and bounded
  preemption; and
- extend playback completion and diagnostics without changing legacy sound
  packets or preferences.

Acceptance:

- all current horn/bell/PWR tests remain source-compatible;
- guidance cannot fill or delay the safety queue;
- malformed or stale speech frames cannot reach the audio task;
- the Swift/C++ generated constants and binary fixtures match; and
- no speech capability is advertised without the later pack manager.

### Slice 2: resident Version A

Primary files:

- new `ios-app/BikeComputer/RideShared/SpokenDirectionsContract.swift`
- new `ios-app/BikeComputer/RideShared/SpokenCueScheduler.swift`
- `ios-app/BikeComputer/BikeComputer/Managers/NavigationEngine.swift`
- focused speech transport/pack manager files beside `BLEManager.swift`
- `ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift`
- `ios-app/BikeComputer/BikeComputer/Managers/DeviceTransferManager.swift`
- new `esp32/lib/spoken_directions/`
- `esp32/lib/device_transfer/`, `esp32/src/main.cpp`, and transfer dispatch
- new pack builder/trust generation under `tools/`

Work:

- implement and exhaustively test threshold/dedupe/lifecycle policy;
- add confidence-aware spoken classification without changing saved-route or
  visual maneuver semantics;
- build and sign the initial pack with provenance notices;
- add the fifth bounded HTTP handler and owner-only transfer mode;
- implement streaming verification, atomic activation, boot recovery, and pack
  status;
- integrate fresh DSTS/error-sequence admission, worker-owned cancellation,
  journal recovery, checkpoint byte verification, and speech-specific trust;
- implement manager lookup, fallback, cue admission, cancellation, and status;
- add per-device enable/volume/settings and install/repair UX;
- enable CAP2 bit 26 only when the complete runtime chain and active pack are
  healthy; and
- extend ride diagnostics with privacy-safe speech events.

Acceptance:

- “In 50 metres, turn right”, “Turn right”, and arrival work from resident
  assets with the phone offline after installation;
- repeated snapshots, reconnect, and acknowledgement retry do not duplicate a
  cue;
- reroute and cancellation cannot play old queued guidance;
- a pack install interrupted at every tested boundary leaves the old pack or
  no pack active;
- SD removal/swap and FFat fallback produce an accurate pack status;
- unknown locale/maneuver fails to visual-only or explicit English fallback,
  never a guessed direction; and
- both boards pass the exact-artifact Version A physical matrix before Slice 3
  is considered releasable.

### Slice 3: dynamic Version B

Primary files:

- new `SpeechRenderer`, `SpokenAssetEncoder`, `DynamicSpeechPrefetcher`, and
  `SpeechBulkFrameSource` iOS components;
- focused BLE speech-stream adapter and status decoder;
- speech manager/cache/transfer worker in `esp32/lib/spoken_directions/`;
- generated contract and protocol documentation; and
- settings for mode, system voice, and speech rate.

Work:

- implement deterministic render/convert/encode with limits and cancellation;
- add the rolling current-plus-three-step deadline queue;
- implement begin/query/data/commit/cancel/status, bounded credits, checksum,
  resume, and generation cleanup;
- integrate the lowest-priority pull source with the existing one-writer state
  machine;
- implement route-scoped dynamic cache and fallback resolution;
- enable CAP2 bit 27 only after cache/worker runtime initialization; and
- add background, resource, privacy, and transfer observability.

Acceptance:

- a full street-name instruction is resident before its prepare threshold in
  the ordinary test route;
- missing, late, cancelled, corrupt, or unsupported dynamic audio resolves to
  the matching generic phrase without delaying the cue;
- navigation/GPS/workout/control latency and disconnect rates stay within the
  Slice 0 baseline budgets during maximum dynamic transfer;
- reconnect resumes only incomplete future assets and never replays a past
  cue;
- route replacement removes old associations and prevents late commit; and
- foreground, screen-locked, and background-navigation matrices have explicit
  pass/fallback results on supported iOS versions.

### Slice 4: tuning, compatibility, and release hardening

- tune threshold constants from controlled riding evidence without changing
  cue identity semantics;
- tune guidance volume/limiting separately for 3.3 V 1.75 and 5 V-modelled
  2.06 gain paths while preserving the shared percent contract;
- add additional packs only with classifier, unit, signing, provenance, and
  both-board fixtures;
- run backward compatibility with old app/new firmware and new app/old
  firmware; unsupported speech remains absent rather than sent as legacy text;
- audit app restoration, owner replacement, factory reset, safe mode, SD swap,
  cache cleanup, and schema migration; and
- freeze the exact release contract and physical artifacts.

## Test and validation plan

### Pure iOS and shared tests

Add scheduler tests for:

- exact and skipped crossings for 50/100/200 m;
- speed-band selection and no mid-step bucket change;
- action before the runtime's 20 m step transition;
- first-fix near-action exception versus reconnect suppression;
- short steps, adjacent steps, GPS jumps, loopbacks, and duplicate snapshots;
- route generation/token replacement, cancellation, arrival grace, and
  generation wrap behavior;
- queue rejection, lost acknowledgement, reconnect, and app-restoration
  omission semantics;
- dynamic ready, late, corrupt, missing, cancelled, and fallback decisions;
- English locale gating and unknown maneuver behavior;
- the real MapKit adapter's default-to-straight and street-name substring
  cases, saved-route preview isolation, and provider expiry/deletion;
- no dependence on the truncated display instruction.

Add real BLE-adapter tests, not only shared policy tests, for dispatch-time
expiry, protected sequence ordering, cue/bulk priority, route-snapshot barriers,
credit stalls, pending ATT/RAK1 gates, same-peripheral reconnect callbacks,
terminal-phase readiness, and old-generation completion. Preserve the current
Watch shutdown/admission harness and motion freshness fixtures. Add transfer
tests for stale DSTS errors/status, cancelled attempts, and unrelated GPS
traffic that keeps the queue nonempty. Verify independent sound/speech settings.

Add renderer/encoder tests for buffer segmentation, end-of-stream, empty
output, unavailable voice, cancellation, resampling, mono mixing, clipping,
eight-second rejection, deterministic keying, and byte-exact ADPCM vectors.

### Firmware host tests

Add focused C++ suites for:

- cue/control/status binary parsing and Swift/C++ golden frames;
- active-token and monotonic-sequence dedupe;
- RCM1 replay, stale, busy, unauthorized, malformed, and resource-rejected
  results;
- semantic lookup, dynamic-first/resident-fallback resolution, and pack schema
  mismatch;
- safety queue reserve, guidance preemption, cancellation, completion reasons,
  and no-resume behavior;
- ADPCM normal, boundary, corrupt-header, truncated-block, frame-count, and
  limiter paths;
- transfer credits, offsets, duplicate chunks, gaps, resume, commit, digest
  mismatch, route cancellation, and partial cleanup;
- pack bounds, signature-domain separation, staging recovery, atomic active
  marker, full handler registration, and low-space rejection;
- activation-journal interruption and repeated recovery, equal-length SD
  checkpoint corruption, changed media, short reads, and production rejection
  of development/cross-domain keys;
- coherent speech snapshots under cancellation, worker cleanup after request
  unwind, socket lease withdrawal, and optional-allocation failure while
  required display buffers remain admitted;
- dynamic cache eviction and boot/owner/route cleanup; and
- privacy allowlist/denylist checks for every new diagnostic event.

### Repository and CI gates

At minimum, each relevant implementation head runs:

```text
python3 tools/generate_ride_ble_contract.py --check
ios-app/scripts/run-navigation-tests.sh
ios-app/scripts/run-ride-shared-tests.sh
ios-app/scripts/run-ride-diagnostics-tests.sh
ios-app/scripts/run-watch-online-navigation-tests.sh
ios-app/scripts/run-watch-offline-navigation-tests.sh
cd esp32 && PYTHONPATH=tools python3 -m unittest discover -s tools/tests
cd esp32 && python3 tools/build_firmware.py WAVESHARE_AMOLED_175
cd esp32 && python3 tools/build_firmware.py WAVESHARE_AMOLED_206
```

These are repo-root commands, each run independently. For any build/device
work, first follow the current `AGENTS.md` device-confirmation requirements.
Use the locked firmware runtime and attested wrapper; raw `pio run`, ambient
toolchains, or another worktree's cache are not substitutes. Record the exact
source/profile and final ELF/image/linker-map provenance. iOS compile checks
use `ios-app/scripts/xcodebuild-cli.sh`, not direct `xcodebuild`.

Current automatic PR/main firmware CI builds only the 1.75 ordinary and
production profiles. A green aggregate `CI Gate` does not validate 2.06.
The implementation release gate requires separate exact-head 2.06 ordinary
and production builds as well; use the documented manual firmware scope when
explicitly requested, or the all-board release qualification workflow. Extend
CI path selectors for the new speech library, pack tools, trust inputs, and
fixtures so these changes cannot skip relevant jobs. Compile all new host
binaries with warnings as errors. Add a deterministic pack-builder
fixture whose complete stream hash, decoded frame counts, signature envelope,
and firmware install result are checked in CI.

`run-navigation-tests.sh` already invokes durable-map-attempt and saved-route
checks; keep those regressions intact and serialize runs across worktrees
because several host outputs use shared temporary paths. New focused speech
tests must be wired into the aggregate scripts/workflow, not merely documented
as standalone commands. This documentation update runs no firmware builds,
hardware actions, or manual CI dispatches.

When implementation reaches physical validation, use the then-current repository
device workflow, identify the board and stable serial, and record the intended
environment and artifact SHA before flashing. This document is a plan and does
not record a physical validation pass.

### Exact-artifact physical matrix

Run from one final source SHA and record app build, firmware environment,
artifact hash, board model, stable serial, iOS version, pack ID/version, SD or
FFat backend, and route fixture.

On both `WAVESHARE_AMOLED_175` and `WAVESHARE_AMOLED_206`:

1. install, verify, replace, and power-interrupt the resident pack on FFat and,
   where available, removable SD;
2. speak 50 m, 100 m, 200 m, left/right variants, U-turn, roundabout generic,
   action, Continue fallback, and arrival;
3. exercise short adjacent steps, starting near a turn, a skipped GPS fix,
   route crossing, reroute, user cancel, BLE disconnect/reconnect, app
   background, screen lock, and device reboot;
4. request PWR honk and every app horn/bell at the start, middle, and end of a
   long sentence, measuring request-to-safety-audio latency and confirming the
   sentence does not resume;
5. run navigation, route geometry, one-Hz GPS, workout telemetry, and dynamic
   prefetch concurrently; compare queue high-water, write/application-ack
   latency, GPS age, disconnects, and firmware resource minima with Slice 0;
6. render and prefetch current plus three upcoming full instructions, including
   a long street name, unavailable voice, corrupt transfer, and forced-late
   asset; verify the expected dynamic/fallback source each time;
7. render/map/audio simultaneously and inspect for underruns, map corruption,
   touch latency, watchdogs, storage errors, and audio glitches;
8. validate stationary, typical cycling, and controlled high-noise
   intelligibility without exceeding the board-specific accepted gain/limiter
   envelope;
9. run a representative two-hour route for thermal, battery, cache, filesystem
   growth, FFat write count, memory minima, and phrase timing; and
10. collect phone and firmware diagnostics before manual reconnect/reboot can
    erase volatile evidence.

Host success, encoder output, a green firmware build, BLE authentication, or
audible playback on one board does not imply this matrix passed.

## Diagnostics and privacy contract

Extend the existing typed ride-diagnostics schema with bounded events such as:

- scheduler decision: phase, semantic class, distance bucket, policy version,
  and emitted/suppressed reason;
- cue delivery: queue disposition, ATT/app-ack latency bucket, retry class, and
  completion result;
- pack: ID/version/locale/backend, validation result, and byte-count bucket;
- dynamic transfer: state, byte-count bucket, credit stalls, resume count,
  duration bucket, and stable failure code;
- audio: resident/dynamic source, start-latency bucket, preemption, underrun,
  decoder/output error, and queue high-water; and
- resources: bounded internal/DMA/PSRAM minima and storage latency/free-space
  buckets already permitted by diagnostics policy.

Reuse the current ATT evidence stages (`prepared`, `callingCoreBluetooth`,
`submitted`, `rejectedBeforeSubmission`) and cumulative queue counters through
a shared, privacy-bounded measurement adapter. Distinguish queue age, API-call
delay, ATT completion, application acknowledgement, and audio-start latency;
the existing renderer debug evidence is not itself a product speech schema or
proof of playback. Map/navigation orientation and Watch motion evidence must
remain in mixed-load trials with speech, not be disabled to improve results.

Forbidden fields include instruction text, rendered PCM/ADPCM, route/street
name, exact coordinates, voice utterance, route ID, raw route token, asset key,
owner/controller secret, BLE payload, transfer token, and exact private cache
path. If cross-device correlation is needed, create a random per-attempt
diagnostic ID rather than logging the text-derived asset digest.

## Compatibility and rollout

- Old firmware advertises neither bit and receives no speech frames. The new
  app keeps visual navigation and existing sounds unchanged.
- New firmware accepts all existing navigation, route, GPS, workout, settings,
  and sound packets unchanged. Speech is inactive until a compatible client
  negotiates it and a valid pack is active.
- A Version A app ignores bit 27 and receives no dynamic notifications it did
  not negotiate.
- A missing or downgraded pack clears runtime readiness but does not clear the
  rider's stored preference; the UI explains that repair is required.
- Pack schema and codec changes are additive. Firmware may retain more than
  one decoder only when flash/resource budgets and downgrade behavior are
  explicit; otherwise reject the incompatible pack before activation.
- Dynamic asset keys include the codec/schema so format upgrades cannot play
  stale bytes.
- No fallback sends speech commands as unauthenticated legacy navigation text.
- Roll out Version A first, inspect duplicate/stale/preemption/resource metrics,
  then enable Version B behind its separate capability and app mode.

## Out of scope

- Bluetooth Classic/A2DP or treating Bicino as an iPhone audio output;
- live PCM streaming at the moment a cue is due;
- phone-speaker playback or simultaneous phone/device speech;
- microphone input, speech recognition, intercom, or voice commands;
- arbitrary user-uploaded audio packs in the first release;
- direct-Watch dynamic synthesis/transfer;
- automatic translation of MapKit instructions;
- claiming non-English generic support from English substring parsing;
- changing the restored IceNav-derived renderer architecture or AMOLED full
  refresh strategy; and
- manufacturing Secure Boot/flash-encryption decisions, which require a
  separate provisioning plan.

## Definition of done

Issue #77 is implementation-complete only when:

- the implementation branch is a descendant of the then-current GitHub
  `main`, with the exact baseline and final head recorded;
- one generated contract defines speech UUID, channel, capabilities, commands,
  statuses, limits, and Swift/C++ fixtures;
- the scheduler uses runtime generation, step IDs, full instructions, and
  along-route threshold crossings with deterministic at-most-once behavior;
- user cancel, reroute, reconnect ambiguity, arrival, device reboot, and app
  restoration follow the documented lifecycle rules;
- safety audio preempts guidance within the measured target and guidance can
  never consume its queue reserve;
- a signed resident pack installs atomically, survives failure injection, and
  works offline on both supported boards;
- Version A passes both-board exact-artifact validation before Version B ships;
- dynamic speech renders, converts, encodes, prefetches, resumes, verifies,
  caches, triggers, and falls back without starving ride traffic;
- app foreground/background/screen-lock behavior has explicit tested results;
- every queue, frame, asset, manifest, cache, duration, and storage allocation
  is bounded and malformed input fails closed;
- current navigation, workout, ownership, transfer, map, speaker, diagnostics,
  iPhone, and Watch compatibility suites remain green;
- privacy tests prove that instruction and audio content never enter durable
  diagnostics or support exports; and
- the release record separates source, CI, installed-app, flashed-device,
  radio, audible, riding, resource, battery, thermal, and untested evidence.

## Sources and evidence limits

Repository observations are pinned to
[`ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157`](https://github.com/seichris/open-bike-computer/tree/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157).
Issue #77 remained open with no comments when checked on 2026-09-12. The
thresholds, cache limits, codec recommendation, pack format, and latency targets
in this plan are proposed engineering decisions. They are not measured product
performance or existing API guarantees.

[^1]: seichris/open-bike-computer, navigation sources at the recorded baseline:
    [NavigationRuntime.swift](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/ios-app/BikeComputer/RideShared/NavigationRuntime.swift),
    [NavigationEngine.swift](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/ios-app/BikeComputer/BikeComputer/Managers/NavigationEngine.swift),
    and [MapKitRouteAdapter.swift](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/ios-app/BikeComputer/BikeComputer/Managers/MapKitRouteAdapter.swift).

[^2]: seichris/open-bike-computer, audio and storage sources at the recorded
    baseline: [speaker.cpp](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/esp32/lib/speaker/speaker.cpp),
    [storage.cpp](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/esp32/lib/storage/storage.cpp),
    and [partitions.csv](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/esp32/partitions.csv).

[^3]: seichris/open-bike-computer, BLE contract and writer at the recorded
    baseline: [ride-ble-contract-v1.json](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/protocol/ride-ble-contract-v1.json),
    [BLEManager.swift](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift),
    and [NavigationWriteQueue.swift](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/ios-app/BikeComputer/BikeComputer/Utilities/NavigationWriteQueue.swift).

[^4]: seichris/open-bike-computer, HTTPS lifecycle at the recorded baseline:
    [device_transfer_http.hpp](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/esp32/lib/device_transfer/device_transfer_http.hpp),
    [device_transfer_http.cpp](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/esp32/lib/device_transfer/device_transfer_http.cpp),
    and [main.cpp registration](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/esp32/src/main.cpp).

[^5]: Apple Developer Documentation, [AVSpeechSynthesizer buffer rendering](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:))
    and [TN3136: AVAudioConverter — performing sample rate conversions](https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions),
    consulted 2026-09-12. These establish the rendering/conversion APIs, not
    measured Bicino background reliability or ADPCM compatibility.

[^6]: Apple Developer Documentation, [maximumWriteValueLength(for:)](https://developer.apple.com/documentation/corebluetooth/cbperipheral/maximumwritevaluelength(for:))
    and [canSendWriteWithoutResponse](https://developer.apple.com/documentation/corebluetooth/cbperipheral/cansendwritewithoutresponse),
    consulted during the August research. Runtime values and ready callbacks
    govern actual frame sizing and admission.

[^7]: Apple Developer Documentation, [Handling location updates in the background](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background),
    consulted during the August research; repository policy is in
    [CurrentLocationManager.swift](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/ios-app/BikeComputer/BikeComputer/Managers/CurrentLocationManager.swift).

[^8]: H. Schulzrinne and S. Casner, IETF, [RFC 3551 §4.5.1, DVI4](https://www.rfc-editor.org/rfc/rfc3551#section-4.5.1),
    July 2003, consulted 2026-09-12. This explains four-bit ADPCM and differences
    from IMA block packing; it is evidence that “IMA ADPCM” alone is an
    insufficient wire specification, not a proposal to add RTP to Bicino.

[^9]: Current firmware ownership primitives and integration ledger:
    [runtime_ownership.hpp](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/esp32/lib/utils/src/runtime_ownership.hpp)
    and [runtime fixes](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/docs/reviews/firmware-runtime-fixes-2026-09-07.md).
    HTTP lifecycle implementation is in note 4. Historical test counts in the
    ledger are not new validation of this plan or future speech code.

[^10]: Current durability implementations:
    [OfflineMapManager.swift](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/ios-app/BikeComputer/BikeComputer/Managers/OfflineMapManager.swift)
    (`SavedMapReplacementJournal`, `DurableMapDownloadCoordinator`),
    [map_stream_install.cpp](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/esp32/lib/map_transfer/map_stream_install.cpp),
    and [DeviceTransferManager.swift](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/ios-app/BikeComputer/BikeComputer/Managers/DeviceTransferManager.swift).
    These are existing map/transfer contracts to preserve or adapt, not an
    already implemented speech installer.

[^11]: Current build/trust boundaries:
    [AGENTS.md](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/AGENTS.md),
    [platformio.ini](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/esp32/platformio.ini),
    and [compiled map trust](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/esp32/lib/map_transfer/map_stream_compiled_trust.cpp).
    Speech-specific trust, profiles, and release gates remain proposed work.

[^12]: Current transport evidence is in note 3. Remaining adapter evidence
    boundaries are recorded in
    [Bluetooth reliability follow-ups](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/docs/plans/bluetooth-reliability-follow-ups-2026-09-07.md).
    Settings semantics are visible in
    [SettingsView.swift](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift)
    and the BLE facade in note 3.

[^13]: Current route ownership/classification sources:
    [PhoneRouteLibrary.swift](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/ios-app/BikeComputer/BikeComputer/Managers/PhoneRouteLibrary.swift),
    [NavigationRouteArchive.swift](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/ios-app/BikeComputer/RideShared/NavigationRouteArchive.swift),
    and [NavigationRouteContract.swift](https://github.com/seichris/open-bike-computer/blob/ce3c5a0cfa1c5bdd428197e71a15d3d3d7973157/ios-app/BikeComputer/RideShared/NavigationRouteContract.swift).
    This is the repository's provider-retention policy, not a new legal
    determination about MapKit audio or a grant to add persistent derived data.
