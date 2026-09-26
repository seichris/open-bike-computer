# Bluetooth data reliability implementation

## Scope and provenance

Implementation branch: `fix/bluetooth-data-reliability`, based on plan commit
`19b9ddb383f1592f53c2e9d230b7402d4f080a4d`, whose parent is reviewed GitHub main
`eaee846393a1cd44214e23d9d9088a5c193a6b49`. Work used an isolated checkout; the
primary working tree was preserved. The implementation fixes DATA-01 through
DATA-04 and delivers the first shared architecture and measured optimization
slice from the [plan](bluetooth-data-reliability-and-architecture-plan.md).

This addresses live display/transport outages and stale presentation. It does
not establish that saved workouts were being erased or that physical recording
is lossless. Workout persistence remains independent of the BLE display stream.

## Changes

| Area | Result |
| --- | --- |
| Source freshness (DATA-01) | Firmware retains source capture age separately from packet arrival. Map prediction uses capture time, including mailbox/UI delay. Repeated expired coordinates cannot restart convergence; new stationary fixes remain observations. Marker opacity and legacy Ride Stats expose stale/unknown GPS; unavailable speed is not a measured zero. Workout freshness and terminal summaries remain independent. |
| Startup retries (DATA-02) | Phone retries publish the current retained source within their navigation epoch. Stop/replacement cancels pending work; an already-fired retired callback cannot alter a successor. Publishing a heartbeat no longer reaccepts the source. |
| Clock semantics (DATA-03) | Shared field encoder and dispatch transform serve phone and Watch, including fallback, workout-only and replay. UnixTime is current dispatch time; sample age is anchored once and advances monotonically across queue delay/reconnect, saturating safely. Invalid/nonfinite inputs cannot trap or fabricate coordinates. |
| Active recovery (DATA-04) | Shared reducer models cancellation and timeout. Watch and phone publish an actionable blocked state after five seconds without a disconnect callback, retaining the connection fence rather than unsafely reconnecting. Real boundary/stop clears the deadline; retired timers cannot poison successors. Watch retains active demand and exact phone handoff identity. Phone warning appears in My Bike Computers. |
| Dispatch cost | Watch checks write readiness before plaintext dispatch transforms and protection, avoiding preparation/encryption while flow-controlled. |
| Route traffic | Unchanged replaceable route geometry is skipped against the last submitted plaintext for that connection. Pending replacement, critical clear and reconnect replay preserve their existing semantics. |
| Diagnostics | Existing rate-limited GPS checkpoints include source age availability/age and mailbox delay separately from packet gaps. No coordinates or credentials added. |

## Architecture boundary

`RideGPSPacket.swift` owns common byte encoding, source-age anchoring/cache and
final plaintext dispatch. The existing shared transport reducer owns the recovery
substate and common five-second policy. Platform adapters still own CoreBluetooth
identity, lifecycle effects, authentication and published UI state; source owners
still supply route/workout counters. This removes policy drift without combining
phone administrative authority with the Watch scoped credential.

No characteristic, capability, wire length, queue limit or ACK requirement changed.
Quality-v1 remains 36 bytes and negotiated; legacy remains 30 bytes from these
senders. Older senders without sample age update the retained marker but have
unknown freshness and disabled prediction. Older Watch builds still need an app
update to correct their clock field. Older firmware continues to exhibit its old
arrival-based presentation until updated. The existing 1.5/2.5-second prediction
windows and acknowledged-write preference are unchanged.

## Regression and measurement evidence

- Cross-language golden GPS bytes are read by the production Swift encoder test
  and firmware decoder/freshness/presentation test. The integration assertion
  keeps a 30-second-old source at 30.5 seconds after 500 ms mailbox/UI delay,
  exhausted rather than predicting as a newly arrived fix.
- Coverage includes age saturation/unknown age, invalid/future data, monotonic
  wrap and a backwards wall-clock correction, repeated stale observations,
  resumed/new stationary observations, invalid speed, latest startup retry and
  retired navigation epochs.
- The actual Watch adapter host fixture withholds cancellation callbacks, advances
  the injected clock, checks visible failure/fenced writes/retained handoff, then
  verifies a radio boundary recovers. A real disconnect before the deadline cannot
  fail a successor; repeated failures retain the recovery instruction.
- The actual phone manager host suite withholds ATT completion then cancellation,
  checks the five-second policy through an accelerated injected interval, no new
  ride writes, and a retired callback after a connection boundary. This exercises
  production manager/reducer/timer code with an injected transport endpoint; it
  is not a physical CoreBluetooth callback-loss reproduction.
- Synthetic route measurement: twenty identical navigation snapshots previously
  submitted twenty replaceable route writes; the adapter now submits one (95%
  reduction for this scenario). The regression also checks pending B superseded
  by A and reconnect replay. No radio, latency or battery improvement is claimed.

## Validation record

Results are recorded below after the final source is frozen. Host tests use
production paths with framework doubles where required. Native builds and
simulator runs are separate from device acceptance.

Pending final local results and exact-head CI.

## Remaining gates and deliberately deferred work

- Physical qualification remains pending separately for 1.75 and 2.06, phone and
  Watch, including background/wrist-down use, source loss, sustained riding,
  mixed-version appearance, handoff/reconnect and saved-workout finalization.
  No device install, flash, serial session or factory release is part of this
  implementation. Required connected-board clarification was requested before a
  local firmware build; no answer was available when the code was prepared.
- A missing disconnect callback is bounded by a visible safe fallback, not by a
  promise of automatic recovery. A real Bluetooth boundary is still required.
- Further lifecycle/readiness flag removal and a common outbound queue metadata
  model require incremental adapter-level migration. Existing identity, queue,
  stop, handoff outbox/tombstone and ownership tests remain the safety boundary;
  this change does not claim a new end-to-end WatchConnectivity restart proof.
- A negotiated epoch/sequence GPS extension remains optional and deferred.
  Quality-v1 cannot provide exact source duplicate/out-of-order identity. Timestamp
  equality is used only for sender age anchoring; coordinate equality does not
  identify a new physical sample.
- Cadence/write-mode/watchdog tuning, heartbeat protocol separation and broader
  queue/allocation changes need matched p50/p95/max latency, memory, radio and
  battery measurements. No unmeasured tuning is shipped here.
- A factory image, merge or deployment is not implied by these software results.
  Rollback should revert the compatible app/firmware slice together where feasible;
  reverting restores the original freshness/clock/recovery limitations.
