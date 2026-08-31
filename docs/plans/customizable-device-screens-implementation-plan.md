# Configurable Device Screen Instances and Ride Stats Layout Implementation Plan

Status: proposed

Baseline: `origin/main` at `89a705ec1dd940b6e3d4dad890cd35e4e1a58d45`
(fetched and matched against GitHub on 2026-08-31)

Planning branch: `plan/customizable-device-screens`

## Outcome

Allow a rider to build the device's main-screen cycle in the iPhone app instead
of choosing only one copy of each hard-coded screen type.

The completed feature must allow the rider to:

- add more than one instance of any supported existing screen type;
- keep, disable, remove, rename, and reorder those instances;
- select one enabled instance as the startup default;
- give each Map, Map + Navigation, or Ride Stats instance its own settings;
- assign any supported Ride Stats widget to any defined Ride Stats slot, and
  leave slots empty; and
- reboot or reconnect without losing the device's applied configuration.

In this plan, **Ride Stats** is the existing device screen that the product
request calls the workout screen. A **screen type** is Map, Navigation, Ride
Stats, Map + Navigation, or Battery Status. A **screen instance** is one entry
in the rider's ordered screen list. Two instances may have the same type while
retaining different identities and settings.

## Product decisions

The implementation should use these decisions unless product direction changes
before coding:

1. Screen order is user-controlled. The PWR button and optional tap gesture
   cycle through enabled instances in that order.
2. At least one instance must exist and at least one must be enabled.
3. The default is an instance, not a type. If it is removed or disabled, the
   first enabled instance becomes the default.
4. New instances are enabled and appended after the currently selected row.
5. Duplicate instances receive automatic names such as `Map 2`; names can be
   changed and are limited to 24 UTF-8 bytes.
6. The first release supports at most 16 stored instances. This is a protocol
   and validation limit, not a reason to allocate 16 LVGL screen trees.
7. Ride Stats customization uses defined slots rather than arbitrary pixel
   coordinates. This gives the rider control over every box position while
   keeping both supported display geometries readable.
8. The device is the source of truth for the applied configuration. The app
   edits a draft and shows success only after the complete document has been
   validated and durably committed by the device.
9. Screen changes are applied with an explicit **Save** action. This avoids a
   half-applied layout if BLE disconnects while the rider is editing.
10. Existing firmware continues to use the current toggle/default UI. The app
    exposes Add, reorder, duplicate, and per-instance controls only after the
    new capability and configuration snapshot have been received.

## Current-main evidence and constraints

### iOS

- `DeviceScreen` in
  `ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift` is a stable
  five-case enum. `enabledDeviceScreensMask` and `defaultDeviceScreen` are
  global `UserDefaults` values.
- `DeviceScreensSettingsSection` in
  `ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift` renders one row
  per supported type, a toggle, Map-profile gear buttons, and a type-based
  default picker.
- Map and Map + Navigation already have separate app settings, but only one
  profile of each type. Those properties currently live directly on
  `BLEManager`.
- Settings IDs `13` and `14` send a type bitmask and a type default. That shape
  cannot represent duplicates, order, stable instance identity, or
  per-instance settings.
- Known devices already have a stable, ownership-backed `deviceID` in
  `DeviceOwnership.swift`. Any app cache for this feature must be keyed by that
  ID, not by the transient CoreBluetooth peripheral UUID.

### Firmware

- `mainScr.cpp` owns one reusable tile for each implemented type and cycles the
  fixed `DEVICE_SCREEN_CYCLE_ORDER` array. The new feature must replace the
  logical order without creating another full LVGL hierarchy per duplicate.
- Map and Map + Navigation share one map canvas. Entry to either screen selects
  one of two singleton `ScreenMapRenderSettings` profiles and may render the
  next map-backed type ahead of a button press.
- `MapRenderSettings` and the legacy `mapSettings` NVS namespace store one Map
  profile, one Map + Navigation profile, a screen mask, and a type default.
- `rideTelemetryScr.cpp` creates one large speed area plus six metric cells.
  `rideTelemetryLayout.hpp` already validates both 410 x 502 and 466 x 466
  layouts. Widget meaning is currently wired to fixed LVGL object pointers.
- The Ride Stats presenter already exposes speed, average and maximum speed,
  current and average heart rate, heart-rate zone, distance, moving and wall
  time, energy, power, cadence, altitude, and route remaining. The configurable
  renderer should consume this existing view model rather than create another
  telemetry source.
- BLE callbacks must continue to publish bounded state for the UI owner task;
  they must not mutate LVGL objects directly.
- Map screen transitions must never reveal a frame rendered with the previous
  instance's profile. The full-screen-buffer and `full_refresh` display strategy
  remains unchanged.

### Why the current settings packet should not be extended again

The existing `SettingID: UInt8 | Value: Int32` packet is appropriate for a
single scalar, but an ordered graph of typed instances is one atomic document.
Encoding it as dozens of new setting IDs would introduce partial updates,
ambiguous retries, no safe readback, and no conflict detection. Keep IDs
`1...36` for compatibility and add a versioned configuration transaction for
the new model.

## User experience

### Device Screens list

Replace the expanded current-firmware section with a navigation row that opens
a dedicated editor when dynamic screen configuration is supported. The editor
contains:

- the ordered screen-instance list;
- a checkmark or `Default` badge on the startup instance;
- an enable switch on every row;
- drag handles while editing;
- an **Add Screen** button;
- row actions for **Duplicate**, **Rename**, and **Delete**; and
- **Cancel** and **Save** navigation actions.

Tapping a row opens its type-specific settings. The row subtitle shows the
stable type, so renamed duplicates remain understandable. Deleting or disabling
the current default immediately selects the first enabled draft row, but the
device is unchanged until Save succeeds.

The Add Screen sheet lists every screen type advertised by the connected
firmware. It disables the action at the device-advertised instance limit. A
new Map or Map + Navigation instance starts from that type's recommended
defaults. A duplicated instance copies the complete type payload but receives a
new non-zero instance ID and generated name.

### Per-instance Map settings

Refactor the existing `MapStyleSettingsView` so it edits a value-type draft
instead of reading and writing singleton `BLEManager` properties. Each Map
instance owns:

- detail level and minimum polygon size;
- zoom;
- route, street, and current-position marker sizes;
- feature, route-overlay, and current-position visibility;
- street-label visibility, density, language, size, and orientation; and
- north-up/course-up selection.

Each Map + Navigation instance owns the equivalent profile plus:

- bird's-eye enabled;
- bird's-eye perspective; and
- 3D buildings enabled.

Map + Navigation must retain its current semantic invariants: it follows GPS,
uses north-up before guidance and course-up during guidance, and owns the
guidance overlay. The ordinary Map rotation picker therefore applies only to
Map instances even though the wire profile has a stable per-type payload.

Brightness, automatic display off, disconnected sleep timeout, tap-to-cycle,
sound, and PWR-button honk remain device-wide settings. They are not copied into
each screen instance.

### Ride Stats layout editor

Use a device-shaped preview with seven assignable positions:

- `hero`: one full-width primary position; and
- `grid0...grid5`: the existing two-column by three-row metric positions.

Every supported widget must have a hero and compact renderer, including the
heart-rate zone strip. The editor supports drag-and-drop between positions and
a tap-to-choose fallback for accessibility. Selecting **Empty** hides that
position. Duplicate widgets are allowed because a rider may intentionally want
the same value in two sizes.

Schema v1 exposes the data already present in the firmware view model:

| ID | App label | Runtime meaning |
| ---: | --- | --- |
| `0` | Empty | Hide the slot. |
| `1` | Speed | Current speed; preserves the existing average-speed summary after the session ends. |
| `2` | Heart rate | Current heart rate; preserves the existing average-HR summary after the session ends. |
| `3` | Heart-rate zone | Five-zone visual strip; unavailable presentation when a five-zone value is absent. |
| `4` | Distance | Workout or legacy ride distance. |
| `5` | Moving time | Moving/workout elapsed time. |
| `6` | Elapsed time | Wall time when supplied by the workout origin frame. |
| `7` | Altitude | Current altitude in meters. |
| `8` | Route remaining | Remaining route distance. |
| `9` | Power | Cycling power in watts. |
| `10` | Cadence | Cycling cadence in rpm. |
| `11` | Average speed | Workout average speed. |
| `12` | Maximum speed | Workout maximum speed. |
| `13` | Calories | Active energy in kilocalories. |
| `14` | Average heart rate | Workout average heart rate. |
| `15` | Smart metric 1 | Existing first adaptive bottom metric selection. |
| `16` | Smart metric 2 | Existing second adaptive bottom metric selection. |

The default template reproduces the current screen:

```text
hero:  Speed
grid0: Heart rate          grid1: Heart-rate zone
grid2: Distance            grid3: Moving time
grid4: Smart metric 1      grid5: Smart metric 2
```

`Smart metric 1/2` preserve the current power/cadence/wall-time/navigation and
ended-summary selection behavior. Riders who want fixed boxes can replace
either smart widget with an explicit metric.

An unavailable metric renders `--` and stays in its assigned position. A real
sensor value of zero remains visible; availability must not be inferred from
the number. At least one of the seven positions must be non-empty.

The configurable layout is used for active, paused, ending, and ended workout
states. The current idle/navigation-only Start Workout and ride-detection
presentation remains system-owned in schema v1, as do the status line and ride
automation decision panel. Customization must not hide or move those controls.

## Architecture

```text
SwiftUI editor draft
        |
        v
DeviceScreenConfigurationController (device-scoped base revision)
        |
        v
authenticated, chunked BLE commit  --->  bounded firmware reassembler
                                           | validate complete document
                                           | write + verify inactive NVS slot
                                           | atomically publish runtime snapshot
        ^                                  v
        +----------- snapshot / ACK -------+
```

There are two important separations:

1. The persisted **logical instance list** is independent from the small set of
   reusable LVGL screen trees.
2. The app's editable **draft** is independent from the last device-acknowledged
   document.

This keeps duplicates cheap on the firmware and makes a failed BLE transaction
non-destructive on both sides.

## Canonical data model

Add equivalent Swift and C++ types, with one golden binary codec shared through
contract fixtures:

```text
ScreenConfigurationDocument
  schemaVersion: UInt8 = 1
  defaultInstanceID: UInt32
  instances: [ScreenInstance]       // order is the device cycle order

ScreenInstance
  id: UInt32                        // non-zero and unique
  type: ScreenType
  enabled: Bool
  name: UTF-8 string                // 1...24 bytes
  payload: type-specific payload

ScreenType
  0 Map
  1 Navigation
  2 Ride Stats
  3 Map + Navigation
  4 Battery Status
```

IDs `1...255` are reserved for deterministic firmware migration IDs. The app
generates new IDs with the high bit set using `SecRandomCopyBytes`, rejects zero
and collisions, and never derives identity from list position.

Type payloads are length-delimited and start with their own version byte:

- Map profile v1 contains `ScreenMapRenderSettings`, the full feature/overlay
  mask, label fields, and rotation mode.
- Map + Navigation profile v1 contains `ScreenMapRenderSettings`, the full
  feature/overlay mask, label fields, bird's-eye, perspective, and 3D-building
  fields.
- Ride Stats profile v1 contains layout kind `slotGridV1`, slot count `7`, and
  seven widget IDs.
- Navigation and Battery Status have an empty v1 payload. Keeping an instance
  payload envelope lets those types gain settings later without changing list
  identity or order.

Use an explicit binary codec, not platform `Codable` memory layout. Multi-byte
integers are little-endian. The document ends with a CRC-32 over all preceding
document bytes. Unknown document or payload versions are rejected rather than
silently rewritten. Unit tests must carry the same golden bytes in Swift and
C++.

Validation is centralized and identical in both implementations:

- schema is supported;
- encoded document is at most 4096 bytes;
- instance count is `1...16`;
- IDs are non-zero and unique;
- names are valid UTF-8, contain no control characters, and are `1...24` bytes;
- type and payload version are supported by the device;
- payload length exactly matches its version;
- scalar values use the existing map-setting clamps;
- seven Ride Stats slots are present, every widget is advertised, and at least
  one is non-empty;
- at least one instance is enabled; and
- the default ID identifies an enabled instance.

## BLE contract

### Capability and characteristic

Extend `protocol/ride-ble-contract-v1.json` and regenerate both language
outputs:

- add optional `screen_configuration` characteristic UUID
  `9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1005`;
- assign protected channel ID `8`;
- assign CAP2 feature bit `23`, `screen_configuration_v1`;
- raise the current client version from `20` to `21`; and
- advertise the feature only when the characteristic, reassembler, persistent
  store, and runtime configuration subsystem all initialized successfully.

The characteristic is authenticated owner-only, with write-with-response and
notify properties. A scoped Watch ride session cannot read or change screen
configuration. The firmware must fail closed if the ownership role cannot be
read safely.

Add CAP2 TLV type `2`, `screen_configuration_capabilities`, containing:

- document schema version;
- maximum instances;
- maximum name bytes;
- supported screen-type bitmask;
- supported Ride Stats widget bitmask;
- Ride Stats slot count; and
- maximum document bytes.

The app uses these advertised values to build the Add sheet and widget picker.
It must not expose values merely because a newer app enum knows about them.

### Transaction frames

All frames below are plaintext before the existing ownership-v2 protected
channel envelope is applied:

```text
App -> device: "SCRQ" | RequestID: UInt32LE

App -> device: "SCUP" | RequestID: UInt32LE |
               BaseRevision: UInt32LE |
               ChunkIndex: UInt8 | ChunkCount: UInt8 | Document bytes

Device -> app: "SCDN" | RequestID: UInt32LE |
               Revision: UInt32LE |
               ChunkIndex: UInt8 | ChunkCount: UInt8 | Document bytes

Device -> app: "SCAK" | RequestID: UInt32LE | Result: UInt8 |
               Revision: UInt32LE | DocumentCRC32: UInt32LE
```

Result values are stable protocol values:

| Value | Meaning |
| ---: | --- |
| `0` | Applied and durably committed. |
| `1` | Base revision conflict; request a fresh snapshot. |
| `2` | Malformed or failed document validation. |
| `3` | Unsupported schema/type/widget. |
| `4` | Persistent-store failure; previous document remains active. |
| `5` | Busy; bounded retry is allowed. |
| `6` | Unauthorized. |

`RequestID` is random and non-zero. `BaseRevision` is the revision from the
snapshot used to create the draft. Firmware assigns the next non-zero revision;
the app cannot choose it. A stale base never overwrites a newer device edit.

Chunk sizes are calculated from the negotiated write/notification length after
protected-frame and command headers. Reassembly is sequential, allows at most
160 chunks and 4096 bytes, and expires after five seconds. A new request ID,
out-of-order chunk, duplicate with different bytes, disconnect, timeout, or
size violation discards only the staging buffer. The active document is never
partially changed.

The app queues an upload as one grouped settings-control delivery. If an
acknowledged characteristic write fails, it abandons that request and retries
the complete document with a new request ID after refreshing the snapshot. It
does not retry individual chunks into an unknown device staging state.

Firmware keeps a small completed-request replay window. Repeating the exact
completed request returns the cached acknowledgement without incrementing the
revision or writing NVS again. Reusing a request ID with different bytes is
rejected.

### Commit ordering

On a complete upload, firmware must perform this sequence:

1. authenticate and authorize the owner session;
2. compare `BaseRevision` with the active revision;
3. decode and validate the complete candidate in bounded memory;
4. write the inactive NVS slot;
5. read it back and validate length, schema, revision, and CRC;
6. switch the committed `head` record;
7. mirror and verify the legacy compatibility projection, then record
   `mirrorRev`;
8. publish an immutable runtime snapshot to the UI owner task;
9. correct the active/default instance if required; and
10. send `SCAK success`.

No success acknowledgement is sent before persistence and readback complete.

## Firmware implementation

### 1. Pure protocol and model modules

Add small LVGL-free modules under `esp32/lib/ble_navigation/`:

- `screen_configuration_protocol.hpp` for constants, frames, chunking, codec,
  CRC, and validation;
- `screen_configuration.hpp/.cpp` for the bounded document model, active
  revision, migration, and A/B persistent store; and
- host tests with golden Swift/C++ documents and malformed-input coverage.

Use fixed-capacity arrays and bounded strings. Do not retain ArduinoJson trees
or allocate one heap object per widget during BLE parsing.

### 2. Atomic persistence and migration

Use a separate Preferences namespace such as `screenCfg` with keys shorter
than the ESP32 NVS key limit:

- `slotA` and `slotB`: complete blobs containing revision, document, and CRC;
- `head`: the last committed slot, revision, and blob CRC; and
- `mirrorRev`: the revision whose compatibility projection was completely
  mirrored to the legacy keys.

Each slot also records the digest of the legacy projection derived from its
document.

At boot, validate both slots and follow a valid `head`, otherwise recover the
highest valid revision and complete its compatibility mirror. If neither slot
is valid, migrate from the existing
`mapSettings` keys:

1. create one deterministic instance for every currently supported type;
2. set each instance's enabled flag from `screenMask`;
3. preserve the current cycle order;
4. map `defaultScreen` to that type's deterministic instance;
5. copy the existing Map and Map + Navigation profiles;
6. assign the current Ride Stats template; and
7. commit the result before advertising the new capability.

The migration is idempotent. A power loss at any point must either leave the
legacy settings usable or leave one complete new slot.

Every successful new-document commit also updates a compatibility projection:

- legacy screen mask = types with at least one enabled instance;
- legacy default = type of the default instance;
- legacy Map and Map + Navigation keys = first enabled instance of each type,
  falling back to the first stored instance of that type.

The commit writes and verifies the candidate slot, switches `head`, mirrors the
legacy keys, verifies their digest, and finally writes `mirrorRev`. If boot sees
`head.revision != mirrorRev`, it finishes that internal mirror idempotently
before comparing digests. Once the revisions match, a later legacy-digest
change means older firmware edited those keys. Import those changes into the
primary instances, preserve duplicate instances and ordering, and commit a new
revision. This avoids both mistaking an interrupted internal mirror for an old
firmware edit and silently losing valid edits across a downgrade/re-upgrade
cycle.

### 3. Logical instance cycle

Replace `DEVICE_SCREEN_CYCLE_ORDER` traversal with a bounded runtime snapshot:

```text
activeInstanceIndex
activeInstanceID
ordered ScreenInstance[instanceCount]
```

`showScreenInstance(index)` becomes the single entry path for startup, PWR
button, tap cycle, guidance overlay cycle strip, active-screen correction, and
tests. It:

- skips disabled instances;
- records instance identity before selecting the reusable tile;
- applies the instance payload;
- invokes all existing type-entry semantics; and
- schedules render/update work through the UI owner task.

Keep one `mapTile`, `navTile`, `rideStatsTile`, and `batteryStatusTile`.
Navigation and Battery duplicates therefore cost only document bytes. If a
commit disables or removes the active instance, switch to the configured
default. Changing only the default does not interrupt the currently visible
screen.

### 4. Per-instance map profiles

Replace type-only `mapStyleSettingsForTile(tileName)` lookups with an active or
target instance profile. `currentMapStyleSettings()` may continue to expose a
const reference, but its backing snapshot must have a lifetime that spans the
render job.

Map render jobs and prepared-frame metadata must include:

- target instance ID;
- screen type;
- profile/style signature; and
- projection signature.

Render-ahead finds the next enabled **instance** backed by a map, not merely the
next map type. Switching Map A -> Map B must start a transition even though both
use `mapTile`. A prepared or published frame can be revealed only when its
instance/profile signatures match the target. This preserves the current rule
that a stale source profile is never shown while the destination renders.

Do not create another map canvas or full-screen buffer per instance. Preserve
the current shared front/back renderer and four-block bounds.

### 5. Generic Ride Stats slots

Refactor `rideTelemetryScr.cpp` from metric-specific global label pointers to
seven reusable slot views. Each slot knows its shape (`hero` or `compact`) and
renders the widget ID from the active Ride Stats instance.

Add a pure `ride_stats_widget.hpp` layer that maps a widget ID and existing
`ride_telemetry_presenter::ViewModel` to:

- title;
- formatted value and unit;
- availability;
- scalar, heart-with-value, or zone-strip presentation; and
- hero/compact font constraints.

Keep the existing integer-based formatters and adaptive font selection; do not
reintroduce `%f`, because LVGL float formatting is disabled in this firmware.
Keep the current five-zone colors and freshness semantics.

`rideTelemetryLayout.hpp` should expose the seven stable slot rectangles for
both display geometries. Tests must prove every widget variant fits every slot,
including long elapsed times, kilometer distances, cadence decimals, and the
five-zone strip. The idle Start Workout and automation overlays keep their
current separate placement.

Changing from Ride Stats A -> Ride Stats B rebinds and updates the seven
existing slot views immediately. It does not recreate the LVGL object tree.

### 6. BLE and diagnostics integration

Create the optional characteristic alongside the existing authenticated
characteristics in `ble_navigation.cpp/.hpp`. Route protected writes to a
bounded reassembler and send snapshot/ack notifications through the existing
deferred notification path.

Add concise diagnostics without user content:

- active revision and instance count at boot;
- migration source and result;
- commit request ID, result, revision, and byte count;
- active instance ID/type on screen switch; and
- map transition instance/profile signature mismatch rejections.

Do not log custom screen names or raw document bytes.

## iOS implementation

### 1. Separate model, transport, and editor state

Do not add another large set of singleton properties to `BLEManager`. Add:

- `Models/DeviceScreenConfiguration.swift`: value types, validators, defaults,
  binary codec, widget catalog, and instance-ID generation;
- `Managers/DeviceScreenConfigurationController.swift`: `@MainActor`
  connection/snapshot/commit state, draft lifecycle, conflict handling, and
  last-acknowledged cache; and
- a small BLE transport surface on `BLEManager` for characteristic discovery,
  capability parsing, grouped writes, and notification forwarding.

The controller state should distinguish `loading`, `ready`, `saving`,
`conflict`, `failed`, and `legacyUnsupported`. A transport-level GATT success is
not presented as an applied save; only `SCAK success` is.

### 2. Device-scoped cache

Cache only the last device-acknowledged document and revision under the stable
ownership `deviceID`. The cache supports fast UI presentation but is not sent
until a fresh authenticated snapshot confirms the base revision. Clear it when
`BikeComputerDeviceRegistry` successfully forgets or deregisters that device.

Schema v1 does not support offline commits. If the device disconnects while an
editor is open, preserve the unsaved draft in memory, disable Save, and offer to
reload or compare after reconnect. Never silently apply a stale draft to a
different active device.

### 3. Connection flow

After authentication and CAP2 negotiation:

1. discover and subscribe to the screen-configuration characteristic;
2. parse the capability TLV;
3. send `SCRQ`;
4. reassemble and validate `SCDN`;
5. bind the snapshot to the exact connected `deviceID` and BLE generation; and
6. enable the dynamic editor.

Disconnect, peripheral change, auth generation change, invalid capability, or
notification timeout cancels all screen-configuration requests and draft-save
callbacks from the old session.

### 4. SwiftUI views

Add focused views rather than growing `SettingsView.swift` further:

- `DeviceScreensSettingsView` for list/add/reorder/default/save;
- `DeviceScreenInstanceEditorView` for common rename/enable actions and
  type-specific routing;
- `RideStatsLayoutEditorView` and a reusable preview/slot picker; and
- a value-bound Map profile editor extracted from the existing private view.

The preview uses sample values and clearly labels itself as a preview. It offers
VoiceOver reorder actions, descriptive slot labels such as `Top left`, Dynamic
Type outside the fixed-ratio preview, and a non-drag picker path. Color is not
the only indication of the selected/default state.

For legacy firmware, retain the current `DeviceScreensSettingsSection`,
settings IDs `13/14`, and singleton Map profile screens unchanged. Do not show a
nonfunctional Add button with an update-firmware error after every tap.

### 5. Save and conflict behavior

Before enabling Save, validate the complete draft with the advertised limits.
On Save:

- freeze a canonical encoded document;
- create one random request ID;
- upload it against the snapshot revision;
- show progress for the logical transaction, not individual chunks; and
- replace the acknowledged snapshot/cache only on matching success ACK and
  CRC.

On conflict, keep the draft, fetch the new snapshot, and show **Reload Device
Settings**. Automatic field-level merging is out of scope for schema v1 because
reorder/delete conflicts are ambiguous.

## Compatibility behavior

| App | Firmware | Behavior |
| --- | --- | --- |
| New | New | Dynamic instance editor, per-instance profiles, atomic save/readback. |
| New | Old | Existing type toggles/default and singleton Map profiles; no duplicates or workout layout editor. |
| Old | New | Existing setting IDs remain accepted through the compatibility adapter; duplicate instances continue to cycle but are invisible to the old app. |
| Old | Old | No change. |

On new firmware, legacy setting IDs behave as follows:

- ID `13` enables/disables all instances of each represented type. Enabling a
  type with no stored instance creates its deterministic default instance.
- ID `14` selects the first enabled instance of the requested type.
- Map IDs update only the designated primary instance for that Map type, so an
  old app cannot overwrite every duplicate profile.
- A short debounce batches the legacy app's reconnect settings burst into one
  validated document revision and NVS commit.

The old bitmask and scalar keys remain compatibility projections, not a second
source of truth while the new firmware is running.

## Validation plan

### Contract and codec tests

- Update generator tests for characteristic UUID, channel `8`, feature bit
  `23`, client version `21`, and CAP2 TLV type `2`.
- Decode the same golden configuration in Swift and C++ and re-encode byte for
  byte.
- Cover truncated headers/payloads, bad CRC, unknown versions, duplicate IDs,
  invalid UTF-8, oversized names/documents, unsupported types/widgets, empty
  screen list, all-disabled list, bad default, and invalid scalar ranges.
- Cover chunk timeout, out-of-order, conflicting duplicate, request-ID replay,
  stale base revision, and interrupted transfer.

### Firmware host tests

Add or extend tests for:

- A/B slot selection, readback failure, corrupt active slot, and power-loss
  cut points;
- legacy migration and downgrade/re-upgrade digest reconciliation;
- arbitrary instance order, duplicate types, disabled entries, single-entry
  cycling, active deletion, and default fallback;
- Map A -> Map B and Map + Navigation A -> B profile selection;
- render-ahead identity/signature validation;
- every Ride Stats widget in hero and all compact positions at 410 x 502 and
  466 x 466;
- unavailable versus zero metrics;
- the default smart-metric behavior and ended summary; and
- owner-only access and notification queue bounds.

Keep pure policy in host-testable headers so these checks do not require LVGL,
NimBLE, or hardware.

### iOS tests

- Model/codec/validation and deterministic encoding.
- Random instance IDs are non-zero, high-bit-set, and collision-checked.
- Add, duplicate, rename, reorder, enable/disable, delete, and default fallback.
- Draft changes never mutate the acknowledged snapshot before ACK.
- Success, conflict, malformed, persistence failure, busy retry, timeout,
  disconnect, reconnect generation, and wrong-device notification handling.
- Device-scoped cache isolation and cleanup on forget/deregister.
- Capability filtering for screen types and workout widgets.
- Legacy firmware retains exactly the current packet behavior.
- SwiftUI accessibility identifiers and non-drag slot selection.

Add the new model/controller sources to
`ios-app/scripts/run-navigation-tests.sh` and the relevant Xcode targets.

### Build and static gates

Run from a clean implementation worktree:

```sh
python3 tools/generate_ride_ble_contract.py --check
ios-app/scripts/run-navigation-tests.sh
cd esp32 && python3 -m unittest discover -s tools/tests
cd esp32 && python3 tools/build_firmware.py WAVESHARE_AMOLED_175
cd esp32 && python3 tools/build_firmware.py WAVESHARE_AMOLED_206
git diff --check
```

Use the repository firmware wrapper rather than raw `pio run`. Run focused C++
host tests with `-std=c++17 -Wall -Wextra -Werror`, and add them to the CI Gate.
An unsigned iOS app build plus the existing workout/navigation suites is
required in addition to the host executable.

### Physical validation gates

Physical validation is not part of creating this plan. Before any later flash,
re-identify the connected board and obtain the required device-specific
confirmation.

Run the eventual feature on both the 466 x 466 1.75-inch target and the
410 x 502 2.06-inch target:

1. Upgrade from a device with customized legacy mask/default/Map profiles and
   confirm migration is visually and behaviorally unchanged.
2. Create two Maps with visibly different zoom/detail/labels and cycle between
   them in both directions.
3. Create two Map + Navigation instances with flat/bird's-eye and different
   perspectives; test before and during navigation.
4. Create two Ride Stats instances with different widget orders, including the
   zone strip in hero and compact positions, power/cadence zero, unavailable
   values, a paused workout, and an ended workout.
5. Reorder, disable, change default, delete the active instance, reboot, deep
   sleep/wake, disconnect/reconnect, and verify exact persistence.
6. Interrupt every upload phase by disconnecting or resetting and confirm the
   prior configuration survives.
7. Fill all 16 instances and verify cycling, editor responsiveness, NVS usage,
   BLE queue bounds, and free heap.
8. Exercise an old-app/new-firmware and new-app/old-firmware pair before release.

Record source SHA, firmware target/profile, app build, device serial, migration
source, and the final device-reported configuration revision. Build success is
not a substitute for these hardware gates.

## Performance and memory gates

- No full-screen LVGL tree, framebuffer, or map canvas is allocated per logical
  instance.
- Configuration parsing and staging have fixed maximum memory derived from the
  4096-byte document limit.
- Non-map duplicate switching must stay within the existing input-to-visible
  update budget; establish and compare a baseline before implementation.
- Map switching may wait for rendering but must keep the destination concealed
  until its instance/profile signature is published.
- Measure minimum internal heap and PSRAM across a 16-instance cycle and a
  workout-plus-navigation session. Do not accept an unbounded per-switch leak.
- BLE configuration traffic must not starve critical ride-delivery,
  navigation-clear, workout, or ownership messages. Configuration uses the
  bounded settings-control lane and cannot run in a scoped Watch-only session.

## Delivery sequence

Keep the capability bit clear until the complete path is ready.

1. **Contract and pure models:** generated contract additions, binary codec,
   validators, golden vectors, and host tests.
2. **Firmware storage and runtime list:** A/B NVS, migration, compatibility
   projection, logical cycle, and map-instance selection behind an unadvertised
   feature flag.
3. **Ride Stats renderer:** generic slots and widget catalog with both display
   geometries fully host-tested.
4. **iOS sync and editor:** controller, characteristic transport, dynamic list,
   Map value binding, workout preview, and legacy fallback.
5. **Integration:** advertise CAP2 bit `23`, update `docs/ble-protocol.md`, add CI
   gates, and complete the compatibility matrix.
6. **Physical qualification:** both hardware targets, upgrade/fault-injection,
   performance, navigation, and workout tests.

The app can ship before the firmware because it retains the legacy path. New
firmware is also safe with the old app through the compatibility adapter. Do
not remove the old settings path in the same release as this feature.

## Main files expected to change

| Area | Existing/new paths |
| --- | --- |
| Contract | `protocol/ride-ble-contract-v1.json`, `tools/generate_ride_ble_contract.py`, generated Swift/C++ files, generator tests |
| Firmware protocol/storage | `esp32/lib/ble_navigation/screen_configuration_protocol.hpp` (new), `screen_configuration.hpp/.cpp` (new), `device_capabilities_protocol.hpp`, `ble_navigation.cpp/.hpp` |
| Firmware screen runtime | `esp32/lib/gui/src/mainScr.cpp/.hpp`, `mainScreenEntryPolicy.hpp`, map render-ahead policy/tests |
| Firmware Ride Stats | `rideTelemetryScr.cpp`, `rideTelemetryLayout.hpp`, `rideTelemetryPresenter.hpp`, `ride_stats_widget.hpp` (new) |
| iOS model/controller | `Models/DeviceScreenConfiguration.swift` (new), `Managers/DeviceScreenConfigurationController.swift` (new), `BLEManager.swift`, `DeviceOwnership.swift` |
| iOS UI | `Views/SettingsView.swift`, `DeviceScreensSettingsView.swift` (new), `RideStatsLayoutEditorView.swift` (new), extracted Map profile editor |
| Documentation/tests | `docs/ble-protocol.md`, focused firmware host tests, iOS protocol/controller tests, `ios-app/scripts/run-navigation-tests.sh`, `.github/workflows/ci.yml` |

## Out of scope for schema v1

- arbitrary user-drawn pixel geometry;
- user-selectable fonts, colors, units, or number precision;
- creating new screen types or telemetry sources in the app;
- moving the Start Workout control, status line, or ride-automation panel;
- synchronizing device screen layouts to Apple Watch or iCloud;
- offline configuration commits; and
- removing the legacy mask/default/scalar settings protocol.

## Completion criteria

The feature is complete only when all of the following are true:

- [ ] The app can add at least two instances of every advertised existing type.
- [ ] Instance order, enabled state, names, default, and typed settings survive
      reconnect, reboot, and deep sleep.
- [ ] Two instances of the same Map type render their own settings without a
      stale intermediate frame.
- [ ] Two Ride Stats instances can place every advertised widget in every slot,
      including an empty slot, without clipping on either display target.
- [ ] Saving is atomic, revision-checked, read back, and acknowledged only after
      durable persistence.
- [ ] Interrupted, malformed, unauthorized, stale, or failed writes leave the
      previous active document intact.
- [ ] New/old app and firmware combinations follow the documented compatibility
      matrix.
- [ ] Exact-head CI passes the generated-contract, Swift host, C++ host, iOS
      build/test, and both firmware-target gates.
- [ ] Both hardware targets pass the physical migration, cycling, workout,
      navigation, fault-injection, memory, and persistence checks.
