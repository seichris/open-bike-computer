//
//  BLEManager.swift
//  BikeComputer
//
//  BLE Manager for connecting to ESP32 Bike Computer
//  Service UUID: 1819 (Navigation Service)
//

import Foundation
import Combine
import CoreBluetooth

class BLEManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var isScanning: Bool = false
    @Published var isConnected: Bool = false
    @Published var peripheralName: String = ""
    @Published var signalStrength: Int = 0
    
    // MARK: - BLE UUIDs (matching ESP32)
    private let serviceUUID = CBUUID(string: "1819")           // Navigation Service
    private let characteristicUUID = CBUUID(string: "2A6E")    // Navigation Data Characteristic
    
    // MARK: - Private Properties
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var navigationCharacteristic: CBCharacteristic?
    
    private var autoReconnect: Bool = true
    private var lastConnectedPeripheralIdentifier: UUID?
    
    // MARK: - Initialization
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - Public Methods
    
    /// Start scanning for bike computer peripheral
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            print("Bluetooth not powered on")
            return
        }
        
        print("Starting BLE scan for service UUID: \(serviceUUID)")
        isScanning = true
        
        // Scan for devices advertising the navigation service
        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
    
    /// Stop scanning
    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        print("BLE scan stopped")
    }
    
    /// Disconnect from current peripheral
    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        
        autoReconnect = false
        centralManager.cancelPeripheralConnection(peripheral)
        print("Disconnecting from peripheral")
    }
    
    /// Send navigation data to ESP32
    func sendNavigationData(_ data: String) {
        guard let peripheral = connectedPeripheral,
              let characteristic = navigationCharacteristic,
              isConnected else {
            print("Cannot send: not connected or characteristic not found")
            return
        }
        
        guard let dataToSend = data.data(using: .utf8) else {
            print("Failed to encode data")
            return
        }
        
        // Write without response for better performance
        peripheral.writeValue(
            dataToSend,
            for: characteristic,
            type: .withoutResponse
        )
        
        print("Sent: \(data) (\(dataToSend.count) bytes)")
    }
    
    /// Attempt to reconnect to last known peripheral
    func reconnectToLastDevice() {
        guard let uuid = lastConnectedPeripheralIdentifier else {
            print("No last connected device")
            startScanning()
            return
        }
        
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        
        if let peripheral = peripherals.first {
            print("Attempting to reconnect to last device: \(peripheral.name ?? "Unknown")")
            connectToPeripheral(peripheral)
        } else {
            print("Last device not found, starting scan")
            startScanning()
        }
    }
    
    // MARK: - Private Methods
    
    private func connectToPeripheral(_ peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
        print("Connecting to: \(peripheral.name ?? "Unknown")")
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("Bluetooth powered on")
            // Attempt to reconnect to last device, or start scanning
            if let uuid = lastConnectedPeripheralIdentifier {
                reconnectToLastDevice()
            } else {
                startScanning()
            }
            
        case .poweredOff:
            print("Bluetooth powered off")
            isConnected = false
            isScanning = false
            
        case .resetting:
            print("Bluetooth resetting")
            
        case .unauthorized:
            print("Bluetooth unauthorized")
            
        case .unsupported:
            print("Bluetooth unsupported")
            
        case .unknown:
            print("Bluetooth unknown state")
            
        @unknown default:
            print("Bluetooth unknown state")
        }
    }
    
    func centralManager(_ central: CBCentralManager, 
                       didDiscover peripheral: CBPeripheral, 
                       advertisementData: [String : Any], 
                       rssi RSSI: NSNumber) {
        
        print("Discovered: \(peripheral.name ?? "Unknown") (RSSI: \(RSSI))")
        
        // Auto-connect to first discovered device with our service
        // (In production, you might want to show a list and let user choose)
        stopScanning()
        connectToPeripheral(peripheral)
        
        // Store signal strength
        signalStrength = RSSI.intValue
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to: \(peripheral.name ?? "Unknown")")
        
        isConnected = true
        peripheralName = peripheral.name ?? "BikeComputer"
        lastConnectedPeripheralIdentifier = peripheral.identifier
        
        // Discover services
        peripheral.discoverServices([serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, 
                       didDisconnectPeripheral peripheral: CBPeripheral, 
                       error: Error?) {
        print("Disconnected from: \(peripheral.name ?? "Unknown")")
        
        if let error = error {
            print("Disconnect error: \(error.localizedDescription)")
        }
        
        isConnected = false
        connectedPeripheral = nil
        navigationCharacteristic = nil
        
        // Auto-reconnect if enabled
        if autoReconnect {
            print("Attempting to reconnect...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.reconnectToLastDevice()
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, 
                       didFailToConnect peripheral: CBPeripheral, 
                       error: Error?) {
        print("Failed to connect to: \(peripheral.name ?? "Unknown")")
        
        if let error = error {
            print("Connection error: \(error.localizedDescription)")
        }
        
        // Retry after delay
        if autoReconnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.startScanning()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("Error discovering services: \(error.localizedDescription)")
            return
        }
        
        guard let services = peripheral.services else { return }
        
        for service in services {
            print("Discovered service: \(service.uuid)")
            
            if service.uuid == serviceUUID {
                // Discover characteristics for navigation service
                peripheral.discoverCharacteristics([characteristicUUID], for: service)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didDiscoverCharacteristicsFor service: CBService, 
                   error: Error?) {
        if let error = error {
            print("Error discovering characteristics: \(error.localizedDescription)")
            return
        }
        
        guard let characteristics = service.characteristics else { return }
        
        for characteristic in characteristics {
            print("Discovered characteristic: \(characteristic.uuid)")
            
            if characteristic.uuid == characteristicUUID {
                navigationCharacteristic = characteristic
                print("Navigation characteristic ready!")
                
                // Optional: Enable notifications if ESP32 sends updates
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didWriteValueFor characteristic: CBCharacteristic, 
                   error: Error?) {
        if let error = error {
            print("Error writing characteristic: \(error.localizedDescription)")
            return
        }
        
        // Write successful (if using .withResponse type)
        // print("Write successful")
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didUpdateValueFor characteristic: CBCharacteristic, 
                   error: Error?) {
        if let error = error {
            print("Error reading characteristic: \(error.localizedDescription)")
            return
        }
        
        // Handle notifications from ESP32 (if implemented)
        guard let data = characteristic.value else { return }
        
        if let string = String(data: data, encoding: .utf8) {
            print("Received from ESP32: \(string)")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didReadRSSI RSSI: NSNumber, 
                   error: Error?) {
        if error == nil {
            signalStrength = RSSI.intValue
        }
    }
}

// MARK: - Helper Extension

extension BLEManager {
    
    /// Read RSSI periodically to monitor connection strength
    func startMonitoringRSSI() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, let peripheral = self.connectedPeripheral, self.isConnected else {
                return
            }
            peripheral.readRSSI()
        }
    }
}
