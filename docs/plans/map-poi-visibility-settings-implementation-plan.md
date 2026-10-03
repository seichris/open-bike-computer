# Offline Map Layers and Nearby POIs Implementation Plan

## Outcome

Add offline OpenStreetMap points of interest to the bike-computer map and let
the rider show or hide five POI groups independently for **Map** and
**Map + Navigation**:

- shops;
- restaurants and cafes;
- public toilets;
- gas stations; and
- bicycle shops and repair stations.

Use **one offline map with independently switchable POIs and contours**, not
separate mutually exclusive POI and topographic maps. Every new-format map
contains all five POI groups; the normal download includes contours where an
approved elevation source is available. Display switches never regenerate or
replace the map. An explicitly chosen map without elevation remains usable,
with contours marked unavailable rather than silently invented or omitted.

Add an on-device **Nearby** screen: select one or several of the five category
icons, then **Show nearby**. Its map shows up to ten nearest matching places in
the downloaded area, with direction/distance indicators for off-screen results.
Existing route, position-marker, street-label, and building behavior remains
authoritative.

This plan is associated with
[issue #338, Add map POI visibility settings](https://github.com/seichris/open-bike-computer/issues/338).
[AnyFinder](https://anyfinder.app/) is useful product inspiration for exposing
OSM POI categories. The user's October 2 UX decision expands the original
visibility-only issue to include offline category-based Nearby discovery, but
not text search, business details, routing, editing, or OSM account integration.

This revision supersedes the earlier POI-only target-5 proposal. The original
draft PR reflected an older implementation; this branch integrates the newer
topography baseline and Nearby flow. Its new code is not production-qualified
or enabled merely because it exists in the branch.

## Baseline

This plan was refreshed against freshly fetched GitHub `main` at
`f935ede97cd4232357c5b8aafa704c58bffe6ab3` (2026-10-03,
Asia/Singapore), 85 commits after the September 26 baseline. The original
implementation branch and PR #378 predated the topography work. The local
branch has now merged this SHA and migrated the POI wire/format allocation,
but full builds, CI, hardware qualification, and PR publication remain
separate evidence gates.

Current `main` already provides most of the cross-device settings path:

1. `tools/OSM_Extract` extracts styled lines and multipolygons from a bounded
   Geofabrik PBF.
2. Renderer target 3 writes FMB v4 blocks containing base geometry, street
   labels, and OSM buildings, plus one FMA1 label font asset. Current main
   also implements target 4 / FMB v5 for topographic contours in an exact-ID
   development canary; section 5 is the contour section, not a free POI slot.
3. The backend validates, signs, catalogs, and streams standard target-3 maps.
   Topography adds a separate, receipt-bound iPhone `.btopo` companion and a
   generation-policy v2 with development-canary/production-disabled states.
4. Firmware validates FMB v1-v5, caches decoded blocks in PSRAM, projects map
   geometry, and composes a background map canvas with a route foreground and
   a separate current-position marker.
5. The 32-bit Map and Map + Navigation visibility masks use bits 0-13. Bit 13
   is topographic contours. Setting IDs `8` and `20` already transport and
   persist those full masks, including configurable-screen round trips.
6. The iPhone persists per-screen feature switches, negotiates CAP2
   capabilities, and resends both map profiles after connection.
7. Ordinary new iPhone map requests still use renderer target 3. Explicit
   topographic jobs use target 4 only on the development-canary path. Saved
   targets 1-4 have format-specific transfer and companion rules.
8. CAP2 bit 26/client version 24 now belongs to configurable screens, and
   bit 30/client version 28 belongs to topographic contours. Bit 31 is the
   remaining unassigned CAP2 feature bit in the current 32-bit response.
9. Both Waveshare production profiles now enable the accepted-camera path.
   The single map worker owns decoded blocks, render-ahead, map activation,
   and replacement frames; the UI task owns live route/marker presentation.
10. The extractor now allows up to 4,096 clipped generic-polygon pieces per
    source in a dense-area fixture. POI normalization must retain its own
    point/area count and block-byte bounds, not reuse that polygon-piece limit.
11. Selected map extraction can read sealed one-degree source shards, with a
    pinned-source fallback outside prepared coverage. Building indexes and
    calibration can be prepared once, and missing building closure can be
    exported from the verified index. This preparation is not a general POI
    index and cannot supply missing tagged nodes or arbitrary POI relations.
12. Configurable screen instances are the primary settings path on current
    firmware. Their document validation, autosave controller, and renderer
    mask must carry POIs as well as the legacy setting-8/20 path.
13. `tools/dev-check` now selects local/CI checks from a shared registry and
    Swift source graph. Ordinary local builds and clean-source qualification
    have distinct evidence modes; firmware dependency caches can be shared
    through verified transport across worktrees.

### Changes since the September 26 refresh

These are source findings at the recorded SHA. Deployment locks and release
records are checked-in evidence; live services and physical devices were not
queried for this planning update.

| Current-main change | Consequence for the POI implementation |
| --- | --- |
| Reusable building preparation and regional source shards (#528, #532, #535) | Extract POIs from the selected general OSM PBF, retain the shard/source verification and fallback rules, and prove identical POI records across full-source, prepared, and shard-boundary paths. |
| Nonbuilding multipolygon parents excluded from the building index | A shop or amenity area must survive independently of building membership. Building closure and calibration caches are not a POI data source. |
| Durable queue admission and public `queuePosition` | Preserve queued jobs, current typed queue-full errors, idempotency, cancellation, and the app's queue status. Do not restore the PR's obsolete cost-budget admission model. |
| `VISIBILITY_RENDER_FEATURE_MASK` now feeds configurable-screen rendering | Extend both wire-document allowed masks and the runtime render mask; merely accepting POI bits in setting 8/20 can still silently strip them when a screen instance is selected. |
| GPS presentation now uses source capture age | POI ranking and marker reservations use the captured render context. Delayed BLE delivery must not refresh a stale rider position or restart prediction. |
| Active-map pointer readback and journal rollback (#540) | Carry POI target/profile/health metadata through candidate, previous-map, readback, and recovery records. Test rollback from target 5 to both standard and topographic maps. |
| Worldwide signed-map approval for build 101 | Existing approval is bound to specific firmware, app, worker, and producer identities. It does not approve a future POI worker, format, or board build. |
| Shared development checks, Swift source graphs, build evidence and scenario replay (#555, #557, #558) | Register POI checks in the existing runner; use its isolated test state and retained reports, and validate release builds with symbols when required. Cache benchmarks are a separate manual workflow. |
| Signed USB recovery packages and firmware build 102 (#567, #568) | This changes release/recovery inputs, not the POI data model. The build-101 map approval does not cover build 102 or any new POI firmware; requalify exact new images and keep the POI runtime gate closed meanwhile. |

### Local integration checkpoint

The branch now carries target 5/FMB v6 section 6 and FPI1 production
code across extractor, backend, installer, iPhone validation, firmware query,
and bike-computer Nearby presentation. Host checks cover index trust,
nearest-ten ranking, cancellation/corruption, layout, and the screen feature
gate. Target-5 manifests now also sign the complete selected block set,
including empty blocks; backend, iPhone, and firmware validators reject
missing or out-of-scope coverage, and Nearby warns when the requested radius
reaches undownloaded geography rather than reporting a false empty search.
The feature remains **off by default** with
`MAP_POIS_RUNTIME_ENABLED=0` in ordinary and production profiles. Both
`*_REMOTE_DEBUG` development profiles opt in for hardware qualification and
advertise CAP2 bit 31 only when the configurable-screen subsystem is ready
for client version 29 or newer. Prior exact-head iOS qualification and 1.75-inch
CI builds passed; the coverage change requires new exact-head checks, and
physical acceptance on both board families is still required. The connected
ESP32's board family has not been identified, so no board-specific local build
or flash is evidence for this checkpoint.

The September allocation remains available in code: target 5/FMB v6,
visibility bits 14-18, and CAP2 bit 31/client 29. The topography plan's
unimplemented hillshade reservations have been moved to the next prospective
format/section and visibility bit in this PR; recheck all allocations before
implementing hillshade.

At the recorded `main` baseline, the missing pieces were point extraction,
exact category and block ownership, a noncolliding POI section and renderer
profile, bounded icon placement, offline nearest-neighbor lookup, and the
capability/settings/screen path. The local branch implements these paths, but
the feature gate remains closed while build, CI, and physical qualification
are pending. A signed map with POIs and the matching app/firmware must all be
available before the end-to-end experience can be exercised.

### Collision with the original PR

The original PR #378 assigned renderer target 4 / FMB v5 section 5,
visibility bit 13, and CAP2 bit 26 to POIs. Current main assigns those
identifiers to topographic contours and configurable screens. The integrated
branch has migrated the golden vectors, generated BLE files, manifests,
readers, policies, and tests to target 5 / FMB v6 section 6, visibility bits
14-18, and CAP2 bit 31. Never accept both meanings behind the same version:
already-created target-4 artifacts and old clients would become ambiguous.

### 3 MiB production application budget

PR #378 must pass with the existing dual 3 MiB OTA layout before the separate
partition migration in issue #461. Keep the 65,536-byte application reserve
enforced: the maximum verified `firmware.bin` size is 3,080,192 bytes in a
3,145,728-byte slot. PlatformIO's Flash estimate excludes image overhead;
the build helper's verified binary size determines acceptance.

The previous image at `809902f75` was 3,080,615 bytes, 423 bytes over that
limit. The POI path codec now formats a complete relative path once and
parses bounded string views with 32-bit arithmetic, removing temporary
strings and 64-bit conversions while preserving canonical-path, signed
coordinate, traversal, and overflow rejection. Tests cover negative tile
boundaries, both int32 extremes, invalid aliases, and malformed paths.
The updated firmware matrix must establish the final binary size before this
budget gate is marked passed. Runtime enablement and physical qualification
remain separate from application-size acceptance.

## Product contract

### Categories and OSM semantics

The generator assigns every retained OSM object to at most one category.
Matching is case-normalized and based on active top-level tags, not lifecycle
tags such as `disused:shop` or `abandoned:amenity`.

| Category | Matching tags | Visibility bit |
| --- | --- | ---: |
| Shops | `shop=*`, excluding inactive placeholder values and `shop=bicycle` | 14 |
| Restaurants & Cafes | `amenity=restaurant`, `amenity=cafe`, `amenity=fast_food` | 15 |
| Public Toilets | `amenity=toilets` | 16 |
| Gas Stations | `amenity=fuel` | 17 |
| Bicycle Shops & Repair | `shop=bicycle`, `amenity=bicycle_repair_station` | 18 |

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
  POI choice before in the legacy UserDefaults path. Existing configurable
  screen documents retain their stored masks exactly; do not interpret missing
  POI bits as permission to rewrite an existing screen profile.
- A fresh firmware profile mirrors the same defaults. Existing firmware NVS
  masks are not rewritten to add POI bits; the authenticated iPhone profile
  synchronization applies the user's saved choices after capability
  negotiation.
- In the ordinary, ambient map view, General Shops appear only at runtime zoom
  levels 0-2. The four more rider-relevant categories appear at levels 0-3.
  POIs are hidden at farther
  levels even when their category switch is on.
- The settings footer explains that POIs appear at supported zoom levels.

The zoom policy and renderer limits are checked-in theme/configuration values,
not additional user controls. Nearby's explicit result set is exempt from these
ambient zoom/category filters: zooming out must not hide the places the rider
just asked to find. Contour visibility remains independent in both modes.

### Nearby: rider flow

Nearby is a configurable screen on the **bike computer**, not a phone-only
search page. The phone configures its inclusion/order like other device screens.
It has two states within the same screen instance:

```text
Nearby category picker
  [Shops]              [Restaurants & Cafes]
  [Public Toilets]     [Gas Stations]
  [Bicycle Shops & Repair]
  [Show nearby]  (enabled after at least one selection)
          |
          v
Nearby map: up to 10 results + edge indicators
  [Categories] -> return to picker with current selections
  Leave screen -> ordinary map profiles are unchanged
```

- Each large icon tile also has a readable label and an explicit selected
  state/checkmark; do not rely on color alone. Use a board-specific layout
  within the usable display shape, not a rectangular grid cropped by a round
  screen. Physical touch-target and readability checks are required on both
  boards. Choosing a tile does not immediately leave the picker: an explicit
  **Show nearby** action makes multi-select possible.
- The working assumption is **10 results total across selected categories**,
  not 10 per category, to keep the small display readable.
  Sort by straight-line geographic distance from a fresh rider fix, then stable
  record identity; do not prefer paid, popular, or arbitrarily ranked places.
  All ten may belong to one category if those really are the nearest matches.
- Search the installed map within 10 km initially. **Search further** expands
  to 25 km explicitly; no unbounded search or network POI request. Display the
  search radius and **Downloaded area only** when coverage is incomplete.
  Fewer than ten matches is a valid result, with the actual count shown.
- The count includes both on-screen and off-screen results. On-screen results
  use category icons at their map positions. Other ambient POI icons are hidden
  during the session so the result set remains unambiguous. Roads, buildings,
  contours, the rider marker, and any active route remain visible according to
  the instance's map profile.
- A compact **Categories** control returns to the picker without losing the
  selection. Leaving Nearby cancels its worker query; returning restores the
  in-memory selection and offers a fresh query, not stale location results.
  Selections are session state, not changes to saved Map/Map + Navigation POI
  switches. Reboot begins with no category selected.
- Initial results are a consistent location snapshot. Distances can refresh
  with fresh fixes; a new nearest query runs after 50 m of movement and no more
  often than once every five seconds. Publish a complete replacement set, never
  reshuffle individual markers mid-query. Mark old results as updating until
  the replacement is ready; these tuning constants require on-bike validation.

### Off-screen indicators and distance

- Place indicators **just inside** the usable map boundary, not outside the
  physical display. Each has a category icon, a small outward direction arrow,
  and distance underneath, for example `350 m` or `1.2 km`.
- Use straight-line distance, not minutes, and explain **Direct distance — not
  route distance** on the picker/results help. Minutes would imply a known
  rideable route and travel speed; neither is supplied by POI coordinates.
  Round sub-kilometre distances to useful metre precision (10 m), and larger
  distances to 0.1 km without oscillating at the unit boundary. A river or
  motorway can make the actual ride much longer; do not call this an ETA.
- Edge direction follows the accepted map camera: north-up, course-up, and
  supported perspective views. Screen clipping/panning uses the POI's direction
  from the visible map center; the displayed distance is always from the rider.
  Do not use an off-screen projection behind the near plane as a valid anchor.
- Inset the entire icon/arrow/text rectangle from the round or rectangular
  display clip and reserved controls. Distance text cannot be clipped off at
  the bottom. Route, rider marker, and guidance remain visually dominant.
- Prevent icon/label overlaps with deterministic edge spacing. When individual
  indicators cannot fit, group results pointing in the same direction and show
  the category (or a neutral mixed-category symbol), count, and nearest member's
  distance. Tapping a group opens a small category/distance chooser, not business
  details; choosing a member highlights/recenters that result without starting
  routing. On-map coincident results use the same grouping convention.
- Use transition hysteresis at the viewport edge and stable tie-breaking, so
  minor GPS/camera changes do not flicker between a map pin and an edge icon.
  A result is represented once, either on-map or at the edge (possibly grouped).

### Nearby empty, unavailable, and interrupted states

| State | Rider-facing behavior |
| --- | --- |
| No category selected | Keep **Show nearby** disabled; explain to choose one or more. |
| No fresh position | **Waiting for GPS**; do not invent a location or silently search from an old fix. Previously visible results are frozen and marked stale. |
| Search running | **Finding nearby places…**; keep the map responsive and support cancellation. |
| No matching records | **No matching places within 10 km in this map** (use the selected radius), with categories/search-further actions; do not claim no such place exists in reality. |
| Outside/near edge of downloaded coverage | Explicit coverage warning; do not treat unrepresented geography as searched empty space. |
| Active map lacks POIs | Explain that an updated offline map is required; direct the rider to download on the phone. |
| Corrupt data/read failure | A typed map-data error, not zero matches or a successful partial top ten. |
| Map replaced, screen left, or request superseded | Cancel the old generation and discard its late results. |

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
| Nearby results, including off-screen | 10 total |
| Nominal icon size | 18 px plus contrast outline |

The implementation may lower the frame limits after physical measurements, but
must not raise encoded or runtime memory limits without new dense-city evidence.
Generation fails with a typed error if a block exceeds the encoded limit; it
must never silently discard source POIs to make a pack fit.

### Legacy maps and unavailable data

- FMB v1-v5 and renderer targets 1-4 continue to install and render unchanged.
- POI controls are capability-gated. Firmware without the new capability does
  not receive bits 14-18.
- On capable firmware with an active target-1 through target-4 map, show the
  controls disabled with **Download Active Map Again** and explain that the
  installed map has no POI data. A target-4 map can be regenerated as a combined
  target-5 map with the same requested contour support; adding POIs must not
  silently remove elevation. Retain the previously saved map/companion until
  the new artifact is verified and activated.
- A target-5 map always contains a valid POI section in every emitted block,
  including an explicit zero-record section. Missing or corrupt target-5 POI
  data is an install failure, not an empty-map fallback.
- An area that genuinely contains zero matching POIs is valid. Its signed
  manifest reports zero counts and the UI does not describe the pack as corrupt.
- Missing elevation is distinct from flat terrain with zero contour records.
  Offer an explicit map-without-contours choice only after explaining that
  elevation is unavailable. Never silently downgrade a combined-map request.

### Explicit non-goals

The first version does not add:

- POI names or labels;
- free-text/name search, business details, or general-purpose result lists
  (the bounded overlap chooser is in scope);
- routing to a POI, route-time estimates, favorites, or destination import;
- opening hours, contact information, wheelchair/access metadata, or live
  availability;
- custom icons/colors/density settings; or
- fetching POIs separately from the signed offline map.

Keeping POIs in a dedicated versioned section leaves room for future names and
business details without requiring them for offline category discovery.

## Decisions locked into this plan

1. Always put all five categories into a target-5 pack; settings are device
   presentation state, not artifact-generation inputs.
2. Add renderer target 5 and FMB v6 instead of reinterpreting target 4 / FMB v5
   or appending an unversioned payload.
3. Target 5 retains FMB v3 label sections 1-3, FMB v4 building section 4, and
   FMB v5 contour section 5, and adds required POI section 6 plus a signed Nearby
   block index. A normal target-5 artifact contains both POIs and contours.
   An explicit no-elevation variant has a signed layer-availability discriminant
   and canonical empty section 5; it is not a second active map or a silent
   fallback. Target-4's existing strict contract remains unchanged.
4. Keep the outer BIKEMAP1 stream format and install protocol unchanged.
5. Use 32-bit visibility bits 14-18 in each configurable screen's map profile.
   Reuse setting IDs `8` and `20` for the legacy profile path. Do not allocate
   five new setting IDs or maintain a second authoritative per-instance store.
6. Reserve CAP2 bit 31 / minimum client version 29 for the complete target-5
   reader/render/settings/Nearby contract. Capability presence means the firmware
   can validate and render both defined target-5 variants, query its POI index,
   and understands visibility bits 14-18. Nearby screen type 6 is additionally
   advertised through the existing configurable-screen type mask. Do not alter
   the meanings of CAP2 bits 26 or 30.
7. Classify POIs during map generation. Firmware never parses raw OSM tags.
8. Use one canonical point per OSM POI and half-open block ownership. Do not
   clip or duplicate the same point into neighboring blocks.
9. Keep icon artwork in firmware and semantic category/position data in FMB.
10. Use bounded selection at render time rather than deleting dense-city data
    during generation.
11. Preserve the current accepted-camera, single-worker, complete-frame
    render-ahead architecture and the live route/marker foreground. POI layout
    must use the accepted projection and visible crop, not a newly requested
    camera pose or a second SD/cache owner.
12. Keep target-5 production generation gated until backend, both firmware
    targets, iPhone transfer, and physical rendering gates pass.
13. Preserve target-4 contour behavior byte-for-byte. Combined target 5 reuses
    the validated elevation-source, contour, and receipt-bound companion
    pipeline; it does not bypass the topography rollout/coverage gates.
14. Nearby selection is transient and independent of saved ambient visibility.
    Rank up to ten selected-category results by direct distance; off-screen
    indicators and overlapping groups are part of the same bounded result set.
15. Keep nearest search on the existing map worker with signed spatial summaries,
    cancellable bounded I/O, and immutable result publication. Never SD-scan all
    map geometry on the LVGL/UI thread or search only currently loaded blocks.

The [topography plan at this baseline](https://github.com/seichris/open-bike-computer/blob/0f6fc8c6f0238d5508df199f2a50b1482b62ca1d/docs/plans/issue-190-topographic-map-support-implementation-plan.md)
proposes target 5/FMB v6/section 6 and visibility bit 14 for future hillshade.
No implementation of that contract exists in the inspected main, but both
reservations conflict with this POI proposal. This PR updates the prospective
hillshade format and visibility reservations to target 6/FMB v7/section 7 and
bit 19. Recheck main before landing either feature. Do not ship two different
target-5 or visibility-bit meanings.

## Versioning and compatibility model

| Renderer target | Block format | Required assets/features | New firmware behavior |
| ---: | --- | --- | --- |
| 1 | FMB v1/v2 or legacy FMP | Base geometry | Continue reading |
| 2 | FMB v3 | Street labels + one FMA1 asset | Continue reading |
| 3 | FMB v4 | Target 2 + OSM buildings | Continue reading |
| 4 | FMB v5 | Target 3 + topographic contours profile 1; separate `.btopo` companion | Preserve current-main reader path |
| 5 | FMB v6 | Target 3 + contour section 5 + POI section 6 + signed Nearby index; explicit contour availability | Combined-layer reader and Nearby path |

Target 5 uses these signed manifest additions:

```json
{
  "target": {
    "renderer": "esp32-fmb",
    "formatVersion": 5,
    "labelProfileVersion": 1,
    "buildingProfileVersion": 1,
    "poiProfileVersion": 1,
    "poiIndexProfileVersion": 1,
    "topographyProfileVersion": 1
  },
  "layers": {
    "contours": "included"
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

This fragment shows the combined variant, not a complete manifest; its existing
topography receipt/source/companion metadata is also required. The five category
counts must sum exactly to `recordCount`. The backend recomputes them from all
FMB v6 blocks and rejects a generator report or
manifest that disagrees.

For target 5, `layers.contours` is a required closed discriminator, with exactly
two valid shapes:

| Value | Required shape |
| --- | --- |
| `included` | Topography profile 1, verified elevation/source receipts, valid contour sections (possibly zero in genuinely flat blocks), and the existing signed/associated iPhone `.btopo` companion contract. |
| `not-included` | No topography profile/receipts/companion; every section 5 has version 1, flags 0, intervals `(20, 100)`, and zero records/points. This shape requires an explicit no-contours generation request. |

Reject missing/unknown discriminators and inconsistent feature/section/companion
combinations. A zero contour count does not establish which variant was built.
Both variants require healthy POI sections and the Nearby index, including when
the POI count is zero. The device streams only its device assets; preserve the
separate iPhone companion's receipt binding and transfer rules. Target 4 retains
its strict manifest/companion contract without this new discriminator.

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
  -> FMB v6 section 6 + Nearby spatial index + POI build statistics
Approved elevation source (when explicitly included)
  -> existing contour pipeline -> FMB v6 section 5 + receipt-bound .btopo
Both layers in one artifact
  -> backend recomputation, target-5 manifest, signature, catalog
  -> iPhone target-5 download and compatibility validation
  -> authenticated map-stream transfer and atomic activation
  -> firmware FMB v6 validation + PSRAM block decode
  -> bounded ambient projection/collision/icon pass
  -> POI regions reserved from street-label layout
  -> route and position marker composed above POIs

Nearby category selection + fresh position + active artifact receipt
  -> single-worker indexed nearest search (not limited to visible blocks)
  -> complete top-ten snapshot
  -> map icons + inset directional edge indicators/groups

iPhone configurable screen document / legacy UserDefaults
  -> Map / Map + Navigation POI switches for the selected screen
  -> revisioned document autosave / legacy full mask (setting 8 or 20)
  -> firmware screen-profile persistence and render mask
  -> render semantic invalidation
```

## Extraction and POI normalization

### Source conversion

Extend `tools/OSM_Extract/scripts/pbf_to_geojson.sh` with an explicit POI mode
selected by renderer format 5. It writes `${prefix}_points.geojson` from the
OGR `points` layer in addition to the existing lines and multipolygons.

Do not add the third OGR pass to target-1 through target-4 jobs. Update the
backend conversion command to pass the renderer format explicitly while
preserving selected-area source-index, relation-closure, cancellation, and
retry arguments.

The selected-area OGR profile must expose `amenity`, `shop`, and `name` as
attributes or retain them losslessly in `other_tags` for both points and
multipolygons. Add a real fixture test because the default and selected OGR
profiles can otherwise diverge silently.

### Prepared sources, shards, and area completeness

Integrate with current `MapPipeline._extract_pbf()` and
`map_platform/source_shards.py`; use the same pinned source snapshot, source
rectangles, checksum validation, cancellation, and resource reservations as
the ordinary map extraction. Respect all three shard modes:

- `disabled`: extract from the verified source PBF;
- `prefer-prepared`: use a sealed generation when it covers the complete
  request; only missing coverage may fall back to the pinned source PBF; and
- `prepared-only`: preserve the existing required-preparation failure behavior.

A corrupt or changed shard is an error, never a reason to bypass its checksum
with a source fallback. Preserve the request bounds of 64 cells / 8 GiB and
the 16 GiB free-space reserve; POI support does not justify raising them.
Keep the original source snapshot in artifact identity; record shard manifest
and selected-input digests in preparation evidence. If retaining POI geometry
requires a different shard algorithm, version that identity and regenerate its
sealed outputs rather than relabeling existing shards.

Extract tagged nodes and POI polygons from the general selected PBF. The
building index contains a specialized subset and its exported closure does
not retain arbitrary POI node tags. The recent exclusion of nonbuilding
multipolygon parents must remain valid for buildings without excluding a
shop/amenity polygon from the POI path. Any extra POI dependency closure must
be explicit, bounded, and tied to the original snapshot; it must not add an
unbounded country-source scan to a ready-preparation request.

Before enabling target 5, use real Osmium/OGR fixtures to compare normalized
records and section bytes from full-source and prepared inputs. Include
tagged nodes, nonbuilding amenity areas, concave polygons/holes, and relations
crossing both one-degree source-shard and 4,096-metre render-block boundaries.
Compute area anchors from the complete semantic geometry before block
ownership, and collapse duplicate OSM objects from merged shards. Byte-identical
output and counts are required regardless of the eligible source path.

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
artifact counts with independently parsed FMB v6 sections.

## FMB v6 POI section

Replace the PR's conflicting `docs/fmb-v5.md` with `docs/fmb-v6-pois.md` as the
normative byte-level POI contract before landing the writer and readers. The
current-main [topography artifact contract](https://github.com/seichris/open-bike-computer/blob/0f6fc8c6f0238d5508df199f2a50b1482b62ca1d/docs/topography-artifact-format.md)
continues to own FMB v5 and contour section 5.

### Compatibility shape

- Magic/version is `FMB\x06`.
- Base polygon/polyline bytes keep their FMB v2 layout.
- Section types 1-3 keep the FMB v3 string, shaped-run, and road-label layouts.
- Section type 4 keeps the FMB v4 building layout.
- Section type 5 keeps the FMB v5 contour layout and limits. Its content follows
  the signed layer discriminator: normal validated contours when included,
  canonical empty bytes only for an explicitly no-elevation artifact.
- The `EXT6` directory contains exactly six ordered, critical, contiguous,
  CRC-protected sections.
- Section type 6 is the POI section.
- A target-5 block with no POIs still has a valid zero-count section 6.
- FMP remains legacy/developer-only and gets no POI representation.

The current OSM writer emits FMB v2-v4, while
`map_platform/topography_artifacts.py` upgrades FMB v4 to v5 for target 4.
Extend the shared directory encoding/validation boundary to v6 without
changing the target-4 upgrade path. Compose section 5 and section 6 explicitly;
do not let a POI writer erase contours or let the contour upgrade erase POIs.
Build the Nearby index only after final section offsets are known. Preserve
v3-v5 golden vectors and the contour validator. Some firmware helpers still use
`V3*` names; do not assume
the whole parser has already been made format-neutral.

### Logical section-6 layout

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
OSM IDs remain generator/audit data and are not copied into the device block.
Nearby uses `(artifact receipt, block coordinates, record ordinal)` as stable
identity, sufficient for selection/highlighting within an immutable artifact.
No identity survives map replacement without reconciliation.

### Explicit target selection

Change `write_fmb()` to receive an explicit renderer target. It must not infer
FMB v6 only from a non-empty POI list: a valid target-5 block with zero matching
POIs still needs FMB v6 and section 6. Target-to-block mismatches are hard
errors. Include POIs in the block-emission emptiness check so a block containing
only POIs is not dropped.

The block-size limit remains 2 MiB. POI records have their own count bound and
do not consume the legacy generic-feature count, but all decoded allocations
remain subject to the existing PSRAM and complete-block validation gates.

### Nearby spatial index, profile 1

Add exactly one signed file at
`VECTMAP/<mapId>/assets/nearby-pois.fpi` for target 5. It is an acceleration
index of section-6 blocks, not a second POI database or an unsigned SD cache.
The backend constructs it from the final validated FMB files and checks a
one-to-one entry for every block containing POIs; no empty block needs an entry.
An empty map has a valid zero-entry index. All source POI coordinates stay in
section 6, so there is no duplicated point truth to drift.

Specify `FPI1` in the normative format document before implementation:

- a 16-byte little-endian header: four-byte magic, uint16 record size (32),
  uint16 reserved zero, uint32 entry count, uint32 entry-table CRC;
- fixed 32-byte entries: two signed int32 block-grid coordinates (not metre
  origins), uint32 category mask, five uint16 category counts, uint32 POI section
  offset, uint32 POI section byte length, and uint16 reserved zero;
- strict lexicographic grid ordering, no duplicates, exact counts/mask/offsets
  matching the referenced validated block, and zero reserved fields;
- at most 16,384 entries, hence 524,304 bytes including the header. A larger
  request fails with a typed limit error until a new qualified profile exists;
- grid coordinates resolve through the normal safe block-path mapping and
  must reference a file in the same signed manifest. No arbitrary paths or
  external file references are accepted.

The independent backend, iPhone, and streaming installer validators must agree
on index integrity and block correspondence. Include the index in file hashes,
byte budgets, catalog requirements, reuse receipts, transaction recovery, and
the all-or-nothing activation gate. Neither a signed-but-inconsistent summary
nor a missing index becomes an empty-result fallback.

The manifest's signed selection geometry/coverage remains authoritative for
search coverage; index entries alone do not establish geographic coverage.
Preserve polygon holes and corridor selections. Where current device metadata
only retains a bounding box, carry the bounded signed selection geometry into
target-5 active-map metadata rather than claiming the whole box was downloaded.

## Backend, signed artifacts, and catalog

### Renderer profile

Add renderer profile `map-pois-v1`, format 5. Schema 3 makes optional generated
layers explicit, rather than inferring them from a numeric format threshold:

```json
{
  "features": ["3d-buildings", "map-pois", "street-labels"],
  "optionalFeatures": ["contours"]
}
```

Here `features` are required in every target-5 artifact; `optionalFeatures` are
supported only when explicitly requested and separately approved. Jobs include
an immutable `requestedFeatures` set: the required three, normally plus
`contours`. Only these two exact sets are valid. The generated artifact reports
its exact feature set, not the whole supported set, and must match the request
and signed layer discriminator. Existing target-1 through target-4 requests
and schema-1/2 policies retain their current shapes and semantics.

Replace numeric range assumptions with exact feature predicates. Building
preprocessing is shared by targets 3, 4, and 5; contour generation runs for
target 4 and target 5 with requested contours; POIs belong to target 5. In
particular, `format >= 4` must never mean topography unconditionally. Audit the
backend, firmware, Swift reader, catalog, and promotion paths for assumptions.

Target 5 reuses immutable target-3 building block-cache entries when their
source/rules identity matches. POI bytes are composed separately and are part
of the target-5 artifact identity. Final target-3, target-4, and target-5
artifacts are not interchangeable reuse candidates.

Extend both the early finished-map lookup and the final artifact key. Include
POI/index profile/category configuration, extraction/normalization algorithm,
exact requested features, and, for contours, the verified DEM/preflight and
topography identities, plus source snapshot and producer identity before
accepting a hit. A no-contours artifact cannot satisfy a combined request or
vice versa. A target-3
building cache hit must still run POI extraction/composition. A target-4
topography pair receipt cannot satisfy a POI request. Verify reused POI section
bytes and counts against their immutable receipt; a warm cache must not skip
the new validation. Preserve current installation ownership and typed misses
when candidate bytes or identities disagree.

### Validation and manifest construction

Extend `map_artifact_validation.py` to parse FMB v6 independently of the
generator. Require:

- FMB v6 for every target-5 `.fmb` file;
- exactly one matching FMA1 asset;
- valid label fingerprint/glyph/language references;
- valid FMB v4 building semantics inside section 4;
- valid section 5 and exact topography metadata/companion behavior for the
  declared contour availability;
- valid required POI section 6 and the complete matching FPI1 block index; and
- recomputed building, contour (when included), and POI summaries matching the
  signed manifest.

Update manifest parsing, pack validation, build identity, reuse identity,
download grants, catalog reader requirements, and API generation-capability
documents for format 5 and `map-pois` without changing target-4 topography
requirements.

The geographic `mapId` remains geographic. Renderer target, POI profile/config,
producer build, and source snapshot affect artifact and signed-manifest identity
through the existing target/build-identity paths.

### Rollout policy

Introduce generation-policy schema 3 with formats 1-5, an exact `map-pois-v1`
required/optional feature contract, and separate authorization for requested
contours. POI approval alone must not unlock elevation processing. Retain the
topography installation allowlist and promotion evidence for the combined
variant; never inherit approval merely from target 4 being readable. Keep
schema 1's formats 1-3 and schema 2's formats
1-4 unchanged: current `GenerationProfilePolicy.load()` enforces those exact
sets, so appending target 5 to the existing v2 file would fail startup. Carry
forward disjoint global/canary/disabled lists and explicit deployment config
selection. Use a new policy file, provisionally
`generation-profile-policy-v4.json`: the existing
`generation-profile-policy-v3.json` still has
schema 2 and prepares a distinct topography rollout. The production Compose
lock selects v1 and development selects v2 at this baseline; the v3 file's
presence is not evidence of global topography activation. Initially:

- an explicit installation allowlist/canary in development;
- disabled in production until complete qualification, then a distinct
  production canary; and
- not globally available in production until the complete hardware gate passes.

Do not silently retry a target-5 request as target 3 or omit requested contours.
If elevation coverage is unavailable, return a typed failure and offer a
separate, user-confirmed no-contours request with its own immutable identity.
A rejected target-5 job
must keep its request ID/idempotency identity and return the existing typed
renderer-capability error. Publish per-installation allowed optional features,
so the app cannot mistake profile availability for contour authorization.
Qualify/promote combined target 5 before releasing it as the default new-map
path; a globally available no-contours profile is not sufficient for that gate.

Keep current durable queue admission, public `queuePosition`, typed
`map_queue_full` / `installation_queue_full` responses, request idempotency,
and cancellation. Historical map-cost metadata is not an active budget model.
Add a measured target-5 preparation-estimate cohort only after recording POI
stage costs; do not label a target-3 estimate as validated POI performance.

Backend code changes follow the digest-pinned image promotion workflow in
`AGENTS.md`. If the signed worker moves, update and satisfy the map-stream
hardware gate before production promotion.
The checked-in worldwide build-101 approval is bound to its existing worker,
producer, app, and firmware identities. It provides no approval for target 5;
retain that production lock until the new POI identities pass their own gates.

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

New firmware accepts FMB v1-v6. It never treats an unknown/newer block as an
empty legacy block. Target 5 requires label profile 1, building profile 1, POI
profile 1, index profile 1, and the exact target-5 layer-discriminated roles.
Both valid variants require the contour parser; included contours must retain
their existing bounds, source checks, and independent visibility behavior.
Target 4 continues to require its contour profile and source receipts.

Extend `targetMetadataMatches`, active-pointer serialization/readback, and the
stream activation journal with the POI fields. Preserve main's recovery of the
verified previous map when the active pointer is missing, unreadable, or fails
readback. Include contour availability and index identity/health in that
transaction. POI section/index failure must retain the previous map and its exact
profile/receipt identity, whether that map is target 3, 4, or 5. The app's
fresh authenticated reconciliation must decide completion/retry; a successful
background upload alone does not prove activation.

### Bounded placement and drawing

Add pure host-testable POI selection/layout code, separate from LVGL and SD I/O.
For each ordinary ambient-map render:

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

Use the render context's presented position for ranking and collision
reservations. Current main derives prediction from the GPS source's capture
time, freezes expired/unknown samples, and dims the stale marker. POI layout
must not observe the BLE arrival time as a new fix or force a new camera pose
while the last complete map remains displayed.

### Indexed nearest search on the map worker

Add host-testable `nearbyPoiQuery` logic separate from LVGL. Input is the active
artifact receipt, immutable FPI1 index, fresh source position, selected-category
mask, radius, and query generation. Use direct WGS-84 distance for ranking, not
Web Mercator metres as physical distance. Include high-latitude, antimeridian,
and block-boundary fixtures.

1. Filter block summaries by category and conservative geographic distance lower
   bound. Order relevant blocks by lower bound. Never discard a block on an
   overestimated bound; calculate from geographic block bounds, not a center
   distance or uncorrected projected coordinates.
2. Read only the validated section-6 ranges through the **existing map worker**,
   in batches of at most 256 records, yielding to render/activation/control jobs
   between slices. Limit work per slice to 4 ms of processing plus at most one
   bounded SD read; measure I/O latency separately because it is not a hard
   real-time guarantee. Do not load unrelated geometry or evict the accepted
   render's block ownership to perform a search.
3. Retain a heap of at most ten matching points, keyed by exact direct distance
   and stable block/record identity. Category priority and ambient max-zoom/rank
   must not bias nearest results.
4. Finish only when all remaining lower bounds exceed the tenth distance, or
   every block inside the requested radius has been exhausted. For fewer than
   ten, exhaust all eligible blocks. If interrupted/resource-limited, report
   cancellation or an error, not a falsely complete nearest-ten set.
5. Publish one immutable snapshot tagged with artifact, query, and source-fix
   identity. Reject results from an old category/radius request, map activation,
   or departed screen. A fresh location does not mutate an in-flight query.

Budget index, frontier, result, and scratch memory explicitly: the profile-1
index ceiling is 524,304 bytes; the frontier has at most 16,384 compact entries;
query-owned allocations must fit a 768 KiB PSRAM ceiling and fixed small worker
stack usage. Allocation failure preserves the last complete map frame and
reports Nearby unavailable. Never silently increase these limits or fall back
to a UI-thread/global filesystem scan. Dense-city timing and memory qualification
must pass on both boards before production capability advertisement.

### Nearby map and perimeter layout

The accepted query supplies at most ten results to a separate pure layout pass.
It uses the accepted camera, actual visible crop/board clip shape, reserved UI
rectangles, and the same source-age discipline as ordinary map rendering.

- Project in-view results normally, irrespective of ambient category toggles
  or max-zoom. Classify outside/behind-camera points safely; obtain edge
  directions in the camera-oriented map plane without dividing by a negative
  perspective depth. Clip the whole icon/distance footprint to the usable
  perimeter, including the circular display's curved edge.
- Lay out on-map markers and edge groups deterministically, with bounded
  tangent displacement and hysteresis. Group only nearby projected positions
  or similar bearings; never place a result on the opposite edge to make room.
  Arrows retain actual direction even when symbols shift for spacing.
- Use a compact count badge for collisions, preserve each result's stable ID,
  and allow group expansion to the bounded category/distance chooser. The
  chooser pauses reranking until closed; it never invents POI names or routes.
- Update direct distances from a captured fresh fix, throttle text changes, and
  freeze/mark stale on GPS expiry. Do not combine a newly rotated edge overlay
  with an old accepted camera/base frame.
- The render/result generation, selection mask, index receipt, and layout mode
  enter cache keys and hit-test identities. Touch handling consumes the same
  published snapshot that was drawn. Controls do not intercept screen-switch
  gestures outside their defined bounds.
- Cancel work and clear selection/highlight references on map replacement;
  Nearby does not change route guidance or saved ambient visibility preferences.

### Nearby screen registration and state

Reserve `screen_types.nearby = 6` in the generated BLE contract and add an
internal Nearby tile separately from that wire ID. Extend the firmware screen
registry, default/order policy, configurable-screen supported-type mask, payload
encoder/decoder/validator, and Swift enum/editor together. Use a version-1
16-byte map-profile payload for Nearby, reusing the ordinary Map fields and
validation; categories/results are transient state, not payload fields.

Advertise type 6 only with complete `map_pois` and screen-configuration support.
Keep the document schema/CRC/revision flow unchanged; type masks are the forward
compatibility gate. Existing documents and enabled order remain unchanged.
Offer **Add screen → Nearby** on compatible devices, and include it in fresh
device defaults without changing the existing default landing screen. The
phone's Nearby editor exposes map style/contours, not a second persisted copy
of the picker selection. Legacy devices keep their current screen IDs/masks.
An app connecting to older firmware must not send a cached type-6 document;
retain local preferences and show incompatibility instead of destructive rewrite.

Within each Nearby instance, the selector/result mode is a local state machine.
Opening results uses that instance's map profile and returns to its own picker;
do not switch to an arbitrary Map instance or overwrite a navigation profile.

### Diagnostics

Extend renderer diagnostics with bounded counters and timings:

- candidate, accepted, collision-rejected, offscreen, and capacity-deferred
  POIs;
- accepted counts by category;
- POI gather/layout/draw milliseconds; and
- decoded POI records/bytes for loaded blocks.

Also record aggregate query slices/blocks/records, completion/cancellation,
result count, edge/group count, search duration and query memory high-water mark.

Keep production logs aggregate and rate-limited. Do not log rider coordinates
or every source POI.

## BLE visibility and persistence contract

### Capability

Add `map_pois` at CAP2 bit 31 with minimum client version 29 in
`protocol/ride-ble-contract-v1.json`, then regenerate the Swift and C++ protocol
files. Update capability golden vectors and Watch/iPhone compatibility tests.
Bit 31 must be encoded/decoded as an unsigned 32-bit mask, with an explicit
high-bit golden vector; avoid signed-shift overflow in Swift and C++. This uses
the final CAP2 feature bit. Any later feature needs a versioned extension,
not a recycled CAP2 bit.

Firmware advertises the bit only when the complete target-5 reader, installer,
renderer, visibility, persistence, index lookup, and Nearby path is present.
The bit is not a claim
that the active map contains POIs; active renderer target/status remains the
map-data signal.

### Visibility masks

Extend `map_profile_protocol.hpp` with named bits 14-18 and a combined POI
mask. Preserve contour bit 13 and the existing extended-marker bit 12. The
marker remains required when a current app sends extended masks.

Update `normalizedFeatureVisibilityMask()` so:

- legacy masks still synthesize Service Roads and Tracks exactly as today;
- current masks retain recognized road, contour, and POI bits under their
  existing normalization rules; POI transmission is gated by the authenticated
  connection's negotiated capability;
- unknown/reserved bits are discarded; and
- overlay bits 8-9 remain global and owned by Map setting ID 8.

No setting packet changes are needed: IDs 8 and 20 already carry signed 32-bit
values. Add the new masks to protocol/persistence/redraw host tests and ensure
both profile changes invalidate map semantics immediately.

For configurable screens, update all three masks together:

- firmware `screen_configuration_protocol::ALLOWED_VISIBILITY_MASK`;
- Swift `DeviceScreenMapProfile.allowedVisibilityMask`; and
- firmware `map_profile_protocol::VISIBILITY_RENDER_FEATURE_MASK`, used by
  `screen_configuration.cpp::applyProfile()`.

The existing document already stores `UInt32` visibility per instance. Preserve
its revision, CRC, validation, autosave, conflict, and acknowledgement protocol.
Test that selecting each of two instances of the same screen type keeps its
own POI choices; accepting the document without rendering its bits is a failure.

### Firmware NVS

Continue storing legacy complete masks in `visMask` and `navVis`, and
configurable instance masks in the existing screen document persistence.
Replace magic default values with named default masks. Do not add five
independent NVS keys or a one-time rewrite of existing masks.

Fresh NVS defaults include all five POI bits for Map and none for Map +
Navigation. Existing stored masks remain unchanged until the owner app sends a
new negotiated profile. New configurable instances follow the same Map-on /
Map + Navigation-off defaults; reading an existing instance preserves its mask.

## iPhone model, settings UI, and transfer compatibility

### State and persistence

The primary path is `DeviceScreenConfigurationController` plus the selected
instance's `DeviceScreenMapProfile.visibilityMask`. Add controls to
`DeviceScreensSettingsView.swift` using its existing binding/controller update
path. The controller remains the only authority for document revisions,
autosave, reconnect, conflicts, and saved-state feedback.

For the legacy screen-settings path, add five `@Published` Boolean properties
and UserDefaults keys per screen type in `BLEManager.swift`. Defaults are all
on for Map and all off for Map + Navigation only when those keys are absent.
Do not broadcast the legacy defaults over a device's existing configurable
screen instances during capability negotiation.

When constructing setting 8 or 20:

- include bits 14-18 only after authenticated capability negotiation reports
  `map_pois`;
- retain the user's Boolean choices when an old device is connected;
- set the existing extended marker for every current extended mask; and
- trigger one full profile resend when POI capability first becomes available
  on a legacy-profile connection. Configurable devices follow the document
  controller's current revision/reconciliation flow instead.

Old firmware receives the same road/terrain mask it receives today. A capability
downgrade clears only connection support state, not saved POI preferences.
Apply the same capability gate to serialized configurable documents: old
firmware must not receive unsupported POI bits or enter an autosave retry loop.

### UI

Under both Map-style screens add a **Points of Interest** section with:

- Shops;
- Restaurants & Cafes;
- Public Toilets;
- Gas Stations; and
- Bicycle Shops & Repair.

Show the section only when the connected firmware advertises `map_pois`. Enable
the switches only when the active map reports renderer format 5, POI profile 1,
and verified health. Otherwise show a regeneration explanation and
**Download Active Map Again**, matching the established street-label workflow.
Preserve contour inclusion when upgrading an active target-4 map. Present
**Contours** beside the POI layer section; one switch never disables the other.
If elevation was explicitly omitted, disable the contour switch with
**Elevation not included in this map**, not an instruction to activate a
different POI/contour map. The iPhone's companion overlay remains bound to the
combined artifact's receipt and saved-map lifecycle.

Each configurable-screen toggle updates the selected instance and uses the
existing document autosave flow. The legacy UI sends its full setting-8/20
mask. Both routes must converge after acknowledgement, reconnect, and screen
switch without duplicating or clobbering per-instance preferences.

Expose **Nearby** in Add Screen only for the negotiated supported screen type.
Its on-device category-picker/result flow is described above; this change does
not add an independent iPhone Nearby search implementation.

### Map requests and saved artifacts

After production target 5 is globally available, change ordinary new custom
bbox, polygon, route-corridor, and regeneration requests from target 3 to
target 5 with explicit requested features, normally including contours.
Existing saved target-4 maps remain usable; new topographic requests use the
combined target-5 variant after its rollout gate. Retain the legacy target-4
development/compatibility request path but do not present two competing map
types as the normal UX. Include target 5 in:

- generation-capability validation;
- request encoding and typed rejection tests;
- signed manifest decoding;
- FMB header/asset validation;
- saved-map metadata;
- catalog reader capabilities and requirements; and
- transfer compatibility policy.

Saved targets 1-4 keep their current rules, including target-4 companion
association. Target 5 requires all of:

- street-label capability;
- OSM 3D-building capability;
- topographic-contour reader capability (both target-5 variants carry section
  5 and the new capability contract includes its reader); and
- map-POI capability, including index-profile compatibility.

Treat an inconsistent capability response as incompatible instead of assuming
the newest bit implies missing older bits. The transfer is rejected before
opening the device-hosted upload session.

Track `activeMapPoiProfileVersion`, `activeMapPoiIndexProfileVersion`,
`activeMapPoiDataHealthy`, and signed contour availability from the
authenticated device status. Enable controls only when capability, active
target 5, POI/index profile 1, and health all agree. Use the existing contour
health plus layer availability to gate its switch independently. Clear
connection availability on disconnect, candidate activation failure, removal,
or activation of another
format; reconcile it from the verified active map so rollback cannot leave
stale target-5 UI enabled. Zero records in valid sections remain healthy.

## Reintegrating the existing PR with current main

This is required before treating PR #378 as an implementation of the revised
plan. It is not completed by this documentation refresh.

1. Fetch and merge the exact current `origin/main` into the PR branch in its
   isolated worktree. Preserve the topography implementation wherever it
   conflicts with the old POI target-4 path; preserve unrelated main changes
   such as configurable screens, firmware OTA, source-shard preparation,
   current queue admission, and active-pointer readback/recovery. Do not
   resurrect the implemented plan documents removed from main in #545.
2. Remove the PR's conflicting POI `docs/fmb-v5.md` and target-4/section-5
   golden artifacts. Keep current main's FMB v5 contour contract, schema-v2
   generation policy, generated BLE mappings, and target-4 companion path.
3. Migrate the existing POI extractor, writer, backend, firmware, iPhone, and
   tests to target 5/FMB v6/section 6, bits 14-18, CAP2 bit 31/client 29.
   Audit every numeric `>= 4` or `== 4` format check for feature meaning,
   every configurable-screen allowed/render mask, and all early reuse paths.
   Implement the combined/no-elevation discriminated contract, FPI1 index,
   requested-feature policy, and Nearby screen type 6 as new work: these are
   not supplied by renumbering the original visibility-only implementation.
4. Keep the coordinated prospective hillshade reservation update in the
   topography plan: target 6/FMB v7/section 7 and visibility bit 19. Preserve
   target-4 topography and recheck for any newer deployed contract before
   resolving conflicts.
5. Register POI tests and Swift dependencies in `tools/development/`; preserve
   main's shared runner, CI routing, report isolation, and evidence workflow.
6. Run the implementation tests below, inspect the fresh PR CI Gate, and keep
   production/physical qualification separate. Do not promote the service,
   flash a board, or mark the draft PR ready merely because merge conflicts
   are resolved.

## Delivery phases

### Phase 1 - Normative contracts and golden fixtures

1. Add `docs/fmb-v6-pois.md`, category/bit mappings, target-5 manifest rules, and
   BLE capability documentation. Specify combined-layer availability, requested
   features, FPI1 bytes/limits, and screen type 6 with its payload.
2. Add synthetic OSM fixtures containing point, way, relation, lifecycle,
   overlap-precedence, boundary, invalid-geometry, and dense-block cases.
3. Add cross-language FMB v6, FPI1, and manifest golden vectors for combined,
   explicitly no-elevation, and zero-POI/flat-terrain cases, plus target-4
   contour regression vectors and board-sized Nearby layout fixtures.

Exit criterion: Python, C++, backend, and Swift tests agree on category codes,
section/index bytes, counts, layer availability, target version, visibility
bits, capability bit, and Nearby screen-type encoding.

### Phase 2 - Extractor and independent artifact validation

1. Add the target-5 point-layer conversion and `poi_pipeline.py`.
2. Add FMB v6 composition with explicit target/layer selection, contour pipeline
   reuse, complete FPI1 indexing, and POI statistics.
3. Add backend FMB v6 parsing, summary recomputation, manifest validation, and
   schema-3 target-5 generation policy behind development/canary controls.
4. Prove target-1 through target-4 artifact bytes/fixtures remain unchanged.
5. Prove full-source/prepared-shard POI equivalence, nonbuilding area retention,
   and warm/cold reuse identity without adding country scans to ready inputs.

Exit criterion: a deterministic target-5 pack built from the fixture contains
the expected five category counts and independently validates; corruption and
limit fixtures fail with typed errors.

### Phase 3 - Firmware reader and renderer

1. Add signed target-5/FMB v6 install validation and runtime decode.
2. Add bounded POI selection, collision, icons, street-label reservations, and
   diagnostics.
3. Add visibility bits, NVS defaults, render invalidation, and CAP2 bit 31
   without changing contour bit 13 or configurable-screen bit 26.
   Include the screen-document allowed mask and runtime render mask.
4. Add Nearby picker/result state, worker-owned nearest search, edge indicators,
   distance formatting, collision groups, and cancellation/coverage/GPS states.
   Validate count correctness against a brute-force reference and board-sized
   render/hit-test fixtures before on-device qualification.
5. Build ordinary and production firmware for both board targets through the
   repository build/CI paths.

Exit criterion: host tests pass, all four firmware profiles build, legacy and
topographic maps render unchanged, target-5 layers toggle independently, and
Nearby produces correct deterministic results and layout in synthetic tests.
This is not yet physical acceptance.

### Phase 4 - iPhone settings and target-5 delivery

1. Add capability parsing, per-instance document autosave, legacy-profile
   persistence, mask composition, and UI in both settings paths.
2. Add active-map availability/status handling and regeneration UX.
3. Add target-5 requests, saved-map/catalog validation, and pre-transfer
   compatibility gates, including requested contours and same-receipt companions.
   Add Nearby screen configuration without persisting its transient selections
   into ordinary map-layer preferences.
4. Run portable Swift tests and unsigned iOS build.

Exit criterion: connection/reconnect simulations converge on the same masks;
old devices never receive POI bits; target 5 is refused before transfer to
incompatible firmware; and ordinary new-map request modes select combined target
5 only after the service rollout prerequisite, with explicit user choice for
unavailable elevation.

### Phase 5 - Integrated rollout and physical gates

1. Publish the backend worker through the digest-pinned development channel.
2. Generate and sign known combined and explicitly no-elevation target-5
   fixture/real-area artifacts; verify counts, index, contours/companion, bytes,
   manifest, stream, download, and activation separately.
3. Complete physical rendering and persistence gates on both Waveshare targets.
4. Promote combined target 5 from production canary to global generation only
   with its topography approval; POI-only eligibility cannot satisfy this gate.
5. Release the ordinary iPhone target-5 request path only after that promotion.

Exit criterion: the acceptance matrix below is recorded with exact backend
image digest, artifact receipt, firmware SHA/profile/board identity, app build,
and map source snapshot.

## Test and validation matrix

### Shared check entry point

After integrating main, start at the repository root with:

```sh
tools/dev-check --plan
tools/dev-check
tools/dev-check --suite ios --level full --fresh --evidence
tools/dev-check --suite firmware --level full --board 175 --evidence
tools/dev-check --suite firmware --level full --board 206 --evidence
```

Identify the connected board before build/device actions under the current
`AGENTS.md`; the full qualification matrix names both targets. The full iOS
suite covers simulator contracts and unsigned Debug/Release app containers.
Evidence mode requires clean committed source and retains corresponding
symbols; retain the check reports and final linker size/partition evidence.
Ordinary development builds can use the runner's incremental local state.

Register new POI checks in `tools/development/checks.json` and add Swift
dependencies to `tools/development/swift-sources.json`, which are shared by
local execution and CI. Do not recreate compiler lists in the old PR workflow.
The backend/deploy/extractor suite IDs are `map-backend-tests`,
`map-deploy-tests`, and `osm-tests`; the commands below are their existing
focused entry points. Missing prerequisites are blocked checks, not passes.
Neither the presence of this section nor a documentation refresh proves any
of these implementation checks has run.

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
- FMB v2/v3/v4/v5 golden regressions remain byte-identical, including the
  nonempty contour section and the separate iPhone `.btopo` companion.
- Combined FMB v6 preserves both nonempty contour and POI sections. Include
  flat-terrain/zero-POI blocks and reject an omitted layer disguised as empty.
- FPI1 empty/max/overflow/CRC/order/duplicate/path/offset/count fixtures; its
  entries cover every nonempty POI block exactly once and no other artifact.
- Full-source versus one/multiple shard extraction produces identical POIs.
  Missing shard coverage uses the existing allowed fallback; corrupt/changed
  shards fail. Prepared building closure does not discard a nonbuilding POI
  area or duplicate a tagged node; missing extraction dependencies must not be
  reported as harmless malformed source geometry.

Run at minimum:

```sh
python -m unittest discover -s tools/OSM_Extract/tests
```

### Backend and signed-stream tests

- Format-5 generation policy, exact development allowlist, production-disabled
  state, required/optional feature sets, and independent contour authorization.
- Combined requests with unavailable elevation fail explicitly; no retry may
  silently drop contours. No-elevation artifacts cannot satisfy combined-map
  cache hits, grants, or catalog requests, and vice versa.
- Target-5 pipeline command includes point conversion and target-3 building
  preprocessing/cache semantics.
- POI report versus independently parsed artifact count mismatch rejection.
- Manifest count-sum, profile, asset-role, FMB-version, producer-identity,
  request/reuse identity, and catalog reader tests.
- Signed map-stream target-5 golden vector plus all malformed/truncated cases.
- Target-1 through target-4 API, artifact, companion, and catalog compatibility.
- Target-5 promotion discovery, manual conversion, grants, and catalog publish
  reject unauthorized profiles without weakening the target-4 topo gate.
- Exact/subset/cache lookup never returns a target-3/4 pack for target 5 or
  ignores changed POI rules/source identities; ready preparation avoids a new
  full-source scan, and restored inputs are verified before use.
- Schema-1/2 policies keep their exact accepted profile sets; schema 3 rejects
  duplicate formats or profiles, wrong required/optional/requested features,
  unauthorized optional layers, and overlapping channel lists.
- Queue status, full-queue errors, cancellation, and idempotent retry remain
  consistent across target-3/4/5 requests.

Run the repository backend/deploy suites from `map-platform/backend`:

```sh
python -m unittest discover -s tests
python -m unittest discover -s ../deploy/tests
```

### Firmware host/build tests

- Stream and runtime FMB v6 parsers accept the same golden bytes.
- All section/count/reference/CRC/bounds failures reject before activation.
- FPI1 correspondence, manifest/contour availability, and index receipt checks
  agree across streaming installation and runtime. Missing/corrupt index is an
  activation error; a valid zero-entry index produces a healthy empty search.
- Visibility normalization and NVS fresh/existing-profile behavior.
- Configurable-screen allowed-mask, document round-trip, and runtime render
  mask preserve POI bits independently for multiple instances and contour bit
  13; existing profiles are not overwritten by new defaults.
- CAP2 client-version gating and feature-vector tests.
- Per-category icon selection, projection, near-plane clipping, collision,
  rank, capacity, label reservations, and stable ordering.
- Route/marker foreground invariants and render cancellation/no-partial-frame
  behavior.
- Flat, rotated, and every supported bird's-eye perspective.
- FMB v1-v5 parser/render regressions, including target-4 contour visibility
  and active-map status.
- Source-age expiry and delayed/repeated GPS input keep the marker and POI
  reservations consistent with the accepted camera.
- Failed active-pointer readback, truncated pointers, interrupted activation,
  and corrupt POI metadata restore the verified prior target-3/4/5 map through
  main's transaction journal; rejected writes do not report completion.

Nearby host/surface tests also cover:

- nearest-ten equivalence to a brute-force geographic reference across multiple
  categories, blocks beyond the viewport, dense/empty areas, equal distances,
  high latitudes, antimeridian, and block/coverage boundaries;
- fewer than ten, explicit radius expansion, coverage holes, rider outside the
  installed selection, and no fresh GPS;
- query slice/memory bounds, rendering priority, slow/failed SD reads,
  cancellation and late-result rejection on map/category/screen changes;
- ambient zoom/category settings never suppress an explicitly requested Nearby
  result, and the session never writes those saved settings;
- all edges/corners, actual circular and rectangular clipping, distance-text
  bounds, near-plane handling, every orientation/perspective, pan/zoom, transition
  hysteresis, dense groups and correct drawn-snapshot hit testing;
- screen type-6 encode/decode, old supported-type masks, defaults/order,
  per-instance state, picker multi-select, zero-selection action disabling, group
  chooser selection and return to categories without stopping an active route.

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
- Exact setting-8 and setting-20 masks for each toggle and both profiles;
  contour bit 13 remains independent of POI bits 14-18.
- No POI bits sent to old firmware; one negotiated resend to new firmware.
- Active target-3/4 versus target-5 settings availability; upgrading a contour
  map retains contour inclusion and enables independent contour/POI switches.
- Ordinary new bbox, polygon, corridor, and regeneration requests use target
  5 only after combined-layer promotion. Requested features, contour approval,
  unavailable-elevation UI and explicit opt-out have exact request identities.
- Typed target-5 service rejection does not silently retry target 3.
- Saved target-1 through target-5 and inconsistent-capability transfer matrix.
- Manifest/catalog/FMB v6/FPI1 validation and active-map status reset; target-4
  companion association remains unchanged and target-5 companions must belong
  to the same combined receipt before MapKit contour overlays are enabled.
- Configurable-screen autosave acknowledgement, revision conflict, reconnect,
  fresh-instance defaults, existing-document preservation, and two same-type
  instances with different POI masks. Legacy resends must not overwrite them.
- Interrupted transfer and fresh device-status reconciliation distinguish a
  completed target-5 activation from a successful upload followed by rollback.
- Nearby Add Screen, type-6 payload round trips, capability downgrade/reconnect,
  existing screen-order preservation, and no destructive cached-document resend
  to firmware that does not advertise that type.

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

Treat the 1.75-inch and 2.06-inch boards as separate gates. Follow current
`AGENTS.md`: immediately before an authorized flash, identify the board by
stable serial and verify the artifact, Git SHA, serial, and environment. A
planning or build-only task does not include a device write.

For each board:

1. Install the exact target-5 map and confirm activation/status identity.
2. At a fixed known coordinate, compare on-device category counts/positions
   against the generated fixture/reference preview.
3. Toggle each category independently on Map and prove the other four do not
   change.
4. Repeat on Map + Navigation with an active route and prove the route and
   marker stay visually dominant.
5. Verify zoom 0-5, north-up, course-up, and supported bird's-eye perspectives.
6. Reconnect the app and cold/warm reboot the device; confirm both profiles
   and multiple configured instances retain their independent choices.
7. Activate target-3 and target-4 maps and confirm legacy/topographic rendering,
   the regeneration UI, and contour/POI setting separation; then reactivate
   target 5.
8. Pan/zoom through a dense urban area while navigation/GPS updates arrive;
   record render time, deferred counts, internal heap, PSRAM, and frame
   freshness.
9. Run an extended navigation/soak session and confirm no reset, watchdog,
   partial frame, stale icon, or unbounded memory growth.
10. Independently toggle contours and each POI group in the same combined map.
    Verify a flat but contour-enabled area differs from a deliberate map without
    elevation, and validate the same-receipt phone companion separately.
11. Select one/multiple categories in Nearby; verify the nearest ten against
    known coordinates, including places outside loaded blocks. Read icon and
    distance at every edge, check overlapping groups, round-screen clipping,
    touch targets and perspective, and return to unchanged map preferences.
12. Exercise fresh/stale GPS, movement updates, downloaded-area boundaries,
    no results, radius expansion, interrupted queries and activation. Record
    query latency/memory and prove navigation/rendering stays responsive.

## Rollout and rollback

Roll out in this order:

1. development backend/worker with allowlisted target 5;
2. target-5-capable development firmware;
3. development iPhone build and physical gates;
4. production backend canary;
5. production firmware capability;
6. production target-5 global generation; then
7. iPhone release that requests target 5 for ordinary new maps.

Safe rollback levers are:

- disable POI switches/Nearby while retaining the valid target-5 map and its
  independently controlled contour layer;
- restore the previous known-good target-5 worker digest;
- keep target 5 canary-only before the iPhone production release;
- revert the iPhone new-map request target to 3 in a reviewed release; and
- continue installing saved target-1 through target-4 maps.

Do not advertise the capability from firmware that cannot validate every
target-5 section. Do not globally disable target-5 generation after shipping an
iPhone build that exclusively requests it without simultaneously providing a
compatible app rollback; silent target downgrade is intentionally forbidden.

## Expected implementation surface

| Layer | Primary files/modules |
| --- | --- |
| OSM conversion | `tools/OSM_Extract/scripts/pbf_to_geojson.sh`, selected OGR config |
| Source preparation | `map_platform/source_shards.py`, `prepared_source_catalog.py`, `pipeline.py`, `export_building_closure.py`, full-source/shard equivalence fixtures |
| POI normalization | new `tools/OSM_Extract/scripts/poi_pipeline.py`, new POI config and fixtures |
| FMB writer | `tools/OSM_Extract/scripts/map_format.py`, `extract_features.py`, `docs/fmb-v6-pois.md` |
| Backend | `generation_profiles.py`, new POI contract module, `pipeline.py`, `map_artifact_validation.py`, `manifest.py`, build/reuse identity and tests |
| Generation policy | schema-3 policy in `generation-profile-policy-v4.json`, v1/v2 schema compatibility, rollout/hardware gates, target-4 topo gate preservation |
| Firmware format/install | `mapBlockFormat.*`, `map_stream_parser.cpp`, `map_transfer.*`, parser/install tests |
| Firmware render | new POI block/layout/icon helpers, `maps.hpp`, `maps.cpp`, renderer diagnostics/tests |
| Nearby discovery | new FPI1 writer/readers and pure nearest-query/perimeter-layout helpers, existing single map worker, activation/status metadata |
| Nearby screen | `mainScreenTypes.hpp`, `mainScreenRegistry.hpp`, main-screen controller/UI, generated screen type 6, configuration payload models and tests |
| BLE/profile | `protocol/ride-ble-contract-v1.json`, generated protocol files, `map_profile_protocol.hpp`, `screen_configuration_protocol.hpp`, `screen_configuration.cpp`, persistence/redraw tests, `ble_navigation.*`, `docs/ble-protocol.md` |
| iPhone | `DeviceScreenConfiguration.swift`, `DeviceScreenConfigurationController.swift`, `DeviceScreensSettingsView.swift`, legacy `BLEManager.swift`/`SettingsView.swift`, offline-map models/manager, screen-configuration and navigation tests |
| Shared validation | `tools/development/checks.json`, `swift-sources.json`, `protocol/scenarios/` where relevant, development reports and build evidence |
| Map docs | `docs/map-stream-format-v1.md`, offline-map build/install and rollout documentation |

Exact helper filenames may change during implementation, but the separation
between source classification, wire-format validation, renderer placement, and
product settings must remain.

## Acceptance criteria

The feature is complete only when all of the following are true:

1. Target-5 extraction retains matching point and area POIs from the bounded
   Geofabrik source with deterministic category precedence and block ownership.
2. Every target-5 block is FMB v6 with valid contour section 5 and required,
   bounded, CRC-validated POI section 6. The signed contour discriminator,
   requested feature set, actual sections, and companion metadata agree.
3. Backend-recomputed POI counts match generator diagnostics and the signed
   manifest exactly.
4. New firmware reads targets 1-5; old firmware is prevented from receiving
   target 5 before transfer, while target-4 topography still works.
5. Map and Map + Navigation persist independent choices for all five groups,
   including multiple configurable instances of each type and the legacy
   profile path. Existing stored masks remain intact.
6. Old firmware never receives visibility bits 14-18, while capable firmware
   receives one convergent full profile after negotiation/reconnect.
7. The renderer uses the shared projection, bounded placement, deterministic
   collision rules, and complete-frame publication.
8. POIs never cover the route, current-position marker, or declared UI regions,
   and street labels avoid accepted POI icons.
9. Active legacy/topographic maps explain that regeneration is required to add
   POIs, without silently dropping contours. Corrupt target-5 sections/indexes
   fail activation instead of appearing empty.
10. All extractor, backend, C++, Swift, signed-stream, and compatibility tests
    pass on the exact implementation head.
11. Ordinary and production firmware builds pass for both the 1.75-inch and
    2.06-inch targets.
12. Physical category, persistence, dense-scene, navigation, and soak gates pass
    independently on both board families.
13. The digest-pinned backend promotion and map-stream hardware gate are
    complete before target 5 becomes globally available.
14. The production iPhone target-5 request path ships only after production
    generation is globally available.
15. Prepared/full-source paths, shard boundaries, and cold/warm reuse produce
    the same POI records without bypassing checksums or silently losing areas.
16. Active-map readback/recovery preserves the verified previous map after
    failed POI activation, and iPhone state converges to the authenticated
    active target and health.
17. One combined offline map renders contours and POIs with independent layer
    switches; changing them does not replace/rebuild the map. The explicitly
    no-elevation variant remains usable and clearly reports the missing layer.
18. Nearby supports multi-select and an explicit Show nearby action, then
    displays the true nearest ten total within the selected radius/downloaded
    area, even when some results are outside loaded/rendered blocks.
19. On-screen markers and off-screen direction/distance indicators account for
    every result exactly once, directly or in a group, without clipping text or
    hiding controls. Distances are explicitly direct metres/kilometres, not ETA.
20. Nearby obeys worker ownership, bounded memory/I/O, source-age, cancellation,
    coverage and no-result semantics; its temporary selection never overwrites
    saved ambient map choices or an active route.
