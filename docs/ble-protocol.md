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
| `9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1003` | iOS/Watch -> ESP32 | Fixed 16-byte core/extended/Watch-motion or 28-byte origin workout frame | Watch-owned workout state, optional live metrics/provenance, and capability-gated raw Watch GPS motion evidence. |
| `9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1004` | bidirectional | Fixed 52-byte `RAUT` v2 frame | Internal, feature-gated ride-detection decisions, configuration, prompt responses, cancellations, acknowledgements, confirmations, and resynchronization. |

`DistanceMeters` is an unsigned 16-bit decimal value (`0...65535`). The iOS
sender saturates larger maneuver distances at `65535` instead of allowing the
firmware field to wrap.

If iOS has cached an older GATT table and does not discover `2A6F`, `2A72`,
`2A73`, or the workout characteristic, the app falls back to framed binary
writes over authenticated `2A6E`. Current firmware exposes acknowledged and
unacknowledged workout writes, and iOS prefers the acknowledged native route.
For earlier firmware whose workout characteristic is unacknowledged, iOS uses
acknowledged `WTLM` whenever `2A6E` supports responses. Native
write-without-response remains the compatibility route when the command
transport is also unacknowledged.
Fallback frame prefixes:

| Prefix | Payload |
| --- | --- |
| `MAPR` | route geometry packet |
| `GPSP` | GPS position packet |
| `MSET` | map setting packet |
| `WTLM` | one fixed 16-byte core/extended/Watch-motion or 28-byte origin workout frame; prefix plus payload is exactly 20 or 32 plaintext bytes before the protected session envelope described below |
| `RAUT` | one fixed 52-byte ride-automation frame; prefix plus payload is exactly 56 plaintext bytes before ownership-v2 protection |

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
settings, workout, rename, or deregistration command is accepted before this
completes.

1. iOS writes `OWNER|<OwnerID>|<ClientNonce>`.
2. ESP32 notifies
   `SERVER2|<DeviceID>|<ClientNonce>|<ServerNonce>|<HMAC-SHA256(OwnerKey, "server2|<DeviceID>|<OwnerID>|<ClientNonce>|<ServerNonce>")>`.
3. iOS verifies the server proof, then writes
   `PROOF|<OwnerID>|<ClientNonce>|<ServerNonce>|<HMAC-SHA256(OwnerKey, "client2|<DeviceID>|<OwnerID>|<ClientNonce>|<ServerNonce>")>`.
4. ESP32 verifies the owner and both nonces, then notifies
   `OK2|<DeviceID>|<ClientNonce>|<ServerNonce>` and opens the authenticated session.

### Protected session frames

After `OK2`, all app-to-device writes on the auth, navigation, route, GPS,
settings, and workout characteristics use AES-256-GCM. Auth replies and every
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

Channels are `1=auth`, `2=navigation`, `3=route`, `4=GPS`, `5=settings`,
`6=workout`, and `7=ride automation`.
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

### Scoped Apple Watch controller

An authenticated owner can grant one Apple Watch a random 128-bit controller
ID and independent 256-bit ride key. The key is generated by iOS, transferred
to the paired Watch with interactive WatchConnectivity, and stored on Watch in
the non-synchronizing, device-only data-protection Keychain. It is never an
owner key. The Watch role can write only navigation, route geometry, GPS,
workout, and the feature-gated ride-automation channel; it cannot use Settings,
rename, read/change the owner name, transfer maps or firmware, or deregister the
device.

Enrollment is proof-before-commit:

1. In a protected owner Auth frame, iOS writes
   `WCTRL_STAGE|<ControllerID>|<ControllerKey>`.
2. Firmware persists the candidate and random 16-byte challenge, then returns
   `WCTRL_STAGED|<ControllerID>|<Challenge>`.
3. Watch stores the candidate as pending and returns
   `HMAC-SHA256(ControllerKey, "watch-enroll1|<DeviceID>|<ControllerID>|<Challenge>")`
   to iOS.
4. iOS writes
   `WCTRL_COMMIT|<ControllerID>|<Challenge>|<WatchProof>`.
5. Firmware verifies the exact staged record and commits it with two NVS slots:
   slot contents and marker first, active-slot pointer last. It returns
   `WCTRL_COMMITTED|<ControllerID>` only after the pointer is durable.
6. iOS asks Watch to promote that exact pending key. On a later reconnect,
   protected `WCTRL_STATUS` returns `WCTRL_STATUS|none` or
   `WCTRL_STATUS|<ControllerID>` so an interrupted Watch promotion can be
   repaired idempotently.

An owner revokes with protected `WCTRL_REVOKE|<ControllerID>`. Firmware removes
the sole active-slot pointer first and returns
`WCTRL_REVOKED|<ControllerID>`. iOS then queues exact Keychain deletion to the
Watch; reachability is not required for deletion. Owner deregistration and the
physical owner-reset path also remove every active, inactive, and staged Watch
record. Failed/corrupt active storage disables capability bit 14 and fails
Watch authentication closed while preserving owner authentication for
recovery.

Every Watch BLE connection performs a fresh mutual challenge:

```text
WATCH|<ControllerID>|<ClientNonce>
WS2|<ControllerID>|<ClientNonce>|<ServerNonce>|<ServerProof>
WATCH_PROOF|<ControllerID>|<ClientNonce>|<ServerNonce>|<ClientProof>
WOK2|<ClientNonce>|<ServerNonce>

ServerProof = HMAC-SHA256(
  ControllerKey,
  "watch-server1|<DeviceID>|<ControllerID>|<ClientNonce>|<ServerNonce>"
)
ClientProof = HMAC-SHA256(
  ControllerKey,
  "watch-client1|<DeviceID>|<ControllerID>|<ClientNonce>|<ServerNonce>"
)
```

The compact `WS2` response binds the already-known DeviceID inside its HMAC and
stays below the 182-byte Auth value limit. After `WOK2`, Watch uses the same
`S2`/`R2` framing and channel numbers with independently derived keys:

```text
WriteKey = HMAC-SHA256(
  ControllerKey,
  "watch-session-write|<DeviceID>|<ControllerID>|<ClientNonce>|<ServerNonce>"
)
NotifyKey = HMAC-SHA256(
  ControllerKey,
  "watch-session-notify|<DeviceID>|<ControllerID>|<ClientNonce>|<ServerNonce>"
)
```

Watch must then send protected `LEASE_CLAIM`. `LEASE_RENEW` and
`LEASE_HEARTBEAT` refresh the 15-second exclusive writer lease;
`LEASE_RELEASE` gives it up. The holder identity includes the full controller
ID, a fresh non-zero authentication-session ID, and role. Every accepted ride
write refreshes the lease. Disconnect, revocation, or timeout releases it.
Owner sessions claim during authentication and may reclaim an expired lease on
their first ride write for compatibility with iPhone versions predating the
lease commands. A scoped Watch never receives that compatibility bypass.

The iPhone publishes the active ownership-v2 DeviceID to Watch in a versioned
`applicationContext` field. Watch filters its device-local Keychain credentials
to that exact DeviceID; if the field has not arrived, only a single
unambiguous credential may be used. Changing or clearing the iPhone selection
disconnects any different direct session before another credential is tried.

At the start of a Watch-direct ride, Watch sends a versioned preparation
request over interactive WatchConnectivity. The request binds a random
preparation ID, the selected DeviceID, and `prepare` or `release`. An idle
iPhone disables reconnect and yields its BLE connection. Active iPhone
navigation, map/device transfer, pairing, or ownership administration rejects
the request. Release is also queued durably; iPhone resumes only when DeviceID
and preparation ID both match, so a delayed release from an older ride cannot
cancel a newer preparation. This coordination does not grant write authority:
the authenticated firmware lease remains final. A persisted iPhone yield
expires after 24 hours if its release never arrives.

### Application-confirmed critical ride delivery

Client version `20` requests capability bit `22` (`0x00400000`). When that bit
is present, an authenticated owner iPhone or scoped Watch wraps critical ride
state in a version-1 logical command envelope. This distinguishes physical ATT
acceptance from firmware acceptance. Peers without bit `22` continue to use the
existing unwrapped compatibility path.

The machine-readable source for these constants is
`protocol/ride-ble-contract-v1.json`. Running
`tools/generate_ride_ble_contract.py` produces the checked-in Swift and C++
constants; `tools/generate_ride_ble_contract.py --check` is a CI drift gate.
The lifecycle and compatibility rules in this document remain authoritative
human-readable protocol text.

An `RCM1` command member has this binary layout:

```text
Offset  Size  Field
0       4     ASCII "RCM1"
4       1     Version = 1
5       1     CommandType
6       1     MemberIndex, zero based
7       1     MemberCount, 1...8
8       16    CommandID, UUID bytes in network/display order
24      4     StateGeneration, UInt32 little-endian, non-zero
28      ...   Existing characteristic payload for this member
```

Command type `1` is `navigationClear`; type `2` is `workoutState`. A navigation
clear is one owner member (empty route) or two Watch members (empty route plus
the canonical `1|0|Navigation idle` maneuver). A workout group contains the
canonical core, extended, and optional origin frames in their existing order.
Only terminal/idle workout state and explicit navigation clear require this
application acknowledgement; replaceable GPS, route windows, maneuvers, and
ordinary live workout snapshots retain latest-state resynchronization semantics.

Firmware validates and admits each member under the same authenticated role,
lease, command ID, state generation, type, and member count before mutating
that member's retained state. The tracker serializes one group at a time;
completed duplicates, in-flight duplicates, and interleaved groups are rejected
or replayed at admission, so a member cannot apply state a second time. Members
can become visible one by one while a group is arriving, but an interrupted
group remains pending and the controller retries or resynchronizes the complete
logical state. Firmware emits no success acknowledgement for a partial group.
It revalidates the authoritative controller lease immediately before a queued
route is retained. When the complete operation has been validated and retained
by the corresponding firmware state owner, it
notifies the controller on protected navigation channel `2` with exactly 32
bytes:

```text
Offset  Size  Field
0       4     ASCII "RAK1"
4       1     Version = 1
5       1     CommandType
6       1     Result
7       1     Reserved = 0
8       16    CommandID
24      4     StateGeneration, UInt32 little-endian
28      4     Current lease generation, UInt32 little-endian, non-zero
```

Results are `0=success`, `1=stale`, `2=busy`, `3=unauthorized`,
`4=malformed`, and `5=resource-rejected`. `success` and an exactly matching
`stale` result complete the logical command. Other results are typed failures;
in particular `resource-rejected` is not reported as a radio timeout. Clients
match type, command ID, state generation, their local connection generation,
and a non-zero firmware lease proof before completing a command. The numeric
lease generation is firmware-owned: current authentication and lease responses
do not expose that generation to clients for an equality comparison. Protected
notification sequencing plus command and connection identity prevent delayed,
duplicate, or old-connection acknowledgements from completing newer work.

Firmware retains the eight most recent completed command results and replays
the matching `RAK1` for a duplicate command ID without applying the state
twice. A client may retry one application-ack timeout with the same command ID
and state generation, but it creates a new protected `S2` frame and sequence.
Disconnect discards encrypted transport bytes; the controller reconnects,
reauthenticates, reacquires its lease, and regenerates a complete latest-state
resynchronization from logical state. Each client admits a critical group to its
outbound queue atomically, and replaceable telemetry cannot evict it; firmware
then serializes and tracks its individual members through completion.

Golden vectors (command payload bytes `aa bb`):

```text
RCM1 workout member 1/3, command 00112233-4455-6677-8899-aabbccddeeff,
state generation 0x12345678:
52 43 4d 31 01 02 01 03 00 11 22 33 44 55 66 77
88 99 aa bb cc dd ee ff 78 56 34 12 aa bb

RAK1 success for the same command/state, lease generation 9:
52 41 4b 31 01 02 00 00 00 11 22 33 44 55 66 77
88 99 aa bb cc dd ee ff 78 56 34 12 09 00 00 00
```

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
The first point is the rider's exact projection onto the route, followed only
by forward route vertices. The retained packet never contains a rider-to-route
connector: firmware prepends its current `PresentedPose` while drawing, so the
blue head stays attached to the arrow without leaving a stale closest segment.
The app's epoch-scoped bounded matcher sends a new forward window when its
matched segment changes, subject to a two-second rate limit. This prevents
loops or self-intersections from making firmware reacquire an older segment;
ordinary window revisions update the live foreground and do not cancel a 3D
base render.

A zero-length route geometry packet clears the route overlay on the ESP32. The
iOS app sends this when navigation stops so stale route geometry is not used for
route-overlay rendering or Course Up rotation.

## GPS Position (`2A72`)

Little-endian binary packet:

```text
Lat: Int32 microdegrees
Lon: Int32 microdegrees
Heading: UInt16 degrees, 0...359; 0xFFFF invalid when CAP2 bit 13 is negotiated
UnixTime: UInt32 seconds since 1970-01-01T00:00:00Z (optional)
Speed: UInt16 centimeters/second, 0xFFFF invalid (optional)
Altitude: Int16 meters (optional)
DistanceTraveled: UInt32 meters (optional)
ElapsedTime: UInt32 seconds (optional)
RouteRemaining: UInt32 meters, 0xFFFFFFFF invalid (optional)
QualitySchema: UInt8, value 1 (optional; requires complete quality tail)
QualityFlags: UInt8, bit 0 fix valid, bit 1 horizontal accuracy available
HorizontalAccuracy: UInt16 decimeters, 0xFFFF unavailable
SampleAge: UInt16 milliseconds, 0xFFFF unavailable
```

Live CoreLocation coordinates are sent as WGS-84. Simulated or MapKit route
coordinates are converted from GCJ-02 to WGS-84 before writing. Firmware accepts
the original 8-byte lat/lon payload, the 10-byte lat/lon/heading payload, the
14-byte payload with Unix time, and the extended 30-byte telemetry payload. A
client that negotiated CAP2 bit `17` appends the six-byte quality-v1 tail for a
36-byte payload. The quality tail carries the original Core Location horizontal
accuracy and sample age; it never fabricates HDOP. `SampleAge`, rather than the
sender's wall clock, is subtracted from the BLE arrival timestamp before ride
detection evaluates freshness. The
Waveshare firmware uses the optional Unix time to sync the onboard PCF85063 RTC.

Quality-v1 is accepted only as a complete 36-byte payload. Unknown schemas,
reserved flag bits, truncated or oversized extensions, mismatched accuracy
availability/sentinels, invalid coordinates, and a valid-fix claim without
measured speed, accuracy, and sample age reject the entire packet before map or
detector state changes. Legacy packets continue to update navigation/map state
but cannot refresh ride-detection evidence. Authenticated BLE evidence is
cleared when the session or owner lease ends.

Example quality tail for a valid fix with 7.3 m accuracy and 1234 ms age:

```text
01 03 49 00 d2 04
```

Client version `11` and CAP2 feature bit `13` negotiate the explicit invalid
heading sentinel. Without that bit, the app preserves the legacy missing-course
value `0`; version-11 firmware knows version-10 clients are ambiguous and uses
the live route bearing before that zero during guidance. Thus new app/old
firmware, old app/new firmware, and new app/new firmware remain interoperable.

The iOS sender treats GPS as replaceable state, not an ordered history. At most
one unsent native or `GPSP` position is retained; a newer position replaces only
that pending position and never route, settings, transfer, destination, auth, or
workout traffic. A complete maneuver snapshot uses the bounded priority lane so
it is delivered ahead of a GPS backlog. Native `2A72` prefers acknowledged
delivery when the characteristic advertises it and the protected payload fits
CoreBluetooth's current maximum. This prevents a missing write-without-response
readiness callback from head-of-line blocking the GPS state that opens the map.
Firmware that exposes only write-without-response still uses that native path
with CoreBluetooth flow control. If no native write fits, iOS uses the
authenticated navigation fallback. Route and catalog batches remain atomic and
ordered.

## Watch Workout Telemetry (`9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1003`)

Workout telemetry is iOS/Watch-to-device, RAM-only, and accepted only after the
existing local authentication handshake. The logical native payload is exactly
16 bytes for core/extended/Watch-motion frames or 28 bytes for the optional origin frame. In
an ownership-v2 session it is carried in an `S2` frame on protected channel `6`,
for a 38- or 50-byte native wire write. Current firmware exposes the
native characteristic with both write properties, so iOS uses acknowledged
delivery. The bounded queue admits each correlated core-plus-extended pair
atomically, preserves pair ordering, coalesces obsolete state, and retries until
the latest state converges. Earlier firmware with only an unacknowledged native
workout characteristic uses this fallback whenever the navigation
characteristic supports acknowledged writes:

```text
"WTLM" | 16-byte core/extended/Watch-motion or 28-byte origin workout frame
```

The fallback plaintext is exactly 20 or 32 bytes before ownership-v2 protection
and the protected fallback wire write is 42 or 54 bytes. Native and fallback
payloads use the same parser after their authenticated channel is unwrapped.
The ownership handshake already requires an ATT MTU large enough for either
protected write.
iOS prefers an acknowledged native workout characteristic when available, then
acknowledged `WTLM`, and uses native write-without-response only when no
acknowledged route is available. Persistent no-response backpressure triggers a
bounded reconnect instead of indefinitely blocking GPS, settings, and workout
state in the shared queue.
iOS sends no workout frames unless capability bit `7` is present, so older
firmware continues using the existing GPS ride fields unchanged.

### Core frame, kind `1`

| Offset | Size | Field |
| ---: | ---: | --- |
| `0` | 1 | frame kind `1` |
| `1` | 1 | session state |
| `2` | 2 | session token, `UInt16LE` |
| `4` | 4 | elapsed seconds, `UInt32LE` |
| `8` | 4 | distance meters, `UInt32LE` |
| `12` | 2 | speed centimeters/second, `UInt16LE` |
| `14` | 2 | current heart rate BPM, `UInt16LE` |

For the current relay contract, bits `6...7` of the core state byte carry a
non-zero pair generation (`1...3`); the session state remains in the low six
bits. Generation zero is the immediately preceding relay contract.

Session states are `0` idle/clear, `1` starting, `2` running, `3` paused, `4`
ending, `5` ended/final summary, and `6` failed. Idle requires token zero; every
other state requires a non-zero token. A native iPhone session-ended callback
does not produce state `5` until the final authoritative Watch snapshot arrives;
the interim `ending` frame carries unavailable numeric sentinels rather than
heartbeat-replaying a frozen snapshot.

When firmware has no retained core state, any valid non-idle generation-zero
core may seed the RAM snapshot so authentication or device-reboot
resynchronization can restore an ending, ended, or failed presentation. Once a
generation-zero session is retained, only an active starting/running/paused
core may replace it with a different token. A complete correlated current-pair
publication may replace a retained token in any non-idle state, including a
newer terminal snapshot that was published as the latest batched state.

### Extended frame, kind `2`

| Offset | Size | Field |
| ---: | ---: | --- |
| `0` | 1 | frame kind `2` |
| `1` | 1 | source/availability flags |
| `2` | 2 | session token, `UInt16LE` |
| `4` | 2 | average heart rate BPM, `UInt16LE` |
| `6` | 2 | active energy in tenths of a kilocalorie, `UInt16LE` |
| `8` | 2 | cycling power watts, `UInt16LE` |
| `10` | 2 | cycling cadence in tenths of an RPM, `UInt16LE` |
| `12` | 1 | current one-based heart-rate zone; zero unavailable |
| `13` | 2 | altitude meters, `Int16LE` |
| `15` | 1 | zone count; zero unavailable |

Source flag bit `0` means paired cycling-speed sensor, bit `1` Watch GPS speed,
bit `2` HealthKit cycling distance, bit `3` valid Watch altitude, and bit `4`
live heart-rate zone data. Bit `5` means the iPhone's mirrored snapshot is
current, even when every individual metric is unavailable. Bits `6...7` carry
the same pair generation (`1...3`) as the core state byte. Generation zero is
the legacy relay contract. A valid iPhone location fallback may supply altitude
without setting bit `3`. For compatibility with the immediately preceding
relay contract, firmware also treats a generation-zero active extended frame
without bit `5` as current when its preceding core was populated, and uses its
heartbeat to refresh the retained core. The predecessor contract encoded a
current-all-unavailable snapshot and transport loss with identical
generation-zero bytes. Firmware handles that ambiguous all-unavailable pair as
current-but-unavailable for one 10-second grace window, clears values instead
of presenting retained speed as live, and does not let later empty
extended-only heartbeats refresh core freshness. A later populated core or
extended frame proves recovery.

For unsigned 16-bit metric fields, `0xFFFF` means unavailable. For elapsed and
distance, `0xFFFFFFFF` means unavailable. Altitude uses `Int16.min` (`0x8000`)
as unavailable. Valid values saturate one step below their sentinel rather than
wrapping; valid altitude saturates to `-32767...32767`. Non-finite and negative
unsigned metrics are unavailable. Heart rate must be positive; zero remains a
valid speed, energy, power, or cadence value. Active energy therefore ranges
from `0` through `6553.4` kcal.

### Origin/timing frame, kind `3`

Kind `3` is capability-gated and optional so preceding firmware continues to
consume only the core/extended pair. It preserves core `elapsedSeconds` as
HealthKit active/moving time.

| Offset | Size | Field |
| ---: | ---: | --- |
| `0` | 1 | frame kind `3` |
| `1` | 1 | pause origin: `0` none/confirmation pending, `1` manual, `2` automatic, `3` system, `4` unknown |
| `2` | 2 | session token, `UInt16LE` |
| `4` | 4 | wall elapsed seconds, `UInt32LE`; `0xFFFFFFFF` unavailable |
| `8` | 16 | authoritative Watch session UUID in RFC 4122 byte order; all zero unavailable |
| `24` | 2 | ride-detector profile version, `UInt16LE`; zero unavailable |
| `26` | 1 | last confirmed transition origin using the same origin enum |
| `27` | 1 | reserved, exactly zero |

Pause origin may be non-zero only for a paused session. A paused snapshot may
temporarily use zero while Watch-side provenance is being durably confirmed;
consumers must treat none, system, and unknown conservatively and never
auto-resume from them. Only an explicit user action is manual. An uncorroborated
HealthKit/session callback is unknown, and a system-attributed callback is
system. Any automatic origin requires a non-zero detector profile version.
Origin/timing frames
must match the retained session token and never create a workout on their own.
iOS queues core, extended, and origin atomically for initial publication,
state/origin changes, and authenticated reconnect. Ordinary metric heartbeats
continue to coalesce the core/extended pair; the origin frame has its own
coalescing identity and is resent when its values change. Firmware retains the
last valid origin frame in RAM and marks it stale with the associated workout.

### Watch motion frame, kind `4`

This frame is accepted only after CAP2 bit `23` is negotiated. It transports
raw Watch workout-location speed rather than the presentation-selected speed.

| Offset | Size | Field |
| ---: | ---: | --- |
| `0` | 1 | frame kind `4` |
| `1` | 1 | flags: bit 0 valid fix, bit 1 speed available, bit 2 accuracy available, bit 3 current source sample, bit 4 automatically-paused phase; bits 5...7 zero |
| `2` | 2 | active workout session token, `UInt16LE` |
| `4` | 4 | producer sample sequence, nonzero `UInt32LE` |
| `8` | 2 | speed in centimetres/second, `UInt16LE` |
| `10` | 2 | horizontal accuracy in decimetres, `UInt16LE` |
| `12` | 2 | sample age at send time in milliseconds, `UInt16LE` |
| `14` | 2 | persisted producer epoch, nonzero `UInt16LE` |

The token and confirmed running/automatically-paused phase must match retained
workout state. Duplicate or regressing sequences, old epochs, malformed flags,
and unauthenticated frames do not mutate evidence. Lifecycle changes clear the
retained motion sample. Firmware qualifies the source at three-second freshness
and `12.5 m` maximum horizontal uncertainty; candidate time comes from distinct
sample capture times, with a three-second maximum gap. No coordinates are
included.

iOS coalesces numeric changes to at most one update per second and sends
state/token and fresh-to-stale transitions immediately. Every new-contract
publication contains a core and extended frame stamped with the same cycling
generation; changes and heartbeats are therefore applied as one coherent pair.
The pair is sent at least every five seconds, including while paused or stale.
Both latest frames are resent after an authenticated reconnect. Current live
sessions set source flag bit `5`; an `ending` state that is currently awaiting
its authoritative final Watch snapshot also sets bit `5` while keeping numeric
fields unavailable.
Stale or disconnected live sessions preserve their state and token but send
unavailable numeric fields with all source flags, including bit `5`, clear.
Authoritative ended summaries retain final numeric values until an explicit
idle frame, a newer session, or device reboot.

Firmware decodes native and `WTLM` frames through one authenticated parser and
keeps the resulting workout state in RAM, separate from legacy `2A72` GPS
telemetry. For correlated generation `1...3` publications, malformed,
mismatched, partial, or wrong-generation frames leave the last coherent workout
state unchanged. A generation `1...3` core is staged and
becomes visible only after a valid extended frame with the same token and
generation arrives. This also lets a complete authenticated pair for a newer
terminal session replace an older retained session without exposing partial
state. Same-token state changes follow the shared workout transition matrix;
ending, ended, and failed cannot regress to a live state. A starting core after
an ended or failed snapshot is treated as an explicit new-session boundary so
a valid 16-bit token collision cannot hide the newer workout. If authentication
resynchronizes a colliding newer workout after it has crossed any transition
that would otherwise be invalid from a retained ending/ended/failed state,
firmware also accepts the complete correlated pair as a replacement, but only
when extended bit `5` proves that the resynchronized snapshot is current. This
includes active, ending, and cross-terminal outcomes. Partial or stale
same-token pairs leave the retained terminal snapshot unchanged. A live core
becomes stale after 10 seconds without a confirmed current
pair; Ride Stats then marks the Watch link lost and suppresses stale speed while
retaining the last received non-speed values. An all-unavailable active core is
held without refreshing freshness until its matching extended frame arrives.
Extended bit `5` set means the current snapshot genuinely has no available
metrics, so firmware clears the old values without marking the link stale. Bit
`5` clear on a correlated pair with every field unavailable marks upstream
transport loss immediately and retains the last snapshot. Explicit idle clears
the workout state. Ended summaries remain visible until idle, a new session, or
reboot. Successful local authentication
starts a transactional resynchronization: firmware keeps displaying the prior
RAM snapshot until a complete valid replacement core/extended pair arrives,
then swaps the pair atomically. A missing, malformed, partial, or disconnected
resynchronization therefore cannot erase the retained snapshot. GPS updates
continue to populate the legacy ride fields and cannot clear or overwrite Watch
workout state.

Ride Stats uses the Watch workout state whenever a non-idle core frame has been
accepted, otherwise it displays the legacy GPS ride fields. Its single page
shows speed, current heart rate and zone, distance, and elapsed time. The bottom
row shows altitude and route remaining when neither power nor cadence is
available. One available power or cadence metric replaces altitude; when both
are available, power and cadence replace altitude and route remaining.
Unavailable non-adaptive values display as `--`. Existing short-tap and hardware
screen cycling remain unchanged.

## Ride Automation (`9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1004`)

Ride automation is an internal-build protocol while the physical false-start,
recovery, and board-stability gates in
`docs/plans/automatic-ride-detection-implementation-plan.md` remain open.
Production firmware neither advertises CAP2 bit `15` nor runs this control
path. Manual `WREQ` and workout telemetry remain available.

The native characteristic carries authenticated notifications and writes on
ownership-v2 channel `7`. A cached GATT table uses:

```text
"RAUT" | 52-byte RAUT frame
```

The native protected wire frame is 74 bytes; the protected fallback is 78
bytes. Native and fallback paths unwrap authentication before entering the same
strict parser. Frames use little-endian numeric fields:

| Offset | Size | Field |
| ---: | ---: | --- |
| `0` | 1 | protocol version, exactly `2` |
| `1` | 1 | message kind |
| `2` | 1 | transition: `0` none, `1` start, `2` pause, `3` resume |
| `3` | 1 | origin: `0` unknown, `1` manual, `2` automatic |
| `4` | 1 | result |
| `5` | 1 | start mode: `0` off, `1` ask, `2` automatic |
| `6` | 1 | Auto-Pause, exactly `0` or `1` |
| `7` | 1 | alert mode: `0` sound+haptic, `1` haptic only, `2` visual only |
| `8` | 4 | non-zero device ride generation, `UInt32LE` |
| `12` | 4 | decision sequence, `UInt32LE` |
| `16` | 2 | normalized evidence mask, `UInt16LE` |
| `18` | 2 | non-zero detector profile version, `UInt16LE` |
| `20` | 16 | Watch session UUID in RFC 4122 byte order; all zero when no session exists |
| `36` | 4 | decision watermark or configuration generation, by kind |
| `40` | 4 | boot-local seconds when the transition candidate began |
| `44` | 4 | sender boot-local seconds when the frame was emitted |
| `48` | 2 | source-health mask: bit 0 wheel, bit 1 cadence, bit 2 GPS, bit 3 IMU |
| `50` | 1 | acknowledged kind for kind `2`; otherwise zero |
| `51` | 1 | reserved, exactly zero |

Kinds are `1=decision`, `2=acknowledgement`, `3=confirmation`,
`4=configuration`, `5=configurationAck`, `6=resynchronize`,
`7=promptResponse`, and `8=cancellation`. Decision, acknowledgement,
confirmation, prompt response, and cancellation require a non-zero decision
sequence. Acknowledgements set offset `50` to `1` for a decision or `7` for a
prompt response, preventing one retry stream from acknowledging the other.
Results are `0=none`,
`1=accepted`, `2=rejected`, `3=Watch unavailable`, `4=stale`, and `5=session
mismatch`. Unknown enums, invalid booleans, zero generations/profile versions,
non-zero reserved bytes, or a wrong frame length reject the whole frame.

### Decision and confirmation lifecycle

The ESP32 is the evidence authority but never treats a notification as proof
that HealthKit changed state:

1. It emits one automatic decision identified by device ID, ride generation,
   and decision sequence, retaining only that current unconfirmed decision.
2. iPhone deduplicates the identity and sends an acknowledgement after
   admission. Ask mode shows the same prompt on iPhone and the bike computer.
3. A response from either prompt surface uses kind `7` with the original
   identity and result `accepted` or `rejected`. The receiving peer ACKs that
   response before iPhone launches or dismisses the Watch flow. A device-side
   **Not Now** already recorded for the identity rejects a delayed iPhone
   acceptance, so rejection cannot be crossed by the launch handshake.
4. iPhone sends a later confirmation only after the authoritative Watch
   snapshot reports the requested state and automatic origin. A detected start
   is annotated with a durable Watch recovery record and HealthKit marker
   before it is confirmed.
5. If fresh evidence contradicts an admitted decision before confirmation, the
   device sends kind `8` with result `stale`. The phone stops the pending flow,
   but never ends or discards a workout that may already have started.

The device retries its current decision or prompt response at bounded
exponential intervals. A matching ACK stops transport retry but retains the
logical decision until confirmation. A matching rejection, a contradictory
manual/terminal state, or retry exhaustion clears it and applies detector
suppression. An automatic resume is accepted only for an automatically paused
matching Watch session; a manual pause cannot be crossed.

### Configuration and reconnect

Configuration uses offset `36` as an RFC 1982-style 32-bit serial generation.
Firmware normalizes and persists start mode, Auto-Pause, and alert mode in NVS,
then returns kind `5` with the stored values and generation. Stale generations
cannot replace newer settings. An authenticated newer edit made on the bike
computer is adopted by iPhone; an iPhone edit advances the same serial and is
then synchronized back to both the device and Watch.

After authentication or app relaunch, both peers exchange kind `6`. The device
reports its current ride generation and outstanding decision sequence at
offset `36`; the current lease holder reports its decision watermark and full
Watch session UUID. Replayed or out-of-order decision identities cannot control a
newer Watch session. Candidate evidence and raw IMU/location samples remain
RAM-only; configuration and confirmed origin metadata are the only durable
device automation state.

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
| `9` | Map street width | Absolute rendered width is `1...24` px. The wire value remains `width - 4` (`-3...20`) so older apps that send a boost remain compatible. |
| `10` | Map current-position marker scale | `1...5`; default is `2`, so the map position marker renders at twice its original size. The firmware shows a route-blue dot when no route is loaded and a route-blue arrow while navigating. Both shapes are rendered at their final display resolution. |
| `11` | Tap to switch screens | `0` disabled, `1` enabled. When enabled, a short tap cycles the device through the enabled main screens. Map drags and long presses are ignored by this shortcut. |
| `12` | Device brightness | Whole-number percent. Firmware clamps the signed value to `5...100`, saves the normalized value in NVS, and applies it from the display task. First boot defaults to `100`; the saved value is restored across reboot and display sleep/wake. |
| `13` | Enabled main screens mask | bit 0 Map, bit 1 Navigation, bit 2 Ride Stats, bit 3 Map + Navigation, bit 4 Battery Status. Invalid or empty masks fall back to all supported screens. Existing four-screen configurations enable Battery Status once during migration, after which it remains user-toggleable. |
| `14` | Default main screen | `0` Map, `1` Navigation, `2` Ride Stats, `3` Map + Navigation, `4` Battery Status. Invalid or disabled defaults prefer Map + Navigation, then the first enabled fallback screen. |
| `15` | Disconnected sleep timeout | seconds before deep sleep while not connected to the app: `60`, `120`, `300`, `600`; `0` disables automatic disconnected sleep. An unclaimed device waiting to be added applies a minimum 600-second registration grace period; `0` still disables automatic disconnected sleep. |
| `16` | Map + Navigation minimum polygon size | `0...50` |
| `17` | Map + Navigation detail level | `0` low, `1` medium, `2` high |
| `18` | Map + Navigation route line width | `2...48` |
| `19` | Map + Navigation zoom level | `0...5` |
| `20` | Map + Navigation feature visibility mask | feature bits and the extended-mask marker use the same meanings as ID `8`; navigation overlay bits remain global via ID `8` |
| `21` | Map + Navigation street width | Absolute rendered width is `1...24` px, encoded as `width - 4` (`-3...20`) for compatibility. |
| `22` | Map + Navigation current-position marker scale | `1...5` |
| `23` | Connected phone battery level | transient whole-number percentage `0...100`; iOS sends it after authentication and whenever the phone battery level changes. Firmware clears it on disconnect. |
| `24` | Connected phone charging state | transient `0` not charging, `1` charging; iOS sends it after authentication and whenever the public battery state changes. Firmware clears it on disconnect. |
| `25` | Map + Navigation bird's-eye view | `0` disabled, `1` enabled; defaults to enabled and is persisted as `navBirdEye`. The projection is effective whenever Map + Navigation is visible, including before a route starts. |
| `26` | Map + Navigation bird's-eye perspective | `0` Gentle, `1` Standard, `2` Strong, `3` Very Strong, `4` Maximum; defaults to Standard and is persisted as `navBirdTilt`. This changes the shared projection strength for the map, route, and position marker. At extreme zoom/viewport combinations, firmware eases the requested strength only as much as needed to stay within the four-block renderer budget. |
| `27` | Map street-label density | `0` off, `1` major roads, `2` balanced, `3` all roads; defaults to balanced |
| `28` | Map street-label language | `0` local, `1` preferred, `2` local + preferred; defaults to local + preferred |
| `29` | Map street-label size | `0` small (18 px), `1` standard (22 px), `2` large (26 px); defaults to small |
| `30` | Map street-label orientation | `0` follow roads, `1` keep upright; defaults to keep upright |
| `31` | Map + Navigation street-label density | Same values as ID `27` |
| `32` | Map + Navigation street-label language | Same values as ID `28` |
| `33` | Map + Navigation street-label size | Same values as ID `29` |
| `34` | Map + Navigation street-label orientation | Same values as ID `30` |
| `35` | Map + Navigation 3D buildings | `0` flat footprints, `1` LoD1 walls and roofs in the bird's-eye Map + Navigation view; defaults to enabled and is persisted as `nav3DBuild` |
| `36` | Automatic display off | `0` disabled, `1` enabled; defaults to enabled and is persisted as `autoDisplayOff`. When enabled, the connected display dims after 15 seconds and turns off after 45 seconds without meaningful activity, except for navigation, workout, transfer, or attention holds. |

In a dense scene, firmware reserves its bounded extrusion workspace from the
nearest eligible buildings outward, preserves global back-to-front drawing,
and renders overflow records as flat roofs. One oversized viewport therefore
does not flatten every otherwise-visible building.

The app presents label visibility as a separate switch from density. It keeps
the selected `1...3` density in the screen profile and sends density `0` while
that switch is off. Map defaults to labels on; Map + Navigation defaults to
labels off while retaining balanced density, local + preferred language, small
text, and keep-upright orientation for use if labels are enabled later.

The settings list and the device's tap/PWR-button cycle use this screen order:
Map + Navigation, Ride Stats, Map, Navigation, then Battery Status.

Setting ID `12` has no application-level acknowledgement or readback packet.
An acknowledged GATT write confirms transport delivery only, not persistence or
panel application. The app retains the normalized value locally and sends it
again after every authenticated reconnect. Brightness updates do not invalidate
or rerender the map.

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

Setting ID `25` is separately capability-gated and does not change the
`16...22` independent-profile range. The ordinary Map screen and Map +
Navigation with bird's-eye disabled remain flat. When bird's-eye is enabled,
Map + Navigation uses one projection snapshot before and during guidance for
vector features, route geometry, and the current-position marker so all three
layers stay aligned.

Fresh Map profiles default to high detail, zoom level `3`, a `4` px route line,
`4` px streets, and a `2x` position marker. Fresh Map + Navigation profiles
default to low detail, zoom level `3`, a `15` px route line, `4` px streets, a
`2x` position marker, and only Major Roads, Residential & Local Roads, and
Water, and Buildings visible. Existing customized profiles keep their saved values; profiles
that still exactly match the former recommendations migrate once.

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
connection. Firmware configures the AXP2101's hard power-off threshold to four
seconds; this remains independent of the short-press honk behavior.

Independently of hard power-off, connected firmware dims after 15 seconds and
turns the panel off after 45 seconds without meaningful activity when no
navigation is active. GPS and workout telemetry alone do not keep the panel
awake. A
changed maneuver instruction/icon, a closer maneuver-distance threshold,
route, screen/input event, connection/authentication event, ownership
comparison, active sound, or transfer wakes or holds it as appropriate. BLE
advertising/connection processing continues with the panel off, and wake
restores the saved brightness with one synchronized full-screen refresh.
Incoming BLE callbacks publish their latest state and notify the firmware's UI
owner task. The UI task applies those mailboxes and LVGL changes immediately;
callbacks do not mutate LVGL objects directly.
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
and device-originated route-request support. Version `6` advertises that the
client understands the dedicated Watch-workout telemetry contract. Version `7`
asks firmware to append an extended capability byte after the optional
PWR-button configuration:

```text
"CAPS" | Flags: UInt8 | ExtendedFlags: UInt8
"CAPS" | Flags: UInt8 | Enabled: UInt8 | SoundID: UInt8 | VolumePercent: UInt8 | ExtendedFlags: UInt8
```

Extended flag bit `0` reports support for the Map + Navigation bird's-eye
projection and setting ID `25`. iOS keeps the switch disabled and never sends
ID `25` when this bit is absent. Version `8` additionally requests bit `1`,
which reports support for the Gentle, Standard, and Strong perspective presets
and setting ID `26`. Version `9` additionally requests bit `2`, which reports
support for the Very Strong and Maximum values. iOS hides the perspective
picker when bit `1` is absent and limits it to the first three presets when bit
`2` is absent. Values `3` and `4` are clamped to Strong before being sent to
older perspective-capable firmware. Version `7` clients receive only bit `0`;
firmware appends the extended byte for versions `7...9`, while older clients
continue receiving the exact legacy five- or eight-byte response.

Receiving a `CAPS` request alone does not switch the firmware's
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

Flag bit `7` reports complete workout-telemetry support: the dedicated
characteristic, authenticated native and `WTLM` parsers, RAM-only state, and
Ride Stats presentation must all be available before firmware sets this bit.
iOS sends no workout health metrics when the bit is absent. A reconnect or a
later valid capability response that enables bit `7` triggers one full
core-plus-extended resynchronization.

Client version `10` switches the response envelope to the extensible `CAP2`
frame:

```text
"CAP2" | Schema: UInt8 | FeatureFlags: UInt32LE | TLVs...
TLV = Type: UInt8 | Length: UInt8 | Value: Length bytes
```

Schema `1` assigns feature bit `8` to street-label profiles, bit `9` to the
bird's-eye projection, bit `10` to its first three perspective presets, bit
`11` to the Very Strong and Maximum presets, bit `12` to OSM 3D buildings
and renderer target 3, bit `13` to the explicit invalid GPS-heading sentinel,
bit `14` to scoped Watch control, bit `15` to the complete RAUT v2
characteristic/fallback, persistence, and UI/control path, and bit `16` to the
session-scoped real-device browser-debug service. Bit `17` negotiates the
GPS-position quality-v1 tail used by ride detection. Bit `18` reports bounded
renderer diagnostics. Bit `19` reports
connected-display automatic inactivity control (setting ID `36`), and bit `20`
negotiates persistent, privacy-bounded ride diagnostics and the authenticated
device-log transfer mode. Bit `21` reports support for the optional detailed
one-Hz ride-automation trace. Bit `22` reports the application-confirmed
critical ride-delivery contract described above. Bit `23` reports the Watch GPS
motion-evidence frame and is advertised only with internal ride control. Client version `11` requests
bit `13`, version `12` requests
bit `14`, version `13` requests bit `15`, and version `14` requests bit `16`;
version `15` requests bit `17`. Version `10` remains a valid CAP2 client
without the newer features. Client version `16` requests bits `18` and `19`,
including the authenticated renderer-diagnostics contract and the already
released automatic-display setting. Version `18` requests bit `20`, version
`19` requests bit `21`, version `20` requests bit `22`, and version `21`
requests bit `23`.
Production builds keep bit `15` clear until the
ride-detection physical gates pass. Firmware sets bit `16` only in
`DEVICE_REMOTE_DEBUG=1` builds after the debug HTTP/input service initializes.
Firmware sets bit `18` only when `FIRMWARE_DIAGNOSTICS=1`; production builds
therefore expose neither the snapshot nor experimental profile control. GFX
firmware advertises bit `19` for client version `16` and newer; iOS enables the
toggle and sends ID `36` only after this bit is received, so legacy firmware
with the generic settings characteristic never receives an unsupported setting.
The bounded persistent recorder may advertise bit `20` in ordinary and
production profiles; it never enables USB serial diagnostics or the
remote-debug service.
Firmware advertises bit `21` only when the read-only ride-automation shadow
producer is compiled. Production firmware keeps it clear, and iOS downgrades
an otherwise detailed capture binding to standard correlation when it is absent.
Bits `0...7` retain their legacy meanings above. TLV type `1` carries the
persisted PWR honk configuration as
exactly three bytes (`Enabled`, `SoundID`, `VolumePercent`). Types are unique;
malformed, duplicate, or overrun TLVs invalidate the complete response. Unknown
well-formed types are skipped. Firmware sends legacy `CAPS` to clients below
version `10`, preserving the version `7...9` extended-byte contract, and current
clients accept either envelope.

Golden vectors:

```text
CAP2 schema 1, flags 0x00003fff, PWR enabled/sound 4/volume 80 (version 11):
43 41 50 32 01 ff 3f 00 00 01 03 01 04 50

CAP2 schema 1, flags 0x00007fff, PWR enabled/sound 4/volume 80 (version 12):
43 41 50 32 01 ff 7f 00 00 01 03 01 04 50

CAP2 schema 1, flags 0x0000ffff, PWR enabled/sound 4/volume 80 (version 13):
43 41 50 32 01 ff ff 00 00 01 03 01 04 50

CAP2 schema 1, flags 0, no TLVs:
43 41 50 32 01 00 00 00 00

Internal RAUT v2 build, CAP2 schema 1, only feature bit 15:
43 41 50 32 01 00 80 00 00

GPS quality v1, CAP2 schema 1, only feature bit 17:
43 41 50 32 01 00 00 02 00

Renderer diagnostics, CAP2 schema 1, only feature bit 18:
43 41 50 32 01 00 00 04 00

Automatic display off, CAP2 schema 1, only feature bit 19:
43 41 50 32 01 00 00 08 00

Persistent ride diagnostics, CAP2 schema 1, only feature bit 20:
43 41 50 32 01 00 00 10 00

Detailed ride diagnostics, CAP2 schema 1, only feature bit 21:
43 41 50 32 01 00 00 20 00

Application-confirmed ride delivery, CAP2 schema 1, only feature bit 22:
43 41 50 32 01 00 00 40 00

Watch GPS motion evidence, CAP2 schema 1, only feature bit 23:
43 41 50 32 01 00 00 80 00
```

Bit `14` (`0x00004000`) reports the complete scoped Watch-controller and
exclusive writer-lease contract below. Firmware keeps it clear if the durable
controller store does not boot cleanly. Merely compiling the lease state
machine is not sufficient to advertise support.

Bit `16` (`0x00010000`) reports the real-device browser-debug service. Firmware
keeps it clear outside dedicated `DEVICE_REMOTE_DEBUG=1` profiles and when the
debug frame/input service does not initialize.

Bit `18` (`0x00040000`) reports the complete bounded renderer-diagnostics
contract. It is independent of bit `16`: remote-debug diagnostic builds support
HTTP plus BLE, ordinary diagnostic builds support BLE only, and production
builds support neither.

## Renderer diagnostics and benchmark fixture

After authentication and CAP2 bit `18` negotiation, iOS can request the same
schema-1 snapshot used by the remote-debug HTTP runner:

```text
iOS -> ESP32: "RDMS"
ESP32 -> iOS: "RDMT" | JSON
ESP32 -> iOS: "RDMC" | TransferID: UInt8 | ChunkIndex: UInt8 |
              ChunkCount: UInt8 | JSON chunk
```

The direct form is used only when it fits the negotiated MTU. Otherwise the
JSON is split into at most 255 indexed chunks and reassembled to at most 32768
bytes by iOS. Requests are limited to one per second and notifications use the
existing authenticated navigation envelope. Missing authentication, missing
capability negotiation, malformed frames, duplicate/oversized chunks, and
production builds fail closed.

The snapshot is generated from one fixed-size state object: no per-render trace
is retained on the device. It includes build/boot identity, measurement-window
identity, active profile and immutable tuning values, internal RAM,
DMA-capable internal RAM, and PSRAM, bounded timing histograms, building
selection/reach and limiter counters,
render-job outcomes, UI/display/GPS gaps, prediction state, fixture-marker
freshness, and remote-debug overhead. It intentionally contains no route
coordinates, network credentials, or transfer token.
The DMA-crypto rejection and operation-failure fields are deltas from the
counter baseline captured at the start of the active measurement window; the
DMA object identifies that contract as `cryptoCountersScope: "window"`. The
separate authenticated device-status diagnostics retain their lifetime scope.

The checked-in benchmark replay marks every exact 1 Hz GPS sample with:

```text
"RBM1" | RouteFixtureSHA256: 32 bytes |
         SampleIndex: UInt16LE | SampleCount: UInt16LE | Loop: UInt32LE
```

The frame is exactly 44 bytes. `SampleCount` is non-zero and `SampleIndex` must
be smaller than it. iOS serializes each GPS write before its corresponding
marker. Firmware accepts a marker only when its hash matches the active
measurement window. This prevents an otherwise plausible GPS stream from being
attributed to the pinned fixture and lets a later checkpoint frame be tied to
the intended position sample.

For confirmation on an ordinary diagnostic build, iOS starts a session-scoped
measurement window with:

```text
"RBW1" | Schema: UInt8 (= 1) | Profile: UInt8 |
         Repeat: UInt16LE | RunNonce: UInt64LE |
         RouteFixtureSHA256: 32 bytes | RouteIDLength: UInt8 |
         RouteFixtureID: RouteIDLength UTF-8 bytes
```

Profile values are `0` flat, `1` current, `2` medium, and `3` high. `Repeat` and
`RunNonce` are non-zero. The route ID is 1–48 bytes and restricted to ASCII
letters, digits, `.`, `-`, `_`, and `:`; the complete frame is at most 97
bytes. Window requests are limited to one per second, copied into bounded
storage, and consumed on the UI task. One immediate `current` cleanup is allowed
only when the last accepted request selected a non-current profile, so a quick
stop cannot strand an experimental profile while repeated cleanup traffic
remains rate-limited. Firmware obtains the active map ID and canonical manifest
receipt itself rather than trusting values supplied by the phone, and labels
the route mode `ordinary-ble-1hz`.

Experimental profile selection is RAM-only and scoped to the authenticated BLE
session. A disconnect, authentication reset, remote-debug transition, or
session end clears the pending window and restores `current`; no NVS setting is
written. The iPhone requests snapshots every five seconds during ordinary
replay and exports at most 128 snapshots for offline validation. The complete
procedure and rejection gates are in
[Renderer building benchmark](renderer-benchmark.md).

IDs `27...34` are sent only after a valid `CAP2` response advertises bit `8`.
Older sessions therefore never receive label-only setting IDs. Missing NVS
values migrate to balanced density, local language, standard text, and Follow
roads independently for Map and Map + Navigation.

ID `35` is sent only after a valid `CAP2` response advertises bit `12`.
Firmware without that bit is never offered renderer target 3 and never receives
the new setting. The setting has no effect unless Buildings is visible, Map +
Navigation is using bird's-eye projection, and an FMB v4 block supplies
building records.

ID `36` is sent only after a valid `CAP2` response advertises bit `19`.
Firmware without that bit is never offered the Automatic Display Off toggle;
the setting remains app-local until a compatible connected display is
negotiated.

## Destination Picker

The idle Navigation screen mirrors up to three favorites from the companion
app. Recent searches are not sent or displayed. Labels are non-empty UTF-8
strings of at most 64 bytes, and an empty catalog is valid.

The picker fills the dedicated Navigation screen with large, transparent
destination rows and a small yellow star before each label. Map + Navigation
does not present the catalog: it always opens directly to its configured map,
with no bottom overlay while idle and the one-third maneuver strip only while
guidance is active.

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
iPhone-owner sessions receive the request normally. A scoped Watch ride
session does not support the device favorite picker, so firmware fails the tap
locally with `Open iPhone to start navigation` and emits no `DREQ`. If the
session role cannot be read safely, firmware applies the same fail-closed
behavior.
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

### Device workout start request

When Ride Stats has no active workout, an authenticated owner session shows an
enabled **Start Workout** button and notifies the iPhone app on `2A6E`:

```text
"WREQ"
```

The request is ownership-v2 protected on the navigation channel. Firmware
emits it only for a role it can read as owner. A scoped Watch session instead
shows disabled **Start on Apple Watch** guidance and emits no `WREQ`; an
unreadable or unavailable role fails closed with a disabled control. Watch
also treats an exact legacy `WREQ` as a harmless ignored owner notification so
a cached/older firmware behavior cannot tear down Watch navigation, while
malformed or unknown notification data still fails closed.

iOS accepts only the exact four-byte payload after the BLE session is authenticated, then
uses the same Watch-owned outdoor-cycling launch flow as the app's Start Workout
controls. Older apps safely ignore the unknown notification. `WREQ` remains the
manual button fallback when either peer does not advertise RAUT; detected ride
decisions never masquerade as `WREQ`.

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

Bulk map packs are transferred over Wi-Fi/HTTPS, not BLE. BLE is the control and
status channel used by the iOS app to ask the device to enter transfer mode and
to inspect the installed map state.

The authenticated `2A6E` framed command channel carries these control commands:

| Command | Direction | Payload | Meaning |
| --- | --- | --- | --- |
| `MTRN` | iOS -> ESP32 | `enter` | Enable short-lived map-transfer mode. |
| `MTRN` | iOS -> ESP32 | `exit` | Disable map-transfer mode. |
| `MSTS` | iOS -> ESP32 | empty | Request current map-transfer status. |
| `MSTC` | ESP32 -> iOS | Framed UTF-8 JSON chunk | Current map-transfer status notification. |
| `DTRN` | iOS -> ESP32 | `enter\|map` | Preferred atomic map-mode entry; publishes both map status and generic device-transfer status. |
| `DTRN` | iOS -> ESP32 | `enter\|firmware` | Enter firmware-update transfer mode. |
| `DTRN` | iOS -> ESP32 | `enter\|debug` | Enter opt-in real-device browser-debug mode when CAP2 bit `16` is present. |
| `DTRN` | iOS -> ESP32 | `enter\|debug\|lan1\|` plus bounded binary credentials | Enter browser-debug mode by trying a normal LAN first, with device-hotspot fallback. |
| `DTRN` | iOS -> ESP32 | `enter\|debug\|h1\|e` | Force the hotspot after authenticated LAN endpoint verification fails; `e` records `endpoint_unreachable`. |
| `DTRN` | iOS -> ESP32 | `enter\|diagnostics` | Enter the authenticated, read-only device-log transfer mode when CAP2 bit `20` is negotiated. |
| `DTRN` | iOS -> ESP32 | `enter\|diagnostics\|lan1\|` plus bounded binary credentials | Enter diagnostics mode by trying the configured trusted LAN first, with protected-hotspot fallback. |
| `DTRN` | iOS -> ESP32 | `enter\|diagnostics\|h1\|e` | Re-enter diagnostics on the protected hotspot after the iPhone confirms that the advertised LAN endpoint is unreachable. |
| `DTRN` | iOS -> ESP32 | `capture\|1\|<standard-or-detailed>\|<uuid>` | Bind the current random iPhone capture UUID and capture level; idempotent on reconnect. Detailed mode is sent only with CAP2 bit `21` and is rejected by firmware without the read-only ride-automation shadow producer. |
| `DTRN` | iOS -> ESP32 | `mark\|1\|<sequence>\|<code>` | Persist one predefined issue marker. Sequence is positive and strictly increasing for the bound capture; replayed or out-of-order markers are rejected. |
| `DTRN` | iOS -> ESP32 | `capture_end` | End the active detailed capture binding. |
| `DTRN` | iOS -> ESP32 | `tls\|prepare` | Generate and durably stage the next device-local TLS identity while no transfer is active. |
| `DTRN` | iOS -> ESP32 | `tls\|commit\|<sha256>` | Atomically select the staged identity only when the exact lowercase leaf-certificate SHA-256 matches. |
| `DTRN` | iOS -> ESP32 | `tls\|cancel` | Delete a staged identity without changing the active identity. |
| `DTRN` | iOS -> ESP32 | `exit` | Exit the active map, firmware, debug, or diagnostics transfer mode. |
| `DSTS` | iOS -> ESP32 | empty | Request generic device-transfer status and the current HTTPS credential/pin. |

The device preserves a detailed binding through short BLE gaps. If the last
confirmed workout lifecycle was active and workout telemetry remains stale for
five minutes, firmware ends detailed sampling conservatively because it can no
longer observe the phone-side ride-end transition. The independent four-hour
deadline remains the final fail-safe.

When the settings characteristic advertises acknowledged writes, iOS uses them
for transfer control and status requests. These commands establish or inspect a
session and must not depend on a later write-without-response readiness callback
to leave the shared command queue. Firmware exposing only
write-without-response remains supported through CoreBluetooth flow control.

For an accessory AP session (`baseUrl` host `192.168.4.1`), iOS clears any
failed saved configuration for the advertised `apSsid`, waits for the AP to
settle, applies one persistent background-transfer configuration, and verifies
the token-authenticated, certificate-pinned HTTPS status endpoint. Only transient NetworkExtension
errors receive one bounded retry. A failed or unreachable join removes the
configuration, exits transfer mode, and surfaces the exact error domain and
code; bulk upload never starts on an unverified network path.

Map stream app-build attestation remains fail closed. A transport-only app
update may resume an already downloaded stream only when its complete prior
identity tuple (bundle build, Git SHA, and component SHA-256) appears in the
reviewed predecessor allowlist. Matching only a build number or Git revision is
insufficient. Unsigned ZIP artifacts are preview-only and must be regenerated
as a signed stream before device installation.

When the full legacy `MSTS{...}` response fits the negotiated ATT MTU, firmware
continues to use it. Otherwise `MSTC` responses fit the minimum BLE notification
payload: ASCII `MSTC`, a one-byte transfer id, zero-based chunk index, chunk
count, and up to 13 JSON bytes (20 bytes total). The app reassembles chunks by
transfer id and accepts both forms.

The HTTPS credential is not part of the map-status payload. Current iOS clients
send `DTRNenter|map`, which applies map mode and publishes a fresh generic
device-transfer response in one application-level handshake. There is no
unsigned or legacy transfer fallback. iOS requires a new authenticated response
whose `mode` is `map`, whose `baseUrl` is HTTPS, whose `sessionToken` is
exactly 32 lowercase hexadecimal characters, whose `transferGeneration` is
nonzero, and whose `tls` and
`capabilities` objects advertise a valid certificate fingerprint,
`secureTransferV1`, `signedMapStreamV1`, and `legacyArchivePolicy: "disabled"`.
A status cached before the enter request is not sufficient. The app pins the
exact leaf certificate from that response and sends the token as
`X-BikeComputer-Transfer-Token` on every local HTTPS request.

Remote-debug entry has no legacy protocol fallback. The plain
`DTRNenter|debug` form starts the device hotspot directly. The compact
`DTRNenter|debug|h1|e` form starts it after endpoint verification fails and
persists that fallback reason. The LAN-first form
starts with ASCII `DTRNenter|debug|lan1|`, followed by one unsigned SSID length
byte, one unsigned password length byte, then the exact SSID and password bytes.
The SSID is 1-32 UTF-8 bytes; the password is empty for an open network or 8-63
UTF-8 bytes. The frame has no delimiters after the two lengths, so spaces and
`|` characters are preserved. It is accepted only through the existing
authenticated command channel. The iPhone stores the credentials in its
device-only Keychain; firmware consumes them for that session and does not
persist, publish, or log the password.

The firmware attempts station association for six seconds without blocking the
UI task. Failure starts `BikeComputer-Transfer` with a fresh per-session WPA2
password and reports a hotspot fallback.
`DSTS` reports `networkTransport` (`starting`, `connecting`, `lan`, or
`hotspot`), `networkSsid`, `hotspotFallback`, `hotspotFallbackReason`, and (only
for an active hotspot) `apPassphrase`; `baseUrl` remains empty until the
selected listener is ready. Stable fallback reasons are `ssid_unavailable`,
`authentication_failed`, `association_timeout`, and `endpoint_unreachable`.

`DSTS` also includes a top-level `storage` object. `storage.backend` is one of
`sdmmc`, `legacy_spi_migration`, `spi`, `ffat`, or `unavailable`, and
`storage.powerCycleRequired` is `true` only while a Waveshare card is mounted
through the HSPI migration compatibility path. The object is optional for
older firmware. iOS persists a warning per stable device identity when it sees
`legacy_spi_migration`; missing fields, FFat, an unavailable card, or another
device cannot clear that warning. It clears only after the same device reports
`backend: "sdmmc"` and `powerCycleRequired: false` on a later boot.

The normal LAN password is never returned. The app verifies a LAN result
against the token-authenticated, certificate-pinned `/device-debug/v1/info`
endpoint. If association succeeded
but the endpoint is unreachable, it exits that session over BLE and sends a
compact endpoint-fallback debug-enter form to force the hotspot while retaining
the reason in firmware status.

iOS requires authenticated navigation readiness, CAP2 bit `16`, and a fresh
`DSTS` response whose `mode` is exactly `debug`, whose `baseUrl` is present,
whose `sessionToken` is exactly 32 lowercase hexadecimal characters, and whose
secure TLS metadata validates. The
app joins the accessory AP when needed and opens the console only in an
ephemeral in-app `WKWebView`. The page URL is
`<baseUrl>/device-debug/` and never contains the token. After the exact page and
pinned certificate load, iOS injects the 32-character token directly into page
memory; API requests carry it only in the transfer-token header. Main-frame
navigation, redirects, and certificate changes are rejected. Debug, map,
firmware, and diagnostics modes are mutually exclusive.

The hotspot password is delivered only through authenticated BLE and is never
part of an HTTPS response or copied session diagnostics. Every transfer mode,
including trusted-LAN debug, uses TLS with an exact BLE-delivered leaf pin, so
nearby hotspot clients and LAN observers cannot read or alter the bearer token.

Firmware creates a device-local P-256 self-signed transfer identity on first
boot and stores its certificate/private key in a versioned dual-slot NVS
record. The active selector is one atomic NVS value. Once identity state exists,
invalid selector, certificate, key, fingerprint, or key-pair data fails closed;
firmware never silently replaces a previously pinnable identity. Rotation is
two phase through the `DTRNtls` commands above. `DSTS.pendingTls` exposes only
the staged version and fingerprint so the authenticated controller can verify
the exact candidate before commit. No private-key material crosses BLE or
appears in status/log output.

If the device rejects a connection before secure HTTP parsing, it retains a
non-secret `DSTS.lastError` classification. Stable codes distinguish TLS
context allocation, handshake allocation, handshake timeout, other handshake
failure, and pre-handshake setup failure. Its monotonic `sequence` lets the app
distinguish a newly observed failure from a retained error belonging to an
earlier transfer. The message contains only numeric ESP-TLS/mbedTLS results,
before/after internal, DMA, and PSRAM heap totals/largest blocks; it never
includes certificate or key bytes, the bearer token, the hotspot password,
request headers, or request payload. This status is intended to diagnose a
failed pinned-HTTPS session over the already authenticated BLE channel without
requiring a serial connection or weakening TLS.

### Device diagnostics transfer

When `DTRN enter|diagnostics` is accepted, the same session-scoped transfer
server uses a fresh WPA2 hotspot password (or the configured trusted LAN) and
the existing bearer token. The read-only API is:

| Method | Path | Meaning |
| --- | --- | --- |
| `GET` | `/device-diagnostics/v1/status` | Constant-size authenticated liveness and storage status; does not enumerate or hash chunks. |
| `GET` | `/device-diagnostics/v1/index` | Bounded list of closed firmware JSONL chunks, byte sizes, SHA-256 hashes, boot sequence, and recorder counters. |
| `GET` | `/device-diagnostics/v1/chunks/{boot}/{chunk}` | Download one immutable closed chunk; path components are strict unsigned integers. |
| `GET` | `/device-diagnostics/v1/active-tail` | Returns `404`; the initial contract does not expose an active mutable tail. |
| `POST` | `/device-diagnostics/v1/session/exit` | Revoke the transfer session after the response completes; request bodies are rejected. |

Every route requires the authenticated transfer token and an active
`diagnostics` mode. The device never accepts an arbitrary filesystem path or a
remote-delete request. Before enabling the HTTP session, the firmware writer
performs a fresh directory and write/flush/close/remove probe, drains all
earlier queue entries, and seals its current chunk; short, normal rides are
therefore included without exposing a mutable tail. The recorder root is stable
for the complete boot. When removable SD was mounted at boot, diagnostics uses
that mount without unmounting it beneath map/font readers. When the boot is
already using the bounded internal FFat fallback, diagnostics exports FFat and
does not switch to a newly inserted removable card while recorder or map file
handles may still be open; adopting removable storage requires a reboot.

The diagnostics-entry `DSTS.lastError` codes are stable and stage-specific:

| Code | Failed stage |
| --- | --- |
| `diagnostics_mount_failed` | Diagnostics storage was not mounted as a directory. |
| `diagnostics_card_missing` | A mounted removable backend no longer reported a card. |
| `diagnostics_writable_probe_failed` | The fresh write/flush/close/remove probe failed. |
| `diagnostics_flush_failed` | Flushing the sealed active chunk failed. |
| `diagnostics_close_failed` | Closing the sealed active chunk failed. |
| `diagnostics_seal_timeout` | The recorder did not drain to the requested cutoff before the bounded deadline. |
| `diagnostics_seal_failed` | Recorder initialization or another seal invariant failed. |

iOS treats a fresh rejection as authoritative during every handshake polling
iteration, surfaces the code immediately, and records entry failures even when
no HTTP session was opened. Chunk GET resolves one strict canonical path and
never re-hashes the complete index. Zero-byte closed files are ignored as empty
crash artifacts. A non-empty file that cannot be stated, bounded, opened, read,
or hashed makes the index fail closed with HTTP error code
`diagnostics_index_unreadable`; it is never silently omitted. A non-empty
checksum-verified chunk with one truncated final JSON record remains evidence:
iOS imports its original bytes, ignores only the incomplete tail while
validating records, and rejects any later non-empty chunk for the same boot.
iOS downloads one bounded chunk at a time, rejects oversized responses while
streaming, verifies length, SHA-256, JSONL schema/source, per-field types, and
sequence ordering within and across chunks, then atomically
retains it under its local diagnostics root. Repeating a download skips an
already-imported chunk with the same hash.
Creating the index starts a bounded transfer snapshot lease. Retention pruning
cannot delete indexed closed chunks while that authenticated session is active;
each non-exit request refreshes the lease and session exit releases it.

The browser API and binary RGB565 frame contract are documented in
[Remote device debugging](remote-device-debugging.md). BLE exit, browser exit,
authenticated BLE disconnect, the transfer inactivity timeout, and setup
failure all use the same
mode-aware teardown path so the token is revoked, synthetic input is cancelled,
the HTTP worker stops, and the session-scoped PSRAM snapshot is freed in that
order.

Status responses should include:

- `activeMapId`: map id from `/sdcard/VECTMAP/active-map.json`, if present.
- `activeSessionId`: durable content-derived session selected by
  `active-map.json`, when installed by transfer-capable firmware. This
  distinguishes regenerated packs that intentionally reuse a stable map ID.
- `activeManifestReceipt`: SHA-256 identity of the exact installed manifest;
  the app binds the following label-health fields to this receipt.
- `activeMapDisplayName`: optional, bounded UTF-8 display name read from the
  installed manifest. Invalid or missing presentation metadata is omitted and
  does not invalidate an otherwise usable map.
- `activeMapBoundsE7`: optional four-integer array in
  `[minLongitude, minLatitude, maxLongitude, maxLatitude]` order, with each
  coordinate scaled by `10^7`. Firmware normalizes legacy decimal `bounds`
  manifests to this representation. The app validates these bounds and uses
  them to generate a local preview; preview image bytes are never sent over
  BLE.
- `activeRendererFormat`: the installed renderer target format (`1` legacy,
  `2` FMB v3 + FMA1 street labels, `3` FMB v4 + FMA1 + OSM buildings).
- `labelProfileVersion`: `1` for the current target-2/3 label profile, otherwise
  `0`.
- `labelLanguages`: the bounded ordered BCP-47 language tags embedded in the
  active pack.
- `fontAssetHealthy`: `true` only when the target-2/3 FMA1 asset passed activation
  validation and the active renderer can open it. The app uses these fields to
  distinguish unsupported firmware, a legacy map that needs regeneration, and
  an unhealthy label asset.
- `enabled`: whether Wi-Fi/HTTPS upload mode is enabled.
- `firmwareVersion`, `firmwareBuild`, and `firmwareGitSha`: the exact running
  firmware identity. The git identity must be the full 40-character lowercase
  SHA from a clean source tree; dirty or unidentified builds fail closed and do
  not advertise protocol v2. Promoted stream artifacts name the approved values
  and iOS rejects device installation when any field differs.
- `protocols`: supported map-install protocol versions. Version `2` is present
  only when SD storage is initialized and at least one production stream
  verification key is compiled into firmware. Version `1` is never advertised.
- `streamFormatVersions`: accepted device-native stream versions when protocol
  v2 is available.
- `streamTrust`: exact verification capabilities compiled into the running
  profile, each encoded as `keyId=SHA256(X9.63 public key)`. Ordinary and
  production firmware advertise only the production registry. Opt-in
  `*_REMOTE_DEBUG` profiles additionally advertise the Bicino Dev public signer
  so development-signed streams can be tested on dedicated hardware; release
  workflows never build those profiles. iOS selects v2 only when the artifact's
  key identity matches one of these entries; a device with an older or
  rotated-out trust set rejects installation until firmware or the artifact is
  updated.
- `baseUrl`: temporary HTTPS base URL when transfer mode is enabled.
- `transferGeneration`: nonzero boot-local authorization generation. BLE
  disconnect, exit, or mode replacement increments it so in-flight requests
  from the old session fail authorization.
- `tls`: active `identityVersion` and exact lowercase DER leaf-certificate
  `certificateSha256` used by iOS for pinning.
- `pendingTls`: optional staged identity version/fingerprint during two-phase
  rotation.
- `capabilities`: `secureTransferV1`, `signedMapStreamV1`, and
  `legacyArchivePolicy`. Current map installation requires both booleans and
  the exact policy value `disabled`.
- `activation`: the latest activation `status`, monotonic boot-local
  `sequence`, `sessionId`, optional `mapId`, numbered `step`, total `steps`,
  integer `progress` percentage, and structured `error`, when present. Status
  is `idle`, `receiving`, `paused`, `finalizing`, `ready`, `activating`,
  `failed`, or `installed`. BLE uses a compact form
  that omits error messages and duplicate `lastError`; HTTPS retains the full
  diagnostic text.
- `lastError`: last installer/upload error code, when present. HTTPS also includes
  the diagnostic message.
- `activeError`: active-map metadata error code, when no active map is installed.
  HTTPS also includes the diagnostic message.

The ESP32 map installer validates staged packs before activation:

- manifest schema version must be `1`.
- `mapId` and session ids may contain only letters, numbers, `.`, `_`, and `-`.
- files must live under `VECTMAP/` and be `.fmb`/legacy `.fmp` blocks, or the
  exact target-2 asset path `VECTMAP/<mapId>/assets/street-labels.fma`.
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

When transfer mode is enabled, the ESP32 exposes a short-lived HTTPS service for
bulk upload:

| Method | Path | Meaning |
| --- | --- | --- |
| `GET` | `/map-transfer/status` | Read transfer status and active map metadata. |
| `PUT` | `/map-transfer/sessions/{sessionId}/install-stream` | Stream one signed v2 artifact directly into an inactive root, then start durable device-owned activation. |

Every former `pack.zip`, per-file, manifest, and explicit-activation route
returns `426 signed_stream_required`. Firmware also discards any pending
unsigned archive marker/staging directory found during boot recovery; it never
parses or activates that artifact.

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

All transfer requests use HTTP/1.1 inside the pinned TLS session, with a
five-second request-wide header
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
and emits `renderer_reload`. Authorization revoked before response completion
discards an unselected ready stream so it cannot activate under a later BLE
session.

An accepted activation returns HTTPS 202 with the boot-local activation
`sequence`. The app matches that acknowledgement to later HTTPS/BLE terminal
status so a cached same-session result cannot be mistaken for the new attempt.
If a manifest HEAD encounters an interrupted activation journal, firmware first
returns 503 and then performs exceptional recovery. The app permits a bounded
long wait only after that explicit recovery/busy response; ordinary transport
timeouts retain a short retry limit.

The HTTPS service is configured by firmware at boot but remains disabled until
BLE transfer control binds it to an authenticated owner session. BLE disconnect
synchronously clears the token, hotspot secret, binding, and request generation,
stops the listener, and schedules mode-specific cleanup.
