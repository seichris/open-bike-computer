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
    var onDirectRidePreparationSubmissionFailure:
        ((WatchDirectRidePreparationRequestV1) -> Void)?
    var onDirectRidePreparationAvailabilityChanged: (() -> Void)?

    private let session: WCSession?
    private let routeLibrary: WatchRouteLibrary
    private let controllerCredentialStore: WatchControllerCredentialStore
    private let defaults: UserDefaults
    private var hasActivated = false
    private var workoutHealthSetupSnapshot:
        WorkoutHealthSetupSnapshotV1?
    private let pendingTransportDiagnosticsKey =
        "watchConnectivity.pendingBLETransportDiagnostics.v1"
    private let inFlightTransportDiagnosticsKey =
        "watchConnectivity.inFlightBLETransportDiagnostics.v1"

    init(
        routeLibrary: WatchRouteLibrary,
        controllerCredentialStore: WatchControllerCredentialStore,
        defaults: UserDefaults = .standard,
        session: WCSession? = WCSession.isSupported() ? .default : nil
    ) {
        self.routeLibrary = routeLibrary
        self.controllerCredentialStore = controllerCredentialStore
        self.defaults = defaults
        self.session = session
        super.init()
    }

    func activate() {
        guard let session else { return }
        if hasActivated {
            if session.activationState == .activated {
                flushPendingTransportDiagnostics(using: session)
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

    func recordTransportDiagnostic(
        _ event: WatchBLETransportDiagnosticEventV1
    ) {
        let existing = defaults.data(
            forKey: pendingTransportDiagnosticsKey
        ).flatMap {
            WatchBLETransportDiagnosticBatchV1.decode($0)?.events
        } ?? []
        let batch = WatchBLETransportDiagnosticBatchV1(
            events: existing + [event]
        )
        if let data = try? batch.encoded() {
            defaults.set(data, forKey: pendingTransportDiagnosticsKey)
        }
        guard let session else { return }
        flushPendingTransportDiagnostics(using: session)
    }

    func sendDirectRidePreparation(
        operation: WatchDirectRidePreparationOperationV1,
        deviceID: String,
        preparationID: UUID
    ) -> WatchDirectRidePreparationSubmissionDispositionV1 {
        guard let intent = try? WatchDirectRidePreparationIntentV1(
            preparationID: preparationID,
            operation: operation,
            deviceID: deviceID
        ), let request = try? intent.request(),
              let payload = try? request.encoded() else {
            return .encodingFailed
        }
        guard let session else { return .transportUnavailable }

        if operation == .release {
            // Admit releases into a local outbox even before WCSession has
            // activated. Once handed to transferUserInfo, WatchConnectivity
            // owns the durable delivery across temporary unreachability.
            enqueuePendingDirectRideRelease(payload)
            flushPendingDirectRideReleases(using: session)
            return .submitted
        }
        guard session.activationState == .activated else {
            return .activationPending
        }
        guard session.isReachable else { return .counterpartUnreachable }
        session.sendMessageData(payload) { [weak self] responseData in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let response = try?
                        WatchDirectRidePreparationResponseV1.decode(
                            responseData
                        ), response.requestID == request.requestID else {
                    self.onDirectRidePreparationSubmissionFailure?(request)
                    return
                }
                self.onDirectRidePreparationResponse?(request, response)
            }
        } errorHandler: { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onDirectRidePreparationSubmissionFailure?(request)
            }
        }
        return .submitted
    }

    fileprivate func activationDidComplete(
        _ state: WCSessionActivationState,
        error: Error?
    ) {
        onDirectRidePreparationAvailabilityChanged?()
        guard error == nil, state == .activated, let session else { return }
        flushPendingDirectRideReleases(using: session)
        flushPendingTransportDiagnostics(using: session)
        publishDeviceMetadata(using: session)
        onApplicationContext?(session.receivedApplicationContext)
    }

    fileprivate func reachabilityDidChange() {
        onDirectRidePreparationAvailabilityChanged?()
        if let session {
            flushPendingTransportDiagnostics(using: session)
        }
    }

    private let pendingDirectRideReleaseKey =
        "watchConnectivity.pendingDirectRideReleases.v1"

    private func enqueuePendingDirectRideRelease(_ payload: Data) {
        var pending = defaults.array(
            forKey: pendingDirectRideReleaseKey
        ) as? [Data] ?? []
        let incoming = try? WatchDirectRidePreparationRequestV1.decode(payload)
        pending.removeAll { existing in
            guard let incoming,
                  let decoded = try?
                    WatchDirectRidePreparationRequestV1.decode(existing) else {
                return false
            }
            return decoded.operation == .release &&
                decoded.deviceID == incoming.deviceID &&
                decoded.preparationID == incoming.preparationID
        }
        pending.append(payload)
        if pending.count > 16 {
            pending.removeFirst(pending.count - 16)
        }
        defaults.set(pending, forKey: pendingDirectRideReleaseKey)
    }

    private func flushPendingDirectRideReleases(using session: WCSession) {
        guard session.activationState == .activated else { return }
        let pending = defaults.array(
            forKey: pendingDirectRideReleaseKey
        ) as? [Data] ?? []
        guard !pending.isEmpty else { return }
        for payload in pending {
            session.transferUserInfo([
                WatchDirectRidePreparationRequestV1.userInfoPayloadKey:
                    payload,
            ])
        }
        defaults.removeObject(forKey: pendingDirectRideReleaseKey)
    }

    private func flushPendingTransportDiagnostics(using session: WCSession) {
        guard session.activationState == .activated else { return }
        reconcileTransportDiagnosticsInFlight(using: session)
        guard defaults.data(forKey: inFlightTransportDiagnosticsKey) == nil,
              let data = defaults.data(
                forKey: pendingTransportDiagnosticsKey
              ),
              WatchBLETransportDiagnosticBatchV1.decode(data) != nil else {
            return
        }
        defaults.set(data, forKey: inFlightTransportDiagnosticsKey)
        defaults.removeObject(forKey: pendingTransportDiagnosticsKey)
        session.transferUserInfo([
            WatchBLETransportDiagnosticBatchV1.userInfoPayloadKey: data,
        ])
    }

    private func reconcileTransportDiagnosticsInFlight(
        using session: WCSession
    ) {
        let outstandingData = session.outstandingUserInfoTransfers
            .compactMap {
                $0.userInfo[
                    WatchBLETransportDiagnosticBatchV1.userInfoPayloadKey
                ] as? Data
            }
            .first(where: {
                WatchBLETransportDiagnosticBatchV1.decode($0) != nil
            })
        if let outstandingData {
            defaults.set(
                outstandingData,
                forKey: inFlightTransportDiagnosticsKey
            )
            return
        }
        guard let abandoned = defaults.data(
            forKey: inFlightTransportDiagnosticsKey
        ) else { return }
        defaults.removeObject(forKey: inFlightTransportDiagnosticsKey)
        mergePendingTransportDiagnostics(abandoned)
    }

    private func transportDiagnosticsDidFinish(
        data: Data,
        error: Error?
    ) {
        if defaults.data(forKey: inFlightTransportDiagnosticsKey) == data {
            defaults.removeObject(forKey: inFlightTransportDiagnosticsKey)
        }
        if error != nil {
            mergePendingTransportDiagnostics(data)
            return
        }
        guard let session else { return }
        flushPendingTransportDiagnostics(using: session)
    }

    private func mergePendingTransportDiagnostics(_ data: Data) {
        guard let incoming = WatchBLETransportDiagnosticBatchV1.decode(data)
        else { return }
        let pending = defaults.data(
            forKey: pendingTransportDiagnosticsKey
        ).flatMap {
            WatchBLETransportDiagnosticBatchV1.decode($0)?.events
        } ?? []
        var seen = Set<String>()
        let merged = (incoming.events + pending).filter { event in
            seen.insert("\(event.attemptID.uuidString):\(event.sequence)")
                .inserted
        }
        guard let encoded = try? WatchBLETransportDiagnosticBatchV1(
            events: merged
        ).encoded() else { return }
        defaults.set(encoded, forKey: pendingTransportDiagnosticsKey)
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

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.reachabilityDidChange()
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

    nonisolated func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: Error?
    ) {
        guard let data = userInfoTransfer.userInfo[
            WatchBLETransportDiagnosticBatchV1.userInfoPayloadKey
        ] as? Data else { return }
        Task { @MainActor [weak self] in
            self?.transportDiagnosticsDidFinish(data: data, error: error)
        }
    }
}
