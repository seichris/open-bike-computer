# Nearby Open Wi-Fi Discovery Implementation Plan

## Status and baseline

This plan addresses [GitHub issue #101](https://github.com/seichris/open-bike-computer/issues/101).
It was authored from a freshly fetched `origin/main` at
`9ef7f09fce0e0d95e349e6ef9c54da137fcff286` on 2026-08-31. It is an
implementation contract, not a claim that the feature, BLE protocol, endpoint,
or physical validation already exists.

The requested placement is the iPhone app's **Settings > Developer Settings**
screen (`DeveloperSettingsView` in `SettingsView.swift`). It is not the
ESP32's existing **Device Settings** LVGL screen. The bike computer still owns
the RF scan and the temporary Wi-Fi connection; the iPhone is the authenticated
owner's control and presentation surface.

iOS does not provide a general-purpose nearby Wi-Fi scanning API. Apple's
[iOS Wi-Fi API overview](https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview)
describes `NEHotspotNetwork.fetchCurrent` as current-network information, not a
nearby scan. Therefore this plan does not add a Network Extension entitlement
or attempt to scan/join Wi-Fi from the iPhone. Scan results cross only the
existing authenticated BLE link, remain in memory while the Developer Settings
view is open, and are never uploaded or persisted.

## Outcome

Add a capability-gated **Nearby Open Wi-Fi** row to the iPhone Developer
Settings form. The view lets an authenticated owner:

1. explicitly request one bounded scan on the connected bike computer;
2. see nearby visible SSIDs, signal strength, security type, and whether each
   result is usable by this first release;
3. select a fresh true-open result and confirm **Connect Once** after an
   unencrypted-network warning;
4. see association, DHCP, captive-portal heuristic, and Internet reachability
   outcomes; and
5. cancel or disconnect, after which the bike computer turns Wi-Fi off unless
   another owner already holds the shared radio lease.

The ESP32 retains the raw SSID/BSSID/channel candidate only in RAM. The BLE
result contains a boot-local opaque network ID and a safe display SSID; BSSID,
channel, and raw identity bytes never leave the device. The iPhone sends that
opaque ID back for connection, so an identically named secured or newly
appeared access point cannot be selected implicitly.

The feature never auto-connects, never saves a network, never retries silently,
never follows or opens a captive-portal page, and never exposes the existing
map/firmware/debug/diagnostics transfer server on an untrusted WLAN.

## Current `main` behavior

### iPhone Developer Settings

`ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift` contains a
`DeveloperSettingsView` with map-server, map-library, workout, transfer,
diagnostics, device-status, and test-navigation sections. It already receives
`BLEManager` as an environment object and is the correct owner for an
experimental hardware-connectivity row. There is no nearby-network view model,
scan result model, or BLE command for this feature today.

The iPhone's existing CoreBluetooth path is deliberately centralized in
`BLEManager`. Authenticated control writes and reverse notifications share the
protected `2A6E` navigation characteristic, while the manager's queues classify
transfer/control traffic separately from replaceable GPS, route, and workout
telemetry. A new feature must use that transport rather than opening a second
CoreBluetooth writer or a direct Wi-Fi API.

### BLE protocol and capability state

The current generated BLE contract advertises a 32-bit `CAP2` feature mask; the
highest assigned feature is bit 22 and the current client version is 20.
Authenticated control commands such as `DTRN`/`DSTS` already use strict text
prefixes over protected `2A6E` frames. Device-originated status can be sent as
one protected notification or as a bounded chunk sequence.

There is no scan/connection command, nearby-Wi-Fi capability bit, or scan-result
chunk parser. Older iOS builds must continue to ignore the additive capability
and unknown notifications.

### ESP32 radio and power lifecycle

The Waveshare environments currently compile with `DISABLE_RADIO=1`.
`Power::begin()` disconnects Wi-Fi, selects `WIFI_OFF`, and stops the Wi-Fi
driver at startup. Deep sleep also stops Wi-Fi. This is the low-power baseline
that discovery must restore when no other owner needs the radio.

The HTTP device-transfer server currently controls the global `WiFi` singleton
directly:

1. it switches to station mode and attempts the configured preferred LAN;
2. it falls back to a WPA2 SoftAP when station association fails;
3. it starts the authenticated transfer HTTP server; and
4. it disconnects and selects `WIFI_OFF` when transfer ends.

There is no shared Wi-Fi ownership abstraction. A second independent caller
could stop or reconfigure Wi-Fi while a map, firmware, debug-log, or diagnostic
transfer is active. Shared ownership is therefore a prerequisite, not a later
cleanup.

### BLE and ride constraints

The BLE reliability baseline keeps navigation, GPS, workout telemetry, and
acknowledged control writes moving through one shared transport. ESP32-S3 Wi-Fi
and BLE share one 2.4 GHz radio. Running the scan on a worker avoids blocking
the Arduino/LVGL loop but does not by itself prove that the active ride remains
responsive.

The feature has no ESP32 LVGL page. BLE state publication may wake the existing
control/main task, but worker code must not create or mutate LVGL objects. The
two display families still require separate firmware and physical validation
because radio, power, and general runtime behavior are target-specific:

- `WAVESHARE_AMOLED_175`: 466 x 466 round display; and
- `WAVESHARE_AMOLED_206`: 410 x 502 rectangular display.

## Product contract

### Developer Settings entry and lifecycle

- Add a **Connectivity** or **Experimental Hardware** section to
  `DeveloperSettingsView` containing **Nearby Open Wi-Fi**.
- Keep the feature out of the ESP32 `deviceSettingsScr` screen and out of the
  normal consumer-facing Settings sections.
- Show an explanatory disabled row when the device is disconnected, not
  navigation-ready, or has not negotiated the new capability. Do not send a
  scan command until authenticated owner state and capability are both true.
- Entering `NearbyOpenWiFiView` is passive. The user must tap **Scan Nearby
  Networks**; there is no scan on app launch, Developer Settings appearance,
  boot, a timer, or a location/ride event.
- A **Rescan** action starts a new generation only after an explicit tap. Ignore
  repeated taps while one request is in flight.
- Warn that scanning uses the bike computer's shared 2.4 GHz radio and may
  briefly reduce Wi-Fi/BLE airtime. Keep **Cancel** available throughout.
- If a transfer owns the radio, show **Wi-Fi is in use for a device transfer**
  and leave the transfer untouched. The user can retry after it ends.
- Clear the iPhone result array, selected network, consent state, and all raw
  protocol buffers on view disappearance, BLE disconnect, authentication reset,
  capability downgrade, or a terminal stop event.
- Treat a result generation as stale after 30 seconds. A stale row must request
  a fresh scan instead of sending a connection command.

### Scan results and presentation

Each visible row shows:

- the device-supplied safe SSID display string;
- RSSI in dBm plus a four- or five-level signal description;
- a specific security label; and
- **Open**, **Not connectable**, or a busy/expired state.

The iPhone model is intentionally presentation-only:

```swift
struct NearbyOpenWiFiNetwork: Identifiable, Equatable, Sendable {
    let id: UInt32                 // boot-local device candidate ID
    let displaySSID: String        // bounded, already sanitized by device
    let rssiDbm: Int
    let security: SecurityClass
    let accessPointCount: UInt8
    let generation: UInt32
    let connectable: Bool
}
```

It must not contain or persist a BSSID, channel, raw SSID bytes, credentials,
or a stable network identifier. The device retains those values in a bounded
RAM candidate table keyed by `id` and `generation`.

On the device, treat an SSID as at most 32 opaque bytes until presentation. Do
not assume null-terminated UTF-8. Preserve valid printable UTF-8, replace
invalid/control sequences with a safe bounded representation, use **Unnamed
network** only when no displayable bytes remain, and escape text before it is
placed in JSON or UI text. Hidden/empty SSIDs are excluded because the owner
cannot meaningfully confirm their identity.

Group scan records by `(raw SSID bytes, security class)`, retain the strongest
BSSID/channel candidate, and show **Multiple access points** when a group has
more than one record. Never merge open and secured records that share an SSID.
Order connectable open groups first, then other groups by descending RSSI and a
deterministic display-name/security tie-breaker. Retain at most the first 24
groups and display **Showing 24 of N networks** when truncation occurred.

The iPhone does not display the BSSID or channel. It must not log the SSID or
network ID through `BLEManager.debugEvents`, os logs, analytics, crash
metadata, or copied debug text.

### Security classification

Map every authentication value explicitly. Unknown or future values must never
fall through to the open branch.

| Scan authentication | iPhone label | Connectable in v1 |
| --- | --- | --- |
| `WIFI_AUTH_OPEN` | **Open** | Yes, after confirmation |
| `WIFI_AUTH_OWE` | **Enhanced Open** | No |
| WEP | **Secured - WEP** | No |
| WPA/WPA2 personal and mixed modes | **Secured - WPA/WPA2** as applicable | No |
| WPA3 personal and transition modes | **Secured - WPA3** as applicable | No |
| WPA/WPA2 enterprise | **Secured - Enterprise** | No |
| WAPI or another recognized secured mode | A specific secured label | No |
| Unknown/future enum | **Unknown security** | No |

OWE has no password but is not unauthenticated `WIFI_AUTH_OPEN`. It remains
visible and disabled until its association support and consent copy have a
separate design and physical gate. Password entry, enterprise credentials,
WPS, hidden-network connection, and saved-network management are not part of
this release.

Before association, show **Portal status unknown**. Beacon security cannot
reveal whether a network requires web sign-in.

### Confirmation and one-shot connection

Selecting a fresh, true-open row presents a full-screen iPhone confirmation that
names the network and states:

> This is an unencrypted network. Other people may be able to observe or
> interfere with traffic, and a sign-in page may be required.

The only actions are **Cancel** and **Connect Once**. Every attempt, including a
retry of the same row, must show this confirmation again and create a new
operation ID. Tapping a row is never consent.

After **Connect Once**, iOS sends only the current `generation`, opaque network
ID, and fresh operation ID through the authenticated BLE command channel. The
device verifies that the candidate is still present, true open, unexpired, and
owned by the same generation before using its retained raw SSID/BSSID/channel.

The device then:

1. acquires the `TemporaryOpenNetwork` radio lease;
2. sets `WiFi.persistent(false)` and disables auto-reconnect;
3. selects station-only mode;
4. starts one BSSID/channel-bound association with a null passphrase;
5. waits for association and DHCP for an eight-second overall deadline; and
6. runs one bounded first-party reachability probe.

There is no silent retry, SSID-only fallback, SoftAP, mDNS, transfer server,
remote-debug listener, or other inbound service on the untrusted network. A
disconnect is terminal for that operation.

### Session lifetime and outcomes

The device connection exists only to perform the requested check and let the
owner inspect its result. It is not a general background network session.

- On **Internet available**, keep station mode only while
  `NearbyOpenWiFiView` is foregrounded and show **Disconnect**. Apply a
  five-minute absolute cap even if the view remains open.
- On **Connected, Internet not verified**, **Sign-in may be required**, or
  **No Internet detected**, publish the result and disconnect because firmware
  cannot safely use the link.
- Back, view disappearance, app background/display-off handling, explicit
  Disconnect, timeout, association failure, probe completion requiring teardown,
  BLE loss, and capability downgrade all invalidate the generation and begin
  idempotent cleanup.
- A later retry always returns through fresh scan/selection/confirmation rules.

Use a finite state model on both sides rather than scattered booleans:

```text
iOS:    Idle -> Scanning -> Results -> Confirming -> Connecting -> Probing
        -> Online | ConnectedUnverified | PortalSuspected | NoInternet
        any state -> Stopping -> Idle

ESP32:  Idle -> AcquiringScan -> Scanning -> Results
        Results -> AcquiringConnection -> Associating -> Probing
        any owned state -> Stopping -> Idle
```

At minimum, distinguish these user-visible outcomes:

| Internal outcome | iPhone copy | Next action |
| --- | --- | --- |
| No visible records | **No visible Wi-Fi networks found** | Scan again |
| Radio owned by transfer | **Wi-Fi is in use for a device transfer** | Retry later |
| Scan API failure/timeout | **Could not scan for Wi-Fi** | Scan again |
| Result expired | **Network list is out of date** | Scan again |
| Access point vanished/auth changed | **Could not connect to this network** | Scan again |
| Association or DHCP deadline | **Connection timed out** | Confirm again |
| Exact probe success | **Internet available** | Disconnect or wait for cap |
| Redirect/unexpected portal response | **Sign-in may be required** | Automatic disconnect |
| DNS/TCP/probe timeout | **No Internet detected** | Automatic disconnect |
| HTTP service failure/non-portal response | **Connected, Internet not verified** | Automatic disconnect |
| User/lifecycle cancellation | No stale failure banner | Return/leave |

Accessibility labels must include the SSID, RSSI description, security,
connectability, and current action. Signal bars and color are supplementary.

## Architecture

### 1. Shared Wi-Fi radio coordinator

Introduce `wifi_radio` as the only firmware code allowed to begin or end a
global Wi-Fi lifecycle. The initial owners are:

```cpp
enum class Owner {
    None,
    DeviceTransfer,
    DiscoveryScan,
    TemporaryOpenNetwork,
};
```

`tryAcquire(owner)` returns a generation-scoped lease with a monotonically
increasing token. A release succeeds only when owner and token still match, so
a late worker completion cannot turn off a newer owner.

Ownership is non-preemptive:

| Current owner | Requested owner | Result |
| --- | --- | --- |
| None | Any valid owner | Grant |
| DeviceTransfer | Discovery/temporary connection | Reject; transfer continues |
| Discovery/temporary connection | DeviceTransfer | Reject with `wifi_busy` |
| Discovery scan | Temporary connection | Stop/delete scan records, then transfer lease |
| Any owner | Same owner with stale token | Reject as stale |

Refactor `HttpTransferServer` to acquire `DeviceTransfer` before its first
`WiFi` mutation and release it only after server, station, and AP cleanup. A
rejected transfer publishes the existing generic status with stable
`lastError.code = "wifi_busy"`; the iPhone can explain that the Developer
Settings session must end before transfer can start.

The coordinator's last-owner cleanup must:

1. cancel/delete scan state;
2. stop owner-specific listeners before disconnecting;
3. disconnect station and SoftAP state using the pinned SDK's credential-erasing
   path;
4. select `WIFI_OFF` and stop the driver when no owner remains; and
5. release the matching power-management lock.

Do not snapshot/replay arbitrary `WiFi.getMode()` values. A failed discovery
acquisition leaves the transfer owner untouched; release from the only owner
returns to the measured radio-off baseline.

### 2. Capability-gated authenticated BLE contract

Add `nearby_open_wifi` as capability bit 23 with minimum client version 21 in
`protocol/ride-ble-contract-v1.json`, regenerate the checked-in Swift and C++
constants, and expose `supportsNearbyOpenWiFi` from `BLEManager`. Clear it on
disconnect, authentication reset, malformed capability response, or downgrade.
The Developer Settings row remains disabled until the bit and navigation-ready
state are both true. Older clients ignore the bit; older firmware never receives
new commands.

Use the existing authenticated `2A6E` command/notification route. Do not add a
new characteristic, a second CoreBluetooth writer, or an unauthenticated scan
path. The owner role is required; the Apple Watch role has no Developer
Settings/control authority and cannot start discovery.

Define a strict versioned command prefix, for example `WFTR`:

```text
WFTR|scan|<operationId>
WFTR|cancel|<operationId>
WFTR|connect|<operationId>|<generation>|<networkId>
WFTR|disconnect|<operationId>
```

`operationId`, `generation`, and `networkId` use fixed-width lowercase hex or
strict unsigned decimal fields with maximum lengths. The parser rejects empty,
extra, overflowed, or out-of-order fields. Commands carry no SSID, BSSID,
channel, credential, URL, or user text. The protected session sequence already
provides transport authentication; the operation ID makes retries and late
responses idempotent at the logical-command layer.

Define reverse notifications with a versioned `WFST` status envelope and
`WFSC` result chunks:

```text
WFST { version, operationId, generation, state, discoveredCount,
       shownCount, truncated, errorCode, resultTransferId }
WFSC { version, resultTransferId, generation, chunkIndex, chunkCount,
       bounded UTF-8 JSON bytes }
```

The result JSON contains only `networkId`, safe `displaySSID`, RSSI, security
class, access-point multiplicity, and connectability. It never contains BSSID,
channel, raw SSID bytes, credentials, probe body, redirect URL, or location.
Use a bounded chunk payload (128 bytes is safe at the minimum supported
protected ATT payload), a maximum result size/count, and reject duplicate,
missing, out-of-order, stale, or over-limit chunks. `WFST` acknowledges each
logical command with the same operation ID and terminal state. If iOS does not
receive an acknowledgement, it may retry one idempotent command with the same
operation ID; it must never create a new connection attempt without a new
confirmation and operation ID.

Add golden vectors and loopback tests for command parsing, authenticated frame
routing, chunk reassembly, result generation, truncation, malformed JSON,
missing chunks, stale operations, and capability gating. Update
`docs/ble-protocol.md` with the normative contract and compatibility behavior.

### 3. Headless ESP32 discovery controller

Add a `wifi_discovery` controller that exposes intent, snapshot, and lifecycle
operations to BLE/control code, not Arduino calls to Swift-facing code:

```cpp
void requestScan(uint32_t operationId);
void requestConnect(uint32_t operationId, uint32_t generation,
                    uint32_t networkId);
void requestCancel(uint32_t operationId);
void requestDisconnect(uint32_t operationId);
void process();
```

Every scan, connect, cancel, disconnect, BLE-loss, and capability-reset event
increments or invalidates a generation. Worker completions carry both
generation and lease token; stale completions are discarded without changing
radio state or emitting a terminal success.

Run scan, association, DNS, TCP, and response parsing on a bounded low-priority
worker. Publish immutable snapshots for the BLE notification pump through a
mutex/queue. The existing main/control task can use a `Wifi` wake reason to
flush notifications, but no worker path may touch LVGL or block the BLE host
task.

### 4. Bounded scan policy

Use asynchronous active scanning through the pinned Arduino-ESP32/ESP-IDF API
with explicit limits:

- visible networks only;
- all locally allowed 2.4 GHz channels;
- one pass per request;
- initial maximum active dwell of 120 ms per channel;
- no background repeat; and
- a bounded overall scan deadline including driver overhead.

The dwell is a starting value from the ESP-IDF active-scan range, not proof of
BLE coexistence. Lower it or select a passive policy only from measured results;
do not raise it without rerunning the active-ride matrix.

When `scanComplete()` finishes, copy only normalized records and the strongest
candidate metadata into the bounded RAM table, call `scanDelete()`, publish
the chunked result, release `DiscoveryScan`, and return the radio to off. Apply
the same deletion/release path on timeout, cancellation, BLE loss, result expiry,
and screen exit. The result list may remain on the iPhone while the device radio
is off.

Generate a nonzero boot-local `networkId` for each retained group. Do not use a
hash of SSID/BSSID as an identifier, because that would create cross-session
linkability. The ID is useless after its generation expires and is never logged.

### 5. Temporary connection and cleanup

After a valid authenticated `WFTR connect` command, acquire
`TemporaryOpenNetwork` and configure Wi-Fi in this order:

1. disable persistence and auto-reconnect;
2. select station-only mode;
3. start one null-passphrase connection bound to the retained raw SSID,
   channel, and BSSID;
4. wait for association and DHCP until the eight-second deadline while checking
   cancellation/generation; and
5. run the reachability probe once.

Cleanup is idempotent and safe before, during, or after every step. It must
erase the candidate table and selected bytes, release the exact lease, clear
the operation result, and prevent late callbacks from affecting a newer scan or
owner. Use the pinned SDK's station-configuration erase API and verify that the
temporary network is absent from Wi-Fi NVS after success, failure, and cancel.

Before physical testing, audit all listeners compiled into firmware and assert
that the temporary-open owner starts none of them. The transfer server must
remain stopped for the entire session.

### 6. First-party reachability probe

Add a minimal first-party Cloudflare Worker under
`map-platform/connectivity-probe/`. Do not use an undocumented Google, Apple,
Microsoft, or operating-system URL.

The endpoint contract is:

```http
GET /generate_204 HTTP/1.1
Host: <dedicated connectivity hostname>

HTTP/1.1 204 No Content
Cache-Control: no-store
X-Bicino-Connectivity: 1
```

Worker requirements:

- accept only `GET /generate_204` with no query string;
- return exactly status 204, an empty body, `Cache-Control: no-store`, and the
  stable marker header;
- reject every other method/path without reflecting request data;
- have no KV, D1, R2, Durable Object, Analytics Engine, service, or secret
  bindings;
- disable Worker application observability and do not add Logpush for the
  hostname;
- never read or store SSID, BSSID, device ID, cookies, authorization, body, or
  query values; and
- document that Cloudflare still processes normal edge connection metadata such
  as source IP and decide whether the product privacy notice needs an update.

Use separate staging and production Worker names and dedicated custom-domain
hostnames, initially proposed as `connectivity-staging.8o.vc` and
`connectivity.8o.vc`. Plain HTTP is intentional for interception detection and
carries no secret or user data. Preserve HTTPS enforcement for every existing
host. If a zone-wide HTTPS/HSTS policy cannot isolate this HTTP endpoint without
weakening existing hosts, use a separate dedicated zone/domain instead of
disabling protection for `8o.vc`.

Firmware uses a small bounded HTTP/1.1 parser over `WiFiClient`:

- resolve only the compiled first-party hostname;
- send no query, cookie, user/device/network identifier, or firmware header;
- do not follow redirects or fetch a redirect target;
- cap status/header bytes, header count, and unexpected body bytes; and
- apply per-stage and five-second overall DNS/TCP/read deadlines.

Classify conservatively:

| Observed response | Classification |
| --- | --- |
| Exact 204, marker present, empty body | Internet available |
| 2xx with body, 3xx, portal-like HTML, wrong/missing marker | Sign-in may be required |
| DNS/TCP/read timeout or no response | No Internet detected |
| HTTP 5xx or syntactically valid non-portal response that cannot prove success | Connected, Internet not verified |
| Malformed/oversized response | Sign-in may be required, then disconnect |

The result is a heuristic, not definitive portal proof. Do not render response
content, expose a redirect URL, submit forms, or use DHCP option 114 as a
requirement for v1. RFC 8910/8908 support can be a future additive signal.

Relevant references are the [Arduino-ESP32 Wi-Fi API](https://docs.espressif.com/projects/arduino-esp32/en/latest/api/wifi.html),
[ESP-IDF Wi-Fi API](https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-reference/wifi/esp_wifi.html),
[ESP32-S3 RF coexistence guidance](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-guides/coexist.html),
[ESP32-S3 Wi-Fi security](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-guides/wifi-security.html),
[RFC 8908](https://www.rfc-editor.org/rfc/rfc8908.html),
[RFC 8910](https://www.rfc-editor.org/rfc/rfc8910.html),
[Cloudflare Worker Custom Domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/),
and [Cloudflare Always Use HTTPS](https://developers.cloudflare.com/ssl/edge-certificates/additional-options/always-use-https/).

### 7. iPhone Developer Settings flow

Add a SwiftUI `NearbyOpenWiFiView` and a pure/testable session model. Keep
CoreBluetooth ownership in `BLEManager`; the new model consumes a narrow
nearby-Wi-Fi event stream and sends commands through the existing prioritized
write queue.

The view should contain:

- a connection/capability summary;
- **Scan Nearby Networks** / **Rescan**;
- a bounded list of rows with SSID, security, RSSI, and action state;
- a stale-result/truncation notice;
- confirmation and outcome sheets that block rows underneath; and
- **Cancel**, **Back**, and **Disconnect** actions wherever the device is busy.

On `onDisappear`, `scenePhase` background, BLE disconnect, and auth/capability
reset, cancel the operation and clear all session data. Do not write results to
`UserDefaults`, Keychain, Core Data, files, ride diagnostics, or shared map
state. Do not import `NetworkExtension` merely to obtain a scan.

The Developer Settings link must not be a shortcut to the existing map,
firmware, debug, or diagnostics transfer flows. It has a separate operation
generation and must report a device-side `wifi_busy`/terminal outcome without
reusing transfer credentials or opening a second network path.

## Privacy and security invariants

These are hard requirements:

- Only an authenticated owner may request a scan or connection. Watch and
  unauthenticated clients cannot use the command.
- Scan results may cross authenticated BLE to the current Developer Settings
  view, but are never persisted, uploaded, or sent to analytics/cloud storage.
- The iPhone receives safe display SSID text and an opaque boot-local ID only;
  BSSID, channel, raw SSID bytes, credentials, and portal data remain device
  RAM-only.
- No discovery/session network identity appears in Preferences, Wi-Fi NVS, SD,
  ride diagnostics, crash metadata, BLE logs, serial logs, analytics, or the
  reachability request. Confirm pinned SDK log levels do not emit it indirectly.
- No boot-time, periodic, background, location-triggered, or ride-triggered
  scan.
- No auto-connect, auto-reconnect, saved open network, remembered consent,
  silent retry, or SSID-only fallback.
- No connection to OWE, secured, hidden, or unknown-security results in v1.
- No Wi-Fi Network Extension entitlement, iPhone native scan, iPhone native
  join, or iPhone upload of the discovered list.
- No SoftAP, mDNS, transfer HTTP server, remote-debug listener, portal browser,
  redirect following, HTML rendering, form submission, arbitrary URL handling,
  or DNS rebinding to a second host on the temporary network.
- No temporary connection remains after the Developer Settings view/lifecycle
  ends or the absolute cap expires.
- Cleanup is generation- and lease-guarded, idempotent, and cannot stop another
  Wi-Fi owner.

Per-session station MAC randomization is a separate hardening item. Do not
change the ESP32 MAC silently; its interaction with BLE coexistence, transfer
configuration, and access-point compatibility needs its own design and gate.

## Expected code and documentation changes

Exact names may change during implementation, but the ownership boundaries
should remain recognizable.

### iOS app

- Update `ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift` to add
  the row inside `DeveloperSettingsView`.
- Add `NearbyOpenWiFiView.swift` and a pure session/state model or coordinator
  under the existing Views/Managers/Utilities conventions.
- Update `ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift` with
  capability state, strict command builders, protected `WFST`/`WFSC` parsing,
  operation-generation reset, and a narrow nearby-Wi-Fi event surface.
- Add pure Swift protocol/model tests plus Developer Settings UI coverage for
  capability gating, stale results, confirmation, cancellation, disconnect,
  chunk loss, and no persistence.
- Do not add a Wi-Fi entitlement or a second CoreBluetooth transport.

### BLE contract and firmware

- Add `nearby_open_wifi` bit 23/minimum client version 21 to
  `protocol/ride-ble-contract-v1.json`; regenerate the checked-in Swift/C++
  contract files and run the generator drift check.
- Update `docs/ble-protocol.md` with `WFTR`, `WFST`, and `WFSC` semantics,
  authentication, bounds, operation idempotency, chunking, and compatibility.
- Add `esp32/lib/wifi_radio/wifi_radio.hpp/.cpp` for lease ownership,
  restoration, and power-lock integration.
- Add `esp32/lib/wifi_discovery/wifi_discovery.hpp/.cpp` plus pure policy,
  normalization, authentication-mapping, deadline, and HTTP-response helpers.
- Update `esp32/lib/ble_navigation/ble_navigation.cpp/.hpp` to dispatch
  authenticated `WFTR` commands and pump bounded `WFST`/`WFSC` notifications.
- Update `esp32/lib/device_transfer/device_transfer_http.hpp/.cpp` to use the
  shared lease and return `wifi_busy` without changing transfer auth/fallback.
- Update `esp32/lib/power_management/power_management.hpp/.cpp` with a
  dedicated Wi-Fi lock domain and `esp32/src/main.cpp` with controller polling.
- Inspect `esp32/platformio.ini`/generated SDK settings and change coexistence
  or task placement only when measurements require it.
- Do not modify `esp32/lib/gui/src/deviceSettingsScr.cpp`,
  `globalGuiDef.h`, or `lvglSetup.*` for this feature.

### Reachability service

- Add standalone `map-platform/connectivity-probe/` Worker source, pinned
  dependencies, Wrangler staging/production environments, unit tests, and
  README/runbook.
- Extend `.github/workflows/map-platform-ci.yml` with Worker typecheck/tests and
  both-environment dry-run validation.
- Add deployment checks for the exact plain-HTTP contract and existing-host
  HTTPS behavior.
- Update the product privacy documentation if edge source-IP processing needs
  explicit disclosure.

### Host test suites

Add focused suites following repository conventions:

- `test_wifi_radio_policy.cpp`;
- `test_wifi_discovery_policy.cpp`;
- `test_wifi_connectivity_probe.cpp`;
- BLE nearby-Wi-Fi codec/chunk golden-vector coverage;
- transfer/radio mutual-exclusion regression coverage; and
- Swift nearby-Wi-Fi model, BLE parser, and Developer Settings UI tests.

## Implementation sequence

### Phase 0: freeze cross-platform contracts

1. Reconfirm the Developer Settings placement and document that the ESP32 is
   the scanner because iOS has no general-purpose scan API.
2. Capture generated Wi-Fi/BLE coexistence configuration, firmware size,
   radio-off current, BLE counters, and iPhone transport/UI baselines for both
   hardware families.
3. Inventory all firmware `WiFi` mutations/listeners and all BLE command/status
   dispatch points.
4. Finalize capability bit/version, `WFTR` fields, `WFST`/`WFSC` bounds,
   operation idempotency, security enum mapping, and timeout constants.
5. Stage the probe hostname policy and prove plain HTTP can be isolated without
   weakening existing HTTPS/HSTS behavior.

Exit gate: no unresolved implementation-changing decision remains in the
Developer Settings UX, authenticated BLE contract, radio ownership, probe
contract, or privacy review.

### Phase 1: radio ownership first

1. Implement pure owner/token transitions and exhaustive stale-release tests.
2. Integrate `HttpTransferServer` with `DeviceTransfer` leases.
3. Preserve preferred-LAN, SoftAP fallback, authentication, and transfer status
   behavior, adding only stable `wifi_busy` rejection.
4. Add Wi-Fi power-lock accounting and assert `WIFI_OFF` after the last owner.

Exit gate: existing transfer host/device regressions pass and concurrent owners
cannot mutate the radio.

### Phase 2: authenticated BLE contract

1. Add the generated capability bit and iOS capability gating.
2. Implement strict `WFTR` command parsing/building and protected routing.
3. Implement bounded `WFST`/`WFSC` notifications, Swift reassembly, golden
   vectors, retries, and generation/operation validation.
4. Prove old clients/firmware ignore the additive feature safely.

Exit gate: loopback and host tests prove authenticated, bounded, idempotent
command/status delivery without starving replaceable ride telemetry.

### Phase 3: headless scan domain

1. Implement asynchronous scan/cancel/deadline handling on the ESP32 worker.
2. Add safe SSID presentation, complete auth mapping, grouping, open-first
   ordering, 24-result cap, boot-local IDs, and expiry.
3. Publish snapshots/chunks and prove scan deletion, lease release, and radio
   restoration on every completion/cancel/error/BLE-loss path.

Exit gate: C++ policy tests pass and a serial-only harness can scan without
logging network identity or blocking the BLE host task.

### Phase 4: iPhone Developer Settings UI

1. Add the capability-gated row inside `DeveloperSettingsView` and the new
   `NearbyOpenWiFiView`.
2. Render scan, busy, empty, truncation, stale, secured, and unknown-security
   states from the BLE snapshot model.
3. Add confirmation, cancellation, Back, background/disconnect cleanup,
   accessibility labels, and operation-generation handling.
4. Verify rows never connect directly and no view lifecycle path retains result
   data.

Exit gate: Swift model/UI tests cover the complete owner-visible flow while
the existing map/firmware/debug/diagnostics settings remain unchanged.

### Phase 5: one-shot connection and probe

1. Implement generation/ID-checked BSSID/channel-bound open association.
2. Add idempotent teardown, eight-second association/DHCP deadline, five-minute
   successful-session cap, and no-retry behavior.
3. Implement/fuzz the bounded HTTP parser and classification table.
4. Build/test/dry-run the no-storage Worker, deploy staging, and validate all
   BLE terminal outcomes against controlled responses.

Exit gate: staging proves success, captive, no-uplink, malformed, slow,
oversized, and service-failure outcomes without persistent state or an inbound
firmware service.

### Phase 6: coexistence, power, and release validation

1. Run active-ride BLE/navigation/workout traffic while repeatedly scanning and
   connecting from iPhone Developer Settings.
2. Tune dwell/deadline/task policy only from measurements, preserving the
   current BLE watchdogs, queue priorities, and backpressure.
3. Run power/teardown/cold-boot matrices on both physical board families.
4. Deploy and validate the production probe contract.
5. Complete exact-SHA production firmware builds and physical gates before
   enabling the capability in a release.

## Verification plan

### Pure host tests

Cover at least:

- every pinned SDK authentication enum plus an unknown value;
- OWE, secured, hidden, and unknown results remaining non-connectable;
- raw-byte identity, invalid UTF-8, controls, maximum SSID length, safe display
  output, duplicate groups, open/secured same-name separation, strongest
  candidate, deterministic order, multiplicity, and 24-result truncation;
- RSSI boundaries and accessible signal descriptions;
- capability absent/present/downgraded and Developer Settings row gating;
- strict command fields, protected routing, operation retry idempotency,
  generation expiry, stale selection, and BLE disconnect reset;
- chunk reassembly with reordering, loss, duplicates, oversized data, malformed
  JSON, wrong generation, and wrong transfer ID;
- radio owner transitions, busy rejection, stale release, double cleanup, and
  scan-to-connection ownership transfer;
- cancellation during scan, association, DNS, TCP, headers, body, and display;
- no automatic retry/reconnect transition;
- exact 204 success, wrong marker, redirect, HTML, 2xx body, 5xx, timeout,
  malformed response, and header/body bounds; and
- Worker method/path/query rejection, exact headers/status/body, and no
  bindings/storage/observability.

Use fake clock, scan adapter, Wi-Fi adapter, lease, BLE byte stream, and Swift
transport doubles so late callbacks and timeout paths are deterministic.

### iPhone Developer Settings UI checks

- Verify the row appears only in the iPhone `Developer Settings` form and never
  in ESP32 Device Settings or consumer-facing Settings.
- Verify disconnected/not-ready/no-capability states cannot send commands.
- Verify Scan/Rescan is explicit, one-generation-at-a-time, and cancellable.
- Verify safe SSID rendering, security badges, signal accessibility, stale and
  truncation copy, and both connectable/non-connectable row actions.
- Verify each Connect Once confirmation creates a new operation ID and that
  Back/background/disconnect clears results and pending consent.
- Verify no UserDefaults, Keychain, file, analytics, debug-event, or BLE-log
  write contains scan history or network identity.

### Static and privacy checks

- Search new firmware/iOS/Worker code for SSID/BSSID/channel persistence,
  logging, BLE serialization outside the intended safe result field, and
  request-derived probe headers.
- Confirm pinned Wi-Fi/SDK release logging does not emit raw network identity.
- Compare Wi-Fi NVS before/after scan, connection, failure, and cancellation;
  cold boot and prove no remembered station or retry.
- Assert temporary connection cannot start transfer, SoftAP, mDNS, debug, or
  diagnostics listeners.
- Assert no third-party connectivity hostname and no iOS Wi-Fi entitlement.
- Check Wrangler configuration for no storage/service/secret bindings and
  disabled application observability.
- Verify existing hostname HTTP-to-HTTPS behavior is unchanged after probe
  deployment.

### Firmware builds

From `esp32/`, use the repository build wrapper and record each result:

```sh
python3 tools/build_firmware.py WAVESHARE_AMOLED_175
python3 tools/build_firmware.py WAVESHARE_AMOLED_175_PRODUCTION
python3 tools/build_firmware.py WAVESHARE_AMOLED_206
python3 tools/build_firmware.py WAVESHARE_AMOLED_206_PRODUCTION
```

Record exact source SHA, toolchain identity, firmware size/heap deltas, and
coexistence configuration. Automatic CI for 1.75-inch environments does not
substitute for explicit 2.06-inch builds or physical evidence.

This plan does not authorize flashing. Before each physical write, re-identify
the attached device by stable serial and obtain fresh confirmation naming the
artifact, SHA, target environment, and device.

### Probe deployment checks

For staging and production, require the exact eventual plain-HTTP contract:

```sh
curl --http1.1 --max-time 5 --dump-header - \
  --output /tmp/bicino-connectivity-body \
  http://<connectivity-host>/generate_204
test ! -s /tmp/bicino-connectivity-body
```

Assert status 204, marker, `no-store`, empty body, no redirect, and rejection
of wrong methods, paths, and query strings. Check ordinary HTTPS health too,
but never substitute an HTTPS success for the required HTTP behavior.

### Controlled network matrix

Use controlled access points or a documented lab setup, not unknown public
networks.

| Network case | Expected BLE/iPhone behavior |
| --- | --- |
| Open with working Internet | List Open; confirm; Internet available |
| Open with HTTP captive portal | List Open; confirm; sign-in may be required; disconnect |
| Open with DNS only/no uplink | List Open; confirm; no Internet detected; disconnect |
| Open AP disappears after scan | Bounded connect failure; no same-name fallback |
| WPA2 personal | Secured; no connection action |
| WPA3/transition | Specific secured label; no connection action |
| OWE | Enhanced Open; no connection action |
| Enterprise/legacy/unknown auth | Specific/unknown label; no connection action |
| Hidden SSID | Excluded |
| Same SSID, open and secured | Separate rows; only exact open ID selectable |
| Multiple same-class BSSIDs | One group, strongest candidate, multiplicity shown |
| More than 24 groups | Open-first bounded list plus accurate truncation |
| Malformed/oversized portal response | Bounded classification and disconnect |
| Device transfer already active | Developer Settings busy state; transfer uninterrupted |
| Transfer requested during scan/session | `wifi_busy`; discovery/session uninterrupted |

Compare presence, auth class, channel, and RSSI tolerance against an
independent scanner in the controlled environment without storing its network
identity in test artifacts.

### Active-ride BLE coexistence matrix

On each supported physical board, run normal iPhone navigation, route geometry,
GPS, navigation instructions, workout telemetry, and the Developer Settings
flow over the same authenticated BLE connection. During the same connection:

1. perform at least 25 explicit enter/scan/cancel/back or rescan cycles;
2. perform at least 10 confirmed open association/probe/disconnect cycles over
   success and failure cases;
3. cancel once during scan, association, DNS, TCP, headers, and result display;
4. attempt transfer while discovery owns Wi-Fi, then complete transfer after
   discovery exits; and
5. exercise an iPhone background/BLE reconnect at every terminal lifecycle.

Pass criteria:

- zero BLE disconnect/reconnect events attributable to discovery;
- zero ATT or application acknowledged-write timeouts;
- zero critical queue drops and no authentication reset;
- GPS, route, navigation, and workout data continue updating at normal rates;
- Developer Settings remains cancellable and within its measured UI budget; and
- transfer succeeds unchanged after the discovery lease is released.

Do not weaken criteria by extending BLE watchdogs, hiding queue drops, or
disabling active ride traffic.

### Power and teardown matrix

Measure radio mode, lock ownership, NVS changes, worker completion, and current
after a bounded settle for:

- successful scan while iPhone results remain visible;
- empty scan and scan API failure;
- cancel/back during scan;
- repeated Rescan and stale-result selection;
- Cancel at the iPhone confirmation;
- association failure/timeout;
- captive, no Internet, malformed, 5xx, and probe-timeout responses;
- successful Internet result, explicit Disconnect, and five-minute cap;
- iPhone background/BLE loss during scan, association, probe, and online state;
- transfer-busy rejection in both directions; and
- connection loss after a successful probe.

Every case must finish with no discovery worker operation, no retained scan
record/candidate, no station/SoftAP connection, no discovery power lock, no
automatic probe/reconnect, and the coordinator's correct owner. When no
transfer owns the radio, mode and settled current must return to the measured
radio-off baseline. A cold boot after representative success and failure must
remain radio-off and contain no temporary station.

### Endpoint and production gates

Keep evidence categories separate:

1. source/host evidence: Swift/C++/Worker tests, builds, codecs, static privacy
   checks, and exact-head CI;
2. staging endpoint evidence: deployed exact HTTP contract and controlled
   firmware outcomes;
3. production endpoint evidence: exact production hostname/contract; and
4. physical evidence: exact firmware SHA on each identified board with the BLE,
   iPhone Developer Settings, controlled-network, and power matrices.

A green Worker deploy does not prove firmware behavior. A successful firmware
build does not prove BLE coexistence. One display family does not qualify the
other.

## Acceptance mapping

| Issue acceptance criterion | Planned evidence |
| --- | --- |
| Nearby networks are listed accurately without interrupting an active ride | ESP32 scan normalization/auth mapping, authenticated BLE chunk tests, iPhone Developer Settings UI tests, independent controlled scan comparison, and active-ride BLE matrix |
| The device never auto-connects to an open network | Explicit iPhone confirmation, fresh operation ID per attempt, generation/ID checks, persistence/auto-reconnect disabled, exact BSSID/channel binding, and retry tests |
| Failed, captive-portal, and Internet-unavailable states are clearly shown | Bounded first-party probe/parser, `WFST` terminal statuses, controlled portal/no-uplink/service-failure matrix, and iPhone outcome UI checks |
| Wi-Fi discovery does not persist or upload scan history | RAM-only device/iPhone snapshots, no BSSID/raw bytes over BLE, no storage/log/analytics fields, NVS/cold-boot checks, and no-storage Worker |
| Leaving restores the previous low-power Wi-Fi state | Generation-scoped shared radio lease, idempotent cleanup, dedicated power lock, BLE-loss/background teardown, NVS check, and settled-current matrix |

## Non-goals

- Adding this feature to the ESP32 LVGL **Device Settings** page; the entry is
  exclusively in the iPhone **Developer Settings** page.
- Using iOS `NetworkExtension` to scan or join networks; the iPhone does not
  perform the RF scan or native Wi-Fi join.
- Password entry or connecting to WEP/WPA/WPA2/WPA3/enterprise networks.
- OWE association in the initial release.
- Hidden-network connection.
- Saving, ranking, recommending, or auto-selecting networks across sessions.
- Background, periodic, ride-triggered, or location-triggered discovery.
- Sending BSSID, channel, raw SSID bytes, scan history, or portal content over
  BLE, to cloud services, or to analytics.
- Captive-portal browsing, login, terms acceptance, redirect following, or form
  submission.
- Using temporary open Wi-Fi for map downloads, firmware upgrades, debug-log
  transfer, remote debugging, diagnostics, or any inbound service.
- Replacing the existing preferred-LAN/SoftAP transfer configuration UI.
- Guaranteeing that a reachability heuristic identifies every captive portal.
- Per-session MAC randomization without a separate design and physical gate.

## Definition of done

The feature is complete only when:

- the capability-gated iPhone Developer Settings flow is implemented and the
  ESP32 remains the headless scanner/temporary connection owner;
- the shared radio coordinator owns every firmware Wi-Fi lifecycle, including
  existing device transfer;
- authenticated `WFTR`/`WFST`/`WFSC` protocol code is bounded, idempotent,
  backward-compatible, and fully tested;
- explicit confirmation, one-shot open association, reachability outcomes, and
  deterministic cleanup satisfy the privacy/security invariants;
- all Swift, C++, codec, Worker, transfer-regression, and UI tests pass on the
  exact release head;
- all four firmware environments build with recorded toolchain and size/heap
  evidence;
- staging and production probe hosts satisfy the exact plain-HTTP contract
  without weakening existing HTTPS policy; and
- both identified display boards pass controlled-network, active-ride BLE, and
  power/teardown matrices using the exact release artifact.
