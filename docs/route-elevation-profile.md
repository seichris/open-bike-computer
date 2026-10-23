# Route elevation

One canonical, versioned elevation profile per route geometry drives both the
iPhone preview and the 1.75-inch Bicino Elevation screen. The device never
recomputes it. Navigation never waits for, or depends on, elevation: every
failure is an explicit state and guidance continues unchanged.

Related issue: seichris/open-bike-computer#98.

## Sources and precedence

The iPhone resolves a profile for a route in this order:

1. **Trusted GPX `<ele>` values.** Imported GPX and Strava routes keep their
   per-vertex heights (decimetres) in a phone-only sidecar. They become the
   profile on the phone, with no network request, when at least 80 % of
   vertices have values, the values are not zero-filled and at most 5 % are
   isolated spikes (more than 25 m against both neighbours within 100 m).
   Zero runs between real heights are treated as missing. Source `gpx`,
   qualification `user-supplied`.
2. **A profile cached with the saved archive.** A service profile is stored in
   the same sidecar so a saved route shows elevation offline.
3. **The managed service**, only when
   `RouteProviderPolicyV1.allowsRouteElevationService` admits the route's
   provider. Today that is imported GPX only. Apple Maps geometry is not sent
   (the privacy checklist forbids a MapKit export path without explicit approval
   under the current Apple terms, see
   `docs/reviews/mapkit-route-storage-2026-09-15.md`); those routes show
   "Elevation isn't available for this route source". Strava API routes stay on
   the phone and use only their own GPX heights. Changing either is a product
   policy decision.

The service tries providers in order and never mixes providers inside one
profile:

- **Geoapify Elevation API** (hosted terrain). Called only from the server with
  a server-side key; at most 1,000 locations per request; credits are
  `max(1, ceil(n / 100))` per request and reserved in a daily ledger before the
  call. Null results stay unknown. Geoapify does not publish a vertical datum
  for this API, so `verticalDatum` is `null`. The profile carries the required
  attribution (`Powered by Geoapify`, its data sources USGS 3DEP, NASA SRTM,
  USGS GMTED2010 and NOAA ETOPO1, and OpenStreetMap). Qualification is
  `pending-live-qualification` until a live key is tested.
- **Internal Copernicus DEM** (GLO-30, GLO-90 fallback, 2021 release; EGM2008,
  DSM, bilinear). Sampled only from tiles an operator staged with
  `map-topography stage`; requests never download. Disabled by
  default (`MAP_PLATFORM_ROUTE_ELEVATION_DEM_ENABLED=0`) and refused in the
  production channel while the pinned sources are not `productionApproved`
  (`dem-not-production-approved`).

The best coverage wins; a complete profile stops the chain.

## Canonical profile `bicino-route-elevation-profile-v1`

Reference implementation: `map-platform/backend/map_platform/route_elevation.py`.
The Swift port (`ios-app/BikeComputer/BikeComputer/Models/RouteElevationProcessing.swift`)
follows it step for step and both are checked against
`protocol/fixtures/route-elevation-v1/processing.json`
(regenerate with `python3 tools/generate_route_elevation_fixtures.py`, check with
`--check`).

- **Geometry.** WGS-84 integer microdegrees, `[lonE6, latE6]` pairs (GeoJSON
  axis order), 2–20,000 points, 1 m–1,000 km, segments at most 100 km. The
  iPhone sends route points exactly as navigated; mainland-China display
  conversion (GCJ-02) is never applied to elevation requests. Digest:
  SHA-256 of `bicino-route-geometry-v1\n`, the point count (u32 LE) and each
  latitude/longitude pair (i32 LE). Distances use the haversine formula with
  R = 6,371,008.8 m, the same as navigation.
- **Sampling.** Uniform 50 m spacing, widened in 10 m steps so there are at
  most 4,001 samples, always including the route end.
- **Processing order.** Range check (−500…9,000 m) → bridge/tunnel correction →
  linear fill of gaps up to 200 m → 3-point smoothing when spacing is at most
  75 m → 5 m extremes-based hysteresis for total and cumulative ascent/descent →
  least-squares grade over ±max(100 m, spacing) → quality. Values round half
  away from zero to 0.1 (coverage to 0.0001).
- **Quality.** `complete`, `partial` or `unavailable` (coverage under 10 %),
  with valid, estimated and unknown distance, the longest gap and reasons
  (`missing-elevation`, `estimated-elevation`, `ambiguous-structure`,
  `unresolved-structure`). Totals of a partial profile cover known stretches
  only and are shown as lower bounds.

Per-sample flags (append-only):

| Bit | Flag |
| --- | --- |
| 0 | raw value missing |
| 1 | interpolated gap |
| 2 | structure estimated |
| 3 | structure unresolved |
| 4 | structure ambiguous |
| 5 | bridge |
| 6 | tunnel |
| 7 | grade estimated |

## Bridges and tunnels

Terrain models describe the ground, not a deck or a tunnel. The service uses a
read-only OSM structure index built offline from an extract (no Overpass):

```sh
map-platform route-elevation-structures \
  --osm europe-latest.osm.pbf \
  --output /data/route-elevation-structures/europe.sqlite3 \
  --source-label geofabrik:europe
```

and points `MAP_PLATFORM_ROUTE_ELEVATION_STRUCTURE_INDEX_DIR` at the directory
(at most 64 indexes). A structure is used only when the route follows it in
distance (15 m) and heading (30°) from one endpoint to the other over at least
60 % of the way. Motorways are not cyclable. Overlapping structures on
different layers, and partial alignment, are **ambiguous**: raw heights are kept,
never corrected, and grade and completeness are withheld for that span. An
estimated span is interpolated between ground anchors at least 30 m outside the
structure (searched within 150 m), only when the implied grade is at most 15 %
and the span at most 15 km; otherwise it is **unresolved** and left unknown. OSM
`layer` only orders structures and is never a height. Without an index the
profile says so (`structureCorrection.status = "unavailable"`); it never
invents deck heights. The iPhone dashes estimated stretches and the device marks
them.

## Service API

`POST /v1/route-elevation-profiles?clientInstallationId=…` with
`X-Installation-Token`. App Attest enrollment is required unless
`MAP_PLATFORM_ROUTE_ELEVATION_REQUIRE_APP_ATTEST=0`. The body is at most 1 MiB:

```json
{
  "schema": "bicino-route-elevation-request-v1",
  "requestId": "lowercase-uuid",
  "geometry": {"crs": "EPSG:4326", "coordinatesE6": [[lonE6, latE6], ...], "digest": "sha256-hex"},
  "travelMode": "cycling",
  "routeSource": "gpx"
}
```

`routeSource` `mapkit` and `strava` are rejected server-side as well. The
answer has `Cache-Control: private, no-store`:

```json
{"schema": "bicino-route-elevation-response-v1", "status": "ready" | "unavailable",
 "profile": {...} | null, "attempts": [{"provider": "geoapify", "status": "complete", "coverage": 1.0}],
 "retryAfterSeconds": null}
```

`protocol/fixtures/route-elevation-v1/service-response-v1.json` is a ready
answer the Swift decoder is tested against. Errors: 400 invalid request,
401 credential refresh, 429 rate limited, 503 busy (with `Retry-After`).
Limits: 60 per IP per hour, 30 per installation per hour, 120 per installation
per day, at most two concurrent lookups, a 25 s deadline, and a Geoapify credit
budget per day (default 1,500) and per installation (default 200).

Privacy and retention: route coordinates exist only for the request. A ready
answer (distances and heights, no coordinates) is replayed from memory for up to
10 minutes for the same installation and geometry. The credit ledger stores an
HMAC pseudonym of the installation per provider and UTC day and expires it
within 48 hours; hourly maintenance also deletes expired rows. Logs carry only
provider failure codes. Credential-bearing provider URLs never reach exceptions
or logs. `/healthz` reports provider order, availability and whether a key is
configured, never the key.

## iPhone

- **Saved-route preview.** The saved-route card on the map shows the chart,
  total ascent/descent, highest/lowest point, quality notes and attribution.
- **Navigation.** The expanded ride sheet adds an Elevation section: chart with
  the rider's marker, elevation and grade at the current position (`~` marks
  estimated values), ascent still to climb (`≥` when the profile is partial),
  an off-route note and the device status.
- **States.** Loading; unavailable for this route source; needs a connection
  (offline); temporarily unavailable (with Try Again); lookups paused (quota,
  Retry-After honoured); no coverage; route too long; partial and estimated
  notes on a ready profile; and device status: sending, sent, couldn't send,
  or "This Bicino firmware doesn't show route elevation" for firmware without
  the capability. During navigation, offline, temporary and quota failures are
  retried automatically once their backoff has passed.
- **Storage.** `PlannedRoutes/route-elevation/<route-id>.json`, bound to the
  archive's route ID, revision and content hash, excluded from backup, protected
  until first unlock, at most 2 MiB, and pruned with deletion, replacement or
  expiry of the archive. It holds no coordinates. The archive format and hash
  are unchanged, so older iPhone and Watch builds read saved routes as before.
- **Device delivery.** `RouteElevationDeliveryPlannerV1` sends the profile to
  a capable device as described in
  [BLE protocol: route elevation profiles](ble-protocol.md#route-elevation-profiles-elv1-v1)
  and derives every on-device value from the same profile and along-route
  progress the phone shows.

## Bicino Elevation screen (1.75-inch)

A default-off screen after Ride Stats: the simplified profile with estimated
and structure-uncertain stretches marked, the progress marker, route elevation
and grade at the rider's position, total ascent and ascent still to climb, and
the source. It explains each state: connect the app, update the app, no route,
loading, and unavailable with the reason. It is compiled only into 1.75-inch
development (`FIRMWARE_DIAGNOSTICS=1`) builds until physically qualified;
production and 2.06-inch builds omit the screen and the capability.

## Configuration

API service only; the worker and maintenance never receive the Geoapify key.
Placeholders only — store the key in the deployment secret store:

| Variable | Default | Purpose |
| --- | --- | --- |
| `MAP_PLATFORM_GEOAPIFY_API_KEY` | unset | Hosted terrain provider key (secret) |
| `MAP_PLATFORM_GEOAPIFY_DAILY_CREDIT_BUDGET` | `1500` | Service-wide daily credits |
| `MAP_PLATFORM_ROUTE_ELEVATION_INSTALLATION_DAILY_CREDITS` | `200` | Credits per installation per day |
| `MAP_PLATFORM_GEOAPIFY_TIMEOUT_SECONDS` | `10` | Provider timeout |
| `MAP_PLATFORM_GEOAPIFY_REQUESTS_PER_SECOND` | `4` | Provider pacing |
| `MAP_PLATFORM_ROUTE_ELEVATION_ENABLED` | `1` | Endpoint answers `unavailable` when `0` |
| `MAP_PLATFORM_ROUTE_ELEVATION_PROVIDERS` | `geoapify,copernicus` | Provider order |
| `MAP_PLATFORM_ROUTE_ELEVATION_DEM_ENABLED` | `0` | Internal DEM fallback |
| `MAP_PLATFORM_ROUTE_ELEVATION_DEM_CACHE` | `<data>/topography-cache` | Staged DEM tiles |
| `MAP_PLATFORM_ROUTE_ELEVATION_STRUCTURE_INDEX_DIR` | unset | OSM structure indexes |
| `MAP_PLATFORM_ROUTE_ELEVATION_MAX_CONCURRENT` | `2` | Concurrent lookups |
| `MAP_PLATFORM_ROUTE_ELEVATION_DEADLINE_SECONDS` | `25` | Per-request deadline |
| `MAP_PLATFORM_ROUTE_ELEVATION_REQUIRE_APP_ATTEST` | `1` | Require App Attest enrollment |
| `MAP_PLATFORM_ROUTE_ELEVATION_IP_LIMIT_PER_HOUR` | `60` | Per-IP limit |
| `MAP_PLATFORM_ROUTE_ELEVATION_LIMIT_PER_HOUR` | `30` | Per-installation hourly limit |
| `MAP_PLATFORM_ROUTE_ELEVATION_LIMIT_PER_DAY` | `120` | Per-installation daily limit |

`map-platform/backend/docker-compose.yml` passes these to the local API. The
production and development locks (`map-platform/deploy/compose*.yaml`)
auto-deploy when they change, so their API-only passthrough belongs in the
reviewed promotion that ships an image containing this endpoint, together with
the secret.

## Remaining gates

- Live Geoapify qualification with a real key in the secret store (response
  shape, nulls, rate limits, attribution) and the deployed secret.
- Backend image promotion and the deploy-lock passthrough above.
- Production approval of the pinned Copernicus sources before enabling the DEM
  fallback in production, and staging of its tiles.
- Building and provisioning structure indexes for the served regions.
- Physical 1.75-inch qualification of transfer, reconnect, readability and
  power; the 2.06-inch layout is not implemented or qualified.
- A product decision before Apple Maps or Strava geometry may use the service.
- Per-climb segmentation and statistics from issue #98 are not part of v1.
