#if DEBUG || HOST_TESTING
import Foundation

/// One cancellable cadence owner. No selector or run-loop registration is
/// required when replay starts from an asynchronous HTTPS preflight.
@MainActor
final class RendererBenchmarkReplayScheduler {
    typealias Sleep = @MainActor (TimeInterval) async throws -> Void
    private let interval: TimeInterval
    private let now: @MainActor () -> TimeInterval
    private let sleep: Sleep
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    var isScheduled: Bool { task != nil }

    init(
        interval: TimeInterval = 1,
        now: @escaping @MainActor () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        sleep: @escaping Sleep = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        precondition(interval.isFinite && interval > 0)
        self.interval = interval
        self.now = now
        self.sleep = sleep
    }

    deinit { task?.cancel() }

    func start(tick: @escaping @MainActor (Int) -> Void) {
        stop()
        let activeGeneration = generation
        let firstDeadline = now() + interval
        let interval = interval
        let now = now
        let sleep = sleep
        task = Task { @MainActor [weak self] in
            var deadline = firstDeadline
            while !Task.isCancelled {
                do {
                    try await sleep(max(0, deadline - now()))
                } catch {
                    if self?.generation == activeGeneration {
                        self?.task = nil
                    }
                    return
                }
                guard !Task.isCancelled,
                      let self, self.generation == activeGeneration else {
                    return
                }
                let actual = now()
                guard actual >= deadline else { continue }
                let latenessMs = Int(max(0, (actual - deadline) * 1_000).rounded())
                tick(latenessMs)
                // Coalesce missed ticks, never send a catch-up burst. Account
                // for time spent inside the callback before sleeping again.
                deadline = max(deadline + interval, now() + interval)
            }
        }
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}
#endif
