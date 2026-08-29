import Foundation
import WatchConnectivity
import WatchKit

/// The sole production owner of `WCSession.default` on Apple Watch.
@MainActor
final class WatchConnectivityCoordinator: NSObject {
    var onApplicationContext: (([String: Any]) -> Void)?
    var onControllerCredentialsChanged: (() -> Void)?
    var onDirectRidePreparationResponse:
        ((WatchDirectRidePreparationRequestV1,
          WatchDirectRidePreparationResponseV1) -> Void)?

    private let session: WCSession?
    private let routeLibrary: WatchRouteLibrary
    private let controllerCredentialStore: WatchControllerCredentialStore
    private var hasActivated = false
    private var workoutHealthSetupSnapshot:
        WorkoutHealthSetupSnapshotV1?

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

    func publishWorkoutHealthSetup(
        _ snapshot: WorkoutHealthSetupSnapshotV1
    ) {
        workoutHealthSetupSnapshot = snapshot
        guard let session,
              session.activationState == .activated else { return }
        publishDeviceMetadata(using: session)
    }

    func sendDirectRidePreparation(
        operation: WatchDirectRidePreparationOperationV1,
        deviceID: String,
        preparationID: UUID
    ) {
        guard let session,
              session.activationState == .activated,
              let request = try? WatchDirectRidePreparationRequestV1(
                preparationID: preparationID,
                operation: operation,
                deviceID: deviceID
              ),
              let payload = try? request.encoded() else { return }

        if operation == .release {
            // The release is idempotent and durable so an iPhone that was
            // temporarily unreachable can resume its prior reconnect policy.
            session.transferUserInfo([
                WatchDirectRidePreparationRequestV1.userInfoPayloadKey:
                    payload,
            ])
        }
        guard session.isReachable else { return }
        session.sendMessageData(payload) { [weak self] responseData in
            guard let response = try?
                    WatchDirectRidePreparationResponseV1.decode(responseData),
                  response.requestID == request.requestID else { return }
            Task { @MainActor [weak self] in
                self?.onDirectRidePreparationResponse?(request, response)
            }
        } errorHandler: { _ in
            // The firmware lease remains authoritative when the iPhone is
            // absent, and release also has the queued fallback above.
        }
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
        if let workoutHealthSetupSnapshot,
           let healthData = try? workoutHealthSetupSnapshot.encoded() {
            merged[WorkoutHealthSetupSnapshotV1.applicationContextKey] =
                healthData
        }
        try? session.updateApplicationContext(merged)
    }

    fileprivate func receiveRouteFile(
        data: Data?,
        request: WatchRouteSyncMessageV1
    ) {
        let response = routeInstallResponse(data: data, request: request)
        acknowledge(response)
    }

    fileprivate func routeInstallResponse(
        data: Data?,
        request: WatchRouteSyncMessageV1
    ) -> WatchRouteSyncMessageV1 {
        guard let data else {
            return routeAcknowledgement(
                request.identity,
                status: .rejected,
                error: "file_read"
            )
        }
        guard request.encodedByteCount == data.count else {
            return routeAcknowledgement(
                request.identity,
                status: .rejected,
                error: "byte_count"
            )
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
                return routeAcknowledgement(
                    request.identity,
                    status: .rejected,
                    error: "retention_mismatch"
                )
            }
            let result = try routeLibrary.install(
                data,
                expectedIdentity: request.identity
            )
            for evictedIdentity in result.evictedIdentities {
                acknowledge(evictedIdentity, status: .evicted)
            }
            return routeAcknowledgement(request.identity, status: .ready)
        } catch {
            let code = Self.errorCode(for: error)
            routeLibrary.reportSyncError(code)
            return routeAcknowledgement(
                request.identity,
                status: .rejected,
                error: code
            )
        }
    }

    fileprivate func routeFileInstallResponse(
        resourceByteCount: Int?,
        data: Data?,
        request: WatchRouteSyncMessageV1
    ) -> WatchRouteSyncMessageV1 {
        switch WatchRouteFilePayloadV1.validate(
            request: request,
            resourceByteCount: resourceByteCount,
            data: data
        ) {
        case .success(let validatedData):
            routeInstallResponse(data: validatedData, request: request)
        case .failure(let error):
            routeAcknowledgement(
                request.identity,
                status: .rejected,
                error: error.rawValue
            )
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
        acknowledge(routeAcknowledgement(
            identity,
            status: status,
            error: error
        ))
    }

    private func acknowledge(_ message: WatchRouteSyncMessageV1) {
        guard let session,
              session.activationState == .activated else { return }
        session.transferUserInfo(message.propertyList)
    }

    private func routeAcknowledgement(
        _ identity: WatchRouteIdentityV1,
        status: WatchRouteSyncStatusV1,
        error: String? = nil
    ) -> WatchRouteSyncMessageV1 {
        WatchRouteSyncMessageV1(
            operation: .acknowledge,
            identity: identity,
            status: status,
            errorCode: error
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
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let immediate = WatchRouteImmediateTransferV1.decode(
            message
        ) else {
            replyHandler([:])
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                replyHandler([:])
                return
            }
            replyHandler(self.routeInstallResponse(
                data: immediate.archiveData,
                request: immediate.install
            ).propertyList)
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
              let request = WatchRouteSyncMessageV1(
                propertyList: metadata
              ), request.operation == .install else { return }
        let resourceBytes = try? file.fileURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize
        let data: Data? = if let resourceBytes,
            resourceBytes > 0,
            resourceBytes <=
                NavigationRouteLimitsV1.production.maximumEncodedBytes {
            try? Data(contentsOf: file.fileURL)
        } else {
            nil
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.acknowledge(self.routeFileInstallResponse(
                resourceByteCount: resourceBytes,
                data: data,
                request: request
            ))
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
