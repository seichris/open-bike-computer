# BLE Protocol

The ESP32 advertises BLE service UUID
`9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1800` under its user-assigned device name.
An unregistered device uses `BikeComputer XXYY`, where `XXYY` is derived from
its stable hardware-derived device ID.

The advertisement carries an eight-byte manufacturer payload:

```text
FF FF | ProtocolVersion: UInt8 | Flags: UInt8 | DeviceID suffix: 4 bytes
```

Protocol version is currently `2`; flag bit `0` means the device already has an
owner and the remaining flag bits are reserved. The suffix lets the app and
device show the same short identifier when
several Bike Computers are nearby without advertising the complete identity.

All navigation/map writes require the authenticated session established through
the auth characteristic. The iOS app completes auth before it marks the device as
navigation-ready.

## Characteristics

| UUID | Direction | Format | Purpose |
| --- | --- | --- | --- |
| `2A6E` | bidirectional | Navigation text plus framed control packets | Current maneuver for the instruction view and device-originated destination requests. |
| `9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1002` | bidirectional | UTF-8 auth messages | Local pairing/auth handshake. |
| `2A6F` | iOS -> ESP32 | Binary route geometry | Upcoming route polyline for the device map view. |
| `2A72` | iOS -> ESP32 | Binary GPS position | Current device position and heading for the map view. |
| `2A73` | iOS -> ESP32 | Binary setting packet | Runtime map-renderer, device-screen, and phone-status values. |

`DistanceMeters` is an unsigned 16-bit decimal value (`0...65535`). The iOS
sender saturates larger maneuver distances at `65535` instead of allowing the
firmware field to wrap.

If iOS has cached an older GATT table and does not discover `2A6F`, `2A72`,
or `2A73`, the app falls back to framed binary writes over authenticated `2A6E`.
Fallback frame prefixes:

| Prefix | Payload |
| --- | --- |
| `MAPR` | route geometry packet |
| `GPSP` | GPS position packet |
| `MSET` | map setting packet |

## Device ownership and authentication

Every ownership-capable ESP32 derives its stable 128-bit device ID as the first
16 bytes of `SHA-256("BikeComputer device ID v2" || eFuseBaseMAC)` and caches it
in NVS. A missing/corrupt cached ID is recreated only when no owner artifacts
exist; otherwise firmware remains physically recoverable but fail-locked rather
than binding an existing credential to a new identity. The iOS installation
similarly creates a random 128-bit
owner ID and stores it in the Keychain. iOS may register multiple Bike
Computers, but maintains one current BLE connection at a time. Automatic
reconnect targets only the current device; changing devices is explicit in
Settings.

### Initial registration

Registration is allowed only while the device is unclaimed. The two sides use
ephemeral P-256 ECDH, HKDF-SHA256, and a comparison code shown independently on
the iPhone and Bike Computer. The derived 256-bit owner key is never sent over
BLE.

All binary fields below are lowercase hex. `AppPublicKey` and
`DevicePublicKey` are 65-byte uncompressed X9.63 P-256 keys.

1. iOS writes `INFO` after the user selects the nearby Bike Computer and taps
   Continue. No device-button press is required yet.
2. ESP32 notifies
   `DEVICE|2|<DeviceID>|<Claimed 0-or-1>|<UTF8NameHex>`.
3. iOS writes `PAIR|<OwnerID>|<AppPublicKey>`. Firmware accepts at most one
   valid `PAIR` request per BLE connection, limiting unattended clients to one
   expensive P-256 operation before they must reconnect.
4. ESP32 derives the owner key and notifies
   `PAIRING|<DeviceID>|<DevicePublicKey>`.
5. Both sides hash `"BikeComputer ownership v2" || DeviceID || OwnerID ||
   AppPublicKey || DevicePublicKey`, then derive the owner key with that hash as
   HKDF salt and `BikeComputer owner key v2` as HKDF info.
6. Both show the six-digit big-endian value from the first four bytes of
   `HMAC-SHA256(OwnerKey, "compare|" || TranscriptHash)`, modulo `1,000,000`.
7. After verifying that the displays match, the user presses either button on
   the Bike Computer. ESP32 arms confirmation only after the comparison screen
   has been rendered, discards older BOOT/PWR events, and requires a fresh
   press for the active pairing generation before notifying
   `PAIR_READY|<DeviceID>`. This physical action is required so a nearby client
   cannot silently claim an unattended device.
8. The user also taps the matching-code confirmation on iPhone. Replacing a
   stale credential uses a separate destructive “Replace Registration” action.
   iOS then writes
   `CONFIRM|<OwnerID>|<HMAC-SHA256(OwnerKey, "claim|" || TranscriptHash)>|<UTF8NameHex>`.
9. ESP32 persists the owner ID, owner key, and name, then notifies
   `PAIRED|<DeviceID>|<UTF8NameHex>`.

iOS keeps the derived key in a provisional Keychain entry through these steps.
`PAIRED` is not itself trusted: the app promotes the key and mutates the device
registry only after the subsequent owner-session handshake proves the hardware
committed that same key. Automatic promotion never overwrites a different final
credential; the explicit replacement action is persisted so recovery remains
possible if the final notification is lost.

Pairing expires after 120 seconds. Names are non-empty UTF-8, exclude control
characters and `|`, and are limited to 24 bytes. The app starts with the
privacy-safe editable suggestion `My bike`; iOS does not expose the Apple ID
owner name to apps.

### Owner session authentication

Every BLE connection performs a fresh mutual challenge using independent
random 16-byte nonces from iOS and the ESP32. The device-generated nonce makes
a captured handshake unusable on a later connection. No navigation, map,
settings, rename, or deregistration command is accepted before this completes.

1. iOS writes `OWNER|<OwnerID>|<ClientNonce>`.
2. ESP32 notifies
   `SERVER2|<DeviceID>|<ClientNonce>|<ServerNonce>|<HMAC-SHA256(OwnerKey, "server2|<DeviceID>|<OwnerID>|<ClientNonce>|<ServerNonce>")>`.
3. iOS verifies the server proof, then writes
   `PROOF|<OwnerID>|<ClientNonce>|<ServerNonce>|<HMAC-SHA256(OwnerKey, "client2|<DeviceID>|<OwnerID>|<ClientNonce>|<ServerNonce>")>`.
4. ESP32 verifies the owner and both nonces, then notifies
   `OK2|<DeviceID>|<ClientNonce>|<ServerNonce>` and opens the authenticated session.

### Protected session frames

After `OK2`, all app-to-device writes on the auth, navigation, route, GPS, and
settings characteristics use AES-256-GCM. Auth replies and every
device-to-app navigation notification—including destination requests,
capabilities, acknowledgements, and transfer status—use the reverse protected
direction. Plaintext notifications are rejected while a v2 session exists. The
two directional keys are:

```text
WriteKey  = HMAC-SHA256(OwnerKey, "session2-write|<DeviceID>|<ClientNonce>|<ServerNonce>")
NotifyKey = HMAC-SHA256(OwnerKey, "session2-notify|<DeviceID>|<ClientNonce>|<ServerNonce>")
```

App-to-device frame (`S2`) and device-to-app notification (`R2`):

```text
Magic: 2 bytes (ASCII S2 or R2)
Sequence: UInt32 big-endian
Ciphertext: 0 or more bytes
Tag: 16-byte AES-GCM tag
```

Channels are `1=auth`, `2=navigation`, `3=route`, `4=GPS`, and `5=settings`.
Each direction has an independent strictly increasing sequence per channel.
Receivers reject zero, replayed, out-of-order, wrong-channel, or invalid-tag
frames. The 12-byte nonce is `Channel || 7 zero bytes || Sequence`. Additional
authenticated data is ASCII `write2|` for `S2` or `notify2|` for `R2`, followed
by the one-byte channel and four-byte sequence. The frame adds 22 bytes, so iOS
subtracts that overhead before packet sizing.

Ownership setup messages are each at most 182 bytes and require an ATT MTU of
at least 185. Firmware checks the negotiated MTU before notifying. Swift and
mbedTLS tests share exact `S2` and `R2` golden vectors to prevent wire-format
drift.

An owned device replies `OWNED|<DeviceID>` or `DENIED|<DeviceID>` to an
unauthorized client and does not fall back to the global legacy key.

### Rename, deregistration, and recovery

Inside protected `S2` frames, iOS can rename with `NAME|<UTF8NameHex>`; ESP32
persists the name and returns a protected `NAME_OK|<UTF8NameHex>`. `UNPAIR`
first persists a signed revocation tombstone, removes the owner ID, owner key,
and name, then returns protected
`UNPAIRED2|<DeviceID>|<ReceiptNonce>|<ReceiptProof>`, where:

```text
ReceiptProof = HMAC-SHA256(
  OwnerKey,
  "revoked2|<DeviceID>|<OwnerID>|<ReceiptNonce>"
)
```

After every owner authentication, iOS sends protected `GET_NAME`; ESP32 returns
protected `NAME_INFO|<UTF8NameHex>`. Registry name changes are committed only
from this authenticated response (or `NAME_OK`), so a dropped rename response
reconciles on reconnect without trusting plaintext `INFO` metadata.

iOS verifies this receipt with its stored credential before deleting that
credential. If the notification is dropped, the device retains and exposes the
same compact receipt on subsequent `INFO` responses as
`DEVICE|2|<DeviceID>|<Claimed>||<ReceiptNonce>|<ReceiptProof>`, including after
a new owner registers. This lets the prior iPhone reconcile a missed handoff
without retaining the old secret on the device. Both receipt forms fit the
supported notification value limit. A disconnected Settings entry also offers
an explicit local Forget action for devices that were reset, transferred more
than once, lost, or destroyed.

At boot, firmware distinguishes an interrupted `UNPAIR` from an older handoff
receipt by verifying the tombstone with the currently committed owner key. If
it matches, firmware completes owner-record cleanup before advertising. If the
same iPhone later re-pairs with a different per-device key, the old receipt no
longer validates under the current credential and remains available to
reconcile the earlier handoff. A receipt from any historical owner never makes
an invalid current-owner record appear unclaimed; current-record corruption
always fails locked until the eight-second physical recovery action.

If the owner iPhone is lost, holding the ESP32 BOOT button for eight seconds
clears ownership locally and makes the device available for registration again.
The stable device ID remains unchanged.

### Hardware security boundary

This ownership layer prevents remote/nearby phones from controlling or
impersonating a registered Bike Computer. Physical possession of the hardware
is intentionally a recovery authority through the BOOT action; the current
development firmware does not claim resistance to invasive flash extraction or
malicious reflashing. Its per-device owner key is stored in ordinary NVS.

A production SKU whose threat model includes stolen-hardware key extraction
must add a separately provisioned hardware-security profile: NVS encryption,
flash encryption, Secure Boot, protected signing/encryption keys, disabled or
controlled debug/download paths, and a tested OTA/recovery ceremony. Those
eFuse and key-management operations are manufacturing decisions and are not
enabled implicitly by this application protocol.

### Legacy compatibility

Only genuinely older firmware accepts the v1 shared-key handshake. Protocol-v2
firmware never accepts the app-wide key, including when pristine, reset, or
unclaimed; unreadable or partial ownership storage also fails closed. iOS keeps
the legacy client path solely for a previously known legacy peripheral that
does not expose v2 identity information.

The legacy shared local key is `BikeComputer BLE v1 local pairing key`:

1. iOS writes `HELLO|<nonce>`.
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
| `4` | Legacy display rotation | Ignored. Rotation is fixed by firmware target: 90° on the 1.75-inch device and 0° on the 2.06-inch device. |
| `6` | Map rotation mode | `0` north-up, `1` course-up |
| `7` | Map zoom level | `0...5` |
| `8` | Map visibility and global navigation-overlay mask | bit 0 buildings, bit 1 parks/green space, bit 2 paths/footways, bit 3 major roads, bit 4 residential/other local roads, bit 5 water, bit 6 railways, bit 7 other areas, bit 8 route overlay, bit 9 current position marker, bit 10 service roads, bit 11 tracks, bit 12 extended-mask marker |
| `9` | Map street line width boost | `0...24` px added to known road/path line style widths; legacy unknown lines are boosted when their stored style width is at least 3px; final rendered width is capped at 24px |
| `10` | Map current-position marker scale | `1...5`; default is `2`, so the map position marker renders at twice its original size. The firmware shows a white dot when no route is loaded and a white arrow while navigating. |
| `11` | Tap to switch screens | `0` disabled, `1` enabled. When enabled, a short tap cycles the device through the enabled main screens. Map drags and long presses are ignored by this shortcut. |
| `12` | Device brightness | `5...100` percent on supported hardware |
| `13` | Enabled main screens mask | bit 0 Map, bit 1 Navigation, bit 2 Ride Stats, bit 3 Map + Navigation, bit 4 Battery Status. Invalid or empty masks fall back to all supported screens. Existing four-screen configurations enable Battery Status once during migration, after which it remains user-toggleable. |
| `14` | Default main screen | `0` Map, `1` Navigation, `2` Ride Stats, `3` Map + Navigation, `4` Battery Status. Invalid or disabled defaults prefer Map + Navigation, then the first enabled fallback screen. |
| `15` | Disconnected sleep timeout | seconds before deep sleep while not connected to the app: `60`, `120`, `300`, `600`; `0` disables automatic disconnected sleep. An unclaimed device waiting to be added applies a minimum 600-second registration grace period; `0` still disables automatic disconnected sleep. |
| `16` | Map + Navigation minimum polygon size | `0...50` |
| `17` | Map + Navigation detail level | `0` low, `1` medium, `2` high |
| `18` | Map + Navigation route line width | `2...48` |
| `19` | Map + Navigation zoom level | `0...5` |
| `20` | Map + Navigation feature visibility mask | feature bits and the extended-mask marker use the same meanings as ID `8`; navigation overlay bits remain global via ID `8` |
| `21` | Map + Navigation street line width boost | `0...24` px |
| `22` | Map + Navigation current-position marker scale | `1...5` |
| `23` | Connected phone battery level | transient whole-number percentage `0...100`; iOS sends it after authentication and whenever the phone battery level changes. Firmware clears it on disconnect. |
| `24` | Connected phone charging state | transient `0` not charging, `1` charging; iOS sends it after authentication and whenever the public battery state changes. Firmware clears it on disconnect. |

The settings list and the device's tap/PWR-button cycle use this screen order:
Map + Navigation, Ride Stats, Map, Navigation, then Battery Status.

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

Supported sound IDs on `WAVESHARE_AMOLED_175` and `WAVESHARE_AMOLED_206`:

| ID | Sound |
| ---: | --- |
| `1` | Bell ding |
| `2` | Plastic bicycle horn |
| `3` | Rotating bicycle bell |
| `5` | Squeeze horn |

`VolumePercent` must be in the inclusive range `0...100`. For compatibility,
the firmware also accepts the older frame containing only `SoundID` and uses
the default volume of `70`. The 1.75 hardware profile maps `70%` to 0 dB DAC
gain and caps `100%` at +6 dB; the established 2.06 curve is unchanged.

Playback requests are queued by the firmware and run outside the BLE callback.
Unsupported IDs, invalid volumes, and sound commands received before
authentication are rejected.

The app configures the Waveshare PWR button as a local honk control with another
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
classes. Version `4` advertises that the client understands Battery Status
screen settings so the device can distinguish a current screen mask from one
sent by an older four-screen app; older app masks preserve the device's
existing Battery Status preference. Version `5` advertises destination-catalog
and device-originated route-request support. Receiving a `CAPS` request alone does not
switch the firmware's
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
configuration from versioned responses. Flag bit `5` reports firmware support
for the Battery Status screen and phone-battery telemetry. The app waits for
capability negotiation before sending screen IDs `13`/`14` or phone-battery IDs
`23`/`24`; when bit `5` is absent, it sends only the legacy four-screen mask and
never selects Battery Status as the device default. An authoritative
five-screen value for setting ID `13` sets bit `30` as a version marker. The
firmware removes that marker before persistence; unmarked masks from older apps
or capability-fallback paths preserve the existing Battery Status bit. This
also keeps the preference intact when a `CAPS` response is lost.

Flag bit `6` reports firmware support for the destination picker described
below. iOS does not send destination data until this bit is present, so older
firmware and other board targets continue to use the existing navigation UI.

## Destination Picker

The idle Map + Navigation overlay mirrors up to three favorites from the
companion app. Recent searches are not sent or displayed. Labels are non-empty
UTF-8 strings of at most 64 bytes, and an empty catalog is valid.

When idle, the picker expands the bottom overlay to two-thirds of the display.
It shows large, transparent destination rows with a small yellow star before
each label and no section heading. Tapping the exposed map or pressing the
BOOT/forward button dismisses the picker and restores the normal one-third
guidance strip; a later forward press resumes normal screen cycling.

The logical catalog is versioned JSON:

```json
{"version":1,"generation":17,"items":[{"token":1,"kind":"favorite","label":"Home"},{"token":2,"kind":"favorite","label":"Work"}]}
```

`generation` is a non-zero `UInt32`. iOS starts each process from a randomized
non-zero generation and advances it after each queued catalog, preventing a
retained device catalog from aliasing a different token map after app relaunch.
Each item has a unique non-zero `UInt16` token and uses `kind: favorite`. For
schema-v1 compatibility, firmware still
accepts correctly ordered `recent` items from older apps but does not render
them. Coordinates and search queries remain private to the app; iOS keeps the
token-to-`SavedDestination` mapping so an exact saved coordinate is used when
available.

iOS chunks the JSON over either authenticated command route:

```text
"DLST" | TransferID: UInt8 | ChunkIndex: UInt8 | ChunkCount: UInt8 | JSON bytes
```

Chunks are zero-indexed, sequential, individually bounded by the negotiated
write length, and use at most 160 chunks / 4096 reassembled bytes. The firmware
commits a catalog only after every chunk arrives in order and the complete JSON
passes schema, ordering, count, token, and label validation. An interrupted,
oversized, malformed, out-of-order, or five-second-stale transfer is discarded
without replacing the last committed catalog.

When a row is tapped, firmware notifies iOS on `2A6E`:

```text
"DREQ" | Generation: UInt32LE | Token: UInt16LE
```

The device immediately displays an animated white spinner with
`Starting navigation...` and suppresses repeat requests while one is pending.
iOS accepts the request only when generation and token match its active catalog,
the device is authenticated, navigation is idle, and a fresh, reasonably
accurate current location is available. It calculates a cycling route from that
location to the exact saved endpoint and replies on either command route. When
the authenticated picker becomes available, iOS may request Always location
permission while the app is active, but it does not run continuous GPS merely
because the device is connected. A row tap starts a request-scoped location
session and holds it through the complete MapKit route-start outcome. With only
When In Use permission, that session must start while the app is active; an
unsupported background start fails instead of pretending the route is pending:

```text
"DNST" | Generation: UInt32LE | Token: UInt16LE | State: UInt8 | Message: UTF-8
```

State `1` is calculating, `2` started, `3` failed, and `4` stale. Messages are
at most 64 UTF-8 bytes. iOS cancels location/search/directions work at 13 seconds
so its terminal response has time to arrive before firmware's 15-second pending
request timeout. A disconnect also cancels any device-originated route before
it can start on the phone alone. Terminal status returns the overlay to the
picker after five seconds. Active maneuver data always takes precedence over
the picker. The last valid catalog remains in RAM across disconnects, while
tapping it without an authenticated app connection shows
`Open app to start navigation`.

iOS republishes the catalog after authenticated capability negotiation, any
favorite change, reconnect, and navigation stop. The logical catalog is queued
atomically on iOS so write-queue pressure cannot expose a partial new
generation. A failed acknowledged catalog chunk schedules a forced full-catalog
retry with a new generation. DNST control responses use a separate bounded
priority lane so even a bulk queue filled entirely by protected catalog chunks
cannot starve the device's pending request. An acknowledged DNST write failure
retries the latest status up to two times; a newer status supersedes stale
retries.

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

The HTTP credential is not part of the map-status payload. After sending
`MTRNenter`, iOS also sends the shared `DSTS` status request and waits for a new
authenticated response whose `mode` is `map`, whose `baseUrl` matches the map
status, and whose `sessionToken` is non-empty. A status cached before the enter
request is not sufficient. The app sends that token as
`X-BikeComputer-Transfer-Token` on every local HTTP request.

Status responses should include:

- `activeMapId`: map id from `/sdcard/VECTMAP/active-map.json`, if present.
- `activeSessionId`: durable content-derived session selected by
  `active-map.json`, when installed by transfer-capable firmware. This
  distinguishes regenerated packs that intentionally reuse a stable map ID.
- `enabled`: whether Wi-Fi/HTTP upload mode is enabled.
- `firmwareVersion`, `firmwareBuild`, and `firmwareGitSha`: the exact running
  firmware identity. The git identity must be the full 40-character lowercase
  SHA from a clean source tree; dirty or unidentified builds fail closed and do
  not advertise protocol v2. Promoted stream artifacts name the approved values
  and iOS stays on protocol v1 when any field differs.
- `protocols`: supported map-install protocol versions. Version `2` is present
  only when SD storage is initialized and at least one production stream
  verification key is compiled into firmware.
- `streamFormatVersions`: accepted device-native stream versions when protocol
  v2 is available.
- `streamTrust`: exact production verification capabilities, each encoded as
  `keyId=SHA256(X9.63 public key)`. iOS selects v2 only when the artifact's key
  identity matches one of these entries; a device with an older or rotated-out
  trust set stays on protocol v1.
- `baseUrl`: temporary HTTP base URL when transfer mode is enabled.
- `activation`: the latest activation `status`, monotonic boot-local
  `sequence`, `sessionId`, optional `mapId`, numbered `step`, total `steps`,
  integer `progress` percentage, and structured `error`, when present. Status
  is `idle`, `receiving`, `paused`, `finalizing`, `ready`, `activating`,
  `failed`, or `installed`. BLE uses a compact form
  that omits error messages and duplicate `lastError`; HTTP retains the full
  diagnostic text.
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
- archive entries are hashed while they are extracted. Each completed file gets
  a durable verification receipt, so boot recovery skips completed entries and
  only redoes a file interrupted in progress. The original archive remains on
  SD until activation commits, so recovery never requires another phone upload.
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
| `PUT` | `/map-transfer/sessions/{sessionId}/pack.zip` | Store one complete archive, then start durable device-owned activation. |
| `PUT` | `/map-transfer/sessions/{sessionId}/install-stream` | Stream one signed v2 artifact directly into an inactive root, then start durable device-owned activation. |
| `PUT` | `/map-transfer/sessions/{sessionId}/manifest.json` | Upload the map pack manifest. |
| `PUT` | `/map-transfer/sessions/{sessionId}/VECTMAP/{mapId}/{folder}/{file}` | Upload one `.fmb` or `.fmp` file. |
| `POST` | `/map-transfer/sessions/{sessionId}/activate` | Validate and atomically activate the staged map. |

The archive route starts activation after its response is durably staged so a
background iOS upload remains installable even if iOS terminates the originating
app process. A pending-session marker is committed before the upload response;
firmware resumes it after a board reset until activation reaches a terminal
result. Firmware disables transfer mode after that activation finishes.
The explicit activation route remains idempotent for the foreground per-file
fallback and for clients that are still alive after the archive upload.

The v2 stream route requires
`Content-Type: application/vnd.openbikecomputer.map-stream`, an exact
`Content-Length`, and the same short-lived transfer token as every other map
endpoint. It does not retain the request artifact. Arbitrary network chunks are
fed into the transport-independent signed-stream receiver, which validates
every `.fmb` or legacy `.fmp` block while writing and hashing each new payload
byte once into the inactive root. A successful response means the
ready and pending markers are durable; Step 3 activation is then device-owned
and is resumed after reboot. A truncated request remains paused at its durable
checkpoint for a matching retry.
Renderer validation also enforces a 2 MiB encoded block limit, at most 16,384
features, at most 262,144 points, and at most 262,144 decoded polygon-grid
entries per block. ASCII input is normalized for CRLF, must end with a physical
newline, and uses the renderer's lowercase `0x` color and signed 16-bit
coordinate grammar.

All transfer requests use HTTP/1.1 with a five-second request-wide header
deadline, at most 512 bytes per line, 8 KiB of request-line/header bytes, and 64
lines. Over-limit or incomplete headers are rejected explicitly. Duplicate
`Content-Length`, `Content-Type`, or transfer-token headers fail closed, and
`Transfer-Encoding` is not accepted. The listener processes the body on one
dedicated bounded worker so the device UI, BLE service, controls, and progress
overlay remain responsive during a long upload. Disabling or switching the BLE
transfer session invalidates an in-flight request generation; an incomplete v2
body becomes paused and cannot queue activation after authorization is revoked.

Protocol v2 is advertised only while the SD map namespace is mounted and
accessible. Entering map-transfer mode and accepting a v2 body also require a
successful writable probe. A blank mounted card creates the map namespace
during that probe, and a removed/reinserted card is unmounted and remounted on
the next authenticated enter request rather than requiring a device reboot.

After the active pointer transaction, the final step remains nonterminal until
the main loop locates and parses a renderer block from the new root. All blocks
were already structurally validated during their unavoidable write/hash pass,
so activation adds no full payload scan. Only that acknowledgement emits
`installed` and closes
transfer mode. A rejected renderer root restores the previous valid selection
and emits `renderer_reload`. A completed v1 archive is an explicit fallback
choice: before v1 activation, firmware removes any unselected ready or paused
v2 root and its pending marker. Boot applies the same arbitration, so a stale
v2 install cannot silently replace the archive after restart.

An accepted activation returns HTTP 202 with the boot-local activation
`sequence`. The app matches that acknowledgement to later HTTP/BLE terminal
status so a cached same-session result cannot be mistaken for the new attempt.
If a manifest HEAD encounters an interrupted activation journal, firmware first
returns 503 and then performs exceptional recovery. The app permits a bounded
long wait only after that explicit recovery/busy response; ordinary transport
timeouts retain a short retry limit.

The HTTP service is configured by firmware at boot but remains disabled until
BLE transfer control enables it for an authenticated app session.
