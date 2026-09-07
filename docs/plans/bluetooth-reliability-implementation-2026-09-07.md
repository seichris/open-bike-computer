# Bluetooth reliability implementation and bundle review — 2026-09-07

Status: implemented; local host, native platform and build checks passed.
After the local review, the user authorized committing, pushing and opening an
implementation PR. Merge, physical installation and flashing remain out of scope.

## Provenance and scope

- Repository: `seichris/open-bike-computer`.
- Review baseline: `fe73e43431ed76c39159de7624c4cd9ede509434` (#393).
- Branch: `fix/bluetooth-shutdown-recovery`; created from freshly fetched main.
- Analysis: [PR #418](https://github.com/seichris/open-bike-computer/pull/418),
  still open at `b263052c9f45231f2d98feaa70e4f3ec3b825c7b` when checked.
- Input archive: `bluetooth-reliability-implementation-bundle.zip`,
  SHA-256 `2f787ed01c969537fb53be143489207894d7cd331b9027e701a63b7ef314f005`.
- Supplied patch SHA-256:
  `caa5e48c0ba70395797a5d062e62b76ded3106648bd20593cf52e22b4c4000ac`.
- Archive paths/types and all supplied checksums were validated. The full
  baseline Watch adapter matches this checkout, and the patch passes
  `git apply --check` against the real main ancestry.

The archive was an offline implementation proposal made from a partial source
snapshot, not a Git branch that could safely be pushed. Its instructions, PR
draft and claimed test results were treated as review input, not authorization.
Only the reviewed source/test changes and reconciled documentation were applied.
The user's dirty primary checkout and the original archive remain untouched.

This report has a separate filename so it can coexist with the original
[analysis at its immutable PR head](https://github.com/seichris/open-bike-computer/blob/b263052c9f45231f2d98feaa70e4f3ec3b825c7b/docs/plans/bluetooth-reliability-reassessment-2026-09-06.md)
when #418 merges. Do not overwrite that broader analysis with a shortened
implementation report. Broader work remains in the
[follow-up plan](bluetooth-reliability-follow-ups-2026-09-07.md).

## Review results and finding ledger

Initial review: standard review-fix-loop, fix-local mode, sequential-local strategy, no agents,
P0/P1/P2 gate. Review covers correctness/recovery, adjacent iPhone integration,
authorization/privacy, test strength, packaging and repository policy.

Terminal state: **clean** for this local review's P0/P1/P2 gate after two full
review iterations. Ledger: four fixed+verified, zero active, zero invalidated,
zero user-deferred. This does not close CI or physical release qualification.
The pre-commit review base/head/merge-base were the SHA above. Runtime/test snapshot SHA-256
(14 paths, sorted; each path + NUL + content + NUL):
`3c09b11e89e68abaa452708eb9e9e0e9189de554bec7b82aa957c19975e3d7ba`.

| ID | Priority | Finding and disposition |
| --- | --- | --- |
| R1 | P1 | Stop followed by disconnect/radio loss can skip the matching phone-preparation release. Reproduced on unchanged main; patched adapter assertions verify release and durable identity. |
| R2 | P1 | Demand arriving during graceful stop can write on the retiring session and then remain idle without progress. Reproduced on unchanged main; patched matrix verifies successor demand/replay and fresh preparation. |
| R3 | P2 | Late current-generation capabilities/writer events can restore readiness during stop/recovery. Reproduced in the reducer and Watch adapter; fixed by phase checks and adapter handling. |
| B1 | P2 | Bundle incorrectly claimed the iPhone does not instantiate the reducer. Source search disproves this; corrected documentation/comment and included iPhone integration in verification. |

R1–R3 are host-verified fixes, not a claim of physical radio qualification. B1 is
a review-scope/documentation defect in the supplied bundle, not a newly discovered
runtime outage. No authentication bypass is alleged.

### R1/R2: one bounded shutdown with successor demand

`WatchDeviceLink` now derives shutdown state from the reducer instead of a
mutable `gracefulStopPending` flag. It captures the retiring preparation identity
and uses one finalizer for release ACK, release deadline, write failure,
connection failure, disconnect and radio loss.

Shutdown drains already-admitted groups, including application ACKs, then sends
`LEASE_RELEASE`. New snapshots remain in logical retained state; they cannot
enter the retiring writer. After actual disconnect or a radio boundary, cleanup
reconciles current demand and starts its successor without needing another GPS
or demand callback. Navigation and workout independently retain demand.

Release must be persisted and durably admitted before a successor overwrites its
identity. This also closes the bundle's additional unsent-release/relaunch case.
The unchanged WatchConnectivity coordinator admits releases to its local outbox
before activation; submission is not proof of remote receipt. Existing phone
device/preparation matching prevents an old release from clearing a new prepare.

The lease-release deadline is five seconds. A separate five-second cancellation
deadline produces an actionable error rather than reconnecting the same peer
while old cancellation callbacks remain ambiguous. Demand survives for a later
disconnect/radio event. Draining has existing per-write/application watchdogs;
the entire shutdown is not promised to finish in five seconds.

### R3: phase checks, with correct iPhone scope

Both production managers instantiate `RideBLETransportStateMachineV1`:
`WatchDeviceLink.transportStateMachine` and
`BLEManager.rideTransportStateMachine` (baseline line 1290). The supplied bundle's
claim to the contrary was incorrect.

The phone feeds begin/link/authentication/lease/capability, writer, failure and
disconnect events into it. Its owner happy path remains begin → link →
authentication → nonzero lease sentinel → capabilities; cleanup resets the
reducer before another connection. These valid transitions are preserved.
The new shutdown substates are currently driven by the Watch, not phone shutdown.

Phone flags such as `isNavigationReady` and capability side effects still have
separate adapter logic. A pure owner-role counterexample is therefore not proof
of every corresponding production iPhone behavior. This patch does not claim to
make all phone readiness/side effects reducer-authoritative. Retain that distinction
in future refactoring and fault tests.

Lease/capability transitions now reject terminal phases, writer callbacks cannot
erase recovery, and a new connection starts only from idle. The Watch adapter
ignores late setup/lease/capability callbacks in incompatible phases. A valid
duplicate CAP2 refresh cannot restart heartbeat/full replay or discard delivery.

## Preserved boundaries

- Owner/scoped authentication, firmware writer lease and permission checks.
- Generated Swift/C++ framing, capability bits and firmware crypto/DMA guards.
- Atomic bounded groups, critical state delivery, application-ACK identities,
  early-ACK buffering and bounded retry/resynchronization.
- Terminal workout summary retention and independent workout/navigation demand.
- Existing phone handoff/tombstone matching and WatchConnectivity outbox.
- Main-actor state ownership and production timeout durations.

Runtime changes are limited to the Watch adapter, shared reducer and exhaustive
Watch navigation-status switch. No firmware, crypto, credentials, wire format,
phone runtime or outbox implementation is changed.

## Verification evidence

Local toolchain: Apple Swift 6.3.3, arm64 macOS; adapter harness uses Swift 5
language mode. Framework doubles are built only in temporary test directories,
never added to the app project. Full repository sources supply the extracted
pure declarations; no offline source excerpts replace production files.

| Check | Current-run result |
| --- | --- |
| Unchanged actual-adapter baseline using full main sources | Expected failure: 19 cases, 111 assertions, 54 failures. |
| Patched actual-adapter matrix | Passed ten runs: 35 cases, 192 assertions, zero failures per run. |
| Complete shared ride suite plus integrated host matrix | Passed; unchanged shared suite also passed in a separate frozen baseline checkout. |
| Complete navigation/BLE protocol suite | Passed, including renderer and Catalyst checks. Runner skipped its opt-in live MapKit smoke test. |
| Workout contract suite | Passed. |
| Generated BLE contract synchronization | Passed. |
| Native Debug/Release iPhone + embedded Watch builds | Both passed using the repository wrapper and isolated DerivedData, code signing disabled. Final Debug refresh also passed. |
| iOS/watchOS platform contract suites | Both passed on local simulators, run sequentially. |
| Development/Release container verification | Both passed: iPhone, embedded Watch, complication and Live Activity. |
| Final adapter repeat, diff and local Markdown links | Ten more runs passed at the final runtime snapshot; whitespace and local links passed. |
| CI and physical-device matrix | Not run during local review; see the implementation PR for current CI. No physical device action authorized. |

The first attempted baseline shared-suite compile overlapped patch application
and reported that its input changed during compilation. That run is invalid,
not evidence of a baseline or patch defect. Baseline verification is repeated
in a separate frozen checkout; only completed frozen-input results count.

Executed repository checks: `ios-app/scripts/run-ride-shared-tests.sh`,
`ios-app/scripts/run-navigation-tests.sh`,
`ios-app/scripts/run-workout-contract-tests.sh`,
`ios-app/scripts/run-workout-platform-tests.sh ios` and `watchos`,
`python3 tools/generate_ride_ble_contract.py --check`, and
`python3 ios-app/tests/watch-link-host/run.py --repeat 10`.
Native app builds used `ios-app/scripts/xcodebuild-cli.sh`, scheme
`BikeComputer`, Debug and Release, `generic/platform=iOS`, isolated
`-derivedDataPath` values and `CODE_SIGNING_ALLOWED=NO`.
Both `verify-development-container.sh` and `verify-release-container.sh` passed.
These are local results, not GitHub CI results or signed distribution artifacts.

Host tests execute the full production Watch adapter and reducer using a
same-file inspection fixture. Demand/queue/ACK/preparation contracts execute from
production declarations. CoreBluetooth, Combine, Security/crypto, credential
storage and payload builders are explicit doubles. Actual WCSession delivery
and full phone execution are not covered by that particular harness. Navigation
tests and native builds provide separate integration evidence, not real-radio
proof. Ten repetitions are not a physical soak.

## Remaining release work

Follow the [physical matrix in #418](https://github.com/seichris/open-bike-computer/pull/418):
exact firmware/app identities, confirmed board profile, phone/Watch handoffs,
lost ACKs, radio loss, background/relaunch, successor demand, queue pressure,
memory and energy/thermal evidence. Do not substitute historical #339/#366 CI
or any host result for installed-artifact qualification.

Use the repository Xcode wrapper. Before any firmware build/device action, obey
AGENTS.md's connected-device confirmation. Physical installation, flashing and
merging require further authorization. Publication was authorized after local
review; its PR checks are separate from the local evidence above.
