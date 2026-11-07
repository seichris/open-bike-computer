# Implicit state machines in the ESP32 firmware

Inventory taken on 2026-11-07 at `fd0689c8` (main after #769). Read-only survey of
`esp32/src` and every non-vendored library under `esp32/lib` (about 100k lines;
LVGL, esp_codec_dev, tinyxml2, fonts and image arrays excluded).

**Definition used.** An *implicit* state machine is lifecycle or phase state that
is not held in one enum with one guarded transition function. The usual forms
here are:

- a tuple of bools whose joint values are the phases;
- a `millis()` timestamp that means "in phase X until deadline" (often with the
  phase expiring lazily inside a getter);
- a `valid` flag next to a payload (a mailbox), or a nullable handle/pointer;
- a pair of generation/sequence counters whose equality or ordering is the phase;
- a free-form status **string** compared in many places;
- an explicit enum that exists but is shadowed by bools, recomputed every tick,
  or written unguarded from many sites.

Explicit machines that were passed over are listed at the end so they can be
told apart. Line numbers are approximate anchors into the files at the SHA above.

The iPhone app, Watch app and cross-device protocols are inventoried in
[app-and-cross-device-implicit-state-machines.md](app-and-cross-device-implicit-state-machines.md).

Counts: **96 implicit machines** across 7 areas; **~45 explicit enums**, of
which about 12 are shadowed or unguarded enough to belong in both lists.

---

## 1. BLE and ownership (`lib/ble_navigation`)

**BLE-1 Link session lifecycle** — `ble_navigation.cpp:207` `activeConnHandle`,
`:147` `bleSessionAuthenticated`, `:647` `unauthenticatedWindowStartMs`, `:208`
`unauthTimeoutDisconnectRequested`, `:725` `ownershipDisconnectPending`,
`:216-218` connection start / local disconnect cause / pending ownership cause,
plus ~14 `bleSessionSupports*` capability atomics (`:148-161`).
States: NoLink → Accepted/Unauthenticated (window running) → Authenticated(+caps)
→ DisconnectRequested(cause) → NoLink; "ownership invalidated while linked" is a
sub-state. Transitions: `acceptConnection` (`:6602`), `completeBleSessionAuthentication`
(`:3047`, `:2869`), `process()` deadline (`:8064`, duplicated verbatim for the
maintenance boot at `:8183`), `disconnectActive` (`:6774`), Unpaired/recovery
resets (`:2898`, `:8425`). Smell: the ~20-store "clear session" sequence is
copy-pasted in five places; capability flags are a mix of plain bools and atomics.

**BLE-2 Transfer link-loss grace driver** — the grace state lives in
`device_transfer` (TR-2) but is driven from `disconnectActive` (`:6790-6815`),
`acceptConnection` (`:6716`), `process()` expiry (`:8169`) and
`rebindTransferAfterLinkGrace` (`:4414`). Whether a disconnect opens a window
depends on three bools evaluated inline; the two terminal states (Expired,
Rebound) are produced in different tasks.

**BLE-3 Transfer connection-profile sync** — `:637-642` `transferProfileHandle`,
`transferProfileLinkStartMs`, `transferProfileApplied`; `:584` `transferWindowOpen`.
NoLink / navigation profile / transfer profile keyed by (handle, linkStartMs) to
defeat NimBLE handle reuse. One tick-polled diff in `syncTransferConnectionProfile`
(`:8277`). Clean but polled.

**BLE-4 Device ownership pairing** — `device_ownership.hpp:183-188` `pairingActive_`,
`pairingConfirmedOnDevice_`, `pairingAttemptedOnConnection_`, `pairingStartedMs_`,
`pairingGeneration_`, `armedPairingGeneration_`. Idle → Pairing(code, timer) →
Armed(gen) → ConfirmedOnDevice → Claimed, or Expired/Failed. Transitions: `PAIR`
(`device_ownership.cpp:535`), BOOT-button arm/confirm (`:1068-1084`), `CONFIRM`
(`:585`), `process()` timeout (`:495`), `resetConnection` (`:486`), `clearPairing`
(`:1787`) from every failure path. Smell: timeout checked in two places; the
"claimed but owner record invalid" fail-closed state is only a flag pair (`:630`).

**BLE-5 Ownership presentation mirror + restart** — `ble_navigation.cpp:685`
`ownershipPairingActiveSnapshot`, `:724` `ownershipAdvertisingDirty`, `:726-727`
`ownershipRestartRequested/Ms`, `:729-736` `ownershipUi*` + `ownershipUiUpdatePending`;
`ownership_button_policy.hpp` `ComparisonRenderGate` / `FreshPowerButtonGate`.
UiStale → UiQueued → UiApplied; AdvertisingClean/Dirty (applied only on next
disconnect, `:6896`); RestartPending 500 ms after Unpaired (`:2911`, `:8440`, fired
`:8092`). Smell: the pairing snapshot is written from the host task (`:2860`) and
the loop (`:8035`, `:8158`) without the ownership mutex on the former.

**BLE-6 Authenticated session × ride-controller lease** — `device_ownership.hpp:155-172`
`claimed_`, `ownerRecordValid_`, `legacyAuthenticationAllowed_`, `sessionAuthenticated_`,
`sessionRole_`, `sessionId_`, `watchControllerActive_`, `stagedWatchControllerValid_`,
`pendingAuthenticationRole_` + nonce strings; `ride_controller_lease.hpp` (`active_`,
`lastActivityMs_`, `generation_`). Unclaimed → Claimed(valid|invalid) × Session(None |
owner-challenge | watch-challenge | Authenticated(Owner|WatchRide)) × Watch(None|Staged|
Committed). Smell: "challenge pending" is a non-empty nonce string; the lease expires
lazily inside `expireIfNeeded()` on every query.

**BLE-7 Legacy pre-ownership handshake** — `ble_navigation.cpp:186` `pendingAuthNonce[33]`:
empty → challenge issued (`:3016`) → cleared on proof (`:3048`) or connect/disconnect.
A two-state machine held in a string; duplicated by the v2 path inside `DeviceOwnership`.

**BLE-8 Diagnostics transfer async start** — `:743-749` `diagnosticsSessionStartInProgress`,
`StartGeneration`, `ActiveGeneration`, `PreparationComplete`, task handle. Idle →
Starting(gen, worker) → WorkerParked(complete, task suspended) → Applied | Stale.
`startDiagnosticsSessionAsync` (`:4372`), worker self-suspend (`:4273`),
`processCompletedDiagnosticsSessionStart` (`:4276`), `cancelDiagnosticsSessionStart`
bumps the generation (`:4226`). Four atomics + a handle for one lifecycle.

**BLE-9 Destination-picker request** — `:760-762` `destinationRequestPending`,
`StartedMs`, `StatusUpdatedMs` + explicit `DestinationPickerStatusCode`. Idle →
Pending(timer) → Calculating → terminal(display timer) → Idle. `beginDestinationRequest`
(`:1118`), `applyDestinationResponseIfPending` (`:1130`), timeout (`:1165`), expiry
(`:1177`), disconnect finish (`:6904`). Pending-ness and status code must agree by hand.

**BLE-10 Screen-configuration transport** — `:764-806` `PendingScreenConfigurationControl`
(`snapshotRequested`, `uploadReady`, `acknowledgementReady`), outgoing snapshot
`active`/`nextChunk`, `screenConfigurationSnapshotActive`, `AckPending`, `ResetRequested`.
Idle → UploadStaged | SnapshotRequested → AckQueued → AckSent; snapshot Streaming.
Host-task callbacks stage, `processPendingScreenConfiguration` (`:2516`) consumes one per
pass, `pumpScreenConfigurationNotifications` (`:2455`) drains. The "one ACK slot" is an
if/else ladder over readiness bools.

**BLE-11 Legacy settings import debounce** — `screen_configuration.cpp:58-61`
`legacyChangedAtMs`, `legacyChangePending`, `legacyMaskPending`, `legacyDefaultPending`.
Idle → Pending(250 ms) → Imported, re-armed forever on readback failure (`:792`).

**BLE-12 Workout telemetry core/extended pairing** — `workout_telemetry_state.hpp:753-756`
`transactionalCorePending_`, `transactionalGeneration_`, `legacyCoreAwaitingExtended_`,
`legacyCoreToken_`; `:869-871` resynchronizer `stagedCoreAccepted_`,
`stagedRequiresCurrentCollisionReplacement_`, `resynchronizationPending_`; `State`
bools `:50-54`. NoCore → CoreStaged → PairCommitted; on re-auth Resync → Promoted|Dropped.
Pure and host-tested, but ~8 bools across two classes.

**BLE-13 Deferred notification dispatch** — `:707-717` ring `head/tail/count` +
`deferredNotificationEventReady/Pending/Scheduled`, `shutdownWritesClosed`. NotReady →
Idle → Pending → Scheduled → Draining → (Pending|Idle); Closed at shutdown. Producer
(`:2100`), owner task (`:2150`), host-task handler (`:2296`). Three atomics plus a count
stand in for one enum; the decision table in `deferred_notification_dispatch_policy.hpp`
is the explicit half.

**BLE-14 Status chunk pumps (map / device / renderer)** — `:189-198`
`pendingMapTransferStatusChunks.active_`, `...Continuation`, `...Refresh`,
`pendingMapAvailabilityStatus`; `map_transfer_status_chunk_session.hpp:122-123, 242-246`.
Idle → Streaming(nextIndex)[+RefreshRequested] → Done (`:3797-3873`, `:8098-8108`).
Three parallel copies with slightly different flag sets.

**BLE-15 Pending map-input mailbox** — `:1361-1407` `PendingMapInput.pending/fallback/
payloadGeneration`, `PendingRouteRideDelivery.pending`, `ridePayloadGeneration`,
lease-generation snapshot; `ride_delivery_protocol.hpp:266-273` `GroupTracker`
`pendingValid_/pendingMask_/pendingAdmittedMask_`. Empty → Staged(gen) → Applied;
group Pending(mask) → Complete. Written on the host task, consumed by
`processPendingMapInputs` on the UI task.

**BLE-16 Disconnected-shutdown countdown** — `disconnected_shutdown_policy.hpp:79-83`
`counting_`, `countdownStartedMs_`, `activeTimeoutSeconds_`, `activeOwnershipClaimed_`,
`shutdownAnnounced_`. Idle → Counting → ShutdownDue → ShutdownRetry. One `update()`; tidy.

**BLE-17 Radio-characterization advertising** (build-flag only) — `:649-653`
`radioAdvertisingMode`, `...StartedMs`, `radioUserWakePending`, `radioNavigationActive`.
Fast(30 s) → Slow, Fast again on wake; `nextAdvertisingMode()` is explicit, the
timestamps around it are not.

**BLE-18 Small latches** — `FreshBootButtonGate` (armed → waiting-release → debounced);
`rendererWindowRequestPending` (`:182`); `lastBleRtcSyncMs` (`:1677`);
`gps_input_freshness::State.hasPacket/packetCount`; `nimbleHostTask` learn-once latch
(`:260`).

## 2. Map rendering (`lib/maps`)

**MAP-1 Render worker task lifecycle** — `maps.hpp:502` handle, `:563-566` atomics
`shutdownAdmissionClosed_`, `renderWorkerShutdown`, `renderWorkerExited`,
`renderWorkerRestartAfterExit`; file-scope mirrors `maps.cpp:123-129`
`gMapRenderWorkerTaskHandle`, `gMapRenderWorkerShutdown`, `gMapRenderControlOperation`.
NotStarted / Running / Stopping / ExitedParked (task suspended, awaiting reclaim) /
StopTimedOut(restartAfterExit) / RestartPending / AdmissionClosed. `startRenderWorker`
(`:4975`), `stopRenderWorker` (`:5067`, 2.5 s wait), `reclaimRenderWorker` (`:5048`),
`recoverRenderWorkerIfNeeded` (`:5116`, every pipeline tick), thunk (`:5127`),
`pollShutdownQuiescence` (`:5029`). Smell: the member and global shutdown flags must stay
in lockstep by convention; a timed-out stop leaves the worker running and relies on a
later tick.

**MAP-2 Vector-map activation mailbox** — `maps.hpp:510-513` pending/completed
activation + `Valid` flags, `:532` sequence, `gMapRenderControlOperation`. Idle →
Requested → Running(worker) → CompletedUnconsumed → Finalized on UI.
`requestVectorMapFolderActivation` (`:6762`), `takeVectorMapActivationRequest` (`:6806`),
`processPendingVectorMapActivation` (`:6821`), `takeVectorMapFolderActivationResult`
(`:6880`). **Smell:** `takeWorkerRequest` (`:4906`) and `processPendingNearbySearch`
(`:6641`) suspend while pending *or* completed, so a result the UI never drains stalls
rendering and Nearby with no timeout.

**MAP-3 Latest-wins render wrapper** — `maps.hpp:503-509` `latestRenderRequest(+Valid)`,
`lastTakenRenderSequence`, `readyRenderResult(+Valid)`, `framePublicationPending`,
`renderFailurePending`; `maps.cpp:124-127` four `gMapRender*` atomics. Shadows the
explicit `LatestWins::State`: `readyRenderResultValid` must equal `state()==Ready` and is
written false in 11 places; the one-shot edge flags are drained by `takeFramePublication`
(`:6112`) / `takeRenderFailure` (`:6119`); the atomics duplicate the generation so the
worker can read it lock-free (two sources of truth).

**MAP-4 Published frame / availability presentation** — `maps.hpp:533-538`
`publishedMapFrame`, `publishedMapFound`, `mapAvailabilityKnown/Available`,
`mapAvailabilityTransitionPending`; `:586` atomic `isMapFound`; `:663` `hasVisibleProjection`.
NoFrame / FrameWithMap / FrameNoMap / TransitionPending edge. Set in `publishReadyFrame`
(`:5620`), reset in three hand-copied places (`:6447`, `:6953`, `:7034`; one omits
`hasVisibleProjection`). `isMapFound` is assigned in ~38 places in block/probe code.

**MAP-5 Pose presenter prediction phases** — `mapPresentation.hpp:456-463` `hasFix_`,
`current_`, `previousPresented_`, `predictionHeadingValid_`, convergence start stamps;
`maps.hpp:555-557` `hasPresentedPose`, `predictionExhaustionCount`,
`lastPredictionExhaustedMs`. FullSpeed (≤1.5 s) → Grace (≤2.5 s) → Exhausted, recomputed
from time on every `present()`; the exhausted *edge* is detected by the caller diffing
snapshots (`maps.cpp:4654`).

**MAP-6 Pose-input dispatch + heading epoch** — `mapPoseInputPolicy.hpp:47-50`
signatures; `maps.hpp:549-550` `lastHeadingSessionSignature`, `headingSessionEpoch`;
`HeadingResolver` `active_/valid_/epoch_/source_` (`mapPresentation.hpp:223`).
NoHistory / PositionKnown / CompleteKnown / HeadingInvalidated.

**MAP-7 Semantic epochs vs signatures** — `maps.hpp:540-546` four epochs + four
signatures; `0` is the "never observed" sentinel for FNV hashes; epochs bumped from
four places (`:4475`, `:6447`, `:6906`, `:7034`).

**MAP-8 Legacy redraw flags** — `maps.hpp:701-703` `isPosMoved`, `redrawMap`, `followGps`.
Set true in 32 places in `maps.cpp` and 18 in `gui/src`; cleared only in `mainScr.cpp`
(`:971`, `:1287`, `:1548-1563`, `:2798`) and `buttonBar.cpp:45`. Coexists with the epoch
pipeline; `isPosMoved` stays pending while a course-up heading is deferred (undocumented).

**MAP-9 Pinch presentation** — `maps.hpp:620-645` `pinchPresentation.active/
settlementPending/capturedFollowGps/hasZoomOutBackdrop`, `:612` backdrop `prepared`.
Idle / Active / SettlementPending / Animating (unobservable: struct zeroed before the
LVGL animation ends, `:8349`). Backdrop support is hard-wired off (`:7762`, `:7779`) so
three fields and ~10 branches are dead state.

**MAP-10 Drag presentation + rolling raster** — `utils/src/mapDragPreview.hpp:82-86`
`active_`, `settlementPending_`, `committedAtMs_`; `maps.hpp:669-684` `usesRollingRaster`,
`waitsForRollingRaster`, `hasBackdrop`. Idle / DraggingOnRaster / DraggingWaiting /
DraggingStatic / SettlementPending / HandedToPinch. `settlementPending_` ends only when
a frame publishes or a cancel arrives; a failing render parks it until the failure retry.
`active && settlementPending` is reachable (begin during settlement).

**MAP-11 Rolling raster window** — `maps.hpp:648-662` `rollingRasterWindow.valid`,
`rollingForegroundReady`. Invalid / Building / Valid / Valid+Foreground; reuse decided
by `rollingRasterCompatible` (`:7117`, eight-field compare). `isMapFound` overwritten
here (`:7582`) outside the worker contract.

**MAP-12 Nearby POI search mailbox** — `maps.hpp:514-531` pending/ready + `Valid`,
`nearbySearchGeneration`, `activeNearbyRequest.sequence` (0 = none), cursor pointer.
Idle / Pending / Active / CancelledStale (generation mismatch) / PausedByStorageControl
(re-queued with old sequence, `:6720`) / ReadyUnconsumed.

**MAP-13 Storage-control job slot** — `maps.hpp:461-462` function pointer + context.
Idle / Queued / Running; Running is invisible to `takeWorkerRequest`.

**MAP-14 Camera lag / throttle** — `mapCamera.hpp:135-136` `Lag::since_`, `pending_`;
`maps.hpp:562` `lastCameraRequestMs`. NotRequired / Pending / Expired.

**MAP-15 Asset health latches** — font: `mapFontAsset.hpp:115-117` sticky
`runtimeUnhealthy_` after 3 failures, mirrored into `maps.hpp` atomics reset only on
root switch; buildings: `FailureRetryCooldown` (`mapBuildingRenderer.hpp:42`); POI:
`nearbyPoiIndexHealthy` atomic (`maps.hpp:292`). Three idioms for "asset unusable".

**MAP-16 Prepared-scene lease** — `mapCamera.hpp:102-104` `valid`, `mapEpoch`,
`generation`; `0` means "incomplete".

**MAP-17 Validator failure latches** — `mapTerrain.hpp:26` `bad_`; `mapBlockFormat.hpp`
`failed_`; `mapNearbyCoverage.hpp:238` `done_/complete_`;
`mapRendererFileValidator.hpp:60-63` three bools selecting one of four validators
(precedence terrain > font > poi > block, should be one enum).

## 3. LVGL UI (`lib/gui`, `lib/ui_scheduler`, `lib/utils`)

**UI-1 Map-tile touch gesture** — `mainScr.cpp:1656-1664` function statics `isDragging`,
`dragStarted`, `dragPreviewStarted`, `pressStartTime`, `longPressTriggered`,
`pendingDx/Dy`, `lastDragRedrawTime`; globals `isScrollingMap` (`:48`), `canScrollMap`
(`:49`); `utils/src/mapTapArbiter.hpp` `pending_/armedAtMs_`. Idle / PressedUndecided /
LongPressFired / DragPreview / LegacyDrag / TapArmed(160 ms). All in `mapEvent`
(`:1693-1882`) plus the 30 ms timer `processDeferredMapTap` (`:560`). Smell:
`pressStartTime` is both a timestamp and a phase marker (`:1765`, `:1793`, `:1806`,
`:1888`); long-press is only detected inside `PRESSING`, so a perfectly still finger
never fires it; an early `break` on a phantom-corner press (`:1702`) leaves the previous
gesture's `isDragging`.

**UI-2 Map tile transition + render-ahead** — `mapTileTransition.hpp:5` two bools;
`mainScr.cpp:94-99` `mapTileTransitionStartedMs`, `UsedRenderAhead`,
`mapRenderAheadPending/Tile/InstanceID/ProfileSignature`. NoTransition /
ConcealedAwaitingFrame / PublishedNotRevealed / Revealed × RenderAhead None/Prepared/
Consumed. `showMainTile` (`:2773`), `acceptPublishedMapFrame` (`:739`),
`revealPendingMapTileIfReady` (`:2921`), `prepareNextMapScreenRenderAhead` (`:923`).
Validity check duplicated at `:2776` and `:2788`; no timeout on `pending`.

**UI-3 Nearby-places screen** — `mainScr.cpp:131-144` `NearbyView` (`showingMap`,
`querying`, `haveResults`, `waitingForPosition`, `querySequence`, `mapEpoch`,
`lastQueryMs`, `radiusM`, `highlightedResult`) + LVGL hidden flags. Picker / WaitingGps /
Querying / Results / ResultsStale / ChooserOpen × radius. `serviceNearbyScreen` (`:2600`,
30 ms tick), `nearbyShowMapTap` (`:2149`), `nearbySearchFurther` (`:2175`),
`showNearbyPicker`/`hideNearbyScreen` (`:2437`/`:2455`). "Unavailable" and "cancelled"
both encode as `querySequence=0`; the view is reset in three places with different
field subsets.

**UI-4 Tileview ownership flags** — `mainScr.cpp:44-50` `isMainScreen`, `isScrolled`,
`isReady`, `activeTile`; `buttonBar.cpp:16` `isBarOpen`. OtherScreen / Scrolling /
ScrollEndFirstEvent / Settled. `isMainScreen` set from 12 sites across four files;
`activeTile` written from both tile position (`:1280`) and `showMainTile` (`:2764`).

**UI-5 Pre-connection screen + map re-entry latch** — `waitingScr.cpp:20-21` volatile
`gpsReceivedFromApp`, `pendingTransitionToMap`; `:41-43` displayed phase/code;
`preConnectionPresentation.hpp:149-150` `MapReentryPolicy`. The six `Phase` values are
explicit; the entry latch (NeverHadNav / TransitionQueued / Consumed / PairingBlocked)
is not. `pendingTransitionToMap` is cleared at `:216` and `:310` and set from the BLE
side with only `volatile`.

**UI-6 Start-Workout request** — `rideTelemetryScr.cpp:73-74` pending flag + start
stamp, 20 s. Idle / Requested; Succeeded, PresentationChanged and TimedOut all collapse
to Idle (`:1104-1113`) so the cause is lost.

**UI-7 World Radio station focus** — `worldRadioScr.cpp:57-64` `pendingStationFocus(+Revision)`,
`randomOnEntryPending`, `renderedRevision`, `renderedPhoneReady`, `reticlePulsing`.
EntryRandomPending / FocusAwaiting / Idle. Cleared in three functions; a lost reply keeps
focus pending until the next command.

**UI-8 Render scheduler baseline** — `mapRenderPolicy.hpp:184-188` `hasRenderedFix_`,
`hasSubmittedFix_`, `hasObservation_`, `pendingForcedReasons_`, `lastSubmissionMs_`.
Contained, but the phase is the product of three bools.

**UI-9 Pinch-out backdrop idle timer** — `mainScr.cpp:574` `idleSinceMs`; `0` doubles
as "not started".

**UI-10 Legacy GPX option flow** — `mainScr.cpp:51` raw `uint8_t gpxAction`;
`buttonBar.cpp:13-15` `isWaypointOpt/isTrackOpt/isOptionLoaded`; `gpxScr.cpp:17-18`;
`gpxDetailScr.cpp:26`. Reset to `WPT_NONE` in three places; option flags double-cleared
in `optionEvent`. Mostly dormant.

**UI-11 Widget edit mode** — `widgets.hpp:32-33` `canMoveWidget`, `widgetSelected` are
`static` in a header, so each translation unit owns its own copy.

**UI-12 Minor latches** — `notifyBar.cpp:105-109` battery sample cache + `statusInitialized`;
`searchSatScr.cpp:12-14` `skipSearch`/`isSearchingSat` with a 500 ms busy-wait;
`settingsScr.cpp:11` `needReboot`; `elevationScr.cpp:51-58` and `rideTelemetryScr.cpp`
rendered/painted diff caches (caches, not phases).

## 4. Map transfer and activation (`lib/map_transfer`, `lib/map_transfer_http`)

**MT-1 On-SD map-root lifecycle (marker files)** — state is the *presence* of
`.installing`, `.stream-checkpoint`, `.ready`, `.operation-prepared`, `.operation-ready`,
`.activation-consumed`, `.library-retained`, `.removing-<session>` tombstones, plus
`/VECTMAP/.pending-stream-activation.json` and `.activation-transaction.json`
(`map_transfer.cpp:47-67`), each with `.bak`/`.tmp` variants that count as present.
Staging → LegacyReady | OperationPrepared → OperationReady → Installed → Removing → Gone.
Writers: `prepareRoot`/`writeFinalMetadata` (`map_stream_install.cpp:940-1210`),
`promotePreparedOperation` (`map_transfer.cpp:2228`), `selectReadyStreamMap` (`:2561`),
`settleSelectionStreamMaps` (`:2712`), `finalizeOperation` (`:2312`),
`restoreRetainedLibraryVersion` (`:2494`), `pruneObsoleteInstalledMaps` (`:4126`).
**Smell:** the root is re-classified by at least five readers with different predicates
(`:2766`, `:4160`, `:3885`, `:5128`, recovery); `.bak` handling repeated by hand; consumed
and `.library-retained` together is legal only to two functions.

**MT-2 Activation transaction journal** — the `"phase"` string in
`.activation-transaction.json` (`:933-952`, legacy `:2035-2082`) plus `retainedSelection`
and `operationID` fields and the file's existence (`hasInterruptedActivation`, `:3622`).
absent / publishing / ready / ready+retained / committed / damaged / quarantined.
Parsed by two readers with different accepted sets (`:2826` vs `:3236`); which of
`.tmp`/`.bak`/primary is authoritative is decided differently in `:3153` and
`:2340-2370`. The file is at once a crash log, a lock and recovery evidence.

**MT-3 Renderer handoff / pending map** — `map_transfer_http.hpp` ~`:190-200`
`pendingMapRoot_`, `SessionId_`, `MapId_`, `OperationID_`, `LibraryCommandID_`,
`RootTaken_`, `pendingRendererAcknowledgement_`, `AutomaticExit_`, `FromLibrary_`.
Idle / OfferedNoAck / AwaitingTake / AwaitingAck → MT-5 or MT-4. Written from the
activation task (`.cpp:2635`) and the library task (`:640`) with different field subsets;
`takeActivatedMapRoot` (`:1953`) has two consumption semantics; a mismatched ack is
silently ignored (`:1970`).

**MT-4 Rollback** — `rollbackKind_` (enum, one axis) + `rollbackSubmitted_`, `Complete_`,
`Succeeded_`, `AutomaticExit_`, `FromLibrary_`, `Session_`, `OperationID_`, `Restored_`.
None / TransferRequested / RuntimeRequested / Submitted / TransferDone (self-clearing) /
RuntimeDone (must be taken by UI, `:2102`). `rollbackSubmitted_` is never reset on
completion; a transfer rollback that `needsReceipt` leaves activation "activating" until
MT-5 runs.

**MT-5 Terminal receipt / operation task** — `terminalOperationID_`, `SessionID_`,
`MapID_`, `AutomaticExit_`, `Failed_`, `CleanupReported_(+AtMs)`, `operationTaskSubmitted_`,
`operationQuery_`, `operationStatus_`. Idle / TerminalPending / Submitted / CleanupFailing
(5 s report throttle) / Done, sharing one worker and one gate with status queries and
commit recovery (`:779-905`). A permanently failing `finalizeOperation` never terminates
and keeps refusing uploads.

**MT-6 Commit recovery (`CommitRecovery`)** — `identity`, `armed`, `responseCompleted`,
`failures`, `retryAfterMs`, `waiting`, `waitingProgress`, `waitingSinceMs` (`:927-935`);
3 attempts, 5→60 s backoff, 10 min stall. None / GrantedUnarmed / Armed / BackingOff /
DeferredWaiting / Exhausted / BootRestoredArmed. `armed` is set by three paths with
different preconditions; `recoverCommitDisposition` reads a *copy* for the stall decision.

**MT-7 Map-library worker** — `libraryAction_` (free string: refresh/select/remove/auto/
manual/automatic-select/suggest), `librarySubmitted_`, `SelectionStarted_`, `Known_`,
`Automatic_`, `ManualPending_`, `RetryAfterMs_`, `RetryStreak_`, block/coverage pairs,
`RejectedSessions_`, command id/error, `Revision_`. Unknown / Idle / Queued / Submitted /
SelectionStarted / RetryBackoff / WaitingRenderer. "Busy" is computed by four different
predicates (`:262`, `:307`, `:361`, `:407`, `:1541`).

**MT-8 Deferred activation + commit grant** — `deferredActivation_` (pending iff session
non-empty), `pendingCommitGrant_` (0 = none), `activationState_.running`. The grant has no
timeout; `releaseCommitGrant` (`:693`) is called from five sites under different conditions.

**MT-9 `MapActivationState` status string** — `running` + `status` ∈ idle/activating/
installed/failed/recovering/prepared (`map_transfer.cpp:1142-1218`). "prepared" exists only
to defeat the `AlreadyInstalled` guard (`.cpp:1024`, `:2466`); `finish` is called with
literals from ~12 sites; `activationSnapshot` (`:1912`) overlays MT-10 on top.

**MT-10 Stream status overlay** — `streamStatusActive_` + `streamInstallState_` snapshot;
cleared by hand in six places; a Paused upload is re-marked active at boot (`:2224`).

**MT-11 Selection anchor two-slot ring** — `/VECTMAP/.selection-anchor-0|1` records
(`map_selection_anchor.hpp`), slot = `newest^1` (`map_transfer.cpp:4958`). None / One /
Two / SameSequenceConflict / ForeignNewer / UnsupportedSchema. Writer (`:4887`) and
reader (`:4982`) duplicate the scan with different foreign-device handling.

**MT-12 Manual-selection intent journal** — `.library-selection-intent.json` presence +
`.library-automatic` content; RAM mirror `libraryManualPending_`, `libraryAutomatic_`.
Reconciliation (`:4092`) is skipped while a select retries, so the intent can stay
pending indefinitely.

**MT-13 Previous-map pair in `active-map.json`** — active + `previous*` fields
(`map_transfer.hpp:103`). None / NoPrevious / WithPrevious / SameRootRefresh. "Promote
previous" is implemented three times (`:3420`, `:3094`, settle).

**MT-14 Stream install file cursor + checkpoint** — `map_stream_install.hpp:150-165`
`currentFd_`, `currentFile_`, `currentSkipped_`, `currentPartPath_`, `nextFileIndex_`,
`bytesAtCheckpoint_`, `checkpointAtMilliseconds_`, `checkpointSequence_`,
`durableFilePrefix` vs `completedFiles`. NoFile / VerifyingSkippedPrefix / WritingPart /
BetweenFiles / CheckpointDue / ResumedFromCheckpoint / ResumedFromReady.
`durableFilePrefix`/`completedFiles` kept in lockstep by hand in five places.

**MT-15 Install-stream request loop** — locals in `handleInstallStream`
(`.cpp:1620-1735`): `remaining`, `lastRead` (10 s idle), `cancelled`, `operationAdmitted`,
`operationAdmissionFailed`, publish throttle. Admission happens inside the progress
callback, so it depends on the 256 KiB / 500 ms throttle firing after the manifest.

**MT-16 `MapSelectionHealth` string state** — unknown/ready/degraded/rolling_back/
rollback_failed with guarded methods, but compared as strings in the library task
(`:597`, `:611`) and set by hand in `observeBootSelection` (`:2052`).

## 5. Transfer, debug, firmware update (`lib/device_transfer`, `lib/device_debug`, `lib/firmware_update`, `lib/firmware_maintenance`)

**TR-1 Transfer session lifecycle (`HttpTransferServer`)** — `device_transfer_http.hpp:149-222`
`enabled_`, `mode_`, `sessionToken_`, `transferGeneration_`, `workerTask_`/`workerStopped_`,
`startedAp_`, `startedStation_`, `hotspotFallback_`, `networkTransport_` (string used as
phase: "", starting, connecting, lan, hotspot), `listenerReady_`, `powerLockHeld_`,
`networkStopFailed_` (sticky), `commitBoundary_.admissionClosed_`. Idle → Enabled →
StationConnecting → LAN|Hotspot → ListenerBound → Serving → Disabling → WorkerParked →
Reclaimed, plus StartupFailed / WorkerCreateFailed / StopPoisoned. `setEnabled` (`:510`),
`runWorker`/`startNetwork` (`:775-1007`), `clearAuthenticatedBleSession` (`:429`),
`process()` (`:753`), `isShutdownQuiescent` (`:1456`, six flags). `enabled_=false` written
in five places; network triple reset in three; generation bumped in eight;
`networkStopFailed_` has no recovery.

**TR-2 BLE link-loss grace window** — `:163-165` `bleLinkGraceActive_`, `DeadlineMs_`,
`LossMs_` + `authenticatedBleSessionId_`. Unbound / Bound / GraceOpen / Adopted / Expired.
Decisions are pure in `transfer_link_grace_policy.hpp`; the clear-triple is copy-pasted
five times. Has a terminal (45 s cap).

**TR-3 Per-request authorization / commit boundary** — `:177-184` `requestInProgress_`,
`currentRequestAuthorized_`, `currentAuthorizationBits_`, `lastUsefulTrafficMs_`,
`activeClient_`, `commitBoundary_`. NoClient / TlsUp / RequestUnauthorized / Authorized /
InsideGrant / Released × AdmissionClosed. Keep-alive is derived from five inputs
(`:1620-1660`); `lastUsefulTrafficMs_` written from four sites.

**TR-4 OTA upload phase, three representations** — `firmware_update_http.hpp:66-85`
explicit `policy::Transaction` + `status_` string (idle/receiving/verified/rebooting/
cancelled/failed) + `firmware_maintenance::Stage`, plus `otaOpen_`/`otaHandle_`/
`updatePartition_`. `handleImage` (`:810`) tests `status_ == "receiving" && otaOpen_`,
not the transaction. **Smell:** `handleCancel` (`:1037`) calls `resetUploadState()`
(which does `transaction_.reset()`, `:1068`) *before* `transaction_.cancel()`, so the
explicit "cannot cancel after CommitStarted" guard (`firmware_update_policy.hpp:44`) is
bypassed; `resetUploadState` is called from ~15 sites.

**TR-5 Boot-time OTA receipt reconciliation** — `firmware_update_http.cpp:417-582`
running-slot `esp_ota_img_states_t` × `receipt::Phase` × `operationRevisionHighWater_`
× `operationDeviceID_` × build flag. `markRunningAppValid` (`:541`, from `main.cpp:2229`),
`rejectRunningApp` (`:570`). A failed receipt persistence on the valid path is ignored
"until next boot" but nothing schedules that retry.

**TR-6 Firmware maintenance mode** — `firmware_maintenance.cpp:12-16` + `main.cpp:108-195`.
`Stage` is an enum but `setStage` is unguarded and called from ~17 sites across three
libraries; the real phase is `retainedRequest` (RTC_NOINIT, consumed once), `runtimeActive`,
`runtimeExitRequested`, `runtimeStartedAtMs`, three loop timers (auth 2 min, inactivity
90 s, overall 10 min) and `BootButtonExitState`. Failed can be overwritten by
NetworkStarting/Ready later in the same boot.

**TR-7 Wi-Fi driver lifecycle (`DeviceWiFiRuntime`)** — `device_wifi_runtime.hpp:35-48`
`initialized_`, `ramStorageReady_`, `initializationFailed_` (set at entry of `initialize()`,
cleared only on full success → partial init is terminal for the boot), `radioStarted_`,
`stationRequested_`, `stationHasIP_`, `apEventStarted_`, `disconnectReason_`.
`stationState()` (`:243`) is derived per call and returns Connecting when nothing was
requested.

**TR-8 Internal operation owner dispatch** — `device_operation_owner.hpp:134-166`
explicit `DispatchState` + `workerTask_`, `callMutex_`, queue contents. NotStarted / Ready /
InFlight / Poisoned; `release()` (`:70`) keeps the static task so Released is
indistinguishable from Ready.

**TR-9 TLS identity rotation** — `device_transfer_tls.hpp:121-129` `active_`, `pending_`,
`activeSlot_`, `initialized_` + NVS selector and two slots. FirstBoot / Recovery(selector
0xffff) / Steady / Prepared / Committed / CleanupFailed. "Pending" is reconstructed at
`load()` (`.cpp:321`) from slot versions.

**TR-10 Per-connection HTTP response phase (`TransferClient`)** — `device_transfer_tls.hpp:208-245`
`connected_`, `tls_`, `socket_`, `responsePersistenceAllowed_`, `responseKeepAlive_`,
`requestBodyConsumed_`, `responseWriteStarted_`, `responseWriteFailed_`,
`responseHeaderInProgress_`, `firstFatalSeen_`, interrupt lease. Unbegun / Handshaking /
Idle / HeaderInProgress / Body / Finished / WriteFailed / Interrupted.

**TR-11 Remote-debug session (`DeviceDebugHttp`)** — `device_debug_http.hpp:52-60`
`configured_`, `runtimeReady_`, frame store `active_`, pointer `active_`, `wakeRequested_`,
`bootPressRequested_`, `exitRequested_`, `exitResponsePending_`. Unconfigured / Ready /
Active / ExitResponsePending / ExitRequested / Teardown (two-step). A repeated
`beginSession` (`:133`) half-resets the session (frame store early-returns, pointer resets).

**TR-12 Frame capture handshake (`FrameStore`)** — `device_debug_frame_store.hpp:90-108`
`active_`, `captureRequested_`, `sequence_`, `lastCaptureMs_`, `consumerLocked_`.
Inactive / AwaitingFrame / FrameReady / ConsumerHolding (a bool mirrors a held mutex);
`end()` takes the mutex with `portMAX_DELAY`.

**TR-13 Remote pointer press phases** — `device_debug_input.hpp:39-249` explicit
`PointerState` shadowed by `enqueuePressed_` (producer view) and `remotePressed_`
(consumer view), validity bits, a fail-safe timer and `physicalOverridePending_` whose
replay (`.cpp:62-70`) is a second driver of the enum.

**TR-14 Durable operation store readiness** — `durable_operation.hpp:70-89` explicit
guarded `Phase` plus `ready_` (poisoned until `restore()`), `generation_==0` (admission
uninitialized), pseudo-phase Forgotten (= `acknowledged` on a terminal record), A/B
`activeSlot_`, `AdmissionFence::floor_`. Same poison pattern in `receipt::Store`.

**TR-15 USB recovery status reader** — `usb_recovery_status/request.hpp:11-44` `size_`,
`overflow_`, `lastByte_` with 1 s reset + 1 s reply limiter. Small and contained.

## 6. Ride automation and diagnostics (`lib/ride_automation`, `lib/ride_diagnostics`, others)

**RA-1 Outstanding decision / transport lifecycle** — `ride_automation_runtime.cpp:41-65`
`hasOutstandingDecision`, `outstandingDecision`, `decisionAcknowledged`,
`outstandingDecisionBeganAtMs`, `lastAcknowledgedDecisionRetryAtMs`, `pendingFrameValid/
Kind/SentAtMs/Attempts`, `promptResponded/Accepted`, `runningStartGraceSessionToken`.
NoDecision → SentUnacked (1/2/4/8 s retries, 4 attempts) → Acked (5 s resend) →
PromptShown → PromptResponded → Confirmed; Expired (30 s) / Cancelled / TransportFailed
(16 s). `processFirmwareShadow` (`:920-1035`), `processInboundTransportFrame` (`:562-660`),
`respondToStartPrompt` (`:1125`), `beginFirmwareShadow` (`:720`). **Smell:**
`hasOutstandingDecision=false` is written at eight sites (`:589`, `:630`, `:647`, `:735`,
`:942`, `:973`, `:1020`, `:1034`) with different companion resets; two clocks
(`pendingSentAtMs`, `outstandingDecisionBeganAtMs`) can disagree after a PromptResponse
re-queues the frame with attempts reset (`:268-276`).

**RA-2 Detection suppression windows and candidate latches** — `ride_automation_policy.hpp:860-889`
`pendingTransition_`, `pendingCancellation_`, three suppression active/until pairs,
`startSuppressionStoppedLatch_`, private `pausePath_`, lifecycle pair, four latches, two
evidence windows, `hasObservedWheelEvidence_`. Quiet / StartCandidate / PauseCandidate /
ResumeCandidate / AwaitingConfirmation / RestartCooldown × manual-running grace. The
explicit `DetectorPhase` is *recomputed* every tick from this; suppression expires lazily
inside getters (`:385-418`), so `startSuppressionActive()` read for NVS persistence
(`runtime.cpp:1040`) can be stale; boot seeding `snoozeStart(0)` (`:735`) measures the
deadline from an arbitrary origin.

**RA-3 Diagnostics recorder chunk / seal / transition / shutdown** — `ride_diagnostics.cpp:89-219`
`activeDescriptor`, `activeHashValid`, `activePath`, `activeFileBytes`, `activeChunk(+Snapshot)`,
`sealRequested`, `sealSequenceCutoff`, `sealPreparationResult`, `sealComplete`,
`storageTransitionRequested/Idle`, `transitionMountGeneration`, `shutdownSealStarted/Ready`,
`checkpointRequested`, `persistentBootSequenceReady`, `recorderResourcesReady/WriterReady`,
writer handle. Uninitialized → ResourcesReady → WriterRunning{NoChunk, ChunkOpen,
ChunkOpenHashInvalid} → SealRequested → Sealed; TransitionRequested; one-way ShutdownSeal.
Three tasks coordinate via ~8 atomics and a semaphore; a timed-out seal caller leaves
"seal in flight" for the next caller to join (`:2176`); `storageTransitionRequested` is
never cleared on the shutdown path (a deferred shutdown leaves the recorder fenced);
`activeChunk` bumped in three places.

**RA-4 Capture binding / detailed lease / policy v2** — `:187-218` `activeCapture[48]`,
`captureGeneration`, `detailedCapture(+DeadlineMs)`, `captureBoundaryPending`, marker
sequence/receipt, `runtimeCapturePolicy{installed,deadline,remaining,filtered}`,
`clockAnchorEmitted`. Unbound / BoundStandard / BoundDetailed / Expired(4 h) ×
PolicyInstalled × BoundaryPending. A policy stays installed after its capture clears;
two boundary requests merge into one rotation; `clockAnchorEmitted` never re-arms on a
storage transition.

**RA-5 Fault capsule flush generations** — `:89-93`, `:166-169` RTC `retainedFaultCapsule`,
current/pending capsules, `faultCapsuleGeneration` vs `QueuedGeneration`, queued checksums,
`FaultCapsuleWriteReceipt::durable`. NoCapsule / Dirty (generations differ) / Queued /
Durable / Reverted (`UINT32_MAX` sentinel forces dirty). Current-boot capsule is withheld
while the queue is non-empty, so under load it is only flushed by a seal.

**RA-6 Social riders portrait staging** — `social_riders_protocol.hpp:14-18`, `:123-127`
`epoch`, `stagingSlot` (255 = none), `offset`, `stagingHash`, per-rider `present/imageReady/
hash/imageHash`. Absent → Present → Staging(slot, offset) → Complete → ImageReady; single
slot, so a second rider's begin abandons the first partial image (`:173`).

**RA-7 Route elevation transfer staging** — `route_elevation_protocol.hpp:541-556` `staging_`,
`failed_`, `failure_`, `transferId_`, `nextChunk_`, `received_`, `expectedCrc_`, `startedMs_`,
`hasProfile_/hasProgress_` + explicit `ProfileState`. Idle / Staging / FailedButStaging /
Committed / Rejected; 10 s `expire` runs only on the next inbound frame.

**RA-8 Diagnostics HTTP exit-after-response** — `ride_diagnostics_http.cpp` `exitAfterResponse_`
+ `retentionLeaseDeadlineMs` (`ride_diagnostics.cpp:209`). Serving / ExitPending / Disabled.
Two owners refresh the 10 min retention lease; a long chunk download can race pruning.

**RA-9 Detailed-capture end-of-ride** — `runtime.cpp:857-895` `retainedLifecycle`,
`workout.stale`, `lastCoreReceivedAtMs`, 5 min grace. Tracking / TelemetryLost / Ended;
judgment frozen at the last frame (documented).

**RA-10 Transport retry counter** — subset of RA-1: `pendingAttempts` 0..4 with
exponential delay; `queueTransportFrame` (`:266`) resets it for PromptResponse frames
while the decision deadline keeps running.

**RA-11 Writer memory-deferral episode** — `ride_diagnostics.cpp:1147-1188` local
`MemoryDeferral{active,startedMs,lowest}`. Clean two-state.

**RA-12 Recovery backoff** — `ride_diagnostics_storage_policy.hpp:79-107` `armed_`,
`waitStartedMs_`, `delayMs_`. Disarmed / Armed / ProbeDue. Clean.

**RA-13 UI error / resumed-message timers** — `runtime.cpp:55-58` `uiError`, `uiErrorUntilMs`
(8 s), `resumedMessageUntilMs` (3 s); cleared on read inside `uiSnapshot` (`:1052`), so
`needsAttention` has the side effect of expiring the error.

**RA-14 Renderer diagnostics session/window** — `renderer_diagnostics_policy.hpp:909-911`
`sessionActive_`, `measurementWindowId_`, `windowStartedAtMs_`; `renderer_diagnostics.cpp:26`
`frameTransferActive`. NoSession / Session{NoWindow, Window(id)}. Clean, id-keyed.

**RA-15 Delivery callback validity** — `renderer_delivery_timing.hpp:97-110` explicit phase,
implicit validity = (session, ordinal, channel) match; `reset()` bumps session. Clean.

**RA-16 World radio request correlation** — `world_radio_runtime.cpp:45-84` local
pre-seeded `PlaybackState` + `request.requestId` vs `status.requestId`. AwaitingPhone has
no timeout and no error state; PlayPause/Prev/Next show the old station as Playing until
the phone answers.

**RA-17 GPS displacement window** — `runtime.cpp:70-103` ring + `gpsWindowSource` guard.
Data window, not a lifecycle.

## 7. Main loop, power, board (`src/main.cpp`, `lib/power*`, `lib/display_power`, `lib/storage`, `lib/panel`, `lib/speaker`, `lib/gps`, `lib/waveshare_board`)

**SYS-1 1.75-inch CST9217 touch reader** — `panel/WAVESHARE_AMOLED_175.cpp:300-654`
`touchInitialized`, `touchHintConfigured`, `touchPressed`, `touchBackoffUntilMs`,
`consecutiveTouchReadFailures`, `lastValidTouchMs`, `lastTouchHintActive`,
`touchHintStateKnown`, `primaryTouchId`, `suppressPrimaryTouchUntilRelease`,
`touchInterruptGeneration` / attempted, `touchReadWindow`, `previousRawTouchFrame`.
Uninitialized(5 s retry) / Idle / HintActive / FollowUpWindow / Pressed / PressedGrace /
Backoff / ReinitBackoff / PrimarySuppressed. `readTouch` (`:992`, every indev poll and from
`main.cpp:2688` while dimmed), `noteTouchReadFailure` (`:902`, four backoff formulas),
`releaseAllTouches` (`:772`, six callers), `publishTouchFrame` (`:355`). The 2.06 FT3168
reader (`:390-627`) is a diverged duplicate; the failure counter wraps after 20 idle
failures (`:926`); the backoff deadline is written in five places; suppression is set by
two unrelated sources and cleared only by a zero-contact frame.

**SYS-2 Display inactivity / panel power stack** — `main.cpp:619-622` `currentDisplayMode`
(copy of the policy's mode), `displayInactivityPolicy`, `:975-1010` `static Signals`
(~20 baseline fields + two poll sub-timers), `display_power.cpp` manager flags + policy
requested/applied/`pendingPanelChange_`/`fullRefreshRequired_`, `mainTimer` paused/period
(`:1146`), `waitScreenRefresh` (`tft.cpp:18`). Effective state is the tuple (policy mode,
`currentDisplayMode`, requested, applied, timer paused, LVGL cadence) ≈ Active / Dimmed /
Off / Transfer / DeferredNotice. **Smell:** `showShutdownDeferredNotice` (`:668`) writes
`currentDisplayMode = Dimmed` directly, bypassing the policy; activity detection is a
hand-rolled diff of ~20 fields; the `initializePanel` fallback (`display_power.cpp:272`)
powers the panel without `markPanelInitialized`, after which every panel change is a
silent no-op.

**SYS-3 Storage mount / pin / degrade / shutdown** — `storage.hpp:150-175` `isSdLoaded`,
`internalFallbackMounted`, `backendPinned_`, `mapStorageAvailable_`, `mountedBackend`,
`diagnosticsSdHealthy`, `lastDiagnosticsMountResult`, `shutdownAdmissionClosed_/Started_/
Complete_`, `waveshareMigrationBusBegun` (`.cpp:119`), `mountGeneration_` (declared at
`:152`, never incremented). Unmounted → RemovableMounted | FFatMounted | Unavailable →
Pinned → Degraded (one-way, `:235-258`); diagnostics Healthy/Unhealthy; shutdown
AdmissionClosed → TaskStarted → Complete. `storageBackend()` (`:268`) derives the backend
from three atomics so after a degrade `mapStorageRoot()` still points at `/sdcard` while
`getSdLoaded()` is false; a failed `xTaskCreate` after `shutdownStarted_` leaves
`shutdownComplete_` false forever.

**SYS-4 BOOT button press/release + pairing arming** — `main.cpp:269-278` ISR latch
`waveshareBootScreenCyclePending`, `WaitingForRelease`, `HandledPairingConfirmation`,
`ReleaseStartMs`, `PressStartMs`, `waveshareBootPairingGate`, `wavesharePowerPairingGate/
Generation`. Idle → Pressed → ReleaseDebouncing(50 ms) → Idle × pairing gate Armed(gen)/
Cancelled. Press edge decides confirm-vs-cycle (`:326-348`), release decides long-press
forget-owner (`:364`), `armOwnershipPairingAfterRenderedComparison` resets all five after
each flush (`:432-449`). Reset exists in two places; `HandledPairingConfirmation` assigned
twice back-to-back (`:329`, `:332`); one gesture can fire both the press and release actions.

**SYS-5 Pending map renderer activation + label rollback** — `main.cpp:474-503`
`pendingMapRendererActivation{source, rendererQueued, queueAttemptStartedMs}`,
`rendererMapDiagnosticIdentity`; function-local statics `labelRuntimeFailure`,
`labelRollbackQueued` (`:2435`). None → PendingUnqueued(≤10 s retry) → Queued → None;
Idle → FailureCaptured → RollbackQueued. A non-matching renderer result still clears the
pending record and sends a failure ack (`:2417`); the identity is rewritten in four places.

**SYS-6 Power-management startup lock / wake pipeline** — `power_management.cpp:36-52`
`attempted`, `startupLockHeld`, `wakeSourcesReady`, `wakeSourceConfigurationFailed`,
`wakeCaptureRegistered`, `gpioWakeNotifier`, runtime `enabled/startupComplete`.
NotAttempted → Enabled | Failed(one-shot); StartupLocked → Released only when five
conditions hold; `completeStartup` silently keeps the lock forever otherwise (log only in
diagnostic builds).

**SYS-7 Speaker codec resources + shutdown** — `speaker.cpp:34-88` `SpeakerResourceState`
(9 bools), `initialized`, device/channel pointers, `playbackActive`, `shutdownRequested/
Acknowledged`, `powerButtonHonkAvailable`, `powerButtonMonitoringConfigured`,
`lastPowerButtonConfigureAttemptMs`. Idle → PartiallyAllocated (ordered subset,
`initialized=false`) → Ready → TearingDown (failures retain a subset); shutdown
NotRequested → Requested → Acknowledged. The PWR-honk configure-retry machine (`:815`) is
unreachable because `powerButtonHonkAvailable` is forced false at `:683`.

**SYS-8 Power shutdown request/deferral wrapper** — `power.hpp:20-31`, `power.cpp:149-194`
`shutdownRequested_`, `restartRequested_`, `lastProgress_`, `deferredNotice_`;
`main.cpp:628` `shutdownDeferredNoticeShown`, composite drain callback (`:1587-1620`).
Beyond the explicit Barrier: DeferredStillDraining (`:165`, `:190`) and NoticeShown
(terminal for the UI). Progress watchdog folds four counters into one `uint64`.

**SYS-9 GPS one-shot time/fix flags** — `gps.cpp:16-18` `setTime` is initialised `true`
and only ever assigned `true` again (`:169`), so the "set system time from GPS once"
block (`:161`) can never run; `isTimeFixed` is never written. Vestigial. Ride-source
hysteresis (`:26`, `:316-341`) is an explicit enum with implicit sticky memory.

**SYS-10 Boot-mode trichotomy** — SafeMode / Maintenance / Normal are not a variable:
early `return`s in `setup()` (`main.cpp:1690-1698`, `:1779`) and `if … return` chains at
the top of `loop()` (`:2264-2277`), with Maintenance's 750 ms RebootPending timer in
`loop()` rather than in `firmware_maintenance`.

**SYS-11 Small ones** — AXP2101 `pmuAvailable` (`axp2101.cpp:30`) re-probes three times on
every battery read while absent, no backoff; I2C `busConfigured` recover loop
(`i2c_bus.cpp:43`, `:110-140`); PCF85063 `present/timeValid/source`; QMI8658
`present/configured/dataValid` with `resetMotionWindow` in three places; battery read
cache; ordinary renderer-diagnostics session (`main.cpp:615-616`, `:2602-2650`) with
`endSession` from four sites; `processTransferInactivityTimeout` 1 s poll gate.

---

## Cross-cutting patterns

1. **Generation counters as revocation.** `transferGeneration_` (TR-1, bumped in eight
   places), `captureGeneration` (RA-4), `nearbySearchGeneration` (MAP-12),
   `diagnosticsSessionStartGeneration` (BLE-8), `pairingGeneration_` (BLE-4),
   `faultCapsuleGeneration` (RA-5), `cancellationGeneration` (MAP-3). The phase is
   "my generation == current generation"; staleness is only discoverable by comparison
   at the consumer, never by a state name.
2. **Copy-pasted reset sequences.** BLE session clear (5×), grace clear (5×),
   `enabled_=false` (5×), ride-automation decision clear (8×), `readyRenderResultValid=false`
   (11×), `resetUploadState` (15×), nearby view reset (3×). Every one is a place where a
   future field is forgotten.
3. **Strings as phases.** `status_` in OTA (TR-4), `networkTransport_` (TR-1),
   `libraryAction_` (MT-7), `MapActivationState.status` (MT-9), `MapSelectionHealth.state`
   (MT-16), the journal `"phase"` (MT-2), `pendingAuthNonce` non-emptiness (BLE-6/7).
4. **Lazy expiry on read.** Suppression windows (RA-2), lease expiry (BLE-6), UI error
   timers (RA-13), prediction phases (MAP-5), station state (TR-7). A getter changes the
   answer depending on when it is called, and persistence can snapshot a stale value.
5. **Mailbox pairs** (`payload` + `valid`): activation (MAP-2), render request/result
   (MAP-3), nearby (MAP-12), map input (BLE-15), fault capsule (RA-5), pending map root
   (MT-3). Several lack a timeout on the "produced but never consumed" state.
6. **Explicit enum shadowed or derived.** `LatestWins::State` (MAP-3), `Transaction`
   (TR-4), `PointerState` (TR-13), `DetectorPhase`/`UiPhase` (RA-2, recomputed every
   tick), `maintenance::Stage` (TR-6, unguarded from 17 sites), `MapStreamInstallState`
   (6 mutation sites inside one class), `display_inactivity::Mode` (derived).
7. **Persisted state that can disagree with RAM.** Marker files vs HTTP server fields
   (MT-1/3), journal vs activation state (MT-2/9), selection intent vs `libraryAutomatic_`
   (MT-12), TLS slot selector vs `pending_` (TR-9), suppression in NVS (RA-2), RTC
   capsules (RA-5, sleep audit).

## Where an explicit machine would pay off most

Ranked by blast radius and by how many of the smells above a single enum would remove:

1. **MT-1 + MT-2 + MT-9** map-root marker files, journal phase string and activation
   status: one `RootState` classifier used by every reader, and one activation enum
   instead of a string, would collapse five divergent predicates and two parsers.
2. **TR-4** OTA upload: drop `status_` and the maintenance stage mirror in favour of
   the existing `Transaction`, and fix the reset-before-cancel ordering that bypasses the
   CommitStarted guard.
3. **BLE-1** link session: one `clearSession()` and one deadline check instead of five
   and two copies.
4. **RA-1** ride-automation decision: one `OutstandingDecision` enum with a single
   `settle(reason)` instead of eight reset sites and two clocks.
5. **MAP-2 / MAP-3** activation mailbox and render wrapper: a timeout on the
   completed-unconsumed state and removal of the duplicated generation atomics.
6. **SYS-2** display power: delete `currentDisplayMode` and route the deferred notice
   through the policy.
7. **SYS-1** touch reader: share one reader between the 1.75 and 2.06 panels with an
   explicit phase, and stop the failure counter wrap.
8. **TR-1** transfer server: an explicit transport/listener enum replacing the
   `networkTransport_` string and the three-flag network triple.

Dead or vestigial state worth deleting outright: GPS `setTime`/`isTimeFixed` (SYS-9),
speaker PWR-honk retry (SYS-7), `mountGeneration_` (SYS-3), pinch zoom-out backdrop
fields (MAP-9), legacy GPX option flow (UI-10).

---

## Explicit machines passed over (for separation)

Clean, single-owner, guarded: `shutdown_barrier::Barrier` Stage; `sleep_audit` Stage
(forward-only RTC capsule); `boot_diagnostics::policy::Stage` (five guarded transitions,
flag/stage invariant in `isValid`); `durable_operation::Phase` (`transition()` table);
`receipt::Phase` + `ReconcileAction`; `commit_boundary_policy::Boundary`;
`map_render_job::LatestWins`; `map_nearby_storage::SearchCursor::Phase`;
`map_pinch_zoom::State`; `storage_stream_admission` slot (Empty/Opening/Open/Closing);
`BootButtonExitState`; `disconnected_shutdown_policy::Tracker`;
`route_elevation::ProfileState` (phone-owned); `workout_telemetry::SessionState` (reduced
in `applyFrame`); stream validators (`MapStreamIncrementalParser::Stage`,
`mapBlockFormat` Binary/V3/Ascii/Coordinate states, `mapContourFormat::State`,
`mapFontAssetFormat::State`).

Explicit but shadowed, derived or unguarded (also counted above): `Transaction`/
`TransactionStage` (TR-4), `firmware_maintenance::Stage` (TR-6), `DispatchState` (TR-8),
`PointerState` (TR-13), `StationState` (TR-7, derived), `MapStreamInstallState` (six
mutation sites), `RollbackKind` (MT-4, one axis), `DetectorPhase` / `MotionEvidenceState` /
`DetectionHealthState` / `UiPhase` (RA-2, derived per tick), `display_power::State`
(requested from five sites), `display_inactivity::Mode` (derived), `PlaybackState`
(RA-16, locally pre-seeded), `runtime_watchdog::Phase` (reporting record).

Value, result and classification enums with no transitions: `DestinationPickerStatusCode`,
`AdvertisingMode`, `NetworkStartStep`, `TransferTlsFailureStage`, `LanSessionMode`,
`ResourcePhase`, `CaptureMode`, `StartMode`, `MemoryObservationPhase`,
`DeliveryCallbackPhase`, `power_metrics::DisplayState`, `i2c::TransactionPhase`,
`Cst9217DecodeStatus`, `map_projection::Mode`, `RotationMode`, `MetricLayoutMode`,
`navigation_content_mode::Mode`, `StatusMutation`, `ScreenState` (pure `status()`),
`pre_connection_presentation::Phase` (pure `resolve()`).
