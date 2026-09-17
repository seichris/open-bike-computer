# iPhone-owned cycling workouts

## Scope

Adds native primary HealthKit workout recording on iOS 26+ alongside the existing
Watch primary recorder and iPhone mirror. This is not standalone ESP32 recording,
not automatic recorder failover, and not a workout handoff protocol. Earlier iOS
navigation and Watch-mirroring minimum versions are unchanged. No BLE schema or
firmware change is introduced.

Apple's primary API reference and sample:
- [Track workouts with HealthKit on iOS and iPadOS](https://developer.apple.com/videos/play/wwdc2025/322/)
- [Building a workout app for iPhone and iPad](https://developer.apple.com/documentation/healthkit/building-a-workout-app-for-iphone-and-ipad)
- [Background location](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)

## Ownership and routing

`WorkoutSessionCoordinator` reserves a durable `WorkoutRecordingRecord` before
starting either recorder. The record includes an owner, random session identity,
start/lifecycle metadata, and an immutable finish disposition. Its file is atomic,
protected until first unlock, excluded from backup, and contains no raw samples.

| Situation | Behavior |
| --- | --- |
| Recovery incomplete or storage unreadable | No new recording; show recovery action |
| WatchConnectivity activating | Wait; the initial false pairing value is not absence |
| No paired Watch after activation | Default to iPhone on iOS 26+ |
| Configured reachable Watch | Default to the existing Watch start |
| Watch unavailable or companion missing | Ask for explicit recorder choice |
| Watch launch times out | Retain unresolved Watch ownership; never auto-fallback |
| Owner disconnects or another device reconnects | Keep the selected owner |
| Another Watch session arrives during phone recording | Surface conflict; do not publish it over phone data or stop either ride |
| Finish confirmed | Keep terminal tombstone until Done |

The existing `WorkoutMirrorManager` still has no builder or Health write path.
`PhoneWorkoutRecorder` has a separate builder, metrics store, and local native
session. A third, source-neutral output store copies only the selected reducer
and retains the application's own navigation context. App, device Start, dashboard,
and Live Activity controls target the selected recorder. Session-scoped Lock Screen
commands retain their existing anti-stale-session checks.

Watch-direct setup must not make a recording phone yield its Bicino connection.
The existing phone-navigation busy check also receives phone ownership/recovery
state. Starting a phone session does not initiate a new bike-computer connection
or override an existing Watch-direct reservation. Existing Watch-only and
Watch-direct recording logic is not rewritten.

Automatic ride detection remains Watch-only, gated by the selected owner. It
cannot silently opt a rider into automatic phone recording. Manual phone pause,
resume, and segments work independently of automatic detection.

## Phone collection and finalization

The native session is cycling/outdoor and uses its associated live workout
builder and associated route builder. The shared `CurrentLocationManager` supplies
GPS; there is no second location manager or requirement to run navigation.
Foreground-started When-In-Use phone GPS can continue on lock with the system
indicator. A cold background recovery without Always location defers GPS until
the app is opened; this never fabricates a missing route segment.

GPS samples are quality/timestamp filtered. Distance is added only once as
explicit HealthKit cycling-distance samples; automatic distance collection is
disabled. Pauses, recovery, and long gaps reset the distance baseline. Implausible
jumps and stationary drift are rejected, and the bounded write queue reports
partial-data failures. Navigation's distance accumulator cannot become recorded
phone-workout distance.

Phone recording exposes time, available GPS route/distance/speed/altitude,
available HealthKit energy and external-monitor heart rate. It does not invent
heart rate, cadence, power, or calories. Phone cadence/power sensor integration is
not included. Segment boundaries use existing segment logic and are written to
HealthKit workout events so they can be recovered.

Save/discard intent is persisted before stopping the session. Save waits for
native stop and queued samples, ends collection, finishes the same builder,
persists a terminal tombstone, and ends the session. Discard never invokes
`finishWorkout`. The associated route is not separately finished into a duplicate
workout. An accepted save cannot later become discard or vice versa.

Before crossing the potentially ambiguous save boundary, `saveAttempted` is
persisted. A later retry queries the same external UUID and app source instead of
blindly issuing another save or constructing a replacement builder. A confirmed
saved object retained in memory can complete a failed tombstone write without
requiring another Health read. An empty lookup (including denied Health read
access) does not prove that the save never happened and leaves the ride unresolved.

## Recovery

Cold launch and UIKit scene connections go through one coalesced recovery
operation; no recovery-only scene option or private selector is required. Native primary sessions must match the phone-owner
metadata and persisted identity. Native mirrored sessions are delivered to the
original mirror manager. A recovered phone session uses the same associated
builder, reinstalls its data source/delegates, restores segments, and continues
only its original finish disposition. Completed tombstones never re-enter save.

Corrupted/protected persistence, identity mismatches, and an unconfirmed saved
outcome block new starts. The UI offers retry/reconciliation, not a false saved
confirmation. An unresolved Watch launch can be released only after an explicit
user check that no Watch workout is running; that action does not stop the Watch.

Independent starts on mutually disconnected devices cannot have global mutual
exclusion. They are surfaced as separate recordings upon detection; this change
must not claim otherwise or silently delete one to hide the conflict.

## Automated validation

- `ios-app/scripts/run-workout-recording-tests.sh`: portable ownership/persistence
  matrix; on macOS, actual coordinator + Combine + real metrics reducer with
  injected recorder boundaries. Called by the existing workout contract suite.
- Existing navigation runtime tests include phone When-In-Use lock continuation,
  release on finish, and refusal to cold-start When-In-Use GPS in background.
- Existing Watch, workout-contract, Live Activity, and app builds remain required.

Portable tests cannot establish HealthKit or physical GPS correctness. An SDK
build is not a device validation.

## Physical release gates (not yet validated)

- [ ] iOS 26 and current iOS: unpaired phone starts, pauses, resumes, segments,
      saves one cycling workout with route; discard produces none.
- [ ] Health denied, partial Health authorization, location denied/reduced
      accuracy, When-In-Use vs Always, and locked-data privacy choices.
- [ ] Locked two-hour phone ride, GPS quality, background BLE/Live Activity,
      energy/thermal behavior; navigation starts/stops independently.
- [ ] Crash during running/paused/start/stop/endCollection/finish/tombstone write,
      recovery on lock/unlock, no duplicate saved identity, segment continuity.
- [ ] Delayed Watch start timeout then late mirror; phone choice after explicit
      checked-idle confirmation; no automatic recorder switch.
- [ ] Phone+Watch, Watch-only, Watch-direct+Bicino; disconnected/reconnected
      devices; a phone recording cannot be displaced by a direct-ride request.
- [ ] Independent starts on both disconnected devices show a conflict and leave
      both workouts intact for explicit review.
- [ ] Legacy iOS Watch mirroring, old firmware telemetry, and OS upgrade/relaunch
      during terminal summary all retain existing compatibility.
