import Foundation

nonisolated enum WorkoutDeviceSessionState: UInt8, Equatable, Sendable {
    case idle = 0
    case starting = 1
    case running = 2
    case paused = 3
    case ending = 4
    case ended = 5
    case failed = 6

    init(_ state: WorkoutSessionStateV1) {
        switch state {
        case .idle: self = .idle
        case .starting: self = .starting
        case .running: self = .running
        case .paused: self = .paused
        case .ending: self = .ending
        case .ended: self = .ended
        case .failed: self = .failed
        }
    }
}

nonisolated struct WorkoutDeviceSourceFlags:
    OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let pairedSpeedSensor = Self(rawValue: 1 << 0)
    static let watchSpeed = Self(rawValue: 1 << 1)
    static let healthKitDistance = Self(rawValue: 1 << 2)
    static let watchAltitude = Self(rawValue: 1 << 3)
    static let liveHeartRateZone = Self(rawValue: 1 << 4)
    static let currentSnapshot = Self(rawValue: 1 << 5)
}

nonisolated struct WorkoutDeviceTelemetrySample: Equatable, Sendable {
    let state: WorkoutDeviceSessionState
    let sessionToken: UInt16
    let hasLiveNumerics: Bool
    let isCurrentSnapshot: Bool
    let elapsedSeconds: Double?
    let distanceMeters: Double?
    let speedMetersPerSecond: Double?
    let currentHeartRateBPM: Double?
    let averageHeartRateBPM: Double?
    let activeEnergyKilocalories: Double?
    let cyclingPowerWatts: Double?
    let cyclingCadenceRPM: Double?
    let currentHeartRateZone: UInt8?
    let altitudeMeters: Double?
    let heartRateZoneCount: UInt8?
    let sourceFlags: WorkoutDeviceSourceFlags
}

nonisolated struct WorkoutDeviceFrames: Equatable, Sendable {
    struct Identity: Equatable, Sendable {
        let state: WorkoutDeviceSessionState
        let sessionToken: UInt16
        let hasLiveNumerics: Bool
        let isCurrentSnapshot: Bool
    }

    let core: Data
    let extended: Data
    let identity: Identity
}

nonisolated enum WorkoutDeviceFrameBuilder {
    static let frameLength = 16
    static let unavailableUInt16 = UInt16.max
    static let unavailableUInt32 = UInt32.max
    static let unavailableAltitude = Int16.min
    private static let metricSourceFlagsMask: UInt8 = 0x1F

    static func frames(
        for sample: WorkoutDeviceTelemetrySample
    ) -> WorkoutDeviceFrames? {
        guard (sample.state == .idle && sample.sessionToken == 0)
                || (sample.state != .idle && sample.sessionToken != 0) else {
            return nil
        }

        let numerics = sample.hasLiveNumerics
        var core = Data(capacity: frameLength)
        core.append(1)
        core.append(sample.state.rawValue)
        core.appendUInt16LE(sample.sessionToken)
        core.appendUInt32LE(numerics
            ? encodeUInt32(sample.elapsedSeconds)
            : unavailableUInt32)
        core.appendUInt32LE(numerics
            ? encodeUInt32(sample.distanceMeters)
            : unavailableUInt32)
        core.appendUInt16LE(numerics
            ? encodeUInt16(sample.speedMetersPerSecond, scale: 100)
            : unavailableUInt16)
        core.appendUInt16LE(numerics
            ? encodeUInt16(
                sample.currentHeartRateBPM,
                requiresPositive: true
            )
            : unavailableUInt16)

        let zone = validZone(
            current: numerics ? sample.currentHeartRateZone : nil,
            count: numerics ? sample.heartRateZoneCount : nil
        )
        let altitude = numerics
            ? encodeAltitude(sample.altitudeMeters)
            : unavailableAltitude
        var flags = WorkoutDeviceSourceFlags(
            rawValue: numerics
                ? sample.sourceFlags.rawValue & metricSourceFlagsMask
                : 0
        )
        if encodeUInt16(
            sample.speedMetersPerSecond,
            scale: 100
        ) == unavailableUInt16 {
            flags.subtract([.pairedSpeedSensor, .watchSpeed])
        }
        if encodeUInt32(sample.distanceMeters) == unavailableUInt32 {
            flags.remove(.healthKitDistance)
        }
        if altitude == unavailableAltitude {
            flags.remove(.watchAltitude)
        }
        if zone == nil {
            flags.remove(.liveHeartRateZone)
        }
        if sample.isCurrentSnapshot {
            flags.insert(.currentSnapshot)
        }

        var extended = Data(capacity: frameLength)
        extended.append(2)
        extended.append(flags.rawValue)
        extended.appendUInt16LE(sample.sessionToken)
        extended.appendUInt16LE(numerics
            ? encodeUInt16(
                sample.averageHeartRateBPM,
                requiresPositive: true
            )
            : unavailableUInt16)
        extended.appendUInt16LE(numerics
            ? encodeUInt16(sample.activeEnergyKilocalories, scale: 10)
            : unavailableUInt16)
        extended.appendUInt16LE(numerics
            ? encodeUInt16(sample.cyclingPowerWatts)
            : unavailableUInt16)
        extended.appendUInt16LE(numerics
            ? encodeUInt16(sample.cyclingCadenceRPM, scale: 10)
            : unavailableUInt16)
        extended.append(zone?.current ?? 0)
        extended.appendInt16LE(altitude)
        extended.append(zone?.count ?? 0)

        guard core.count == frameLength, extended.count == frameLength else {
            return nil
        }
        return WorkoutDeviceFrames(
            core: core,
            extended: extended,
            identity: .init(
                state: sample.state,
                sessionToken: sample.sessionToken,
                hasLiveNumerics: sample.hasLiveNumerics,
                isCurrentSnapshot: sample.isCurrentSnapshot
            )
        )
    }

    static func stampedPair(
        core: Data,
        extended: Data,
        generation: UInt8
    ) -> (core: Data, extended: Data) {
        var core = core
        var extended = extended
        guard core.count == frameLength, extended.count == frameLength else {
            return (core, extended)
        }
        let generationBits = (generation & 0x03) << 6
        core[1] = (core[1] & 0x3F) | generationBits
        extended[1] = (extended[1] & 0x3F) | generationBits
        return (core, extended)
    }

    private static func encodeUInt16(
        _ value: Double?,
        scale: Double = 1,
        requiresPositive: Bool = false
    ) -> UInt16 {
        guard let value,
              value.isFinite,
              value >= 0,
              !requiresPositive || value > 0 else {
            return unavailableUInt16
        }
        let scaled = value * scale
        guard scaled.isFinite else { return UInt16.max - 1 }
        return UInt16(min(scaled.rounded(), Double(UInt16.max - 1)))
    }

    private static func encodeUInt32(_ value: Double?) -> UInt32 {
        guard let value, value.isFinite, value >= 0 else {
            return unavailableUInt32
        }
        return UInt32(min(value.rounded(), Double(UInt32.max - 1)))
    }

    private static func encodeAltitude(_ value: Double?) -> Int16 {
        guard let value, value.isFinite else { return unavailableAltitude }
        let lowerBound = Double(Int16.min + 1)
        let upperBound = Double(Int16.max)
        return Int16(min(max(value.rounded(), lowerBound), upperBound))
    }

    private static func validZone(
        current: UInt8?,
        count: UInt8?
    ) -> (current: UInt8, count: UInt8)? {
        guard let current,
              let count,
              current > 0,
              count > 0,
              current <= count else {
            return nil
        }
        return (current, count)
    }
}

private extension Data {
    nonisolated mutating func appendUInt16LE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) {
            append(contentsOf: $0)
        }
    }

    nonisolated mutating func appendUInt32LE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) {
            append(contentsOf: $0)
        }
    }

    nonisolated mutating func appendInt16LE(_ value: Int16) {
        Swift.withUnsafeBytes(of: value.littleEndian) {
            append(contentsOf: $0)
        }
    }
}
