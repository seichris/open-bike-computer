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
    nonisolated static let reportingFreshness: TimeInterval = 10
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

    func bind(to workoutStore: WorkoutMetricsStore) {
        guard presentationCancellable == nil else { return }
        presentationCancellable = workoutStore.$presentation.sink {
            [weak self] presentation in
            self?.ingest(presentation, at: self?.now() ?? Date())
        }
        ingest(workoutStore.presentation, at: now())
    }

    func beginLooking() {
        isLooking = true
        pruneCandidates(at: now())
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
        guard let lastObservedAt = lastObservedAt(for: capabilities) else {
            return false
        }
        let age = date.timeIntervalSince(lastObservedAt)
        return age >= 0 && age <= Self.reportingFreshness
    }

    func ingest(
        _ presentation: WorkoutMirrorPresentationV1,
        at date: Date
    ) {
        hasActiveWorkout = presentation.isWorkoutActive

        guard presentation.isWorkoutActive,
              presentation.connectionState == .connected,
              let sessionID = presentation.sessionID else {
            if !presentation.isWorkoutActive {
                currentSessionID = nil
                dismissedCapabilities = []
            }
            pruneCandidates(at: date)
            reconcileCandidatesAndPrompt(at: date)
            return
        }

        if currentSessionID != sessionID {
            currentSessionID = sessionID
            dismissedCapabilities = restoredDismissedCapabilities(
                for: sessionID
            )
            candidates.removeAll()
            lastObservedAtByCapability = [:]
        }

        let snapshot = presentation.snapshot
        if isFresh(snapshot.cyclingCadence, at: date) {
            observe(.cadence, at: date)
        }
        if isFresh(snapshot.cyclingPower, at: date) {
            observe(.power, at: date)
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
            candidates[index].lastObservedAt = date
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

    private func isFresh(
        _ metric: WorkoutMetricV1?,
        at date: Date
    ) -> Bool {
        guard let metric else { return false }
        return WorkoutMetricFreshness.isFresh(
            capturedAt: metric.capturedAt,
            now: date,
            maximumAge:
                WorkoutMetricFreshness.pairedCyclingSensorMaximumAge
        )
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
        guard let nextExpiry = candidates.map({
            $0.lastObservedAt.addingTimeInterval(candidateGracePeriod)
        }).min() else {
            return
        }

        let delay = max(0, nextExpiry.timeIntervalSince(now()))
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
            let date = self.now()
            self.pruneCandidates(at: date)
            self.reconcileCandidatesAndPrompt(at: date)
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
