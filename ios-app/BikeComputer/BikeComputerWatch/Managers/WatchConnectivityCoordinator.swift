import Foundation
import WatchConnectivity
import WatchKit

/// The sole production owner of `WCSession.default` on Apple Watch.
@MainActor
final class WatchConnectivityCoordinator: NSObject {
    var onApplicationContext: (([String: Any]) -> Void)?
    var onControllerCredentialsChanged: (() -> Void)?

    private let session: WCSession?
    private let routeLibrary: WatchRouteLibrary
    private let controllerCredentialStore: WatchControllerCredentialStore
    private var hasActivated = false

    init(
        routeLibrary: WatchRouteLibrary,
        controllerCredentialStore: WatchControllerCredentialStore,
        session: WCSession? = WCSession.isSupported() ? .default : nil
    ) {
        self.routeLibrary = routeLibrary
        self.controllerCredentialStore = controllerCredentialStore
        self.session = session
        super.init()
    }

    func activate() {
        guard let session else { return }
        if hasActivated {
            if session.activationState == .activated {
                publishDeviceMetadata(using: session)
            }
            return
        }
        hasActivated = true
        session.delegate = self
        session.activate()
    }

    func refreshDeviceMetadata() {
        guard let session,
              session.activationState == .activated else { return }
        publishDeviceMetadata(using: session)
    }

    fileprivate func activationDidComplete(
        _ state: WCSessionActivationState,
        error: Error?
    ) {
        guard error == nil, state == .activated, let session else { return }
        publishDeviceMetadata(using: session)
        onApplicationContext?(session.receivedApplicationContext)
    }

    private func publishDeviceMetadata(using session: WCSession) {
        let device = WKInterfaceDevice.current()
        let fallbackName = device.localizedModel.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty ? "Apple Watch" : device.localizedModel
        guard let metadata = try? WatchDeviceMetadataV1(
            name: device.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ? fallbackName : device.name,
            localizedModel: fallbackName,
            systemName: device.systemName,
            systemVersion: device.systemVersion
        ), let data = try? metadata.encoded() else { return }
        var merged = session.applicationContext
        merged[WatchDeviceMetadataV1.applicationContextKey] = data
        try? session.updateApplicationContext(merged)
    }

    fileprivate func receiveRouteFile(
        data: Data?,
        request: WatchRouteSyncMessageV1
    ) {
        guard let data else {
            acknowledge(request.identity, status: .rejected, error: "file_read")
            return
        }
        guard request.encodedByteCount == data.count else {
            acknowledge(request.identity, status: .rejected, error: "byte_count")
            return
        }
        do {
            let archive = try NavigationRouteArchiveV1.decode(
                data,
                purpose: .offlineNavigation
            )
            guard WatchRouteIdentityV1(archive: archive) == request.identity else {
                throw WatchRouteLibraryError.metadataMismatch
            }
            guard archive.deleteAfter == request.deleteAfter else {
                acknowledge(
                    request.identity,
                    status: .rejected,
                    error: "retention_mismatch"
                )
                return
            }
            _ = try routeLibrary.install(
                data,
                expectedIdentity: request.identity
            )
            acknowledge(request.identity, status: .ready)
        } catch {
            let code = Self.errorCode(for: error)
            routeLibrary.reportSyncError(code)
            acknowledge(request.identity, status: .rejected, error: code)
        }
    }

    fileprivate func receiveUserInfo(_ userInfo: [String: Any]) {
        if let payload = userInfo[
            WatchControllerTransportV1.userInfoPayloadKey
        ] as? Data {
            _ = receiveControllerRequest(payload)
            return
        }
        guard let request = WatchRouteSyncMessageV1(propertyList: userInfo),
              request.operation == .delete else {
            return
        }
        do {
            try routeLibrary.delete(request.identity)
            acknowledge(request.identity, status: .deleted)
        } catch NavigationRouteFileStoreError.notFound {
            // Deletion is idempotent: the requested exact revision is absent.
            acknowledge(request.identity, status: .deleted)
        } catch {
            let code = Self.errorCode(for: error)
            routeLibrary.reportSyncError(code)
            acknowledge(request.identity, status: .rejected, error: code)
        }
    }

    fileprivate func receiveControllerRequest(_ data: Data) -> Data {
        let request: WatchControllerRequestV1
        do {
            request = try WatchControllerRequestV1.decode(data)
        } catch {
            return encodedControllerResponse(
                WatchControllerResponseV1(
                    requestID: UUID(),
                    accepted: false,
                    errorCode: "invalid_request"
                )
            )
        }
        do {
            switch request.operation {
            case .proveEnrollment:
                guard let credential = request.credential,
                      let challenge = request.challenge else {
                    throw WatchControllerContractError.invalidEnvelope
                }
                try controllerCredentialStore.stage(credential)
                let proof = try WatchControllerCryptographyV1.enrollmentProof(
                    credential: credential,
                    challenge: challenge
                )
                return encodedControllerResponse(
                    WatchControllerResponseV1(
                        requestID: request.requestID,
                        accepted: true,
                        proof: proof
                    )
                )
            case .promote:
                try controllerCredentialStore.promote(
                    deviceID: request.deviceID,
                    controllerID: request.controllerID
                )
                onControllerCredentialsChanged?()
            case .revoke:
                try controllerCredentialStore.revoke(
                    deviceID: request.deviceID,
                    controllerID: request.controllerID
                )
                onControllerCredentialsChanged?()
            }
            return encodedControllerResponse(
                WatchControllerResponseV1(
                    requestID: request.requestID,
                    accepted: true
                )
            )
        } catch {
            return encodedControllerResponse(
                WatchControllerResponseV1(
                    requestID: request.requestID,
                    accepted: false,
                    errorCode: "credential_store"
                )
            )
        }
    }

    private func encodedControllerResponse(
        _ response: WatchControllerResponseV1
    ) -> Data {
        (try? response.encoded()) ?? Data()
    }

    private func acknowledge(
        _ identity: WatchRouteIdentityV1,
        status: WatchRouteSyncStatusV1,
        error: String? = nil
    ) {
        guard let session,
              session.activationState == .activated else { return }
        session.transferUserInfo(
            WatchRouteSyncMessageV1(
                operation: .acknowledge,
                identity: identity,
                status: status,
                errorCode: error
            ).propertyList
        )
    }

    private static func errorCode(for error: Error) -> String {
        switch error {
        case WatchRouteLibraryError.metadataMismatch:
            "metadata_mismatch"
        case NavigationRouteFileStoreError.capacityExceeded:
            "capacity"
        case NavigationRouteFileStoreError.staleRevision:
            "stale_revision"
        case NavigationRouteFileStoreError.revisionConflict:
            "revision_conflict"
        case NavigationRouteFileStoreError.notFound:
            "not_found"
        case NavigationRouteFileStoreError.ioFailure:
            "storage_io"
        case NavigationRouteArchiveError.expired:
            "expired"
        case NavigationRouteArchiveError.hashMismatch:
            "hash_mismatch"
        default:
            "invalid_archive"
        }
    }
}

extension WatchConnectivityCoordinator: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.activationDidComplete(activationState, error: error)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            replyHandler(self.receiveControllerRequest(messageData))
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            self?.onApplicationContext?(applicationContext)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceive file: WCSessionFile
    ) {
        // WCSession owns this temporary URL only for the callback duration.
        guard let metadata = file.metadata,
              let resourceBytes = try? file.fileURL.resourceValues(
                forKeys: [.fileSizeKey]
              ).fileSize,
              resourceBytes > 0,
              resourceBytes <= 4 * 1_024 * 1_024 else { return }
        let data = try? Data(contentsOf: file.fileURL)
        Task { @MainActor [weak self] in
            guard let request = WatchRouteSyncMessageV1(
                propertyList: metadata
            ), request.operation == .install,
               request.encodedByteCount == resourceBytes else { return }
            self?.receiveRouteFile(data: data, request: request)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            self?.receiveUserInfo(userInfo)
        }
    }
}
