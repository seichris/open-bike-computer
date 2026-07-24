import Foundation

@available(iOS 17.0, *)
@MainActor
protocol WorkoutLiveActivityControlStateProviding: AnyObject {
    var presentation: WorkoutMirrorPresentationV1 { get }
    var supportsSegmentMarking: Bool { get }
    var isSegmentConfirmationPending: Bool { get }
}

@available(iOS 17.0, *)
extension WorkoutMetricsStore: WorkoutLiveActivityControlStateProviding {}

@available(iOS 17.0, *)
@MainActor
final class WorkoutLiveActivityCommandRouter: @unchecked Sendable {
    nonisolated static let defaultRecoveryTimeout: TimeInterval = 2
    nonisolated static let defaultActionResolutionTimeout: TimeInterval = 2
    nonisolated static let recoveryPollInterval: TimeInterval = 0.1

    private let controlState:
        any WorkoutLiveActivityControlStateProviding
    private let markSegmentAction: @MainActor () -> Void
    private let pauseAction: @MainActor () -> Void
    private let resumeAction: @MainActor () -> Void
    private let recoveryTimeout: TimeInterval
    private let actionResolutionTimeout: TimeInterval
    private let wait:
        @MainActor @Sendable (TimeInterval) async throws -> Void
    private let actionResolutionWait:
        @MainActor @Sendable (TimeInterval) async throws -> Void

    convenience init(manager: WorkoutMirrorManager) {
        self.init(
            store: manager.store,
            markSegment: { manager.markSegment() },
            pause: { manager.pause() },
            resume: { manager.resume() }
        )
    }

    init(
        store: any WorkoutLiveActivityControlStateProviding,
        recoveryTimeout: TimeInterval = defaultRecoveryTimeout,
        actionResolutionTimeout: TimeInterval =
            defaultActionResolutionTimeout,
        wait: (@MainActor @Sendable (TimeInterval) async throws -> Void)? = nil,
        actionResolutionWait: (@MainActor @Sendable (
            TimeInterval
        ) async throws -> Void)? = nil,
        markSegment: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () -> Void,
        resume: @escaping @MainActor () -> Void
    ) {
        controlState = store
        self.recoveryTimeout = recoveryTimeout.isFinite
            ? min(max(0, recoveryTimeout), 5)
            : Self.defaultRecoveryTimeout
        self.actionResolutionTimeout = actionResolutionTimeout.isFinite
            ? min(max(0, actionResolutionTimeout), 5)
            : Self.defaultActionResolutionTimeout
        self.wait = wait ?? { interval in
            try await Task.sleep(
                nanoseconds: UInt64(interval * 1_000_000_000)
            )
        }
        self.actionResolutionWait = actionResolutionWait ?? { interval in
            try await Task.sleep(
                nanoseconds: UInt64(interval * 1_000_000_000)
            )
        }
        markSegmentAction = markSegment
        pauseAction = pause
        resumeAction = resume
    }

    func perform(
        _ action: WorkoutLiveActivityAction,
        sessionID: UUID
    ) async -> Bool {
        guard await recoverSessionIfNeeded(sessionID: sessionID) else {
            return false
        }
        let presentation = controlState.presentation
        guard presentation.sessionID == sessionID,
              presentation.connectionState == .connected,
              presentation.pendingControl == nil,
              presentation.errorCode != .terminalChoiceUnconfirmed else {
            return false
        }

        switch action {
        case .segment:
            guard presentation.sessionState == .running,
                  controlState.supportsSegmentMarking,
                  !controlState.isSegmentConfirmationPending else {
                return false
            }
            markSegmentAction()
            return controlState.presentation.pendingControl == .markSegment
        case .pause:
            guard presentation.sessionState == .running else { return false }
            pauseAction()
            return controlState.presentation.pendingControl == .pause
        case .resume:
            guard presentation.sessionState == .paused else { return false }
            resumeAction()
            return controlState.presentation.pendingControl == .resume
        }
    }

    func waitForResolution(
        of action: WorkoutLiveActivityAction,
        sessionID: UUID
    ) async {
        let expectedControl: WorkoutControlV1
        switch action {
        case .segment:
            expectedControl = .markSegment
        case .pause:
            expectedControl = .pause
        case .resume:
            expectedControl = .resume
        }

        var remaining = actionResolutionTimeout
        while remaining > 0,
              controlState.presentation.sessionID == sessionID,
              controlState.presentation.pendingControl == expectedControl {
            let interval = min(Self.recoveryPollInterval, remaining)
            do {
                try await actionResolutionWait(interval)
            } catch {
                return
            }
            remaining -= interval
        }
    }

    private func recoverSessionIfNeeded(sessionID: UUID) async -> Bool {
        if controlState.presentation.sessionID == sessionID {
            return true
        }
        // A different verified session must never be displaced by an old
        // Lock Screen action.
        if controlState.presentation.sessionID != nil {
            return false
        }

        var remaining = recoveryTimeout
        while remaining > 0 {
            let interval = min(Self.recoveryPollInterval, remaining)
            do {
                try await wait(interval)
            } catch {
                return false
            }
            remaining -= interval
            if controlState.presentation.sessionID == sessionID {
                return true
            }
            if controlState.presentation.sessionID != nil {
                return false
            }
        }
        return false
    }
}
