# Cycling Sensor Settings and Workout Tile Gating Plan

## Outcome

Add an explicit cycling-sensor registry to the BikeComputer iPhone app. A
person can enroll a cadence sensor, power meter, or combined cadence-and-power
sensor from Settings, give it a custom name, and later edit, disable, or forget
it.

The workout stats sheet shows cadence and power tiles only for capabilities
that the person has enrolled and enabled:

- no enrolled cadence sensor: no cadence tile;
- no enrolled power sensor: no power tile;
- enrolled cadence sensor: show cadence, using `--` when no fresh value exists;
- enrolled power sensor: show power, using `--` when no fresh value exists; and
- enrolled combined sensor: show both tiles.

Fresh data can discover a sensor and prompt the person to enroll it, but it
must never enroll a sensor or reveal a tile automatically.

This plan is associated with
[issue #85, Pair directly with BLE cycling sensors and accessories](https://github.com/seichris/open-bike-computer/issues/85).
It delivers the Apple Watch/HealthKit-assisted sensor-management slice of that
issue. It does not complete issue #85's separate direct-to-ESP32 BLE work.

## Baseline

This plan was prepared from `origin/main` at
`d41112a3f91d51bf4cebec98bc522671e042792f`.

### Already implemented

The metric transport and most of the runtime measurement path already exist:

1. `WatchWorkoutManager` owns an `HKWorkoutSession` and
   `HKLiveWorkoutBuilder`.
2. The Watch requests cycling power and cycling cadence from HealthKit.
3. The live builder delegate handles `cyclingPower` and `cyclingCadence`,
   converts them to watts and RPM, and expires stale sensor values after the
   existing paired-sensor freshness window.
4. `WorkoutSnapshotV1` carries optional `cyclingPower` and `cyclingCadence`
   metrics from Watch to iPhone.
5. `WorkoutMetricsStore` publishes those mirrored values on iPhone.
6. `WorkoutDeviceRelay` can relay both metrics from iPhone to the paired bike
   computer.
7. `NavigationDetailsView` already renders cadence and power tiles.

This explains why the tiles can display real values today when a compatible
sensor is connected to Apple Watch and the BikeComputer Watch app owns an
active cycling workout.

### Not implemented

The current code does not have:

- an app-owned sensor registry;
- a sensor discovery or enrollment flow;
- an editable sensor name;
- a persisted enabled/disabled choice;
- a reliable physical sensor identifier in the workout mirror contract;
- a detected-sensor notification;
- a deep link from that notification to sensor settings; or
- tile gating based on a person's enrolled sensors.

Today, the cadence and power tiles are always present and use `--` when their
optional workout metrics are absent.

## Apple platform contract

Apple Watch owns system pairing for compatible cycling accessories. The person
pairs one in **Apple Watch Settings > Bluetooth > Health Devices**. Apple says a
configured accessory automatically connects when a cycling workout begins and
can supply cadence and power metrics:

- [Go cycling with Apple Watch](https://support.apple.com/en-ca/guide/watch/apd4cbc876c7/watchos)

BikeComputer's Watch app already receives live data through
`HKLiveWorkoutBuilderDelegate`:

- [HKLiveWorkoutBuilderDelegate](https://developer.apple.com/documentation/healthkit/hkliveworkoutbuilderdelegate)

HealthKit samples can have source and device metadata, but the callback used by
the current implementation supplies `HKStatistics`, not a physical peripheral
or a public list of connected Health Devices:

- [HKQuantitySample](https://developer.apple.com/documentation/healthkit/hkquantitysample)
- [HKSourceRevision](https://developer.apple.com/documentation/healthkit/hksourcerevision)

Therefore, **Connect a new Sensor** is an app enrollment flow, not a replacement
for Apple's Bluetooth pairing UI. It listens for actual sensor observations
from an active BikeComputer workout. It must not claim that BikeComputer is
pairing the accessory to Apple Watch.

When no BikeComputer workout is active, the sensor screen must explain:

1. pair the sensor under Apple Watch Settings > Bluetooth > Health Devices;
2. wake the sensor by pedaling or rotating the crank; and
3. start or continue an outdoor cycling workout in BikeComputer.

The existing iPhone app deployment target remains iOS 16.4, and the existing
Watch target remains watchOS 10. The workout mirroring path continues to use its
current iOS 17 availability boundary.

## Product definitions

Use the following terms consistently in code and UI:

- **System-paired**: Apple Watch knows the accessory under Health Devices.
  BikeComputer cannot infer this merely from app settings.
- **Observed**: BikeComputer received live cadence or power data during the
  current workout.
- **Enrolled**: the person added a sensor profile to **My Sensors**.
- **Enabled**: the enrolled profile is allowed to control stats-tile
  visibility.
- **Reporting**: fresh data matching the profile is currently arriving.

In product copy, the requested word **Connect** means “enroll this sensor in
BikeComputer.” Internally, use `enroll`/`enrolled` to avoid confusing app state
with an active Bluetooth connection.

Do not show a row as **Connected** merely because it is enrolled. Use runtime
status such as **Data received now**, **Last seen recently**, or
**Not currently reporting**.

## Decisions locked into this plan

1. Sensor enrollment is explicit and local to the iPhone app.
2. Live metric freshness does not decide whether a tile exists.
3. Fresh observations can propose enrollment but cannot enroll automatically.
4. Cadence and power tile visibility is the union of capabilities on enabled
   enrolled profiles.
5. An enrolled tile remains visible and changes to `--` when data becomes
   stale or the sensor disconnects.
6. An unenrolled tile stays hidden even if an unaccepted live observation has a
   fresh value.
7. Sensor discovery listens only to current BikeComputer workout data. It does
   not scan HealthKit history.
8. The iPhone owns names and enrollment choices. The Watch owns workout
   collection.
9. The first version does not ask iPhone `CoreBluetooth` to pair with a sensor
   already managed by Apple Watch.
10. A combined cadence-and-power device is inferred automatically only when
    both measurements can be tied to the same stable device identity.
11. If HealthKit does not expose a safe stable identity, use an honest logical
    sensor profile and require the person to confirm its capabilities.
12. Sensor metadata and workout metrics remain local. No backend is added.

## Phase 0: physical-device identity feasibility gate

Complete this spike before choosing the persisted identity model.

### Test matrix

Run a BikeComputer-owned cycling workout on physical devices with:

- one cadence-only sensor;
- one power-only sensor;
- one combined cadence-and-power sensor;
- separate cadence and power sensors active simultaneously; and
- two sensors of the same capability, if hardware is available.

For each setup, inspect the live and newly stored HealthKit samples for:

- `HKObject.device`;
- `HKObject.sourceRevision`;
- manufacturer, model, hardware, firmware, local identifier, and UDI fields;
- whether the metadata is present during the workout or only after storage;
- whether the identity is stable after disconnect/reconnect and across
  workouts;
- whether cadence and power from one combined device share the same identity;
  and
- whether separate devices remain distinguishable.

Do not log raw identifiers in ordinary production diagnostics. The spike may
use a local debug build with redacted or hashed output.

### Gate A: stable physical identity is available

If a public HealthKit path exposes a stable identity with acceptable latency:

- derive an app-local opaque identifier;
- store only the minimum fields needed to match observations;
- use a non-sensitive manufacturer/model string as a suggested name when
  available;
- never persist or mirror a serial number or UDI;
- associate observed capabilities with that identity; and
- allow multiple sensors with the same capability in **My Sensors**.

### Gate B: stable physical identity is not available

If HealthKit supplies only values or an Apple Watch/app source:

- do not invent a physical device identifier;
- create a logical candidate such as **Cadence Sensor**, **Power Sensor**, or
  **Cycling Sensor**;
- ask the person to confirm **Cadence**, **Power**, or **Cadence + Power** when
  enrolling;
- describe status as measurement data received, not hardware connected;
- do not merge simultaneous cadence and power into one physical sensor without
  explicit confirmation; and
- document that multiple same-capability accessories cannot be distinguished
  through the HealthKit-assisted path.

Gate B still supports every tile-visibility requirement. It limits only
automatic device naming and physical-device differentiation.

Record the result of the spike in the eventual implementation PR and add a
focused code comment at the identity boundary. Do not leave production behavior
dependent on debug-only assumptions.

## Persisted model

Add a versioned, Codable registry owned by a `@MainActor`
`CyclingSensorStore`.

Suggested types:

```swift
struct CyclingSensorCapabilities: OptionSet, Codable, Sendable {
    let rawValue: UInt8

    static let cadence = Self(rawValue: 1 << 0)
    static let power = Self(rawValue: 1 << 1)
}

enum CyclingSensorIdentityKind: Codable, Sendable {
    case healthKitDevice(opaqueID: String)
    case logical
}

struct CyclingSensorProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var capabilities: CyclingSensorCapabilities
    var isEnabled: Bool
    let identityKind: CyclingSensorIdentityKind
    let createdAt: Date
    var lastObservedAt: Date?
}
```

The exact representation can change after Phase 0, but the store must expose:

- ordered `profiles`;
- `enabledCapabilities`;
- create/enroll;
- rename;
- enable/disable;
- forget;
- match an observation to an existing profile; and
- versioned decoding with corruption fallback that does not crash app launch.

Persist registry metadata in `UserDefaults` under a new versioned key. Do not
put raw workout samples, live values, or HealthKit objects in that registry.

No migration should auto-enroll cadence or power based on previously seen
workout data. Existing users start with no enrolled sensors, so both tiles are
hidden until they make an explicit choice.

## Observation and discovery model

Use a separate ephemeral `CyclingSensorDetectionCoordinator`.

An observation contains:

- optional opaque physical identity from Phase 0;
- observed capabilities;
- safe suggested display name, if available;
- `firstObservedAt` and `lastObservedAt`;
- current workout session ID; and
- whether it has already been offered, dismissed, enrolled, or matched.

The coordinator:

1. accepts only current, validated mirrored workout snapshots;
2. treats a non-stale cadence metric as a cadence observation;
3. treats a non-stale power metric as a power observation;
4. merges observations only when their identity is proven equal;
5. matches them against the sensor registry;
6. publishes nearby candidates to the Settings UI;
7. publishes at most one actionable enrollment prompt; and
8. deduplicates repeated snapshots and rapid reconnects.

Keep observations for the current workout plus a short enrollment grace period
so a person can tap the notification and still see the candidate. Clear
unresolved candidates at a defined boundary, such as after the workout plus 30
minutes. Persist only a small prompt-dismissal token if needed to prevent a
notification loop after app relaunch.

Do not observe SwiftUI view rendering or the formatted `--` strings. Feed the
detection coordinator from the accepted snapshot boundary in
`WorkoutMirrorManager` or immediately after `WorkoutMetricsStore.ingestBatch`.

## Watch-to-iPhone contract

### Capability-only path

The existing optional `cyclingCadence` and `cyclingPower` metrics are sufficient
to detect capabilities. If Phase 0 returns Gate B, no workout schema change is
required for initial enrollment.

### Identity-aware path

If Phase 0 returns Gate A, extend `WorkoutSnapshotV1` with an optional, bounded
array of `CyclingSensorObservationV1` values:

```swift
struct CyclingSensorObservationV1: Codable, Equatable, Sendable {
    let opaqueDeviceID: String
    let suggestedName: String?
    let capabilities: CyclingSensorCapabilitiesV1
    let observedAt: Date
}
```

Requirements:

- bump the minor workout schema version from 1.4 to 1.5;
- keep the new field optional with an empty default for old payloads;
- reject malformed, future-dated, oversized, or duplicate observations;
- cap the array to a small number such as eight;
- never include serial number, UDI, or unrestricted metadata;
- preserve major-version compatibility; and
- add mixed-version encode/decode tests.

The Watch should emit identity observations only after correlating a fresh
sample to a validated identity. A statistics update by itself is not proof of
identity.

## Settings information architecture

Extend the existing **My Bike Computer** page so its form contains both the
current Bike Computer list and a new **My Sensors** group. Do not add another
navigation level between **My Bike Computer** and the sensor list.

Refactor `BikeComputersSettingsView` only as much as necessary to compose its
existing content with `CyclingSensorsSettingsSection`. Preserve its current
Bike Computer discovery, pairing, editable detail, reconnect, and deregistration
behavior.

The new sensor group follows the established Bike Computer interaction pattern:

### Default state

- Section label: **My Sensors**
- Empty state: **No Sensors**
- Supporting text: **Add a sensor after BikeComputer receives cadence or power
  data from your Apple Watch.**
- Action: **Connect a new Sensor**

Show the action even when profiles already exist so another sensor can be
enrolled.

### Looking state

Tapping **Connect a new Sensor** starts an enrollment-listening session and
shows:

- `ProgressView`;
- **Looking nearby…**; and
- a short instruction footer explaining the Apple Watch Health Devices setup.

If no workout is active, do not spin indefinitely with no explanation. Show
the three setup steps from the platform contract and keep the listener ready
for the next BikeComputer workout. Provide **Stop Looking**.

When fresh observations arrive, list unmatched candidates under **Nearby**.
Do not list already enrolled profiles as new candidates.

### Enrollment sheet

Tapping a candidate opens a sheet modeled after the existing Bike Computer
pairing sheet:

- proposed name;
- editable name;
- detected capability or capability confirmation;
- explanation that Apple Watch manages the Bluetooth connection; and
- primary action **Connect Sensor**.

The action writes the profile to the registry. Only after that commit succeeds
may the corresponding stats tile appear.

### My Sensors rows and detail

Each enrolled profile appears under **My Sensors**. A row contains:

- sensor name;
- capability summary: **Cadence**, **Power**, or **Cadence + Power**;
- enabled/disabled state; and
- reporting status when a matching live observation exists.

Tapping a row opens `CyclingSensorDetailView`, following
`BikeComputerDetailView`:

- edit and save the custom name;
- enable or disable the sensor;
- show capabilities;
- show **Data received now** or a last-seen description;
- explain the Apple Watch Health Devices relationship; and
- **Forget Sensor** behind confirmation.

Disabling or forgetting the last enabled profile for a capability immediately
hides that capability's tile. Renaming never changes matching identity.

## Detected-sensor bottom notification

Reuse the visual language of the current offline-map status chip, but extract a
small reusable actionable status-chip view instead of copying the layout.

Show the sensor chip when:

- a BikeComputer workout is active;
- a fresh cadence or power observation was accepted;
- no enabled enrolled profile covers that observation;
- the candidate was not dismissed for the current workout; and
- an enrollment screen is not already visible.

Copy:

- title: **Cadence sensor detected**, **Power sensor detected**, or
  **Cycling sensor detected**;
- action/subtitle: **Connect sensor?**

Tapping the chip opens **My Bike Computer**, focuses its **My Sensors** group,
and preserves the candidate so it is immediately selectable. This needs a real
settings route, not just `presentedSheet = .settings`.

Add a typed settings destination, for example:

```swift
enum SettingsDestination: Hashable {
    case bikeComputer(sensorCandidateID: UUID?)
    case offlineMaps
}
```

Use `NavigationStack`/`NavigationPath` or a dedicated sheet destination so
opening the chip reliably lands on the combined **My Bike Computer** page with
the sensor candidate visible. Do not depend on timing delays, hidden
`NavigationLink` activation, or a nested sensor-management page.

Provide a non-destructive dismissal. **Not Now** suppresses the same candidate
for the current workout; it does not enroll, disable, or forget anything. A
future workout can offer it again.

If both an offline-map status and sensor prompt are eligible, show one
actionable chip at a time. Sensor enrollment has priority while its observation
is fresh; the offline-map chip returns after enrollment, dismissal, or expiry.
The normal workout/navigation controls remain visible.

## Workout stats tile rules

Move tile selection out of an unconditional array literal into a testable
policy:

```swift
struct WorkoutMetricTilePolicy {
    let enabledSensorCapabilities: CyclingSensorCapabilities

    var showsCadence: Bool { enabledSensorCapabilities.contains(.cadence) }
    var showsPower: Bool { enabledSensorCapabilities.contains(.power) }
}
```

Inject `CyclingSensorStore` into `RideMetricsPanel` or pass its
`enabledCapabilities` explicitly.

Build the metric list in this order:

1. elapsed;
2. cadence, only when enabled;
3. power, only when enabled;
4. speed;
5. distance;
6. altitude;
7. heart rate;
8. heart zone; and
9. energy.

The compact and expanded layouts use the same filtered metric list. Preserve
the current compact/expanded sizing and formatting work:

- compact state uses its existing grid policy;
- expanded state keeps the speed hero and two stats per row;
- numeric value styling remains unchanged;
- units such as `km/h`, `m`, `bpm`, and `kcal` keep their secondary gray,
  smaller styling; and
- a registered but stale cadence/power value renders as `--`, not zero.

Enrollment affects workout stats tiles, including workouts shown while
navigation is active. Navigation-only stats remain unchanged and never gain
cadence or power tiles.

Do not filter completed workout history solely because a sensor is later
forgotten. The registry controls the live ride sheet; historical summaries
continue to display measurements that were actually recorded.

## Dependency wiring

Create:

```text
ios-app/BikeComputer/BikeComputer/
  Models/
    CyclingSensorProfile.swift
  Managers/
    CyclingSensorStore.swift
    CyclingSensorDetectionCoordinator.swift
  Views/
    CyclingSensorsSettingsSection.swift
    CyclingSensorDetailView.swift
    CyclingSensorEnrollmentSheet.swift
    ActionStatusChip.swift
```

Recommended ownership:

- `AppDelegate` creates the long-lived `CyclingSensorStore` and detection
  coordinator;
- `WorkoutMirrorManager` forwards accepted live snapshots to the coordinator;
- `ContentView` observes pending prompts and owns sheet/deep-link routing;
- `SettingsView` receives the store/coordinator through environment injection;
  and
- ride-metrics views receive the registry's enabled capabilities.

Do not add cycling sensors to `BLEManager.knownDevices`. That registry represents
BikeComputer peripherals, ownership handshakes, and authenticated app-to-ESP32
connections. Apple Watch cycling sensors have different ownership, transport,
and status semantics.

If Gate A requires Watch-side observation state, add the narrowest possible
Watch component and shared contract type. Do not move iPhone-owned names or
enable choices into `WatchWorkoutManager` unless a Watch UI or collection rule
actually needs them.

## Implementation sequence

### 1. Prove identity behavior

- run the Phase 0 physical-device matrix;
- choose Gate A or Gate B;
- capture redacted evidence in the implementation PR; and
- lock the observation contract before building UI.

### 2. Add the registry and pure policies

- implement the profile/capability model;
- add versioned persistence;
- implement enrollment, rename, enable/disable, and forget;
- implement observation matching and prompt deduplication; and
- implement `WorkoutMetricTilePolicy`.

### 3. Feed live observations

- observe only accepted current workout snapshots;
- classify fresh cadence and power;
- add the optional identity-aware mirror field only for Gate A;
- retain a candidate long enough for notification-to-settings navigation; and
- keep workout collection and save behavior unchanged.

### 4. Build My Sensors UI

- compose the new **My Sensors** group into the existing **My Bike Computer**
  page;
- implement the empty, looking, nearby, enrollment, list, and detail states;
- add no-active-workout instructions;
- support editable names and confirmed forget; and
- ensure leaving the screen stops only the enrollment listener, not the
  workout.

### 5. Add prompt and deep link

- extract the shared action chip presentation;
- add the sensor prompt;
- add typed routing to the sensor screen;
- implement priority against the offline-map chip; and
- add per-workout dismissal behavior.

### 6. Gate live workout tiles

- filter cadence and power by enabled registry capabilities;
- preserve `--` for enrolled-but-stale sensors;
- apply the same policy during active workout plus navigation;
- leave navigation-only metrics unchanged; and
- leave recorded workout summaries data-driven.

### 7. Validate and document

- run unit and contract tests;
- test the complete flow on a physical Watch and iPhone;
- test the stats sheet collapsed and expanded;
- update the iOS README with Apple Watch Health Devices setup;
- document Gate A or Gate B limitations; and
- keep issue #85 open for the direct ESP32 work.

## Automated tests

### Sensor registry

- empty/corrupt/default persistence;
- round-trip versioned persistence;
- enroll cadence, power, and combined profiles;
- rename preserves identity;
- disabling affects capability union;
- forgetting the last capable profile removes that capability;
- two enabled profiles with overlapping capabilities;
- no migration from historical workout metrics; and
- future registry versions fail safely.

### Detection coordinator

- cadence-only and power-only observations;
- proven combined identity;
- unproven simultaneous cadence and power remain separate;
- repeated snapshots do not create repeated candidates;
- an enabled matched profile suppresses the prompt;
- a disabled matched profile is offered without becoming enabled;
- **Not Now** suppresses only the current workout;
- a new workout can offer the candidate again;
- stale, future, terminal, and replayed snapshots are rejected; and
- candidate grace-period expiry.

### Workout contract, when Gate A applies

- 1.5 round trip with observations;
- 1.4 payload decodes with no observations;
- unknown minor fields remain compatible;
- malformed identity, invalid dates, duplicates, and oversize arrays fail
  validation;
- no sensitive metadata is encoded; and
- snapshot merge preserves validated observations.

### Tile policy

- no profiles hides both cadence and power;
- cadence only shows cadence;
- power only shows power;
- combined shows both;
- disabled profiles do not expose tiles;
- fresh but unenrolled metrics do not expose tiles;
- enrolled stale metrics expose `--`;
- active workout plus navigation uses the same gating; and
- navigation-only metrics are unchanged.

### Settings and routing

- **Connect a new Sensor** enters **Looking nearby…**;
- no-active-workout guidance is visible;
- candidate tap opens enrollment;
- enrollment adds the profile exactly once;
- row tap opens detail;
- rename, enable/disable, and forget update the list;
- notification tap lands on **My Bike Computer** with the **My Sensors**
  candidate visible;
- dismiss does not enroll; and
- offline-map chip returns after the sensor prompt resolves.

## Physical acceptance matrix

Validate on a supported iPhone, Apple Watch, and real sensors:

| Scenario | Expected result |
| --- | --- |
| No enrolled sensor, no workout data | Cadence and power tiles are absent. |
| Unenrolled cadence data arrives | Cadence tile remains absent; cadence prompt appears. |
| Enroll cadence candidate | Cadence tile appears; power remains absent. |
| Cadence sensor stops reporting | Cadence tile remains and shows `--` after freshness expiry. |
| Enroll power candidate | Power tile appears and shows watts while reporting. |
| Enroll verified/confirmed combined sensor | Both tiles appear. |
| Disable cadence-only profile | Cadence tile disappears unless another enabled profile supplies cadence. |
| Forget power profile | Power tile disappears unless another enabled profile supplies power. |
| Workout and navigation run together | Enrolled workout tiles follow the same rules in the expandable sheet. |
| Navigation runs without workout | Existing three navigation stats remain unchanged. |
| Watch disconnects from iPhone | Watch workout continues; tiles remain configured and values become unavailable as existing freshness rules require. |
| iPhone reconnects mid-workout | Current observations resume without duplicate profiles or prompts. |
| App relaunches | Enrolled names and enabled choices survive; prompt deduplication remains bounded. |
| No active workout while looking | UI explains how to pair/wake/start; it does not claim a Bluetooth scan is finding devices. |

## Acceptance criteria

This slice is complete when:

- the existing **My Bike Computer** page contains a **My Sensors** group;
- **Connect a new Sensor** shows a spinner and **Looking nearby…**;
- actual current workout cadence/power data creates an honest nearby candidate;
- an enrolled sensor appears under **My Sensors**;
- tapping it opens a detail screen with editable name, enable/disable, status,
  and confirmed forget;
- fresh unknown sensor data shows one deduplicated **Connect sensor?** bottom
  notification;
- tapping the notification opens **My Bike Computer** with the detected sensor
  ready to enroll;
- no cadence or power tile appears before explicit enrollment;
- enabled sensor capabilities, not sample freshness, decide tile visibility;
- enrolled-but-stale tiles remain visible with `--`;
- compact and expanded workout layouts remain correct;
- the flow works during a workout with and without navigation;
- the Watch-owned workout, HealthKit save, iPhone mirror, and ESP32 metric relay
  do not regress; and
- physical-device validation documents whether Gate A or Gate B shipped.

## Relationship to issue #85

This plan advances issue #85 by adding:

- user-visible cadence/power sensor enrollment;
- local sensor profiles and names;
- capability-aware training-screen visibility;
- live observation and reconnect-tolerant app behavior; and
- a path that can later represent direct sensors consistently.

The following issue #85 work remains separate:

- ESP32-owned BLE scanning and direct GATT connections;
- bonding, reconnect, and multi-peripheral scheduling on ESP32;
- Cycling Speed and Cadence Service and Cycling Power Service parsing in
  firmware;
- direct heart-rate, temperature, radar/light, or other accessory support;
- on-device sensor configuration screens;
- direct-sensor ride-file logging and post-ride analysis;
- direct sensor-to-ESP32 behavior without Apple Watch/iPhone;
- ANT+ support and its hardware limitations; and
- alerts, laps, targets, and broader configurable training screens.

Keep issue #85 open after this Apple Watch/HealthKit-assisted slice merges.
Future direct ESP32 work should reuse the capability vocabulary and user-facing
profile concepts, but it must keep transport-specific identities and connection
state separate.
