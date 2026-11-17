import Foundation

/// Segment boundaries stay in HealthKit metadata. HealthKit accepts strings,
/// not arbitrary binary Data, as metadata values.
nonisolated enum WorkoutRecordingMetadataCodec {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        let data: Data
        if let text = value as? String { data = Data(text.utf8) }
        else if let legacy = value as? Data { data = legacy }
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

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

/// A native state callback can precede its HealthKit event write. Keep that
/// exact transition recoverable until the builder contains its receipt.
nonisolated struct WorkoutNativeTransitionIntent: Codable, Equatable, Sendable {
    let id: UUID
    let paused: Bool
    let capturedAt: Date
}

/// A Watch-owned ride that the rider explicitly continued on iPhone. Bicino
/// keeps both parts as one ride; HealthKit keeps them as two workouts. Only
/// part boundaries and summary totals are stored here, never Health samples or
/// route coordinates. The time between the parts is an unrecorded gap: no
/// distance is counted across it and no route line joins the two parts.
nonisolated struct WorkoutRideContinuation: Codable, Equatable, Sendable {
    /// Bicino's view of the Watch part. `endedAt` is the capture time of the
    /// latest Watch data counted in this ride; nil while none is known (for
    /// example after a restart while Apple Watch was unreachable).
    struct WatchPart: Codable, Equatable, Sendable {
        let sessionID: UUID
        let requestedAt: Date
        let startedAt: Date
        var endedAt: Date?
        var movingTime: TimeInterval?
        var distanceMeters: Double?
        var activeKilocalories: Double?
        var averageHeartRate: Double?
        var savedInFitness = false
        /// Apple Watch kept recording after iPhone took over. Its Fitness
        /// workout is left intact; Bicino counts it only up to `endedAt`.
        var recordedPastHandoff = false
    }

    /// Late Watch data: a mirrored snapshot or the saved Fitness workout.
    struct WatchEvidence: Equatable, Sendable {
        let capturedAt: Date
        var movingTime: TimeInterval?
        var distanceMeters: Double?
        var activeKilocalories: Double?
        var averageHeartRate: Double?
        var savedInFitness = false
    }

    var schemaVersion = 1
    var watch: WatchPart
    /// When the rider chose Continue on iPhone (iPhone clock).
    let handoffAt: Date

    var isValid: Bool {
        schemaVersion == 1
            && watch.sessionID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            && [watch.requestedAt, watch.startedAt, handoffAt].allSatisfy {
                $0.timeIntervalSinceReferenceDate.isFinite
            }
            && (watch.endedAt.map {
                $0.timeIntervalSinceReferenceDate.isFinite && $0 >= watch.startedAt
            } ?? true)
            && [watch.movingTime, watch.distanceMeters, watch.activeKilocalories].allSatisfy {
                $0.map { $0.isFinite && $0 >= 0 } ?? true
            }
            && (watch.averageHeartRate.map { $0.isFinite && $0 > 0 } ?? true)
    }

    /// Counts late Watch data without double-counting time that iPhone also
    /// recorded. Totals are cumulative, so data captured before iPhone took
    /// over can only extend the Watch part (each total keeps its largest
    /// value). Data captured afterwards overlaps the iPhone part: it is
    /// recorded as overlap and left only in the Watch's own Fitness workout.
    func absorbing(_ evidence: WatchEvidence, phoneStartedAt: Date?) -> Self {
        var next = self
        if evidence.savedInFitness { next.watch.savedInFitness = true }
        guard evidence.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              evidence.capturedAt >= watch.startedAt else { return next }
        // Before the iPhone recorder confirms its start, the rider's choice
        // is the boundary.
        if evidence.capturedAt > (phoneStartedAt ?? handoffAt) {
            next.watch.recordedPastHandoff = true
            return next.isValid ? next : self
        }
        if let endedAt = watch.endedAt, evidence.capturedAt < endedAt { return next }
        func larger(_ value: Double?, _ current: Double?) -> Double? {
            guard let value, value.isFinite, value >= 0 else { return current }
            return max(value, current ?? 0)
        }
        next.watch.endedAt = evidence.capturedAt
        next.watch.movingTime = larger(evidence.movingTime, watch.movingTime)
        next.watch.distanceMeters = larger(evidence.distanceMeters, watch.distanceMeters)
        next.watch.activeKilocalories = larger(evidence.activeKilocalories, watch.activeKilocalories)
        if let heartRate = evidence.averageHeartRate, heartRate.isFinite, heartRate > 0 {
            next.watch.averageHeartRate = heartRate
        }
        return next.isValid ? next : self
    }

    /// The unrecorded interval between the Watch part and the iPhone part.
    /// Nil while either boundary is unknown.
    func gap(phoneStartedAt: Date?) -> DateInterval? {
        guard let endedAt = watch.endedAt, let phoneStartedAt else { return nil }
        // Watch and iPhone clocks can differ slightly; never report negative time.
        return DateInterval(start: min(endedAt, phoneStartedAt), end: phoneStartedAt)
    }
}

/// Watch sessions the rider continued on iPhone. A late reconnect or save of
/// one of these sessions is never adopted as a new Watch-owned ride, so Bicino
/// cannot switch a continued ride back to Apple Watch or count it twice.
nonisolated struct WorkoutHandoffLedger: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let watchSessionID: UUID
        let handedOffAt: Date
    }

    static let capacity = 16
    static let retention: TimeInterval = 14 * 24 * 60 * 60

    var schemaVersion = 1
    private(set) var entries: [Entry] = []

    func contains(_ watchSessionID: UUID) -> Bool {
        entries.contains { $0.watchSessionID == watchSessionID }
    }

    func inserting(_ watchSessionID: UUID, at date: Date) -> Self {
        var next = self
        next.entries.removeAll {
            $0.watchSessionID == watchSessionID
                || date.timeIntervalSince($0.handedOffAt) > Self.retention
        }
        next.entries.append(Entry(watchSessionID: watchSessionID, handedOffAt: date))
        next.entries.sort { $0.handedOffAt < $1.handedOffAt }
        if next.entries.count > Self.capacity {
            next.entries.removeFirst(next.entries.count - Self.capacity)
        }
        return next
    }

    func removing(_ watchSessionID: UUID) -> Self {
        var next = self
        next.entries.removeAll { $0.watchSessionID == watchSessionID }
        return next
    }
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
    var pendingNativeTransitions: [WorkoutNativeTransitionIntent]?
    /// Present only on an iPhone recording that continues a Watch-owned ride.
    var continuation: WorkoutRideContinuation?

    var isValid: Bool {
        schemaVersion == 1
            && (continuation.map {
                owner == .iphone && $0.isValid && $0.watch.sessionID != sessionID
            } ?? true)
            && sessionID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            && requestedAt.timeIntervalSinceReferenceDate.isFinite
            && (startedAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
            && (finishedChoice == nil || (phase == .finished && finishedChoice == finishChoice))
            && (phase != .finished || finishedChoice != nil)
            && (!saveAttempted || finishChoice == .save)
            && (pendingNativeTransitions?.count ?? 0) <= 32
            && Set(pendingNativeTransitions?.map(\.id) ?? []).count == (pendingNativeTransitions?.count ?? 0)
            && (pendingNativeTransitions?.allSatisfy {
                owner == .iphone && $0.id != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
                    && $0.capturedAt.timeIntervalSinceReferenceDate.isFinite
                    && $0.capturedAt >= (startedAt ?? requestedAt)
            } ?? true)
            && (phase != .finished || pendingNativeTransitions?.isEmpty != false)
    }

    func addingNativeTransition(_ intent: WorkoutNativeTransitionIntent) -> Self? {
        guard owner == .iphone, phase != .finished, finishChoice == nil else { return nil }
        var next = self
        var pending = pendingNativeTransitions ?? []
        if !pending.contains(where: { $0.paused == intent.paused && $0.capturedAt == intent.capturedAt }) {
            guard pending.count < 32 else { return nil }
            pending.append(intent)
        }
        next.pendingNativeTransitions = pending.sorted { $0.capturedAt < $1.capturedAt }
        return next.isValid ? next : nil
    }

    /// Persist the returned value BEFORE stopping or finalizing HealthKit.
    /// Once accepted, a Save can never become Discard (or vice versa).
    func finishing(_ choice: WorkoutRecordingDisposition) -> Self? {
        guard isValid, phase != .finished,
              finishChoice == nil || finishChoice == choice,
              choice != .save || pendingNativeTransitions?.isEmpty != false else { return nil }
        var next = self
        if choice == .discard { next.pendingNativeTransitions = nil }
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

    /// Final check after Health authorization, immediately before iPhone
    /// creates its session. An active Watch workout normally blocks it; only
    /// an explicit Continue on iPhone may start beside the session it
    /// continues. After a restart HealthKit can report that session before
    /// any snapshot identifies it; that unidentified session is admitted, and
    /// the coordinator reports a conflict if it later proves to be another.
    static func phoneMayStart(
        _ record: WorkoutRecordingRecord,
        watchSessionID: UUID?,
        watchWorkoutBusy: Bool
    ) -> Bool {
        guard watchWorkoutBusy else { return true }
        guard let continued = record.continuation?.watch.sessionID else { return false }
        return watchSessionID == nil || continued == watchSessionID
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
