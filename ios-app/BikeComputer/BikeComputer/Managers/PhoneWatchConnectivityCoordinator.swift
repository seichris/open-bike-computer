import Foundation
import WatchConnectivity

struct PhoneWatchConnectivityStateV1: Equatable {
    var isSupported = false
    var isActivated = false
    var activationFailed = false
    var isPaired = false
    var isWatchAppInstalled = false
    var isReachable = false
}

/// The sole production owner of `WCSession.default` on iPhone.
///
/// Application-context fields are merged so independently evolving features
/// cannot erase each other's state. Route files and deletion commands use the
/// queued WatchConnectivity APIs and therefore do not require reachability.
@MainActor
final class PhoneWatchConnectivityCoordinator: NSObject, ObservableObject,
    PhoneWatchControllerTransporting {
    @Published private(set) var state: PhoneWatchConnectivityStateV1

    var onRouteAcknowledgement: ((WatchRouteSyncMessageV1) -> Void)?

    private let session: WCSession?
    private let defaults: UserDefaults
    private var hasActivated = false
    private var pendingControllerRevocations: [WatchControllerRequestV1] = []
    private var coordinateFavoritesEnvelope: CoordinateFavoritesEnvelopeV1?
    private static let pendingControllerRevocationsDefaultsKey =
        "watchController.pendingRevocations.v1"
    private static let coordinateFavoritesDefaultsKey =
        "watchNavigation.coordinateFavoritesEnvelope.v1"

    override convenience init() {
        self.init(
            session: WCSession.isSupported() ? .default : nil,
            defaults: .standard
        )
    }

    init(session: WCSession?, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
        state = PhoneWatchConnectivityStateV1(
            isSupported: session != nil
        )
        super.init()
        loadPendingControllerRevocations()
        if let data = defaults.data(
            forKey: Self.coordinateFavoritesDefaultsKey
        ) {
            coordinateFavoritesEnvelope = try?
                CoordinateFavoritesEnvelopeV1.decode(data)
        }
    }

    func activate() {
        guard let session else {
            refreshState(activationFailed: false)
            return
        }
        guard !hasActivated else {
            refreshState()
            return
        }
        hasActivated = true
        session.delegate = self
        session.activate()
        refreshState(activationFailed: false)
    }

    func updateApplicationContextMerging(_ fields: [String: Any]) throws {
        guard let session else { return }
        var merged = session.applicationContext
        for (key, value) in fields {
            merged[key] = value
        }
        try session.updateApplicationContext(merged)
    }

    func updateCoordinateFavorites(
        _ favorites: [SyncedCoordinateFavoriteV1]
    ) throws {
        let validated = try favorites.map { try $0.validated() }
        let revision: UInt64
        if coordinateFavoritesEnvelope?.favorites == validated {
            guard let envelope = coordinateFavoritesEnvelope else { return }
            try publishCoordinateFavorites(envelope)
            return
        } else {
            let currentRevision = coordinateFavoritesEnvelope?.revision ?? 0
            guard currentRevision < UInt64.max else {
                throw SyncedFavoriteContractError.invalidEnvelope
            }
            revision = currentRevision + 1
        }
        let envelope = try CoordinateFavoritesEnvelopeV1(
            revision: revision,
            favorites: validated
        ).validated()
        let data = try envelope.encoded()
        coordinateFavoritesEnvelope = envelope
        defaults.set(data, forKey: Self.coordinateFavoritesDefaultsKey)
        try publishCoordinateFavorites(envelope)
    }

    private func publishCoordinateFavorites(
        _ envelope: CoordinateFavoritesEnvelopeV1
    ) throws {
        try updateApplicationContextMerging([
            CoordinateFavoritesEnvelopeV1.applicationContextKey:
                try envelope.encoded(),
        ])
    }

    nonisolated func sendWatchControllerRequest(
        _ request: WatchControllerRequestV1,
        completion: @escaping @Sendable (
            Result<WatchControllerResponseV1,
                   PhoneWatchControllerTransportError>
        ) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                completion(.failure(
                    PhoneWatchControllerTransportError.watchUnavailable
                ))
                return
            }
            self.sendWatchControllerRequestOnMain(
                request,
                completion: completion
            )
        }
    }

    nonisolated func queueWatchControllerRevocation(
        _ request: WatchControllerRequestV1
    ) {
        Task { @MainActor [weak self] in
            guard let self, request.operation == .revoke,
                  (try? request.validated()) != nil else {
                return
            }
            self.pendingControllerRevocations.removeAll {
                $0.deviceID == request.deviceID &&
                    $0.controllerID == request.controllerID
            }
            self.pendingControllerRevocations.append(request)
            self.persistPendingControllerRevocations()
            self.flushPendingControllerRevocations()
        }
    }

    private func loadPendingControllerRevocations() {
        guard let data = defaults.data(
            forKey: Self.pendingControllerRevocationsDefaultsKey
        ), let requests = try? PropertyListDecoder().decode(
            [WatchControllerRequestV1].self,
            from: data
        ) else {
            return
        }
        pendingControllerRevocations = requests.filter {
            $0.operation == .revoke && (try? $0.validated()) != nil
        }
    }

    private func persistPendingControllerRevocations() {
        if pendingControllerRevocations.isEmpty {
            defaults.removeObject(
                forKey: Self.pendingControllerRevocationsDefaultsKey
            )
            return
        }
        guard let data = try? PropertyListEncoder().encode(
            pendingControllerRevocations
        ) else { return }
        defaults.set(
            data,
            forKey: Self.pendingControllerRevocationsDefaultsKey
        )
    }

    private func flushPendingControllerRevocations() {
        guard let session,
              session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else { return }
        var queuedRequestIDs = Set<UUID>()
        for request in pendingControllerRevocations {
            guard let payload = try? request.encoded() else { continue }
            session.transferUserInfo([
                WatchControllerTransportV1.userInfoPayloadKey: payload,
            ])
            queuedRequestIDs.insert(request.requestID)
        }
        pendingControllerRevocations.removeAll {
            queuedRequestIDs.contains($0.requestID)
        }
        persistPendingControllerRevocations()
    }

    private func sendWatchControllerRequestOnMain(
        _ request: WatchControllerRequestV1,
        completion: @escaping @Sendable (
            Result<WatchControllerResponseV1,
                   PhoneWatchControllerTransportError>
        ) -> Void
    ) {
        guard let session,
              session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled,
              session.isReachable else {
            completion(.failure(
                PhoneWatchControllerTransportError.watchUnavailable
            ))
            return
        }
        let payload: Data
        do {
            payload = try request.encoded()
        } catch {
            completion(.failure(
                PhoneWatchControllerTransportError.invalidRequest
            ))
            return
        }
        session.sendMessageData(payload) { responseData in
            do {
                let response = try WatchControllerResponseV1.decode(
                    responseData
                )
                guard response.requestID == request.requestID else {
                    throw PhoneWatchControllerTransportError.invalidResponse
                }
                guard response.accepted else {
                    throw PhoneWatchControllerTransportError.rejected(
                        response.errorCode ?? "rejected"
                    )
                }
                completion(.success(response))
            } catch let error as PhoneWatchControllerTransportError {
                completion(.failure(error))
            } catch {
                completion(.failure(.invalidResponse))
            }
        } errorHandler: { error in
            completion(.failure(
                PhoneWatchControllerTransportError.transport(
                    String(describing: error)
                )
            ))
        }
    }

    @discardableResult
    func transferRoute(
        _ record: InstalledNavigationRouteV1
    ) -> WCSessionFileTransfer? {
        guard let session,
              session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else {
            return nil
        }
        let message = WatchRouteSyncMessageV1(
            operation: .install,
            identity: WatchRouteIdentityV1(archive: record.archive),
            encodedByteCount: record.encodedSize,
            deleteAfter: record.archive.deleteAfter
        )
        return session.transferFile(
            record.fileURL,
            metadata: message.propertyList
        )
    }

    @discardableResult
    func requestRouteDeletion(
        _ identity: WatchRouteIdentityV1
    ) -> WCSessionUserInfoTransfer? {
        guard let session,
              session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else {
            return nil
        }
        return session.transferUserInfo(
            WatchRouteSyncMessageV1(
                operation: .delete,
                identity: identity
            ).propertyList
        )
    }

    fileprivate func refreshState(activationFailed: Bool? = nil) {
        guard let session else {
            state = PhoneWatchConnectivityStateV1()
            return
        }
        let activated = session.activationState == .activated
        state = PhoneWatchConnectivityStateV1(
            isSupported: true,
            isActivated: activated,
            activationFailed: activationFailed ?? state.activationFailed,
            isPaired: activated && session.isPaired,
            isWatchAppInstalled: activated && session.isWatchAppInstalled,
            isReachable: activated && session.isReachable
        )
        if activated {
            flushPendingControllerRevocations()
            if let coordinateFavoritesEnvelope {
                try? publishCoordinateFavorites(coordinateFavoritesEnvelope)
            }
        }
    }

    fileprivate func receiveAcknowledgement(_ userInfo: [String: Any]) {
        guard let message = WatchRouteSyncMessageV1(propertyList: userInfo),
              message.operation == .acknowledge,
              message.status != nil else {
            return
        }
        onRouteAcknowledgement?(message)
    }

    fileprivate func finishFileTransfer(
        _ transfer: WCSessionFileTransfer,
        error: Error?
    ) {
        guard let error,
              let metadata = transfer.file.metadata,
              let install = WatchRouteSyncMessageV1(propertyList: metadata),
              install.operation == .install else {
            return
        }
        onRouteAcknowledgement?(
            WatchRouteSyncMessageV1(
                operation: .acknowledge,
                identity: install.identity,
                status: .rejected,
                errorCode: "transfer_failed_\((error as NSError).code)"
            )
        )
    }
}

extension PhoneWatchConnectivityCoordinator: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.refreshState(
                activationFailed: error != nil || activationState != .activated
            )
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.refreshState() }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        Task { @MainActor [weak self] in
            self?.refreshState(activationFailed: false)
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.refreshState() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.refreshState() }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            self?.receiveAcknowledgement(userInfo)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.finishFileTransfer(fileTransfer, error: error)
        }
    }
}
