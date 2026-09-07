# Watch link host coordination regressions

Run from a complete repository checkout with a Swift 6 toolchain:

```sh
python3 ios-app/tests/watch-link-host/run.py
python3 ios-app/tests/watch-link-host/run.py --repeat 10
```

The existing `ios-app/scripts/run-ride-shared-tests.sh` also invokes this matrix
after its normal suite. This runner does not replace native platform builds or
that suite. It compiles in Swift 5 language mode, matching the source's supported
compatibility mode, using the installed Swift 6 compiler.

## What executes

The **full production WatchDeviceLink source and reducer** execute. A fixture
extension is appended in a temporary source file for private setup/inspection.
No production function is rewritten. Production demand, queue, acknowledgement,
preparation-persistence and restoration declarations are extracted from their
repository files instead of maintaining an alternate lifecycle implementation.
Changing or removing a declaration makes compilation fail rather than silently
falling back to a duplicate definition. The generated protocol is read directly.

CoreBluetooth/Combine/Security modules exist only inside the temporary host
build directory and are never included in an app target. Credential storage,
crypto sessions, navigation/workout value builders and WC admission outcomes are
test boundaries. The byte-level cryptographic protocol, real Combine delivery,
HealthKit, Apple SDK type compatibility, WCSession/outbox execution and radio
behavior are **not** validated. Nothing here installs or flashes a device.

A cancellation-aware manual clock drives deadlines. Test code controls delegate
order and lets scheduled tasks run without using wall-clock sleep to wait for a
failure. Repetition checks host stability; it is not physical soak evidence.
Fixture teardown cancels tasks and deletes isolated UserDefaults domains.

## Regression coverage

The matrix covers shutdown acknowledgement, missing acknowledgement/deadline,
write failure, failed connection, disconnect, radio loss, repeated completion,
and bounded missing-disconnect failure. Navigation-only, workout-only and
combined successor demand must replay on a new connection, never on the retiring
writer. Withdrawn successor demand must not reconnect. Each channel independently
holds connection demand after the other channel clears.

Terminal workout and navigation clear groups require exact application ACKs,
including ACK-before-final-ATT ordering; mismatched generations are ignored.
Late capabilities, lease, writer, discovery and restoration callbacks cannot
revive stopping/recovery. Old unsent preparation releases persist through
relaunch and cannot be overwritten by a successor prepare.

## Comparing an unchanged baseline

`--source-root OTHER_CHECKOUT --baseline` compiles the baseline adapter/reducer
with common fixed expectations; a nonzero test result is expected on the
reviewed baseline. The cases needing the new injected clock API are excluded.
The baseline run is not a suite expected to pass in ordinary CI.

`--contract-source`, `--generated-source` and `--preparation-source` are explicit
input overrides for an offline focused-source review. Normal CI must use the
repository defaults. The review bundle documents the blob-verified full files
and the separately transcribed contract slices used for its local run.
