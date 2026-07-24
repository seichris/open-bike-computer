import ActivityKit
import Combine
import Foundation
import OSLog
import UIKit

@MainActor
protocol WorkoutLiveActivityDiagnosticReporting: AnyObject {
    func setIssue(_ message: String?)
}

@MainActor
final class WorkoutLiveActivityDiagnosticStore:
    ObservableObject,
    WorkoutLiveActivityDiagnosticReporting {
    @Published private(set) var issueMessage: String?

    func setIssue(_ message: String?) {
        issueMessage = message
    }
}

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
    var supportsSegmentMarking: Bool { get }
    var isSegmentConfirmationPending: Bool { get }
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
    nonisolated static let reconciliationGracePeriod: TimeInterval =
        WorkoutMirrorStateReducer.defaultStartTimeout
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BikeComputer",
        category: "WorkoutLiveActivity"
    )

    private let presentationSource:
        any WorkoutLiveActivityPresentationProviding
    private let client: WorkoutLiveActivityClient
    private let authorization: WorkoutLiveActivityAuthorizationProviding
    private let suppressionStore: WorkoutLiveActivitySuppressionStoring
    private let diagnostics: any WorkoutLiveActivityDiagnosticReporting
    private let finalizationBackgroundLease:
        any WorkoutBackgroundExecutionLeasing
    private let backgroundTimeRemaining: () -> TimeInterval
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
    private var pendingPresentation: WorkoutMirrorPresentationV1?
    private var presentationProcessingTask: Task<Void, Never>?
    private var pendingMetricContent:
        WorkoutLiveActivityAttributes.ContentState?
    private var isMetricUpdateDue = false
    private var metricUpdateTask: Task<Void, Never>?
    private var activityStateTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var reconciliationGraceTask: Task<Void, Never>?
    private var hasReconciled = false
    private var isWithinReconciliationGrace = false
    private var isReconciliationGraceExpiryPending = false
    private var isApplicationForeground = false
    private var systemEndedSessionIDs: Set<UUID> = []
    private var lastDiagnosticIssue: String?

    init(
        store: WorkoutMetricsStore,
        client: WorkoutLiveActivityClient? = nil,
        authorization: WorkoutLiveActivityAuthorizationProviding? = nil,
        suppressionStore: WorkoutLiveActivitySuppressionStoring? = nil,
        diagnostics:
            (any WorkoutLiveActivityDiagnosticReporting)? = nil,
        finalizationBackgroundLease:
            (any WorkoutBackgroundExecutionLeasing)? = nil,
        backgroundTimeRemaining: (() -> TimeInterval)? = nil,
        now: @escaping () -> Date = Date.init,
        wait: (@MainActor @Sendable (TimeInterval) async throws -> Void)? = nil
    ) {
        presentationSource = store
        self.client = client ?? SystemWorkoutLiveActivityClient()
        self.authorization = authorization
            ?? SystemWorkoutLiveActivityAuthorizationProvider()
        self.suppressionStore = suppressionStore
            ?? WorkoutLiveActivitySuppressionStore()
        self.diagnostics = diagnostics
            ?? WorkoutLiveActivityDiagnosticStore()
        self.finalizationBackgroundLease =
            finalizationBackgroundLease
            ?? SystemWorkoutBackgroundExecutionLease()
        self.backgroundTimeRemaining = backgroundTimeRemaining
            ?? Self.defaultBackgroundTimeRemaining
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
        diagnostics:
            (any WorkoutLiveActivityDiagnosticReporting)? = nil,
        finalizationBackgroundLease:
            (any WorkoutBackgroundExecutionLeasing)? = nil,
        backgroundTimeRemaining: (() -> TimeInterval)? = nil,
        now: @escaping () -> Date = Date.init,
        wait: (@MainActor @Sendable (TimeInterval) async throws -> Void)? = nil
    ) {
        self.presentationSource = presentationSource
        self.client = client
        self.authorization = authorization
        self.suppressionStore = suppressionStore
        self.diagnostics = diagnostics
            ?? WorkoutLiveActivityDiagnosticStore()
        self.finalizationBackgroundLease =
            finalizationBackgroundLease
            ?? SystemWorkoutBackgroundExecutionLease()
        self.backgroundTimeRemaining = backgroundTimeRemaining
            ?? Self.defaultBackgroundTimeRemaining
        self.now = now
        self.wait = wait ?? { interval in
            try await Task.sleep(
                nanoseconds: UInt64(interval * 1_000_000_000)
            )
        }
        latestPresentation = presentationSource.presentation
    }

    private static func defaultBackgroundTimeRemaining() -> TimeInterval {
#if WORKOUT_CONTRACT_XCTEST
        .greatestFiniteMagnitude
#else
        UIApplication.shared.backgroundTimeRemaining
#endif
    }

    deinit {
        presentationProcessingTask?.cancel()
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
        Self.logger.notice(
            "Starting Live Activity controller; foreground=\(isApplicationForeground)"
        )
        self.isApplicationForeground = isApplicationForeground
        latestPresentation = presentationSource.presentation
        let publisher = presentationSource.presentationPublisher
        presentationCancellable = publisher.sink {
            [weak self] presentation in
            guard let self else { return }
            latestPresentation = presentation
            // Initial reconciliation may already have retained the matching
            // Activity and be suspended while ending a duplicate. Preserve
            // the manager-to-controller finalization lease handoff even
            // though presentation processing must remain serialized behind
            // reconciliation.
            retainFinalizationBackgroundExecutionIfNeeded(
                for: presentation
            )
            guard hasReconciled else { return }
            enqueue(presentation)
        }
        reconciliationTask = Task { @MainActor [weak self] in
            await self?.reconcileExistingActivities()
        }
    }

    func setApplicationForeground(_ isForeground: Bool) {
        Self.logger.debug(
            "Application foreground state changed to \(isForeground)"
        )
        isApplicationForeground = isForeground
        guard isForeground, hasReconciled else { return }
        enqueue(latestPresentation)
    }

    @discardableResult
    func publishCurrentStateForIntent(sessionID: UUID) async -> Bool {
        if let reconciliationTask {
            await reconciliationTask.value
        }
        guard hasReconciled else { return false }

        let presentation = presentationSource.presentation
        latestPresentation = presentation
        guard WorkoutLiveActivityStateMapper.map(
            presentation,
            at: now(),
            supportsSegmentMarking:
                presentationSource.supportsSegmentMarking,
            isSegmentConfirmationPending:
                presentationSource.isSegmentConfirmationPending
        )?.attributes.sessionID == sessionID else {
            return false
        }

        enqueue(presentation)
        while let processingTask = presentationProcessingTask {
            await processingTask.value
        }

        guard managedSessionID == sessionID,
              let publishedContent = lastPublishedContent,
              let currentContent = WorkoutLiveActivityStateMapper.map(
                  presentationSource.presentation,
                  at: now(),
                  supportsSegmentMarking:
                      presentationSource.supportsSegmentMarking,
                  isSegmentConfirmationPending:
                      presentationSource.isSegmentConfirmationPending
              )?.contentState else {
            return false
        }
        return publishedContent == currentContent
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
            at: now(),
            supportsSegmentMarking:
                presentationSource.supportsSegmentMarking,
            isSegmentConfirmationPending:
                presentationSource.isSegmentConfirmationPending
        )

        if let mapped {
            let matching = records.filter {
                $0.attributes.sessionID == mapped.attributes.sessionID
            }
            if let retained = matching.first {
                retain(retained)
            }
            for record in records where record.id != managedActivityID {
                let currentSessionID = WorkoutLiveActivityStateMapper.map(
                    latestPresentation,
                    at: now(),
                    supportsSegmentMarking:
                        presentationSource.supportsSegmentMarking,
                    isSegmentConfirmationPending:
                        presentationSource.isSegmentConfirmationPending
                )?.attributes.sessionID
                guard currentSessionID == mapped.attributes.sessionID else {
                    await reconcileExistingActivities()
                    return
                }
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
        enqueue(latestPresentation)
        if !isWithinReconciliationGrace {
            releaseReconciliationLeaseIfNoTerminalFinalization()
        }
    }

    private func beginReconciliationGrace() {
        isWithinReconciliationGrace = true
        isReconciliationGraceExpiryPending = false
        reconciliationGraceTask?.cancel()
        finalizationBackgroundLease.begin { [weak self] in
            guard let self, isWithinReconciliationGrace else { return }
            reconciliationGraceTask?.cancel()
            reconciliationGraceTask = nil
            isReconciliationGraceExpiryPending = true
            enqueue(latestPresentation)
        }
        let grace = WorkoutBackgroundExecutionBudget.boundedDelay(
            requested: Self.reconciliationGracePeriod,
            backgroundTimeRemaining: backgroundTimeRemaining()
        )
        if grace == 0 {
            isReconciliationGraceExpiryPending = true
            enqueue(latestPresentation)
            return
        }
        let wait = wait
        reconciliationGraceTask = Task { @MainActor [weak self] in
            do {
                try await wait(grace)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            isReconciliationGraceExpiryPending = true
            enqueue(latestPresentation)
        }
    }

    private func enqueue(
        _ presentation: WorkoutMirrorPresentationV1
    ) {
        retainFinalizationBackgroundExecutionIfNeeded(
            for: presentation
        )
        pendingPresentation = presentation
        guard presentationProcessingTask == nil else { return }
        presentationProcessingTask = Task { @MainActor [weak self] in
            await self?.processPendingPresentations()
        }
    }

    private func processPendingPresentations() async {
        while !Task.isCancelled,
              let presentation = pendingPresentation {
            pendingPresentation = nil
            if isReconciliationGraceExpiryPending {
                isReconciliationGraceExpiryPending = false
                await expireReconciliationGrace()
            } else {
                await handle(presentation)
            }
        }
        presentationProcessingTask = nil
    }

    private func expireReconciliationGrace() async {
        guard isWithinReconciliationGrace else { return }
        isWithinReconciliationGrace = false
        reconciliationGraceTask = nil

        if WorkoutLiveActivityStateMapper.map(
            latestPresentation,
            at: now(),
            supportsSegmentMarking:
                presentationSource.supportsSegmentMarking,
            isSegmentConfirmationPending:
                presentationSource.isSegmentConfirmationPending
        ) != nil {
            await reconcileExistingActivities()
            releaseReconciliationLeaseIfNoTerminalFinalization()
            return
        }

        // Give a terminal or active recovery already queued on the main actor
        // one final chance to win before ActivityKit end content becomes
        // immutable. Recovery after the call below starts is past this
        // relaunch correction cutoff.
        await Task.yield()
        if WorkoutLiveActivityStateMapper.map(
            latestPresentation,
            at: now(),
            supportsSegmentMarking:
                presentationSource.supportsSegmentMarking,
            isSegmentConfirmationPending:
                presentationSource.isSegmentConfirmationPending
        ) != nil {
            await reconcileExistingActivities()
            releaseReconciliationLeaseIfNoTerminalFinalization()
            return
        }

        let records = client.records().filter {
            $0.systemState == .active || $0.systemState == .stale
        }
        for record in records {
            if WorkoutLiveActivityStateMapper.map(
                latestPresentation,
                at: now(),
                supportsSegmentMarking:
                    presentationSource.supportsSegmentMarking,
                isSegmentConfirmationPending:
                    presentationSource.isSegmentConfirmationPending
            ) != nil {
                await reconcileExistingActivities()
                releaseReconciliationLeaseIfNoTerminalFinalization()
                return
            }
            let recoveredFinalContent =
                record.contentState.phase == .ending
                ? unavailableFinalContent(from: record.contentState)
                : nil
            if recoveredFinalContent != nil {
                finalizationBackgroundLease.begin {}
            }
            await client.end(
                id: record.id,
                contentState: recoveredFinalContent,
                dismissal: recoveredFinalContent == nil
                    ? .immediate
                    : .after(
                        now().addingTimeInterval(
                            Self.finalSummaryDismissalInterval
                        )
                    )
            )
            if recoveredFinalContent == nil {
                // A generic orphan is removed immediately, so a late verified
                // active session may create its one replacement.
                suppressionStore.remove(record.attributes.sessionID)
            } else {
                // Finalization is the relaunch correction cutoff. Keep the
                // tombstone so a later recovery cannot create a second card
                // beside immutable unavailable-final content.
                suppressionStore.insert(record.attributes.sessionID)
            }
        }
        finalizationBackgroundLease.end()
        enqueue(latestPresentation)
    }

    private func retainFinalizationBackgroundExecutionIfNeeded(
        for presentation: WorkoutMirrorPresentationV1
    ) {
        guard managedActivityID != nil,
              let managedSessionID,
              let mapped = WorkoutLiveActivityStateMapper.map(
                  presentation,
                  at: now(),
                  supportsSegmentMarking:
                      presentationSource.supportsSegmentMarking,
                  isSegmentConfirmationPending:
                      presentationSource.isSegmentConfirmationPending
              ),
              mapped.isTerminal,
              mapped.attributes.sessionID == managedSessionID else {
            return
        }
        // Combine delivery is synchronous. Acquiring here bridges the manager
        // wait lease to the separately queued ActivityKit end operation.
        finalizationBackgroundLease.begin {}
    }

    private func releaseReconciliationLeaseIfNoTerminalFinalization() {
        let current = WorkoutLiveActivityStateMapper.map(
            latestPresentation,
            at: now(),
            supportsSegmentMarking:
                presentationSource.supportsSegmentMarking,
            isSegmentConfirmationPending:
                presentationSource.isSegmentConfirmationPending
        )
        if managedActivityID == nil || current?.isTerminal != true {
            finalizationBackgroundLease.end()
        }
    }

    private func unavailableFinalContent(
        from content: WorkoutLiveActivityAttributes.ContentState
    ) -> WorkoutLiveActivityAttributes.ContentState {
        WorkoutLiveActivityAttributes.ContentState(
            phase: .final,
            capturedAt: content.capturedAt,
            elapsedActiveSeconds: content.elapsedActiveSeconds,
            currentSpeedKilometersPerHour: nil,
            cyclingDistanceMeters: content.cyclingDistanceMeters,
            currentHeartRateBPM: nil,
            lastCompletedSegmentIndex:
                content.lastCompletedSegmentIndex,
            lastCompletedSegmentDuration:
                content.lastCompletedSegmentDuration,
            lastCompletedSegmentDistanceMeters:
                content.lastCompletedSegmentDistanceMeters,
            isSegmentControlAvailable: false,
            pendingAction: .none,
            finalOutcome: .none,
            displayError: .finalSummaryUnavailable
        )
    }

    private func handle(
        _ presentation: WorkoutMirrorPresentationV1
    ) async {
        guard authorization.areActivitiesEnabled else {
            cancelPendingMetricUpdate()
            reportIssue(
                "Live Activity unavailable: iOS reports that Live Activities "
                    + "are disabled for BikeComputer."
            )
            return
        }
        guard let mapped = WorkoutLiveActivityStateMapper.map(
            presentation,
            at: now(),
            supportsSegmentMarking:
                presentationSource.supportsSegmentMarking,
            isSegmentConfirmationPending:
                presentationSource.isSegmentConfirmationPending
        ) else {
            guard !isWithinReconciliationGrace else { return }
            if shouldRetainManagedActivity(while: presentation) {
                Self.logger.debug(
                    "Keeping the existing Live Activity while waiting for a fresh workout snapshot"
                )
                return
            }
            await endManagedActivity(dismissal: .immediate)
            clearIssue()
            return
        }

        if isWithinReconciliationGrace {
            isWithinReconciliationGrace = false
            isReconciliationGraceExpiryPending = false
            reconciliationGraceTask?.cancel()
            reconciliationGraceTask = nil
            await reconcileExistingActivities()
            releaseReconciliationLeaseIfNoTerminalFinalization()
            return
        }

        if managedSessionID != nil,
           managedSessionID != mapped.attributes.sessionID {
            await endManagedActivity(dismissal: .immediate)
        }

        if mapped.isTerminal {
            clearIssue()
            systemEndedSessionIDs.remove(mapped.attributes.sessionID)
            guard managedSessionID == mapped.attributes.sessionID else {
                return
            }
            suppressionStore.remove(mapped.attributes.sessionID)
            let dismissal: WorkoutLiveActivityDismissal
            switch mapped.contentState.finalOutcome {
            case .saved, .none:
                dismissal = .after(
                    now().addingTimeInterval(
                        Self.finalSummaryDismissalInterval
                    )
                )
            case .discarded:
                dismissal = .immediate
            }
            await endManagedActivity(
                finalContent: mapped.contentState,
                dismissal: dismissal
            )
            return
        }

        guard let managedActivityID else {
            guard mapped.isStartEligible else {
                Self.logger.debug(
                    "Live Activity request is waiting for a verified running or paused workout"
                )
                return
            }
            guard isApplicationForeground else {
                Self.logger.notice(
                    "Live Activity request deferred because the app is not foreground"
                )
                return
            }
            guard !suppressionStore.contains(
                mapped.attributes.sessionID
            ) else {
                reportIssue(
                    "Live Activity hidden because it was dismissed for this "
                        + "workout. Start a new workout to try again."
                )
                return
            }
            guard !systemEndedSessionIDs.contains(
                mapped.attributes.sessionID
            ) else {
                reportIssue(
                    "Live Activity unavailable because iOS already ended it "
                        + "for this workout. Start a new workout to try again."
                )
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

    private func shouldRetainManagedActivity(
        while presentation: WorkoutMirrorPresentationV1
    ) -> Bool {
        guard let managedSessionID,
              presentation.sessionID == managedSessionID else {
            return false
        }
        switch presentation.connectionState {
        case .launchingWatch, .awaitingFirstSnapshot:
            return true
        default:
            return false
        }
    }

    private func requestActivity(
        _ mapped: WorkoutLiveActivityMappedPresentation
    ) {
        let sessionID = mapped.attributes.sessionID.uuidString
        Self.logger.notice(
            "Requesting Live Activity for session \(sessionID, privacy: .public)"
        )
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
            clearIssue()
            Self.logger.notice(
                "Live Activity created; id=\(record.id, privacy: .public)"
            )
        } catch {
            let nsError = error as NSError
            reportIssue(
                "Live Activity failed: \(error.localizedDescription) "
                    + "(\(nsError.domain) \(nsError.code))."
            )
        }
    }

    private func reportIssue(_ message: String) {
        guard message != lastDiagnosticIssue else { return }
        lastDiagnosticIssue = message
        diagnostics.setIssue(message)
        Self.logger.error("\(message, privacy: .public)")
    }

    private func clearIssue() {
        guard lastDiagnosticIssue != nil else { return }
        lastDiagnosticIssue = nil
        diagnostics.setIssue(nil)
        Self.logger.notice("Cleared Live Activity diagnostic issue")
    }

    private func publish(
        _ content: WorkoutLiveActivityAttributes.ContentState,
        to activityID: String
    ) async {
        guard content != lastPublishedContent else {
            cancelPendingMetricUpdate()
            return
        }
        let elapsedSinceLastUpdate = lastPublishedAt.map {
            max(0, now().timeIntervalSince($0))
        } ?? Self.metricUpdateInterval
        let requiresImmediateUpdate = isCriticalChange(
            from: lastPublishedContent,
            to: content
        )

        guard requiresImmediateUpdate
            || isMetricUpdateDue
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
            guard pendingMetricContent != nil,
                  managedActivityID != nil else {
                pendingMetricContent = nil
                return
            }
            isMetricUpdateDue = true
            enqueue(latestPresentation)
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
            guard !Task.isCancelled,
                  managedActivityID == activityID else {
                return
            }
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
        finalizationBackgroundLease.end()
        managedActivityID = nil
        managedSessionID = nil
        lastPublishedContent = nil
        lastPublishedAt = nil
    }

    private func retain(_ record: WorkoutLiveActivityRecord) {
        managedActivityID = record.id
        managedSessionID = record.attributes.sessionID
        // Persist that this session has already owned a Live Activity. If the
        // process is absent when the user dismisses it or the system expires
        // it, a later launch must not create a replacement for the same ride.
        suppressionStore.insert(record.attributes.sessionID)
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
        finalizationBackgroundLease.end()
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
        isMetricUpdateDue = false
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
