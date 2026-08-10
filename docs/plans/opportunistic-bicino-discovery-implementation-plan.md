# Opportunistic Bicino Discovery and Single-Session BLE Scanning Plan

## Outcome

Make device setup feel automatic without running an indefinite background
search or weakening Bicino's explicit ownership flow.

When the iPhone app is active, Bluetooth is available, the local Bike Computer
registry is empty, and no BLE connection is active, Bicino will listen for the
existing Bike Computer service advertisement. A fresh, unclaimed device can
trigger an AirPods-inspired **Bicino nearby** sheet. Selecting **Connect**
advances into the existing secure naming and code-comparison flow; discovery
alone never connects, registers, or authenticates a device.

After one Bicino has been registered, automatic discovery of other devices is
disabled. The app may still scan specifically to reconnect its saved active
device, but it ignores other advertisements and presents no new-device UI.
People who intentionally own multiple devices can use **Connect a new Bike
Computer** in Settings.

The transport invariant is stricter than the current implementation:

> One `CBCentralManager`, at most one scan purpose, and no scan while a Bike
> Computer is connecting or connected.

Scanning stops before a connection attempt begins. It remains stopped through
service discovery, authentication, navigation, map transfer, workouts, and
disconnect teardown. Once disconnected, the manager may resume the one eligible
purpose: trusted-device reconnect, a still-owned explicit setup flow, or
foreground opportunistic discovery.

This is not always-on background discovery. Background support remains enabled
for an existing trusted connection and trusted-device reconnect, but unknown
devices are discovered only while the app is active.

## Baseline

This plan was prepared on branch `plan/opportunistic-device-discovery` from the
freshly fetched GitHub `origin/main` commit
`227d4223eb9eaae47d84d23b45848bf2cb7be61a`.

### Already implemented

The current repository already contains most of the lower-level machinery:

1. Firmware advertises the Bike Computer service UUID, its effective name, and
   ownership manufacturer data.
2. Ownership advertisement v2 includes a stable identity suffix and claimed
   flag. The iOS app parses both into `DiscoveredBikeComputerDevice`.
3. `BLEManager` uses one service-filtered `CBCentralManager`, retains fresh
   candidates, and exposes an explicit Nearby scan.
4. `BikeComputersSettingsView` already lists Nearby devices and routes a chosen
   candidate through naming, physical confirmation, code comparison, and
   authenticated registration.
5. The local device registry supports an active device and multiple saved Bike
   Computers, while the runtime owns only one `connectedPeripheral`.
6. `connectToPeripheral(_:)` stops scanning before calling
   `centralManager.connect`.
7. The app declares `bluetooth-central`, supplies a Core Bluetooth restoration
   identifier, and restores only the currently trusted peripheral.
8. Trusted reconnection is intentionally durable in the background and remains
   a different use case from discovering unknown devices.

### Missing or conflicting behavior

1. No app-wide foreground discovery starts when an unregistered person opens
   Bicino; discovery starts only in the explicit Bike Computers screen.
2. `BLEManager` does not receive a durable app-active/app-background signal for
   discovery policy.
3. Scan intent is distributed across `isDiscoveringDevices`, `isPairingMode`,
   pending identifiers, and direct `startScanning()` calls.
4. `startScanning()` currently permits explicit discovery while another Bike
   Computer connection is active. That violates the requested no-scan-while-
   connected rule.
5. A successful restored or ordinary connection does not defensively reconcile
   every discovery owner before proceeding.
6. The main map UI has no automatic, AirPods-inspired sheet that advances a
   fresh Nearby observation into the existing setup flow.
7. Adding another registered device currently assumes discovery can overlap the
   existing connection. The new invariant requires an explicit disconnect
   handoff first.

## Apple platform contract

Core Bluetooth scanning is registration-based rather than an application poll
loop: the app starts a service-filtered scan once, and the central manager calls
its delegate when a matching advertisement is observed.

- [Scanning for peripherals](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/scanforperipherals%28withservices%3Aoptions%3A%29)
- [Core Bluetooth background processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)

Apple allows service-filtered scans in the background for apps declaring
`bluetooth-central`, but it coalesces duplicate discoveries, increases scan
intervals when all scanners are backgrounded, and recommends session-based
background work. Bicino does not need that behavior for unknown-device setup.

Keep `bluetooth-central` and the existing restoration identifier. They serve
active navigation, subscribed characteristics, restored connections, and
trusted-device reconnect. The implementation must stop only the opportunistic
or explicit unknown-device scan when the app backgrounds; it must not regress
the established trusted-connection lifecycle.

### AirPods UI and AccessorySetupKit

The exact AirPods proximity card shown by iOS is system-owned pairing UI. Apple
does not document a public API that lets an ordinary app trigger that exact
card over the Home Screen or substitute its own product into it.

The closest public API is
[AccessorySetupKit](https://developer.apple.com/documentation/accessorysetupkit),
introduced in iOS 18 and iPadOS 18. Its operating-system-hosted accessory
picker can display an app-supplied product name and artwork, discover matching
Bluetooth/Wi-Fi accessories, and authorize the selected accessory:

- [Discovering and configuring accessories](https://developer.apple.com/documentation/accessorysetupkit/discovering-and-configuring-accessories)
- [Meet AccessorySetupKit](https://developer.apple.com/videos/play/wwdc2024/10203/)

AccessorySetupKit is not a drop-in visual component. The app must declare its
accessory identifiers in `Info.plist`, activate an `ASAccessorySession`, and
adopt the framework's system authorization and migration model. Apple also
recommends giving people context and, where possible, invoking its picker from
a user action rather than presenting it unexpectedly. Its picker initiates
unknown-accessory discovery; it does not expose the AirPods behavior where an
ordinary app first receives a passive unknown-device event and then asks iOS to
show a product card. After AccessorySetupKit authorization, the app continues
communication through Core Bluetooth, scoped to accessories authorized for it.

Bicino currently supports iOS 16.4, already has Core Bluetooth discovery and a
device-local ownership handshake, and needs to preserve existing registered
devices. Therefore the first implementation uses a custom SwiftUI sheet inside
the active app. The sheet uses native iOS presentation, typography, controls,
materials, Dynamic Type, and accessibility, but Bicino owns its contents and
pairing transitions. AccessorySetupKit remains a separate future migration,
not an availability-gated second setup path in this feature.

## Product definitions

Use these terms consistently:

- **Known**: stored in this iPhone's `BikeComputerDeviceRegistry`.
- **Unclaimed**: ownership advertisement v2 explicitly reports that no owner is
  installed on the device.
- **Claimed**: the device reports an installed owner. It may belong to this
  iPhone, another iPhone, or a stale installation; an advertisement alone
  cannot decide which.
- **Opportunistic discovery**: foreground-only observation used to offer the
  first-device setup while the local registry is empty.
- **Explicit discovery**: a user-owned Nearby session started from **Connect a
  new Bike Computer**.
- **Trusted reconnect**: reconnection to the active known peripheral. This may
  continue in the background.
- **Connected** in the scan policy: any active transport, including
  `isConnecting`, a non-nil `connectedPeripheral`, or an established Core
  Bluetooth connection. The scan must stop at the earliest of these states,
  not after navigation authentication finishes.

## Decisions locked into this plan

1. Opportunistic discovery runs only while the iPhone app is active.
2. It is eligible only while the local Bike Computer registry is empty. Once a
   device is registered, automatic unknown-device discovery stays off even if
   that device is temporarily disconnected.
3. A candidate is eligible for the automatic sheet only when it has the Bicino
   service UUID, valid ownership-v2 manufacturer data, and `isClaimed == false`.
4. Claimed and legacy/unknown-ownership advertisements remain visible in an
   explicit Nearby session but never trigger an unsolicited sheet.
5. Discovery never auto-connects. The user chooses a device and completes the
   existing physical-access and comparison-code checks.
6. No local notification is posted. Bicino automatically presents one custom
   SwiftUI sheet only inside the foreground app.
7. Unknown candidate identifiers, names, RSSI, and timestamps stay in memory
   and are cleared when the scan session ends. They are not added to the device
   registry or analytics.
8. If several eligible devices are nearby, use a brief bounded observation
   window to select the strongest fresh candidate. Presenting the sheet seals
   that candidate and stops the scan so the product shown cannot change under
   the user.
9. Dismissing the sheet suppresses opportunistic discovery for the current
   foreground activation. Leaving and later reopening Bicino may offer it again
   only if the registry is still empty.
10. Scanning stops before any connection attempt and cannot coexist with a
    connecting, restored, or connected peripheral.
11. **Connect a new Bike Computer** cannot scan behind an existing connection.
    The app first asks permission to disconnect the current device, then starts
    explicit discovery only after `didDisconnectPeripheral` confirms teardown.
12. Cancelling that confirmation preserves the existing connection and starts
    no scan.
13. Cancelling or failing candidate pairing resumes explicit discovery only if
    that foreground setup screen still owns the discovery lifecycle.
14. A completed pairing clears all discovery state. Because the registry is no
    longer empty, opportunistic discovery cannot restart.
15. Background trusted reconnect remains supported. Background discovery of
    unknown devices, iBeacon monitoring, UWB/Nearby Interaction, and push
    notifications are out of scope.

## Scan-purpose state model

Replace independent scan booleans as the source of truth with one explicit
purpose. Published compatibility properties may remain, but they must be
derived from this purpose rather than mutated independently.

```swift
enum BLEScanPurpose: Equatable {
    case none
    case trustedReconnect(UUID)
    case opportunisticDiscovery
    case explicitDiscovery
    case selectedPeripheral(UUID)
}
```

`selectedPeripheral` covers the existing fallback where a chosen peripheral is
not in Core Bluetooth's retrieved cache and must be found by identifier before
connecting.

The normative transitions are:

| App/transport state | Allowed scan purpose | Result |
| --- | --- | --- |
| Active, empty registry, idle transport | Opportunistic discovery | Select one fresh unclaimed candidate, stop scanning, and present the setup sheet |
| Active, trusted device absent, idle transport | Trusted reconnect | Connect only the active saved peripheral; ignore every other advertisement |
| Background, trusted device absent, idle transport | Trusted reconnect | Search only for the active saved peripheral; do not publish unknown candidates |
| Active, user opened setup, idle transport | Explicit discovery | Populate the existing Nearby list |
| Active, chosen peripheral not cached, idle transport | Selected peripheral | Accept only that identifier, stop, then connect |
| Connecting | None | Stop scanning before `connect` |
| Connected or authenticating | None | Keep scanning stopped |
| Background, no trusted reconnect pending | None | Clear opportunistic/explicit candidates |
| Watch-direct connection handoff or device administration | None | Preserve the existing exclusive operation |

Priority when more than one condition becomes true:

1. active/restored connection;
2. selected-peripheral pairing handoff;
3. explicit foreground discovery;
4. trusted reconnect; and
5. opportunistic foreground discovery.

The policy must not infer connection state from `isNavigationReady`. BLE radio
ownership begins at the connection attempt.

## Implementation

### Phase 1: centralize scan policy

Add pure policy types to
`ios-app/BikeComputer/BikeComputer/Managers/DeviceOwnership.swift`:

- `BLEScanPurpose`;
- a small `BLEScanContext` containing app activity, Bluetooth availability,
  active-session state, registry state, explicit ownership, and pending
  operations; and
- `BLEScanLifecyclePolicy`, which resolves the allowed purpose and whether a
  current scan must stop.

Keep Core Bluetooth objects out of the policy so every transition can run in
the existing host-side Swift test executable.

Add a separate eligibility helper for the automatic setup sheet. It should
reject:

- stale observations using `BLEDiscoveryFreshnessPolicy`;
- any locally known peripheral or stable device identity;
- `isClaimed == true`;
- `isClaimed == nil`; and
- candidates observed after a discovery generation has ended.

The helper must also refuse every candidate when `knownDevices` is non-empty,
even when the saved device is disconnected or currently unavailable.

Do not rely on RSSI to establish proximity or authenticity. RSSI only sorts
fresh eligible candidates for presentation.

### Phase 2: make `BLEManager` reconcile one scan purpose

In `BLEManager.swift`:

1. Store `isApplicationActive` and the current `BLEScanPurpose`.
2. Add `setApplicationActive(_:)` and one private
   `reconcileScanning(reason:)` entry point.
3. Replace naked `startScanning()` decisions with typed requests for trusted
   reconnect, explicit discovery, opportunistic discovery, or a selected
   peripheral.
4. Keep one private Core Bluetooth start operation. It always filters on
   `DeviceBLEProtocol.serviceUUID`.
5. Use duplicate advertisements only for explicit Nearby lists and the brief
   opportunistic candidate-selection window, where freshness and RSSI ranking
   need updates. Trusted and selected-peripheral scans keep duplicate filtering.
6. Derive `isScanning` from actual start/stop calls and derive
   `isDiscoveringDevices` from the two discovery purposes.
7. Make the active-session guard unconditional. Remove the current exception
   that permits `isDiscoveringDevices` to scan through an active connection.
8. Call `stopScanning()` at the beginning of `connectToPeripheral(_:)`, as
   today, and defensively in `didConnect` and the accepted restoration path.
9. When the app backgrounds, stop opportunistic/explicit scanning and clear
   candidates and freshness timers. Preserve a still-owned explicit Settings
   request as suspended intent so trusted reconnect cannot take the transport
   before foreground restoration; cancelling or leaving that screen releases
   the intent and reconciles trusted reconnect separately.
10. When the app becomes active, start opportunistic discovery only if the
    registry is empty. If a trusted device exists, use only the trusted
    reconnect path and ignore advertisements from all other identifiers.
11. Route `didDiscover` by the active scan purpose/generation and require a
    repeated observation in each new unknown-device scan. A lone callback
    delayed from a stopped scan is quarantined and cannot populate UI or
    trigger a different connection path.
12. On connection failure or disconnect, compute the next purpose rather than
    calling `startScanning()` directly. Preserve current reconnect backoff and
    pending-handoff semantics.
13. After the bounded candidate-selection window, seal the strongest eligible
    candidate and stop the scan before publishing the sheet item. Once the
    sheet is presented, suppress additional opportunistic scans until the next
    foreground activation. If another app-owned presentation blocks the sheet
    until the candidate expires, discard it and resume the foreground scan so
    first-run onboarding cannot consume the only setup opportunity.
14. Clear discovery candidates on successful pairing, restored connection,
    Bluetooth loss, Watch-direct handoff, and device deregistration/forget
    transitions that invalidate the generation.
15. Add concise debug events for purpose transitions and stop reasons without
    logging owner keys or full stable identifiers.

The existing restoration path remains scoped to the active trusted peripheral.
Never restore an opportunistic candidate as if it were a trusted connection.

### Phase 3: connect app lifecycle and presentation

Use the existing `AppDelegate.setApplicationActive(_:)` path in
`BikeComputerApp.swift` to forward activity changes through
`BikeComputerCoordinator` to `BLEManager`. `ContentView` already feeds its
`scenePhase` into this method, and `UIApplicationDelegate` also reports active
and background transitions.

Keep the existing item-driven modal router in `ContentView.swift`. Change
`ContentSheetDestination` from a raw-value enum to an `Identifiable`,
`Equatable` enum with stable computed IDs, then add a lightweight
`.nearbyBicino(peripheralIdentifier:)` destination. Do not add a second
`sheet(isPresented:)` flag beside the existing `.sheet(item:)` presentation.

Automatically present the Nearby destination when all of these are true:

- the app is active;
- no Bike Computer is connecting or connected;
- the local Bike Computer registry is empty;
- a fresh eligible unclaimed candidate exists;
- setup/settings/onboarding is not already presenting an equivalent action;
- map-area selection and another blocking modal are not active; and
- the candidate was not dismissed during this foreground activation.

Create a focused `NearbyBicinoSetupSheet` that visually follows the attached
AirPods reference without copying private Apple artwork or pretending to be
system UI:

- close button in the top-right;
- **Bicino** or the advertised product name as the title;
- a large app-owned Bicino product render or illustration;
- the advertised short code, such as **Device 158D**;
- concise explanatory copy; and
- one full-width blue **Connect** button.

Suggested copy:

```text
Bicino

Connect this Bicino to your iPhone for maps, navigation, and ride data.

Connect
```

The short code must come from the ownership advertisement, matching the code
already used in Nearby and on the device. Do not say **Connected** or
**Registered** at this stage.

Use native SwiftUI sheet presentation and controls, with an adaptive detent that
fits the product image and Dynamic Type. The content itself is app-owned; it is
not the private AirPods proximity card. Add VoiceOver labels, sufficient
contrast, Reduce Motion-safe transitions, and previews for standard and
accessibility text sizes.

Presenting the sheet seals one candidate and stops scanning. Closing it clears
the candidate and suppresses opportunistic discovery until the next foreground
activation. Tapping **Connect** advances within the same modal presentation to
the existing naming and secure code-comparison flow. Refactor the current
private `PairBikeComputerSheet` content into a reusable pairing-flow view rather
than stacking a second sheet on top of the first.

If the retained `CBPeripheral` is no longer usable when **Connect** is tapped,
start only the existing bounded `selectedPeripheral(identifier)` scan. It may
find that selected candidate but must not reopen general discovery.

### Phase 4: preserve multi-device setup without overlapping scans

Update `BikeComputersSettingsView.swift` so **Connect a new Bike Computer**
obeys the single-session rule:

- disconnected: begin explicit discovery immediately;
- connecting: disable the action and show the current connection attempt;
- connected: present a confirmation explaining that the current Bike Computer
  must disconnect before the app can search for another;
- confirmed disconnect: mark explicit discovery as pending, request
  disconnection, and start scanning only from the matching disconnect callback;
  and
- cancelled confirmation: keep the connection and do nothing.

Remove the current discovery-to-new-device path that scans while a current
device remains connected. Retain the secure pairing handoff for cases where the
candidate connection itself must be cancelled or replaced; it no longer
justifies overlapping scan and connection activity.

If the screen disappears while waiting for disconnect, cancel the pending
explicit-discovery intent unless a pairing connection has already begun.

### Phase 5: tests

Extend `NavigationProtocolTests.swift` with deterministic policy coverage:

1. active + Bluetooth on + empty registry + idle transport resolves to
   opportunistic discovery;
2. a non-empty registry disables opportunistic discovery even when its active
   saved device is unavailable;
3. a trusted reconnect scan accepts only the saved identifier and never
   publishes an unknown candidate in either foreground or background;
4. background state rejects opportunistic and explicit discovery;
5. connecting, connected, authenticating, and restored states always resolve
   to no scan;
6. a trusted reconnect remains eligible in the background only while no
   connection is active;
7. trusted reconnect outranks opportunistic discovery;
8. explicit discovery never bypasses an active connection;
9. a confirmed disconnect handoff begins explicit discovery only after the
   matching disconnect callback;
10. cancelled disconnect handoff preserves the current connection and starts no
   scan;
11. only fresh, unclaimed, valid-v2 candidates qualify for the automatic sheet
    while the registry is empty;
12. claimed, legacy/unknown, stale, and locally known advertisements do not
    qualify;
13. the strongest eligible candidate is selected deterministically;
14. sealing the automatic candidate stops scanning before sheet presentation;
15. a stopped discovery generation rejects delayed callbacks and a lone
    callback in a replacement unknown-device scan remains quarantined;
16. dismissing the sheet suppresses scanning for the current foreground
    activation;
17. **Connect** advances the same item-driven sheet into the pairing flow
    without stacking another modal;
18. pairing completion makes the registry non-empty and prevents automatic
    discovery from restarting;
19. pairing cancellation resumes only a still-owned foreground explicit
    session;
20. sensor enrollment temporarily stops unknown Bike Computer discovery and
    resumes the same explicit request afterward;
21. an explicit request made while Bluetooth is off wins over trusted reconnect
    when Bluetooth powers on;
22. foreground/background transitions suspend and resume an owned explicit
    request without starting trusted reconnect; and
23. Bluetooth-off and Watch-direct handoff clear unknown discovery state;
24. production and host tests share the same Bluetooth power-transition
    handler, including explicit-over-reconnect precedence;
25. leaving Settings cancels its owned suspended discovery before restoring
    trusted reconnect;
26. foreground restoration cannot clear an in-flight pairing failure or replace
    its retry UI with a stale progress state; and
27. sensor enrollment or Bluetooth loss releases an unpresented candidate seal
    so eligible opportunistic discovery can resume;
28. foreground and Bluetooth-on callbacks cannot restore explicit discovery UI
    while sensor enrollment still owns the scanner;
29. cancelling a Bluetooth-off Settings request clears its discovery-scoped
    error before trusted reconnect resumes; and
30. a manual reconnect with no registered device re-enables opportunistic sheet
    discovery instead of starting an invisible, unowned explicit scan.

Add UI-policy tests for sheet eligibility, modal-route identity, session
dismissal, in-sheet pairing progression, and the connected-device disconnect
confirmation. Prefer pure presentation policies over source-text assertions.

Run at minimum:

```sh
cd ios-app
./scripts/run-navigation-tests.sh
xcodebuild \
  -project BikeComputer/BikeComputer.xcodeproj \
  -scheme BikeComputer \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The final PR should also pass the repository's complete iOS CI matrix and
Release device build.

## Physical validation

Use an ownership-v2 firmware build and a physical iPhone. No firmware change or
firmware flash is required by this plan.

Validate these scenarios with Core Bluetooth debug events and visible UI:

1. Fresh install/empty registry, one unclaimed Bicino nearby: the AirPods-
   inspired Bicino sheet appears while the app is active.
2. No device nearby: the app stays usable with no spinner or modal interruption.
3. App backgrounded before discovery: opportunistic scanning stops and no local
   notification appears.
4. App foregrounded again: eligible discovery resumes with a new generation.
5. Candidate selected for the sheet: the scan-stop event precedes sheet
   presentation; **Connect** advances into the existing secure pairing flow.
6. Sheet dismissed: no repeated sheet or opportunistic scan occurs during that
   foreground activation.
7. Pairing succeeds: scanning remains off through authentication and ordinary
   app use.
8. Turn the registered Bicino off and advertise a different unclaimed Bicino:
   only trusted reconnect remains active, and no automatic sheet appears.
9. A second Bicino advertises while the first is connected: no Nearby sheet or
   discovery scan begins.
10. **Connect a new Bike Computer** while connected: no scan begins until the
   user confirms and the first device has disconnected.
11. The disconnect confirmation is cancelled: the original connection remains
   active and scanning remains off.
12. Pairing fails or is cancelled from the explicit setup flow: discovery
    resumes only while that foreground flow still owns it.
13. A claimed device owned elsewhere: it does not trigger the automatic sheet
    but remains visible as **Registered** during explicit discovery.
14. Forget or deregister the sole saved device, then begin a new foreground
    activation: first-device opportunistic discovery becomes eligible again.
15. Relaunch with a restored trusted connection: the restored device wins and
    scanning stays off.
16. Trusted device leaves and returns while the app is backgrounded: existing
    trusted reconnect and restoration behavior still works.
17. Watch-direct ride handoff: the iPhone does not start unknown-device
    discovery while its Bicino connection is yielded to Watch.
18. Begin explicit Bike Computer discovery, then begin sensor enrollment: the
    Bike Computer scan stops and the same explicit request resumes only after
    sensor enrollment ends.
19. With a trusted Bicino saved, request a new Bike Computer while Bluetooth is
    off: turning Bluetooth on starts explicit discovery, not trusted reconnect.
20. Background and foreground an owned explicit Settings flow: no unknown scan
    runs in the background, and foregrounding resumes the explicit request
    before trusted reconnect.

Visually verify the sheet in light and dark appearance, portrait and landscape,
the largest accessibility text sizes, VoiceOver, Reduce Motion, and on the
minimum supported iOS version. Confirm that the artwork is Bicino-owned and the
sheet never resembles an iOS permission alert closely enough to imply that it
is system UI.

Record `CBCentralManager.isScanning`, the resolved scan purpose, connection
state, and timestamps for the start/stop/connect ordering. Do not record raw
owner credentials.

## Acceptance gates

Implementation is complete only when:

- a foreground app with an empty registry can automatically present a fresh,
  unclaimed Bicino in the custom setup sheet;
- a non-empty registry disables all automatic unknown-device discovery,
  including while its saved device is disconnected;
- the sheet never auto-connects or bypasses secure pairing;
- opportunistic discovery stops whenever the app backgrounds;
- every connection path stops scanning before connecting;
- no explicit, opportunistic, or trusted scan runs while a peripheral is
  connecting or connected;
- adding another device requires confirmed disconnection before discovery;
- connected navigation, transfer, workout relay, Watch-direct handoff, trusted
  reconnect, and restoration tests remain green;
- unknown observations are not persisted;
- the item-driven sheet supports Dynamic Type, VoiceOver, light/dark appearance,
  and Reduce Motion without stacking a second modal;
- host tests, Debug build, Release build, and complete iOS CI pass; and
- the physical matrix above is recorded in the implementation PR.

## Expected file changes

- `ios-app/BikeComputer/BikeComputer/Managers/DeviceOwnership.swift`
  - scan-purpose, lifecycle, sheet-eligibility, and disconnect-handoff policies.
- `ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift`
  - one scan reconciler, lifecycle input, purpose-aware discovery routing, and
    hard scan/connection exclusion.
- `ios-app/BikeComputer/BikeComputer/Managers/BikeComputerCoordinator.swift`
  - forward application activity and expose the setup handoff.
- `ios-app/BikeComputer/BikeComputer/BikeComputerApp.swift`
  - connect the existing active/background callback to the BLE lifecycle.
- `ios-app/BikeComputer/BikeComputer/ContentView.swift`
  - item-driven Nearby destination and automatic presentation routing.
- `ios-app/BikeComputer/BikeComputer/Views/NearbyBicinoSetupSheet.swift`
  - AirPods-inspired app-owned setup content, previews, and accessibility.
- `ios-app/BikeComputer/BikeComputer/Views/BikeComputersSettingsView.swift`
  - reusable pairing-flow content, explicit disconnect-before-discovery UX, and
    preserved candidate handoff.
- `ios-app/BikeComputer/BikeComputer/Assets.xcassets`
  - Bicino-owned setup artwork sized for the sheet.
- `ios-app/BikeComputerTests/NavigationProtocolTests.swift`
  - scan-policy, candidate, lifecycle, and presentation tests.

No ESP32 source, BLE UUID, advertisement schema, `Info.plist` background mode,
backend, or notification entitlement change is expected.

## Out of scope

- background discovery or notifications for unknown Bicino devices;
- automatic connection, registration, or ownership transfer;
- changing the existing physical confirmation or comparison-code protocol;
- multiple simultaneous Bike Computer connections;
- adopting or migrating existing devices to AccessorySetupKit;
- invoking or imitating the private system-owned AirPods proximity card;
- replacing Core Bluetooth with iBeacon, Nearby Interaction, or UWB;
- firmware advertisement or device-screen changes;
- analytics or server-side device presence; and
- redesigning the full pre-connection device screen beyond the custom iPhone
  sheet and existing setup flow.
