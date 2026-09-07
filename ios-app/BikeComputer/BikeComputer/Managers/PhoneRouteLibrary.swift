import Combine
import Foundation

enum PhoneRouteWatchSyncStateV1: Equatable {
    case localOnly
    case transferring
    case ready
    case deleting
    case rejected(String)
}

enum PhoneRouteLibraryError: Error, Equatable {
    case watchUnavailable
    case transferInProgress
    case stravaBookmarkMissing
    case stravaBookmarkConflict
    case stravaReceiptMismatch
    case stravaRouteExpired
    case revisionExhausted
}

/// Durable route ownership on iPhone. Only archives whose provider policy
/// explicitly permits offline storage can enter this library.
@MainActor
final class PhoneRouteLibrary: ObservableObject {
    @Published private(set) var routes: [PlannedRouteSummaryV1] = []
    @Published private(set) var stravaReloadBookmarks:
        [StravaRouteReloadBookmarkV1] = []
    @Published private(set) var stravaBookmarkStoreAvailable = true
    @Published private(set) var watchSyncState:
        [WatchRouteIdentityV1: PhoneRouteWatchSyncStateV1] = [:]
    @Published private var displayNames: SavedRouteDisplayNames

    private let store: NavigationRouteFileStoreV1
    private let stravaBookmarkStore: StravaRouteReloadBookmarkStoreV1
    private let connectivity: PhoneWatchConnectivityCoordinator
    private let now: () -> Date
    private let defaults: UserDefaults
    private let readyReceiptKey = "watchRouteReadyReceipts.v1"
    private let pendingDeletionKey = "watchRoutePendingDeletions.v1"
    private let pendingInstallKey = "watchRoutePendingInstalls.v1"
    private let providerDeletionTombstonesKey =
        "watchRouteProviderDeletionTombstones.v1"
    private var readyReceiptKeys: Set<String>
    private var pendingDeletionKeys: Set<String>
    private var pendingInstallKeys: Set<String>
    private var providerDeletionTombstones: Set<WatchRouteIdentityV1>
    private var queuedProviderDeletions: Set<WatchRouteIdentityV1> = []
    private var cancellables = Set<AnyCancellable>()
    private var expiryTask: Task<Void, Never>?

    convenience init(connectivity: PhoneWatchConnectivityCoordinator) {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let routeStore = NavigationRouteFileStoreV1(
            rootDirectory: base.appendingPathComponent(
                "PlannedRoutes",
                isDirectory: true
            )
        )
        self.init(
            store: routeStore,
            stravaBookmarkStore: StravaRouteReloadBookmarkStoreV1(
                fileURL: routeStore.rootDirectory.appendingPathComponent(
                    "strava-reload-bookmarks-v1.json"
                )
            ),
            connectivity: connectivity,
            defaults: .standard
        )
    }

    init(
        store: NavigationRouteFileStoreV1,
        stravaBookmarkStore: StravaRouteReloadBookmarkStoreV1? = nil,
        connectivity: PhoneWatchConnectivityCoordinator,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.stravaBookmarkStore = stravaBookmarkStore ??
            StravaRouteReloadBookmarkStoreV1(
                fileURL: store.rootDirectory.appendingPathComponent(
                    "strava-reload-bookmarks-v1.json"
                )
            )
        self.connectivity = connectivity
        self.defaults = defaults
        self.now = now
        displayNames = SavedRouteDisplayNames(defaults: defaults)
        readyReceiptKeys = Set(
            defaults.stringArray(forKey: readyReceiptKey) ?? []
        )
        pendingDeletionKeys = Set(
            defaults.stringArray(forKey: pendingDeletionKey) ?? []
        )
        pendingInstallKeys = Set(
            defaults.stringArray(forKey: pendingInstallKey) ?? []
        )
        providerDeletionTombstones = Self.decodeProviderDeletionTombstones(
            defaults.data(forKey: providerDeletionTombstonesKey)
        )
        connectivity.onRouteAcknowledgement = { [weak self] message in
            self?.receive(message)
        }
        connectivity.$state
            .map(\.isReachable)
            .removeDuplicates()
            .sink { [weak self] isReachable in
                guard isReachable else { return }
                Task { @MainActor [weak self] in
                    self?.retryPendingInstallsImmediately()
                    self?.queuedProviderDeletions.removeAll()
                    self?.retryProviderDeletions()
                }
            }
            .store(in: &cancellables)
        reload()
    }

    @discardableResult
    func importArchive(_ data: Data) throws -> PlannedRouteSummaryV1 {
        let record = try store.install(data, now: now())
        reload()
        return record.summary
    }

    @discardableResult
    func importGPX(
        _ data: Data,
        fileName: String
    ) throws -> PlannedRouteSummaryV1 {
        let session = try prepareGPX(data, fileName: fileName)
        return try saveOffline(session.archive, name: session.name).summary
    }

    /// Parsing and naming are a memory-only draft. Cancel never reaches the store.
    func prepareGPX(_ data: Data, fileName: String) throws -> PhoneOfflineRouteSaveSession {
        let archive = try GPXRouteImporterV1.archive(
            data: data, fallbackName: fileName, createdAt: now()
        )
        return PhoneOfflineRouteSaveSession(archive: archive, now: now)
    }

    /// The sole Save Offline commit boundary. Never accepts MKRoute, invents
    /// provider attribution, resets an expiry, or overwrites a conflicting ID.
    func saveOffline(
        _ archive: NavigationRouteArchiveV1,
        name: String
    ) throws -> PhoneOfflineRouteSaveResult {
        try archive.validate(purpose: .offlineNavigation, now: now())
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.count <= 120 else {
            throw OfflineRouteSaveError.invalidName
        }
        let identity = WatchRouteIdentityV1(archive: archive)
        let records = store.records(now: now())
        if let exact = records.first(where: {
            WatchRouteIdentityV1(archive: $0.archive) == identity
        }) {
            // A library-backed save is idempotent, including Strava's original
            // deadline. A different typed name must not rewrite its identity.
            let verified = try offlineNavigationArchive(for: exact.summary)
            return PhoneOfflineRouteSaveResult(
                summary: PlannedRouteSummaryV1(archive: verified), alreadySaved: true
            )
        }
        // Do not hide stale revisions or same-revision conflicts behind a
        // geometry match. Cross-UUID deduplication is for local GPX only; Strava
        // imports/reloads keep their existing receipt + bookmark transaction.
        if !records.contains(where: { $0.archive.routeID == archive.routeID }),
           archive.route.provider == RouteProviderPolicyV1.importedGPX,
           let duplicate = records.first(where: {
               $0.archive.route.hasSameOfflineContent(as: archive.route)
           }) {
            let verified = try offlineNavigationArchive(for: duplicate.summary)
            return PhoneOfflineRouteSaveResult(
                summary: PlannedRouteSummaryV1(archive: verified), alreadySaved: true
            )
        }
        // New Strava data must enter through importStravaGPX and its receipt,
        // retention and bookmark transaction, never through a generic draft.
        guard archive.route.provider == RouteProviderPolicyV1.importedGPX else {
            throw PhoneRouteLibraryError.stravaReceiptMismatch
        }
        let named = try NavigationRouteArchiveV1.create(
            route: archive.route.namedForOfflineStorage(normalizedName),
            createdAt: archive.createdAt, deleteAfter: archive.deleteAfter,
            purpose: .durableStorage
        )
        let summary = try importArchive(named.encoded(purpose: .durableStorage, now: now()))
        // Report success only after the exact committed identity can be read.
        _ = try offlineNavigationArchive(for: summary)
        return PhoneOfflineRouteSaveResult(summary: summary, alreadySaved: false)
    }

    /// Always read the full identity again at start, not geometry retained by a
    /// preview. Missing, deleted, expired, corrupt or replaced routes fail closed.
    func offlineNavigationArchive(
        for summary: PlannedRouteSummaryV1
    ) throws -> NavigationRouteArchiveV1 {
        do {
            let selectedIdentity = identity(for: summary)
            guard !pendingDeletionKeys.contains(Self.receiptKey(selectedIdentity)),
                  !providerDeletionTombstones.contains(selectedIdentity) else {
                throw NavigationRouteFileStoreError.notFound
            }
            let archive = try store.record(matching: selectedIdentity, now: now()).archive
            try archive.validate(purpose: .offlineNavigation, now: now())
            return archive
        } catch {
            reload()
            throw error
        }
    }

    var expiredStravaBookmarks: [StravaRouteReloadBookmarkV1] {
        let activeRouteIDs = Set(routes.map(\.id))
        return stravaReloadBookmarks.filter {
            !activeRouteIDs.contains($0.routeID)
        }
    }

    func stravaBookmark(
        routeID: UUID
    ) -> StravaRouteReloadBookmarkV1? {
        stravaReloadBookmarks.first { $0.routeID == routeID }
    }

    @discardableResult
    func importStravaGPX(
        _ data: Data,
        receipt: StravaRouteImportReceiptV1
    ) throws -> PlannedRouteSummaryV1 {
        if let bookmark = stravaReloadBookmarks.first(where: {
            $0.externalRouteID == receipt.routeURL.externalRouteID
        }) {
            return try reloadStravaGPX(
                data,
                receipt: receipt,
                bookmark: bookmark
            )
        }
        return try persistStravaGPX(
            data,
            receipt: receipt,
            priorBookmark: nil,
            routeID: UUID(),
            revision: 1
        )
    }

    @discardableResult
    func reloadStravaGPX(
        _ data: Data,
        receipt: StravaRouteImportReceiptV1,
        bookmark: StravaRouteReloadBookmarkV1
    ) throws -> PlannedRouteSummaryV1 {
        guard receipt.routeURL.externalRouteID == bookmark.externalRouteID else {
            throw PhoneRouteLibraryError.stravaReceiptMismatch
        }
        guard let stored = stravaReloadBookmarks.first(where: {
            $0.routeID == bookmark.routeID
        }) else {
            throw PhoneRouteLibraryError.stravaBookmarkMissing
        }
        guard stored == bookmark else {
            throw PhoneRouteLibraryError.stravaBookmarkConflict
        }
        guard let revision = bookmark.nextRevision else {
            throw PhoneRouteLibraryError.revisionExhausted
        }
        return try persistStravaGPX(
            data,
            receipt: receipt,
            priorBookmark: bookmark,
            routeID: bookmark.routeID,
            revision: revision
        )
    }

    @discardableResult
    func recordStravaReloadAttempt(
        _ bookmark: StravaRouteReloadBookmarkV1,
        failed: Bool = false
    ) throws -> StravaRouteReloadBookmarkV1 {
        guard stravaReloadBookmarks.contains(bookmark) else {
            throw PhoneRouteLibraryError.stravaBookmarkConflict
        }
        let timestamp = now()
        let updated = try bookmark.updating(
            lastReloadAttemptAt: .some(timestamp),
            lastErrorAt: failed ? .some(timestamp) : .some(nil)
        )
        try stravaBookmarkStore.upsert(updated)
        loadStravaBookmarks()
        return updated
    }

    func recordStravaValidation(
        _ bookmark: StravaRouteReloadBookmarkV1,
        checkedAt: Date
    ) throws {
        guard let stored = stravaReloadBookmarks.first(where: {
            $0.routeID == bookmark.routeID
        }), stored == bookmark else {
            throw PhoneRouteLibraryError.stravaBookmarkConflict
        }
        let updated = try bookmark.updating(
            lastValidationAt: .some(checkedAt),
            lastErrorAt: .some(nil)
        )
        try stravaBookmarkStore.upsert(updated)
        loadStravaBookmarks()
    }

    func expireStravaRoute(id routeID: UUID) {
        let records = store.recordsIncludingExpired().filter {
            $0.archive.routeID == routeID &&
                $0.archive.providerID == RouteProviderPolicyV1.strava.providerID
        }
        for record in records {
            removeArchiveAndQueueWatchDeletion(record)
        }
        reload()
    }

    func deleteExpiredStravaBookmark(
        _ bookmark: StravaRouteReloadBookmarkV1
    ) throws {
        _ = try stravaBookmarkStore.delete(routeID: bookmark.routeID)
        removeDisplayName(routeID: bookmark.routeID)
        reload()
    }

    @discardableResult
    func purge(providerID: String) throws -> Int {
        guard providerID == RouteProviderPolicyV1.strava.providerID else {
            return 0
        }
        let records = store.recordsIncludingExpired().filter {
            $0.archive.providerID == providerID
        }
        let routeIDs = Set(records.map { $0.archive.routeID })
            .union(stravaReloadBookmarks.map(\.routeID))
        for record in records {
            removeArchiveAndQueueWatchDeletion(record)
        }
        let removed = try stravaBookmarkStore.purge()
        for routeID in routeIDs { removeDisplayName(routeID: routeID) }
        reload()
        return removed
    }

    func sendToWatch(_ summary: PlannedRouteSummaryV1) throws {
        let identity = identity(for: summary)
        let record = try store.record(matching: identity, now: now())
        guard connectivity.transferRoute(record) != nil else {
            watchSyncState[identity] = .rejected("watch_unavailable")
            return
        }
        pendingInstallKeys.insert(Self.receiptKey(identity))
        persistPendingInstalls()
        watchSyncState[identity] = .transferring
        connectivity.sendRouteImmediately(record)
    }

    @discardableResult
    func cancelSendToWatch(_ summary: PlannedRouteSummaryV1) -> Bool {
        let identity = identity(for: summary)
        let key = Self.receiptKey(identity)
        guard pendingInstallKeys.contains(key) else { return true }
        guard connectivity.cancelRouteTransfers(identity) > 0 else {
            return false
        }
        pendingInstallKeys.remove(key)
        persistPendingInstalls()
        watchSyncState[identity] = readyReceiptKeys.contains(key)
            ? .ready
            : .localOnly
        return true
    }

    func displayName(for summary: PlannedRouteSummaryV1) -> String {
        displayNames.displayName(
            routeID: summary.id,
            defaultName: summary.name
        )
    }

    /// Resolve only the selected immutable identity through normal archive
    /// validation and retention. A successful preview read has no write or
    /// Watch-transfer side effects and never falls back to another revision.
    func mapSelection(
        for summary: PlannedRouteSummaryV1
    ) throws -> SavedRouteMapSelection {
        let name = displayName(for: summary)
        do {
            guard !providerDeletionTombstones.contains(identity(for: summary)) else {
                throw NavigationRouteFileStoreError.notFound
            }
            let record = try store.record(
                matching: identity(for: summary),
                now: now()
            )
            // The clock may have crossed the retention deadline while reading.
            try record.archive.validate(purpose: .offlineNavigation, now: now())
            return SavedRouteMapSelection(
                identity: WatchRouteIdentityV1(archive: record.archive),
                displayName: displayName(for: record.summary),
                route: record.archive.route,
                createdAt: record.archive.createdAt,
                deleteAfter: record.archive.deleteAfter
            )
        } catch {
            // Publish deletion, corruption, or replacement to any open preview
            // using the same cleanup and Watch-retention path as the library.
            reload()
            if let deadline = summary.deleteAfter, now() >= deadline {
                throw SavedRouteMapError.expired(name)
            }
            throw SavedRouteMapError.unavailable(name)
        }
    }

    @discardableResult
    func rename(
        _ summary: PlannedRouteSummaryV1,
        to proposedName: String
    ) -> String {
        var updated = displayNames
        let name = updated.rename(
            routeID: summary.id,
            defaultName: summary.name,
            to: proposedName
        )
        guard updated != displayNames else { return name }
        if let bookmark = stravaBookmark(routeID: summary.id) {
            do {
                let updatedBookmark = try bookmark.updating(
                    localAlias: .some(name)
                )
                try stravaBookmarkStore.upsert(updatedBookmark)
            } catch {
                return displayName(for: summary)
            }
            loadStravaBookmarks()
        }
        displayNames = updated
        displayNames.persist(to: defaults)
        publishRouteDisplayNames()
        return name
    }

    func delete(_ summary: PlannedRouteSummaryV1) throws {
        let identity = identity(for: summary)
        let key = Self.receiptKey(identity)
        if summary.providerID == RouteProviderPolicyV1.strava.providerID {
            _ = try stravaBookmarkStore.delete(routeID: summary.id)
            var removedLocally = true
            for record in store.recordsIncludingExpired().filter({
                $0.archive.routeID == summary.id
            }) {
                if !removeArchiveAndQueueWatchDeletion(record) { removedLocally = false }
            }
            removeDisplayName(routeID: summary.id)
            watchSyncState.removeValue(forKey: identity)
            reload()
            guard removedLocally else { throw NavigationRouteFileStoreError.ioFailure }
            return
        }
        guard !pendingInstallKeys.contains(key) else {
            throw PhoneRouteLibraryError.transferInProgress
        }
        guard readyReceiptKeys.contains(key) ||
                pendingDeletionKeys.contains(key) else {
            try store.delete(matching: identity, now: now())
            removeDisplayName(routeID: summary.id)
            watchSyncState.removeValue(forKey: identity)
            reload()
            return
        }
        guard connectivity.requestRouteDeletion(identity) != nil else {
            throw PhoneRouteLibraryError.watchUnavailable
        }
        pendingDeletionKeys.insert(key)
        persistPendingDeletions()
        watchSyncState[identity] = .deleting
    }

    func reload() {
        let timestamp = now()
        // Retry local cleanup from persisted tombstones after a transient disk
        // failure/restart. Such routes stay unavailable even before cleanup wins.
        for identity in providerDeletionTombstones {
            try? store.deleteDeferred(matching: identity)
        }
        for record in store.expiredRecords(now: timestamp) {
            removeArchiveAndQueueWatchDeletion(record)
        }
        _ = store.pruneInvalidAndExpired(now: timestamp)
        routes = store.records(now: timestamp).filter {
            !providerDeletionTombstones.contains(WatchRouteIdentityV1(archive: $0.archive))
        }.map(\.summary)
        loadStravaBookmarks()
        let installedIdentities = Set(routes.map { identity(for: $0) })
        let installedKeys = Set(installedIdentities.map(Self.receiptKey))
        readyReceiptKeys.formIntersection(installedKeys)
        pendingDeletionKeys.formIntersection(installedKeys)
        pendingInstallKeys.formIntersection(installedKeys)
        persistReadyReceipts()
        persistPendingDeletions()
        persistPendingInstalls()
        watchSyncState = Dictionary(uniqueKeysWithValues:
            installedIdentities.map { identity in
                (
                    identity,
                    syncState(for: identity)
                )
            }
        )
        publishRouteDisplayNames()
        retryProviderDeletions()
        scheduleNextExpiry()
    }

    private func receive(_ message: WatchRouteSyncMessageV1) {
        switch message.status {
        case .ready:
            if providerDeletionTombstones.contains(message.identity) {
                queuedProviderDeletions.remove(message.identity)
                retryProviderDeletions()
                return
            }
            guard (try? store.record(
                matching: message.identity,
                now: now()
            )) != nil else { return }
            guard !pendingDeletionKeys.contains(
                Self.receiptKey(message.identity)
            ) else { return }
            readyReceiptKeys.insert(Self.receiptKey(message.identity))
            pendingInstallKeys.remove(Self.receiptKey(message.identity))
            persistReadyReceipts()
            persistPendingInstalls()
            watchSyncState[message.identity] = .ready
        case .deleted:
            if (try? store.deleteDeferred(
                matching: message.identity
            )) != nil,
               stravaBookmark(routeID: message.identity.routeID) == nil {
                removeDisplayName(routeID: message.identity.routeID)
            }
            providerDeletionTombstones.remove(message.identity)
            queuedProviderDeletions.remove(message.identity)
            persistProviderDeletionTombstones()
            readyReceiptKeys.remove(Self.receiptKey(message.identity))
            pendingDeletionKeys.remove(Self.receiptKey(message.identity))
            pendingInstallKeys.remove(Self.receiptKey(message.identity))
            persistReadyReceipts()
            persistPendingDeletions()
            persistPendingInstalls()
            reload()
        case .evicted:
            let key = Self.receiptKey(message.identity)
            providerDeletionTombstones.remove(message.identity)
            queuedProviderDeletions.remove(message.identity)
            persistProviderDeletionTombstones()
            readyReceiptKeys.remove(key)
            pendingDeletionKeys.remove(key)
            pendingInstallKeys.remove(key)
            persistReadyReceipts()
            persistPendingDeletions()
            persistPendingInstalls()
            if watchSyncState[message.identity] != nil {
                watchSyncState[message.identity] = .localOnly
            }
        case .rejected:
            if providerDeletionTombstones.contains(message.identity) {
                queuedProviderDeletions.remove(message.identity)
                persistProviderDeletionTombstones()
                return
            }
            guard watchSyncState[message.identity] != nil else { return }
            let key = Self.receiptKey(message.identity)
            let wasDeleting = pendingDeletionKeys.contains(key)
            if WatchRouteAcknowledgementReconciliationV1
                .preservesReadyReceipt(
                    hasReadyReceipt: readyReceiptKeys.contains(key),
                    isPendingDeletion: wasDeleting
                ) {
                pendingInstallKeys.remove(key)
                persistPendingInstalls()
                watchSyncState[message.identity] = .ready
                return
            }
            if wasDeleting {
                pendingDeletionKeys.remove(key)
            }
            if !wasDeleting {
                readyReceiptKeys.remove(key)
            }
            pendingInstallKeys.remove(key)
            persistReadyReceipts()
            persistPendingDeletions()
            persistPendingInstalls()
            watchSyncState[message.identity] = .rejected(
                message.errorCode ?? "watch_rejected"
            )
        case nil:
            break
        }
    }

    private func persistStravaGPX(
        _ data: Data,
        receipt: StravaRouteImportReceiptV1,
        priorBookmark: StravaRouteReloadBookmarkV1?,
        routeID: UUID,
        revision: UInt32
    ) throws -> PlannedRouteSummaryV1 {
        let timestamp = now()
        guard timestamp < receipt.deleteAfter else {
            throw PhoneRouteLibraryError.stravaRouteExpired
        }
        let archive = try GPXRouteImporterV1.archive(
            data: data,
            fallbackName: "Strava route",
            routeID: routeID,
            revision: revision,
            source: .strava(receipt: receipt)
        )
        let replacementBookmark = try StravaRouteReloadBookmarkV1(
            routeURL: receipt.routeURL,
            routeID: routeID,
            lastRevision: revision,
            localAlias: priorBookmark?.localAlias,
            createdAt: priorBookmark?.createdAt ?? timestamp,
            lastReloadAttemptAt: timestamp,
            lastReloadSucceededAt: timestamp,
            lastValidationAt: receipt.validatedAt,
            lastErrorAt: nil
        )
        let archiveData = try archive.encoded(
            purpose: .offlineNavigation,
            now: timestamp
        )
        let previousBookmarks = try stravaBookmarkStore.bookmarks()
        let record: InstalledNavigationRouteV1
        do {
            record = try store.installAtomically(
                archiveData,
                now: timestamp
            ) {
                try stravaBookmarkStore.upsert(replacementBookmark)
            }
        } catch {
            // `installAtomically` leaves the previous archive intact when the
            // companion write fails. Restore the previous bookmark envelope in
            // case a filesystem error happened after its atomic replacement.
            try? stravaBookmarkStore.replaceAll(previousBookmarks)
            throw error
        }
        if let alias = replacementBookmark.localAlias {
            var updated = displayNames
            _ = updated.rename(
                routeID: routeID,
                defaultName: record.summary.name,
                to: alias
            )
            displayNames = updated
            displayNames.persist(to: defaults)
        }
        reload()
        return record.summary
    }

    private func loadStravaBookmarks() {
        do {
            stravaReloadBookmarks = try stravaBookmarkStore.bookmarks()
            stravaBookmarkStoreAvailable = true
        } catch {
            stravaReloadBookmarks = []
            stravaBookmarkStoreAvailable = false
        }
    }

    @discardableResult
    private func removeArchiveAndQueueWatchDeletion(
        _ record: InstalledNavigationRouteV1
    ) -> Bool {
        let identity = WatchRouteIdentityV1(archive: record.archive)
        providerDeletionTombstones.insert(identity)
        queuedProviderDeletions.remove(identity)
        readyReceiptKeys.remove(Self.receiptKey(identity))
        pendingDeletionKeys.remove(Self.receiptKey(identity))
        pendingInstallKeys.remove(Self.receiptKey(identity))
        persistReadyReceipts()
        persistPendingDeletions()
        persistPendingInstalls()
        persistProviderDeletionTombstones()
        let removed: Bool
        do {
            try store.deleteDeferred(matching: identity)
            removed = true
        } catch NavigationRouteFileStoreError.notFound {
            removed = true
        } catch {
            removed = false
        }
        retryProviderDeletions()
        return removed
    }

    private func retryProviderDeletions() {
        for identity in providerDeletionTombstones
            where !queuedProviderDeletions.contains(identity) {
            guard connectivity.requestRouteDeletion(identity) != nil else {
                continue
            }
            queuedProviderDeletions.insert(identity)
        }
    }

    private func persistProviderDeletionTombstones() {
        let ordered = providerDeletionTombstones.sorted {
            if $0.routeID != $1.routeID {
                return $0.routeID.uuidString < $1.routeID.uuidString
            }
            if $0.revision != $1.revision {
                return $0.revision < $1.revision
            }
            return $0.contentHash < $1.contentHash
        }
        defaults.set(
            try? PropertyListEncoder().encode(ordered),
            forKey: providerDeletionTombstonesKey
        )
    }

    private static func decodeProviderDeletionTombstones(
        _ data: Data?
    ) -> Set<WatchRouteIdentityV1> {
        guard let data,
              let identities = try? PropertyListDecoder().decode(
                [WatchRouteIdentityV1].self,
                from: data
              ), identities.count <= 100 else {
            return []
        }
        return Set(identities)
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

    private func retryPendingInstallsImmediately() {
        for summary in routes {
            let identity = identity(for: summary)
            guard pendingInstallKeys.contains(Self.receiptKey(identity)),
                  let record = try? store.record(
                      matching: identity,
                      now: now()
                  ) else { continue }
            connectivity.sendRouteImmediately(record)
        }
    }

    private func identity(
        for summary: PlannedRouteSummaryV1
    ) -> WatchRouteIdentityV1 {
        WatchRouteIdentityV1(
            routeID: summary.id,
            revision: summary.revision,
            contentHash: summary.contentHash
        )
    }

    private func persistReadyReceipts() {
        defaults.set(readyReceiptKeys.sorted(), forKey: readyReceiptKey)
    }

    private func persistPendingDeletions() {
        defaults.set(
            pendingDeletionKeys.sorted(),
            forKey: pendingDeletionKey
        )
    }

    private func persistPendingInstalls() {
        defaults.set(
            pendingInstallKeys.sorted(),
            forKey: pendingInstallKey
        )
    }

    private func removeDisplayName(routeID: UUID) {
        var updated = displayNames
        guard updated.remove(routeID: routeID) else { return }
        displayNames = updated
        displayNames.persist(to: defaults)
    }

    private func publishRouteDisplayNames() {
        let entries = routes.compactMap { summary in
            try? WatchRouteDisplayNameV1(
                identity: identity(for: summary),
                name: displayName(for: summary)
            )
        }
        try? connectivity.updateRouteDisplayNames(entries)
    }

    private func syncState(
        for identity: WatchRouteIdentityV1
    ) -> PhoneRouteWatchSyncStateV1 {
        let key = Self.receiptKey(identity)
        if pendingDeletionKeys.contains(key) { return .deleting }
        if pendingInstallKeys.contains(key) { return .transferring }
        if readyReceiptKeys.contains(key) { return .ready }
        return .localOnly
    }

    private static func receiptKey(_ identity: WatchRouteIdentityV1) -> String {
        "\(identity.routeID.uuidString.lowercased())|\(identity.revision)|\(identity.contentHash)"
    }
}
struct PhoneOfflineRouteSaveResult: Equatable {
    let summary: PlannedRouteSummaryV1
    let alreadySaved: Bool
}

/// Shared by the confirmation UI and integration tests. The operation has one
/// synchronous atomic commit point on the library's actor: cancellation before
/// Save writes nothing; cancellation after success does not undo a committed save.
@MainActor
final class PhoneOfflineRouteSaveSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case ready
        case saving
        case saved(PhoneOfflineRouteSaveResult)
        case failed(String)
        case cancelled
    }
    let archive: NavigationRouteArchiveV1
    nonisolated let id: UUID
    @Published var name: String
    @Published private(set) var state: State = .ready
    private let now: () -> Date
    private let validationFailure: String?

    init(archive: NavigationRouteArchiveV1, now: @escaping () -> Date = Date.init) {
        self.archive = archive
        self.id = archive.routeID
        self.now = now
        name = archive.route.name ?? "\(archive.route.source.label) → \(archive.route.destination.label)"
        do {
            try archive.validate(purpose: .offlineNavigation, now: now())
            validationFailure = nil
        } catch {
            validationFailure = error.localizedDescription
            state = .failed(error.localizedDescription)
        }
    }

    var canSave: Bool {
        switch state {
        case .saving, .saved, .cancelled: return false
        case .ready, .failed: break
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return validationFailure == nil && !trimmed.isEmpty && trimmed.count <= 120 &&
            OfflineRouteSourceEligibilityV1.allowsSave(
                provider: archive.route.provider, deleteAfter: archive.deleteAfter, now: now()
            )
    }

    @discardableResult
    func save(to library: PhoneRouteLibrary) -> PhoneOfflineRouteSaveResult? {
        guard canSave else { return nil }
        state = .saving
        do {
            let result = try library.saveOffline(archive, name: name)
            state = .saved(result)
            return result
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ??
                NSLocalizedString("The route could not be saved. Check available iPhone storage and try again.", comment: "Offline route storage failure"))
            return nil
        }
    }

    func cancel() {
        switch state {
        case .ready, .failed: state = .cancelled
        case .saving, .saved, .cancelled: break
        }
    }
}
