import Foundation

@main enum DiagnosticsAcquisitionStoreTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticsAcquisitionStore(root: root)
        let job = try await store.create(deviceDigest: "0123456789abcdef", captureID: UUID())
        let first = DiagnosticsChunkReceipt(bootSequence: 1, chunk: 1, bytes: 10, sha256: String(repeating: "a", count: 64))
        let second = DiagnosticsChunkReceipt(bootSequence: 1, chunk: 2, bytes: 20, sha256: String(repeating: "b", count: 64))
        _ = try await store.inventory(job.id, deviceDigest: job.deviceDigest, index: Data("original".utf8), chunks: [first, second])
        try await store.verified(job.id, receipt: first)
        do { try await store.finish(job.id); fatalError("partial collection completed") }
        catch DiagnosticsAcquisitionStore.Failure.inventoryChanged {}
        try await store.interrupt(job.id)
        // Recreate the store, not only the in-memory object: process-loss replay.
        let restored = DiagnosticsAcquisitionStore(root: root)
        let initial = try await restored.load(job.id)
        precondition(initial.phase == .partial && initial.verified.count == 1)
        let retry = try await restored.inventory(job.id, deviceDigest: job.deviceDigest,
            index: Data("newer".utf8), chunks: [second])
        precondition(retry.expected == [first, second])
        precondition(retry.indexData == Data("original".utf8))
        precondition(retry.verified.isEmpty)
        do {
            _ = try await restored.inventory(job.id, deviceDigest: "fedcba9876543210", index: Data(), chunks: [])
            fatalError("wrong device accepted")
        } catch DiagnosticsAcquisitionStore.Failure.inventoryChanged {}
        try await restored.verified(job.id, receipt: first)
        try await restored.verified(job.id, receipt: first)
        try await restored.verified(job.id, receipt: second)
        try await restored.finish(job.id)
        try await restored.interrupt(job.id, code: "cleanup_failed")
        let complete = try await restored.load(job.id)
        precondition(complete.deliveryComplete && complete.verified.count == 2)
        let bad = DiagnosticsChunkReceipt(bootSequence: 0, chunk: 1, bytes: 10, sha256: String(repeating: "a", count: 64))
        let invalid = try await restored.create(deviceDigest: job.deviceDigest, captureID: nil)
        do {
            _ = try await restored.inventory(invalid.id, deviceDigest: job.deviceDigest, index: Data(), chunks: [bad])
            fatalError("invalid inventory accepted")
        } catch DiagnosticsAcquisitionStore.Failure.invalidManifest {}
        let untouched = try await restored.load(invalid.id)
        precondition(untouched.indexData == nil)
        print("Diagnostics acquisition persistence, cutoff, identity and completeness tests passed")
    }
}
