import Foundation

@main
struct RendererBenchmarkWindowAdmissionTests {
    enum Failure: Error { case limited, network, stopped }

    @MainActor
    static func main() async throws {
        var now: TimeInterval = 10
        var requestTimes: [TimeInterval] = []
        var stopped = false
        var stopWhileSleeping = false
        let admission = RendererBenchmarkWindowAdmission(
            now: { now },
            sleep: { delay in
                precondition(delay > 0)
                now += delay
                if stopWhileSleeping { stopped = true }
            }
        )
        func check() throws { if stopped { throw Failure.stopped } }
        func retryable(_ error: Error) -> Bool {
            if case Failure.limited = error { return true }
            return false
        }
        func begin() async throws -> UInt32 {
            try await admission.execute(check: check, isRateLimited: retryable) {
                requestTimes.append(now)
                return UInt32(requestTimes.count)
            }
        }
        // Fast setup, warm-up and cleanup responses must never bypass pacing.
        let setup = try await begin()
        let warmup = try await begin()
        let cleanup = try await begin()
        precondition([setup, warmup, cleanup] == [1, 2, 3])
        for pair in zip(requestTimes, requestTimes.dropFirst()) {
            precondition(pair.1 - pair.0 >= 1.099)
        }
        var attempts = 0
        var retryTimes: [TimeInterval] = []
        let accepted = try await admission.execute(check: check, isRateLimited: retryable) {
            retryTimes.append(now)
            attempts += 1
            if attempts == 1 { throw Failure.limited }
            return 42
        }
        precondition(accepted == 42 && attempts == 2)
        precondition(retryTimes[1] - retryTimes[0] >= 1.099)

        attempts = 0
        do {
            _ = try await admission.execute(check: check, isRateLimited: retryable) {
                attempts += 1
                throw Failure.limited
            }
            preconditionFailure("permanent rejection must fail")
        } catch Failure.limited {}
        precondition(attempts == RendererBenchmarkWindowAdmission.maximumAttempts)

        attempts = 0
        do {
            _ = try await admission.execute(check: check, isRateLimited: retryable) {
                attempts += 1
                throw Failure.network
            }
            preconditionFailure("ambiguous POST must fail without retry")
        } catch Failure.network {}
        precondition(attempts == 1)

        let beforeStop = requestTimes.count
        stopWhileSleeping = true
        do {
            _ = try await begin()
            preconditionFailure("Stop during pacing must prevent the POST")
        } catch Failure.stopped {}
        precondition(requestTimes.count == beforeStop)

        precondition(RendererBenchmarkWindowAdmission.isRetryable(
            status: 429, code: "renderer_window_rate_limited"
        ))
        for status in [400, 401, 403, 409, 500, 503] {
            precondition(!RendererBenchmarkWindowAdmission.isRetryable(
                status: status, code: "renderer_window_rate_limited"
            ))
        }
        for code in [nil, "metrics_rate_limited", "session_revoked"] as [String?] {
            precondition(!RendererBenchmarkWindowAdmission.isRetryable(status: 429, code: code))
        }
        print("RendererBenchmarkWindowAdmissionTests passed")
    }
}
