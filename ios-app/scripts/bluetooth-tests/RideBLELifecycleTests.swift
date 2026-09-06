import Foundation

@main
struct RideBLELifecycleTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func ready(_ role: RideBLEControllerRoleV1) -> RideBLETransportStateMachineV1 {
        var machine = RideBLETransportStateMachineV1(role: role)
        expect(machine.reduce(.beginConnection) == .applied, "begin connection")
        let generation = machine.generation
        expect(machine.reduce(.linkConnected(generation: generation)) == .applied, "link")
        expect(machine.reduce(.authenticated(generation: generation)) == .applied, "authentication")
        expect(machine.reduce(.leaseAccepted(generation: generation, leaseGeneration: 7)) == .applied, "lease")
        expect(machine.reduce(.capabilitiesAccepted(generation: generation, schemaVersion: 1)) == .becameReady, "capabilities")
        return machine
    }

    static func permutations<T>(_ values: [T]) -> [[T]] {
        guard !values.isEmpty else { return [[]] }
        return values.indices.flatMap { index -> [[T]] in
            var remaining = values
            let first = remaining.remove(at: index)
            return permutations(remaining).map { [first] + $0 }
        }
    }

    static func main() {
        for role: RideBLEControllerRoleV1 in [.ownerPhone, .scopedWatch] {
            for phase in ["stopping", "disconnecting", "recovering"] {
                let callbacks: [RideBLETransportEventV1] = [
                    .leaseAccepted(generation: 1, leaseGeneration: 7),
                    .capabilitiesAccepted(generation: 1, schemaVersion: 1),
                    .writerChanged(generation: 1, state: .idle),
                    .writerChanged(generation: 1, state: .waitingForATTResponse(writeID: 11)),
                ]
                for ordering in permutations(callbacks) {
                    var machine = ready(role)
                    if phase == "recovering" {
                        _ = machine.reduce(.failed(generation: 1, reason: .attTimeout))
                    } else {
                        _ = machine.reduce(.stopRequested(generation: 1))
                        if phase == "disconnecting" {
                            _ = machine.reduce(.disconnectRequested(generation: 1))
                        }
                    }
                    let expectedPhase = machine.phase
                    for event in ordering {
                        let before = machine
                        let result = machine.reduce(event)
                        expect(!machine.isReady && machine.phase == expectedPhase,
                               "\(role) \(phase): late callback restored readiness")
                        switch event {
                        case .writerChanged where phase == "stopping":
                            expect(result == .applied, "pre-release writer completion is allowed")
                        default:
                            expect(result == .rejectedInvalidTransition && machine == before,
                                   "rejected same-generation callback must not mutate state")
                        }
                    }
                    if phase != "recovering" {
                        let before = machine
                        expect(machine.reduce(.beginConnection) == .rejectedInvalidTransition &&
                               machine == before, "successor waits for disconnect boundary")
                    }
                }
            }

            var machine = ready(role)
            expect(machine.reduce(.capabilitiesAccepted(generation: 1, schemaVersion: 1)) == .applied,
                   "ready capability refresh is idempotent")
            expect(machine.reduce(.leaseAccepted(generation: 1, leaseGeneration: 7)) == .applied,
                   "ready same-lease refresh is idempotent")
            let beforeDifferentLease = machine
            expect(machine.reduce(.leaseAccepted(generation: 1, leaseGeneration: 8)) == .rejectedInvalidTransition &&
                   machine == beforeDifferentLease, "cannot replace a ready lease underneath delivery")
            expect(machine.reduce(.stopRequested(generation: 1)) == .leftReady, "stop revokes readiness")
            expect(machine.reduce(.leaseReleased(generation: 1)) == .applied && machine.leaseGeneration == nil,
                   "release acknowledgement is recorded")
            expect(machine.reduce(.disconnectRequested(generation: 1)) == .applied,
                   "start cancellation barrier")
            let awaitingDisconnect = machine
            expect(machine.reduce(.stopRequested(generation: 1)) == .applied &&
                   machine == awaitingDisconnect, "duplicate stop cannot rewind cancellation")
            expect(machine.reduce(.leaseReleased(generation: 1)) == .rejectedInvalidTransition &&
                   machine == awaitingDisconnect, "duplicate release cannot restart cancellation")
            expect(machine.reduce(.disconnected(generation: 1)) == .applied &&
                   machine.phase == .idle && machine.stopStage == nil, "disconnect completes stop")
            let idle = machine
            for event: RideBLETransportEventV1 in [
                .leaseAccepted(generation: 1, leaseGeneration: 7),
                .capabilitiesAccepted(generation: 1, schemaVersion: 1),
                .writerChanged(generation: 1, state: .idle),
                .disconnectRequested(generation: 1),
                .disconnected(generation: 1),
            ] {
                expect(machine.reduce(event) == .ignoredStaleGeneration && machine == idle,
                       "old callbacks cannot touch the next generation")
            }
            for event: RideBLETransportEventV1 in [
                .leaseAccepted(generation: machine.generation, leaseGeneration: 7),
                .capabilitiesAccepted(generation: machine.generation, schemaVersion: 1),
                .writerChanged(generation: machine.generation, state: .idle),
            ] {
                expect(machine.reduce(event) == .rejectedInvalidTransition && machine == idle,
                       "same-generation callbacks cannot revive idle")
            }
            expect(machine.reduce(.stopRequested(generation: machine.generation)) == .applied,
                   "preparation-only/scanning shutdown has an authoritative stop phase")
        }
        print("RideBLE lifecycle: \(assertions) assertions passed")
    }
}
