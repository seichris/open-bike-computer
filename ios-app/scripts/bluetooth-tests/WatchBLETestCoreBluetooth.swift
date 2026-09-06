// Test-only CoreBluetooth module. The host runner puts this module ahead of
// the SDK to drive real WatchDeviceLink delegate methods without a radio.
// No lifecycle, authentication, queue or acknowledgement policy lives here.
import Foundation
@_exported import CoreFoundation

public struct CBUUID: Hashable, Sendable {
    public let uuidString: String
    public init(string: String) { uuidString = string.uppercased() }
}
public struct CBCharacteristicProperties: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let write = Self(rawValue: 1)
    public static let writeWithoutResponse = Self(rawValue: 2)
    public static let notify = Self(rawValue: 4)
}
public enum CBCharacteristicWriteType { case withResponse, withoutResponse }
public enum CBManagerState { case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn }
public let CBCentralManagerOptionRestoreIdentifierKey = "restoreIdentifier"
public let CBCentralManagerScanOptionAllowDuplicatesKey = "allowDuplicates"
public let CBCentralManagerRestoredStatePeripheralsKey = "restoredPeripherals"
public let CBAdvertisementDataManufacturerDataKey = "manufacturerData"

public final class CBCharacteristic {
    public let uuid: CBUUID
    public let properties: CBCharacteristicProperties
    public var isNotifying = false
    public var value: Data?
    public init(uuid: CBUUID, properties: CBCharacteristicProperties = [.write, .notify]) {
        self.uuid = uuid
        self.properties = properties
    }
}
public final class CBService {
    public let uuid: CBUUID
    public var characteristics: [CBCharacteristic]?
    public init(uuid: CBUUID, characteristics: [CBCharacteristic]) {
        self.uuid = uuid
        self.characteristics = characteristics
    }
}
public protocol CBPeripheralDelegate: AnyObject {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?)
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral)
}
public final class CBPeripheral {
    public struct Write {
        public let data: Data
        public let characteristic: CBCharacteristic
        public let type: CBCharacteristicWriteType
    }
    public let identifier: UUID
    public weak var delegate: (any CBPeripheralDelegate)?
    public var services: [CBService]?
    public var canSendWriteWithoutResponse = true
    public var maximumWriteLength = 576
    public private(set) var writes: [Write] = []
    public private(set) var serviceDiscoveryCount = 0
    public private(set) var characteristicDiscoveryCount = 0
    public init(identifier: UUID = UUID()) { self.identifier = identifier }
    public func discoverServices(_ uuids: [CBUUID]?) { serviceDiscoveryCount += 1 }
    public func discoverCharacteristics(_ uuids: [CBUUID]?, for service: CBService) { characteristicDiscoveryCount += 1 }
    public func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) { characteristic.isNotifying = enabled }
    public func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { maximumWriteLength }
    public func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        writes.append(Write(data: data, characteristic: characteristic, type: type))
    }
}
public protocol CBCentralManagerDelegate: AnyObject {
    func centralManagerDidUpdateState(_ central: CBCentralManager)
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any])
    func centralManager(_ central: CBCentralManager, didDiscover candidate: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber)
    func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral)
    func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: Error?)
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral disconnected: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?)
}
public final class CBCentralManager {
    public static var latest: CBCentralManager?
    public static var knownPeripherals: [CBPeripheral] = []
    public weak var delegate: (any CBCentralManagerDelegate)?
    public var state: CBManagerState = .poweredOn
    public private(set) var isScanning = false
    public private(set) var connections: [UUID] = []
    public private(set) var cancellations: [UUID] = []
    public init(delegate: (any CBCentralManagerDelegate)?, queue: DispatchQueue?, options: [String: Any]?) {
        self.delegate = delegate
        Self.latest = self
    }
    public func scanForPeripherals(withServices: [CBUUID]?, options: [String: Any]?) { isScanning = true }
    public func stopScan() { isScanning = false }
    public func retrievePeripherals(withIdentifiers ids: [UUID]) -> [CBPeripheral] {
        Self.knownPeripherals.filter { ids.contains($0.identifier) }
    }
    public func connect(_ peripheral: CBPeripheral) { connections.append(peripheral.identifier) }
    public func cancelPeripheralConnection(_ peripheral: CBPeripheral) { cancellations.append(peripheral.identifier) }
}
