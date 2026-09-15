# Waveshare 3.97-inch e-paper navigation smoothing implementation plan

## Status and baseline

This is a planning-only follow-up to the Waveshare ESP32-S3-ePaper-3.97 port in
PR #442. The plan is based on the exact PR #442 head
`cfa2cb8259ce74e370518db45786c4223e288ae2` and targets only firmware compiled
with `WAVESHARE_EPAPER_397`.

A source comparison used OpenTrailPaper commit
[`10e2401229432150b1b6252f47d757a7cf971e95`](https://github.com/RaemondBW/OpenTrailPaper/commit/10e2401229432150b1b6252f47d757a7cf971e95)
as a reference for current-state snapshots, bounded map work, heading stability,
and readable-content preservation. OpenTrailPaper's panel waveforms, power
sequence, H3 storage format, onboard GPS ownership, and route-matching authority
are not implementation dependencies and must not be copied into this target.

Physical testing of PR #442 established that startup, BLE, SD map recovery,
static map rendering, controls, SSD1677 full/partial updates, sensors, and idle
controller sleep work. During actual movement and navigation, the map did not
remain usefully current. A code audit found a deterministic scheduling conflict
that can produce this symptom; a controlled moving-navigation replay and ride
are still required to prove the complete cause and the final behavior.

## Required outcome

While navigating on the 3.97-inch e-paper device:

- Keep the last complete and geographically compatible map visible while a
  replacement is rendered.
- Apply the latest rider position, route foreground, and navigation instruction
  without waiting for a new base-map render.
- Recenter or rotate the base map at a bounded riding cadence using the latest
  accepted state, without accumulating historical GPS render jobs.
- Coalesce panel work to the latest complete frame and avoid redundant
  waveforms.
- Make stale, missing-coverage, and rendering-failure states explicit instead of
  presenting an unexplained white map.
- Preserve the existing physical-presentation fence: a frame becomes `shown`
  only after its SSD1677 waveform completes successfully.

For this panel, smooth navigation means a stable readable update approximately
every one to two seconds while moving. It does not mean AMOLED-style animation.

## Non-goals

This work must not:

- Change the compiled behavior of `WAVESHARE_AMOLED_175` or
  `WAVESHARE_AMOLED_206`, including their production and diagnostic profiles.
- Change the BLE navigation protocol or move navigation authority from the
  iPhone to the firmware.
- Adopt OpenTrailPaper's panel driver, electrical waveform policy, H3 map format,
  or onboard route-progress implementation.
- Treat the QMI8658 gyroscope as an absolute compass. The device has no
  magnetometer.
- Add 3D buildings, redesign map styling, replace the IceNav-derived renderer,
  or broaden this work into a renderer refactor.
- Change the proven SSD1677 mailbox, successful-`shown` baseline, waveform
  spacing, full-refresh cap, or 60-second controller-idle policy unless separate
  physical evidence requires it.

## Verified failure mechanism

The current UI timer observes state every 30 ms, but the e-paper branch in
`prepareVisibleMapUpdate()` returns for four seconds before it can service the
map presentation pipeline:

```text
updateMainScreen()
  -> observe GPS/route/navigation signatures
  -> prepareVisibleMapUpdate()
       -> e-paper four-second early return
       -> serviceRenderPipeline()
       -> updatePositionOverlay()
       -> publish ready base map
       -> update route foreground
       -> process renderer failure
       -> evaluate base-render policy
```

At the same time, every 3.97-inch profile enables `MAP_STABLE_CAMERA`. The stable
camera considers an update overdue after 500 ms and can hide both the base map
and route foreground. It also submits replacement render requests every 100 ms
when the desired camera differs by one pixel or 0.5 degrees. These rules conflict
with the separate e-paper scheduler, which uses a four-second minimum interval,
an eight-metre movement threshold, and a twelve-degree heading threshold.

A representative moving sequence is:

```text
4.0 s   e-paper UI gate opens and submits a base render
4.2 s   worker finishes the render
8.0 s   UI gate next permits publication
8.0 s   accepted request is about 4 s old
        stable-camera maximum lag is 0.5 s
        map and route are hidden while movement continues
```

A second problem can amplify this: `epaper_ui::process()` invalidates the entire
display context whenever the route revision changes. Normal sliding route-window
updates can therefore obsolete a pending complete frame before another
composition is submitted.

The lower display pipeline is already suitable for this work. It owns separate
desired, in-flight, and successfully shown packed buffers; replaces pending work
with the latest complete frame; compares real one-bit bytes; and commits the
shown baseline only after waveform success. The navigation fix should preserve
that design.

## Isolation contract for the AMOLED targets

All new policy behavior must be unavailable unless `WAVESHARE_EPAPER_397` is
defined.

Prefer a pure helper such as:

```text
esp32/lib/gui/src/epaperNavigationPolicy.hpp
```

Include and call it only inside `#ifdef WAVESHARE_EPAPER_397`. Where a shared
function needs different behavior, use an explicit structure that preserves the
existing path literally:

```cpp
#ifdef WAVESHARE_EPAPER_397
    // New e-paper-only policy.
#else
    // Existing AMOLED behavior, unchanged.
#endif
```

Do not change shared stable-camera constants globally. The 1.75-inch and
2.06-inch developer profiles also enable `MAP_STABLE_CAMERA`; changing those
constants would silently alter their firmware.

Whole firmware hashes from different commits cannot be expected to match
because the verified build embeds Git SHA and build timestamp metadata. The
compatibility gate must therefore use all of the following:

1. Build the 1.75-inch and 2.06-inch ordinary and production profiles at the
   baseline and implementation heads with `esp32/tools/build_firmware.py`.
2. Compare preprocessed output for every modified shared translation unit under
   each AMOLED macro, with line markers removed. It must be identical.
3. Compare hashes of non-metadata object files. Every object affected by this
   change must be identical for the corresponding baseline and implementation
   AMOLED profile.
4. If full binaries are compared, normalize only the known embedded Git SHA and
   timestamp fields first. Any other byte difference fails the gate.
5. Compare final linker maps for code/data symbol sizes and addresses, excluding
   only the documented metadata bytes. Any other difference fails the gate.
6. Run the existing AMOLED host tests, profile-contract tests, and required CI
   jobs. A successful build alone is insufficient evidence of isolation.

Record the baseline and resulting hashes, comparison commands, exclusions, and
results in the PR. Never describe the other firmware as unchanged without this
artifact evidence.

## Target runtime architecture

Keep six identities separate:

```text
latest accepted navigation state
latest desired camera
latest completed compatible base-map render
latest composed monochrome frame
in-flight SSD1677 frame
successfully shown SSD1677 frame
```

A new GPS fix changes the desired state. It does not make the accepted base map
immediately unusable, and it does not prove that pixels reached the glass.

The target control flow is:

```text
BLE receives current GPS/navigation/route state
                     |
                     v
          publish latest accepted snapshot
             |                    |
             |                    +--> update guidance promptly
             |                    +--> project marker and route on accepted base
             v
    e-paper camera policy evaluates current geometry
             |
       recenter/turn/deadline reached
             |
             v
 submit one immutable latest-state base-render request
             |
      compatible old base remains visible
             |
      worker publishes completed replacement
             |
      UI owner accepts it immediately
             |
      existing LVGL -> one-bit -> SSD1677 worker path
```

The base map, marker/route foreground, navigation guidance, logical LVGL frame,
and physical e-paper frame must retain distinct revision and completion
bookkeeping.

## Detailed implementation

### 1. Service presentation on every UI-owner tick

In `esp32/lib/gui/src/mainScr.cpp`, change
`prepareVisibleMapUpdate()` so the 3.97-inch path always performs bounded owner
work:

- Apply the current rotation mode.
- Call `mapView.serviceRenderPipeline(nowMs)`.
- Publish a ready compatible result immediately.
- Update the position overlay and route foreground.
- Update navigation text when its signature changes.
- Consume renderer failures and schedule recovery.
- Evaluate whether a new expensive base render should be admitted.

Remove the four-second early return around this complete block. Cadence belongs
only in render admission and physical panel eligibility, not completion
publication or lightweight foreground work.

Correct `acceptPublishedMapFrame()` so it marks the scheduler with the fix and
camera identity captured by the completed render request. It must not sample
`currentMapFix()` at publication time and incorrectly claim that a newer fix was
rendered.

### 2. Introduce one e-paper camera scheduler

Add a pure, allocation-free, host-testable e-paper policy. Its inputs should
include:

- Latest accepted GPS sequence, position, capture age, speed, and heading.
- Accepted base projection, coverage, camera identity, and render timestamp.
- Latest desired camera and pending/running render metadata.
- Current route/navigation revisions and urgency.
- Time since the last accepted base render and last physical waveform.

Its decision should report:

- Whether to update only marker/route/guidance layers.
- Whether to submit a base render.
- The reason mask: position, heading, maximum deferral, screen, map/style/zoom,
  route-session replacement, or recovery.
- Whether an existing render remains useful, should finish, or is semantically
  obsolete.
- Whether a pending successor was replaced by newer desired state.

For `WAVESHARE_EPAPER_397`, disable independent 100 ms render submission from
`Maps::serviceStableCamera()`. Base-render admission must come from this one
policy. Preserve the existing stable-camera behavior for all other profiles.

An already-running compatible render should normally finish. Maintain at most
one latest pending successor. Cancel immediately for hard semantic changes such
as another map epoch, zoom, map style, screen/layout, or explicit recovery.
Ordinary GPS fixes must not perpetually supersede useful work.

### 3. Preserve the last compatible base map

For the 3.97-inch target, camera age is scheduling evidence, not a visibility
deadline. Do not hide a valid map solely because camera lag exceeded 500 ms.
Keep it visible while the replacement renders.

Hide or replace the base only when:

- The visible render belongs to an incompatible map/style/zoom/layout epoch.
- Its projection can no longer cover the rider and viewport safely.
- There is no map coverage for the current location.
- A bounded renderer/display failure requires an explicit error state.

When the base is old but still compatible, expose a diagnostic stale/recentering
state without clearing the map pixels. A rider outside available map coverage
must produce an explicit `No map here` or equivalent state rather than white
glass.

### 4. Update live content against the accepted projection

Continue using the accepted base projection to draw:

- The latest rider marker.
- The latest route window and ridden/upcoming distinction.
- The current navigation icon, distance, and instruction.

These layers should update without waiting for SD geometry or a new base render.
Their composition may run at owner cadence; the existing one-bit comparison and
panel mailbox decide whether pixels warrant a waveform.

A new maneuver, changed instruction/icon, navigation clear, map-coverage loss,
or route-session replacement is urgent. Routine distance countdown and sliding
route-window changes are ordinary latest-state updates.

### 5. Separate hard context changes from data revisions

In `esp32/lib/gui/src/epaper_ui.cpp`, replace the current blanket invalidation for
every route revision with two categories.

Hard context changes invalidate pending physical frames and require a replacement
composition:

- Screen or configured screen-instance replacement.
- Map epoch, style, zoom, or incompatible layout change.
- Pairing comparison replacement.
- Panel wake/history loss or display recovery.
- Route-session replacement when the previous route is no longer meaningful.

Soft data changes retain the compatible context and update layers:

- New GPS position or heading.
- Routine route-window revision.
- Distance countdown.
- Same-maneuver text/metric change.

Every hard invalidation must also request a replacement composition. It must not
only increment the context generation and leave the old frame rejected without
a successor.

### 6. Stabilize the e-paper course-up camera

Apply heading filtering only to the 3.97-inch map-presentation policy. Preserve
raw GPS values and the iPhone/firmware BLE contract.

Use a circular time-based filter:

```text
alpha = 1 - exp(-sampleDeltaTime / timeConstant)
filtered vector = previous vector + alpha * (new vector - previous vector)
heading = atan2(filteredY, filteredX)
```

Start with a one-to-two-second time constant. Hold the last useful course below
4 km/h and resume course-driven rotation above 6 km/h. This hysteresis avoids
low-speed oscillation. Never use QMI8658 yaw as absolute heading.

### 7. Propagate end-to-end provenance

Assign or retain monotonic identities through the path:

```text
GPS arrival sequence
accepted navigation-state sequence
camera request sequence and captured-fix sequence
completed base-render sequence
composed-frame generation
panel mailbox generation
successful waveform/shown generation
```

For every accepted GPS sequence, diagnostics must eventually record exactly one
terminal disposition:

- Reflected by marker/foreground composition.
- Reflected by a base render.
- Coalesced into a named newer sequence.
- Ignored because it was duplicate, invalid, stale, below the pixel deadband, or
  incompatible with the active screen/session.

Log bounded counters continuously and detailed transitions only in diagnostic
profiles. Production logging must remain appropriately compact.

## Initial qualification thresholds

These values are starting policy, not manufacturer guarantees. Tune them from
recorded ride evidence.

| Decision | Initial 3.97-inch policy |
| --- | --- |
| BLE/model servicing | Every wake; never gated by map cadence |
| UI-owner completion/foreground servicing | Existing 30 ms timer; bounded work only |
| Marker pixel deadband | Approximately 2 rendered pixels |
| Base-map recenter threshold | 4–8 rendered pixels using the actual projection |
| Maximum recenter deferral while moving | 2 seconds; increases urgency but never hides a compatible base |
| Ordinary course-up change | 8–12 degrees after filtering |
| Clear-turn acceleration | Approximately 20 degrees |
| Low-speed heading hysteresis | Hold below 4 km/h; resume above 6 km/h |
| Heading-filter time constant | 1–2 seconds |
| Normal SSD1677 eligibility | Retain 1,000 ms after the previous successful waveform |
| Urgent SSD1677 eligibility | Retain 250 ms after the previous successful waveform |
| Full refresh | Retain boot/wake/history-loss/recovery rules and cap of 20 successful partials |
| Controller sleep | Retain 60 seconds since the last actual waveform |

Express recenter thresholds in projected pixels rather than fixed metres so zoom
and the Map + Navigation bird's-eye projection remain coherent. At 2 m/pixel,
4–8 pixels corresponds to approximately 8–16 metres.

Initially quantize an unchanged maneuver's distance countdown to 10 m when more
than 100 m away and 5 m within 100 m. Treat a new maneuver, icon, instruction,
or navigation clear as urgent. This prevents label-only panel work on every
minor phone distance update.

## File-level change map

| File or module | Planned change |
| --- | --- |
| `esp32/lib/gui/src/mainScr.cpp` | Always service e-paper presentation; throttle only base-render admission; record the completed request's captured fix when accepting a frame. |
| `esp32/lib/gui/src/epaperNavigationPolicy.hpp` | New pure 3.97-inch decision policy for recentering, heading, deadline, coalescing, and urgency. |
| `esp32/lib/gui/src/epaper_ui.cpp` | Separate hard context invalidation from soft navigation/route revisions. |
| `esp32/lib/maps/src/maps.cpp` | Add the e-paper visibility rule, disable its independent stable-camera submissions, retain compatible base content, and expose captured request metadata. |
| `esp32/lib/maps/src/maps.hpp` | Carry the minimum camera/fix/route metadata required for correct publication accounting. |
| `esp32/lib/maps/src/mapCamera.hpp` | Preserve existing constants and behavior for AMOLED; add only explicitly e-paper-scoped helpers if needed. |
| `esp32/lib/ble_navigation/ble_navigation.cpp` | Propagate existing GPS sequence/capture-age data into e-paper presentation diagnostics without changing the protocol. |
| `esp32/lib/epaper_display/frame_mailbox.hpp` and `epaper_display.cpp` | Add frame provenance and disposition logs only if needed; preserve ownership and waveform behavior. |
| E-paper host tests | Add deterministic moving-fix, slow-render, route-revision, heading-wrap, and context-invalidation fixtures. |
| Firmware build/CI tooling | Add or use an AMOLED artifact-equivalence check that accounts only for embedded provenance differences. |

## Implementation sequence

### Phase 1: Reproduce and fence the scheduling conflict

- Add a host fixture for continuous moving fixes with a fast render that becomes
  ready inside the existing four-second gate.
- Prove the old behavior delays publication and triggers the 500 ms hide state.
- Add profile assertions that the new policy is enabled only for
  `WAVESHARE_EPAPER_397`.
- Capture baseline AMOLED preprocessed/object/link evidence before changing
  shared files.

Exit criterion: the fixture fails on the PR #442 behavior for the expected
reason, and the compatibility comparison procedure is reproducible.

### Phase 2: Restore prompt publication and readable continuity

- Remove the e-paper blanket early return.
- Publish compatible ready results and service live layers on every owner tick.
- Stop the e-paper lag timer from hiding otherwise valid map content.
- Retain explicit missing-map and hard-incompatibility states.

Exit criterion: slow or delayed renders never turn a compatible map white, and a
ready result is published on the next bounded owner pass.

### Phase 3: Consolidate base-render admission

- Introduce the pure e-paper navigation policy.
- Disable e-paper requests from the shared 100 ms stable-camera submitter.
- Implement projected-pixel recentering, two-second maximum deferral, heading
  thresholds, latest-pending coalescing, and compatible-render completion.

Exit criterion: continuous 1 Hz and faster GPS replays make forward progress,
never grow a queue, and cannot starve the renderer through supersession.

### Phase 4: Separate base, foreground, and context revisions

- Project marker and route updates against the accepted base.
- Keep guidance updates independent of base completion.
- Replace routine route-revision context invalidation with soft layer updates.
- Ensure every hard invalidation requests a successor frame.

Exit criterion: routine route-window traffic cannot reject all pending frames,
and maneuver updates appear without waiting for SD work.

### Phase 5: Stabilize heading and add provenance

- Apply the time-based circular heading filter and speed hysteresis.
- Carry captured-fix/camera identities through completion publication.
- Add disposition counters and diagnostic transition logs.

Exit criterion: heading wrap, low-speed jitter, delayed samples, and newer-fix
publication bookkeeping all pass host fixtures.

### Phase 6: Cross-device and physical qualification

- Run the AMOLED equivalence contract before interpreting e-paper results.
- Build every 3.97-inch ordinary/diagnostic/production profile through the
  repository wrapper.
- Flash only an exact approved image to the identified 3.97-inch device.
- Run stationary, walking, and bicycle tests with synchronized phone and serial
  logs.

Exit criterion: the artifact evidence proves no non-provenance AMOLED change,
and the physical e-paper ride satisfies the acceptance criteria below.

## Host test matrix

Add deterministic coverage for:

- A ready render is published immediately even when the last base-render request
  was less than four seconds ago.
- Camera lag alone never hides a compatible e-paper base.
- Missing coverage and incompatible epochs still hide/replace content with an
  explicit state.
- 200 ms, 800 ms, and multi-second render durations with continuous fixes.
- Only one running render and one latest pending successor exist.
- A compatible running render completes despite newer ordinary fixes.
- A hard semantic change cancels/rejects obsolete work.
- Marker and route foreground advance against an older compatible base.
- Routine route revisions do not invalidate the physical display context.
- Hard context invalidation always schedules a replacement composition.
- Heading wrap around 359/0 degrees, low-speed hold, resume hysteresis, and
  irregular BLE intervals.
- Every accepted GPS sequence reaches one terminal diagnostic disposition.
- One-bit identical frames still skip the waveform.
- Changed content wakes a sleeping controller and performs the required full
  base refresh.

Run existing map projection, route overlay, UI scheduler, e-paper transport,
mailbox, BLE protocol, firmware profile, and changed-components tests as
regressions.

## Physical qualification matrix

Use an exact-head diagnostic image and record the device identity, port, firmware
SHA-256, ELF SHA-256, flash-plan SHA-256, Git SHA, upload verification, boot
identity, and post-flash ready state.

1. **Stationary baseline:** map appears, remains visible beyond the former 500 ms
   deadline, and controller idle sleep/wake remains correct.
2. **Walking replay:** move slowly through known map coverage while recording
   phone GPS, BLE arrivals, render dispositions, waveform completions, and video
   of the glass.
3. **Straight bicycle segment:** verify marker progress and base recentering at
   several zoom levels without white frames or stale-job buildup.
4. **Turns and roundabout:** verify filtered course-up behavior, prompt maneuver
   changes, and no oscillation while stopped.
5. **Route-window churn:** use a long route that replaces foreground geometry
   during movement; verify no context-starvation blanking.
6. **Slow SD/render injection:** deliberately delay base rendering and confirm
   the prior compatible map remains readable.
7. **Coverage boundary:** leave installed coverage and verify an explicit state;
   re-enter coverage and recover without reboot.
8. **BLE interruption:** disconnect/reconnect the iPhone during navigation and
   verify stale-state visibility, current-state recovery, and no old-session
   frame publication.
9. **Long ride:** measure partial count, full-clean cadence, BUSY durations,
   ghosting, memory stability, temperature, and battery impact.

## Acceptance criteria

The implementation is ready for review when:

- The map never becomes white solely because camera lag exceeded 500 ms.
- A completed compatible base render is accepted on the next UI-owner service
  pass rather than waiting for a four-second blanket gate.
- Continuous movement produces visible marker/navigation progress at a useful
  one-to-two-second e-paper cadence.
- Base-map rendering has one scheduling authority, one running request, and at
  most one latest pending successor.
- A valid older base remains visible during replacement rendering.
- Navigation instruction changes do not wait for map geometry or SD reads.
- Routine route-window revisions cannot obsolete every pending display frame.
- Heading is stable when stopped or moving slowly and responds coherently to real
  turns.
- Every accepted GPS sequence is rendered, coalesced, or ignored with a recorded
  reason.
- No additional waveform is issued for byte-identical pixels.
- Controller sleep, changed-content wake, full/partial history, pairing
  presentation fencing, BLE authentication, and SD map recovery retain their
  proven behavior.
- Preprocessed/object/link comparisons show no non-provenance change in the
  1.75-inch or 2.06-inch ordinary and production firmware.
- Required host tests, firmware builds, CI, exact-image flash evidence, and the
  controlled physical ride all pass.

## Rollback boundaries

Keep each behavior independently reversible:

- E-paper UI presentation servicing.
- E-paper camera admission policy.
- E-paper visibility policy.
- Soft route/foreground revision handling.
- E-paper heading filter.
- Diagnostic provenance.

A rollback must restore the previous 3.97-inch behavior without touching the
AMOLED paths. Do not weaken the shared renderer's semantic-generation checks,
display mailbox ownership, physical completion fencing, BLE authentication, or
build/upload identity controls to make a test pass.
