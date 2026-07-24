import Combine
import Foundation

@available(iOS 17.0, *)
func makeLiveActivityPresentation(
    sessionID: UUID = UUID(),
    state: WorkoutSessionStateV1 = .running,
    connection: WorkoutMirrorConnectionStateV1 = .connected,
    capturedAt: Date = Date(timeIntervalSinceReferenceDate: 800_500_000),
    elapsed: Double? = 120,
    speedMetersPerSecond: Double? = 8,
    distanceMeters: Double? = 2_500,
    heartRate: Double? = 140,
    pendingControl: WorkoutControlV1? = nil,
    errorCode: WorkoutSafeErrorCodeV1? = nil,
    segment: WorkoutCompletedSegmentV1? = nil,
    terminalOutcome: WorkoutTerminalOutcomeV1? = nil
) -> WorkoutMirrorPresentationV1 {
    let startDate = capturedAt.addingTimeInterval(-(elapsed ?? 120))
    let snapshot = WorkoutSnapshotV1(
        state: state,
        startDate: startDate,
        elapsedTime: elapsed.map {
            WorkoutMetricV1(
                value: $0,
                unit: .seconds,
                capturedAt: capturedAt
            )
        },
        currentHeartRate: heartRate.map {
            WorkoutMetricV1(
                value: $0,
                unit: .beatsPerMinute,
                capturedAt: capturedAt
            )
        },
        cyclingDistance: distanceMeters.map {
            WorkoutMetricV1(
                value: $0,
                unit: .meters,
                capturedAt: capturedAt
            )
        },
        currentSpeed: speedMetersPerSecond.map {
            WorkoutMetricV1(
                value: $0,
                unit: .metersPerSecond,
                capturedAt: capturedAt
            )
        },
        lastCompletedSegment: segment,
        terminalOutcome: terminalOutcome
    )
    return WorkoutMirrorPresentationV1(
        connectionState: connection,
        snapshot: snapshot,
        sessionID: sessionID,
        capturedAt: capturedAt,
        receivedAt: capturedAt,
        confirmedSessionState: state,
        errorCode: errorCode,
        pendingControl: pendingControl,
        finalSnapshot: state == .ended ? snapshot : nil,
        navigation: .empty
    )
}

@available(iOS 17.0, *)
@available(iOS 17.0, *)
@MainActor
final class TestWorkoutLiveActivityPresentationSource:
    WorkoutLiveActivityPresentationProviding {
    private let subject:
        CurrentValueSubject<WorkoutMirrorPresentationV1, Never>

    var presentation: WorkoutMirrorPresentationV1 {
        subject.value
    }

    var presentationPublisher:
        AnyPublisher<WorkoutMirrorPresentationV1, Never> {
        subject.eraseToAnyPublisher()
    }
    var supportsSegmentMarking = true
    var isSegmentConfirmationPending = false

    init(_ presentation: WorkoutMirrorPresentationV1) {
        subject = CurrentValueSubject(presentation)
    }

    func send(_ presentation: WorkoutMirrorPresentationV1) {
        subject.send(presentation)
    }
}

@available(iOS 17.0, *)
@MainActor
final class TestWorkoutLiveActivityControlState:
    WorkoutLiveActivityControlStateProviding {
    var presentation: WorkoutMirrorPresentationV1
    var supportsSegmentMarking = true
    var isSegmentConfirmationPending = false

    init(_ presentation: WorkoutMirrorPresentationV1) {
        self.presentation = presentation
    }
}
