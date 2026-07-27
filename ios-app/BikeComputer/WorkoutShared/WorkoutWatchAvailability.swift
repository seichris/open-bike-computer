import Foundation

nonisolated enum WorkoutWatchAvailabilityV1: Equatable, Sendable {
    case activating
    case unsupported
    case activationFailed
    case noPairedWatch
    case companionAppNotInstalled
    case ready(isReachable: Bool)
}

nonisolated enum WorkoutWatchAvailabilityPolicyV1 {
    static func resolve(
        isSupported: Bool,
        isActivated: Bool,
        activationFailed: Bool = false,
        isPaired: Bool,
        isCompanionAppInstalled: Bool,
        isReachable: Bool
    ) -> WorkoutWatchAvailabilityV1 {
        guard isSupported else { return .unsupported }
        guard !activationFailed else { return .activationFailed }
        guard isActivated else { return .activating }
        guard isPaired else { return .noPairedWatch }
        guard isCompanionAppInstalled else {
            return .companionAppNotInstalled
        }
        return .ready(isReachable: isReachable)
    }
}

nonisolated enum WorkoutStartAvailabilityDecisionV1: Equatable, Sendable {
    case waitForActivation
    case attemptHealthKitLaunch
    case unsupported
    case activationFailed
    case noPairedWatch
}

/// Decides whether an iPhone start request should reach HealthKit.
///
/// WatchConnectivity installation state is advisory here. Its companion-app
/// catalogue can lag the actual Watch installation, while HealthKit's Watch
/// launch API provides the authoritative success or failure result.
nonisolated enum WorkoutStartAvailabilityPolicyV1 {
    static func resolve(
        _ availability: WorkoutWatchAvailabilityV1
    ) -> WorkoutStartAvailabilityDecisionV1 {
        switch availability {
        case .activating:
            return .waitForActivation
        case .ready, .companionAppNotInstalled:
            return .attemptHealthKitLaunch
        case .unsupported:
            return .unsupported
        case .activationFailed:
            return .activationFailed
        case .noPairedWatch:
            return .noPairedWatch
        }
    }
}
