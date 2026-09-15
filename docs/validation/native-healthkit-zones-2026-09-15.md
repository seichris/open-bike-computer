# Native workout zones — validation record

Date: 2026-09-15. PR: [#446](https://github.com/seichris/open-bike-computer/pull/446).

Implementation commit tested: `6a7012cb21639c8cff238e17ed078ce29966a523`.
Base: `85914afc147f8cbd336f5ef17cb8dbdc2fdf85a6`.

## Verified results

The [final validation run](https://github.com/seichris/open-bike-computer/actions/runs/34913855538)
checked out the implementation commit explicitly. Its `tests` job passed:

| Check | Result |
| --- | --- |
| `run-native-workout-zone-tests.sh` | 107 checks passed on macOS; also passed locally on Linux |
| `run-workout-contract-tests.sh` | Passed, including the existing Watch metric-order and ended-summary assertions |
| `run-watch-source-typecheck.sh` | Passed with watchOS SDK 26.5; explicitly reports that the SDK 27 native adapter was **not** checked |
| Python `unittest discover -s scripts/tests` | 24 tests passed |
| Patch whitespace validation | `git diff --check` passed |

The native tests cover variable zone counts, exact configuration preservation,
zero-based Apple indices, malformed data, transition ordering, sparse callbacks,
freshness independent of transitions, pause/end, missing sensors, zero-watt
coasting, reset/recovery, codec compatibility, final/live separation, native
current-zone durations, mirrored fields and byte-identical legacy BLE frames.
The existing workout contract tests were not weakened or removed to accommodate
new UI; the implementation preserves their expected paired Watch metric order.

An unsigned full Release application build using the repository wrapper passed
on Xcode 26.6 at implementation commit
`ec0d0bfd06b099884b5478197227a40dbc069b26` in
[the first validation run](https://github.com/seichris/open-bike-computer/actions/runs/34913268333).
That run's overall failure was from three UI source-shape assertions, subsequently
resolved at the final tested commit above. The final validation run also has an
independent Release build job; consult that job's result for the latest layout.
Do not interpret the earlier build as proof that a later commit was built.

## Unverified release gates

**This remains a draft implementation, not a native-platform acceptance report.**
The inspected hosted runner has Xcode 26.6 / watchOS SDK 26.5. On that SDK,
`BICINO_HEALTHKIT_WORKOUT_ZONES` is deliberately absent. Therefore passing these
builds does not compile or validate the new HealthKit symbols.

Select a verified Xcode 27 installation, then run:

```sh
cd ios-app
REQUIRE_NATIVE_HEALTHKIT_ZONES=1 ./scripts/run-watch-source-typecheck.sh
./scripts/xcodebuild-cli.sh \
  -project BikeComputer/BikeComputer.xcodeproj -scheme BikeComputer \
  -configuration Debug -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
./scripts/xcodebuild-cli.sh \
  -project BikeComputer/BikeComputer.xcodeproj -scheme BikeComputer \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

The required-native source check must fail rather than silently skip on an older
SDK. Physical watchOS 27 testing with a real power sensor remains required for
native threshold agreement, same-zone updates, wrist-down behavior, stale data,
reconnects, pause/resume, save/discard/recovery and long-ride battery impact.
See [the API research and acceptance matrix](../native-healthkit-zones.md).

## Scope

Native HR and cycling-power zones are added to iPhone and Watch. The ESP32's
existing five-zone `WEXT` fields retain their original Bicino definitions and
wire bytes. Native thresholds/ordinals are never silently sent under the legacy
meaning. Device-native zones need a separately negotiated firmware capability.
No firmware flash, production deployment, merge, or Health Settings mutation was
performed.
