import Foundation
import Combine
let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
struct StubPairing: Equatable { let certificateSHA256 = "synthetic-recipient"; func valid() -> Bool { true } }
final class RideDiagnosticsRecorder { var deleted = false; func deleteLocalLogs() throws { deleted = true } }
final class BLEManager {}
typealias DiagnosticsBrokerPairingFixture = StubPairing
@MainActor final class DiagnosticsCollectionCoordinator {
    static let shared = DiagnosticsCollectionCoordinator()
    @Published var manifest: DiagnosticsAcquisitionManifest?
    let store = DiagnosticsAcquisitionStore(root: testRoot.appendingPathComponent("acquisitions"))
    var exportCalls = 0
    var release: CheckedContinuation<Void, Never>?
    var suspendFirst = true
    var deleting = false
    var operationGeneration: UInt64 = 0
    var selectionTask: Task<Void, Never>?, rideJournalTask: Task<Void, Never>?, task: Task<Void, Never>?
    var rideContexts: [String: UUID] = [:]
    var status = ""
    func exportForCodex(recorder: RideDiagnosticsRecorder, requiring: UUID?) async throws -> URL {
        exportCalls += 1
        if suspendFirst { suspendFirst = false; await withCheckedContinuation { release = $0 } }
        let file = testRoot.appendingPathComponent(UUID().uuidString)
        try Data("synthetic-bundle".utf8).write(to: file)
        return file
    }
    // COORDINATOR_DELETE
}
@MainActor final class DiagnosticsBrokerClient {
    static var shared: DiagnosticsBrokerClient!
    var isPaired = true, deleting = false, active = true
    var status = ""
    weak var recorder: RideDiagnosticsRecorder?
    weak var bleManager: BLEManager?
    var pairing: StubPairing? = StubPairing()
    var exportTask: Task<Void, Never>?, reconciliationTask: Task<Void, Never>?, loop: Task<Void, Never>?
    var loopGeneration: UInt64 = 0
    var cancellables = Set<AnyCancellable>()
    let root: URL
    init(root: URL) { self.root = root }
    func setActive(_ value: Bool) { active = value }
    // CLIENT_METHODS
}
@main struct Tests {
    @MainActor static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("lifecycle condition timed out")
    }
    @MainActor static func main() async throws {
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let coordinator = DiagnosticsCollectionCoordinator.shared
        func complete() async throws -> DiagnosticsAcquisitionManifest {
            let m = try await coordinator.store.create(deviceDigest: "0123456789abcdef", captureID: UUID())
            _ = try await coordinator.store.inventory(m.id, deviceDigest: m.deviceDigest, index: Data(), chunks: [])
            try await coordinator.store.finish(m.id)
            return try await coordinator.store.manifests().first(where: { $0.id == m.id })!
        }
        let one = try await complete()
        let recorder = RideDiagnosticsRecorder(), ble = BLEManager()
        let root = testRoot.appendingPathComponent("outbox")
        let client = DiagnosticsBrokerClient(root: root)
        DiagnosticsBrokerClient.shared = client
        client.configure(recorder: recorder, bleManager: ble)
        try await waitFor { coordinator.release != nil }
        let two = try await complete()
        coordinator.manifest = one
        coordinator.manifest = two
        coordinator.release!.resume(); coordinator.release = nil
        let recipient = root.appendingPathComponent("synthetic-recipient")
        func zip(_ id: UUID) -> URL { recipient.appendingPathComponent(id.uuidString.lowercased() + ".zip") }
        try await waitFor { FileManager.default.fileExists(atPath: zip(one.id).path) && FileManager.default.fileExists(atPath: zip(two.id).path) && client.exportTask == nil && client.reconciliationTask == nil }
        precondition(coordinator.exportCalls == 2, "a completion during export remains durable intent")
        for i in 0..<6 { try Data([0]).write(to: recipient.appendingPathComponent("filler-\(i).zip")) }
        let three = try await complete()
        coordinator.manifest = three
        try await waitFor { client.exportTask == nil && client.reconciliationTask == nil }
        precondition(!FileManager.default.fileExists(atPath: zip(three.id).path))
        try FileManager.default.removeItem(at: recipient.appendingPathComponent("filler-0.zip"))
        client.reconcileCompletedHandoffs()
        try await waitFor { FileManager.default.fileExists(atPath: zip(three.id).path) && client.exportTask == nil && client.reconciliationTask == nil }
        try DiagnosticsHandoffReceipt.acknowledge(one.id, sha256: String(repeating: "a", count: 64), root: recipient)
        try FileManager.default.removeItem(at: zip(one.id))
        let restarted = DiagnosticsBrokerClient(root: root)
        DiagnosticsBrokerClient.shared = restarted
        restarted.configure(recorder: recorder, bleManager: ble)
        try await waitFor { restarted.reconciliationTask == nil }
        precondition(coordinator.exportCalls == 3 && !FileManager.default.fileExists(atPath: zip(one.id).path))
        let journal = DiagnosticsBrokerCommandJournal(root: recipient.appendingPathComponent("commands.json"))
        let commandID = UUID()
        try await journal.save(.init(id: commandID, state: "interrupted", code: "execution_started"),
            expiresAt: Int64(Date().timeIntervalSince1970) + 60)
        try await coordinator.deleteRetainedDiagnostics(recorder: recorder)
        let remaining = try await coordinator.store.exportSnapshot()
        precondition(recorder.deleted && remaining.manifests.isEmpty && remaining.appChunks.isEmpty)
        let replay = try await journal.existing(commandID)
        precondition(replay?.code == "execution_started", "deleting logs must preserve command anti-replay state")
        let retainedNames = try FileManager.default.contentsOfDirectory(atPath: recipient.path)
        precondition(retainedNames == ["commands.json"], "only control receipts may remain after deletion")
        print("Completed-acquisition startup, busy export, full-outbox recovery, receipt replay and coordinated deletion passed")
    }
}
