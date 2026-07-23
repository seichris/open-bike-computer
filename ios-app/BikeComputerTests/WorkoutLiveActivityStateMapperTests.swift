import XCTest

@available(iOS 17.0, *)
final class WorkoutLiveActivityStateMapperTests: XCTestCase {
    func testRunningSnapshotMapsDisplaySafeMetricsAndControls() throws {
        let capturedAt = Date(timeIntervalSinceReferenceDate: 800_500_000)
        let sessionID = UUID()
        let segment = WorkoutCompletedSegmentV1(
            index: 3,
            startedAt: capturedAt.addingTimeInterval(-60),
            endedAt: capturedAt,
            duration: 60,
            distanceMeters: 500
        )
        let mapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                makeLiveActivityPresentation(
                    sessionID: sessionID,
                    capturedAt: capturedAt,
                    segment: segment
                ),
                at: capturedAt
            )
        )

        XCTAssertEqual(mapped.attributes.sessionID, sessionID)
        XCTAssertEqual(mapped.contentState.phase, .running)
        XCTAssertEqual(
            try XCTUnwrap(
                mapped.contentState.currentSpeedKilometersPerHour
            ),
            28.8,
            accuracy: 0.001
        )
        XCTAssertEqual(mapped.contentState.cyclingDistanceMeters, 2_500)
        XCTAssertEqual(mapped.contentState.currentHeartRateBPM, 140)
        XCTAssertEqual(mapped.contentState.lastCompletedSegmentIndex, 3)
        XCTAssertTrue(mapped.contentState.canMarkSegment)
        XCTAssertTrue(mapped.isStartEligible)
    }

    func testInvalidHeartRateRemainsUnavailableAndPayloadIsSmall() throws {
        let capturedAt = Date(timeIntervalSinceReferenceDate: 800_500_000)
        let mapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                makeLiveActivityPresentation(
                    capturedAt: capturedAt,
                    heartRate: -.infinity
                ),
                at: capturedAt
            )
        )

        XCTAssertNil(mapped.contentState.currentHeartRateBPM)
        let payload = try JSONEncoder().encode(mapped.contentState)
        XCTAssertLessThan(payload.count, 4_096)
    }

    func testStaleWorkoutFreezesInstantaneousMetricsAndControls() throws {
        let capturedAt = Date(timeIntervalSinceReferenceDate: 800_500_000)
        let mapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                makeLiveActivityPresentation(
                    connection: .stale,
                    capturedAt: capturedAt
                ),
                at: capturedAt.addingTimeInterval(12)
            )
        )

        XCTAssertEqual(mapped.contentState.phase, .stale)
        XCTAssertNil(mapped.contentState.currentSpeedKilometersPerHour)
        XCTAssertNil(mapped.contentState.currentHeartRateBPM)
        XCTAssertEqual(mapped.contentState.cyclingDistanceMeters, 2_500)
        XCTAssertFalse(mapped.contentState.canMarkSegment)
        XCTAssertFalse(mapped.isStartEligible)
    }

    func testPausedAndTerminalStatesRemainHonest() throws {
        let capturedAt = Date(timeIntervalSinceReferenceDate: 800_500_000)
        let paused = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                makeLiveActivityPresentation(
                    state: .paused,
                    capturedAt: capturedAt,
                    pendingControl: .resume
                ),
                at: capturedAt
            )
        )
        XCTAssertEqual(paused.contentState.phase, .paused)
        XCTAssertEqual(paused.contentState.pendingAction, .resume)
        XCTAssertFalse(paused.contentState.canResume)

        let saved = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                makeLiveActivityPresentation(
                    state: .ended,
                    connection: .ended,
                    capturedAt: capturedAt,
                    terminalOutcome: .saved
                ),
                at: capturedAt
            )
        )
        XCTAssertEqual(saved.contentState.phase, .final)
        XCTAssertEqual(saved.contentState.finalOutcome, .saved)
        XCTAssertTrue(saved.isTerminal)
        XCTAssertFalse(saved.isStartEligible)

        let discarded = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                makeLiveActivityPresentation(
                    state: .ended,
                    connection: .ended,
                    capturedAt: capturedAt,
                    terminalOutcome: .discarded
                ),
                at: capturedAt
            )
        )
        XCTAssertEqual(discarded.contentState.finalOutcome, .discarded)
        XCTAssertNotEqual(
            saved.contentState.finalOutcome,
            discarded.contentState.finalOutcome
        )
    }

    func testDisconnectedAndEndingVariantsDisableInstantControls() throws {
        let capturedAt = Date(timeIntervalSinceReferenceDate: 800_500_000)
        let disconnected = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                makeLiveActivityPresentation(
                    connection: .disconnected,
                    capturedAt: capturedAt
                ),
                at: capturedAt
            )
        )
        XCTAssertEqual(disconnected.contentState.phase, .disconnected)
        XCTAssertEqual(
            disconnected.contentState.displayError,
            .controlsUnavailable
        )
        XCTAssertNil(
            disconnected.contentState.currentSpeedKilometersPerHour
        )
        XCTAssertFalse(disconnected.contentState.canMarkSegment)

        let ending = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                makeLiveActivityPresentation(
                    state: .ending,
                    capturedAt: capturedAt
                ),
                at: capturedAt
            )
        )
        XCTAssertEqual(ending.contentState.phase, .ending)
        XCTAssertNil(ending.contentState.currentHeartRateBPM)
        XCTAssertFalse(ending.contentState.canPause)
    }

    func testPendingSegmentAndSegmentFailureRemainUnconfirmed() throws {
        let capturedAt = Date(timeIntervalSinceReferenceDate: 800_500_000)
        let segment = WorkoutCompletedSegmentV1(
            index: 2,
            startedAt: capturedAt.addingTimeInterval(-45),
            endedAt: capturedAt,
            duration: 45,
            distanceMeters: 400
        )
        let pending = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                makeLiveActivityPresentation(
                    capturedAt: capturedAt,
                    pendingControl: .markSegment,
                    segment: segment
                ),
                at: capturedAt
            )
        )
        XCTAssertEqual(pending.contentState.pendingAction, .segment)
        XCTAssertEqual(pending.contentState.lastCompletedSegmentIndex, 2)
        XCTAssertFalse(pending.contentState.canMarkSegment)

        let rejected = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                makeLiveActivityPresentation(
                    capturedAt: capturedAt,
                    errorCode: .segmentMarkFailed,
                    segment: segment
                ),
                at: capturedAt
            )
        )
        XCTAssertEqual(
            rejected.contentState.displayError,
            .segmentRejected
        )
        XCTAssertEqual(rejected.contentState.lastCompletedSegmentIndex, 2)
    }

    func testInvalidMetricsRemainUnavailableInsteadOfZero() throws {
        let capturedAt = Date(timeIntervalSinceReferenceDate: 800_500_000)
        let mapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                makeLiveActivityPresentation(
                    capturedAt: capturedAt,
                    speedMetersPerSecond: .nan,
                    distanceMeters: -1,
                    heartRate: 0
                ),
                at: capturedAt
            )
        )

        XCTAssertNil(mapped.contentState.currentSpeedKilometersPerHour)
        XCTAssertNil(mapped.contentState.cyclingDistanceMeters)
        XCTAssertNil(mapped.contentState.currentHeartRateBPM)
    }

    func testUnverifiedAndMismatchedDataCannotStartActivity() {
        XCTAssertNil(
            WorkoutLiveActivityStateMapper.map(
                .idle,
                at: Date(timeIntervalSinceReferenceDate: 800_500_000)
            )
        )

        let capturedAt = Date(timeIntervalSinceReferenceDate: 800_500_000)
        let verified = makeLiveActivityPresentation(
            capturedAt: capturedAt
        )
        let missingIdentity = WorkoutMirrorPresentationV1(
            connectionState: verified.connectionState,
            snapshot: verified.snapshot,
            sessionID: nil,
            capturedAt: verified.capturedAt,
            receivedAt: verified.receivedAt,
            confirmedSessionState: verified.confirmedSessionState,
            errorCode: verified.errorCode,
            pendingControl: verified.pendingControl,
            finalSnapshot: verified.finalSnapshot,
            navigation: verified.navigation
        )
        XCTAssertNil(
            WorkoutLiveActivityStateMapper.map(
                missingIdentity,
                at: capturedAt
            )
        )
    }
}
