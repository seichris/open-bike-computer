# Bluetooth reliability reassessment — R1–R3 implementation record

Updated: 2026-09-07. Scope: review and implementation, not merge, installation,
flashing, or physical-device qualification.

## Baseline and independent reassessment

The analysis was read directly from unmerged PR [#418](https://github.com/seichris/open-bike-computer/pull/418),
head `b263052c9f45231f2d98feaa70e4f3ec3b825c7b`, plan blob
`d71f741e9d52fb739d830a24a342f1863cfdf9ae`. This document is the implementation
record at that plan's path; the original proposal remains available at its pinned
PR head. Broader work is separated into
[the follow-up plan](bluetooth-reliability-followups-2026-09-07.md).

Fresh GitHub main was checked before review and again before publication:
`fe73e43431ed76c39159de7624c4cd9ede509434`. It still equals the reviewed baseline;
there were no subsequent main fixes to subtract from R1–R3. PR #393's workout
navigation/rerouting changes are already in this baseline. PRs #339 and #366 are
merged; their existing code and validation history are not a validation result
for this implementation.

The reviewed production source blobs were independently hash-verified:

- `WatchDeviceLink.swift`: `a3117e3fb4224c0a23cd427844c7d296109aa83d`.
- `RideBLETransportStateMachine.swift`: `08b89bac91a3ec451c96e59c2f397f7d2a6d5154`.

An isolated Git worktree and implementation branch were created from the exact
main commit. Container DNS prevented ordinary Git clone/push. Source and Git
objects were fetched through the GitHub connector; the local worktree is sparse,
not a complete checkout. Publication uses a tree based on the original main tree,
replacing only this implementation's explicitly listed paths. No existing user
checkout or unrelated file is changed.

### R1 — confirmed: shutdown can orphan a phone preparation

At baseline, `stop()` retains the old preparation while waiting for
`LEASE_RELEASED` or its deadline. `didDisconnectPeripheral` calls
`resetTransport`, which cancels that deadline and clears `gracefulStopPending`
without going through `completeStop()`'s phone release. The phone-side preparation
can therefore remain active after the last Watch demand ended.

This is not an assertion of permanent phone suppression: the existing phone
policy expires it. The defect is loss of prompt, identity-matched release, not
absence of all eventual expiry.

### R2 — confirmed, with a path-specific qualification

The baseline published state can remain `ready` while the reducer is `stopping`.
A new navigation/workout demand is recorded but `beginIfNeeded()` returns because
of that published readiness. ACK/deadline completion then resets to idle without
reconciling the retained demand. A later unrelated update can mask the stall.

The baseline ordinary-disconnect path already schedules reconnect when demand
exists, and radio-on can restart it. Those paths must not be described as always
permanently stranded. They still bypass the common shutdown/preparation boundary.
Latest logical snapshots already survive the reset; the missing behavior is
correct scheduling and replay on a fresh, admitted successor connection.

### R3 — confirmed in the reducer and Watch adapter; phone claim narrowed

At baseline, lease/capability acceptance does not require an appropriate phase.
A same-generation writer-idle callback can also overwrite recovering writer
state. Deterministic reducer sequences produce `becameReady` after stopping or
recovery. Watch callback handling can consequently publish readiness, start a
heartbeat, and replay data at the wrong lifecycle boundary.

The reducer is parameterized for owner-phone and scoped-Watch roles, and the
counterexample reproduces for both role values. Source search and inspection only
identified a runtime reducer instance in `WatchDeviceLink`; `BLEManager` also uses
shared phase types, but this is **not** evidence of a reproduced iPhone adapter
failure. The implementation does not claim to repair or rewrite that separate
phone coordinator.

## Implemented lifecycle boundary

`RideBLETransportStateMachineV1` is the authority for readiness, callback
admission, recovery, and shutdown stage. Its stop stage is `releasingLease` then
`awaitingDisconnect`. The redundant `gracefulStopPending` flag is removed.
`WatchDeviceLinkState.stopping` is a UI projection, not a second state machine.
Existing connection/write identities and logical demand retain their separate
purposes; no wire generation or protocol schema was changed.

1. All explicit stop completions (release ACK, release deadline, disconnect,
   failed connection, radio loss, and defensive reset during stopping) handle the
   old phone-preparation identity before cleanup can cancel its completion task.
   Unavailable WatchConnectivity retains a persisted release intent. Successful
   submission keeps the existing durable-outbox ownership semantics.
2. Demand setters and snapshot updates keep the latest successor state but cannot
   prepare or write it on a stopping lease. Shutdown clears only connection-scoped
   bytes. Completion re-evaluates current demand and selection and starts a fresh
   connection/preparation, then normal readiness performs full logical resync.
3. Same-generation lease/capability/writer callbacks are phase-gated. Delegates
   honor rejected reducer transitions before publishing state or performing
   discovery. Late discovery errors cannot overwrite stopping/recovery. Duplicate
   ready CAP2 refreshes do not repeat heartbeat startup or replay.
4. The existing terminal-clear demand remains until the atomic group has both
   physically completed and received its application acknowledgement. The stop
   release is ordered behind already-admitted groups. No new ride groups enter
   during stopping. Application ACK processing remains available while an old
   admitted group is draining; it cannot restore readiness.

### Cancellation boundary and bounded failure

A lease ACK is not a CoreBluetooth disconnection callback. The successor cannot
reuse the same peripheral until cancellation has completed. Otherwise an old
cancellation callback, which has no logical attempt ID, can tear down its successor.

The existing five-second lease-release wait is retained. Cancellation has a
separate five-second bound. If that callback never arrives, the adapter preserves
demand, reports an actionable Bluetooth-retry error, and does not start an
unsafe overlapping connection. An actual disconnect or radio cycle can recover.
This is an explicit failure state, not an idle-with-demand stall; the extra bound
is not claimed to be physically tuned. Radio loss is itself a link-loss boundary.

Normal active-ride disconnect/recovery retains phone preparation and demand.
Credential revocation during a stop requests cancellation through the same stop
boundary rather than reusing the peripheral early.

## Regression tests and reproducibility

`ios-app/scripts/run-watch-device-link-tests.sh` runs the reducer matrix and the
complete production Watch adapter. `run-ride-shared-tests.sh` invokes it so the
existing native shared-test CI entry point also exercises adapter coordination.
The test files live under `ios-app/scripts/bluetooth-tests`, outside app targets.

The native adapter runner substitutes only the CoreBluetooth radio boundary and
an in-memory credential store; it compiles the real RideShared/WorkoutShared
contracts, authentication/session implementation, packet encoding, bounded atomic
queue, and application-ACK policy. Same-file test access is appended to a temporary
copy of the **whole** adapter. No lifecycle model or extracted lifecycle method
replaces production coordination. Authenticated ingress fixtures do not themselves
prove cryptographic interoperability; the existing shared-contract suite supplies
that separate coverage. Stop deadlines use an injected deterministic clock.

Coverage includes ACK/deadline/disconnect/radio completion; navigation-only,
workout-only and simultaneous successor demand; unavailable preparation submission
and relaunch; stale preparation response/failure IDs; latest navigation/workout
resync; independent demand withdrawal; late writer/CAP2/discovery callbacks;
readiness refresh idempotence; terminal ATT versus application-ACK ordering; active
ride recovery; and missing cancellation callback with radio-cycle recovery.

Commands on macOS:

```sh
ios-app/scripts/run-watch-device-link-tests.sh
ios-app/scripts/run-ride-shared-tests.sh
ios-app/scripts/run-watch-source-typecheck.sh
ios-app/scripts/run-navigation-tests.sh
ios-app/scripts/run-workout-contract-tests.sh
# Platform suites/builds must use repository scripts, including xcodebuild-cli.sh.
```

Portable reducer-only command:

```sh
ios-app/scripts/run-watch-device-link-tests.sh --reducer-only
```

### Local evidence — completed

- Original hash-verified production reducer reproduced all four stop/recovery
  counterexamples (two roles). Each incorrectly returned `becameReady`.
- Initial actual-adapter lifecycle matrix: **115 assertions, 53 failures on the
  baseline; 115 assertions, zero failures after the fixes**.
- Expanded adapter matrix: **150 assertions, zero failures** after the fixes.
- Production reducer permutation/identity matrix: **2,014 assertions passed**.
- Shell syntax checks passed for the changed test runners.

**Local limitation:** this Linux container lacks Xcode, Apple SDKs and CryptoKit.
The local whole-adapter runs used explicitly local-only leaf stand-ins for SDK,
wire and queue dependencies. They are useful counterexamples of the actual
adapter's coordination but are **not** native integration, cryptographic, packet,
or real-queue validation. Those stand-ins are not committed. The native runner
uses the real shared contracts instead. No local iOS/watchOS build, full platform
suite, firmware build or physical test is represented as passed.

### CI evidence — publication gate

The new native runner is wired into the existing shared-test script. Native
compilation, real-contract adapter execution, existing shared/navigation/workout
regressions, and the normal CI gate must be evaluated on the implementation PR's
actual head. Pending or unavailable checks are not passes. Historical #339/#366
CI results do not satisfy this gate. No manual 2.06-inch firmware job is requested.

### Physical evidence — not run

No iPhone, Watch or ESP32 was installed, flashed, or exercised. Before physical
qualification, record the exact app/Watch/firmware commits, signed build identities,
board/profile and OS versions. Run the separate follow-up matrix with explicit
user authorization; do not infer radio, background execution, memory, power or
battery behavior from host/CI results.

## Preservation and review boundaries

No firmware, generated BLE protocol, capability bit assignment, authentication
cryptography, scoped-controller authorization, lease wire format, RCM1/RAK1
format, retry budget, queue capacity, or acknowledgement identity policy changes.
#339's DMA/crypto/TLS protections remain untouched. The Watch writer changes are
limited to lifecycle admission and release ordering around the existing grouped
writer. #366's durable preparation/outbox and terminal delivery contracts remain
in place. Broader phone coordination, attempt-scoped delegate design, model-based
fuzzing and physical qualification are tracked separately rather than implied to
be solved by this patch.
