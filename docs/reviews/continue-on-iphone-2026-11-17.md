# Continue on iPhone — local review record (2026-11-17)

Branch `claude/bicino-continue-iphone-9dfa5b`, published as
[PR #813](https://github.com/seichris/open-bike-computer/pull/813) and merged
by seichris on 2026-11-17 as `cae11b2f` from head `92a49a75` (which contains
the CIP-6 fix). This file carries the REVIEW.md ledger; the PR description
holds the merged head's checks and the physical-device evidence.

## Source

- Implementation base: `fdd47a55` (includes PR #810 Fitness reconciliation).
  PR base at merge: `f0304e2c`.
- Implementation commit: `d59ebfc8`. Its pre-publication checks (historical
  section below) ran on the identical working tree except this file.
- Merged head: `92a49a75` (base-sync merge `fad208a5` + the CIP-6 commit).
  Merge commit `cae11b2f` has parents `f0304e2c` and `92a49a75`, and its tree
  `0cab7fdf` is identical to `92a49a75`'s, so evidence for `92a49a75` covers
  the merged tree exactly.
- Merge provenance: #813 was merged at 2026-11-17 18:17Z while this ledger
  recorded needs-rethink (pass 3 not clean). REVIEW.md expects such a change
  to stay unmerged until resolved. The confirming pass 4 ran afterwards, on
  that identical tree.
- Not included: the parked partial-save patch in
  `~/.codex/worktrees/bicino-save-partial-watch-workout` (left untouched).

## Risk

High. Changes recorder ownership, the persisted owner record, recovery after
restart and the coordinator output that feeds the bike computer and Live
Activity. No BLE schema, firmware or backend change.

## Review

- Passes used: 3 of 3, plus a fourth confirming pass that Chris explicitly
  directed on 2026-11-17.
  - Pass 1: independent read-only review of the complete diff at base
    `fdd47a55` (CIP-1..5).
  - Pass 2: delta review of those fixes; clean.
  - Pass 3 (2026-11-17, after publication at `d59ebfc8`): code delta since
    pass 2 was none (the commit only added this record); base delta to
    `f0304e2c` is one line in `.github/workflows/map-platform-image.yml`, no
    effect. Scope expanded only to the Watch-discard path, because the PR's
    physical test discarded the Watch workout after the handoff. Found CIP-6,
    fixed in `92a49a75`; pass 3 was therefore not clean (needs-rethink).
  - Pass 4 (user-directed, independent, read-only; it ran after the merge, on
    the merged code): scope limited to the CIP-6
    delta `fad208a5..92a49a75` and the code it depends on. Verdict: CIP-6
    resolved wherever the discard reaches iPhone (live mirrored snapshot,
    before or during the iPhone start, after finish before Done, after a
    relaunch once recorded); no P0-P2 regression. Clean.
    Evidence, on a scratch copy of `92a49a75` (no dev-check report; the
    reviewer ran the suite directly):
    - `bash ios-app/scripts/run-workout-recording-tests.sh`: ownership 316,
      coordinator 185 assertions passed.
    - Mutations: removing the discard branch in `absorbing` fails the
      ownership test; removing the discard condition from the Watch-part
      lookup candidate fails the coordinator test.
    - Uncommitted scratch scenarios passed: discard during the iPhone start,
      after the iPhone part finished but before Done, and after a relaunch
      once the discard was recorded.
- State: **clean** after the confirming pass 4. No further automatic passes.
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
- Active findings: 0.
- Accepted P3 notes: start failure after `startedAt` plus a failed restore
  write ends in the existing ambiguous-recovery path; a permanently corrupt
  ledger is never rebuilt and is re-read on each Watch update; a ledger removal
  made while unreadable can return (harmless while the restored Watch record
  holds that session).
- Accepted P3 notes from pass 4 (none block):
  - A Watch discard is reported once. If it arrives while launch recovery is
    still running, or its write fails, it is not recorded; the Watch-part
    Fitness lookup then continues until Done (as for a discard made while the
    app is closed, which predates CIP-6).
  - A discard during the iPhone start followed by a failed iPhone start
    restores the Watch record without the continuation (CIP-4 restore path).
  - The coordinator test's lookup-count assertion is weak on its own; the
    `canCheckFitness` assertion is what catches a removed lookup stop.
  - Copy: the discarded-part line says "last report from before the handoff"
    even when no Watch data was ever known (restart path); the "End that
    workout on Apple Watch" line can be stale after a Watch save iPhone never
    saw. Check Fitness stays offered in that case.
  - A rare `.failed` Watch session after a handoff (builder missing during the
    Watch's final save) is treated as recorded past the handoff, with lookups
    continuing, which is correct.

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
