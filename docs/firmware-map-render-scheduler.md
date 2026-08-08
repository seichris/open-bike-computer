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

The visible frame and every LVGL object have one owner: the LVGL task. Drag and
pinch previews temporarily own the base-image and marker transforms; worker
publication waits until release, and a settlement keeps its exact endpoint
until the replacement frame is ready. The live route foreground is hidden
during that bounded preview instead of drifting away from the transformed map.
Screen recreation invalidates the semantic job without waiting for SD or
geometry work. The worker is quiesced only before a persistent PSRAM surface is resized;
ordinary LVGL object rebinding keeps the stable hidden-buffer address and never
exposes that buffer.

## Immutable render requests

Every `MapRenderJob` captures the state needed to reproduce the frame:

- predicted world-space center and presentation context;
- heading, projection, perspective, zoom, viewport, overscan, and style;
- route revision for diagnostics (the route itself is live foreground);
- navigation, style, map-root, and projection epochs; and
- the fixed render dimensions and RGB565 stride.

The request receives a monotonic sequence number. Position-only and
route-window-only requests are coalesced: an active render is allowed to finish
and publish when its navigation, style, map, and projection epochs still match,
even if a newer GPS sequence
has arrived. This is the backpressure invariant that prevents a 1.8-second
3D render from being cancelled forever by a 750 ms GPS cadence. Semantic
changes (navigation session, style, map source, projection, or screen mode)
cancel at the next bounded checkpoint. A completed result is checked again
against current style/navigation/projection state immediately before
publication. A stale result never reaches the front buffer.

Boot-time map-root recovery may synchronously quiesce the worker before it has
started. Runtime map activation and renderer probes are control jobs on the
same storage/render worker, with a completion mailbox back to the UI task.
Loaded blocks therefore have one owner, and SD traversal or block parsing never
runs in the LVGL loop. A control job ignores ordinary camera/style cancellation
generations once it starts, while still honoring worker shutdown, so a new GPS
fix cannot interrupt a map-root probe/switch halfway through. A transient
non-blocking enqueue failure is retried for up to 10 seconds before transfer
activation is rejected. A failed probe keeps the previous root and explicitly
requests a replacement frame because entering the control job cancelled the
old in-flight render. If an exceptional stop times out while an SD operation
finishes, a late-exit handoff restarts the preserved old root instead of
leaving the map frozen. Initial canvas allocation does not stop a worker that
can only be running a storage control job; buffer relocation is quiesced once
both persistent frame buffers exist and can be worker-owned.

## Base-frame publication and motion

Both persistent RGB565 buffers are sized for the maximum supported viewport
plus 96 pixels of overscan on each edge. On the 466 x 466 profile each 658 x 658
RGB565 frame is 865,928 bytes at the current aligned stride. The two frames plus
the 466 x 466 RGB565+A8 foreground total 2,383,324 persistent bytes (about 2.27
MiB), before map blocks and bounded workspaces. The foreground is 651,468 bytes:
`466 * 466 * (2 + 1)`, because it is viewport-sized rather than overscanned.
The worker renders only into the
hidden buffer. Publication verifies dimensions, stride, both buffer capacities,
and that the current translated/rotated viewport still fits inside the
candidate's overscan,
then swaps the raw pointers under the render-state mutex. LVGL rebinding happens
on the UI task after the mutex is released.

The old complete frame remains visible while a replacement renders. The UI
translates it continuously using the current `PresentedPose`. Course-up rotates
it by the difference between the frame heading and the current presented
heading. The route foreground applies the exact same transform, so its first
point, the route head, the arrow, and the base map remain attached.
This continuity applies only while the active screen profile is unchanged.
Map and Map + Navigation share the same LVGL canvas but have different style
and projection semantics. During a direct transition between those profiles,
the shared canvas is concealed against the neutral screen background until a
new worker publication for the destination profile arrives; the prior
profile's already-published frame is never accepted as transition completion.
The oversized base object stays LVGL center-aligned. Its style position is an
offset from the centered origin, not an absolute parent coordinate; the
presenter explicitly converts the desired parent-space pivot target to that
offset. This prevents the overscan origin from being applied twice to the base
while the viewport-sized route foreground and marker apply it once.

iOS does not retain or retransmit a rider-to-route connector. A packet begins
at the exact route projection and contains only forward route geometry.
Firmware prepends the current presented rider pose on every UI frame, while
the app sends a replacement when its bounded route matcher advances to another
segment (or after reroute, backtrack, or readiness recovery). The existing
two-second send gate coalesces short segments. This keeps loops and
self-intersections anchored to an unambiguous forward window, while route
revisions remain live-foreground input and cannot create a fixed cancellation
loop for longer map jobs.

The base transform and route foreground update at UI cadence only while their
pose, heading, frame, route, dimensions, or style changes. Cached presentation
signatures make an idle tick a true no-op: it performs neither an LVGL base
invalidate nor a full 466 x 466 foreground-alpha clear. Gesture teardown clears
those signatures, and pinch animation completion leaves the live presenter in
sole control of the image pivot.

Prediction is deliberately finite: by default it is capped at 1.5 seconds and
30 metres, then stops instead of drifting without a fresh fix. Repeated packets
with unchanged coordinates are still fresh observations and drive convergence.
A new fix converges over a bounded interval rather than moving one visual layer
independently.

## Course-up state

Course-up is explicit navigation state. A valid measured course is preferred
after client version 11 negotiates CAP2 bit 13. When Core Location reports an
invalid course, including `-1` during test navigation, the app then sends
`0xFFFF` and both sides use the nearest live route-segment bearing. Version-10
apps retain their ambiguous zero encoding; version-11 firmware detects that
session and resolves route-first, preserving mixed-version behavior. iOS
scopes remembered course to its navigation epoch and clears it on start, stop,
or reroute. Firmware clears its remembered course when the guidance session or
screen/mode changes. It does not treat an ordinary sliding-window packet as a
new heading epoch: doing so would discard live prediction and pull the rider
back to the last raw fix. A new valid route bearing replaces remembered
direction without that reset. Each new route window also feeds the resolved course into
the ordinary 12-degree scheduler threshold, so a material turn or reroute can
replace the base frame even before another GPS packet arrives, while an
equivalent sliding window does not force or cancel a render. The arrival order
of the route window and maneuver packet does not create a second guidance
session; either is enough to activate guidance.

A missing heading is a deferred request, not heading zero. The scheduler keeps
the last good frame dirty until a measured course or route bearing exists.
The directional marker remains hidden during that new-session gap rather than
displaying a false north-facing arrow; the ordinary non-navigation location dot
does not require a course.
Before any route or maneuver is active, course-up has no navigation direction;
the idle guidance screen may establish its first bird's-eye/3D base north-up.
That idle bootstrap is discarded through the normal navigation semantic epoch
as soon as guidance starts and is never used as an active-navigation fallback.

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
pixel budget. Overflow degrades only courtyard restoration to a solid roof;
the admitted 3D building remains. A scheduling checkpoint does not trigger 2D fallback. Genuine
allocation failure retries once with a smaller fixed-memory nearest set of flat
footprints; polygon-node allocation failures are promoted into that same
bounded fallback instead of creating an identical retry loop, and its scoped
cooldown uses the same path. Data or invariant failures
retain the last complete frame and emit diagnostics.

The renderer preserves FMB v1-v4 and ordinary flat-map behavior.

## Render request policy

An ordinary follow-mode GPS update requests a replacement base frame only when
both of these conditions are true:

- at least 750 ms has passed since the last accepted base-map request; and
- position moved at least 8 m, or course-up heading changed at least 12 degrees.

Navigation-session, style, zoom, screen, semantic recovery, or
exhausted-overscan requests bypass those ordinary GPS gates. Overscan refresh uses measured presented speed,
pixels per metre, the most recent render duration, and safety pixels. The
request center is led by speed times that measured duration within the
96-pixel/16-pixel safety budget. Publication independently proves all four
inverse-transformed viewport corners remain covered. Overscan is geometry
capacity, not a promise that a slow render may block the UI.

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
