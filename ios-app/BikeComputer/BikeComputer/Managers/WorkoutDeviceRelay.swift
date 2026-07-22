import Combine
import Foundation

enum WorkoutDeviceSessionState: UInt8, Equatable, Sendable {
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

struct WorkoutDeviceSourceFlags: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let pairedSpeedSensor = Self(rawValue: 1 << 0)
    static let watchSpeed = Self(rawValue: 1 << 1)
    static let healthKitDistance = Self(rawValue: 1 << 2)
    static let watchAltitude = Self(rawValue: 1 << 3)
    static let liveHeartRateZone = Self(rawValue: 1 << 4)
    static let currentSnapshot = Self(rawValue: 1 << 5)
}

struct WorkoutDeviceTelemetrySample: Equatable, Sendable {
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

struct WorkoutDeviceFrames: Equatable, Sendable {
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

enum WorkoutDeviceFrameBuilder {
    static let frameLength = DeviceBLEProtocol.workoutTelemetryFrameLength
    static let unavailableUInt16 = UInt16.max
    static let unavailableUInt32 = UInt32.max
    static let unavailableAltitude = Int16.min
    private static let metricSourceFlagsMask: UInt8 = 0x1F

    static func frames(for sample: WorkoutDeviceTelemetrySample) -> WorkoutDeviceFrames? {
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
            ? encodeUInt16(sample.currentHeartRateBPM, requiresPositive: true)
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
        if encodeUInt16(sample.speedMetersPerSecond, scale: 100) == unavailableUInt16 {
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
            ? encodeUInt16(sample.averageHeartRateBPM, requiresPositive: true)
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

enum WorkoutDeviceTelemetryMapper {
    static func sample(
        presentation: WorkoutMirrorPresentationV1,
        envelope: WorkoutEnvelopeV1?
    ) -> WorkoutDeviceTelemetrySample? {
        let authoritativeSnapshot = presentation.finalSnapshot
            ?? envelope?.snapshot
        let hasAuthoritativeEnd = authoritativeSnapshot?.state == .ended
        let requestedState = presentation.sessionState
        let state = requestedState == .ended && !hasAuthoritativeEnd
            ? WorkoutDeviceSessionState.ending
            : WorkoutDeviceSessionState(requestedState)

        if state == .idle {
            return emptySample(state: .idle, token: 0)
        }

        guard let envelope,
              envelope.sessionToken != 0,
              presentation.sessionID == envelope.sessionID else {
            return nil
        }

        let snapshot = state == .ended
            ? (presentation.finalSnapshot ?? presentation.snapshot)
            : presentation.snapshot
        let hasLiveNumerics: Bool
        let isCurrentSnapshot: Bool
        switch presentation.connectionState {
        case .connected:
            // HealthKit can stop producing live samples before the final
            // authoritative Watch snapshot arrives. Keep that ending update
            // current, but do not replay the last running values as live.
            hasLiveNumerics = state != .ending
            isCurrentSnapshot = true
        case .ended:
            hasLiveNumerics = state == .ended && hasAuthoritativeEnd
            // The mirrored end callback is current even while its final
            // authoritative snapshot is still pending. Keep freshness
            // independent from whether numeric fields may be relayed.
            isCurrentSnapshot = state == .ending || hasLiveNumerics
        case .failed:
            hasLiveNumerics = false
            // A terminal failure envelope is authoritative even though it
            // carries no live numerics. Transport/launch failures have no
            // matching failed envelope and therefore remain non-current.
            isCurrentSnapshot = state == .failed
                && envelope.snapshot?.state == .failed
        case .unsupported, .idle, .launchingWatch, .awaitingFirstSnapshot,
             .stale, .disconnected:
            hasLiveNumerics = false
            isCurrentSnapshot = false
        }

        guard hasLiveNumerics else {
            return emptySample(
                state: state,
                token: envelope.sessionToken,
                isCurrentSnapshot: isCurrentSnapshot
            )
        }

        var flags: WorkoutDeviceSourceFlags = []
        switch snapshot.currentSpeed?.source {
        case .pairedCyclingSensor:
            flags.insert(.pairedSpeedSensor)
        case .watchLocation:
            flags.insert(.watchSpeed)
        default:
            break
        }
        if snapshot.cyclingDistance?.source == .healthKit {
            flags.insert(.healthKitDistance)
        }

        let rawSnapshot = envelope.snapshot
        if rawSnapshot?.availability.contains(.altitude) == true,
           rawSnapshot?.location?.altitude != nil {
            flags.insert(.watchAltitude)
        }
        if rawSnapshot?.availability.contains(.heartRateZone) == true,
           rawSnapshot?.currentHeartRateZone != nil,
           rawSnapshot?.heartRateZoneCount != nil {
            flags.insert(.liveHeartRateZone)
        }

        return WorkoutDeviceTelemetrySample(
            state: state,
            sessionToken: envelope.sessionToken,
            hasLiveNumerics: true,
            isCurrentSnapshot: true,
            elapsedSeconds: metric(snapshot.elapsedTime, unit: .seconds),
            distanceMeters: metric(snapshot.cyclingDistance, unit: .meters),
            speedMetersPerSecond: metric(
                snapshot.currentSpeed,
                unit: .metersPerSecond
            ),
            currentHeartRateBPM: metric(
                snapshot.currentHeartRate,
                unit: .beatsPerMinute
            ),
            averageHeartRateBPM: metric(
                snapshot.averageHeartRate,
                unit: .beatsPerMinute
            ),
            activeEnergyKilocalories: metric(
                snapshot.activeEnergy,
                unit: .kilocalories
            ),
            cyclingPowerWatts: metric(snapshot.cyclingPower, unit: .watts),
            cyclingCadenceRPM: metric(
                snapshot.cyclingCadence,
                unit: .revolutionsPerMinute
            ),
            currentHeartRateZone: snapshot.currentHeartRateZone,
            altitudeMeters: snapshot.location?.altitude,
            heartRateZoneCount: snapshot.heartRateZoneCount,
            sourceFlags: flags
        )
    }

    private static func emptySample(
        state: WorkoutDeviceSessionState,
        token: UInt16,
        isCurrentSnapshot: Bool = false
    ) -> WorkoutDeviceTelemetrySample {
        WorkoutDeviceTelemetrySample(
            state: state,
            sessionToken: token,
            hasLiveNumerics: false,
            isCurrentSnapshot: isCurrentSnapshot,
            elapsedSeconds: nil,
            distanceMeters: nil,
            speedMetersPerSecond: nil,
            currentHeartRateBPM: nil,
            averageHeartRateBPM: nil,
            activeEnergyKilocalories: nil,
            cyclingPowerWatts: nil,
            cyclingCadenceRPM: nil,
            currentHeartRateZone: nil,
            altitudeMeters: nil,
            heartRateZoneCount: nil,
            sourceFlags: []
        )
    }

    private static func metric(
        _ metric: WorkoutMetricV1?,
        unit: WorkoutMetricUnitV1
    ) -> Double? {
        guard let metric, metric.unit == unit else { return nil }
        return metric.value
    }
}

enum WorkoutDeviceFrameKind: Equatable, Sendable {
    case core
    case extended
}

struct WorkoutDeviceTransmission: Equatable, Sendable {
    let kind: WorkoutDeviceFrameKind
    let data: Data
    let prioritized: Bool
}

struct WorkoutDeviceRelaySchedule: Equatable, Sendable {
    let transmissions: [WorkoutDeviceTransmission]
    let nextEvaluationAt: Date?
}

struct WorkoutDeviceRelayScheduler: Sendable {
    let coalescingInterval: TimeInterval
    let coreHeartbeatInterval: TimeInterval
    let extendedHeartbeatInterval: TimeInterval

    private var wasTransportReady = false
    private var lastCoreFrame: Data?
    private var lastExtendedFrame: Data?
    private var lastCoreSentAt: Date?
    private var lastExtendedSentAt: Date?
    private var lastCoreIdentity: WorkoutDeviceFrames.Identity?
    private var pendingCoreFrame: Data?
    private var pendingExtendedFrame: Data?
    private var pendingPairIdentity: WorkoutDeviceFrames.Identity?
    private var nextPairGeneration: UInt8 = 1

    init(
        coalescingInterval: TimeInterval = 1,
        coreHeartbeatInterval: TimeInterval = 5,
        extendedHeartbeatInterval: TimeInterval = 5
    ) {
        self.coalescingInterval = max(0, coalescingInterval)
        self.coreHeartbeatInterval = max(0, coreHeartbeatInterval)
        self.extendedHeartbeatInterval = max(0, extendedHeartbeatInterval)
    }

    mutating func update(
        frames: WorkoutDeviceFrames?,
        transportReady: Bool,
        at date: Date
    ) -> WorkoutDeviceRelaySchedule {
        guard transportReady, let frames else {
            wasTransportReady = false
            pendingCoreFrame = nil
            pendingExtendedFrame = nil
            pendingPairIdentity = nil
            return WorkoutDeviceRelaySchedule(
                transmissions: [],
                nextEvaluationAt: nil
            )
        }

        let becameReady = !wasTransportReady
        wasTransportReady = true
        let urgent = becameReady || lastCoreIdentity != frames.identity
        guard pendingCoreFrame == nil, pendingExtendedFrame == nil else {
            return WorkoutDeviceRelaySchedule(
                transmissions: [],
                nextEvaluationAt: nil
            )
        }

        if frames.identity.state == .idle {
            guard urgent || isChangedFrameDue(
                frames.core,
                lastFrame: lastCoreFrame,
                lastSentAt: lastCoreSentAt,
                at: date
            ) else {
                return WorkoutDeviceRelaySchedule(
                    transmissions: [],
                    nextEvaluationAt: nil
                )
            }
            pendingCoreFrame = frames.core
            pendingPairIdentity = frames.identity
            return WorkoutDeviceRelaySchedule(
                transmissions: [WorkoutDeviceTransmission(
                    kind: .core,
                    data: frames.core,
                    prioritized: true
                )],
                nextEvaluationAt: nil
            )
        }

        let coreHeartbeatDue = shouldHeartbeatCore(frames)
            && isDue(
                lastCoreSentAt,
                interval: coreHeartbeatInterval,
                at: date
            )
        let extendedChangedDue = isChangedFrameDue(
            frames.extended,
            lastFrame: lastExtendedFrame,
            lastSentAt: lastExtendedSentAt,
            at: date
        )
        let extendedHeartbeatDue = isDue(
            lastExtendedSentAt,
            interval: extendedHeartbeatInterval,
            at: date
        )
        let coreChangedDue = isChangedFrameDue(
            frames.core,
            lastFrame: lastCoreFrame,
            lastSentAt: lastCoreSentAt,
            at: date
        )
        guard urgent || coreChangedDue || coreHeartbeatDue
                || extendedChangedDue || extendedHeartbeatDue else {
            return WorkoutDeviceRelaySchedule(
                transmissions: [],
                nextEvaluationAt: nextEvaluationDate(for: frames, at: date)
            )
        }

        let generation = nextPairGeneration
        nextPairGeneration = generation == 3 ? 1 : generation + 1
        let core = stampedCore(frames.core, generation: generation)
        let extended = stampedExtended(
            frames.extended,
            generation: generation
        )
        pendingCoreFrame = core
        pendingExtendedFrame = extended
        pendingPairIdentity = frames.identity

        return WorkoutDeviceRelaySchedule(
            transmissions: [
                WorkoutDeviceTransmission(
                    kind: .core,
                    data: core,
                    prioritized: urgent
                ),
                WorkoutDeviceTransmission(
                    kind: .extended,
                    data: extended,
                    prioritized: false
                ),
            ],
            nextEvaluationAt: nil
        )
    }

    mutating func didWrite(
        kind: WorkoutDeviceFrameKind,
        data: Data,
        at date: Date
    ) {
        switch kind {
        case .core:
            if pendingCoreFrame == data { pendingCoreFrame = nil }
            lastCoreFrame = canonicalCore(data)
            lastCoreSentAt = date
            lastCoreIdentity = pendingPairIdentity
        case .extended:
            if pendingExtendedFrame == data { pendingExtendedFrame = nil }
            lastExtendedFrame = canonicalExtended(data)
            lastExtendedSentAt = date
        }
        if pendingCoreFrame == nil, pendingExtendedFrame == nil {
            pendingPairIdentity = nil
        }
    }

    mutating func didNotWrite(
        kind: WorkoutDeviceFrameKind,
        data: Data
    ) {
        switch kind {
        case .core:
            if pendingCoreFrame == data { pendingCoreFrame = nil }
        case .extended:
            if pendingExtendedFrame == data { pendingExtendedFrame = nil }
        }
        // A partial pair is never a successful publication. Force the next
        // evaluation to resend both correlated frames.
        lastCoreFrame = nil
        lastExtendedFrame = nil
        lastCoreSentAt = nil
        lastExtendedSentAt = nil
        lastCoreIdentity = nil
        if pendingCoreFrame == nil, pendingExtendedFrame == nil {
            pendingPairIdentity = nil
        }
    }

    mutating func didFail(
        kind: WorkoutDeviceFrameKind,
        data: Data
    ) {
        didNotWrite(kind: kind, data: data)
    }

    mutating func transportDidBecomeUnavailable() {
        wasTransportReady = false
        pendingCoreFrame = nil
        pendingExtendedFrame = nil
        pendingPairIdentity = nil
    }

    private func isChangedFrameDue(
        _ frame: Data,
        lastFrame: Data?,
        lastSentAt: Date?,
        at date: Date
    ) -> Bool {
        guard frame != lastFrame else { return false }
        return isDue(lastSentAt, interval: coalescingInterval, at: date)
    }

    private func isDue(
        _ lastDate: Date?,
        interval: TimeInterval,
        at date: Date
    ) -> Bool {
        guard let lastDate else { return true }
        return date.timeIntervalSince(lastDate) >= interval
    }

    private func nextEvaluationDate(
        for frames: WorkoutDeviceFrames,
        at date: Date
    ) -> Date? {
        guard pendingCoreFrame == nil, pendingExtendedFrame == nil,
              frames.identity.state != .idle else {
            return nil
        }
        var dates: [Date] = []
        if frames.core != lastCoreFrame {
            dates.append(lastCoreSentAt?.addingTimeInterval(coalescingInterval) ?? date)
        }
        if shouldHeartbeatCore(frames),
           let lastCoreSentAt {
            dates.append(lastCoreSentAt.addingTimeInterval(
                coreHeartbeatInterval
            ))
        }
        if frames.extended != lastExtendedFrame {
            dates.append(lastExtendedSentAt?.addingTimeInterval(coalescingInterval) ?? date)
        }
        if let lastExtendedSentAt {
            dates.append(lastExtendedSentAt.addingTimeInterval(
                extendedHeartbeatInterval
            ))
        }
        return dates.min()
    }

    private func stampedCore(_ data: Data, generation: UInt8) -> Data {
        guard data.count == WorkoutDeviceFrameBuilder.frameLength else {
            return data
        }
        var stamped = data
        stamped[1] = (stamped[1] & 0x3F) | ((generation & 0x03) << 6)
        return stamped
    }

    private func stampedExtended(_ data: Data, generation: UInt8) -> Data {
        guard data.count == WorkoutDeviceFrameBuilder.frameLength else {
            return data
        }
        var stamped = data
        stamped[1] = (stamped[1] & 0x3F) | ((generation & 0x03) << 6)
        return stamped
    }

    private func canonicalCore(_ data: Data) -> Data {
        guard data.count == WorkoutDeviceFrameBuilder.frameLength else {
            return data
        }
        var canonical = data
        canonical[1] &= 0x3F
        return canonical
    }

    private func canonicalExtended(_ data: Data) -> Data {
        guard data.count == WorkoutDeviceFrameBuilder.frameLength else {
            return data
        }
        var canonical = data
        canonical[1] &= 0x3F
        return canonical
    }

    private func shouldHeartbeatCore(_ frames: WorkoutDeviceFrames) -> Bool {
        guard frames.identity.hasLiveNumerics else { return false }
        switch frames.identity.state {
        case .starting, .running, .paused:
            return true
        case .idle, .ending, .ended, .failed:
            return false
        }
    }
}

@MainActor
final class WorkoutDeviceRelay {
    private let store: WorkoutMetricsStore
    private let bleManager: BLEManager
    private let now: () -> Date
    private var scheduler: WorkoutDeviceRelayScheduler
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var evaluationScheduled = false

    init(
        store: WorkoutMetricsStore,
        bleManager: BLEManager,
        now: @escaping () -> Date = Date.init,
        scheduler: WorkoutDeviceRelayScheduler? = nil
    ) {
        self.store = store
        self.bleManager = bleManager
        self.now = now
        // Default-argument expressions are evaluated from a nonisolated
        // context. Construct the default on the main actor so this remains
        // valid under Swift 6 strict isolation.
        self.scheduler = scheduler ?? WorkoutDeviceRelayScheduler()

        Publishers.CombineLatest4(
            store.$presentation,
            bleManager.$isConnected,
            bleManager.$isNavigationReady,
            bleManager.$supportsWorkoutTelemetry
        )
        .sink { [weak self] _, isConnected, isNavigationReady,
                supportsWorkoutTelemetry in
            // @Published emits in willSet. Defer one main turn so the store
            // presentation/envelope and BLE readiness properties are read from
            // the same committed revision. Coalescing also keeps a multi-field
            // connection transition to one evaluation.
            guard let self else { return }
            // Preserve a transport-off boundary synchronously from the emitted
            // values. If false/true publications arrive in one run-loop turn,
            // the deferred evaluator must still treat the later true state as
            // a reconnect and resend both frames.
            if !isConnected || !isNavigationReady || !supportsWorkoutTelemetry {
                self.scheduler.transportDidBecomeUnavailable()
            }
            self.requestEvaluation()
        }
        .store(in: &cancellables)
    }

    deinit {
        timer?.invalidate()
    }

    private func evaluate() {
        timer?.invalidate()
        timer = nil
        let date = now()
        let sample = WorkoutDeviceTelemetryMapper.sample(
            presentation: store.presentation,
            envelope: store.currentEnvelope
        )
        let frames = sample.flatMap(WorkoutDeviceFrameBuilder.frames)
        let ready = bleManager.isConnected
            && bleManager.isNavigationReady
            && bleManager.supportsWorkoutTelemetry
        var schedule = scheduler.update(
            frames: frames,
            transportReady: ready,
            at: date
        )

        var needsRetry = false
        for transmission in schedule.transmissions {
            let accepted = bleManager.sendWorkoutTelemetryFrame(
                transmission.data,
                prioritized: transmission.prioritized,
                onWrite: { [weak self] in
                    self?.completeWrite(transmission)
                },
                onDrop: { [weak self] in
                    self?.dropWrite(transmission)
                },
                onWriteFailure: { [weak self] in
                    self?.failWrite(transmission)
                }
            )
            if !accepted {
                scheduler.didNotWrite(
                    kind: transmission.kind,
                    data: transmission.data
                )
                needsRetry = true
            }
        }

        if needsRetry {
            schedule = WorkoutDeviceRelaySchedule(
                transmissions: [],
                nextEvaluationAt: date.addingTimeInterval(0.25)
            )
        }
        scheduleEvaluation(at: schedule.nextEvaluationAt)
    }

    private func completeWrite(_ transmission: WorkoutDeviceTransmission) {
        scheduler.didWrite(
            kind: transmission.kind,
            data: transmission.data,
            at: now()
        )
        requestEvaluation()
    }

    private func dropWrite(_ transmission: WorkoutDeviceTransmission) {
        scheduler.didNotWrite(
            kind: transmission.kind,
            data: transmission.data
        )
        requestEvaluation()
    }

    private func failWrite(_ transmission: WorkoutDeviceTransmission) {
        scheduler.didFail(
            kind: transmission.kind,
            data: transmission.data
        )
        requestEvaluation()
    }

    private func requestEvaluation() {
        guard !evaluationScheduled else { return }
        evaluationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.evaluationScheduled = false
            self.evaluate()
        }
    }

    private func scheduleEvaluation(at date: Date?) {
        guard let date else { return }
        let interval = max(0.01, date.timeIntervalSince(now()))
        timer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluate()
            }
        }
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func appendInt16LE(_ value: Int16) {
        appendUInt16LE(UInt16(bitPattern: value))
    }
}
