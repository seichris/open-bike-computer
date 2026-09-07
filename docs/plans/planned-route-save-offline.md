# Planned-route Save Offline (iPhone)

## Baseline and prerequisite

Implementation baseline: `b072b60f49213c41a7a53392a23abfbcf7d9d1cd`.
PR #429 preview prerequisite: `b8282d3954b59fde7f551856bf8242e8024a274e`.
The isolated implementation worktree integrates that preview without modifying
its PR. The navigation runner retains both main's cycling-sensor observation
tests and #429's saved-route map tests.

## Scope and policy gate

This is **not MapKit route persistence**. `NavigationRouteAlternativeV1` still
contains `MKRoute`; its Save Offline control stays disabled. No MapKit geometry
is written, exported to GPX, or relabelled as user-provided data.

`RouteProviderPolicyV1` remains authoritative and unchanged in substance:

- `user.imported-gpx`: approved durable local route, optional expiry.
- `strava.route`: receipt-backed cache, required expiry, at most seven days;
  original attribution, source URL, creation date and expiry are retained.
- `apple.mapkit`: active use only. Unknown/self-declared durable providers are
  denied. There is no new policy approval or legal interpretation here.

New Strava data continues through the existing receipt/bookmark transaction,
not the generic GPX draft save API. Saving an already installed Strava archive
is idempotent and cannot extend its deadline. Adding durable MapKit planning
requires a separately approved provider/export contract and implementation;
a UI enablement change alone is not sufficient.

## User flow

Settings → Saved Routes → Import GPX parses a memory-only draft using the
existing importer. A Save Offline sheet derives a route name and allows editing
before the one durable commit. Empty or excessively long names cannot save.
Cancel, picker dismissal and app termination before confirmation write no draft.
After success the existing library row shows the route and success/duplicate
feedback. Storage errors remain in the sheet and permit retry.

Saved GPX and unexpired Strava rows retain #429's separate Show on Map action
and add Navigate Offline on iPhone. A preview never starts navigation. Starting
navigation resolves the exact UUID/revision/content-hash through the library
again, so a stale preview cannot resurrect a deleted, replaced, expired or
corrupt archive. Navigation and route planning must first be stopped/cancelled.

Offline starts feed canonical WGS-84 geometry directly into the existing
NavigationRuntimeV1 and NavigationEngine with mode `offline` and the archive
hash. No MKDirections, local search, network check or Watch connection is
needed. Display conversion reuses SavedRouteMapPreviewFactory once; the live
map owns a normal navigation overlay separately from the saved preview layer.
No GPS fix is required to enter navigation, but location permission and a fix
are required to make progress. No connector route or online reroute is silently
requested. Basemap tiles are **not** included by saving route geometry.

The route-choice flow explicitly starts a single usable returned route and
sorts multiple alternatives fastest-first, preserving provider order for equal
or unavailable estimates. Multiple alternatives still require rider selection.

## Durable identity and failure boundaries

NavigationRouteArchiveV1 and NavigationRouteFileStoreV1 remain the serialization
and storage authorities. Geometry, provider metadata, schema, normalization,
retention and SHA-256 integrity are validated before admission, after disk
write, after restart and at offline start. Names are set before creating the
final hash. UUID/revision/hash are not rewritten after installation.

Exact library saves return the installed identity unchanged. Reimported local
GPX routes with equal canonical navigation content (excluding UUID, revision,
archive timestamps and route name) return the existing identity and name.
Different providers, source references or navigation instructions never dedupe.
Same-UUID stale revisions and same-revision content conflicts still fail.

The store bounds regular-file reads before decoding, rejects symbolic links
and mismatched archive filenames, and synchronizes local deletion. It retains
the existing atomic-write, capacity, file-protection and bounded quarantine
mechanisms. iPhone initialization no longer falls back to temporary storage.

Provider deletion tombstones hide routes from preview/navigation and retry
local cleanup after storage failure/restart; an explicit failed local deletion
reports failure instead of claiming successful removal. Expired active Strava
geometry is cleared by the engine heartbeat even without a location fix, and
also checked before location/reconnect resends. Library identity removal or
replacement stops active offline navigation. The app does not automatically
resume a navigation session after restart: the durable route remains selectable.

## Verification

Focused tests use the production source policy, save-session state machine,
library, importer, archive codec, store, map coordinator, navigation coordinator
and runtime. Boundary doubles cover Watch transport and direction requests.
They cover admission/spoofing, naming, cancel/success/failure UI state, duplicates,
UUID/revision/hash/schema, quota/IO failure, corruption and bounded reads,
delete failure/retry, restart persistence, no-network starts, expiry without a
fix, map ownership, planning exclusion, and single/multiple-route behavior.

Run from `ios-app`:

```sh
./scripts/run-navigation-tests.sh
./scripts/run-saved-route-map-tests.sh
./scripts/xcodebuild-cli.sh -project BikeComputer/BikeComputer.xcodeproj \
  -scheme BikeComputer -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Linux can run the source-eligibility and preview-policy checks, but cannot run
native MapKit/SwiftUI/CryptoKit integration or the iOS build. Those require an
Apple SDK. Do not interpret a portable runner's native-skip message as a native
pass. The PR report records actual runs separately.

Physical iPhone airplane-mode navigation, permission/GPS acquisition, app
force-quit/relaunch, iPhone file-protection/low-storage behavior, accessibility,
Strava expiry over suspension, and BLE/Watch/device navigation require separate
manual verification. No hardware was flashed or production automation enabled.
