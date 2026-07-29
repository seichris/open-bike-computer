# iPhone Interactive Workout Live Activity Implementation Plan

## Outcome

Add a BikeComputer Live Activity that presents the active Watch-owned cycling
workout on the iPhone Lock Screen and in the Dynamic Island. The largest Lock
Screen and expanded presentations use the available 160-point height for:

- elapsed active workout time;
- current speed;
- cycling distance;
- current heart rate when available;
- the most recently completed user-marked segment;
- a Segment button; and
- a Pause or Resume button.

The Live Activity is a display and control surface only. The Apple Watch remains
the sole owner of `HKWorkoutSession`, `HKLiveWorkoutBuilder`, segment events,
route recording, and the saved `HKWorkout`.

## Branch and dependency baseline

This plan is stacked on `feature/workout-segments`, the head branch of PR #128.
At preparation time:

- `main` was `95bffc59776967bd33e7271169620933df5aa6e5`;
- `feature/workout-segments` was
  `c3722bd72cb1e0390b91dce050f3933155619130`;
- GitHub reported the segment branch one commit ahead of `main` and zero
  commits behind; and
- `main` was the merge base, so no merge or pull from `main` was necessary.

Keep Live Activity implementation stacked on the segment branch until PR #128
merges. After PR #128 lands, rebase the implementation branch onto the new
`main` or recreate it from `main` and cherry-pick only the Live Activity
commits. Do not merge `main` into PR #128 solely for this work.

PR #128 is treated as implemented and authoritative. In particular, reuse:

- `WorkoutControlV1.markSegment`;
- `WorkoutCompletedSegmentV1`;
- `WorkoutSnapshotV1.lastCompletedSegment`;
- `WorkoutMirrorManager.markSegment()`;
- the existing replay-safe command sequencing and acknowledgement path;
- the Watch `HKWorkoutEvent` of type `segment`; and
- the existing pending-control and `segmentMarkFailed` behavior.

Do not create another segment counter, segment persistence model, or
iPhone-owned segment writer.

## Product contract

- The Watch continues to own and save exactly one workout.
- The iPhone `WorkoutMetricsStore` remains the canonical publication boundary
  for Watch-owned workout state on iPhone.
- A verified active workout can create one Live Activity for its session.
- The Lock Screen presentation uses the maximum useful content budget: up to
  408 by 160 points on larger current iPhones and 371 by 160 points on smaller
  current iPhones.
- Dynamic Island compact and minimal presentations remain glanceable; a long
  press exposes the expanded presentation and its controls.
- Segment is enabled only while the verified workout state is running and no
  other control is pending.
- Pause is enabled only while running. Resume replaces Pause while paused.
- Button taps never mutate Live Activity state directly. They invoke the
  existing iPhone workout-control path, and the UI changes only from the
  resulting mirrored state or acknowledgement.
- A successful segment acknowledgement exposes
  `lastCompletedSegment`; rejected or timed-out segment requests remain
  nonterminal and show honest failure state.
- Dismissing, disabling, expiring, or failing the Live Activity never pauses,
  ends, discards, duplicates, or otherwise changes the Watch workout.
- End and Discard remain in the app and Watch UI. They are intentionally absent
  from the Live Activity because they are destructive, require more
  confirmation space, and are not part of the requested quick-control surface.
- No workout metric, route, or location is uploaded to a backend.

## Platform constraints

### Availability

The iPhone app keeps its iOS 15 deployment target for existing navigation
features. The Live Activity extension uses iOS 17 as its minimum because:

- the existing mirrored workout feature requires iOS 17;
- interactive Live Activity buttons require iOS 17; and
- the feature has no meaningful fallback without the mirrored Watch workout.

Wrap ActivityKit and App Intents integration in iOS 17 availability checks.
On iOS 15 and 16, the existing app and Watch behavior continues without a Live
Activity.

### Start restrictions

ActivityKit normally permits a local app to request a Live Activity only while
the app is in the foreground. Updating and ending an existing activity is
allowed while the app runs in the background.

Required behavior:

1. If a ride starts from the iPhone app, request the Live Activity after the
   first verified active Watch snapshot arrives.
2. If a ride starts on Watch while the iPhone app is already foreground,
   request it after the mirrored session and first verified snapshot arrive.
3. If a ride starts on Watch while the iPhone app is not foreground and no Live
   Activity exists, do not claim that one was created. Request it when the app
   next enters the foreground and the same workout is still verified active.
4. Continue updating an already-created Live Activity while the iPhone is
   backgrounded and receives mirrored workout updates.

Automatically starting an iPhone Live Activity for a Watch-started ride while
the iPhone app is fully backgrounded would require a system-invoked
`LiveActivityIntent` start path or ActivityKit push-to-start infrastructure.
Neither is required for the first version. Do not introduce a backend merely to
remove this limitation.

### Lock Screen authentication

The controls use `LiveActivityIntent` so the system runs their implementations
in the BikeComputer app process without presenting the app UI. iOS still
requires the person to authenticate and unlock before a button or toggle on a
locked device performs its action. Treat Face ID as part of the interaction;
do not promise a no-authentication cycling control.

Viewing the Live Activity does not require opening the app. Validate the exact
authentication experience on physical iPhones with and without Always-On
display.

### Lifetime

Live Activities are system-managed and intended for activities of up to about
eight hours. A longer Watch workout must continue and save correctly even if
the system ends or removes its Live Activity. Do not make workout ownership,
background execution, or finalization depend on ActivityKit.

## Decisions locked into this plan

1. Watch is the only HealthKit writer and workout owner.
2. `WorkoutMetricsStore.presentation` is the only source used to derive Live
   Activity content on iPhone.
3. The widget extension never reads HealthKit or talks directly to Watch.
4. Live Activity intents route into the existing `WorkoutMirrorManager`.
5. Segment success remains acknowledgement-driven and replay-safe.
6. Pause and Resume continue to use the mirrored native
   `HKWorkoutSession` controls already implemented by
   `WorkoutMirrorManager`.
7. The ActivityKit state is a narrow, display-safe projection, not a copy of
   `WorkoutSnapshotV1`.
8. No location, route, destination, navigation instruction, session token,
   control sender identity, or raw HealthKit object enters ActivityKit content.
9. No App Group is needed. ActivityKit distributes content to the extension,
   while `LiveActivityIntent` runs in the app process.
10. No APNs entitlement or `NSSupportsLiveActivitiesFrequentUpdates` setting is
    added because the first version uses local mirrored-session updates.
11. The feature shows only Segment and Pause/Resume as interactive controls.
12. User dismissal is respected for the remainder of that workout session.

## Target and project setup

Add an iOS Widget Extension named `BikeComputerLiveActivity` to
`ios-app/BikeComputer/BikeComputer.xcodeproj`.

The extension:

- has deployment target iOS 17.0;
- uses bundle identifier
  `LetItRide.BikeComputer.WorkoutLiveActivity`;
- is embedded in the `BikeComputer` application target;
- imports WidgetKit, ActivityKit, AppIntents, and SwiftUI;
- contains an `ActivityConfiguration`, not a Home Screen widget timeline;
- has no HealthKit, location, Bluetooth, networking, or App Group entitlement;
  and
- is built automatically by the main iOS scheme.

Add `NSSupportsLiveActivities` with value `true` to the iPhone app Info.plist.
Do not add `NSSupportsLiveActivitiesFrequentUpdates` without a measured need
and an APNs update design.

Suggested source layout:

```text
ios-app/BikeComputer/
  BikeComputer/
    Managers/
      WorkoutLiveActivityController.swift
    SystemActions/
      WorkoutLiveActivityCommandRouter.swift
  BikeComputerLiveActivity/
    BikeComputerLiveActivityBundle.swift
    WorkoutLiveActivityWidget.swift
    WorkoutLiveActivityViews.swift
    Info.plist
  WorkoutLiveActivityShared/
    WorkoutLiveActivityAttributes.swift
    WorkoutLiveActivityIntents.swift
    WorkoutLiveActivityFormatting.swift
  BikeComputerTests/
    WorkoutLiveActivityStateMapperTests.swift
    WorkoutLiveActivityControllerTests.swift
    WorkoutLiveActivityIntentTests.swift
```

Give `WorkoutLiveActivityShared` files target membership in both the iPhone app
and Live Activity extension. Keep business logic out of the extension. Ensure
the `LiveActivityIntent` declarations are compiled into the app target so the
system can execute them in the app process.

## ActivityKit contract

Define `WorkoutLiveActivityAttributes: ActivityAttributes`.

Static attributes:

- `sessionID: UUID`;
- `workoutStartDate: Date`; and
- an activity kind fixed to outdoor cycling if a future-proof discriminator is
  useful.

Dynamic content state:

- `phase`: running, paused, stale, disconnected, ending, or final;
- `capturedAt: Date`;
- `elapsedActiveSeconds: TimeInterval`;
- `currentSpeedKilometersPerHour: Double?`;
- `cyclingDistanceMeters: Double?`;
- `currentHeartRateBPM: Double?`;
- `lastCompletedSegmentIndex: UInt32?`;
- `lastCompletedSegmentDuration: TimeInterval?`;
- `lastCompletedSegmentDistanceMeters: Double?`;
- `pendingAction`: none, segment, pause, or resume;
- `finalOutcome`: saved, discarded, or none; and
- a narrow display error such as segment rejected or controls unavailable.

Keep the encoded attributes and content comfortably below ActivityKit's 4 KB
payload limit.

Do not place these existing values into the ActivityKit contract:

- route coordinates or altitude;
- navigation source or destination;
- HealthKit samples or objects;
- full heart-rate-zone histories;
- control sequences, tokens, sender IDs, or acknowledgements;
- raw diagnostic errors; or
- the full `WorkoutSnapshotV1`.

## State mapping

Implement a pure `WorkoutLiveActivityStateMapper` so mapping can be unit tested
without ActivityKit.

Map `WorkoutMetricsStore.presentation` as follows:

| Workout presentation | Live Activity behavior |
| --- | --- |
| Launching Watch or awaiting first snapshot | Do not start yet |
| Verified connected and running | Running content; Segment and Pause enabled when no command is pending |
| Verified connected and paused | Freeze active elapsed time; Resume enabled |
| Stale but workout remains active | Freeze instantaneous metrics and elapsed time; show Delayed; disable controls |
| Disconnected but workout remains active | Show Watch disconnected / ride continues on Watch; disable controls |
| Ending | Show Finishing; disable controls |
| Saved final snapshot | Show final time and distance, end with a 15-minute dismissal window |
| Discarded final snapshot | End and dismiss immediately |
| Failed with active Watch workout | Preserve the activity as unavailable/stale; never imply the workout ended |
| Failed or idle with no active session | End any matching activity after reconciliation |

The mapper must reject nonfinite or negative metrics and preserve optionality:
missing heart rate is an em dash, not zero.

### Elapsed-time rendering

Do not call `Activity.update` every second merely to animate elapsed time.

When running:

- derive a timer anchor as `capturedAt - elapsedActiveSeconds`; and
- render it with SwiftUI's timer-style text so the system advances the visible
  timer.

When paused, stale, disconnected, ending, or final:

- render the fixed formatted `elapsedActiveSeconds`; and
- do not let wall-clock time masquerade as active workout time.

Every new verified Watch snapshot recalibrates the timer anchor from
`HKLiveWorkoutBuilder.elapsedTime`, which already excludes pauses.

### Segment rendering

The current segment is `lastCompletedSegment.index + 1` after at least one
completed segment, otherwise segment 1.

After a Segment tap:

1. immediately publish pending Segment state from the existing
   `WorkoutMetricsStore`;
2. disable both control buttons while that command is pending;
3. wait for the existing Watch acknowledgement and mirrored snapshot;
4. show the new completed segment only when
   `lastCompletedSegment.index` advances; and
5. show a small nonterminal rejection state when the existing safe error is
   `segmentMarkFailed`.

The top status row can persist the last completed segment summary, for example
`SEG 3 · 08:42 · 4.2 KM`. Do not depend on a short-lived animation task for the
only confirmation because the app process may be suspended.

## Live Activity lifecycle controller

Add a main-actor `WorkoutLiveActivityController` owned by `AppDelegate`.
Construct it with:

- `workoutMirrorManager.store`;
- an ActivityKit client hidden behind a protocol for tests;
- an authorization provider;
- the application foreground/background state; and
- a lightweight UserDefaults suppression store containing session IDs only.

The controller subscribes to `WorkoutMetricsStore.$presentation`.

### Start

Start only when all are true:

- iOS 17 or later;
- `ActivityAuthorizationInfo().areActivitiesEnabled`;
- the app is foreground;
- the presentation contains a verified `sessionID`;
- the snapshot has a valid start date;
- the workout is running or paused; and
- the same session was not dismissed or suppressed by the user.

Use one Activity per workout session. Never create parallel activities for
individual segments.

### Update

- State transitions, pending-control changes, segment acknowledgements, stale
  transitions, and terminal state update immediately.
- Coalesce ordinary metric-only changes to at most one latest-wins update per
  second.
- Skip byte-equivalent content.
- Set `staleDate` consistently with the existing workout freshness policy.
- If content becomes stale, do not continue presenting speed or heart rate as
  current.
- Recover cleanly from ActivityKit update errors without changing workout
  state.

### Reconcile and recover

At app launch:

1. install the existing mirrored-workout handler first;
2. enumerate existing `Activity<WorkoutLiveActivityAttributes>.activities`;
3. retain at most one Activity for the verified active session;
4. end duplicates and definitively orphaned activities;
5. if the store is initially idle during a cold background launch, allow a
   bounded reconciliation grace period for HealthKit to deliver the mirrored
   session before ending an existing activity; and
6. update the retained activity from the latest verified presentation.

Observe each activity's state updates. If the person dismisses it, persist only
that session ID as suppressed until the workout ends. This prevents an app
foreground transition from recreating something the person explicitly removed.
Clear the suppression when the session reaches a terminal state.

### End

- Saved workout: publish a final summary, then end with dismissal after
  approximately 15 minutes.
- Discarded workout: end immediately.
- Missing final Watch snapshot: after the manager's bounded final-snapshot
  wait expires, publish honest unavailable-final content and end with the same
  system-owned delayed dismissal. That timeout is the Live Activity correction
  cutoff: ActivityKit end content is immutable, so a later Watch envelope may
  still correct the iPhone app's workout presentation but does not revise the
  already-ended Lock Screen card. Keep background execution asserted from the
  manager wait through completion of the controller's ActivityKit end call.
  On relaunch, the recovery grace boundary is the equivalent cutoff for a
  persisted Finishing card; retain its session tombstone after finalization so
  a late recovery cannot create a conflicting second card. Bound both waits
  by the process's remaining background time with a finalization safety margin,
  leaving time for the normal path to await ActivityKit finalization. Perform
  expiration bookkeeping synchronously and immediately queue best-effort
  cleanup, but do not claim that ActivityKit's asynchronous `end` call can
  complete inside UIKit's expiration callback. If the system suspends before
  that queued work completes, reconcile it on the next app execution. Re-evaluate
  recovered truth before every ActivityKit end in a multi-record reconciliation
  batch.
- User dismissal: stop managing the activity but do not send a workout command.
- Activity authorization disabled: stop ActivityKit work silently.
- System eight-hour expiration: allow it; the Watch workout continues.

## App Intent control routing

Define three narrow intents:

- `BikeComputerMarkSegmentIntent`;
- `BikeComputerPauseWorkoutIntent`; and
- `BikeComputerResumeWorkoutIntent`.

Each conforms to `LiveActivityIntent` and carries the `sessionID` embedded in
the Live Activity. The intent declarations are available to the extension for
`Button(intent:)`, but execution routes through the app process.

Register one app-process dependency or command router during `AppDelegate`
launch. The router owns no workout state; it holds access to the existing
`WorkoutMirrorManager` and validates against its store.

Every intent must:

1. ensure the manager and mirroring handler are installed;
2. verify the intent session ID matches the current verified session;
3. reject stale, disconnected, terminal, or conflicting pending-control state;
4. validate the expected running or paused state;
5. invoke `WorkoutMirrorManager.markSegment()`, `.pause()`, or `.resume()`;
6. return without fabricating success; and
7. let the store/controller publish pending and confirmed state.

For a cold app process launched by an intent, permit a short bounded wait for
the mirrored session handler to deliver the current session. If it does not
arrive, fail safely and leave the Watch workout untouched.

Do not create a second `WorkoutMirrorManager` for intents. The `AppDelegate`
instance remains the only iPhone workout-control owner.

## Lock Screen presentation

Use the full useful 160-point height without inserting empty space. Maintain
Apple's standard 14-point outer margin and at least 44-point control targets.

Recommended layout:

```text
┌──────────────────────────────────────────┐
│ ● RIDING / SEG 3               01:24:37 │
│                                          │
│  27.4 km/h        42.6 km        142 bpm │
│  CURRENT          DISTANCE        HEART  │
│                                          │
│ [  + SEGMENT  ]              [ Ⅱ PAUSE ] │
└──────────────────────────────────────────┘
```

Paused presentation:

- replace Riding with Paused;
- freeze the timer;
- render instantaneous speed as unavailable unless the verified paused
  snapshot explicitly provides an appropriate value; and
- replace Pause with Resume.

Stale/disconnected presentation:

- use a clear Delayed or Watch disconnected label;
- freeze the timer at the last verified active duration;
- de-emphasize or remove instantaneous speed and heart rate;
- retain cumulative distance with a Last updated treatment; and
- disable both controls.

Use `activityBackgroundTint` sparingly, verify Dark Mode and Always-On reduced
luminance, and set `activitySystemActionForegroundColor` so the system dismiss
control stays legible.

## Dynamic Island and other system presentations

### Compact

- Leading: BikeComputer cycling glyph plus running/paused indicator.
- Trailing: elapsed active time, or current speed when the timer cannot fit
  legibly.

No buttons appear in compact or minimal presentations.

### Minimal

- Show a cycling glyph with a compact running/paused status treatment.
- Do not attempt to squeeze segment, heart rate, or distance into the minimal
  region.

### Expanded

- Use the same metric priority as the Lock Screen.
- Put Segment and Pause/Resume in the bottom region with full tap targets.
- Keep expanded height at or below the 160-point system limit.

### StandBy, CarPlay, Watch, and Mac

ActivityKit can reuse these presentations on additional system surfaces.
Confirm that:

- StandBy's scaled Lock Screen view remains legible in Night Mode;
- CarPlay does not expose unsafe or clipped controls;
- the paired Watch Smart Stack presentation does not confuse the native
  BikeComputer Watch workout UI; and
- missing features on a given surface degrade to display-only content.

The native Watch workout UI remains the primary Watch control surface.

## Accessibility and privacy

- Provide combined VoiceOver labels for status, timer, each metric, segment
  summary, and control.
- Preserve Dynamic Type legibility without exceeding the 160-point height.
- Never rely only on color to distinguish running, paused, stale, and failed.
- Use monospaced digits for changing numeric values.
- Respect Reduce Motion and reduced luminance.
- Do not put route coordinates, destination names, street instructions, or raw
  errors on the Lock Screen.
- Treat heart rate as optional and omit it when unavailable rather than showing
  zero.
- Document in release notes that active workout metrics may be visible on the
  Lock Screen and Always-On display.

## Failure behavior

| Failure | Required behavior |
| --- | --- |
| Live Activities disabled | Workout continues; app omits the activity without repeated prompts |
| Live Activity dismissed | Respect dismissal for that session; workout continues |
| Watch link becomes stale | Freeze active values, show delayed state, disable controls |
| Watch disconnects | State that the ride continues on Watch; disable controls |
| Segment write rejected | Show nonterminal segment failure; do not advance segment index |
| Segment acknowledgement delayed | Keep pending state; do not optimistically show success |
| Pause/Resume confirmation delayed | Keep prior confirmed phase and pending state |
| Intent launches a cold app process | Wait briefly for the mirrored session, then fail safely |
| Intent session ID is old | Reject without affecting the current workout |
| ActivityKit update throws | Keep workout untouched and retry only from a later verified store update |
| App crashes or is terminated | Reconcile the system Activity with the recovered mirrored session |
| Workout exceeds Live Activity lifetime | Live Activity may disappear; Watch workout and save remain correct |
| Workout ends while iPhone is disconnected | Finalize from the terminal Watch snapshot when it arrives within the bounded wait; otherwise end with honest unavailable-final content and a system-owned delayed dismissal |

## Implementation phases

### Phase 1: target and shared contract

1. Add the iOS 17 Widget Extension and embed it in the iPhone target.
2. Enable `NSSupportsLiveActivities`.
3. Add shared ActivityAttributes, content state, action enum, and pure
   formatting.
4. Add running, paused, stale, disconnected, segment, and final previews.

Gate:

- iOS app still builds for the iOS 15 deployment target;
- extension builds for iOS 17;
- Watch targets and existing workout tests still build; and
- encoded ActivityKit content is below 4 KB.

### Phase 2: state mapper and lifecycle controller

1. Implement the pure presentation-to-content mapper.
2. Implement start, update, coalescing, stale-date, end, and suppression logic.
3. Install the controller after the mirrored-session handler in `AppDelegate`.
4. Implement launch reconciliation and duplicate cleanup.

Gate:

- one verified workout creates at most one Activity;
- metric-only updates are coalesced;
- pause and stale states freeze active time honestly;
- user dismissal is respected; and
- no ActivityKit failure changes workout state.

### Phase 3: interactive controls

1. Add the three `LiveActivityIntent` types.
2. Register a single app-process command dependency.
3. Route Segment, Pause, and Resume into the existing
   `WorkoutMirrorManager`.
4. Validate session identity, state, connection, and pending controls.
5. Surface pending and acknowledged state through the controller.

Gate:

- Segment advances only after PR #128's mirrored acknowledgement;
- Pause/Resume changes only after confirmed mirrored session state;
- stale or old-session actions are rejected;
- cold-process invocation fails safely when mirroring cannot recover; and
- button interaction never opens a duplicate workout or app-owned
  `HKWorkoutSession`.

### Phase 4: system-surface UI

1. Implement the maximum-height Lock Screen design.
2. Implement compact, minimal, and expanded Dynamic Island layouts.
3. Add stale, disconnected, missing-heart-rate, pending-control, segment-failed,
   saved, and discarded variants.
4. Verify accessibility, Dark Mode, Always-On, and StandBy.

Gate:

- the Lock Screen and expanded views never exceed 160 points;
- controls retain at least 44-point tap targets;
- content is not clipped at 371- and 408-point widths;
- no health metric is presented as zero when unavailable; and
- compact/minimal views remain readable with two simultaneous Live Activities.

### Phase 5: verification and rollout

1. Run automated mapper, controller, intent, and existing workout tests.
2. Build iPhone, extension, Watch app, complication, and workout test targets.
3. Complete the physical iPhone/Watch matrix.
4. Update user-facing documentation and release notes.
5. Merge only after PR #128 is merged and the implementation is rebased onto
   current `main`.

## Automated test strategy

### State mapper

- connected running snapshot maps all available primary metrics;
- missing or invalid heart rate remains unavailable;
- paused state freezes elapsed time;
- stale and disconnected state freeze instantaneous data and disable controls;
- pending Segment, Pause, and Resume map correctly;
- advancing `lastCompletedSegment.index` updates the summary;
- `segmentMarkFailed` never advances the segment;
- saved and discarded terminal outcomes map differently; and
- mismatched or missing session identity cannot start an Activity.

### Lifecycle controller

Use an ActivityKit client protocol with a fake implementation.

- foreground verified start requests one activity;
- duplicate equivalent states do not update;
- metric bursts coalesce latest-wins;
- state and segment transitions bypass metric coalescing;
- background state updates an existing Activity but does not request a new one;
- launch reconciliation retains the matching Activity and ends duplicates;
- reconciliation grace avoids ending an activity before mirroring recovers;
- user dismissal suppresses recreation for that session;
- saved outcome ends after the configured final-summary window;
- discarded outcome ends immediately; and
- ActivityKit errors do not call a workout command.

### Intents and routing

- Segment routes to `WorkoutMirrorManager.markSegment()` only while running;
- Pause routes only while running;
- Resume routes only while paused;
- old session IDs are rejected;
- stale, disconnected, terminal, and pending-control states are rejected;
- cold launch waits only for the bounded recovery interval;
- missing manager dependency fails safely; and
- the intent does not report confirmed success before the Watch response.

### Existing regression suites

Retain and run PR #128 coverage for:

- segment duration and distance accounting;
- HealthKit segment event metadata;
- remote command replay safety;
- duplicate control acknowledgement;
- recovery from existing segment events;
- segment write timeout/failure;
- sequential segments across pause and resume; and
- final segment closure at workout end.

## Physical-device validation matrix

Use a real paired Apple Watch and iPhone; simulator-only validation is
insufficient.

1. Start from iPhone foreground, receive the first Watch snapshot, lock iPhone,
   and verify the Live Activity.
2. Start from Watch while iPhone is foreground and verify the same result.
3. Start from Watch while iPhone is backgrounded and verify the documented
   deferred-start behavior when iPhone next foregrounds.
4. Mark several segments from the Lock Screen and verify each appears only
   after Watch acknowledgement and in the final HealthKit workout.
5. Pause and Resume from the Lock Screen and verify Watch, iPhone app, Live
   Activity, elapsed time, and route recording agree.
6. Authenticate button taps with Face ID from a genuinely locked device.
7. Test Dynamic Island compact, minimal with a competing Live Activity, and
   expanded presentations.
8. Test an iPhone without Dynamic Island.
9. Lock an Always-On iPhone and verify reduced-luminance contrast.
10. Test StandBy and Night Mode.
11. Disconnect Watch during a ride; verify stale/disconnected content and
    disabled controls while the Watch workout continues.
12. Reconnect Watch; verify a coherent latest snapshot restores the activity.
13. Kill and relaunch the iPhone app; verify Activity reconciliation and intent
    routing recover without a duplicate workout.
14. Dismiss the Live Activity manually; verify it stays dismissed and the
    workout continues.
15. Disable Live Activities for BikeComputer; verify the workout is unaffected.
16. End and Save from Watch and from iPhone in separate rides; verify the final
    summary and delayed dismissal.
17. Discard a test ride; verify immediate Live Activity dismissal and no saved
    workout.
18. Run with heart rate unavailable and confirm no false zero.
19. Run with a segment write failure injection and confirm nonterminal failure.
20. Simulate an eight-hour ActivityKit expiration and confirm Watch workout
    ownership and saving remain independent.

## Acceptance criteria

- A verified active BikeComputer workout can present a Live Activity on iPhone.
- The Lock Screen layout uses the maximum useful 160-point content budget and
  fits both 371- and 408-point widths.
- Elapsed active time, current speed, cycling distance, and optional heart rate
  are legible at a glance.
- Segment and Pause/Resume are available on the Lock Screen and expanded
  Dynamic Island presentation.
- Segment uses PR #128's existing replay-safe Watch command and
  acknowledgement; no duplicate segment system exists.
- Pause/Resume uses the existing mirrored `HKWorkoutSession`.
- Pending, stale, disconnected, failed, paused, and final states are honest.
- A button for an old or mismatched workout session cannot affect the current
  workout.
- Live Activity dismissal, failure, disablement, or expiration cannot alter the
  Watch workout.
- Watch remains the only HealthKit writer and exactly one workout is saved.
- No raw health metrics, route coordinates, or navigation destinations are
  persisted in an App Group or sent to a backend.
- The app keeps its iOS 15 navigation compatibility; Live Activity features
  activate on iOS 17 or later.
- App, Live Activity extension, Watch app, Watch complication, and workout test
  targets build successfully.
- The complete physical-device matrix passes before release.

## Expected implementation touch points

Project and configuration:

- `ios-app/BikeComputer/BikeComputer.xcodeproj/project.pbxproj`
- `ios-app/BikeComputer/BikeComputer/Info.plist`
- new `ios-app/BikeComputer/BikeComputerLiveActivity/` target
- new `ios-app/BikeComputer/WorkoutLiveActivityShared/` shared files

iPhone app:

- `ios-app/BikeComputer/BikeComputer/BikeComputerApp.swift`
- new
  `ios-app/BikeComputer/BikeComputer/Managers/WorkoutLiveActivityController.swift`
- new
  `ios-app/BikeComputer/BikeComputer/SystemActions/WorkoutLiveActivityCommandRouter.swift`
- `ios-app/BikeComputer/BikeComputer/Managers/WorkoutMirrorManager.swift` only
  if a narrow async/control-routing adapter is required
- `ios-app/BikeComputer/BikeComputer/Managers/WorkoutMetricsStore.swift` only
  if a narrow observation helper is required

Tests:

- new focused Live Activity mapper/controller/intent tests under
  `ios-app/BikeComputer/BikeComputerTests/`
- existing `WorkoutContractTests.swift`
- existing `WorkoutMirrorManagerTests.swift`
- existing Watch workout manager tests

Documentation:

- `README.md` or iOS documentation for availability and Watch-start behavior
- release notes for Lock Screen metric visibility and authentication

## Apple references

- Live Activities Human Interface Guidelines:
  https://developer.apple.com/design/human-interface-guidelines/live-activities
- Displaying live data with Live Activities:
  https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- Adding interactivity to widgets and Live Activities:
  https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
- `LiveActivityIntent`:
  https://developer.apple.com/documentation/appintents/liveactivityintent
- Building a workout app for iPhone and iPad:
  https://developer.apple.com/documentation/healthkit/building-a-workout-app-for-iphone-and-ipad
- Building a multidevice workout app:
  https://developer.apple.com/documentation/healthkit/building-a-multidevice-workout-app
