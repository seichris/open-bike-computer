# iPhone MapKit Appearance Switcher Implementation Plan

## Outcome

Add an in-map appearance control to the Bicino iPhone app that lets a person
switch the Apple MapKit presentation without leaving the main map:

- Standard street map;
- Satellite imagery;
- Hybrid satellite imagery with roads and labels; and
- optional realistic 3D terrain for any of those base maps.

Present Settings, a direct 2D/3D camera toggle, and Layers in one vertical
bottom-right control rail. Put MapKit's adaptive compass immediately above the
rail so it remains hidden at north-up and appears after the map rotates. Use
native Liquid Glass for the rail on iOS 26 and a system material fallback on
older supported iOS versions.

The switcher uses MapKit's supported map-configuration APIs. It does not add a
third-party tile provider, custom topographic tiles, contour lines, or a new
route provider. The existing Apple route, destination pins, user location,
simulation marker, camera, and Bicino overlays remain on the same `MKMapView`
while its base presentation changes.

This is an iPhone-app feature only. It does not change the ESP32 map renderer,
offline `.fmb` map contents, BLE settings, map-platform jobs, Watch maps, or
saved-map preview images.

## Baseline

This plan was prepared from freshly fetched `origin/main` at
`29be0efcd34fd7a9a9d685df3d311a2ca679d9b3`.

The current implementation has these relevant properties:

- `ContentView` places one `MapViewContainer` behind the app's SwiftUI
  overlays.
- `MapViewContainer` owns one UIKit `MKMapView`; it does not currently set
  `preferredConfiguration`, `mapType`, or an elevation style.
- The visible map therefore uses MapKit's default standard presentation.
- The navigation camera uses a 58-degree pitch. Browsing can also use MapKit's
  normal map gestures, but the app does not expose a map-appearance choice.
- The app installs custom `MKCompassButton` and `MKUserTrackingButton`
  controls. The SwiftUI top overlay separately contains the Bicino connection
  control and Settings button.
- The iPhone app's minimum deployment target is iOS 16.4.
- `OfflineMapManager` deliberately creates small, light-mode, flat standard
  `MKMapSnapshotter` images for saved-map bounds. Those are catalog previews,
  not the live iPhone map.
- The existing Settings screen's Map and Map + Navigation appearance controls
  are BLE-backed settings for the physical Bicino display. They are not an
  appropriate place to store or label the iPhone's Apple MapKit preference.

Apple's supported configuration surface is:

- [`MKMapView.preferredConfiguration`](https://developer.apple.com/documentation/mapkit/mkmapview/preferredconfiguration)
  for changing the live map presentation;
- [`MKStandardMapConfiguration`](https://developer.apple.com/documentation/mapkit/mkstandardmapconfiguration)
  for the street map;
- [`MKImageryMapConfiguration`](https://developer.apple.com/documentation/mapkit/mkimagerymapconfiguration)
  for satellite imagery;
- [`MKHybridMapConfiguration`](https://developer.apple.com/documentation/mapkit/mkhybridmapconfiguration)
  for satellite imagery with roads and labels; and
- [`MKMapConfiguration.ElevationStyle.realistic`](https://developer.apple.com/documentation/mapkit/mkmapconfiguration/elevationstyle-swift.enum/realistic)
  for realistic ground contours.

The older `MKMapView.mapType` API is deprecated in favor of map
configurations. The local Xcode 26.5 SDK marks live-map
`preferredConfiguration` and realistic elevation as available from iOS 16.0,
so the iOS 16.4 app target does not require a legacy `mapType` fallback.

MapKit provides official compass and pitch controls, but it does not provide an
iOS control that chooses among Standard, Imagery, and Hybrid configurations.
Bicino therefore owns the unified SwiftUI rail while reusing
[`MKCompassButton`](https://developer.apple.com/documentation/mapkit/mkcompassbutton)
for correct heading behavior. The custom rail uses SwiftUI's official
[`glassEffect`](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))
on iOS 26.

## Product contract

### Map appearance choices

Expose two independent choices rather than multiplying every combination into
a long preset list:

| Control | Choices | MapKit mapping |
| --- | --- | --- |
| Base map | Standard | `MKStandardMapConfiguration` |
| Base map | Satellite | `MKImageryMapConfiguration` |
| Base map | Hybrid | `MKHybridMapConfiguration` |
| 3D Terrain | Off | `.flat` elevation |
| 3D Terrain | On | `.realistic` elevation |

This yields six supported combinations while keeping the mental model simple.
The user-facing term is **3D Terrain**, not **Topographic**. MapKit realistic
elevation creates a terrain surface, but it does not promise contour lines,
trail-specific symbology, slope shading, or downloadable topographic maps.

### Defaults and persistence

- A fresh install defaults to Standard plus 3D Terrain off. This preserves the
  current map exactly until a person opts into another presentation.
- Persist the base-map choice and terrain toggle across launches.
- Treat the preference as app-global, not per Bicino. It changes only the
  iPhone's Apple map and has no device capability dependency.
- Debug and Release naturally retain separate preferences because they use
  separate app bundle identifiers and sandboxes.
- Unknown or corrupt stored base-style values resolve to Standard. Missing or
  invalid terrain state resolves to off.
- Do not migrate, read, or write the BLE-backed device Map or Map + Navigation
  style settings.

Use versioned UserDefaults keys, for example:

```text
iphoneMapAppearance.baseStyle.v1
iphoneMapAppearance.realisticElevation.v1
```

### Switcher placement and behavior

Add one trailing, bottom-right vertical rail above Bicino's existing dynamic
bottom overlay. Its order from top to bottom is Settings, 2D/3D, and Layers.

- Give every item at least a 44-by-44-point hit target and use standard system
  symbols.
- Settings opens the existing settings sheet.
- 2D/3D directly toggles the live camera between 0 and 45 degrees without
  changing base style or realistic elevation.
- Disable the pitch action during active navigation so it cannot compete with
  the existing 58-degree navigation camera.
- Layers uses the accessibility label `Layers` and opens the appearance menu.
- Organize menu commands into Base Map and Elevation sections.
- Show a checkmark beside the selected base map and beside 3D Terrain when it
  is enabled.
- Give 3D Terrain the accessibility hint `Adds realistic elevation; tilt the
  map to see the terrain.`
- Keep the menu available before, during, and after navigation. The existing
  higher-z-index map-selection and onboarding surfaces continue to take
  interaction priority while they are visible.
- Changing a choice updates the existing map immediately and closes the menu.
- Do not open the full Settings sheet merely to change the live map.
- Apply one interactive Liquid Glass surface to the whole rail on iOS 26. Use
  `.ultraThinMaterial`, a subtle stroke, and a small shadow on iOS 16.4 through
  iOS 25.
- Place the standard adaptive `MKCompassButton` directly above the rail. It is
  hidden by default and appears only when the map heading differs from north.

The menu is Bicino-owned UI because MapKit has no base-style picker. It should
still use standard SwiftUI menu semantics, Dynamic Type, VoiceOver, and system
symbols. The native compass retains MapKit's behavior and accessibility.

### Camera and pitch behavior

- Explicitly keep `mapView.isPitchEnabled = true`.
- Do not recenter, zoom, rotate, flatten, or automatically pitch the camera
  when a map appearance changes.
- The existing 58-degree navigation camera immediately reveals realistic
  terrain during active navigation.
- Outside navigation, the person can use either MapKit's pitch gesture or the
  rail's direct 2D/3D action.
- On iOS 17 and later, set `pitchButtonVisibility = .hidden` because the rail
  now owns the explicit pitch action and a second control would be redundant.
- Observe camera changes through the existing `MKMapViewDelegate` so the rail's
  action icon stays correct after gestures and compass resets.
- The adaptive compass is never forced visible during navigation; its
  visibility depends only on heading.

Not changing the camera is intentional. A base-layer choice must not interrupt
free panning, dismiss a destination callout, or make the map jump while the
person is riding.

## Decisions locked into this plan

1. Use `preferredConfiguration`; do not use deprecated `mapType` for the live
   map.
2. Keep base map and elevation as independent persisted choices.
3. Preserve Standard plus flat elevation as the default.
4. Change the configuration on the existing `MKMapView`; do not recreate the
   UIKit view.
5. Apply a configuration only when the resolved appearance value changes.
   SwiftUI updates for GPS, BLE, workouts, or route progress must not repeatedly
   replace the configuration.
6. Do not mutate the camera as a side effect of changing appearance.
7. Continue rendering the route above roads and retain every current annotation
   and callout path.
8. Keep the iPhone preference independent of Bicino device settings and BLE.
9. Keep saved-map catalog snapshots flat Standard for consistent, inexpensive,
   readable thumbnails.
10. Do not market realistic elevation as a complete topographic map.
11. Do not add provider selection, Apple Maps caching controls, downloadable
    Apple map data, or custom tile overlays.
12. Keep iOS 16.4 support. Liquid Glass and the iOS 17 pitch-button visibility
    API remain availability-guarded with native fallbacks.
13. Keep realistic elevation and camera pitch independent: Layers chooses the
    terrain surface, while 2D/3D chooses the viewing angle.
14. Use MapKit's adaptive compass instead of recreating heading behavior.

## Proposed architecture

```text
SwiftUI bottom-right control rail
       |
       +---- Settings
       +---- 2D/3D camera action ----> MapViewControlState ----> MKMapCamera
       +---- Layers menu
       |
       +---- persisted base-style raw value
       +---- persisted realistic-elevation Boolean
                         |
                         v
              IPhoneMapAppearance value
                         |
                         v
                 MapViewContainer
                         |
                         v
          Coordinator.applyAppearanceIfNeeded
                         |
                         v
      existing MKMapView.preferredConfiguration
        |                |                 |
        v                v                 v
     Standard         Imagery           Hybrid
        \________________|________________/
                         |
                   flat or realistic
```

### Appearance value model

Add a narrow value model under the iPhone app, for example
`Models/IPhoneMapAppearance.swift`:

```swift
enum IPhoneMapBaseStyle: String, CaseIterable, Identifiable {
    case standard
    case satellite
    case hybrid
}

struct IPhoneMapAppearance: Equatable {
    var baseStyle: IPhoneMapBaseStyle
    var usesRealisticElevation: Bool
}
```

The model owns:

- stable persisted raw values;
- user-facing labels and system symbols, if keeping those properties out of
  `ContentView` improves readability;
- normalization of unknown persisted values; and
- a MapKit configuration factory that creates a new configuration of the
  correct subclass with `.flat` or `.realistic` elevation.

Do not persist `MKMapConfiguration` objects. They are mutable presentation
objects, not application settings. Persist only Bicino's small value model and
create a fresh MapKit configuration when the value changes.

### SwiftUI persistence boundary

`ContentView` owns the two app-level values through `@AppStorage` or an
equivalent injectable UserDefaults-backed store. Prefer the smallest approach
that still permits deterministic invalid-value tests.

Build one resolved `IPhoneMapAppearance` and pass it to `MapViewContainer`.
The menu writes only those two persisted values. It must not reach into the
coordinator, BLE manager, or `MKMapView` directly.

A narrow observable control state bridges the explicit 2D/3D action and native
compass to the existing `MKMapView`. It does not own appearance persistence,
route state, or navigation policy.

### UIKit application boundary

Add `appearance: IPhoneMapAppearance` to `MapViewContainer`.

In `makeUIView`:

1. create the existing `MKMapView`;
2. enable pitch;
3. apply the initial appearance before the first region/camera work; and
4. install the existing controls, gestures, and delegate.

In `updateUIView`:

1. ask the coordinator to apply the appearance if it differs from the last
   applied value; then
2. continue the existing location, route, annotation, camera, and tracking
   updates unchanged.

The coordinator stores `lastAppliedAppearance`. Its application helper:

- returns immediately for an equal value;
- assigns exactly one newly created object to
  `mapView.preferredConfiguration` for a changed value;
- updates the stored value only after assignment; and
- does not remove overlays, annotations, or change `userTrackingMode`.

Keep configuration creation separate from application so the mapping can be
host-tested without driving a live map renderer.

### Overlay and route continuity

Map appearance changes must leave these objects and states intact:

- `MKRoute.polyline` and its current renderer;
- destination and simulated-position annotations;
- the selected destination callout and asynchronous reverse-geocoded label;
- `showsUserLocation` and authorization handling;
- `.follow` or `.followWithHeading` tracking;
- offline area-selection free pan and bounds conversion;
- current camera center, distance, pitch, and heading; and
- the current search, workout, route-alternative, and navigation overlays in
  SwiftUI.

Do not call `removeOverlays`, `setRegion`, `setVisibleMapRect`, or `setCamera`
from the appearance application helper. Existing route/lifecycle code remains
the only owner of those transitions.

## UI details

Control rail and menu hierarchy:

```text
Settings
2D / 3D
Layers
  Base Map
    [check] Standard
            Satellite
            Hybrid
  Elevation
    [check] 3D Terrain
```

Suggested symbols:

| Item | Symbol |
| --- | --- |
| Settings | `gearshape.fill` |
| 2D/3D action | `view.2d` / `view.3d` |
| Layers menu | `map.fill` |
| Standard | `map` |
| Satellite | `globe.americas.fill` |
| Hybrid | `map.fill` |
| 3D Terrain | `mountain.2.fill` |

Use availability-safe symbol fallbacks if any selected symbol is unavailable
on iOS 16.4. Symbol availability must not raise the deployment target.

The unified rail should remain legible over Standard, Satellite, and Hybrid in
light and dark system appearance. Liquid Glass supplies the iOS 26 treatment;
the system-material fallback supplies contrast on older iOS versions.

## Persistence and recovery behavior

The persisted state is convenience UI state, not a security or device-authority
boundary.

- Load and normalize it synchronously with the view.
- Never delay map creation on disk or network work.
- If the raw base style is unknown, use Standard without crashing.
- If a future version removes a style, old values safely fall back to Standard.
- Do not copy preferences between Debug and Release or into an App Group.
- Do not sync the preference to iCloud, WatchConnectivity, BLE, or the map
  backend.

## Testing strategy

### Host tests

Add focused Catalyst-compatible coverage, for example
`ios-app/BikeComputerTests/MapAppearanceTests.swift`, and include the new model
in the relevant host-test compile commands.

Required assertions:

1. the default resolves to Standard plus flat elevation;
2. each base style creates the intended MapKit configuration subclass;
3. the terrain Boolean maps to `.flat` and `.realistic` for every base style;
4. persisted raw values round-trip;
5. an unknown raw base style falls back to Standard;
6. changing only terrain produces a different appearance value; and
7. equal appearance values compare equal so the coordinator can suppress
   redundant assignments; and
8. camera pitches around the threshold resolve to the correct 2D/3D state and
   action target.

Keep MapKit renderer behavior out of pure tests. Validate only Bicino's mapping,
normalization, and idempotence contract there.

If the new model is a separate source file, update the existing Catalyst
`DestinationCalloutLayoutTests` compile list because `MapView.swift` will now
reference it. Add a separate small executable for `MapAppearanceTests` rather
than folding unrelated assertions into destination-callout tests.

### Existing regression checks

Run:

```sh
cd ios-app
./scripts/run-navigation-tests.sh
./scripts/xcodebuild-cli.sh -project BikeComputer/BikeComputer.xcodeproj \
  -scheme BikeComputer -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Also run `git diff --check` and inspect the final plan/implementation diff for
accidental firmware, BLE, map-platform, Watch, or saved-preview changes.

### Simulator and physical-device acceptance

Validate at minimum:

1. a fresh install starts with the same Standard flat map as current `main`;
2. all three base maps switch without recreating the screen or losing the
   visible region;
3. the 3D Terrain toggle survives app termination and relaunch;
4. a pitched view around a well-defined mountain area visibly uses MapKit
   realistic terrain when enabled and returns to a flat ground surface when
   disabled;
5. switching appearance during route preview retains the entire route and its
   fitted camera;
6. switching during simulated and real navigation retains the 58-degree camera,
   heading, tracking, route, and position marker;
7. switching while a destination callout is selected does not dismiss it or
   resume tracking;
8. offline area selection still converts the visible selection frame to the
   same geographic bounds;
9. Standard, Satellite, and Hybrid keep the route line and controls readable
   in light/dark appearance and portrait/landscape;
10. all three rail actions have correct VoiceOver labels, state, and at least
    44-point hit targets;
11. iOS 16.4 uses the system-material rail fallback without calling iOS 26-only
    APIs;
12. iOS 26 presents the native Liquid Glass rail;
13. the compass is absent at north-up, appears above the rail after rotation,
    and resets the map correctly when tapped;
14. the 2D/3D action tracks gesture-driven pitch changes, toggles 0/45 degrees,
    and stays disabled during active navigation; and
15. changing styles during slow or unavailable networking does not crash or
    remove application overlays. MapKit-owned placeholder/loading behavior is
    acceptable.

Use a physical iPhone for the final terrain and control-layout check. A green
build proves API compatibility, not terrain coverage, gesture quality, or
readability in motion.

## File-by-file implementation

### `ios-app/BikeComputer/BikeComputer/Models/IPhoneMapAppearance.swift`

- Add the base-style enum and appearance value.
- Add safe raw-value normalization.
- Add the MapKit configuration factory.
- Keep the model independent of BLE and offline-map models.

### `ios-app/BikeComputer/BikeComputer/ContentView.swift`

- Add versioned persisted base-style and terrain state.
- Build the resolved appearance value.
- Move Settings into a bottom-right vertical control rail.
- Add the direct 2D/3D action and Layers menu to that rail.
- Apply native Liquid Glass on iOS 26 and the material fallback earlier.
- Place the MapKit compass immediately above the rail.
- Pass the appearance into `MapViewContainer`.
- Preserve existing overlay ordering and settings presentation.

### `ios-app/BikeComputer/BikeComputer/Views/MapView.swift`

- Accept the appearance value.
- Apply it during `makeUIView`.
- Apply changes idempotently during `updateUIView`.
- Explicitly enable pitch.
- Add a narrow camera-control state and update it from delegate callbacks.
- Hide MapKit's separate pitch button on iOS 17 and later.
- Keep the existing navigation-only tracking control.
- Preserve all route, annotation, tracking, and camera ownership boundaries.

### `ios-app/BikeComputerTests/MapAppearanceTests.swift`

- Cover defaults, normalization, configuration-class mapping, elevation
  mapping, equality/idempotence inputs, and pitch-state/action mapping.

### `ios-app/scripts/run-navigation-tests.sh`

- Compile the appearance model anywhere `MapView.swift` is compiled.
- Add and execute the focused Catalyst map-appearance test binary.

### `docs/README.md`

- Index this implementation plan and track the remaining physical-validation
  status.

No change is expected in:

- `BLEManager.swift` or the BLE protocol;
- firmware sources;
- `OfflineMapManager` saved-map snapshot configuration;
- map-platform services;
- Watch targets; or
- App Store privacy disclosures.

## Implementation sequence

1. Add the value model, persistence keys, and mapping tests.
2. Thread the resolved appearance through `ContentView` and
   `MapViewContainer` without adding UI, then verify the default is unchanged.
3. Add the idempotent `preferredConfiguration` application helper.
4. Add the Layers menu and persisted bindings.
5. Add the bottom-right Settings / 2D-3D / Layers rail, native compass, and
   iOS 26 Liquid Glass with the earlier-system fallback.
6. Run host tests and the unsigned generic iOS build.
7. Exercise route preview, callout free-pan, offline selection, simulation, and
   active-navigation continuity in Simulator.
8. Validate realistic terrain and control placement on a physical iPhone.
9. Record any MapKit coverage limitation as a validation note rather than
   adding proprietary terrain data to this feature.

## Risks and mitigations

### Reassigning configuration on every SwiftUI update

GPS, route progress, workout state, and BLE events can update `ContentView`
frequently. Recreating MapKit configuration on every pass may reload tiles or
produce flicker.

Mitigation: compare the small appearance value in the coordinator and assign a
new configuration only after an actual user preference change.

### Camera or overlay disruption

A careless implementation may treat a style change like map recreation and
lose camera/tracking state or overlays.

Mitigation: keep one `MKMapView`, never clear map content from the appearance
helper, and explicitly validate route/callout/free-pan continuity.

### Satellite route legibility

The existing six-point system-blue route may have weaker contrast over some
imagery.

Mitigation: make route readability an acceptance gate across representative
urban, forest, water, and mountainous imagery. Do not silently redesign the
route in the same patch unless that gate demonstrates a failure; if it does,
add the smallest style-independent casing treatment with its own tests.

### Terrain expectations

Realistic elevation depends on Apple's map data, selected zoom, camera pitch,
OS, and region. It is not a digital-elevation export or contour map.

Mitigation: label the toggle 3D Terrain, document the limitation, test a known
supported mountainous area, and avoid claims that every mountain or region has
the same detail.

### Pitch-control layout

The rail sits above dynamic route, workout, and search panels, and the adaptive
compass needs a stable position even while hidden.

Mitigation: keep the rail inside the same bottom overlay stack so it moves above
the panels, reserve the compass's 44-point slot to avoid rail jumps, and
validate portrait, landscape, compact height, navigation, and offline-selection
states.

### Network and data use

Satellite and hybrid imagery can load more data than Standard, and MapKit owns
its cache and network behavior.

Mitigation: make imagery explicitly user-selected, avoid background
preloading, and do not promise offline availability.

## Out of scope

- contour lines, elevation labels, trail grading, slope shading, or a true
  hiking/cycling topographic style;
- custom raster/vector tile providers or overlays;
- exporting Apple elevation or map imagery to the ESP32;
- changing Bicino `.fmb` map generation or 3D-building rendering;
- synchronizing the iPhone style with device Map/Map + Navigation profiles;
- changing MapKit routing or transport type;
- changing saved-map preview thumbnails;
- automatic camera flyovers or non-user-initiated pitch changes outside the
  existing navigation camera;
- Apple Maps offline-download management; and
- telemetry or analytics for map-style selection.

## Definition of done

The implementation is complete when:

- the app presents a native, accessible Map appearance menu;
- Settings, 2D/3D, and Layers appear in one bottom-right rail with the adaptive
  compass above it;
- iOS 26 uses native Liquid Glass and older supported systems use native
  material fallback;
- Standard, Satellite, and Hybrid use the correct official MapKit
  configurations;
- 3D Terrain independently selects flat or realistic elevation;
- Standard plus flat remains the fresh-install default;
- the selection persists safely across relaunches;
- configuration changes are idempotent and retain camera, route, annotations,
  callouts, tracking, and SwiftUI overlays;
- the camera action and adaptive compass behave as specified without competing
  with navigation camera ownership;
- host tests, the unsigned generic iOS build, and `git diff --check` pass;
- physical-iPhone testing demonstrates realistic mountain terrain in a pitched
  view and acceptable control/route readability; and
- no firmware, BLE, Watch, map-platform, saved-preview, or custom-topographic
  scope has entered the change.
