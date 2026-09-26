import Foundation
import CoreBluetooth

@MainActor
@main
enum Tests {
    static var failures = 0
    static var assertions = 0
    static var cases = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !value() { failures += 1; print("  FAIL: \(message)"); fflush(stdout) }
    }
    static func run(_ name: String, _ body: () async -> Void) async {
        cases += 1
        let before = failures
        await body()
        print("\(failures == before ? "PASS" : "FAIL") \(name)"); fflush(stdout)
    }
    @MainActor final class Fixture {
        let clock = ManualClock()
        let link: WatchDeviceLink
        let peer: CBPeripheral
        let id = UUID()
        var calls: [(WatchDirectRidePreparationOperationV1, UUID)] = []
        var disposition: WatchDirectRidePreparationSubmissionDispositionV1 = .submitted
        let defaults: UserDefaults
        let suite: String
        init(appACK: Bool = true) {
            suite = "WatchLinkHost-\(UUID())"
            defaults = UserDefaults(suiteName: suite)!
            #if FIXED_LIFECYCLE
            let clock = clock
            link = WatchDeviceLink(credentialStore: WatchControllerCredentialStore(), defaults: defaults, sleep: { try await clock.sleep($0) })
            #else
            link = WatchDeviceLink(credentialStore: WatchControllerCredentialStore(), defaults: defaults)
            #endif
            peer = link.testStartReady(preparationID: id, appACK: appACK)
            link.onDirectRidePreparationChange = { [weak self] op, _, id in
                guard let self else { return .transportUnavailable }
                self.calls.append((op, id))
                return self.disposition
            }
        }
        func close() { link.testDispose(); clock.cancelAll(); defaults.removePersistentDomain(forName: suite) }
        var releases: [UUID] { calls.filter { $0.0 == .release }.map(\.1) }
        var prepares: [UUID] { calls.filter { $0.0 == .prepare }.map(\.1) }
        func stop() { link.setDemand(navigation: false, workout: false) }
    }
    static func settle() async { for _ in 0..<100 { await Task.yield() } }
    static func snapshot(_ marker: UInt8) -> NavigationSnapshotV1 {
        var result = NavigationSnapshotV1(); result.routeWindow = Data([marker]); result.instruction = "new-\(marker)"; return result
    }
    static var location: NavigationLocationSampleV1 { .init(coordinate: .init(latitude: 1, longitude: 2), horizontalAccuracyMeters: 3, courseDegrees: 4, speedMetersPerSecond: 5, altitudeMeters: 6, timestamp: Date(timeIntervalSince1970: 0)) }
    static func main() async {
        await run("unchanged route suppression preserves replacement and reconnect") {
            let f = Fixture(); defer { f.close() }
            for _ in 0..<20 {
                f.link.updateNavigation(location: location, snapshot: snapshot(77))
                f.link.testDrainATT(on: f.peer)
            }
            let routeID = WatchDirectBLEProtocolV1.routeUUID
            expect(f.peer.writes.filter { $0.characteristic.uuid.uuidString == routeID }.count == 1,
                   "20 unchanged snapshots submit one route instead of 20")
            // An in-flight workout blocks B, then the latest route returns to A.
            f.link.setWorkoutDemand(true)
            f.link.updateWorkout(.init(identity: .init(state: .running)), gps: nil, motion: nil)
            f.link.updateNavigation(location: location, snapshot: snapshot(88))
            f.link.updateNavigation(location: location, snapshot: snapshot(77))
            f.link.testDrainATT(on: f.peer)
            expect(!f.peer.writes.contains { $0.data == Data([88]) }, "unsent B cannot survive newer A")
            f.link.testWriterFailure(); f.link.testDrop(f.peer); await settle()
            f.clock.advance(by: .seconds(1)); await settle()
            f.link.testFinishReconnect(f.peer)
            expect(f.peer.writes.filter { $0.characteristic.uuid.uuidString == routeID }.count == 2,
                   "reconnect forces a fresh route submission")
        }
        await run("maneuver distance advances across small GPS increments") {
            let f = Fixture(); defer { f.close() }
            var current = snapshot(77)
            for distance in stride(from: 100.0, through: 0.0, by: -5.0) {
                current.distanceToManeuverMeters = distance
                f.link.updateNavigation(location: location, snapshot: current)
                f.link.testDrainATT(on: f.peer)
            }
            let maneuvers = f.peer.writes.filter {
                $0.characteristic.uuid.uuidString == WatchDirectBLEProtocolV1.navigationUUID
            }
            expect(maneuvers.count == 11,
                   "100 metres of 5-metre updates must send each accumulated 10-metre change")
        }
        await run("maneuver threshold follows the snapshot actually dispatched") {
            let f = Fixture(); defer { f.close() }
            var current = snapshot(77)
            current.distanceToManeuverMeters = 100
            f.link.updateNavigation(location: location, snapshot: current)
            f.link.testDrainATT(on: f.peer)
            f.link.setWorkoutDemand(true)
            f.link.updateWorkout(.init(identity: .init(state: .running)), gps: nil, motion: nil)
            // Several samples arrive while another characteristic owns ATT.
            // The queued 90-metre maneuver must be replaced by 85, then become
            // the baseline only when it reaches the transport.
            for distance in [95.0, 90.0, 85.0] {
                current.distanceToManeuverMeters = distance
                f.link.updateNavigation(location: location, snapshot: current)
            }
            f.link.testDrainATT(on: f.peer)
            current.distanceToManeuverMeters = 80
            f.link.updateNavigation(location: location, snapshot: current)
            f.link.testDrainATT(on: f.peer)
            expect(f.peer.writes.filter {
                $0.characteristic.uuid.uuidString == WatchDirectBLEProtocolV1.navigationUUID
            }.count == 2, "an unsent intermediate sample must not become the distance baseline")
            current.distanceToManeuverMeters = 75
            f.link.updateNavigation(location: location, snapshot: current)
            f.link.testDrainATT(on: f.peer)
            expect(f.peer.writes.filter {
                $0.characteristic.uuid.uuidString == WatchDirectBLEProtocolV1.navigationUUID
            }.count == 3, "the next accumulated 10 metres must update the maneuver")
        }
        for appACK in [false, true] {
            await run("navigation clear retires queued snapshots, app ACK \(appACK)") {
                let f = Fixture(appACK: appACK); defer { f.close() }
                f.link.setWorkoutDemand(true)
                // Hold the writer on a workout while older navigation waits.
                f.link.updateWorkout(.init(identity: .init(state: .running)), gps: nil, motion: nil)
                f.link.updateNavigation(location: location, snapshot: snapshot(77))
                f.link.endNavigationDemandAfterClearing()
                f.link.testDrainATT(on: f.peer)
                if appACK, let clear = f.link.testPendingACK {
                    expect(clear.applicationCommandType == .navigationClear, "clear must be the pending command")
                    f.link.testAcknowledge(clear, on: f.peer)
                    f.link.testDrainATT(on: f.peer)
                }
                expect(!f.peer.writes.contains { $0.data == Data([77]) },
                       "an obsolete queued route cannot be sent after its clear")
                expect(!f.peer.writes.contains { $0.data == Data("new-77".utf8) },
                       "an obsolete queued maneuver cannot resurrect navigation")
                expect(f.link.state.isReady && f.link.testDemand.workoutActive,
                       "the independent workout keeps its connection")
            }
        }
        await run("clear preserves a successor route and queued workout") {
            let f = Fixture(); defer { f.close() }
            f.link.setWorkoutDemand(true)
            f.link.updateNavigation(location: location, snapshot: snapshot(77))
            f.link.updateWorkout(.init(identity: .init(state: .running)), gps: nil, motion: nil)
            f.link.endNavigationDemandAfterClearing()
            f.link.setNavigationDemand(true)
            f.link.updateNavigation(location: location, snapshot: snapshot(88))
            f.link.testDrainATT(on: f.peer)
            guard let clear = f.link.testPendingACK else {
                expect(false, "old navigation clear must precede successor state")
                return
            }
            let clearEnd = f.peer.writes.count
            f.link.testAcknowledge(clear, on: f.peer)
            f.link.testDrainATT(on: f.peer)
            let successorWrites = f.peer.writes.dropFirst(clearEnd)
            expect(successorWrites.contains { $0.data == Data([88]) }, "successor route survives the clear")
            expect(successorWrites.contains { $0.data == Data("new-88".utf8) }, "successor maneuver follows the clear")
            expect(!successorWrites.contains { $0.data == Data([77]) || $0.data == Data("new-77".utf8) },
                   "retired navigation cannot return after the clear")
            expect(successorWrites.contains { $0.data == Data("workout-running-identity".utf8) },
                   "clearing navigation retains queued workout traffic")
        }
        await run("R1 disconnect releases exact preparation") {
            let f = Fixture(); defer { f.close() }
            f.stop(); f.link.testDrop(f.peer)
            expect(f.releases == [f.id], "disconnect must submit the captured release once")
            expect(f.link.testIntent == nil, "submitted release leaves no orphaned prepare")
            expect(!f.link.state.isReady, "shutdown cannot remain ready")
            f.link.testDrop(f.peer)
            expect(f.releases == [f.id], "duplicate disconnect must be inert")
        }
        await run("R1 unavailable WC persists release and retries") {
            let f = Fixture(); defer { f.close() }
            f.disposition = .activationPending
            f.stop(); f.link.testDrop(f.peer)
            expect(f.link.testIntent?.operation == .release, "persist release before WC submission succeeds")
            expect(f.link.testIntent?.preparationID == f.id, "persist exact old identity")
            f.disposition = .submitted
            f.link.directRidePreparationAvailabilityDidChange()
            expect(f.link.testIntent == nil, "availability submits retained release")
            expect(f.releases.allSatisfy { $0 == f.id } && f.releases.count >= 2, "retry must not change identity")
        }
        await run("R1 radio loss with no remaining demand") {
            let f = Fixture(); defer { f.close() }
            f.stop(); f.link.testRadio(.poweredOff)
            expect(f.releases == [f.id], "radio loss must finalize without a disconnect callback")
            expect(f.link.transportPhase == .idle, "radio loss ends stopped transport")
        }
        for completion in ["ack", "disconnect", "radio"] {
            for kind in ["navigation", "workout", "combined"] {
                await run("R2 successor \(kind) completed by \(completion)") {
                    let f = Fixture(); defer { f.close() }
                    f.stop()
                    let nav = kind != "workout", workout = kind != "navigation"
                    f.link.setDemand(navigation: nav, workout: workout)
                    if nav { f.link.updateNavigation(location: location, snapshot: snapshot(77)) }
                    if workout { f.link.updateWorkout(.init(identity: .init(state: .running)), gps: nil, motion: nil) }
                    expect(!f.link.state.isReady, "published readiness follows stopping phase")
                    expect(f.link.testQueued == 0, "successor snapshots cannot enter retiring queue")
                    expect(f.prepares.isEmpty, "no successor prepare before old session finishes")
                    if completion == "ack" {
                        f.link.testAuth("LEASE_RELEASED", on: f.peer)
                        expect(f.link.testCentral.connections.isEmpty, "wait for old cancellation before reconnect")
                        f.link.testDrop(f.peer)
                    } else if completion == "radio" {
                        f.link.testRadio(.poweredOff)
                        expect(f.link.testCentral.connections.isEmpty, "no connect while radio is off")
                        f.link.testRadio(.poweredOn)
                    } else { f.link.testDrop(f.peer) }
                    expect(f.releases == [f.id], "retire old identity once")
                    expect(f.link.testDemand.navigationActive == nav && f.link.testDemand.workoutActive == workout, "successor demand preserved")
                    expect(f.prepares.count == 1 && f.prepares[0] != f.id, "successor prepares with fresh identity")
                    expect(!f.link.testCentral.connections.isEmpty, "successor reconnect scheduled without another demand event")
                    if !f.link.testCentral.connections.isEmpty {
                        f.link.testFinishReconnect(f.peer)
                        expect(f.link.state.isReady, "successor completes authenticating/lease/capabilities")
                        if nav { expect(f.peer.writes.contains { $0.data == Data([77]) }, "latest route replayed") }
                        if workout { expect(f.peer.writes.contains { String(data: $0.data, encoding: .utf8)?.contains("running") == true }, "latest workout replayed") }
                    }
                }
            }
        }
        await run("R3 late capabilities/lease/writer during stop") {
            let f = Fixture(); defer { f.close() }
            f.stop()
            let writes = f.peer.writes.count
            f.link.testCapabilities(on: f.peer)
            f.link.testAuth("LEASE_OK", on: f.peer)
            f.link.peripheralIsReady(toSendWriteWithoutResponse: f.peer)
            expect(!f.link.state.isReady && f.link.transportPhase == .stopping, "callbacks must not revive stopped link")
            expect(!f.link.testHeartbeat && f.peer.writes.count == writes, "no heartbeat or replay from late CAP2")
        }
        await run("R3 late callbacks after writer recovery") {
            let f = Fixture(); defer { f.close() }
            f.link.testWriterFailure()
            let writes = f.peer.writes.count
            f.link.peripheralIsReady(toSendWriteWithoutResponse: f.peer)
            f.link.testCapabilities(on: f.peer)
            f.link.testAuth("LEASE_OK", on: f.peer)
            f.link.centralManager(f.link.testCentral, didConnect: f.peer)
            expect(f.link.transportPhase == .recovering && !f.link.state.isReady, "same-generation callbacks cannot leave recovery")
            expect(f.link.testWriter == .recovering(reason: .attTimeout), "late writer idle must not erase failure")
            expect(f.peer.writes.count == writes && f.peer.serviceDiscoveries == 0, "no new writes or discovery in recovery")
        }
        await run("duplicate CAP2 is side-effect free") {
            let f = Fixture(); defer { f.close() }
            let writes = f.peer.writes.count
            f.link.testCapabilities(on: f.peer)
            expect(f.link.state.isReady, "valid refresh stays ready")
            expect(f.peer.writes.count == writes, "duplicate capabilities must not start replay")
        }
        for appBeforeATT in [false, true] {
            await run("terminal workout and clear application ACK ordering \(appBeforeATT)") {
                let f = Fixture(); defer { f.close() }
                f.link.setWorkoutDemand(true)
                f.link.endWorkoutDemandAfterClearing(.init(identity: .init(state: .ended)))
                let group = f.link.testActiveGroup!
                f.link.testATT(on: f.peer) // first member
                if appBeforeATT { f.link.testAcknowledge(group, on: f.peer) }
                f.link.testATT(on: f.peer) // final member
                if !appBeforeATT {
                    expect(f.link.testDemand.workoutReleasePending, "ATT alone does not complete workout release")
                    f.link.testAcknowledge(group, on: f.peer, generation: group.stateGeneration &+ 1)
                    expect(f.link.testDemand.workoutReleasePending, "wrong-generation app ACK ignored")
                    f.link.testAcknowledge(group, on: f.peer)
                }
                expect(f.link.testDemand.navigationActive && f.link.state.isReady, "navigation independently holds demand")
                expect(!f.link.testDemand.workoutReleasePending, "exact app ACK completes terminal workout")
                expect(!f.peer.writes.contains { $0.data == Data("LEASE_RELEASE".utf8) }, "no lease release while navigation remains")
                f.link.endNavigationDemandAfterClearing()
                guard let clear = f.link.testActiveGroup else { expect(false, "clear not active: phase=\(f.link.transportPhase) state=\(f.link.state) pendingACK=\(f.link.testPendingACK != nil)"); return }
                f.link.testDrainATT(on: f.peer)
                expect(f.link.testDemand.navigationReleasePending, "navigation clear also needs app acceptance")
                f.link.testAcknowledge(clear, on: f.peer)
                expect(f.peer.writes.last?.data == Data("LEASE_RELEASE".utf8), "lease follows terminal and clear acceptance")
            }
        }
        await run("workout independently retains demand after navigation clear") {
            let f = Fixture(); defer { f.close() }
            f.link.setWorkoutDemand(true)
            f.link.endNavigationDemandAfterClearing()
            let clear = f.link.testActiveGroup!
            f.link.testDrainATT(on: f.peer)
            expect(f.link.testDemand.navigationReleasePending, "ATT does not release navigation demand")
            f.link.testAcknowledge(clear, on: f.peer)
            expect(f.link.testDemand.workoutActive && f.link.state.isReady, "workout independently holds the connection")
            expect(!f.link.testDemand.navigationReleasePending, "accepted clear releases only navigation")
            expect(!f.peer.writes.contains { $0.data == Data("LEASE_RELEASE".utf8) }, "no lease release while workout remains")
        }
        await run("R1 write failure and duplicate ACK share finalization") {
            let f = Fixture(); defer { f.close() }
            f.stop()
            f.link.testATT(on: f.peer, error: NSError(domain: "test", code: 1))
            expect(f.releases == [f.id], "write failure releases exact old preparation")
            f.link.testAuth("LEASE_RELEASED", on: f.peer)
            f.link.testDrop(f.peer)
            f.link.testAuth("LEASE_RELEASED", on: f.peer)
            expect(f.releases == [f.id], "duplicate completion cannot release another handoff")
        }
        #if FIXED_LIFECYCLE
        for disposition in [WatchDirectRidePreparationSubmissionDispositionV1.activationPending,
                            .counterpartUnreachable, .transportUnavailable, .encodingFailed] {
            await run("R1 release survives relaunch: \(disposition)") {
                let f = Fixture(); defer { f.close() }
                f.disposition = disposition
                f.stop(); f.link.testDrop(f.peer)
                f.link.setNavigationDemand(true)
                expect(f.link.testIntent?.operation == .release && f.link.testIntent?.preparationID == f.id,
                       "successor cannot overwrite an unsent old release")
                f.link.testDispose()
                let restored = WatchDeviceLink(credentialStore: WatchControllerCredentialStore(), defaults: f.defaults,
                                              sleep: { try await f.clock.sleep($0) })
                defer { restored.testDispose() }
                var released: [UUID] = []
                restored.onDirectRidePreparationChange = { operation, _, id in
                    if operation == .release { released.append(id) }
                    return .submitted
                }
                restored.completeInitialDemandRestoration()
                restored.directRidePreparationAvailabilityDidChange()
                expect(released == [f.id] && restored.testIntent == nil,
                       "relaunch without recovered demand releases the identity the phone still holds")
            }
        }
        for kind in ["navigation", "workout", "combined"] {
            await run("R2 successor \(kind) after release deadline") {
                let f = Fixture(); defer { f.close() }
                f.stop(); f.link.testDrainATT(on: f.peer)
                f.link.setDemand(navigation: kind != "workout", workout: kind != "navigation")
                if kind != "workout" { f.link.updateNavigation(location: location, snapshot: snapshot(88)) }
                if kind != "navigation" { f.link.updateWorkout(.init(identity: .init(state: .running)), gps: nil, motion: nil) }
                await settle(); f.clock.advance(by: .seconds(5)); await settle()
                expect(f.releases == [f.id] && f.link.testCentral.connections.isEmpty,
                       "deadline releases preparation but respects old connection cancellation")
                f.link.testDrop(f.peer)
                expect(f.link.testCentral.connections.count == 1, "timeout successor reconnects")
                f.link.testFinishReconnect(f.peer)
                expect(f.link.state.isReady, "timeout successor becomes ready")
                if kind != "workout" { expect(f.peer.writes.contains { $0.data == Data([88]) }, "latest timeout navigation replayed") }
            }
        }
        await run("R2 withdrawn successor does not restart") {
            let f = Fixture(); defer { f.close() }
            f.stop(); f.link.setNavigationDemand(true); f.link.setNavigationDemand(false)
            f.link.testAuth("LEASE_RELEASED", on: f.peer); f.link.testDrop(f.peer)
            expect(f.prepares.isEmpty && f.link.testCentral.connections.isEmpty, "withdrawn demand stays stopped")
        }
        await run("late restoration and setup callbacks cannot bypass stopping") {
            let f = Fixture(); defer { f.close() }
            f.stop(); f.link.setNavigationDemand(true)
            f.link.centralManager(f.link.testCentral, willRestoreState: [CBCentralManagerRestoredStatePeripheralsKey: [f.peer]])
            f.link.centralManager(f.link.testCentral, didConnect: f.peer)
            f.link.peripheral(f.peer, didDiscoverServices: nil)
            f.link.peripheral(f.peer, didDiscoverCharacteristicsFor: f.peer.services![0], error: NSError(domain: "late", code: 1))
            let characteristic = f.peer.services![0].characteristics![0]
            f.link.peripheral(f.peer, didUpdateNotificationStateFor: characteristic, error: NSError(domain: "late", code: 1))
            expect(f.link.transportPhase == .stopping && f.link.testCentral.connections.isEmpty,
                   "restore callback cannot reconnect a retiring peer")
            expect(f.peer.serviceDiscoveries == 0 && f.peer.characteristicDiscoveries == 0,
                   "late setup callbacks do not cause new setup")
        }
        await run("stop drains admitted application groups before release") {
            let f = Fixture(); defer { f.close() }
            f.link.updateWorkout(.init(identity: .init(state: .ended)), gps: nil, motion: nil)
            let group = f.link.testActiveGroup!
            f.stop()
            f.link.testAuth("LEASE_RELEASED", on: f.peer)
            expect(f.releases.isEmpty, "early release response cannot abandon admitted terminal state")
            f.link.testDrainATT(on: f.peer)
            expect(!f.peer.writes.contains { $0.data == Data("LEASE_RELEASE".utf8) }, "ATT completion still waits for application ACK while stopping")
            f.link.testAcknowledge(group, on: f.peer)
            expect(f.peer.writes.last?.data == Data("LEASE_RELEASE".utf8), "release follows admitted group acceptance")
        }
        await run("failed connection callback completes stopping") {
            let f = Fixture(); defer { f.close() }
            f.stop()
            f.link.centralManager(f.link.testCentral, didFailToConnect: f.peer, error: NSError(domain: "test", code: 1))
            expect(f.releases == [f.id] && f.link.transportPhase == .idle, "failed connection is a release-completing terminal callback")
        }
        await run("old release cannot clear phone successor preparation") {
            let old = try! WatchDirectRidePreparationRequestV1(preparationID: UUID(), operation: .release,
                         deviceID: "00112233445566778899aabbccddeeff")
            let successor = UUID()
            expect(!WatchDirectRidePreparationPolicyV1.releaseMatches(preparedDeviceID: old.deviceID,
                   preparedPreparationID: successor, request: old), "production phone policy rejects the old preparation identity")
        }
        await run("R1/R2 injected lease deadline and bounded missing disconnect") {
            let f = Fixture(); defer { f.close() }
            f.stop(); f.link.testDrainATT(on: f.peer)
            f.link.setNavigationDemand(true)
            await settle()
            expect(f.clock.pending > 0, "deadline registered")
            f.clock.advance(by: .seconds(5)); await settle()
            expect(f.releases == [f.id], "lease timeout releases phone even without ACK")
            expect(f.link.testCentral.cancellations.count == 1, "one cancellation requested")
            f.clock.advance(by: .seconds(5)); await settle()
            expect(f.link.lastError?.contains("Toggle Bluetooth") == true, "missing callback is actionable, not silently idle")
            expect(f.link.testCentral.connections.isEmpty, "no unsafe same-peer reconnect")
            f.link.testDrop(f.peer)
            expect(f.link.testCentral.connections.count == 1, "late disconnect safely resumes successor")
        }
        await run("active recovery cancellation has a bounded visible failure") {
            let f = Fixture(); defer { f.close() }
            f.link.testWriterFailure()
            await settle()
            expect(f.link.testRecoveryPhase == .cancelling, "cancellation is a reducer substate")
            f.clock.advance(by: .seconds(5)); await settle()
            expect(f.link.testRecoveryPhase == .cancellationTimedOut, "deadline marks recovery blocked")
            expect(f.link.lastError == RideBLERecoveryPolicyV1.blockedMessage, "blocked recovery is actionable")
            f.link.testWriterFailure()
            expect(f.link.lastError == RideBLERecoveryPolicyV1.blockedMessage, "repeated failure does not hide the blocked instruction")
            f.link.setNavigationDemand(true)
            f.link.updateNavigation(location: location, snapshot: snapshot(99))
            expect(f.link.testCentral.connections.isEmpty && f.peer.writes.isEmpty, "deadline must not reuse ambiguous callbacks")
            expect(f.link.testPreparationID == f.id, "active demand retains exact phone handoff")
            f.link.testRadio(.poweredOff)
            f.link.testRadio(.poweredOn)
            expect(f.link.testCentral.connections.count == 1, "real radio boundary permits reconnect")
            expect(f.link.testRecoveryPhase == nil, "successor clears recovery deadline state")
        }
        await run("disconnect before recovery deadline cannot fail successor") {
            let f = Fixture(); defer { f.close() }
            f.link.testWriterFailure(); await settle()
            f.link.testDrop(f.peer); await settle()
            f.clock.advance(by: .seconds(1)); await settle()
            f.link.testFinishReconnect(f.peer)
            f.clock.advance(by: .seconds(10)); await settle()
            expect(f.link.state.isReady, "cancelled old deadline cannot poison new connection")
        }
        await run("active ride disconnect retains preparation and retries") {
            let f = Fixture(); defer { f.close() }
            f.link.testDrop(f.peer)
            expect(f.releases.isEmpty && f.link.testIntent?.operation == .prepare, "active demand retains handoff")
            await settle(); f.clock.advance(by: .seconds(1)); await settle()
            expect(f.link.testCentral.connections.count == 1, "normal recovery restarts retained demand")
        }
        await run("old prepare response cannot clear successor identity") {
            let f = Fixture(); defer { f.close() }
            f.disposition = .counterpartUnreachable
            f.stop(); f.link.setNavigationDemand(true)
            f.link.directRidePreparationAvailabilityDidChange()
            expect(f.link.testPreparationID == f.id, "availability cannot supersede retiring identity")
            f.link.testDrop(f.peer)
            expect(f.link.testIntent?.operation == .release && f.link.testPreparationID == f.id,
                   "unsent release cannot be overwritten by a successor prepare")
            expect(f.link.testCentral.connections.isEmpty && f.link.lastError != nil,
                   "pending old handoff is visible and gates reconnect")
            f.disposition = .submitted
            f.link.directRidePreparationAvailabilityDidChange()
            let successor = f.link.testPreparationID
            expect(successor != nil && successor != f.id, "durable release permits fresh successor identity")
            expect(f.link.testCentral.connections.count == 1, "availability restarts pending successor")
            f.link.directRidePreparationDidRespond(request: try! .init(preparationID: f.id, operation: .prepare, deviceID: "00112233445566778899aabbccddeeff"), response: .init(requestID: UUID(), accepted: true))
            expect(f.link.testPreparationID == successor && !f.link.testPreparationAccepted, "delayed prepare reply ignored")
        }
        await run("phone reconciliation waits for restored demand") {
            let suite = "WatchLinkReconciliation-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let preparationID = UUID()
            WatchDeviceLink.testInstallRestoredPreparation(
                defaults: defaults,
                preparationID: preparationID
            )
            let link = WatchDeviceLink(
                credentialStore: WatchControllerCredentialStore(),
                defaults: defaults,
                sleep: { _ in }
            )
            defer { link.testDispose() }
            var releases: [UUID] = []
            link.onDirectRidePreparationChange = { operation, _, identity in
                if operation == .release { releases.append(identity) }
                return .submitted
            }
            let request = try! WatchDirectRideReconciliationRequestV1(
                preparationID: preparationID,
                deviceID: "00112233445566778899aabbccddeeff"
            )
            link.requestPhonePreparationReconciliation(request)
            expect(releases.isEmpty,
                   "reconciliation cannot release before ride restoration completes")
            expect(link.testPendingReconciliation == request,
                   "a pre-restoration reconciliation is persisted")
            link.completeInitialDemandRestoration()
            expect(releases == [preparationID],
                   "idle restoration durably releases the exact phone handoff")
            expect(link.testPendingReconciliation == nil && link.testIntent == nil,
                   "successful reconciliation clears both persisted intents")
        }
        await run("phone reconciliation cannot steal an active Watch ride") {
            let f = Fixture(); defer { f.close() }
            f.link.completeInitialDemandRestoration()
            let request = try! WatchDirectRideReconciliationRequestV1(
                preparationID: f.id,
                deviceID: "00112233445566778899aabbccddeeff"
            )
            f.link.requestPhonePreparationReconciliation(request)
            expect(f.releases.isEmpty && f.link.testPreparationID == f.id,
                   "active demand retains the current handoff")
            f.stop()
            f.link.testDrop(f.peer)
            expect(f.releases == [f.id],
                   "the pending request completes after the active ride ends")
        }
        await run("old reconciliation cannot release a successor ride") {
            let f = Fixture(); defer { f.close() }
            f.link.completeInitialDemandRestoration()
            let oldID = UUID()
            let request = try! WatchDirectRideReconciliationRequestV1(
                preparationID: oldID,
                deviceID: "00112233445566778899aabbccddeeff"
            )
            f.link.requestPhonePreparationReconciliation(request)
            expect(f.releases == [oldID],
                   "the Watch releases only the stale requested identity")
            expect(f.link.testPreparationID == f.id && f.link.testIntent?.operation == .prepare,
                   "the active successor preparation remains intact")
        }
        #endif
        #if FIXED_LIFECYCLE
        await run("reducer role/phase/generation regression matrix") {
            for role in [RideBLEControllerRoleV1.ownerPhone, .scopedWatch] {
                var ready = RideBLETransportStateMachineV1(role: role)
                _ = ready.reduce(.beginConnection)
                _ = ready.reduce(.linkConnected(generation: 1))
                _ = ready.reduce(.authenticated(generation: 1))
                _ = ready.reduce(.leaseAccepted(generation: 1, leaseGeneration: 1))
                _ = ready.reduce(.capabilitiesAccepted(generation: 1, schemaVersion: 1))
                for stopping in [false, true] {
                    var transport = ready
                    _ = transport.reduce(stopping ? .stopRequested(generation: 1) : .failed(generation: 1, reason: .attTimeout))
                    let original = transport
                    for event in [RideBLETransportEventV1.capabilitiesAccepted(generation: 1, schemaVersion: 1),
                                  .leaseAccepted(generation: 1, leaseGeneration: 1), .authenticated(generation: 1),
                                  .linkConnected(generation: 1), .beginConnection] {
                        expect(transport.reduce(event) == .rejectedInvalidTransition && transport == original,
                               "\(role) rejects invalid readiness event \(event)")
                    }
                    if !stopping {
                        expect(transport.reduce(.writerChanged(generation: 1, state: .idle)) == .rejectedInvalidTransition && transport == original,
                               "recovery writer cannot be overwritten")
                    }
                    expect(transport.reduce(.capabilitiesAccepted(generation: 0, schemaVersion: 1)) == .ignoredStaleGeneration && transport == original,
                           "old generation remains ignored")
                }
            }
        }
        #endif
        print("RESULT cases=\(cases) assertions=\(assertions) failures=\(failures)")
        if failures != 0 { exit(1) }
    }
}
