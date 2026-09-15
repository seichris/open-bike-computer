# Durable download attempt tests

Run `python3 ios-app/scripts/run-durable-map-attempt-tests.py` from the repository.
The navigation runner invokes this automatically before its existing full suite.

The runner compiles the exact `DurableMapDownloadCoordinator` source, without
rewriting it, in the same Swift file as a private test extension. Controlled
URLSessionDownloadTask callbacks expose cancellation, retry, publication and
restoration boundaries deterministically. Real Foundation files and continuations
are used. The fixture stubs only unrelated app types and unsigned networking;
it does not model or replace the coordinator state machine.

Coverage includes stale cancellation, download/error/progress callbacks, exactly
once continuation completion, persistent terminal ownership, late cancellation
resume-data writes, background-event handoff, restored completion without an
in-memory waiter, corrupt ownership, and changed-host-policy resume rejection.

These tests run on macOS and Linux with Swift 6 strict concurrency. They do not
qualify OS background scheduling, iPhone process termination, signed map
installation, disk-pressure recovery, or real networking. The existing full
navigation/app suites and physical release gates remain necessary.
