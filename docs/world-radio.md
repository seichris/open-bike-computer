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

The lower controls are icon-only previous station, play/pause, and next station.
They sit inside the round display's safe area. Active playback omits the redundant
"Playing on iPhone" status line, including when an older phone build sends that
message; searching, buffering, connection, and error messages remain visible.

The offline world map uses a bundled Natural Earth I shaded-relief texture:
natural land cover, mountain shading and water, with no artificial grid or
bright coastline outlines. The 1024x512 map decodes once into a shared 1 MiB
RGB565 canvas; longitude wrapping and drag-to-tune coordinates use its WGS84
plate-carree projection. See `esp32/tools/world-radio-map/README.md` for source,
licensing, memory budget and deterministic regeneration.

The map has no title banner or bottom panel. Its viewport fills the screen,
with the reticle at the screen center. A 2x display-only zoom provides a
closer view without another texture allocation. Drag deltas move the camera in
screen pixels, 1:1 with the finger; longitude wraps and vertical movement stops
at the map edges so the viewport stays covered. Ordinary playback updates and
location-search results do not recenter the map. Explicit previous/next/random
station selection can focus the resulting station, constrained to the same map
bounds; beginning a drag cancels that pending focus.

The lower controls are global shuffle and play/pause icons, with transparent
half-width, 140px-high touch areas reaching the left/right bottom edges.
Station name (black) and place (dark gray) occupy two single-line rows above the dot, without
coordinates or text backgrounds. The bundled radio font supports Latin accents
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
2. Releasing the map sends one fixed-size `WRQ1` coordinate request over the
   existing authenticated navigation characteristic.
3. The iPhone queries Radio Browser with progressively larger radii, filters to
   healthy HTTPS streams, and keeps a bounded candidate queue.
4. `AVPlayer` starts the selected live stream. The phone returns a bounded
   `WRS1` status containing station metadata and playback state.
5. Previous, play/pause, next, stop, and global-random commands remain tiny BLE
   control messages. Audio continues on the iPhone if the device temporarily
   disconnects.

## Privacy and security

- Both endpoints must use the updated World Radio contract: client version 25
  and CAP2 feature bit 27. Earlier draft builds used bit 23, which is now
  reserved for renderer replay samples; rebuild both iPhone and firmware when
  moving from those drafts. The Watch keeps client version 23 for its GPS
  motion-evidence support and does not host radio playback.

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
