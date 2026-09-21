import Foundation

@main
struct WorkoutRecordingOwnershipTests {
    @MainActor
    static func main() throws {
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            assertions += 1
        }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let availability: [WorkoutWatchAvailabilityV1] = [
            .activating, .unsupported, .activationFailed, .noPairedWatch,
            .companionAppNotInstalled, .ready(isReachable: false), .ready(isReachable: true)
        ]
        func decision(_ watch: WorkoutWatchAvailabilityV1, recovery: Bool = true,
                      record: WorkoutRecordingRecord? = nil, phone: Bool = true,
                      explicit: WorkoutRecordingOwner? = nil) -> WorkoutRecordingStartDecision {
            WorkoutRecordingStartPolicy.resolve(recoveryComplete: recovery,
                existingRecording: record, watchAvailability: watch,
                phoneSupported: phone, explicitOwner: explicit)
        }
        check(decision(.activating) == .waitForWatchActivation, "Activation is not absence")
        check(decision(.noPairedWatch) == .start(.iphone), "Unpaired iPhone default")
        check(decision(.noPairedWatch, phone: false) == .phoneUnsupported, "Old OS has no phone recorder")
        check(decision(.ready(isReachable: true)) == .start(.watch), "Ready Watch remains default")
        check(decision(.ready(isReachable: false)) == .start(.watch),
              "Interactive reachability does not block HealthKit Watch launch")
        check(decision(.companionAppNotInstalled) == .chooseRecorder, "Missing companion needs explicit choice")
        check(decision(.activationFailed) == .chooseRecorder, "Activation failure is not unpaired")
        for watch in availability {
            check(decision(watch, recovery: false) == .waitForRecovery, "Cold-start recovery always first")
            check(decision(watch, recovery: false, explicit: .iphone) == .waitForRecovery, "Explicit start cannot bypass recovery")
            check(decision(watch, explicit: .iphone) == .start(.iphone), "Explicit phone choice")
            check(decision(watch, phone: false, explicit: .iphone) == .phoneUnsupported, "Availability guard")
            check(decision(watch, explicit: .watch) == .start(.watch), "Explicit Watch retains native wake path")
        }
        for owner in [WorkoutRecordingOwner.watch, .iphone] {
            for phase in [WorkoutRecordingRecord.Phase.starting, .running, .paused, .finishing, .unresolved, .finished] {
                var record = WorkoutRecordingRecord(owner: owner, sessionID: UUID(), requestedAt: date)
                record.phase = phase
                if phase == .finishing || phase == .finished { record.finishChoice = .save }
                if phase == .finished { record.finishedChoice = .save }
                check(record.isValid, "Lifecycle record validates")
                for watch in availability {
                    check(decision(watch, record: record) == .blockedByExistingRecording,
                          "Connectivity never changes the selected owner")
                    check(decision(watch, record: record, explicit: owner == .watch ? .iphone : .watch)
                          == .blockedByExistingRecording, "Explicit start cannot steal a ride")
                }
                check(WorkoutRecordingStartPolicy.mayPublish(from: owner, selectedRecord: record), "Selected source may publish")
                check(!WorkoutRecordingStartPolicy.mayPublish(from: owner == .watch ? .iphone : .watch,
                    selectedRecord: record), "Late other-owner metrics cannot overwrite selected metrics")
                check(WorkoutRecordingStartPolicy.mayYieldBikeComputer(record: record)
                      == (owner == .watch || phase == .finished), "Phone start/recovery/finish reserves bike link")
            }
        }
        var record = WorkoutRecordingRecord(owner: .iphone, sessionID: UUID(), requestedAt: date)
        record.startedAt = date
        let save = try require(record.finishing(.save))
        check(save.finishing(.discard) == nil, "Save intent cannot become discard")
        check(save.finishing(.save) == save, "Retry preserves same identity and intent")
        check(save.finished(.discard) == nil, "Cannot report opposite outcome")
        var attempted = save
        attempted.saveAttempted = true
        let encoded = try JSONEncoder().encode(attempted)
        let decoded = try JSONDecoder().decode(WorkoutRecordingRecord.self, from: encoded)
        check(decoded == attempted, "Ambiguous save boundary survives restart")
        let terminal = try require(decoded.finished(.save))
        check(terminal.finishing(.save) == nil, "Tombstone cannot re-enter finalization")
        let discard = try require(record.finishing(.discard))
        check(discard.finishing(.save) == nil, "Discard cannot become save")
        var invalid = discard
        invalid.saveAttempted = true
        check(!invalid.isValid, "Discard cannot have a save attempt")
        invalid = record; invalid.schemaVersion = 99
        check(!invalid.isValid, "Unknown schema is not empty state")
        invalid = record; invalid.phase = .finished
        check(!invalid.isValid, "Finished requires authoritative disposition")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutRecordingStore(url: directory.appendingPathComponent("owner.json"))
        check(try store.load() == nil, "Missing file is truly empty")
        try store.save(attempted)
        check(try store.load() == attempted, "Atomic durable round trip")
        do {
            try store.clear(sessionID: UUID())
            preconditionFailure("Wrong ride must not clear ownership")
        } catch WorkoutRecordingStore.StoreError.identityMismatch { assertions += 1 }
        check(try store.load() == attempted, "Failed clear leaves record intact")
        try Data("{broken".utf8).write(to: store.url)
        do {
            _ = try store.load()
            preconditionFailure("Corruption must not return no-workout")
        } catch { assertions += 1 }
        try store.save(terminal)
        try store.clear(sessionID: terminal.sessionID)
        check(try store.load() == nil, "Only matching acknowledged ride is cleared")
        print("Workout recording ownership: \(assertions) assertions passed")
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw TestError.missingValue }
        return value
    }
    private enum TestError: Error { case missingValue }
}
