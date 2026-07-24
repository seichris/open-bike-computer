import Foundation

@available(iOS 17.0, *)
nonisolated struct WorkoutLiveActivityMappedPresentation: Equatable, Sendable {
    let attributes: WorkoutLiveActivityAttributes
    let contentState: WorkoutLiveActivityAttributes.ContentState
    let isStartEligible: Bool

    var isTerminal: Bool {
        contentState.phase == .final
    }
}

@available(iOS 17.0, *)
nonisolated enum WorkoutLiveActivityStateMapper {
    static func map(
        _ presentation: WorkoutMirrorPresentationV1,
        at referenceDate: Date,
        supportsSegmentMarking: Bool = true,
        isSegmentConfirmationPending: Bool = false
    ) -> WorkoutLiveActivityMappedPresentation? {
        let snapshot = presentation.finalSnapshot ?? presentation.snapshot
        guard let sessionID = presentation.sessionID,
              let startDate = snapshot.startDate
                ?? presentation.snapshot.startDate,
              startDate <= referenceDate,
              let capturedAt = validCaptureDate(
                  presentation.capturedAt
                    ?? snapshot.elapsedTime?.capturedAt
                    ?? snapshot.cyclingDistance?.capturedAt,
                  notBefore: startDate,
                  at: referenceDate
              ),
              let phase = phase(
                  for: presentation,
                  snapshot: snapshot
              ) else {
            return nil
        }

        let hidesInstantaneousMetrics = [
            .stale,
            .disconnected,
            .ending,
            .final,
        ].contains(phase)
        let segment = validSegment(snapshot.lastCompletedSegment)
        let pendingAction = pendingAction(presentation.pendingControl)
        let finalOutcome = finalOutcome(snapshot.terminalOutcome)

        let state = WorkoutLiveActivityAttributes.ContentState(
            phase: phase,
            capturedAt: capturedAt,
            elapsedActiveSeconds: metric(
                snapshot.elapsedTime,
                unit: .seconds,
                allowZero: true
            ),
            currentSpeedKilometersPerHour: hidesInstantaneousMetrics
                ? nil
                : metric(
                    snapshot.currentSpeed,
                    unit: .metersPerSecond,
                    allowZero: true
                ).flatMap {
                    let kilometersPerHour = $0 * 3.6
                    return kilometersPerHour.isFinite
                        ? kilometersPerHour
                        : nil
                },
            cyclingDistanceMeters: metric(
                snapshot.cyclingDistance,
                unit: .meters,
                allowZero: true
            ),
            currentHeartRateBPM: hidesInstantaneousMetrics
                ? nil
                : metric(
                    snapshot.currentHeartRate,
                    unit: .beatsPerMinute,
                    allowZero: false
                ),
            lastCompletedSegmentIndex: segment?.index,
            lastCompletedSegmentDuration: segment?.duration,
            lastCompletedSegmentDistanceMeters: segment?.distanceMeters,
            isSegmentControlAvailable: supportsSegmentMarking
                && !isSegmentConfirmationPending,
            pendingAction: pendingAction,
            finalOutcome: finalOutcome,
            displayError: displayError(
                phase: phase,
                errorCode: presentation.errorCode
                    ?? snapshot.errorCode
            )
        )
        let isStartEligible = presentation.connectionState == .connected
            && (phase == .running || phase == .paused)
            && presentation.pendingControl != .endAndSave
            && presentation.pendingControl != .discard

        return WorkoutLiveActivityMappedPresentation(
            attributes: WorkoutLiveActivityAttributes(
                sessionID: sessionID,
                workoutStartDate: startDate
            ),
            contentState: state,
            isStartEligible: isStartEligible
        )
    }

    private static func phase(
        for presentation: WorkoutMirrorPresentationV1,
        snapshot: WorkoutSnapshotV1
    ) -> WorkoutLiveActivityPhase? {
        let errorCode = presentation.errorCode ?? snapshot.errorCode
        if snapshot.terminalOutcome != nil
            || errorCode == .finalSummaryUnavailable {
            return .final
        }
        if presentation.connectionState == .ended
            || presentation.sessionState == .ended {
            return .ending
        }

        switch presentation.connectionState {
        case .stale:
            return presentation.isWorkoutActive ? .stale : nil
        case .disconnected:
            return presentation.isWorkoutActive ? .disconnected : nil
        case .failed:
            return presentation.isWorkoutActive ? .stale : nil
        case .connected:
            switch presentation.sessionState {
            case .running:
                return .running
            case .paused:
                return .paused
            case .ending:
                return .ending
            case .ended:
                return .final
            case .idle, .starting, .failed:
                return nil
            }
        case .unsupported, .idle, .launchingWatch, .awaitingFirstSnapshot:
            return nil
        case .ended:
            return .final
        }
    }

    private static func pendingAction(
        _ control: WorkoutControlV1?
    ) -> WorkoutLiveActivityPendingAction {
        switch control {
        case .markSegment:
            return .segment
        case .pause:
            return .pause
        case .resume:
            return .resume
        case .endAndSave:
            return .endAndSave
        case .discard:
            return .discard
        case .requestCurrentSnapshot, nil:
            return .none
        }
    }

    private static func finalOutcome(
        _ outcome: WorkoutTerminalOutcomeV1?
    ) -> WorkoutLiveActivityFinalOutcome {
        switch outcome {
        case .saved:
            return .saved
        case .discarded:
            return .discarded
        case nil:
            return .none
        }
    }

    private static func displayError(
        phase: WorkoutLiveActivityPhase,
        errorCode: WorkoutSafeErrorCodeV1?
    ) -> WorkoutLiveActivityDisplayError {
        switch errorCode {
        case .segmentMarkFailed:
            return .segmentRejected
        case .segmentMarkUnconfirmed:
            return .segmentUnconfirmed
        case .terminalChoiceUnconfirmed:
            return phase == .final
                ? .finalSummaryUnavailable
                : .controlsUnavailable
        case .finalSummaryUnavailable:
            return .finalSummaryUnavailable
        default:
            if phase == .stale || phase == .disconnected {
                return .controlsUnavailable
            }
            return .none
        }
    }

    private static func metric(
        _ metric: WorkoutMetricV1?,
        unit: WorkoutMetricUnitV1,
        allowZero: Bool
    ) -> Double? {
        guard let metric,
              metric.unit == unit,
              metric.value.isFinite,
              allowZero ? metric.value >= 0 : metric.value > 0 else {
            return nil
        }
        return metric.value
    }

    private static func validSegment(
        _ segment: WorkoutCompletedSegmentV1?
    ) -> WorkoutCompletedSegmentV1? {
        guard let segment,
              segment.index > 0,
              segment.startedAt <= segment.endedAt,
              segment.duration.isFinite,
              segment.duration >= 0,
              segment.distanceMeters == nil
                || (
                    segment.distanceMeters?.isFinite == true
                        && (segment.distanceMeters ?? -1) >= 0
                ) else {
            return nil
        }
        return segment
    }

    private static func validCaptureDate(
        _ date: Date?,
        notBefore startDate: Date,
        at referenceDate: Date
    ) -> Date? {
        guard let date,
              date >= startDate,
              date <= referenceDate.addingTimeInterval(
                  WorkoutMirrorStateReducer.maximumFutureCaptureSkew
              ) else {
            return nil
        }
        return date
    }
}
