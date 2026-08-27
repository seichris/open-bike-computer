import Foundation

nonisolated enum StravaRouteReloadBookmarkStoreError: Error, Equatable {
    case invalidData
    case capacityExceeded
    case ioFailure
}

private nonisolated struct StravaRouteReloadBookmarkEnvelopeV1: Codable, Equatable {
    static let schemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let bookmarks: [StravaRouteReloadBookmarkV1]
}

final class StravaRouteReloadBookmarkStoreV1 {
    static let defaultMaximumCount = 100

    let fileURL: URL
    private let maximumCount: Int
    private let fileManager: FileManager

    init(
        fileURL: URL,
        maximumCount: Int = defaultMaximumCount,
        fileManager: FileManager = .default
    ) {
        precondition(maximumCount > 0)
        self.fileURL = fileURL
        self.maximumCount = maximumCount
        self.fileManager = fileManager
    }

    func bookmarks() throws -> [StravaRouteReloadBookmarkV1] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try Self.decode(data, maximumCount: maximumCount)
        } catch let error as StravaRouteReloadBookmarkStoreError {
            throw error
        } catch {
            throw StravaRouteReloadBookmarkStoreError.ioFailure
        }
    }

    func bookmark(routeID: UUID) throws -> StravaRouteReloadBookmarkV1? {
        try bookmarks().first { $0.routeID == routeID }
    }

    func bookmark(externalRouteID: String) throws -> StravaRouteReloadBookmarkV1? {
        try bookmarks().first { $0.externalRouteID == externalRouteID }
    }

    func upsert(_ bookmark: StravaRouteReloadBookmarkV1) throws {
        try bookmark.validate()
        var values = try bookmarks().filter {
            $0.routeID != bookmark.routeID &&
                $0.externalRouteID != bookmark.externalRouteID
        }
        values.append(bookmark)
        try replaceAll(values)
    }

    @discardableResult
    func delete(routeID: UUID) throws -> Bool {
        let existing = try bookmarks()
        let retained = existing.filter { $0.routeID != routeID }
        guard retained.count != existing.count else { return false }
        try replaceAll(retained)
        return true
    }

    @discardableResult
    func purge() throws -> Int {
        let count = (try? bookmarks().count) ?? 0
        guard fileManager.fileExists(atPath: fileURL.path) else { return 0 }
        try replaceAll([])
        return count
    }

    func replaceAll(_ bookmarks: [StravaRouteReloadBookmarkV1]) throws {
        guard bookmarks.count <= maximumCount else {
            throw StravaRouteReloadBookmarkStoreError.capacityExceeded
        }
        var routeIDs = Set<UUID>()
        var externalIDs = Set<String>()
        for bookmark in bookmarks {
            try bookmark.validate()
            guard routeIDs.insert(bookmark.routeID).inserted,
                  externalIDs.insert(bookmark.externalRouteID).inserted else {
                throw StravaRouteReloadBookmarkStoreError.invalidData
            }
        }
        let ordered = bookmarks.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.routeID.uuidString < $1.routeID.uuidString
        }
        let envelope = StravaRouteReloadBookmarkEnvelopeV1(
            schemaVersion: StravaRouteReloadBookmarkEnvelopeV1.schemaVersion,
            bookmarks: ordered
        )
        let data: Data
        do {
            data = try Self.encoder().encode(envelope)
        } catch {
            throw StravaRouteReloadBookmarkStoreError.invalidData
        }
        try writeVerified(data)
    }

    private func writeVerified(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".strava-bookmarks-\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: temporary)
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            let verified = try Data(contentsOf: temporary)
            guard verified == data,
                  (try? Self.decode(verified, maximumCount: maximumCount)) != nil else {
                throw StravaRouteReloadBookmarkStoreError.invalidData
            }
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporary, to: fileURL)
            }
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableURL = fileURL
            try? mutableURL.setResourceValues(resourceValues)
#if os(iOS) || os(watchOS)
            try fileManager.setAttributes(
                [
                    .protectionKey:
                        FileProtectionType.completeUntilFirstUserAuthentication
                ],
                ofItemAtPath: fileURL.path
            )
#endif
        } catch let error as StravaRouteReloadBookmarkStoreError {
            throw error
        } catch {
            throw StravaRouteReloadBookmarkStoreError.ioFailure
        }
    }

    private static func decode(
        _ data: Data,
        maximumCount: Int
    ) throws -> [StravaRouteReloadBookmarkV1] {
        let envelope: StravaRouteReloadBookmarkEnvelopeV1
        do {
            envelope = try decoder().decode(
                StravaRouteReloadBookmarkEnvelopeV1.self,
                from: data
            )
        } catch {
            throw StravaRouteReloadBookmarkStoreError.invalidData
        }
        guard envelope.schemaVersion ==
                StravaRouteReloadBookmarkEnvelopeV1.schemaVersion,
              envelope.bookmarks.count <= maximumCount else {
            throw StravaRouteReloadBookmarkStoreError.invalidData
        }
        var routeIDs = Set<UUID>()
        var externalIDs = Set<String>()
        for bookmark in envelope.bookmarks {
            do { try bookmark.validate() } catch {
                throw StravaRouteReloadBookmarkStoreError.invalidData
            }
            guard routeIDs.insert(bookmark.routeID).inserted,
                  externalIDs.insert(bookmark.externalRouteID).inserted else {
                throw StravaRouteReloadBookmarkStoreError.invalidData
            }
        }
        return envelope.bookmarks
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
