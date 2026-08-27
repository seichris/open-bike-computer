import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum NavigationRouteFileStoreError: Error, Equatable {
    case ioFailure
    case capacityExceeded
    case staleRevision
    case revisionConflict
    case notFound
}

struct InstalledNavigationRouteV1: Equatable {
    let archive: NavigationRouteArchiveV1
    let fileURL: URL
    let encodedSize: Int

    var summary: PlannedRouteSummaryV1 {
        PlannedRouteSummaryV1(archive: archive)
    }
}

struct NavigationRouteFileStoreLimitsV1: Equatable {
    static let phone = NavigationRouteFileStoreLimitsV1(
        maximumArchiveCount: 50,
        maximumTotalEncodedBytes: 64 * 1_024 * 1_024
    )
    static let watch = NavigationRouteFileStoreLimitsV1(
        maximumArchiveCount: 10,
        maximumTotalEncodedBytes: 50 * 1_024 * 1_024
    )

    let maximumArchiveCount: Int
    let maximumTotalEncodedBytes: Int
}

final class NavigationRouteFileStoreV1 {
    let rootDirectory: URL
    private let fileManager: FileManager
    private let limits: NavigationRouteFileStoreLimitsV1

    init(
        rootDirectory: URL,
        limits: NavigationRouteFileStoreLimitsV1 = .phone,
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.limits = limits
        self.fileManager = fileManager
    }

    @discardableResult
    func install(
        _ data: Data,
        now: Date = Date(),
        evictingOldestUnprotected protectedIdentities:
            Set<WatchRouteIdentityV1>? = nil
    ) throws -> InstalledNavigationRouteV1 {
        try install(
            data,
            now: now,
            evictingOldestUnprotected: protectedIdentities,
            cleanupFailuresAreFatal: true,
            committing: {}
        )
    }

    /// Stages and verifies a new archive, commits its companion metadata, and
    /// only then retires the previous revision. If metadata persistence fails,
    /// the staged archive is removed and the prior revision remains intact.
    @discardableResult
    func installAtomically(
        _ data: Data,
        now: Date = Date(),
        committing companionMetadata: () throws -> Void
    ) throws -> InstalledNavigationRouteV1 {
        try install(
            data,
            now: now,
            evictingOldestUnprotected: nil,
            cleanupFailuresAreFatal: false,
            committing: companionMetadata
        )
    }

    private func install(
        _ data: Data,
        now: Date,
        evictingOldestUnprotected protectedIdentities:
            Set<WatchRouteIdentityV1>?,
        cleanupFailuresAreFatal: Bool,
        committing companionMetadata: () throws -> Void
    ) throws -> InstalledNavigationRouteV1 {
        let archive = try NavigationRouteArchiveV1.decode(
            data,
            purpose: .offlineNavigation,
            now: now
        )
        _ = pruneInvalidAndExpired(now: now)
        let current = records(now: now)
        let sameRoute = current.filter { $0.archive.routeID == archive.routeID }
        if let newest = sameRoute.max(by: {
            $0.archive.revision < $1.archive.revision
        }) {
            if newest.archive.revision > archive.revision {
                throw NavigationRouteFileStoreError.staleRevision
            }
            if newest.archive.revision == archive.revision,
               newest.archive.contentHash != archive.contentHash {
                throw NavigationRouteFileStoreError.revisionConflict
            }
            if newest.archive.contentHash == archive.contentHash {
                try companionMetadata()
                if cleanupFailuresAreFatal {
                    try removeSuperseded(
                        sameRoute,
                        keeping: newest.fileURL
                    )
                } else {
                    try? removeSuperseded(
                        sameRoute,
                        keeping: newest.fileURL
                    )
                }
                return newest
            }
        }

        var retained = current.filter {
            $0.archive.routeID != archive.routeID
        }
        var recordsToEvict: [InstalledNavigationRouteV1] = []
        while retained.count + 1 > limits.maximumArchiveCount ||
                retained.reduce(data.count, { $0 + $1.encodedSize }) >
                limits.maximumTotalEncodedBytes {
            guard let protectedIdentities else {
                throw NavigationRouteFileStoreError.capacityExceeded
            }
            let evictionCandidates = retained.indices.filter { index in
                !protectedIdentities.contains(
                    WatchRouteIdentityV1(archive: retained[index].archive)
                )
            }
            guard let evictionIndex = evictionCandidates.min(by: {
                Self.isOlder(retained[$0], than: retained[$1])
            }) else {
                throw NavigationRouteFileStoreError.capacityExceeded
            }
            recordsToEvict.append(retained.remove(at: evictionIndex))
        }

        try prepareDirectory()
        let destination = fileURL(for: WatchRouteIdentityV1(archive: archive))
        do {
            try verifiedAtomicWrite(
                data,
                archive: archive,
                destination: destination,
                now: now
            )
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableDestination = destination
            try? mutableDestination.setResourceValues(resourceValues)
#if os(iOS) || os(watchOS)
            try fileManager.setAttributes(
                [
                    .protectionKey:
                        FileProtectionType.completeUntilFirstUserAuthentication
                ],
                ofItemAtPath: destination.path
            )
#endif
        } catch {
            throw NavigationRouteFileStoreError.ioFailure
        }

        do {
            try companionMetadata()
        } catch {
            try? fileManager.removeItem(at: destination)
            try? synchronizeRootDirectory()
            throw error
        }
        if cleanupFailuresAreFatal {
            try removeSuperseded(sameRoute, keeping: destination)
            try removeSuperseded(recordsToEvict, keeping: destination)
        } else {
            // Companion metadata now points at the fully verified new archive.
            // A stale older file is harmless and will be hidden by record
            // reconciliation; do not turn a committed reload into ambiguity.
            try? removeSuperseded(sameRoute, keeping: destination)
            try? removeSuperseded(recordsToEvict, keeping: destination)
        }
        return InstalledNavigationRouteV1(
            archive: archive,
            fileURL: destination,
            encodedSize: data.count
        )
    }

    func records(now: Date = Date()) -> [InstalledNavigationRouteV1] {
        recordsIncludingExpired().filter { record in
            guard let deleteAfter = record.archive.deleteAfter else { return true }
            return now < deleteAfter
        }
    }

    func recordsIncludingExpired() -> [InstalledNavigationRouteV1] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let decoded: [InstalledNavigationRouteV1] = urls.compactMap {
            url -> InstalledNavigationRouteV1? in
            guard url.pathExtension == "routev1",
                  let data = try? Data(contentsOf: url),
                  let archive = try? NavigationRouteArchiveV1
                    .decodeForRetentionInspection(
                    data,
                    purpose: .offlineNavigation
                  ) else {
                return nil
            }
            return InstalledNavigationRouteV1(
                archive: archive,
                fileURL: url.standardizedFileURL,
                encodedSize: data.count
            )
        }
        var newestByRouteID: [UUID: InstalledNavigationRouteV1] = [:]
        for record in decoded {
            guard let current = newestByRouteID[record.archive.routeID] else {
                newestByRouteID[record.archive.routeID] = record
                continue
            }
            let hasNewerRevision =
                record.archive.revision > current.archive.revision
            let hasNewerTimestamp =
                record.archive.revision == current.archive.revision &&
                record.archive.createdAt > current.archive.createdAt
            if hasNewerRevision || hasNewerTimestamp {
                newestByRouteID[record.archive.routeID] = record
            }
        }
        return newestByRouteID.values.sorted {
            if $0.archive.createdAt != $1.archive.createdAt {
                return $0.archive.createdAt > $1.archive.createdAt
            }
            return $0.archive.routeID.uuidString < $1.archive.routeID.uuidString
        }
    }

    func expiredRecords(now: Date = Date()) -> [InstalledNavigationRouteV1] {
        recordsIncludingExpired().filter { record in
            guard let deleteAfter = record.archive.deleteAfter else { return false }
            return now >= deleteAfter
        }
    }

    func record(
        matching identity: WatchRouteIdentityV1,
        now: Date = Date()
    ) throws -> InstalledNavigationRouteV1 {
        guard let record = records(now: now).first(where: {
            WatchRouteIdentityV1(archive: $0.archive) == identity
        }) else {
            throw NavigationRouteFileStoreError.notFound
        }
        return record
    }

    func delete(
        matching identity: WatchRouteIdentityV1,
        now: Date = Date()
    ) throws {
        let record = try record(matching: identity, now: now)
        do {
            try fileManager.removeItem(at: record.fileURL)
        } catch {
            throw NavigationRouteFileStoreError.ioFailure
        }
    }

    /// Deletes the canonical file for an identity without revalidating route
    /// retention. This is used only for a previously validated active route
    /// whose exact deletion was deferred until navigation stopped.
    func deleteDeferred(matching identity: WatchRouteIdentityV1) throws {
        let url = fileURL(for: identity)
        guard fileManager.fileExists(atPath: url.path) else {
            throw NavigationRouteFileStoreError.notFound
        }
        do {
            try fileManager.removeItem(at: url)
            try synchronizeRootDirectory()
        } catch {
            throw NavigationRouteFileStoreError.ioFailure
        }
    }

    @discardableResult
    func pruneInvalidAndExpired(
        now: Date = Date(),
        protecting protectedIdentities: Set<WatchRouteIdentityV1> = []
    ) -> Int {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var removed = 0
        for url in urls where url.pathExtension == "routev1" {
            guard let data = try? Data(contentsOf: url) else {
                if quarantineOrRemove(url) { removed += 1 }
                continue
            }
            do {
                let archive = try NavigationRouteArchiveV1
                    .decodeForRetentionInspection(
                    data,
                    purpose: .offlineNavigation
                )
                if let deleteAfter = archive.deleteAfter,
                   now >= deleteAfter {
                    let identity = WatchRouteIdentityV1(archive: archive)
                    if !protectedIdentities.contains(identity),
                       (try? fileManager.removeItem(at: url)) != nil {
                        removed += 1
                    }
                } else {
                    try archive.validate(
                        purpose: .offlineNavigation,
                        now: now
                    )
                }
            } catch {
                if quarantineOrRemove(url) { removed += 1 }
            }
        }
        return removed
    }

    private func prepareDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw NavigationRouteFileStoreError.ioFailure
        }
    }

    private func verifiedAtomicWrite(
        _ data: Data,
        archive: NavigationRouteArchiveV1,
        destination: URL,
        now: Date
    ) throws {
        let temporary = rootDirectory.appendingPathComponent(
            ".route-write-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let verifiedData = try Data(contentsOf: temporary)
        let verifiedArchive = try NavigationRouteArchiveV1.decode(
            verifiedData,
            purpose: .offlineNavigation,
            now: now
        )
        guard verifiedData == data, verifiedArchive == archive else {
            throw NavigationRouteFileStoreError.ioFailure
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: temporary,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        try synchronizeRootDirectory()
    }

    private func quarantineOrRemove(_ url: URL) -> Bool {
        let quarantine = rootDirectory.appendingPathComponent(
            "Quarantine",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: quarantine,
                withIntermediateDirectories: true
            )
            let destination = quarantine.appendingPathComponent(
                "\(UUID().uuidString)-\(url.lastPathComponent).invalid",
                isDirectory: false
            )
            try fileManager.moveItem(at: url, to: destination)
            trimQuarantine(quarantine)
            return true
        } catch {
            return (try? fileManager.removeItem(at: url)) != nil
        }
    }

    private func trimQuarantine(_ directory: URL) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let ordered = files.sorted { left, right in
            let leftDate = try? left.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            let rightDate = try? right.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            return (leftDate ?? .distantPast) > (rightDate ?? .distantPast)
        }
        for stale in ordered.dropFirst(3) {
            try? fileManager.removeItem(at: stale)
        }
    }

    private func removeSuperseded(
        _ records: [InstalledNavigationRouteV1],
        keeping fileURL: URL
    ) throws {
        var removedAny = false
        do {
            for record in records where record.fileURL != fileURL {
                try fileManager.removeItem(at: record.fileURL)
                removedAny = true
            }
            if removedAny {
                try synchronizeRootDirectory()
            }
        } catch {
            throw NavigationRouteFileStoreError.ioFailure
        }
    }

    private func fileURL(for identity: WatchRouteIdentityV1) -> URL {
        rootDirectory.appendingPathComponent(
            "\(identity.routeID.uuidString.lowercased())-r\(identity.revision)-\(identity.contentHash).routev1",
            isDirectory: false
        ).standardizedFileURL
    }

    private static func isOlder(
        _ left: InstalledNavigationRouteV1,
        than right: InstalledNavigationRouteV1
    ) -> Bool {
        if left.archive.createdAt != right.archive.createdAt {
            return left.archive.createdAt < right.archive.createdAt
        }
        let leftID = left.archive.routeID.uuidString
        let rightID = right.archive.routeID.uuidString
        if leftID != rightID { return leftID < rightID }
        return left.archive.revision < right.archive.revision
    }

    private func synchronizeRootDirectory() throws {
#if canImport(Darwin)
        let descriptor = Darwin.open(rootDirectory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw NavigationRouteFileStoreError.ioFailure
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw NavigationRouteFileStoreError.ioFailure
        }
#endif
    }
}
