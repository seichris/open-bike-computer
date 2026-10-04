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
    case watchUpdateRequired
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
    /// Excludes pending deletion even while its row remains visible for Watch
    /// status. Preview/navigation observers consume this admission list.
    @Published private(set) var offlineNavigationRoutes: [PlannedRouteSummaryV1] = []
    @Published private(set) var stravaReloadBookmarks:
        [StravaRouteReloadBookmarkV1] = []
    @Published private(set) var stravaBookmarkStoreAvailable = true
    @Published private(set) var watchSyncState:
        [WatchRouteIdentityV1: PhoneRouteWatchSyncStateV1] = [:]
    @Published private var displayNames: SavedRouteDisplayNames

    private let operations: WatchRouteOperationJournalV2
    private let store: NavigationRouteFileStoreV1
    private let stravaBookmarkStore: StravaRouteReloadBookmarkStoreV1
    private let connectivity: PhoneWatchConnectivityCoordinator
    private let now: () -> Date
    private let defaults: UserDefaults
    private let readyReceiptKey = "watchRouteReadyReceipts.v1"
    private let pendingDeletionKey = "watchRoutePendingDeletions.v1"
    private let pendingInstallKey = "watchRoutePendingInstalls.v1"
    private let attemptedInstallKey = "watchRouteAttemptedInstalls.v1"
    private let rejectedInstallReasonsKey =
        "watchRouteRejectedInstallReasons.v1"
    private let pendingInstallStartedAtKey =
        "watchRoutePendingInstallStartedAt.v1"
    private let pendingInstallMaximumAge: TimeInterval = 7 * 24 * 60 * 60
    private let providerDeletionTombstonesKey =
        "watchRouteProviderDeletionTombstones.v1"
    private var readyReceiptKeys: Set<String>
    private var pendingDeletionKeys: Set<String>
    private var pendingInstallKeys: Set<String>
    private var attemptedInstallKeys: Set<String>
    private var rejectedInstallReasons: [String: String]
    private var pendingInstallStartedAt: [String: Date]
    private let localDeletionTombstonesKey = "phoneRouteLocalDeletionTombstones.v1"
    private var localDeletionTombstones: Set<WatchRouteIdentityV1>
    private var providerDeletionTombstones: Set<WatchRouteIdentityV1>
    private var queuedProviderDeletions: Set<WatchRouteIdentityV1> = []
    private var immediateInstallKeys: Set<String> = []
    private var cancellables = Set<AnyCancellable>()
    private var expiryTask: Task<Void, Never>?
    private var pendingInstallExpiryTask: Task<Void, Never>?
    private var deletionRetryTask: Task<Void, Never>?

    convenience init(connectivity: PhoneWatchConnectivityCoordinator) {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        // Never fall back to a purgeable temporary directory for a successful
        // Save Offline operation. A write failure must be reported instead.
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
        self.operations = WatchRouteOperationJournalV2(rootDirectory: store.rootDirectory)
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
        attemptedInstallKeys = Set(
            defaults.stringArray(forKey: attemptedInstallKey) ?? []
        )
        rejectedInstallReasons = defaults.dictionary(
            forKey: rejectedInstallReasonsKey
        ) as? [String: String] ?? [:]
        pendingInstallStartedAt = defaults.dictionary(
            forKey: pendingInstallStartedAtKey
        )?.compactMapValues { $0 as? Date } ?? [:]
        providerDeletionTombstones = Self.decodeProviderDeletionTombstones(
            defaults.data(forKey: providerDeletionTombstonesKey)
        )
        // Older builds tracked only the Watch half of a provider deletion.
        // Retry its local half too; never forget it just because Watch replies.
        localDeletionTombstones = Self.decodeProviderDeletionTombstones(
            defaults.data(forKey: localDeletionTombstonesKey)
        ).union(providerDeletionTombstones)
        connectivity.onRouteAcknowledgement = { [weak self] message in
            self?.receive(message)
        }
        connectivity.$state
            .map {
                $0.isActivated && $0.isPaired && $0.isWatchAppInstalled && $0.routeSyncSchemaVersion >= 2
            }
            .removeDuplicates()
            .sink { [weak self] isWatchAvailable in
                guard isWatchAvailable else { return }
                Task { @MainActor [weak self] in
                    self?.autoQueueEligibleRoutes()
                }
            }
            .store(in: &cancellables)
        connectivity.$state
            .map(\.isReachable)
            .removeDuplicates()
            .sink { [weak self] isReachable in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard isReachable else {
                        self.immediateInstallKeys.removeAll()
                        return
                    }
                    self.retryPendingInstallsImmediately()
                    self.queuedProviderDeletions.removeAll()
                    self.retryProviderDeletions()
                }
            }
            .store(in: &cancellables)
        reload()
    }

    @discardableResult
    func importArchive(_ data: Data) throws -> PlannedRouteSummaryV1 {
        let archive = try NavigationRouteArchiveV1.decode(
            data, purpose: .offlineNavigation, now: now()
        )
        let identity = WatchRouteIdentityV1(archive: archive)
        try requireUsableIdentity(identity)
        if let prior = try operations.entry(identity), prior.operation == .delete, prior.applied {
            // Explicit import after a completed deletion is a new desired state,
            // even when its content bytes are identical to the deleted archive.
            _ = try operations.issue(.install, identity: identity)
        }
        let record = try store.install(data, now: now())
        reload()
        return record.summary
    }

    @discardableResult
    func importGPX(
        _ data: Data,
        fileName: String
    ) throws -> PlannedRouteSummaryV1 {
        let draft = try OfflineRouteSaveDraft.gpx(data: data, fileName: fileName, now: now())
        return try saveOffline(draft, name: draft.archive.route.name ?? fileName).summary
    }

    /// The only Save Offline commit path. Library-backed selections are reads,
    /// never clones: in particular a Strava lease cannot be extended by saving.
    func saveOffline(_ draft: OfflineRouteSaveDraft, name: String) throws -> OfflineRouteSaveResult {
        try draft.archive.validate(purpose: .offlineNavigation, now: now())
        if draft.requiresExistingArchive {
            let archive = try offlineArchive(for: PlannedRouteSummaryV1(archive: draft.archive))
            return OfflineRouteSaveResult(summary: PlannedRouteSummaryV1(archive: archive), alreadySaved: true)
        }
        let archive = try draft.namedArchive(name)
        // Repeated clicks on the same selected alternative must keep the first
        // committed name/hash rather than mutate an existing revision.
        if let existing = store.records(now: now()).first(where: {
            $0.archive.routeID == archive.routeID
        }) {
            guard existing.archive.revision == archive.revision else {
                throw NavigationRouteFileStoreError.staleRevision
            }
            guard OfflineRouteSaveDraft.sameSavableContent(existing.archive.route, archive.route) else {
                throw NavigationRouteFileStoreError.revisionConflict
            }
            let verified = try offlineArchive(for: existing.summary)
            return OfflineRouteSaveResult(summary: PlannedRouteSummaryV1(archive: verified), alreadySaved: true)
        }
        if let duplicate = store.records(now: now()).first(where: {
            OfflineRouteSaveDraft.sameSavableContent($0.archive.route, archive.route)
        }) {
            // Re-read the exact identity, also covering expiry/corruption races.
            let verified = try offlineArchive(for: duplicate.summary)
            reload()
            return OfflineRouteSaveResult(summary: PlannedRouteSummaryV1(archive: verified), alreadySaved: true)
        }
        let summary = try importArchive(archive.encoded(purpose: .offlineNavigation, now: now()))
        _ = try offlineArchive(for: summary)
        return OfflineRouteSaveResult(summary: summary, alreadySaved: false)
    }

    func offlineDraft(for summary: PlannedRouteSummaryV1) throws -> OfflineRouteSaveDraft {
        try .installed(offlineArchive(for: summary), now: now())
    }

    /// Navigation must re-read the exact durable identity, not use a preview's
    /// cached geometry or silently substitute a newer revision.
    func offlineArchive(for summary: PlannedRouteSummaryV1) throws -> NavigationRouteArchiveV1 {
        do {
            let selectedIdentity = identity(for: summary)
            try requireUsableIdentity(selectedIdentity)
            let record = try store.record(matching: selectedIdentity, now: now())
            try record.archive.validate(purpose: .offlineNavigation, now: now())
            return record.archive
        } catch {
            reload()
            if let deadline = summary.deleteAfter, now() >= deadline {
                throw SavedRouteMapError.expired(displayName(for: summary))
            }
            throw SavedRouteMapError.unavailable(displayName(for: summary))
        }
    }

    func isAvailableOffline(_ summary: PlannedRouteSummaryV1) -> Bool {
        let selected = identity(for: summary)
        return !isPendingDeletion(selected) &&
            (summary.deleteAfter.map { now() < $0 } ?? true) &&
            offlineNavigationRoutes.contains { identity(for: $0) == selected }
    }

    private func isPendingDeletion(_ identity: WatchRouteIdentityV1) -> Bool {
        if pendingDeletionKeys.contains(Self.receiptKey(identity)) ||
            localDeletionTombstones.contains(identity) ||
            providerDeletionTombstones.contains(identity) { return true }
        do {
            let operation = try operations.entry(identity)
            return operation?.operation == .delete && operation?.applied == false
        } catch { return true }
    }

    private func requireUsableIdentity(_ identity: WatchRouteIdentityV1) throws {
        guard !isPendingDeletion(identity) else {
            throw NavigationRouteFileStoreError.notFound
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
        var removedLocally = true
        for record in records {
            if !removeArchiveAndQueueWatchDeletion(record) { removedLocally = false }
        }
        let removed = try stravaBookmarkStore.purge()
        for routeID in routeIDs { removeDisplayName(routeID: routeID) }
        reload()
        guard removedLocally else { throw NavigationRouteFileStoreError.ioFailure }
        return removed
    }

    func canSendToWatch(_ summary: PlannedRouteSummaryV1) -> Bool {
        isAvailableOffline(summary) && summary.providerID != RouteProviderPolicyV1.mapKit.providerID
    }

    func retryWatchSync(_ summary: PlannedRouteSummaryV1) throws {
        if isPendingDeletion(identity(for: summary)) {
            try delete(summary)
        } else {
            try sendToWatch(summary)
        }
    }

    func sendToWatch(_ summary: PlannedRouteSummaryV1) throws {
        let identity = identity(for: summary)
        try requireUsableIdentity(identity)
        let record = try store.record(matching: identity, now: now())
        try record.archive.validate(purpose: .watchTransfer, now: now())
        let key = Self.receiptKey(identity)
        guard connectivity.state.routeSyncSchemaVersion >= 2 else {
            watchSyncState[identity] = .rejected("watch_update_required")
            return
        }
        attemptedInstallKeys.insert(key)
        let operation = try operations.issue(.install, identity: identity,
                                             renew: !pendingInstallKeys.contains(key))
        guard connectivity.transferRoute(record, deliveryOperation: operation) != nil else {
            rejectedInstallReasons[key] = "watch_unavailable"
            persistInstallAttempts()
            watchSyncState[identity] = .rejected("watch_unavailable")
            return
        }
        rejectedInstallReasons.removeValue(forKey: key)
        pendingInstallKeys.insert(key)
        pendingInstallStartedAt[key] = now()
        persistPendingInstalls()
        persistInstallAttempts()
        watchSyncState[identity] = .transferring
        if connectivity.state.isReachable {
            immediateInstallKeys.insert(key)
        }
        scheduleNextPendingInstallExpiry()
        connectivity.sendRouteImmediately(record, deliveryOperation: operation)
    }

    @discardableResult
    func cancelSendToWatch(_ summary: PlannedRouteSummaryV1) -> Bool {
        let identity = identity(for: summary)
        let key = Self.receiptKey(identity)
        guard pendingInstallKeys.contains(key) else { return true }
        // A transfer can disappear from WCSession's outstanding queue without
        // the acknowledgement reaching iPhone. Clear the durable local attempt
        // even when there is no longer a system transfer to cancel. A late
        // ready acknowledgement remains authoritative and restores `.ready`.
        _ = connectivity.cancelRouteTransfers(identity)
        clearPendingInstall(key)
        persistPendingInstalls()
        if readyReceiptKeys.contains(key) {
            attemptedInstallKeys.remove(key)
            rejectedInstallReasons.removeValue(forKey: key)
            watchSyncState[identity] = .ready
        } else {
            attemptedInstallKeys.insert(key)
            rejectedInstallReasons[key] = "transfer_cancelled"
            watchSyncState[identity] = .rejected("transfer_cancelled")
        }
        persistInstallAttempts()
        scheduleNextPendingInstallExpiry()
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
            try requireUsableIdentity(identity(for: summary))
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
        let priorOperation = try operations.entry(identity)
        guard readyReceiptKeys.contains(key) || attemptedInstallKeys.contains(key) ||
                pendingDeletionKeys.contains(key) || priorOperation != nil else {
            try store.delete(matching: identity, now: now())
            removeDisplayName(routeID: summary.id)
            watchSyncState.removeValue(forKey: identity)
            reload()
            return
        }
        guard connectivity.state.routeSyncSchemaVersion >= 2 else {
            watchSyncState[identity] = .rejected("watch_update_required")
            throw PhoneRouteLibraryError.watchUpdateRequired
        }
        let operation = try operations.issue(.delete, identity: identity)
        guard connectivity.requestRouteDeletion(identity, deliveryOperation: operation) != nil else {
            throw PhoneRouteLibraryError.watchUnavailable
        }
        pendingDeletionKeys.insert(key)
        persistPendingDeletions()
        watchSyncState[identity] = .deleting
        reload()
    }

    func reload() {
        let timestamp = now()
        loadStravaBookmarks()
        do {
            // The journal precedes WC submission and legacy UI bookkeeping.
            // Reconcile a crash after receipt persistence but before local unlink.
            let stored = Set(store.recordsIncludingExpired().map { WatchRouteIdentityV1(archive: $0.archive) })
            for operation in try operations.entries()
                where operation.operation == .delete && operation.applied && stored.contains(operation.identity) {
                localDeletionTombstones.insert(operation.identity)
            }
        } catch {
            routes = []
            offlineNavigationRoutes = []
            return
        }
        for identity in localDeletionTombstones {
            _ = finishLocalDeletion(identity)
        }
        for record in store.expiredRecords(now: timestamp) {
            removeArchiveAndQueueWatchDeletion(record)
        }
        _ = store.pruneInvalidAndExpired(now: timestamp)
        routes = store.records(now: timestamp).filter {
            let identity = WatchRouteIdentityV1(archive: $0.archive)
            return !localDeletionTombstones.contains(identity) &&
                !providerDeletionTombstones.contains(identity)
        }.map(\.summary)
        let installedIdentities = Set(routes.map { identity(for: $0) })
        let installedKeys = Set(installedIdentities.map(Self.receiptKey))
        // Migrate attempts queued by older builds so the one-week expiry does
        // not immediately auto-create the same transfer again.
        attemptedInstallKeys.formUnion(pendingInstallKeys)
        readyReceiptKeys.formIntersection(installedKeys)
        pendingDeletionKeys.formIntersection(installedKeys)
        pendingInstallKeys.formIntersection(installedKeys)
        attemptedInstallKeys.formIntersection(installedKeys)
        immediateInstallKeys.formIntersection(installedKeys)
        rejectedInstallReasons = rejectedInstallReasons.filter {
            installedKeys.contains($0.key)
        }
        pendingInstallStartedAt = pendingInstallStartedAt.filter {
            pendingInstallKeys.contains($0.key)
        }
        expireStalePendingInstalls(
            installedIdentities: installedIdentities,
            at: timestamp
        )
        persistReadyReceipts()
        persistPendingDeletions()
        persistPendingInstalls()
        persistInstallAttempts()
        watchSyncState = Dictionary(uniqueKeysWithValues:
            installedIdentities.map { identity in
                (
                    identity,
                    syncState(for: identity)
                )
            }
        )
        offlineNavigationRoutes = routes.filter { !isPendingDeletion(identity(for: $0)) }
        publishRouteDisplayNames()
        autoQueueEligibleRoutes()
        retryProviderDeletions()
        scheduleNextExpiry()
        scheduleNextPendingInstallExpiry()
    }

    private func receive(_ message: WatchRouteSyncMessageV1) {
        // A receipt must identify the exact current operation, including after
        // reinstalling identical route bytes. Old file/immediate replies cannot
        // settle a successor install or deletion.
        do {
            let operation = try operations.entry(message.identity)
            guard message.deliveryOperation == operation?.token else { return }
            if let operation {
                guard (message.status != .ready || operation.operation == .install),
                      (message.status != .deleted || operation.operation == .delete) else { return }
                if message.status == .ready || message.status == .deleted ||
                    (message.status == .evicted && operation.operation == .delete) {
                    try operations.complete(operation.operation, identity: message.identity,
                                            token: message.deliveryOperation)
                }
            }
        } catch { return }
        switch message.status {
        case .ready:
            if providerDeletionTombstones.contains(message.identity) ||
                localDeletionTombstones.contains(message.identity) {
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
            let key = Self.receiptKey(message.identity)
            readyReceiptKeys.insert(key)
            _ = connectivity.cancelRouteTransfers(message.identity)
            clearPendingInstall(key)
            attemptedInstallKeys.remove(key)
            rejectedInstallReasons.removeValue(forKey: key)
            persistReadyReceipts()
            persistPendingInstalls()
            persistInstallAttempts()
            watchSyncState[message.identity] = .ready
            scheduleNextPendingInstallExpiry()
        case .deleted, .evicted:
            let identity = message.identity
            let key = Self.receiptKey(identity)
            let deletionRequested = isPendingDeletion(identity) ||
                ((try? operations.entry(identity)?.operation) == .delete)
            // An ordinary eviction changes Watch availability, not phone
            // ownership. Ignore unsolicited deletion acknowledgements.
            if message.status == .deleted && !deletionRequested { return }
            if deletionRequested {
                localDeletionTombstones.insert(identity)
                persistLocalDeletionTombstones()
                _ = finishLocalDeletion(identity)
            }
            providerDeletionTombstones.remove(identity)
            queuedProviderDeletions.remove(identity)
            persistProviderDeletionTombstones()
            readyReceiptKeys.remove(key)
            pendingDeletionKeys.remove(key)
            clearPendingInstall(key)
            attemptedInstallKeys.remove(key)
            rejectedInstallReasons.removeValue(forKey: key)
            persistReadyReceipts()
            persistPendingDeletions()
            persistPendingInstalls()
            persistInstallAttempts()
            reload()
        case .rejected:
            if (try? operations.entry(message.identity)?.operation) == .delete {
                queuedProviderDeletions.remove(message.identity)
                watchSyncState[message.identity] = .rejected(message.errorCode ?? "watch_rejected")
                scheduleDeletionRetry()
                return
            }
            if providerDeletionTombstones.contains(message.identity) ||
                localDeletionTombstones.contains(message.identity) {
                queuedProviderDeletions.remove(message.identity)
                persistProviderDeletionTombstones()
                return
            }
            guard watchSyncState[message.identity] != nil else { return }
            let key = Self.receiptKey(message.identity)
            attemptedInstallKeys.insert(key)
            immediateInstallKeys.remove(key)
            rejectedInstallReasons[key] =
                message.errorCode ?? "watch_rejected"
            let wasDeleting = pendingDeletionKeys.contains(key)
            if WatchRouteAcknowledgementReconciliationV1
                .preservesReadyReceipt(
                    hasReadyReceipt: readyReceiptKeys.contains(key),
                    isPendingDeletion: wasDeleting
                ) {
                clearPendingInstall(key)
                attemptedInstallKeys.remove(key)
                rejectedInstallReasons.removeValue(forKey: key)
                persistPendingInstalls()
                persistInstallAttempts()
                watchSyncState[message.identity] = .ready
                scheduleNextPendingInstallExpiry()
                return
            }
            if wasDeleting {
                pendingDeletionKeys.remove(key)
            }
            if !wasDeleting {
                readyReceiptKeys.remove(key)
            }
            clearPendingInstall(key)
            persistReadyReceipts()
            persistPendingDeletions()
            persistPendingInstalls()
            persistInstallAttempts()
            reload()
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
        localDeletionTombstones.insert(identity)
        persistLocalDeletionTombstones()
        queuedProviderDeletions.remove(identity)
        let key = Self.receiptKey(identity)
        readyReceiptKeys.remove(key)
        pendingDeletionKeys.remove(key)
        clearPendingInstall(key)
        attemptedInstallKeys.remove(key)
        rejectedInstallReasons.removeValue(forKey: key)
        persistReadyReceipts()
        persistPendingDeletions()
        persistPendingInstalls()
        persistInstallAttempts()
        persistProviderDeletionTombstones()
        let removed = finishLocalDeletion(identity)
        retryProviderDeletions()
        return removed
    }

    /// Local cleanup and Watch acknowledgement have independent durable state.
    /// A failed unlink must remain retryable after either Watch reply or restart.
    @discardableResult
    private func finishLocalDeletion(_ identity: WatchRouteIdentityV1) -> Bool {
        do {
            try store.deleteDeferred(matching: identity)
        } catch NavigationRouteFileStoreError.notFound {
            // deleteDeferred synchronizes an existing directory even on retry.
        } catch {
            return false
        }
        localDeletionTombstones.remove(identity)
        persistLocalDeletionTombstones()
        if stravaBookmark(routeID: identity.routeID) == nil &&
            !store.recordsIncludingExpired().contains(where: { $0.archive.routeID == identity.routeID }) {
            removeDisplayName(routeID: identity.routeID)
        }
        return true
    }

    private func persistLocalDeletionTombstones() {
        defaults.set(try? PropertyListEncoder().encode(Array(localDeletionTombstones)),
                     forKey: localDeletionTombstonesKey)
    }

    private func retryProviderDeletions() {
        guard connectivity.state.routeSyncSchemaVersion >= 2 else { return }
        guard let operationsPending = try? operations.entries() else { return }
        let identities = providerDeletionTombstones.union(operationsPending.filter {
            $0.operation == .delete && !$0.applied
        }.map(\.identity))
        for identity in identities where !queuedProviderDeletions.contains(identity) {
            guard let operation = try? operations.issue(.delete, identity: identity),
                  connectivity.requestRouteDeletion(identity, deliveryOperation: operation) != nil else { continue }
            queuedProviderDeletions.insert(identity)
        }
        if !identities.isEmpty { scheduleDeletionRetry() }
    }

    private func scheduleDeletionRetry() {
        guard deletionRetryTask == nil else { return }
        deletionRetryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self else { return }
            deletionRetryTask = nil
            queuedProviderDeletions.removeAll()
            retryProviderDeletions()
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

    private func expireStalePendingInstalls(
        installedIdentities: Set<WatchRouteIdentityV1>,
        at timestamp: Date
    ) {
        let identitiesByKey = Dictionary(
            uniqueKeysWithValues: installedIdentities.map {
                (Self.receiptKey($0), $0)
            }
        )
        for key in pendingInstallKeys {
            guard isPendingInstallStale(key, at: timestamp) else { continue }
            if let identity = identitiesByKey[key] {
                _ = connectivity.cancelRouteTransfers(identity)
            }
            clearPendingInstall(key)
        }
    }

    /// Untimestamped attempts came from the legacy queue and cannot prove
    /// freshness. Expire them once on upgrade instead of leaving an immortal
    /// "Queued" row. Retrying is safe because Watch installs are idempotent by
    /// immutable route identity.
    private func isPendingInstallStale(
        _ key: String,
        at timestamp: Date
    ) -> Bool {
        guard let startedAt = pendingInstallStartedAt[key],
              startedAt <= timestamp else { return true }
        return timestamp.timeIntervalSince(startedAt) >=
            pendingInstallMaximumAge
    }

    private func scheduleNextPendingInstallExpiry() {
        pendingInstallExpiryTask?.cancel()
        let timestamp = now()
        let deadline = pendingInstallKeys.compactMap { key -> Date? in
            guard let startedAt = pendingInstallStartedAt[key],
                  startedAt <= timestamp else { return timestamp }
            return startedAt.addingTimeInterval(pendingInstallMaximumAge)
        }.min()
        guard let deadline else {
            pendingInstallExpiryTask = nil
            return
        }
        let delay = max(deadline.timeIntervalSince(timestamp), 0)
        let nanoseconds = UInt64(min(
            delay * 1_000_000_000,
            Double(UInt64.max)
        ))
        pendingInstallExpiryTask = Task { @MainActor [weak self] in
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
        guard connectivity.state.isReachable else { return }
        for summary in routes {
            let identity = identity(for: summary)
            let key = Self.receiptKey(identity)
            guard canSendToWatch(summary), !isPendingDeletion(identity),
                  pendingInstallKeys.contains(key),
                  !immediateInstallKeys.contains(key),
                  let record = try? store.record(
                      matching: identity,
                      now: now()
                  ) else { continue }
            immediateInstallKeys.insert(key)
            guard let operation = try? operations.issue(.install, identity: identity) else { continue }
            connectivity.sendRouteImmediately(record, deliveryOperation: operation)
        }
    }

    /// Watch-supported routes are mirrored automatically once the paired Watch
    /// app is available. Pending, ready and explicitly rejected identities are
    /// left alone so reloads cannot duplicate work or hide a failed transfer.
    private func autoQueueEligibleRoutes() {
        let state = connectivity.state
        guard state.isActivated, state.isPaired, state.isWatchAppInstalled,
              state.routeSyncSchemaVersion >= 2 else {
            return
        }
        for summary in routes {
            let identity = identity(for: summary)
            guard canSendToWatch(summary),
                  syncState(for: identity) == .localOnly else { continue }
            try? sendToWatch(summary)
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
        defaults.set(
            pendingInstallStartedAt,
            forKey: pendingInstallStartedAtKey
        )
    }

    private func clearPendingInstall(_ key: String) {
        pendingInstallKeys.remove(key)
        pendingInstallStartedAt.removeValue(forKey: key)
        immediateInstallKeys.remove(key)
    }

    private func persistInstallAttempts() {
        defaults.set(
            attemptedInstallKeys.sorted(),
            forKey: attemptedInstallKey
        )
        defaults.set(
            rejectedInstallReasons,
            forKey: rejectedInstallReasonsKey
        )
    }

    private func removeDisplayName(routeID: UUID) {
        var updated = displayNames
        guard updated.remove(routeID: routeID) else { return }
        displayNames = updated
        displayNames.persist(to: defaults)
    }

    private func publishRouteDisplayNames() {
        let entries = routes.filter {
            $0.providerID != RouteProviderPolicyV1.mapKit.providerID
        }.compactMap { summary in
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
        if isPendingDeletion(identity) { return .deleting }
        if pendingInstallKeys.contains(key) { return .transferring }
        if readyReceiptKeys.contains(key) { return .ready }
        if let reason = rejectedInstallReasons[key] {
            return .rejected(reason)
        }
        if attemptedInstallKeys.contains(key) {
            return .rejected("transfer_expired")
        }
        return .localOnly
    }

    private static func receiptKey(_ identity: WatchRouteIdentityV1) -> String {
        "\(identity.routeID.uuidString.lowercased())|\(identity.revision)|\(identity.contentHash)"
    }
}


extension PhoneRouteLibraryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .watchUpdateRequired: "Update Bicino on Apple Watch before syncing routes."
        default: nil
        }
    }
}
