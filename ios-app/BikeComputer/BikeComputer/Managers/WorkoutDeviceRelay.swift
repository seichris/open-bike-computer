import Combine
import Foundation
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
            return WorkoutDeviceTelemetrySampleMapperV1.emptySample(
                state: .idle,
                sessionToken: 0
            )
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

        let rawSnapshot = envelope.snapshot
        return WorkoutDeviceTelemetrySampleMapperV1.sample(
            snapshot: snapshot,
            provenanceSnapshot: rawSnapshot,
            state: state,
            sessionToken: envelope.sessionToken,
            sessionID: presentation.sessionID,
            hasLiveNumerics: hasLiveNumerics,
            isCurrentSnapshot: isCurrentSnapshot
        )
    }
}

enum WorkoutDeviceFrameKind: Equatable, Sendable {
    case core
    case extended
    case origin
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
    private var lastOriginFrame: Data?
    private var lastCoreSentAt: Date?
    private var lastExtendedSentAt: Date?
    private var lastOriginSentAt: Date?
    private var lastCoreIdentity: WorkoutDeviceFrames.Identity?
    private var pendingCoreFrame: Data?
    private var pendingExtendedFrame: Data?
    private var pendingOriginFrame: Data?
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
        originTransportReady: Bool = true,
        at date: Date
    ) -> WorkoutDeviceRelaySchedule {
        guard transportReady, let frames else {
            wasTransportReady = false
            pendingCoreFrame = nil
            pendingExtendedFrame = nil
            pendingOriginFrame = nil
            pendingPairIdentity = nil
            return WorkoutDeviceRelaySchedule(
                transmissions: [],
                nextEvaluationAt: nil
            )
        }

        let becameReady = !wasTransportReady
        wasTransportReady = true
        let originReady = originTransportReady && frames.originAvailable
        if !originReady {
            pendingOriginFrame = nil
        }
        let urgent = becameReady || lastCoreIdentity != frames.identity
        guard pendingCoreFrame == nil, pendingExtendedFrame == nil,
              pendingOriginFrame == nil else {
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
        let originChangedDue = isChangedFrameDue(
            frames.origin,
            lastFrame: lastOriginFrame,
            lastSentAt: lastOriginSentAt,
            at: date
        )
        let originIdentityBoundary = lastCoreIdentity.map {
            $0.sessionToken != frames.identity.sessionToken
                || $0.hasLiveNumerics != frames.identity.hasLiveNumerics
        } ?? true
        let originDue = originReady
            && (becameReady || originChangedDue || originIdentityBoundary)
        let pairDue = urgent || coreChangedDue || coreHeartbeatDue
            || extendedChangedDue || extendedHeartbeatDue
        guard pairDue || originDue else {
            return WorkoutDeviceRelaySchedule(
                transmissions: [],
                nextEvaluationAt: nextEvaluationDate(
                    for: frames,
                    includeOrigin: originReady,
                    at: date
                )
            )
        }

        if !pairDue {
            pendingOriginFrame = frames.origin
            return WorkoutDeviceRelaySchedule(
                transmissions: [WorkoutDeviceTransmission(
                    kind: .origin,
                    data: frames.origin,
                    prioritized: true
                )],
                nextEvaluationAt: nil
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
        if originDue {
            pendingOriginFrame = frames.origin
        }
        pendingPairIdentity = frames.identity

        var transmissions = [
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
        ]
        if originDue {
            transmissions.append(
                WorkoutDeviceTransmission(
                    kind: .origin,
                    data: frames.origin,
                    prioritized: urgent
                )
            )
        }
        return WorkoutDeviceRelaySchedule(
            transmissions: transmissions,
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
        case .origin:
            if pendingOriginFrame == data { pendingOriginFrame = nil }
            lastOriginFrame = data
            lastOriginSentAt = date
        }
        if pendingCoreFrame == nil, pendingExtendedFrame == nil,
           pendingOriginFrame == nil {
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
        case .origin:
            if pendingOriginFrame == data { pendingOriginFrame = nil }
            lastOriginFrame = nil
            lastOriginSentAt = nil
            return
        }
        // A partial pair is never a successful publication. Force the next
        // evaluation to resend both correlated frames.
        lastCoreFrame = nil
        lastExtendedFrame = nil
        lastCoreSentAt = nil
        lastExtendedSentAt = nil
        lastOriginFrame = nil
        lastOriginSentAt = nil
        lastCoreIdentity = nil
        if pendingCoreFrame == nil, pendingExtendedFrame == nil,
           pendingOriginFrame == nil {
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
        pendingOriginFrame = nil
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
        includeOrigin: Bool,
        at date: Date
    ) -> Date? {
        guard pendingCoreFrame == nil, pendingExtendedFrame == nil,
              pendingOriginFrame == nil,
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
        if includeOrigin, frames.origin != lastOriginFrame {
            dates.append(
                lastOriginSentAt?.addingTimeInterval(coalescingInterval)
                    ?? date
            )
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
    private struct MotionTransmissionIdentity: Equatable {
        let sessionToken: UInt16
        let epoch: UInt16
        let sequence: UInt32
        let automaticallyPaused: Bool
    }
    private var lastMotionIdentity: MotionTransmissionIdentity?
    private var pendingMotionIdentity: MotionTransmissionIdentity?

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
                self.lastMotionIdentity = nil
                self.pendingMotionIdentity = nil
            }
            self.requestEvaluation()
        }
        .store(in: &cancellables)

        bleManager.$supportsRideAutomation
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.requestEvaluation()
            }
            .store(in: &cancellables)

        bleManager.$supportsWatchGPSMotionEvidenceV1
            .removeDuplicates()
            .sink { [weak self] supported in
                if !supported {
                    self?.lastMotionIdentity = nil
                    self?.pendingMotionIdentity = nil
                }
                self?.requestEvaluation()
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
            originTransportReady: bleManager.supportsRideAutomation,
            at: date
        )

        var needsRetry = false
        let pairedCore = schedule.transmissions.first(where: {
            $0.kind == .core
        })
        let pairedExtended = schedule.transmissions.first(where: {
            $0.kind == .extended
        })
        if let core = pairedCore,
           let extended = pairedExtended {
            let transmissionsByData = Dictionary(
                uniqueKeysWithValues: schedule.transmissions.map {
                    ($0.data, $0)
                }
            )
            let accepted = bleManager.sendWorkoutTelemetryPair(
                core: core.data,
                extended: extended.data,
                origin: schedule.transmissions.first(where: {
                    $0.kind == .origin
                })?.data,
                prioritized: core.prioritized || extended.prioritized,
                onWrite: { [weak self] data in
                    guard let transmission = transmissionsByData[data] else {
                        return
                    }
                    self?.completeWrite(transmission)
                },
                onDrop: { [weak self] data in
                    guard let transmission = transmissionsByData[data] else {
                        return
                    }
                    self?.dropWrite(transmission)
                },
                onWriteFailure: { [weak self] data in
                    guard let transmission = transmissionsByData[data] else {
                        return
                    }
                    self?.failWrite(transmission)
                }
            )
            if !accepted {
                for transmission in schedule.transmissions {
                    scheduler.didNotWrite(
                        kind: transmission.kind,
                        data: transmission.data
                    )
                }
                needsRetry = true
            }
        }

        if pairedCore == nil || pairedExtended == nil {
            for transmission in schedule.transmissions where
                transmission.kind != .origin {
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
        }

        for transmission in schedule.transmissions where
            transmission.kind == .origin
                && (pairedCore == nil || pairedExtended == nil) {
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

        if ready,
           bleManager.supportsWatchGPSMotionEvidenceV1,
           let envelope = store.currentEnvelope,
           envelope.kind == .snapshot,
           let snapshot = envelope.snapshot,
           let epoch = snapshot.location?.motionSampleEpoch,
           let sequence = snapshot.location?.motionSampleSequence {
            let motionIdentity = MotionTransmissionIdentity(
                sessionToken: envelope.sessionToken,
                epoch: epoch,
                sequence: sequence,
                automaticallyPaused: snapshot.state == .paused &&
                    snapshot.pauseOrigin == .automatic
            )
            if motionIdentity != lastMotionIdentity,
               motionIdentity != pendingMotionIdentity,
               let motion = WorkoutDeviceFrameBuilder.watchMotionFrame(
                    for: snapshot,
                    sessionToken: envelope.sessionToken,
                    sentAt: date
                  ) {
                pendingMotionIdentity = motionIdentity
                let accepted = bleManager.sendWorkoutTelemetryFrame(
                    motion,
                    prioritized: false,
                    motionCapturedAt: snapshot.location?.capturedAt,
                    onWrite: { [weak self] in
                        self?.completeMotionWrite(motionIdentity)
                    },
                    onDrop: { [weak self] in
                        self?.dropMotionWrite(motionIdentity)
                    },
                    onWriteFailure: { [weak self] in
                        self?.dropMotionWrite(motionIdentity)
                    }
                )
                if !accepted {
                    if pendingMotionIdentity == motionIdentity {
                        pendingMotionIdentity = nil
                    }
                    needsRetry = true
                }
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

    private func completeMotionWrite(
        _ identity: MotionTransmissionIdentity
    ) {
        if pendingMotionIdentity == identity {
            pendingMotionIdentity = nil
        }
        lastMotionIdentity = identity
        requestEvaluation()
    }

    private func dropMotionWrite(
        _ identity: MotionTransmissionIdentity
    ) {
        if pendingMotionIdentity == identity {
            pendingMotionIdentity = nil
        }
        requestEvaluation()
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
