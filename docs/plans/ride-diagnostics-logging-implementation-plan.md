# Ride diagnostics capture and Mac export implementation plan

## Status and baseline

This document is the implementation plan and acceptance contract for the
ride-diagnostics delivery. The implementation branch starts from freshly
fetched GitHub `main` at commit `4630ce5f7b9c0ada7a1026e6b458508dfcbfb9d3`
(2026-08-19); the original dirty checkout is intentionally not used as the
implementation base.

The current baseline already provides useful pieces, but none of them is a
durable ride log:

- firmware developer profiles emit extensive USB serial diagnostics, while
  production profiles deliberately disable USB CDC and
  `FIRMWARE_DIAGNOSTICS`;
- boot diagnostics retain the previous boot stage and reset classification in
  RTC memory, but report it only to serial;
- ride-automation development builds emit the privacy-bounded schema-2 trace
  to serial once per second;
- the iOS `BLEManager` exposes only the newest 40 in-memory debug lines, and
  most other app diagnostics are unstructured `print` calls;
- authenticated BLE already controls the session-scoped local Wi-Fi transfer
  service used by maps, firmware updates, and opt-in remote debugging; and
- GPS packets already carry Unix time and periodically synchronize the device
  RTC, which gives the two recorders a useful clock anchor.

The implementation worktree was later reconciled with the subsequent
`origin/main` display-inactivity change before the feature commits were
published, while the original dirty checkout remained untouched.

## Outcome

During an ordinary ride, the iPhone and Bicino independently retain bounded,
local, privacy-safe diagnostics. After the ride, the rider can reconnect the
app, download any missing device chunks over an authenticated local transfer,
and export one integrity-checked support bundle to a Mac. A repository tool
validates that bundle and produces a single correlated timeline without
modifying the raw evidence.

The normal rider workflow should be:

1. Ride normally; standard logging is automatic on both sides.
2. Optionally tap **Mark Issue Now** when a visible problem occurs.
3. After the ride, open **Settings > Diagnostics** and tap
   **Download Device Logs** while Bicino is connected.
4. Tap **Export Support Bundle**, or connect the iPhone to a Mac and use the
   repository collector for a development build.
5. Run the Mac summarizer and debug against one ordered timeline.

No cloud service, account, telemetry SDK, or automatic developer upload is
part of this design.

## Product and safety decisions

### Two capture levels

**Standard logging** is always available and designed for normal developer and
production firmware. It records state transitions, errors, counters, freshness
and quality buckets, build identity, and resource-watermark summaries. It does
not record exact locations, addresses, route instructions, Wi-Fi credentials,
session tokens, owner keys, raw HealthKit values, or raw IMU samples.

**Detailed ride trace** is an explicit one-ride opt-in. It uses the existing
schema-2 ride-automation allowlist and one-Hz cadence, including only the
normalized policy inputs already approved by
`docs/ride-automation-traces.md`. It automatically stops at ride end, after
four hours, or when the rider disables it. Heart rate, power, exact
coordinates, addresses, navigation text, and raw sensors remain forbidden.

Standard logging must be useful on its own. Detailed mode is for reproducing
ride-detection, pause/resume, and intermittent-sensor behavior; it must never
become a prerequisite for diagnosing boot, BLE, map, navigation, storage, or
power failures.

### Application logging, not console capture

Do not redirect `Serial`, `stdout`, `print`, or the entire ESP-IDF/Apple
unified log into files. Those streams contain unstable text, can include data
that was never reviewed for persistence, and have profile-dependent volume.
Add an explicit structured recorder API and migrate selected diagnostic sites
to typed events. Developer console output may remain as a secondary sink.

### Independent recording and later correlation

The phone and device must keep recording when BLE drops. Neither recorder may
depend on a live forwarding channel. Correlation uses:

- an app process UUID;
- a random ride capture UUID created by the iPhone;
- the firmware boot sequence and firmware fingerprint;
- wall-clock UTC when available;
- monotonic uptime on each producer; and
- explicit clock-sync and reconnect marker records.

When an authenticated session is available, the app sends the current capture
UUID to the device. That command is idempotent and is resent after reconnect.
If a ride starts while disconnected, each side still records independently and
the Mac tool aligns the streams later using clock anchors and reconnect events.

### Bounded overhead and failure isolation

Logging must never block the LVGL owner, touch/BOOT input, BLE callbacks,
navigation writes, map rendering, audio, or storage used by map activation.
Every sink has a fixed queue and record-size ceiling. When overloaded, it drops
low-priority samples before lifecycle/error events and emits a later aggregate
drop counter. Logging failure is observable but never changes ride behavior.

## Shared event contract

Create a versioned schema document at
`docs/ride-diagnostics-format.md` and matching host-test fixtures. Each JSON
line has a strict allowlist and these common fields:

```json
{"schema":1,"source":"ios","sequence":42,"level":"info","category":"ble","event":"connected","wallTime":"2026-08-19T08:20:31.412Z","uptimeMs":381231,"processId":"...","captureId":"...","fields":{"rssiBucket":"good"}}
```

Firmware uses the same logical fields, with `bootSequence`, `firmwareFingerprint`,
and optional `wallTime`. Before RTC synchronization, the device writes only
monotonic time. A later `clock_anchor` event maps firmware uptime to UTC without
rewriting older records.

Contract rules:

- line length is bounded and a truncated final line is recoverable;
- category, event name, field names, and value types are enumerated;
- unknown fields fail host validation rather than being silently accepted;
- each stream has a monotonic sequence so gaps and drops are visible;
- capture UUIDs are random correlation values, not user or device identity;
- stable device identifiers are represented only by a per-install or
  per-export salted digest;
- errors use stable codes plus bounded, scrubbed descriptions;
- full payload bytes are never logged; record only message class, length,
  result, latency, and sequence/revision;
- every export retains original schema versions and raw chunks; and
- secrets and privacy-denied field names have a second explicit denylist in
  both Swift and Python validation.

Standard event categories should initially cover:

- app/firmware lifecycle and build identity;
- boot stage, prior reset class, safe mode, and ready state;
- BLE scan/connect/disconnect/authentication/capability negotiation;
- navigation start/stop/step revision/reroute outcome and queue health;
- GPS fix freshness, sample age, and accuracy buckets without coordinates;
- workout and ride lifecycle transitions without raw health metrics;
- ride-automation decision/acknowledgement/recovery state;
- SD/FFat mount state, write errors, and logger drops;
- map identity/revision, renderer errors, and bounded memory/render summaries;
- display/power mode transitions, battery buckets, PMIC warnings, and reset
  classification;
- firmware/map/device-log transfer lifecycle and integrity results; and
- user issue markers.

## iOS implementation

### Recorder and storage

Add a long-lived `RideDiagnosticsRecorder` owned by `AppDelegate` and inject a
small `DiagnosticEventSink` protocol into managers that produce events. The
recorder should serialize writes on one actor/queue and use an immutable event
value type so callers return immediately.

Store chunks below:

```text
Library/Application Support/BicinoDiagnostics/v1/
  app/<process-uuid>/manifest.json
  app/<process-uuid>/events-000001.jsonl
  imported-device/<device-digest>/<boot-sequence>/...
  exports/...
```

Requirements:

- apply `NSFileProtectionCompleteUntilFirstUserAuthentication`;
- exclude the diagnostic root from device backup;
- buffer small writes and checkpoint complete JSON lines at bounded intervals;
- rotate at 256 KiB so transfer/export can resume at chunk boundaries;
- retain at most 14 days, 20 ride captures, and 50 MiB, deleting the oldest
  closed captures first;
- preserve the active capture and the most recent pre-ride context;
- record retention, rotation, queue-drop, and disk-full outcomes;
- flush on background transition, capture end, and controlled termination,
  without assuming those callbacks always run; and
- tolerate one truncated tail line after a crash.

Keep `OSLog.Logger` as an optional secondary sink with private interpolation,
but make the application-support files the durable evidence. Replace the
current 40-line `BLEManager.debugEvents` implementation with a view over the
recorder's bounded recent-event projection so Developer Settings still works.

### Initial instrumentation sites

Convert high-value events first rather than mechanically persisting every
`print`:

- `BikeComputerApp.swift`: launch and scene/background transitions;
- `BLEManager.swift`: connection, authentication, negotiated capabilities,
  disconnect reasons, retry/backoff, write-queue stalls/drops, transfer state,
  and packet-class counters;
- `BikeComputerCoordinator.swift` and `NavigationEngine.swift`: route and
  navigation lifecycle, step/revision changes, reroute result, and rejected
  inputs, without names, coordinates, or instruction text;
- `CurrentLocationManager.swift`: authorization, update lifecycle, errors,
  source freshness, and accuracy buckets, without coordinates or addresses;
- `RideAutomationCoordinator.swift`: decisions, acknowledgements, recovery,
  configuration generation, and stable error codes;
- `WorkoutMirrorManager.swift` and `WorkoutMetricsStore.swift`: session state,
  origin, sequence, and delivery health, without health values;
- `DeviceTransferManager.swift`, `OfflineMapManager.swift`, and
  `FirmwareUpdateManager.swift`: session lifecycle, byte counts, receipts,
  retries, and stable errors, never credentials or tokens.

Add source tests that fail if known secret-bearing values are passed to the
diagnostic sink and update existing privacy-oriented tests when a field is
intentionally added.

### Diagnostics UI

Add a release-safe **Diagnostics** destination under Settings. Do not bury the
basic export behind `#if DEBUG`. It should show:

- recording health, retained size, oldest/newest timestamps, and dropped-event
  count;
- connected-device support and last successful device-log import;
- **Mark Issue Now** with an optional short predefined category, not free-form
  text that may collect private details;
- **Download Device Logs**;
- **Export Support Bundle**;
- **Detailed Ride Trace** with its scope, privacy notice, automatic expiry,
  and remaining time; and
- **Delete iPhone Logs**, with explicit confirmation and wording that
  already-exported files are unaffected and device-side chunks age out under
  their independent bounded retention policy.

The issue marker writes locally first, then best-effort sends the same marker
and capture UUID over authenticated BLE. The UI reports phone-marked and
device-marked status separately.

## Firmware implementation

### Persistent recorder

Add `esp32/lib/ride_diagnostics/` with:

- a fixed-size typed event model and formatter;
- a non-blocking producer API;
- a low-priority FreeRTOS writer task;
- bounded high/normal priority queues;
- chunk rotation, retention, and recovery;
- privacy/field allowlist enforcement; and
- counters exposed to BLE status and support bundles.

Use a new `PERSISTENT_RIDE_DIAGNOSTICS` build flag in the shared Waveshare base
so standard capture exists in developer and production profiles without
turning USB CDC or verbose `FIRMWARE_DIAGNOSTICS` back on. Remote framebuffer
debugging and renderer benchmark controls remain opt-in exactly as today.

Primary storage is the removable SD card:

```text
/sdcard/BICINO/DIAGNOSTICS/v1/
  boots/<boot-sequence>/manifest.json
  boots/<boot-sequence>/events-000001.jsonl
  boots/<boot-sequence>/events-000002.jsonl
```

Use 256 KiB closed chunks, a 4 KiB write buffer, and a conservative initial
retention ceiling of 32 MiB, 20 ride captures, or 14 days. Make these constants
host-tested and revise them only after physical power/storage measurements.
Retention deletes only closed chunks, oldest first, and never touches map or
firmware-transfer paths.

If SD is absent or becomes unwritable, retain only a small RAM/RTC fault
capsule containing the latest critical event codes, drop counts, active boot
stage, and reset classification. Do not silently format storage or use the
current FFat map fallback as an unbounded log volume. A later SD recovery writes
one `storage_gap` event with the missing interval and counters.

The writer:

- formats into fixed buffers with no unbounded heap growth;
- acquires the existing storage power lock only around actual I/O;
- batches writes and checkpoints at most every five seconds in standard mode;
- checkpoints immediately for ride end, safe-mode entry, storage failure, and
  controlled sleep/shutdown where safe;
- never calls storage from ISR, BLE callback, or LVGL context;
- records queue overflow and maximum queue depth;
- validates free space before starting/rotating a chunk; and
- recovers by ignoring a truncated last line and starting a new chunk after
  an unclean boot.

### Boot and crash evidence

Extend `boot_diagnostics` with a read-only snapshot API. `begin()` still runs
before peripherals, but once storage is mounted the ride recorder writes the
current `BOOT_META`, previous stage, reset reason, failure count, safe-mode
state, and firmware fingerprint as structured records. This preserves the
current early-boot safety behavior while making reset evidence available after
the ride.

The first delivery intentionally does not export raw ESP32 core dumps because
they can contain credentials, owner material, health data, and arbitrary RAM.
If reset classification plus the last structured events is insufficient, add
an independently reviewed, opt-in encrypted crash-dump phase with its own
partition and privacy threat model; do not quietly fold raw memory into the
support bundle.

### Firmware instrumentation

Start at state-owner boundaries rather than replacing every `Serial` call:

- boot diagnostics and `main.cpp` initialization stages;
- storage mount/recovery and map/firmware transfer errors;
- BLE connection policy, ownership/auth outcomes, capability negotiation,
  packet-class/gap counters, and disconnect cleanup;
- GPS freshness/quality state, workout lifecycle, and ride automation;
- map render revision/failure and bounded renderer/memory snapshots;
- display power, wake causes, battery buckets, PMIC warnings, and sleep entry;
  and
- unexpected task/queue failures and watchdog/reset classifications.

The existing one-Hz ride-automation JSON formatter can feed detailed mode
through the new writer instead of `Serial`, while developer serial output may
remain. Standard mode records transition decisions and aggregate evidence only.

## BLE correlation and capability contract

Add a new CAP2 feature bit and client version for persistent ride diagnostics.
Update all three protocol owners together:

- `esp32/lib/ble_navigation/ble_navigation.cpp` and `.hpp`;
- `esp32/lib/ble_navigation/device_capabilities_protocol.hpp`; and
- `ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift` plus
  `Utilities/NavigationProtocol.swift`.

Define fixed, versioned, authenticated binary control frames for:

- bind/rebind capture UUID;
- mark issue with a predefined code and sequence;
- end capture; and
- request diagnostic transfer status.

Frames must fit the protected transport's negotiated payload or use an
explicit bounded chunking contract. Replays, malformed sizes, unknown versions,
unauthenticated writes, stale capture IDs, and out-of-order marker sequences
must be rejected without changing recorder state. Do not add a second
unauthenticated BLE characteristic.

## Device-log download

### Transfer mode and HTTP API

Extend the existing generic transfer server with a mutually exclusive
`diagnostics` mode entered through authenticated BLE. Generalize the sensitive
hotspot policy so both `debug` and `diagnostics` sessions use a fresh WPA2
passphrase; continue to deliver the passphrase and HTTP bearer token only over
the authenticated BLE session. Reuse the trusted-LAN preference where
available, with hotspot fallback and token revocation on exit/disconnect.

Register a production-safe, read-only handler under
`esp32/lib/ride_diagnostics/ride_diagnostics_http.*`:

| Method | Route | Purpose |
| --- | --- | --- |
| `GET` | `/device-diagnostics/v1/index` | Bounded manifest of boot/capture chunks, sizes, hashes, and recorder health. |
| `GET` | `/device-diagnostics/v1/chunks/{boot}/{chunk}` | Download one closed immutable chunk. |
| `GET` | `/device-diagnostics/v1/active-tail` | Optional bounded snapshot of complete lines from the active chunk. |
| `POST` | `/device-diagnostics/v1/session/exit` | Revoke the transfer session after the response completes. |

Every route requires the existing transfer token, current transfer generation,
and `diagnostics` mode. Use strict path component parsing; never accept an
arbitrary filesystem path. Cap index entries and response sizes. Serve only
closed immutable chunks so a retry is byte-identical. A 256 KiB chunk is the
resume unit; the app verifies byte count and SHA-256 before recording its
watermark. The initial API has no remote delete operation.

### iOS downloader

Add `DeviceDiagnosticsTransferManager` beside `DeviceTransferManager`.
It should:

- require an authenticated connected device and negotiated capability;
- enter diagnostics mode and obtain a fresh status generation;
- join/probe the protected local transfer network using a fresh ephemeral
  `URLSession` with cellular, cookies, cache, and proxy routing disabled;
- fetch and validate the index;
- skip chunks already imported with the same hash;
- download one bounded chunk at a time to a temporary file;
- validate length, SHA-256, schema, privacy allowlist, and sequence ordering;
- atomically move accepted chunks into application support;
- retain partial progress only at verified chunk boundaries;
- exit the session and restore network state on success, cancellation, or
  failure; and
- never delete the device copy merely because the app imported it.

Map, firmware, remote-debug, and diagnostics transfers remain mutually
exclusive and use the existing transfer-busy error behavior.

## Support bundle and Mac tools

### Bundle format

Export one deterministic stored-ZIP file named like:

```text
Bicino-Diagnostics-20260819T082300Z-7f32c8a1.zip
```

Refactor the repository's existing stored-ZIP writing logic into a small
general utility rather than adding a third-party archive dependency or
duplicating ZIP code. The bundle contains:

```text
manifest.json
checksums.sha256
app/...
device/...
summary/recorder-health.json
```

The manifest includes schema versions, export time, app and firmware build
identities, source stream IDs, UTC/uptime anchors, chunk hashes, truncation or
drop counters, and the selected capture range. It must not contain transfer
tokens, Wi-Fi data, raw stable identifiers, addresses, coordinates, or health
values. Generate exports in a temporary protected directory, validate the ZIP
and hashes, then present it through the system share sheet. Clean temporary
exports after completion/expiry while leaving retained source logs intact.

### Repository tooling

Add `tools/ride_diagnostics.py` with:

- `validate <bundle>`: strict paths, ZIP limits, hashes, schemas, sequences,
  privacy denylist, and truncated-tail reporting;
- `summarize <bundle> --output <dir>`: immutable raw extraction plus
  `timeline.jsonl`, `summary.json`, and a concise Markdown report;
- `timeline`: merge by UTC anchors while retaining source uptime and showing
  uncertainty where a clock was not synchronized; and
- filters for category, level, capture UUID, boot sequence, and a time window
  around an issue marker.

Add `ios-app/scripts/collect-ride-diagnostics.sh` as a developer convenience.
It requires an explicit iPhone identifier and bundle ID, then uses
`xcrun devicectl device copy from --domain-type appDataContainer` to copy only
the diagnostic root. It must consume `devicectl` JSON output, validate the
result, and never guess among connected phones or erase the app container.
Support both `LetItRide.BikeComputer.dev` and `LetItRide.BikeComputer` only when
explicitly selected. The in-app share sheet remains the canonical path for
App Store builds.

## Delivery sequence

### Phase 1: contracts and host-testable stores

1. Land the format/privacy specification and JSONL fixtures.
2. Implement the Swift recorder, rotation, retention, recovery, and export
   manifest tests with temporary directories and injected clocks.
3. Implement the C++ formatter, queue policy, chunk policy, and recovery logic
   with host tests and fake storage.
4. Add Python bundle validation and timeline tests using mixed clocks,
   reconnects, dropped sequences, corrupt hashes, and truncated tails.

### Phase 2: app capture

1. Instantiate the recorder in `AppDelegate` and instrument app lifecycle.
2. Route `BLEManager`'s current debug events into the durable sink while
   preserving the bounded Developer Settings view.
3. Instrument navigation, location quality, workout/ride automation, and
   transfer state owners.
4. Add Settings > Diagnostics, issue markers, detailed-mode expiry, export, and
   local deletion.

### Phase 3: firmware capture

1. Add the persistent recorder task and SD chunk backend.
2. Export structured boot/reset snapshots after storage initialization.
3. Instrument BLE/navigation/map/power/storage owner boundaries.
4. Route the existing privacy-safe ride trace through detailed mode.
5. Enable only the bounded persistent feature in both ordinary and production
   board profiles; keep verbose serial and remote debug gates unchanged.

### Phase 4: correlation and retrieval

1. Add the CAP2 bit/client version and authenticated capture/marker frames.
2. Add the protected diagnostics transfer mode and read-only HTTP routes.
3. Implement resumable chunk import and verified watermarks on iOS.
4. Export one combined bundle and finish the Mac collector/summarizer.
5. Update `docs/ble-protocol.md`, firmware profile docs, privacy disclosures,
   and user-facing diagnostics documentation.

### Phase 5: validation and rollout

1. Run complete iOS, firmware host, workflow-policy, and bundle-tool suites.
2. Build ordinary and production firmware for both Waveshare targets and prove
   that remote-debug routes remain absent from ordinary/release ELFs while the
   new authenticated diagnostics capability is present as intended.
3. Perform physical power-loss, SD removal/full/corruption, BLE reconnect,
   background/termination, transfer cancellation, and long-ride tests.
4. Measure storage throughput, CPU, heap/PSRAM, BLE latency, map frame timing,
   and battery impact with logging off/standard/detailed on both boards.
5. Roll out standard capture first; keep detailed mode visibly opt-in until its
   battery and privacy acceptance gates pass.

## Verification matrix

### Automated

- schema round trips and forward-version rejection;
- privacy denylist rejects coordinates, addresses, credentials, owner material,
  raw health values, and raw sensor arrays;
- queue saturation retains critical events and reports exact drops;
- file rotation and all retention boundaries;
- recovery from a truncated line, truncated chunk, corrupt manifest, bad hash,
  duplicate sequence, and disk-full error;
- monotonic wrap handling on firmware;
- capture bind/marker replay, ordering, authentication, and reconnect behavior;
- transfer mode mutual exclusion and revocation;
- path traversal, oversized index, response bounds, and stale generation;
- downloader cancellation and verified chunk-boundary resume;
- deterministic export hashes and ZIP-bomb/path protections; and
- timeline alignment with synced, unsynced, and clock-correction streams.

### Physical device/app

For both 1.75-inch and 2.06-inch hardware:

- two-hour navigation ride with screen changes and intermittent BLE;
- ride beginning and ending while the iPhone app is backgrounded;
- device reboot during a ride, verifying prior stage/reset and post-boot
  continuation are both exported;
- iPhone force-quit/relaunch and capture rebinding;
- SD removal, full SD, and transient mount failure without map/UI deadlock;
- hard power loss during a chunk write with only the active tail affected;
- issue marker while connected and phone-only marker while disconnected;
- diagnostics download over trusted LAN and protected hotspot fallback;
- cancel/retry download and reconnect without duplicate imported chunks;
- app export through Share Sheet and Mac collection through explicit
  `devicectl` app-container copy; and
- detailed mode expiry at ride end and maximum duration.

Compare a logging-disabled control build, standard capture, and detailed mode.
Acceptance requires no perceptible UI/navigation regression and measured,
documented limits for battery, map-render timing, BLE write latency, queue
drops, storage rate, heap, and PSRAM. Do not infer physical success from green
host tests or a successful build.

## Acceptance criteria

The feature is complete only when:

- app and device continue recording independently through BLE loss;
- standard capture is automatic, bounded, and available in intended release
  profiles without re-enabling USB diagnostics;
- a reset during a ride leaves a recoverable prior-boot classification and log
  tail;
- one user action imports missing device chunks after reconnect;
- one export contains verified app and device evidence plus drop/truncation
  disclosures;
- the Mac tool validates and correlates the bundle without altering raw files;
- no forbidden privacy field or secret is present in fixtures, physical
  captures, or exported manifests;
- iPhone retention and explicit deletion work, and device retention prunes
  only the oldest closed chunks within its documented bounds;
- transfer authentication, revocation, path, and size boundaries pass
  adversarial tests;
- ordinary map, firmware update, navigation, workout, and remote-debug
  behaviors remain compatible; and
- both boards pass the defined long-ride, power-loss, reconnect, and measured
  resource-impact gates.

## Explicitly deferred

- automatic cloud upload or a support backend;
- raw coordinate, route instruction, address, heart-rate, power, or raw sensor
  recording;
- raw ESP32 core-dump export;
- continuous device-to-phone log streaming during a ride;
- remote deletion of device logs immediately after import; and
- using diagnostic firmware power measurements to claim production battery
  behavior.
