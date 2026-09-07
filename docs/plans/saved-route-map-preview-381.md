# Saved-route map preview (#381)

## Scope and ownership

Implemented from GitHub main `44e0df3bf87cce1aca0c4da9d5d7b776f1823c1b`.
This is an iPhone-only presentation feature, not a navigation start, Watch
transfer, new route import, or alternate persistent route cache.

`SavedRoutesSettingsSection` exposes a local **Show on Map** action separately
from rename, Watch sync, reload, and delete controls. The scoped
`SavedRouteMapAction` environment value carries the Settings-to-ContentView
callback. Navigation disables it; transfer and acknowledgement status do not.
Expired Strava bookmark rows retain their existing reload/link actions only.
Read or construction failure leaves Settings open with a localized error.

`PhoneRouteLibrary.mapSelection(for:)` resolves the exact UUID, revision, and
content hash through the existing archive store and revalidates retention after
the read. A successful read has no write/Watch effects. Failure uses the normal
library reload/pruning path rather than substituting another revision.

`SavedRouteMapPreviewFactory` converts the verified canonical WGS-84 points at
the iPhone display boundary using the existing China coordinate policy. It
validates point count, finite coordinates, distinct geometry, map bounds, and
expiry before and after construction. Only the finished polyline and display
metadata survive construction; no archive/coordinate array is persisted.

`ContentView` owns ephemeral presentation state. Library changes reconcile the
full immutable identity; deletion, pruning, expiry, replacement, and foreground
reload invalidate old geometry. The library's existing expiry scheduling remains
authoritative. Starting route planning, navigation, or offline-area selection
clears the saved preview. An explicit attempt during an existing plan is rejected
without cancelling that plan. Hide affects presentation only.

The MapKit coordinator owns separate arrays/references for calculated/navigation
polylines and the saved polyline. It never clears all overlays. Precedence is
navigation, calculated route/alternatives/in-flight calculation, saved preview,
then no route. Saved styling is thinner and translucent with rounded caps/joins.
The camera waits for the bottom card's measured layout, keyed by full identity,
then fits once; location/appearance/layout updates cannot repeatedly refit it.
Hide restores authorized follow unless another interaction owns free pan.

An active workout continues normally, but its automatic metrics-sheet restoration
is suspended during preview so that closing Settings reveals the map. Hiding the
preview restores normal ride-sheet behavior. Nearby-device automatic sheets are
also deferred while the preview is present.

## Automated verification

Run the focused suite with:

```sh
bash ios-app/scripts/run-saved-route-map-tests.sh
```

The portable Swift policy suite covers all precedence combinations, full-identity
camera changes, repeated updates, reopening, deletion/replacement, and the exact
expiry boundary. It was compiled and executed with Swift 6.2.1 on Linux: **178
checks passed**.

On macOS the same script also compiles a focused Mac Catalyst executable against
the production archive store, PhoneRouteLibrary, preview factory, and MapView
coordinator. Only the Watch-connectivity and map-system boundaries are doubled.
It covers both providers/local aliases; archive bytes, modification time,
preferences and Watch effects; stale/missing/corrupt archives; expiry/deletion;
China/non-China conversion; 50,000-point reuse; overlay ownership and styling;
one-time layout-aware fitting; free-pan preservation; priority transitions; and
successful/failed Settings callbacks.

The focused runner is included in `run-navigation-tests.sh`. Existing MapView
Catalyst suites also compile the new shared presentation policy.

**Environment limit:** the implementation environment has no Apple SDK or Xcode.
The Mac Catalyst suite, full iOS build, and interactive UI checks were not run
locally. CI/build results must be checked separately; adding a test is not proof
that it has passed.

## Interactive acceptance checks (not performed locally)

1. Import a GPX and a currently valid Strava route; rename each and show it from
   Settings. Confirm Settings dismisses only after success and the main map/card
   shows the selected alias, labels, distance, attribution, and Strava expiry.
2. Repeat while a Watch transfer is pending or rejected. Preview still works and
   does not send a route. During navigation it is disabled. Expired Strava rows
   offer reload/link but no preview.
3. Pan/zoom, change Layers, toggle 2D/3D, rotate the phone, and receive location
   updates. Verify the preview remains and no update repeatedly snaps the camera.
   Hide and reopen; the new presentation should fit again.
4. Preview a China route and a non-China route. Confirm alignment without changing
   the archive. Exercise deletion, a newer imported revision, provider expiry,
   and foreground return: old geometry must disappear.
5. Start search/planning, select alternatives, start/stop navigation, and choose
   an offline map area. Confirm route priority, destination callouts, unrelated
   overlays, and existing map controls are preserved.
6. Preview during an active workout, hide it, and reopen Settings. The workout
   must keep running and its metrics sheet must not cover the preview immediately.
7. Check VoiceOver names/hints, 44-point preview/close targets, long route names,
   large accessibility text, landscape and a small iPhone screen. Capture UI
   screenshots during this device/simulator verification.
