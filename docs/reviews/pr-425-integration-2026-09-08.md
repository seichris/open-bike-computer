# PR #425 current-main integration and attempt ownership

Reviewed main: `25b6352e69c39af66369743b57dd6f76c92c5e91`.
Original PR head: `8dcbc540b518a6d63e171160dea906bf8096c2e6`.

The branch integrates main without replaying an older stack. The confirmed
race was in `DurableMapDownloadCoordinator`: cancellation was keyed only by
artifact, while completion/error/progress callbacks could affect shared files
before the existing task-identifier check in `finish`.

## Fix

Each download has a UUID attempt identity persisted with the immutable artifact
constraints and active/cancelled/finished/failed phase. Each waiting invocation
has its own cancellation identity. A delayed cancellation from A cannot remove
or cancel B's waiter, and task/attempt identity fences all callback side effects.

All delegate work is serialized on the main actor by the session's main delegate
queue. Ownership verification, file validation and promotion happen synchronously
in that one callback, before URLSession invalidates its temporary download. This
avoids both the prior unguarded canonical-file write and an asynchronous temporary
file lifetime gap. Cancellation resume-data completions explicitly hop to the
same actor, verify persistent ownership, and are counted before background-event
handoff. Terminal records reject duplicate callbacks across coordinator relaunch.

Valid background completion without an in-memory waiter remains supported through
the persisted active owner record. Legacy tasks without attempt authority are
cancelled/restarted when a caller reconnects using a fresh authorized URL; they
are not blindly adopted. Existing completed immutable cache entries remain
usable and still undergo the caller's full digest/signature validation.

Opaque resume data is reusable only with the same immutable artifact AND the
same transport-host constraints, in a resumable terminal/cancelled phase. A new
host policy never silently resumes a request made under the old policy. The
storage sweep protects in-memory waiters as well as restored active tasks.

## Evidence and limits

`run-durable-map-attempt-tests.py` extracts the exact production class and compiles
it with controlled delegates and Swift 6 strict concurrency. The initial Linux
run passed 30 assertions covering A cancellation -> B retry -> every late A
callback; B progress and successful completion; duplicate terminal callbacks;
restored completion with no waiter; pre-registration cancellation; resume-data
ownership/host-policy checks; and corrupt-authority failure without a hung caller.
The runner is included in the existing full navigation suite; no previous test
or gate is removed. Fixture app-model stubs are not production networking tests.

Fresh full Apple-platform validation and the required exact-head PR CI must be
recorded separately after publication. This document does not claim those future
results. Real iPhone OS relaunch/background scheduling, storage exhaustion,
network transitions and device map installation remain physical qualification.
No hardware access, flashing, OTA, release or production deployment is authorized
or performed by this reconciliation.

## macOS validation and atomic staging

Integrated main `b082746e` in an isolated worktree. Completion now stages under
its attempt UUID on the destination filesystem and atomically renames only
while persisted ownership still matches. Failed staging retains the existing
completed artifact; successful promotion leaves no staging file. The storage
sweep also accounts for abandoned attempt staging files.

Passed locally: all 33 deterministic attempt assertions; full navigation suite
(including real delegates, saved-map replacement/migration and Catalyst preview);
unsigned Release iOS app/Watch container; backend 742 tests (2 existing skips);
catalog check with 66 tests, generated bindings/type/format checks and deployment
dry-runs; native stream format/install regressions using Mbed TLS 2.28.10.
The opt-in live MapKit smoke test was skipped. Debug app build and exact-head CI
are recorded separately. No OS-daemon, device or physical SD qualification is
claimed. Both-board hardware risk remains subject to the repository merge gate.
