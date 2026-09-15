# World Radio

World Radio turns the ESP32-S3 display into a geographic remote for internet
radio. The device renders and manipulates the map; the authenticated iPhone app
performs every network request and plays the stream through the phone's active
audio route. Encoded audio never crosses BLE and the firmware does not enable
Wi-Fi for this feature.

## Flow

This PR exposes World Radio only in development firmware with
`FIRMWARE_DIAGNOSTICS=1`, including the ordinary and remote-debug Waveshare
profiles. It is still off by default in Device Screens. Production profiles
omit the screen, its map allocation, and capability bit 27; iOS hides the
option when that bit is absent. Enabling it for production requires physical
qualification and a firmware size budget that fits the existing 3 MiB OTA
partition. No partition offsets or sizes change in this PR.

In Device Screens, choose Add Screen → World Radio, then Save to Bicino.
World Radio uses configurable screen type 5 and the existing version-1 empty
screen payload. Its type bit is advertised in the screen-configuration TLV
only by development firmware. Playback follows the acknowledged configuration;
removing or disabling the last World Radio instance releases the phone player.

The lower controls are global shuffle and play/pause; the separate top `NEXT`
button cycles device screens, not stations. Previous/next station commands are
retained in the wire protocol for compatibility but have no on-screen buttons.
Playback-state text is not drawn over the map; the reticle and metadata convey
state as described below.

The offline world map uses a bundled Natural Earth I shaded-relief texture:
natural land cover, mountain shading and water, with no artificial grid or
bright coastline outlines. The 1024x512 map decodes once into a 1 MiB
RGB565 texture; longitude wrapping and drag-to-tune coordinates use its WGS84
plate-carree projection. See `esp32/tools/world-radio-map/README.md` for source,
licensing, memory budget and deterministic regeneration.

The map has no title banner or bottom panel. Its viewport fills the screen,
with the reticle at the screen center. A 2x display-only zoom provides a
closer view. A screen-sized raster cache (about 424 KiB on the 1.75) composes
the visible map at integer 2x scale, avoiding LVGL image-transform work on each
drag frame. Adjacent duplicated rows are copied, and the panel's full-frame
refresh strategy remains unchanged. Drag deltas move the camera in
screen pixels at 1:1 speed using calibrated physical touch coordinates;
longitude wraps and vertical movement stops
at the map edges so the viewport stays covered. Ordinary playback updates and
location-search results do not recenter the map. Explicit previous/next/random
station selection can focus the resulting station, constrained to the same map
bounds; beginning a drag cancels that pending focus.

The same-country shuffle report was traced to physical input, not directory
scope: the 1.75 CST9217 sensor needs a half-turn offset before display rotation.
The captured shuffle tap `(415,330)` previously became `(330,50)` and triggered
a nearby search; calibrated it becomes `(135,415)` in the bottom-left control.
Both primary touch and multi-contact snapshots use this calibration. Remote
panel-pixel input and the 2.06 native mapping are unchanged. The temporary radio
drag-axis workaround is removed so its physical movement direction is preserved.

The lower controls are black 32px global shuffle and play/pause icons without
backgrounds or borders, with transparent
half-width, 140px-high touch areas reaching the left/right bottom edges.
Station name (black, emboldened with a one-pixel overprint) and place (dark gray)
occupy two closer single-line rows above the dot, without
coordinates or text backgrounds. A bundled country flag precedes the place;
the redundant country-code suffix is removed. The bundled radio font supports Latin accents
and BMP Chinese ideographs; see `esp32/tools/world-radio-font/README.md`.
Each screen entry requests a new global station once the phone is ready;
an intervening manual map/control action cancels that pending entry request.
There are no previous/next station controls or candidate counter. Random tunes
worldwide; landing on a map location randomly selects from that area's bounded
candidate list. Both avoid the current station when alternatives exist and
retain automatic fallback if a stream fails. The separate top `NEXT` button
cycles to another device screen.

The reticle is solid green while playing, shrinks from 42px to 14px over one
second then immediately resets and repeats while searching,
connecting or buffering, and is gray when idle, paused, disconnected, empty or
in error. The dot stays centered and steady during the ring's animation.
Without a station, both metadata rows stay empty. Playback-state text,
including legacy phone messages, is not displayed.

1. The rider opens **World Radio** and drags the wrapped, equirectangular map
   under the fixed reticle.
2. After a drag settles for 180 ms, the map sends one fixed-size `WRQ1`
   coordinate request over the existing authenticated navigation characteristic.
   Another drag restarts that interval; map feedback itself stays immediate.
   Taps below the existing 10px threshold do not pan. A cancelled/lost press
   does not select a station. Explicit shuffle/play actions cancel a pending lookup.
3. The iPhone queries Radio Browser with progressively larger radii, filters to
   healthy HTTPS streams, and keeps a bounded candidate queue.
4. `AVPlayer` starts the selected live stream. The phone returns a bounded
   `WRS1` status containing station metadata and playback state.
5. Play/pause and global shuffle use tiny BLE control messages. Previous, next
   and stop remain supported protocol commands, not additional screen controls. Audio continues on the iPhone if the device temporarily
   disconnects.

## Privacy and security

- Both endpoints must use the updated World Radio contract: client version 25
  and CAP2 feature bit 27. Earlier draft builds used bit 23, which is now
  reserved for renderer replay samples; rebuild both iPhone and firmware when
  moving from those drafts. The current Watch requests client version 27 for
  workout-zone sidecars but does not host radio playback; older version-23
  Watch clients continue to request GPS motion-evidence support.

- World Radio uses the existing owner-authenticated BLE envelope.
- Station and coordinate requests are sent only to the connected iPhone.
- The device receives no station URL and cannot fetch internet content.
- The iPhone accepts HTTPS station streams only in the first release.
- Radio Browser's click endpoint is called only after playback begins.

## Validation boundary

Host tests cover request/status encoding, screen registry behavior, iPhone
service orchestration, and generated-contract drift. Firmware and iOS builds
prove integration at compile time. Physical acceptance still requires dragging
the map and controlling live playback on both supported Waveshare panels while
an authenticated iPhone is connected.

## Reused mechanics and lifecycle invariants

Stable screen type numbers come from `protocol/ride-ble-contract-v1.json` and
its existing generator. Firmware registry/configuration types alias the generated
wire type; legacy settings keep source-compatible adapters. Swift's Int settings
and UInt8 wire enums are generated from that same source. Titles, cycling order
and production/capability gates remain platform policy, not generated UI data.
No screen numbers, mask-marker behavior, packet layout or client versions change.

`wireBytes.hpp` and `RideShared/WireBytes.swift` provide small little-endian
primitives, used by World Radio and screen configuration. Packet codecs still
validate lengths/reserved bytes and own protocol semantics. Swift offsets work
relative to `Data.startIndex`; fixed-layout incoming radio frames normalize Data
slices before direct byte indexing. Shared independent fixtures under
`protocol/fixtures/` cover both codecs, including maximum UTF-8 lengths and
malformed frames.

Radio's `DragSession` reuses `map_drag_preview::Controller` for pixel accumulation
and settlement. It does not reuse the navigation projection/renderer. Camera
wrapping and clamping stay radio-specific, reversal at a clamp is immediate,
and unchanged camera positions avoid raster recomposition. The raster host test
replays repeated touch samples and checks identical final pixels with 610 versus
51 compositions. This is synthetic host evidence, not a device frame-rate claim.
Physical dragging and touch-release timing still need panel qualification.

The AVPlayer adapter uses an item generation plus explicit playing/paused/stopped
intent. Queued callbacks check both generation and item identity on MainActor;
readiness never overrides Pause, and old errors cannot skip the current station.
Failures while paused are surfaced on explicit Resume rather than auto-playing
a fallback. Stop invalidates callbacks before detaching observations.

Directory operations have their own generation, separate from BLE command IDs.
Pause during discovery retains the result without starting it. Cancellation,
replacement and feature disablement reject late success and generic-error paths.
BLE reconnection only resends the existing status: it does not stop playback,
restart discovery, or create a new player generation. Host lifecycle tests use
controlled directory continuations and queued fake-player events exercising the
same pure playback gate; they do not claim to exercise real AVPlayer/KVO or audio.
