import Foundation

/// BikeComputer's watchOS 10-compatible heart-rate zone model.
///
/// These zones are intentionally app-defined rather than presented as Apple's
/// system workout zones. Apple does not expose its personalized live zone data
/// to this project's current watchOS SDK.
nonisolated struct WorkoutHeartRateZoneProfile: Equatable, Sendable {
    static let zoneCount: UInt8 = 5
    static let defaultMaximumHeartRateBPM = 190
    static let supportedMaximumHeartRateBPM = 100...240

    let maximumHeartRateBPM: Int

    init(maximumHeartRateBPM: Int) {
        self.maximumHeartRateBPM = Self.clampedMaximumHeartRateBPM(
            maximumHeartRateBPM
        )
    }

    static func clampedMaximumHeartRateBPM(_ value: Int) -> Int {
        min(
            max(value, supportedMaximumHeartRateBPM.lowerBound),
            supportedMaximumHeartRateBPM.upperBound
        )
    }

    /// Maps a live heart rate into five continuous intensity bands:
    /// below 60%, 60-70%, 70-80%, 80-90%, and 90%+ of configured max HR.
    func zone(for heartRateBPM: Double?) -> UInt8? {
        guard let heartRateBPM,
              heartRateBPM.isFinite,
              heartRateBPM > 0 else {
            return nil
        }

        switch heartRateBPM / Double(maximumHeartRateBPM) {
        case ..<0.60: return 1
        case ..<0.70: return 2
        case ..<0.80: return 3
        case ..<0.90: return 4
        default: return 5
        }
    }
}

/// Accumulates workout elapsed time by heart-rate zone for the iPhone UI.
/// Using the workout's elapsed metric keeps the value frozen while paused.
nonisolated struct WorkoutHeartRateZoneDurationAccumulator: Sendable {
    struct Checkpoint: Codable, Equatable, Sendable {
        let previousElapsedTime: TimeInterval?
        let previousZone: UInt8?
        let secondsByZone: [TimeInterval]

        var isValid: Bool {
            previousElapsedTime.map { $0.isFinite && $0 >= 0 } ?? true
                && previousZone.map {
                    $0 > 0
                        && $0 <= WorkoutHeartRateZoneProfile.zoneCount
                } ?? true
                && secondsByZone.count
                    == Int(WorkoutHeartRateZoneProfile.zoneCount)
                && secondsByZone.allSatisfy { $0.isFinite && $0 >= 0 }
                && previousElapsedTime.map {
                    secondsByZone.reduce(0, +) <= $0 + 0.001
                } ?? true
        }
    }

    private var sessionID: UUID?
    private var previousElapsedTime: TimeInterval?
    private var previousZone: UInt8?
    private var hasObservedZone = false
    private var secondsByZone = Array(
        repeating: TimeInterval.zero,
        count: Int(WorkoutHeartRateZoneProfile.zoneCount)
    )

    mutating func update(
        sessionID newSessionID: UUID?,
        elapsedTime: TimeInterval?,
        currentZone: UInt8?,
        authoritativeDurations: WorkoutZoneDurationsV1? = nil
    ) -> TimeInterval? {
        guard let newSessionID else {
            reset()
            return nil
        }

        if sessionID != newSessionID {
            reset()
            sessionID = newSessionID
        }

        let validElapsedTime = elapsedTime.flatMap { value in
            value.isFinite && value >= 0 ? value : nil
        }
        let validCurrentZone = Self.validZone(currentZone)
        if validCurrentZone != nil {
            hasObservedZone = true
        }

        if let authoritativeDurations,
           authoritativeDurations.secondsByZone.count
                == Int(WorkoutHeartRateZoneProfile.zoneCount),
           authoritativeDurations.secondsByZone.allSatisfy({
               $0.isFinite && $0 >= 0
           }) {
            secondsByZone = zip(
                secondsByZone,
                authoritativeDurations.secondsByZone
            ).map(max)
        } else if let previousElapsedTime,
                  let validElapsedTime,
                  validElapsedTime >= previousElapsedTime,
                  let previousZone {
            secondsByZone[Int(previousZone - 1)] +=
                validElapsedTime - previousElapsedTime
        }

        let canAdvanceCursor = validElapsedTime.map { elapsedTime in
            previousElapsedTime.map { elapsedTime >= $0 } ?? true
        } ?? true
        if canAdvanceCursor {
            previousElapsedTime = validElapsedTime ?? previousElapsedTime
            previousZone = validCurrentZone
        }

        guard let validCurrentZone else { return nil }
        return secondsByZone[Int(validCurrentZone - 1)]
    }

    func authoritativeDurations(
        capturedAt: Date
    ) -> WorkoutZoneDurationsV1? {
        guard sessionID != nil, hasObservedZone else { return nil }
        return WorkoutZoneDurationsV1(
            capturedAt: capturedAt,
            secondsByZone: secondsByZone
        )
    }

    var checkpoint: Checkpoint? {
        guard sessionID != nil, hasObservedZone else { return nil }
        return Checkpoint(
            previousElapsedTime: previousElapsedTime,
            previousZone: previousZone,
            secondsByZone: secondsByZone
        )
    }

    mutating func restore(
        sessionID: UUID,
        checkpoint: Checkpoint?
    ) {
        reset()
        guard let checkpoint, checkpoint.isValid else { return }
        self.sessionID = sessionID
        previousElapsedTime = checkpoint.previousElapsedTime
        previousZone = checkpoint.previousZone
        secondsByZone = checkpoint.secondsByZone
        hasObservedZone = true
    }

    mutating func reset() {
        sessionID = nil
        previousElapsedTime = nil
        previousZone = nil
        hasObservedZone = false
        secondsByZone = Array(
            repeating: .zero,
            count: Int(WorkoutHeartRateZoneProfile.zoneCount)
        )
    }

    private static func validZone(_ zone: UInt8?) -> UInt8? {
        guard let zone,
              zone > 0,
              zone <= WorkoutHeartRateZoneProfile.zoneCount else {
            return nil
        }
        return zone
    }
}

/// Coalesces recovery writes when heart rate oscillates around a zone boundary.
/// A pending transition is retained until a durable write succeeds.
nonisolated struct WorkoutHeartRateZoneCheckpointPersistenceGate: Sendable {
    static let minimumAttemptInterval: TimeInterval = 15

    private(set) var hasPendingTransition = false
    private var lastAttemptAt: Date?

    mutating func observeTransition(
        from previous: WorkoutHeartRateZoneDurationAccumulator.Checkpoint?,
        to current: WorkoutHeartRateZoneDurationAccumulator.Checkpoint?
    ) {
        if previous?.previousZone != current?.previousZone {
            hasPendingTransition = true
        }
    }

    mutating func shouldAttempt(at date: Date) -> Bool {
        guard hasPendingTransition,
              date.timeIntervalSinceReferenceDate.isFinite else {
            return false
        }
        if let lastAttemptAt,
           date.timeIntervalSince(lastAttemptAt)
                < Self.minimumAttemptInterval {
            return false
        }
        lastAttemptAt = date
        return true
    }

    mutating func markSucceeded() {
        hasPendingTransition = false
    }

    mutating func reset() {
        hasPendingTransition = false
        lastAttemptAt = nil
    }
}

nonisolated enum WorkoutHeartRateZoneSettings {
    static let maximumHeartRateBPMKey =
        "BikeComputer.workout.maximumHeartRateBPM"

    static func maximumHeartRateBPM(
        from defaults: UserDefaults = .standard
    ) -> Int {
        guard defaults.object(forKey: maximumHeartRateBPMKey) != nil else {
            return WorkoutHeartRateZoneProfile.defaultMaximumHeartRateBPM
        }
        return WorkoutHeartRateZoneProfile.clampedMaximumHeartRateBPM(
            defaults.integer(forKey: maximumHeartRateBPMKey)
        )
    }

    static func saveMaximumHeartRateBPM(
        _ value: Int,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(
            WorkoutHeartRateZoneProfile.clampedMaximumHeartRateBPM(value),
            forKey: maximumHeartRateBPMKey
        )
    }
}

nonisolated enum WorkoutHeartRateZoneSyncContext {
    static let maximumHeartRateBPMKey =
        "BikeComputer.workout.maximumHeartRateBPM.v1"

    static func applicationContext(
        maximumHeartRateBPM: Int
    ) -> [String: Any] {
        [
            maximumHeartRateBPMKey:
                WorkoutHeartRateZoneProfile.clampedMaximumHeartRateBPM(
                    maximumHeartRateBPM
                )
        ]
    }

    static func maximumHeartRateBPM(
        from applicationContext: [String: Any]
    ) -> Int? {
        guard let value = applicationContext[maximumHeartRateBPMKey] as? Int
        else {
            return nil
        }
        return WorkoutHeartRateZoneProfile.clampedMaximumHeartRateBPM(value)
    }
}
