import CryptoKit
import Foundation

@main enum DiagnosticsAcquisitionStoreTests {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func receipt(_ data: Data, chunk: UInt32 = 1) -> DiagnosticsChunkReceipt {
        .init(bootSequence: 1, chunk: chunk, bytes: data.count, sha256: digest(data))
    }

    static func firmwareJob(_ store: DiagnosticsAcquisitionStore, data: Data,
                            phase: DiagnosticsAcquisitionManifest.Phase) async throws -> UUID {
        let job = try await store.create(deviceDigest: "0123456789abcdef", captureID: nil)
        let item = receipt(data)
        _ = try await store.inventory(job.id, deviceDigest: job.deviceDigest, index: Data(), chunks: [item])
        try await store.verified(job.id, receipt: item, data: data)
        if phase == .complete { try await store.finish(job.id) }
        if phase == .partial || phase == .cancelled {
            try await store.interrupt(job.id, cancelled: phase == .cancelled)
        }
        return job.id
    }

    static func cacheSnapshot(_ root: URL) throws -> [String: Data] {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: Data] = [:]
        for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(file.path.dropFirst(root.path.count))] = try Data(contentsOf: file)
        }
        return result
    }

    static func bytePressureTests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticsAcquisitionStore(root: root, maximumEvidenceBytes: 110)
        let oldComplete = try await firmwareJob(store, data: Data(repeating: 1, count: 30), phase: .complete)
        let oldCancelled = try await firmwareJob(store, data: Data(repeating: 2, count: 20), phase: .cancelled)
        let youngerComplete = try await firmwareJob(store, data: Data(repeating: 8, count: 10), phase: .complete)
        let partialBytes = Data(repeating: 3, count: 20)
        let partial = try await firmwareJob(store, data: partialBytes, phase: .partial)
        let active = try await store.create(deviceDigest: "0123456789abcdef", captureID: nil)
        let first = Data(repeating: 4, count: 30), second = Data(repeating: 5, count: 40)
        _ = try await store.inventory(active.id, deviceDigest: active.deviceDigest, index: Data(),
            chunks: [receipt(first), receipt(second, chunk: 2)])
        try await store.verified(active.id, receipt: receipt(first), data: first)
        let before = try await store.manifests()
        precondition(before.count == 5, "reproduce byte pressure well below the 20-job limit")
        try await store.verified(active.id, receipt: receipt(second, chunk: 2), data: second)
        let restarted = DiagnosticsAcquisitionStore(root: root, maximumEvidenceBytes: 110)
        let remaining = try await restarted.manifests()
        precondition(Set(remaining.map(\.id)) == Set([youngerComplete, partial, active.id]),
            "reclaim oldest terminal jobs while preserving partial and collecting jobs")
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent(oldComplete.uuidString.lowercased() + ".json").path))
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent(oldCancelled.uuidString.lowercased() + ".json").path))
        let retainedPartial = try await restarted.chunkData(partial, receipt: receipt(partialBytes))
        let retainedFirst = try await restarted.chunkData(active.id, receipt: receipt(first))
        precondition(retainedPartial == partialBytes && retainedFirst == first,
            "eviction cannot discard an incomplete job's already verified prefix")
        try await restarted.finish(active.id)
        let exported = try await restarted.exportSnapshot()
        precondition(exported.chunks.values.reduce(0) { $0 + $1.count } == 100,
            "stop reclamation as soon as the request fits; preserve younger terminal jobs")

        // A completed body shared only by terminal jobs frees zero bytes when
        // the first reference is evicted; both owners must go to admit 60 bytes.
        let sharedRoot = root.appendingPathComponent("shared")
        let sharedStore = DiagnosticsAcquisitionStore(root: sharedRoot, maximumEvidenceBytes: 100)
        let shared = Data(repeating: 6, count: 50)
        _ = try await firmwareJob(sharedStore, data: shared, phase: .complete)
        _ = try await firmwareJob(sharedStore, data: shared, phase: .complete)
        let newer = try await firmwareJob(sharedStore, data: Data(repeating: 7, count: 60), phase: .complete)
        let sharedRemaining = try await sharedStore.manifests()
        let sharedExport = try await sharedStore.exportSnapshot()
        precondition(sharedRemaining.map(\.id) == [newer] && sharedExport.chunks.count == 1,
            "shared firmware evidence is reclaimed only after its last owner")
    }

    static func appPressureAndOversizeTests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = UUID(), process = UUID().uuidString.lowercased()
        func app(_ chunk: Int) -> (String, Data) {
            (String(format: "%@/events-%06d.jsonl", process, chunk),
             Data("{\"source\":\"ios\",\"processId\":\"\(process)\",\"captureId\":\"\(capture.uuidString.lowercased())\",\"sequence\":\(chunk)}\n".utf8))
        }
        let (sharedPath, shared) = app(1), (oldPath, old) = app(2), (newPath, new) = app(3)
        let limit = shared.count + new.count
        let store = DiagnosticsAcquisitionStore(root: root, maximumEvidenceBytes: limit)
        func appJob(_ chunks: [String: Data], complete: Bool) async throws -> UUID {
            let job = try await store.create(deviceDigest: "0123456789abcdef", captureID: capture)
            try await store.retainAppEvidence(job.id, chunks: chunks)
            if complete {
                _ = try await store.inventory(job.id, deviceDigest: job.deviceDigest, index: Data(), chunks: [])
                try await store.finish(job.id)
            }
            return job.id
        }
        let oldest = try await appJob([sharedPath: shared], complete: true)
        let second = try await appJob([oldPath: old], complete: true)
        let requested = try await appJob([sharedPath: shared], complete: false)
        let incoming = try await store.create(deviceDigest: "0123456789abcdef", captureID: capture)
        try await store.retainAppEvidence(incoming.id, chunks: [sharedPath: shared, newPath: new])
        let restarted = DiagnosticsAcquisitionStore(root: root, maximumEvidenceBytes: limit)
        let remaining = try await restarted.manifests()
        precondition(Set(remaining.map(\.id)) == Set([requested, incoming.id]),
            "app admission protects requested jobs and cannot count a shared body as reclaimed")
        precondition(!remaining.contains { $0.id == oldest || $0.id == second })
        let snapshot = try await restarted.exportSnapshot()
        precondition(snapshot.appChunks == [sharedPath: shared, newPath: new])
        precondition(snapshot.appChunks.values.reduce(0) { $0 + $1.count } == limit,
            "admission at the exact byte bound succeeds without double counting shared bodies")

        // One batch cannot fit even in an empty cache. No terminal receipts or
        // evidence may be discarded on this rejected admission.
        try await restarted.interrupt(requested, cancelled: true)
        let oversized = try await restarted.create(deviceDigest: "0123456789abcdef", captureID: capture)
        let before = try cacheSnapshot(root)
        do {
            try await restarted.retainAppEvidence(oversized.id,
                chunks: [sharedPath: shared, oldPath: old, newPath: new])
            fatalError("oversized app snapshot admitted")
        } catch DiagnosticsAcquisitionStore.Failure.storageFull {}
        let after = try cacheSnapshot(root)
        precondition(after == before, "oversized batch admission must be non-destructive")
        let oversizedReceipt = try await restarted.load(oversized.id)
        precondition(oversizedReceipt.appEvidence == nil, "failed batch must not publish partial app receipts")

        // The incoming snapshot can be the only remaining reference to a
        // shared body after its completed owner is evicted during admission.
        let prospectiveRoot = root.appendingPathComponent("prospective")
        let prospectiveStore = DiagnosticsAcquisitionStore(root: prospectiveRoot, maximumEvidenceBytes: limit)
        for (path, bytes) in [(sharedPath, shared), (oldPath, old)] {
            let owner = try await prospectiveStore.create(deviceDigest: "0123456789abcdef", captureID: capture)
            try await prospectiveStore.retainAppEvidence(owner.id, chunks: [path: bytes])
            _ = try await prospectiveStore.inventory(owner.id, deviceDigest: owner.deviceDigest, index: Data(), chunks: [])
            try await prospectiveStore.finish(owner.id)
        }
        let prospective = try await prospectiveStore.create(deviceDigest: "0123456789abcdef", captureID: capture)
        try await prospectiveStore.retainAppEvidence(prospective.id, chunks: [sharedPath: shared, newPath: new])
        let prospectiveEntries = try await prospectiveStore.manifests()
        let prospectiveSnapshot = try await prospectiveStore.exportSnapshot()
        precondition(prospectiveEntries.map(\.id) == [prospective.id])
        precondition(prospectiveSnapshot.appChunks == [sharedPath: shared, newPath: new])
    }

    static func protectedPressureAndReportingTests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticsAcquisitionStore(root: root, maximumEvidenceBytes: 100)
        let shared = Data(repeating: 1, count: 50)
        let terminal = try await firmwareJob(store, data: shared, phase: .complete)
        let incomplete = try await firmwareJob(store, data: shared, phase: .partial)
        let active = try await store.create(deviceDigest: "0123456789abcdef", captureID: nil)
        let incoming = Data(repeating: 2, count: 60)
        _ = try await store.inventory(active.id, deviceDigest: active.deviceDigest, index: Data(), chunks: [receipt(incoming)])
        let before = try cacheSnapshot(root)
        do {
            try await store.verified(active.id, receipt: receipt(incoming), data: incoming)
            fatalError("eviction stole evidence shared with an incomplete acquisition")
        } catch {
            precondition((error as? DiagnosticsAcquisitionStore.Failure) == .storageFull)
            let after = try cacheSnapshot(root)
            precondition(after == before,
                "infeasible admission must preserve terminal jobs as well as incomplete jobs")
            let status = DiagnosticsAcquisitionFailureReporting.status(for: error)
            precondition(status.contains("cache is full") && status.contains("32 MiB") && status.contains("preserved"))
            let fields = DiagnosticsAcquisitionFailureReporting.fields(for: error, acquisitionID: active.id, phase: "device_download")
            precondition(fields == ["code": "cache_full", "reason": "cache_full", "phase": "device_download",
                "operationId": active.id.uuidString.lowercased()])
            try await store.interrupt(active.id, code: DiagnosticsAcquisitionFailureReporting.code(for: error))
        }
        let restarted = DiagnosticsAcquisitionStore(root: root, maximumEvidenceBytes: 100)
        let failed = try await restarted.load(active.id)
        let remaining = try await restarted.manifests()
        precondition(failed.phase == .partial && failed.failureCode == "cache_full" && failed.verified.isEmpty)
        precondition(!failed.canResumeAutomatically(postRideEnabled: true), "cache failure cannot create a reconnect retry storm")
        precondition(Set(remaining.map(\.id)) == Set([terminal, incomplete, active.id]))
        let retained = try await restarted.chunkData(incomplete, receipt: receipt(shared))
        precondition(retained == shared)

        let oversized = try await restarted.create(deviceDigest: active.deviceDigest, captureID: nil)
        let tooLarge = Data(repeating: 3, count: 101)
        _ = try await restarted.inventory(oversized.id, deviceDigest: active.deviceDigest, index: Data(), chunks: [receipt(tooLarge)])
        let beforeOversize = try cacheSnapshot(root)
        do {
            try await restarted.verified(oversized.id, receipt: receipt(tooLarge), data: tooLarge)
            fatalError("oversized firmware body admitted")
        } catch DiagnosticsAcquisitionStore.Failure.storageFull {}
        let afterOversize = try cacheSnapshot(root)
        precondition(afterOversize == beforeOversize)
        let privateError = NSError(domain: "https://private.example/token", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "private password or cache path"])
        let safe = DiagnosticsAcquisitionFailureReporting.fields(for: privateError, acquisitionID: nil, phase: "request")
        precondition(safe == ["code": "transfer_failed", "reason": "transfer_failed", "phase": "request"])
    }

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
        try await bytePressureTests()
        try await appPressureAndOversizeTests()
        try await protectedPressureAndReportingTests()
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
            let failures: [String?] = [nil, "transfer_failed", "cache_full", "wifi_memory", "diagnostics_seal_timeout", "cancelled"]
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
