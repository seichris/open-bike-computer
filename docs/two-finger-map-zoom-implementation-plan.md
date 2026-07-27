# Two-Finger Map Zoom Implementation Plan

## Outcome

Add responsive two-finger pinch zoom to the ESP32 device's full Map screen on
the Waveshare ESP32-S3-Touch-AMOLED-1.75.

During a pinch, the visible map frame scales continuously with the fingers.
The vector map, rendered route, and current-position placement stay aligned,
and the gesture does not trigger map drag, a short tap, rotation toggle, screen
cycling, or toolbar controls. When the gesture ends, firmware selects the
nearest supported map zoom level, renders that level once into the existing
back buffer, swaps it into view, and removes the temporary image transform.

This is an ESP32-only feature. It does not change BLE, the iPhone app, offline
map files, map styling, or the persisted Map and Map + Navigation profile
defaults.

## Baseline

This plan was prepared from `origin/main` at
`e2f9d0ad76b9d15c0c24def0302d16ff4d31ff32`.

### Hardware capability

The 1.75-inch board uses the CST9217 touch controller. Waveshare's official
diagnostic says the board supports two simultaneous touch points and exercises
the controller with two coordinate arrays:

- [CST9217 diagnostic documentation](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75/blob/main/examples/arduino/10_Touch_CST9217/README.md)
- [CST9217 two-point example](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75/blob/main/examples/arduino/10_Touch_CST9217/10_Touch_CST9217.ino)
- [CST9217 reference parser](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75/blob/main/examples/arduino/libraries/SensorLib/src/touch/TouchDrvCST92xx.cpp)

The reference parser reads a 15-byte frame from register `0xD000`, validates
the acknowledgement at byte 6, obtains the active count from byte 5, and
decodes at most two finger records with stable finger IDs. It acknowledges the
frame after the read.

### Current touch path

The current production firmware does not expose the controller's second point:

1. `waveshare_board::touch::CST9217_DATA_LENGTH` is 10 bytes.
2. `readTouch()` reads the reported point count but decodes only the first
   status, X, and Y fields.
3. Global state is limited to `touchPressed`, `touchX`, and `touchY`.
4. `my_touchpad_read()` rotates and publishes one point through LVGL's pointer
   input callback.
5. `DISABLE_GESTURES=1` intentionally disables the old LovyanGFX-specific
   gesture implementation on both Waveshare Arduino_GFX targets.

The new work must not re-enable that legacy gesture path. It must introduce a
small controller-independent gesture layer that works with the existing
Arduino_GFX touch driver.

### Current map path

The vector map is synchronously rasterized into an RGB565 LVGL canvas. Current
`main` already maintains a visible front map buffer and a hidden back map
buffer in PSRAM. `Maps::generateVectorMap()` draws the vector features and the
route into the hidden canvas, then atomically swaps the buffers.

This double-buffered architecture is the settlement path for pinch zoom. The
gesture must not rerasterize vector data or read map blocks for every touch
sample. It temporarily transforms the visible canvas, then requests one normal
vector render at the chosen discrete level.

The current zoom levels are discrete and non-linear:

| Runtime zoom | World-to-screen scale |
| ---: | ---: |
| 1 | `1.5x` |
| 2 | `1.0x` |
| 3 | `0.5x` |
| 4 | `1/3x` |
| 5 | `0.25x` |

Map features, the route overlay, off-center current-position placement, and
map dragging repeat this scale calculation in several locations. The pinch
implementation needs one shared transform helper so visual preview,
settlement, route placement, and center adjustment cannot disagree.

## Product contract

- Two-finger pinch is enabled only on the full Map tile (`activeTile == MAP`)
  in the first release.
- It works in normal and full-screen Map layouts.
- Moving the fingers apart zooms in; moving them together zooms out.
- The visible map responds continuously while two valid contacts are present.
- The route is part of the map canvas and transforms with the map.
- The current-position marker keeps a constant visual size.
- While GPS following is enabled, zoom is anchored at the current-position map
  anchor and GPS following remains enabled.
- While GPS following is disabled, zoom is anchored at the pinch midpoint and
  the settled geographic center is adjusted so the focal map point does not
  jump.
- A small or noisy two-finger contact that never crosses the activation
  threshold settles back to the current zoom without rerendering.
- The remaining finger is ignored after one finger lifts. Normal one-finger
  interaction resumes only after both fingers have been released.
- The gesture may cross more than one zoom level, but cannot exceed runtime
  zoom levels 1 through 5.
- The final runtime zoom behaves like the existing on-device zoom buttons. It
  does not write NVS, change iPhone settings, or modify either persisted map
  profile.
- Existing `+` and `-` controls remain available and use the same bounded
  runtime zoom request helper as pinch settlement.
- Map + Navigation, the destination picker, other device screens, and the
  2.06-inch board retain their existing touch behavior in the first release.

## Decisions locked into this plan

1. Use the CST9217's documented two-point frame instead of inferring a second
   contact from gesture direction or controller point count alone.
2. Keep all I2C access outside interrupts. The GPIO interrupt remains a read
   hint; it must not call `Wire` from an ISR.
3. Preserve the current interrupt-gated polling, retry, grace, and recovery
   behavior. Do not return to rapid idle polling.
4. Do not vendor the full Waveshare SensorLib. Implement the narrow packet
   transaction and decoder required by this board, with attribution where
   reference behavior materially informed the implementation.
5. Preserve a single primary contact for ordinary LVGL input so all current
   one-finger screens continue to work.
6. Detect pinch below the LVGL widget gesture system. LVGL continues to receive
   one pointer; the Map screen consumes the separate two-contact snapshot.
7. Once two contacts appear, suppress the primary LVGL pointer until all
   contacts are released. This prevents a partial pinch from becoming a click,
   drag, long press, or screen-cycle action.
8. Use a pure, host-testable pinch state machine. Board I/O, gesture math, and
   Map/LVGL presentation remain separate layers.
9. Scale the existing visible canvas during the gesture. Do not allocate a
   third full-size map framebuffer.
10. Do not rerasterize on each finger update. Queue GPS, route, and heading
    redraw requests and service them after the gesture settles.
11. Quantize the final zoom in logarithmic scale space because adjacent runtime
    levels are not evenly spaced.
12. Keep the position marker at its configured pixel size; transform its
    position, not its artwork scale.
13. Ship only after the physical 1.75-inch performance and touch-stability
    gates pass. Build success alone is not sufficient.

## Proposed architecture

```text
CST9217 I2C frame
        |
        v
two-contact packet decoder -----> primary contact compatibility -----> LVGL
        |
        v
immutable TouchFrame snapshot
        |
        v
MapPinchZoomController
  Idle -> Candidate -> Active -> Settling -> SuppressedUntilRelease
        |                         |
        |                         +---- one discrete vector render
        v
temporary LVGL canvas transform
```

### Touch frame contract

Add a small board-neutral value model, for example:

```cpp
struct TouchContact {
  uint8_t id;
  uint16_t x;
  uint16_t y;
  uint8_t status;
};

struct TouchFrame {
  uint32_t sequence;
  uint32_t sampledAtMs;
  uint8_t count;
  TouchContact contacts[2];
};
```

Coordinates exposed to consumers are display-space coordinates after the same
rotation currently applied to the primary LVGL point. The decoder itself
operates on raw controller bytes and remains independent of Arduino, LVGL, and
the Map screen.

Sort or associate contacts by the CST9217 finger ID so array order cannot flip
when fingers cross. Retain the same primary finger ID until every contact is
released. `touchPressed`, `touchX`, and `touchY` remain compatibility views of
that primary contact during the migration.

Publish frames through a copied snapshot with a monotonic sequence number. Do
not expose a mutable pointer into the panel driver. The LVGL input callback and
the Map timer currently run on the LVGL execution path, but the snapshot API
should remain safe if display/input scheduling changes later.

### CST9217 transaction and decoding

For the 1.75-inch target:

1. Increase the frame buffer to the vendor-compatible 15-byte length.
2. Read from register `0xD000` through the existing shared I2C helper and retry
   policy.
3. Send the vendor acknowledgement sequence after a successful read by adding
   the smallest required 16-bit-register write helper to `i2c_bus`.
4. Validate byte 6, point count, finger ID, status, and both coordinates before
   publishing a new frame.
5. Decode the first record from byte 0 and the second record from the vendor's
   second-record offset.
6. Preserve the current tolerance for continuing `status == 0x00` reports, but
   require a valid press status before introducing a new finger ID.
7. If the read or acknowledgement fails, use the existing active-touch grace
   period and recovery policy; never publish a partially decoded frame.
8. Clear both contacts when the controller reports zero points or the existing
   release-grace policy expires.
9. Rate-limit diagnostic output. Ordinary production builds must not print raw
   coordinates or the full packet on every sample.

The 2.06-inch FT3168 path continues to publish at most one contact. It uses the
same `TouchFrame` type with `count <= 1`, which gives common downstream code
without claiming unsupported hardware behavior.

### Pinch state machine

Add a pure `MapPinchZoomController` with no LVGL, Arduino, I2C, or global Map
dependencies.

States:

- **Idle**: fewer than two contacts and no gesture-owned release sequence.
- **Candidate**: two valid contacts have appeared; record finger IDs, initial
  distance, midpoint, runtime zoom, follow state, viewport center, and map
  rotation.
- **Active**: distance change has crossed the activation threshold. Produce a
  clamped continuous scale and the current midpoint for the presenter.
- **Settling**: contact count fell below two; choose the final discrete zoom or
  cancel to the original level.
- **SuppressedUntilRelease**: ignore the remaining finger until the controller
  reports zero contacts, then return to Idle.

Initial tuning constants should be named and tested rather than embedded in UI
callbacks. Start physical tuning with:

- minimum initial finger separation: 40 px;
- activation distance change: max of 10 px or 4 percent;
- two consecutive valid two-contact frames before activation;
- release after two consecutive frames below two contacts, unless the driver
  reports an explicit clean release; and
- bounded low-pass filtering that favors latency over perfect smoothness.

These are starting values, not permission to tune by intuition. Record raw
jitter and contact-loss evidence on the physical panel before finalizing them.

The state machine returns decisions such as `none`, `begin`, `update`,
`commit(targetZoom)`, and `cancel`. It does not mutate the global `zoom` value.

### Shared zoom and coordinate math

Introduce a host-testable map transform helper that owns:

- valid runtime zoom bounds;
- world-to-screen scale for each runtime zoom;
- inverse screen-to-world scale;
- log-space nearest-level selection;
- rotation-aware screen delta to Mercator delta conversion; and
- focal-point-preserving center adjustment.

Use this helper in the new pinch path and replace the duplicated scale branches
in the directly affected map, route, marker, and drag code. Keep the existing
IceNav-derived renderer structure, feature culling, map blocks, and filled-line
rasterizer intact.

When GPS following is enabled, the visual pivot is
`mapInteractionAnchorX/Y()` and the settled center remains the latest GPS map
point. When following is disabled, calculate the world point under the initial
pinch midpoint and choose the new center that leaves it under the final
midpoint at the target zoom and current rotation.

### LVGL presentation

`lv_canvas` inherits LVGL's image behavior, so the visible map canvas can use
the LVGL image scale and pivot APIs without copying its RGB565 pixels.

On `begin`:

1. Confirm the Map tile is active and both map canvases are available.
2. Latch gesture ownership and cancel/reset the ordinary pointer interaction.
3. Capture the visible canvas geometry, zoom, viewport center, follow state,
   rotation, and marker position.
4. Set the image pivot to the chosen map anchor.

On each `update`:

1. Convert the pinch ratio to an LVGL image scale relative to `LV_SCALE_NONE`.
2. Clamp the scale to the supported zoom range.
3. Apply scale and any required midpoint translation to `canvasMap`.
4. Keep the marker artwork at its configured size.
5. If following is disabled, reposition the marker using the same temporary
   transform; if following is enabled, keep it at the map interaction anchor.
6. Invalidate only the map presentation objects needed for the frame.
7. Leave toolbars, notification chrome, and non-map overlays untransformed.

For pinch-out/zoom-out, shrinking an exact-size source canvas necessarily
reveals pixels that were never rasterized. The first release must clip the
canvas to the map viewport and fill those temporary gutters with the active
map style's background color; it must never reveal black, stale, or
uninitialized memory. Do not hide the limitation with a third framebuffer or
claim that the source contains off-screen map detail. Once the target level is
known, render it into the existing back canvas, present it with the inverse
temporary scale needed to match the final gesture frame, then animate or
settle it to `LV_SCALE_NONE`. The target frame fills the viewport after the
swap. The physical polish gate decides whether the short settlement animation
and temporary style-colored gutters are acceptable; if not, implementation
must stop and propose an overscan or level-crossing render design with measured
memory and latency costs.

On `commit`:

1. Apply the selected runtime zoom and any focal center adjustment.
2. Keep the transformed old front frame visible.
3. Render the target level into the hidden back buffer through the existing
   synchronous vector path.
4. Swap only after the target frame and route are complete.
5. Transfer presentation to the completed frame, settle it to neutral scale,
   and reset pivot/position state.
6. Apply any GPS, route, style, or heading update queued during the gesture.
7. Release gesture ownership only after all fingers are up.

If target rendering is interrupted, keep the previous front frame and the
gesture's target state, clear unsafe partial transforms, and request a clean
retry. Never expose the partially rendered back buffer.

### Input ownership and renderer coordination

Add one source of truth for `mapPinchOwnsInput()`.

While Candidate, Active, Settling, or SuppressedUntilRelease:

- LVGL receives a released/suppressed primary pointer;
- `scrollMapEvent()` ignores press, pressing, release, click, and long-press
  behavior from that contact sequence;
- toolbar zoom/full-screen controls do not fire;
- map short-tap rotation and tap-to-switch do not fire;
- screen-cycle touch handling does not consume the pinch;
- new synchronous map renders are deferred; and
- incoming redraw reasons remain queued rather than discarded.

Extend the existing map-render interruption checkpoints narrowly enough that a
gesture that becomes active during block loading can leave the hidden back
buffer incomplete without changing the visible front buffer. Do not perform
CST9217 I2C reads from the renderer or interruption callback.

## Implementation phases

### Phase 0: physical two-contact feasibility gate

Before changing Map behavior, add a diagnostic-only build flag or environment
that reports, at a limited rate:

- controller-supported point count;
- point IDs and raw/display coordinates;
- frame sequence and sample interval;
- point-order changes;
- invalid frames and contact-loss events; and
- shared I2C failure/recovery counters.

On the physical 1.75-inch device, validate two stationary fingers, independent
movement, fingers crossing, edge contacts, rapid second-finger addition, and
lifting either finger first. Confirm stable operation for at least ten minutes
of repeated gestures.

Gate: do not proceed to Map integration until two independent, stable contacts
are demonstrated without increasing I2C failures or resetting the touch/display
path.

### Phase 1: touch frame and decoder

- Add the pure CST9217 frame decoder and fixture tests.
- Add the two-contact `TouchFrame` snapshot API.
- Extend the I2C transaction to the complete frame and acknowledgement.
- Preserve primary-point LVGL behavior and all current release/recovery rules.
- Keep the 2.06 FT3168 path source-compatible with one contact.
- Repeat the Phase 0 physical matrix with the production touch path.

### Phase 2: gesture math and ownership

- Add the pure pinch state machine and map transform helper.
- Add host tests for activation, jitter, finger order, cancellation, bounds,
  log-space quantization, rotation, focal-center preservation, and release
  suppression.
- Integrate ownership with the LVGL pointer and existing Map event callbacks.
- Verify ordinary one-finger drag, tap, long press, toolbar controls, and screen
  cycling are unchanged when no pinch occurs.

### Phase 3: continuous preview and settlement

- Apply live canvas scaling and pivot updates without vector rerendering.
- Keep marker size and route alignment correct.
- Defer redraw work while pinching.
- Settle through the existing hidden back buffer and atomic swap.
- Handle cancellation, min/max bounds, target-render interruption, screen
  change, and map-canvas recreation safely.
- Add rate-limited performance instrumentation.

### Phase 4: validation and documentation

- Run host tests and both board firmware build matrices.
- Complete the physical gesture, regression, stability, and performance gates.
- Document the verified 1.75-inch two-point behavior in `hardware/README.md`.
- Remove or compile out packet-level diagnostics from normal firmware.
- Record measured frame intervals, render-settlement time, free PSRAM, largest
  free PSRAM block, and I2C counters in the implementation pull request.

## Expected file changes

| Area | Expected change |
| --- | --- |
| `esp32/lib/waveshare_board/touch.hpp` | CST9217 frame constants and maximum contacts |
| `esp32/lib/waveshare_board/i2c_bus.hpp/.cpp` | Narrow 16-bit-register acknowledgement write helper |
| New touch decoder/value header under `esp32/lib/waveshare_board/` | Pure frame decoding and `TouchFrame` contract |
| `esp32/lib/panel/WAVESHARE_AMOLED_175.hpp/.cpp` | Two-point read, rotation, snapshot publication, and primary-point compatibility |
| New pinch controller under `esp32/lib/utils/src/` | Pure gesture state machine |
| New map transform helper under `esp32/lib/maps/src/` | Shared zoom, rotation, and focal-center math |
| `esp32/lib/gui/src/mainScr.hpp/.cpp` | Gesture ownership, event suppression, and runtime zoom settlement |
| `esp32/lib/maps/src/maps.hpp/.cpp` | Canvas preview, marker positioning, queued redraw, and back-buffer settlement |
| `esp32/lib/route_overlay/route_overlay.cpp` | Use shared scale transform where required for alignment |
| `esp32/tools/tests/` | Decoder, state-machine, and transform host tests |
| `.github/workflows/ci.yml` | Compile and run the new host tests |
| `hardware/README.md` | Physically verified multi-touch behavior and limitations |

Exact names may change during implementation, but the separation between board
I/O, pure gesture logic, coordinate math, and LVGL presentation must remain.

## Host test matrix

### CST9217 decoding

- zero-contact frame;
- one valid contact;
- two valid contacts with distinct IDs;
- swapped record/ID order;
- second-contact coordinate boundaries;
- malformed acknowledgement;
- count greater than two;
- invalid status;
- out-of-range coordinate;
- truncated frame;
- continuing `status == 0x00` for a known finger; and
- invalid new finger with `status == 0x00`.

### Pinch state machine

- two-finger candidate without enough motion cancels;
- outward movement commits zoom in;
- inward movement commits zoom out;
- multiple-level gesture;
- minimum and maximum zoom clamp;
- jitter around the activation threshold;
- finger IDs reorder without scale reversal;
- one finger lifts before activation;
- one finger lifts after activation;
- remaining finger stays suppressed until full release;
- stale/duplicate frame sequence is ignored;
- sudden implausible coordinate jump is rejected; and
- screen/context cancellation resets safely.

### Map transform

- exact scale values for runtime zoom 1 through 5;
- nearest-level quantization at every boundary;
- north-up focal center preservation;
- course-up focal center preservation across representative headings;
- follow-GPS anchor remains fixed;
- off-center marker position transforms while marker size remains constant;
- normal/full-screen viewport anchors; and
- forward/inverse transform round trips within integer rounding tolerance.

## Physical validation matrix

Before the first build, upload, serial capture, or device debug action in the
implementation task, confirm which physical device is connected. Perform the
feature validation on a Waveshare 1.75-inch board.

Test all of the following:

1. Pinch in and out by one level around the center.
2. Cross multiple levels in one gesture.
3. Attempt to exceed both zoom bounds.
4. Hold one finger still while moving the other.
5. Move both fingers symmetrically.
6. Cross the two fingers and verify there is no scale reversal.
7. Lift the first finger, then repeat while lifting the second finger first.
8. Add and remove the second finger without crossing the activation threshold.
9. Pinch with the toolbar visible and hidden.
10. Pinch in normal and full-screen Map layouts.
11. Pinch in north-up and course-up modes.
12. Pinch while GPS following is enabled.
13. Pan to disable following, then pinch around an off-center midpoint.
14. Pinch with a route loaded and verify route/map alignment.
15. Receive BLE GPS and route updates during a pinch and verify the queued
    redraw settles cleanly.
16. Verify one-finger pan, short tap, marker rotation toggle, long-press
    recenter, toolbar zoom, full-screen toggle, and screen cycling afterward.
17. Attempt two-finger input on Map + Navigation and other screens and confirm
    no new action occurs.
18. Run repeated mixed gestures for at least ten minutes without a watchdog,
    reboot, blank display, touch loss, or I2C recovery growth.

Also build and smoke-test the 2.06-inch target to confirm its existing
single-contact dragging and all non-pinch screens remain unchanged.

## Performance gates

Instrument before optimizing. Record touch sample timestamps, visual update
timestamps, display flush duration, settlement render duration, free heap,
free PSRAM, largest free PSRAM block, and I2C counters.

The feature is ready to ship only when the physical 1.75-inch device meets all
of these gates:

- steady two-contact sampling has a median interval at or below 35 ms;
- continuous visual preview sustains at least 15 frames per second at the 95th
  percentile frame interval;
- no preview frame stalls for more than 150 ms before settlement rendering;
- final settlement is no more than 20 percent slower than a matching existing
  discrete zoom-button render at the same location and style;
- no third full-screen map buffer is allocated;
- repeated pinches do not create unbounded heap/PSRAM loss;
- I2C failed/recovered transaction counters do not grow during the ten-minute
  stability run; and
- no route/marker misalignment, half-rendered canvas, black/uninitialized edge
  exposure, watchdog, reboot, or touch lockup is observed; temporary gutters
  during inward pinch use only the active map background color and pass the
  physical polish review.

If LVGL software scaling cannot meet these gates, stop and report the measured
limit. Do not replace the design with per-sample vector rerasterization or ship
a gesture that only appears smooth in simulator/host tests.

## Automated verification

Required local/CI checks for the implementation:

```sh
cd esp32

# New host tests, using the same warnings-as-errors posture as other pure logic.
g++ -std=c++17 -Wall -Wextra -Werror \
  tools/tests/test_cst9217_touch_frame.cpp \
  -o /tmp/test_cst9217_touch_frame
/tmp/test_cst9217_touch_frame

g++ -std=c++17 -Wall -Wextra -Werror \
  tools/tests/test_map_pinch_zoom.cpp \
  -o /tmp/test_map_pinch_zoom
/tmp/test_map_pinch_zoom

# Both production device targets must still compile.
pio run -e WAVESHARE_AMOLED_175
pio run -e WAVESHARE_AMOLED_206
```

CI continues to build the speaker-honk variants as part of its existing
four-target matrix. The new host tests must be added to the `esp32-host` job.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Larger CST9217 reads destabilize shared I2C | Preserve interrupt gating/retries, add the vendor acknowledgement, and require the physical stability gate before Map integration |
| Finger record order changes | Track controller finger IDs and test crossing/reordering |
| A partial pinch becomes a tap or drag | Latch ownership at two contacts and suppress until all contacts release |
| Synchronous map render masks input | Defer new renders while pinching and retain safe interruption checkpoints with the hidden back buffer |
| Zoom-out exposes pixels outside the exact-size canvas | Clip to the viewport, fill temporary gutters with the active map background, and settle through the rendered target back buffer; black, stale, or uninitialized pixels fail acceptance |
| Canvas scaling is too slow with software rotation | Measure physical frame intervals and stop if the explicit performance gate fails |
| Route or marker diverges from the map | Centralize affected scale/rotation math and test focal/marker/route alignment |
| GPS update recenters during pinch | Queue redraw inputs; preserve follow anchoring or panned focal center according to the captured follow state |
| 2.06 behavior regresses | Keep count at one on FT3168, compile both targets, and physically smoke-test existing drag behavior |
| Diagnostics flood serial or expose coordinates | Rate-limit and compile out packet-level logging in production |

## Out of scope

- Multi-touch support for the Waveshare 2.06-inch FT3168 controller.
- Pinch zoom on Map + Navigation or the destination picker.
- Continuous vector rerasterization at every touch sample.
- Fractional zoom persistence after the fingers are released.
- Changing zoom defaults or synchronizing runtime pinch state to iPhone.
- Rotation, tilt, or two-finger pan gestures.
- Changing map-stream, offline-map, BLE, or iOS contracts.
- Replacing the current map renderer or full-screen/back-buffer strategy.
- Adding the complete Waveshare SensorLib dependency.

## Definition of done

Implementation is complete only when:

- the 1.75-inch CST9217 path publishes two stable contacts from real hardware;
- host tests cover packet parsing, gesture ownership, zoom selection, and map
  transforms;
- two-finger pinch continuously previews and settles correctly on the physical
  1.75-inch Map screen;
- no accidental tap, drag, long press, toolbar, rotation, or screen-cycle
  action leaks from a pinch;
- route and marker presentation remain aligned in every required mode;
- the physical stability and performance gates pass with recorded evidence;
- both production firmware targets and existing CI variants build;
- existing one-finger interaction remains physically verified on 1.75 and
  smoke-tested on 2.06;
- normal firmware contains no high-volume raw touch logging; and
- hardware documentation records the verified capability and limitations.
