@preconcurrency import CoreBluetooth
import Combine
import Foundation
import Security

enum WatchDeviceLinkState: Equatable {
    case idle
    case notEnrolled
    case bluetoothUnavailable
    case scanning
    case connecting
    case discovering
    case authenticating
    case claimingLease
    case ready(deviceID: String)
    case busy
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Focused Watch Core Bluetooth central for scoped ride traffic. Administrative
/// ownership remains on iPhone; this link can authenticate only the Watch ride
/// credential, hold the exclusive lease, and write live ride channels.
@MainActor
final class WatchDeviceLink: NSObject, ObservableObject {
    @Published private(set) var state: WatchDeviceLinkState = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var transportPhase:
        RideBLETransportPhaseV1 = .idle
    @Published private(set) var transportFailureReason:
        RideBLETransportFailureReasonV1?
    var onDirectRidePreparationChange:
        ((WatchDirectRidePreparationOperationV1, String, UUID)
            -> WatchDirectRidePreparationSubmissionDispositionV1)?
    var onRideAutomationFrame: ((RideAutomationFrame) -> Void)?
    var onTransportDiagnostic:
        ((WatchBLETransportDiagnosticEventV1) -> Void)?

    private let credentialStore: WatchControllerCredentialStore
    private let defaults: UserDefaults
    private let serviceUUID = CBUUID(
        string: WatchDirectBLEProtocolV1.serviceUUID
    )
    private let authUUID = CBUUID(
        string: WatchDirectBLEProtocolV1.authUUID
    )
    private let navigationUUID = CBUUID(
        string: WatchDirectBLEProtocolV1.navigationUUID
    )
    private let routeUUID = CBUUID(
        string: WatchDirectBLEProtocolV1.routeUUID
    )
    private let gpsUUID = CBUUID(
        string: WatchDirectBLEProtocolV1.gpsUUID
    )
    private let workoutUUID = CBUUID(
        string: WatchDirectBLEProtocolV1.workoutUUID
    )
    private let rideAutomationUUID = CBUUID(
        string: WatchDirectBLEProtocolV1.rideAutomationUUID
    )
    private lazy var central = CBCentralManager(
        delegate: self,
        queue: .main,
        options: [
            CBCentralManagerOptionRestoreIdentifierKey:
                "com.openbikecomputer.watch.direct-ble.v1",
        ]
    )

    private var demand = WatchRideDemandStateV1()
    private var selectedBikeComputerEnvelope:
        WatchSelectedBikeComputerV1?
    private var credentials: [WatchControllerCredentialV1] = []
    private var credential: WatchControllerCredentialV1?
    private var peripheral: CBPeripheral?
    private var authCharacteristic: CBCharacteristic?
    private var navigationCharacteristic: CBCharacteristic?
    private var routeCharacteristic: CBCharacteristic?
    private var gpsCharacteristic: CBCharacteristic?
    private var workoutCharacteristic: CBCharacteristic?
    private var rideAutomationCharacteristic: CBCharacteristic?
    private var authentication: WatchScopedAuthenticationV1?
    private var challenge: WatchScopedAuthenticationChallengeV1?
    private var protectedSession: WatchAuthenticatedBLESessionV1?
    private var capabilities: WatchDeviceCapabilitiesV1?
    private var connectionGeneration: UInt64 = 0
    private var transportAttemptID = UUID()
    private var transportDiagnosticSequence: UInt32 = 0
    private var transportStateMachine = RideBLETransportStateMachineV1(
        role: .scopedWatch
    )
    private var queue = WatchBLEOutboundQueueV1(capacity: 32)
    private var activeWriteGroup: WatchBLEOutboundGroupV1?
    private var activeWriteIndex = 0
    private var pendingApplicationAckGroup: WatchBLEOutboundGroupV1?
    private var bufferedApplicationAcknowledgement:
        RideBLEApplicationAcknowledgementV1?
    private var applicationAckRetryCount = 0
    private var applicationAckWatchdogTask: Task<Void, Never>?
    private var applicationAckStartedAtUptime: TimeInterval?
    private var nextOutboundStateGeneration: UInt32 = 0
    private var writeWithResponseInFlight = false
    private struct PendingATTWrite {
        let writeID: UInt64
        let peripheralID: UUID
        let connectionGeneration: UInt64
        let characteristicID: CBUUID
        let startedAtUptime: TimeInterval
    }
    private var nextWriteID: UInt64 = 0
    private var pendingATTWrite: PendingATTWrite?
    private var writerWatchdogTask: Task<Void, Never>?
    private var withoutResponseWatchdogTask: Task<Void, Never>?
    private var heartbeatTimer: Timer?
    private var reconnectTask: Task<Void, Never>?
    private var operationTimeoutTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var disconnectingForBusyLease = false
    private var gracefulStopPending = false
    private var leaseReleaseAckTask: Task<Void, Never>?
    private var latestWorkoutFrames: WorkoutDeviceFrames?
    private var latestWorkoutGPS: WorkoutDeviceGPSUpdate?
    private var latestWorkoutMotion: WorkoutDeviceMotionUpdate?
    private var workoutPairGeneration: UInt8 = 0
    private var latestLocation: NavigationLocationSampleV1?
    private var latestNavigationSnapshot: NavigationSnapshotV1?
    private var latestRouteWindow = Data()
    private var preparedPhoneDeviceID: String?
    private var preparedPhonePreparationID: UUID?
    private var phonePreparationAccepted = false
    private var phonePreparationSubmissionOutstanding = false
    private var phonePreparationReleasePending = false
    private var phonePreparationAttempt = 0
    private var phonePreparationRetryTask: Task<Void, Never>?
    private var phonePreparationResponseTimeoutTask: Task<Void, Never>?
    private var phonePreparationRestorationGate =
        WatchDirectRidePreparationRestorationGateV1(
            restoredOperation: nil
        )

    private let peripheralMapKey =
        "watchDeviceLink.peripheralByDeviceID.v1"
    private let selectedBikeComputerKey =
        "watchDeviceLink.selectedBikeComputer.v1"
    private let directRidePreparationIntentKey =
        "watchDeviceLink.directRidePreparationIntent.v1"

    init(
        credentialStore: WatchControllerCredentialStore,
        defaults: UserDefaults = .standard
    ) {
        self.credentialStore = credentialStore
        self.defaults = defaults
        if let data = defaults.data(forKey: selectedBikeComputerKey) {
            selectedBikeComputerEnvelope = try?
                WatchSelectedBikeComputerV1.decode(data)
        }
        if let data = defaults.data(forKey: directRidePreparationIntentKey),
           let intent = try?
                WatchDirectRidePreparationIntentV1.decode(data) {
            preparedPhoneDeviceID = intent.deviceID
            preparedPhonePreparationID = intent.preparationID
            phonePreparationReleasePending = intent.operation == .release
            phonePreparationRestorationGate = .init(
                restoredOperation: intent.operation
            )
        }
        super.init()
    }

    func receiveApplicationContext(_ context: [String: Any]) {
        guard let data = context[
            WatchSelectedBikeComputerV1.applicationContextKey
        ] as? Data else { return }
        let incoming: WatchSelectedBikeComputerV1
        do {
            incoming = try WatchSelectedBikeComputerV1.decode(data)
        } catch {
            failClosedSelection("Selected Bike Computer sync is invalid")
            return
        }
        if let current = selectedBikeComputerEnvelope {
            if incoming.revision < current.revision { return }
            if incoming.revision == current.revision {
                guard incoming == current else {
                    failClosedSelection(
                        "Selected Bike Computer sync conflicts"
                    )
                    return
                }
                return
            }
        }

        let previousDeviceID = selectedBikeComputerEnvelope?.deviceID
        selectedBikeComputerEnvelope = incoming
        defaults.set(data, forKey: selectedBikeComputerKey)
        guard previousDeviceID != incoming.deviceID else { return }

        releasePhonePreparationIfNeeded()

        let canRetainReadySession = state.isReady &&
            credential?.deviceID == incoming.deviceID
        if !canRetainReadySession {
            reconnectTask?.cancel()
            reconnectTask = nil
            operationTimeoutTask?.cancel()
            operationTimeoutTask = nil
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
            if state.isReady {
                writeProtectedAuth("LEASE_RELEASE")
            }
            if let peripheral {
                central.cancelPeripheralConnection(peripheral)
            }
            connectionGeneration &+= 1
            resetTransport(keepingPeripheral: false)
        }
        credentials = eligibleCredentials(from: credentials)
        requestPhonePreparationIfNeeded()
        guard hasDemand else {
            if !canRetainReadySession { state = .idle }
            return
        }
        guard !canRetainReadySession else { return }
        state = .idle
        beginIfNeeded()
    }

    func setDemand(navigation: Bool, workout: Bool) {
        demand.setNavigationActive(navigation)
        demand.setWorkoutActive(workout)
        reconcileDemand()
    }

    func setNavigationDemand(_ active: Bool) {
        demand.setNavigationActive(active)
        reconcileDemand()
    }

    func setWorkoutDemand(_ active: Bool) {
        demand.setWorkoutActive(active)
        reconcileDemand()
    }

    /// Reconciles an enrollment promotion or revocation delivered over the
    /// durable phone/Watch control channel. In particular, a revoked active
    /// credential must not remain usable merely because its BLE session was
    /// already authenticated before Keychain deletion.
    func controllerCredentialsDidChange() {
        let refreshed: [WatchControllerCredentialV1]
        do {
            refreshed = try credentialStore.allActiveCredentials()
        } catch {
            fail("Watch credential could not be read")
            return
        }

        let refreshedIdentities = Set(refreshed.map {
            CredentialIdentity(
                deviceID: $0.deviceID,
                controllerID: $0.controllerID
            )
        })
        let removedDeviceIDs = credentials.compactMap { saved -> String? in
            let identity = CredentialIdentity(
                deviceID: saved.deviceID,
                controllerID: saved.controllerID
            )
            return refreshedIdentities.contains(identity)
                ? nil
                : saved.deviceID
        }
        credentials = eligibleCredentials(from: refreshed)
        if !removedDeviceIDs.isEmpty {
            var map = peripheralMap()
            for deviceID in removedDeviceIDs {
                map.removeValue(forKey: deviceID)
            }
            defaults.set(map, forKey: peripheralMapKey)
        }

        let activeWasRevoked = credential.map { active in
            !refreshedIdentities.contains(CredentialIdentity(
                deviceID: active.deviceID,
                controllerID: active.controllerID
            ))
        } ?? false
        if activeWasRevoked {
            reconnectTask?.cancel()
            reconnectTask = nil
            operationTimeoutTask?.cancel()
            operationTimeoutTask = nil
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
            if state.isReady {
                writeProtectedAuth("LEASE_RELEASE")
            }
            if let peripheral {
                central.cancelPeripheralConnection(peripheral)
            }
            connectionGeneration &+= 1
            resetTransport(keepingPeripheral: false)
            state = refreshed.isEmpty
                ? .notEnrolled
                : .failed("Watch controller enrollment changed")
        }

        guard hasDemand else { return }
        if credentials.isEmpty {
            state = .notEnrolled
        } else if !state.isReady {
            beginIfNeeded()
        }
    }

    private func reconcileDemand() {
        guard hasDemand else {
            stop()
            return
        }
        requestPhonePreparationIfNeeded()
        beginIfNeeded()
    }

    func directRidePreparationDidRespond(
        request: WatchDirectRidePreparationRequestV1,
        response: WatchDirectRidePreparationResponseV1
    ) {
        guard request.operation == .prepare,
              request.deviceID == preparedPhoneDeviceID,
              request.preparationID == preparedPhonePreparationID,
              request.deviceID == selectedBikeComputerEnvelope?.deviceID,
              hasDemand else { return }
        phonePreparationResponseTimeoutTask?.cancel()
        phonePreparationResponseTimeoutTask = nil
        phonePreparationSubmissionOutstanding = false
        if response.accepted {
            phonePreparationAccepted = true
            phonePreparationAttempt = 0
            phonePreparationRetryTask?.cancel()
            phonePreparationRetryTask = nil
            return
        }
        phonePreparationAccepted = false
        guard !state.isReady else { return }
        if state == .scanning {
            central.stopScan()
        }
        operationTimeoutTask?.cancel()
        operationTimeoutTask = nil
        let message: String
        switch response.errorCode {
        case "phone_navigation_active":
            message = "Bicino is controlled by iPhone navigation"
        case "device_transfer_active":
            message = "Bicino is busy transferring data from iPhone"
        case "device_admin_active":
            message = "Bicino setup is active on iPhone"
        case "different_device":
            message = "Select the same Bicino on iPhone"
        default:
            message = "Bicino is controlled by iPhone"
        }
        lastError = message
        state = .busy
        scheduleReconnect()
    }

    func directRidePreparationSubmissionDidFail(
        request: WatchDirectRidePreparationRequestV1
    ) {
        guard request.operation == .prepare,
              request.deviceID == preparedPhoneDeviceID,
              request.preparationID == preparedPhonePreparationID,
              hasDemand else { return }
        phonePreparationResponseTimeoutTask?.cancel()
        phonePreparationResponseTimeoutTask = nil
        phonePreparationSubmissionOutstanding = false
        phonePreparationAccepted = false
        schedulePhonePreparationRetry()
    }

    func directRidePreparationAvailabilityDidChange() {
        if hasDemand {
            if phonePreparationReleasePending,
               preparedPhoneDeviceID ==
                selectedBikeComputerEnvelope?.deviceID {
                phonePreparationReleasePending = false
                preparedPhonePreparationID = UUID()
                persistPhonePreparationIntent(operation: .prepare)
            }
            requestPhonePreparationIfNeeded()
        } else if phonePreparationReleasePending {
            releasePhonePreparationIfNeeded()
        }
    }

    func completeInitialDemandRestoration() {
        switch phonePreparationRestorationGate.complete(
            hasRecoveredDemand: hasDemand
        ) {
        case .retain:
            requestPhonePreparationIfNeeded()
        case .release:
            releasePhonePreparationIfNeeded()
        case .none:
            break
        }
    }

    func updateNavigation(
        location: NavigationLocationSampleV1,
        snapshot: NavigationSnapshotV1
    ) {
        let previousSnapshot = latestNavigationSnapshot
        latestLocation = location
        latestNavigationSnapshot = snapshot
        latestRouteWindow = snapshot.routeWindow
        guard state.isReady else { return }
        enqueueLiveNavigation(
            location: location,
            snapshot: snapshot,
            previousSnapshot: previousSnapshot
        )
    }

    func clearNavigation() {
        latestLocation = nil
        latestNavigationSnapshot = nil
        latestRouteWindow = Data()
        guard state.isReady else { return }
        _ = enqueueGroup(
            priority: .control,
            disposition: .critical,
            applicationCommandType: .navigationClear,
            coalescingKey: "navigation-state",
            writes: [
                .init(target: .route, payload: Data()),
                .init(
                    target: .navigation,
                    payload: WatchRidePacketEncoderV1.maneuver(nil)
                ),
            ]
        )
        enqueueWorkoutGPSIfNeeded()
        drainQueue()
    }

    func endNavigationDemandAfterClearing() {
        demand.beginNavigationRelease()
        clearNavigation()
        finishPendingReleasesIfPossible()
        reconcileDemand()
    }

    func updateWorkout(
        _ frames: WorkoutDeviceFrames,
        gps: WorkoutDeviceGPSUpdate?,
        motion: WorkoutDeviceMotionUpdate?
    ) {
        latestWorkoutFrames = frames
        latestWorkoutGPS = gps
        latestWorkoutMotion = motion
        guard state.isReady else { return }
        enqueueWorkoutFrames(frames)
        enqueueWorkoutMotionIfNeeded()
        enqueueWorkoutGPSIfNeeded()
        drainQueue()
    }

    func clearWorkout(_ frames: WorkoutDeviceFrames) {
        latestWorkoutFrames = frames
        latestWorkoutGPS = nil
        latestWorkoutMotion = nil
        guard state.isReady else { return }
        enqueueWorkoutFrames(frames)
        drainQueue()
    }

    @discardableResult
    func sendRideAutomationFrame(_ frame: RideAutomationFrame) -> Bool {
        guard state.isReady,
              capabilities?.supportsRideAutomation == true,
              let payload = frame.encoded(),
              let transport = WatchRideAutomationTransportV1.outbound(
                frame: payload,
                nativeCharacteristicAvailable:
                    rideAutomationCharacteristic != nil
              ) else {
            return false
        }
        guard enqueueGroup(
            priority: .control,
            disposition: .critical,
            coalescingKey: frame.kind == .resynchronize ||
                frame.kind == .configuration
                ? "ride-automation-\(frame.kind.rawValue)" : nil,
            writes: [.init(
                target: transport.target,
                payload: transport.payload
            )]
        ) else {
            return false
        }
        drainQueue()
        return true
    }

    func endWorkoutDemandAfterClearing(_ frames: WorkoutDeviceFrames) {
        demand.beginWorkoutRelease()
        clearWorkout(frames)
        finishPendingReleasesIfPossible()
        reconcileDemand()
    }

    private var hasDemand: Bool {
        demand.requiresConnection
    }

    private struct CredentialIdentity: Hashable {
        let deviceID: String
        let controllerID: Data
    }

    private func beginIfNeeded() {
        guard hasDemand, !state.isReady else { return }
        if state == .busy {
            requestPhonePreparationIfNeeded(force: true)
        } else {
            requestPhonePreparationIfNeeded()
        }
        switch state {
        case .scanning, .connecting, .discovering, .authenticating,
                .claimingLease:
            return
        default:
            break
        }
        do {
            credentials = eligibleCredentials(
                from: try credentialStore.allActiveCredentials()
            )
        } catch {
            fail("Watch credential could not be read")
            return
        }
        guard !credentials.isEmpty else {
            state = .notEnrolled
            return
        }
        _ = central
        guard central.state == .poweredOn else {
            state = .bluetoothUnavailable
            return
        }
        if connectRetrievedPeripheral() { return }
        startScan()
    }

    private func connectRetrievedPeripheral() -> Bool {
        let saved = peripheralMap()
        let candidates = credentials.compactMap { credential -> UUID? in
            guard let value = saved[credential.deviceID] else { return nil }
            return UUID(uuidString: value)
        }
        guard !candidates.isEmpty,
              let retrieved = central.retrievePeripherals(
                withIdentifiers: candidates
              ).first,
              let matchedCredential = credentials.first(where: {
                  saved[$0.deviceID] == retrieved.identifier.uuidString
              }) else {
            return false
        }
        connect(retrieved, credential: matchedCredential)
        return true
    }

    private func eligibleCredentials(
        from allCredentials: [WatchControllerCredentialV1]
    ) -> [WatchControllerCredentialV1] {
        guard let selectedBikeComputerEnvelope else {
            // Backward compatibility while an older paired iPhone has not yet
            // published the versioned selected-device field. A single
            // credential is unambiguous; multiple credentials fail closed.
            return allCredentials.count == 1 ? allCredentials : []
        }
        return allCredentials.filter(selectedBikeComputerEnvelope.selects)
    }

    private func requestPhonePreparationIfNeeded(force: Bool = false) {
        guard hasDemand,
              let deviceID = selectedBikeComputerEnvelope?.deviceID else {
            return
        }
        if preparedPhoneDeviceID != deviceID {
            guard releasePhonePreparationIfNeeded() else { return }
            preparedPhoneDeviceID = deviceID
            preparedPhonePreparationID = UUID()
            phonePreparationAccepted = false
            phonePreparationSubmissionOutstanding = false
            phonePreparationReleasePending = false
            phonePreparationAttempt = 0
            persistPhonePreparationIntent(operation: .prepare)
        } else if phonePreparationReleasePending {
            // A release that never left the Watch can be superseded when the
            // same ride regains demand before connectivity recovers. Give the
            // new prepare a fresh identity so a release already handed to
            // WatchConnectivity just before a crash cannot clear it later.
            phonePreparationReleasePending = false
            preparedPhonePreparationID = UUID()
            persistPhonePreparationIntent(operation: .prepare)
        }
        guard let preparationID = preparedPhonePreparationID,
              !phonePreparationReleasePending,
              force || !phonePreparationAccepted,
              !phonePreparationSubmissionOutstanding else { return }
        phonePreparationRetryTask?.cancel()
        phonePreparationRetryTask = nil
        phonePreparationAttempt = min(phonePreparationAttempt + 1, 6)
        let disposition = onDirectRidePreparationChange?(
            .prepare,
            deviceID,
            preparationID
        ) ?? .transportUnavailable
        switch disposition {
        case .submitted:
            phonePreparationSubmissionOutstanding = true
            startPhonePreparationResponseTimeout()
        case .transportUnavailable, .activationPending,
                .counterpartUnreachable, .encodingFailed:
            phonePreparationSubmissionOutstanding = false
            schedulePhonePreparationRetry()
        }
    }

    @discardableResult
    private func releasePhonePreparationIfNeeded() -> Bool {
        guard let deviceID = preparedPhoneDeviceID,
              let preparationID = preparedPhonePreparationID else {
            return true
        }
        phonePreparationRetryTask?.cancel()
        phonePreparationRetryTask = nil
        phonePreparationResponseTimeoutTask?.cancel()
        phonePreparationResponseTimeoutTask = nil
        phonePreparationSubmissionOutstanding = false
        phonePreparationAccepted = false
        phonePreparationReleasePending = true
        persistPhonePreparationIntent(operation: .release)
        let disposition = onDirectRidePreparationChange?(
            .release,
            deviceID,
            preparationID
        ) ?? .transportUnavailable
        guard disposition == .submitted else { return false }
        preparedPhoneDeviceID = nil
        preparedPhonePreparationID = nil
        phonePreparationReleasePending = false
        phonePreparationAttempt = 0
        defaults.removeObject(forKey: directRidePreparationIntentKey)
        return true
    }

    private func persistPhonePreparationIntent(
        operation: WatchDirectRidePreparationOperationV1
    ) {
        guard let deviceID = preparedPhoneDeviceID,
              let preparationID = preparedPhonePreparationID,
              let intent = try? WatchDirectRidePreparationIntentV1(
                preparationID: preparationID,
                operation: operation,
                deviceID: deviceID
              ), let data = try? intent.encoded() else { return }
        defaults.set(data, forKey: directRidePreparationIntentKey)
    }

    private func startPhonePreparationResponseTimeout() {
        phonePreparationResponseTimeoutTask?.cancel()
        let deviceID = preparedPhoneDeviceID
        let preparationID = preparedPhonePreparationID
        phonePreparationResponseTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(
                WatchDirectRidePreparationRetryPolicyV1
                    .responseTimeoutSeconds
            ))
            guard !Task.isCancelled, let self,
                  self.hasDemand,
                  self.preparedPhoneDeviceID == deviceID,
                  self.preparedPhonePreparationID == preparationID,
                  self.phonePreparationSubmissionOutstanding else { return }
            self.phonePreparationResponseTimeoutTask = nil
            self.phonePreparationSubmissionOutstanding = false
            self.schedulePhonePreparationRetry()
        }
    }

    private func schedulePhonePreparationRetry() {
        guard hasDemand,
              !phonePreparationAccepted,
              !phonePreparationReleasePending,
              phonePreparationRetryTask == nil else { return }
        let deviceID = preparedPhoneDeviceID
        let preparationID = preparedPhonePreparationID
        let delay = WatchDirectRidePreparationRetryPolicyV1.delaySeconds(
            afterAttempt: phonePreparationAttempt
        )
        phonePreparationRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.phonePreparationRetryTask = nil
            guard self.hasDemand,
                  self.preparedPhoneDeviceID == deviceID,
                  self.preparedPhonePreparationID == preparationID else {
                return
            }
            self.requestPhonePreparationIfNeeded()
        }
    }

    private func failClosedSelection(_ message: String) {
        lastError = message
        reconnectTask?.cancel()
        reconnectTask = nil
        operationTimeoutTask?.cancel()
        operationTimeoutTask = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        if state == .scanning { central.stopScan() }
        if state.isReady {
            writeProtectedAuth("LEASE_RELEASE")
        }
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        connectionGeneration &+= 1
        resetTransport(keepingPeripheral: false)
        credentials = []
        releasePhonePreparationIfNeeded()
        state = .failed(message)
    }

    private func startScan() {
        guard hasDemand, central.state == .poweredOn else { return }
        state = .scanning
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        startOperationTimeout(generation: connectionGeneration)
    }

    private func connect(
        _ candidate: CBPeripheral,
        credential: WatchControllerCredentialV1
    ) {
        central.stopScan()
        resetTransport(keepingPeripheral: false)
        connectionGeneration &+= 1
        transportAttemptID = UUID()
        transportDiagnosticSequence = 0
        _ = reduceTransport(.beginConnection)
        self.credential = credential
        peripheral = candidate
        candidate.delegate = self
        state = .connecting
        central.connect(candidate)
        startOperationTimeout(generation: connectionGeneration)
    }

    private func stop() {
        if gracefulStopPending { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        operationTimeoutTask?.cancel()
        operationTimeoutTask = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        disconnectingForBusyLease = false
        demand.reset()
        if state.isReady, protectedSession != nil, !gracefulStopPending {
            _ = reduceTransport(.stopRequested(
                generation: transportStateMachine.generation
            ))
            gracefulStopPending = true
            writeProtectedAuth("LEASE_RELEASE")
            leaseReleaseAckTask?.cancel()
            let generation = connectionGeneration
            leaseReleaseAckTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self,
                      self.gracefulStopPending,
                      self.connectionGeneration == generation else { return }
                self.leaseReleaseAckTask = nil
                self.completeStop()
            }
            return
        }
        completeStop()
    }

    private func completeStop() {
        gracefulStopPending = false
        leaseReleaseAckTask?.cancel()
        leaseReleaseAckTask = nil
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        if transportStateMachine.phase != .idle {
            _ = reduceTransport(.disconnected(
                generation: transportStateMachine.generation
            ))
        }
        connectionGeneration &+= 1
        resetTransport(keepingPeripheral: false)
        releasePhonePreparationIfNeeded()
        state = .idle
        lastError = nil
    }

    private func resetTransport(keepingPeripheral: Bool) {
        if transportStateMachine.phase != .idle {
            _ = reduceTransport(.disconnected(
                generation: transportStateMachine.generation
            ))
        }
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        leaseReleaseAckTask?.cancel()
        leaseReleaseAckTask = nil
        gracefulStopPending = false
        operationTimeoutTask?.cancel()
        operationTimeoutTask = nil
        authentication = nil
        challenge = nil
        protectedSession = nil
        capabilities = nil
        authCharacteristic = nil
        navigationCharacteristic = nil
        routeCharacteristic = nil
        gpsCharacteristic = nil
        workoutCharacteristic = nil
        rideAutomationCharacteristic = nil
        writeWithResponseInFlight = false
        pendingATTWrite = nil
        writerWatchdogTask?.cancel()
        writerWatchdogTask = nil
        withoutResponseWatchdogTask?.cancel()
        withoutResponseWatchdogTask = nil
        activeWriteGroup = nil
        activeWriteIndex = 0
        pendingApplicationAckGroup = nil
        bufferedApplicationAcknowledgement = nil
        applicationAckRetryCount = 0
        applicationAckStartedAtUptime = nil
        applicationAckWatchdogTask?.cancel()
        applicationAckWatchdogTask = nil
        queue.removeAll()
        if !keepingPeripheral {
            peripheral = nil
            credential = nil
        }
    }

    private func beginAuthentication() {
        guard authentication == nil,
              let credential,
              let nonce = Self.randomNonce() else {
            fail("Could not begin Watch authentication")
            return
        }
        do {
            let authentication = try WatchScopedAuthenticationV1(
                credential: credential,
                clientNonce: nonce
            )
            self.authentication = authentication
            state = .authenticating
            startOperationTimeout(generation: connectionGeneration)
            writeRawAuth(authentication.hello)
        } catch {
            fail("Watch credential is invalid")
        }
    }

    private func handleAuthNotification(_ raw: Data) {
        if raw.prefix(2) == Data([0x52, 0x32]) {
            guard let protectedSession,
                  let payload = protectedSession.notificationPayload(
                    from: raw,
                    channel: .auth
                  ),
                  let message = String(data: payload, encoding: .utf8) else {
                fail("Bike Computer sent invalid protected auth data")
                return
            }
            handleProtectedAuthMessage(message)
            return
        }
        guard let message = String(
            data: raw.trimmingTrailingTransportBytes(),
            encoding: .utf8
        ), let authentication else {
            failAuthentication(
                "Bike Computer sent invalid authentication data"
            )
            return
        }
        do {
            if message.hasPrefix("WS2|") {
                let challenge = try authentication.acceptServer(message)
                self.challenge = challenge
                writeRawAuth(challenge.proofCommand)
            } else if message.hasPrefix("WOK2|"), let challenge {
                protectedSession = try authentication.finish(
                    message,
                    challenge: challenge
                )
                _ = reduceTransport(.authenticated(
                    generation: transportStateMachine.generation
                ))
                state = .claimingLease
                writeProtectedAuth("LEASE_CLAIM")
            } else if message.hasPrefix("DENIED|") {
                failAuthentication("Watch controller was rejected")
            }
        } catch {
            failAuthentication(
                "Bike Computer authentication proof was invalid"
            )
        }
    }

    private func handleProtectedAuthMessage(_ message: String) {
        switch message {
        case "LEASE_OK":
            if state == .claimingLease {
                _ = reduceTransport(.leaseAccepted(
                    generation: transportStateMachine.generation,
                    leaseGeneration: 1
                ))
                requestCapabilities()
            }
        case "LEASE_RELEASED":
            if gracefulStopPending {
                _ = reduceTransport(.leaseReleased(
                    generation: transportStateMachine.generation
                ))
                completeStop()
            }
        case "ERROR|lease_busy":
            _ = reduceTransport(.failed(
                generation: transportStateMachine.generation,
                reason: .leaseBusy
            ))
            state = .busy
            lastError = "Bicino is controlled by iPhone"
            disconnectingForBusyLease = true
            if let peripheral {
                central.cancelPeripheralConnection(peripheral)
            }
        case "ERROR|lease_not_held", "ERROR|lease_rejected":
            fail(
                "Bike Computer ride lease was lost",
                reason: .leaseLost
            )
        default:
            break
        }
    }

    private func requestCapabilities() {
        var request = Data("CAPS".utf8)
        request.append(WatchDirectBLEProtocolV1.capabilityClientVersion)
        _ = enqueueGroup(
            priority: .control,
            disposition: .critical,
            coalescingKey: "capabilities",
            writes: [.init(target: .navigation, payload: request)]
        )
        drainQueue()
    }

    private func handleNavigationNotification(_ raw: Data) {
        guard let protectedSession,
              let payload = protectedSession.notificationPayload(
                from: raw,
                channel: .navigation
              ) else {
            fail("Bike Computer sent invalid protected navigation data")
            return
        }
        if payload.starts(with: RideBLEApplicationAcknowledgementV1.prefix) {
            guard let acknowledgement =
                    RideBLEApplicationAcknowledgementV1.decode(payload) else {
                fail(
                    "Bike Computer sent malformed ride acknowledgement",
                    reason: .applicationRejected
                )
                return
            }
            handleApplicationAcknowledgement(acknowledgement)
            return
        }
        if payload.starts(with: WatchRideAutomationTransportV1.fallbackPrefix) {
            guard state.isReady,
                  capabilities?.supportsRideAutomation == true,
                  let framePayload = WatchRideAutomationTransportV1
                    .decodeNavigationFallback(payload),
                  let frame = RideAutomationFrame(framePayload) else {
                fail("Bike Computer sent invalid ride automation fallback")
                return
            }
            onRideAutomationFrame?(frame)
            return
        }
        let capabilities: WatchDeviceCapabilitiesV1
        switch WatchNavigationNotificationV1.decode(payload) {
        case .ignoredDeviceRequest:
            return
        case .invalidCapabilities:
            fail("Bike Computer sent invalid capability data")
            return
        case .capabilities(let decoded):
            capabilities = decoded
        }
        guard capabilities.supportsScopedController else {
            fail("Bike Computer firmware does not support Watch navigation")
            return
        }
        if demand.requiresWorkoutChannel {
            guard capabilities.supportsWorkoutTelemetry,
                  workoutCharacteristic != nil else {
                fail("Bike Computer firmware lacks Watch workout telemetry")
                return
            }
        }
        self.capabilities = capabilities
        let transportTransition = reduceTransport(.capabilitiesAccepted(
            generation: transportStateMachine.generation,
            schemaVersion: 1
        ))
        guard transportTransition == .becameReady ||
                (transportTransition == .applied &&
                 transportStateMachine.isReady) else {
            fail(
                "Watch transport could not establish authoritative readiness",
                reason: .capabilityRejected
            )
            return
        }
        reconnectAttempt = 0
        lastError = nil
        state = .ready(deviceID: credential?.deviceID ?? "")
        operationTimeoutTask?.cancel()
        operationTimeoutTask = nil
        persistCurrentPeripheral()
        startHeartbeat()
        enqueueFullResynchronization()
        drainQueue()
    }

    private func handleRideAutomationNotification(_ raw: Data) {
        guard state.isReady,
              capabilities?.supportsRideAutomation == true,
              let protectedSession,
              let payload = protectedSession.notificationPayload(
                from: raw,
                channel: .rideAutomation
              ),
              let frame = RideAutomationFrame(payload) else {
            fail("Bike Computer sent invalid ride automation data")
            return
        }
        onRideAutomationFrame?(frame)
    }

    private func enqueueFullResynchronization() {
        queue.removeAll()
        if let latestWorkoutFrames {
            enqueueWorkoutFrames(latestWorkoutFrames)
        }
        enqueueWorkoutMotionIfNeeded()
        if let latestLocation {
            _ = enqueueGroup(
                priority: .livePosition,
                disposition: .replaceable,
                coalescingKey: "gps",
                writes: [.init(
                    target: .gps,
                    payload: WatchRidePacketEncoderV1.gps(
                        latestLocation,
                        snapshot: latestNavigationSnapshot,
                        includeRideDetectionQuality:
                            capabilities?.supportsGPSPositionQualityV1 == true
                    ),
                    gpsSampleTimestamp: latestLocation.timestamp
                )]
            )
        } else {
            enqueueWorkoutGPSIfNeeded()
        }
        if demand.navigationReleasePending {
            _ = enqueueGroup(
                priority: .control,
                disposition: .critical,
                applicationCommandType: .navigationClear,
                coalescingKey: "navigation-state",
                writes: [
                    .init(target: .route, payload: Data()),
                    .init(
                        target: .navigation,
                        payload: WatchRidePacketEncoderV1.maneuver(nil)
                    ),
                ]
            )
        } else {
            _ = enqueueGroup(
                priority: .livePosition,
                disposition: .replaceable,
                coalescingKey: "route",
                writes: [.init(target: .route, payload: latestRouteWindow)]
            )
            _ = enqueueGroup(
                priority: .navigationBoundary,
                disposition: .replaceable,
                coalescingKey: "maneuver",
                writes: [.init(
                    target: .navigation,
                    payload: WatchRidePacketEncoderV1.maneuver(
                        latestNavigationSnapshot
                    )
                )]
            )
        }
    }

    private func enqueueLiveNavigation(
        location: NavigationLocationSampleV1,
        snapshot: NavigationSnapshotV1,
        previousSnapshot: NavigationSnapshotV1?
    ) {
        _ = enqueueGroup(
            priority: .livePosition,
            disposition: .replaceable,
            coalescingKey: "gps",
            writes: [.init(
                target: .gps,
                payload: WatchRidePacketEncoderV1.gps(
                    location,
                    snapshot: snapshot,
                    includeRideDetectionQuality:
                        capabilities?.supportsGPSPositionQualityV1 == true
                ),
                gpsSampleTimestamp: location.timestamp
            )]
        )
        _ = enqueueGroup(
            priority: .livePosition,
            disposition: .replaceable,
            coalescingKey: "route",
            writes: [.init(target: .route, payload: snapshot.routeWindow)]
        )
        if Self.shouldSendManeuver(
            snapshot,
            after: previousSnapshot
        ) {
            _ = enqueueGroup(
                priority: .navigationBoundary,
                disposition: .replaceable,
                coalescingKey: "maneuver",
                writes: [.init(
                    target: .navigation,
                    payload: WatchRidePacketEncoderV1.maneuver(snapshot)
                )]
            )
        }
        drainQueue()
    }

    private static func shouldSendManeuver(
        _ snapshot: NavigationSnapshotV1,
        after previous: NavigationSnapshotV1?
    ) -> Bool {
        guard let previous else { return true }
        return snapshot.navigationGeneration != previous.navigationGeneration ||
            snapshot.routeID != previous.routeID ||
            snapshot.revision != previous.revision ||
            snapshot.currentStepIndex != previous.currentStepIndex ||
            snapshot.maneuver != previous.maneuver ||
            snapshot.instruction != previous.instruction ||
            snapshot.offRouteDistanceMeters != previous.offRouteDistanceMeters ||
            abs(
                snapshot.distanceToManeuverMeters -
                    previous.distanceToManeuverMeters
            ) >= 10
    }

    private func enqueueWorkoutFrames(_ frames: WorkoutDeviceFrames) {
        workoutPairGeneration = workoutPairGeneration == 3
            ? 1
            : workoutPairGeneration + 1
        let payloads = WorkoutDeviceFrameBuilder.transportFrames(
            for: frames,
            generation: workoutPairGeneration,
            includeOrigin: capabilities?.supportsRideAutomation == true
        )
        let isCritical = [
            WorkoutDeviceSessionState.ending,
            .ended,
            .failed,
            .idle,
        ].contains(frames.identity.state)
        _ = enqueueGroup(
            priority: isCritical ? .terminalWorkout : .liveWorkout,
            disposition: isCritical ? .critical : .replaceable,
            applicationCommandType: isCritical ? .workoutState : nil,
            coalescingKey: "workout",
            writes: payloads.map {
                .init(target: .workout, payload: $0)
            }
        )
    }

    private func enqueueWorkoutGPSIfNeeded() {
        guard demand.workoutActive,
              !demand.navigationActive,
              let latestWorkoutGPS else { return }
        _ = enqueueGroup(
            priority: .livePosition,
            disposition: .replaceable,
            coalescingKey: "gps",
            writes: [.init(
              target: .gps,
              payload: WatchRidePacketEncoderV1.gps(
                NavigationLocationSampleV1(
                    coordinate: RouteCoordinateV1(
                        latitude: latestWorkoutGPS.latitude,
                        longitude: latestWorkoutGPS.longitude
                    ),
                    horizontalAccuracyMeters:
                        latestWorkoutGPS.horizontalAccuracyMeters,
                    courseDegrees: latestWorkoutGPS.courseDegrees ?? -1,
                    speedMetersPerSecond:
                        latestWorkoutGPS.speedMetersPerSecond ?? -1,
                    altitudeMeters: latestWorkoutGPS.altitudeMeters ?? 0,
                    timestamp: latestWorkoutGPS.capturedAt
                ),
                snapshot: nil,
                distanceTraveledMeters:
                    latestWorkoutGPS.distanceTraveledMeters,
                elapsedSeconds: latestWorkoutGPS.elapsedSeconds,
                includeRideDetectionQuality:
                    capabilities?.supportsGPSPositionQualityV1 == true
              ),
              gpsSampleTimestamp: latestWorkoutGPS.capturedAt
            )]
        )
    }

    private func enqueueWorkoutMotionIfNeeded() {
        guard demand.workoutActive,
              capabilities?.supportsWatchGPSMotionEvidenceV1 == true,
              let latestWorkoutMotion,
              let frame = WorkoutDeviceFrameBuilder.watchMotionFrame(
                for: latestWorkoutMotion,
                sentAt: Date()
              ) else { return }
        _ = enqueueGroup(
            priority: .liveWorkout,
            disposition: .replaceable,
            coalescingKey: "workout-motion",
            writes: [.init(
                target: .workout,
                payload: frame
            )]
        )
    }

    @discardableResult
    private func enqueueGroup(
        priority: RideBLECommandPriorityV1,
        disposition: RideBLECommandDispositionV1,
        applicationCommandType: RideBLEApplicationCommandTypeV1? = nil,
        coalescingKey: String? = nil,
        writes: [WatchBLEOutboundWriteV1]
    ) -> Bool {
        nextOutboundStateGeneration &+= 1
        if nextOutboundStateGeneration == 0 {
            nextOutboundStateGeneration = 1
        }
        let admission = queue.enqueue(.init(
            connectionGeneration: connectionGeneration,
            stateGeneration: nextOutboundStateGeneration,
            priority: priority,
            disposition: disposition,
            applicationCommandType: applicationCommandType,
            coalescingKey: coalescingKey,
            writes: writes
        ))
        recordTransportDiagnostic(kind: .queueAdmission)
        guard admission.admitted else {
            if disposition == .critical {
                fail(
                    "Critical Watch BLE command is waiting for resync",
                    reason: .criticalAdmissionFailed
                )
            }
            return false
        }
        return true
    }

    private func drainQueue() {
        guard let peripheral,
              transportStateMachine.phase != .idle,
              transportStateMachine.phase != .recovering,
              !writeWithResponseInFlight,
              pendingApplicationAckGroup == nil else { return }
        while true {
            if activeWriteGroup == nil {
                activeWriteGroup = queue.dequeueGroup()
                activeWriteIndex = 0
            }
            guard let group = activeWriteGroup else {
                finishPendingReleasesIfPossible()
                return
            }
            guard group.connectionGeneration == connectionGeneration else {
                activeWriteGroup = nil
                activeWriteIndex = 0
                continue
            }
            guard activeWriteIndex < group.writes.count else {
                completePhysicallyWrittenGroup(group)
                if pendingApplicationAckGroup != nil { return }
                continue
            }
            let write = group.writes[activeWriteIndex]
            let memberIndex = activeWriteIndex
            guard let characteristic = characteristic(for: write.target) else {
                fail("Bike Computer characteristic disappeared")
                return
            }
            var payload = write.gpsSampleTimestamp.map {
                WatchRidePacketEncoderV1.refreshingQualityAge(
                    in: write.payload,
                    sampleTimestamp: $0
                )
            } ?? write.payload
            if shouldUseApplicationAcknowledgement(for: group) {
                guard let commandType = group.applicationCommandType,
                      let wrapped = RideBLEApplicationCommandEnvelopeV1(
                commandType: commandType,
                memberIndex: UInt8(memberIndex),
                memberCount: UInt8(group.writes.count),
                commandID: group.commandID,
                stateGeneration: group.stateGeneration,
                payload: payload
                      ).encoded() else {
                    fail("Could not encode critical Watch BLE command")
                    return
                }
                payload = wrapped
            }
            let frame: Data
            switch write.protection {
            case .raw:
                frame = payload
            case .protected:
                guard let session = protectedSession else {
                    fail("Protected Watch writer is not authenticated")
                    return
                }
                do {
                    frame = try session.frame(
                        payload: payload,
                        channel: write.target.channel
                    )
                } catch {
                    fail("Could not protect Watch BLE data")
                    return
                }
            }
            let writeType: CBCharacteristicWriteType
            if characteristic.properties.contains(.write) {
                writeType = .withResponse
            } else if characteristic.properties.contains(
                .writeWithoutResponse
            ) {
                guard peripheral.canSendWriteWithoutResponse else {
                    startWithoutResponseWatchdog(
                        peripheralID: peripheral.identifier,
                        generation: connectionGeneration
                    )
                    return
                }
                withoutResponseWatchdogTask?.cancel()
                withoutResponseWatchdogTask = nil
                writeType = .withoutResponse
            } else {
                fail("Bike Computer characteristic is not writable")
                return
            }
            let maximum = peripheral.maximumWriteValueLength(for: writeType)
            guard frame.count <= maximum else {
                fail("Watch ride packet exceeds the BLE write limit")
                return
            }
            writeWithResponseInFlight = writeType == .withResponse
            activeWriteIndex += 1
            if writeType == .withResponse {
                beginATTWriteWait(
                    peripheralID: peripheral.identifier,
                    characteristicID: characteristic.uuid
                )
            }
            peripheral.writeValue(
                frame,
                for: characteristic,
                type: writeType
            )
            if writeType == .withResponse { return }
            if activeWriteIndex == group.writes.count {
                completePhysicallyWrittenGroup(group)
                if pendingApplicationAckGroup != nil { return }
            }
        }
    }

    private func shouldUseApplicationAcknowledgement(
        for group: WatchBLEOutboundGroupV1
    ) -> Bool {
        group.applicationCommandType != nil &&
            capabilities?.supportsRideDeliveryAcknowledgement == true
    }

    private func completePhysicallyWrittenGroup(
        _ group: WatchBLEOutboundGroupV1
    ) {
        activeWriteGroup = nil
        activeWriteIndex = 0
        guard shouldUseApplicationAcknowledgement(for: group) else { return }
        pendingApplicationAckGroup = group
        startApplicationAckWatchdog(for: group)
        if let buffered = bufferedApplicationAcknowledgement {
            bufferedApplicationAcknowledgement = nil
            handleApplicationAcknowledgement(buffered)
        }
    }

    private func beginATTWriteWait(
        peripheralID: UUID,
        characteristicID: CBUUID
    ) {
        nextWriteID &+= 1
        if nextWriteID == 0 {
            nextWriteID = 1
        }
        let pending = PendingATTWrite(
            writeID: nextWriteID,
            peripheralID: peripheralID,
            connectionGeneration: connectionGeneration,
            characteristicID: characteristicID,
            startedAtUptime: ProcessInfo.processInfo.systemUptime
        )
        pendingATTWrite = pending
        _ = reduceTransport(.writerChanged(
            generation: transportStateMachine.generation,
            state: .waitingForATTResponse(writeID: pending.writeID)
        ))
        writerWatchdogTask?.cancel()
        let watchdogClass: RideBLEATTWriteClassV1 =
            activeWriteGroup?.applicationCommandType == nil
                ? .other : .criticalApplication
        let watchdogTimeout = RideBLEATTWatchdogPolicyV1.timeoutSeconds(
            for: watchdogClass
        )
        writerWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(watchdogTimeout))
            guard !Task.isCancelled, let self,
                  let current = self.pendingATTWrite,
                  current.writeID == pending.writeID,
                  current.peripheralID == pending.peripheralID,
                  current.connectionGeneration ==
                    pending.connectionGeneration else { return }
            self.writerWatchdogTask = nil
            self.pendingATTWrite = nil
            self.writeWithResponseInFlight = false
            self.recordTransportDiagnostic(
                kind: .attTimeout,
                latencyMs: max(0, Int((
                    ProcessInfo.processInfo.systemUptime -
                        current.startedAtUptime
                ) * 1_000))
            )
            // CoreBluetooth callbacks carry no logical write ID. Reusing this
            // connection could let a late callback complete the wrong retry,
            // so reconnect and regenerate retained logical state instead.
            self.fail(
                "Watch BLE acknowledged write timed out",
                reason: .attTimeout
            )
        }
    }

    private func startWithoutResponseWatchdog(
        peripheralID: UUID,
        generation: UInt64
    ) {
        guard withoutResponseWatchdogTask == nil else { return }
        _ = reduceTransport(.writerChanged(
            generation: transportStateMachine.generation,
            state: .waitingForWithoutResponseReadiness
        ))
        withoutResponseWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self,
                  self.peripheral?.identifier == peripheralID,
                  self.connectionGeneration == generation,
                  self.activeWriteGroup != nil else { return }
            self.withoutResponseWatchdogTask = nil
            self.fail(
                "Watch BLE write backpressure timed out",
                reason: .writeBackpressure
            )
        }
    }

    private func startApplicationAckWatchdog(
        for group: WatchBLEOutboundGroupV1
    ) {
        applicationAckWatchdogTask?.cancel()
        if applicationAckRetryCount == 0 {
            applicationAckStartedAtUptime =
                ProcessInfo.processInfo.systemUptime
        }
        _ = reduceTransport(.writerChanged(
            generation: transportStateMachine.generation,
            state: .waitingForApplicationAcknowledgement(
                commandID: group.commandID
            )
        ))
        applicationAckWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self,
                  self.pendingApplicationAckGroup?.commandID ==
                    group.commandID,
                  self.connectionGeneration == group.connectionGeneration else {
                return
            }
            self.applicationAckWatchdogTask = nil
            self.pendingApplicationAckGroup = nil
            let startedAt = self.applicationAckStartedAtUptime ??
                ProcessInfo.processInfo.systemUptime
            self.recordTransportDiagnostic(
                kind: .applicationTimeout,
                latencyMs: max(0, Int((
                    ProcessInfo.processInfo.systemUptime - startedAt
                ) * 1_000))
            )
            switch RideBLEApplicationRetryPolicyV1.timeoutAction(
                completedRetries: self.applicationAckRetryCount
            ) {
            case .retry:
                self.applicationAckRetryCount = 1
                self.activeWriteGroup = group
                self.activeWriteIndex = 0
                self.drainQueue()
            case .recoverTransport:
                self.applicationAckStartedAtUptime = nil
                self.fail(
                    "Bike Computer did not acknowledge critical state",
                    reason: .applicationTimeout
                )
            }
        }
    }

    private func handleApplicationAcknowledgement(
        _ acknowledgement: RideBLEApplicationAcknowledgementV1
    ) {
        guard let group = pendingApplicationAckGroup else {
            guard let active = activeWriteGroup,
                  let commandType = active.applicationCommandType,
                  activeWriteIndex == active.writes.count,
                  RideBLEApplicationAcknowledgementPolicyV1.disposition(
                    pending: .init(
                        commandType: commandType,
                        commandID: active.commandID,
                        stateGeneration: active.stateGeneration
                    ),
                    acknowledgement: acknowledgement
                  ) != .ignored else { return }
            // A firmware notification can beat CoreBluetooth's callback for
            // the final acknowledged write. Hold only the exact active group
            // result, then consume it as soon as physical completion advances.
            bufferedApplicationAcknowledgement = acknowledgement
            return
        }
        guard let commandType = group.applicationCommandType else { return }
        let disposition = RideBLEApplicationAcknowledgementPolicyV1.disposition(
            pending: .init(
                commandType: commandType,
                commandID: group.commandID,
                stateGeneration: group.stateGeneration
            ),
            acknowledgement: acknowledgement
        )
        switch disposition {
        case .ignored:
            // A delayed acknowledgement from an older command/generation is
            // safe to ignore after reconnect or replacement.
            return
        case .invalidLeaseGeneration:
            fail(
                "Bike Computer returned an invalid lease acknowledgement",
                reason: .applicationRejected
            )
        case .completed:
            let startedAt = applicationAckStartedAtUptime ??
                ProcessInfo.processInfo.systemUptime
            applicationAckWatchdogTask?.cancel()
            applicationAckWatchdogTask = nil
            applicationAckStartedAtUptime = nil
            pendingApplicationAckGroup = nil
            applicationAckRetryCount = 0
            recordTransportDiagnostic(
                kind: .applicationAcknowledged,
                latencyMs: max(0, Int((
                    ProcessInfo.processInfo.systemUptime - startedAt
                ) * 1_000))
            )
            _ = reduceTransport(.writerChanged(
                generation: transportStateMachine.generation,
                state: .idle
            ))
            finishPendingReleasesIfPossible()
            drainQueue()
        case .rejected(let result):
            switch result {
            case .busy:
                fail(
                    "Bike Computer ride lease became busy",
                    reason: .leaseBusy
                )
            case .unauthorized:
                fail(
                    "Bike Computer rejected the Watch ride lease",
                    reason: .leaseLost
                )
            case .malformed:
                fail(
                    "Bike Computer rejected malformed critical state",
                    reason: .applicationRejected
                )
            case .resourceRejected:
                fail(
                    "Bike Computer lacked resources for critical state",
                    reason: .applicationRejected
                )
            case .success, .stale:
                break
            }
        }
    }

    private func finishPendingReleasesIfPossible() {
        guard state.isReady,
              demand.hasPendingRelease,
              queue.isEmpty,
              activeWriteGroup == nil,
              pendingApplicationAckGroup == nil,
              !writeWithResponseInFlight else { return }
        demand.completePendingReleases()
        if !hasDemand {
            stop()
        }
    }

    private func characteristic(
        for target: WatchBLEOutboundTargetV1
    ) -> CBCharacteristic? {
        switch target {
        case .auth: authCharacteristic
        case .navigation: navigationCharacteristic
        case .route: routeCharacteristic
        case .gps: gpsCharacteristic
        case .workout: workoutCharacteristic
        case .rideAutomation: rideAutomationCharacteristic
        }
    }

    private func writeRawAuth(_ message: String) {
        guard let data = message.data(using: .utf8),
              authCharacteristic != nil else {
            fail("Watch auth characteristic is unavailable")
            return
        }
        guard enqueueGroup(
            priority: .control,
            disposition: .critical,
            writes: [.init(
                target: .auth,
                payload: data,
                protection: .raw
            )]
        ) else { return }
        drainQueue()
    }

    private func writeProtectedAuth(_ message: String) {
        guard protectedSession != nil,
              let data = message.data(using: .utf8),
              authCharacteristic != nil else { return }
        let coalescingKey = message == "LEASE_HEARTBEAT"
            ? "lease-heartbeat" : nil
        guard enqueueGroup(
            priority: .control,
            disposition: .critical,
            coalescingKey: coalescingKey,
            writes: [.init(target: .auth, payload: data)]
        ) else { return }
        drainQueue()
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: 5,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.state.isReady == true else { return }
                self?.writeProtectedAuth("LEASE_HEARTBEAT")
            }
        }
    }

    @discardableResult
    private func reduceTransport(
        _ event: RideBLETransportEventV1
    ) -> RideBLETransportTransitionV1 {
        let transition = transportStateMachine.reduce(event)
        transportPhase = transportStateMachine.phase
        transportFailureReason = transportStateMachine.lastFailure
        recordTransportDiagnostic(kind: .transportTransition)
        return transition
    }

    private func recordTransportDiagnostic(
        kind: WatchBLETransportDiagnosticKindV1,
        latencyMs: Int? = nil
    ) {
        guard connectionGeneration != 0 else { return }
        transportDiagnosticSequence &+= 1
        if transportDiagnosticSequence == 0 {
            transportDiagnosticSequence = 1
        }
        let metrics = queue.metrics
        let queued = min(
            queue.pendingFrameCount +
                max((activeWriteGroup?.writes.count ?? 0) - activeWriteIndex, 0),
            64
        )
        let queuedBytes = min(
            queue.pendingByteCount +
                (activeWriteGroup?.writes.dropFirst(activeWriteIndex).reduce(0) {
                    $0 + $1.payload.count
                } ?? 0),
            64 * WatchBLEOutboundQueueV1.maximumFrameBytes
        )
        onTransportDiagnostic?(WatchBLETransportDiagnosticEventV1(
            attemptID: transportAttemptID,
            sequence: transportDiagnosticSequence,
            kind: kind,
            phase: transportStateMachine.phase.rawValue,
            reason: transportStateMachine.lastFailure?.rawValue,
            connectionGeneration: connectionGeneration,
            queueDepth: queued,
            queueHighWater: min(metrics.highWaterFrames, 64),
            queueBytes: queuedBytes,
            queueHighWaterBytes: min(
                metrics.highWaterBytes,
                64 * WatchBLEOutboundQueueV1.maximumFrameBytes
            ),
            replacedGroups: metrics.replacedGroups,
            rejectedGroups: metrics.rejectedGroups,
            uptimeMs: max(0, Int(
                ProcessInfo.processInfo.systemUptime * 1_000
            )),
            latencyMs: latencyMs
        ))
    }

    private func fail(
        _ message: String,
        reason: RideBLETransportFailureReasonV1 = .connectionFailed
    ) {
        guard transportStateMachine.phase != .recovering else { return }
        let wasScanning = state == .scanning
        lastError = message
        state = .failed(message)
        _ = reduceTransport(.failed(
            generation: transportStateMachine.generation,
            reason: reason
        ))
        recordTransportDiagnostic(kind: .recovery)
        operationTimeoutTask?.cancel()
        operationTimeoutTask = nil
        writerWatchdogTask?.cancel()
        writerWatchdogTask = nil
        withoutResponseWatchdogTask?.cancel()
        withoutResponseWatchdogTask = nil
        applicationAckWatchdogTask?.cancel()
        applicationAckWatchdogTask = nil
        if wasScanning { central.stopScan() }
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            scheduleReconnect()
        }
    }

    private func failAuthentication(_ message: String) {
        if let credential {
            var map = peripheralMap()
            map.removeValue(forKey: credential.deviceID)
            defaults.set(map, forKey: peripheralMapKey)
        }
        fail(message, reason: .authenticationFailed)
    }

    private func startOperationTimeout(generation: UInt64) {
        operationTimeoutTask?.cancel()
        operationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self,
                  self.connectionGeneration == generation,
                  !self.state.isReady else { return }
            self.operationTimeoutTask = nil
            self.fail("Bike Computer connection timed out")
        }
    }

    private func scheduleReconnect() {
        guard hasDemand, reconnectTask == nil else { return }
        reconnectAttempt = min(reconnectAttempt + 1, 6)
        let delay = min(pow(2, Double(reconnectAttempt - 1)), 30)
        let generation = connectionGeneration
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(delay)
            )
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            guard self.hasDemand,
                  self.connectionGeneration == generation else { return }
            self.resetTransport(keepingPeripheral: false)
            self.beginIfNeeded()
        }
    }

    private func persistCurrentPeripheral() {
        guard let credential, let peripheral else { return }
        var map = peripheralMap()
        map[credential.deviceID] = peripheral.identifier.uuidString
        defaults.set(map, forKey: peripheralMapKey)
    }

    private func peripheralMap() -> [String: String] {
        defaults.dictionary(forKey: peripheralMapKey) as? [String: String]
            ?? [:]
    }

    private static func randomNonce() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        ) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    private static func advertisedSuffix(
        _ advertisementData: [String: Any]
    ) -> String? {
        guard let data = advertisementData[
            CBAdvertisementDataManufacturerDataKey
        ] as? Data,
              data.count == 8,
              data[0] == 0xFF,
              data[1] == 0xFF,
              data[2] == 2 else { return nil }
        return data.subdata(in: 4..<8).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

extension WatchDeviceLink: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard hasDemand else { return }
        if central.state == .poweredOn {
            beginIfNeeded()
        } else {
            if transportStateMachine.phase != .idle {
                _ = reduceTransport(.failed(
                    generation: transportStateMachine.generation,
                    reason: .radioUnavailable
                ))
                _ = reduceTransport(.disconnected(
                    generation: transportStateMachine.generation
                ))
            }
            state = .bluetoothUnavailable
            resetTransport(keepingPeripheral: false)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        guard hasDemand,
              let restored = (dict[
                CBCentralManagerRestoredStatePeripheralsKey
              ] as? [CBPeripheral])?.first,
              let matched = credentials.first(where: {
                  peripheralMap()[$0.deviceID] == restored.identifier.uuidString
              }) else { return }
        connect(restored, credential: matched)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover candidate: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard state == .scanning,
              let suffix = Self.advertisedSuffix(advertisementData) else {
            return
        }
        let matches = credentials.filter {
            $0.deviceID.hasSuffix(suffix)
        }
        guard matches.count == 1, let matched = matches.first else {
            if matches.count > 1 {
                fail("Two enrolled Bike Computers share an ambiguous code")
            }
            return
        }
        connect(candidate, credential: matched)
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect connected: CBPeripheral
    ) {
        guard peripheral?.identifier == connected.identifier else {
            central.cancelPeripheralConnection(connected)
            return
        }
        _ = reduceTransport(.linkConnected(
            generation: transportStateMachine.generation
        ))
        state = .discovering
        connected.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect failed: CBPeripheral,
        error: Error?
    ) {
        guard peripheral?.identifier == failed.identifier else { return }
        _ = reduceTransport(.failed(
            generation: transportStateMachine.generation,
            reason: .connectionFailed
        ))
        _ = reduceTransport(.disconnected(
            generation: transportStateMachine.generation
        ))
        resetTransport(keepingPeripheral: false)
        state = .failed("Could not connect to Bicino")
        scheduleReconnect()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral disconnected: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        guard peripheral?.identifier == disconnected.identifier else { return }
        if transportStateMachine.phase != .idle {
            _ = reduceTransport(.disconnected(
                generation: transportStateMachine.generation
            ))
        }
        connectionGeneration &+= 1
        resetTransport(keepingPeripheral: false)
        guard hasDemand else {
            disconnectingForBusyLease = false
            state = .idle
            return
        }
        if disconnectingForBusyLease {
            state = .busy
            disconnectingForBusyLease = false
        } else {
            state = .failed("Bicino disconnected")
        }
        scheduleReconnect()
    }
}

extension WatchDeviceLink: @preconcurrency CBPeripheralDelegate {
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier,
              error == nil,
              let service = peripheral.services?.first(where: {
                  $0.uuid == serviceUUID
              }) else {
            fail("Bike Computer navigation service is unavailable")
            return
        }
        peripheral.discoverCharacteristics(
            [
                authUUID,
                navigationUUID,
                routeUUID,
                gpsUUID,
                workoutUUID,
                rideAutomationUUID,
            ],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier,
              error == nil else {
            fail("Bike Computer characteristics are unavailable")
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case authUUID: authCharacteristic = characteristic
            case navigationUUID: navigationCharacteristic = characteristic
            case routeUUID: routeCharacteristic = characteristic
            case gpsUUID: gpsCharacteristic = characteristic
            case workoutUUID: workoutCharacteristic = characteristic
            case rideAutomationUUID:
                rideAutomationCharacteristic = characteristic
            default: break
            }
        }
        guard let authCharacteristic,
              let navigationCharacteristic,
              routeCharacteristic != nil,
              gpsCharacteristic != nil else {
            fail("Bike Computer firmware is missing Watch ride channels")
            return
        }
        peripheral.setNotifyValue(true, for: authCharacteristic)
        peripheral.setNotifyValue(true, for: navigationCharacteristic)
        if let rideAutomationCharacteristic {
            peripheral.setNotifyValue(true, for: rideAutomationCharacteristic)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else {
            return
        }
        guard error == nil, characteristic.isNotifying else {
            fail("Bike Computer notifications could not be enabled")
            return
        }
        if authCharacteristic?.isNotifying == true,
           navigationCharacteristic?.isNotifying == true,
           (rideAutomationCharacteristic == nil
                || rideAutomationCharacteristic?.isNotifying == true) {
            beginAuthentication()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier,
              error == nil,
              let value = characteristic.value else { return }
        if characteristic.uuid == authUUID {
            handleAuthNotification(value)
        } else if characteristic.uuid == navigationUUID {
            handleNavigationNotification(value)
        } else if characteristic.uuid == rideAutomationUUID {
            handleRideAutomationNotification(value)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier,
              let pending = pendingATTWrite,
              pending.peripheralID == peripheral.identifier,
              pending.connectionGeneration == connectionGeneration,
              pending.characteristicID == characteristic.uuid else {
            return
        }
        writerWatchdogTask?.cancel()
        writerWatchdogTask = nil
        pendingATTWrite = nil
        writeWithResponseInFlight = false
        recordTransportDiagnostic(
            kind: .attCompleted,
            latencyMs: max(0, Int((
                ProcessInfo.processInfo.systemUptime -
                    pending.startedAtUptime
            ) * 1_000))
        )
        if error != nil {
            fail("Bike Computer rejected a Watch BLE write")
            return
        }
        _ = reduceTransport(.writerChanged(
            generation: transportStateMachine.generation,
            state: .idle
        ))
        drainQueue()
    }

    func peripheralIsReady(
        toSendWriteWithoutResponse peripheral: CBPeripheral
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else {
            return
        }
        withoutResponseWatchdogTask?.cancel()
        withoutResponseWatchdogTask = nil
        _ = reduceTransport(.writerChanged(
            generation: transportStateMachine.generation,
            state: .idle
        ))
        drainQueue()
    }
}

extension WatchDeviceLink: WatchNavigationDeviceLinking {}

private extension Data {
    func trimmingTrailingTransportBytes() -> Data {
        var end = endIndex
        while end > startIndex {
            let byte = self[index(before: end)]
            guard byte == 0 || byte == 0x0A || byte == 0x0D || byte == 0x20
            else { break }
            end = index(before: end)
        }
        return self[startIndex..<end]
    }
}
