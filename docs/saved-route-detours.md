# Saved-route bicycle detours

While a rider follows a saved route (imported GPX, a direct Strava API import,
or a saved Apple Maps / Create a Route archive) and reliably leaves it, Bicino
calculates a temporary bicycle detour from the rider's position to one rejoin
point on the original route. The original route stays visible and keeps its
identity; the detour is discarded when the rider has a confirmed rejoin, and
original guidance resumes from there.

## Routing policy

1. **Apple MapKit cycling first.** A plain cycling request, never the car
   fallback (`CyclingFallbackDirectionsTask`/`carRequest`).
2. **Valhalla bicycle only when MapKit has no cycling route for that request.**
   The trigger is the actual MapKit result (`MKDirectionsErrorCode` 8
   out-of-coverage, 16 not reachable, or `directionsNotFound`), never a country
   list. Apple currently omits the United Arab Emirates from Maps: Cycling, and
   live MapKit cycling requests in Dubai return code 8.
3. **Never driving directions** for a saved-route detour. The server forces
   Valhalla's `bicycle` costing (`bicycle_type` `hybrid`; Valhalla 3.9.2
   lowercases the type and treats unknown values as hybrid) and refuses any
   maneuver whose `travel_mode` is not `bicycle`. Create a Route's bicycle legs
   use the same service with rider-chosen profiles; see
   [Bicycle routes](bicycle-routes.md).
4. Offline, or no bicycle route from either provider: the original route and
   the off-route status stay on screen.

Each Valhalla request carries exactly two coordinates: the rider's current
position and one selected rejoin point. The saved route's provenance (`gpx`,
`strava`, `mapkit`) travels as a tag; its geometry does not.

## Endpoint

`POST /v1/bicycle-detours?clientInstallationId=…` with `X-Installation-Token`.

```json
{
  "schema": "bicino-bicycle-detour-request-v1",
  "requestId": "<lowercase uuid>",
  "origin": {"latitudeE6": 25206600, "longitudeE6": 55269200, "courseDegrees": 182.5},
  "rejoin": {"latitudeE6": 25225800, "longitudeE6": 55263100},
  "routeSource": "gpx",
  "locale": "en-AE"
}
```

- `ready`: `route.provider` (`bicino.valhalla`, "© OpenStreetMap
  contributors"), `distanceMeters`, `durationSeconds`, `pointsE6`
  (`[latitudeE6, longitudeE6]`, travel order) and `maneuvers` (Valhalla `type`,
  `instruction`, contiguous `beginShapeIndex`/`endShapeIndex`, length, time,
  bearings). The app converts them into a `.activeOnly` `NavigationRouteV1`
  whose last step is "Rejoin saved route", never an arrival.
- `unavailable` with `reason`: `no_bicycle_route` (Valhalla 170/171/442/443,
  which includes points outside the loaded graph), `request_too_long` (154),
  `service_disabled` (no upstream configured).
- `400 bicycle_detour_invalid_request`, `429` (per-IP and per-installation
  hourly/daily limits), `503 bicycle_detour_busy|bicycle_detour_unavailable`
  with `Retry-After`.
- `Cache-Control: private, no-store`. Coordinates and routes are neither
  stored nor logged; logs carry outcome codes only. The upstream address never
  appears in a response.

Configuration (`MAP_PLATFORM_*`): `BICYCLE_ROUTING_UPSTREAM_URL` (internal
Valhalla origin shared with [bicycle routes](bicycle-routes.md); unset disables
both endpoints), `BICYCLE_ROUTING_TIMEOUT_SECONDS`
(8), `BICYCLE_DETOUR_MAX_CONCURRENT` (4), `BICYCLE_DETOUR_MAX_SEPARATION_METERS`
(15000), `BICYCLE_DETOUR_REQUIRE_APP_ATTEST` (true in the code and in the
development lock; acceptance uses a normally enrolled Bicino Dev installation),
`BICYCLE_DETOUR_IP_LIMIT_PER_HOUR` (120), `BICYCLE_DETOUR_LIMIT_PER_HOUR` (60),
`BICYCLE_DETOUR_LIMIT_PER_DAY` (300).

## First coverage: all seven emirates (GCC States graph)

The first coverage and development acceptance target is the whole United Arab
Emirates. Argentina/Buenos Aires is a later coverage check.

### Source (reused from the map platform source cache)

| Item | Value |
| --- | --- |
| Cache entry | `geofabrik-gcc-states` in the development stack's `source-cache.json` |
| Cached path | `/data/source-pbf/geofabrik/gcc-states-latest.osm.pbf` (development map-platform volume, read only) |
| Resolved snapshot | Geofabrik `gcc-states-261117.osm.pbf` |
| Size | 257,776,007 bytes |
| SHA-256 | `267054333e0efabb1219015f369e82621147ce34fd6909082d0420f8ffccf759` (the copied file matched the cache record) |

The extract covers Bahrain, Kuwait, Oman, Qatar, Saudi Arabia and the UAE, so
the graph includes connected roads across the UAE's borders with Oman and
Saudi Arabia.

### Graph (uncut GCC, no optional elevation)

| Item | Value |
| --- | --- |
| Valhalla | 3.9.2, `ghcr.io/valhalla/valhalla-scripted@sha256:b523b803483d1b0e5f3cd506e8b55b010d0477e614a152c1f833c4451ede8228` (index with `linux/amd64` and `linux/arm64`) |
| Builder | local OrbStack (ARM64), 2026-11-21 |
| Archive | `valhalla_tiles.tar`, **828,477,440 bytes** (828.5 decimal MB), 3,497 tiles |
| Archive SHA-256 | `a1911ad2d013f43bc1595a9fdd40e7caa4b88075db4b86f4ddfc8f0b3150bfff` |
| Build scratch | sampled peak of the graph directory 3,467,624 KiB (about 3.55 GB); the finished graph directory was 1.2 GiB |

Local 3.9.3 ARM64 Argentina builds crashed at graph enhancement while 3.9.2
succeeded; that is a local observation, not evidence of a general regression.
Keep the 3.9.2 digest until another version passes a clean build and the same
route probes.

### Archive-only bicycle probes (networking disabled)

| Emirate | Distance | Maneuvers | Modes |
| --- | --- | --- | --- |
| Abu Dhabi | 2.035 km | 9 | bicycle |
| Dubai | 3.194 km | 13 | bicycle |
| Sharjah | 2.949 km | 12 | bicycle |
| Ajman | 2.356 km | 10 | bicycle |
| Umm Al Quwain | 2.063 km | 9 | bicycle |
| Ras Al Khaimah | 5.233 km | 18 | bicycle |
| Fujairah | 2.156 km | 14 | bicycle |

The first Abu Dhabi pair did not connect ("Reverse search exhausted"); an
urban alternate passed. Recorded responses used by the backend tests are in
`map-platform/backend/tests/fixtures/bicycle_detour/`: the Dubai route above,
Valhalla 442 (no path, a point at sea) and 171 (Buenos Aires, outside the
graph).

## Development deployment (Coolify host, development only)

- **Graph staging:** `/var/lib/bicino-valhalla-development/graphs/<archive
  SHA-256>/valhalla_tiles.tar`, mode 0444, verified against the SHA-256 above.
  It lives outside every map-platform data volume.
- **Service:** `bicino-valhalla-dev-acceptance`, a temporary Docker-run
  sidecar on the development stack network (`msvncw7r45jfrz8dbvh0yp7p`), not
  yet Coolify managed: pinned 3.9.2 digest, read-only root filesystem, 2 GiB
  memory limit, no published ports, graph directory mounted read only at
  `/custom_files`, labels `io.bicino.channel=development` and
  `io.bicino.graph-sha256=<archive SHA-256>`. It generates its config at start
  (`valhalla_build_config --mjolnir-tile-extract /custom_files/valhalla_tiles.tar`)
  and serves archive-only with `valhalla_service … 2`. From the development API
  container `GET /status` reports 3.9.2 and `POST /route` returns the Dubai
  bicycle route.
- **API wiring:** `compose.development.yaml` defaults
  `MAP_PLATFORM_BICYCLE_ROUTING_UPSTREAM_URL` to
  `http://bicino-valhalla-dev-acceptance:8002`.

### Rebuilding or replacing the graph

1. Resolve the source from the map platform cache, not a fresh download: read
   the `geofabrik-gcc-states` entry in `source-cache.json`, confirm its
   resolved snapshot name and SHA-256, and copy the PBF to the builder,
   verifying the hash. If the entry is cold, let the map platform's
   `SourceCache` fetch it once (it records the URL, validators and SHA-256).
2. Feed the builder only that read-only PBF (or its verified copy). Keep graph
   output and build scratch on a separate path, never on the map-platform data
   volume.
3. Build with the pinned 3.9.2 image, without optional elevation, and record
   the source snapshot, source SHA-256, image digest, archive bytes, tile count,
   archive SHA-256 and peak scratch.
4. Run archive-only bicycle probes with networking disabled in every emirate
   before serving the archive.
5. Stage the archive under a new `graphs/<archive SHA-256>/` directory and
   restart the sidecar on it; never overwrite a served archive in place.

Production provisioning, image promotion, a Coolify-managed Valhalla service
for production, and any production lock change are outside this development
deployment.

## Bicino One display

- **Compatible mode (every firmware today, every Watch-owned ride):** during
  the detour the route window on `2A6F` follows the detour and the maneuver
  text guides it; the saved route is not drawn on the device until rejoin,
  when its window returns. Offline or with no bicycle route, the device keeps
  the saved route's window and the phone shows "Off route — return to saved
  route".
- **Two-line mode (CAP2 extended bit 7, client 37; development firmware
  profiles until a physical board check):** the detour stays the anchored
  guidance line and the iPhone also sends the saved route around the detour
  (`RTK1`, from 150 m behind the leave point to 300 m past the rejoin point,
  at most 48 points), drawn as a muted line underneath. It is cleared at
  rejoin, when navigation stops and when the BLE session ends. See
  [Route reference track](ble-protocol.md#route-reference-track-rtk1).

## Privacy

When a rider leaves a saved route, Bicino first asks Apple's MapKit for a
cycling route back. Only if MapKit has none does the app send the rider's
current location and one selected point on the saved route to the Bicino
service with the installation credential. The service computes a bicycle
route on Bicino's own Valhalla server and neither stores nor logs the
coordinates. On a Watch-owned ride with online routing enabled, the Watch
passes the same two points to the reachable paired iPhone, which sends them
with the iPhone's credential. The detour exists only for the active ride and
is discarded at rejoin or when navigation stops.
