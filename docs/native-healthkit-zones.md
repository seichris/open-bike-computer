# Native HealthKit workout zones

Research date: 2026-09-15. Implementation baseline: `85914afc147f8cbd336f5ef17cb8dbdc2fdf85a6`.

**Release gate: native SDK 27 compilation and physical Watch validation are
required before promotion.** The hosted macOS runner inspected for this change
has Xcode 26.6 / watchOS SDK 26.5. Passing its build does not validate the SDK 27
adapter. No physical ride, sensor, battery or recovery acceptance is claimed.

## Verified Apple interfaces

Primary sources:

- [WWDC26: Deliver workout insights with HealthKit workout zones](https://developer.apple.com/videos/play/wwdc2026/207/)
- [HKWorkoutZoneConfiguration](https://developer.apple.com/documentation/healthkit/hkworkoutzoneconfiguration)
- [Configuration source](https://developer.apple.com/documentation/healthkit/hkworkoutzoneconfiguration/source-swift.enum)
- [HKWorkoutZone.index](https://developer.apple.com/documentation/healthkit/hkworkoutzone/index)
- [HKLiveWorkoutZoneUpdate](https://developer.apple.com/documentation/healthkit/hkliveworkoutzoneupdate)
- [HKWorkoutBuilder.zoneGroup(for:)](https://developer.apple.com/documentation/healthkit/hkworkoutbuilder/zonegroup(for:))
- [Accessing workout zone data](https://developer.apple.com/documentation/healthkit/accessing-workout-zone-data)

The zone APIs are available in iOS/watchOS 27. Both `.heartRate` and
`.cyclingPower` use `HKWorkoutZoneGroup`, with a configuration and ordered native
durations. Configurations contain 3–9 contiguous, non-overlapping zones; Apple's
system power configuration need not have five zones. Preserve source `.system`,
`.user`, `.app` (or unknown), every threshold, and the originating metric. Units
are canonically BPM and watts respectively.

`HKWorkoutZone.index` is zero-based. Convert once at the adapter boundary; all
Bicino display ordinals are one-based. Do not clamp malformed indices. The first
and last bounds can be unbounded. Preserve a supplied zero lower bound as well.
We do not invent the inclusion convention for values exactly on a shared
threshold: the current zone comes from HealthKit, not a local reclassification.

`workoutBuilder(_:didUpdateWorkoutZone:)` delivers **transitions**, not periodic
sensor heartbeats. The verified symbol properties are `currentZoneDuration`,
`previousZoneDuration`, `zoneGroup` and `lastSampleProcessedDate`. Some prose code
in the accessing-data article uses different property names; the implementation
uses the symbol documentation and WWDC code, not those inconsistent snippets.

`builder.zoneGroup(for:)` is synchronous and returns current native durations as
HealthKit processes incoming samples. It is read on the existing coalesced
snapshot path. `zoneConfiguration(for:)` is an asynchronous preferred/custom
configuration lookup; it is deliberately **not** used to reinterpret an active
or completed workout. The attached group is the workout-specific authority.

HealthKit uses preferred Health Settings configurations by default. This change
does not call `setCustomZoneConfiguration`, change Health Settings, invent FTP,
or calculate replacement power thresholds. Existing workout, heart-rate and
cycling-power read requests cover these data. Missing data is not described as
proof of denied read permission.

## Data flow and compatibility

1. The Watch remains the only workout owner. The SDK-specific adapter copies a
   native transition into a Sendable value before its MainActor handoff. Builder
   identity, workout dates and monotonic transition times reject late callbacks.
2. A group retains its exact configuration and HealthKit durations. Fresh raw
   samples, a running session, matching configuration and consistency with the
   native zone are required to highlight a live zone. An old transition remains
   usable while new samples arrive in the same zone. Transition callbacks never
   refresh raw sample timestamps. Pausing, stale power/HR, future samples and
   contradictory values suppress the highlight, not the underlying workout.
3. `WorkoutSnapshotV1.nativeZones` is an optional schema-1.7 addition. It has
   independent HR/power fields, bounded counts, canonical units, observation and
   transition dates, and a final flag. Validation rejects wrong metrics,
   nonfinite/unordered thresholds, invalid totals, malformed ordinals, dates
   outside the workout and final/live confusion. No new availability bits are
   introduced. Phone fallback merging retains the native fields.
4. Only the actual `HKWorkout` returned by a successful finish callback, or the
   actual reconciled saved workout, supplies **final** native data. A live
   builder group or recovery checkpoint is never relabelled final. The original
   finish callback policy, one-workout ownership, route saving and retry paths
   remain intact. Discard and new-session reset remove native data.
5. iPhone and Watch views show native HR/power zones and source labels, and saved
   native time-in-zone breakdowns. Without native HR data the existing Bicino
   max-HR fallback is explicitly labelled. No power zone appears without native
   power data. The fallback setting does not alter Apple Health thresholds.

A recovered builder can restore native groups without a new transition. In that
case durations/configuration remain available but the current highlight waits
for HealthKit's next valid transition. This is intentionally unavailable rather
than inferred from ambiguous boundary semantics or restored from stale state.

The existing five-band fallback/checkpoint implementation continues in parallel
for legacy clients and firmware. Native values are **not** put into `WEXT` even
when the native configuration also contains five zones: its boundaries may be
different. A new capability-negotiated, versioned sidecar now carries both zone metrics to
compatible firmware, with an explicit Bicino fallback on iOS/watchOS 26.
The renderer supports 3–9 zones plus optional power-zone, range and time widgets.
See [the device protocol](workout-zone-device-protocol.md) for the exact wire,
old-peer compatibility, source labels and production qualification gate.

## Toolchains

Minimum deployment targets are unchanged: iOS 16.4 and watchOS 10. Native APIs
have runtime `@available` checks and are compiled only with
`BICINO_HEALTHKIT_WORKOUT_ZONES`. Both build configurations include
`HealthKitZones.xcconfig`, which selects that flag for `watchos27*` and
`watchsimulator27*` SDKs. This is an SDK gate, not a guessed Swift-version gate.
The Watch source-graph checker applies the same SDK selection. Review the SDK
selector when adopting a later major SDK.

On older SDKs, the adapter is excluded and the app continues to emit the legacy
fallback. Its build succeeding is **not** evidence that native APIs compiled.
Force an explicit, failing-unless-native check with:

```sh
cd ios-app
REQUIRE_NATIVE_HEALTHKIT_ZONES=1 ./scripts/run-watch-source-typecheck.sh
./scripts/xcodebuild-cli.sh \
  -project BikeComputer/BikeComputer.xcodeproj -scheme BikeComputer \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Select a verified Xcode 27 installation before these commands. The first command
exits 69 on an older SDK instead of silently passing a disabled native branch.
Use the repository build wrapper, not an unqualified direct `xcodebuild` call.

## Validation

Portable regression checks (run directly on Linux or macOS, and called from the
normal Swift helper CI suite):

```sh
./ios-app/scripts/run-native-workout-zone-tests.sh
```

Coverage includes 3/5/6/9 zones, zero/one-based indices and integer overflow,
invalid/nonfinite/gapped/overlapping boundaries, duplicate/out-of-order/future
callbacks, same-zone freshness, pause/end, missing and stale sensors, zero-watt
coasting versus invalid zero BPM, changing configurations, reset/recovery,
codec/legacy projection, final/discard validation, mirrored data preservation and
unchanged legacy BLE bytes. Existing workout contracts and platform suites must
also continue to pass.

Required physical acceptance, not replaced by the portable tests or Simulator:

- WatchOS 27 automatic and manually configured HR zones; six-zone and custom
  power setups with a real power sensor; denied/missing quantity access.
- Zone crossings and exact thresholds; remain in one zone beyond 30 seconds;
  unplug/reconnect the power sensor, verify five-second power staleness and zero
  watts while coasting. Verify all UI source labels and all supported zone counts.
- Pause/resume, wrist-down delivery, phone disconnection, Watch-direct rides,
  process recovery and a later new workout. Recovery must not display an old
  current ordinal or silently relabel a fallback as native.
- End/save, discard, save failure and recovered-save reconciliation. Compare
  final thresholds/durations against the actual saved HealthKit workout. Ensure
  exactly one workout/route and no native data after discard.
- Older supported OS/SDK fallback, mixed app versions where platform pairing is
  supported, and both existing bike display targets retaining their legacy data.
- Long ride power/thermal and mirroring payload cost; confirm native group reads
  on the existing snapshot cadence do not regress delivery or battery life.
