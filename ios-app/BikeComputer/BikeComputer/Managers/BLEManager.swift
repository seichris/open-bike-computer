//
//  BLEManager.swift
//  BikeComputer
//
//  BLE Manager for connecting to ESP32 Bike Computer
//  Service UUID: 9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1800
//

import Foundation
import Combine
import CoreBluetooth
import CryptoKit
import Security

struct NavigationWriteEndpoint {
    let maximumWriteLength: Int
    let canSend: () -> Bool
    let write: (Data) -> Void
}

enum BLEPairingAuthenticator {
    private static let key = SymmetricKey(data: Data("BikeComputer BLE v1 local pairing key".utf8))

    static func makeNonce() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func isValidServerResponse(_ response: String, nonce: String) -> Bool {
        let parts = response.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "SERVER",
              parts[1] == Substring(nonce) else {
            return false
        }

        return constantTimeEquals(String(parts[2]), hmacHex("server|\(nonce)"))
    }

    static func clientProof(nonce: String) -> String {
        hmacHex("client|\(nonce)")
    }

    static func authMessage(from data: Data) -> String? {
        let trimmed = data.trimmedTrailingNullsAndWhitespace
        if let message = String(data: trimmed, encoding: .utf8) {
            return message
        }

        let printable = trimmed.filter { byte in
            byte == 0x0A || byte == 0x0D || (byte >= 0x20 && byte <= 0x7E)
        }
        guard !printable.isEmpty else { return nil }

        return String(data: Data(printable), encoding: .utf8)
    }

    private static func hmacHex(_ message: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }

        var diff: UInt8 = 0
        for index in left.indices {
            diff |= left[index] ^ right[index]
        }
        return diff == 0
    }
}

private extension Data {
    var trimmedTrailingNullsAndWhitespace: Data {
        var end = endIndex
        while end > startIndex {
            let byte = self[index(before: end)]
            guard byte == 0 || byte == 0x0A || byte == 0x0D || byte == 0x20 else {
                break
            }
            end = index(before: end)
        }
        return self[startIndex..<end]
    }

    var hexPreview: String {
        prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

private extension CBCharacteristicProperties {
    var debugDescription: String {
        var names: [String] = []
        if contains(.broadcast) { names.append("broadcast") }
        if contains(.read) { names.append("read") }
        if contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
        if contains(.write) { names.append("write") }
        if contains(.notify) { names.append("notify") }
        if contains(.indicate) { names.append("indicate") }
        if contains(.authenticatedSignedWrites) { names.append("authenticatedSignedWrites") }
        if contains(.extendedProperties) { names.append("extendedProperties") }
        if contains(.notifyEncryptionRequired) { names.append("notifyEncryptionRequired") }
        if contains(.indicateEncryptionRequired) { names.append("indicateEncryptionRequired") }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }
}

class BLEManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var isScanning: Bool = false
    @Published var isConnected: Bool = false
    @Published var isNavigationReady: Bool = false
    @Published var supportsDeviceSettings: Bool = false
    @Published var peripheralName: String = ""
    @Published var signalStrength: Int = 0
    @Published var centralStateDescription: String = "unknown"
    @Published var trustedPeripheralDescription: String = "none"
    @Published var debugEvents: [String] = []
    
    // MARK: - Map Settings (persisted for UI display)
    @Published var minPolygonSize: Double = 0
    @Published var detailLevel: Int = 2
    @Published var routeLineWidth: Double = 4
    @Published var streetLineWidthBoost: Double = 0
    @Published var positionMarkerScale: Double = 2
    @Published var displayRotation: Int = 0 
    @Published var mapRotationMode: Int = 0 // 0=North Up, 1=Course Up  // 0-3: 0°, 90°, 180°, 270°
    @Published var zoomLevel: Int = 2 // 0-4: 0=super-zoom, 1=closest, 4=farthest
    @Published var tapToSwitchScreens: Bool = false
    
    // Feature Visibility
    @Published var showBuildings: Bool = true
    @Published var showGreenSpace: Bool = true
    @Published var showPaths: Bool = true
    @Published var showMajorRoads: Bool = true
    @Published var showLocalStreets: Bool = true
    @Published var showWater: Bool = true
    @Published var showRailways: Bool = true
    @Published var showOtherAreas: Bool = true
    @Published var showRouteOverlay: Bool = true
    @Published var showCurrentPosition: Bool = true
    
    // MARK: - BLE UUIDs (matching ESP32)
    private let serviceUUID = CBUUID(string: "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1800")
    private let characteristicUUID = CBUUID(string: "2A6E")    // Navigation Data Characteristic
    private let authCharacteristicUUID = CBUUID(string: "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1002")
    private let routeGeometryCharacteristicUUID = CBUUID(string: "2A6F")
    private let gpsPositionCharacteristicUUID = CBUUID(string: "2A72")
    private let settingsCharacteristicUUID = CBUUID(string: "2A73")
    
    // MARK: - Private Properties
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var navigationCharacteristic: CBCharacteristic?
    private var authCharacteristic: CBCharacteristic?
    private var routeGeometryCharacteristic: CBCharacteristic?
    private var gpsPositionCharacteristic: CBCharacteristic?
    private var settingsCharacteristic: CBCharacteristic?
    private var navigationWriteEndpoint: NavigationWriteEndpoint?
    private var navigationWriteQueue = NavigationWriteQueue(maxCount: 16)
    private var isConnecting: Bool = false
    private var isPairingMode: Bool = false
    private var pendingAuthNonce: String?
    private enum AuthWriteState {
        case idle
        case helloInFlight
        case waitingForServer
        case clientProofPending(Data)
        case clientProofInFlight
        case waitingForOK
    }
    private var authWriteState: AuthWriteState = .idle
    
    private var autoReconnect: Bool = true
    private var lastConnectedPeripheralIdentifier: UUID?
    
    // MARK: - Reconnection with Exponential Backoff (Optimization #14)
    private var reconnectAttempts: Int = 0
    private var maxReconnectAttempts: Int = 10
    private var baseReconnectDelay: TimeInterval = 1.0 // Start with 1 second
    private var maxReconnectDelay: TimeInterval = 60.0 // Cap at 60 seconds
    private var reconnectTimer: Timer?
    private var rssiTimer: Timer?
    private var navigationFlushRetryTimer: Timer?
    private var connectionTimeoutTimer: Timer?
    private var authRetryTimer: Timer?
    private var authTimeoutTimer: Timer?
    private var shouldPairAfterDisconnect: Bool = false
    private var suppressNextReconnect: Bool = false
    private var hasActiveBLESession: Bool {
        isConnected || isConnecting || connectedPeripheral != nil
    }
    
    // MARK: - UserDefaults Keys
    private enum SettingsKeys {
        static let minPolygonSize = "mapSettings.minPolygonSize"
        static let detailLevel = "mapSettings.detailLevel"
        static let routeLineWidth = "mapSettings.routeLineWidth"
        static let streetLineWidthBoost = "mapSettings.streetLineWidthBoost"
        static let positionMarkerScale = "mapSettings.positionMarkerScale"
        static let displayRotation = "mapSettings.displayRotation"
        static let mapRotationMode = "mapSettings.mapRotationMode"
        static let resetMapRotationModeToNorthUp = "mapSettings.resetMapRotationModeToNorthUp.v1"
        static let zoomLevel = "mapSettings.zoomLevel"
        static let tapToSwitchScreens = "deviceSettings.tapToSwitchScreens"
        static let showBuildings = "mapSettings.showBuildings"
        static let showGreenSpace = "mapSettings.showGreenSpace"
        static let showPaths = "mapSettings.showPaths"
        static let showMajorRoads = "mapSettings.showMajorRoads"
        static let showLocalStreets = "mapSettings.showLocalStreets"
        static let showWater = "mapSettings.showWater"
        static let showRailways = "mapSettings.showRailways"
        static let showOtherAreas = "mapSettings.showOtherAreas"
        static let showRouteOverlay = "mapSettings.showRouteOverlay"
        static let showCurrentPosition = "mapSettings.showCurrentPosition"
        static let legacyShowNature = "mapSettings.showNature"
        static let legacyShowMinorRoads = "mapSettings.showMinorRoads"
        static let lastPeripheralIdentifier = "ble.lastPeripheralIdentifier"
    }
    
    // MARK: - Initialization
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        loadSettings()
        loadLastPeripheralIdentifier()
        updateTrustedPeripheralDescription()
        log("BLE debug session started")
    }
    
    private func loadSettings() {
        let defaults = UserDefaults.standard
        minPolygonSize = defaults.double(forKey: SettingsKeys.minPolygonSize)
        detailLevel = defaults.object(forKey: SettingsKeys.detailLevel) as? Int ?? 2
        routeLineWidth = defaults.object(forKey: SettingsKeys.routeLineWidth) as? Double ?? 4.0
        streetLineWidthBoost = defaults.object(forKey: SettingsKeys.streetLineWidthBoost) as? Double ?? 0.0
        positionMarkerScale = defaults.object(forKey: SettingsKeys.positionMarkerScale) as? Double ?? 2.0
        displayRotation = defaults.object(forKey: SettingsKeys.displayRotation) as? Int ?? 0
        if defaults.bool(forKey: SettingsKeys.resetMapRotationModeToNorthUp) {
            mapRotationMode = defaults.object(forKey: SettingsKeys.mapRotationMode) as? Int ?? 0
        } else {
            mapRotationMode = 0
            defaults.set(0, forKey: SettingsKeys.mapRotationMode)
            defaults.set(true, forKey: SettingsKeys.resetMapRotationModeToNorthUp)
        }
        zoomLevel = defaults.object(forKey: SettingsKeys.zoomLevel) as? Int ?? 2
        tapToSwitchScreens = defaults.object(forKey: SettingsKeys.tapToSwitchScreens) as? Bool ?? false
        showBuildings = defaults.object(forKey: SettingsKeys.showBuildings) as? Bool ?? true
        let legacyNature = defaults.object(forKey: SettingsKeys.legacyShowNature) as? Bool ?? true
        let legacyMinorRoads = defaults.object(forKey: SettingsKeys.legacyShowMinorRoads) as? Bool ?? true
        showGreenSpace = defaults.object(forKey: SettingsKeys.showGreenSpace) as? Bool ?? legacyNature
        showPaths = defaults.object(forKey: SettingsKeys.showPaths) as? Bool ?? legacyMinorRoads
        showMajorRoads = defaults.object(forKey: SettingsKeys.showMajorRoads) as? Bool ?? true
        showLocalStreets = defaults.object(forKey: SettingsKeys.showLocalStreets) as? Bool ?? true
        showWater = defaults.object(forKey: SettingsKeys.showWater) as? Bool ?? legacyNature
        showRailways = defaults.object(forKey: SettingsKeys.showRailways) as? Bool ?? true
        showOtherAreas = defaults.object(forKey: SettingsKeys.showOtherAreas) as? Bool ?? true
        showRouteOverlay = defaults.object(forKey: SettingsKeys.showRouteOverlay) as? Bool ?? true
        showCurrentPosition = defaults.object(forKey: SettingsKeys.showCurrentPosition) as? Bool ?? true
    }

    private func loadLastPeripheralIdentifier() {
        guard let uuidString = UserDefaults.standard.string(forKey: SettingsKeys.lastPeripheralIdentifier) else { return }
        lastConnectedPeripheralIdentifier = UUID(uuidString: uuidString)
        updateTrustedPeripheralDescription()
    }
    
    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(minPolygonSize, forKey: SettingsKeys.minPolygonSize)
        defaults.set(detailLevel, forKey: SettingsKeys.detailLevel)
        defaults.set(routeLineWidth, forKey: SettingsKeys.routeLineWidth)
        defaults.set(streetLineWidthBoost, forKey: SettingsKeys.streetLineWidthBoost)
        defaults.set(positionMarkerScale, forKey: SettingsKeys.positionMarkerScale)
        defaults.set(displayRotation, forKey: SettingsKeys.displayRotation)
        defaults.set(mapRotationMode, forKey: SettingsKeys.mapRotationMode)
        defaults.set(zoomLevel, forKey: SettingsKeys.zoomLevel)
        defaults.set(tapToSwitchScreens, forKey: SettingsKeys.tapToSwitchScreens)
        defaults.set(showBuildings, forKey: SettingsKeys.showBuildings)
        defaults.set(showGreenSpace, forKey: SettingsKeys.showGreenSpace)
        defaults.set(showPaths, forKey: SettingsKeys.showPaths)
        defaults.set(showMajorRoads, forKey: SettingsKeys.showMajorRoads)
        defaults.set(showLocalStreets, forKey: SettingsKeys.showLocalStreets)
        defaults.set(showWater, forKey: SettingsKeys.showWater)
        defaults.set(showRailways, forKey: SettingsKeys.showRailways)
        defaults.set(showOtherAreas, forKey: SettingsKeys.showOtherAreas)
        defaults.set(showRouteOverlay, forKey: SettingsKeys.showRouteOverlay)
        defaults.set(showCurrentPosition, forKey: SettingsKeys.showCurrentPosition)
    }
    
    // MARK: - Public Methods
    
    /// Start scanning for bike computer peripheral
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            log("Bluetooth not powered on")
            return
        }
        guard !hasActiveBLESession else {
            log("Skipping BLE scan: connection already active")
            return
        }
        guard !isScanning else {
            log("Skipping BLE scan: scan already active")
            return
        }
        guard lastConnectedPeripheralIdentifier != nil || isPairingMode else {
            log("Skipping BLE scan: no trusted peripheral saved and pairing mode is not active")
            return
        }
        
        log("Starting BLE scan for service UUID: \(serviceUUID)")
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
        log("BLE scan stopped")
    }
    
    /// Disconnect from current peripheral
    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        
        autoReconnect = false
        stopMonitoringRSSI()
        centralManager.cancelPeripheralConnection(peripheral)
        log("Disconnecting from peripheral")
    }

    func reconnect() {
        clearDebugEvents()
        log("Debug log cleared for reconnect")
        autoReconnect = true
        resetReconnectionState()

        if let peripheral = connectedPeripheral {
            log("Restarting active BLE connection with fresh pairing scan")
            shouldPairAfterDisconnect = true
            stopMonitoringRSSI()
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        forgetTrustedPeripheralForFreshScan()
        beginPairing()
    }
    
    /// Send navigation data to ESP32
    @discardableResult
    func sendNavigationData(_ data: String) -> Bool {
        guard let endpoint = navigationWriteEndpoint,
              isConnected,
              isNavigationReady else {
            log("Cannot send: not connected or navigation not ready")
            return false
        }
        
        let maxLength = min(endpoint.maximumWriteLength, NavigationPacketBuilder.protocolMaxBytes)
        guard let dataToSend = NavigationPacketBuilder.data(from: data, maxLength: maxLength) else {
            log("Failed to encode navigation data")
            return false
        }
        
        enqueueNavigationWrite(dataToSend, endpoint: endpoint, label: "navigation")
        log("Queued navigation packet: \(dataToSend.count) bytes")
        return true
    }
    
    /// Send route geometry data to ESP32.
    /// Format: [StartLat:4][StartLon:4][DeltaLat:2][DeltaLon:2]...
    func sendRouteGeometry(_ data: Data) {
        guard let peripheral = connectedPeripheral,
              isConnected,
              isNavigationReady else {
            log("Cannot send geometry: BLE not ready")
            return
        }

        let maxLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
        if let characteristic = routeGeometryCharacteristic {
            guard data.count <= maxLength else {
                log("Cannot send geometry: \(data.count) bytes exceeds write limit \(maxLength)")
                return
            }

            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            log("Sent route geometry: \(data.count) bytes")
            return
        }

        var fallback = Data("MAPR".utf8)
        fallback.append(data)
        guard fallback.count <= maxLength else {
            log("Cannot send geometry: \(data.count) bytes exceeds write limit \(maxLength)")
            return
        }

        sendFallbackMapPacket(fallback, label: "route geometry")
    }

    /// Clear route geometry on ESP32.
    func clearRouteGeometry() {
        sendRouteGeometry(Data())
    }

    /// Send GPS position and optional ride telemetry to ESP32.
    /// Format: [Lat:4][Lon:4][Heading:2][UnixTime:4][SpeedCmps:2][Altitude:2][Distance:4][Elapsed:4][RouteRemaining:4].
    func sendGPSPosition(
        lat: Double,
        lon: Double,
        heading: Double = 0,
        speedMetersPerSecond: Double? = nil,
        altitudeMeters: Double? = nil,
        distanceTraveledMeters: Double? = nil,
        elapsedSeconds: TimeInterval? = nil,
        routeRemainingMeters: Double? = nil
    ) {
        guard let peripheral = connectedPeripheral,
              isConnected,
              isNavigationReady else {
            log("Cannot send GPS position: BLE not ready")
            return
        }

        let data = DeviceGPSPacketBuilder.data(
            lat: lat,
            lon: lon,
            heading: heading,
            speedMetersPerSecond: speedMetersPerSecond,
            altitudeMeters: altitudeMeters,
            distanceTraveledMeters: distanceTraveledMeters,
            elapsedSeconds: elapsedSeconds,
            routeRemainingMeters: routeRemainingMeters
        )

        if let characteristic = gpsPositionCharacteristic {
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            log(String(format: "Sent GPS position: %.6f, %.6f heading=%.0f", lat, lon, heading))
            return
        }

        var fallback = Data("GPSP".utf8)
        fallback.append(data)
        guard fallback.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
            log("Cannot send GPS position fallback: write limit exceeded")
            return
        }
        sendFallbackMapPacket(fallback, label: "GPS position")
    }

    /// Persist and send a runtime map setting to ESP32 when supported.
    func sendSetting(id: UInt8, value: Int32) {
        saveSettings()
        guard isConnected, isNavigationReady else {
            log("Settings characteristic unsupported; saved local setting id=\(id), value=\(value)")
            return
        }

        var data = Data()
        data.append(id)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }

        if let peripheral = connectedPeripheral, let characteristic = settingsCharacteristic {
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            log("Sent setting: id=\(id), value=\(value)")
            return
        }

        var fallback = Data("MSET".utf8)
        fallback.append(data)
        guard fallback.count <= (navigationWriteEndpoint?.maximumWriteLength ?? 0) else {
            log("Cannot send fallback setting: write limit exceeded")
            return
        }
        sendFallbackMapPacket(fallback, label: "setting id=\(id)")
    }
    
    /// Send feature visibility bitmask
    func sendVisibilityMask() {
        var mask: Int32 = 0
        if showBuildings { mask |= (1 << 0) }
        if showGreenSpace { mask |= (1 << 1) }
        if showPaths { mask |= (1 << 2) }
        if showMajorRoads { mask |= (1 << 3) }
        if showLocalStreets { mask |= (1 << 4) }
        if showWater { mask |= (1 << 5) }
        if showRailways { mask |= (1 << 6) }
        if showOtherAreas { mask |= (1 << 7) }
        if showRouteOverlay { mask |= (1 << 8) }
        if showCurrentPosition { mask |= (1 << 9) }
        
        sendSetting(id: 8, value: mask)
    }

    func sendDebugNavigationPacket() {
        let packet = "\(NavigationIconID.left)|123|Debug turn left"
        guard sendNavigationData(packet) else {
            log("Debug navigation packet was not sent")
            return
        }

        log("Sent debug navigation packet")
    }

    func forgetTrustedPeripheral() {
        autoReconnect = false
        lastConnectedPeripheralIdentifier = nil
        UserDefaults.standard.removeObject(forKey: SettingsKeys.lastPeripheralIdentifier)
        updateTrustedPeripheralDescription()
        log("Forgot trusted BikeComputer peripheral")
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        } else {
            clearConnectionState()
        }
    }

    var debugLogText: String {
        debugEvents.joined(separator: "\n")
    }
    
    /// Attempt to reconnect to last known peripheral
    func reconnectToLastDevice() {
        guard centralManager.state == .poweredOn else {
            log("Cannot reconnect: Bluetooth not powered on")
            return
        }
        guard !hasActiveBLESession else {
            log("Skipping reconnect: connection already active")
            return
        }

        guard let uuid = lastConnectedPeripheralIdentifier else {
            log("No last connected device")
            startScanning()
            return
        }
        
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        
        if let peripheral = peripherals.first {
            log("Attempting to reconnect to last device: \(peripheral.name ?? "Unknown")")
            connectToPeripheral(peripheral)
        } else {
            log("Last device not found, starting scan")
            startScanning()
        }
    }
    
    // MARK: - Private Methods
    
    private func connectToPeripheral(_ peripheral: CBPeripheral) {
        guard !hasActiveBLESession else {
            log("Skipping connect: connection already active")
            return
        }

        stopScanning()
        connectedPeripheral = peripheral
        navigationCharacteristic = nil
        authCharacteristic = nil
        routeGeometryCharacteristic = nil
        gpsPositionCharacteristic = nil
        settingsCharacteristic = nil
        navigationWriteEndpoint = nil
        isNavigationReady = false
        pendingAuthNonce = nil
        authWriteState = .idle
        navigationWriteQueue.removeAll()
        authRetryTimer?.invalidate()
        authRetryTimer = nil
        authTimeoutTimer?.invalidate()
        authTimeoutTimer = nil
        peripheral.delegate = self
        isConnecting = true
        centralManager.connect(peripheral, options: nil)
        log("Connecting to: \(peripheral.name ?? "Unknown")")
        startConnectionTimeout(for: peripheral)
    }

    private func beginPairing() {
        guard centralManager.state == .poweredOn else {
            log("Cannot pair: Bluetooth not powered on")
            return
        }

        isPairingMode = true
        log("Starting pairing scan")
        startScanning()
    }

    private func forgetTrustedPeripheralForFreshScan() {
        if lastConnectedPeripheralIdentifier != nil {
            log("Forgetting trusted BikeComputer peripheral for fresh scan")
        }

        lastConnectedPeripheralIdentifier = nil
        UserDefaults.standard.removeObject(forKey: SettingsKeys.lastPeripheralIdentifier)
        updateTrustedPeripheralDescription()
    }

    private func startConnectionTimeout(for peripheral: CBPeripheral) {
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self, weak peripheral] _ in
            guard let self,
                  let peripheral,
                  self.isConnecting,
                  self.connectedPeripheral?.identifier == peripheral.identifier else {
                return
            }

            self.log("BLE connection timed out; starting fresh pairing scan")
            self.centralManager.cancelPeripheralConnection(peripheral)
            self.clearConnectionState()
            self.forgetTrustedPeripheralForFreshScan()
            self.beginPairing()
        }
    }

    private func clearConnectionState() {
        isConnected = false
        isConnecting = false
        supportsDeviceSettings = false
        connectedPeripheral = nil
        navigationCharacteristic = nil
        authCharacteristic = nil
        routeGeometryCharacteristic = nil
        gpsPositionCharacteristic = nil
        settingsCharacteristic = nil
        navigationWriteEndpoint = nil
        isNavigationReady = false
        pendingAuthNonce = nil
        authWriteState = .idle
        navigationWriteQueue.removeAll()
        navigationFlushRetryTimer?.invalidate()
        navigationFlushRetryTimer = nil
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        authRetryTimer?.invalidate()
        authRetryTimer = nil
        authTimeoutTimer?.invalidate()
        authTimeoutTimer = nil
        stopMonitoringRSSI()
    }

    private func updateTrustedPeripheralDescription() {
        trustedPeripheralDescription = lastConnectedPeripheralIdentifier?.uuidString ?? "none"
    }

    private func log(_ message: String) {
        print(message)

        let timestamp = DateFormatter.bleDebugTimestamp.string(from: Date())
        let line = "\(timestamp) \(message)"
        if Thread.isMainThread {
            appendDebugEvent(line)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.appendDebugEvent(line)
            }
        }
    }

    private func clearDebugEvents() {
        if Thread.isMainThread {
            debugEvents.removeAll()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.debugEvents.removeAll()
            }
        }
    }

    private func appendDebugEvent(_ line: String) {
        debugEvents.append(line)
        if debugEvents.count > 40 {
            debugEvents.removeFirst(debugEvents.count - 40)
        }
    }

    func installNavigationWriteEndpoint(_ endpoint: NavigationWriteEndpoint) {
        navigationWriteEndpoint = endpoint
    }

    private func scheduleAuthenticationRetry(for peripheral: CBPeripheral) {
        authRetryTimer?.invalidate()
        authRetryTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self, weak peripheral] _ in
            guard let self, let peripheral else { return }
            self.beginAuthenticationIfReady(for: peripheral, source: "retry")
        }
    }

    private func startAuthenticationTimeout(for peripheral: CBPeripheral) {
        authTimeoutTimer?.invalidate()
        authTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { [weak self, weak peripheral] _ in
            guard let self,
                  let peripheral,
                  self.connectedPeripheral?.identifier == peripheral.identifier,
                  !self.isNavigationReady else {
                return
            }

            self.log("BLE auth timed out; restarting fresh pairing scan")
            self.clearConnectionState()
            self.forgetTrustedPeripheralForFreshScan()
            self.centralManager.cancelPeripheralConnection(peripheral)
            self.beginPairing()
        }
    }

    private func beginAuthenticationIfReady(for peripheral: CBPeripheral, source: String = "discovery") {
        guard navigationCharacteristic != nil else {
            log("BLE auth not ready from \(source): navigation characteristic missing")
            return
        }
        guard let authCharacteristic else {
            log("BLE auth not ready from \(source): auth characteristic missing")
            return
        }
        guard pendingAuthNonce == nil, case .idle = authWriteState else {
            return
        }

        guard let writeType = authWriteType(for: authCharacteristic) else {
            log("Auth characteristic does not support writes; props=\(authCharacteristic.properties.debugDescription)")
            return
        }

        guard let nonce = BLEPairingAuthenticator.makeNonce() else {
            log("Failed to generate BLE auth nonce")
            return
        }

        let challenge = "HELLO|\(nonce)"
        guard let challengeData = challenge.data(using: .utf8) else { return }
        pendingAuthNonce = nonce
        authWriteState = writeType == .withResponse ? .helloInFlight : .waitingForServer
        peripheral.writeValue(challengeData, for: authCharacteristic, type: writeType)
        log("Sent BLE auth challenge via \(authWriteLabel(writeType)); props=\(authCharacteristic.properties.debugDescription)")
    }

    private func authWriteType(for characteristic: CBCharacteristic) -> CBCharacteristicWriteType? {
        if characteristic.properties.contains(.writeWithoutResponse) {
            return .withoutResponse
        }
        if characteristic.properties.contains(.write) {
            return .withResponse
        }
        return nil
    }

    private func authWriteLabel(_ type: CBCharacteristicWriteType) -> String {
        type == .withResponse ? "withResponse" : "withoutResponse"
    }

    private func handleAuthResponse(_ data: Data, peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard let message = BLEPairingAuthenticator.authMessage(from: data) else {
            log("Received undecodable BLE auth response: \(data.count) bytes hex=\(data.hexPreview)")
            return
        }
        log("Received BLE auth response: \(message.prefix(16))... (\(data.count) bytes)")

        if message == "LOCKED" {
            log("Ignoring initial BLE auth state")
            return
        }

        guard let nonce = pendingAuthNonce else {
            log("Ignoring BLE auth response without a pending challenge")
            return
        }

        if message.hasPrefix("SERVER|") {
            guard BLEPairingAuthenticator.isValidServerResponse(message, nonce: nonce) else {
                log("BLE auth failed: invalid server proof")
                isPairingMode = false
                clearConnectionState()
                centralManager.cancelPeripheralConnection(peripheral)
                return
            }

            let clientProof = BLEPairingAuthenticator.clientProof(nonce: nonce)
            let proofMessage = "CLIENT|\(nonce)|\(clientProof)"
            guard let proofData = proofMessage.data(using: .utf8) else { return }
            sendOrQueueClientProof(proofData, peripheral: peripheral, characteristic: characteristic)
            return
        }

        if message == "OK|\(nonce)" {
            completeAuthentication(for: peripheral)
            return
        }

        log("BLE auth failed: unexpected response")
        isPairingMode = false
        clearConnectionState()
        centralManager.cancelPeripheralConnection(peripheral)
    }

    private func completeAuthentication(for peripheral: CBPeripheral) {
        guard let characteristic = navigationCharacteristic else { return }

        installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: peripheral.maximumWriteValueLength(for: .withoutResponse),
            canSend: { [weak peripheral] in
                peripheral?.canSendWriteWithoutResponse == true
            },
            write: { [weak peripheral, weak characteristic] data in
                guard let peripheral, let characteristic else { return }
                peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            }
        ))

        pendingAuthNonce = nil
        authWriteState = .idle
        isPairingMode = false
        isConnected = true
        isNavigationReady = true
        supportsDeviceSettings = true
        authRetryTimer?.invalidate()
        authRetryTimer = nil
        authTimeoutTimer?.invalidate()
        authTimeoutTimer = nil
        lastConnectedPeripheralIdentifier = peripheral.identifier
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: SettingsKeys.lastPeripheralIdentifier)
        updateTrustedPeripheralDescription()
        log("BLE peripheral authenticated")
        sendVisibilityMask()
        sendSetting(id: 1, value: Int32(minPolygonSize))
        sendSetting(id: 2, value: Int32(detailLevel))
        sendSetting(id: 3, value: Int32(routeLineWidth))
        sendSetting(id: 9, value: Int32(streetLineWidthBoost))
        sendSetting(id: 10, value: Int32(positionMarkerScale))
        sendSetting(id: 4, value: Int32(displayRotation))
        sendSetting(id: 6, value: Int32(mapRotationMode))
        sendSetting(id: 7, value: Int32(zoomLevel))
        sendSetting(id: 11, value: tapToSwitchScreens ? 1 : 0)
    }

    private func sendOrQueueClientProof(_ proofData: Data, peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        switch authWriteState {
        case .helloInFlight:
            authWriteState = .clientProofPending(proofData)
            log("Queued BLE client auth proof until challenge write completes")
        case .waitingForServer:
            writeClientAuthProof(proofData, peripheral: peripheral, characteristic: characteristic)
        default:
            log("Ignoring duplicate BLE server auth response")
        }
    }

    private func writeClientAuthProof(_ proofData: Data, peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard let writeType = authWriteType(for: characteristic) else {
            log("Cannot send BLE client auth proof: auth characteristic is not writable")
            isPairingMode = false
            clearConnectionState()
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        authWriteState = writeType == .withResponse ? .clientProofInFlight : .waitingForOK
        peripheral.writeValue(proofData, for: characteristic, type: writeType)
        log("Sent BLE client auth proof via \(authWriteLabel(writeType))")
    }

    private func authWriteCompleted(for peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        switch authWriteState {
        case .helloInFlight:
            authWriteState = .waitingForServer
        case .clientProofPending(let proofData):
            writeClientAuthProof(proofData, peripheral: peripheral, characteristic: characteristic)
        case .clientProofInFlight:
            authWriteState = .waitingForOK
        default:
            break
        }
    }

    private func enqueueNavigationWrite(_ data: Data, endpoint: NavigationWriteEndpoint, label: String) {
        if navigationWriteQueue.enqueue(NavigationWrite(data: data, label: label)) {
            log("Navigation write queue full; dropped oldest packet")
        }

        flushPendingNavigationWrites(endpoint: endpoint)
        scheduleNavigationFlushRetryIfNeeded()
    }

    private func sendFallbackMapPacket(_ data: Data, label: String) {
        guard let endpoint = navigationWriteEndpoint,
              isConnected,
              isNavigationReady else {
            log("Cannot send fallback \(label): navigation endpoint not ready")
            return
        }

        enqueueNavigationWrite(data, endpoint: endpoint, label: "fallback \(label)")
        log("Queued fallback \(label): \(data.count) bytes")
    }

    private func flushPendingNavigationWrites(endpoint: NavigationWriteEndpoint) {
        navigationWriteQueue.flush(canSend: endpoint.canSend) { write in
            endpoint.write(write.data)
            log("Sent \(write.label): \(write.data.count) bytes")
        }
        if navigationWriteQueue.count == 0 {
            navigationFlushRetryTimer?.invalidate()
            navigationFlushRetryTimer = nil
        } else {
            log("Navigation write queue pending: \(navigationWriteQueue.count)")
        }
    }

    private func scheduleNavigationFlushRetryIfNeeded() {
        guard navigationWriteQueue.count > 0,
              navigationFlushRetryTimer == nil else { return }

        navigationFlushRetryTimer = Timer.scheduledTimer(withTimeInterval: 0.1,
                                                         repeats: false) { [weak self] _ in
            guard let self else { return }
            self.navigationFlushRetryTimer = nil
            guard self.isNavigationReady,
                  let endpoint = self.navigationWriteEndpoint else { return }
            self.flushPendingNavigationWrites(endpoint: endpoint)
            self.scheduleNavigationFlushRetryIfNeeded()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            centralStateDescription = "powered on"
            log("Bluetooth powered on")
            // Attempt to reconnect to last device, or start scanning
            if lastConnectedPeripheralIdentifier != nil {
                reconnectToLastDevice()
            } else {
                log("No trusted BikeComputer peripheral saved; tap reconnect to pair")
            }
            
        case .poweredOff:
            centralStateDescription = "powered off"
            log("Bluetooth powered off")
            isScanning = false
            clearConnectionState()
            resetReconnectionState()
            
        case .resetting:
            centralStateDescription = "resetting"
            log("Bluetooth resetting")
            isScanning = false
            clearConnectionState()
            
        case .unauthorized:
            centralStateDescription = "unauthorized"
            log("Bluetooth unauthorized")
            isScanning = false
            clearConnectionState()
            resetReconnectionState()
            
        case .unsupported:
            centralStateDescription = "unsupported"
            log("Bluetooth unsupported")
            isScanning = false
            clearConnectionState()
            resetReconnectionState()
            
        case .unknown:
            centralStateDescription = "unknown"
            log("Bluetooth unknown state")
            isScanning = false
            clearConnectionState()
            
        @unknown default:
            centralStateDescription = "unknown"
            log("Bluetooth unknown state")
            isScanning = false
            clearConnectionState()
        }
    }
    
    func centralManager(_ central: CBCentralManager, 
                       didDiscover peripheral: CBPeripheral, 
                       advertisementData: [String : Any], 
                       rssi RSSI: NSNumber) {
        
        log("Discovered: \(peripheral.name ?? "Unknown") (RSSI: \(RSSI))")

        if let trustedIdentifier = lastConnectedPeripheralIdentifier,
           peripheral.identifier != trustedIdentifier {
            log("Ignoring untrusted BikeComputer peripheral: \(peripheral.identifier)")
            return
        }

        guard isPairingMode || peripheral.identifier == lastConnectedPeripheralIdentifier else {
            log("Ignoring BikeComputer peripheral outside pairing mode")
            return
        }

        connectToPeripheral(peripheral)
        
        // Store signal strength
        signalStrength = RSSI.intValue
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Connected to: \(peripheral.name ?? "Unknown")")
        
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        isConnecting = false
        isConnected = false
        isNavigationReady = false
        peripheralName = peripheral.name ?? "BikeComputer"
        startMonitoringRSSI()
        startAuthenticationTimeout(for: peripheral)
        
        // Reset reconnection state on successful connection (Optimization #14)
        resetReconnectionState()
        
        // Discover services
        peripheral.discoverServices([serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, 
                       didDisconnectPeripheral peripheral: CBPeripheral, 
                       error: Error?) {
        log("Disconnected from: \(peripheral.name ?? "Unknown")")
        
        if let error = error {
            log("Disconnect error: \(error.localizedDescription)")
        }
        
        isConnected = false
        isConnecting = false
        supportsDeviceSettings = false
        connectedPeripheral = nil
        navigationCharacteristic = nil
        authCharacteristic = nil
        routeGeometryCharacteristic = nil
        gpsPositionCharacteristic = nil
        settingsCharacteristic = nil
        navigationWriteEndpoint = nil
        isNavigationReady = false
        pendingAuthNonce = nil
        authWriteState = .idle
        navigationWriteQueue.removeAll()
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        stopMonitoringRSSI()

        if shouldPairAfterDisconnect {
            shouldPairAfterDisconnect = false
            forgetTrustedPeripheralForFreshScan()
            beginPairing()
            return
        }

        if suppressNextReconnect {
            suppressNextReconnect = false
            log("Suppressing reconnect after auth write failure")
            return
        }
        
        // Auto-reconnect if enabled with exponential backoff
        if autoReconnect {
            scheduleReconnectWithBackoff()
        }
    }
    
    // MARK: - Exponential Backoff Reconnection (Optimization #14)
    
    private func scheduleReconnectWithBackoff() {
        reconnectTimer?.invalidate()
        
        guard reconnectAttempts < maxReconnectAttempts else {
            log("Max reconnection attempts reached (\(maxReconnectAttempts))")
            reconnectAttempts = 0
            return
        }
        
        // Calculate delay with exponential backoff: base * 2^attempts
        let delay = min(baseReconnectDelay * pow(2.0, Double(reconnectAttempts)), maxReconnectDelay)
        reconnectAttempts += 1
        
        log("Reconnection attempt \(reconnectAttempts)/\(maxReconnectAttempts) in \(String(format: "%.1f", delay))s")
        
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.reconnectToLastDevice()
        }
    }
    
    private func resetReconnectionState() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnectAttempts = 0
    }

    private func stopMonitoringRSSI() {
        rssiTimer?.invalidate()
        rssiTimer = nil
    }
    
    func centralManager(_ central: CBCentralManager, 
                       didFailToConnect peripheral: CBPeripheral, 
                       error: Error?) {
        log("Failed to connect to: \(peripheral.name ?? "Unknown")")
        clearConnectionState()
        
        if let error = error {
            log("Connection error: \(error.localizedDescription)")
        }
        
        // Retry after delay
        if autoReconnect {
            scheduleReconnectWithBackoff()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("Error discovering services: \(error.localizedDescription)")
            return
        }
        
        guard let services = peripheral.services else { return }
        
        for service in services {
            log("Discovered service: \(service.uuid)")
            
            if service.uuid == serviceUUID {
                log("Discovering all BikeComputer service characteristics")
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didDiscoverCharacteristicsFor service: CBService, 
                   error: Error?) {
        if let error = error {
            log("Error discovering characteristics: \(error.localizedDescription)")
            return
        }
        
        guard let characteristics = service.characteristics else { return }
        
        for characteristic in characteristics {
            log("Discovered characteristic: \(characteristic.uuid) props=\(characteristic.properties.debugDescription)")
            
            if characteristic.uuid == characteristicUUID {
                guard characteristic.properties.contains(.writeWithoutResponse) else {
                    log("Navigation characteristic does not support write without response")
                    continue
                }

                navigationCharacteristic = characteristic
                beginAuthenticationIfReady(for: peripheral, source: "navigation characteristic")
                scheduleAuthenticationRetry(for: peripheral)
            }

            if characteristic.uuid == authCharacteristicUUID {
                authCharacteristic = characteristic
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                    scheduleAuthenticationRetry(for: peripheral)
                } else {
                    beginAuthenticationIfReady(for: peripheral, source: "auth characteristic")
                    scheduleAuthenticationRetry(for: peripheral)
                }
            }

            if characteristic.uuid == routeGeometryCharacteristicUUID {
                guard characteristic.properties.contains(.writeWithoutResponse) else {
                    log("Route geometry characteristic does not support write without response")
                    continue
                }
                routeGeometryCharacteristic = characteristic
            }

            if characteristic.uuid == gpsPositionCharacteristicUUID {
                guard characteristic.properties.contains(.writeWithoutResponse) else {
                    log("GPS characteristic does not support write without response")
                    continue
                }
                gpsPositionCharacteristic = characteristic
            }

            if characteristic.uuid == settingsCharacteristicUUID {
                guard characteristic.properties.contains(.writeWithoutResponse) else {
                    log("Settings characteristic does not support write without response")
                    continue
                }
                settingsCharacteristic = characteristic
                supportsDeviceSettings = true
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                   didUpdateNotificationStateFor characteristic: CBCharacteristic,
                   error: Error?) {
        if let error = error {
            log("Error updating notifications: \(error.localizedDescription)")
            return
        }

        if characteristic.uuid == authCharacteristicUUID {
            beginAuthenticationIfReady(for: peripheral, source: "notify enabled")
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard isNavigationReady, let endpoint = navigationWriteEndpoint else { return }
        flushPendingNavigationWrites(endpoint: endpoint)
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didWriteValueFor characteristic: CBCharacteristic, 
                   error: Error?) {
        if let error = error {
            log("Error writing characteristic \(characteristic.uuid): \(error.localizedDescription); props=\(characteristic.properties.debugDescription)")
            if characteristic.uuid == authCharacteristicUUID {
                suppressNextReconnect = true
                isPairingMode = false
                clearConnectionState()
                centralManager.cancelPeripheralConnection(peripheral)
            }
            return
        }

        if characteristic.uuid == authCharacteristicUUID {
            authWriteCompleted(for: peripheral, characteristic: characteristic)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didUpdateValueFor characteristic: CBCharacteristic, 
                   error: Error?) {
        if let error = error {
            log("Error reading characteristic: \(error.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value else { return }

        if characteristic.uuid == authCharacteristicUUID {
            handleAuthResponse(data, peripheral: peripheral, characteristic: characteristic)
            return
        }
        
        if let string = String(data: data, encoding: .utf8) {
            log("Received from ESP32: \(string)")
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

private extension DateFormatter {
    static let bleDebugTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// MARK: - Helper Extension

extension BLEManager {
    
    /// Read RSSI periodically to monitor connection strength
    func startMonitoringRSSI() {
        rssiTimer?.invalidate()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, let peripheral = self.connectedPeripheral, self.isConnected else {
                return
            }
            peripheral.readRSSI()
        }
    }
}
