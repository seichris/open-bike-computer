import XCTest

@available(iOS 17.0, *)
@MainActor
private final class FakeWorkoutLiveActivityClient:
    WorkoutLiveActivityClient {
    var recordsValue: [WorkoutLiveActivityRecord] = []
    var requestError: Error?
    var updateError: Error?
    private var shouldSuspendNextUpdate = false
    private var suspendedUpdate:
        CheckedContinuation<Void, Never>?
    private var shouldSuspendNextEnd = false
    private var suspendedEnd:
        CheckedContinuation<Void, Never>?
    private(set) var requestAttempts = 0
    private(set) var requests:
        [(WorkoutLiveActivityRecord, Date?)] = []
    private(set) var updates:
        [(String, WorkoutLiveActivityAttributes.ContentState, Date?)] = []
    private(set) var updateAttempts:
        [(String, WorkoutLiveActivityAttributes.ContentState, Date?)] = []
    private(set) var endings:
        [(
            String,
            WorkoutLiveActivityAttributes.ContentState?,
            WorkoutLiveActivityDismissal
        )] = []
    private(set) var endAttempts: [String] = []
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
        updateAttempts.append((id, contentState, staleDate))
        if shouldSuspendNextUpdate {
            shouldSuspendNextUpdate = false
            await withCheckedContinuation { continuation in
                suspendedUpdate = continuation
            }
        }
        if let updateError {
            throw updateError
        }
        updates.append((id, contentState, staleDate))
    }

    func suspendNextUpdate() {
        shouldSuspendNextUpdate = true
    }

    func resumeSuspendedUpdate() {
        suspendedUpdate?.resume()
        suspendedUpdate = nil
    }

    func end(
        id: String,
        contentState: WorkoutLiveActivityAttributes.ContentState?,
        dismissal: WorkoutLiveActivityDismissal
    ) async {
        endAttempts.append(id)
        if shouldSuspendNextEnd {
            shouldSuspendNextEnd = false
            await withCheckedContinuation { continuation in
                suspendedEnd = continuation
            }
        }
        endings.append((id, contentState, dismissal))
        if let index = recordsValue.firstIndex(where: { $0.id == id }) {
            let record = recordsValue[index]
            recordsValue[index] = WorkoutLiveActivityRecord(
                id: record.id,
                attributes: record.attributes,
                contentState: contentState ?? record.contentState,
                systemState: .ended
            )
        }
    }

    func suspendNextEnd() {
        shouldSuspendNextEnd = true
    }

    func resumeSuspendedEnd() {
        suspendedEnd?.resume()
        suspendedEnd = nil
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
private final class FakeWorkoutBackgroundExecutionLease:
    WorkoutBackgroundExecutionLeasing {
    private(set) var isActive = false
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private var expirationHandler:
        (@MainActor @Sendable () -> Void)?

    func begin(
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        guard !isActive else { return }
        isActive = true
        beginCount += 1
        self.expirationHandler = expirationHandler
    }

    func end() {
        guard isActive else { return }
        isActive = false
        endCount += 1
        expirationHandler = nil
    }

    func expireSynchronously() {
        guard isActive else { return }
        let expirationHandler = expirationHandler
        expirationHandler?()
        end()
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

    func testActiveTransportReplacementRetainsExistingActivity() async {
        let sessionID = UUID()
        let running = makeLiveActivityPresentation(
            sessionID: sessionID,
            capturedAt: capturedAt
        )
        let source =
            TestWorkoutLiveActivityPresentationSource(running)
        let client = FakeWorkoutLiveActivityClient()
        let suppression = MemoryWorkoutLiveActivitySuppressionStore()
        let controller = makeController(
            source: source,
            client: client,
            suppression: suppression
        )
        controller.start(isApplicationForeground: true)
        await settle()

        source.send(
            WorkoutMirrorPresentationV1(
                connectionState: .awaitingFirstSnapshot,
                snapshot: running.snapshot,
                sessionID: running.sessionID,
                capturedAt: running.capturedAt,
                receivedAt: running.receivedAt,
                confirmedSessionState: running.confirmedSessionState,
                errorCode: nil,
                pendingControl: nil,
                finalSnapshot: nil,
                navigation: running.navigation
            )
        )
        await settle()

        XCTAssertTrue(client.endings.isEmpty)

        source.send(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                state: .paused,
                capturedAt: capturedAt
            )
        )
        await settle()

        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.updates.last?.1.phase, .paused)
        XCTAssertTrue(suppression.contains(sessionID))
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

    func testMetricRevertCancelsPendingDueState() async {
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
        await settle()
        source.send(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                capturedAt: capturedAt,
                speedMetersPerSecond: 8
            )
        )
        await settle()
        scheduler.resumeNext()
        await settle()

        source.send(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                capturedAt: capturedAt,
                speedMetersPerSecond: 10
            )
        )
        await settle()

        XCTAssertTrue(client.updates.isEmpty)
        XCTAssertEqual(scheduler.requestedIntervals.count, 2)
        scheduler.resumeNext()
        await settle()
        XCTAssertEqual(
            client.updates.last?.1.currentSpeedKilometersPerHour,
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

    func testIntentFlushAwaitsPendingActivityUpdate() async {
        let sessionID = UUID()
        let source = source(sessionID: sessionID)
        let client = FakeWorkoutLiveActivityClient()
        let controller = makeController(source: source, client: client)
        controller.start(isApplicationForeground: true)
        await settle()
        client.suspendNextUpdate()

        source.send(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                capturedAt: capturedAt,
                pendingControl: .pause
            )
        )
        let flushTask = Task {
            await controller.publishCurrentStateForIntent(
                sessionID: sessionID
            )
        }
        await settle()

        XCTAssertEqual(
            client.updateAttempts.map(\.1.pendingAction),
            [.pause]
        )

        client.resumeSuspendedUpdate()
        let published = await flushTask.value
        XCTAssertTrue(published)
        XCTAssertEqual(client.updates.last?.1.pendingAction, .pause)
    }

    func testStateTransitionsPublishInOrderWhenEarlierUpdateSuspends()
        async {
        let sessionID = UUID()
        let source = source(sessionID: sessionID)
        let client = FakeWorkoutLiveActivityClient()
        let controller = makeController(source: source, client: client)
        controller.start(isApplicationForeground: true)
        await settle()
        client.suspendNextUpdate()

        source.send(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                state: .paused,
                capturedAt: capturedAt
            )
        )
        await settle()
        XCTAssertEqual(client.updateAttempts.map(\.1.phase), [.paused])

        source.send(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                state: .running,
                capturedAt: capturedAt
            )
        )
        await settle()
        XCTAssertEqual(client.updateAttempts.map(\.1.phase), [.paused])

        client.resumeSuspendedUpdate()
        await settle()

        XCTAssertEqual(
            client.updateAttempts.map(\.1.phase),
            [.paused, .running]
        )
        XCTAssertEqual(client.updates.map(\.1.phase), [.paused, .running])
    }

    func testSessionRolloverCannotBeClearedBySuspendedPriorEnd() async {
        let firstSessionID = UUID()
        let secondSessionID = UUID()
        let source = source(sessionID: firstSessionID)
        let client = FakeWorkoutLiveActivityClient()
        let suppression = MemoryWorkoutLiveActivitySuppressionStore()
        let controller = makeController(
            source: source,
            client: client,
            suppression: suppression
        )
        controller.start(isApplicationForeground: true)
        await settle()
        client.suspendNextEnd()

        let secondPresentation = makeLiveActivityPresentation(
            sessionID: secondSessionID,
            capturedAt: capturedAt
        )
        source.send(secondPresentation)
        await settle()
        XCTAssertEqual(client.endAttempts, ["activity-1"])
        XCTAssertEqual(client.requests.count, 1)

        source.send(secondPresentation)
        await settle()
        XCTAssertEqual(client.endAttempts, ["activity-1"])

        client.resumeSuspendedEnd()
        await settle()

        XCTAssertEqual(client.endings.map(\.0), ["activity-1"])
        XCTAssertEqual(
            client.requests.map(\.0.attributes.sessionID),
            [firstSessionID, secondSessionID]
        )
        XCTAssertTrue(suppression.contains(secondSessionID))
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

    func testInitialReconciliationRechecksSessionBetweenAwaitedEnds()
        async throws {
        let firstSessionID = UUID()
        let recoveredSessionID = UUID()
        let first = makeLiveActivityPresentation(
            sessionID: firstSessionID,
            capturedAt: capturedAt
        )
        let recovered = makeLiveActivityPresentation(
            sessionID: recoveredSessionID,
            capturedAt: capturedAt
        )
        let unrelated = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                makeLiveActivityPresentation(capturedAt: capturedAt),
                at: capturedAt
            )
        )
        let recoveredMapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                recovered,
                at: capturedAt
            )
        )
        let source =
            TestWorkoutLiveActivityPresentationSource(first)
        let client = FakeWorkoutLiveActivityClient()
        client.recordsValue = [
            record("unrelated", mapped: unrelated),
            record("recovered", mapped: recoveredMapped),
        ]
        client.suspendNextEnd()
        let controller = makeController(source: source, client: client)
        controller.start(isApplicationForeground: false)
        await settle()
        XCTAssertEqual(client.endAttempts, ["unrelated"])

        source.send(recovered)
        client.resumeSuspendedEnd()
        await settle()

        XCTAssertEqual(client.endings.map(\.0), ["unrelated"])
        XCTAssertFalse(client.endAttempts.contains("recovered"))
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testInitialReconciliationRetainsTerminalLeaseDuringDuplicateEnd()
        async throws {
        let sessionID = UUID()
        let active = makeLiveActivityPresentation(
            sessionID: sessionID,
            capturedAt: capturedAt
        )
        let terminal = makeLiveActivityPresentation(
            sessionID: sessionID,
            state: .ended,
            connection: .ended,
            capturedAt: capturedAt,
            terminalOutcome: .saved
        )
        let mapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(active, at: capturedAt)
        )
        let source =
            TestWorkoutLiveActivityPresentationSource(active)
        let client = FakeWorkoutLiveActivityClient()
        client.recordsValue = [
            record("matching", mapped: mapped),
            record("duplicate", mapped: mapped),
        ]
        client.suspendNextEnd()
        let lease = FakeWorkoutBackgroundExecutionLease()
        let controller = makeController(
            source: source,
            client: client,
            finalizationBackgroundLease: lease
        )
        controller.start(isApplicationForeground: false)
        await settle()
        XCTAssertEqual(client.endAttempts, ["duplicate"])

        source.send(terminal)
        XCTAssertTrue(
            lease.isActive,
            "terminal publication must acquire the controller lease synchronously"
        )

        client.resumeSuspendedEnd()
        await settle()

        XCTAssertEqual(client.endings.map(\.0), [
            "duplicate",
            "matching",
        ])
        XCTAssertEqual(client.endings.last?.1?.finalOutcome, .saved)
        XCTAssertFalse(lease.isActive)
        XCTAssertEqual(lease.beginCount, 1)
        XCTAssertEqual(lease.endCount, 1)
    }

    func testInitialReconciliationReleasesRetractedTerminalLease()
        async throws {
        let sessionID = UUID()
        let active = makeLiveActivityPresentation(
            sessionID: sessionID,
            capturedAt: capturedAt
        )
        let terminal = makeLiveActivityPresentation(
            sessionID: sessionID,
            state: .ended,
            connection: .ended,
            capturedAt: capturedAt,
            terminalOutcome: .saved
        )
        let mapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(active, at: capturedAt)
        )
        let source =
            TestWorkoutLiveActivityPresentationSource(active)
        let client = FakeWorkoutLiveActivityClient()
        client.recordsValue = [
            record("matching", mapped: mapped),
            record("duplicate", mapped: mapped),
        ]
        client.suspendNextEnd()
        let lease = FakeWorkoutBackgroundExecutionLease()
        let controller = makeController(
            source: source,
            client: client,
            finalizationBackgroundLease: lease
        )
        controller.start(isApplicationForeground: false)
        await settle()

        source.send(terminal)
        XCTAssertTrue(lease.isActive)
        source.send(active)
        client.resumeSuspendedEnd()
        await settle()

        XCTAssertEqual(client.endings.map(\.0), ["duplicate"])
        XCTAssertFalse(lease.isActive)
        XCTAssertEqual(lease.beginCount, 1)
        XCTAssertEqual(lease.endCount, 1)
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
        let lease = FakeWorkoutBackgroundExecutionLease()
        let controller = makeController(
            source: source,
            client: client,
            finalizationBackgroundLease: lease,
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
        XCTAssertTrue(lease.isActive)

        source.send(active)
        await settle()
        XCTAssertFalse(lease.isActive)
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

    func testReconciliationGraceUsesBackgroundBudgetAndLease()
        async throws {
        let active = makeLiveActivityPresentation(capturedAt: capturedAt)
        let mapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(active, at: capturedAt)
        )
        let source =
            TestWorkoutLiveActivityPresentationSource(.idle)
        let client = FakeWorkoutLiveActivityClient()
        client.recordsValue = [record("orphan", mapped: mapped)]
        let scheduler = WorkoutLiveActivityWaitScheduler()
        let lease = FakeWorkoutBackgroundExecutionLease()
        let controller = makeController(
            source: source,
            client: client,
            finalizationBackgroundLease: lease,
            backgroundTimeRemaining: { 8 },
            wait: { interval in
                try await scheduler.wait(interval)
            }
        )
        controller.start(isApplicationForeground: false)
        await settle()

        XCTAssertTrue(lease.isActive)
        XCTAssertEqual(scheduler.requestedIntervals, [3])

        scheduler.resumeNext()
        await settle()

        XCTAssertFalse(lease.isActive)
        XCTAssertEqual(client.endings.map(\.0), ["orphan"])
    }

    func testReconciliationExpirationSchedulesCleanupForNextExecutionTurn()
        async throws {
        let mapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                makeLiveActivityPresentation(capturedAt: capturedAt),
                at: capturedAt
            )
        )
        let source =
            TestWorkoutLiveActivityPresentationSource(.idle)
        let client = FakeWorkoutLiveActivityClient()
        client.recordsValue = [record("orphan", mapped: mapped)]
        let scheduler = WorkoutLiveActivityWaitScheduler()
        let lease = FakeWorkoutBackgroundExecutionLease()
        let controller = makeController(
            source: source,
            client: client,
            finalizationBackgroundLease: lease,
            wait: { interval in
                try await scheduler.wait(interval)
            }
        )
        controller.start(isApplicationForeground: false)
        await settle()
        XCTAssertTrue(lease.isActive)

        lease.expireSynchronously()
        XCTAssertFalse(lease.isActive)
        XCTAssertTrue(client.endAttempts.isEmpty)
        await settle()

        XCTAssertEqual(client.endings.map(\.0), ["orphan"])
    }

    func testReconciliationGraceFinalizesRecoveredEndingActivity()
        async throws {
        let sessionID = UUID()
        let ending = makeLiveActivityPresentation(
            sessionID: sessionID,
            state: .ended,
            connection: .ended,
            capturedAt: capturedAt
        )
        let mapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(ending, at: capturedAt)
        )
        XCTAssertEqual(mapped.contentState.phase, .ending)
        let source =
            TestWorkoutLiveActivityPresentationSource(.idle)
        let client = FakeWorkoutLiveActivityClient()
        client.recordsValue = [record("ending", mapped: mapped)]
        let suppression = MemoryWorkoutLiveActivitySuppressionStore()
        let scheduler = WorkoutLiveActivityWaitScheduler()
        let lease = FakeWorkoutBackgroundExecutionLease()
        let controller = makeController(
            source: source,
            client: client,
            suppression: suppression,
            finalizationBackgroundLease: lease,
            wait: { interval in
                try await scheduler.wait(interval)
            }
        )
        controller.start(isApplicationForeground: false)
        await settle()
        XCTAssertTrue(lease.isActive)

        scheduler.resumeNext()
        await settle()

        XCTAssertEqual(client.endings.count, 1)
        XCTAssertEqual(client.endings.first?.1?.phase, .final)
        XCTAssertEqual(
            client.endings.first?.1?.displayError,
            .finalSummaryUnavailable
        )
        XCTAssertEqual(
            client.endings.first?.2,
            .after(
                capturedAt.addingTimeInterval(
                    WorkoutLiveActivityController
                        .finalSummaryDismissalInterval
                )
            )
        )
        XCTAssertTrue(suppression.contains(sessionID))
        XCTAssertFalse(lease.isActive)
    }

    func testRecoveredEndingCutoffPreventsSecondSameSessionActivity()
        async throws {
        let sessionID = UUID()
        let ending = makeLiveActivityPresentation(
            sessionID: sessionID,
            state: .ended,
            connection: .ended,
            capturedAt: capturedAt
        )
        let mapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(ending, at: capturedAt)
        )
        let source =
            TestWorkoutLiveActivityPresentationSource(.idle)
        let client = FakeWorkoutLiveActivityClient()
        client.recordsValue = [record("ending", mapped: mapped)]
        client.suspendNextEnd()
        let suppression = MemoryWorkoutLiveActivitySuppressionStore()
        let scheduler = WorkoutLiveActivityWaitScheduler()
        let controller = makeController(
            source: source,
            client: client,
            suppression: suppression,
            wait: { interval in
                try await scheduler.wait(interval)
            }
        )
        controller.start(isApplicationForeground: true)
        await settle()

        scheduler.resumeNext()
        await settle()
        XCTAssertEqual(client.endAttempts, ["ending"])

        source.send(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                capturedAt: capturedAt
            )
        )
        await settle()
        XCTAssertTrue(client.requests.isEmpty)

        client.resumeSuspendedEnd()
        await settle()

        XCTAssertEqual(client.endings.count, 1)
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertTrue(suppression.contains(sessionID))
    }

    func testTerminalRecoveryQueuedBeforeRelaunchCutoffWins()
        async throws {
        let sessionID = UUID()
        let ending = makeLiveActivityPresentation(
            sessionID: sessionID,
            state: .ended,
            connection: .ended,
            capturedAt: capturedAt
        )
        let mapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(ending, at: capturedAt)
        )
        let source =
            TestWorkoutLiveActivityPresentationSource(.idle)
        let client = FakeWorkoutLiveActivityClient()
        client.recordsValue = [record("ending", mapped: mapped)]
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

        scheduler.resumeNext()
        source.send(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                state: .ended,
                connection: .ended,
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

    func testGraceCleanupRechecksTruthBetweenAwaitedEnds()
        async throws {
        let recoveredSessionID = UUID()
        let unrelatedMapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                makeLiveActivityPresentation(capturedAt: capturedAt),
                at: capturedAt
            )
        )
        let ending = makeLiveActivityPresentation(
            sessionID: recoveredSessionID,
            state: .ended,
            connection: .ended,
            capturedAt: capturedAt
        )
        let endingMapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(
                ending,
                at: capturedAt
            )
        )
        let source =
            TestWorkoutLiveActivityPresentationSource(.idle)
        let client = FakeWorkoutLiveActivityClient()
        client.recordsValue = [
            record("unrelated", mapped: unrelatedMapped),
            record("recovered", mapped: endingMapped),
        ]
        client.suspendNextEnd()
        let scheduler = WorkoutLiveActivityWaitScheduler()
        let lease = FakeWorkoutBackgroundExecutionLease()
        let controller = makeController(
            source: source,
            client: client,
            finalizationBackgroundLease: lease,
            wait: { interval in
                try await scheduler.wait(interval)
            }
        )
        controller.start(isApplicationForeground: true)
        await settle()

        scheduler.resumeNext()
        await settle()
        XCTAssertEqual(client.endAttempts, ["unrelated"])
        XCTAssertTrue(
            lease.isActive,
            "the grace lease must span the entire reconciliation batch"
        )

        source.send(
            makeLiveActivityPresentation(
                sessionID: recoveredSessionID,
                state: .ended,
                connection: .ended,
                capturedAt: capturedAt,
                terminalOutcome: .saved
            )
        )
        client.resumeSuspendedEnd()
        await settle()

        XCTAssertEqual(client.endings.map(\.0), [
            "unrelated",
            "recovered",
        ])
        XCTAssertNil(client.endings.first?.1)
        XCTAssertEqual(
            client.endings.last?.1?.finalOutcome,
            .saved
        )
        XCTAssertFalse(lease.isActive)
    }

    func testReconciliationGraceSerializesRecoveryWithOrphanCleanup()
        async throws {
        let sessionID = UUID()
        let active = makeLiveActivityPresentation(
            sessionID: sessionID,
            capturedAt: capturedAt
        )
        let mapped = try XCTUnwrap(
            WorkoutLiveActivityStateMapper.map(active, at: capturedAt)
        )
        let source =
            TestWorkoutLiveActivityPresentationSource(.idle)
        let client = FakeWorkoutLiveActivityClient()
        client.recordsValue = [record("existing", mapped: mapped)]
        client.suspendNextEnd()
        let suppression = MemoryWorkoutLiveActivitySuppressionStore()
        suppression.insert(sessionID)
        let scheduler = WorkoutLiveActivityWaitScheduler()
        let controller = makeController(
            source: source,
            client: client,
            suppression: suppression,
            wait: { interval in
                try await scheduler.wait(interval)
            }
        )
        controller.start(isApplicationForeground: true)
        await settle()

        scheduler.resumeNext()
        await settle()
        XCTAssertEqual(client.endAttempts, ["existing"])

        source.send(active)
        await settle()
        XCTAssertTrue(
            client.requests.isEmpty,
            "recovery must not create while the old Activity is still ending"
        )

        client.resumeSuspendedEnd()
        await settle()

        XCTAssertEqual(client.endings.map(\.0), ["existing"])
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(
            client.requests.first?.0.attributes.sessionID,
            sessionID
        )
        XCTAssertTrue(suppression.contains(sessionID))
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

    func testCreatedSessionDoesNotRecreateAfterProcessDeath() async {
        let sessionID = UUID()
        let suppression = MemoryWorkoutLiveActivitySuppressionStore()
        let firstClient = FakeWorkoutLiveActivityClient()
        let firstController = makeController(
            source: source(sessionID: sessionID),
            client: firstClient,
            suppression: suppression
        )
        firstController.start(isApplicationForeground: true)
        await settle()

        XCTAssertEqual(firstClient.requests.count, 1)
        XCTAssertTrue(suppression.contains(sessionID))

        let relaunchedClient = FakeWorkoutLiveActivityClient()
        let relaunchedController = makeController(
            source: source(sessionID: sessionID),
            client: relaunchedClient,
            suppression: suppression
        )
        relaunchedController.start(isApplicationForeground: true)
        await settle()

        XCTAssertTrue(relaunchedClient.requests.isEmpty)
    }

    func testNativeEndWaitsForAuthoritativeSavedFinalSnapshot() async {
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
                connection: .ended,
                capturedAt: capturedAt
            )
        )
        await settle()

        XCTAssertEqual(client.updates.last?.1.phase, .ending)
        XCTAssertTrue(client.endings.isEmpty)

        source.send(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                state: .ended,
                connection: .ended,
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

    func testMissingFinalSnapshotEndsWithHonestUnavailableSummary()
        async {
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
                connection: .ended,
                capturedAt: capturedAt,
                errorCode: .finalSummaryUnavailable
            )
        )
        await settle()

        XCTAssertEqual(client.endings.count, 1)
        XCTAssertEqual(client.endings.first?.1?.phase, .final)
        XCTAssertEqual(
            client.endings.first?.1?.displayError,
            .finalSummaryUnavailable
        )
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

    func testFinalizationBackgroundLeaseSpansActivityEndCompletion()
        async {
        let sessionID = UUID()
        let source = source(sessionID: sessionID)
        let client = FakeWorkoutLiveActivityClient()
        let lease = FakeWorkoutBackgroundExecutionLease()
        let controller = makeController(
            source: source,
            client: client,
            finalizationBackgroundLease: lease
        )
        controller.start(isApplicationForeground: true)
        await settle()
        client.suspendNextEnd()

        source.send(
            makeLiveActivityPresentation(
                sessionID: sessionID,
                state: .ended,
                connection: .ended,
                capturedAt: capturedAt,
                errorCode: .finalSummaryUnavailable
            )
        )
        XCTAssertTrue(
            lease.isActive,
            "publisher delivery must acquire the controller lease synchronously"
        )
        await settle()

        XCTAssertEqual(client.endAttempts, ["activity-1"])
        XCTAssertTrue(lease.isActive)

        client.resumeSuspendedEnd()
        await settle()

        XCTAssertFalse(lease.isActive)
        XCTAssertEqual(lease.beginCount, 1)
        XCTAssertEqual(lease.endCount, 1)
    }

    func testUnconfirmedTerminalChoiceWaitsForFinalCutoff() async {
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
                connection: .ended,
                capturedAt: capturedAt,
                errorCode: .terminalChoiceUnconfirmed
            )
        )
        await settle()

        XCTAssertTrue(client.endings.isEmpty)
        XCTAssertEqual(client.updates.last?.1.phase, .ending)
        XCTAssertEqual(
            client.updates.last?.1.displayError,
            .controlsUnavailable
        )
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
        let diagnostics = WorkoutLiveActivityDiagnosticStore()
        client.requestError = TestError.unavailable
        let controller = makeController(
            source: source,
            client: client,
            diagnostics: diagnostics
        )
        controller.start(isApplicationForeground: true)
        await settle()

        XCTAssertEqual(client.requestAttempts, 1)
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertTrue(
            diagnostics.issueMessage?.contains(
                "Live Activity failed:"
            ) == true
        )

        client.requestError = nil
        controller.setApplicationForeground(true)
        await settle()
        XCTAssertEqual(client.requestAttempts, 2)
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertNil(diagnostics.issueMessage)
    }

    func testDisabledAuthorizationDoesNotRequestActivity() async {
        let source = source()
        let client = FakeWorkoutLiveActivityClient()
        let diagnostics = WorkoutLiveActivityDiagnosticStore()
        let controller = makeController(
            source: source,
            client: client,
            authorization: EnabledWorkoutLiveActivityAuthorization(false),
            diagnostics: diagnostics
        )

        controller.start(isApplicationForeground: true)
        await settle()

        XCTAssertEqual(client.requestAttempts, 0)
        XCTAssertEqual(
            diagnostics.issueMessage,
            "Live Activity unavailable: iOS reports that Live Activities "
                + "are disabled for BikeComputer."
        )
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
        diagnostics:
            (any WorkoutLiveActivityDiagnosticReporting)? = nil,
        finalizationBackgroundLease:
            (any WorkoutBackgroundExecutionLeasing)? = nil,
        backgroundTimeRemaining: (() -> TimeInterval)? = nil,
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
            diagnostics: diagnostics,
            finalizationBackgroundLease:
                finalizationBackgroundLease,
            backgroundTimeRemaining:
                backgroundTimeRemaining
                ?? { .greatestFiniteMagnitude },
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
