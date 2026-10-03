import CryptoKit
import Foundation

nonisolated enum DiagnosticsAcquisitionEvidencePolicy {
    // Recorder + acquisition evidence + manifests stay within the existing
    // 100 MiB archive-reader bound (ordinary recorder retention is 50 MiB).
    static let maximumBytes = 32 * 1024 * 1024
}

nonisolated struct DiagnosticsChunkReceipt: Codable, Equatable, Sendable {
    let bootSequence: UInt32
    let chunk: UInt32
    let bytes: Int
    let sha256: String
    var key: String { "\(bootSequence):\(chunk):\(sha256)" }
}

/// A collection is an immutable inventory plus mutable, replayable receipts.
/// It is intentionally outside the v1 recorder root: v1 archives remain unchanged.
nonisolated struct DiagnosticsAcquisitionManifest: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case requested, collecting, partial, complete, cancelled

        var canResumeAutomatically: Bool {
            switch self {
            case .requested, .collecting, .partial: return true
            case .complete, .cancelled: return false
            }
        }
    }
    enum Origin: String, Codable, Sendable { case manual, postRide = "post_ride" }
    let schema: Int
    let id: UUID
    var origin: Origin? = nil
    let captureID: UUID?
    let deviceDigest: String
    let createdAt: Date
    var updatedAt: Date
    var phase: Phase
    var indexData: Data?
    var expected: [DiagnosticsChunkReceipt]
    var verified: [String]
    var failureCode: String?
    // Absent in pre-cache receipts, whose claims still need archive validation.
    var evidenceRetained: Bool? = nil

    func canResumeAutomatically(postRideEnabled: Bool) -> Bool {
        phase.canResumeAutomatically && (origin != .postRide || postRideEnabled)
    }

    var deliveryComplete: Bool {
        indexData != nil && phase == .complete &&
            Set(verified) == Set(expected.map(\.key))
    }
}

/// Disk I/O is actor isolated, never performed on the UI executor. Only a
/// bounded, redacted device index, receipts and exact verified chunks are persisted; never transport
/// tokens, SSIDs, URLs or BLE identifiers. Atomic replacement supports process
/// recovery; physical power durability is not claimed by this store.
actor DiagnosticsAcquisitionStore {
    enum Failure: Error { case invalidManifest, inventoryChanged, notFound, storageFull }
    private let root: URL
    private let maximumJobs = 20
    private let maximumManifestBytes = 256 * 1024
    private let maximumEvidenceBytes: Int
    private var evidenceRoot: URL { root.appendingPathComponent("evidence", isDirectory: true) }

    init(root: URL, maximumEvidenceBytes: Int = DiagnosticsAcquisitionEvidencePolicy.maximumBytes) {
        precondition(maximumEvidenceBytes > 0 && maximumEvidenceBytes <= DiagnosticsAcquisitionEvidencePolicy.maximumBytes)
        self.root = root
        self.maximumEvidenceBytes = maximumEvidenceBytes
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw Failure.invalidManifest }
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: root.path)
        #endif
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var directory = root
        try directory.setResourceValues(excluded)
    }

    private func path(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    private func validate(_ manifest: DiagnosticsAcquisitionManifest) throws {
        guard manifest.schema == 2,
              manifest.deviceDigest.count == 16,
              manifest.deviceDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              manifest.expected.count <= 256,
              (manifest.indexData?.count ?? 0) <= 64 * 1024,
              manifest.failureCode.map({ $0.count <= 64 && $0.utf8.allSatisfy {
                  (97...122).contains($0) || (48...57).contains($0) || $0 == 95
              } }) ?? true else { throw Failure.invalidManifest }
        var keys = Set<String>()
        var identities = Set<String>()
        for item in manifest.expected {
            guard item.bootSequence > 0, item.chunk > 0, item.bytes > 0,
                  item.bytes <= 256 * 1024, item.sha256.count == 64,
                  item.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  keys.insert(item.key).inserted,
                  identities.insert("\(item.bootSequence):\(item.chunk)").inserted
            else { throw Failure.invalidManifest }
        }
        guard Set(manifest.verified).count == manifest.verified.count,
              Set(manifest.verified).isSubset(of: keys),
              manifest.indexData != nil || manifest.expected.isEmpty,
              manifest.phase != .complete || manifest.deliveryComplete
        else { throw Failure.invalidManifest }
    }

    func load(_ id: UUID) throws -> DiagnosticsAcquisitionManifest {
        try prepare()
        let url = path(id)
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              let size = values.fileSize, size <= maximumManifestBytes
        else { throw Failure.invalidManifest }
        let value = try JSONDecoder().decode(DiagnosticsAcquisitionManifest.self, from: Data(contentsOf: url))
        guard value.id == id else { throw Failure.invalidManifest }
        try validate(value)
        return value
    }

    private func save(_ value: DiagnosticsAcquisitionManifest) throws {
        try validate(value)
        try prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumManifestBytes else { throw Failure.invalidManifest }
        try data.write(to: path(value.id), options: .atomic)
        let handle = try FileHandle(forWritingTo: path(value.id))
        defer { try? handle.close() }
        try handle.synchronize()
    }

    func manifests() throws -> [DiagnosticsAcquisitionManifest] {
        try prepare()
        let paths = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let receipts = paths.filter { $0.pathExtension == "json" }
        guard receipts.count <= maximumJobs else { throw Failure.storageFull }
        return try receipts.map { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                throw Failure.invalidManifest
            }
            return try load(id)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    func create(deviceDigest: String, captureID: UUID?, id: UUID = UUID(),
                origin: DiagnosticsAcquisitionManifest.Origin = .manual) throws -> DiagnosticsAcquisitionManifest {
        let now = Date()
        let value = DiagnosticsAcquisitionManifest(schema: 2, id: id, origin: origin, captureID: captureID,
            deviceDigest: deviceDigest, createdAt: now, updatedAt: now, phase: .requested,
            indexData: nil, expected: [], verified: [], failureCode: nil)
        try validate(value)
        let entries = try manifests()
        if let existing = entries.first(where: { $0.id == id }) {
            guard existing.deviceDigest == deviceDigest, existing.captureID == captureID,
                  (existing.origin ?? .manual) == origin else {
                throw Failure.inventoryChanged
            }
            return existing
        }
        if entries.count >= maximumJobs {
            // Never evict an incomplete collection to create another one.
            guard let old = entries.first(where: { $0.phase == .complete || $0.phase == .cancelled }) else {
                throw Failure.storageFull
            }
            try FileManager.default.removeItem(at: path(old.id))
        }
        try save(value)
        try pruneUnreferencedEvidence()
        return value
    }

    func inventory(_ id: UUID, deviceDigest: String, index: Data,
                   chunks: [DiagnosticsChunkReceipt]) throws -> DiagnosticsAcquisitionManifest {
        var value = try load(id)
        guard value.deviceDigest == deviceDigest else { throw Failure.inventoryChanged }
        if value.indexData == nil {
            value.indexData = index
            value.expected = chunks
        }
        // A retry always revalidates local bytes; previous receipts alone are
        // not proof that retention or a damaged file did not remove evidence.
        value.verified = []
        value.updatedAt = Date()
        value.phase = .collecting
        value.failureCode = nil
        try save(value)
        return value
    }

    private func evidenceName(device: String, receipt: DiagnosticsChunkReceipt) -> String {
        "\(device)-\(receipt.bootSequence)-\(receipt.chunk)-\(receipt.sha256).jsonl"
    }

    private func prepareEvidence() throws {
        try prepare()
        try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
        guard try evidenceRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw Failure.invalidManifest
        }
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: evidenceRoot.path)
        #endif
    }

    private func evidenceFiles() throws -> [URL] {
        try prepareEvidence()
        let files = try FileManager.default.contentsOfDirectory(at: evidenceRoot,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard files.count <= maximumJobs * 256 else { throw Failure.storageFull }
        for file in files {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true,
                  let size = values.fileSize, size > 0, size <= 256 * 1024 else {
                throw Failure.invalidManifest
            }
        }
        return files
    }

    private func pruneUnreferencedEvidence() throws {
        let referenced = Set(try manifests().flatMap { value in
            value.expected.map { evidenceName(device: value.deviceDigest, receipt: $0) }
        })
        for file in try evidenceFiles() where !referenced.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func matches(_ data: Data, receipt: DiagnosticsChunkReceipt) -> Bool {
        data.count == receipt.bytes &&
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == receipt.sha256
    }

    private func cached(device: String, receipt: DiagnosticsChunkReceipt) throws -> Data? {
        try prepareEvidence()
        let url = evidenceRoot.appendingPathComponent(evidenceName(device: device, receipt: receipt))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              values.fileSize == receipt.bytes else { throw Failure.invalidManifest }
        let data = try Data(contentsOf: url)
        guard matches(data, receipt: receipt) else { throw Failure.invalidManifest }
        return data
    }

    func chunkData(_ id: UUID, receipt: DiagnosticsChunkReceipt) throws -> Data? {
        let value = try load(id)
        guard value.expected.contains(receipt) else { throw Failure.inventoryChanged }
        return try cached(device: value.deviceDigest, receipt: receipt)
    }

    func verified(_ id: UUID, receipt: DiagnosticsChunkReceipt, data: Data) throws {
        var value = try load(id)
        guard value.phase == .collecting, value.expected.contains(receipt) else {
            throw Failure.inventoryChanged
        }
        guard matches(data, receipt: receipt) else { throw Failure.invalidManifest }
        // Persist exact bytes before publishing a receipt. Ordinary v1 capture
        // retention has no ownership of this bounded, deduplicated store.
        try pruneUnreferencedEvidence()
        let url = evidenceRoot.appendingPathComponent(evidenceName(device: value.deviceDigest, receipt: receipt))
        let files = try evidenceFiles()
        let retainedBytes = try files.reduce(0) { total, file in
            total + (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        let replacedBytes = FileManager.default.fileExists(atPath: url.path)
            ? (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) : 0
        guard retainedBytes - replacedBytes + data.count <= maximumEvidenceBytes else { throw Failure.storageFull }
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        if !value.verified.contains(receipt.key) { value.verified.append(receipt.key) }
        value.updatedAt = Date()
        try save(value)
    }

    func finish(_ id: UUID) throws {
        var value = try load(id)
        guard value.indexData != nil, Set(value.verified) == Set(value.expected.map(\.key)) else {
            throw Failure.inventoryChanged
        }
        for receipt in value.expected {
            guard try cached(device: value.deviceDigest, receipt: receipt) != nil else {
                throw Failure.inventoryChanged
            }
        }
        value.phase = .complete
        value.evidenceRetained = true
        value.updatedAt = Date()
        value.failureCode = nil
        try save(value)
    }

    /// Actor-isolated immutable Data prevents eviction racing recorder snapshot
    /// creation. At most 32 MiB; every returned chunk is rehashed on export.
    func exportSnapshot() throws -> (manifests: [DiagnosticsAcquisitionManifest], chunks: [String: Data]) {
        let entries = try manifests()
        var chunks: [String: Data] = [:]
        var bytes = 0
        for value in entries {
            for receipt in value.expected where value.verified.contains(receipt.key) {
                guard let data = try cached(device: value.deviceDigest, receipt: receipt) else {
                    if value.evidenceRetained == true { throw Failure.invalidManifest }
                    continue // Legacy receipt: the v1 recorder may still contain it.
                }
                let name = String(format: "events-%06u-%@.jsonl", receipt.chunk, String(receipt.sha256.prefix(16)))
                let relative = "\(value.deviceDigest)/\(receipt.bootSequence)/\(name)"
                if let existing = chunks[relative] {
                    guard existing == data else { throw Failure.inventoryChanged }
                } else {
                    bytes += data.count
                    guard bytes <= maximumEvidenceBytes else { throw Failure.storageFull }
                    chunks[relative] = data
                }
            }
        }
        return (entries, chunks)
    }

    func interrupt(_ id: UUID, cancelled: Bool = false, code: String = "interrupted") throws {
        var value = try load(id)
        // Complete delivery is independent of a subsequent transport-cleanup
        // error; do not erase already established delivery evidence.
        if value.deliveryComplete { return }
        value.phase = cancelled ? .cancelled : .partial
        value.updatedAt = Date()
        value.failureCode = code
        try save(value)
    }
}
