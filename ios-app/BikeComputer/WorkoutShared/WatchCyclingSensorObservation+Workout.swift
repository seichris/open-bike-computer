import Foundation

extension WatchCyclingSensorObservationV1 {
    init?(envelope: WorkoutEnvelopeV1) {
        guard let snapshot = envelope.snapshot else { return nil }
        self.init(
            sessionID: envelope.sessionID,
            snapshot: snapshot,
            capturedAt: envelope.capturedAt
        )
    }

    init?(
        sessionID: UUID,
        snapshot: WorkoutSnapshotV1,
        capturedAt: Date
    ) {
        // An idle envelope may precede a real workout identity. Only an
        // ended/failed snapshot (or confirmed recovery with no envelope) is
        // an authoritative inactivity event.
        guard snapshot.state != .idle else { return nil }
        func observedAt(_ metric: WorkoutMetricV1?) -> Date? {
            guard snapshot.state.isActive, let metric,
                Self.isFresh(
                    metric.capturedAt, at: capturedAt,
                    maximumAge: Self.discoveryFreshness
                )
            else { return nil }
            return metric.capturedAt
        }
        self.init(
            sessionID: sessionID,
            sessionStartedAt: snapshot.startDate,
            capturedAt: capturedAt,
            isWorkoutActive: snapshot.state.isActive,
            cadenceObservedAt: observedAt(snapshot.cyclingCadence),
            powerObservedAt: observedAt(snapshot.cyclingPower)
        )
        guard isValid else { return nil }
    }
}
