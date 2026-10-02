import Foundation

/// Source age is anchored once, then advances only with the monotonic clock.
/// A wall-clock correction while a sample is queued must not rejuvenate it.
struct RideGPSSampleClock: Equatable, Sendable {
    let initialAge: TimeInterval?
    let receivedUptime: TimeInterval

    init(timestamp: Date?, now: Date = Date(),
         uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        receivedUptime = uptime
        let age = timestamp.map { now.timeIntervalSince($0) }
        initialAge = age.flatMap { $0.isFinite && $0 >= -1 ? max(0, $0) : nil }
    }

    func ageMilliseconds(at uptime: TimeInterval) -> UInt16 {
        guard let initialAge, uptime.isFinite, receivedUptime.isFinite,
              uptime >= receivedUptime else { return .max }
        return UInt16(min(((initialAge + uptime - receivedUptime) * 1000).rounded(.up),
                          Double(UInt16.max - 1)))
    }
}

/// Retained by the source adapter across requeue and reconnect. It is not a
/// transport-session clock. Equal timestamps may represent stationary samples.
struct RideGPSSampleClockCache {
    private var timestamp: Date?
    private var clock: RideGPSSampleClock?

    mutating func sample(_ timestamp: Date?, now: Date = Date(),
                         uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> RideGPSSampleClock {
        if let clock, self.timestamp == timestamp { return clock }
        let clock = RideGPSSampleClock(timestamp: timestamp, now: now, uptime: uptime)
        self.timestamp = timestamp
        self.clock = clock
        return clock
    }
}

/// Shared legacy/quality-v1 field encoding for both controller roles.
/// Authentication, route projection and workout ownership stay in the adapters.
enum RideGPSPacketEncoder {
    static func data(lat: Double, lon: Double, heading: Double?, unixTime: UInt32,
                     speed: Double?, altitude: Double?, distance: Double?,
                     elapsed: Double?, remaining: Double?, accuracy: Double?,
                     sampleAgeMs: UInt16, includeQuality: Bool) -> Data {
        var bytes = Data()
        func append(_ value: UInt64, count: Int) {
            for index in 0..<count { bytes.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        func unsigned(_ value: Double?, scale: Double = 1,
                      maximum: UInt64, unavailable: UInt64) -> UInt64 {
            guard let value, value.isFinite, value >= 0 else { return unavailable }
            return UInt64(min((value * scale).rounded(), Double(maximum)))
        }
        let coordinateValid = lat.isFinite && lon.isFinite &&
            (-90...90).contains(lat) && (-180...180).contains(lon)
        // An invalid source remains an invalid wire coordinate, never a fix at
        // (0,0). The firmware rejects this before changing its retained state.
        append(UInt64(UInt32(bitPattern: coordinateValid ? Int32(lat * 1_000_000) : .max)), count: 4)
        append(UInt64(UInt32(bitPattern: coordinateValid ? Int32(lon * 1_000_000) : .max)), count: 4)
        let course: UInt16 = heading.flatMap {
            guard $0.isFinite, $0 >= 0 else { return nil }
            let normalized = $0.truncatingRemainder(dividingBy: 360)
            return UInt16((normalized < 0 ? normalized + 360 : normalized).rounded()) % 360
        } ?? .max
        append(UInt64(course), count: 2)
        append(UInt64(unixTime), count: 4)
        let speedValue = unsigned(speed, scale: 100, maximum: 65534, unavailable: 65535)
        append(speedValue, count: 2)
        let height = altitude.flatMap { $0.isFinite ? $0 : nil } ?? 0
        append(UInt64(UInt16(bitPattern: Int16(max(-32768, min(32767, height.rounded()))))), count: 2)
        append(unsigned(distance, maximum: 4294967295, unavailable: 0), count: 4)
        append(unsigned(elapsed, maximum: 4294967295, unavailable: 0), count: 4)
        append(unsigned(remaining, maximum: 4294967294, unavailable: 4294967295), count: 4)
        if includeQuality {
            let accuracyValue = unsigned(accuracy, scale: 10, maximum: 65534, unavailable: 65535)
            let valid = coordinateValid && accuracyValue != 65535 && speedValue != 65535 && sampleAgeMs != .max
            append(1, count: 1)
            append((valid ? 1 : 0) | (accuracyValue != 65535 ? 2 : 0), count: 1)
            append(accuracyValue, count: 2)
            append(UInt64(sampleAgeMs), count: 2)
        }
        return bytes
    }

    static func unixTime(_ date: Date) -> UInt32 {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return 0 }
        return UInt32(max(0, min(Double(UInt32.max), seconds)))
    }
}

/// Final plaintext dispatch transform, before encryption, including every retry.
struct RideGPSDispatch: Equatable, Sendable {
    let frame: Data
    let sampleClock: RideGPSSampleClock

    func payload(now: Date = Date(),
                 uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Data {
        guard frame.count == 30 || frame.count == 36 else { return frame }
        var result = frame
        let seconds = RideGPSPacketEncoder.unixTime(now)
        for index in 0..<4 { result[10 + index] = UInt8(truncatingIfNeeded: seconds >> (index * 8)) }
        if result.count == 36, result[30] == 1 {
            let age = sampleClock.ageMilliseconds(at: uptime)
            if age == .max { result[31] &= ~1 }
            result[34] = UInt8(truncatingIfNeeded: age)
            result[35] = UInt8(truncatingIfNeeded: age >> 8)
        }
        return result
    }
}
