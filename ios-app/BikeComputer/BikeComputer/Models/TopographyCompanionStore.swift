import Foundation
import CryptoKit
import SQLite3
import ImageIO
import Darwin

/// Supplied by authenticated catalog publication metadata, never inferred from
/// a filename or a downloaded database's self-declared identity.
nonisolated struct TopographyCompanionReceipt: Codable, Equatable, Sendable {
    let mapEntryID: String
    let mapContentReceipt: String
    let mapID: String
    let sha256: String
    let bytes: Int64
    let intermediateSha256: String
    let sourcePolicySha256: String
    let attributionSha256: String

    func validate() throws {
        guard !mapEntryID.isEmpty, mapEntryID.utf8.count <= 128,
              !mapID.isEmpty, mapID.utf8.count <= 128,
              (512...Int64(256 * 1024 * 1024)).contains(bytes),
              [mapContentReceipt, sha256, intermediateSha256, sourcePolicySha256, attributionSha256]
                .allSatisfy(Self.isDigest) else { throw TopographyCompanionError.receipt }
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

nonisolated struct TopographyCompanionMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let profileVersion: Int
    let styleId: String
    let tileScheme: String
    let tileSize: Int
    let scales: [Int]
    let minimumZoom: Int
    let maximumZoom: Int
    let mapId: String
    let intermediateSha256: String
    let sourcePolicySha256: String
    let attributionSha256: String
    let boundsE7: [Int]
    let tileCount: Int

    func validate(receipt: TopographyCompanionReceipt) throws {
        guard schemaVersion == 1, profileVersion == 1,
              styleId == "contours-transparent-20-50-v1", tileScheme == "xyz",
              tileSize == 256, scales == [1, 2], minimumZoom == 9, maximumZoom == 16,
              mapId == receipt.mapID, intermediateSha256 == receipt.intermediateSha256,
              sourcePolicySha256 == receipt.sourcePolicySha256, attributionSha256 == receipt.attributionSha256,
              boundsE7.count == 4, (0...16384).contains(tileCount) else { throw TopographyCompanionError.metadata }
        guard -1800000000 <= boundsE7[0], boundsE7[0] < boundsE7[2], boundsE7[2] <= 1800000000,
              -850511288 <= boundsE7[1], boundsE7[1] < boundsE7[3], boundsE7[3] <= 850511288 else {
            throw TopographyCompanionError.metadata
        }
    }
}

nonisolated enum TopographyCompanionError: Error {
    case receipt, file, database, schema, metadata, tile, closed
}

/// Durable binding between one verified companion and the exact saved stream
/// it decorates. A stale companion can remain on disk during crash recovery,
/// but it is never selected unless every association identity still matches.
nonisolated struct SavedTopographyCompanionAssociation: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let localArtifactFilename: String
    let streamArtifactSHA256: String
    let receipt: TopographyCompanionReceipt

    func validate() throws {
        try receipt.validate()
        guard schemaVersion == Self.currentSchemaVersion,
              localArtifactFilename == "topography-\(receipt.mapEntryID).btopo",
              TopographyCompanionReceipt.isDigest(streamArtifactSHA256) else {
            throw TopographyCompanionError.receipt
        }
    }
}

nonisolated enum SavedTopographyCompanionStorage {
    static func filename(mapEntryID: String) -> String? {
        let isCatalogID = mapEntryID.range(
            of: "^map_v1_[A-Za-z0-9_-]{43}$",
            options: .regularExpression
        ) != nil
        let isJobID = mapEntryID.range(
            of: "^job_v1_[A-Za-z0-9_-]{8,64}$",
            options: .regularExpression
        ) != nil
        guard isCatalogID || isJobID else { return nil }
        return "topography-\(mapEntryID).btopo"
    }

    static func associationURL(for companionURL: URL) -> URL {
        companionURL.appendingPathExtension("association.json")
    }

    static func load(
        for companionURL: URL,
        expectedMapEntryID: String,
        expectedMapContentReceipt: String,
        expectedStreamArtifactSHA256: String
    ) -> SavedTopographyCompanionAssociation? {
        guard let data = try? Data(contentsOf: associationURL(for: companionURL)),
              let value = try? JSONDecoder().decode(
                SavedTopographyCompanionAssociation.self,
                from: data
              ),
              (try? value.validate()) != nil,
              value.localArtifactFilename == companionURL.lastPathComponent,
              value.receipt.mapEntryID == expectedMapEntryID,
              value.receipt.mapContentReceipt == expectedMapContentReceipt,
              value.streamArtifactSHA256 == expectedStreamArtifactSHA256 else {
            return nil
        }
        return value
    }

    static func save(
        _ value: SavedTopographyCompanionAssociation,
        for companionURL: URL
    ) throws {
        try value.validate()
        guard value.localArtifactFilename == companionURL.lastPathComponent else {
            throw TopographyCompanionError.receipt
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(
            to: associationURL(for: companionURL),
            options: .atomic
        )
    }

    static func delete(for companionURL: URL) throws {
        let manager = FileManager.default
        for url in [companionURL, associationURL(for: companionURL)]
        where manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
    }
}

/// Crash-safe two-file replacement for a companion and its external binding.
/// The journal is committed only after both new files and the directory have
/// been synchronized. Recovery therefore keeps either the old pair or the new
/// pair, never a newly trusted database with an old association.
nonisolated struct SavedTopographyCompanionReplacementJournal: Codable {
    static let suffix = ".topography-replacement.json"

    let filename: String
    let id: UUID
    let hadArtifact: Bool
    let hadAssociation: Bool
    var committed: Bool

    func artifact(in directory: URL) -> URL {
        directory.appendingPathComponent(filename)
    }

    func backup(in directory: URL) -> URL {
        directory.appendingPathComponent(".\(filename).\(id.uuidString).backup")
    }

    func url(in directory: URL) -> URL {
        directory.appendingPathComponent(".\(filename)\(Self.suffix)")
    }

    static func sync(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }

    func save(in directory: URL) throws {
        try JSONEncoder().encode(self).write(to: url(in: directory), options: .atomic)
        try Self.sync(url(in: directory))
        try Self.sync(directory)
    }

    static func begin(at destination: URL) throws -> Self {
        guard destination.pathExtension == "btopo",
              destination.lastPathComponent == URL(
                fileURLWithPath: destination.lastPathComponent
              ).lastPathComponent else {
            throw POSIXError(.EINVAL)
        }
        let manager = FileManager.default
        let value = Self(
            filename: destination.lastPathComponent,
            id: UUID(),
            hadArtifact: manager.fileExists(atPath: destination.path),
            hadAssociation: manager.fileExists(
                atPath: SavedTopographyCompanionStorage
                    .associationURL(for: destination).path
            ),
            committed: false
        )
        try value.save(in: destination.deletingLastPathComponent())
        return value
    }

    func finish(in directory: URL) throws {
        let manager = FileManager.default
        let destination = artifact(in: directory)
        let previous = backup(in: directory)
        let pairs = [
            (destination, previous, hadArtifact),
            (
                SavedTopographyCompanionStorage.associationURL(for: destination),
                SavedTopographyCompanionStorage.associationURL(for: previous),
                hadAssociation
            ),
        ]
        for (current, backup, existed) in pairs {
            if manager.fileExists(atPath: backup.path) {
                if committed {
                    try manager.removeItem(at: backup)
                } else {
                    if manager.fileExists(atPath: current.path) {
                        try manager.removeItem(at: current)
                    }
                    try manager.moveItem(at: backup, to: current)
                }
            } else if !committed && !existed && manager.fileExists(atPath: current.path) {
                try manager.removeItem(at: current)
            }
        }
        try Self.sync(directory)
        try manager.removeItem(at: url(in: directory))
        try Self.sync(directory)
    }

    static func recover(in directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        for file in files where file.lastPathComponent.hasSuffix(Self.suffix) {
            let values = try file.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 4096 else {
                throw POSIXError(.EINVAL)
            }
            let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            guard value.filename.hasPrefix("topography-"),
                  value.filename.hasSuffix(".btopo"),
                  !value.filename.contains("/"),
                  !value.filename.contains("\\"),
                  SavedTopographyCompanionStorage.filename(
                    mapEntryID: String(
                        value.filename.dropFirst("topography-".count).dropLast(".btopo".count)
                    )
                  ) == value.filename,
                  value.url(in: directory).standardizedFileURL == file.standardizedFileURL else {
                throw POSIXError(.EINVAL)
            }
            try value.finish(in: directory)
        }
    }
}

// Only accessed by the owning actor. The holder makes connection cleanup
// independent of actor-deinit isolation rules; it never exports the pointer.
private nonisolated final class TopographyDatabase: @unchecked Sendable {
    let handle: OpaquePointer
    init(url: URL) throws {
        var pointer: OpaquePointer?
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        guard sqlite3_open_v2(components.string, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw TopographyCompanionError.database
        }
        handle = pointer
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 1024 * 1024 + 65536)
        sqlite3_limit(handle, SQLITE_LIMIT_SQL_LENGTH, 8192)
        sqlite3_limit(handle, SQLITE_LIMIT_COLUMN, 32)
        try execute("PRAGMA trusted_schema=OFF")
        try execute("PRAGMA query_only=ON")
    }

    deinit { sqlite3_close(handle) }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw TopographyCompanionError.database
        }
        return statement
    }

    func execute(_ sql: String) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw TopographyCompanionError.database }
    }

    func integer(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
            throw TopographyCompanionError.database
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    static func text(_ statement: OpaquePointer, _ column: Int32, maximum: Int) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              sqlite3_column_bytes(statement, column) <= maximum,
              let value = sqlite3_column_text(statement, column),
              let text = String(bytes: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8) else {
            throw TopographyCompanionError.database
        }
        return text
    }
}

/// Reads only an immutable, receipt-verified Application Support file. Downloads
/// and association journaling belong to OfflineMapManager, not this tile reader.
actor TopographyCompanionStore {
    private let url: URL
    let receipt: TopographyCompanionReceipt
    private var database: TopographyDatabase?
    private var metadata: TopographyCompanionMetadata?
    private var tileCache: [TileKey: Data] = [:]
    private var cacheOrder: [TileKey] = []
    private var cacheBytes = 0
    private static let cacheLimit = 4 * 1024 * 1024

    private struct TileKey: Hashable { let z: Int; let x: Int; let y: Int; let scale: Int }

    init(url: URL, receipt: TopographyCompanionReceipt) {
        self.url = url
        self.receipt = receipt
    }

    @discardableResult
    func validate() throws -> TopographyCompanionMetadata {
        if let metadata { return metadata }
        try receipt.validate()
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard url.isFileURL, attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              attributes.fileSize.map(Int64.init) == receipt.bytes else { throw TopographyCompanionError.file }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256(), count: Int64 = 0
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            count += Int64(data.count)
            guard count <= receipt.bytes else { throw TopographyCompanionError.file }
            hash.update(data: data)
        }
        guard count == receipt.bytes, Self.hex(hash.finalize()) == receipt.sha256 else { throw TopographyCompanionError.receipt }
        let database = try TopographyDatabase(url: url)
        guard try database.integer("PRAGMA application_id") == 0x42544F50,
              try database.integer("PRAGMA user_version") == 1,
              try database.integer("PRAGMA page_size") == 4096,
              try database.integer("SELECT count(*) FROM sqlite_schema") == 2 else { throw TopographyCompanionError.schema }
        let schemas = [
            "CREATE TABLE metadata (id INTEGER PRIMARY KEY CHECK (id = 1), json TEXT NOT NULL)",
            "CREATE TABLE tiles (z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL, scale INTEGER NOT NULL, png BLOB NOT NULL, sha256 TEXT NOT NULL, PRIMARY KEY (z, x, y, scale)) WITHOUT ROWID"
        ]
        let schema = try database.prepare("SELECT type, name, sql FROM sqlite_schema ORDER BY name")
        defer { sqlite3_finalize(schema) }
        for (index, name) in ["metadata", "tiles"].enumerated() {
            guard sqlite3_step(schema) == SQLITE_ROW,
                  try TopographyDatabase.text(schema, 0, maximum: 16) == "table",
                  try TopographyDatabase.text(schema, 1, maximum: 16) == name,
                  try TopographyDatabase.text(schema, 2, maximum: 1024) == schemas[index] else { throw TopographyCompanionError.schema }
        }
        guard sqlite3_step(schema) == SQLITE_DONE,
              try database.integer("SELECT count(*) FROM metadata") == 1 else { throw TopographyCompanionError.metadata }
        let row = try database.prepare("SELECT json FROM metadata WHERE id = 1")
        defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW else { throw TopographyCompanionError.metadata }
        let json = try TopographyDatabase.text(row, 0, maximum: 16384)
        let metadata = try JSONDecoder().decode(TopographyCompanionMetadata.self, from: Data(json.utf8))
        try metadata.validate(receipt: receipt)
        // Exact canonical JSON rejects duplicate keys, extras, booleans in
        // numeric fields and alternate whitespace/number representations.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(metadata) + Data([10]) == Data(json.utf8),
              try database.integer("SELECT count(*) FROM tiles") == metadata.tileCount else { throw TopographyCompanionError.metadata }
        let check = try database.prepare("PRAGMA quick_check")
        defer { sqlite3_finalize(check) }
        guard sqlite3_step(check) == SQLITE_ROW,
              try TopographyDatabase.text(check, 0, maximum: 256) == "ok",
              sqlite3_step(check) == SQLITE_DONE else { throw TopographyCompanionError.database }
        let tiles = try database.prepare("SELECT z, x, y, scale, png, sha256 FROM tiles ORDER BY z, x, y, scale")
        defer { sqlite3_finalize(tiles) }
        var keys = Set<TileKey>()
        var status = sqlite3_step(tiles)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            guard (0..<4).allSatisfy({ sqlite3_column_type(tiles, Int32($0)) == SQLITE_INTEGER }) else { throw TopographyCompanionError.tile }
            let values = (0..<4).map { Int(sqlite3_column_int64(tiles, Int32($0))) }
            let key = TileKey(z: values[0], x: values[1], y: values[2], scale: values[3])
            guard Self.valid(key), keys.count < 16384 else { throw TopographyCompanionError.tile }
            _ = try Self.tileData(tiles, pngColumn: 4, shaColumn: 5, scale: key.scale)
            keys.insert(key)
            status = sqlite3_step(tiles)
        }
        guard status == SQLITE_DONE, keys.count == metadata.tileCount,
              keys.allSatisfy({ keys.contains(TileKey(z: $0.z, x: $0.x, y: $0.y, scale: 3 - $0.scale)) }) else {
            throw TopographyCompanionError.tile
        }
        self.database = database
        self.metadata = metadata
        return metadata
    }

    func tile(z: Int, x: Int, y: Int, scale: Int) throws -> Data? {
        try Task.checkCancellation()
        guard let database, metadata != nil else { throw TopographyCompanionError.closed }
        let key = TileKey(z: z, x: x, y: y, scale: scale)
        guard Self.valid(key) else { return nil }
        if let data = tileCache[key] { return data }
        let statement = try database.prepare("SELECT png, sha256 FROM tiles WHERE z=? AND x=? AND y=? AND scale=?")
        defer { sqlite3_finalize(statement) }
        for (index, value) in [z, x, y, scale].enumerated() { sqlite3_bind_int64(statement, Int32(index + 1), Int64(value)) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw TopographyCompanionError.database }
        let data = try Self.tileData(statement, pngColumn: 0, shaColumn: 1, scale: scale)
        while cacheBytes + data.count > Self.cacheLimit || cacheOrder.count >= 128 {
            let oldest = cacheOrder.removeFirst()
            cacheBytes -= tileCache.removeValue(forKey: oldest)?.count ?? 0
        }
        tileCache[key] = data; cacheOrder.append(key); cacheBytes += data.count
        return data
    }

    func close() {
        tileCache.removeAll(); cacheOrder.removeAll(); cacheBytes = 0
        metadata = nil; database = nil
    }

    func purgeCache() {
        tileCache.removeAll()
        cacheOrder.removeAll()
        cacheBytes = 0
    }

    private static func valid(_ key: TileKey) -> Bool {
        (9...16).contains(key.z) && (1...2).contains(key.scale) &&
            (0..<(1 << key.z)).contains(key.x) && (0..<(1 << key.z)).contains(key.y)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func tileData(_ statement: OpaquePointer, pngColumn: Int32, shaColumn: Int32, scale: Int) throws -> Data {
        let length = Int(sqlite3_column_bytes(statement, pngColumn))
        guard sqlite3_column_type(statement, pngColumn) == SQLITE_BLOB, (33...1024 * 1024).contains(length),
              let blob = sqlite3_column_blob(statement, pngColumn) else { throw TopographyCompanionError.tile }
        let data = Data(bytes: blob, count: length)
        guard Self.hex(SHA256.hash(data: data)) == (try TopographyDatabase.text(statement, shaColumn, maximum: 64)),
              data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]), data[24] == 8, data[25] == 6,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == 256 * scale,
              properties[kCGImagePropertyPixelHeight] as? Int == 256 * scale,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw TopographyCompanionError.tile }
        return data
    }
}
