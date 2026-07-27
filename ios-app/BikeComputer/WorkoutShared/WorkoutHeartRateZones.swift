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
    private var sessionID: UUID?
    private var previousElapsedTime: TimeInterval?
    private var previousZone: UInt8?
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

        if let authoritativeDurations,
           authoritativeDurations.secondsByZone.count
                == Int(WorkoutHeartRateZoneProfile.zoneCount),
           authoritativeDurations.secondsByZone.allSatisfy({
               $0.isFinite && $0 >= 0
           }) {
            secondsByZone = authoritativeDurations.secondsByZone
        } else if let previousElapsedTime,
                  let validElapsedTime,
                  validElapsedTime >= previousElapsedTime,
                  let previousZone {
            secondsByZone[Int(previousZone - 1)] +=
                validElapsedTime - previousElapsedTime
        }

        previousElapsedTime = validElapsedTime ?? previousElapsedTime
        previousZone = validCurrentZone

        guard let validCurrentZone else { return nil }
        return secondsByZone[Int(validCurrentZone - 1)]
    }

    mutating func reset() {
        sessionID = nil
        previousElapsedTime = nil
        previousZone = nil
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
