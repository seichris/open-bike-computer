# Firmware map rendering and PSRAM budget

This is the source of truth for the ESP32 map renderer's memory and timing
budget. Values are tied to a Git revision and board profile; estimates are not
device measurements.

## Waveshare 1.75-inch budget

The 1.75-inch device has 8 MiB PSRAM. Guidance uses a 466 x 466 visible
viewport and a 96-pixel overscan on each edge, producing a maximum 658 x 658
RGB565 base frame. At the current LVGL-aligned stride:

| Frame / surface | Bytes |
| --- | ---: |
| One 658 x 658 RGB565 base frame | 865,928 |
| Two base frames (front + worker back) | 1,731,856 |
| 466 x 466 RGB565+A8 live foreground | 651,468 |
| Persistent surface total | 2,383,324 (2.27 MiB) |

The foreground formula is `466 * 466 * (2 RGB565 + 1 alpha)`; overscan applies
only to the two base frames. These are static sizes from PR #207 rebased on
`origin/main` `1e189980`, for `WAVESHARE_AMOLED_175`; they are not a runtime or
external measurement and use no map/navigation fixture. Free PSRAM,
largest-contiguous PSRAM, map-block cache, temporary
building workspace, and SD latency remain runtime concerns. No battery claim is
derived from these sizes.

## Rendering ownership and cadence

The LVGL task owns visible objects, the front RGB565 frame, the live route
foreground, and the arrow. A low-priority worker owns map-block IO, geometry,
building admission, and raw RGB565 rasterization into the hidden frame. It never
calls LVGL. A completed frame is published by a short UI-side pointer swap.

Each request carries a monotonic sequence plus diagnostic route revision and
navigation, style, map, and projection epochs. GPS movement and route-window
requests are coalesced: an active render
may finish and publish when those frame semantics still match, even if newer
position sequences exist. This prevents a long 3D render from being cancelled
continuously by the 750 ms intake cadence. Route geometry is a live foreground
input; navigation-session, style, map-root, projection, and screen
invalidations cancel at the next cooperative checkpoint.

The request center is led toward the rider's expected position using speed and
the most recent render duration, capped by the 96-pixel overscan minus the
16-pixel safety margin. Immediately before publication, all four viewport
corners are inverse-transformed into the candidate frame. A frame that no
longer covers the translated and rotated viewport is rejected and replaced;
an already-uncovered candidate is never newly published. If later presentation
motion exhausts a visible frame's margin, it immediately schedules a
replacement while retaining the last complete frame.

While presentation is changing, the visible frame is translated and rotated at
UI cadence using one `PresentedPose`. The live route head, route line, and arrow
use the same pivot, anchor, and rotation delta. Pose/frame/route/style
signatures make stable ticks no-ops: they do not invalidate the base image or
clear and redraw the full foreground alpha plane. Test and real navigation use
the same 1 Hz device-pose heartbeat. Dead reckoning remains at full speed for
1.5 seconds, then linearly decelerates to a hard stop at 2.5 seconds, with a
distance cap of 30 metres. This bridges one missed heartbeat without allowing
unbounded motion, and all visible layers stop from the same pose when the
horizon is exhausted. Each new phone fix converges from that shared pose.

The full-speed window (1.5 seconds), hard horizon (2.5 seconds), and distance
cap (30 metres) are static policy values from implementation commit
`a02e24a3139d93a507cc716818ba7bcb151cf736`, based on `origin/main`
`15d806613b680621b923b311ec30b2470fd4b349`. They apply to both
`WAVESHARE_AMOLED_175` and `WAVESHARE_AMOLED_206` and have no map/navigation
fixture; they are not runtime or externally measured values. Device validation
of the timing policy remains part of the physical gate below.

The overscanned base canvas remains LVGL center-aligned; its position is an
offset from the resolved centered origin. Presentation converts the desired
parent-space pivot target to that aligned offset exactly once, so the 96-pixel
overscan crop cannot become a heading-relative base/route displacement.

## 3D-building admission

FMB v4 records are considered across all loaded in-view blocks and selected by
stable rider-distance and block/record identity. The default 8 MiB quotas are:

| Resource | Total | Extruded |
| --- | ---: | ---: |
| Records | 96 | 32 |
| Source points | 8,192 | 3,072 |
| Projected pixels | 220,000 | 90,000 |

Nearest records retain 3D; farther admitted records render flat roofs; records
outside the quota are deferred. Courtyard snapshots are clipped to the raw
surface and capped at 180,000 pixels. A building whose courtyard exceeds that
workspace remains rendered with its walls and a deterministic solid roof; only
the courtyard underlay restoration is deferred. A genuine allocation failure retries with
a smaller deterministic flat-footprint set. A timing checkpoint or GPS update
does not turn a healthy frame into a flat fallback.

The guidance-screen flag is deliberately separate from route/maneuver
availability. Bird's-eye and configured 3D buildings therefore remain active on
the Map + Navigation screen before a route starts. If course-up has no heading
yet, that idle first frame may be north-up; active guidance still requires a
measured course, route bearing, or prior valid guidance frame.

## Validation boundary

The focused host contracts cover worker ownership, semantic invalidation,
position-only coalescing, shared presentation transforms, heading fallback and
epoch reset, one-missed-heartbeat prediction, finite transport-loss stopping,
pre-publication overscan coverage, deterministic building
admission, solid-roof courtyard overflow, asynchronous runtime map activation,
and cross-version heading protocol behavior. The required physical gate is an exact
`WAVESHARE_AMOLED_175` build followed by device navigation with an FMB v4 pack in
idle guidance, test navigation, and real navigation. Record UI maximum gap,
display flush interval, render diagnostics, building counts, and free/largest
PSRAM. Until that run is completed, this document does not claim runtime
success.
