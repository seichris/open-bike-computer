import Foundation
@main enum DiagnosticsCapturePolicyTests {
    static func main() {
        let id = UUID()
        let request = DiagnosticsCaptureRequest(captureID: id, generation: 1,
            mask: DiagnosticsSchema.mask(for: "ble"), minimumLevel: 0, durationSeconds: 60, budgetBytes: 2048)
        var state = DiagnosticsCapturePolicyState()
        precondition(request.valid)
        precondition(!state.apply(request, now: 100, captureID: UUID()))
        precondition(state.apply(request, now: 100, captureID: id))
        precondition(state.admit(level: "trace", domain: "ble", now: 101, captureID: id, maximumBytes: 768))
        let remaining = state.remainingBytes
        precondition(state.apply(request, now: 120, captureID: id))
        precondition(state.remainingBytes == remaining && state.expiresUptime == 160)
        precondition(!state.admit(level: "debug", domain: "map", now: 120, captureID: id, maximumBytes: 768))
        precondition(state.admit(level: "debug", domain: "ble", now: 130, captureID: id, maximumBytes: 768))
        precondition(!state.admit(level: "trace", domain: "ble", now: 130, captureID: id, maximumBytes: 768))
        precondition(!state.active(now: 161, captureID: id))
        precondition(state.admit(level: "fatal", domain: "boot", now: 190, captureID: id, maximumBytes: 768))
        precondition(!state.admit(level: "surprise", domain: "ble", now: 120, captureID: id, maximumBytes: 768))
        let unsupported = DiagnosticsCaptureRequest(captureID: id, generation: 2,
            mask: UInt32.max, minimumLevel: 0, durationSeconds: 60, budgetBytes: 2048)
        precondition(!unsupported.valid)
        print("Swift bounded diagnostics policy and replay tests passed")
    }
}
