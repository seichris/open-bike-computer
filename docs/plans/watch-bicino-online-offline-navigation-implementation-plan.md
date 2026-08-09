# Watch + Bicino online and offline navigation implementation plan

Tracks [#106, iPhone-free rides with Watch-only navigation](https://github.com/seichris/open-bike-computer/issues/106).
Related but out of scope: [#97, GPS-equipped Bicino phone-free navigation](https://github.com/seichris/open-bike-computer/issues/97).

Prepared from `origin/main` at
`951a51089197c4ef58374c452d320c73fb3a7f03` with Xcode 26.6 and the
watchOS 26.5 SDK.

Implementation evidence and the still-open physical/provider gates are tracked
in [`../watch-bicino-navigation-validation.md`](../watch-bicino-navigation-validation.md).
Until MapKit durable export is explicitly approved, the implemented offline
source is user-imported GPX; MapKit routes remain active-session only.

This plan supersedes the route-source, capability-allocation, and automatic
transport-selection sections of draft PR #119. It preserves that draft's
security rule: a Watch must receive a scoped ride credential and a
device-issued exclusive control lease; the iPhone OwnerKey must never be copied
to the Watch.

## Outcome

Let an enrolled Apple Watch navigate and drive the Bicino display while the
iPhone is off or out of range. The rider chooses the routing policy explicitly
in the Watch app:

- **Use Watch cellular connection off**, the default: select a complete route
  that was planned and confirmed on iPhone, transferred to Watch, and marked
  ready before the ride. The Watch performs no online route request and does
  not reroute online.
- **Use Watch cellular connection on**: the Watch may request a cycling route
  and reroutes over its available internet connection. If connectivity fails
  after a route is loaded, the Watch keeps following that route rather than
  destroying it.

The user setting is the authority. The app never enables the online policy
because it believes the Watch supports cellular, never disables it because a
network path is unavailable, and never silently changes policies mid-ride.

Internally name the policies `offlineOnly` and `onlineAllowed`. The user-facing
label remains **Use Watch cellular connection**, with this footer:

> Allows online route calculation and rerouting from this Watch. watchOS may
> use cellular or Wi-Fi when available.

MapKit does not expose a supported way to force an `MKDirections` request onto
cellular rather than Wi-Fi. The switch therefore grants permission for Watch
online routing; it does not promise a particular network interface.

## End-to-end flows

### Offline Watch + Bicino

```text
iPhone approved export route or user-imported GPX
  -> exact complete route geometry
  -> rider selects/imports the intended route
  -> validated route archive
  -> WatchConnectivity file transfer
  -> Watch verifies and persists archive
  -> Watch acknowledges "Ready for offline ride"

Later, with iPhone and Watch internet unavailable:

Watch saved route + Watch GPS
  -> shared navigation runtime
  -> maneuver + route progress + off-route status
  -> authenticated Watch BLE
  -> Bicino route window + position + instruction + workout metrics
```

The complete archive lives on the Watch. Bicino remains a live display in this
mode; it does not need to persist the complete route or have its own GPS.

### Online Watch + Bicino

```text
Synced favorite + current Watch GPS
  -> Watch MKDirections cycling request
  -> active route cache
  -> shared navigation runtime
  -> authenticated Watch BLE
  -> Bicino live display

Sustained route deviation
  -> Watch MKDirections reroute request
  -> generation-checked route replacement
  -> full Bicino navigation resynchronization
```

Both modes use Watch Core Location as the live position source. Both keep the
HealthKit workout and navigation as separate lifecycles: route or Bicino
failure must not prevent a Watch workout from starting, continuing, or saving.

## Product decisions

### A route is a first-class object

A favorite does not identify a unique route. Keep these concepts separate:

| Object | Meaning | Usable offline |
| --- | --- | --- |
| `SavedDestination` | A coordinate-backed place used as an online routing target | No |
| `PlannedRouteSummaryV1` | Route-library metadata shown on iPhone and Watch | Only when its archive is installed |
| `NavigationRouteArchiveV1` | The selected route's complete geometry, steps, and integrity metadata | Yes |

Offline mode never tries to recreate a route from only a destination. Online
mode may calculate from current Watch GPS to a synced coordinate-backed
favorite. Query-only favorites remain iPhone-only until resolved to a stable
coordinate.

### Watch setting behavior

Store the switch in Watch-local preferences, defaulting to `false`. The iPhone
may display the reported value for diagnostics but must not write it. Do not
sync it from an iPhone setting, infer it from Watch model, inspect cellular
subscription state to choose it, or flip it after an error.

Changing the switch while navigation is active has deterministic behavior:

- on to off: cancel any pending directions request, keep the current loaded
  route, and disable later online reroutes;
- off to on: keep the current route and allow a later explicit recalculation or
  deviation-triggered reroute; do not replace the route immediately;
- either direction increments the routing-policy generation so a delayed
  response from the previous policy cannot be installed.

`NWPathMonitor` may drive `Online`, `No connection`, and retry status, but its
output is advisory. The result of the requested MapKit operation remains the
authoritative success or failure.

### Offline start and deviation behavior

The Watch offline picker lists only archives that are installed, validated,
not expired under their provider policy, and compatible with the current app
schema.

At start:

- within 250 metres of the planned start, initialize progress at the nearest
  unambiguous route segment;
- farther away, show the distance to the planned start and require **Start
  anyway** or a different route; there is no invented connector route;
- use the current 30-metre / three-eligible-sample deviation policy, adjusted
  by horizontal accuracy, for off-route detection;
- while off route, retain the selected route and Bicino overlay, show distance
  to the nearest route segment, and resume normal progress after rejoining;
- never call a route provider, geocoder, local search, or reroute service while
  the policy is `offlineOnly`.

Offline mode does not provide a new road-following route after deviation. It
provides the original route, current position, nearest-course distance, and a
clear `Rerouting unavailable offline` state.

### Online start and reroute behavior

Online mode accepts either a synced favorite or an installed route:

- favorite: calculate from current Watch GPS to the exact destination
  coordinate;
- installed route: start with the exact selected route; use online routing only
  if the rider asks to recalculate or deviation triggers a reroute;
- no usable network before an initial favorite route exists: report navigation
  unavailable while allowing a workout-only ride;
- network loss after route load: continue the active route and retain all
  geometry, steps, progress, and instructions;
- reroute failure: keep the old route, report the failure, and retry only after
  connectivity recovery plus the existing cooldown;
- stale reroute response: discard it when its navigation, policy, request, or
  location generation is no longer current.

Route replacement must reuse the existing non-destructive semantics of
`NavigationEngine.replaceRoute(with:currentLocation:)`: preserve workout state,
ride telemetry, and navigation lifetime while replacing only route progress.

## Current `main` baseline

The repository already has:

- a Watch app that runs independently of the companion app, owns the
  `HKWorkoutSession`, records the workout route, recovers sessions, and mirrors
  workout state to iPhone;
- iPhone route input with explicit source and destination selection;
- iPhone `MKDirections` cycling requests, route progress, maneuver mapping,
  deviation detection, 15-second reroute cooldown, and non-destructive route
  replacement;
- coordinate-aware `SavedDestination` favorites on iPhone;
- authenticated ownership-v2 BLE with AES-GCM-protected navigation, route,
  GPS, settings, and workout channels;
- Bicino live navigation characteristics: maneuver `2A6E`, sliding route
  geometry `2A6F`, GPS/ride state `2A72`, and Watch workout telemetry;
- `CAP2` schema 1 feature negotiation with bits `0...13` assigned;
- offline OpenStreetMap FMB map packs on Bicino.

The current implementation does not have:

- a Watch navigation settings policy, favorites or route library;
- a serializable route model independent of `MKRoute`;
- route preview/alternative selection and route-file transfer to Watch;
- a Watch MapKit route provider or navigation runtime;
- a Watch CoreBluetooth central, device credential, or direct packet writer;
- firmware-scoped Watch authentication or an exclusive writer lease;
- navigation recovery state on Watch;
- GPS-equipped Bicino-only navigation for #97.

`WatchRouteRecorder` currently owns its `CLLocationManager` and stops it with
workout route recording. That ownership must be separated so workout recording
and navigation can start and stop independently.

Offline map packs and offline routes are separate artifacts. FMB blocks give
Bicino a basemap; they do not calculate a route or supply maneuvers.

## Phase 0 legal and platform gates

### Apple Maps data-use gate

`MKDirections` asks Apple servers for routes, and an `MKDirections.Response`
can contain multiple route alternatives. See Apple's
[MKDirections](https://developer.apple.com/documentation/mapkit/mkdirections)
and [response routes](https://developer.apple.com/documentation/mapkit/mkdirections/response/routes)
documentation.

Before shipping a MapKit-derived offline archive, review the currently accepted
Apple Developer Program License Agreement, especially Attachment 6. The current
published agreement restricts caching, storing, deriving a secondary database
from, and displaying Apple Map Data outside the permitted Apple Maps context.
See the
[Apple Developer Program License Agreement](https://developer.apple.com/la/support/terms/apple-developer-program-license-agreement/).

Obtain an explicit product/legal determination for both:

1. temporarily serializing and transferring a selected `MKRoute` to the paired
   Watch for an upcoming offline ride; and
2. sending MapKit-derived route geometry and instructions to a non-Apple Bicino
   display over an OSM basemap, including the existing online iPhone flow.

Do not make App Store submission contingent on an optimistic interpretation.
Build the route model behind a provider boundary:

```text
NavigationRouteProvider
  +-- MapKitRouteProvider
  +-- ExportLicensedRouteProvider
  +-- ImportedGPXRouteProvider
```

If MapKit export is not approved, use a provider whose terms expressly allow
route persistence and accessory display, or user-imported GPX, for durable
offline archives. The Watch runtime, sync, BLE, and UI architecture stays the
same. A MapKit route may still be held as a short-lived active-route cache only
to the extent the accepted terms and legal review permit.

Every archive records `providerID`, attribution metadata, retention policy, and
an optional `deleteAfter`. Stores enforce deletion and refuse an expired route.

### Physical Watch execution gate

The SDK exposes cycling `MKDirections`, `CBCentralManager`, and
`CLBackgroundActivitySession`, but API availability does not prove acceptable
wrist-down throughput or battery life. Apple's watchOS documentation describes
Core Bluetooth background communication and its background-scan budget in
[Using background tasks](https://developer.apple.com/documentation/watchkit/using-background-tasks).
Core Location documents background location sessions in
[CLBackgroundActivitySession](https://developer.apple.com/documentation/corelocation/clbackgroundactivitysession-3mzv3).

Before building the full UI, prove on the minimum supported physical Watch:

- route calculation while foregrounded and during an active workout;
- continuous Watch GPS while wrist-down;
- an established Bicino BLE connection, writes, notifications, reconnect, and
  full-state resync during an active workout;
- behavior after app suspension and relaunch;
- battery and thermal impact over a representative two-hour ride;
- background scan limits, avoiding repeated scans by retaining or retrieving a
  known connection whenever possible.

If navigation without an active workout cannot run reliably, preserve separate
state machines but require an active BikeComputer workout for background
Watch+Bicino navigation in the first release.

## Shared route architecture

### New shared source group

Add a platform-neutral `RideShared` group with iOS, watchOS, and host-test
membership:

```text
ios-app/BikeComputer/RideShared/
  SavedDestinationContract.swift
  NavigationRouteContract.swift
  NavigationRouteArchive.swift
  NavigationRuntime.swift
  NavigationGeometry.swift
  RouteProviderContract.swift
  WatchSyncContract.swift
  DeviceRideProtocol.swift
  DeviceTelemetryContract.swift
```

Keep MapKit request construction, Core Location delegates, CoreBluetooth
delegates, WatchConnectivity delegates, HealthKit, and Keychain access in their
platform targets.

Refactor the current `RouteProgress`, `RouteDeviation`, `RouteStepSelection`,
instruction mapping, geometry-window encoding, and send-tracking logic to use
the shared route model instead of `MKRoute`. First adapt the iPhone runtime and
require parity tests before using the same runtime on Watch.

### `NavigationRouteArchiveV1`

Do not attempt to encode `MKRoute`. Convert a selected provider route into a
bounded Foundation model:

```text
NavigationRouteArchiveV1
  schemaVersion
  routeID: UUID
  revision: UInt32
  contentHash: SHA-256
  providerID
  providerAttribution
  retentionPolicy
  createdAt
  deleteAfter?
  localeIdentifier
  transportType: cycling
  source: coordinate + label
  destination: coordinate + label
  bounds
  distanceMeters
  expectedTravelTimeSeconds?
  routeName?
  points: normalized WGS-84 coordinates
  steps: geometry range + instruction + maneuver + distance
  normalizationVersion
```

Rules:

- normalize coordinates to WGS-84 once, preserving the existing China
  MapKit/GCJ-02 conversion behavior and recording its version;
- store the exact alternative selected by the rider, not only endpoints;
- retain provider instruction text for the planned locale and a normalized
  `ManeuverV1` for Bicino icon mapping;
- index step geometry into the route point array and validate every range;
- reject invalid coordinates, non-finite numbers, duplicate IDs, backward or
  overlapping invalid step ranges, empty geometry, and hash mismatches;
- set initial safety limits of 50,000 points, 2,000 steps, and 4 MiB encoded;
  finalize lower product limits from measured long cycling routes;
- contain no HealthKit samples, workout metrics, map tiles, OwnerKey, or Watch
  controller credential;
- encode deterministically so the same content produces the same hash;
- write to a temporary file, fsync, verify by decoding, then atomically rename.

Use a route summary catalog separately from archive files so lists do not load
full geometry.

### Shared navigation runtime

`NavigationRuntime` accepts a validated route and filtered location samples and
publishes one coherent snapshot:

```text
NavigationSnapshotV1
  navigationGeneration
  routeID + revision + contentHash
  currentStepIndex
  maneuver
  instruction
  distanceToManeuver
  routeRemainingDistance
  expectedArrival?
  offRouteDistance?
  mode: offline | online | onlineUsingCachedRoute
```

The runtime owns:

- start-point and nearest-step selection;
- monotonic progress with protection for loops and out-and-back geometry;
- route remaining distance and ETA projection;
- maneuver transitions and icon mapping;
- deviation filtering and rejoin detection;
- the same 30-point Bicino route window used by the current iPhone engine;
- current-position and route-coordinate normalization;
- full snapshot generation after device reconnect;
- route replacement without resetting ride telemetry.

Platform managers own route-provider requests, timers, storage, UI, and BLE.

## iPhone implementation

### Route planning and confirmation

Extend the existing `RouteInputView` and `BikeComputerCoordinator` instead of
building a second address-search flow:

1. Require exact start and destination map items or coordinates.
2. Set `requestsAlternateRoutes = true` for route planning.
3. Present returned alternatives on the Apple map with route name, distance,
   expected time, and advisory notices.
4. Require the rider to select one alternative explicitly.
5. Offer **Start on iPhone** and **Save for Apple Watch** as distinct actions.
6. Convert the selected route through the chosen provider adapter and validate
   the archive before adding it to the library.
7. Keep `SavedDestination` favorites unchanged; saving a route does not turn
   its endpoints into favorites implicitly.

Add:

```text
RoutePlanningCoordinator
PlannedRouteStore
PlannedRoutesView
RouteAlternativePreview
RouteArchiveEncoder
RouteArchiveRetentionPolicy
```

The iPhone is authoritative for the planned-route library. Use route IDs and
monotonic revisions. A content update creates a new revision; it never mutates
an archive already active on Watch.

### WatchConnectivity ownership and route transfer

`WCSession.default.delegate` is a singleton. Current main assigns it to
`WorkoutWatchAvailabilityMonitor` on iPhone and
`WatchHeartRateZoneSettingsReceiver` on Watch. Replace those direct delegates
with one coordinator per process:

- `PhoneWatchSyncCoordinator`;
- `WatchSyncCoordinator`.

Each coordinator routes typed events for workout availability, maximum heart
rate, favorites, planned-route summaries, route files, controller enrollment,
deletion tombstones, and acknowledgements.

Use the channels deliberately:

| WatchConnectivity channel | Content |
| --- | --- |
| `applicationContext` | One merged, versioned latest-state envelope: max HR, coordinate favorites, selected Bicino metadata, route summaries, and revisions |
| `transferFile` | Complete route archive files |
| `transferUserInfo` | Durable route-installed acknowledgements, route deletion tombstones, revocation receipts, and completed-ride summaries |
| `sendMessageData` | Interactive controller enrollment proof and optional foreground status refresh |
| HealthKit workout mirroring | Existing workout snapshots and controls only |

Apple documents that application context overwrites prior context, while file
and user-info transfers can continue opportunistically in the background. See
[WCSession](https://developer.apple.com/documentation/watchconnectivity/wcsession).
Always merge the complete latest-state envelope so a route update cannot erase
maximum-HR state.

Route transfer sequence:

1. iPhone writes and verifies `route-<UUID>-r<revision>.bcr`.
2. It queues `transferFile` with route ID, revision, hash, byte count, and
   retention metadata.
3. iPhone shows `Queued`, not `Ready`.
4. Watch receives the temporary file, moves it before the delegate returns,
   validates it, and atomically installs it.
5. Watch sends a durable acknowledgement containing route ID, revision, hash,
   and installed result.
6. Only the matching acknowledgement changes iPhone and Watch UI to **Ready for
   offline ride**.
7. A newer revision supersedes an older inactive file only after successful
   install; an active route remains pinned until navigation ends.
8. Deletion is a revisioned tombstone. Watch removes inactive files immediately
   and defers removal of an active file until navigation ends.

Bound the first release to 10 installed routes and 50 MiB total Watch storage,
with deterministic oldest-unused eviction only after the iPhone and Watch
catalogs agree. Never evict an active route or the only file for a pending
offline ride.

## Watch implementation

### `WatchNavigationSettingsStore`

Add the requested toggle to `WatchSettingsView`:

```text
Navigation
  [ ] Use Watch cellular connection
      Allows online route calculation and rerouting from this Watch.
      watchOS may use cellular or Wi-Fi when available.
```

The store publishes `RouteNetworkPolicy` and a monotonic policy generation.
Default migration is always off, including upgrades from builds that predate
the key. Unit tests must prove no network, Watch model, pairing, or reachability
callback mutates it.

### `WatchRouteStore`

Persist route summaries and files with complete file protection appropriate for
use after device unlock. On launch and after every transfer:

- validate schema, bounds, byte limits, coordinates, ranges, retention, and
  hash;
- quarantine corrupt files for bounded diagnostics without making them
  selectable;
- reconcile files against the latest summary revision and tombstones;
- pin the active route against replacement and eviction;
- expose explicit `queued`, `validating`, `ready`, `expired`, `incompatible`,
  `corrupt`, and `deleting` states.

### `WatchLocationService`

Make one service own `CLLocationManager`. Workout route recording and
navigation register independent consumers. Location updates run while either
consumer needs them, and stopping one consumer never stops the other.

`WatchRouteRecorder` keeps only HealthKit filtering, batching, and
`HKWorkoutRouteBuilder` responsibilities. Navigation obtains the same accepted
locations without reading HealthKit back.

During active navigation, use `CLBackgroundActivitySession` where supported and
retain `workout-processing`. Add the Watch Bluetooth usage description and the
supported Core Bluetooth background mode documented for watchOS. Verify the
built Watch plist rather than assuming an Xcode capability changed the right
target.

### `WatchNavigationManager`

Own these explicit states:

```text
idle
preparingOffline(routeID, generation)
requestingOnline(destinationID, requestGeneration)
navigating(routeID, navigationGeneration, mode)
offRoute(routeID, distance, mode)
rerouting(routeID, requestGeneration)
navigationUnavailable(reason)
stopping(generation)
```

Offline start loads only `WatchRouteStore`. Online start uses
`MapKitRouteProvider` or the approved online provider with `.cycling`, exact
Watch GPS, and the selected coordinate destination. Convert the provider result
immediately to the shared model; platform code must not retain `MKRoute` as the
navigation engine's state.

Persist one bounded active-navigation journal containing route identity and
hash, policy, navigation generation, current step/progress checkpoint, and
timestamps. The journal contains no health metrics or keys. Recovery validates
the route again, restores location demand, and creates a new BLE transport
generation before sending anything.

### Watch start and live UI

Extend `WorkoutStartView` without making navigation a prerequisite for the
workout:

- **Navigation** row: `None`, installed route, or favorite allowed by policy;
- **Route mode** badge: `Offline` or `Online` derived from the user setting;
- **Bicino** row: automatic setup, connection, authentication, and lease status;
- existing **Start Ride** action.

When the policy is offline, show installed routes only. When online, show
coordinate favorites and installed routes. Starting with `None` records a
workout and may still stream workout metrics directly to Bicino.

The live view adds current maneuver, maneuver distance, route remaining,
offline/online state, off-route or reroute status, and Bicino connection state.
Workout pause/resume/end and navigation stop/change remain separately labelled.

Failure copy must distinguish:

- `Workout could not start`;
- `Navigation unavailable`;
- `Route not installed on this Watch`;
- `No Watch internet connection`;
- `Bicino not connected`;
- `Bicino is controlled by iPhone`;
- `Rerouting unavailable offline`.

## Direct Watch-to-Bicino BLE

### Security model

Keep the iPhone OwnerID/OwnerKey as the administrative root. Add one scoped
controller per owned Bicino:

```text
WatchControllerCredentialV1
  deviceID: 16 bytes
  controllerID: 16 random bytes
  controllerKey: 32 random bytes
  role: watchRide
  schemaVersion
  createdAt
```

Store the Watch key in a non-synchronizing, this-device-only Keychain item. Its
role may authenticate, claim/renew/release a ride lease, and write navigation,
route, GPS, and workout channels. It may not rename, deregister, update
firmware, transfer maps, alter device settings, add controllers, or recover
ownership.

Enrollment remains a staged three-party transaction:

1. Authenticated owner iPhone stages a provisional Watch controller on Bicino.
2. iPhone sends the credential interactively to the reachable Watch.
3. Watch saves it and returns a challenge proof.
4. iPhone forwards the proof to Bicino.
5. Firmware atomically commits the replacement controller.
6. iPhone and Watch mark enrollment complete only after firmware confirmation.

Interrupted setup remains pending and retryable. Watch replacement,
reinstallation, device deregistration, or physical ownership reset revokes or
removes the scoped credential.

### Capability allocation and lease

Current `main` uses `CAP2` schema 1 feature bits through bit 13. Reserve bit 14
and client version 12 for the complete `watchDirectControllerV1` contract. Do
not reuse the older draft's bit 8 allocation; bit 8 now belongs to street-label
profiles.

Firmware sets bit 14 only when all of these are active:

- atomic scoped-controller persistence;
- scoped challenge/response authentication and protected session keys;
- command authorization by role;
- exclusive lease claim, renewal, expiry, release, and busy responses;
- rejection of ride-channel writes from non-holders;
- protected acknowledgements and full resynchronization support.

Authentication proves identity; a protected device-issued lease grants write
authority. Only one controller may hold it. Every accepted ride frame refreshes
the lease; an idle holder sends a bounded heartbeat. Disconnect releases it
when possible, otherwise it expires after the documented deadline. Reconnect
creates a new authenticated session and lease generation.

An iPhone-started ride retains the existing iPhone BLE writer. A Watch-started
Watch+Bicino ride requests the direct lease. If a reachable, idle iPhone owns
the link, it may release it after an explicit Watch-direct preparation message.
It must not release an active iPhone navigation session. The firmware lease is
the final authority; WatchConnectivity reachability alone never grants control.

### `WatchDeviceLink`

Implement a focused Watch CoreBluetooth central rather than compiling the
large iPhone `BLEManager.swift` into the Watch target. It must:

- retrieve or scan by service UUID and advertised DeviceID suffix, then verify
  full DeviceID during authentication;
- connect, discover required characteristics, negotiate limits, authenticate
  the scoped credential, request `CAP2`, and claim the lease;
- require feature bit 14 and workout bit 7 for the corresponding features;
- use one bounded priority queue with coalescing for replaceable GPS and route
  windows and ordered delivery for maneuver/workout pairs;
- share packet encoders and golden vectors with iPhone;
- reject stale callbacks using connection and lease generations;
- keep or retrieve an established connection rather than spending background
  scan budget repeatedly;
- reconnect with bounded exponential backoff while workout or navigation still
  needs Bicino;
- release the lease and stop BLE work when neither lifecycle needs it.

After readiness or Bicino reboot, send a complete state in this order:

1. current or clear workout pair;
2. latest valid GPS position;
3. current route window or clear route;
4. current maneuver snapshot or idle navigation state.

The Watch uses the existing live characteristics and protected fallback
frames. No full route-file transfer to Bicino is part of Watch+Bicino mode.
Persistent device routes and onboard GPS remain #97.

## Firmware work

Update together:

- `docs/ble-protocol.md`;
- `esp32/lib/ble_navigation/ble_navigation.hpp`;
- `esp32/lib/ble_navigation/ble_navigation.cpp`;
- ownership persistence and crypto helpers;
- iPhone and Watch protocol constants;
- shared Swift/C++ golden vectors.

Firmware changes are limited to direct-controller security, lease enforcement,
capability reporting, and coherent live-state resync. The route renderer keeps
the current full-screen LVGL strategy and consumes the same RAM route window,
GPS marker, instruction, and workout state it uses today.

The current non-GPS Waveshare models remain valid Watch+Bicino targets because
Watch supplies GPS. Do not add UART GPS code to them. The GPS-equipped
standalone product has a different data owner and acceptance matrix under #97.

## Failure and recovery behavior

| Event | Required behavior |
| --- | --- |
| Offline policy, no installed route | Do not issue network requests. Allow workout-only start and explain how to transfer a route. |
| Offline route transfer queued but unacknowledged | Show `Queued`, not `Ready`; do not offer it as guaranteed offline. |
| Route file corrupt or wrong hash | Keep prior valid revision, quarantine the file, and return a failed acknowledgement. |
| Rider starts far from offline route | Show distance to route start; require Start anyway or another route. |
| Rider leaves offline route | Keep route and overlay, show nearest-course distance, never reroute online, resume after rejoin. |
| Online policy, no initial route and no network | Workout may start; navigation reports unavailable and offers retry. |
| Network drops after route load | Continue current route and show `Offline - continuing route`. |
| Network drops during reroute | Retain old route; discard failed/partial replacement; retry only after recovery and cooldown. |
| Setting turns off during request | Cancel request, increment policy generation, continue existing route, reject late result. |
| Setting turns on mid-route | Keep route; permit later explicit or deviation-triggered reroute. |
| Bicino is off | Workout and navigation continue on Watch; reconnect with backoff. |
| Bicino reboots | Reauthenticate, reclaim lease, and send ordered full state. |
| iPhone returns during direct ride | Observe and sync metadata; do not steal a healthy Watch lease. |
| iPhone already has active navigation | Watch records workout and reports Bicino busy; it does not create a second writer. |
| Watch app relaunches | Recover workout and navigation independently, validate route, resume location, then create new BLE generation. |
| Workout pauses | Navigation and Bicino lease remain active; send paused workout state. |
| Workout ends while navigation continues | Save exactly one workout, clear workout telemetry, keep navigation/location/BLE active. |
| Navigation stops while workout continues | Clear route and maneuver, keep direct workout telemetry active. |
| Route deleted while active | Mark pending deletion and remove only after navigation stops. |
| Provider retention expires | Refuse a new start, delete per policy, never silently recalculate while offline. |

## Concrete file plan

### iPhone and shared code

- add the `RideShared` files listed above;
- refactor `Models/AppModels.swift` only enough to bridge
  `SavedDestinationV1` without changing existing stored favorites;
- extend `Views/RouteInputView.swift` with alternate-route preview and save;
- add `Views/PlannedRoutesView.swift`;
- refactor `Managers/BikeComputerCoordinator.swift` to use a provider adapter
  and shared runtime while preserving `replaceRoute` behavior;
- refactor `Managers/NavigationEngine.swift` behind the shared runtime;
- replace direct WatchConnectivity ownership in
  `WorkoutWatchAvailabilityMonitor.swift` with `PhoneWatchSyncCoordinator`;
- extend `BikeComputersSettingsView.swift` with the Watch-provided display name
  and read-only automatic direct-ride setup status;
- extend `BLEManager.swift` for controller administration, `CAP2` bit 14, and
  lease-aware iPhone writes.

### Watch code

- add `Managers/WatchNavigationSettingsStore.swift`;
- add `Managers/WatchRouteStore.swift`;
- add `Managers/WatchLocationService.swift`;
- add `Managers/WatchNavigationManager.swift`;
- add `Managers/WatchOnlineRouteProvider.swift`;
- add `Managers/WatchDeviceLink.swift`;
- add `Managers/WatchRideSessionCoordinator.swift`;
- add `Managers/WatchCredentialStore.swift`;
- add `Managers/WatchSyncCoordinator.swift`;
- refactor `WatchRouteRecorder.swift` to consume `WatchLocationService`;
- extend `WatchSettingsView.swift`, `WorkoutStartView.swift`,
  `WatchWorkoutRootView.swift`, and `LiveWorkoutView.swift`;
- add Bluetooth usage text and verified watchOS background declarations.

### Tests and documentation

- extend `ios-app/scripts/run-navigation-tests.sh`;
- extend workout contract/platform tests for independent lifecycles;
- add Watch target tests for settings, route storage, navigation, sync, and BLE
  state machines;
- extend `esp32/tools/tests/test_device_capabilities_protocol.cpp`;
- extend ownership crypto/persistence tests and add lease tests;
- update `docs/device-ownership-test-vectors.json`;
- update `docs/ble-protocol.md`, privacy disclosures if required, release notes,
  and iOS/Watch setup documentation.

## Delivery phases

### Phase 0: compliance and physical proof

1. Resolve the Apple Maps storage/accessory-display gate or select an
   export-licensed provider.
2. Spike Watch cycling directions, GPS, and direct Bicino BLE during an active
   workout.
3. Measure wrist-down behavior, reconnects, battery, and background limits.
4. Prototype `CAP2` bit 14 plus controller/lease host tests.

Gate: approved route-source policy and sustained physical Watch GPS/BLE proof.

### Phase 1: shared route contract and iPhone parity

1. Add provider-neutral route/archive models and strict validation.
2. Extract the navigation runtime from `MKRoute`-specific code.
3. Adapt current iPhone navigation to the shared runtime.
4. Prove geometry, maneuvers, rerouting, telemetry, and simulation parity.

Gate: existing iPhone navigation behavior and tests remain green; route
replacement does not reset ride telemetry.

### Phase 2: iPhone planning and route delivery

1. Add alternate route preview and explicit selection.
2. Add route library, retention enforcement, and archive encoder.
3. Centralize WatchConnectivity delegates.
4. Add file transfer, validation acknowledgement, revisions, and deletion.
5. Add Watch route store and offline-ready UI without navigation execution.

Gate: a physical paired Watch receives a route opportunistically, survives
iPhone/Watch app relaunch, and reports Ready only after hash-verified install.

### Phase 3: scoped Watch controller and exclusive lease

1. Add firmware controller persistence, auth, role checks, and lease.
2. Allocate and document `CAP2` feature bit 14 and client version 12.
3. Add automatic iPhone enrollment, read-only Watch status, revocation
   internals, and Watch Keychain storage.
4. Add adversarial dual-controller, reset, and power-loss tests.

Gate: no test can make iPhone and Watch writes both succeed; older firmware and
older iPhone clients retain their documented fallback behavior.

### Phase 4: offline Watch + Bicino navigation

1. Refactor Watch location ownership.
2. Add shared runtime and active-navigation recovery on Watch.
3. Add Watch direct BLE writer and full-state resync.
4. Add offline route picker, start-distance warning, progress, maneuvers,
   off-route/rejoin behavior, and live UI.
5. Verify zero route-provider calls under `offlineOnly`.

Gate: with iPhone off and Watch internet unavailable, an acknowledged route
drives accurate Watch and Bicino navigation for a complete physical ride.

### Phase 5: online Watch + Bicino routing

1. Add the default-off Watch setting and immutable user-policy semantics.
2. Sync coordinate favorites.
3. Add Watch cycling route requests and active-route cache.
4. Add generation-safe rerouting and connectivity recovery.
5. Add online/offline-continuation status and policy-change behavior.

Gate: with iPhone off, the rider explicitly enables the switch, calculates and
follows a route from Watch GPS, reroutes after deviation, and continues the old
route when network fails.

### Phase 6: recovery and release hardening

1. Complete independent workout/navigation/route/transport recovery.
2. Complete Watch replacement, route expiry, app downgrade, device reset, and
   controller revocation behavior.
3. Run automated, physical, battery, privacy, and App Store compliance gates.
4. Update #106 with evidence; keep GPS-equipped Bicino-only work under #97.

Gate: all acceptance criteria and the physical matrix below pass with recorded
device, OS, firmware, commit, battery, and route-provider evidence.

## Automated verification

### Shared and iPhone tests

- deterministic archive encoding/hash and corruption rejection;
- schema, point/step/size, coordinate, geometry-range, retention, and locale
  validation;
- provider adapter parity and alternate-route selection;
- WGS-84/China normalization parity with current device geometry;
- progress on loops, out-and-back routes, skipped points, starts near a later
  segment, route replacement, and rejoin;
- maneuver transitions, remaining distance/ETA, 30-point geometry windows, and
  Bicino packet parity;
- existing iPhone start, simulation, deviation, reroute, and telemetry tests.

### Watch tests

- default setting is off and no environment callback changes it;
- offline policy makes zero provider calls, including deviation and recovery;
- on/off policy changes cancel and generation-reject pending results;
- route catalog/file transfer ordering, duplicate delivery, newer revision,
  failed acknowledgement, tombstone, active pin, eviction, and expiry;
- no-network initial online route, network loss after load, failed reroute,
  stale reroute, cooldown, and connectivity recovery;
- start-distance warning, Start anyway, off-route distance, and rejoin;
- independent workout/navigation lifecycle and recovery journals;
- Watch BLE connection, callback generation, queue priority/coalescing,
  reconnect, resync, lease busy, and revocation;
- WCSession merged-context behavior so route sync cannot erase max HR.

### Firmware tests

- every existing `CAPS` and `CAP2` golden vector remains byte-identical;
- `CAP2` bit 14 appears only with the complete direct-controller contract;
- scoped auth success plus malformed, wrong-device, HMAC, nonce, replay,
  sequence, revoked, and wrong-role failures;
- atomic controller stage/commit/revoke across NVS failures and reboot;
- lease grant, busy, renew, activity refresh, release, disconnect, timeout,
  generation wrap, and simultaneous claims;
- non-holder navigation, route, GPS, workout, settings, and transfer attempts;
- ordered full resync after reconnect and Bicino reboot;
- legacy owner-session and older-firmware compatibility.

## Physical validation matrix

Use a real paired iPhone, cellular-capable Apple Watch where required, and each
supported Bicino/Waveshare firmware target. Simulator-only evidence is not
sufficient.

1. Plan two alternatives on iPhone, select the non-default alternative, send it
   to Watch, and verify the exact selected geometry arrives.
2. Confirm iPhone shows Queued until Watch verifies and acknowledges the file.
3. Power iPhone off, disable Watch Wi-Fi/cellular, leave the setting off, and
   complete the saved route with Bicino guidance.
4. Start 250 metres inside and well outside the planned-start threshold; verify
   nearest-segment behavior and the Start anyway warning.
5. Deviate while offline, verify no network request, preserve the route, and
   rejoin it.
6. Relaunch Watch during offline navigation and verify route/progress/Bicino
   recovery without iPhone.
7. Enable the setting explicitly, power iPhone off, disable Watch Wi-Fi, and
   calculate a route using an active Watch cellular connection.
8. Repeat online mode on a non-cellular or unsubscribed Watch and verify a
   truthful failure without changing the setting.
9. Lose network after route load, then during reroute; verify the current route
   is never cleared.
10. Toggle off during an in-flight request and verify its late result is
    rejected; toggle on later and verify the current route remains unchanged.
11. Power-cycle Bicino and verify authenticated reconnect, new lease, and
    ordered full resync.
12. Bring iPhone back during direct mode and verify one accepted writer.
13. Start active navigation from iPhone, then try Watch direct mode and verify
    Watch reports busy without stealing the route.
14. Pause/end workout while navigation continues, then stop navigation while a
    workout continues; verify exactly one saved HealthKit workout.
15. Revoke the Watch, replace/reinstall it, downgrade apps/firmware, and perform
    a physical ownership reset.
16. Ride wrist-down for two hours and record GPS cadence, maneuver latency, BLE
    reconnects, Watch battery/thermal delta, and Bicino power impact.
17. Validate the approved route-provider retention, attribution, deletion, and
    accessory-display requirements in the release build.

## Acceptance criteria

### Offline mode

- **Use Watch cellular connection** is off by default and remains user-owned.
- iPhone can plan with explicit start and destination, show alternatives, save
  the selected route, transfer it, and prove Watch installation by matching
  acknowledgement.
- With iPhone off and Watch internet unavailable, Watch GPS drives route
  progress, maneuvers, remaining distance, current position, and Bicino route
  geometry for the selected archive.
- Starting away from the route is explicit; the app does not invent a connector
  route.
- Deviation produces an offline warning and rejoin guidance without making any
  online route request or destroying the route.
- Route and navigation recover after Watch app relaunch and Bicino reboot.

### Online mode

- Only the rider enables online Watch routing; hardware detection and network
  reachability never choose the policy.
- With iPhone off and a usable Watch network path, a coordinate favorite can be
  routed from current Watch GPS and displayed on Bicino.
- Sustained deviation requests one generation-safe reroute after the cooldown.
- Initial failure is honest; post-load network or reroute failure preserves the
  current route.
- watchOS may choose cellular or Wi-Fi; the app does not claim it forced a
  specific interface.

### Shared safety and compatibility

- Watch uses a scoped ride credential, never the iPhone OwnerKey.
- Firmware accepts ride writes only from the authenticated exclusive lease
  holder.
- iPhone-started navigation, current Bicino rendering, older-firmware fallback,
  ownership reset, and Watch workout behavior remain functional.
- Workout and navigation start, pause, stop, recover, and finish independently;
  route or Bicino failure never loses the Watch workout.
- The route source and retention behavior have an explicit production approval
  compatible with route persistence and Bicino display.

## Explicit non-goals for this plan

- GPS-equipped Bicino-only navigation, onboard route progress, and onboard ride
  history tracked by #97;
- persisting the complete route archive on current non-GPS Bicino hardware;
- calculating a new route offline on Watch;
- downloadable offline routing graphs or regional routing packs;
- forcing MapKit traffic onto cellular instead of Wi-Fi;
- automatically changing the Watch routing setting;
- Watch free-text address search or authoritative favorite editing;
- automatic mid-ride handoff between iPhone and Watch writers;
- map-pack transfer, firmware update, rename, deregistration, or ownership
  administration from the scoped Watch controller;
- cloud upload of route geometry, GPS history, or HealthKit samples.
