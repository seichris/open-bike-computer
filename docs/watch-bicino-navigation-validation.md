# Watch + Bicino navigation validation record

This record tracks evidence for the implementation plan in
`docs/plans/watch-bicino-online-offline-navigation-implementation-plan.md`.
It is intentionally fail-closed: a software build or simulator result does not
satisfy a physical or route-provider compliance gate.

## Phase 0 baseline

- Implementation branch merged current `origin/main` at `1e1899807f7ba10d5afc18788a3f24ec55401c40`.
- Portable iOS navigation/BLE tests passed before implementation on 2026-08-08.
- `CAP2` bit 13 is reserved but is not advertised by firmware.
- The exclusive controller lease has a host-testable state machine covering
  grant, renew, busy, role mismatch, activity refresh, release, disconnect,
  revocation, timeout, and `millis()` wrap.

## Route-source policy gate

Durable offline archives default to denied for MapKit-derived route data until
an explicit current Apple terms/product/legal approval record is attached here.
The implementation must keep durable storage behind a provider retention
policy and allow export-licensed or user-imported route sources. A short-lived
active online route is not evidence that durable export is approved.

Status: **not approved for MapKit durable export**.

## Physical Watch gate

Required evidence remains:

- minimum-supported physical Watch model and watchOS version;
- foreground and active-workout cycling route request;
- wrist-down GPS cadence;
- direct Bicino BLE writes, notifications, reconnect, and full resync;
- suspension/relaunch recovery;
- representative two-hour battery and thermal measurements.

Status: **not yet physically validated**.

## Deep review ledger

### Phase 0 software spike

Review profile: deep. Mode: local fixes. Base snapshot:
`3727d04a53a2b0a1b875d725774d30faa59975f1` plus the Phase 0 working-tree
manifest.

| ID | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| P0-001 | P1 | A 64-bit controller-only identity could collide and could let two authenticated sessions for the same durable credential renew one lease. | Use the full 128-bit controller ID plus a non-zero authentication-session ID and role in holder equality; a reconnect is busy until the old session releases or expires. |
| P0-002 | P1 | A zero timeout created a non-expiring writer lease. | Normalize zero to the bounded 15-second production default and test exact expiry. |
| P0-003 | P1 | An out-of-range role value passed identity validation. | Validate the role allowlist before every claim. |

The confirming pass covered correctness/security, failure boundaries and
sanitizers, compatibility/golden vectors, and scope/documentation. It found no
remaining actionable P0/P1/P2 software-spike findings. Strict GCC and Clang
builds, AddressSanitizer/UndefinedBehaviorSanitizer, capability golden vectors,
and `git diff --check` passed. The external route-source and physical-Watch
gates above remain open and are not waived by this review.

### Phase 1 shared route contract and iPhone parity

Review profile: deep. Mode: local fixes. First frozen working-tree snapshot:
`77a76eabd3373bbaa4264bf07ad9208f5c837b2829ee76a8b1912c06894e7ffe`.
Confirming implementation snapshot (excluding this self-referential ledger):
`33c29ca8ced2ab30de38097d6f067f59201445c6a0270d99f64d366e1052f9f9`.

| ID | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| P1-101 | P1 | Runtime and engine route replacement mutated active state before all validation and projection work succeeded. | Make `start` and `replaceRoute` transactional on a candidate runtime and commit engine state only after a valid replacement snapshot exists; add failure-atomicity tests. |
| P1-102 | P1 | Processing the same initial/replacement GPS fix twice could skip a curved maneuver whose endpoint loops close to its start. | Apply the runtime-produced initial snapshot instead of reprocessing it, make identical fixes idempotent, use the maneuver-arrival ambiguity band, and expose at most one new maneuver per fix. |
| P1-103 | P1 | Route-window deltas outside `Int16` were silently clamped, and endpoint/step gaps could admit geometry that no longer matched its instructions. | Reject unencodable adjacent points, fail compression instead of clamping, pin endpoints to geometry, and require continuous step coverage from first through last point. |
| P1-104 | P1 | A provider metadata record could self-declare durable storage, including by reusing the MapKit provider ID with a different scope. | Enforce exact policy for known providers and an explicit durable-provider allowlist; currently only user-imported GPX is allowed. |
| P1-105 | P1 | Dropping MapKit's empty terminal step removed arrival semantics, and a one-point provider step failed the existing iPhone fallback behavior. | Normalize a terminal empty step to an explicit arrival and synthesize a source-to-endpoint segment only when an initial/current location is available. |
| P1-106 | P2 | Millisecond JSON date encoding could make a newly created archive unequal to its decoded form when the input contained sub-millisecond precision. | Normalize archive retention timestamps to milliseconds before hashing and storing them. |
| P1-107 | P2 | Every GPS update allocated projections for up to 50,000 segments, which is unsuitable for sustained Watch navigation. | Keep a segment cursor, scan a bounded local window during ordinary progress, and fall back to the full route only for large jumps or remote rejoins. |
| P1-108 | P2 | Location validation covered coordinates and accuracy but allowed non-finite course, speed, altitude, or timestamp values into ETA/runtime state. | Validate every numeric sample field and preserve the previous runtime on rejection. |

The confirming pass covers four independent lenses: correctness/security;
tests and failure boundaries; maintainability/performance; and scope/docs. The
shared tests include deterministic archive/hash behavior, corruption, schema,
retention, size, point/step, locale, endpoint, range, provider-policy,
duplicate-fix, deviation, rejoin, and transactional replacement/start cases.
The entire pre-existing portable iPhone navigation, cycling-sensor, destination
layout, and Catalyst preview suite remains green. The shared sources also pass
strict host compilation, AddressSanitizer, and direct iPhoneOS/watchOS SDK
type-checks.

`xcodebuild -list` confirms project parsing and target membership. Full target
build attempts are currently blocked before source compilation by a local
Xcode `SWBBuildService` pipe deadlock in its SDK macro probes; the same failure
is concurrently reproducible in an unrelated checkout, while the identical
standalone SDK probe completes successfully. This environment limitation is
recorded rather than misreported as a source failure. It does not satisfy or
waive any later physical-device gate.

### Phase 2 iPhone planning and Watch route delivery

Review profile: deep. Mode: local fixes. First frozen working-tree snapshot:
`b5122ff96f38c0903389aebc4ad78fb51117a49f7f80654b653dc175da95ddfd`.
Confirming implementation snapshot (excluding this self-referential ledger):
`85e224569d30fb3580fa4994cb5ed60168de55b0ed3c74fd9e7bbd1fc469e023`.

| ID | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| P2-201 | P1 | Deleting a route while its file transfer was queued allowed the deletion tombstone and file to arrive out of order, potentially resurrecting the route. | Persist queued installs and deletions, refuse deletion while an install is in flight, retain the local archive until the exact deletion acknowledgement, and make Watch deletion exact and idempotent. |
| P2-202 | P1 | Transfer and Ready state existed only in memory, so reopening the app could allow duplicate sends or forget a verified Watch installation; re-importing identical content also downgraded Ready to local-only. | Persist exact route/revision/hash install, deletion, and Ready receipts; reconcile them against validated local files on every reload; ignore stale acknowledgements and preserve idempotent imports. |
| P2-203 | P1 | The Watch delegate read and memory-mapped a temporary transfer file before validating metadata and then carried that mapping beyond the delegate callback. | Parse canonical metadata first, cap and match the filesystem byte count, copy at most 4 MiB while the callback owns the URL, and pass owned data to the main-actor installer. |
| P2-204 | P1 | Archive writes relied on a generic atomic option without a post-write decode, explicit file sync, directory sync, or Watch file protection. | Write in-directory temporary files, fsync, decode and compare, atomically rename, fsync the directory, exclude backups, and apply complete-until-first-unlock protection. |
| P2-205 | P1 | Route transfer metadata did not bind the encoded byte count or retention date, allowing metadata and archive policy to disagree. | Require canonical byte-count and retention fields for install messages and validate size, identity, hash, revision, and retention before mutating Watch storage. |
| P2-206 | P2 | The first returned alternative was implicitly selected, so the rider could start without making the required explicit choice. | Preview the first route without selecting it, disable Start until a rider selection, retain advisory notices, and test that planning requests alternatives without starting navigation. |
| P2-207 | P2 | Invalid files were silently deleted and were not counted before capacity checks, while the plan called for bounded diagnostics. | Prune before accounting, remove expired files, quarantine corrupt files outside the selectable library, and cap quarantine at three artifacts. |
| P2-208 | P2 | The iPhone and Watch route limits shared one generic 50-route/64 MiB policy. | Add explicit store policies and enforce the planned Watch bound of 10 routes and 50 MiB, with pre-write capacity tests. |
| P2-209 | P2 | Idempotent installation returned semantically identical but non-equal constructed and enumerated file URLs. | Standardize both generated and discovered file URLs and cover repeated installation. |

The confirming pass covered correctness/security; asynchronous ordering and
failure boundaries; storage/performance; and compatibility/UI. Shared tests
cover transfer-message semantics, revision conflicts, stale delivery,
idempotency, exact deletion, capacity, expiry, quarantine, atomic validation,
and provider policy. The full portable navigation suite, workout-contract host
suite, strict Watch source graph, focused strict iPhone sources, complete iOS
source graph, project parsing, and `git diff --check` pass. Production has one
`WCSession.default` delegate per process; legacy injected delegate paths remain
only for existing tests and previews.

The Phase 2 physical paired-Watch gate remains open: no physical transfer,
process termination/relaunch, or acknowledgement capture has been performed.
The full workout simulator schemes encountered the same previously documented
local `SWBBuildService` SDK-probe deadlock and were terminated by their exact
process groups; this is not reported as test success.

### Phase 3 scoped Watch controller and exclusive lease

Review profile: deep. Mode: local fixes. First frozen working-tree snapshot:
`ddd87c9f5e8327bb76b94378f65043e77f7b314b5b0b127e726f5dbc60e5c7f3`.
Confirming implementation snapshot (excluding this self-referential ledger):
`6d898d06c2f3014687b25a2cb93b8f295266bde826956afc3ded2d90dd54e2d9`.

| ID | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| P3-301 | P1 | The legacy navigation characteristic multiplexes settings, transfer, sound, capability, and destination commands, so channel-level role checks alone let a Watch controller reach owner-only behavior. | Add a syntax-bounded Watch payload allowlist for maneuver, route-window, GPS, and workout fallback frames; reject every privileged multiplexed prefix and cover it with host tests. |
| P3-302 | P1 | Reading the authenticated role after releasing the ownership mutex allowed a concurrent revoke or reset to make an accepted Watch frame appear to be an owner frame. | Capture the authorized session role atomically while unwrapping the protected payload and use that immutable result for downstream dispatch. |
| P3-303 | P1 | Watch Keychain promotion attempted to mutate the synchronizable attribute, which Security does not permit during an item update. | Keep the non-synchronizing attribute in the exact lookup and insertion identity, but remove it from mutable update attributes; test pending-to-active promotion behavior. |
| P3-304 | P1 | A valid Watch controller orphaned by an interrupted unclaimed-device transition could prevent the next legitimate owner from enrolling a replacement. | Purge an orphan only when the owner state is validly unclaimed; retain fail-closed behavior when the owner record is corrupt. |
| P3-305 | P1 | Watch credential deletion could be lost when WatchConnectivity was not activated, paired, or installed at the moment of revocation. | Persist exact device/controller revocations on iPhone, deduplicate them, and flush durable queued user-info after every eligible activation transition. |
| P3-306 | P2 | Temporary ownership-lock contention could produce a valid capability response with direct-Watch bit 13 falsely clear. | Withhold the capability response on lock contention so the client retries; advertise bit 13 only after a clean controller-store boot. |
| P3-307 | P2 | A lost firmware commit/revoke response or failed Watch promotion could leave stale UI or Keychain authority. | Persist the non-secret controller ID per Bicino and reconcile it with exact `WCTRL_STATUS`; make Watch promotion and deletion idempotent while keeping firmware revocation first. |
| P3-308 | P2 | The Watch maneuver allowlist accepted unbounded numeric fields later parsed with `atoi`, permitting integer overflow. | Bound icon IDs to 255 and distance to signed 32-bit range before accepting the fallback frame. |
| P3-309 | P2 | Owner deregistration or local device removal did not necessarily clean the matching Watch credential. | Remember the exact controller ID and queue its Watch deletion only after the corresponding local owner mutation succeeds. |

The confirming pass covered authorization boundaries, persistence and
power-loss ordering, cryptographic transcript parity, replay/session identity,
dual-controller lease exclusion, revocation delivery, compatibility, and UI
reconciliation. Strict firmware host tests pass for capabilities, lease,
scoped payload policy, and ownership state; ownership also passes Clang
AddressSanitizer/UndefinedBehaviorSanitizer. The fixed cross-language HMAC
vector, shared route suite, workout contract suite, full portable navigation
suite, project parsing, and `git diff --check` pass.

The test matrix covers stage/commit/revoke across reboot and failed writes,
active-slot corruption, exact-controller revocation, Watch challenge/response,
explicit lease claim, role and settings denial, owner compatibility, and
navigation-characteristic privilege denial. The scoped key remains
non-synchronizing and this-device-only, and neither it nor the OwnerKey is
written to ordinary preferences.

No PlatformIO target build, upload, serial capture, or physical dual-controller
test has been performed in this phase. Repository policy requires identifying
the connected Bicino hardware before the first such action, and the physical
Watch/Bicino gates remain open rather than being inferred from host evidence.

### Phase 4 offline Watch + Bicino navigation

Review profile: deep. Mode: local fixes. First frozen working-tree snapshot:
`ce27216dc1ff9094db1f3b12aa343ffd387079258449ddd0041fe31300c0b754`.
Confirming implementation snapshot (excluding this self-referential ledger):
`2fa53f23a17899230f82600fd7f3d12bd8486d5af078f66ee88fee5840000fa0`.

| ID | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| P4-401 | P1 | The scoped Watch payload allowlist denied `CAPS`, so a correctly authenticated Watch could never discover bit 13 and become ready. | Allow only the exact read-only five-byte capability request and test malformed and oversized variants; all privileged multiplexed commands remain denied. |
| P4-402 | P1 | Stopping navigation removed BLE demand before queued route and maneuver clear frames could drain, allowing stale guidance to remain on Bicino. | Keep navigation demand until the protected clear frames have flushed, then release the lease only when no workout demand remains. |
| P4-403 | P1 | Core and extended Watch workout frames had no shared pair generation, so reconnect or rapid updates could combine frames from different snapshots. | Stamp both frames with one two-bit generation and atomically replace a pending telemetry pair as one queue target. |
| P4-404 | P1 | Recovery on a loop or out-and-back route could project onto an earlier geometrically identical segment and regress progress. | Restore through a validated step checkpoint and constrain the initial projection to that checkpoint's forward neighborhood. |
| P4-405 | P1 | A failed navigation-journal clear was ignored, so a route reported as stopped could resurrect after relaunch. | Fail the stop visibly and preserve active state until the journal is durably cleared. |
| P4-406 | P1 | A stale saved-peripheral mapping survived full DeviceID/HMAC identity rejection and could cause endless reconnects to the wrong hardware. | Remove the exact mapping after authenticated identity rejection so the next attempt returns to suffix-filtered discovery. |
| P4-407 | P1 | `bluetooth-central` was placed under `WKBackgroundModes`, although watchOS declares Core Bluetooth and location background services through `UIBackgroundModes`. | Keep only `workout-processing` in `WKBackgroundModes`; declare `bluetooth-central` and `location` in `UIBackgroundModes`, and inspect the built-source plist. |
| P4-408 | P2 | Connect, discovery, or authentication could hang indefinitely without advancing reconnect backoff. | Add a connection-generation-scoped 20-second timeout that cancels stale work and retries only while ride demand remains. |
| P4-409 | P2 | Deferred deletion could fail after provider retention expiry because normal library lookup excludes expired routes. | Delete the exact canonical route/revision/hash file directly after active pin release, including expired records. |
| P4-410 | P2 | Far-start confirmation could activate with a newly received GPS fix while publishing the earlier candidate snapshot. | Reprocess the latest accepted sample before activation and publish one coherent runtime snapshot. |
| P4-411 | P2 | A stale or poor cached GPS fix could produce an incorrect start-distance warning. | Require a valid coordinate, nonnegative accuracy at most 100 metres, and an age between minus 5 and 60 seconds for first-fix activation. |
| P4-412 | P2 | Frequent GPS, route-window, maneuver, and workout updates could grow stale work behind a slow BLE link. | Coalesce replaceable GPS and route targets, threshold maneuver changes, and replace pending workout pairs atomically in a bounded priority queue. |
| P4-413 | P2 | Failed recovery could retain the route's active pin and prevent later replacement or deletion. | Track the activated identity and always release it on every recovery failure before applying pending tombstones. |
| P4-414 | P2 | Main-actor defaults and route-message parsing crossed nonisolated WatchConnectivity callback boundaries under the target's Swift 6 isolation mode. | Construct actor-owned dependencies explicitly, copy the bounded temporary file in the callback, and parse/mutate state only after hopping to the main actor. |

The confirming pass covered independent workout/navigation lifecycles,
location ownership, route recovery and deletion, bounded BLE scheduling,
authenticated reconnect and capability negotiation, stale callback rejection,
offline provider exclusion, strict Swift 6 isolation, Watch background plist
placement, firmware scoped-command authorization, and existing iPhone
compatibility. The shared ride, Watch offline navigation, workout contract,
complete portable iPhone navigation, capability, lease, scoped payload, and
ownership host suites pass. The full Watch source graph type-checks against the
watchOS SDK with warnings as errors, the Watch plist validates, and
`git diff --check` passes.

The runtime contains no route-provider dependency in offline mode. No
PlatformIO target build, physical paired-Watch route install, wrist-down GPS,
direct Watch/Bicino ride, reconnect, or battery test has been performed. The
Phase 4 physical gate therefore remains open.

### Phase 5 online Watch + Bicino routing

Review profile: deep. Mode: local fixes. First frozen working-tree snapshot:
`42750c43fac5c276235c076861eafdefebd0167af05ec3a67e53aa8bbc93b85f`.
Confirming implementation snapshot (excluding this self-referential ledger):
`0304a819c2c8dd1cdade1c82c66440a8743242d4b8ef5c91513e64e9ac469a54`.

| ID | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| P5-501 | P1 | Treating `NWPathMonitor` as an authority blocked an explicit MapKit request even though the routing operation itself could still succeed. | Treat path state as advisory: explicit initial calculation and explicit recalculation may run, while the provider result is authoritative; automatic retries still wait for path recovery and cooldown. |
| P5-502 | P1 | Turning the setting off after queuing a task but before its body executed could still invoke the online provider under `offlineOnly`. | Validate navigation, policy, request, and material-location generations immediately before every provider call and again before installing its result. |
| P5-503 | P1 | Replacing an installed route with an active-only online reroute while retaining its journal could resurrect the obsolete installed route after relaunch. | Build the replacement in a candidate runtime, durably clear the installed-route journal, then atomically commit the candidate and release the old route pin. |
| P5-504 | P1 | The setting was reachable only from the pre-ride screen, so its required deterministic mid-ride semantics could not be exercised by a rider. | Keep the full setting and footer in Watch Settings and expose the same Watch-local toggle in the live ride UI. |
| P5-505 | P1 | BLE maneuver throttling did not compare route identity or navigation generation, so a reroute with similar first instructions could omit the required maneuver resync. | Force maneuver delivery whenever navigation generation, route ID, or route revision changes, while retaining ordinary distance thresholding. |
| P5-506 | P1 | A route response could be installed using a stale or newly inaccurate latest GPS fix. | Require a valid, at-most-100-metre, minus-5-to-60-second location both before a request and before initial or replacement commit; material motion invalidates the request generation. |
| P5-507 | P1 | A journal-clear failure during reroute was ignored, trading a working old route for an unrecoverable or misleading replacement. | Keep the old runtime untouched unless candidate validation and durable journal removal both succeed; failure reports reroute failure while preserving guidance. |
| P5-508 | P2 | All initial provider errors were labelled as no connection, even when the path was available and MapKit failed for another reason. | Distinguish `No Watch internet connection` from `Route calculation failed` and retain an explicit retry action. |
| P5-509 | P2 | The manager accepted any active-only response metadata rather than binding the result to the provider that received the request. | Require exact provider metadata equality plus active-only scope before installing a Watch online route. |
| P5-510 | P2 | Turning online policy back on or recovering connectivity could leave stale offline failure copy even though an immediate replacement is intentionally forbidden. | Preserve the route and avoid automatic recalculation, but refresh status to an online retry state; off-route recovery may retry only through the cooldown gate. |
| P5-511 | P2 | An unbounded iPhone favorite list or a wrapped revision could make the latest-state context permanently invalid or non-monotonic. | Sync the deterministic first 50 coordinate-backed favorites and fail closed before `UInt64` revision exhaustion. |
| P5-512 | P2 | Invalid favorite input could overwrite the visible state of an already active route. | Validate and canonicalize the destination before stopping anything; invalid input leaves an existing route untouched. |
| P5-513 | P2 | Installed-route activation failure after pinning could strand an active pin. | Track activation and release the exact identity on every later failure. |
| P5-514 | P2 | Online recovery always reported cached/offline continuation even when an available path already allowed rerouting. | Derive the recovered runtime mode from the user policy plus advisory current path without changing the setting or issuing an immediate request. |
| P5-515 | P2 | Active online guidance did not expose route-provider attribution. | Publish the current route attribution from the shared model and render it in the Watch live-navigation status. |

The confirming pass covered Watch-local setting ownership, default-off
migration, merged coordinate-favorite context, stale and equivocal revisions,
China coordinate normalization, explicit routing under advisory no-path state,
zero provider calls for offline start and deviation, pending-policy races,
material-motion rejection, 15-second reroute cooldown, network loss, failed
reroute preservation, active-only storage, journal transition ordering,
mid-ride policy changes, BLE replacement resync, and provider attribution.

The focused Watch online manager harness, shared route suite, Watch offline
suite, workout contract suite, strict warnings-as-errors Watch source graph,
complete iPhone source graph, and full portable iPhone navigation/Catalyst
regression suite pass. `xcodebuild -list`, Watch plist validation, the static
active-only provider persistence audit, and `git diff --check` also pass. The
MapKit provider is memory-only and contains no archive, file-store, or write
path.

No physical Watch MapKit request, cellular or Wi-Fi transition, GPS deviation,
direct Bicino display, or two-hour ride was performed. The Phase 5 physical
gate and the Apple Maps accessory-display compliance gate remain open.

### Phase 6 recovery and release hardening

Review profile: deep. Mode: local fixes. First reviewed working-tree snapshot
(excluding this self-referential ledger):
`ab941244ff60621227c531a820759c58c76575bac36689dc125d610b752070c3`.
Confirming implementation snapshot:
`618b0ba8a9cd376cbc1c211b9ad4de4c866f6afe52e72c5ee625b5e7c385071c`.

| ID | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| P6-601 | P1 | A completed workout summary had priority over a still-running navigation session, hiding maneuvers and Stop/Retry controls even though the underlying lifecycles were independent. | Add a navigation-only presentation, share the exact status controls with the live workout, and keep navigation ahead of the workout summary until navigation stops. |
| P6-602 | P1 | Durable Watch revocation deleted the Keychain item but an already authenticated direct BLE session retained the credential and lease in memory. | Notify the direct link after every successful promotion/revocation, reload the active Keychain set, release/cancel any removed controller session, remove its peripheral binding, and reconnect only with still-authorized credentials. |
| P6-603 | P1 | Starting replacement navigation before the previous route-clear drained could let the old release completion stop the new navigation-only BLE connection. | Base release completion on the combined current workout/navigation demand instead of the old workout demand alone. |
| P6-604 | P1 | The MapKit legal fail-closed gate left no rider-facing durable route source, so the offline implementation could not be used outside test fixtures. | Add a bounded user-owned GPX importer, iPhone document-picker flow, validated durable archive creation, route library entry, exact Watch transfer, and user/release documentation while keeping MapKit Save Offline disabled. |
| P6-605 | P1 | A naive GPX parser could expand entities, concatenate disjoint segments/routes, accept oversized geometry, or connect sparse unencodable points. | Cap input at 4 MiB and 50,000 points, disable external resolution, reject entity declarations, validate every coordinate and final shared route, choose one longest usable route/track segment, deduplicate adjacent points, and test failure cases. |
| P6-606 | P2 | Deleting an iPhone-only or rejected GPX route unnecessarily required a paired reachable Watch and could make local data undeletable. | Delete local-only routes directly; require an exact Watch tombstone only when a Ready receipt proves that revision was installed. |
| P6-607 | P2 | The planned-route empty state used an iOS 17-only view while the app supports iOS 16.4. | Add an availability-gated iOS 17 presentation and an equivalent iOS 16 fallback, then type-check the complete source graph at the 16.4 deployment target. |
| P6-608 | P2 | Turning online permission off retained an `onlineUsingCachedRoute` snapshot mode even though network use was now forbidden. | Move the active runtime to the explicit offline mode, retain geometry, and test the published mode and zero immediate replacement behavior. |
| P6-609 | P2 | Pending controller revocations accepted an injected defaults store but loaded and persisted through `UserDefaults.standard`, undermining deterministic recovery and tests. | Use the coordinator's injected store for load, write, and deletion consistently. |
| P6-610 | P2 | Route expiry and future-schema downgrade behavior were implemented but not exercised at the Watch library/journal boundary. | Add exact expiry-boundary physical-file deletion, future archive rejection, future journal rejection, and navigation-without-workout recovery coverage. |
| P6-611 | P2 | Location usage, paired route/favorite transfer, online Watch MapKit requests, active-only storage, and re-enrollment behavior were absent from setup/privacy/release documentation. | Update the Watch usage description, public privacy policy, App Store answer sheet, setup README, plan status, documentation index, and fail-closed draft release notes. |
| P6-612 | P1 | The first clean GitHub CI run stopped before every Swift and Xcode check because the release-asset test still required the obsolete zero-argument `WatchSettingsView()` construction. | Assert the dependency-injected settings construction and its exact `navigationSettings` argument; reproduce the failure locally, make the generated-identity suite green, and rerun the complete local contract matrix before republishing. |
| P6-613 | P1 | The simulator-backed workout target compiled the Watch-availability monitor in isolation, but Phase 2 had coupled that monitor to the production `PhoneWatchConnectivityCoordinator`, which is intentionally outside the target. | Depend on a narrow workout coordinator protocol and value snapshot, adapt the sole production coordinator through a publisher, cover activation/availability/context sync through a fake adapter, and type-check both the isolated monitor graph and the complete iPhone graph. |
| P6-614 | P2 | A coordinator can synchronously publish its activated state from `activate()`, so marking heart-rate synchronization pending afterward sent the same application context once from the publisher and again from the caller. | Mark synchronization pending before activation and require exactly one context in the synchronous-publisher adapter test. |

The confirming pass covered independent workout/navigation presentation,
navigation-only relaunch recovery, combined BLE demand transitions, immediate
credential reconciliation, route expiry, future archive/journal schemas,
default-off and mid-route policy behavior, GPX import security and geometry
selection, local versus acknowledged deletion, iOS 16 availability, and
release/privacy copy. MapKit remains active-session only; the implemented
offline source is user-provided GPX.

The shared route/GPX suite, Watch offline suite, Watch online manager suite,
workout contract suite, full portable iPhone navigation/Catalyst suite,
capability suite, lease suite, scoped payload suite, and ownership/crypto state
suite pass. The generated app-identity suite also passes after the clean-CI
contract correction. The complete Watch source graph type-checks against watchOS 10 with
warnings as errors. The complete iPhone source graph type-checks against iOS
16.4. Watch and privacy plists validate, the Xcode project lists every expected
target, and `git diff --check` passes. The portable iPhone suite emits only its
pre-existing SDK 26 MapKit/CoreLocation deprecation warnings.

No PlatformIO target build or physical-device action was attempted because the
connected Bicino model has not yet been identified as required by repository
policy. No paired route transfer, offline/online ride, cellular transition,
direct Watch BLE session, revocation/replacement/reset sequence, wrist-down
measurement, or two-hour battery/thermal run has been recorded. The Apple Maps
accessory-display and durable-export determination also remains unapproved.
Issue #106 has therefore not been updated with completion evidence. Phase 6
software work is complete, but the release gate remains open until those
external and physical checks pass.
