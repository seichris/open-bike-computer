import ActivityKit
import Foundation

@available(iOS 17.0, *)
nonisolated enum WorkoutLiveActivityPhase: String, Codable, Hashable, Sendable {
    case running
    case paused
    case stale
    case disconnected
    case ending
    case final
}

@available(iOS 17.0, *)
nonisolated enum WorkoutLiveActivityPendingAction:
    String, Codable, Hashable, Sendable {
    case none
    case segment
    case pause
    case resume
}

@available(iOS 17.0, *)
nonisolated enum WorkoutLiveActivityFinalOutcome:
    String, Codable, Hashable, Sendable {
    case none
    case saved
    case discarded
}

@available(iOS 17.0, *)
nonisolated enum WorkoutLiveActivityDisplayError:
    String, Codable, Hashable, Sendable {
    case none
    case segmentRejected
    case segmentUnconfirmed
    case controlsUnavailable
}

@available(iOS 17.0, *)
nonisolated enum WorkoutLiveActivityAction: String, Codable, Hashable, Sendable {
    case segment
    case pause
    case resume
}

@available(iOS 17.0, *)
nonisolated struct WorkoutLiveActivityAttributes:
    ActivityAttributes, Hashable, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        let phase: WorkoutLiveActivityPhase
        let capturedAt: Date
        let elapsedActiveSeconds: TimeInterval
        let currentSpeedKilometersPerHour: Double?
        let cyclingDistanceMeters: Double?
        let currentHeartRateBPM: Double?
        let lastCompletedSegmentIndex: UInt32?
        let lastCompletedSegmentDuration: TimeInterval?
        let lastCompletedSegmentDistanceMeters: Double?
        let pendingAction: WorkoutLiveActivityPendingAction
        let finalOutcome: WorkoutLiveActivityFinalOutcome
        let displayError: WorkoutLiveActivityDisplayError

        var currentSegmentIndex: UInt32 {
            guard let lastCompletedSegmentIndex else { return 1 }
            return lastCompletedSegmentIndex == .max
                ? .max
                : lastCompletedSegmentIndex + 1
        }

        var controlsEnabled: Bool {
            phase == .running && pendingAction == .none
        }

        var canMarkSegment: Bool {
            controlsEnabled
        }

        var canPause: Bool {
            controlsEnabled
        }

        var canResume: Bool {
            phase == .paused && pendingAction == .none
        }

        var isTerminal: Bool {
            phase == .final
        }
    }

    enum ActivityKind: String, Codable, Hashable, Sendable {
        case outdoorCycling
    }

    let sessionID: UUID
    let workoutStartDate: Date
    let activityKind: ActivityKind

    init(
        sessionID: UUID,
        workoutStartDate: Date,
        activityKind: ActivityKind = .outdoorCycling
    ) {
        self.sessionID = sessionID
        self.workoutStartDate = workoutStartDate
        self.activityKind = activityKind
    }
}
