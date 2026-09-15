# Saved-route following on iPhone (#437)

## Consolidation, 2026-09-15

Refreshed #437 (`c877f449ad49b2786520c86c351a65d3926e2b9f`) against freshly
fetched `origin/main` at `85914afc147f8cbd336f5ef17cb8dbdc2fdf85a6` in an
isolated worktree. Selected improvements were reviewed from #432 at
`e2e99a94818329b689798923a8545f8d6ebca709`; that PR is superseded by this one,
not a prerequisite to merge. #429 is already in main.

Kept from #437: typed GPX/installed drafts, the existing archive codec/store,
semantic duplicate handling, exact-identity reads, direct iPhone offline
navigation, online request invalidation, shared runtime and preview ownership.

Ported/adapted from #432: GPX confirmation in the existing library, direct saved
row navigation, bounded regular-file archive reads, canonical filename checks,
pending-deletion admission checks, local deletion retries and an engine-level
prohibition on replacing offline navigation with an online reroute.

Did NOT port #432's earlier preview implementation, old route sorting/start
logic or competing save-session class. Main's single-result immediate start,
fastest-first alternatives, explicit selection, and current #429 preview remain.

## One library, one import flow

Settings and the planner's **Saved Routes** shortcut render the same
`SavedRoutesSettingsSection`. The shortcut is only a container; it does not
implement its own list, import handler or persistence flow. The section requests
GPX confirmation from its stable parent presenter; it never owns a transient
sheet. Settings routes the typed draft through its existing item-driven sheet
enum, and the library shortcut uses the same stable-parent presentation pattern.

**New GPX:** Import GPX -> memory-only typed draft -> editable meaningful name
-> Save Route. Cancel and picker cancellation write nothing. The confirmation
sheet uses `OfflineRouteSaveInteraction`; failed saves retain the original draft
and identity for retry. Successful saves dismiss confirmation and show feedback
in the library, including an explicit already-saved result for duplicates.

**Already installed GPX/Strava:** Preview or Navigate on iPhone directly. There
is no redundant Save Offline step. Availability, provider attribution/Strava
expiry, rename, deletion and separate Watch sync controls remain in that row.
Previewing never starts navigation. Settings preview retains #429's planning
exclusion. A planner-shortcut preview may replace its plan only after the
selected archive and display geometry have been validated successfully.

## Selected MapKit route saving — follow-up, 2026-09-15

The maintainer explicitly requested enabling the existing **Save Offline**
button for the selected Apple Maps alternative, rather than a GPX redirect.
This follow-up implements that product-policy change. Ordinary MapKit results
remain active-only. An explicit selected draft uses the same `apple.mapkit`
provider and Apple Maps attribution with a new `phoneOnly` storage scope.
This is **not** an assertion that Apple permits durable Map Data storage:
[licensing review and release decision](../reviews/mapkit-route-storage-2026-09-15.md).

Both route-choice layouts capture a validated immutable canonical route and
show the shared naming/confirmation sheet. Save commits through the existing
archive/library store; Cancel has no disk effects. The first save keeps its
UUID and revision, and repeated saves reuse its identity and original name.
The plan and selected alternative are not replaced or started by saving.
Saved copies appear in Saved Routes and use the existing preview and offline
navigation paths. No second directions request or GPX conversion is made.

Watch transfer is disabled in the row, library, transport and Watch receiver;
Watch disk reads use a separate archive purpose to reject phone-only files.
User-owned GPX and Strava retain their current rules, including Strava's
original deadline and receipt/bookmark flow. Unknown providers still fail.

Offline route following is not offline route calculation or a basemap download.
Selected Apple routes retain the returned turn instructions. Imported GPX
continues to supply geometry/waypoint guidance, not newly generated Apple turns.
Apple map tile availability offline is not guaranteed.

## Storage and identity

`PhoneRouteLibrary`, `NavigationRouteArchiveV1`, `NavigationRouteContract` and
`NavigationRouteFileStoreV1` remain the storage and validation authorities. No
second database, persistent coordinate cache or archive format is introduced.
Application Support is the durable root; existing quotas, atomic verification,
SHA-256, schema/normalization versions and file protection are reused.

New GPX imports keep their staged UUID/revision; naming happens before the final
hash. Semantic duplicates compare provenance, canonical ordered geometry and
guidance, ignoring the new UUID/timestamp/name. They reuse the installed identity
and alias. Library-backed reads never clone or renew a Strava lease.

Archive discovery/reload bounds reads before decoding, validates the canonical
identity-derived filename, and rejects nonregular files and symbolic links. On
Apple platforms it uses `O_NOFOLLOW | O_NONBLOCK` plus `fstat` on the opened
descriptor to avoid pathname-check races and blocking FIFO reads. Quarantine
retains its existing bound. Deletion synchronizes the containing directory;
retrying an already-removed file also completes that synchronization boundary.

## Deletion and navigation lifecycle

A pending Watch deletion can keep a visible status row, but it is immediately
excluded from `offlineNavigationRoutes`. Preview and active navigation observe
that admission list, not mere file existence. Read/save/re-export paths also
check deletion state at the operation boundary.

Local cleanup and Watch acknowledgement now have independent persisted
identity sets. Local unlink failure remains blocked and retryable after either
Watch `deleted` or `evicted` acknowledgement and after app restart. Provider
removal failures are reported, not declared successful. Existing provider
Watch tombstones seed local cleanup on migration. Ordinary Watch eviction or an
unsolicited deletion acknowledgement does not delete the iPhone-owned copy.
A Watch-rejected GPX deletion retains the route under the existing semantics.

Navigation re-reads the exact UUID/revision/hash archive before starting the
shared runtime in offline mode. No directions/geocoding/Strava fetch or GPX
reparse is needed. No fix is fabricated: loading works without GPS, but progress
requires a valid fix. Canonical geometry stays WGS-84; display conversion is
owned by the MapKit boundary. Pending online requests are invalidated only after
an offline start has validated successfully. Offline rerouting is blocked at
both coordinator and engine boundaries. Off-route guidance asks the rider to
return to the saved route. Expiry is enforced on location/heartbeat and resend
paths; deletion/replacement/corruption discovered by reload stops navigation.
Restart restores the library, not an unrequested active navigation session.

## Verification

Run from `ios-app`:

```sh
./scripts/run-offline-route-tests.sh
./scripts/run-navigation-tests.sh
./scripts/run-saved-route-map-tests.sh
./scripts/xcodebuild-cli.sh -project BikeComputer/BikeComputer.xcodeproj \
  -scheme BikeComputer -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Standalone runners include main's World Radio, device-screen and WireBytes
dependencies. Focused tests compile production importer/library/store/coordinator/
engine with Watch/directions boundaries doubled. Added coverage includes pending
Watch deletion, rejected deletion, failed local deletion followed by either
Watch acknowledgement, restart/retry, unsolicited acknowledgements, symbolic
links, wrong filenames, oversized archives, and shared UI confirmation wiring.
Native map tests cover enabled/disabled/failed direct navigation actions in
addition to the existing preview and active-overlay checks.

Fresh verification results belong to the exact refreshed commit and are
recorded in the PR. The September 8 results on commit `302df26b...` are historical,
not evidence that this refreshed source graph passes. Linux parser and portable
policy tests are not substitutes for Apple-platform compilation or UI automation.

Physical checks still required: airplane-mode route following, force-quit and
relaunch, GPS acquisition and background/lock-screen delivery, Strava expiry over
suspension/reconnect, BLE and Watch handover, China/non-China map alignment,
VoiceOver/Dynamic Type/landscape, disk-full and protected-storage behavior. No
physical installation, ride, firmware flashing or automatic merge is authorized
by this change.
