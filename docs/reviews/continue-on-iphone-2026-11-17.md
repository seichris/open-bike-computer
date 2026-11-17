# Continue on iPhone — local review record (2026-11-17)

Branch `claude/bicino-continue-iphone-9dfa5b`, published as
[PR #813](https://github.com/seichris/open-bike-computer/pull/813). This file
carries the REVIEW.md ledger; the PR description holds the exact current head,
its checks and the physical-device evidence.

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

- Passes used: 3 of 3.
  - Pass 1: independent read-only review of the complete diff at base
    `fdd47a55` (CIP-1..5).
  - Pass 2: delta review of those fixes; clean.
  - Pass 3 (2026-11-17, after publication at `d59ebfc8`): code delta since
    pass 2 was none (the commit only added this record); base delta to
    `f0304e2c` is one line in `.github/workflows/map-platform-image.yml`, no
    effect. Scope expanded only to the Watch-discard path, because the PR's
    physical test discarded the Watch workout after the handoff. Found CIP-6.
- State: **needs-rethink** under REVIEW.md, because pass 3 was not clean. CIP-6
  is fixed and verified by regression and mutation tests, but no review pass
  has confirmed that fix; a fourth pass needs explicit direction. The proposed
  narrower step is a confirming review of the CIP-6 delta only.
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
  - CIP-6 (P2, pass 3) a discard of the continued Watch workout on Apple Watch
    was absorbed as "recorded past the handoff", so the summary claimed the
    Watch's own Fitness workout keeps the data, and the Watch-part Fitness
    lookup repeated on every app activation. Trigger: handoff, Watch
    reconnects, rider discards on Apple Watch (the PR's device sequence). Fix:
    the discard is stored as a status-only Watch outcome (`discardedOnWatch`,
    optional so earlier records decode), counted totals stay, lookups stop,
    and the copy claims Fitness only after a Watch or Fitness save.
- Open defects: 0. Unconfirmed by review: the CIP-6 fix.
- Accepted P3 notes: start failure after `startedAt` plus a failed restore
  write ends in the existing ambiguous-recovery path; a permanently corrupt
  ledger is never rebuilt and is re-read on each Watch update; a ledger removal
  made while unreadable can return (harmless while the restored Watch record
  holds that session).

## Checks for CIP-6 (pre-commit)

- `ios-app/scripts/run-workout-recording-tests.sh`: ownership 316
  assertions, coordinator 185. New: a discard is status-only in the model and
  older records decode; the coordinator reproduces handoff then Watch discard
  (outcome stored durably, totals kept, summary reports the discard, lookups
  stop).
- Mutation check: removing the discard latch, or the lookup stop, fails these
  tests.
- Exact-head development checks and CI for the commit carrying this fix are
  recorded in the PR description, not here.

## Historical checks before publication (dirty working tree; no receipts)

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

The PR description records the 2026-11-17 stationary device test at
`d59ebfc8`. It does not cover the CIP-6 change. Still unverified:

- HealthKit starting a primary iPhone session while the Watch's mirrored
  session (disconnected, or HealthKit-active without snapshots) is held.
- What `recoverActiveWorkoutSession` returns when both sessions exist; the
  real recorder's mirrored-recovery branch is modelled only by the fake.
- Bike computer accepting the new session token mid-ride with whole-ride
  totals; Live Activity switching sessions.
- The Watch's own behaviour when it returns (it keeps recording; the rider ends
  it on Apple Watch).
- Watch battery shutdown, outdoor GPS/maps, firmware telemetry, Live Activity
  and a delayed Watch-save import (limits recorded in the PR).

## Recovery

Revert the change; records written by this version stay readable by older
builds (the `continuation` key is ignored), but an older build would treat a
continued ride as a plain iPhone ride and could re-adopt the handed-off Watch
session after Done. App Store/TestFlight recovery is a new build, not a server
rollback.
