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
}

/// Durable route ownership on iPhone. Only archives whose provider policy
/// explicitly permits offline storage can enter this library.
@MainActor
final class PhoneRouteLibrary: ObservableObject {
    @Published private(set) var routes: [PlannedRouteSummaryV1] = []
    @Published private(set) var watchSyncState:
        [WatchRouteIdentityV1: PhoneRouteWatchSyncStateV1] = [:]

    private let store: NavigationRouteFileStoreV1
    private let connectivity: PhoneWatchConnectivityCoordinator
    private let now: () -> Date
    private let defaults: UserDefaults
    private let readyReceiptKey = "watchRouteReadyReceipts.v1"
    private let pendingDeletionKey = "watchRoutePendingDeletions.v1"
    private let pendingInstallKey = "watchRoutePendingInstalls.v1"
    private var readyReceiptKeys: Set<String>
    private var pendingDeletionKeys: Set<String>
    private var pendingInstallKeys: Set<String>
    private var cancellables = Set<AnyCancellable>()

    convenience init(connectivity: PhoneWatchConnectivityCoordinator) {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        self.init(
            store: NavigationRouteFileStoreV1(
                rootDirectory: base.appendingPathComponent(
                    "PlannedRoutes",
                    isDirectory: true
                )
            ),
            connectivity: connectivity,
            defaults: .standard
        )
    }

    init(
        store: NavigationRouteFileStoreV1,
        connectivity: PhoneWatchConnectivityCoordinator,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.connectivity = connectivity
        self.defaults = defaults
        self.now = now
        readyReceiptKeys = Set(
            defaults.stringArray(forKey: readyReceiptKey) ?? []
        )
        pendingDeletionKeys = Set(
            defaults.stringArray(forKey: pendingDeletionKey) ?? []
        )
        pendingInstallKeys = Set(
            defaults.stringArray(forKey: pendingInstallKey) ?? []
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
        let archive = try GPXRouteImporterV1.archive(
            data: data,
            fallbackName: fileName,
            createdAt: now()
        )
        return try importArchive(archive.encoded(
            purpose: .offlineNavigation,
            now: now()
        ))
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

    func delete(_ summary: PlannedRouteSummaryV1) throws {
        let identity = identity(for: summary)
        let key = Self.receiptKey(identity)
        guard !pendingInstallKeys.contains(key) else {
            throw PhoneRouteLibraryError.transferInProgress
        }
        guard readyReceiptKeys.contains(key) ||
                pendingDeletionKeys.contains(key) else {
            try store.delete(matching: identity, now: now())
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
        _ = store.pruneInvalidAndExpired(now: now())
        routes = store.records(now: now()).map(\.summary)
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
    }

    private func receive(_ message: WatchRouteSyncMessageV1) {
        switch message.status {
        case .ready:
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
            try? store.delete(matching: message.identity, now: now())
            readyReceiptKeys.remove(Self.receiptKey(message.identity))
            pendingDeletionKeys.remove(Self.receiptKey(message.identity))
            pendingInstallKeys.remove(Self.receiptKey(message.identity))
            persistReadyReceipts()
            persistPendingDeletions()
            persistPendingInstalls()
            reload()
        case .rejected:
            guard watchSyncState[message.identity] != nil else { return }
            let key = Self.receiptKey(message.identity)
            let wasDeleting = pendingDeletionKeys.remove(key) != nil
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
