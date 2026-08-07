# Firmware map memory diagnostics

The ESP32 map renderer has opt-in, machine-readable memory samples for
diagnosing heap pressure and PSRAM fragmentation during map work. These
samples are telemetry only: they do not change allocation, rendering, or
fallback policy.

## Enabling the samples

The structured samples are emitted when either
`WAVESHARE_MAPIO_TIMING_LOG` or `WAVESHARE_TOUCH_DIAGNOSTICS` is enabled. The
tracked `WAVESHARE_AMOLED_175_MAPIO_DIAGNOSTICS` and
`WAVESHARE_AMOLED_206_MAPIO_DIAGNOSTICS` profiles enable the stream on both
supported boards. The normal firmware keeps the existing human-readable
`FreeHeap` messages, but does not print the structured stream unless one of
those diagnostics profiles is selected.

## Structured memory samples

The renderer emits lines in this form:

```text
MAPIO: memory phase=canvas-draw freeInternalHeap=... \
largestInternalHeap=... \
freePsram=... largestPsram=... psramUsed=... psramTotal=...
```

Samples are taken after the map-block cache pass and after successful or empty
canvas rendering. Each phase is rate-limited to one line every 250 ms so
rolling raster cells and pinch backdrops do not turn the diagnostic stream into
a source of serial/UI timing distortion while a fast render still produces
both its cache and canvas boundary samples. The `phase` value distinguishes
`block-cache`, `canvas-draw`, `canvas-no-map`, and `canvas-draw-empty`.

Building summaries include the same internal-heap fields plus the existing
PSRAM fields. They also report:

- `courtyardSnapshots`: number of courtyard underlay captures in the pass;
- `courtyardMaxBytes`: largest allocated underlay-vector capacity in bytes;
- `freeInternalHeap` and `largestInternalHeap`: internal 8-bit heap
  availability at the end of the pass;
- `psramUsed`, `psramFree`, and `psramLargest`: PSRAM availability at the end
  of the pass.

Building-abort summaries capture the heap and PSRAM values before the failure
workspace is released, including the deferred screen-cycle interruption path,
so allocation, deadline, and interruption outcomes can be compared with
successful passes. `psramUsed` is calculated as `psramTotal - psramFree`; it is
a total occupancy estimate, not an attribution to a particular buffer.

## Interpreting a capture

Record the firmware revision, board/profile, map fixture, navigation state,
render phase, and the four free/largest values. A falling `largestPsram` with
stable `freePsram` indicates fragmentation; a simultaneous fall in both values
indicates live allocation pressure. `courtyardMaxBytes` identifies the largest
allocated courtyard-underlay vector capacity that overlapped the render pass.

These diagnostics are not a battery measurement. Battery claims require a
source-monitor capture with USB power disconnected; static PSRAM capacity or a
single free-memory sample is insufficient.
