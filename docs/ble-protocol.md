# BLE Protocol

The ESP32 advertises BLE service UUID
`9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1800` as `BikeComputer`.

All navigation/map writes require the authenticated session established through
the auth characteristic. The iOS app completes auth before it marks the device as
navigation-ready.

## Characteristics

| UUID | Direction | Format | Purpose |
| --- | --- | --- | --- |
| `2A6E` | iOS -> ESP32 | UTF-8 `IconID|DistanceMeters|Instruction` | Current maneuver for the instruction view. |
| `9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1002` | bidirectional | UTF-8 auth messages | Local pairing/auth handshake. |
| `2A6F` | iOS -> ESP32 | Binary route geometry | Upcoming route polyline for the device map view. |
| `2A72` | iOS -> ESP32 | Binary GPS position | Current device position and heading for the map view. |
| `2A73` | iOS -> ESP32 | Binary setting packet | Runtime map-renderer settings. |

If iOS has cached an older GATT table and does not discover `2A6F`, `2A72`,
or `2A73`, the app falls back to framed binary writes over authenticated `2A6E`.
Fallback frame prefixes:

| Prefix | Payload |
| --- | --- |
| `MAPR` | route geometry packet |
| `GPSP` | GPS position packet |
| `MSET` | map setting packet |

## Auth

The shared local key is `BikeComputer BLE v1 local pairing key`.

Handshake:

1. iOS writes `HELLO|<nonce>` to auth characteristic.
2. ESP32 notifies `SERVER|<nonce>|<hmac_sha256_hex("server|<nonce>")>`.
3. iOS writes `CLIENT|<nonce>|<hmac_sha256_hex("client|<nonce>")>`.
4. ESP32 notifies `OK|<nonce>` and accepts navigation/map writes.

## Route Geometry (`2A6F`)

Little-endian binary packet:

```text
StartLat: Int32 microdegrees
StartLon: Int32 microdegrees
DeltaLat: Int16 microdegrees
DeltaLon: Int16 microdegrees
...
```

Coordinates are WGS-84. The iOS app converts Apple Maps route coordinates from
GCJ-02 to WGS-84 before writing route geometry so it aligns with OSM map blocks.

A zero-length route geometry packet clears the route overlay on the ESP32. The
iOS app sends this when navigation stops so stale route geometry is not used for
route-overlay rendering or Course Up rotation.

## GPS Position (`2A72`)

Little-endian binary packet:

```text
Lat: Int32 microdegrees
Lon: Int32 microdegrees
Heading: UInt16 degrees, 0...359
UnixTime: UInt32 seconds since 1970-01-01T00:00:00Z (optional)
Speed: UInt16 centimeters/second, 0xFFFF invalid (optional)
Altitude: Int16 meters (optional)
DistanceTraveled: UInt32 meters (optional)
ElapsedTime: UInt32 seconds (optional)
RouteRemaining: UInt32 meters, 0xFFFFFFFF invalid (optional)
```

Live CoreLocation coordinates are sent as WGS-84. Simulated or MapKit route
coordinates are converted from GCJ-02 to WGS-84 before writing. Firmware accepts
the original 8-byte lat/lon payload, the 10-byte lat/lon/heading payload, the
14-byte payload with Unix time, and the extended 30-byte telemetry payload. The
Waveshare firmware uses the optional Unix time to sync the onboard PCF85063 RTC.

## Map Settings (`2A73`)

Little-endian binary packet:

```text
SettingID: UInt8
Value: Int32
```

Current setting IDs:

| ID | Meaning | Range |
| --- | --- | --- |
| `1` | Map minimum polygon size | `0...50` |
| `2` | Map detail level | `0` low, `1` medium, `2` high |
| `3` | Map route line width | `2...48` |
| `4` | Display rotation | `0...3` |
| `6` | Map rotation mode | `0` north-up, `1` course-up |
| `7` | Map zoom level | `0...5` |
| `8` | Map visibility and global navigation-overlay mask | bit 0 buildings, bit 1 parks/green space, bit 2 paths/footways, bit 3 major roads, bit 4 residential/other local roads, bit 5 water, bit 6 railways, bit 7 other areas, bit 8 route overlay, bit 9 current position marker, bit 10 service roads, bit 11 tracks, bit 12 extended-mask marker |
| `9` | Map street line width boost | `0...24` px added to known road/path line style widths; legacy unknown lines are boosted when their stored style width is at least 3px; final rendered width is capped at 24px |
| `10` | Map current-position marker scale | `1...5`; default is `2`, so the map position marker renders at twice its original size. The firmware shows a white dot when no route is loaded and a white arrow while navigating. |
| `11` | Tap to switch screens | `0` disabled, `1` enabled. When enabled, a short tap cycles the device through the enabled main screens. Map drags and long presses are ignored by this shortcut. |
| `12` | Device brightness | `5...100` percent on supported hardware |
| `13` | Enabled main screens mask | bit 0 Map, bit 1 Navigation, bit 2 Ride Stats, bit 3 Map + Navigation. Invalid or empty masks fall back to all supported screens. |
| `14` | Default main screen | `0` Map, `1` Navigation, `2` Ride Stats, `3` Map + Navigation. Invalid or disabled defaults fall back to Map if enabled, otherwise the first enabled screen. |
| `15` | Disconnected sleep timeout | seconds before deep sleep while not connected to the app: `60`, `120`, `300`, `600`; `0` disables automatic disconnected sleep. |
| `16` | Map + Navigation minimum polygon size | `0...50` |
| `17` | Map + Navigation detail level | `0` low, `1` medium, `2` high |
| `18` | Map + Navigation route line width | `2...48` |
| `19` | Map + Navigation zoom level | `0...5` |
| `20` | Map + Navigation feature visibility mask | feature bits and the extended-mask marker use the same meanings as ID `8`; navigation overlay bits remain global via ID `8` |
| `21` | Map + Navigation street line width boost | `0...24` px |
| `22` | Map + Navigation current-position marker scale | `1...5` |

Feature visibility toggles are authoritative for their classes. Detail level
controls small-area density without overriding the visibility mask: high uses
the explicit Min Polygon Size, medium applies at least a 12px floor, and low
applies at least a 24px floor. For example, the Buildings toggle can show or
hide buildings at any detail level. IDs `1`, `2`, `3`, `7`, `8`, `9`, and `10`
form the Map screen profile. IDs `16...22` form the independent Map +
Navigation profile. On firmware upgrade, missing Map + Navigation values inherit
the persisted Map values. Map rotation mode remains Map-only; Map + Navigation
automatically uses course-up while navigating. Route and current-position
overlay visibility remains shared by both profiles.

Fresh Map + Navigation profiles default to low detail with Major Roads and
Residential & Local Roads visible. Buildings, Service Roads, Paths & Footways,
Tracks, Railways, and Other Areas default to hidden; green space and water
remain visible. Existing persisted or migrated profiles keep their saved
values.

Apps that support the extended visibility classes set marker bit `12`. Without
that marker, firmware preserves the legacy behavior by applying bit `4` to both
local and service roads and bit `2` to both paths and tracks.
Legacy v1 map blocks do not contain feature type IDs, so the renderer also
combines Local with Service and Paths with Tracks for those blocks. Downloading
a current v2 map is required for independent road-class visibility.

## Device Sound Playback

The authenticated command channel accepts a sound-play frame on either the
settings characteristic (`2A73`) or the navigation fallback characteristic
(`2A6E`):

```text
"SNDP" | SoundID: UInt8 | VolumePercent: UInt8
```

Supported sound IDs on `WAVESHARE_AMOLED_206`:

| ID | Sound |
| ---: | --- |
| `1` | Bell ding |
| `2` | Plastic bicycle horn |
| `3` | Rotating bicycle bell |
| `5` | Squeeze horn |

`VolumePercent` must be in the inclusive range `0...100`. For compatibility,
the firmware also accepts the older frame containing only `SoundID` and uses
the default volume of `70`.

Playback requests are queued by the firmware and run outside the BLE callback.
Unsupported IDs, invalid volumes, and sound commands received before
authentication are rejected.

The app configures the 2.06 PWR button as a local honk control with another
authenticated frame on the same command routes:

```text
"SNDH" | Enabled: UInt8 | SoundID: UInt8 | VolumePercent: UInt8
```

`Enabled` is `0` or `1`. The sound and volume use the same ranges as `SNDP`.
This legacy frame remains the one-shot format for firmware without capability
bit `2`. ACK-capable firmware uses a tracked frame:

```text
"SNDH" | RequestID: UInt32LE | Enabled: UInt8 | SoundID: UInt8 | VolumePercent: UInt8
```

Firmware persists the complete configuration and queues the configured sound
after an AXP2101 short-press event, so the button works without an active app
connection. The AXP2101's six-second hardware power-off behavior is unchanged.
Firmware echoes the request ID when acknowledging tracked requests on the
navigation notification characteristic:

```text
"SNHA" | RequestID: UInt32LE | Applied: UInt8 | Enabled: UInt8 | SoundID: UInt8 | VolumePercent: UInt8
```

`Applied` is `1` only after the PMU setting and complete persisted configuration
have both succeeded. The request ID prevents a delayed acknowledgement for an
older identical configuration from completing the current request. iOS retries
a failed or missing acknowledgement up to three total attempts. Legacy requests
receive the same status frame without `RequestID` for protocol compatibility.

Capability discovery uses a bounded authenticated frame on either command
route so it fits every supported BLE MTU:

```text
iOS -> ESP32: "CAPS" | Version: UInt8
ESP32 -> iOS: "CAPS" | Flags: UInt8
```

Version `1` asks ACK-capable firmware to append its persisted PWR-button
configuration:

```text
"CAPS" | Flags: UInt8 | Enabled: UInt8 | SoundID: UInt8 | VolumePercent: UInt8
```

Version `2` advertises that the client understands independent Map and Map +
Navigation profiles. Version `3` also requests the extended map visibility
classes. Receiving a `CAPS` request alone does not switch the firmware's
setting semantics: a session switches to independent profiles only after the
first setting ID in `16...22` is received. This keeps legacy IDs shared when a
capability response is dropped.

Legacy four-byte requests and five-byte responses remain supported. This lets
new apps treat the device as the source of truth after reconnecting, while new
apps still interoperate with older firmware and older apps still receive the
original response. When the device reports PWR honk disabled, the app restores
the toggle without replacing its app-local map-button sound and volume.

Flag bit `0` reports runtime device-sound availability after the speaker queue
and task start successfully. Flag bit `1` reports PWR-button honk support. Flag
bit `2` reports `SNHA` acknowledgement support; iOS only retries PWR
configuration when this bit is set, preserving one-shot writes for older
firmware. Flag bit `3` reports independent map profiles. Apps send IDs `16...22`
only after this bit is received; otherwise they send the legacy Map profile and
the firmware mirrors it to Map + Navigation. Flag bit `4` reports separate
service-road and track visibility. The app retries discovery after each
connection, ignores retry timers from older BLE sessions, uses the sound-related
bits to enable sound controls, and restores the device-persisted PWR
configuration from versioned responses.

## OSM Map Blocks

The ESP32 renderer reads binary `.fmb` files generated by `OSM_Extract`.
Legacy/manual SD layout:

```text
/VECTMAP/<folder>/<blockX>_<blockY>.fmb
```

Maps installed by the companion app use immutable, content-derived versions:

```text
/VECTMAP/.maps/<sessionId>/<folder>/<blockX>_<blockY>.fmb
```

`/VECTMAP/active-map.json` selects the renderer root. The firmware continues to
accept `/VECTMAP` as the root for cards populated manually or by older builds.

The renderer also checks `/maps/<folder>/<blockX>_<blockY>.fmb` and
`/<folder>/<blockX>_<blockY>.fmb` for bring-up convenience.

Folder/block naming follows the OSM extract pipeline:

- Web Mercator meters
- `4096 x 4096` meter blocks
- `16 x 16` block folders
- folder name format like `+0032+0008`

## Map Transfer Control

Bulk map packs are transferred over Wi-Fi/HTTP, not BLE. BLE is the control and
status channel used by the iOS app to ask the device to enter transfer mode and
to inspect the installed map state.

The authenticated `2A6E` framed command channel carries these control commands:

| Command | Direction | Payload | Meaning |
| --- | --- | --- | --- |
| `MTRN` | iOS -> ESP32 | `enter` | Enable short-lived map-transfer mode. |
| `MTRN` | iOS -> ESP32 | `exit` | Disable map-transfer mode. |
| `MSTS` | iOS -> ESP32 | empty | Request current map-transfer status. |
| `MSTC` | ESP32 -> iOS | Framed UTF-8 JSON chunk | Current map-transfer status notification. |

When the full legacy `MSTS{...}` response fits the negotiated ATT MTU, firmware
continues to use it. Otherwise `MSTC` responses fit the minimum BLE notification
payload: ASCII `MSTC`, a one-byte transfer id, zero-based chunk index, chunk
count, and up to 13 JSON bytes (20 bytes total). The app reassembles chunks by
transfer id and accepts both forms.

Status responses should include:

- `activeMapId`: map id from `/sdcard/VECTMAP/active-map.json`, if present.
- `activeSessionId`: durable content-derived session selected by
  `active-map.json`, when installed by transfer-capable firmware. This
  distinguishes regenerated packs that intentionally reuse a stable map ID.
- `enabled`: whether Wi-Fi/HTTP upload mode is enabled.
- `baseUrl`: temporary HTTP base URL when transfer mode is enabled.
- `activation`: the latest activation `status`, monotonic boot-local
  `sequence`, `sessionId`, optional `mapId`, and structured `error`, when
  present. Status is `idle`, `activating`, `failed`, or `installed`. BLE uses a
  compact form that omits error messages and duplicate `lastError`; HTTP retains
  the full diagnostic text.
- `lastError`: last installer/upload error code, when present. HTTP also includes
  the diagnostic message.
- `activeError`: active-map metadata error code, when no active map is installed.
  HTTP also includes the diagnostic message.

The ESP32 map installer validates staged packs before activation:

- uploading a new session manifest removes abandoned staging sessions while
  preserving the current content-derived session for resume.
- manifest schema version must be `1`.
- `mapId` and session ids may contain only letters, numbers, `.`, `_`, and `-`.
- files must live under `VECTMAP/` and end in `.fmb` or `.fmp`.
- path traversal and absolute paths are rejected.
- declared byte size and SHA-256 must match the staged file. New uploads are
  hashed while streaming to SD and receive a verification receipt, avoiding a
  second full read during activation.
- activation moves verified files into `.maps/<sessionId>` using same-volume
  renames, then switches `/sdcard/VECTMAP/active-map.json` to that immutable
  root. Each installed root retains a hidden manifest and verification receipt,
  so an idempotent same-session activation checks metadata without rereading all
  map bytes. It does not copy the full map again.

Active-map metadata is written through a temporary file and atomic rename. A
backup is retained during the embedded FAT fallback. A hidden activation
journal tracks publishing and the pointer switch. Boot recovery removes an
incomplete new version when the pointer was not switched. If the new root is
already selected, the exceptional recovery path verifies its retained manifest,
receipt, sizes, and hashes before completing cleanup; otherwise it restores the
previous root or clears an unrecoverable first-install selection so a fresh
transfer can proceed. The previous selected root remains
available for rollback until the next transfer begins; at that point only the
current version is retained before the replacement uploads.

When transfer mode is enabled, the ESP32 exposes a short-lived HTTP service for
bulk upload:

| Method | Path | Meaning |
| --- | --- | --- |
| `GET` | `/map-transfer/status` | Read transfer status and active map metadata. |
| `PUT` | `/map-transfer/sessions/{sessionId}/manifest.json` | Upload the map pack manifest. |
| `PUT` | `/map-transfer/sessions/{sessionId}/VECTMAP/{mapId}/{folder}/{file}` | Upload one `.fmb` or `.fmp` file. |
| `POST` | `/map-transfer/sessions/{sessionId}/activate` | Validate and atomically activate the staged map. |

An accepted activation returns HTTP 202 with the boot-local activation
`sequence`. The app matches that acknowledgement to later HTTP/BLE terminal
status so a cached same-session result cannot be mistaken for the new attempt.
If a manifest HEAD encounters an interrupted activation journal, firmware first
returns 503 and then performs exceptional recovery. The app permits a bounded
long wait only after that explicit recovery/busy response; ordinary transport
timeouts retain a short retry limit.

The HTTP service is configured by firmware at boot but remains disabled until
BLE transfer control enables it for an authenticated app session.
