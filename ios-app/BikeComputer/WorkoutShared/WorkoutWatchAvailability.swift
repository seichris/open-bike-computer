import Foundation

nonisolated enum WorkoutHealthSetupStateV1: String, Codable, Equatable,
    Sendable {
    case checking
    case needsAuthorization
    case ready
    case denied
    case unavailable
    case failed
}

nonisolated enum WorkoutHealthSetupSnapshotErrorV1: Error, Equatable {
    case unsupportedSchema
}

/// A privacy-safe summary of the Watch-owned HealthKit setup state.
nonisolated struct WorkoutHealthSetupSnapshotV1: Codable, Equatable, Sendable {
    static let applicationContextKey = "workoutHealthSetup.v1"
    static let currentSchemaVersion = 1
    static let defaultFreshnessInterval: TimeInterval = 24 * 60 * 60
    static let allowedFutureClockSkew: TimeInterval = 5 * 60

    let schemaVersion: Int
    let state: WorkoutHealthSetupStateV1
    let canWriteWorkoutRoute: Bool
    let updatedAt: Date

    init(
        state: WorkoutHealthSetupStateV1,
        canWriteWorkoutRoute: Bool,
        updatedAt: Date = Date()
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.state = state
        self.canWriteWorkoutRoute = canWriteWorkoutRoute
        self.updatedAt = updatedAt
    }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        let snapshot = try PropertyListDecoder().decode(Self.self, from: data)
        guard snapshot.schemaVersion == currentSchemaVersion else {
            throw WorkoutHealthSetupSnapshotErrorV1.unsupportedSchema
        }
        return snapshot
    }

    func isFresh(
        at now: Date = Date(),
        maximumAge: TimeInterval = Self.defaultFreshnessInterval
    ) -> Bool {
        guard maximumAge >= 0,
              updatedAt <= now.addingTimeInterval(
                Self.allowedFutureClockSkew
              ) else {
            return false
        }
        return now.timeIntervalSince(updatedAt) <= maximumAge
    }
}

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
    case continueSetupOnWatch
    case healthAccessDenied
    case healthUnavailable
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
        _ availability: WorkoutWatchAvailabilityV1,
        healthSetup: WorkoutHealthSetupSnapshotV1?,
        now: Date = Date()
    ) -> WorkoutStartAvailabilityDecisionV1 {
        switch availability {
        case .activating:
            return .waitForActivation
        case .unsupported:
            return .unsupported
        case .activationFailed:
            return .activationFailed
        case .noPairedWatch:
            return .noPairedWatch
        case .ready, .companionAppNotInstalled:
            break
        }

        guard let healthSetup, healthSetup.isFresh(at: now) else {
            return .continueSetupOnWatch
        }
        switch healthSetup.state {
        case .ready:
            return .attemptHealthKitLaunch
        case .denied:
            return .healthAccessDenied
        case .unavailable:
            return .healthUnavailable
        case .checking, .needsAuthorization, .failed:
            return .continueSetupOnWatch
        }
    }
}
