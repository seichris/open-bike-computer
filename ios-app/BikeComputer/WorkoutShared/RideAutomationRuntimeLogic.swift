import Combine
import Foundation

protocol RideAutomationBLETransport: AnyObject {
    var onRideAutomationFrame: ((RideAutomationFrame) -> Void)? { get set }
    var connectedDeviceID: String? { get }
    var supportsRideAutomation: Bool { get }
    var rideAutomationSupportPublisher: AnyPublisher<Bool, Never> { get }
    var rideAutomationDevicePublisher: AnyPublisher<String?, Never> { get }
    func sendRideAutomationFrame(_ frame: RideAutomationFrame) -> Bool
}

@MainActor
protocol RideAutomationWorkoutControlling: AnyObject {
    var rideAutomationPresentation: WorkoutMirrorPresentationV1 { get }
    var rideAutomationPresentationPublisher:
        AnyPublisher<WorkoutMirrorPresentationV1, Never> { get }
    func startOutdoorCyclingOnWatch() -> Bool
    func requestAutomaticTransition(
        _ transition: RideAutomationTransition,
        context: WorkoutControlContextV1
    ) -> Bool
    func requestAutomaticTransitionConfirmation(
        _ transition: RideAutomationTransition,
        context: WorkoutControlContextV1
    ) -> Bool
    func requestAutomaticStartAnnotation(
        context: WorkoutControlContextV1
    ) -> Bool
}

@MainActor
protocol RideAutomationWatchAvailabilityControlling: AnyObject {
    @discardableResult
    func setPendingAutomaticStartContext(
        _ context: WorkoutControlContextV1?
    ) -> Bool
    func setConfirmedRideDetectionSettings(
        _ settings: RideDetectionSettings?,
        generation: UInt32?
    )
}

nonisolated struct RideAutomationDecisionIdentity:
    Codable, Hashable, Sendable {
    let deviceID: String
    let rideGeneration: UInt32
    let decisionSequence: UInt32
}

nonisolated enum RideAutomationAdmission: Equatable, Sendable {
    case prompt
    case start
    case pause
    case resume
    case reject(RideAutomationResult)
    case duplicate
}

nonisolated enum RideAutomationAdmissionPolicy {
    static func resolve(
        frame: RideAutomationFrame,
        settings: RideDetectionSettings,
        workoutState: WorkoutSessionStateV1,
        pauseOrigin: WorkoutTransitionOrigin?,
        expectedSessionID: UUID?,
        highestDecisionSequence: UInt32
    ) -> RideAutomationAdmission {
        guard frame.kind == .decision,
              frame.origin == .automatic else {
            return .reject(.rejected)
        }
        guard highestDecisionSequence == 0
                || RideAutomationSerialNumber.isNewer(
                    frame.decisionSequence,
                    than: highestDecisionSequence
                ) else {
            return .duplicate
        }
        switch frame.transition {
        case .start:
            guard workoutState == .idle || workoutState == .ended
                    || workoutState == .failed else {
                return .reject(.stale)
            }
            switch settings.startMode {
            case .off: return .reject(.rejected)
            case .ask: return .prompt
            case .automatic: return .start
            }
        case .pause:
            guard settings.autoPauseEnabled else {
                return .reject(.rejected)
            }
            guard workoutState == .running else {
                return .reject(.stale)
            }
            guard let expectedSessionID,
                  frame.sessionID == expectedSessionID else {
                return .reject(.sessionMismatch)
            }
            return .pause
        case .resume:
            guard settings.autoPauseEnabled else {
                return .reject(.rejected)
            }
            guard workoutState == .paused,
                  pauseOrigin == .automatic else {
                return .reject(.stale)
            }
            guard let expectedSessionID,
                  frame.sessionID == expectedSessionID else {
                return .reject(.sessionMismatch)
            }
            return .resume
        case .none:
            return .reject(.rejected)
        }
    }

}

nonisolated enum RideAutomationMonotonicClock {
    static func isExpired(
        sampleSeconds: UInt32,
        latestSeconds: UInt32,
        maximumAgeSeconds: UInt32
    ) -> Bool {
        let age = latestSeconds &- sampleSeconds
        // If the sample is serial-newer than the latest observation, it is a
        // valid clock advance, not a future-dated replay.
        return age < 0x8000_0000 && age > maximumAgeSeconds
    }
}

nonisolated enum RideAutomationRecoveryControlPolicy {
    static func mayReplay(
        _ transition: RideAutomationTransition,
        sessionState: WorkoutSessionStateV1,
        pauseOrigin: WorkoutTransitionOrigin?,
        lastTransitionOrigin: WorkoutTransitionOrigin?
    ) -> Bool {
        switch transition {
        case .pause:
            return sessionState == .running
                || (sessionState == .paused && pauseOrigin == .automatic)
        case .resume:
            return (sessionState == .paused && pauseOrigin == .automatic)
                || (sessionState == .running
                    && lastTransitionOrigin == .automatic)
        case .none, .start:
            return false
        }
    }

    /// A marker from an earlier transition cannot confirm a durable request
    /// that was persisted later. Without this boundary, recovery can mistake
    /// the workout's initial manual start for a pending automatic resume.
    static func markerConfirmsPendingTransition(
        markerAt: Date,
        pendingRequestedAt: Date?
    ) -> Bool {
        guard let pendingRequestedAt else { return true }
        return markerAt >= pendingRequestedAt
    }
}

nonisolated enum RideAutomationStartContextDisposition: Equatable, Sendable {
    case queueForNextStart
    case applyToCurrentSuppliedStart
    case ignore
}

nonisolated enum RideAutomationStartContextPolicy {
    /// WatchConnectivity application context is not ordered with HealthKit's
    /// Watch launch. Bind a late detector identity only while the current
    /// supplied configuration is explicitly awaiting start provenance; never
    /// carry an active-session arrival into the next workout.
    static func disposition(
        sessionState: WorkoutSessionStateV1,
        awaitingSuppliedStartOrigin: Bool,
        hasConfirmedStartOrigin: Bool,
        matchesLastConsumedContext: Bool
    ) -> RideAutomationStartContextDisposition {
        guard !matchesLastConsumedContext else { return .ignore }
        switch sessionState {
        case .idle, .ended, .failed:
            return .queueForNextStart
        case .starting, .running:
            return awaitingSuppliedStartOrigin && !hasConfirmedStartOrigin
                ? .applyToCurrentSuppliedStart
                : .ignore
        case .paused, .ending:
            return .ignore
        }
    }
}
