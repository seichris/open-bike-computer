# Firmware map-rendering and PSRAM budget

This is the short source of truth for the ESP32 map renderer's memory and
performance budget. Keep measured values tied to a Git revision and board
profile; distinguish estimates from device measurements.

## Current 1.75-inch budget

The Waveshare 1.75-inch device has 8 MiB PSRAM. Guidance keeps the 466 x 466
visible map continuously moving by rendering an overscanned 658 x 658 frame.
The known persistent map buffers are:

| Revision / frame | Screen RGB565 | Temp RGB565 | Foreground RGB565A8 | Total |
| --- | ---: | ---: | ---: | ---: |
| `283d2442`, 466 x 466 | 434,312 B | 508,040 B | 651,468 B | 1,593,820 B (1.52 MiB) |
| `60407746`, 658 x 658 guidance | 865,928 B | 865,928 B | 1,298,892 B | 3,030,748 B (2.89 MiB) |

The 2.89 MiB figure is within an 8 MiB PSRAM device, but free bytes,
largest-contiguous block, temporary allocations, and the building render
deadline still matter. A previous `60407746` device run measured 7,423,160 B
free before Map + Navigation setup and 4,375,724 B after it (a 3,047,436 B
drop, including renderer overhead).

## 3D-building workspace

The building pass now snapshots only the projected courtyard bounding box and
clips it to the canvas. One snapshot is capped at the visible viewport size:

- 1.75-inch full-screen 466 x 466: at most 434,312 B (0.41 MiB);
- 1.75-inch non-fullscreen 466 x 366: at most 341,112 B (0.33 MiB);
- ordinary courtyards are smaller than either bound.

Before this change, a courtyard snapshot could copy the entire 658 x 658
guidance canvas (865,928 B / 0.83 MiB). If a courtyard exceeds the cap or an
allocation fails, its roof/hole is left unfilled so the real 2D underlay stays
visible; the rest of the 2D map and other building surfaces still render.
With `WAVESHARE_MAPIO_TIMING_LOG` or touch diagnostics enabled, the building
log reports `courtyardMaxBytes` and `courtyardBudgetBytes`.

## Validation and maintenance

For relevant implementation or device tests, append the revision/profile,
visible and render frame sizes, PSRAM free/largest values, building snapshot
bytes, render timings, map/GPS fixture, and pass/fallback result here. Battery
claims require a source-monitor test with USB disconnected; static PSRAM size
alone is not a battery-current measurement. The current compact-snapshot
implementation is host-tested and the deterministic
`WAVESHARE_AMOLED_175` firmware build passes; a new device flash/navigation run
is still required before calling its runtime behavior validated.
