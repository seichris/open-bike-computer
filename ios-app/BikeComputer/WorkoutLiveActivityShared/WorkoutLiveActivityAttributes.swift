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
    case endAndSave
    case discard
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
    case finalSummaryUnavailable
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
        let elapsedActiveSeconds: TimeInterval?
        let currentSpeedKilometersPerHour: Double?
        let cyclingDistanceMeters: Double?
        let currentHeartRateBPM: Double?
        let lastCompletedSegmentIndex: UInt32?
        let lastCompletedSegmentDuration: TimeInterval?
        let lastCompletedSegmentDistanceMeters: Double?
        let isSegmentControlAvailable: Bool
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
            phase == .running
                && pendingAction == .none
                && displayError != .controlsUnavailable
        }

        var canMarkSegment: Bool {
            controlsEnabled
                && isSegmentControlAvailable
                && displayError != .segmentUnconfirmed
        }

        var canPause: Bool {
            controlsEnabled
        }

        var canResume: Bool {
            phase == .paused
                && pendingAction == .none
                && displayError != .controlsUnavailable
        }

        var segmentControlTitle: String {
            pendingAction == .segment ? "Marking…" : "Segment"
        }

        var pauseControlTitle: String {
            switch pendingAction {
            case .pause:
                return "Pausing…"
            case .resume:
                return "Resuming…"
            default:
                return phase == .paused ? "Resume" : "Pause"
            }
        }

        var pauseControlSystemImage: String {
            switch pendingAction {
            case .pause, .resume:
                return "hourglass"
            default:
                return phase == .paused ? "play.fill" : "pause.fill"
            }
        }

        var isTerminal: Bool {
            phase == .final
        }

        func displayState(isSystemStale: Bool) -> Self {
            guard isSystemStale,
                  phase == .running || phase == .paused else {
                return self
            }
            return Self(
                phase: .stale,
                capturedAt: capturedAt,
                elapsedActiveSeconds: elapsedActiveSeconds,
                currentSpeedKilometersPerHour: nil,
                cyclingDistanceMeters: cyclingDistanceMeters,
                currentHeartRateBPM: nil,
                lastCompletedSegmentIndex: lastCompletedSegmentIndex,
                lastCompletedSegmentDuration:
                    lastCompletedSegmentDuration,
                lastCompletedSegmentDistanceMeters:
                    lastCompletedSegmentDistanceMeters,
                isSegmentControlAvailable: isSegmentControlAvailable,
                pendingAction: pendingAction,
                finalOutcome: finalOutcome,
                displayError: .controlsUnavailable
            )
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
