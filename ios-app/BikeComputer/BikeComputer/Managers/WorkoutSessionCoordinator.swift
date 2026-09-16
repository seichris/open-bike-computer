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
    @discardableResult func resetTerminalPresentation() -> Bool
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
    let phoneSupported: Bool

    private let persistence: any WorkoutRecordingPersisting
    private let phone: (any PhoneWorkoutRecording)?
    private var subscriptions = Set<AnyCancellable>()
    private var recoveryTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var pendingAutomaticChoice = false
    private var storageFailed = false
    private var isResetting = false

    init(
        watch: any WorkoutWatchRecording,
        watchAvailability: any WorkoutRecordingWatchAvailability,
        persistence: (any WorkoutRecordingPersisting)? = nil,
        phone: (any PhoneWorkoutRecording)? = nil
    ) {
        self.watch = watch
        self.watchAvailability = watchAvailability
        let persistence = persistence ?? WorkoutRecordingStore()
        self.persistence = persistence
        self.phone = phone
        phoneSupported = phone != nil
        do { record = try persistence.load() }
        catch {
            storageFailed = true
            notice = WorkoutRecordingNotice(kind: .recovery,
                message: "Bicino cannot read the recording owner. Unlock iPhone and retry recovery before starting a workout.")
        }
        store.recordingOwner = record?.owner ?? .watch
        installObservers()
    }

    /// Register callbacks only after every stored property has been initialized.
    private func installObservers() {
        watch.store.$presentation.sink { [weak self] presentation in
            self?.receiveWatch(presentation)
        }.store(in: &subscriptions)
        if let phone {
            phone.store.$presentation.dropFirst().sink { [weak self, weak phone] _ in
                guard let self, let phone, !isResetting, record?.owner == .iphone else { return }
                if let next = phone.record { record = next }
                store.followWorkoutState(from: phone.store, owner: .iphone)
            }.store(in: &subscriptions)
            phone.store.$recordingMessage.sink { [weak self] message in
                guard let self, record?.owner == .iphone else { return }
                store.recordingMessage = message
            }.store(in: &subscriptions)
        }
        watchAvailability.recordingAvailabilityPublisher.removeDuplicates().sink { [weak self] availability in
            guard let self else { return }
            objectWillChange.send()
            guard pendingAutomaticChoice, availability != .activating else { return }
            // @Published emits before storage changes; use this emitted value.
            requestStart(using: availability)
        }.store(in: &subscriptions)
    }

    deinit { recoveryTask?.cancel(); startTask?.cancel() }

    var blocksBikeComputerHandoff: Bool {
        !WorkoutRecordingStartPolicy.mayYieldBikeComputer(record: record)
            || !recoveryComplete || storageFailed
    }

    /// Recovery is attempted on cold launch and for UIKit recovery requests.
    /// Repeated callbacks join the same attempt; they cannot create sessions.
    func recoverIfNeeded() {
        guard recoveryTask == nil, !recoveryComplete else { return }
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { recoveryTask = nil }
            do {
                let persisted = try persistence.load()
                if record == nil { record = persisted }
                storageFailed = false
                if let phone {
                    try await phone.recover(expected: record)
                    if let phoneRecord = phone.record {
                        record = phoneRecord
                        store.followWorkoutState(from: phone.store, owner: .iphone)
                    } else if record?.owner == .iphone {
                        record = try persistence.load()
                    }
                } else if record?.owner == .iphone {
                    throw WorkoutRecordingStore.StoreError.invalidRecord
                }
                recoveryComplete = true
                receiveWatch(watch.store.presentation)
                if notice?.kind == .recovery { notice = nil }
                if pendingAutomaticChoice {
                    pendingAutomaticChoice = false
                    requestStart()
                }
            } catch {
                if let phoneRecord = phone?.record {
                    record = phoneRecord
                    if let phone { store.followWorkoutState(from: phone.store, owner: .iphone) }
                }
                notice = WorkoutRecordingNotice(kind: .recovery,
                    message: phone?.message ?? "Bicino could not reconcile the existing workout. Unlock iPhone and retry; no new recording has been started.")
                recoveryComplete = false
                pendingAutomaticChoice = false
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
        guard !storageFailed, startTask == nil else { return false }
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
                store.followWorkoutState(from: phone.store, owner: .iphone)
                if record == nil { receiveWatch(watch.store.presentation) }
            }
        }
        return true
    }

    private func receiveWatch(_ presentation: WorkoutMirrorPresentationV1) {
        guard !isResetting, !storageFailed else { return }
        // Native phone recovery must finish before adopting an unsolicited Watch ride.
        guard recoveryComplete || record?.owner == .watch else { return }
        let hasActiveEvidence = presentation.isWorkoutActive
            || presentation.connectionState == .awaitingFirstSnapshot
            || presentation.connectionState == .launchingWatch
        if record?.owner == .iphone {
            if hasActiveEvidence {
                notice = WorkoutRecordingNotice(kind: .conflict,
                    message: "A separate Watch workout was detected. This iPhone ride remains selected; Bicino has not stopped, discarded, or merged either recording. Review the Watch workout separately.")
            }
            return
        }
        if record == nil, hasActiveEvidence {
            let adopted = WorkoutRecordingRecord(owner: .watch,
                sessionID: presentation.sessionID ?? UUID(), requestedAt: Date())
            do { try persistence.save(adopted); record = adopted }
            catch { persistenceError(); return }
        }
        if var next = record, next.owner == .watch {
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
        publishWatch()
    }

    private func publishWatch() {
        guard record?.owner != .iphone else { return }
        store.followWorkoutState(from: watch.store, owner: .watch)
    }

    private func persistenceError() {
        storageFailed = true
        notice = WorkoutRecordingNotice(kind: .recovery,
            message: "Recording ownership could not be stored. Existing workouts are left untouched. Unlock iPhone and retry recovery before starting another.")
    }

    /// Only offered after an explicit user check; never called on a timeout.
    func confirmNoWorkoutOnWatch() {
        guard let record, record.owner == .watch, record.phase == .unresolved,
              !watch.store.presentation.isWorkoutActive,
              watch.store.presentation.connectionState != .awaitingFirstSnapshot else { return }
        do {
            try persistence.clear(sessionID: record.sessionID)
            self.record = nil
            _ = watch.resetTerminalPresentation()
            notice = nil
            publishWatch()
        } catch { persistenceError() }
    }

    func retryWatchStart() {
        guard record?.owner == .watch, record?.phase == .unresolved else { return }
        // Retry only the original owner, never fall back to phone.
        _ = watch.startOutdoorCyclingOnWatch()
    }

    func chooseRecorder() {
        guard record == nil else { _ = requestStart(); return }
        notice = WorkoutRecordingNotice(kind: .chooseRecorder,
            message: "Choose the recorder for this ride. Check that Bicino is not already recording on the other device. This choice will not change when devices connect or disconnect.")
    }

    func retryFinish() {
        guard record?.owner == .iphone, let choice = record?.finishChoice else { return }
        phone?.finish(choice)
    }

    func dismissNotice() { notice = nil }
    func refreshFreshness() { watch.refreshFreshness() }
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
        guard current.phase == .finished else { return false }
        do { try persistence.clear(sessionID: current.sessionID) }
        catch { persistenceError(); return false }
        isResetting = true
        if current.owner == .iphone { phone?.resetFinished() }
        else { _ = watch.resetTerminalPresentation() }
        record = nil
        notice = nil
        isResetting = false
        receiveWatch(watch.store.presentation)
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
