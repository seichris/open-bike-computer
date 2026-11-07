# Implicit state machines in the iOS app, the Watch app, and across devices

Companion to [firmware-implicit-state-machines.md](firmware-implicit-state-machines.md).
Inventory taken on 2026-11-07 at `fd0689c8`. Read-only survey of
`ios-app/BikeComputer/` (iPhone app, Watch app, shared contracts; about 135k lines
including tests) plus a cross-device pass over the protocols whose lifecycle is split
between firmware, phone and Watch. Firmware halves are cited by the IDs in the firmware
document (BLE-n, MAP-n, MT-n, TR-n, RA-n, SYS-n).

The definition of "implicit" is the same as in the firmware document: lifecycle or
phase state not held in one enum with one guarded transition function. In Swift the
recurring forms are `@Published` bool tuples, nullable models or tasks whose nil-ness is
the phase, attempt UUIDs and generation counters used as cancellation tokens, free
status strings compared by literal, lazy expiry inside getters, and persisted records
(UserDefaults, Keychain, files) shadowed by RAM flags.

Counts: **131 implicit machines** on the app side (114 iPhone, 17 Watch) and **11
distributed protocols**; about 60 explicit enums were passed, of which roughly 15 are
published labels or derived views rather than drivers.

Paths are relative to `ios-app/BikeComputer/`; line numbers are anchors into the files
at the SHA above.

---

## 1. iPhone: BLE manager (`BikeComputer/Managers/BLEManager.swift`)

**A-1 Connection lifecycle (phone half of BLE-1)** — `:1437-1448` central, peripheral
and eight characteristic optionals; `:1468` `isConnecting`; `:1095-1096` `isConnected`,
`isNavigationReady`; `:1154` capabilities received; `:1170-1171` active/connected device
IDs; `:1653-1656` connection (8 s) and auth (12 s) timers; `:1614-1616` link-lost/connected
uptimes. NoLink → Connecting → LinkUpUnauthenticated → Authenticated (`isConnected` is
only ever true after auth) → CapabilitiesKnown → teardown. Smell: the ~35-line session
reset is written three times (`adoptConnectionContext` `:7316`, `clearConnectionState`
`:7395`, `didDisconnect` `:10580`) with different subsets; the "device operation
interrupted" block is duplicated at `:7453` and `:10625`.

**A-2 Reconnect policy** — `:1549` `autoReconnect` (37 assignment sites), `:1683`
`suppressNextReconnect`, `:1552-1555` attempts/timer (1 s to 60 s, 30 attempts), `:1510-1511`
pending handoff IDs + timer, `:1550` last peripheral. Evaluated as an if-chain in
`didDisconnect` (`:10620-10670`): HandoffPending / WaitForAdvertisement / ResumeExplicit /
PairingInterrupted / SuppressedOnce / Backoff / Idle. Smell: `autoReconnect` is a mode
flag mutated by pairing, deregistration, watch-direct, discovery, lifecycle and auth
failure, so its value at disconnect is whichever path ran last; `suppressNextReconnect`
can stay armed if the disconnect callback for that link never arrives.

**A-3 CoreBluetooth state restoration** — `:1438-1440` `pendingBluetoothRestoration`
closure, restored identifiers, `restoredSessionAwaitingAdvertisement`. NoRestore /
DeferredUntilPoweredOn / AdoptedConnected→Retiring (`:7364`) / AdoptedConnecting /
AwaitingAdvertisement (`:10270`). Smell: the awaiting-advertisement optional also means
"wait before connecting after a local cancel" (`:10636`).

**A-4 Authentication flow** — explicit `AuthFlowState` (`:1471`, seven cases) shadowed by
`:1470` `pendingAuthNonce`, `:1480` `authenticatedWriteSession` (non-nil = authenticated
transport), `:1481` queued messages, `:1483-1484` INFO fallback timer/attempts, `:1490`
`ownerAuthenticationUsesProvisionalKey`, `:1469` `isPairingMode` (14 writes), `:1294`
`firmwareMaintenanceReconnectExpected`. Five `.idle` resets. Smell: `authTimeoutTimer`
serves both the 12 s auth deadline and the 115 s pairing-code deadline (`:7854`, `:7869`),
so starting one cancels the other.

**A-5 Pairing session** — `:1487-1489` pending session/material/candidate; `:1172-1176`
prompt, submitting, completed generation, status, error; `:1490` explicit
`BLEOwnershipLifecycle`; `:1534` discovery origin. None → SessionCreated → ConnectingForPairing
→ PairingSent → MaterialStaged+PromptShown (`:7999`) → ConfirmationSubmitting → PAIRED →
owner auth with provisional key → Completed (`:8899`) | Cancelled | Interrupted | Failed.
Smell: three teardown functions clear overlapping but non-identical sets.

**A-6 Scan purpose / discovery** — `:1164` explicit `currentScanPurpose`, `:1094` `isScanning`,
`:1163` `isDiscoveringDevices` (hand-maintained copy), `:1515-1516` start work item and last
stop, `:1526-1527` discovery generations, `:1514` freshness timer, `:1531-1533` explicit-
discovery flags, `:1167-1168` opportunistic suppression, `:1166` app active. Desired purpose
is recomputed from ~10 bools; physical state is NotScanning / DrainingCallbacks / Scanning /
Stale. `reconcileScanning` (`:2795`) is called from ~40 sites with a free-text reason.
Smell: `explicitDiscoveryRequested` (17 writes) and `isOpportunisticDiscoverySuppressed`
(16 writes) are both inputs and outputs of the same reconcile.

**A-7 Opportunistic nearby candidate** — `:1165` candidate, `:1530` presented, `:1524-1525`
1 s seal timer + expiry timer, `:1528` observations, `:1519` gate. Observing → SealPending
→ SealedUnpresented → Presented → Dismissed | Expired | ConsumedByPairing. Cleared at six
sites; survival across a connection decided by a policy call evaluated in three places.

**A-8 Watch-direct ride handoff (phone half of W-4)** — `:1540-1547` prepared device/
preparation IDs, previous auto-reconnect, handoff disconnect peripheral, 24 h expiry timer,
reconciliation timeout; `:1803` release tombstones; persisted in UserDefaults (`:3072-3135`).
NotPrepared → Prepared (auto-reconnect forced off, link cancelled) → Released | Expired |
RestoredFromDefaults. Smell: "prepared" is two nullable IDs that must both match; the
previous auto-reconnect value is captured only on the first prepare.

**A-9 ATT write-with-response wait** — `:1584-1613` `PendingATTWrite` (owner, write ID,
generation, stage), handlers, 5 s timeout, response generation, backpressure start;
`:1557` 50 ms flush retry. Idle / InFlight / TimedOutFenced × NoBackpressure / Backpressure /
Recovering. Completion sequence written twice (`:9705`, `:9732`).

**A-10 Ride application delivery (RCM1 acked commands)** — `:209-224` per-command
`writes`, dispatched members, completed uptime, retry count, 5 s ack timer, `isFinished`;
`:1620-1632` delivery connection generation, state generation, `pendingNavigationClear`
intent. Queued → PartiallyDispatched → AllDispatched → Acknowledged | Dropped |
TransportFailure | TimedOut→Retry | Reconnect. Smell: `isFinished`, dictionary membership
and generation equality are three validity checks every callback repeats; the clear
intent survives reconnect but is superseded silently by new route state (`:4309-4338`).

**A-11 Ride transport reducer + recovery deadline** — explicit
`RideBLETransportStateMachineV1` (`:1621`) invoked from ~25 sites with the generation read
immediately before; `:1650-1651` recovery cancellation timer whose expiry is explicitly
non-terminal ("does not prove disconnection").

**A-12 Watch controller enrollment** — explicit `PendingWatchControllerOperation` (`:1493`)
plus `:1504-1505` status received / promotion in flight. Idle → Staging → RequestingProof →
Committing → Promoting → Done; Revoking. Smell: the two Watch round-trips are tracked by a
bool and by "enum still equals `.committing`" captured in a closure (`:8297`); promotion in
flight is reset on disconnect but not on the WC failure path.

**A-13 Device operation (rename / deregister)** — `:1506-1508` pending IDs + 12 s timer;
`:1177-1178` operation/feedback device IDs. Idle → RenamePending | DeregisterPending →
Confirmed | TimedOut | DisconnectedBeforeConfirm. Four clear sites reset the same five
fields; `pendingDeregistrationDeviceID` is cleared at seven sites in total.

**A-14 Per-connection "already sent" latches** — `:1671-1679` six `hasSent*ForConnection`
bools + `isSendingNegotiatedMapProfiles` + last phone battery. Cleared wholesale at `:7625`
and `:11164`; re-armed by six separate capability-diff ifs at `:11400-11431`.

**A-15 Status chunk reassembly (phone half of BLE-14)** — `:1558-1565` map, device-transfer
and renderer chunk sets. Idle → Collecting(ID, count) → Complete. Two hand-copied
implementations plus one encapsulated reassembler.

**A-16 Power-button honk retry** — `:1657-1668` packet, attempt, retry work item, 1 s ack
timeout. None → Sent → Acked | RetryScheduled | Failed. Targets a feature the firmware
forces off (SYS-7), so it never reaches Acked on current firmware.

**A-17 Diagnostics capture binding** — `:1663-1665` desired binding, retry work item,
retry pending; `:1191` generation; `:1192` explicit marker delivery state. NoDesire /
DesiredUnsent / Queued / RetryPending. `retryPending` survives disconnects; the generation is
bumped but not read in this file.

**A-18 Firmware maintenance reconnect expectation** — `:1290-1294` active/stage/
correlation/expected. A two-state flag that changes the meaning of A-4, A-17 and map
transfer mode (`:8847`, `:8921`, `:6391`).

**A-19 Published mirrors of firmware map state** — `:1209-1215` library pages, pending
library command ID (`defer`-cleared), selection health projection + epoch; `:1241-1259`
activation status string (mirror of MT-9), fresh-status flag, operation status +
observation generation + epoch. Receive-side projections keyed by connection epoch.

**A-20 Smaller latches** — GPS override token (`:1566`, cleared at four sites); setting
write generations (`:1201-1202`); destination status sequence and catalog transfer ID;
locally forgotten peripherals (`:1535`); `isLoadingSettings` one-shot; transfer-failure
dedupe key.

## 2. iPhone: ownership, coordinator, navigation protocol, app shell

**B-1 ContentView sheet handshake** — `BikeComputer/ContentView.swift:106-128`
`presentedSheet`, `queuedSheetAfterDismiss`, `activeSheetDestination`,
`isSheetDismissalInFlight`, map-setup latch, favorite/route-search latches (optional plus
a bool because nil is legal), pairing completion generation, pending app link. NoSheet /
Presented / DismissalInFlight / +Queued / +MapSetupLatch / +RouteSearchLatch /
DeviceIntroQueued. Smell: "a sheet is blocking" is the OR of six fields computed in three
places; `isSheetDismissalInFlight = false` is written at 11 sites; two `Task.yield` re-checks
make the terminal state depend on SwiftUI commit timing.

**B-2 Route calculation generation** — `BikeComputer/Managers/BikeComputerCoordinator.swift:169-198`
four in-flight searches, `routeCalculationGeneration`, pending start (generation,
completion), pending plan, `routeCalculation{isCalculating,status}` (free string),
`wasNavigating`, `isSimulationMode`. Idle / Searching / Directions / AlternativesPresented /
Navigating / OfflineNavigating. Smell: "cancel everything + bump generation" is written four
times with different subsets (`:981`, `:1445`, `:1478`, `:1018` omits the bump);
navigation-active is mirrored three ways.

**B-3 Device-initiated destination request (phone half of BLE-9)** — `:193-197` location
request, observation, 5 s location timeout, 13 s deadline, route generation; location
manager `isRefreshingDeviceDestinationLocation`. Idle / AwaitingFreshLocation /
RouteCalculating / Finished / TimedOut. Teardown of five cancellables duplicated at
`:1331` and `:1435`; the status retry lives in BLEManager, so the terminal write can still
be lost after this machine reports Finished.

**B-4 Screen-configuration sync session (phone half of BLE-10)** —
`BikeComputer/Managers/DeviceScreenConfigurationController.swift:168-182` device IDs,
`preserveDraftOnSnapshot`, connection generation, snapshot/save request IDs, save document/
CRC/base revision, 650 ms autosave, 5 s request timeout, chunk reassembler (`:80-85`).
The explicit sync state (loading/ready/saving/conflict/failed/legacyUnsupported) is written
from ~14 sites; SnapshotInFlight, SaveInFlight, AutosaveArmed, DraftPreserved and
Reassembling are outside it. Smell: one timeout task serves both request kinds; leaving
`.conflict` depends on the user because the automatic re-snapshot early-returns (`:303`).

**B-5 Location tracking / stall recovery** — `BikeComputer/Managers/CurrentLocationManager.swift:349-377`
recovery timer, tracking/usable/recovery stamps, paused, deferred, nine demand bools, three
authorization one-shots. NotUpdating / Updating / Stale(45 s) / Paused / RecoveryDeferred /
Recovering(30 s). Smell: the one-shots never reset so a denied-then-reauthorized flow cannot
re-prompt; `isRecoveryDeferred` cleared in three places.

**B-6 Ownership provisional credential (phone half of BLE-4)** — explicit
`BLEOwnershipLifecycle` (`BikeComputer/Managers/DeviceOwnership.swift:665-745`) surrounded
by the registry triple: Keychain provisional key, defaults `provisionalConfirmed`,
`provisionalReplacementAuthorized` (`:1247-1480`). NoCredential / Provisional /
ProvisionalConfirmed / +ReplacementAuthorized / Promoted / PartiallyRemoved (Keychain has no
transaction). Only `hasConfirmedReplacementCredential` (`:1364`) reads all three stores.

**B-7 Scan purpose context** — `:273-313` ten-input context → derived `BLEScanPurpose`;
`:245-266` unknown-scan gate (generation + seen-once set); `:167-205` order stabilizer
(5 s); callback drain (100 ms). The enum is derived every evaluation, the generation gate is
the real phase.

**B-8 Navigation elevation delivery** — `BikeComputerCoordinator.swift:199-205` sync,
task, retry task, subject, key, state, progress. NoRoute / Loading / Ready / Unavailable+
RetryArmed / Stale (progress key ≠ route key). Phone state and device
`RouteElevationStateV1` are two copies reconciled by `onStatusChange`.

**B-9 Destination catalog publication** — `:187-192` generation (nil = never), next
generation (random, wraps to 1), fingerprint, token map, retry work item. Smell: retry is
created only when nil, so a failed publish during an active retry is dropped.

**B-10 Reroute detector** — `BikeComputer/Utilities/NavigationProtocol.swift:617-675`
consecutive off-route samples (0..3) + coordinator `:173-178` reroute location/observation/
request (15 s cooldown). Reset in three places.

**B-11 Route progress matcher / send tracker** — `NavigationProtocol.swift:901-953`,
`:1072-1108`. Tidy single-struct machines; listed for completeness.

**B-12 Navigation write queue retry window** — `BikeComputer/Utilities/NavigationWriteQueue.swift:256-260`
pending/priority writes, `retryStartedAtUptime` (cleared in six places), per-write validity;
in-flight phase lives in metrics (`:118-124`) owned by BLEManager.

**B-13 Watch ride demand state** — `RideShared/WatchDirectBLEContract.swift:620-668` four
bools (`navigationActive`, `workoutActive`, two release-pending). Guarded setters; the combo
`navigationActive && workoutReleasePending` is legal but unnamed.

**B-14 Watch outbound group queue** — `WatchDirectBLEContract.swift:915-1137` entries with
sequence, priority, disposition, coalescing key, critical reserve; `RideBLEMotionDispatch`
ordering (`:671-720`). Pure and tested; the per-command phase (pending → acked / ignored /
invalidLease) is decided here and held in the Watch link (W-6).

**B-15 Scoped Watch authentication handshake** — `:46-200` hello → acceptServer → finish;
per-channel sequences whose overflow is an unnamed "session exhausted" terminal. Same shape
as the phone's `AuthenticatedBLEWriteSession` (`DeviceOwnership.swift:1064-1180`).

**B-16 Onboarding latches** — `ContentView.swift:131-141` five `@AppStorage` bools plus
five `@State` bools; `visibleOfflineMapOnboardingStep` is derived (`:1608`);
`shouldShowMapSwitchPrompt` (`:1585`) is a 16-term predicate; `prefersIPhoneOnly` is
rewritten whenever the known-device count changes.

**B-17 Workout segment toast / ride-metrics sheet sync** — `:114-115`, `:608`, `:713`,
`:1120-1130`. Small; a `.task(id:)` auto-dismiss keyed on the segment index.

**B-18 Application-active fan-out** — `BikeComputer/BikeComputerApp.swift:396-445` and
`ContentView.swift:578-597`: UIKit delegate and SwiftUI `scenePhase` both drive ~8
consumers; ordering between the two sources is implicit.

**B-19 Device capability refresh generation** — `BikeComputerCoordinator.swift:180`,
`:393-412`; generation bumped on every readiness edge, no named "refresh in flight".

## 3. iPhone: offline maps (`BikeComputer/Managers/OfflineMapManager.swift` and models)

**C-1 Last-transfer outcome string (phone view of a device install)** — `:2289-2294`
`lastTransferOutcome` (literals `""`, uploading, activating, unconfirmed, installed, failed,
cancelled, unknown), map ID, idle-on-another-map, connection epoch (RAM only); ten
UserDefaults keys (`:7817-7832`); per-pack mirror in `SavedMapLocalRecord` (`:1602-1613`).
`hasPendingDeviceActivation` is literally `== "unconfirmed"` (`:2338`). Transitions:
`recordTransfer` (`:7661`), `updateLastTransferOutcome` (`:7754`, re-derives from the
journal), `reconcileLastTransfer` (`:4819`), `confirmActivatedMap` (`:7257`),
`restorePendingDurableTransfer` (`:4772`). Smell: compared as a string in ~25 places;
three persisted copies reconciled by hand on every relaunch with the journal authoritative;
the epoch is RAM-only so a relaunch cannot bind a legacy result.

**C-2 Durable device-operation journal** — `BikeComputer/Models/DeviceMapOperation.swift:138-139`
`observation` and `cleanup` strings, receipt phase/status/revision, commit/cancel/
acknowledged/retired stamps, legacy terminal stamp, upload attempt, admission epoch/revision,
fenced retirement proof, previous selection; pointer in UserDefaults (`OfflineMapManager.swift:4424`).
observation ∈ in_progress / commit_requested / cancel_requested / commit_accepted /
installed_confirmed / failed_or_rolled_back / cancelled_before_commit / result_unknown ×
receipt phase × cleanup × acknowledged/retired. `apply(receipt)` (`:222`) is monotone by
revision and phase rank; `save` holds ~15 invariant guards (`:325-375`). Smell: the
vocabulary is spread across two files; `result_unknown` is written from the manager
(`:7770`); the manager rewrites `observation` for legacy records from a UI outcome
(`:7767`); pointer and journal can name different operations.

**C-3 Activation reconciliation (legacy, sequence-based; phone half of MT-9)** —
persisted previous/accepted sequences, `observedCurrentAttempt`, idle-on-another-map,
`activationReconciliationTask` (`:2393`), fresh-status flag. Pure `MapActivationReconciler.
evaluate` (`:763-860`, serial-number arithmetic) plus `CachedPackRecoveryDecision` and
`ExistingMapStreamAttemptDisposition`. Smell: the device's activation status string is
matched by literal in four policy enums; the monitor's only exit is the outcome string
changing, so a device that never reports stays polled.

**C-4 Background upload task lifecycle** — `BikeComputer/Models/OfflineMapPlatform.swift:3519-3525`
pending uploads, retired IDs, network claims, completed IDs, buffers, completion handler;
persisted `BackgroundMapUploadRecord` (`:3290-3348`); URLSession `getAllTasks`. Started /
Waited / Retired / CompletedSuccess / CompletedFailure / CompletedBeforeWaiter (`:3608`).
Smell: three sources of truth for "upload active"; `markStarted` reachable from three paths;
the manager caches `hasActiveBackgroundUpload` (`:2281`) asynchronously so guards read a
stale snapshot.

**C-5 Durable map download ownership** — `BikeComputer/Managers/DurableMapDownloadCoordinator.swift:10-22`
on-disk `Ownership{attemptID, constraints, phase}` (active/cancelled/finished/failed) +
resume file, waiters, `blockedAttempts` (RAM fence), cancellation callbacks, background
events. Explicit phase enum, but the real state is the triple (owner file, resume file,
waiter); `blockedAttempts` is lost on process death.

**C-6 Map job lifecycle** — UserDefaults `activeJobId`, install flag, server URL, downloaded
job/map IDs (`:1316-1389`); RAM `currentJob`, task + task ID, `isMapJobProcessing`,
`isServerRecoveryCheckPending` (`:2283`), download URLs/progress; recovery history (`:2025`).
NoJob / DiscoveryPending / JobPersistedNotDownloaded / DownloadedAwaitingInstall / Paused /
TerminalFailure / Forgotten. Smell: "pending" is derived in four computed properties with
different predicates; the recovery-pending flag is set once and cleared in four places; the
server job status is matched by literal.

**C-7 Terminal transport cleanup** — `:2394-2395` task, attempts (epoch, count), record
`cleanup` string. NotNeeded / Due (12-condition guard `:4733`) / InFlight / Exhausted
(3 per epoch) / Complete. Two paths mark complete with different preconditions.

**C-8 Fenced retirement of a pre-commit upload** — `DeviceMapOperation.swift:51-59` proof,
`originalUploadIsFenced` (~20 field guards), before/after status revisions.
`isRetiredUnknown` re-validates the proof on every read, so a later rule change silently
un-retires old records.

**C-9 Catalog pending-alias sync** — `BikeComputer/Models/OfflineMapCatalog.swift:1024-1071`
pending aliases (pending / conflict), request tokens (`OfflineMapManager.swift:2308`).
Token and alias dictionaries kept in step by two helpers (`:3825-3840`); conflict is terminal
with no resolution path except re-rename.

**C-10 Saved-map catalog sync state** — `SavedMapLocalRecord.catalogSyncState` (`:1621`,
`pending` / `synced` / nil), entry/receipt IDs, non-durable copies (`:2387`), two
single-flight tasks (`:2390-2391`). nil and "pending" treated alike in one guard (`:5347`)
and differently in another (`:5516`).

**C-11 Installation credential + refresh backoff** — `:2379-2380` installation ID/token,
Keychain-or-defaults store (`:1450-1525`), 25 h deferred-until per server (`:1405`),
single-flight bootstrap (`OfflineMapCatalog.swift:1113`). Clean apart from the timestamp
phase.

**C-12 Activity / busy flags** — `:2086` activity counter, `:2279-2281` `isBusy`,
`isMapJobProcessing`, `isDeviceTransferBusy`, `hasActiveBackgroundUpload`. "Idle" is spelled
as a different subset in at least six guards.

**C-13 Topography overlay reload generation** — `:2399-2400` task + UUID generation,
`:2298-2301` overlay + status string; overlay `tileTasks` (`BikeComputer/Views/BicinoTopographyTileOverlay.swift:230-262`);
companion store `metadata` nil = not validated (`BikeComputer/Models/TopographyCompanionStore.swift:371`).
A failed validation re-runs the full hash walk on every tile request.

**C-14 Preview load registries** — `:938` token registry, `:2406-2413` tasks, sticky
unavailable sets, LRU of 3. Two parallel single-flight mechanisms.

**C-15 Pending share / link code** — `:2392`, `:2305-2307`. Nullable-pointer phases only.

**C-16 Map area selection** — `:2284-2285` `isMapAreaSelectionActive`, `selectedMapBounds`.
Two bools, one unreachable-by-intent combo.

**C-17 Migration one-shots** — `:53-60`, `:1974`, `:1589`. Migrated vs not is the absence
of a legacy key; no record of a partial migration.

## 4. iPhone: transfer, OTA, diagnostics, benchmarks

**D-1 Transfer operation lease lifecycle (phone half of TR-1)** —
`BikeComputer/Managers/DeviceTransferManager.swift:1142-1161` joined SSID, lease, cleanup
task, static passive cleanup task and starting set, passive attempts (epoch, count),
`remoteAcceptancePossible`, `firmwareMaintenancePrepared`, authorization token/generation;
`BikeComputer/Managers/DeviceOperationCoordinator.swift:33-41` lease, claims, pending
applies, SSID, unresolved, unreadable record, recorded SSID, token digest, transfer
generation; UserDefaults `device-operation-cleanup-v1`. Idle → AcquiredUnauthorized →
EnterQueued → Authorized → NetworkConfigured → Serving; CleanupRunning / FinishedClear /
FinishedUnresolved (stranded owner) / UnreadableRecord / PassiveReconcile / RecoveredAdopted /
ResumedMapRoot / Rebound. Smell: "owns" is a three-way comparison evaluated at ~20 sites;
the auth triple is reset in four places (two partial); Idle and Stranded are
indistinguishable from the manager's own fields; `restoreClaim` sets `claims = []` while
`lease != nil`, a state no other path produces.

**D-2 BLE link-loss rebind continuation (phone half of TR-2; PRs 746/749)** — pure
`DeviceTransferLinkRebindPolicy` (`:661-760`, 15 s per link, 45 s cap, `remoteCleared`) plus
loop locals in `rebindAfterLinkLoss` (`:1272-1359`): loss uptime, last status request,
(epoch, revision). Owned → Waiting → Rebound | Stale(remoteCleared false|true) | Expired,
polled every 250 ms inside the cleanup task. Smell: `lossUptime` falls back to the cleanup
start when BLEManager never observed the loss; rebind refuses whenever an OS background
claim is retained (`DeviceOperationCoordinator.swift:140`, `:222` require
`claims == [lease.id]`), which is exactly the map-upload case, so a map transfer cannot
rebind.

**D-3 Accessory Wi-Fi join loop** — `joinDeviceNetworkIfNeeded` (`:2694-2991`) locals
(stale rejoins, last apply error, last diagnostic, probe failure flag, accepted-without-
association, keep-applied, association accepted); `DeviceNetworkApplyGate` (`:980-1083`,
explicit resolution enum + four bools); observation gate; coordinator pending applies.
AlreadyOnTarget / StaleAssociation / ApplyRequested / ApplyCallback / ApplyTimeout(60 s) /
Observing(12 s) / ProbeWindow(20 s) / Ready / Retry / Terminal. Smell: `keepAppliedConfiguration`
is a `defer`-driven side channel; `lastApplyError` is nulled in two branches; the loop
breaks from three places with different meanings.

**D-4 Firmware update transaction (phone half of TR-4/TR-5)** — UserDefaults
`PendingFirmwareUpdate` (`BikeComputer/Managers/FirmwareUpdateManager.swift:307-325`):
`status` free string, explicit 11-stage `transactionStage`, maintenance correlation,
operation ID, image hash, `requiresOperationReceipt`; retained results map; `isBusy`,
`statusMessage`, device status. `reconcilePendingUpdate` (`:1008-1083`) re-derives
Installed / Failed / AwaitingCompletion / RolledBack / Cancelled / Unresolved from the BLE
snapshot every call. Smell: `updatePending(stage:)` accepts any stage from any stage;
status string and message duplicate the stage at ~25 sites; the stage membership lists that
decide rolled-back vs unresolved differ between the reconcile path (`:1066-1072`:
finalizing, rebooting, unresolved) and the error path (`:1220-1224`: also
maintenanceRequested); `finalized = true` is set before `client.finalize()` returns.

**D-5 Firmware maintenance handshake** — `prepareFirmwareMaintenance` (`:2180-2260`) and
`performEnterFirmwareTransfer` (`:1979-2110`) locals: expected correlation, saw disconnect,
enter queued; BLE maintenance stage string. Requested → RebootPending → Disconnected →
ReconnectedUnconfirmed → MaintenanceReady → EnterQueued. The reconnect-and-confirm loop is
written twice; `firmwareMaintenancePrepared` is a silently consumed one-shot.

**D-6 Diagnostics collection job** — `BikeComputer/Managers/DiagnosticsCollectionCoordinator.swift:11-38`
running, status, manifest, task, automatic retry allowed, user cancelled, restore
started/finished/failed, selection task, operation generation, last block reason, ride
active, deleting, ride contexts (≤8), journal task + generation; persisted manifest phase
(requested/collecting/partial/complete/cancelled) + failure code + origin. Smell: "resumable"
is a store-side predicate (`:86-92`) AND a RAM flag written at eight sites, and the two can
disagree; the operation generation is bumped from four places; `start`'s `defer` calls
`resumeIfPossible`, so completion can immediately restart a job.

**D-7 iOS diagnostics recorder** — `BikeComputer/Utilities/RideDiagnostics.swift:616-668`
capture binding snapshot, sequence, chunk number/URL/bytes, pre-detailed context, standard
capture ID/start, active capture ID, detailed trace active/expiry (4 h), pending records +
drain scheduled + admission drops, storage outcomes + draining, errors by scope, policy
state. Standard ⟷ Detailed × chunk Open/Rotating × mailbox Idle/DrainScheduled/Draining ×
policy None/Applied/Expired/BudgetExhausted (derived). Smell: the detailed-trace end is
written in `endDetailedTraceOnQueue` and partially again in `prepareStorage`
(`:1515-1521`); an `asyncAfter` timer and lazy expiry on drain race, guarded only by
expiry equality; the policy request stays installed after expiry (mirrors RA-4).

**D-8 Diagnostics broker client** — `BikeComputer/Managers/DiagnosticsBrokerClient.swift:121-143`
paired, status string (~20 literals), pairing (enrollment pending = `enrollmentRequest`
non-nil), rejected count, active, loop, export/reconciliation tasks, deleting, journals,
loop generation, live leases; outbox files (`<id>.zip`, `delivered-<id>.txt`,
`rejected-<id>.json`). Unpaired → PairedInactive → Enrolling → Polling (5 s to 60 s) →
Denied | InboxFull | Unavailable. Smell: the loop-cancel triple is repeated five times; the
file-system outbox has three marker kinds and no classifier (MT-1 in miniature).

**D-9 Secure renderer benchmark sweep** — `BikeComputer/Managers/SecureRendererBenchmarkController.swift:305-334`
terminal outcome, export retryable, stop reason, measurements done, active gates, pending
export, running, status, task, stop requested, client, expected session, profile restoration,
startup evidence, idle timer. Idle → Preflight → Running → StopRequested → Cleanup →
Terminal → ExportPending | Exported. Smell: terminal classification is
`didFinishMeasurements ? completed : requestedStopReason ?? error` with `stopRequested` as a
third copy; `profileMayNeedRestoration` toggled at six sites; `start` resets ~20 fields by
hand.

**D-10 Renderer replay coordinator** — `BikeComputer/Managers/RendererBenchmarkReplayCoordinator.swift:8-31`
running, status string (the de-facto phase: `stop` compares `status == "Running at 1 Hz"`),
fixture, GPS override token, idle-timer flags, repeat number; scheduler task + generation.
`start` calls `stop` first, so failure branches release the override by hand (three sites).

**D-11 Device diagnostics download** — `BikeComputer/Managers/DeviceDiagnosticsTransferManager.swift:195-400`
locals: opened session, imported, per-boot sequences/fingerprints, truncated boots; store
receipts expected/verified. NotEntered → Entered → IndexFrozen → Reserved → ChunkLoop →
Verified. Clean apart from the entered bool standing in for phase.

**D-12 Diagnostics session entry with LAN→hotspot fallback** — `:2271-2416` locals
(enter queued, rejected before session), `networkTransport` string (mirror of TR-1), fallback
attempts. The compensating `stopDiagnostics` between attempts exists for old builds and is
unconditional.

**D-13 Remote-debug session observer** — `:2660-2696` observer, 2 s poll, lease mode
"debug", BLE mode/token emptiness. Stop called from four sites; a late empty status after
cleanup re-enters `recover` once.

**D-14 Remote-debug settings UI** — `BikeComputer/Views/SettingsView.swift:3538-3890`
`isWorking`, status/error strings ("Idle" / "Requesting session" / "Failed" / "Ending
session" / "Session ended"), passphrase reveal/copied, loaded LAN credentials. UI level.

**D-15 App Attest enrollment key store** — `BikeComputer/Services/ManagedAppAttestClient.swift`
Keychain active key, UserDefaults pending enrollment (key, previous key, installation,
challenge expiry, attestation), `rotationRequired`; explicit `ReconciledKeyState` result.
NoKey → PendingChallenge → PendingAttested → Active; Active+RotationRequired. Pending
validity is a five-term predicate; `markRotationRequired` is set inside a query.

**D-16 Server-probe readiness window** — `:468-520`, `:3127-3178` attempt, last error,
consecutive no-route probes, stale association. Probing → Ready | NonRetryable |
StaleSuspected | Deadline. Contained.

**D-17 Small ones** — `MapTransferStartupPolicy.waitForSession` (`:414-440`, 30 s, never
renewed); fresh-failure policy (`:1125`, "fresh" = error sequence advanced past the link's
first revision); observation gate one-shot; unreadable cleanup record poison bit;
once-per-device automatic check latch; benchmark window cooldown; rejected handoff count.

## 5. iPhone: workouts, ride automation, Watch connectivity, services

**E-1 Mirror transport attachment + terminal-failure drain** —
`BikeComputer/Managers/WorkoutMirrorManager.swift:156-182` mirrored session storage,
attachment ID/session ID/start date, drain timeout task + attempt, pending terminal
failure code/session/origin start/origin storage/origin attachment, handler installed.
NoTransport / Attached / AttachedReconnect / Draining (origin retained, credentials
withheld from replacements) / DrainTimedOut / VerifiedNewSession. Smell: six optionals
define "draining"; `resetRemoteTransport` (`:1083`) clears 17 fields from four callers;
"new session" is judged by start date, falling back to attachment ID.

**E-2 Remote control queue / in-flight send / confirmation windows** — `:167-196`
sequencer, queue, `remoteSendInFlight` (didSet cancels the 8 s deadline task), segment
replay message + attempt, control timeout task/attempt/control/sequence, final snapshot
timeout. Queued → InFlight → SendBarrierRetired | SendCallbackDone → Confirmed |
ConfirmationTimedOut. Smell: two clocks per control plus a third for terminal controls,
each with its own attempt UUID; the confirmation timeout starts at submission, so a control
stuck behind a barrier has no bound; terminal timeout and deadline task race to retire the
same barrier (`:697`).

**E-3 Phone recorder lifecycle (HealthKit-confirmed)** — `BikeComputer/Managers/PhoneWorkoutRecorder.swift:24-67`
explicit `state` written at 14 sites with no guard (the shared `WorkoutLifecycleReducer`
exists in `WorkoutShared/WorkoutRuntimeLogic.swift:38` and is not used here), four
finalization bools (collection started/ended, finish attempted, save confirmed), recovered
route, attach pending, generation UUID, native transition task/ID/generation, transition
origins, control timeout, flush task. Idle → Starting → Running/Paused (+TransitionRequested,
10 s) → Ending{open | collectionEnded | finishAttempted | saveConfirmed} → Ended; recovery
AttachPending → Attached → Reconciled. `resetFinished` (`:542`) is a 12-field reset.

**E-4 Session coordinator recovery / ownership arbitration** —
`BikeComputer/Managers/WorkoutSessionCoordinator.swift:51-66` record, recovery complete,
notice, recovery/start tasks, pending automatic choice, storage failed, resetting, phone
recovery deferred for Watch, Watch retry session, primary recovery required. NotRecovered →
Recovering → Recovered | RecoveryFailed × DeferredForWatch × AutomaticChoicePending ×
WatchRetryPending × Resetting. Smell: `recoveryComplete` is set false from three places so
"recovered" is not monotonic; `pendingAutomaticChoice` cleared in seven places; readiness
recomputed in two spots.

**E-5 Persisted recording record phase** — `WorkoutShared/WorkoutRecordingOwnership.swift:44-112`
explicit `Phase` (starting/running/paused/finishing/unresolved/finished) + finish choice,
finished choice, save attempted, pending native transitions; legal combinations enforced by
`isValid`, only finishing/finished built through guarded builders. E-3's flags are its RAM
shadow.

**E-6 Ride automation pending decision (phone half of RA-1)** —
`BikeComputer/Managers/RideAutomationCoordinator.swift:15-41` pending decision (nil /
unresolved / `resolvedResult != nil`), 30 s timeout task, prompt countdown task, resync task,
per-generation watermarks, acknowledgements by decision, per-device generation/monotonic/
config/retry maps, start annotation requested, prompt + seconds remaining. None → Pending
[+PromptShown] → Resolved (kept, re-sends confirmation + config every 30 s) → Cleared;
Superseded; RestoredAtLaunch. Smell: resolved-but-not-cleared is a third phase encoded as a
field inside the optional; the same task serves "unresolved → timeout" and "resolved →
periodic resend", chosen by inspecting `resolvedResult` at fire time (`:872-900`);
persistence failure rolls back the watermark but not the pending decision (`:685-696`).

**E-7 Live Activity reconciliation** — `BikeComputer/Managers/WorkoutLiveActivityController.swift:287-307`
managed activity/session IDs, last published content/at, pending presentation, processing
task, pending metric content, metric due, metric/activity/reconciliation/grace tasks,
`hasReconciled`, within-grace, grace-expiry pending, foreground, system-ended set.
NotStarted → Reconciling → InGrace → GraceExpiryQueued → Reconciled; Managed / Unmanaged.
Smell: grace expiry is signalled by queueing a presentation whose content is ignored; grace
bools cleared in two functions; background lease callback and timer both set the same flag.

**E-8 Device relay scheduler (phone half of BLE-12)** — `BikeComputer/Managers/WorkoutDeviceRelay.swift:95-109`
transport ready, last core/extended/origin frames + sent-at, core identity, pending
core/extended/origin frames, pair identity, pair generation (1..3), zone contexts; runtime
`:466-474` evaluation scheduled, motion identity, timer. TransportDown / ReadyIdle /
PairInFlight / OriginOnlyInFlight / Heartbeating × MotionInFlight. Smell: "in flight" is the
nullity of three frames cleared together in four places; pair generation wraps 1→2→3→1 so the
firmware pairing can confuse frames three pairs apart; `pendingZoneContext` not cleared on
`didNotWrite`.

**E-9 Watch-connectivity outboxes** — `BikeComputer/Managers/PhoneWatchConnectivityCoordinator.swift:28-41`
activated, intentionally cancelled transfers, controller revocation outbox + retry task/
attempt + per-request next attempt, direct-ride reconciliations (≤16, persisted) + retry task,
cached envelopes. Revocation: Queued → Sent(+30 s) → Receipted | Backoff (30·2ⁿ ≤ 300 s,
n ≤ 4). Smell: the attempt counter is global while next-attempt dates are per request;
in-flight reconciliations are not persisted, so a relaunch re-sends; `hasActivated` never
re-arms after `sessionDidDeactivate`.

**E-10 Strava coordinator** — `BikeComputer/Services/StravaIntegrationCoordinator.swift:107-148`
explicit `activity`, pending operation, authorized flag, OAuth session ID, three generation
counters (authorization, task, revalidation) + catalog generation, catalog active, tasks.
Idle → OperationPending → Authorizing → Authorized → Executing; Revalidating; Catalog.
Smell: three independent "cancel by bump" counters; the pending pair is cleared in five
places; the explicit enum is derived from these rather than driving them.

**E-11 Cycling-sensor observation reducer** — `WorkoutShared/WatchCyclingSensorObservation.swift:112-118`,
`:277-280`. Single `ingest` with ~9 ordered guards; clean. "Closed with no session" is
reachable only through the inactive-barrier branch.

**E-12 Navigation-distance fallback** — `BikeComputer/Managers/WorkoutMetricsStore.swift:45-49`
session ID, baseline, last, completed, advancing. Four fields for two phases; baseline
reset at three sites.

**E-13 Workout-service activity tracker** — `WorkoutMetricsStore.swift:4-29`
`unverifiedSince` (5 min grace). Clean.

**E-14 Watch-launch and first-snapshot timeouts** — `WorkoutMirrorManager.swift:163-166`
launch/first-snapshot/freshness tasks; the deadline lives in the reducer while the timer
that enforces it lives in the manager.

**E-15 Route batch queue / generation / timestamp gates** — `WorkoutShared/WorkoutRuntimeLogic.swift:348-656`.
Small pure latches held in bools; well tested.

**E-16 WorkoutViews local latches** — `BikeComputer/Views/WorkoutViews.swift:53-54`
`pendingStart` (cleared in seven or eight branches) + `presentedAlert`; `:529-530` segment
toast.

**E-17 Social coordinator** — `BikeComputer/Managers/SocialCoordinator.swift:38-74`
notification status, alerts authorized/denied, push token nil/set, relay nil until bound.
Minor.

Explicit but worth noting: `WorkoutMirrorStateReducer.connectionState`
(`WorkoutShared/WorkoutMirrorRuntimeLogic.swift:616`) is one pure struct whose state is
assigned at 23 sites across ~20 mutating methods, and whose "launching", "first-snapshot
wait", "terminal control timed out" and "segment unconfirmed" phases are flag combinations
around the enum.

## 6. iPhone: navigation, routes, views, services

**G-1 Phone→Watch route sync bookkeeping** — `BikeComputer/Managers/PhoneRouteLibrary.swift:56-71`
six persisted sets/dicts (ready receipts, pending deletions, pending installs, attempted
installs, rejected reasons, pending install start), four RAM sets (immediate installs,
queued provider deletions, two tombstone sets), deletion retry attempt/task, expiry tasks;
on-disk `WatchRouteOperationJournalV2`. The explicit `PhoneRouteWatchSyncStateV1` is
derived by `syncState(for:)` (`:1368-1381`) from set membership, and also assigned directly
at 10 sites. Hidden sub-states: TransferringImmediate, PendingInstallStale (>7 d),
DeleteQueuedToProvider, TombstonedAwaitingReceipt, journal-applied-but-not-unlinked.
Smell: four persistence calls repeated after nearly every mutation with per-site subsets;
the `.rejected` branch writes the state after `reload` recomputed it (`:1113-1121`);
`deletionRetryAttempt` resets only on a `.deleted` receipt.

**G-2 Navigation session (`NavigationEngine`)** — `BikeComputer/Managers/NavigationEngine.swift:38-89`
navigating, simulation, current route, offline archive + delete-after, accepted live
location + initial location, navigation epoch, initial-GPS retry cancellations, telemetry/
simulation timers, last device GPS, last geometry index/time; `sendTracker`. Idle /
LiveAwaitingStart (150 m gate) / LiveTracking / Simulating / LiveOfflineWithDeadline /
InitialGPSRetrying / GeometryResendPending. Smell: `beginNavigation` (`:241`) and
`stopNavigation` (`:431`) each reset ~25-30 fields with different members; the explicit
`NavigationRuntimeV1` holds the same lifecycle in parallel; three readiness paths can each
resend the same position.

**G-3 Group-ride sharing (`LiveRideService`)** — `BikeComputer/Services/LiveRideService.swift:53-95`
ride, sharing, notice (ordered latch), error, sharing revision, local epoch, retired epochs,
deadline, started, stream, publisher, socket, awaiting authorization. NoRide → Selected →
{StreamConnected | Reconnecting} × {NotSharing | AwaitingAuth | ConsentInFlight | Sharing |
Ended}. Smell: two cancellation tokens compared at ~20 guards; `isSharing=false` set in five
places; retired epochs cleared only on `reset`.

**G-4 Friend live sharing (`FriendLiveService`)** — `BikeComputer/Services/FriendLiveService.swift:14-61`
enabled, active, task, two generations, leases (epoch, deadline), remembered, persisted,
`unrecordedStop` (sticky), busy/pending/sharing sets, reserved sequence. Stopped → Restoring
→ Enabled{PollingFast 3 s | PollingIdle 60 s | NotPolling} × per-friend Off / Busy /
Sharing / Remembered. Two cancellation tokens for one loop.

**G-5 World Radio playback bridge (phone half of RA-16)** — `BikeComputer/Services/WorldRadioService.swift:441-449`
request task, candidates, index, failed stations, request ID, search generation,
`pausedByUser`, `hasPlayerItem`, status; player session (generation, intent). Idle /
Searching [+PausedWhileSearching] / HasCandidatesStopped / Connecting / Buffering / Playing /
PausedByUser / FailingOver / Error. Smell: the device-facing state is re-derived from five
fields on every emit; `hasPlayerItem` is set in `playCurrent` but only reset in
`stopPlayer`; `failedStationUUIDs` cleared only by `moveStation`.

**G-6 Device-operation lease & cleanup record** — see D-1; `BikeComputer/Managers/DeviceOperationCoordinator.swift:33-41`.
`isCleanupComplete` is the AND of five fields; "owns" differs between `rebindAfterMaintenance`
and `resumeMapRoot`; `unresolved` cleared in four functions.

**G-7 Durable background map download** — see C-5. `.cancelled` is resumable, `.finished`
terminal, and nothing prunes `.finished` except storage maintenance.

**G-8 Map tracking / initial region / free pan (`MapView.Coordinator`)** —
`BikeComputer/Views/MapView.swift:630-634` `hasSetInitialRegion` and five mirrored SwiftUI
inputs; selection frame, online POI flags, focused POI, saved-route overlay/identity/camera,
last route/polyline/coordinate/heading; `MKMapView.userTrackingMode`. UninitializedRegion /
Following / FreePan (derived from four sources, `:716-726`) / NavigationCamera /
SavedRoutePreview / OnlinePOIBrowsing. Smell: `hasSetInitialRegion` set true in four places
and false in one; tracking mode written both through the policy and directly (`:801-808`,
`:1021`, `:1329`).

**G-9 Route search panel (two copies)** — `BikeComputer/Views/RouteInputView.swift:78-83`
and `:589-595` four bools + selected destination + focus. Collapsed / DestinationTyping /
SuggestionsShown / DestinationSelected / EditingSource / SourceSelected / ApplyingSuggestion
(one-shot consumed on the next `onChange`). Implemented twice.

**G-10 Diagnostics export view** — `BikeComputer/Views/RideDiagnosticsSettingsView.swift:17-26`
exporting, task, URL, status message (phase and error), local/device marker status +
incident ID.

**G-11 Sensor detection prompt** — `BikeComputer/Managers/CyclingSensorDetectionCoordinator.swift:20-39`
looking, active workout, prompt, candidates, session ID, dismissed capabilities (persisted
per session), expiry task. Clean recompute; hidden state is the per-session dismissal set.

**G-12 / G-13** — benchmark controller and replay coordinator: see D-9, D-10.

**G-14 Watch-route operation journal** — `RideShared/NavigationRouteFileStore.swift:546-655`
per identity (operation, generation, applied). Issued → Admitted → Applied; "no entry" vs
"applied" vs "unapplied" distinguished by callers, not the journal.

**G-15 Strava bookmark lifecycle** — `PhoneRouteLibrary.swift:183-203`, `:461-600`.
Imported → ReloadAttempted → Validated → Expired (route removed, bookmark kept) → Deleted;
two paths call the same removal.

**G-16 Social notification binding** — `BikeComputer/Services/SocialNotificationBinding.swift:10-27`
explicit status + persisted bound owner / release pending; failures swallowed (`:115`).

**G-17 Pending account deletion** — `BikeComputer/Services/SocialAccountDeletion.swift:18-116`
persisted receipt + created-at grace; explicit resolution, implicit timer.

**G-18 Social rider relay** — `BikeComputer/Services/SocialRiderRelayEngine.swift:38-48`
epoch, eight slots, committed, expires, sequence, ack mailbox, needs restart (sticky). Per
slot Empty → Assigned → StatePublished → PortraitBegun → Chunking → Committed; `send`
(`:194-224`) is a 3×40 poll on a single ACK mailbox. Phone half of RA-6.

**G-19 Route elevation delivery driver** — `BikeComputer/Managers/RouteElevationDeviceSync.swift:12-15`
linked, timer, connected. Pure `pump` recompute; phone half of RA-7.

**G-20 Route elevation cache** — `BikeComputer/Managers/RouteElevationService.swift:272-276`
LRU, digests, failures (state, until), in-flight. Unknown / InFlight / Cached /
FailedUntil.

**G-21 Online POI session** — `BikeComputer/Managers/OnlinePOISearchSession.swift:160-169`
explicit state + generation, task, `retryAfter` (hidden Throttled sub-state reported as
`.failed`).

**G-22 Multi-stop planner & stop resolver** — `BikeComputer/Managers/MultiStopRoutePlanner.swift:90-115`,
`:341-399`. Explicit state plus request + generation + directions + leg cache deciding
restarts; resolver `pendingID` nil = idle.

**G-23 View-local one-shot latches** — `DeviceScreensSettingsView` save-in-progress /
saved confirmation (3 s); `StravaRouteImportView` initial completion sequence;
`BikeComputersSettingsView` discovery ownership (seven write sites) + selected candidate +
completion generation + disconnect confirmation; `SavedMapRow` share-after-dismissal;
`SavedMapsSettingsSection` removal map/device/epoch; `SocialProfileEditor` pending saves;
`SocialLinkView` completed + session generation; `RouteCreatorView` saving → completed
sheet handoff.

**G-24 Models with hidden phases** — `OfflineRouteSaveInteraction` (draft / result /
error); `SavedRouteRenameInteraction` (`editingRouteID` nil = idle);
`RideDetectionSettingsStore` decision state / load failed (sticky) / migrating;
`BicinoUserSession` explicit state but refresh task + Apple flow nil-ness are the in-flight
phases; `BicinoServiceSession.registrationTasks` dedupe; topography tile tasks + label
generation.

## 7. Watch app (`BikeComputerWatch/`)

**W-1 Terminal cleanup / detached finalization** — `Managers/WatchWorkoutManager.swift:398-402`,
`:496-511`, `:553-559` five published pending bools (archive, publication, mirror delivery,
start-failure mirror, retrying), authoritative end date, identity metadata retry, recovered
save mode, prepared route, terminal cleanup session ID/disposition, confirmed snapshot,
reconciliation gate, detached reconciliation, retry task/counters, pending error
persistence; plus `session`/`builder` nil-ness. `terminalCleanupState` (`:887`) *derives*
Delivering / Retrying / RetryRequired / None with sub-cases from ~10 bools. Transitions:
`completeFinalization` (`:3559`), `finishTerminalRuntimeAfterPublication` (`:3727`),
`retryTerminalPublicationAndArchive` (`:3763`), `releaseHealthKitObjectsAfterTerminalPublicationFailure`
(`:3796`, ~30 resets), `clearActiveObjects` (`:3836`), retry scheduling (`:1565-1652`,
exponential, 15 cap). Smell: the same reset block exists twice; the "lifecycle ended" edge
is applied before publication can fail, so `.ended` + publication-pending is live.

**W-2 Finalization persistence ladder** — `Managers/WatchWorkoutRecoveryStore.swift:118-185`,
`:280-365` finish request (disposition, phase, route status, error), identity (HealthKit
session ID, corrupt-reset synthetic identity and pending choice), terminal tombstone,
corrupt-reset authorization, takeover journal, sequence lease, load state. The explicit
`WorkoutFinalizationPhase` ladder (requested → collectionEnded → finishAttempted →
workoutSaved) is monotonic via `rank`, but applies only to `.save`; discard, tombstones,
takeover and corrupt-reset are parallel flag files. `reload()` (`:381`) collapses to four
load states and the manager re-derives ~8 sub-states from the identity's optionals.

**W-3 Companion mirror transport** — `WatchWorkoutManager.swift:515-519` envelope buffer
(explicit), `isMirroring`, start in flight, start/send attempt IDs, retry/start-timeout/
live-send-timeout/shutdown-watchdog tasks, shutdown retry count, phone schema version.
NotMirroring / StartInFlight / Mirroring / SendInFlight / RetryScheduled / ShutdownDelivery
(10 s) / Disconnected. Smell: HealthKit sends cannot be cancelled, so three attempt UUIDs
and three timeout tasks fence late callbacks; both bools can be false while a start
callback is still pending.

**W-4 Direct-BLE link: phone preparation / handback (Watch half of A-8)** —
`Managers/WatchDeviceLink.swift:126-199` prepared phone device/preparation IDs, accepted,
submission outstanding, release pending, attempt, retry/timeout tasks, restoration gate,
initial demand restoration completed/deferred, pending reconciliation (persisted),
`phoneNavigationHandback` deferring/suspended (persisted), deferred retry due, stopping
preparation, disconnecting for busy lease. NoPreparation / PrepareSubmitted (20 s) /
PrepareRejectedBusy / PrepareAccepted / ReleasePending (persisted, must drain) /
RestoredUndecided × Handback None / Deferring (30 s backoff) / Suspended. Smell: six bools
+ two persisted records + one enum for one handoff; `phonePreparationAccepted=false`
written in six places; `.busy` is a value of the published link state but decided by the
preparation machine.

**W-5 Published link state vs transport reducer** — `WatchDeviceLink.swift:31`
`@Published state` (12 cases) written at 27 sites alongside the explicit
`RideBLETransportStateMachineV1`. The reducer is authoritative for readiness; `state` is a
mirror that also carries non-transport values (`.notEnrolled`, `.bluetoothUnavailable`,
`.busy`, `.failed`). `reduceTransport` (`:2165`) demotes `.ready` but never promotes;
`.failed` can show while the reducer is recovering; `disconnectingForBusyLease` and
`stoppingPhonePreparation` are side flags the reducer does not know.

**W-6 Outbound write pump + application ACK (Watch half of A-10)** — `WatchDeviceLink.swift:98-120`
queue, active group/index, pending ack group, buffered early ack, ack retry count, ack
watchdog (5 s) + start uptime, outbound generation, write-with-response in flight, pending
ATT write, next write ID. Idle / GroupActive / ATTWaiting / AckWaiting (retry 0/1) /
BufferedAckEarly. The reducer's writer state and the pump's fields are two copies; the ACK
watchdog restores `activeWriteGroup` for the retry from a task.

**W-7 Graceful stop / lease release** — `WatchDeviceLink.swift:1039-1163`. Shutdown
sub-phases are explicit; entry conditions mix `canReleaseLease`, lease-release ack task,
connection generation and `linkEnded` from four callbacks; the restoration one-shot has
three exits (`:532`).

**W-8 Ride transition confirmation (origin tracking)** — `WatchWorkoutManager.swift:531-551`
write revision, pending automatic start/transition annotations, three mutually exclusive
"origin pending" bools, launch contexts, manual override pending + generation + 10 s task,
pending system event, last processed stamps, pending remote acknowledgement. OriginUnknown /
LaunchAutomaticPending / LocalManualPending / SuppliedConfigUnknown / MarkerWritten /
Confirmed × ManualOverride. Revision-fenced writes stand in for a per-transition state.

**W-9 Segment mark operation** — `:407-408`, `:490-494` marking, error, timeout task, final
closure task, attempted final closure, attempt IDs, remote control context, allows saving
unconfirmed, persisted `RemoteSegmentIntent`. Idle / InFlight / TimedOutUnconfirmed /
FinalClosureAttempted / RecoveredIntentPending. Smell: `waitForSegmentOperationBeforeFinalization`
(`:4051`) is a 25 ms polling loop.

**W-10 Recovery loop and launch admission** — `:390`, `:409-411`, `:486-488`, `:510`,
`:558` `isRecovering`, `isRecoveryLoopRunning`, signal queue (generation + parked), pending
configuration, pending launch request + expiry, authorization/complication tasks, setup
state. `canAdmitConfirmedWorkoutLaunch` (`:1784`) is an 8-term conjunction; `isRecovering`
ends as `terminalCleanupSessionID != nil` (`:1729`). Two bools for one loop; drain/reconcile
called from four `defer` sites.

**W-11 Watch navigation request generations** — `Managers/WatchNavigationManager.swift:124-139`
pending record/mode/far-start/favorite, active record/destination, started, journal stamps,
lifecycle/request/location generations, origin, task, reroute cooldown. The published state
is explicit; the online-request lifecycle is a generation triple compared by
`isRequestCurrent` (`:739`); `onlineStatus` (10 cases) is a second enum set by hand.

**W-12 Direct ride automation decision mailbox (Watch half of RA-1)** —
`Managers/WatchRideAutomationCoordinator.swift:19-23` active device, last generation,
highest sequence by generation, device monotonic, pending decision (device, frame, expected
state). Idle / DecisionAcceptedAwaitingSnapshot / Confirmed. A pending decision whose
expected state never arrives is cleared only by a device-ID change (no timeout; firmware
times out first).

**W-13 Route recorder capture** — `Managers/WatchRouteRecorder.swift:33-45` builder,
workout start, active, may-contain-existing, timestamp gate, explicit capture lifecycle,
accumulator, queue, flush task, generation, save failed (sticky). Clean-ish; `isWorkoutActive`
duplicates the manager's lifecycle.

**W-14 WatchConnectivity background delivery + release outbox** —
`Managers/WatchConnectivityCoordinator.swift:49-66` activated, activation failed (sticky per
wake), background work count, UserDefaults pending/in-flight release arrays and diagnostics
arrays, retry task; app delegate background tasks. Pending → InFlight → Finished | Retry;
background Held → Completable. Smell: pending→in-flight promotion is skipped while anything
is in flight (`:296`), so a stuck transfer starves later releases.

**W-15 Demand state** — see B-13; "release pending" is completed only by W-6 when the queue
drains, so a link that never becomes ready keeps `requiresConnection` true until `stop()`.

**W-16 Route library active / pending deletion** — `Managers/WatchRouteLibrary.swift:16-17`
active identity, pending deletion (persisted). The transition lives in the navigation
manager's recovery and stop paths (`:181`, `:343`).

**W-17 Small ones** — recovery signal queue (`WatchWorkoutManager.swift:231`), recovered-save
reconciliation gate (`:279`), setup progress (`:173`), launch request expiry, manual override
window, route generation gate, `reconnectAttempt` (1..6, 2ⁿ capped 30 s, reset only on
success), latest/dispatched GPS and motion pairs (`WatchDeviceLink.swift:139-151`), motion
cleared sentinel (`:146`), location consumer map, network availability.

---

## 8. Cross-device (distributed) state machines

Ranked by risk. Each spans two or three parties; the firmware half is cited by ID.

### X-1 Map upload → prepare/commit → activate → renderer ACK → receipt → library (highest risk)
Parties: firmware MT-1, MT-2, MT-3, MT-4, MT-5, MT-6, MT-8, MT-9, MT-10, TR-14; phone C-1,
C-2, C-3, C-7, C-8, D-1.
Joint phases: Uploading(stream seq) → LegacyReady+grant | Prepared → Accepted (commit) →
Activating(activation seq, renderer pending) ↔ Recovering → Installed (renderer ACK +
receipt) | Failed | RolledBack; library Use/Remove reuses the renderer handoff without an
upload. Moved by PUT install-stream, 200 ready/prepared, POST commit/cancel, GET
operations/{id}, MSTS/DSTS activation polling, renderer take/acknowledge, MTRN library
commands.
Persistence: firmware SD markers + transaction journal + active-map.json + selection
anchors + A/B operation ledger; phone per-map metadata + operation journal + lease record.
Failure modes: response lost after commit → phone must query the exact operation ID, but
legacy uploads only have the boot-local sequence; firmware reboot mid-activation → boot
resume on the storage owner; phone kill → `adoptRecoveredJob` and re-poll; BLE loss →
grace window (X-6), else the session is torn down while accepted work continues.
Divergences: (a) the phone binds "same attempt" to a boot-local sequence whose meaning
changes by status word, and the firmware mixes two counters in one field (MT-9), so after a
power cut the phone can only wait for a terminal it may never see on legacy firmware;
(b) a stale or mismatched renderer ACK is silently ignored (MT-3) and a permanently failing
receipt write never terminates (MT-5), so the phone polls until its own deadline and reports
unknown; (c) the legacy grant has no timeout (MT-8), so a stuck device-side terminal answers
409 `activation_busy` to every new upload with no phone command to clear it short of reboot;
(d) four firmware "busy" predicates (MT-7) vs the phone's pending/paused predicates derive
from different fields; (e) the selection intent (MT-12) settles only on the next library
task, so phone inventory can show manual for the length of a retry loop.

### X-2 Watch-direct ride handoff: preparation → yield → lease → handback → release
Parties: Watch W-4, W-5, W-7, W-15; phone A-8, E-9; firmware BLE-6 lease and BLE-1 session.
Joint phases (Watch × Phone × Lease): NoDemand/NotYielded/Owner → PreparationSubmitted/
Yielded(prepID, auto-reconnect off)/Free → WatchConnected/Yielded/WatchHolds → [phone
navigation starts] HandbackDeferring/ReconciliationQueued → WatchReleased/PhoneReconnected/
Owner → WatchRetryBackoff (rejected `phone_navigation_active`) → ReleaseWhenIdle/Resumed/
Owner. Moved by WC prepare/release (fresh request ID, stable preparation ID), phone
rejection codes, WC reconciliation, BLE LEASE_* commands, firmware busy.
Persistence: Watch UserDefaults (intent, reconciliation, handback); phone UserDefaults
(yield + 24 h expiry); firmware RAM only.
Failure modes: Watch relaunch mid-ride → restoration gate waits for navigation and HealthKit
demand, else releases; phone kill → yield persists and reconnect stays suppressed until
release or 24 h; firmware reboot → lease gone, Watch reclaims; WC unreachable → Watch
suspends the hold.
Divergences: three persisted half-states with no shared epoch beyond the preparation ID;
the phone's 24 h expiry and the Watch's suspended hold can leave phone auto-reconnect off
while the Watch is not scanning (both waiting) until the next backoff tick;
`phone_navigation_active` also means "my recording blocks you", so the Watch cannot tell a
handback from a permanent refusal; the firmware's owner-reclaim-on-first-write means a phone
reconnecting during a Watch heartbeat gap silently steals the lease with no Watch signal
besides `leaseLost`.

### X-3 Firmware update: prepare → maintenance reboot → upload → finalize → reboot → verify → receipt ack → exit
Parties: firmware TR-4, TR-5, TR-6; phone D-4, D-5, A-18.
Joint phases: Downloading/ImageVerified (phone) → MaintenanceRequested(correlation,
`reboot_pending`) → [reboot] MaintenanceReady → Uploading → Finalizing → Rebooting →
[reboot into new slot, pending verify] → Unresolved until the next authenticated status
shows the new build (+ receipt ack when required) → Installed | RolledBack | Failed |
Cancelled. Moved by DTRN prepare/enter, HTTP begin/image/finalize/cancel,
`markRunningAppValid` (firmware `main.cpp:2229`) + receipt reconcile, maintenance exit
(button, timers, request).
Persistence: phone UserDefaults pending record; firmware RTC request (consumed once), NVS
receipt, OTA slot state.
Failure modes: phone kill after prepare → device waits ≤10 min in maintenance then reboots
back, phone relaunch treats the stage as unresolved and re-reads status; power loss during
finalize → slot invalid, old image boots; power loss after reboot before validation →
bootloader rollback, phone sees the old build and marks rolled back.
Divergences: phone `unresolved` is set at six sites from different causes with two
differing stage lists (D-4); the correlation is compared only once at enter, and nothing
binds the post-update boot to the pending record except the build number; the firmware's
reset-before-cancel (TR-4) accepts a phone cancel during commit while the device still
reboots, so the phone marks cancelled and the device installs; a receipt persistence
failure on the valid path is ignored (TR-5), so `requiresOperationReceipt` can wait on a
receipt that never appears.

### X-4 Ride automation: decision → ack → prompt → response → confirmation / cancellation
Parties: firmware RA-1, RA-2, RA-10, RA-13; phone E-6; Watch W-12 plus the mirror (E-1, W-3).
Joint phases: Quiet → DeviceDecided(gen, seq) [firmware retries 1/2/4/8 s ×4] → PhoneAcked
[firmware 5 s resend; phone 30 s pending] → PromptOnBoth → PromptResponse → WatchLaunch/
Snapshot → Confirmed | Cancelled(stale) | Expired (two independent 30 s clocks); config
generation ack; resync on auth exchanging ride generation, outstanding sequence, watermark,
session UUID.
Persistence: phone pending decision + watermarks; firmware NVS config + suppression; Watch
recovery record + automatic-start marker.
Failure modes: BLE drop before ack → firmware retries on the new lease, phone dedups by
identity; phone kill → pending reloaded but inert until the device retry or resync proves
it outstanding; firmware reboot → ride generation changes, phone retires the old pending only
when a *different* device connects, same-device new boot relies on the resync watermark;
Watch unavailable → result 3.
Divergences: two 30 s deadlines started at different moments; firmware clears on
exhaustion and applies suppression while the phone may still show the prompt; confirmation
needs an authoritative Watch snapshot with automatic origin, so a Watch started manually in
the window yields a contradictory state on firmware and an unresolved pending on the phone
until timeout; the config ack is sent after NVS persistence outside the mutex, so a
disconnect in between leaves the phone retrying the same generation (idempotent, but the
retry counter grows).

### X-5 Ownership: register → provisional key → promote; owner session; Watch controller enrol/revoke
Parties: firmware BLE-1, BLE-4, BLE-5, BLE-6, BLE-7; phone A-4, A-5, A-12, A-13, B-6, E-9;
Watch credential store.
Joint phases (registration): Unclaimed/Idle → PAIR sent/Pairing(code, 120 s) → PAIR_READY
+ phone confirm → CONFIRM → PAIRED (phone keeps provisional) → OWNER/SERVER2/PROOF/OK2 on
the same connection within 12 s → promoted. Deregistration: UNPAIR → tombstone →
UNPAIRED2 receipt → phone verifies → deletes credential; receipt re-exposed in a later
DEVICE frame. Watch: WCTRL_STAGE → STAGED → Watch pending key → WCTRL_COMMIT → COMMITTED →
Watch promote; repair via WCTRL_STATUS; revoke → REVOKED → outbox → Watch delete → receipt.
Persistence: firmware NVS owner record + tombstone + two controller slots; phone Keychain
provisional/final + registry + outbox; Watch device-only Keychain.
Failure modes: PAIRED lost → phone keeps provisional, re-auth promotes (by design);
disconnect between PAIRED and OK2 → firmware claimed, phone provisional, recovered on the
next connect only if the provisional entry survives; phone kill mid-UNPAIR → firmware
tombstone cleanup at boot, phone reconciles from the DEVICE receipt; Watch promotion
interrupted → status repair; revoke receipt lost → outbox retries.
Divergences: firmware pairing expires at 120 s with no matching phone deadline, so the
user can sit in comparison-ready after expiry and CONFIRM fails with no distinct phone
state; `pendingDeregistrationDeviceID` cleared at seven sites; "ownership invalidated while
linked" (BLE-1) reaches the phone only as a disconnect; promotion-in-flight is reset on
disconnect but not on the WC failure path, so a silent Watch blocks re-promotion until
reconnect.

### X-6 Transfer session + BLE link-loss grace + lease rebind
Parties: firmware TR-1, TR-2, TR-3, BLE-2, BLE-3; phone D-1, D-2, D-3, A-1.
Joint phases: Idle → EnterRequested → NetworkStarting("starting"/"connecting") → LAN |
Hotspot + listener → PhoneJoined (NEHotspot config, probe) → Serving(epoch E) → [BLE loss]
GraceOpen (firmware deadline) / Wait (phone status poll on the new link) → Rebind (same
token, generation, mode) → Serving(E') | Stale → exit; a firmware mode replacement bumps
the generation and the phone learns it by 401.
Persistence: none on firmware beyond boot; phone lease record with SSID.
Failure modes: loss inside the window with owner re-auth → both continue; outside → firmware
tears down, phone stale; phone kill → firmware inactivity timeout exits; firmware
`networkStopFailed_` sticky → quiescence never reached, phone sees the mode stuck until
reboot.
Divergences: the phone mirrors the firmware's 15 s / 45 s arithmetic, so a firmware change
silently desynchronizes; `remoteCleared` is inferred from "empty mode on new link" after
PR 749's status gating, not acknowledged; the authorization generation is compared in two
places with different null handling; the firmware bumps `transferGeneration_` in eight
places while the phone reads it only from DSTS.

### X-7 Diagnostics capture: bind → policy lease → markers → seal → chunk download → cutoff → exit
Parties: firmware RA-3, RA-4, RA-5, RA-8, RA-9; phone A-17, D-6, D-7, D-11.
Joint phases: Unbound → Bound(capture UUID, standard | detailed; idempotent on reconnect) →
PolicyInstalled(gen, budget) → Marking (sequence strictly increasing) → ride ends (firmware
5 min telemetry-stale rule or explicit end) → EntryRequested → Sealed(cutoff) → Serving
(index, chunks, lease refresh) → phone acquisition collecting → partial | complete → Exit →
retention pruning.
Persistence: firmware SD chunks + RTC fault capsule + RAM binding; phone acquisition store
(reserved inventory, verified chunks, cutoff) + evidence directories.
Failure modes: BLE drop mid-download → grace/rebind (X-6), else the lease expires and
pruning may resume; phone kill → acquisition partial, resume skips same-hash chunks;
firmware reboot → binding lost until the phone re-binds, boot sequence changes, recorder
fenced; seal timeout → "seal in flight" left for the next caller (RA-3).
Divergences: the marker sequence is phone-monotonic per process but firmware-monotonic per
binding, so a phone relaunch restarts at 1 and is rejected until a rebind bumps the
generation; the policy stays installed on firmware after the capture clears (RA-4) and the
phone's generation only increments, so a firmware reboot (generation 0) accepts anything;
the retention lease has two refreshers (RA-8) and a one-chunk-at-a-time download can exceed
10 min with no non-chunk request.

### X-8 Workout session mirror (Watch primary ↔ phone mirror/recorder ↔ device telemetry)
Parties: Watch W-1, W-2, W-3, W-8, W-9; phone E-1, E-2, E-3, E-4, E-5, E-8; firmware BLE-12,
BLE-15, `GroupTracker`, workout `SessionState` reducer.
Joint phases: NoSession → WatchLaunchRequested → MirrorStarting (10 s) → Live (core +
extended heartbeat, firmware pairs frames) → Paused/Resumed (controls with sequence gate) →
Finishing (disposition persisted first) → TerminalGroup to device (RCM1, ack required) →
SavedTombstone | Discarded → cleanup receipts.
Persistence: Watch recovery store (finish request, tombstone, remote terminal ack); phone
recording record + sequence checkpoint; firmware RAM only.
Failure modes: phone kill → new sender ID, may advance the generation once; Watch kill →
recovery loop and finish-request replay with late HealthKit session-ID match; firmware
reboot → group tracker and retained results gone, so a duplicate terminal after reboot is
applied again (idempotent terminal state); BLE drop mid-group → interrupted group stays
pending on firmware, controller resyncs on the new lease.
Divergences: Watch and phone each own a "terminal delivered to device" belief with no
cross-check; firmware retains only 8 results, so a controller with more outstanding
critical IDs across a flapping link gets a fresh apply instead of a replay; the phone's
navigation-clear intent (A-10) survives reconnect but is superseded silently, so the device
may keep guidance the phone believes cleared if the new route write then fails.

### X-9 Navigation route / GPS / maneuver delivery with payload generations
Parties: phone A-9, A-10, A-14, B-12; Watch B-14, W-6; firmware BLE-15 and the map-setting
redraw policy.
Joint phases per connection: Unsent → ProfilesNegotiated (six one-shot flags) → route /
maneuver / GPS replaceable latest-wins → ClearIntent (RCM1) → ClearAcked | Superseded;
firmware Empty → Staged(gen) → Applied on the UI task.
Divergences: six per-connection "already sent" bools instead of a negotiation phase;
firmware rejects stale by command/state generation but replaceable writes carry no
generation, so an old connection's late ATT write on a restored link is fenced only by the
phone's connection generation.

### X-10 Screen configuration snapshot / upload / ack
Parties: firmware BLE-10, BLE-11; phone B-4.
Joint phases: Disconnected → SnapshotRequested(req ID) → Streaming (≤160 chunks) →
Ready(revision, CRC) → Draft → Saving(req ID, base revision) → Acked(ok | conflict) → Ready
| Conflict → re-snapshot.
Persistence: firmware NVS slot revision; phone draft in UserDefaults.
Failure modes: ack lost → 5 s timeout → phone failed while firmware already persisted
revision+1 → the next save conflicts; disconnect mid-upload → firmware drops the partial.
Divergences: a timed-out save whose ack arrives late is ignored by ID although the firmware
state moved; a retry after a lost ack carries a new request ID with the same CRC, so it is a
second revision bump (no idempotency key).

### X-11 Request/response correlations (lower risk, same pattern)
- Destination picker: firmware BLE-9 ↔ phone B-3 + status sequence. Firmware times out on
  its own; a late phone answer is dropped; the phone has no retry.
- World radio: firmware RA-16 ↔ phone G-5. Firmware never times out a request whose phone
  task was cancelled; the UI shows the previous station until the next command.
- Route elevation: firmware RA-7 ↔ phone B-8, G-19. A phone that stops mid-transfer leaves
  firmware staging until the disconnect reset.
- Social riders portraits: firmware RA-6 ↔ phone G-18. A second rider's begin abandons the
  first; no ack back, so the phone learns a drop only by the absence of `imageReady`.
- Power-button honk: phone A-16 ↔ firmware SYS-7 (forced off). The phone retry machine
  targets a removed feature.
- Map profile / settings one-shots: phone A-14 ↔ firmware redraw policy; setting write
  generations.

### Cross-device divergences, summarized
1. **Boot-local counters crossing the air.** Activation sequence, transfer generation, ride
   generation, lease generation and diagnostics boot sequence all reset on firmware reboot;
   the phone persists its last-seen value and must infer a reboot from status-word context.
   Only map operations (admission epoch + revision) and ride automation (ride generation in
   every frame) carry an explicit epoch.
2. **Timeout mirrors.** The phone copies firmware constants (15/45 s rebind, 30 s
   automation, 5 s ack, 10/8 s ATT) instead of reading them; each is a latent desync.
3. **Terminal states acknowledged one way.** Renderer ACK → receipt (map), app-valid →
   receipt (OTA) and RAK1 (ride) are device terminals the phone learns by polling; the
   firmware never learns the phone's terminal (saved tombstone, acquisition complete,
   pending record cleared) except through the absence of a retry on the next connection.
4. **Persisted intents without a peer epoch.** Phone yield (24 h), Watch handback,
   revocation outbox, navigation-clear intent, pending firmware record and pending
   automation decision all survive relaunch and are retired by heuristics (device-ID
   mismatch, status word, timer), not by a peer-signed completion.
5. **Status strings as the contract.** `activation.status`, `networkTransport`,
   `maintenance.stage`, `libraryAction` and selection health are switched on by the phone's
   reconcilers, so every firmware string-state smell is also a cross-device one.

---

## App-side cross-cutting patterns

The iPhone and Watch code repeats the firmware's idioms one for one:

1. **Attempt UUIDs and generations as cancellation tokens** — A-9, A-10, B-2, B-19, C-13,
   D-6, E-1, E-2, E-10, G-3, G-4, W-3, W-5, W-6, W-11. Staleness is discoverable only by
   comparison at the consumer.
2. **Copy-pasted resets** — A-1 session reset (3×), A-2 `autoReconnect` (37 writes), B-1
   dismissal flag (11), B-2 cancel-and-bump (4×), E-1 `resetRemoteTransport` (17 fields from
   4 callers), E-4 automatic choice (7), G-2 begin/stop (~25-30 fields each), W-1 release
   block (2×, ~30 resets), W-4 accepted flag (6), W-5 link state (27 writes).
3. **Strings as phases** — C-1 outcome, C-2 observation/cleanup, D-4 status, D-8 broker
   status, D-10 replay status, D-12 transport, D-14 and G-10 status messages, B-2
   calculation status.
4. **Nullable as phase** — E-1 (six optionals), E-6 (optional within optional), E-8 (three
   frames), G-22 resolver, W-4 (two IDs), W-11 (two record pairs), G-24.
5. **Explicit enum shadowed, derived or unguarded** — A-4 auth flow, B-4 sync state (14
   writes), D-4 stage (any-to-any), E-3 recorder state (14 writes, shared reducer unused),
   E-10 Strava activity, G-1 Watch sync state (derived and also assigned), W-1 cleanup
   state (derived from ~10 bools), W-5 link state (mirror), `WorkoutMirrorStateReducer`
   connection state (23 writes).
6. **Persisted record shadowed by RAM** — C-1 (three copies), C-2 pointer vs journal, C-4
   (three sources), D-1 cleanup record, D-4 pending update, D-6 manifest vs retry flag, E-5
   record vs E-3 flags, G-1 six sets, W-2 flag files, W-4 intent + handback, W-14 outbox.
7. **Lazy expiry inside getters and recomputed phases** — B-5, B-7, C-8, D-7 policy, E-13,
   G-5, W-1, W-10.

## Where an explicit machine would pay off most (app and cross-device)

1. **X-1 / C-1 / C-2 / D-1** device map install: one phone-side `DeviceInstallState` fed
   by the operation journal only, with the outcome string and per-map mirror derived from
   it; pair it with the firmware root classifier proposed in the firmware document.
2. **X-3 / D-4** firmware update: guard `updatePending(stage:)` with the same transition
   table on both reconcile and error paths, drop the status string, and bind the post-update
   boot to the pending record by correlation, not build number.
3. **X-2 / A-8 / W-4** Watch-direct handoff: a single preparation record with one epoch
   shared by Watch, phone and lease, replacing six Watch bools, two persisted Watch records
   and the phone's 24 h timer.
4. **A-1 / A-2 / A-6** BLE manager: one `clearSession()`, an explicit reconnect-intent
   enum in place of the `autoReconnect` mode flag, and a scan-purpose reconcile that takes a
   typed reason.
5. **E-3** phone recorder: drive `state` through the existing `WorkoutLifecycleReducer`
   like the Watch does.
6. **X-4 / E-6 / RA-1** ride automation: one decision enum with a single `settle(reason)`
   on both sides and one shared deadline origin.
7. **W-1 / W-5** Watch: make `terminalCleanupState` the stored state instead of a
   derivation, and stop writing the published link state outside `reduceTransport`.
8. **X-6 / D-2** rebind: have the firmware advertise its grace deadline in DSTS and let the
   rebind policy accept retained OS claims so map uploads can rebind.

Dead or vestigial on the app side: the power-button honk retry (A-16, feature removed on
firmware), the second copy of the route search panel (G-9), and the duplicated
reconnect-and-confirm loop in the maintenance handshake (D-5).

---

## Explicit machines passed over (app side)

Clean, single-owner, guarded: `RideBLETransportStateMachineV1` (shared, generation-fenced
reducer; the one real reducer on phone and Watch); `WorkoutLifecycleReducer`;
`WorkoutFinalizationPhase` ladder (save path); `BLEOwnershipLifecycle`;
`WorkoutLatestEnvelopeBuffer`; `WorkoutControlEnvelopeSequencer` /
`WorkoutRemoteControlSequenceGate`; `WorkoutDeviceForwardingStateV1`;
`CyclingSensorObservationReducer`; `NavigationRuntimeV1`; `WatchRouteOperationJournalV2`
fence; `DeviceOperationCoordinator.Failure`; `DeviceTransferLinkRebindPolicy.Decision`;
`DeviceNetworkApplyGate.Resolution`; `MapActivationReconciler` results;
`BackgroundMapUploadArbitration`; `OfflineMapOnboardingPolicy` presentation;
`WatchDirectRidePreparationRestorationGateV1`; `WatchRideDemandStateV1`;
`WorkoutRouteCaptureLifecycle`; `WatchRerouteCooldownV1`; `LiveRideService.Notice`;
`SocialNotificationBinding.Status`; `SocialAccountDeletion.Resolution`;
`NearbyBicinoSetupStage`.

Explicit but shadowed, derived, mirrored or unguarded (also counted above): `AuthFlowState`
(A-4), `PendingWatchControllerOperation` (A-12), `BLEScanPurpose` (derived, A-6/B-7),
`DeviceScreenConfigurationSyncState` (B-4), `FirmwareUpdateTransactionStage` (D-4),
`DiagnosticsAcquisitionManifest.Phase` (D-6), `PhoneWorkoutRecorder.state` (E-3),
`WorkoutRecordingRecord.Phase` (E-5), `WorkoutMirrorStateReducer.connectionState`,
`StravaIntegrationActivityV1` (E-10), `PhoneRouteWatchSyncStateV1` (G-1),
`WorldRadioPlaybackState` (G-5), `OnlinePOISearchSession.State` (G-21),
`MultiStopRoutePlanner.State` (G-22), `DurableMapDownloadCoordinator.Ownership.Phase` (C-5),
`WatchDeviceLinkState` (W-5), `WatchNavigationState` + `WatchOnlineRoutingStatusV1` (W-11),
`WatchWorkoutCleanupState` (W-1), `WatchWorkoutRecoveryStore.LoadState` (W-2),
`BicinoUserSession.State` (G-24).

Value, result and wire enums with no transitions: `BLEDiscoveryOrigin`, `ATTWriteOwner`,
`RideApplicationDeliveryOutcome`, `DeviceDestinationStatusCode`, `DeviceTransferSession.Mode`,
`DeviceMapOperationControlAction` (derived per read), `ReconciledKeyState`,
`RendererBenchmark*Outcome`, `WorkoutSessionStateV1`, `WorkoutControlV1`,
`RideAutomationKind/Transition/Origin/Result`, `WorldRadioCommand`, `MapTrackingBehavior`,
`ContentSheetDestination`, `SettingsSheetDestination`, `WatchRouteSyncOperationV1`,
`GPXRouteImportSourceV1`.
