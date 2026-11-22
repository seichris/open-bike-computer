# Saved-route detours and Strava elevation fallback — review record

Branch `claude/bicino-rerouting-plan-acacae` (app side), base `381e07c8`.
Backend split out and merged: #833 (`e30a5976`, endpoint) and #835
(`f8100d3b`, App Attest required on development). Risk: **high** (new
authenticated routing proxy, Watch → iPhone relay, navigation runtime change).

## Scope

- Strava elevation fallback: provider gate `strava`, live-archive check,
  revocation of cached/late answers (`RouteElevationService`), privacy wording.
- Shared detour core (`RideShared/SavedRouteDetour.swift`,
  `BicycleDetourProvider.swift`, `BicycleDetourServiceContract.swift`,
  `MapKitNavigationRouteAdapter.swift`, `WatchBicycleDetourRelayContract.swift`),
  `NavigationRuntimeV1.resume`.
- iPhone: `NavigationEngine` holds the saved route and guides the detour,
  `BikeComputerCoordinator` runs MapKit cycling → Valhalla, dashed detour overlay,
  notice; Bicino One gets the detour window and maneuvers (compatible mode).
- Watch: installed GPX/Strava rides with online routing keep their route
  (no destructive reroute); MapKit cycling on the Watch, Valhalla via the iPhone
  relay; Bicino One compatible mode through the existing Watch link.

## Not in this change

- Two-line Bicino One rendering (`RTK1`, extended bit 7 / client 37): in the
  stacked PR #838, development firmware only. With this change alone every
  firmware runs compatible mode (detour line replaces the route line during the
  detour, original returns at rejoin).
- Production Valhalla, production lock, promotion, flashing. This change has no
  `map-platform/` input, so merging it builds no map image. The production map
  service has no `/v1/bicycle-detours` yet (404 on 2026-11-22), so a production
  app build gets MapKit cycling detours only; where MapKit has none it shows
  "Bike detour unavailable right now: follow the saved route" with backoff.

## Evidence

- `ios-app/scripts/run-saved-route-detour-tests.sh`: planner, rejoin
  confirmation, engine, resume, provider chain, contract, Watch relay — passed.
- `ios-app/scripts/run-route-elevation-tests.sh`: Strava fallback cases — passed.
- `run-watch-online-navigation-tests.sh` and `run-watch-source-typecheck.sh` — passed.
- Live acceptance harness (`ios-app/tests/saved-route-detour-acceptance`)
  against a local backend + local Valhalla on the verified GCC archive: live
  MapKit cycling in Dubai returned `MKErrorDomain` 2 / `MKDirectionsErrorCode` 8,
  the Valhalla detour was used, rejoin confirmed, saved-route generation and
  content hash preserved (perpendicular leave and missed-turn scenarios).

- `run-navigation-tests.sh map` (NavigationProtocolTests, offline route
  save/navigation 405 checks, route elevation, saved-route detours, map and
  contour groups), `run-ride-shared-tests.sh`,
  `run-watch-offline-navigation-tests.sh`, `.github/scripts` routing tests (47)
  and `tools/development` tests (74) — passed on the merged head.
- Signed Debug device build (`LetItRide.BikeComputer.dev`, team `4H5PK8686H`,
  1.11 (33), built from `228b8731`, whose `ios-app/` tree is identical to the
  DEBUG hook commit `8cdc68d1`) — BUILD SUCCEEDED, `codesign --verify --deep
  --strict` OK.
- Enrolled on-device acceptance, 2026-11-22, iPhone `Ultra` (iPhone 16 Pro
  Max), that build installed with `devicectl`: normal in-app App Attest
  enrollment against the development stack, which requires App Attest for
  detours; no token minted. The Dubai acceptance GPX was replayed with
  `devicectl simulate location route` (2,185 m at 5 m/s, missed turn after
  about 930 m) — PASSED: `Off route` at 2,196 m remaining → MapKit cycling
  `MKErrorDomain` 2 / `MKDirectionsErrorCode` 8 → `maps-dev.8o.vc` 200 →
  `bicino.valhalla` detour (3 steps, 859 m, last step "Rejoin saved route") →
  guidance through both turns → rejoin confirmed at 1,058 m along, inside the
  window → `resumed generation=1 step=0 offRoute=false`, "Follow imported GPX
  route" with 2,067 m remaining. An earlier attempt stopped about 160 m before
  the rejoin because the replay script's 420 s wait was shorter than the 437 s
  trace (script fixed; not an app defect). The app code tested equals this
  branch's detour code; later commits are main merges and this record.
- Development deployment (#834 → `e1d89494`, Coolify queue 5482): API image
  `373328b9…`, `MAP_PLATFORM_BICYCLE_DETOUR_REQUIRE_APP_ATTEST=1`, upstream
  `http://bicino-valhalla-dev-acceptance:8002`; `/healthz` reports
  `bicycleDetour.enabled`; unauthenticated requests get 401; a service-level
  call inside the API container returned the Dubai bicycle route (3,194 m,
  13 maneuvers). Production containers unchanged.

## Review ledger

Pass 1 of 3 (author). Findings fixed before commit:
- DET-1 (P2) pass tie-break compared neighbouring segments of one street as
  separate passes and pulled targets back up to ~65 m; fixed with per-pass
  minima and a separation rule; tests pin it.
- DET-2 (P2) relay failures mapped to "offline"; fixed to service error.

Pass 2 of 3 (author, delta), 2026-11-22. Scope: `406b56aa..HEAD`, which is the
DEBUG acceptance hook and evidence logs (`8cdc68d1`), this record, and main merges
`57ac11fb`, `980089cf` and the merge of `1818d32f` (#839). Every
`DETOUR_EVIDENCE`/`DETOUR_ACCEPTANCE` statement is inside `#if DEBUG` and only
prints; the launch hook runs only with `--saved-route-acceptance-gpx=` and
rejects paths. #839 overlaps this branch only in `BikeComputerApp.swift` and
`ContentView.swift`, in separate hunks (workout recorder choice versus detour
wiring); the merge was clean. No new findings.

State: clean, 0 active findings (DET-1 and DET-2 fixed and verified by tests).
Not verified: Watch detours on a real Watch (host tests and the Watch type
check cover the Watch paths; REVIEW.md asks for behavioural helpers and
simulator tests, not a physical Watch). Recovery: revert the merge commit; the
app keeps no detour state on disk, and the Watch journal keeps the saved route,
not the detour.
