import Combine
import Foundation

struct WatchRouteInstallResultV1 {
    let installed: InstalledNavigationRouteV1
    let evictedIdentities: [WatchRouteIdentityV1]
}

@MainActor
final class WatchRouteLibrary: ObservableObject {
    @Published private(set) var routes: [PlannedRouteSummaryV1] = []
    @Published private(set) var lastSyncError: String?
    @Published private(set) var activeIdentity: WatchRouteIdentityV1?
    @Published private(set) var pendingDeletionIdentity:
        WatchRouteIdentityV1?

    private let store: NavigationRouteFileStoreV1
    private let now: () -> Date
    private let defaults: UserDefaults
    private let pendingDeletionKey =
        "watchRouteLibrary.pendingDeletion.v1"
    private let displayNamesKey =
        "watchRouteLibrary.displayNames.v1"
    private var displayNamesEnvelope:
        WatchRouteDisplayNamesEnvelopeV1?

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
        return record
    }

    @discardableResult
    func activate(
        _ identity: WatchRouteIdentityV1
    ) throws -> InstalledNavigationRouteV1 {
        let record = try store.record(matching: identity, now: now())
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
        _ = store.pruneInvalidAndExpired(now: now())
        routes = store.records(now: now()).map(\.summary)
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
}
