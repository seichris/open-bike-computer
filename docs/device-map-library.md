# Device map library

Completed maps stay in their existing `/VECTMAP/.maps/<session>` folders.
Installing Chengdu no longer prunes a completed Shanghai installation. Abandoned
upload staging remains recoverable or reclaimable through the existing protocol.

## App behavior

Settings shows **Maps on this Bike Computer**, with installed payload sizes,
**Available offline** and **In use** states, a **Use** action, and an automatic
selection toggle. Swiping an inactive map exposes explicit SD removal with a
confirmation bound to that phone connection and device identity. iPhone files
and cloud-library references are separate from SD removal.

When the upload action finds an exact verified signed version in a fresh device
inventory, it selects that installation over authenticated BLE. No map payload
or Wi-Fi session is sent. A different manifest/signature is a different version
and follows the normal validated installation path. A missing library capability
preserves compatibility with older firmware. Unresolved uploads still require
their own durable reconciliation; inventory is not a new upload receipt.

## Automatic selection

Automatic selection defaults on and persists on the SD card. While following a
valid GPS position, the device checks coverage at five-second intervals. It
keeps a working covering map across overlaps. Otherwise it chooses the smallest
covering bounds, breaking ties by session ID. The storage worker also checks for
the actual renderer block at that coordinate, so a route corridor's bounding
rectangle cannot claim an empty interior as coverage. Pan/browse mode does not
automatically switch maps. There is no network request or download when no map
covers a location.

**Use** pins a manual map and persists automatic selection off. Re-enabling the
toggle returns to location-based selection. Automatic failures are excluded from
repeated selection until an explicit library command/refresh or a reboot.

## Storage and recovery

Inventory admits only completed signed streams with matching consumed markers,
manifest receipts, and file sizes, or existing verified archive installations.
Prepared, incomplete, truncated, or uncommitted roots are excluded. Selection
additionally rehashes payloads and validates the renderer/label contract. Reuse
switches the recoverable canonical pointer and clears/reloads the renderer's
existing cache through its established activation mailbox. It copies no map
payloads and creates no new upload or terminal operation receipt.

The previous selection, independent selection anchors, and interrupted
transactions remain protected. Explicit removal refuses protected maps. Completed
versions persist until explicitly removed; an update does not destroy its older
version. Invalid/staging state still uses the existing bounded recovery rules.

The authenticated BLE snapshot supports **32 completed maps**. Installation
refuses a 33rd map before receiving its payload and asks for an explicit removal;
it never silently evicts a city. Payload sizes exclude filesystem allocation,
metadata and archive overhead. Space availability remains enforced by the
existing stream installer.

Existing verified version folders are discovered in place. Original flat
`/VECTMAP` files are preserved as migration evidence; folders without an installed
manifest/receipt cannot be treated as an identified library version. They need
one verified installation to become selectable library entries. No migration
renames or deletes those files.

## Qualification

Host coverage includes retained-map cleanup, exact version matching, selection
without file moves, checksum rejection, failed pointer writes, restart recovery,
protected removal, pending-stream exclusion, deterministic overlap selection,
and malformed/duplicate/future-schema inventory.

Physical acceptance remains required separately for the 1.75 and 2.06 boards:

1. Install two disjoint signed maps and verify both remain in inventory after a
   further installation and a full power cycle.
2. Select the older map, confirm zero payload upload and a fresh rendered frame.
3. Drive the test GPS between covered locations and an uncovered location;
   verify overlap stability, route-corridor holes and manual selection.
4. Interrupt an update and selection, then cold boot and verify recovery without
   admitting uncommitted content or losing another completed map.
5. Remove an unprotected map explicitly; confirm selected/recovery maps cannot
   be removed and iPhone/cloud copies remain available.

Build and host checks are not SD durability, radio, or physical display proof.
This change must not be merged into production or released before both target
gates pass or the maintainer explicitly accepts the remaining hardware risk.
