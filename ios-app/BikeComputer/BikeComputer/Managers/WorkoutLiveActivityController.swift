import ActivityKit
import Combine
import Foundation

@available(iOS 17.0, *)
enum WorkoutLiveActivitySystemState: Equatable, Sendable {
    case active
    case stale
    case ended
    case dismissed
}

@available(iOS 17.0, *)
enum WorkoutLiveActivityDismissal: Equatable, Sendable {
    case immediate
    case after(Date)
}

@available(iOS 17.0, *)
struct WorkoutLiveActivityRecord: Equatable, Sendable {
    let id: String
    let attributes: WorkoutLiveActivityAttributes
    let contentState: WorkoutLiveActivityAttributes.ContentState
    let systemState: WorkoutLiveActivitySystemState
}

@available(iOS 17.0, *)
@MainActor
protocol WorkoutLiveActivityClient {
    func records() -> [WorkoutLiveActivityRecord]
    func request(
        attributes: WorkoutLiveActivityAttributes,
        contentState: WorkoutLiveActivityAttributes.ContentState,
        staleDate: Date?
    ) throws -> WorkoutLiveActivityRecord
    func update(
        id: String,
        contentState: WorkoutLiveActivityAttributes.ContentState,
        staleDate: Date?
    ) async throws
    func end(
        id: String,
        contentState: WorkoutLiveActivityAttributes.ContentState?,
        dismissal: WorkoutLiveActivityDismissal
    ) async
    func stateUpdates(
        for id: String
    ) -> AsyncStream<WorkoutLiveActivitySystemState>
}

@available(iOS 17.0, *)
protocol WorkoutLiveActivityAuthorizationProviding {
    var areActivitiesEnabled: Bool { get }
}

@available(iOS 17.0, *)
protocol WorkoutLiveActivitySuppressionStoring: AnyObject {
    func contains(_ sessionID: UUID) -> Bool
    func insert(_ sessionID: UUID)
    func remove(_ sessionID: UUID)
}

@available(iOS 17.0, *)
@MainActor
protocol WorkoutLiveActivityPresentationProviding: AnyObject {
    var presentation: WorkoutMirrorPresentationV1 { get }
    var presentationPublisher:
        AnyPublisher<WorkoutMirrorPresentationV1, Never> { get }
}

@available(iOS 17.0, *)
extension WorkoutMetricsStore: WorkoutLiveActivityPresentationProviding {
    var presentationPublisher:
        AnyPublisher<WorkoutMirrorPresentationV1, Never> {
        $presentation.eraseToAnyPublisher()
    }
}

@available(iOS 17.0, *)
struct SystemWorkoutLiveActivityAuthorizationProvider:
    WorkoutLiveActivityAuthorizationProviding {
    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }
}

@available(iOS 17.0, *)
@MainActor
final class WorkoutLiveActivitySuppressionStore:
    WorkoutLiveActivitySuppressionStoring {
    private static let defaultsKey =
        "WorkoutLiveActivitySuppressedSessionIDs"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func contains(_ sessionID: UUID) -> Bool {
        identifiers.contains(sessionID.uuidString)
    }

    func insert(_ sessionID: UUID) {
        var identifiers = identifiers
        identifiers.insert(sessionID.uuidString)
        defaults.set(Array(identifiers).sorted(), forKey: Self.defaultsKey)
    }

    func remove(_ sessionID: UUID) {
        var identifiers = identifiers
        identifiers.remove(sessionID.uuidString)
        defaults.set(Array(identifiers).sorted(), forKey: Self.defaultsKey)
    }

    private var identifiers: Set<String> {
        Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }
}

@available(iOS 17.0, *)
@MainActor
final class SystemWorkoutLiveActivityClient: WorkoutLiveActivityClient {
    private enum ClientError: Error {
        case missingActivity
    }

    func records() -> [WorkoutLiveActivityRecord] {
        Activity<WorkoutLiveActivityAttributes>.activities.map(record)
    }

    func request(
        attributes: WorkoutLiveActivityAttributes,
        contentState: WorkoutLiveActivityAttributes.ContentState,
        staleDate: Date?
    ) throws -> WorkoutLiveActivityRecord {
        let activity = try Activity<WorkoutLiveActivityAttributes>.request(
            attributes: attributes,
            content: ActivityContent(
                state: contentState,
                staleDate: staleDate
            ),
            pushType: nil
        )
        return record(activity)
    }

    func update(
        id: String,
        contentState: WorkoutLiveActivityAttributes.ContentState,
        staleDate: Date?
    ) async throws {
        guard let activity = activity(id: id) else {
            throw ClientError.missingActivity
        }
        await activity.update(
            ActivityContent(
                state: contentState,
                staleDate: staleDate
            )
        )
    }

    func end(
        id: String,
        contentState: WorkoutLiveActivityAttributes.ContentState?,
        dismissal: WorkoutLiveActivityDismissal
    ) async {
        guard let activity = activity(id: id) else { return }
        let content = contentState.map {
            ActivityContent(state: $0, staleDate: nil)
        }
        let policy: ActivityUIDismissalPolicy
        switch dismissal {
        case .immediate:
            policy = .immediate
        case .after(let date):
            policy = .after(date)
        }
        await activity.end(content, dismissalPolicy: policy)
    }

    func stateUpdates(
        for id: String
    ) -> AsyncStream<WorkoutLiveActivitySystemState> {
        guard let activity = activity(id: id) else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        return AsyncStream { continuation in
            let task = Task {
                for await state in activity.activityStateUpdates {
                    continuation.yield(Self.systemState(state))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func activity(
        id: String
    ) -> Activity<WorkoutLiveActivityAttributes>? {
        Activity<WorkoutLiveActivityAttributes>.activities.first {
            $0.id == id
        }
    }

    private func record(
        _ activity: Activity<WorkoutLiveActivityAttributes>
    ) -> WorkoutLiveActivityRecord {
        WorkoutLiveActivityRecord(
            id: activity.id,
            attributes: activity.attributes,
            contentState: activity.content.state,
            systemState: Self.systemState(activity.activityState)
        )
    }

    private static func systemState(
        _ state: ActivityState
    ) -> WorkoutLiveActivitySystemState {
        switch state {
        case .active:
            return .active
        case .stale:
            return .stale
        case .dismissed:
            return .dismissed
        case .ended:
            return .ended
        default:
            // Covers newer nonterminal states such as the iOS 26 pending
            // request state without raising the app's deployment target.
            return .active
        }
    }
}

@available(iOS 17.0, *)
@MainActor
final class WorkoutLiveActivityController {
    nonisolated static let metricUpdateInterval: TimeInterval = 1
    nonisolated static let finalSummaryDismissalInterval: TimeInterval = 15 * 60
    nonisolated static let reconciliationGracePeriod: TimeInterval = 3

    private let presentationSource:
        any WorkoutLiveActivityPresentationProviding
    private let client: WorkoutLiveActivityClient
    private let authorization: WorkoutLiveActivityAuthorizationProviding
    private let suppressionStore: WorkoutLiveActivitySuppressionStoring
    private let now: () -> Date
    private let wait:
        @MainActor @Sendable (TimeInterval) async throws -> Void

    private var presentationCancellable: AnyCancellable?
    private var managedActivityID: String?
    private var managedSessionID: UUID?
    private var lastPublishedContent:
        WorkoutLiveActivityAttributes.ContentState?
    private var lastPublishedAt: Date?
    private var latestPresentation: WorkoutMirrorPresentationV1
    private var pendingMetricContent:
        WorkoutLiveActivityAttributes.ContentState?
    private var metricUpdateTask: Task<Void, Never>?
    private var activityStateTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var reconciliationGraceTask: Task<Void, Never>?
    private var hasReconciled = false
    private var isWithinReconciliationGrace = false
    private var isApplicationForeground = false
    private var systemEndedSessionIDs: Set<UUID> = []

    init(
        store: WorkoutMetricsStore,
        client: WorkoutLiveActivityClient? = nil,
        authorization: WorkoutLiveActivityAuthorizationProviding? = nil,
        suppressionStore: WorkoutLiveActivitySuppressionStoring? = nil,
        now: @escaping () -> Date = Date.init,
        wait: (@MainActor @Sendable (TimeInterval) async throws -> Void)? = nil
    ) {
        presentationSource = store
        self.client = client ?? SystemWorkoutLiveActivityClient()
        self.authorization = authorization
            ?? SystemWorkoutLiveActivityAuthorizationProvider()
        self.suppressionStore = suppressionStore
            ?? WorkoutLiveActivitySuppressionStore()
        self.now = now
        self.wait = wait ?? { interval in
            try await Task.sleep(
                nanoseconds: UInt64(interval * 1_000_000_000)
            )
        }
        latestPresentation = store.presentation
    }

    init(
        presentationSource:
            any WorkoutLiveActivityPresentationProviding,
        client: WorkoutLiveActivityClient,
        authorization: WorkoutLiveActivityAuthorizationProviding,
        suppressionStore: WorkoutLiveActivitySuppressionStoring,
        now: @escaping () -> Date = Date.init,
        wait: (@MainActor @Sendable (TimeInterval) async throws -> Void)? = nil
    ) {
        self.presentationSource = presentationSource
        self.client = client
        self.authorization = authorization
        self.suppressionStore = suppressionStore
        self.now = now
        self.wait = wait ?? { interval in
            try await Task.sleep(
                nanoseconds: UInt64(interval * 1_000_000_000)
            )
        }
        latestPresentation = presentationSource.presentation
    }

    deinit {
        metricUpdateTask?.cancel()
        activityStateTask?.cancel()
        reconciliationTask?.cancel()
        reconciliationGraceTask?.cancel()
    }

    func start(isApplicationForeground: Bool) {
        guard presentationCancellable == nil else {
            setApplicationForeground(isApplicationForeground)
            return
        }
        self.isApplicationForeground = isApplicationForeground
        latestPresentation = presentationSource.presentation
        let publisher = presentationSource.presentationPublisher
        presentationCancellable = publisher.sink {
            [weak self] presentation in
            guard let self else { return }
            latestPresentation = presentation
            guard hasReconciled else { return }
            Task { @MainActor [weak self] in
                await self?.handle(presentation)
            }
        }
        reconciliationTask = Task { @MainActor [weak self] in
            await self?.reconcileExistingActivities()
        }
    }

    func setApplicationForeground(_ isForeground: Bool) {
        isApplicationForeground = isForeground
        guard isForeground, hasReconciled else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await handle(latestPresentation)
        }
    }

    private func reconcileExistingActivities() async {
        let allRecords = client.records()
        for record in allRecords {
            switch record.systemState {
            case .dismissed:
                suppressionStore.insert(record.attributes.sessionID)
            case .ended:
                systemEndedSessionIDs.insert(record.attributes.sessionID)
            case .active, .stale:
                break
            }
        }
        let records = allRecords.filter {
            $0.systemState == .active || $0.systemState == .stale
        }
        let mapped = WorkoutLiveActivityStateMapper.map(
            latestPresentation,
            at: now()
        )

        if let mapped {
            let matching = records.filter {
                $0.attributes.sessionID == mapped.attributes.sessionID
            }
            if let retained = matching.first {
                retain(retained)
            }
            for record in records where record.id != managedActivityID {
                await client.end(
                    id: record.id,
                    contentState: nil,
                    dismissal: .immediate
                )
            }
        } else if !records.isEmpty {
            beginReconciliationGrace()
        }

        hasReconciled = true
        await handle(latestPresentation)
    }

    private func beginReconciliationGrace() {
        isWithinReconciliationGrace = true
        reconciliationGraceTask?.cancel()
        let grace = Self.reconciliationGracePeriod
        let wait = wait
        reconciliationGraceTask = Task { @MainActor [weak self] in
            do {
                try await wait(grace)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            isWithinReconciliationGrace = false
            if WorkoutLiveActivityStateMapper.map(
                latestPresentation,
                at: now()
            ) != nil {
                await reconcileExistingActivities()
                return
            }
            let records = client.records().filter {
                $0.systemState == .active || $0.systemState == .stale
            }
            for record in records {
                await client.end(
                    id: record.id,
                    contentState: nil,
                    dismissal: .immediate
                )
            }
            await handle(latestPresentation)
        }
    }

    private func handle(
        _ presentation: WorkoutMirrorPresentationV1
    ) async {
        guard authorization.areActivitiesEnabled else {
            cancelPendingMetricUpdate()
            return
        }
        guard let mapped = WorkoutLiveActivityStateMapper.map(
            presentation,
            at: now()
        ) else {
            guard !isWithinReconciliationGrace else { return }
            await endManagedActivity(dismissal: .immediate)
            return
        }

        if isWithinReconciliationGrace {
            isWithinReconciliationGrace = false
            reconciliationGraceTask?.cancel()
            reconciliationGraceTask = nil
            await reconcileExistingActivities()
            return
        }

        if managedSessionID != nil,
           managedSessionID != mapped.attributes.sessionID {
            await endManagedActivity(dismissal: .immediate)
        }

        if mapped.isTerminal {
            suppressionStore.remove(mapped.attributes.sessionID)
            systemEndedSessionIDs.remove(mapped.attributes.sessionID)
            guard managedSessionID == mapped.attributes.sessionID else {
                return
            }
            let dismissal: WorkoutLiveActivityDismissal =
                mapped.contentState.finalOutcome == .saved
                ? .after(
                    now().addingTimeInterval(
                        Self.finalSummaryDismissalInterval
                    )
                )
                : .immediate
            await endManagedActivity(
                finalContent: mapped.contentState,
                dismissal: dismissal
            )
            return
        }

        guard let managedActivityID else {
            guard mapped.isStartEligible,
                  isApplicationForeground,
                  !suppressionStore.contains(
                      mapped.attributes.sessionID
                  ),
                  !systemEndedSessionIDs.contains(
                      mapped.attributes.sessionID
                  ) else {
                return
            }
            requestActivity(mapped)
            return
        }

        await publish(
            mapped.contentState,
            to: managedActivityID
        )
    }

    private func requestActivity(
        _ mapped: WorkoutLiveActivityMappedPresentation
    ) {
        do {
            let content = mapped.contentState
            let record = try client.request(
                attributes: mapped.attributes,
                contentState: content,
                staleDate: staleDate(for: content)
            )
            retain(record)
            lastPublishedContent = content
            lastPublishedAt = now()
        } catch {
            // ActivityKit failure is display-only. A later verified store
            // update or foreground transition may safely try again.
        }
    }

    private func publish(
        _ content: WorkoutLiveActivityAttributes.ContentState,
        to activityID: String
    ) async {
        guard content != lastPublishedContent else { return }
        let elapsedSinceLastUpdate = lastPublishedAt.map {
            max(0, now().timeIntervalSince($0))
        } ?? Self.metricUpdateInterval
        let requiresImmediateUpdate = isCriticalChange(
            from: lastPublishedContent,
            to: content
        )

        guard requiresImmediateUpdate
            || elapsedSinceLastUpdate >= Self.metricUpdateInterval else {
            pendingMetricContent = content
            scheduleMetricUpdate(
                after: Self.metricUpdateInterval - elapsedSinceLastUpdate
            )
            return
        }
        cancelPendingMetricUpdate()
        await update(content, activityID: activityID)
    }

    private func scheduleMetricUpdate(after delay: TimeInterval) {
        guard metricUpdateTask == nil else { return }
        let wait = wait
        metricUpdateTask = Task { @MainActor [weak self] in
            do {
                try await wait(max(0, delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            metricUpdateTask = nil
            guard let content = pendingMetricContent,
                  let activityID = managedActivityID else {
                pendingMetricContent = nil
                return
            }
            pendingMetricContent = nil
            await update(content, activityID: activityID)
        }
    }

    private func update(
        _ content: WorkoutLiveActivityAttributes.ContentState,
        activityID: String
    ) async {
        do {
            try await client.update(
                id: activityID,
                contentState: content,
                staleDate: staleDate(for: content)
            )
            lastPublishedContent = content
            lastPublishedAt = now()
        } catch {
            // Keep the previous publication marker so a later verified store
            // update retries. Workout state is never changed here.
        }
    }

    private func endManagedActivity(
        finalContent: WorkoutLiveActivityAttributes.ContentState? = nil,
        dismissal: WorkoutLiveActivityDismissal
    ) async {
        cancelPendingMetricUpdate()
        activityStateTask?.cancel()
        activityStateTask = nil
        guard let activityID = managedActivityID else { return }
        await client.end(
            id: activityID,
            contentState: finalContent,
            dismissal: dismissal
        )
        managedActivityID = nil
        managedSessionID = nil
        lastPublishedContent = nil
        lastPublishedAt = nil
    }

    private func retain(_ record: WorkoutLiveActivityRecord) {
        managedActivityID = record.id
        managedSessionID = record.attributes.sessionID
        lastPublishedContent = record.contentState
        observeSystemState(
            activityID: record.id,
            sessionID: record.attributes.sessionID
        )
    }

    private func observeSystemState(
        activityID: String,
        sessionID: UUID
    ) {
        activityStateTask?.cancel()
        let updates = client.stateUpdates(for: activityID)
        activityStateTask = Task { @MainActor [weak self] in
            for await state in updates {
                guard let self,
                      managedActivityID == activityID,
                      managedSessionID == sessionID else {
                    return
                }
                switch state {
                case .dismissed:
                    suppressionStore.insert(sessionID)
                    abandonManagedActivity()
                    return
                case .ended:
                    systemEndedSessionIDs.insert(sessionID)
                    abandonManagedActivity()
                    return
                case .active, .stale:
                    break
                }
            }
        }
    }

    private func abandonManagedActivity() {
        cancelPendingMetricUpdate()
        managedActivityID = nil
        managedSessionID = nil
        lastPublishedContent = nil
        lastPublishedAt = nil
        activityStateTask?.cancel()
        activityStateTask = nil
    }

    private func cancelPendingMetricUpdate() {
        metricUpdateTask?.cancel()
        metricUpdateTask = nil
        pendingMetricContent = nil
    }

    private func staleDate(
        for content: WorkoutLiveActivityAttributes.ContentState
    ) -> Date? {
        guard content.phase == .running || content.phase == .paused else {
            return nil
        }
        return content.capturedAt.addingTimeInterval(
            WorkoutMirrorStateReducer.defaultStaleAfter
        )
    }

    private func isCriticalChange(
        from previous: WorkoutLiveActivityAttributes.ContentState?,
        to next: WorkoutLiveActivityAttributes.ContentState
    ) -> Bool {
        guard let previous else { return true }
        return previous.phase != next.phase
            || previous.pendingAction != next.pendingAction
            || previous.finalOutcome != next.finalOutcome
            || previous.displayError != next.displayError
            || previous.lastCompletedSegmentIndex
                != next.lastCompletedSegmentIndex
            || previous.lastCompletedSegmentDuration
                != next.lastCompletedSegmentDuration
            || previous.lastCompletedSegmentDistanceMeters
                != next.lastCompletedSegmentDistanceMeters
    }
}
