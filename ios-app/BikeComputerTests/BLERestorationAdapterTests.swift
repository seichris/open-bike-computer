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
            manager.installScanDriverForTesting(driver, trustedPeripheralIdentifier: trusted.identifier)
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
                assertEqual(trusted.serviceDiscoveries, 1, "restored connected link discovers once")
                assertEqual(manager.rideTransportPhase, .authenticating, "real didConnect starts authentication")
                let generation = manager.rideConnectionGenerationForTesting
                powerOn(manager, driver, central)
                restore(manager, central, [trusted])
                manager.centralManager(central, didConnect: trusted)
                assertEqual(trusted.serviceDiscoveries, 1, "duplicate callbacks cannot restart discovery")
                assertEqual(manager.rideConnectionGenerationForTesting, generation,
                            "duplicate restoration cannot replace the active generation")
                assert(central.connections.isEmpty && !central.cancellations.contains(trusted.identifier),
                       "a restored connected link needs no extra connect or cancellation")
            case .connecting:
                assert(central.connections.isEmpty, "keep the OS-owned pending connect")
                assertEqual(trusted.serviceDiscoveries, 0, "connecting waits for the real connection callback")
                trusted.state = .connected
                manager.centralManager(central, didConnect: trusted)
                assertEqual(trusted.serviceDiscoveries, 1, "real connect resumes discovery")
            case .disconnected:
                assertEqual(central.connections, [trusted.identifier], "disconnected restoration connects once")
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
            assertEqual(trusted.serviceDiscoveries, 1, "replay observes the now-connected peripheral")
            assert(central.cancellations.isEmpty, "early callback preserves the restored link")
            manager.clearConnectionStateForTesting()
        }

        for invalidatingState in [CBManagerState.poweredOff, .resetting, .unauthorized, .unsupported] {
            let (manager, driver, central, trusted, _) = fixture()
            restore(manager, central, [trusted])
            central.state = invalidatingState
            manager.centralManagerDidUpdateState(central)
            powerOn(manager, driver, central)
            assertEqual(trusted.serviceDiscoveries, 0, "radio invalidation retires the old snapshot")
            assert(central.commands.isEmpty && central.droppedCommands.isEmpty,
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
            assertEqual(trusted.serviceDiscoveries, 1, "already-powered-on restoration runs immediately")
            manager.clearConnectionStateForTesting()
        }
    }
}
#endif
