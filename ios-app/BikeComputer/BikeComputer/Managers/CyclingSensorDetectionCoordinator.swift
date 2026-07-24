import Combine
import Foundation

@MainActor
final class CyclingSensorDetectionCoordinator: ObservableObject {
    static let candidateGracePeriod: TimeInterval = 30 * 60
    static let reportingFreshness: TimeInterval = 10

    @Published private(set) var candidates: [CyclingSensorCandidate] = []
    @Published private(set) var activePrompt: CyclingSensorPrompt?
    @Published private(set) var isLooking = false
    @Published private(set) var hasActiveWorkout = false
    @Published private(set) var lastObservedAtByCapability:
        [CyclingSensorCapabilities: Date] = [:]

    private let sensorStore: CyclingSensorStore
    private let now: () -> Date
    private let idGenerator: () -> UUID
    private var presentationCancellable: AnyCancellable?
    private var profileCancellable: AnyCancellable?
    private var currentSessionID: UUID?
    private var dismissedCapabilities = CyclingSensorCapabilities()

    init(
        sensorStore: CyclingSensorStore,
        now: @escaping () -> Date = Date.init,
        idGenerator: @escaping () -> UUID = UUID.init
    ) {
        self.sensorStore = sensorStore
        self.now = now
        self.idGenerator = idGenerator

        profileCancellable = sensorStore.$profiles.sink {
            [weak self] profiles in
            self?.reconcileCandidatesAndPrompt(profiles: profiles)
        }
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
        guard let prompt = activePrompt else { return }
        dismissedCapabilities.formUnion(prompt.capabilities)
        activePrompt = nil
    }

    func didEnroll(capabilities: CyclingSensorCapabilities) {
        candidates.removeAll {
            !$0.capabilities.intersection(capabilities).isEmpty
        }
        dismissedCapabilities.subtract(capabilities)
        reconcileCandidatesAndPrompt()
    }

    func didForget(capabilities: CyclingSensorCapabilities) {
        candidates.removeAll {
            !$0.capabilities.intersection(capabilities).isEmpty
        }
        dismissedCapabilities.formUnion(capabilities)
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
            dismissedCapabilities = []
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
                > Self.candidateGracePeriod
        }
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

        guard hasActiveWorkout else {
            activePrompt = nil
            return
        }

        var unresolved = CyclingSensorCapabilities()

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
            }
        }

        unresolved.subtract(dismissedCapabilities)
        activePrompt = unresolved.isEmpty
            ? nil
            : CyclingSensorPrompt(capabilities: unresolved)
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
