# End-to-end workout zones — validation record

Date: 2026-09-15. PR: [#446](https://github.com/seichris/open-bike-computer/pull/446).

Latest implementation and generated preview commit:
`ab2426a688f8732d65d062ca1795cb9ad29c65fd`.
Original implementation base: `85914afc147f8cbd336f5ef17cb8dbdc2fdf85a6`.
This record supersedes the earlier phone/Watch-only validation record. Device
transport, variable-count rendering and all five additional widgets are now
implemented in this PR, not deferred to another change.

## Compatibility boundary

The updated application retains iOS 16.4 / watchOS 10 deployment targets and
supports iOS 26. The shared zone codec, source-labelled Bicino HR fallback,
capability negotiation and device widgets do not require OS 27. Native HealthKit
collection is separately gated by SDK and runtime availability on Watch.

On older systems the existing workout-specific maximum-HR profile supplies
five Bicino HR zones. Power zones remain unavailable unless native power data
is supplied; watts and cadence continue to work. No FTP, replacement power
thresholds or native provenance is fabricated. Older app binaries and older or
production firmware retain the unchanged core/extended/origin protocol. An older
binary is not promised to edit a layout containing newly introduced widget IDs.

Firmware's new capability and widget masks remain restricted to
`FIRMWARE_DIAGNOSTICS` builds pending physical qualification. The ordinary
1.75-inch and 2.06-inch profiles were built; no board was flashed. Production
continues to advertise legacy capabilities. This is not a production rollout.

## Verified automated evidence

### Native and device protocol implementation

The [device implementation validation run](https://github.com/seichris/open-bike-computer/actions/runs/34948303507)
checked out `e337a2736eff61577dd690822ce04f88644fdda5` and verified:

- 286 native/transport Swift checks, including independent wire fixtures,
  fallback provenance, exact thresholds, invalid payloads, queue ageing, legacy
  bytes and the generated append-only widget contract.
- The existing workout contract suite and all 24 Python app script/release tests.
- Complete Watch source-graph typechecking against SDK 26.5, explicitly reporting
  that the SDK-27-only HealthKit adapter was **not checked**.
- Full unsigned Debug and Release iPhone containers with the embedded Watch app
  using Xcode 26.6.

That run was not all green: it exposed an old capability assertion and a
`VERSION` macro collision. Subsequent commits fix both; these failures are not
represented as successful checks.

### Compatibility and full firmware builds

The [compatibility validation run](https://github.com/seichris/open-bike-computer/actions/runs/34949975013)
tested `8b77ab9d455c93460d7c8c0d358a93fbce5f6345`. Both unsigned Debug and Release
app builds passed. Watch-direct adapter lifecycle tests passed 35 cases / 192
assertions, and the workout contracts and Watch source graph passed.

The [full firmware validation run](https://github.com/seichris/open-bike-computer/actions/runs/34950327988)
built `c9ab0de32d6528b0bc679ae7c578bfc47e8c7910` successfully for both
`WAVESHARE_AMOLED_175` and `WAVESHARE_AMOLED_206` using the repository's locked
runtime wrapper. This includes the generated `ZONE_WIRE_VERSION` macro-collision
fix and a regression test that defines the conflicting generic macro. These are
build results, not device installation or physical acceptance.

The permanent [Workout Zone Contracts run](https://github.com/seichris/open-bike-computer/actions/runs/34953198599)
passed on both board layouts at `73b5d5eed16f5cf46e749fa034d4c47298da5134`.
It covers generated constants, independent Swift/C++ fixtures, decoder lifecycle,
legacy telemetry, authentication/lease boundaries, display geometry and both
legacy and diagnostic widget capability masks.

### Final integration and real preview rendering

The initial broad PR CI exposed three additional integration issues. They are
fixed without dropping the old behavioural assertions:

1. Frozen legacy widget-mask tests now explicitly test the original 17 widgets,
   independently of the expanded 22-widget mask. Each new zone widget is
   rejected for a legacy peer and accepted only for a capable peer.
2. The renderer test validates all visible segments and verifies that spare
   capacity is empty/hidden. It retains the original five-zone checks and adds
   every count from 3 to 9, every active ordinal, heart/power presentation and all
   seven slots on both displays.
3. The World Radio test freezes its own minimum client protocol version (25),
   rather than forbidding unrelated later capabilities from increasing the
   global client version. The new zone capability still requires protocol 26;
   this number is not an iOS requirement.

The [final preview and compatibility validation run](https://github.com/seichris/open-bike-computer/actions/runs/34954720694)
applied the SHA-256-verified reviewed patch on exact head `73b5d5e`, regenerated
and checked the actual LVGL pixel assets, ran the targeted tests plus all 286
zone checks, and published `ab2426a688f8732d65d062ca1795cb9ad29c65fd`.
Its separate Debug/Release jobs rebuild that exact implementation commit; use
those job results for the final app-build status, not a preceding commit's build.
The documentation-only record commit also triggers the normal PR CI.

Local checks of the same source changes passed all 102 root `tools/tests` tests,
286 native/transport checks, the two World Radio contract tests and generated
contract / whitespace checks. Both composed display previews were visually
inspected after native pixel rendering.

Preview regeneration uses the real firmware renderer and pinned LVGL commit
`7f07a129e8d77f4984fff8e623fd5be18ff42e74`, including a clean source-tree digest
check. Every current widget and supported altitude row pair is present in all
eight board/sensor scenarios. Selecting any power-zone widget enables the same
synthetic power example across the page, using generated widget IDs rather than
new magic numbers. Preview thresholds and durations are examples only, never
written to user settings. Source fingerprints include the zone and generated
protocol inputs. They are not hand-edited to conceal stale assets.

## Not established by these checks

**The available hosted toolchain is Xcode 26.6 with watchOS SDK 26.5. An older-SDK
build excludes the native HealthKit adapter; its success cannot establish that
the SDK-27-only symbols compile or behave correctly.** No native SDK 27 build or
physical Watch, sensor, board, battery or recovery acceptance is claimed.

This PR remains draft. Before promotion, run both Debug and Release with a
verified Xcode 27 installation, retaining the minimum deployment targets:

```sh
cd ios-app
REQUIRE_NATIVE_HEALTHKIT_ZONES=1 ./scripts/run-watch-source-typecheck.sh
for configuration in Debug Release; do
  ./scripts/xcodebuild-cli.sh \
    -project BikeComputer/BikeComputer.xcodeproj -scheme BikeComputer \
    -configuration "$configuration" -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO build
done
```

The required-native checker must fail on an older SDK rather than silently
exclude the adapter. Then validate supported iOS 26 / older-Watch fallback and
native Watch configurations on physical devices: thresholds, all zone counts,
same-zone riding, five-second power staleness, zero-watt coasting, missing or
denied readings, pause/resume, save/discard/recovery, reconnect and controller
handoff, phone-relayed and Watch-direct rides, both boards, and sustained battery,
thermal and queue-latency impact. Do not infer support for OS pairings that Apple
does not allow.

Draft PR CI intentionally skips some heavy jobs. The explicit builds above are
separate evidence, not proof that skipped jobs ran. Native collection, transport,
rendering, build, install and physical acceptance are distinct gates.

See [the device protocol](../workout-zone-device-protocol.md) and
[HealthKit API research](../native-healthkit-zones.md) for the wire contract,
source/freshness policy and physical acceptance matrix. No merge, production
deployment, firmware flash, Health Settings change or health-data logging was
performed.
