import Foundation

nonisolated struct DeviceMapOperationAdmission: Codable, Equatable {
    let schemaVersion: Int
    let deviceID: String
    let admissionRevision: UInt64
}

// The app's durable observation is deliberately separate from device outcome.
// Neither HTTP completion nor a changed selected map implies installed.
nonisolated struct DeviceMapOperationReceipt: Codable, Equatable {
    let schemaVersion: Int
    let deviceID: String
    let operationID: String
    let sessionID: String?
    let mapID: String?
    let manifestReceipt: String?
    let signedManifestReceipt: String?
    let streamSHA256: String?
    let streamBytes: UInt64?
    let phase: String?
    let revision: UInt64?
    let status: String?

    static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

nonisolated struct DeviceMapOperationRecord: Codable, Equatable {
    let schemaVersion: Int
    let deviceID: String
    let operationID: UUID
    let sessionID: String
    let mapID: String
    let manifestReceipt: String
    let signedManifestReceipt: String
    let streamSHA256: String
    let streamBytes: UInt64
    let artifactFilename: String
    let appNamespace: String
    let createdAt: Date
    let connectionEpoch: UInt64
    var observation: String
    var cleanup: String
    var usesDurableProtocol: Bool
    var lastReceipt: DeviceMapOperationReceipt?
    var admissionRevision: UInt64? = nil
    var uploadAttemptID: UUID? = nil
    var uploadCompletedAt: Date? = nil
    var uploadResponseBody: Data? = nil
    var uploadHTTPStatus: Int? = nil
    var uploadErrorCode: Int? = nil

    var wireOperationID: String {
        operationID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
    var isTerminal: Bool {
        ["installed_confirmed", "failed_or_rolled_back", "cancelled_before_commit"].contains(observation)
    }
    func matches(_ receipt: DeviceMapOperationReceipt) -> Bool {
        receipt.schemaVersion == 1 && receipt.deviceID == deviceID &&
            receipt.operationID == wireOperationID && receipt.sessionID == sessionID &&
            receipt.mapID == mapID && receipt.manifestReceipt == manifestReceipt &&
            receipt.signedManifestReceipt == signedManifestReceipt &&
            receipt.streamSHA256 == streamSHA256 && receipt.streamBytes == streamBytes
    }
    mutating func apply(_ receipt: DeviceMapOperationReceipt) -> Bool {
        guard matches(receipt), receipt.status == nil,
              let revision = receipt.revision, revision > 0,
              ["receiving", "prepared", "accepted", "installed", "failed", "cancelled"].contains(receipt.phase ?? ""),
              revision >= (lastReceipt?.revision ?? 0) else { return false }
        if let lastReceipt, lastReceipt.revision == revision { return lastReceipt == receipt }
        // A late progress callback cannot rewrite a known terminal outcome.
        guard !isTerminal else { return lastReceipt == receipt }
        let phases = ["receiving": 0, "prepared": 1, "accepted": 2, "installed": 3, "failed": 3, "cancelled": 3]
        if let previous = lastReceipt?.phase, let phase = receipt.phase {
            guard (phases[phase] ?? -1) >= (phases[previous] ?? -1),
                  !(previous == "accepted" && phase == "cancelled") else { return false }
        }
        lastReceipt = receipt
        switch receipt.phase {
        case "installed": observation = "installed_confirmed"
        case "failed": observation = "failed_or_rolled_back"
        case "cancelled": observation = "cancelled_before_commit"
        case "accepted": observation = "commit_accepted"
        default: observation = "in_progress"
        }
        return true
    }
}

// Serializes whole-record atomic replacements before network side effects or
// delegate delivery. Corrupt/unknown stores fail closed rather than erase work.
nonisolated final class DeviceMapOperationStore: @unchecked Sendable {
    enum StoreError: Error { case invalidStore, conflict, capacity }
    static let shared = DeviceMapOperationStore()
    private let lock = NSRecursiveLock()
    private let url: URL
    init(url: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.url = url ?? base.appendingPathComponent("DeviceOperations", isDirectory: true)
            .appendingPathComponent("map-operations-v1.json")
    }
    func records() throws -> [DeviceMapOperationRecord] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let records = try JSONDecoder().decode([DeviceMapOperationRecord].self, from: Data(contentsOf: url))
        guard records.count <= 128, records.allSatisfy(Self.isValid),
              Set(records.map(\.operationID)).count == records.count else { throw StoreError.invalidStore }
        return records
    }
    func save(_ record: DeviceMapOperationRecord) throws {
        lock.lock(); defer { lock.unlock() }
        guard Self.isValid(record) else { throw StoreError.invalidStore }
        var records = try self.records()
        if let index = records.firstIndex(where: { $0.operationID == record.operationID }) {
            let old = records[index]
            guard old.deviceID == record.deviceID && old.mapID == record.mapID &&
                    old.sessionID == record.sessionID && old.streamSHA256 == record.streamSHA256 &&
                    old.streamBytes == record.streamBytes && old.manifestReceipt == record.manifestReceipt &&
                    old.signedManifestReceipt == record.signedManifestReceipt &&
                    old.artifactFilename == record.artifactFilename && old.appNamespace == record.appNamespace &&
                    old.createdAt == record.createdAt && old.connectionEpoch == record.connectionEpoch,
                  !(old.usesDurableProtocol && !record.usesDurableProtocol),
                  old.admissionRevision == nil || old.admissionRevision == record.admissionRevision,
                  !old.isTerminal || (old.observation == record.observation && old.lastReceipt == record.lastReceipt),
                  (record.lastReceipt?.revision ?? 0) >= (old.lastReceipt?.revision ?? 0),
                  old.lastReceipt?.revision != record.lastReceipt?.revision || old.lastReceipt == record.lastReceipt else {
                throw StoreError.conflict
            }
            records[index] = record
        } else {
            guard records.count < 128 else { throw StoreError.capacity }
            records.append(record)
        }
        // No implicit eviction: unresolved work and terminal replay evidence stay
        // until an explicit protocol acknowledgement/pruning policy is available.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: url, options: .atomic)
        guard try Data(contentsOf: url) == data else { throw StoreError.invalidStore }
    }
    private static func isValid(_ record: DeviceMapOperationRecord) -> Bool {
        guard record.schemaVersion == 1, !record.deviceID.isEmpty, !record.sessionID.isEmpty,
              !record.mapID.isEmpty, !record.appNamespace.isEmpty, !record.artifactFilename.isEmpty,
              record.streamBytes > 0,
              DeviceMapOperationReceipt.isLowerHex(record.manifestReceipt, count: 64),
              DeviceMapOperationReceipt.isLowerHex(record.signedManifestReceipt, count: 64),
              DeviceMapOperationReceipt.isLowerHex(record.streamSHA256, count: 64) else { return false }
        if let receipt = record.lastReceipt {
            guard record.matches(receipt), (receipt.revision ?? 0) > 0 else { return false }
        }
        if record.usesDurableProtocol && record.isTerminal {
            let phase = ["installed_confirmed": "installed", "failed_or_rolled_back": "failed", "cancelled_before_commit": "cancelled"][record.observation]
            guard phase != nil, record.lastReceipt?.phase == phase else { return false }
        }
        return (record.uploadResponseBody?.count ?? 0) <= 4096
    }

    func beginUpload(operationID: UUID, deviceID: String, appNamespace: String,
                     uploadAttemptID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard var record = try records().first(where: { $0.operationID == operationID }),
              record.deviceID == deviceID, record.appNamespace == appNamespace,
              record.usesDurableProtocol, record.admissionRevision != nil, !record.isTerminal,
              record.lastReceipt?.phase != "accepted" else { throw StoreError.conflict }
        if record.uploadAttemptID == uploadAttemptID { return }
        guard record.uploadAttemptID == nil || record.uploadCompletedAt != nil else { throw StoreError.conflict }
        record.uploadAttemptID = uploadAttemptID
        record.uploadCompletedAt = nil
        record.uploadResponseBody = nil
        record.uploadHTTPStatus = nil
        record.uploadErrorCode = nil
        try save(record)
    }

    // Persist completion before delivering the URLSession callback. A stale or
    // cross-device task can neither ingest another receipt nor overwrite a retry.
    func completeUpload(operationID: UUID, deviceID: String, appNamespace: String,
                        mapID: String, sessionID: String, uploadAttemptID: UUID,
                        responseBody: Data, httpStatus: Int?, errorCode: Int?,
                        now: Date = Date()) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var record = try records().first(where: { $0.operationID == operationID }),
              record.deviceID == deviceID, record.appNamespace == appNamespace,
              record.mapID == mapID, record.sessionID == sessionID,
              record.uploadAttemptID == uploadAttemptID else { return false }
        guard responseBody.count <= 4096 else { throw StoreError.invalidStore }
        if record.uploadCompletedAt != nil { return true }
        if !responseBody.isEmpty {
            struct Envelope: Decodable { let operation: DeviceMapOperationReceipt? }
            if let envelope = try? JSONDecoder().decode(Envelope.self, from: responseBody),
               let receipt = envelope.operation {
                guard record.apply(receipt) else { throw StoreError.conflict }
            }
        }
        record.uploadCompletedAt = now
        record.uploadResponseBody = responseBody
        record.uploadHTTPStatus = httpStatus
        record.uploadErrorCode = errorCode
        // HTTP status is transport evidence only, never installation acceptance.
        try save(record)
        return true
    }

    func ingest(_ receipt: DeviceMapOperationReceipt) throws -> DeviceMapOperationRecord? {
        lock.lock(); defer { lock.unlock() }
        guard var record = try records().first(where: { $0.wireOperationID == receipt.operationID }),
              record.apply(receipt) else { return nil }
        try save(record)
        return record
    }
}
