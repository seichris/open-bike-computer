# Saved-route favorite coordinates: review record

Local branch `fix/saved-route-favorite-coordinates`, not pushed. Recorded
under REVIEW.md before a pull request exists.

- Base: `902a06663e890691672c0704e49175a9cb0e6fe4` (GitHub `main`).
- Reviewed head: `57f781f5c800ec09eceb0758f6157c69b15733fb`. Commits:
  `8f24f1bb` fix, `f6723820` pass-1 fixes, `57f781f5` pass-2 fixes. This
  record is a later documentation-only commit.
- Passes: 3 of 3. Pass 1 covered the whole diff; passes 2 and 3 covered
  `8f24f1bb..f6723820` and `f6723820..57f781f5` plus every open finding.
- State: **clean**. 0 active P0–P2 findings.

## Change

Starring a saved route in Saved Routes created its favorite from the
archive's WGS-84 destination. Map pins create favorites in MapKit
coordinates, and route planning, device destination requests and the
Watch favorite sync all read them that way. In mainland China such a
favorite was routed about 480 m from the saved route's end, and the Watch
received it about 480 m off in the other direction.

- **New stars:** the star now converts the destination with
  `RouteCoordinateNormalizationV1.wgs84ToMapKit`.
- **Existing entries:** when the installed routes load, favorites stored by
  the earlier button, and the copies that planning to them left in Recent
  Searches, are repaired. Only entries still linked to an installed route
  and holding exactly its WGS-84 destination are moved, and only where the
  conversion changes the point.
- **Copies:** a recent with a favorite's ID moves only together with that
  favorite.
- **IDs:** `addFavorite` also replaces an entry with the same ID, so
  favorite IDs stay unique for the Watch favorite sync.

## Risk: medium

Favorites and recents persisted in UserDefaults are rewritten in place,
once, and `addFavorite` now replaces same-ID entries. The Watch favorite
sync receives one more revision and the device destination catalog is
resent once. Recovery needs an app update.

## Findings

| ID | Severity | Status | Summary |
| --- | --- | --- | --- |
| FAV-1 | P2 | fixed, verified | The first repair moved favorites but not their recent copies, which share the favorite's ID and link. A copy resurfaced under Recent Searches still routing off, and saving it again could duplicate a favorite ID, which silently stops the Watch favorite sync. A pass-2 residual, where the favorite had been re-linked to another route before the upgrade, is also fixed. |
| PRE-1 | — | pre-existing, deferred to an app-wide follow-up | The app's GCJ-02 region test is a coarse rectangle that also covers Singapore, Hong Kong, Taiwan, Korea and Thailand, where MapKit uses WGS-84. See below. |

**PRE-1.** The test is `RouteCoordinateNormalizationV1.isInMainlandChina`,
with the same bounds as `CoordinateConverter.isInChina`. This change follows
that app-wide convention. Inside the rectangle but outside mainland China, a
starred favorite now matches how the app already draws the saved route. It
is correct for MapKit-derived routes there, and offset like the drawn route
for GPX, Strava and social routes.

P3 notes, accepted:
- The no-op test cannot distinguish a rewrite of identical bytes from no
  write.
- Only a Debug install that ran the intermediate `8f24f1bb` build could hold
  a repaired favorite next to a stale copy. That build was compiled for
  checks only and never installed.

Invalidated: the concern that CI might skip these source checks when only
view files change. `ios_scopes` in `.github/scripts/ci_scopes.py` selects
every iOS check for Swift paths that no check lists.

Known, documented misses: favorites whose linked route was deleted, legacy
favorites re-linked to a different route before the upgrade (they keep the
old point together with their copies), and Strava reloads that moved the
destination.

## Checks

The receipt-signing key was blanked for every run, so no local result was
published.

- `tools/dev-check --level full` on clean `57f781f5`: 18 passed.
  `ios-navigation-map` failed with "No space left on device" while
  compiling, because the shared disk briefly filled.
  `tools/dev-check --check ios-navigation-map` on the same commit:
  passed.
- `tools/dev-check` on clean `8f24f1bb`: 17 passed.
- Offline-route host group, which includes the new tests: 272 checks on the
  final content.
- Unsigned Debug iOS app build on each committed change: succeeded, with no
  warnings in the touched files.

## Not verified

- No check on a device in mainland China or with a paired Watch.
- No manual UI pass.

## Recovery

Revert the commits and ship an app update. Repaired coordinates stay in
UserDefaults, and the earlier code also reads them as MapKit coordinates, so
they remain correct. After a revert, new stars would store WGS-84 points
again. There is no server state or firmware to roll back.
