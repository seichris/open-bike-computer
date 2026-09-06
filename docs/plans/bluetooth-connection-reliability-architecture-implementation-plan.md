# Bluetooth controller reliability and architecture implementation plan

## Current status — 2026-09-06

PR [#339](https://github.com/seichris/open-bike-computer/pull/339) and
[#366](https://github.com/seichris/open-bike-computer/pull/366) both merged on
2026-08-30 and are ancestors of the main SHA reviewed on 2026-09-06.
The [current Bluetooth reassessment](bluetooth-reliability-reassessment-2026-09-06.md)
reconciles the implemented work, documents remaining shutdown/recovery findings,
and defines follow-up implementation and physical acceptance gates.

The remainder of this document is preserved as historical design and pre-merge
implementation evidence. Its pending-merge/rebase/CI statements describe that
earlier snapshot, not current GitHub status. Do not treat the original findings
as still unimplemented or infer physical qualification from their software fixes.

## Historical status and baseline

Historical status: **deep-review repairs implemented in a local PR worktree; repaired-head
GitHub CI, post-merge rebase, and physical validation pending**. The original
PR #366 GitHub CI run failed before these repairs.

This plan turns the 2026-08-30 review of iPhone-to-Bicino and
Apple-Watch-to-Bicino Bluetooth behavior into an implementation and acceptance
contract. The planning branch starts from freshly fetched GitHub `main` at
commit `149b7589a2193f29bb3f34c67b08580d0f846d51`. The ordinary working checkout
was intentionally not used as the source baseline.

Implementation began in a separate clean worktree by applying the then-reviewed
[PR #339, Guard and measure DMA
headroom for BLE crypto](https://github.com/seichris/open-bike-computer/pull/339),
head `53ab44c6495dd30bbb6dec6d2c98de35b8ac8cf0` on top of the freshly fetched
`origin/main` baseline. This preserves its exact allocator, crypto-headroom,
TLS-diagnostics, and retained-error contracts while GitHub merge is pending.
PR #339 has since advanced to
`f43386a89968d8c01025f1a55330474403f6f683`, adding reduced TLS setup memory
and dynamic TLS record allocation. A synthetic merge of that current head into
PR #366 was clean during the deep review; PR #339 remains in hardware
validation and has not merged.
The implementation branch must still be rebased onto the final GitHub merge
commit before release validation; the stacked PR head is an integration
baseline, not evidence that PR #339 has merged.

After PR #339 merges:

1. fetch GitHub `main` again and rebase the implementation branch;
2. record the resulting main and PR #339 merge SHAs in the implementation PR;
3. rerun the focused source audit for every overlap in `ble_navigation.cpp`,
   `device_ownership.*`, `platformio.ini`, and `docs/ble-protocol.md`;
4. retain PR #339's accepted allocator settings, BLE crypto headroom guards,
   DMA/internal-memory counters, TLS diagnostics, and monotonic retained-error
   sequence; and
5. do not recreate or fork those facilities in this work.

PR #339's CI and build evidence do not substitute for its own required
physical gate. If it is merged before that gate is complete, this plan must
still describe its behavior as unvalidated on physical hardware until exact
artifact evidence exists.

## Outcome

The iPhone owner controller and scoped Apple Watch controller should each be
able to drive Bicino reliably, while remaining mutually exclusive at the
firmware. Handoff, reconnect, workout lifecycle, navigation lifecycle, and
critical state clearing must remain correct across backgrounding, temporary
unreachability, callback loss, queue saturation, process relaunch, and BLE
reconnection.

The rider-visible outcome is:

- iPhone-owned navigation and relayed Watch workouts do not disconnect merely
  because traffic bursts or one acknowledged write is delayed;
- a Watch-direct ride can reliably ask an idle iPhone to yield Bicino, even if
  WatchConnectivity was not ready on the first attempt;
- a direct Watch workout leaves the final Ride Stats summary on Bicino until
  explicit dismissal or a new workout;
- the Bicino **Start Workout** control never sends an iPhone-only request into
  a scoped Watch session or tears down Watch navigation;
- navigation clears, workout terminal snapshots, and lease release are never
  silently dropped under queue pressure;
- a lost CoreBluetooth callback cannot leave either controller permanently
  reporting Ready while all writes are frozen; and
- diagnostics explain which controller held authority, what was queued,
  whether firmware applied a critical command, and why recovery occurred,
  without logging private ride data or secrets.

## Current architecture

```text
Apple Watch -- HealthKit / WatchConnectivity -- iPhone
     |                                         |
     | scoped ride credential                  | owner credential
     | direct BLE                              | direct BLE
     +------------------+  +-------------------+
                        |  |
                 one active BLE central
                          |
                       Bicino
                          |
          firmware-enforced exclusive writer lease
```

The current security direction is retained:

- the iPhone owns registration, settings, transfer, rename, and deregistration;
- Watch receives a separate random scoped ride credential, never the owner key;
- both roles perform fresh mutual authentication and use protected per-channel
  AES-256-GCM frames;
- firmware allows one BLE connection and one controller lease at a time;
- Watch may write navigation, route, GPS, workout, and feature-gated ride
  automation only; and
- firmware remains the final authority when WatchConnectivity or either app is
  absent.

## Non-negotiable invariants

1. **One authoritative writer.** iPhone and Watch must never both believe they
   may write ride state. WatchConnectivity coordinates intent; the authenticated
   firmware lease decides authority.
2. **Independent lifecycles.** Workout failure must not stop navigation, and
   navigation or Bicino failure must not prevent a Watch workout from saving.
3. **No silent loss of critical state.** Clear, terminal, lease, enrollment,
   and controller-transition commands are admitted as complete groups or not
   admitted at all.
4. **ATT success is not application success.** A CoreBluetooth write response
   proves transport acceptance only. Critical work completes after Bicino
   confirms the logical command or after a generation-checked resynchronization
   proves the intended state.
5. **Idempotent recovery.** Retrying after a lost response must not duplicate a
   workout transition, revive stale navigation, or let an old release cancel a
   newer controller preparation.
6. **Generation-scoped callbacks.** Late CoreBluetooth, WatchConnectivity,
   timer, and retry callbacks from an older connection or request cannot mutate
   the current session.
7. **Role-correct protocol.** Firmware decides which notifications are valid
   for the authenticated role. Clients recognize every exact, valid notification
   they may receive and continue to fail closed on malformed or unknown data.
8. **Bounded work.** Every queue has explicit item and byte ceilings, reserved
   critical capacity, documented coalescing, and observable drops or rejection.
9. **Backward compatibility is explicit.** New application acknowledgements and
   Watch actions are capability-gated. Older owner apps and firmware retain the
   currently documented baseline rather than receiving ambiguous new payloads.
10. **Privacy and secrets remain out of diagnostics.** Never log owner or Watch
    keys, nonces, protected payload bytes, transfer credentials, exact GPS,
    route instructions, or raw HealthKit values.
11. **Evidence classes stay separate.** Host tests, CI builds, simulator runs,
    installed-app checks, and exact-artifact physical rides are reported
    independently.

## Findings that this plan must close

| ID | Priority | Current failure | Required end state |
| --- | --- | --- | --- |
| BLE-001 | P1 | Watch marks phone preparation locally before WatchConnectivity has delivered it; activation or reachability can drop the only prepare attempt. | A stable outstanding preparation survives retries and relaunch, is resent on usable WCSession transitions, and is complete only after a matching response. |
| BLE-002 | P1 | `WatchWorkoutDeviceBridge` converts `.ended` and `.failed` into idle after any active workout. | Direct Watch publishes ending/ended/failed state and retains the terminal summary until an explicit idle boundary. |
| BLE-003 | P1 | Bicino enables **Start Workout** for a scoped Watch session and sends `WREQ`; Watch treats it as invalid capability data and disconnects. | Owner-only requests are suppressed by firmware for Watch, and exact known legacy requests are harmless to Watch. |
| BLE-004 | P1 | Watch enqueues workout groups and navigation clears one frame at a time and ignores admission failure; lease release can follow incomplete state. | Critical groups are atomically admitted, fully tracked, resynchronized after partial transport, and acknowledged before logical release. |
| BLE-005 | P2 | A missing Watch `didWriteValueFor` callback leaves `writeWithResponseInFlight` set forever while state remains Ready. | One generation-scoped writer owns auth and ride writes, has a bounded watchdog, and performs idempotent recovery. |
| BLE-006 | P2 | iPhone disconnects the whole peripheral after one fixed three-second acknowledged-write delay on the shared ride queue. | Measured latency, bounded retry, application acknowledgement, and resync precede a full reconnect; policy is observable and tested. |
| BLE-007 | P2 | iPhone and Watch implement overlapping connection/auth/write/recovery behavior separately, while `BLEManager` has become a very large unisolated facade. | A shared pure transport state machine and platform adapters enforce the same lifecycle without a risky one-shot rewrite. |
| BLE-008 | Release gate | Direct Watch BLE, handoff, wrist-down recovery, and representative battery/thermal behavior remain incompletely validated on one exact current SHA. | The full exact-artifact hardware matrix passes after PR #339 integration and all transport changes. |

## Delivery strategy

Implement this as a sequence of independently reviewable changes. Do not hide
the P1 corrections inside the large `BLEManager` extraction, and do not wait for
the final refactor before fixing deterministic rider-facing failures.

### Slice 0: integrate the post-PR #339 baseline

Before Bluetooth code changes:

- rebase onto the GitHub main that contains PR #339;
- confirm the final `CONFIG_SPIRAM_MALLOC_RESERVE_INTERNAL` value and generated
  profile contract rather than assuming the reviewed 64 KiB value survived;
- confirm BLE crypto headroom rejection and operation-failure counters are
  present and distinguish expected invalid-tag rejection from engine failure;
- confirm retained transfer errors have a monotonic sequence;
- run PR #339's exact focused host tests and inspect its physical gate record;
- update this plan's implementation record with the actual merge SHA; and
- create no competing allocator, crypto-counter, or TLS diagnostic code.

Acceptance:

- the implementation branch is a descendant of the current remote `main`;
- all PR #339 contracts pass unchanged before Bluetooth behavior changes; and
- any physical result is tied to the exact firmware SHA, environment, artifact
  hash, board serial, and app build used.

### Slice 1: close the deterministic P1 behavior bugs

#### 1.1 Reliable Watch-to-iPhone preparation

Replace the implicit `preparedPhoneDeviceID` send-once behavior with a small,
pure preparation state machine. Suggested logical states are:

```text
idle
preparing(deviceID, preparationID, attempt, lastDisposition)
accepted(deviceID, preparationID)
releasing(deviceID, preparationID)
```

Requirements:

- create one preparation ID per logical direct-ride demand and retain it across
  retries;
- persist the ID with the active navigation/workout recovery identity so Watch
  relaunch does not invent a second preparation for the same ride;
- make `sendDirectRidePreparation` return a typed disposition such as
  `notActivated`, `notReachable`, `submitted`, or `encodingFailed`;
- do not mark the request delivered merely because a closure was invoked;
- retry the same ID after WatchConnectivity activation, reachability becoming
  usable, a matching request error, and bounded Watch BLE scan/connect cycles;
- implement `sessionReachabilityDidChange` and keep activation callbacks
  generation-safe;
- accept only the matching request ID, preparation ID, and DeviceID response;
- preserve the existing durable release and released-ID tombstones so a delayed
  prepare cannot yield the iPhone after its ride has ended;
- keep preparation coordination advisory: if the iPhone is absent, Watch may
  continue attempting the authenticated firmware lease rather than making
  WatchConnectivity a prerequisite; and
- make an iPhone's repeated accepted response idempotent.

Primary files:

- `ios-app/BikeComputer/BikeComputerWatch/Managers/WatchDeviceLink.swift`
- `ios-app/BikeComputer/BikeComputerWatch/Managers/WatchConnectivityCoordinator.swift`
- `ios-app/BikeComputer/BikeComputerWatch/WatchAppDelegate.swift`
- `ios-app/BikeComputer/BikeComputer/Managers/PhoneWatchConnectivityCoordinator.swift`
- `ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift`
- `ios-app/BikeComputer/RideShared/WatchControllerContract.swift`

Required tests:

- demand begins before WCSession activation, then activation resends;
- demand begins while unreachable, then reachability resends;
- app relaunch with a recovered ride retains the same preparation ID;
- lost accepted response causes an idempotent retry;
- release followed by delayed prepare remains a no-op on iPhone;
- an older response cannot complete a newer preparation; and
- iPhone-busy rejection remains visible and retries only under bounded policy.

#### 1.2 Preserve direct-Watch terminal workouts

Move the platform-neutral workout-to-device mapping out of the iPhone-only
relay and make iPhone relay and direct Watch use one semantic mapper.

Requirements:

- normalize both sources into one `WorkoutDeviceTelemetrySample` input;
- publish `.ending`, authoritative `.ended`, and authoritative `.failed` rather
  than converting them to idle;
- preserve final numeric values and current/stale semantics defined in
  `docs/ble-protocol.md`;
- keep direct BLE demand until the terminal group is confirmed or retained for
  reconnect recovery;
- use the existing protected-data/recovery boundary for any pending terminal
  record; do not introduce an unprotected raw HealthKit cache;
- send idle only after explicit summary dismissal, a new workout boundary, or
  the existing protocol reset rule; and
- keep navigation demand independent when workout demand ends.

Primary files:

- `ios-app/BikeComputer/BikeComputerWatch/Managers/WatchWorkoutDeviceBridge.swift`
- `ios-app/BikeComputer/BikeComputer/Managers/WorkoutDeviceRelay.swift`
- `ios-app/BikeComputer/WorkoutShared/WorkoutDeviceFrames.swift`
- `ios-app/BikeComputer/WorkoutShared/WorkoutContract.swift`

Required tests:

- running -> ending -> ended publishes terminal frames and no implicit idle;
- running -> failed publishes an authoritative failed state;
- final numerics remain visible on Bicino until explicit idle;
- ending without final numerics remains current but unavailable;
- workout end does not stop active navigation; and
- reconnect after terminal publication resends the retained terminal group.

#### 1.3 Make device-originated requests role-aware

Immediate behavior:

- firmware must read authenticated controller role before enabling or sending
  `WREQ`;
- if role cannot be read, fail closed and disable the action;
- owner sessions keep the current iPhone workout-start flow;
- scoped Watch sessions show disabled/noninteractive copy such as **Start on
  Apple Watch** until a dedicated Watch flow exists;
- Watch treats exact, known owner-only `WREQ` and `DREQ` payloads as ignored
  device requests, while malformed variants and unknown protected payloads
  remain fatal; and
- tests cover the UI enablement and notification decoder together so firmware
  and Watch behavior cannot drift independently.

Longer-term behavior may add a typed Watch workout-start request, but only with:

- a new capability bit and client version;
- a dedicated exact message type rather than overloading legacy `WREQ`;
- on-Watch user confirmation before HealthKit starts;
- acknowledgement or rejection back to Bicino; and
- no regression to the rule that a Watch workout continues independently of
  Bicino connection state.

Primary files:

- `esp32/lib/ble_navigation/ble_navigation.cpp`
- `esp32/lib/gui/src/rideTelemetryScr.cpp`
- `esp32/lib/gui/src/rideTelemetryLayout.hpp`
- `ios-app/BikeComputer/RideShared/WatchDirectBLEContract.swift`
- `ios-app/BikeComputer/BikeComputerWatch/Managers/WatchDeviceLink.swift`
- `ios-app/BikeComputer/BikeComputerWatch/Managers/WatchRideAutomationCoordinator.swift`

Acceptance for Slice 1:

- all BLE-001, BLE-002, and BLE-003 regression tests fail on the old baseline
  and pass with the change;
- direct Watch navigation cannot be disconnected by tapping the device workout
  control;
- an ended direct Watch workout remains visible until explicit idle; and
- Watch preparation recovers without changing firmware lease authority.

### Slice 2: create one reliable delivery pipeline

#### 2.1 Atomic command groups and QoS

Replace individual best-effort enqueue calls with a group-aware bounded queue.
Each group has:

- a logical command ID;
- controller/session generation;
- state generation;
- priority class;
- one or more characteristic payloads;
- replace/coalescing identity;
- critical versus replaceable disposition; and
- delivery/application state.

Required priority classes, highest first:

1. lease/auth/control and critical clear;
2. terminal workout and explicit lifecycle state;
3. maneuver or route replacement boundary;
4. live workout snapshot;
5. replaceable GPS and route-window state; and
6. diagnostics or other non-ride work.

Queue rules:

- reserve slots and bytes for at least one maximum critical group;
- admit every member of a group or none;
- check and handle every admission result;
- replace a pending group atomically, never frame by frame;
- coalesce route, GPS, and ordinary live workout snapshots to the newest state;
- bound ordered maneuvers by navigation generation and current step so a slow
  link cannot accumulate obsolete guidance;
- never evict a critical clear or terminal state for replaceable telemetry;
- if critical admission is impossible, retain the logical intent, declare the
  transport unhealthy, and reconnect/resynchronize rather than releasing;
- after disconnect, discard connection-scoped encrypted bytes and regenerate
  fresh protected frames from retained logical state; and
- record queue high-water, replacement, rejection, retry, and critical-wait
  metrics without payload content.

Use one shared pure queue contract for Watch and iPhone where their semantics
match. Platform-specific characteristic availability remains in adapters.

#### 2.2 One writer for auth and ride traffic

On each platform, one writer owns all calls to `CBPeripheral.writeValue`.
Heartbeats must not bypass it.

Writer states are conceptually:

```text
idle
waitingForWithoutResponseReadiness
waitingForATTResponse(writeID, deadline)
waitingForApplicationAck(commandID, deadline)
recovering(connectionGeneration, reason)
```

Requirements:

- exactly one acknowledged write is app-owned in flight;
- every timer and callback binds the peripheral ID, connection generation, and
  write ID;
- a late callback from an old generation is ignored;
- a watchdog operates after Ready as well as during connect/authentication;
- retry creates a new protected frame and sequence while retaining the same
  idempotent logical command ID;
- critical commands receive one bounded retry/resync opportunity before full
  reconnect;
- replaceable telemetry may be superseded rather than retried;
- auth heartbeat scheduling cannot overtake or deadlock a ride write;
- disconnect resets transport bytes but retains logical state that requires
  resynchronization; and
- Ready means authenticated, capabilities accepted, lease valid when required,
  and writer able to make progress.

#### 2.3 Application acknowledgement for critical state

Add a capability-gated, versioned protected ride acknowledgement contract.
The exact binary layout must be documented in `docs/ble-protocol.md` and share
Swift/C++ golden vectors. It must identify:

- command type;
- logical command ID;
- applied state generation;
- success, stale, busy, unauthorized, malformed, or resource-rejected result;
  and
- the current lease generation or controller-session identity needed to reject
  a stale acknowledgement.

Firmware sends an application acknowledgement only after the logical operation
has been accepted and made visible to the corresponding retained state. At
minimum this covers:

- navigation clear;
- workout core/extended terminal or idle group;
- explicit lease claim/release where current replies are insufficient; and
- future device-originated workout-start decisions.

High-rate GPS, route windows, and ordinary metrics remain replaceable snapshots
and do not require per-packet application acknowledgements. Their reconnect
contract is full latest-state resynchronization.

Firmware must treat duplicate command IDs idempotently and return the retained
result. Clients complete a pending release only after a matching success/stale
result that proves the intended state, or after authenticated resynchronization
reports an already-equivalent state.

Primary files:

- `ios-app/BikeComputer/RideShared/WatchDirectBLEContract.swift`
- `ios-app/BikeComputer/BikeComputerWatch/Managers/WatchDeviceLink.swift`
- `ios-app/BikeComputer/BikeComputer/Utilities/NavigationWriteQueue.swift`
- `ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift`
- `esp32/lib/ble_navigation/ble_navigation.cpp`
- `esp32/lib/ble_navigation/ble_navigation.hpp`
- `esp32/lib/ble_navigation/device_ownership.*`
- `docs/ble-protocol.md`

Required fault-injection tests:

- queue full with zero, one, and multiple replaceable entries;
- atomic two- and three-frame workout groups at every capacity boundary;
- clear admission while route/GPS/maneuver traffic is saturated;
- disconnect after the first physical member of a logical group;
- ATT response lost after firmware applied the command;
- application acknowledgement lost, duplicated, delayed, or reordered;
- heartbeat due while a ride write awaits response;
- old-generation callback after reconnect;
- lease timeout between admission and firmware application;
- malformed and unauthorized acknowledgement; and
- full resync replacing a retained terminal snapshot without exposing a
  partial pair.

Acceptance for Slice 2:

- no ignored queue admission result remains in the critical Watch paths;
- logical release cannot complete while its clear/terminal command is unknown;
- a lost Watch write callback recovers or reconnects within a bounded interval;
- retry never reuses an AES-GCM sequence or creates a duplicate state change;
- queue saturation cannot leave stale navigation/workout state behind; and
- firmware low-headroom rejection from PR #339 is surfaced as a typed outcome,
  not mistaken for a radio timeout.

### Slice 3: harden the iPhone transport and extract shared architecture

Do not replace `BLEManager` in one commit. Keep it as the ObservableObject/UI
facade and move behavior behind tested components in this order:

1. extract a pure connection/controller state reducer;
2. route all existing writes through the new writer and group queue;
3. extract Watch handoff persistence and policy;
4. extract ownership/enrollment orchestration;
5. extract map/firmware/admin transfer coordination; and
6. leave only published presentation state and compatibility forwarding in the
   facade.

Proposed boundaries:

- a platform-neutral `RideBLETransportStateMachine` in `RideShared` with no
  CoreBluetooth imports;
- platform adapters that translate CoreBluetooth callbacks into typed events;
- a `RideBLEWriter` actor per connected peripheral;
- a `ControllerHandoffCoordinator` for phone/Watch intent and persistence;
- existing ownership crypto and credential stores retained behind protocols;
  and
- explicit clock/scheduler/randomness injection for deterministic tests.

Actor and callback policy:

- mark the iPhone UI facade `@MainActor`;
- keep transport mutation inside one actor or the documented CoreBluetooth
  queue, never both implicitly;
- nonisolated delegate callbacks copy bounded data and immediately hop to the
  owner actor;
- no callback retains a mutable `CBCharacteristic` as application state without
  verifying peripheral and connection generation; and
- cancellation and teardown are idempotent.

#### Replace the fixed iPhone disconnect policy

The existing three-second acknowledged-write watchdog is retained initially as
an observation point, not silently replaced with another guessed constant.
Instrument privacy-safe latency and connection context, then define policy from
evidence:

- negotiated connection interval/MTU bucket;
- write class and byte-count bucket;
- queue depth/high-water;
- time to ATT response and application acknowledgement;
- app foreground/background and active workout/navigation flags; and
- recovery outcome.

The production policy must have documented minimum and maximum bounds. One
delayed idempotent write first receives bounded recovery/resync. Reconnect occurs
after transport progress is genuinely lost, auth/lease is invalid, firmware
rejects work, or bounded recovery fails. It must not retry non-idempotent legacy
commands blindly.

Acceptance for Slice 3:

- existing UI and settings call sites do not need a simultaneous sweeping
  rewrite;
- iPhone and Watch execute the same pure lifecycle fixtures;
- `BLEManager` public behavior remains source-compatible during extraction;
- Swift compiler isolation protects all mutable transport state;
- a delayed write has a typed recovery reason rather than immediate generic
  disconnect; and
- the workout-plus-navigation burst scenario has deterministic queue and
  watchdog tests.

### Slice 4: make the protocol and diagnostics durable

#### 4.1 Single protocol source

Introduce a versioned machine-readable BLE contract for constants and fixed
wire layouts. Generate or validate:

- service and characteristic UUIDs;
- protected channel IDs;
- client versions and capability bits;
- controller roles;
- exact command/notification magic values and lengths;
- acknowledgement enums and result codes; and
- Swift/C++ golden fixtures.

Human-readable lifecycle, security, compatibility, and recovery rules remain in
`docs/ble-protocol.md`; generation must not overwrite those explanations.
CI fails when generated Swift, C++, fixtures, and the documented constants are
out of date.

#### 4.2 Privacy-safe cross-device observability

Extend the existing ride-diagnostics path instead of creating another logging
system. Correlate iPhone, Watch, and firmware with a random per-attempt ID and
record only bounded metadata:

- controller role and state transition;
- connection generation and disconnect/recovery reason;
- prepare operation and result without stable device identity;
- queue counts, bytes, high-water, replacement, rejection, and critical wait;
- write class, size bucket, ATT latency, application-ack latency, and timeout;
- lease claim/renew/release/busy/expiry result;
- capability/schema versions;
- PR #339 crypto headroom rejection, engine failure, and DMA minima counters;
- workout/navigation state class without values, instructions, or coordinates;
  and
- resync start, completion, and rejected-generation counts.

Use salted device digests only where correlation truly requires one. Debug UI
may show the latest typed reason, while exported support bundles preserve the
independent iPhone, Watch, and firmware timelines and their evidence origin.

Acceptance for Slice 4:

- no protocol constant is manually duplicated without a CI check;
- production diagnostics can distinguish radio loss, ATT timeout, application
  rejection, lease contention, low crypto headroom, and intentional handoff;
- support bundles contain no denied secrets or ride payload data; and
- diagnostics failure never blocks BLE, LVGL, workout, navigation, or storage.

### Slice 5: exact-SHA release validation

#### Host and CI gates

At every implementation head, run the applicable existing suites:

```text
ios-app/scripts/run-navigation-tests.sh
ios-app/scripts/run-ride-shared-tests.sh
ios-app/scripts/run-watch-offline-navigation-tests.sh
ios-app/scripts/run-watch-online-navigation-tests.sh
ios-app/scripts/run-workout-contract-tests.sh
PYTHONPATH=esp32/tools python3 -m unittest discover -s esp32/tools/tests
```

Also run the CI-shaped firmware capability, controller-lease, scoped-payload,
workout telemetry, ride-automation, ownership/crypto, and new acknowledgement
host binaries. Build the complete iPhone and Watch source graphs with warnings
as errors where the existing workflow requires it. Run Swift concurrency
checking on the extracted state machine and adapters.

Add model-based tests that generate controller events across:

- phone connected, yielding, released, or reconnecting;
- Watch preparing, unreachable, scanning, authenticating, leased, or stopping;
- lease active, expired, revoked, or held by another session;
- navigation active/stopping and workout active/ending/terminal independently;
- callback loss and arbitrary legal delayed callbacks; and
- queue capacities from one through the production maximum.

The invariant checker must prove that two controllers are never both accepted,
critical release never completes with unknown state, and terminal workout state
cannot regress to live state.

#### Physical matrix

Before the first physical action in the validation thread, identify the
connected Bicino model and stable serial and obtain the required fresh
confirmation naming environment, artifact SHA, serial, and intended action.

Run the final matrix from one exact firmware/iPhone/Watch source SHA and record
artifact hashes separately from installed-device evidence:

1. iPhone owner pairing, reconnect, navigation-only, workout-relay-only, and
   simultaneous workout plus navigation;
2. start-navigation burst, reroute, foreground/background, Bluetooth toggle,
   and delayed acknowledged writes without unexplained disconnect;
3. Watch-direct navigation-only, workout-only, and combined ride with iPhone
   Bluetooth off;
4. Watch preparation before WCSession activation, temporary iPhone
   unreachability, iPhone busy rejection, accepted yield, release, and automatic
   phone reconnect;
5. Watch app suspension/relaunch, wrist-down GPS cadence, BLE disconnect,
   authenticated reconnect, and full state resynchronization;
6. device **Start Workout** interaction under owner, scoped Watch, and no
   authenticated controller;
7. ended and failed workout summary retention followed by explicit idle;
8. lease timeout, revocation, credential replacement, device reset, and stale
   callback/release resistance;
9. representative queue pressure while route, GPS, workout, and maneuver state
   change together;
10. PR #339 repeated authentication, acceptable DMA/internal minima, and zero
    unexpected crypto headroom rejection or operation failure;
11. both supported Waveshare environments unless a release explicitly excludes
    one with documented reason; and
12. representative two-hour ride battery and thermal measurement, including
    wrist-down Watch operation.

Phone, Watch, and device support bundles must be collected before a manual
reconnect or app restart can erase volatile evidence. A successful host build,
simulator run, framebuffer capture, or BLE authentication is not a physical
ride pass.

## Compatibility and rollout

- Ship new application acknowledgements behind a new firmware capability bit.
- New clients use the durable path only after capability negotiation; otherwise
  they retain current legacy behavior plus the role/terminal safety fixes that
  do not require a new wire contract.
- Firmware accepts existing owner navigation/workout clients and continues to
  deny scoped Watch settings/admin payloads.
- Do not copy iPhone OwnerID/OwnerKey to Watch, enable BLE bonding as a substitute
  for ownership v2, or weaken protected framing for compatibility.
- Keep a rollback path to the prior client behavior, but never roll back
  firmware ownership storage formats or PR #339 security diagnostics without a
  migration plan.
- Stage release telemetry review before broad rollout; investigate any increase
  in low-headroom rejection, application-ack timeout, reconnect, queue critical
  wait, or controller-busy rate.

## Production hardware-security follow-up

This transport plan does not claim resistance to invasive flash extraction or
malicious reflashing. Before a production SKU adopts that threat model, define
and validate a separate manufacturing profile for:

- NVS and flash encryption;
- Secure Boot;
- protected signing and encryption keys;
- controlled debug/download paths;
- OTA signing, rollback, owner reset, and recovery ceremonies; and
- factory provisioning and destruction of temporary credentials.

These eFuse and key-management operations are manufacturing decisions. They
must not be enabled incidentally by the Bluetooth implementation.

## Implementation record — 2026-08-30

The reviewed source implementation, including the local repairs recorded below,
closes BLE-001 through BLE-007 on the stacked PR #339 integration baseline. It
includes:

- a persisted, idempotent Watch-to-iPhone preparation intent with bounded
  retry, activation/reachability recovery, durable release delivery, and
  released-preparation tombstones;
- one shared workout-to-device mapper that retains direct-Watch ending,
  ended, and failed state until an explicit idle boundary;
- role-aware firmware presentation of device workout requests and harmless
  handling of exact legacy owner requests by a scoped Watch;
- bounded atomic iPhone and Watch write queues with frame and byte ceilings,
  critical reserve, coalescing, watchdogs, generation checks, and one physical
  CoreBluetooth writer per controller;
- capability-gated `RCM1` command groups and protected `RAK1` application
  acknowledgements for navigation clear and terminal workout state, including
  firmware replay, interleaving rejection, UI-application boundaries, and
  stale mailbox generation rejection;
- one pure transport reducer used by both iPhone and Watch adapters;
- a generated JSON-to-Swift/C++ BLE contract with CI drift checking; and
- privacy-bounded Watch forwarding and iPhone/firmware diagnostics for queue,
  ATT, application acknowledgement, lease, recovery, and PR #339 resource
  evidence classes.

Live GitHub integration status at the verification point:

- `origin/main`: `149b7589a2193f29bb3f34c67b08580d0f846d51`;
- PR #339: open, clean, mergeable, head
  `f43386a89968d8c01025f1a55330474403f6f683`;
- PR #339's current CI Gate and selected firmware/host checks: successful; and
- the current PR #339 delta merges cleanly into PR #366 in a synthetic review
  worktree. This branch must be
  rebased onto the eventual GitHub merge commit before release validation.

The original implementation run recorded local source evidence. The deep review
then reproduced three gaps exposed by the original GitHub run: a firmware
`VERSION` macro collision, a macOS-runner dependency on `rg`, and diagnostics
allowlist drift. It also found and repaired replay/admission, queued-route lease,
Watch relaunch preparation, and transactional queue-replacement defects.

The repaired local worktree passed this matrix on 2026-08-31:

```text
python3 tools/generate_ride_ble_contract.py --check
python3 -m unittest discover -s .github/scripts/tests -p test_changed_components.py
ios-app/scripts/run-navigation-tests.sh
ios-app/scripts/run-workout-contract-tests.sh
ios-app/scripts/run-ride-shared-tests.sh
ios-app/scripts/run-watch-source-typecheck.sh
ios-app/scripts/run-watch-online-navigation-tests.sh
ios-app/scripts/run-watch-offline-navigation-tests.sh
ios-app/scripts/run-ride-diagnostics-tests.sh
ios-app/scripts/run-workout-platform-tests.sh ios
ios-app/scripts/run-workout-platform-tests.sh watchos
PYTHONPATH=tools python3 -m unittest discover -s tools/tests
python3 -m unittest discover -s ios-app/scripts/tests
```

The selector suite passed 28 tests, the complete Python tools suite passed 74,
and the iOS script-identity suite passed 24. CI-shaped C++ ride-delivery and
diagnostics-format binaries passed with `-Wall -Wextra -Werror`; the delivery
binary also passed with a production-shaped `-DVERSION=...` macro. The full
watchOS workout platform suite passed again after the final Watch restoration
change. The full iOS workout platform suite passed on a complete rerun; one
earlier run had a single timing-sensitive failure in
`testDelayedEndingCannotConfirmOppositeTerminalRetry`, which then passed both
in isolation and in that complete rerun.

This evidence does **not** include a repaired exact-head PlatformIO firmware
build, a green repaired-head GitHub CI run, installation, flashing, radio
traffic, or the physical matrix. The repository requires connected-device
identity before a PlatformIO build or device action, and no device identity or
physical write authorization was requested for this review. Both Waveshare
environments, real iPhone/Watch handoff and background behavior, PR #339's
physical resource gate, battery, and thermal behavior therefore remain release
gates rather than inferred passes.

## Definition of done

This plan is complete only when all of the following are true:

- PR #339 has been integrated and its inherited contracts remain intact;
- BLE-001 through BLE-007 have deterministic regression tests and reviewed
  implementations;
- no critical Watch enqueue result is ignored;
- direct Watch ending/ended/failed state follows the shared workout contract;
- owner-only device requests cannot disrupt scoped Watch sessions;
- both controller writers recover from lost callbacks without stale Ready state;
- critical clears and terminal state have application-level confirmation or an
  equivalent generation-proven resync;
- iPhone and Watch share the pure transport lifecycle and queue invariants;
- privacy-safe diagnostics distinguish the principal transport and resource
  failure classes;
- current host, CI, iPhone, Watch, firmware, and protocol compatibility suites
  pass on the final exact head;
- the exact-artifact physical matrix passes with PR #339 resource gates; and
- the release record states all untested board, OS, provider, battery, and
  physical scope rather than inferring it from source or CI evidence.
