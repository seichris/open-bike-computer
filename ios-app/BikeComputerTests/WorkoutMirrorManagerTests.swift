import Combine
import HealthKit
import WatchConnectivity
import XCTest

private final class FakeWorkoutWatchConnectivitySession:
    WorkoutWatchConnectivitySession
{
    enum Failure: Error {
        case requested
    }

    weak var delegate: WCSessionDelegate?
    var activationState: WCSessionActivationState = .notActivated
    var isPaired = true
    var isWatchAppInstalled = true
    var isReachable = false
    var activationCount = 0
    var remainingUpdateFailures = 0
    var applicationContexts: [[String: Any]] = []

    func activate() {
        activationCount += 1
    }

    func updateApplicationContext(
        _ applicationContext: [String: Any]
    ) throws {
        if remainingUpdateFailures > 0 {
            remainingUpdateFailures -= 1
            throw Failure.requested
        }
        applicationContexts.append(applicationContext)
    }
}

@MainActor
private final class ManualWorkoutWatchSyncRetryScheduler {
    private(set) var delays: [TimeInterval] = []
    private var actions: [@MainActor () -> Void] = []

    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) {
        delays.append(delay)
        actions.append(action)
    }

    func runNext() {
        guard !actions.isEmpty else { return }
        actions.removeFirst()()
    }
}

@MainActor
final class WorkoutWatchAvailabilityMonitorProductionTests: XCTestCase {
    func testPersistedMaximumHeartRatePublishesAfterActivationAndInstall() async throws {
        let suiteName = "WorkoutWatchAvailabilityMonitorActivationTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = FakeWorkoutWatchConnectivitySession()
        session.isWatchAppInstalled = false
        let scheduler = ManualWorkoutWatchSyncRetryScheduler()
        let monitor = WorkoutWatchAvailabilityMonitor(
            heartRateZoneDefaults: defaults,
            session: session,
            syncRetryScheduler: scheduler.schedule
        )

        monitor.activate()
        XCTAssertEqual(session.activationCount, 1)
        XCTAssertTrue(session.delegate === monitor)

        monitor.setMaximumHeartRateBPM(205)
        XCTAssertEqual(
            WorkoutHeartRateZoneSettings.maximumHeartRateBPM(from: defaults),
            205
        )
        XCTAssertTrue(session.applicationContexts.isEmpty)

        session.activationState = .activated
        monitor.session(
            WCSession.default,
            activationDidCompleteWith: .activated,
            error: nil
        )
        await Task.yield()
        XCTAssertTrue(session.applicationContexts.isEmpty)

        session.isWatchAppInstalled = true
        monitor.sessionWatchStateDidChange(WCSession.default)
        await Task.yield()
        XCTAssertEqual(
            WorkoutHeartRateZoneSyncContext.maximumHeartRateBPM(
                from: try XCTUnwrap(session.applicationContexts.last)
            ),
            205
        )
    }

    func testTransientApplicationContextFailureRetriesLatestValue() throws {
        let suiteName = "WorkoutWatchAvailabilityMonitorRetryTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = FakeWorkoutWatchConnectivitySession()
        session.activationState = .activated
        session.remainingUpdateFailures = 1
        let scheduler = ManualWorkoutWatchSyncRetryScheduler()
        let monitor = WorkoutWatchAvailabilityMonitor(
            heartRateZoneDefaults: defaults,
            session: session,
            syncRetryScheduler: scheduler.schedule
        )

        monitor.setMaximumHeartRateBPM(215)

        XCTAssertTrue(session.applicationContexts.isEmpty)
        XCTAssertEqual(scheduler.delays, [1])
        scheduler.runNext()
        XCTAssertEqual(
            WorkoutHeartRateZoneSyncContext.maximumHeartRateBPM(
                from: try XCTUnwrap(session.applicationContexts.last)
            ),
            215
        )
    }
}

@available(iOS 17.0, *)
@MainActor
final class WorkoutMirrorManagerProductionTests: XCTestCase {
    func testNativeTakeoverFailureDrainsAuthoritativeTerminalSnapshot() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_399_900)
        let manager = WorkoutMirrorManager(
            now: { now },
            finalSnapshotTimeout: 0.05
        )
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)
        let running = makeSnapshotEnvelope(sequence: 1, capturedAt: now)
        manager.applyRemoteEnvelopes(
            [running],
            receivedAt: now,
            from: transport
        )
        let takeoverError = NSError(
            domain: HKErrorDomain,
            code: HKError.Code.errorAnotherWorkoutSessionStarted.rawValue
        )

        manager.applyNativeSessionFailure(
            takeoverError,
            at: now.addingTimeInterval(0.5),
            from: transport
        )

        XCTAssertTrue(transport.hasDelegate)
        XCTAssertEqual(manager.store.presentation.sessionState, .ending)
        XCTAssertEqual(
            manager.store.presentation.errorCode,
            .anotherWorkoutActive,
            "the production HealthKit error translation must retain takeover provenance"
        )

        manager.applyRemoteEnvelopes(
            terminalEnvelopes(
                after: running,
                outcome: .saved,
                capturedAt: now.addingTimeInterval(1)
            ),
            receivedAt: now.addingTimeInterval(2.5),
            from: transport
        )
        XCTAssertFalse(transport.hasDelegate)
        XCTAssertEqual(manager.store.presentation.connectionState, .ended)
        XCTAssertEqual(manager.store.presentation.sessionState, .ended)
        XCTAssertEqual(
            manager.store.presentation.finalSnapshot?.terminalOutcome,
            .saved
        )
        XCTAssertEqual(
            manager.store.presentation.errorCode,
            .anotherWorkoutActive
        )

        let preSnapshotLaunchProbe = WatchLaunchProbe()
        let preSnapshotManager = WorkoutMirrorManager(
            now: { now },
            finalSnapshotTimeout: 0.05,
            launchWatchApp: preSnapshotLaunchProbe.launch
        )
        let preSnapshotTransport = FakeMirroredSessionTransport()
        preSnapshotManager.acceptMirroredTransport(preSnapshotTransport)
        preSnapshotManager.applyNativeSessionFailure(
            takeoverError,
            at: now.addingTimeInterval(0.5),
            from: preSnapshotTransport
        )
        XCTAssertTrue(preSnapshotTransport.hasDelegate)
        XCTAssertEqual(
            preSnapshotManager.store.presentation.sessionState,
            .ending
        )
        preSnapshotManager.applyNativeSessionState(
            .ended,
            at: now.addingTimeInterval(0.75),
            from: preSnapshotTransport
        )
        preSnapshotManager.startOutdoorCyclingOnWatch()
        XCTAssertNil(
            preSnapshotLaunchProbe.configuration,
            "retry must remain blocked while an authoritative takeover drain is pending"
        )
        XCTAssertTrue(preSnapshotTransport.hasDelegate)
        preSnapshotManager.applyRemoteEnvelopes(
            terminalEnvelopes(
                after: running,
                outcome: .saved,
                capturedAt: now.addingTimeInterval(1)
            ),
            receivedAt: now.addingTimeInterval(2.5),
            from: preSnapshotTransport
        )
        XCTAssertEqual(
            preSnapshotManager.store.presentation.finalSnapshot?
                .terminalOutcome,
            .saved,
            "a takeover before the first custom snapshot must still admit the authoritative terminal stream"
        )
        XCTAssertFalse(preSnapshotTransport.hasDelegate)
        XCTAssertEqual(
            preSnapshotManager.store.presentation.errorCode,
            .anotherWorkoutActive
        )

        let timeoutManager = WorkoutMirrorManager(
            now: { now },
            finalSnapshotTimeout: 0.02
        )
        let timeoutTransport = FakeMirroredSessionTransport()
        timeoutManager.acceptMirroredTransport(timeoutTransport)
        timeoutManager.applyRemoteEnvelopes(
            [makeSnapshotEnvelope(
                sequence: 1,
                capturedAt: now,
                errorCode: .sessionFailed
            )],
            receivedAt: now,
            from: timeoutTransport
        )
        timeoutManager.applyNativeSessionFailure(
            takeoverError,
            at: now.addingTimeInterval(0.5),
            from: timeoutTransport
        )
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(timeoutTransport.hasDelegate)
        XCTAssertEqual(
            timeoutManager.store.presentation.connectionState,
            .failed
        )
        XCTAssertEqual(
            timeoutManager.store.presentation.errorCode,
            .anotherWorkoutActive
        )

        let remoteFailureManager = WorkoutMirrorManager(
            now: { now },
            finalSnapshotTimeout: 0.05
        )
        let remoteFailureTransport = FakeMirroredSessionTransport()
        remoteFailureManager.acceptMirroredTransport(remoteFailureTransport)
        remoteFailureManager.applyRemoteEnvelopes(
            [running],
            receivedAt: now,
            from: remoteFailureTransport
        )
        remoteFailureManager.applyNativeSessionFailure(
            takeoverError,
            at: now.addingTimeInterval(0.5),
            from: remoteFailureTransport
        )
        remoteFailureManager.applyRemoteEnvelopes(
            [
                WorkoutEnvelopeV1(
                    kind: .error,
                    sessionID: running.sessionID,
                    sessionToken: running.sessionToken,
                    transportGenerationID: running.transportGenerationID,
                    sequence: running.sequence + 1,
                    capturedAt: now.addingTimeInterval(1),
                    error: WorkoutErrorV1(code: .sessionFailed)
                ),
                WorkoutEnvelopeV1(
                    kind: .snapshot,
                    sessionID: running.sessionID,
                    sessionToken: running.sessionToken,
                    transportGenerationID: running.transportGenerationID,
                    sequence: running.sequence + 2,
                    capturedAt: now.addingTimeInterval(2),
                    snapshot: WorkoutSnapshotV1(
                        state: .failed,
                        startDate: running.snapshot?.startDate,
                        errorCode: .sessionFailed
                    )
                ),
            ],
            receivedAt: now.addingTimeInterval(2.5),
            from: remoteFailureTransport
        )
        XCTAssertFalse(remoteFailureTransport.hasDelegate)
        XCTAssertEqual(
            remoteFailureManager.store.presentation.errorCode,
            .anotherWorkoutActive,
            "generic remote error and terminal-failure data must not erase takeover provenance"
        )
    }

    func testTakeoverDrainSurvivesReplacementDisconnectAndLaterFailure() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_399_950)
        let takeoverError = NSError(
            domain: HKErrorDomain,
            code: HKError.Code.errorAnotherWorkoutSessionStarted.rawValue
        )
        let laterGenericError = NSError(
            domain: HKErrorDomain,
            code: HKError.Code.errorInvalidArgument.rawValue
        )

        for disconnectFirst in [false, true] {
            let manager = WorkoutMirrorManager(
                now: { now },
                finalSnapshotTimeout: 0.05
            )
            let original = FakeMirroredSessionTransport()
            let running = makeSnapshotEnvelope(sequence: 1, capturedAt: now)
            manager.acceptMirroredTransport(original)
            manager.applyRemoteEnvelopes(
                [running],
                receivedAt: now,
                from: original
            )
            manager.applyNativeSessionFailure(
                takeoverError,
                at: now.addingTimeInterval(0.5),
                from: original
            )
            if disconnectFirst {
                manager.applyRemoteDisconnect(error: nil, from: original)
            }

            let replacement = FakeMirroredSessionTransport()
            manager.acceptMirroredTransport(replacement)
            XCTAssertFalse(original.hasDelegate)
            XCTAssertTrue(replacement.hasDelegate)
            XCTAssertEqual(manager.store.presentation.sessionState, .ending)
            XCTAssertEqual(
                manager.store.presentation.errorCode,
                .anotherWorkoutActive
            )

            manager.applyNativeSessionFailure(
                laterGenericError,
                at: now.addingTimeInterval(0.75),
                from: replacement
            )
            XCTAssertTrue(
                replacement.hasDelegate,
                "a lower-priority callback must not tear down the takeover drain"
            )
            XCTAssertEqual(
                manager.store.presentation.errorCode,
                .anotherWorkoutActive
            )

            manager.applyRemoteEnvelopes(
                terminalEnvelopes(
                    after: running,
                    outcome: .saved,
                    capturedAt: now.addingTimeInterval(1)
                ),
                receivedAt: now.addingTimeInterval(2.5),
                from: replacement
            )
            XCTAssertFalse(replacement.hasDelegate)
            XCTAssertEqual(manager.store.presentation.connectionState, .ended)
            XCTAssertEqual(
                manager.store.presentation.errorCode,
                .anotherWorkoutActive
            )
        }

        let terminalWaiter = ControlledWorkoutTimeoutWaiter()
        let timeoutManager = WorkoutMirrorManager(
            now: { now },
            terminalFailureDrainWait: { timeout in
                try await terminalWaiter.wait(timeout)
            }
        )
        let timeoutOriginal = FakeMirroredSessionTransport()
        timeoutManager.acceptMirroredTransport(timeoutOriginal)
        timeoutManager.applyNativeSessionFailure(
            takeoverError,
            at: now,
            from: timeoutOriginal
        )
        try await waitUntil { terminalWaiter.waitCallCount == 1 }
        let timeoutReplacement = FakeMirroredSessionTransport()
        timeoutManager.acceptMirroredTransport(timeoutReplacement)
        XCTAssertTrue(timeoutReplacement.hasDelegate)
        XCTAssertEqual(
            terminalWaiter.waitCallCount,
            1,
            "replacement must retain the original timeout attempt"
        )
        terminalWaiter.completeWait(at: 0)
        try await waitUntil { terminalWaiter.hasReturned(at: 0) }
        try await waitUntil { !timeoutReplacement.hasDelegate }
        XCTAssertEqual(
            timeoutManager.store.presentation.connectionState,
            .failed
        )
        XCTAssertEqual(
            timeoutManager.store.presentation.errorCode,
            .anotherWorkoutActive,
            "transport replacement must not escape the original bounded drain"
        )

        let displacedStartDate = now.addingTimeInterval(-60)
        let verifiedNewStartDate = now.addingTimeInterval(1)
        for disconnectFirst in [false, true] {
            let delayedOldManager = WorkoutMirrorManager(
                now: { now },
                finalSnapshotTimeout: 0.05
            )
            let delayedOldOriginal = FakeMirroredSessionTransport(
                sessionStartDate: displacedStartDate
            )
            delayedOldManager.acceptMirroredTransport(delayedOldOriginal)
            delayedOldManager.applyNativeSessionFailure(
                takeoverError,
                at: now,
                from: delayedOldOriginal
            )
            if disconnectFirst {
                delayedOldManager.applyRemoteDisconnect(
                    error: nil,
                    from: delayedOldOriginal
                )
            }
            let delayedOldReplacement = FakeMirroredSessionTransport(
                sessionStartDate: displacedStartDate.addingTimeInterval(1.5)
            )
            delayedOldManager.acceptMirroredTransport(delayedOldReplacement)
            let delayedOldSnapshot = makeSnapshotEnvelope(
                sequence: 1,
                capturedAt: now.addingTimeInterval(0.5),
                startDate: displacedStartDate.addingTimeInterval(1.5)
            )
            delayedOldManager.applyRemoteEnvelopes(
                [delayedOldSnapshot],
                receivedAt: now.addingTimeInterval(0.75),
                from: delayedOldReplacement
            )
            XCTAssertEqual(
                delayedOldManager.store.presentation.errorCode,
                .anotherWorkoutActive,
                "delayed active data from the displaced ride must retain takeover provenance"
            )
            delayedOldManager.applyRemoteEnvelopes(
                terminalEnvelopes(
                    after: delayedOldSnapshot,
                    outcome: .saved,
                    capturedAt: now.addingTimeInterval(1)
                ),
                receivedAt: now.addingTimeInterval(2.5),
                from: delayedOldReplacement
            )
            XCTAssertFalse(delayedOldReplacement.hasDelegate)
            XCTAssertEqual(
                delayedOldManager.store.presentation.errorCode,
                .anotherWorkoutActive
            )

            let newActiveWaiter = ControlledWorkoutTimeoutWaiter()
            let newActiveManager = WorkoutMirrorManager(
                now: { now },
                terminalFailureDrainWait: { timeout in
                    try await newActiveWaiter.wait(timeout)
                }
            )
            let newActiveOriginal = FakeMirroredSessionTransport(
                sessionStartDate: displacedStartDate
            )
            newActiveManager.acceptMirroredTransport(newActiveOriginal)
            newActiveManager.applyNativeSessionFailure(
                takeoverError,
                at: now,
                from: newActiveOriginal
            )
            try await waitUntil { newActiveWaiter.waitCallCount == 1 }
            if disconnectFirst {
                newActiveManager.applyRemoteDisconnect(
                    error: nil,
                    from: newActiveOriginal
                )
            }
            let newActiveReplacement = FakeMirroredSessionTransport(
                sessionStartDate: verifiedNewStartDate
            )
            newActiveManager.acceptMirroredTransport(newActiveReplacement)
            let newActiveSessionID = UUID()
            newActiveManager.applyRemoteEnvelopes(
                [makeSnapshotEnvelope(
                    sequence: 1,
                    capturedAt: now.addingTimeInterval(1.5),
                    startDate: verifiedNewStartDate,
                    sessionID: newActiveSessionID,
                    transportGenerationID: UUID()
                )],
                receivedAt: now.addingTimeInterval(1.75),
                from: newActiveReplacement
            )
            newActiveWaiter.completeWait(at: 0)
            try await waitUntil { newActiveWaiter.hasReturned(at: 0) }
            XCTAssertTrue(newActiveReplacement.hasDelegate)
            XCTAssertEqual(
                newActiveManager.store.presentation.sessionID,
                newActiveSessionID
            )
            XCTAssertEqual(
                newActiveManager.store.presentation.sessionState,
                .running
            )
            XCTAssertNil(newActiveManager.store.presentation.errorCode)

            let newTerminalWaiter = ControlledWorkoutTimeoutWaiter()
            let newTerminalManager = WorkoutMirrorManager(
                now: { now },
                terminalFailureDrainWait: { timeout in
                    try await newTerminalWaiter.wait(timeout)
                }
            )
            let newTerminalOriginal = FakeMirroredSessionTransport(
                sessionStartDate: displacedStartDate
            )
            newTerminalManager.acceptMirroredTransport(newTerminalOriginal)
            newTerminalManager.applyNativeSessionFailure(
                takeoverError,
                at: now,
                from: newTerminalOriginal
            )
            try await waitUntil { newTerminalWaiter.waitCallCount == 1 }
            if disconnectFirst {
                newTerminalManager.applyRemoteDisconnect(
                    error: nil,
                    from: newTerminalOriginal
                )
            }
            let newTerminalReplacement = FakeMirroredSessionTransport(
                sessionStartDate: verifiedNewStartDate
            )
            newTerminalManager.acceptMirroredTransport(
                newTerminalReplacement
            )
            let newTerminalSnapshot = makeSnapshotEnvelope(
                sequence: 1,
                capturedAt: now.addingTimeInterval(1.5),
                state: .ending,
                startDate: verifiedNewStartDate,
                sessionID: UUID(),
                transportGenerationID: UUID()
            )
            newTerminalManager.applyRemoteEnvelopes(
                terminalEnvelopes(
                    after: newTerminalSnapshot,
                    outcome: .saved,
                    capturedAt: now.addingTimeInterval(2)
                ),
                receivedAt: now.addingTimeInterval(3.5),
                from: newTerminalReplacement
            )
            newTerminalWaiter.completeWait(at: 0)
            try await waitUntil { newTerminalWaiter.hasReturned(at: 0) }
            XCTAssertTrue(
                newTerminalReplacement.hasDelegate,
                "a fast-ending verified new workout must not inherit the old drain"
            )
            XCTAssertEqual(
                newTerminalManager.store.presentation.sessionID,
                newTerminalSnapshot.sessionID
            )
            XCTAssertEqual(
                newTerminalManager.store.presentation.sessionState,
                .ended
            )
            XCTAssertNil(newTerminalManager.store.presentation.errorCode)
        }

        let newSessionWaiter = ControlledWorkoutTimeoutWaiter()
        let newSessionManager = WorkoutMirrorManager(
            now: { now },
            terminalFailureDrainWait: { timeout in
                try await newSessionWaiter.wait(timeout)
            }
        )
        let newSessionOriginal = FakeMirroredSessionTransport()
        let firstSessionSnapshot = makeSnapshotEnvelope(
            sequence: 1,
            capturedAt: now
        )
        newSessionManager.acceptMirroredTransport(newSessionOriginal)
        newSessionManager.applyRemoteEnvelopes(
            [firstSessionSnapshot],
            receivedAt: now,
            from: newSessionOriginal
        )
        newSessionManager.applyNativeSessionFailure(
            takeoverError,
            at: now.addingTimeInterval(0.5),
            from: newSessionOriginal
        )
        try await waitUntil { newSessionWaiter.waitCallCount == 1 }
        let newSessionReplacement = FakeMirroredSessionTransport()
        newSessionManager.acceptMirroredTransport(newSessionReplacement)
        let secondSessionID = UUID()
        let secondSessionSnapshot = makeSnapshotEnvelope(
            sequence: 1,
            capturedAt: now.addingTimeInterval(1),
            sessionID: secondSessionID,
            transportGenerationID: UUID()
        )
        newSessionManager.applyRemoteEnvelopes(
            [secondSessionSnapshot],
            receivedAt: now.addingTimeInterval(1.5),
            from: newSessionReplacement
        )
        newSessionWaiter.completeWait(at: 0)
        try await waitUntil { newSessionWaiter.hasReturned(at: 0) }
        XCTAssertTrue(
            newSessionReplacement.hasDelegate,
            "a verified new session must retire the displaced session's deadline"
        )
        XCTAssertEqual(
            newSessionManager.store.presentation.sessionID,
            secondSessionID
        )
        XCTAssertEqual(newSessionManager.store.presentation.sessionState, .running)
        XCTAssertNil(newSessionManager.store.presentation.errorCode)
    }

    func testCanceledTimeoutContinuationsCannotAffectNewAttempts() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_399_975)
        let firstSnapshotWaiter = ControlledWorkoutTimeoutWaiter()
        let firstSnapshotManager = WorkoutMirrorManager(
            now: { now },
            firstSnapshotWait: { timeout in
                try await firstSnapshotWaiter.wait(timeout)
            }
        )
        let original = FakeMirroredSessionTransport()
        firstSnapshotManager.acceptMirroredTransport(original)
        try await waitUntil { firstSnapshotWaiter.waitCallCount == 1 }

        let replacement = FakeMirroredSessionTransport()
        firstSnapshotManager.acceptMirroredTransport(replacement)
        try await waitUntil { firstSnapshotWaiter.waitCallCount == 2 }
        firstSnapshotWaiter.completeWait(at: 0)
        try await waitUntil { firstSnapshotWaiter.hasReturned(at: 0) }
        XCTAssertTrue(
            replacement.hasDelegate,
            "a canceled first-snapshot continuation cannot detach its replacement"
        )

        let running = makeSnapshotEnvelope(sequence: 1, capturedAt: now)
        firstSnapshotManager.applyRemoteEnvelopes(
            [running],
            receivedAt: now,
            from: replacement
        )
        firstSnapshotWaiter.completeWait(at: 1)
        try await waitUntil { firstSnapshotWaiter.hasReturned(at: 1) }
        XCTAssertTrue(replacement.hasDelegate)
        XCTAssertEqual(
            firstSnapshotManager.store.presentation.sessionState,
            .running
        )

        let takeoverError = NSError(
            domain: HKErrorDomain,
            code: HKError.Code.errorAnotherWorkoutSessionStarted.rawValue
        )
        let drainWaiter = ControlledWorkoutTimeoutWaiter()
        let drainManager = WorkoutMirrorManager(
            now: { now },
            terminalFailureDrainWait: { timeout in
                try await drainWaiter.wait(timeout)
            }
        )
        let firstDrainTransport = FakeMirroredSessionTransport()
        let firstDrainSnapshot = makeSnapshotEnvelope(
            sequence: 1,
            capturedAt: now
        )
        drainManager.acceptMirroredTransport(firstDrainTransport)
        drainManager.applyRemoteEnvelopes(
            [firstDrainSnapshot],
            receivedAt: now,
            from: firstDrainTransport
        )
        drainManager.applyNativeSessionFailure(
            takeoverError,
            at: now.addingTimeInterval(0.5),
            from: firstDrainTransport
        )
        try await waitUntil { drainWaiter.waitCallCount == 1 }
        drainManager.applyRemoteEnvelopes(
            terminalEnvelopes(
                after: firstDrainSnapshot,
                outcome: .saved,
                capturedAt: now.addingTimeInterval(1)
            ),
            receivedAt: now.addingTimeInterval(2.5),
            from: firstDrainTransport
        )
        XCTAssertTrue(drainManager.resetTerminalPresentation())

        let laterDrainTransport = FakeMirroredSessionTransport()
        let laterDrainSnapshot = makeSnapshotEnvelope(
            sequence: 1,
            capturedAt: now.addingTimeInterval(10),
            sessionID: UUID(),
            transportGenerationID: UUID()
        )
        drainManager.acceptMirroredTransport(laterDrainTransport)
        drainManager.applyRemoteEnvelopes(
            [laterDrainSnapshot],
            receivedAt: now.addingTimeInterval(10),
            from: laterDrainTransport
        )
        drainManager.applyNativeSessionFailure(
            takeoverError,
            at: now.addingTimeInterval(10.5),
            from: laterDrainTransport
        )
        try await waitUntil { drainWaiter.waitCallCount == 2 }

        drainWaiter.completeWait(at: 0)
        try await waitUntil { drainWaiter.hasReturned(at: 0) }
        XCTAssertTrue(
            laterDrainTransport.hasDelegate,
            "a canceled terminal continuation cannot consume a later drain"
        )
        XCTAssertEqual(
            drainManager.store.presentation.errorCode,
            .anotherWorkoutActive
        )

        drainWaiter.completeWait(at: 1)
        try await waitUntil { drainWaiter.hasReturned(at: 1) }
        try await waitUntil { !laterDrainTransport.hasDelegate }
        XCTAssertEqual(
            drainManager.store.presentation.connectionState,
            .failed
        )
    }

    func testReplacementFailureBeforeFirstSnapshotOwnsItsCorrelation()
        async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_399_980)
        let priorStart = now.addingTimeInterval(-120)
        let replacementStart = now.addingTimeInterval(1)
        let manager = WorkoutMirrorManager(now: { now })
        let priorTransport = FakeMirroredSessionTransport(
            sessionStartDate: priorStart
        )
        manager.acceptMirroredTransport(priorTransport)
        manager.applyRemoteEnvelopes(
            [makeSnapshotEnvelope(
                sequence: 1,
                capturedAt: now,
                startDate: priorStart
            )],
            receivedAt: now,
            from: priorTransport
        )
        manager.applyRemoteDisconnect(error: nil, from: priorTransport)

        let replacement = FakeMirroredSessionTransport(
            sessionStartDate: replacementStart
        )
        manager.acceptMirroredTransport(replacement)
        manager.applyNativeSessionState(
            .running,
            at: replacementStart,
            from: replacement
        )
        let takeoverError = NSError(
            domain: HKErrorDomain,
            code: HKError.Code.errorAnotherWorkoutSessionStarted.rawValue
        )
        manager.applyNativeSessionFailure(
            takeoverError,
            at: replacementStart.addingTimeInterval(1),
            from: replacement
        )

        let replacementSnapshot = makeSnapshotEnvelope(
            sequence: 1,
            capturedAt: replacementStart.addingTimeInterval(2),
            startDate: replacementStart,
            sessionID: UUID(),
            transportGenerationID: UUID()
        )
        manager.applyRemoteEnvelopes(
            terminalEnvelopes(
                after: replacementSnapshot,
                outcome: .saved,
                capturedAt: replacementStart.addingTimeInterval(3)
            ),
            receivedAt: replacementStart.addingTimeInterval(5),
            from: replacement
        )

        XCTAssertFalse(replacement.hasDelegate)
        XCTAssertEqual(manager.store.presentation.sessionState, .ended)
        XCTAssertEqual(
            manager.store.presentation.errorCode,
            .anotherWorkoutActive,
            "the replacement's pre-snapshot takeover must not be correlated to the prior transport's retained envelope"
        )
    }

    func testUnknownOriginUsesDelayedTransportEvidenceAndAttachmentLifecycle()
        async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_399_985)
        let takeoverError = NSError(
            domain: HKErrorDomain,
            code: HKError.Code.errorAnotherWorkoutSessionStarted.rawValue
        )

        for disconnectFirst in [false, true] {
            let oldWaiter = ControlledWorkoutTimeoutWaiter()
            let oldManager = WorkoutMirrorManager(
                now: { now },
                terminalFailureDrainWait: { timeout in
                    try await oldWaiter.wait(timeout)
                }
            )
            let oldOrigin = FakeMirroredSessionTransport()
            oldManager.acceptMirroredTransport(oldOrigin)
            oldManager.applyNativeSessionFailure(
                takeoverError,
                at: now,
                from: oldOrigin
            )
            try await waitUntil { oldWaiter.waitCallCount == 1 }
            let delayedOriginStart = now.addingTimeInterval(-30)
            oldOrigin.sessionStartDate = delayedOriginStart
            if disconnectFirst {
                oldManager.applyRemoteDisconnect(error: nil, from: oldOrigin)
            }
            let oldReplacement = FakeMirroredSessionTransport(
                sessionStartDate: delayedOriginStart.addingTimeInterval(1.5)
            )
            oldManager.acceptMirroredTransport(oldReplacement)
            let delayedOldSnapshot = makeSnapshotEnvelope(
                sequence: 1,
                capturedAt: now.addingTimeInterval(1),
                startDate: delayedOriginStart.addingTimeInterval(1.5),
                sessionID: UUID(),
                transportGenerationID: UUID()
            )
            oldManager.applyRemoteEnvelopes(
                terminalEnvelopes(
                    after: delayedOldSnapshot,
                    outcome: .saved,
                    capturedAt: now.addingTimeInterval(2)
                ),
                receivedAt: now.addingTimeInterval(4),
                from: oldReplacement
            )
            XCTAssertFalse(oldReplacement.hasDelegate)
            XCTAssertEqual(
                oldManager.store.presentation.errorCode,
                .anotherWorkoutActive,
                "delayed native start evidence within tolerance must keep the displaced workout's cause"
            )

            for firstState in [
                WorkoutSessionStateV1.running,
                .ending,
            ] {
                let newWaiter = ControlledWorkoutTimeoutWaiter()
                let newManager = WorkoutMirrorManager(
                    now: { now },
                    terminalFailureDrainWait: { timeout in
                        try await newWaiter.wait(timeout)
                    }
                )
                let unknownOrigin = FakeMirroredSessionTransport()
                newManager.acceptMirroredTransport(unknownOrigin)
                newManager.applyNativeSessionFailure(
                    takeoverError,
                    at: now,
                    from: unknownOrigin
                )
                try await waitUntil { newWaiter.waitCallCount == 1 }
                if disconnectFirst {
                    newManager.applyRemoteDisconnect(
                        error: nil,
                        from: unknownOrigin
                    )
                }
                let newStart = now.addingTimeInterval(10)
                let newReplacement = FakeMirroredSessionTransport(
                    sessionStartDate: newStart
                )
                newManager.acceptMirroredTransport(newReplacement)
                let newSnapshot = makeSnapshotEnvelope(
                    sequence: 1,
                    capturedAt: newStart.addingTimeInterval(1),
                    state: firstState,
                    startDate: newStart,
                    sessionID: UUID(),
                    transportGenerationID: UUID()
                )
                let newEnvelopes = firstState == .running
                    ? [newSnapshot]
                    : terminalEnvelopes(
                        after: newSnapshot,
                        outcome: .saved,
                        capturedAt: newStart.addingTimeInterval(2)
                    )
                newManager.applyRemoteEnvelopes(
                    newEnvelopes,
                    receivedAt: newStart.addingTimeInterval(4),
                    from: newReplacement
                )
                newWaiter.completeWait(at: 0)
                try await waitUntil { newWaiter.hasReturned(at: 0) }
                XCTAssertTrue(
                    newReplacement.hasDelegate,
                    "a different attachment with its own start evidence must retire an origin that never started"
                )
                XCTAssertNil(newManager.store.presentation.errorCode)
                XCTAssertEqual(
                    newManager.store.presentation.sessionState,
                    firstState == .running ? .running : .ended
                )
            }
        }
    }

    func testUnknownOriginSameTransportRemainsTheTakeoverOrigin()
        async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_399_987)
        let waiter = ControlledWorkoutTimeoutWaiter()
        let manager = WorkoutMirrorManager(
            now: { now },
            terminalFailureDrainWait: { timeout in
                try await waiter.wait(timeout)
            }
        )
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)
        let takeoverError = NSError(
            domain: HKErrorDomain,
            code: HKError.Code.errorAnotherWorkoutSessionStarted.rawValue
        )
        manager.applyNativeSessionFailure(
            takeoverError,
            at: now,
            from: transport
        )
        try await waitUntil { waiter.waitCallCount == 1 }

        let originStart = now.addingTimeInterval(-30)
        let active = makeSnapshotEnvelope(
            sequence: 1,
            capturedAt: now.addingTimeInterval(1),
            startDate: originStart,
            sessionID: UUID(),
            transportGenerationID: UUID()
        )
        manager.applyRemoteEnvelopes(
            [active],
            receivedAt: now.addingTimeInterval(1.5),
            from: transport
        )
        XCTAssertTrue(transport.hasDelegate)
        XCTAssertEqual(
            manager.store.presentation.errorCode,
            .anotherWorkoutActive,
            "the origin's first active snapshot must not retire its own takeover drain"
        )

        manager.applyRemoteEnvelopes(
            terminalEnvelopes(
                after: active,
                outcome: .saved,
                capturedAt: now.addingTimeInterval(2)
            ),
            receivedAt: now.addingTimeInterval(4),
            from: transport
        )
        waiter.completeWait(at: 0)
        try await waitUntil { waiter.hasReturned(at: 0) }
        XCTAssertFalse(transport.hasDelegate)
        XCTAssertEqual(manager.store.presentation.sessionState, .ended)
        XCTAssertEqual(
            manager.store.presentation.errorCode,
            .anotherWorkoutActive
        )
    }

    func testStartCorrelationToleranceBoundaryIsSymmetricAndExclusive()
        async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_399_988)
        let originStart = now.addingTimeInterval(-30)
        let takeoverError = NSError(
            domain: HKErrorDomain,
            code: HKError.Code.errorAnotherWorkoutSessionStarted.rawValue
        )
        let cases: [(offset: TimeInterval, isNew: Bool)] = [
            (2, false),
            (-2, false),
            (2.001, true),
            (-2.001, true),
        ]

        for disconnectFirst in [false, true] {
            for firstState in [
                WorkoutSessionStateV1.running,
                .ending,
            ] {
                for testCase in cases {
                    let waiter = ControlledWorkoutTimeoutWaiter()
                    let manager = WorkoutMirrorManager(
                        now: { now },
                        terminalFailureDrainWait: { timeout in
                            try await waiter.wait(timeout)
                        }
                    )
                    let origin = FakeMirroredSessionTransport()
                    manager.acceptMirroredTransport(origin)
                    manager.applyNativeSessionFailure(
                        takeoverError,
                        at: now,
                        from: origin
                    )
                    try await waitUntil { waiter.waitCallCount == 1 }
                    origin.sessionStartDate = originStart
                    if disconnectFirst {
                        manager.applyRemoteDisconnect(
                            error: nil,
                            from: origin
                        )
                    }

                    let candidateStart = originStart.addingTimeInterval(
                        testCase.offset
                    )
                    let replacement = FakeMirroredSessionTransport(
                        sessionStartDate: candidateStart
                    )
                    manager.acceptMirroredTransport(replacement)
                    let firstSnapshot = makeSnapshotEnvelope(
                        sequence: 1,
                        capturedAt: now.addingTimeInterval(1),
                        state: firstState,
                        startDate: candidateStart,
                        sessionID: UUID(),
                        transportGenerationID: UUID()
                    )
                    if firstState == .running {
                        manager.applyRemoteEnvelopes(
                            [firstSnapshot],
                            receivedAt: now.addingTimeInterval(1.5),
                            from: replacement
                        )
                        if !testCase.isNew {
                            manager.applyRemoteEnvelopes(
                                terminalEnvelopes(
                                    after: firstSnapshot,
                                    outcome: .saved,
                                    capturedAt: now.addingTimeInterval(2)
                                ),
                                receivedAt: now.addingTimeInterval(4),
                                from: replacement
                            )
                        }
                    } else {
                        manager.applyRemoteEnvelopes(
                            terminalEnvelopes(
                                after: firstSnapshot,
                                outcome: .saved,
                                capturedAt: now.addingTimeInterval(2)
                            ),
                            receivedAt: now.addingTimeInterval(4),
                            from: replacement
                        )
                    }
                    waiter.completeWait(at: 0)
                    try await waitUntil { waiter.hasReturned(at: 0) }

                    if testCase.isNew {
                        XCTAssertTrue(replacement.hasDelegate)
                        XCTAssertNil(manager.store.presentation.errorCode)
                        XCTAssertEqual(
                            manager.store.presentation.sessionState,
                            firstState == .running ? .running : .ended
                        )
                    } else {
                        XCTAssertFalse(replacement.hasDelegate)
                        XCTAssertEqual(
                            manager.store.presentation.errorCode,
                            .anotherWorkoutActive
                        )
                        XCTAssertEqual(
                            manager.store.presentation.sessionState,
                            .ended
                        )
                    }
                }
            }
        }
    }

    func testFinalAndControlTimeoutAttemptsIgnoreStaleContinuations()
        async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_399_990)
        let finalWaiter = ControlledWorkoutTimeoutWaiter()
        let finalManager = WorkoutMirrorManager(
            now: { now },
            finalSnapshotWait: { timeout in
                try await finalWaiter.wait(timeout)
            }
        )
        let firstFinalTransport = FakeMirroredSessionTransport()
        let firstFinalSnapshot = makeSnapshotEnvelope(
            sequence: 1,
            capturedAt: now
        )
        finalManager.acceptMirroredTransport(firstFinalTransport)
        finalManager.applyRemoteEnvelopes(
            [firstFinalSnapshot],
            receivedAt: now,
            from: firstFinalTransport
        )
        finalManager.applyNativeSessionState(
            .ended,
            at: now.addingTimeInterval(1),
            from: firstFinalTransport
        )
        try await waitUntil { finalWaiter.waitCallCount == 1 }
        finalManager.applyRemoteEnvelopes(
            terminalEnvelopes(
                after: firstFinalSnapshot,
                outcome: .saved,
                capturedAt: now.addingTimeInterval(2)
            ),
            receivedAt: now.addingTimeInterval(4),
            from: firstFinalTransport
        )
        XCTAssertTrue(finalManager.resetTerminalPresentation())

        let secondFinalTransport = FakeMirroredSessionTransport()
        let secondFinalSnapshot = makeSnapshotEnvelope(
            sequence: 1,
            capturedAt: now.addingTimeInterval(10),
            sessionID: UUID(),
            transportGenerationID: UUID()
        )
        finalManager.acceptMirroredTransport(secondFinalTransport)
        finalManager.applyRemoteEnvelopes(
            [secondFinalSnapshot],
            receivedAt: now.addingTimeInterval(10),
            from: secondFinalTransport
        )
        finalManager.applyNativeSessionState(
            .ended,
            at: now.addingTimeInterval(11),
            from: secondFinalTransport
        )
        try await waitUntil { finalWaiter.waitCallCount == 2 }
        finalWaiter.completeWait(at: 0)
        try await waitUntil { finalWaiter.hasReturned(at: 0) }
        XCTAssertNil(finalManager.store.presentation.errorCode)
        XCTAssertFalse(finalManager.store.canResetTerminalPresentation)
        finalWaiter.completeWait(at: 1)
        try await waitUntil { finalWaiter.hasReturned(at: 1) }
        XCTAssertEqual(
            finalManager.store.presentation.errorCode,
            .finalSummaryUnavailable
        )

        let controlWaiter = ControlledWorkoutTimeoutWaiter()
        let controlManager = WorkoutMirrorManager(
            now: { now },
            controlConfirmationWait: { timeout in
                try await controlWaiter.wait(timeout)
            }
        )
        let firstControlTransport = FakeMirroredSessionTransport()
        let firstControlSnapshot = makeSnapshotEnvelope(
            sequence: 1,
            capturedAt: now
        )
        controlManager.acceptMirroredTransport(firstControlTransport)
        controlManager.applyRemoteEnvelopes(
            [firstControlSnapshot],
            receivedAt: now,
            from: firstControlTransport
        )
        controlManager.pause()
        try await waitUntil { controlWaiter.waitCallCount == 1 }
        controlManager.applyNativeSessionState(
            .paused,
            at: now.addingTimeInterval(1),
            from: firstControlTransport
        )
        controlManager.applyRemoteEnvelopes(
            terminalEnvelopes(
                after: firstControlSnapshot,
                outcome: .saved,
                capturedAt: now.addingTimeInterval(2)
            ),
            receivedAt: now.addingTimeInterval(4),
            from: firstControlTransport
        )
        XCTAssertTrue(controlManager.resetTerminalPresentation())

        let secondControlTransport = FakeMirroredSessionTransport()
        let secondControlSnapshot = makeSnapshotEnvelope(
            sequence: 1,
            capturedAt: now.addingTimeInterval(10),
            sessionID: UUID(),
            transportGenerationID: UUID()
        )
        controlManager.acceptMirroredTransport(secondControlTransport)
        controlManager.applyRemoteEnvelopes(
            [secondControlSnapshot],
            receivedAt: now.addingTimeInterval(10),
            from: secondControlTransport
        )
        controlManager.pause()
        try await waitUntil { controlWaiter.waitCallCount == 2 }
        controlWaiter.completeWait(at: 0)
        try await waitUntil { controlWaiter.hasReturned(at: 0) }
        XCTAssertEqual(
            controlManager.store.presentation.pendingControl,
            .pause,
            "a canceled nil-sequence Pause timeout must not fail a later workout's Pause attempt"
        )
        XCTAssertNil(controlManager.store.presentation.errorCode)
        controlWaiter.completeWait(at: 1)
        try await waitUntil { controlWaiter.hasReturned(at: 1) }
        XCTAssertNil(controlManager.store.presentation.pendingControl)
        XCTAssertEqual(
            controlManager.store.presentation.errorCode,
            .watchUnavailable
        )
    }

    func testPhoneStartUsesOutdoorCyclingAndPublishesLaunchFailure() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_000)
        let probe = WatchLaunchProbe()
        let manager = WorkoutMirrorManager(
            now: { now },
            launchWatchApp: probe.launch
        )

        manager.installMirroringHandler()
        manager.installMirroringHandler()
        manager.startOutdoorCyclingOnWatch()

        let configuration = try? XCTUnwrap(probe.configuration)
        XCTAssertEqual(configuration?.activityType, .cycling)
        XCTAssertEqual(configuration?.locationType, .outdoor)
        XCTAssertEqual(
            manager.store.presentation.connectionState,
            .launchingWatch
        )

        probe.complete(succeeded: false)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(manager.store.presentation.connectionState, .failed)
        XCTAssertEqual(manager.store.presentation.errorCode, .watchUnavailable)
        let copyContext = WorkoutErrorCopyV1.context(
            for: manager.store.presentation
        )
        XCTAssertEqual(copyContext, .workoutLaunch)
        let detail = WorkoutErrorCopyV1.detail(
            manager.store.presentation.errorCode,
            context: copyContext
        )
        XCTAssertTrue(detail.contains("workout did not start"))
        XCTAssertFalse(detail.contains("workout continues on Watch"))
    }

    func testStaleLaunchFailureCannotCancelRetryTimeout() async throws {
        let probe = WatchLaunchProbe()
        let manager = WorkoutMirrorManager(
            watchLaunchTimeout: 0.02,
            launchWatchApp: probe.launch
        )

        manager.startOutdoorCyclingOnWatch()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(manager.store.presentation.connectionState, .failed)
        XCTAssertEqual(manager.store.presentation.errorCode, .setupRequired)

        manager.startOutdoorCyclingOnWatch()
        XCTAssertEqual(manager.store.presentation.connectionState, .launchingWatch)
        probe.completeNext(succeeded: false)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(
            manager.store.presentation.connectionState,
            .launchingWatch,
            "launch A's late callback must not cancel or fail launch B"
        )

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(manager.store.presentation.connectionState, .failed)
        XCTAssertEqual(
            manager.store.presentation.errorCode,
            .setupRequired,
            "launch B must retain its own bounded timeout"
        )
    }

    func testRetryDetachesPriorFailedMirroredTransport() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_050)
        let probe = WatchLaunchProbe()
        let manager = WorkoutMirrorManager(
            now: { now },
            launchWatchApp: probe.launch
        )
        let oldTransport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(oldTransport)
        manager.applyRemoteEnvelopes(
            [
                WorkoutEnvelopeV1(
                    kind: .snapshot,
                    sessionID: UUID(),
                    sessionToken: 7,
                    transportGenerationID: UUID(),
                    sequence: 1,
                    capturedAt: now,
                    snapshot: WorkoutSnapshotV1(
                        state: .failed,
                        errorCode: .setupRequired
                    )
                ),
            ],
            receivedAt: now,
            from: oldTransport
        )
        XCTAssertEqual(manager.store.presentation.connectionState, .failed)

        manager.startOutdoorCyclingOnWatch()
        XCTAssertEqual(manager.store.presentation.connectionState, .launchingWatch)
        manager.applyNativeSessionState(
            .ended,
            at: now.addingTimeInterval(1),
            from: oldTransport
        )
        manager.applyRemoteDisconnect(error: nil, from: oldTransport)
        XCTAssertEqual(
            manager.store.presentation.connectionState,
            .launchingWatch,
            "callbacks from the detached failed transport must not mutate the retry"
        )
        probe.completeNext(succeeded: false)
        await Task.yield()
        await Task.yield()
    }

    func testStateChangingControlWithoutSessionCannotBecomeStuckPending() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_100)
        let store = WorkoutMetricsStore()
        let manager = WorkoutMirrorManager(store: store, now: { now })
        store.attachMirroredSession(at: now)
        store.confirmSessionState(.running, at: now)

        manager.endAndSave()

        XCTAssertNil(store.presentation.pendingControl)
        XCTAssertEqual(store.presentation.sessionState, .running)
    }

    func testFailureCopyContextUsesMirroredSessionProvenance() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_150)

        let preSnapshotFailure = WorkoutMetricsStore(now: { now })
        preSnapshotFailure.attachMirroredSession(at: now)
        preSnapshotFailure.failSession(error: .watchUnavailable)
        let fatalContext = WorkoutErrorCopyV1.context(
            for: preSnapshotFailure.presentation
        )
        XCTAssertEqual(fatalContext, .general)
        let fatalDetail = WorkoutErrorCopyV1.detail(
            preSnapshotFailure.presentation.errorCode,
            context: fatalContext
        )
        XCTAssertFalse(fatalDetail.contains("workout did not start"))
        XCTAssertFalse(fatalDetail.contains("workout continues on Watch"))

        let activeDisconnect = WorkoutMetricsStore(now: { now })
        activeDisconnect.attachMirroredSession(at: now)
        _ = activeDisconnect.ingestBatch(
            [makeSnapshotEnvelope(sequence: 1, capturedAt: now)],
            receivedAt: now.addingTimeInterval(0.25)
        )
        activeDisconnect.disconnect(error: .watchUnavailable)
        let activeContext = WorkoutErrorCopyV1.context(
            for: activeDisconnect.presentation
        )
        XCTAssertEqual(activeContext, .activeWorkout)
        XCTAssertTrue(
            WorkoutErrorCopyV1.detail(
                activeDisconnect.presentation.errorCode,
                context: activeContext
            ).contains("workout continues on Watch")
        )

        let verifiedFailure = WorkoutMetricsStore(now: { now })
        verifiedFailure.attachMirroredSession(at: now)
        _ = verifiedFailure.ingestBatch(
            [
                WorkoutEnvelopeV1(
                    kind: .snapshot,
                    sessionID: UUID(),
                    sessionToken: 12,
                    transportGenerationID: UUID(),
                    sequence: 1,
                    capturedAt: now,
                    snapshot: WorkoutSnapshotV1(
                        state: .failed,
                        errorCode: .setupRequired
                    )
                ),
            ],
            receivedAt: now.addingTimeInterval(0.25)
        )
        verifiedFailure.disconnect(error: nil)
        XCTAssertEqual(verifiedFailure.presentation.connectionState, .failed)
        XCTAssertEqual(verifiedFailure.presentation.errorCode, .setupRequired)

        let preSnapshotDisconnect = WorkoutMetricsStore(now: { now })
        preSnapshotDisconnect.attachMirroredSession(at: now)
        preSnapshotDisconnect.disconnect(error: nil)
        XCTAssertEqual(
            preSnapshotDisconnect.presentation.connectionState,
            .disconnected
        )
        XCTAssertEqual(
            preSnapshotDisconnect.presentation.errorCode,
            .watchUnavailable
        )
        let disconnectedContext = WorkoutErrorCopyV1.context(
            for: preSnapshotDisconnect.presentation
        )
        XCTAssertEqual(disconnectedContext, .general)
        let disconnectedDetail = WorkoutErrorCopyV1.detail(
            preSnapshotDisconnect.presentation.errorCode,
            context: disconnectedContext
        )
        XCTAssertFalse(disconnectedDetail.contains("workout continues on Watch"))
        XCTAssertFalse(disconnectedDetail.contains("workout did not start"))
    }

    func testStorePublishesOneCoherentStateForDelayedBatch() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_200)
        let store = WorkoutMetricsStore()
        store.attachMirroredSession(at: now)
        var publications: [WorkoutMirrorPresentationV1] = []
        let cancellable = store.$presentation
            .dropFirst()
            .sink { publications.append($0) }

        let sessionID = UUID()
        let start = now.addingTimeInterval(-10)
        let envelopes = [
            WorkoutEnvelopeV1(
                kind: .snapshot,
                sessionID: sessionID,
                sessionToken: 7,
                sequence: 1,
                capturedAt: now.addingTimeInterval(-1),
                snapshot: WorkoutSnapshotV1(
                    state: .running,
                    startDate: start
                )
            ),
            WorkoutEnvelopeV1(
                kind: .snapshot,
                sessionID: sessionID,
                sessionToken: 7,
                sequence: 2,
                capturedAt: now,
                snapshot: WorkoutSnapshotV1(
                    state: .paused,
                    startDate: start
                )
            ),
        ]

        _ = store.ingestBatch(envelopes, receivedAt: now)

        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(publications.first?.sessionState, .paused)
        XCTAssertEqual(publications.first?.capturedAt, now)
        withExtendedLifetime(cancellable) {}
    }

    func testNavigationDistanceFallbackIsScopedToCurrentWorkout() async {
        let start = Date(timeIntervalSinceReferenceDate: 800_400_250)
        let store = WorkoutMetricsStore()
        store.updateNavigationFallback(
            isNavigating: true,
            distanceTraveledMeters: 100,
            routeRemainingDistanceMeters: 1_000,
            routeRemainingTime: 120,
            instruction: "Continue",
            capturedAt: start
        )
        store.attachMirroredSession(at: start)
        _ = store.ingestBatch(
            [
                WorkoutEnvelopeV1(
                    kind: .snapshot,
                    sessionID: UUID(),
                    sessionToken: 9,
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

        XCTAssertEqual(store.presentation.snapshot.cyclingDistance?.value, 0)
        XCTAssertEqual(
            store.presentation.snapshot.cyclingDistance?.source,
            .iPhoneNavigation
        )

        store.updateNavigationFallback(
            isNavigating: true,
            distanceTraveledMeters: 125,
            routeRemainingDistanceMeters: 975,
            routeRemainingTime: 115,
            instruction: "Continue",
            capturedAt: start.addingTimeInterval(5)
        )
        XCTAssertEqual(store.presentation.snapshot.cyclingDistance?.value, 25)

        store.updateNavigationFallback(
            isNavigating: false,
            distanceTraveledMeters: nil,
            routeRemainingDistanceMeters: nil,
            routeRemainingTime: nil,
            instruction: nil,
            capturedAt: start.addingTimeInterval(6)
        )
        XCTAssertNil(store.presentation.snapshot.cyclingDistance)
    }

    func testNavigationDistanceFallbackFreezesAcrossPauseAndAccumulatesRestarts() async {
        let start = Date(timeIntervalSinceReferenceDate: 800_400_255)
        let sessionID = UUID()
        let generationID = UUID()
        let store = WorkoutMetricsStore(now: { start.addingTimeInterval(60) })
        store.attachMirroredSession(at: start)
        _ = store.ingestBatch(
            [
                WorkoutEnvelopeV1(
                    kind: .snapshot,
                    sessionID: sessionID,
                    sessionToken: 19,
                    transportGenerationID: generationID,
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

        func updateNavigation(_ distance: Double, at offset: TimeInterval) {
            store.updateNavigationFallback(
                isNavigating: true,
                distanceTraveledMeters: distance,
                routeRemainingDistanceMeters: 1_000 - distance,
                routeRemainingTime: 120,
                instruction: "Continue",
                capturedAt: start.addingTimeInterval(offset)
            )
        }

        updateNavigation(100, at: 1)
        updateNavigation(125, at: 5)
        XCTAssertEqual(store.presentation.snapshot.cyclingDistance?.value, 25)

        store.confirmSessionState(.paused, at: start.addingTimeInterval(6))
        updateNavigation(150, at: 10)
        XCTAssertEqual(
            store.presentation.snapshot.cyclingDistance?.value,
            25,
            "navigation movement while the Watch workout is paused must not advance fallback distance"
        )

        store.confirmSessionState(.running, at: start.addingTimeInterval(11))
        updateNavigation(160, at: 15)
        XCTAssertEqual(
            store.presentation.snapshot.cyclingDistance?.value,
            35,
            "resume must continue from the frozen fallback distance"
        )

        store.updateNavigationFallback(
            isNavigating: false,
            distanceTraveledMeters: nil,
            routeRemainingDistanceMeters: nil,
            routeRemainingTime: nil,
            instruction: nil,
            capturedAt: start.addingTimeInterval(16)
        )
        XCTAssertNil(store.presentation.snapshot.cyclingDistance)

        updateNavigation(0, at: 20)
        XCTAssertEqual(
            store.presentation.snapshot.cyclingDistance?.value,
            35,
            "restarting navigation must retain completed workout-relative distance"
        )
        updateNavigation(12, at: 25)
        XCTAssertEqual(store.presentation.snapshot.cyclingDistance?.value, 47)

        let watchDistance = WorkoutMetricV1(
            value: 80,
            unit: .meters,
            capturedAt: start.addingTimeInterval(30),
            source: .healthKit
        )
        _ = store.ingestBatch(
            [
                WorkoutEnvelopeV1(
                    kind: .snapshot,
                    sessionID: sessionID,
                    sessionToken: 19,
                    transportGenerationID: generationID,
                    sequence: 2,
                    capturedAt: start.addingTimeInterval(30),
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: start,
                        cyclingDistance: watchDistance,
                        availability: [.cyclingDistance]
                    )
                ),
            ],
            receivedAt: start.addingTimeInterval(30)
        )
        XCTAssertEqual(
            store.presentation.snapshot.cyclingDistance,
            watchDistance,
            "authoritative Watch distance must keep precedence over the accumulated phone fallback"
        )
    }

    func testNativeEndFreezesPhoneFallbackBeforeFinalWatchEnvelope() async throws {
        var clock = Date(timeIntervalSinceReferenceDate: 800_400_260)
        let store = WorkoutMetricsStore(now: { clock })
        store.attachMirroredSession(at: clock)
        let initialReceivedAt = clock.addingTimeInterval(0.25)
        _ = store.ingestBatch(
            [makeSnapshotEnvelope(sequence: 1, capturedAt: clock)],
            receivedAt: initialReceivedAt
        )
        store.updateNavigationFallback(
            isNavigating: true,
            distanceTraveledMeters: 100,
            routeRemainingDistanceMeters: 1_000,
            routeRemainingTime: 120,
            instruction: "Continue",
            capturedAt: clock
        )
        clock = clock.addingTimeInterval(5)
        store.updateNavigationFallback(
            isNavigating: true,
            distanceTraveledMeters: 125,
            routeRemainingDistanceMeters: 975,
            routeRemainingTime: 115,
            instruction: "Continue",
            capturedAt: clock
        )
        XCTAssertEqual(store.presentation.snapshot.cyclingDistance?.value, 25)
        let activeSnapshot = store.presentation.snapshot
        let activeCapturedAt = store.presentation.capturedAt
        let activeReceivedAt = store.presentation.receivedAt

        store.confirmSessionState(.ended, at: clock)
        XCTAssertEqual(
            store.presentation.snapshot,
            activeSnapshot,
            "native end must retain the last coherent phone fallback until Watch sends its final snapshot"
        )
        clock = clock.addingTimeInterval(5)
        store.updateNavigationFallback(
            isNavigating: true,
            distanceTraveledMeters: 175,
            routeRemainingDistanceMeters: 925,
            routeRemainingTime: 105,
            instruction: "Turn left",
            capturedAt: clock
        )
        store.updateIPhoneLocationFallback(
            WorkoutLocationV1(
                latitude: 1.30,
                longitude: 103.80,
                capturedAt: clock,
                horizontalAccuracy: 4,
                altitude: 20,
                verticalAccuracy: 3,
                course: nil,
                speed: 7
            )
        )

        XCTAssertEqual(store.presentation.connectionState, .ended)
        XCTAssertEqual(
            store.presentation.snapshot,
            activeSnapshot,
            "phone navigation/location updates must not mutate the finished summary"
        )
        XCTAssertEqual(store.presentation.capturedAt, activeCapturedAt)
        XCTAssertEqual(store.presentation.receivedAt, activeReceivedAt)

        let current = try XCTUnwrap(store.currentEnvelope)
        let finalCapturedAt = clock.addingTimeInterval(1)
        let finalReceivedAt = finalCapturedAt.addingTimeInterval(0.5)
        let finalSnapshot = WorkoutSnapshotV1(
            state: .ended,
            startDate: current.snapshot?.startDate,
            cyclingDistance: WorkoutMetricV1(
                value: 30,
                unit: .meters,
                capturedAt: finalCapturedAt,
                source: .healthKit
            ),
            availability: [.cyclingDistance],
            terminalOutcome: .saved
        )
        _ = store.ingestBatch(
            [
                WorkoutEnvelopeV1(
                    kind: .snapshot,
                    sessionID: current.sessionID,
                    sessionToken: current.sessionToken,
                    transportGenerationID: current.transportGenerationID,
                    sequence: current.sequence + 1,
                    capturedAt: finalCapturedAt,
                    snapshot: finalSnapshot
                ),
            ],
            receivedAt: finalReceivedAt
        )
        XCTAssertEqual(
            store.presentation.snapshot,
            finalSnapshot,
            "the complete final Watch snapshot must replace the frozen fallback"
        )
        XCTAssertEqual(store.presentation.capturedAt, finalCapturedAt)
        XCTAssertEqual(store.presentation.receivedAt, finalReceivedAt)
    }

    func testNativeEndWaitsForFinalSnapshotOrHonestBoundedTimeout() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_270)
        let manager = WorkoutMirrorManager(
            now: { now },
            finalSnapshotTimeout: 0.02
        )
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)
        manager.applyRemoteEnvelopes(
            [makeSnapshotEnvelope(sequence: 1, capturedAt: now)],
            receivedAt: now,
            from: transport
        )

        manager.applyNativeSessionState(
            .ended,
            at: now.addingTimeInterval(1),
            from: transport
        )
        XCTAssertFalse(
            manager.resetTerminalPresentation(),
            "native end alone must not detach the transport before the final Watch snapshot"
        )

        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(
            manager.store.presentation.errorCode,
            .finalSummaryUnavailable
        )
        XCTAssertTrue(manager.store.canResetTerminalPresentation)
        XCTAssertTrue(
            manager.resetTerminalPresentation(),
            "the bounded timeout must permit dismissal only after publishing honest copy"
        )
    }

    func testFreshWatchSnapshotDoesNotResurrectStalePhoneLocation() async {
        var clock = Date(timeIntervalSinceReferenceDate: 800_400_275)
        let store = WorkoutMetricsStore(now: { clock })
        let sessionID = UUID()
        store.attachMirroredSession(at: clock)
        _ = store.ingestBatch(
            [
                WorkoutEnvelopeV1(
                    kind: .snapshot,
                    sessionID: sessionID,
                    sessionToken: 10,
                    sequence: 1,
                    capturedAt: clock,
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: clock.addingTimeInterval(-30)
                    )
                ),
            ],
            receivedAt: clock
        )
        store.updateIPhoneLocationFallback(
            WorkoutLocationV1(
                latitude: 1.30,
                longitude: 103.80,
                capturedAt: clock,
                horizontalAccuracy: 4,
                altitude: 20,
                verticalAccuracy: 3,
                course: nil,
                speed: 6
            )
        )
        XCTAssertEqual(
            store.presentation.snapshot.currentSpeed?.source,
            .iPhoneLocation
        )
        XCTAssertNotNil(store.presentation.snapshot.location)

        clock = clock.addingTimeInterval(
            WorkoutIPhoneTelemetryMerge.phoneLocationMaximumAge + 1
        )
        _ = store.ingestBatch(
            [
                WorkoutEnvelopeV1(
                    kind: .snapshot,
                    sessionID: sessionID,
                    sessionToken: 10,
                    sequence: 2,
                    capturedAt: clock,
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: clock.addingTimeInterval(-41)
                    )
                ),
            ],
            receivedAt: clock
        )
        XCTAssertNil(store.presentation.snapshot.currentSpeed)
        XCTAssertNil(store.presentation.snapshot.location)
        XCTAssertFalse(
            store.presentation.snapshot.availability.contains(.currentSpeed)
        )
        XCTAssertFalse(
            store.presentation.snapshot.availability.contains(.location)
        )
    }

    func testProductionControlQueueUsesCurrentWatchIdentityAndAcknowledgement() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_300)
        let manager = WorkoutMirrorManager(now: { now })
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)

        let snapshot = makeSnapshotEnvelope(sequence: 40, capturedAt: now)
        manager.applyRemoteData(
            [Data([0x00, 0x01]), try WorkoutContractCodec.encode(snapshot)],
            receivedAt: now,
            from: transport
        )
        manager.endAndSave()

        XCTAssertEqual(transport.sentData.count, 1)
        let control = try WorkoutContractCodec.decode(transport.sentData[0])
        XCTAssertEqual(control.control, .endAndSave)
        XCTAssertEqual(control.sequence, 41)
        XCTAssertNotNil(control.controlSenderID)
        XCTAssertEqual(
            manager.store.presentation.pendingControl,
            .endAndSave
        )

        transport.completeNext(succeeded: true)
        await Task.yield()
        let acknowledgement = WorkoutEnvelopeV1(
            kind: .acknowledgement,
            sessionID: snapshot.sessionID,
            sessionToken: snapshot.sessionToken,
            transportGenerationID: snapshot.transportGenerationID,
            sequence: 41,
            capturedAt: now.addingTimeInterval(1),
            acknowledgement: WorkoutAcknowledgementV1(
                control: .endAndSave,
                resultingState: .ending,
                acknowledgedSequence: control.sequence
            )
        )
        manager.applyRemoteData(
            [try WorkoutContractCodec.encode(acknowledgement)],
            receivedAt: now.addingTimeInterval(1),
            from: transport
        )
        XCTAssertNil(manager.store.presentation.pendingControl)
    }

    func testProductionSegmentControlReportsWatchWriteFailureWithoutEndingRide()
        async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_350)
        let manager = WorkoutMirrorManager(now: { now })
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)
        let snapshot = makeSnapshotEnvelope(sequence: 45, capturedAt: now)
        manager.applyRemoteEnvelopes(
            [snapshot],
            receivedAt: now,
            from: transport
        )

        manager.markSegment()

        XCTAssertEqual(transport.sentData.count, 1)
        let control = try WorkoutContractCodec.decode(transport.sentData[0])
        XCTAssertEqual(control.control, .markSegment)
        XCTAssertEqual(
            manager.store.presentation.pendingControl,
            .markSegment
        )

        transport.completeNext(succeeded: true)
        await Task.yield()
        let acknowledgement = WorkoutEnvelopeV1(
            kind: .acknowledgement,
            sessionID: snapshot.sessionID,
            sessionToken: snapshot.sessionToken,
            transportGenerationID: snapshot.transportGenerationID,
            sequence: 46,
            capturedAt: now.addingTimeInterval(1),
            acknowledgement: WorkoutAcknowledgementV1(
                control: .markSegment,
                resultingState: .running,
                acknowledgedSequence: control.sequence,
                errorCode: .segmentMarkFailed
            )
        )
        manager.applyRemoteEnvelopes(
            [acknowledgement],
            receivedAt: now.addingTimeInterval(1),
            from: transport
        )

        XCTAssertNil(manager.store.presentation.pendingControl)
        XCTAssertEqual(
            manager.store.presentation.errorCode,
            .segmentMarkFailed
        )
        XCTAssertEqual(
            manager.store.presentation.sessionState,
            .running
        )
    }

    func testProductionSegmentControlRequiresWatchSchema14() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_375)
        let manager = WorkoutMirrorManager(now: { now })
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)
        let current = makeSnapshotEnvelope(sequence: 47, capturedAt: now)
        let oldWatchSnapshot = WorkoutEnvelopeV1(
            schemaVersion: WorkoutSchemaVersion(major: 1, minor: 3),
            kind: .snapshot,
            sessionID: current.sessionID,
            sessionToken: current.sessionToken,
            transportGenerationID: current.transportGenerationID,
            sequence: current.sequence,
            capturedAt: current.capturedAt,
            snapshot: current.snapshot
        )
        manager.applyRemoteEnvelopes(
            [oldWatchSnapshot],
            receivedAt: now,
            from: transport
        )

        XCTAssertFalse(manager.store.supportsSegmentMarking)
        manager.markSegment()
        XCTAssertTrue(transport.sentData.isEmpty)
        XCTAssertNil(manager.store.presentation.pendingControl)
    }

    func testProductionSegmentTimeoutAcceptsCorrelatedLateSuccess()
        async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_380)
        let manager = WorkoutMirrorManager(
            now: { now },
            controlConfirmationTimeout: 0.02
        )
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)
        let snapshot = makeSnapshotEnvelope(sequence: 48, capturedAt: now)
        manager.applyRemoteEnvelopes(
            [snapshot],
            receivedAt: now,
            from: transport
        )
        manager.markSegment()
        let control = try WorkoutContractCodec.decode(
            XCTUnwrap(transport.sentData.first)
        )

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(manager.store.presentation.pendingControl)
        XCTAssertEqual(
            manager.store.presentation.errorCode,
            .segmentMarkUnconfirmed
        )
        XCTAssertEqual(transport.sentData.count, 2)
        XCTAssertEqual(
            try WorkoutContractCodec.decode(transport.sentData[1]),
            control
        )

        // Completing both the invalidated original callback and the replay
        // callback without an acknowledgement must not create a send loop.
        transport.completeNext(succeeded: true)
        await Task.yield()
        transport.completeNext(succeeded: true)
        await Task.yield()
        XCTAssertEqual(transport.sentData.count, 2)

        manager.markSegment()
        XCTAssertEqual(transport.sentData.count, 2)

        let acknowledgement = WorkoutEnvelopeV1(
            kind: .acknowledgement,
            sessionID: snapshot.sessionID,
            sessionToken: snapshot.sessionToken,
            transportGenerationID: snapshot.transportGenerationID,
            sequence: 49,
            capturedAt: now.addingTimeInterval(1),
            acknowledgement: WorkoutAcknowledgementV1(
                control: .markSegment,
                resultingState: .running,
                acknowledgedSequence: control.sequence
            )
        )
        manager.applyRemoteEnvelopes(
            [acknowledgement],
            receivedAt: now.addingTimeInterval(1),
            from: transport
        )
        XCTAssertNil(manager.store.presentation.errorCode)
    }

    func testProductionSegmentReplayRecoversLostFailureAcknowledgement()
        async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_382)
        let manager = WorkoutMirrorManager(
            now: { now },
            controlConfirmationTimeout: 0.02
        )
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)
        let snapshot = makeSnapshotEnvelope(sequence: 48, capturedAt: now)
        manager.applyRemoteEnvelopes(
            [snapshot],
            receivedAt: now,
            from: transport
        )
        manager.markSegment()
        let control = try WorkoutContractCodec.decode(
            XCTUnwrap(transport.sentData.first)
        )

        try await waitUntil { transport.sentData.count == 2 }
        XCTAssertEqual(
            try WorkoutContractCodec.decode(transport.sentData[1]),
            control
        )
        let replayFailure = WorkoutEnvelopeV1(
            kind: .acknowledgement,
            sessionID: snapshot.sessionID,
            sessionToken: snapshot.sessionToken,
            transportGenerationID: snapshot.transportGenerationID,
            sequence: 49,
            capturedAt: now.addingTimeInterval(1),
            acknowledgement: WorkoutAcknowledgementV1(
                control: .markSegment,
                resultingState: .running,
                acknowledgedSequence: control.sequence,
                errorCode: .segmentMarkFailed
            )
        )
        manager.applyRemoteEnvelopes(
            [replayFailure],
            receivedAt: now.addingTimeInterval(1),
            from: transport
        )

        XCTAssertFalse(manager.store.isSegmentConfirmationPending)
        XCTAssertEqual(
            manager.store.presentation.errorCode,
            .segmentMarkFailed
        )
        manager.markSegment()
        XCTAssertEqual(transport.sentData.count, 3)
    }

    func testProductionFinishSupersedesUnconfirmedSegmentReplay()
        async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_383)
        let manager = WorkoutMirrorManager(
            now: { now },
            controlConfirmationTimeout: 0.02
        )
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)
        manager.applyRemoteEnvelopes(
            [makeSnapshotEnvelope(sequence: 48, capturedAt: now)],
            receivedAt: now,
            from: transport
        )
        manager.markSegment()
        try await waitUntil { transport.sentData.count == 2 }

        manager.endAndSave()

        XCTAssertEqual(transport.sentData.count, 3)
        XCTAssertEqual(
            try WorkoutContractCodec.decode(transport.sentData[2]).control,
            .endAndSave
        )
        XCTAssertEqual(
            manager.store.presentation.pendingControl,
            .endAndSave
        )

        // Stale callbacks for the abandoned original and replay must not send
        // another mark after the terminal choice.
        transport.completeNext(succeeded: true)
        transport.completeNext(succeeded: true)
        await Task.yield()
        XCTAssertEqual(transport.sentData.count, 3)

        manager.applyRemoteDisconnect(error: nil, from: transport)
        let replacement = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(replacement)
        XCTAssertEqual(replacement.sentData.count, 1)
        XCTAssertEqual(
            try WorkoutContractCodec.decode(replacement.sentData[0]).control,
            .endAndSave
        )
    }

    func testProductionSegmentPreemptsSnapshotAndStartsSubmittedTimeout()
        async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_385)
        let waiter = ControlledWorkoutTimeoutWaiter()
        let manager = WorkoutMirrorManager(
            now: { now },
            controlConfirmationWait: { timeout in
                try await waiter.wait(timeout)
            }
        )
        let original = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(original)
        let snapshot = makeSnapshotEnvelope(sequence: 49, capturedAt: now)
        manager.applyRemoteEnvelopes(
            [snapshot],
            receivedAt: now,
            from: original
        )

        let replacement = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(replacement)
        XCTAssertEqual(replacement.sentData.count, 1)
        XCTAssertEqual(
            try WorkoutContractCodec.decode(replacement.sentData[0]).control,
            .requestCurrentSnapshot
        )

        manager.markSegment()
        try await waitUntil {
            replacement.sentData.count == 2
                && waiter.waitCallCount == 1
        }
        XCTAssertEqual(
            try WorkoutContractCodec.decode(replacement.sentData[1]).control,
            .markSegment
        )
        XCTAssertEqual(
            manager.store.presentation.pendingControl,
            .markSegment
        )
    }

    func testProductionFinishCanSupersedePendingSegmentControl() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_390)
        let manager = WorkoutMirrorManager(now: { now })
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)
        let snapshot = makeSnapshotEnvelope(sequence: 50, capturedAt: now)
        manager.applyRemoteEnvelopes(
            [snapshot],
            receivedAt: now,
            from: transport
        )
        manager.markSegment()
        XCTAssertEqual(
            manager.store.presentation.pendingControl,
            .markSegment
        )

        manager.endAndSave()

        XCTAssertEqual(transport.sentData.count, 2)
        XCTAssertEqual(
            try WorkoutContractCodec.decode(transport.sentData[1]).control,
            .endAndSave
        )
        XCTAssertEqual(
            manager.store.presentation.pendingControl,
            .endAndSave
        )

        // Neither the invalidated mark callback nor the terminal callback may
        // resurrect the superseded segment after the terminal choice.
        transport.completeNext(succeeded: true)
        await Task.yield()
        transport.completeNext(succeeded: true)
        await Task.yield()
        XCTAssertEqual(transport.sentData.count, 2)
    }

    func testProductionPauseReplaysSegmentAfterOutstandingSendCallback()
        async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_395)
        let manager = WorkoutMirrorManager(now: { now })
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)
        let snapshot = makeSnapshotEnvelope(sequence: 50, capturedAt: now)
        manager.applyRemoteEnvelopes(
            [snapshot],
            receivedAt: now,
            from: transport
        )
        manager.markSegment()
        let originalControl = try WorkoutContractCodec.decode(
            XCTUnwrap(transport.sentData.first)
        )

        manager.pause()

        XCTAssertEqual(transport.pauseCallCount, 1)
        XCTAssertEqual(transport.sentData.count, 1)
        XCTAssertEqual(
            try WorkoutContractCodec.decode(transport.sentData[0]).control,
            .markSegment
        )
        XCTAssertEqual(manager.store.presentation.pendingControl, .pause)
        XCTAssertTrue(manager.store.isSegmentConfirmationPending)

        transport.completeNext(succeeded: true)
        try await waitUntil { transport.sentData.count == 2 }
        XCTAssertEqual(
            try WorkoutContractCodec.decode(transport.sentData[1]),
            originalControl
        )
    }

    func testProductionReconnectResendsControlBeforeSnapshotRequest() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_400)
        let manager = WorkoutMirrorManager(now: { now })
        let first = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(first)
        let snapshot = makeSnapshotEnvelope(sequence: 50, capturedAt: now)
        manager.applyRemoteEnvelopes(
            [snapshot],
            receivedAt: now,
            from: first
        )
        manager.discard()
        XCTAssertEqual(first.sentData.count, 1)

        manager.applyRemoteDisconnect(error: nil, from: first)
        XCTAssertEqual(
            manager.store.presentation.connectionState,
            .disconnected
        )
        let replacement = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(replacement)
        XCTAssertEqual(replacement.sentData.count, 1)
        XCTAssertEqual(
            try WorkoutContractCodec.decode(replacement.sentData[0]).control,
            .discard
        )

        first.completeNext(succeeded: true)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(
            replacement.sentData.count,
            1,
            "the superseded transport callback must not clear the replacement send"
        )

        replacement.completeNext(succeeded: true)
        await Task.yield()
        XCTAssertEqual(replacement.sentData.count, 2)
        XCTAssertEqual(
            try WorkoutContractCodec.decode(replacement.sentData[1]).control,
            .requestCurrentSnapshot
        )
    }

    func testProductionNativePauseResumeWaitsForConfirmation() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_500)
        let manager = WorkoutMirrorManager(now: { now })
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)
        manager.applyRemoteEnvelopes(
            [makeSnapshotEnvelope(sequence: 60, capturedAt: now)],
            receivedAt: now,
            from: transport
        )

        manager.pause()
        XCTAssertEqual(transport.pauseCallCount, 1)
        XCTAssertEqual(manager.store.presentation.pendingControl, .pause)
        XCTAssertEqual(manager.store.presentation.sessionState, .running)
        manager.applyNativeSessionState(
            .paused,
            at: now.addingTimeInterval(1),
            from: transport
        )
        XCTAssertNil(manager.store.presentation.pendingControl)
        XCTAssertEqual(manager.store.presentation.sessionState, .paused)

        manager.resume()
        XCTAssertEqual(transport.resumeCallCount, 1)
        manager.applyNativeSessionState(
            .running,
            at: now.addingTimeInterval(2),
            from: transport
        )
        XCTAssertNil(manager.store.presentation.pendingControl)
        XCTAssertEqual(manager.store.presentation.sessionState, .running)
    }

    func testPauseResumeTimeoutsRemainWatchUnavailable() async throws {
        for (index, scenario) in [
            (state: WorkoutSessionStateV1.running, control: WorkoutControlV1.pause),
            (state: WorkoutSessionStateV1.paused, control: WorkoutControlV1.resume),
        ].enumerated() {
            let now = Date(
                timeIntervalSinceReferenceDate: 800_400_550
                    + TimeInterval(index * 10)
            )
            let manager = WorkoutMirrorManager(
                now: { now },
                controlConfirmationTimeout: 0.02
            )
            let transport = FakeMirroredSessionTransport()
            manager.acceptMirroredTransport(transport)
            manager.applyRemoteEnvelopes(
                [
                    makeSnapshotEnvelope(
                        sequence: UInt64(65 + index * 10),
                        capturedAt: now,
                        state: scenario.state
                    ),
                ],
                receivedAt: now,
                from: transport
            )

            if scenario.control == .pause {
                manager.pause()
            } else {
                manager.resume()
            }
            XCTAssertEqual(
                manager.store.presentation.pendingControl,
                scenario.control
            )
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertNil(manager.store.presentation.pendingControl)
            XCTAssertEqual(
                manager.store.presentation.errorCode,
                .watchUnavailable,
                "non-terminal control timeouts must stay distinct from finish-choice uncertainty"
            )
        }
    }

    func testControlsWaitForFirstVerifiedSnapshotCredentials() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_600)
        let manager = WorkoutMirrorManager(now: { now })
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)
        manager.applyNativeSessionState(
            .running,
            at: now,
            from: transport
        )

        manager.endAndSave()
        manager.discard()

        XCTAssertTrue(transport.sentData.isEmpty)
        XCTAssertNil(manager.store.presentation.pendingControl)
        XCTAssertNil(manager.store.presentation.sessionID)
        XCTAssertEqual(
            manager.store.presentation.connectionState,
            .awaitingFirstSnapshot
        )
    }

    func testMirroredTransportWithoutAnyActiveEvidenceTimesOutAndCanRetry() async throws {
        let probe = WatchLaunchProbe()
        let manager = WorkoutMirrorManager(
            watchLaunchTimeout: 0.02,
            launchWatchApp: probe.launch
        )
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(manager.store.presentation.connectionState, .failed)
        XCTAssertEqual(manager.store.presentation.errorCode, .setupRequired)
        XCTAssertFalse(manager.store.presentation.isWorkoutActive)

        manager.startOutdoorCyclingOnWatch()
        XCTAssertEqual(
            manager.store.presentation.connectionState,
            .launchingWatch,
            "a missing first snapshot must produce a bounded, retryable failure"
        )
        XCTAssertNotNil(probe.configuration)
    }

    func testFirstSnapshotTimeoutPreservesNativeRunningAndAcceptsLateMetrics() async throws {
        let probe = WatchLaunchProbe()
        let manager = WorkoutMirrorManager(
            watchLaunchTimeout: 0.02,
            launchWatchApp: probe.launch
        )
        let transport = FakeMirroredSessionTransport()
        let nativeStateDate = Date()
        manager.acceptMirroredTransport(transport)
        manager.applyNativeSessionState(
            .running,
            at: nativeStateDate,
            from: transport
        )

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            manager.store.presentation.connectionState,
            .disconnected
        )
        XCTAssertEqual(manager.store.presentation.errorCode, .watchUnavailable)
        XCTAssertTrue(manager.store.presentation.isWorkoutActive)
        let context = WorkoutErrorCopyV1.context(
            for: manager.store.presentation
        )
        XCTAssertEqual(context, .activeWorkout)
        let detail = WorkoutErrorCopyV1.detail(
            manager.store.presentation.errorCode,
            context: context
        )
        XCTAssertTrue(detail.contains("workout continues on Watch"))
        XCTAssertFalse(detail.contains("workout did not start"))

        manager.startOutdoorCyclingOnWatch()
        XCTAssertNil(
            probe.configuration,
            "native active evidence must prevent a second launch attempt"
        )

        manager.applyRemoteDisconnect(error: nil, from: transport)
        let replacement = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(replacement)
        XCTAssertEqual(
            manager.store.presentation.connectionState,
            .awaitingFirstSnapshot
        )
        XCTAssertTrue(
            manager.store.presentation.isWorkoutActive,
            "replacement transport attachment must preserve native running provenance"
        )

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            manager.store.presentation.connectionState,
            .disconnected
        )
        XCTAssertTrue(manager.store.presentation.isWorkoutActive)
        manager.startOutdoorCyclingOnWatch()
        XCTAssertNil(probe.configuration)

        let lateSnapshot = makeSnapshotEnvelope(
            sequence: 1,
            capturedAt: nativeStateDate.addingTimeInterval(1)
        )
        manager.applyRemoteEnvelopes(
            [lateSnapshot],
            receivedAt: nativeStateDate.addingTimeInterval(1),
            from: replacement
        )
        XCTAssertEqual(manager.store.presentation.connectionState, .connected)
        XCTAssertNil(manager.store.presentation.errorCode)
    }

    func testHungTerminalAttemptCannotBlockOrClearSameControlRetry() async throws {
        for (index, control) in [
            WorkoutControlV1.endAndSave,
            .discard,
        ].enumerated() {
            let now = Date(
                timeIntervalSinceReferenceDate: 800_400_700
                    + TimeInterval(index * 100)
            )
            let manager = WorkoutMirrorManager(
                now: { now },
                controlConfirmationTimeout: 0.02
            )
            let transport = FakeMirroredSessionTransport()
            manager.acceptMirroredTransport(transport)
            let snapshot = makeSnapshotEnvelope(
                sequence: UInt64(40 + index * 20),
                capturedAt: now
            )
            manager.applyRemoteEnvelopes(
                [snapshot],
                receivedAt: now,
                from: transport
            )

            if control == .endAndSave {
                manager.endAndSave()
            } else {
                manager.discard()
            }
            let attemptA = try WorkoutContractCodec.decode(
                XCTUnwrap(transport.sentData.first)
            )
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertNil(manager.store.presentation.pendingControl)
            XCTAssertEqual(
                manager.store.presentation.errorCode,
                .terminalChoiceUnconfirmed
            )

            if control == .endAndSave {
                manager.endAndSave()
            } else {
                manager.discard()
            }
            XCTAssertEqual(manager.store.presentation.pendingControl, control)
            XCTAssertEqual(
                transport.sentData.count,
                2,
                "a hung \(control) send must release queue ownership for its retry"
            )
            let attemptBSequence = try XCTUnwrap(
                manager.store.currentPendingControlSequence
            )
            XCTAssertGreaterThan(attemptBSequence, attemptA.sequence)

            let lateAcknowledgement = WorkoutEnvelopeV1(
                kind: .acknowledgement,
                sessionID: snapshot.sessionID,
                sessionToken: snapshot.sessionToken,
                transportGenerationID: snapshot.transportGenerationID,
                sequence: snapshot.sequence + 1,
                capturedAt: now.addingTimeInterval(1),
                acknowledgement: WorkoutAcknowledgementV1(
                    control: control,
                    resultingState: .ending,
                    acknowledgedSequence: attemptA.sequence
                )
            )
            manager.applyRemoteEnvelopes(
                [lateAcknowledgement],
                receivedAt: now.addingTimeInterval(1),
                from: transport
            )
            XCTAssertEqual(manager.store.presentation.pendingControl, control)
            XCTAssertEqual(
                manager.store.currentPendingControlSequence,
                attemptBSequence
            )

            transport.completeNext(succeeded: false)
            await Task.yield()
            await Task.yield()
            XCTAssertEqual(transport.sentData.count, 2)
            XCTAssertEqual(manager.store.presentation.pendingControl, control)
            XCTAssertEqual(
                manager.store.currentPendingControlSequence,
                attemptBSequence,
                "attempt A's late failure must not clear attempt B"
            )
        }
    }

    func testDelayedEndingCannotConfirmOppositeTerminalRetry() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_800)
        let manager = WorkoutMirrorManager(
            now: { now },
            controlConfirmationTimeout: 0.02
        )
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)
        let initialSnapshot = makeSnapshotEnvelope(
            sequence: 70,
            capturedAt: now
        )
        let initialReceivedAt = now.addingTimeInterval(0.25)
        manager.applyRemoteEnvelopes(
            [initialSnapshot],
            receivedAt: initialReceivedAt,
            from: transport
        )

        manager.endAndSave()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(manager.store.presentation.pendingControl)

        manager.discard()
        XCTAssertEqual(manager.store.presentation.pendingControl, .discard)
        let discardSequence = try XCTUnwrap(
            manager.store.currentPendingControlSequence
        )

        manager.applyNativeSessionState(
            .ending,
            at: now.addingTimeInterval(1),
            from: transport
        )
        XCTAssertEqual(
            manager.store.presentation.pendingControl,
            .discard,
            "the delayed native transition from Save must not confirm Discard"
        )
        XCTAssertEqual(
            manager.store.currentPendingControlSequence,
            discardSequence
        )
        manager.applyNativeSessionState(
            .ended,
            at: now.addingTimeInterval(2),
            from: transport
        )
        XCTAssertEqual(
            manager.store.presentation.pendingControl,
            .discard,
            "outcome-free native end must not confirm Discard"
        )
        XCTAssertEqual(
            manager.store.currentPendingControlSequence,
            discardSequence
        )
        manager.refreshFreshness()
        XCTAssertEqual(manager.store.presentation.connectionState, .ended)
        let frozenSnapshot = manager.store.presentation.snapshot
        let frozenCapturedAt = manager.store.presentation.capturedAt
        let frozenReceivedAt = manager.store.presentation.receivedAt
        let delayedCapturedAt = now.addingTimeInterval(3)
        let delayedReceivedAt = delayedCapturedAt.addingTimeInterval(0.5)
        manager.applyRemoteEnvelopes(
            [
                WorkoutEnvelopeV1(
                    kind: .snapshot,
                    sessionID: initialSnapshot.sessionID,
                    sessionToken: initialSnapshot.sessionToken,
                    transportGenerationID:
                        initialSnapshot.transportGenerationID,
                    sequence: 71,
                    capturedAt: delayedCapturedAt,
                    snapshot: WorkoutSnapshotV1(
                        state: .running,
                        startDate: initialSnapshot.snapshot?.startDate,
                        cyclingDistance: WorkoutMetricV1(
                            value: 999,
                            unit: .meters,
                            capturedAt: delayedCapturedAt,
                            source: .healthKit
                        ),
                        availability: [.cyclingDistance]
                    )
                )
            ],
            receivedAt: delayedReceivedAt,
            from: transport
        )
        XCTAssertEqual(
            manager.store.presentation.connectionState,
            .ended,
            "freshness and delayed active snapshots must not regress native end"
        )
        XCTAssertEqual(
            manager.store.presentation.snapshot,
            frozenSnapshot,
            "an observably different delayed active snapshot must not replace frozen metrics"
        )
        XCTAssertEqual(
            manager.store.presentation.capturedAt,
            frozenCapturedAt,
            "ignored active metrics and their capture timestamp must freeze together"
        )
        XCTAssertEqual(
            manager.store.presentation.receivedAt,
            frozenReceivedAt,
            "ignored active metrics must not appear newly received"
        )
        XCTAssertEqual(manager.store.presentation.pendingControl, .discard)
        XCTAssertFalse(
            manager.resetTerminalPresentation(),
            "Done must not dismiss an unresolved terminal choice"
        )

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(manager.store.presentation.pendingControl)
        XCTAssertEqual(
            manager.store.presentation.errorCode,
            .terminalChoiceUnconfirmed,
            "an unacknowledged opposite retry must fail honestly"
        )
        XCTAssertEqual(manager.store.presentation.connectionState, .ended)
        XCTAssertTrue(manager.resetTerminalPresentation())
        XCTAssertEqual(manager.store.presentation.connectionState, .idle)
    }

    func testExplicitOppositeTerminalOutcomeRejectsPendingImmediately() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_400_900)
        let manager = WorkoutMirrorManager(
            now: { now },
            controlConfirmationTimeout: 0.02
        )
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)
        let running = makeSnapshotEnvelope(sequence: 80, capturedAt: now)
        manager.applyRemoteEnvelopes(
            [running],
            receivedAt: now,
            from: transport
        )
        manager.discard()
        XCTAssertEqual(manager.store.presentation.pendingControl, .discard)

        let ending = WorkoutEnvelopeV1(
            kind: .snapshot,
            sessionID: running.sessionID,
            sessionToken: running.sessionToken,
            transportGenerationID: running.transportGenerationID,
            sequence: 81,
            capturedAt: now.addingTimeInterval(1),
            snapshot: WorkoutSnapshotV1(
                state: .ending,
                startDate: running.snapshot?.startDate
            )
        )
        let saved = WorkoutEnvelopeV1(
            kind: .snapshot,
            sessionID: running.sessionID,
            sessionToken: running.sessionToken,
            transportGenerationID: running.transportGenerationID,
            sequence: 82,
            capturedAt: now.addingTimeInterval(2),
            snapshot: WorkoutSnapshotV1(
                state: .ended,
                startDate: running.snapshot?.startDate,
                terminalOutcome: .saved
            )
        )
        manager.applyRemoteEnvelopes(
            [ending, saved],
            receivedAt: now.addingTimeInterval(2),
            from: transport
        )

        XCTAssertNil(manager.store.presentation.pendingControl)
        XCTAssertEqual(
            manager.store.presentation.errorCode,
            .terminalChoiceConflict
        )
        XCTAssertEqual(manager.store.presentation.connectionState, .ended)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            manager.store.presentation.errorCode,
            .terminalChoiceConflict,
            "the canceled transport timeout must not replace the semantic conflict"
        )
    }

    func testTerminalTimeoutBeforeNativeEndIsReclassifiedHonestly() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_401_000)
        let manager = WorkoutMirrorManager(
            now: { now },
            controlConfirmationTimeout: 0.02
        )
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)
        manager.applyRemoteEnvelopes(
            [makeSnapshotEnvelope(sequence: 90, capturedAt: now)],
            receivedAt: now,
            from: transport
        )

        manager.endAndSave()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(manager.store.presentation.pendingControl)
        XCTAssertEqual(
            manager.store.presentation.errorCode,
            .terminalChoiceUnconfirmed
        )

        manager.pause()
        XCTAssertEqual(manager.store.presentation.pendingControl, .pause)
        manager.applyNativeSessionState(
            .paused,
            at: now.addingTimeInterval(0.5),
            from: transport
        )
        XCTAssertNil(manager.store.presentation.pendingControl)
        XCTAssertEqual(
            manager.store.presentation.errorCode,
            .terminalChoiceUnconfirmed,
            "Pause confirmation must preserve the unresolved finish warning"
        )

        manager.applyNativeSessionState(
            .ended,
            at: now.addingTimeInterval(1),
            from: transport
        )
        XCTAssertEqual(manager.store.presentation.connectionState, .ended)
        XCTAssertEqual(
            manager.store.presentation.errorCode,
            .terminalChoiceUnconfirmed,
            "native end must reclassify an earlier terminal timeout"
        )
    }

    func testTerminalTimeoutSurvivesPauseResumeConfirmationAndFailureMatrix() async throws {
        let cases: [(
            terminal: WorkoutControlV1,
            initialState: WorkoutSessionStateV1,
            transient: WorkoutControlV1,
            confirmTransient: Bool
        )] = [
            (.discard, .paused, .resume, true),
            (.endAndSave, .running, .pause, false),
            (.discard, .paused, .resume, false),
        ]

        for (index, scenario) in cases.enumerated() {
            let now = Date(
                timeIntervalSinceReferenceDate: 800_401_020
                    + TimeInterval(index * 10)
            )
            let manager = WorkoutMirrorManager(
                now: { now },
                controlConfirmationTimeout: 0.02
            )
            let transport = FakeMirroredSessionTransport()
            manager.acceptMirroredTransport(transport)
            manager.applyRemoteEnvelopes(
                [
                    makeSnapshotEnvelope(
                        sequence: UInt64(92 + index * 10),
                        capturedAt: now,
                        state: scenario.initialState
                    ),
                ],
                receivedAt: now,
                from: transport
            )

            if scenario.terminal == .endAndSave {
                manager.endAndSave()
            } else {
                manager.discard()
            }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(
                manager.store.presentation.errorCode,
                .terminalChoiceUnconfirmed
            )

            if scenario.transient == .pause {
                manager.pause()
            } else {
                manager.resume()
            }
            XCTAssertEqual(
                manager.store.presentation.pendingControl,
                scenario.transient
            )
            if scenario.confirmTransient {
                manager.applyNativeSessionState(
                    scenario.transient == .pause ? .paused : .running,
                    at: now.addingTimeInterval(0.5),
                    from: transport
                )
            } else {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertNil(manager.store.presentation.pendingControl)
            XCTAssertEqual(
                manager.store.presentation.errorCode,
                .terminalChoiceUnconfirmed,
                "Pause/Resume resolution must retain the unresolved terminal warning"
            )

            manager.applyNativeSessionState(
                .ended,
                at: now.addingTimeInterval(1),
                from: transport
            )
            XCTAssertEqual(
                manager.store.presentation.errorCode,
                .terminalChoiceUnconfirmed,
                "native end must retain terminal correlation for every transient-control path"
            )
        }
    }

    func testTimedOutTerminalControlsReconcileLateEvidence() async throws {
        for (index, control) in [
            WorkoutControlV1.endAndSave,
            .discard,
        ].enumerated() {
            let baseSequence = UInt64(100 + index * 20)

            do {
                let runtime = try await makeTimedOutTerminalRuntime(
                    control: control,
                    sequence: baseSequence,
                    clockOffset: TimeInterval(index * 100)
                )
                let acknowledgement = WorkoutEnvelopeV1(
                    kind: .acknowledgement,
                    sessionID: runtime.snapshot.sessionID,
                    sessionToken: runtime.snapshot.sessionToken,
                    transportGenerationID:
                        runtime.snapshot.transportGenerationID,
                    sequence: baseSequence + 1,
                    capturedAt: runtime.now.addingTimeInterval(1),
                    acknowledgement: WorkoutAcknowledgementV1(
                        control: control,
                        resultingState: .ending,
                        acknowledgedSequence: runtime.control.sequence
                    )
                )
                runtime.manager.applyRemoteEnvelopes(
                    [acknowledgement],
                    receivedAt: runtime.now.addingTimeInterval(1),
                    from: runtime.transport
                )
                XCTAssertNil(runtime.manager.store.presentation.errorCode)
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertNil(
                    runtime.manager.store.presentation.errorCode,
                    "late timeout work must not overwrite a matching acknowledgement"
                )
            }

            let matchingOutcome: WorkoutTerminalOutcomeV1 = control == .endAndSave
                ? .saved
                : .discarded
            do {
                let runtime = try await makeTimedOutTerminalRuntime(
                    control: control,
                    sequence: baseSequence + 5,
                    clockOffset: TimeInterval(index * 100 + 10)
                )
                runtime.manager.applyRemoteEnvelopes(
                    terminalEnvelopes(
                        after: runtime.snapshot,
                        outcome: matchingOutcome,
                        capturedAt: runtime.now.addingTimeInterval(1)
                    ),
                    receivedAt: runtime.now.addingTimeInterval(2),
                    from: runtime.transport
                )
                XCTAssertNil(runtime.manager.store.presentation.errorCode)
                XCTAssertEqual(
                    runtime.manager.store.presentation.connectionState,
                    control == .discard ? .idle : .ended
                )
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertNil(
                    runtime.manager.store.presentation.errorCode,
                    "matching final outcome must remain reconciled"
                )
            }

            let oppositeOutcome: WorkoutTerminalOutcomeV1 = control == .endAndSave
                ? .discarded
                : .saved
            do {
                let runtime = try await makeTimedOutTerminalRuntime(
                    control: control,
                    sequence: baseSequence + 10,
                    clockOffset: TimeInterval(index * 100 + 20)
                )
                runtime.manager.applyRemoteEnvelopes(
                    terminalEnvelopes(
                        after: runtime.snapshot,
                        outcome: oppositeOutcome,
                        capturedAt: runtime.now.addingTimeInterval(1)
                    ),
                    receivedAt: runtime.now.addingTimeInterval(2),
                    from: runtime.transport
                )
                XCTAssertEqual(
                    runtime.manager.store.presentation.errorCode,
                    .terminalChoiceConflict
                )
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertEqual(
                    runtime.manager.store.presentation.errorCode,
                    .terminalChoiceConflict,
                    "late timeout work must not overwrite an opposite outcome"
                )
            }
        }
    }

    func testTimedOutTerminalWarningSurvivesReconnectUntilMatchingEvidence() async throws {
        for (index, control) in [
            WorkoutControlV1.endAndSave,
            .discard,
        ].enumerated() {
            let baseSequence = UInt64(180 + index * 10)
            let runtime = try await makeTimedOutTerminalRuntime(
                control: control,
                sequence: baseSequence,
                clockOffset: TimeInterval(300 + index * 10)
            )
            runtime.manager.applyRemoteDisconnect(
                error: nil,
                from: runtime.transport
            )
            let replacement = FakeMirroredSessionTransport()
            runtime.manager.acceptMirroredTransport(replacement)
            XCTAssertEqual(
                runtime.manager.store.presentation.errorCode,
                .terminalChoiceUnconfirmed,
                "active reconnect must keep the unresolved terminal warning visible"
            )

            let acknowledgement = WorkoutEnvelopeV1(
                kind: .acknowledgement,
                sessionID: runtime.snapshot.sessionID,
                sessionToken: runtime.snapshot.sessionToken,
                transportGenerationID:
                    runtime.snapshot.transportGenerationID,
                sequence: baseSequence + 1,
                capturedAt: runtime.now.addingTimeInterval(1),
                acknowledgement: WorkoutAcknowledgementV1(
                    control: control,
                    resultingState: .ending,
                    acknowledgedSequence: runtime.control.sequence
                )
            )
            runtime.manager.applyRemoteEnvelopes(
                [acknowledgement],
                receivedAt: runtime.now.addingTimeInterval(1),
                from: replacement
            )
            XCTAssertNil(runtime.manager.store.presentation.errorCode)
        }
    }

    func testTimedOutTerminalRejectsUncorrelatedLateAcknowledgements() async throws {
        for (index, control) in [
            WorkoutControlV1.endAndSave,
            .discard,
        ].enumerated() {
            let baseSequence = UInt64(220 + index * 10)
            let runtime = try await makeTimedOutTerminalRuntime(
                control: control,
                sequence: baseSequence,
                clockOffset: TimeInterval(400 + index * 10)
            )
            let wrongControl: WorkoutControlV1 = control == .endAndSave
                ? .discard
                : .endAndSave
            let wrongVerb = WorkoutEnvelopeV1(
                kind: .acknowledgement,
                sessionID: runtime.snapshot.sessionID,
                sessionToken: runtime.snapshot.sessionToken,
                transportGenerationID:
                    runtime.snapshot.transportGenerationID,
                sequence: baseSequence + 1,
                capturedAt: runtime.now.addingTimeInterval(1),
                acknowledgement: WorkoutAcknowledgementV1(
                    control: wrongControl,
                    resultingState: .ending,
                    acknowledgedSequence: runtime.control.sequence
                )
            )
            let wrongSequence = WorkoutEnvelopeV1(
                kind: .acknowledgement,
                sessionID: runtime.snapshot.sessionID,
                sessionToken: runtime.snapshot.sessionToken,
                transportGenerationID:
                    runtime.snapshot.transportGenerationID,
                sequence: baseSequence + 2,
                capturedAt: runtime.now.addingTimeInterval(1.5),
                acknowledgement: WorkoutAcknowledgementV1(
                    control: control,
                    resultingState: .ending,
                    acknowledgedSequence: runtime.control.sequence + 100
                )
            )
            runtime.manager.applyRemoteEnvelopes(
                [wrongVerb, wrongSequence],
                receivedAt: runtime.now.addingTimeInterval(2),
                from: runtime.transport
            )
            XCTAssertEqual(
                runtime.manager.store.presentation.errorCode,
                .terminalChoiceUnconfirmed,
                "wrong verb or sequence must not resolve a timed-out terminal choice"
            )

            let matching = WorkoutEnvelopeV1(
                kind: .acknowledgement,
                sessionID: runtime.snapshot.sessionID,
                sessionToken: runtime.snapshot.sessionToken,
                transportGenerationID:
                    runtime.snapshot.transportGenerationID,
                sequence: baseSequence + 3,
                capturedAt: runtime.now.addingTimeInterval(2),
                acknowledgement: WorkoutAcknowledgementV1(
                    control: control,
                    resultingState: .ending,
                    acknowledgedSequence: runtime.control.sequence
                )
            )
            runtime.manager.applyRemoteEnvelopes(
                [matching],
                receivedAt: runtime.now.addingTimeInterval(2),
                from: runtime.transport
            )
            XCTAssertNil(runtime.manager.store.presentation.errorCode)
        }
    }

    func testEvidenceBeforeDeadlineCancelsTerminalTimeout() async throws {
        for (index, control) in [
            WorkoutControlV1.endAndSave,
            .discard,
        ].enumerated() {
            for resolvesWithOutcome in [false, true] {
                let now = Date(
                    timeIntervalSinceReferenceDate: 800_401_700
                        + TimeInterval(index * 100)
                        + (resolvesWithOutcome ? 10 : 0)
                )
                let manager = WorkoutMirrorManager(
                    now: { now },
                    controlConfirmationTimeout: 0.05
                )
                let transport = FakeMirroredSessionTransport()
                manager.acceptMirroredTransport(transport)
                let snapshot = makeSnapshotEnvelope(
                    sequence: UInt64(260 + index * 20),
                    capturedAt: now
                )
                manager.applyRemoteEnvelopes(
                    [snapshot],
                    receivedAt: now,
                    from: transport
                )
                if control == .endAndSave {
                    manager.endAndSave()
                } else {
                    manager.discard()
                }
                let sentControl = try WorkoutContractCodec.decode(
                    XCTUnwrap(transport.sentData.first)
                )

                if resolvesWithOutcome {
                    let outcome: WorkoutTerminalOutcomeV1 = control == .endAndSave
                        ? .saved
                        : .discarded
                    manager.applyRemoteEnvelopes(
                        terminalEnvelopes(
                            after: snapshot,
                            outcome: outcome,
                            capturedAt: now.addingTimeInterval(1)
                        ),
                        receivedAt: now.addingTimeInterval(2),
                        from: transport
                    )
                } else {
                    manager.applyRemoteEnvelopes(
                        [
                            WorkoutEnvelopeV1(
                                kind: .acknowledgement,
                                sessionID: snapshot.sessionID,
                                sessionToken: snapshot.sessionToken,
                                transportGenerationID:
                                    snapshot.transportGenerationID,
                                sequence: snapshot.sequence + 1,
                                capturedAt: now.addingTimeInterval(1),
                                acknowledgement: WorkoutAcknowledgementV1(
                                    control: control,
                                    resultingState: .ending,
                                    acknowledgedSequence: sentControl.sequence
                                )
                            ),
                        ],
                        receivedAt: now.addingTimeInterval(1),
                        from: transport
                    )
                }
                XCTAssertNil(manager.store.presentation.pendingControl)
                XCTAssertNil(manager.store.presentation.errorCode)
                try await Task.sleep(for: .milliseconds(80))
                XCTAssertNil(
                    manager.store.presentation.errorCode,
                    "the original scheduled timeout must not overwrite evidence received before its deadline"
                )
            }
        }
    }

    private func makeTimedOutTerminalRuntime(
        control: WorkoutControlV1,
        sequence: UInt64,
        clockOffset: TimeInterval
    ) async throws -> (
        manager: WorkoutMirrorManager,
        transport: FakeMirroredSessionTransport,
        snapshot: WorkoutEnvelopeV1,
        control: WorkoutEnvelopeV1,
        now: Date
    ) {
        let now = Date(
            timeIntervalSinceReferenceDate: 800_401_100 + clockOffset
        )
        let manager = WorkoutMirrorManager(
            now: { now },
            controlConfirmationTimeout: 0.02
        )
        let transport = FakeMirroredSessionTransport()
        manager.acceptMirroredTransport(transport)
        let snapshot = makeSnapshotEnvelope(
            sequence: sequence,
            capturedAt: now
        )
        manager.applyRemoteEnvelopes(
            [snapshot],
            receivedAt: now,
            from: transport
        )
        switch control {
        case .endAndSave:
            manager.endAndSave()
        case .discard:
            manager.discard()
        default:
            XCTFail("Expected a terminal control")
        }
        let controlEnvelope = try WorkoutContractCodec.decode(
            XCTUnwrap(transport.sentData.first)
        )
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(manager.store.presentation.pendingControl)
        XCTAssertEqual(
            manager.store.presentation.errorCode,
            .terminalChoiceUnconfirmed
        )
        return (manager, transport, snapshot, controlEnvelope, now)
    }

    private func terminalEnvelopes(
        after snapshot: WorkoutEnvelopeV1,
        outcome: WorkoutTerminalOutcomeV1,
        capturedAt: Date
    ) -> [WorkoutEnvelopeV1] {
        [
            WorkoutEnvelopeV1(
                kind: .snapshot,
                sessionID: snapshot.sessionID,
                sessionToken: snapshot.sessionToken,
                transportGenerationID: snapshot.transportGenerationID,
                sequence: snapshot.sequence + 1,
                capturedAt: capturedAt,
                snapshot: WorkoutSnapshotV1(
                    state: .ending,
                    startDate: snapshot.snapshot?.startDate
                )
            ),
            WorkoutEnvelopeV1(
                kind: .snapshot,
                sessionID: snapshot.sessionID,
                sessionToken: snapshot.sessionToken,
                transportGenerationID: snapshot.transportGenerationID,
                sequence: snapshot.sequence + 2,
                capturedAt: capturedAt.addingTimeInterval(1),
                snapshot: WorkoutSnapshotV1(
                    state: .ended,
                    startDate: snapshot.snapshot?.startDate,
                    terminalOutcome: outcome
                )
            ),
        ]
    }

    private func makeSnapshotEnvelope(
        sequence: UInt64,
        capturedAt: Date,
        state: WorkoutSessionStateV1 = .running,
        errorCode: WorkoutSafeErrorCodeV1? = nil,
        startDate: Date? = nil,
        sessionID: UUID = UUID(
            uuidString: "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        )!,
        sessionToken: UInt16 = 9,
        transportGenerationID: UUID = UUID(
            uuidString: "CCCCCCCC-1111-2222-3333-DDDDDDDDDDDD"
        )!
    ) -> WorkoutEnvelopeV1 {
        WorkoutEnvelopeV1(
            kind: .snapshot,
            sessionID: sessionID,
            sessionToken: sessionToken,
            transportGenerationID: transportGenerationID,
            sequence: sequence,
            capturedAt: capturedAt,
            snapshot: WorkoutSnapshotV1(
                state: state,
                startDate: startDate
                    ?? capturedAt.addingTimeInterval(-30),
                errorCode: errorCode
            )
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for asynchronous iPhone state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@available(iOS 17.0, *)
@MainActor
private final class ControlledWorkoutTimeoutWaiter {
    private var continuations: [CheckedContinuation<Void, Error>?] = []
    private var returnedWaits: Set<Int> = []

    var waitCallCount: Int { continuations.count }

    func wait(_ timeout: TimeInterval) async throws {
        _ = timeout
        let index = continuations.count
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
        returnedWaits.insert(index)
    }

    func hasReturned(at index: Int) -> Bool {
        returnedWaits.contains(index)
    }

    func completeWait(at index: Int) {
        guard continuations.indices.contains(index),
              let continuation = continuations[index] else {
            return
        }
        continuations[index] = nil
        continuation.resume()
    }
}

@available(iOS 17.0, *)
private final class WatchLaunchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedConfiguration: HKWorkoutConfiguration?
    private var storedCompletions: [(@Sendable (Bool, Error?) -> Void)] = []

    var configuration: HKWorkoutConfiguration? {
        lock.withLock { storedConfiguration }
    }

    func launch(
        configuration: HKWorkoutConfiguration,
        completion: @escaping @Sendable (Bool, Error?) -> Void
    ) {
        lock.withLock {
            storedConfiguration = configuration
            storedCompletions.append(completion)
        }
    }

    func complete(succeeded: Bool) {
        completeNext(succeeded: succeeded)
    }

    func completeNext(succeeded: Bool) {
        let completion = lock.withLock {
            storedCompletions.isEmpty ? nil : storedCompletions.removeFirst()
        }
        completion?(succeeded, nil)
    }
}

@available(iOS 17.0, *)
@MainActor
private final class FakeMirroredSessionTransport:
    WorkoutMirroredSessionTransport {
    var sessionStartDate: Date?
    private(set) var sentData: [Data] = []
    private(set) var pauseCallCount = 0
    private(set) var resumeCallCount = 0
    private var completions: [@Sendable (Bool, Error?) -> Void] = []
    private weak var delegate: HKWorkoutSessionDelegate?

    init(sessionStartDate: Date? = nil) {
        self.sessionStartDate = sessionStartDate
    }

    var healthKitSession: HKWorkoutSession? { nil }
    var hasDelegate: Bool { delegate != nil }

    func installDelegate(_ delegate: HKWorkoutSessionDelegate?) {
        self.delegate = delegate
    }

    func pause() {
        pauseCallCount += 1
    }

    func resume() {
        resumeCallCount += 1
    }

    func send(
        data: Data,
        completion: @escaping @Sendable (Bool, Error?) -> Void
    ) {
        sentData.append(data)
        completions.append(completion)
    }

    func completeNext(succeeded: Bool) {
        guard !completions.isEmpty else { return }
        let completion = completions.removeFirst()
        completion(succeeded, nil)
    }
}
