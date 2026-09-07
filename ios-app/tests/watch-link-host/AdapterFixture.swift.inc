// Appended only to a temporary compiler input, never included in app sources.
// The fixture starts at an authenticated/leased boundary; every tested stop,
// demand update, ACK, disconnect, radio event and timeout executes production code.
extension WatchDeviceLink {
    func testStartReady(preparationID: UUID, appACK: Bool = true) -> CBPeripheral {
        let peer = CBPeripheral()
        central.knownPeripherals = [peer]
        selectedBikeComputerEnvelope = .init(revision: 1, deviceID: "00112233445566778899aabbccddeeff")
        credential = WatchControllerCredentialV1()
        credentials = [credential!]
        peripheral = peer
        peer.delegate = self
        defaults.set(["00112233445566778899aabbccddeeff": peer.identifier.uuidString], forKey: peripheralMapKey)
        authCharacteristic = CBCharacteristic(WatchDirectBLEProtocolV1.authUUID)
        navigationCharacteristic = CBCharacteristic(WatchDirectBLEProtocolV1.navigationUUID)
        routeCharacteristic = CBCharacteristic(WatchDirectBLEProtocolV1.routeUUID)
        gpsCharacteristic = CBCharacteristic(WatchDirectBLEProtocolV1.gpsUUID)
        workoutCharacteristic = CBCharacteristic(WatchDirectBLEProtocolV1.workoutUUID)
        rideAutomationCharacteristic = CBCharacteristic(WatchDirectBLEProtocolV1.rideAutomationUUID)
        peer.services = [CBService(WatchDirectBLEProtocolV1.serviceUUID, characteristics: [
            authCharacteristic!, navigationCharacteristic!, routeCharacteristic!,
            gpsCharacteristic!, workoutCharacteristic!, rideAutomationCharacteristic!
        ])]
        protectedSession = WatchAuthenticatedBLESessionV1()
        connectionGeneration = 1
        _ = reduceTransport(.beginConnection)
        _ = reduceTransport(.linkConnected(generation: transportStateMachine.generation))
        _ = reduceTransport(.authenticated(generation: transportStateMachine.generation))
        _ = reduceTransport(.leaseAccepted(generation: transportStateMachine.generation, leaseGeneration: 1))
        _ = reduceTransport(.capabilitiesAccepted(generation: transportStateMachine.generation, schemaVersion: 1))
        capabilities = .init(featureFlags: Self.testFlags(appACK: appACK))
        state = .ready(deviceID: "00112233445566778899aabbccddeeff")
        demand.setNavigationActive(true)
        preparedPhoneDeviceID = "00112233445566778899aabbccddeeff"
        preparedPhonePreparationID = preparationID
        phonePreparationAccepted = true
        persistPhonePreparationIntent(operation: .prepare)
        return peer
    }
    static func testFlags(appACK: Bool = true) -> UInt32 {
        WatchDirectBLEProtocolV1.scopedControllerFeature |
        WatchDirectBLEProtocolV1.workoutTelemetryFeature |
        WatchDirectBLEProtocolV1.rideAutomationFeature |
        (appACK ? WatchDirectBLEProtocolV1.rideDeliveryAcknowledgementFeature : 0)
    }
    var testCentral: CBCentralManager { central }
    var testDemand: WatchRideDemandStateV1 { demand }
    var testPreparationID: UUID? { preparedPhonePreparationID }
    var testPreparationAccepted: Bool { phonePreparationAccepted }
    var testQueued: Int { queue.pendingFrameCount }
    var testHeartbeat: Bool { heartbeatTimer != nil }
    var testGeneration: UInt64 { connectionGeneration }
    var testReleasePending: Bool { phonePreparationReleasePending }
    var testPendingACK: WatchBLEOutboundGroupV1? { pendingApplicationAckGroup }
    var testWriter: RideBLEWriterStateV1 { transportStateMachine.writerState }
    var testIntent: WatchDirectRidePreparationIntentV1? {
        guard let data = defaults.data(forKey: directRidePreparationIntentKey) else { return nil }
        return try? .decode(data)
    }
    func testAuth(_ message: String, on peer: CBPeripheral) {
        let characteristic = peer.services![0].characteristics!.first { $0.uuid == authUUID }!
        characteristic.value = Data([0x52, 0x32]) + Data(message.utf8)
        self.peripheral(peer, didUpdateValueFor: characteristic, error: nil)
    }
    func testNavigationPayload(_ payload: Data, on peer: CBPeripheral) {
        let characteristic = peer.services![0].characteristics!.first { $0.uuid == navigationUUID }!
        characteristic.value = Data([0x52, 0x32]) + payload
        self.peripheral(peer, didUpdateValueFor: characteristic, error: nil)
    }
    func testCapabilities(on peer: CBPeripheral) {
        var payload = Data("CAP2".utf8); payload.append(1); payload.appendUInt32LE(Self.testFlags())
        testNavigationPayload(payload, on: peer)
    }
    func testATT(on peer: CBPeripheral, error: Error? = nil) {
        guard let pending = pendingATTWrite,
              let characteristic = peer.services![0].characteristics!.first(where: { $0.uuid == pending.characteristicID }) else { return }
        self.peripheral(peer, didWriteValueFor: characteristic, error: error)
    }
    func testDrainATT(on peer: CBPeripheral) {
        for _ in 0..<100 {
            guard pendingATTWrite != nil else { return }
            testATT(on: peer)
        }
        preconditionFailure("Unbounded ATT drain in test")
    }
    func testDrop(_ peer: CBPeripheral) {
        centralManager(central, didDisconnectPeripheral: peer, timestamp: 0, isReconnecting: false, error: nil)
    }
    func testRadio(_ state: CBManagerState) {
        central.state = state
        centralManagerDidUpdateState(central)
    }
    func testWriterFailure() { fail("test timeout", reason: .attTimeout) }
    func testAcknowledge(_ group: WatchBLEOutboundGroupV1, on peer: CBPeripheral, generation: UInt32? = nil) {
        testNavigationPayload(RideBLEApplicationAcknowledgementV1(
            commandType: group.applicationCommandType!, result: .success,
            commandID: group.commandID, stateGeneration: generation ?? group.stateGeneration,
            leaseGeneration: 1
        ).encoded(), on: peer)
    }
    var testActiveGroup: WatchBLEOutboundGroupV1? { activeWriteGroup }
    func testFinishReconnect(_ peer: CBPeripheral) {
        centralManager(central, didConnect: peer)
        self.peripheral(peer, didDiscoverServices: nil)
        self.peripheral(peer, didDiscoverCharacteristicsFor: peer.services![0], error: nil)
        let auth = peer.services![0].characteristics!.first { $0.uuid == authUUID }!
        self.peripheral(peer, didUpdateNotificationStateFor: auth, error: nil)
        testDrainATT(on: peer)
        auth.value = Data("WS2|test".utf8)
        self.peripheral(peer, didUpdateValueFor: auth, error: nil)
        testDrainATT(on: peer)
        auth.value = Data("WOK2|test".utf8)
        self.peripheral(peer, didUpdateValueFor: auth, error: nil)
        testDrainATT(on: peer)
        testAuth("LEASE_OK", on: peer)
        testDrainATT(on: peer)
        testCapabilities(on: peer)
        testDrainATT(on: peer)
    }
    func testDispose() {
        reconnectTask?.cancel(); operationTimeoutTask?.cancel()
        leaseReleaseAckTask?.cancel(); writerWatchdogTask?.cancel()
        withoutResponseWatchdogTask?.cancel(); applicationAckWatchdogTask?.cancel()
        phonePreparationRetryTask?.cancel(); phonePreparationResponseTimeoutTask?.cancel()
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
    }
}
