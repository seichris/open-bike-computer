import Foundation

struct SpokenCueDecisionV1: Equatable {
    let cue: SpokenCueV1
    let startDeadline: TimeInterval

    /// Evaluate again at physical write dispatch, before authenticated framing.
    func payload(at now: TimeInterval, token: UInt64, generation: UInt32, stepID: UInt32) -> Data? {
        guard now.isFinite, now >= 0, startDeadline.isFinite,
              now >= startDeadline - Double(cue.startLifetimeMS) / 1000,
              token == cue.token, generation == cue.generation, stepID == cue.stepID,
              now < startDeadline else { return nil }
        let remaining = min(Double(SpokenDirectionsGeneratedV1.maximumStartLifetimeMs),
                            (startDeadline - now) * 1000)
        guard remaining >= 1 else { return nil }
        return SpokenCueV1(token: cue.token, generation: cue.generation, sequence: cue.sequence,
                           stepID: cue.stepID, progressRevision: cue.progressRevision, phase: cue.phase,
                           maneuver: cue.maneuver, distanceBucket: cue.distanceBucket, volume: cue.volume,
                           startLifetimeMS: UInt16(remaining), assetKey: cue.assetKey).encoded()
    }
}

/// One owner per NavigationEngine. No timers, geometry projection, I/O, speech
/// rendering, transport retries, or mutable global preferences in this policy.
struct SpokenCueSchedulerV1 {
    static let policyVersion = 1
    private(set) var token: UInt64 = 0
    private(set) var generation: UInt32 = 0
    private(set) var progressRevision: UInt32 = 0
    private(set) var prepareBucket: UInt16 = 50
    private(set) var actionDistance = 25.0
    private(set) var sequence: UInt32 = 0
    private var stepIndex: Int?
    private var stepID: UInt32 = 0
    private var previousDistance: Double?
    private var consumedPrepare = false
    private var consumedAction = false
    private var allowNearStart = false
    private var seedAfterReconnect = false
    private var lastTimestamp: Date?
    private var lastUptime: TimeInterval?
    private var lastPreparedDistance: Double?
    private var minimumGap = 35.0
    private var smoothedSpeed: Double?

    mutating func start(token: UInt64, generation: UInt32, restored: Bool = false) {
        self = Self()
        guard token != 0, generation != 0 else { return }
        self.token = token
        self.generation = generation
        allowNearStart = !restored
        seedAfterReconnect = restored
    }

    mutating func stop() { self = Self() }

    /// Preserve consumed decisions, and seed any thresholds passed during the
    /// disconnect. A reconnect cannot recreate the near-start exception.
    mutating func resynchronize() {
        allowNearStart = false
        seedAfterReconnect = true
    }

    mutating func evaluate(
        snapshot: NavigationSnapshotV1, step: NavigationRouteStepV1, locale: String,
        location: NavigationLocationSampleV1, now: Date, uptime: TimeInterval,
        enabled: Bool, ready: Bool, paused: Bool, volume: UInt8 = 70
    ) -> SpokenCueDecisionV1? {
        guard token != 0, generation == snapshot.navigationGeneration,
              step.id != 0, snapshot.currentStepIndex >= 0,
              snapshot.distanceToManeuverMeters.isFinite, snapshot.distanceToManeuverMeters >= 0,
              location.timestamp.timeIntervalSinceReferenceDate.isFinite,
              uptime.isFinite, uptime >= 0, lastUptime.map({ uptime >= $0 }) ?? true,
              lastTimestamp.map({ location.timestamp >= $0 }) ?? true else { return nil }
        if lastTimestamp == location.timestamp, !seedAfterReconnect { return nil }
        if let stepIndex, snapshot.currentStepIndex < stepIndex { return nil }
        if stepIndex == snapshot.currentStepIndex, stepID != step.id { return nil }
        guard progressRevision != .max else { stop(); return nil }
        progressRevision += 1
        let previousUptime = lastUptime
        lastTimestamp = location.timestamp
        lastUptime = uptime
        let distance = snapshot.distanceToManeuverMeters
        let age = now.timeIntervalSince(location.timestamp)
        let speed = location.speedMetersPerSecond
        let stationary = speed.isFinite && speed == 0
        let measuredSpeed = speed.isFinite && speed > 0 && age.isFinite && (0...5).contains(age)
            ? min(15, max(2, speed)) : 5
        if let previousUptime, let previousSpeed = smoothedSpeed, uptime - previousUptime <= 5 {
            let alpha = 1 - exp(-(uptime - previousUptime) / 2)
            smoothedSpeed = previousSpeed + alpha * (measuredSpeed - previousSpeed)
        } else { smoothedSpeed = measuredSpeed }
        let normalizedSpeed = smoothedSpeed ?? 5
        let maneuver = SpokenManeuverClassifier.classify(step.instruction, locale: locale)
        let usable = enabled && ready && !paused && !stationary && volume <= 100 &&
            SpokenManeuverClassifier.supports(locale: locale) && snapshot.offRouteDistanceMeters == nil &&
            age.isFinite && age >= 0 && age <= 5 && location.horizontalAccuracyMeters.isFinite &&
            location.horizontalAccuracyMeters >= 0 && location.horizontalAccuracyMeters <= min(30, max(20, distance))

        let entered = stepIndex != snapshot.currentStepIndex
        let nearStart = entered && stepIndex == nil && allowNearStart && !seedAfterReconnect
        if entered {
            stepIndex = snapshot.currentStepIndex
            stepID = step.id
            actionDistance = min(60, max(25, normalizedSpeed * 3))
            minimumGap = max(35, normalizedSpeed * 5)
            // Honor BOTH lead and minimum gap. A 50 m prepare paired with the
            // plan's >=25 m action and >=35 m gap is otherwise impossible.
            let lead = min(200, max(50, normalizedSpeed * 8, actionDistance + minimumGap))
            prepareBucket = lead <= 50 ? 50 : (lead <= 100 ? 100 : 200)
            consumedPrepare = distance <= Double(prepareBucket) || maneuver == .unknown ||
                maneuver == .continueRoute || maneuver == .arrive
            consumedAction = distance <= actionDistance
            previousDistance = distance
            lastPreparedDistance = nil
            allowNearStart = false
        }
        if seedAfterReconnect {
            consumedPrepare = consumedPrepare || distance <= Double(prepareBucket)
            consumedAction = consumedAction || distance <= actionDistance
            previousDistance = distance
            seedAfterReconnect = false
            return nil
        }

        let previous = previousDistance ?? distance
        previousDistance = distance
        let prepareCrossed = !consumedPrepare && previous > Double(prepareBucket) && distance <= Double(prepareBucket)
        let actionCrossed = !consumedAction && previous > actionDistance && distance <= actionDistance
        // Consumed BEFORE async enqueue, even if muted, invalid, or transport
        // rejects. A later preference/readiness change must not replay it.
        if prepareCrossed { consumedPrepare = true }
        if actionCrossed { consumedAction = true }
        let arrivalAtEntry = entered && maneuver == .arrive && distance <= actionDistance
        let startAction = nearStart && distance >= 20 && distance <= actionDistance
        let actionDue = actionCrossed || startAction || arrivalAtEntry
        if actionDue { consumedAction = true }
        guard usable else { return nil }

        let phase: SpokenPhaseV1
        let selected: SpokenManeuverV1
        if actionDue {
            // A passed ordinary maneuver is stale; arrival is intentionally
            // processed before NavigationEngine's <20 m terminal stop.
            guard maneuver == .arrive || distance >= 20 else { return nil }
            phase = maneuver == .arrive ? .arrival : .action
            selected = maneuver == .unknown ? .continueRoute : maneuver
        } else if prepareCrossed {
            guard distance - actionDistance >= minimumGap,
                  lastPreparedDistance == nil, maneuver != .unknown, maneuver != .continueRoute,
                  maneuver != .arrive else { return nil }
            phase = .prepare
            selected = maneuver
            lastPreparedDistance = distance
        } else { return nil }
        guard sequence != .max else { stop(); return nil }
        sequence += 1
        let cue = SpokenCueV1(token: token, generation: generation, sequence: sequence,
                              stepID: step.id, progressRevision: progressRevision, phase: phase,
                              maneuver: selected, distanceBucket: phase == .prepare ? prepareBucket : 0,
                              volume: volume, startLifetimeMS: 5000, assetKey: Data(repeating: 0, count: 16))
        return SpokenCueDecisionV1(cue: cue, startDeadline: uptime + 5)
    }
}
