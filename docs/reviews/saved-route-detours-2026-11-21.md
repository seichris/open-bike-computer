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

- Two-line Bicino One rendering (`RTK1`, extended bit 7 / client 37) for the
  target firmware release: not implemented; every firmware runs compatible mode
  (detour line replaces the route line during the detour, original returns at
  rejoin).
- Enrolled Bicino Dev acceptance on a physical iPhone: blocked, the only iPhone
  (`Ultra`) was unavailable; App Attest cannot enrol in the simulator.
- Production Valhalla, production lock, promotion, flashing.

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

## Review ledger

Pass 1 of 3 (author). Findings fixed before commit:
- DET-1 (P2) pass tie-break compared neighbouring segments of one street as
  separate passes and pulled targets back up to ~65 m; fixed with per-pass
  minima and a separation rule; tests pin it.
- DET-2 (P2) relay failures mapped to "offline"; fixed to service error.

Active findings: see the final report for the state at handoff.
