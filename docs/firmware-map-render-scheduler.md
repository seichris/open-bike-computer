# Firmware map render-ahead scheduler

The map renderer has two independent paths:

- a presentation path owned by the LVGL task, which updates the rider marker,
  route foreground, maneuver UI, and transform of the last complete base frame;
- a low-priority render worker, which reads map blocks and renders a complete
  hidden RGB565 base frame without calling LVGL.

The movement and cadence policy remains an intake policy. It decides when a new
immutable render request is useful; it is not relied on to make map rendering
safe.

## UI-task contract

A normal UI tick must not perform SD reads, block parsing, building discovery,
global sorting, polygon filling, large allocation, or 3D surface drawing. It:

1. consumes the latest GPS, route, maneuver, style, and screen state;
2. advances one `PresentedPose` with bounded prediction and convergence;
3. translates and rotates the current front frame around the projected rider;
4. draws the route into a viewport-sized RGB565+A8 foreground using the same
   projected pivot, viewport anchor, and heading delta as the base frame;
5. updates the arrow from that same pose; and
6. publishes a completed worker frame through a short front/back pointer swap.

The visible frame and every LVGL object have one owner: the LVGL task. Screen
recreation invalidates the semantic job without waiting for SD or geometry
work. The worker is quiesced only before a persistent PSRAM surface is resized;
ordinary LVGL object rebinding keeps the stable hidden-buffer address and never
exposes that buffer.

## Immutable render requests

Every `MapRenderJob` captures the state needed to reproduce the frame:

- predicted world-space center and presentation context;
- heading, projection, perspective, zoom, viewport, overscan, and style;
- route revision;
- navigation, style, map-root, and projection epochs; and
- the fixed render dimensions and RGB565 stride.

The request receives a monotonic sequence number. Position-only requests are
coalesced: an active render is allowed to finish and publish when its route,
style, map, and projection epochs still match, even if a newer GPS sequence
has arrived. This is the backpressure invariant that prevents a 1.8-second
3D render from being cancelled forever by a 750 ms GPS cadence. Semantic
changes (route replacement, style, map source, projection, or screen mode)
cancel at the next bounded checkpoint. A completed result is checked again
against current route/style/navigation/projection state immediately before
publication. A stale result never reaches the front buffer.

Map-root changes and probes stop the worker before mutating the cache. Loaded
blocks remain owned by the renderer while a job is active, so cache mutation
cannot invalidate worker pointers.

## Base-frame publication and motion

Both persistent RGB565 buffers are sized for the maximum supported viewport
plus 96 pixels of overscan on each edge. On the 466 x 466 profile each 658 x 658
RGB565 frame is 865,928 bytes at the current aligned stride. The two frames plus
the 466 x 466 RGB565+A8 foreground total 3,030,748 persistent bytes (about 2.89
MiB), before map blocks and bounded workspaces. The worker renders only into the
hidden buffer. Publication verifies dimensions, stride, and both buffer capacities,
then swaps the raw pointers under the render-state mutex. LVGL rebinding happens
on the UI task after the mutex is released.

The old complete frame remains visible while a replacement renders. The UI
translates it continuously using the current `PresentedPose`. Course-up rotates
it by the difference between the frame heading and the current presented
heading. The route foreground applies the exact same transform, so its first
point, the route head, the arrow, and the base map remain attached.

iOS does not retransmit the route merely because the exact rider coordinate
changed. Firmware anchors the retained window at every presented pose, while
the app sends a replacement after roughly two thirds of the 30-point forward
window has been consumed (or after reroute, backtrack, or readiness recovery).
This keeps route revisions semantic and prevents a fixed two-second
cancellation loop for longer map jobs.

Prediction is deliberately finite: by default it is capped at 1.5 seconds and
30 metres, then stops instead of drifting without a fresh fix. Repeated packets
with unchanged coordinates are still fresh observations and drive convergence.
A new fix converges over a bounded interval rather than moving one visual layer
independently.

## Course-up state

Course-up is explicit navigation state. A valid measured course is preferred.
When Core Location reports an invalid course, including `-1` during test
navigation, iOS sends the invalid-heading sentinel and both sides use the
nearest live route-segment bearing. A remembered heading is scoped to the
current navigation epoch and is cleared on start, stop, reroute, or mode
change. The arrival order of the route window and maneuver packet does not
create a second guidance session; either is enough to activate guidance.

A missing heading is a deferred request, not heading zero. The scheduler keeps
the last good frame dirty until a measured course or route bearing exists.

## Deterministic buildings and bounded memory

FMB v4 records are discovered across every loaded in-view block. Candidate
metadata is retained with a bounded nearest-item heap, then sorted by distance
and stable block/record identity. Selection therefore does not depend on cache
or block iteration order.

Fixed quotas are applied nearest first: at most 96 admitted records, 8,192
source points, and 220,000 projected pixels; within that set at most 32 records,
3,072 source points, and 90,000 projected pixels are extruded. The nearest useful records retain 3D roofs and walls. Farther admitted
records become flat roofs; records outside the quota are explicitly deferred.
Courtyard snapshots are clipped to the visible raw surface and have a fixed
pixel budget. A scheduling checkpoint does not trigger 2D fallback. Genuine
allocation failure retries once with a smaller fixed-memory nearest set of flat
footprints; its scoped cooldown uses the same path. Data or invariant failures
retain the last complete frame and emit diagnostics.

The renderer preserves FMB v1-v4 and ordinary flat-map behavior.

## Render request policy

An ordinary follow-mode GPS update requests a replacement base frame only when
both of these conditions are true:

- at least 750 ms has passed since the last published base-map render; and
- position moved at least 8 m, or course-up heading changed at least 12 degrees.

Route, style, zoom, screen, semantic recovery, or exhausted-overscan requests
bypass those ordinary GPS gates. Overscan refresh uses measured presented speed,
pixels per metre, the most recent render duration, and safety pixels. The
96-pixel overscan is geometry capacity, not a promise that a slow render may
block the UI.

## Diagnostics

`MAPIO` diagnostics report:

- submit, ready, cancellation, stale-publication, invariant-failure, and publish
  sequence state;
- total job, block-load, draw, and UI swap durations;
- bounded work-unit count and longest observed unit;
- selected, extruded, flat, and deferred building counts;
- allocation fallback; and
- free and largest-contiguous PSRAM at completion and surface creation.

The declared initial UI/work-unit acceptance gate is 50 ms. Display-flush and UI
maximum-gap telemetry remain the physical source of truth; host tests and a
successful firmware build do not establish that gate.

## Validation boundary

Host tests cover semantic invalidation, position-only coalescing, stale rejection,
invariant failure,
bounded fake-clock slices, heading wrap/fallback, finite prediction and
convergence, shared presentation transforms, exact route-head anchoring,
deterministic building admission under block-order permutations, quota
overflow, bounded courtyard workspace, and legacy protocol behavior.

A `WAVESHARE_AMOLED_175` build is required before review. Physical acceptance
still requires an FMB v4 building-bearing pack on the 8 MiB PSRAM device in
idle Map + Navigation, test navigation, and real navigation. The run must record
UI maximum gap, display flush interval, render diagnostics, building counts,
and PSRAM free/largest values. No physical success is implied by this document.
