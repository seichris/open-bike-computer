import Foundation
import HealthKit
import UIKit

@available(iOS 17.0, *)
@MainActor
protocol WorkoutMirroredSessionTransport: AnyObject {
    var healthKitSession: HKWorkoutSession? { get }
    var sessionStartDate: Date? { get }
    func installDelegate(_ delegate: HKWorkoutSessionDelegate?)
    func pause()
    func resume()
    func send(
        data: Data,
        completion: @escaping @Sendable (Bool, Error?) -> Void
    )
}

@available(iOS 17.0, *)
@MainActor
private final class HealthKitMirroredSessionTransport:
    WorkoutMirroredSessionTransport {
    let session: HKWorkoutSession

    init(session: HKWorkoutSession) {
        self.session = session
    }

    var healthKitSession: HKWorkoutSession? { session }
    var sessionStartDate: Date? { session.startDate }

    func installDelegate(_ delegate: HKWorkoutSessionDelegate?) {
        session.delegate = delegate
    }

    func pause() {
        session.pause()
    }

    func resume() {
        session.resume()
    }

    func send(
        data: Data,
        completion: @escaping @Sendable (Bool, Error?) -> Void
    ) {
        session.sendToRemoteWorkoutSession(data: data, completion: completion)
    }
}

@MainActor
protocol WorkoutBackgroundExecutionLeasing: AnyObject {
    func begin(
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    )
    func end()
}

nonisolated enum WorkoutBackgroundExecutionBudget {
    static let finalizationSafetyMargin: TimeInterval = 5

    static func boundedDelay(
        requested: TimeInterval,
        backgroundTimeRemaining: TimeInterval
    ) -> TimeInterval {
        guard backgroundTimeRemaining.isFinite else {
            return requested
        }
        return min(
            requested,
            max(
                0,
                backgroundTimeRemaining - finalizationSafetyMargin
            )
        )
    }
}

@MainActor
final class SystemWorkoutBackgroundExecutionLease:
    WorkoutBackgroundExecutionLeasing {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin(
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Finalize mirrored workout"
        ) {
            // UIKit's expiration callback is synchronous on the main thread.
            // Do not defer expiration bookkeeping to a Task after the
            // callback returns.
            MainActor.assumeIsolated { [self] in
                expirationHandler()
                self.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// Long-lived iPhone bridge for a Watch-owned primary workout session.
///
/// The manager intentionally has no workout builder and never asks HealthKit
/// for write authorization. Its only session on iPhone is the system-provided
/// mirrored HKWorkoutSession available on iOS 17 and later.
@MainActor
final class WorkoutMirrorManager: NSObject {
    nonisolated static let watchLaunchTimeout: TimeInterval = 15
    nonisolated static let defaultControlConfirmationTimeout: TimeInterval = 10
    nonisolated static let defaultFinalSnapshotTimeout: TimeInterval = 10
    nonisolated static let sessionStartDateMatchTolerance: TimeInterval = 2

    let store: WorkoutMetricsStore

    private let healthStore: HKHealthStore
    private let now: () -> Date
    private let watchLaunchTimeout: TimeInterval
    private let controlConfirmationTimeout: TimeInterval
    private let finalSnapshotTimeout: TimeInterval
    private let firstSnapshotWait:
        @MainActor @Sendable (TimeInterval) async throws -> Void
    private let controlConfirmationWait:
        @MainActor @Sendable (TimeInterval) async throws -> Void
    private let finalSnapshotWait:
        @MainActor @Sendable (TimeInterval) async throws -> Void
    private let finalSnapshotBackgroundLease:
        any WorkoutBackgroundExecutionLeasing
    private let backgroundTimeRemaining: () -> TimeInterval
    private let terminalFailureDrainWait:
        @MainActor @Sendable (TimeInterval) async throws -> Void
    private let launchWatchApp: (
        HKWorkoutConfiguration,
        @escaping @Sendable (Bool, Error?) -> Void
    ) -> Void

    private var isHandlerInstalled = false
    private var mirroredSessionStorage: AnyObject?
    private var launchTimeoutTask: Task<Void, Never>?
    private var firstSnapshotTimeoutTask: Task<Void, Never>?
    private var firstSnapshotTimeoutAttemptID: UUID?
    private var freshnessTask: Task<Void, Never>?
    private var pendingControlTimeoutTask: Task<Void, Never>?
    private var pendingControlTimeoutAttemptID: UUID?
    private var finalSnapshotTimeoutTask: Task<Void, Never>?
    private var finalSnapshotTimeoutAttemptID: UUID?
    private var terminalFailureDrainTimeoutTask: Task<Void, Never>?
    private var terminalFailureDrainTimeoutAttemptID: UUID?
    private var pendingTerminalFailureCode: WorkoutSafeErrorCodeV1?
    private var pendingTerminalFailureSessionID: UUID?
    private var pendingTerminalFailureOriginStartDate: Date?
    private var pendingTerminalFailureOriginTransportStorage: AnyObject?
    private var pendingTerminalFailureOriginAttachmentID: UUID?
    private var currentTransportAttachmentID: UUID?
    private var currentTransportSessionID: UUID?
    private var currentTransportStartDate: Date?
    private var pendingControlTimeoutControl: WorkoutControlV1?
    private var pendingControlTimeoutSequence: UInt64?

    private var controlSequencer = WorkoutControlEnvelopeSequencer()
    private var remoteQueue: [RemoteMessage] = []
    private var remoteSendInFlight: RemoteSendAttempt?
    private var segmentStatusReplayMessage: RemoteMessage?
    private var segmentReplayAfterSendAttemptID: UUID?

    init(
        healthStore: HKHealthStore = HKHealthStore(),
        store: WorkoutMetricsStore? = nil,
        now: @escaping () -> Date = Date.init,
        watchLaunchTimeout: TimeInterval = WorkoutMirrorManager.watchLaunchTimeout,
        controlConfirmationTimeout: TimeInterval =
            WorkoutMirrorManager.defaultControlConfirmationTimeout,
        finalSnapshotTimeout: TimeInterval =
            WorkoutMirrorManager.defaultFinalSnapshotTimeout,
        firstSnapshotWait: (@MainActor @Sendable (
            TimeInterval
        ) async throws -> Void)? = nil,
        controlConfirmationWait: (@MainActor @Sendable (
            TimeInterval
        ) async throws -> Void)? = nil,
        finalSnapshotWait: (@MainActor @Sendable (
            TimeInterval
        ) async throws -> Void)? = nil,
        finalSnapshotBackgroundLease:
            (any WorkoutBackgroundExecutionLeasing)? = nil,
        backgroundTimeRemaining: (() -> TimeInterval)? = nil,
        terminalFailureDrainWait: (@MainActor @Sendable (
            TimeInterval
        ) async throws -> Void)? = nil,
        launchWatchApp: ((
            HKWorkoutConfiguration,
            @escaping @Sendable (Bool, Error?) -> Void
        ) -> Void)? = nil
    ) {
        self.healthStore = healthStore
        self.store = store ?? WorkoutMetricsStore(now: now)
        self.now = now
        self.watchLaunchTimeout = watchLaunchTimeout.isFinite
            ? min(max(0.01, watchLaunchTimeout), 60)
            : Self.watchLaunchTimeout
        self.controlConfirmationTimeout = controlConfirmationTimeout.isFinite
            ? min(max(0, controlConfirmationTimeout), 60)
            : Self.defaultControlConfirmationTimeout
        self.finalSnapshotTimeout = finalSnapshotTimeout.isFinite
            ? min(max(0.01, finalSnapshotTimeout), 60)
            : Self.defaultFinalSnapshotTimeout
        self.firstSnapshotWait = firstSnapshotWait ?? { timeout in
            try await Task.sleep(
                nanoseconds: UInt64(timeout * 1_000_000_000)
            )
        }
        self.controlConfirmationWait = controlConfirmationWait ?? { timeout in
            try await Task.sleep(
                nanoseconds: UInt64(timeout * 1_000_000_000)
            )
        }
        self.finalSnapshotWait = finalSnapshotWait ?? { timeout in
            try await Task.sleep(
                nanoseconds: UInt64(timeout * 1_000_000_000)
            )
        }
        self.finalSnapshotBackgroundLease =
            finalSnapshotBackgroundLease
            ?? SystemWorkoutBackgroundExecutionLease()
        self.backgroundTimeRemaining = backgroundTimeRemaining
            ?? Self.defaultBackgroundTimeRemaining
        self.terminalFailureDrainWait = terminalFailureDrainWait
            ?? { timeout in
                try await Task.sleep(
                    nanoseconds: UInt64(timeout * 1_000_000_000)
                )
            }
        self.launchWatchApp = launchWatchApp ?? { configuration, completion in
            healthStore.startWatchApp(
                with: configuration,
                completion: completion
            )
        }
        super.init()
    }

    private static func defaultBackgroundTimeRemaining() -> TimeInterval {
#if WORKOUT_CONTRACT_XCTEST
        .greatestFiniteMagnitude
#else
        UIApplication.shared.backgroundTimeRemaining
#endif
    }

    deinit {
        launchTimeoutTask?.cancel()
        firstSnapshotTimeoutTask?.cancel()
        freshnessTask?.cancel()
        pendingControlTimeoutTask?.cancel()
        finalSnapshotTimeoutTask?.cancel()
        terminalFailureDrainTimeoutTask?.cancel()
    }

    /// Must be called from AppDelegate launch before SwiftUI depends on the
    /// store. Apple may launch the app in the background to invoke this handler.
    func installMirroringHandler() {
        guard !isHandlerInstalled else { return }
        isHandlerInstalled = true
        guard #available(iOS 17.0, *) else {
            store.markUnsupported()
            return
        }

        let callbackReference = WorkoutWeakReference(self)
        healthStore.workoutSessionMirroringStartHandler = { session in
            Task { @MainActor in
                callbackReference.value?.acceptMirroredSession(session)
            }
        }
        startFreshnessTimerIfNeeded()
    }

    func startOutdoorCyclingOnWatch() {
        guard #available(iOS 17.0, *) else {
            store.markUnsupported()
            return
        }
        guard pendingTerminalFailureCode == nil else { return }
        let launchID = UUID()
        let requestDate = now()
        guard store.beginWatchLaunch(
            id: launchID,
            at: requestDate,
            timeout: watchLaunchTimeout
        ) else {
            return
        }
        mirroredTransport?.installDelegate(nil)
        mirroredTransport = nil
        resetRemoteTransport()

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .outdoor

        scheduleLaunchTimeout(id: launchID)
        let callbackReference = WorkoutWeakReference(self)
        launchWatchApp(configuration) { success, error in
            Task { @MainActor in
                guard let manager = callbackReference.value else { return }
                let completedCurrentLaunch = manager.store.completeWatchLaunch(
                    id: launchID,
                    succeeded: success,
                    error: success ? nil : Self.safeLaunchErrorCode(for: error)
                )
                if !success, completedCurrentLaunch {
                    manager.launchTimeoutTask?.cancel()
                    manager.launchTimeoutTask = nil
                }
            }
        }
    }

    func pause() {
        guard #available(iOS 17.0, *),
              let session = mirroredTransport,
              store.presentation.sessionState == .running else {
            return
        }
        releasePendingSegmentForLifecycleControl(
            prioritizeRemoteQueue: false
        )
        guard store.markPendingControl(.pause) else {
            return
        }
        session.pause()
        scheduleControlConfirmationTimeout(for: .pause)
    }

    func resume() {
        guard #available(iOS 17.0, *),
              let session = mirroredTransport,
              store.presentation.sessionState == .paused else {
            return
        }
        releasePendingSegmentForLifecycleControl(
            prioritizeRemoteQueue: false
        )
        guard store.markPendingControl(.resume) else {
            return
        }
        session.resume()
        scheduleControlConfirmationTimeout(for: .resume)
    }

    func markSegment() {
        guard store.presentation.sessionState == .running,
              store.supportsSegmentMarking,
              !store.isSegmentConfirmationPending else {
            return
        }
        enqueueStateChangingControl(.markSegment)
    }

    func endAndSave() {
        releasePendingSegmentForLifecycleControl(
            prioritizeRemoteQueue: true
        )
        enqueueStateChangingControl(.endAndSave)
    }

    func discard() {
        releasePendingSegmentForLifecycleControl(
            prioritizeRemoteQueue: true
        )
        enqueueStateChangingControl(.discard)
    }

    @discardableResult
    func resetTerminalPresentation() -> Bool {
        guard pendingTerminalFailureCode == nil,
              !store.presentation.isWorkoutActive,
              store.presentation.pendingControl == nil,
              store.resetTerminalPresentation() else {
            return false
        }
        if #available(iOS 17.0, *) {
            mirroredTransport?.installDelegate(nil)
            mirroredTransport = nil
        }
        resetRemoteTransport()
        return true
    }

    func refreshFreshness() {
        store.refreshFreshness(at: now())
    }

    private func scheduleLaunchTimeout(id: UUID) {
        launchTimeoutTask?.cancel()
        let timeout = watchLaunchTimeout
        launchTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(timeout * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self else { return }
            _ = store.timeOutWatchLaunch(id: id, at: now())
            launchTimeoutTask = nil
        }
    }

    private func scheduleFirstSnapshotTimeout() {
        cancelFirstSnapshotTimeout()
        let timeout = watchLaunchTimeout
        let attemptID = UUID()
        let wait = firstSnapshotWait
        firstSnapshotTimeoutAttemptID = attemptID
        firstSnapshotTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await wait(timeout)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  firstSnapshotTimeoutAttemptID == attemptID else {
                return
            }
            guard store.timeOutFirstSnapshot() else {
                firstSnapshotTimeoutTask = nil
                firstSnapshotTimeoutAttemptID = nil
                return
            }
            if store.presentation.connectionState == .failed {
                if #available(iOS 17.0, *) {
                    mirroredTransport?.installDelegate(nil)
                    mirroredTransport = nil
                }
                resetRemoteTransport()
            } else {
                firstSnapshotTimeoutTask = nil
                firstSnapshotTimeoutAttemptID = nil
            }
        }
    }

    private func cancelFirstSnapshotTimeout() {
        firstSnapshotTimeoutTask?.cancel()
        firstSnapshotTimeoutTask = nil
        firstSnapshotTimeoutAttemptID = nil
    }

    private func startFreshnessTimerIfNeeded() {
        guard freshnessTask == nil else { return }
        freshnessTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard let self else { return }
                store.refreshFreshness(at: now())
                synchronizeControlTimeoutWithPresentation()
            }
        }
    }

    private func scheduleControlConfirmationTimeout(
        for control: WorkoutControlV1,
        sequence: UInt64? = nil
    ) {
        cancelControlConfirmationTimeout()
        pendingControlTimeoutControl = control
        pendingControlTimeoutSequence = sequence
        let confirmationTimeout = controlConfirmationTimeout
        let attemptID = UUID()
        let wait = controlConfirmationWait
        pendingControlTimeoutAttemptID = attemptID
        pendingControlTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await wait(confirmationTimeout)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  pendingControlTimeoutAttemptID == attemptID,
                  pendingControlTimeoutControl == control,
                  pendingControlTimeoutSequence == sequence,
                  store.presentation.pendingControl == control,
                  store.currentPendingControlSequence == sequence else {
                return
            }
            remoteQueue.removeAll {
                $0.control == control
                    && $0.envelope.sequence == sequence
            }
            if control == .endAndSave
                || control == .discard
                || control == .markSegment {
                // HealthKit does not provide cancellation for a remote send.
                // Once the correlated control has exhausted its bounded
                // confirmation window, invalidate whichever attempt owns the
                // queue so a later terminal retry can be submitted. Its late
                // callback is ignored by the attempt-ID guard.
                remoteSendInFlight = nil
            }
            store.failPendingControl(
                control,
                sequence: sequence,
                error: control == .endAndSave || control == .discard
                    ? .terminalChoiceUnconfirmed
                    : control == .markSegment
                        ? .segmentMarkUnconfirmed
                        : .watchUnavailable
            )
            pendingControlTimeoutControl = nil
            pendingControlTimeoutSequence = nil
            pendingControlTimeoutTask = nil
            pendingControlTimeoutAttemptID = nil
            synchronizeFinalSnapshotTimeoutWithPresentation()
            enqueueUnconfirmedSegmentReplayIfNeeded()
            drainRemoteQueue()
        }
    }

    private func cancelControlConfirmationTimeout() {
        pendingControlTimeoutTask?.cancel()
        pendingControlTimeoutTask = nil
        pendingControlTimeoutAttemptID = nil
        pendingControlTimeoutControl = nil
        pendingControlTimeoutSequence = nil
    }

    private func releasePendingSegmentForLifecycleControl(
        prioritizeRemoteQueue: Bool
    ) {
        guard store.presentation.pendingControl == .markSegment,
              let sequence = store.currentPendingControlSequence else {
            if prioritizeRemoteQueue {
                abandonSegmentStatusReplay()
            }
            return
        }
        let markWasSubmitted =
            remoteSendInFlight?.message.control == .markSegment
                && remoteSendInFlight?.message.envelope.sequence == sequence
                || pendingControlTimeoutControl == .markSegment
                    && pendingControlTimeoutSequence == sequence
        let submittedMarkAttemptID = remoteSendInFlight.flatMap { attempt in
            attempt.message.control == .markSegment
                && attempt.message.envelope.sequence == sequence
                ? attempt.id
                : nil
        }
        remoteQueue.removeAll {
            $0.control == .markSegment
                && $0.envelope.sequence == sequence
        }
        if prioritizeRemoteQueue {
            remoteQueue.removeAll {
                $0.control == .requestCurrentSnapshot
            }
            if markWasSubmitted
                || remoteSendInFlight?.message.control
                    == .requestCurrentSnapshot {
                remoteSendInFlight = nil
            }
            // A terminal choice supersedes status recovery for this boundary.
            // Never resurrect the mark after End or Discard has been sent.
            abandonSegmentStatusReplay()
        } else {
            // Pause/resume may overtake a submitted mark. If its transport
            // callback is still outstanding, replay exactly once when that
            // particular callback releases the queue.
            segmentReplayAfterSendAttemptID = submittedMarkAttemptID
        }
        cancelControlConfirmationTimeout()
        store.failPendingControl(
            .markSegment,
            sequence: sequence,
            error: markWasSubmitted
                ? .segmentMarkUnconfirmed
                : .segmentMarkFailed
        )
        if !prioritizeRemoteQueue {
            enqueueUnconfirmedSegmentReplayIfNeeded()
            drainRemoteQueue()
        }
    }

    private func abandonSegmentStatusReplay() {
        guard let message = segmentStatusReplayMessage else {
            segmentReplayAfterSendAttemptID = nil
            return
        }
        let sequence = message.envelope.sequence
        remoteQueue.removeAll {
            $0.control == .markSegment
                && $0.envelope.sequence == sequence
        }
        if remoteSendInFlight?.message.control == .markSegment,
           remoteSendInFlight?.message.envelope.sequence == sequence {
            remoteSendInFlight = nil
        }
        segmentStatusReplayMessage = nil
        segmentReplayAfterSendAttemptID = nil
    }

    private func synchronizeControlTimeoutWithPresentation() {
        guard store.presentation.pendingControl == nil else { return }
        cancelControlConfirmationTimeout()
    }

    private func synchronizeFinalSnapshotTimeoutWithPresentation() {
        let presentation = store.presentation
        guard presentation.connectionState == .ended,
              presentation.finalSnapshot?.terminalOutcome == nil,
              presentation.pendingControl == nil,
              !store.canResetTerminalPresentation else {
            cancelFinalSnapshotTimeout()
            return
        }
        guard finalSnapshotTimeoutTask == nil else { return }
        let attemptID = UUID()
        let wait = finalSnapshotWait
        finalSnapshotTimeoutAttemptID = attemptID
        finalSnapshotBackgroundLease.begin { [weak self] in
            guard let self,
                  finalSnapshotTimeoutAttemptID == attemptID else {
                return
            }
            _ = store.timeOutFinalSnapshot()
            cancelFinalSnapshotTimeout()
        }
        guard finalSnapshotTimeoutAttemptID == attemptID else { return }
        let timeout = WorkoutBackgroundExecutionBudget.boundedDelay(
            requested: finalSnapshotTimeout,
            backgroundTimeRemaining: backgroundTimeRemaining()
        )
        if timeout == 0 {
            _ = store.timeOutFinalSnapshot()
            cancelFinalSnapshotTimeout()
            return
        }
        finalSnapshotTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await wait(timeout)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  finalSnapshotTimeoutAttemptID == attemptID else {
                return
            }
            _ = store.timeOutFinalSnapshot()
            cancelFinalSnapshotTimeout()
        }
    }

    private func cancelFinalSnapshotTimeout() {
        finalSnapshotTimeoutTask?.cancel()
        finalSnapshotTimeoutTask = nil
        finalSnapshotTimeoutAttemptID = nil
        finalSnapshotBackgroundLease.end()
    }

    @available(iOS 17.0, *)
    private var mirroredTransport: (any WorkoutMirroredSessionTransport)? {
        get { mirroredSessionStorage as? any WorkoutMirroredSessionTransport }
        set { mirroredSessionStorage = newValue }
    }

    @available(iOS 17.0, *)
    private var pendingTerminalFailureOriginTransport:
        (any WorkoutMirroredSessionTransport)? {
        get {
            pendingTerminalFailureOriginTransportStorage
                as? any WorkoutMirroredSessionTransport
        }
        set { pendingTerminalFailureOriginTransportStorage = newValue }
    }

    @available(iOS 17.0, *)
    private func acceptMirroredSession(_ session: HKWorkoutSession) {
        acceptMirroredTransport(
            HealthKitMirroredSessionTransport(session: session)
        )
    }

    @available(iOS 17.0, *)
    func acceptMirroredTransport(
        _ transport: any WorkoutMirroredSessionTransport
    ) {
        launchTimeoutTask?.cancel()
        launchTimeoutTask = nil

        let terminalFailureDrainCode = pendingTerminalFailureCode
        if terminalFailureDrainCode != nil || store.presentation.isWorkoutActive {
            if let inFlight = remoteSendInFlight {
                remoteQueue.insert(inFlight.message, at: 0)
                remoteSendInFlight = nil
            }
        } else {
            // A handler call after an ended/failed/idle presentation belongs to
            // a new Watch session. Never carry old credentials or commands into
            // it. A reconnect of an active session retains them above.
            resetRemoteTransport()
        }
        mirroredTransport?.installDelegate(nil)
        mirroredTransport = transport
        currentTransportAttachmentID = UUID()
        currentTransportSessionID = nil
        currentTransportStartDate = transport.sessionStartDate
        transport.installDelegate(self)
        store.attachMirroredSession(at: now())
        if let terminalFailureDrainCode {
            // A replacement HealthKit transport belongs to the same terminal
            // takeover drain. Keep the original bound and cause rather than
            // treating it as a new launch or clearing the pending failure.
            store.awaitTerminalSnapshotAfterFailure(
                error: terminalFailureDrainCode,
                at: now()
            )
        } else {
            scheduleFirstSnapshotTimeout()
        }

        // HealthKit can provide a fresh HKWorkoutSession instance after a
        // reconnect. Preserve ordered state, replace the object reference, and
        // replay an outcome-unknown segment before requesting one full
        // snapshot. The exact original sender/sequence is the only safe way
        // to distinguish it from a Watch-local segment boundary.
        enqueueUnconfirmedSegmentReplayIfNeeded()
        if store.currentEnvelope?.snapshot?.state.isActive == true {
            enqueueSnapshotRequestIfPossible()
        }
        drainRemoteQueue()
    }

    private func enqueueStateChangingControl(_ control: WorkoutControlV1) {
        guard #available(iOS 17.0, *),
              mirroredTransport != nil,
              store.presentation.isWorkoutActive,
              store.presentation.pendingControl == nil,
              let envelope = makeControlEnvelope(control) else {
            return
        }
        guard store.markPendingControl(
            control,
            sequence: envelope.sequence
        ) else { return }
        // A best-effort snapshot request must never hold a rider control
        // behind a callback that HealthKit may delay indefinitely.
        remoteQueue.removeAll {
            $0.control == .requestCurrentSnapshot
        }
        if remoteSendInFlight?.message.control == .requestCurrentSnapshot {
            remoteSendInFlight = nil
        }
        remoteQueue.append(
            RemoteMessage(
                envelope: envelope,
                control: control,
                reportsFailure: true
            )
        )
        drainRemoteQueue()
    }

    private func enqueueSnapshotRequestIfPossible() {
        guard let envelope = makeControlEnvelope(.requestCurrentSnapshot) else {
            return
        }
        guard remoteSendInFlight?.message.control != .requestCurrentSnapshot,
              !remoteQueue.contains(where: {
                  $0.control == .requestCurrentSnapshot
              }) else {
            return
        }
        remoteQueue.append(
            RemoteMessage(
                envelope: envelope,
                control: .requestCurrentSnapshot,
                reportsFailure: false
            )
        )
    }

    private func enqueueUnconfirmedSegmentReplayIfNeeded() {
        guard let message = segmentStatusReplayMessage,
              message.control == .markSegment,
              store.currentUnconfirmedSegmentControlSequence
                == message.envelope.sequence,
              remoteSendInFlight?.message.envelope.sequence
                != message.envelope.sequence,
              !remoteQueue.contains(where: {
                  $0.control == .markSegment
                      && $0.envelope.sequence == message.envelope.sequence
              }) else {
            return
        }
        remoteQueue.insert(message, at: 0)
    }

    private func synchronizeSegmentStatusReplayWithPresentation() {
        guard let message = segmentStatusReplayMessage else { return }
        let sequence = message.envelope.sequence
        let isStillPending =
            store.presentation.pendingControl == .markSegment
                && store.currentPendingControlSequence == sequence
        let isStillUnconfirmed =
            store.currentUnconfirmedSegmentControlSequence == sequence
        guard !isStillPending, !isStillUnconfirmed else { return }
        remoteQueue.removeAll {
            $0.control == .markSegment
                && $0.envelope.sequence == sequence
        }
        if remoteSendInFlight?.message.control == .markSegment,
           remoteSendInFlight?.message.envelope.sequence == sequence {
            remoteSendInFlight = nil
        }
        segmentReplayAfterSendAttemptID = nil
        segmentStatusReplayMessage = nil
    }

    private func makeControlEnvelope(
        _ control: WorkoutControlV1
    ) -> WorkoutEnvelopeV1? {
        guard let latestEnvelope = store.currentEnvelope else {
            return nil
        }
        guard let envelope = controlSequencer.makeEnvelope(
            control: control,
            currentEnvelope: latestEnvelope,
            capturedAt: now()
        ) else {
            store.failSession(error: .sessionFailed)
            return nil
        }
        return envelope
    }

    private func resetRemoteTransport() {
        cancelFirstSnapshotTimeout()
        remoteQueue.removeAll()
        remoteSendInFlight = nil
        segmentStatusReplayMessage = nil
        segmentReplayAfterSendAttemptID = nil
        controlSequencer.reset()
        cancelControlConfirmationTimeout()
        cancelFinalSnapshotTimeout()
        cancelTerminalFailureDrainTimeout()
        pendingTerminalFailureCode = nil
        pendingTerminalFailureSessionID = nil
        pendingTerminalFailureOriginStartDate = nil
        pendingTerminalFailureOriginTransportStorage = nil
        pendingTerminalFailureOriginAttachmentID = nil
        currentTransportAttachmentID = nil
        currentTransportSessionID = nil
        currentTransportStartDate = nil
    }

    @available(iOS 17.0, *)
    private func scheduleTerminalFailureDrainTimeout() {
        cancelTerminalFailureDrainTimeout()
        let timeout = finalSnapshotTimeout
        let attemptID = UUID()
        let wait = terminalFailureDrainWait
        terminalFailureDrainTimeoutAttemptID = attemptID
        terminalFailureDrainTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await wait(timeout)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  terminalFailureDrainTimeoutAttemptID == attemptID,
                  let errorCode = pendingTerminalFailureCode else {
                return
            }
            mirroredTransport?.installDelegate(nil)
            mirroredTransport = nil
            resetRemoteTransport()
            store.failSession(error: errorCode)
        }
    }

    private func cancelTerminalFailureDrainTimeout() {
        terminalFailureDrainTimeoutTask?.cancel()
        terminalFailureDrainTimeoutTask = nil
        terminalFailureDrainTimeoutAttemptID = nil
    }

    @available(iOS 17.0, *)
    private func completeTerminalFailureDrain(
        from transport: any WorkoutMirroredSessionTransport
    ) {
        guard pendingTerminalFailureCode != nil,
              isCurrentTransport(transport) else {
            return
        }
        transport.installDelegate(nil)
        mirroredTransport = nil
        resetRemoteTransport()
    }

    private func adoptRemoteSessionIdentity(_ sessionID: UUID) {
        remoteQueue.removeAll { $0.envelope.sessionID != sessionID }
        if remoteSendInFlight?.message.envelope.sessionID != sessionID {
            remoteSendInFlight = nil
        }
    }

    private func drainRemoteQueue() {
        guard #available(iOS 17.0, *),
              remoteSendInFlight == nil,
              !remoteQueue.isEmpty,
              let session = mirroredTransport else {
            return
        }
        let message = remoteQueue.removeFirst()
        let data: Data
        do {
            data = try WorkoutContractCodec.encode(message.envelope)
        } catch {
            if message.reportsFailure {
                store.failPendingControl(
                    message.control,
                    sequence: message.envelope.sequence,
                    error: .sessionFailed
                )
            }
            drainRemoteQueue()
            return
        }

        let attempt = RemoteSendAttempt(
            id: UUID(),
            message: message
        )
        remoteSendInFlight = attempt
        if message.control == .markSegment {
            segmentStatusReplayMessage = message
        }
        if message.reportsFailure,
           store.presentation.pendingControl == message.control,
           store.currentPendingControlSequence == message.envelope.sequence {
            // A queued control has not reached HealthKit yet, so its
            // confirmation window must begin only when it is actually
            // submitted to the mirrored session.
            scheduleControlConfirmationTimeout(
                for: message.control,
                sequence: message.envelope.sequence
            )
        }
        let callbackReference = WorkoutWeakReference(self)
        session.send(data: data) { success, error in
            Task { @MainActor in
                guard let manager = callbackReference.value,
                      manager.remoteSendInFlight?.id == attempt.id else {
                    return
                }
                let shouldEnqueueDeferredSegmentReplay =
                    manager.segmentReplayAfterSendAttemptID == attempt.id
                if shouldEnqueueDeferredSegmentReplay {
                    manager.segmentReplayAfterSendAttemptID = nil
                }
                manager.remoteSendInFlight = nil
                if !success, message.reportsFailure {
                    manager.store.failPendingControl(
                        message.control,
                        sequence: message.envelope.sequence,
                        error: Self.safeErrorCode(for: error)
                    )
                }
                manager.synchronizeControlTimeoutWithPresentation()
                if shouldEnqueueDeferredSegmentReplay {
                    manager.enqueueUnconfirmedSegmentReplayIfNeeded()
                }
                manager.drainRemoteQueue()
            }
        }
    }

    @available(iOS 17.0, *)
    private func isCurrentSession(_ session: HKWorkoutSession) -> Bool {
        mirroredTransport?.healthKitSession === session
    }

    @available(iOS 17.0, *)
    private func isCurrentTransport(
        _ transport: any WorkoutMirroredSessionTransport
    ) -> Bool {
        guard let current = mirroredTransport else { return false }
        return ObjectIdentifier(current) == ObjectIdentifier(transport)
    }

    @available(iOS 17.0, *)
    func applyRemoteData(
        _ data: [Data],
        receivedAt: Date,
        from transport: any WorkoutMirroredSessionTransport
    ) {
        let envelopes = data.compactMap { payload in
            try? WorkoutContractCodec.decode(payload)
        }
        guard !envelopes.isEmpty else { return }
        applyRemoteEnvelopes(
            envelopes,
            receivedAt: receivedAt,
            from: transport
        )
    }

    @available(iOS 17.0, *)
    func applyRemoteEnvelopes(
        _ envelopes: [WorkoutEnvelopeV1],
        receivedAt: Date,
        from transport: any WorkoutMirroredSessionTransport
    ) {
        guard isCurrentTransport(transport) else { return }
        let drainSessionID = pendingTerminalFailureSessionID
        let result = store.ingestBatch(envelopes, receivedAt: receivedAt)
        synchronizeSegmentStatusReplayWithPresentation()
        if let sessionID = result.latestSnapshotEnvelope?.sessionID {
            currentTransportSessionID = sessionID
            currentTransportStartDate = result.latestSnapshotEnvelope?
                .snapshot?.startDate
                ?? transport.sessionStartDate
                ?? currentTransportStartDate
            cancelFirstSnapshotTimeout()
            adoptRemoteSessionIdentity(sessionID)
            if pendingTerminalFailureCode != nil {
                if let drainSessionID, drainSessionID != sessionID {
                    clearTerminalFailureForVerifiedNewSession()
                } else if drainSessionID == nil,
                          let snapshot = result.latestSnapshotEnvelope?.snapshot,
                          snapshotIsFromVerifiedNewSession(
                              snapshot,
                              transport: transport
                          ) {
                    clearTerminalFailureForVerifiedNewSession()
                } else if drainSessionID == nil {
                    pendingTerminalFailureSessionID = sessionID
                }
            }
        }
        synchronizeControlTimeoutWithPresentation()
        synchronizeFinalSnapshotTimeoutWithPresentation()
        if result.latestSnapshotEnvelope?.snapshot?.state == .ended
            || result.latestSnapshotEnvelope?.snapshot?.state == .failed {
            completeTerminalFailureDrain(from: transport)
        }
        if store.presentation.shouldAutomaticallyResetAfterDiscard {
            _ = resetTerminalPresentation()
        }
    }

    @available(iOS 17.0, *)
    func applyNativeSessionState(
        _ state: WorkoutSessionStateV1,
        at date: Date,
        from transport: any WorkoutMirroredSessionTransport
    ) {
        guard isCurrentTransport(transport) else { return }
        if state == .running {
            currentTransportStartDate = currentTransportStartDate
                ?? transport.sessionStartDate
                ?? date
        }
        store.confirmSessionState(state, at: date)
        if store.presentation.connectionState != .awaitingFirstSnapshot {
            cancelFirstSnapshotTimeout()
        }
        synchronizeControlTimeoutWithPresentation()
        synchronizeFinalSnapshotTimeoutWithPresentation()
    }

    @available(iOS 17.0, *)
    func applyRemoteDisconnect(
        error: Error?,
        from transport: any WorkoutMirroredSessionTransport
    ) {
        guard isCurrentTransport(transport) else { return }
        cancelFirstSnapshotTimeout()
        transport.installDelegate(nil)
        mirroredTransport = nil
        currentTransportAttachmentID = nil
        currentTransportSessionID = nil
        currentTransportStartDate = nil
        if let inFlight = remoteSendInFlight {
            remoteQueue.insert(inFlight.message, at: 0)
            remoteSendInFlight = nil
        }
        store.disconnect(error: pendingTerminalFailureCode
            ?? error.map { Self.safeErrorCode(for: $0) })
        if pendingTerminalFailureCode == nil {
            cancelTerminalFailureDrainTimeout()
        }
        synchronizeFinalSnapshotTimeoutWithPresentation()
    }

    @available(iOS 17.0, *)
    func applyNativeSessionFailure(
        _ error: Error,
        at date: Date,
        from transport: any WorkoutMirroredSessionTransport
    ) {
        guard isCurrentTransport(transport) else { return }
        let mappedErrorCode = Self.safeErrorCode(for: error)
        let errorCode = WorkoutTerminalErrorPolicy.resolve(
            summaryError: mappedErrorCode,
            persistedFinishError: pendingTerminalFailureCode
        ) ?? mappedErrorCode
        if errorCode == .anotherWorkoutActive {
            let isExistingDrain = pendingTerminalFailureCode != nil
            if !isExistingDrain {
                let drainSessionID = currentTransportSessionID
                let drainOriginStartDate = currentTransportStartDate
                    ?? transport.sessionStartDate
                let drainOriginAttachmentID = currentTransportAttachmentID
                resetRemoteTransport()
                pendingTerminalFailureCode = errorCode
                pendingTerminalFailureSessionID = drainSessionID
                pendingTerminalFailureOriginStartDate = drainOriginStartDate
                pendingTerminalFailureOriginTransport = transport
                pendingTerminalFailureOriginAttachmentID =
                    drainOriginAttachmentID
            }
            store.awaitTerminalSnapshotAfterFailure(
                error: errorCode,
                at: date
            )
            if !isExistingDrain {
                scheduleTerminalFailureDrainTimeout()
            }
            return
        }
        transport.installDelegate(nil)
        mirroredTransport = nil
        resetRemoteTransport()
        store.failSession(error: errorCode)
        synchronizeControlTimeoutWithPresentation()
    }

    @available(iOS 17.0, *)
    private func snapshotIsFromVerifiedNewSession(
        _ snapshot: WorkoutSnapshotV1,
        transport: any WorkoutMirroredSessionTransport
    ) -> Bool {
        guard let candidateStartDate = snapshot.startDate
                ?? transport.sessionStartDate else {
            return false
        }
        if let originTransport = pendingTerminalFailureOriginTransport,
           ObjectIdentifier(originTransport) == ObjectIdentifier(transport) {
            return false
        }
        let originStartDate = pendingTerminalFailureOriginStartDate
            ?? pendingTerminalFailureOriginTransport?.sessionStartDate
        if let originStartDate {
            return abs(
                candidateStartDate.timeIntervalSince(originStartDate)
            ) > Self.sessionStartDateMatchTolerance
        }
        // A takeover before the origin ever acquired a start date means that
        // origin never became a running workout. Only a later attachment with
        // native/custom start evidence can therefore represent a workout.
        return currentTransportAttachmentID
            != pendingTerminalFailureOriginAttachmentID
    }

    private func clearTerminalFailureForVerifiedNewSession() {
        cancelTerminalFailureDrainTimeout()
        pendingTerminalFailureCode = nil
        pendingTerminalFailureSessionID = nil
        pendingTerminalFailureOriginStartDate = nil
        pendingTerminalFailureOriginTransportStorage = nil
        pendingTerminalFailureOriginAttachmentID = nil
        store.clearTerminalFailureForNewSession()
    }

    private static func safeErrorCode(for error: Error?) -> WorkoutSafeErrorCodeV1 {
        guard let healthError = error as? HKError else {
            return .watchUnavailable
        }
        switch healthError.code {
        case .errorAuthorizationDenied,
             .errorAuthorizationNotDetermined,
             .errorRequiredAuthorizationDenied:
            return .setupRequired
        case .errorAnotherWorkoutSessionStarted:
            return .anotherWorkoutActive
        case .errorHealthDataUnavailable,
             .errorNoData:
            return .watchUnavailable
        default:
            return .sessionFailed
        }
    }

    private static func safeLaunchErrorCode(
        for error: Error?
    ) -> WorkoutSafeErrorCodeV1 {
        guard let healthError = error as? HKError else {
            return .watchUnavailable
        }
        switch healthError.code {
        case .errorAuthorizationDenied,
             .errorAuthorizationNotDetermined,
             .errorRequiredAuthorizationDenied:
            return .setupRequired
        case .errorAnotherWorkoutSessionStarted:
            return .anotherWorkoutActive
        default:
            return .watchUnavailable
        }
    }

    private struct RemoteMessage {
        let envelope: WorkoutEnvelopeV1
        let control: WorkoutControlV1
        let reportsFailure: Bool
    }

    private struct RemoteSendAttempt {
        let id: UUID
        let message: RemoteMessage
    }
}

@available(iOS 17.0, *)
extension WorkoutMirrorManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  isCurrentSession(workoutSession),
                  let transport = mirroredTransport else { return }
            applyNativeSessionState(
                Self.contractState(for: toState),
                at: date,
                from: transport
            )
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  isCurrentSession(workoutSession),
                  let transport = mirroredTransport else { return }
            applyNativeSessionFailure(
                error,
                at: now(),
                from: transport
            )
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        // Apple calls this on an anonymous serial queue and may batch data after
        // suspension. Decode and validate there, then publish one coherent
        // latest snapshot on MainActor.
        let envelopes = data.compactMap { payload in
            try? WorkoutContractCodec.decode(payload)
        }
        guard !envelopes.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  isCurrentSession(workoutSession),
                  let transport = mirroredTransport else { return }
            applyRemoteEnvelopes(
                envelopes,
                receivedAt: now(),
                from: transport
            )
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  isCurrentSession(workoutSession),
                  let transport = mirroredTransport else { return }
            applyRemoteDisconnect(
                error: error,
                from: transport
            )
        }
    }

    nonisolated private static func contractState(
        for state: HKWorkoutSessionState
    ) -> WorkoutSessionStateV1 {
        switch state {
        case .notStarted, .prepared:
            return .starting
        case .running:
            return .running
        case .paused:
            return .paused
        case .stopped:
            return .ending
        case .ended:
            return .ended
        @unknown default:
            return .failed
        }
    }
}
