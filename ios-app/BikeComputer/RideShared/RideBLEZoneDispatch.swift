import Foundation

/// Age the immutable admitted packet with a monotonic clock immediately before
/// encryption (also on ACK retries). Expiry clears only the live highlight;
/// definitions and accumulated durations remain valid. No clock/queue delay can
/// rejuvenate a sample. Header offsets are fixed by workout_zones v1.
struct RideBLEZoneDispatch: Equatable, Sendable {
    let frame: Data
    let enqueuedUptime: TimeInterval

    init(frame: Data, enqueuedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.frame = frame
        self.enqueuedUptime = enqueuedUptime
    }

    func payload(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Data {
        typealias Wire = RideBLEGeneratedProtocolV1
        guard frame.count >= Wire.workoutZoneHeaderBytes,
              frame.first == UInt8(Wire.workoutZoneFrameKind),
              frame[Wire.workoutZoneOffsetVersion] == UInt8(Wire.workoutZoneVersion) else { return frame }
        var result = frame
        guard result[6] != 0 else { return result }
        let delay = (uptime - enqueuedUptime) * 1000
        let originalAge = UInt16(frame[10]) | UInt16(frame[11]) << 8
        let age = Double(originalAge) + delay.rounded(.up)
        let limit = Double(frame[Wire.workoutZoneOffsetMetric] == 1
            ? Wire.workoutZoneHeartRateMaximumAgeMs : Wire.workoutZonePowerMaximumAgeMs)
        if !delay.isFinite || delay < 0 || age >= limit || delay >= Double(Wire.workoutZoneStreamMaximumAgeMs) {
            result[6] = 0
            result[10] = 255
            result[11] = 255
        } else {
            result[10] = UInt8(UInt16(age) & 255)
            result[11] = UInt8(UInt16(age) >> 8)
        }
        return result
    }
}
