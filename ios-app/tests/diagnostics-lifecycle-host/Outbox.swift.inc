import Foundation
import CryptoKit
struct Pairing: Equatable {}
@MainActor enum DiagnosticsBrokerHTTP {
    enum Failure: Error { case uploadRejected(Int), authorizationDenied, inboxFull, unavailable }
    static var rejected: UUID?
    static var failure: Failure?
    static var attempts: [UUID] = []
    static var badReceipt = false
    static func request(_ pairing: Pairing, method: String, path: String, file: URL, digest: String) async throws -> Data {
        let id = UUID(uuidString: path.components(separatedBy: "/").last!)!
        attempts.append(id)
        if id == rejected { throw Failure.uploadRejected(400) }
        if let failure { throw failure }
        return try JSONSerialization.data(withJSONObject: ["schema": 2, "id": id.uuidString,
            "sha256": badReceipt ? String(repeating: "0", count: 64) : digest, "accepted": true])
    }
}
@MainActor final class Client {
    let root: URL
    var rejectedHandoffCount = 0
    init(_ root: URL) { self.root = root }
    func recipientRoot(_ pairing: Pairing) -> URL { root }
    func checkOwner(_ pairing: Pairing, generation: UInt64) throws { try Task.checkCancellation() }
    // UPLOAD_METHOD
}
@main struct Tests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        func path(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased() + ".zip") }
        func put(_ id: UUID) throws { try Data("synthetic ZIP body".utf8).write(to: path(id)) }
        try put(a); try put(b)
        DiagnosticsBrokerHTTP.rejected = a
        let client = Client(root)
        try await client.uploadPending(Pairing(), generation: 1)
        precondition(DiagnosticsBrokerHTTP.attempts == [a, b])
        precondition(FileManager.default.fileExists(atPath: path(a).path))
        precondition(!FileManager.default.fileExists(atPath: path(b).path))
        let hash = SHA256.hash(data: try Data(contentsOf: path(a))).map { String(format: "%02x", $0) }.joined()
        let quarantined = try DiagnosticsHandoffRejection.contains(a, sha256: hash, root: root)
        precondition(quarantined)
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("delivered-" + a.uuidString.lowercased() + ".txt").path))
        try put(b)
        DiagnosticsBrokerHTTP.attempts = []
        try await Client(root).uploadPending(Pairing(), generation: 2)
        precondition(DiagnosticsBrokerHTTP.attempts == [b], "relaunch must skip unchanged rejected bytes and deliver later ZIPs")
        DiagnosticsBrokerHTTP.rejected = nil
        for failure in [DiagnosticsBrokerHTTP.Failure.unavailable, .inboxFull, .authorizationDenied] {
            try put(b); DiagnosticsBrokerHTTP.failure = failure
            do { try await client.uploadPending(Pairing(), generation: 2); preconditionFailure("expected transient/auth/capacity error") }
            catch is DiagnosticsBrokerHTTP.Failure {}
            precondition(FileManager.default.fileExists(atPath: path(b).path))
            let bodyHash = SHA256.hash(data: try Data(contentsOf: path(b))).map { String(format: "%02x", $0) }.joined()
            let quarantined = try DiagnosticsHandoffRejection.contains(b, sha256: bodyHash, root: root)
            precondition(!quarantined)
        }
        DiagnosticsBrokerHTTP.failure = nil; DiagnosticsBrokerHTTP.badReceipt = true
        do { try await client.uploadPending(Pairing(), generation: 2); preconditionFailure("mismatched digest acknowledged") }
        catch DiagnosticsAcquisitionStore.Failure.invalidManifest {}
        precondition(FileManager.default.fileExists(atPath: path(b).path))
        print("Permanent upload rejection survives restart, preserves rejected ZIP and permits later delivery; auth/capacity/transient and receipt validation remain strict")
    }
}
