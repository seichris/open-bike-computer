# iPhone-owned cycling workouts

## Scope

Adds native primary HealthKit workout recording on iOS 26+ alongside the existing
Watch primary recorder and iPhone mirror. This is not standalone ESP32 recording,
not automatic recorder failover, and not a Watch↔iPhone handoff protocol: the only
change of recorder during a ride is the rider's explicit Continue on iPhone
(below), which sends Apple Watch no command. Earlier iOS navigation and
Watch-mirroring minimum versions are unchanged. No BLE schema or firmware change
is introduced.

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
| Active Watch ride stops reporting (disconnected, stale, or unmirrored after an iPhone restart) | Keep Watch ownership; offer Continue on iPhone |
| Rider confirms Continue on iPhone | One atomic owner-record write moves the ride to a new iPhone recording that carries the Watch part |
| Continued Watch session reconnects, sends late data or saves | Never switch back; count Watch data only up to the iPhone start |
| Another Watch session arrives during phone recording | Surface conflict; do not publish it over phone data or stop either ride |
| Finish confirmed | Keep the terminal tombstone until Done or the rider explicitly starts the next workout |

The existing `WorkoutMirrorManager` still has no builder or Health write path.
`PhoneWorkoutRecorder` has a separate builder, metrics store, and local native
session. A third, source-neutral output store copies only the selected reducer
and retains the application's own navigation context. App, device Start, dashboard,
Live Activity and Siri controls target the selected recorder. Session-scoped Lock Screen
commands retain their existing anti-stale-session checks. Siri's Start and Finish
call the coordinator like the app's buttons (Finish asks first); its Pause, Resume
and Segment go through the Live Activity command router and its checks.

Watch-direct setup must not make a recording phone yield its Bicino connection.
The existing phone-navigation busy check also receives phone ownership/recovery
state. Starting a phone session does not initiate a new bike-computer connection
or override an existing Watch-direct reservation. Existing Watch-only and
Watch-direct recording logic is not rewritten.

Automatic ride detection remains Watch-only, gated by the selected owner. It
cannot silently opt a rider into automatic phone recording. Manual phone pause,
resume, and segments work independently of automatic detection.

## Continue on iPhone

When an active Watch-owned ride stops reporting, the record stays Watch-owned
and the app offers **Continue on iPhone** (map card, navigation ride panel and
workout dashboard). It is offered for a started Watch ride (running, paused or
unresolved) whose own session is disconnected or stale, or, after an iPhone
restart, when no session has been mirrored yet. It is not offered while a Watch
end/discard is pending, for an unconfirmed launch, or for another Watch session.
The rider confirms; nothing waits for Apple Watch to return, reboot or sync.

The handoff writes one `WorkoutRecordingRecord` owned by iPhone with a new
session identity and a `continuation`: the Watch session identity, start, the
capture time of its latest counted data (`endedAt`) and summary totals (moving
time, distance, energy, average heart rate). No samples or coordinates are
stored. The existing `PhoneWorkoutRecorder` then starts a new HealthKit workout
at the handoff (metadata `org.bicino.continuesWatchWorkout.v1` names the Watch
workout). The phone's final authorization check admits only the Watch session
being continued; after a restart that may be a session HealthKit reports before
any snapshot identifies it, and if it later proves to be another session Bicino
shows a conflict. If the iPhone start fails, or the app stops before it began
(including when HealthKit recovery returns the Watch's mirrored session), one
atomic write replaces the iPhone reservation with the original Watch record. The
reservation is never deleted first, so a failed write leaves it for recovery to
restore from. The recorder builds its started record from the current record, so
Watch-part data stored during Health authorization is kept. The handed-off
ledger is never written while it cannot be read; entries remembered meanwhile
are merged once it can.

Fitness keeps two workouts: the Watch's (never stopped, saved or discarded by
iPhone) and the iPhone's. Bicino shows one ride. The coordinator's output (the
dashboard, Live Activity and bike computer) adds the Watch part's totals to the
iPhone part and starts the ride at the Watch start; the time between the parts is
an unrecorded gap that adds ride time but no moving time or distance. The iPhone
route starts at its own first fix, so no route line or distance joins the parts.
The ride summary lists the Watch part, the gap (or "unknown" until the Watch's
last data is known) and the iPhone part, and draws them as separate bars.

Late Watch data is absorbed by capture time. Mirrored snapshots or a Fitness save
captured before the iPhone start can extend the Watch part (each cumulative total
keeps its largest value, so a smaller or incomplete save never removes counted
data). Data captured after the iPhone start overlaps it: Bicino records the
overlap and the Watch save but leaves those totals only in the Watch's own Fitness
workout. A reconnecting Watch that is still recording is explained, never
adopted. If the rider discards the Watch workout on Apple Watch, that discard is
stored as the Watch part's outcome: its already-counted totals stay in the ride,
and the summary says it is not in Fitness. The Watch part is looked up in Fitness
(read-only, without a prompt) after the handoff, on recovery and when the app
becomes active, until found or discarded.

Continued Watch sessions are kept in a bounded ledger
(`WorkoutRecording/handed-off-watch-v1.json`, 16 entries, 14 days) so that after
Done, or a relaunch, a late reconnect or save of that session is never adopted as
a new Watch ride. Once Apple Watch stops mirroring it, the stale session is
released so it cannot block the next ride.

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
- [ ] Siri with the iPhone locked, for a Watch ride and a phone ride: start,
      pause, resume, segment, and finish after the spoken confirmation.
      On 2026-11-22 the maintainer reported the workout commands working for a
      Watch ride and a phone ride (Bicino Dev `8a001ed6`, iOS 27.2.1). The
      locked case and each command were not itemized, so the gate stays open.
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
- [ ] Continue on iPhone with the Watch out of range and with the Watch app
      crashed/rebooting: iPhone starts beside the disconnected mirrored session
      (HealthKit concurrency), the bike computer accepts the new session token and
      keeps showing whole-ride totals, the Live Activity switches sessions.
- [ ] After the handoff: Watch reconnects still recording (no switch back), the
      Watch saves its part late (Fitness entry kept, gap updated), iPhone relaunch
      mid-ride and after finish (one ride with the same gap), Done then a late
      Watch reconnect (not adopted, next ride can start).
