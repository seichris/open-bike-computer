# Map POI Visibility Settings Implementation Plan

## Outcome

Add offline OpenStreetMap points of interest to the bike-computer map and let
the rider show or hide five POI groups independently for **Map** and
**Map + Navigation**:

- shops;
- restaurants and cafes;
- public toilets;
- gas stations; and
- bicycle shops and repair stations.

Every new-format map contains all five groups. The settings affect rendering
only, so changing a toggle never requires regenerating a map. POIs are rendered
as compact category icons on the device; existing route, position-marker,
street-label, and building behavior remains authoritative.

This plan is associated with
[issue #338, Add map POI visibility settings](https://github.com/seichris/open-bike-computer/issues/338).
[AnyFinder](https://anyfinder.app/) is useful product inspiration for exposing
OSM POI categories, but this issue does not add POI search, details, editing, or
OpenStreetMap account integration.

## Baseline

This plan was prepared from freshly fetched `origin/main` at
`9ef7f09fce0e0d95e349e6ef9c54da137fcff286`.

Current `main` already provides most of the cross-device settings path:

1. `tools/OSM_Extract` extracts styled lines and multipolygons from a bounded
   Geofabrik PBF.
2. Renderer target 3 writes FMB v4 blocks containing base geometry, street
   labels, and OSM buildings, plus one FMA1 label font asset.
3. The backend validates, signs, catalogs, and streams target-3 map artifacts.
4. Firmware validates FMB v1-v4, caches decoded blocks in PSRAM, projects map
   geometry, and composes a background map canvas with a route foreground and
   a separate current-position marker.
5. The 32-bit Map and Map + Navigation visibility masks use bits 0-12. Setting
   IDs `8` and `20` already transport and persist those full masks.
6. The iPhone persists per-screen feature switches, negotiates CAP2
   capabilities, and resends both map profiles after connection.
7. New iPhone map requests currently require renderer target 3. Saved targets
   1 and 2 remain transferable to compatible older firmware.

The missing pieces are:

- the conversion step does not read OSM point features;
- there is no exact POI classification or block-ownership policy;
- FMB v4 has no bounded point-record section;
- the backend, firmware, and iPhone accept renderer formats only through 3;
- the renderer has no bounded icon-placement pass; and
- the capability and settings UI do not expose POI support.

## Product contract

### Categories and OSM semantics

The generator assigns every retained OSM object to at most one category.
Matching is case-normalized and based on active top-level tags, not lifecycle
tags such as `disused:shop` or `abandoned:amenity`.

| Category | Matching tags | Visibility bit |
| --- | --- | ---: |
| Shops | `shop=*`, excluding inactive placeholder values and `shop=bicycle` | 13 |
| Restaurants & Cafes | `amenity=restaurant`, `amenity=cafe`, `amenity=fast_food` | 14 |
| Public Toilets | `amenity=toilets` | 15 |
| Gas Stations | `amenity=fuel` | 16 |
| Bicycle Shops & Repair | `shop=bicycle`, `amenity=bicycle_repair_station` | 17 |

Specialized bicycle matches take precedence over the general Shops category.
The remaining amenity categories take precedence over a simultaneous generic
`shop=*` tag. This gives every switch one unambiguous owner: disabling Bicycle
Shops & Repair cannot leave the same icon visible through Shops.

Treat `shop=no`, `shop=vacant`, `shop=closed`, and empty/invalid values as
inactive. Do not infer closure from missing opening hours. Do not fuzzy-merge
nearby POIs: adjacent branches of the same chain are valid distinct objects.
Only duplicate representations of the same canonical OSM object/component may
be collapsed.

Retain both common OSM mapping shapes:

- tagged nodes use their point coordinate;
- tagged closed ways and multipolygon relations use a deterministic interior
  representative point computed before block assignment.

Use `representative_point()`, not a polygon centroid, so concave areas and areas
with holes never place their icon outside the source feature.

### Default behavior

- All five POI switches default **on** for a fresh ordinary Map profile.
- All five default **off** for a fresh Map + Navigation profile, preserving the
  current low-clutter guidance default.
- Existing saved Map and Map + Navigation feature choices are preserved. New
  POI keys receive the defaults above only because the user has never made a
  POI choice before.
- A fresh firmware profile mirrors the same defaults. Existing firmware NVS
  masks are not rewritten to add POI bits; the authenticated iPhone profile
  synchronization applies the user's saved choices after capability
  negotiation.
- General Shops appear only at runtime zoom levels 0-2. The four more
  rider-relevant categories appear at levels 0-3. POIs are hidden at farther
  levels even when their category switch is on.
- The settings footer explains that POIs appear at supported zoom levels.

The zoom policy and renderer limits are checked-in theme/configuration values,
not additional user controls.

### Device presentation

- Draw one compact, fixed-pixel icon per accepted POI. Icons remain upright and
  the same visual size in north-up, course-up, and bird's-eye views.
- Use distinct, high-contrast symbols for shop, food, toilets, fuel, and bicycle
  service. Store them as small firmware-owned monochrome/vector assets so map
  packs do not duplicate artwork.
- Project the icon anchor through the same `map_projection::Projection` used by
  roads, buildings, routes, and the current-position marker.
- Draw POIs into the base map after terrain/buildings and before street labels.
  Accepted POI icon bounds become reserved street-label regions.
- The route remains in the foreground canvas and the current-position marker
  remains a sibling above the base map. POIs therefore cannot cover either
  safety-critical overlay.
- Reuse the existing guidance/header and current-position reserved regions so
  a POI is not placed under controls or the rider marker.
- Collision handling is deterministic across adjacent blocks and redraws.

Initial hard renderer bounds are:

| Limit | Value |
| --- | ---: |
| Encoded POIs per FMB block | 16,384 |
| Candidates retained for one frame | 256 |
| Icons on ordinary Map | 32 |
| Icons on Map + Navigation | 20 |
| Nominal icon size | 18 px plus contrast outline |

The implementation may lower the frame limits after physical measurements, but
must not raise encoded or runtime memory limits without new dense-city evidence.
Generation fails with a typed error if a block exceeds the encoded limit; it
must never silently discard source POIs to make a pack fit.

### Legacy maps and unavailable data

- FMB v1-v4 and renderer targets 1-3 continue to install and render unchanged.
- POI controls are capability-gated. Firmware without the new capability does
  not receive bits 13-17.
- On capable firmware with an active target-1, target-2, or target-3 map, show
  the controls disabled with **Download Active Map Again** and explain that the
  installed map has no POI data.
- A target-4 map always contains a valid POI section in every emitted block,
  including an explicit zero-record section. Missing or corrupt target-4 POI
  data is an install failure, not an empty-map fallback.
- An area that genuinely contains zero matching POIs is valid. Its signed
  manifest reports zero counts and the UI does not describe the pack as corrupt.

### Explicit non-goals

The first version does not add:

- POI names or labels;
- POI search, category browsing, list views, or details;
- tap selection, routing to a POI, favorites, or destination import;
- opening hours, contact information, wheelchair/access metadata, or live
  availability;
- custom icons/colors/density settings; or
- fetching POIs separately from the signed offline map.

Keeping POIs in a dedicated versioned section leaves room for a future named or
interactive POI format without coupling this issue to a much larger product.

## Decisions locked into this plan

1. Always put all five categories into a target-4 pack; settings are device
   presentation state, not artifact-generation inputs.
2. Add renderer target 4 and FMB v5 instead of appending an unversioned payload
   to FMB v4.
3. Target 4 is cumulative: FMB v5 retains the FMB v3 label sections and FMB v4
   building section, then adds one required POI section.
4. Keep the outer BIKEMAP1 stream format and install protocol unchanged.
5. Reuse visibility setting IDs `8` and `20` and unused 32-bit mask bits 13-17.
   Do not allocate five new setting IDs.
6. Reserve one CAP2 bit for the complete target-4 reader/render/settings
   contract. Capability presence means the firmware can validate, install, and
   render target 4 and understands visibility bits 13-17.
7. Classify POIs during map generation. Firmware never parses raw OSM tags.
8. Use one canonical point per OSM POI and half-open block ownership. Do not
   clip or duplicate the same point into neighboring blocks.
9. Keep icon artwork in firmware and semantic category/position data in FMB.
10. Use bounded selection at render time rather than deleting dense-city data
    during generation.
11. Preserve the current full-screen-buffer, full-refresh, render-ahead, and
    IceNav-derived renderer architecture.
12. Keep target-4 production generation gated until backend, both firmware
    targets, iPhone transfer, and physical rendering gates pass.

## Versioning and compatibility model

| Renderer target | Block format | Required assets/features | New firmware behavior |
| ---: | --- | --- | --- |
| 1 | FMB v1/v2 or legacy FMP | Base geometry | Continue reading |
| 2 | FMB v3 | Street labels + one FMA1 asset | Continue reading |
| 3 | FMB v4 | Target 2 + OSM buildings | Continue reading |
| 4 | FMB v5 | Target 3 + map POIs profile 1 | New reader path |

Target 4 uses these signed manifest additions:

```json
{
  "target": {
    "renderer": "esp32-fmb",
    "formatVersion": 4,
    "labelProfileVersion": 1,
    "buildingProfileVersion": 1,
    "poiProfileVersion": 1
  },
  "pois": {
    "recordCount": 0,
    "shopsCount": 0,
    "restaurantsAndCafesCount": 0,
    "publicToiletsCount": 0,
    "gasStationsCount": 0,
    "bicycleServicesCount": 0
  }
}
```

The five category counts must sum exactly to `recordCount`. The backend
recomputes them from all FMB v5 blocks and rejects a generator report or
manifest that disagrees.

The manifest remains schema version 1: file entry shape, signing domain,
canonical JSON, stream envelope, and payload ordering do not change. The
renderer target version is the compatibility barrier.

## End-to-end architecture

```text
Geofabrik PBF / bounded source PBF
  -> OGR points + lines + multipolygons
  -> exact POI tag classification
  -> node coordinate or polygon interior representative point
  -> deterministic de-duplication and half-open block ownership
  -> FMB v5 section 5 + POI build statistics
  -> backend recomputation, target-4 manifest, signature, catalog
  -> iPhone target-4 download and compatibility validation
  -> authenticated map-stream transfer and atomic activation
  -> firmware FMB v5 validation + PSRAM block decode
  -> bounded projection/collision/icon pass
  -> POI regions reserved from street-label layout
  -> route and position marker composed above POIs

iPhone UserDefaults
  -> Map / Map + Navigation POI switches
  -> full visibility mask (setting 8 or 20)
  -> firmware NVS profile
  -> render semantic invalidation
```

## Extraction and POI normalization

### Source conversion

Extend `tools/OSM_Extract/scripts/pbf_to_geojson.sh` with an explicit POI mode
selected by renderer format 4. It writes `${prefix}_points.geojson` from the
OGR `points` layer in addition to the existing lines and multipolygons.

Do not add the third OGR pass to target-1, target-2, or target-3 jobs. Update the
backend conversion command to pass the renderer format explicitly while
preserving selected-area source-index, relation-closure, cancellation, and
retry arguments.

The selected-area OGR profile must expose `amenity`, `shop`, and `name` as
attributes or retain them losslessly in `other_tags` for both points and
multipolygons. Add a real fixture test because the default and selected OGR
profiles can otherwise diverge silently.

### `poi_pipeline.py`

Add a focused, pure Python POI module rather than extending generic polygon
styling with point-only special cases. It owns:

- safe parsing of top-level properties plus `other_tags`;
- lifecycle/inactive-value filtering;
- category precedence;
- canonical OSM identity and component identity;
- point validation and polygon representative-point generation;
- deterministic ordering;
- half-open block assignment;
- per-category zoom/rank configuration; and
- diagnostic/count aggregation.

Keep the classification table and visual rank/max-zoom policy in a checked-in
`conf/poi_categories.yaml`. Include that file in the worker build identity and
test its schema strictly.

For each raw feature:

1. Normalize the relevant tag keys/values without guessing synonyms outside
   the issue contract.
2. Apply specialized category precedence.
3. Parse only Point, Polygon, and MultiPolygon geometry.
4. Generate one canonical anchor per semantic OSM object/component.
5. Apply the requested selection policy consistently with other generic map
   features.
6. Assign an anchor to exactly one 4,096-metre block using
   `[minX, maxX) x [minY, maxY)` ownership.
7. Sort by block, coordinate, category, rank, OSM kind, and numeric ID before
   encoding.

Malformed individual OSM geometry is counted by reason and skipped. Structural
pipeline errors, nondeterministic identity, coordinate overflow, category
schema errors, or hard record/byte limits fail with a typed `poi_*` build error.

### Generator diagnostics

Emit one machine-readable `POI_STATS:` line containing at least:

- total records and counts by category;
- point versus area-derived records;
- inactive and malformed records by reason;
- exact-identity duplicates removed;
- blocks containing POIs;
- maximum records and POI bytes in one block; and
- normalization, block assignment, and encoding timings.

The backend parses this line using bounded strict JSON and compares the reported
artifact counts with independently parsed FMB v5 sections.

## FMB v5 POI section

Add `docs/fmb-v5.md` as the normative byte-level contract before landing the
writer and readers.

### Compatibility shape

- Magic/version is `FMB\x05`.
- Base polygon/polyline bytes keep their FMB v2 layout.
- Section types 1-3 keep the FMB v3 string, shaped-run, and road-label layouts.
- Section type 4 keeps the FMB v4 building layout.
- The `EXT5` directory contains exactly five ordered, critical, contiguous,
  CRC-protected sections.
- Section type 5 is the POI section.
- A target-4 block with no POIs still has a valid zero-count section 5.
- FMP remains legacy/developer-only and gets no POI representation.

Refactor the current `V3*` directory helpers into format-neutral extension
directory helpers shared by v3, v4, and v5. Keep the change limited to the map
format/parser boundary; do not refactor the renderer generally.

### Logical section-5 layout

The final specification uses a fixed eight-byte header and fixed eight-byte
records:

```text
POI section header
  uint16 recordCount
  uint16 recordSize        // exactly 8 for profile 1
  uint32 categoryMask      // bits 0...4, must match present records

POI record
  int16  localX
  int16  localY
  uint8  category          // 1...5
  uint8  maximumZoom       // 0...5
  uint8  rank              // 0...3; lower is preferred during selection
  uint8  flags             // zero in profile 1
```

Coordinates must be finite quantized block-local metres in `0...4095`. Reject
unknown categories, out-of-range zoom/rank, nonzero reserved flags, inconsistent
category masks, count/length mismatch, trailing bytes, CRC mismatch, and more
than 16,384 records.

The deterministic encoded record order is the stable final tie-breaker. Source
OSM IDs remain generator/audit data and are not copied into the device block
because profile 1 has no POI interaction or detail lookup.

### Explicit target selection

Change `write_fmb()` to receive an explicit renderer target. It must not infer
FMB v5 only from a non-empty POI list: a valid target-4 block with zero matching
POIs still needs FMB v5 and section 5. Target-to-block mismatches are hard
errors. Include POIs in the block-emission emptiness check so a block containing
only POIs is not dropped.

The block-size limit remains 2 MiB. POI records have their own count bound and
do not consume the legacy generic-feature count, but all decoded allocations
remain subject to the existing PSRAM and complete-block validation gates.

## Backend, signed artifacts, and catalog

### Renderer profile

Add renderer profile `map-pois-v1`, format 4, with the cumulative feature set:

```json
[
  "street-labels",
  "3d-buildings",
  "map-pois"
]
```

Replace scattered `format == 3` building checks with named predicates such as
`renderer_includes_buildings(format)` so targets 3 and 4 share the exact
building preprocessing, cache, statistics, and failure model. A separate
`renderer_includes_pois(format)` predicate is true only for target 4.

Target 4 reuses immutable target-3 building block-cache entries when their
source/rules identity matches. POI bytes are composed separately and are part
of the target-4 artifact identity. Final target-3 and target-4 artifacts are not
interchangeable reuse candidates.

### Validation and manifest construction

Extend `map_artifact_validation.py` to parse FMB v5 independently of the
generator. Require:

- FMB v5 for every target-4 `.fmb` file;
- exactly one matching FMA1 asset;
- valid label fingerprint/glyph/language references;
- valid FMB v4 building semantics inside section 4;
- valid required POI section 5; and
- recomputed building and POI summaries matching the signed manifest.

Update manifest parsing, pack validation, build identity, reuse identity,
download grants, catalog reader requirements, and API generation-capability
documents for format 4 and `map-pois`.

The geographic `mapId` remains geographic. Renderer target, POI profile/config,
producer build, and source snapshot affect artifact and signed-manifest identity
through the existing target/build-identity paths.

### Rollout policy

Add format 4 to the generation-profile schema and checked-in policy, initially:

- globally available in the development channel;
- an explicit installation allowlist/canary in production; and
- not globally available in production until the complete hardware gate passes.

Do not silently retry a target-4 request as target 3. A rejected target-4 job
must keep its request ID/idempotency identity and return the existing typed
renderer-capability error. Promote target 4 globally before releasing an iPhone
build that makes it the only new-map target.

Backend code changes follow the digest-pinned image promotion workflow in
`AGENTS.md`. If the signed worker moves, update and satisfy the map-stream
hardware gate before production promotion.

## Firmware parsing and block cache

### Validation and decode

Extend all three firmware reader boundaries together:

1. streaming install validation in `mapBlockFormat.*`;
2. signed manifest/target validation in `map_stream_parser.cpp` and
   `map_transfer.cpp`; and
3. runtime block decode in `Maps::readMapBlockBinary()`.

Add a small `mapPoiBlock.hpp` value model using `PsramAllocator` for decoded
records. `Maps::MapBlock` owns one POI block beside `labelData` and
`buildingData`. Parsing is all-or-nothing: a malformed POI section rejects the
block/map before activation.

New firmware accepts FMB v1-v5. It never treats an unknown/newer block as an
empty legacy block. Target 4 requires label profile 1, building profile 1, POI
profile 1, and the exact target-4 manifest roles.

### Bounded placement and drawing

Add pure host-testable POI selection/layout code, separate from LVGL and SD I/O.
For each render:

1. Gather records only from visible blocks, enabled categories, and applicable
   zoom levels.
2. Project anchors through the captured render-context projection.
3. Reject near-plane, invalid, or offscreen anchors with an icon margin.
4. Keep at most 256 candidates using a bounded nearest/best structure; do not
   allocate proportional to every POI in all loaded blocks.
5. Rank by screen mode, semantic category priority, encoded rank, distance to
   the presented rider position, block order, and record order.
6. Reserve marker and guidance/control regions.
7. Accept non-overlapping icons up to the per-screen limit.
8. Draw accepted icons into the base RGB565 surface.
9. Pass their padded bounds to the street-label layout as fixed reserved
   regions.

Include POI visibility and placement inputs in render/style and label-layout
cache signatures so a toggle, map activation, pan, zoom, rotation, projection,
or screen-profile change cannot reuse stale icons or label collisions.

POI allocation failure must preserve the last complete frame and use the same
semantic render invalidation/cancellation model as the current renderer. It must
not publish a partially drawn replacement frame.

### Diagnostics

Extend renderer diagnostics with bounded counters and timings:

- candidate, accepted, collision-rejected, offscreen, and capacity-deferred
  POIs;
- accepted counts by category;
- POI gather/layout/draw milliseconds; and
- decoded POI records/bytes for loaded blocks.

Keep production logs aggregate and rate-limited. Do not log rider coordinates
or every source POI.

## BLE visibility and persistence contract

### Capability

Add `map_pois` at CAP2 bit 23 with minimum client version 21 in
`protocol/ride-ble-contract-v1.json`, then regenerate the Swift and C++ protocol
files. Update capability golden vectors and Watch/iPhone compatibility tests.

Firmware advertises the bit only when the complete target-4 reader, installer,
renderer, visibility, and persistence path is present. The bit is not a claim
that the active map contains POIs; active renderer target/status remains the
map-data signal.

### Visibility masks

Extend `map_profile_protocol.hpp` with named bits 13-17 and a combined POI
mask. The existing extended-marker bit 12 remains required when a current app
sends extended masks.

Update `normalizedFeatureVisibilityMask()` so:

- legacy masks still synthesize Service Roads and Tracks exactly as today;
- current masks retain recognized road and POI bits only when the extended
  marker is present;
- unknown/reserved bits are discarded; and
- overlay bits 8-9 remain global and owned by Map setting ID 8.

No setting packet changes are needed: IDs 8 and 20 already carry signed 32-bit
values. Add the new masks to protocol/persistence/redraw host tests and ensure
both profile changes invalidate map semantics immediately.

### Firmware NVS

Continue storing complete masks in `visMask` and `navVis`. Replace magic default
values with named default masks. Do not add five independent NVS keys or a
one-time rewrite of existing masks.

Fresh NVS defaults include all five POI bits for Map and none for Map +
Navigation. Existing stored masks remain unchanged until the owner app sends a
new negotiated profile.

## iPhone model, settings UI, and transfer compatibility

### State and persistence

Add five `@Published` Boolean properties and UserDefaults keys for each screen
profile in `BLEManager.swift`. Persist them with the existing profile state.
Defaults are all on for Map and all off for Map + Navigation.

When constructing setting 8 or 20:

- include bits 13-17 only after authenticated capability negotiation reports
  `map_pois`;
- retain the user's Boolean choices when an old device is connected;
- set the existing extended marker for every current extended mask; and
- trigger one full profile resend when POI capability first becomes available
  on a connection.

Old firmware receives the same road/terrain mask it receives today. A capability
downgrade clears only connection support state, not saved POI preferences.

### UI

Under both Map-style screens add a **Points of Interest** section with:

- Shops;
- Restaurants & Cafes;
- Public Toilets;
- Gas Stations; and
- Bicycle Shops & Repair.

Show the section only when the connected firmware advertises `map_pois`. Enable
the switches only when the active map reports renderer format 4 and POI profile
1. Otherwise show a regeneration explanation and **Download Active Map Again**,
matching the established street-label workflow.

The UI sends the full profile visibility mask after any toggle rather than
incremental bit commands. This keeps iPhone, BLE, NVS, reconnect, and screen
switch behavior convergent.

### Map requests and saved artifacts

After production target 4 is globally available, change every new custom bbox,
polygon, route-corridor, and regeneration request from target 3 to target 4.
Include target 4 in:

- generation-capability validation;
- request encoding and typed rejection tests;
- signed manifest decoding;
- FMB header/asset validation;
- saved-map metadata;
- catalog reader capabilities and requirements; and
- transfer compatibility policy.

Saved targets 1-3 keep their current rules. Target 4 requires all of:

- street-label capability;
- OSM 3D-building capability; and
- map-POI capability.

Treat an inconsistent capability response as incompatible instead of assuming
the newest bit implies missing older bits. The transfer is rejected before
opening the device-hosted upload session.

Track `activeMapPoiProfileVersion` (and a POI-data health flag if status framing
needs to distinguish it) from device status. Clear it on disconnect, activation
failure, map removal, or legacy-map activation so stale target-4 UI cannot stay
enabled.

## Delivery phases

### Phase 1 - Normative contracts and golden fixtures

1. Add `docs/fmb-v5.md`, category/bit mappings, target-4 manifest rules, and
   BLE capability documentation.
2. Add synthetic OSM fixtures containing point, way, relation, lifecycle,
   overlap-precedence, boundary, invalid-geometry, and dense-block cases.
3. Add cross-language FMB v5 and manifest golden vectors.

Exit criterion: Python, C++, backend, and Swift tests agree on category codes,
section bytes, counts, target version, visibility bits, and capability bit.

### Phase 2 - Extractor and independent artifact validation

1. Add the target-4 point-layer conversion and `poi_pipeline.py`.
2. Add FMB v5 writing with explicit target selection and POI statistics.
3. Add backend FMB v5 parsing, summary recomputation, manifest validation, and
   target-4 generation profile behind development/canary policy.
4. Prove target-1 through target-3 artifact bytes/fixtures remain unchanged.

Exit criterion: a deterministic target-4 pack built from the fixture contains
the expected five category counts and independently validates; corruption and
limit fixtures fail with typed errors.

### Phase 3 - Firmware reader and renderer

1. Add signed target-4/FMB v5 install validation and runtime decode.
2. Add bounded POI selection, collision, icons, street-label reservations, and
   diagnostics.
3. Add visibility bits, NVS defaults, render invalidation, and CAP2 bit 23.
4. Build ordinary and production firmware for both board targets through the
   repository build/CI paths.

Exit criterion: host tests pass, all four firmware profiles build, legacy maps
render unchanged, and target-4 maps render deterministic icons in synthetic
surface tests. This is not yet physical acceptance.

### Phase 4 - iPhone settings and target-4 delivery

1. Add capability parsing, per-screen persistence, mask composition, and UI.
2. Add active-map availability/status handling and regeneration UX.
3. Add target-4 requests, saved-map/catalog validation, and pre-transfer
   compatibility gates.
4. Run portable Swift tests and unsigned iOS build.

Exit criterion: connection/reconnect simulations converge on the same masks;
old devices never receive POI bits; target 4 is refused before transfer to
incompatible firmware; and all new-map request modes select target 4 only after
the service rollout prerequisite.

### Phase 5 - Integrated rollout and physical gates

1. Publish the backend worker through the digest-pinned development channel.
2. Generate and sign a known target-4 fixture/real-area artifact; verify counts,
   bytes, manifest, stream, download, and activation separately.
3. Complete physical rendering and persistence gates on both Waveshare targets.
4. Promote target 4 from production canary to global generation.
5. Release the iPhone target-4 request path only after that promotion.

Exit criterion: the acceptance matrix below is recorded with exact backend
image digest, artifact receipt, firmware SHA/profile/board identity, app build,
and map source snapshot.

## Test and validation matrix

### Extractor and format tests

- Exact classification for every issue tag.
- Bicycle precedence over general Shops.
- Inactive/lifecycle exclusion and malformed `other_tags` handling.
- Point, closed-way, multipolygon, concave polygon, hole, and boundary
  ownership fixtures.
- Deterministic output across input ordering and worker count.
- No fuzzy collapse of adjacent same-name/category POIs.
- Empty POI section, maximum valid count, count overflow, coordinate overflow,
  unknown category, reserved flags, CRC mismatch, truncation, trailing bytes,
  and oversized-block rejection.
- FMB v2/v3/v4 golden regressions remain byte-identical.

Run at minimum:

```sh
python -m unittest discover -s tools/OSM_Extract/tests
```

### Backend and signed-stream tests

- Format-4 generation policy, canary/global capability documents, and exact
  cumulative feature set.
- Target-4 pipeline command includes point conversion and target-3 building
  preprocessing/cache semantics.
- POI report versus independently parsed artifact count mismatch rejection.
- Manifest count-sum, profile, asset-role, FMB-version, producer-identity,
  request/reuse identity, and catalog reader tests.
- Signed map-stream target-4 golden vector plus all malformed/truncated cases.
- Target-1 through target-3 API, artifact, and catalog compatibility.

Run the repository backend/deploy suites from `map-platform/backend`:

```sh
python -m unittest discover -s tests
python -m unittest discover -s ../deploy/tests
```

### Firmware host/build tests

- Stream and runtime FMB v5 parsers accept the same golden bytes.
- All section/count/reference/CRC/bounds failures reject before activation.
- Visibility normalization and NVS fresh/existing-profile behavior.
- CAP2 client-version gating and feature-vector tests.
- Per-category icon selection, projection, near-plane clipping, collision,
  rank, capacity, label reservations, and stable ordering.
- Route/marker foreground invariants and render cancellation/no-partial-frame
  behavior.
- Flat, rotated, and every supported bird's-eye perspective.
- FMB v1-v4 parser/render regressions.

Build through the repository wrapper, not raw PlatformIO:

```sh
cd esp32
python3 tools/build_firmware.py WAVESHARE_AMOLED_175
python3 tools/build_firmware.py WAVESHARE_AMOLED_206
```

CI/release qualification must also cover the corresponding production
profiles. A build is source evidence, not physical device evidence.

### iPhone tests

- Fresh defaults, existing UserDefaults migration, save/relaunch, and
  capability downgrade/upgrade.
- Exact setting-8 and setting-20 masks for each toggle and both profiles.
- No POI bits sent to old firmware; one negotiated resend to new firmware.
- Active target-3 versus target-4 settings availability and regeneration CTA.
- New bbox, polygon, corridor, and regeneration requests use target 4.
- Typed target-4 service rejection does not silently retry target 3.
- Saved target-1 through target-4 and inconsistent-capability transfer matrix.
- Manifest/catalog/FMB v5 validation and active-map status reset.

Run:

```sh
cd ios-app
./scripts/run-navigation-tests.sh
./scripts/xcodebuild-cli.sh \
  -project BikeComputer/BikeComputer.xcodeproj \
  -scheme BikeComputer \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

### Physical acceptance

Treat the 1.75-inch and 2.06-inch boards as separate gates. Immediately before
any flash, re-identify the board by stable serial and obtain fresh confirmation
naming the artifact, Git SHA, serial, and environment.

For each board:

1. Install the exact target-4 map and confirm activation/status identity.
2. At a fixed known coordinate, compare on-device category counts/positions
   against the generated fixture/reference preview.
3. Toggle each category independently on Map and prove the other four do not
   change.
4. Repeat on Map + Navigation with an active route and prove the route and
   marker stay visually dominant.
5. Verify zoom 0-5, north-up, course-up, and supported bird's-eye perspectives.
6. Reconnect the app and cold/warm reboot the device; confirm both profiles
   retain their choices.
7. Activate a target-3 map and confirm legacy rendering plus the regeneration
   UI, then reactivate target 4.
8. Pan/zoom through a dense urban area while navigation/GPS updates arrive;
   record render time, deferred counts, internal heap, PSRAM, and frame
   freshness.
9. Run an extended navigation/soak session and confirm no reset, watchdog,
   partial frame, stale icon, or unbounded memory growth.

## Rollout and rollback

Roll out in this order:

1. development backend/worker with target 4;
2. target-4-capable development firmware;
3. development iPhone build and physical gates;
4. production backend canary;
5. production firmware capability;
6. production target-4 global generation; then
7. iPhone release that requests target 4 for new maps.

Safe rollback levers are:

- disable POI switches while retaining a valid target-4 map;
- restore the previous known-good target-4 worker digest;
- keep target 4 canary-only before the iPhone production release;
- revert the iPhone new-map request target to 3 in a reviewed release; and
- continue installing saved target-1 through target-3 maps.

Do not advertise the capability from firmware that cannot validate every
target-4 section. Do not globally disable target-4 generation after shipping an
iPhone build that exclusively requests it without simultaneously providing a
compatible app rollback; silent target downgrade is intentionally forbidden.

## Expected implementation surface

| Layer | Primary files/modules |
| --- | --- |
| OSM conversion | `tools/OSM_Extract/scripts/pbf_to_geojson.sh`, selected OGR config |
| POI normalization | new `tools/OSM_Extract/scripts/poi_pipeline.py`, new POI config and fixtures |
| FMB writer | `tools/OSM_Extract/scripts/map_format.py`, `extract_features.py`, `docs/fmb-v5.md` |
| Backend | `generation_profiles.py`, new POI contract module, `pipeline.py`, `map_artifact_validation.py`, `manifest.py`, build/reuse identity and tests |
| Generation policy | `map-platform/config/generation-profile-policy-v1.json`, rollout/hardware-gate configuration |
| Firmware format/install | `mapBlockFormat.*`, `map_stream_parser.cpp`, `map_transfer.*`, parser/install tests |
| Firmware render | new POI block/layout/icon helpers, `maps.hpp`, `maps.cpp`, renderer diagnostics/tests |
| BLE/profile | `protocol/ride-ble-contract-v1.json`, generated protocol files, `map_profile_protocol.hpp`, persistence/redraw tests, `ble_navigation.*`, `docs/ble-protocol.md` |
| iPhone | `BLEManager.swift`, `SettingsView.swift`, offline-map request/manifest/catalog/manager models, `NavigationProtocolTests.swift` |
| Map docs | `docs/map-stream-format-v1.md`, offline-map build/install and rollout documentation |

Exact helper filenames may change during implementation, but the separation
between source classification, wire-format validation, renderer placement, and
product settings must remain.

## Acceptance criteria

The feature is complete only when all of the following are true:

1. Target-4 extraction retains matching point and area POIs from the bounded
   Geofabrik source with deterministic category precedence and block ownership.
2. Every target-4 block is FMB v5 with a required, bounded, CRC-validated POI
   section, including empty blocks.
3. Backend-recomputed POI counts match generator diagnostics and the signed
   manifest exactly.
4. New firmware reads targets 1-4; old firmware is prevented from receiving
   target 4 before transfer.
5. Map and Map + Navigation persist independent choices for all five groups.
6. Old firmware never receives visibility bits 13-17, while capable firmware
   receives one convergent full profile after negotiation/reconnect.
7. The renderer uses the shared projection, bounded placement, deterministic
   collision rules, and complete-frame publication.
8. POIs never cover the route, current-position marker, or declared UI regions,
   and street labels avoid accepted POI icons.
9. Active legacy maps explain that regeneration is required; a corrupt target-4
   section fails activation instead of appearing empty.
10. All extractor, backend, C++, Swift, signed-stream, and compatibility tests
    pass on the exact implementation head.
11. Ordinary and production firmware builds pass for both the 1.75-inch and
    2.06-inch targets.
12. Physical category, persistence, dense-scene, navigation, and soak gates pass
    independently on both board families.
13. The digest-pinned backend promotion and map-stream hardware gate are
    complete before target 4 becomes globally available.
14. The production iPhone target-4 request path ships only after production
    generation is globally available.
