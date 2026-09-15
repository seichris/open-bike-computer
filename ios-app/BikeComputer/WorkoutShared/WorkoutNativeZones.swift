import Foundation

/// Additive phone/Watch data. Never encode these ordinals into the legacy
/// five-band WEXT payload: native heart-rate and power configurations may differ.
nonisolated enum WorkoutNativeZoneMetricV1: String, Codable, Sendable {
    case heartRate
    case cyclingPower

    var unit: WorkoutMetricUnitV1 {
        self == .heartRate ? .beatsPerMinute : .watts
    }

    var title: String { self == .heartRate ? "Heart-rate zones" : "Power zones" }
    var unitLabel: String { self == .heartRate ? "BPM" : "W" }
}

nonisolated enum WorkoutNativeZoneSourceV1: String, Codable, Sendable {
    case system, user, app, unknown

    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    var label: String {
        switch self {
        case .system: "Apple Health · automatic"
        case .user: "Apple Health · user configured"
        case .app: "HealthKit · app configured"
        case .unknown: "Apple Health"
        }
    }
}

nonisolated struct WorkoutNativeZoneRangeV1: Codable, Equatable, Sendable {
    /// Exact thresholds in BPM or watts, as identified by the configuration.
    /// nil is unbounded. These are not rounded display-bin endpoints.
    let minimum: Double?
    let maximum: Double?

    /// A consistency check, NOT a classifier. At a shared boundary we defer to
    /// HealthKit's reported index instead of inventing an inclusion convention.
    func mayContain(_ value: Double) -> Bool {
        (minimum.map { value >= $0 } ?? true)
            && (maximum.map { value <= $0 } ?? true)
    }

    var label: String {
        let lower = minimum.map { String($0) } ?? "−∞"
        let upper = maximum.map { String($0) } ?? "+∞"
        return "\(lower) … \(upper)"
    }
}

nonisolated struct WorkoutNativeZoneConfigurationV1: Codable, Equatable, Sendable {
    let metric: WorkoutNativeZoneMetricV1
    let source: WorkoutNativeZoneSourceV1
    let ranges: [WorkoutNativeZoneRangeV1]

    var isValid: Bool {
        guard (3...9).contains(ranges.count),
              ranges.first?.minimum == nil || ranges.first?.minimum == 0,
              ranges.last?.maximum == nil else { return false }
        for (index, range) in ranges.enumerated() {
            if let minimum = range.minimum, !minimum.isFinite || minimum < 0 { return false }
            if let maximum = range.maximum, !maximum.isFinite || maximum < 0 { return false }
            if index > 0, range.minimum == nil { return false }
            if index < ranges.count - 1, range.maximum == nil { return false }
            if let lower = range.minimum, let upper = range.maximum, lower >= upper { return false }
            if index > 0, ranges[index - 1].maximum != range.minimum { return false }
        }
        // A zero upper boundary would create an empty first physiological zone.
        return (ranges.first?.maximum ?? 0) > 0
    }
}

nonisolated struct WorkoutNativeZoneSnapshotV1: Codable, Equatable, Sendable {
    let configuration: WorkoutNativeZoneConfigurationV1
    let secondsByZone: [TimeInterval]
    /// When this native group was read. It does NOT refresh sensor freshness.
    let observedAt: Date
    /// One-based display ordinal, converted exactly once from HealthKit's index.
    let currentZone: UInt8?
    /// The native transition sample time, not a heartbeat. May remain unchanged
    /// while new, fresh samples continue in the same zone.
    let currentZoneSampleAt: Date?
    /// Only true for data read from the successfully saved HKWorkout.
    let isFinal: Bool

    var isValid: Bool {
        guard configuration.isValid,
              observedAt.timeIntervalSinceReferenceDate.isFinite,
              secondsByZone.count == configuration.ranges.count,
              secondsByZone.allSatisfy({ $0.isFinite && $0 >= 0 }),
              secondsByZone.reduce(0, +).isFinite,
              (currentZone == nil) == (currentZoneSampleAt == nil),
              !isFinal || currentZone == nil else { return false }
        if let zone = currentZone,
           !(1...configuration.ranges.count).contains(Int(zone)) { return false }
        if let sampleAt = currentZoneSampleAt,
           !sampleAt.timeIntervalSinceReferenceDate.isFinite || sampleAt > observedAt { return false }
        return true
    }

    func clearingCurrentZone() -> Self {
        Self(configuration: configuration, secondsByZone: secondsByZone,
             observedAt: observedAt, currentZone: nil, currentZoneSampleAt: nil,
             isFinal: isFinal)
    }
}

nonisolated struct WorkoutNativeZonesV1: Codable, Equatable, Sendable {
    let heartRate: WorkoutNativeZoneSnapshotV1?
    let cyclingPower: WorkoutNativeZoneSnapshotV1?

    var groups: [WorkoutNativeZoneSnapshotV1] { [heartRate, cyclingPower].compactMap { $0 } }

    var isValid: Bool {
        !groups.isEmpty && groups.allSatisfy(\.isValid)
            && (heartRate.map { $0.configuration.metric == .heartRate } ?? true)
            && (cyclingPower.map { $0.configuration.metric == .cyclingPower } ?? true)
    }
}

/// Portable boundary for sparse native transition callbacks. Group durations
/// themselves are read from the builder; no app-side time extrapolation occurs.
nonisolated struct WorkoutNativeZoneEventV1: Equatable, Sendable {
    let configuration: WorkoutNativeZoneConfigurationV1
    let currentZone: UInt8?
    let sampleAt: Date

    static func make(
        configuration: WorkoutNativeZoneConfigurationV1,
        zeroBasedIndex: Int?, sampleAt: Date
    ) -> Self? {
        guard configuration.isValid, sampleAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        if let index = zeroBasedIndex, !configuration.ranges.indices.contains(index) { return nil }
        return Self(configuration: configuration,
                    currentZone: zeroBasedIndex.map { UInt8($0 + 1) }, sampleAt: sampleAt)
    }
}

nonisolated struct WorkoutNativeZoneLiveState: Sendable {
    private var heartRate: WorkoutNativeZoneEventV1?
    private var cyclingPower: WorkoutNativeZoneEventV1?

    mutating func record(_ event: WorkoutNativeZoneEventV1, startDate: Date, now: Date) {
        guard event.configuration.isValid,
              event.sampleAt >= startDate, event.sampleAt <= now else { return }
        let previous = event.configuration.metric == .heartRate ? heartRate : cyclingPower
        // Duplicate or delayed callbacks never replace newer transition state.
        guard previous.map({ event.sampleAt > $0.sampleAt }) ?? true else { return }
        if event.configuration.metric == .heartRate { heartRate = event } else { cyclingPower = event }
    }

    func applyingCurrentZone(
        to group: WorkoutNativeZoneSnapshotV1,
        metric: WorkoutMetricV1?, state: WorkoutSessionStateV1, now: Date
    ) -> WorkoutNativeZoneSnapshotV1 {
        let cleared = group.clearingCurrentZone()
        let event = group.configuration.metric == .heartRate ? heartRate : cyclingPower
        let maximumAge = group.configuration.metric == .heartRate
            ? WorkoutMetricFreshness.heartRateMaximumAge
            : WorkoutMetricFreshness.pairedCyclingSensorMaximumAge
        guard group.isValid, !group.isFinal, state == .running,
              let event, event.configuration == group.configuration,
              let zone = event.currentZone,
              group.configuration.ranges.indices.contains(Int(zone) - 1),
              event.sampleAt <= group.observedAt,
              let metric, metric.unit == group.configuration.metric.unit,
              metric.value.isFinite,
              metric.value >= 0,
              group.configuration.metric != .heartRate || metric.value > 0,
              metric.capturedAt >= event.sampleAt,
              WorkoutMetricFreshness.isFresh(capturedAt: metric.capturedAt, now: now, maximumAge: maximumAge),
              group.configuration.ranges[Int(zone) - 1].mayContain(metric.value) else { return cleared }
        return WorkoutNativeZoneSnapshotV1(
            configuration: group.configuration, secondsByZone: group.secondsByZone,
            observedAt: group.observedAt, currentZone: zone,
            currentZoneSampleAt: event.sampleAt, isFinal: false
        )
    }

    mutating func reset() { heartRate = nil; cyclingPower = nil }
}
