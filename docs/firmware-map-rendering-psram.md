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
| 466 x 466 RGB565+A8 live foreground | 1,298,892 |
| Persistent surface total | 3,030,748 (2.89 MiB) |

These are static sizes from the implementation based on `origin/main`
`66692af1`. Free PSRAM, largest-contiguous PSRAM, map-block cache, temporary
building workspace, and SD latency remain runtime concerns. No battery claim is
derived from these sizes.

## Rendering ownership and cadence

The LVGL task owns visible objects, the front RGB565 frame, the live route
foreground, and the arrow. A low-priority worker owns map-block IO, geometry,
building admission, and raw RGB565 rasterization into the hidden frame. It never
calls LVGL. A completed frame is published by a short UI-side pointer swap.

Each request carries a monotonic sequence plus route, navigation, style, map,
and projection epochs. GPS movement requests are coalesced: an active render
may finish and publish when those frame semantics still match, even if newer
position sequences exist. This prevents a long 3D render from being cancelled
continuously by the 750 ms intake cadence. Route replacement, style, map-root,
projection, and screen invalidations cancel at the next cooperative checkpoint.

The visible frame is translated and rotated every UI tick using one
`PresentedPose`. The live route head, route line, and arrow use the same pivot,
anchor, and rotation delta. Dead reckoning is finite (1.5 seconds and 30 metres
by default) and converges to each new phone fix.

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
surface and capped at 180,000 pixels. A genuine allocation failure retries with
a smaller deterministic flat-footprint set. A timing checkpoint or GPS update
does not turn a healthy frame into a flat fallback.

The guidance-screen flag is deliberately separate from route/maneuver
availability. Bird's-eye and configured 3D buildings therefore remain active on
the Map + Navigation screen before a route starts.

## Validation boundary

The focused host contracts cover worker ownership, semantic invalidation,
position-only coalescing, shared presentation transforms, heading fallback and
epoch reset, deterministic building admission, courtyard workspace limits, and
legacy protocol behavior. The required physical gate is an exact
`WAVESHARE_AMOLED_175` build followed by device navigation with an FMB v4 pack in
idle guidance, test navigation, and real navigation. Record UI maximum gap,
display flush interval, render diagnostics, building counts, and free/largest
PSRAM. Until that run is completed, this document does not claim runtime
success.
