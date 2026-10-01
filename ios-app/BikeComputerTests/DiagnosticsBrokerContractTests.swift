import Foundation

@main enum DiagnosticsBrokerContractTests {
    static func main() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func pairing(_ origin: String, lifetime: Int64 = 3600) -> DiagnosticsBrokerPairing {
            DiagnosticsBrokerPairing(schema: 2, origin: origin,
                certificateSHA256: String(repeating: "a", count: 64),
                token: String(repeating: "b", count: 64), expiresAt: 1_800_000_000 + lifetime)
        }
        precondition(pairing("https://192.168.1.50:8443").valid(at: date))
        precondition(pairing("https://127.0.0.1:8443").valid(at: date))
        for origin in ["http://192.168.1.50:8443", "https://8.8.8.8:8443",
                       "https://example.com:8443", "https://192.168.1.50",
                       "https://192.168.1.50:8443/path", "https://192.168.1.50:8443?token=x",
                       "https://user@192.168.1.50:8443", "https://192.168.01.50:8443"] {
            precondition(!pairing(origin).valid(at: date), origin)
        }
        precondition(!pairing("https://192.168.1.50:8443", lifetime: 0).valid(at: date))
        precondition(!pairing("https://192.168.1.50:8443", lifetime: 100000).valid(at: date))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("commands.json")
        let first = DiagnosticsBrokerCommandJournal(root: url)
        let id = UUID()
        try await first.save(.init(id: id, state: "interrupted", code: "execution_started"))
        let reloaded = DiagnosticsBrokerCommandJournal(root: url)
        let pending = try await reloaded.existing(id)
        precondition(pending?.state == "interrupted")
        try await first.save(.init(id: id, state: "accepted", code: "phone_marker_saved"))
        let completed = try await reloaded.existing(id)
        precondition(completed?.code == "phone_marker_saved")
        for _ in 0..<99 { try await first.save(.init(id: UUID(), state: "accepted", code: "done")) }
        do {
            try await first.save(.init(id: UUID(), state: "accepted", code: "done"))
            preconditionFailure("journal must not evict still-valid replay receipts")
        } catch DiagnosticsAcquisitionStore.Failure.storageFull { }
        let original = try await reloaded.existing(id)
        precondition(original != nil)
        let bytes = try Data(contentsOf: url)
        do {
            try await first.save(.init(id: id, state: "bad", code: "not diagnostic text"))
            preconditionFailure("invalid receipt should fail")
        } catch DiagnosticsAcquisitionStore.Failure.invalidManifest { }
        let afterFailure = try Data(contentsOf: url)
        precondition(afterFailure == bytes)
        print("Swift broker pairing, bounded journal and process-loss replay tests passed")
    }
}
