# Nearby Wi-Fi Discovery and Own-Network Password Testing Plan

## Status and baseline

This plan addresses [GitHub issue #101](https://github.com/seichris/open-bike-computer/issues/101).
It was refreshed against freshly fetched GitHub `main` at
`df58b75a05e6aa3aa5813e33090cfab6d116b432` on 2026-10-29, superseding the
October 2 refresh at `0f6fc8c6f0238d5508df199f2a50b1482b62ca1d`. PR #375 remains
documentation-only. This is an implementation contract, not a claim that the
feature, BLE protocol, endpoint, or physical validation already exists.

Scope now includes two separately gated phases: open-network discovery/checks
and foreground password-list testing against the user's own explicitly selected
networks. Ownership scope was confirmed on October 29. The latter is fully
planned below, not awaiting a further ownership clarification. This PR does
not authorize implementation, deployment, network testing, or a device write.

### Changes required by current main

| Area | Verified current source | Revised implementation decision |
| --- | --- | --- |
| Capability allocation | Client 33; base bits 0–31 occupied; extended-feature TLV type 3 uses bits 0–3 | Propose extended bit 4/client 34 for discovery and bit 5/client 35 for own-network testing; recheck before implementation |
| Wi-Fi execution | `DeviceOperationOwner` plus native `DeviceWiFiRuntime`; static internal stack, resident driver/netifs | Extend native scan/exact-target association; never mix Arduino WiFi lifecycle flags with this runtime |
| Transfer lifecycle | Shared commit grants, shutdown barrier, PSRAM protocol workers, quiescent internal owner | Add discovery admission without disturbing accepted map/OTA work or reclaiming resident runtime resources |
| BLE routing | `BLEManager.sendTransferControlPacket`: Settings first, navigation fallback; maintenance-specific routing | Use existing queue and protected channel selection; reject discovery in firmware maintenance |
| iOS admission and credentials | App-wide `DeviceOperationCoordinator`; trusted LAN Keychain store | Extend shared admission with a temporary test kind and secret-free cleanup; use a separate password-list Keychain service |
| Validation | `tools/dev-setup`, `tools/dev-env`, central checks/source graphs, path-selected firmware matrix | Use managed host dependencies and current check selection; retain separate physical qualification |

All source paths in this table are repository-relative; detailed paths appear
below. Plans for other unmerged branches are not treated as implemented code.

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

Add a capability-gated **Nearby Wi-Fi** row to the iPhone Developer
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

The open-network phase never auto-connects, never saves a network, never retries silently,
never follows or opens a captive-portal page, and never exposes the existing
map/firmware/debug/diagnostics transfer server on an untrusted WLAN.
The separately confirmed password-test phase may advance through a bounded
user-selected list for one owned target; it saves only user-authored password
lists, not discovered networks or scan history. Both phases retain the same
headless device, no-listener and cleanup boundaries.

## Current `main` behavior

### iPhone Developer Settings

`ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift` contains a
`DeveloperSettingsView` with map-server, map-library, workout, transfer,
diagnostics, remote-debug/renderer, device-status, and test-navigation sections.
It already receives
`BLEManager` as an environment object and is the correct owner for an
experimental hardware-connectivity row. There is no nearby-network view model,
scan result model, or BLE command for this feature today.

The iPhone's existing CoreBluetooth path is deliberately centralized in
`BLEManager`. `sendTransferControlPacket` prefers protected Settings (`2A73`)
writes and falls back to protected navigation (`2A6E`); reverse control
notifications use navigation. The manager's queues classify
transfer/control traffic separately from replaceable GPS, route, and workout
telemetry. A new feature must use that transport rather than opening a second
CoreBluetooth writer or a direct Wi-Fi API.

### BLE protocol and capability state

The generated BLE contract has a full 32-bit base `CAP2` mask:
bit 31 is now `terrain_experiments`. Current client version is 33.
An existing extended-feature TLV (type 3) carries another UInt32 mask, with
bits 0–3 assigned to group riders, friend-marker scale, route elevation and
map POIs. Propose extended bit 4/client 34 for `nearby_open_wifi` and
extended bit 5/client 35 for `owned_wifi_password_test_v1`. Base bit 31 must
not be reused. These are allocations to reconfirm when code is implemented,
not reservations made by this documentation PR.
Authenticated transfer controls already use Settings/native and navigation
fallback paths. Device-originated status can be sent as
one protected notification or as a bounded chunk sequence.

There is no scan/connection command, nearby-Wi-Fi capability bit, or scan-result
chunk parser. Older iOS builds must continue to ignore the additive capability
and unknown notifications.

### ESP32 radio and power lifecycle

Once initialized, the native runtime's radio-off baseline retains the driver
and netifs. On normal 1.75-inch boot, `main.cpp` calls
`operationOwner()->prepareWiFi()` before BLE fragments internal RAM, except
after an unfinished boot when preparation is deferred. Maintenance and 2.06
must retain their current first-use paths and independent memory qualification.
Preparation installs no session credentials and does not start the radio.
Runtime stop uses `esp_wifi_stop()`, clears RAM configuration and
returns to `WIFI_MODE_NULL`. Restore this measured resident-but-stopped state,
not Arduino `WiFi.mode(WIFI_OFF)` or driver deinitialization.

The transfer subsystem now has an explicit internal execution boundary:

- `esp32/lib/device_transfer/device_transfer_network_owner.hpp` defines
  `NetworkOperationOwner`, detailed startup failures, and internal/DMA memory
  admission checks. These are conservative rejection floors derived from
  observed failures, not proof of successful discovery operation.
- `esp32/lib/firmware_update/device_operation_owner.hpp/.cpp` implements
  `DeviceOperationOwner`: a serialized 16 KiB internal-RAM worker for Wi-Fi
  mutations, OTA flash operations, and durable map activation. Its internal
  stack/TCB are static and boot-lifetime. It correlates command/results and
  poisons the owner on unsafe timeout/mismatch. `release()` quiesces and clears
  staging buffers; it does not delete the task or reclaim its stack.
- `esp32/lib/firmware_update/device_wifi_runtime.hpp/.cpp` owns the native
  IDF driver, netifs and event handlers. It distinguishes first-use allocation
  admission from resident-radio headroom checks and publishes readiness and
  disconnect observations. Extend this runtime, not Arduino WiFi internals.
- `HttpTransferServer` delegates Wi-Fi mutations through that interface. Its
  HTTP/TLS worker uses PSRAM; map activation remains on the internal owner.
  Wi-Fi configuration uses `WIFI_STORAGE_RAM`; there is no event-driven
  reconnect loop. Network teardown precedes owner quiescence.

The existing transfer path:

1. it switches to station mode and attempts the configured preferred LAN;
2. it falls back to a WPA2 SoftAP when station association fails;
3. it starts the authenticated, pinned-HTTPS transfer server; and
4. it stops the radio and clears session configuration when transfer ends.

There is still no discovery-versus-transfer admission lease or scan interface.
Execution serialization alone does not prevent a discovery request from
reconfiguring a live transfer. Extend the existing owner and add non-preemptive
admission above it. Do not reintroduce direct Wi-Fi mutations from a new worker.
Preserve committed map activation/rollback and OTA maintenance boundaries even
after BLE revocation; a discovery cancellation cannot interrupt those operations.
The common commit-grant and shutdown barrier now govern these transitions;
see `docs/wifi-device-operation-lifecycle.md`. Discovery is reversible work
and must drain before shutdown can receive its power permit.

`RemoteDebugLANCredentialStore` in `DeviceTransferManager.swift` already keeps
one trusted LAN credential in this iPhone's device-only Keychain, with separate
Debug/Release service identities. That is deliberate saved configuration for
trusted transfers, not a scan-history store or implicit consent to try networks.

`DeviceOperationCoordinator.swift` already serializes app-wide transfer
admission, tracks device/connection-epoch leases and retains unresolved cleanup.
Add a non-hotspot temporary-Wi-Fi operation kind to this coordinator rather
than creating a parallel app lock. Do not reuse its recorded hotspot SSID field
for a discovered target. Discovery never applies or removes an iPhone network
configuration. Extend recovery to use fresh matching discovery status; a blank
transfer `DSTS` alone cannot prove a discovery run has stopped.

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
  `DeveloperSettingsView` containing **Nearby Wi-Fi**, with an open-network
  action and a separately gated **Test My Network** action.
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
2. configures `WIFI_STORAGE_RAM` and zero connection retries in the native runtime;
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

Introduce a pure `wifi_radio` admission policy around the existing
`DeviceOperationOwner` execution boundary. The coordinator decides which
session may use Wi-Fi; the existing internal executor performs all driver
mutations. The initial lease owners are:

```cpp
enum class Owner {
    None,
    DeviceTransfer,
    DiscoveryScan,
    TemporaryOpenNetwork,
    OwnedNetworkTest,
};
```

`tryAcquire(owner)` returns a generation-scoped lease with a monotonically
increasing token. A release succeeds only when owner and token still match, so
a late worker completion cannot turn off a newer owner.

Ownership is non-preemptive:

| Current owner | Requested owner | Result |
| --- | --- | --- |
| None | Any valid owner | Grant |
| DeviceTransfer or accepted activation | Discovery/temporary connection/password test | Reject; transfer or accepted work continues |
| Discovery/temporary connection/password test | DeviceTransfer | Reject with `wifi_busy` |
| Shutdown admission closed or maintenance boot | Any discovery/test owner | Reject without starting the radio |
| Discovery scan still running | Temporary connection | Reject as busy; finish scan and release its lease before confirming a result |
| Any owner | Same owner with stale token | Reject as stale |

Have `HttpTransferServer` acquire `DeviceTransfer` before its first network
owner command and release it only after server, station, AP, and required
activation handoffs finish. Reuse the same `DeviceOperationOwner` instance
already wired through firmware-update/transfer setup; inject its narrow
network interface into discovery rather than constructing another executor. A
rejected transfer publishes the existing generic status with stable
`lastError.code = "wifi_busy"`; the iPhone can explain that the Developer
Settings session must end before transfer can start.

The coordinator's last-owner cleanup orchestrates protocol-worker teardown and
dispatches driver mutations on the internal executor. It must:

1. cancel/delete scan state;
2. wait for owner-specific protocol-worker/listener teardown before disconnecting;
3. disconnect station and SoftAP state and clear temporary RAM configuration;
   preserve existing persistent settings and never erase unrelated NVS;
4. invoke the native runtime stop/credential-clear path, leaving the driver and
   netifs resident with radio stopped and `WIFI_MODE_NULL`; and
5. release the matching power-management lock only after confirmed cleanup,
   and quiesce the internal owner without deleting its static task. A poisoned
   owner or failed cleanup keeps admission closed; it cannot claim radio-off
   success or provide a shutdown acknowledgement.

Extend `NetworkOperationOwner` with scan start/poll/cancel/delete and
BSSID/channel-bound station association operations, carrying session generation
and command identity. Keep calls short and asynchronous at the discovery
boundary; its eight-second deadline must not block behind the existing
60-second synchronous owner dispatch or ten-minute map-activation timeout.
Do not hold the internal executor waiting for DHCP, DNS, TCP, or a probe body.
Admission must reject discovery while transfer, activation, or firmware
maintenance is active. Preserve first-use internal/DMA free-and-largest-block
checks and resident-start headroom checks, including measured resident allocation.
Expose bounded, non-secret failure codes to iOS.

Add the discovery/test controller to the existing nonblocking shutdown drain:
close admission, cancel outstanding reversible work, clear credentials/results,
stop the radio, and acknowledge only after matching worker/owner completion.
Missing or poisoned completion defers shutdown; it never forces sleep. Any
PSRAM worker follows the existing completion-and-park, internal-owner-reclaims
pattern. Do not self-delete a PSRAM task or delete the resident operation owner.

Do not snapshot/replay arbitrary radio modes. A failed discovery
acquisition leaves the transfer owner untouched; release from the only owner
returns to the measured radio-off baseline.

### 2. Capability-gated authenticated BLE contract

Provisionally add `nearby_open_wifi` as extended-feature bit 4 with minimum client
version 34, and `owned_wifi_password_test_v1` as extended bit 5/client 35, in
`protocol/ride-ble-contract-v1.json`, regenerate the checked-in Swift and C++
constants, and expose `supportsNearbyOpenWiFi` from `BLEManager`. Clear it on
disconnect, authentication reset, malformed capability response, or downgrade.
Use the existing type-3 extension and generated extended masks, not the base
feature word. Recheck both allocations immediately before implementation.
Test absent/truncated/unknown TLVs, independent capability gating, reset and
old-client parsing. Password testing requires both discovery and test support;
advertising discovery alone must never make secured rows connectable.
The Developer Settings row remains disabled until the bit and navigation-ready
state are both true. Older clients ignore the bit; older firmware never receives
new commands.

Use `BLEManager.sendTransferControlPacket` and its existing prioritized queue:
protected `2A73` when available, protected `2A6E` fallback otherwise, with
notifications on `2A6E`. Dispatch both firmware input paths to the same
authenticated-owner handler. Do not add a new characteristic, a second
CoreBluetooth writer, or an unauthenticated scan
path. The owner role is required; the Apple Watch role has no Developer
Settings/control authority and cannot start discovery. Normal-boot capability
publication must exclude discovery in firmware-maintenance boot. Do not expand
maintenance's command allowlist or route discovery through its reconnect path.

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
Compute each chunk budget from the actual negotiated ATT payload minus the
22-byte protected frame overhead and the finalized chunk header. Cap data at
128 bytes only when it fits; apply the same budget to status frames. Freeze a
shared maximum serialized byte count and corresponding maximum chunk count so
24 worst-case escaped SSIDs fit both encoders and decoders. Never use a network
count as the chunk-count limit. Reject conflicting duplicate,
missing, out-of-order, stale, or over-limit chunks. `WFST` acknowledges each
logical command with the same operation ID and terminal state. Identical
duplicate chunks may be ignored, with an explicit deadline for missing chunks.
If iOS does not receive an acknowledgement, it may retry one idempotent command with the same
operation ID; it must never create a new connection attempt without a new
confirmation and operation ID.

Add golden vectors and loopback tests for command parsing, authenticated frame
routing, chunk reassembly, result generation, truncation, malformed JSON,
missing chunks, stale operations, and capability gating. Update
`docs/ble-protocol.md` with the normative contract and compatibility behavior.

### 3. Headless ESP32 discovery controller

Add a `wifi_discovery` controller that exposes intent, snapshot, and lifecycle
operations to BLE/control code, not direct native driver calls from BLE callbacks:

```cpp
void requestScan(uint32_t operationId);
void requestConnect(uint32_t operationId, uint32_t generation,
                    uint32_t networkId);
void requestCancel(uint32_t operationId);
void requestDisconnect(uint32_t operationId);
void process();
```

Keep BLE session generation, scan generation, operation ID, and lease token
distinct. A new scan creates a new scan generation; Connect consumes the
selected still-valid generation and creates a fresh operation ID. Cancel,
disconnect, BLE loss, capability reset, and expiry invalidate the corresponding
session/results. Worker completions carry session generation, operation ID,
and lease token; stale completions cannot change radio state or emit success.
After a successful scan, release the radio but retain only the bounded RAM
candidate table for the 30-second selection window. Expiry/view exit clears
it even while the radio is already off.

Run scan/association orchestration and the probe on a bounded low-priority
worker. Dispatch driver mutations to the existing internal-RAM owner; a PSRAM
worker must never invoke a flash-cache-disabling driver path. Publish immutable
snapshots for the BLE notification pump through a
mutex/queue. The existing main/control task can use a `Wifi` wake reason to
flush notifications, but no worker path may touch LVGL or block the BLE host
task.

### 4. Bounded scan policy

Extend `DeviceWiFiRuntime` with native asynchronous scanning through the pinned
ESP-IDF API, invoked only from the internal owner, with explicit limits:

- visible networks only;
- all locally allowed 2.4 GHz channels;
- one pass per request;
- initial maximum active dwell of 120 ms per channel;
- no background repeat; and
- a bounded overall scan deadline including driver overhead.

The dwell is a starting value from the ESP-IDF active-scan range, not proof of
BLE coexistence. Lower it or select a passive policy only from measured results;
do not raise it without rerunning the active-ride matrix.

On the matching scan-done event, retrieve records through the native scan-record
API into a bounded normalization path, explicitly free any remaining driver
AP list, publish the chunked result, release `DiscoveryScan`, and return the
radio to off. Apply
the same deletion/release path on timeout, cancellation, BLE loss, result expiry,
and screen exit. The result list may remain on the iPhone while the device radio
is off.

Generate a nonzero boot-local `networkId` for each retained group. Do not use a
hash of SSID/BSSID as an identifier, because that would create cross-session
linkability. The ID is useless after its generation expires and is never logged.

### 5. Temporary connection and cleanup

After a valid authenticated `WFTR connect` command, acquire
`TemporaryOpenNetwork` and configure Wi-Fi in this order:

1. use RAM-only configuration and zero driver retries, with no event reconnect loop;
2. select station-only mode;
3. ensure RAM-backed driver storage, then start one null-passphrase connection
   bound to the retained raw SSID,
   channel, and BSSID;
4. wait for association and DHCP until the eight-second deadline while checking
   cancellation/generation; and
5. run the reachability probe once.

Cleanup is idempotent and safe before, during, or after every step. It must
erase the candidate table and selected bytes, release the exact lease, clear
the operation result, and prevent late callbacks from affecting a newer scan or
owner. Verify RAM-only configuration and temporary-buffer clearing against the
pinned SDK. Prove Wi-Fi NVS is unchanged after success, failure, and cancel;
do not use a blanket NVS erase as cleanup.

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

Firmware uses a small bounded HTTP/1.1 parser over a socket/client adapter that
does not initialize or mutate Arduino WiFi state:

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

Relevant references are the [ESP-IDF 5.5.1 ESP32-S3 Wi-Fi API](https://docs.espressif.com/projects/esp-idf/en/v5.5.1/esp32s3/api-reference/network/esp_wifi.html),
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

These are hard requirements for open-network v1. The password-test phase adds
only the explicit Keychain-list and transient credential exceptions described
in its section below; it does not relax scan-history or telemetry privacy:

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

- Add `nearby_open_wifi` provisionally at extended bit 4/client 34 and
  `owned_wifi_password_test_v1` at extended bit 5/client 35 to
  `protocol/ride-ble-contract-v1.json`; regenerate the checked-in Swift/C++
  contract files and run the generator drift check.
- Update `docs/ble-protocol.md` with `WFTR`, `WFST`, and `WFSC` semantics,
  authentication, bounds, operation idempotency, chunking, and compatibility.
- Add `esp32/lib/wifi_radio/wifi_radio.hpp/.cpp` for lease admission,
  restoration policy, and power-lock integration; driver execution remains in
  the existing internal owner.
- Extend `esp32/lib/device_transfer/device_transfer_network_owner.hpp` and
  `esp32/lib/firmware_update/device_operation_owner.hpp/.cpp` with bounded
  generation-aware scan and exact-candidate station operations. Preserve
  `firmware_internal_owner_policy.hpp` poisoning and release guarantees.
- Extend `esp32/lib/firmware_update/device_wifi_runtime.hpp/.cpp` with native
  scan, exact-BSSID/security association and attempt-fenced event observations.
  Preserve resident allocation, static internal stacks and credential clearing.
- Update the wiring in `esp32/lib/firmware_update/firmware_update_http.cpp`
  to share its owner with discovery through an injected narrow interface.
- Add `esp32/lib/wifi_discovery/wifi_discovery.hpp/.cpp` plus pure policy,
  normalization, authentication-mapping, deadline, and HTTP-response helpers.
- Update `esp32/lib/ble_navigation/ble_navigation.cpp/.hpp` to dispatch
  authenticated `WFTR` commands and pump bounded `WFST`/`WFSC` notifications.
- Update `esp32/lib/device_transfer/device_transfer_http.hpp/.cpp` to use the
  shared lease and return `wifi_busy` without changing transfer auth/fallback.
- Update `esp32/lib/power_management/power_management.hpp/.cpp` with a
  dedicated Wi-Fi lock domain and `esp32/src/main.cpp` with controller polling
  and shutdown-drain participation. Reuse `power/shutdown_barrier_policy.hpp`
  and commit-grant admission rather than adding an independent shutdown path.
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

Register commands and affected paths in `tools/development/checks.json` and
production Swift dependencies in `tools/development/swift-sources.json`.
Compatibility shell entry points should delegate to those definitions, as
current navigation tests do. Add protocol golden vectors under
`protocol/fixtures/` and deterministic cancellation/backpressure scenarios
under `protocol/scenarios/` where the existing replay runner applies. Keep
Worker checks in the existing map-platform CI entry point and central registry
where applicable. Do not recreate parallel hard-coded Swift compiler lists.

## Implementation sequence

### Phase 0: freeze cross-platform contracts

1. Reconfirm the Developer Settings placement and document that the ESP32 is
   the scanner because iOS has no general-purpose scan API.
2. Capture generated Wi-Fi/BLE coexistence configuration, firmware size,
   radio-off current, BLE counters, and iPhone transport/UI baselines for both
   hardware families.
3. Inventory all firmware `WiFi` mutations/listeners and all BLE command/status
   dispatch points, including boot/deep-sleep shutdown, internal owner commands,
   map activation/rollback and firmware maintenance. Confirm World Radio's
   current transport rather than treating its name as a Wi-Fi owner.
4. Finalize capability bit/version, `WFTR` fields, `WFST`/`WFSC` bounds,
   operation idempotency, security enum mapping, and timeout constants.
5. Stage the probe hostname policy and prove plain HTTP can be isolated without
   weakening existing HTTPS/HSTS behavior.

Exit gate: no unresolved implementation-changing decision remains in the
Developer Settings UX, authenticated BLE contract, radio ownership, probe
contract, or privacy review.

### Phase 1: radio ownership first

1. Implement pure owner/token transitions and exhaustive stale-release tests.
2. Integrate `HttpTransferServer` and discovery admission with `DeviceTransfer`
   leases around the existing `DeviceOperationOwner`; extend its narrow network
   interface rather than creating a second internal worker.
3. Preserve preferred-LAN, SoftAP fallback, authentication, and transfer status
   behavior, memory admission, poisoning, resident-owner quiescence, and activation/OTA
   commit boundaries; add stable `wifi_busy` rejection.
4. Add Wi-Fi power-lock accounting and assert stopped radio/cleared RAM config/
   `WIFI_MODE_NULL` after the last owner, retaining resident driver resources.

Exit gate: existing transfer host/device regressions pass and concurrent owners
cannot mutate the radio.

### Phase 2: authenticated BLE contract

1. Recheck the proposed extended bits 4/5 and client versions 34/35, add
   generated constants, and test TLV parsing plus independent feature gating.
2. Implement strict `WFTR` command parsing/building and protected routing.
3. Implement bounded `WFST`/`WFSC` notifications, Swift reassembly, golden
   vectors, retries, and generation/operation validation.
4. Prove old clients/firmware ignore the additive feature safely.

Exit gate: loopback and host tests prove authenticated, bounded, idempotent
command/status delivery without starving replaceable ride telemetry.

### Phase 3: headless scan domain

1. Implement asynchronous scan/cancel/deadline orchestration with driver calls
   dispatched to the internal owner and nonblocking BLE callbacks.
2. Add safe SSID presentation, complete auth mapping, grouping, open-first
   ordering, 24-result cap, boot-local IDs, and expiry.
3. Publish snapshots/chunks and prove scan deletion, lease release, and radio
   restoration on every completion/cancel/error/BLE-loss path.

Exit gate: C++ policy tests pass and the authenticated control harness can scan
without logging network identity or blocking the BLE host task. Physical
evidence must use the intended build/profile and deliberate capture flow;
opening serial solely to observe a running session can reset the device.

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

### Current validation entry point

For this documentation refresh, prepare the worktree with `tools/dev-setup`,
run `tools/dev-env tools/dev-check --plan`, selected fast checks via
`tools/dev-env tools/dev-check`, and `git diff --check`. A docs-only refresh
does not establish any of the implementation or physical gates below.

During implementation, register new checks/source graphs first, then use the
same entry point locally and in CI. Add explicit full iOS and board-specific
firmware checks only when their sources change and prerequisites are available.
Retain the generated report and label blocked prerequisites separately from
failed or passed tests. Follow `docs/development-checks.md` and `AGENTS.md` for
isolated simulator ownership, the Xcode wrapper, locked firmware runtime, and
clean-source evidence. Current CI chooses boards/profiles from changed paths;
shared runtime/configuration and unknown libraries can select both boards.
Record the actual matrix; never infer 2.06 or remote-debug validation from the
aggregate gate's name. Clean local receipts may be reused only by the existing
verifier; they do not substitute for firmware or physical acceptance.

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
- internal-owner creation/dispatch failure, memory rejection, timeout poison,
  late result, resident-owner quiescence, map activation handoff, and rejected
  discovery during firmware maintenance;
- both native Settings and navigation fallback routes, maintenance rejection,
  extended-feature CAP2 round trips, and smallest-supported protected ATT budgets;
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
coexistence configuration. Use current path-selected CI evidence for the actual
boards/profiles built, add missing target qualification explicitly, and retain
physical evidence separately. Shared radio/runtime changes must also exercise
the affected remote-debug/lifecycle profiles selected by current CI policy.

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

Every terminal session case must finish with no discovery worker operation,
no retained scan record/candidate, no station/SoftAP connection, no discovery
power lock, no
automatic probe/reconnect, and the coordinator's correct owner. When no
transfer owns the radio, mode and settled current must return to the measured
radio-off baseline. A cold boot after representative success and failure must
remain radio-off and contain no temporary station.

A successful scan with its results still displayed is the sole retention
exception: driver scan records and the radio lease are released immediately,
while the bounded candidate table remains for at most 30 seconds. Exercise
expiry without a new BLE command and prove the table is then cleared.

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

## Phase 7: password-list testing for the user's own networks

The user confirmed that targets are their own networks and requested this
extension on October 29. Design an explicit foreground test of one selected
access point using a small list of passwords the user supplied in the app.
No further ownership clarification is required to complete this plan.
Implementation remains outside this documentation-only PR.

### Product flow and target selection

1. In **Nearby Wi-Fi**, tap **Password Lists** to create, name, edit, reorder
   or delete a list. Each entry has an opaque local UUID, optional display label
   and secret; passwords are masked. Manual entry is sufficient initially.
   No dictionary downloads, password generation, permutations or bulk import.
2. Scan explicitly, select a supported secured network, then tap **Test My
   Network**. This action requires both extended capabilities and an
   authenticated owner phone. Unsupported firmware shows an explanation.
3. If the grouped SSID represents several APs, select a device-supplied
   session-only AP choice (for example “Access point 1, -52 dBm”). Add
   per-candidate opaque IDs beneath grouped rows in this capability version;
   retain BSSID/channel/raw SSID exclusively on the device. Do not silently
   move to the strongest sibling between attempts.
4. Choose one list or a subset in its displayed order. Show the safe target
   name, security, password count, bounded runtime and **Stop** behavior.
   Require explicit confirmation that this is the user's own network and
   **Start Test** for every run. Selecting a row/list is not consent.
5. Show **Testing password 2 of 5**, elapsed time, the target and Stop. Do not
   display the attempted password. Freeze the list revision and order for the
   run; editing/deleting an active list first stops the run and waits for cleanup.
6. Finish with a per-entry result and, on success, the local entry label/index.
   Do not reveal, copy, save to a network profile or export the successful
   password automatically. Session results disappear when leaving the view.

Target selection must be less than 30 seconds old at Start. Firmware binds a
new random run grant to its exact retained AP identity, security mode, current
boot, owner session and run ID. The scan's normal expiry is replaced by the
bounded run lifetime for that one pinned candidate only. Other candidates
expire normally. If the AP disappears, changes security, or reports a different
identity, end the run and request rescan/confirmation; never fall back by SSID.
An SSID/BSSID match is a binding constraint, not cryptographic proof of AP
ownership. Validation uses controlled APs owned by the tester.

Cap selectable AP choices at four per retained group (96 total for 24 groups);
show a per-group truncation notice when necessary and never automatically
test an omitted AP. Recalculate result JSON/chunk bounds for these choices
instead of assuming the open-only payload budget still suffices.

Initial secured support is WPA2-Personal only. WPA3-only and transition modes,
WPA/WEP, enterprise, OWE, WPS, hidden SSIDs and unknown modes remain disabled
until separately qualified. Do not silently downgrade security to make a
candidate work. Open networks keep their existing no-password flow.

### Bounds, progression and outcome semantics

These are initial product limits to enforce in firmware as well as iOS:

| Limit | Initial policy |
| --- | --- |
| Stored collections | At most 5 lists, at most 10 entries each |
| One confirmed run | One exact AP, 1–10 selected unique passwords, one attempt at a time |
| Credential format | 8–63 UTF-8 bytes, no NUL; preserve bytes exactly without trimming/normalization; raw 64-hex PSKs deferred |
| Authentication/association | At most 8 seconds per attempt |
| Progression pacing | At least 5 seconds after confirmed teardown before a different password |
| Whole run | 180-second monotonic absolute cap; not extended by heartbeat/retry |
| Foreground liveness | Heartbeat every 2 seconds; device cancels after 8 seconds without a fresh heartbeat |
| Cleanup acknowledgement | 3-second target; exceeding it reports cleanup unresolved and blocks new admission |
| Application retry | At most one retry/query with the same request identity; never a second RF attempt for a duplicate |

Exact duplicate entries are rejected within a list without logging their value.
Advance only after a current-attempt authentication rejection or a classified
WPA2 four-way/handshake failure for the still-pinned target. Wrong WPA2
credentials can surface as handshake failures, so those must be exercised by
the controlled-AP wrong-first/correct-second fixture rather than classified
unconditionally as a transport outage. Report **Not accepted in this attempt**
with a bounded reason, never that a password is definitively wrong.
The existing `StationState::AuthenticationFailed` bucket is insufficient:
retain typed current-attempt reason evidence and fence old events. A generic
eight-second deadline with no matching handshake/authentication result,
no-AP, changed target or unknown failure is inconclusive and stops the run.
This conservative distinction follows
[Espressif's Wi-Fi failure guidance](https://github.com/espressif/esp-faq/blob/master/docs/en/software-framework/wifi.rst):
a handshake failure can accompany a bad password, but is not definitive proof.

Stop at the first completed secure association. Verify the negotiated security
and selected BSSID before reporting **Credential accepted**. DHCP then gets a
separate eight-second window, followed by at most one optional bounded probe.
No DHCP, captive portal or unavailable Internet does not invalidate the
credential and must not cause another password attempt.

| Observation | Result and next action |
| --- | --- |
| Current-attempt rejection or classified WPA2 handshake failure | Record not accepted with reason, teardown, wait, advance if within limits |
| Generic timeout without matching auth result, AP absent/changed, disconnect ambiguity | Inconclusive; stop, no automatic next password |
| Secure association verified, DHCP fails | Credential accepted; address unavailable; stop and disconnect |
| Secure association and DHCP succeed | Credential accepted; optionally check reachability once |
| Portal/no Internet/probe error | Separate network outcome; stop and disconnect, no additional passwords |
| All selected entries attempted without acceptance | No selected password accepted in this run; end run |
| Radio busy, low memory, poisoned owner, shutdown requested | Stop or reject before attempt; preserve other operation |
| Cancel, background, BLE loss, heartbeat or absolute timeout | Cancel, clear secrets, stop radio; no automatic resume |

The password-test phase always disconnects after its result, including success;
it does not inherit the open-flow five-minute online display period. There is
no auto-reconnect or attempt of the same password within a run. A new run needs
a fresh scan and explicit confirmation. No testing during active navigation or
a workout in the initial release: if a ride begins, cancel at the reversible
boundary. Open-network scan coexistence remains separately qualified.

### Storage and credential boundary

Add a separate `OwnedWiFiPasswordListStore` using a versioned device-only
Keychain service, isolated between Bicino Dev and production. Use
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, synchronization disabled, and
no shared Watch/app-extension access group. See Apple's
[Keychain accessibility contract](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly).
Keychain failures or a locked device fail closed; never fall back to defaults.

Store list/entry UUIDs, labels, order, revision and passwords together in
bounded Keychain records. Persist only user-authored content: no discovered
SSID/BSSID, network-to-password mapping, matched-password history, attempt
history or result. Existing trusted-transfer credentials are never imported
or modified automatically. Do not add clipboard/export or iCloud sync.

The session coordinator holds entry IDs/order, not a second full plaintext
list. Retrieve only the next entry at dispatch, bind it to the frozen list
revision, and clear temporary references after transport completion/drop.
On app background/lock, cancel and cover the secret editor in the app-switcher
snapshot. Swift String/Data copies cannot promise complete process-memory
zeroization; minimize copies/lifetime, never stringify packets, and explicitly
wipe owned mutable byte buffers where supported. Firmware uses fixed bounded
credential buffers, non-elidable clearing, and the native runtime's RAM config
clear path. It never writes credentials or password hashes to NVS/SD.

### Protocol and session state

Keep open-only `WFTR` commands credential-free. Define an additive
`WFTP` binary version-1 control family for test sessions and `WFTS` bounded
status responses, using the existing owner-authenticated Settings/navigation
routes with ownership-v2 AES-256-GCM protection; authenticated plaintext or
legacy unprotected fallback is never acceptable for credentials.
Reserve these prefixes in the generated contract and normative BLE doc
during implementation. Do not overload `DTRN` trusted-LAN entry or create a
transfer token, SoftAP, HTTPS listener or iPhone hotspot join.

The finalized wire schema must include a version/action, request ID, random
run ID, device-issued target grant where applicable, attempt index and explicit
body length. Fix byte order and exact field sizes with cross-language golden
vectors before writing either transport adapter. Proposed operations:

| Operation | Meaning |
| --- | --- |
| Begin | Scan generation, candidate ID, expected security and selected count; device validates admission and returns a random target grant |
| Try credential | Run/grant, next attempt index and one length-prefixed credential; no SSID, BSSID, whole list or user label |
| Heartbeat/query | Run/grant only; observe/reaffirm liveness, never associate |
| Cancel | Run/grant; terminally fence queued attempts and request teardown |
| Status | Echo request/run/attempt, bounded phase/result/reason, counts and cleanup state; never credential, hash or packet echo |

Keep the maximum command within the negotiated protected ATT budget at the
minimum supported MTU; refuse an undersized transport before extracting a
secret. Do not add credential fragmentation in the initial protocol. Treat
credential writes as noncoalescible acknowledged control, never replaceable
telemetry; cancellation invalidates queued Try writes before returning.
The transport queue must clear secret-bearing bytes on ACK, drop, disconnect
and reset, and its debug/diagnostic descriptions must be redacted.

iOS obtains the shared app operation lease before Begin. Firmware independently
checks native owner availability, shutdown/maintenance/ride state and the
current session on Begin and Try. One in-flight attempt is admitted; changed
run/grant/index, cross-device callbacks, skipped indices and attempts after
terminal cancellation are rejected. Identical request retries return the
existing status and cannot trigger a second association. Conflicting retry
bodies fail closed, using a session-keyed RAM digest if needed; never log or
persist a password digest.

Device-originated Wi-Fi events do not inherently carry this app run ID. Extend
the runtime adapter to fence them: finish the old stop/disconnect and clear
pending observations before starting a new attempt, then bind observations to
the active runtime epoch. Do not merely relabel a late callback with the newest
run/index. If teardown or event ordering cannot establish the fence, stop as
inconclusive. This requires deterministic late-event tests.

Device state:

```text
Idle -> Admitted -> AwaitingCredential -> Associating
     -> Rejected -> Cleaning -> Cooldown -> AwaitingCredential
     -> Authenticated -> DHCP -> OptionalProbe -> Cleaning -> Complete
Any active state -> Cancelling -> Cleaning -> Cancelled
Unconfirmed cleanup -> CleanupUnresolved (admission remains closed)
```

The device is the authority for count/deadline/pacing. iOS never streams the
whole list or prequeues later passwords. It sends the next entry only after a
matching classified authentication failure plus cleanup/cooldown completion. Secret-free terminal
deduplication metadata may remain in RAM for the authenticated session with a
60-second retention limit; credentials and candidate identity must already be
cleared. An evicted or unknown run ID can only be queried/rejected, not revived
by Try. Starting again requires a new Begin and confirmation.

### Lifecycle, recovery and diagnostics

Reuse `DeviceOperationCoordinator` admission with a temporary test lease.
Its retained unresolved-cleanup record may contain only device ID, operation
kind, run ID and connection epoch, never target identity, list ID or secret.
Fresh `WFTS` status must confirm stop/idle for that device; transfer `DSTS`
does not substitute. Relaunch/reconnect reconciles cleanup only and never
resumes a password sequence. Firmware clears the run on BLE loss/reboot and
the absolute/heartbeat watchdog bounds phone suspension even if Cancel is lost.
Do not reuse durable map/OTA receipt stores for reversible Wi-Fi testing.

Cancel closes run admission immediately, drops queued secret writes, interrupts
association/probe, stops the native radio, clears all credential copies and
candidate identity, then reports cleanup and releases the exact lease.
Late status cannot start the next entry or clear another device's lease.
Deletion of the active list and logout/ownership reset follow this same stop.
Accepted map/OTA work is never cancelled by the test controller.

Diagnostics-v2 bundles, BLE debug events, status JSON, serial output and error
paths must never include password/list labels, secret bytes, hashes, SSID,
BSSID, raw packet dumps or portal content. Emit only bounded phase/reason,
duration, counts and resource measurements using existing schemas where
available. Audit credential staging, transport retry, failure formatting and
incident export; synthetic secrets must be absent from every captured artifact.

### Implementation slices and exit gates

Expected additions are `OwnedWiFiPasswordListStore.swift`,
`OwnedWiFiTestSession.swift` and a list-editor view under the app's existing
Managers/Views conventions; a pure credential-test codec/state policy beside
`wifi_discovery`; and synthetic fixtures in `protocol/fixtures/`.
Update `DeviceOperationCoordinator.swift`, `BLEManager.swift`, Settings,
the native owner/runtime, shutdown drain, protocol document and central
test/source registries together. These are proposed files, not current main.

1. Add pure list validation, Keychain adapter, state machine, clock and fake
   transport; test exact bytes, duplicate policy and frozen revision behavior.
2. Add the second extended capability and WFTP/WFTS golden vectors, owner-role
   checks, MTU refusal, noncoalescible secret queue and redaction contracts.
3. Extend native driver exact-target WPA2 association, typed reason evidence,
   event fencing and fixed-buffer wiping; test rejection versus inconclusive
   progression without real RF.
4. Integrate app-wide/device admission, Cancel/background/liveness, shutdown
   and unresolved-cleanup reconciliation; no listener or hotspot path.
5. Add the list editor, AP selection, confirmation, progress and outcomes in
   Developer Settings. Register production Swift sources/checks centrally.
6. Qualify on the tester's controlled WPA2 APs and each supported board, keeping
   the capability disabled in production until its own evidence gate passes.

Additional acceptance cases:

- Incorrect-first/correct-second and correct-first lists: classified current
  authentication/handshake failures advance; success stops immediately with
  the matching local label. Include APs that report bad PSKs as handshake timeout.
- All-rejected, duplicate, empty, oversized, NUL, multibyte and delimiter-bearing
  passwords: exact bounded binary handling, no truncation/normalization.
- Correct password/no DHCP, captive portal or no uplink: credential acceptance
  survives the separate connectivity failure and no next password is sent.
- Generic timeout, changed security/AP, delayed old Wi-Fi events and missing
  ACK: inconclusive/unchanged status, no extra RF attempt.
- Same-name different BSSIDs and open/secured siblings: only the pinned AP can
  be attempted; grouping never grants authorization to all neighbors.
- Cancel during every state, background/lock/termination, BLE auth reset,
  device switch/reboot, list edit/delete, ride start, transfer contention and
  shutdown: no new attempts, secrets cleared, correct lease/drain behavior.
- Reordered/duplicate/conflicting requests, capability downgrade, Watch role
  and unauthenticated requests: fail closed without radio or credential use.
- Enforce count, pacing, heartbeat and absolute cap on both sides with fake
  monotonic clocks, then measure repeated success/failure cycles on devices.
- Keychain unavailable/corrupt/version mismatch and all diagnostic/export
  paths: no fallback persistence and no synthetic secret leakage.

The extension is done only when these tests, UI behavior, both-board native
runtime qualification, RF stop/credential-clear evidence, and source/CI checks
pass. Open-network acceptance alone does not qualify password testing.

## Non-goals for open-only v1

Phase 7 explicitly adds the bounded WPA2 own-network testing and user-authored
Keychain lists above. Other exclusions remain applicable to both phases.

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

Open-network v1 is complete only when:

- the capability-gated iPhone Developer Settings flow is implemented and the
  ESP32 remains the headless scanner/temporary connection owner;
- shared admission covers all post-boot discovery/transfer use and shutdown,
  with native driver mutations confined to the existing internal runtime;
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

The full planned feature additionally requires Phase 7's independent capability,
credential lifecycle, protocol, foreground flow and owned-AP acceptance gates.
A documentation merge completes neither implementation phase.
