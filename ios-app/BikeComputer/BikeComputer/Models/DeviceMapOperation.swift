import Foundation

// Shared by the real URLSession delegate and the Foundation host harness.
// The OS event acknowledgement waits for both persistence and client delivery.
// A failed write is delivered as an error; the already-persisted upload intent
// remains unresolved and must be queried on recovery.
nonisolated final class DeviceMapUploadCompletionBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCompletions = 0
    private var eventCompletions: [() -> Void] = []

    func complete(persist: () throws -> Void, publish: (Error?) -> Void) {
        lock.lock()
        activeCompletions += 1
        lock.unlock()
        let persistenceError: Error?
        do { try persist(); persistenceError = nil }
        catch { persistenceError = error }
        publish(persistenceError)
        lock.lock()
        activeCompletions -= 1
        let completions = activeCompletions == 0 ? eventCompletions : []
        if activeCompletions == 0 { eventCompletions.removeAll() }
        lock.unlock()
        completions.forEach { $0() }
    }

    func finishEvents(_ completion: @escaping () -> Void) {
        lock.lock()
        if activeCompletions > 0 {
            eventCompletions.append(completion)
            lock.unlock()
        } else {
            lock.unlock()
            completion()
        }
    }
}

nonisolated enum DeviceMapOperationControlAction: String, Equatable, Sendable {
    case query, commit, cancel, none
}

nonisolated struct DeviceMapOperationAdmission: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let deviceID: String
    let admissionRevision: UInt64
    let admissionEpoch: String
}

// The app's durable observation is deliberately separate from device outcome.
// Neither HTTP completion nor a changed selected map implies installed.
nonisolated struct DeviceMapOperationReceipt: Codable, Equatable, Sendable {
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

// Historical context only; never an installation receipt or rollback authority.
nonisolated struct DeviceMapConfirmedSelectionSnapshot: Codable, Equatable, Sendable {
    let deviceID: String
    let mapID: String
    let sessionID: String?
    let manifestReceipt: String?
    let root: String?
    let operationID: String?
    let healthBootID: String?
    let healthRevision: UInt64?
    let connectionEpoch: UInt64
    let observationProcessID: UUID
    let observedAt: Date

    var isValid: Bool {
        guard !deviceID.isEmpty, !mapID.isEmpty else { return false }
        if let manifestReceipt,
           !DeviceMapOperationReceipt.isLowerHex(manifestReceipt, count: 64) { return false }
        if let healthBootID {
            guard DeviceMapOperationReceipt.isLowerHex(healthBootID, count: 32),
                  (healthRevision ?? 0) > 0, let root, Self.isInstallerRoot(root) else { return false }
        } else if healthRevision != nil || root != nil || operationID != nil { return false }
        if let operationID, !DeviceMapOperationReceipt.isLowerHex(operationID, count: 32) { return false }
        return true
    }

    // Same firmware installer-root contract as MapSelectionHealth, which this
    // standalone model cannot import: /VECTMAP or /VECTMAP/.maps/<safe ID>.
    static func isInstallerRoot(_ root: String) -> Bool {
        if root == "/VECTMAP" { return true }
        let prefix = "/VECTMAP/.maps/"
        guard root.hasPrefix(prefix) else { return false }
        let id = root.dropFirst(prefix.count)
        return !id.isEmpty && id.utf8.count <= 80 && !id.hasPrefix(".") && !id.contains("..") &&
            id.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                    $0 == 45 || $0 == 46 || $0 == 95
            }
    }

    static func capture(_ observation: Self, currentDeviceID: String?, currentEpoch: UInt64,
                        currentProcessID: UUID, hasFreshStatus: Bool,
                        isConfirmed: Bool, isUnconfirmed: Bool) -> Self? {
        guard observation.isValid, hasFreshStatus, isConfirmed, !isUnconfirmed,
              observation.deviceID == currentDeviceID,
              observation.connectionEpoch == currentEpoch,
              observation.observationProcessID == currentProcessID else { return nil }
        return observation
    }
}

nonisolated struct DeviceMapOperationRecord: Codable, Equatable, Sendable {
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
    var admissionEpoch: String? = nil
    var admissionRevision: UInt64? = nil
    var uploadAttemptID: UUID? = nil
    var uploadCompletedAt: Date? = nil
    var uploadResponseBody: Data? = nil
    var uploadHTTPStatus: Int? = nil
    var uploadErrorCode: Int? = nil
    var observationProcessID: UUID? = nil
    var commitRequestedAt: Date? = nil
    var cancellationRequestedAt: Date? = nil
    var acknowledgedAt: Date? = nil
    var retiredAt: Date? = nil
    var legacyTerminalConfirmedAt: Date? = nil
    var previousConfirmedSelection: DeviceMapConfirmedSelectionSnapshot? = nil

    mutating func confirmLegacyTerminal(outcome: String, deviceID: String,
                                       connectionEpoch: UInt64, processID: UUID,
                                       now: Date = Date()) -> Bool {
        guard !usesDurableProtocol, lastReceipt == nil, acknowledgedAt == nil,
              self.deviceID == deviceID, self.connectionEpoch == connectionEpoch,
              observationProcessID == processID,
              ["installed_confirmed", "failed_or_rolled_back"].contains(outcome),
              !isTerminal || observation == outcome else { return false }
        observation = outcome
        if legacyTerminalConfirmedAt == nil { legacyTerminalConfirmedAt = now }
        return true
    }

    var hasRetainableTerminalEvidence: Bool {
        guard isTerminal else { return false }
        if usesDurableProtocol { return lastReceipt != nil && acknowledgedAt != nil }
        return legacyTerminalConfirmedAt != nil && observationProcessID != nil &&
            lastReceipt == nil && acknowledgedAt == nil &&
            ["installed_confirmed", "failed_or_rolled_back"].contains(observation)
    }

    // A durable operation owns device admission until its receipt is terminal.
    // A legacy observation can only become terminal in the BLE connection and
    // app process that created it (confirmLegacyTerminal). After either changes
    // it stays unresolved history, but must not block another transfer forever;
    // active OS uploads and the firmware commit grant are fenced separately.
    func blocksNewTransfer(connectionEpoch: UInt64, processID: UUID) -> Bool {
        guard !isTerminal else { return false }
        return usesDurableProtocol ||
            (self.connectionEpoch == connectionEpoch && observationProcessID == processID)
    }


    // Every network control action is selected from durable device evidence.
    // A missing receipt or accepted grant must be queried, never re-uploaded.
    var nextControlAction: DeviceMapOperationControlAction {
        if isTerminal { return .none }
        if lastReceipt?.phase == "accepted" { return .query }
        if cancellationRequestedAt != nil {
            return .cancel
        }
        return lastReceipt?.phase == "prepared" ? .commit : .query
    }


    // Caller must additionally prove this response belongs to the current
    // authenticated BLE epoch and that the old transport session has stopped.
    func permitsPrecommitSessionRecovery(after freshReceipt: DeviceMapOperationReceipt) -> Bool {
        guard usesDurableProtocol, !isTerminal, lastReceipt?.phase != "accepted",
              freshReceipt.schemaVersion == 1, freshReceipt.deviceID == deviceID,
              freshReceipt.operationID == wireOperationID else { return false }
        if freshReceipt.status == "result_unavailable" {
            return commitRequestedAt == nil && cancellationRequestedAt != nil
        }
        return matches(freshReceipt) && freshReceipt == lastReceipt &&
            ["receiving", "prepared"].contains(freshReceipt.phase ?? "")
    }

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
        guard retiredAt == nil, matches(receipt), receipt.status == nil,
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
        default:
            observation = cancellationRequestedAt != nil ? "cancel_requested" :
                (commitRequestedAt != nil ? "commit_requested" : "in_progress")
        }
        return true
    }
}

// Serializes whole-record atomic replacements before network side effects or
// delegate delivery. Corrupt/unknown stores fail closed rather than erase work.
nonisolated final class DeviceMapOperationStore: @unchecked Sendable {
    enum StoreError: Error { case invalidStore, conflict, capacity }
    static let shared = DeviceMapOperationStore()
    static let observationProcessID = UUID()
    private let lock = NSRecursiveLock()
    private let url: URL
    private let atomicWriter: (Data, URL) throws -> Void
    init(url: URL? = nil, atomicWriter: @escaping (Data, URL) throws -> Void = {
        try $0.write(to: $1, options: .atomic)
    }) {
        self.atomicWriter = atomicWriter
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.url = url ?? base.appendingPathComponent("DeviceOperations", isDirectory: true)
            .appendingPathComponent("map-operations-v1.json")
    }
    func records() throws -> [DeviceMapOperationRecord] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let records = try JSONDecoder().decode([DeviceMapOperationRecord].self, from: Data(contentsOf: url))
        guard records.count <= 4096, records.filter({ $0.retiredAt == nil }).count <= 128,
              records.allSatisfy(Self.isValid),
              Set(records.map(\.operationID)).count == records.count else { throw StoreError.invalidStore }
        return records
    }
    func save(_ record: DeviceMapOperationRecord) throws {
        try save(record, replacingUploadAttempt: false)
    }
    private func save(_ record: DeviceMapOperationRecord, replacingUploadAttempt: Bool) throws {
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
                    old.createdAt == record.createdAt && old.connectionEpoch == record.connectionEpoch &&
                    old.observationProcessID == record.observationProcessID &&
                    old.previousConfirmedSelection == record.previousConfirmedSelection,
                  replacingUploadAttempt || old.uploadAttemptID == record.uploadAttemptID,
                  replacingUploadAttempt || old.uploadCompletedAt == nil ||
                    (old.uploadCompletedAt == record.uploadCompletedAt && old.uploadResponseBody == record.uploadResponseBody &&
                     old.uploadHTTPStatus == record.uploadHTTPStatus && old.uploadErrorCode == record.uploadErrorCode),
                  !(old.usesDurableProtocol && !record.usesDurableProtocol),
                  old.admissionRevision == nil || old.admissionRevision == record.admissionRevision,
                  old.admissionEpoch == nil || old.admissionEpoch == record.admissionEpoch,
                  old.commitRequestedAt == nil || old.commitRequestedAt == record.commitRequestedAt,
                  old.cancellationRequestedAt == nil || old.cancellationRequestedAt == record.cancellationRequestedAt,
                  old.acknowledgedAt == nil || old.acknowledgedAt == record.acknowledgedAt,
                  old.legacyTerminalConfirmedAt == nil || old.legacyTerminalConfirmedAt == record.legacyTerminalConfirmedAt,
                  old.retiredAt == record.retiredAt,
                  !old.isTerminal || (old.observation == record.observation && old.lastReceipt == record.lastReceipt),
                  (record.lastReceipt?.revision ?? 0) >= (old.lastReceipt?.revision ?? 0),
                  old.lastReceipt?.revision != record.lastReceipt?.revision || old.lastReceipt == record.lastReceipt else {
                throw StoreError.conflict
            }
            records[index] = record
        } else {
            records = Self.retained(records, now: Date(), reserveSlot: true, protecting: record.operationID)
            guard records.filter({ $0.retiredAt == nil }).count < 128,
                  records.count < 4096 else { throw StoreError.capacity }
            records.append(record)
        }
        records = Self.retained(records, now: Date(), reserveSlot: false, protecting: record.operationID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try atomicWriter(data, url)
        guard try Data(contentsOf: url) == data else { throw StoreError.invalidStore }
    }
    // Compact after durable receipt + ACK, or legacy terminal evidence observed
    // in its original process/connection (legacy IDs never reach the device).
    // Require finished OS transport and lease cleanup. Keep exact terminal
    // evidence as a 30-day tombstone so a late callback cannot revive an old ID.
    private static func retained(_ input: [DeviceMapOperationRecord], now: Date,
                                 reserveSlot: Bool, protecting: UUID?) -> [DeviceMapOperationRecord] {
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        var records = input.filter { $0.operationID == protecting || $0.retiredAt == nil || $0.retiredAt! > cutoff }
        let eligible = records.indices.filter {
            let r = records[$0]
            return r.retiredAt == nil && r.hasRetainableTerminalEvidence && r.cleanup == "complete" &&
                (r.uploadAttemptID == nil || r.uploadCompletedAt != nil)
        }.sorted {
            (records[$0].acknowledgedAt ?? records[$0].legacyTerminalConfirmedAt ?? .distantFuture) <
            (records[$1].acknowledgedAt ?? records[$1].legacyTerminalConfirmedAt ?? .distantFuture)
        }
        var liveCount = records.filter { $0.retiredAt == nil }.count
        var fullHistory = eligible.count
        for index in eligible where records[index].operationID != protecting {
            guard fullHistory > 64 || (reserveSlot && liveCount >= 128) else { break }
            records[index].retiredAt = now
            records[index].uploadResponseBody = nil
            liveCount -= 1
            fullHistory -= 1
        }
        return records
    }

    func pruneAcknowledgedHistory(now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        let retained = Self.retained(try records(), now: now, reserveSlot: false, protecting: nil)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(retained)
        try atomicWriter(data, url)
        guard try Data(contentsOf: url) == data else { throw StoreError.invalidStore }
    }

    func markAcknowledged(operationID: UUID, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        guard var record = try records().first(where: { $0.operationID == operationID }),
              record.isTerminal, record.lastReceipt != nil else { throw StoreError.conflict }
        if record.acknowledgedAt == nil { record.acknowledgedAt = now }
        try save(record)
    }

    func markCleanupComplete(operationID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard var record = try records().first(where: { $0.operationID == operationID }) else { throw StoreError.conflict }
        record.cleanup = "complete"
        try save(record)
    }

    private static func isValid(_ record: DeviceMapOperationRecord) -> Bool {
        guard record.schemaVersion == 1, !record.deviceID.isEmpty, !record.sessionID.isEmpty,
              !record.mapID.isEmpty, !record.appNamespace.isEmpty, !record.artifactFilename.isEmpty,
              record.streamBytes > 0,
              DeviceMapOperationReceipt.isLowerHex(record.manifestReceipt, count: 64),
              DeviceMapOperationReceipt.isLowerHex(record.signedManifestReceipt, count: 64),
              DeviceMapOperationReceipt.isLowerHex(record.streamSHA256, count: 64) else { return false }
        if let previous = record.previousConfirmedSelection {
            guard previous.isValid, previous.deviceID == record.deviceID,
                  previous.connectionEpoch == record.connectionEpoch,
                  previous.observationProcessID == record.observationProcessID,
                  previous.observedAt <= record.createdAt else { return false }
        }
        if let receipt = record.lastReceipt {
            guard record.matches(receipt), receipt.status == nil, (receipt.revision ?? 0) > 0,
                  ["receiving", "prepared", "accepted", "installed", "failed", "cancelled"].contains(receipt.phase ?? "") else { return false }
        }
        if record.usesDurableProtocol && record.isTerminal {
            let phase = ["installed_confirmed": "installed", "failed_or_rolled_back": "failed", "cancelled_before_commit": "cancelled"][record.observation]
            guard phase != nil, record.lastReceipt?.phase == phase else { return false }
        }
        if record.legacyTerminalConfirmedAt != nil {
            guard !record.usesDurableProtocol, record.hasRetainableTerminalEvidence else { return false }
        }
        if record.retiredAt != nil {
            guard record.hasRetainableTerminalEvidence, record.cleanup == "complete",
                  record.uploadAttemptID == nil || record.uploadCompletedAt != nil else { return false }
        }
        return (record.uploadResponseBody?.count ?? 0) <= 4096
    }

    func beginUpload(operationID: UUID, deviceID: String, appNamespace: String,
                     uploadAttemptID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard var record = try records().first(where: { $0.operationID == operationID }),
              record.deviceID == deviceID, record.appNamespace == appNamespace,
              record.usesDurableProtocol, record.admissionRevision != nil, record.admissionEpoch != nil, !record.isTerminal,
              !["prepared", "accepted"].contains(record.lastReceipt?.phase ?? ""),
              record.commitRequestedAt == nil, record.cancellationRequestedAt == nil else { throw StoreError.conflict }
        if record.uploadAttemptID == uploadAttemptID { return }
        guard record.uploadAttemptID == nil || record.uploadCompletedAt != nil else { throw StoreError.conflict }
        record.uploadAttemptID = uploadAttemptID
        record.uploadCompletedAt = nil
        record.uploadResponseBody = nil
        record.uploadHTTPStatus = nil
        record.uploadErrorCode = nil
        try save(record, replacingUploadAttempt: true)
    }

    func retireInterruptedTransport(operationID: UUID) throws -> DeviceMapOperationRecord {
        lock.lock(); defer { lock.unlock() }
        guard var record = try records().first(where: { $0.operationID == operationID }),
              record.lastReceipt?.phase == "receiving", record.commitRequestedAt == nil,
              record.cancellationRequestedAt == nil, !record.isTerminal else { throw StoreError.conflict }
        if record.uploadAttemptID != nil, record.uploadCompletedAt == nil {
            record.uploadCompletedAt = Date()
            record.uploadErrorCode = -1005
        }
        try save(record)
        return record
    }

    func requestCommit(operationID: UUID, now: Date = Date()) throws -> DeviceMapOperationRecord {
        lock.lock(); defer { lock.unlock() }
        guard var record = try records().first(where: { $0.operationID == operationID }),
              record.usesDurableProtocol, record.nextControlAction == .commit,
              record.lastReceipt?.phase == "prepared", record.cancellationRequestedAt == nil else {
            throw StoreError.conflict
        }
        if record.commitRequestedAt == nil { record.commitRequestedAt = now }
        record.observation = "commit_requested"
        try save(record)
        return record
    }

    func requestCancellation(operationID: UUID, now: Date = Date()) throws -> DeviceMapOperationRecord {
        lock.lock(); defer { lock.unlock() }
        guard var record = try records().first(where: { $0.operationID == operationID }),
              record.usesDurableProtocol else { throw StoreError.conflict }
        // The device won the race. Never send cancel for a known grant/terminal.
        if record.isTerminal || record.lastReceipt?.phase == "accepted" { return record }
        if record.cancellationRequestedAt == nil { record.cancellationRequestedAt = now }
        record.observation = "cancel_requested"
        try save(record)
        return record
    }

    func markControlResponseUnknown(operationID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard var record = try records().first(where: { $0.operationID == operationID }),
              !record.isTerminal, record.lastReceipt?.phase != "accepted" else { return }
        record.observation = "result_unknown"
        try save(record)
    }

    // Caller first verifies there is no matching OS-owned upload. Missing
    // server intent is replayable only under the originally persisted admission.
    func prepareReplayAfterUnavailable(operationID: UUID, admission: DeviceMapOperationAdmission) throws -> DeviceMapOperationRecord {
        lock.lock(); defer { lock.unlock() }
        guard var record = try records().first(where: { $0.operationID == operationID }),
              record.usesDurableProtocol, !record.isTerminal, record.lastReceipt == nil,
              record.commitRequestedAt == nil, record.cancellationRequestedAt == nil,
              admission.schemaVersion == 1, admission.deviceID == record.deviceID,
              record.admissionEpoch == admission.admissionEpoch,
              record.admissionRevision == admission.admissionRevision else { throw StoreError.conflict }
        if record.uploadAttemptID != nil, record.uploadCompletedAt == nil {
            record.uploadCompletedAt = Date()
            record.uploadErrorCode = -1005 // Lost transport; no device result implied.
        }
        try save(record)
        return record
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
              record.retiredAt == nil, record.uploadAttemptID == uploadAttemptID else { return false }
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
