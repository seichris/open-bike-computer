import XCTest

@available(iOS 17.0, *)
@MainActor
private final class WorkoutLiveActivityCallCounter {
    var value = 0
}

@available(iOS 17.0, *)
@MainActor
private final class WorkoutLiveActivityTestClock {
    var date: Date
    private(set) var waits = 0

    init(_ date: Date) {
        self.date = date
    }

    func advance(by interval: TimeInterval) {
        waits += 1
        date.addTimeInterval(interval)
    }
}

@available(iOS 17.0, *)
@MainActor
final class WorkoutLiveActivityIntentTests: XCTestCase {
    private let capturedAt =
        Date(timeIntervalSinceReferenceDate: 800_500_000)

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
            now: { capturedAt },
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

    func testMissingAppProcessDependencyFailsSafely() async {
        let accepted = await WorkoutLiveActivityIntentDispatcher.unavailable
            .perform(.pause, sessionID: UUID())

        XCTAssertFalse(accepted)
    }

    func testColdIntentStopsAfterBoundedRecoveryTimeout() async {
        let sessionID = UUID()
        let state =
            TestWorkoutLiveActivityControlState(.idle)
        let clock = WorkoutLiveActivityTestClock(capturedAt)
        let calls = WorkoutLiveActivityCallCounter()
        let router = WorkoutLiveActivityCommandRouter(
            store: state,
            recoveryTimeout: 0.25,
            now: { clock.date },
            wait: { interval in clock.advance(by: interval) },
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
        XCTAssertEqual(clock.waits, 3)
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
