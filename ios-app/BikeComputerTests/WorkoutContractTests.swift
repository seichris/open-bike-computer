import Foundation
#if WORKOUT_CONTRACT_HOST
import Darwin
#endif
#if WORKOUT_CONTRACT_XCTEST
import XCTest
#endif

private nonisolated func roundTripWorkoutEnvelope(
    _ envelope: WorkoutEnvelopeV1
) throws -> WorkoutEnvelopeV1 {
    try WorkoutContractCodec.decode(WorkoutContractCodec.encode(envelope))
}

private nonisolated final class ControllableRecoveryPersistence: WorkoutRecoveryPersistence {
    enum Failure: Error {
        case requested
    }

    var data: Data?
    var takeoverJournalData: Data?
    var failsLoad = false
    var failsSave = false
    var failsClear = false

    func load() throws -> Data? {
        if failsLoad { throw Failure.requested }
        return data
    }

    func save(_ data: Data) throws {
        if failsSave { throw Failure.requested }
        self.data = data
    }

    func clear() throws {
        if failsClear { throw Failure.requested }
        data = nil
    }

    func loadTakeoverJournal() throws -> Data? {
        takeoverJournalData
    }

    func saveTakeoverJournal(_ data: Data) throws {
        takeoverJournalData = data
    }

    func clearTakeoverJournal() throws {
        takeoverJournalData = nil
    }
}

private struct WorkoutContractTestSuite {
    private(set) var failureCount = 0

    mutating func run() async {
        testRideAutomationGoldenVectorAndValidation()
#if WORKOUT_CONTRACT_HOST
        testRideDetectionSettingsAdoptOnlyNewerDeviceState()
#endif
        testRideAutomationAdmissionAndOriginContract()
        testSnapshotRoundTrip()
        testSegmentRoundTripValidationAndAccumulation()
        testTerminalOutcomeRoundTripAndValidation()
        testAllMessageKindsRoundTrip()
        testCompatibleMinorVersionIgnoresUnknownFields()
        testUnsupportedMajorVersionIsRejected()
        testOptionalMetricsRemainUnavailable()
        testWorkoutDevicePairGenerationStamp()
        testInvalidEnvelopeIdentityIsRejected()
        testInvalidNumbersAndCoordinatesAreRejected()
        testMetricUnitsAndAvailabilityMustMatchPayload()
        testActiveSnapshotsRequireTrustworthyStartDates()
        testHeartRateMustBePositiveWithoutRejectingMeaningfulZeroes()
        testSpeedRequiresSource()
        testCyclingDistanceRequiresSource()
        testComponentTimestampsStayWithinWorkoutWindow()
        testHeartRateZonePayloadIsCoherent()
        testHeartRateZoneProfileAndPersistence()
        testHeartRateZoneBreakdownPresentation()
        testHeartRateZoneDurationAccumulator()
#if WORKOUT_CONTRACT_HOST
        testWorkoutMetricsStoreUsesAuthoritativeCoalescedZoneTotals()
#endif
        testAltitudeRequiresVerticalAccuracy()
        testUnknownErrorCodesBecomeSafeGenericCodes()
        testSequenceGateRejectsDuplicatesAndOlderSnapshots()
        testSessionIdentityCannotDrift()
        testSameSessionCanAdvanceToNewTransportGeneration()
        testSameSessionLifecycleRejectsRegressions()
        testBatchPublishesOnlyLatestCoherentSnapshot()
        testBatchSkipsInvalidItemsAndContinues()
        testOlderSessionCannotReplaceNewerActiveSession()
        testActiveSessionReplacesIdlePlaceholderRegardlessOfDeliveryOrder()
        testActiveSessionReplacesFailedAttemptRegardlessOfDeliveryOrder()
        testEndedSessionReplacesOnlyOlderPlaceholders()
        testNewerTerminalSessionReplacesOlderTerminalSession()
        testWatchLifecycleRequiresHealthKitConfirmationAndFinalizesOnce()
        testWorkoutLifecycleFailureAndLateRunningPolicies()
        await testWorkoutFinalizationOrchestratorOrderAndFailures()
        testWorkoutFinishAndRecoveryPolicies()
        testMetricPrecedenceDoesNotCombineOrInventSources()
        testInstantaneousMetricFreshnessAndSpeedFallback()
        testBuilderElapsedTimeUsesHealthKitPauseClock()
        testRoutePointFilteringHonorsWorkoutAndAccuracyBounds()
        testRouteTimestampGateRejectsDelayedPausedBatches()
        testRouteSegmentAndQueueBounds()
        testRouteRecoveryDistanceAndAssociatedFinalizationPolicies()
        testRecoverySequenceLeasesNeverReuseReservedValues()
        testRecoveryStorePersistsIdentityAndLeases()
        testTerminalErrorUpdatePreservesFinishRequestAndSurvivesRecovery()
#if WORKOUT_CONTRACT_HOST
        testRecoveryStoreSurvivesProcessRelaunch()
#endif
        testMirrorReducerSupportsBothStartDirections()
        testMirrorReducerStartTimeoutIsAttemptScoped()
        testMirrorReducerDelayedBatchesCannotRollBackState()
        testMirrorReducerRejectsFutureCaptureBeforeStateOrdering()
        testMirrorReducerDisconnectAndStalenessStayHonest()
        testMirrorReducerNativeStateConfirmationBeatsOlderData()
        testMirrorReducerAcknowledgesRemoteControls()
        testMirrorReducerReplacesTerminalSessionCleanly()
        testMirrorReducerWaitsForFinalSnapshotBeforeReset()
        testTerminalResetRetiresOldSessionWithoutRetainingWallClockOrder()
        testMirrorReducerLateNativeConfirmationClearsCommandError()
        testMirrorReducerDoesNotTurnFailedStartIntoFinishedRide()
        testControlSequencerSurvivesPhoneProcessRestart()
        testRemoteControlGateRejectsFutureSenderWithoutPoisoningRelaunch()
        testIPhoneFallbackMergePreservesWatchPrecedence()
        testLatestEnvelopeBufferCoalescesBackpressure()
        testWorkoutErrorCopyDistinguishesTerminalUncertainty()
        testTerminalErrorAndTakeoverCopyUseDurableDisposition()
        testWorkoutWatchAvailabilityPolicy()
        testDiscardedWorkoutSummaryDismissalPolicy()
        testWorkoutDiscardDisclosureRequiresFinalConfirmation()
        testIPhoneStartsUseWatchAvailabilityAndWatchStartsDirectly()
        testWatchOfflineNavigationUIFlow()
        testHeartRateZoneConfigurationLivesInIPhoneDeveloperSettings()
        testEveryDiscardSurfaceRequiresFinalConfirmation()
        testWorkoutUICompositionRetainsPhaseThreeExitCriteria()
        testMainRideControlsComposition()
        testWorkoutFormattingKeepsUnavailableValuesDistinctFromZero()
        testWatchWorkoutLaunchRequest()
    }

    private mutating func testRideAutomationGoldenVectorAndValidation() {
        let sessionID = UUID(
            uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"
        )!
        let frame = RideAutomationFrame(
            kind: .decision,
            transition: .pause,
            origin: .automatic,
            rideGeneration: 0x0102_0304,
            decisionSequence: 0x1122_3344,
            evidenceMask: 0x55AA,
            profileVersion: 1,
            sessionID: sessionID,
            watermarkOrConfigGeneration: 7,
            startMode: .ask,
            autoPauseEnabled: true,
            alertMode: 2,
            candidateBeganSeconds: 88,
            monotonicSeconds: 99,
            sourceHealthMask: 0x000F
        )
        let expected = Data([
            2, 1, 2, 2, 0, 1, 1, 2,
            0x04, 0x03, 0x02, 0x01, 0x44, 0x33, 0x22, 0x11,
            0xAA, 0x55, 0x01, 0x00,
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
            0x07, 0, 0, 0, 0x58, 0, 0, 0,
            0x63, 0, 0, 0, 0x0F, 0, 0, 0,
        ])
        expect(frame.encoded() == expected, "RAUT Swift encoding must match firmware golden vector")
        expect(RideAutomationFrame(expected) == frame, "RAUT golden vector must round trip")
        expect(RideAutomationFrame(expected.dropLast()) == nil, "RAUT frames must be exactly 52 bytes")
        var invalid = expected
        invalid[12] = 0
        invalid[13] = 0
        invalid[14] = 0
        invalid[15] = 0
        expect(RideAutomationFrame(invalid) == nil, "RAUT decisions require a nonzero sequence")
        invalid = expected
        invalid[48] = 0x10
        expect(
            RideAutomationFrame(invalid) == nil,
            "RAUT source health must reject undefined bits"
        )
        invalid = expected
        invalid[51] = 1
        expect(
            RideAutomationFrame(invalid) == nil,
            "RAUT reserved bytes must remain zero"
        )

        var acknowledgement = frame
        acknowledgement.kind = .acknowledgement
        acknowledgement.result = .accepted
        acknowledgement.acknowledgedKind = .decision
        expect(
            acknowledgement.encoded().flatMap(RideAutomationFrame.init)
                == acknowledgement,
            "RAUT decision acknowledgements must identify their target kind"
        )
        acknowledgement.acknowledgedKind = nil
        expect(
            acknowledgement.encoded() == nil,
            "RAUT acknowledgements without a target kind must be rejected"
        )
        acknowledgement.transition = .start
        acknowledgement.acknowledgedKind = .promptResponse
        expect(
            acknowledgement.encoded().flatMap(RideAutomationFrame.init)
                == acknowledgement,
            "RAUT prompt acknowledgements must remain distinct from decision acknowledgements"
        )

        var promptResponse = frame
        promptResponse.kind = .promptResponse
        promptResponse.transition = .start
        promptResponse.result = .accepted
        expect(
            promptResponse.encoded().flatMap(RideAutomationFrame.init)
                == promptResponse,
            "device prompt responses must round trip with their decision identity"
        )
        promptResponse.decisionSequence = 0
        expect(
            promptResponse.encoded() == nil,
            "device prompt responses require a nonzero decision sequence"
        )

        var settings = RideDetectionSettings(alertMode: 99)
        settings.normalize()
        expect(settings.alertMode == 2, "ride alert settings must normalize")
        let syncContext = RideDetectionSyncContext.adding(
            settings: RideDetectionSettings(
                startMode: .automatic,
                autoPauseEnabled: false,
                alertMode: 1
            ),
            generation: 42
        )
        let synchronized = RideDetectionSyncContext.settings(
            from: syncContext
        )
        expect(
            synchronized?.generation == 42
                && synchronized?.settings.startMode == .automatic
                && synchronized?.settings.autoPauseEnabled == false
                && synchronized?.settings.alertMode == 1,
            "Watch settings context must preserve normalized ride policy and generation"
        )
        let automaticStart = WorkoutControlContextV1(
            origin: .automatic,
            automaticReason: .rideDetection,
            rideGeneration: 9,
            decisionSequence: 12,
            detectorProfileVersion: 1
        )
        let withAutomaticStart = RideDetectionSyncContext
            .addingPendingAutomaticStart(
                automaticStart,
                to: syncContext
            )
        expect(
            RideDetectionSyncContext.pendingAutomaticStart(
                from: withAutomaticStart
            ) == automaticStart,
            "Watch application context must preserve automatic-start identity"
        )
        let clearedAutomaticStart = RideDetectionSyncContext
            .addingPendingAutomaticStart(nil, to: withAutomaticStart)
        expect(
            RideDetectionSyncContext.pendingAutomaticStart(
                from: clearedAutomaticStart
            ) == nil,
            "clearing automatic-start context must remove every identity field"
        )
        var invalidSyncContext = syncContext
        invalidSyncContext[RideDetectionSyncContext.generationKey] = -1
        expect(
            RideDetectionSyncContext.settings(from: invalidSyncContext) == nil,
            "negative settings generations must not wrap"
        )
        invalidSyncContext = syncContext
        invalidSyncContext[RideDetectionSyncContext.startModeKey] = 256
        expect(
            RideDetectionSyncContext.settings(from: invalidSyncContext) == nil,
            "oversized start modes must not truncate"
        )
        invalidSyncContext = syncContext
        invalidSyncContext[RideDetectionSyncContext.alertModeKey] = 1.5
        expect(
            RideDetectionSyncContext.settings(from: invalidSyncContext) == nil,
            "fractional alert modes must be rejected"
        )
        var invalidAutomaticStart = withAutomaticStart
        invalidAutomaticStart[
            RideDetectionSyncContext.automaticStartDecisionSequenceKey
        ] = NSNumber(value: UInt64(UInt32.max) + 1)
        expect(
            RideDetectionSyncContext.pendingAutomaticStart(
                from: invalidAutomaticStart
            ) == nil,
            "oversized automatic-start identities must not truncate"
        )
        expect(
            RideAutomationSerialNumber.isNewer(2, than: 1)
                && RideAutomationSerialNumber.isNewer(
                    1,
                    than: UInt32.max
                )
                && !RideAutomationSerialNumber.isNewer(1, than: 1)
                && !RideAutomationSerialNumber.isNewer(
                    UInt32.max,
                    than: 1
                ),
            "ride setting generations must compare safely across UInt32 wrap"
        )
        expect(
            WorkoutSchemaVersion.current
                .supportsRideAutomationControlContext
                && !WorkoutSchemaVersion(major: 1, minor: 4)
                    .supportsRideAutomationControlContext,
            "automatic Watch controls must require the 1.5 origin contract"
        )
        expect(
            !RideAutomationMonotonicClock.isExpired(
                sampleSeconds: 107,
                latestSeconds: 100,
                maximumAgeSeconds: 10
            )
                && !RideAutomationMonotonicClock.isExpired(
                    sampleSeconds: 90,
                    latestSeconds: 100,
                    maximumAgeSeconds: 10
                )
                && RideAutomationMonotonicClock.isExpired(
                    sampleSeconds: 89,
                    latestSeconds: 100,
                    maximumAgeSeconds: 10
                )
                && !RideAutomationMonotonicClock.isExpired(
                    sampleSeconds: UInt32.max - 4,
                    latestSeconds: 3,
                    maximumAgeSeconds: 10
                ),
            "device monotonic freshness must accept advances and UInt32 wrap"
        )
    }

#if WORKOUT_CONTRACT_HOST
    private mutating func testRideDetectionSettingsAdoptOnlyNewerDeviceState() {
        let sessionID = UUID(
            uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"
        )!
        let suiteName = "RideDetectionSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            expect(false, "ride settings test defaults must be available")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RideDetectionSettingsStore(defaults: defaults)
        expect(store.generation == 1, "ride settings begin at generation one")

        store.adoptDeviceSettings(
            RideDetectionSettings(
                startMode: .off,
                autoPauseEnabled: false,
                alertMode: 2
            ),
            generation: 2
        )
        expect(
            store.generation == 2
                && store.settings.startMode == .off
                && !store.settings.autoPauseEnabled
                && store.settings.alertMode == 2,
            "newer authenticated device settings must be adopted"
        )

        store.adoptDeviceSettings(
            RideDetectionSettings(
                startMode: .ask,
                autoPauseEnabled: true,
                alertMode: 0
            ),
            generation: 1
        )
        expect(
            store.generation == 2 && store.settings.startMode == .off,
            "older device settings must not replace newer local state"
        )

        store.adoptDeviceSettings(
            RideDetectionSettings(
                startMode: .automatic,
                autoPauseEnabled: true,
                alertMode: 1
            ),
            generation: 3
        )
#if RIDE_AUTOMATION_AUTOMATIC_START
        expect(
            store.generation == 3 && store.settings.startMode == .automatic,
            "automatic rollout builds may adopt automatic device mode"
        )
#else
        expect(
            store.generation == 4 && store.settings.startMode == .ask,
            "closed rollout builds must override automatic mode with a newer Ask generation"
        )
#endif

        let restored = RideDetectionSettingsStore(defaults: defaults)
        expect(
            restored.generation == store.generation
                && restored.settings == store.settings,
            "adopted device settings and generation must survive relaunch"
        )

        defaults.set(-1, forKey: "rideDetection.settingsGeneration.v1")
        let corruptGenerationReload = RideDetectionSettingsStore(
            defaults: defaults
        )
        expect(
            corruptGenerationReload.generation == 1,
            "negative persisted generations must fail closed instead of wrapping"
        )
        defaults.set(
            [
                "bike-a": NSNumber(value: UInt64(UInt32.max) + 1),
                "bike-b": NSNumber(value: 12),
                "": NSNumber(value: 99),
            ],
            forKey: "rideDetection.decisionWatermarks.v1"
        )
        expect(
            corruptGenerationReload.loadDecisionWatermarks()
                == ["bike-b": 12],
            "corrupt decision watermarks and empty device identities must be ignored"
        )

        let startFrame = RideAutomationFrame(
            kind: .decision,
            transition: .start,
            origin: .automatic,
            rideGeneration: 7,
            decisionSequence: 11,
            startMode: .ask,
            autoPauseEnabled: true
        )
        let startIdentity = RideAutomationDecisionIdentity(
            deviceID: "bike-a",
            rideGeneration: 7,
            decisionSequence: 11
        )
        let pendingStart = RideAutomationPendingDecision(
            identity: startIdentity,
            frame: startFrame,
            expectedState: nil
        )
        expect(
            pendingStart.isValidForPersistence
                && pendingStart.isProvenOutstanding(
                    by: startIdentity,
                    on: "bike-a"
                )
                && !pendingStart.isProvenOutstanding(
                    by: RideAutomationDecisionIdentity(
                        deviceID: "bike-a",
                        rideGeneration: 8,
                        decisionSequence: 11
                    ),
                    on: "bike-a"
                ),
            "pending automation may recover only after exact device boot and sequence proof"
        )
        store.savePendingDecision(pendingStart)
        expect(
            store.loadPendingDecision() == pendingStart,
            "a valid unresolved prompt must survive relaunch"
        )

        let mismatchedIdentity = RideAutomationPendingDecision(
            identity: RideAutomationDecisionIdentity(
                deviceID: "bike-a",
                rideGeneration: 7,
                decisionSequence: 12
            ),
            frame: startFrame,
            expectedState: nil
        )
        expect(
            !mismatchedIdentity.isValidForPersistence,
            "a recovery cache cannot relabel a detector decision identity"
        )
        store.savePendingDecision(mismatchedIdentity)
        expect(
            store.loadPendingDecision() == nil,
            "invalid pending automation must be removed rather than replayed"
        )

        let pauseFrame = RideAutomationFrame(
            kind: .decision,
            transition: .pause,
            origin: .automatic,
            rideGeneration: 7,
            decisionSequence: 12,
            sessionID: sessionID,
            startMode: .ask,
            autoPauseEnabled: true
        )
        let pauseIdentity = RideAutomationDecisionIdentity(
            deviceID: "bike-a",
            rideGeneration: 7,
            decisionSequence: 12
        )
        let acceptedPause = RideAutomationPendingDecision(
            identity: pauseIdentity,
            frame: pauseFrame,
            expectedState: .paused,
            resolvedResult: .accepted,
            resolvedSessionID: sessionID
        )
        expect(
            acceptedPause.isValidForPersistence,
            "accepted recovery state must retain a nonzero Watch session identity"
        )
        let unboundAcceptedPause = RideAutomationPendingDecision(
            identity: pauseIdentity,
            frame: pauseFrame,
            expectedState: .paused,
            resolvedResult: .accepted,
            resolvedSessionID: nil
        )
        expect(
            !unboundAcceptedPause.isValidForPersistence,
            "an accepted transition without Watch identity proof must fail closed"
        )
    }
#endif

    private mutating func testRideAutomationAdmissionAndOriginContract() {
        let sessionID = UUID(uuidString: "6D1ED7F6-8BAA-43E2-94D5-2A0E4FF65A01")!
        var settings = RideDetectionSettings()
        let start = RideAutomationFrame(
            kind: .decision,
            transition: .start,
            origin: .automatic,
            rideGeneration: 4,
            decisionSequence: 1
        )
        expect(
            RideAutomationAdmissionPolicy.resolve(
                frame: start,
                settings: settings,
                workoutState: .idle,
                pauseOrigin: nil,
                expectedSessionID: nil,
                highestDecisionSequence: 0
            ) == .prompt,
            "Ask mode must admit a prompt rather than starting optimistically"
        )
        settings.startMode = .off
        expect(
            RideAutomationAdmissionPolicy.resolve(
                frame: start,
                settings: settings,
                workoutState: .idle,
                pauseOrigin: nil,
                expectedSessionID: nil,
                highestDecisionSequence: 0
            ) == .reject(.rejected),
            "Off mode must reject detected starts"
        )
        settings.startMode = .ask
        let resume = RideAutomationFrame(
            kind: .decision,
            transition: .resume,
            origin: .automatic,
            rideGeneration: 4,
            decisionSequence: 2,
            sessionID: sessionID
        )
        expect(
            RideAutomationAdmissionPolicy.resolve(
                frame: resume,
                settings: settings,
                workoutState: .paused,
                pauseOrigin: .manual,
                expectedSessionID: sessionID,
                highestDecisionSequence: 1
            ) == .reject(.stale),
            "automation must never resume a manually paused ride"
        )
        expect(
            RideAutomationAdmissionPolicy.resolve(
                frame: resume,
                settings: settings,
                workoutState: .paused,
                pauseOrigin: .automatic,
                expectedSessionID: sessionID,
                highestDecisionSequence: 1
            ) == .resume,
            "matching automatic pauses may auto-resume"
        )
        var wrappedStart = start
        wrappedStart.decisionSequence = 1
        expect(
            RideAutomationAdmissionPolicy.resolve(
                frame: wrappedStart,
                settings: settings,
                workoutState: .idle,
                pauseOrigin: nil,
                expectedSessionID: nil,
                highestDecisionSequence: UInt32.max
            ) == .prompt,
            "decision deduplication must accept the serial after UInt32 wrap"
        )
        expect(
            RideAutomationRecoveryControlPolicy.mayReplay(
                .pause,
                sessionState: .paused,
                pauseOrigin: .automatic,
                lastTransitionOrigin: .automatic
            )
                && !RideAutomationRecoveryControlPolicy.mayReplay(
                    .pause,
                    sessionState: .paused,
                    pauseOrigin: .manual,
                    lastTransitionOrigin: .manual
                )
                && RideAutomationRecoveryControlPolicy.mayReplay(
                    .resume,
                    sessionState: .running,
                    pauseOrigin: nil,
                    lastTransitionOrigin: .automatic
                )
                && !RideAutomationRecoveryControlPolicy.mayReplay(
                    .resume,
                    sessionState: .running,
                    pauseOrigin: nil,
                    lastTransitionOrigin: .manual
                ),
            "recovery must replay only source-state or known automatic transitions"
        )
        expect(
            RideAutomationStartContextPolicy.disposition(
                sessionState: .idle,
                awaitingSuppliedStartOrigin: false,
                hasConfirmedStartOrigin: false,
                matchesLastConsumedContext: false
            ) == .queueForNextStart
                && RideAutomationStartContextPolicy.disposition(
                    sessionState: .starting,
                    awaitingSuppliedStartOrigin: true,
                    hasConfirmedStartOrigin: false,
                    matchesLastConsumedContext: false
                ) == .applyToCurrentSuppliedStart
                && RideAutomationStartContextPolicy.disposition(
                    sessionState: .running,
                    awaitingSuppliedStartOrigin: true,
                    hasConfirmedStartOrigin: false,
                    matchesLastConsumedContext: false
                ) == .applyToCurrentSuppliedStart
                && RideAutomationStartContextPolicy.disposition(
                    sessionState: .running,
                    awaitingSuppliedStartOrigin: false,
                    hasConfirmedStartOrigin: true,
                    matchesLastConsumedContext: false
                ) == .ignore
                && RideAutomationStartContextPolicy.disposition(
                    sessionState: .paused,
                    awaitingSuppliedStartOrigin: true,
                    hasConfirmedStartOrigin: false,
                    matchesLastConsumedContext: false
                ) == .ignore
                && RideAutomationStartContextPolicy.disposition(
                    sessionState: .idle,
                    awaitingSuppliedStartOrigin: false,
                    hasConfirmedStartOrigin: false,
                    matchesLastConsumedContext: true
                ) == .ignore,
            "late automatic-start context must bind only to its current or next eligible launch"
        )

        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let context = WorkoutControlContextV1(
            origin: .automatic,
            automaticReason: .rideDetection,
            rideGeneration: 4,
            decisionSequence: 2,
            detectorProfileVersion: 1
        )
        let control = WorkoutEnvelopeV1(
            kind: .control,
            sessionID: sessionID,
            sessionToken: 9,
            transportGenerationID: sessionID,
            sequence: 3,
            capturedAt: now,
            controlSenderID: UUID(),
            controlContext: context,
            control: .resume
        )
        let startAnnotation = WorkoutEnvelopeV1(
            kind: .control,
            sessionID: sessionID,
            sessionToken: 9,
            transportGenerationID: sessionID,
            sequence: 4,
            capturedAt: now,
            controlSenderID: UUID(),
            controlContext: WorkoutControlContextV1(
                origin: .automatic,
                automaticReason: .rideDetection,
                rideGeneration: 4,
                decisionSequence: 1,
                detectorProfileVersion: 1
            ),
            control: .requestCurrentSnapshot
        )
        expect(
            (try? WorkoutContractCodec.validate(startAnnotation)) != nil,
            "an automatic start annotation must use the durable snapshot-control path"
        )
        expect(
            (try? WorkoutContractCodec.validate(control)) != nil,
            "automatic pause/resume context must validate"
        )
        let invalidContext = WorkoutEnvelopeV1(
            kind: .control,
            sessionID: sessionID,
            sessionToken: 9,
            transportGenerationID: sessionID,
            sequence: 4,
            capturedAt: now,
            controlSenderID: UUID(),
            controlContext: WorkoutControlContextV1(origin: .automatic),
            control: .pause
        )
        expectThrows(
            .invalidEnvelopePayload,
            "automatic context requires durable decision identity"
        ) {
            try WorkoutContractCodec.validate(invalidContext)
        }
    }
    private mutating func testWorkoutDevicePairGenerationStamp() {
        let sample = WorkoutDeviceTelemetrySample(
            state: .running,
            sessionToken: 7,
            hasLiveNumerics: true,
            isCurrentSnapshot: true,
            elapsedSeconds: 10,
            distanceMeters: 20,
            speedMetersPerSecond: 3,
            currentHeartRateBPM: 120,
            averageHeartRateBPM: 110,
            activeEnergyKilocalories: 5,
            cyclingPowerWatts: 200,
            cyclingCadenceRPM: 80,
            currentHeartRateZone: 2,
            altitudeMeters: 30,
            heartRateZoneCount: 5,
            sourceFlags: [.watchSpeed, .watchAltitude]
        )
        guard let frames = WorkoutDeviceFrameBuilder.frames(for: sample) else {
            expect(false, "workout device frames encode")
            return
        }
        let stamped = WorkoutDeviceFrameBuilder.stampedPair(
            core: frames.core,
            extended: frames.extended,
            generation: 3
        )
        expect(
            stamped.core[1] & 0xC0 == 0xC0 &&
                stamped.extended[1] & 0xC0 == 0xC0,
            "workout core and extended frames share one pair generation"
        )
        expect(
            stamped.core[1] & 0x3F == frames.core[1] &&
                stamped.extended[1] & 0x3F == frames.extended[1],
            "pair stamping preserves state and source bits"
        )
    }

    private mutating func expect(
        _ condition: Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard !condition else { return }
        failureCount += 1
        fputs("FAIL: \(message) (\(file):\(line))\n", stderr)
    }

    private mutating func expectThrows(
        _ expected: WorkoutContractError,
        _ message: String,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            expect(false, "\(message): expected \(expected)")
        } catch let error as WorkoutContractError {
            expect(error == expected, "\(message): got \(error), expected \(expected)")
        } catch {
            expect(false, "\(message): unexpected error \(error)")
        }
    }

    private mutating func testSnapshotRoundTrip() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let snapshot = WorkoutSnapshotV1(
            state: .running,
            startDate: now.addingTimeInterval(-90),
            elapsedTime: metric(90, .seconds, now),
            currentHeartRate: metric(142, .beatsPerMinute, now, .healthKit),
            averageHeartRate: metric(137, .beatsPerMinute, now, .healthKit),
            activeEnergy: metric(41.2, .kilocalories, now, .healthKit),
            cyclingDistance: metric(734.5, .meters, now, .healthKit),
            currentSpeed: metric(8.4, .metersPerSecond, now, .pairedCyclingSensor),
            cyclingPower: metric(211, .watts, now, .healthKit),
            cyclingCadence: metric(88, .revolutionsPerMinute, now, .healthKit),
            currentHeartRateZone: 3,
            heartRateZoneCount: 5,
            heartRateZoneDurations: WorkoutZoneDurationsV1(
                capturedAt: now,
                secondsByZone: [10, 20, 30, 20, 10]
            ),
            location: WorkoutLocationV1(
                latitude: 1.3521,
                longitude: 103.8198,
                capturedAt: now,
                horizontalAccuracy: 4,
                altitude: 12,
                verticalAccuracy: 6,
                course: 182,
                speed: 8.1
            ),
            availability: [
                .elapsedTime,
                .currentHeartRate,
                .averageHeartRate,
                .activeEnergy,
                .cyclingDistance,
                .currentSpeed,
                .cyclingPower,
                .cyclingCadence,
                .heartRateZone,
                .location,
                .altitude,
            ]
        )
        let envelope = makeEnvelope(sequence: 1, capturedAt: now, snapshot: snapshot)

        do {
            let data = try WorkoutContractCodec.encode(envelope)
            expect(data.starts(with: Data("bplist".utf8)), "contract should use a binary property list")
            expect(try roundTripWorkoutEnvelope(envelope) == envelope, "snapshot should round-trip")
        } catch {
            expect(false, "snapshot round-trip threw \(error)")
        }

        let pausedSnapshot = WorkoutSnapshotV1(
            state: .paused,
            startDate: now.addingTimeInterval(-120),
            elapsedTime: metric(90, .seconds, now),
            availability: [.elapsedTime],
            pauseOrigin: .automatic,
            lastTransitionOrigin: .automatic,
            lastTransitionAt: now.addingTimeInterval(-30),
            wallElapsedTime: metric(120, .seconds, now),
            detectorProfileVersion: 1
        )
        let pausedEnvelope = makeEnvelope(
            sequence: 2,
            capturedAt: now,
            snapshot: pausedSnapshot
        )
        do {
            expect(
                try roundTripWorkoutEnvelope(pausedEnvelope).snapshot
                    == pausedSnapshot,
                "automatic pause provenance and wall time should round-trip"
            )
        } catch {
            expect(false, "pause-origin snapshot round-trip threw \(error)")
        }

        let runningPauseProvenance = makeEnvelope(
            sequence: 3,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-120),
                pauseOrigin: .automatic
            )
        )
        expectThrows(.invalidEnvelopePayload, "running pause provenance") {
            try WorkoutContractCodec.validate(runningPauseProvenance)
        }
        let unpairedTransitionDate = makeEnvelope(
            sequence: 4,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .paused,
                startDate: now.addingTimeInterval(-120),
                pauseOrigin: .manual,
                lastTransitionAt: now.addingTimeInterval(-30)
            )
        )
        expectThrows(.invalidEnvelopePayload, "unpaired transition date") {
            try WorkoutContractCodec.validate(unpairedTransitionDate)
        }
        let wallTimeBeforeMovingTime = makeEnvelope(
            sequence: 5,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .paused,
                startDate: now.addingTimeInterval(-120),
                elapsedTime: metric(90, .seconds, now),
                availability: [.elapsedTime],
                pauseOrigin: .automatic,
                wallElapsedTime: metric(89, .seconds, now),
                detectorProfileVersion: 1
            )
        )
        expectThrows(.invalidMetric, "wall time before moving time") {
            try WorkoutContractCodec.validate(wallTimeBeforeMovingTime)
        }
        let zeroDetectorProfile = makeEnvelope(
            sequence: 6,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .paused,
                startDate: now.addingTimeInterval(-120),
                pauseOrigin: .automatic,
                detectorProfileVersion: 0
            )
        )
        expectThrows(.invalidEnvelopePayload, "zero detector profile") {
            try WorkoutContractCodec.validate(zeroDetectorProfile)
        }
        let automaticOriginWithoutProfile = makeEnvelope(
            sequence: 7,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .paused,
                startDate: now.addingTimeInterval(-120),
                pauseOrigin: .automatic,
                lastTransitionOrigin: .automatic,
                lastTransitionAt: now.addingTimeInterval(-30)
            )
        )
        expectThrows(
            .invalidEnvelopePayload,
            "automatic origin without detector profile"
        ) {
            try WorkoutContractCodec.validate(
                automaticOriginWithoutProfile
            )
        }
    }

    private mutating func testSegmentRoundTripValidationAndAccumulation() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_010)
        let firstEnd = start.addingTimeInterval(60)
        var accumulator = WorkoutSegmentAccumulator()
        accumulator.reset(workoutStart: start)
        let first = accumulator.candidate(
            endedAt: firstEnd,
            cumulativeElapsedTime: 55,
            cumulativeDistanceMeters: 1_000,
            cumulativeDistanceSource: .watchRoute
        )
        expect(first?.completedSegment.index == 1, "first segment should be numbered one")
        expect(first?.completedSegment.duration == 55, "segment duration should use active workout time")
        expect(first?.completedSegment.distanceMeters == 1_000, "first segment should begin at zero distance")
        if let first {
            expect(accumulator.commit(first), "first segment candidate should commit")
        }

        let secondEnd = firstEnd.addingTimeInterval(40)
        let second = accumulator.candidate(
            endedAt: secondEnd,
            cumulativeElapsedTime: 90,
            cumulativeDistanceMeters: 1_650,
            cumulativeDistanceSource: .watchRoute
        )
        expect(second?.completedSegment.index == 2, "segments should increment monotonically")
        expect(second?.completedSegment.duration == 35, "pause time must not enter the next segment duration")
        expect(second?.completedSegment.distanceMeters == 650, "segment distance should use cumulative-distance boundaries")
        if let second {
            expect(accumulator.commit(second), "second segment candidate should commit")
        }
        expect(
            WorkoutSnapshotV1(state: .running).currentSegmentIndex == 1,
            "a workout should begin with segment one in progress"
        )

        let snapshot = WorkoutSnapshotV1(
            state: .running,
            startDate: start,
            elapsedTime: metric(90, .seconds, secondEnd),
            lastCompletedSegment: accumulator.lastCompletedSegment,
            availability: [.elapsedTime]
        )
        expect(
            snapshot.currentSegmentIndex == 3,
            "the current segment number should follow the latest completed segment"
        )
        let envelope = makeEnvelope(
            sequence: 1,
            capturedAt: secondEnd,
            snapshot: snapshot
        )
        do {
            let decoded = try roundTripWorkoutEnvelope(envelope)
            expect(
                decoded.snapshot?.lastCompletedSegment
                    == accumulator.lastCompletedSegment,
                "the latest segment summary should round-trip with live metrics"
            )
        } catch {
            expect(false, "segment snapshot round-trip threw \(error)")
        }

        var restored = WorkoutSegmentAccumulator()
        restored.restore(
            workoutStart: start,
            lastCompletedSegment: accumulator.lastCompletedSegment,
            cumulativeElapsedTime: 90,
            cumulativeDistanceMeters: 1_650,
            cumulativeDistanceSource: .watchRoute
        )
        expect(
            restored.candidate(
                endedAt: secondEnd.addingTimeInterval(30),
                cumulativeElapsedTime: 120,
                cumulativeDistanceMeters: 2_100,
                cumulativeDistanceSource: .watchRoute
            )?.completedSegment.index == 3,
            "recovered segment state should continue with the next index"
        )

        let sourceChange = restored.candidate(
            endedAt: secondEnd.addingTimeInterval(30),
            cumulativeElapsedTime: 120,
            cumulativeDistanceMeters: 2_000,
            cumulativeDistanceSource: .healthKit
        )
        expect(
            sourceChange?.completedSegment.distanceMeters == nil,
            "a segment must not subtract cumulative totals from different distance sources"
        )

        let invalidSegment = makeEnvelope(
            sequence: 2,
            capturedAt: secondEnd,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: start,
                lastCompletedSegment: WorkoutCompletedSegmentV1(
                    index: 0,
                    startedAt: start,
                    endedAt: secondEnd,
                    duration: 90,
                    distanceMeters: 1_650
                )
            )
        )
        expectThrows(.invalidMetric, "zero segment index") {
            try WorkoutContractCodec.validate(invalidSegment)
        }

        let failedAcknowledgement = WorkoutEnvelopeV1(
            kind: .acknowledgement,
            sessionID: envelope.sessionID,
            sessionToken: envelope.sessionToken,
            transportGenerationID: envelope.transportGenerationID,
            sequence: 3,
            capturedAt: secondEnd,
            acknowledgement: WorkoutAcknowledgementV1(
                control: .markSegment,
                resultingState: .running,
                acknowledgedSequence: 2,
                errorCode: .segmentMarkFailed
            )
        )
        do {
            expect(
                try roundTripWorkoutEnvelope(failedAcknowledgement)
                    == failedAcknowledgement,
                "a correlated segment failure acknowledgement should round-trip"
            )
        } catch {
            expect(false, "segment failure acknowledgement threw \(error)")
        }
    }

    private mutating func testTerminalOutcomeRoundTripAndValidation() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_050)
        let discarded = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .ended,
                startDate: now.addingTimeInterval(-30),
                terminalOutcome: .discarded
            )
        )
        do {
            let decoded = try roundTripWorkoutEnvelope(discarded)
            expect(
                decoded.snapshot?.terminalOutcome == .discarded,
                "a terminal discard outcome should round-trip"
            )
        } catch {
            expect(false, "terminal outcome round-trip threw \(error)")
        }

        let invalidRunningOutcome = makeEnvelope(
            sequence: 2,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                terminalOutcome: .saved
            )
        )
        expectThrows(.invalidEnvelopePayload, "nonterminal outcome") {
            try WorkoutContractCodec.validate(invalidRunningOutcome)
        }
    }

    private mutating func testAllMessageKindsRoundTrip() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_100)
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let envelopes = [
            WorkoutEnvelopeV1(
                kind: .control,
                sessionID: sessionID,
                sessionToken: 7,
                sequence: 1,
                capturedAt: now,
                control: .pause
            ),
            WorkoutEnvelopeV1(
                kind: .acknowledgement,
                sessionID: sessionID,
                sessionToken: 7,
                sequence: 2,
                capturedAt: now,
                acknowledgement: WorkoutAcknowledgementV1(
                    control: .pause,
                    resultingState: .paused,
                    acknowledgedSequence: 1
                )
            ),
            WorkoutEnvelopeV1(
                kind: .error,
                sessionID: sessionID,
                sessionToken: 7,
                sequence: 3,
                capturedAt: now,
                error: WorkoutErrorV1(code: .sessionFailed)
            ),
        ]

        for envelope in envelopes {
            do {
                expect(
                    try WorkoutContractCodec.decode(WorkoutContractCodec.encode(envelope)) == envelope,
                    "\(envelope.kind) should round-trip"
                )
            } catch {
                expect(false, "\(envelope.kind) round-trip threw \(error)")
            }
        }
    }

    private mutating func testCompatibleMinorVersionIgnoresUnknownFields() {
        let envelope = makeEnvelope(
            schemaVersion: WorkoutSchemaVersion(major: 1, minor: 42),
            sequence: 1
        )
        do {
            let original = try PropertyListEncoder().encode(envelope)
            var plist = try PropertyListSerialization.propertyList(from: original, format: nil) as! [String: Any]
            plist["futureOptionalField"] = "ignored"
            let withUnknownField = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .binary,
                options: 0
            )
            let decoded = try WorkoutContractCodec.decode(withUnknownField)
            expect(decoded.schemaVersion.minor == 42, "compatible minor version should be retained")
        } catch {
            expect(false, "compatible minor version threw \(error)")
        }
    }

    private mutating func testUnsupportedMajorVersionIsRejected() {
        let envelope = makeEnvelope(
            schemaVersion: WorkoutSchemaVersion(major: 2, minor: 0),
            sequence: 1
        )
        do {
            let data = try PropertyListEncoder().encode(envelope)
            expectThrows(.unsupportedSchemaMajor(2), "future schema major") {
                _ = try WorkoutContractCodec.decode(data)
            }
        } catch {
            expect(false, "building future-major fixture threw \(error)")
        }
    }

    private mutating func testOptionalMetricsRemainUnavailable() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let envelope = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .starting,
                startDate: now
            )
        )
        do {
            let decoded = try WorkoutContractCodec.decode(WorkoutContractCodec.encode(envelope))
            expect(decoded.snapshot?.currentHeartRate == nil, "missing heart rate must remain unavailable")
            expect(decoded.snapshot?.cyclingPower == nil, "missing power must remain unavailable")
            expect(decoded.snapshot?.availability.isEmpty == true, "availability mask must remain empty")
        } catch {
            expect(false, "optional metric fixture threw \(error)")
        }
    }

    private mutating func testInvalidEnvelopeIdentityIsRejected() {
        let emptyID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let emptyIDEnvelope = makeEnvelope(sessionID: emptyID, sequence: 1)
        let zeroTokenEnvelope = makeEnvelope(sessionToken: 0, sequence: 1)
        let zeroGenerationEnvelope = makeEnvelope(
            transportGenerationID: emptyID,
            sequence: 1
        )
        expectThrows(.emptySessionID, "empty session ID") {
            try WorkoutContractCodec.validate(emptyIDEnvelope)
        }
        expectThrows(.zeroSessionToken, "zero token") {
            try WorkoutContractCodec.validate(zeroTokenEnvelope)
        }
        expectThrows(.invalidEnvelopePayload, "zero transport generation") {
            try WorkoutContractCodec.validate(zeroGenerationEnvelope)
        }
        expectThrows(.invalidEnvelopePayload, "kind/payload mismatch") {
            try WorkoutContractCodec.validate(
                WorkoutEnvelopeV1(
                    kind: .control,
                    sessionID: UUID(),
                    sessionToken: 1,
                    sequence: 1,
                    capturedAt: Date(),
                    snapshot: WorkoutSnapshotV1(state: .running)
                )
            )
        }
    }

    private mutating func testInvalidNumbersAndCoordinatesAreRejected() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_200)
        let nonFiniteMetricEnvelope = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                currentSpeed: metric(.infinity, .metersPerSecond, now, .watchLocation),
                availability: [.currentSpeed]
            )
        )
        let negativeTotalEnvelope = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                cyclingDistance: metric(-1, .meters, now, .healthKit),
                availability: [.cyclingDistance]
            )
        )
        let validNumbersEnvelope = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                cyclingDistance: metric(1, .meters, now, .healthKit),
                currentSpeed: metric(0, .metersPerSecond, now, .watchLocation),
                availability: [.cyclingDistance, .currentSpeed]
            )
        )
        let invalidLocationEnvelope = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                location: WorkoutLocationV1(
                    latitude: 91,
                    longitude: 103,
                    capturedAt: now,
                    horizontalAccuracy: 5,
                    altitude: nil,
                    verticalAccuracy: nil,
                    course: nil,
                    speed: nil
                )
            )
        )
        expectThrows(.invalidMetric, "non-finite metric") {
            try WorkoutContractCodec.validate(nonFiniteMetricEnvelope)
        }
        expectThrows(.invalidMetric, "negative total") {
            try WorkoutContractCodec.validate(negativeTotalEnvelope)
        }
        expectThrows(.invalidLocation, "invalid coordinate") {
            try WorkoutContractCodec.validate(invalidLocationEnvelope)
        }
        do {
            try WorkoutContractCodec.validate(validNumbersEnvelope)
        } catch {
            expect(false, "finite nonnegative numeric control should validate: \(error)")
        }
    }

    private mutating func testSequenceGateRejectsDuplicatesAndOlderSnapshots() {
        var gate = WorkoutEnvelopeSequenceGate()
        do {
            expect(try gate.ingest(makeEnvelope(sequence: 0)), "zero may be the first sequence")
            expect(try gate.ingest(makeEnvelope(sequence: 2)), "newer sequence should be accepted")
            expect(!(try gate.ingest(makeEnvelope(sequence: 2))), "duplicate sequence should be rejected")
            expect(!(try gate.ingest(makeEnvelope(sequence: 1))), "older sequence should be rejected")
            expect(try gate.ingest(makeEnvelope(sequence: 3)), "newer sequence should be accepted")
        } catch {
            expect(false, "sequence gate threw \(error)")
        }
    }

    private mutating func testMetricUnitsAndAvailabilityMustMatchPayload() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_300)
        let wrongUnitEnvelope = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                currentHeartRate: metric(140, .watts, now),
                availability: [.currentHeartRate]
            )
        )
        let staleAvailabilityEnvelope = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                currentHeartRate: metric(140, .beatsPerMinute, now)
            )
        )
        expectThrows(.invalidMetric, "metric unit mismatch") {
            try WorkoutContractCodec.validate(wrongUnitEnvelope)
        }
        expectThrows(.invalidMetric, "availability mismatch") {
            try WorkoutContractCodec.validate(staleAvailabilityEnvelope)
        }
    }

    private mutating func testActiveSnapshotsRequireTrustworthyStartDates() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_350)
        let missingStart = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(state: .running)
        )
        let futureStart = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .paused,
                startDate: now.addingTimeInterval(1)
            )
        )
        expectThrows(.invalidDate, "active snapshot missing start date") {
            try WorkoutContractCodec.validate(missingStart)
        }
        expectThrows(.invalidDate, "start date after capture") {
            try WorkoutContractCodec.validate(futureStart)
        }
    }

    private mutating func testHeartRateMustBePositiveWithoutRejectingMeaningfulZeroes() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_375)
        for (label, snapshot) in [
            (
                "current",
                WorkoutSnapshotV1(
                    state: .running,
                    startDate: now.addingTimeInterval(-30),
                    currentHeartRate: metric(0, .beatsPerMinute, now, .healthKit),
                    availability: [.currentHeartRate]
                )
            ),
            (
                "average",
                WorkoutSnapshotV1(
                    state: .running,
                    startDate: now.addingTimeInterval(-30),
                    averageHeartRate: metric(0, .beatsPerMinute, now, .healthKit),
                    availability: [.averageHeartRate]
                )
            ),
        ] {
            let envelope = makeEnvelope(sequence: 1, capturedAt: now, snapshot: snapshot)
            expectThrows(.invalidMetric, "zero \(label) heart rate") {
                try WorkoutContractCodec.validate(envelope)
            }
        }

        let meaningfulZeroes = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                elapsedTime: metric(0, .seconds, now),
                activeEnergy: metric(0, .kilocalories, now, .healthKit),
                cyclingDistance: metric(0, .meters, now, .healthKit),
                currentSpeed: metric(0, .metersPerSecond, now, .watchLocation),
                cyclingPower: metric(0, .watts, now, .healthKit),
                cyclingCadence: metric(0, .revolutionsPerMinute, now, .healthKit),
                availability: [
                    .elapsedTime,
                    .activeEnergy,
                    .cyclingDistance,
                    .currentSpeed,
                    .cyclingPower,
                    .cyclingCadence,
                ]
            )
        )
        do {
            try WorkoutContractCodec.validate(meaningfulZeroes)
        } catch {
            expect(false, "meaningful zero metrics should remain valid: \(error)")
        }
    }

    private mutating func testSpeedRequiresSource() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_400)
        let noSource = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                currentSpeed: metric(8.2, .metersPerSecond, now),
                availability: [.currentSpeed]
            )
        )
        expectThrows(.invalidMetric, "speed without provenance") {
            try WorkoutContractCodec.validate(noSource)
        }

        for source in [
            WorkoutMetricSourceV1.pairedCyclingSensor,
            .watchLocation,
            .iPhoneLocation,
        ] {
            let withSource = makeEnvelope(
                sequence: 1,
                capturedAt: now,
                snapshot: WorkoutSnapshotV1(
                    state: .running,
                    startDate: now.addingTimeInterval(-30),
                    currentSpeed: metric(8.2, .metersPerSecond, now, source),
                    availability: [.currentSpeed]
                )
            )
            do {
                try WorkoutContractCodec.validate(withSource)
            } catch {
                expect(false, "valid speed source \(source.rawValue) threw \(error)")
            }
        }

        for source in [
            WorkoutMetricSourceV1.healthKit,
            .watchRoute,
            .iPhoneNavigation,
            .unknown,
        ] {
            let invalidSource = makeEnvelope(
                sequence: 1,
                capturedAt: now,
                snapshot: WorkoutSnapshotV1(
                    state: .running,
                    startDate: now.addingTimeInterval(-30),
                    currentSpeed: metric(8.2, .metersPerSecond, now, source),
                    availability: [.currentSpeed]
                )
            )
            expectThrows(.invalidMetric, "invalid speed source \(source.rawValue)") {
                try WorkoutContractCodec.validate(invalidSource)
            }
        }

        do {
            let data = Data(#""futurePrivateSource""#.utf8)
            let source = try JSONDecoder().decode(WorkoutMetricSourceV1.self, from: data)
            expect(source == .unknown, "unknown metric sources should decode to a safe generic case")
        } catch {
            expect(false, "unknown metric source fixture threw \(error)")
        }

        var gate = WorkoutEnvelopeSequenceGate()
        let valid = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                currentSpeed: metric(8.2, .metersPerSecond, now, .watchLocation),
                availability: [.currentSpeed]
            )
        )
        let invalidHigherSequence = makeEnvelope(
            sequence: 2,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                currentSpeed: metric(8.2, .metersPerSecond, now, .healthKit),
                availability: [.currentSpeed]
            )
        )
        do {
            expect(try gate.ingest(valid), "valid speed should seed the sequence gate")
        } catch {
            expect(false, "valid speed gate fixture threw \(error)")
        }
        expectThrows(.invalidMetric, "invalid speed must fail before advancing gate state") {
            _ = try gate.ingest(invalidHigherSequence)
        }
        expect(
            gate.highestSequenceBySession[valid.sessionID] == 1,
            "invalid speed must not advance the highest accepted sequence"
        )
        expect(gate.currentSnapshotEnvelope?.sequence == 1, "invalid speed must not replace the snapshot")
    }

    private mutating func testCyclingDistanceRequiresSource() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_450)
        for source in [
            WorkoutMetricSourceV1.healthKit,
            .watchRoute,
            .iPhoneNavigation,
        ] {
            let valid = makeEnvelope(
                sequence: 1,
                capturedAt: now,
                snapshot: WorkoutSnapshotV1(
                    state: .running,
                    startDate: now.addingTimeInterval(-30),
                    cyclingDistance: metric(500, .meters, now, source),
                    availability: [.cyclingDistance]
                )
            )
            do {
                try WorkoutContractCodec.validate(valid)
            } catch {
                expect(false, "valid distance source \(source.rawValue) threw \(error)")
            }
        }

        let invalidSources: [WorkoutMetricSourceV1?] = [
            nil,
            .pairedCyclingSensor,
            .watchLocation,
            .iPhoneLocation,
            .unknown,
        ]
        for source in invalidSources {
            let invalid = makeEnvelope(
                sequence: 1,
                capturedAt: now,
                snapshot: WorkoutSnapshotV1(
                    state: .running,
                    startDate: now.addingTimeInterval(-30),
                    cyclingDistance: metric(500, .meters, now, source),
                    availability: [.cyclingDistance]
                )
            )
            expectThrows(.invalidMetric, "invalid distance source \(source?.rawValue ?? "nil")") {
                try WorkoutContractCodec.validate(invalid)
            }
        }

        var gate = WorkoutEnvelopeSequenceGate()
        let valid = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                cyclingDistance: metric(500, .meters, now, .healthKit),
                availability: [.cyclingDistance]
            )
        )
        let invalidHigherSequence = makeEnvelope(
            sequence: 2,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                cyclingDistance: metric(510, .meters, now, .iPhoneLocation),
                availability: [.cyclingDistance]
            )
        )
        do {
            expect(try gate.ingest(valid), "valid distance should seed the sequence gate")
        } catch {
            expect(false, "valid distance gate fixture threw \(error)")
        }
        expectThrows(.invalidMetric, "invalid distance must fail before advancing gate state") {
            _ = try gate.ingest(invalidHigherSequence)
        }
        expect(
            gate.highestSequenceBySession[valid.sessionID] == 1,
            "invalid distance must not advance the highest accepted sequence"
        )
        expect(gate.currentSnapshotEnvelope?.sequence == 1, "invalid distance must not replace the snapshot")
    }

    private mutating func testComponentTimestampsStayWithinWorkoutWindow() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_500)
        let capturedAt = start.addingTimeInterval(60)
        let validBoundaryEnvelope = makeEnvelope(
            sequence: 1,
            capturedAt: capturedAt,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: start,
                currentHeartRate: metric(140, .beatsPerMinute, start, .healthKit),
                heartRateZoneCount: 2,
                heartRateZoneDurations: WorkoutZoneDurationsV1(
                    capturedAt: capturedAt,
                    secondsByZone: [30, 30]
                ),
                location: WorkoutLocationV1(
                    latitude: 1.35,
                    longitude: 103.82,
                    capturedAt: capturedAt,
                    horizontalAccuracy: 5,
                    altitude: nil,
                    verticalAccuracy: nil,
                    course: nil,
                    speed: nil
                ),
                availability: [.currentHeartRate, .heartRateZone, .location]
            )
        )
        do {
            try WorkoutContractCodec.validate(validBoundaryEnvelope)
        } catch {
            expect(false, "component timestamps at workout boundaries should be valid: \(error)")
        }

        let preStartMetric = makeEnvelope(
            sequence: 1,
            capturedAt: capturedAt,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: start,
                currentHeartRate: metric(
                    140,
                    .beatsPerMinute,
                    start.addingTimeInterval(-1),
                    .healthKit
                ),
                availability: [.currentHeartRate]
            )
        )
        expectThrows(.invalidMetric, "metric captured before workout start") {
            try WorkoutContractCodec.validate(preStartMetric)
        }

        let futureLocation = makeEnvelope(
            sequence: 1,
            capturedAt: capturedAt,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: start,
                location: WorkoutLocationV1(
                    latitude: 1.35,
                    longitude: 103.82,
                    capturedAt: capturedAt.addingTimeInterval(1),
                    horizontalAccuracy: 5,
                    altitude: nil,
                    verticalAccuracy: nil,
                    course: nil,
                    speed: nil
                ),
                availability: [.location]
            )
        )
        expectThrows(.invalidLocation, "location captured after envelope") {
            try WorkoutContractCodec.validate(futureLocation)
        }

        let futureZoneDurations = makeEnvelope(
            sequence: 1,
            capturedAt: capturedAt,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: start,
                heartRateZoneCount: 2,
                heartRateZoneDurations: WorkoutZoneDurationsV1(
                    capturedAt: capturedAt.addingTimeInterval(1),
                    secondsByZone: [30, 30]
                ),
                availability: [.heartRateZone]
            )
        )
        expectThrows(.invalidZone, "zone durations captured after envelope") {
            try WorkoutContractCodec.validate(futureZoneDurations)
        }
    }

    private mutating func testHeartRateZonePayloadIsCoherent() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_600)
        let durationsWithoutCount = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-60),
                heartRateZoneDurations: WorkoutZoneDurationsV1(
                    capturedAt: now,
                    secondsByZone: [20, 40]
                ),
                availability: [.heartRateZone]
            )
        )
        expectThrows(.invalidZone, "zone durations without a declared zone count") {
            try WorkoutContractCodec.validate(durationsWithoutCount)
        }

        let missingAvailability = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-60),
                heartRateZoneCount: 2,
                heartRateZoneDurations: WorkoutZoneDurationsV1(
                    capturedAt: now,
                    secondsByZone: [20, 40]
                )
            )
        )
        expectThrows(.invalidMetric, "zone payload without availability bit") {
            try WorkoutContractCodec.validate(missingAvailability)
        }

        let coherent = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-60),
                currentHeartRateZone: 2,
                heartRateZoneCount: 2,
                heartRateZoneDurations: WorkoutZoneDurationsV1(
                    capturedAt: now,
                    secondsByZone: [20, 40]
                ),
                availability: [.heartRateZone]
            )
        )
        do {
            try WorkoutContractCodec.validate(coherent)
        } catch {
            expect(false, "coherent zone payload should be accepted: \(error)")
        }

        let invalidProfile = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-60),
                heartRateZoneCount: 2,
                heartRateZoneDurations: WorkoutZoneDurationsV1(
                    capturedAt: now,
                    secondsByZone: [20, 40],
                    maximumHeartRateBPM: 999
                ),
                availability: [.heartRateZone]
            )
        )
        expectThrows(.invalidZone, "zone profile must stay in supported bounds") {
            try WorkoutContractCodec.validate(invalidProfile)
        }
    }

    private mutating func testHeartRateZoneProfileAndPersistence() {
        let profile = WorkoutHeartRateZoneProfile(maximumHeartRateBPM: 200)
        expect(profile.zone(for: nil) == nil, "missing heart rate has no zone")
        expect(profile.zone(for: 0) == nil, "zero heart rate has no zone")
        expect(profile.zone(for: .nan) == nil, "non-finite heart rate has no zone")
        expect(profile.zone(for: 119.9) == 1, "below 60 percent is zone 1")
        expect(profile.zone(for: 120) == 2, "60 percent starts zone 2")
        expect(profile.zone(for: 140) == 3, "70 percent starts zone 3")
        expect(profile.zone(for: 160) == 4, "80 percent starts zone 4")
        expect(profile.zone(for: 180) == 5, "90 percent starts zone 5")
        expect(profile.zone(for: 220) == 5, "above max remains zone 5")
        expect(
            profile.bpmRange(for: 1)
                == WorkoutHeartRateZoneBPMRange(
                    lowerBound: nil,
                    upperBound: 119
                ),
            "zone 1 summary range should end below 60 percent"
        )
        expect(
            profile.bpmRange(for: 3)
                == WorkoutHeartRateZoneBPMRange(
                    lowerBound: 140,
                    upperBound: 159
                ),
            "middle summary ranges should match the live zone boundaries"
        )
        expect(
            profile.bpmRange(for: 5)
                == WorkoutHeartRateZoneBPMRange(
                    lowerBound: 180,
                    upperBound: nil
                ),
            "zone 5 summary range should remain open ended"
        )
        expect(
            profile.bpmRange(for: 0) == nil
                && profile.bpmRange(for: 6) == nil,
            "unsupported zone numbers should not produce summary ranges"
        )
        expect(
            WorkoutHeartRateZoneProfile(maximumHeartRateBPM: 20)
                .maximumHeartRateBPM == 100,
            "maximum heart rate clamps to the supported lower bound"
        )
        expect(
            WorkoutHeartRateZoneProfile(maximumHeartRateBPM: 900)
                .maximumHeartRateBPM == 240,
            "maximum heart rate clamps to the supported upper bound"
        )

        let suiteName = "WorkoutHeartRateZoneSettingsTests"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            expect(false, "heart-rate zone test defaults should be available")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        expect(
            WorkoutHeartRateZoneSettings.maximumHeartRateBPM(from: defaults)
                == WorkoutHeartRateZoneProfile.defaultMaximumHeartRateBPM,
            "missing setting uses the documented default"
        )
        WorkoutHeartRateZoneSettings.saveMaximumHeartRateBPM(205, to: defaults)
        expect(
            WorkoutHeartRateZoneSettings.maximumHeartRateBPM(from: defaults)
                == 205,
            "maximum heart rate persists"
        )
        WorkoutHeartRateZoneSettings.saveMaximumHeartRateBPM(999, to: defaults)
        expect(
            WorkoutHeartRateZoneSettings.maximumHeartRateBPM(from: defaults)
                == 240,
            "persisted maximum heart rate is clamped"
        )

        let applicationContext = WorkoutHeartRateZoneSyncContext
            .applicationContext(maximumHeartRateBPM: 205)
        expect(
            WorkoutHeartRateZoneSyncContext.maximumHeartRateBPM(
                from: applicationContext
            ) == 205,
            "maximum heart rate round-trips through Watch sync context"
        )
        expect(
            WorkoutHeartRateZoneSyncContext.maximumHeartRateBPM(
                from: [
                    WorkoutHeartRateZoneSyncContext.maximumHeartRateBPMKey: 999
                ]
            ) == 240,
            "Watch sync context clamps a received maximum heart rate"
        )
        expect(
            WorkoutHeartRateZoneSyncContext.maximumHeartRateBPM(from: [:])
                == nil,
            "missing Watch sync context leaves the current/default value unchanged"
        )
    }

    private mutating func testHeartRateZoneBreakdownPresentation() {
        let capturedAt = Date(
            timeIntervalSinceReferenceDate: 800_000_605
        )
        let presentation = WorkoutHeartRateZoneBreakdownPresentationV1.make(
            durations: WorkoutZoneDurationsV1(
                capturedAt: capturedAt,
                secondsByZone: [109, 42, 55, 149, 704],
                maximumHeartRateBPM: 200
            )
        )
        expect(
            presentation?.maximumHeartRateBPM == 200,
            "zone breakdown must use the Watch profile carried with its bins"
        )
        expect(
            presentation?.rows.map(\.zone) == [1, 2, 3, 4, 5],
            "zone breakdown must present exactly five ordered rows"
        )
        expect(
            presentation?.rows[0].durationLabel == "01:49"
                && presentation?.rows[0].bpmRangeLabel == "<120 BPM",
            "zone breakdown must format duration and lower open range"
        )
        expect(
            presentation?.rows[2].bpmRangeLabel == "140–159 BPM"
                && presentation?.rows[4].bpmRangeLabel == "180+ BPM",
            "zone breakdown must match middle and upper live-zone boundaries"
        )
        expect(
            presentation?.rows[4].fractionOfLongestDuration == 1
                && abs(
                    (presentation?.rows[3].fractionOfLongestDuration ?? 0)
                        - 149.0 / 704.0
                ) < 0.000_001,
            "zone bars must scale against the longest recorded duration"
        )
        expect(
            presentation?.rows[2].accessibilityLabel
                == "Zone 3, 00:55, 140–159 BPM",
            "zone rows must expose the same values to accessibility"
        )

        let zeroPresentation =
            WorkoutHeartRateZoneBreakdownPresentationV1.make(
                durations: WorkoutZoneDurationsV1(
                    capturedAt: capturedAt,
                    secondsByZone: [0, 0, 0, 0, 0]
                )
            )
        expect(
            zeroPresentation?.rows.allSatisfy {
                $0.fractionOfLongestDuration == 0
            } == true,
            "all-zero zone durations must render zero-width progress bars"
        )
        expect(
            zeroPresentation?.maximumHeartRateBPM == nil
                && zeroPresentation?.rows.allSatisfy {
                    $0.bpmRangeLabel == "Range unavailable"
                } == true,
            "legacy zone payloads must not invent historical BPM ranges from current settings"
        )
        expect(
            WorkoutHeartRateZoneBreakdownPresentationV1.make(
                durations: nil
            ) == nil,
            "missing zone durations must use the unavailable state"
        )
        expect(
            WorkoutHeartRateZoneBreakdownPresentationV1.make(
                durations: WorkoutZoneDurationsV1(
                    capturedAt: capturedAt,
                    secondsByZone: [1, 2]
                )
            ) == nil,
            "malformed zone arrays must use the unavailable state"
        )
        expect(
            WorkoutHeartRateZoneBreakdownPresentationV1.make(
                durations: WorkoutZoneDurationsV1(
                    capturedAt: capturedAt,
                    secondsByZone: [0, 0, .nan, 0, 0]
                )
            ) == nil,
            "non-finite zone durations must use the unavailable state"
        )
    }

    private mutating func testHeartRateZoneDurationAccumulator() {
        let firstSession = UUID(
            uuidString: "72C8E2D9-3EC0-4C9A-A101-111111111111"
        )!
        let secondSession = UUID(
            uuidString: "72C8E2D9-3EC0-4C9A-A101-222222222222"
        )!
        var accumulator = WorkoutHeartRateZoneDurationAccumulator()

        expect(
            accumulator.update(
                sessionID: firstSession,
                elapsedTime: 10,
                currentZone: 2
            ) == 0,
            "the first observed zone starts at zero without inventing history"
        )
        expect(
            accumulator.authoritativeDurations(
                capturedAt: Date(timeIntervalSinceReferenceDate: 800_000_410)
            )?.secondsByZone == [0, 0, 0, 0, 0],
            "the workout owner publishes an authoritative five-zone baseline"
        )
        expect(
            accumulator.update(
                sessionID: firstSession,
                elapsedTime: 15,
                currentZone: 2
            ) == 5,
            "workout elapsed time accumulates in the current zone"
        )
        expect(
            accumulator.update(
                sessionID: firstSession,
                elapsedTime: 20,
                currentZone: 3
            ) == 0,
            "moving zones attributes the preceding interval to the old zone"
        )
        expect(
            accumulator.update(
                sessionID: firstSession,
                elapsedTime: 24,
                currentZone: 3
            ) == 4,
            "the new zone begins accumulating on the next elapsed update"
        )
        expect(
            accumulator.update(
                sessionID: firstSession,
                elapsedTime: 24,
                currentZone: 3
            ) == 4,
            "a paused workout does not advance time in zone"
        )
        expect(
            accumulator.update(
                sessionID: firstSession,
                elapsedTime: 27,
                currentZone: 2
            ) == 10,
            "returning to a zone shows its cumulative workout time"
        )

        let authoritative = WorkoutZoneDurationsV1(
            capturedAt: Date(timeIntervalSinceReferenceDate: 800_000_425),
            secondsByZone: [1, 12, 8, 4, 5]
        )
        expect(
            accumulator.update(
                sessionID: firstSession,
                elapsedTime: 30,
                currentZone: 4,
                authoritativeDurations: authoritative
            ) == 4,
            "authoritative Watch zone durations replace the local fallback"
        )
        expect(
            accumulator.authoritativeDurations(
                capturedAt: authoritative.capturedAt,
                maximumHeartRateBPM: 200
            ) == WorkoutZoneDurationsV1(
                capturedAt: authoritative.capturedAt,
                secondsByZone: authoritative.secondsByZone,
                maximumHeartRateBPM: 200
            ),
            "authoritative zone totals and their profile survive transport coalescing"
        )
        let regressingAuthoritative = WorkoutZoneDurationsV1(
            capturedAt: authoritative.capturedAt.addingTimeInterval(1),
            secondsByZone: [0, 0, 0, 0, 0]
        )
        expect(
            accumulator.update(
                sessionID: firstSession,
                elapsedTime: 30,
                currentZone: 4,
                authoritativeDurations: regressingAuthoritative
            ) == 4,
            "a recovered authoritative snapshot cannot move zone time backward"
        )

        var recoveredAccumulator = WorkoutHeartRateZoneDurationAccumulator()
        var zoneEntryAccumulator = WorkoutHeartRateZoneDurationAccumulator()
        _ = zoneEntryAccumulator.update(
            sessionID: secondSession,
            elapsedTime: 10,
            currentZone: 2
        )
        let zoneEntryCheckpoint = zoneEntryAccumulator.checkpoint
        _ = zoneEntryAccumulator.update(
            sessionID: secondSession,
            elapsedTime: 15,
            currentZone: 2
        )
        recoveredAccumulator.restore(
            sessionID: secondSession,
            checkpoint: zoneEntryCheckpoint
        )
        expect(
            recoveredAccumulator.update(
                sessionID: secondSession,
                elapsedTime: 30,
                currentZone: 2
            ) == 20,
            "Watch recovery reconstructs the uninterrupted current-zone interval from its entry checkpoint"
        )
        expect(
            recoveredAccumulator.update(
                sessionID: secondSession,
                elapsedTime: 0,
                currentZone: 2
            ) == 20,
            "a temporarily regressed recovered clock does not change zone totals"
        )
        expect(
            recoveredAccumulator.update(
                sessionID: secondSession,
                elapsedTime: 1,
                currentZone: 2
            ) == 20,
            "successive regressed clock values cannot double-count recovered time"
        )
        expect(
            recoveredAccumulator.update(
                sessionID: secondSession,
                elapsedTime: 31,
                currentZone: 2
            ) == 21,
            "zone accumulation resumes only after the recovered clock passes its checkpoint"
        )

        var terminalCheckpointAccumulator =
            WorkoutHeartRateZoneDurationAccumulator()
        _ = terminalCheckpointAccumulator.update(
            sessionID: secondSession,
            elapsedTime: 0,
            currentZone: 3
        )
        _ = terminalCheckpointAccumulator.update(
            sessionID: secondSession,
            elapsedTime: 585,
            currentZone: 3
        )
        _ = terminalCheckpointAccumulator.update(
            sessionID: secondSession,
            elapsedTime: nil,
            currentZone: nil
        )
        expect(
            terminalCheckpointAccumulator.hasCompleteTerminalDurations(
                elapsedTime: 585
            ),
            "a detached checkpoint is complete only at its exact authoritative elapsed time"
        )
        expect(
            !terminalCheckpointAccumulator.hasCompleteTerminalDurations(
                elapsedTime: 600
            )
                && !terminalCheckpointAccumulator
                    .hasCompleteTerminalDurations(elapsedTime: nil),
            "a stale or duration-less detached checkpoint must not claim exact final zone totals"
        )

        var persistenceGate =
            WorkoutHeartRateZoneCheckpointPersistenceGate()
        let firstCheckpoint = zoneEntryCheckpoint
        persistenceGate.observeTransition(from: nil, to: firstCheckpoint)
        let firstAttemptAt = Date(
            timeIntervalSinceReferenceDate: 800_000_430
        )
        expect(
            persistenceGate.shouldAttempt(at: firstAttemptAt),
            "the first observed zone checkpoints immediately"
        )
        persistenceGate.markSucceeded()
        let changedZoneCheckpoint =
            WorkoutHeartRateZoneDurationAccumulator.Checkpoint(
                previousElapsedTime: 11,
                previousZone: 3,
                secondsByZone: [0, 1, 0, 0, 0]
            )
        persistenceGate.observeTransition(
            from: firstCheckpoint,
            to: changedZoneCheckpoint
        )
        expect(
            !persistenceGate.shouldAttempt(
                at: firstAttemptAt.addingTimeInterval(1)
            ),
            "rapid zone oscillation is coalesced instead of writing every second"
        )
        let returnedZoneCheckpoint =
            WorkoutHeartRateZoneDurationAccumulator.Checkpoint(
                previousElapsedTime: 12,
                previousZone: 2,
                secondsByZone: [0, 1, 1, 0, 0]
            )
        persistenceGate.observeTransition(
            from: changedZoneCheckpoint,
            to: returnedZoneCheckpoint
        )
        expect(
            persistenceGate.shouldAttempt(
                at: firstAttemptAt.addingTimeInterval(15)
            ),
            "a coalesced transition remains pending until the bounded retry"
        )
        expect(
            persistenceGate.hasPendingTransition,
            "a persistence attempt alone does not discard an unsaved transition"
        )
        persistenceGate.markSucceeded()
        expect(
            !persistenceGate.hasPendingTransition,
            "only a successful durable write clears the pending transition"
        )
        let advancedSameZoneCheckpoint =
            WorkoutHeartRateZoneDurationAccumulator.Checkpoint(
                previousElapsedTime: 27,
                previousZone: 2,
                secondsByZone: [0, 16, 1, 0, 0]
            )
        persistenceGate.observeTransition(
            from: returnedZoneCheckpoint,
            to: advancedSameZoneCheckpoint
        )
        expect(
            persistenceGate.shouldAttempt(
                at: firstAttemptAt.addingTimeInterval(30)
            ),
            "time accumulated within one zone must checkpoint at the bounded interval"
        )
        persistenceGate.markSucceeded()
        expect(
            accumulator.update(
                sessionID: secondSession,
                elapsedTime: 5,
                currentZone: 1
            ) == 0,
            "a new workout session resets accumulated zone time"
        )
        expect(
            accumulator.update(
                sessionID: nil,
                elapsedTime: nil,
                currentZone: nil
            ) == nil,
            "clearing the session clears the displayed zone duration"
        )
    }

#if WORKOUT_CONTRACT_HOST
    private mutating func testWorkoutMetricsStoreUsesAuthoritativeCoalescedZoneTotals() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_500)
        let sessionID = UUID(
            uuidString: "72C8E2D9-3EC0-4C9A-A101-333333333333"
        )!
        var currentDate = start.addingTimeInterval(10)
        let store = WorkoutMetricsStore(now: { currentDate })
        store.attachMirroredSession(at: currentDate)

        func zoneSnapshot(
            elapsedTime: TimeInterval,
            zone: UInt8,
            secondsByZone: [TimeInterval],
            capturedAt: Date
        ) -> WorkoutSnapshotV1 {
            WorkoutSnapshotV1(
                state: .running,
                startDate: start,
                elapsedTime: WorkoutMetricV1(
                    value: elapsedTime,
                    unit: .seconds,
                    capturedAt: capturedAt
                ),
                currentHeartRateZone: zone,
                heartRateZoneCount: WorkoutHeartRateZoneProfile.zoneCount,
                heartRateZoneDurations: WorkoutZoneDurationsV1(
                    capturedAt: capturedAt,
                    secondsByZone: secondsByZone
                ),
                availability: [.elapsedTime, .heartRateZone]
            )
        }

        _ = store.ingestBatch(
            [
                makeEnvelope(
                    sessionID: sessionID,
                    sequence: 1,
                    capturedAt: currentDate,
                    snapshot: zoneSnapshot(
                        elapsedTime: 10,
                        zone: 2,
                        secondsByZone: [0, 0, 0, 0, 0],
                        capturedAt: currentDate
                    )
                ),
            ],
            receivedAt: currentDate
        )

        let zoneThreeDate = start.addingTimeInterval(20)
        let zoneFourDate = start.addingTimeInterval(30)
        currentDate = zoneFourDate
        _ = store.ingestBatch(
            [
                makeEnvelope(
                    sessionID: sessionID,
                    sequence: 2,
                    capturedAt: zoneThreeDate,
                    snapshot: zoneSnapshot(
                        elapsedTime: 20,
                        zone: 3,
                        secondsByZone: [0, 10, 0, 0, 0],
                        capturedAt: zoneThreeDate
                    )
                ),
                makeEnvelope(
                    sessionID: sessionID,
                    sequence: 3,
                    capturedAt: zoneFourDate,
                    snapshot: zoneSnapshot(
                        elapsedTime: 30,
                        zone: 4,
                        secondsByZone: [0, 10, 10, 0, 0],
                        capturedAt: zoneFourDate
                    )
                ),
            ],
            receivedAt: currentDate
        )
        expect(
            store.currentHeartRateZoneElapsedTime == 0,
            "the store publishes the latest zone from a coalesced Watch batch"
        )

        currentDate = start.addingTimeInterval(50)
        _ = store.ingestBatch(
            [
                makeEnvelope(
                    sessionID: sessionID,
                    sequence: 4,
                    capturedAt: currentDate,
                    snapshot: zoneSnapshot(
                        elapsedTime: 50,
                        zone: 2,
                        secondsByZone: [0, 10, 10, 20, 0],
                        capturedAt: currentDate
                    )
                ),
            ],
            receivedAt: currentDate
        )
        expect(
            store.currentHeartRateZoneElapsedTime == 10,
            "authoritative Watch totals prevent a coalesced gap from inflating the stale zone"
        )
    }
#endif

    private mutating func testAltitudeRequiresVerticalAccuracy() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_450)
        let locationWithoutAccuracy = WorkoutLocationV1(
            latitude: 1.35,
            longitude: 103.82,
            capturedAt: now,
            horizontalAccuracy: 5,
            altitude: 12,
            verticalAccuracy: nil,
            course: nil,
            speed: nil
        )
        let invalid = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                location: locationWithoutAccuracy,
                availability: [.location, .altitude]
            )
        )
        expectThrows(.invalidLocation, "altitude without vertical accuracy") {
            try WorkoutContractCodec.validate(invalid)
        }

        let horizontalOnly = makeEnvelope(
            sequence: 1,
            capturedAt: now,
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now.addingTimeInterval(-30),
                location: WorkoutLocationV1(
                    latitude: 1.35,
                    longitude: 103.82,
                    capturedAt: now,
                    horizontalAccuracy: 5,
                    altitude: nil,
                    verticalAccuracy: nil,
                    course: nil,
                    speed: nil
                ),
                availability: [.location]
            )
        )
        do {
            try WorkoutContractCodec.validate(horizontalOnly)
        } catch {
            expect(false, "location without altitude should remain valid: \(error)")
        }
    }

    private mutating func testUnknownErrorCodesBecomeSafeGenericCodes() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_500)
        let envelope = WorkoutEnvelopeV1(
            kind: .error,
            sessionID: UUID(uuidString: "BBBBBBBB-1111-2222-3333-444444444444")!,
            sessionToken: 9,
            sequence: 1,
            capturedAt: now,
            error: WorkoutErrorV1(code: .sessionFailed)
        )
        do {
            let encoded = try PropertyListEncoder().encode(envelope)
            var plist = try PropertyListSerialization.propertyList(from: encoded, format: nil) as! [String: Any]
            var errorPayload = plist["error"] as! [String: Any]
            errorPayload["code"] = "private raw error details"
            plist["error"] = errorPayload
            let futureData = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .binary,
                options: 0
            )
            let decoded = try WorkoutContractCodec.decode(futureData)
            expect(decoded.error?.code == .unknown, "unknown error code should map to a safe generic code")
            let reencoded = try WorkoutContractCodec.encode(decoded)
            let roundTrip = try WorkoutContractCodec.decode(reencoded)
            expect(roundTrip.error?.code == .unknown, "raw unknown error text must not survive re-encoding")
        } catch {
            expect(false, "unknown error fixture threw \(error)")
        }
    }

    private mutating func testSessionIdentityCannotDrift() {
        var gate = WorkoutEnvelopeSequenceGate()
        let sessionID = UUID(uuidString: "ABABABAB-1111-2222-3333-444444444444")!
        let start = Date(timeIntervalSinceReferenceDate: 800_002_500)

        func envelope(
            state: WorkoutSessionStateV1 = .running,
            token: UInt16 = 41,
            sequence: UInt64,
            startDate: Date?
        ) -> WorkoutEnvelopeV1 {
            makeEnvelope(
                sessionID: sessionID,
                sessionToken: token,
                sequence: sequence,
                capturedAt: start.addingTimeInterval(600),
                snapshot: WorkoutSnapshotV1(state: state, startDate: startDate)
            )
        }

        do {
            expect(
                try gate.ingest(envelope(sequence: 1, startDate: start)),
                "first snapshot should establish session identity"
            )
            expect(
                !(try gate.ingest(envelope(token: 42, sequence: 2, startDate: start))),
                "same UUID must not change its session token"
            )
            expect(
                !(try gate.ingest(
                    envelope(sequence: 2, startDate: start.addingTimeInterval(300))
                )),
                "same UUID must not rewrite its workout start date"
            )
            expect(
                !(try gate.ingest(envelope(state: .failed, sequence: 2, startDate: nil))),
                "same UUID must not drop an established workout start date"
            )
            expect(gate.highestSequenceBySession[sessionID] == 1, "identity drift must not advance sequence")
            expect(gate.sessionTokenBySession[sessionID] == 41, "canonical token must remain unchanged")
            expect(gate.startDateBySession[sessionID] == start, "canonical start date must remain unchanged")
            expect(gate.currentSnapshotEnvelope?.sequence == 1, "identity drift must not replace current state")
            expect(
                try gate.ingest(envelope(state: .paused, sequence: 2, startDate: start)),
                "original session identity should remain usable after rejected drift"
            )
        } catch {
            expect(false, "session identity fixture threw \(error)")
        }
    }

    private mutating func testSameSessionCanAdvanceToNewTransportGeneration() {
        var gate = WorkoutEnvelopeSequenceGate()
        let sessionID = UUID(uuidString: "ACACACAC-1111-2222-3333-444444444444")!
        let originalGeneration = UUID(
            uuidString: "ACACACAC-0000-0000-0000-000000000001"
        )!
        let recoveredGeneration = UUID(
            uuidString: "ACACACAC-0000-0000-0000-000000000002"
        )!
        let olderCandidateGeneration = UUID(
            uuidString: "ACACACAC-0000-0000-0000-000000000003"
        )!
        let terminalGeneration = UUID(
            uuidString: "ACACACAC-0000-0000-0000-000000000004"
        )!
        let start = Date(timeIntervalSinceReferenceDate: 800_002_700)

        func envelope(
            token: UInt16,
            generation: UUID,
            sequence: UInt64,
            capturedOffset: TimeInterval,
            state: WorkoutSessionStateV1
        ) -> WorkoutEnvelopeV1 {
            makeEnvelope(
                sessionID: sessionID,
                sessionToken: token,
                transportGenerationID: generation,
                sequence: sequence,
                capturedAt: start.addingTimeInterval(capturedOffset),
                snapshot: WorkoutSnapshotV1(state: state, startDate: start)
            )
        }

        do {
            expect(
                try gate.ingest(
                    envelope(
                        token: 41,
                        generation: originalGeneration,
                        sequence: 9,
                        capturedOffset: 10,
                        state: .running
                    )
                ),
                "the original generation should be accepted"
            )
            expect(
                try gate.ingest(
                    envelope(
                        token: 42,
                        generation: recoveredGeneration,
                        sequence: 4,
                        capturedOffset: 20,
                        state: .paused
                    )
                ),
                "the first observed envelope of a newer generation need not be sequence one"
            )
            expect(gate.sessionTokenBySession[sessionID] == 42, "new token should become canonical")
            expect(gate.highestSequenceBySession[sessionID] == 4, "new generation should reset sequence")
            expect(
                gate.transportGenerationBySession[sessionID] == recoveredGeneration,
                "the explicit transport generation should become canonical"
            )
            expect(
                !(try gate.ingest(
                    envelope(
                        token: 41,
                        generation: originalGeneration,
                        sequence: 10,
                        capturedOffset: 30,
                        state: .paused
                    )
                )),
                "an old generation cannot resume after reset"
            )
            expect(
                !(try gate.ingest(
                    envelope(
                        token: 43,
                        generation: olderCandidateGeneration,
                        sequence: 2,
                        capturedOffset: 15,
                        state: .paused
                    )
                )),
                "an older captured generation reset must be rejected"
            )
            expect(
                try gate.ingest(
                    envelope(
                        token: 42,
                        generation: recoveredGeneration,
                        sequence: 5,
                        capturedOffset: 21,
                        state: .running
                    )
                ),
                "the accepted generation should continue monotonically"
            )
            expect(
                try gate.ingest(
                    envelope(
                        token: 43,
                        generation: terminalGeneration,
                        sequence: 8,
                        capturedOffset: 40,
                        state: .ended
                    )
                ),
                "reconnect may first observe an ended snapshot from an unseen generation"
            )
            expect(
                !(try gate.ingest(
                    envelope(
                        token: 42,
                        generation: recoveredGeneration,
                        sequence: 6,
                        capturedOffset: 50,
                        state: .ended
                    )
                )),
                "a terminal reset must not reopen its retired predecessor"
            )

            var legacyGate = WorkoutEnvelopeSequenceGate()
            let legacySessionID = UUID(
                uuidString: "ACACACAC-1111-2222-3333-555555555555"
            )!
            let legacyToken: UInt16 = 51
            expect(
                try legacyGate.ingest(
                    makeEnvelope(
                        sessionID: legacySessionID,
                        sessionToken: legacyToken,
                        sequence: 9,
                        capturedAt: start.addingTimeInterval(60),
                        snapshot: WorkoutSnapshotV1(
                            state: .running,
                            startDate: start
                        )
                    )
                ),
                "a legacy generation-less envelope should seed migration state"
            )
            expect(
                try legacyGate.ingest(
                    makeEnvelope(
                        sessionID: legacySessionID,
                        sessionToken: legacyToken,
                        transportGenerationID: recoveredGeneration,
                        sequence: 1,
                        capturedAt: start.addingTimeInterval(70),
                        snapshot: WorkoutSnapshotV1(
                            state: .paused,
                            startDate: start
                        )
                    )
                ),
                "the first explicit generation must migrate legacy state even when its token collides"
            )
            expect(
                !(try legacyGate.ingest(
                    makeEnvelope(
                        sessionID: legacySessionID,
                        sessionToken: legacyToken,
                        sequence: 10,
                        capturedAt: start.addingTimeInterval(80),
                        snapshot: WorkoutSnapshotV1(
                            state: .running,
                            startDate: start
                        )
                    )
                )),
                "generation-less legacy replay must remain retired after migration"
            )
        } catch {
            expect(false, "transport generation fixtures threw \(error)")
        }
    }

    private mutating func testSameSessionLifecycleRejectsRegressions() {
        var gate = WorkoutEnvelopeSequenceGate()
        let sessionID = UUID(uuidString: "EEEEEEEE-1111-2222-3333-444444444444")!
        let start = Date(timeIntervalSinceReferenceDate: 800_003_000)

        func envelope(_ state: WorkoutSessionStateV1, sequence: UInt64) -> WorkoutEnvelopeV1 {
            makeEnvelope(
                sessionID: sessionID,
                sequence: sequence,
                capturedAt: start.addingTimeInterval(TimeInterval(sequence)),
                snapshot: WorkoutSnapshotV1(state: state, startDate: start)
            )
        }

        do {
            expect(try gate.ingest(envelope(.running, sequence: 1)), "running should seed the gate")
            expect(try gate.ingest(envelope(.paused, sequence: 2)), "running may transition to paused")
            expect(try gate.ingest(envelope(.running, sequence: 3)), "paused may resume to running")
            expect(
                !(try gate.ingest(envelope(.starting, sequence: 4))),
                "running must not regress to starting"
            )
            expect(gate.highestSequenceBySession[sessionID] == 3, "rejected regression must not advance sequence")
            expect(gate.currentSnapshotEnvelope?.snapshot?.state == .running, "rejected regression must not replace state")
            expect(try gate.ingest(envelope(.ended, sequence: 4)), "lossy delivery may jump running to ended")
            expect(
                !(try gate.ingest(envelope(.running, sequence: 5))),
                "ended must not regress to running"
            )
            expect(gate.highestSequenceBySession[sessionID] == 4, "terminal regression must not advance sequence")
            expect(gate.currentSnapshotEnvelope?.snapshot?.state == .ended, "ended state must remain visible")
        } catch {
            expect(false, "same-session lifecycle fixture threw \(error)")
        }
    }

    private mutating func testBatchPublishesOnlyLatestCoherentSnapshot() {
        var gate = WorkoutEnvelopeSequenceGate()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let batch = [
            makeEnvelope(sequence: 1, snapshot: WorkoutSnapshotV1(state: .starting, startDate: start)),
            makeEnvelope(sequence: 3, snapshot: WorkoutSnapshotV1(state: .running, startDate: start)),
            makeEnvelope(sequence: 2, snapshot: WorkoutSnapshotV1(state: .starting, startDate: start)),
            makeEnvelope(sequence: 4, snapshot: WorkoutSnapshotV1(state: .paused, startDate: start)),
        ]
        let result = gate.ingestBatch(batch)
        expect(result.latestSnapshotEnvelope?.sequence == 4, "batch should publish only the newest accepted sequence")
        expect(result.latestSnapshotEnvelope?.snapshot?.state == .paused, "batch should publish the latest coherent state")
        expect(result.rejections.isEmpty, "valid out-of-order snapshots should not be malformed rejections")
    }

    private mutating func testBatchSkipsInvalidItemsAndContinues() {
        var gate = WorkoutEnvelopeSequenceGate()
        let validOne = makeEnvelope(sequence: 1)
        let invalid = makeEnvelope(sessionToken: 0, sequence: 2)
        let validThree = makeEnvelope(sequence: 3)

        let result = gate.ingestBatch([validOne, invalid, validThree])
        expect(result.latestSnapshotEnvelope?.sequence == 3, "batch must continue to the newest valid snapshot")
        expect(result.rejections == [
            WorkoutEnvelopeBatchRejection(index: 1, error: .zeroSessionToken),
        ], "batch must report the rejected item")
        expect(gate.currentSnapshotEnvelope?.sequence == 3, "gate state should match the published result")
    }

    private mutating func testNewerTerminalSessionReplacesOlderTerminalSession() {
        var gate = WorkoutEnvelopeSequenceGate()
        let oldStart = Date(timeIntervalSinceReferenceDate: 800_002_000)
        let newStart = oldStart.addingTimeInterval(600)
        let oldID = UUID(uuidString: "CCCCCCCC-1111-2222-3333-444444444444")!
        let newID = UUID(uuidString: "DDDDDDDD-1111-2222-3333-444444444444")!

        do {
            expect(
                try gate.ingest(
                    makeEnvelope(
                        sessionID: oldID,
                        sequence: 1,
                        capturedAt: oldStart.addingTimeInterval(300),
                        snapshot: WorkoutSnapshotV1(state: .ended, startDate: oldStart)
                    )
                ),
                "old terminal session should seed the gate"
            )
            expect(
                try gate.ingest(
                    makeEnvelope(
                        sessionID: newID,
                        sequence: 1,
                        capturedAt: newStart.addingTimeInterval(300),
                        snapshot: WorkoutSnapshotV1(state: .ended, startDate: newStart)
                    )
                ),
                "newer terminal session should replace the old summary"
            )
            expect(gate.currentSnapshotEnvelope?.sessionID == newID, "new terminal summary should be visible")
        } catch {
            expect(false, "terminal replacement threw \(error)")
        }
    }

    private mutating func testOlderSessionCannotReplaceNewerActiveSession() {
        var gate = WorkoutEnvelopeSequenceGate()
        let newerStart = Date(timeIntervalSinceReferenceDate: 800_001_000)
        let olderStart = newerStart.addingTimeInterval(-600)
        let newerID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let olderID = UUID(uuidString: "AAAAAAAA-2222-3333-4444-555555555555")!

        do {
            expect(
                try gate.ingest(
                    makeEnvelope(
                        sessionID: newerID,
                        sequence: 1,
                        capturedAt: newerStart,
                        snapshot: WorkoutSnapshotV1(state: .running, startDate: newerStart)
                    )
                ),
                "newer active session should be accepted"
            )
            expect(
                !(try gate.ingest(
                    makeEnvelope(
                        sessionID: olderID,
                        sequence: 99,
                        capturedAt: newerStart.addingTimeInterval(60),
                        snapshot: WorkoutSnapshotV1(state: .running, startDate: olderStart)
                    )
                )),
                "older session must not replace the newer active session"
            )
            expect(gate.currentSnapshotEnvelope?.sessionID == newerID, "newer session should remain visible")
        } catch {
            expect(false, "cross-session gate threw \(error)")
        }
    }

    private mutating func testActiveSessionReplacesIdlePlaceholderRegardlessOfDeliveryOrder() {
        var gate = WorkoutEnvelopeSequenceGate()
        let activeStart = Date(timeIntervalSinceReferenceDate: 800_003_500)
        let idleID = UUID(uuidString: "12121212-1111-2222-3333-444444444444")!
        let activeID = UUID(uuidString: "34343434-1111-2222-3333-444444444444")!

        do {
            expect(
                try gate.ingest(
                    makeEnvelope(
                        sessionID: idleID,
                        sequence: 1,
                        capturedAt: activeStart.addingTimeInterval(120),
                        snapshot: WorkoutSnapshotV1(state: .idle)
                    )
                ),
                "idle placeholder should seed the gate"
            )
            expect(
                try gate.ingest(
                    makeEnvelope(
                        sessionID: activeID,
                        sequence: 1,
                        capturedAt: activeStart.addingTimeInterval(60),
                        snapshot: WorkoutSnapshotV1(state: .running, startDate: activeStart)
                    )
                ),
                "active workout must replace an idle placeholder delivered first"
            )
            expect(gate.currentSnapshotEnvelope?.sessionID == activeID, "active workout should be visible")
        } catch {
            expect(false, "active-over-idle fixture threw \(error)")
        }
    }

    private mutating func testActiveSessionReplacesFailedAttemptRegardlessOfDeliveryOrder() {
        var gate = WorkoutEnvelopeSequenceGate()
        let activeStart = Date(timeIntervalSinceReferenceDate: 800_004_000)
        let failedID = UUID(uuidString: "FFFFFFFF-1111-2222-3333-444444444444")!
        let activeID = UUID(uuidString: "99999999-1111-2222-3333-444444444444")!

        do {
            expect(
                try gate.ingest(
                    makeEnvelope(
                        sessionID: failedID,
                        sequence: 1,
                        capturedAt: activeStart.addingTimeInterval(120),
                        snapshot: WorkoutSnapshotV1(state: .failed)
                    )
                ),
                "failed start attempt should seed the gate"
            )
            expect(
                try gate.ingest(
                    makeEnvelope(
                        sessionID: activeID,
                        sequence: 1,
                        capturedAt: activeStart.addingTimeInterval(60),
                        snapshot: WorkoutSnapshotV1(state: .running, startDate: activeStart)
                    )
                ),
                "active workout must replace a failed attempt even when delivered in reverse order"
            )
            expect(gate.currentSnapshotEnvelope?.sessionID == activeID, "active workout should be visible")
        } catch {
            expect(false, "active-over-failed fixture threw \(error)")
        }
    }

    private mutating func testEndedSessionReplacesOnlyOlderPlaceholders() {
        let workoutStart = Date(timeIntervalSinceReferenceDate: 800_004_500)
        for (index, placeholderState) in [
            WorkoutSessionStateV1.idle,
            .failed,
        ].enumerated() {
            let placeholderID = UUID(uuidString: index == 0
                ? "56565656-1111-2222-3333-444444444444"
                : "78787878-1111-2222-3333-444444444444")!
            let endedID = UUID(uuidString: index == 0
                ? "90909090-1111-2222-3333-444444444444"
                : "A0A0A0A0-1111-2222-3333-444444444444")!
            let endedEnvelope = makeEnvelope(
                sessionID: endedID,
                sequence: 1,
                capturedAt: workoutStart.addingTimeInterval(200),
                snapshot: WorkoutSnapshotV1(state: .ended, startDate: workoutStart)
            )

            var acceptsNewerEnded = WorkoutEnvelopeSequenceGate()
            var rejectsOlderEnded = WorkoutEnvelopeSequenceGate()
            do {
                expect(
                    try acceptsNewerEnded.ingest(
                        makeEnvelope(
                            sessionID: placeholderID,
                            sequence: 1,
                            capturedAt: workoutStart.addingTimeInterval(100),
                            snapshot: WorkoutSnapshotV1(state: placeholderState)
                        )
                    ),
                    "\(placeholderState) should seed newer-ended acceptance gate"
                )
                expect(
                    try acceptsNewerEnded.ingest(endedEnvelope),
                    "later-captured ended workout should replace \(placeholderState)"
                )
                expect(
                    acceptsNewerEnded.currentSnapshotEnvelope?.sessionID == endedID,
                    "ended workout should be visible after \(placeholderState)"
                )

                expect(
                    try rejectsOlderEnded.ingest(
                        makeEnvelope(
                            sessionID: placeholderID,
                            sequence: 1,
                            capturedAt: workoutStart.addingTimeInterval(300),
                            snapshot: WorkoutSnapshotV1(state: placeholderState)
                        )
                    ),
                    "\(placeholderState) should seed older-ended rejection gate"
                )
                expect(
                    !(try rejectsOlderEnded.ingest(endedEnvelope)),
                    "older-captured ended workout must not replace \(placeholderState)"
                )
                expect(
                    rejectsOlderEnded.currentSnapshotEnvelope?.sessionID == placeholderID,
                    "newer \(placeholderState) should remain visible"
                )
                expect(
                    rejectsOlderEnded.highestSequenceBySession[endedID] == nil,
                    "rejected ended workout must not mutate sequence state"
                )
            } catch {
                expect(false, "ended-over-\(placeholderState) fixture threw \(error)")
            }
        }
    }

    private mutating func testWatchLifecycleRequiresHealthKitConfirmationAndFinalizesOnce() {
        var saveReducer = WorkoutLifecycleReducer()
        expect(saveReducer.apply(.requestStart), "idle workout should accept start")
        expect(saveReducer.state == .starting, "start request should enter starting")
        expect(!saveReducer.apply(.requestStart), "active workout must reject a second start")
        expect(saveReducer.apply(.sessionRunning), "HealthKit running callback should be accepted")
        expect(saveReducer.state == .running, "delegate callback should enter running")

        // There is intentionally no optimistic pause request event. The state
        // remains running until HealthKit confirms the transition.
        expect(saveReducer.state == .running, "pause request alone must not change state")
        expect(saveReducer.apply(.sessionPaused), "HealthKit pause callback should be accepted")
        expect(saveReducer.state == .paused, "delegate callback should enter paused")
        expect(saveReducer.apply(.sessionRunning), "HealthKit resume callback should be accepted")

        expect(
            saveReducer.apply(.requestEnd(.save)),
            "running workout should accept save finalization"
        )
        expect(saveReducer.state == .ending, "end request should enter ending")
        expect(
            saveReducer.claimFinalization() == .save,
            "save disposition should be claimable exactly once"
        )
        expect(
            saveReducer.claimFinalization() == nil,
            "duplicate stopped callbacks must not save a second workout"
        )
        saveReducer.releaseFinalizationClaimForRetry()
        expect(
            saveReducer.claimFinalization() == .save,
            "a retryable save failure should make the same disposition claimable again"
        )
        expect(
            saveReducer.claimFinalization() == nil,
            "a retried finalization must still be single-claim"
        )
        expect(saveReducer.apply(.sessionEnded), "successful finalization should enter ended")
        expect(!saveReducer.apply(.fail), "ended workout must not regress to failed")

        var discardReducer = WorkoutLifecycleReducer()
        expect(discardReducer.apply(.requestStart), "discard fixture should start")
        expect(discardReducer.apply(.sessionRunning), "discard fixture should run")
        expect(discardReducer.apply(.requestEnd(.discard)), "discard should enter ending")
        expect(
            discardReducer.claimFinalization() == .discard,
            "discard disposition should not become save"
        )
        expect(discardReducer.apply(.sessionEnded), "discard should finish as ended")
        expect(discardReducer.apply(.reset), "summary dismissal should return to idle")
    }

    private mutating func testWorkoutLifecycleFailureAndLateRunningPolicies() {
        expect(
            WorkoutSessionFailurePolicy.action(for: .starting) == .failStart,
            "pre-running session failure must discard the startup attempt"
        )
        expect(
            WorkoutSessionFailurePolicy.action(for: .running) == .savePartialWorkout,
            "a running failure may save the partial workout"
        )
        expect(
            WorkoutSessionFailurePolicy.action(for: .paused) == .savePartialWorkout,
            "a paused failure may save the partial workout"
        )
        expect(
            WorkoutSessionFailurePolicy.action(for: .ending) == .finishRequestedDisposition,
            "a failure during ending must retain the requested save/discard disposition"
        )
        expect(
            WorkoutSessionFailurePolicy.action(for: .ended) == .ignore,
            "terminal sessions must ignore later failures"
        )
        expect(
            WorkoutRunningCallbackPolicy.action(for: .starting) == .enterRunning,
            "normal startup should accept the running callback"
        )
        expect(
            WorkoutRunningCallbackPolicy.action(for: .ending) == .stopSession,
            "a late running callback after quick end must reissue session stop"
        )
        expect(
            WorkoutRunningCallbackPolicy.action(for: .failed) == .ignore,
            "a failed workout must ignore a late running callback"
        )
        expect(
            WorkoutRecoveredSessionAdoptionPolicy.action(
                wasEndedBeforeMetadataRepair: false,
                isEndedAfterMetadataRepair: true,
                pendingDisposition: .save
            ) == .adoptEnded(.save),
            "a session that ends during metadata repair must retain its pending save"
        )
        expect(
            WorkoutRecoveredSessionAdoptionPolicy.action(
                wasEndedBeforeMetadataRepair: true,
                isEndedAfterMetadataRepair: true,
                pendingDisposition: .discard
            ) == .adoptEnded(.discard),
            "an already-ended recovery must retain its pending discard"
        )
        expect(
            WorkoutRecoveredSessionAdoptionPolicy.action(
                wasEndedBeforeMetadataRepair: false,
                isEndedAfterMetadataRepair: true,
                pendingDisposition: nil
            ) == .adoptEnded(.save),
            "an unexpectedly ended recovery should default to preserving the ride"
        )
        expect(
            WorkoutRecoveredSessionAdoptionPolicy.action(
                wasEndedBeforeMetadataRepair: false,
                isEndedAfterMetadataRepair: false,
                isStoppedAfterMetadataRepair: true,
                pendingDisposition: nil
            ) == .adoptStopped(.save),
            "an unexpectedly stopped recovery must create a durable default save request"
        )
        expect(
            WorkoutRecoveredSessionAdoptionPolicy.action(
                wasEndedBeforeMetadataRepair: false,
                isEndedAfterMetadataRepair: false,
                isStoppedAfterMetadataRepair: true,
                pendingDisposition: .discard
            ) == .adoptStopped(.discard),
            "a stopped recovery must preserve an existing discard request"
        )
        expect(
            WorkoutRecoveredSessionAdoptionPolicy.action(
                wasEndedBeforeMetadataRepair: false,
                isEndedAfterMetadataRepair: false,
                pendingDisposition: .discard
            ) == .adopt,
            "a still-active session should remain eligible for recovery adoption"
        )
    }

    private mutating func testWorkoutFinalizationOrchestratorOrderAndFailures() async {
        enum SyntheticFailure: Error {
            case expected
        }

        var saveEvents: [String] = []
        do {
            let outcome = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                discardWorkout: { saveEvents.append("discard-workout") },
                discardRoute: { saveEvents.append("discard-route") },
                prepareRoute: {
                    saveEvents.append("prepare-route")
                    return WorkoutPreparedRoute(
                        routeKnownPresent: true,
                        distanceMeters: 123
                    )
                },
                markPreparedRoute: { status in
                    saveEvents.append("route-\(status.rawValue)")
                },
                endCollection: { saveEvents.append("end-collection") },
                markCollectionEnded: { saveEvents.append("phase-collection-ended") },
                markFinishAttempted: { saveEvents.append("phase-finish-attempted") },
                finishWorkout: { saveEvents.append("finish-workout") },
                markFinishFailed: { saveEvents.append("phase-finish-failed") },
                markWorkoutSaved: { saveEvents.append("phase-workout-saved") },
                endSession: { saveEvents.append("end-session") }
            )
            expect(
                outcome == .saved(
                    WorkoutPreparedRoute(
                        routeKnownPresent: true,
                        distanceMeters: 123
                    )
                ),
                "save orchestrator should return the prepared route exactly"
            )
            expect(
                saveEvents == [
                    "prepare-route",
                    "route-present",
                    "end-collection",
                    "phase-collection-ended",
                    "phase-finish-attempted",
                    "finish-workout",
                    "phase-workout-saved",
                    "end-session",
                ],
                "save orchestrator must flush and finish before ending the session"
            )
        } catch {
            expect(false, "successful finalization orchestrator threw \(error)")
        }

        var discardEvents: [String] = []
        do {
            let outcome = try await WorkoutFinalizationOrchestrator.run(
                disposition: .discard,
                discardWorkout: { discardEvents.append("discard-workout") },
                discardRoute: { discardEvents.append("discard-route") },
                prepareRoute: {
                    discardEvents.append("prepare-route")
                    return WorkoutPreparedRoute(
                        routeKnownPresent: true,
                        distanceMeters: 123
                    )
                },
                endCollection: { discardEvents.append("end-collection") },
                finishWorkout: { discardEvents.append("finish-workout") },
                endSession: { discardEvents.append("end-session") }
            )
            expect(outcome == .discarded, "discard orchestrator should return discarded")
            expect(
                discardEvents == ["discard-workout", "discard-route", "end-session"],
                "discard must save nothing before ending the session"
            )
        } catch {
            expect(false, "discard orchestrator threw \(error)")
        }

        var endFailureEvents: [String] = []
        do {
            _ = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                discardWorkout: { endFailureEvents.append("discard-workout") },
                discardRoute: { endFailureEvents.append("discard-route") },
                prepareRoute: {
                    endFailureEvents.append("prepare-route")
                    return WorkoutPreparedRoute(
                        routeKnownPresent: false,
                        distanceMeters: nil
                    )
                },
                endCollection: {
                    endFailureEvents.append("end-collection")
                    throw SyntheticFailure.expected
                },
                finishWorkout: { endFailureEvents.append("finish-workout") },
                endSession: { endFailureEvents.append("end-session") }
            )
            expect(false, "end-collection failure should propagate")
        } catch {
            expect(
                endFailureEvents == [
                    "prepare-route",
                    "end-collection",
                ],
                "endCollection failure must retain the stopped builder, route, and session for retry"
            )
        }
        do {
            let outcome = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                discardWorkout: { endFailureEvents.append("retry-discard-workout") },
                discardRoute: { endFailureEvents.append("retry-discard-route") },
                prepareRoute: {
                    endFailureEvents.append("retry-prepare-route")
                    return WorkoutPreparedRoute(routeKnownPresent: false, distanceMeters: nil)
                },
                endCollection: { endFailureEvents.append("retry-end-collection") },
                finishWorkout: { endFailureEvents.append("retry-finish-workout") },
                endSession: { endFailureEvents.append("retry-end-session") }
            )
            expect(
                outcome == .saved(
                    WorkoutPreparedRoute(routeKnownPresent: false, distanceMeters: nil)
                ),
                "endCollection failure should be retryable without a destructive cleanup"
            )
            expect(
                endFailureEvents == [
                    "prepare-route",
                    "end-collection",
                    "retry-prepare-route",
                    "retry-end-collection",
                    "retry-finish-workout",
                    "retry-end-session",
                ],
                "a retried full save should finish once and only then end session mode"
            )
        } catch {
            expect(false, "end-collection retry should succeed: \(error)")
        }

        var finishFailureEvents: [String] = []
        do {
            _ = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                discardWorkout: { finishFailureEvents.append("discard-workout") },
                discardRoute: { finishFailureEvents.append("discard-route") },
                prepareRoute: {
                    finishFailureEvents.append("prepare-route")
                    return WorkoutPreparedRoute(
                        routeKnownPresent: false,
                        distanceMeters: nil
                    )
                },
                markPreparedRoute: { status in
                    finishFailureEvents.append("route-\(status.rawValue)")
                },
                endCollection: { finishFailureEvents.append("end-collection") },
                markCollectionEnded: {
                    finishFailureEvents.append("phase-collection-ended")
                },
                markFinishAttempted: {
                    finishFailureEvents.append("phase-finish-attempted")
                },
                finishWorkout: {
                    finishFailureEvents.append("finish-workout")
                    throw SyntheticFailure.expected
                },
                markFinishFailed: {
                    finishFailureEvents.append("phase-finish-failed")
                },
                endSession: { finishFailureEvents.append("end-session") }
            )
            expect(false, "finish-workout failure should propagate")
        } catch {
            expect(
                    finishFailureEvents
                    == [
                        "prepare-route",
                        "route-unavailable",
                        "end-collection",
                        "phase-collection-ended",
                        "phase-finish-attempted",
                        "finish-workout",
                        "phase-finish-failed",
                    ],
                    "finish failure must retain the collection-ended builder and session for reconciliation"
            )
        }
        do {
            let outcome = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                saveMode: .finishOnly,
                discardWorkout: { finishFailureEvents.append("retry-discard-workout") },
                discardRoute: { finishFailureEvents.append("retry-discard-route") },
                prepareRoute: {
                    finishFailureEvents.append("retry-prepare-route")
                    return WorkoutPreparedRoute(routeKnownPresent: false, distanceMeters: nil)
                },
                endCollection: { finishFailureEvents.append("retry-end-collection") },
                markFinishAttempted: {
                    finishFailureEvents.append("retry-phase-finish-attempted")
                },
                finishWorkout: { finishFailureEvents.append("retry-finish-workout") },
                markWorkoutSaved: {
                    finishFailureEvents.append("phase-workout-saved")
                },
                endSession: { finishFailureEvents.append("retry-end-session") }
            )
            expect(
                outcome == .saved(
                    WorkoutPreparedRoute(routeStatus: .unknown, distanceMeters: nil)
                ),
                "finishWorkout failure should retry from the durable collection-ended phase"
            )
            expect(
                finishFailureEvents == [
                    "prepare-route",
                    "route-unavailable",
                    "end-collection",
                    "phase-collection-ended",
                    "phase-finish-attempted",
                    "finish-workout",
                    "phase-finish-failed",
                    "retry-phase-finish-attempted",
                    "retry-finish-workout",
                    "phase-workout-saved",
                    "retry-end-session",
                ],
                "finish retry must not end collection or discard resources a second time"
            )
        } catch {
            expect(false, "finish-workout retry should succeed: \(error)")
        }

        var finishMarkerFailureEvents: [String] = []
        do {
            _ = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                saveMode: .finishOnly,
                discardWorkout: { finishMarkerFailureEvents.append("discard-workout") },
                discardRoute: { finishMarkerFailureEvents.append("discard-route") },
                prepareRoute: {
                    finishMarkerFailureEvents.append("prepare-route")
                    return WorkoutPreparedRoute(routeStatus: .unknown, distanceMeters: nil)
                },
                endCollection: { finishMarkerFailureEvents.append("end-collection") },
                markFinishAttempted: {
                    finishMarkerFailureEvents.append("phase-finish-attempted")
                    throw SyntheticFailure.expected
                },
                finishWorkout: { finishMarkerFailureEvents.append("finish-workout") },
                endSession: { finishMarkerFailureEvents.append("end-session") }
            )
            expect(false, "finish-attempt persistence failure should propagate")
        } catch {
            expect(
                finishMarkerFailureEvents == ["phase-finish-attempted"],
                "the HealthKit save call must not start unless its commit-unknown marker is durable"
            )
        }

        var savedMarkerFailureEvents: [String] = []
        do {
            let outcome = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                saveMode: .finishOnly,
                discardWorkout: { savedMarkerFailureEvents.append("discard-workout") },
                discardRoute: { savedMarkerFailureEvents.append("discard-route") },
                prepareRoute: {
                    savedMarkerFailureEvents.append("prepare-route")
                    return WorkoutPreparedRoute(routeStatus: .unknown, distanceMeters: nil)
                },
                recoveredRouteStatus: .unknown,
                endCollection: { savedMarkerFailureEvents.append("end-collection") },
                markFinishAttempted: {
                    savedMarkerFailureEvents.append("phase-finish-attempted")
                },
                finishWorkout: { savedMarkerFailureEvents.append("finish-workout") },
                markWorkoutSaved: {
                    savedMarkerFailureEvents.append("phase-workout-saved")
                    throw SyntheticFailure.expected
                },
                workoutSavedPersistenceFailed: {
                    savedMarkerFailureEvents.append("phase-workout-saved-pending")
                },
                endSession: { savedMarkerFailureEvents.append("end-session") }
            )
            expect(
                outcome == .saved(
                    WorkoutPreparedRoute(routeStatus: .unknown, distanceMeters: nil)
                ),
                "a definitive HealthKit finish success must remain saved when its local marker fails"
            )
            expect(
                savedMarkerFailureEvents == [
                    "phase-finish-attempted",
                    "finish-workout",
                    "phase-workout-saved",
                    "phase-workout-saved-pending",
                    "end-session",
                ],
                "marker failure after finish success must still end session exactly once"
            )
        } catch {
            expect(false, "post-success marker failure must not replace HealthKit success: \(error)")
        }

        var rollbackFailureEvents: [String] = []
        do {
            _ = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                saveMode: .finishOnly,
                discardWorkout: { rollbackFailureEvents.append("discard-workout") },
                discardRoute: { rollbackFailureEvents.append("discard-route") },
                prepareRoute: {
                    rollbackFailureEvents.append("prepare-route")
                    return WorkoutPreparedRoute(routeStatus: .unknown, distanceMeters: nil)
                },
                endCollection: { rollbackFailureEvents.append("end-collection") },
                markFinishAttempted: {
                    rollbackFailureEvents.append("phase-finish-attempted")
                },
                finishWorkout: {
                    rollbackFailureEvents.append("finish-workout")
                    throw SyntheticFailure.expected
                },
                markFinishFailed: {
                    rollbackFailureEvents.append("phase-finish-failed")
                    throw SyntheticFailure.expected
                },
                endSession: { rollbackFailureEvents.append("end-session") }
            )
            expect(false, "failed rollback persistence should remain retryable in memory")
        } catch WorkoutFinalizationPersistenceError.finishFailureRollbackPending {
            expect(
                rollbackFailureEvents == [
                    "phase-finish-attempted",
                    "finish-workout",
                    "phase-finish-failed",
                ],
                "known finish failure must not end or call finish again before rollback persists"
            )
        } catch {
            expect(false, "rollback persistence failure used the wrong error: \(error)")
        }

        var collectionEndedRecoveryEvents: [String] = []
        do {
            let outcome = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                saveMode: .finishOnly,
                discardWorkout: { collectionEndedRecoveryEvents.append("discard-workout") },
                discardRoute: { collectionEndedRecoveryEvents.append("discard-route") },
                completeAlreadySavedRoute: {
                    collectionEndedRecoveryEvents.append("complete-saved-route")
                },
                prepareRoute: {
                    collectionEndedRecoveryEvents.append("prepare-route")
                    return WorkoutPreparedRoute(routeKnownPresent: true, distanceMeters: 1)
                },
                recoveredRouteStatus: .present,
                endCollection: { collectionEndedRecoveryEvents.append("end-collection") },
                markCollectionEnded: {
                    collectionEndedRecoveryEvents.append("phase-collection-ended")
                },
                markFinishAttempted: {
                    collectionEndedRecoveryEvents.append("phase-finish-attempted")
                },
                finishWorkout: { collectionEndedRecoveryEvents.append("finish-workout") },
                markWorkoutSaved: {
                    collectionEndedRecoveryEvents.append("phase-workout-saved")
                },
                endSession: { collectionEndedRecoveryEvents.append("end-session") }
            )
            expect(
                outcome == .saved(
                    WorkoutPreparedRoute(routeStatus: .present, distanceMeters: nil)
                ),
                "collection-ended recovery should report an honest unknown route"
            )
            expect(
                collectionEndedRecoveryEvents == [
                    "phase-finish-attempted",
                    "finish-workout",
                    "phase-workout-saved",
                    "end-session",
                ],
                "collection-ended recovery must invoke the save adapter once without ending collection again"
            )
        } catch {
            expect(false, "collection-ended recovery threw \(error)")
        }

        var alreadySavedRecoveryEvents: [String] = []
        do {
            let outcome = try await WorkoutFinalizationOrchestrator.run(
                disposition: .save,
                saveMode: .alreadySaved,
                discardWorkout: { alreadySavedRecoveryEvents.append("discard-workout") },
                discardRoute: { alreadySavedRecoveryEvents.append("discard-route") },
                completeAlreadySavedRoute: {
                    alreadySavedRecoveryEvents.append("complete-saved-route")
                },
                prepareRoute: {
                    alreadySavedRecoveryEvents.append("prepare-route")
                    return WorkoutPreparedRoute(routeKnownPresent: true, distanceMeters: 1)
                },
                recoveredRouteStatus: .present,
                endCollection: { alreadySavedRecoveryEvents.append("end-collection") },
                markCollectionEnded: {
                    alreadySavedRecoveryEvents.append("phase-collection-ended")
                },
                finishWorkout: { alreadySavedRecoveryEvents.append("finish-workout") },
                markWorkoutSaved: {
                    alreadySavedRecoveryEvents.append("phase-workout-saved")
                },
                endSession: { alreadySavedRecoveryEvents.append("end-session") }
            )
            expect(
                alreadySavedRecoveryEvents == ["complete-saved-route", "end-session"],
                "already-saved recovery must not invoke the workout save adapter a second time"
            )
            expect(
                outcome == .saved(
                    WorkoutPreparedRoute(routeStatus: .present, distanceMeters: nil)
                ),
                "already-saved recovery must retain the durable known-present route state"
            )
        } catch {
            expect(false, "already-saved recovery threw \(error)")
        }
    }

    private mutating func testWorkoutFinishAndRecoveryPolicies() {
        expect(
            WorkoutFinishCallbackPolicy.outcome(
                workoutReturned: true,
                errorReturned: false
            ) == .saved,
            "a returned workout with no error should be a successful save"
        )
        expect(
            WorkoutFinishCallbackPolicy.outcome(
                workoutReturned: false,
                errorReturned: false
            ) == .saved,
            "locked-device nil workout with no error should still be a successful save"
        )
        expect(
            WorkoutFinishCallbackPolicy.outcome(
                workoutReturned: true,
                errorReturned: true
            ) == .failed,
            "an explicit finish error must win over a returned object"
        )
        expect(
            WorkoutRecoveryInitializationPolicy.shouldClearDurableIdentity(after: .none),
            "confirmed absence of an active workout should clear durable identity"
        )
        expect(
            !WorkoutRecoveryInitializationPolicy.shouldClearDurableIdentity(after: .failed),
            "a transient recovery error must preserve durable identity for retry"
        )
        expect(
            WorkoutRecoverySingleFlightPolicy.canStartRetry(
                isWorkoutActive: false,
                isRecovering: false
            ),
            "idle recovery should allow one retry"
        )
        expect(
            !WorkoutRecoverySingleFlightPolicy.canStartRetry(
                isWorkoutActive: false,
                isRecovering: true
            ),
            "an in-flight recovery must reject a second retry"
        )
        expect(
            !WorkoutRecoverySingleFlightPolicy.canStartRetry(
                isWorkoutActive: true,
                isRecovering: false
            ),
            "an attached active workout must reject recovery retry"
        )
        let callbackDate = Date(timeIntervalSinceReferenceDate: 800_019_000)
        let stoppedDate = callbackDate.addingTimeInterval(-15)
        expect(
            WorkoutFinalizationEndDatePolicy.resolve(
                authoritativeEndDate: stoppedDate,
                callbackDate: callbackDate
            ) == stoppedDate,
            "recovered stopped workouts must retain the HealthKit end date"
        )
        expect(
            WorkoutFinalizationEndDatePolicy.resolve(
                authoritativeEndDate: nil,
                callbackDate: callbackDate
            ) == callbackDate,
            "ordinary finalization should use the ended callback date"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .requested,
                builderCollectionEnded: false,
                matchingWorkout: .notFound
            ) == .finalize(.full),
            "requested recovery with no saved match should run full finalization"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .requested,
                builderCollectionEnded: true,
                matchingWorkout: .notFound
            ) == .finalize(.finishOnly),
            "a builder that already ended collection must not end it twice"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .collectionEnded,
                builderCollectionEnded: false,
                matchingWorkout: .notFound
            ) == .finalize(.finishOnly),
            "durable collection-ended state should resume at finishWorkout"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .finishAttempted,
                builderCollectionEnded: true,
                matchingWorkout: .notFound
            ) == .retryReconciliation,
            "one empty query after a finish attempt must remain commit-unknown"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .finishAttempted,
                builderCollectionEnded: true,
                matchingWorkout: .notFound
            ) == .retryReconciliation,
            "repeated no-match queries must never infer that finishWorkout failed"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .finishAttempted,
                builderCollectionEnded: true,
                matchingWorkout: .unavailable
            ) == .retryReconciliation,
            "an unreadable commit-unknown workout must remain explicitly unresolved"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .finishAttempted,
                builderCollectionEnded: true,
                matchingWorkout: .found
            ) == .finalize(.alreadySaved),
            "readable confirmation after a finish attempt must suppress a second save"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .requested,
                builderCollectionEnded: true,
                matchingWorkout: .found
            ) == .finalize(.alreadySaved),
            "a matching stable workout identifier must suppress a second save"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .workoutSaved,
                builderCollectionEnded: true,
                matchingWorkout: .queryFailed
            ) == .finalize(.alreadySaved),
            "durable workout-saved state must remain authoritative during query failure"
        )
        expect(
            WorkoutRecoveredSavePolicy.action(
                phase: .requested,
                builderCollectionEnded: true,
                matchingWorkout: .queryFailed
            ) == .retryReconciliation,
            "ambiguous query failure must not call the save adapter"
        )
    }

    private mutating func testMetricPrecedenceDoesNotCombineOrInventSources() {
        let now = Date(timeIntervalSinceReferenceDate: 800_020_000)
        let healthDistance = WorkoutMetricCandidate(
            value: 1_000,
            capturedAt: now,
            source: .healthKit
        )
        let routeDistance = WorkoutMetricCandidate(
            value: 950,
            capturedAt: now,
            source: .watchRoute
        )
        expect(
            WorkoutMetricPrecedence.cyclingDistance(
                healthKit: healthDistance,
                watchRoute: routeDistance
            ) == healthDistance,
            "HealthKit distance should win without adding route distance"
        )
        expect(
            WorkoutMetricPrecedence.cyclingDistance(
                healthKit: nil,
                watchRoute: routeDistance
            ) == routeDistance,
            "route distance should fill only when HealthKit distance is unavailable"
        )

        let sensorSpeed = WorkoutMetricCandidate(
            value: 8.5,
            capturedAt: now,
            source: .pairedCyclingSensor
        )
        let locationSpeed = WorkoutMetricCandidate(
            value: 7.8,
            capturedAt: now,
            source: .watchLocation
        )
        expect(
            WorkoutMetricPrecedence.currentSpeed(
                pairedSensor: sensorSpeed,
                watchLocation: locationSpeed
            ) == sensorSpeed,
            "paired cycling sensor should win over Watch location"
        )
        expect(
            WorkoutMetricPrecedence.currentSpeed(
                pairedSensor: WorkoutMetricCandidate(
                    value: .nan,
                    capturedAt: now,
                    source: .pairedCyclingSensor
                ),
                watchLocation: locationSpeed
            ) == locationSpeed,
            "invalid sensor speed should fall back to a valid location speed"
        )
        expect(
            WorkoutMetricPrecedence.currentSpeed(
                pairedSensor: WorkoutMetricCandidate(
                    value: 9,
                    capturedAt: now,
                    source: .healthKit
                ),
                watchLocation: nil
            ) == nil,
            "a semantically wrong source must remain unavailable"
        )
    }

    private mutating func testInstantaneousMetricFreshnessAndSpeedFallback() {
        let now = Date(timeIntervalSinceReferenceDate: 800_025_000)
        let sensorAtBoundary = WorkoutMetricCandidate(
            value: 8.5,
            capturedAt: now.addingTimeInterval(
                -WorkoutMetricFreshness.pairedCyclingSensorMaximumAge
            ),
            source: .pairedCyclingSensor
        )
        let staleSensor = WorkoutMetricCandidate(
            value: 9,
            capturedAt: sensorAtBoundary.capturedAt.addingTimeInterval(-0.001),
            source: .pairedCyclingSensor
        )
        let freshLocation = WorkoutMetricCandidate(
            value: 7.8,
            capturedAt: now.addingTimeInterval(-1),
            source: .watchLocation
        )
        expect(
            WorkoutMetricFreshness.candidate(
                sensorAtBoundary,
                now: now,
                maximumAge: WorkoutMetricFreshness.pairedCyclingSensorMaximumAge
            ) == sensorAtBoundary,
            "instantaneous sensor value should remain fresh at its age boundary"
        )
        let freshSensor = WorkoutMetricFreshness.candidate(
            staleSensor,
            now: now,
            maximumAge: WorkoutMetricFreshness.pairedCyclingSensorMaximumAge
        )
        expect(freshSensor == nil, "sensor value beyond the age limit must expire")
        expect(
            WorkoutMetricPrecedence.currentSpeed(
                pairedSensor: freshSensor,
                watchLocation: freshLocation
            ) == freshLocation,
            "fresh Watch GPS speed must replace an expired paired-sensor speed"
        )

        let heartRateAtBoundary = WorkoutMetricV1(
            value: 142,
            unit: .beatsPerMinute,
            capturedAt: now.addingTimeInterval(-WorkoutMetricFreshness.heartRateMaximumAge),
            source: .healthKit
        )
        expect(
            WorkoutMetricFreshness.metric(
                heartRateAtBoundary,
                now: now,
                maximumAge: WorkoutMetricFreshness.heartRateMaximumAge
            ) == heartRateAtBoundary,
            "heart rate should remain fresh at its boundary"
        )
        expect(
            WorkoutMetricFreshness.metric(
                WorkoutMetricV1(
                    value: 143,
                    unit: .beatsPerMinute,
                    capturedAt: now.addingTimeInterval(1),
                    source: .healthKit
                ),
                now: now,
                maximumAge: WorkoutMetricFreshness.heartRateMaximumAge
            ) == nil,
            "future instantaneous readings must fail closed"
        )
    }

    private mutating func testBuilderElapsedTimeUsesHealthKitPauseClock() {
        let start = Date(timeIntervalSinceReferenceDate: 800_027_000)
        let running = WorkoutElapsedTimePolicy.metric(
            builderElapsedTime: 30,
            startDate: start,
            capturedAt: start.addingTimeInterval(30)
        )
        let pausedLater = WorkoutElapsedTimePolicy.metric(
            builderElapsedTime: 30,
            startDate: start,
            capturedAt: start.addingTimeInterval(50)
        )
        let resumed = WorkoutElapsedTimePolicy.metric(
            builderElapsedTime: 31,
            startDate: start,
            capturedAt: start.addingTimeInterval(51)
        )
        expect(running?.value == 30, "running snapshot should use builder elapsed time")
        expect(
            pausedLater?.value == running?.value,
            "wall-clock time during pause must not advance elapsed workout time"
        )
        expect(
            resumed?.value == 31,
            "elapsed time should advance again only when the builder does"
        )
        expect(
            WorkoutElapsedTimePolicy.metric(
                builderElapsedTime: .nan,
                startDate: start,
                capturedAt: start
            ) == nil,
            "invalid builder elapsed time must remain unavailable"
        )
    }

    private mutating func testRoutePointFilteringHonorsWorkoutAndAccuracyBounds() {
        let start = Date(timeIntervalSinceReferenceDate: 800_030_000)
        let now = start.addingTimeInterval(30)
        let valid = WorkoutRoutePointCandidate(
            latitude: 1.3521,
            longitude: 103.8198,
            capturedAt: now,
            horizontalAccuracy: 6,
            verticalAccuracy: 8
        )
        expect(
            WorkoutRoutePointFilter.accepts(valid, workoutStart: start, now: now),
            "accurate in-window route point should be accepted"
        )
        expect(
            !WorkoutRoutePointFilter.accepts(
                WorkoutRoutePointCandidate(
                    latitude: valid.latitude,
                    longitude: valid.longitude,
                    capturedAt: start.addingTimeInterval(-1),
                    horizontalAccuracy: valid.horizontalAccuracy,
                    verticalAccuracy: valid.verticalAccuracy
                ),
                workoutStart: start,
                now: now
            ),
            "pre-workout route point should be rejected"
        )
        expect(
            !WorkoutRoutePointFilter.accepts(
                WorkoutRoutePointCandidate(
                    latitude: valid.latitude,
                    longitude: valid.longitude,
                    capturedAt: now,
                    horizontalAccuracy: 51,
                    verticalAccuracy: valid.verticalAccuracy
                ),
                workoutStart: start,
                now: now
            ),
            "inaccurate route point should be rejected"
        )
        expect(
            !WorkoutRoutePointFilter.accepts(
                WorkoutRoutePointCandidate(
                    latitude: 91,
                    longitude: valid.longitude,
                    capturedAt: now,
                    horizontalAccuracy: valid.horizontalAccuracy,
                    verticalAccuracy: valid.verticalAccuracy
                ),
                workoutStart: start,
                now: now
            ),
            "invalid coordinate should be rejected"
        )
    }

    private mutating func testRouteTimestampGateRejectsDelayedPausedBatches() {
        let start = Date(timeIntervalSinceReferenceDate: 800_035_000)
        var gate = WorkoutRouteTimestampGate(workoutStart: start)
        expect(gate.accepts(start), "route timestamp gate should include workout start")

        let resumeDate = start.addingTimeInterval(30)
        gate.resume(at: resumeDate)
        expect(
            !gate.accepts(resumeDate.addingTimeInterval(-0.001)),
            "a paused point delivered after resume must still be rejected by capture time"
        )
        expect(
            gate.accepts(resumeDate),
            "a point captured at the resume boundary should be accepted"
        )
        gate.resume(at: start.addingTimeInterval(10))
        expect(
            gate.minimumAcceptedAt == resumeDate,
            "an out-of-order resume callback must not move the gate backward"
        )
    }

    private mutating func testRouteSegmentAndQueueBounds() {
        expect(
            WorkoutRouteSegmentFilter.accepts(distanceMeters: 100, interval: 2),
            "a segment at the cycling plausibility boundary should be accepted"
        )
        expect(
            !WorkoutRouteSegmentFilter.accepts(distanceMeters: 101, interval: 2),
            "an implausibly fast route segment should be rejected"
        )
        expect(
            !WorkoutRouteSegmentFilter.accepts(distanceMeters: 1, interval: 0),
            "a route segment with a nonpositive interval should be rejected"
        )
        expect(
            !WorkoutRouteSegmentFilter.accepts(distanceMeters: .infinity, interval: 1),
            "a non-finite route segment should be rejected"
        )

        let limit = WorkoutRouteQueuePolicy.maximumPendingPointCount
        expect(
            WorkoutRouteQueuePolicy.canAppend(currentCount: limit - 1, incomingCount: 1),
            "the route queue should accept exactly its configured bound"
        )
        expect(
            !WorkoutRouteQueuePolicy.canAppend(currentCount: limit, incomingCount: 1),
            "the route queue must reject points beyond its configured bound"
        )
        expect(
            !WorkoutRouteQueuePolicy.canAppend(currentCount: Int.max, incomingCount: 1),
            "route queue count overflow must fail closed"
        )

        var queue = WorkoutRouteBatchQueue<Int>()
        expect(
            queue.append(contentsOf: Array(0..<45)),
            "production route queue should accept a bounded burst"
        )
        let firstBatch = queue.takeNextBatch()
        let secondBatch = queue.takeNextBatch()
        let thirdBatch = queue.takeNextBatch()
        expect(firstBatch == Array(0..<20), "first route insertion batch should contain 20 points")
        expect(secondBatch == Array(20..<40), "second route insertion batch should preserve order")
        expect(thirdBatch == Array(40..<45), "final route insertion batch should contain the remainder")
        queue.markInserted(count: firstBatch.count)
        queue.markInserted(count: secondBatch.count)
        queue.markInserted(count: thirdBatch.count)
        expect(queue.insertedPointCount == 45, "successful route batches should count exactly once")
        expect(queue.isEmpty, "draining should leave no pending route points")

        queue.reset()
        expect(
            queue.append(
                contentsOf: Array(
                    0..<WorkoutRouteQueuePolicy.maximumPendingPointCount
                )
            ),
            "queue should accept exactly the backpressure bound"
        )
        expect(
            !queue.append(contentsOf: [999]),
            "queue should reject a point beyond the backpressure bound"
        )
        queue.markFailed()
        expect(queue.hasFailed && queue.isEmpty, "insertion failure should purge pending raw points")

        var generation = WorkoutRouteGenerationGate()
        let firstGeneration = generation.advance()
        expect(generation.accepts(firstGeneration), "current route generation should be accepted")
        _ = generation.advance()
        expect(
            !generation.accepts(firstGeneration),
            "reset route generation must reject an older async insertion completion"
        )
        var wrappingGeneration = WorkoutRouteGenerationGate(current: UInt64.max)
        expect(wrappingGeneration.advance() == 1, "generation rollover must avoid zero reuse")
    }

    private mutating func testRouteRecoveryDistanceAndAssociatedFinalizationPolicies() {
        expect(
            WorkoutRouteFallbackPolicy.canProvideTotal(
                mayContainExistingRouteData: false
            ),
            "a new route may provide a whole-workout fallback distance"
        )
        expect(
            !WorkoutRouteFallbackPolicy.canProvideTotal(
                mayContainExistingRouteData: true
            ),
            "a recovered route must not publish a partial distance as the total"
        )
        expect(
            WorkoutAssociatedRoutePolicy.decision(
                insertedPointCount: 1,
                routeSavingFailed: false,
                mayContainExistingRouteData: false
            ) == WorkoutAssociatedRouteDecision(
                keepBuilderForWorkout: true,
                routeStatus: .present
            ),
            "known nonempty associated route should finalize and be reported present"
        )
        expect(
            WorkoutAssociatedRoutePolicy.decision(
                insertedPointCount: 0,
                routeSavingFailed: false,
                mayContainExistingRouteData: false
            ) == WorkoutAssociatedRouteDecision(
                keepBuilderForWorkout: false,
                routeStatus: .unavailable
            ),
            "known empty new route should be discarded before workout finalization"
        )
        expect(
            WorkoutAssociatedRoutePolicy.decision(
                insertedPointCount: 0,
                routeSavingFailed: false,
                mayContainExistingRouteData: true
            ) == WorkoutAssociatedRouteDecision(
                keepBuilderForWorkout: true,
                routeStatus: .unknown
            ),
            "recovery should preserve a possibly-existing route without claiming it exists"
        )
        expect(
            WorkoutAssociatedRoutePolicy.decision(
                insertedPointCount: 20,
                routeSavingFailed: true,
                mayContainExistingRouteData: true
            ) == WorkoutAssociatedRouteDecision(
                keepBuilderForWorkout: true,
                routeStatus: .unknown
            ),
            "a recovered route failure must preserve possible pre-crash data without claiming presence"
        )
        expect(
            WorkoutAssociatedRoutePolicy.decision(
                insertedPointCount: 20,
                routeSavingFailed: true,
                mayContainExistingRouteData: false
            ) == WorkoutAssociatedRouteDecision(
                keepBuilderForWorkout: false,
                routeStatus: .unavailable
            ),
            "a failed new route must be discarded and reported unavailable"
        )

        var distance = WorkoutRouteDistanceAccumulator(
            mayContainExistingRouteData: false
        )
        distance.appendPoint(segmentDistanceFromPrevious: nil)
        distance.appendPoint(segmentDistanceFromPrevious: 100)
        distance.appendPoint(segmentDistanceFromPrevious: 50)
        expect(
            distance.totalMeters == 150,
            "two internal segments in the first delivered batch must both count"
        )
        distance.breakSegment()
        distance.appendPoint(segmentDistanceFromPrevious: nil)
        expect(
            distance.totalMeters == 150,
            "first point after pause must not bridge distance across the pause"
        )
        distance.appendPoint(segmentDistanceFromPrevious: 25)
        expect(
            distance.totalMeters == 175,
            "post-resume segments should continue the cumulative total"
        )

        var recoveredDistance = WorkoutRouteDistanceAccumulator(
            mayContainExistingRouteData: true
        )
        recoveredDistance.appendPoint(segmentDistanceFromPrevious: nil)
        recoveredDistance.appendPoint(segmentDistanceFromPrevious: 100)
        expect(
            recoveredDistance.totalMeters == nil,
            "post-recovery segments must remain unavailable as a whole-workout total"
        )

        let endDate = Date(timeIntervalSinceReferenceDate: 800_039_000)
        let terminalDistance = WorkoutTerminalRouteDistancePolicy.candidate(
            distanceMeters: 175,
            capturedAt: endDate
        )
        expect(
            WorkoutMetricPrecedence.cyclingDistance(
                healthKit: nil,
                watchRoute: terminalDistance
            ) == terminalDistance,
            "terminal full snapshot should retain valid route fallback distance"
        )
    }

    private mutating func testRecoverySequenceLeasesNeverReuseReservedValues() {
        var first = WorkoutSequenceLease(after: 0, size: 3)
        expect(first.lowerBound == 1, "first lease should begin after persisted watermark")
        expect(first.persistedHighWatermark == 3, "lease should reserve its full range")
        expect(first.take() == 1, "lease should issue its lower bound")
        expect(first.take() == 2, "lease should remain monotonic")

        var recovered = WorkoutSequenceLease(
            after: first.persistedHighWatermark,
            size: 3
        )
        expect(
            recovered.take() == 4,
            "recovery should skip every value reserved before the crash"
        )
        expect(first.take() == 3, "original lease should issue its final value")
        expect(first.take() == nil, "exhausted lease must not wrap")

        var exhausted = WorkoutSequenceLease(after: UInt64.max, size: 1)
        expect(exhausted.take() == nil, "maximum watermark must not reuse UInt64.max")
    }

    private mutating func testRecoveryStorePersistsIdentityAndLeases() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BikeComputer.WorkoutRecoveryTests.\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("active.plist")
        let persistence = WorkoutRecoveryFilePersistence(fileURL: fileURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = Date(timeIntervalSinceReferenceDate: 800_040_000)
        do {
            let firstStore = WatchWorkoutRecoveryStore(persistence: persistence)
            let identity = try firstStore.begin(startDate: start)
            expect(identity.sessionToken != 0, "persisted workout token must be nonzero")
            expect(firstStore.nextSequence() == 1, "first transport sequence should be one")
            var zoneAccumulator = WorkoutHeartRateZoneDurationAccumulator()
            _ = zoneAccumulator.update(
                sessionID: identity.sessionID,
                elapsedTime: 10,
                currentZone: 2
            )
            let zoneCheckpoint = zoneAccumulator.checkpoint!
            try firstStore.persistHeartRateZoneCheckpoint(zoneCheckpoint)
            let finishRequestedAt = start.addingTimeInterval(90)
            try firstStore.markFinishing(
                disposition: .save,
                requestedAt: finishRequestedAt
            )

            let recoveredStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                recoveredStore.recoveredIdentity?.sessionID == identity.sessionID,
                "relaunch should recover the same workout identity"
            )
            expect(
                recoveredStore.nextSequence() == WorkoutSequenceLease.defaultSize + 1,
                "relaunch must skip the entire pre-crash reserved sequence lease"
            )
            expect(
                recoveredStore.recoveredIdentity?.finishRequest
                    == WatchWorkoutRecoveryStore.FinishRequest(
                        disposition: .save,
                        requestedAt: finishRequestedAt
                    ),
                "relaunch must recover the requested save phase and exact stop date"
            )
            expect(
                recoveredStore.recoveredIdentity?.heartRateZoneCheckpoint
                    == zoneCheckpoint,
                "relaunch must recover the exact heart-rate zone checkpoint"
            )
            try recoveredStore.markCollectionEnded()
            let collectionEndedStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                collectionEndedStore.recoveredIdentity?.finishRequest?.phase
                    == .collectionEnded,
                "collection-ended finalization phase must survive relaunch"
            )
            try collectionEndedStore.markPreparedRoute(.present)
            try collectionEndedStore.markFinishAttempted()
            let finishAttemptedStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                finishAttemptedStore.recoveredIdentity?.finishRequest?.phase
                    == .finishAttempted,
                "the pre-call finish-attempt marker must survive relaunch"
            )
            expect(
                finishAttemptedStore.recoveredIdentity?.finishRequest?.routeStatus
                    == .present,
                "known route presence must survive a crash around workout saving"
            )
            try finishAttemptedStore.markFinishFailed()
            let failedFinishStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                failedFinishStore.recoveredIdentity?.finishRequest?.phase
                    == .collectionEnded,
                "an explicit finish callback failure should durably permit one safe retry"
            )
            try failedFinishStore.markFinishAttempted()
            try failedFinishStore.markWorkoutSaved()
            let workoutSavedStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                workoutSavedStore.recoveredIdentity?.finishRequest?.phase == .workoutSaved,
                "workout-saved finalization phase must survive relaunch"
            )
            expect(
                try workoutSavedStore.useRecoveredIdentity(
                    startDate: start.addingTimeInterval(1)
                ).sessionID == identity.sessionID,
                "HealthKit start-date jitter within tolerance should retain identity"
            )

            let tombstone = try workoutSavedStore.archiveConfirmedSavedIdentity(
                at: finishRequestedAt
            )
            let archivedStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                archivedStore.recoveredIdentity == nil,
                "archiving a confirmed save must release the active identity"
            )
            expect(
                archivedStore.terminalTombstone(
                    externalUUID: identity.sessionID.uuidString
                ) == tombstone,
                "a terminal tombstone must survive relaunch and match stable metadata"
            )
            expect(
                tombstone.disposition == .save,
                "legacy saved tombstones must remain explicitly save-only"
            )
            let nextIdentity = try archivedStore.begin(
                startDate: finishRequestedAt.addingTimeInterval(60)
            )
            let combinedStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                combinedStore.recoveredIdentity?.sessionID == nextIdentity.sessionID,
                "a new active identity must coexist with an older terminal tombstone"
            )
            expect(
                combinedStore.terminalTombstone(
                    externalUUID: identity.sessionID.uuidString
                )?.sessionID == identity.sessionID,
                "starting a new ride must not overwrite late-callback proof"
            )
            try combinedStore.removeTerminalTombstone(sessionID: identity.sessionID)
            let consumedStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                consumedStore.terminalTombstone(
                    externalUUID: identity.sessionID.uuidString
                ) == nil,
                "late-session cleanup must consume only its matching tombstone"
            )
            expect(
                consumedStore.recoveredIdentity?.sessionID == nextIdentity.sessionID,
                "consuming an old tombstone must preserve the new active identity"
            )

            try consumedStore.clear()
            expect(
                WatchWorkoutRecoveryStore(persistence: persistence).recoveredIdentity == nil,
                "clear should remove the durable workout identity"
            )

            let discardStore = WatchWorkoutRecoveryStore(persistence: persistence)
            let discardIdentity = try discardStore.begin(
                startDate: finishRequestedAt.addingTimeInterval(120)
            )
            try discardStore.markFinishing(
                disposition: .discard,
                requestedAt: finishRequestedAt.addingTimeInterval(150)
            )
            let discardTombstone = try discardStore
                .archiveConfirmedDiscardedIdentity(
                    at: finishRequestedAt.addingTimeInterval(151)
                )
            let reloadedDiscardStore = WatchWorkoutRecoveryStore(
                persistence: persistence
            )
            expect(
                reloadedDiscardStore.terminalTombstone(
                    externalUUID: discardIdentity.sessionID.uuidString
                ) == discardTombstone,
                "a discard tombstone must survive relaunch"
            )
            expect(
                discardTombstone.disposition == .discard
                    && discardTombstone.routeStatus == .unavailable,
                "late discard proof must never imply a saved workout or route"
            )
            try reloadedDiscardStore.removeTerminalTombstone(
                sessionID: discardIdentity.sessionID
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data([0x00, 0x01, 0x02]).write(to: fileURL, options: .atomic)
            let corruptStore = WatchWorkoutRecoveryStore(persistence: persistence)
            expect(
                corruptStore.recoveredIdentity == nil,
                "corrupt durable recovery data must fail closed"
            )
            expect(
                corruptStore.loadState == .corrupt,
                "corrupt durable recovery data must remain distinguishable from a missing file"
            )
            do {
                _ = try corruptStore.useRecoveredIdentity(startDate: start)
                expect(false, "recovery must not invent a UUID when HealthKit metadata is absent")
            } catch {
                expect(corruptStore.recoveredIdentity == nil, "failed recovery must retain no identity")
            }
            let builderSessionID = UUID()
            do {
                _ = try corruptStore.useRecoveredIdentity(
                    startDate: start,
                    stableSessionID: builderSessionID
                )
                expect(false, "corrupt state must not be overwritten during identity adoption")
            } catch {
                expect(
                    corruptStore.recoveredIdentity == nil,
                    "corrupt state must stay fail-closed even with a valid builder UUID"
                )
            }
        } catch {
            expect(false, "file-backed recovery fixture threw \(error)")
        }

        struct LegacyFinishRequest: Codable {
            let disposition: WorkoutFinishDisposition
            let requestedAt: Date
        }
        struct LegacyIdentity: Codable {
            let sessionID: UUID
            let sessionToken: UInt16
            let startDate: Date
            let sequenceHighWatermark: UInt64
            let finishRequest: LegacyFinishRequest?
        }
        let legacyPersistence = ControllableRecoveryPersistence()
        do {
            legacyPersistence.data = try PropertyListEncoder().encode(
                LegacyIdentity(
                    sessionID: UUID(),
                    sessionToken: 7,
                    startDate: start,
                    sequenceHighWatermark: 0,
                    finishRequest: LegacyFinishRequest(
                        disposition: .save,
                        requestedAt: start.addingTimeInterval(45)
                    )
                )
            )
            expect(
                WatchWorkoutRecoveryStore(
                    persistence: legacyPersistence
                ).recoveredIdentity?.finishRequest?.phase == .requested,
                "pre-phase recovery files must migrate to requested without data loss"
            )
        } catch {
            expect(false, "legacy recovery migration fixture threw \(error)")
        }

        let controlled = ControllableRecoveryPersistence()
        let controlledStore = WatchWorkoutRecoveryStore(persistence: controlled)
        expect(
            controlledStore.loadState == .missing,
            "an absent recovery file must be reported as missing"
        )
        controlled.failsSave = true
        do {
            _ = try controlledStore.begin(startDate: start)
            expect(false, "identity must not be issued when its durable write fails")
        } catch {
            expect(controlledStore.recoveredIdentity == nil, "failed begin must retain no identity")
        }
        controlled.failsSave = false
        do {
            let identity = try controlledStore.begin(startDate: start)
            var zoneAccumulator = WorkoutHeartRateZoneDurationAccumulator()
            _ = zoneAccumulator.update(
                sessionID: identity.sessionID,
                elapsedTime: 20,
                currentZone: 3
            )
            let zoneCheckpoint = zoneAccumulator.checkpoint!
            controlled.failsSave = true
            do {
                try controlledStore.persistHeartRateZoneCheckpoint(
                    zoneCheckpoint
                )
                expect(false, "a failed zone checkpoint write must throw")
            } catch {
                expect(
                    controlledStore.recoveredIdentity?
                        .heartRateZoneCheckpoint == nil,
                    "a failed zone checkpoint write must not publish unsaved state"
                )
            }
            controlled.failsSave = false
            try controlledStore.persistHeartRateZoneCheckpoint(zoneCheckpoint)
            expect(
                WatchWorkoutRecoveryStore(persistence: controlled)
                    .recoveredIdentity?.heartRateZoneCheckpoint
                    == zoneCheckpoint,
                "a retried zone checkpoint write must survive store recreation"
            )
            controlled.failsSave = true
            do {
                try controlledStore.markFinishing(
                    disposition: .discard,
                    requestedAt: start.addingTimeInterval(30)
                )
                expect(false, "finish request must not succeed when persistence fails")
            } catch {
                expect(
                    controlledStore.recoveredIdentity?.finishRequest == nil,
                    "failed finish persistence must not publish a disposition"
                )
            }
            expect(
                controlledStore.nextSequence() == nil,
                "sequence must not be issued when lease reservation cannot be persisted"
            )
            controlled.failsSave = false
            expect(
                controlledStore.nextSequence() == 1,
                "failed reservation must not consume or skip a sequence"
            )
            try controlledStore.markFinishing(
                disposition: .save,
                requestedAt: start.addingTimeInterval(60)
            )
            controlled.failsSave = true
            do {
                try controlledStore.markCollectionEnded()
                expect(false, "phase transition must not publish when persistence fails")
            } catch {
                expect(
                    controlledStore.recoveredIdentity?.finishRequest?.phase == .requested,
                    "failed phase persistence must retain the last durable phase"
                )
            }
            controlled.failsSave = false
            try controlledStore.markCollectionEnded()
            try controlledStore.markFinishAttempted()
            try controlledStore.markWorkoutSaved()
            controlled.failsSave = true
            do {
                _ = try controlledStore.archiveConfirmedSavedIdentity()
                expect(false, "failed tombstone persistence must not release the active identity")
            } catch {
                expect(
                    controlledStore.recoveredIdentity?.finishRequest?.phase == .workoutSaved,
                    "failed tombstone persistence must retain the saved active identity"
                )
                expect(
                    controlledStore.recoveredTerminalTombstones.isEmpty,
                    "failed tombstone persistence must not publish in-memory late-callback proof"
                )
            }
        } catch {
            expect(false, "controlled recovery fixture threw \(error)")
        }

        let transitionPersistence = ControllableRecoveryPersistence()
        do {
            let transitionStore = WatchWorkoutRecoveryStore(
                persistence: transitionPersistence
            )
            _ = try transitionStore.begin(startDate: start)
            let senderID = UUID()
            let checkpoint = WorkoutRemoteControlSequenceGate.Checkpoint(
                currentSenderID: senderID,
                highestSequence: 1,
                seenSenderIDs: [senderID],
                latestCapturedAt: start.addingTimeInterval(5),
                legacyHighestSequence: 0
            )
            let context = WorkoutControlContextV1(
                origin: .automatic,
                automaticReason: .rideDetection,
                rideGeneration: 21,
                decisionSequence: 34,
                detectorProfileVersion: 1
            )
            try transitionStore.persistRemoteControlCheckpoint(
                checkpoint,
                pendingTransitionContext: context,
                pendingTransitionPaused: true,
                pendingTransitionRequestedAt: start.addingTimeInterval(5)
            )
            let recoveredPending = WatchWorkoutRecoveryStore(
                persistence: transitionPersistence
            )
            expect(
                recoveredPending.recoveredIdentity?
                    .pendingTransitionContext == context
                    && recoveredPending.recoveredIdentity?
                        .pendingTransitionPaused == true,
                "automatic transition intent must be durable before HealthKit state mutation"
            )

            transitionPersistence.failsSave = true
            do {
                try recoveredPending
                    .clearPendingAutomaticTransitionForManualRequest()
                expect(false, "manual preemption must report a failed durable clear")
            } catch {
                expect(
                    recoveredPending.recoveredIdentity?
                        .pendingTransitionContext == context,
                    "failed manual preemption must not publish an undurable clear"
                )
            }
            transitionPersistence.failsSave = false
            try recoveredPending
                .clearPendingAutomaticTransitionForManualRequest()
            expect(
                WatchWorkoutRecoveryStore(
                    persistence: transitionPersistence
                ).recoveredIdentity?.pendingTransitionContext == nil,
                "manual pause/resume must durably retire automatic intent before HealthKit changes state"
            )

            let secondCheckpoint =
                WorkoutRemoteControlSequenceGate.Checkpoint(
                    currentSenderID: senderID,
                    highestSequence: 2,
                    seenSenderIDs: [senderID],
                    latestCapturedAt: start.addingTimeInterval(10),
                    legacyHighestSequence: 0
                )
            try recoveredPending.persistRemoteControlCheckpoint(
                secondCheckpoint,
                pendingTransitionContext: context,
                pendingTransitionPaused: true,
                pendingTransitionRequestedAt: start.addingTimeInterval(10)
            )
            try recoveredPending.confirmRideTransition(
                origin: .automatic,
                paused: true,
                at: start.addingTimeInterval(11),
                detectorProfileVersion: 1
            )
            let confirmedPause = WatchWorkoutRecoveryStore(
                persistence: transitionPersistence
            ).recoveredIdentity
            expect(
                confirmedPause?.pauseOrigin == .automatic
                    && confirmedPause?.lastTransitionOrigin == .automatic
                    && confirmedPause?.detectorProfileVersion == 1
                    && confirmedPause?.pendingTransitionContext == nil,
                "confirmed automatic pause must atomically replace its pending intent with provenance"
            )
            try recoveredPending.confirmRideTransition(
                origin: .manual,
                paused: false,
                at: start.addingTimeInterval(20),
                detectorProfileVersion: nil
            )
            let confirmedManualResume = WatchWorkoutRecoveryStore(
                persistence: transitionPersistence
            ).recoveredIdentity
            expect(
                confirmedManualResume?.pauseOrigin == nil
                    && confirmedManualResume?.lastTransitionOrigin == .manual
                    && confirmedManualResume?.detectorProfileVersion == 1,
                "manual resume must win while retaining the detector profile audit trail"
            )
        } catch {
            expect(false, "ride-transition recovery fixture threw \(error)")
        }
    }

    private mutating func testTerminalErrorUpdatePreservesFinishRequestAndSurvivesRecovery() {
        for disposition in [
            WorkoutFinishDisposition.save,
            WorkoutFinishDisposition.discard,
        ] {
            let persistence = ControllableRecoveryPersistence()
            let store = WatchWorkoutRecoveryStore(persistence: persistence)
            do {
                let identity = try store.begin(
                    startDate: Date(timeIntervalSinceReferenceDate: 800_070_000)
                )
                let requestedAt = identity.startDate.addingTimeInterval(45)
                try store.markFinishing(
                    disposition: disposition,
                    requestedAt: requestedAt
                )
                if disposition == .save {
                    try store.markPreparedRoute(.present)
                    try store.markCollectionEnded()
                }
                let before = store.recoveredIdentity?.finishRequest

                try store.markTerminalError(.anotherWorkoutActive)
                let after = store.recoveredIdentity?.finishRequest
                expect(after?.disposition == disposition, "takeover persistence must preserve Save or Discard")
                expect(after?.requestedAt == requestedAt, "takeover persistence must preserve the rider request time")
                expect(after?.phase == before?.phase, "takeover persistence must preserve finalization progress")
                expect(after?.routeStatus == before?.routeStatus, "takeover persistence must preserve route progress")
                expect(after?.terminalErrorCode == .anotherWorkoutActive, "takeover persistence must store the terminal cause")

                persistence.failsSave = true
                try store.markTerminalError(.sessionFailed)
                expect(
                    store.recoveredIdentity?.finishRequest?.terminalErrorCode
                        == .anotherWorkoutActive,
                    "a later generic failure must neither rewrite nor block an already-durable takeover cause"
                )
                persistence.failsSave = false

                let relaunched = WatchWorkoutRecoveryStore(
                    persistence: persistence
                )
                expect(
                    relaunched.recoveredIdentity?.finishRequest == after,
                    "the updated terminal cause and untouched finish request must survive relaunch"
                )
            } catch {
                expect(false, "terminal-error recovery fixture threw \(error)")
            }
        }
    }

#if WORKOUT_CONTRACT_HOST
    private mutating func testRecoveryStoreSurvivesProcessRelaunch() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BikeComputer.WorkoutRecoveryProcessTests.\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("active.plist")
        defer { try? FileManager.default.removeItem(at: directory) }

        func runChild(mode: String) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            var environment = ProcessInfo.processInfo.environment
            environment["BIKE_RECOVERY_CHILD_MODE"] = mode
            environment["BIKE_RECOVERY_CHILD_PATH"] = fileURL.path
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return (
                process.terminationStatus,
                String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        do {
            let writeResult = try runChild(mode: "write-and-crash")
            expect(
                writeResult.0 == 0,
                "abrupt recovery writer should exit immediately after reservation: \(writeResult.1)"
            )
            let readResult = try runChild(mode: "read-after-crash")
            let parts = readResult.1.split(separator: "|", omittingEmptySubsequences: false)
            expect(readResult.0 == 0, "post-crash reader should exit cleanly: \(readResult.1)")
            expect(
                parts.count == 2 && UUID(uuidString: String(parts[0])) != nil,
                "post-crash reader should recover a valid identity: \(readResult.1)"
            )
            expect(
                parts.count == 2
                    && UInt64(parts[1]) == WorkoutSequenceLease.defaultSize + 1,
                "post-crash process must skip the full durably reserved lease: \(readResult.1)"
            )
        } catch {
            expect(false, "recovery crash/relaunch child failed: \(error)")
        }
    }
#endif

    private mutating func testMirrorReducerSupportsBothStartDirections() {
        let now = Date(timeIntervalSinceReferenceDate: 800_050_000)
        let snapshot = WorkoutSnapshotV1(
            state: .running,
            startDate: now
        )

        var watchStarted = WorkoutMirrorStateReducer()
        watchStarted.attachMirroredSession(at: now)
        expect(
            watchStarted.presentation.connectionState == .awaitingFirstSnapshot,
            "a Watch-started mirror should wait for its first coherent snapshot"
        )
        _ = watchStarted.ingestBatch(
            [makeEnvelope(sequence: 1, capturedAt: now, snapshot: snapshot)],
            receivedAt: now
        )
        expect(
            watchStarted.presentation.connectionState == .connected,
            "a Watch-started workout should become connected after its first snapshot"
        )
        expect(
            watchStarted.presentation.sessionState == .running,
            "a Watch-started mirror should publish the Watch state"
        )

        var phoneStarted = WorkoutMirrorStateReducer()
        let launchID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        expect(
            phoneStarted.beginWatchLaunch(id: launchID, at: now),
            "an idle iPhone should admit one Watch launch"
        )
        phoneStarted.completeWatchLaunch(
            id: launchID,
            succeeded: true,
            error: nil
        )
        phoneStarted.attachMirroredSession(at: now.addingTimeInterval(1))
        _ = phoneStarted.ingestBatch(
            [
                makeEnvelope(
                    sequence: 1,
                    capturedAt: now.addingTimeInterval(1),
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: now.addingTimeInterval(1)
                    )
                ),
            ],
            receivedAt: now.addingTimeInterval(1)
        )
        expect(
            phoneStarted.presentation.connectionState == .connected,
            "an iPhone-started workout should wait for and then adopt the Watch mirror"
        )
        expect(
            !phoneStarted.beginWatchLaunch(id: UUID(), at: now.addingTimeInterval(2)),
            "an active mirrored workout must reject a second iPhone start"
        )
    }

    private mutating func testMirrorReducerStartTimeoutIsAttemptScoped() {
        let now = Date(timeIntervalSinceReferenceDate: 800_051_000)
        let firstID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000010")!
        let secondID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000011")!
        var reducer = WorkoutMirrorStateReducer()

        expect(
            reducer.beginWatchLaunch(id: firstID, at: now, timeout: 5),
            "the first launch should be admitted"
        )
        reducer.completeWatchLaunch(id: firstID, succeeded: true, error: nil)
        expect(
            !reducer.timeOutWatchLaunch(id: firstID, at: now.addingTimeInterval(4.9)),
            "a launch must not time out before its deadline"
        )
        expect(
            reducer.timeOutWatchLaunch(id: firstID, at: now.addingTimeInterval(5)),
            "a launch without a mirrored session should time out at its deadline"
        )
        expect(
            reducer.presentation.errorCode == .setupRequired,
            "a silent Watch launch should direct the rider to finish setup on Watch"
        )

        expect(
            reducer.beginWatchLaunch(
                id: secondID,
                at: now.addingTimeInterval(6),
                timeout: 5
            ),
            "a timed-out launch should be retryable"
        )
        reducer.completeWatchLaunch(
            id: firstID,
            succeeded: false,
            error: .watchUnavailable
        )
        expect(
            reducer.presentation.connectionState == .launchingWatch,
            "a late callback from an old launch must not fail the retry"
        )
        reducer.attachMirroredSession(at: now.addingTimeInterval(7))
        expect(
            !reducer.timeOutWatchLaunch(id: secondID, at: now.addingTimeInterval(20)),
            "a delivered mirrored session must cancel its launch timeout"
        )
    }

    private mutating func testMirrorReducerDelayedBatchesCannotRollBackState() {
        let start = Date(timeIntervalSinceReferenceDate: 800_052_000)
        let generation = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
        var reducer = WorkoutMirrorStateReducer()
        reducer.attachMirroredSession(at: start)

        let running = makeEnvelope(
            transportGenerationID: generation,
            sequence: 2,
            capturedAt: start.addingTimeInterval(2),
            snapshot: WorkoutSnapshotV1(state: .running, startDate: start)
        )
        _ = reducer.ingestBatch([running], receivedAt: start.addingTimeInterval(2))

        let delayedOlder = makeEnvelope(
            transportGenerationID: generation,
            sequence: 1,
            capturedAt: start.addingTimeInterval(1),
            snapshot: WorkoutSnapshotV1(state: .starting, startDate: start)
        )
        let paused = makeEnvelope(
            transportGenerationID: generation,
            sequence: 3,
            capturedAt: start.addingTimeInterval(3),
            snapshot: WorkoutSnapshotV1(state: .paused, startDate: start)
        )
        let result = reducer.ingestBatch(
            [delayedOlder, paused],
            receivedAt: start.addingTimeInterval(4)
        )
        expect(
            result.acceptedEnvelopes.map(\.sequence) == [3],
            "a resumed batch should accept only envelopes newer than displayed state"
        )
        expect(
            reducer.presentation.sessionState == .paused,
            "a delayed batch must publish only its newest coherent state"
        )
        expect(
            reducer.presentation.capturedAt == paused.capturedAt,
            "capture age must be based on the newest accepted Watch timestamp"
        )
    }

    private mutating func testMirrorReducerRejectsFutureCaptureBeforeStateOrdering() {
        let start = Date(timeIntervalSinceReferenceDate: 800_052_500)
        var reducer = WorkoutMirrorStateReducer()
        reducer.attachMirroredSession(at: start)
        _ = reducer.ingestBatch(
            [
                makeEnvelope(
                    sequence: 1,
                    capturedAt: start,
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: start
                    )
                ),
            ],
            receivedAt: start
        )

        let future = makeEnvelope(
            sequence: 2,
            capturedAt: start.addingTimeInterval(100),
            snapshot: WorkoutSnapshotV1(state: .paused, startDate: start)
        )
        let rejected = reducer.ingestBatch(
            [future],
            receivedAt: start.addingTimeInterval(1)
        )
        expect(
            rejected.acceptedEnvelopes.isEmpty
                && rejected.rejections == [
                    WorkoutEnvelopeBatchRejection(
                        index: 0,
                        error: .invalidDate
                    ),
                ],
            "a Watch envelope beyond the bounded clock skew must be rejected"
        )
        expect(
            reducer.presentation.sessionState == .running
                && reducer.presentation.capturedAt == start,
            "a rejected future snapshot must not poison presentation ordering"
        )

        reducer.confirmSessionState(.ended, at: start.addingTimeInterval(2))
        _ = reducer.ingestBatch(
            [
                makeEnvelope(
                    sequence: 2,
                    capturedAt: start.addingTimeInterval(2),
                    snapshot: WorkoutSnapshotV1(
                        state: .ended,
                        startDate: start,
                        terminalOutcome: .saved
                    )
                ),
            ],
            receivedAt: start.addingTimeInterval(2)
        )
        expect(
            reducer.presentation.sessionState == .ended
                && reducer.presentation.connectionState == .ended,
            "native and Watch terminal evidence must remain admissible after a rejected future snapshot"
        )
    }

    private mutating func testMirrorReducerDisconnectAndStalenessStayHonest() {
        let start = Date(timeIntervalSinceReferenceDate: 800_053_000)
        let envelope = makeEnvelope(
            sequence: 1,
            capturedAt: start,
            snapshot: WorkoutSnapshotV1(state: .running, startDate: start)
        )
        var reducer = WorkoutMirrorStateReducer()
        reducer.attachMirroredSession(at: start)
        _ = reducer.ingestBatch([envelope], receivedAt: start)

        reducer.refreshFreshness(at: start.addingTimeInterval(10))
        expect(
            reducer.presentation.connectionState == .connected,
            "a snapshot at the freshness boundary should remain live"
        )
        reducer.refreshFreshness(at: start.addingTimeInterval(10.001))
        expect(
            reducer.presentation.connectionState == .stale,
            "an overdue snapshot should become explicitly stale"
        )
        reducer.disconnect(error: nil)
        expect(
            reducer.presentation.connectionState == .disconnected,
            "a remote disconnect should not masquerade as ordinary staleness"
        )
        expect(
            reducer.presentation.snapshot == envelope.snapshot,
            "disconnect must preserve the last coherent metrics without inventing zeroes"
        )
        reducer.refreshFreshness(at: start.addingTimeInterval(30))
        expect(
            reducer.presentation.connectionState == .disconnected,
            "freshness ticks must not hide a known disconnect"
        )
    }

    private mutating func testMirrorReducerNativeStateConfirmationBeatsOlderData() {
        let start = Date(timeIntervalSinceReferenceDate: 800_054_000)
        var reducer = WorkoutMirrorStateReducer()
        reducer.attachMirroredSession(at: start)
        reducer.confirmSessionState(.paused, at: start.addingTimeInterval(5))

        _ = reducer.ingestBatch(
            [
                makeEnvelope(
                    sequence: 1,
                    capturedAt: start.addingTimeInterval(4),
                    snapshot: WorkoutSnapshotV1(state: .running, startDate: start)
                ),
            ],
            receivedAt: start.addingTimeInterval(6)
        )
        expect(
            reducer.presentation.sessionState == .paused,
            "an older delivered snapshot must not undo a newer native HealthKit pause callback"
        )

        _ = reducer.ingestBatch(
            [
                makeEnvelope(
                    sequence: 2,
                    capturedAt: start.addingTimeInterval(7),
                    snapshot: WorkoutSnapshotV1(state: .paused, startDate: start)
                ),
            ],
            receivedAt: start.addingTimeInterval(7)
        )
        expect(
            reducer.presentation.sessionState == .paused,
            "a newer Watch snapshot should converge with native session confirmation"
        )
    }

    private mutating func testMirrorReducerAcknowledgesRemoteControls() {
        let now = Date(timeIntervalSinceReferenceDate: 800_055_000)
        let sessionID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!
        let generation = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000002")!
        var reducer = WorkoutMirrorStateReducer()
        reducer.attachMirroredSession(at: now)
        _ = reducer.ingestBatch(
            [
                makeEnvelope(
                    sessionID: sessionID,
                    sessionToken: 9,
                    transportGenerationID: generation,
                    sequence: 1,
                    capturedAt: now,
                    snapshot: WorkoutSnapshotV1(state: .running, startDate: now)
                ),
            ],
            receivedAt: now
        )
        expect(
            reducer.markPendingControl(.endAndSave, sequence: 1),
            "one remote end request should enter the pending state"
        )
        let acknowledgement = WorkoutEnvelopeV1(
            kind: .acknowledgement,
            sessionID: sessionID,
            sessionToken: 9,
            transportGenerationID: generation,
            sequence: 2,
            capturedAt: now.addingTimeInterval(1),
            acknowledgement: WorkoutAcknowledgementV1(
                control: .endAndSave,
                resultingState: .ending,
                acknowledgedSequence: 1
            )
        )
        let result = reducer.ingestBatch(
            [acknowledgement],
            receivedAt: now.addingTimeInterval(1)
        )
        expect(
            result.acceptedEnvelopes == [acknowledgement],
            "a valid acknowledgement should share the Watch envelope ordering stream"
        )
        expect(
            reducer.presentation.pendingControl == nil,
            "the matching Watch acknowledgement should clear the pending control"
        )

        expect(
            reducer.markPendingControl(.endAndSave, sequence: 42),
            "a retry should carry its own control sequence"
        )
        let lateAcknowledgement = WorkoutEnvelopeV1(
            kind: .acknowledgement,
            sessionID: sessionID,
            sessionToken: 9,
            transportGenerationID: generation,
            sequence: 3,
            capturedAt: now.addingTimeInterval(2),
            acknowledgement: WorkoutAcknowledgementV1(
                control: .endAndSave,
                resultingState: .ending,
                acknowledgedSequence: 1
            )
        )
        _ = reducer.ingestBatch(
            [lateAcknowledgement],
            receivedAt: now.addingTimeInterval(2)
        )
        expect(
            reducer.presentation.pendingControl == .endAndSave
                && reducer.pendingControlSequence == 42,
            "a late acknowledgement for attempt A must not clear attempt B"
        )

        let invalidStateAcknowledgement = WorkoutEnvelopeV1(
            kind: .acknowledgement,
            sessionID: sessionID,
            sessionToken: 9,
            transportGenerationID: generation,
            sequence: 4,
            capturedAt: now.addingTimeInterval(3),
            acknowledgement: WorkoutAcknowledgementV1(
                control: .endAndSave,
                resultingState: .running,
                acknowledgedSequence: 42
            )
        )
        _ = reducer.ingestBatch(
            [invalidStateAcknowledgement],
            receivedAt: now.addingTimeInterval(3)
        )
        expect(
            reducer.presentation.pendingControl == .endAndSave,
            "an acknowledgement with an incompatible result must not confirm control"
        )

        reducer.confirmSessionState(
            .ending,
            at: now.addingTimeInterval(4)
        )
        expect(
            reducer.presentation.pendingControl == .endAndSave,
            "generic HealthKit ending state must not confirm a save/discard choice"
        )
        reducer.confirmSessionState(
            .ended,
            at: now.addingTimeInterval(4.5)
        )
        expect(
            reducer.presentation.pendingControl == .endAndSave,
            "outcome-free native ended state must not confirm a save/discard choice"
        )
        _ = reducer.ingestBatch(
            [
                makeEnvelope(
                    sessionID: sessionID,
                    sessionToken: 9,
                    transportGenerationID: generation,
                    sequence: 5,
                    capturedAt: now.addingTimeInterval(4),
                    snapshot: WorkoutSnapshotV1(
                        state: .ending,
                        startDate: now
                    )
                ),
                makeEnvelope(
                    sessionID: sessionID,
                    sessionToken: 9,
                    transportGenerationID: generation,
                    sequence: 6,
                    capturedAt: now.addingTimeInterval(5),
                    snapshot: WorkoutSnapshotV1(
                        state: .ended,
                        startDate: now,
                        terminalOutcome: .discarded
                    )
                ),
            ],
            receivedAt: now.addingTimeInterval(5)
        )
        expect(
            reducer.presentation.pendingControl == nil
                && reducer.presentation.errorCode == .terminalChoiceConflict,
            "an explicit opposite terminal outcome must reject the pending choice immediately"
        )

        var matchingOutcomeReducer = WorkoutMirrorStateReducer()
        matchingOutcomeReducer.attachMirroredSession(at: now)
        _ = matchingOutcomeReducer.ingestBatch(
            [
                makeEnvelope(
                    sessionID: sessionID,
                    sessionToken: 9,
                    transportGenerationID: generation,
                    sequence: 1,
                    capturedAt: now,
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: now
                    )
                ),
            ],
            receivedAt: now
        )
        expect(
            matchingOutcomeReducer.markPendingControl(.discard, sequence: 20),
            "a discard choice should become pending"
        )
        _ = matchingOutcomeReducer.ingestBatch(
            [
                makeEnvelope(
                    sessionID: sessionID,
                    sessionToken: 9,
                    transportGenerationID: generation,
                    sequence: 2,
                    capturedAt: now.addingTimeInterval(1),
                    snapshot: WorkoutSnapshotV1(
                        state: .ending,
                        startDate: now
                    )
                ),
                makeEnvelope(
                    sessionID: sessionID,
                    sessionToken: 9,
                    transportGenerationID: generation,
                    sequence: 3,
                    capturedAt: now.addingTimeInterval(2),
                    snapshot: WorkoutSnapshotV1(
                        state: .ended,
                        startDate: now,
                        terminalOutcome: .discarded
                    )
                ),
            ],
            receivedAt: now.addingTimeInterval(2)
        )
        expect(
            matchingOutcomeReducer.presentation.pendingControl == nil,
            "a matching explicit terminal outcome may confirm the pending choice"
        )

        var segmentReducer = WorkoutMirrorStateReducer()
        segmentReducer.attachMirroredSession(at: now)
        _ = segmentReducer.ingestBatch(
            [
                makeEnvelope(
                    sessionID: sessionID,
                    sessionToken: 9,
                    transportGenerationID: generation,
                    sequence: 1,
                    capturedAt: now,
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: now
                    )
                ),
            ],
            receivedAt: now
        )
        expect(
            segmentReducer.markPendingControl(.markSegment, sequence: 77),
            "an iPhone segment request should become pending"
        )
        let segmentFailure = WorkoutEnvelopeV1(
            kind: .acknowledgement,
            sessionID: sessionID,
            sessionToken: 9,
            transportGenerationID: generation,
            sequence: 2,
            capturedAt: now.addingTimeInterval(1),
            acknowledgement: WorkoutAcknowledgementV1(
                control: .markSegment,
                resultingState: .running,
                acknowledgedSequence: 77,
                errorCode: .segmentMarkFailed
            )
        )
        _ = segmentReducer.ingestBatch(
            [segmentFailure],
            receivedAt: now.addingTimeInterval(1)
        )
        expect(
            segmentReducer.presentation.pendingControl == nil
                && segmentReducer.presentation.errorCode
                    == .segmentMarkFailed,
            "a correlated segment failure should clear pending state without failing the workout"
        )

        var unconfirmedSegmentReducer = WorkoutMirrorStateReducer()
        unconfirmedSegmentReducer.attachMirroredSession(at: now)
        _ = unconfirmedSegmentReducer.ingestBatch(
            [
                makeEnvelope(
                    sessionID: sessionID,
                    sessionToken: 9,
                    transportGenerationID: generation,
                    sequence: 1,
                    capturedAt: now,
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: now
                    )
                ),
            ],
            receivedAt: now
        )
        expect(
            unconfirmedSegmentReducer.markPendingControl(
                .markSegment,
                sequence: 78
            ),
            "a segment request should become pending before its outcome is unknown"
        )
        let segmentUnconfirmed = WorkoutEnvelopeV1(
            kind: .acknowledgement,
            sessionID: sessionID,
            sessionToken: 9,
            transportGenerationID: generation,
            sequence: 2,
            capturedAt: now.addingTimeInterval(1),
            acknowledgement: WorkoutAcknowledgementV1(
                control: .markSegment,
                resultingState: .running,
                acknowledgedSequence: 78,
                errorCode: .segmentMarkUnconfirmed
            )
        )
        _ = unconfirmedSegmentReducer.ingestBatch(
            [segmentUnconfirmed],
            receivedAt: now.addingTimeInterval(1)
        )
        unconfirmedSegmentReducer.attachMirroredSession(
            at: now.addingTimeInterval(2)
        )
        expect(
            unconfirmedSegmentReducer.isSegmentConfirmationPending
                && unconfirmedSegmentReducer.presentation.errorCode
                    == .segmentMarkUnconfirmed
                && !unconfirmedSegmentReducer.markPendingControl(
                    .markSegment,
                    sequence: 79
                ),
            "reconnection must preserve an outcome-unknown segment and block another boundary"
        )
        let recoveredSegmentSnapshot = WorkoutEnvelopeV1(
            kind: .snapshot,
            sessionID: sessionID,
            sessionToken: 9,
            transportGenerationID: generation,
            sequence: 3,
            capturedAt: now.addingTimeInterval(3),
            snapshot: WorkoutSnapshotV1(
                state: .running,
                startDate: now,
                lastCompletedSegment: WorkoutCompletedSegmentV1(
                    index: 1,
                    startedAt: now,
                    endedAt: now.addingTimeInterval(3),
                    duration: 3,
                    distanceMeters: nil
                )
            )
        )
        _ = unconfirmedSegmentReducer.ingestBatch(
            [recoveredSegmentSnapshot],
            receivedAt: now.addingTimeInterval(3)
        )
        expect(
            unconfirmedSegmentReducer.isSegmentConfirmationPending,
            "segment count alone must not attribute a Watch-local boundary to an iPhone command"
        )
        let recoveredSegmentAcknowledgement = WorkoutEnvelopeV1(
            kind: .acknowledgement,
            sessionID: sessionID,
            sessionToken: 9,
            transportGenerationID: generation,
            sequence: 4,
            capturedAt: now.addingTimeInterval(4),
            acknowledgement: WorkoutAcknowledgementV1(
                control: .markSegment,
                resultingState: .running,
                acknowledgedSequence: 78
            )
        )
        _ = unconfirmedSegmentReducer.ingestBatch(
            [recoveredSegmentAcknowledgement],
            receivedAt: now.addingTimeInterval(4)
        )
        expect(
            !unconfirmedSegmentReducer.isSegmentConfirmationPending
                && unconfirmedSegmentReducer.presentation.errorCode == nil,
            "the Watch replay acknowledgement must resolve the exact original segment command"
        )

        var snapshotFirstReducer = WorkoutMirrorStateReducer()
        snapshotFirstReducer.attachMirroredSession(at: now)
        _ = snapshotFirstReducer.ingestBatch(
            [
                makeEnvelope(
                    sessionID: sessionID,
                    sessionToken: 9,
                    transportGenerationID: generation,
                    sequence: 1,
                    capturedAt: now,
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: now
                    )
                ),
            ],
            receivedAt: now
        )
        expect(
            snapshotFirstReducer.markPendingControl(
                .markSegment,
                sequence: 80
            ),
            "the command-time segment baseline must be captured before delivery"
        )
        _ = snapshotFirstReducer.ingestBatch(
            [
                makeEnvelope(
                    sessionID: sessionID,
                    sessionToken: 9,
                    transportGenerationID: generation,
                    sequence: 2,
                    capturedAt: now.addingTimeInterval(1),
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: now,
                        lastCompletedSegment: WorkoutCompletedSegmentV1(
                            index: 1,
                            startedAt: now,
                            endedAt: now.addingTimeInterval(1),
                            duration: 1,
                            distanceMeters: nil
                        )
                    )
                ),
            ],
            receivedAt: now.addingTimeInterval(1)
        )
        let delayedUnconfirmedAcknowledgement = WorkoutEnvelopeV1(
            kind: .acknowledgement,
            sessionID: sessionID,
            sessionToken: 9,
            transportGenerationID: generation,
            sequence: 3,
            capturedAt: now.addingTimeInterval(2),
            acknowledgement: WorkoutAcknowledgementV1(
                control: .markSegment,
                resultingState: .running,
                acknowledgedSequence: 80,
                errorCode: .segmentMarkUnconfirmed
            )
        )
        _ = snapshotFirstReducer.ingestBatch(
            [delayedUnconfirmedAcknowledgement],
            receivedAt: now.addingTimeInterval(2)
        )
        expect(
            snapshotFirstReducer.isSegmentConfirmationPending
                && snapshotFirstReducer.presentation.errorCode
                    == .segmentMarkUnconfirmed,
            "a delayed unrelated snapshot must not clear the correlated command before Watch acknowledgement"
        )
        let snapshotFirstDefinitiveAcknowledgement = WorkoutEnvelopeV1(
            kind: .acknowledgement,
            sessionID: sessionID,
            sessionToken: 9,
            transportGenerationID: generation,
            sequence: 4,
            capturedAt: now.addingTimeInterval(3),
            acknowledgement: WorkoutAcknowledgementV1(
                control: .markSegment,
                resultingState: .running,
                acknowledgedSequence: 80
            )
        )
        _ = snapshotFirstReducer.ingestBatch(
            [snapshotFirstDefinitiveAcknowledgement],
            receivedAt: now.addingTimeInterval(3)
        )
        expect(
            !snapshotFirstReducer.isSegmentConfirmationPending
                && snapshotFirstReducer.presentation.errorCode == nil,
            "a definitive replay acknowledgement must resolve a snapshot-first segment command"
        )
    }

    private mutating func testMirrorReducerReplacesTerminalSessionCleanly() {
        let firstStart = Date(timeIntervalSinceReferenceDate: 800_055_100)
        let secondStart = firstStart.addingTimeInterval(60)
        var reducer = WorkoutMirrorStateReducer()
        reducer.attachMirroredSession(at: firstStart)
        _ = reducer.ingestBatch(
            [
                makeEnvelope(
                    sessionID: UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001")!,
                    sequence: 1,
                    capturedAt: firstStart.addingTimeInterval(10),
                    snapshot: WorkoutSnapshotV1(
                        state: .ended,
                        startDate: firstStart,
                        terminalOutcome: .saved
                    )
                ),
            ],
            receivedAt: firstStart.addingTimeInterval(10)
        )
        reducer.attachMirroredSession(at: secondStart)
        expect(
            reducer.presentation.connectionState == .awaitingFirstSnapshot,
            "a handler for a new workout must not present the old terminal session"
        )
        expect(
            reducer.presentation.sessionID == nil,
            "a new mirrored session must clear old terminal credentials"
        )

        let secondID = UUID(
            uuidString: "DDDDDDDD-0000-0000-0000-000000000002"
        )!
        _ = reducer.ingestBatch(
            [
                makeEnvelope(
                    sessionID: secondID,
                    sequence: 1,
                    capturedAt: secondStart,
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: secondStart
                    )
                ),
            ],
            receivedAt: secondStart
        )
        expect(
            reducer.presentation.sessionID == secondID
                && reducer.presentation.sessionState == .running,
            "the first snapshot should atomically adopt the new workout"
        )
    }

    private mutating func testMirrorReducerWaitsForFinalSnapshotBeforeReset() {
        let start = Date(timeIntervalSinceReferenceDate: 800_055_150)
        let sessionID = UUID(
            uuidString: "DDDDDDDD-1000-0000-0000-000000000001"
        )!
        var reducer = WorkoutMirrorStateReducer()
        reducer.attachMirroredSession(at: start)
        _ = reducer.ingestBatch(
            [
                makeEnvelope(
                    sessionID: sessionID,
                    sequence: 1,
                    capturedAt: start,
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: start
                    )
                ),
            ],
            receivedAt: start
        )
        reducer.confirmSessionState(.ended, at: start.addingTimeInterval(10))
        expect(
            !reducer.canResetTerminalPresentation
                && !reducer.resetTerminalPresentation(),
            "native end must not permit dismissal before the final Watch snapshot"
        )
        expect(
            !reducer.presentation.canStartNewWorkout
                && !reducer.beginWatchLaunch(
                    id: UUID(),
                    at: start.addingTimeInterval(11)
                ),
            "native end must not admit a new launch before the final outcome is resolved and dismissed"
        )
        expect(
            reducer.timeOutFinalSnapshot()
                && reducer.presentation.errorCode == .finalSummaryUnavailable
                && reducer.canResetTerminalPresentation,
            "a bounded final-snapshot timeout must explain the missing result before permitting dismissal"
        )
        expect(
            reducer.resetTerminalPresentation()
                && reducer.presentation.connectionState == .idle,
            "the rider may dismiss after the honest bounded timeout"
        )

        var deliveredReducer = WorkoutMirrorStateReducer()
        deliveredReducer.attachMirroredSession(at: start)
        _ = deliveredReducer.ingestBatch(
            [
                makeEnvelope(
                    sessionID: sessionID,
                    sequence: 1,
                    capturedAt: start,
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: start
                    )
                ),
            ],
            receivedAt: start
        )
        deliveredReducer.confirmSessionState(
            .ended,
            at: start.addingTimeInterval(10)
        )
        _ = deliveredReducer.ingestBatch(
            [
                makeEnvelope(
                    sessionID: sessionID,
                    sequence: 2,
                    capturedAt: start.addingTimeInterval(11),
                    snapshot: WorkoutSnapshotV1(
                        state: .ended,
                        startDate: start,
                        terminalOutcome: .saved
                    )
                ),
            ],
            receivedAt: start.addingTimeInterval(11)
        )
        expect(
            deliveredReducer.canResetTerminalPresentation
                && deliveredReducer.presentation.finalSnapshot?.terminalOutcome
                    == .saved,
            "the authoritative terminal envelope must enable dismissal immediately"
        )
    }

    private mutating func testTerminalResetRetiresOldSessionWithoutRetainingWallClockOrder() {
        let firstStart = Date(timeIntervalSinceReferenceDate: 800_055_180)
        let correctedStart = firstStart.addingTimeInterval(-120)
        let firstID = UUID(
            uuidString: "DDDDDDDD-2000-0000-0000-000000000001"
        )!
        let secondID = UUID(
            uuidString: "DDDDDDDD-2000-0000-0000-000000000002"
        )!
        var reducer = WorkoutMirrorStateReducer()
        reducer.attachMirroredSession(at: firstStart)
        _ = reducer.ingestBatch(
            [
                makeEnvelope(
                    sessionID: firstID,
                    sequence: 1,
                    capturedAt: firstStart.addingTimeInterval(30),
                    snapshot: WorkoutSnapshotV1(
                        state: .ended,
                        startDate: firstStart,
                        terminalOutcome: .saved
                    )
                ),
            ],
            receivedAt: firstStart.addingTimeInterval(30)
        )
        expect(
            reducer.resetTerminalPresentation(),
            "a confirmed terminal session should reset"
        )

        let delayedOldResult = reducer.ingestBatch(
            [
                makeEnvelope(
                    sessionID: firstID,
                    sequence: 2,
                    capturedAt: firstStart.addingTimeInterval(31),
                    snapshot: WorkoutSnapshotV1(
                        state: .ended,
                        startDate: firstStart,
                        terminalOutcome: .saved
                    )
                ),
            ],
            receivedAt: firstStart.addingTimeInterval(31)
        )
        expect(
            delayedOldResult.acceptedEnvelopes.isEmpty,
            "reset must permanently reject delayed traffic from the dismissed session"
        )

        reducer.attachMirroredSession(at: correctedStart)
        _ = reducer.ingestBatch(
            [
                makeEnvelope(
                    sessionID: secondID,
                    sequence: 1,
                    capturedAt: correctedStart,
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: correctedStart
                    )
                ),
            ],
            receivedAt: correctedStart
        )
        expect(
            reducer.presentation.sessionID == secondID
                && reducer.presentation.sessionState == .running,
            "a new workout must be admitted after reset even when the wall clock moved backward"
        )
    }

    private mutating func testMirrorReducerLateNativeConfirmationClearsCommandError() {
        let start = Date(timeIntervalSinceReferenceDate: 800_055_200)
        var reducer = WorkoutMirrorStateReducer()
        reducer.attachMirroredSession(at: start)
        _ = reducer.ingestBatch(
            [makeEnvelope(sequence: 1, capturedAt: start)],
            receivedAt: start
        )
        expect(reducer.markPendingControl(.pause), "pause should become pending")
        reducer.failPendingControl(.pause, error: .watchUnavailable)
        expect(
            reducer.presentation.errorCode == .watchUnavailable,
            "a timed-out command should surface a safe error"
        )
        reducer.confirmSessionState(.paused, at: start.addingTimeInterval(11))
        expect(
            reducer.presentation.sessionState == .paused
                && reducer.presentation.errorCode == nil,
            "a late native confirmation should clear the obsolete timeout error"
        )
    }

    private mutating func testControlSequencerSurvivesPhoneProcessRestart() {
        let now = Date(timeIntervalSinceReferenceDate: 800_055_300)
        let sessionID = UUID(
            uuidString: "EEEEEEEE-0000-0000-0000-000000000001"
        )!
        let generation = UUID(
            uuidString: "EEEEEEEE-0000-0000-0000-000000000002"
        )!
        let currentWatchEnvelope = makeEnvelope(
            sessionID: sessionID,
            sessionToken: 12,
            transportGenerationID: generation,
            sequence: 40,
            capturedAt: now
        )
        let priorSender = UUID(
            uuidString: "EEEEEEEE-0000-0000-0000-000000000003"
        )!
        let relaunchedSender = UUID(
            uuidString: "EEEEEEEE-0000-0000-0000-000000000004"
        )!
        let priorControl = WorkoutEnvelopeV1(
            kind: .control,
            sessionID: sessionID,
            sessionToken: 12,
            transportGenerationID: generation,
            sequence: 41,
            capturedAt: now,
            controlSenderID: priorSender,
            control: .requestCurrentSnapshot
        )
        var watchGate = WorkoutRemoteControlSequenceGate()
        do {
            expect(try watchGate.ingest(priorControl), "Watch should seed its replay gate")
            var relaunchedPhone = WorkoutControlEnvelopeSequencer(
                controlSenderID: relaunchedSender
            )
            let end = relaunchedPhone.makeEnvelope(
                control: .endAndSave,
                currentEnvelope: currentWatchEnvelope,
                capturedAt: now.addingTimeInterval(1)
            )
            expect(
                end?.sequence == 41,
                "a new phone process should also advance from the last Watch sequence for legacy compatibility"
            )
            expect(
                try end.map { try watchGate.ingest($0) } == true,
                "the first post-relaunch control should pass the retained Watch replay gate"
            )
            let delayedRetiredControl = WorkoutEnvelopeV1(
                kind: .control,
                sessionID: sessionID,
                sessionToken: 12,
                transportGenerationID: generation,
                sequence: 42,
                capturedAt: now.addingTimeInterval(2),
                controlSenderID: priorSender,
                control: .discard
            )
            expect(
                try watchGate.ingest(delayedRetiredControl) == false,
                "a retired phone process must never resume after relaunch"
            )
        } catch {
            expect(false, "post-relaunch control sequencing threw \(error)")
        }
    }

    private mutating func testRemoteControlGateRejectsFutureSenderWithoutPoisoningRelaunch() {
        let receivedAt = Date(timeIntervalSinceReferenceDate: 800_055_350)
        let sessionID = UUID(
            uuidString: "EFEFEFEF-0000-0000-0000-000000000001"
        )!
        let generation = UUID(
            uuidString: "EFEFEFEF-0000-0000-0000-000000000002"
        )!
        let futureSender = UUID(
            uuidString: "EFEFEFEF-0000-0000-0000-000000000003"
        )!
        let correctedSender = UUID(
            uuidString: "EFEFEFEF-0000-0000-0000-000000000004"
        )!
        let futureControl = WorkoutEnvelopeV1(
            kind: .control,
            sessionID: sessionID,
            sessionToken: 22,
            transportGenerationID: generation,
            sequence: 10,
            capturedAt: receivedAt.addingTimeInterval(100),
            controlSenderID: futureSender,
            control: .requestCurrentSnapshot
        )
        let correctedControl = WorkoutEnvelopeV1(
            kind: .control,
            sessionID: sessionID,
            sessionToken: 22,
            transportGenerationID: generation,
            sequence: 11,
            capturedAt: receivedAt.addingTimeInterval(1),
            controlSenderID: correctedSender,
            control: .endAndSave
        )
        var gate = WorkoutRemoteControlSequenceGate()
        do {
            expect(
                try !gate.ingest(futureControl, receivedAt: receivedAt),
                "a phone control beyond the bounded clock skew must be rejected"
            )
            expect(
                gate.currentSenderID == nil
                    && gate.latestCapturedAt == nil,
                "a rejected future sender must not advance Watch generation state"
            )
            expect(
                try gate.ingest(
                    correctedControl,
                    receivedAt: receivedAt.addingTimeInterval(1)
                ),
                "a corrected-clock phone relaunch must remain admissible"
            )
            expect(
                gate.currentSenderID == correctedSender,
                "only the corrected sender should become canonical"
            )
        } catch {
            expect(false, "future control gating threw \(error)")
        }
    }

    private mutating func testMirrorReducerDoesNotTurnFailedStartIntoFinishedRide() {
        let now = Date(timeIntervalSinceReferenceDate: 800_055_400)
        var reducer = WorkoutMirrorStateReducer()
        reducer.attachMirroredSession(at: now)
        _ = reducer.ingestBatch(
            [
                makeEnvelope(
                    sequence: 1,
                    capturedAt: now,
                    snapshot: WorkoutSnapshotV1(
                        state: .failed,
                        errorCode: .setupRequired
                    )
                ),
            ],
            receivedAt: now
        )
        reducer.confirmSessionState(.ended, at: now.addingTimeInterval(1))
        expect(
            reducer.presentation.connectionState == .failed
                && reducer.presentation.errorCode == .setupRequired,
            "native session teardown must preserve a mirrored startup failure"
        )

        var noSnapshotReducer = WorkoutMirrorStateReducer()
        noSnapshotReducer.attachMirroredSession(at: now)
        noSnapshotReducer.confirmSessionState(.ended, at: now)
        expect(
            noSnapshotReducer.presentation.connectionState == .failed,
            "native end without any verified snapshot must fail safely"
        )
    }

    private mutating func testIPhoneFallbackMergePreservesWatchPrecedence() {
        let start = Date(timeIntervalSinceReferenceDate: 800_055_500)
        let capture = start.addingTimeInterval(20)
        var reducer = WorkoutMirrorStateReducer()
        reducer.attachMirroredSession(at: capture)
        _ = reducer.ingestBatch(
            [
                makeEnvelope(
                    sequence: 1,
                    capturedAt: capture,
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: start
                    )
                ),
            ],
            receivedAt: capture
        )
        let phoneLocation = WorkoutLocationV1(
            latitude: 1.30,
            longitude: 103.80,
            capturedAt: capture,
            horizontalAccuracy: 4,
            altitude: 25,
            verticalAccuracy: 3,
            course: 90,
            speed: 7
        )
        let phone = WorkoutIPhoneTelemetryV1(
            isNavigating: true,
            capturedAt: capture,
            navigationDistanceMeters: 123,
            routeRemainingDistanceMeters: 456,
            routeRemainingTime: 78,
            instruction: "Turn left",
            location: phoneLocation
        )
        let fallback = WorkoutIPhoneTelemetryMerge.presentation(
            reducer.presentation,
            phone: phone,
            at: capture
        )
        expect(
            fallback.snapshot.cyclingDistance?.value == 123
                && fallback.snapshot.cyclingDistance?.source == .iPhoneNavigation,
            "iPhone navigation distance should fill an unavailable Watch distance"
        )
        expect(
            fallback.snapshot.currentSpeed?.value == 7
                && fallback.snapshot.currentSpeed?.source == .iPhoneLocation,
            "iPhone location speed should fill an unavailable Watch speed"
        )
        expect(
            fallback.snapshot.location == phoneLocation
                && fallback.navigation.routeRemainingDistanceMeters == 456,
            "iPhone location and navigation-only context should remain available"
        )

        let watchLocation = WorkoutLocationV1(
            latitude: 1.31,
            longitude: 103.81,
            capturedAt: capture,
            horizontalAccuracy: 2,
            altitude: 30,
            verticalAccuracy: 2,
            course: 100,
            speed: 8
        )
        let watchSnapshot = WorkoutSnapshotV1(
            state: .running,
            startDate: start,
            cyclingDistance: metric(200, .meters, capture, .healthKit),
            currentSpeed: metric(9, .metersPerSecond, capture, .pairedCyclingSensor),
            location: watchLocation,
            availability: [.cyclingDistance, .currentSpeed, .location, .altitude]
        )
        let watchPresentation = WorkoutMirrorPresentationV1(
            connectionState: .connected,
            snapshot: watchSnapshot,
            sessionID: UUID(),
            capturedAt: capture,
            receivedAt: capture,
            confirmedSessionState: .running,
            errorCode: nil,
            pendingControl: nil,
            finalSnapshot: nil,
            navigation: .empty
        )
        let preferred = WorkoutIPhoneTelemetryMerge.presentation(
            watchPresentation,
            phone: phone,
            at: capture
        )
        expect(
            preferred.snapshot.cyclingDistance?.value == 200
                && preferred.snapshot.currentSpeed?.value == 9
                && preferred.snapshot.location == watchLocation,
            "available Watch metrics must retain precedence over iPhone fallbacks"
        )

        let nativeEndedPresentation = WorkoutMirrorPresentationV1(
            connectionState: .ended,
            snapshot: reducer.presentation.snapshot,
            sessionID: reducer.presentation.sessionID,
            capturedAt: reducer.presentation.capturedAt,
            receivedAt: reducer.presentation.receivedAt,
            confirmedSessionState: .ended,
            errorCode: nil,
            pendingControl: nil,
            finalSnapshot: nil,
            navigation: .empty
        )
        let endedFallback = WorkoutIPhoneTelemetryMerge.presentation(
            nativeEndedPresentation,
            phone: phone,
            at: capture
        )
        expect(
            endedFallback.snapshot == reducer.presentation.snapshot,
            "phone telemetry must not mutate a natively ended workout while its last Watch snapshot is still active"
        )

        let stalePhoneLocation = WorkoutLocationV1(
            latitude: 1.29,
            longitude: 103.79,
            capturedAt: start.addingTimeInterval(-1),
            horizontalAccuracy: 4,
            altitude: 20,
            verticalAccuracy: 3,
            course: nil,
            speed: 5
        )
        let stalePhone = WorkoutIPhoneTelemetryV1(
            isNavigating: true,
            capturedAt: start.addingTimeInterval(-1),
            navigationDistanceMeters: 99,
            routeRemainingDistanceMeters: nil,
            routeRemainingTime: nil,
            instruction: nil,
            location: stalePhoneLocation
        )
        let rejectedStaleFallback = WorkoutIPhoneTelemetryMerge.presentation(
            reducer.presentation,
            phone: stalePhone,
            at: capture
        )
        expect(
            rejectedStaleFallback.snapshot.cyclingDistance == nil
                && rejectedStaleFallback.snapshot.currentSpeed == nil
                && rejectedStaleFallback.snapshot.location == nil,
            "phone telemetry captured before the Watch workout must not fill metrics"
        )

        let agedLocation = WorkoutLocationV1(
            latitude: 1.29,
            longitude: 103.79,
            capturedAt: start.addingTimeInterval(1),
            horizontalAccuracy: 4,
            altitude: 20,
            verticalAccuracy: 3,
            course: nil,
            speed: 5
        )
        var agedPhone = phone
        agedPhone.location = agedLocation
        let rejectedAgedLocation = WorkoutIPhoneTelemetryMerge.presentation(
            reducer.presentation,
            phone: agedPhone,
            at: capture
        )
        expect(
            rejectedAgedLocation.snapshot.currentSpeed == nil
                && rejectedAgedLocation.snapshot.location == nil,
            "expired phone speed, location, and altitude must become unavailable"
        )

        var futurePhone = phone
        futurePhone.location = WorkoutLocationV1(
            latitude: phoneLocation.latitude,
            longitude: phoneLocation.longitude,
            capturedAt: capture.addingTimeInterval(1),
            horizontalAccuracy: 4,
            altitude: 25,
            verticalAccuracy: 3,
            course: 90,
            speed: 7
        )
        let rejectedFutureLocation = WorkoutIPhoneTelemetryMerge.presentation(
            reducer.presentation,
            phone: futurePhone,
            at: capture
        )
        expect(
            rejectedFutureLocation.snapshot.currentSpeed == nil
                && rejectedFutureLocation.snapshot.location == nil,
            "future-dated phone location must not fill current metrics"
        )

        let watchWithoutAltitude = WorkoutLocationV1(
            latitude: 1.31,
            longitude: 103.81,
            capturedAt: capture,
            horizontalAccuracy: 2,
            altitude: nil,
            verticalAccuracy: nil,
            course: 100,
            speed: 8
        )
        let farPhone = WorkoutIPhoneTelemetryV1(
            isNavigating: false,
            capturedAt: nil,
            navigationDistanceMeters: nil,
            routeRemainingDistanceMeters: nil,
            routeRemainingTime: nil,
            instruction: nil,
            location: WorkoutLocationV1(
                latitude: 1.40,
                longitude: 103.90,
                capturedAt: capture,
                horizontalAccuracy: 3,
                altitude: 40,
                verticalAccuracy: 2,
                course: nil,
                speed: nil
            )
        )
        let noAltitudeMix = WorkoutIPhoneTelemetryMerge.presentation(
            WorkoutMirrorPresentationV1(
                connectionState: .connected,
                snapshot: WorkoutSnapshotV1(
                    state: .running,
                    startDate: start,
                    location: watchWithoutAltitude,
                    availability: [.location]
                ),
                sessionID: UUID(),
                capturedAt: capture,
                receivedAt: capture,
                confirmedSessionState: .running,
                errorCode: nil,
                pendingControl: nil,
                finalSnapshot: nil,
                navigation: .empty
            ),
            phone: farPhone,
            at: capture
        )
        expect(
            noAltitudeMix.snapshot.location == watchWithoutAltitude,
            "phone altitude must not be mixed into unrelated Watch coordinates"
        )
    }

    private mutating func testWorkoutErrorCopyDistinguishesTerminalUncertainty() {
        let terminalDetail = WorkoutErrorCopyV1.detail(
            .terminalChoiceUnconfirmed
        )
        expect(
            WorkoutErrorCopyV1.title(.terminalChoiceUnconfirmed)
                == "Finish choice unconfirmed",
            "terminal uncertainty should have its own user-facing title"
        )
        expect(
            terminalDetail.contains("Save or Discard")
                && terminalDetail.contains("Check Bicino on Apple Watch"),
            "terminal uncertainty should tell the rider what was not confirmed and where to check"
        )
        expect(
            !terminalDetail.contains("workout continues on Watch"),
            "terminal uncertainty must not claim that an accepted finish command is still running"
        )

        let now = Date(timeIntervalSinceReferenceDate: 800_055_900)
        var activeReducer = WorkoutMirrorStateReducer()
        activeReducer.attachMirroredSession(at: now)
        _ = activeReducer.ingestBatch(
            [makeEnvelope(sequence: 1, capturedAt: now)],
            receivedAt: now.addingTimeInterval(0.25)
        )
        let activeContext = WorkoutErrorCopyV1.context(
            for: activeReducer.presentation
        )
        expect(
            activeContext == .activeWorkout,
            "an active presentation should derive continuity guidance"
        )
        expect(
            WorkoutErrorCopyV1.detail(
                .watchUnavailable,
                context: activeContext
            )
                .contains("workout continues on Watch"),
            "ordinary Watch unavailability should retain its distinct continuity guidance"
        )

        let launchID = UUID()
        var launchReducer = WorkoutMirrorStateReducer()
        expect(
            launchReducer.beginWatchLaunch(
                id: launchID,
                at: now,
                timeout: 15
            ),
            "launch context fixture should start"
        )
        launchReducer.completeWatchLaunch(
            id: launchID,
            succeeded: false,
            error: .watchUnavailable
        )
        let launchContext = WorkoutErrorCopyV1.context(
            for: launchReducer.presentation
        )
        let launchDetail = WorkoutErrorCopyV1.detail(
            .watchUnavailable,
            context: launchContext
        )
        expect(
            launchContext == .workoutLaunch
                && launchDetail.contains("workout did not start")
                && !launchDetail.contains("workout continues on Watch"),
            "failed Watch launch must say the workout did not start"
        )

        var fatalReducer = WorkoutMirrorStateReducer()
        fatalReducer.attachMirroredSession(at: now)
        fatalReducer.failSession(error: .watchUnavailable)
        let fatalContext = WorkoutErrorCopyV1.context(
            for: fatalReducer.presentation
        )
        expect(
            fatalContext == .general
                && !WorkoutErrorCopyV1.detail(
                .watchUnavailable,
                context: fatalContext
            ).contains("workout continues on Watch"),
            "pre-snapshot mirrored-session failure must stay neutral about workout continuity"
        )
    }

    private mutating func testLatestEnvelopeBufferCoalescesBackpressure() {
        let now = Date(timeIntervalSinceReferenceDate: 800_056_000)
        let first = makeEnvelope(sequence: 1, capturedAt: now)
        let second = makeEnvelope(
            sequence: 2,
            capturedAt: now.addingTimeInterval(1)
        )
        let third = makeEnvelope(
            sequence: 3,
            capturedAt: now.addingTimeInterval(2),
            snapshot: WorkoutSnapshotV1(
                state: .paused,
                startDate: now.addingTimeInterval(-1)
            )
        )
        var buffer = WorkoutLatestEnvelopeBuffer()
        buffer.offer(first)
        expect(buffer.beginNext() == first, "the first envelope should send immediately")
        buffer.offer(second)
        buffer.offer(third)
        expect(
            buffer.pending == third,
            "backpressure must retain only the newest complete pending snapshot"
        )
        buffer.complete(succeeded: true)
        expect(buffer.beginNext() == third, "the next send should skip the obsolete middle snapshot")
        buffer.complete(succeeded: false)
        expect(
            buffer.beginNext() == third,
            "a failed final send should remain available for one reconnect retry"
        )
        buffer.interruptInFlight()
        expect(
            buffer.pending == third && buffer.inFlight == nil,
            "a disconnect should safely return the interrupted full snapshot to pending"
        )

        let acknowledgement = WorkoutEnvelopeV1(
            kind: .acknowledgement,
            sessionID: second.sessionID,
            sessionToken: second.sessionToken,
            transportGenerationID: second.transportGenerationID,
            sequence: 4,
            capturedAt: now.addingTimeInterval(3),
            acknowledgement: WorkoutAcknowledgementV1(
                control: .pause,
                resultingState: .paused,
                acknowledgedSequence: 1
            )
        )
        var priorityBuffer = WorkoutLatestEnvelopeBuffer()
        priorityBuffer.offer(second)
        priorityBuffer.offer(acknowledgement)
        expect(
            priorityBuffer.pending == second,
            "a later acknowledgement must not evict a pending full metric snapshot"
        )
        expect(
            priorityBuffer.beginNext() == second,
            "the earlier snapshot should preserve sequence order"
        )
        priorityBuffer.complete(succeeded: true)
        expect(
            priorityBuffer.beginNext() == acknowledgement,
            "the acknowledgement must remain queued after the snapshot"
        )

        var staleOfferBuffer = WorkoutLatestEnvelopeBuffer()
        staleOfferBuffer.offer(third)
        expect(
            staleOfferBuffer.beginNext() == third,
            "the newest snapshot should enter flight"
        )
        staleOfferBuffer.offer(second)
        staleOfferBuffer.complete(succeeded: true)
        expect(
            staleOfferBuffer.beginNext() == nil,
            "an older offer must not replay after a newer in-flight snapshot"
        )

        let terminal = makeEnvelope(
            sequence: 5,
            capturedAt: now.addingTimeInterval(4),
            snapshot: WorkoutSnapshotV1(
                state: .ended,
                startDate: now.addingTimeInterval(-1),
                terminalOutcome: .saved
            )
        )
        var shutdownBuffer = WorkoutLatestEnvelopeBuffer()
        shutdownBuffer.offer(first)
        expect(
            shutdownBuffer.beginNext() == first,
            "the live snapshot should be in flight before shutdown"
        )
        shutdownBuffer.offer(acknowledgement)
        shutdownBuffer.offer(terminal)
        expect(
            shutdownBuffer.prioritizeShutdownEnvelope(terminal),
            "shutdown should supersede an older hung live send"
        )
        expect(
            shutdownBuffer.beginNext() == terminal,
            "the final snapshot must become the bounded shutdown attempt"
        )
        shutdownBuffer.complete(succeeded: true)
        expect(
            shutdownBuffer.beginNext() == nil,
            "obsolete pre-terminal traffic must not follow the final snapshot"
        )
    }

    private mutating func testWorkoutFormattingKeepsUnavailableValuesDistinctFromZero() {
        expect(WorkoutValueFormatter.heartRate(nil) == "--", "missing heart rate should be unavailable")
        expect(WorkoutValueFormatter.heartRate(0) == "--", "zero heart rate should be unavailable")
        expect(WorkoutValueFormatter.whole(nil) == "--", "missing power should be unavailable")
        expect(WorkoutValueFormatter.whole(0) == "0", "available zero power should remain zero")
        expect(WorkoutValueFormatter.speed(nil) == "--", "missing speed should be unavailable")
        expect(WorkoutValueFormatter.speed(0) == "0.0", "available stopped speed should remain zero")
        expect(
            WorkoutValueFormatter.speed(.greatestFiniteMagnitude) == "--",
            "speed conversion overflow should remain unavailable"
        )
        expect(
            WorkoutValueFormatter.averageSpeed(
                distanceMeters: 1_000,
                elapsedSeconds: 200
            ) == "18.0",
            "average speed should derive kilometers per hour from distance and active time"
        )
        expect(
            WorkoutValueFormatter.averageSpeed(
                distanceMeters: 0,
                elapsedSeconds: 200
            ) == "0.0",
            "an available zero-distance average should remain zero"
        )
        expect(
            WorkoutValueFormatter.averageSpeed(
                distanceMeters: 1_000,
                elapsedSeconds: 0
            ) == "--",
            "average speed requires positive elapsed time"
        )
        expect(
            WorkoutValueFormatter.averageSpeed(
                distanceMeters: .greatestFiniteMagnitude,
                elapsedSeconds: .leastNonzeroMagnitude
            ) == "--",
            "average speed division overflow should remain unavailable"
        )
        expect(WorkoutValueFormatter.distance(nil) == "--", "missing distance should be unavailable")
        expect(WorkoutValueFormatter.distance(0) == "0", "available zero distance should remain zero")
        expect(WorkoutValueFormatter.duration(nil) == "--:--", "missing elapsed time should be unavailable")
        expect(WorkoutValueFormatter.duration(3_661) == "1:01:01", "long duration should retain hours")
        expect(
            WorkoutValueFormatter.duration(Double.greatestFiniteMagnitude) == "596523:14:07",
            "huge finite duration should saturate instead of trapping"
        )
    }

    private mutating func testWorkoutWatchAvailabilityPolicy() {
        expect(
            WorkoutWatchAvailabilityPolicyV1.resolve(
                isSupported: false,
                isActivated: false,
                isPaired: false,
                isCompanionAppInstalled: false,
                isReachable: false
            ) == .unsupported,
            "unsupported devices must not be treated as Watch-ready"
        )
        expect(
            WorkoutWatchAvailabilityPolicyV1.resolve(
                isSupported: true,
                isActivated: false,
                activationFailed: true,
                isPaired: false,
                isCompanionAppInstalled: false,
                isReachable: false
            ) == .activationFailed,
            "a failed WCSession activation must become a recoverable error state"
        )
        expect(
            WorkoutWatchAvailabilityPolicyV1.resolve(
                isSupported: true,
                isActivated: false,
                isPaired: false,
                isCompanionAppInstalled: false,
                isReachable: false
            ) == .activating,
            "pairing state must not be trusted before WCSession activates"
        )
        expect(
            WorkoutWatchAvailabilityPolicyV1.resolve(
                isSupported: true,
                isActivated: true,
                isPaired: false,
                isCompanionAppInstalled: false,
                isReachable: false
            ) == .noPairedWatch,
            "an activated unpaired phone must report that no Watch is paired"
        )
        expect(
            WorkoutWatchAvailabilityPolicyV1.resolve(
                isSupported: true,
                isActivated: true,
                isPaired: true,
                isCompanionAppInstalled: false,
                isReachable: false
            ) == .companionAppNotInstalled,
            "WatchConnectivity's reported companion-install state must remain available for non-start uses"
        )
        expect(
            WorkoutStartAvailabilityPolicyV1.resolve(.activating)
                == .waitForActivation,
            "the start flow must wait for WatchConnectivity activation before deciding"
        )
        expect(
            WorkoutStartAvailabilityPolicyV1.resolve(.unsupported)
                == .unsupported,
            "unsupported iPhones must remain blocked"
        )
        expect(
            WorkoutStartAvailabilityPolicyV1.resolve(.activationFailed)
                == .activationFailed,
            "WatchConnectivity activation failures must remain recoverable"
        )
        expect(
            WorkoutStartAvailabilityPolicyV1.resolve(.noPairedWatch)
                == .noPairedWatch,
            "an iPhone without a paired Watch must remain blocked"
        )
        expect(
            WorkoutStartAvailabilityPolicyV1.resolve(
                .companionAppNotInstalled
            ) == .attemptHealthKitLaunch,
            "a negative WatchConnectivity install flag must still attempt the authoritative HealthKit launch"
        )
        for isReachable in [false, true] {
            let availability = WorkoutWatchAvailabilityPolicyV1.resolve(
                isSupported: true,
                isActivated: true,
                isPaired: true,
                isCompanionAppInstalled: true,
                isReachable: isReachable
            )
            expect(
                availability == .ready(isReachable: isReachable),
                "an installed companion must be start-ready regardless of immediate messaging reachability"
            )
            expect(
                WorkoutStartAvailabilityPolicyV1.resolve(availability)
                    == .attemptHealthKitLaunch,
                "a ready Watch must attempt the HealthKit launch regardless of reachability"
            )
        }
    }

    private mutating func testDiscardedWorkoutSummaryDismissalPolicy() {
        let now = Date(timeIntervalSinceReferenceDate: 800_399_800)
        let sessionID = UUID(
            uuidString: "EEEEEEEE-0000-0000-0000-000000000000"
        )!

        func presentation(
            outcome: WorkoutTerminalOutcomeV1,
            errorCode: WorkoutSafeErrorCodeV1? = nil,
            pendingControl: WorkoutControlV1? = nil
        ) -> WorkoutMirrorPresentationV1 {
            let snapshot = WorkoutSnapshotV1(
                state: .ended,
                startDate: now.addingTimeInterval(-30),
                terminalOutcome: outcome
            )
            return WorkoutMirrorPresentationV1(
                connectionState: .ended,
                snapshot: snapshot,
                sessionID: sessionID,
                capturedAt: now,
                receivedAt: now,
                confirmedSessionState: .ended,
                errorCode: errorCode,
                pendingControl: pendingControl,
                finalSnapshot: snapshot,
                navigation: .empty
            )
        }

        expect(
            presentation(outcome: .discarded)
                .shouldAutomaticallyResetAfterDiscard,
            "a verified ordinary discard must return the main screen to idle"
        )
        expect(
            !presentation(outcome: .saved)
                .shouldAutomaticallyResetAfterDiscard,
            "a saved workout must retain its completion summary"
        )
        expect(
            !presentation(
                outcome: .discarded,
                errorCode: .anotherWorkoutActive
            ).shouldAutomaticallyResetAfterDiscard,
            "a terminal error must remain visible even when the displaced workout was discarded"
        )
        expect(
            !presentation(
                outcome: .discarded,
                pendingControl: .discard
            ).shouldAutomaticallyResetAfterDiscard,
            "the UI must not reset before the discard command is confirmed"
        )
    }

    private mutating func testWorkoutDiscardDisclosureRequiresFinalConfirmation() {
        var discardCount = 0
        let discard = { discardCount += 1 }
        let expectedSessionID = UUID(
            uuidString: "EEEEEEEE-0000-0000-0000-000000000001"
        )!
        let replacementSessionID = UUID(
            uuidString: "EEEEEEEE-0000-0000-0000-000000000002"
        )!

        WorkoutDiscardDisclosureV1.perform(
            .cancel,
            expectedSessionID: expectedSessionID,
            currentSessionID: expectedSessionID,
            discard: discard
        )
        expect(
            discardCount == 0,
            "Keep Riding must not discard or end the active workout"
        )

        WorkoutDiscardDisclosureV1.perform(
            .confirmDiscard,
            expectedSessionID: expectedSessionID,
            currentSessionID: replacementSessionID,
            discard: discard
        )
        expect(
            discardCount == 0,
            "a stale warning must not discard a replacement workout"
        )

        WorkoutDiscardDisclosureV1.perform(
            .confirmDiscard,
            expectedSessionID: expectedSessionID,
            currentSessionID: expectedSessionID,
            discard: discard
        )
        expect(
            discardCount == 1,
            "the final destructive confirmation must discard exactly once"
        )
        expect(
            WorkoutDiscardDisclosureV1.title == "Discard Ride?"
                && WorkoutDiscardDisclosureV1.message
                    == "Discarding can't be undone.",
            "the final discard warning must use the concise rider-facing copy"
        )
        expect(
            WorkoutDiscardDisclosureV1.cancelTitle == "Keep Riding"
                && WorkoutDiscardDisclosureV1.confirmTitle == "Discard Workout",
            "the final discard decision must remain explicit and unambiguous"
        )
    }

    private mutating func testTerminalErrorAndTakeoverCopyUseDurableDisposition() {
        expect(
            WorkoutTerminalErrorPolicy.resolve(
                summaryError: nil,
                persistedFinishError: nil
            ) == nil,
            "a successful retry must not promote a transient failure into the terminal result"
        )
        expect(
            WorkoutTerminalErrorPolicy.resolve(
                summaryError: nil,
                persistedFinishError: .anotherWorkoutActive
            ) == .anotherWorkoutActive,
            "a persisted takeover cause must reach the terminal result"
        )
        expect(
            WorkoutTerminalErrorPolicy.resolve(
                summaryError: .terminalChoiceConflict,
                persistedFinishError: .anotherWorkoutActive
            ) == .anotherWorkoutActive,
            "a durable takeover cause must outrank an older generic summary error"
        )

        let liveDiscard = WorkoutCrossAppTakeoverCopyV1.live(
            disposition: .discard
        )
        let summaryDiscard = WorkoutCrossAppTakeoverCopyV1.summary(
            disposition: .discard
        )
        expect(
            liveDiscard.contains("discarding")
                && !liveDiscard.contains("saving"),
            "live takeover copy must describe the rider's Discard choice"
        )
        expect(
            summaryDiscard.contains("discarded")
                && !summaryDiscard.contains(" saved"),
            "terminal takeover copy must never claim a discarded ride was saved"
        )
        expect(
            WorkoutCrossAppTakeoverCopyV1.summary(disposition: .save)
                .contains("saved"),
            "saved takeover copy must still identify the partial save"
        )
    }

    private mutating func testIPhoneStartsUseWatchAvailabilityAndWatchStartsDirectly() {
        let iosAppDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BikeComputer")
        let iPhoneViewURL = iosAppDirectory
            .appendingPathComponent("BikeComputer/Views/WorkoutViews.swift")
        let watchViewURL = iosAppDirectory
            .appendingPathComponent("BikeComputerWatch/Views/WorkoutStartView.swift")
        guard let iPhoneSource = try? String(
            contentsOf: iPhoneViewURL,
            encoding: .utf8
        ),
        let watchSource = try? String(
            contentsOf: watchViewURL,
            encoding: .utf8
        ) else {
            expect(false, "start-surface source files must be available")
            return
        }

        let iPhoneAvailabilityCount = iPhoneSource
            .components(separatedBy: "WorkoutStartButton(")
            .count - 1
        expect(
            iPhoneAvailabilityCount == 4,
            "all four iPhone compact, dashboard, failed, and disconnected start routes must use the Watch availability flow"
        )
        expect(
            !iPhoneSource.contains("WorkoutStartDisclosureV1"),
            "iPhone start surfaces must not show the cross-app workout warning"
        )
        let iPhoneConfirmationComponent = iPhoneSource
            .components(separatedBy: "struct WorkoutCompactCard").first ?? ""
        let compactIPhoneConfirmation = iPhoneConfirmationComponent.filter {
            !$0.isWhitespace
        }
        expect(
            iPhoneConfirmationComponent.contains(
                "switch WorkoutStartAvailabilityPolicyV1.resolve(availability)"
            )
                && iPhoneConfirmationComponent.contains(
                    "case .attemptHealthKitLaunch:\n            pendingStart = false\n            action()"
                ),
            "the iPhone component must let the start policy reach the authoritative HealthKit launch"
        )
        expect(
            compactIPhoneConfirmation.contains(
                "YouneedtheBicinoapponanAppleWatchtostarttrackingyourworkout"
            )
                && compactIPhoneConfirmation.contains(
                    ".alert(item:$presentedAlert)"
                )
                && !iPhoneConfirmationComponent.contains(
                    "Install Bicino on Apple Watch"
                ),
            "iPhone must keep paired-Watch guidance without blocking on a stale companion-install flag"
        )

        expect(
            watchSource.contains("manager.startOutdoorCycling()")
                && !watchSource.contains("showingStartConfirmation")
                && !watchSource.contains("WorkoutStartDisclosureV1"),
            "Watch Start Ride must start directly without a confirmation screen"
        )
        expect(
            !watchSource.contains("Max HR")
                && !watchSource.contains("heartRateZoneSettings"),
            "maximum-heart-rate configuration must not remain on the Watch start screen"
        )
    }

    private mutating func testWatchOfflineNavigationUIFlow() {
        let watchDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BikeComputer/BikeComputerWatch")
        let sourceURLs = [
            "start": watchDirectory.appendingPathComponent(
                "Views/WorkoutStartView.swift"
            ),
            "library": watchDirectory.appendingPathComponent(
                "Views/WatchRouteLibraryView.swift"
            ),
            "status": watchDirectory.appendingPathComponent(
                "Views/WatchNavigationStatusView.swift"
            ),
            "navigationOnly": watchDirectory.appendingPathComponent(
                "Views/WatchNavigationOnlyView.swift"
            ),
            "manager": watchDirectory.appendingPathComponent(
                "Managers/WatchNavigationManager.swift"
            ),
            "settings": watchDirectory.appendingPathComponent(
                "Views/WatchSettingsView.swift"
            ),
            "root": watchDirectory.appendingPathComponent(
                "Views/WatchWorkoutRootView.swift"
            ),
            "live": watchDirectory.appendingPathComponent(
                "Views/LiveWorkoutView.swift"
            ),
        ]
        var sources: [String: String] = [:]
        for (name, url) in sourceURLs {
            guard let source = try? String(
                contentsOf: url,
                encoding: .utf8
            ) else {
                expect(
                    false,
                    "Watch offline-navigation source must exist: \(name)"
                )
                return
            }
            sources[name] = source
        }

        let start = sources["start"] ?? ""
        expect(
            start.contains(
                "Label(\"Offline Navigation\", systemImage: \"map\")"
            )
                && start.components(
                    separatedBy: ".frame(maxWidth: .infinity, minHeight: 52)"
                ).count - 1 == 2
                && !start.contains("Picker(\"Navigation\"")
                && !start.contains("selectedNavigation"),
            "Watch home must offer equal-height Ride and backgroundless Offline Navigation actions without a navigation picker"
        )

        let library = sources["library"] ?? ""
        let manager = sources["manager"] ?? ""
        expect(
            library.contains("pendingRoute = route")
                && library.contains(".confirmationDialog(")
                && library.contains("\"Start Navigation?\"")
                && library.contains(
                    "navigationManager.startInstalledRoute(routeID: route.id)"
                )
                && manager.contains(
                    "func startInstalledRoute(routeID: UUID)"
                )
                && manager.contains("case .awaitingStartConfirmation")
                && manager.contains("func startAnyway()"),
            "selecting an offline route must confirm intent and retain the measured far-start warning"
        )

        let status = sources["status"] ?? ""
        expect(
            status.contains("let suffix = \" checkpoint\"")
                && status.contains(
                    "\"Off route by \\(compactDistance($0))\""
                )
                && status.contains("snapshot.routeRemainingDistanceMeters")
                && status.contains(".background(.quaternary")
                && status.contains("navigationManager.routeAttribution")
                && status.contains("RouteProviderPolicyV1.importedGPX")
                && status.contains("navigationManager.onlineStatus")
                && status.contains("Bicino is controlled by iPhone")
                && !status.contains("Rerouting unavailable offline"),
            "active Watch guidance keeps the compact offline layout while surfacing online attribution and actionable Bicino failures"
        )

        let navigationOnly = sources["navigationOnly"] ?? ""
        expect(
            navigationOnly.contains(
                "Label(\"Start Workout\", systemImage: \"bicycle\")"
            )
                && navigationOnly.contains("manager.startOutdoorCycling()")
                && navigationOnly.contains(
                    "Label(\"End Navigation\", systemImage: \"stop.fill\")"
                )
                && navigationOnly.contains(
                    "navigationManager.stopNavigation()"
                )
                && navigationOnly.contains("WatchSettingsView("),
            "navigation-only mode must independently start a workout, end navigation, or open live navigation settings"
        )

        let settings = sources["settings"] ?? ""
        let root = sources["root"] ?? ""
        let live = sources["live"] ?? ""
        expect(
            settings.contains("WatchOnlineDestinationListView(")
                && settings.contains("favoriteStore.favorites")
                && settings.contains(
                    "navigationManager.startOnline(destination: destination)"
                )
                && settings.contains("navigationManager.recalculateOnlineRoute()")
                && root.contains("favoriteStore: favoriteStore")
                && live.contains("WatchSettingsView("),
            "synced online destinations and the policy toggle must remain reachable before and during a ride"
        )
    }

    private mutating func testHeartRateZoneConfigurationLivesInIPhoneDeveloperSettings() {
        let iosAppDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BikeComputer")
        let settingsURL = iosAppDirectory
            .appendingPathComponent("BikeComputer/Views/SettingsView.swift")
        let monitorURL = iosAppDirectory
            .appendingPathComponent(
                "BikeComputer/Managers/WorkoutWatchAvailabilityMonitor.swift"
            )
        let watchDelegateURL = iosAppDirectory
            .appendingPathComponent("BikeComputerWatch/WatchAppDelegate.swift")
        guard let settingsSource = try? String(
            contentsOf: settingsURL,
            encoding: .utf8
        ), let monitorSource = try? String(
            contentsOf: monitorURL,
            encoding: .utf8
        ), let watchDelegateSource = try? String(
            contentsOf: watchDelegateURL,
            encoding: .utf8
        ) else {
            expect(false, "heart-zone settings source files must be available")
            return
        }

        expect(
            settingsSource.contains("Text(\"Workout Heart Zones\")")
                && settingsSource.contains(
                    "set: watchAvailability.setMaximumHeartRateBPM"
                )
                && settingsSource.contains("The default is 190 BPM"),
            "Developer Settings must own the visible maximum-heart-rate control and document its default"
        )
        expect(
            monitorSource.contains("session.updateApplicationContext(")
                && monitorSource.contains(
                    "WorkoutHeartRateZoneSyncContext.applicationContext("
                )
                && watchDelegateSource.contains(
                    "WatchHeartRateZoneSettingsReceiver"
                )
                && watchDelegateSource.contains(
                    "workoutManager.setMaximumHeartRateBPM(value)"
                ),
            "iPhone maximum heart rate must sync to the paired Watch and update its production manager"
        )
    }

    private mutating func testEveryDiscardSurfaceRequiresFinalConfirmation() {
        let iosAppDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BikeComputer")
        let iPhoneViewURL = iosAppDirectory
            .appendingPathComponent("BikeComputer/Views/WorkoutViews.swift")
        let watchViewURL = iosAppDirectory
            .appendingPathComponent("BikeComputerWatch/Views/LiveWorkoutView.swift")
        guard let iPhoneSource = try? String(
            contentsOf: iPhoneViewURL,
            encoding: .utf8
        ),
        let watchSource = try? String(
            contentsOf: watchViewURL,
            encoding: .utf8
        ) else {
            expect(false, "discard-surface source files must be available")
            return
        }

        for (surface, source, sessionSource) in [
            ("iPhone", iPhoneSource, "store.presentation.sessionID"),
            ("Watch", watchSource, "manager.activeSessionID"),
        ] {
            let compactSource = source.filter { !$0.isWhitespace }
            expect(
                compactSource.contains(
                    "Button(\"DiscardWorkout\",role:.destructive){requestDiscardConfirmation(for:sessionID)}"
                ),
                "\(surface) finish options must request, not execute, discard"
            )
            expect(
                compactSource.contains(
                    "caseoptions(sessionID:UUID)"
                )
                    && compactSource.contains(
                        "casediscardConfirmation(sessionID:UUID)"
                    )
                    && compactSource.contains(".onChange(of:\(sessionSource))"),
                "\(surface) finish prompts must be scoped to and invalidated with their session"
            )
        }

        let compactIPhoneSource = iPhoneSource.filter { !$0.isWhitespace }
        expect(
            compactIPhoneSource.contains(
                "WorkoutDiscardDisclosureV1.perform(.cancel,expectedSessionID:sessionID,currentSessionID:store.presentation.sessionID,discard:onDiscard)"
            )
                && compactIPhoneSource.contains(
                    "WorkoutDiscardDisclosureV1.perform(.confirmDiscard,expectedSessionID:sessionID,currentSessionID:store.presentation.sessionID,discard:onDiscard)"
                )
                && compactIPhoneSource.contains(
                    "isPresented:discardConfirmationPresented"
                ),
            "iPhone final warning must preserve shared disclosure policy and session capture"
        )

        let compactWatchSource = watchSource.filter { !$0.isWhitespace }
        expect(
            compactWatchSource.contains(
                "ifcase.discardConfirmation(letsessionID)=finishPrompt{discardConfirmationView(sessionID:sessionID)}"
            )
                && compactWatchSource.contains(
                    "Button(WorkoutDiscardDisclosureV1.confirmTitle,role:.destructive){finishPrompt=nilguardmanager.activeSessionID==sessionIDelse{return}manager.discard()}"
                )
                && compactWatchSource.contains(
                    "Button(WorkoutDiscardDisclosureV1.cancelTitle,role:.cancel){finishPrompt=nil}"
                ),
            "Watch dedicated discard screen must preserve disclosure choices and capture its session before dismissal"
        )
        expect(
            watchSource.contains("\"Finish Ride?\"")
                && watchSource.contains(
                    "\"Saving creates a workout in your Fitness app.\""
                ),
            "Watch finish confirmation must use the concise rider-facing copy"
        )
    }

    private mutating func testWorkoutUICompositionRetainsPhaseThreeExitCriteria() {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "BikeComputer/BikeComputer/Views/WorkoutViews.swift"
            )
        let contentViewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BikeComputer/BikeComputer/ContentView.swift")
        let appURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "BikeComputer/BikeComputer/BikeComputerApp.swift"
            )
        let liveWatchViewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "BikeComputer/BikeComputerWatch/Views/LiveWorkoutView.swift"
            )
        let navigationDetailsViewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "BikeComputer/BikeComputer/Views/NavigationDetailsView.swift"
            )
        let heartRateZoneStripURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "BikeComputer/BikeComputer/Views/HeartRateZoneStrip.swift"
            )
        let summaryWatchViewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "BikeComputer/BikeComputerWatch/Views/WorkoutSummaryView.swift"
            )
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8),
              let contentViewSource = try? String(
                contentsOf: contentViewURL,
                encoding: .utf8
              ),
              let appSource = try? String(
                contentsOf: appURL,
                encoding: .utf8
              ),
              let liveWatchViewSource = try? String(
                contentsOf: liveWatchViewURL,
                encoding: .utf8
              ),
              let navigationDetailsViewSource = try? String(
                contentsOf: navigationDetailsViewURL,
                encoding: .utf8
              ),
              let heartRateZoneStripSource = try? String(
                contentsOf: heartRateZoneStripURL,
                encoding: .utf8
              ),
              let summaryWatchViewSource = try? String(
                contentsOf: summaryWatchViewURL,
                encoding: .utf8
              ) else {
            expect(false, "workout UI source must be available")
            return
        }

        for metricTitle in [
            "Heart Rate",
            "Speed",
            "Distance",
            "Energy",
            "Power",
            "Cadence",
            "Average HR",
            "Average Speed",
            "Altitude",
        ] {
            expect(
                source.contains("metric(\n                        \"\(metricTitle)\""),
                "dashboard must retain the \(metricTitle) metric tile"
            )
        }
        expect(
            source.contains("TimelineView(.periodic(from: Date(), by: 1))")
                && source.contains("captureAgeLabel(age)"),
            "dashboard must render live capture age"
        )
        expect(
            source.contains(
                "if store.presentation.connectionState == .ended {"
            )
                && source.contains("HeartRateZoneBreakdown(")
                && source.contains(
                    "durations: snapshot.heartRateZoneDurations"
                ),
            "ended workout summaries must render the authoritative heart-rate zone breakdown"
        )
        for controlRoute in [
            "Button(action: onMarkSegment)",
            "Button(action: onResume)",
            "Button(action: onPause)",
            "Button(\"End and Save\") {",
            "onEndAndSave()",
            "WorkoutDiscardDisclosureV1.perform(",
            "discard: onDiscard",
            "if onDone()",
        ] {
            expect(
                source.contains(controlRoute),
                "dashboard must retain control wiring: (controlRoute)"
            )
        }
        expect(
            source.contains("connectionState == .unsupported")
                && source.contains("connectionState == .disconnected")
                && source.contains("connectionState == .ended")
                && source.contains("Waiting for the final saved or discarded result")
                && source.contains("Saved by Apple Watch")
                && source.contains("Not saved to Health")
                && source.contains("Finished on Apple Watch"),
            "dashboard must retain unsupported, disconnected, final-wait, and terminal summary states"
        )

        let compactSource = source.filter { !$0.isWhitespace }
        let compactContentViewSource =
            contentViewSource.filter { !$0.isWhitespace }
        let compactLiveWatchViewSource =
            liveWatchViewSource.filter { !$0.isWhitespace }
        let compactNavigationDetailsViewSource =
            navigationDetailsViewSource.filter { !$0.isWhitespace }
        let compactHeartRateZoneStripSource =
            heartRateZoneStripSource.filter { !$0.isWhitespace }
        for metricBinding in [
            "metric(\"HeartRate\",WorkoutValueFormatter.heartRate(snapshot.currentHeartRate?.value),\"\",\"heart.fill\",.red,valueSymbol:\"heart.fill\",accessibilityUnit:\"beatsperminute\")",
            "metric(\"Speed\",WorkoutValueFormatter.speed(snapshot.currentSpeed?.value),\"KM/H\"",
            "metric(\"Distance\",WorkoutValueFormatter.distance(snapshot.cyclingDistance?.value),WorkoutValueFormatter.distanceUnit(snapshot.cyclingDistance?.value)",
            "metric(\"Energy\",WorkoutValueFormatter.energy(snapshot.activeEnergy?.value),\"KCAL\"",
            "metric(\"Power\",WorkoutValueFormatter.whole(snapshot.cyclingPower?.value),\"W\"",
            "metric(\"Cadence\",WorkoutValueFormatter.whole(snapshot.cyclingCadence?.value),\"RPM\"",
            "metric(\"AverageHR\",WorkoutValueFormatter.heartRate(snapshot.averageHeartRate?.value),\"BPM\"",
            "metric(\"Altitude\",altitudeValue(snapshot.location?.altitude),\"M\"",
        ] {
            expect(
                compactSource.contains(metricBinding),
                "each workout metric title must remain bound to its matching snapshot value"
            )
        }
        expect(
            compactSource.contains(
                "HeartRateZoneStrip(currentZone:snapshot.currentHeartRateZone)"
            )
                && compactHeartRateZoneStripSource.contains(
                    "ForEach(1...zoneCount,id:\\.self)"
                )
                && compactHeartRateZoneStripSource.contains(
                    "Text(\"ZONE\\(zone)\")"
                )
                && compactHeartRateZoneStripSource.contains(
                    "Image(systemName:\"heart.fill\")"
                )
                && compactHeartRateZoneStripSource.contains(
                    "ifletnormalizedCurrentZone{GeometryReader"
                )
                && compactHeartRateZoneStripSource.contains(
                    ".frame(width:isCurrent?activeWidth:inactiveWidth)"
                )
                && !compactHeartRateZoneStripSource.contains(
                    "letequalWidth="
                ),
            "dashboard heart zones must stay hidden until a valid zone exists, then expand the active heart-labeled position"
        )
        expect(
            compactSource.contains(
                "Button(action:onMarkSegment){HStack(spacing:6){WorkoutSegmentNumberBadge(number:currentSegmentNumber,diameter:22)Text(\"Segment\")}}"
            )
                && compactSource.contains(
                    "ifpresentation.sessionState==.paused{Button(action:onResume){Label(\"Resume\""
                )
                && compactSource.contains(
                    "else{Button(action:onPause){Label(\"Pause\""
                )
                && compactSource.contains(
                    ".accessibilityLabel(\"Markworkoutsegment\")"
                )
                && compactSource.contains(
                    "Button(\"EndandSave\"){finishPrompt=nilguardstore.presentation.sessionID==sessionIDelse{return}onEndAndSave()}"
                )
                && compactSource.contains(
                    "Button(\"DiscardWorkout\",role:.destructive){requestDiscardConfirmation(for:sessionID)}"
                )
                && compactSource.contains(
                    ".background{finishPromptPresenter}"
                )
                && compactSource.contains(
                    "privatevarfinishPromptPresenter:someView{Color.clear.tint(.accentColor).confirmationDialog("
                )
                && compactSource.contains(
                    "Button(WorkoutDiscardDisclosureV1.cancelTitle,role:.cancel)"
                )
                && compactSource.contains(
                    "WorkoutDiscardDisclosureV1.perform(.confirmDiscard,expectedSessionID:sessionID,currentSessionID:store.presentation.sessionID,discard:onDiscard)"
                )
                && compactSource.contains(
                    "WorkoutFinishButton(store:store,onEndAndSave:onEndAndSave,onDiscard:onDiscard){Label(\"End\""
                ),
            "dashboard labels must remain bound to the matching control closures"
        )
        expect(
            compactSource.contains(
                "presentation.pendingControl!=nil&&presentation.pendingControl!=.markSegment"
            )
                && compactNavigationDetailsViewSource.contains(
                    "presentation.pendingControl==nil||presentation.pendingControl==.markSegment"
                ),
            "iPhone lifecycle controls must remain reachable while a segment is pending"
        )
        expect(
            compactContentViewSource.contains("scenePhase==.active")
                && compactContentViewSource.contains(
                    "presentedSheet!=.workoutDashboard"
                )
                && compactSource.contains("scenePhase==.active"),
            "segment feedback must be foreground-only and avoid dashboard duplicates"
        )
        expect(
            compactNavigationDetailsViewSource.contains(
                "WorkoutErrorCopyV1.detail(errorCode,context:WorkoutErrorCopyV1.context(for:presentation))"
            )
                && compactNavigationDetailsViewSource.contains(
                    "delayedWorkoutStatus(at:context.date),color:.orange,detail:workoutRecoveryDetail"
                )
                && compactNavigationDetailsViewSource.contains(
                    "disconnectedWorkoutStatus(at:context.date),color:.red,detail:workoutRecoveryDetail"
                ),
            "the active iPhone ride panel must show actionable Watch recovery copy"
        )
        expect(
            compactLiveWatchViewSource.contains("Button(\"SaveAnyway\")")
                && compactLiveWatchViewSource.contains(
                    "manager.saveWithoutUnconfirmedSegment()"
                ),
            "a permanently unconfirmed segment must leave a rider-visible save escape"
        )
        expect(
            compactSource.contains(
                "ifletage=store.presentation.captureAge(at:context.date){Text(captureAgeLabel(age))"
            ),
            "capture age must remain bound to the TimelineView's current date"
        )

        let compactContentView = contentViewSource.filter { !$0.isWhitespace }
        let compactAppSource = appSource.filter { !$0.isWhitespace }
        expect(
            compactAppSource.contains(
                "onApplicationActiveChange:{appDelegate.setApplicationActive($0)}"
            )
                && compactAppSource.contains(
                    "publishCurrentStateForIntent(sessionID:sessionID)"
                )
                && compactAppSource.contains(
                    "waitForResolution(of:action,sessionID:sessionID)"
                )
                && compactContentView.contains(
                    "onApplicationActiveChange(scenePhase==.active)"
                )
                && compactContentView.contains(
                    "onApplicationActiveChange(newValue==.active)"
                ),
            "SwiftUI scene phase must drive Live Activity foreground state"
        )
        expect(
            compactContentView.contains(
                "WorkoutCompactCard(store:workoutStore,watchAvailability:watchAvailability,onStart:{_=workoutMirrorManager.startOutdoorCyclingOnWatch()},onOpen:{presentedSheet=.workoutDashboard})"
            )
                && compactContentView.contains(
                    "case.workoutDashboard:WorkoutDashboardView(store:workoutStore,watchAvailability:watchAvailability,onStart:{_=workoutMirrorManager.startOutdoorCyclingOnWatch()},onPause:workoutMirrorManager.pause,onResume:workoutMirrorManager.resume,onMarkSegment:workoutMirrorManager.markSegment,onEndAndSave:workoutMirrorManager.endAndSave,onDiscard:workoutMirrorManager.discard,onDone:workoutMirrorManager.resetTerminalPresentation)"
                ),
            "ContentView must present the dashboard from its exact state and inject each production manager action"
        )

        let compactLiveWatchView = liveWatchViewSource.filter {
            !$0.isWhitespace
        }
        let compactSummaryWatchView = summaryWatchViewSource.filter {
            !$0.isWhitespace
        }
        expect(
            compactLiveWatchView.contains("manager.markSegment()")
                && compactLiveWatchView.contains(
                    "WatchSegmentNumberBadge(number:manager.snapshot.currentSegmentIndex)"
                )
                && compactLiveWatchView.contains(
                    ".accessibilityLabel(\"Markworkoutsegment\")"
                )
                && compactLiveWatchView.contains(
                    "manager.snapshot.lastCompletedSegment"
                ),
            "Watch live workout must expose segment marking and its latest completed segment"
        )
        expect(
            compactLiveWatchView.contains("case.running:nil")
                && !liveWatchViewSource.contains("\"LIVE\"")
                && compactLiveWatchView.contains(
                    "metric(title:\"HRZone\",value:heartRateZoneValue,unit:heartRateZoneUnit"
                )
                && compactLiveWatchView.contains(
                    "metric(title:\"Altitude\",value:altitudeValue,unit:\"M\""
                )
                && compactLiveWatchView.contains(
                    "workoutTime(\"Elapsed\",manager.snapshot.wallElapsedTime?.value??manager.snapshot.elapsedTime?.value)"
                )
                && compactLiveWatchView.contains(
                    "workoutTime(\"Moving\",manager.snapshot.elapsedTime?.value)"
                ),
            "Watch live workout must omit LIVE, expose heart-rate zone and altitude, and show elapsed plus moving time"
        )
        let expectedWatchMetricTitles = [
            "Speed",
            "Distance",
            "Heart",
            "HRZone",
            "AvgHeart",
            "AvgSpeed",
            "Energy",
            "Power",
            "Cadence",
            "Altitude",
        ]
        var actualWatchMetricTitles: [String]?
        if let gridStart = compactLiveWatchView.range(
            of: "LazyVGrid(columns:columns,spacing:8)"
        )?.upperBound,
           let gridEnd = compactLiveWatchView.range(
            of: "workoutTime(\"Elapsed\",manager.snapshot.wallElapsedTime?.value??manager.snapshot.elapsedTime?.value)"
           )?.lowerBound,
           gridStart < gridEnd {
            let grid = String(compactLiveWatchView[gridStart..<gridEnd])
            var titles = [String]()
            var searchStart = grid.startIndex
            let marker = "metric(title:\""
            while let markerRange = grid.range(
                of: marker,
                range: searchStart..<grid.endIndex
            ) {
                let titleStart = markerRange.upperBound
                guard let titleEnd = grid[titleStart...].firstIndex(
                    of: "\""
                ) else {
                    break
                }
                titles.append(String(grid[titleStart..<titleEnd]))
                searchStart = grid.index(after: titleEnd)
            }
            actualWatchMetricTitles = titles
        }
        expect(
            actualWatchMetricTitles == expectedWatchMetricTitles
                && compactLiveWatchView.contains(
                    "WorkoutValueFormatter.heartRate(manager.snapshot.averageHeartRate?.value)"
                )
                && compactLiveWatchView.contains(
                    "WorkoutValueFormatter.averageSpeed(distanceMeters:manager.snapshot.cyclingDistance?.value,elapsedSeconds:manager.snapshot.elapsedTime?.value)"
                ),
            "Watch live workout must keep exact consecutive Speed/Distance, Heart/Zone, and Avg Heart/Avg Speed rows"
        )
        expect(
            compactSummaryWatchView.contains(
                "summaryRow(\"AvgHeart\",\"\\(WorkoutValueFormatter.heartRate(summary.averageHeartRate))BPM\")"
            )
                && compactSummaryWatchView.contains(
                    "summaryRow(\"AvgSpeed\",\"\\(WorkoutValueFormatter.averageSpeed(distanceMeters:summary.distanceMeters,elapsedSeconds:summary.duration))KM/H\")"
                ),
            "Watch saved-workout summary must show average heart rate and average speed"
        )
        if let gridIndex = compactLiveWatchView.range(
            of: "LazyVGrid(columns:columns,spacing:8)"
        )?.lowerBound,
           let timerIndex = compactLiveWatchView.range(
            of: "workoutTime(\"Elapsed\",manager.snapshot.wallElapsedTime?.value??manager.snapshot.elapsedTime?.value)"
           )?.lowerBound,
           let controlsIndex = compactLiveWatchView.range(
            of: "HStack(spacing:8){Button{manager.markSegment()"
           )?.lowerBound {
            expect(
                gridIndex < timerIndex && timerIndex < controlsIndex,
                "Watch elapsed timer must appear below the stat grid and above workout controls"
            )
        } else {
            expect(
                false,
                "Watch live workout grid, timer, and controls must remain discoverable"
            )
        }
        expect(
            compactLiveWatchView.contains(
                "WorkoutCrossAppTakeoverCopyV1.live(disposition:manager.isDiscarding?.discard:.save)"
            )
                && compactSummaryWatchView.contains(
                    "WorkoutCrossAppTakeoverCopyV1.summary(disposition:summary.outcome==.saved?.save:.discard)"
                ),
            "Watch takeover copy must remain bound to the live and terminal Save/Discard dispositions"
        )
    }

    private mutating func testMainRideControlsComposition() {
        let iosAppDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BikeComputer")
        let contentURL = iosAppDirectory
            .appendingPathComponent("BikeComputer/ContentView.swift")
        let navigationURL = iosAppDirectory
            .appendingPathComponent("BikeComputer/Views/NavigationDetailsView.swift")
        let routeURL = iosAppDirectory
            .appendingPathComponent("BikeComputer/Views/RouteInputView.swift")
        let workoutURL = iosAppDirectory
            .appendingPathComponent("BikeComputer/Views/WorkoutViews.swift")
        let heartRateZoneStripURL = iosAppDirectory
            .appendingPathComponent("BikeComputer/Views/HeartRateZoneStrip.swift")
        let liveActivityURL = iosAppDirectory
            .appendingPathComponent(
                "BikeComputerLiveActivity/WorkoutLiveActivityViews.swift"
            )
        let watchWorkoutManagerURL = iosAppDirectory
            .appendingPathComponent(
                "BikeComputerWatch/Managers/WatchWorkoutManager.swift"
            )
        guard let content = try? String(contentsOf: contentURL, encoding: .utf8),
              let navigation = try? String(contentsOf: navigationURL, encoding: .utf8),
              let route = try? String(contentsOf: routeURL, encoding: .utf8),
              let workout = try? String(contentsOf: workoutURL, encoding: .utf8),
              let liveActivity = try? String(
                contentsOf: liveActivityURL,
                encoding: .utf8
              ),
              let watchWorkoutManager = try? String(
                contentsOf: watchWorkoutManagerURL,
                encoding: .utf8
              ),
              let heartRateZoneStrip = try? String(
                contentsOf: heartRateZoneStripURL,
                encoding: .utf8
              ) else {
            expect(false, "main ride-control source files must be available")
            return
        }

        let compactContent = content.filter { !$0.isWhitespace }
        let compactNavigation = navigation.filter { !$0.isWhitespace }
        let compactWorkout = workout.filter { !$0.isWhitespace }
        let compactLiveActivity = liveActivity.filter { !$0.isWhitespace }
        let compactWatchWorkoutManager =
            watchWorkoutManager.filter { !$0.isWhitespace }
        let compactHeartRateZoneStrip =
            heartRateZoneStrip.filter { !$0.isWhitespace }
        expect(
            route.contains("Search destination")
                && !route.contains("Search for a destination"),
            "all destination search surfaces must use the concise label"
        )
        expect(
            compactContent.contains(
                "HStack(alignment:.bottom,spacing:8){RouteSearchPanel("
            )
                && compactContent.contains(
                    "Label(\"StartWorkout\",systemImage:\"figure.outdoor.cycle\")"
                )
                && compactContent.contains(
                    "WorkoutStartButton(watchAvailability:watchAvailability,action:{_=workoutMirrorManager.startOutdoorCyclingOnWatch()})"
                )
                && compactContent.contains(
                    "Label(\"StartWorkout\",systemImage:\"figure.outdoor.cycle\").labelStyle(.titleAndIcon)"
                )
                && compactContent.contains(
                    ".buttonStyle(.plain).fixedSize(horizontal:true,vertical:false).layoutPriority(1).accessibilityLabel(\"StartworkoutonAppleWatch\")"
                ),
            "the collapsed destination row must keep the full blue Watch-gated Start Workout label visible"
        )
        expect(
            compactContent.contains(
                "ifcoordinator.isNavigating,!workoutStore.presentation.isWorkoutActive{rideControlPanel"
            )
                && compactContent.contains(
                    "if!coordinator.isNavigating{"
                )
                && compactContent.contains(
                    ".onChange(of:workoutStore.presentation.isWorkoutActive){_insynchronizeRideMetricsSheet()}"
                )
                && compactContent.contains(
                    "ifworkoutStore.presentation.isWorkoutActive{guardpresentedSheet==nilelse{return}rideMetricsDetent=.rideMetricsCompactpresentedSheet=.rideMetrics}"
                )
                && compactContent.contains(
                    ".sheet(item:$presentedSheet,onDismiss:handleSheetDismissal){destinationinpresentedSheetContent(for:destination)}"
                )
                && compactContent.contains(
                    "SensorSettingsRoutingPolicy.openDecision("
                )
                && compactContent.contains(
                    "case.dismissAndQueue:queuedSheetAfterDismiss=.sensorSettingspresentedSheet=nil"
                )
                && compactContent.contains(
                    "SensorSettingsRoutingPolicy.dismissalDecision("
                )
                && compactContent.contains(
                    "case.presentQueuedSheet:guardletqueuedSheetAfterDismisselse{return}self.queuedSheetAfterDismiss=nil"
                )
                && compactContent.contains(
                    ".presentationDetents([.rideMetricsCompact,.large],selection:$rideMetricsDetent)"
                )
                && compactContent.contains(
                    "context.dynamicTypeSize.isAccessibilitySize?360:280"
                )
                && compactContent.contains(
                    ".presentationDragIndicator(.visible)"
                )
                && compactContent.contains(
                    ".presentationBackgroundInteraction(.enabled(upThrough:.rideMetricsCompact))"
                )
                && compactContent.contains(
                    ".interactiveDismissDisabled()"
                )
                && compactNavigation.contains(
                    "compactSheetMetricContent:someView{ifworkoutStore.presentation.isWorkoutActive{workoutStatusBannerworkoutMetrics}ifisNavigating{navigationMetrics}}"
                )
                && !compactNavigation.contains("Text(\"RideStats\")")
                && !compactNavigation.contains("chevron.up")
                && !compactNavigation.contains("chevron.down")
                && !compactNavigation.contains("onToggleExpansion"),
            "active workouts must own the expandable native stats sheet while navigation-only keeps the compact overlay"
        )
        expect(
            compactNavigation.contains(
                "lettilePolicy=WorkoutMetricTilePolicy(enabledSensorCapabilities:enabledSensorCapabilities)"
            )
                && compactNavigation.contains(
                    "iftilePolicy.showsCadence{metrics.append("
                )
                && compactNavigation.contains(
                    "iftilePolicy.showsPower{metrics.append("
                )
                && compactNavigation.contains(
                    "ifletsensorPrompt{ActionStatusChip("
                )
                && compactContent.contains(
                    "case.sensorSettings:NavigationView{BikeComputersSettingsView("
                ),
            "sensor enrollment must gate cadence and power tiles and route detected sensors to My Bike Computer"
        )
        var expandedIPhoneLeadingMetricsAreExact = false
        if let methodStart = compactNavigation.range(
            of: "privatefuncexpandedWorkoutMetricValues(frommetrics:[RideMetric])->[RideMetric]{"
        )?.upperBound,
           let leadingEnd = compactNavigation.range(
            of: "expandedMetrics.append(contentsOf:",
            range: methodStart..<compactNavigation.endIndex
           )?.lowerBound {
            let leading = String(
                compactNavigation[methodStart..<leadingEnd]
            )
            let expectedBindings = [
                "expandedMetrics.append(heartRate)",
                "WorkoutValueFormatter.duration(displayedHeartRateZoneElapsedTime),showsHeartInLabel:true,label:\"timeinzone\"",
                "WorkoutValueFormatter.heartRate(snapshot.averageHeartRate?.value),unit:\"BPM\",label:\"averageheartrate\"",
                "WorkoutValueFormatter.averageSpeed(distanceMeters:snapshot.cyclingDistance?.value,elapsedSeconds:snapshot.elapsedTime?.value),unit:\"km/h\",label:\"averagespeed\"",
            ]
            var searchStart = leading.startIndex
            var bindingsAreOrdered = true
            for binding in expectedBindings {
                guard let range = leading.range(
                    of: binding,
                    range: searchStart..<leading.endIndex
                ) else {
                    bindingsAreOrdered = false
                    break
                }
                searchStart = range.upperBound
            }
            let appendCount = leading.components(
                separatedBy: "expandedMetrics.append("
            ).count - 1
            expandedIPhoneLeadingMetricsAreExact =
                bindingsAreOrdered && appendCount == expectedBindings.count
        }
        expect(
            expandedIPhoneLeadingMetricsAreExact,
            "expanded iPhone metrics must keep exact consecutive Heart/Time in Zone and Average Heart/Average Speed rows"
        )
        expect(
            compactNavigation.contains(
                "workoutMetricGrid(metrics:workoutMetricValues,columnCount:3,isExpanded:false)"
            )
                && compactNavigation.contains(
                    "metrics.first(where:{$0.id==\"speed\"})"
                )
                && compactNavigation.contains(
                    "isExpanded:true,isHero:true,showsLabel:false"
                )
                && compactNavigation.contains(
                    "metrics:expandedWorkoutMetricValues(from:metrics),columnCount:2,isExpanded:true"
                )
                && compactNavigation.contains(
                    "ifletheartRate=metrics.first(where:{$0.id==\"heartrate\"}){expandedMetrics.append(heartRate)}"
                )
                && compactNavigation.contains(
                    "WorkoutValueFormatter.duration(displayedHeartRateZoneElapsedTime),showsHeartInLabel:true,label:\"timeinzone\""
                )
                && compactNavigation.contains(
                    "WorkoutValueFormatter.heartRate(snapshot.averageHeartRate?.value),unit:\"BPM\",label:\"averageheartrate\""
                )
                && compactNavigation.contains(
                    "WorkoutValueFormatter.averageSpeed(distanceMeters:snapshot.cyclingDistance?.value,elapsedSeconds:snapshot.elapsedTime?.value),unit:\"km/h\",label:\"averagespeed\""
                )
                && compactNavigation.contains(
                    "ifshowsHeartInLabel{HStack(spacing:4){Text(\"timein\")Image(systemName:\"heart.fill\").accessibilityHidden(true)Text(\"zone\")}}"
                )
                && compactNavigation.contains(
                    "ifshowsLabel{metricLabel"
                )
                && compactNavigation.contains(
                    "label:\"workouttime\""
                )
                && !compactNavigation.contains(
                    "label:\"elapsed\""
                )
                && compactNavigation.contains(
                    "expandedNavigationMetrics"
                )
                && compactNavigation.contains(
                    "size:isHero?64:isExpanded?42:25"
                )
                && compactNavigation.contains(
                    "size:isHero?28:isExpanded?24:16"
                )
                && compactNavigation.contains(
                    "Text(unit).font(unitFont).foregroundColor(.secondary)"
                )
                && compactNavigation.contains(
                    ".frame(maxWidth:.infinity,minHeight:36)"
                )
                && compactNavigation.contains(
                    ".padding(.bottom,4)"
                ),
            "expanded ride stats must place current and average heart-rate/speed rows below the zone strip"
        )
        expect(
            compactContent.contains(
                "guard!isOnlyCheckingForServerMapselse{returnfalse}"
            )
                && compactContent.contains(
                    "offlineMapManager.isServerRecoveryCheckPending&&offlineMapManager.currentJob==nil&&offlineMapManager.downloadedPackURL==nil&&offlineMapManager.errorMessage==nil"
                ),
            "the passive offline-map recovery scan must not flash a startup status chip"
        )

        for binding in [
            "WorkoutValueFormatter.whole(suppressInstantaneous?nil:snapshot.cyclingCadence?.value)",
            "WorkoutValueFormatter.whole(suppressInstantaneous?nil:snapshot.cyclingPower?.value)",
            "WorkoutValueFormatter.speed(suppressInstantaneous?nil:snapshot.currentSpeed?.value)",
            "WorkoutValueFormatter.distance(snapshot.cyclingDistance?.value)",
            "altitudeValue(suppressInstantaneous?nil:snapshot.location?.altitude)",
            "WorkoutValueFormatter.heartRate(suppressInstantaneous?nil:snapshot.currentHeartRate?.value)",
            "WorkoutValueFormatter.energy(snapshot.activeEnergy?.value)",
        ] {
            expect(
                compactNavigation.contains(binding.filter { !$0.isWhitespace }),
                "main ride panel must bind the requested live metric: \(binding)"
            )
        }
        var previousMetricIndex = compactNavigation.startIndex
        for label in [
            "label:\"cadence\"",
            "label:\"power\"",
            "label:\"speed\"",
            "label:\"distance\"",
            "label:\"altitude\"",
            "label:\"heartrate\"",
            "label:\"energy\"",
        ] {
            guard let range = compactNavigation.range(
                of: label,
                range: previousMetricIndex..<compactNavigation.endIndex
            ) else {
                expect(
                    false,
                    "main ride panel must keep the requested metric order at \(label)"
                )
                break
            }
            previousMetricIndex = range.upperBound
        }
        expect(
            compactNavigation.contains(
                "HeartRateZoneStrip(currentZone:displayedHeartRateZone)"
            )
                && compactNavigation.contains(
                    "privatevardisplayedHeartRateZone:UInt8?{suppressInstantaneousMetrics?nil:workoutStore.presentation.snapshot.currentHeartRateZone}"
                )
                && compactHeartRateZoneStrip.contains(
                    "Text(\"ZONE\\(zone)\")"
                )
                && compactNavigation.contains(
                    "valueSymbol:\"heart.fill\",accessibilityUnit:\"beatsperminute\",label:\"heartrate\""
                )
                && compactWorkout.contains(
                    "valueSymbol:\"heart.fill\",accessibilityUnit:\"beatsperminute\""
                )
                && compactWorkout.contains(
                    "Image(systemName:\"heart.fill\").foregroundStyle(.red).accessibilityHidden(true)"
                )
                && !compactWorkout.contains(
                    "return\"\\(elapsed)••\\(heart)BPM"
                )
                && compactLiveActivity.contains(
                    "valueSymbol:\"heart.fill\",accessibilityUnit:\"beatsperminute\",label:\"Heartrate\""
                )
                && !compactLiveActivity.contains(
                    "unit:\"BPM\",label:\"Heartrate\""
                )
                && compactWorkout.contains(
                    "workoutTime(\"Elapsed\",snapshot.wallElapsedTime?.value??snapshot.elapsedTime?.value)"
                )
                && compactWorkout.contains(
                    ".accessibilityLabel(\"\\(label)\\(WorkoutValueFormatter.duration(seconds))\")"
                ),
            "every iPhone current-heart-rate surface must use a red heart, and workout time must retain a descriptive accessible label"
        )
        expect(
            compactWatchWorkoutManager.contains(
                "heartRateZoneDurationAccumulator.update(sessionID:identity?.sessionID,elapsedTime:elapsedTime?.value,currentZone:currentHeartRateZone)"
            )
                && compactWatchWorkoutManager.contains(
                    "heartRateZoneDurations:heartRateZoneDurations"
                )
                && compactWatchWorkoutManager.contains(
                    "heartRateZoneDurationAccumulator.restore(sessionID:recoveredIdentity.sessionID,checkpoint:recoveredIdentity.heartRateZoneCheckpoint)"
                )
                && compactWatchWorkoutManager.contains(
                    "recoveryStore.persistHeartRateZoneCheckpoint(checkpoint)"
                ),
            "the Watch workout owner must publish authoritative zone totals before iPhone transport coalescing"
        )
        for control in [
            "\"Segment\"",
            "\"Pauseworkout\"",
            "\"Resumeworkout\"",
            "\"Endworkout\"",
            "onStopNavigation",
            "onMarkSegment",
            "onPauseWorkout",
            "onResumeWorkout",
            "onEndAndSaveWorkout",
            "onDiscardWorkout",
        ] {
            expect(
                compactNavigation.contains(control),
                "main ride panel must retain control route: \(control)"
            )
        }
        expect(
            compactNavigation.contains(
                "Button(action:onMarkSegment){RideSegmentControlLabel(number:presentation.snapshot.currentSegmentIndex)}"
            )
                && compactNavigation.contains(
                    "presentation.pendingControl==nil"
                )
                && compactContent.contains(
                    "onMarkSegment:workoutMirrorManager.markSegment"
                ),
            "the ride sheet must expose the numbered segment action with safe production wiring"
        )
        expect(
            compactNavigation.contains(
                "case.launchingWatch,.awaitingFirstSnapshot,.stale,.disconnected:"
            )
                && compactNavigation.contains("Workoutdatadelayed")
                && compactNavigation.contains("AppleWatchdisconnected")
                && compactNavigation.contains("captureAge(at:date)"),
            "unconfirmed, stale, or disconnected workout metrics must suppress instantaneous values and show connection status"
        )
        expect(
            compactNavigation.contains(
                "ifisCompactHeight{ScrollView(.vertical,showsIndicators:true)"
            )
                && compactNavigation.contains(
                    ".frame(maxHeight:isCompactHeight?215:nil)"
                ),
            "compact-height layouts must keep metrics scrollable above pinned controls"
        )
        expect(
            compactNavigation.contains("@Environment(\\.dynamicTypeSize)")
                && compactNavigation.contains(
                    "ifdynamicTypeSize.isAccessibilitySize{VStack(spacing:8){navigationControlworkoutControls}"
                )
                && compactNavigation.contains(
                    "ifisCompactHeight&&dynamicTypeSize.isAccessibilitySize{ScrollView(.vertical,showsIndicators:true){VStack(spacing:8){metricContent"
                ),
            "accessibility controls must reflow and remain scrollable in compact-height layouts"
        )
        expect(
            compactWorkout.contains("case.activationFailed:")
                && compactWorkout.contains("Text(\"TryAgain\")")
                && compactWorkout.contains("watchAvailability.activate()"),
            "Watch activation failures must offer a retry path before starting"
        )
    }

    private func metric(
        _ value: Double,
        _ unit: WorkoutMetricUnitV1,
        _ date: Date,
        _ source: WorkoutMetricSourceV1? = nil
    ) -> WorkoutMetricV1 {
        WorkoutMetricV1(value: value, unit: unit, capturedAt: date, source: source)
    }

    private mutating func testWatchWorkoutLaunchRequest() {
        expect(
            WatchWorkoutLaunchRequest(
                url: WatchWorkoutLaunchRequest.startOutdoorCyclingURL
            ) == .startOutdoorCycling,
            "the complication URL must resolve to a start-workout request"
        )
        expect(
            WatchWorkoutLaunchRequest(
                url: URL(string: "bikecomputer://workout/summary")!
            ) == nil,
            "unknown BikeComputer paths must not start a workout"
        )
        expect(
            WatchWorkoutLaunchRequest(
                url: URL(string: "https://workout/start")!
            ) == nil,
            "foreign URL schemes must not start a workout"
        )
    }

    private func makeEnvelope(
        schemaVersion: WorkoutSchemaVersion = .current,
        sessionID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        sessionToken: UInt16 = 1,
        transportGenerationID: UUID? = nil,
        sequence: UInt64,
        capturedAt: Date = Date(timeIntervalSinceReferenceDate: 800_000_000),
        snapshot: WorkoutSnapshotV1? = nil
    ) -> WorkoutEnvelopeV1 {
        let resolvedSnapshot = snapshot ?? WorkoutSnapshotV1(
            state: .running,
            startDate: capturedAt.addingTimeInterval(-1)
        )
        return WorkoutEnvelopeV1(
            schemaVersion: schemaVersion,
            kind: .snapshot,
            sessionID: sessionID,
            sessionToken: sessionToken,
            transportGenerationID: transportGenerationID,
            sequence: sequence,
            capturedAt: capturedAt,
            snapshot: resolvedSnapshot
        )
    }
}

#if WORKOUT_CONTRACT_XCTEST
final class WorkoutContractPlatformTests: XCTestCase {
    func testWorkoutContractSuite() async {
        var suite = WorkoutContractTestSuite()
        await suite.run()
        XCTAssertEqual(suite.failureCount, 0)
    }
}
#else
@main
private enum WorkoutContractTestRunner {
    static func main() async {
#if WORKOUT_CONTRACT_HOST
        if let mode = ProcessInfo.processInfo.environment["BIKE_RECOVERY_CHILD_MODE"],
           let path = ProcessInfo.processInfo.environment["BIKE_RECOVERY_CHILD_PATH"] {
            let persistence = WorkoutRecoveryFilePersistence(
                fileURL: URL(fileURLWithPath: path)
            )
            switch mode {
            case "write-and-crash":
                let store = WatchWorkoutRecoveryStore(persistence: persistence)
                guard (try? store.begin(
                    startDate: Date(timeIntervalSinceReferenceDate: 800_045_000)
                )) != nil,
                store.nextSequence() == 1 else {
                    Darwin._exit(2)
                }
                Darwin._exit(0)
            case "read-after-crash":
                let store = WatchWorkoutRecoveryStore(persistence: persistence)
                guard let identity = store.recoveredIdentity,
                      let sequence = store.nextSequence() else {
                    exit(3)
                }
                print("\(identity.sessionID.uuidString)|\(sequence)")
                return
            default:
                exit(4)
            }
        }
#endif
        var suite = WorkoutContractTestSuite()
        await suite.run()
        guard suite.failureCount == 0 else {
            fputs("Workout contract tests failed: \(suite.failureCount)\n", stderr)
            exit(1)
        }
        print("Workout contract tests passed")
    }
}
#endif
