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
    func clear(sessionID: UUID) throws {
        if fails { throw WorkoutRecordingStore.StoreError.invalidRecord }
        guard record == nil || record?.sessionID == sessionID else {
            throw WorkoutRecordingStore.StoreError.identityMismatch
        }
        record = nil
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
private final class FakeWatch: WorkoutWatchRecording {
    let store = WorkoutMetricsStore()
    var starts = 0
    var pauses = 0
    var saves = 0
    var startAdmission: (() -> Void)?
    var sequence: UInt64 = 0
    let date = Date().addingTimeInterval(-60)
    var rideAutomationPresentation: WorkoutMirrorPresentationV1 { store.presentation }
    var rideAutomationPresentationPublisher: AnyPublisher<WorkoutMirrorPresentationV1, Never> { store.$presentation.eraseToAnyPublisher() }
    func startOutdoorCyclingOnWatch() -> Bool {
        startAdmission?()
        starts += 1
        return store.beginWatchLaunch(id: UUID(), at: Date(), timeout: 15)
    }
    func pause() { pauses += 1 }
    func resume() {}
    func markSegment() {}
    func endAndSave() { saves += 1 }
    func discard() {}
    func refreshFreshness() {}
    func resetTerminalPresentation() -> Bool { store.resetTerminalPresentation() }
    func requestAutomaticTransition(_ transition: RideAutomationTransition, context: WorkoutControlContextV1) -> Bool { true }
    func requestAutomaticTransitionConfirmation(_ transition: RideAutomationTransition, context: WorkoutControlContextV1) -> Bool { true }
    func requestAutomaticStartAnnotation(context: WorkoutControlContextV1) -> Bool { true }

    func emit(id: UUID, state: WorkoutSessionStateV1, outcome: WorkoutTerminalOutcomeV1? = nil) {
        sequence += 1
        if state.isActive { store.attachMirroredSession(at: Date()) }
        let result = store.ingestBatch([WorkoutEnvelopeV1(
            kind: .snapshot, sessionID: id, sessionToken: 19,
            sequence: sequence, capturedAt: Date(),
            snapshot: WorkoutSnapshotV1(state: state, startDate: date,
                availability: [], terminalOutcome: outcome)
        )], receivedAt: Date())
        precondition(result.rejections.isEmpty, "Fixture must pass real contract validation")
    }
}

@MainActor
private final class FakePhone: PhoneWorkoutRecording {
    let store = WorkoutMetricsStore()
    let persistence: MemoryRecordingStore
    var record: WorkoutRecordingRecord?
    var message: String?
    var recoveryFails = false
    var starts = 0
    var pauses = 0
    var saves = 0
    var sequence: UInt64 = 0
    init(_ persistence: MemoryRecordingStore) { self.persistence = persistence }
    func recover(expected: WorkoutRecordingRecord?) async throws {
        if recoveryFails { throw WorkoutRecordingStore.StoreError.invalidRecord }
        guard let expected, expected.owner == .iphone else { return }
        record = expected
        store.beginLocalWorkout()
        emit(expected.phase == .finished ? .ended : .running)
    }
    func start(_ record: WorkoutRecordingRecord) async {
        precondition(persistence.record == record, "Owner must be durable before start")
        self.record = record
        self.record?.startedAt = Date().addingTimeInterval(-1)
        self.record?.phase = .running
        starts += 1
        store.beginLocalWorkout()
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
    private func emit(_ state: WorkoutSessionStateV1) {
        guard let record else { return }
        sequence += 1
        let result = store.ingestBatch([WorkoutEnvelopeV1(
            kind: .snapshot, sessionID: record.sessionID, sessionToken: 23,
            sequence: sequence, capturedAt: Date(),
            snapshot: WorkoutSnapshotV1(state: state,
                startDate: record.startedAt, availability: [],
                terminalOutcome: record.finishedChoice.map { $0 == .save ? .saved : .discarded })
        )], receivedAt: Date())
        precondition(result.rejections.isEmpty)
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
                persistence: disk, phone: phone), watch, phone, availability, disk)
        }
        let (coordinator, watch, phone, availability, disk) = harness()
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

        let (choose, watch3, phone3, availability3, _) = harness()
        availability3.availability = .ready(isReachable: false)
        choose.recoverIfNeeded()
        await spin { choose.recoveryComplete }
        check(!choose.requestStart() && choose.notice?.kind == .chooseRecorder, "Unreachable Watch asks explicitly")
        check(watch3.starts == 0 && phone3.starts == 0, "No recorder silently starts")
        check(choose.requestStart(explicitOwner: .iphone), "Explicit phone override admitted")
        await spin { phone3.starts == 1 }
        check(choose.record?.owner == .iphone, "Explicit phone selection stays selected")

        let (recovery, watch4, phone4, _, disk4) = harness()
        phone4.recoveryFails = true
        recovery.recoverIfNeeded()
        await spin { recovery.notice?.kind == .recovery }
        check(!recovery.recoveryComplete && !recovery.requestStart(explicitOwner: .watch), "Recovery failure blocks even Watch starts")
        check(watch4.starts == 0 && phone4.starts == 0, "Recovery never creates substitute workout")
        phone4.recoveryFails = false
        recovery.retryRecovery()
        await spin { recovery.recoveryComplete }
        disk4.fails = true
        check(!recovery.requestStart(explicitOwner: .iphone), "Storage failure prevents native start")
        check(phone4.starts == 0, "No recording without durable owner")
        print("Workout session coordinator: \(count) assertions passed")
    }

    @MainActor
    private static func spin(until condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("Asynchronous coordinator did not settle")
    }
}
