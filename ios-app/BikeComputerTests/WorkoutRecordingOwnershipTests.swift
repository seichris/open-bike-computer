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
        let unconfirmedWatches: [WorkoutWatchAvailabilityV1] = [
            .ready(isReachable: false), .companionAppNotInstalled, .activationFailed
        ]
        for unconfirmedWatch in unconfirmedWatches {
            check(decision(unconfirmedWatch) == .chooseRecorder,
                  "An uncertain Watch prompts for a recorder before launching either device")
            check(decision(unconfirmedWatch, phone: false) == .start(.watch),
                  "An older iPhone preserves native Watch launch")
        }
        check(decision(.unsupported) == .start(.iphone),
              "Unsupported WatchConnectivity uses the available phone recorder")
        check(decision(.unsupported, phone: false) == .phoneUnsupported,
              "Unsupported WatchConnectivity cannot invent a recorder")
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
        let pauseIntent = WorkoutNativeTransitionIntent(id: UUID(), paused: true,
            capturedAt: date.addingTimeInterval(10))
        let pending = try require(record.addingNativeTransition(pauseIntent))
        check(pending.isValid && pending.pendingNativeTransitions == [pauseIntent],
              "Native event intent is durable ownership bookkeeping")
        check(try JSONDecoder().decode(WorkoutRecordingRecord.self,
            from: JSONEncoder().encode(pending)) == pending,
              "A pending native event survives process loss")
        check(pending.addingNativeTransition(pauseIntent) == pending,
              "A repeated native callback cannot duplicate its pending event")
        check(pending.finishing(.save) == nil,
              "Saving waits for acknowledged native event writes")
        check(pending.finishing(.discard)?.pendingNativeTransitions == nil,
              "An explicit discard can retire unfinished native event writes")
        var fullJournal = record
        for index in 0..<32 {
            fullJournal = try require(fullJournal.addingNativeTransition(.init(id: UUID(),
                paused: index % 2 == 0, capturedAt: date.addingTimeInterval(Double(index)))))
        }
        check(fullJournal.addingNativeTransition(.init(id: UUID(), paused: true,
            capturedAt: date.addingTimeInterval(40))) == nil,
              "Native transition journal admission is bounded")
        var legacyObject = try require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "pendingNativeTransitions")
        check(try JSONDecoder().decode(WorkoutRecordingRecord.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)).pendingNativeTransitions == nil,
              "Earlier ownership records retain backwards-compatible recovery")
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
        let metadata = try WorkoutRecordingMetadataCodec.encode(attempted)
        check(WorkoutRecordingMetadataCodec.decode(WorkoutRecordingRecord.self, from: metadata) == attempted,
              "HealthKit-compatible string metadata preserves the original typed recording data")
        check(WorkoutRecordingMetadataCodec.decode(WorkoutRecordingRecord.self,
              from: try JSONEncoder().encode(attempted)) == attempted,
              "Legacy in-memory binary metadata remains readable")
        check(WorkoutRecordingMetadataCodec.decode(WorkoutRecordingRecord.self, from: "invalid") == nil
                  && WorkoutRecordingMetadataCodec.decode(WorkoutRecordingRecord.self, from: 7) == nil,
              "Malformed or unsupported metadata cannot manufacture recording data")
        try continueOnIPhoneModel(date: date, check: check)
        print("Workout recording ownership: \(assertions) assertions passed")
    }

    /// Continue on iPhone: one atomic owner record carries the Watch part,
    /// late Watch data never double-counts, and the gap is never negative.
    @MainActor
    private static func continueOnIPhoneModel(
        date: Date, check: (Bool, String) -> Void
    ) throws {
        let watchID = UUID()
        let watchStart = date.addingTimeInterval(-3_600)
        let lastWatchData = date.addingTimeInterval(-600)
        let handoff = date.addingTimeInterval(-300)
        let phoneStart = date.addingTimeInterval(-298)
        var part = WorkoutRideContinuation.WatchPart(
            sessionID: watchID, requestedAt: watchStart, startedAt: watchStart)
        part.endedAt = lastWatchData
        part.movingTime = 2_400
        part.distanceMeters = 20_000
        part.averageHeartRate = 140
        let continuation = WorkoutRideContinuation(watch: part, handoffAt: handoff)
        check(continuation.isValid, "A Watch part with ordered boundaries is valid")

        var phone = WorkoutRecordingRecord(owner: .iphone, sessionID: UUID(), requestedAt: handoff)
        phone.continuation = continuation
        check(phone.isValid, "An iPhone recording may continue a Watch ride")
        var watchOwned = WorkoutRecordingRecord(owner: .watch, sessionID: UUID(), requestedAt: handoff)
        watchOwned.continuation = continuation
        check(!watchOwned.isValid, "Only an iPhone recording can carry a continued Watch part")
        var sameSession = WorkoutRecordingRecord(owner: .iphone, sessionID: watchID, requestedAt: handoff)
        sameSession.continuation = continuation
        check(!sameSession.isValid, "The iPhone part has its own HealthKit identity")
        var reversed = part
        reversed.endedAt = watchStart.addingTimeInterval(-1)
        check(!WorkoutRideContinuation(watch: reversed, handoffAt: handoff).isValid,
              "A Watch part cannot end before it starts")

        let encoded = try JSONEncoder().encode(phone)
        check(try JSONDecoder().decode(WorkoutRecordingRecord.self, from: encoded) == phone,
              "Both parts survive a restart in the single owner record")
        check(!String(decoding: encoded, as: UTF8.self).contains("discardedOnWatch"),
              "Records from builds before the discard outcome (no such key) decode as shown above")
        let legacy = WorkoutRecordingRecord(owner: .watch, sessionID: UUID(), requestedAt: date)
        var legacyJSON = try require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(legacy)) as? [String: Any])
        legacyJSON.removeValue(forKey: "continuation")
        check(try JSONDecoder().decode(WorkoutRecordingRecord.self,
                from: JSONSerialization.data(withJSONObject: legacyJSON)) == legacy,
              "Records written before this change still load")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bicino-continuation-\(UUID().uuidString)/owner-v1.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = WorkoutRecordingStore(url: url)
        try store.save(phone)
        check(try store.load() == phone, "The owner file keeps the Watch part across launches")

        // Late data captured before iPhone took over extends the Watch part.
        let late = continuation.absorbing(.init(
            capturedAt: date.addingTimeInterval(-400), movingTime: 2_550,
            distanceMeters: 21_000, averageHeartRate: 142
        ), phoneStartedAt: phoneStart)
        check(late.watch.endedAt == date.addingTimeInterval(-400)
                && late.watch.movingTime == 2_550 && late.watch.distanceMeters == 21_000
                && !late.watch.recordedPastHandoff,
              "Watch data from before the iPhone start shrinks the gap")
        check(late.gap(phoneStartedAt: phoneStart)?.duration == 102,
              "The gap runs from the last counted Watch data to the iPhone start")
        // Data after the iPhone start overlaps the iPhone part.
        let overlap = late.absorbing(.init(
            capturedAt: date, movingTime: 2_800, distanceMeters: 23_500, savedInFitness: true
        ), phoneStartedAt: phoneStart)
        check(overlap.watch.movingTime == 2_550 && overlap.watch.distanceMeters == 21_000
                && overlap.watch.endedAt == late.watch.endedAt,
              "Watch totals after the handoff are not added to the ride a second time")
        check(overlap.watch.recordedPastHandoff && overlap.watch.savedInFitness,
              "The overlap and the Watch save are recorded without discarding either")
        let discarded = late.absorbing(.init(capturedAt: date, discardedOnWatch: true),
                                       phoneStartedAt: phoneStart)
        check(discarded.watch.discardedOnWatch == true
                && discarded.watch.endedAt == late.watch.endedAt
                && discarded.watch.distanceMeters == late.watch.distanceMeters
                && discarded.watch.movingTime == late.watch.movingTime
                && !discarded.watch.recordedPastHandoff && !discarded.watch.savedInFitness,
              "A discard on Apple Watch changes only the Watch outcome; counted totals stay")
        let older = late.absorbing(.init(
            capturedAt: lastWatchData, movingTime: 2_000, distanceMeters: 15_000
        ), phoneStartedAt: phoneStart)
        check(older == late, "An older late report cannot shrink the Watch part")
        let partialSave = late.absorbing(.init(
            capturedAt: date.addingTimeInterval(-350), movingTime: 2_500, distanceMeters: nil,
            savedInFitness: true
        ), phoneStartedAt: phoneStart)
        check(partialSave.watch.movingTime == 2_550 && partialSave.watch.distanceMeters == 21_000
                && partialSave.watch.savedInFitness,
              "A smaller or incomplete Fitness total never discards data already counted")
        let beforeStart = continuation.absorbing(.init(
            capturedAt: handoff.addingTimeInterval(1), movingTime: 3_000
        ), phoneStartedAt: nil)
        check(beforeStart.watch.recordedPastHandoff && beforeStart.watch.movingTime == 2_400,
              "Before iPhone confirms its start, the rider's choice is the boundary")
        var skewed = part
        skewed.endedAt = phoneStart.addingTimeInterval(2)
        check(WorkoutRideContinuation(watch: skewed, handoffAt: handoff)
                .gap(phoneStartedAt: phoneStart)?.duration == 0,
              "A Watch clock running ahead never produces negative gap time")
        var unknown = part
        unknown.endedAt = nil
        check(WorkoutRideContinuation(watch: unknown, handoffAt: handoff)
                .gap(phoneStartedAt: phoneStart) == nil,
              "An unknown Watch end leaves the gap unknown, not zero")

        check(WorkoutRecordingStartPolicy.phoneMayStart(
                phone, watchSessionID: watchID, watchWorkoutBusy: true),
              "Continue on iPhone may start beside the exact unreachable Watch session")
        check(!WorkoutRecordingStartPolicy.phoneMayStart(
                phone, watchSessionID: UUID(), watchWorkoutBusy: true),
              "A different identified Watch workout still blocks the continuation")
        check(WorkoutRecordingStartPolicy.phoneMayStart(
                phone, watchSessionID: nil, watchWorkoutBusy: true),
              "After a restart, a Watch session HealthKit reports before any snapshot may be the continued one")
        let ordinary = WorkoutRecordingRecord(owner: .iphone, sessionID: UUID(), requestedAt: date)
        check(!WorkoutRecordingStartPolicy.phoneMayStart(
                ordinary, watchSessionID: watchID, watchWorkoutBusy: true)
                && !WorkoutRecordingStartPolicy.phoneMayStart(
                    ordinary, watchSessionID: nil, watchWorkoutBusy: true),
              "An ordinary iPhone start never runs beside an active Watch workout")
        check(WorkoutRecordingStartPolicy.phoneMayStart(
                ordinary, watchSessionID: nil, watchWorkoutBusy: false),
              "An idle Watch never blocks iPhone")

        var ledger = WorkoutHandoffLedger().inserting(watchID, at: date)
        check(ledger.contains(watchID), "A continued Watch session is remembered")
        check(ledger.inserting(watchID, at: date).entries.count == 1, "Entries are unique")
        for offset in 0..<WorkoutHandoffLedger.capacity {
            ledger = ledger.inserting(UUID(), at: date.addingTimeInterval(Double(offset + 1)))
        }
        check(ledger.entries.count == WorkoutHandoffLedger.capacity && !ledger.contains(watchID),
              "The ledger is bounded, dropping the oldest session")
        let expired = WorkoutHandoffLedger().inserting(watchID, at: date)
            .inserting(UUID(), at: date.addingTimeInterval(WorkoutHandoffLedger.retention + 1))
        check(!expired.contains(watchID) && expired.entries.count == 1,
              "Old handoffs expire")
        check(!WorkoutHandoffLedger().inserting(watchID, at: date).removing(watchID).contains(watchID),
              "A handoff that never started iPhone is forgotten")
        let ledgerURL = url.deletingLastPathComponent().appendingPathComponent("handed-off-watch-v1.json")
        let ledgerStore = WorkoutHandoffLedgerStore(url: ledgerURL)
        check(try ledgerStore.load() == WorkoutHandoffLedger(), "A missing ledger is empty")
        try ledgerStore.save(ledger)
        check(try ledgerStore.load() == ledger, "The ledger survives relaunch")
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw TestError.missingValue }
        return value
    }
    private enum TestError: Error { case missingValue }
}
