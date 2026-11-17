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

/// Main-actor publication boundary for the selected recorder on iPhone. The store never writes HealthKit data or persists raw health metrics.
@MainActor
final class WorkoutMetricsStore: ObservableObject {
    @Published var recordingOwner: WorkoutRecordingOwner = .watch
    @Published var recordingMessage: String?
    @Published private(set) var presentation: WorkoutMirrorPresentationV1
    @Published private(set) var shouldMaintainWorkoutServices: Bool
    @Published private(set) var currentHeartRateZoneElapsedTime: TimeInterval?

    weak var diagnosticsRecorder: (any RideDiagnosticsEventSink)?

    private var reducer: WorkoutMirrorStateReducer
    private var rideContinuation: WorkoutRideContinuation?
    private var iPhoneTelemetry: WorkoutIPhoneTelemetryV1 = .empty
    private var fallbackSessionID: UUID?
    private var navigationDistanceBaseline: Double?
    private var lastNavigationDistanceMeters: Double?
    private var completedNavigationDistanceMeters: Double = 0
    private var wasNavigationDistanceAdvancing = false
    private var heartRateZoneDurationAccumulator =
        WorkoutHeartRateZoneDurationAccumulator()
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
        currentHeartRateZoneElapsedTime = nil
        shouldMaintainWorkoutServices =
            workoutServiceActivityTracker.shouldMaintainServices(
                for: presentation,
                at: referenceDate
            )
        self.workoutServiceActivityTracker = workoutServiceActivityTracker
    }

    /// An isolated local recorder reuses the validated snapshot/presentation
    /// reducer without sharing a transport or state with Watch mirroring.
    func beginLocalWorkout() {
        reducer = WorkoutMirrorStateReducer()
        reducer.attachMirroredSession(at: now())
        recordingOwner = .iphone
        publish()
    }

    /// The coordinator's output store retains its own navigation context. Only
    /// the selected recorder's reducer is copied; late data from another owner
    /// never enters this store or the bike-computer telemetry path. A ride
    /// continued on iPhone adds the Watch part's persisted totals for display.
    func followWorkoutState(
        from source: WorkoutMetricsStore,
        owner: WorkoutRecordingOwner,
        continuation: WorkoutRideContinuation? = nil
    ) {
        recordingOwner = owner
        recordingMessage = source.recordingMessage
        reducer = source.reducer
        rideContinuation = owner == .iphone ? continuation : nil
        publish()
    }

    /// Shows no workout. Used when the only observed Watch session is one the
    /// rider already continued on iPhone, so it cannot reappear as a new ride.
    func followNoWorkout(owner: WorkoutRecordingOwner) {
        recordingOwner = owner
        recordingMessage = nil
        reducer = WorkoutMirrorStateReducer()
        rideContinuation = nil
        publish()
    }

    @discardableResult
    func releaseHandedOffSession(_ sessionID: UUID) -> Bool {
        let released = reducer.releaseHandedOffSession(sessionID)
        if released { publish() }
        return released
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

    func preemptPendingControlForManualAction() {
        reducer.preemptPendingControlForManualAction()
        publish()
    }

    /// Let native lifecycle controls proceed without admitting another segment
    /// while the original HealthKit write still has an unknown outcome.
    func releasePendingSegmentForLifecycleControl() {
        guard presentation.pendingControl == .markSegment,
              let sequence = currentPendingControlSequence else { return }
        failPendingControl(.markSegment, sequence: sequence,
                           error: .segmentMarkUnconfirmed)
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
    func reconcileSavedWorkout(_ saved: WorkoutSavedInFitness) -> Bool {
        let reconciled = reducer.reconcileSavedWorkout(saved)
        if reconciled { publish() }
        return reconciled
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
        var merged = WorkoutIPhoneTelemetryMerge.presentation(
            base,
            phone: normalizedIPhoneTelemetry(for: base),
            at: referenceDate
        )
        if let rideContinuation {
            // Applied once to fresh reducer output; the frozen branch below
            // reuses the previous, already combined snapshot unchanged.
            merged = WorkoutRideContinuationMath.presentation(
                merged, continuation: rideContinuation
            )
        }
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
        let nextHeartRateZoneElapsedTime =
            heartRateZoneDurationAccumulator.update(
                sessionID: next.sessionID,
                elapsedTime: next.snapshot.elapsedTime?.value,
                currentZone: next.snapshot.currentHeartRateZone,
                authoritativeDurations:
                    next.snapshot.heartRateZoneDurations
            )
        if nextHeartRateZoneElapsedTime
            != currentHeartRateZoneElapsedTime {
            currentHeartRateZoneElapsedTime =
                nextHeartRateZoneElapsedTime
        }
        if nextShouldMaintainWorkoutServices
            != shouldMaintainWorkoutServices {
            shouldMaintainWorkoutServices =
                nextShouldMaintainWorkoutServices
        }
        guard next != presentation else { return }
        let stateChanged = presentation.sessionState != next.sessionState
            || presentation.connectionState != next.connectionState
            || presentation.pendingControl != next.pendingControl
            || presentation.errorCode != next.errorCode
            || (presentation.sessionID != nil) != (next.sessionID != nil)
        if stateChanged {
            var fields: [String: String] = [
                "state": next.sessionState.rawValue,
                "connectionState": next.connectionState.rawValue,
                "active": String(next.isWorkoutActive),
                "sessionPresent": String(next.sessionID != nil),
                "pendingControl": next.pendingControl?.rawValue ?? "none",
            ]
            if let errorCode = next.errorCode {
                fields["code"] = errorCode.rawValue
            }
            diagnosticsRecorder?.record(
                level: next.errorCode == nil ? .info : .warning,
                category: .workout,
                event: "state_changed",
                fields: fields,
                captureId: nil
            )
        }
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
        if recordingOwner == .iphone {
            normalized.navigationDistanceMeters = nil
            return normalized
        }
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

/// One ride, two recorders: the Watch part before an explicit Continue on
/// iPhone, an unrecorded gap, then the iPhone part.
nonisolated struct WorkoutRideContinuationSummary: Equatable, Sendable {
    struct Part: Equatable, Sendable {
        let startedAt: Date
        /// Nil while the part is still recording or its end is unknown.
        let endedAt: Date?
        let movingTime: TimeInterval?
        let distanceMeters: Double?
        /// Set once the part has ended and its own outcome is known.
        var outcome: WorkoutTerminalOutcomeV1? = nil
    }

    let watch: Part
    /// Nil until both the Watch end and the iPhone start are known.
    let gap: DateInterval?
    /// Nil until the iPhone recorder confirms its start.
    let phone: Part?
    let watchSaved: Bool
    let watchRecordedPastHandoff: Bool
    let handoffAt: Date

    var totalMovingTime: TimeInterval? {
        let values = [watch.movingTime, phone?.movingTime].compactMap { $0 }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    var totalDistanceMeters: Double? {
        let values = [watch.distanceMeters, phone?.distanceMeters].compactMap { $0 }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

/// Display arithmetic for a ride continued on iPhone. HealthKit and the iPhone
/// recorder keep only the iPhone part; the coordinator's output (dashboard,
/// Live Activity and bike computer) shows the whole ride. The gap behaves like
/// an unrecorded pause: it adds wall time but never moving time or distance.
nonisolated enum WorkoutRideContinuationMath {
    typealias WatchEvidence = WorkoutRideContinuation.WatchEvidence

    /// The Watch part as last seen before the rider chose to continue.
    static func watchPart(
        for record: WorkoutRecordingRecord,
        presentation: WorkoutMirrorPresentationV1
    ) -> WorkoutRideContinuation.WatchPart? {
        let observed = presentation.sessionID == record.sessionID
        let snapshot = presentation.finalSnapshot ?? presentation.snapshot
        guard let startedAt = record.startedAt ?? (observed ? snapshot.startDate : nil)
        else { return nil }
        var part = WorkoutRideContinuation.WatchPart(
            sessionID: record.sessionID,
            requestedAt: record.requestedAt,
            startedAt: startedAt
        )
        // The latest snapshot already happened; take it as the Watch part's
        // end even if the Watch clock runs slightly ahead of iPhone's.
        if observed, let evidence = evidence(from: presentation),
           evidence.capturedAt >= startedAt {
            part.endedAt = evidence.capturedAt
            part.movingTime = nonnegative(evidence.movingTime)
            part.distanceMeters = nonnegative(evidence.distanceMeters)
            part.activeKilocalories = nonnegative(evidence.activeKilocalories)
            part.averageHeartRate = evidence.averageHeartRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            part.savedInFitness = evidence.savedInFitness
        }
        return part
    }

    static func evidence(from presentation: WorkoutMirrorPresentationV1) -> WatchEvidence? {
        let snapshot = presentation.finalSnapshot ?? presentation.snapshot
        guard snapshot.startDate != nil,
              let capturedAt = presentation.capturedAt ?? snapshot.elapsedTime?.capturedAt
        else { return nil }
        return WatchEvidence(
            capturedAt: capturedAt,
            movingTime: snapshot.elapsedTime?.value,
            distanceMeters: snapshot.cyclingDistance?.value,
            activeKilocalories: snapshot.activeEnergy?.value,
            averageHeartRate: snapshot.averageHeartRate?.value,
            savedInFitness: snapshot.state == .ended && snapshot.terminalOutcome == .saved
        )
    }

    static func evidence(from saved: WorkoutSavedInFitness) -> WatchEvidence {
        WatchEvidence(
            capturedAt: saved.endDate,
            movingTime: saved.duration,
            distanceMeters: saved.distanceMeters,
            activeKilocalories: saved.activeKilocalories,
            savedInFitness: true
        )
    }

    static func presentation(
        _ presentation: WorkoutMirrorPresentationV1,
        continuation: WorkoutRideContinuation
    ) -> WorkoutMirrorPresentationV1 {
        WorkoutMirrorPresentationV1(
            connectionState: presentation.connectionState,
            snapshot: combined(presentation.snapshot, continuation: continuation),
            sessionID: presentation.sessionID,
            capturedAt: presentation.capturedAt,
            receivedAt: presentation.receivedAt,
            confirmedSessionState: presentation.confirmedSessionState,
            errorCode: presentation.errorCode,
            pendingControl: presentation.pendingControl,
            finalSnapshot: presentation.finalSnapshot.map {
                combined($0, continuation: continuation)
            },
            navigation: presentation.navigation,
            fitnessReconciliation: presentation.fitnessReconciliation
        )
    }

    /// Adds the Watch part to an iPhone-part snapshot. Live values (speed,
    /// heart rate, location, segments and zones) remain the iPhone's own.
    static func combined(
        _ snapshot: WorkoutSnapshotV1,
        continuation: WorkoutRideContinuation
    ) -> WorkoutSnapshotV1 {
        let watch = continuation.watch
        guard let phoneStart = snapshot.startDate,
              watch.startedAt <= phoneStart else { return snapshot }
        let beforePhone = phoneStart.timeIntervalSince(watch.startedAt)
        var availability = snapshot.availability
        func adding(
            _ metric: WorkoutMetricV1?, _ watchValue: Double?,
            unit: WorkoutMetricUnitV1, flag: WorkoutAvailabilityMaskV1,
            source: WorkoutMetricSourceV1? = nil
        ) -> WorkoutMetricV1? {
            guard let watchValue = nonnegative(watchValue), watchValue > 0 else { return metric }
            availability.insert(flag)
            guard let metric else {
                return WorkoutMetricV1(value: watchValue, unit: unit,
                                       capturedAt: phoneStart, source: source)
            }
            return WorkoutMetricV1(value: metric.value + watchValue, unit: metric.unit,
                                   capturedAt: metric.capturedAt, source: metric.source)
        }
        let averageHeartRate: WorkoutMetricV1?
        switch (snapshot.averageHeartRate, watch.averageHeartRate) {
        case let (phone?, watchAverage?):
            let phoneWeight = max(0, snapshot.elapsedTime?.value ?? 0)
            let watchWeight = max(0, watch.movingTime ?? 0)
            let total = phoneWeight + watchWeight
            averageHeartRate = total > 0
                ? WorkoutMetricV1(
                    value: (phone.value * phoneWeight + watchAverage * watchWeight) / total,
                    unit: phone.unit, capturedAt: phone.capturedAt, source: phone.source)
                : phone
        case let (nil, watchAverage?):
            availability.insert(.averageHeartRate)
            averageHeartRate = WorkoutMetricV1(value: watchAverage, unit: .beatsPerMinute,
                                               capturedAt: phoneStart, source: .healthKit)
        case (let phone, nil):
            averageHeartRate = phone
        }
        let elapsed = adding(snapshot.elapsedTime, watch.movingTime,
                             unit: .seconds, flag: .elapsedTime, source: .healthKit)
        let energy = adding(snapshot.activeEnergy, watch.activeKilocalories,
                            unit: .kilocalories, flag: .activeEnergy, source: .healthKit)
        let distance = adding(snapshot.cyclingDistance, watch.distanceMeters,
                              unit: .meters, flag: .cyclingDistance, source: .healthKit)
        let wallElapsed = snapshot.wallElapsedTime.map {
            WorkoutMetricV1(value: $0.value + beforePhone, unit: $0.unit,
                            capturedAt: $0.capturedAt, source: $0.source)
        }
        return WorkoutSnapshotV1(
            state: snapshot.state,
            startDate: watch.startedAt,
            elapsedTime: elapsed,
            currentHeartRate: snapshot.currentHeartRate,
            averageHeartRate: averageHeartRate,
            activeEnergy: energy,
            cyclingDistance: distance,
            currentSpeed: snapshot.currentSpeed,
            cyclingPower: snapshot.cyclingPower,
            cyclingCadence: snapshot.cyclingCadence,
            currentHeartRateZone: snapshot.currentHeartRateZone,
            heartRateZoneCount: snapshot.heartRateZoneCount,
            heartRateZoneDurations: snapshot.heartRateZoneDurations,
            nativeZones: snapshot.nativeZones,
            location: snapshot.location,
            lastCompletedSegment: snapshot.lastCompletedSegment,
            availability: availability,
            errorCode: snapshot.errorCode,
            terminalOutcome: snapshot.terminalOutcome,
            pauseOrigin: snapshot.pauseOrigin,
            lastTransitionOrigin: snapshot.lastTransitionOrigin,
            lastTransitionAt: snapshot.lastTransitionAt,
            wallElapsedTime: wallElapsed,
            detectorProfileVersion: snapshot.detectorProfileVersion
        )
    }

    /// `phoneSnapshot` is the iPhone recorder's own snapshot, not the combined
    /// output. The iPhone part has an end only once its workout has ended.
    static func summary(
        continuation: WorkoutRideContinuation,
        phoneStartedAt: Date?,
        phoneSnapshot: WorkoutSnapshotV1?
    ) -> WorkoutRideContinuationSummary {
        let watch = continuation.watch
        let phone = phoneStartedAt.map { start -> WorkoutRideContinuationSummary.Part in
            let snapshot = phoneSnapshot
            let ended = snapshot?.state == .ended
            let end = ended
                ? (snapshot?.wallElapsedTime.map { start.addingTimeInterval($0.value) }
                    ?? snapshot?.elapsedTime?.capturedAt)
                : nil
            return WorkoutRideContinuationSummary.Part(
                startedAt: start,
                endedAt: end.map { max($0, start) },
                movingTime: nonnegative(snapshot?.elapsedTime?.value),
                distanceMeters: nonnegative(snapshot?.cyclingDistance?.value),
                outcome: ended ? snapshot?.terminalOutcome : nil
            )
        }
        return WorkoutRideContinuationSummary(
            watch: .init(startedAt: watch.startedAt, endedAt: watch.endedAt,
                         movingTime: watch.movingTime, distanceMeters: watch.distanceMeters),
            gap: continuation.gap(phoneStartedAt: phoneStartedAt),
            phone: phone,
            watchSaved: watch.savedInFitness,
            watchRecordedPastHandoff: watch.recordedPastHandoff,
            handoffAt: continuation.handoffAt
        )
    }

    private static func nonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
