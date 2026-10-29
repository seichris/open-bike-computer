import Combine
import HealthKit
import XCTest

@MainActor
private final class PhoneRecordingPersistenceProbe: WorkoutRecordingPersisting {
    var record: WorkoutRecordingRecord?
    var failTerminalWrites = false
    func load() throws -> WorkoutRecordingRecord? { record }
    func save(_ record: WorkoutRecordingRecord) throws {
        if failTerminalWrites && record.phase == .finished {
            throw WorkoutRecordingStore.StoreError.invalidRecord
        }
        self.record = record
    }
    func clear(sessionID: UUID) throws { record = nil }
}

@available(iOS 26.0, *)
@MainActor
final class PhoneWorkoutRecorderTests: XCTestCase {
    func testLockedSaveAndTombstoneRetryDoNotSaveAgainOrRequireHealthRead() async throws {
        let persistence = PhoneRecordingPersistenceProbe()
        let healthStore = HKHealthStore()
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .outdoor
        let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        let start = Date().addingTimeInterval(-60)
        var record = WorkoutRecordingRecord(owner: .iphone, sessionID: UUID(), requestedAt: start)
        record.startedAt = start
        record = try XCTUnwrap(record.finishing(.save))
        try persistence.save(record)
        var saveCalls = 0
        var lookups = 0
        let recorder = PhoneWorkoutRecorder(
            persistence: persistence,
            locations: Empty().eraseToAnyPublisher(),
            healthStore: healthStore,
            finishWorkoutCallback: { _, completion in
                saveCalls += 1
                completion(nil, nil) // HealthKit's documented locked-device success.
            },
            savedWorkoutLookup: { _ in
                lookups += 1
                throw HKError(.errorDatabaseInaccessible)
            }
        )
        recorder.configureFinalizationForTesting(session: session, record: record)
        persistence.failTerminalWrites = true
        await recorder.finalizeForTesting()
        XCTAssertEqual(saveCalls, 1)
        XCTAssertEqual(recorder.record?.phase, .finishing)
        XCTAssertEqual(recorder.record?.saveAttempted, true)
        let finalElapsed = recorder.store.presentation.snapshot.elapsedTime
        XCTAssertNotNil(finalElapsed, "The original builder still exposes its final elapsed time")

        persistence.failTerminalWrites = false
        await recorder.finalizeForTesting()
        XCTAssertEqual(saveCalls, 1, "Only retry the failed durable tombstone write")
        XCTAssertEqual(lookups, 0, "Authoritative success must not require Health read access")
        XCTAssertEqual(recorder.record?.finishedChoice, .save)
        XCTAssertEqual(persistence.record?.phase, .finished)
        XCTAssertEqual(recorder.store.presentation.snapshot.terminalOutcome, .saved)
        XCTAssertEqual(recorder.store.presentation.finalSnapshot?.elapsedTime, finalElapsed,
                       "Releasing the builder must not erase the saved terminal statistics")
        recorder.resetFinished()
        XCTAssertNil(recorder.record)
    }

    func testFinishCallbackErrorRemainsUnconfirmed() async throws {
        let persistence = PhoneRecordingPersistenceProbe()
        let healthStore = HKHealthStore()
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .outdoor
        let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        let start = Date().addingTimeInterval(-60)
        var record = WorkoutRecordingRecord(owner: .iphone, sessionID: UUID(), requestedAt: start)
        record.startedAt = start
        record = try XCTUnwrap(record.finishing(.save))
        try persistence.save(record)
        let recorder = PhoneWorkoutRecorder(
            persistence: persistence, locations: Empty().eraseToAnyPublisher(),
            healthStore: healthStore,
            finishWorkoutCallback: { _, completion in
                completion(nil, HKError(.errorDatabaseInaccessible))
            }
        )
        recorder.configureFinalizationForTesting(session: session, record: record)
        await recorder.finalizeForTesting()
        XCTAssertNil(recorder.record?.finishedChoice)
        XCTAssertNil(recorder.store.presentation.snapshot.terminalOutcome)
        XCTAssertEqual(recorder.record?.saveAttempted, true)
    }

    func testRecoveryRetryDrainsOriginalAttachedBuilderAfterWriteFailure() async throws {
        let persistence = PhoneRecordingPersistenceProbe()
        let healthStore = HKHealthStore()
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .outdoor
        let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        let start = Date().addingTimeInterval(-60)
        var record = WorkoutRecordingRecord(owner: .iphone, sessionID: UUID(), requestedAt: start)
        record.startedAt = start
        record.phase = .paused
        record.pendingNativeTransitions = [.init(id: UUID(), paused: true, capturedAt: start.addingTimeInterval(20))]
        try persistence.save(record)
        var writes = 0
        let recorder = PhoneWorkoutRecorder(
            persistence: persistence, locations: Empty().eraseToAnyPublisher(),
            healthStore: healthStore,
            nativeTransitionWrite: { actualBuilder, _ in
                XCTAssertTrue(actualBuilder === builder)
                writes += 1
                if writes <= 2 { throw WorkoutRecordingStore.StoreError.invalidRecord }
            }
        )
        do {
            try await recorder.attachRecoveredPrimarySession(session, builder: builder, record: record)
            XCTFail("The initial native-event write must fail")
        } catch { }
        do {
            try await recorder.recover(expected: record)
            XCTFail("A second failed attachment must not report completed recovery")
        } catch { }
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(recorder.record?.pendingNativeTransitions?.count, 1)
        try await recorder.recover(expected: record)
        XCTAssertEqual(writes, 3)
        XCTAssertNil(recorder.record?.pendingNativeTransitions)
        XCTAssertNil(persistence.record?.pendingNativeTransitions)
        XCTAssertEqual(recorder.record?.sessionID, record.sessionID)
        XCTAssertEqual(recorder.store.presentation.sessionID, record.sessionID)
        XCTAssertEqual(recorder.store.presentation.sessionState, .starting,
                       "The real unstarted fixture becomes visible for explicit resolution")
        try await recorder.recover(expected: record)
        XCTAssertEqual(writes, 3, "A completed attachment is idempotent")
    }
}
