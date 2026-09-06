# Stable map camera: implementation and qualification

## Scope and rollout

The implementation follows [the orientation plan](map-orientation-implementation-plan.md)
on GitHub main `e10aa7fa341366dd3b8e3ed74c0e069d414b8f0d`.
`MAP_STABLE_CAMERA=1` selects the new path in ordinary Waveshare 1.75-inch and
2.06-inch development profiles (and their derived remote-debug profiles).
The default is off; production profiles retain the legacy renderer and do not
advertise the orientation capability. No map-format, backend, extrusion-quota,
benchmark-ranking threshold, or production activation change is included.

| Target | Source path | Physical acceptance | Production activation |
| --- | --- | --- | --- |
| WAVESHARE_AMOLED_175 | Implemented, development enabled | Pending | Disabled |
| WAVESHARE_AMOLED_206 | Implemented, development enabled | Pending | Disabled |

Do not treat host tests, a firmware build, or green CI as physical acceptance.
Activating production requires a separate tracked change after the gates below
pass, or explicit recorded maintainer acceptance of the residual risk.

## Display contract

- Course Up rotates geographic roads and building footprints together. Roof
  extrusion is recomputed in the camera and stays screen-vertical; it is not
  counter-rotated geographic geometry. Visible faces can change through turns.
- North Up fixes the map bearing and lets the position arrow rotate.
- Keep Upright rasterizes horizontal, unwarped text at projected road anchors.
  Follow Roads uses the perspective-projected segment tangent, normalized to a
  readable half-turn. Label language, density, text size, collision checks, and
  marker/UI reservations remain in force.
- Completed camera frames are cropped, never rotated to impersonate a new
  perspective. While a replacement runs, live route and position are projected
  against the accepted camera. A Course Up arrow is upright at the camera's
  accepted pose; it can move off-center and acquire a small residual angle as
  newer motion arrives. Forcing it upright during that interval would lie about
  its relationship to the displayed roads.
- The worker is asked for a replacement at most every 100 ms when displacement
  exceeds one projected pixel or bearing differs by at least 0.5 degrees.
  Outstanding lag over 500 ms, incompatible semantics, or lost rider coverage
  hides the camera/route/marker and displays “Updating map...”. Static views
  do not expire merely because time passes. Gesture ownership retains its
  existing preview/settlement path and is explicitly excluded from camera
  screenshot evidence.

## Ownership and memory

`mapCamera.hpp` holds pure projection, lag, coverage and scene-lease policies.
The existing single map worker owns decoded blocks and rasterizes into the
existing back buffer. `prepareMapScene` reuses a complete, epoch-bound block
rectangle when it covers a new camera's bounds. It invalidates that lease
before any block loader/evictor mutates it; incomplete coverage is retried,
not cached as complete. A scene generation identifies each prepared set.

This is a separation of decoded-scene preparation from camera rasterization,
not a second geometry cache or four full-screen layers. The existing front,
back and route-overlay surfaces remain unchanged. Scene metadata is at most
32 bytes and each camera sample at most 40 bytes, enforced by static assertions.
Additional fixed metadata lives in request/result, diagnostics and frame-store
objects; one small LVGL status label is owned by the map screen. JSON export
has additive camera fields and may grow its existing bounded response buffer.
Measure peak memory and largest allocations with remote capture enabled.

Camera-specific label cache keys include the complete projection signature.
Candidates are laid out and rasterized in the visible crop rather than spending
label admission on overscan. Existing worker checkpoints, cancellation tokens,
semantic epochs, diagnostic-window admission, building quotas and recovery
remain authoritative. Camera requests coalesce without resetting outstanding
lag; publication advances reflected progress only to the accepted request time.

## Evidence schema

Renderer metrics add optional `camera` schema 1 with frame/scene identity,
request and observation timestamps, outstanding lag, displayed/target bearing,
marker angle, effective perspective, requested/effective rotation, label policy,
hidden/update-required flags, scene reuse, lag timing summary and maximum
Course Up marker residual. Samples are admitted only to their exact active
diagnostic window; a new window clears camera history. Idle observations do
not pad the lag histogram with zeroes. Bearings/marker angles use tenths of a
degree; top-edge scale uses thousandths. Times are wrapping firmware millis.

The remote frame endpoint keeps its RGB565 body unchanged and adds the bounded
`X-BikeComputer-Map-Camera` header. Its 18 comma-separated integers are:

```text
schema,enabled,frameSequence,sceneGeneration,requestedAtMs,observedAtMs,lagMs,
displayedBearingTenths,targetBearingTenths,markerAngleTenths,
effectiveTopScalePermille,requestedMode,effectiveMode,labelDensity,
labelOrientation,hidden,updateRequired,sceneReused
```

The header sample is copied with the pixels at the full-panel flush boundary
under the frame-store lock, not sampled when the HTTP request is answered.
`frameSequence` is the map-render sequence; the binary frame's sequence is the
separate panel-capture sequence. `enabled=0` means the capture cannot attest an
active stable camera (including other screens and gesture previews). Requested
mode is current intent; effective mode and labels belong to the accepted frame.
The iOS secure benchmark client validates the header and includes it in each
screenshot's evidence. Legacy missing headers and metrics without `camera`
remain readable; malformed present headers fail closed.

## Reproducible qualification

1. Run generated-contract verification, host camera tests with the feature both
   on and off, existing projection/building/label/presentation/job tests,
   capability/persistence tests, guidance/debug integration tests and Swift
   navigation tests. Build iOS through its repository wrapper. Build both
   firmware families through the locked helper or explicit both-target CI.
2. Confirm the connected model and stable USB serial, exact clean commit and
   remote-debug profile. Obtain fresh flash authorization and retain post-flash
   identity/ready evidence under `AGENTS.md`. Use a signed FMB v4 fixture with
   asymmetric roads, labeled streets and buildings. Record map/route hashes.
3. Run a separate bounded orientation capture, not the ranking sweep: hold
   headings 0, 90, 180, 270, 359 and 1 degrees for five seconds each, retaining
   transition and settled frame samples. Repeat North Up/Course Up, Keep
   Upright/Follow Roads, flat and all five perspective presets, full-screen and
   toolbar viewports. The debug transport's capture latency means it is not a
   high-frame-rate proof; use external video for every visible transition.
4. Exercise controlled delayed publication in a dedicated test build, heading-
   only input, invalid course, stops/prediction exhaustion, reroutes, changed
   settings/windows, pan/pinch settlement, map activation and screen teardown.
   Require horizontal Keep Upright text, vertical extrusion, footprint/road and
   marker/route agreement in every accepted frame; expired views must show the
   refresh state. Verify latest requests do not starve publication.
5. Measure moving-camera lag p95 <=250 ms and maximum <=500 ms, plus existing
   memory, UI/flush, SD, watchdog, transport and benchmark gates unchanged.
   Prepared-scene reuse avoids block preparation but does not eliminate raster
   cost; these performance targets are not yet demonstrated. If missed, keep
   production disabled and optimize the view pass, not the acceptance limits.
6. Repeat normal physical navigation with real course noise/BLE jitter. Record
   daylight readability, tearing, battery/thermal behavior and both targets
   independently. Commit sanitized evidence and qualification decisions before
   proposing production activation.

Rollback removes the development enable flag/capability without deleting either
stored rotation preference. The app falls back to its capability-absent state.
