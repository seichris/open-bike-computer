import Foundation

nonisolated enum WatchRouteSyncOperationV1: String, Codable, Equatable, Sendable {
    case install
    case delete
    case acknowledge
}

nonisolated enum WatchRouteSyncStatusV1: String, Codable, Equatable, Sendable {
    case ready
    case deleted
    case evicted
    case rejected
}

nonisolated struct WatchRouteIdentityV1: Codable, Equatable, Hashable, Sendable {
    let routeID: UUID
    let revision: UInt32
    let contentHash: String

    init(routeID: UUID, revision: UInt32, contentHash: String) {
        self.routeID = routeID
        self.revision = revision
        self.contentHash = contentHash
    }

    init(archive: NavigationRouteArchiveV1) {
        self.init(
            routeID: archive.routeID,
            revision: archive.revision,
            contentHash: archive.contentHash
        )
    }
}

nonisolated struct WatchRouteSyncMessageV1: Equatable, Sendable {
    static let schemaVersion: UInt16 = 1

    let operation: WatchRouteSyncOperationV1
    let identity: WatchRouteIdentityV1
    let status: WatchRouteSyncStatusV1?
    let errorCode: String?
    let encodedByteCount: Int?
    let deleteAfter: Date?

    init(
        operation: WatchRouteSyncOperationV1,
        identity: WatchRouteIdentityV1,
        status: WatchRouteSyncStatusV1? = nil,
        errorCode: String? = nil,
        encodedByteCount: Int? = nil,
        deleteAfter: Date? = nil
    ) {
        self.operation = operation
        self.identity = identity
        self.status = status
        self.errorCode = errorCode.map { String($0.prefix(128)) }
        self.encodedByteCount = encodedByteCount
        self.deleteAfter = deleteAfter
    }

    var propertyList: [String: Any] {
        var value: [String: Any] = [
            Keys.schema: Int(Self.schemaVersion),
            Keys.operation: operation.rawValue,
            Keys.routeID: identity.routeID.uuidString.lowercased(),
            // Keep the fixed-width revision intact on 32-bit watchOS. An
            // `Int` cannot represent every valid UInt32 value there.
            Keys.revision: NSNumber(value: identity.revision),
            Keys.contentHash: identity.contentHash
        ]
        if let status {
            value[Keys.status] = status.rawValue
        }
        if let errorCode {
            value[Keys.errorCode] = String(errorCode.prefix(128))
        }
        if let encodedByteCount {
            value[Keys.encodedByteCount] = encodedByteCount
        }
        if let deleteAfter {
            value[Keys.deleteAfter] = deleteAfter
        }
        return value
    }

    init?(propertyList: [String: Any]) {
        guard let schema = Self.integer(propertyList[Keys.schema]),
              schema == Int(Self.schemaVersion),
              let operationRaw = propertyList[Keys.operation] as? String,
              let operation = WatchRouteSyncOperationV1(rawValue: operationRaw),
              let routeIDRaw = propertyList[Keys.routeID] as? String,
              let routeID = UUID(uuidString: routeIDRaw),
              let revision = Self.revision(propertyList[Keys.revision]),
              revision > 0,
              let contentHash = propertyList[Keys.contentHash] as? String,
              contentHash.count == 64,
              contentHash.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            return nil
        }
        let status: WatchRouteSyncStatusV1?
        if let raw = propertyList[Keys.status] as? String {
            guard let parsed = WatchRouteSyncStatusV1(rawValue: raw) else {
                return nil
            }
            status = parsed
        } else {
            status = nil
        }
        let errorCode = propertyList[Keys.errorCode] as? String
        guard errorCode?.utf8.count ?? 0 <= 128 else { return nil }
        let encodedByteCount = Self.integer(
            propertyList[Keys.encodedByteCount]
        )
        if propertyList[Keys.encodedByteCount] != nil {
            guard let encodedByteCount,
                  encodedByteCount > 0,
                  encodedByteCount <=
                    NavigationRouteLimitsV1.production.maximumEncodedBytes else {
                return nil
            }
        }
        let deleteAfter = propertyList[Keys.deleteAfter] as? Date
        if propertyList[Keys.deleteAfter] != nil {
            guard let deleteAfter,
                  deleteAfter.timeIntervalSince1970.isFinite else {
                return nil
            }
        }
        switch operation {
        case .install:
            guard status == nil, errorCode == nil,
                  encodedByteCount != nil else { return nil }
        case .delete:
            guard status == nil, errorCode == nil,
                  encodedByteCount == nil, deleteAfter == nil else { return nil }
        case .acknowledge:
            guard status != nil,
                  encodedByteCount == nil, deleteAfter == nil else { return nil }
            if status == .rejected {
                guard errorCode != nil else { return nil }
            } else {
                guard errorCode == nil else { return nil }
            }
        }
        self.init(
            operation: operation,
            identity: WatchRouteIdentityV1(
                routeID: routeID,
                revision: revision,
                contentHash: contentHash
            ),
            status: status,
            errorCode: errorCode,
            encodedByteCount: encodedByteCount,
            deleteAfter: deleteAfter
        )
    }

    func matches(_ archive: NavigationRouteArchiveV1) -> Bool {
        identity == WatchRouteIdentityV1(archive: archive)
    }

    private enum Keys {
        static let schema = "bicino.route.schema"
        static let operation = "bicino.route.operation"
        static let routeID = "bicino.route.id"
        static let revision = "bicino.route.revision"
        static let contentHash = "bicino.route.hash"
        static let status = "bicino.route.status"
        static let errorCode = "bicino.route.error"
        static let encodedByteCount = "bicino.route.bytes"
        static let deleteAfter = "bicino.route.deleteAfter"
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func revision(_ value: Any?) -> UInt32? {
        if let value = value as? UInt32 { return value }
        if let value = value as? UInt64 { return UInt32(exactly: value) }
        if let value = value as? UInt { return UInt32(exactly: value) }
        if let value = value as? Int64 { return UInt32(exactly: value) }
        if let value = value as? Int { return UInt32(exactly: value) }
        if let value = value as? NSNumber {
            guard let unsigned = UInt64(value.stringValue) else { return nil }
            return UInt32(exactly: unsigned)
        }
        return nil
    }
}

nonisolated enum WatchRouteFilePayloadErrorV1: String, Error, Equatable,
    Sendable {
    case fileRead = "file_read"
    case byteCount = "byte_count"
}

nonisolated enum WatchRouteFilePayloadV1 {
    static func validate(
        request: WatchRouteSyncMessageV1,
        resourceByteCount: Int?,
        data: Data?
    ) -> Result<Data, WatchRouteFilePayloadErrorV1> {
        guard request.operation == .install,
              let expectedByteCount = request.encodedByteCount,
              let resourceByteCount,
              resourceByteCount > 0,
              resourceByteCount <=
                NavigationRouteLimitsV1.production.maximumEncodedBytes else {
            return .failure(.fileRead)
        }
        guard resourceByteCount == expectedByteCount else {
            return .failure(.byteCount)
        }
        guard let data else { return .failure(.fileRead) }
        guard data.count == resourceByteCount else {
            return .failure(.byteCount)
        }
        return .success(data)
    }
}

nonisolated enum WatchRouteAcknowledgementReconciliationV1 {
    static func preservesReadyReceipt(
        hasReadyReceipt: Bool,
        isPendingDeletion: Bool
    ) -> Bool {
        hasReadyReceipt && !isPendingDeletion
    }
}

nonisolated enum WatchRouteDisplayNameContractErrorV1: Error, Equatable {
    case invalidRevision
    case invalidName
    case duplicateIdentity
    case tooManyEntries
    case invalidEnvelope
}

nonisolated struct WatchRouteDisplayNameV1: Codable, Equatable, Sendable {
    let identity: WatchRouteIdentityV1
    let name: String

    init(identity: WatchRouteIdentityV1, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identity.routeID != UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        ), identity.revision > 0,
              identity.contentHash.count == 64,
              identity.contentHash.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }),
              !name.isEmpty, name.utf8.count <= 128 else {
            throw WatchRouteDisplayNameContractErrorV1.invalidName
        }
        self.identity = identity
        self.name = name
    }
}

nonisolated struct WatchRouteDisplayNamesEnvelopeV1: Codable, Equatable,
    Sendable {
    static let applicationContextKey = "bicino.route.displayNames.v1"
    static let maximumEntryCount = 50

    let revision: UInt64
    let entries: [WatchRouteDisplayNameV1]

    init(revision: UInt64, entries: [WatchRouteDisplayNameV1]) throws {
        guard revision > 0 else {
            throw WatchRouteDisplayNameContractErrorV1.invalidRevision
        }
        guard entries.count <= Self.maximumEntryCount else {
            throw WatchRouteDisplayNameContractErrorV1.tooManyEntries
        }
        let entries = try entries.map {
            try WatchRouteDisplayNameV1(identity: $0.identity, name: $0.name)
        }
        guard Set(entries.map(\.identity)).count == entries.count else {
            throw WatchRouteDisplayNameContractErrorV1.duplicateIdentity
        }
        self.revision = revision
        self.entries = entries.sorted(by: Self.precedes)
    }

    func encoded() throws -> Data {
        try PropertyListEncoder().encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        let decoded: Self
        do {
            decoded = try PropertyListDecoder().decode(Self.self, from: data)
        } catch {
            throw WatchRouteDisplayNameContractErrorV1.invalidEnvelope
        }
        return try Self(revision: decoded.revision, entries: decoded.entries)
    }

    private static func precedes(
        _ left: WatchRouteDisplayNameV1,
        _ right: WatchRouteDisplayNameV1
    ) -> Bool {
        let leftID = left.identity.routeID.uuidString
        let rightID = right.identity.routeID.uuidString
        if leftID != rightID { return leftID < rightID }
        if left.identity.revision != right.identity.revision {
            return left.identity.revision < right.identity.revision
        }
        return left.identity.contentHash < right.identity.contentHash
    }
}

/// A high-priority route install used only while the counterpart is reachable.
/// The durable `transferFile` delivery remains authoritative for larger routes
/// and for times when the Watch app is not active.
nonisolated enum WatchRouteImmediateTransferV1 {
    static let maximumEncodedByteCount = 48 * 1_024
    private static let archiveDataKey = "bicino.route.archive"

    static func message(
        install: WatchRouteSyncMessageV1,
        archiveData: Data
    ) -> [String: Any]? {
        guard install.operation == .install,
              install.encodedByteCount == archiveData.count,
              !archiveData.isEmpty,
              archiveData.count <= maximumEncodedByteCount,
              WatchRouteSyncMessageV1(
                  propertyList: install.propertyList
              ) == install else {
            return nil
        }
        var message = install.propertyList
        message[archiveDataKey] = archiveData
        return message
    }

    static func decode(
        _ message: [String: Any]
    ) -> (install: WatchRouteSyncMessageV1, archiveData: Data)? {
        guard let archiveData = message[archiveDataKey] as? Data,
              !archiveData.isEmpty,
              archiveData.count <= maximumEncodedByteCount else {
            return nil
        }
        var metadata = message
        metadata.removeValue(forKey: archiveDataKey)
        guard let install = WatchRouteSyncMessageV1(
            propertyList: metadata
        ), install.operation == .install,
           install.encodedByteCount == archiveData.count else {
            return nil
        }
        return (install, archiveData)
    }
}
