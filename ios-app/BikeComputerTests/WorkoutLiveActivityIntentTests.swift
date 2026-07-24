import AppIntents
import XCTest

@available(iOS 17.0, *)
@MainActor
private final class WorkoutLiveActivityCallCounter {
    var value = 0
}

@available(iOS 17.0, *)
@MainActor
final class WorkoutLiveActivityIntentTests: XCTestCase {
    private let capturedAt =
        Date(timeIntervalSinceReferenceDate: 800_500_000)

    func testControlsRequireAuthentication() {
        XCTAssertEqual(
            BikeComputerMarkSegmentIntent.authenticationPolicy,
            .requiresAuthentication
        )
        XCTAssertEqual(
            BikeComputerPauseWorkoutIntent.authenticationPolicy,
            .requiresAuthentication
        )
        XCTAssertEqual(
            BikeComputerResumeWorkoutIntent.authenticationPolicy,
            .requiresAuthentication
        )
    }

    func testSegmentRoutesOnlyForMatchingConnectedRunningSession() async {
        let sessionID = UUID()
        let state = controlState(sessionID: sessionID)
        let calls = WorkoutLiveActivityCallCounter()
        let router = WorkoutLiveActivityCommandRouter(
            store: state,
            markSegment: {
                calls.value += 1
                state.presentation = self.presentation(
                    sessionID: sessionID,
                    pending: .markSegment
                )
            },
            pause: {},
            resume: {}
        )

        let rejected = await router.perform(
            .segment,
            sessionID: UUID()
        )
        XCTAssertFalse(rejected)
        XCTAssertEqual(calls.value, 0)

        let accepted = await router.perform(
            .segment,
            sessionID: sessionID
        )
        XCTAssertTrue(accepted)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(state.presentation.pendingControl, .markSegment)
    }

    func testPauseAndResumeValidateConfirmedState() async {
        let sessionID = UUID()
        let running = controlState(sessionID: sessionID)
        let pauseCalls = WorkoutLiveActivityCallCounter()
        let pauseRouter = WorkoutLiveActivityCommandRouter(
            store: running,
            markSegment: {},
            pause: {
                pauseCalls.value += 1
                running.presentation = self.presentation(
                    sessionID: sessionID,
                    pending: .pause
                )
            },
            resume: {}
        )
        let acceptedPause = await pauseRouter.perform(
            .pause,
            sessionID: sessionID
        )
        XCTAssertTrue(acceptedPause)
        XCTAssertEqual(pauseCalls.value, 1)

        let paused = controlState(
            sessionID: sessionID,
            state: .paused
        )
        let resumeCalls = WorkoutLiveActivityCallCounter()
        let resumeRouter = WorkoutLiveActivityCommandRouter(
            store: paused,
            markSegment: {},
            pause: {},
            resume: {
                resumeCalls.value += 1
                paused.presentation = self.presentation(
                    sessionID: sessionID,
                    state: .paused,
                    pending: .resume
                )
            }
        )
        let rejectedPause = await resumeRouter.perform(
            .pause,
            sessionID: sessionID
        )
        XCTAssertFalse(rejectedPause)
        let acceptedResume = await resumeRouter.perform(
            .resume,
            sessionID: sessionID
        )
        XCTAssertTrue(acceptedResume)
        XCTAssertEqual(resumeCalls.value, 1)
    }

    func testDisconnectedPendingAndUnsupportedSegmentAreRejected() async {
        let sessionID = UUID()
        let calls = WorkoutLiveActivityCallCounter()
        let disconnected = TestWorkoutLiveActivityControlState(
            presentation(
                sessionID: sessionID,
                connection: .disconnected
            )
        )
        let disconnectedRouter = router(
            state: disconnected,
            calls: calls
        )
        let disconnectedResult = await disconnectedRouter.perform(
            .segment,
            sessionID: sessionID
        )
        XCTAssertFalse(disconnectedResult)

        let pending = TestWorkoutLiveActivityControlState(
            presentation(
                sessionID: sessionID,
                pending: .pause
            )
        )
        let pendingRouter = router(state: pending, calls: calls)
        let pendingResult = await pendingRouter.perform(
            .pause,
            sessionID: sessionID
        )
        XCTAssertFalse(pendingResult)

        let unsupported = controlState(sessionID: sessionID)
        unsupported.supportsSegmentMarking = false
        let unsupportedRouter = router(
            state: unsupported,
            calls: calls
        )
        let unsupportedResult = await unsupportedRouter.perform(
            .segment,
            sessionID: sessionID
        )
        XCTAssertFalse(unsupportedResult)

        let terminal = controlState(
            sessionID: sessionID,
            state: .ending
        )
        let terminalRouter = router(state: terminal, calls: calls)
        let terminalResult = await terminalRouter.perform(
            .pause,
            sessionID: sessionID
        )
        XCTAssertFalse(terminalResult)
        XCTAssertEqual(calls.value, 0)
    }

    func testTimedOutTerminalChoiceRejectsConflictingControls() async {
        let sessionID = UUID()
        let calls = WorkoutLiveActivityCallCounter()
        let state = TestWorkoutLiveActivityControlState(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                capturedAt: capturedAt,
                errorCode: .terminalChoiceUnconfirmed
            )
        )
        let rejected = await router(
            state: state,
            calls: calls
        ).perform(.pause, sessionID: sessionID)

        XCTAssertFalse(rejected)
        XCTAssertEqual(calls.value, 0)
    }

    func testCommandDoesNotReportSuccessWithoutPendingPublication() async {
        let sessionID = UUID()
        let state = controlState(sessionID: sessionID)
        let calls = WorkoutLiveActivityCallCounter()
        let router = WorkoutLiveActivityCommandRouter(
            store: state,
            markSegment: {},
            pause: { calls.value += 1 },
            resume: {}
        )

        let accepted = await router.perform(
            .pause,
            sessionID: sessionID
        )
        XCTAssertFalse(accepted)
        XCTAssertEqual(calls.value, 1)
    }

    func testColdIntentWaitsBrieflyForMatchingMirroredSession() async {
        let sessionID = UUID()
        let capturedAt = capturedAt
        let state =
            TestWorkoutLiveActivityControlState(.idle)
        let pauseCalls = WorkoutLiveActivityCallCounter()
        let router = WorkoutLiveActivityCommandRouter(
            store: state,
            recoveryTimeout: 1,
            wait: { _ in
                state.presentation = makeLiveActivityPresentation(
                    sessionID: sessionID,
                    capturedAt: capturedAt
                )
            },
            markSegment: {},
            pause: {
                pauseCalls.value += 1
                state.presentation = makeLiveActivityPresentation(
                    sessionID: sessionID,
                    capturedAt: capturedAt,
                    pendingControl: .pause
                )
            },
            resume: {}
        )

        let accepted = await router.perform(
            .pause,
            sessionID: sessionID
        )
        XCTAssertTrue(accepted)
        XCTAssertEqual(pauseCalls.value, 1)
    }

    func testActionResolutionWaitStopsAfterWatchConfirmation() async {
        let sessionID = UUID()
        let state = controlState(sessionID: sessionID)
        var waits: [TimeInterval] = []
        let router = WorkoutLiveActivityCommandRouter(
            store: state,
            actionResolutionTimeout: 1,
            actionResolutionWait: { interval in
                waits.append(interval)
                state.presentation = self.presentation(
                    sessionID: sessionID,
                    state: .paused
                )
            },
            markSegment: {},
            pause: {
                state.presentation = self.presentation(
                    sessionID: sessionID,
                    pending: .pause
                )
            },
            resume: {}
        )

        let accepted = await router.perform(
            .pause,
            sessionID: sessionID
        )
        XCTAssertTrue(accepted)
        await router.waitForResolution(
            of: .pause,
            sessionID: sessionID
        )

        XCTAssertEqual(waits, [0.1])
        XCTAssertEqual(state.presentation.sessionState, .paused)
        XCTAssertNil(state.presentation.pendingControl)
    }

    func testActionResolutionWaitHasBoundedTimeout() async {
        let sessionID = UUID()
        let state = controlState(sessionID: sessionID)
        var waits: [TimeInterval] = []
        let router = WorkoutLiveActivityCommandRouter(
            store: state,
            actionResolutionTimeout: 0.25,
            actionResolutionWait: { interval in
                waits.append(interval)
            },
            markSegment: {
                state.presentation = self.presentation(
                    sessionID: sessionID,
                    pending: .markSegment
                )
            },
            pause: {},
            resume: {}
        )

        let accepted = await router.perform(
            .segment,
            sessionID: sessionID
        )
        XCTAssertTrue(accepted)
        await router.waitForResolution(
            of: .segment,
            sessionID: sessionID
        )

        XCTAssertEqual(waits.count, 3)
        XCTAssertEqual(waits[0], 0.1, accuracy: 0.000_001)
        XCTAssertEqual(waits[1], 0.1, accuracy: 0.000_001)
        XCTAssertEqual(waits[2], 0.05, accuracy: 0.000_001)
        XCTAssertEqual(
            state.presentation.pendingControl,
            .markSegment
        )
    }

    func testMissingAppProcessDependencyFailsSafely() async {
        let accepted = await WorkoutLiveActivityIntentDispatcher.unavailable
            .perform(.pause, sessionID: UUID())

        XCTAssertFalse(accepted)
    }

    func testIntentExecutionThrowsWhenCommandIsRejected() async {
        do {
            try await WorkoutLiveActivityIntentExecution.perform(
                .pause,
                sessionID: UUID().uuidString,
                dispatcher: .unavailable
            )
            XCTFail("A rejected workout command must not report success")
        } catch let error as WorkoutLiveActivityIntentError {
            guard case .commandRejected = error else {
                return XCTFail("Unexpected intent error: \(error)")
            }
        } catch {
            XCTFail("Unexpected intent error: \(error)")
        }
    }

    func testIntentExecutionRejectsMalformedSessionIdentifier() async {
        do {
            try await WorkoutLiveActivityIntentExecution.perform(
                .pause,
                sessionID: "not-a-session",
                dispatcher: .unavailable
            )
            XCTFail("An invalid session must not report success")
        } catch let error as WorkoutLiveActivityIntentError {
            guard case .invalidSession = error else {
                return XCTFail("Unexpected intent error: \(error)")
            }
        } catch {
            XCTFail("Unexpected intent error: \(error)")
        }
    }

    func testColdIntentStopsAfterBoundedRecoveryTimeout() async {
        let sessionID = UUID()
        let state =
            TestWorkoutLiveActivityControlState(.idle)
        let calls = WorkoutLiveActivityCallCounter()
        var waits: [TimeInterval] = []
        let router = WorkoutLiveActivityCommandRouter(
            store: state,
            recoveryTimeout: 0.25,
            wait: { interval in waits.append(interval) },
            markSegment: {},
            pause: { calls.value += 1 },
            resume: {}
        )

        let accepted = await router.perform(
            .pause,
            sessionID: sessionID
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(waits.count, 3)
        XCTAssertEqual(waits[0], 0.1, accuracy: 0.000_001)
        XCTAssertEqual(waits[1], 0.1, accuracy: 0.000_001)
        XCTAssertEqual(waits[2], 0.05, accuracy: 0.000_001)
    }

    private func controlState(
        sessionID: UUID,
        state: WorkoutSessionStateV1 = .running
    ) -> TestWorkoutLiveActivityControlState {
        TestWorkoutLiveActivityControlState(
            presentation(sessionID: sessionID, state: state)
        )
    }

    private func presentation(
        sessionID: UUID,
        state: WorkoutSessionStateV1 = .running,
        connection: WorkoutMirrorConnectionStateV1 = .connected,
        pending: WorkoutControlV1? = nil
    ) -> WorkoutMirrorPresentationV1 {
        makeLiveActivityPresentation(
            sessionID: sessionID,
            state: state,
            connection: connection,
            capturedAt: capturedAt,
            pendingControl: pending
        )
    }

    private func router(
        state: TestWorkoutLiveActivityControlState,
        calls: WorkoutLiveActivityCallCounter
    ) -> WorkoutLiveActivityCommandRouter {
        WorkoutLiveActivityCommandRouter(
            store: state,
            markSegment: { calls.value += 1 },
            pause: { calls.value += 1 },
            resume: { calls.value += 1 }
        )
    }
}
