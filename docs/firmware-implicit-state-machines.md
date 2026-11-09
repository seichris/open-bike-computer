# Implicit state machines in the ESP32 firmware

Inventory taken on 2026-11-07 at `fd0689c8` (main after #769) and refreshed on 2026-11-09
at `dd610395` (main after #797). Read-only survey of `esp32/src` and every non-vendored
library under `esp32/lib` (about 112k lines; LVGL, esp_codec_dev, tinyxml2, fonts and image
arrays excluded).

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
told apart. Line numbers are approximate anchors into the files at `dd610395`.

The iPhone app, Watch app and cross-device protocols are inventoried in
[app-and-cross-device-implicit-state-machines.md](app-and-cross-device-implicit-state-machines.md).

Counts: **115 implicit machines** across 9 areas; **~62 explicit enums**, of
which about 17 are shadowed or unguarded enough to belong in both lists.

**Refresh 2026-11-09.** Re-checked against `dd610395`, 163 commits after the first survey:
the Waveshare 3.97-inch e-paper board (#442), the board-family split (#770, #772, #792), the
GNSS position source (#775, #776, #784, #785), the unsettled-previous-map gate (#791) and
the simulator map LAN (#797). #789 removed a widget no entry described.
- New: section 8 (POS-1 to POS-4), section 9 (EP-1 to EP-5) and cross-cutting pattern 8.
- Rewritten: BLE-5, MAP-3, MAP-4, MAP-14, UI-5, UI-8, MT-13, MT-16, SYS-1, SYS-2, SYS-4,
  SYS-9, SYS-10, SYS-11, RA-17.
- Amended: BLE-4, BLE-16, BLE-18, MT-12, TR-1, TR-6, SYS-3.
- Corrected from the first survey: it stated 96 machines but listed 106; TR-1 bumps its
  generation at six sites, not eight; TR-6 has 13 `setStage` call sites across four files,
  not about 17 across three; SYS-1's release has seven call sites, not six; the anchors of
  TR-2, TR-3, TR-9, MT-16 and RA-17 pointed at the wrong lines.
- Every other anchor was carried through the diff hunks mechanically; anchors next to a
  named identifier were re-checked against the new code. Behavioural claims come from
  reading code; none were exercised on hardware.

---

## 1. BLE and ownership (`lib/ble_navigation`)

**BLE-1 Link session lifecycle** — `ble_navigation.cpp:212` `activeConnHandle`,
`:152` `bleSessionAuthenticated`, `:652` `unauthenticatedWindowStartMs`, `:213`
`unauthTimeoutDisconnectRequested`, `:730` `ownershipDisconnectPending`,
`:221-223` connection start / local disconnect cause / pending ownership cause,
plus ~14 `bleSessionSupports*` capability atomics (`:153-166`).
States: NoLink → Accepted/Unauthenticated (window running) → Authenticated(+caps)
→ DisconnectRequested(cause) → NoLink; "ownership invalidated while linked" is a
sub-state. Transitions: `acceptConnection` (`:6743`), `completeBleSessionAuthentication`
(`:3058`, `:2880`), `process()` deadline (`:8174`, duplicated verbatim for the
maintenance boot at `:8293`), `disconnectActive` (`:6869`), Unpaired/recovery
resets (`:2909`, `:8535`). Smell: the ~20-store "clear session" sequence is
copy-pasted in five places; capability flags are a mix of plain bools and atomics.

**BLE-2 Transfer link-loss grace driver** — the grace state lives in
`device_transfer` (TR-2) but is driven from `disconnectActive` (`:6893-6918`),
`acceptConnection` (`:6752`), `process()` expiry (`:8279`) and
`rebindTransferAfterLinkGrace` (`:4475`). Whether a disconnect opens a window
depends on three bools evaluated inline; the two terminal states (Expired,
Rebound) are produced in different tasks.

**BLE-3 Transfer connection-profile sync** — `:642-647` `transferProfileHandle`,
`transferProfileLinkStartMs`, `transferProfileApplied`; `:589` `transferWindowOpen`.
NoLink / navigation profile / transfer profile keyed by (handle, linkStartMs) to
defeat NimBLE handle reuse. One tick-polled diff in `syncTransferConnectionProfile`
(`:8387`). Clean but polled.

**BLE-4 Device ownership pairing** — `device_ownership.hpp:188-193` `pairingActive_`,
`pairingConfirmedOnDevice_`, `pairingAttemptedOnConnection_`, `pairingStartedMs_`,
`pairingGeneration_`, `armedPairingGeneration_`. Idle → Pairing(code, timer) →
Armed(gen) → ConfirmedOnDevice → Claimed, or Expired/Failed. Transitions: `PAIR`
(`device_ownership.cpp:535`), BOOT-button arm/confirm (`:1068-1084`), `CONFIRM`
(`:585`), `process()` timeout (`:495`), `resetConnection` (`:486`), `clearPairing`
(`:1787`) from every failure path. Smell: timeout checked in two places; the
"claimed but owner record invalid" fail-closed state is only a flag pair (`:630`). Since #442 `cancelPairingOnDevice()`
(`device_ownership.hpp:62-66`) is a new exit from Pairing, reached only from the e-paper
side keys (`board_input.cpp:45-46` → `ble_navigation.cpp:8556-8564`); it clears the pairing
without telling the phone (X-5 in the app document).

**BLE-5 Ownership presentation mirror + restart** — `ble_navigation.cpp:690`
`ownershipPairingActiveSnapshot`, `:729` `ownershipAdvertisingDirty`, `:731-732`
`ownershipRestartRequested/Ms`, `:734-741` `ownershipUi*` + `ownershipUiUpdatePending`,
`:742-743` the `ComparisonRenderGate`; `ownership_button_policy.hpp` `ComparisonRenderGate` /
`FreshPowerButtonGate`. UiStale → UiQueued → UiApplied; AdvertisingClean/Dirty (applied only
on next disconnect, `ble_navigation.cpp:6999-7001`); RestartPending 500 ms after Unpaired
(`:2921-2923`, `:8548-8551`, fired `:8202-8206`). Since #442 the comparison gate (a
pending/rendered generation pair) has two attestation inputs with different meanings: the
AMOLED flush hook (`main.cpp:182-186` → `displayFlushed`, any completed flush while the
comparison screen is active) and the e-paper waveform completion
(`epaper_display.cpp:468-469` → `displayGenerationCompleted`,
`ownership_button_policy.hpp:28-31`, only for a frame tagged with the current pairing and
display context; EP-3). On the e-paper the gate request and cancel also set the display's
pairing generation, which bumps its context (`ble_navigation.cpp:1054-1056`,
`:1062-1064`). Smell: the pairing snapshot is written from the host task (`:2867`,
`:2871`) and the loop (`:8147`, `:8268`) without the ownership mutex on the former.

**BLE-6 Authenticated session × ride-controller lease** — `device_ownership.hpp:160-177`
`claimed_`, `ownerRecordValid_`, `legacyAuthenticationAllowed_`, `sessionAuthenticated_`,
`sessionRole_`, `sessionId_`, `watchControllerActive_`, `stagedWatchControllerValid_`,
`pendingAuthenticationRole_` + nonce strings; `ride_controller_lease.hpp` (`active_`,
`lastActivityMs_`, `generation_`). Unclaimed → Claimed(valid|invalid) × Session(None |
owner-challenge | watch-challenge | Authenticated(Owner|WatchRide)) × Watch(None|Staged|
Committed). Smell: "challenge pending" is a non-empty nonce string; the lease expires
lazily inside `expireIfNeeded()` on every query.

**BLE-7 Legacy pre-ownership handshake** — `ble_navigation.cpp:191` `pendingAuthNonce[33]`:
empty → challenge issued (`:3027`) → cleared on proof (`:3059`) or connect/disconnect.
A two-state machine held in a string; duplicated by the v2 path inside `DeviceOwnership`.

**BLE-8 Diagnostics transfer async start** — `:748-754` `diagnosticsSessionStartInProgress`,
`StartGeneration`, `ActiveGeneration`, `PreparationComplete`, task handle. Idle →
Starting(gen, worker) → WorkerParked(complete, task suspended) → Applied | Stale.
`startDiagnosticsSessionAsync` (`:4433`), worker self-suspend (`:4334`),
`processCompletedDiagnosticsSessionStart` (`:4337`), `cancelDiagnosticsSessionStart`
bumps the generation (`:4287`). Four atomics + a handle for one lifecycle.

**BLE-9 Destination-picker request** — `:765-767` `destinationRequestPending`,
`StartedMs`, `StatusUpdatedMs` + explicit `DestinationPickerStatusCode`. Idle →
Pending(timer) → Calculating → terminal(display timer) → Idle. `beginDestinationRequest`
(`:1129`), `applyDestinationResponseIfPending` (`:1141`), timeout (`:1176`), expiry
(`:1188`), disconnect finish (`:7007`). Pending-ness and status code must agree by hand.

**BLE-10 Screen-configuration transport** — `:769-811` `PendingScreenConfigurationControl`
(`snapshotRequested`, `uploadReady`, `acknowledgementReady`), outgoing snapshot
`active`/`nextChunk`, `screenConfigurationSnapshotActive`, `AckPending`, `ResetRequested`.
Idle → UploadStaged | SnapshotRequested → AckQueued → AckSent; snapshot Streaming.
Host-task callbacks stage, `processPendingScreenConfiguration` (`:2527`) consumes one per
pass, `pumpScreenConfigurationNotifications` (`:2466`) drains. The "one ACK slot" is an
if/else ladder over readiness bools.

**BLE-11 Legacy settings import debounce** — `screen_configuration.cpp:58-61`
`legacyChangedAtMs`, `legacyChangePending`, `legacyMaskPending`, `legacyDefaultPending`.
Idle → Pending(250 ms) → Imported, re-armed forever on readback failure (`:794`).

**BLE-12 Workout telemetry core/extended pairing** — `workout_telemetry_state.hpp:753-756`
`transactionalCorePending_`, `transactionalGeneration_`, `legacyCoreAwaitingExtended_`,
`legacyCoreToken_`; `:869-871` resynchronizer `stagedCoreAccepted_`,
`stagedRequiresCurrentCollisionReplacement_`, `resynchronizationPending_`; `State`
bools `:50-54`. NoCore → CoreStaged → PairCommitted; on re-auth Resync → Promoted|Dropped.
Pure and host-tested, but ~8 bools across two classes.

**BLE-13 Deferred notification dispatch** — `:712-722` ring `head/tail/count` +
`deferredNotificationEventReady/Pending/Scheduled`, `shutdownWritesClosed`. NotReady →
Idle → Pending → Scheduled → Draining → (Pending|Idle); Closed at shutdown. Producer
(`:2111`), owner task (`:2161`), host-task handler (`:2307`). Three atomics plus a count
stand in for one enum; the decision table in `deferred_notification_dispatch_policy.hpp`
is the explicit half.

**BLE-14 Status chunk pumps (map / device / renderer)** — `:194-203`
`pendingMapTransferStatusChunks.active_`, `...Continuation`, `...Refresh`,
`pendingMapAvailabilityStatus`; `map_transfer_status_chunk_session.hpp:122-123, 242-246`.
Idle → Streaming(nextIndex)[+RefreshRequested] → Done (`:3858-3934`, `:8208-8218`).
Three parallel copies with slightly different flag sets.

**BLE-15 Pending map-input mailbox** — `:1372-1418` `PendingMapInput.pending/fallback/
payloadGeneration`, `PendingRouteRideDelivery.pending`, `ridePayloadGeneration`,
lease-generation snapshot; `ride_delivery_protocol.hpp:266-273` `GroupTracker`
`pendingValid_/pendingMask_/pendingAdmittedMask_`. Empty → Staged(gen) → Applied;
group Pending(mask) → Complete. Written on the host task, consumed by
`processPendingMapInputs` on the UI task.

**BLE-16 Disconnected-shutdown countdown** — `disconnected_shutdown_policy.hpp:79-83`
`counting_`, `countdownStartedMs_`, `activeTimeoutSeconds_`, `activeOwnershipClaimed_`,
`shutdownAnnounced_`. Idle → Counting → ShutdownDue → ShutdownRetry. One `update()`; tidy. The countdown never runs on boards without
`board::power::qualifiedPowerControl` (the e-paper), because `processDisconnectedShutdown`
returns first (`main.cpp:1371-1376`).

**BLE-17 Radio-characterization advertising** (build-flag only) — `:654-658`
`radioAdvertisingMode`, `...StartedMs`, `radioUserWakePending`, `radioNavigationActive`.
Fast(30 s) → Slow, Fast again on wake; `nextAdvertisingMode()` is explicit, the
timestamps around it are not.

**BLE-18 Small latches** — `FreshBootButtonGate` (armed → waiting-release → debounced);
`rendererWindowRequestPending` (`:187`); `lastBleRtcSyncMs` (`:1688`);
`gps_input_freshness::State.hasPacket/packetCount`; `nimbleHostTask` learn-once latch
(`:265`). On the e-paper `FreshBootButtonGate` is
re-armed on every loop pass while a pairing code exists but is not on glass
(`main.cpp:213-215`).

## 2. Map rendering (`lib/maps`)

**MAP-1 Render worker task lifecycle** — `maps.hpp:549` handle, `:610-620` atomics
`shutdownAdmissionClosed_`, `renderWorkerShutdown`, `renderWorkerExited`,
`renderWorkerRestartAfterExit`; file-scope mirrors `maps.cpp:123-129`
`gMapRenderWorkerTaskHandle`, `gMapRenderWorkerShutdown`, `gMapRenderControlOperation`.
NotStarted / Running / Stopping / ExitedParked (task suspended, awaiting reclaim) /
StopTimedOut(restartAfterExit) / RestartPending / AdmissionClosed. `startRenderWorker`
(`:4999`), `stopRenderWorker` (`:5091`, 2.5 s wait), `reclaimRenderWorker` (`:5072`),
`recoverRenderWorkerIfNeeded` (`:5140`, every pipeline tick), thunk (`:5151`),
`pollShutdownQuiescence` (`:5053`). Smell: the member and global shutdown flags must stay
in lockstep by convention; a timed-out stop leaves the worker running and relies on a
later tick.

**MAP-2 Vector-map activation mailbox** — `maps.hpp:557-560` pending/completed
activation + `Valid` flags, `:579` sequence, `gMapRenderControlOperation`. Idle →
Requested → Running(worker) → CompletedUnconsumed → Finalized on UI.
`requestVectorMapFolderActivation` (`:6815`), `takeVectorMapActivationRequest` (`:6859`),
`processPendingVectorMapActivation` (`:6874`), `takeVectorMapFolderActivationResult`
(`:6933`). **Smell:** `takeWorkerRequest` (`:4930`) and `processPendingNearbySearch`
(`:6694`) suspend while pending *or* completed, so a result the UI never drains stalls
rendering and Nearby with no timeout.

**MAP-3 Latest-wins render wrapper** — `maps.hpp:549-556` `latestRenderRequest(+Valid)`,
`lastTakenRenderSequence`, `readyRenderResult(+Valid)`, `framePublicationPending`,
`renderFailurePending`; `maps.cpp:124-127` four `gMapRender*` atomics. Shadows the explicit
`LatestWins::State`: `readyRenderResultValid` must equal `state()==Ready` and is written
false in 11 places. The one-shot edges are drained by two `takeFramePublication` overloads
(`maps.cpp:6090`, `:6096`; the second also hands over the `framePublication_` provenance
payload, `maps.hpp:616`, filled at `maps.cpp:5643-5650`) and by `takeRenderFailure`
(`:6169`), which since #442 turns the failure edge into the level flag `recoveryPending_`
(`maps.hpp:617`; set `maps.cpp:6177`, cleared on publish `:5641` and in two of the three
resets, `:7016` and `:7096`) that the e-paper status line reads. The atomics duplicate the
generation so the worker can read it lock-free (two sources of truth).

**MAP-4 Published frame / availability presentation** — `maps.hpp:580-584`
`publishedMapFrame`, `publishedMapFound`, `mapAvailabilityKnown/Available`,
`mapAvailabilityTransitionPending`; `:640` atomic `isMapFound`; `:722`
`hasVisibleProjection`; `:615-617` `visibleFrameAcceptedAtMs_`, `framePublication_`,
`recoveryPending_`. NoFrame / FrameWithMap / FrameNoMap / TransitionPending edge. Set in
`publishReadyFrame` (`maps.cpp:5504`, fields at `:5639-5657`), reset in three hand-copied
places: `finalizeVectorMapFolderSwitchOnUi` (`:6499-6510`), `deleteMapScrSprites`
(`:7007-7016`) and `createMapScrSprites` (`:7089-7096`). The folder-switch reset still
omits `hasVisibleProjection` and now also omits the four publication fields the other two
clear (`framePublicationPending`, `visibleFrameAcceptedAtMs_`, `framePublication_`,
`recoveryPending_`). `isMapFound` is assigned on 40 lines in `maps.cpp`.

**MAP-5 Pose presenter prediction phases** — `mapPresentation.hpp:463-470` `hasFix_`,
`current_`, `previousPresented_`, `predictionHeadingValid_`, convergence start stamps;
`maps.hpp:602-604` `hasPresentedPose`, `predictionExhaustionCount`,
`lastPredictionExhaustedMs`. FullSpeed (≤1.5 s) → Grace (≤2.5 s) → Exhausted, recomputed
from time on every `present()`; the exhausted *edge* is detected by the caller diffing
snapshots (`maps.cpp:4673`).

**MAP-6 Pose-input dispatch + heading epoch** — `mapPoseInputPolicy.hpp:47-50`
signatures; `maps.hpp:596-597` `lastHeadingSessionSignature`, `headingSessionEpoch`;
`HeadingResolver` `active_/valid_/epoch_/source_` (`mapPresentation.hpp:230`).
NoHistory / PositionKnown / CompleteKnown / HeadingInvalidated.

**MAP-7 Semantic epochs vs signatures** — `maps.hpp:587-593` four epochs + four
signatures; `0` is the "never observed" sentinel for FNV hashes; epochs bumped from
four places (`:4494`, `:6500`, `:6959`, `:7090`).

**MAP-8 Legacy redraw flags** — `maps.hpp:755-757` `isPosMoved`, `redrawMap`, `followGps`.
Set true in 32 places in `maps.cpp` and 18 in `gui/src`; cleared only in `mainScr.cpp`
(`:979`, `:1297`, `:1549-1564`, `:2784`) and `buttonBar.cpp:45`. Coexists with the epoch
pipeline; `isPosMoved` stays pending while a course-up heading is deferred (undocumented).

**MAP-9 Pinch presentation** — `maps.hpp:674-699` `pinchPresentation.active/
settlementPending/capturedFollowGps/hasZoomOutBackdrop`, `:612` backdrop `prepared`.
Idle / Active / SettlementPending / Animating (unobservable: struct zeroed before the
LVGL animation ends, `:8408`). Backdrop support is hard-wired off (`:7821`, `:7838`) so
three fields and ~10 branches are dead state.

**MAP-10 Drag presentation + rolling raster** — `utils/src/mapDragPreview.hpp:82-86`
`active_`, `settlementPending_`, `committedAtMs_`; `maps.hpp:723-738` `usesRollingRaster`,
`waitsForRollingRaster`, `hasBackdrop`. Idle / DraggingOnRaster / DraggingWaiting /
DraggingStatic / SettlementPending / HandedToPinch. `settlementPending_` ends only when
a frame publishes or a cancel arrives; a failing render parks it until the failure retry.
`active && settlementPending` is reachable (begin during settlement).

**MAP-11 Rolling raster window** — `maps.hpp:702-716` `rollingRasterWindow.valid`,
`rollingForegroundReady`. Invalid / Building / Valid / Valid+Foreground; reuse decided
by `rollingRasterCompatible` (`:7176`, eight-field compare). `isMapFound` overwritten
here (`:7641`) outside the worker contract.

**MAP-12 Nearby POI search mailbox** — `maps.hpp:561-578` pending/ready + `Valid`,
`nearbySearchGeneration`, `activeNearbyRequest.sequence` (0 = none), cursor pointer.
Idle / Pending / Active / CancelledStale (generation mismatch) / PausedByStorageControl
(re-queued with old sequence, `:6773`) / ReadyUnconsumed.

**MAP-13 Storage-control job slot** — `maps.hpp:501-502` function pointer + context.
Idle / Queued / Running; Running is invisible to `takeWorkerRequest`.

**MAP-14 Camera lag / throttle (AMOLED family)** — `mapCamera.hpp:135-136` `Lag::since_`,
`pending_`; `maps.hpp:608-609` `cameraLag`, `lastCameraRequestMs`. NotRequired / Pending /
Expired. Since the family split (#772) it is observed and throttled only in
`mapCameraAmoled.cpp:34`, `:65-69`, reflected on publish (`maps.cpp:5640`) and reset at
`:7009-7011`. The e-paper `serviceStableCamera` (`mapCameraEpaper.cpp:20-93`) never feeds
it and derives lag from `visibleFrameAcceptedAtMs_`; base-render admission there belongs to
EP-5.

**MAP-15 Asset health latches** — font: `mapFontAsset.hpp:115-117` sticky
`runtimeUnhealthy_` after 3 failures, mirrored into `maps.hpp` atomics reset only on
root switch; buildings: `FailureRetryCooldown` (`mapBuildingRenderer.hpp:42`); POI:
`nearbyPoiIndexHealthy` atomic (`maps.hpp:332`). Three idioms for "asset unusable".

**MAP-16 Prepared-scene lease** — `mapCamera.hpp:102-104` `valid`, `mapEpoch`,
`generation`; `0` means "incomplete".

**MAP-17 Validator failure latches** — `mapTerrain.hpp:26` `bad_`; `mapBlockFormat.hpp`
`failed_`; `mapNearbyCoverage.hpp:238` `done_/complete_`;
`mapRendererFileValidator.hpp:60-63` three bools selecting one of four validators
(precedence terrain > font > poi > block, should be one enum).

## 3. LVGL UI (`lib/gui`, `lib/ui_scheduler`, `lib/utils`)

**UI-1 Map-tile touch gesture** — `mainScr.cpp:1657-1665` function statics `isDragging`,
`dragStarted`, `dragPreviewStarted`, `pressStartTime`, `longPressTriggered`,
`pendingDx/Dy`, `lastDragRedrawTime`; globals `isScrollingMap` (`:45`), `canScrollMap`
(`:46`); `utils/src/mapTapArbiter.hpp` `pending_/armedAtMs_`. Idle / PressedUndecided /
LongPressFired / DragPreview / LegacyDrag / TapArmed(160 ms). All in `mapEvent`
(`:1694-1883`) plus the 30 ms timer `processDeferredMapTap` (`:570`). Smell:
`pressStartTime` is both a timestamp and a phase marker (`:1766`, `:1794`, `:1807`,
`:1889`); long-press is only detected inside `PRESSING`, so a perfectly still finger
never fires it; an early `break` on a phantom-corner press (`:1703`) leaves the previous
gesture's `isDragging`.

**UI-2 Map tile transition + render-ahead** — `mapTileTransition.hpp:5` two bools;
`mainScr.cpp:87-92` `mapTileTransitionStartedMs`, `UsedRenderAhead`,
`mapRenderAheadPending/Tile/InstanceID/ProfileSignature`. NoTransition /
ConcealedAwaitingFrame / PublishedNotRevealed / Revealed × RenderAhead None/Prepared/
Consumed. `showMainTile` (`:2733`), `acceptPublishedMapFrame` (`:747`),
`revealPendingMapTileIfReady` (`:2908`), `prepareNextMapScreenRenderAhead` (`:931`).
Validity check duplicated at `:2762` and `:2774`; no timeout on `pending`.

**UI-3 Nearby-places screen** — `mainScr.cpp:124-137` `NearbyView` (`showingMap`,
`querying`, `haveResults`, `waitingForPosition`, `querySequence`, `mapEpoch`,
`lastQueryMs`, `radiusM`, `highlightedResult`) + LVGL hidden flags. Picker / WaitingGps /
Querying / Results / ResultsStale / ChooserOpen × radius. `serviceNearbyScreen` (`:2586`,
30 ms tick), `nearbyShowMapTap` (`:2135`), `nearbySearchFurther` (`:2161`),
`showNearbyPicker`/`hideNearbyScreen` (`:2441`/`:2441`). "Unavailable" and "cancelled"
both encode as `querySequence=0`; the view is reset in three places with different
field subsets.

**UI-4 Tileview ownership flags** — `mainScr.cpp:41-47` `isMainScreen`, `isScrolled`,
`isReady`, `activeTile`; `buttonBar.cpp:16` `isBarOpen`. OtherScreen / Scrolling /
ScrollEndFirstEvent / Settled. `isMainScreen` set from 12 sites across four files;
`activeTile` written from both tile position (`:1290`) and `showMainTile` (`:2733`).

**UI-5 Pre-connection screen + map re-entry latch** — `waitingScr.cpp:27-28` volatile
`gpsReceivedFromApp`, `pendingTransitionToMap`; `:48-51` displayed phase/code +
`mapReentryPolicy`; `preConnectionPresentation.hpp:128-160` `MapReentryPolicy` (plus the
compile-time `ConfirmInput`, `:73-75`, added for the e-paper keys). The six `Phase` values
are explicit; the entry latch (NeverHadNav / TransitionQueued / Consumed / PairingBlocked)
is not. `pendingTransitionToMap` is cleared at `waitingScr.cpp:226` and `:315` and set by
`noteNavigationInputForMapEntry` (`:326-334`) from three inputs, all on the main loop: phone
route geometry (`ble_navigation.cpp:5814`), phone GPS (`:5955`) and, since #776, a device
GNSS fix (`main.cpp:2328`). `gpsReceivedFromApp` is a boot-long one-way latch that now also
means "the device's own receiver fixed": on the GNSS variant the first fix leaves Welcome or
WaitingForIPhone for the map with no phone, and after pairing a device fix, not the "fresh
authenticated GPS fix or route" the comment at `waitingScr.cpp:313-314` describes, restores
the map. Route-start seeding keys off the same latch (`ble_navigation.cpp:5804`). Whether
entering the map without a phone is intended is unverified.

**UI-6 Start-Workout request** — `rideTelemetryScr.cpp:78-79` pending flag + start
stamp, 20 s. Idle / Requested; Succeeded, PresentationChanged and TimedOut all collapse
to Idle (`:1089-1098`) so the cause is lost.

**UI-7 World Radio station focus** — `worldRadioScr.cpp:57-64` `pendingStationFocus(+Revision)`,
`randomOnEntryPending`, `renderedRevision`, `renderedPhoneReady`, `reticlePulsing`.
EntryRandomPending / FocusAwaiting / Idle. Cleared in three functions; a lost reply keeps
focus pending until the next command.

**UI-8 Render scheduler baseline (AMOLED family)** — `mapRenderPolicy.hpp:186-190`
`lastSubmissionMs_`, `pendingForcedReasons_`, `hasRenderedFix_`, `hasSubmittedFix_`,
`hasObservation_`, owned since #772 by `mapSchedulerAmoled.cpp:19` behind the per-family
`map_scheduler` interface (`mapSchedulerFamily.hpp:40-63`). Contained, but the phase is the
product of three bools. The e-paper uses EP-5 instead.

**UI-9 Pinch-out backdrop idle timer** — `mainScr.cpp:586` `idleSinceMs`; `0` doubles
as "not started".

**UI-10 Legacy GPX option flow** — `mainScr.cpp:48` raw `uint8_t gpxAction`;
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
(`map_transfer.cpp:45-69`).
Staging → LegacyReady | OperationPrepared → OperationReady → Installed → Removing → Gone.
Writers: `prepareRoot`/`writeFinalMetadata` (`map_stream_install.cpp:936-1206`),
`promotePreparedOperation` (`map_transfer.cpp:2238`), `selectReadyStreamMap` (`:2571`),
`settleSelectionStreamMaps` (`:2723`), `finalizeOperation` (`:2323`),
`restoreRetainedLibraryVersion` (`:2505`), `pruneObsoleteInstalledMaps` (`:4120`).
Since 2026-11-10 the lifecycle markers are named and read in one place,
`map_root_state.hpp`: a marker counts when its file or its `.bak` copy is a regular file,
never a `.tmp`, and `.library-retained` has no `.bak` (`present`, `:64`). A per-root
view (`Markers`, `:73`) checks each marker at most once, and each reader's
decision is a named predicate: `streamRecoveryCandidate` (stream boot recovery,
`map_stream_install.cpp:505`), `unusableActiveRoot` and `uploadFinished`
(`activeRootExists`, `map_transfer.cpp:5119`; also `readInstalledMap` `:3862` and
pruning), `unsettledLegacyUpload` (settling, legacy `.ready` only),
`discardableLegacyStreamState` (`discardAllUnselectedStreamMaps` `:3579`, legacy
state only) and `pruneKeepsByMarkers`. `test_map_root_state.cpp` compares every predicate
with the expression it replaced over all combinations of marker copies. **Smell:** each
reader still classifies the root for itself; there is no stored root state.
`promotePreparedOperation` has to check `.library-retained` live (`:2269`) because
its loop writes that marker. Consumed and `.library-retained` together is legal only to two
functions.

**MT-2 Activation transaction journal** — the `"phase"` of `.activation-transaction.json`
(stream writer `map_transfer.cpp:933-954`, archive writer
`:2042-2089`) plus `retainedSelection` and `operationID` fields and the file's
existence (`hasInterruptedActivation`, `:3627`). absent / publishing / ready /
ready+retained / committed / damaged / quarantined. Since 2026-11-10 the phase is parsed
once into `root_state::JournalPhase` (`map_root_state.hpp:156`, `:175`) and
written through `journalPhaseName`. The two recovery readers keep different accepted
sets, now named: stream recovery accepts ready and committed (`streamJournalAccepts`,
`map_transfer.cpp:2913`), archive recovery also publishing (`archiveJournalAccepts`,
`:3286`), which matches what each writer emits. Which of `.tmp`/`.bak`/primary is
authoritative is still decided differently in `:2351` and `:2381-2411`.
The file is at once a crash log, a lock and recovery evidence.

**MT-3 Renderer handoff / pending map** — `map_transfer_http.hpp` ~`:190-200`
`pendingMapRoot_`, `SessionId_`, `MapId_`, `OperationID_`, `LibraryCommandID_`,
`RootTaken_`, `pendingRendererAcknowledgement_`, `AutomaticExit_`, `FromLibrary_`.
Idle / OfferedNoAck / AwaitingTake / AwaitingAck → MT-5 or MT-4. Written from the
activation task (`.cpp:2662`) and the library task (`:656`) with different field subsets;
`takeActivatedMapRoot` (`:1977`) has two consumption semantics; a mismatched ack is
silently ignored (`:1994`).

**MT-4 Rollback** — `rollbackKind_` (enum, one axis) + `rollbackSubmitted_`, `Complete_`,
`Succeeded_`, `AutomaticExit_`, `FromLibrary_`, `Session_`, `OperationID_`, `Restored_`.
None / TransferRequested / RuntimeRequested / Submitted / TransferDone (self-clearing) /
RuntimeDone (must be taken by UI, `:2126`). `rollbackSubmitted_` is never reset on
completion; a transfer rollback that `needsReceipt` leaves activation "activating" until
MT-5 runs.

**MT-5 Terminal receipt / operation task** — `terminalOperationID_`, `SessionID_`,
`MapID_`, `AutomaticExit_`, `Failed_`, `CleanupReported_(+AtMs)`, `operationTaskSubmitted_`,
`operationQuery_`, `operationStatus_`. Idle / TerminalPending / Submitted / CleanupFailing
(5 s report throttle) / Done, sharing one worker and one gate with status queries and
commit recovery (`:795-921`). A permanently failing `finalizeOperation` never terminates
and keeps refusing uploads; that is deliberate, since an ambiguous accepted write must not
race a new upload, and the next boot resumes it.

**MT-6 Commit recovery (`CommitRecovery`)** — `identity`, `armed`, `responseCompleted`,
`failures`, `retryAfterMs`, `waiting`, `waitingProgress`, `waitingSinceMs` (`map_transfer_http.hpp:166-178`; constants at
`map_transfer_http.cpp:943-951`);
3 attempts, 5→60 s backoff, 10 min stall. None / GrantedUnarmed / Armed / BackingOff /
DeferredWaiting / Exhausted / BootRestoredArmed. `armed` is set by three paths with
different preconditions; `recoverCommitDisposition` reads a *copy* for the stall decision.

**MT-7 Map-library worker** — `libraryAction_` (free string: refresh/select/remove/auto/
manual/automatic-select/suggest), `librarySubmitted_`, `SelectionStarted_`, `Known_`,
`Automatic_`, `ManualPending_`, `RetryAfterMs_`, `RetryStreak_`, block/coverage pairs,
`RejectedSessions_`, command id/error, `Revision_`. Unknown / Idle / Queued / Submitted /
SelectionStarted / RetryBackoff / WaitingRenderer. "Busy" is computed by four different
predicates (`:262`, `:307`, `:361`, `:407`, `:1557`).

**MT-8 Deferred activation + commit grant** — `deferredActivation_` (pending iff session
non-empty), `pendingCommitGrant_` (0 = none), `activationState_.running`. The grant has no
deadline of its own, but it is held together with `CommitRecovery` (MT-6), which bounds the
accepted work to three attempts with backoff and fails an attempt whose storage progress
stalls for 10 min; recovery then releases the grant. It stays held only while a failed
receipt write leaves an accepted write ambiguous (MT-5) or the device's own renderer has
not acknowledged an activation, which is fail-closed by design: accepted work cannot be
revoked. `releaseCommitGrant` (`:709`) is called from five sites under different conditions.
(The first survey said the grant had no timeout; corrected on 2026-11-09.)

**MT-9 `MapActivationState` status** — `running` + an `ActivationStatus` enum since
2026-11-10 (idle/activating/installed/failed/recovering/prepared,
`map_activation_status.hpp:9`), with one conversion to the wire strings
(`activationStatusName`); `setStatus` keeps the snapshot's string equal to it
(`map_transfer.cpp:1144`, `finish` `:1199`), so the BLE and HTTP status text is
unchanged. "prepared" still exists only to defeat the `AlreadyInstalled` guard
(`map_transfer_http.cpp:1078`, `:2506`); the status arguments at 16 call sites in
`map_transfer_http.cpp` are enum values instead of literals; `activationSnapshot`
(`:1933`) overlays MT-10 on top.

**MT-10 Stream status overlay** — `streamStatusActive_` + `streamInstallState_` snapshot;
cleared by hand in six places; a Paused upload is re-marked active at boot (`:2224`).

**MT-11 Selection anchor two-slot ring** — `/VECTMAP/.selection-anchor-0|1` records
(`map_selection_anchor.hpp`), slot = `newest^1` (`map_transfer.cpp:4963`). None / One /
Two / SameSequenceConflict / ForeignNewer / UnsupportedSchema. Writer (`:4892`) and
reader (`:4987`) duplicate the scan with different foreign-device handling.

**MT-12 Manual-selection intent journal** — `.library-selection-intent.json` presence +
`.library-automatic` content; RAM mirror `libraryManualPending_`, `libraryAutomatic_`.
Reconciliation (`map_transfer.cpp:4097`) is skipped while a select retries, so the intent
can stay pending indefinitely. Since #791 a manual Use refused with
`stream_settle_previous` writes the intent (`map_transfer_http.cpp:558-559`) and
reconciles it away in the same task (`:599-601`), so every refused retry costs two journal
writes.

**MT-13 Previous-map pair in `active-map.json`** — active + `previous*` fields
(`map_transfer.hpp:106-118` `ActiveMapSelection`). None / NoPrevious / WithPrevious /
SameRootRefresh, plus a per-member cleanup sub-state that is never stored: Settled /
SelectedUnsettled / PreviousUnsettled, re-derived from the root's marker files on every
call of `settleSelectionStreamMaps` (`map_transfer.cpp:2712-2768`). Since #791
PreviousUnsettled is a gate: the call returns the literal `stream_settle_previous`
(`:2761`), which refuses an upload with 503 (`map_transfer_http.cpp:1579-1583`) and a Use
of any map outside the pair before the selection has started (`:573-582`). An automatic
selection gets the same code as a transient probe failure and backs off from 30 s to the
300 s cap (`:643`, `:648`, `scheduleLibraryRetry` `:338-344`). Boot resume ignores the code
(`:2335`), so a resumed upload can still push an unsettled previous map out of the
pointer, where its markers become pending work again. "Promote previous" is implemented
three times (`rollbackActiveMap` `map_transfer.cpp:3422`, `recoverActiveSelection`
`:3099`, settle). **Smell:** the gate is a status string compared at two call sites, the
pair's settled-ness is never stored, and a refused manual Use writes and then discards its
intent journal (MT-12).

**MT-14 Stream install file cursor + checkpoint** — `map_stream_install.hpp:150-165`
`currentFd_`, `currentFile_`, `currentSkipped_`, `currentPartPath_`, `nextFileIndex_`,
`bytesAtCheckpoint_`, `checkpointAtMilliseconds_`, `checkpointSequence_`,
`durableFilePrefix` vs `completedFiles`. NoFile / VerifyingSkippedPrefix / WritingPart /
BetweenFiles / CheckpointDue / ResumedFromCheckpoint / ResumedFromReady.
`durableFilePrefix`/`completedFiles` kept in lockstep by hand in five places.

**MT-15 Install-stream request loop** — locals in `handleInstallStream`
(`.cpp:1644-1759`): `remaining`, `lastRead` (10 s idle), `cancelled`, `operationAdmitted`,
`operationAdmissionFailed`, publish throttle. Admission happens inside the progress
callback, so it depends on the 256 KiB / 500 ms throttle firing after the manifest.

**MT-16 `MapSelectionHealth` string state** — unknown/ready/degraded/rolling_back/
rollback_failed (literals in `map_selection_health.hpp:24-33`) with guarded methods, but
compared as strings in the library JSON and the library task
(`map_transfer_http.cpp:364`, `:627`) and set by hand in `observeBootSelection` (`:2075`).

## 5. Transfer, debug, firmware update (`lib/device_transfer`, `lib/device_debug`, `lib/firmware_update`, `lib/firmware_maintenance`)

**TR-1 Transfer session lifecycle (`HttpTransferServer`)** — `device_transfer_http.hpp:149-222`
`enabled_`, `mode_`, `sessionToken_`, `transferGeneration_`, `workerTask_`/`workerStopped_`,
`startedAp_`, `startedStation_`, `hotspotFallback_`, `networkTransport_` (string used as
phase: "", starting, connecting, lan, hotspot), `listenerReady_`, `powerLockHeld_`,
`networkStopFailed_` (sticky), `commitBoundary_.admissionClosed_`. Idle → Enabled →
StationConnecting → LAN|Hotspot → ListenerBound → Serving → Disabling → WorkerParked →
Reclaimed, plus StartupFailed / WorkerCreateFailed / StopPoisoned. `setEnabled` (`:510`),
`runWorker`/`startNetwork` (`:779-1017`), `clearAuthenticatedBleSession` (`:429`),
`process()` (`:757`), `isShutdownQuiescent` (`:1466`, six flags). `enabled_=false` written
in five places; network triple reset in three; generation bumped in six (`:326`, `:423`, `:453`, `:607`, `:660`,
`:1029`);
`networkStopFailed_` has no recovery. Since #797 the emulator-only
`WAVESHARE_AMOLED_175_SIMULATOR` profile (`BICINO_SIMULATOR_MAP_LAN`) pins map mode to the
`Bicino-Sim` network (`:642-645`) and fails with `simulator_lan_unavailable` instead of
falling back to the hotspot (`:875-880`); other profiles are unchanged.

**TR-2 BLE link-loss grace window** — `:195-198` `bleLinkGraceActive_`, `DeadlineMs_`,
`LossMs_` + `authenticatedBleSessionId_`. Unbound / Bound / GraceOpen / Adopted / Expired.
Decisions are pure in `transfer_link_grace_policy.hpp`; the clear-triple is copy-pasted
five times. Has a terminal (45 s cap).

**TR-3 Per-request authorization / commit boundary** — `:214-219` `requestInProgress_`,
`currentRequestAuthorized_`, `currentAuthorizationBits_`, `lastUsefulTrafficMs_`,
`activeClient_`, `commitBoundary_`. NoClient / TlsUp / RequestUnauthorized / Authorized /
InsideGrant / Released × AdmissionClosed. Keep-alive is derived from five inputs
(`:1630-1670`); `lastUsefulTrafficMs_` written from four sites.

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
× `operationDeviceID_` × build flag. `markRunningAppValid` (`:541`, from `main.cpp:1987`),
`rejectRunningApp` (`:570`). A failed receipt persistence on the valid path is ignored
"until next boot" but nothing schedules that retry.

**TR-6 Firmware maintenance mode** — `firmware_maintenance.cpp:12-16` +
`board_startup/amoled.cpp:42-130` (moved out of `main.cpp` by #770). `Stage` is an enum but
`setStage` is unguarded and called from 13 sites across four files
(`device_transfer_http.cpp` 6, `firmware_update_http.cpp` 5, `firmware_maintenance.cpp` 1,
`board_startup/amoled.cpp` 1); the real phase is `retainedRequest` (RTC_NOINIT, consumed
once), `runtimeActive`, `runtimeExitRequested`, `runtimeStartedAtMs`, three loop timers
(auth 2 min, inactivity 90 s, overall 10 min) and `BootButtonExitState`. Failed can be
overwritten by NetworkStarting/Ready later in the same boot. The e-paper family has no
maintenance mode (SYS-10).

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

**TR-9 TLS identity rotation** — `device_transfer_tls.hpp:139-142` `active_`, `pending_`,
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
`respondToStartPrompt` (`:1177`), `beginFirmwareShadow` (`:727`). **Smell:**
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
(`ride_automation_runtime.cpp:1040`) can be stale; boot seeding `snoozeStart(0)` (`:742`) measures the
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

**RA-9 Detailed-capture end-of-ride** — `ride_automation_runtime.cpp:857-895` `retainedLifecycle`,
`workout.stale`, `lastCoreReceivedAtMs`, 5 min grace. Tracking / TelemetryLost / Ended;
judgment frozen at the last frame (documented).

**RA-10 Transport retry counter** — subset of RA-1: `pendingAttempts` 0..4 with
exponential delay; `queueTransportFrame` (`:266`) resets it for PromptResponse frames
while the decision deadline keeps running.

**RA-11 Writer memory-deferral episode** — `ride_diagnostics.cpp:1147-1188` local
`MemoryDeferral{active,startedMs,lowest}`. Clean two-state.

**RA-12 Recovery backoff** — `ride_diagnostics_storage_policy.hpp:79-107` `armed_`,
`waitStartedMs_`, `delayMs_`. Disarmed / Armed / ProbeDue. Clean.

**RA-13 UI error / resumed-message timers** — `ride_automation_runtime.cpp:55-58` `uiError`, `uiErrorUntilMs`
(8 s), `resumedMessageUntilMs` (3 s); cleared on read inside `uiSnapshot` (`:1107`), so
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

**RA-17 GPS displacement window** — `ride_automation_runtime.cpp:76-118` ring +
`gpsWindowSource` guard; a change of source clears the window (`:457-460`). Data window,
not a lifecycle. Since #776 two sources are live on the GNSS variant, so every switch of
POS-4's selector restarts the displacement evidence.

## 7. Main loop, power, board (`src/main.cpp`, `lib/power*`, `lib/display_power`, `lib/storage`, `lib/panel`, `lib/speaker`, `lib/gps`, `lib/waveshare_board`)

**SYS-1 1.75-inch CST9217 touch reader** — `panel/WAVESHARE_AMOLED_175.cpp:294-649`
`touchInitialized`, `touchHintConfigured`, `touchPressed`, `touchBackoffUntilMs`,
`consecutiveTouchReadFailures`, `lastValidTouchMs`, `lastTouchHintActive`,
`touchHintStateKnown`, `primaryTouchId`, `suppressPrimaryTouchUntilRelease`,
`touchInterruptGeneration` / attempted, `touchReadWindow`, `previousRawTouchFrame` (the 1.75
statics at `:626-649`). Uninitialized(5 s retry) / Idle / HintActive / FollowUpWindow /
Pressed / PressedGrace / Backoff / ReinitBackoff / PrimarySuppressed. `readTouch` (`:969`),
`noteTouchReadFailure` (`:903`, four backoff formulas), `releaseAllTouches` (`:751`, seven
call sites), `publishTouchFrame` (`:363`). The 2.06 FT3168 reader (`:385-624`) is a
diverged duplicate; the failure counter wraps after 20 idle failures (`:921-923`); the
backoff deadline is written in five places across the two readers; suppression is set by two
unrelated sources and cleared only by a zero-contact frame. `readTouch` also runs from
`main.cpp:2428` while dimmed, now gated by `board::touch::wakePolling`. The panel file
compiles only for the AMOLED family; since #775 the TCA9554 shadows it used live in
`waveshare_board/tca9554.cpp:12-13` (SYS-11).

**SYS-2 Display inactivity / panel power stack** — `main.cpp:504-507`
`displayInactivityPolicy`, `currentDisplayMode` (copy of the policy's mode), `:856-881`
`static Signals` (~20 baseline fields + two poll sub-timers), `display_power.cpp` manager
flags + policy requested/applied/`pendingPanelChange_`/`fullRefreshRequired_`, `mainTimer`
paused/period (`main.cpp:1039-1049`), `waitScreenRefresh` (`tft.cpp:18`). Effective state
is the tuple (policy mode, `currentDisplayMode`, requested, applied, timer paused, LVGL
cadence) ≈ Active / Dimmed / Off / Transfer / DeferredNotice. The stack is now compiled for
every board. **Smell:** `showShutdownDeferredNotice` (`main.cpp:534`) still writes
`currentDisplayMode = Dimmed` directly (`:546-551`), bypassing the policy, now only where
`board::display::brightness` holds; activity detection is a hand-rolled diff of ~20 fields;
the `initializePanel` fallback (`display_power.cpp:291-297`) powers the panel without
`markPanelInitialized`, after which every panel change is a silent no-op. On the e-paper the
manager's panel paths are stubs (`display_power.cpp:76-78`, `:117-119`, `:242-244`,
`:265-266`, `:302-304`), `automaticDisplayOffEnabled()` is false so the inactivity policy
only reaches Active or Transfer, the deferred notice's requested Dimmed state is recorded but
never applied, and the panel's real power state is `epaper::PresentationPolicy` (EP-1),
which neither `currentDisplayMode` nor `display_power::State` sees.

**SYS-3 Storage mount / pin / degrade / shutdown** — `storage.hpp:132-161` `isSdLoaded`,
`internalFallbackMounted`, `backendPinned_`, `mapStorageAvailable_`, `mountedBackend`,
`diagnosticsSdHealthy`, `lastDiagnosticsMountResult`, `shutdownAdmissionClosed_/Started_/
Complete_`, `waveshareMigrationBusBegun` (`.cpp:119`), `mountGeneration_` (declared at
`:152`, never incremented). Unmounted → RemovableMounted | FFatMounted | Unavailable →
Pinned → Degraded (one-way, `:239-262`); diagnostics Healthy/Unhealthy; shutdown
AdmissionClosed → TaskStarted → Complete. `storageBackend()` (`:272`) derives the backend
from three atomics so after a degrade `mapStorageRoot()` still points at `/sdcard` while
`getSdLoaded()` is false; a failed `xTaskCreate` after `shutdownStarted_` leaves
`shutdownComplete_` false forever. Since #442 the legacy SPI migration is skipped on boards
without a legacy chip select (`storage.cpp:122-125`, `:516-519`).

**SYS-4 BOOT button press/release + pairing arming** — `main.cpp:170-179` ISR latch
`waveshareBootScreenCyclePending`, `WaitingForRelease`, `HandledPairingConfirmation`,
`ReleaseStartMs`, `PressStartMs`, `waveshareBootPairingGate`,
`wavesharePowerPairingGate/Generation`. Idle → Pressed → ReleaseDebouncing(50 ms) → Idle ×
pairing gate Armed(gen)/Cancelled. The press edge decides confirm-vs-cycle (`:227-250`) and
the release decides long-press forget-owner (`:268-279`).
`armOwnershipPairingAfterRenderedComparison` (`:312-338`) resets all five after each
rendered comparison and, since #770, discards stale input through the family hook
`board::startup::discardStalePairingInput()` (`:327`): PMIC events on AMOLED, a
fresh-release requirement on the e-paper side keys. On the e-paper the BOOT gate is also
re-armed on every pass while a code exists but is not on glass (`main.cpp:213-215` via
`board_startup/epaper.cpp:75-77`), and the power gate is armed but never fed, since that
board has no PWR-key events (`:79-81`). Reset exists in two places,
`HandledPairingConfirmation` is assigned twice back-to-back (`main.cpp:233`, `:236`), and one
gesture can fire both the press and release actions.

**SYS-5 Pending map renderer activation + label rollback** — `main.cpp:360-389`
`pendingMapRendererActivation{source, rendererQueued, queueAttemptStartedMs}`,
`rendererMapDiagnosticIdentity`; function-local statics `labelRuntimeFailure`,
`labelRollbackQueued` (`:2178`). None → PendingUnqueued(≤10 s retry) → Queued → None;
Idle → FailureCaptured → RollbackQueued. A non-matching renderer result still clears the
pending record and sends a failure ack (`:2160`); the identity is rewritten in four places.

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
`main.cpp:512` `shutdownDeferredNoticeShown`, composite drain callback (`:1431-1458`).
Beyond the explicit Barrier: DeferredStillDraining (`:165`, `:190`) and NoticeShown
(terminal for the UI). Progress watchdog folds four counters into one `uint64`.

**SYS-9 GPS one-shot time/fix flags** — `gps.cpp:16-18` `setTime` is initialised `true`
and only ever assigned `true` again (`:118`), so the "set system time from GPS once"
block (`:110`) can never run; `isTimeFixed` is never written. Still vestigial, but since
#776 it ignores a real input: the 1.75 GNSS variant feeds receiver dates and times into
`getGPSData` (`gnss_receiver.cpp:707-708`), yet the device sets no clock and computes no
sunrise or sunset from them; only phone GPS packets sync the RTC
(`ble_navigation.cpp:5863-5876`). `isGpsFixed` (`gps.cpp:17`) is the GNSS-only fix
indicator, written at `gps.cpp:95`, `:99` and `gnss_receiver.cpp:712`; phone positions
never set it. The ride-source hysteresis formerly noted here is now a live two-source
selector (POS-4).

**SYS-10 Boot-mode trichotomy** — SafeMode / Maintenance / Normal are not a variable. They
are early `return`s in `setup()` (`main.cpp:1520-1525` safe mode; `:1579-1581` maintenance
through `board::startup::beginFirmwareMaintenance()`) and the `if … return` chain at the top
of `loop()` (`:2015-2025`). Since #770 maintenance is a family hook: the AMOLED body
(`board_startup/amoled.cpp:42-130`, `:153-174`) still carries the 750 ms RebootPending timer
(`:166-172`) outside `firmware_maintenance`, while the e-paper hook returns false for both
calls (`board_startup/epaper.cpp:48-50`) and BLE refuses the request with
`firmware_maintenance_unsupported` (`ble_navigation.cpp:4604-4607`), so that board has only
two of the three modes. The safe-mode branch, formerly AMOLED-only, is now compiled for every
board.

**SYS-11 Small ones** — AXP2101 `pmuAvailable` (`axp2101.cpp:30`) re-probes three times on
every battery read while absent, with no backoff; on the e-paper it also requires identity
0x4A (`:65-73`). I2C `busConfigured` recover loop (`i2c_bus.cpp:43`, `:113-150`); on the GNSS
variant the bus-lock wait and Wire timeout rise from 50 to 150 ms and the Wire buffer to
1024 bytes (`i2c_bus.hpp:115-119`), so other bus users such as touch can now wait that long.
TCA9554 output/config shadows (`tca9554.cpp:12-13`), moved out of the 1.75 panel driver by
#775 and shared with the GNSS reset under one mutex: they start at the power-on image, are
updated before each write and never read back, so a failed write or an expander reset leaves
shadow and pins disagreeing until the next successful write. PCF85063
`present/timeValid/source`; QMI8658 `present/configured/dataValid` with `resetMotionWindow`
in three places; SHTC3 `present/identified/dataValid` + `lastAttemptMs` (`shtc3.cpp:16-17`,
`WAVESHARE_SHTC3_DIAGNOSTICS` builds only) identifies once in `begin()` and never retries;
battery read cache; ordinary renderer-diagnostics session (`main.cpp:501-502`,
`:2344-2394`) with `endSession` from four sites; `processTransferInactivityTimeout` 1 s poll
gate.


## 8. Position source (`lib/position_source`, `lib/gps`)

Added by the board-support M5/M6 work (#775, #776) and tuned by #784 and #785. Only the
1.75-inch GNSS variant (`board/boards/waveshare_amoled_175_gnss.hpp`) fits a receiver;
every other profile keeps the phone as the only position source.

**POS-1 Position-source arbiter (ownership of the shared position record)** —
`position_source_policy.hpp:17-50` `Arbiter` (`gnssFitted`, `gnssFixSeen`, `gnssFixValid`,
`lastGnssFixMs`, `phoneSeen`, `lastPhoneMs`; 3 s GNSS hold, 5 s phone hold) behind one
`portMUX` (`position_source.cpp:11-48`). The explicit `Source` enum is derived per query
(`active()`, `position_source.cpp:32-38`) and never stored. PhoneOnlyBoard / NoFix (phone
owns) / GnssHolds (valid fix under 3 s old) / HoldLapsed (phone owns again) / None (no
input within 5 s). Moved by `noteGnssFix` for every parsed interval
(`gnss_receiver.cpp:306`), `acceptsPhonePosition` per phone packet
(`ble_navigation.cpp:5853-5854`) and `notePhonePosition` only for packets that were applied
(`:5881-5882`). **Smell:** the hold expires lazily inside `gnssHolds()`; one invalid
interval drops the hold at once while an older valid fix may still be pending (POS-3);
`lastPhoneMs` counts only accepted packets, so after a GNSS hold `active()` (and the `DSTS`
`active` field) reports `none` until the next phone packet applies, although the phone
never stopped; hold times are stamped at drain time, so a backlog drained in one I2C burst
counts as fresh; `gnssFixSeen` is redundant (`gnssFixValid` cannot be true without it).
Host-tested (`test_position_source_policy.cpp`).

**POS-2 GNSS receiver reader (I2C poll, restart, probe latches)** —
`gnss_receiver.cpp:26` `GnssStatus state` (`portOpen`, `probeLocked`, `fixValid`,
`resetPulses`, counters) + latches `probeReported` (`:28`), `firstBytesReported` (`:31`),
`fixReported`/`lastFixLogMs` (`:81-82`), `lastStatusMs` (`:86`); `I2cTransport`
(`:411-597`) with `sawValidSentence` (`:429`) and `I2cReceiverPolicy`
(`position_source_policy.hpp:180-247`: `progressBytes`, `progressMs`,
`pollsSinceProgress`, `silentWindowMs`, `consecutiveFailures`). Fitted → FreshStart (RESET
pulse in `begin`, `gnss_receiver.cpp:510-520`) → Pending → Locked (first checksum-valid
sentence, one-way) × Streaming / Busy (answered before, now refusing: re-poll at once) /
Absent (2 s polls) / AbsentSlow (30 s after 5 misses) / Silent (no new byte for at least
three polls and the window) → Restart (pulse; the window doubles from 15 s to 300 s,
`:589-593`). "Present" is `state.portOpen`, rewritten after every poll (`:582`) and
edge-logged against the previous value (`:585-586`). **Smell:** `probeLocked` and
`probeReported` never clear, so after a restart or a later silence the status still says
locked and `printBoot` prints `ok`; `fixValid` is the last parsed interval and never
expires when the stream stops; `portOpen` means "port opened" on UART but "answered the
latest poll" on I2C; the per-step refusal counters (`:437-462`) also book bus-lock
timeouts as NACKs; one exchange can retry for seconds (up to 20 request rounds of 10
writes and 5 reads, 20 ms apart); the reader has no stop or pause path (only
`main.cpp:1418` begin and `:1907` start). The UART transport
(`gnss_receiver.cpp:340-391`: `BaudProbe`, `validSinceSwitch`, `bytesAtRoundStart`, the
three-pulse cap `kMaxResetPulses` at `:80`) is compiled only for transport `uart`, which no
board selects.

**POS-3 GNSS fix handoff mailbox + fix indicator** — `gnss_receiver.cpp:271-274`
`pendingFix`, `pendingSatellites`, `pendingFixReady` under `handoffMux`; filled
latest-wins by `drainFixes` on the reader task with valid fixes only (`:278-305`); taken
by `applyPendingFix` on the main loop (`:692-715`, from `main.cpp:2328` right after
`bleNavServer.process()`), which copies into the `fix` global and runs `getGPSData`
(`gps.cpp:78-189`). Empty / Pending / Applied; `isGpsFixed` is cleared only on a tick with
nothing pending and a non-valid last interval (`gnss_receiver.cpp:709-713`). **Smell:**
the apply ignores the arbiter, and phone packets are applied first in the same tick, so
under burst delivery a valid fix drained just before an invalid interval overwrites a
newer phone position for one tick; when the stream stops after a valid fix, `isGpsFixed`
stays true indefinitely, so the status bar (`notifyBar.cpp:114`) shows a fix while the
phone owns the record; `printBoot` reads the main-loop-owned `fix.status` from the reader
task; the applied fix's freshness (`presentationSample`, `gps.cpp:89`, and the ride
observation) is stamped at apply time, not fix time.

**POS-4 Ride-automation position-source selector (now two live sources)** —
`gps.cpp:21-24` `hardwareRideObservation`, `authenticatedBleRideObservation`, sticky
`selectedRidePositionSource` under one mux; `selectGpsRideObservation`
(`gps_ride_observation.hpp:57-96`: validity → fix quality → accuracy with a 3 m switch
hysteresis → newer capture). The explicit `RidePositionSource` (`gps_ride_observation.hpp:6-10`)
is stored only as the hysteresis memory, written by the reader `currentGpsRideObservation`
(`gps.cpp:216-229`) and cleared by `clearAuthenticatedBleGpsRideObservation`
(`gps.cpp:208-214`, eight call sites in `ble_navigation.cpp`). Before #776 the hardware
observation was never published; on the GNSS variant every applied valid fix publishes it
(`gps.cpp:188`) and it is never cleared, only aged out. **Smell:** a query mutates the
preference, and ride automation queries a second time with `UINT32_MAX` age when the first
finds nothing (`ride_automation_runtime.cpp:818-822`), so a stale observation can set the
sticky source; this selector and POS-1 can pick different sources at the same moment, and
each switch here clears RA-17's window.


## 9. E-paper display and board families (`lib/epaper_display`, `lib/board_input`, `lib/board_startup`, e-paper GUI)

Added by the Waveshare 3.97-inch e-paper board (#442) and the board-family split (#770,
#772, #792). The e-paper defaults are experimental and excluded from release and factory
profiles (`epaper_policy.hpp:6`). The board creates no LVGL input device (the only
`lv_indev_create` is in the AMOLED panel driver, `WAVESHARE_AMOLED_175.cpp:1311`), so the
touch-driven machines UI-1, UI-9, UI-11, MAP-9 and MAP-10 are unreachable there.

**EP-1 E-paper presentation worker and refresh policy** — `epaper_policy.hpp:89-94`
`history_`, `busy_`, `fault_`, `sleeping_`, `lastFull_`, `baseReason_`, `failures_`,
`partials_`, `startedAt_`, `finishedAt_`; `epaper_display.cpp:35-36` `urgent`,
`sleepRequested`, `wakeRequested`; worker-local `wakeForChangedContent` (`:134`); `Status`
mirror `busy`/`fault`/`sleeping` (`epaper_display.hpp:27`). NoHistory(Startup | Wake |
Recovery) → Busy → History(n partials) → CleaningDue (n ≥ 160) → IdleSleep after 60 s (wakes
for changed pixels) | ExplicitSleep (wakes only on request) → Fault (latched on the second
consecutive failure). Worker loop `epaper_display.cpp:139-303`; policy transitions
`epaper_policy.hpp:59-82`; requests `sleep()`/`wake()` (`epaper_display.cpp:389-400`).
**Smell:** the explicit `RefreshReason` is derived from `history_`/`baseReason_`/`partials_`
(`epaper_policy.hpp:46-49`); the snapshot repeats `busy`, `fault` and `sleeping` and writes
each at three sites (`epaper_display.cpp:172`, `:204`, `:246`; `:136`, `:157`, `:247`;
`:157`, `:190`, `:214`); explicit versus idle sleep is a worker-local bool that neither the
policy nor the status sees; `sleepFailed()` (`epaper_policy.hpp:78`) reuses the
waveform-finished stamp as the 60 s sleep retry timer. The fault latch clears only in
`wake()`, and `epaper::sleep()`/`wake()` are called only from the `EPAPER_DISPLAY_TEST`
branch (`board_input.cpp:33-41`), so in ordinary builds a latched fault lasts until reboot
and the status line reads "Display fault - reconnect power" (`epaper_ui.cpp:224`). The
status is published in the transfer status JSON (`ble_navigation.cpp:3536-3549`) but has no
reader in `ios-app/`. Host-tested (`tools/tests/test_epaper_display.cpp`).

**EP-2 Frame mailbox and semantic-context revocation** — `frame_mailbox.hpp:57-60`
desired/flight/shown buffers, `generation_`, `pairing_`, `context_`, `provenance_`,
`writing_`, `pending_`, `inFlight_`; `epaper_display.cpp:37-38` atomics `currentPairing`,
`currentContext`; `:41` `contextCompositionPending`. Idle → Writing → Pending(gen) →
InFlight → Shown | Discarded; a publish during flight gives Pending+InFlight, and a second
publish replaces Pending (latest wins). The worker discards a claimed frame whose pairing or
context is no longer current (`:202-206`). `invalidateContext()` (`:366-375`) bumps the
context from eight sites (`epaper_ui.cpp:82`, `:179`, `:189`, `mapSchedulerEpaper.cpp:285`,
and inside `setPairingGeneration`, `sleep`, `wake` and `diagnosticPattern` in
`epaper_display.cpp`). The successor composition is a separate edge flag drained by `poll()`
on the UI task (`epaper_display.cpp:419-423`); `urgent` is a third channel, set by
`prioritize()` from ten sites, eight of them in the GUI, and by `wake()`. **Smell:** three
bools for one slot (contained and host-tested); whether a change is hard is decided at each
call site, separately from the navigation scheduler's `kHardReasonMask`
(`epaperNavigationPolicy.hpp:36-38`), and both classify route-session changes; a
screen-instance change bumps the context twice (`mainScr.cpp:2895` through
`screenInstanceChanged`, then `epaper_ui.cpp:177-179` on the next pass).

**EP-3 Pairing comparison on glass** — the BLE side requests the gate and sets the display
pairing generation (`ble_navigation.cpp:1054-1056`, `:1062-1064`). The display tags a frame
only if the waiting screen shows the comparison when it is packed
(`epaper_display.cpp:327`), attests presentation only when pairing and context are still
current (`:256-257`) and clears the attestation on explicit sleep, failure and `sleep()`
(`:191`, `:283`, `:392`). `pairingPresented()` (`:380-388`) requires not busy, no fault, a
pairing match and a context match. `poll()` forwards completion (`:468-469`) to
`ComparisonRenderGate::displayGenerationCompleted`, and the loop's
`armOwnershipPairingAfterRenderedComparison` (`main.cpp:312-338`) arms `DeviceOwnership`.
NoCode → CodeRequested(gen, context bumped) → TaggedFrameQueued → InFlight → OnGlass(gen) →
Armed (gate consumed) → Confirmed | CancelledOnDevice | Expired. OnGlass is withdrawn whenever
a later frame is in flight, the context changes or a waveform fails. **Smell:** "on glass" is
recomputed from five fields per read and read independently in four places: the side-key
re-block (`board_input.cpp:25-28`), the BOOT gate re-arm (`board_startup/epaper.cpp:75-77`),
the confirm guard (`ble_navigation.cpp:8626`) and the `poll()` notification. Because `busy`
counts, any frame in flight during pairing withdraws visibility and forces fresh releases on
every key. The AMOLED family feeds the same gate synchronously from a flush
(`main.cpp:182-186`), so one gate class carries two meanings.

**EP-4 Side keys and context menu** — per key `button_policy.hpp:41-42` `raw_`, `stable_`,
`held_`, `blocked_`, `changedAt_`, `pressedAt_`, `repeatedAt_`, `releasedAt_` (0 = no release
yet); `board_input.cpp:12-13` three `Button`s + `pairingWasVisible`; `epaper_ui.cpp:18-21`
`menu` (LVGL hidden flag), `controls` group, `inControls`, `selected`. Per key: Blocked
(until 40 ms of stable release; every key starts blocked) → Debouncing(40 ms) → Pressed →
Held(700 ms, Hold) → Repeating(250 ms, menu only) → Press emitted on release only when not
held (`button_policy.hpp:11-39`). Menu: Closed / Actions(selected) / ScreenControls(focus).
`contextOpen()` (`epaper_ui.cpp:86`) combines two sources; `closeContext()` (`:87-91`) is
called from seven sites, including every loop pass during pairing (`board_input.cpp:43`).
**Smell:** keys are re-blocked from three places (`board_input.cpp:21`, `:27`,
`board_startup/epaper.cpp:84`); the menu state is split between a bool and an LVGL flag; the
only LVGL input on this board is the synthetic `LV_EVENT_CLICKED` that `activate()` sends to
a focused control (`epaper_ui.cpp:130-134`).

**EP-5 E-paper navigation scheduler, heading filter and disposition ledger (e-paper
counterpart of UI-8)** — `mapSchedulerEpaper.cpp:25-28` scheduler, filter, ledger,
`epaperArmedRenderReasons`; `epaperNavigationPolicy.hpp:139-143` filter `x_/y_`,
`lastCapturedAtMs_` (0 = none), `initialized_`, `courseDriven_` (hold below 4 km/h, resume
above 6 km/h); `:292-298` scheduler `latestFix_`, `latestSubmittedFix_`, `publishedFix_`,
`lastSubmissionMs_` (0 = never; `markSubmitted` stores 1 for 0, `:273`), `lastPublishedMs_`,
`forcedReasons_`, `hasFix_`; `:383-384` ledger `pendingSequence_`, `terminalSequence_`.
Scheduler: Idle → Armed(reasons) → Submitted → Published, with a 1 s base cadence and
successor-pending suppression (`:253-264`). Heading: Uninitialized → Held ↔ CourseDriven.
Per fix sequence: Pending → Foreground | Base | Coalesced. **Smell:** a non-zero armed mask
suppresses `evaluate` entirely (`mapSchedulerEpaper.cpp:191`); it clears only on a submit or
a synchronous render (`:235`, `:244`, `:249`), not in `markInterrupted` (`:252-256`), and
relies on `isPosMoved` to resubmit; the heading filter is never reset (no caller of
`reset()`), so a held heading survives disconnects and route changes;
`latestSubmittedFix_`, `publishedFix_` and `lastPublishedMs_` are written but never read in
firmware; `DispositionLedger::ignore()` and four of the eight `Disposition` values (Invalid,
Stale, Deadband, Incompatible) occur only in the host test. Host-tested
(`test_epaper_navigation_policy.cpp`).

---

## Cross-cutting patterns

1. **Generation counters as revocation.** `transferGeneration_` (TR-1, bumped in six
   places), `captureGeneration` (RA-4), `nearbySearchGeneration` (MAP-12),
   `diagnosticsSessionStartGeneration` (BLE-8), `pairingGeneration_` (BLE-4),
   `faultCapsuleGeneration` (RA-5), `cancellationGeneration` (MAP-3), the
   e-paper frame `pairing`/`context` tags (EP-2, EP-3). The phase is
   "my generation == current generation"; staleness is only discoverable by comparison
   at the consumer, never by a state name.
2. **Copy-pasted reset sequences.** BLE session clear (5×), grace clear (5×),
   `enabled_=false` (5×), ride-automation decision clear (8×), `readyRenderResultValid=false`
   (11×), `resetUploadState` (15×), nearby view reset (3×), e-paper `closeContext()` (7×),
   and MAP-4's three frame resets, whose subsets diverged further with #442. Every one is a place where a
   future field is forgotten.
3. **Strings as phases.** `status_` in OTA (TR-4), `networkTransport_` (TR-1),
   `libraryAction_` (MT-7), `MapSelectionHealth.state` (MT-16), `pendingAuthNonce`
   non-emptiness (BLE-6/7), the `stream_settle_previous` gate code (MT-13). The activation
   status (MT-9) and the journal phase (MT-2) became enums on 2026-11-10; only their wire
   form is a string.
4. **Lazy expiry on read.** Suppression windows (RA-2), lease expiry (BLE-6), UI error
   timers (RA-13), prediction phases (MAP-5), station state (TR-7), the e-paper "comparison on glass"
   (EP-3, recomputed from five fields per read), position-source holds
   (POS-1), the ride selector's sticky source written by a getter (POS-4). A getter
   changes the answer depending on when it is called, and persistence can snapshot a stale
   value. The reverse also appears: last-event values reported as current with no expiry
   (`GnssStatus.fixValid`, `probeLocked`, `isGpsFixed`; POS-2, POS-3).
5. **Mailbox pairs** (`payload` + `valid`): activation (MAP-2), render request/result
   (MAP-3), nearby (MAP-12), map input (BLE-15), fault capsule (RA-5), pending map root
   (MT-3), GNSS fix handoff (POS-3, applied without consulting the arbiter), the
   e-paper `FrameMailbox` and `contextCompositionPending` (EP-2), MAP-3's `framePublication_`
   + flag. Several lack a timeout on the "produced but never consumed" state.
6. **Explicit enum shadowed or derived.** `LatestWins::State` (MAP-3), `Transaction`
   (TR-4), `PointerState` (TR-13), `DetectorPhase`/`UiPhase` (RA-2, recomputed every
   tick), `maintenance::Stage` (TR-6, unguarded from 17 sites), `MapStreamInstallState`
   (6 mutation sites inside one class), `display_inactivity::Mode` (derived),
   `position_source::Source` (POS-1, derived per query), `RidePositionSource` (POS-4, a
   sticky preference written by a getter), `epaper::RefreshReason` (EP-1) and
   `epaper_navigation_policy::Visibility` (EP-5), both derived per call.
7. **Persisted state that can disagree with RAM.** Marker files vs HTTP server fields
   (MT-1/3), journal vs activation state (MT-2/9), selection intent vs `libraryAutomatic_`
   (MT-12), TLS slot selector vs `pending_` (TR-9), suppression in NVS (RA-2), RTC
   capsules (RA-5, sleep audit), and the believed-not-read TCA9554 output shadows (SYS-11).
8. **One family hook, two phase meanings.** Since the board-family split the same name
   carries different phases per family: `ComparisonRenderGate` takes a flush on AMOLED and
   a waveform on the e-paper (BLE-5, EP-3); `markFramePublished` means render completion on
   AMOLED and publication provenance on the e-paper (MAP-3); display power is the manager
   on AMOLED and stubs plus `PresentationPolicy` on the e-paper (SYS-2, EP-1); the
   disconnected-shutdown countdown and maintenance mode do not exist on the e-paper
   (BLE-16, SYS-10).

## Where an explicit machine would pay off most

Ranked by blast radius and by how many of the smells above a single enum would remove:

1. **MT-1 + MT-2 + MT-9** map-root marker files, journal phase string and activation
   status. Partly done on 2026-11-10: marker names, the `.bak` rule and each reader's
   decision live in `map_root_state.hpp`, and the journal phase and activation status are
   enums with one wire conversion. Still open: one stored root state instead of per-reader
   predicates, which would also absorb MT-13's `stream_settle_previous` gate.
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
9. **POS-1 + POS-2 + POS-3** position source: one expiring owner of fix validity, from
   which `isGpsFixed` and the reported `fixValid` derive. Phone packets are already gated
   only on their position fields (X-12 a in the app document). Small blast radius: only the
   GNSS 1.75 variant fits a receiver.
10. **EP-3** comparison on glass: one stored value owned by the display worker, published
    with its pairing generation, so the BOOT gate, side keys and confirm guard read one
    value. Experimental board.
11. **EP-1** e-paper presentation: make explicit sleep a policy state and give the fault
    latch an ordinary recovery path instead of a reboot. Experimental board.

Dead or vestigial state worth deleting outright: GPS `setTime`/`isTimeFixed` (SYS-9),
speaker PWR-honk retry (SYS-7), `mountGeneration_` (SYS-3), pinch zoom-out backdrop
fields (MAP-9), legacy GPX option flow (UI-10). The GNSS work adds unreachable code of
its own: the UART receiver transport with `BaudProbe`, `probeLines` and
`kMaxResetPulses` (POS-2; no profile selects UART), and the redundant
`Arbiter::gnssFixSeen` (POS-1). #775 deleted the never-built legacy UART GPS path
(`Gps::init`, `autoBaud`, `gpsTask`, the GPS baud and rate settings). The e-paper work adds
write-only scheduler fields (`latestSubmittedFix_`, `publishedFix_`, `lastPublishedMs_`),
a test-only `DispositionLedger::ignore()` with four test-only `Disposition` values and an
uncalled `HeadingFilter::reset()` (EP-5). Per family: on the e-paper
`wavesharePowerPairingGate` is armed but never fed (SYS-4), MAP-14 is unused, the
`DisplayPowerManager` panel paths are stubs and explicit `epaper::sleep()`/`wake()` exist
only in diagnostic builds (EP-1); on AMOLED `cameraHeadingDegrees_/Valid_` are never set
(only `mapSchedulerEpaper.cpp:173` sets them).

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
`mapFontAssetFormat::State`, `position_source::NmeaLineValidator`);
`position_source::BaudProbe` (clean but unreachable, POS-2);
`epaper_navigation_policy::DispositionLedger` and its `Disposition` outcome (guarded,
single owner, four values unused; EP-5).

Explicit but shadowed, derived or unguarded (also counted above): `Transaction`/
`TransactionStage` (TR-4), `firmware_maintenance::Stage` (TR-6), `DispatchState` (TR-8),
`PointerState` (TR-13), `StationState` (TR-7, derived), `MapStreamInstallState` (six
mutation sites), `RollbackKind` (MT-4, one axis), `DetectorPhase` / `MotionEvidenceState` /
`DetectionHealthState` / `UiPhase` (RA-2, derived per tick), `display_power::State`
(requested from five sites), `display_inactivity::Mode` (derived), `PlaybackState`
(RA-16, locally pre-seeded), `runtime_watchdog::Phase` (reporting record),
`position_source::Source` (POS-1, derived per query), `RidePositionSource` (POS-4,
sticky preference written by a getter), `epaper::RefreshReason` (EP-1, derived),
`epaper_navigation_policy::Visibility` (EP-5, recomputed per call), `board_input::Event`
(output of EP-4's per-key machine).

Value, result and classification enums with no transitions: `DestinationPickerStatusCode`,
`AdvertisingMode`, `NetworkStartStep`, `TransferTlsFailureStage`, `LanSessionMode`,
`ResourcePhase`, `CaptureMode`, `StartMode`, `MemoryObservationPhase`,
`DeliveryCallbackPhase`, `power_metrics::DisplayState`, `i2c::TransactionPhase`,
`Cst9217DecodeStatus`, `map_projection::Mode`, `RotationMode`, `MetricLayoutMode`,
`navigation_content_mode::Mode`, `StatusMutation`, `ScreenState` (pure `status()`),
`pre_connection_presentation::Phase` (pure `resolve()`), `I2cPollOutcome` (#785, replaced
an answered/partial bool pair), `NmeaLineValidator::Event`, `I2cTransport::Step`,
`SentenceType`, `board::GnssModule`, `board::GnssTransport`,
`epaper_navigation_policy::Reason` (bitmask), `pre_connection_presentation::ConfirmInput`
(compile-time).
