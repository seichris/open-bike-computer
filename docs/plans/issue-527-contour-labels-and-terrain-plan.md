# Contour labels and optional terrain views — issue #527

Planning baseline: `origin/main` at `0f6fc8c6f0238d5508df199f2a50b1482b62ca1d`, inspected 2026-10-02.
Issue: https://github.com/seichris/open-bike-computer/issues/527

## Delivery order

**Contour elevation numbers → hillshade → elevation tint and slope shading experiments → 3D terrain exploration.**

Updated scope, 2026-10-02: the maintainer requested all four steps in one PR.
Contour numbers belong in the existing Map and Map+Navigation screens. The other
views are opt-in copies of Map, using independent configured screen instances:
Hillshade; Tint & Slope (alternate palettes); and 3D Terrain exploration.
Implementation may proceed together; physical qualification and production
promotion remain separate per-feature gates. The 3D prototype is terrain-only,
without flat road/route overlays pretending to be draped navigation.

The sections below retain the design rationale and qualification roadmap.
They are not claims of completed physical validation.

## Current implementation and consequences

- FMB5 contour records already carry signed elevation metres and an index flag. Supported minor/index pairs are 20/100 m and 50/250 m. Device labels can use existing geometry without changing FMB5 solely to add elevation text.
- `esp32/lib/maps/src/maps.cpp` admits a bounded, index-first set of 128 contour records and projects them through the accepted camera. Contours draw after area fills and before roads. Existing street-label layout, collision reservations, font rasterization, and layout caching are useful infrastructure, but do not yet constitute contour-label placement.
- `map-platform/backend/map_platform/topography_companion.py` draws contour lines into transparent PNG tiles at z9–16, scales 1/2. The current tile-reference path drops elevation and keeps only index status and points. The strict `.btopo` schema/style is v1 and cannot silently acquire new tables or semantics.
- `TopographyCompanionStore.swift`, `BicinoTopographyTileOverlay.swift`, and `OfflineMapManager.swift` validate and bind companions to installed map content. Any successor must preserve that trust chain, offline restoration, replacement, and cache bounds.
- The iPhone resamples WGS-84 contour imagery for mainland-China MapKit presentation through `TopographyMapKitTileWarp.swift`. Apply the corresponding coordinate conversion to new label anchors; retain WGS-84 storage/device geometry and the existing cross-region suppression policy.
- `MapView.swift` inserts topography at `.aboveRoads`. [Apple's overlay-level contract](https://developer.apple.com/documentation/mapkit/mkoverlaylevel) places this above roads and below base-map labels. A transparent MapKit overlay is not currently a layer beneath Apple road artwork. Both road visibility and collisions with Apple-owned labels require an explicit feasibility/visual gate; do not claim total collision control from Bicino's own geometry alone.
- Existing source DEM acquisition is reusable, but contour-only output is insufficient for hillshade, slope, or terrain height. Preserve normalized elevation independently of contour geometry before introducing these products.
- Issue #509 remains open. Current source already has larger development map-wide limits than the original issue description; raising caps again is not the plan. Reuse its bounded tile/cache contracts for terrain. Labels do not depend on completing the entire 2,500 km² goal.
- Issue #389's original failed-benchmark snapshot is not the latest evidence: the September 4 comment on PR #384 records a passing exact-pair remote-debug sweep and soak. That historical pair does not qualify today's terrain build. Capture a fresh baseline for each candidate.

## Stage 0 — small baseline and design gate

Complete within the contour-label milestone, without a separate platform rewrite.

1. Freeze a repeatable Chengdu 2 fixture: exact map/content receipts, source policy and DEM identities, coordinate, route, zoom, bearing, pitch, brightness, device profile, firmware/app revisions, and capture procedure. Use the same fixture throughout the roadmap. The coordinate and artifact hashes must come from the actual saved map, not be invented in this plan.
2. Capture current contours-off/on behavior in Map and Map+Navigation, including dense roads, a ridge/valley, a block/tile boundary, and a no-data edge. Add a 50/250 m fixture and below-sea-level synthetic cases for correctness.
3. Measure baseline render P50/P95, presentation/flush and UI gaps, internal/DMA/PSRAM minima and largest blocks, allocation fallback, SD reads, GPS/BLE continuity, map bytes, generation time/memory, download and transfer duration. Record battery conditions separately.
4. Prove a small iPhone screen-space label overlay follows camera changes and pitch, uses the same China alignment, and reserves route/marker space. Verify available control over Apple base-map labels and roads. If strict collision acceptance cannot be achieved with the chosen MapKit integration, resolve that scope/design gap explicitly before declaring stage 1 ready; do not quietly redefine acceptance.

No hardware interaction is part of writing this plan. Before a later build/upload/device-debug action, confirm the connected physical board and use the repository's current build and device-identity workflow.

## Stage 1 — contour elevation numbers

### Rider-visible behavior

Selected index contours display values such as `800 m`, `900 m`, or `1250 m`. Minor contours remain unlabelled. Labels follow contour visibility; the first release does not need another user-facing switch. Density varies by projected spacing and zoom, with sparse labels on the round device. Labels stay upright and readable through rotation and tilt, and never take priority over navigation or street names.

### Placement and device implementation

1. Generate deterministic candidate anchors from index-contour geometry in world coordinates. Select locally straight runs, use arc-length spacing, and reject short, sharply curved, clipped, or near-plane-invalid candidates. Do not restart spacing at every block/record fragment.
2. For existing FMB5, derive anchors using a stable world-coordinate policy and bounded neighboring geometry. Deduplicate spatially across visible blocks using elevation plus quantized position/tangent; elevation alone is not a unique contour identity. New backend-generated anchors can use canonical pre-split contour identity, but device support must still work for already installed FMB5 maps.
3. Integrate contour candidates into the existing label-layout pass at lower priority than street labels. Reserve screen-space road corridors, route stroke plus margin, marker footprint, guidance UI, and the round screen edge. The current marker/UI reservations are a starting point; full road and route reservations are new work.
4. Project anchors with the same accepted camera and pose used by the visible map. Render text at a stable screen size, with a small halo or local contour-line gap. Avoid independently rotating or scaling the glyphs with the terrain surface. Recheck moving route/marker exclusions during presentation and suppress a conflicting contour label when necessary.
5. Preserve worker/UI ownership, semantic cancellation, full-buffer/full-refresh display behavior, existing contour admission, and bounded allocations. Cap candidates, placements, collision work, and glyph work explicitly. Cache keys must include contour content, zoom, camera, visibility, font/size policy, and relevant exclusions.
6. Verify digits, minus sign, space, and `m` are available on existing map/font combinations. Use a small firmware-owned numeric glyph path if needed rather than assuming street-name assets contain every elevation glyph. Missing glyphs must suppress labels without disabling the map.
7. Add counters for candidates, placed labels, seam duplicates, collision/capacity suppression, layout/draw time, and cache behavior. Define caps before benchmark runs; exact values are tuned from the fixture, not claimed as measured here.

### iPhone and companion implementation

Retain raster contour strokes and add a bounded, spatially indexed anchor/geometry layer in a versioned companion successor. Render elevation text at runtime in screen space. Baking numbers into PNGs alone is insufficient for upright pitched text and collision handling against a changing route.

- Carry elevation, stable anchor identity, position/tangent, zoom eligibility, and enough local geometry/reservations for placement. Share numeric formatting and placement fixtures with firmware; do not require identical pixel positions on different displays.
- Query only visible bounded tiles/anchors; deduplicate across tile edges and use display-point density independent of 1x/2x tile scale. Relayout during pan, bearing, pitch, and zoom changes with bounded work and stable placement.
- Keep contours below the label overlay and keep navigation above it. Use Bicino-owned road/route geometry for conservative reservations and assess Apple base-map interference explicitly.
- Introduce a new companion profile/schema and explicit artifact/capability negotiation. New readers support v1 and the successor; old readers must receive v1 or an explicit unsupported-feature outcome, never an unexpected schema. Update producer validators, signed artifact bindings, app reader, restore/replace/delete paths, and format documentation together.
- Existing device maps gain labels from their existing FMB5 data. Existing iPhone v1 companions remain usable as contour-only overlays until a trusted companion regeneration/update is available. Do not derive elevations from PNG pixels or mutate signed installed artifacts.

### Reviewable changes and acceptance

Suggested PR boundaries within this one milestone:

1. Shared fixtures, placement policy, telemetry, and companion contract/readers.
2. Firmware contour labels and collision integration.
3. Companion production, iPhone runtime labels, negotiation and lifecycle integration.
4. Qualification evidence, visual tuning, and deliberate rollout to the approved audience.

Contract support should land before producers emit successor artifacts. PRs 1–3 may remain feature-gated until both surfaces pass. None unlocks hillshade on its own.

Acceptance requires correct index elevations including negative/zero values; both interval pairs; stable repeat spacing; no duplicate or cut-off labels at seams; readable rotation/tilt in both screens; protected navigation/roads/street labels; offline iPhone reopen; legacy companion/map behavior; corrupt or oversized metadata rejection; and measured resource limits. Add host/Swift/backend tests for these behaviors and physical iPhone plus 1.75-inch daylight/motion captures. Simulator images and host tests do not substitute for the panel gate.

## Stage 2 — bounded offline hillshade

Physically qualify contour labels before promoting hillshade. Make one architecture decision after a small measured encoding comparison.

### Recommended architecture

Preserve a canonical normalized elevation tile cache on the backend and ship precomputed shade data to the device. Retain elevation server-side for future tint, slope, and 3D experiments; do not require every device download to include a height grid before a device consumer exists.

- Align with #509's deterministic metric grid, halo, half-open ownership, immutable DEM/policy/algorithm identities, verified cache receipts, and bounded tile processing. The necessary elevation tile contract is a dependency; the full large-area product milestone is separate.
- Record horizontal CRS, vertical datum, sampling resolution, units, quantization/error bounds, valid-data mask, coverage, algorithm/light parameters, and attribution. Compute gradients using consistent physical units and valid neighboring samples. A contour interval is not source-height accuracy.
- Produce shade with a derivative/filter halo, then crop to canonical owned interiors. Explicitly mask no-data rather than treating it as zero elevation. Test source-resolution transitions, region boundaries, and adjacent independently generated requests for seams.
- Compare compact quantized shade encodings/resolutions using actual pack size, transfer, cache, SD I/O, decode cost and visible banding. Use bounded tile buffers and allocation-free or bounded sampling during rendering; avoid runtime DEM derivatives or general image decoding in the navigation hot path.
- Decide the next available versioned artifact/section only after checking current cumulative formats. Optional sidecar versus a new FMB section is a format decision, not permission to add bytes to strict FMB5. Missing terrain data renders the accepted map normally; invalid trusted artifacts follow existing validation rules.

### Rendering and controls

On firmware, apply subtle shade after base area fills and before roads, contour strokes, text, route, and marker. Reuse the same projection and accepted pose, with bounded texture sampling and semantic cancellation. Preserve legible land-use/water colors and avoid shading water/no-data into false relief. Use a fixed geographic illumination direction so shading does not change with heading.

On iPhone, generate equivalent imagery from the same elevation/light policy, retaining the established China presentation transform. The existing `.aboveRoads` overlay needs a measured low-opacity/masking solution for road visibility. If true placement below Apple roads is necessary and unavailable, make a separate map-renderer decision; do not bundle a wholesale MapKit replacement into hillshade implementation or claim that `.aboveRoads` meets a below-roads requirement.

Add independent contour and hillshade switches, default hillshade off initially, with separate Map/Map+Navigation preferences and explicit data-availability state. Keep phone/device intent equivalent while allowing display-specific contrast. Update BLE capability/settings contracts and both clients if settings cross the device boundary. A saved preference on a map without shade data must fall back cleanly.

### Acceptance

Deliver matched plain / contours / contours-plus-hillshade captures, plus hillshade-only to prove independent toggles. Validate seams, alignment, no-data, both modes, camera motion, daylight readability, offline reopen, old maps, settings persistence, installation/transfer interruption and recovery. Measure worker memory/time, storage, bytes transferred, device rendering/memory, phone memory, and controlled battery impact against stage 1. Publish selected encoding, resolution, contrast, and limits with the evidence before considering a default change.

Suggested PR sequence: elevation-cache/product contract → generator and validated artifacts → device/iPhone renderers and settings → physical qualification and rollout. This sequence must preserve legacy delivery throughout.

## Stage 3 — elevation tint and slope shading experiments

Promote only after hillshade is physically accepted. Use the same cached elevation, coverage mask, fixtures, and bounded product generation.

- Compare subtle elevation tint and slope shading separately against accepted contours-plus-hillshade at identical locations, camera settings and daylight brightness.
- Use geographically stable, documented elevation palette ranges; do not normalize each tile independently and create color seams. Define slope in physical ground units and preserve no-data/quality semantics.
- Keep these styles behind experiment controls. Evaluate combinations only after each style alone shows value. Navigation readability and terrain understanding decide retention; adding more modes is not itself success.
- Retain only a style that passes existing budgets and an explicit rider comparison. Record rejection reasons and remove unused production paths. Retain the reusable elevation source either way.

## Stage 4 — true 3D terrain exploration

Promotion follows stage 3's keep/drop decision. This has a research exit, not a guaranteed shipping exit.

1. On iPhone, prototype a Bicino-owned offline height surface from the preserved elevation data. Treat the existing Apple MapKit 3D Terrain preference as a separate product. Select an offline renderer only after verifying artifact ingestion, offline availability, licensing, app size and performance; MapLibre screenshots are visual references, not evidence of integration.
2. Solve height/imagery alignment, mesh seams and LOD, no-data holes, vertical datum, near-plane clipping, route/road draping, camera behavior, and screen-space navigation labels. Keep any vertical exaggeration explicit and disabled for initial fidelity comparisons.
3. Only if the phone experiment proves useful, prototype a bounded coarse device height mesh with capped vertices/triangles/pixels and tile-local scratch space. Keep early experiments free of simultaneous building-detail expansion. Do not assume current flat-ground projection or painter ordering can handle terrain occlusion correctly; prove it on ridges and steep valleys.
4. Require a separate 1.75-inch gate for RAM/fragmentation, frame/presentation time, touch/GPS/BLE responsiveness, battery, thermal behavior, daylight readability, camera motion, and safe fallback to accepted flat hillshade. A full-frame depth buffer or display architecture change needs its own measured justification.

Valid outcomes: phone-only offline terrain; a restricted device experiment; or no shipped 3D. Never enable device 3D by default based on phone success.

## Budgets and validation policy

Use `esp32/tools/renderer_benchmark_gates.json` as the current source of truth and re-read it at implementation time. At this planning baseline it includes render P95 ≤1,250 ms, flush P95 ≤150 ms, internal free ≥32,768 bytes and largest block ≥16,384 bytes, PSRAM free ≥1,500,000 bytes, and zero crypto/invariant failures. Existing candidate comparisons limit relative render P95 to 1.25× and PSRAM headroom loss to 65,536 bytes. These are existing ceilings, not proof that terrain has that spare capacity.

Create an explicit terrain fixture/profile with the applicable existing safety gates. The building benchmark's minimum-building-count and reach-gain requirements are not meaningful acceptance criteria for rural contour labels; replace those workload-specific criteria with terrain coverage/readability criteria before running, while retaining resource/security/responsiveness limits. Keep the existing urban benchmark as a regression check. Do not weaken a gate after seeing results.

Before stage 2 default enablement is even considered, fill in numeric budgets for added bytes per area, generation CPU/peak memory, transfer time, shade-cache bytes, and battery increase under a controlled ride workload. Baseline data needed to choose those values is not available in this planning session. Default-off development experiments remain distinct from default-on release qualification.

At each delivery gate record exact source/app/firmware/map identities, test results, artifact hashes, screenshots and physical observations. Start implementation validation with `tools/dev-check --plan`, then affected checks and required full/CI gates. A 2.06-inch release needs separate physical qualification. Production backend delivery follows the digest-pinned promotion/runbook process in `AGENTS.md`; map-source canary approval does not silently become global source approval.

## Current PR validation and remaining gates

The PR implements bounded contour labels, optional FME1 height/shade/slope data,
versioned iPhone companions, configurable Map presets, and an isolated 3D height
surface on phone and device. Tint incorporates hillshade; slope is an alternative
color meaning. Existing maps and companion v1 remain readable. New phone labels
and terrain require regeneration of an experimental map pair.

Source/build tests do not establish daylight readability, optical seams,
motion stability, measured on-device frame time or battery impact. These remain
required before promotion. Apple base-map labels are owned by MapKit; numeric
annotations use its low display priority and collision handling plus explicit
route/marker exclusions. Exact Apple-label interactions still need visual QA.
The 3D device renderer uses a capped painter-ordered surface; steep-relief
occlusion and navigation draping are separate exploration questions.
