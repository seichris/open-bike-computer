import Foundation

nonisolated struct DiagnosticsBrokerPairing: Codable, Sendable {
    let schema: Int
    let origin: String
    let certificateSHA256: String
    let token: String
    let expiresAt: Int64

    var baseURL: URL? { URL(string: origin) }
    func valid(at date: Date = Date()) -> Bool {
        guard schema == 2, let components = URLComponents(string: origin),
              components.scheme == "https", components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty, let host = components.host,
              let port = components.port, (1...65535).contains(port),
              expiresAt > Int64(date.timeIntervalSince1970),
              expiresAt <= Int64(date.timeIntervalSince1970) + 24 * 3600 + 60,
              Self.hex(certificateSHA256), Self.hex(token) else { return false }
        let bytes = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard bytes.count == 4, bytes.map(String.init).joined(separator: ".") == host else { return false }
        return bytes[0] == 10 || bytes[0] == 127 ||
            (bytes[0] == 192 && bytes[1] == 168) ||
            (bytes[0] == 172 && (16...31).contains(bytes[1]))
    }
    private static func hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

nonisolated struct DiagnosticsBrokerCommand: Decodable, Sendable {
    struct Parameters: Decodable, Sendable {
        let mask: UInt32?
        let minimumLevel: UInt32?
        let durationSeconds: UInt32?
        let budgetBytes: UInt32?
        let registryDigest: String?
        let code: String?
    }
    let schema: Int
    let id: UUID
    let kind: String
    let target: String
    let parameters: Parameters
    let createdAt: Int64
    let expiresAt: Int64

    func valid(at date: Date = Date()) -> Bool {
        let now = Int64(date.timeIntervalSince1970)
        guard schema == 2, createdAt <= now + 60, expiresAt > now,
              expiresAt > createdAt, expiresAt - createdAt <= 3600,
              target == "iphone" || (target.count == 16 && target.utf8.allSatisfy {
                  (48...57).contains($0) || (97...102).contains($0)
              }) else { return false }
        switch kind {
        case "capture":
            guard let mask = parameters.mask, let level = parameters.minimumLevel,
                  let duration = parameters.durationSeconds, let budget = parameters.budgetBytes,
                  parameters.registryDigest == DiagnosticsSchema.digest else { return false }
            return DiagnosticsCaptureRequest(captureID: id, generation: 1, mask: mask,
                minimumLevel: level, durationSeconds: duration, budgetBytes: budget).valid
        case "mark":
            return ["navigation_wrong", "device_blank", "connection_drop", "sensor_missing", "other"].contains(parameters.code ?? "")
        case "live":
            return parameters.durationSeconds.map { (1...300).contains($0) } == true
        case "collect", "export", "stop_capture", "stop_live": return true
        default: return false
        }
    }
}

nonisolated struct DiagnosticsBrokerAcknowledgement: Codable, Sendable {
    let id: UUID
    let state: String
    let code: String
    var valid: Bool {
        ["accepted", "rejected", "interrupted"].contains(state) &&
        !code.isEmpty && code.count <= 64 && code.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 95
        }
    }
}

/// Persist a started receipt BEFORE an action. After process loss we report
/// interrupted/unknown rather than replaying a capture with a renewed lease.
actor DiagnosticsBrokerCommandJournal {
    private let root: URL
    init(root: URL) { self.root = root }
    private func entries() throws -> [DiagnosticsBrokerAcknowledgement] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 64 * 1024 else {
            throw DiagnosticsAcquisitionStore.Failure.invalidManifest
        }
        let result = try JSONDecoder().decode([DiagnosticsBrokerAcknowledgement].self, from: Data(contentsOf: root))
        guard result.count <= 100, Set(result.map(\.id)).count == result.count,
              result.allSatisfy(\.valid) else { throw DiagnosticsAcquisitionStore.Failure.invalidManifest }
        return result
    }
    func existing(_ id: UUID) throws -> DiagnosticsBrokerAcknowledgement? {
        try entries().first { $0.id == id }
    }
    func save(_ receipt: DiagnosticsBrokerAcknowledgement) throws {
        guard receipt.valid else { throw DiagnosticsAcquisitionStore.Failure.invalidManifest }
        var existing = try entries().filter { $0.id != receipt.id }
        existing.append(receipt)
        // Never forget a still-valid command and execute it again after replay.
        // Broker history has the same 100-command hard ceiling per pairing.
        guard existing.count <= 100 else { throw DiagnosticsAcquisitionStore.Failure.storageFull }
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(existing)
        try data.write(to: root, options: .atomic)
        let handle = try FileHandle(forWritingTo: root)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
