import Combine
import Foundation

nonisolated struct WorkoutServiceActivityTracker: Sendable {
    static let reconnectionGracePeriod: TimeInterval = 5 * 60
    private(set) var unverifiedSince: Date?

    mutating func shouldMaintainServices(
        for presentation: WorkoutMirrorPresentationV1,
        at date: Date
    ) -> Bool {
        guard presentation.isWorkoutActive else {
            unverifiedSince = nil
            return false
        }
        switch presentation.connectionState {
        case .awaitingFirstSnapshot, .connected:
            unverifiedSince = nil
            return true
        case .stale, .disconnected:
            let graceStartedAt = unverifiedSince ?? date
            unverifiedSince = graceStartedAt
            return date.timeIntervalSince(graceStartedAt)
                <= Self.reconnectionGracePeriod
        case .unsupported, .idle, .launchingWatch, .ended, .failed:
            unverifiedSince = nil
            return false
        }
    }
}

/// Main-actor publication boundary for all Watch-owned workout state shown on
/// iPhone. The store never writes HealthKit data or persists raw health metrics.
@MainActor
final class WorkoutMetricsStore: ObservableObject {
    @Published private(set) var presentation: WorkoutMirrorPresentationV1
    @Published private(set) var shouldMaintainWorkoutServices: Bool

    private var reducer: WorkoutMirrorStateReducer
    private var iPhoneTelemetry: WorkoutIPhoneTelemetryV1 = .empty
    private var fallbackSessionID: UUID?
    private var navigationDistanceBaseline: Double?
    private var lastNavigationDistanceMeters: Double?
    private var completedNavigationDistanceMeters: Double = 0
    private var wasNavigationDistanceAdvancing = false
    private let now: () -> Date
    private var workoutServiceActivityTracker: WorkoutServiceActivityTracker

    var currentEnvelope: WorkoutEnvelopeV1? {
        reducer.latestEnvelope
    }

    var currentPendingControlSequence: UInt64? {
        reducer.pendingControlSequence
    }

    var supportsSegmentMarking: Bool {
        guard let version = reducer.latestEnvelope?.schemaVersion else {
            return false
        }
        return version.major == WorkoutSchemaVersion.current.major
            && version.minor >= 4
    }

    var isSegmentConfirmationPending: Bool {
        reducer.isSegmentConfirmationPending
    }

    var currentUnconfirmedSegmentControlSequence: UInt64? {
        reducer.currentUnconfirmedSegmentControlSequence
    }

    var canResetTerminalPresentation: Bool {
        reducer.canResetTerminalPresentation
    }

    init(
        reducer: WorkoutMirrorStateReducer = WorkoutMirrorStateReducer(),
        now: @escaping () -> Date = Date.init
    ) {
        self.reducer = reducer
        self.now = now
        let referenceDate = now()
        let presentation = WorkoutIPhoneTelemetryMerge.presentation(
            reducer.presentation,
            phone: .empty,
            at: referenceDate
        )
        var workoutServiceActivityTracker = WorkoutServiceActivityTracker()
        self.presentation = presentation
        shouldMaintainWorkoutServices =
            workoutServiceActivityTracker.shouldMaintainServices(
                for: presentation,
                at: referenceDate
            )
        self.workoutServiceActivityTracker = workoutServiceActivityTracker
    }

    @discardableResult
    func beginWatchLaunch(
        id: UUID,
        at date: Date,
        timeout: TimeInterval
    ) -> Bool {
        let admitted = reducer.beginWatchLaunch(
            id: id,
            at: date,
            timeout: timeout
        )
        publish()
        return admitted
    }

    @discardableResult
    func completeWatchLaunch(
        id: UUID,
        succeeded: Bool,
        error: WorkoutSafeErrorCodeV1?
    ) -> Bool {
        let completed = reducer.completeWatchLaunch(
            id: id,
            succeeded: succeeded,
            error: error
        )
        publish()
        return completed
    }

    @discardableResult
    func timeOutWatchLaunch(id: UUID, at date: Date) -> Bool {
        let didTimeOut = reducer.timeOutWatchLaunch(id: id, at: date)
        publish()
        return didTimeOut
    }

    func markUnsupported() {
        reducer.markUnsupported()
        publish()
    }

    func attachMirroredSession(at date: Date) {
        reducer.attachMirroredSession(at: date)
        publish()
    }

    @discardableResult
    func timeOutFirstSnapshot() -> Bool {
        let didTimeOut = reducer.timeOutFirstSnapshot()
        publish()
        return didTimeOut
    }

    @discardableResult
    func ingestBatch(
        _ envelopes: [WorkoutEnvelopeV1],
        receivedAt: Date
    ) -> WorkoutEnvelopeBatchResult {
        let result = reducer.ingestBatch(envelopes, receivedAt: receivedAt)
        publish()
        return result
    }

    func confirmSessionState(
        _ state: WorkoutSessionStateV1,
        at date: Date
    ) {
        reducer.confirmSessionState(state, at: date)
        publish()
    }

    @discardableResult
    func markPendingControl(
        _ control: WorkoutControlV1,
        sequence: UInt64? = nil
    ) -> Bool {
        let accepted = reducer.markPendingControl(
            control,
            sequence: sequence
        )
        publish()
        return accepted
    }

    func failPendingControl(
        _ control: WorkoutControlV1,
        sequence: UInt64? = nil,
        error: WorkoutSafeErrorCodeV1
    ) {
        reducer.failPendingControl(
            control,
            sequence: sequence,
            error: error
        )
        publish()
    }

    func disconnect(error: WorkoutSafeErrorCodeV1?) {
        reducer.disconnect(error: error)
        publish()
    }

    func failSession(error: WorkoutSafeErrorCodeV1) {
        reducer.failSession(error: error)
        publish()
    }

    func awaitTerminalSnapshotAfterFailure(
        error: WorkoutSafeErrorCodeV1,
        at date: Date
    ) {
        reducer.awaitTerminalSnapshotAfterFailure(error: error, at: date)
        publish()
    }

    func clearTerminalFailureForNewSession() {
        reducer.clearTerminalFailureForNewSession()
        publish()
    }

    func refreshFreshness(at date: Date) {
        reducer.refreshFreshness(at: date)
        publish()
    }

    @discardableResult
    func timeOutFinalSnapshot() -> Bool {
        let didTimeOut = reducer.timeOutFinalSnapshot()
        publish()
        return didTimeOut
    }

    @discardableResult
    func resetTerminalPresentation() -> Bool {
        let didReset = reducer.resetTerminalPresentation()
        publish()
        return didReset
    }

    func updateNavigationFallback(
        isNavigating: Bool,
        distanceTraveledMeters: Double?,
        routeRemainingDistanceMeters: Double?,
        routeRemainingTime: TimeInterval?,
        instruction: String?,
        capturedAt: Date
    ) {
        iPhoneTelemetry.isNavigating = isNavigating
        iPhoneTelemetry.capturedAt = isNavigating ? capturedAt : nil
        iPhoneTelemetry.navigationDistanceMeters = isNavigating
            ? distanceTraveledMeters
            : nil
        iPhoneTelemetry.routeRemainingDistanceMeters = isNavigating
            ? routeRemainingDistanceMeters
            : nil
        iPhoneTelemetry.routeRemainingTime = isNavigating
            ? routeRemainingTime
            : nil
        iPhoneTelemetry.instruction = isNavigating ? instruction : nil
        publish()
    }

    func updateIPhoneLocationFallback(_ location: WorkoutLocationV1?) {
        iPhoneTelemetry.location = location
        publish()
    }

    private func publish() {
        let referenceDate = now()
        let base = reducer.presentation
        let merged = WorkoutIPhoneTelemetryMerge.presentation(
            base,
            phone: normalizedIPhoneTelemetry(for: base),
            at: referenceDate
        )
        let next: WorkoutMirrorPresentationV1
        if base.sessionState == .ended,
           base.snapshot.state.isActive,
           base.finalSnapshot == nil,
           base.sessionID != nil,
           base.sessionID == presentation.sessionID,
           presentation.snapshot.state.isActive {
            // Native HealthKit can report ended before the final Watch
            // envelope. Freeze the last coherent, already-merged active
            // snapshot so phone fallback does not disappear or keep changing.
            // The authoritative ended Watch snapshot replaces it when it
            // arrives because its raw state is no longer active.
            next = WorkoutMirrorPresentationV1(
                connectionState: merged.connectionState,
                snapshot: presentation.snapshot,
                sessionID: merged.sessionID,
                capturedAt: presentation.capturedAt,
                receivedAt: presentation.receivedAt,
                confirmedSessionState: merged.confirmedSessionState,
                errorCode: merged.errorCode,
                pendingControl: merged.pendingControl,
                finalSnapshot: merged.finalSnapshot,
                navigation: merged.navigation
            )
        } else {
            next = merged
        }
        let nextShouldMaintainWorkoutServices =
            workoutServiceActivityTracker.shouldMaintainServices(
                for: next,
                at: referenceDate
            )
        if nextShouldMaintainWorkoutServices
            != shouldMaintainWorkoutServices {
            shouldMaintainWorkoutServices =
                nextShouldMaintainWorkoutServices
        }
        guard next != presentation else { return }
        presentation = next
    }

    /// Navigation distance starts independently from a Watch workout. Capture
    /// a per-session baseline so a ride that was already navigating does not
    /// attribute pre-workout distance to the workout fallback.
    private func normalizedIPhoneTelemetry(
        for base: WorkoutMirrorPresentationV1
    ) -> WorkoutIPhoneTelemetryV1 {
        guard base.isWorkoutActive,
              let sessionID = base.sessionID else {
            resetNavigationDistanceFallback()
            return iPhoneTelemetry
        }

        if fallbackSessionID != sessionID {
            resetNavigationDistanceFallback()
            fallbackSessionID = sessionID
        }

        var normalized = iPhoneTelemetry
        guard iPhoneTelemetry.isNavigating,
              let currentDistance = validNavigationDistance(
                  iPhoneTelemetry.navigationDistanceMeters
              ) else {
            finishCurrentNavigationDistanceSegment()
            navigationDistanceBaseline = nil
            lastNavigationDistanceMeters = nil
            wasNavigationDistanceAdvancing = false
            normalized.navigationDistanceMeters = nil
            return normalized
        }

        guard base.sessionState == .running else {
            if wasNavigationDistanceAdvancing {
                finishCurrentNavigationDistanceSegment(
                    endingAt: currentDistance
                )
            }
            // Follow the raw navigation counter while paused/ending without
            // adding that movement. Resuming starts a fresh counted segment
            // from the newest value, including after a navigation restart.
            navigationDistanceBaseline = currentDistance
            lastNavigationDistanceMeters = currentDistance
            wasNavigationDistanceAdvancing = false
            normalized.navigationDistanceMeters =
                completedNavigationDistanceMeters
            return normalized
        }

        if !wasNavigationDistanceAdvancing {
            navigationDistanceBaseline = currentDistance
            lastNavigationDistanceMeters = currentDistance
            wasNavigationDistanceAdvancing = true
        } else if let previousNavigationDistance = lastNavigationDistanceMeters,
                  currentDistance < previousNavigationDistance {
            // Navigation restarted while the workout remained active. Bank
            // the completed segment before baselining the new counter.
            finishCurrentNavigationDistanceSegment()
            navigationDistanceBaseline = currentDistance
            lastNavigationDistanceMeters = currentDistance
        } else {
            lastNavigationDistanceMeters = currentDistance
        }

        if let navigationDistanceBaseline {
            normalized.navigationDistanceMeters =
                completedNavigationDistanceMeters
                + max(0, currentDistance - navigationDistanceBaseline)
        }
        return normalized
    }

    private func finishCurrentNavigationDistanceSegment(
        endingAt explicitDistance: Double? = nil
    ) {
        guard wasNavigationDistanceAdvancing,
              let baseline = navigationDistanceBaseline,
              let end = explicitDistance ?? lastNavigationDistanceMeters,
              end >= baseline else {
            return
        }
        completedNavigationDistanceMeters += end - baseline
    }

    private func resetNavigationDistanceFallback() {
        fallbackSessionID = nil
        navigationDistanceBaseline = nil
        lastNavigationDistanceMeters = nil
        completedNavigationDistanceMeters = 0
        wasNavigationDistanceAdvancing = false
    }

    private func validNavigationDistance(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
