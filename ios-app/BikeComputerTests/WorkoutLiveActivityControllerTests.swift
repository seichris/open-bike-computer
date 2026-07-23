import XCTest

@available(iOS 17.0, *)
@MainActor
private final class FakeWorkoutLiveActivityClient:
    WorkoutLiveActivityClient {
    var recordsValue: [WorkoutLiveActivityRecord] = []
    var requestError: Error?
    var updateError: Error?
    private(set) var requestAttempts = 0
    private(set) var requests:
        [(WorkoutLiveActivityRecord, Date?)] = []
    private(set) var updates:
        [(String, WorkoutLiveActivityAttributes.ContentState, Date?)] = []
    private(set) var endings:
        [(
            String,
            WorkoutLiveActivityAttributes.ContentState?,
            WorkoutLiveActivityDismissal
        )] = []
    private var continuations:
        [String: AsyncStream<WorkoutLiveActivitySystemState>.Continuation] = [:]

    func records() -> [WorkoutLiveActivityRecord] {
        recordsValue
    }

    func request(
        attributes: WorkoutLiveActivityAttributes,
        contentState: WorkoutLiveActivityAttributes.ContentState,
        staleDate: Date?
    ) throws -> WorkoutLiveActivityRecord {
        requestAttempts += 1
        if let requestError {
            throw requestError
        }
        let record = WorkoutLiveActivityRecord(
            id: "activity-\(requests.count + 1)",
            attributes: attributes,
            contentState: contentState,
            systemState: .active
        )
        requests.append((record, staleDate))
        recordsValue.append(record)
        return record
    }

    func update(
        id: String,
        contentState: WorkoutLiveActivityAttributes.ContentState,
        staleDate: Date?
    ) async throws {
        if let updateError {
            throw updateError
        }
        updates.append((id, contentState, staleDate))
    }

    func end(
        id: String,
        contentState: WorkoutLiveActivityAttributes.ContentState?,
        dismissal: WorkoutLiveActivityDismissal
    ) async {
        endings.append((id, contentState, dismissal))
    }

    func stateUpdates(
        for id: String
    ) -> AsyncStream<WorkoutLiveActivitySystemState> {
        AsyncStream { continuation in
            continuations[id] = continuation
        }
    }

    func yield(
        _ state: WorkoutLiveActivitySystemState,
        for id: String
    ) {
        continuations[id]?.yield(state)
    }
}

@available(iOS 17.0, *)
private struct EnabledWorkoutLiveActivityAuthorization:
    WorkoutLiveActivityAuthorizationProviding {
    let areActivitiesEnabled: Bool

    init(_ enabled: Bool = true) {
        areActivitiesEnabled = enabled
    }
}

@available(iOS 17.0, *)
@MainActor
private final class MemoryWorkoutLiveActivitySuppressionStore:
    WorkoutLiveActivitySuppressionStoring {
    private(set) var identifiers: Set<UUID> = []

    func contains(_ sessionID: UUID) -> Bool {
        identifiers.contains(sessionID)
    }

    func insert(_ sessionID: UUID) {
        identifiers.insert(sessionID)
    }

    func remove(_ sessionID: UUID) {
        identifiers.remove(sessionID)
    }
}

@available(iOS 17.0, *)
@MainActor
private final class WorkoutLiveActivityWaitScheduler {
    private(set) var requestedIntervals: [TimeInterval] = []
    private var continuations: [CheckedContinuation<Void, Error>] = []

    func wait(_ interval: TimeInterval) async throws {
        requestedIntervals.append(interval)
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

@available(iOS 17.0, *)
@MainActor
final class WorkoutLiveActivityControllerTests: XCTestCase {
    private let capturedAt =
        Date(timeIntervalSinceReferenceDate: 800_500_000)

    func testForegroundVerifiedWorkoutRequestsOnlyOneActivity() async {
        let sessionID = UUID()
        let source = source(sessionID: sessionID)
        let client = FakeWorkoutLiveActivityClient()
        let controller = makeController(source: source, client: client)

        controller.start(isApplicationForeground: true)
        await settle()
        controller.setApplicationForeground(true)
        await settle()

        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(
            client.requests.first?.0.attributes.sessionID,
            sessionID
        )
        XCTAssertEqual(
            client.requests.first?.1,
            capturedAt.addingTimeInterval(
                WorkoutMirrorStateReducer.defaultStaleAfter
            )
        )
    }

    func testBackgroundWorkoutDefersStartUntilForeground() async {
        let source = source()
        let client = FakeWorkoutLiveActivityClient()
        let controller = makeController(source: source, client: client)

        controller.start(isApplicationForeground: false)
        await settle()
        XCTAssertTrue(client.requests.isEmpty)

        controller.setApplicationForeground(true)
        await settle()
        XCTAssertEqual(client.requests.count, 1)
    }

    func testBackgroundStateStillUpdatesExistingActivity() async {
        let sessionID = UUID()
        let source = source(sessionID: sessionID)
        let client = FakeWorkoutLiveActivityClient()
        let controller = makeController(source: source, client: client)
        controller.start(isApplicationForeground: true)
        await settle()

        controller.setApplicationForeground(false)
        source.send(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                state: .paused,
                capturedAt: capturedAt
            )
        )
        await settle()

        XCTAssertEqual(client.updates.count, 1)
        XCTAssertEqual(client.updates.first?.1.phase, .paused)
    }

    func testEquivalentPresentationDoesNotUpdate() async {
        let presentation = makeLiveActivityPresentation(
            capturedAt: capturedAt
        )
        let source =
            TestWorkoutLiveActivityPresentationSource(presentation)
        let client = FakeWorkoutLiveActivityClient()
        let controller = makeController(source: source, client: client)
        controller.start(isApplicationForeground: true)
        await settle()

        source.send(presentation)
        await settle()

        XCTAssertTrue(client.updates.isEmpty)
    }

    func testMetricBurstCoalescesLatestWins() async {
        let sessionID = UUID()
        let source = source(sessionID: sessionID)
        let client = FakeWorkoutLiveActivityClient()
        let scheduler = WorkoutLiveActivityWaitScheduler()
        let controller = makeController(
            source: source,
            client: client,
            wait: { interval in
                try await scheduler.wait(interval)
            }
        )
        controller.start(isApplicationForeground: true)
        await settle()

        source.send(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                capturedAt: capturedAt,
                speedMetersPerSecond: 9
            )
        )
        source.send(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                capturedAt: capturedAt,
                speedMetersPerSecond: 10
            )
        )
        await settle()

        XCTAssertTrue(client.updates.isEmpty)
        XCTAssertEqual(scheduler.requestedIntervals.count, 1)
        scheduler.resumeNext()
        await settle()

        XCTAssertEqual(client.updates.count, 1)
        XCTAssertEqual(
            client.updates.first?.1.currentSpeedKilometersPerHour,
            36
        )
    }

    func testStateTransitionBypassesMetricCoalescing() async {
        let sessionID = UUID()
        let source = source(sessionID: sessionID)
        let client = FakeWorkoutLiveActivityClient()
        let scheduler = WorkoutLiveActivityWaitScheduler()
        let controller = makeController(
            source: source,
            client: client,
            wait: { interval in
                try await scheduler.wait(interval)
            }
        )
        controller.start(isApplicationForeground: true)
        await settle()

        source.send(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                state: .paused,
                capturedAt: capturedAt
            )
        )
        await settle()

        XCTAssertEqual(client.updates.count, 1)
        XCTAssertEqual(client.updates.first?.1.phase, .paused)
        XCTAssertTrue(scheduler.requestedIntervals.isEmpty)
    }

    func testSegmentAcknowledgementBypassesMetricCoalescing() async {
        let sessionID = UUID()
        let source = source(sessionID: sessionID)
        let client = FakeWorkoutLiveActivityClient()
        let scheduler = WorkoutLiveActivityWaitScheduler()
        let controller = makeController(
            source: source,
            client: client,
            wait: { interval in
                try await scheduler.wait(interval)
            }
        )
        controller.start(isApplicationForeground: true)
        await settle()
        let segment = WorkoutCompletedSegmentV1(
            index: 1,
            startedAt: capturedAt.addingTimeInterval(-60),
            endedAt: capturedAt,
            duration: 60,
            distanceMeters: 500
        )

        source.send(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                capturedAt: capturedAt,
                segment: segment
            )
        )
        await settle()

        XCTAssertEqual(client.updates.count, 1)
        XCTAssertEqual(
            client.updates.first?.1.lastCompletedSegmentIndex,
            1
        )
        XCTAssertTrue(scheduler.requestedIntervals.isEmpty)
    }

    func testReconciliationRetainsMatchAndEndsDuplicatesAndOrphan()
        async throws {
        let sessionID = UUID()
        let otherSessionID = UUID()
        let presentation = makeLiveActivityPresentation(
            sessionID: sessionID,
            capturedAt: capturedAt
        )
        let content = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                presentation,
                at: capturedAt
            )
        )
        let client = FakeWorkoutLiveActivityClient()
        client.recordsValue = [
            record("matching", mapped: content),
            record("duplicate", mapped: content),
            record(
                "orphan",
                mapped: try XCTUnwrap(
                    WorkoutLiveActivityStateMapper.map(
                        makeLiveActivityPresentation(
                            sessionID: otherSessionID,
                            capturedAt: capturedAt
                        ),
                        at: capturedAt
                    )
                )
            ),
        ]
        let source =
            TestWorkoutLiveActivityPresentationSource(presentation)
        let controller = makeController(source: source, client: client)

        controller.start(isApplicationForeground: true)
        await settle()

        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertEqual(Set(client.endings.map(\.0)), ["duplicate", "orphan"])
    }

    func testReconciliationGraceRetainsColdLaunchActivityUntilRecovery()
        async throws {
        let sessionID = UUID()
        let active = makeLiveActivityPresentation(
            sessionID: sessionID,
            capturedAt: capturedAt
        )
        let mapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(active, at: capturedAt)
        )
        let otherMapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                makeLiveActivityPresentation(
                    capturedAt: capturedAt
                ),
                at: capturedAt
            )
        )
        let source =
            TestWorkoutLiveActivityPresentationSource(.idle)
        let client = FakeWorkoutLiveActivityClient()
        client.recordsValue = [
            record("other", mapped: otherMapped),
            record("existing", mapped: mapped),
        ]
        let scheduler = WorkoutLiveActivityWaitScheduler()
        let controller = makeController(
            source: source,
            client: client,
            wait: { interval in
                try await scheduler.wait(interval)
            }
        )
        controller.start(isApplicationForeground: false)
        await settle()

        XCTAssertTrue(client.endings.isEmpty)
        XCTAssertEqual(scheduler.requestedIntervals, [
            WorkoutLiveActivityController.reconciliationGracePeriod,
        ])

        source.send(active)
        await settle()
        scheduler.resumeNext()
        await settle()

        XCTAssertEqual(client.endings.map(\.0), ["other"])
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testReconciliationGraceEndsOrphanAfterTimeout() async throws {
        let active = makeLiveActivityPresentation(
            capturedAt: capturedAt
        )
        let mapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(active, at: capturedAt)
        )
        let source =
            TestWorkoutLiveActivityPresentationSource(.idle)
        let client = FakeWorkoutLiveActivityClient()
        client.recordsValue = [record("orphan", mapped: mapped)]
        let scheduler = WorkoutLiveActivityWaitScheduler()
        let controller = makeController(
            source: source,
            client: client,
            wait: { interval in
                try await scheduler.wait(interval)
            }
        )
        controller.start(isApplicationForeground: false)
        await settle()

        scheduler.resumeNext()
        await settle()

        XCTAssertEqual(client.endings.count, 1)
        XCTAssertEqual(client.endings.first?.0, "orphan")
        XCTAssertEqual(client.endings.first?.2, .immediate)
    }

    func testDismissalSuppressesRecreationForSameSession() async throws {
        let sessionID = UUID()
        let source = source(sessionID: sessionID)
        let client = FakeWorkoutLiveActivityClient()
        let suppression = MemoryWorkoutLiveActivitySuppressionStore()
        let controller = makeController(
            source: source,
            client: client,
            suppression: suppression
        )
        controller.start(isApplicationForeground: true)
        await settle()
        let activityID = try XCTUnwrap(client.requests.first?.0.id)

        client.yield(.dismissed, for: activityID)
        await settle()
        controller.setApplicationForeground(true)
        await settle()

        XCTAssertTrue(suppression.contains(sessionID))
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertTrue(client.endings.isEmpty)
    }

    func testSystemExpirationDoesNotRecreateSameSession() async throws {
        let sessionID = UUID()
        let source = source(sessionID: sessionID)
        let client = FakeWorkoutLiveActivityClient()
        let controller = makeController(source: source, client: client)
        controller.start(isApplicationForeground: true)
        await settle()
        let activityID = try XCTUnwrap(client.requests.first?.0.id)

        client.yield(.ended, for: activityID)
        await settle()
        controller.setApplicationForeground(true)
        await settle()

        XCTAssertEqual(client.requests.count, 1)
        XCTAssertTrue(client.endings.isEmpty)
    }

    func testSavedFinalSummaryEndsAfterFifteenMinutes() async {
        let sessionID = UUID()
        let source = source(sessionID: sessionID)
        let client = FakeWorkoutLiveActivityClient()
        let controller = makeController(source: source, client: client)
        controller.start(isApplicationForeground: true)
        await settle()

        source.send(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                state: .ended,
                capturedAt: capturedAt,
                terminalOutcome: .saved
            )
        )
        await settle()

        XCTAssertEqual(client.endings.count, 1)
        XCTAssertEqual(client.endings.first?.1?.finalOutcome, .saved)
        XCTAssertEqual(
            client.endings.first?.2,
            .after(
                capturedAt.addingTimeInterval(
                    WorkoutLiveActivityController
                        .finalSummaryDismissalInterval
                )
            )
        )
    }

    func testDiscardedFinalSummaryEndsImmediately() async {
        let sessionID = UUID()
        let source = source(sessionID: sessionID)
        let client = FakeWorkoutLiveActivityClient()
        let controller = makeController(source: source, client: client)
        controller.start(isApplicationForeground: true)
        await settle()

        source.send(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                state: .ended,
                capturedAt: capturedAt,
                terminalOutcome: .discarded
            )
        )
        await settle()

        XCTAssertEqual(client.endings.count, 1)
        XCTAssertEqual(client.endings.first?.2, .immediate)
    }

    func testActivityKitRequestFailureIsContainedAndRetryable() async {
        enum TestError: Error { case unavailable }
        let source = source()
        let client = FakeWorkoutLiveActivityClient()
        client.requestError = TestError.unavailable
        let controller = makeController(source: source, client: client)
        controller.start(isApplicationForeground: true)
        await settle()

        XCTAssertEqual(client.requestAttempts, 1)
        XCTAssertTrue(client.requests.isEmpty)

        client.requestError = nil
        controller.setApplicationForeground(true)
        await settle()
        XCTAssertEqual(client.requestAttempts, 2)
        XCTAssertEqual(client.requests.count, 1)
    }

    func testDisabledAuthorizationDoesNotRequestActivity() async {
        let source = source()
        let client = FakeWorkoutLiveActivityClient()
        let controller = makeController(
            source: source,
            client: client,
            authorization: EnabledWorkoutLiveActivityAuthorization(false)
        )

        controller.start(isApplicationForeground: true)
        await settle()

        XCTAssertEqual(client.requestAttempts, 0)
    }

    private func source(
        sessionID: UUID = UUID()
    ) -> TestWorkoutLiveActivityPresentationSource {
        TestWorkoutLiveActivityPresentationSource(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                capturedAt: capturedAt
            )
        )
    }

    private func makeController(
        source: TestWorkoutLiveActivityPresentationSource,
        client: FakeWorkoutLiveActivityClient,
        authorization:
            WorkoutLiveActivityAuthorizationProviding? = nil,
        suppression:
            WorkoutLiveActivitySuppressionStoring? = nil,
        wait:
            (@MainActor @Sendable (TimeInterval) async throws -> Void)? = nil
    ) -> WorkoutLiveActivityController {
        let referenceDate = capturedAt
        return WorkoutLiveActivityController(
            presentationSource: source,
            client: client,
            authorization: authorization
                ?? EnabledWorkoutLiveActivityAuthorization(),
            suppressionStore: suppression
                ?? MemoryWorkoutLiveActivitySuppressionStore(),
            now: { referenceDate },
            wait: wait
        )
    }

    private func record(
        _ id: String,
        mapped: WorkoutLiveActivityMappedPresentation
    ) -> WorkoutLiveActivityRecord {
        WorkoutLiveActivityRecord(
            id: id,
            attributes: mapped.attributes,
            contentState: mapped.contentState,
            systemState: .active
        )
    }

    private func settle() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }
}
