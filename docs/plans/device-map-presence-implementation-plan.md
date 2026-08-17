# Device-Reported Saved Map Presence Implementation Plan

## Status and scope

This plan was authored from freshly fetched `origin/main` at
`95880ff88ba96b01abf714c13ad2107ed3110535` on 2026-08-17. It is an
implementation contract for the accompanying branch, not a claim that the
feature has shipped. The software changes and automated coverage are
implemented on this branch; the cloned-SD physical-device acceptance check
remains a release validation step.

The feature makes the iOS **Saved Maps** section reflect the map that is
currently active on the connected bike computer even when the corresponding
map pack is not cached on that iPhone. The primary acceptance case is a cloned
SD card moved into another bike computer and connected to a different iPhone.

This is deliberately an active-map feature, not a multi-map library. Firmware
continues to select one usable map through `/VECTMAP/active-map.json`; inactive,
rollback, staging, and orphaned folders are not presented as user-selectable
maps.

## Outcome

The Saved Maps list becomes the union of:

1. map packs cached by the Bicino app on this iPhone; and
2. the active map descriptor reported by the currently authenticated bike
   computer.

Each row reuses the existing saved-map state indicator: a round upload arrow
when a local map can be sent to the device, or a green check when the exact map
is active. No separate phone or bike-computer symbol is shown. A local trash
button indicates that the map is cached on the iPhone; its absence identifies a
device-only row.

A device-only map receives the same style of map preview as an iPhone-cached
map. The iPhone generates that preview from trusted, bounded geographic
metadata; firmware does not send PNG bytes over BLE. Tapping an available
thumbnail opens that rendered preview in a modal.

## Current main-branch behavior

### iPhone saved-map inventory

`OfflineMapManager.refreshCachedPacks()` enumerates only `.bmap` and `.zip`
files under the iPhone cache directory `OfflineMapPacks`. `SettingsView` then
renders one `DownloadedMapRow` for each `cachedPackURL`. A map that exists only
on the SD card therefore cannot create a Saved Maps row.

The current row contains:

- the locally resolved preview;
- an editable local display name;
- a gray upload icon when the local pack is not active on the device;
- a green checkmark when local map and active device session match; and
- a trash action that removes only the iPhone copy.

### Device-reported state

The existing authenticated `MSTS`/`MSTC` map-transfer status already reports:

- `sdPresent`;
- `activeMapId`;
- `activeSessionId`;
- `activeManifestReceipt`;
- renderer/label metadata; and
- activation progress and errors.

`BLEManager` parses those fields, and `OfflineMapManager.isCachedPackInstalled`
uses the map ID plus the content/session identity to avoid claiming that a
regenerated pack for the same area is already installed.

The status does not currently expose the active map's display name or bounds.
The iOS app also has no row model for a map without a local pack URL.

### Installed manifest metadata

The signed map manifests already contain the required presentation metadata:

- `displayName`;
- `bounds` in ZIP manifests;
- normalized `boundsE7` in Bike Map Stream manifests; and
- optional preview data intended for local pack presentation.

Current firmware validates and stores the installed manifest but ignores
`displayName`, `bounds`, and `boundsE7` in its `MapManifest` model. The feature
can therefore be implemented without changing map generation or transferring
preview images from the SD card.

## Product contract

### Presence states and icons

| Exact artifact state | State indicator | Local delete button | Primary interaction |
| --- | --- | --- | --- |
| Cached only on this iPhone | Existing round `arrow.up.circle` | Visible | Tap the arrow to transfer |
| Active only on the connected device | Existing green `checkmark.circle.fill` | Hidden | Status only |
| Cached on this iPhone and active on the device | Existing green `checkmark.circle.fill` | Visible | Tapping the check may retain the existing “Already on Device” explanation |
| Upload in progress | Existing upload progress/resume treatment | Visible | Existing pause/resume behavior remains authoritative |

Do not show a separate iPhone or bike-computer symbol. The state indicator is
the same regardless of where the row originated. The local trash button is the
visual distinction between a local row and a device-only row, while
accessibility text states explicitly when the map is not saved on the iPhone.

Inactive device packs remain outside this active-map-only protocol. If a future
device inventory exposes them, use the same round upload/activation arrow and
omit the local trash button.

Accessibility labels must describe the complete state, for example:

- `Saved on this iPhone`;
- `Not saved on this iPhone`;
- `Active on bike computer`; and
- `Transfer <map name> to bike computer`.

### Row behavior

- The active device row sorts first.
- A device-only row is not renameable because changing the iPhone label would
  not rename the signed map metadata on the SD card.
- A device-only row has no trash button. Remote deletion is outside this
  feature.
- A merged phone-and-device row keeps the existing local rename behavior and
  prefers the iPhone's user-defined name for presentation.
- Deleting the local copy from a merged row leaves a device-only row visible
  while the device remains connected. The existing confirmation must continue
  to state that the map on the bike computer remains.
- The `Download a new Map` action remains unchanged.
- Replace the misleading empty-state copy `0 maps downloaded yet` with
  `No offline maps yet` when neither a local nor live device map is available.

### Connection and freshness

Device presence is live, connection-scoped state:

- publish a device-only row only after a complete authenticated map-status
  response has been parsed;
- clear the live descriptor on disconnect, local forget, authentication reset,
  SD removal, or a later valid status with no active map;
- never leave a green device indicator based only on stale persisted state;
- keep local rows visible while disconnected, with the neutral gray `b`
  transfer state disabled until navigation BLE is ready; and
- request a fresh map status through the existing status request after the
  connection becomes navigation-ready.

A future feature may show a clearly labeled “last seen” map, but this plan does
not persist live device presence as current truth.

## Identity and merge rules

`mapId` identifies a logical area, not necessarily one generated artifact.
Rows must therefore merge only when content identity is proven.

Use this matching order:

1. compare the active `sessionId` with the local signed manifest receipt,
   expected active session, or last transferred session already accepted by
   `isCachedPackInstalled`;
2. for legacy ZIP packs, derive the existing manifest-based transfer session
   identity and compare it with `activeSessionId`;
3. if firmware reports an active map ID but no session identity, show a
   conservative device-only row rather than marking an arbitrary same-area
   local pack active.

If a local pack and device map share `mapId` but not content identity, show
them as distinct rows. This avoids a false “on both” state and preserves the
user's ability to upload the newer/different iPhone copy.

Define a pure, host-testable model such as:

```swift
struct DeviceActiveMapDescriptor: Equatable, Sendable {
    let mapID: String
    let sessionID: String?
    let manifestReceipt: String?
    let displayName: String?
    let bounds: OfflineMapPreviewBounds?
}

struct SavedMapListItem: Identifiable, Equatable {
    let identity: SavedMapContentIdentity
    let localPackURL: URL?
    let activeDeviceMap: DeviceActiveMapDescriptor?
    let displayName: String
}
```

The exact names may change during implementation, but identity resolution and
row merging must remain independent of SwiftUI rendering.

## BLE status extension

Extend the existing map-transfer status additively; do not add a BLE UUID or a
second status command.

When presentation metadata is valid, firmware adds:

```json
{
  "activeMapId": "custom-map-6354c43431",
  "activeSessionId": "<content identity>",
  "activeMapDisplayName": "Shanghai and Suzhou",
  "activeMapBoundsE7": [1209000000, 307000000, 1219500000, 315500000]
}
```

Requirements:

- retain every existing status field and meaning;
- continue using authenticated `MSTS` when it fits and authenticated `MSTC`
  chunks otherwise;
- never place `preview.dataBase64` or other image data in BLE status;
- bound and JSON-escape the display name before serialization;
- validate four bounds coordinates, longitude/latitude ranges, and strict
  minimum/maximum ordering;
- prefer `boundsE7`; accept and safely convert legacy finite `bounds` values;
- omit invalid optional presentation metadata without hiding an otherwise
  valid active map; and
- keep the serialized response below the existing 255-chunk ceiling under the
  minimum supported authenticated chunk payload.

Older iOS builds ignore the additive fields. New iOS builds continue to work
with older firmware by falling back to `activeMapId`, a generated display name,
and the generic map placeholder when name or bounds are absent.

## Firmware implementation

### Presentation metadata parsing

Add bounded optional presentation fields to the map-transfer domain rather
than parsing arbitrary manifest JSON directly in `ble_navigation.cpp`.

Recommended changes:

1. Add a small `MapPresentationMetadata` value to
   `esp32/lib/map_transfer/map_transfer.hpp` or a focused adjacent header.
2. Extend the installed-manifest reader in
   `esp32/lib/map_transfer/map_transfer.cpp` to parse `displayName`,
   `boundsE7`, and legacy `bounds` as optional presentation data.
3. Treat malformed presentation data as unavailable, not as a reason to reject
   a map that passes the existing renderer/file integrity checks.
4. Expose one read-only `readActiveMapPresentation(...)` operation that binds
   presentation data to the same active root selected by `active-map.json`.
5. Reuse a pure JSON-serialization helper for the new status fields so host
   tests can cover escaping, bounds, omission, and size behavior without
   compiling NimBLE/LVGL globals.

The reader must not enumerate `/VECTMAP/.maps`, staging directories, or rollback
roots. Only the map selected by the validated active-map record is surfaced.

### Status publication

Update `esp32/lib/ble_navigation/ble_navigation.cpp` to append the optional
name and E7 bounds to `mapTransferStatusJson()`. Preserve the current status
chunk transfer-ID behavior: identical response bodies reuse their transfer ID,
and a changed active descriptor produces a new transfer ID.

If SD metadata changes while connected, the next explicit or lifecycle status
request must replace the entire iOS descriptor atomically. Partial chunks must
never publish a half-updated row.

## iOS implementation

### Atomic active-map descriptor

Add a single published `DeviceActiveMapDescriptor?` to `BLEManager` and build
it only after the complete `MSTS` body or all `MSTC` chunks have parsed.

The parser must:

- validate map ID and optional session/receipt lengths;
- decode `activeMapBoundsE7` using the same geographic invariants as
  `OfflineMapPreviewBounds`;
- trim or reject empty display names;
- publish `nil` when `activeMapId` is absent or invalid;
- clear the descriptor wherever existing map-transfer active fields are reset;
  and
- preserve current published fields for transfer, activation, label, and
  compatibility consumers.

Keep descriptor assignment logically atomic even if legacy scalar properties
remain for existing callers.

### Merged Saved Maps model

Move Saved Maps row construction out of the direct
`ForEach(manager.cachedPackURLs)` path. Add a pure builder that accepts:

- the ordered local pack URLs and their derived identities/metadata; and
- the current optional `DeviceActiveMapDescriptor`.

It returns `SavedMapListItem` values with the active device item first, exact
matches merged, and remaining local packs in their current modification order.

Refactor `isCachedPackInstalled` to share the same identity matcher rather than
maintaining two definitions of “same artifact.” Existing transfer recovery and
activation decisions must continue to use content identity, not display name
or bounds.

### Device-only previews

Reuse `OfflineMapSnapshotPreviewRenderer` for a device-only descriptor with
valid bounds:

1. immediately publish the existing lightweight bounds fallback;
2. request the MapKit snapshot asynchronously;
3. validate meaningful visual variation as existing local snapshots do;
4. cache the PNG under an identity-derived filename in a dedicated
   `DeviceMapPreviews` cache directory; and
5. replace the fallback only if the descriptor/task token is still current.

Do not synthesize a fake artifact URL or place device-only previews beside
local `.bmap`/`.zip` files. Use a distinct cache API keyed by the normalized
map/session identity. Bound the cache by count or age so SD swaps do not create
unbounded files.

When bounds are unavailable, invalid, or MapKit fails, display the existing
generic map placeholder. Lack of a preview must not hide the row.

### SwiftUI row

Refactor `DownloadedMapRow` into a row that accepts `SavedMapListItem` rather
than requiring a local `packURL`.

Use the existing upload and installed-state SF Symbols directly in the saved
map row; no origin-specific icon component is needed.

Preserve the current upload enablement conditions, background upload resume
behavior, installed confirmation, rename commit behavior, and local delete
confirmation. Gate controls by the row's actual capabilities:

- rename and trash require `localPackURL`;
- upload requires `localPackURL` and a nonmatching device identity;
- a device-only row exposes no action that implies downloading the map back to
  the iPhone; and
- the active device indicator remains visible when there is no local pack.

Make the rendered thumbnail a plain button whenever a preview is available.
Capture the displayed image at tap time and present it scaled to fit in a modal
with the map display name, a Close action, and an accessibility label that
describes the preview action. A still-loading placeholder must not open an
empty modal.

## Compatibility and failure behavior

| Situation | Required behavior |
| --- | --- |
| New iOS + new firmware + cloned current SD | Device-only row, green check, no trash, manifest name, generated preview |
| New iOS + older firmware with active ID/session | Device-only row, green check, no trash, ID-derived name, placeholder preview |
| New iOS + older firmware with active ID but no session | Conservative device-only row; do not merge with same-area local pack |
| Old iOS + new firmware | Existing Saved Maps behavior; additive fields ignored |
| Missing or invalid active manifest | No phantom device-only row; retain valid local rows |
| Valid active map with malformed optional name/bounds | Device-only row with safe fallback name/preview |
| SD removed after connection | Fresh status clears the device descriptor and active green-check state |
| Incomplete/lost `MSTC` response | Keep the previous complete descriptor until a complete replacement or connection reset; never publish partial data |
| Same map ID, different sessions | Separate device-active and local rows |
| MapKit unavailable/offline | Bounds fallback or generic map placeholder; row remains usable |

## Expected file changes

Firmware and protocol:

- `esp32/lib/map_transfer/map_transfer.hpp`
- `esp32/lib/map_transfer/map_transfer.cpp`
- `esp32/lib/ble_navigation/ble_navigation.cpp`
- a small host-testable status/presentation helper if needed
- `esp32/tools/tests/test_map_transfer.cpp`
- `esp32/tools/tests/test_map_transfer_status_chunk_session.cpp` or a focused
  new status-payload test
- `docs/ble-protocol.md`

iOS:

- `ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift`
- `ios-app/BikeComputer/BikeComputer/Managers/OfflineMapManager.swift`
- `ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift`
- optionally a focused
  `ios-app/BikeComputer/BikeComputer/Models/SavedMapPresence.swift`
- the Xcode project and host-test source list if a new Swift file is introduced
- `ios-app/BikeComputerTests/NavigationProtocolTests.swift`
- `ios-app/BikeComputerTests/SavedMapPreviewCatalystTests.swift`

The map-platform generator should require no production change because current
manifests already contain display name and bounds. Add or adjust backend tests
only if implementation exposes a missing contract in archive/stream manifest
normalization.

## Implementation sequence

1. **Extract and test active presentation metadata in firmware.** Add
   best-effort name/bounds parsing bound to the validated active map root.
2. **Extend authenticated map status.** Serialize optional presentation fields,
   document them, and verify direct and chunked transport size behavior.
3. **Parse an atomic device descriptor on iOS.** Cover full, missing, malformed,
   chunked, retransmitted, and reset payloads.
4. **Build the pure merged-row model.** Reuse exact session/receipt matching and
   cover every local/device combination before changing SwiftUI.
5. **Add device-only preview loading and caching.** Reuse the existing snapshot,
   validation, cancellation, and stale-result protections.
6. **Replace row status controls with phone and round-`b` indicators.** Preserve
   upload, rename, delete, progress, and accessibility behavior.
7. **Run host, app, firmware-build, and physical cloned-SD acceptance gates.**

## Verification plan

### Firmware host tests

Add coverage for:

- stream `boundsE7` and legacy `bounds` parsing;
- coordinate range/order rejection;
- display-name escaping, empty values, control characters, and size bounds;
- valid active map with absent/malformed optional presentation metadata;
- selection of only the `active-map.json` root;
- unchanged core manifest validation and installed receipt behavior;
- additive JSON fields and omission behavior;
- direct `MSTS` versus chunked `MSTC` behavior; and
- status bodies remaining within the chunk-count ceiling.

Run at minimum the CI-equivalent map-transfer and status host tests, including
`test_map_transfer` and `test_map_transfer_status_chunk_session`, with
`-Wall -Wextra -Werror` for any new pure helper.

### iOS host and Catalyst tests

Add coverage for:

- parsing the new descriptor from direct and chunked status;
- clearing it on a status without an active map and on disconnect/reset;
- no publication from incomplete chunks;
- local-only, device-only, exact merged, same-ID/different-session, and empty
  list construction;
- active-first stable ordering;
- device-only preview fallback, MapKit replacement, disk restoration, cache
  invalidation, and stale async completion;
- absence of rename/delete/upload actions when no local pack exists;
- local deletion converting a merged row into device-only; and
- accessibility labels for both indicators.

Run:

```sh
cd ios-app
./scripts/run-navigation-tests.sh
```

Then build the complete iOS app through `scripts/xcodebuild-cli.sh` using an
isolated DerivedData directory and no code signing, matching the repository CI
configuration.

### Firmware builds

Build both supported production targets through the repository-owned firmware
runtime:

```sh
cd esp32
python3 tools/build_firmware.py WAVESHARE_AMOLED_175_PRODUCTION
python3 tools/build_firmware.py WAVESHARE_AMOLED_206_PRODUCTION
```

No firmware flash is part of implementation until the connected physical
device is identified and explicit pre-flash confirmation is obtained.

### Physical cloned-SD acceptance

Use a verified exact clone containing the hidden active stream state,
`active-map.json`, and its ready/receipt files.

1. Start with an iPhone/app installation that has no matching local map pack.
2. Insert the cloned SD card into the identified compatible Bicino device.
3. Boot and confirm SD mount, active map selection, and normal map rendering.
4. Connect and authenticate the other iPhone.
5. Open Saved Maps and confirm the active map appears first.
6. Confirm the active green check is shown, there is no iPhone icon, and there
   is no local trash action.
7. Confirm the manifest-derived display name appears.
8. Confirm the bounds fallback appears promptly and the MapKit snapshot replaces
   it when available, then tap the thumbnail and confirm the preview opens in a
   modal.
9. Reboot/reconnect and confirm the same identity and preview are restored.
10. Remove or swap the SD card, request fresh status, and confirm the green
    device presence is not retained incorrectly.
11. Download the exact same artifact to the iPhone and confirm the row remains a
    single green-check row and gains the local trash action.
12. Test a same-map-ID but different-session local pack and confirm it does not
    receive a false active state.

## Acceptance criteria

The implementation is complete only when all of the following are true:

- A current cloned SD map appears in Saved Maps on a different, otherwise
  empty iPhone after an authenticated connection.
- The row accurately distinguishes phone absence from device-active presence
  through the local trash action and an explicit accessibility hint.
- The state indicator is the existing round arrow when inactive/uploadable and
  the existing green check when active, regardless of row origin.
- A device-only map receives a bounds-derived preview without transferring PNG
  data over BLE.
- Tapping an available Saved Maps thumbnail opens the displayed preview in an
  accessible, dismissible modal; a loading placeholder does not open one.
- Exact local/device identities merge; same-area different artifacts do not.
- Device-only rows cannot be renamed, locally deleted, or mistaken for an
  iPhone download.
- Existing local map download, rename, preview, upload/resume, installed
  confirmation, and delete behavior remains intact.
- Old firmware and old iOS compatibility behavior remains safe.
- Firmware host tests, iOS helper/Catalyst tests, complete iOS build, and both
  firmware production builds pass.
- Physical cloned-SD behavior is verified on an identified device after the
  required flash approval and boot validation.

## Explicit non-goals

- Enumerating every folder or rollback artifact on the SD card.
- Turning the bike computer into a selectable multi-map library.
- Copying a map pack from the bike computer back to the iPhone.
- Sending preview PNG bytes over BLE.
- Renaming or deleting device-only maps.
- Changing map generation, map activation, rollback, or pruning semantics.
- Adding a new BLE service or characteristic.
- Persisting stale device presence as if it were live.
