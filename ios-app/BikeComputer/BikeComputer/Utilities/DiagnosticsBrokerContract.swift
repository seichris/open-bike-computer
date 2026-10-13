import Foundation

nonisolated enum DiagnosticsBrokerAddress {
    static func valid(_ origin: String, certificateSHA256: String) -> Bool {
        guard let components = URLComponents(string: origin),
              components.scheme == "https", components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty, let host = components.host,
              let port = components.port, (1...65535).contains(port), hex(certificateSHA256) else { return false }
        let bytes = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard bytes.count == 4, bytes.map(String.init).joined(separator: ".") == host else { return false }
        return bytes[0] == 10 || bytes[0] == 127 ||
            (bytes[0] == 192 && bytes[1] == 168) ||
            (bytes[0] == 172 && (16...31).contains(bytes[1]))
    }
    static func hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Only this one-use import document has a 24-hour deadline. The iPhone creates
/// its own credential and persists it before asking the pinned Mac to enroll.
nonisolated struct DiagnosticsBrokerEnrollment: Codable, Equatable, Sendable {
    let schema: Int
    let origin: String
    let certificateSHA256: String
    let token: String
    let expiresAt: Int64
    let brokerID: UUID
    let enrollmentID: UUID

    var structurallyValid: Bool {
        schema == 3 && expiresAt > 0 && DiagnosticsBrokerAddress.hex(token) &&
            DiagnosticsBrokerAddress.valid(origin, certificateSHA256: certificateSHA256)
    }
    func valid(at date: Date = Date()) -> Bool {
        let now = Int64(date.timeIntervalSince1970)
        return structurallyValid && expiresAt > now && expiresAt <= now + 24 * 3600 + 60
    }
    func pairing(phoneID: UUID, credential: String, credentialID: UUID,
                 existing: DiagnosticsBrokerPairing? = nil, at date: Date = Date()) throws -> DiagnosticsBrokerPairing {
        guard valid(at: date) else { throw DiagnosticsAcquisitionStore.Failure.invalidManifest }
        if let existing, existing.schema == 3, existing.brokerID == brokerID,
           existing.enrollmentID == enrollmentID, existing.phoneID == phoneID,
           existing.origin == origin, existing.certificateSHA256 == certificateSHA256,
           existing.valid(at: date) {
            // Importing the same file twice must not discard a credential whose
            // first enrollment may already have committed but lost its reply.
            return existing
        }
        guard DiagnosticsBrokerAddress.hex(credential), credential != token else {
            throw DiagnosticsAcquisitionStore.Failure.invalidManifest
        }
        return DiagnosticsBrokerPairing(schema: 3, origin: origin,
            certificateSHA256: certificateSHA256, token: credential, brokerID: brokerID,
            phoneID: phoneID, credentialID: credentialID, enrollmentID: enrollmentID, enrollment: self)
    }
}

nonisolated struct DiagnosticsBrokerEnrollmentRequest: Encodable, Sendable {
    let schema = 3
    let brokerID: UUID
    let enrollmentID: UUID
    let credentialID: UUID
    let phoneID: UUID
    let credential: String
}

nonisolated struct DiagnosticsBrokerEnrollmentReceipt: Codable, Sendable {
    let schema: Int
    let brokerID: UUID
    let credentialID: UUID
    let phoneID: UUID
    let paired: Bool
}

nonisolated struct DiagnosticsBrokerPairing: Codable, Equatable, Sendable {
    let schema: Int
    let origin: String
    let certificateSHA256: String
    let token: String
    let expiresAt: Int64?
    let brokerID: UUID?
    let phoneID: UUID?
    let credentialID: UUID?
    let enrollmentID: UUID?
    let enrollment: DiagnosticsBrokerEnrollment?

    init(schema: Int, origin: String, certificateSHA256: String, token: String,
         expiresAt: Int64? = nil, brokerID: UUID? = nil, phoneID: UUID? = nil,
         credentialID: UUID? = nil, enrollmentID: UUID? = nil, enrollment: DiagnosticsBrokerEnrollment? = nil) {
        self.schema = schema; self.origin = origin; self.certificateSHA256 = certificateSHA256
        self.token = token; self.expiresAt = expiresAt; self.brokerID = brokerID
        self.phoneID = phoneID; self.credentialID = credentialID; self.enrollmentID = enrollmentID
        self.enrollment = enrollment
    }

    var baseURL: URL? { URL(string: origin) }
    func valid(at date: Date = Date()) -> Bool {
        guard DiagnosticsBrokerAddress.valid(origin, certificateSHA256: certificateSHA256),
              DiagnosticsBrokerAddress.hex(token) else { return false }
        if schema == 2 {
            guard let expiresAt, brokerID == nil, phoneID == nil, credentialID == nil,
                  enrollmentID == nil, enrollment == nil else { return false }
            return expiresAt > Int64(date.timeIntervalSince1970) &&
                expiresAt <= Int64(date.timeIntervalSince1970) + 24 * 3600 + 60
        }
        guard schema == 3, expiresAt == nil, brokerID != nil, phoneID != nil,
              credentialID != nil, enrollmentID != nil else { return false }
        if let enrollment {
            // An expired pending import may confirm an already-committed pair.
            // The Mac refuses creating a new pair after the enrollment expiry.
            return enrollment.structurallyValid && enrollment.origin == origin &&
                enrollment.certificateSHA256 == certificateSHA256 &&
                enrollment.brokerID == brokerID && enrollment.enrollmentID == enrollmentID &&
                enrollment.token != token
        }
        return true
    }

    var enrollmentRequest: DiagnosticsBrokerEnrollmentRequest? {
        guard schema == 3, enrollment != nil, let brokerID, let enrollmentID,
              let credentialID, let phoneID else { return nil }
        return DiagnosticsBrokerEnrollmentRequest(brokerID: brokerID, enrollmentID: enrollmentID,
            credentialID: credentialID, phoneID: phoneID, credential: token)
    }
    func confirmed(by receipt: DiagnosticsBrokerEnrollmentReceipt) throws -> Self {
        guard valid(), enrollment != nil, receipt.schema == 3, receipt.paired,
              receipt.brokerID == brokerID, receipt.phoneID == phoneID,
              receipt.credentialID == credentialID else { throw DiagnosticsAcquisitionStore.Failure.invalidManifest }
        return Self(schema: schema, origin: origin, certificateSHA256: certificateSHA256, token: token,
            brokerID: brokerID, phoneID: phoneID, credentialID: credentialID, enrollmentID: enrollmentID)
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

    /// A local evidence request must not start a radio session. Firmware
    /// targets use the app-owned collector; phone targets only queue a snapshot.
    var requiresFirmware: Bool { target != "iphone" }

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

nonisolated struct DiagnosticsBrokerAcknowledgement: Codable, Equatable, Sendable {
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
    nonisolated struct Claim: Sendable {
        let receipt: DiagnosticsBrokerAcknowledgement
        let shouldExecute: Bool
    }
    nonisolated private struct Entry: Codable {
        let receipt: DiagnosticsBrokerAcknowledgement
        let expiresAt: Int64
    }
    nonisolated private struct Document: Codable {
        let schema: Int
        let entries: [Entry]
    }
    private let root: URL
    init(root: URL) { self.root = root }

    private func write(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Document(schema: 3, entries: entries))
        guard data.count <= 64 * 1024 else { throw DiagnosticsAcquisitionStore.Failure.storageFull }
        try data.write(to: root, options: .atomic)
        let handle = try FileHandle(forWritingTo: root)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func entries(at date: Date) throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 64 * 1024 else {
            throw DiagnosticsAcquisitionStore.Failure.invalidManifest
        }
        let bytes = try Data(contentsOf: root)
        let result: [Entry]
        if let document = try? JSONDecoder().decode(Document.self, from: bytes) {
            guard document.schema == 3 else { throw DiagnosticsAcquisitionStore.Failure.invalidManifest }
            result = document.entries
        } else {
            let legacy = try JSONDecoder().decode([DiagnosticsBrokerAcknowledgement].self, from: bytes)
            guard legacy.count <= 100, Set(legacy.map(\.id)).count == legacy.count,
                  legacy.allSatisfy(\.valid) else { throw DiagnosticsAcquisitionStore.Failure.invalidManifest }
            // Old receipts lacked deadlines. Retain them for the maximum
            // command lifetime plus clock allowance, and freeze that migration
            // deadline on disk so polling cannot extend it indefinitely.
            let deadline = Int64(date.timeIntervalSince1970) + 3660
            result = legacy.map { Entry(receipt: $0, expiresAt: deadline) }
            try write(result)
        }
        guard result.count <= 100, Set(result.map { $0.receipt.id }).count == result.count,
              result.allSatisfy({ $0.receipt.valid && $0.expiresAt > 0 }) else {
            throw DiagnosticsAcquisitionStore.Failure.invalidManifest
        }
        return result
    }

    func existing(_ id: UUID, at date: Date = Date()) throws -> DiagnosticsBrokerAcknowledgement? {
        try entries(at: date).first { $0.receipt.id == id && $0.expiresAt > Int64(date.timeIntervalSince1970) }?.receipt
    }

    func save(_ receipt: DiagnosticsBrokerAcknowledgement, expiresAt: Int64, at date: Date = Date()) throws {
        guard receipt.valid else { throw DiagnosticsAcquisitionStore.Failure.invalidManifest }
        let now = Int64(date.timeIntervalSince1970)
        let loaded = try entries(at: date)
        if let previous = loaded.first(where: { $0.receipt.id == receipt.id }) {
            guard previous.expiresAt == expiresAt else { throw DiagnosticsAcquisitionStore.Failure.invalidManifest }
            guard previous.receipt == receipt ||
                    (previous.receipt.state == "interrupted" && previous.receipt.code == "execution_started") else {
                throw DiagnosticsAcquisitionStore.Failure.invalidManifest
            }
        } else {
            guard expiresAt > now, expiresAt <= now + 3660 else { throw DiagnosticsAcquisitionStore.Failure.invalidManifest }
        }
        var retained = loaded.filter { $0.receipt.id != receipt.id && $0.expiresAt > now }
        retained.append(Entry(receipt: receipt, expiresAt: expiresAt))
        guard retained.count <= 100 else { throw DiagnosticsAcquisitionStore.Failure.storageFull }
        try write(retained)
    }

    /// This durable claim is the only permission to execute. Expired replays
    /// cannot regain permission after their receipts have aged out.
    func claim(_ command: DiagnosticsBrokerCommand, at date: Date = Date()) throws -> Claim {
        guard command.valid(at: date) else {
            return Claim(receipt: .init(id: command.id, state: "rejected", code: "invalid_or_expired"), shouldExecute: false)
        }
        if let previous = try existing(command.id, at: date) {
            return Claim(receipt: previous, shouldExecute: false)
        }
        let started = DiagnosticsBrokerAcknowledgement(id: command.id, state: "interrupted", code: "execution_started")
        try save(started, expiresAt: command.expiresAt, at: date)
        return Claim(receipt: started, shouldExecute: true)
    }

    func complete(_ command: DiagnosticsBrokerCommand, receipt: DiagnosticsBrokerAcknowledgement,
                  at date: Date = Date()) throws {
        guard receipt.id == command.id else { throw DiagnosticsAcquisitionStore.Failure.invalidManifest }
        let previous = try entries(at: date).first { $0.receipt.id == command.id }
        guard previous != nil else { throw DiagnosticsAcquisitionStore.Failure.invalidManifest }
        try save(receipt, expiresAt: command.expiresAt, at: date)
    }
}

/// Disk budgets apply to the prospective total, not merely to the outbox before
/// export. Keep admission independent of networking and injectable in host tests.
nonisolated enum DiagnosticsOutboxAdmission {
    static let maximumFiles = 8
    static let maximumBytes = 400 * 1024 * 1024
    static let maximumBundleBytes = 104 * 1024 * 1024

    static func allows(existingCount: Int, existingBytes: Int, additionalBytes: Int) -> Bool {
        existingCount >= 0 && existingCount < maximumFiles &&
            existingBytes >= 0 && existingBytes <= maximumBytes &&
            additionalBytes > 0 && additionalBytes <= maximumBundleBytes &&
            additionalBytes <= maximumBytes - existingBytes
    }
}
