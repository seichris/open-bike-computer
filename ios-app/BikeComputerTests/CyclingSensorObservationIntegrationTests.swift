import Combine
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@MainActor
private final class SensorObservationClock {
    var date = Date(timeIntervalSinceReferenceDate: 800_100_000)
}

@MainActor
private final class SensorObservationFixture {
    let suiteName = "SensorObservationIntegration.\(UUID().uuidString)"
    let defaults: UserDefaults
    let clock = SensorObservationClock()
    let sessionID = UUID()
    let store: CyclingSensorStore
    let mirror: WorkoutMetricsStore
    let coordinator: CyclingSensorDetectionCoordinator
    let watch: CurrentValueSubject<WatchCyclingSensorObservationV1?, Never>

    init(cachedSampleAge: TimeInterval = 0) throws {
        defaults = UserDefaults(suiteName: suiteName)!
        let clock = self.clock
        store = CyclingSensorStore(defaults: defaults, now: { clock.date })
        mirror = WorkoutMetricsStore(now: { clock.date })
        coordinator = CyclingSensorDetectionCoordinator(
            sensorStore: store, now: { clock.date },
            dismissalDefaults: defaults
        )
        let cached = WatchCyclingSensorObservationV1(
            sessionID: sessionID,
            sessionStartedAt: clock.date.addingTimeInterval(-60),
            capturedAt: clock.date,
            isWorkoutActive: true,
            cadenceObservedAt: clock.date.addingTimeInterval(-cachedSampleAge)
        )
        // This is the same codec and current-value publication boundary used
        // after PhoneWatchConnectivityCoordinator reads receivedApplicationContext.
        let decoded = try WatchCyclingSensorObservationV1.decode(
            cached.encoded())
        watch = CurrentValueSubject<WatchCyclingSensorObservationV1?, Never>(
            decoded)
        coordinator.bind(
            to: mirror, watchObservations: watch.eraseToAnyPublisher())
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func presentation(
        connection: WorkoutMirrorConnectionStateV1 = .connected,
        state: WorkoutSessionStateV1 = .running,
        at date: Date? = nil
    ) -> WorkoutMirrorPresentationV1 {
        let date = date ?? clock.date
        return WorkoutMirrorPresentationV1(
            connectionState: connection,
            snapshot: WorkoutSnapshotV1(
                state: state,
                startDate: clock.date.addingTimeInterval(-60),
                cyclingCadence: WorkoutMetricV1(
                    value: 82, unit: .revolutionsPerMinute,
                    capturedAt: date, source: .healthKit
                ),
                availability: .cyclingCadence
            ),
            sessionID: sessionID, capturedAt: date, receivedAt: date,
            confirmedSessionState: state, errorCode: nil,
            pendingControl: nil, finalSnapshot: nil, navigation: .empty
        )
    }
}

@main
private enum CyclingSensorObservationIntegrationTests {
    @MainActor
    static func main() async throws {
        require(
            WatchCyclingSensorObservationV1(
                sessionID: UUID(), snapshot: WorkoutSnapshotV1(state: .idle),
                capturedAt: Date()
            ) == nil,
            "idle envelope cannot permanently retire a future workout identity")
        let fixture = try SensorObservationFixture(cachedSampleAge: 2)
        let originalSample = fixture.clock.date.addingTimeInterval(-2)
        require(
            fixture.mirror.presentation.connectionState == .idle,
            "fixture has no mirror")
        require(
            fixture.coordinator.candidates.count == 1,
            "cold-start cached Watch evidence discovers cadence")
        require(
            fixture.coordinator.candidates[0].lastObservedAt == originalSample,
            "candidate uses sample time, not receipt time")
        require(fixture.store.profiles.isEmpty, "discovery never auto-enrolls")
        let candidateID = fixture.coordinator.candidates[0].id
        for connection in [
            WorkoutMirrorConnectionStateV1.idle, .stale, .disconnected, .failed,
        ] {
            fixture.coordinator.ingest(
                fixture.presentation(connection: connection),
                at: fixture.clock.date)
            require(
                fixture.coordinator.hasActiveWorkout,
                "mirror availability cannot end Watch activity")
            require(
                fixture.coordinator.isReporting(
                    capabilities: .cadence, at: fixture.clock.date),
                "Watch reporting survives idle/stale/disconnected mirror")
            require(
                fixture.coordinator.candidates.first?.id == candidateID,
                "mirror loss cannot duplicate candidates")
        }
        fixture.mirror.disconnect(error: nil)
        fixture.mirror.failSession(error: .watchUnavailable)
        require(
            fixture.coordinator.hasActiveWorkout,
            "actual mirror-store publication preserves Watch evidence")
        fixture.coordinator.ingest(
            fixture.presentation(), at: fixture.clock.date)
        require(
            fixture.coordinator.candidates.count == 1,
            "dual-source observations deduplicate")
        let profile = fixture.store.enroll(
            name: "Crank", capabilities: .cadence)!
        fixture.coordinator.didEnroll(capabilities: .cadence)
        fixture.coordinator.ingest(
            fixture.presentation(), at: fixture.clock.date)
        fixture.watch.send(fixture.watch.value)
        require(
            fixture.store.profiles.count == 1
                && profile.identityKind == .logical,
            "explicit connection creates exactly one logical profile")
        require(
            fixture.coordinator.candidates.isEmpty
                && fixture.coordinator.activePrompt == nil,
            "enrollment suppresses duplicate candidates and prompts from both paths"
        )

        let endedAt = fixture.clock.date.addingTimeInterval(1)
        fixture.clock.date = endedAt
        fixture.watch.send(
            WatchCyclingSensorObservationV1(
                sessionID: fixture.sessionID,
                sessionStartedAt: endedAt.addingTimeInterval(-61),
                capturedAt: endedAt, isWorkoutActive: false
            ))
        require(
            !fixture.coordinator.hasActiveWorkout,
            "Watch end clears active status immediately")
        require(
            !fixture.coordinator.isReporting(
                capabilities: .cadence, at: endedAt),
            "Watch end immediately clears enrolled reporting")
        fixture.coordinator.ingest(
            fixture.presentation(at: endedAt.addingTimeInterval(-1)),
            at: endedAt)
        require(
            !fixture.coordinator.hasActiveWorkout,
            "late mirrored snapshot cannot revive an ended session")

        let dismissed = try SensorObservationFixture()
        dismissed.coordinator.dismissPrompt()
        dismissed.mirror.disconnect(error: nil)
        dismissed.watch.send(dismissed.watch.value)
        require(
            dismissed.coordinator.activePrompt == nil,
            "mirror outage does not reset same-workout dismissal")
        let restored = CyclingSensorDetectionCoordinator(
            sensorStore: dismissed.store, now: { dismissed.clock.date },
            dismissalDefaults: dismissed.defaults
        )
        restored.bind(
            to: dismissed.mirror,
            watchObservations: dismissed.watch.eraseToAnyPublisher())
        require(
            restored.activePrompt == nil,
            "Watch-only dismissal survives phone coordinator recreation")
        dismissed.clock.date.addTimeInterval(1)
        dismissed.watch.send(
            WatchCyclingSensorObservationV1(
                sessionID: UUID(), sessionStartedAt: dismissed.clock.date,
                capturedAt: dismissed.clock.date, isWorkoutActive: true,
                cadenceObservedAt: dismissed.clock.date
            ))
        require(
            restored.activePrompt?.capabilities == .cadence,
            "successor workout may prompt again")

        let stale = try SensorObservationFixture(cachedSampleAge: 6)
        require(
            stale.coordinator.candidates.isEmpty,
            "fresh context cannot rejuvenate stale sensor sample")
        require(
            !stale.coordinator.isReporting(
                capabilities: .cadence, at: stale.clock.date),
            "stale sample is not Reporting")
        stale.watch.send(
            WatchCyclingSensorObservationV1(
                sessionID: stale.sessionID,
                sessionStartedAt: stale.clock.date.addingTimeInterval(-60),
                capturedAt: stale.clock.date.addingTimeInterval(1),
                isWorkoutActive: true,
                cadenceObservedAt: stale.clock.date.addingTimeInterval(1)
            ))
        require(
            stale.coordinator.candidates.isEmpty,
            "future Watch context does not create candidates")

        let replay = try SensorObservationFixture(cachedSampleAge: 2)
        let cached = replay.watch.value
        let timestamp = replay.coordinator.lastObservedAt(for: .cadence)
        replay.clock.date.addTimeInterval(1)
        replay.watch.send(cached)
        require(
            replay.coordinator.lastObservedAt(for: .cadence) == timestamp,
            "cache replay never extends last-seen time")
        replay.clock.date.addTimeInterval(8)
        replay.coordinator.refresh(at: replay.clock.date)
        require(
            replay.coordinator.activePrompt == nil,
            "silent source stops prompting after original sample expires")
        require(
            !replay.coordinator.isReporting(
                capabilities: .cadence, at: replay.clock.date),
            "silent source cannot report indefinitely")

        let mirrorEnd = try SensorObservationFixture()
        mirrorEnd.coordinator.ingest(
            mirrorEnd.presentation(connection: .ended, state: .ended),
            at: mirrorEnd.clock.date
        )
        require(
            !mirrorEnd.coordinator.hasActiveWorkout,
            "explicit HealthKit end also retires Watch evidence")
        mirrorEnd.watch.send(mirrorEnd.watch.value)
        require(
            !mirrorEnd.coordinator.hasActiveWorkout,
            "cached Watch packet cannot revive mirrored end")

        let removed = try SensorObservationFixture()
        removed.watch.send(nil)
        require(
            !removed.coordinator.hasActiveWorkout,
            "counterpart removal clears Watch-only reporting")
        let combined = WatchCyclingSensorObservationV1(
            sessionID: removed.sessionID,
            sessionStartedAt: removed.clock.date.addingTimeInterval(-60),
            capturedAt: removed.clock.date, isWorkoutActive: true,
            cadenceObservedAt: removed.clock.date,
            powerObservedAt: removed.clock.date
        )
        removed.watch.send(combined)
        require(
            Set(removed.coordinator.candidates.map(\.capabilities))
                == Set([.cadence, .power]),
            "unidentified cadence and power remain separate logical candidates")

        // Actual timer integration: no refresh(), new presentation, or Watch
        // event is supplied after admission. The first sample expires in ~5s.
        let timerSuite = "SensorObservationTimer.\(UUID().uuidString)"
        let timerDefaults = UserDefaults(suiteName: timerSuite)!
        defer { timerDefaults.removePersistentDomain(forName: timerSuite) }
        let timerStore = CyclingSensorStore(defaults: timerDefaults)
        let timerCoordinator = CyclingSensorDetectionCoordinator(
            sensorStore: timerStore, dismissalDefaults: timerDefaults
        )
        let timerNow = Date()
        timerCoordinator.ingestWatchObservation(
            WatchCyclingSensorObservationV1(
                sessionID: UUID(),
                sessionStartedAt: timerNow.addingTimeInterval(-60),
                capturedAt: timerNow, isWorkoutActive: true,
                cadenceObservedAt: timerNow.addingTimeInterval(-4.9)
            ), at: timerNow)
        require(
            timerCoordinator.activePrompt != nil,
            "timer fixture starts with a fresh prompt")
        let timerDeadline = Date().addingTimeInterval(15)
        while timerCoordinator.activePrompt != nil && Date() < timerDeadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        require(
            timerCoordinator.activePrompt == nil
                && timerCoordinator.lastObservedAt(for: .cadence) == nil,
            "expiry task clears published reporting and prompt without another callback"
        )
        print("Cycling sensor observation integration tests passed")
    }
}
