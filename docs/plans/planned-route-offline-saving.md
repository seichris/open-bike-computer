# Planned-route offline saving: approved sources only

Baseline: `origin/main` at `b082746ef0d8e53ab08d3755206536ef2b0fa00c`.
PR #429 is already merged and its GPX/Strava preview remains the presentation boundary.

## Policy and scope

`RouteProviderPolicyV1` remains the authority. `apple.mapkit` is active-only;
`user.imported-gpx` is durable; `strava.route` is allowed only with its original
validated source reference and a maximum seven-day retention period. Unknown
providers cannot opt in by declaring `.durable`. This change grants no new
rights, exports no MKRoute geometry, and does not reclassify MapKit routes.

The MapKit alternative chooser still cannot save its selected Apple route.
It now offers **Import GPX or choose a saved route**. In that approved-source
panel, selecting a valid GPX draft or a valid library-backed route enables
**Save Offline**. New GPX imports have an editable, bounded name. The Settings
GPX importer derives a name from GPX metadata or the filename and shares the
same duplicate-safe commit path. Existing saved-route aliases remain editable
through Settings; saving an existing route does not rename or clone it.

This is not implementation of policy-gated MapKit Save Offline. The approved
GPX/library path and offline navigation are the implemented scope.

## Storage and identity

`OfflineRouteSaveDraft` can be constructed only by the GPX importer or a
validated installed archive. Drafts live in memory. Cancellation before Save
has no storage effects. Synchronous commits cannot be interrupted midway by
sheet dismissal; failure retains the same draft UUID for retry.

`PhoneRouteLibrary.saveOffline` reuses `NavigationRouteArchiveV1` and the
verified atomic `NavigationRouteFileStoreV1` write, file protection, capacity
limits, hashing, validation and quarantine. There is no second route database,
index, or coordinate cache. The fallback storage location is Application Support,
not a purgeable temporary directory.

New GPX imports keep their staged UUID/revision. Exact semantic duplicates compare
source, normalization, ordered geometry, endpoints and guidance; they reuse the
installed UUID/revision/hash, ignoring import timestamps and the proposed name.
Reversed routes and changed guidance are not duplicates. Existing route saves
re-read the exact identity, never rewrite bytes, replace a newer revision, or
renew Strava expiry. Disk failures/capacity limits never evict phone routes
silently. Deletion synchronizes the containing directory.

## Offline navigation and preview

Saved routes remain in the existing Settings library and PR #429 map preview.
The preview and approved-source panel offer an explicit **Start Offline
Navigation** action. Starting always re-reads the exact persisted identity,
revalidates policy/hash/geometry/retention, then enters `NavigationRuntimeV1` in
`.offline` mode with the archive's content hash. No directions, geocoding,
Strava request or GPX reparsing is required to start. Live GPS remains canonical
WGS-84; the active map polyline converts once at the MapKit display boundary.

An offline start invalidates pending online request generations and cancels
those tasks. Its active polyline belongs to the navigation layer, not the
saved-preview layer. Offline off-route guidance asks the rider to return to the
saved route; it never silently enables online rerouting. Deletion, replacement,
corruption detected by normal library reload, and retention expiry stop the
active offline route. The engine also enforces expiry on GPS and heartbeat
updates. A launch reloads saved routes but does not silently resume navigation.

One MapKit result still starts immediately; multiple results remain selectable
and fastest-first. PR #429 overlay ownership, identity reconciliation, China
coordinate conversion, and read-only preview behavior are preserved.

Route guidance is separate from basemap tiles. This feature downloads no map
areas and cannot guarantee that Apple map tiles are available offline. GPX
provides its own geometry/waypoint guidance, not new turn directions from Apple.

## Verification

Focused suite: `ios-app/scripts/run-offline-route-tests.sh`; it is also included
in `run-navigation-tests.sh`. It compiles the actual library, store, importer,
interaction state, engine and coordinator, with Watch/directions boundaries
doubled. It covers allowlists, invalid geometry/names, schema/hash rejection,
archive round trips, UUID/revision/hash identity, retries/duplicates, filesystem
and capacity failures, cancellation, restart/deletion/corruption, stale revisions,
Strava expiry, offline startup without directions, off-route behavior, late
online completion, button/feedback wiring, and one/multiple-result regressions.
PR #429's native suite adds offline active-overlay ownership/reuse transitions.

Native verification passed on code commit
`302df26bf3ae5fa61f19e70d8cacdfc12753bd5b`, using Xcode 26.6 on a macOS
GitHub Actions runner. Run: [34174921680](https://github.com/seichris/open-bike-computer/actions/runs/34174921680).
Commands run from `ios-app`:

```sh
./scripts/run-offline-route-tests.sh
./scripts/run-navigation-tests.sh
./scripts/run-saved-route-map-tests.sh
./scripts/xcodebuild-cli.sh -project BikeComputer/BikeComputer.xcodeproj -scheme BikeComputer -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

All four commands exited successfully. The focused suite passed 86 checks;
the saved-map suite passed 178 policy checks and 86 native integration checks.
The full navigation suite, including its existing renderer, protocol, runtime,
layout and preview regressions, passed. The unsigned iOS build succeeded.
No physical-device or UI-automation run is implied by these results. The UI
coverage consists of interaction-state/coordinator tests, source-wiring checks,
native MapKit integration tests and the real SwiftUI application build.

Local Linux attempts ran the portable cycling observation and 178 saved-map
policy checks successfully; native tests/build were blocked by missing `xcrun`.
Swift parser checks and `git diff --check` passed locally. The first native
focused/navigation attempt found two test-helper access-control compile errors;
those were corrected before the fully passing run above. The first native
saved-map suite and iOS build also passed. Subsequent changes to this document
only record these results; they do not change the tested application or tests.

Not performed: installation or flashing; airplane-mode iPhone/Watch/Bicino ride;
GPS/background/lock-screen retention behavior; map alignment or screenshots;
VoiceOver/Dynamic Type/landscape; disk-full/protected-storage behavior on a phone.
