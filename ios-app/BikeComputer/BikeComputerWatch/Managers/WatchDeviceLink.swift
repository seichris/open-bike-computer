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
    private lazy var central = CBCentralManager(
        delegate: self,
        queue: .main,
        options: [
            CBCentralManagerOptionRestoreIdentifierKey:
                "com.openbikecomputer.watch.direct-ble.v1",
        ]
    )

    private var navigationDemand = false
    private var workoutDemand = false
    private var credentials: [WatchControllerCredentialV1] = []
    private var credential: WatchControllerCredentialV1?
    private var peripheral: CBPeripheral?
    private var authCharacteristic: CBCharacteristic?
    private var navigationCharacteristic: CBCharacteristic?
    private var routeCharacteristic: CBCharacteristic?
    private var gpsCharacteristic: CBCharacteristic?
    private var workoutCharacteristic: CBCharacteristic?
    private var authentication: WatchScopedAuthenticationV1?
    private var challenge: WatchScopedAuthenticationChallengeV1?
    private var protectedSession: WatchAuthenticatedBLESessionV1?
    private var capabilities: WatchDeviceCapabilitiesV1?
    private var connectionGeneration: UInt64 = 0
    private var queue = WatchBLEOutboundQueueV1(capacity: 32)
    private var writeWithResponseInFlight = false
    private var heartbeatTimer: Timer?
    private var reconnectTask: Task<Void, Never>?
    private var operationTimeoutTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var disconnectingForBusyLease = false
    private var navigationReleasePending = false

    private var latestWorkoutFrames: WorkoutDeviceFrames?
    private var workoutPairGeneration: UInt8 = 0
    private var latestLocation: NavigationLocationSampleV1?
    private var latestNavigationSnapshot: NavigationSnapshotV1?
    private var latestRouteWindow = Data()

    private let peripheralMapKey =
        "watchDeviceLink.peripheralByDeviceID.v1"

    init(
        credentialStore: WatchControllerCredentialStore,
        defaults: UserDefaults = .standard
    ) {
        self.credentialStore = credentialStore
        self.defaults = defaults
        super.init()
    }

    func setDemand(navigation: Bool, workout: Bool) {
        navigationDemand = navigation
        workoutDemand = workout
        reconcileDemand()
    }

    func setNavigationDemand(_ active: Bool) {
        navigationDemand = active
        reconcileDemand()
    }

    func setWorkoutDemand(_ active: Bool) {
        workoutDemand = active
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
        credentials = refreshed
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
        if refreshed.isEmpty {
            state = .notEnrolled
        } else if !state.isReady {
            beginIfNeeded()
        }
    }

    private func reconcileDemand() {
        guard hasDemand else {
            if navigationReleasePending {
                finishNavigationReleaseIfPossible()
                return
            }
            stop()
            return
        }
        beginIfNeeded()
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
        _ = queue.enqueue(.init(
            target: .route,
            payload: Data(),
            priority: 2,
            coalescingKey: "route"
        ))
        _ = queue.enqueue(.init(
            target: .navigation,
            payload: WatchRidePacketEncoderV1.maneuver(nil),
            priority: 3
        ))
        drainQueue()
    }

    func endNavigationDemandAfterClearing() {
        navigationDemand = false
        guard state.isReady else {
            reconcileDemand()
            return
        }
        navigationReleasePending = true
        clearNavigation()
        finishNavigationReleaseIfPossible()
    }

    func updateWorkout(_ frames: WorkoutDeviceFrames) {
        latestWorkoutFrames = frames
        guard state.isReady else { return }
        enqueueWorkoutFrames(frames)
        drainQueue()
    }

    func clearWorkout(_ frames: WorkoutDeviceFrames) {
        updateWorkout(frames)
    }

    private var hasDemand: Bool {
        navigationDemand || workoutDemand
    }

    private struct CredentialIdentity: Hashable {
        let deviceID: String
        let controllerID: Data
    }

    private func beginIfNeeded() {
        guard hasDemand, !state.isReady else { return }
        switch state {
        case .scanning, .connecting, .discovering, .authenticating,
                .claimingLease:
            return
        default:
            break
        }
        do {
            credentials = try credentialStore.allActiveCredentials()
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

    private func startScan() {
        guard hasDemand, central.state == .poweredOn else { return }
        state = .scanning
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func connect(
        _ candidate: CBPeripheral,
        credential: WatchControllerCredentialV1
    ) {
        central.stopScan()
        resetTransport(keepingPeripheral: false)
        connectionGeneration &+= 1
        self.credential = credential
        peripheral = candidate
        candidate.delegate = self
        state = .connecting
        central.connect(candidate)
        startOperationTimeout(generation: connectionGeneration)
    }

    private func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        operationTimeoutTask?.cancel()
        operationTimeoutTask = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        disconnectingForBusyLease = false
        navigationReleasePending = false
        if state.isReady {
            writeProtectedAuth("LEASE_RELEASE")
        }
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        connectionGeneration &+= 1
        resetTransport(keepingPeripheral: false)
        state = .idle
        lastError = nil
    }

    private func resetTransport(keepingPeripheral: Bool) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
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
        writeWithResponseInFlight = false
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
                requestCapabilities()
            }
        case "LEASE_RELEASED":
            break
        case "ERROR|lease_busy":
            state = .busy
            lastError = "Bicino is controlled by iPhone"
            disconnectingForBusyLease = true
            if let peripheral {
                central.cancelPeripheralConnection(peripheral)
            }
        case "ERROR|lease_not_held", "ERROR|lease_rejected":
            fail("Bike Computer ride lease was lost")
        default:
            break
        }
    }

    private func requestCapabilities() {
        var request = Data("CAPS".utf8)
        request.append(WatchDirectBLEProtocolV1.capabilityClientVersion)
        enqueueProtected(
            target: .navigation,
            payload: request,
            priority: 0,
            coalescingKey: "capabilities"
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
        guard let capabilities = WatchDeviceCapabilitiesV1.decode(payload),
              capabilities.supportsScopedController else {
            fail("Bike Computer firmware does not support Watch navigation")
            return
        }
        if workoutDemand {
            guard capabilities.supportsWorkoutTelemetry,
                  workoutCharacteristic != nil else {
                fail("Bike Computer firmware lacks Watch workout telemetry")
                return
            }
        }
        self.capabilities = capabilities
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

    private func enqueueFullResynchronization() {
        queue.removeAll()
        if let latestWorkoutFrames {
            enqueueWorkoutFrames(latestWorkoutFrames)
        }
        if let latestLocation {
            _ = queue.enqueue(.init(
                target: .gps,
                payload: WatchRidePacketEncoderV1.gps(
                    latestLocation,
                    snapshot: latestNavigationSnapshot
                ),
                priority: 1,
                coalescingKey: "gps"
            ))
        }
        _ = queue.enqueue(.init(
            target: .route,
            payload: latestRouteWindow,
            priority: 2,
            coalescingKey: "route"
        ))
        _ = queue.enqueue(.init(
            target: .navigation,
            payload: WatchRidePacketEncoderV1.maneuver(
                latestNavigationSnapshot
            ),
            priority: 3
        ))
    }

    private func enqueueLiveNavigation(
        location: NavigationLocationSampleV1,
        snapshot: NavigationSnapshotV1,
        previousSnapshot: NavigationSnapshotV1?
    ) {
        _ = queue.enqueue(.init(
            target: .gps,
            payload: WatchRidePacketEncoderV1.gps(
                location,
                snapshot: snapshot
            ),
            priority: 1,
            coalescingKey: "gps"
        ))
        _ = queue.enqueue(.init(
            target: .route,
            payload: snapshot.routeWindow,
            priority: 2,
            coalescingKey: "route"
        ))
        if Self.shouldSendManeuver(
            snapshot,
            after: previousSnapshot
        ) {
            _ = queue.enqueue(.init(
                target: .navigation,
                payload: WatchRidePacketEncoderV1.maneuver(snapshot),
                priority: 3
            ))
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
        queue.removeAll(target: .workout)
        workoutPairGeneration = workoutPairGeneration == 3
            ? 1
            : workoutPairGeneration + 1
        let payloads = WorkoutDeviceFrameBuilder.transportFrames(
            for: frames,
            generation: workoutPairGeneration
        )
        for payload in payloads {
            _ = queue.enqueue(.init(
                target: .workout,
                payload: payload,
                priority: 0
            ))
        }
    }

    private func enqueueProtected(
        target: WatchBLEOutboundTargetV1,
        payload: Data,
        priority: UInt8,
        coalescingKey: String? = nil
    ) {
        guard queue.enqueue(.init(
            target: target,
            payload: payload,
            priority: priority,
            coalescingKey: coalescingKey
        )) else {
            fail("Watch BLE queue is full")
            return
        }
    }

    private func drainQueue() {
        guard protectedSession != nil,
              let peripheral,
              !writeWithResponseInFlight else { return }
        while let write = queue.dequeue() {
            guard let characteristic = characteristic(for: write.target),
                  let session = protectedSession else {
                fail("Bike Computer characteristic disappeared")
                return
            }
            let frame: Data
            do {
                frame = try session.frame(
                    payload: write.payload,
                    channel: write.target.channel
                )
            } catch {
                fail("Could not protect Watch ride data")
                return
            }
            let writeType: CBCharacteristicWriteType
            if characteristic.properties.contains(.write) {
                writeType = .withResponse
            } else if characteristic.properties.contains(
                .writeWithoutResponse
            ) {
                guard peripheral.canSendWriteWithoutResponse else {
                    _ = queue.enqueue(write)
                    return
                }
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
            peripheral.writeValue(
                frame,
                for: characteristic,
                type: writeType
            )
            if writeType == .withResponse { return }
        }
        finishNavigationReleaseIfPossible()
    }

    private func finishNavigationReleaseIfPossible() {
        guard navigationReleasePending,
              queue.isEmpty,
              !writeWithResponseInFlight else { return }
        navigationReleasePending = false
        if !hasDemand {
            stop()
        }
    }

    private func characteristic(
        for target: WatchBLEOutboundTargetV1
    ) -> CBCharacteristic? {
        switch target {
        case .navigation: navigationCharacteristic
        case .route: routeCharacteristic
        case .gps: gpsCharacteristic
        case .workout: workoutCharacteristic
        }
    }

    private func writeRawAuth(_ message: String) {
        guard let data = message.data(using: .utf8),
              let peripheral,
              let authCharacteristic else {
            fail("Watch auth characteristic is unavailable")
            return
        }
        let type: CBCharacteristicWriteType =
            authCharacteristic.properties.contains(.write)
                ? .withResponse
                : .withoutResponse
        guard data.count <= peripheral.maximumWriteValueLength(for: type) else {
            fail("Watch auth command exceeds the BLE write limit")
            return
        }
        peripheral.writeValue(data, for: authCharacteristic, type: type)
    }

    private func writeProtectedAuth(_ message: String) {
        guard let session = protectedSession,
              let data = message.data(using: .utf8),
              let peripheral,
              let authCharacteristic else { return }
        do {
            let frame = try session.frame(payload: data, channel: .auth)
            let type: CBCharacteristicWriteType =
                authCharacteristic.properties.contains(.write)
                    ? .withResponse
                    : .withoutResponse
            guard frame.count <= peripheral.maximumWriteValueLength(
                for: type
            ) else {
                fail("Protected Watch auth command is too large")
                return
            }
            peripheral.writeValue(frame, for: authCharacteristic, type: type)
        } catch {
            fail("Could not protect Watch auth command")
        }
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

    private func fail(_ message: String) {
        lastError = message
        state = .failed(message)
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
        fail(message)
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
        state = .discovering
        connected.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect failed: CBPeripheral,
        error: Error?
    ) {
        guard peripheral?.identifier == failed.identifier else { return }
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
           navigationCharacteristic?.isNotifying == true {
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
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else {
            return
        }
        if error != nil {
            fail("Bike Computer rejected a Watch BLE write")
            return
        }
        if characteristic.uuid != authUUID {
            writeWithResponseInFlight = false
            drainQueue()
        }
    }

    func peripheralIsReady(
        toSendWriteWithoutResponse peripheral: CBPeripheral
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else {
            return
        }
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
