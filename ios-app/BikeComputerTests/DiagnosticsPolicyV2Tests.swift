import Foundation
@main struct DiagnosticsPolicyV2Tests {
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let policy = try DiagnosticsCapturePolicyV2(profile: "ble-navigation", durationSeconds: 60, now: start)
        assert(policy.valid)
        let command = try policy.command()
        assert(command.hasPrefix("DTRNcapture|2|"))
        assert(policy.effectiveLevels(at: start)["ble"] == "trace")
        assert(policy.effectiveLevels(at: start.addingTimeInterval(60)).isEmpty)
        var admission = DiagnosticsAdmissionV2()
        assert(!admission.admit(level: "trace", domain: "ble", estimatedBytes: 100, now: start, uptime: 0))
        admission.policy = policy
        for _ in 0..<20 { assert(admission.admit(level: "trace", domain: "ble", estimatedBytes: 100, now: start, uptime: 0)) }
        assert(!admission.admit(level: "trace", domain: "ble", estimatedBytes: 100, now: start, uptime: 0))
        assert(admission.admit(level: "error", domain: "ble", estimatedBytes: 768, now: start, uptime: 0))
        assert(admission.admit(level: "trace", domain: "ble", estimatedBytes: 100, now: start, uptime: 1))
        let decoded = try JSONDecoder().decode(DiagnosticsCapturePolicyV2.self, from: JSONEncoder().encode(policy))
        assert(decoded == policy)
        print("diagnostics v2 policy tests passed")
    }
}
