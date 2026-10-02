import Foundation

/// An OS-independent sidecar to the unchanged legacy workout frames. iOS 26
/// and watchOS 26 use the same transport with an explicitly Bicino-owned HR
/// configuration. Only the Watch's HealthKit adapter supplies native groups.
nonisolated struct WorkoutZoneDeviceContextV1: Equatable, Sendable {
    let snapshot: WorkoutSnapshotV1
    let sessionID: UUID
    let sessionToken: UInt16
    let state: WorkoutDeviceSessionState
    let isCurrent: Bool
}

/// Each metric packet is self-contained: identity, exact configuration, current
/// ordinal, source age and accumulated durations are applied together. There is
/// deliberately no persistent configuration cache or hash whose loss/collision
/// could make a current ordinal refer to yesterday's thresholds.
nonisolated enum WorkoutZoneDeviceCodecV1 {
    static let frameKind = UInt8(WorkoutZoneWireV1.frameKind)
    static let headerBytes = WorkoutZoneWireV1.headerBytes
    static let maximumFrameBytes = WorkoutZoneWireV1.maximumFrameBytes

    static func packets(
        for context: WorkoutZoneDeviceContextV1?, sequence: UInt32,
        pairGeneration: UInt8 = 0, at now: Date
    ) -> [Data] {
        guard let context, sequence != 0, context.sessionToken != 0,
              context.state != .idle,
              context.sessionID.uuidString != "00000000-0000-0000-0000-000000000000",
              now.timeIntervalSinceReferenceDate.isFinite else { return [] }
        return [WorkoutNativeZoneMetricV1.heartRate, .cyclingPower].map {
            packet(metric: $0, context: context, sequence: sequence, pairGeneration: pairGeneration, at: now)
        }
    }

    private static func packet(
        metric: WorkoutNativeZoneMetricV1, context: WorkoutZoneDeviceContextV1,
        sequence: UInt32, pairGeneration: UInt8, at now: Date
    ) -> Data {
        let snapshot = context.snapshot
        let isHeart = metric == .heartRate
        let native = isHeart ? snapshot.nativeZones?.heartRate : snapshot.nativeZones?.cyclingPower
        let raw = isHeart ? snapshot.currentHeartRate : snapshot.cyclingPower
        var ranges: [WorkoutNativeZoneRangeV1] = []
        var durations: [Double]?
        var source = UInt8(WorkoutZoneWireV1.sourceBicino)
        var current: UInt8 = 0
        var final = false

        let canPresent = context.isCurrent && context.state != .ending
            && context.state != .failed && snapshot.terminalOutcome != .discarded
            && WorkoutDeviceSessionState(snapshot.state) == context.state
            && (context.state != .ended || snapshot.terminalOutcome == .saved)
        if canPresent, let native, native.isValid,
           native.configuration.metric == metric,
           native.isFinal == (context.state == .ended),
           native.observedAt >= (snapshot.startDate ?? .distantFuture),
           native.observedAt <= now {
            ranges = native.configuration.ranges
            durations = native.secondsByZone
            source = sourceByte(native.configuration.source)
            final = native.isFinal
            // A transition is not a heartbeat. Freshness comes from the raw
            // measurement and is rechecked when enqueueing, not from the fact
            // that a previously encoded frame is being resent.
            if context.state == .running, !final,
               now.timeIntervalSince(native.observedAt) < Double(WorkoutZoneWireV1.streamMaximumAgeMs) / 1000,
               let ordinal = native.currentZone, let raw,
               raw.unit == metric.unit, raw.value.isFinite,
               raw.value >= 0, !isHeart || raw.value > 0,
               raw.capturedAt >= (native.currentZoneSampleAt ?? .distantFuture),
               ranges[Int(ordinal) - 1].mayContain(raw.value) {
                current = ordinal
            }
        } else if canPresent, native == nil, isHeart,
                  let legacy = snapshot.heartRateZoneDurations,
                  let maximum = legacy.maximumHeartRateBPM,
                  WorkoutHeartRateZoneProfile.supportedMaximumHeartRateBPM.contains(maximum) {
            // Reuse the established model, including its exact (unrounded)
            // percentage thresholds; never invent FTP or a power-zone fallback.
            let thresholds = [0.60, 0.70, 0.80, 0.90].map { Double(maximum) * $0 }
            ranges = (0..<5).map { index in
                WorkoutNativeZoneRangeV1(
                    minimum: index == 0 ? nil : thresholds[index - 1],
                    maximum: index == 4 ? nil : thresholds[index]
                )
            }
            if legacy.secondsByZone.count == 5 { durations = legacy.secondsByZone }
            final = context.state == .ended && snapshot.terminalOutcome == .saved
            if context.state == .running, let raw,
               raw.unit == .beatsPerMinute, raw.value.isFinite, raw.value > 0 {
                current = WorkoutHeartRateZoneProfile(maximumHeartRateBPM: maximum)
                    .zone(for: raw.value) ?? 0
            }
        }

        let ageLimit = isHeart ? WorkoutZoneWireV1.heartRateMaximumAgeMs : WorkoutZoneWireV1.powerMaximumAgeMs
        var age: UInt16 = .max
        if current != 0, let raw {
            let milliseconds = (now.timeIntervalSince(raw.capturedAt) * 1000).rounded(.up)
            if milliseconds.isFinite, milliseconds >= 0, milliseconds < Double(ageLimit),
               raw.capturedAt >= (snapshot.startDate ?? .distantFuture) {
                age = UInt16(milliseconds)
            } else {
                current = 0
            }
        } else {
            current = 0
        }

        let encodedDurations: [UInt32]?
        if let durations, durations.count == ranges.count,
           snapshot.elapsedTime?.unit == .seconds,
           snapshot.elapsedTime?.value.isFinite == true,
           durations.allSatisfy({ $0.isFinite && $0 >= 0 && $0 * 1000 < Double(UInt32.max) }),
           durations.reduce(0, +).isFinite,
           durations.reduce(0, +) <= (snapshot.elapsedTime?.value ?? -1) + 1 {
            encodedDurations = durations.map { UInt32(($0 * 1000).rounded(.down)) }
        } else {
            encodedDurations = nil
        }
        if final && encodedDurations == nil { ranges = []; final = false; current = 0; age = .max }
        if ranges.isEmpty { current = 0; age = .max; final = false }
        var flags: UInt8 = 0
        if final { flags |= UInt8(WorkoutZoneWireV1.flagFinal) }
        if ranges.first?.minimum == 0 { flags |= UInt8(WorkoutZoneWireV1.flagLowerBoundZero) }
        if encodedDurations != nil && !ranges.isEmpty { flags |= UInt8(WorkoutZoneWireV1.flagDurations) }
        var data = Data([frameKind, UInt8(WorkoutZoneWireV1.version),
                         UInt8(isHeart ? WorkoutZoneWireV1.metricHeartRate : WorkoutZoneWireV1.metricCyclingPower),
                         source, flags, UInt8(ranges.count), current, context.state.rawValue | ((pairGeneration & 3) << 6)])
        data.zoneAppend(context.sessionToken, bytes: 2)
        data.zoneAppend(age, bytes: 2)
        data.zoneAppend(sequence, bytes: 4)
        var uuid = context.sessionID.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
        for range in ranges.dropLast() { data.zoneAppend(range.maximum!.bitPattern, bytes: 8) }
        for index in ranges.indices {
            data.zoneAppend(encodedDurations?[index] ?? UInt32.max, bytes: 4)
        }
        return data
    }

    private static func sourceByte(_ source: WorkoutNativeZoneSourceV1) -> UInt8 {
        switch source {
        case .system: UInt8(WorkoutZoneWireV1.sourceHealthkitSystem)
        case .user: UInt8(WorkoutZoneWireV1.sourceHealthkitUser)
        case .app: UInt8(WorkoutZoneWireV1.sourceHealthkitApp)
        case .unknown: UInt8(WorkoutZoneWireV1.sourceHealthkitUnknown)
        }
    }

    /// Cheap bounded shape check before admitting a sidecar to the write queue.
    /// Semantic validation lives at both the snapshot and firmware boundaries.
    static func hasValidShape(_ data: Data) -> Bool {
        guard data.count >= headerBytes, data.first == frameKind,
              data[1] == UInt8(WorkoutZoneWireV1.version), (1...2).contains(data[2]),
              data[3] <= UInt8(WorkoutZoneWireV1.sourceHealthkitUnknown), data[4] & 0xF8 == 0 else { return false }
        let count = Int(data[5])
        guard count == 0 || (WorkoutZoneWireV1.minimumZones...WorkoutZoneWireV1.maximumZones).contains(count),
              data[6] <= data[5] else { return false }
        return data.count == headerBytes + max(0, count - 1) * 8 + count * 4
    }
}

private extension Data {
    nonisolated mutating func zoneAppend<T: FixedWidthInteger>(_ value: T, bytes: Int) {
        for index in 0..<bytes { append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
    }
}
