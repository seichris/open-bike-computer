// Host-only API double. Never linked into the app; no radio or Apple SDK claim.
import Foundation
public typealias CFAbsoluteTime = Double
public let CBCentralManagerOptionRestoreIdentifierKey = "restore"
public let CBCentralManagerScanOptionAllowDuplicatesKey = "duplicates"
public let CBCentralManagerRestoredStatePeripheralsKey = "peripherals"
public let CBAdvertisementDataLocalNameKey = "localName"
public let CBAdvertisementDataManufacturerDataKey = "manufacturer"
public enum CBManagerState { case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn }
public struct CBUUID: Hashable, Sendable {
    public let uuidString: String
    public init(string: String) { uuidString = string }
}
public struct CBCharacteristicProperties: OptionSet, Sendable, CustomDebugStringConvertible {
    public var debugDescription: String { String(rawValue) }
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let broadcast = Self(rawValue: 1)
    public static let read = Self(rawValue: 2)
    public static let writeWithoutResponse = Self(rawValue: 4)
    public static let write = Self(rawValue: 8)
    public static let notify = Self(rawValue: 16)
    public static let indicate = Self(rawValue: 32)
    public static let authenticatedSignedWrites = Self(rawValue: 64)
    public static let extendedProperties = Self(rawValue: 128)
    public static let notifyEncryptionRequired = Self(rawValue: 256)
    public static let indicateEncryptionRequired = Self(rawValue: 512)
}
public enum CBPeripheralState: Int { case disconnected, connecting, connected, disconnecting }
public enum CBCharacteristicWriteType { case withResponse, withoutResponse }
@objc public protocol CBCentralManagerDelegate: AnyObject {
    func centralManagerDidUpdateState(_ central: CBCentralManager)
}
public protocol CBPeripheralDelegate: AnyObject {}
public final class CBCharacteristic {
    public let uuid: CBUUID
    public var properties: CBCharacteristicProperties
    public var isNotifying = false
    public var value: Data?
    public init(_ id: String, properties: CBCharacteristicProperties = .write) {
        uuid = CBUUID(string: id); self.properties = properties
    }
}
public final class CBService {
    public let uuid: CBUUID
    public var characteristics: [CBCharacteristic]?
    public init(_ id: String, characteristics: [CBCharacteristic]? = nil) {
        uuid = CBUUID(string: id); self.characteristics = characteristics
    }
}
public final class CBPeripheral {
    public struct Write { public let data: Data; public let characteristic: CBCharacteristic; public let type: CBCharacteristicWriteType }
    public var name: String? = "Host bike"
    public var state: CBPeripheralState = .disconnected
    public weak var central: CBCentralManager?
    public let identifier: UUID
    public weak var delegate: CBPeripheralDelegate?
    public var services: [CBService]?
    public var canSendWriteWithoutResponse = true
    public private(set) var writes: [Write] = []
    public private(set) var serviceDiscoveries = 0
    public private(set) var characteristicDiscoveries = 0
    public init(identifier: UUID = UUID()) { self.identifier = identifier }
    public func discoverServices(_ ids: [CBUUID]?) {
        guard central?.record("discoverServices") == true else { return }
        serviceDiscoveries += 1
    }
    public func readValue(for characteristic: CBCharacteristic) {}
    public func readRSSI() {}
    public func discoverCharacteristics(_ ids: [CBUUID]?, for service: CBService) { characteristicDiscoveries += 1 }
    public func setNotifyValue(_ value: Bool, for characteristic: CBCharacteristic) { characteristic.isNotifying = value }
    public func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 1024 }
    public func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        writes.append(Write(data: data, characteristic: characteristic, type: type))
    }
}
public final class CBCentralManager: NSObject {
    public weak var delegate: CBCentralManagerDelegate?
    public var state: CBManagerState = .unknown
    public private(set) var commands: [String] = []
    public private(set) var droppedCommands: [String] = []
    @discardableResult public func record(_ command: String) -> Bool {
        guard state == .poweredOn else { droppedCommands.append(command); return false }
        commands.append(command); return true
    }
    public var knownPeripherals: [CBPeripheral] = []
    public private(set) var connections: [UUID] = []
    public private(set) var cancellations: [UUID] = []
    public private(set) var scans = 0
    public private(set) var isScanning = false
    public init(delegate: CBCentralManagerDelegate?, queue: DispatchQueue?, options: [String: Any]?) { self.delegate = delegate }
    public func scanForPeripherals(withServices: [CBUUID]?, options: [String: Any]?) { scans += 1; isScanning = true }
    public func stopScan() { if record("stopScan") { isScanning = false } }
    public func retrievePeripherals(withIdentifiers ids: [UUID]) -> [CBPeripheral] { knownPeripherals.filter { ids.contains($0.identifier) } }
    public func connect(_ peripheral: CBPeripheral, options: [String: Any]? = nil) {
        if record("connect") { connections.append(peripheral.identifier) }
    }
    public func cancelPeripheralConnection(_ peripheral: CBPeripheral) {
        if record("cancel") { cancellations.append(peripheral.identifier) }
    }
}
