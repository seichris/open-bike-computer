import Foundation

@MainActor
private final class ManualClock {
    var now: TimeInterval = 0
    var waits: [TimeInterval] = []
    var pending: [CheckedContinuation<Void, Error>] = []

    func sleep(_ seconds: TimeInterval) async throws {
        waits.append(seconds)
        try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func wake(at time: TimeInterval) {
        now = time
        pending.removeFirst().resume()
    }
}

@main
struct RendererBenchmarkReplaySchedulerTests {
    @MainActor
    static func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("async replay did not make progress")
    }

    @MainActor
    static func main() async {
        let clock = ManualClock()
        var callbacks: [Int] = []
        let scheduler = RendererBenchmarkReplayScheduler(
            now: { clock.now }, sleep: { try await clock.sleep($0) }
        )
        // Start after an async boundary, as the secure HTTP preflight does.
        await Task.yield()
        scheduler.start { callbacks.append($0) }
        await waitFor { clock.pending.count == 1 }
        precondition(clock.waits == [1])
        clock.wake(at: 1)
        await waitFor { clock.pending.count == 1 && callbacks.count == 1 }
        precondition(callbacks == [0])
        clock.wake(at: 2)
        await waitFor { clock.pending.count == 1 && callbacks.count == 2 }
        precondition(callbacks == [0, 0])

        // A late callback produces one sample, not a burst of stale samples.
        clock.wake(at: 5.5)
        await waitFor { clock.pending.count == 1 && callbacks.count == 3 }
        precondition(callbacks.last == 2_500)
        precondition(clock.waits.last == 1)
        scheduler.stop()
        precondition(!scheduler.isScheduled)
        // Stop/restart before the old sleep returns must not invoke the old tick.
        scheduler.start { callbacks.append(10_000 + $0) }
        await waitFor { clock.pending.count == 2 }
        clock.wake(at: 6.5)
        for _ in 0..<20 { await Task.yield() }
        precondition(callbacks.count == 3)
        clock.wake(at: 6.5)
        await waitFor { callbacks.count == 4 && clock.pending.count == 1 }
        precondition(callbacks.last == 10_000)
        scheduler.stop()
        clock.wake(at: 7.5)
        for _ in 0..<20 { await Task.yield() }
        precondition(callbacks.count == 4)

        // The sleeping task must not retain its owner indefinitely.
        var owner: RendererBenchmarkReplayScheduler? = .init(
            now: { clock.now }, sleep: { try await clock.sleep($0) }
        )
        weak var weakOwner = owner
        owner?.start { _ in preconditionFailure("released owner emitted a tick") }
        await waitFor { clock.pending.count == 1 }
        owner = nil
        precondition(weakOwner == nil)
        clock.wake(at: 8.5)

        // Exercise real async sleep too, without pumping a Foundation run loop.
        let real = RendererBenchmarkReplayScheduler(interval: 0.01)
        var realTicks = 0
        real.start { _ in realTicks += 1 }
        try! await Task.sleep(nanoseconds: 120_000_000)
        precondition(realTicks >= 2)
        real.stop()
        let stoppedCount = realTicks
        try! await Task.sleep(nanoseconds: 30_000_000)
        precondition(realTicks == stoppedCount)
        print("RendererBenchmarkReplaySchedulerTests passed")
    }
}
