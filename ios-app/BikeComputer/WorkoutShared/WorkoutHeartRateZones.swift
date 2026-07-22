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
