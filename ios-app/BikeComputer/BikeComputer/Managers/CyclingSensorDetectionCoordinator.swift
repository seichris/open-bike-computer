import Combine
import Foundation

private struct CyclingSensorPromptDismissalEnvelope: Codable {
    static let currentVersion = 1

    let version: Int
    let sessionID: UUID
    let capabilities: CyclingSensorCapabilities
}

@MainActor
final class CyclingSensorDetectionCoordinator: ObservableObject {
    nonisolated static let candidateGracePeriod: TimeInterval = 30 * 60
    nonisolated static let reportingFreshness =
        WatchCyclingSensorObservationV1.reportingFreshness
    nonisolated static let defaultDismissalStorageKey =
        "cyclingSensors.promptDismissal.v1"

    @Published private(set) var candidates: [CyclingSensorCandidate] = []
    @Published private(set) var activePrompt: CyclingSensorPrompt?
    @Published private(set) var isLooking = false
    @Published private(set) var hasActiveWorkout = false
    @Published private(set) var lastObservedAtByCapability:
        [CyclingSensorCapabilities: Date] = [:]

    private let sensorStore: CyclingSensorStore
    private let now: () -> Date
    private let idGenerator: () -> UUID
    private let candidateGracePeriod: TimeInterval
    private let dismissalDefaults: UserDefaults
    private let dismissalStorageKey: String
    private var observationReducer = CyclingSensorObservationReducer()
    private var watchObservationCancellable: AnyCancellable?
    private var presentationCancellable: AnyCancellable?
    private var profileCancellable: AnyCancellable?
    private var candidateExpiryTask: Task<Void, Never>?
    private var currentSessionID: UUID?
    private var dismissedCapabilities = CyclingSensorCapabilities()

    init(
        sensorStore: CyclingSensorStore,
        now: @escaping () -> Date = Date.init,
        idGenerator: @escaping () -> UUID = UUID.init,
        candidateGracePeriod: TimeInterval =
            CyclingSensorDetectionCoordinator.candidateGracePeriod,
        dismissalDefaults: UserDefaults = .standard,
        dismissalStorageKey: String =
            CyclingSensorDetectionCoordinator.defaultDismissalStorageKey
    ) {
        self.sensorStore = sensorStore
        self.now = now
        self.idGenerator = idGenerator
        self.candidateGracePeriod = candidateGracePeriod
        self.dismissalDefaults = dismissalDefaults
        self.dismissalStorageKey = dismissalStorageKey

        profileCancellable = sensorStore.$profiles.sink {
            [weak self] profiles in
            self?.reconcileCandidatesAndPrompt(profiles: profiles)
        }
    }

    deinit {
        candidateExpiryTask?.cancel()
    }

    func bind(
        to workoutStore: WorkoutMetricsStore,
        watchObservations:
            AnyPublisher<WatchCyclingSensorObservationV1?, Never>? = nil
    ) {
        if presentationCancellable == nil {
            presentationCancellable = workoutStore.$presentation.sink {
                [weak self] presentation in
                guard let self else { return }
                self.ingest(presentation, at: self.now())
            }
        }
        if watchObservationCancellable == nil, let watchObservations {
            // Published/CurrentValueSubject replays the latest received
            // context on binding, including a cold-start cached observation.
            watchObservationCancellable = watchObservations.sink {
                [weak self] observation in
                guard let self else { return }
                self.ingestWatchObservation(observation, at: self.now())
            }
        }
    }

    func beginLooking() {
        isLooking = true
        refresh(at: now())
    }

    func stopLooking() {
        isLooking = false
    }

    func prepareForPromptNavigation() {
        beginLooking()
    }

    func dismissPrompt() {
        guard let prompt = activePrompt,
              currentSessionID != nil else {
            return
        }
        dismissedCapabilities.formUnion(prompt.capabilities)
        persistPromptDismissal()
        activePrompt = nil
    }

    func didEnroll(capabilities: CyclingSensorCapabilities) {
        candidates.removeAll {
            !$0.capabilities.intersection(capabilities).isEmpty
        }
        dismissedCapabilities.subtract(capabilities)
        persistPromptDismissal()
        reconcileCandidatesAndPrompt()
    }

    func didForget(capabilities: CyclingSensorCapabilities) {
        candidates.removeAll {
            !$0.capabilities.intersection(capabilities).isEmpty
        }
        dismissedCapabilities.formUnion(capabilities)
        persistPromptDismissal()
        reconcileCandidatesAndPrompt()
    }

    func lastObservedAt(
        for capabilities: CyclingSensorCapabilities
    ) -> Date? {
        capabilities
            .intersection(.supported)
            .individualCapabilities
            .compactMap { lastObservedAtByCapability[$0] }
            .max()
    }

    func isReporting(
        capabilities: CyclingSensorCapabilities,
        at date: Date = Date()
    ) -> Bool {
        guard hasActiveWorkout,
              let lastObservedAt = lastObservedAt(for: capabilities) else {
            return false
        }
        let age = date.timeIntervalSince(lastObservedAt)
        return age >= 0 && age <= Self.reportingFreshness
    }

    func ingest(
        _ presentation: WorkoutMirrorPresentationV1,
        at date: Date
    ) {
        // snapshot.state comes from the Watch envelope. sessionState can
        // instead reflect a local mirror failure and must not retire Watch.
        let isTerminal = presentation.snapshot.state == .ended ||
            presentation.snapshot.state == .failed
        let accepted: Bool
        let hasActiveMirror = presentation.connectionState == .connected &&
            presentation.isWorkoutActive &&
            presentation.snapshot.state.isActive
        if (hasActiveMirror || isTerminal),
           let sessionID = presentation.sessionID,
           let capturedAt = presentation.capturedAt,
           let observation = WatchCyclingSensorObservationV1(
               sessionID: sessionID,
               snapshot: presentation.snapshot,
               capturedAt: capturedAt
           ) {
            accepted = observationReducer.ingest(
                observation, from: .mirror, at: date
            )
        } else {
            // Idle/stale/disconnected describes the mirror, not the Watch
            // workout. It must not clear Watch evidence or prompt dismissal.
            observationReducer.setUnavailable(.mirror)
            accepted = false
        }
        refresh(at: date, admittingCandidates: accepted)
    }

    func ingestWatchObservation(
        _ observation: WatchCyclingSensorObservationV1?,
        at date: Date
    ) {
        let accepted: Bool
        if let observation {
            accepted = observationReducer.ingest(
                observation, from: .watch, at: date
            )
        } else {
            observationReducer.setUnavailable(.watch)
            accepted = false
        }
        refresh(at: date, admittingCandidates: accepted)
    }

    /// Refreshes time-dependent presentation without manufacturing another
    /// observation. Expiry must work even with no further mirror/WC callbacks.
    func refresh(
        at date: Date,
        admittingCandidates: Bool = false
    ) {
        if let sessionID = observationReducer.sessionID,
           sessionID != currentSessionID {
            currentSessionID = sessionID
            dismissedCapabilities = restoredDismissedCapabilities(
                for: sessionID
            )
            candidates.removeAll()
        }
        hasActiveWorkout = observationReducer.hasActiveWorkout(at: date)
        var observed: [CyclingSensorCapabilities: Date] = [:]
        observed[.cadence] = observationReducer.cadenceObservedAt(at: date)
        observed[.power] = observationReducer.powerObservedAt(at: date)
        lastObservedAtByCapability = observed
        if admittingCandidates {
            for capability in CyclingSensorCapabilities.supported
                .individualCapabilities {
                guard let sampleDate = observed[capability],
                      WatchCyclingSensorObservationV1.isFresh(
                          sampleDate, at: date,
                          maximumAge:
                            WatchCyclingSensorObservationV1.discoveryFreshness
                      ) else { continue }
                observe(capability, at: sampleDate)
            }
        }
        pruneCandidates(at: date)
        reconcileCandidatesAndPrompt(at: date)
    }

    private func observe(
        _ capability: CyclingSensorCapabilities,
        at date: Date
    ) {
        lastObservedAtByCapability[capability] = date
        sensorStore.markObserved(capabilities: capability, at: date)

        guard sensorStore.profiles(matching: capability).isEmpty else {
            return
        }

        if let index = candidates.firstIndex(where: {
            $0.capabilities == capability
        }) {
            candidates[index].lastObservedAt = max(
                candidates[index].lastObservedAt, date
            )
        } else {
            candidates.append(
                CyclingSensorCandidate(
                    id: idGenerator(),
                    capabilities: capability,
                    firstObservedAt: date,
                    lastObservedAt: date
                )
            )
        }
        scheduleCandidateExpiry()
    }

    private func pruneCandidates(at date: Date) {
        candidates.removeAll {
            date.timeIntervalSince($0.lastObservedAt)
                >= candidateGracePeriod
        }
        scheduleCandidateExpiry()
    }

    private func reconcileCandidatesAndPrompt(
        profiles profileOverride: [CyclingSensorProfile]? = nil,
        at referenceDate: Date? = nil
    ) {
        let profiles = profileOverride ?? sensorStore.profiles
        let referenceDate = referenceDate ?? now()
        func matchingProfiles(
            _ capabilities: CyclingSensorCapabilities
        ) -> [CyclingSensorProfile] {
            profiles.filter {
                !$0.capabilities.intersection(capabilities).isEmpty
            }
        }

        candidates.removeAll { candidate in
            !matchingProfiles(candidate.capabilities).isEmpty
        }
        scheduleCandidateExpiry()

        guard hasActiveWorkout else {
            activePrompt = nil
            return
        }

        var unresolved = CyclingSensorCapabilities()
        var enrollmentCapabilities = CyclingSensorCapabilities()
        var enableCapabilities = CyclingSensorCapabilities()

        for capability in CyclingSensorCapabilities.supported
            .individualCapabilities {
            let matches = matchingProfiles(capability)
            let isEnabled = matches.contains(where: \.isEnabled)
            let hasCurrentObservation = isReporting(
                capabilities: capability,
                at: referenceDate
            )
            if !isEnabled && hasCurrentObservation {
                unresolved.insert(capability)
                if matches.isEmpty {
                    enrollmentCapabilities.insert(capability)
                } else {
                    enableCapabilities.insert(capability)
                }
            }
        }

        unresolved.subtract(dismissedCapabilities)
        guard !unresolved.isEmpty else {
            activePrompt = nil
            return
        }
        let needsEnrollment =
            !enrollmentCapabilities.intersection(unresolved).isEmpty
        let needsEnable =
            !enableCapabilities.intersection(unresolved).isEmpty
        let action: CyclingSensorPrompt.Action
        if needsEnrollment && needsEnable {
            action = .review
        } else if needsEnable {
            action = .enable
        } else {
            action = .connect
        }
        activePrompt = CyclingSensorPrompt(
            capabilities: unresolved,
            action: action
        )
    }

    private func scheduleCandidateExpiry() {
        candidateExpiryTask?.cancel()
        candidateExpiryTask = nil
        let referenceDate = now()
        let deadlines = candidates.map {
            $0.lastObservedAt.addingTimeInterval(candidateGracePeriod)
        } + [observationReducer.nextExpiry(after: referenceDate)].compactMap { $0 }
        guard let nextExpiry = deadlines.min() else {
            return
        }

        let delay = max(0, nextExpiry.timeIntervalSince(referenceDate))
        let nanoseconds = UInt64(
            min(delay, Double(UInt64.max) / 1_000_000_000)
                * 1_000_000_000
        )
        candidateExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.candidateExpiryTask = nil
            self.refresh(at: self.now())
        }
    }

    private func restoredDismissedCapabilities(
        for sessionID: UUID
    ) -> CyclingSensorCapabilities {
        guard let data = dismissalDefaults.data(
            forKey: dismissalStorageKey
        ),
        let envelope = try? JSONDecoder().decode(
            CyclingSensorPromptDismissalEnvelope.self,
            from: data
        ),
        envelope.version
            == CyclingSensorPromptDismissalEnvelope.currentVersion,
        envelope.sessionID == sessionID else {
            dismissalDefaults.removeObject(forKey: dismissalStorageKey)
            return []
        }
        return envelope.capabilities.intersection(.supported)
    }

    private func persistPromptDismissal() {
        guard let currentSessionID,
              !dismissedCapabilities.isEmpty else {
            dismissalDefaults.removeObject(forKey: dismissalStorageKey)
            return
        }
        let envelope = CyclingSensorPromptDismissalEnvelope(
            version: CyclingSensorPromptDismissalEnvelope.currentVersion,
            sessionID: currentSessionID,
            capabilities:
                dismissedCapabilities.intersection(.supported)
        )
        guard let data = try? JSONEncoder().encode(envelope) else {
            return
        }
        dismissalDefaults.set(data, forKey: dismissalStorageKey)
    }
}

private extension CyclingSensorCapabilities {
    var individualCapabilities: [CyclingSensorCapabilities] {
        var result: [CyclingSensorCapabilities] = []
        if contains(.cadence) {
            result.append(.cadence)
        }
        if contains(.power) {
            result.append(.power)
        }
        return result
    }
}
