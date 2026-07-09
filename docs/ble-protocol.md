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
| `1` | Minimum polygon size | `0...50` |
| `2` | Detail level | `0` low, `1` medium, `2` high |
| `3` | Route line width | `2...48` |
| `4` | Display rotation | `0...3` |
| `6` | Map rotation mode | `0` north-up, `1` course-up |
| `7` | Zoom level | `0...5` |
| `8` | Visibility mask | bit 0 buildings, bit 1 parks/green space, bit 2 paths/tracks, bit 3 major roads, bit 4 local streets, bit 5 water, bit 6 railways, bit 7 other areas, bit 8 route overlay, bit 9 current position marker |
| `9` | Street line width boost | `0...24` px added to known road/path line style widths; legacy unknown lines are boosted when their stored style width is at least 3px; final rendered width is capped at 24px |
| `10` | Current-position marker scale | `1...5`; default is `2`, so the map position marker renders at twice its original size. The firmware shows a white dot when no route is loaded and a white arrow while navigating. |
| `11` | Tap to switch screens | `0` disabled, `1` enabled. When enabled, a short tap cycles the device through the enabled main screens. Map drags and long presses are ignored by this shortcut. |
| `12` | Device brightness | `5...100` percent on supported hardware |
| `13` | Enabled main screens mask | bit 0 Map, bit 1 Navigation, bit 2 Ride Stats, bit 3 Map + Navigation. Invalid or empty masks fall back to all supported screens. |
| `14` | Default main screen | `0` Map, `1` Navigation, `2` Ride Stats, `3` Map + Navigation. Invalid or disabled defaults fall back to Map if enabled, otherwise the first enabled screen. |
| `15` | Disconnected sleep timeout | seconds before deep sleep while not connected to the app: `60`, `120`, `300`, `600`; `0` disables automatic disconnected sleep. |

Feature visibility toggles are authoritative for their classes. Detail level
controls small-area density without overriding the visibility mask: high uses
the explicit Min Polygon Size, medium applies at least a 12px floor, and low
applies at least a 24px floor. For example, the Buildings toggle can show or
hide buildings at any detail level.

## OSM Map Blocks

The ESP32 renderer reads binary `.fmb` files generated by `OSM_Extract`.
Preferred SD layout:

```text
/VECTMAP/<folder>/<blockX>_<blockY>.fmb
```

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
| `MSTS` | ESP32 -> iOS | UTF-8 JSON | Current map-transfer status notification. |

Status responses should include:

- `activeMapId`: map id from `/sdcard/VECTMAP/active-map.json`, if present.
- `enabled`: whether Wi-Fi/HTTP upload mode is enabled.
- `baseUrl`: temporary HTTP base URL when transfer mode is enabled.
- `lastError`: last installer/upload error code and message, when present.
- `activeError`: active-map metadata error, when no active map is installed.

The ESP32 map installer validates staged packs before activation:

- manifest schema version must be `1`.
- `mapId` and session ids may contain only letters, numbers, `.`, `_`, and `-`.
- files must live under `VECTMAP/` and end in `.fmb` or `.fmp`.
- path traversal and absolute paths are rejected.
- declared byte size and SHA-256 must match the staged file.
- activation writes `/sdcard/VECTMAP/active-map.json` only after all map files
  have been published.

When transfer mode is enabled, the ESP32 exposes a short-lived HTTP service for
bulk upload:

| Method | Path | Meaning |
| --- | --- | --- |
| `GET` | `/map-transfer/status` | Read transfer status and active map metadata. |
| `PUT` | `/map-transfer/sessions/{sessionId}/manifest.json` | Upload the map pack manifest. |
| `PUT` | `/map-transfer/sessions/{sessionId}/VECTMAP/{mapId}/{folder}/{file}` | Upload one `.fmb` or `.fmp` file. |
| `POST` | `/map-transfer/sessions/{sessionId}/activate` | Validate and atomically activate the staged map. |

The HTTP service is configured by firmware at boot but remains disabled until
BLE transfer control enables it for an authenticated app session.
