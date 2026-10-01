import Foundation

@main enum DiagnosticsAcquisitionStoreTests {
    static func main() async throws {
        for phase in [DiagnosticsAcquisitionManifest.Phase.requested, .collecting, .partial] {
            precondition(phase.canResumeAutomatically)
        }
        for phase in [DiagnosticsAcquisitionManifest.Phase.complete, .cancelled] {
            precondition(!phase.canResumeAutomatically, "terminal jobs must not acquire a new cutoff automatically")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticsAcquisitionStore(root: root)
        let job = try await store.create(deviceDigest: "0123456789abcdef", captureID: UUID())
        let replay = try await store.create(deviceDigest: job.deviceDigest, captureID: job.captureID, id: job.id)
        precondition(replay == job, "ride-end retries must preserve the same request identity")
        do {
            _ = try await store.create(deviceDigest: "fedcba9876543210", captureID: job.captureID, id: job.id)
            fatalError("request identity was reused for another device")
        } catch DiagnosticsAcquisitionStore.Failure.inventoryChanged {}
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
        let terminalReplay = try await restored.create(deviceDigest: job.deviceDigest, captureID: job.captureID, id: job.id)
        precondition(terminalReplay.deliveryComplete, "replay cannot replace a completed cutoff")
        let laterRide = try await restored.create(deviceDigest: job.deviceDigest, captureID: job.captureID)
        var postRide = laterRide
        postRide.origin = .postRide
        precondition(postRide.canResumeAutomatically(postRideEnabled: true))
        precondition(!postRide.canResumeAutomatically(postRideEnabled: false))
        postRide.phase = .cancelled
        precondition(!postRide.canResumeAutomatically(postRideEnabled: true))
        precondition(laterRide.id != job.id && laterRide.indexData == nil,
            "a new ride needs its own cutoff even during an asynchronous capture rotation")
        for _ in 0..<17 { _ = try await restored.create(deviceDigest: job.deviceDigest, captureID: UUID()) }
        do {
            _ = try await restored.create(deviceDigest: "invalid", captureID: nil)
            fatalError("invalid request was admitted")
        } catch DiagnosticsAcquisitionStore.Failure.invalidManifest {}
        let originalReceipt = try await restored.load(job.id)
        precondition(originalReceipt.deliveryComplete, "invalid admission must not prune a completed receipt")
        print("Diagnostics acquisition persistence, cutoff, identity and completeness tests passed")
    }
}
