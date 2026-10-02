#if DEBUG || HOST_TESTING
import Foundation

/// Owned by the sweep's single serial task, including its cleanup path.
/// Firmware accepts window POSTs at most once per second. Start the cooldown
/// at response completion, conservatively later than firmware admission.
@MainActor
final class RendererBenchmarkWindowAdmission {
    private let now: @MainActor () -> TimeInterval
    private let sleep: @MainActor (TimeInterval) async throws -> Void
    private var nextAllowedAt: TimeInterval = 0
    static let minimumInterval: TimeInterval = 1.1
    static let maximumAttempts = 3

    init(
        now: @escaping @MainActor () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        sleep: @escaping @MainActor (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.now = now
        self.sleep = sleep
    }

    nonisolated static func isRetryable(status: Int, code: String?) -> Bool {
        // This response is issued before the firmware queues a window. Never
        // automatically replay an ambiguously completed POST/network timeout.
        status == 429 && code == "renderer_window_rate_limited"
    }

    func execute(
        check: @MainActor () throws -> Void,
        isRateLimited: @MainActor (Error) -> Bool,
        operation: @MainActor () async throws -> UInt32
    ) async throws -> UInt32 {
        for attempt in 1...Self.maximumAttempts {
            try Task.checkCancellation()
            try check()
            while now() < nextAllowedAt {
                try await sleep(max(0, nextAllowedAt - now()))
                try Task.checkCancellation()
                try check()
            }
            defer { nextAllowedAt = now() + Self.minimumInterval }
            do {
                return try await operation()
            } catch {
                guard attempt < Self.maximumAttempts, isRateLimited(error) else {
                    throw error
                }
            }
        }
        preconditionFailure("bounded window admission must return or throw")
    }
}
#endif
