# Issue #98: Elevation profile and climb progress implementation plan

- Issue: [#98 — Add an elevation profile and climb progress screen](https://github.com/seichris/open-bike-computer/issues/98)
- Planning branch: plan/issue-98-elevation-profile
- Baseline: origin/main at 951a51089197c4ef58374c452d320c73fb3a7f03
- Status: plan only; this branch intentionally contains no implementation or pull request

## Outcome

During navigation, the device shows the planned elevation profile for the whole route, a clear current-position marker, and current/upcoming climb information represented by the attached design. The iPhone remains responsible for route matching, profile generation or retrieval, live sensor fusion, and BLE transport. The ESP32 receives a compact, already-processed profile and renders it deterministically.

The first release must remain useful when elevation is unavailable: normal turn-by-turn navigation, map rendering, GPS, and route telemetry continue; the profile screen degrades to an explicit “Elevation unavailable” state instead of inventing a profile from noisy GPS altitude.

## Issue acceptance contract

The implementation is complete only when all of the issue’s acceptance criteria hold:

1. During navigation, the profile and climb statistics update from live route progress.
2. The current position and remaining portion of the climb are legible while riding.
3. Missing or incomplete elevation data never disrupts ordinary navigation.
4. The screen is reachable through the existing device-screen controls.

The implementation must also preserve the existing route geometry, maneuver, map-transfer, device-ownership, and workout telemetry contracts for older app/firmware combinations.

## Current repository boundaries

This plan is based on the actual origin/main layout, not on an assumed greenfield service.

### iPhone navigation

- ios-app/BikeComputer/BikeComputer/Managers/BikeComputerCoordinator.swift obtains MKRoute, starts navigation, and replaces a route after rerouting.
- ios-app/BikeComputer/BikeComputer/Managers/NavigationEngine.swift owns the active route, location acceptance, route remaining distance, simulation, route progress helpers, route geometry extraction, and GPS telemetry sends.
- The current device geometry is a sliding window of latitude/longitude points (extractSlidingWindowGeometry) sent through characteristic 2A6F; it is not a complete route/profile dataset.
- DeviceGPSPacketBuilder in ios-app/BikeComputer/BikeComputer/Utilities/NavigationProtocol.swift currently sends latitude, longitude, heading, speed, current altitude, ride distance/time, and route remaining distance. It does not send progressM.
- Existing route-deviation and step-selection helpers are useful starting points, but they are not sufficient for loop/crossing-safe along-route projection.

### BLE and ESP32

- The documented navigation service is in docs/ble-protocol.md and esp32/lib/ble_navigation/.
- Existing characteristics are navigation text/control (2A6E), route geometry (2A6F), GPS position (2A72), and map settings (2A73), with authenticated fallback/control framing over 2A6E.
- esp32/lib/route_overlay/route_overlay.hpp/.cpp currently stores route coordinates only. It must not be made responsible for DEM sampling or route matching.
- Existing chunk/transfer patterns in esp32/lib/ble_navigation/map_transfer_status_chunk_session.hpp, destination_picker_protocol.hpp, map_profile_persistence.hpp, and the authenticated command path should be reused where appropriate.

### Online map platform and Geofabrik extraction

- The online map service is under map-platform/backend/map_platform/ with versioned endpoints such as /v1/map-jobs, /v1/map-packs, and /v1/source-regions.
- map-platform/backend/map_platform/geofabrik_sources.py discovers Geofabrik OSM vector extracts. pipeline.py stages PBF input and packages FMB/FMP map artifacts.
- tools/OSM_Extract/ converts OSM vector features for map rendering. Its configuration and pbf_to_geojson.sh do not provide a numeric terrain grid.
- Geofabrik’s normal .osm.pbf is therefore not an elevation source. OSM ele=* tags are sparse feature metadata, not a continuous route DEM. Elevation must be a separate, versioned artifact/service; do not add a fake DEM layer to FMB/FMP map blocks.

## Decisions

### Elevation source

1. Canonical global source: self-hosted Copernicus GLO-30 raw raster data, stored as source GeoTIFF/COG or an equivalent lossless internal form. Copernicus GLO-30 is a 30 m global digital surface model (DSM), not a bare-earth DTM; vegetation, buildings, and infrastructure can affect a sample.
2. Regional override: allow a source-priority registry for open, higher-resolution regional DTMs/LiDAR-derived models when licensing, coverage, vertical datum, and update policy are explicit.
3. Fallback: SRTM v3 where GLO-30 or a regional model is missing. Record the fallback and any overlap calibration in quality metadata.
4. Not canonical: Google/Open-Meteo/Mapbox/OpenTopoData point APIs, contour lines, hillshade, rendered topographic tiles, or raw GPS altitude differences. A self-hosted point service may bootstrap development, but production profiles must be sampled from our versioned raster cache so they can be persisted and downloaded.
5. Attribution and licensing: ship the required Copernicus, SRTM, OSM, Geofabrik, and any regional-DTM notices in the app/data-source documentation. Treat route-provider export and display permissions as a Phase 0 gate before sending proprietary route geometry to a backend or ESP32.

### Processing ownership

- Backend online path: canonical raster acquisition, route densification, sampling, corrections, smoothing, grade, climbs, cache, and profile endpoint.
- iPhone offline path: the same algorithm against a downloaded DEM/profile package, route map matching, progressM, live altitude/grade fusion, package cache, and BLE transfer.
- ESP32: profile storage, CRC/revision validation, interpolation at progressM, graph/marker/climb rendering, and graceful fallback. It never downloads or indexes raw DEM tiles, matches GPS to a route, or recomputes the full processing pipeline.

### Route provider boundary

MapKit remains the current online routing/instruction provider while the route-export terms are investigated. A production backend request must use a route representation that we are permitted to persist, process, and display on the device. If MapKit geometry cannot satisfy that requirement, use an OSM-based router, imported GPX, or another export-permitted source for the profile package rather than silently building a durable proprietary route mirror.

### Sampling and quality defaults

- Fixed profile spacing: 25 m of cumulative route distance, including a sample at distance zero and a final sample at route end.
- Bilinear interpolation over the four surrounding raster cells.
- Small no-data gaps (target default: 100–200 m) may be interpolated and flagged; larger gaps use the fallback source or make the affected section unknown.
- Bridge, tunnel, and ferry corrections use route-edge metadata where available. A DSM sample below a bridge or above a tunnel must not be presented as road-deck elevation.
- Planned profile altitude is separate from recorded ride altitude. The graph marker follows the planned profile; live altitude and live grade are separate fields.
- Algorithm and dataset versions are part of every profile identity. A filtering change invalidates the relevant cache entries instead of changing old profiles in place.

## Target architecture

~~~mermaid
flowchart LR
    ROUTE["Permitted route geometry + edge metadata"] --> DEM["Regional DTM → Copernicus GLO-30 DSM → SRTM fallback"]
    DEM --> PROFILE["25 m sampling → corrections → smoothing → grade → climbs"]
    ROUTE --> PROFILE
    PROFILE --> CACHE["Versioned backend/profile cache"]
    CACHE --> PHONE["iPhone route package + map matching"]
    PHONE -->|"profile revision + chunks"| DEVICE["ESP32 pending slot"]
    PHONE -->|"progressM + live sensors, 1–2 Hz"| DEVICE
    DEVICE --> SCREEN["Profile, marker, climb and graceful fallback"]
    PHONE --> OFFLINE["Offline DEM/profile package"]
    OFFLINE --> PHONE
~~~

The route geometry, navigation instructions, profile, and live ride state share a routeToken + revision identity. A reroute creates a new revision and never mutates the active profile in place.

## Versioned data model

Define the shared schema before backend, Swift, and firmware implementation. JSON is useful for debug fixtures/API responses; the BLE payload is explicit little-endian binary and never a copied/padded native struct.

### RoutePlan

~~~text
routeId                 stable app/backend identifier when available
routeToken              compact non-zero 32-bit BLE-session token
routeProvider           mapkit | osm-router | gpx | other permitted provider
canonicalGeometry       normalized full route polyline used for profile hashing
edgeMetadata            bridge/tunnel/ferry/layer flags when available
totalDistanceM
~~~

### RouteRevision

~~~text
routeToken              same route identity for a BLE session
revision                monotonically increasing, non-zero u16
geometryHash
profileHash
createdAt
status                  preparing | active | stale | unavailable
~~~

### ElevationProfile

Required metadata:

~~~text
routeToken
revision
routeProvider
demSource               regional-dtm | copernicus-glo30 | srtm-v3 | mixed
demRelease              immutable source release/checksum
verticalDatum           e.g. EGM2008 or EGM96; never implicit
sampleSpacingM          normally 25
algorithmVersion/id
totalDistanceM
sampleCount
minElevationM
maxElevationM
totalAscentM
totalDescentM
climbCount
qualityFlags
payloadBytes
payloadCRC32
~~~

Each sample is, in V1, a signed elevation in metres plus a precomputed quantized grade:

~~~text
i16 elevationM
i8  gradeQ4              // 0.25 percentage-point units
~~~

The implementation must validate the representable elevation range before encoding. If launch routes require an offset encoding, add an explicit elevationBaseM field in a new profile version rather than silently wrapping an i16.

Each Climb is 16 bytes in the V1 binary payload:

~~~text
u32 startDistanceM
u32 endDistanceM
u16 elevationGainM
i16 averageGradeCentiPercent
i16 maximumGradeCentiPercent
u16 flagsOrCategory
~~~

Quality flags distinguish measured source, interpolated no-data, fallback source, bridge/tunnel correction, low-confidence match, and unavailable sections. They are visible in diagnostics and may drive UI styling, but a low-quality profile still cannot claim more precision than it has.

## Elevation processing specification

The backend and iPhone implementations may use different languages, but must produce equivalent results for the same versioned fixtures.

### 1. Route normalization and densification

1. Normalize coordinates and antimeridian handling in a documented geographic CRS.
2. Preserve cumulative distance along the full route, not only the current 2A6F sliding window.
3. Densify/interpolate the route as needed, then emit target distances 0, 25, 50, …, totalDistanceM.
4. Retain route-edge attributes through densification so bridge/tunnel/ferry corrections map to sample intervals.
5. Hash canonical geometry, provider/version, DEM release, processing algorithm, and spacing for cache identity.

### 2. Raster sampling and source fallback

1. Resolve the source-priority region for the route corridor.
2. Read intersecting raster windows in batches; do not issue one network request per point.
3. Bilinearly sample valid cells.
4. Interpolate only bounded no-data gaps. If a gap exceeds the configured limit, try the next source and record a source transition.
5. When sources overlap, calculate and persist a bounded offset calibration before blending; never create a false step at a source boundary.
6. Keep source release, vertical datum, quality mask, and checksum in the profile metadata.

### 3. Bridge, tunnel, and surface corrections

- Bridge: when route-edge metadata identifies a bridge and portal/approach elevations are available, interpolate the road deck across the span and flag corrected samples.
- Tunnel: interpolate between tunnel portals rather than sampling the terrain above the tunnel; flag corrected samples and preserve portal quality.
- Ferry: use a documented water-surface policy or mark the interval unavailable; never infer a climb from the terrain under water.
- Missing metadata: leave the raster value with a DSM/quality warning rather than guessing from nearby OSM tags.

The first implementation must make the source of edge metadata explicit. MapKit’s route steps do not necessarily expose OSM tags; this is a design gate for any correction claimed as production quality.

### 4. Filtering, grade, ascent, and descent

1. Remove isolated spikes with a three-sample median or Hampel filter.
2. Apply a centered Savitzky–Golay filter, polynomial order 2, five samples by default (approximately 100 m). Use seven samples for explicitly low-quality/forested data only if fixtures show the policy is stable.
3. Compute planned grade from a local linear regression over approximately 100 m (about 50 m behind and ahead), not from adjacent 25 m differences. Also expose a forward-looking regression for the next 100 m.
4. Calculate planned ascent/descent from smoothed elevations with a 3–5 m vertical deadband (default 4 m), reversal confirmation, and a minimum horizontal run. Never sum every positive sample delta.
5. Keep planned ascent/descent separate from recorded ascent/descent generated from barometric ride data.

### 5. Climb detection

Initial road defaults:

~~~text
minimum length          500 m
minimum gain            25 m
minimum average grade   3%
merge downhill gaps     up to 100–150 m or approximately 10 m loss
~~~

Each climb stores start/end distance, gain, average grade, maximum smoothed grade, and category/quality flags. MTB/gravel thresholds are a later profile policy, not hidden constants in the ESP32.

## Backend work

Add a dedicated elevation/profile module under map-platform/backend/map_platform/; keep it separate from the FMB/FMP renderer pipeline.

### Source acquisition and storage

- Add a pinned source manifest/registry for GLO-30 releases, regional DTM overrides, and SRTM v3 fallback.
- Store source raster tiles and quality masks in object storage or a durable configured data root, with checksums and release metadata.
- Add cache locking and bounded working windows consistent with existing SourceCache/artifact-store patterns.
- Do not make the Geofabrik index or OSM PBF download responsible for fetching elevation.

### Profile service/API

Add a dedicated versioned endpoint in the existing FastAPI app, using the project’s /v1/... naming and request-limit/auth conventions. A proposed shape is:

~~~text
POST /v1/elevation-profiles
GET  /v1/elevation-profiles/{profile_id}
GET  /v1/elevation-profiles/{profile_id}/download
~~~

The create request must include a permitted canonical route representation, route identity/revision, requested processing policy, and client request id. The response exposes profile metadata, quality, cache identity, and a compact binary download URL; it must not expose provider-prohibited raw route data or unbounded raster data.

The endpoint must:

- validate route size, coordinate bounds, spacing, and revision;
- return a deterministic cache hit for the same canonical key;
- report ready, processing, unavailable, and failed without blocking navigation;
- include source/datum/algorithm/quality metadata;
- use authenticated installation/download credentials where required; and
- enforce request/body/rate limits independently from map-job limits.

### Backend tests and observability

Add deterministic fixtures and tests under map-platform/backend/tests/ for:

- flat route;
- long alpine climb;
- rolling hills;
- bridge over a valley;
- tunnel through a mountain;
- forest/DSM anomaly;
- no-data and source fallback;
- loop/crossing geometry;
- mid-route reroute and revision invalidation; and
- missing profile/error response.

Record profile generation time, source selection, fallback distance, corrected-sample count, quality flags, min/max, ascent/descent, and suspicious spike counts. Do not log raw user route geometry unless the existing privacy contract explicitly permits it.

## iPhone work

### ElevationProfileService

Create an actor/service responsible for:

- online profile request, authentication, retries, and cache lookup;
- profile binary/metadata validation before BLE transfer;
- profile-only route-package persistence;
- local DEM package lookup and the same processing algorithm for offline mode;
- backend/Swift fixture comparison in host tests; and
- cancellation when a route is replaced or navigation stops.

Integrate it at route start and replacement in BikeComputerCoordinator/NavigationEngine. A profile request must not block route display or maneuver guidance. If it cannot finish, navigation remains active and the profile state becomes unavailable/stale.

### Along-route progress (progressM)

Implement a route matcher that:

1. searches near the previous segment index rather than the entire route on every GPS fix;
2. projects the location onto nearby segments in a local metric coordinate system;
3. uses heading, horizontal accuracy, and distance-to-segment confidence;
4. prefers monotonic progress with a bounded backtrack tolerance;
5. uses prior progress and heading to disambiguate loops/out-and-backs/crossings;
6. freezes/greys the marker while confidently off-route instead of snapping to a distant crossing; and
7. emits a confidence/quality flag alongside progressM.

Send progressM and the active route revision to the device at approximately 1–2 Hz. The existing GPS characteristic may retain its location payload for the map view; do not overload latitude/longitude or route remaining distance to mean profile progress.

### Live altitude and grade

- The profile marker uses plannedElevation(progressM) so it remains on the planned graph.
- Current CLLocation.altitude is a separate live field.
- When a barometer is available, combine relative barometric changes with a slowly corrected GPS absolute anchor, subject to accuracy checks.
- At low speed or low route-match confidence, hold/fallback to planned grade rather than deriving a large instantaneous grade from GPS altitude noise.
- Show planned and recorded ascent/descent as distinct metrics; never replace planned ascent with a ride-derived estimate.

### iOS UI and screen controls

Implement the profile graph in SwiftUI first so profile processing and marker behavior can be debugged before rendering on the small round device. Then add the device screen through the existing screen-control/capability mechanism.

The device screen should include:

- a compact full-route or forward-window graph;
- a rider marker based on progressM;
- the remaining portion of the active climb;
- distance to the next climb;
- current planned/live grade and live altitude;
- planned total ascent/descent where quality is sufficient; and
- explicit loading, stale, unavailable, and low-confidence states.

Do not make graph rendering depend on MapKit tiles or a network connection.

## ESP32 work

### Protocol V1

Document a new versioned profile protocol in docs/ble-protocol.md and implement it in dedicated esp32/lib/ble_navigation/ helpers. Reuse authenticated fallback framing and runtime MTU logic instead of assuming a fixed packet size.

Static profile header (44 bytes):

~~~text
u8  type                 PROFILE_BEGIN
u8  version              1
u16 flags
u32 routeToken
u16 revision
u16 spacingM
u32 totalDistanceM
u16 sampleCount
u16 climbCount
i16 minElevationM
i16 maxElevationM
u32 totalAscentM
u32 totalDescentM
u32 algorithmId
u32 payloadBytes
u32 payloadCRC32
~~~

Profile samples are i16 elevationM + i8 gradeQ4; climb records are 16 bytes as defined above. The frequent ride-state packet is exactly 20 bytes:

~~~text
u8  type                 RIDE_STATE
u8  flags
u16 revision
u32 routeToken
u32 progressM
i16 liveElevationM
i16 liveGradeCentiPercent
u16 sequence
u16 crc16
~~~

The exact characteristic UUID layout is a Phase 0 design decision. Prefer additive characteristics for control/bulk/status/live state if discovery and compatibility testing support them; otherwise carry the same framed protocol over authenticated 2A6E. Existing 2A6F route geometry and 2A72 GPS semantics must remain backward compatible.

### Transfer and persistence

Use:

~~~text
PROFILE_START  (write with response)
PROFILE_DATA   (bulk write without response)
PROFILE_COMMIT (write with response)
PROFILE_STATUS / ACK (notify or indicate)
~~~

Each data chunk includes a type, stream id, sequence, packet CRC16, and payload. The implementation must:

- derive payload capacity from the negotiated MTU and the iPhone’s maximumWriteValueLength(for:);
- obey canSendWriteWithoutResponse/ready callbacks;
- ACK every 16–32 chunks with the highest contiguous sequence plus a missing-packet bitmap;
- support resume from the last acknowledged sequence;
- validate payload length, sample/climb bounds, CRC32, route token, and revision;
- retain the old profile until the new one commits successfully;
- store pending and active profiles in separate slots with power-loss-safe commit markers; and
- ignore stale route/profile/ride-state revisions.

The first profile implementation may keep a 200 km profile in RAM/PSRAM only after measuring the actual target hardware. At 25 m, 200 km is 8,001 samples and approximately 24 KB for elevation plus quantized grade before headers/climbs; this is a budget to verify, not an assumed guarantee.

### Rendering and failure behavior

- Interpolate between profile samples using progressM / spacingM.
- Render the graph marker from planned profile elevation, not ESP32 GPS map matching.
- Compute distance to next climb and distance remaining in current climb from the climb table.
- Display live altitude/grade received from the phone separately.
- Keep ordinary navigation visible when no profile is active.
- On revision mismatch, show a grey/stale profile or “profile updating”; never continue advancing the old climb as if it described the new route.
- Add screen registration and capability negotiation through the existing device-screen protocol; older firmware simply ignores the new screen/profile messages.

## Reroute and atomic activation

The route/profile lifecycle is:

1. iPhone detects a reroute or receives a new route.
2. It increments revision immediately and marks the prior profile stale.
3. It requests/generates the new canonical route profile online or offline.
4. It transfers geometry, instructions, and profile into inactive device storage.
5. ESP32 validates each artifact and the shared token/revision.
6. ESP32 atomically activates the complete new route set.
7. iPhone sends subsequent live state with the new revision.

For V1, resend the complete profile on reroute. Differential/suffix profile updates are not worth the added failure modes at the expected profile size.

If profile generation fails while navigation succeeds, retain navigation and hide/grey only the profile surface. Do not advance stale climb metadata or substitute a raw GPS-derived planned profile.

## Offline packages

Keep these packages independent because their licenses, update cadence, and storage needs differ:

1. vector map package (existing FMB/FMP pipeline);
2. routing graph package (future offline routing); and
3. elevation package (raw/processed terrain data).

### Profile-only mode (first offline milestone)

For a preplanned route, store route geometry, instructions, processed profile, and climbs. A 200 km elevation+grade profile is roughly 24 KB, making this the lowest-risk offline feature. It cannot create a new offline route profile without a local DEM.

### Corridor mode

Download a clipped/retiled DEM corridor around a planned route (initial target 5–10 km each side), plus the matching routing/vector coverage. Do not ship complete 1° source tiles when a clipped package will do.

### Region mode

Use an app-specific indexed package of 256×256 or 512×512 blocks containing signed integer metres, a no-data mask, source/datum metadata, tile-scheme version, license notice, and checksums. Keep numeric geographic coordinates; these are terrain samples, not rendered Web Mercator tiles. The iPhone samples the package; the ESP32 still receives only a processed profile.

## Phased delivery and gates

### Phase 0 — source, legal, fixtures, and protocol foundation

- Confirm which route geometry may be persisted, sent to the backend, and displayed on the ESP32.
- Confirm Copernicus/SRTM/regional-DTM access, attribution, vertical-datum handling, release pinning, and cache policy.
- Define RoutePlan, RouteRevision, ElevationProfile, Climb, ElevationQuality, the processing algorithm version, and BLE V1.
- Decide whether to add profile characteristics or use authenticated 2A6E framing, with an explicit MTU/compatibility matrix.
- Create golden routes for flat, alpine, rolling, bridge, tunnel, forest, no-data/fallback, loop/crossing, and reroute cases.

Gate: legal/data-source decision recorded; binary schema has a version and test vectors; no implementation depends on an unpinned third-party elevation API.

### Phase 1 — online profile MVP and iPhone debug UI

- Add a development GLO-30 tile subset and profile sampler in the backend.
- Add /v1/elevation-profiles create/status/download flow and deterministic cache key.
- Implement 25 m bilinear sampling, basic no-data handling, median/Savitzky–Golay filtering, regression grade, deadband ascent/descent, and road climb detection.
- Add ElevationProfileService, route matching, progressM, profile cache, and a SwiftUI debug profile screen.
- Validate backend/Swift outputs against shared golden fixtures.

Gate: profiles are reproducible; online navigation still works when profile requests fail; marker/progress behavior passes loop/off-route tests; no BLE or firmware change is required to use the debug UI.

### Phase 2 — production online quality and device transport

- Replace point-by-point development sampling with batched raster-window reads and durable GLO-30/quality-mask storage.
- Add bridge/tunnel corrections where route metadata is permitted, SRTM fallback with overlap calibration, source/version metadata, and suspicious-profile diagnostics.
- Implement BLE static profile transfer, ACK/resume, CRC, dual-slot persistence, atomic route/profile activation, live ride-state, and the device profile/climb screen.
- Add barometer/GPS altitude fusion and reroute revision handling.

Gate: physical Waveshare validation proves profile transfer, reconnect/resume, power-loss behavior, revision rejection, screen readability, and ordinary-navigation fallback on the target firmware environments. Obtain the connected hardware choice before any device action.

### Phase 3 — offline profile generation

- Generate route-corridor and region DEM packages with checksums, source/version, datum, quality masks, and attribution.
- Add iPhone package download/storage management and local bilinear sampling.
- Run the same correction/smoothing/grade/climb algorithm locally and compare with backend fixtures.
- Add a local OSM routing graph/engine only when genuine offline rerouting is separately scoped and licensed.

Gate: an offline preplanned ride produces the same profile/progress behavior as online; package corruption/missing coverage falls back without disrupting navigation.

### Phase 4 — regional quality and tuning

- Add licensed open regional DTMs through the source-priority registry.
- Compare planned profiles with recorded barometric rides without rewriting planned metrics.
- Tune road/gravel/MTB climb thresholds and filtering policies using versioned fixtures.
- Add targeted corrections for known DEM anomalies and preserve quality provenance.

Gate: each source/algorithm change has a new version, reproducible fixtures, attribution, and a documented migration/cache invalidation story.

## Test plan

### Backend

- Unit-test coordinate normalization, cumulative distance, bilinear interpolation, no-data gaps, source blending, bridge/tunnel correction, filtering, regression grade, deadband totals, climb segmentation, cache keys, and binary serialization.
- API-test authentication, rate limits, idempotency, processing status, unavailable profiles, size limits, and download checksums.
- Golden fixture test: exact sample/grade/climb output for every Phase 0 route.

### Swift/iOS

- Test route projection on straight, curved, looped, crossing, out-and-back, stationary, low-accuracy, and off-route fixes.
- Test monotonic progress/backtrack tolerance and revision cancellation during reroute.
- Test profile binary validation and cache invalidation when dataset/algorithm changes.
- Test online failure, offline package absence, stale profile, and no-profile UI states.
- Compare Swift outputs against the shared golden fixtures within explicitly documented quantization tolerances.

### Firmware

- Host-test every header/sample/climb/ride-state parser and CRC failure path.
- Test out-of-order chunks, duplicate chunks, missing bitmap, resume, stale revision, interrupted commit, power-loss recovery, over-limit counts, and unsupported protocol version.
- Test interpolation at route start/end, active-climb boundaries, no-profile fallback, and marker/progress quantization.
- Run PlatformIO builds for supported target environments and perform physical validation only after confirming the connected board.

### End-to-end

- Start a route with a profile, advance progress, cross a climb boundary, disconnect/reconnect BLE, reroute mid-climb, and finish with an unavailable profile.
- Verify that map geometry, maneuver guidance, route remaining, GPS telemetry, workout telemetry, and the new screen do not starve one another on the BLE queue.

## Risks and open decisions

| Risk/decision | Required resolution |
| --- | --- |
| Copernicus GLO-30 is a DSM, not a road-surface DTM | Keep quality flags and bridge/tunnel corrections; add regional DTM overrides only with explicit provenance. |
| MapKit route export/persistence terms | Resolve before backend persistence/device display; use an export-permitted route provider if needed. |
| Geofabrik does not provide continuous elevation in normal PBF | Keep terrain acquisition separate from GeofabrikSourceProvider and tools/OSM_Extract. |
| DEM source/datum offsets | Record vertical datum and calibrate overlapping fallback points before blending. |
| BLE negotiated MTU varies | Size writes at runtime and use application-level ACK/CRC/resume. |
| Profile size and ESP32 memory | Measure RAM/PSRAM and persistence budgets on every supported hardware profile; do not assume 24 KB is free. |
| GPS loop/crossing ambiguity | Freeze/grey the marker on low-confidence matches; never snap to a distant segment. |
| Offline rerouting scope | Ship profile-only offline first; add routing graph/DEM corridor only as a separate milestone. |
| Old firmware/app compatibility | Additive versioned messages, capability gating, and unchanged legacy characteristic semantics. |
| Planned versus recorded ascent confusion | Label and store them separately throughout API, UI, BLE, and firmware. |

## Definition of done

- The issue acceptance criteria are demonstrated on a real route and in the missing-elevation fallback path.
- Backend and iPhone produce equivalent versioned profiles from the same fixtures.
- ESP32 accepts only validated, revision-matched profiles and keeps the prior profile until atomic commit.
- progressM is generated by the iPhone route matcher and is the sole profile-position input to the device.
- The profile screen is available through existing device screen controls and remains legible on the target hardware.
- Geofabrik/OSM remains the vector/routing source; Copernicus/regional DTM/SRTM remains the terrain source; no renderer map artifact pretends to contain raw elevation.
- Attribution, source releases, vertical datums, algorithm versions, quality flags, cache invalidation, and rollback behavior are documented.
- The implementation is separately reviewed and tested before a pull request or rollout is opened.

## References

- [Issue #98](https://github.com/seichris/open-bike-computer/issues/98)
- [Copernicus DEM collection](https://dataspace.copernicus.eu/explore-data/data-collections/copernicus-contributing-missions/collections-description/COP-DEM)
- [USGS SRTM 1 Arc-Second Global](https://www.usgs.gov/centers/eros/science/usgs-eros-archive-digital-elevation-shuttle-radar-topography-mission-srtm-1)
- [Geofabrik download server](https://download.geofabrik.de/)
- [Geofabrik contours and hillshading](https://www.geofabrik.de/maps/hillshade-contours.html)
- [Apple MKRoute](https://developer.apple.com/documentation/mapkit/mkroute)
- [Apple CLLocation.altitude](https://developer.apple.com/documentation/corelocation/cllocation/altitude)
- [Apple maximumWriteValueLength(for:)](https://developer.apple.com/documentation/corebluetooth/cbperipheral/maximumwritevaluelength%28for%3A%29)
- [OpenStreetMap ele key](https://wiki.openstreetmap.org/wiki/Key:ele)
