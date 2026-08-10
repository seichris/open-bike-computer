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
    let pauseOrigin: WorkoutTransitionOrigin?
    let wallElapsedSeconds: Double?
    let sessionID: UUID?
    let detectorProfileVersion: UInt16?
    let lastTransitionOrigin: WorkoutTransitionOrigin?

    init(
        state: WorkoutDeviceSessionState,
        sessionToken: UInt16,
        hasLiveNumerics: Bool,
        isCurrentSnapshot: Bool,
        elapsedSeconds: Double?,
        distanceMeters: Double?,
        speedMetersPerSecond: Double?,
        currentHeartRateBPM: Double?,
        averageHeartRateBPM: Double?,
        activeEnergyKilocalories: Double?,
        cyclingPowerWatts: Double?,
        cyclingCadenceRPM: Double?,
        currentHeartRateZone: UInt8?,
        altitudeMeters: Double?,
        heartRateZoneCount: UInt8?,
        sourceFlags: WorkoutDeviceSourceFlags,
        pauseOrigin: WorkoutTransitionOrigin? = nil,
        wallElapsedSeconds: Double? = nil,
        sessionID: UUID? = nil,
        detectorProfileVersion: UInt16? = nil,
        lastTransitionOrigin: WorkoutTransitionOrigin? = nil
    ) {
        self.state = state
        self.sessionToken = sessionToken
        self.hasLiveNumerics = hasLiveNumerics
        self.isCurrentSnapshot = isCurrentSnapshot
        self.elapsedSeconds = elapsedSeconds
        self.distanceMeters = distanceMeters
        self.speedMetersPerSecond = speedMetersPerSecond
        self.currentHeartRateBPM = currentHeartRateBPM
        self.averageHeartRateBPM = averageHeartRateBPM
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.cyclingPowerWatts = cyclingPowerWatts
        self.cyclingCadenceRPM = cyclingCadenceRPM
        self.currentHeartRateZone = currentHeartRateZone
        self.altitudeMeters = altitudeMeters
        self.heartRateZoneCount = heartRateZoneCount
        self.sourceFlags = sourceFlags
        self.pauseOrigin = pauseOrigin
        self.wallElapsedSeconds = wallElapsedSeconds
        self.sessionID = sessionID
        self.detectorProfileVersion = detectorProfileVersion
        self.lastTransitionOrigin = lastTransitionOrigin
    }
}

nonisolated struct WorkoutDeviceGPSUpdate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let capturedAt: Date
    let horizontalAccuracyMeters: Double
    let courseDegrees: Double?
    let speedMetersPerSecond: Double?
    let altitudeMeters: Double?
    let distanceTraveledMeters: Double?
    let elapsedSeconds: TimeInterval?
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
    let origin: Data
    let originAvailable: Bool
    let identity: Identity
}

nonisolated enum WorkoutDeviceFrameBuilder {
    static let frameLength = 16
    static let originFrameLength = 28
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

        let origin = originFrame(for: sample)
        guard core.count == frameLength, extended.count == frameLength else {
            return nil
        }
        return WorkoutDeviceFrames(
            core: core,
            extended: extended,
            origin: origin ?? Data(),
            originAvailable: origin != nil,
            identity: .init(
                state: sample.state,
                sessionToken: sample.sessionToken,
                hasLiveNumerics: sample.hasLiveNumerics,
                isCurrentSnapshot: sample.isCurrentSnapshot
            )
        )
    }

    static func gpsUpdate(
        for snapshot: WorkoutSnapshotV1
    ) -> WorkoutDeviceGPSUpdate? {
        guard snapshot.state.isActive,
              let location = snapshot.location,
              location.latitude.isFinite,
              (-90...90).contains(location.latitude),
              location.longitude.isFinite,
              (-180...180).contains(location.longitude),
              location.horizontalAccuracy.isFinite,
              location.horizontalAccuracy >= 0 else {
            return nil
        }
        return WorkoutDeviceGPSUpdate(
            latitude: location.latitude,
            longitude: location.longitude,
            capturedAt: location.capturedAt,
            horizontalAccuracyMeters: location.horizontalAccuracy,
            courseDegrees: finiteValue(
                location.course,
                acceptedBy: { (0..<360).contains($0) }
            ),
            speedMetersPerSecond: finiteValue(
                location.speed,
                acceptedBy: { $0 >= 0 }
            ),
            altitudeMeters: finiteValue(location.altitude),
            distanceTraveledMeters: finiteValue(
                snapshot.cyclingDistance?.value,
                acceptedBy: { $0 >= 0 }
            ),
            elapsedSeconds: finiteValue(
                snapshot.elapsedTime?.value,
                acceptedBy: { $0 >= 0 }
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

    /// Produces the firmware transport transaction for one canonical sample.
    /// Idle is a reset command, not a correlated metric snapshot: firmware
    /// requires one generation-zero core frame and rejects an idle extended
    /// frame. Active samples remain an atomically stamped core/extended pair.
    static func transportFrames(
        for frames: WorkoutDeviceFrames,
        generation: UInt8,
        includeOrigin: Bool = false
    ) -> [Data] {
        if frames.identity.state == .idle {
            return [frames.core]
        }
        let stamped = stampedPair(
            core: frames.core,
            extended: frames.extended,
            generation: generation
        )
        var result = [stamped.core, stamped.extended]
        if includeOrigin, frames.originAvailable {
            result.append(frames.origin)
        }
        return result
    }

    private static func originFrame(
        for sample: WorkoutDeviceTelemetrySample
    ) -> Data? {
        guard sample.state != .idle,
              sample.sessionToken != 0,
              let sessionID = sample.sessionID else {
            return nil
        }
        let pauseOrigin: UInt8
        if sample.state == .paused {
            pauseOrigin = sample.pauseOrigin?.rawValue ?? 0
        } else {
            pauseOrigin = 0
        }
        let profileVersion = sample.detectorProfileVersion ?? 0
        let lastOrigin = sample.lastTransitionOrigin?.rawValue ?? 0
        if (pauseOrigin == WorkoutTransitionOrigin.automatic.rawValue
                || lastOrigin == WorkoutTransitionOrigin.automatic.rawValue),
           profileVersion == 0 {
            return nil
        }

        var origin = Data(capacity: originFrameLength)
        origin.append(3)
        origin.append(pauseOrigin)
        origin.appendUInt16LE(sample.sessionToken)
        origin.appendUInt32LE(encodeUInt32(sample.wallElapsedSeconds))
        origin.appendUUID(sessionID)
        origin.appendUInt16LE(profileVersion)
        origin.append(lastOrigin)
        origin.append(0)
        guard origin.count == originFrameLength else { return nil }
        return origin
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

    private static func finiteValue(
        _ value: Double?,
        acceptedBy predicate: (Double) -> Bool = { _ in true }
    ) -> Double? {
        guard let value, value.isFinite, predicate(value) else { return nil }
        return value
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

    nonisolated mutating func appendUUID(_ value: UUID) {
        var bytes = value.uuid
        Swift.withUnsafeBytes(of: &bytes) {
            append(contentsOf: $0)
        }
    }
}
