import Combine
import Foundation

@MainActor
protocol PhoneWorkoutRecording: AnyObject {
    var store: WorkoutMetricsStore { get }
    var record: WorkoutRecordingRecord? { get }
    var message: String? { get }
    func recover(expected: WorkoutRecordingRecord?) async throws
    func start(_ record: WorkoutRecordingRecord) async
    func pause()
    func resume()
    func markSegment()
    func finish(_ choice: WorkoutRecordingDisposition)
    func resetFinished()
    /// Durably replaces the Watch-part bookkeeping of the current recording.
    /// The iPhone recorder owns the record file while it records.
    func updateContinuation(_ continuation: WorkoutRideContinuation) -> Bool
}

@MainActor
protocol WorkoutWatchRecording: RideAutomationWorkoutControlling {
    var store: WorkoutMetricsStore { get }
    func pause()
    func resume()
    func markSegment()
    func endAndSave()
    func discard()
    func refreshFreshness()
    func savedWorkoutInFitness(sessionID: UUID, requestReadAccess: Bool) async throws -> WorkoutSavedInFitness?
    func reconcileSavedWorkout(_ saved: WorkoutSavedInFitness) -> Bool
    @discardableResult func resetTerminalPresentation() -> Bool
    /// Stops presenting an unreachable or ended Watch session that the rider
    /// continued on iPhone. Never ends, saves or discards the Watch workout.
    @discardableResult func releaseHandedOffSession(_ sessionID: UUID) -> Bool
}

/// When Bicino may offer to continue a Watch-owned ride on iPhone. A
/// disconnect alone never changes the recorder; it only makes the offer.
nonisolated enum WorkoutHandoffPolicy {
    static func mayOfferContinueOnIPhone(
        record: WorkoutRecordingRecord?,
        presentation: WorkoutMirrorPresentationV1,
        ready: Bool,
        phoneSupported: Bool
    ) -> Bool {
        guard ready, phoneSupported, let record, record.owner == .watch,
              record.startedAt != nil, record.finishChoice == nil else { return false }
        switch record.phase {
        case .running, .paused, .unresolved: break
        case .starting, .finishing, .finished: return false
        }
        if presentation.sessionID == record.sessionID {
            // The Watch's last report says the ride is underway, and it has
            // stopped reporting. A requested finish is not a ride to continue.
            guard presentation.pendingControl != .endAndSave,
                  presentation.pendingControl != .discard,
                  presentation.sessionState == .running
                    || presentation.sessionState == .paused else { return false }
            return presentation.connectionState == .disconnected
                || presentation.connectionState == .stale
        }
        // After an iPhone restart nothing may be mirrored yet, or HealthKit
        // reports a session whose snapshot never arrived. Continuing must not
        // wait for Apple Watch to reboot or sync. A different identified
        // session, a launch or a reattachment in progress is not offered.
        guard presentation.sessionID == nil else { return false }
        switch presentation.connectionState {
        case .idle, .disconnected, .stale, .failed: return true
        case .unsupported, .launchingWatch, .awaitingFirstSnapshot, .connected, .ended: return false
        }
    }
}

@MainActor
protocol WorkoutRecordingWatchAvailability: AnyObject {
    var availability: WorkoutWatchAvailabilityV1 { get }
    var recordingAvailabilityPublisher: AnyPublisher<WorkoutWatchAvailabilityV1, Never> { get }
    func activate()
}

nonisolated struct WorkoutRecordingNotice: Equatable {
    enum Kind: Equatable { case chooseRecorder, information, recovery, watchUnresolved, conflict }
    let kind: Kind
    let message: String
}

/// Routes app/device/Lock Screen commands to one recorder for the entire ride.
/// Neither reachability changes nor incoming mirrored data can change a phone
/// ride's owner. The original Watch manager and its recovery logic stay intact.
@MainActor
final class WorkoutSessionCoordinator: ObservableObject {
    let store = WorkoutMetricsStore()
    let watch: any WorkoutWatchRecording
    let watchAvailability: any WorkoutRecordingWatchAvailability
    @Published private(set) var record: WorkoutRecordingRecord?
    @Published private(set) var recoveryComplete = false
    @Published private(set) var notice: WorkoutRecordingNotice?
    @Published private(set) var fitnessCheckMessage: String?
    @Published private(set) var isCheckingFitnessOnRequest = false
    let phoneSupported: Bool

    private let persistence: any WorkoutRecordingPersisting
    private let handoffPersistence: any WorkoutHandoffLedgerPersisting
    private var handoffLedger = WorkoutHandoffLedger()
    /// False while the ledger file could not be read (for example before
    /// first unlock). An unread ledger is never written over.
    private var handoffLedgerLoaded = false
    private let phone: (any PhoneWorkoutRecording)?
    private var subscriptions = Set<AnyCancellable>()
    private var recoveryTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var fitnessCheckTask: Task<Void, Never>?
    private var fitnessCheckSessionID: UUID?
    private var fitnessCheckAttemptID: UUID?
    private var watchPartFitnessTask: Task<Void, Never>?
    private var watchPartFitnessAttemptID: UUID?
    private var pendingAutomaticChoice = false
    private var storageFailed = false
    private var isResetting = false
    private var phoneRecoveryDeferredForWatch = false
    private var pendingWatchRetrySessionID: UUID?
    private var primaryRecoveryRequiredForWatch = false
#if DEBUG
    private var lastRecoveryDebugCheckpoint: NSDictionary?
#endif

    init(
        watch: any WorkoutWatchRecording,
        watchAvailability: any WorkoutRecordingWatchAvailability,
        persistence: (any WorkoutRecordingPersisting)? = nil,
        phone: (any PhoneWorkoutRecording)? = nil,
        handoffLedger: (any WorkoutHandoffLedgerPersisting)? = nil
    ) {
        self.watch = watch
        self.watchAvailability = watchAvailability
        let persistence = persistence ?? WorkoutRecordingStore()
        self.persistence = persistence
        handoffPersistence = handoffLedger ?? WorkoutHandoffLedgerStore()
        self.phone = phone
        phoneSupported = phone != nil
        do { record = try persistence.load() }
        catch {
            storageFailed = true
            notice = WorkoutRecordingNotice(kind: .recovery,
                message: "Bicino cannot read the recording owner. Unlock iPhone and retry recovery before starting a workout.")
        }
        store.recordingOwner = record?.owner ?? .watch
        // Read before observing the Watch, so a continued session is
        // recognized from the first presentation.
        _ = loadHandoffLedgerIfNeeded()
        installObservers()
        if let continuation = record?.continuation {
            rememberHandoff(of: continuation.watch.sessionID, at: continuation.handoffAt)
        }
    }

    /// Reads the ledger once it is readable, keeping any session remembered
    /// in this process meanwhile. Returns whether the ledger may be written.
    @discardableResult
    private func loadHandoffLedgerIfNeeded() -> Bool {
        guard !handoffLedgerLoaded else { return true }
        guard let persisted = try? handoffPersistence.load() else { return false }
        var merged = persisted
        for entry in handoffLedger.entries where !merged.contains(entry.watchSessionID) {
            merged = merged.inserting(entry.watchSessionID, at: entry.handedOffAt)
        }
        handoffLedger = merged
        handoffLedgerLoaded = true
        if merged != persisted { try? handoffPersistence.save(merged) }
        return true
    }

    /// Register callbacks only after every stored property has been initialized.
    private func installObservers() {
        watch.store.$presentation.sink { [weak self] presentation in
            guard let self else { return }
            receiveWatch(presentation)
#if DEBUG
            recordRecoveryDebugCheckpoint(observed: presentation)
#endif
        }.store(in: &subscriptions)
        if let phone {
            phone.store.$presentation.dropFirst().sink { [weak self, weak phone] _ in
                guard let self, let phone, !isResetting, record?.owner == .iphone else { return }
                if let next = phone.record { record = next }
                followPhone()
            }.store(in: &subscriptions)
            phone.store.$recordingMessage.sink { [weak self] message in
                guard let self, record?.owner == .iphone else { return }
                store.recordingMessage = message
            }.store(in: &subscriptions)
        }
        watchAvailability.recordingAvailabilityPublisher.removeDuplicates().sink { [weak self] availability in
            guard let self else { return }
            recordWatchAvailability(availability)
            objectWillChange.send()
            guard pendingAutomaticChoice, availability != .activating else { return }
            // @Published emits before storage changes; use this emitted value.
            requestStart(using: availability)
        }.store(in: &subscriptions)
    }

    deinit {
        recoveryTask?.cancel()
        startTask?.cancel()
        fitnessCheckTask?.cancel()
        watchPartFitnessTask?.cancel()
    }

    /// The coordinator output for an iPhone recording, including the Watch
    /// part of a continued ride.
    private func followPhone() {
        guard let phone else { return }
        store.followWorkoutState(from: phone.store, owner: .iphone,
                                 continuation: record?.continuation)
    }

    // MARK: - Continue on iPhone

    /// Offered only after an active Watch-owned ride stops reporting. The
    /// Watch remains the recorder until the rider explicitly chooses this.
    var canContinueOnIPhone: Bool {
        WorkoutHandoffPolicy.mayOfferContinueOnIPhone(
            record: record, presentation: watch.store.presentation,
            ready: recoveryComplete && !storageFailed && startTask == nil
                && recoveryTask == nil && !isResetting,
            phoneSupported: phoneSupported
        )
    }

    /// The whole continued ride: Watch part, unrecorded gap and iPhone part.
    var rideContinuationSummary: WorkoutRideContinuationSummary? {
        guard let record, record.owner == .iphone, let continuation = record.continuation else { return nil }
        let phoneSnapshot = phone.map { $0.store.presentation.finalSnapshot ?? $0.store.presentation.snapshot }
        return WorkoutRideContinuationMath.summary(
            continuation: continuation,
            phoneStartedAt: record.startedAt,
            phoneSnapshot: phoneSnapshot
        )
    }

    /// Explicit rider choice: start recording on iPhone now, without waiting
    /// for Apple Watch to return. The Watch workout is never stopped, saved or
    /// discarded from here; its part stays in Fitness as its own workout and
    /// Bicino joins both parts into one ride with the gap between them.
    @discardableResult
    func continueOnIPhone() -> Bool {
        guard canContinueOnIPhone, let watchRecord = record, let phone,
              let watchPart = WorkoutRideContinuationMath.watchPart(
                for: watchRecord, presentation: watch.store.presentation
              ) else { return false }
        let handoffAt = Date()
        var next = WorkoutRecordingRecord(owner: .iphone, sessionID: UUID(), requestedAt: handoffAt)
        next.continuation = WorkoutRideContinuation(watch: watchPart, handoffAt: handoffAt)
        // One atomic write moves the ride to iPhone; there is no state in
        // which both or neither recorder owns it.
        do { try persistence.save(next) }
        catch { persistenceError(); return false }
        record = next
        store.recordingOwner = .iphone
        notice = nil
        fitnessCheckTask?.cancel()
        fitnessCheckTask = nil
        fitnessCheckSessionID = nil
        rememberHandoff(of: watchRecord.sessionID, at: handoffAt)
        store.diagnosticsRecorder?.record(category: .workout, event: "continue_on_iphone",
            fields: ["phase": watchRecord.phase.rawValue,
                     "connectionState": watch.store.presentation.connectionState.rawValue])
        startTask = Task { @MainActor [weak self, weak phone] in
            guard let self, let phone else { return }
            defer { startTask = nil }
            await phone.start(next)
            guard record?.sessionID == next.sessionID else { return }
            if let started = phone.record, started.sessionID == next.sessionID,
               started.startedAt != nil {
                record = started
                followPhone()
                synchronizeWatchPartFitnessCheck()
            } else {
                restoreWatchAfterFailedHandoff(watchRecord, phoneMessage: phone.message)
            }
        }
        return true
    }

    /// iPhone never started, so nothing was recorded there and the ride is
    /// still the Watch's. Restore that ownership instead of dropping the ride.
    /// The iPhone reservation stays on disk until this single atomic write
    /// replaces it; if the write fails, recovery restores from it later.
    private func restoreWatchAfterFailedHandoff(_ watchRecord: WorkoutRecordingRecord,
                                                phoneMessage: String?) {
        do { try persistence.save(watchRecord) }
        catch { persistenceError(); return }
        record = watchRecord
        store.recordingOwner = .watch
        forgetHandoff(of: watchRecord.sessionID)
        receiveWatch(watch.store.presentation)
        let reason = phoneMessage.map { " \($0)" } ?? ""
        notice = WorkoutRecordingNotice(kind: .information,
            message: "iPhone could not start recording, so Apple Watch is still the recorder for this ride.\(reason)")
    }

    private func rememberHandoff(of watchSessionID: UUID, at date: Date) {
        let readable = loadHandoffLedgerIfNeeded()
        guard !handoffLedger.contains(watchSessionID) else { return }
        let next = handoffLedger.inserting(watchSessionID, at: date)
        handoffLedger = next
        // Until the file is readable, the entry lives in memory and is merged
        // and saved on the next successful read.
        guard readable else { return }
        do { try handoffPersistence.save(next) }
        catch {
            // The current record still identifies the continued session; the
            // ledger only matters after this ride is dismissed.
            store.diagnosticsRecorder?.record(level: .warning, category: .workout,
                event: "handoff_ledger_write_failed", fields: [:], captureId: nil)
        }
    }

    private func forgetHandoff(of watchSessionID: UUID) {
        let readable = loadHandoffLedgerIfNeeded()
        guard handoffLedger.contains(watchSessionID) else { return }
        handoffLedger = handoffLedger.removing(watchSessionID)
        // A restored Watch record matches its own session, so a stale entry
        // that could not be removed never hides that ride.
        if readable { try? handoffPersistence.save(handoffLedger) }
    }

    private func updateContinuation(_ next: WorkoutRideContinuation) {
        guard let phone, let current = record, current.owner == .iphone,
              let continuation = current.continuation, next != continuation,
              next.watch.sessionID == continuation.watch.sessionID else { return }
        guard phone.updateContinuation(next), let updated = phone.record else {
            // Keep the previous counted values; a later report retries.
            store.diagnosticsRecorder?.record(level: .warning, category: .workout,
                event: "handoff_watch_part_write_failed", fields: [:], captureId: nil)
            return
        }
        record = updated
        followPhone()
    }

    private static let watchStillRecordingMessage =
        "Apple Watch reconnected and is still recording. iPhone stays the recorder for this ride, and Bicino counts the Watch only up to the handoff. End the workout on Apple Watch to keep its part in Fitness."
    private static let handedOffWatchBusyMessage =
        "Apple Watch is still recording the ride you continued on iPhone. End that workout on Apple Watch before starting another ride there."

    /// Late data from the Watch session this ride continues. It can extend
    /// the Watch part up to the handoff but never switches the recorder back.
    private func receiveContinuedWatch(_ presentation: WorkoutMirrorPresentationV1,
                                       continuation: WorkoutRideContinuation) {
        if let evidence = WorkoutRideContinuationMath.evidence(from: presentation) {
            updateContinuation(continuation.absorbing(evidence, phoneStartedAt: record?.startedAt))
        }
        let watchRecording = presentation.isWorkoutActive
            && (presentation.connectionState == .connected
                || presentation.connectionState == .awaitingFirstSnapshot)
        if watchRecording {
            let reconnected = WorkoutRecordingNotice(kind: .information,
                                                     message: Self.watchStillRecordingMessage)
            if notice != reconnected { notice = reconnected }
        } else if notice?.message == Self.watchStillRecordingMessage {
            notice = nil
        }
        if !presentation.isWorkoutActive || presentation.connectionState != .connected {
            synchronizeWatchPartFitnessCheck()
        }
    }

    /// A Watch session that an earlier ride continued on iPhone. It is never
    /// adopted again; Bicino stops presenting it once Apple Watch is not
    /// actively mirroring it.
    private func ignoreHandedOffWatch(_ presentation: WorkoutMirrorPresentationV1, sessionID: UUID) {
        if let provisional = record, provisional.owner == .watch,
           provisional.startedAt == nil, provisional.phase != .finished {
            // Reserved before the mirror revealed which session it carries.
            do { try persistence.clear(sessionID: provisional.sessionID); record = nil }
            catch { persistenceError(); return }
        }
        if record == nil { store.followNoWorkout(owner: .watch) }
        let busy = presentation.isWorkoutActive
            && (presentation.connectionState == .connected
                || presentation.connectionState == .awaitingFirstSnapshot)
        if busy {
            let information = WorkoutRecordingNotice(kind: .information,
                                                     message: Self.handedOffWatchBusyMessage)
            if notice != information { notice = information }
        } else {
            if notice?.message == Self.handedOffWatchBusyMessage { notice = nil }
            // Released outside this publisher callback.
            Task { @MainActor [weak self] in
                guard let self, record?.continuation?.watch.sessionID != sessionID else { return }
                _ = watch.releaseHandedOffSession(sessionID)
            }
        }
    }

    private func watchPartFitnessCandidate() -> UUID? {
        guard recoveryComplete, !storageFailed, let record, record.owner == .iphone,
              let continuation = record.continuation, !continuation.watch.savedInFitness,
              // A discarded Watch workout never reaches Fitness.
              continuation.watch.discardedOnWatch != true
        else { return nil }
        return continuation.watch.sessionID
    }

    /// The Watch can save its part (for example after it restarts) long
    /// after iPhone took over. Its Fitness workout is read, never changed.
    private func synchronizeWatchPartFitnessCheck(requestReadAccess: Bool = false) {
        guard let sessionID = watchPartFitnessCandidate() else {
            if watchPartFitnessAttemptID != nil, fitnessCheckTask == nil {
                isCheckingFitnessOnRequest = false
            }
            watchPartFitnessTask?.cancel()
            watchPartFitnessTask = nil
            watchPartFitnessAttemptID = nil
            return
        }
        guard requestReadAccess || watchPartFitnessTask == nil else { return }
        watchPartFitnessTask?.cancel()
        let attempt = UUID()
        watchPartFitnessAttemptID = attempt
        if requestReadAccess {
            isCheckingFitnessOnRequest = true
            fitnessCheckMessage = "Checking Fitness…"
        }
        let delays: [UInt64] = requestReadAccess ? [0] : [0, 5, 15, 40]
        watchPartFitnessTask = Task { @MainActor [weak self, watch] in
            defer {
                if let self, watchPartFitnessAttemptID == attempt {
                    watchPartFitnessTask = nil
                    if requestReadAccess { isCheckingFitnessOnRequest = false }
                }
            }
            for delay in delays {
                if delay > 0 {
                    do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) }
                    catch { return }
                }
                guard !Task.isCancelled, self?.watchPartFitnessCandidate() == sessionID else { return }
                let saved = try? await watch.savedWorkoutInFitness(
                    sessionID: sessionID, requestReadAccess: requestReadAccess
                )
                guard !Task.isCancelled, let self, watchPartFitnessAttemptID == attempt,
                      watchPartFitnessCandidate() == sessionID,
                      let continuation = record?.continuation else { return }
                if let saved, saved.sessionID == sessionID {
                    updateContinuation(continuation.absorbing(
                        WorkoutRideContinuationMath.evidence(from: saved),
                        phoneStartedAt: record?.startedAt
                    ))
                    if requestReadAccess { fitnessCheckMessage = nil }
                    return
                }
                if requestReadAccess {
                    fitnessCheckMessage = "Apple Watch’s part isn’t in Fitness yet. It appears after Apple Watch saves and syncs it."
                }
            }
        }
    }

    private func fitnessCheckCandidate(_ presentation: WorkoutMirrorPresentationV1) -> UUID? {
        guard recoveryComplete, !storageFailed, let record, record.owner == .watch,
              // A provisional Watch launch reservation has no verified start.
              record.startedAt != nil, record.finishChoice != .discard,
              // A finished ride has nothing to reconcile. Its Watch
              // presentation may already belong to a new, unidentified ride.
              record.phase != .finished,
              presentation.canReconcileFromFitness(sessionID: record.sessionID)
        else { return nil }
        return record.sessionID
    }

    var canCheckFitness: Bool {
        fitnessCheckCandidate(watch.store.presentation) != nil
            || watchPartFitnessCandidate() != nil
    }

    func checkFitness() {
        guard !isCheckingFitnessOnRequest else { return }
        if let sessionID = fitnessCheckCandidate(watch.store.presentation) {
            startFitnessCheck(sessionID: sessionID, requestReadAccess: true)
        } else if watchPartFitnessCandidate() != nil {
            synchronizeWatchPartFitnessCheck(requestReadAccess: true)
        }
    }

    private func synchronizeFitnessCheck(with presentation: WorkoutMirrorPresentationV1) {
        let candidate = fitnessCheckCandidate(presentation)
        guard candidate != fitnessCheckSessionID else { return }
        fitnessCheckTask?.cancel()
        fitnessCheckTask = nil
        fitnessCheckAttemptID = nil
        fitnessCheckSessionID = candidate
        if fitnessCheckMessage != nil { fitnessCheckMessage = nil }
        if isCheckingFitnessOnRequest { isCheckingFitnessOnRequest = false }
        if let candidate {
            startFitnessCheck(sessionID: candidate, requestReadAccess: false)
        }
    }

    private func startFitnessCheck(sessionID: UUID, requestReadAccess: Bool) {
        fitnessCheckTask?.cancel()
        fitnessCheckSessionID = sessionID
        let attempt = UUID()
        fitnessCheckAttemptID = attempt
        if requestReadAccess {
            isCheckingFitnessOnRequest = true
            fitnessCheckMessage = "Checking Fitness…"
        }
        // A Watch save can reach iPhone after mirroring disconnects.
        let delays: [UInt64] = requestReadAccess ? [0] : [0, 5, 15, 40]
        fitnessCheckTask = Task { @MainActor [weak self, watch] in
            defer {
                if let self, fitnessCheckAttemptID == attempt {
                    fitnessCheckTask = nil
                    if requestReadAccess { isCheckingFitnessOnRequest = false }
                }
            }
            for delay in delays {
                if delay > 0 {
                    do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) }
                    catch { return }
                }
                guard !Task.isCancelled,
                      self?.fitnessCheckCandidate(watch.store.presentation) == sessionID else { return }
                let saved = try? await watch.savedWorkoutInFitness(
                    sessionID: sessionID, requestReadAccess: requestReadAccess
                )
                guard !Task.isCancelled, let self,
                      fitnessCheckAttemptID == attempt,
                      fitnessCheckCandidate(watch.store.presentation) == sessionID else { return }
                if let saved, saved.sessionID == sessionID, watch.reconcileSavedWorkout(saved) {
                    return
                }
                if requestReadAccess {
                    fitnessCheckMessage = "Bicino couldn’t verify this ride in Fitness yet."
                }
            }
        }
    }

    var blocksBikeComputerHandoff: Bool {
        !WorkoutRecordingStartPolicy.mayYieldBikeComputer(record: record)
            || !recoveryComplete || storageFailed
    }

    /// The main screen should offer a new start only after ownership recovery
    /// has completed and no unfinished ride is reserved. A finished record is
    /// eligible because `requestStart()` acknowledges it before continuing.
    var canOfferNewWorkout: Bool {
        recoveryComplete && !storageFailed && startTask == nil
            && (record == nil || record?.phase == .finished)
    }

    /// Recovery is attempted on cold launch and for UIKit recovery requests.
    /// Repeated callbacks join the same attempt; they cannot create sessions.
    func recoverIfNeeded(startOnIPhoneAfterRecovery: Bool = false) {
        guard recoveryTask == nil, !recoveryComplete else { return }
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { recoveryTask = nil }
            do {
                let persisted = try persistence.load()
                if record == nil { record = persisted }
                storageFailed = false
                loadHandoffLedgerIfNeeded()
                if let phone {
                    if record?.owner == .watch, record?.phase != .finished,
                       !primaryRecoveryRequiredForWatch {
                        // The launch-time mirroring handler owns Watch recovery.
                        // Do not run primary-session recovery concurrently with
                        // that attachment. A reserved Watch owner already blocks
                        // new recordings. Probe before an explicit Watch retry
                        // or after the owner is finished or checked idle.
                        phoneRecoveryDeferredForWatch = true
                    } else {
                        let reservation = record?.owner == .iphone && record?.startedAt == nil
                            && record?.continuation != nil ? record : nil
                        try await phone.recover(expected: record)
                        primaryRecoveryRequiredForWatch = false
                        if let phoneRecord = phone.record {
                            record = phoneRecord
                            followPhone()
                        } else if record?.owner == .iphone {
                            record = try persistence.load()
                        }
                        if phone.record == nil, let reservation,
                           let handoff = reservation.continuation,
                           record == nil || record?.sessionID == reservation.sessionID {
                            // The app stopped before iPhone began recording,
                            // and recovery found no iPhone session. The ride
                            // is still the Watch's; this atomic write replaces
                            // the reservation, so it is never dropped.
                            let restored = WorkoutRecordingRecord(
                                owner: .watch, sessionID: handoff.watch.sessionID,
                                requestedAt: handoff.watch.requestedAt,
                                startedAt: handoff.watch.startedAt, phase: .unresolved
                            )
                            try persistence.save(restored)
                            record = restored
                            store.recordingOwner = .watch
                            forgetHandoff(of: restored.sessionID)
                        }
                        if let continuation = record?.continuation {
                            rememberHandoff(of: continuation.watch.sessionID, at: continuation.handoffAt)
                        }
                        phoneRecoveryDeferredForWatch = record?.owner == .watch
                            && record?.phase != .finished
                    }
                } else if record?.owner == .iphone {
                    throw WorkoutRecordingStore.StoreError.invalidRecord
                }
                recoveryComplete = true
                receiveWatch(watch.store.presentation)
                if notice?.kind == .recovery { notice = nil }
                synchronizeWatchPartFitnessCheck()
                if let retryID = pendingWatchRetrySessionID {
                    pendingWatchRetrySessionID = nil
                    pendingAutomaticChoice = false
                    if record?.owner == .watch, record?.sessionID == retryID,
                       record?.phase == .unresolved, phone?.record == nil {
                        _ = watch.startOutdoorCyclingOnWatch()
                    }
                }
                if startOnIPhoneAfterRecovery, record == nil {
                    requestStart(explicitOwner: .iphone)
                } else if pendingAutomaticChoice {
                    pendingAutomaticChoice = false
                    requestStart()
                }
            } catch {
                if let phoneRecord = phone?.record {
                    record = phoneRecord
                    followPhone()
                }
                notice = WorkoutRecordingNotice(kind: .recovery,
                    message: phone?.message ?? "Bicino could not reconcile the existing workout. Unlock iPhone and retry; no new recording has been started.")
                recoveryComplete = false
                pendingAutomaticChoice = false
                pendingWatchRetrySessionID = nil
            }
        }
    }

    func retryRecovery() {
        guard recoveryTask == nil, startTask == nil else { return }
        recoveryComplete = false
        recoverIfNeeded()
    }

    /// Manual app or authenticated bike-computer start request.
    @discardableResult
    func requestStart(explicitOwner: WorkoutRecordingOwner? = nil) -> Bool {
        requestStart(using: watchAvailability.availability, explicitOwner: explicitOwner)
    }

    @discardableResult
    private func requestStart(using availability: WorkoutWatchAvailabilityV1,
                              explicitOwner: WorkoutRecordingOwner? = nil) -> Bool {
        recordStartRequest(
            availability: availability,
            explicitOwner: explicitOwner
        )
        guard !storageFailed, startTask == nil else {
            recordStartDecision(
                availability: availability,
                outcome: storageFailed ? "storageBlocked" : "startInFlight",
                owner: explicitOwner
            )
            return false
        }
        // An explicit new start also acknowledges the previous ride's
        // completed summary. Clear only an authoritative terminal tombstone;
        // unresolved, active, and recovering rides must continue to block.
        if recoveryComplete, record?.phase == .finished {
            guard resetTerminalPresentation() else { return false }
        }
        // Native mirroring evidence can precede a custom snapshot/identity.
        if record == nil, watch.store.presentation.isWorkoutActive
            || watch.store.presentation.connectionState == .awaitingFirstSnapshot {
            receiveWatch(watch.store.presentation)
        }
        let decision = WorkoutRecordingStartPolicy.resolve(
            recoveryComplete: recoveryComplete, existingRecording: record,
            watchAvailability: availability, phoneSupported: phoneSupported,
            explicitOwner: explicitOwner
        )
        recordStartDecision(
            availability: availability,
            decision: decision
        )
        switch decision {
        case .waitForRecovery:
            pendingAutomaticChoice = explicitOwner == nil
            notice = WorkoutRecordingNotice(kind: .recovery, message: "Checking for an existing workout before starting another.")
            recoverIfNeeded()
        case .waitForWatchActivation:
            pendingAutomaticChoice = true
            watchAvailability.activate()
        case .chooseRecorder:
            pendingAutomaticChoice = false
            notice = WorkoutRecordingNotice(kind: .chooseRecorder,
                message: "Apple Watch is not ready for an immediate connection. You can try starting on Watch, or explicitly record this ride with iPhone. Check that no ride is already running on Watch.")
        case .phoneUnsupported:
            notice = WorkoutRecordingNotice(kind: .information, message: "Recording without Apple Watch requires iOS 26 or later. Watch workouts and navigation keep their existing requirements.")
        case .blockedByExistingRecording:
            if record?.owner == .watch, record?.phase == .unresolved {
                notice = WorkoutRecordingNotice(kind: .watchUnresolved,
                    message: "The Watch start or finish is unconfirmed. A timeout does not prove the Watch is idle. Check Bicino on Watch before choosing a different recorder.")
            } else {
                notice = WorkoutRecordingNotice(kind: .information,
                    message: "This ride belongs to \(record?.owner.displayName ?? "its selected recorder"). Finish or recover it before starting another.")
            }
        case .start(let owner):
            pendingAutomaticChoice = false
            return start(owner)
        }
        return false
    }

    private func recordWatchAvailability(
        _ availability: WorkoutWatchAvailabilityV1
    ) {
        store.diagnosticsRecorder?.record(
            category: .workout,
            event: "watch_availability_changed",
            fields: Self.diagnosticFields(for: availability)
        )
    }

    private func recordStartRequest(
        availability: WorkoutWatchAvailabilityV1,
        explicitOwner: WorkoutRecordingOwner?
    ) {
        var fields = Self.diagnosticFields(for: availability)
        fields["role"] = explicitOwner?.rawValue ?? "automatic"
        fields["ready"] = String(recoveryComplete && !storageFailed)
        fields["sessionPresent"] = String(record != nil)
        store.diagnosticsRecorder?.record(
            category: .workout,
            event: "start_requested",
            fields: fields
        )
    }

    private func recordStartDecision(
        availability: WorkoutWatchAvailabilityV1,
        decision: WorkoutRecordingStartDecision
    ) {
        switch decision {
        case .waitForRecovery:
            recordStartDecision(
                availability: availability,
                outcome: "waitForRecovery"
            )
        case .waitForWatchActivation:
            recordStartDecision(
                availability: availability,
                outcome: "waitForWatchActivation"
            )
        case .start(let owner):
            recordStartDecision(
                availability: availability,
                outcome: "start",
                owner: owner
            )
        case .chooseRecorder:
            recordStartDecision(
                availability: availability,
                outcome: "chooseRecorder"
            )
        case .blockedByExistingRecording:
            recordStartDecision(
                availability: availability,
                outcome: "blockedByExistingRecording",
                owner: record?.owner
            )
        case .phoneUnsupported:
            recordStartDecision(
                availability: availability,
                outcome: "phoneUnsupported"
            )
        }
    }

    private func recordStartDecision(
        availability: WorkoutWatchAvailabilityV1,
        outcome: String,
        owner: WorkoutRecordingOwner? = nil
    ) {
        var fields = Self.diagnosticFields(for: availability)
        fields["outcome"] = outcome
        fields["role"] = owner?.rawValue ?? "none"
        fields["phase"] = record?.phase.rawValue ?? "none"
        store.diagnosticsRecorder?.record(
            category: .workout,
            event: "start_decision",
            fields: fields
        )
    }

    private static func diagnosticFields(
        for availability: WorkoutWatchAvailabilityV1
    ) -> [String: String] {
        switch availability {
        case .activating:
            return ["state": "activating"]
        case .unsupported:
            return ["state": "unsupported"]
        case .activationFailed:
            return ["state": "activationFailed"]
        case .noPairedWatch:
            return ["state": "noPairedWatch"]
        case .companionAppNotInstalled:
            return ["state": "companionAppNotInstalled"]
        case .ready(let isReachable):
            return [
                "state": "ready",
                "connectionState": isReachable
                    ? "reachable" : "unreachable",
            ]
        }
    }

    private func start(_ owner: WorkoutRecordingOwner) -> Bool {
        guard record == nil, recoveryComplete, !storageFailed else { return false }
        let next = WorkoutRecordingRecord(owner: owner, sessionID: UUID(), requestedAt: Date())
        do { try persistence.save(next) }
        catch { persistenceError(); return false }
        record = next // Reserve synchronously, before any framework call/await.
        store.recordingOwner = owner
        notice = nil
        if owner == .watch {
            guard watch.startOutdoorCyclingOnWatch() else {
                do { try persistence.clear(sessionID: next.sessionID); record = nil }
                catch { persistenceError() }
                return false
            }
            publishWatch()
        } else if let phone {
            startTask = Task { @MainActor [weak self, weak phone] in
                guard let self, let phone else { return }
                defer { startTask = nil }
                await phone.start(next)
                guard record?.sessionID == next.sessionID else { return }
                record = phone.record
                followPhone()
                if record == nil { receiveWatch(watch.store.presentation) }
            }
        }
        return true
    }

    private func receiveWatch(_ presentation: WorkoutMirrorPresentationV1) {
        guard !isResetting, !storageFailed else { return }
        defer { synchronizeFitnessCheck(with: presentation) }
        // Native phone recovery must finish before adopting an unsolicited Watch ride.
        guard recoveryComplete || record?.owner == .watch else { return }
        let hasActiveEvidence = presentation.isWorkoutActive
            || presentation.connectionState == .awaitingFirstSnapshot
            || presentation.connectionState == .launchingWatch
        if !handoffLedgerLoaded, presentation.sessionID != nil { loadHandoffLedgerIfNeeded() }
        if record?.owner == .iphone {
            if let continuation = record?.continuation {
                if presentation.sessionID == continuation.watch.sessionID {
                    receiveContinuedWatch(presentation, continuation: continuation)
                    return
                }
                // A reattaching mirror may be the continued session; wait
                // for its identity before calling it a separate workout.
                if presentation.sessionID == nil { return }
            }
            if let id = presentation.sessionID, handoffLedger.contains(id) { return }
            if hasActiveEvidence {
                notice = WorkoutRecordingNotice(kind: .conflict,
                    message: "A separate Watch workout was detected. This iPhone ride remains selected; Bicino has not stopped, discarded, or merged either recording. Review the Watch workout separately.")
            }
            return
        }
        if let id = presentation.sessionID, handoffLedger.contains(id), record?.sessionID != id {
            // Continued on iPhone earlier: never adopted again, so a late
            // reconnect cannot switch that ride back or count it twice.
            ignoreHandedOffWatch(presentation, sessionID: id)
            return
        }
        if record == nil, hasActiveEvidence {
            let adopted = WorkoutRecordingRecord(owner: .watch,
                sessionID: presentation.sessionID ?? UUID(), requestedAt: Date())
            do { try persistence.save(adopted); record = adopted }
            catch { persistenceError(); return }
        }
        if var next = record, next.owner == .watch {
            // Attaching the next mirrored transport can temporarily retain the
            // previous ride's snapshot/UUID. Keep its terminal tombstone intact
            // until a validated snapshot supplies the new session identity.
            if next.phase == .finished,
               presentation.sessionID == nil || presentation.sessionID == next.sessionID {
                publishWatch()
                return
            }
            if let id = presentation.sessionID, id != next.sessionID {
                // A newly verified Watch session replaces only Watch presentation.
                // Never carry a previous ride's terminal disposition into it.
                next = WorkoutRecordingRecord(owner: .watch, sessionID: id,
                    requestedAt: presentation.snapshot.startDate ?? Date())
            }
            next.startedAt = presentation.snapshot.startDate ?? next.startedAt
            switch presentation.sessionState {
            case .running: next.phase = .running
            case .paused: next.phase = .paused
            case .ending: next.phase = .finishing
            case .starting: next.phase = .starting
            case .ended:
                if let outcome = (presentation.finalSnapshot ?? presentation.snapshot).terminalOutcome {
                    next.finishChoice = outcome == .saved ? .save : .discard
                    next.finishedChoice = next.finishChoice
                    next.phase = .finished
                } else { next.phase = .unresolved }
            case .idle, .failed:
                if presentation.connectionState == .launchingWatch
                    || presentation.connectionState == .awaitingFirstSnapshot {
                    next.phase = .starting
                } else if next.phase != .finished { next.phase = .unresolved }
            }
            if next != record {
                do { try persistence.save(next); record = next }
                catch { persistenceError() }
            } else if hasActiveEvidence, presentation.sessionID == nil {
                do { try persistence.save(next) } catch { persistenceError() }
            }
        }
        if record?.phase == .unresolved, record?.owner == .watch {
            let unresolved = WorkoutRecordingNotice(kind: .watchUnresolved,
                message: "The Watch start or finish is unconfirmed. A timeout does not prove the Watch is idle. Check Bicino on Watch before choosing a different recorder.")
            if notice != unresolved { notice = unresolved }
        } else if notice?.kind == .watchUnresolved,
                  let record, presentation.sessionID == record.sessionID {
            notice = nil
        }
        publishWatch()
    }

    private func publishWatch() {
        guard record?.owner != .iphone else { return }
        if let id = watch.store.presentation.sessionID, handoffLedger.contains(id),
           record?.sessionID != id {
            store.followNoWorkout(owner: .watch)
            return
        }
        store.followWorkoutState(from: watch.store, owner: .watch)
    }

#if DEBUG
    private func recordRecoveryDebugCheckpoint(observed: WorkoutMirrorPresentationV1) {
        let fields: [String: Any] = [
            "schema": 1,
            "recoveryComplete": recoveryComplete,
            "storageFailed": storageFailed,
            "recordOwner": record?.owner.rawValue ?? "none",
            "recordPhase": record?.phase.rawValue ?? "none",
            "observedState": observed.sessionState.rawValue,
            "observedConnection": observed.connectionState.rawValue,
            "outputState": store.presentation.sessionState.rawValue,
            "outputConnection": store.presentation.connectionState.rawValue,
            "outputIsActive": store.presentation.isWorkoutActive,
            "outputOwner": store.recordingOwner.rawValue,
            "phoneRecoveryDeferredForWatch": phoneRecoveryDeferredForWatch,
            "startInFlight": startTask != nil,
        ]
        let checkpoint = fields as NSDictionary
        guard lastRecoveryDebugCheckpoint != checkpoint else { return }
        lastRecoveryDebugCheckpoint = checkpoint
        var persisted = fields
        persisted["capturedAt"] = Date().timeIntervalSince1970
        UserDefaults.standard.set(persisted, forKey: "bicino.debug.workoutSelection.v1")
    }
#endif

    private func persistenceError() {
        storageFailed = true
        notice = WorkoutRecordingNotice(kind: .recovery,
            message: "Recording ownership could not be stored. Existing workouts are left untouched. Unlock iPhone and retry recovery before starting another.")
    }

    /// Resolve only the Watch attempt shown by the confirmation. The Watch
    /// remains responsible for any workout it may have recorded.
    func resolveUnconfirmedWatchWorkout(sessionID: UUID, startOnIPhone: Bool) {
        guard let record, record.sessionID == sessionID,
              record.owner == .watch, record.phase == .unresolved,
              !startOnIPhone || phoneSupported,
              recoveryTask == nil, startTask == nil, !storageFailed,
              !watch.store.presentation.isWorkoutActive,
              watch.store.presentation.connectionState != .awaitingFirstSnapshot else { return }
        do {
            try persistence.clear(sessionID: record.sessionID)
            self.record = nil
            pendingAutomaticChoice = false
            _ = watch.resetTerminalPresentation()
            notice = nil
            publishWatch()
            recoverPhoneAfterWatchOwnershipClears(startOnIPhone: startOnIPhone)
        } catch { persistenceError() }
    }

    private func recoverPhoneAfterWatchOwnershipClears(startOnIPhone: Bool = false) {
        if phoneRecoveryDeferredForWatch {
            recoveryComplete = false
            recoverIfNeeded(startOnIPhoneAfterRecovery: startOnIPhone)
        } else if startOnIPhone {
            requestStart(explicitOwner: .iphone)
        }
    }

    func retryWatchStart() {
        guard record?.owner == .watch, record?.phase == .unresolved,
              recoveryTask == nil, startTask == nil else { return }
        if phoneRecoveryDeferredForWatch {
            // A retry can start a new primary workout on Watch. Resolve the
            // deferred phone probe before admitting that explicit action.
            pendingWatchRetrySessionID = record?.sessionID
            primaryRecoveryRequiredForWatch = true
            retryRecovery()
            return
        }
        // Retry only the original owner, never fall back to phone.
        _ = watch.startOutdoorCyclingOnWatch()
    }

    func retryFinish() {
        guard record?.owner == .iphone, let choice = record?.finishChoice else { return }
        phone?.finish(choice)
    }

    func dismissNotice() { notice = nil }
    func refreshFreshness() {
        watch.refreshFreshness()
        if fitnessCheckTask == nil, let sessionID = fitnessCheckCandidate(watch.store.presentation) {
            startFitnessCheck(sessionID: sessionID, requestReadAccess: false)
        }
        synchronizeWatchPartFitnessCheck()
    }
    func pause() { if record?.owner == .iphone { phone?.pause() } else if record?.owner == .watch { watch.pause() } }
    func resume() { if record?.owner == .iphone { phone?.resume() } else if record?.owner == .watch { watch.resume() } }
    func markSegment() { if record?.owner == .iphone { phone?.markSegment() } else if record?.owner == .watch { watch.markSegment() } }
    func endAndSave() { if record?.owner == .iphone { phone?.finish(.save) } else if record?.owner == .watch { watch.endAndSave() } }
    func discard() { if record?.owner == .iphone { phone?.finish(.discard) } else if record?.owner == .watch { watch.discard() } }

    @discardableResult
    func resetTerminalPresentation() -> Bool {
        guard let current = record else {
            phone?.resetFinished()
            return store.resetTerminalPresentation()
        }
        guard current.phase == .finished,
              current.owner != .watch || watch.store.canResetTerminalPresentation else { return false }
        do { try persistence.clear(sessionID: current.sessionID) }
        catch { persistenceError(); return false }
        isResetting = true
        if current.owner == .iphone { phone?.resetFinished() }
        else { _ = watch.resetTerminalPresentation() }
        if let handedOff = current.continuation?.watch.sessionID {
            // The ledger keeps ignoring this session; stop showing it if
            // Apple Watch is no longer actively mirroring it.
            _ = watch.releaseHandedOffSession(handedOff)
        }
        watchPartFitnessTask?.cancel()
        watchPartFitnessTask = nil
        record = nil
        notice = nil
        isResetting = false
        receiveWatch(watch.store.presentation)
        recoverPhoneAfterWatchOwnershipClears()
        return true
    }
}

extension WorkoutSessionCoordinator: RideAutomationWorkoutControlling {
    var rideAutomationPresentation: WorkoutMirrorPresentationV1 { store.presentation }
    var rideAutomationPresentationPublisher: AnyPublisher<WorkoutMirrorPresentationV1, Never> { store.$presentation.eraseToAnyPublisher() }

    /// The existing automatic detector remains Watch-only. It cannot bypass a
    /// phone-owned ride or silently opt a rider into automatic phone recording.
    func startOutdoorCyclingOnWatch() -> Bool {
        requestStart(explicitOwner: .watch)
    }
    func requestAutomaticTransition(_ transition: RideAutomationTransition, context: WorkoutControlContextV1) -> Bool {
        record?.owner == .watch && watch.requestAutomaticTransition(transition, context: context)
    }
    func requestAutomaticTransitionConfirmation(_ transition: RideAutomationTransition, context: WorkoutControlContextV1) -> Bool {
        record?.owner == .watch && watch.requestAutomaticTransitionConfirmation(transition, context: context)
    }
    func requestAutomaticStartAnnotation(context: WorkoutControlContextV1) -> Bool {
        record?.owner == .watch && watch.requestAutomaticStartAnnotation(context: context)
    }
}
