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
    @Published var isGPSReady: Bool = false // Ready to send GPS data
    @Published var isRouteReady: Bool = false // Ready to send Route data
    @Published var peripheralName: String = ""
    @Published var signalStrength: Int = 0
    
    // MARK: - Map Settings (persisted for UI display)
    @Published var minPolygonSize: Double = 0
    @Published var detailLevel: Int = 2
    @Published var routeLineWidth: Double = 4
    @Published var displayRotation: Int = 0  // 0-3: 0°, 90°, 180°, 270°
    
    // MARK: - BLE UUIDs (matching ESP32)
    private let serviceUUID = CBUUID(string: "1819")           // Navigation Service
    private let characteristicUUID = CBUUID(string: "2A6E")    // Navigation Data Characteristic
    private let routeGeometryCharacteristicUUID = CBUUID(string: "2A6F")  // Route Geometry Characteristic
    private let gpsPositionCharacteristicUUID = CBUUID(string: "2A72")    // GPS Position Characteristic (Location and Speed)
    private let settingsCharacteristicUUID = CBUUID(string: "2A73")       // Settings Characteristic (runtime configuration)
    
    // MARK: - Private Properties
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var navigationCharacteristic: CBCharacteristic?
    private var routeGeometryCharacteristic: CBCharacteristic?
    private var gpsPositionCharacteristic: CBCharacteristic?
    private var settingsCharacteristic: CBCharacteristic?
    
    private var autoReconnect: Bool = true
    private var lastConnectedPeripheralIdentifier: UUID?
    
    // MARK: - Reconnection with Exponential Backoff (Optimization #14)
    private var reconnectAttempts: Int = 0
    private var maxReconnectAttempts: Int = 10
    private var baseReconnectDelay: TimeInterval = 1.0 // Start with 1 second
    private var maxReconnectDelay: TimeInterval = 60.0 // Cap at 60 seconds
    private var reconnectTimer: Timer?
    
    // MARK: - UserDefaults Keys
    private enum SettingsKeys {
        static let minPolygonSize = "mapSettings.minPolygonSize"
        static let detailLevel = "mapSettings.detailLevel"
        static let routeLineWidth = "mapSettings.routeLineWidth"
        static let displayRotation = "mapSettings.displayRotation"
    }
    
    // MARK: - Initialization
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        loadSettings()
    }
    
    private func loadSettings() {
        let defaults = UserDefaults.standard
        minPolygonSize = defaults.double(forKey: SettingsKeys.minPolygonSize)
        detailLevel = defaults.object(forKey: SettingsKeys.detailLevel) as? Int ?? 2
        routeLineWidth = defaults.object(forKey: SettingsKeys.routeLineWidth) as? Double ?? 4.0
        displayRotation = defaults.object(forKey: SettingsKeys.displayRotation) as? Int ?? 0
    }
    
    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(minPolygonSize, forKey: SettingsKeys.minPolygonSize)
        defaults.set(detailLevel, forKey: SettingsKeys.detailLevel)
        defaults.set(routeLineWidth, forKey: SettingsKeys.routeLineWidth)
        defaults.set(displayRotation, forKey: SettingsKeys.displayRotation)
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
    
    /// Send route geometry data to ESP32 (binary format)
    func sendRouteGeometry(_ data: Data) {
        guard let peripheral = connectedPeripheral,
              let characteristic = routeGeometryCharacteristic,
              isConnected else {
            print("Cannot send geometry: not connected or characteristic not found")
            return
        }
        
        // Write without response for better performance
        peripheral.writeValue(
            data,
            for: characteristic,
            type: .withoutResponse
        )
        
        print("Sent route geometry: \(data.count) bytes")
    }
    
    /// Send GPS position to ESP32
    /// Format: [Lat:4][Lon:4][Heading:2] = 10 bytes
    /// GPS coordinates are sent as-is (WGS-84) but with a calibration nudge for map alignment
    func sendGPSPosition(lat: Double, lon: Double, heading: Double = 0) {
        guard let peripheral = connectedPeripheral,
              let characteristic = gpsPositionCharacteristic,
              isConnected else {
            return
        }
        
        // GPS coordinates arrive already converted from GCJ-02 to WGS-84 by NavigationEngine
        // Do NOT apply additional calibration here - that would cause double offset
        
        // Format: [Lat:4][Lon:4][Heading:2] Int32 microdegrees + UInt16 degrees
        var data = Data()
        
        let latInt = Int32(lat * 1_000_000)
        let lonInt = Int32(lon * 1_000_000)
        
        // Heading: 0-359 degrees (UInt16), -1 means invalid
        let headingDeg: UInt16 = heading >= 0 ? UInt16(min(heading, 359)) : 0
        
        withUnsafeBytes(of: latInt.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: lonInt.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: headingDeg.littleEndian) { data.append(contentsOf: $0) }
        
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
    }
    
    /// Send a setting to ESP32 (runtime map configuration)
    /// Format: [settingId:1][value:4] = 5 bytes
    /// Setting IDs: 1=minPolygonSize (0-50), 2=detailLevel (0-2), 3=routeLineWidth (2-8)
    func sendSetting(id: UInt8, value: Int32) {
        guard let peripheral = connectedPeripheral,
              let characteristic = settingsCharacteristic,
              isConnected else {
            print("Cannot send setting: not connected or characteristic not found")
            return
        }
        
        var data = Data()
        data.append(id)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        print("Sent setting: id=\(id), value=\(value)")
        
        // Persist settings to UserDefaults
        saveSettings()
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
        
        // Reset reconnection state on successful connection (Optimization #14)
        resetReconnectionState()
        
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
        isGPSReady = false
        isRouteReady = false
        connectedPeripheral = nil
        navigationCharacteristic = nil
        
        // Auto-reconnect if enabled with exponential backoff
        if autoReconnect {
            scheduleReconnectWithBackoff()
        }
    }
    
    // MARK: - Exponential Backoff Reconnection (Optimization #14)
    
    private func scheduleReconnectWithBackoff() {
        reconnectTimer?.invalidate()
        
        guard reconnectAttempts < maxReconnectAttempts else {
            print("❌ Max reconnection attempts reached (\(maxReconnectAttempts))")
            reconnectAttempts = 0
            return
        }
        
        // Calculate delay with exponential backoff: base * 2^attempts
        let delay = min(baseReconnectDelay * pow(2.0, Double(reconnectAttempts)), maxReconnectDelay)
        reconnectAttempts += 1
        
        print("🔄 Reconnection attempt \(reconnectAttempts)/\(maxReconnectAttempts) in \(String(format: "%.1f", delay))s...")
        
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.reconnectToLastDevice()
        }
    }
    
    private func resetReconnectionState() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnectAttempts = 0
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
                peripheral.discoverCharacteristics([
                    characteristicUUID, 
                    routeGeometryCharacteristicUUID,
                    gpsPositionCharacteristicUUID,
                    settingsCharacteristicUUID
                ], for: service)
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
            
            if characteristic.uuid == routeGeometryCharacteristicUUID {
                routeGeometryCharacteristic = characteristic
                isRouteReady = true // Mark as ready to send Route data
                print("Route Geometry characteristic ready!")
            }
            
            if characteristic.uuid == gpsPositionCharacteristicUUID {
                gpsPositionCharacteristic = characteristic
                print("GPS Position characteristic ready!")
            }
            
            if characteristic.uuid == gpsPositionCharacteristicUUID {
                gpsPositionCharacteristic = characteristic
                isGPSReady = true // Mark as ready to receive GPS
                print("GPS Position characteristic ready!")
            }
            
            if characteristic.uuid == settingsCharacteristicUUID {
                settingsCharacteristic = characteristic
                print("Settings characteristic ready!")
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
