import Foundation

private func sensorAssert(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        Foundation.exit(1)
    }
}

private func sensorAssertEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: String
) {
    sensorAssert(
        actual == expected,
        "\(message): expected \(expected), got \(actual)"
    )
}

@MainActor
private struct CyclingSensorTestSuite {
    mutating func run() async {
        testTilePolicy()
        testSensorSettingsRoutingPolicy()
        testRegistryPersistenceAndMutations()
        testCorruptRegistryFailsSafe()
        testFutureRegistryVersionFailsSafe()
        testCapabilityUnionAcrossProfiles()
        testFreshCadenceCreatesCandidateAndPrompt()
        testCombinedMeasurementsRemainSeparateCandidates()
        await testDisabledProfilePromptsUntilEnabled()
        testPromptDismissalResetsForNextWorkout()
        testPromptDismissalSurvivesRelaunch()
        testCandidateGracePeriodExpiry()
        await testCandidateExpiresWithoutAnotherPresentation()
        testInactiveStaleFutureAndDisconnectedDataDoNotPrompt()
        print("Cycling sensor tests passed")
    }

    private func testTilePolicy() {
        sensorAssert(
            !WorkoutMetricTilePolicy(enabledSensorCapabilities: [])
                .showsCadence,
            "empty registry hides cadence"
        )
        sensorAssert(
            !WorkoutMetricTilePolicy(enabledSensorCapabilities: [])
                .showsPower,
            "empty registry hides power"
        )
        let cadence = WorkoutMetricTilePolicy(
            enabledSensorCapabilities: .cadence
        )
        sensorAssert(cadence.showsCadence, "cadence profile shows cadence")
        sensorAssert(!cadence.showsPower, "cadence profile hides power")
        let combined = WorkoutMetricTilePolicy(
            enabledSensorCapabilities: [.cadence, .power]
        )
        sensorAssert(combined.showsCadence, "combined shows cadence")
        sensorAssert(combined.showsPower, "combined shows power")
    }

    private func testSensorSettingsRoutingPolicy() {
        sensorAssertEqual(
            SensorSettingsRoutingPolicy.openDecision(
                hasPresentedSheet: false,
                isSensorSettingsPresented: false
            ),
            .presentImmediately,
            "sensor settings presents immediately when no sheet is open"
        )
        sensorAssertEqual(
            SensorSettingsRoutingPolicy.openDecision(
                hasPresentedSheet: true,
                isSensorSettingsPresented: false
            ),
            .dismissAndQueue,
            "sensor settings queues behind the ride metrics sheet"
        )
        sensorAssertEqual(
            SensorSettingsRoutingPolicy.openDecision(
                hasPresentedSheet: true,
                isSensorSettingsPresented: true
            ),
            .unchanged,
            "an existing sensor settings sheet is not replaced"
        )
        sensorAssertEqual(
            SensorSettingsRoutingPolicy.dismissalDecision(
                hasQueuedSheet: true,
                isWorkoutActive: true
            ),
            .presentQueuedSheet,
            "a queued sensor sheet wins over ride metrics restoration"
        )
        sensorAssertEqual(
            SensorSettingsRoutingPolicy.dismissalDecision(
                hasQueuedSheet: false,
                isWorkoutActive: true
            ),
            .restoreRideMetrics,
            "ride metrics returns after sensor settings closes"
        )
        sensorAssertEqual(
            SensorSettingsRoutingPolicy.dismissalDecision(
                hasQueuedSheet: false,
                isWorkoutActive: false
            ),
            .doNothing,
            "no sheet is restored after the workout ends"
        )
    }

    private func testRegistryPersistenceAndMutations() {
        let (defaults, suiteName) = makeDefaults("registry")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let profileID = UUID(uuidString:
            "10000000-0000-0000-0000-000000000001")!
        let store = CyclingSensorStore(
            defaults: defaults,
            storageKey: "sensors",
            now: { now },
            idGenerator: { profileID }
        )

        sensorAssert(store.profiles.isEmpty, "registry starts empty")
        let profile = store.enroll(
            name: "  Crank Sensor  ",
            capabilities: .cadence
        )
        sensorAssertEqual(profile?.id, profileID, "enrollment uses ID")
        sensorAssertEqual(
            profile?.identityKind,
            .logical,
            "Gate B enrollment uses logical identity"
        )
        sensorAssertEqual(
            store.enabledCapabilities,
            .cadence,
            "enabled enrollment exposes cadence"
        )
        sensorAssert(
            profile?.lastObservedAt == nil,
            "manual enrollment does not invent a last-seen timestamp"
        )
        store.rename(profileID: profileID, to: "Morning Bike")
        store.setEnabled(false, profileID: profileID)
        sensorAssert(
            store.enabledCapabilities.isEmpty,
            "disabled profile removes capability"
        )

        let restored = CyclingSensorStore(
            defaults: defaults,
            storageKey: "sensors",
            now: { now }
        )
        sensorAssertEqual(
            restored.profile(id: profileID)?.name,
            "Morning Bike",
            "name persists"
        )
        sensorAssertEqual(
            restored.profile(id: profileID)?.identityKind,
            .logical,
            "rename preserves identity"
        )
        sensorAssertEqual(
            restored.profile(id: profileID)?.isEnabled,
            false,
            "enabled state persists"
        )
        restored.forget(profileID: profileID)
        sensorAssert(restored.profiles.isEmpty, "forget removes profile")
    }

    private func testCorruptRegistryFailsSafe() {
        let (defaults, suiteName) = makeDefaults("corrupt")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: "sensors")
        let store = CyclingSensorStore(
            defaults: defaults,
            storageKey: "sensors"
        )
        sensorAssert(store.profiles.isEmpty, "corrupt registry loads empty")
    }

    private func testFutureRegistryVersionFailsSafe() {
        let (defaults, suiteName) = makeDefaults("future-version")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data(#"{"version":2,"profiles":[]}"#.utf8),
            forKey: "sensors"
        )
        let store = CyclingSensorStore(
            defaults: defaults,
            storageKey: "sensors"
        )
        sensorAssert(
            store.profiles.isEmpty,
            "future registry version loads empty"
        )
    }

    private func testCapabilityUnionAcrossProfiles() {
        let (defaults, suiteName) = makeDefaults("capability-union")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CyclingSensorStore(
            defaults: defaults,
            storageKey: "sensors"
        )
        let cadence = store.enroll(
            name: "Cadence",
            capabilities: .cadence
        )!
        let combined = store.enroll(
            name: "Combined",
            capabilities: [.cadence, .power]
        )!
        sensorAssertEqual(
            store.enabledCapabilities,
            [.cadence, .power],
            "overlapping profiles expose the capability union"
        )

        store.setEnabled(false, profileID: combined.id)
        sensorAssertEqual(
            store.enabledCapabilities,
            .cadence,
            "disabled combined profile leaves cadence profile active"
        )
        store.forget(profileID: cadence.id)
        sensorAssert(
            store.enabledCapabilities.isEmpty,
            "forgetting last enabled profile removes its capability"
        )
    }

    private func testFreshCadenceCreatesCandidateAndPrompt() {
        let fixture = makeFixture("fresh-cadence")
        let sessionID = UUID()
        fixture.coordinator.ingest(
            presentation(
                sessionID: sessionID,
                at: fixture.now,
                cadence: 82
            ),
            at: fixture.now
        )

        sensorAssertEqual(
            fixture.coordinator.candidates.map(\.capabilities),
            [.cadence],
            "fresh cadence creates cadence candidate"
        )
        sensorAssertEqual(
            fixture.coordinator.activePrompt?.capabilities,
            .cadence,
            "fresh cadence creates prompt"
        )
        sensorAssertEqual(
            fixture.coordinator.activePrompt?.action,
            .connect,
            "unknown cadence offers connection"
        )
        sensorAssert(
            fixture.store.enabledCapabilities.isEmpty,
            "observation does not auto-enroll"
        )
        fixture.coordinator.ingest(
            presentation(
                sessionID: sessionID,
                at: fixture.now.addingTimeInterval(1),
                cadence: 83
            ),
            at: fixture.now.addingTimeInterval(1)
        )
        sensorAssertEqual(
            fixture.coordinator.candidates.count,
            1,
            "repeated snapshots do not duplicate candidates"
        )

        _ = fixture.store.enroll(
            name: "Cadence Sensor",
            capabilities: .cadence
        )
        fixture.coordinator.didEnroll(capabilities: .cadence)
        sensorAssert(
            fixture.coordinator.activePrompt == nil,
            "explicit enrollment clears prompt"
        )
        sensorAssertEqual(
            fixture.store.enabledCapabilities,
            .cadence,
            "explicit enrollment exposes tile capability"
        )
    }

    private func testCombinedMeasurementsRemainSeparateCandidates() {
        let fixture = makeFixture("combined")
        fixture.coordinator.ingest(
            presentation(
                sessionID: UUID(),
                at: fixture.now,
                cadence: 90,
                power: 245
            ),
            at: fixture.now
        )

        sensorAssertEqual(
            Set(fixture.coordinator.candidates.map(\.capabilities)),
            Set([.cadence, .power]),
            "unidentified cadence and power stay separate candidates"
        )
        sensorAssertEqual(
            fixture.coordinator.activePrompt?.capabilities,
            [.cadence, .power],
            "prompt summarizes both capabilities"
        )
    }

    private mutating func testDisabledProfilePromptsUntilEnabled() async {
        let fixture = makeFixture("disabled")
        let profile = fixture.store.enroll(
            name: "Power Meter",
            capabilities: .power
        )!
        fixture.store.setEnabled(false, profileID: profile.id)
        fixture.coordinator.ingest(
            presentation(
                sessionID: UUID(),
                at: fixture.now,
                power: 210
            ),
            at: fixture.now
        )
        sensorAssertEqual(
            fixture.coordinator.activePrompt?.capabilities,
            .power,
            "disabled observed profile prompts"
        )
        sensorAssertEqual(
            fixture.coordinator.activePrompt?.action,
            .enable,
            "disabled observed profile offers enable instead of duplicate enrollment"
        )
        sensorAssert(
            fixture.coordinator.candidates.isEmpty,
            "disabled profiles are not duplicated as nearby candidates"
        )

        fixture.store.setEnabled(true, profileID: profile.id)
        await Task.yield()
        await Task.yield()
        sensorAssert(
            fixture.coordinator.activePrompt == nil,
            "enabling matching profile clears prompt"
        )
    }

    private func testPromptDismissalResetsForNextWorkout() {
        let fixture = makeFixture("dismiss")
        let firstSession = UUID()
        fixture.coordinator.ingest(
            presentation(
                sessionID: firstSession,
                at: fixture.now,
                cadence: 78
            ),
            at: fixture.now
        )
        fixture.coordinator.dismissPrompt()
        sensorAssert(
            fixture.coordinator.activePrompt == nil,
            "dismiss hides current prompt"
        )
        fixture.coordinator.ingest(
            presentation(
                sessionID: firstSession,
                at: fixture.now.addingTimeInterval(1),
                cadence: 79
            ),
            at: fixture.now.addingTimeInterval(1)
        )
        sensorAssert(
            fixture.coordinator.activePrompt == nil,
            "dismiss remains scoped to current workout"
        )

        let nextTime = fixture.now.addingTimeInterval(2)
        fixture.coordinator.ingest(
            presentation(
                sessionID: UUID(),
                at: nextTime,
                cadence: 80
            ),
            at: nextTime
        )
        sensorAssertEqual(
            fixture.coordinator.activePrompt?.capabilities,
            .cadence,
            "next workout can prompt again"
        )
    }

    private func testPromptDismissalSurvivesRelaunch() {
        let fixture = makeFixture("dismiss-relaunch")
        let sessionID = UUID()
        fixture.coordinator.ingest(
            presentation(
                sessionID: sessionID,
                at: fixture.now,
                cadence: 84
            ),
            at: fixture.now
        )
        fixture.coordinator.dismissPrompt()

        let restoredStore = CyclingSensorStore(
            defaults: fixture.defaults,
            storageKey: "sensors",
            now: { fixture.now }
        )
        let restoredCoordinator = CyclingSensorDetectionCoordinator(
            sensorStore: restoredStore,
            now: { fixture.now },
            dismissalDefaults: fixture.defaults,
            dismissalStorageKey: "prompt-dismissal"
        )
        restoredCoordinator.ingest(
            presentation(
                sessionID: sessionID,
                at: fixture.now,
                cadence: 85
            ),
            at: fixture.now
        )
        sensorAssert(
            restoredCoordinator.activePrompt == nil,
            "same-workout dismissal survives coordinator recreation"
        )

        let nextTime = fixture.now.addingTimeInterval(1)
        restoredCoordinator.ingest(
            presentation(
                sessionID: UUID(),
                at: nextTime,
                cadence: 86
            ),
            at: nextTime
        )
        sensorAssertEqual(
            restoredCoordinator.activePrompt?.action,
            .connect,
            "a new workout can offer the sensor again after relaunch"
        )
    }

    private func testCandidateGracePeriodExpiry() {
        let fixture = makeFixture("candidate-expiry")
        let sessionID = UUID()
        fixture.coordinator.ingest(
            presentation(
                sessionID: sessionID,
                at: fixture.now,
                cadence: 70
            ),
            at: fixture.now
        )

        let expiredAt = fixture.now.addingTimeInterval(
            CyclingSensorDetectionCoordinator.candidateGracePeriod + 1
        )
        fixture.coordinator.ingest(
            presentation(sessionID: sessionID, at: expiredAt),
            at: expiredAt
        )
        sensorAssert(
            fixture.coordinator.candidates.isEmpty,
            "candidate expires after the enrollment grace period"
        )
        sensorAssert(
            fixture.coordinator.activePrompt == nil,
            "expired candidate no longer prompts"
        )
    }

    private mutating func testCandidateExpiresWithoutAnotherPresentation()
        async {
        let (defaults, suiteName) = makeDefaults("scheduled-expiry")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CyclingSensorStore(
            defaults: defaults,
            storageKey: "sensors"
        )
        let coordinator = CyclingSensorDetectionCoordinator(
            sensorStore: store,
            candidateGracePeriod: 0.03,
            dismissalDefaults: defaults,
            dismissalStorageKey: "prompt-dismissal"
        )
        let detectedAt = Date()
        coordinator.ingest(
            presentation(
                sessionID: UUID(),
                at: detectedAt,
                cadence: 72
            ),
            at: detectedAt
        )
        sensorAssertEqual(
            coordinator.candidates.count,
            1,
            "scheduled-expiry fixture starts with a candidate"
        )

        let expiryDeadline = Date().addingTimeInterval(1)
        while !coordinator.candidates.isEmpty && Date() < expiryDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        sensorAssert(
            coordinator.candidates.isEmpty,
            "candidate expires on wall-clock time without another presentation"
        )
    }

    private func testInactiveStaleFutureAndDisconnectedDataDoNotPrompt() {
        let fixture = makeFixture("inactive-stale")
        fixture.coordinator.ingest(.idle, at: fixture.now)
        sensorAssert(
            fixture.coordinator.activePrompt == nil,
            "idle presentation does not prompt"
        )

        fixture.coordinator.ingest(
            presentation(
                sessionID: UUID(),
                at: fixture.now.addingTimeInterval(-10),
                cadence: 70
            ),
            at: fixture.now
        )
        sensorAssert(
            fixture.coordinator.activePrompt == nil,
            "stale cadence does not prompt"
        )

        fixture.coordinator.ingest(
            presentation(
                sessionID: UUID(),
                at: fixture.now.addingTimeInterval(1),
                cadence: 71
            ),
            at: fixture.now
        )
        sensorAssert(
            fixture.coordinator.activePrompt == nil,
            "future cadence does not prompt"
        )

        fixture.coordinator.ingest(
            presentation(
                sessionID: UUID(),
                at: fixture.now,
                cadence: 72,
                connectionState: .disconnected
            ),
            at: fixture.now
        )
        sensorAssert(
            fixture.coordinator.activePrompt == nil,
            "disconnected cadence does not prompt"
        )

        fixture.coordinator.ingest(
            presentation(
                sessionID: UUID(),
                at: fixture.now,
                cadence: 73,
                sessionState: .ended
            ),
            at: fixture.now
        )
        sensorAssert(
            fixture.coordinator.activePrompt == nil,
            "terminal workout data does not prompt"
        )
    }

    private func makeDefaults(
        _ suffix: String
    ) -> (UserDefaults, String) {
        let suiteName = "CyclingSensorTests.\(suffix).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func makeFixture(_ suffix: String) -> SensorFixture {
        let (defaults, suiteName) = makeDefaults(suffix)
        let now = Date(timeIntervalSinceReferenceDate: 900_100_000)
        let store = CyclingSensorStore(
            defaults: defaults,
            storageKey: "sensors",
            now: { now }
        )
        let coordinator = CyclingSensorDetectionCoordinator(
            sensorStore: store,
            now: { now },
            dismissalDefaults: defaults,
            dismissalStorageKey: "prompt-dismissal"
        )
        return SensorFixture(
            defaults: defaults,
            suiteName: suiteName,
            now: now,
            store: store,
            coordinator: coordinator
        )
    }

    private func presentation(
        sessionID: UUID,
        at date: Date,
        cadence: Double? = nil,
        power: Double? = nil,
        connectionState: WorkoutMirrorConnectionStateV1 = .connected,
        sessionState: WorkoutSessionStateV1 = .running
    ) -> WorkoutMirrorPresentationV1 {
        let cadenceMetric = cadence.map {
            WorkoutMetricV1(
                value: $0,
                unit: .revolutionsPerMinute,
                capturedAt: date,
                source: .healthKit
            )
        }
        let powerMetric = power.map {
            WorkoutMetricV1(
                value: $0,
                unit: .watts,
                capturedAt: date,
                source: .healthKit
            )
        }
        var availability = WorkoutAvailabilityMaskV1()
        if cadenceMetric != nil {
            availability.insert(.cyclingCadence)
        }
        if powerMetric != nil {
            availability.insert(.cyclingPower)
        }
        return WorkoutMirrorPresentationV1(
            connectionState: connectionState,
            snapshot: WorkoutSnapshotV1(
                state: sessionState,
                startDate: date.addingTimeInterval(-60),
                cyclingPower: powerMetric,
                cyclingCadence: cadenceMetric,
                availability: availability
            ),
            sessionID: sessionID,
            capturedAt: date,
            receivedAt: date,
            confirmedSessionState: sessionState,
            errorCode: nil,
            pendingControl: nil,
            finalSnapshot: nil,
            navigation: .empty
        )
    }
}

@MainActor
private final class SensorFixture {
    let defaults: UserDefaults
    let suiteName: String
    let now: Date
    let store: CyclingSensorStore
    let coordinator: CyclingSensorDetectionCoordinator

    init(
        defaults: UserDefaults,
        suiteName: String,
        now: Date,
        store: CyclingSensorStore,
        coordinator: CyclingSensorDetectionCoordinator
    ) {
        self.defaults = defaults
        self.suiteName = suiteName
        self.now = now
        self.store = store
        self.coordinator = coordinator
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@main
private enum CyclingSensorTestRunner {
    @MainActor
    static func main() async {
        var suite = CyclingSensorTestSuite()
        await suite.run()
    }
}
