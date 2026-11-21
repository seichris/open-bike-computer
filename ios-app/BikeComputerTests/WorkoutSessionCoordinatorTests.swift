import Combine
import Foundation

@MainActor
private final class MemoryRecordingStore: WorkoutRecordingPersisting {
    var record: WorkoutRecordingRecord?
    var fails = false
    var saves = 0
    func load() throws -> WorkoutRecordingRecord? {
        if fails { throw WorkoutRecordingStore.StoreError.invalidRecord }
        return record
    }
    func save(_ record: WorkoutRecordingRecord) throws {
        if fails { throw WorkoutRecordingStore.StoreError.invalidRecord }
        precondition(record.isValid, "Invalid recording reservation: \(record)")
        self.record = record
        saves += 1
    }
    var clears = 0
    func clear(sessionID: UUID) throws {
        if fails { throw WorkoutRecordingStore.StoreError.invalidRecord }
        guard record == nil || record?.sessionID == sessionID else {
            throw WorkoutRecordingStore.StoreError.identityMismatch
        }
        record = nil
        clears += 1
    }
}

@MainActor
private final class MemoryHandoffLedger: WorkoutHandoffLedgerPersisting {
    var ledger = WorkoutHandoffLedger()
    var fails = false
    /// The file exists but cannot be read, while writes would still succeed.
    var readFails = false
    func load() throws -> WorkoutHandoffLedger {
        if fails || readFails { throw WorkoutRecordingStore.StoreError.invalidRecord }
        return ledger
    }
    func save(_ ledger: WorkoutHandoffLedger) throws {
        if fails { throw WorkoutRecordingStore.StoreError.invalidRecord }
        self.ledger = ledger
    }
}

@MainActor
private final class FakeAvailability: WorkoutRecordingWatchAvailability {
    @Published var availability: WorkoutWatchAvailabilityV1 = .noPairedWatch
    var recordingAvailabilityPublisher: AnyPublisher<WorkoutWatchAvailabilityV1, Never> {
        $availability.eraseToAnyPublisher()
    }
    func activate() {}
}

@MainActor
private final class WorkoutStartDiagnosticsProbe:
    RideDiagnosticsEventSink {
    struct Event {
        let level: RideDiagnosticLevel
        let category: RideDiagnosticCategory
        let name: String
        let fields: [String: String]
    }

    var events: [Event] = []

    func record(
        level: RideDiagnosticLevel,
        category: RideDiagnosticCategory,
        event: String,
        fields: [String: String],
        captureId: UUID?
    ) {
        events.append(Event(
            level: level,
            category: category,
            name: event,
            fields: fields
        ))
    }
}

@MainActor
private final class FakeWatch: WorkoutWatchRecording {
    let store = WorkoutMetricsStore()
    var starts = 0
    var pauses = 0
    var saves = 0
    var fitnessLookup: ((UUID, Bool) async throws -> WorkoutSavedInFitness?)?
    var startAdmission: (() -> Void)?
    var sequence: UInt64 = 0
    var launchID = UUID()
    let date = Date().addingTimeInterval(-60)
    var startDates: [UUID: Date] = [:]
    var rideAutomationPresentation: WorkoutMirrorPresentationV1 { store.presentation }
    var rideAutomationPresentationPublisher: AnyPublisher<WorkoutMirrorPresentationV1, Never> { store.$presentation.eraseToAnyPublisher() }
    func startOutdoorCyclingOnWatch() -> Bool {
        startAdmission?()
        starts += 1
        launchID = UUID()
        return store.beginWatchLaunch(id: launchID, at: Date(), timeout: 15)
    }
    func pause() { pauses += 1 }
    func resume() {}
    func markSegment() {}
    func endAndSave() { saves += 1 }
    func discard() {}
    func refreshFreshness() {}
    func savedWorkoutInFitness(sessionID: UUID, requestReadAccess: Bool) async throws -> WorkoutSavedInFitness? {
        try await fitnessLookup?(sessionID, requestReadAccess)
    }
    func reconcileSavedWorkout(_ saved: WorkoutSavedInFitness) -> Bool { store.reconcileSavedWorkout(saved) }
    func resetTerminalPresentation() -> Bool { store.resetTerminalPresentation() }
    var releases: [UUID] = []
    func releaseHandedOffSession(_ sessionID: UUID) -> Bool {
        guard store.releaseHandedOffSession(sessionID) else { return false }
        releases.append(sessionID)
        return true
    }
    func requestAutomaticTransition(_ transition: RideAutomationTransition, context: WorkoutControlContextV1) -> Bool { true }
    func requestAutomaticTransitionConfirmation(_ transition: RideAutomationTransition, context: WorkoutControlContextV1) -> Bool { true }
    func requestAutomaticStartAnnotation(context: WorkoutControlContextV1) -> Bool { true }

    func emit(id: UUID, state: WorkoutSessionStateV1, outcome: WorkoutTerminalOutcomeV1? = nil,
              capturedAt: Date = Date(), moving: Double? = nil, distance: Double? = nil) {
        sequence += 1
        if startDates[id] == nil {
            startDates[id] = date.addingTimeInterval(Double(startDates.count))
        }
        if state.isActive { store.attachMirroredSession(at: Date()) }
        let result = store.ingestBatch([WorkoutEnvelopeV1(
            kind: .snapshot, sessionID: id, sessionToken: 19,
            sequence: sequence, capturedAt: capturedAt,
            snapshot: WorkoutSnapshotV1(state: state, startDate: startDates[id],
                elapsedTime: moving.map { WorkoutMetricV1(value: $0, unit: .seconds, capturedAt: capturedAt) },
                cyclingDistance: distance.map {
                    WorkoutMetricV1(value: $0, unit: .meters, capturedAt: capturedAt, source: .healthKit)
                },
                availability: WorkoutAvailabilityMaskV1()
                    .union(moving == nil ? [] : .elapsedTime)
                    .union(distance == nil ? [] : .cyclingDistance),
                terminalOutcome: outcome)
        )], receivedAt: Date())
        precondition(result.rejections.isEmpty && result.acceptedEnvelopes.count == 1,
                     "Fixture must pass real contract and chronological session validation")
    }
}

@MainActor
private final class FakePhone: PhoneWorkoutRecording {
    let store = WorkoutMetricsStore()
    let persistence: MemoryRecordingStore
    var record: WorkoutRecordingRecord?
    var message: String?
    var recoveryFails = false
    var startFails = false
    /// HealthKit's recovery returns Apple Watch's mirrored session.
    var recoversMirror = false
    /// The real recorder's final check after Health authorization.
    var startGate: ((WorkoutRecordingRecord) -> Bool)?
    /// Models the Health authorization await inside the real start.
    var startWindow: (() async -> Void)?
    var recoveries = 0
    var starts = 0
    var continuationWrites = 0
    var pauses = 0
    var saves = 0
    var sequence: UInt64 = 0
    init(_ persistence: MemoryRecordingStore) { self.persistence = persistence }
    func recover(expected: WorkoutRecordingRecord?) async throws {
        recoveries += 1
        if recoveryFails { throw WorkoutRecordingStore.StoreError.invalidRecord }
        guard let expected, expected.owner == .iphone else { return }
        let unstarted = expected.startedAt == nil && expected.finishChoice == nil
        if recoversMirror, !unstarted { throw WorkoutRecordingStore.StoreError.identityMismatch }
        if unstarted {
            // As in the real recorder: a reservation that never started has
            // no iPhone session. A Continue on iPhone reservation is left for
            // the coordinator to replace atomically; others are cleared.
            if expected.continuation == nil { try persistence.clear(sessionID: expected.sessionID) }
            record = nil
            return
        }
        record = expected
        store.beginLocalWorkout()
        emit(expected.phase == .finished ? .ended : .running)
    }
    func start(_ record: WorkoutRecordingRecord) async {
        precondition(persistence.record == record, "Owner must be durable before start")
        self.record = record
        store.beginLocalWorkout()
        if let startWindow { await startWindow() }
        guard !startFails, startGate?(record) ?? true,
              var next = self.record, next.sessionID == record.sessionID else {
            if self.record?.continuation == nil, let id = self.record?.sessionID {
                try? persistence.clear(sessionID: id)
            }
            self.record = nil
            message = "iPhone workout could not start."
            store.failSession(error: .sessionFailed)
            return
        }
        // Built from the current record, as in the real recorder.
        next.startedAt = Date()
        next.phase = .running
        try! persistence.save(next)
        self.record = next
        starts += 1
        emit(.running)
    }
    func pause() { pauses += 1; emit(.paused) }
    func resume() { emit(.running) }
    func markSegment() {}
    func finish(_ choice: WorkoutRecordingDisposition) {
        guard let next = record?.finishing(choice)?.finished(choice) else { return }
        saves += choice == .save ? 1 : 0
        record = next
        try! persistence.save(next)
        emit(.ended)
    }
    func resetFinished() { record = nil; _ = store.resetTerminalPresentation() }
    func updateContinuation(_ continuation: WorkoutRideContinuation) -> Bool {
        guard var next = record,
              next.continuation?.watch.sessionID == continuation.watch.sessionID else { return false }
        next.continuation = continuation
        guard (try? persistence.save(next)) != nil else { return false }
        record = next
        continuationWrites += 1
        return true
    }
    private func emit(_ state: WorkoutSessionStateV1) {
        guard let record else { return }
        sequence += 1
        let now = Date()
        let elapsed = record.startedAt.map {
            WorkoutMetricV1(value: max(0, now.timeIntervalSince($0)), unit: .seconds, capturedAt: now)
        }
        let result = store.ingestBatch([WorkoutEnvelopeV1(
            kind: .snapshot, sessionID: record.sessionID, sessionToken: 23,
            sequence: sequence, capturedAt: now,
            snapshot: WorkoutSnapshotV1(state: state,
                startDate: record.startedAt, elapsedTime: elapsed,
                availability: elapsed == nil ? [] : .elapsedTime,
                terminalOutcome: record.finishedChoice.map { $0 == .save ? .saved : .discarded },
                wallElapsedTime: elapsed)
        )], receivedAt: Date())
        precondition(result.rejections.isEmpty, "Phone fixture rejected: \(result.rejections) state=\(state)")
    }
}

@main
struct WorkoutSessionCoordinatorTests {
    @MainActor
    static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); count += 1
        }
        func harness() -> (WorkoutSessionCoordinator, FakeWatch, FakePhone, FakeAvailability, MemoryRecordingStore) {
            let disk = MemoryRecordingStore()
            let watch = FakeWatch()
            let phone = FakePhone(disk)
            let availability = FakeAvailability()
            return (WorkoutSessionCoordinator(watch: watch, watchAvailability: availability,
                persistence: disk, phone: phone, handoffLedger: MemoryHandoffLedger()),
                    watch, phone, availability, disk)
        }
        let (coordinator, watch, phone, availability, disk) = harness()
        check(!coordinator.canOfferNewWorkout,
              "Start stays hidden until ownership recovery completes")
        check(!coordinator.requestStart(), "Start awaits recovery")
        await spin { phone.starts == 1 }
        check(watch.starts == 0, "No paired Watch uses phone only")
        check(coordinator.record?.owner == .iphone && disk.record?.owner == .iphone, "Phone owner reserved durably")
        check(coordinator.blocksBikeComputerHandoff, "Active phone protects bike link")
        let phoneID = coordinator.record!.sessionID
        availability.availability = .ready(isReachable: true)
        check(watch.starts == 0 && coordinator.record?.sessionID == phoneID, "Reconnection cannot transfer ownership")
        let watchID = UUID()
        watch.emit(id: watchID, state: .running)
        check(coordinator.notice?.kind == .conflict, "Independent Watch ride is surfaced")
        check(coordinator.store.presentation.sessionID == phoneID, "Late Watch data cannot overwrite phone")
        coordinator.pause()
        check(phone.pauses == 1 && watch.pauses == 0, "Pause routed to selected phone")
        check(!coordinator.startOutdoorCyclingOnWatch(), "Automatic Watch start cannot bypass phone")
        check(!coordinator.requestAutomaticTransition(.pause, context: .init(origin: .automatic)), "Watch auto-control gated during phone ride")
        coordinator.endAndSave()
        check(phone.saves == 1 && watch.saves == 0, "Exactly selected recorder saves")
        check(coordinator.record?.phase == .finished, "Authoritative terminal result adopted")
        check(coordinator.resetTerminalPresentation(), "Done clears matching tombstone")
        check(coordinator.record?.owner == .watch && coordinator.record?.sessionID == watchID, "Existing separate Watch workout is adopted only after phone Done")
        check(disk.record?.sessionID == watchID, "Unsolicited Watch adoption persists")
        coordinator.pause()
        check(watch.pauses == 1, "Controls now target adopted Watch")

        let (reconciling, interrupted, reconcilingPhone, _, savedDisk) = harness()
        reconciling.recoverIfNeeded()
        await spin { reconciling.recoveryComplete }
        let savedID = UUID()
        interrupted.emit(id: savedID, state: .running)
        let healthSave = WorkoutSavedInFitness(
            sessionID: savedID, startDate: interrupted.date,
            endDate: interrupted.date.addingTimeInterval(55), duration: 50,
            distanceMeters: 400, activeKilocalories: nil
        )
        var automaticLookups = 0
        var manualLookups = 0
        interrupted.fitnessLookup = { id, requestAccess in
            check(id == savedID, "Fitness query is scoped to the original Watch ride")
            if requestAccess {
                manualLookups += 1
                return healthSave
            }
            automaticLookups += 1
            return nil
        }
        check(!reconciling.canCheckFitness, "A verified live Watch ride is not reconciled")
        _ = interrupted.store.markPendingControl(.endAndSave, sequence: 42)
        interrupted.store.disconnect(error: .watchUnavailable)
        await spin { automaticLookups == 1 }
        check(reconciling.store.presentation.isWorkoutActive && savedDisk.record?.phase == .running,
              "No HealthKit match means the Watch ride remains unresolved")
        reconciling.checkFitness()
        await spin { reconciling.store.presentation.finalSnapshot?.terminalOutcome == .saved }
        check(manualLookups == 1 && interrupted.saves == 0,
              "Manual check requests read access and never sends a Watch save command")
        check(savedDisk.record?.phase == .finished && savedDisk.record?.finishedChoice == .save,
              "The matching Fitness workout durably resolves Watch ownership")
        check(!reconciling.store.presentation.isWorkoutActive
                && reconciling.store.presentation.pendingControl == nil
                && !reconciling.store.shouldMaintainWorkoutServices
                && reconciling.store.presentation.fitnessReconciliation == .verified
                && reconciling.store.presentation.finalSnapshot?.elapsedTime?.value == 50,
              "The verified Fitness summary removes queued controls and ride services")
        let late = WorkoutEnvelopeV1(kind: .snapshot, sessionID: savedID, sessionToken: 19,
            sequence: 100, capturedAt: Date(),
            snapshot: WorkoutSnapshotV1(state: .running, startDate: interrupted.date))
        // A stale mirror of the saved ride reports only that it has ended.
        interrupted.store.attachMirroredSession(at: Date())
        interrupted.store.confirmSessionState(.ended, at: Date())
        check(!reconciling.resetTerminalPresentation(),
              "Done cannot clear ownership while a replacement mirror is being identified")
        check(interrupted.store.ingestBatch([late], receivedAt: Date()).acceptedEnvelopes.isEmpty,
              "Late snapshots cannot resurrect the workout saved in Fitness")
        check(interrupted.store.timeOutFirstSnapshot()
                && reconciling.store.presentation.finalSnapshot?.terminalOutcome == .saved,
              "An attachment timeout restores dismissal of the saved summary")
        // HealthKit reports a live session, so this is a new ride whose
        // snapshot is late. It must not be dropped as an unverified mirror.
        interrupted.store.attachMirroredSession(at: Date())
        interrupted.store.confirmSessionState(.running, at: Date())
        check(reconciling.store.presentation.connectionState == .awaitingFirstSnapshot
                && reconciling.store.presentation.isWorkoutActive
                && reconciling.store.presentation.fitnessReconciliation == nil,
              "HealthKit's live state shows the new Watch ride instead of the saved summary")
        check(interrupted.store.timeOutFirstSnapshot()
                && reconciling.store.presentation.connectionState == .disconnected
                && reconciling.store.presentation.isWorkoutActive,
              "A silent live replacement stays a disconnected active ride")
        check(!reconciling.resetTerminalPresentation()
                && !reconciling.requestStart(explicitOwner: .iphone)
                && reconcilingPhone.starts == 0
                && savedDisk.record?.sessionID == savedID,
              "The live replacement blocks Done and a second recorder")
        check(!reconciling.canCheckFitness,
              "A finished ride is not checked again over the live replacement")
        interrupted.emit(id: UUID(), state: .running)
        check(reconciling.record?.owner == .watch && reconciling.record?.sessionID != savedID
                && reconciling.store.presentation.isWorkoutActive,
              "A verified new Watch ride supersedes the saved Fitness summary")

        let (racing, racingWatch, _, _, racingDisk) = harness()
        racing.recoverIfNeeded()
        await spin { racing.recoveryComplete }
        racingWatch.emit(id: savedID, state: .running)
        var pendingLookup: CheckedContinuation<WorkoutSavedInFitness?, Never>?
        racingWatch.fitnessLookup = { _, _ in
            await withCheckedContinuation { pendingLookup = $0 }
        }
        racingWatch.store.disconnect(error: .watchUnavailable)
        await spin { pendingLookup != nil }
        let newID = UUID()
        racingWatch.emit(id: newID, state: .running)
        pendingLookup?.resume(returning: healthSave)
        for _ in 0..<8 { await Task.yield() }
        check(racingDisk.record?.sessionID == newID && racing.store.presentation.isWorkoutActive,
              "A late HealthKit lookup cannot finish a replacement Watch ride")

        let (relaunch, relaunchWatch, _, _, relaunchDisk) = harness()
        let preexisting = WorkoutRecordingRecord(owner: .watch, sessionID: savedID,
            requestedAt: healthSave.startDate, startedAt: healthSave.startDate, phase: .running)
        try relaunchDisk.save(preexisting)
        relaunchWatch.fitnessLookup = { id, _ in id == savedID ? healthSave : nil }
        relaunch.recoverIfNeeded()
        await spin { relaunch.store.presentation.finalSnapshot?.terminalOutcome == .saved }
        check(relaunch.record?.phase == .finished && relaunch.notice == nil,
              "Cold launch resolves a saved Watch ride from its persisted identity")
        check(relaunch.resetTerminalPresentation() && relaunchDisk.record == nil
                && relaunch.store.presentation.connectionState == .idle,
              "Done clears the completed ride without new recording or save actions")

        // Exercise the actual failed/expired launch reducers, rather than
        // replacing the presentation with the generic failSession helper.
        for timedOut in [false, true] {
            let (checked, checkedWatch, _, checkedAvailability, checkedDisk) = harness()
            checkedAvailability.availability = .ready(isReachable: true)
            checked.recoverIfNeeded()
            await spin { checked.recoveryComplete }
            check(checked.requestStart(), "Reserve Watch before failed launch")
            if timedOut {
                _ = checkedWatch.store.timeOutWatchLaunch(id: checkedWatch.launchID,
                    at: Date().addingTimeInterval(20))
            } else {
                _ = checkedWatch.store.completeWatchLaunch(id: checkedWatch.launchID,
                    succeeded: false, error: .watchUnavailable)
            }
            check(checked.record?.phase == .unresolved, "Failed native launch remains unresolved")
            checked.confirmNoWorkoutOnWatch()
            check(checked.record == nil && checkedDisk.record == nil,
                  "Checked-idle acknowledgement clears actual failed launch without restarting")
            check(checked.canOfferNewWorkout, "Checked idle restores new-ride admission")
        }

        let (watchCoordinator, watch2, phone2, availability2, disk2) = harness()
        availability2.availability = .ready(isReachable: true)
        watchCoordinator.recoverIfNeeded()
        await spin { watchCoordinator.recoveryComplete }
        watch2.startAdmission = { precondition(disk2.record?.owner == .watch) }
        check(watchCoordinator.requestStart(), "Ready Watch launch accepted")
        check(watchCoordinator.record?.phase == .starting, "Launching is not an unresolved timeout")
        watch2.store.failSession(error: .watchUnavailable)
        check(watchCoordinator.record?.phase == .unresolved, "Watch timeout retains reservation")
        availability2.availability = .noPairedWatch
        check(!watchCoordinator.requestStart(explicitOwner: .iphone) && phone2.starts == 0, "Timeout/unpair cannot silently fall back")
        watchCoordinator.confirmNoWorkoutOnWatch()
        check(watchCoordinator.record == nil, "Explicit checked-idle confirmation can clear unresolved Watch launch")
        let id2 = UUID()
        watch2.emit(id: id2, state: .running)
        watch2.store.disconnect(error: .watchUnavailable)
        check(watchCoordinator.record?.owner == .watch, "Watch disconnection retains ownership")
        check(!watchCoordinator.requestStart(explicitOwner: .iphone), "Disconnected active Watch blocks phone")
        watch2.emit(id: id2, state: .ended, outcome: .saved)
        let id3 = UUID()
        watch2.store.attachMirroredSession(at: Date())
        check(watchCoordinator.record?.phase == .finished && disk2.record?.isValid == true,
              "Next transport must not corrupt the previous ride's terminal reservation")
        watch2.emit(id: id3, state: .running)
        check(watchCoordinator.record?.sessionID == id3 && watchCoordinator.record?.finishedChoice == nil,
              "Next Watch ride cannot inherit previous terminal disposition")

        let (chooser, chooserWatch, chooserPhone, chooserAvailability, chooserDisk) = harness()
        chooserAvailability.availability = .ready(isReachable: true)
        chooser.recoverIfNeeded()
        await spin { chooser.recoveryComplete }
        let completedWatchID = UUID()
        chooserWatch.emit(id: completedWatchID, state: .running)
        chooserWatch.emit(id: completedWatchID, state: .ended, outcome: .saved)
        chooser.chooseRecorder()
        check(chooser.record == nil && chooserDisk.record == nil
                  && chooser.notice?.kind == .chooseRecorder,
              "Choosing after a completed ride acknowledges its tombstone and opens the chooser")
        check(chooserWatch.starts == 0 && chooserPhone.starts == 0,
              "Opening the recorder chooser must not start the default Watch")
        check(chooser.requestStart(explicitOwner: .iphone),
              "A paired Watch does not prevent an explicit phone choice")
        await spin { chooserPhone.starts == 1 }
        let explicitlySelectedPhoneID = chooser.record!.sessionID
        chooser.chooseRecorder()
        check(chooser.record?.sessionID == explicitlySelectedPhoneID
                  && chooser.record?.owner == .iphone
                  && chooserPhone.starts == 1 && chooserWatch.starts == 0,
              "Choosing during a running ride cannot switch or start another recorder")

        let (unreachable, watch3, phone3, availability3, _) = harness()
        availability3.availability = .ready(isReachable: false)
        unreachable.recoverIfNeeded()
        await spin { unreachable.recoveryComplete }
        check(unreachable.requestStart(),
              "Paired installed Watch starts through HealthKit when WCSession is unreachable")
        check(watch3.starts == 1 && phone3.starts == 0,
              "Transient Watch reachability never redirects recording to iPhone")
        check(unreachable.record?.owner == .watch && unreachable.notice == nil,
              "HealthKit Watch launch reserves Watch ownership without an attention sheet")

        let (transient, watch4, phone4, availability4, _) = harness()
        let diagnostics = WorkoutStartDiagnosticsProbe()
        transient.store.diagnosticsRecorder = diagnostics
        availability4.availability = .activationFailed
        transient.recoverIfNeeded()
        await spin { transient.recoveryComplete }
        check(transient.requestStart(),
              "Transient Watch activation failure attempts authoritative HealthKit launch")
        check(watch4.starts == 1 && phone4.starts == 0,
              "Transient Watch state never opens recorder selection or redirects to iPhone")
        check(transient.notice == nil,
              "Accepted HealthKit Watch launch does not present a recorder sheet")
        check(diagnostics.events.contains {
            $0.name == "watch_availability_changed"
                && $0.fields["state"] == "activationFailed"
        }, "Availability transition is retained in privacy-safe diagnostics")
        check(diagnostics.events.contains {
            $0.name == "start_requested"
                && $0.fields["state"] == "activationFailed"
        }, "Start request records the observed Watch availability")
        check(diagnostics.events.contains {
            $0.name == "start_decision"
                && $0.fields["outcome"] == "start"
                && $0.fields["role"] == "watch"
        }, "Start decision records the selected recorder")

        let (catalogue, watch5, phone5, availability5, _) = harness()
        availability5.availability = .companionAppNotInstalled
        catalogue.recoverIfNeeded()
        await spin { catalogue.recoveryComplete }
        check(catalogue.requestStart(),
              "Stale companion catalogue attempts authoritative HealthKit launch")
        check(watch5.starts == 1 && phone5.starts == 0
                && catalogue.notice == nil,
              "Companion registration lag does not open recorder selection")

        let finishedDisk = MemoryRecordingStore()
        var finishedWatchRecord = WorkoutRecordingRecord(
            owner: .watch,
            sessionID: UUID(),
            requestedAt: Date().addingTimeInterval(-120)
        )
        finishedWatchRecord.startedAt = Date().addingTimeInterval(-119)
        finishedWatchRecord.finishChoice = .save
        finishedWatchRecord.finishedChoice = .save
        finishedWatchRecord.phase = .finished
        try finishedDisk.save(finishedWatchRecord)
        let restartWatch = FakeWatch()
        let restartPhone = FakePhone(finishedDisk)
        let restartAvailability = FakeAvailability()
        restartAvailability.availability = .ready(isReachable: true)
        let restart = WorkoutSessionCoordinator(
            watch: restartWatch,
            watchAvailability: restartAvailability,
            persistence: finishedDisk,
            phone: restartPhone,
            handoffLedger: MemoryHandoffLedger()
        )
        restart.recoverIfNeeded()
        await spin { restart.recoveryComplete }
        check(restart.record == finishedWatchRecord,
              "Recovery keeps a finished tombstone until the rider continues")
        check(restart.canOfferNewWorkout,
              "A finished tombstone still offers the next workout")
        check(restart.requestStart(),
              "One start tap clears a finished tombstone and starts the next ride")
        check(restartWatch.starts == 1 && restartPhone.starts == 0,
              "The normal recorder policy selects the reachable Watch after cleanup")
        check(restart.record?.phase == .starting
                && restart.record?.sessionID != finishedWatchRecord.sessionID,
              "The new ride gets fresh ownership instead of reusing the old summary")
        check(!restart.canOfferNewWorkout,
              "A reserved new ride immediately removes the start action")
        check(restart.notice == nil,
              "A successful restart does not request the workout attention sheet")

        let watchRecoveryDisk = MemoryRecordingStore()
        let recoveredWatchID = UUID()
        watchRecoveryDisk.record = WorkoutRecordingRecord(owner: .watch,
            sessionID: recoveredWatchID, requestedAt: Date().addingTimeInterval(-60))
        let recoveredWatch = FakeWatch()
        let deferredPhone = FakePhone(watchRecoveryDisk)
        deferredPhone.recoveryFails = true
        let watchRecovery = WorkoutSessionCoordinator(watch: recoveredWatch,
            watchAvailability: FakeAvailability(), persistence: watchRecoveryDisk,
            phone: deferredPhone, handoffLedger: MemoryHandoffLedger())
        check(watchRecovery.record?.phase == .unresolved
                && watchRecovery.notice?.kind == .watchUnresolved,
              "A cold-launch unresolved Watch owner exposes its recovery actions")
        check(!watchRecovery.canOfferNewWorkout,
              "Exposing checked-idle recovery does not admit a replacement ride")
        recoveredWatch.emit(id: recoveredWatchID, state: .paused)
        watchRecovery.recoverIfNeeded()
        await spin { watchRecovery.recoveryComplete }
        check(deferredPhone.recoveries == 0,
              "A reserved Watch workout reattaches without a concurrent primary recovery probe")
        check(watchRecovery.record?.sessionID == recoveredWatchID
                && watchRecovery.record?.phase == .paused && watchRecovery.notice == nil,
              "The credentialed paused Watch snapshot recovers its reserved identity")
        watchRecovery.pause()
        check(recoveredWatch.pauses == 1 && deferredPhone.pauses == 0,
              "Recovered controls remain bound to Watch")
        check(!watchRecovery.requestStart(explicitOwner: .iphone)
                && deferredPhone.starts == 0 && recoveredWatch.starts == 0,
              "Deferred phone recovery cannot admit a second recording")
        recoveredWatch.emit(id: recoveredWatchID, state: .ended, outcome: .discarded)
        check(watchRecovery.resetTerminalPresentation(),
              "Only a confirmed Watch terminal disposition clears its owner")
        await spin { watchRecovery.notice?.kind == .recovery }
        check(deferredPhone.recoveries == 1 && !watchRecovery.recoveryComplete,
              "Clearing Watch ownership requires a fresh primary phone probe")
        check(!watchRecovery.requestStart(explicitOwner: .iphone)
                && deferredPhone.starts == 0 && recoveredWatch.starts == 0,
              "An unsuccessful deferred probe still blocks all new starts")
        deferredPhone.recoveryFails = false
        watchRecovery.retryRecovery()
        await spin { watchRecovery.recoveryComplete }
        check(deferredPhone.recoveries == 2 && watchRecovery.record == nil,
              "A successful deferred probe releases only the finished owner")

        let retryDisk = MemoryRecordingStore()
        retryDisk.record = WorkoutRecordingRecord(owner: .watch,
            sessionID: UUID(), requestedAt: Date().addingTimeInterval(-60))
        let retryWatch = FakeWatch()
        let retryPhone = FakePhone(retryDisk)
        retryPhone.recoveryFails = true
        let guardedRetry = WorkoutSessionCoordinator(watch: retryWatch,
            watchAvailability: FakeAvailability(), persistence: retryDisk,
            phone: retryPhone, handoffLedger: MemoryHandoffLedger())
        guardedRetry.recoverIfNeeded()
        await spin { guardedRetry.recoveryComplete }
        check(retryPhone.recoveries == 0 && retryWatch.starts == 0,
              "Cold Watch recovery leaves the primary probe deferred without starting a workout")
        guardedRetry.retryWatchStart()
        await spin { guardedRetry.notice?.kind == .recovery }
        check(retryPhone.recoveries == 1 && retryWatch.starts == 0,
              "An explicit Watch retry cannot start while primary recovery is unresolved")
        check(!guardedRetry.requestStart(explicitOwner: .iphone)
                && retryPhone.starts == 0,
              "A failed retry probe cannot switch to a new phone recording")
        await spin { retryPhone.recoveries == 2
            && guardedRetry.notice?.kind == .recovery }
        check(!guardedRetry.recoveryComplete && retryWatch.starts == 0,
              "Automatic recovery after a failed retry must preserve the required primary probe")
        retryPhone.recoveryFails = false
        guardedRetry.retryWatchStart()
        await spin { retryWatch.starts == 1 }
        check(retryPhone.recoveries == 3 && retryWatch.starts == 1
                && retryPhone.starts == 0,
              "Only a successful explicit retry probe admits the reserved Watch recorder")

        let (recovery, watch6, phone6, _, disk6) = harness()
        phone6.recoveryFails = true
        recovery.recoverIfNeeded()
        await spin { recovery.notice?.kind == .recovery }
        check(!recovery.recoveryComplete && !recovery.requestStart(explicitOwner: .watch), "Recovery failure blocks even Watch starts")
        check(watch6.starts == 0 && phone6.starts == 0, "Recovery never creates substitute workout")
        phone6.recoveryFails = false
        recovery.retryRecovery()
        await spin { recovery.recoveryComplete }
        disk6.fails = true
        check(!recovery.requestStart(explicitOwner: .iphone), "Storage failure prevents native start")
        check(phone6.starts == 0, "No recording without durable owner")
        for segmentError in [nil, WorkoutSafeErrorCodeV1.segmentMarkFailed] {
            let local = WorkoutMetricsStore()
            local.beginLocalWorkout()
            let id = UUID(), start = Date().addingTimeInterval(-60)
            let running = WorkoutEnvelopeV1(kind: .snapshot, sessionID: id,
                sessionToken: 23, sequence: 1, capturedAt: Date(),
                snapshot: WorkoutSnapshotV1(state: .running, startDate: start, availability: []))
            _ = local.ingestBatch([running], receivedAt: Date())
            check(local.markPendingControl(.markSegment, sequence: 1), "Native segment starts")
            local.releasePendingSegmentForLifecycleControl()
            check(local.currentUnconfirmedSegmentControlSequence == 1,
                  "Releasing a native segment preserves its original acknowledgement identity")
            check(!local.markPendingControl(.markSegment, sequence: 2),
                  "An unknown native segment outcome cannot admit a duplicate mark")
            check(local.markPendingControl(.pause, sequence: 2),
                  "An unconfirmed native segment cannot block Pause")
            let ack = WorkoutEnvelopeV1(kind: .acknowledgement, sessionID: id,
                sessionToken: 23, sequence: 2, capturedAt: Date(),
                acknowledgement: WorkoutAcknowledgementV1(control: .markSegment,
                    resultingState: .running, acknowledgedSequence: 1, errorCode: segmentError))
            let accepted = local.ingestBatch([ack], receivedAt: Date())
            check(accepted.rejections.isEmpty && !local.isSegmentConfirmationPending,
                  "Late success or failure resolves only the original native segment")
            check(local.presentation.pendingControl == .pause,
                  "A late segment acknowledgement cannot clear the newer Pause")
            local.confirmSessionState(.paused, at: Date())
            check(local.presentation.pendingControl == nil
                      && local.presentation.sessionState == .paused,
                  "Native paused state confirms its own lifecycle control")
            check(local.markPendingControl(.markSegment, sequence: 3),
                  "Only a confirmed segment outcome admits the next mark")
        }
        try await continueOnIPhoneScenarios(check: check)
        try await siriWorkoutCommandScenarios(check: check)
        print("Workout session coordinator: \(count) assertions passed")
    }

    /// Continue on iPhone: transient disconnect, explicit handoff, late Watch
    /// recovery, Done, restart, and a failed iPhone start.
    @MainActor
    private static func continueOnIPhoneScenarios(check: (Bool, String) -> Void) async throws {
        func harness(_ existingDisk: MemoryRecordingStore? = nil,
                     ledger existingLedger: MemoryHandoffLedger? = nil)
            -> (WorkoutSessionCoordinator, FakeWatch, FakePhone, MemoryRecordingStore, MemoryHandoffLedger) {
            let disk = existingDisk ?? MemoryRecordingStore()
            let ledger = existingLedger ?? MemoryHandoffLedger()
            let watch = FakeWatch()
            let phone = FakePhone(disk)
            let availability = FakeAvailability()
            availability.availability = .ready(isReachable: true)
            // The same final gate BikeComputerApp gives the real recorder.
            phone.startGate = { [weak watch] record in
                guard let presentation = watch?.store.presentation else { return false }
                return WorkoutRecordingStartPolicy.phoneMayStart(
                    record, watchSessionID: presentation.sessionID,
                    watchWorkoutBusy: presentation.isWorkoutActive
                        || presentation.connectionState == .awaitingFirstSnapshot
                        || presentation.connectionState == .launchingWatch)
            }
            return (WorkoutSessionCoordinator(watch: watch, watchAvailability: availability,
                persistence: disk, phone: phone, handoffLedger: ledger), watch, phone, disk, ledger)
        }

        // Transient disconnect: Apple Watch stays the recorder.
        let (ride, watch, phone, disk, ledger) = harness()
        ride.recoverIfNeeded()
        await spin { ride.recoveryComplete }
        // The rider started on Apple Watch; its mirrored ride is adopted.
        let watchID = UUID()
        watch.emit(id: watchID, state: .running, capturedAt: Date().addingTimeInterval(-8),
                   moving: 30, distance: 250)
        check(ride.record?.owner == .watch && ride.record?.sessionID == watchID
                && ride.record?.phase == .running && !ride.canContinueOnIPhone,
              "A connected Watch ride offers no handoff")
        watch.store.disconnect(error: .watchUnavailable)
        check(ride.record?.owner == .watch && disk.record?.sessionID == watchID
                && ride.record?.phase == .running,
              "A disconnect alone keeps Apple Watch as the recorder")
        check(ride.canContinueOnIPhone && phone.starts == 0,
              "A disconnect offers Continue on iPhone but starts nothing")
        check(!ride.requestStart(explicitOwner: .iphone) && phone.starts == 0,
              "An ordinary iPhone start is still blocked by the unreachable Watch ride")
        check(ride.store.recordingOwner == .watch && ride.store.presentation.sessionID == watchID,
              "The dashboard keeps showing the Watch ride while it is unreachable")
        let reconnectAt = Date().addingTimeInterval(-6)
        watch.emit(id: watchID, state: .running, capturedAt: reconnectAt, moving: 35, distance: 300)
        check(!ride.canContinueOnIPhone && ride.record?.owner == .watch && phone.starts == 0
                && ledger.ledger.entries.isEmpty,
              "Reconnecting withdraws the offer; nothing switched")
        watch.store.refreshFreshness(at: Date().addingTimeInterval(30))
        check(ride.canContinueOnIPhone && ride.record?.owner == .watch,
              "Stale Watch data offers the handoff without switching")
        _ = watch.store.markPendingControl(.endAndSave, sequence: 99)
        watch.store.disconnect(error: .watchUnavailable)
        check(!ride.canContinueOnIPhone,
              "A ride the rider asked to end is not offered for continuation")
        watch.store.failPendingControl(.endAndSave, sequence: 99, error: .watchUnavailable)
        check(ride.canContinueOnIPhone, "Once that end request fails, the offer returns")

        // Explicit handoff: the existing iPhone recorder starts now.
        var authorization: CheckedContinuation<Void, Never>?
        phone.startWindow = { await withCheckedContinuation { authorization = $0 } }
        let beforeHandoff = Date()
        check(ride.continueOnIPhone(), "The rider can continue without waiting for Apple Watch")
        check(ride.record?.owner == .iphone && disk.record == ride.record
                && disk.record?.continuation?.watch.sessionID == watchID
                && disk.record?.continuation?.watch.endedAt == reconnectAt
                && disk.record?.continuation?.watch.distanceMeters == 300
                && (disk.record?.requestedAt ?? .distantPast) >= beforeHandoff,
              "One durable owner record moves the ride to iPhone with the Watch part's last report")
        check(ledger.ledger.contains(watchID), "The continued Watch session is remembered")
        await spin { authorization != nil }
        // While iPhone waits for Health authorization, the Watch reconnects
        // and delivers data it captured before the handoff.
        let lateAt = reconnectAt.addingTimeInterval(2)
        watch.emit(id: watchID, state: .running, capturedAt: lateAt, moving: 40, distance: 340)
        check(disk.record?.continuation?.watch.endedAt == lateAt && disk.record?.startedAt == nil,
              "Late pre-handoff Watch data is stored while iPhone is still starting")
        check(ride.record?.owner == .iphone && ride.notice?.kind == .information
                && ride.notice?.message.contains("still recording") == true,
              "A Watch still recording is explained, not adopted")
        phone.startWindow = nil
        authorization?.resume()
        await spin { phone.starts == 1 && ride.record?.startedAt != nil }
        let phoneRecord = try require(ride.record)
        let continuation = try require(phoneRecord.continuation)
        check(continuation.watch.endedAt == lateAt && continuation.watch.movingTime == 40
                && continuation.watch.distanceMeters == 340
                && continuation.watch.startedAt == watch.startDates[watchID]
                && disk.record == phoneRecord,
              "The iPhone start keeps Watch-part data stored while it was authorizing")
        check((phoneRecord.startedAt ?? .distantPast) >= (continuation.handoffAt),
              "The iPhone recording starts at the handoff, not before it")
        check(phone.record == phoneRecord && phone.record?.sessionID != watchID,
              "The existing iPhone recorder records the continuation under its own identity")
        check(ride.store.recordingOwner == .iphone
                && ride.store.presentation.sessionID == phoneRecord.sessionID,
              "Bike computer and dashboard now follow iPhone")
        let combined = ride.store.presentation.snapshot
        let phoneOnly = phone.store.presentation.snapshot
        check(combined.startDate == watch.startDates[watchID]
                && combined.cyclingDistance?.value == 340
                && combined.elapsedTime?.value == (phoneOnly.elapsedTime?.value ?? 0) + 40,
              "The ride shows Watch and iPhone totals together")
        check(phoneOnly.cyclingDistance == nil && phoneOnly.startDate == phoneRecord.startedAt,
              "The iPhone recorder and its HealthKit workout keep only the iPhone part")
        check((combined.wallElapsedTime?.value ?? 0) + 0.001 >= (combined.elapsedTime?.value ?? 0),
              "The gap adds ride time, never moving time")
        let summary = try require(ride.rideContinuationSummary)
        check(summary.gap?.start == lateAt && summary.gap?.end == phoneRecord.startedAt
                && summary.watch.distanceMeters == 340 && summary.phone?.endedAt == nil,
              "The summary shows the Watch part, the unrecorded gap and the live iPhone part")
        check(!ride.canContinueOnIPhone && ride.blocksBikeComputerHandoff
                && ride.notice?.kind != .conflict,
              "The continued session is neither re-offered nor a conflict")
        ride.pause()
        check(phone.pauses == 1 && watch.pauses == 0, "Controls go to the iPhone recorder")

        // Late Watch recovery after the iPhone start: a reconnect never
        // switches back and overlapping data is not counted twice.
        check(ride.store.presentation.sessionID == phoneRecord.sessionID,
              "A reconnected Watch never takes the ride back")
        watch.emit(id: watchID, state: .running, capturedAt: Date(), moving: 90, distance: 800)
        check(ride.record?.continuation?.watch.distanceMeters == 340
                && ride.record?.continuation?.watch.recordedPastHandoff == true
                && ride.store.presentation.snapshot.cyclingDistance?.value == 340,
              "Watch data that overlaps the iPhone part is not counted twice")
        watch.emit(id: watchID, state: .ended, outcome: .saved, capturedAt: Date(),
                   moving: 92, distance: 820)
        check(ride.record?.continuation?.watch.savedInFitness == true
                && ride.record?.continuation?.watch.distanceMeters == 340
                && ride.record?.owner == .iphone && ride.notice == nil && watch.saves == 0,
              "The Watch saves its own Fitness workout; Bicino neither ends nor discards it")

        ride.endAndSave()
        check(phone.saves == 1 && watch.saves == 0 && ride.record?.phase == .finished,
              "Finishing saves only the iPhone part")
        let saved = ride.store.presentation.finalSnapshot ?? ride.store.presentation.snapshot
        check(saved.cyclingDistance?.value == 340 && saved.startDate == watch.startDates[watchID],
              "The finished summary keeps the whole ride")
        check(ride.rideContinuationSummary?.phone?.endedAt != nil
                && ride.rideContinuationSummary?.phone?.outcome == .saved,
              "The finished iPhone part has an end time and its own outcome")

        // Restart: both parts persist as one ride.
        let (restarted, restartedWatch, restartedPhone, _, _) = harness(disk, ledger: ledger)
        restarted.recoverIfNeeded()
        await spin { restarted.recoveryComplete }
        check(restarted.record == disk.record && restartedPhone.recoveries == 1
                && restarted.record?.continuation?.watch.sessionID == watchID,
              "A relaunch recovers the continued ride from its single owner record")
        check(restarted.rideContinuationSummary?.gap == ride.rideContinuationSummary?.gap
                && (restarted.store.presentation.finalSnapshot ?? restarted.store.presentation.snapshot)
                    .cyclingDistance?.value == 340,
              "The relaunched summary shows the same parts and gap")
        check(restarted.resetTerminalPresentation() && disk.record == nil
                && restarted.store.presentation.connectionState == .idle,
              "Done dismisses the continued ride")
        check(ledger.ledger.contains(watchID), "Done keeps ignoring the continued Watch session")

        // A mirror that has not identified itself yet is reserved provisionally,
        // then dropped once it proves to be the continued session.
        restartedWatch.store.attachMirroredSession(at: Date())
        restartedWatch.store.confirmSessionState(.running, at: Date())
        check(restarted.record?.owner == .watch && restarted.record?.startedAt == nil,
              "An unidentified mirror is held provisionally, as before")
        restartedWatch.emit(id: watchID, state: .running, capturedAt: Date(), moving: 95, distance: 830)
        check(restarted.record == nil && disk.record == nil
                && restarted.store.presentation.connectionState == .idle,
              "A late reconnect of the continued session is never adopted as a new ride")
        check(restarted.notice?.message.contains("still recording the ride you continued") == true,
              "The rider learns why that Watch workout is not shown")
        restartedWatch.emit(id: watchID, state: .ended, outcome: .saved, capturedAt: Date(),
                            moving: 96, distance: 835)
        await spin { restartedWatch.store.presentation.connectionState == .idle }
        check(restartedWatch.releases == [watchID] && restarted.record == nil
                && restarted.notice == nil && restartedWatch.saves == 0,
              "Once that Watch workout ends it is released without any Watch command")
        let nextWatchID = UUID()
        restartedWatch.emit(id: nextWatchID, state: .running)
        check(restarted.record?.owner == .watch && restarted.record?.sessionID == nextWatchID,
              "A new Watch ride is still adopted normally")

        // Restart before the iPhone recording started: the ride stays the Watch's.
        let crashDisk = MemoryRecordingStore()
        let crashLedger = MemoryHandoffLedger()
        let crashedWatchID = UUID()
        var crashedPart = WorkoutRideContinuation.WatchPart(
            sessionID: crashedWatchID, requestedAt: Date().addingTimeInterval(-600),
            startedAt: Date().addingTimeInterval(-590))
        crashedPart.endedAt = Date().addingTimeInterval(-60)
        var pending = WorkoutRecordingRecord(owner: .iphone, sessionID: UUID(), requestedAt: Date())
        pending.continuation = WorkoutRideContinuation(watch: crashedPart, handoffAt: Date())
        try crashDisk.save(pending)
        crashLedger.ledger = crashLedger.ledger.inserting(crashedWatchID, at: Date())
        let (crashed, crashedWatch, crashedPhone, _, _) = harness(crashDisk, ledger: crashLedger)
        // The Watch workout is still running, so HealthKit's recovery returns
        // its mirrored session rather than an iPhone one.
        crashedPhone.recoversMirror = true
        crashed.recoverIfNeeded()
        await spin { crashed.recoveryComplete }
        check(crashed.record?.owner == .watch && crashed.record?.sessionID == crashedWatchID
                && crashed.record?.startedAt == crashedPart.startedAt
                && crashDisk.record == crashed.record && crashedPhone.starts == 0
                && crashDisk.clears == 0 && crashed.notice?.kind != .recovery,
              "A handoff interrupted before iPhone started is replaced, not deleted, by the Watch record")
        crashedPhone.recoversMirror = false
        check(!crashLedger.ledger.contains(crashedWatchID),
              "The interrupted handoff is forgotten so the Watch ride stays adoptable")
        check(crashed.canContinueOnIPhone,
              "After a restart the rider can continue without waiting for Apple Watch")
        let fitnessSave = WorkoutSavedInFitness(
            sessionID: crashedWatchID, startDate: crashedPart.startedAt,
            endDate: Date().addingTimeInterval(-45), duration: 500,
            distanceMeters: 4_000, activeKilocalories: 120)
        var lookups = 0
        var lookedUp: [(UUID, Bool)] = []
        crashedWatch.fitnessLookup = { id, requestAccess in
            lookups += 1
            lookedUp.append((id, requestAccess))
            return fitnessSave
        }
        check(crashed.continueOnIPhone(), "Continue on iPhone with no Watch data since restart")
        check(crashed.record?.continuation?.watch.endedAt == nil
                && crashed.rideContinuationSummary?.gap == nil,
              "With no Watch data the gap is unknown, not invented")
        await spin { crashed.record?.continuation?.watch.savedInFitness == true }
        let filled = try require(crashed.record?.continuation?.watch)
        check(lookedUp.allSatisfy { $0.0 == crashedWatchID && !$0.1 },
              "Only the continued Watch workout is looked up, without a prompt")
        check(filled.endedAt == fitnessSave.endDate && filled.movingTime == 500
                && filled.distanceMeters == 4_000 && filled.activeKilocalories == 120
                && crashed.rideContinuationSummary?.gap?.start == fitnessSave.endDate
                && crashed.record?.owner == .iphone && crashedWatch.saves == 0,
              "A late Fitness save fills in the Watch part and the gap, read-only")
        check(crashed.store.presentation.snapshot.cyclingDistance?.value == 4_000,
              "The live ride includes the Watch part found in Fitness")
        let lookupsAfterSave = lookups
        crashed.refreshFreshness()
        for _ in 0..<20 { await Task.yield() }
        check(lookups == lookupsAfterSave, "A saved Watch part is not looked up again")

        // The rider discards the continued Watch workout on Apple Watch after
        // the handoff (as in the 2026-11-17 device test).
        let (discarding, discardingWatch, discardingPhone, discardingDisk, _) = harness()
        discarding.recoverIfNeeded()
        await spin { discarding.recoveryComplete }
        let discardedID = UUID()
        discardingWatch.emit(id: discardedID, state: .running,
                             capturedAt: Date().addingTimeInterval(-5), moving: 20, distance: 150)
        discardingWatch.store.disconnect(error: .watchUnavailable)
        var discardLookups = 0
        discardingWatch.fitnessLookup = { _, _ in
            discardLookups += 1
            return nil
        }
        check(discarding.continueOnIPhone(), "The rider continues on iPhone")
        await spin { discardingPhone.starts == 1 && discarding.record?.startedAt != nil
            && discardLookups >= 1 }
        discardingWatch.emit(id: discardedID, state: .ended, outcome: .discarded, capturedAt: Date())
        let discardedPart = try require(discarding.record?.continuation?.watch)
        check(discardedPart.discardedOnWatch == true && !discardedPart.recordedPastHandoff
                && !discardedPart.savedInFitness && discardedPart.distanceMeters == 150
                && discardingDisk.record?.continuation == discarding.record?.continuation,
              "A Watch discard is stored as the Watch part's outcome; counted totals stay")
        check(discarding.rideContinuationSummary?.watchDiscarded == true
                && discarding.rideContinuationSummary?.watchSaved == false
                && discarding.record?.owner == .iphone
                && discarding.store.presentation.snapshot.cyclingDistance?.value == 150
                && discardingWatch.saves == 0,
              "The summary reports the discard, not a Fitness workout; iPhone keeps recording")
        let lookupsAfterDiscard = discardLookups
        discarding.refreshFreshness()
        for _ in 0..<20 { await Task.yield() }
        check(discardLookups == lookupsAfterDiscard && !discarding.canCheckFitness,
              "A discarded Watch part is no longer looked up in Fitness")

        // A failed iPhone start restores Watch ownership.
        let (failing, failingWatch, failingPhone, failingDisk, failingLedger) = harness()
        failing.recoverIfNeeded()
        await spin { failing.recoveryComplete }
        check(failing.requestStart(), "Watch ride starts")
        let failingID = UUID()
        failingWatch.emit(id: failingID, state: .running, moving: 10, distance: 50)
        failingWatch.store.disconnect(error: .watchUnavailable)
        failingPhone.startFails = true
        check(failing.continueOnIPhone(), "The handoff is attempted")
        await spin { failing.record?.owner == .watch }
        check(failing.record?.sessionID == failingID && failingDisk.record == failing.record
                && !failingLedger.ledger.contains(failingID)
                && failing.notice?.kind == .information
                && failing.store.recordingOwner == .watch
                && failing.store.presentation.sessionID == failingID,
              "If iPhone cannot start, the ride stays with Apple Watch")
        check(failingDisk.clears == 0,
              "The iPhone reservation is replaced by the Watch record, never deleted first")
        check(failing.canContinueOnIPhone, "The rider may try again")
        var failingAuthorization: CheckedContinuation<Void, Never>?
        failingPhone.startWindow = { await withCheckedContinuation { failingAuthorization = $0 } }
        check(failing.continueOnIPhone(), "A second attempt is made")
        await spin { failingAuthorization != nil }
        failingDisk.fails = true
        failingAuthorization?.resume()
        await spin { failing.notice?.kind == .recovery }
        failingDisk.fails = false
        check(failingDisk.record?.owner == .iphone && failingDisk.record?.startedAt == nil
                && failingDisk.record?.continuation?.watch.sessionID == failingID,
              "If the Watch record cannot be written, the reservation still holds the ride")
        failingPhone.startWindow = nil
        failing.retryRecovery()
        await spin { failing.recoveryComplete }
        check(failing.record?.owner == .watch && failing.record?.sessionID == failingID
                && failingDisk.record == failing.record && failingDisk.clears == 0
                && !failingLedger.ledger.contains(failingID),
              "Recovery restores the Watch ride from that reservation")

        // After an iPhone restart HealthKit reports the Watch ride, but no
        // snapshot identifies it. The offer must also pass the start gate.
        let liveDisk = MemoryRecordingStore()
        let liveID = UUID()
        try liveDisk.save(WorkoutRecordingRecord(owner: .watch, sessionID: liveID,
            requestedAt: Date().addingTimeInterval(-300),
            startedAt: Date().addingTimeInterval(-290), phase: .running))
        let (live, liveWatch, livePhone, _, _) = harness(liveDisk)
        live.recoverIfNeeded()
        await spin { live.recoveryComplete }
        liveWatch.store.attachMirroredSession(at: Date())
        liveWatch.store.confirmSessionState(.running, at: Date())
        check(liveWatch.store.timeOutFirstSnapshot()
                && liveWatch.store.presentation.connectionState == .disconnected
                && liveWatch.store.presentation.sessionID == nil
                && liveWatch.store.presentation.isWorkoutActive,
              "HealthKit reports the Watch ride but no snapshot arrives")
        check(live.record?.sessionID == liveID && live.canContinueOnIPhone,
              "That unreachable ride is offered for continuation")
        check(live.continueOnIPhone(), "The rider continues")
        await spin { livePhone.starts == 1 && live.record?.startedAt != nil }
        check(live.record?.owner == .iphone && live.notice == nil
                && live.record?.continuation?.watch.sessionID == liveID,
              "The start gate admits the unidentified session being continued")

        // An unreadable ledger is never written over.
        let lockedLedger = MemoryHandoffLedger()
        let earlierID = UUID()
        lockedLedger.ledger = WorkoutHandoffLedger().inserting(earlierID, at: Date().addingTimeInterval(-60))
        lockedLedger.readFails = true
        let (locked, lockedWatch, lockedPhone, _, _) = harness(ledger: lockedLedger)
        locked.recoverIfNeeded()
        await spin { locked.recoveryComplete }
        let lockedID = UUID()
        lockedWatch.emit(id: lockedID, state: .running, moving: 5, distance: 20)
        lockedWatch.store.disconnect(error: .watchUnavailable)
        check(locked.continueOnIPhone(), "Continuing does not depend on the ledger")
        await spin { lockedPhone.starts == 1 }
        check(lockedLedger.ledger.contains(earlierID) && !lockedLedger.ledger.contains(lockedID),
              "While unreadable, the stored ledger keeps its earlier entries")
        lockedLedger.readFails = false
        lockedWatch.emit(id: lockedID, state: .running, moving: 9, distance: 40)
        check(lockedLedger.ledger.contains(earlierID) && lockedLedger.ledger.contains(lockedID)
                && locked.record?.owner == .iphone,
              "Once readable, earlier and new handoffs are both kept")

        // Offer policy and display arithmetic.
        let date = Date()
        let policyID = UUID()
        let running = WorkoutRecordingRecord(owner: .watch, sessionID: policyID,
            requestedAt: date, startedAt: date, phase: .running)
        func presentation(_ connection: WorkoutMirrorConnectionStateV1,
                          _ state: WorkoutSessionStateV1, id: UUID?,
                          pending: WorkoutControlV1? = nil) -> WorkoutMirrorPresentationV1 {
            WorkoutMirrorPresentationV1(connectionState: connection,
                snapshot: WorkoutSnapshotV1(state: state, startDate: date), sessionID: id,
                capturedAt: date, receivedAt: date, confirmedSessionState: nil, errorCode: nil,
                pendingControl: pending, finalSnapshot: nil, navigation: .empty)
        }
        func offered(_ record: WorkoutRecordingRecord?, _ presentation: WorkoutMirrorPresentationV1,
                     ready: Bool = true, phone: Bool = true) -> Bool {
            WorkoutHandoffPolicy.mayOfferContinueOnIPhone(record: record,
                presentation: presentation, ready: ready, phoneSupported: phone)
        }
        check(offered(running, presentation(.disconnected, .paused, id: policyID)),
              "A paused, unreachable Watch ride can continue on iPhone")
        check(!offered(running, presentation(.disconnected, .running, id: policyID), ready: false)
                && !offered(running, presentation(.disconnected, .running, id: policyID), phone: false),
              "No offer before recovery or without the iOS 26 recorder")
        check(!offered(running, presentation(.disconnected, .ending, id: policyID))
                && !offered(running, presentation(.disconnected, .running, id: policyID, pending: .discard)),
              "An ending ride is not continued")
        check(!offered(running, presentation(.disconnected, .running, id: UUID()))
                && !offered(running, presentation(.awaitingFirstSnapshot, .running, id: nil))
                && !offered(running, presentation(.connected, .running, id: policyID)),
              "Another session, a reattaching mirror or a live Watch is not offered")
        check(offered(running, presentation(.disconnected, .running, id: nil))
                && offered(running, presentation(.idle, .idle, id: nil)),
              "An unidentified unreachable session or no mirror at all is offered")
        var launching = running
        launching.startedAt = nil
        launching.phase = .unresolved
        check(!offered(launching, presentation(.idle, .idle, id: nil)),
              "An unconfirmed Watch launch has no ride to continue")
        var phoneOwned = running
        phoneOwned.owner = .iphone
        check(!offered(phoneOwned, presentation(.disconnected, .running, id: policyID)),
              "An iPhone ride is never offered")

        var part = WorkoutRideContinuation.WatchPart(sessionID: policyID, requestedAt: date,
            startedAt: date.addingTimeInterval(-1_000))
        part.movingTime = 300
        part.distanceMeters = 2_000
        part.activeKilocalories = 80
        part.averageHeartRate = 130
        let math = WorkoutRideContinuation(watch: part, handoffAt: date.addingTimeInterval(-500))
        let phoneStart = date.addingTimeInterval(-500)
        let phoneSnapshot = WorkoutSnapshotV1(state: .running, startDate: phoneStart,
            elapsedTime: WorkoutMetricV1(value: 100, unit: .seconds, capturedAt: date),
            averageHeartRate: WorkoutMetricV1(value: 150, unit: .beatsPerMinute, capturedAt: date),
            currentSpeed: WorkoutMetricV1(value: 7, unit: .metersPerSecond, capturedAt: date,
                                          source: .iPhoneLocation),
            availability: [.elapsedTime, .averageHeartRate, .currentSpeed],
            wallElapsedTime: WorkoutMetricV1(value: 120, unit: .seconds, capturedAt: date))
        let whole = WorkoutRideContinuationMath.combined(phoneSnapshot, continuation: math)
        check(whole.startDate == part.startedAt && whole.elapsedTime?.value == 400
                && whole.wallElapsedTime?.value == 620 && whole.cyclingDistance?.value == 2_000
                && whole.activeEnergy?.value == 80 && whole.averageHeartRate?.value == 135
                && whole.currentSpeed == phoneSnapshot.currentSpeed
                && whole.availability.contains(.cyclingDistance),
              "Totals add up, the average is time-weighted and live values stay iPhone's")
        let skewed = WorkoutRideContinuation.WatchPart(sessionID: policyID, requestedAt: date,
            startedAt: phoneStart.addingTimeInterval(1))
        check(WorkoutRideContinuationMath.combined(phoneSnapshot,
                continuation: WorkoutRideContinuation(watch: skewed, handoffAt: date)) == phoneSnapshot,
              "Inconsistent clocks never produce a negative-length ride")
    }

    /// Siri's ride commands on the real coordinator: an iPhone ride from
    /// start to a confirmed finish, a Watch ride, the Watch activation wait,
    /// and the refusals Siri speaks instead of sending a command.
    @MainActor
    private static func siriWorkoutCommandScenarios(check: (Bool, String) -> Void) async throws {
        func harness(phone hasPhone: Bool = true,
                     availability initial: WorkoutWatchAvailabilityV1 = .noPairedWatch)
            -> (WorkoutSessionCoordinator, FakeWatch, FakePhone?, FakeAvailability, MemoryRecordingStore) {
            let disk = MemoryRecordingStore()
            let watch = FakeWatch()
            let phone = hasPhone ? FakePhone(disk) : nil
            let availability = FakeAvailability()
            availability.availability = initial
            return (WorkoutSessionCoordinator(watch: watch, watchAvailability: availability,
                persistence: disk, phone: phone, handoffLedger: MemoryHandoffLedger()),
                    watch, phone, availability, disk)
        }
        // One scheduler turn per poll: the 3 s budget is 30 turns.
        let turn: @MainActor (TimeInterval) async -> Void = { _ in await Task.yield() }

        check(BicinoWorkoutCommand.allCases.filter(\.requiresConfirmation) == [.finish],
              "Only Finish asks before acting")
        check(BicinoWorkoutReplyText.text(for: .needsConfirmation(.watch, sessionID: UUID()))
                == "Finish and save your ride on Apple Watch?",
              "The confirmation names the recorder")
        check(BicinoWorkoutReplyText.text(for: .failed(.start, nil))
                == "Bicino couldn't start a ride. Open Bicino to check it.",
              "An unexplained start failure points to the app")

        // iPhone ride, as on an iPhone without a paired Watch.
        let (coordinator, _, phoneOrNil, _, _) = harness()
        let phone = try require(phoneOrNil)
        var routed: [BicinoWorkoutCommand] = []
        var routedSessions: [UUID] = []
        let runner = BicinoWorkoutCommandRunner(
            coordinator: coordinator,
            control: { command, sessionID in
                routed.append(command)
                routedSessions.append(sessionID)
                switch command {
                case .pause: coordinator.pause()
                case .resume: coordinator.resume()
                case .segment: coordinator.markSegment()
                case .start, .finish: return false
                }
                return true
            },
            wait: turn
        )
        coordinator.recoverIfNeeded()
        await spin { coordinator.recoveryComplete }
        check(await runner.run(.pause) == .noRide, "Pause without a ride says so")
        check(await runner.run(.finish) == .noRide, "Finish without a ride asks nothing")
        check(routed.isEmpty, "Nothing is sent without a ride")
        check(await runner.run(.start) == .done(.start, .iphone) && phone.starts == 1,
              "Without a paired Watch, Start records on iPhone and waits for it to run")
        let rideID = try require(coordinator.store.presentation.sessionID)
        check(await runner.run(.start) == .alreadyRecording(.iphone) && phone.starts == 1,
              "A second Start never starts another ride")
        check(await runner.run(.resume) == .notPaused, "Resume on a running ride says so")
        check(await runner.run(.pause) == .done(.pause, .iphone) && phone.pauses == 1,
              "Pause is sent and confirmed")
        check(await runner.run(.pause) == .alreadyPaused && phone.pauses == 1,
              "A second Pause sends nothing")
        check(await runner.run(.segment) == .segmentNeedsRunningRide,
              "A paused ride takes no segment")
        check(await runner.run(.resume) == .done(.resume, .iphone), "Resume is sent and confirmed")
        check(await runner.run(.segment) == .done(.segment, .iphone), "Segment is sent")
        check(routed == [.pause, .resume, .segment] && routedSessions.allSatisfy { $0 == rideID },
              "Only Pause, Resume and Segment use the control path, for the live session")
        check(await runner.run(.finish) == .needsConfirmation(.iphone, sessionID: rideID)
                && phone.saves == 0,
              "Finish asks about the live ride before ending it")
        check(await runner.run(.finish, confirmedSession: UUID()) == .rideChanged && phone.saves == 0,
              "A yes for another ride finishes nothing")
        check(await runner.run(.finish, confirmedSession: rideID) == .done(.finish, .iphone)
                && phone.saves == 1,
              "A confirmed Finish saves the ride once")
        check(await runner.run(.pause) == .noRide, "A finished ride takes no more controls")
        check(await runner.run(.start) == .done(.start, .iphone) && phone.starts == 2,
              "Start after a finish acknowledges the summary and starts the next ride")

        // Apple Watch ride. The fake Watch confirms nothing by itself.
        let (watchRide, watch, _, _, _) = harness(availability: .ready(isReachable: true))
        var watchRouted: [BicinoWorkoutCommand] = []
        let watchRunner = BicinoWorkoutCommandRunner(
            coordinator: watchRide,
            control: { command, _ in
                watchRouted.append(command)
                guard command == .pause else { return false }
                watchRide.pause()
                return watch.store.markPendingControl(.pause, sequence: 7)
            },
            wait: turn
        )
        watchRide.recoverIfNeeded()
        await spin { watchRide.recoveryComplete }
        check(await watchRunner.run(.start) == .sent(.start, .watch) && watch.starts == 1,
              "A Watch start is reported as starting until the Watch runs it")
        check(await watchRunner.run(.pause) == .busy(.watch) && watchRouted.isEmpty,
              "Nothing is sent before the Watch ride is running")
        let watchRideID = UUID()
        watch.emit(id: watchRideID, state: .running)
        check(await watchRunner.run(.start) == .alreadyRecording(.watch) && watch.starts == 1,
              "Start during a Watch ride starts nothing")
        check(await watchRunner.run(.pause) == .sent(.pause, .watch) && watch.pauses == 1,
              "An unconfirmed Watch pause is reported as sent")
        check(await watchRunner.run(.segment) == .busy(.watch) && watchRouted == [.pause],
              "A command in flight holds the next one")
        check(await watchRunner.run(.finish) == .busy(.watch) && watch.saves == 0,
              "Finish waits for the command in flight")
        watch.store.disconnect(error: .watchUnavailable)
        check(await watchRunner.run(.finish) == .unreachable(.watch) && watch.saves == 0,
              "An unreachable Watch keeps its ride; Siri sends nothing")

        // Finishing a Watch ride: sent to the Watch, done once it reports the save.
        let (finishing, finishingWatch, _, _, _) = harness(availability: .ready(isReachable: true))
        finishing.recoverIfNeeded()
        await spin { finishing.recoveryComplete }
        let finishedID = UUID()
        finishingWatch.emit(id: finishedID, state: .running)
        var publishedSessions: [UUID] = []
        var watchSaves = false
        let finishingRunner = BicinoWorkoutCommandRunner(
            coordinator: finishing,
            control: { _, _ in false },
            publish: { sessionID in
                publishedSessions.append(sessionID)
                if watchSaves, finishingWatch.saves == 1, publishedSessions.count == 1 {
                    finishingWatch.emit(id: finishedID, state: .ended, outcome: .saved)
                }
            },
            wait: turn
        )
        check(await finishingRunner.run(.finish) == .needsConfirmation(.watch, sessionID: finishedID)
                && finishingWatch.saves == 0 && publishedSessions.isEmpty,
              "A Watch finish asks first and sends nothing")
        watchSaves = true
        check(await finishingRunner.run(.finish, confirmedSession: finishedID) == .done(.finish, .watch)
                && finishingWatch.saves == 1,
              "A confirmed Watch finish is sent once and reported once the Watch saves")
        check(publishedSessions == [finishedID, finishedID],
              "The Lock Screen is updated after sending and after the result")
        check(finishing.record?.phase == .finished, "The coordinator records the finished ride")

        // Apple Watch still activating: the coordinator starts once it answers.
        let (activating, slowWatch, _, slowAvailability, _) = harness(availability: .activating)
        activating.recoverIfNeeded()
        await spin { activating.recoveryComplete }
        let answeringRunner = BicinoWorkoutCommandRunner(
            coordinator: activating,
            control: { _, _ in false },
            wait: { _ in
                if slowAvailability.availability == .activating {
                    slowAvailability.availability = .ready(isReachable: true)
                }
                await Task.yield()
            }
        )
        // A notice the app left up earlier must not stop the wait.
        activating.chooseRecorder()
        check(activating.notice?.kind == .chooseRecorder, "Fixture leaves the recorder prompt up")
        check(await answeringRunner.run(.start) == .sent(.start, .watch) && slowWatch.starts == 1,
              "Start waits for Watch activation and then starts on the Watch")
        let (silent, silentWatch, _, _, _) = harness(availability: .activating)
        silent.recoverIfNeeded()
        await spin { silent.recoveryComplete }
        let silentRunner = BicinoWorkoutCommandRunner(
            coordinator: silent, control: { _, _ in false }, wait: turn)
        check(await silentRunner.run(.start) == .waitingForWatch && silentWatch.starts == 0,
              "A Watch that hasn't answered yet is reported, and the start stays queued")

        // iPhone can't record here: no paired Watch and no iPhone recorder.
        let (watchOnly, _, _, _, _) = harness(phone: false)
        watchOnly.recoverIfNeeded()
        await spin { watchOnly.recoveryComplete }
        let watchOnlyRunner = BicinoWorkoutCommandRunner(
            coordinator: watchOnly, control: { _, _ in false }, wait: turn)
        check(await watchOnlyRunner.run(.start) == .iPhoneRecordingUnsupported
                && watchOnly.record == nil,
              "Without a Watch or iPhone recording, Start explains why")

        // Recovery that can't read the ownership record blocks every command.
        let (unrecovered, _, _, _, unreadable) = harness()
        unreadable.fails = true
        unrecovered.recoverIfNeeded()
        let unrecoveredRunner = BicinoWorkoutCommandRunner(
            coordinator: unrecovered, control: { _, _ in false }, wait: turn)
        check(await unrecoveredRunner.run(.start) == .checkingForRide && unrecovered.record == nil,
              "Start waits for ownership recovery instead of guessing")
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw CoordinatorTestError.missingValue }
        return value
    }

    private enum CoordinatorTestError: Error { case missingValue }

    @MainActor
    private static func spin(until condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("Asynchronous coordinator did not settle")
    }
}
