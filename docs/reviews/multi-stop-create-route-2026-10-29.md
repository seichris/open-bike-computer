# Multi-stop Create a Route: review record

Branch `feature/create-route-waypoints-20261029`. Recorded under REVIEW.md
before the pull request existed; the pull request description carries the
later record. See "Base sync" for the 2026-11-06 merge of `main`.

- Base: `f37a084facc8a286ad506bd51bfc2e6adbd19957` (GitHub `main`).
- Reviewed head: `92ae2cf30daeb13de5737a3eb93e99dc55a1f3b9`. Commits:
  `73c0d11e` feature, `ea759d8e` pass-1 fixes, `92ae2cf3` pass-2 fixes.
  This record is a later documentation-only commit.
- Passes: 3 of 3. Pass 1 covered the whole diff; passes 2 and 3 covered
  `73c0d11e..ea759d8e` and `ea759d8e..92ae2cf3` plus every open finding.
- State: **clean**. 0 active P0–P2 findings.

## Risk: medium

The new Create a Route flow is iPhone-only and stores routes in the existing
archive format. There is no schema, BLE, firmware or server change. The shared
`NavigationRuntimeV1` projection choice changes for iPhone online/offline and
Watch navigation, but only where a route passes the same place more than once:
a ride starting at a loop's own start and finish, or a candidate lying on a
pass behind the current step. Recovering from a bad runtime release needs an
app update.

## Findings

| ID | Severity | Status | Summary |
| --- | --- | --- | --- |
| MS-1 | P1 | fixed, verified | The Saved Routes footer copy is pinned by `NavigationProtocolMapTests`; the original copy was restored. |
| MS-2 | P2 | fixed, verified | Exposed by this change; GPX and Strava loops were also affected. A loop started at its own finish when the first fix was nearer the closing street, and progress froze after an out-and-back turnaround. |
| MS-3 | P2 | fixed, verified | Introduced in `ea759d8e`: the loop-start rule moved mid-route starts off the nearest pass. It now applies only at the route start. |
| MS-4 | P3 | open, non-blocking | After `.checkpoint` recovery behind the checkpoint step, progress can trail the rider by up to the ambiguity band per fix. |
| MS-5 | P3 | open, non-blocking | On hairpins narrower than the band, a fix more than 20 m back after the apex can move onto the far side early. The original runtime froze on these hairpins. |
| MS-6 | P3 | open, non-blocking | A rider who turns back before entering a stop's 20 m arrival band, or a stop whose arrival ends at a join longer than 20 m, keeps the original pinned guidance. |

Pass-1 P3 notes fixed in `ea759d8e`:
- Leg cache keyed by locale.
- Joins limited to 100 m.
- Try Again shown only for leg failures.
- Stop-limit footer.
- Policy wording.
- Resolver tests.

Pass-1 P3 notes left unchanged as non-blocking, with reasons:
- "Current Location" stays in default names and labels, as in the previous flow, and can be renamed in the save sheet.
- Picks are added to the shared Recent Searches, as in the previous flow.
- The joined draft is encoded on the main thread.
- The start location has no freshness check, as in the existing planner.

**Separate pre-existing defect.** Favorites starred from Saved Routes rows store
WGS-84 archive destinations, but every planner treats favorites as MapKit
(GCJ-02) coordinates, so in mainland China those stops are offset by a few
hundred metres. This needs its own change: branch
`fix/saved-route-favorite-coordinates`.

## Base sync

On 2026-11-06 `main` at `1fa19116` was merged into the branch without
conflicts, and then `268409ea`, which adds the saved-route favorite fix.
`main` brings PR 755's precise mainland-China region and its two-reading
rule beside the border. In the strip up to about 1.2 km deep
beside the border, an Apple Maps coordinate also reads as a shifted mainland
position. The mainland reading wins unless a reference, such as the rider's
GPS fix, lies at the other one.

| ID | Severity | Status | Summary |
| --- | --- | --- | --- |
| SYNC-1 | P2 | fixed after the review passes; verified by test | Exposed by the sync. A "Current Location" stop kept only its Apple Maps coordinate, and each leg's start was converted back without a reference. A multi-stop route started by a rider in Hong Kong's or Macau's strip beside the border was therefore read as shifted mainland until it left the strip, about 600 m off near Shenzhen. Direct planning on `main` already passes the rider's fix. The stop now keeps its GPS fix, and legs start from `wgs84Coordinate`, read near that fix. `multiStopCurrentLocationBesideBorder` passes and fails on the old reference. |

All 3 review passes had been used, so SYNC-1's fix had no further review pass.
It is limited to a current-location stop. Searched and saved stops in the
strip still take the mainland reading, as a searched start does in direct
planning.

## Checks

The receipt-signing key was blanked for every run, so no local result was
published to `ci/local-test-results`.

- `tools/dev-check --level full` on clean `92ae2cf3`: 19 passed, source unchanged.
  - Swift navigation (map, sensors, workout, radio).
  - Shared route and Watch BLE contracts.
  - Watch source graph type-check.
  - Watch offline and online navigation.
  - Ride diagnostics and workout contracts.
  - Development runner and CI policy.
  - iOS and Watch simulator contracts.
  - Debug/Release iOS containers.
  - Diagnostics and social contracts.
- `tools/dev-check` on clean `ea759d8e`: 17 passed.
- On clean `73c0d11e`, `ios-navigation-map` failed on the footer pin (MS-1). The other 16 checks passed.
- Unsigned Debug iOS app build on each committed change: succeeded, with no warnings in the touched files.
- `RideSharedTests` built three times, swapping only `NavigationRuntime.swift`:
  - This head passes.
  - `ea759d8e` fails the out-and-back turnaround 15 m short.
  - `f37a084f` fails the loop start.

## Not verified

- No manual or UI-automation pass of the creator on a simulator or device.
- No live MapKit directions or search. Tests use injected directions and search.
- No physical ride of a loop, an out-and-back or a multi-stop route.
- No mainland-China device check.

## Recovery

Revert the three commits and ship an app update. Saved multi-stop routes are
ordinary phone-only Apple Maps archives and stay valid after a revert.
Reverting the runtime brings back the loop-start and out-and-back limitations
above. There is no migration, server state or device firmware to roll back.
