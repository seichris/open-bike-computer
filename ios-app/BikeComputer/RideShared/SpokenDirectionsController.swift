import Foundation

@MainActor
protocol SpokenDirectionsTransportV1: AnyObject {
    var isSpokenDirectionsReady: Bool { get }
    var spokenDirectionsConnectionGeneration: UInt64 { get }
    @discardableResult
    func sendSpokenDirectionsCommand(commandType: RideBLEApplicationCommandTypeV1, payload: Data,
                                    preparePayload: @escaping () -> Data?,
                                    completion: @escaping (Bool) -> Void) -> Bool
}

/// iPhone lifecycle adapter. Keeps at most one control/cue transaction in
/// flight; observations while busy still consume phases, never form a backlog.
@MainActor
final class SpokenDirectionsControllerV1 {
    weak var transport: (any SpokenDirectionsTransportV1)?
    private var scheduler = SpokenCueSchedulerV1()
    private var incarnation = UUID()
    private var connection: UInt64?
    private var activated = false
    private var activationAttempted = false
    private var failedConnection: UInt64?
    private var controlRevision: UInt32 = 0
    private var operation: UUID?
    private var operationPhase: SpokenPhaseV1?
    private var terminalRequested = false
    private var stepID: UInt32 = 0
    private var distance = Double.infinity
    private var usable = false
    private var volume: UInt8 = 70
    private let uptime: () -> TimeInterval

    init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    func start(generation: UInt32, restored: Bool = false) {
        stop()
        incarnation = UUID()
        scheduler.start(token: UInt64.random(in: 1...UInt64.max), generation: generation, restored: restored)
        connection = nil
        terminalRequested = false
    }

    func connectionLost() {
        incarnation = UUID() // revoke any queued dispatch/retry before reconnect
        operation = nil
        operationPhase = nil
        activated = false
        activationAttempted = false
        usable = false
        scheduler.resynchronize()
    }

    func observe(snapshot: NavigationSnapshotV1, step: NavigationRouteStepV1, locale: String,
                 location: NavigationLocationSampleV1, now: Date, enabled: Bool,
                 paused: Bool, volume: UInt8) {
        guard scheduler.token != 0, !terminalRequested else { return }
        let currentConnection = transport?.spokenDirectionsConnectionGeneration
        let ready = transport?.isSpokenDirectionsReady == true &&
            (failedConnection == nil || failedConnection != currentConnection)
        if connection != currentConnection {
            if connection != nil { connectionLost() }
            connection = currentConnection
        }
        if !ready { connectionLost() }
        self.volume = min(100, volume)
        let age = now.timeIntervalSince(location.timestamp)
        usable = enabled && !paused && ready && age.isFinite && (0...5).contains(age) &&
            location.speedMetersPerSecond != 0 && snapshot.offRouteDistanceMeters == nil &&
            location.horizontalAccuracyMeters.isFinite &&
            (0...min(30, max(20, snapshot.distanceToManeuverMeters))).contains(location.horizontalAccuracyMeters) &&
            SpokenManeuverClassifier.supports(locale: locale)
        let previousProgress = scheduler.progressRevision
        let decision = scheduler.evaluate(snapshot: snapshot, step: step, locale: locale,
            location: location, now: now, uptime: uptime(), enabled: enabled, ready: ready,
            paused: paused, volume: self.volume)
        guard scheduler.progressRevision != previousProgress else { return }
        stepID = step.id
        distance = snapshot.distanceToManeuverMeters
        guard ready, operation == nil, let transport else { return }
        if !activated {
            guard advanceControlRevision() else { return }
        }
        let control = makeControl(activated ? .progress : .activate, enabled: usable)
        guard let payload = control.encoded() else { return }
        let epoch = incarnation
        let operationID = UUID()
        operation = operationID
        activationAttempted = true
        operationPhase = decision?.cue.phase
        let deadline = uptime() + max(0, 5 - max(0, age))
        let admitted = transport.sendSpokenDirectionsCommand(commandType: .spokenRouteControl, payload: payload,
            preparePayload: { [weak self] in
                guard let self, self.incarnation == epoch, self.operation == operationID,
                      self.stepID == control.stepID, self.uptime() < deadline,
                      self.usable == control.enabled else { return nil }
                let remaining = min(5000, (deadline - self.uptime()) * 1000)
                guard remaining >= 1 else { return nil }
                return SpokenRouteControlV1(action: control.action, token: control.token,
                    generation: control.generation, revision: control.revision, stepID: control.stepID,
                    progressRevision: control.progressRevision, enabled: control.enabled,
                    volume: control.volume, leaseMS: UInt16(remaining)).encoded()
            }, completion: { [weak self] success in
                guard let self, self.incarnation == epoch, self.operation == operationID else { return }
                // Failed activation may have reached firmware before its ACK was
                // lost. Never retry it under a new command identity this session.
                guard success else {
                    self.failedConnection = self.connection
                    let consumed = self.scheduler
                    self.stop()
                    self.scheduler = consumed
                    self.scheduler.resynchronize()
                    return
                }
                self.activated = true
                guard let decision else { self.complete(operationID); return }
                self.send(decision, epoch: epoch, operationID: operationID)
            })
        if !admitted { complete(operationID) }
    }

    func stop(arrived: Bool = false) {
        if arrived, operation != nil, operationPhase == .arrival {
            terminalRequested = true
            return // terminal control follows the arrival cue's application ACK
        }
        let wasActive = activated || activationAttempted
        incarnation = UUID()
        operation = nil
        operationPhase = nil
        usable = false
        if wasActive, advanceControlRevision(), let transport {
            let control = makeControl(arrived ? .arrived : .cancel, enabled: arrived)
            if let payload = control.encoded() {
                // Matching token/generation prevents this delayed stop touching
                // a replacement route. It carries no location or speech text.
                _ = transport.sendSpokenDirectionsCommand(commandType: .spokenRouteControl, payload: payload,
                    preparePayload: { payload }, completion: { _ in })
            }
        }
        scheduler.stop()
        activated = false
        activationAttempted = false
        terminalRequested = false
        stepID = 0
    }

    private func send(_ decision: SpokenCueDecisionV1, epoch: UUID, operationID: UUID) {
        guard let transport, let initial = decision.cue.encoded() else { complete(operationID); return }
        let admitted = transport.sendSpokenDirectionsCommand(commandType: .spokenCue, payload: initial,
            preparePayload: { [weak self] in
                guard let self, self.incarnation == epoch, self.operation == operationID, self.usable,
                      self.scheduler.sequence == decision.cue.sequence,
                      decision.cue.phase != .prepare || self.distance > self.scheduler.actionDistance,
                      decision.cue.phase == .arrival || self.distance >= 20 else { return nil }
                return decision.payload(at: self.uptime(), token: self.scheduler.token,
                    generation: self.scheduler.generation, stepID: self.stepID)
            }, completion: { [weak self] _ in
                guard let self, self.incarnation == epoch else { return }
                self.complete(operationID)
            })
        if !admitted { complete(operationID) }
    }

    private func complete(_ id: UUID) {
        guard operation == id else { return }
        operation = nil
        operationPhase = nil
        if terminalRequested { stop(arrived: true) }
    }

    private func advanceControlRevision() -> Bool {
        guard controlRevision < .max else { scheduler.stop(); activated = false; return false }
        controlRevision += 1
        return true
    }

    private func makeControl(_ action: SpokenControlActionV1, enabled: Bool) -> SpokenRouteControlV1 {
        SpokenRouteControlV1(action: action, token: scheduler.token, generation: scheduler.generation,
            revision: controlRevision, stepID: stepID, progressRevision: scheduler.progressRevision,
            enabled: enabled, volume: volume, leaseMS: 5000)
    }
}
