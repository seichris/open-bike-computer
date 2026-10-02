import Foundation

// Uses the actual NavigationWriteQueue. FakeATT below is a deterministic
// serialization/epoch CONTRACT MODEL, not CoreBluetooth or BLEManager.
// Radio behaviour and real delegate identity delivery need integration tests.
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
private func route(_ n: UInt8, bytes: Int = 12, key: String? = "route-snapshot",
                   command: UUID? = nil) -> NavigationWrite {
    NavigationWrite(data: Data(repeating: n, count: bytes), label: "route-\(n)",
        transportExpectsWriteResponse: true, applicationCommandID: command,
        writeClass: .route, coalescingKey: key)
}
private func gps(_ n: UInt8) -> NavigationWrite {
    NavigationWrite(data: Data([n]), label: "gps-\(n)",
        transportExpectsWriteResponse: true, writeClass: .gpsPosition,
        coalescingKey: "renderer.benchmark.sample")
}
private func drain(_ q: inout NavigationWriteQueue) -> [NavigationWrite] {
    var result: [NavigationWrite] = []
    q.flush(canSend: { true }, write: { result.append($0) })
    return result
}

private final class FakeATT {
    struct Slot {
        let id: Int
        let epoch: Int
        let characteristic: NavigationWriteClass
        let submittedMs: Int
    }
    var queue = NavigationWriteQueue(maxCount: 8, priorityMaxCount: 4)
    var nowMs = 0
    var epoch = 1
    var nextID = 1
    var pending: Slot?
    var quarantined = false
    var ignored = 0
    var submissions: [NavigationWrite] = []
    func flush() {
        // Mirrors the manager's early return. It does not call queue.flush
        // during ATT wait, hence no backpressureStops increment is expected.
        guard pending == nil, !quarantined else { return }
        var next: NavigationWrite?
        queue.flush(canSend: { true }, maxWrites: 1, write: { next = $0 })
        guard let next else { return }
        submissions.append(next)
        pending = Slot(id: nextID, epoch: epoch,
                       characteristic: next.writeClass, submittedMs: nowMs)
        nextID += 1
    }
    func callback(originEpoch: Int, characteristic: NavigationWriteClass) {
        // CoreBluetooth has no write-ID parameter. originEpoch is a contract
        // harness input, NOT a claim that CB callbacks contain an epoch.
        guard !quarantined, let slot = pending,
              slot.epoch == originEpoch, originEpoch == epoch,
              slot.characteristic == characteristic else { ignored += 1; return }
        pending = nil
        flush()
    }
    func timeout(localID: Int) {
        guard pending?.id == localID else { return }
        pending = nil
        quarantined = true
    }
    func reconnect() {
        epoch += 1
        pending = nil
        queue.removeAll()
        quarantined = false
    }
}

@main
struct RendererDeliveryRegressionTests {
    static func main() throws {
        var count = 0
        func run(_ name: String, _ test: () throws -> Void) rethrows {
            try test(); count += 1; print("PASS \(name)")
        }
        run("queue/latest route replaces unsent route; priority GPS remains first") {
            var q = NavigationWriteQueue(maxCount: 4, priorityMaxCount: 2)
            expect(q.enqueueLatestRouteSnapshot(route(1)), "first route")
            expect(q.enqueueCoalescing(gps(1), prioritized: true), "GPS")
            expect(q.enqueueLatestRouteSnapshot(route(2)), "replacement")
            expect(q.count == 2, "one pending route and one GPS")
            expect(drain(&q).map(\.label) == ["gps-1", "route-2"], "priority/order")
            expect(q.cumulativeMetrics.coalescedFrames(for: .route) == 1, "counter")
        }
        run("queue/rejected larger replacement retains old snapshot and unrelated batch") {
            var q = NavigationWriteQueue(maxCount: 3, maxPendingBytes: 20)
            expect(q.enqueueAtomically([NavigationWrite(data: Data(repeating: 9, count: 8), label: "batch")]), "batch")
            expect(q.enqueueLatestRouteSnapshot(route(1, bytes: 8)), "old")
            expect(!q.enqueueLatestRouteSnapshot(route(2, bytes: 13)), "over byte ceiling")
            expect(drain(&q).map(\.label) == ["batch", "route-1"], "transactional rejection")
        }
        run("queue/route snapshot stays protected from unrelated FIFO eviction") {
            var q = NavigationWriteQueue(maxCount: 1)
            expect(q.enqueueLatestRouteSnapshot(route(1)), "route")
            _ = q.enqueue(NavigationWrite(data: Data([0]), label: "ordinary"))
            expect(drain(&q).map(\.label) == ["route-1"], "protected route")
        }
        run("queue/never coalesce across a route-clear boundary") {
            var q = NavigationWriteQueue(maxCount: 4)
            expect(q.enqueueLatestRouteSnapshot(route(1)), "old epoch")
            expect(q.enqueueAtomically([route(0, bytes: 0, key: nil)]), "clear")
            expect(q.enqueueLatestRouteSnapshot(route(2)), "new epoch")
            expect(q.enqueueLatestRouteSnapshot(route(3)), "new replacement")
            expect(drain(&q).map(\.label) == ["route-1", "route-0", "route-3"], "clear boundary")
        }
        run("queue/application ACK command members are not snapshots") {
            var q = NavigationWriteQueue(maxCount: 2)
            expect(!q.enqueueLatestRouteSnapshot(route(1, command: UUID())), "reject command")
            expect(q.count == 0, "no partial admission")
        }
        run("queue/oversize and empty frames do not erase an admitted snapshot") {
            var q = NavigationWriteQueue(maxCount: 2)
            expect(q.enqueueLatestRouteSnapshot(route(1)), "old")
            expect(!q.enqueueLatestRouteSnapshot(route(2, bytes: 577)), "oversize")
            expect(!q.enqueueLatestRouteSnapshot(route(0, bytes: 0)), "clear cannot be snapshot")
            expect(drain(&q).map(\.label) == ["route-1"], "retained")
        }
        run("queue/protected priority application group retains members and order") {
            var q = NavigationWriteQueue(maxCount: 3, priorityMaxCount: 3)
            let id = UUID()
            let members = [route(7, key: "command", command: id), route(8, key: "command", command: id)]
            expect(q.enqueuePrioritizedAtomically(members), "whole group")
            expect(q.enqueueLatestRouteSnapshot(route(1)), "route")
            expect(q.enqueueLatestRouteSnapshot(route(2)), "route replacement")
            let sent = drain(&q)
            expect(sent.map(\.label) == ["route-7", "route-8", "route-2"], "group not split/replaced")
            expect(sent[0].applicationCommandID == id && sent[1].applicationCommandID == id, "command IDs")
        }
        run("queue/count and bytes remain bounded through 1000 refreshes") {
            var q = NavigationWriteQueue(maxCount: 4, maxPendingBytes: 64)
            for n in 0..<1000 {
                expect(q.enqueueLatestRouteSnapshot(route(UInt8(n % 256))), "refresh")
                expect(q.count == 1 && q.pendingByteCount == 12, "bound")
            }
            expect(q.metrics.coalescedFrames(for: .route) == 999, "all replacements counted")
        }
        run("queue/metric snapshots preserve cumulative counts") {
            var q = NavigationWriteQueue(maxCount: 2)
            _ = q.enqueueLatestRouteSnapshot(route(1)); _ = q.snapshotMetricsAndReset()
            _ = q.enqueueLatestRouteSnapshot(route(2))
            expect(q.cumulativeMetrics.enqueuedFrames == 2, "enqueues across reset")
            expect(q.cumulativeMetrics.coalescedFrames(for: .route) == 1, "coalescing across reset")
        }
        run("queue/replacement updates age using monotonic injected clock") {
            var now = 10.0
            var q = NavigationWriteQueue(maxCount: 2, now: { now })
            _ = q.enqueueLatestRouteSnapshot(route(1)); now = 13
            expect(q.metrics.oldestPendingAgeMs == 3000, "old age")
            _ = q.enqueueLatestRouteSnapshot(route(2))
            expect(q.metrics.oldestPendingAgeMs == 0, "replacement age")
        }
        run("contract/3391ms route ACK delay blocks ongoing 1Hz GPS and STILL violates 2500ms") {
            let w = FakeATT()
            _ = w.queue.enqueueLatestRouteSnapshot(route(0)); w.flush()
            let originalID = w.pending!.id
            for second in 1...3 {
                w.nowMs = second * 1000
                _ = w.queue.enqueueCoalescing(gps(UInt8(second)), prioritized: true)
                if second == 2 { _ = w.queue.enqueueLatestRouteSnapshot(route(2)) }
                w.flush()
                expect(w.pending!.id == originalID, "ATT not preempted")
            }
            expect(w.queue.metrics.backpressureStops == 0, "ATT wait != queue canSend refusal")
            expect(w.queue.metrics.coalescedFrames(for: .gpsPosition) == 2, "GPS latest only")
            w.nowMs = 3391
            w.callback(originEpoch: 1, characteristic: .route)
            expect(w.submissions.map(\.label) == ["route-0", "gps-3"], "latest GPS recovers first")
            expect(w.nowMs > 2500, "this mitigation cannot turn a delayed-ACK scenario green")
            w.callback(originEpoch: 1, characteristic: .gpsPosition)
            expect(w.submissions.last!.label == "route-2", "normal route recovery")
        }
        run("contract/lost callback quarantines writer rather than inventing completion") {
            let w = FakeATT(); _ = w.queue.enqueueLatestRouteSnapshot(route(1)); w.flush()
            _ = w.queue.enqueueCoalescing(gps(2), prioritized: true)
            w.timeout(localID: w.pending!.id); w.flush()
            expect(w.quarantined && w.submissions.count == 1, "no unsafe retry/new ATT")
        }
        run("contract/stale epoch and wrong characteristic callbacks are ignored") {
            let w = FakeATT(); _ = w.queue.enqueueLatestRouteSnapshot(route(1)); w.flush()
            w.callback(originEpoch: 0, characteristic: .route)
            w.callback(originEpoch: 1, characteristic: .gpsPosition)
            expect(w.ignored == 2 && w.pending != nil, "identity mismatch")
        }
        run("contract/old timeout and old-connection callback cannot complete a new slot") {
            let w = FakeATT(); _ = w.queue.enqueueLatestRouteSnapshot(route(1)); w.flush()
            let oldID = w.pending!.id; w.timeout(localID: oldID); w.reconnect()
            _ = w.queue.enqueueLatestRouteSnapshot(route(2)); w.flush()
            let newID = w.pending!.id
            w.timeout(localID: oldID); w.callback(originEpoch: 1, characteristic: .route)
            expect(w.pending!.id == newID && !w.quarantined, "new slot retained")
        }
        run("contract/replay cancellation removes unsent GPS but does not release ATT") {
            let w = FakeATT(); _ = w.queue.enqueueLatestRouteSnapshot(route(1)); w.flush()
            let id = w.pending!.id
            _ = w.queue.enqueueCoalescing(gps(3), prioritized: true)
            w.queue.removePendingWrites(withCoalescingKey: "renderer.benchmark.sample")
            expect(w.pending!.id == id && w.queue.count == 0, "pending ATT is not cancellable queue data")
            w.callback(originEpoch: 1, characteristic: .route)
            expect(w.submissions.count == 1, "cancelled replay sample never submitted")
        }
        func outcome(_ execution: RendererBenchmarkExecutionOutcome = .completed,
                     cleanup: RendererBenchmarkCleanupOutcome = .restoredCurrent,
                     completed: Int = 12, passed: Int = 12,
                     soakCompleted: Bool = true, soakPassed: Bool = true,
                     failures: [RendererBenchmarkGateFailure] = []) -> RendererBenchmarkTerminalOutcome {
            RendererBenchmarkTerminalOutcome(schema: 1, execution: execution, cleanup: cleanup,
                expectedComparisons: 12, completedComparisons: completed, passedComparisons: passed,
                soakCompleted: soakCompleted, soakPassed: soakPassed, failures: failures,
                interruptionReason: nil)
        }
        run("outcome/all comparisons + soak + restoration required") {
            expect(outcome().automatedPassed, "complete success")
            expect(!outcome(completed: 0, passed: 0).automatedPassed, "no vacuous allSatisfy")
            expect(!outcome(completed: 11, passed: 11).automatedPassed, "missing comparison")
            expect(!outcome(soakCompleted: false, soakPassed: false).automatedPassed, "missing soak")
            expect(!outcome(soakPassed: false).automatedPassed, "failed soak")
            expect(!outcome(cleanup: .failed).automatedPassed, "cleanup failure")
        }
        let failures = [
            RendererBenchmarkGateFailure(runId: "rb-test-r-m-3", profile: "medium", repeatNumber: 3,
                soak: false, rawFailure: "gps_packet_gap:4710", observed: 4710, limit: 2500, unit: "ms"),
            RendererBenchmarkGateFailure(runId: "rb-test-r-m-3", profile: "medium", repeatNumber: 3,
                soak: false, rawFailure: "stale_route_marker", observed: 4494, limit: 2500, unit: "ms")]
        run("outcome/Medium repeat3 failure remains failed despite successful High soak") {
            let o = outcome(passed: 11, failures: failures)
            expect(!o.automatedPassed && o.execution == .completed, "completed, not aborted")
            expect(o.details.contains("4710 ms, limit 2500 ms"), "GPS observed/limit")
            expect(o.details.contains("4494 ms, limit 2500 ms"), "marker observed/limit")
            expect(o.details.contains("Medium repeat 3"), "profile/repeat")
        }
        run("outcome/user cancellation differs from transport and lifecycle") {
            expect(RendererBenchmarkStopReason.user.executionOutcome == .userCancelled, "user")
            expect(RendererBenchmarkStopReason.transport.executionOutcome == .transportAborted, "transport")
            expect(RendererBenchmarkStopReason.lifecycle.executionOutcome == .lifecycleCancelled, "lifecycle")
            expect(!outcome(.transportAborted).automatedPassed, "transport not success")
        }
        run("outcome/cleanup failure does not overwrite primary termination or gates") {
            let o = outcome(.userCancelled, cleanup: .failed, passed: 11, failures: failures)
            expect(o.status.contains("Cancelled by user") && o.status.contains("restoration failed"), "both causes")
            expect(o.failures.count == 2, "failures preserved")
        }
        try run("outcome/Codable round trip retains full failure accounting") {
            let o = outcome(passed: 11, failures: failures)
            let encoded = try JSONEncoder().encode(o)
            let decoded = try JSONDecoder().decode(RendererBenchmarkTerminalOutcome.self, from: encoded)
            expect(decoded == o, "round trip")
        }
        run("outcome/unknown gates stay visible without fabricated numbers") {
            let f = RendererBenchmarkGateFailure(runId: "r", profile: "high", repeatNumber: 4,
                soak: true, rawFailure: "new_gate:x", observed: nil, limit: nil, unit: nil)
            expect(f.displayText.contains("new_gate:x"), "unknown retained")
            expect(!f.displayText.contains("limit"), "no invented limit")
        }
        run("clock/firmware marker age uses modular device clock, not app uptime") {
            expect(RendererBenchmarkObservation.markerAgeMs(timestampMs: 6664736,
                receivedAtMs: 6660242, valid: true) == 4494, "evidence age")
            expect(RendererBenchmarkObservation.markerAgeMs(timestampMs: 10,
                receivedAtMs: UInt32.max - 9, valid: true) == 20, "wrap")
            expect(RendererBenchmarkObservation.markerAgeMs(timestampMs: 10,
                receivedAtMs: 20, valid: true) == nil, "backward clock invalid")
            expect(RendererBenchmarkObservation.markerAgeMs(timestampMs: 10,
                receivedAtMs: 0, valid: false) == nil, "invalid marker")
        }
        print("Executed \(count) tests: queue unit tests, synthetic ATT contract models, and outcome/clock unit tests. No CoreBluetooth or radio test was run.")
    }
}
