#if BLUETOOTH_RESTORATION_ADAPTER_TESTING
import Foundation
import CoreBluetooth

extension NavigationProtocolTests {
    // The API double drops commands before poweredOn. These tests invoke the
    // production delegate methods, adoption, reducer and discovery calls.
    // They do not qualify Apple's framework or a physical radio.
    static func testBluetoothRestorationAdapter() {
        func fixture(_ state: CBPeripheralState = .connected) -> (
            BLEManager, BLEScanDriverForTesting, CBCentralManager, CBPeripheral, CBPeripheral
        ) {
            let manager = BLEManager()
            let driver = BLEScanDriverForTesting()
            driver.isPoweredOn = false
            let central = CBCentralManager(delegate: manager, queue: nil, options: nil)
            let trusted = CBPeripheral()
            trusted.central = central
            trusted.state = state
            let extra = CBPeripheral()
            extra.central = central
            extra.state = .connected
            central.knownPeripherals = [trusted, extra]
            manager.installScanDriverForTesting(driver, trustedPeripheralIdentifier: trusted.identifier,
                                                shouldAutoReconnect: true)
            manager.installCentralManagerForTesting(central)
            return (manager, driver, central, trusted, extra)
        }
        func restore(_ manager: BLEManager, _ central: CBCentralManager,
                     _ peripherals: [CBPeripheral]) {
            manager.centralManager(central, willRestoreState: [
                CBCentralManagerRestoredStatePeripheralsKey: peripherals
            ])
        }
        func powerOn(_ manager: BLEManager, _ driver: BLEScanDriverForTesting,
                     _ central: CBCentralManager) {
            driver.isPoweredOn = true
            central.state = .poweredOn
            manager.centralManagerDidUpdateState(central)
        }
        func advertise(_ manager: BLEManager, _ central: CBCentralManager,
                       _ peripheral: CBPeripheral) {
            for _ in 0..<20 where !central.isScanning {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            assert(central.isScanning, "fresh trusted scan remains active while awaiting physical teardown")
            manager.centralManager(central, didDiscover: peripheral,
                                   advertisementData: [:], rssi: -50)
        }
        for (yieldingToWatch, error, reason) in [
            (false, nil, "connection_ended"),
            (true, nil, "watch_direct_handoff"),
            (true, NSError(domain: "HostTransport", code: 1), "transport_error"),
        ] as [(Bool, NSError?, String)] {
            let (manager, driver, central, trusted, _) = fixture(.connecting)
            restore(manager, central, [trusted])
            powerOn(manager, driver, central)
            trusted.state = .connected
            manager.centralManager(central, didConnect: trusted)
            manager.installScanDriverForTesting(driver,
                trustedPeripheralIdentifier: trusted.identifier,
                isExclusiveOperationActive: yieldingToWatch)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let recorder = RideDiagnosticsRecorder(rootURL: root)
            manager.diagnosticsRecorder = recorder
            manager.centralManager(central, didDisconnectPeripheral: trusted, error: error)
            recorder.flush()
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects as! [URL]
            let records = files.filter { $0.pathExtension == "jsonl" }.flatMap { file in
                (try! Data(contentsOf: file)).split(separator: 0x0a).compactMap {
                    try? JSONDecoder().decode(RideDiagnosticEvent.self, from: Data($0))
                }
            }
            let disconnect = records.last { $0.event == "transport_disconnected" }
            assertEqual(disconnect?.fields["reason"], reason,
                        "diagnostics distinguish a Watch handoff from an unattributed close or transport error")
            assertEqual(disconnect?.level, error == nil ? .info : .warning,
                        "a Watch handoff must not hide a real transport error")
            manager.clearConnectionStateForTesting()
        }
        for state in [CBPeripheralState.connected, .connecting, .disconnected, .disconnecting] {
            let (manager, driver, central, trusted, extra) = fixture(state)
            restore(manager, central, [trusted, extra])
            assert(central.commands.isEmpty && central.droppedCommands.isEmpty,
                   "willRestoreState must not issue platform commands before poweredOn")
            assertEqual(manager.rideTransportPhase, .idle,
                        "restoration cannot start authentication before readiness")
            assert(manager.hasActiveTransportSession,
                   "pending restoration reserves the connection against competing reconnects")
            manager.reconnectToLastDevice()
            manager.centralManagerDidUpdateState(central) // Initial unknown is not radio loss.
            powerOn(manager, driver, central)
            assertEqual(central.droppedCommands.count, 0, "no platform operation was lost")
            assertEqual(central.cancellations.filter { $0 == extra.identifier }.count, 1,
                        "rejected restored links are cancelled when the radio is ready")
            switch state {
            case .connected:
                assertEqual(trusted.serviceDiscoveries, 0, "old secure session cannot accept a fresh plaintext handshake")
                assertEqual(central.cancellations.filter { $0 == trusted.identifier }.count, 1,
                            "retained secure link is retired once at readiness")
                assertEqual(manager.rideTransportPhase, .recovering, "wait for confirmed teardown")
                let generation = manager.rideConnectionGenerationForTesting
                powerOn(manager, driver, central)
                restore(manager, central, [trusted])
                assertEqual(central.cancellations.filter { $0 == trusted.identifier }.count, 1,
                            "duplicate readiness/restoration cannot restart cancellation")
                assert(central.connections.isEmpty, "never reconnect before the disconnect callback")
                trusted.state = .disconnected
                manager.centralManager(central, didDisconnectPeripheral: trusted, error: nil)
                assert(central.connections.isEmpty, "local disconnect does not prove physical teardown")
                manager.reconnectToLastDevice()
                manager.reconnect()
                assert(central.connections.isEmpty && trusted.serviceDiscoveries == 0,
                       "cached and manual reconnect cannot bypass the physical advertisement barrier")
                advertise(manager, central, trusted)
                assertEqual(central.connections, [trusted.identifier], "fresh advertisement admits the new connection")
                assert(manager.rideConnectionGenerationForTesting > generation,
                       "fresh session uses a new generation")
                trusted.state = .connected
                manager.centralManager(central, didConnect: trusted)
                assertEqual(manager.rideTransportPhase, .authenticating, "real new connection starts authentication")
                let freshGeneration = manager.rideConnectionGenerationForTesting
                manager.centralManager(central, didConnect: trusted)
                assertEqual(trusted.serviceDiscoveries, 1, "duplicate callbacks cannot restart discovery")
                assertEqual(manager.rideConnectionGenerationForTesting, freshGeneration,
                            "duplicate restoration cannot replace the active generation")
            case .connecting:
                assert(central.connections.isEmpty, "keep the OS-owned pending connect")
                assertEqual(trusted.serviceDiscoveries, 0, "connecting waits for the real connection callback")
                trusted.state = .connected
                manager.centralManager(central, didConnect: trusted)
                assertEqual(trusted.serviceDiscoveries, 1, "real connect resumes discovery")
            case .disconnected:
                assert(central.connections.isEmpty, "disconnected restoration does not assume cached link is fresh")
                advertise(manager, central, trusted)
                assertEqual(central.connections, [trusted.identifier], "advertising disconnected restoration connects once")
                trusted.state = .connected
                manager.centralManager(central, didConnect: trusted)
                assertEqual(trusted.serviceDiscoveries, 1, "new connection discovers once")
            case .disconnecting:
                assertEqual(central.cancellations.filter { $0 == trusted.identifier }.count, 1,
                            "disconnecting restoration retires through bounded recovery")
            }
            manager.clearConnectionStateForTesting()
        }

        do {
            let (manager, driver, central, trusted, _) = fixture(.connecting)
            restore(manager, central, [trusted])
            trusted.state = .connected
            manager.centralManager(central, didConnect: trusted)
            assert(central.commands.isEmpty && central.droppedCommands.isEmpty,
                   "early restored didConnect cannot cancel or discover before readiness")
            powerOn(manager, driver, central)
            assertEqual(trusted.serviceDiscoveries, 0, "replay observes and retires the retained secure link")
            assertEqual(central.cancellations, [trusted.identifier], "early callback is retired only after readiness")
            manager.clearConnectionStateForTesting()
        }

        for invalidatingState in [CBManagerState.poweredOff, .resetting, .unauthorized, .unsupported] {
            let (manager, driver, central, trusted, _) = fixture()
            restore(manager, central, [trusted])
            central.state = invalidatingState
            manager.centralManagerDidUpdateState(central)
            powerOn(manager, driver, central)
            assertEqual(trusted.serviceDiscoveries, 0, "radio invalidation retires the old snapshot")
            assert(central.connections.isEmpty && central.cancellations.isEmpty && central.droppedCommands.isEmpty,
                   "invalidated peripherals receive no later operations")
            manager.clearConnectionStateForTesting()
        }
        do {
            let (manager, driver, central, trusted, _) = fixture()
            restore(manager, central, [trusted])
            manager.clearConnectionStateForTesting()
            powerOn(manager, driver, central)
            assertEqual(trusted.serviceDiscoveries, 0, "explicit cleanup retires deferred restoration")
        }
        for watchOwnsConnection in [false, true] {
            let (manager, driver, central, trusted, extra) = fixture()
            restore(manager, central, [trusted, extra])
            manager.installScanDriverForTesting(driver,
                trustedPeripheralIdentifier: watchOwnsConnection ? trusted.identifier : UUID(),
                isExclusiveOperationActive: watchOwnsConnection)
            powerOn(manager, driver, central)
            assertEqual(Set(central.cancellations), Set([trusted.identifier, extra.identifier]),
                        "current trust and Watch ownership are checked when replay executes")
            assertEqual(trusted.serviceDiscoveries, 0, "an ineligible restored link never discovers")
            assert(central.connections.isEmpty && central.droppedCommands.isEmpty,
                   "rejected links cannot start a phone connection")
            manager.clearConnectionStateForTesting()
        }
        do {
            let (manager, driver, central, trusted, _) = fixture()
            driver.isPoweredOn = true
            central.state = .poweredOn
            restore(manager, central, [trusted])
            assertEqual(central.cancellations, [trusted.identifier], "already-powered-on restoration retires immediately")
            assertEqual(trusted.serviceDiscoveries, 0, "no plaintext handshake on a retained session")
            manager.clearConnectionStateForTesting()
        }
    }
}
#endif
