import Combine
import Foundation
import WatchConnectivity

/// The sole production owner of `WCSession.default` on iPhone.
///
/// Application-context fields are merged so independently evolving features
/// cannot erase each other's state. Route files and deletion commands use the
/// queued WatchConnectivity APIs and therefore do not require reachability.
@MainActor
final class PhoneWatchConnectivityCoordinator: NSObject, ObservableObject,
    PhoneWatchControllerTransporting, WorkoutWatchConnectivityCoordinating {
    @Published private(set) var state: PhoneWatchConnectivityStateV1
    @Published private(set) var workoutHealthSetupSnapshot:
        WorkoutHealthSetupSnapshotV1?

    @Published private(set) var cyclingSensorObservation:
        WatchCyclingSensorObservationV1?

    var onRouteAcknowledgement: ((WatchRouteSyncMessageV1) -> Void)?
    var onDirectRidePreparationRequest:
        ((WatchDirectRidePreparationRequestV1) ->
            WatchDirectRidePreparationResponseV1)?
    weak var diagnosticsRecorder: RideDiagnosticsRecorder?

    private let session: WCSession?
    private let defaults: UserDefaults
    private var hasActivated = false
    private var intentionallyCancelledRouteTransferIDs =
        Set<ObjectIdentifier>()
    private var pendingControllerRevocations: [WatchControllerRequestV1] = []
    private var pendingDirectRideReconciliations:
        [WatchDirectRideReconciliationRequestV1] = []
    private var directRideReconciliationRetryTask: Task<Void, Never>?
    private var coordinateFavoritesEnvelope: CoordinateFavoritesEnvelopeV1?
    private var routeDisplayNamesEnvelope:
        WatchRouteDisplayNamesEnvelopeV1?
    private var selectedBikeComputerEnvelope:
        WatchSelectedBikeComputerV1?
    private static let pendingControllerRevocationsDefaultsKey =
        "watchController.pendingRevocations.v1"
    private static let pendingDirectRideReconciliationsDefaultsKey =
        "watchDirectRide.pendingReconciliations.v1"
    private static let inFlightDirectRideReconciliationsDefaultsKey =
        "watchDirectRide.inFlightReconciliations.v1"
    private static let coordinateFavoritesDefaultsKey =
        "watchNavigation.coordinateFavoritesEnvelope.v1"
    private static let routeDisplayNamesDefaultsKey =
        "watchNavigation.routeDisplayNamesEnvelope.v1"
    private static let selectedBikeComputerDefaultsKey =
        "watchNavigation.selectedBikeComputerEnvelope.v1"
    private static let receivedTransportDiagnosticIDsDefaultsKey =
        "watchBLETransportDiagnostics.receivedIDs.v1"

    var workoutState: WorkoutWatchConnectivityStateV1 {
        WorkoutWatchConnectivityStateV1(
            isSupported: state.isSupported,
            isActivated: state.isActivated,
            activationFailed: state.activationFailed,
            isPaired: state.isPaired,
            isWatchAppInstalled: state.isWatchAppInstalled,
            isReachable: state.isReachable,
            healthSetupSnapshot: workoutHealthSetupSnapshot
        )
    }

    var workoutStatePublisher:
        AnyPublisher<WorkoutWatchConnectivityStateV1, Never> {
        Publishers.CombineLatest($state, $workoutHealthSetupSnapshot)
            .map { state, healthSetupSnapshot in
                WorkoutWatchConnectivityStateV1(
                    isSupported: state.isSupported,
                    isActivated: state.isActivated,
                    activationFailed: state.activationFailed,
                    isPaired: state.isPaired,
                    isWatchAppInstalled: state.isWatchAppInstalled,
                    isReachable: state.isReachable,
                    healthSetupSnapshot: healthSetupSnapshot
                )
            }
            .eraseToAnyPublisher()
    }

    override convenience init() {
        self.init(
            session: WCSession.isSupported() ? .default : nil,
            defaults: .standard
        )
    }

    init(session: WCSession?, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
        workoutHealthSetupSnapshot = nil
        state = PhoneWatchConnectivityStateV1(
            isSupported: session != nil
        )
        super.init()
        loadPendingControllerRevocations()
        loadPendingDirectRideReconciliations()
        if let data = defaults.data(
            forKey: Self.coordinateFavoritesDefaultsKey
        ) {
            coordinateFavoritesEnvelope = try?
                CoordinateFavoritesEnvelopeV1.decode(data)
        }
        if let data = defaults.data(
            forKey: Self.routeDisplayNamesDefaultsKey
        ) {
            routeDisplayNamesEnvelope = try?
                WatchRouteDisplayNamesEnvelopeV1.decode(data)
        }
        if let data = defaults.data(
            forKey: Self.selectedBikeComputerDefaultsKey
        ) {
            selectedBikeComputerEnvelope = try?
                WatchSelectedBikeComputerV1.decode(data)
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

    func updateApplicationContextMerging(
        _ fields: [String: Any],
        removingKeys: Set<String> = []
    ) throws {
        guard let session else { return }
        var merged = session.applicationContext
        for key in removingKeys {
            merged.removeValue(forKey: key)
        }
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

    func updateRouteDisplayNames(
        _ entries: [WatchRouteDisplayNameV1]
    ) throws {
        let normalized = try WatchRouteDisplayNamesEnvelopeV1(
            revision: routeDisplayNamesEnvelope?.revision ?? 1,
            entries: entries
        ).entries
        if routeDisplayNamesEnvelope?.entries == normalized,
           let envelope = routeDisplayNamesEnvelope {
            try publishRouteDisplayNames(envelope)
            return
        }
        let revision: UInt64
        if let current = routeDisplayNamesEnvelope?.revision {
            guard current < UInt64.max else {
                throw WatchRouteDisplayNameContractErrorV1.invalidRevision
            }
            revision = current + 1
        } else {
            revision = 1
        }
        let envelope = try WatchRouteDisplayNamesEnvelopeV1(
            revision: revision,
            entries: normalized
        )
        let data = try envelope.encoded()
        routeDisplayNamesEnvelope = envelope
        defaults.set(data, forKey: Self.routeDisplayNamesDefaultsKey)
        try publishRouteDisplayNames(envelope)
    }

    private func publishRouteDisplayNames(
        _ envelope: WatchRouteDisplayNamesEnvelopeV1
    ) throws {
        try updateApplicationContextMerging([
            WatchRouteDisplayNamesEnvelopeV1.applicationContextKey:
                try envelope.encoded(),
        ])
    }

    func updateSelectedBikeComputer(deviceID: String?) throws {
        let normalizedDeviceID: String?
        if let deviceID,
           deviceID.count == 32,
           deviceID.utf8.allSatisfy({
               ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) ||
                   ($0 >= 97 && $0 <= 102)
           }) {
            normalizedDeviceID = deviceID.lowercased()
        } else {
            // Legacy peripherals have no ownership-v2 Watch credential and
            // are deliberately represented by the explicit no-selection
            // tombstone.
            normalizedDeviceID = nil
        }
        if selectedBikeComputerEnvelope?.deviceID == normalizedDeviceID,
           let envelope = selectedBikeComputerEnvelope {
            try publishSelectedBikeComputer(envelope)
            return
        }
        let revision: UInt64
        if let current = selectedBikeComputerEnvelope?.revision {
            guard current < UInt64.max else {
                throw WatchControllerContractError.invalidEnvelope
            }
            revision = current + 1
        } else {
            revision = 1
        }
        let envelope = try WatchSelectedBikeComputerV1(
            revision: revision,
            deviceID: normalizedDeviceID
        )
        let data = try envelope.encoded()
        selectedBikeComputerEnvelope = envelope
        defaults.set(data, forKey: Self.selectedBikeComputerDefaultsKey)
        try publishSelectedBikeComputer(envelope)
    }

    private func publishSelectedBikeComputer(
        _ envelope: WatchSelectedBikeComputerV1
    ) throws {
        try updateApplicationContextMerging([
            WatchSelectedBikeComputerV1.applicationContextKey:
                try envelope.encoded(),
        ])
    }

    @discardableResult
    private func receiveTransportDiagnostics(
        _ userInfo: [String: Any]
    ) -> Bool {
        guard let data = userInfo[
            WatchBLETransportDiagnosticBatchV1.userInfoPayloadKey
        ] as? Data else { return false }
        guard let batch = WatchBLETransportDiagnosticBatchV1.decode(data) else {
            diagnosticsRecorder?.record(
                level: .warning,
                category: .ble,
                event: "watch_ble_diagnostics_rejected",
                fields: ["origin": "watch", "reason": "malformed"]
            )
            return true
        }
        let storedReceived = defaults.stringArray(
            forKey: Self.receivedTransportDiagnosticIDsDefaultsKey
        ) ?? []
        var received: [String] = []
        var receivedSet = Set<String>()
        for eventID in storedReceived.suffix(512)
            where receivedSet.insert(eventID).inserted {
            received.append(eventID)
        }
        for event in batch.events {
            let eventID = "\(event.attemptID.uuidString):\(event.sequence)"
            guard receivedSet.insert(eventID).inserted else { continue }
            received.append(eventID)
            var fields: [String: String] = [
                "origin": "watch",
                "controllerRole": "scoped_watch",
                "attemptId": event.attemptID.uuidString,
                "watchSequence": String(event.sequence),
                "watchUptimeMs": String(event.uptimeMs),
                "connectionGeneration":
                    String(event.connectionGeneration),
                "phase": event.phase,
                "queueDepth": String(event.queueDepth),
                "highWater": String(event.queueHighWater),
                "replacedCount": String(event.replacedGroups),
                "rejectedCount": String(event.rejectedGroups),
            ]
            if let queueBytes = event.queueBytes {
                fields["queueBytes"] = String(queueBytes)
            }
            if let queueHighWaterBytes = event.queueHighWaterBytes {
                fields["highWaterBytes"] = String(queueHighWaterBytes)
            }
            if let reason = event.reason { fields["reason"] = reason }
            if let latencyMs = event.latencyMs {
                fields["latencyMs"] = String(latencyMs)
            }
            let warningKinds: Set<WatchBLETransportDiagnosticKindV1> = [
                .attTimeout, .applicationTimeout, .recovery,
            ]
            diagnosticsRecorder?.record(
                level: warningKinds.contains(event.kind)
                    ? .warning : .info,
                category: .ble,
                event: "watch_ble_\(event.kind.rawValue)",
                fields: fields
            )
        }
        received = Array(received.suffix(512))
        defaults.set(
            received,
            forKey: Self.receivedTransportDiagnosticIDsDefaultsKey
        )
        return true
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

    nonisolated func queueWatchDirectRideReconciliation(
        _ request: WatchDirectRideReconciliationRequestV1
    ) {
        Task { @MainActor [weak self] in
            guard let self, (try? request.validated()) != nil else { return }
            self.pendingDirectRideReconciliations.removeAll {
                $0.deviceID == request.deviceID &&
                    $0.preparationID == request.preparationID
            }
            self.pendingDirectRideReconciliations.append(request)
            if self.pendingDirectRideReconciliations.count > 16 {
                self.pendingDirectRideReconciliations.removeFirst(
                    self.pendingDirectRideReconciliations.count - 16
                )
            }
            self.persistPendingDirectRideReconciliations()
            self.flushPendingDirectRideReconciliations()
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

    private func loadPendingDirectRideReconciliations() {
        guard let data = defaults.data(
            forKey: Self.pendingDirectRideReconciliationsDefaultsKey
        ), let requests = try? PropertyListDecoder().decode(
            [WatchDirectRideReconciliationRequestV1].self,
            from: data
        ) else { return }
        pendingDirectRideReconciliations = requests.filter {
            (try? $0.validated()) != nil
        }
    }

    private func persistPendingDirectRideReconciliations() {
        if pendingDirectRideReconciliations.isEmpty {
            defaults.removeObject(
                forKey: Self.pendingDirectRideReconciliationsDefaultsKey
            )
            return
        }
        guard let data = try? PropertyListEncoder().encode(
            pendingDirectRideReconciliations
        ) else { return }
        defaults.set(
            data,
            forKey: Self.pendingDirectRideReconciliationsDefaultsKey
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

    private func flushPendingDirectRideReconciliations() {
        guard let session,
              session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else { return }
        reconcileDirectRideReconciliationsInFlight(using: session)
        let inFlight = defaults.array(
            forKey: Self.inFlightDirectRideReconciliationsDefaultsKey
        ) as? [Data] ?? []
        guard inFlight.isEmpty else { return }
        let queued = pendingDirectRideReconciliations.compactMap { request in
            (try? request.encoded()).map { (request, $0) }
        }
        guard !queued.isEmpty else { return }
        let queuedRequestIDs = Set(queued.map { $0.0.requestID })
        let queuedPayloads = queued.map { $0.1 }
        defaults.set(
            queuedPayloads,
            forKey: Self.inFlightDirectRideReconciliationsDefaultsKey
        )
        pendingDirectRideReconciliations.removeAll {
            queuedRequestIDs.contains($0.requestID)
        }
        persistPendingDirectRideReconciliations()
        for (_, payload) in queued {
            let message = [
                WatchDirectRideReconciliationRequestV1.userInfoPayloadKey:
                    payload,
            ]
            session.transferUserInfo(message)
            if session.isReachable {
                session.sendMessage(
                    message,
                    replyHandler: nil,
                    errorHandler: nil
                )
            }
        }
    }

    private func reconcileDirectRideReconciliationsInFlight(
        using session: WCSession
    ) {
        let outstanding = session.outstandingUserInfoTransfers.compactMap {
            $0.userInfo[
                WatchDirectRideReconciliationRequestV1.userInfoPayloadKey
            ] as? Data
        }.filter {
            (try? WatchDirectRideReconciliationRequestV1.decode($0)) != nil
        }
        let recorded = defaults.array(
            forKey: Self.inFlightDirectRideReconciliationsDefaultsKey
        ) as? [Data] ?? []
        for abandoned in recorded where !outstanding.contains(abandoned) {
            requeueDirectRideReconciliation(abandoned)
        }
        if outstanding.isEmpty {
            defaults.removeObject(
                forKey: Self.inFlightDirectRideReconciliationsDefaultsKey
            )
        } else {
            defaults.set(
                outstanding,
                forKey: Self.inFlightDirectRideReconciliationsDefaultsKey
            )
        }
    }

    private func directRideReconciliationDidFinish(
        data: Data,
        error: Error?
    ) {
        var inFlight = defaults.array(
            forKey: Self.inFlightDirectRideReconciliationsDefaultsKey
        ) as? [Data] ?? []
        if let index = inFlight.firstIndex(of: data) {
            inFlight.remove(at: index)
        }
        if inFlight.isEmpty {
            defaults.removeObject(
                forKey: Self.inFlightDirectRideReconciliationsDefaultsKey
            )
        } else {
            defaults.set(
                inFlight,
                forKey: Self.inFlightDirectRideReconciliationsDefaultsKey
            )
        }
        if error != nil {
            requeueDirectRideReconciliation(data)
            scheduleDirectRideReconciliationRetry()
            return
        }
        guard inFlight.isEmpty else { return }
        flushPendingDirectRideReconciliations()
    }

    private func requeueDirectRideReconciliation(_ data: Data) {
        guard let request = try?
                WatchDirectRideReconciliationRequestV1.decode(data) else {
            return
        }
        pendingDirectRideReconciliations.removeAll {
            $0.deviceID == request.deviceID &&
                $0.preparationID == request.preparationID
        }
        pendingDirectRideReconciliations.append(request)
        persistPendingDirectRideReconciliations()
    }

    private func scheduleDirectRideReconciliationRetry() {
        guard directRideReconciliationRetryTask == nil else { return }
        directRideReconciliationRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            self.directRideReconciliationRetryTask = nil
            self.flushPendingDirectRideReconciliations()
        }
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
    func cancelRouteTransfers(
        _ identity: WatchRouteIdentityV1
    ) -> Int {
        guard let session else { return 0 }
        let matchingTransfers = session.outstandingFileTransfers.filter {
            WatchRouteSyncMessageV1.isInstallTransfer(
                $0.file.metadata,
                matching: identity
            )
        }
        matchingTransfers.forEach {
            intentionallyCancelledRouteTransferIDs.insert(
                ObjectIdentifier($0)
            )
            $0.cancel()
        }
        return matchingTransfers.count
    }

    /// Attempts the high-priority route path while Watch is reachable. The
    /// caller always queues `transferRoute` first so a failed live message
    /// still has a durable background fallback.
    @discardableResult
    func sendRouteImmediately(
        _ record: InstalledNavigationRouteV1
    ) -> Bool {
        guard let session,
              session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled,
              session.isReachable,
              record.encodedSize <=
                WatchRouteImmediateTransferV1.maximumEncodedByteCount,
              let archiveData = try? Data(contentsOf: record.fileURL) else {
            return false
        }
        let install = WatchRouteSyncMessageV1(
            operation: .install,
            identity: WatchRouteIdentityV1(archive: record.archive),
            encodedByteCount: record.encodedSize,
            deleteAfter: record.archive.deleteAfter
        )
        guard let message = WatchRouteImmediateTransferV1.message(
            install: install,
            archiveData: archiveData
        ) else { return false }
        session.sendMessage(message) { [weak self] response in
            Task { @MainActor [weak self] in
                self?.receiveAcknowledgement(response)
            }
        } errorHandler: { _ in
            // The already-queued file transfer remains the durable fallback.
        }
        return true
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
            workoutHealthSetupSnapshot = nil
            cyclingSensorObservation = nil
            state = PhoneWatchConnectivityStateV1()
            return
        }
        let activated = session.activationState == .activated
        let paired = activated && session.isPaired
        let watchAppInstalled = paired && session.isWatchAppInstalled
        // Read the latest context on activation as well as delivery. A phone
        // launched after the sensor started must not wait for another packet.
        if watchAppInstalled,
           let data = session.receivedApplicationContext[
               WatchCyclingSensorObservationV1.applicationContextKey
           ] as? Data {
            cyclingSensorObservation = try?
                WatchCyclingSensorObservationV1.decode(data)
        } else {
            cyclingSensorObservation = nil
        }
        let watchMetadata: WatchDeviceMetadataV1?
        if watchAppInstalled,
           let data = session.receivedApplicationContext[
               WatchDeviceMetadataV1.applicationContextKey
           ] as? Data {
            watchMetadata = try? WatchDeviceMetadataV1.decode(data)
        } else {
            watchMetadata = nil
        }
        if paired,
           let data = session.receivedApplicationContext[
               WorkoutHealthSetupSnapshotV1.applicationContextKey
           ] as? Data {
            workoutHealthSetupSnapshot = try?
                WorkoutHealthSetupSnapshotV1.decode(data)
        } else {
            workoutHealthSetupSnapshot = nil
        }
        state = PhoneWatchConnectivityStateV1(
            isSupported: true,
            isActivated: activated,
            activationFailed: activationFailed ?? state.activationFailed,
            isPaired: paired,
            isWatchAppInstalled: watchAppInstalled,
            isReachable: activated && session.isReachable,
            watchMetadata: watchMetadata
        )
        if activated {
            flushPendingControllerRevocations()
            flushPendingDirectRideReconciliations()
            if let coordinateFavoritesEnvelope {
                try? publishCoordinateFavorites(coordinateFavoritesEnvelope)
            }
            if let routeDisplayNamesEnvelope {
                try? publishRouteDisplayNames(routeDisplayNamesEnvelope)
            }
            if let selectedBikeComputerEnvelope {
                try? publishSelectedBikeComputer(
                    selectedBikeComputerEnvelope
                )
            }
        }
    }

    fileprivate func receiveAcknowledgement(_ userInfo: [String: Any]) {
        if let payload = userInfo[
            WatchDirectRidePreparationRequestV1.userInfoPayloadKey
        ] as? Data {
            _ = receiveDirectRidePreparationRequest(payload)
            return
        }
        guard let message = WatchRouteSyncMessageV1(propertyList: userInfo),
              message.operation == .acknowledge,
              message.status != nil else {
            return
        }
        onRouteAcknowledgement?(message)
    }

    fileprivate func receiveDirectRidePreparationRequest(
        _ data: Data
    ) -> Data {
        let request: WatchDirectRidePreparationRequestV1
        do {
            request = try WatchDirectRidePreparationRequestV1.decode(data)
        } catch {
            return (try? WatchDirectRidePreparationResponseV1(
                requestID: UUID(),
                accepted: false,
                errorCode: "invalid_request"
            ).encoded()) ?? Data()
        }
        let response = onDirectRidePreparationRequest?(request) ??
            WatchDirectRidePreparationResponseV1(
                requestID: request.requestID,
                accepted: false,
                errorCode: "handler_unavailable"
            )
        guard response.requestID == request.requestID else {
            return (try? WatchDirectRidePreparationResponseV1(
                requestID: request.requestID,
                accepted: false,
                errorCode: "invalid_response"
            ).encoded()) ?? Data()
        }
        return (try? response.encoded()) ?? Data()
    }

    fileprivate func finishFileTransfer(
        _ transfer: WCSessionFileTransfer,
        error: Error?
    ) {
        if intentionallyCancelledRouteTransferIDs.remove(
            ObjectIdentifier(transfer)
        ) != nil {
            return
        }
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
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor [weak self] in self?.refreshState() }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                replyHandler(Data())
                return
            }
            replyHandler(
                self.receiveDirectRidePreparationRequest(messageData)
            )
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.receiveTransportDiagnostics(userInfo) {
                self.receiveAcknowledgement(userInfo)
            }
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

    nonisolated func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: Error?
    ) {
        guard let data = userInfoTransfer.userInfo[
            "watchDirectRideReconciliationRequestV1"
        ] as? Data else { return }
        Task { @MainActor [weak self] in
            self?.directRideReconciliationDidFinish(
                data: data,
                error: error
            )
        }
    }
}
