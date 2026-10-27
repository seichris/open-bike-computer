# Device map library

Completed maps stay in their existing `/VECTMAP/.maps/<session>` folders.
Installing Chengdu no longer prunes a completed Shanghai installation. Abandoned
upload staging remains recoverable or reclaimable through the existing protocol.

## App behavior

Settings uses one **Saved Maps** list for iPhone, catalog, active-device and
retained SD versions. Inactive installed maps use the same upload icon as maps
on the phone; the action reuses the installed exact version. Tapping a thumbnail
opens its high-resolution preview directly, with a compact saved-to-Bicino or
iPhone-only status immediately below the image. Topography details and source
attribution follow without a full-height image spacer. Swiping an inactive map
exposes **Remove from Bicino**, with confirmation bound to the phone connection
and device identity. iPhone files and cloud references remain separate from SD
removal. Damaged copies stay visible with repair instructions. A library
download (an update or a claimed share) replaces the iPhone copy it supersedes:
once it is verified and saved, another iPhone copy of the same library entry,
such as the original direct-job file, is removed with its contour companion.
Nothing is removed while a transfer runs. A copy that a transfer without a
settled result, a paused upload, an unfinished device operation or a pending
device install still uses is kept, and stays a separate row until it is removed
by hand. SD installations are unaffected.

When the upload action finds an exact verified signed version in a fresh device
inventory, it selects that installation over authenticated BLE. No map payload
or Wi-Fi session is sent. A different manifest/signature is a different version
and follows the normal validated installation path. A missing library capability
preserves compatibility with older firmware. Unresolved uploads still require
their own durable reconciliation; inventory is not a new upload receipt.

## Location-based switch prompts

GPS updates never silently switch maps. While following GPS, the device checks
current coverage and searches completed installations on the storage worker at
five-second intervals. It checks actual renderer blocks, so a route corridor's
bounding rectangle cannot claim an empty interior as coverage. One probe per
4096 m Mercator block and declared-bounds membership is cached until refresh or selection; temporary failures
back off and do not report a false absence of installed coverage.

The authenticated inventory includes a coverage result bound to its current
renderer selection and GPS block. The foreground landing page waits for a fresh,
complete inventory and a usable matching GPS fix. When the current map does not
cover the location and another installed map does, **Switch Bicino map?** offers
**Cancel** or **Open Saved Maps**. The latter opens Settings scrolled to Saved
Maps; it does not select anything. Cancel suppresses that prompt for the same
connection, selection, suggested map and GPS block. Prompts wait during rides,
navigation, other sheets and map operations.

If no installed map covers the location, the existing **Download Map** /
**Choose Area** onboarding remains. An unknown or busy coverage probe cannot
trigger that download prompt. Older firmware without a map library keeps the
existing download flow. Pan/browse mode does not probe the user's current GPS.
There is no automatic network request or download when coverage is missing.

The old `automatic` field and policy commands remain for protocol compatibility;
the current firmware GPS loop only queues a read-only suggestion. The app no
longer exposes an automatic-selection setting.

**Use** pins a manual map and persists automatic selection off. It first journals
its exact target (`/VECTMAP/.library-selection-intent.json`), then moves the
canonical pointer. The manual policy is written only once the renderer has
acknowledged that pointer, or when a reboot finds it durable. A crash between
the pointer and policy writes is settled from the journal at the next library
task. A Use that is refused, fails, or is rolled back after a renderer failure
drops the journal and leaves automatic selection as it was. While the journal is
unsettled the inventory reports `automatic: false` and no automatic switch runs.
A failed library switch leaves the renderer on its previous root, so **In use** and
live-renderer removal protection keep naming that map; the version that never
loaded can be removed. If the pointer cannot follow the renderer back, health
reports `rollback_failed` and both maps stay protected. Choosing another map in Saved Maps selects that version explicitly. Invalid automatic candidates are excluded
from repeated selection until an explicit library command/refresh or a reboot.
Temporary upload/storage-busy conditions remain eligible for a later retry.
Label/font contract failures are candidate verdicts and do not trigger repeated
full-map hashing. Renderer acknowledgements and rollback invalidate the position
cache so another covering version can be tried after a failed switch.

## Storage and recovery

Inventory admits only completed signed streams with matching consumed markers,
manifest receipts, and file sizes, or existing verified archive installations.
Prepared and uncommitted roots are excluded. Completed versions with missing or
truncated payloads remain visible as **Files need repair**; they can be removed
but cannot authorize reuse or automatic selection. Cancelled
retransmissions preserve a previously completed version even after it has aged
out of the active/rollback selections, and a mismatched stream cannot overwrite
a completed slot in place. Selection
additionally rehashes payloads and validates the renderer/label contract. Reuse
switches the recoverable canonical pointer and clears/reloads the renderer's
existing cache through its established activation mailbox. It copies no map
payloads and creates no new upload or terminal operation receipt. Reuse waits
for the exact client request ID and renderer acknowledgement; unrelated automatic
errors cannot complete or fail that waiter. Full integrity/anchor checks can pause
map rendering during a switch; physical acceptance must measure this with real
city packs before production merge.

An identical signed re-upload of a completed version keeps that version's
completion evidence (`.library-retained`) while the new operation owns the root.
If the operation fails (for example after a renderer rejection), the version is
restored as completed instead of being discarded as staging. An upload never
overwrites a damaged copy. Reinstalling the same version returns 409
`stream_repair_requires_removal`, and Settings offers an explicit **Remove**
for **Files need repair** entries before a fresh install. Protected roots and
other versions in the same slot return 409 `stream_session_conflict`.

Removal first renames a verified, unprotected version to a deletion tombstone.
Boot and refresh cleanup reclaim tombstones after an interrupted recursive delete.
A bounded first 32-entry inventory remains removable even if external SD changes
have added more versions.

The previous selection, independent selection anchors, and interrupted
transactions remain protected. Explicit removal refuses protected maps. Completed
versions persist until explicitly removed; an update does not destroy its older
version. Invalid/staging state still uses the existing bounded recovery rules.

The authenticated inventory supports **32 completed maps**, delivered in four-map
BLE pages and assembled within one connection and snapshot revision. Installation
refuses a 33rd map before receiving its payload and asks for an explicit removal;
it never silently evicts a city. Payload sizes exclude filesystem allocation,
metadata and archive overhead. Space availability remains enforced by the
manifest preflight: remaining payload bytes, conservative FAT cluster slack and
metadata reserve are checked before the first payload file. A full card or a
33rd-map attempt directs the app to **Saved Maps** for removal.
A durable upload refused before it writes payload resolves its own operation as
Failed and returns that receipt with the error. Neither the device nor the phone
then keeps a pending installation that would block the removal. Removal also
proceeds while a different map's upload is paused or prepared; that upload's own
map and committed activations stay protected. **Use** and the automatic toggle
still ask the rider to resume or cancel a pending installation first.

Existing verified version folders are discovered in place. Original flat
`/VECTMAP` files are preserved as migration evidence; folders without an installed
manifest/receipt cannot be treated as an identified library version. They need
one verified installation to become selectable library entries. No migration
renames or deletes those files.

## Qualification

Host coverage includes retained-map cleanup, exact version matching, selection
without file moves, checksum rejection, failed pointer writes, restart recovery,
protected removal, pending-stream exclusion, deterministic overlap selection,
and malformed/duplicate/future-schema inventory, paginated snapshot fencing,
cancellation of retransmissions to retained versions, production controller
execution with empty/partial/pending operation ledgers, automatic negative coverage
caching, allocation-failure handoff recovery, owner dispatch rejection, SD-space
preflight, interrupted removal, failed-renderer fallback in the same block,
label-contract rejection caching, paused-upload/current-coverage behavior,
allocation recovery and maximal BLE inventory page size. Review follow-ups add:

- full-card rejection resolving only its own operation, with removal still permitted;
- retention of an identical, aged-out version through failed re-activation and reboot discard;
- damaged-copy and protected-copy reinstall refusals, and removal-then-reinstall repair;
- bounded owner-dispatch backoff without revision churn;
- renderer health after failed manual and automatic switches, including rollback failure;
- the manual-Use journal at every pointer/policy crash boundary, policy-write failure and renderer rollback.

Physical acceptance remains required separately for the 1.75 and 2.06 boards:

1. Install two disjoint signed maps and verify both remain in inventory after a
   further installation and a full power cycle.
2. Select the older map from Saved Maps, confirm zero payload upload and a fresh rendered frame.
3. Drive the test GPS between covered locations and an uncovered location;
   verify switch/download prompt routing, Cancel, route-corridor holes and explicit selection.
4. Interrupt an update and selection, then cold boot and verify recovery without
   admitting uncommitted content or losing another completed map.
5. Remove an unprotected map explicitly; confirm selected/recovery maps cannot
   be removed and iPhone/cloud copies remain available.

Build and host checks are not SD durability, radio, or physical display proof.
This change must not be merged into production or released before both target
gates pass or the maintainer explicitly accepts the remaining hardware risk.
