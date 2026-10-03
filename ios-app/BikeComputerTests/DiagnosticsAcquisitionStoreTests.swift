import CryptoKit
import Foundation

@main enum DiagnosticsAcquisitionStoreTests {
    static func appEvidenceTests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticsAcquisitionStore(root: root)
        let capture = UUID(), process = UUID().uuidString.lowercased()
        let path = "\(process)/events-000001.jsonl"
        let bytes = Data("{\"source\":\"ios\",\"processId\":\"\(process)\",\"captureId\":\"\(capture.uuidString.lowercased())\"}\n".utf8)
        let job = try await store.create(deviceDigest: "0123456789abcdef", captureID: capture)
        precondition(job.appEvidence == nil, "legacy receipts do not claim retention")
        do { try await store.retainAppEvidence(job.id, chunks: ["../events-000001.jsonl": bytes]); fatalError("unsafe path retained") }
        catch DiagnosticsAcquisitionStore.Failure.invalidManifest {}
        let other = try await store.create(deviceDigest: job.deviceDigest, captureID: UUID())
        do { try await store.retainAppEvidence(other.id, chunks: [path: bytes]); fatalError("foreign capture retained") }
        catch DiagnosticsAcquisitionStore.Failure.inventoryChanged {}
        do { try await store.retainAppEvidence(job.id, chunks: [path: Data("not-json\n".utf8)]); fatalError("invalid complete record retained") }
        catch DiagnosticsAcquisitionStore.Failure.invalidManifest {}
        try await store.retainAppEvidence(job.id, chunks: [path: bytes])
        let shared = try await store.create(deviceDigest: job.deviceDigest, captureID: capture)
        try await store.retainAppEvidence(shared.id, chunks: [path: bytes])
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("evidence"), includingPropertiesForKeys: nil)
        precondition(files.count == 1, "shared original bytes must be deduplicated")
        let restarted = DiagnosticsAcquisitionStore(root: root)
        let snapshot = try await restarted.exportSnapshot()
        precondition(snapshot.appChunks == [path: bytes])
        // A historical capture with no source does not gain invented evidence.
        try await restarted.retainAppEvidence(other.id, chunks: [:])
        let missing = try await restarted.load(other.id)
        precondition(missing.appEvidence == [])
        let small = DiagnosticsAcquisitionStore(root: root.appendingPathComponent("bounded"), maximumEvidenceBytes: bytes.count - 1)
        let limited = try await small.create(deviceDigest: job.deviceDigest, captureID: capture)
        do { try await small.retainAppEvidence(limited.id, chunks: [path: bytes]); fatalError("app evidence budget exceeded") }
        catch DiagnosticsAcquisitionStore.Failure.storageFull {}
        let limitedReceipt = try await small.load(limited.id)
        precondition(limitedReceipt.appEvidence == nil, "failed cache admission cannot claim retention")
        try Data(repeating: 0, count: bytes.count).write(to: files[0])
        do { _ = try await restarted.exportSnapshot(); fatalError("corrupt app evidence exported") }
        catch DiagnosticsAcquisitionStore.Failure.invalidManifest {}
        try await restarted.interrupt(job.id, cancelled: true)
        try await restarted.interrupt(shared.id, cancelled: true)
        for _ in 0..<17 { _ = try await restarted.create(deviceDigest: job.deviceDigest, captureID: UUID()) }
        _ = try await restarted.create(deviceDigest: job.deviceDigest, captureID: UUID())
        precondition(FileManager.default.fileExists(atPath: files[0].path),
            "evicting one job must preserve bytes referenced by another")
        _ = try await restarted.create(deviceDigest: job.deviceDigest, captureID: UUID())
        precondition(!FileManager.default.fileExists(atPath: files[0].path),
            "evicting the last reference must prune orphaned app evidence")
    }
    static func main() async throws {
        try await appEvidenceTests()
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
        let firstData = Data(repeating: 97, count: 10)
        let secondData = Data(repeating: 98, count: 20)
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let first = DiagnosticsChunkReceipt(bootSequence: 1, chunk: 1, bytes: firstData.count, sha256: digest(firstData))
        let second = DiagnosticsChunkReceipt(bootSequence: 1, chunk: 2, bytes: secondData.count, sha256: digest(secondData))
        _ = try await store.inventory(job.id, deviceDigest: job.deviceDigest, index: Data("original".utf8), chunks: [first, second])
        try await store.verified(job.id, receipt: first, data: firstData)
        do { try await store.finish(job.id); fatalError("partial collection completed") }
        catch DiagnosticsAcquisitionStore.Failure.inventoryChanged {}
        try await store.interrupt(job.id)
        // Recreate the store, not only the in-memory object: process-loss replay.
        let restored = DiagnosticsAcquisitionStore(root: root)
        let initial = try await restored.load(job.id)
        precondition(initial.phase == .partial && initial.verified.count == 1)
        precondition(!initial.canResumeAutomatically(postRideEnabled: true), "legacy partial jobs require explicit retry after process restart")
        var eligibility = initial
        for origin in [DiagnosticsAcquisitionManifest.Origin.manual, .postRide] {
            eligibility.origin = origin
            let failures: [String?] = [nil, "transfer_failed", "wifi_memory", "diagnostics_seal_timeout", "cancelled"]
            for code in failures {
                eligibility.failureCode = code
                precondition(!eligibility.canResumeAutomatically(postRideEnabled: true), "another successful job cannot reopen a failed partial job")
            }
            eligibility.failureCode = "ride_started"
            precondition(eligibility.canResumeAutomatically(postRideEnabled: true), "ride interruption must remain resumable")
            precondition(eligibility.canResumeAutomatically(postRideEnabled: false) == (origin == .manual))
        }
        let retry = try await restored.inventory(job.id, deviceDigest: job.deviceDigest,
            index: Data("newer".utf8), chunks: [second])
        precondition(retry.expected == [first, second])
        precondition(retry.indexData == Data("original".utf8))
        precondition(retry.verified.isEmpty)
        do {
            _ = try await restored.inventory(job.id, deviceDigest: "fedcba9876543210", index: Data(), chunks: [])
            fatalError("wrong device accepted")
        } catch DiagnosticsAcquisitionStore.Failure.inventoryChanged {}
        let replayBytes = try await restored.chunkData(job.id, receipt: first)
        precondition(replayBytes == firstData, "exact bytes must survive process restart")
        do {
            try await restored.verified(job.id, receipt: second, data: firstData)
            fatalError("receipt accepted mismatching bytes")
        } catch DiagnosticsAcquisitionStore.Failure.invalidManifest {}
        try await restored.verified(job.id, receipt: first, data: firstData)
        try await restored.verified(job.id, receipt: first, data: firstData)
        try await restored.verified(job.id, receipt: second, data: secondData)
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
        let exported = try await restored.exportSnapshot()
        precondition(exported.chunks.count == 2 && Set(exported.chunks.values) == Set([firstData, secondData]))
        let cacheFiles = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("evidence"), includingPropertiesForKeys: nil)
        try Data(repeating: 99, count: 10).write(to: cacheFiles.first { $0.lastPathComponent.contains(first.sha256) }!)
        do { _ = try await restored.exportSnapshot(); fatalError("corrupt evidence exported as complete") }
        catch DiagnosticsAcquisitionStore.Failure.invalidManifest {}

        let boundedRoot = root.appendingPathComponent("bounded")
        let bounded = DiagnosticsAcquisitionStore(root: boundedRoot, maximumEvidenceBytes: 10)
        let limited = try await bounded.create(deviceDigest: job.deviceDigest, captureID: nil)
        _ = try await bounded.inventory(limited.id, deviceDigest: job.deviceDigest, index: Data(), chunks: [first, second])
        try await bounded.verified(limited.id, receipt: first, data: firstData)
        try await bounded.verified(limited.id, receipt: first, data: firstData)
        do { try await bounded.verified(limited.id, receipt: second, data: secondData); fatalError("evidence budget exceeded") }
        catch DiagnosticsAcquisitionStore.Failure.storageFull {}
        let boundedReceipt = try await bounded.load(limited.id)
        let boundedBytes = try await bounded.chunkData(limited.id, receipt: first)
        precondition(boundedReceipt.verified == [first.key] && boundedBytes == firstData,
            "a full evidence store must preserve existing bytes and partial receipts")
        print("Diagnostics acquisition persistence, cutoff, identity and completeness tests passed")
    }
}
