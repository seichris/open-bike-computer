# Continue on iPhone — local review record (2026-11-17)

Local implementation on branch `claude/bicino-continue-iphone-9dfa5b`; no PR,
no push, no deployment, no device install. This file is the REVIEW.md record
until a PR exists.

## Source

- Base: `fdd47a55` (origin/main, includes PR #810 Fitness reconciliation).
- Head: the local commit that adds this record on that branch (not pushed).
  Every check below ran on the identical working tree before that commit,
  except this file.
- Not included: the parked partial-save patch in
  `~/.codex/worktrees/bicino-save-partial-watch-workout` (left untouched).

## Risk

High. Changes recorder ownership, the persisted owner record, recovery after
restart and the coordinator output that feeds the bike computer and Live
Activity. No BLE schema, firmware or backend change.

## Review

- Passes used: 2 of 3. Pass 1: independent read-only review of the complete
  diff. Pass 2: delta review of the fixes. State after pass 2: clean.
- Findings (all fixed and verified):
  - CIP-1 (P2) offer shown where the start gate always refused it
    (restart, HealthKit-active Watch session with no snapshot). Gate now admits
    an unidentified session only for a continuation.
  - CIP-2 (P2) `PhoneWorkoutRecorder.start` rebuilt the record from the
    request, overwriting Watch-part data stored during Health authorization.
  - CIP-3 (P2) relaunch before the iPhone start, with HealthKit returning the
    Watch's mirrored session, failed recovery forever.
  - CIP-4 (P2) failed-start rollback deleted the reservation before writing the
    Watch record back (possible "no recorder" state).
  - CIP-5 (P2) an unreadable handoff ledger could later be overwritten,
    dropping earlier entries.
- Active findings: 0.
- Accepted P3 notes: start failure after `startedAt` plus a failed restore
  write ends in the existing ambiguous-recovery path; a permanently corrupt
  ledger is never rebuilt and is re-read on each Watch update; a ledger removal
  made while unreadable can return (harmless while the restored Watch record
  holds that session).

## Checks (dirty working tree; no receipts signed or published)

- `ios-app/scripts/run-workout-recording-tests.sh`: ownership 314 assertions
  (was 285), coordinator 181 (was 109). New coverage: transient disconnect,
  stale data, pending end, explicit handoff, late Watch data during iPhone
  authorization, reconnect while recording, overlap after the iPhone start,
  Watch save, finish, relaunch with the finished ride, Done then late
  reconnect/save, provisional mirror reservation, relaunch before the iPhone
  start (HealthKit returning the Watch mirror), relaunch with an unidentified
  HealthKit-active session, failed iPhone start, failed restore write then
  retry, unreadable ledger, offer policy and combined arithmetic.
- Mutation check: reverting the CIP-1, CIP-3/4 and CIP-5 coordinator/policy
  fixes each fails the new tests.
- `tools/dev-check --level full` (19 checks): all passed, including Swift
  navigation map/sensors/workout/radio, workout contracts, Watch source-graph
  type-check, iOS and Watch simulator contracts (new XCTest
  `testFailedContinuationStartKeepsReservationForAtomicWatchRestore` passed)
  and Debug/Release iOS container builds. Report
  `development-checks/07187fbb-5a16-4be2-9735-44f435a0aa1c`; local results
  "dirty source cannot be reused".
- Unsigned generic iOS app build: succeeded.
- Not run: firmware or map checks (not selected; no inputs changed).

## Not verified (needs physical devices)

- HealthKit starting a primary iPhone session while the Watch's mirrored
  session (disconnected, or HealthKit-active without snapshots) is held.
- What `recoverActiveWorkoutSession` returns when both sessions exist; the
  real recorder's mirrored-recovery branch is modelled only by the fake.
- Bike computer accepting the new session token mid-ride with whole-ride
  totals; Live Activity switching sessions.
- The Watch's own behaviour when it returns (it keeps recording; the rider ends
  it on Apple Watch).

## Recovery

Revert the change; records written by this version stay readable by older
builds (the `continuation` key is ignored), but an older build would treat a
continued ride as a plain iPhone ride and could re-adopt the handed-off Watch
session after Done. App Store/TestFlight recovery is a new build, not a server
rollback.
