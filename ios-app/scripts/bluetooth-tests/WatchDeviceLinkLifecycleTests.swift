import Foundation
import CoreBluetooth

private final class TestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

actor WatchStopTestClock {
    private var waits: [(UUID, CheckedContinuation<Void, Error>, TestCancellation)] = []

    func sleep() async throws {
        let id = UUID()
        let cancellation = TestCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waits.append((id, continuation, cancellation))
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waits.firstIndex(where: { $0.0 == id }) else { return }
        waits.remove(at: index).1.resume(throwing: CancellationError())
    }

    func fireNext() async {
        for _ in 0..<10_000 {
            if !waits.isEmpty {
                let (_, continuation, cancellation) = waits.removeFirst()
                if cancellation.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    continue
                }
                continuation.resume()
                return
            }
            await Task.yield()
        }
        fatalError("The production stop timer was not armed")
    }
}

@MainActor
private final class Fixture {
    struct Preparation {
        let operation: WatchDirectRidePreparationOperationV1
        let deviceID: String
        let preparationID: UUID
        let persistedBeforeSubmission: Bool
    }

    let deviceID = String(repeating: "a", count: 32)
    let preparationID = UUID()
    let peripheral = CBPeripheral()
    let defaults: UserDefaults
    let suiteName = "WatchDeviceLinkLifecycleTests.\(UUID().uuidString)"
    let clock = WatchStopTestClock()
    let link: WatchDeviceLink
    var preparations: [Preparation] = []
    var disposition: WatchDirectRidePreparationSubmissionDispositionV1 = .activationPending

    init(navigation: Bool = true, workout: Bool = false) throws {
        defaults = UserDefaults(suiteName: suiteName)!
        let credential = try WatchControllerCredentialV1(
            deviceID: deviceID,
            controllerID: Data(repeating: 1, count: 16),
            key: Data(repeating: 2, count: 32)
        )
        let clock = self.clock
        link = WatchDeviceLink(
            credentialStore: WatchControllerCredentialStore(credentials: [credential]),
            defaults: defaults,
            stopDelay: { try await clock.sleep() }
        )
        try link.testSeedReady(
            peripheral: peripheral,
            credential: credential,
            preparationID: preparationID,
            navigation: navigation,
            workout: workout
        )
        link.onDirectRidePreparationChange = { [weak self] operation, deviceID, id in
            guard let self else { return .transportUnavailable }
            let intent = self.intent
            self.preparations.append(Preparation(
                operation: operation, deviceID: deviceID, preparationID: id,
                persistedBeforeSubmission: intent?.operation == operation &&
                    intent?.preparationID == id && intent?.deviceID == deviceID
            ))
            return self.disposition
        }
    }

    var central: CBCentralManager { CBCentralManager.latest! }
    var intent: WatchDirectRidePreparationIntentV1? {
        defaults.data(forKey: "watchDeviceLink.directRidePreparationIntent.v1")
            .flatMap { try? WatchDirectRidePreparationIntentV1.decode($0) }
    }

    func stop() { link.setDemand(navigation: false, workout: false) }
    func disconnect() {
        link.centralManager(
            central, didDisconnectPeripheral: peripheral,
            timestamp: 0, isReconnecting: false, error: nil
        )
    }
    func radio(_ poweredOn: Bool) {
        central.state = poweredOn ? .poweredOn : .poweredOff
        link.centralManagerDidUpdateState(central)
    }
    func dispose() {
        link.testDispose()
        defaults.removePersistentDomain(forName: suiteName)
        CBCentralManager.knownPeripherals = []
    }
}

@main
@MainActor
struct WatchDeviceLinkLifecycleTests {
    static var failures: [String] = []
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() {
            failures.append(message)
            print("FAIL: \(message)")
        }
    }

    static func flushActor() async {
        for _ in 0..<20 { await Task.yield() }
    }

    static func main() async throws {
        try await stopCompletionsReleasePreparation()
        try await successorDemandRestarts()
        try lateCallbacksDoNotRestoreReadiness()
        try activeDisconnectRetainsPreparation()
        try await missingDisconnectIsActionable()
        try successorSnapshotsAndStalePreparationReplies()
        try pendingReleaseSurvivesRelaunch()
        try criticalClearsWaitForApplicationAcceptance()
        try readyRefreshAndLateDiscoveryAreIdempotent()
        try repeatedDemandDuringStop()
        print("WatchDeviceLink lifecycle: \(assertions) assertions, \(failures.count) failures")
        if !failures.isEmpty { exit(1) }
    }

    static func stopCompletionsReleasePreparation() async throws {
        for completion in ["ack", "timeout", "disconnect", "radio"] {
            let fixture = try Fixture()
            defer { fixture.dispose() }
            fixture.stop()
            switch completion {
            case "ack": fixture.link.testLeaseReleased()
            case "timeout":
                await fixture.clock.fireNext()
                await flushActor()
            case "disconnect": fixture.disconnect()
            default: fixture.radio(false)
            }
            expect(fixture.intent?.operation == .release,
                   "R1 \(completion): durable release, not orphaned prepare")
            expect(fixture.intent?.preparationID == fixture.preparationID,
                   "R1 \(completion): matching preparation identity")
            expect(fixture.preparations.contains { $0.operation == .release },
                   "R1 \(completion): release submitted to handoff boundary")
            expect(fixture.preparations.allSatisfy(\.persistedBeforeSubmission),
                   "R1 \(completion): persist intent before calling transport")
            fixture.disconnect()
            fixture.link.testLeaseReleased()
            expect(!fixture.link.testHasDemand,
                   "R1 \(completion): duplicate completion does not create demand")
        }
    }

    static func successorDemandRestarts() async throws {
        for completion in ["ack", "timeout", "disconnect", "radio"] {
            for (navigation, workout) in [(true, false), (false, true), (true, true)] {
                let fixture = try Fixture()
                defer { fixture.dispose() }
                fixture.disposition = .submitted
                fixture.stop()
                fixture.link.setDemand(navigation: navigation, workout: workout)
                fixture.link.directRidePreparationAvailabilityDidChange()
                expect(fixture.link.testHasDemand,
                       "R2 \(completion): retain successor demand")
                expect(!fixture.link.state.isReady,
                       "R2 \(completion): readiness revoked while stopping")
                expect(fixture.link.testPreparationID == fixture.preparationID,
                       "R2 \(completion): do not replace stopping preparation early")
                switch completion {
                case "ack": fixture.link.testLeaseReleased()
                case "timeout":
                    await fixture.clock.fireNext()
                    await flushActor()
                case "disconnect": fixture.disconnect()
                default: fixture.radio(false)
                }
                // Complete the old cancellation before allowing its peripheral
                // to be reused. Radio loss is itself a link-loss boundary.
                if completion == "ack" || completion == "timeout" {
                    fixture.disconnect()
                }
                if completion == "radio" { fixture.radio(true) }
                expect(fixture.central.connections.count == 1,
                       "R2 \(completion) nav=\(navigation) workout=\(workout): successor connects once")
                expect(fixture.link.testNavigationDemand == navigation &&
                       fixture.link.testWorkoutDemand == workout,
                       "R2 \(completion): preserve independent demand")
                expect(fixture.link.testPreparationID != nil &&
                       fixture.link.testPreparationID != fixture.preparationID,
                       "R2 \(completion): fresh successor preparation identity")
                expect(fixture.link.transportPhase == .connecting,
                       "R2 \(completion): no idle-with-demand stall")
            }
        }
    }

    static func lateCallbacksDoNotRestoreReadiness() throws {
        for stopping in [true, false] {
            let fixture = try Fixture()
            defer { fixture.dispose() }
            if stopping { fixture.stop() } else { fixture.link.testFailWriter() }
            fixture.link.peripheralIsReady(toSendWriteWithoutResponse: fixture.peripheral)
            fixture.link.testCapabilities()
            expect(!fixture.link.state.isReady,
                   "R3 \(stopping ? "stopping" : "recovering"): published readiness stays false")
            expect(fixture.link.transportPhase == (stopping ? .stopping : .recovering),
                   "R3: late callbacks preserve authoritative phase")
            expect(!fixture.link.testHasHeartbeat,
                   "R3: late CAP2 does not start heartbeat")
            if !stopping {
                expect(fixture.link.testWriterState == .recovering(reason: .attTimeout),
                       "R3: late writer callback does not erase recovery")
            }
        }
    }

    static func sample() -> NavigationLocationSampleV1 {
        .init(coordinate: .init(latitude: 31, longitude: 121),
              horizontalAccuracyMeters: 4, courseDegrees: 90,
              speedMetersPerSecond: 5, altitudeMeters: 10,
              timestamp: Date(timeIntervalSince1970: 1_700_000_000))
    }

    static func snapshot(_ revision: UInt32) -> NavigationSnapshotV1 {
        .init(navigationGeneration: 2, routeID: UUID(), revision: revision,
              contentHash: nil, currentStepIndex: 0, maneuver: .straight,
              instruction: "Successor \(revision)", distanceToManeuverMeters: 100,
              routeRemainingDistanceMeters: 1_000, expectedArrival: nil,
              offRouteDistanceMeters: nil, mode: .offline,
              routeWindow: Data([1, 2, UInt8(revision)]))
    }

    static func workoutFrames(_ state: WorkoutDeviceSessionState) -> WorkoutDeviceFrames {
        // Canonical-sized transport fixtures; lifecycle tests assert the
        // adapter's group ordering, not the metric mapper's numeric values.
        .init(core: Data(repeating: 1, count: 16),
              extended: Data(repeating: 2, count: 16),
              origin: Data(repeating: 3, count: 28), originAvailable: false,
              identity: .init(state: state, sessionToken: state == .idle ? 0 : 7,
                              hasLiveNumerics: false, isCurrentSnapshot: true))
    }

    static func missingDisconnectIsActionable() async throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        fixture.disposition = .submitted
        fixture.stop()
        fixture.link.setNavigationDemand(true)
        fixture.link.testLeaseReleased()
        expect(fixture.central.connections.isEmpty,
               "Cancellation barrier prevents overlapping connect")
        await fixture.clock.fireNext()
        await flushActor()
        expect(fixture.link.transportPhase == .recovering,
               "Missing cancellation callback enters explicit recovery")
        expect(fixture.link.lastError?.contains("Toggle Bluetooth") == true,
               "Missing cancellation callback has actionable error")
        expect(fixture.link.testHasDemand && fixture.central.connections.isEmpty,
               "Missing cancellation callback retains demand without unsafe retry")
        fixture.link.testCapabilities()
        expect(!fixture.link.state.isReady, "Late CAP2 cannot bypass cancellation barrier")
        fixture.radio(false)
        fixture.radio(true)
        expect(fixture.central.connections.count == 1,
               "Radio cycle resumes demand after missing cancellation callback")
    }

    static func successorSnapshotsAndStalePreparationReplies() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        fixture.disposition = .submitted
        let oldRequest = try WatchDirectRidePreparationRequestV1(
            preparationID: fixture.preparationID, operation: .prepare,
            deviceID: fixture.deviceID
        )
        fixture.stop()
        fixture.link.setDemand(navigation: true, workout: true)
        let first = snapshot(1)
        let latest = snapshot(2)
        fixture.link.updateNavigation(location: sample(), snapshot: first)
        fixture.link.updateNavigation(location: sample(), snapshot: latest)
        fixture.link.updateWorkout(workoutFrames(.running), gps: nil)
        expect(fixture.link.testLogicalWrites.allSatisfy { $0.target == .auth },
               "Successor updates cannot write on the releasing lease")
        fixture.link.testLeaseReleased()
        fixture.disconnect()
        let successorID = fixture.link.testPreparationID
        fixture.link.directRidePreparationDidRespond(
            request: oldRequest,
            response: .init(requestID: oldRequest.requestID, accepted: true)
        )
        fixture.link.directRidePreparationSubmissionDidFail(request: oldRequest)
        expect(!fixture.link.testPreparationAccepted &&
               fixture.link.testPreparationID == successorID,
               "Old prepare response/failure cannot alter successor preparation")
        fixture.link.testNegotiateReady()
        expect(fixture.link.state.isReady && fixture.link.testGeneration > 1,
               "Successor reaches ready on a fresh generation")
        expect(fixture.link.testLatestSnapshot == latest &&
               fixture.link.testLatestWorkoutState == .running,
               "Latest navigation/workout state survives shutdown")
        let writes = fixture.link.testLogicalWrites
        expect(writes.contains { $0.target == .route && $0.payload == latest.routeWindow },
               "Successor full resync contains latest route")
        expect(writes.contains {
            $0.target == .navigation && $0.payload == WatchRidePacketEncoderV1.maneuver(latest)
        }, "Successor full resync contains latest maneuver")
        expect(writes.contains { $0.target == .workout },
               "Successor full resync contains workout frames")
        expect(!writes.contains { $0.target == .auth && $0.payload == Data("LEASE_RELEASE".utf8) },
               "Old lease-release bytes do not enter successor connection")
    }

    static func pendingReleaseSurvivesRelaunch() throws {
        for disposition in [WatchDirectRidePreparationSubmissionDispositionV1.activationPending,
                            .counterpartUnreachable, .transportUnavailable] {
            let fixture = try Fixture()
            defer { fixture.dispose() }
            fixture.disposition = disposition
            fixture.stop()
            fixture.disconnect()
            let restored = WatchDeviceLink(
                credentialStore: WatchControllerCredentialStore(credentials: []),
                defaults: fixture.defaults
            )
            defer { restored.testDispose() }
            var releases: [UUID] = []
            restored.onDirectRidePreparationChange = { operation, _, id in
                if operation == .release { releases.append(id) }
                return .submitted
            }
            restored.completeInitialDemandRestoration()
            restored.directRidePreparationAvailabilityDidChange()
            restored.directRidePreparationAvailabilityDidChange()
            expect(releases == [fixture.preparationID],
                   "Relaunch submits exact durable release once after availability")
            expect(fixture.intent == nil,
                   "Accepted durable outbox submission removes local intent")
        }
    }

    static func criticalClearsWaitForApplicationAcceptance() throws {
        for navigation in [true, false] {
            let fixture = try Fixture(navigation: navigation, workout: !navigation)
            defer { fixture.dispose() }
            if navigation {
                fixture.link.endNavigationDemandAfterClearing()
            } else {
                fixture.link.endWorkoutDemandAfterClearing(workoutFrames(.ended))
            }
            expect(fixture.link.testHasDemand && fixture.link.state.isReady,
                   "Terminal clear retains demand while ATT writes are pending")
            for _ in 0..<16 where fixture.link.testHasATTWrite {
                fixture.link.testATTCompletion()
            }
            expect(fixture.link.testHasApplicationAck && fixture.link.testHasDemand,
                   "Physical group completion is not application acceptance")
            expect(fixture.preparations.isEmpty,
                   "No phone release before terminal application ACK")
            fixture.link.testApplicationAcknowledgement()
            expect(!fixture.link.testHasDemand && fixture.link.transportPhase == .stopping,
                   "Terminal application ACK permits logical shutdown")
            expect(fixture.link.testLogicalWrites.contains {
                $0.target == .auth && $0.payload == Data("LEASE_RELEASE".utf8)
            }, "Terminal acceptance precedes lease-release write")
        }
        // Releasing one channel must not terminate the independent other one.
        let fixture = try Fixture(navigation: true, workout: true)
        defer { fixture.dispose() }
        fixture.link.endNavigationDemandAfterClearing()
        for _ in 0..<16 where fixture.link.testHasATTWrite { fixture.link.testATTCompletion() }
        fixture.link.testApplicationAcknowledgement()
        expect(fixture.link.state.isReady && fixture.link.testWorkoutDemand,
               "Navigation clear does not stop active workout")
    }

    static func readyRefreshAndLateDiscoveryAreIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let writes = fixture.peripheral.writes.count
        fixture.link.testCapabilities()
        fixture.link.testCapabilities()
        expect(fixture.peripheral.writes.count == writes,
               "Ready CAP2 refresh does not enqueue duplicate replay")
        fixture.stop()
        let failed = NSError(domain: "Injected", code: 1)
        fixture.link.peripheral(fixture.peripheral, didDiscoverServices: failed)
        fixture.link.centralManager(fixture.central, didConnect: fixture.peripheral)
        expect(fixture.link.transportPhase == .stopping && fixture.link.lastError == nil,
               "Late discovery/connection callbacks cannot overwrite shutdown")
    }

    static func repeatedDemandDuringStop() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        fixture.stop()
        fixture.link.setNavigationDemand(true)
        fixture.link.setNavigationDemand(false)
        fixture.link.setWorkoutDemand(true)
        fixture.link.setWorkoutDemand(false)
        fixture.disconnect()
        expect(!fixture.link.testHasDemand && fixture.central.connections.isEmpty,
               "Withdrawn successor demand does not restart an unwanted ride")
        expect(fixture.intent?.operation == .release,
               "Repeated stop/start still releases the old preparation")
    }

    static func activeDisconnectRetainsPreparation() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        fixture.disconnect()
        expect(fixture.link.testHasDemand, "Active disconnect retains demand")
        expect(fixture.intent?.operation == .prepare, "Active disconnect retains prepare")
        expect(fixture.preparations.isEmpty, "Active disconnect does not release phone")
        expect(fixture.link.testHasReconnect, "Active disconnect schedules recovery")
    }
}
