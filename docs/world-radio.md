# World Radio

World Radio turns the ESP32-S3 display into a geographic remote for internet
radio. The authenticated iPhone app performs directory requests and plays the
HTTPS stream through the phone's active audio route. Encoded audio never crosses
BLE and the firmware does not enable Wi-Fi for this feature.

## Rollout

World Radio remains available only in development firmware with
`FIRMWARE_DIAGNOSTICS=1`. Production omits screen type 5 and CAP2 capability bit
27, so iOS hides the option. It is also off by default in Device Screens in a
development build.

The development screen intentionally has no embedded raster map, flag atlas, or
multilingual font. A 156-pixel Earth is drawn from LVGL lines and filled polygon
geometry, station and place metadata use the firmware's existing Montserrat
fonts, and the two-letter country code replaces the flag. This avoids roughly
2.3 MiB of fixed image/font data and removes the former decoded-map and viewport
buffers from PSRAM.

## Interaction

- Tap inside the vector Earth to select an approximate latitude/longitude. The
  fixed-size `WRQ1` request is sent through the existing owner-authenticated BLE
  navigation characteristic.
- The center and edge of the Earth cover the full latitude/longitude range. A
  marker shows the selected coordinate and moves to a returned random station.
- The lower-left control asks for a random station worldwide. The lower-right
  control plays or pauses. `NEXT` cycles device screens.
- The marker is green while playing, pulses while searching, connecting, or
  buffering, and is gray while idle, paused, disconnected, empty, or in error.

The small vector Earth is an intentionally approximate geographic selector, not
an offline navigation map. The former full-screen drag/pan interaction and
Natural Earth relief texture are removed.

## Protocol and playback lifecycle

World Radio uses configurable screen type 5, client version 25, CAP2 bit 27,
and the existing version-1 empty screen payload. `WRQ1` and `WRS1` remain byte
compatible. The iPhone queries Radio Browser with progressively larger radii,
filters to healthy HTTPS streams, maintains a bounded candidate queue, and
reports bounded station metadata and playback state. Previous/next/stop remain
wire commands even though only random and play/pause are on screen.

Playback intent, player-item generation, and directory-operation generation
remain separate. Pause during discovery keeps the result without starting it;
late callbacks cannot replace or restart a newer item. Disconnect only stops
the device control session: it does not create a new search or silently restart
audio. Removing or disabling the last World Radio screen releases the phone
player.

## Privacy and validation

- Both endpoints must use the updated World Radio contract. Earlier draft bit
  23 is reserved for renderer replay and must not be interpreted as radio.
- Station and coordinate requests are sent only to the connected owner iPhone.
- The ESP32 receives no station URL; the phone accepts HTTPS station streams.
- Radio Browser's click endpoint is called only after playback begins.

Host tests cover coordinate projection, request/status encoding, development
gating, removed-asset guards, screen registry behavior, and iPhone orchestration.
Firmware and iOS builds prove integration only. Physical acceptance still
requires coordinate selection and live playback on both supported panels with
an authenticated iPhone.
