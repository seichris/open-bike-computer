# Stable map orientation implementation plan

Status: proposed; implementation and physical qualification are pending.

Researched on 2026-09-06 against freshly fetched GitHub `main`:
`e10aa7fa341366dd3b8e3ed74c0e069d414b8f0d`. This document starts on branch
`plan/map-orientation-stable-layers` from that exact commit. The previous
discussion examined `8b8157f52ea57a1590867a153df1e4cdde3f40c2` on 2026-08-31.

## 1. Intended experience

Give Map + Navigation its own North Up / Course Up preference. Default to
Course Up for navigation and retain Keep Upright as the default label
orientation. Preserve existing label visibility and density preferences:
Map + Navigation currently defaults to labels **off**. This change must not
silently enable them.

| Element | North Up | Course Up |
| --- | --- | --- |
| Roads, route, land, building footprints | Geographic bearing stays fixed; position follows the rider | Rotate together with camera bearing |
| Directional position marker | Rotates with resolved travel heading | Upright when the camera tracks travel heading |
| Building height direction | Screen-up | Screen-up, including while turning |
| Keep Upright labels | Horizontal text, anchored to projected roads | Horizontal text, anchored to projected roads |
| Follow Roads labels | Follow the projected road tangent, with readable text direction | Same rule as the map turns |

North Up fixes the map's bearing, not its position or zoom. Course Up cannot
keep building footprints fixed on the display: doing so would separate them
from roads and parcels. Walls, roofs, and shading may change as the camera
bearing changes; stable extrusion means that the vertical height axis remains
screen-up. It does not mean freezing a building's silhouette or visible faces.

Use the existing resolved course policy: measured course, route bearing, then
valid remembered direction within the current session. This is travel direction,
not an assumption that the device or phone has a usable compass heading.
Retain the idle location dot, the north-up idle guidance bootstrap, and hiding
the directional marker when active guidance has no valid heading.

The marker must always reflect the camera actually displayed. In the existing
flat convention, its angle is `resolvedHeading + displayedMapRotation`.
Perspective should derive the direction from a projected short ground segment
through the rider so it agrees with the visible road tangent. When the camera
tracks the course at the rider anchor, both conventions produce an upright
marker. During a delayed camera update, a small temporary marker rotation is
more accurate than forcing it upright against an older camera bearing. This
exception must be bounded and measured; it is not a second user setting.

## 2. Refreshed source findings

The following references are relative to this document and refer to the pinned
baseline above. Function names remain the primary lookup keys if lines move.

### What the merged work changed

The fetched main history includes merges of PRs #373, #384, #344, #371, #401,
and #400, among others. Relevant changes now present include:

- Diagnostic-window identity participates in render-job validity, and job
  counters are attributed to the window that owns each request.
- Polygon scanline workspace is reused; building admission stops unnecessary
  exact projection after the existing quotas are filled; projection zoom and
  rotation coefficients are cached per immutable request.
- The worker runs one priority above idle with cooperative idle release.
  Variable scratch uses PSRAM where appropriate.
- The 1.75-inch panel uses physical-circle coverage checks and adaptive
  overscan. The full-height viewport has a 64-pixel minimum; the 466 x 366
  toolbar layout needs at least 66 pixels. Allocation still allows 96 pixels.
  Rectangular coverage must remain separately valid for the 2.06-inch target.
- Secure replay now carries GPS and its fixture marker atomically, with paced
  window changes, deadline-based replay scheduling, transport timing, warm-up
  evidence, and retained-memory regression checks.

These changes improve throughput and evidence. They do not establish the
stable-orientation contract. `mainScr.cpp`'s mode selection,
`mapBuildingRenderer.hpp`, and `map_profile_protocol.hpp` are unchanged from
the previous research baseline. The changes to presentation/projection and
`maps.cpp` retain whole-frame rotation and the label path described below.

Sources: [render-job versioning](../esp32/lib/maps/src/mapRenderJob.hpp),
[presentation and coverage](../esp32/lib/maps/src/mapPresentation.hpp),
[renderer](../esp32/lib/maps/src/maps.cpp),
[current benchmark contract](renderer-benchmark.md).

### Orientation behavior that remains

1. `applyMapRotationForTile()` in
   [mainScr.cpp](../esp32/lib/gui/src/mainScr.cpp) still chooses Course Up
   whenever a route or maneuver activates Map + Navigation. Idle guidance uses
   North Up. Only the ordinary Map profile honors `mapRotationMode`.
2. [SettingsView.swift](../ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift)
   still exposes Rotation only for Map. Its Map + Navigation controls expose
   bird's-eye view, perspective, 3D buildings, and independent label settings.
3. `groundForWorld()` rotates geographic coordinates before perspective.
   `projectElevatedGround()` subtracts projected height from screen Y while
   keeping X unchanged. Fresh building extrusion therefore already points
   screen-up. See [map_projection.hpp](../esp32/lib/maps/src/map_projection.hpp)
   and [mapBuildingRenderer.hpp](../esp32/lib/maps/src/mapBuildingRenderer.hpp).
4. `renderWorkerLoop()` invokes `readVectorMap()` with labels enabled. Buildings
   and labels are drawn into the completed base RGB565 frame.
   `updatePresentedFrameTransform()` then applies `lv_img_set_angle()` to that
   entire image as heading changes. `renderLiveForeground()` transforms the
   route using the same old projection and rotation delta.
5. `drawStreetLabels()` selects `atan2(dy, dx)` for Follow Roads and zero for
   Keep Upright, then normalizes readable direction. Keep Upright currently
   describes a fresh raster, not every transitional display frame.
6. The refreshed replay coordinator still calculates course from fixture
   points and sends samples at 1 Hz, with route windows every two seconds.
   Building profiles change extrusion quotas; they do not select map or label
   orientation. Replay transport is synthetic, but rendering semantics are
   shared with normal navigation. See
   [RendererBenchmarkReplayCoordinator.swift](../ios-app/BikeComputer/BikeComputer/Managers/RendererBenchmarkReplayCoordinator.swift).

### Additional correctness gaps to address

**Perspective label placement:** `drawStreetLabels()` does not receive the
`Projection` used by roads/buildings. It transforms candidate endpoints using
flat zoom/rotation and its own surface anchors. `LabelSurface` is a raw pixel
target, not a perspective adapter. Consequently, bird's-eye labels can have
different anchors and tangents from their roads even in a newly rendered frame.
The layout cache also has no explicit perspective identity. This is a source
finding newly identified during this refresh, not a newly measured device
failure. Fixing glyph rotation alone would leave it unresolved.

**Perspective ground reprojection:** for perspective projection `P` and camera
rotation `R`, `P(R(world))` generally differs from `R(P(world))`. Rotating an old
bird's-eye ground image changes its screen-relative foreshortening direction.
Thus separating text and buildings while continuing to rotate a projected
ground bitmap is insufficient for a fully coherent camera. The current route
transform stays attached to that approximation, but does not make it a new
perspective view. Translation of a projected raster is also an approximation
to moving a perspective camera.

The previous suggestion of four layers is retained as a separation of rendering
responsibilities. It is refined below: it does not require four persistent
full-screen pixel buffers, and perspective ground needs camera reprojection too.

## 3. Architecture decision

Separate expensive scene preparation from camera-dependent rendering. Keep the
single worker and UI publication boundary. Reuse decoded map data to render a
new view without repeating SD reads, decoding, or unrelated preparation merely
because the course changed.

The current `MemCache` already reuses loaded blocks. This is a refactoring of
that ownership and preparation boundary, not a claim that every existing turn
reads the SD card. Measure preparation, projection, fill, and label costs
separately: retaining a scene alone will not remove expensive rasterization.

### Immutable scene and camera state

- `PreparedMapScene` (proposed): bounded decoded ground geometry, building
  source geometry/metadata, and label candidates/shaped-run references with
  owned lifetimes. It records map generation and geographic coverage. Reuse
  current block data through explicit leases or owned bounded storage; never
  publish raw pointers into an evictable `MemCache` or mutable font cache.
- `CameraSnapshot` (proposed): scene generation, world center, resolved target
  bearing, actual view bearing, zoom, projection mode/effective perspective,
  viewport, anchor, screen profile, semantic epochs, and pose timestamp.
- `PresentedFrame` (proposed): the accepted camera snapshot and scene identity,
  completed raster, label-layout identity, and diagnostics window. All base
  passes are rendered for this same snapshot.

The scene belongs to the worker. The UI receives a small immutable frame
descriptor, not ownership of a geometry walk. Cache eviction must wait until
all worker references are released. Limit active/prepared generations and
account for their maximum simultaneous residency. Map activation, screen
teardown, recovery, and worker shutdown must retire every lease deterministically.

### Rendering passes and storage

Use explicit ground, building, annotation, and route/marker passes. Initially
compose ground, buildings, and labels into the existing hidden RGB565 surface,
then swap it atomically. Logical separation makes those passes independently
testable and reusable; it does not require another full surface per pass.

For each camera snapshot:

1. Project/rasterize ground geometry with the shared `Projection`.
2. Recompute bounded building admission where camera-dependent area or coverage
   requires it; project footprints, walls, and roofs for that camera. Retain
   nearest-first selection, global drawing order, clipping, courtyard behavior,
   and total/extrusion quotas. Cached admission is valid only for its declared
   camera/coverage envelope.
3. Project label candidate segments through the same projection, clip them,
   lay out labels in visible screen coordinates, and rasterize text after
   perspective. Keep Upright glyphs have zero screen angle. Follow Roads uses
   the projected tangent and readable direction; text size remains in pixels.
4. Publish the complete frame with its camera. Draw the live route and marker
   against that accepted camera, using the existing foreground and marker
   ownership. Preserve the established route-over-map priority. Reserve the
   marker and actual navigation UI bounds during label layout; use a stable
   halo so a moving live route cannot make text unreadable.

Never apply a heading delta to a completed raster containing text, extrusions,
or perspective ground. A future flat-view optimization may transform a
label-free, ground-only cache before composition; it must preserve these same
output rules and pass pixel/coverage tests. It is not a prerequisite.

Do not put SD IO, font loading, label collision search, building projection,
or a full frame raster on the LVGL task. Preserve short swaps, cached idle
signatures, cooperative cancellation, watchdog fairness, and PSRAM allocation
discipline from the merged work.

### Cadence, publication, and overload behavior

Keep target pose distinct from accepted camera pose. Movement and heading
updates coalesce into one latest camera request; they must not cancel every
active view render. Map/style/projection/screen/session changes remain semantic
invalidations. Carry `diagnosticsWindowId` through scene/view accounting so work
from an old measurement window cannot satisfy a new checkpoint.

Use the existing shared pose resolver and finite prediction horizon. Add a
camera-refresh path for a prepared scene; do not reuse the ordinary
750 ms / 12-degree heavy-render gate as its only cadence. Continue preparing
new map coverage ahead of the rider when the resident scene is insufficient.
Heading updates alone must not restart map decoding.

A completed frame may publish after a newer pose request when its semantics,
coverage, and bounded camera age remain valid. Publish its actual camera and
queue the newest view. Exact pose equality would recreate render starvation.
Re-evaluate physical viewport coverage using the new camera model; the existing
circle/square proof is specific to an affine presentation and cannot be copied
unchanged into a different transform. Include near-plane clipping, effective
perspective easing, toolbar/fullscreen layouts, and building roof reach.

While waiting, hold the complete prior camera image without rotating it.
Project the current live marker and route through that accepted camera so they
remain geographically attached; the marker may move away from the follow anchor
or show a bearing residual until recentering. Never independently freeze a
building layer over a moving ground layer. After coverage or age is no longer
usable, conceal the stale scene with a neutral/loading state and retain valid
turn instructions. Do not silently switch the selected orientation or display
a heading unsupported by the visible camera.

Proposed normal-operation targets for the prepared-scene path are camera age
p95 <= 250 ms and maximum <= 500 ms under the acceptance fixture. These are
new product targets, not measured capabilities or replacements for existing
benchmark gates. Here camera age measures time spent displaying an older view
while a geometric camera update is required, using the device monotonic clock;
an unchanged idle camera does not expire because its raster is old. Record raw
frame timestamps separately, and include all demanded updates, including
coalesced ones, in lag accounting. Cold scene preparation is measured separately, including its
visible loading duration; it must not be disguised as a cache hit. If the
target is infeasible, optimize bounded projection/raster work and reassess the
design before production activation rather than restoring rotated 3D/text.

### Label stability and cache identity

Project world-space candidate anchors/endpoints, rather than counter-rotating
already rendered text. Use the actual viewport and navigation-card bounds,
not the overscanned surface bounds, for collision placement. Retain language
selection, shaped assets, density, zoom eligibility, repeat suppression, and
road visibility filtering.

Cache immutable shaping independently from placement. A placement key includes
scene/map identity, effective camera projection, center, bearing, zoom,
viewport/anchor, language, size, density, orientation, visibility, and reserved
regions. A stable feature/run identity should survive cache block reordering.
Use bounded placement reuse/hysteresis only when projected error and collision
checks still pass. Quantization must not apply an old glyph angle to a new
camera. Invalid or clipped candidates are omitted cleanly.

## 4. Settings and compatibility

Add a separate persisted Map + Navigation rotation preference to
`MapRenderSettings`, its NVS helpers, and iOS's per-screen profile. Default
missing/invalid values to Course Up for active guidance. Preserve idle
north-up behavior and all ordinary Map preferences. Do not migrate the Map
setting into the navigation preference: the historical settings were independent.

At this baseline setting IDs end at 36, CAP2 feature bits end at 23, and the
current client version is 21. Propose setting ID 37 (`0` North Up, `1` Course
Up), CAP2 bit 24, and client version 22 for independent navigation orientation.
These values are provisional until rechecked against GitHub main immediately
before implementation. Do not reuse setting ID 6 or the bird's-eye capability.

Update the canonical [ride BLE contract](../protocol/ride-ble-contract-v1.json),
regenerate Swift/C++ capabilities with
`tools/generate_ride_ble_contract.py`, and coordinate the setting constants,
handler authorization/validation, capability encoder, persistence, iOS parser,
send gates, and [BLE documentation](ble-protocol.md) in the same change.

Only advertise support when the implementation is enabled for that build.
The new app must show that the independent choice requires newer firmware when
the feature is absent, preserve the local preference, and send no unsupported
setting. Reconnect should use the existing authenticated settings-sync ownership;
do not introduce an unrelated multi-writer settings protocol. A legacy app
does not send this setting, so firmware retains its stored/default navigation
preference. Invalid values never alter the Map profile.

Mode changes invalidate the camera/profile generation atomically. Guidance
start/stop, route-only updates, and screen transitions must not overwrite the
chosen preference. Heading validity remains separate from camera mode: a
North Up background can exist while a directional marker has no valid heading.

## 5. Resource and performance constraints

The current documented 1.75-inch maximum is two 658 x 658 RGB565 base frames
(1,731,856 bytes together) plus a 466 x 466 RGB565+A8 foreground (651,468 bytes):
2,383,324 persistent surface bytes before decoded maps and scratch. These are
static estimates, not a current heap measurement. Adaptive overscan reduces
raster work, not those maximum allocated capacities.

Retain that surface allocation as the initial design budget. An extra
466 x 466 RGB565+A8 layer would cost about 651,468 bytes before any additional
buffering; four independently buffered layers are not assumed affordable.
Before adding scene leases or metadata, inventory exact decoded geometry,
glyph-cache residency, view scratch, and simultaneous old/new scene lifetimes.
Publish a byte-accounted cap and failure policy for each added allocation in
[the PSRAM budget](firmware-map-rendering-psram.md). Existing four-block world
span protection and building/label candidate bounds must remain enforced.

Preserve benchmark absolute and retained-memory gates. Current floors include
1,500,000 free PSRAM bytes, a 750,000-byte largest PSRAM block, 32,768 free
internal bytes, and DMA headroom/crypto checks. The exact contracts are
[firmware gates](../esp32/tools/renderer_benchmark_gates.json) and the matching
iOS resource. Compare warmed existing and proposed paths on the same hardware,
map, scene style, labels, capture settings, and building profile. Track decoded
scene reuse, view-render duration, camera age/bearing residual, label layout,
building projection, publication, DMA, and long-run memory separately.

Do not reinterpret the temporary four-coverage-rejection allowance as an
orientation fix or relax it in this work. [Issue #402](https://github.com/seichris/open-bike-computer/issues/402)
tracks that policy; the independent stale-render limit remains three. Existing
benchmark acceptance alone also does not establish the new camera-age target.

## 6. Implementation sequence and completion gates

Each step should be reviewable separately. Production activation follows the
last step; preparatory changes must retain the current production behavior.

1. **Baseline and camera contract.** Add deterministic asymmetric road/building
   and label fixtures; characterize old-frame rotation and perspective label
   misplacement. Introduce pure camera/marker projection policy and frame
   identity tests. Record current resource/timing baselines with labels both off
   and on. Define the bounded scene residency caps from measured/source sizes.
2. **Shared label projection.** Pass the real projection and visible viewport
   bounds into candidate generation; fix perspective anchors/tangents and cache
   keys. Extract annotation layout/raster APIs without changing map assets.
   This step alone does not claim transitional stability.
3. **Prepared scene and view rendering.** Separate decoding/preparation from
   camera passes; add bounded worker-owned scene lifetimes, coalesced camera
   requests, and diagnostics. Preserve the merged admission, fairness, and
   window-accounting behavior. Demonstrate that turns within resident coverage
   perform no map IO and do not cause unbounded geometry duplication.
4. **Coherent presentation.** Render and publish complete camera views, remove
   whole-image heading transforms from the new path, and make route/marker
   consume the accepted camera. Implement explicit delayed/loading behavior,
   new coverage validation, idle no-ops, gesture settlement, and profile
   transition fencing. Keep this path behind a tracked development feature
   gate until it meets correctness and performance targets.
5. **Independent navigation preference.** Implement the coordinated firmware,
   generated protocol, NVS, and iOS changes described above. Add North Up /
   Course Up to Map + Navigation. Enable the capability only where the
   supported implementation is compiled. Preserve all stored label settings.
6. **Orientation evidence and qualification.** Extend diagnostics/evidence to
   record requested/effective map mode, label settings, effective perspective,
   camera/frame identity and age, and maximum marker bearing residual. Run
   deterministic turn tests, the existing quota sweep/soak, and real navigation.
   Record distinct 1.75-inch and 2.06-inch hardware outcomes before enabling the
   new production path for either target.

Primary firmware touch points are `mainScr.cpp`, `maps.cpp`/`maps.hpp`,
`mapPresentation.hpp`, `map_projection.hpp`, `mapRenderJob.hpp`,
`mapBuildingRenderer.hpp`, label layout/raster helpers, `RouteOverlay`, and
BLE profile/capability/persistence helpers. iOS touch points are
`BLEManager.swift`, `SettingsView.swift`, generated protocol/capability code,
and benchmark controller/evidence models. Update renderer scheduling, PSRAM,
BLE, and benchmark documentation alongside their respective changes.

## 7. Verification and acceptance

### Host and iOS contracts

Extend the existing projection, presentation, building-renderer/admission,
label-layout/raster, render-job, profile-protocol/persistence, capability, and
guidance integration tests under `esp32/tools/tests/`. Use the repository CI
commands for those suites. Add behavioral fixture assertions rather than only
source-string checks. Run generated-contract `--check` and
`ios-app/scripts/run-navigation-tests.sh` for protocol/settings/replay changes.

Required cases:

- Bearings 0/90/180/270 degrees and 359-to-1 wraparound; both modes; flat and
  every perspective preset; full-height and toolbar viewports.
- Building footprint/road alignment and equal base/roof X for each vertical
  edge through turns, with clipping, holes, min-height, and admission overflow.
- Keep Upright angle zero on every published frame; Follow Roads matches the
  projected tangent within raster quantization and stays readable. Include
  bilingual labels, rotated roads, reserved UI regions, and offscreen anchors.
- Perspective ground and labels match a common projection. A fixture must
  distinguish camera reprojection from rotation of an old perspective raster.
- Route/marker agreement with the actual displayed camera during normal motion,
  forced render delays, missing heading, heading-only updates, reroute, and
  finite prediction exhaustion. North Up must not manufacture a heading.
- Camera coalescing cannot starve publication. Semantic changes and diagnostic
  windows reject incompatible frames. Scene teardown/eviction cannot invalidate
  in-flight geometry. Exercise allocation failures and stale coverage explicitly.
- Start/stop, reconnect, old/new app-firmware pairs, missing/corrupt settings,
  capability absence, screen cycle/render-ahead, pan/pinch settlement, and
  repeated idle ticks preserve the intended mode and resource ownership.

### Physical evidence

Use a separately identified device and a signed FMB v4 map with known buildings
and labels. Follow the current root `AGENTS.md` for locked builds, target
confirmation, flash authorization, and post-flash identity/ready evidence.
Use the matching remote-debug profile for capture and BLE-pinned HTTPS.
Build/CI success is not a device result. Automatic CI's 1.75-inch profiles do
not qualify 2.06-inch compilation or operation; schedule both target builds as
part of the implementation's explicitly authorized full qualification.

Supplement the existing four benchmark checkpoints with a separate bounded
orientation test: hold several known bearings, turn through them, and include
controlled delayed-publication intervals. Frame sequences must include the
transition, not just the settled image. Keep this capture separate from the
ranking sweep so extra screenshots do not silently change its overhead.
Record the exact camera state belonging to each captured frame, rather than
assuming its request or route-marker time identifies its pixels.

Acceptance requires readable horizontal Keep Upright labels throughout the
captured transitions, correct Follow Roads tangents and footprint alignment,
screen-vertical extrusion, coherent marker/route behavior, bounded camera lag,
and unchanged memory/transport/render gates. Repeat in natural navigation to
cover real course noise, stops, and BLE jitter. Display motion/tearing,
daylight readability, and thermal/battery impact require separate observations;
the synthetic sweep cannot establish them.

### Rollout and rollback

Keep a per-target hardware gate in the implementation PRs and release notes.
Merge production-disabled preparation normally; activate only after the target
passes its physical and performance gates or the maintainer explicitly records
the allowed residual risk under repository policy. Do not change default
extrusion quotas, map format, backend processing, signed artifacts, or benchmark
limits as incidental parts of this feature.

Rollback disables the new renderer/capability through a tracked change while
preserving persisted preferences for a later upgrade. The app falls back to
the capability-absent UI. Do not erase user settings or silently claim that a
rolled-back forced Course Up renderer still supports independent orientation.

## 8. Research boundary

This plan is based on fetched source, merged history, and existing checked-in
contracts. No firmware, app, map, or physical device was changed or tested for
this document. Historical sweep evidence remains evidence for its recorded
artifact and policy; it does not prove orientation acceptance on this baseline.
Before implementation, fetch main again, reconcile intervening renderer work,
and recheck the proposed protocol allocations.
