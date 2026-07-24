import Foundation

@available(iOS 17.0, *)
nonisolated enum WorkoutLiveActivityFormatting {
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(min(seconds.rounded(.down), Double(Int32.max)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                remainingSeconds
            )
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    static func speed(_ kilometersPerHour: Double?) -> String {
        guard let kilometersPerHour,
              kilometersPerHour.isFinite,
              kilometersPerHour >= 0 else {
            return "—"
        }
        return String(format: "%.1f", kilometersPerHour)
    }

    static func distance(_ meters: Double?) -> String {
        guard let meters, meters.isFinite, meters >= 0 else { return "—" }
        if meters >= 1_000 {
            return String(format: "%.1f", meters / 1_000)
        }
        return String(format: "%.0f", meters)
    }

    static func distanceUnit(_ meters: Double?) -> String {
        guard let meters, meters.isFinite, meters >= 1_000 else { return "M" }
        return "KM"
    }

    static func heartRate(_ beatsPerMinute: Double?) -> String {
        guard let beatsPerMinute,
              beatsPerMinute.isFinite,
              beatsPerMinute > 0 else {
            return "—"
        }
        return String(format: "%.0f", beatsPerMinute)
    }

    static func segmentSummary(
        index: UInt32?,
        duration: TimeInterval?,
        distanceMeters: Double?
    ) -> String? {
        guard let index else { return nil }
        var parts = ["SEG \(index)"]
        if let duration, duration.isFinite, duration >= 0 {
            parts.append(Self.duration(duration))
        }
        if let distanceMeters,
           distanceMeters.isFinite,
           distanceMeters >= 0 {
            parts.append(
                "\(distance(distanceMeters)) \(distanceUnit(distanceMeters))"
            )
        }
        return parts.joined(separator: " · ")
    }
}
