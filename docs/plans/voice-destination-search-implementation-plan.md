# Voice Destination Search Implementation Plan

Prepared on 2026-08-31 from freshly fetched GitHub `origin/main` at
`9ef7f09fce0e0d95e349e6ef9c54da137fcff286` on branch
`feature/voice-address-search`.

Implementation status: planning only. No feature code is implemented on this
branch. This document is the proposed implementation contract for
[issue #153](https://github.com/seichris/open-bike-computer/issues/153). It does
not change firmware, the BLE protocol, or navigation behavior on the physical
Bicino device.

## Outcome

Add an always-available microphone action to the active iPhone destination
search field. A rider can dictate a place or address, see the live transcript
become the existing MapKit query, and explicitly choose a suggestion before
starting navigation.

The complete flow is:

1. Expand destination search and tap the microphone.
2. Bicino requests microphone and speech-recognition permission just in time.
3. Bicino listens to one short destination phrase and updates the search text
   from partial recognition results.
4. The existing `MKLocalSearchCompleter` produces nearby addresses and points
   of interest from that text.
5. The rider taps the intended MapKit completion.
6. Bicino resolves that exact completion to an `MKMapItem`, stores its
   coordinate in `SavedDestination`, and presents the existing route controls.
7. The existing **Go** action calculates the route.

Voice input never chooses the first result and never starts navigation. Typed
search remains available before, during, and after the feature rollout.

## Current `main` baseline

- `ContentView.routeAndWorkoutStartRow` presents the active
  `RouteSearchPanel` from `Views/RouteInputView.swift`.
- `RouteSearchPanel` binds `destinationAddress` to a `TextField` and sends each
  edit to `AddressSearchCompleter`.
- `AddressSearchCompleter` already searches addresses, points of interest, and
  free-form queries, biased to a 50-kilometer region around the current
  location.
- Tapping a completion currently converts its title and subtitle to a plain
  string. Route calculation later performs a second natural-language search
  and may therefore choose a different result.
- `SavedDestination` already supports an optional coordinate and produces a
  coordinate-bearing `RouteEndpoint.mapItem` when one is present.
- The app supports iOS 16.4. Xcode 26 exposes the modern Speech framework only
  on iOS 26 and newer, while `SFSpeechRecognizer` supports the existing
  deployment range.
- The app has no microphone or speech-recognition usage descriptions and no
  current audio capture path.

The older modal `RouteInputView` in the same source file is not instantiated
by the current app. This feature targets `RouteSearchPanel` only so the branch
does not expand an already-dead UI path.

## Architecture decision

Use a hybrid Apple-native speech architecture behind one testable controller:

```text
RouteSearchPanel microphone
          |
          v
DestinationVoiceSearchController
  - one mutually exclusive state
  - previous-query snapshot
  - stale-event generation guard
  - permission/start/stop/cancel lifecycle
          |
          +---- iOS 26+
          |       SpeechAnalyzer
          |       SpeechTranscriber when available
          |       DictationTranscriber fallback
          |       downloaded Apple on-device assets
          |
          +---- iOS 16.4-25
                  SFSpeechRecognizer
                  taskHint = .search
                  on-device recognition when supported
                  Apple service fallback when necessary
          |
          v
destinationAddress -> MKLocalSearchCompleter
          |
          v
explicit completion tap
          |
          v
MKLocalSearch.Request(completion:)
          |
          v
coordinate-rich SavedDestination -> existing route planner
```

### Why this option

- It keeps the current iOS 16.4 support promise instead of hiding the feature
  from most installed devices.
- It adopts Apple's current, on-device SpeechAnalyzer path where the operating
  system supports it.
- It retains a mature fallback without introducing a third-party speech SDK,
  API key, audio upload service, or a second privacy boundary.
- A shared controller gives both backends identical UI, state, cancellation,
  and test behavior.
- It is replaceable: the view depends on normalized events rather than either
  Speech API directly.

### Alternatives considered

| Approach | Benefit | Cost and decision |
| --- | --- | --- |
| `SFSpeechRecognizer` only | Smallest implementation and widest support | Leaves the app on the legacy API indefinitely and can use Apple's recognition service. Rejected as the long-term architecture. |
| SpeechAnalyzer only | Fully on-device modern stack | Requires iOS 26, model availability, and a large compatibility break. Rejected while the app supports iOS 16.4. |
| System keyboard dictation only | No app-owned audio session | Not discoverable as a Bicino feature and gives the app no reliable start, stop, status, or cancellation contract. Kept as an incidental fallback, not the feature. |
| Third-party or self-hosted speech | Potentially uniform engine behavior | Adds audio transport, credentials, cost, latency, retention policy, and another privacy/security surface. Rejected for destination search. |
| Auto-search and choose the first result | Fastest happy path | Unsafe for ambiguous place names and can route to the wrong city. Explicitly rejected. |

## Product contract

### Search-field behavior

- Put a microphone button at the trailing edge of the destination field.
- Keep the clear button available when there is text; both actions have at
  least a 44-by-44-point hit target.
- Tapping the microphone dismisses the keyboard and starts a short recognition
  session. Tapping it again stops and finalizes the current phrase.
- Use a red filled microphone and a listening label while audio capture is
  active. Use progress UI while permissions, models, or the recognizer prepare.
- Partial transcripts replace the destination query and feed the existing
  completer. The user can tap a suggestion as soon as it appears.
- Do not append to old search text. Snapshot the old query, replace it while
  dictating, and restore it after cancellation, no speech, or startup failure.
- A successful final transcript remains editable. Recognition does not mark it
  as a selected destination.
- Present concise inline status or error text below the field. Permission denial
  must explain that typed search still works and offer an **Open Settings**
  action.
- Do not show a modal alert for normal cancellation or an audio interruption.

### Recognition state machine

The feature has one source of truth:

```text
idle
  -> requestingPermission
  -> preparing
  -> listening
  -> finalizing
  -> idle

requestingPermission / preparing / listening / finalizing
  -> failed(message, offersSettings)
  -> idle on the next attempt or text edit

any active state
  -> idle on explicit cancel or lifecycle teardown
```

`DestinationVoiceSearchState` is mutually exclusive and derives button image,
color, accessibility label, progress visibility, and helper text. The view
does not maintain parallel booleans for those facts.

Every start creates a monotonically increasing generation. Backend callbacks
must carry the active generation; a completion from an old or cancelled task
cannot overwrite a newer typed query or recognition session.

### Permissions and privacy

- Add `NSMicrophoneUsageDescription` and
  `NSSpeechRecognitionUsageDescription` to both the production plist and its
  checked-in template.
- Ask for both permissions only after a microphone tap.
- Treat denied and restricted access as recoverable search errors. The search
  field remains usable and the UI can open the app's Settings page.
- On iOS 26, install and use Apple SpeechAnalyzer assets on device.
- On older systems, set `requiresOnDeviceRecognition` when the selected
  recognizer supports it; permit Apple's service fallback when it does not so
  the feature remains available across the supported OS range.
- Capture microphone buffers only for the active request. Do not persist raw
  audio, transcripts, or recognition diagnostics, and do not print dictated
  content to logs.
- Do not add an audio background mode.

### Audio-session ownership

- Use a short-lived `AVAudioSession` with `.playAndRecord` and `.spokenAudio`
  for a voice-focused capture session that remains compatible with routed
  input devices.
- Activate immediately before installing the input tap.
- Stop the engine, remove its tap, cancel or finalize the recognizer, and
  deactivate with `.notifyOthersOnDeactivation` on every terminal path.
- Treat route changes and audio interruptions as cancellation, not as a reason
  to retain the microphone.

### Lifecycle cleanup

Cancel recognition and restore the previous query when:

- the search panel collapses;
- the destination is cleared;
- the rider starts editing the source field;
- a destination suggestion or saved destination is selected;
- navigation starts;
- the app resigns active or enters the background; or
- the audio session is interrupted or its input route becomes unavailable.

The controller owns speech-task cancellation. `@FocusState` remains local to
`RouteSearchPanel`; service code never manipulates keyboard focus.

## Exact MapKit completion resolution

Voice makes ambiguity more visible, so the implementation also repairs the
current typed-search selection seam.

When a rider taps an `MKLocalSearchCompletion`:

1. Cancel any older selection-resolution request.
2. Build `MKLocalSearch.Request(completion:)` from the exact tapped object.
3. Resolve it with `MKLocalSearch` and require the first returned map item to
   have a valid coordinate.
4. Use the map item's name plus formatted postal address for the display name
   when available; otherwise preserve the completion title/subtitle.
5. Create `SavedDestination(name:coordinate:)` and pass its `.mapItem` endpoint
   through the existing route planner.
6. Show a bounded inline error and keep the query editable if the lookup fails.

This behavior applies equally to typed and spoken queries. A selected
completion is not converted back into a new natural-language search.

## Source layout

Add narrowly scoped files under the synchronized iPhone target:

- `Models/DestinationVoiceSearch.swift`
  - normalized state, errors, backend protocol, and controller;
- `Services/AppleDestinationVoiceSearchBackend.swift`
  - just-in-time permission client, iOS 26 SpeechAnalyzer backend, legacy
    SFSpeechRecognizer backend, audio capture, and backend factory;
- `Views/RouteInputView.swift`
  - microphone UI, local focus coordination, lifecycle hooks, and exact
    completion resolution;
- `Info.plist` and `Info.plist.template`
  - privacy usage descriptions;
- `BikeComputerTests/DestinationVoiceSearchTests.swift`
  - deterministic controller tests with fake permissions and backends;
- `scripts/run-navigation-tests.sh`
  - compile and run the new portable state-machine test executable.

The Xcode project uses a file-system-synchronized `BikeComputer` group, so new
production files do not require hand-editing `project.pbxproj`.

## Verification contract

### Deterministic automated tests

Cover at least:

- granted, denied, and restricted permission results;
- permission request ordering;
- preparing, listening, and finalizing transitions;
- partial and final transcript propagation;
- cancellation restoring the previous query;
- no-speech and startup errors restoring the previous query;
- stale callbacks from an old generation being ignored;
- a second session replacing the first without shared state;
- lifecycle teardown cancelling the backend;
- whitespace-only recognition never replacing a useful query; and
- permission errors carrying the **Open Settings** affordance only when useful.

Run:

```sh
cd ios-app
./scripts/run-navigation-tests.sh
```

### Build and static checks

Run:

```sh
cd ios-app
./scripts/xcodebuild-cli.sh -project BikeComputer/BikeComputer.xcodeproj \
  -scheme BikeComputer -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
plutil -lint BikeComputer/BikeComputer/Info.plist
plutil -lint BikeComputer/BikeComputer/Info.plist.template
git diff --check
```

### Physical acceptance gates after the pull request

Automated builds cannot prove microphone routing or transcription quality.
Before release, validate on at least one iOS 26 iPhone and one iOS 16.4-25
iPhone:

- first-use permission prompts and denial recovery;
- a precise street address, nearby point of interest, and ambiguous place name;
- noisy outdoor speech and a Bluetooth audio route;
- interruption by a call or another audio session;
- panel collapse, backgrounding, and immediate second attempts;
- no lingering recording indicator after every exit path;
- exact selected pin and route destination; and
- VoiceOver labels, Dynamic Type, and 44-point hit targets.

Physical testing is a post-PR acceptance gate and is not implied by a green
command-line build.

## Non-goals

- Wake words, always-listening audio, Siri/App Intents, or lock-screen capture;
- spoken turn-by-turn directions or firmware speaker output;
- voice commands for workout or device controls;
- source-location dictation in this release;
- custom language models or stored address vocabulary;
- automatic destination selection or navigation start;
- third-party geocoding, speech services, or transcript analytics; and
- any BLE, ESP32, Watch, map-platform, or offline-map format change.

## Rollout and reversibility

The feature is additive and has a typed-search fallback. Backend selection is
runtime-gated by OS and locale support; no server or firmware rollout is
required. If recognition fails in production, the microphone path can be
removed without changing saved destinations, the route planner, or MapKit
search data. The exact completion resolver should remain because it independently
improves typed destination correctness.
