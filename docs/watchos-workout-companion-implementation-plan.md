# watchOS Workout Companion Implementation Plan

## Outcome

Add a BikeComputer watchOS companion that owns an outdoor cycling workout,
collects live HealthKit and Apple Watch sensor data, mirrors that data to the
BikeComputer iPhone app, and lets the iPhone relay the current workout metrics
to the ESP32 display.

The completed flow is:

    Apple Watch sensors and paired cycling sensors
                    |
                    v
       watchOS HKWorkoutSession + HKLiveWorkoutBuilder
                    |
          HealthKit workout-session mirroring
                    |
                    v
       iOS WorkoutMirrorManager + WorkoutMetricsStore
                    |
              +-----+------------------+
              |                        |
              v                        v
       iPhone workout UI       authenticated BLE relay
                                       |
                                       v
                              ESP32 Ride Stats UI

The Watch is the only component that creates and saves the workout. The iPhone
and ESP32 are live displays and control surfaces. This prevents duplicate
HealthKit workouts and avoids the delayed iPhone HealthKit polling approach that
was removed from the repository.

## Product contract

- A ride can start from either the Watch app or the iPhone app.
- Starting from iPhone launches the paired Watch app and asks it to create the
  workout.
- The BikeComputer Watch app, not Apple's Workout app, owns the active
  HKWorkoutSession.
- Apple Watch permits only one active workout session, but public HealthKit APIs
  do not expose whether another app currently owns it. Watch and iPhone starts
  proceed directly after their setup checks; transient WatchConnectivity
  reachability is not a hard gate because HealthKit can wake the Watch app. If
  another app owns or later takes ownership of the workout session,
  BikeComputer reports the outcome explicitly and never retries in a loop.
- Workout and navigation are independent:
  - starting navigation does not silently start a workout;
  - ending navigation does not end a workout;
  - ending a workout does not end navigation.
- Discard is a two-step destructive action on both Watch and iPhone. Selecting
  `Discard Workout` from the finish menu opens a final warning; only confirming
  that warning discards the ride, while `Keep Riding` leaves it active.
- A later opt-in setting may offer Start workout with navigation, but it must
  default off and still require a reachable Watch.
- The workout continues and saves on Watch if iPhone or ESP32 disconnects.
- The iPhone shows live metrics whenever it is receiving current mirrored
  snapshots.
- The ESP32 receives the same current metrics through the existing authenticated
  iPhone-to-device BLE relationship.
- Missing sensors produce an unavailable value, never a misleading zero.
- No health metric or workout route is uploaded to a backend.

## Non-goals

- Attaching to, inspecting, or mirroring a workout owned by Apple's Workout app
  or another third-party app.
- Running BikeComputer and Apple Workout simultaneously.
- Reintroducing the deleted iPhone-only HealthKit timer and sample-polling
  implementation.
- Having Apple Watch connect directly to the ESP32 in the first version.
- Cloud synchronization of raw workout metrics.
- Making iPhone navigation depend on HealthKit authorization.

## Current main-branch baseline

This plan was prepared from origin/main at 74a1d32b.

- The Xcode project currently contains one iOS target with deployment target
  iOS 15.0 and no HealthKit entitlement.
- The previous HealthKitManager and workout views were removed by f0a9e6b2
  because they did not own a real live workout session.
- NavigationEngine currently calculates ride distance and elapsed time only
  while navigation is active.
- The existing 2A72 GPS packet can carry speed, altitude, distance, elapsed
  time, and route remaining in its 30-byte form.
- The ESP32 Ride Stats screen currently displays speed, altitude, distance,
  elapsed time, and route remaining.
- The existing GPS parser resets its ride fields for each position packet.
  Workout telemetry must therefore live in separate firmware state so a GPS
  update cannot erase a Watch metric.
- The BLE service is authenticated and already has capability negotiation,
  native characteristics, and a framed fallback path.

## Decisions locked into this plan

1. Watch owns the primary workout session and the saved HKWorkout.
2. iPhone receives a mirrored session and versioned full-state snapshots.
3. The app supports iOS 16.4 or later for navigation, but Watch workout features
   are available only on iOS 17 or later with watchOS 10 or later.
4. Watch and iPhone share one Codable workout contract.
5. ESP32 workout data uses a dedicated characteristic and two compact,
   versioned 16-byte frames instead of extending the GPS packet again.
6. The old GPS telemetry behavior remains the fallback when no Watch workout is
   active or the connected firmware lacks workout-telemetry support.
7. Workout controls and navigation controls remain separate in the UI.
8. Raw HealthKit values remain local to Watch, iPhone, and the paired ESP32.

## Platform and target setup

### Xcode targets

Add a Watch App for the existing iOS app in
ios-app/BikeComputer/BikeComputer.xcodeproj.

- iOS app bundle identifier: keep LetItRide.BikeComputer.
- Watch app bundle identifier: use LetItRide.BikeComputer.watchkitapp unless
  App Store Connect requires an already-reserved identifier.
- Watch deployment target: watchOS 10.0.
- Set the iOS deployment target to 16.4.
- Wrap mirrored-workout integration in iOS 17 availability checks so the
  existing navigation app still launches and builds on iOS 16.4.
- The Watch target is a companion target, not a standalone Watch-only product.
- Keep version and build numbers aligned across the containing iOS app and
  Watch app.

Suggested source layout:

    ios-app/BikeComputer/
      WorkoutShared/
        WorkoutContract.swift
        WorkoutMetricUnits.swift
      BikeComputer/
        Managers/WorkoutMirrorManager.swift
        Managers/WorkoutMetricsStore.swift
        Managers/WorkoutDeviceRelay.swift
        Views/WorkoutCardView.swift
        Views/WorkoutDashboardView.swift
      BikeComputerWatch/
        BikeComputerWatchApp.swift
        WatchAppDelegate.swift
        Managers/WatchWorkoutManager.swift
        Managers/WatchRouteRecorder.swift
        Views/WorkoutStartView.swift
        Views/LiveWorkoutView.swift
        Views/WorkoutSummaryView.swift

WorkoutShared files must have target membership in both the iOS and watchOS
targets. Platform-specific files must not be shared accidentally.

### Capabilities and Info.plist

Enable HealthKit for both targets.

Watch target:

- HealthKit capability.
- Background Modes: Workout processing, producing WKBackgroundModes with
  workout-processing.
- Location When In Use permission for outdoor route recording and GPS-derived
  speed/elevation fallback.
- NSHealthShareUsageDescription explaining the live cycling metrics being read.
- NSHealthUpdateUsageDescription explaining that BikeComputer saves a cycling
  workout and route to HealthKit.
- NSLocationWhenInUseUsageDescription explaining route, speed, and elevation
  recording during an outdoor ride.
- WKCompanionAppBundleIdentifier pointing to LetItRide.BikeComputer.

iOS target:

- HealthKit capability for mirrored HKWorkoutSession support and optional
  completed-workout summary lookup.
- Add a clear NSHealthShareUsageDescription for the optional completed-workout
  summary lookup.
- Do not request HealthKit write access or save workouts on iPhone. Add
  NSHealthUpdateUsageDescription only if final SDK/runtime validation proves it
  is required for the mirrored-session target; otherwise omit it.
- Keep the current location and Bluetooth background modes unchanged.

HealthKit authorization success does not prove that every read type was
granted. The UI must treat individual metrics as optional based on received
data, not infer read access from the authorization callback.

## HealthKit authorization set

On Watch, request permission to share:

- workout type;
- workout route type.

Request permission to read the public quantities used by the live builder:

- heart rate;
- active energy burned;
- distance cycling;
- cycling speed;
- cycling power;
- cycling cadence.

Also request read access to workout and workout-route samples for the
just-finished summary, route, and zone data. Do not request unrelated HealthKit
categories.

If HealthKit access is denied:

- navigation and ESP32 connectivity continue to work;
- the Watch app explains that it cannot start a BikeComputer workout;
- the iPhone provides exact on-Watch authorization guidance; Apple exposes no
  public iPhone deep link to the Watch app's Health authorization surface;
- no synthetic HKWorkout is created later.

If location access is denied on Watch, the session may still collect heart
rate, active energy, and any paired-sensor metrics. Route, elevation, and
GPS-speed fallback remain unavailable.

## Metric ownership and precedence

Use one merged WorkoutSnapshot on Watch and one WorkoutMetricsStore on iPhone.
Each optional metric carries its value, capture time, and source where the
source matters.

| Metric | Primary source | Fallback | Notes |
| --- | --- | --- | --- |
| Session state | Watch HKWorkoutSession | none | Watch is authoritative. |
| Elapsed time | HKLiveWorkoutBuilder elapsedTime | extrapolate briefly from last running snapshot | Builder time respects pauses. |
| Current heart rate | live builder heart-rate statistics | none | Use most recent quantity. |
| Average heart rate | live builder heart-rate statistics | none | Use average quantity. |
| Active energy | live builder active-energy sum | none | Convert to kilocalories only at the presentation boundary. |
| Cycling distance | live builder distance-cycling sum | Watch route distance, then iPhone navigation distance | Never add sources together. |
| Current speed | cycling-speed quantity from a paired sensor | Watch CLLocation speed, then iPhone CLLocation speed | Preserve the source for UI and testing. |
| Cycling power | live builder cycling-power quantity | none | Unavailable without a compatible sensor. |
| Cycling cadence | live builder cycling-cadence quantity | none | Unavailable without a compatible sensor. |
| Current HR zone | BikeComputer max-HR profile applied to fresh Watch heart rate | none | Five app-defined zones; never label them as Apple's system zones. |
| Zone durations | future HealthKit live zone group | completed-workout query | Unavailable on the current SDK; ESP32 needs only current zone and zone count. |
| Current location | Watch Core Location | iPhone Core Location for device relay | Keep accuracy and timestamp. |
| Altitude | Watch CLLocation altitude | iPhone CLLocation, then device GPS | Reject invalid vertical accuracy. |
| Saved workout route | Watch HKWorkoutRouteBuilder | no route | Store in HealthKit, not in app files. |
| Route remaining and instructions | iPhone NavigationEngine | none | Navigation data is not a HealthKit metric. |

When a Watch workout is current, Watch-owned speed, distance, elapsed time, and
sensor values win on the iPhone and ESP32. When there is no Watch workout, the
existing iPhone navigation telemetry remains available exactly as it is today.
An iPhone location fallback is instantaneous data: reject future samples and
expire speed, coordinates, and altitude after 10 seconds. Only merge iPhone
altitude into Watch coordinates when the samples are temporally and spatially
coherent; preserve the oldest component timestamp.

### Heart-rate zones

The current shipping SDK does not expose Apple's personalized workout-zone
stream. BikeComputer therefore provides a separate five-zone profile based on
the maximum heart rate configured in the iPhone app's Developer Settings: below
60%, 60-70%, 70-80%, 80-90%, and 90% or more. The default is 190 BPM. Changes
persist on iPhone and use WatchConnectivity application context to update the
paired Watch, which retains its last received value and falls back to the
default before any setting has arrived. The profile reports a one-based current
zone and a count of five only while the underlying heart-rate sample is fresh
and valid.

These values are always described as BikeComputer zones, not approximations of
Apple's configured system zones. When Apple's workout-zone API is available in
a shipping SDK supported by the project, prefer its system/user configuration
behind compile-time and runtime availability checks. Zone-duration data remains
unavailable until that production source exists.

## Shared Watch-to-iPhone contract

Define a versioned Codable envelope. Use binary property-list encoding or
another deterministic Foundation encoding supported by both targets. Do not
archive arbitrary object graphs.

WorkoutEnvelopeV1 contains:

- schemaVersion;
- message kind: snapshot, control, acknowledgement, or error;
- session UUID;
- non-zero UInt16 device session token;
- optional durable transport-generation UUID, repeated on every v1.1-or-newer
  snapshot so a receiver can recover even if the first sequence was missed;
- monotonically increasing UInt64 sequence;
- capturedAt timestamp.

Version 1.3 controls also carry an optional iPhone control-sender UUID. It
identifies one iPhone process' sequence space so a relaunched phone can advance
to a fresh sender generation without reusing the Watch's retained replay
watermark. Watch retires prior sender UUIDs for the workout; delayed controls
from a retired process cannot resume.

Version 1.4 adds user-marked workout segments. Segment controls retain the same
sender and sequence identity so the Watch can make them replay-safe.

WorkoutSnapshotV1 contains:

- session state: idle, starting, running, paused, ending, ended, or failed;
- start date;
- elapsed seconds;
- current and average heart rate in beats per minute;
- active energy in kilocalories;
- cycling distance in meters;
- current speed in meters per second and its source;
- cycling power in watts;
- cycling cadence in revolutions per minute;
- current heart-rate zone, zone count, and optional zone durations;
- latest location coordinate, timestamp, horizontal/vertical accuracy, course,
  speed, and altitude;
- the most recently completed segment's one-based index, boundary dates, active
  duration, and optional distance;
- a compact availability/source mask;
- an optional user-safe error code, never raw sensitive data; an explicit
  opposite Save/Discard outcome is presented as a terminal-choice conflict,
  not as a connectivity failure; an outcome-free native end keeps the choice
  pending until an acknowledgement, explicit outcome, or honest unconfirmed
  timeout;
- an optional terminal outcome distinguishing a Watch save from discard.

WorkoutControlV1 contains:

- pause;
- resume;
- mark a segment;
- request end and save;
- request discard;
- request current full snapshot.

The Watch acknowledges state-changing controls with the resulting state and
sequence. A rejected segment carries the safe `segmentMarkFailed` error without
failing or ending the workout. A timed-out, non-cancellable HealthKit write is
reported as `segmentMarkUnconfirmed` until its callback supplies a definitive
result. It does not require acknowledgements for every metric snapshot.

Decoder rules:

- reject unsupported future major schema versions;
- ignore unknown optional fields from a compatible minor version;
- reject empty session IDs, token zero, non-finite numbers, impossible negative
  totals, and invalid coordinates;
- keep the highest sequence per session and discard older snapshots;
- keep the highest control sequence per iPhone sender generation, accept only
  one newer unseen sender generation, and reject retired senders;
- permit a same-session token change only for an unseen explicit transport
  generation with the canonical start date and a newer capture time; remember
  retired generations so they cannot resume, even with newer sequence numbers;
- process a batched array in order, then publish only the latest coherent
  state;
- never let an older session overwrite a newer active session.

## Watch workout lifecycle

### Start on Watch

1. Present an outdoor cycling start action.
2. Request required HealthKit and location authorization if needed.
3. Create HKWorkoutConfiguration with activityType cycling and locationType
   outdoor.
4. Create HKWorkoutSession, its associated HKLiveWorkoutBuilder, and
   HKLiveWorkoutDataSource.
5. Register session and builder delegates before starting.
6. Start mirroring to the companion iPhone.
7. Start the session activity and begin builder collection using the same
   start date.
8. Start Watch route recording and publish a full starting/running snapshot.

### Start on iPhone

1. iPhone creates the same outdoor-cycling HKWorkoutConfiguration.
2. Call HKHealthStore.startWatchApp with that configuration.
3. WatchAppDelegate receives the configuration through its workout handle
   callback and passes it to WatchWorkoutManager.
4. Watch follows the normal start flow and starts mirroring.
5. iPhone shows Starting on Apple Watch until the mirrored session arrives.
6. Use a bounded timeout and show a retryable error if no Watch responds. Do not
   start an iPhone-owned replacement workout.

If authorization interaction is still required on Watch, iPhone displays
Finish setup on Apple Watch instead of timing out silently.

### Live collection

WatchWorkoutManager implements HKLiveWorkoutBuilderDelegate and
HKWorkoutSessionDelegate.

- Read sum quantities for distance and energy.
- Read most-recent quantities for current heart rate, speed, power, and
  cadence.
- Read average heart rate from builder statistics.
- Use builder elapsedTime rather than Date minus start date.
- Record Watch CLLocation updates into HKWorkoutRouteBuilder in bounded
  batches.
- Use paired-sensor cycling speed before CLLocation speed.
- Coalesce builder and location callbacks into at most one full snapshot per
  second.
- Send state transitions immediately.
- Send a periodic full snapshot even when values are unchanged so iPhone can
  recover from a lost update.
- Permit only one send operation at a time and retain only the newest pending
  snapshot under backpressure.

### Pause and resume

- Pause/resume from Watch uses the primary session.
- Pause/resume from iPhone uses the mirrored session's native control.
- Both UIs update only after session delegate state confirms the transition.
- Elapsed time and distance do not advance while paused.
- Route points received during a pause are ignored.
- ESP32 displays a PAUSED state without converting unavailable speed to zero.

### Segments

- Marking a segment is available while the workout is running on both Watch and
  iPhone. The iPhone action requires a Watch snapshot using schema 1.4 or later,
  so staggered app updates do not send an undecodable control to an older Watch.
- The Watch writes an `HKWorkoutEvent` of type `segment` to the live builder and
  remains the only HealthKit writer.
- Segment duration uses builder elapsed time so pauses are excluded. Distance is
  the delta between cumulative Watch workout distances when both boundaries have
  usable values from the same source; a source change omits that segment's
  distance and establishes a new baseline.
- A successful boundary is mirrored before either UI shows success feedback.
- BikeComputer metadata on each event stores the segment index and cumulative
  values needed to reconstruct the next boundary after workout recovery.
- A remote segment control stores its sender and sequence in the event metadata
  so a replay cannot create a duplicate segment.
- Before starting that HealthKit write, Watch durably journals the exact remote
  control and original boundary candidate in the same transaction as its replay
  checkpoint. Recovery can therefore resume the original boundary if the app
  exits after accepting the command but before HealthKit records the event.
- If its definitive acknowledgement is lost, iPhone retains and replays that
  exact sender/sequence after the confirmation timeout and on reconnect. A
  segment-count change alone never attributes a Watch-local boundary to the
  iPhone command.
- If at least one segment was marked, saving adds the final segment from the last
  boundary to the authoritative workout end date.
- Segment writes use a bounded confirmation window. Because HealthKit writes
  cannot be cancelled after submission, a timeout keeps the boundary pending,
  prevents duplicate retries, and reconciles the late callback. Pause and finish
  intent remain available while confirmation is pending. Save waits for one
  additional bounded window so it can close the final segment correctly. If the
  callback still does not arrive, the stopped ride remains retryable and the
  rider can explicitly save anyway with a warning that the pending segment is
  not guaranteed. Discard never waits for segment confirmation.

### End and save

The Watch owns finalization:

1. Transition to ending and publish that state.
2. Stop location collection and call `stopActivity(with:)` on the primary
   session, retaining workout-session mode while the save completes.
3. After HealthKit reports the session stopped, flush valid points to the
   associated HKWorkoutRouteBuilder.
4. End live builder collection at the authoritative stop date.
5. Finish the workout. HealthKit automatically finalizes an associated route
   builder with its workout; never call `finishRoute` on a route builder
   obtained from `HKWorkoutBuilder.seriesBuilder(for:)`.
6. Call `end()` on the primary session only after the builder was finished or
   discarded, then publish one final ended snapshot and summary.
7. Stop mirroring only after final state delivery has been attempted.
8. Clear in-memory raw route points and the durable finish request.

The final-state attempt is bounded. If HealthKit returns neither a mirror-send
completion nor a disconnect callback within 10 seconds, invalidate that send,
end the retained primary session exactly once, and release new-workout
admission rather than wedging cleanup indefinitely.

An iPhone End action sends a request-end control to Watch so Watch can perform
this ordered finalization. If Watch is unreachable, iPhone explains that the
workout continues on Watch and offers no fake local completion.

The Watch UI must also offer an explicit discard path. Discarding must not save
an HKWorkout or route.

If builder collection or workout saving fails after the rider chose Save,
retain the stopped session, builder, associated route, durable finish request,
and finalization phase. Show a retryable save state and reconcile HealthKit
before retrying; do not convert a transient save failure into an implicit
discard.

Persist finalization as requested, collection-ended, finish-attempted, and
workout-saved. Write the finish-attempted marker before calling
`finishWorkout`. After a crash in that commit-unknown window, a matching
readable workout proves success, but an empty query does not prove absence:
HealthKit intentionally hides read-denial status. Keep the save unresolved and
never call `finishWorkout` again until non-commit is proven. A delivered finish
error may durably return to collection-ended for a safe retry.

Persist associated-route status before the finish attempt as present,
unavailable, or unknown. Recovery must never display an unknown route as
unavailable merely because it could not be queried.

### Recovery

- On Watch relaunch, implement active-workout recovery and reattach the
  session, builder, data source, delegates, route recorder, and snapshot
  publisher.
- Reconcile stopped and ended recovered sessions when a finish request exists;
  preserve an unexpectedly ended ride with a default save request.
- Treat a detached durable-save reconciliation separately from an attached
  HealthKit session. A late `handleActiveWorkoutRecovery` callback must retry
  attachment whenever no session is attached, even if the UI is already in an
  ending or reconciled state. After HealthKit confirms no session and the
  workout is known saved, atomically archive its stable UUID into a separate
  bounded terminal tombstone before releasing the summary and new-workout
  admission. A genuinely late session matches that tombstone through builder
  metadata and is only stopped/ended; it is never saved again. If tombstone
  persistence fails, keep the summary visible, offer Retry Recovery, and block
  new-workout admission rather than overwrite the only proof.
- Configure the iOS mirroring start handler during app launch, before SwiftUI
  views depend on it.
- Replace the iOS mirrored-session reference when HealthKit reconnects and
  supplies a new instance.
- After any mirror reconnect, iPhone requests a full snapshot.
- Watch workouts continue without iPhone and without ESP32.
- iPhone BLE reconnect sends its latest coherent snapshot to ESP32
  immediately after authentication and capability negotiation.

## Mirroring and latency contract

Use HKWorkoutSession.startMirroringToCompanionDevice and
sendToRemoteWorkoutSession for the supported path. Do not poll the iPhone
HealthKit database for Watch samples.

Apple documents that data sent to a suspended iPhone may be cached and delivered
in batches, with potentially several minutes between delegate callbacks.
Therefore:

- foreground iPhone use is the live-bike-computer path;
- active navigation can keep the current iOS location/BLE execution path alive
  in the background;
- no hard real-time promise is made while iOS is fully suspended;
- snapshots contain capture timestamps and sequences so delayed batches cannot
  appear current;
- iPhone and ESP32 show a stale indicator when the newest capture exceeds the
  freshness threshold;
- iPhone forwards only the newest valid snapshot from a resumed batch to
  ESP32, not a burst of obsolete history.

Initial performance targets on real hardware:

- Watch to foreground iPhone: p95 snapshot age at display no more than 2 seconds.
- iPhone to connected ESP32: p95 relay delay no more than 1 second.
- End-to-end Watch to ESP32: p95 no more than 3 seconds while iPhone is active.
- Mark metrics stale after 10 seconds without a current snapshot.

Measure these targets; do not claim them from simulator tests.

## iPhone architecture

### WorkoutMirrorManager

Create one long-lived manager, available on iOS 17 and later.

- Own HKHealthStore and the current mirrored HKWorkoutSession.
- Install workoutSessionMirroringStartHandler during AppDelegate launch.
- Decode remote envelopes on the HealthKit delegate queue and hand validated
  snapshots to a MainActor store.
- Expose start, pause, resume, mark-segment, end, and discard requests.
- Track launch timeout, remote disconnect, stale data, and cross-app session
  displacement as explicit states.
- Treat native terminal state as sticky: freshness ticks or delayed active
  snapshots cannot move an ended session back to connected or stale.
- Never save a second iPhone HKWorkout for a Watch-owned session.

### WorkoutMetricsStore

Publish a single coherent view model:

- connection and freshness state;
- session state;
- all optional workout metrics;
- source labels where useful;
- last update time;
- final summary;
- safe user-facing errors.

The store also merges iPhone navigation-only fields such as route remaining.
Metric precedence follows the table above and is unit-tested.

### Coordinator and UI integration

BikeComputerCoordinator binds to WorkoutMetricsStore without making
NavigationEngine depend on HealthKit.

Add:

- a compact workout card in ContentView that can coexist with the navigation
  controls;
- a full workout dashboard showing current heart rate/zone, speed, distance,
  elapsed time, active energy, power, cadence, average heart rate, altitude,
  connection freshness, and unavailable-sensor states;
- Start on Apple Watch while idle;
- Pause, Resume, and End while active;
- a clear Watch unavailable/setup-required state;
- a final summary after save or discard; keep Done unavailable while a terminal
  choice is still awaiting acknowledgement, explicit outcome, or timeout.

Navigation and workout controls must remain separately labelled. The existing
End navigation button never ends the workout.

### WorkoutDeviceRelay

This component observes WorkoutMetricsStore and BLEManager readiness.

- Build compact device packets from the latest coherent snapshot.
- Coalesce high-rate changes instead of appending every metric callback to the
  navigation write queue.
- Send session-state changes immediately.
- Send the core frame no more than once per second.
- Send the extended frame when it changes and at least once every five seconds.
- Send both frames after ESP32 authentication/reconnect.
- Stop sending live numeric updates when the snapshot is stale; send state and
  unavailable sentinels instead.
- Fall back to the existing GPS ride telemetry when firmware does not advertise
  workout telemetry.

## ESP32 BLE protocol extension

### Capability and characteristic

Add a full 128-bit characteristic rather than consuming another adopted
16-bit Bluetooth UUID:

    9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1003

Properties:

- direction: iOS to ESP32;
- write without response;
- accepted only after the existing local auth handshake;
- fixed 16-byte logical native payload, carried as a 38-byte protected wire
  write in an ownership-v2 session.

Capability negotiation:

- increment the iOS CAPS request version from 5 to 6;
- reserve capability flag bit 7 for workout telemetry;
- firmware sets bit 7 only when the characteristic, parser, in-memory state,
  and Ride Stats presentation are all available;
- old firmware ignores the feature and continues receiving existing GPS data.

For cached GATT tables where the characteristic is not discovered, support the
existing authenticated command channel fallback:

    WTLM | 16-byte workout frame

The four-byte prefix plus frame is exactly 20 plaintext bytes. Ownership-v2
protection expands the fallback to a 42-byte wire write; the ownership
handshake requires an ATT MTU large enough for it. Native and fallback frames
use the same parser after authenticated-channel unwrapping.

### Core frame: kind 1

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 1 | Frame kind = 1 |
| 1 | 1 | Session state |
| 2 | 2 | Non-zero session token, UInt16 little-endian |
| 4 | 4 | Elapsed seconds, UInt32 little-endian |
| 8 | 4 | Distance meters, UInt32 little-endian |
| 12 | 2 | Speed centimeters/second, UInt16 little-endian |
| 14 | 2 | Current heart rate BPM, UInt16 little-endian |

Session-state values:

| Value | Meaning |
| ---: | --- |
| 0 | Idle/clear |
| 1 | Starting |
| 2 | Running |
| 3 | Paused |
| 4 | Ending |
| 5 | Ended/final summary |
| 6 | Failed |

### Extended frame: kind 2

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 1 | Frame kind = 2 |
| 1 | 1 | Source/availability flags |
| 2 | 2 | Session token, UInt16 little-endian |
| 4 | 2 | Average heart rate BPM |
| 6 | 2 | Active energy in tenths of a kilocalorie |
| 8 | 2 | Cycling power watts |
| 10 | 2 | Cycling cadence in tenths of an RPM |
| 12 | 1 | Current one-based heart-rate zone; 0 unavailable |
| 13 | 2 | Altitude meters, Int16 little-endian |
| 15 | 1 | Zone count; 0 unavailable |

Initial flag allocation:

| Bit | Meaning |
| ---: | --- |
| 0 | Speed came from a paired cycling-speed sensor |
| 1 | Speed came from Watch GPS |
| 2 | Distance came from HealthKit distance-cycling statistics |
| 3 | Altitude came from a valid Watch location |
| 4 | A live heart-rate zone is available |
| 5 | Mirrored snapshot is current, including current-but-unavailable metrics |
| 6...7 | Correlated frame-pair generation; zero is the legacy relay contract |

Encoding rules:

- UInt16.max means unavailable for unsigned UInt16 metric fields.
- UInt32.max means unavailable for elapsed time or distance; valid values
  saturate at UInt32.max minus one.
- Int16.min means unavailable altitude.
- Saturate valid numeric values below the sentinel instead of wrapping.
- Active energy range is 0 through 6553.4 kcal.
- Reject non-finite and negative values before encoding.
- Core state idle with token zero clears device workout state.
- Starting/running/paused core frames establish the active token.
- Ignore an extended frame whose token does not match the active core token.
- Ended preserves a final summary until an explicit idle frame, a new session,
  or reboot.
- Current-snapshot freshness is independent from numeric availability, so an
  awaiting-final ending state can be current while carrying sentinels.
- Correlated generation `1...3` pairs commit atomically. Same-token transitions
  follow the shared workout state machine, while starting after ended/failed is
  an explicit replacement boundary for the rare UInt16 token-collision case.
- At an authenticated reconnect boundary, a complete current correlated pair
  may cross an otherwise-invalid transition from a retained ending/ended/failed
  snapshot with the same token, including active, ending, and cross-terminal
  outcomes. A partial or stale pair cannot cross that boundary.
- Generation-zero current-all-unavailable and transport-loss pairs are
  inherently identical. Firmware clears ambiguous values, grants one
  10-second freshness window, and does not let empty extended-only heartbeats
  extend that window.

Document this extension in docs/ble-protocol.md and add exact byte-vector tests
on both iOS and firmware sides.

## Firmware architecture and UI

### Workout telemetry state

Add a small RAM-only WorkoutTelemetryState separate from gps.gpsData.

It stores:

- active session token and state;
- receive timestamp;
- all decoded optional fields;
- source flags;
- whether core and extended frames have been received;
- freshness.

Parser requirements:

- require an authenticated session;
- require exactly 16 payload bytes;
- validate frame kind, state, token, flags, and sentinels;
- ignore mismatched extended tokens;
- handle native and WTLM fallback through one function;
- never write raw health values to persistent logs;
- clear RAM state on explicit idle and reboot;
- retain the last snapshot but mark it stale after transport loss.

The existing GPS parser continues updating gps.gpsData. It must not reset or
overwrite WorkoutTelemetryState. The Ride Stats presenter chooses Watch workout
state when it is active/current and legacy GPS ride telemetry otherwise.

### Ride Stats presentation

Keep the existing Ride Stats screen, but make it capable of showing every
received workout metric using two pages:

Page 1, Live:

- hero speed;
- current heart rate and zone;
- distance;
- elapsed time;
- power;
- cadence.

Page 2, Summary/navigation:

- average heart rate;
- active energy;
- altitude;
- route remaining from the existing navigation state;
- source/freshness indicator;
- paused, ended, or failed status.

Interaction:

- short tap keeps the existing optional cycle-to-next-screen behavior;
- long press while on Ride Stats toggles between the two workout pages;
- a hardware screen-cycle action remains unchanged;
- page selection is RAM-only and does not add a persisted setting in v1.

Presentation rules:

- show -- for unavailable metrics;
- never render absent power/cadence/heart rate as zero;
- show PAUSED without clearing the last valid numbers;
- show stale/link-lost state after 10 seconds without current core data;
- do not interpret a stale Watch speed as current;
- show the final summary after ended until cleared;
- retain readable type sizes on both Waveshare 1.75 and 2.06 builds.

## Privacy and security

- Health data remains protected by HealthKit authorization.
- Mirrored messages travel through the paired Apple Watch/iPhone workout
  session.
- ESP32 packets use the existing authenticated local BLE session.
- Do not upload, analyze remotely, or include raw health/location metrics in
  crash reports.
- Avoid console logging current heart rate, route coordinates, power, or full
  encoded snapshots.
- ESP32 keeps workout telemetry in RAM only.
- Clear ESP32 health metrics on explicit idle and reboot.
- Update PRIVACY_POLICY.md and App Store privacy disclosures before release to
  describe Health & Fitness and workout-route use accurately.
- Keep permission descriptions specific to user-visible cycling features.

## Failure behavior

| Failure | Required behavior |
| --- | --- |
| No paired Watch or missing companion app | iPhone start explains the required setup; navigation remains usable. Transient WatchConnectivity unreachability does not block a paired, installed Watch start. |
| HealthKit denied | No workout starts; no synthetic workout is saved. |
| Location denied on Watch | Continue supported sensor metrics; route/elevation unavailable. |
| Apple Workout already active before BikeComputer starts | Watch and iPhone starts proceed directly after setup checks because public APIs cannot detect the competing workout. Any resulting start failure or displacement is reported honestly. |
| Another app starts while BikeComputer is active | Report that BikeComputer was displaced, stop safely, and do not retry in a loop. |
| iPhone disconnects | Watch continues and saves; buffer only the newest pending snapshot. |
| Mirroring reconnects | Replace session reference and request a full snapshot. |
| ESP32 disconnects | App continues; resend latest core and extended frames after auth. |
| iPhone becomes suspended | Show snapshot age after resume; never replay old metrics as live. |
| Power/cadence sensor absent | Show --; remaining metrics continue. |
| Watch app crashes | Recover the active workout session and reattach delegates. |
| Firmware lacks bit 7 | Keep current GPS ride telemetry; hide unsupported device-live status. |
| Malformed BLE frame | Reject without altering the last valid state. |
| Route builder has no points | Save workout without a route. |
| End request cannot reach Watch | Explain that workout continues on Watch. |

## Implementation phases

### Phase 1: project skeleton and shared contract

1. Add the watchOS companion target and capabilities.
2. Add WorkoutShared source files with versioned snapshot/control models.
3. Add unit tests for encoding, decoding, schema rejection, sequencing,
   optional metrics, and invalid numbers.
4. Add iOS 17/watchOS 10 availability boundaries.

Exit criteria:

- iOS 16.4 target still builds without entering workout code.
- Watch target builds and installs.
- Shared-contract tests pass on both platforms.

### Phase 2: Watch-owned workout

1. Implement authorization and explicit setup states.
2. Implement WatchWorkoutManager state machine.
3. Collect heart rate, active energy, distance, speed, power, and cadence.
4. Add Watch location and HKWorkoutRouteBuilder.
5. Implement pause, resume, save, discard, and recovery.
6. Build Watch start/live/summary views.

Exit criteria:

- A Watch-only ride saves exactly one cycling HKWorkout.
- Heart rate and available sensor metrics update live.
- Pause time is handled by builder elapsed time.
- A route is associated when location is authorized.
- Disconnecting iPhone does not lose the workout.

### Phase 3: mirrored iPhone experience

1. Install the mirroring handler during AppDelegate launch.
2. Implement WorkoutMirrorManager and WorkoutMetricsStore.
3. Support Watch-started and iPhone-started sessions.
4. Add iPhone workout card, dashboard, controls, stale state, and summary.
5. Keep navigation lifecycle independent.
6. Add reducer, ordering, batching, disconnect, and timeout tests.

Exit criteria:

- Start works in both directions.
- Pause/resume state is synchronized.
- iPhone shows all available metrics with capture age.
- A delayed batch cannot roll the UI backward.
- iPhone never saves a duplicate workout.

### Phase 4: BLE relay and protocol

1. Add WorkoutDeviceRelay and 16-byte packet builders.
2. Add the new characteristic, CAPS v6, flag bit 7, and WTLM fallback.
3. Add coalescing and reconnect resynchronization.
4. Update docs/ble-protocol.md.
5. Add iOS byte-vector, saturation, sentinel, capability, fallback, and
   reconnect tests.

Exit criteria:

- New app keeps the saved-device migration path compatible with previously
  paired old firmware; a fresh install does not silently trust an unknown
  shared-key device.
- Ownership-v2 firmware requires the ownership-capable app and intentionally
  rejects the old app-wide shared key.
- Core plus WTLM fallback is exactly 20 plaintext bytes; ownership-v2 transport
  protection expands it to a 42-byte wire write after the MTU-gated handshake.
- Missing metrics round-trip as unavailable.

### Phase 5: firmware telemetry and Ride Stats

1. Implement RAM-only WorkoutTelemetryState.
2. Parse authenticated native/fallback frames.
3. Keep workout and GPS telemetry state independent.
4. Add two-page Ride Stats presentation and staleness handling.
5. Add host/unit coverage for parser and formatter behavior.
6. Build both Waveshare environments.

Exit criteria:

- GPS packets cannot erase Watch metrics.
- Both device variants show all available fields.
- Auth, length, token, and sentinel failures are rejected safely.
- Paused, stale, ended, and idle states render correctly.

### Phase 6: real-device validation and release preparation

1. Run the complete paired Watch/iPhone/ESP32 matrix below.
2. Measure end-to-end latency and battery use.
3. Confirm Health/Fitness contains exactly one saved workout and route.
4. Update privacy policy, App Store disclosures, screenshots, and release notes.
5. Ship the ownership-capable app before ownership-v2 firmware. Existing users
   can migrate a saved legacy device through the app; do not strand old-app
   users by publishing the firmware first.

## Test strategy

### Automated iOS/watchOS tests

- WorkoutEnvelopeV1 and WorkoutSnapshotV1 round trips.
- Unknown version and malformed payload rejection.
- Sequence ordering and session replacement.
- Batched snapshots publish only the latest valid state.
- Metric precedence and no double-counting.
- Elapsed-time behavior across pause/resume.
- Sequential segment duration/distance accounting, replay safety, recovery, and
  bounded HealthKit write failure.
- Sensor/GPS speed source selection.
- Missing permissions and missing sensor values.
- Staleness transitions.
- Start timeout and remote disconnect reducers.
- Core and extended packet exact bytes.
- Numeric saturation and sentinel behavior.
- Capability bit absent/present.
- Native characteristic and WTLM fallback selection.
- Reconnect sends the latest full state once.
- Workout end does not stop navigation and vice versa.

### Firmware tests

- Exact 16-byte core and extended vectors.
- Reject unauthenticated frames.
- Reject short, long, unknown-kind, invalid-state, and token-zero active frames.
- Ignore extended frame before its matching core frame.
- Saturated maximum and unavailable sentinel formatting.
- GPS update leaves WorkoutTelemetryState unchanged.
- Explicit idle clears state.
- Staleness at the millis wrap-safe boundary.
- Page formatting for unavailable, paused, stale, ended, and failed states.
- Old 8/10/14/30-byte GPS packets continue to work.

### Physical-device matrix

Use a real paired Watch and iPhone; simulator-only validation is insufficient.

1. Start on Watch with iPhone app foreground and ESP32 connected.
2. Start on iPhone and confirm Watch wakes and owns the workout.
3. Start with no ESP32, then connect it mid-workout.
4. Disconnect/reconnect ESP32 during a ride.
5. Disable Bluetooth between Watch and iPhone, then reconnect.
6. Lock/background iPhone while navigating and measure update latency.
7. Background iPhone without navigation and verify honest stale behavior.
8. Pause/resume and mark multiple segments from Watch and iPhone.
9. End from Watch and from iPhone, then verify the segment boundaries in
   Fitness.
10. With Apple Workout active, start directly from Watch and iPhone in separate
    runs; verify any start failure or displacement is reported honestly.
11. Deny HealthKit, then deny Watch location separately.
12. Ride without external sensors.
13. Ride with cycling speed, power, and cadence sensors.
14. Force Watch workout recovery after app termination/crash.
15. Verify one workout, route, distance, energy, and available zone data in
    Health/Fitness.
16. Run at least a two-hour battery and thermal test.
17. Validate both WAVESHARE_AMOLED_175 and WAVESHARE_AMOLED_206 layouts.

## Acceptance criteria

- BikeComputer can start an outdoor cycling workout from Watch or iPhone.
- Watch is visibly and technically the primary workout owner.
- Current/average heart rate, elapsed time, distance, speed, active energy,
  altitude, and available zone/power/cadence data appear in the iPhone app.
- The same current metrics are available on the ESP32 Ride Stats pages.
- Missing optional sensors render as unavailable.
- Foreground end-to-end metric latency meets the measured three-second p95
  target or the implementation records and resolves the gap before release.
- Pauses do not inflate elapsed time or distance.
- The workout continues through iPhone and ESP32 disconnects.
- Reconnection restores one coherent latest snapshot without stale replay.
- Exactly one HKWorkout is saved, by Watch, with a route when permitted.
- Navigation and workout can start/end independently.
- Cross-app workout ownership is handled explicitly: Watch and iPhone starts
  proceed directly after setup checks because public APIs cannot detect another
  app's workout; displacement of an active BikeComputer workout is reported
  honestly.
- Existing iPhone navigation and legacy firmware GPS telemetry remain working.
- No raw health metrics are persisted on ESP32 or sent to a backend.
- iOS, watchOS, and both firmware targets pass their relevant automated and
  real-device verification.

## Expected implementation touch points

iOS/watchOS:

- ios-app/BikeComputer/BikeComputer.xcodeproj/project.pbxproj
- ios-app/BikeComputer/BikeComputer/BikeComputer.entitlements
- ios-app/BikeComputer/BikeComputer/Info.plist
- ios-app/BikeComputer/BikeComputer/BikeComputerApp.swift
- ios-app/BikeComputer/BikeComputer/Managers/BikeComputerCoordinator.swift
- ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift
- ios-app/BikeComputer/BikeComputer/ContentView.swift
- new WorkoutShared, BikeComputerWatch, manager, view, and test files

Protocol/firmware:

- docs/ble-protocol.md
- ios-app/BikeComputer/BikeComputer/Utilities/NavigationProtocol.swift or a
  new WorkoutTelemetryProtocol.swift
- ios-app/BikeComputerTests/NavigationProtocolTests.swift or focused new
  workout protocol tests
- esp32/lib/ble_navigation/ble_navigation.hpp
- esp32/lib/ble_navigation/ble_navigation.cpp
- esp32/lib/gui/src/rideTelemetryScr.hpp
- esp32/lib/gui/src/rideTelemetryScr.cpp
- focused firmware protocol/state tests

Product/release:

- PRIVACY_POLICY.md
- README.md and ios-app documentation where Watch requirements are described
- App Store privacy answers and Watch app metadata/assets

## Rollout order

1. Release the ownership-capable iOS app containing the Watch companion while
   existing users are still on old firmware.
2. Let the app migrate previously saved legacy peripherals. A fresh install
   does not use the shared app-wide key to trust an unknown old-firmware device.
3. Release ownership-v2 firmware with capability bit 7 and workout frames only
   after the compatible app is available.
4. On old firmware registered before the upgrade, keep showing legacy ride
   telemetry and tell the user that a firmware update enables Watch metrics.
5. Ownership-v2 firmware intentionally rejects old-app shared-key
   authentication; users must update the app before installing that firmware.

## Apple references

- Running workout sessions:
  https://developer.apple.com/documentation/healthkit/running-workout-sessions
- HKWorkoutSession and its one-session rule:
  https://developer.apple.com/documentation/healthkit/hkworkoutsession
- Launching the Watch workout from iPhone:
  https://developer.apple.com/documentation/healthkit/hkhealthstore/startwatchapp(with:completion:)
- Starting workout-session mirroring:
  https://developer.apple.com/documentation/healthkit/hkworkoutsession/startmirroringtocompaniondevice(completion:)
- Receiving mirrored data, including background batching behavior:
  https://developer.apple.com/documentation/healthkit/hkworkoutsessiondelegate/workoutsession(_:didreceivedatafromremoteworkoutsession:)
- Live data source and automatically collected types:
  https://developer.apple.com/documentation/healthkit/hkliveworkoutdatasource/typestocollect
- Creating and finishing a workout route:
  https://developer.apple.com/documentation/healthkit/creating-a-workout-route
- Live and completed workout-zone data:
  https://developer.apple.com/documentation/healthkit/accessing-workout-zone-data/
- Apple's Watch-to-handlebar-iPhone cycling example:
  https://developer.apple.com/videos/play/wwdc2023/10023/
