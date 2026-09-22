import Foundation

/// Recording ownership is a per-ride decision, never a connectivity heuristic.
/// This is deliberately not a BLE version change or a Watch recording mode.
nonisolated enum WorkoutRecordingOwner: String, Codable, Sendable {
    case watch
    case iphone

    var displayName: String { self == .watch ? "Apple Watch" : "iPhone" }
}

nonisolated enum WorkoutRecordingDisposition: String, Codable, Sendable {
    case save
    case discard
}

/// Only identity and lifecycle bookkeeping are persisted here. Health samples
/// and route coordinates remain in HealthKit, not UserDefaults or diagnostics.
nonisolated struct WorkoutRecordingRecord: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case starting, running, paused, finishing, unresolved, finished
    }

    var schemaVersion = 1
    var owner: WorkoutRecordingOwner
    var sessionID: UUID
    var requestedAt: Date
    var startedAt: Date?
    var phase: Phase = .starting
    var finishChoice: WorkoutRecordingDisposition?
    var finishedChoice: WorkoutRecordingDisposition?
    // Written before crossing the potentially ambiguous HealthKit save boundary.
    var saveAttempted: Bool = false

    var isValid: Bool {
        schemaVersion == 1
            && sessionID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            && requestedAt.timeIntervalSinceReferenceDate.isFinite
            && (startedAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
            && (finishedChoice == nil || (phase == .finished && finishedChoice == finishChoice))
            && (phase != .finished || finishedChoice != nil)
            && (!saveAttempted || finishChoice == .save)
    }

    /// Persist the returned value BEFORE stopping or finalizing HealthKit.
    /// Once accepted, a Save can never become Discard (or vice versa).
    func finishing(_ choice: WorkoutRecordingDisposition) -> Self? {
        guard isValid, phase != .finished,
              finishChoice == nil || finishChoice == choice else { return nil }
        var next = self
        next.finishChoice = choice
        next.phase = .finishing
        return next
    }

    func finished(_ choice: WorkoutRecordingDisposition) -> Self? {
        guard finishChoice == choice else { return nil }
        var next = self
        next.phase = .finished
        next.finishedChoice = choice
        return next.isValid ? next : nil
    }
}

nonisolated enum WorkoutRecordingStartDecision: Equatable, Sendable {
    case waitForRecovery
    case waitForWatchActivation
    case start(WorkoutRecordingOwner)
    case chooseRecorder
    case blockedByExistingRecording
    case phoneUnsupported
}

nonisolated enum WorkoutRecordingStartPolicy {
    static func resolve(
        recoveryComplete: Bool,
        existingRecording: WorkoutRecordingRecord?,
        watchAvailability: WorkoutWatchAvailabilityV1,
        phoneSupported: Bool,
        explicitOwner: WorkoutRecordingOwner? = nil
    ) -> WorkoutRecordingStartDecision {
        guard recoveryComplete else { return .waitForRecovery }
        // Even an unresolved launch/finish owns the ride until reconciliation.
        // A launch timeout or a lost connection is NOT evidence of no workout.
        guard existingRecording == nil else { return .blockedByExistingRecording }
        if let explicitOwner {
            if explicitOwner == .iphone, !phoneSupported { return .phoneUnsupported }
            return .start(explicitOwner)
        }
        switch watchAvailability {
        case .activating:
            return .waitForWatchActivation
        case .noPairedWatch:
            return phoneSupported ? .start(.iphone) : .phoneUnsupported
        case .ready, .companionAppNotInstalled, .activationFailed:
            // WatchConnectivity's reachability, activation, and companion-app
            // catalogue can all lag the actual Watch installation. HealthKit's
            // Watch launch callback is the authoritative result, so transient
            // WCSession state must not force a recorder-selection sheet.
            return .start(.watch)
        case .unsupported:
            return phoneSupported ? .start(.iphone) : .phoneUnsupported
        }
    }

    static func mayPublish(
        from owner: WorkoutRecordingOwner,
        selectedRecord: WorkoutRecordingRecord?
    ) -> Bool {
        selectedRecord?.owner == owner
    }

    static func mayYieldBikeComputer(record: WorkoutRecordingRecord?) -> Bool {
        guard let record else { return true }
        return record.owner != .iphone || record.phase == .finished
    }
}
