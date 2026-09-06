// Appended to a temporary copy of the COMPLETE production WatchDeviceLink.swift
// by the host runner. This file exposes fixtures/observations at the adapter's
// authenticated ingress boundary; it does not implement lifecycle decisions.
// No test-only access is compiled into the app target.

extension WatchDeviceLink {
    func testSeedReady(
        peripheral: CBPeripheral,
        credential: WatchControllerCredentialV1,
        preparationID: UUID,
        navigation: Bool = true,
        workout: Bool = false
    ) throws {
        self.credential = credential
        credentials = [credential]
        selectedBikeComputerEnvelope = try WatchSelectedBikeComputerV1(
            revision: 1, deviceID: credential.deviceID
        )
        defaults.set(
            try selectedBikeComputerEnvelope!.encoded(),
            forKey: selectedBikeComputerKey
        )
        self.peripheral = peripheral
        peripheral.delegate = self
        CBCentralManager.knownPeripherals = [peripheral]
        _ = central
        installTestCharacteristics()
        demand.setNavigationActive(navigation)
        demand.setWorkoutActive(workout)
        connectionGeneration &+= 1
        _ = reduceTransport(.beginConnection)
        testNegotiateReady()
        // The fixture starts after the initial resynchronization has drained.
        queue.removeAll()
        activeWriteGroup = nil
        activeWriteIndex = 0
        pendingATTWrite = nil
        writeWithResponseInFlight = false
        writerWatchdogTask?.cancel()
        writerWatchdogTask = nil
        preparedPhoneDeviceID = credential.deviceID
        preparedPhonePreparationID = preparationID
        phonePreparationAccepted = true
        persistPhonePreparationIntent(operation: .prepare)
    }

    private func installTestCharacteristics() {
        authCharacteristic = CBCharacteristic(uuid: authUUID)
        navigationCharacteristic = CBCharacteristic(uuid: navigationUUID)
        routeCharacteristic = CBCharacteristic(uuid: routeUUID)
        gpsCharacteristic = CBCharacteristic(uuid: gpsUUID)
        workoutCharacteristic = CBCharacteristic(uuid: workoutUUID)
        rideAutomationCharacteristic = CBCharacteristic(uuid: rideAutomationUUID)
    }

    func testNegotiateReady() {
        installTestCharacteristics()
        let generation = transportStateMachine.generation
        _ = reduceTransport(.linkConnected(generation: generation))
        _ = reduceTransport(.authenticated(generation: generation))
        _ = reduceTransport(.leaseAccepted(generation: generation, leaseGeneration: 7))
        let credential = self.credential!
        protectedSession = WatchAuthenticatedBLESessionV1(
            controllerKey: credential.key,
            deviceID: credential.deviceID,
            controllerIDHex: credential.controllerIDHex,
            clientNonceHex: String(format: "%032llx", connectionGeneration),
            serverNonceHex: String(repeating: "2", count: 32)
        )
        testCapabilities()
    }

    func testCapabilities() {
        // A valid, already-authenticated CAP2 payload with all optional flags.
        // Authentication/encryption is independently covered by RideSharedTests.
        handleAuthenticatedNavigationPayload(
            Data("CAP2".utf8) + Data([1, 255, 255, 255, 255])
        )
    }

    func testLeaseReleased() { handleProtectedAuthMessage("LEASE_RELEASED") }
    func testFailWriter() { fail("Injected ATT timeout", reason: .attTimeout) }
    var testGeneration: UInt64 { connectionGeneration }
    var testHasDemand: Bool { hasDemand }
    var testNavigationDemand: Bool { demand.navigationActive }
    var testWorkoutDemand: Bool { demand.workoutActive }
    var testHasReconnect: Bool { reconnectTask != nil }
    var testPreparationID: UUID? { preparedPhonePreparationID }
    var testPreparationAccepted: Bool { phonePreparationAccepted }
    var testHasHeartbeat: Bool { heartbeatTimer != nil }
    var testWriterState: RideBLEWriterStateV1 { transportStateMachine.writerState }
    var testHasATTWrite: Bool { pendingATTWrite != nil }
    var testHasApplicationAck: Bool { pendingApplicationAckGroup != nil }
    var testLatestSnapshot: NavigationSnapshotV1? { latestNavigationSnapshot }
    var testLatestWorkoutState: WorkoutDeviceSessionState? { latestWorkoutFrames?.identity.state }

    var testLogicalWrites: [WatchBLEOutboundWriteV1] {
        var result = activeWriteGroup?.writes ?? []
        var copy = queue
        while let group = copy.dequeueGroup() { result += group.writes }
        return result
    }

    func testATTCompletion(error: Error? = nil) {
        guard let peripheral, let pendingATTWrite,
              let characteristic = [authCharacteristic, navigationCharacteristic,
                  routeCharacteristic, gpsCharacteristic, workoutCharacteristic,
                  rideAutomationCharacteristic].compactMap({ $0 }).first(where: {
                      $0.uuid == pendingATTWrite.characteristicID
                  }) else { return }
        self.peripheral(peripheral, didWriteValueFor: characteristic, error: error)
    }

    func testApplicationAcknowledgement() {
        guard let group = pendingApplicationAckGroup ?? activeWriteGroup,
              let type = group.applicationCommandType else { return }
        handleApplicationAcknowledgement(.init(
            commandType: type,
            result: .success,
            commandID: group.commandID,
            stateGeneration: group.stateGeneration,
            leaseGeneration: 7
        ))
    }

    func testDispose() {
        reconnectTask?.cancel()
        phonePreparationRetryTask?.cancel()
        phonePreparationResponseTimeoutTask?.cancel()
        resetTransport(keepingPeripheral: false)
    }
}
