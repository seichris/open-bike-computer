import Foundation

nonisolated enum WorkoutFinishDisposition: String, Codable, Equatable, Sendable {
    case save
    case discard
}

nonisolated enum WorkoutFinalizationPhase: String, Codable, Equatable, Sendable {
    case requested
    case collectionEnded
    /// Persisted before invoking `finishWorkout`. A process death in this
    /// phase leaves the HealthKit commit result unknown, so recovery must
    /// reconcile rather than invoke the save adapter again.
    case finishAttempted
    case workoutSaved
}

nonisolated enum WorkoutRouteSaveStatus: String, Codable, Equatable, Sendable {
    case present
    case unavailable
    case unknown
}

nonisolated enum WorkoutLifecycleEvent: Equatable, Sendable {
    case requestStart
    case sessionRunning
    case sessionPaused
    case requestEnd(WorkoutFinishDisposition)
    case sessionEnded
    case fail
    case reset
}

/// Keeps UI requests separate from HealthKit-confirmed state transitions.
/// Pause and resume intentionally have no optimistic event: callers ask the
/// session to change state and apply the delegate callback when HealthKit
/// confirms it.
nonisolated struct WorkoutLifecycleReducer: Equatable, Sendable {
    private(set) var state: WorkoutSessionStateV1 = .idle
    private(set) var finishDisposition: WorkoutFinishDisposition?
    private var finalizationClaimed = false

    @discardableResult
    mutating func apply(_ event: WorkoutLifecycleEvent) -> Bool {
        switch event {
        case .requestStart:
            guard [.idle, .ended, .failed].contains(state) else { return false }
            state = .starting
            finishDisposition = nil
            finalizationClaimed = false
        case .sessionRunning:
            guard [.starting, .running, .paused].contains(state) else { return false }
            state = .running
        case .sessionPaused:
            guard [.running, .paused].contains(state) else { return false }
            state = .paused
        case .requestEnd(let disposition):
            guard [.starting, .running, .paused].contains(state) else { return false }
            state = .ending
            finishDisposition = disposition
            finalizationClaimed = false
        case .sessionEnded:
            guard state == .ending else { return false }
            state = .ended
        case .fail:
            guard state != .ended else { return false }
            state = .failed
        case .reset:
            guard [.ended, .failed].contains(state) else { return false }
            state = .idle
            finishDisposition = nil
            finalizationClaimed = false
        }
        return true
    }

    /// Returns the requested disposition once and only once after HealthKit
    /// reports that the primary session stopped and builder finalization can
    /// begin while the system remains in workout-session mode.
    mutating func claimFinalization() -> WorkoutFinishDisposition? {
        guard state == .ending,
              !finalizationClaimed,
              let finishDisposition else {
            return nil
        }
        finalizationClaimed = true
        return finishDisposition
    }

    mutating func releaseFinalizationClaimForRetry() {
        guard state == .ending else { return }
        finalizationClaimed = false
    }

}

nonisolated enum WorkoutRecoveredSessionAdoptionAction: Equatable, Sendable {
    case adopt
    case adoptStopped(WorkoutFinishDisposition)
    case adoptEnded(WorkoutFinishDisposition)
}

nonisolated enum WorkoutRecoveredSessionAdoptionPolicy {
    static func action(
        wasEndedBeforeMetadataRepair: Bool,
        isEndedAfterMetadataRepair: Bool,
        isStoppedAfterMetadataRepair: Bool = false,
        pendingDisposition: WorkoutFinishDisposition?
    ) -> WorkoutRecoveredSessionAdoptionAction {
        if wasEndedBeforeMetadataRepair || isEndedAfterMetadataRepair {
            return .adoptEnded(pendingDisposition ?? .save)
        }
        if isStoppedAfterMetadataRepair {
            return .adoptStopped(pendingDisposition ?? .save)
        }
        return .adopt
    }
}

nonisolated struct WorkoutMetricCandidate: Equatable, Sendable {
    let value: Double
    let capturedAt: Date
    let source: WorkoutMetricSourceV1

    init(value: Double, capturedAt: Date, source: WorkoutMetricSourceV1) {
        self.value = value
        self.capturedAt = capturedAt
        self.source = source
    }

    var isUsable: Bool {
        value.isFinite
            && value >= 0
            && capturedAt.timeIntervalSinceReferenceDate.isFinite
    }
}

nonisolated enum WorkoutMetricPrecedence {
    static func cyclingDistance(
        healthKit: WorkoutMetricCandidate?,
        watchRoute: WorkoutMetricCandidate?
    ) -> WorkoutMetricCandidate? {
        firstUsable([
            healthKit.flatMap { $0.source == .healthKit ? $0 : nil },
            watchRoute.flatMap { $0.source == .watchRoute ? $0 : nil },
        ])
    }

    static func currentSpeed(
        pairedSensor: WorkoutMetricCandidate?,
        watchLocation: WorkoutMetricCandidate?
    ) -> WorkoutMetricCandidate? {
        firstUsable([
            pairedSensor.flatMap { $0.source == .pairedCyclingSensor ? $0 : nil },
            watchLocation.flatMap { $0.source == .watchLocation ? $0 : nil },
        ])
    }

    private static func firstUsable(
        _ candidates: [WorkoutMetricCandidate?]
    ) -> WorkoutMetricCandidate? {
        candidates.compactMap { $0 }.first(where: \.isUsable)
    }
}

/// Freshness limits apply only to instantaneous readings. Cumulative metrics
/// such as distance and active energy remain valid until HealthKit replaces
/// them with newer totals.
nonisolated enum WorkoutMetricFreshness {
    static let pairedCyclingSensorMaximumAge: TimeInterval = 5
    static let watchLocationMaximumAge: TimeInterval = 10
    static let heartRateMaximumAge: TimeInterval = 30

    static func isFresh(
        capturedAt: Date,
        now: Date,
        maximumAge: TimeInterval
    ) -> Bool {
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite,
              maximumAge.isFinite,
              maximumAge >= 0 else {
            return false
        }
        let age = now.timeIntervalSince(capturedAt)
        return age.isFinite && age >= 0 && age <= maximumAge
    }

    static func metric(
        _ metric: WorkoutMetricV1?,
        now: Date,
        maximumAge: TimeInterval
    ) -> WorkoutMetricV1? {
        guard let metric,
              isFresh(
                capturedAt: metric.capturedAt,
                now: now,
                maximumAge: maximumAge
              ) else {
            return nil
        }
        return metric
    }

    static func candidate(
        _ candidate: WorkoutMetricCandidate?,
        now: Date,
        maximumAge: TimeInterval
    ) -> WorkoutMetricCandidate? {
        guard let candidate,
              candidate.isUsable,
              isFresh(
                capturedAt: candidate.capturedAt,
                now: now,
                maximumAge: maximumAge
              ) else {
            return nil
        }
        return candidate
    }
}

nonisolated enum WorkoutElapsedTimePolicy {
    static func metric(
        builderElapsedTime: TimeInterval,
        startDate: Date?,
        capturedAt: Date
    ) -> WorkoutMetricV1? {
        guard let startDate,
              builderElapsedTime.isFinite,
              builderElapsedTime >= 0,
              startDate.timeIntervalSinceReferenceDate.isFinite,
              capturedAt.timeIntervalSinceReferenceDate.isFinite,
              capturedAt >= startDate else {
            return nil
        }
        return WorkoutMetricV1(
            value: builderElapsedTime,
            unit: .seconds,
            capturedAt: capturedAt,
            source: .healthKit
        )
    }
}

nonisolated struct WorkoutRoutePointCandidate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let capturedAt: Date
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
}

nonisolated enum WorkoutRoutePointFilter {
    static let maximumHorizontalAccuracy = 50.0
    static let maximumFutureSkew: TimeInterval = 2.0

    static func accepts(
        _ point: WorkoutRoutePointCandidate,
        workoutStart: Date,
        now: Date
    ) -> Bool {
        point.latitude.isFinite
            && (-90.0...90.0).contains(point.latitude)
            && point.longitude.isFinite
            && (-180.0...180.0).contains(point.longitude)
            && point.capturedAt.timeIntervalSinceReferenceDate.isFinite
            && point.capturedAt >= workoutStart
            && point.capturedAt <= now.addingTimeInterval(maximumFutureSkew)
            && point.horizontalAccuracy.isFinite
            && point.horizontalAccuracy >= 0
            && point.horizontalAccuracy <= maximumHorizontalAccuracy
            && point.verticalAccuracy.isFinite
    }
}

nonisolated enum WorkoutRouteSegmentFilter {
    static let maximumCyclingSpeedMetersPerSecond = 50.0

    static func accepts(
        distanceMeters: Double,
        interval: TimeInterval,
        maximumSpeed: Double = maximumCyclingSpeedMetersPerSecond
    ) -> Bool {
        distanceMeters.isFinite
            && distanceMeters >= 0
            && interval.isFinite
            && interval > 0
            && maximumSpeed.isFinite
            && maximumSpeed > 0
            && distanceMeters / interval <= maximumSpeed
    }
}

nonisolated enum WorkoutRouteQueuePolicy {
    /// Bounds retained-but-not-yet-written location data if HealthKit stalls.
    /// A route is abandoned on overflow instead of silently saving a partial
    /// path while the workout and live location metrics continue.
    static let maximumPendingPointCount = 200

    static func canAppend(currentCount: Int, incomingCount: Int) -> Bool {
        guard currentCount >= 0, incomingCount >= 0 else { return false }
        let (combinedCount, overflow) = currentCount.addingReportingOverflow(incomingCount)
        return !overflow && combinedCount <= maximumPendingPointCount
    }
}

nonisolated struct WorkoutRouteBatchQueue<Element> {
    private var pending: [Element] = []
    private(set) var insertedPointCount = 0
    private(set) var hasFailed = false

    var pendingCount: Int { pending.count }
    var isEmpty: Bool { pending.isEmpty }

    mutating func append(contentsOf elements: [Element]) -> Bool {
        guard !hasFailed,
              WorkoutRouteQueuePolicy.canAppend(
                currentCount: pending.count,
                incomingCount: elements.count
              ) else {
            return false
        }
        pending.append(contentsOf: elements)
        return true
    }

    mutating func takeNextBatch(maximumCount: Int = 20) -> [Element] {
        guard maximumCount > 0, !pending.isEmpty, !hasFailed else { return [] }
        let count = min(maximumCount, pending.count)
        let batch = Array(pending.prefix(count))
        pending.removeFirst(count)
        return batch
    }

    mutating func markInserted(count: Int) {
        guard count >= 0 else {
            markFailed()
            return
        }
        let (updatedCount, overflow) = insertedPointCount.addingReportingOverflow(count)
        guard !overflow else {
            markFailed()
            return
        }
        insertedPointCount = updatedCount
    }

    mutating func markFailed() {
        hasFailed = true
        pending.removeAll(keepingCapacity: false)
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: false)
        insertedPointCount = 0
        hasFailed = false
    }
}

nonisolated struct WorkoutRouteGenerationGate: Equatable, Sendable {
    private(set) var current: UInt64

    init(current: UInt64 = 0) {
        self.current = current
    }

    @discardableResult
    mutating func advance() -> UInt64 {
        current = current == UInt64.max ? 1 : current + 1
        return current
    }

    func accepts(_ generation: UInt64) -> Bool {
        generation == current
    }
}

/// Rejects delayed Core Location batches captured before the most recent
/// resume callback. This prevents paused points from entering the route merely
/// because the delegate batch arrived after the workout resumed.
nonisolated struct WorkoutRouteTimestampGate: Equatable, Sendable {
    private(set) var minimumAcceptedAt: Date

    init(workoutStart: Date) {
        minimumAcceptedAt = workoutStart
    }

    mutating func resume(at date: Date) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        minimumAcceptedAt = max(minimumAcceptedAt, date)
    }

    func accepts(_ capturedAt: Date) -> Bool {
        capturedAt.timeIntervalSinceReferenceDate.isFinite
            && capturedAt >= minimumAcceptedAt
    }
}

nonisolated enum WorkoutRouteFallbackPolicy {
    /// A recovered route may already contain points that are intentionally not
    /// persisted locally. New segments therefore cannot be represented as a
    /// trustworthy whole-workout total.
    static func canProvideTotal(mayContainExistingRouteData: Bool) -> Bool {
        !mayContainExistingRouteData
    }
}

nonisolated struct WorkoutRouteDistanceAccumulator: Equatable, Sendable {
    private let canProvideTotal: Bool
    private var hasSegmentAnchor = false
    private(set) var totalMeters: Double?

    init(mayContainExistingRouteData: Bool) {
        canProvideTotal = WorkoutRouteFallbackPolicy.canProvideTotal(
            mayContainExistingRouteData: mayContainExistingRouteData
        )
        totalMeters = nil
    }

    /// `segmentDistanceFromPrevious` is nil for the first point after start,
    /// pause, or resume. The first accepted point establishes a zero-distance
    /// total; later points add their already-validated segment distances.
    mutating func appendPoint(segmentDistanceFromPrevious: Double?) {
        guard canProvideTotal else { return }
        if !hasSegmentAnchor {
            hasSegmentAnchor = true
            if totalMeters == nil {
                totalMeters = 0
            }
            return
        }
        guard let segmentDistanceFromPrevious,
              segmentDistanceFromPrevious.isFinite,
              segmentDistanceFromPrevious >= 0 else {
            return
        }
        totalMeters = (totalMeters ?? 0) + segmentDistanceFromPrevious
    }

    mutating func breakSegment() {
        hasSegmentAnchor = false
    }
}

nonisolated struct WorkoutAssociatedRouteDecision: Equatable, Sendable {
    let keepBuilderForWorkout: Bool
    let routeStatus: WorkoutRouteSaveStatus

    var routeKnownPresent: Bool { routeStatus == .present }
}

nonisolated enum WorkoutAssociatedRoutePolicy {
    static func decision(
        insertedPointCount: Int,
        routeSavingFailed: Bool,
        mayContainExistingRouteData: Bool
    ) -> WorkoutAssociatedRouteDecision {
        guard !routeSavingFailed else {
            return WorkoutAssociatedRouteDecision(
                // A recovered associated builder can already contain route
                // samples written before this process launched. A later
                // insert failure makes route presence unknowable, but must
                // not erase those earlier samples by discarding the builder.
                keepBuilderForWorkout: mayContainExistingRouteData,
                routeStatus: mayContainExistingRouteData
                    ? .unknown
                    : .unavailable
            )
        }
        if insertedPointCount > 0 {
            return WorkoutAssociatedRouteDecision(
                keepBuilderForWorkout: true,
                routeStatus: .present
            )
        }
        return WorkoutAssociatedRouteDecision(
            keepBuilderForWorkout: mayContainExistingRouteData,
            routeStatus: mayContainExistingRouteData ? .unknown : .unavailable
        )
    }
}

nonisolated struct WorkoutPreparedRoute: Equatable, Sendable {
    let routeStatus: WorkoutRouteSaveStatus
    let distanceMeters: Double?

    var routeKnownPresent: Bool { routeStatus == .present }

    init(routeStatus: WorkoutRouteSaveStatus, distanceMeters: Double?) {
        self.routeStatus = routeStatus
        self.distanceMeters = distanceMeters
    }

    init(routeKnownPresent: Bool, distanceMeters: Double?) {
        self.init(
            routeStatus: routeKnownPresent ? .present : .unavailable,
            distanceMeters: distanceMeters
        )
    }
}

nonisolated enum WorkoutFinalizationOutcome: Equatable, Sendable {
    case saved(WorkoutPreparedRoute)
    case discarded
}

nonisolated enum WorkoutFinalizationPersistenceError: Error {
    /// HealthKit definitively reported that finishing failed, but the local
    /// rollback from commit-unknown to collection-ended was not persisted.
    /// The caller must retain that known callback result in memory and retry
    /// the rollback before invoking HealthKit finish again.
    case finishFailureRollbackPending
}

nonisolated enum WorkoutSaveFinalizationMode: Equatable, Sendable {
    case full
    case finishOnly
    case alreadySaved
}

nonisolated enum WorkoutSavedMatchState: Equatable, Sendable {
    case found
    case notFound
    case queryFailed
    case unavailable
}

nonisolated enum WorkoutRecoveredSaveAction: Equatable, Sendable {
    case finalize(WorkoutSaveFinalizationMode)
    case retryReconciliation
}

nonisolated enum WorkoutRecoveredSavePolicy {
    static func action(
        phase: WorkoutFinalizationPhase,
        builderCollectionEnded: Bool,
        matchingWorkout: WorkoutSavedMatchState
    ) -> WorkoutRecoveredSaveAction {
        if phase == .workoutSaved || matchingWorkout == .found {
            return .finalize(.alreadySaved)
        }
        if phase == .finishAttempted {
            // Neither a query failure nor a no-match response proves that the
            // earlier finishWorkout call failed to commit. Only a matching
            // saved workout can resolve this state without risking a duplicate.
            return .retryReconciliation
        }
        if matchingWorkout == .queryFailed {
            return .retryReconciliation
        }
        if phase == .collectionEnded || builderCollectionEnded {
            return .finalize(.finishOnly)
        }
        return .finalize(.full)
    }
}

nonisolated enum WorkoutFinalizationOrchestrator {
    /// Owns the exact save/discard call order. The Watch manager supplies thin
    /// HealthKit adapters, while tests supply recording closures and failures.
    @MainActor
    static func run(
        disposition: WorkoutFinishDisposition,
        saveMode: WorkoutSaveFinalizationMode = .full,
        discardWorkout: @MainActor () -> Void,
        discardRoute: @MainActor () -> Void,
        completeAlreadySavedRoute: @MainActor () -> Void = {},
        prepareRoute: @MainActor () async -> WorkoutPreparedRoute,
        recoveredRouteStatus: WorkoutRouteSaveStatus = .unknown,
        markPreparedRoute: @MainActor (WorkoutRouteSaveStatus) throws -> Void = { _ in },
        endCollection: @MainActor () async throws -> Void,
        markCollectionEnded: @MainActor () throws -> Void = {},
        markFinishAttempted: @MainActor () throws -> Void = {},
        finishWorkout: @MainActor () async throws -> Void,
        markFinishFailed: @MainActor () throws -> Void = {},
        markWorkoutSaved: @MainActor () throws -> Void = {},
        workoutSavedPersistenceFailed: @MainActor () -> Void = {},
        endSession: @MainActor () -> Void
    ) async throws -> WorkoutFinalizationOutcome {
        switch disposition {
        case .discard:
            discardWorkout()
            discardRoute()
            endSession()
            return .discarded
        case .save:
            switch saveMode {
            case .full:
                let route = await prepareRoute()
                try markPreparedRoute(route.routeStatus)
                try await endCollection()
                try markCollectionEnded()
                try markFinishAttempted()
                do {
                    try await finishWorkout()
                } catch {
                    do {
                        try markFinishFailed()
                    } catch {
                        throw WorkoutFinalizationPersistenceError
                            .finishFailureRollbackPending
                    }
                    throw error
                }
                do {
                    try markWorkoutSaved()
                } catch {
                    // The HealthKit callback is authoritative: the workout is
                    // saved even if the local phase marker cannot advance.
                    // Keep moving to session teardown and let the caller
                    // archive the durable finish-attempt identity safely.
                    workoutSavedPersistenceFailed()
                }
                endSession()
                return .saved(route)
            case .finishOnly:
                try markFinishAttempted()
                do {
                    try await finishWorkout()
                } catch {
                    do {
                        try markFinishFailed()
                    } catch {
                        throw WorkoutFinalizationPersistenceError
                            .finishFailureRollbackPending
                    }
                    throw error
                }
                do {
                    try markWorkoutSaved()
                } catch {
                    workoutSavedPersistenceFailed()
                }
                endSession()
                return .saved(
                    WorkoutPreparedRoute(
                        routeStatus: recoveredRouteStatus,
                        distanceMeters: nil
                    )
                )
            case .alreadySaved:
                completeAlreadySavedRoute()
                endSession()
                return .saved(
                    WorkoutPreparedRoute(
                        routeStatus: recoveredRouteStatus,
                        distanceMeters: nil
                    )
                )
            }
        }
    }
}

nonisolated enum WorkoutTerminalRouteDistancePolicy {
    static func candidate(
        distanceMeters: Double?,
        capturedAt: Date
    ) -> WorkoutMetricCandidate? {
        guard let distanceMeters,
              distanceMeters.isFinite,
              distanceMeters >= 0,
              capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            return nil
        }
        return WorkoutMetricCandidate(
            value: distanceMeters,
            capturedAt: capturedAt,
            source: .watchRoute
        )
    }
}

nonisolated enum WorkoutFinishCallbackOutcome: Equatable, Sendable {
    case saved
    case failed
}

nonisolated enum WorkoutFinishCallbackPolicy {
    /// HealthKit documents a nil workout with no error as a successful save
    /// when the saved object cannot be returned while the device is locked.
    static func outcome(
        workoutReturned: Bool,
        errorReturned: Bool
    ) -> WorkoutFinishCallbackOutcome {
        errorReturned ? .failed : .saved
    }
}

nonisolated enum WorkoutSessionFailureAction: Equatable, Sendable {
    case failStart
    case savePartialWorkout
    case finishRequestedDisposition
    case ignore
}

nonisolated enum WorkoutSessionFailurePolicy {
    static func action(
        for state: WorkoutSessionStateV1
    ) -> WorkoutSessionFailureAction {
        switch state {
        case .starting:
            .failStart
        case .running, .paused:
            .savePartialWorkout
        case .ending:
            .finishRequestedDisposition
        case .idle, .ended, .failed:
            .ignore
        }
    }
}

nonisolated enum WorkoutTerminalErrorPolicy {
    static func resolve(
        summaryError: WorkoutSafeErrorCodeV1?,
        persistedFinishError: WorkoutSafeErrorCodeV1?
    ) -> WorkoutSafeErrorCodeV1? {
        if summaryError == .anotherWorkoutActive
            || persistedFinishError == .anotherWorkoutActive {
            return .anotherWorkoutActive
        }
        return summaryError ?? persistedFinishError
    }
}

nonisolated enum WorkoutCrossAppTakeoverCopyV1 {
    static func live(disposition: WorkoutFinishDisposition) -> String {
        switch disposition {
        case .save:
            "Another workout app took over. BikeComputer is saving the partial ride."
        case .discard:
            "Another workout app took over. BikeComputer is discarding the partial ride as requested."
        }
    }

    static func summary(disposition: WorkoutFinishDisposition) -> String {
        switch disposition {
        case .save:
            "Another workout app took over. This is the partial BikeComputer ride saved before the handoff."
        case .discard:
            "Another workout app took over. The partial BikeComputer ride was discarded as requested."
        }
    }
}

nonisolated enum WorkoutRunningCallbackAction: Equatable, Sendable {
    case enterRunning
    case stopSession
    case ignore
}

nonisolated enum WorkoutRunningCallbackPolicy {
    static func action(
        for state: WorkoutSessionStateV1
    ) -> WorkoutRunningCallbackAction {
        switch state {
        case .starting, .running, .paused:
            .enterRunning
        case .ending:
            .stopSession
        case .idle, .ended, .failed:
            .ignore
        }
    }
}

nonisolated enum WorkoutRecoveryAttemptOutcome: Equatable, Sendable {
    case recovered
    case none
    case failed
}

nonisolated enum WorkoutRecoveryInitializationPolicy {
    static func shouldClearDurableIdentity(
        after outcome: WorkoutRecoveryAttemptOutcome
    ) -> Bool {
        outcome == .none
    }
}

nonisolated enum WorkoutRecoverySingleFlightPolicy {
    static func canStartRetry(
        isWorkoutActive: Bool,
        isRecovering: Bool
    ) -> Bool {
        !isWorkoutActive && !isRecovering
    }
}

nonisolated enum WorkoutFinalizationEndDatePolicy {
    static func resolve(
        authoritativeEndDate: Date?,
        callbackDate: Date
    ) -> Date {
        authoritativeEndDate ?? callbackDate
    }
}

nonisolated struct WorkoutSequenceLease: Equatable, Sendable {
    static let defaultSize: UInt64 = 1_024

    let lowerBound: UInt64
    let upperBound: UInt64
    private(set) var nextValue: UInt64

    init(after persistedHighWatermark: UInt64, size: UInt64 = defaultSize) {
        precondition(size > 0)
        if persistedHighWatermark == UInt64.max {
            self.lowerBound = UInt64.max
            self.upperBound = UInt64.max
            self.nextValue = 0
            return
        }
        let lowerBound = persistedHighWatermark + 1
        let (candidateUpperBound, overflow) = persistedHighWatermark.addingReportingOverflow(size)
        self.lowerBound = lowerBound
        self.upperBound = overflow ? UInt64.max : candidateUpperBound
        self.nextValue = lowerBound
    }

    var persistedHighWatermark: UInt64 { upperBound }

    mutating func take() -> UInt64? {
        guard nextValue != 0, nextValue <= upperBound else { return nil }
        let value = nextValue
        if nextValue == UInt64.max {
            nextValue = 0
        } else {
            nextValue += 1
        }
        return value
    }

    var isExhausted: Bool {
        nextValue == 0 || nextValue > upperBound
    }
}
