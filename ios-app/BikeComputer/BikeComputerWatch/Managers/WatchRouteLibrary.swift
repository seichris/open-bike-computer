import Combine
import Foundation

struct WatchRouteInstallResultV1 {
    let installed: InstalledNavigationRouteV1
    let evictedIdentities: [WatchRouteIdentityV1]
}

@MainActor
final class WatchRouteLibrary: ObservableObject {
    static let minimumRemainingValidityForNewNavigation: TimeInterval =
        24 * 60 * 60

    @Published private(set) var routes: [PlannedRouteSummaryV1] = []
    @Published private(set) var lastSyncError: String?
    @Published private(set) var activeIdentity: WatchRouteIdentityV1?
    @Published private(set) var pendingDeletionIdentity:
        WatchRouteIdentityV1?

    var onRouteExpired: ((WatchRouteIdentityV1) -> Void)?

    private let store: NavigationRouteFileStoreV1
    private let now: () -> Date
    private let defaults: UserDefaults
    private let pendingDeletionKey =
        "watchRouteLibrary.pendingDeletion.v1"
    private let displayNamesKey =
        "watchRouteLibrary.displayNames.v1"
    private var displayNamesEnvelope:
        WatchRouteDisplayNamesEnvelopeV1?
    private var expiryTask: Task<Void, Never>?

    convenience init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        self.init(
            store: NavigationRouteFileStoreV1(
                rootDirectory: base.appendingPathComponent(
                    "WatchRoutes",
                    isDirectory: true
                ),
                limits: .watch
            )
        )
    }

    init(
        store: NavigationRouteFileStoreV1,
        now: @escaping () -> Date = Date.init,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.now = now
        self.defaults = defaults
        pendingDeletionIdentity = Self.decodeIdentity(
            defaults.data(forKey: pendingDeletionKey)
        )
        displayNamesEnvelope = defaults.data(forKey: displayNamesKey)
            .flatMap { try? WatchRouteDisplayNamesEnvelopeV1.decode($0) }
        reload()
    }

    @discardableResult
    func install(
        _ data: Data,
        expectedIdentity: WatchRouteIdentityV1
    ) throws -> WatchRouteInstallResultV1 {
        let archive = try NavigationRouteArchiveV1.decode(
            data,
            purpose: .offlineNavigation,
            now: now()
        )
        guard WatchRouteIdentityV1(archive: archive) == expectedIdentity else {
            throw WatchRouteLibraryError.metadataMismatch
        }
        if let activeIdentity,
           activeIdentity.routeID == expectedIdentity.routeID,
           activeIdentity != expectedIdentity {
            throw WatchRouteLibraryError.activeRoutePinned
        }
        let protectedIdentities = Set(
            [activeIdentity, pendingDeletionIdentity].compactMap { $0 }
        )
        let previousIdentities = Set(store.records(now: now()).map {
            WatchRouteIdentityV1(archive: $0.archive)
        })
        let installed = try store.install(
            data,
            now: now(),
            evictingOldestUnprotected: protectedIdentities
        )
        lastSyncError = nil
        reload()
        let currentIdentities = Set(store.records(now: now()).map {
            WatchRouteIdentityV1(archive: $0.archive)
        })
        let evicted = previousIdentities
            .subtracting(currentIdentities)
            .filter { $0.routeID != expectedIdentity.routeID }
            .sorted {
                if $0.routeID != $1.routeID {
                    return $0.routeID.uuidString < $1.routeID.uuidString
                }
                if $0.revision != $1.revision {
                    return $0.revision < $1.revision
                }
                return $0.contentHash < $1.contentHash
            }
        return WatchRouteInstallResultV1(
            installed: installed,
            evictedIdentities: evicted
        )
    }

    func delete(_ identity: WatchRouteIdentityV1) throws {
        if activeIdentity == identity {
            pendingDeletionIdentity = identity
            persistPendingDeletion()
            lastSyncError = nil
            return
        }
        try store.delete(matching: identity, now: now())
        if pendingDeletionIdentity == identity {
            pendingDeletionIdentity = nil
            persistPendingDeletion()
        }
        lastSyncError = nil
        reload()
    }

    func record(
        matching identity: WatchRouteIdentityV1
    ) throws -> InstalledNavigationRouteV1 {
        try store.record(matching: identity, now: now())
    }

    func displayName(for summary: PlannedRouteSummaryV1) -> String {
        let identity = WatchRouteIdentityV1(
            routeID: summary.id,
            revision: summary.revision,
            contentHash: summary.contentHash
        )
        return displayNamesEnvelope?.entries.first {
            $0.identity == identity
        }?.name ?? summary.name
    }

    func receiveApplicationContext(_ context: [String: Any]) {
        guard let data = context[
            WatchRouteDisplayNamesEnvelopeV1.applicationContextKey
        ] as? Data,
              let envelope = try?
                WatchRouteDisplayNamesEnvelopeV1.decode(data),
              envelope.revision >= (displayNamesEnvelope?.revision ?? 0)
        else { return }
        if envelope.revision == displayNamesEnvelope?.revision,
           envelope != displayNamesEnvelope {
            lastSyncError = "display_name_revision_conflict"
            return
        }
        displayNamesEnvelope = envelope
        defaults.set(data, forKey: displayNamesKey)
        lastSyncError = nil
        objectWillChange.send()
    }

    func record(
        routeID: UUID
    ) throws -> InstalledNavigationRouteV1 {
        guard let record = store.records(now: now()).first(where: {
            $0.archive.routeID == routeID
        }) else {
            throw NavigationRouteFileStoreError.notFound
        }
        try validateStartWindow(record)
        return record
    }

    @discardableResult
    func activate(
        _ identity: WatchRouteIdentityV1,
        requiringStartWindow: Bool = true
    ) throws -> InstalledNavigationRouteV1 {
        let record = try store.record(matching: identity, now: now())
        if requiringStartWindow { try validateStartWindow(record) }
        activeIdentity = identity
        return record
    }

    func deactivate(_ identity: WatchRouteIdentityV1) {
        guard activeIdentity == identity else { return }
        activeIdentity = nil
        guard pendingDeletionIdentity == identity else { return }
        do {
            try store.deleteDeferred(matching: identity)
            pendingDeletionIdentity = nil
            persistPendingDeletion()
            lastSyncError = nil
            reload()
        } catch NavigationRouteFileStoreError.notFound {
            pendingDeletionIdentity = nil
            persistPendingDeletion()
            lastSyncError = nil
            reload()
        } catch {
            lastSyncError = "delete_after_navigation_failed"
        }
    }

    func applyPendingDeletionIfInactive() {
        guard activeIdentity == nil,
              let pendingDeletionIdentity else { return }
        do {
            try store.deleteDeferred(matching: pendingDeletionIdentity)
            self.pendingDeletionIdentity = nil
            persistPendingDeletion()
            lastSyncError = nil
            reload()
        } catch NavigationRouteFileStoreError.notFound {
            self.pendingDeletionIdentity = nil
            persistPendingDeletion()
        } catch {
            lastSyncError = "delete_after_navigation_failed"
        }
    }

    func reload() {
        let timestamp = now()
        let expiredRecords = store.expiredRecords(now: timestamp)
        var callbacks: [WatchRouteIdentityV1] = []
        for record in expiredRecords {
            let identity = WatchRouteIdentityV1(archive: record.archive)
            callbacks.append(identity)
            if activeIdentity == identity {
                pendingDeletionIdentity = identity
                persistPendingDeletion()
            }
        }
        let protected = Set([activeIdentity].compactMap { $0 })
        _ = store.pruneInvalidAndExpired(
            now: timestamp,
            protecting: protected
        )
        routes = store.records(now: timestamp).map(\.summary)
        scheduleNextExpiry()
        for identity in callbacks { onRouteExpired?(identity) }
    }

    func reportSyncError(_ code: String) {
        lastSyncError = code
    }

    private func persistPendingDeletion() {
        guard let pendingDeletionIdentity else {
            defaults.removeObject(forKey: pendingDeletionKey)
            return
        }
        defaults.set(
            try? PropertyListEncoder().encode(pendingDeletionIdentity),
            forKey: pendingDeletionKey
        )
    }

    private func validateStartWindow(
        _ record: InstalledNavigationRouteV1
    ) throws {
        guard record.archive.providerID ==
                RouteProviderPolicyV1.strava.providerID,
              let deleteAfter = record.archive.deleteAfter else {
            return
        }
        guard deleteAfter.timeIntervalSince(now()) >=
                Self.minimumRemainingValidityForNewNavigation else {
            throw WatchRouteLibraryError.nearExpiry
        }
    }

    private func scheduleNextExpiry() {
        expiryTask?.cancel()
        guard let deadline = routes.compactMap(\.deleteAfter).min() else {
            expiryTask = nil
            return
        }
        let delay = max(deadline.timeIntervalSince(now()), 0)
        let nanoseconds = UInt64(min(
            delay * 1_000_000_000,
            Double(UInt64.max)
        ))
        expiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    private static func decodeIdentity(_ data: Data?) -> WatchRouteIdentityV1? {
        guard let data else { return nil }
        return try? PropertyListDecoder().decode(
            WatchRouteIdentityV1.self,
            from: data
        )
    }
}

enum WatchRouteLibraryError: Error, Equatable {
    case metadataMismatch
    case activeRoutePinned
    case nearExpiry
}
