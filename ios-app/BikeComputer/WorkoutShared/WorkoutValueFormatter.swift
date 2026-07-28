import Foundation

nonisolated enum WorkoutValueFormatter {
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--:--" }
        // Keep the conversion defined even for corrupted-but-finite payloads.
        // Int32.max seconds is already more than 68 years of elapsed time.
        let total = Int(min(seconds.rounded(.down), Double(Int32.max)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    static func heartRate(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "--" }
        return String(format: "%.0f", value)
    }

    static func whole(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "--" }
        return String(format: "%.0f", value)
    }

    static func speed(_ metersPerSecond: Double?) -> String {
        guard let metersPerSecond,
              metersPerSecond.isFinite,
              metersPerSecond >= 0 else {
            return "--"
        }
        return String(format: "%.1f", metersPerSecond * 3.6)
    }

    static func averageSpeed(
        distanceMeters: Double?,
        elapsedSeconds: Double?
    ) -> String {
        guard let distanceMeters,
              distanceMeters.isFinite,
              distanceMeters >= 0,
              let elapsedSeconds,
              elapsedSeconds.isFinite,
              elapsedSeconds > 0 else {
            return "--"
        }
        return speed(distanceMeters / elapsedSeconds)
    }

    static func energy(_ kilocalories: Double?) -> String {
        guard let kilocalories,
              kilocalories.isFinite,
              kilocalories >= 0 else {
            return "--"
        }
        return String(format: "%.0f", kilocalories)
    }

    static func distance(_ meters: Double?) -> String {
        guard let meters, meters.isFinite, meters >= 0 else { return "--" }
        if meters >= 1_000 {
            return String(format: "%.2f", meters / 1_000)
        }
        return String(format: "%.0f", meters)
    }

    static func distanceUnit(_ meters: Double?) -> String {
        guard let meters, meters.isFinite, meters >= 1_000 else { return "M" }
        return "KM"
    }
}
