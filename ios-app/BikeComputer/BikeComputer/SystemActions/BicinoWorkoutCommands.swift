import Foundation

/// A ride control Siri can run.
nonisolated enum BicinoWorkoutCommand: String, CaseIterable, Sendable {
    case start, pause, resume, segment, finish

    /// Finishing waits for the rider's yes, so a misheard phrase can't end
    /// the recording.
    var requiresConfirmation: Bool { self == .finish }
}

/// What a command did, phrased for Siri by `BicinoWorkoutReplyText`.
nonisolated enum BicinoWorkoutCommandOutcome: Equatable, Sendable {
    /// The recorder confirmed the change.
    case done(BicinoWorkoutCommand, WorkoutRecordingOwner)
    /// Sent, but not confirmed by the time Siri has to answer.
    case sent(BicinoWorkoutCommand, WorkoutRecordingOwner)
    /// Finish asks first; nothing has been sent. The rider's yes applies
    /// only to this session.
    case needsConfirmation(WorkoutRecordingOwner, sessionID: UUID)
    /// The confirmed ride is no longer the one recording; nothing was sent.
    case rideChanged
    case noRide
    case alreadyRecording(WorkoutRecordingOwner)
    /// A start or finish Bicino couldn't confirm still owns the ride.
    case unconfirmedRide(WorkoutRecordingOwner)
    case alreadyPaused
    case notPaused
    case segmentNeedsRunningRide
    case segmentsUnsupported
    case finishing(WorkoutRecordingOwner)
    /// The ride is still starting, or the recorder is answering an earlier
    /// command.
    case busy(WorkoutRecordingOwner)
    case unreachable(WorkoutRecordingOwner)
    /// The last ride's save isn't confirmed, so a new one can't start yet.
    case previousRideSaving
    /// Ownership recovery hasn't finished since Bicino launched.
    case checkingForRide
    /// Apple Watch is still activating; the coordinator starts the ride once
    /// it answers.
    case waitingForWatch
    case iPhoneRecordingUnsupported
    case healthAccessNeeded(WorkoutRecordingOwner)
    case failed(BicinoWorkoutCommand, WorkoutRecordingOwner?)
    /// The app hasn't registered the workout handler.
    case unavailable
}

nonisolated enum BicinoWorkoutReplyText {
    static func text(for outcome: BicinoWorkoutCommandOutcome) -> String {
        switch outcome {
        case .done(let command, let owner):
            switch command {
            case .start: return "Your ride started on \(owner.displayName)."
            case .pause: return "Ride paused."
            case .resume: return "Ride resumed."
            case .segment: return "Segment marked."
            case .finish: return "Ride finished and saved."
            }
        case .sent(let command, let owner):
            switch command {
            case .start: return "Starting your ride on \(owner.displayName)."
            case .pause: return "Pausing your ride on \(owner.displayName)."
            case .resume: return "Resuming your ride on \(owner.displayName)."
            case .segment: return "Marking a segment on \(owner.displayName)."
            case .finish: return "Finishing and saving your ride on \(owner.displayName)."
            }
        case .needsConfirmation(let owner, _):
            return "Finish and save your ride on \(owner.displayName)?"
        case .rideChanged:
            return "Your ride changed before you answered, so Bicino didn't finish it."
        case .noRide:
            return "No ride is recording."
        case .alreadyRecording(let owner):
            return "Bicino is already recording a ride on \(owner.displayName)."
        case .unconfirmedRide(.watch):
            return "Bicino can't confirm whether Apple Watch is still recording. Check Bicino on your Watch."
        case .unconfirmedRide(.iphone):
            return "Bicino can't confirm the last ride on iPhone. Open Bicino to check it."
        case .alreadyPaused:
            return "Your ride is already paused."
        case .notPaused:
            return "Your ride isn't paused."
        case .segmentNeedsRunningRide:
            return "Resume your ride to mark a segment."
        case .segmentsUnsupported:
            return "Update Bicino on Apple Watch to mark segments from iPhone."
        case .finishing(let owner):
            return "Your ride is already finishing on \(owner.displayName)."
        case .busy(let owner):
            return "Bicino is still waiting for \(owner.displayName). Try again in a moment."
        case .unreachable(.watch):
            return "Bicino can't reach Apple Watch right now. Use Bicino on your Watch."
        case .unreachable(.iphone):
            return "Bicino can't control this ride right now. Open Bicino to check it."
        case .previousRideSaving:
            return "Bicino is still saving your last ride. Try again in a moment."
        case .checkingForRide:
            // Recovery can also fail until the iPhone is unlocked.
            return "Bicino is still checking for an unfinished ride. If this keeps happening, unlock iPhone and open Bicino."
        case .waitingForWatch:
            return "Bicino is checking your Apple Watch and will start the ride when it answers."
        case .iPhoneRecordingUnsupported:
            return "Recording without Apple Watch needs iOS 26 or later."
        case .healthAccessNeeded(.watch):
            return WorkoutErrorCopyV1.detail(.setupRequired)
        case .healthAccessNeeded(.iphone):
            return "Allow Workouts for Bicino in Health on iPhone, then try again."
        case .failed(let command, let owner):
            let place = owner.map { " on \($0.displayName)" } ?? ""
            switch command {
            case .start: return "Bicino couldn't start a ride\(place). Open Bicino to check it."
            case .pause: return "Bicino couldn't pause your ride\(place). Try again."
            case .resume: return "Bicino couldn't resume your ride\(place). Try again."
            case .segment: return "Bicino couldn't mark a segment\(place). Try again."
            case .finish: return "Bicino couldn't finish your ride\(place). Open Bicino to check it."
            }
        case .unavailable:
            return "Bicino isn't ready yet. Open Bicino and try again."
        }
    }
}

/// Runs Siri's ride commands on the app's one workout coordinator. Start
/// and Finish make the same coordinator calls as the app's buttons; Pause,
/// Resume and Segment go through `control`, which the app routes like the
/// Live Activity buttons. Nothing here chooses or changes the recorder.
@MainActor
final class BicinoWorkoutCommandRunner {
    /// Siri shows a spinner meanwhile; the reply says what the recorder had
    /// confirmed by then.
    nonisolated static let settleTimeout: TimeInterval = 3
    nonisolated static let pollInterval: TimeInterval = 0.1

    private let coordinator: WorkoutSessionCoordinator
    private let control: @MainActor (BicinoWorkoutCommand, UUID) async -> Bool
    private let publish: @MainActor (UUID) async -> Void
    private let wait: @MainActor (TimeInterval) async -> Void

    init(
        coordinator: WorkoutSessionCoordinator,
        control: @escaping @MainActor (BicinoWorkoutCommand, UUID) async -> Bool,
        publish: @escaping @MainActor (UUID) async -> Void = { _ in },
        wait: (@MainActor (TimeInterval) async -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.control = control
        self.publish = publish
        self.wait = wait ?? { interval in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// `confirmedSession` is the session the rider said yes to, for a
    /// command that asks first.
    func run(
        _ command: BicinoWorkoutCommand,
        confirmedSession: UUID? = nil
    ) async -> BicinoWorkoutCommandOutcome {
        // Siri may have just launched Bicino: ownership recovery and the
        // mirrored Watch ride attach shortly after launch.
        await waitUntil { self.coordinator.recoveryComplete && !self.isAttaching }
        guard coordinator.recoveryComplete else { return .checkingForRide }
        switch command {
        case .start:
            return await start()
        case .pause, .resume, .segment, .finish:
            return await send(command, confirmedSession: confirmedSession)
        }
    }

    private func start() async -> BicinoWorkoutCommandOutcome {
        if let ride = existingRide() { return ride }
        let watchActivating = coordinator.watchAvailability.availability == .activating
        let earlierNotice = coordinator.notice
        var started = coordinator.requestStart()
        if !started, watchActivating,
           coordinator.record == nil, coordinator.notice == earlierNotice {
            // The coordinator starts by itself once Apple Watch answers.
            await waitUntil {
                self.coordinator.record != nil || self.coordinator.notice != earlierNotice
            }
            if coordinator.record == nil, coordinator.notice == earlierNotice {
                return .waitingForWatch
            }
            started = coordinator.record != nil
        }
        guard started, let owner = coordinator.record?.owner else { return refusedStart() }

        // A failed start clears the reservation (iPhone) or leaves it
        // unresolved (Apple Watch); a stale store state proves neither.
        await waitUntil {
            self.coordinator.record == nil || self.coordinator.record?.phase == .unresolved
                || self.coordinator.store.presentation.sessionState == .running
        }
        let presentation = coordinator.store.presentation
        if let record = coordinator.record, record.phase != .unresolved {
            return Self.result(of: .start, owner: owner, presentation: presentation)
        }
        switch presentation.errorCode {
        case .authorizationDenied?, .setupRequired?:
            return .healthAccessNeeded(owner)
        default:
            return coordinator.record == nil ? .failed(.start, owner) : .unconfirmedRide(owner)
        }
    }

    /// Why `requestStart()` declined, read from the state it left.
    private func refusedStart() -> BicinoWorkoutCommandOutcome {
        if let ride = existingRide() { return ride }
        if coordinator.record?.phase == .finished { return .previousRideSaving }
        switch coordinator.notice?.kind {
        case .information?:
            // Without a ride to block the start, the only information notice
            // is that iPhone can't record on this iOS version.
            return .iPhoneRecordingUnsupported
        default:
            return .failed(.start, nil)
        }
    }

    /// The ride that keeps a new one from starting.
    private func existingRide() -> BicinoWorkoutCommandOutcome? {
        if let record = coordinator.record, record.phase != .finished {
            return record.phase == .unresolved
                ? .unconfirmedRide(record.owner)
                : .alreadyRecording(record.owner)
        }
        guard coordinator.store.presentation.isWorkoutActive else { return nil }
        return .alreadyRecording(coordinator.store.recordingOwner)
    }

    private func send(
        _ command: BicinoWorkoutCommand,
        confirmedSession: UUID?
    ) async -> BicinoWorkoutCommandOutcome {
        guard let owner = activeOwner else { return .noRide }
        let store = coordinator.store
        if let refusal = Self.refusal(
            for: command,
            presentation: store.presentation,
            owner: owner,
            supportsSegmentMarking: store.supportsSegmentMarking,
            isSegmentConfirmationPending: store.isSegmentConfirmationPending
        ) {
            return refusal
        }
        guard let sessionID = store.presentation.sessionID else { return .unreachable(owner) }
        if command.requiresConfirmation {
            guard let confirmedSession else {
                return .needsConfirmation(owner, sessionID: sessionID)
            }
            // A yes never carries over to a ride that started meanwhile.
            guard confirmedSession == sessionID else { return .rideChanged }
        }

        if command == .finish {
            coordinator.endAndSave()
            await publish(sessionID)
            await waitUntil {
                let presentation = self.coordinator.store.presentation
                return presentation.sessionID != sessionID
                    || (presentation.finalSnapshot ?? presentation.snapshot).terminalOutcome != nil
            }
            await publish(sessionID)
        } else if !(await control(command, sessionID)) {
            return .failed(command, owner)
        }
        return Self.result(of: command, owner: owner, presentation: coordinator.store.presentation)
    }

    private var activeOwner: WorkoutRecordingOwner? {
        if let record = coordinator.record, record.phase != .finished { return record.owner }
        return coordinator.store.presentation.isWorkoutActive
            ? coordinator.store.recordingOwner
            : nil
    }

    /// A ride Bicino owns whose live state hasn't arrived yet.
    private var isAttaching: Bool {
        guard let record = coordinator.record,
              record.phase != .finished, record.phase != .unresolved else { return false }
        return coordinator.store.presentation.sessionID == nil
    }

    private func waitUntil(_ condition: () -> Bool) async {
        var remaining = Self.settleTimeout
        while !condition(), remaining > 0 {
            await wait(Self.pollInterval)
            remaining -= Self.pollInterval
        }
    }

    /// Why a control can't be sent now, or nil when it can. Matches the
    /// Live Activity router's rules, which accept only a connected,
    /// identified session with no control in flight.
    nonisolated static func refusal(
        for command: BicinoWorkoutCommand,
        presentation: WorkoutMirrorPresentationV1,
        owner: WorkoutRecordingOwner,
        supportsSegmentMarking: Bool,
        isSegmentConfirmationPending: Bool
    ) -> BicinoWorkoutCommandOutcome? {
        let state = presentation.sessionState
        if state == .ending || state == .ended
            || presentation.pendingControl == .endAndSave
            || presentation.pendingControl == .discard
            || presentation.errorCode == .terminalChoiceUnconfirmed {
            return .finishing(owner)
        }
        if presentation.connectionState == .launchingWatch
            || presentation.connectionState == .awaitingFirstSnapshot
            || (presentation.isWorkoutActive && state == .starting) {
            return .busy(owner)
        }
        guard presentation.isWorkoutActive, presentation.sessionID != nil,
              presentation.connectionState == .connected else {
            return .unreachable(owner)
        }
        guard presentation.pendingControl == nil else { return .busy(owner) }
        switch command {
        case .start:
            return .alreadyRecording(owner)
        case .pause:
            if state == .paused { return .alreadyPaused }
            return state == .running ? nil : .busy(owner)
        case .resume:
            if state == .running { return .notPaused }
            return state == .paused ? nil : .busy(owner)
        case .segment:
            if state == .paused { return .segmentNeedsRunningRide }
            guard supportsSegmentMarking else { return .segmentsUnsupported }
            return state == .running && !isSegmentConfirmationPending ? nil : .busy(owner)
        case .finish:
            return nil
        }
    }

    /// The reply once a command was sent, from the state the recorder
    /// reported afterwards.
    nonisolated static func result(
        of command: BicinoWorkoutCommand,
        owner: WorkoutRecordingOwner,
        presentation: WorkoutMirrorPresentationV1
    ) -> BicinoWorkoutCommandOutcome {
        let state = presentation.sessionState
        let pending = presentation.pendingControl
        switch command {
        case .start:
            return state == .running ? .done(.start, owner) : .sent(.start, owner)
        case .pause:
            if state == .paused { return .done(.pause, owner) }
            return pending == .pause ? .sent(.pause, owner) : .failed(.pause, owner)
        case .resume:
            if pending == .resume { return .sent(.resume, owner) }
            return state == .running ? .done(.resume, owner) : .failed(.resume, owner)
        case .segment:
            if pending == .markSegment || presentation.errorCode == .segmentMarkUnconfirmed {
                return .sent(.segment, owner)
            }
            return presentation.errorCode == .segmentMarkFailed
                ? .failed(.segment, owner)
                : .done(.segment, owner)
        case .finish:
            if (presentation.finalSnapshot ?? presentation.snapshot).terminalOutcome == .saved {
                return .done(.finish, owner)
            }
            if pending == .endAndSave || state == .ending || state == .ended {
                return .sent(.finish, owner)
            }
            return .failed(.finish, owner)
        }
    }
}
