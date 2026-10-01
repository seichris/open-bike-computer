import Foundation

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
    enum Phase: String, Codable, Sendable { case requested, collecting, partial, complete, cancelled }
    let schema: Int
    let id: UUID
    let captureID: UUID?
    let deviceDigest: String
    let createdAt: Date
    var updatedAt: Date
    var phase: Phase
    var indexData: Data?
    var expected: [DiagnosticsChunkReceipt]
    var verified: [String]
    var failureCode: String?

    var deliveryComplete: Bool {
        indexData != nil && phase == .complete &&
            Set(verified) == Set(expected.map(\.key))
    }
}

/// Disk I/O is actor isolated, never performed on the UI executor. Only a
/// bounded, redacted device index and receipts are persisted; never transport
/// tokens, SSIDs, URLs or BLE identifiers. Atomic replacement supports process
/// recovery; physical power durability is not claimed by this store.
actor DiagnosticsAcquisitionStore {
    enum Failure: Error { case invalidManifest, inventoryChanged, notFound, storageFull }
    private let root: URL
    private let maximumJobs = 20
    private let maximumManifestBytes = 256 * 1024

    init(root: URL) { self.root = root }

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
        guard paths.count <= maximumJobs else { throw Failure.storageFull }
        return try paths.filter { $0.pathExtension == "json" }.map { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                throw Failure.invalidManifest
            }
            return try load(id)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    func create(deviceDigest: String, captureID: UUID?) throws -> DiagnosticsAcquisitionManifest {
        let entries = try manifests()
        if entries.count >= maximumJobs {
            // Never evict an incomplete collection to create another one.
            guard let old = entries.first(where: { $0.phase == .complete || $0.phase == .cancelled }) else {
                throw Failure.storageFull
            }
            try FileManager.default.removeItem(at: path(old.id))
        }
        let now = Date()
        let value = DiagnosticsAcquisitionManifest(schema: 2, id: UUID(), captureID: captureID,
            deviceDigest: deviceDigest, createdAt: now, updatedAt: now, phase: .requested,
            indexData: nil, expected: [], verified: [], failureCode: nil)
        try save(value)
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

    func verified(_ id: UUID, receipt: DiagnosticsChunkReceipt) throws {
        var value = try load(id)
        guard value.phase == .collecting, value.expected.contains(receipt) else {
            throw Failure.inventoryChanged
        }
        if !value.verified.contains(receipt.key) { value.verified.append(receipt.key) }
        value.updatedAt = Date()
        try save(value)
    }

    func finish(_ id: UUID) throws {
        var value = try load(id)
        guard value.indexData != nil, Set(value.verified) == Set(value.expected.map(\.key)) else {
            throw Failure.inventoryChanged
        }
        value.phase = .complete
        value.updatedAt = Date()
        value.failureCode = nil
        try save(value)
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
