# Selected MapKit route storage: implementation and licensing review

## Status: implemented at maintainer request; Apple permission not established

On 15 September 2026 the maintainer explicitly requested that the existing
Save Offline button save the selected MapKit alternative to Saved Routes.
This updates the repository's implementation policy for deliberate iPhone
saves. It does **not** record a legal approval, written Apple permission,
App Review acceptance, or an exception granted by Apple. Do not describe the
new storage scope as licensed or approved by Apple.

## Primary source reviewed on 15 September 2026

Apple Developer Program License Agreement, definitions and Attachment 6:
https://developer.apple.com/support/terms/apple-developer-program-license-agreement/

The definition of Map Data includes content supplied through Apple Maps and
coordinates. Attachment 6 §2.5 limits caching/prefetching/storage to temporary,
limited permitted service use/performance purposes, followed by deletion,
unless Apple expressly permits otherwise in writing. §2.2 restricts extraction
and secondary/derived databases; §2.4 addresses display on Apple maps.
An indefinite, user-managed offline route library is not established as a
permitted exception by the sources reviewed. Saving only a polyline or JSON,
keeping it local, or displaying attribution does not itself grant permission.

**Before distribution:** obtain a documented applicable permission/legal
resolution, or change the routing source/product behavior. No arbitrary
retention period has been invented as a supposed Apple-approved workaround.
The enabled button in this development PR is not a licensing attestation.
No release, merge into main, or device deployment is part of this change.

## What the code actually does

- Keep normal MapKit responses `activeOnly`. Only an explicit selected route
  becomes `apple.mapkit` / `Apple Maps` / `phoneOnly`; never `user.imported-gpx`.
- Capture the already-normalized canonical route at selection. Retain UUID,
  revision, ordered WGS-84 geometry, steps, endpoint labels, distance, ETA,
  locale and normalization version. Serialize the shared archive, not MKRoute.
- Confirm the name using the same draft/save UI as GPX. Save with existing
  validation, hashing, atomic writes and corruption/deletion handling. Show
  the result in the existing Saved Routes list and map preview.
- Preserve single-result automatic navigation and multi-result selection.
  Saving does not start navigation or trigger another directions request.
- Keep this storage change iPhone-only. Reject Watch transfer at the UI,
  library, transport, receiver and Watch-file-store boundaries. Older Watch
  decoders also reject the unknown phoneOnly scope. No GPX export, new server
  route cache, map-tile download or new provider fetch is introduced.
- Existing iPhone navigation still relays navigation/route data over BLE as
  before. This implementation does not establish permission for displaying
  Apple-derived data on an ESP32/non-Apple basemap; review that separately too.

## Verification expectations

Run the focused offline-save, full navigation, saved-map, shared route and
Watch offline/online suites plus the unsigned generic iOS build. New checks
cover non-fastest selection, immutable geometry/steps, cancellation, storage
failure/retry, duplicates, restart, preview, offline start without directions,
deletion/corruption, China normalization and Watch rejection. Record actual
native results on the final commit in the PR; parser checks are not a build.
Physical airplane-mode riding, UI interaction, GPS/background behavior and
on-device file protection remain separate acceptance checks.
