import Foundation

nonisolated struct DeviceDiagnosticsIndex: Codable, Equatable, Sendable {
    let schema: Int
    let source: String
    let bootSequence: UInt32
    let activeChunk: UInt32
    let stats: DeviceDiagnosticsStats
    let chunks: [DeviceDiagnosticsChunk]
}

nonisolated struct DeviceDiagnosticsStats: Codable, Equatable, Sendable {
    let enqueued: UInt32
    let written: UInt32
    let dropped: UInt32
    let storageErrors: UInt32
}

nonisolated struct DeviceDiagnosticsChunk: Codable, Identifiable, Equatable, Sendable {
    let bootSequence: UInt32
    let chunk: UInt32
    let bytes: Int
    let sha256: String
    var id: String { "\(bootSequence)-\(chunk)-\(sha256.lowercased())" }
    var valid: Bool {
        bootSequence > 0 && chunk > 0 && bytes > 0 && bytes <= 256 * 1024 &&
        sha256.utf8.count == 64 && sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

nonisolated struct DiagnosticsAcquisitionV2: Codable, Equatable, Sendable {
    let schema: Int
    let id: UUID
    let deviceDigest: String
    let captureID: UUID?
    let createdAt: Date
    /// This immutable inventory is saved before the first payload request.
    /// Later logging cannot move this acquisition's cutoff.
    let index: DeviceDiagnosticsIndex
    let rawIndex: Data
    let indexSHA256: String
    let capabilities: DeviceDiagnosticsStatusV2?
    var received: Set<String>
    var state: String
    var failureCode: String?
    var updatedAt: Date

    init(id: UUID, deviceDigest: String, captureID: UUID?, index: DeviceDiagnosticsIndex,
         rawIndex: Data, indexSHA256: String, capabilities: DeviceDiagnosticsStatusV2?, now: Date = Date()) {
        self.schema = 2; self.id = id; self.deviceDigest = deviceDigest; self.captureID = captureID
        self.createdAt = now; self.updatedAt = now; self.index = index
        self.rawIndex = rawIndex; self.indexSHA256 = indexSHA256; self.capabilities = capabilities
        self.received = []; self.state = "collecting"
    }
    var expectedIDs: Set<String> { Set(index.chunks.map(\.id)) }
    var missingIDs: Set<String> { expectedIDs.subtracting(received) }
    var deliveryComplete: Bool { valid && missingIDs.isEmpty }
    var valid: Bool {
        schema == 2 && Self.validDigest(deviceDigest) && rawIndex.count <= 64 * 1024 &&
        indexSHA256.utf8.count == 64 && indexSHA256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
        index.schema == 1 && index.source == "firmware" && index.bootSequence > 0 && index.activeChunk > 0 &&
        index.chunks.count <= 256 && index.chunks.allSatisfy(\.valid) &&
        expectedIDs.count == index.chunks.count && received.isSubset(of: expectedIDs) &&
        ["collecting", "interrupted", "delivered"].contains(state) &&
        (state != "delivered" || missingIDs.isEmpty)
    }
    static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 16 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

nonisolated enum DiagnosticsAcquisitionError: Error {
    case invalidManifest, invalidChunk, capacityExceeded, wrongDevice
}

/// Disk I/O is actor-owned, independent from SwiftUI and the MainActor.
/// Only complete verified chunks advance the acquisition receipt.
actor DiagnosticsAcquisitionStoreV2 {
    let root: URL
    init(root: URL) { self.root = root }

    func load(_ id: UUID) throws -> DiagnosticsAcquisitionV2? {
        let url = manifestURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard count > 0, count <= 256 * 1024 else { throw DiagnosticsAcquisitionError.invalidManifest }
        let data = try Data(contentsOf: url)
        let value = try JSONDecoder().decode(DiagnosticsAcquisitionV2.self, from: data)
        guard value.id == id, value.valid,
              (try? JSONDecoder().decode(DeviceDiagnosticsIndex.self, from: value.rawIndex)) == value.index else {
            throw DiagnosticsAcquisitionError.invalidManifest
        }
        return value
    }

    func save(_ manifest: DiagnosticsAcquisitionV2) throws {
        guard manifest.valid else { throw DiagnosticsAcquisitionError.invalidManifest }
        try prepare(root.appendingPathComponent("acquisitions", isDirectory: true))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= 256 * 1024 else { throw DiagnosticsAcquisitionError.capacityExceeded }
        let url = manifestURL(manifest.id)
        try data.write(to: url, options: [.atomic])
        try protect(url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }

    func partial(_ chunk: DeviceDiagnosticsChunk, deviceDigest: String) throws -> Data {
        let url = try partialURL(chunk, deviceDigest: deviceDigest)
        guard FileManager.default.fileExists(atPath: url.path) else { return Data() }
        let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard count >= 0, count <= chunk.bytes else {
            try FileManager.default.removeItem(at: url)
            return Data()
        }
        return try Data(contentsOf: url)
    }

    func append(_ slice: Data, to chunk: DeviceDiagnosticsChunk, deviceDigest: String, expectedOffset: Int) throws {
        let url = try partialURL(chunk, deviceDigest: deviceDigest)
        try prepare(url.deletingLastPathComponent())
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists { guard expectedOffset == 0, FileManager.default.createFile(atPath: url.path, contents: nil) else { throw DiagnosticsAcquisitionError.invalidChunk } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size == expectedOffset, slice.count > 0, slice.count <= 16 * 1024,
              size + slice.count <= chunk.bytes else { throw DiagnosticsAcquisitionError.invalidChunk }
        try protect(url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: slice)
        try file.synchronize()
    }

    func removePartial(_ chunk: DeviceDiagnosticsChunk, deviceDigest: String) throws {
        let url = try partialURL(chunk, deviceDigest: deviceDigest)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func manifestURL(_ id: UUID) -> URL {
        root.appendingPathComponent("acquisitions", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased() + ".json")
    }
    private func partialURL(_ chunk: DeviceDiagnosticsChunk, deviceDigest: String) throws -> URL {
        guard chunk.valid, DiagnosticsAcquisitionV2.validDigest(deviceDigest) else { throw DiagnosticsAcquisitionError.invalidChunk }
        return root.appendingPathComponent("partials", isDirectory: true)
            .appendingPathComponent(deviceDigest, isDirectory: true).appendingPathComponent(chunk.id + ".part")
    }
    private func prepare(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var value = url; var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try value.setResourceValues(resources)
    }
    private func protect(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
