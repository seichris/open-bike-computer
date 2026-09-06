# Bluetooth reliability reassessment — 2026-09-06

## Decision and scope

Keep the architecture delivered by PR #366. Fix the remaining shutdown and
readiness transitions before undertaking a larger transport refactor. The
highest-impact remaining issues are in Watch-direct lifecycle coordination,
with consequences for both Watch-to-Bicino and iPhone-to-Bicino reconnection.

This is an analysis and implementation plan, **not an implementation or a
physical-device qualification report**. This documentation PR changes no runtime
code. The three findings below remain open at the reviewed baseline.

- Reviewed GitHub `main`: `fe73e43431ed76c39159de7624c4cd9ede509434`
  (`Fix workout navigation controls and rerouting (#393)`).
- Review branch: `docs/bluetooth-reassessment-2026-09-06`, created in an isolated
  worktree from freshly fetched `origin/main`; unrelated checkout edits excluded.
  Main advanced from `9be1f51e1bb1946654e61e2d8b6dd60b60ccacdf` during review;
  the branch was rebased onto #393 after inspecting its navigation/coordinator
  delta. The BLE managers, Watch lifecycle, shared ride/workout contracts and
  firmware transport were unchanged; navigation/workout suites were rerun.
- Previous review baseline: `149b7589a2193f29bb3f34c67b08580d0f846d51`.
- [PR #339](https://github.com/seichris/open-bike-computer/pull/339) merged as
  `e94a07689b4d58645c75df300afc26820c330bb9` and
  [PR #366](https://github.com/seichris/open-bike-computer/pull/366) merged as
  `9ef7f09fce0e0d95e349e6ef9c54da137fcff286`, both on 2026-08-30.
  GitHub merge status and ancestry in the reviewed main were checked live.

Scope includes the iPhone owner controller, scoped Watch-direct controller,
WatchConnectivity handoff and workout forwarding, shared contracts and delivery
state, firmware authorization/lease/ACK handling, and newer acknowledged
GPS/renderer-diagnostic/transfer-status traffic. It is a focused source review,
not a claim of exhaustive security audit or real-radio fault reproduction.
Source links below are pinned to the reviewed SHA; revalidate against main
before implementing.

## What changed since the original review

The [original plan](bluetooth-connection-reliability-architecture-implementation-plan.md)
is useful historical design evidence, but its pre-merge status was stale. Do not
reimplement its findings as if PR #366 had never landed.

| Original item | Current source disposition | Remaining work |
| --- | --- | --- |
| BLE-001: dropped Watch phone-preparation attempt | Submission dispositions, stable preparation identities, persistence, response timeout/retry, availability callbacks and durable release outbox are present. | Close the shutdown path that never enters release: R1. Test successor preparation identities: R2. |
| BLE-002: ended/failed workout incorrectly cleared | `WatchWorkoutDeviceBridge` forwards `latestEnvelope` through `WorkoutDeviceForwardingStateV1`, retaining terminal state until an explicit idle boundary. | Preserve this in lifecycle fixes and test navigation/workout independence. |
| BLE-003: owner-only workout start sent to Watch | Firmware uses role-aware workout-start presentation; scoped Watch displays Start on Apple Watch instead of issuing the owner request. | Preserve role checks and legacy compatibility handling. |
| BLE-004: partial admission of critical groups | Watch uses bounded atomic groups, critical delivery tracking, application ACKs and resynchronization. | Do not clear a pending logical release merely because an ATT write completed. |
| BLE-005/006: absent/fixed three-second write watchdog | Shared policy exists: authentication 10 s, critical application write 8 s, transfer control 15 s, replaceable/other write 5 s; recovery is bounded. | Measure latency and callback loss before tuning. Retain deliberate disconnect/resync after ambiguous ATT completion. |
| BLE-007: duplicated/unisolated transport | Shared pure transport reducer and generated Swift/C++ contract exist; both managers are `@MainActor`. | Reducer and adapter readiness can still disagree: R2/R3. Extract incrementally, not a new stack. |
| BLE-008: exact-artifact physical qualification | Source/host evidence cannot close the physical release gate. | Complete and record a current-artifact two-controller matrix; see below. |

Relevant current implementation entry points:
[Watch handoff coordinator][wc], [Watch workout bridge][bridge],
[workout forwarding state][workout], [shared transport/watchdog][reducer],
[firmware workout-start role check][firmware-start], and [iPhone manager][phone].
PR #339's allocator, crypto-headroom and TLS diagnostics are already integrated;
this work must retain them rather than create another memory-hardening layer.

## Current architecture and boundaries

```text
Watch workout/navigation demand
  ├── phone-relayed workout → WatchConnectivity → iPhone BLEManager ─┐
  └── Watch-direct ride    → WatchDeviceLink ───────────────────────┤
                            │                                     ▼
                            └─ prepare/release → iPhone     Bicino BLE server
                               handoff coordinator         one writer lease
                                                          owner/scoped roles
```

WatchConnectivity coordinates yielding the phone; it does not confer firmware
ownership. Authentication, scoped permission checks and the device's lease
remain the authority. A connected peripheral is not equivalent to an
authenticated, leased, capability-compatible, writable transport.

The existing delivery design is appropriate: replaceable samples can coalesce;
critical clears/terminal state need atomic admission and application acceptance;
ambiguous transport failure needs a new connection generation and full state
resynchronization. An ATT completion and a device application ACK are different
events. Apple documents that write-without-response does not guarantee success;
keep application-level delivery semantics where state must be accepted.
[Apple writeValue documentation](https://developer.apple.com/documentation/corebluetooth/cbperipheral/writevalue(_:for:type:)).

The central remaining weakness is lifecycle ownership: the shared reducer,
published `state`, demand, preparation intent, write queues and several stop/retry
tasks are updated by separate branches in `WatchDeviceLink`. Main-actor isolation
prevents concurrent mutation, but does not make asynchronous event ordering
correct. R1 and R2 are examples of missing transitions, not data races.

## Open findings

Priorities: P1 = important ride/handoff outage to fix next; P2 = correctness or
structural reliability issue. Source-trace confirmation is distinguished from
executed reproduction. No finding below is claimed to have been reproduced on
physical hardware.

### R1 — P1: disconnect during graceful Watch stop skips phone release

**Trigger:** A direct Watch ride has prepared the phone and established a ready
BLE session. The last demand ends, `stop()` sends `LEASE_RELEASE`, and the
peripheral disconnects before its release ACK or the five-second completion
timer fires.

**Evidence:** [Watch stop and reset][watch-stop] resets demand at line 782 and
arms the timer. [didDisconnectPeripheral][watch-disconnect] calls
`resetTransport(keepingPeripheral: false)` at line 1987, which cancels that timer
and clears `gracefulStopPending`. With no demand, the callback returns idle at
lines 1988–1991. It never calls `completeStop()`, the normal path that invokes
`releasePhonePreparationIfNeeded()` at line 818.

The preparation remains a persisted **prepare**, not a release. The availability
callback retries a release only when `phonePreparationReleasePending` is true
([preparation availability][watch-availability]); this path never sets it.
On the phone, accepted preparation disables auto-reconnect and suppresses
discovery ([phone preparation][phone-preparation]). Its persistence has a 24-hour
expiry, so the problem is not necessarily permanent, but normal phone takeover
can remain suppressed after the Watch has stopped. Watch relaunch/restoration or
other explicit recovery may also release the orphaned preparation.

**Confidence:** confirmed source/control-flow defect; no adapter or radio
reproduction executed in this documentation task.

**Fix contract:** use one idempotent stop finalizer for release ACK, timeout,
disconnect and radio-unavailable paths. Capture the stopping session and
preparation identity before transport cleanup. With no successor demand, persist
and submit the matching release through the existing durable outbox even if BLE
has already disappeared. A normal disconnect during an active ride must retain
its demand/preparation and reconnect, not release the phone accidentally.

**Acceptance:** deterministic tests for all four completion paths, duplicate
callbacks, WC activation pending/unreachable, process relaunch with release
pending, and the control case of disconnect with active demand. Assert exact
preparation identity, durable intent and eventual phone auto-reconnect restoration.

### R2 — P1: new navigation demand during graceful stop can remain disconnected

**Trigger:** Start a navigation-only direct ride while the prior ride is in its
up-to-five-second graceful lease-release window; the old release then completes
normally by ACK or timeout.

**Evidence:** `stop()` moves the reducer to `.stopping` but leaves published
`state` ready ([stop][watch-stop]). New demand reaches `beginIfNeeded()`, whose
guard rejects work when `state.isReady` ([beginIfNeeded][watch-begin]). Meanwhile
`updateNavigation` stores the new snapshot and can enqueue against that still-ready
published state ([navigation updates][watch-updates]). `completeStop()` then clears
the transport queue, releases phone preparation and publishes idle, without
reconciling newly arrived demand. It clears `peripheral` before the later
disconnect callback, so that callback's identity guard cannot schedule recovery.

Navigation start/recovery sets demand, whereas subsequent location updates call
`updateNavigation` rather than repeatedly setting it
([WatchNavigationManager][watch-navigation], demand call sites around lines
224, 278, 290 and 410; location update around line 856). Thus navigation-only
demand can remain present with an idle transport until another demand/lifecycle
event occurs. Repeated workout updates may mask the bug; they are not a recovery
guarantee for navigation-only use. The latest snapshot is retained in memory,
but its queued delivery is discarded and automatic reconnection is missing.

**Confidence:** confirmed source/control-flow defect; no timed adapter or
physical reproduction executed.

**Fix contract:** represent demand arriving during shutdown as successor demand.
Finish or abandon the old session's release in a bounded way, then reconcile
current demand, prepare with a safe fresh identity when needed, reconnect with a
fresh generation and replay the latest state. A delayed old release must never
clear successor preparation. Do not resume ride writes on a lease already being
released; shutdown control writes need their own allowed path. Published readiness
must follow the authoritative transport phase.

**Acceptance:** stop then immediate navigation start, workout start, and combined
demand; finish by ACK, timeout and disconnect; radio off/on during the transition;
delayed old preparation/release replies; repeated stop/start. Assert eventual
ready or an explicit actionable error, correct latest snapshot replay, no stale
session writes, and no idle-with-demand state lacking scheduled progress.

### R3 — P2: same-generation late events can resurrect authoritative readiness

**Evidence:** [shared reducer][reducer-transitions] checks generation/auth/lease
for `capabilitiesAccepted`, but does not constrain the current phase before
setting `.ready`. `leaseAccepted` similarly lacks a phase guard, and
`writerChanged(.idle)` can overwrite a recovering writer without exiting the
recovering phase through a valid recovery transition.

A host probe compiled against the unmodified production reducer reproduced all
four counterexamples (owner phone and scoped Watch):

```text
ready → stopRequested → capabilitiesAccepted(same generation)
  result: becameReady, isReady=true
ready → failed(attTimeout) → writerChanged(idle) → capabilitiesAccepted(same generation)
  result: becameReady, isReady=true
```

The Watch capability handler acts on `becameReady`, publishes ready, starts a
heartbeat and enqueues full resynchronization ([capability handler][watch-capabilities]).
A delayed valid same-session capability response during shutdown can therefore
reactivate adapter work. This is not evidence of an authentication bypass or a
cross-generation replay attack. The pure reducer counterexample is proven; real
platform delivery of each ordering remains an adapter/hardware test requirement.

**Fix contract:** specify allowed events by phase. Initial capability acceptance
belongs in negotiation; a deliberately supported refresh in ready must be
idempotent. Reject readiness/lease resurrection in stopping, recovering and idle.
A late writer completion must not clear recovery. Adapters must honor rejected
transitions without starting heartbeat, replay or unrelated new failure cycles.
Retain stale-generation checks as an additional guard, not a substitute for phase
checks.

**Acceptance:** table-driven event-by-phase tests for both roles, stale and current
generations, duplicate capabilities/lease notifications, writer callbacks after
timeout, and valid happy paths. Add adapter tests with a late authenticated CAP2
while `LEASE_RELEASE` is outstanding and after writer recovery has begun.

## Implementation sequence and durable improvements

### Phase 1 — establish reproducible failures and lifecycle authority

- [ ] Independently revalidate R1–R3 on freshly fetched main. Record any finding
  invalidated by newer code before editing production behavior.
- [ ] Add the R3 failing reducer tests and small injectable seams for Watch BLE,
  WatchConnectivity submission and time. Test actual adapter transitions or an
  extracted lifecycle reducer that the adapter genuinely uses, not a parallel
  test-only model.
- [ ] Fix R1/R2 together as one shutdown/demand coordination change, including
  idempotent finalization, successor demand and preparation identity ordering.
- [ ] Fix phase guards and adapter handling for R3. Derive readiness from the
  accepted lifecycle state; keep the control-write path available during stop.
- [ ] Prove terminal workout summaries and critical clears still precede logical
  release, and active navigation/workout independently retain connection demand.

Exit gate: deterministic tests fail on the reviewed baseline and pass with the
fixes; existing suites remain green; no unbounded wait or retry is introduced.

### Phase 2 — make callback-order reliability maintainable

- [ ] Extend the existing shared reducer with explicit shutdown/recovery outputs
  and a documented event/phase table. Reconcile adapter connection-generation and
  reducer-generation responsibilities; do not simply delete one without tracing
  timers, peripherals, queued writes and application ACKs.
- [ ] Reduce `BLEManager`'s large facade incrementally by extracting handoff,
  write delivery and diagnostic coordination behind the existing public surface.
  Preserve `@MainActor` ownership. A one-shot iPhone/Watch transport rewrite is not
  required to fix these bugs.
- [ ] Add callback permutation/fault tests: ATT ACK before/after application ACK,
  late characteristic callbacks, missing write-without-response readiness,
  queue saturation, critical group partial transport, capability refresh, device
  switching, credential revocation and reconnect during renderer/transfer traffic.
- [ ] Preserve generated Swift/C++ protocol definitions and extend common golden
  vectors and malformed-frame tests when contracts evolve. Coordinate firmware,
  both apps and `docs/ble-protocol.md` for any wire change; no new wire version is
  inherently required for R1–R3.

The current shared host suite compiles contracts/reducer code, not
`WatchDeviceLink` ([test runner][ride-tests]). That explains why its success does
not validate the concrete stop/disconnect plumbing. Retain fast pure tests and
add adapter-boundary coverage rather than replacing either with hardware-only
testing.

### Phase 3 — observability and physical release qualification

- [ ] Emit privacy-safe transition diagnostics with controller role, reason,
  connection/lease generation, preparation correlation, queue depth and writer
  age. Record shutdown completion and successor-demand decisions. Do not log
  credentials, auth payloads or raw location/route data in routine telemetry.
- [ ] Measure connect/auth/capability/handoff/critical-ACK latency distributions,
  missing-callback counts, retry counts and queue saturation. Tune the existing
  5/8/10/15-second policy from these measurements; do not restore a universal
  three-second disconnect or retry ambiguous ATT writes on the same connection.
- [ ] Retain crypto/DMA headroom measurements during Wi-Fi/map transfer and BLE
  churn. Treat credential storage hardening, broader protocol fuzzing and energy
  budgeting as separate evidence-led workstreams, not newly confirmed defects.
- [ ] Publish an exact-artifact acceptance report linked from
  [Watch navigation validation](../watch-bicino-navigation-validation.md).

| Scenario | Required observation |
| --- | --- |
| iPhone-only navigation/workout, foreground and locked/background | Stable ownership; current state after reconnect; bounded recovery without losing terminal state. |
| Watch-direct navigation only, workout only, both | Independent demand, wrist-down/background behavior, correct role-specific UI, accepted critical clears. |
| Phone → Watch → phone, including unreachable WC and relaunch | No orphaned preparation, conflicting writers or stale release clearing a new preparation. |
| R1/R2/R3 event orderings | Stop resolves on ACK/timeout/disconnect/radio loss; successor ride makes progress; late callbacks cannot revive an old lease. |
| Queue pressure plus map/renderer diagnostics and transfer control | No writer starvation, ACK confusion, unbounded queue or lost critical state. |
| Out of range, radio toggles, peripheral reboot, revoke/re-enroll | Fresh authentication/generation, correct device selection, bounded retry and useful error state. |
| Representative two-hour mixed ride | Battery/thermal behavior, reconnect counts and DMA minima recorded, not inferred from host tests. |

Record firmware SHA/environment/hash, installed iPhone and Watch build identities,
device models and OS versions, timestamps, fault procedure and pass/fail evidence.
Qualify supported 1.75-inch and 2.06-inch boards as an explicit release activity;
do not infer the connected board or trigger 2.06 builds from this docs task.
No device build, installation, flash, reset or radio manipulation was performed
for this reassessment.

The reviewed validation documents do not establish a completed current-SHA
two-controller matrix. This is an evidence gap, not a claim that no individual
feature has ever been physically tested. Apple requires active WCSession for
transfers and recommends testing WatchConnectivity on paired devices;
host/simulator success cannot replace that gate.
[Apple transferUserInfo documentation](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferuserinfo(_:)).

## Validation performed for this reassessment

All results below concern the reviewed main SHA, not future fixes or installed
devices. Temporary probe/build outputs were outside the worktree.

| Check | Result and boundary |
| --- | --- |
| `ios-app/scripts/run-ride-shared-tests.sh` | Passed. Shared contract/reducer suite, not Watch adapter callback execution. |
| `ios-app/scripts/run-navigation-tests.sh` | Passed. Includes navigation/BLE protocol tests; opt-in live MapKit snapshot smoke test skipped by runner. |
| `ios-app/scripts/run-workout-contract-tests.sh` | Passed. Workout contract suite. |
| `python3 tools/generate_ride_ble_contract.py --check` | Passed; generated protocol synchronized. |
| Host C++ `test_ride_delivery_protocol`, `test_ride_controller_lease`, `test_scoped_watch_payload_policy`, `test_workout_telemetry_state` | Compiled with `c++ -std=c++17 -Wall -Wextra -Werror` and passed. Sources in `esp32/tools/tests/`. Not firmware builds. |
| Additional production-reducer counterexample | Reproduced R3 for both roles. This successful probe demonstrates a bug, not correct transport behavior. |
| Full iPhone/Watch app builds, full firmware builds, physical fault matrix | Not run in this documentation-only task. Required in implementation/release work as applicable. |

### Reproduce the reducer counterexample

Save the following as `ReducerProbe.swift` outside the repository. Compile it
alongside `ios-app/BikeComputer/RideShared/RideBLETransportStateMachine.swift`
using `xcrun swiftc <production-source> <probe> -o <temporary-executable>`, then run
the executable. These preconditions intentionally assert the **bad baseline**;
regression tests must invert them to require non-readiness/rejected transitions.

```swift
import Foundation

@main
enum ReducerProbe {
    static func ready(_ role: RideBLEControllerRoleV1)
        -> RideBLETransportStateMachineV1 {
        var value = RideBLETransportStateMachineV1(role: role)
        value.reduce(.beginConnection)
        value.reduce(.linkConnected(generation: 1))
        value.reduce(.authenticated(generation: 1))
        value.reduce(.leaseAccepted(generation: 1, leaseGeneration: 7))
        value.reduce(.capabilitiesAccepted(generation: 1, schemaVersion: 1))
        precondition(value.isReady)
        return value
    }

    static func main() {
        for role in [RideBLEControllerRoleV1.ownerPhone, .scopedWatch] {
            var stopping = ready(role)
            stopping.reduce(.stopRequested(generation: 1))
            stopping.reduce(.capabilitiesAccepted(generation: 1, schemaVersion: 1))
            print("\(role): stop then late capabilities, ready=\(stopping.isReady)")
            precondition(stopping.isReady)

            var recovering = ready(role)
            recovering.reduce(.failed(generation: 1, reason: .attTimeout))
            recovering.reduce(.writerChanged(generation: 1, state: .idle))
            recovering.reduce(.capabilitiesAccepted(generation: 1, schemaVersion: 1))
            print("\(role): recovery then late callbacks, ready=\(recovering.isReady)")
            precondition(recovering.isReady)
        }
    }
}
```

## Implementation handoff

Use this report as hypotheses plus evidence, not unquestionable instructions.
Recheck current main, reproduce the findings, fix confirmed R1–R3 with regression
tests and the minimum durable lifecycle extraction, and update this plan with
results. Preserve already merged reliability/security/delivery contracts. Stage
broader Phase 2/3 work separately when it is not necessary for those fixes.
Open an implementation PR with exact-head validation and explicit unexecuted
hardware gates; do not merge, deploy or flash without further authorization.

[wc]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/ios-app/BikeComputer/BikeComputerWatch/Managers/WatchConnectivityCoordinator.swift#L89-L134
[bridge]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/ios-app/BikeComputer/BikeComputerWatch/Managers/WatchWorkoutDeviceBridge.swift
[workout]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/ios-app/BikeComputer/WorkoutShared/WorkoutDeviceFrames.swift#L297
[reducer]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/ios-app/BikeComputer/RideShared/RideBLETransportStateMachine.swift
[reducer-transitions]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/ios-app/BikeComputer/RideShared/RideBLETransportStateMachine.swift#L173-L210
[firmware-start]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/esp32/lib/ble_navigation/ble_navigation.cpp#L706-L734
[phone]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift#L898
[phone-preparation]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift#L2508-L2581
[watch-stop]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/ios-app/BikeComputer/BikeComputerWatch/Managers/WatchDeviceLink.swift#L773-L865
[watch-disconnect]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/ios-app/BikeComputer/BikeComputerWatch/Managers/WatchDeviceLink.swift#L1973-L2000
[watch-availability]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/ios-app/BikeComputer/BikeComputerWatch/Managers/WatchDeviceLink.swift#L389-L414
[watch-begin]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/ios-app/BikeComputer/BikeComputerWatch/Managers/WatchDeviceLink.swift#L527-L540
[watch-updates]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/ios-app/BikeComputer/BikeComputerWatch/Managers/WatchDeviceLink.swift#L417-L430
[watch-navigation]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/ios-app/BikeComputer/BikeComputerWatch/Managers/WatchNavigationManager.swift
[watch-capabilities]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/ios-app/BikeComputer/BikeComputerWatch/Managers/WatchDeviceLink.swift#L1040-L1062
[ride-tests]: https://github.com/seichris/open-bike-computer/blob/fe73e43431ed76c39159de7624c4cd9ede509434/ios-app/scripts/run-ride-shared-tests.sh
