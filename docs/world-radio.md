# World Radio

World Radio turns the ESP32-S3 display into a geographic remote for internet
radio. The device renders and manipulates the map; the authenticated iPhone app
performs every network request and plays the stream through the phone's active
audio route. Encoded audio never crosses BLE and the firmware does not enable
Wi-Fi for this feature.

## Flow

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
