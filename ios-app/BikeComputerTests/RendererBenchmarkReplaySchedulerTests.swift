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
        // Physical evidence exposed 30-50 ms of accumulated delay per tick.
        // Repeat a two-minute run with 40 ms wake-up jitter and 3 ms callback
        // work: the deadline must remain on the original one-second grid.
        let driftClock = ManualClock()
        var driftTicks = 0
        let driftScheduler = RendererBenchmarkReplayScheduler(
            now: { driftClock.now }, sleep: { try await driftClock.sleep($0) }
        )
        driftScheduler.start { lateness in
            precondition(lateness == 40)
            driftTicks += 1
            driftClock.now += 0.003
        }
        await waitFor { driftClock.pending.count == 1 }
        for tick in 1...120 {
            let scheduledAt = driftClock.now + driftClock.waits.last!
            precondition(abs(scheduledAt - Double(tick)) < 0.000_001,
                         "callback jitter must not shift the next 1 Hz deadline")
            driftClock.wake(at: Double(tick) + 0.04)
            await waitFor { driftTicks == tick && driftClock.pending.count == 1 }
        }
        precondition(driftTicks == 120 && driftClock.now < 120.05)
        driftScheduler.stop()
        driftClock.wake(at: 121)

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
        precondition(clock.waits.last == 0.5,
                     "a missed slot resumes at the next original deadline")
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

        let slowClock = ManualClock()
        var slowTicks = 0
        let slowScheduler = RendererBenchmarkReplayScheduler(
            now: { slowClock.now }, sleep: { try await slowClock.sleep($0) }
        )
        slowScheduler.start { _ in
            slowTicks += 1
            slowClock.now += 2.25
        }
        await waitFor { slowClock.pending.count == 1 }
        slowClock.wake(at: 0.5)
        await waitFor { slowClock.pending.count == 1 }
        precondition(slowTicks == 0, "an early wake never emits a sample")
        slowClock.wake(at: 1)
        await waitFor { slowTicks == 1 && slowClock.pending.count == 1 }
        precondition(slowClock.waits.last == 0.75,
                     "slow callback skips elapsed slots without a catch-up burst")
        slowScheduler.stop()
        slowClock.wake(at: 4)

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
