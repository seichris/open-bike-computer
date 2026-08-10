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
#if canImport(UIKit)
import UIKit
#endif

struct NavigationWriteEndpoint {
    let maximumWriteLength: Int
    let expectsWriteResponse: Bool
    let canSend: () -> Bool
    let write: (Data) -> Void

    init(
        maximumWriteLength: Int,
        expectsWriteResponse: Bool = false,
        canSend: @escaping () -> Bool,
        write: @escaping (Data) -> Void
    ) {
        self.maximumWriteLength = maximumWriteLength
        self.expectsWriteResponse = expectsWriteResponse
        self.canSend = canSend
        self.write = write
    }
}

struct WorkoutTelemetryWriteEndpoint {
    let maximumWriteLength: Int
    let canSend: () -> Bool
    let write: (Data) -> Void

    init(
        maximumWriteLength: Int,
        canSend: @escaping () -> Bool = { true },
        write: @escaping (Data) -> Void
    ) {
        self.maximumWriteLength = maximumWriteLength
        self.canSend = canSend
        self.write = write
    }
}

enum GPSPositionWriteRoute: Equatable {
    case nativeWithoutResponse
    case nativeWithResponse
    case navigationFallback
}

enum GPSPositionWriteRouting {
    static func route(
        hasNativeWriteWithResponse: Bool,
        hasNativeWriteWithoutResponse: Bool,
        payloadLength: Int,
        protectionOverhead: Int,
        withResponseMaximum: Int,
        withoutResponseMaximum: Int
    ) -> GPSPositionWriteRoute {
        let protectedLength = payloadLength + protectionOverhead
        if hasNativeWriteWithResponse,
           protectedLength <= withResponseMaximum {
            return .nativeWithResponse
        }
        if hasNativeWriteWithoutResponse,
           protectedLength <= withoutResponseMaximum {
            return .nativeWithoutResponse
        }
        return .navigationFallback
    }
}

enum WorkoutTelemetryWriteRoute: Equatable {
    case nativeWithResponse
    case navigationFallback
    case nativeWithoutResponse
}

enum WorkoutTelemetryWriteRouting {
    static func route(
        hasNativeWriteWithResponse: Bool,
        hasNativeWriteWithoutResponse: Bool,
        navigationExpectsWriteResponse: Bool
    ) -> WorkoutTelemetryWriteRoute {
        if hasNativeWriteWithResponse {
            return .nativeWithResponse
        }
        // Prefer the acknowledged fallback over a dedicated unacknowledged
        // characteristic. Both transports share one ordered queue, so a
        // write-without-response credit stall at the priority head would also
        // block GPS, settings, and transfer traffic behind the workout pair.
        if navigationExpectsWriteResponse {
            return .navigationFallback
        }
        if hasNativeWriteWithoutResponse {
            return .nativeWithoutResponse
        }
        return .navigationFallback
    }
}

enum DeviceBLEProtocol {
    static let serviceUUIDString = "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1800"
    static let navigationCharacteristicUUIDString = "2A6E"
    static let authCharacteristicUUIDString = "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1002"
    static let routeGeometryCharacteristicUUIDString = "2A6F"
    static let gpsPositionCharacteristicUUIDString = "2A72"
    static let settingsCharacteristicUUIDString = "2A73"
    static let workoutTelemetryCharacteristicUUIDString =
        "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1003"
    static let rideAutomationCharacteristicUUIDString =
        "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1004"
    static let deviceInformationServiceUUIDString = "180A"
    static let modelNumberCharacteristicUUIDString = "2A24"
    static let firmwareRevisionCharacteristicUUIDString = "2A26"
    static let hardwareRevisionCharacteristicUUIDString = "2A27"
    static let manufacturerNameCharacteristicUUIDString = "2A29"

    static let routeGeometryFallbackPrefix = "MAPR"
    static let gpsPositionFallbackPrefix = "GPSP"
    static let settingsFallbackPrefix = "MSET"
    static let workoutTelemetryFallbackPrefix = "WTLM"
    static let rideAutomationFallbackPrefix = "RAUT"
    static let mapTransferControlPrefix = "MTRN"
    static let mapTransferStatusPrefix = "MSTS"
    static let mapTransferStatusChunkPrefix = "MSTC"
    static let deviceTransferControlPrefix = "DTRN"
    static let deviceTransferStatusPrefix = "DSTS"
    static let deviceTransferStatusChunkPrefix = "DSTC"
    static let deviceCapabilitiesPrefix = "CAPS"
    static let deviceCapabilitiesV2Prefix = "CAP2"
    static let soundPlayPrefix = "SNDP"
    static let powerButtonHonkPrefix = "SNDH"
    static let powerButtonHonkStatusPrefix = "SNHA"
    static let destinationCatalogChunkPrefix = "DLST"
    static let destinationRequestPrefix = "DREQ"
    static let destinationStatusPrefix = "DNST"
    static let workoutStartRequestPrefix = "WREQ"
    static let deviceSoundsCapabilityMask: UInt8 = 1 << 0
    static let powerButtonHonkCapabilityMask: UInt8 = 1 << 1
    static let powerButtonHonkAcknowledgementCapabilityMask: UInt8 = 1 << 2
    static let independentMapProfilesCapabilityMask: UInt8 = 1 << 3
    static let extendedMapVisibilityCapabilityMask: UInt8 = 1 << 4
    static let batteryStatusScreenCapabilityMask: UInt8 = 1 << 5
    static let destinationPickerCapabilityMask: UInt8 = 1 << 6
    static let workoutTelemetryCapabilityMask: UInt8 = 1 << 7
    static let birdsEyeMapNavigationExtendedCapabilityMask: UInt8 = 1 << 0
    static let birdsEyeMapNavigationPerspectiveExtendedCapabilityMask: UInt8 = 1 << 1
    static let birdsEyeMapNavigationStrongerPerspectiveExtendedCapabilityMask: UInt8 = 1 << 2
    static let streetLabelsCapabilityMask: UInt32 = 1 << 8
    static let birdsEyeMapNavigationCapabilityMask: UInt32 = 1 << 9
    static let birdsEyeMapNavigationPerspectiveCapabilityMask: UInt32 = 1 << 10
    static let birdsEyeMapNavigationStrongerPerspectiveCapabilityMask: UInt32 = 1 << 11
    static let osm3DBuildingsCapabilityMask: UInt32 = 1 << 12
    static let explicitInvalidGPSHeadingCapabilityMask: UInt32 = 1 << 13
    static let scopedWatchControllerCapabilityMask: UInt32 = 1 << 14
    static let rideAutomationCapabilityMask: UInt32 = 1 << 15
    static let deviceCapabilitiesVersion: UInt8 = 13
    static let workoutTelemetryFrameLength = 16
    static let workoutTelemetryOriginFrameLength = 28
    static let workoutTelemetryCoreCoalescingKey = "workout-telemetry-core"
    static let workoutTelemetryExtendedCoalescingKey =
        "workout-telemetry-extended"
    static let workoutTelemetryOriginCoalescingKey =
        "workout-telemetry-origin"
    static let navigationSnapshotCoalescingKey = "navigation-snapshot"
    static let gpsPositionCoalescingKey = "gps-position"
    // Large enough for the worst schema-v1 three-favorite catalog at the
    // minimum BLE write length, without retaining a long stale GPS backlog.
    static let fallbackWriteQueueCapacity = 64

    static let serviceRoadsVisibilityMask: Int32 = 1 << 10
    static let tracksVisibilityMask: Int32 = 1 << 11
    static let extendedVisibilityMarker: Int32 = 1 << 12
    static let defaultStreetWidth: Int32 = 4

    static let brightnessSettingID: UInt8 = 12
    static let enabledScreensSettingID: UInt8 = 13
    static let defaultScreenSettingID: UInt8 = 14
    static let disconnectedSleepTimeoutSettingID: UInt8 = 15
    static let mapPlusNavigationMinPolygonSizeSettingID: UInt8 = 16
    static let mapPlusNavigationDetailLevelSettingID: UInt8 = 17
    static let mapPlusNavigationRouteLineWidthSettingID: UInt8 = 18
    static let mapPlusNavigationZoomLevelSettingID: UInt8 = 19
    static let mapPlusNavigationVisibilityMaskSettingID: UInt8 = 20
    static let mapPlusNavigationStreetLineWidthSettingID: UInt8 = 21
    static let mapPlusNavigationPositionMarkerScaleSettingID: UInt8 = 22
    static let phoneBatteryLevelSettingID: UInt8 = 23
    static let phoneBatteryChargingSettingID: UInt8 = 24
    static let mapPlusNavigationBirdsEyeViewSettingID: UInt8 = 25
    static let mapPlusNavigationBirdsEyePerspectiveSettingID: UInt8 = 26
    static let mapLabelDensitySettingID: UInt8 = 27
    static let mapLabelLanguageModeSettingID: UInt8 = 28
    static let mapLabelTextSizeSettingID: UInt8 = 29
    static let mapLabelOrientationSettingID: UInt8 = 30
    static let mapPlusNavigationLabelDensitySettingID: UInt8 = 31
    static let mapPlusNavigationLabelLanguageModeSettingID: UInt8 = 32
    static let mapPlusNavigationLabelTextSizeSettingID: UInt8 = 33
    static let mapPlusNavigationLabelOrientationSettingID: UInt8 = 34
    static let mapPlusNavigation3DBuildingsSettingID: UInt8 = 35
    static let currentScreenMaskMarker: Int32 = 1 << 30
    static let defaultMapStreetLabelsEnabled = true
    static let defaultMapPlusNavigationStreetLabelsEnabled = false
    static let defaultStreetLabelDensity = 2
    static let defaultStreetLabelLanguageMode = 2
    static let defaultStreetLabelTextSize = 0
    static let defaultStreetLabelOrientation = 1

    static var serviceUUID: CBUUID { CBUUID(string: serviceUUIDString) }
    static var navigationCharacteristicUUID: CBUUID { CBUUID(string: navigationCharacteristicUUIDString) }
    static var authCharacteristicUUID: CBUUID { CBUUID(string: authCharacteristicUUIDString) }
    static var routeGeometryCharacteristicUUID: CBUUID { CBUUID(string: routeGeometryCharacteristicUUIDString) }
    static var gpsPositionCharacteristicUUID: CBUUID { CBUUID(string: gpsPositionCharacteristicUUIDString) }
    static var settingsCharacteristicUUID: CBUUID { CBUUID(string: settingsCharacteristicUUIDString) }
    static var workoutTelemetryCharacteristicUUID: CBUUID {
        CBUUID(string: workoutTelemetryCharacteristicUUIDString)
    }
    static var rideAutomationCharacteristicUUID: CBUUID {
        CBUUID(string: rideAutomationCharacteristicUUIDString)
    }
    static var deviceInformationServiceUUID: CBUUID { CBUUID(string: deviceInformationServiceUUIDString) }
    static var modelNumberCharacteristicUUID: CBUUID { CBUUID(string: modelNumberCharacteristicUUIDString) }
    static var firmwareRevisionCharacteristicUUID: CBUUID { CBUUID(string: firmwareRevisionCharacteristicUUIDString) }
    static var hardwareRevisionCharacteristicUUID: CBUUID { CBUUID(string: hardwareRevisionCharacteristicUUIDString) }
    static var manufacturerNameCharacteristicUUID: CBUUID { CBUUID(string: manufacturerNameCharacteristicUUIDString) }

    static func phoneBatteryPercentage(from batteryLevel: Float) -> Int32? {
        guard batteryLevel >= 0, batteryLevel <= 1 else { return nil }
        return Int32((batteryLevel * 100).rounded())
    }

    static func phoneBatteryChargingValue(isCharging: Bool) -> Int32 {
        isCharging ? 1 : 0
    }

    static func normalizedStreetLabelDensity(_ density: Int) -> Int {
        (1...3).contains(density) ? density : defaultStreetLabelDensity
    }

    static func effectiveStreetLabelDensity(
        enabled: Bool,
        density: Int
    ) -> Int32 {
        enabled ? Int32(normalizedStreetLabelDensity(density)) : 0
    }

    static func absoluteStreetWidth(fromLegacyBoost boost: Double) -> Double {
        normalizedStreetWidth(Double(defaultStreetWidth) + boost)
    }

    static func normalizedStreetWidth(_ width: Double) -> Double {
        min(max(width, 1), 24)
    }

    static func normalizedBrightnessPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 100 }
        return min(max(value.rounded(), 5), 100)
    }

    static func legacyStreetWidthBoost(fromAbsoluteWidth width: Int32) -> Int32 {
        min(max(width, 1), 24) - defaultStreetWidth
    }

    static func hardwareLabel(model: String?, hardware: String?) -> String {
        if let model, !model.isEmpty {
            return model
        }
        if let hardware, !hardware.isEmpty {
            return hardware
        }
        return ""
    }
}

enum DevicePacketRouting {
    static func sendPreferredThenFallback(
        preferred: () -> Bool,
        fallback: () -> Bool
    ) -> Bool {
        if preferred() {
            return true
        }
        return fallback()
    }
}

enum DeviceSound: UInt8, CaseIterable, Identifiable {
    case bellDing = 1
    case plasticBicycleHorn = 2
    case rotatingBicycleBell = 3
    case squeezeHorn = 5

    var id: UInt8 { rawValue }

    static let defaultSelection: DeviceSound = .plasticBicycleHorn
    static let defaultVolumePercent: Double = 70

    static func normalizedVolumePercent(_ volumePercent: Double) -> Double {
        guard volumePercent.isFinite else { return defaultVolumePercent }
        return min(max(volumePercent, 0), 100)
    }

    func playPacket(volumePercent: Double) -> Data {
        let volume = UInt8(Self.normalizedVolumePercent(volumePercent).rounded())
        var packet = Data(DeviceBLEProtocol.soundPlayPrefix.utf8)
        packet.append(rawValue)
        packet.append(volume)
        return packet
    }

    func powerButtonHonkPacket(
        enabled: Bool,
        volumePercent: Double,
        requestID: UInt32? = nil
    ) -> Data {
        let volume = UInt8(Self.normalizedVolumePercent(volumePercent).rounded())
        var packet = Data(DeviceBLEProtocol.powerButtonHonkPrefix.utf8)
        if let requestID {
            packet.append(UInt8(truncatingIfNeeded: requestID))
            packet.append(UInt8(truncatingIfNeeded: requestID >> 8))
            packet.append(UInt8(truncatingIfNeeded: requestID >> 16))
            packet.append(UInt8(truncatingIfNeeded: requestID >> 24))
        }
        packet.append(enabled ? 1 : 0)
        packet.append(rawValue)
        packet.append(volume)
        return packet
    }

    var title: String {
        switch self {
        case .bellDing:
            return "Bell Ding"
        case .plasticBicycleHorn:
            return "Bicycle Horn"
        case .rotatingBicycleBell:
            return "Rotating Bicycle Bell"
        case .squeezeHorn:
            return "Squeeze Horn"
        }
    }

    var systemImage: String {
        switch self {
        case .bellDing:
            return "bell.fill"
        case .plasticBicycleHorn:
            return "speaker.wave.2.fill"
        case .rotatingBicycleBell:
            return "bell.circle.fill"
        case .squeezeHorn:
            return "speaker.wave.3.fill"
        }
    }
}

enum DeviceScreen: Int, CaseIterable, Identifiable {
    case map = 0
    case navigation = 1
    case rideStats = 2
    case mapPlusNavigation = 3
    case batteryStatus = 4

    var id: Int { rawValue }
    var bit: Int { 1 << rawValue }

    var title: String {
        switch self {
        case .map:
            return "Map"
        case .navigation:
            return "Navigation"
        case .rideStats:
            return "Ride Stats"
        case .mapPlusNavigation:
            return "Map + Navigation"
        case .batteryStatus:
            return "Battery Status"
        }
    }

    static var allScreensMask: Int {
        allCases.reduce(0) { $0 | $1.bit }
    }

    static var legacyScreensMask: Int {
        allScreensMask & ~batteryStatus.bit
    }

    static var displayOrder: [DeviceScreen] {
        [.mapPlusNavigation, .rideStats, .map, .navigation, .batteryStatus]
    }

    static func normalizedMask(_ rawMask: Int) -> Int {
        normalizedMask(rawMask, supportedMask: allScreensMask)
    }

    static func normalizedMask(_ rawMask: Int, supportedMask: Int) -> Int {
        let availableMask = supportedMask & allScreensMask
        let mask = rawMask & availableMask
        return mask == 0 ? availableMask : mask
    }

    static func fallbackDefault(for rawDefault: Int, mask rawMask: Int) -> DeviceScreen {
        fallbackDefault(for: rawDefault, mask: rawMask, supportedMask: allScreensMask)
    }

    static func fallbackDefault(for rawDefault: Int,
                                mask rawMask: Int,
                                supportedMask: Int) -> DeviceScreen {
        let mask = normalizedMask(rawMask, supportedMask: supportedMask)
        let candidate = DeviceScreen(rawValue: rawDefault) ?? .mapPlusNavigation
        if mask & candidate.bit != 0 {
            return candidate
        }
        return displayOrder.first { mask & $0.bit != 0 } ?? .mapPlusNavigation
    }
}

enum DisconnectedSleepTimeout: Int, CaseIterable, Identifiable {
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case tenMinutes = 600
    case never = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .oneMinute:
            return "1 min"
        case .twoMinutes:
            return "2 min"
        case .fiveMinutes:
            return "5 min"
        case .tenMinutes:
            return "10 min"
        case .never:
            return "Never"
        }
    }

    var settingValue: Int32 {
        Int32(rawValue)
    }

    static func normalized(rawValue: Int) -> DisconnectedSleepTimeout {
        DisconnectedSleepTimeout(rawValue: rawValue) ?? .twoMinutes
    }
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

enum MapNavigationBirdsEyePerspective: Int, CaseIterable, Identifiable {
    case gentle = 0
    case standard = 1
    case strong = 2
    case veryStrong = 3
    case maximum = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .gentle: return "Gentle"
        case .standard: return "Standard"
        case .strong: return "Strong"
        case .veryStrong: return "Very Strong"
        case .maximum: return "Maximum"
        }
    }

    static let baselineCases: [Self] = [.gentle, .standard, .strong]

    func supportedValue(supportsStrongerPerspectives: Bool) -> Self {
        supportsStrongerPerspectives || rawValue <= Self.strong.rawValue
            ? self
            : .strong
    }

    static func normalized(rawValue: Int) -> Self {
        Self(rawValue: rawValue) ?? .standard
    }
}

private enum MapPlusNavigationDefaults {
    static let minPolygonSize: Double = 0
    static let detailLevel = 0
    static let routeLineWidth: Double = 15
    static let streetLineWidth: Double = 4
    static let positionMarkerScale: Double = 2
    static let zoomLevel = 3
    static let showBuildings = false
    static let showGreenSpace = false
    static let showPaths = false
    static let showTracks = false
    static let showMajorRoads = true
    static let showLocalStreets = true
    static let showServiceRoads = false
    static let showWater = true
    static let showRailways = false
    static let showOtherAreas = false
}

private final class WeakBLEManagerSendableBox: @unchecked Sendable {
    weak var value: BLEManager?

    init(_ value: BLEManager) {
        self.value = value
    }
}

#if HOST_TESTING
final class BLEScanDriverForTesting {
    struct Start: Equatable {
        let serviceUUIDs: [String]
        let allowsDuplicates: Bool
    }

    var isPoweredOn = true
    private(set) var isScanning = false
    private(set) var starts: [Start] = []
    private(set) var stopCount = 0

    func start(serviceUUIDs: [CBUUID], allowsDuplicates: Bool) {
        isScanning = true
        starts.append(Start(
            serviceUUIDs: serviceUUIDs.map(\.uuidString),
            allowsDuplicates: allowsDuplicates
        ))
    }

    func stop() {
        stopCount += 1
        isScanning = false
    }
}
#endif

class BLEManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var isScanning: Bool = false
    @Published var isConnected: Bool = false
    @Published var isNavigationReady: Bool = false
    @Published var supportsDeviceSettings: Bool = false
    @Published var supportsDeviceSounds: Bool = false
    @Published var supportsPowerButtonHonk: Bool = false
    @Published var supportsPowerButtonHonkAcknowledgement: Bool = false
    @Published private(set) var supportsIndependentMapProfiles: Bool = false
    @Published private(set) var supportsExtendedMapVisibility: Bool = false
    @Published private(set) var supportsBirdsEyeMapNavigation: Bool = false
    @Published private(set) var supportsBirdsEyeMapNavigationPerspective: Bool = false
    @Published private(set) var supportsBirdsEyeMapNavigationStrongerPerspective: Bool = false
    @Published private(set) var supportsBatteryStatusScreen: Bool = false
    @Published private(set) var supportsDestinationPicker: Bool = false
    @Published private(set) var supportsWorkoutTelemetry: Bool = false
    @Published private(set) var supportsRideAutomation: Bool = false
    @Published private(set) var supportsStreetLabels: Bool = false
    @Published private(set) var supports3DBuildings: Bool = false
    @Published private(set) var supportsExplicitInvalidGPSHeading: Bool = false
    @Published private(set) var supportsScopedWatchController: Bool = false
    @Published private(set) var watchControllerIDHex: String?
    @Published private(set) var watchControllerOperationStatus: String?
    @Published private(set) var watchControllerOperationError: String?
    @Published private(set) var watchConnectivityState =
        PhoneWatchConnectivityStateV1()
    @Published private(set) var powerButtonHonkConfigurationError: String?
    @Published private(set) var hasReceivedDeviceCapabilities: Bool = false
    @Published var peripheralName: String = ""
    @Published var hardwareLabel: String = ""
    @Published var signalStrength: Int = 0
    @Published var centralStateDescription: String = "unknown"
    @Published var trustedPeripheralDescription: String = "none"
    @Published private(set) var knownDevices: [KnownBikeComputerDevice] = []
    @Published private(set) var discoveredDevices: [DiscoveredBikeComputerDevice] = []
    @Published private(set) var isDiscoveringDevices = false
    @Published private(set) var currentScanPurpose: BLEScanPurpose = .none
    @Published private(set) var nearbyBicinoCandidate: DiscoveredBikeComputerDevice?
    @Published private(set) var isApplicationActive = false
    @Published private(set) var isOpportunisticDiscoverySuppressed = false
    @Published private(set) var observedIdentityMismatchDeviceIDs: Set<String> = []
    @Published private(set) var activeDeviceID: String?
    @Published private(set) var connectedDeviceID: String?
    @Published private(set) var pairingPrompt: BikeComputerPairingPrompt?
    @Published private(set) var isPairingConfirmedOnDevice = false
    @Published private(set) var isPairingConfirmationSubmitting = false
    @Published private(set) var completedPairingGeneration: UInt64 = 0
    @Published private(set) var pairingStatusMessage: String?
    @Published private(set) var pairingError: String?
    @Published private(set) var deviceOperationDeviceID: String?
    @Published private(set) var deviceFeedbackDeviceID: String?
    @Published var debugEvents: [String] = []
    @Published var mapTransferModeEnabled: Bool = false
    @Published var mapTransferBaseURL: URL?
    @Published var mapTransferAccessPointSSID: String?
    @Published var mapTransferActiveMapId: String = ""
    @Published var mapTransferActiveSessionId: String = ""
    @Published private(set) var activeMapManifestReceipt: String = ""
    @Published private(set) var activeMapRendererFormat: Int?
    @Published private(set) var activeMapLabelProfileVersion: Int?
    @Published private(set) var activeMapLabelLanguages: [String] = []
    @Published private(set) var activeMapFontAssetHealthy: Bool = false
    @Published var mapTransferActivationStatus: String = "idle"
    @Published var mapTransferActivationSequence: UInt32?
    @Published var mapTransferActivationSessionId: String = ""
    @Published var mapTransferActivationMapId: String = ""
    @Published var mapTransferActivationStep: Int?
    @Published var mapTransferActivationStepCount: Int?
    @Published var mapTransferActivationProgress: Int?
    @Published var mapTransferActivationError: String?
    @Published var mapTransferLastError: String?
    @Published var mapTransferStatusDescription: String = "unknown"
    @Published var deviceTransferMode: String = ""
    @Published var deviceTransferBaseURL: URL?
    @Published var deviceTransferAccessPointSSID: String?
    @Published var deviceTransferSessionToken: String?
    @Published private(set) var deviceTransferLastErrorCode: String?
    @Published private(set) var deviceTransferLastErrorMessage: String?
    @Published private(set) var deviceTransferStatusRevision: UInt64 = 0
    @Published var firmwareTarget: String = ""
    @Published var firmwareVersion: String = ""
    @Published var firmwareBuild: Int = 0
    @Published var firmwareGitSha: String = ""
    @Published var firmwareUpdateStatus: String = "unknown"
    @Published var firmwareUpdateReceivedBytes: Int = 0
    @Published var firmwareUpdateTotalBytes: Int = 0
    @Published var firmwareUpdateLastError: String?
    @Published var deviceHasSDCard: Bool?
    @Published var deviceMapFoundForCurrentLocation: Bool?
    @Published var deviceMapBlockCount: Int = 0
    
    // MARK: - Map Settings (persisted for UI display)
    @Published var minPolygonSize: Double = 0
    @Published var detailLevel: Int = 2
    @Published var routeLineWidth: Double = 4
    @Published var streetLineWidth: Double = 4
    @Published var positionMarkerScale: Double = 2
    @Published var mapRotationMode: Int = 0 // 0=North Up, 1=Course Up
    @Published var zoomLevel: Int = 3 // 0-5: 0=closest, 5=farthest
    @Published var mapLabelsEnabled = DeviceBLEProtocol.defaultMapStreetLabelsEnabled
    @Published var mapLabelDensity = DeviceBLEProtocol.defaultStreetLabelDensity
    @Published var mapLabelLanguageMode = DeviceBLEProtocol.defaultStreetLabelLanguageMode
    @Published var mapLabelTextSize = DeviceBLEProtocol.defaultStreetLabelTextSize
    @Published var mapLabelOrientation = DeviceBLEProtocol.defaultStreetLabelOrientation
    @Published var mapPlusNavigationMinPolygonSize = MapPlusNavigationDefaults.minPolygonSize
    @Published var mapPlusNavigationDetailLevel = MapPlusNavigationDefaults.detailLevel
    @Published var mapPlusNavigationRouteLineWidth = MapPlusNavigationDefaults.routeLineWidth
    @Published var mapPlusNavigationStreetLineWidth = MapPlusNavigationDefaults.streetLineWidth
    @Published var mapPlusNavigationPositionMarkerScale = MapPlusNavigationDefaults.positionMarkerScale
    @Published var mapPlusNavigationZoomLevel = MapPlusNavigationDefaults.zoomLevel
    @Published var mapPlusNavigationBirdsEyeViewEnabled = true
    @Published var mapPlusNavigationBirdsEyePerspective: MapNavigationBirdsEyePerspective = .standard
    @Published var mapPlusNavigation3DBuildingsEnabled = true
    @Published var mapPlusNavigationLabelsEnabled =
        DeviceBLEProtocol.defaultMapPlusNavigationStreetLabelsEnabled
    @Published var mapPlusNavigationLabelDensity = DeviceBLEProtocol.defaultStreetLabelDensity
    @Published var mapPlusNavigationLabelLanguageMode = DeviceBLEProtocol.defaultStreetLabelLanguageMode
    @Published var mapPlusNavigationLabelTextSize = DeviceBLEProtocol.defaultStreetLabelTextSize
    @Published var mapPlusNavigationLabelOrientation = DeviceBLEProtocol.defaultStreetLabelOrientation
    @Published var tapToSwitchScreens: Bool = false
    @Published var enabledDeviceScreensMask: Int = DeviceScreen.allScreensMask
    @Published var defaultDeviceScreen: DeviceScreen = .mapPlusNavigation
    @Published var deviceBrightnessPercent: Double = 100
    @Published var disconnectedSleepTimeout: DisconnectedSleepTimeout = .twoMinutes
    @Published var selectedDeviceSound: DeviceSound = .defaultSelection
    @Published var deviceSoundVolumePercent: Double = DeviceSound.defaultVolumePercent
    @Published var isPowerButtonHonkEnabled: Bool = false
    private var isLoadingSettings = true
    private var shouldApply3DBuildingVisibilityDefault = false
    
    // Feature Visibility
    @Published var showBuildings: Bool = true
    @Published var showGreenSpace: Bool = true
    @Published var showPaths: Bool = true
    @Published var showTracks: Bool = true
    @Published var showMajorRoads: Bool = true
    @Published var showLocalStreets: Bool = true
    @Published var showServiceRoads: Bool = true
    @Published var showWater: Bool = true
    @Published var showRailways: Bool = true
    @Published var showOtherAreas: Bool = true
    @Published var mapPlusNavigationShowBuildings = MapPlusNavigationDefaults.showBuildings {
        didSet {
            if !isLoadingSettings && oldValue != mapPlusNavigationShowBuildings {
                shouldApply3DBuildingVisibilityDefault = false
                UserDefaults.standard.set(
                    mapPlusNavigationShowBuildings,
                    forKey: SettingsKeys.mapPlusNavigationShowBuildings
                )
                UserDefaults.standard.set(
                    false,
                    forKey: SettingsKeys.mapPlusNavigationBuildingVisibilityDefaultPending
                )
            }
        }
    }
    @Published var mapPlusNavigationShowGreenSpace = MapPlusNavigationDefaults.showGreenSpace
    @Published var mapPlusNavigationShowPaths = MapPlusNavigationDefaults.showPaths
    @Published var mapPlusNavigationShowTracks = MapPlusNavigationDefaults.showTracks
    @Published var mapPlusNavigationShowMajorRoads = MapPlusNavigationDefaults.showMajorRoads
    @Published var mapPlusNavigationShowLocalStreets = MapPlusNavigationDefaults.showLocalStreets
    @Published var mapPlusNavigationShowServiceRoads = MapPlusNavigationDefaults.showServiceRoads
    @Published var mapPlusNavigationShowWater = MapPlusNavigationDefaults.showWater
    @Published var mapPlusNavigationShowRailways = MapPlusNavigationDefaults.showRailways
    @Published var mapPlusNavigationShowOtherAreas = MapPlusNavigationDefaults.showOtherAreas
    @Published var showRouteOverlay: Bool = true
    @Published var showCurrentPosition: Bool = true
    
    // MARK: - BLE UUIDs (matching ESP32)
    private let serviceUUID = DeviceBLEProtocol.serviceUUID
    private let characteristicUUID = DeviceBLEProtocol.navigationCharacteristicUUID
    private let authCharacteristicUUID = DeviceBLEProtocol.authCharacteristicUUID
    private let routeGeometryCharacteristicUUID = DeviceBLEProtocol.routeGeometryCharacteristicUUID
    private let gpsPositionCharacteristicUUID = DeviceBLEProtocol.gpsPositionCharacteristicUUID
    private let settingsCharacteristicUUID = DeviceBLEProtocol.settingsCharacteristicUUID
    private let workoutTelemetryCharacteristicUUID =
        DeviceBLEProtocol.workoutTelemetryCharacteristicUUID
    private let rideAutomationCharacteristicUUID =
        DeviceBLEProtocol.rideAutomationCharacteristicUUID
    private let deviceInformationServiceUUID = DeviceBLEProtocol.deviceInformationServiceUUID
    private let modelNumberCharacteristicUUID = DeviceBLEProtocol.modelNumberCharacteristicUUID
    private let firmwareRevisionCharacteristicUUID = DeviceBLEProtocol.firmwareRevisionCharacteristicUUID
    private let hardwareRevisionCharacteristicUUID = DeviceBLEProtocol.hardwareRevisionCharacteristicUUID
    private let manufacturerNameCharacteristicUUID = DeviceBLEProtocol.manufacturerNameCharacteristicUUID
    
    // MARK: - Private Properties
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var navigationCharacteristic: CBCharacteristic?
    private var authCharacteristic: CBCharacteristic?
    private var routeGeometryCharacteristic: CBCharacteristic?
    private var gpsPositionCharacteristic: CBCharacteristic?
    private var settingsCharacteristic: CBCharacteristic?
    private var workoutTelemetryCharacteristic: CBCharacteristic?
    private var rideAutomationCharacteristic: CBCharacteristic?
    private var workoutTelemetryWriteEndpointForTesting: WorkoutTelemetryWriteEndpoint?
    private var deviceInformation: [CBUUID: String] = [:]
    private var navigationWriteEndpoint: NavigationWriteEndpoint?
    private var navigationWriteQueue = NavigationWriteQueue(
        maxCount: DeviceBLEProtocol.fallbackWriteQueueCapacity,
        // One complete workout pair plus the latest destination status,
        // maneuver snapshot, transfer control, and transfer status must
        // coexist while an acknowledged write is in flight.
        priorityMaxCount: 6
    )
    private var lastNavigationQueuePendingLogAt = Date.distantPast
#if DEBUG
    private var navigationQueueMetricsTimer: Timer?
    private var lastNavigationQueueMetricsUptime: TimeInterval = 0
#endif
    @Published private(set) var isConnecting: Bool = false
    private var isPairingMode: Bool = false
    private var pendingAuthNonce: String?
    private enum AuthFlowState {
        case idle
        case waitingForInfo
        case legacy(nonce: String)
        case pairing
        case awaitingPairingConfirmation
        case owner(clientNonce: String, serverNonce: String?, deviceID: String, ownerID: Data, ownerKey: Data)
        case authenticated
    }
    private var authFlowState: AuthFlowState = .idle
    private var authenticatedWriteSession: AuthenticatedBLEWriteSession?
    private var authWriteInFlight = false
    private var queuedAuthMessages: [Data] = []
    private var authInfoFallbackTimer: Timer?
    private var authInfoAttempts = 0
    private let deviceRegistry = BikeComputerDeviceRegistry()
    private var pendingPairingSession: DevicePairingSession?
    private var pendingPairingMaterial: DevicePairingMaterial?
    private var pendingPairingCandidate: DiscoveredBikeComputerDevice?
    private var ownershipLifecycle = BLEOwnershipLifecycle()
    private var ownerAuthenticationUsesProvisionalKey = false
    private weak var watchConnectivityCoordinator:
        (any PhoneWatchControllerTransporting)?
    private enum PendingWatchControllerOperation {
        case staging(WatchControllerCredentialV1)
        case requestingProof(
            WatchControllerCredentialV1,
            challenge: Data
        )
        case committing(WatchControllerCredentialV1)
        case revoking(deviceID: String, controllerID: Data)
    }
    private var pendingWatchControllerOperation:
        PendingWatchControllerOperation?
    private var hasReceivedWatchControllerStatus = false
    private var isWatchControllerPromotionInFlight = false
    private var pendingDeregistrationDeviceID: String?
    private var pendingRenameDeviceID: String?
    private var deviceOperationTimeoutTimer: Timer?
    private var pendingConnectionAfterDisconnect: UUID?
    private var pendingScannedConnectionIdentifier: UUID?
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var discoveryFreshnessTimer: Timer?
    private var pendingScanStartWorkItem: DispatchWorkItem?
    private var lastPhysicalScanStoppedAt: Date?
    private var unknownScanObservationGate =
        BLEUnknownScanObservationGate()
#if HOST_TESTING
    private var scanDriverForTesting: BLEScanDriverForTesting?
#endif
    private var opportunisticSelectionTimer: Timer?
    private var opportunisticCandidateExpiryTimer: Timer?
    private var discoveryGeneration: UInt64 = 0
    private var activeDiscoveryGeneration: UInt64?
    private var opportunisticObservations:
        [UUID: BLEDiscoveryObservation] = [:]
    private var isNearbyBicinoCandidatePresented = false
    private var explicitDiscoveryRequested = false
    private var isExplicitDiscoveryPausedForCandidate = false
    private var isUnknownDeviceDiscoverySuspended = false
    private var pairingDiscoveryOrigin: BLEDiscoveryOrigin?
    private var locallyForgottenPeripheralIdentifiers: Set<UUID> = []
    
    private var autoReconnect: Bool = true
    private var watchDirectRidePreparedDeviceID: String?
    private var watchDirectRidePreparationID: UUID?
    private var watchDirectRidePreviousAutoReconnect: Bool?
    private var watchDirectRidePreparationExpiryTimer: Timer?
    private var watchDirectRideReleaseTombstones:
        [WatchDirectRideReleaseTombstone] = []
    private var lastConnectedPeripheralIdentifier: UUID?
    
    // MARK: - Reconnection with Exponential Backoff (Optimization #14)
    private var reconnectAttempts: Int = 0
    private var baseReconnectDelay: TimeInterval = 1.0 // Start with 1 second
    private var maxReconnectDelay: TimeInterval = 60.0 // Cap at 60 seconds
    private var reconnectTimer: Timer?
    private var rssiTimer: Timer?
    private var navigationFlushRetryTimer: Timer?
    private var mapTransferStatusChunkTransferID: UInt8?
    private var mapTransferStatusChunkCount: UInt8 = 0
    private var mapTransferStatusChunks: [UInt8: Data] = [:]
    private var deviceTransferStatusChunkTransferID: UInt8?
    private var deviceTransferStatusChunkCount: UInt8 = 0
    private var deviceTransferStatusChunks: [UInt8: Data] = [:]
    private var writeWithResponseInFlight = false
    private var navigationWriteWithResponseFailureHandler: (() -> Void)?
    private var navigationWriteWithResponseLabel: String?
    private var navigationWriteResponseTimeoutTimer: Timer?
    private var navigationWriteResponseGeneration: UInt64 = 0
    private var navigationBackpressureStartedAt: Date?
#if HOST_TESTING
    private var navigationWriteResponseTimeout: TimeInterval = 60
#else
    private var navigationWriteResponseTimeout: TimeInterval = 3
#endif
    private var navigationWriteStallRecoveryForTesting: (() -> Void)?
    private var connectionTimeoutTimer: Timer?
    private var pendingScannedConnectionTimeoutTimer: Timer?
    private var authRetryTimer: Timer?
    private var authTimeoutTimer: Timer?
    private var pendingPowerButtonHonkPacket: Data?
    private var powerButtonHonkAttempt = 0
    private var nextPowerButtonHonkRequestID: UInt32 = 1
    private var nextDestinationCatalogTransferID: UInt8 = 1
    private var destinationStatusSequence: UInt64 = 0
    private var powerButtonHonkRetryWorkItem: DispatchWorkItem?
    private var powerButtonHonkRetryScheduler: (TimeInterval, DispatchWorkItem) -> Void = { delay, workItem in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    private var powerButtonHonkAckTimeout: TimeInterval = 1.0
    private var powerButtonHonkFailureRetryDelay: TimeInterval = 0.1
    private var hasSentMapProfileForConnection = false
    private var hasSentMapNavigationProfileForConnection = false
    private var hasSentScreenSettingsForConnection = false
    private var isSendingNegotiatedMapProfiles = false
    private var lastSentPhoneBatteryPercent: Int32?
    private var lastSentPhoneBatteryCharging: Bool?
    private var suppressNextReconnect: Bool = false
    private var hasActiveBLESession: Bool {
        isConnected || isConnecting || connectedPeripheral != nil
    }

    var hasActiveTransportSession: Bool { hasActiveBLESession }

    var onDestinationRequest: ((DeviceDestinationRequest) -> Void)?
    var onWorkoutStartRequest: (() -> Void)?
    var onRideAutomationFrame: ((RideAutomationFrame) -> Void)?
    var onDestinationCatalogWriteFailure: (() -> Void)?
    
    // MARK: - UserDefaults Keys
    private enum SettingsKeys {
        static let minPolygonSize = "mapSettings.minPolygonSize"
        static let detailLevel = "mapSettings.detailLevel"
        static let routeLineWidth = "mapSettings.routeLineWidth"
        static let streetLineWidth = "mapSettings.streetLineWidth"
        static let legacyStreetLineWidthBoost = "mapSettings.streetLineWidthBoost"
        static let positionMarkerScale = "mapSettings.positionMarkerScale"
        static let mapRotationMode = "mapSettings.mapRotationMode"
        static let resetMapRotationModeToNorthUp = "mapSettings.resetMapRotationModeToNorthUp.v1"
        static let zoomLevel = "mapSettings.zoomLevel"
        static let mapLabelsEnabled = "mapSettings.labelsEnabled"
        static let mapLabelDensity = "mapSettings.labelDensity"
        static let mapLabelLanguageMode = "mapSettings.labelLanguageMode"
        static let mapLabelTextSize = "mapSettings.labelTextSize"
        static let mapLabelOrientation = "mapSettings.labelOrientation"
        static let mapPlusNavigationMinPolygonSize = "mapPlusNavigationSettings.minPolygonSize"
        static let mapPlusNavigationDetailLevel = "mapPlusNavigationSettings.detailLevel"
        static let mapPlusNavigationRouteLineWidth = "mapPlusNavigationSettings.routeLineWidth"
        static let mapPlusNavigationStreetLineWidth = "mapPlusNavigationSettings.streetLineWidth"
        static let legacyMapPlusNavigationStreetLineWidthBoost = "mapPlusNavigationSettings.streetLineWidthBoost"
        static let mapPlusNavigationPositionMarkerScale = "mapPlusNavigationSettings.positionMarkerScale"
        static let mapPlusNavigationZoomLevel = "mapPlusNavigationSettings.zoomLevel"
        static let mapPlusNavigationBirdsEyeViewEnabled = "mapPlusNavigationSettings.birdsEyeViewEnabled"
        static let mapPlusNavigationBirdsEyePerspective = "mapPlusNavigationSettings.birdsEyePerspective"
        static let mapPlusNavigation3DBuildingsEnabled = "mapPlusNavigationSettings.3dBuildingsEnabled"
        static let mapPlusNavigationLabelsEnabled = "mapPlusNavigationSettings.labelsEnabled"
        static let mapPlusNavigationLabelDensity = "mapPlusNavigationSettings.labelDensity"
        static let mapPlusNavigationLabelLanguageMode = "mapPlusNavigationSettings.labelLanguageMode"
        static let mapPlusNavigationLabelTextSize = "mapPlusNavigationSettings.labelTextSize"
        static let mapPlusNavigationLabelOrientation = "mapPlusNavigationSettings.labelOrientation"
        static let mapPlusNavigationShowBuildings = "mapPlusNavigationSettings.showBuildings"
        static let mapPlusNavigationBuildingVisibilityDefaultPending =
            "mapPlusNavigationSettings.buildingVisibilityDefaultPending.v1"
        static let mapPlusNavigationShowGreenSpace = "mapPlusNavigationSettings.showGreenSpace"
        static let mapPlusNavigationShowPaths = "mapPlusNavigationSettings.showPaths"
        static let mapPlusNavigationShowTracks = "mapPlusNavigationSettings.showTracks"
        static let mapPlusNavigationShowMajorRoads = "mapPlusNavigationSettings.showMajorRoads"
        static let mapPlusNavigationShowLocalStreets = "mapPlusNavigationSettings.showLocalStreets"
        static let mapPlusNavigationShowServiceRoads = "mapPlusNavigationSettings.showServiceRoads"
        static let mapPlusNavigationShowWater = "mapPlusNavigationSettings.showWater"
        static let mapPlusNavigationShowRailways = "mapPlusNavigationSettings.showRailways"
        static let mapPlusNavigationShowOtherAreas = "mapPlusNavigationSettings.showOtherAreas"
        static let mapPlusNavigationProfileMigrated = "mapPlusNavigationSettings.migrated.v1"
        static let recommendedMapDefaultsMigrated = "mapSettings.recommendedDefaults.v2"
        static let streetLabelDefaultsMigrated = "streetLabels.defaults.v1"
        static let tapToSwitchScreens = "deviceSettings.tapToSwitchScreens"
        static let enabledDeviceScreensMask = "deviceSettings.enabledScreensMask"
        static let defaultDeviceScreen = "deviceSettings.defaultScreen"
        static let defaultDeviceScreenMigrated = "deviceSettings.defaultScreen.mapPlusNavigationDefault.v1"
        static let batteryStatusScreenMigrated = "deviceSettings.enabledScreensMask.batteryStatus.v1"
        static let deviceBrightnessPercent = "deviceSettings.brightnessPercent"
        static let disconnectedSleepTimeoutSeconds = "deviceSettings.disconnectedSleepTimeoutSeconds"
        static let watchControllerIDsByDevice =
            "deviceSettings.watchControllerIDsByDevice.v1"
        static let selectedDeviceSound = "deviceSettings.selectedSound"
        static let deviceSoundVolumePercent = "deviceSettings.soundVolumePercent"
        static let powerButtonHonkEnabled = "deviceSettings.powerButtonHonkEnabled"
        static let showBuildings = "mapSettings.showBuildings"
        static let showGreenSpace = "mapSettings.showGreenSpace"
        static let showPaths = "mapSettings.showPaths"
        static let showTracks = "mapSettings.showTracks"
        static let showMajorRoads = "mapSettings.showMajorRoads"
        static let showLocalStreets = "mapSettings.showLocalStreets"
        static let showServiceRoads = "mapSettings.showServiceRoads"
        static let showWater = "mapSettings.showWater"
        static let showRailways = "mapSettings.showRailways"
        static let showOtherAreas = "mapSettings.showOtherAreas"
        static let showRouteOverlay = "mapSettings.showRouteOverlay"
        static let showCurrentPosition = "mapSettings.showCurrentPosition"
        static let legacyShowNature = "mapSettings.showNature"
        static let legacyShowMinorRoads = "mapSettings.showMinorRoads"
        static let lastPeripheralIdentifier = "ble.lastPeripheralIdentifier"
        static let watchDirectRidePreparedDeviceID =
            "ble.watchDirectRidePreparedDeviceID.v1"
        static let watchDirectRidePreviousAutoReconnect =
            "ble.watchDirectRidePreviousAutoReconnect.v1"
        static let watchDirectRidePreparationID =
            "ble.watchDirectRidePreparationID.v1"
        static let watchDirectRidePreparationExpiresAt =
            "ble.watchDirectRidePreparationExpiresAt.v1"
        static let watchDirectRideReleaseTombstones =
            "ble.watchDirectRideReleaseTombstones.v1"
    }

    private struct WatchDirectRideReleaseTombstone: Codable {
        let deviceID: String
        let preparationID: UUID
        let expiresAt: Date
    }
    
    // MARK: - Initialization
    override init() {
        super.init()
#if canImport(UIKit) && !HOST_TESTING
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(phoneBatteryStatusDidChange(_:)),
            name: UIDevice.batteryLevelDidChangeNotification,
            object: UIDevice.current
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(phoneBatteryStatusDidChange(_:)),
            name: UIDevice.batteryStateDidChangeNotification,
            object: UIDevice.current
        )
#endif
        loadSettings()
        isLoadingSettings = false
        loadLastPeripheralIdentifier()
        migrateLegacyPeripheralIfNeeded()
        refreshKnownDevices()
        restoreWatchDirectRidePreparation()
        updateTrustedPeripheralDescription()
#if canImport(UIKit) && !HOST_TESTING
        // Load the active-device registry before CoreBluetooth can deliver a
        // restoration callback, so an old peripheral can never replace the
        // user's current Bike Computer during app launch.
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey:
                    "BikeComputer.central.v2"
            ]
        )
#endif
        log("BLE debug session started")
#if DEBUG
        lastNavigationQueueMetricsUptime = ProcessInfo.processInfo.systemUptime
        let metricsTimer = Timer(
            timeInterval: 10,
            repeats: true
        ) { [weak self] _ in
            self?.logNavigationQueueMetricsInterval()
        }
        RunLoop.main.add(metricsTimer, forMode: .common)
        navigationQueueMetricsTimer = metricsTimer
#endif
    }

    deinit {
#if DEBUG
        navigationQueueMetricsTimer?.invalidate()
#endif
#if canImport(UIKit) && !HOST_TESTING
        NotificationCenter.default.removeObserver(
            self,
            name: UIDevice.batteryLevelDidChangeNotification,
            object: UIDevice.current
        )
        NotificationCenter.default.removeObserver(
            self,
            name: UIDevice.batteryStateDidChangeNotification,
            object: UIDevice.current
        )
#endif
    }

#if canImport(UIKit) && !HOST_TESTING
    @objc private func phoneBatteryStatusDidChange(_ notification: Notification) {
        sendPhoneBatteryStatus()
    }
#endif
    
    private func loadSettings() {
        let defaults = UserDefaults.standard
        minPolygonSize = defaults.double(forKey: SettingsKeys.minPolygonSize)
        detailLevel = defaults.object(forKey: SettingsKeys.detailLevel) as? Int ?? 2
        routeLineWidth = defaults.object(forKey: SettingsKeys.routeLineWidth) as? Double ?? 4.0
        if let storedWidth = defaults.object(forKey: SettingsKeys.streetLineWidth) as? Double {
            streetLineWidth = DeviceBLEProtocol.normalizedStreetWidth(storedWidth)
        } else {
            let legacyBoost = defaults.object(
                forKey: SettingsKeys.legacyStreetLineWidthBoost
            ) as? Double ?? 0
            streetLineWidth = DeviceBLEProtocol.absoluteStreetWidth(
                fromLegacyBoost: legacyBoost
            )
        }
        positionMarkerScale = defaults.object(forKey: SettingsKeys.positionMarkerScale) as? Double ?? 2.0
        if defaults.bool(forKey: SettingsKeys.resetMapRotationModeToNorthUp) {
            mapRotationMode = defaults.object(forKey: SettingsKeys.mapRotationMode) as? Int ?? 0
        } else {
            mapRotationMode = 0
            defaults.set(0, forKey: SettingsKeys.mapRotationMode)
            defaults.set(true, forKey: SettingsKeys.resetMapRotationModeToNorthUp)
        }
        zoomLevel = defaults.object(forKey: SettingsKeys.zoomLevel) as? Int ?? 3
        let shouldMigrateStreetLabelDefaults = !defaults.bool(
            forKey: SettingsKeys.streetLabelDefaultsMigrated
        )
        if shouldMigrateStreetLabelDefaults {
            mapLabelsEnabled = DeviceBLEProtocol.defaultMapStreetLabelsEnabled
            mapLabelDensity = DeviceBLEProtocol.defaultStreetLabelDensity
            mapLabelLanguageMode = DeviceBLEProtocol.defaultStreetLabelLanguageMode
            mapLabelTextSize = DeviceBLEProtocol.defaultStreetLabelTextSize
            mapLabelOrientation = DeviceBLEProtocol.defaultStreetLabelOrientation
            mapPlusNavigationLabelsEnabled =
                DeviceBLEProtocol.defaultMapPlusNavigationStreetLabelsEnabled
            mapPlusNavigationLabelDensity = DeviceBLEProtocol.defaultStreetLabelDensity
            mapPlusNavigationLabelLanguageMode = DeviceBLEProtocol.defaultStreetLabelLanguageMode
            mapPlusNavigationLabelTextSize = DeviceBLEProtocol.defaultStreetLabelTextSize
            mapPlusNavigationLabelOrientation = DeviceBLEProtocol.defaultStreetLabelOrientation
            defaults.set(true, forKey: SettingsKeys.streetLabelDefaultsMigrated)
        } else {
            mapLabelsEnabled = defaults.object(
                forKey: SettingsKeys.mapLabelsEnabled
            ) as? Bool ?? DeviceBLEProtocol.defaultMapStreetLabelsEnabled
            mapLabelDensity = DeviceBLEProtocol.normalizedStreetLabelDensity(
                defaults.object(forKey: SettingsKeys.mapLabelDensity) as? Int
                    ?? DeviceBLEProtocol.defaultStreetLabelDensity
            )
            mapLabelLanguageMode = min(max(
                defaults.object(forKey: SettingsKeys.mapLabelLanguageMode) as? Int
                    ?? DeviceBLEProtocol.defaultStreetLabelLanguageMode,
                0
            ), 2)
            mapLabelTextSize = min(max(
                defaults.object(forKey: SettingsKeys.mapLabelTextSize) as? Int
                    ?? DeviceBLEProtocol.defaultStreetLabelTextSize,
                0
            ), 2)
            mapLabelOrientation = min(max(
                defaults.object(forKey: SettingsKeys.mapLabelOrientation) as? Int
                    ?? DeviceBLEProtocol.defaultStreetLabelOrientation,
                0
            ), 1)
            mapPlusNavigationLabelsEnabled = defaults.object(
                forKey: SettingsKeys.mapPlusNavigationLabelsEnabled
            ) as? Bool ?? DeviceBLEProtocol.defaultMapPlusNavigationStreetLabelsEnabled
            mapPlusNavigationLabelDensity = DeviceBLEProtocol.normalizedStreetLabelDensity(
                defaults.object(
                    forKey: SettingsKeys.mapPlusNavigationLabelDensity
                ) as? Int ?? DeviceBLEProtocol.defaultStreetLabelDensity
            )
            mapPlusNavigationLabelLanguageMode = min(max(
                defaults.object(
                    forKey: SettingsKeys.mapPlusNavigationLabelLanguageMode
                ) as? Int ?? DeviceBLEProtocol.defaultStreetLabelLanguageMode,
                0
            ), 2)
            mapPlusNavigationLabelTextSize = min(max(
                defaults.object(
                    forKey: SettingsKeys.mapPlusNavigationLabelTextSize
                ) as? Int ?? DeviceBLEProtocol.defaultStreetLabelTextSize,
                0
            ), 2)
            mapPlusNavigationLabelOrientation = min(max(
                defaults.object(
                    forKey: SettingsKeys.mapPlusNavigationLabelOrientation
                ) as? Int ?? DeviceBLEProtocol.defaultStreetLabelOrientation,
                0
            ), 1)
        }
        tapToSwitchScreens = defaults.object(forKey: SettingsKeys.tapToSwitchScreens) as? Bool ?? false
        var storedScreensMask = defaults.object(forKey: SettingsKeys.enabledDeviceScreensMask) as? Int
            ?? DeviceScreen.allScreensMask
        if !defaults.bool(forKey: SettingsKeys.batteryStatusScreenMigrated) {
            storedScreensMask |= DeviceScreen.batteryStatus.bit
            defaults.set(storedScreensMask, forKey: SettingsKeys.enabledDeviceScreensMask)
            defaults.set(true, forKey: SettingsKeys.batteryStatusScreenMigrated)
        }
        enabledDeviceScreensMask = DeviceScreen.normalizedMask(storedScreensMask)
        let storedDefaultScreen = defaults.object(forKey: SettingsKeys.defaultDeviceScreen) as? Int
        let shouldMigrateDefaultScreen = !defaults.bool(forKey: SettingsKeys.defaultDeviceScreenMigrated)
        let rawDefaultScreen = shouldMigrateDefaultScreen && storedDefaultScreen == DeviceScreen.map.rawValue
            ? DeviceScreen.mapPlusNavigation.rawValue
            : storedDefaultScreen ?? DeviceScreen.mapPlusNavigation.rawValue
        defaultDeviceScreen = DeviceScreen.fallbackDefault(
            for: rawDefaultScreen,
            mask: enabledDeviceScreensMask
        )
        if shouldMigrateDefaultScreen {
            defaults.set(defaultDeviceScreen.rawValue, forKey: SettingsKeys.defaultDeviceScreen)
            defaults.set(true, forKey: SettingsKeys.defaultDeviceScreenMigrated)
        }
        deviceBrightnessPercent = DeviceBLEProtocol.normalizedBrightnessPercent(
            defaults.object(forKey: SettingsKeys.deviceBrightnessPercent) as? Double ?? 100
        )
        disconnectedSleepTimeout = DisconnectedSleepTimeout.normalized(
            rawValue: defaults.object(forKey: SettingsKeys.disconnectedSleepTimeoutSeconds) as? Int ?? DisconnectedSleepTimeout.twoMinutes.rawValue
        )
        let storedSoundID = defaults.object(forKey: SettingsKeys.selectedDeviceSound) as? Int
            ?? Int(DeviceSound.defaultSelection.rawValue)
        selectedDeviceSound = UInt8(exactly: storedSoundID)
            .flatMap(DeviceSound.init(rawValue:))
            ?? .defaultSelection
        let storedSoundVolume = defaults.object(forKey: SettingsKeys.deviceSoundVolumePercent) as? Double
            ?? DeviceSound.defaultVolumePercent
        deviceSoundVolumePercent = DeviceSound.normalizedVolumePercent(storedSoundVolume)
        isPowerButtonHonkEnabled = defaults.object(
            forKey: SettingsKeys.powerButtonHonkEnabled
        ) as? Bool ?? false
        showBuildings = defaults.object(forKey: SettingsKeys.showBuildings) as? Bool ?? true
        let legacyNature = defaults.object(forKey: SettingsKeys.legacyShowNature) as? Bool ?? true
        let legacyMinorRoads = defaults.object(forKey: SettingsKeys.legacyShowMinorRoads) as? Bool ?? true
        showGreenSpace = defaults.object(forKey: SettingsKeys.showGreenSpace) as? Bool ?? legacyNature
        showPaths = defaults.object(forKey: SettingsKeys.showPaths) as? Bool ?? legacyMinorRoads
        showTracks = defaults.object(forKey: SettingsKeys.showTracks) as? Bool ?? showPaths
        showMajorRoads = defaults.object(forKey: SettingsKeys.showMajorRoads) as? Bool ?? true
        showLocalStreets = defaults.object(forKey: SettingsKeys.showLocalStreets) as? Bool ?? true
        showServiceRoads = defaults.object(forKey: SettingsKeys.showServiceRoads) as? Bool ?? showLocalStreets
        showWater = defaults.object(forKey: SettingsKeys.showWater) as? Bool ?? legacyNature
        showRailways = defaults.object(forKey: SettingsKeys.showRailways) as? Bool ?? true
        showOtherAreas = defaults.object(forKey: SettingsKeys.showOtherAreas) as? Bool ?? true
        let persistedMapProfileKeys = [
            SettingsKeys.minPolygonSize,
            SettingsKeys.detailLevel,
            SettingsKeys.routeLineWidth,
            SettingsKeys.streetLineWidth,
            SettingsKeys.legacyStreetLineWidthBoost,
            SettingsKeys.positionMarkerScale,
            SettingsKeys.zoomLevel,
            SettingsKeys.showBuildings,
            SettingsKeys.showGreenSpace,
            SettingsKeys.showPaths,
            SettingsKeys.showTracks,
            SettingsKeys.showMajorRoads,
            SettingsKeys.showLocalStreets,
            SettingsKeys.showServiceRoads,
            SettingsKeys.showWater,
            SettingsKeys.showRailways,
            SettingsKeys.showOtherAreas
        ]
        let hasPersistedMapProfile = persistedMapProfileKeys.contains {
            defaults.object(forKey: $0) != nil
        }
        let shouldMigrateMapPlusNavigationProfile = !defaults.bool(
            forKey: SettingsKeys.mapPlusNavigationProfileMigrated
        )
        if let pendingDefault = defaults.object(
            forKey: SettingsKeys.mapPlusNavigationBuildingVisibilityDefaultPending
        ) as? Bool {
            shouldApply3DBuildingVisibilityDefault = pendingDefault
        } else {
            shouldApply3DBuildingVisibilityDefault =
                !hasPersistedMapProfile &&
                defaults.object(
                    forKey: SettingsKeys.mapPlusNavigationShowBuildings
                ) == nil
            defaults.set(
                shouldApply3DBuildingVisibilityDefault,
                forKey: SettingsKeys.mapPlusNavigationBuildingVisibilityDefaultPending
            )
        }
        if shouldMigrateMapPlusNavigationProfile && hasPersistedMapProfile {
            mapPlusNavigationMinPolygonSize = minPolygonSize
            mapPlusNavigationDetailLevel = detailLevel
            mapPlusNavigationRouteLineWidth = routeLineWidth
            mapPlusNavigationStreetLineWidth = streetLineWidth
            mapPlusNavigationPositionMarkerScale = positionMarkerScale
            mapPlusNavigationZoomLevel = zoomLevel
            mapPlusNavigationShowBuildings = showBuildings
            mapPlusNavigationShowGreenSpace = showGreenSpace
            mapPlusNavigationShowPaths = showPaths
            mapPlusNavigationShowTracks = showTracks
            mapPlusNavigationShowMajorRoads = showMajorRoads
            mapPlusNavigationShowLocalStreets = showLocalStreets
            mapPlusNavigationShowServiceRoads = showServiceRoads
            mapPlusNavigationShowWater = showWater
            mapPlusNavigationShowRailways = showRailways
            mapPlusNavigationShowOtherAreas = showOtherAreas
        } else if !shouldMigrateMapPlusNavigationProfile {
            mapPlusNavigationMinPolygonSize = defaults.double(
                forKey: SettingsKeys.mapPlusNavigationMinPolygonSize
            )
            mapPlusNavigationDetailLevel = defaults.object(
                forKey: SettingsKeys.mapPlusNavigationDetailLevel
            ) as? Int ?? MapPlusNavigationDefaults.detailLevel
            mapPlusNavigationRouteLineWidth = defaults.object(
                forKey: SettingsKeys.mapPlusNavigationRouteLineWidth
            ) as? Double ?? MapPlusNavigationDefaults.routeLineWidth
            if let storedWidth = defaults.object(
                forKey: SettingsKeys.mapPlusNavigationStreetLineWidth
            ) as? Double {
                mapPlusNavigationStreetLineWidth = DeviceBLEProtocol.normalizedStreetWidth(
                    storedWidth
                )
            } else if let legacyBoost = defaults.object(
                forKey: SettingsKeys.legacyMapPlusNavigationStreetLineWidthBoost
            ) as? Double {
                mapPlusNavigationStreetLineWidth = DeviceBLEProtocol.absoluteStreetWidth(
                    fromLegacyBoost: legacyBoost
                )
            } else {
                mapPlusNavigationStreetLineWidth = MapPlusNavigationDefaults.streetLineWidth
            }
            mapPlusNavigationPositionMarkerScale = defaults.object(
                forKey: SettingsKeys.mapPlusNavigationPositionMarkerScale
            ) as? Double ?? MapPlusNavigationDefaults.positionMarkerScale
            mapPlusNavigationZoomLevel = defaults.object(
                forKey: SettingsKeys.mapPlusNavigationZoomLevel
            ) as? Int ?? MapPlusNavigationDefaults.zoomLevel
            mapPlusNavigationShowBuildings = defaults.object(
                forKey: SettingsKeys.mapPlusNavigationShowBuildings
            ) as? Bool ?? MapPlusNavigationDefaults.showBuildings
            mapPlusNavigationShowGreenSpace = defaults.object(
                forKey: SettingsKeys.mapPlusNavigationShowGreenSpace
            ) as? Bool ?? MapPlusNavigationDefaults.showGreenSpace
            mapPlusNavigationShowPaths = defaults.object(
                forKey: SettingsKeys.mapPlusNavigationShowPaths
            ) as? Bool ?? MapPlusNavigationDefaults.showPaths
            mapPlusNavigationShowTracks = defaults.object(
                forKey: SettingsKeys.mapPlusNavigationShowTracks
            ) as? Bool ?? MapPlusNavigationDefaults.showTracks
            mapPlusNavigationShowMajorRoads = defaults.object(
                forKey: SettingsKeys.mapPlusNavigationShowMajorRoads
            ) as? Bool ?? MapPlusNavigationDefaults.showMajorRoads
            mapPlusNavigationShowLocalStreets = defaults.object(
                forKey: SettingsKeys.mapPlusNavigationShowLocalStreets
            ) as? Bool ?? MapPlusNavigationDefaults.showLocalStreets
            mapPlusNavigationShowServiceRoads = defaults.object(
                forKey: SettingsKeys.mapPlusNavigationShowServiceRoads
            ) as? Bool ?? MapPlusNavigationDefaults.showServiceRoads
            mapPlusNavigationShowWater = defaults.object(
                forKey: SettingsKeys.mapPlusNavigationShowWater
            ) as? Bool ?? MapPlusNavigationDefaults.showWater
            mapPlusNavigationShowRailways = defaults.object(
                forKey: SettingsKeys.mapPlusNavigationShowRailways
            ) as? Bool ?? MapPlusNavigationDefaults.showRailways
            mapPlusNavigationShowOtherAreas = defaults.object(
                forKey: SettingsKeys.mapPlusNavigationShowOtherAreas
            ) as? Bool ?? MapPlusNavigationDefaults.showOtherAreas
        }
        mapPlusNavigationBirdsEyeViewEnabled = defaults.object(
            forKey: SettingsKeys.mapPlusNavigationBirdsEyeViewEnabled
        ) as? Bool ?? true
        mapPlusNavigationBirdsEyePerspective = .normalized(
            rawValue: defaults.object(
                forKey: SettingsKeys.mapPlusNavigationBirdsEyePerspective
            ) as? Int ?? MapNavigationBirdsEyePerspective.standard.rawValue
        )
        mapPlusNavigation3DBuildingsEnabled = defaults.object(
            forKey: SettingsKeys.mapPlusNavigation3DBuildingsEnabled
        ) as? Bool ?? true
        let shouldMigrateRecommendedDefaults = !defaults.bool(
            forKey: SettingsKeys.recommendedMapDefaultsMigrated
        )
        if shouldMigrateRecommendedDefaults {
            if detailLevel == 2,
               routeLineWidth == 4,
               streetLineWidth == 4,
               positionMarkerScale == 2,
               zoomLevel == 2 {
                zoomLevel = 3
            }
            if mapPlusNavigationDetailLevel == 0,
               mapPlusNavigationRouteLineWidth == 4,
               mapPlusNavigationStreetLineWidth == 4,
               mapPlusNavigationPositionMarkerScale == 2,
               mapPlusNavigationZoomLevel == 2,
               !mapPlusNavigationShowBuildings,
               mapPlusNavigationShowGreenSpace,
               !mapPlusNavigationShowPaths,
               !mapPlusNavigationShowTracks,
               mapPlusNavigationShowMajorRoads,
               mapPlusNavigationShowLocalStreets,
               !mapPlusNavigationShowServiceRoads,
               mapPlusNavigationShowWater,
               !mapPlusNavigationShowRailways,
               !mapPlusNavigationShowOtherAreas {
                mapPlusNavigationRouteLineWidth = 15
                mapPlusNavigationZoomLevel = 3
                mapPlusNavigationShowGreenSpace = false
            }
            defaults.set(true, forKey: SettingsKeys.recommendedMapDefaultsMigrated)
        }
        showRouteOverlay = defaults.object(forKey: SettingsKeys.showRouteOverlay) as? Bool ?? true
        showCurrentPosition = defaults.object(forKey: SettingsKeys.showCurrentPosition) as? Bool ?? true
        if shouldMigrateMapPlusNavigationProfile ||
            shouldMigrateStreetLabelDefaults ||
            shouldMigrateRecommendedDefaults ||
            defaults.object(forKey: SettingsKeys.streetLineWidth) == nil ||
            defaults.object(forKey: SettingsKeys.mapPlusNavigationStreetLineWidth) == nil {
            defaults.set(true, forKey: SettingsKeys.mapPlusNavigationProfileMigrated)
            saveSettings()
        }
    }

    private func loadLastPeripheralIdentifier() {
        guard let uuidString = UserDefaults.standard.string(forKey: SettingsKeys.lastPeripheralIdentifier) else { return }
        lastConnectedPeripheralIdentifier = UUID(uuidString: uuidString)
        updateTrustedPeripheralDescription()
    }

    private func migrateLegacyPeripheralIfNeeded() {
        guard deviceRegistry.devices.isEmpty,
              let identifier = lastConnectedPeripheralIdentifier else { return }
        let legacy = KnownBikeComputerDevice(
            deviceID: "legacy:\(identifier.uuidString.lowercased())",
            peripheralIdentifier: identifier,
            name: DeviceOwnershipProtocol.defaultDeviceName,
            lastConnectedAt: .distantPast,
            isLegacy: true
        )
        deviceRegistry.upsert(legacy, makeActive: true)
    }

    private func refreshKnownDevices() {
        knownDevices = deviceRegistry.devices
        observedIdentityMismatchDeviceIDs.formIntersection(
            Set(knownDevices.map(\.deviceID))
        )
        activeDeviceID = deviceRegistry.activeDeviceID
        if let activeDeviceID,
           let active = knownDevices.first(where: { $0.deviceID == activeDeviceID }) {
            lastConnectedPeripheralIdentifier = active.peripheralIdentifier
            UserDefaults.standard.set(
                active.peripheralIdentifier.uuidString,
                forKey: SettingsKeys.lastPeripheralIdentifier
            )
        } else if knownDevices.isEmpty {
            lastConnectedPeripheralIdentifier = nil
            UserDefaults.standard.removeObject(forKey: SettingsKeys.lastPeripheralIdentifier)
        }
        updateTrustedPeripheralDescription()
    }

    func hasObservedIdentityMismatch(for device: KnownBikeComputerDevice) -> Bool {
        observedIdentityMismatchDeviceIDs.contains(device.deviceID)
    }
    
    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(minPolygonSize, forKey: SettingsKeys.minPolygonSize)
        defaults.set(detailLevel, forKey: SettingsKeys.detailLevel)
        defaults.set(routeLineWidth, forKey: SettingsKeys.routeLineWidth)
        defaults.set(streetLineWidth, forKey: SettingsKeys.streetLineWidth)
        defaults.set(positionMarkerScale, forKey: SettingsKeys.positionMarkerScale)
        defaults.set(mapRotationMode, forKey: SettingsKeys.mapRotationMode)
        defaults.set(zoomLevel, forKey: SettingsKeys.zoomLevel)
        defaults.set(mapLabelsEnabled, forKey: SettingsKeys.mapLabelsEnabled)
        defaults.set(mapLabelDensity, forKey: SettingsKeys.mapLabelDensity)
        defaults.set(mapLabelLanguageMode, forKey: SettingsKeys.mapLabelLanguageMode)
        defaults.set(mapLabelTextSize, forKey: SettingsKeys.mapLabelTextSize)
        defaults.set(mapLabelOrientation, forKey: SettingsKeys.mapLabelOrientation)
        defaults.set(mapPlusNavigationMinPolygonSize, forKey: SettingsKeys.mapPlusNavigationMinPolygonSize)
        defaults.set(mapPlusNavigationDetailLevel, forKey: SettingsKeys.mapPlusNavigationDetailLevel)
        defaults.set(mapPlusNavigationRouteLineWidth, forKey: SettingsKeys.mapPlusNavigationRouteLineWidth)
        defaults.set(mapPlusNavigationStreetLineWidth, forKey: SettingsKeys.mapPlusNavigationStreetLineWidth)
        defaults.set(mapPlusNavigationPositionMarkerScale, forKey: SettingsKeys.mapPlusNavigationPositionMarkerScale)
        defaults.set(mapPlusNavigationZoomLevel, forKey: SettingsKeys.mapPlusNavigationZoomLevel)
        defaults.set(mapPlusNavigationBirdsEyeViewEnabled, forKey: SettingsKeys.mapPlusNavigationBirdsEyeViewEnabled)
        defaults.set(mapPlusNavigationBirdsEyePerspective.rawValue, forKey: SettingsKeys.mapPlusNavigationBirdsEyePerspective)
        defaults.set(mapPlusNavigation3DBuildingsEnabled, forKey: SettingsKeys.mapPlusNavigation3DBuildingsEnabled)
        defaults.set(mapPlusNavigationLabelsEnabled, forKey: SettingsKeys.mapPlusNavigationLabelsEnabled)
        defaults.set(mapPlusNavigationLabelDensity, forKey: SettingsKeys.mapPlusNavigationLabelDensity)
        defaults.set(mapPlusNavigationLabelLanguageMode, forKey: SettingsKeys.mapPlusNavigationLabelLanguageMode)
        defaults.set(mapPlusNavigationLabelTextSize, forKey: SettingsKeys.mapPlusNavigationLabelTextSize)
        defaults.set(mapPlusNavigationLabelOrientation, forKey: SettingsKeys.mapPlusNavigationLabelOrientation)
        defaults.set(tapToSwitchScreens, forKey: SettingsKeys.tapToSwitchScreens)
        enabledDeviceScreensMask = DeviceScreen.normalizedMask(enabledDeviceScreensMask)
        defaultDeviceScreen = DeviceScreen.fallbackDefault(
            for: defaultDeviceScreen.rawValue,
            mask: enabledDeviceScreensMask
        )
        defaults.set(enabledDeviceScreensMask, forKey: SettingsKeys.enabledDeviceScreensMask)
        defaults.set(defaultDeviceScreen.rawValue, forKey: SettingsKeys.defaultDeviceScreen)
        deviceBrightnessPercent = DeviceBLEProtocol.normalizedBrightnessPercent(
            deviceBrightnessPercent
        )
        defaults.set(deviceBrightnessPercent, forKey: SettingsKeys.deviceBrightnessPercent)
        defaults.set(disconnectedSleepTimeout.rawValue, forKey: SettingsKeys.disconnectedSleepTimeoutSeconds)
        defaults.set(Int(selectedDeviceSound.rawValue), forKey: SettingsKeys.selectedDeviceSound)
        deviceSoundVolumePercent = DeviceSound.normalizedVolumePercent(deviceSoundVolumePercent)
        defaults.set(deviceSoundVolumePercent, forKey: SettingsKeys.deviceSoundVolumePercent)
        defaults.set(isPowerButtonHonkEnabled, forKey: SettingsKeys.powerButtonHonkEnabled)
        defaults.set(showBuildings, forKey: SettingsKeys.showBuildings)
        defaults.set(showGreenSpace, forKey: SettingsKeys.showGreenSpace)
        defaults.set(showPaths, forKey: SettingsKeys.showPaths)
        defaults.set(showTracks, forKey: SettingsKeys.showTracks)
        defaults.set(showMajorRoads, forKey: SettingsKeys.showMajorRoads)
        defaults.set(showLocalStreets, forKey: SettingsKeys.showLocalStreets)
        defaults.set(showServiceRoads, forKey: SettingsKeys.showServiceRoads)
        defaults.set(showWater, forKey: SettingsKeys.showWater)
        defaults.set(showRailways, forKey: SettingsKeys.showRailways)
        defaults.set(showOtherAreas, forKey: SettingsKeys.showOtherAreas)
        defaults.set(mapPlusNavigationShowBuildings, forKey: SettingsKeys.mapPlusNavigationShowBuildings)
        defaults.set(mapPlusNavigationShowGreenSpace, forKey: SettingsKeys.mapPlusNavigationShowGreenSpace)
        defaults.set(mapPlusNavigationShowPaths, forKey: SettingsKeys.mapPlusNavigationShowPaths)
        defaults.set(mapPlusNavigationShowTracks, forKey: SettingsKeys.mapPlusNavigationShowTracks)
        defaults.set(mapPlusNavigationShowMajorRoads, forKey: SettingsKeys.mapPlusNavigationShowMajorRoads)
        defaults.set(mapPlusNavigationShowLocalStreets, forKey: SettingsKeys.mapPlusNavigationShowLocalStreets)
        defaults.set(mapPlusNavigationShowServiceRoads, forKey: SettingsKeys.mapPlusNavigationShowServiceRoads)
        defaults.set(mapPlusNavigationShowWater, forKey: SettingsKeys.mapPlusNavigationShowWater)
        defaults.set(mapPlusNavigationShowRailways, forKey: SettingsKeys.mapPlusNavigationShowRailways)
        defaults.set(mapPlusNavigationShowOtherAreas, forKey: SettingsKeys.mapPlusNavigationShowOtherAreas)
        defaults.set(true, forKey: SettingsKeys.mapPlusNavigationProfileMigrated)
        defaults.set(showRouteOverlay, forKey: SettingsKeys.showRouteOverlay)
        defaults.set(showCurrentPosition, forKey: SettingsKeys.showCurrentPosition)
    }
    
    // MARK: - Public Methods

    private var hasScanDriver: Bool {
#if HOST_TESTING
        scanDriverForTesting != nil
#else
        centralManager != nil
#endif
    }

    private var isScanDriverPoweredOn: Bool {
#if HOST_TESTING
        scanDriverForTesting?.isPoweredOn == true
#else
        centralManager != nil && centralManager.state == .poweredOn
#endif
    }

    private var isScanDriverScanning: Bool {
#if HOST_TESTING
        scanDriverForTesting?.isScanning == true
#else
        centralManager != nil && centralManager.isScanning
#endif
    }

    private func startScanDriver(
        serviceUUIDs: [CBUUID],
        allowsDuplicates: Bool
    ) {
#if HOST_TESTING
        scanDriverForTesting?.start(
            serviceUUIDs: serviceUUIDs,
            allowsDuplicates: allowsDuplicates
        )
#else
        centralManager.scanForPeripherals(
            withServices: serviceUUIDs,
            options: [
                CBCentralManagerScanOptionAllowDuplicatesKey:
                    allowsDuplicates
            ]
        )
#endif
    }

    private func stopScanDriver() {
#if HOST_TESTING
        scanDriverForTesting?.stop()
#else
        centralManager?.stopScan()
#endif
    }

#if HOST_TESTING
    func installScanDriverForTesting(
        _ driver: BLEScanDriverForTesting,
        knownDevices: [KnownBikeComputerDevice] = [],
        trustedPeripheralIdentifier: UUID? = nil,
        shouldAutoReconnect: Bool = false,
        isExclusiveOperationActive: Bool = false
    ) {
        pendingScanStartWorkItem?.cancel()
        pendingScanStartWorkItem = nil
        scanDriverForTesting = driver
        self.knownDevices = knownDevices
        lastConnectedPeripheralIdentifier = trustedPeripheralIdentifier
        autoReconnect = shouldAutoReconnect
        watchDirectRidePreparedDeviceID = isExclusiveOperationActive
            ? knownDevices.first?.deviceID ?? "host-test-device"
            : nil
        isApplicationActive = false
        isOpportunisticDiscoverySuppressed = false
        explicitDiscoveryRequested = false
        isExplicitDiscoveryPausedForCandidate = false
        isUnknownDeviceDiscoverySuspended = false
        pendingScannedConnectionIdentifier = nil
        isScanning = false
        isDiscoveringDevices = false
        currentScanPurpose = .none
        activeDiscoveryGeneration = nil
        unknownScanObservationGate.end()
        centralStateDescription = driver.isPoweredOn
            ? "powered on"
            : "powered off"
    }

    func setBluetoothPoweredOnForTesting(_ isPoweredOn: Bool) {
        guard let scanDriverForTesting else { return }
        scanDriverForTesting.isPoweredOn = isPoweredOn
        handleCentralStateChange(isPoweredOn ? .poweredOn : .poweredOff)
    }

    func installNearbyCandidateForTesting(
        _ candidate: DiscoveredBikeComputerDevice,
        isPresented: Bool
    ) {
        stopPhysicalScan(reason: "test nearby candidate sealed")
        nearbyBicinoCandidate = candidate
        isNearbyBicinoCandidatePresented = isPresented
        isOpportunisticDiscoverySuppressed = true
    }

    func installPausedExplicitDiscoveryFailureForTesting(
        error: String,
        status: String
    ) {
        stopPhysicalScan(reason: "test explicit candidate selected")
        explicitDiscoveryRequested = true
        isExplicitDiscoveryPausedForCandidate = true
        isPairingMode = true
        pairingError = error
        pairingStatusMessage = status
    }
#endif
    
    /// Compatibility entry point for callers that want the manager to resolve
    /// the one currently eligible scan. Scan ownership lives in
    /// `reconcileScanning`, never in the caller.
    func startScanning() {
        reconcileScanning(reason: "scan requested")
    }

    /// Stop the active radio scan without granting another scan owner.
    func stopScanning() {
        stopPhysicalScan(reason: "stop requested")
    }

    func setApplicationActive(_ isActive: Bool) {
        guard isApplicationActive != isActive else {
            reconcileScanning(reason: "application activity reaffirmed")
            return
        }
        isApplicationActive = isActive
        if isActive {
            let isContinuingOpportunisticPairing =
                NearbyBicinoPresentationPolicy
                    .shouldRetainCandidateDuringConnection(
                        discoveryOrigin: pairingDiscoveryOrigin,
                        hasPendingPairingSession:
                            pendingPairingSession != nil
                    )
            isOpportunisticDiscoverySuppressed =
                isContinuingOpportunisticPairing
            if !isContinuingOpportunisticPairing {
                nearbyBicinoCandidate = nil
                isNearbyBicinoCandidatePresented = false
                opportunisticCandidateExpiryTimer?.invalidate()
                opportunisticCandidateExpiryTimer = nil
            }
            if isPureExplicitDiscoveryPhase {
                autoReconnect = false
                pairingError = isScanDriverPoweredOn
                    ? nil
                    : "Turn on Bluetooth to add a Bike Computer."
                if !isUnknownDeviceDiscoverySuspended {
                    pairingStatusMessage = isScanDriverPoweredOn
                        ? "Looking for nearby Bike Computers…"
                        : nil
                }
            }
        } else {
            let isSuspendingExplicitDiscovery =
                explicitDiscoveryRequested && pendingPairingSession == nil
            if pendingScannedConnectionIdentifier != nil {
                interruptPendingPairing(
                    "Pairing paused when Bicino moved to the background. Try again while the app is open."
                )
            } else if pendingPairingSession == nil &&
                        !isSuspendingExplicitDiscovery {
                ownershipLifecycle.interrupt()
                isPairingMode = false
            }
            if isSuspendingExplicitDiscovery &&
                explicitDiscoveryRequested {
                // Keep the user's explicit Settings request authoritative while
                // iOS backgrounds the app. Unknown-device scanning remains
                // foreground-only, and trusted reconnect must not steal the
                // transport before the screen can resume.
                autoReconnect = false
            }
            clearUnknownDiscoveryState(
                keepingCandidate: NearbyBicinoPresentationPolicy
                    .shouldRetainCandidateDuringConnection(
                        discoveryOrigin: pairingDiscoveryOrigin,
                        hasPendingPairingSession:
                            pendingPairingSession != nil
                    )
            )
            isOpportunisticDiscoverySuppressed = true
        }
        reconcileScanning(
            reason: isActive ? "application became active" :
                "application entered background"
        )
    }

    /// Temporarily yields unknown-device scanning to another foreground BLE
    /// enrollment flow without discarding an explicit Bike Computer request.
    /// Trusted reconnect is unaffected because it does not discover new devices.
    func setUnknownDeviceDiscoverySuspended(_ isSuspended: Bool) {
        guard isUnknownDeviceDiscoverySuspended != isSuspended else { return }
        isUnknownDeviceDiscoverySuspended = isSuspended
        if isSuspended {
            if isPureExplicitDiscoveryPhase {
                pairingStatusMessage = nil
            }
            clearUnknownDiscoveryState(
                releasingUnpresentedCandidateSuppression: true
            )
        } else if isPureExplicitDiscoveryPhase,
                  isApplicationActive,
                  isScanDriverPoweredOn {
            pairingError = nil
            pairingStatusMessage = "Looking for nearby Bike Computers…"
        }
        reconcileScanning(
            reason: isSuspended
                ? "unknown-device discovery yielded to another enrollment"
                : "unknown-device discovery enrollment yield ended"
        )
    }

    func dismissNearbyBicinoCandidate(peripheralIdentifier: UUID) {
        endNearbyBicinoCandidate(
            peripheralIdentifier: peripheralIdentifier,
            reason: .dismissed
        )
    }

    private func expireNearbyBicinoCandidate(peripheralIdentifier: UUID) {
        endNearbyBicinoCandidate(
            peripheralIdentifier: peripheralIdentifier,
            reason: .expiredBeforePresentation
        )
    }

    private func endNearbyBicinoCandidate(
        peripheralIdentifier: UUID,
        reason: NearbyBicinoCandidateEndReason
    ) {
        guard nearbyBicinoCandidate?.peripheralIdentifier ==
                peripheralIdentifier else { return }
        nearbyBicinoCandidate = nil
        isNearbyBicinoCandidatePresented = false
        isOpportunisticDiscoverySuppressed =
            NearbyBicinoCandidateLifecyclePolicy
                .suppressesFurtherDiscovery(after: reason)
        opportunisticCandidateExpiryTimer?.invalidate()
        opportunisticCandidateExpiryTimer = nil
        clearUnknownDiscoveryState(keepingCandidate: false)
        pairingStatusMessage = nil
        reconcileScanning(
            reason: reason == .dismissed
                ? "nearby setup dismissed"
                : "unpresented nearby candidate expired"
        )
    }

    func markNearbyBicinoCandidatePresented(
        peripheralIdentifier: UUID
    ) {
        guard nearbyBicinoCandidate?.peripheralIdentifier ==
                peripheralIdentifier else { return }
        isNearbyBicinoCandidatePresented = true
        opportunisticCandidateExpiryTimer?.invalidate()
        opportunisticCandidateExpiryTimer = nil
    }

    func nearbyCandidate(
        peripheralIdentifier: UUID
    ) -> DiscoveredBikeComputerDevice? {
        guard nearbyBicinoCandidate?.peripheralIdentifier ==
                peripheralIdentifier else { return nil }
        return nearbyBicinoCandidate
    }

    private func resolvedScanPurpose() -> BLEScanPurpose {
        BLEScanLifecyclePolicy.purpose(
            for: BLEScanContext(
                isApplicationActive: isApplicationActive,
                isBluetoothPoweredOn: isScanDriverPoweredOn,
                hasActiveBLESession: hasActiveBLESession,
                knownDeviceCount: knownDevices.count,
                trustedPeripheralIdentifier:
                    lastConnectedPeripheralIdentifier,
                shouldReconnectTrustedPeripheral: autoReconnect,
                explicitDiscoveryRequested:
                    explicitDiscoveryRequested &&
                    !isExplicitDiscoveryPausedForCandidate &&
                    !isUnknownDeviceDiscoverySuspended,
                selectedPeripheralIdentifier:
                    pendingScannedConnectionIdentifier,
                isUnknownDiscoverySuppressed:
                    isOpportunisticDiscoverySuppressed ||
                    isUnknownDeviceDiscoverySuspended,
                isExclusiveOperationActive:
                    watchDirectRidePreparedDeviceID != nil ||
                    deviceOperationDeviceID != nil
            )
        )
    }

    private var isPureExplicitDiscoveryPhase: Bool {
        explicitDiscoveryRequested &&
            !isExplicitDiscoveryPausedForCandidate &&
            pendingPairingSession == nil &&
            pendingPairingMaterial == nil &&
            pairingPrompt == nil &&
            pendingScannedConnectionIdentifier == nil &&
            !hasActiveBLESession
    }

    private func reconcileScanning(reason: String) {
        guard hasScanDriver else { return }
        let desiredPurpose = resolvedScanPurpose()

        if pendingScanStartWorkItem != nil,
           currentScanPurpose == desiredPurpose {
            return
        }
        if isScanning, isScanDriverScanning,
           currentScanPurpose == desiredPurpose {
            return
        }
        if isScanning || pendingScanStartWorkItem != nil ||
            isScanDriverScanning {
            let previousPurpose = currentScanPurpose.logDescription
            stopPhysicalScan(
                reason: "purpose transition \(previousPurpose) -> " +
                    "\(desiredPurpose.logDescription): \(reason)"
            )
        }

        currentScanPurpose = desiredPurpose
        isDiscoveringDevices = desiredPurpose.discoversUnknownDevices
        guard desiredPurpose != .none else {
            log("BLE scan purpose resolved to none: \(reason)")
            return
        }

        let callbackDrainDelay = desiredPurpose.discoversUnknownDevices
            ? BLEScanCallbackDrainPolicy.delay(
                after: lastPhysicalScanStoppedAt
            )
            : 0
        guard callbackDrainDelay > 0 else {
            startPhysicalScan(purpose: desiredPurpose, reason: reason)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingScanStartWorkItem = nil
            guard self.currentScanPurpose == desiredPurpose,
                  self.resolvedScanPurpose() == desiredPurpose else {
                self.reconcileScanning(
                    reason: "scan purpose changed during callback drain"
                )
                return
            }
            self.startPhysicalScan(purpose: desiredPurpose, reason: reason)
        }
        pendingScanStartWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + callbackDrainDelay,
            execute: workItem
        )
        log(
            "BLE scan pending for \(desiredPurpose.logDescription) " +
            "while prior callbacks drain: \(reason)"
        )
    }

    private func startPhysicalScan(
        purpose: BLEScanPurpose,
        reason: String
    ) {
        guard isScanDriverPoweredOn,
              !hasActiveBLESession,
              currentScanPurpose == purpose,
              resolvedScanPurpose() == purpose else {
            reconcileScanning(reason: "scan start preconditions changed")
            return
        }

        if purpose.discoversUnknownDevices {
            discoveryGeneration &+= 1
            activeDiscoveryGeneration = discoveryGeneration
            unknownScanObservationGate.begin(
                generation: discoveryGeneration
            )
            if purpose == .opportunisticDiscovery {
                opportunisticObservations.removeAll()
            }
            startDiscoveryFreshnessTimer()
        } else {
            activeDiscoveryGeneration = nil
            unknownScanObservationGate.end()
            discoveryFreshnessTimer?.invalidate()
            discoveryFreshnessTimer = nil
        }

        isScanning = true
        startScanDriver(
            serviceUUIDs: [serviceUUID],
            allowsDuplicates: purpose.allowsDuplicateAdvertisements
        )
        log("BLE scan started for \(purpose.logDescription): \(reason)")
    }

    private func stopPhysicalScan(reason: String) {
        pendingScanStartWorkItem?.cancel()
        pendingScanStartWorkItem = nil
        let hadPhysicalScan = isScanning ||
            isScanDriverScanning
        stopScanDriver()
        if hadPhysicalScan {
            lastPhysicalScanStoppedAt = Date()
        }
        isScanning = false
        currentScanPurpose = .none
        isDiscoveringDevices = false
        activeDiscoveryGeneration = nil
        unknownScanObservationGate.end()
        discoveryFreshnessTimer?.invalidate()
        discoveryFreshnessTimer = nil
        opportunisticSelectionTimer?.invalidate()
        opportunisticSelectionTimer = nil
        log("BLE scan stopped: \(reason)")
    }

    private func clearUnknownDiscoveryState(
        keepingCandidate: Bool = false,
        releasingUnpresentedCandidateSuppression: Bool = false
    ) {
        let shouldReleaseCandidateSuppression =
            releasingUnpresentedCandidateSuppression &&
            nearbyBicinoCandidate != nil &&
            !isNearbyBicinoCandidatePresented
        discoveryFreshnessTimer?.invalidate()
        discoveryFreshnessTimer = nil
        opportunisticSelectionTimer?.invalidate()
        opportunisticSelectionTimer = nil
        opportunisticObservations.removeAll()
        discoveredDevices = []
        discoveredPeripherals = [:]
        if !keepingCandidate {
            opportunisticCandidateExpiryTimer?.invalidate()
            opportunisticCandidateExpiryTimer = nil
            nearbyBicinoCandidate = nil
            isNearbyBicinoCandidatePresented = false
        }
        if shouldReleaseCandidateSuppression {
            isOpportunisticDiscoverySuppressed = false
        }
    }
    
    /// Disconnect from current peripheral
    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        
        autoReconnect = false
        stopMonitoringRSSI()
        centralManager.cancelPeripheralConnection(peripheral)
        log("Disconnecting from peripheral")
    }

    func handleWatchDirectRidePreparationRequest(
        _ request: WatchDirectRidePreparationRequestV1,
        phoneNavigationActive: Bool
    ) -> WatchDirectRidePreparationResponseV1 {
        switch request.operation {
        case .release:
            rememberReleasedWatchDirectRidePreparation(request)
            if WatchDirectRidePreparationPolicyV1.releaseMatches(
                preparedDeviceID: watchDirectRidePreparedDeviceID,
                preparedPreparationID: watchDirectRidePreparationID,
                request: request
            ) {
                endWatchDirectRidePreparation(
                    deviceID: request.deviceID,
                    preparationID: request.preparationID
                )
            }
            return WatchDirectRidePreparationResponseV1(
                requestID: request.requestID,
                accepted: true
            )
        case .prepare:
            if request.deviceID == activeDeviceID,
               wasWatchDirectRidePreparationReleased(request) {
                // WCSession's durable release and interactive prepare use
                // different delivery paths. A release may therefore arrive
                // first; its tombstone makes the delayed prepare a safe no-op.
                return WatchDirectRidePreparationResponseV1(
                    requestID: request.requestID,
                    accepted: true
                )
            }
            let rejection = WatchDirectRidePreparationPolicyV1.rejectionCode(
                requestedDeviceID: request.deviceID,
                selectedDeviceID: activeDeviceID,
                phoneNavigationActive: phoneNavigationActive,
                transferActive: mapTransferModeEnabled ||
                    !deviceTransferMode.isEmpty,
                administrationActive:
                    deviceOperationDeviceID != nil ||
                    pendingWatchControllerOperation != nil ||
                    pendingPairingSession != nil ||
                    explicitDiscoveryRequested || isPairingMode
            )
            if let rejection {
                return WatchDirectRidePreparationResponseV1(
                    requestID: request.requestID,
                    accepted: false,
                    errorCode: rejection
                )
            }

            beginWatchDirectRidePreparation(
                deviceID: request.deviceID,
                preparationID: request.preparationID
            )
            return WatchDirectRidePreparationResponseV1(
                requestID: request.requestID,
                accepted: true
            )
        }
    }

    private func beginWatchDirectRidePreparation(
        deviceID: String,
        preparationID: UUID
    ) {
        if watchDirectRidePreparedDeviceID == nil {
            watchDirectRidePreviousAutoReconnect = autoReconnect
        }
        watchDirectRidePreparedDeviceID = deviceID
        watchDirectRidePreparationID = preparationID
        autoReconnect = false
        resetReconnectionState()
        pendingConnectionAfterDisconnect = nil
        pendingScannedConnectionIdentifier = nil
        explicitDiscoveryRequested = false
        isExplicitDiscoveryPausedForCandidate = false
        isOpportunisticDiscoverySuppressed = true
        clearUnknownDiscoveryState()
        stopPhysicalScan(reason: "Apple Watch direct ride handoff")
        persistWatchDirectRidePreparation(
            deviceID: deviceID,
            preparationID: preparationID
        )
        if let peripheral = connectedPeripheral {
            stopMonitoringRSSI()
            centralManager.cancelPeripheralConnection(peripheral)
            log("Yielding BLE connection to Apple Watch direct ride")
        }
    }

    private func endWatchDirectRidePreparation(
        deviceID: String,
        preparationID: UUID
    ) {
        guard watchDirectRidePreparedDeviceID == deviceID,
              watchDirectRidePreparationID == preparationID else { return }
        let shouldReconnect = watchDirectRidePreviousAutoReconnect ?? true
        clearWatchDirectRidePreparationPersistence()
        watchDirectRidePreparedDeviceID = nil
        watchDirectRidePreparationID = nil
        watchDirectRidePreviousAutoReconnect = nil
        autoReconnect = shouldReconnect
        guard shouldReconnect else { return }
        resetReconnectionState()
        reconcileScanning(reason: "Apple Watch direct ride released")
        resumeAutoReconnectIfNeeded()
    }

    private func persistWatchDirectRidePreparation(
        deviceID: String,
        preparationID: UUID
    ) {
        let defaults = UserDefaults.standard
        let expiresAt = Date().addingTimeInterval(24 * 60 * 60)
        defaults.set(
            deviceID,
            forKey: SettingsKeys.watchDirectRidePreparedDeviceID
        )
        defaults.set(
            preparationID.uuidString,
            forKey: SettingsKeys.watchDirectRidePreparationID
        )
        defaults.set(
            watchDirectRidePreviousAutoReconnect ?? true,
            forKey: SettingsKeys.watchDirectRidePreviousAutoReconnect
        )
        defaults.set(
            expiresAt,
            forKey: SettingsKeys.watchDirectRidePreparationExpiresAt
        )
        scheduleWatchDirectRidePreparationExpiry(
            deviceID: deviceID,
            preparationID: preparationID,
            expiresAt: expiresAt
        )
    }

    private func restoreWatchDirectRidePreparation() {
        let defaults = UserDefaults.standard
        restoreWatchDirectRideReleaseTombstones(from: defaults)
        guard let deviceID = defaults.string(
                forKey: SettingsKeys.watchDirectRidePreparedDeviceID
              ),
              deviceID == activeDeviceID,
              let preparationIDRaw = defaults.string(
                forKey: SettingsKeys.watchDirectRidePreparationID
              ),
              let preparationID = UUID(uuidString: preparationIDRaw),
              let expiresAt = defaults.object(
                forKey: SettingsKeys.watchDirectRidePreparationExpiresAt
              ) as? Date,
              expiresAt > Date() else {
            clearWatchDirectRidePreparationPersistence()
            return
        }
        watchDirectRidePreparedDeviceID = deviceID
        watchDirectRidePreparationID = preparationID
        watchDirectRidePreviousAutoReconnect = defaults.object(
            forKey: SettingsKeys.watchDirectRidePreviousAutoReconnect
        ) as? Bool ?? true
        autoReconnect = false
        scheduleWatchDirectRidePreparationExpiry(
            deviceID: deviceID,
            preparationID: preparationID,
            expiresAt: expiresAt
        )
    }

    private func scheduleWatchDirectRidePreparationExpiry(
        deviceID: String,
        preparationID: UUID,
        expiresAt: Date
    ) {
        watchDirectRidePreparationExpiryTimer?.invalidate()
        let interval = max(expiresAt.timeIntervalSinceNow, 0.1)
        watchDirectRidePreparationExpiryTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: false
        ) { [weak self] _ in
            self?.endWatchDirectRidePreparation(
                deviceID: deviceID,
                preparationID: preparationID
            )
        }
    }

    private func clearWatchDirectRidePreparationPersistence() {
        watchDirectRidePreparationExpiryTimer?.invalidate()
        watchDirectRidePreparationExpiryTimer = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(
            forKey: SettingsKeys.watchDirectRidePreparedDeviceID
        )
        defaults.removeObject(
            forKey: SettingsKeys.watchDirectRidePreparationID
        )
        defaults.removeObject(
            forKey: SettingsKeys.watchDirectRidePreviousAutoReconnect
        )
        defaults.removeObject(
            forKey: SettingsKeys.watchDirectRidePreparationExpiresAt
        )
    }

    private func rememberReleasedWatchDirectRidePreparation(
        _ request: WatchDirectRidePreparationRequestV1
    ) {
        pruneWatchDirectRideReleaseTombstones()
        watchDirectRideReleaseTombstones.removeAll {
            $0.deviceID == request.deviceID &&
                $0.preparationID == request.preparationID
        }
        watchDirectRideReleaseTombstones.append(.init(
            deviceID: request.deviceID,
            preparationID: request.preparationID,
            expiresAt: Date().addingTimeInterval(24 * 60 * 60)
        ))
        if watchDirectRideReleaseTombstones.count > 16 {
            watchDirectRideReleaseTombstones.removeFirst(
                watchDirectRideReleaseTombstones.count - 16
            )
        }
        persistWatchDirectRideReleaseTombstones()
    }

    private func wasWatchDirectRidePreparationReleased(
        _ request: WatchDirectRidePreparationRequestV1
    ) -> Bool {
        pruneWatchDirectRideReleaseTombstones()
        return watchDirectRideReleaseTombstones.contains {
            $0.deviceID == request.deviceID &&
                $0.preparationID == request.preparationID
        }
    }

    private func restoreWatchDirectRideReleaseTombstones(
        from defaults: UserDefaults
    ) {
        guard let data = defaults.data(
            forKey: SettingsKeys.watchDirectRideReleaseTombstones
        ), let decoded = try? PropertyListDecoder().decode(
            [WatchDirectRideReleaseTombstone].self,
            from: data
        ) else { return }
        watchDirectRideReleaseTombstones = decoded
        pruneWatchDirectRideReleaseTombstones()
    }

    private func pruneWatchDirectRideReleaseTombstones() {
        let previousCount = watchDirectRideReleaseTombstones.count
        watchDirectRideReleaseTombstones.removeAll { $0.expiresAt <= Date() }
        if watchDirectRideReleaseTombstones.count != previousCount {
            persistWatchDirectRideReleaseTombstones()
        }
    }

    private func persistWatchDirectRideReleaseTombstones() {
        let defaults = UserDefaults.standard
        if watchDirectRideReleaseTombstones.isEmpty {
            defaults.removeObject(
                forKey: SettingsKeys.watchDirectRideReleaseTombstones
            )
            return
        }
        guard let data = try? PropertyListEncoder().encode(
            watchDirectRideReleaseTombstones
        ) else { return }
        defaults.set(
            data,
            forKey: SettingsKeys.watchDirectRideReleaseTombstones
        )
    }

    func reconnect() {
        clearDebugEvents()
        log("Debug log cleared for reconnect")
        autoReconnect = true
        resetReconnectionState()

        if let peripheral = connectedPeripheral {
            log("Restarting connection to the active Bike Computer")
            pendingConnectionAfterDisconnect = peripheral.identifier
            stopMonitoringRSSI()
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        if lastConnectedPeripheralIdentifier == nil {
            startDeviceDiscovery()
        } else {
            reconnectToLastDevice()
        }
    }

    func resumeAutoReconnectIfNeeded() {
        guard autoReconnect, !isConnected, !isConnecting,
              pendingPairingSession == nil else { return }
        reconnectTimer?.invalidate()
        reconnectToLastDevice()
    }

    func startDeviceDiscovery() {
        guard BLEDeviceOperationPolicy.canStartPairing(
            operationDeviceID: deviceOperationDeviceID
        ) else {
            pairingError = "Wait for the current Bike Computer change to finish."
            return
        }
        guard isApplicationActive else {
            pairingError = "Keep Bicino open to search for a Bike Computer."
            return
        }
        guard !hasActiveBLESession else {
            pairingError = "Disconnect the current Bike Computer before searching for another."
            return
        }
        pairingError = nil
        pairingDiscoveryOrigin = nil
        explicitDiscoveryRequested = true
        isExplicitDiscoveryPausedForCandidate = false
        autoReconnect = false
        isOpportunisticDiscoverySuppressed = true
        nearbyBicinoCandidate = nil
        ownershipLifecycle.beginDiscovery()
        clearUnknownDiscoveryState()
        isPairingMode = true
        guard isScanDriverPoweredOn else {
            // Retain explicit intent so Bluetooth-on resumes this user request
            // before any trusted reconnect can claim the radio.
            pairingStatusMessage = nil
            pairingError = "Turn on Bluetooth to add a Bike Computer."
            reconcileScanning(reason: "explicit discovery waiting for Bluetooth")
            return
        }
        pairingStatusMessage = "Looking for nearby Bike Computers…"
        reconcileScanning(reason: "explicit discovery requested")
    }

    func selectDiscoveredDeviceForPairing(
        _ candidate: DiscoveredBikeComputerDevice
    ) {
        guard explicitDiscoveryRequested,
              currentScanPurpose == .explicitDiscovery,
              discoveredPeripherals[candidate.peripheralIdentifier] != nil else {
            return
        }
        isExplicitDiscoveryPausedForCandidate = true
        stopPhysicalScan(reason: "explicit discovery candidate selected")
        discoveredPeripherals = discoveredPeripherals.filter {
            $0.key == candidate.peripheralIdentifier
        }
        discoveredDevices = [candidate]
        pairingStatusMessage = nil
    }

    func disconnectCurrentDeviceAndStartDiscovery() {
        guard isApplicationActive else {
            pairingError = "Keep Bicino open to search for a Bike Computer."
            return
        }
        guard !isConnecting else {
            pairingError = "Wait for the current connection attempt to finish."
            return
        }
        guard let peripheral = connectedPeripheral else {
            startDeviceDiscovery()
            return
        }
        guard BLEDeviceOperationPolicy.canStartPairing(
            operationDeviceID: deviceOperationDeviceID
        ) else {
            pairingError = "Wait for the current Bike Computer change to finish."
            return
        }
        pairingError = nil
        pairingDiscoveryOrigin = nil
        explicitDiscoveryRequested = true
        isExplicitDiscoveryPausedForCandidate = false
        isOpportunisticDiscoverySuppressed = true
        ownershipLifecycle.beginDiscovery()
        pairingStatusMessage = "Disconnecting before searching nearby…"
        autoReconnect = false
        stopPhysicalScan(reason: "disconnect before explicit discovery")
        stopMonitoringRSSI()
        centralManager.cancelPeripheralConnection(peripheral)
        log("Disconnecting current Bike Computer before explicit discovery")
    }

    func cancelDeviceDiscovery(resumeAutoReconnect: Bool = false) {
        let shouldResumeAutoReconnect = ownershipLifecycle.endDiscovery(
            resumeAutoReconnect: resumeAutoReconnect
        )
        explicitDiscoveryRequested = false
        isExplicitDiscoveryPausedForCandidate = false
        isPairingMode = false
        clearUnknownDiscoveryState()
        pairingStatusMessage = nil
        if shouldResumeAutoReconnect {
            autoReconnect = true
            resumeAutoReconnectIfNeeded()
        } else {
            reconcileScanning(reason: "explicit discovery cancelled")
        }
    }

    func pair(with candidate: DiscoveredBikeComputerDevice, name: String) {
        guard BLEDeviceOperationPolicy.canStartPairing(
            operationDeviceID: deviceOperationDeviceID
        ) else {
            pairingError = "Wait for the current Bike Computer change to finish."
            return
        }
        guard centralManager.state == .poweredOn else {
            pairingError = "Turn on Bluetooth to add a Bike Computer."
            return
        }
        guard let ownerID = deviceRegistry.installationOwnerID() else {
            pairingError = "Could not create a secure owner identity on this iPhone."
            return
        }
        locallyForgottenPeripheralIdentifiers.remove(candidate.peripheralIdentifier)
        do {
            pendingPairingSession = try DevicePairingSession(
                peripheralIdentifier: candidate.peripheralIdentifier,
                ownerID: ownerID,
                deviceName: name
            )
        } catch {
            pairingError = "Could not begin secure pairing."
            return
        }
        let discoveryOrigin: BLEDiscoveryOrigin =
            nearbyBicinoCandidate?.peripheralIdentifier ==
                candidate.peripheralIdentifier
                ? .opportunistic
                : .explicit
        pairingDiscoveryOrigin = discoveryOrigin
        if discoveryOrigin == .opportunistic {
            explicitDiscoveryRequested = false
            isExplicitDiscoveryPausedForCandidate = false
            isOpportunisticDiscoverySuppressed = true
            opportunisticCandidateExpiryTimer?.invalidate()
            opportunisticCandidateExpiryTimer = nil
        }
        pendingPairingCandidate = candidate
        let requiresConnectedDeviceHandoff = ownershipLifecycle.beginPairing(
            candidateIdentifier: candidate.peripheralIdentifier,
            connectedIdentifier: connectedPeripheral?.identifier
        )
        pendingPairingMaterial = nil
        pairingPrompt = nil
        isPairingConfirmedOnDevice = false
        isPairingConfirmationSubmitting = false
        pairingError = nil
        pairingStatusMessage = "Connecting to \(candidate.advertisedName)…"
        isPairingMode = true
        autoReconnect = false
        stopPhysicalScan(reason: "selected Bike Computer is connecting")

        if requiresConnectedDeviceHandoff, let connectedPeripheral {
            pendingConnectionAfterDisconnect = candidate.peripheralIdentifier
            autoReconnect = false
            centralManager.cancelPeripheralConnection(connectedPeripheral)
            return
        }
        connectDiscoveredPeripheral(identifier: candidate.peripheralIdentifier)
    }

    func confirmPairingAfterCodeMatch() {
        guard let material = pendingPairingMaterial,
              let peripheral = connectedPeripheral,
              isPairingConfirmedOnDevice,
              !isPairingConfirmationSubmitting,
              ownershipLifecycle.beginConfirmation(
                for: peripheral.identifier
              ) else { return }
        isPairingConfirmationSubmitting = true
        // Persist recovery eligibility only after both the hardware button
        // confirmation and the user's matching-code confirmation on iPhone.
        deviceRegistry.markProvisionalOwnerKeyConfirmed(
            deviceID: material.deviceID
        )
        if pairingPrompt?.isReplacingExistingRegistration == true {
            deviceRegistry.authorizeProvisionalCredentialReplacement(
                deviceID: material.deviceID
            )
        }
        pairingStatusMessage = "Registering this iPhone…"
        startAuthenticationTimeout(for: peripheral)
        enqueueAuthMessage(material.confirmationCommand)
    }

    func cancelPairing() {
        guard pendingPairingSession != nil || pendingPairingMaterial != nil ||
                pairingPrompt != nil || isPairingMode else { return }
        let hasActivePairing = pendingPairingSession != nil ||
            pendingPairingMaterial != nil || pairingPrompt != nil

        // Closing the naming sheet is not a transport cancellation. Keep the
        // automatic Nearby scan alive and, especially, do not disconnect a
        // currently selected Bike Computer before Continue has been tapped.
        guard hasActivePairing else {
            pairingError = nil
            return
        }
        let cancellation = ownershipLifecycle.cancel(
            connectedIdentifier: connectedPeripheral?.identifier
        )
        let shouldResumeExplicitDiscovery =
            pairingDiscoveryOrigin == .explicit &&
            explicitDiscoveryRequested &&
            isApplicationActive
        if let deviceID = pendingPairingMaterial?.deviceID,
           !deviceRegistry.isProvisionalOwnerKeyConfirmed(deviceID: deviceID) {
            deviceRegistry.removeProvisionalOwnerKey(deviceID: deviceID)
        }
        pendingPairingSession = nil
        pendingPairingMaterial = nil
        pendingPairingCandidate = nil
        pairingPrompt = nil
        isPairingConfirmedOnDevice = false
        isPairingConfirmationSubmitting = false
        pairingStatusMessage = nil
        pairingError = nil
        authFlowState = .idle
        pendingConnectionAfterDisconnect = nil
        pendingScannedConnectionIdentifier = nil
        pendingScannedConnectionTimeoutTimer?.invalidate()
        pendingScannedConnectionTimeoutTimer = nil
        pairingDiscoveryOrigin = nil
        isExplicitDiscoveryPausedForCandidate = false
        isPairingMode = shouldResumeExplicitDiscovery
        autoReconnect = !knownDevices.isEmpty &&
            !shouldResumeExplicitDiscovery
        if shouldResumeExplicitDiscovery {
            ownershipLifecycle.beginDiscovery()
            pairingStatusMessage = "Looking for nearby Bike Computers…"
        } else {
            explicitDiscoveryRequested = false
            isExplicitDiscoveryPausedForCandidate = false
            clearUnknownDiscoveryState()
        }
        reconcileScanning(reason: "pairing cancelled")
        if let peripheral = connectedPeripheral,
           cancellation.shouldDisconnectPairingPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    private func interruptPendingPairing(_ message: String) {
        guard pendingPairingSession != nil || pendingPairingMaterial != nil ||
                isPairingMode else { return }
        pendingPairingSession = nil
        ownershipLifecycle.interrupt()
        pendingPairingMaterial = nil
        pendingPairingCandidate = nil
        pairingPrompt = nil
        isPairingConfirmedOnDevice = false
        isPairingConfirmationSubmitting = false
        pendingConnectionAfterDisconnect = nil
        pendingScannedConnectionIdentifier = nil
        pendingScannedConnectionTimeoutTimer?.invalidate()
        pendingScannedConnectionTimeoutTimer = nil
        pairingDiscoveryOrigin = nil
        explicitDiscoveryRequested = false
        isExplicitDiscoveryPausedForCandidate = false
        isPairingMode = false
        clearUnknownDiscoveryState()
        pairingStatusMessage = nil
        pairingError = message
        authFlowState = .idle
        autoReconnect = !knownDevices.isEmpty
        reconcileScanning(reason: "pairing interrupted")
    }

    private func startDiscoveryFreshnessTimer() {
        discoveryFreshnessTimer?.invalidate()
        discoveryFreshnessTimer = Timer.scheduledTimer(
            withTimeInterval: 2,
            repeats: true
        ) { [weak self] _ in
            guard let self, self.isDiscoveringDevices else { return }
            let retained = BLEDiscoveryFreshnessPolicy.retained(
                self.discoveredDevices
            )
            let retainedIdentifiers = Set(retained.map(\.peripheralIdentifier))
            self.discoveredDevices = retained
            self.discoveredPeripherals = self.discoveredPeripherals.filter {
                retainedIdentifiers.contains($0.key)
            }
            self.opportunisticObservations =
                self.opportunisticObservations.filter {
                    Date().timeIntervalSince($0.value.device.lastSeenAt) <=
                        BLEDiscoveryFreshnessPolicy.maximumAge
                }
            self.pairingStatusMessage = retained.isEmpty
                ? "Looking for nearby Bike Computers…"
                : nil
        }
    }

    private func scheduleOpportunisticCandidateSelection(
        generation: UInt64
    ) {
        guard opportunisticSelectionTimer == nil else { return }
        opportunisticSelectionTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: false
        ) { [weak self] _ in
            self?.sealOpportunisticCandidate(generation: generation)
        }
    }

    private func sealOpportunisticCandidate(generation: UInt64) {
        opportunisticSelectionTimer = nil
        guard currentScanPurpose == .opportunisticDiscovery,
              isScanning,
              activeDiscoveryGeneration == generation,
              let selected = BLEOpportunisticCandidatePolicy.strongest(
                from: Array(opportunisticObservations.values),
                activeGeneration: generation,
                knownDevices: knownDevices
              ),
              discoveredPeripherals[
                selected.device.peripheralIdentifier
              ] != nil else {
            return
        }

        isOpportunisticDiscoverySuppressed = true
        stopPhysicalScan(
            reason: "automatic setup candidate \(selected.device.shortIdentifier) sealed"
        )
        discoveredPeripherals = discoveredPeripherals.filter {
            $0.key == selected.device.peripheralIdentifier
        }
        opportunisticObservations = [
            selected.device.peripheralIdentifier: selected
        ]
        isNearbyBicinoCandidatePresented = false
        // Publication deliberately follows the scan stop so SwiftUI cannot
        // display a candidate while Core Bluetooth is still scanning.
        nearbyBicinoCandidate = selected.device
        opportunisticCandidateExpiryTimer?.invalidate()
        let remainingFreshness = max(
            0.1,
            BLEDiscoveryFreshnessPolicy.maximumAge -
                Date().timeIntervalSince(selected.device.lastSeenAt)
        )
        opportunisticCandidateExpiryTimer = Timer.scheduledTimer(
            withTimeInterval: remainingFreshness,
            repeats: false
        ) { [weak self] _ in
            guard let self,
                  !self.isNearbyBicinoCandidatePresented,
                  self.nearbyBicinoCandidate?.peripheralIdentifier ==
                    selected.device.peripheralIdentifier else { return }
            self.expireNearbyBicinoCandidate(
                peripheralIdentifier: selected.device.peripheralIdentifier
            )
        }
        log("Automatic setup candidate \(selected.device.shortIdentifier) is ready")
    }

    func connect(to device: KnownBikeComputerDevice) {
        guard watchDirectRidePreparedDeviceID == nil else {
            pairingError =
                "End the Apple Watch direct ride before connecting from iPhone."
            return
        }
        guard deviceOperationDeviceID == nil else {
            pairingError = "Wait for the current Bike Computer change to finish."
            return
        }
        deviceRegistry.activeDeviceID = device.deviceID
        refreshKnownDevices()
        autoReconnect = true
        if let peripheral = connectedPeripheral {
            if peripheral.identifier == device.peripheralIdentifier, isConnected { return }
            pendingConnectionAfterDisconnect = device.peripheralIdentifier
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        reconnectToLastDevice()
    }

    func bindWatchConnectivityCoordinator(
        _ coordinator: any PhoneWatchControllerTransporting
    ) {
        watchConnectivityCoordinator = coordinator
    }

    func updateWatchConnectivityState(
        _ state: PhoneWatchConnectivityStateV1
    ) {
        let wasReady = watchConnectivityState.controllerAvailability
            .canPerformLiveEnrollment
        watchConnectivityState = state
        if !wasReady && state.controllerAvailability.canPerformLiveEnrollment {
            if watchControllerIDHex == nil {
                attemptAutomaticWatchControllerEnrollment()
            } else {
                attemptWatchControllerPromotion()
            }
        }
    }

    func isWatchControllerConfigured(
        for device: KnownBikeComputerDevice
    ) -> Bool {
        if connectedDeviceID == device.deviceID,
           hasReceivedWatchControllerStatus {
            return watchControllerIDHex != nil
        }
        return rememberedWatchControllerID(deviceID: device.deviceID) != nil
    }

    private func attemptAutomaticWatchControllerEnrollment() {
        guard let deviceID = connectedDeviceID,
              let device = knownDevices.first(where: {
                  $0.deviceID == deviceID
              }) else { return }
        let shouldStart = WatchControllerAutomaticEnrollmentPolicyV1
            .shouldStart(
                firmwareSupportsScopedController:
                    supportsScopedWatchController,
                deviceConnectedAndAuthenticated:
                    isConnected(to: device) &&
                    authenticatedWriteSession != nil,
                controllerStatusKnown: hasReceivedWatchControllerStatus,
                hasController: watchControllerIDHex != nil,
                operationInFlight: pendingWatchControllerOperation != nil,
                availability:
                    watchConnectivityState.controllerAvailability
            )
        guard shouldStart else { return }
        enableWatchController(for: device)
    }

    private func attemptWatchControllerPromotion() {
        guard hasReceivedWatchControllerStatus,
              pendingWatchControllerOperation == nil,
              !isWatchControllerPromotionInFlight,
              watchConnectivityState.controllerAvailability
                .canPerformLiveEnrollment,
              let deviceID = connectedDeviceID,
              let controllerIDHex = watchControllerIDHex,
              let controllerID = Data(ownershipHex: controllerIDHex),
              controllerID.count == 16,
              let watchConnectivityCoordinator else { return }
        let request = WatchControllerRequestV1(
            operation: .promote,
            deviceID: deviceID,
            controllerID: controllerID
        )
        isWatchControllerPromotionInFlight = true
        let callbackBox = WeakBLEManagerSendableBox(self)
        watchConnectivityCoordinator.sendWatchControllerRequest(request) {
            result in
            DispatchQueue.main.async {
                guard let manager = callbackBox.value else { return }
                manager.isWatchControllerPromotionInFlight = false
                guard manager.connectedDeviceID == deviceID,
                      manager.watchControllerIDHex == controllerIDHex else {
                    return
                }
                switch result {
                case .success:
                    manager.watchControllerOperationError = nil
                case .failure(.rejected("credential_store")):
                    manager.watchControllerOperationError =
                        "This Bike Computer is linked to a different or reset Apple Watch. Replacing a Watch requires resetting or deregistering this Bike Computer for now."
                case .failure:
                    break
                }
            }
        }
    }

    func enableWatchController(for device: KnownBikeComputerDevice) {
        guard pendingWatchControllerOperation == nil else {
            watchControllerOperationError =
                "Wait for the current Apple Watch change to finish."
            return
        }
        guard isConnected(to: device),
              connectedDeviceID == device.deviceID,
              authenticatedWriteSession != nil else {
            watchControllerOperationError =
                "Connect securely to this Bike Computer first."
            return
        }
        guard supportsScopedWatchController else {
            watchControllerOperationError =
                "This Bike Computer firmware does not support Apple Watch control."
            return
        }
        guard let controllerID = Self.randomData(count: 16),
              let key = Self.randomData(count: 32),
              let credential = try? WatchControllerCredentialV1(
                deviceID: device.deviceID,
                controllerID: controllerID,
                key: key
              ) else {
            watchControllerOperationError =
                "Could not create a secure Apple Watch credential."
            return
        }
        watchControllerOperationError = nil
        watchControllerOperationStatus =
            "Preparing Apple Watch navigation…"
        pendingWatchControllerOperation = .staging(credential)
        enqueueAuthMessage(
            "WCTRL_STAGE|\(credential.controllerIDHex)|\(credential.key.ownershipHex)"
        )
    }

    func revokeWatchController(for device: KnownBikeComputerDevice) {
        guard pendingWatchControllerOperation == nil else {
            watchControllerOperationError =
                "Wait for the current Apple Watch change to finish."
            return
        }
        guard isConnected(to: device),
              connectedDeviceID == device.deviceID,
              let controllerIDHex = watchControllerIDHex,
              let controllerID = Data(ownershipHex: controllerIDHex),
              controllerID.count == 16 else {
            watchControllerOperationError =
                "Connect to the Bike Computer and refresh its Apple Watch status first."
            return
        }
        watchControllerOperationError = nil
        watchControllerOperationStatus =
            "Revoking Apple Watch navigation…"
        pendingWatchControllerOperation = .revoking(
            deviceID: device.deviceID,
            controllerID: controllerID
        )
        enqueueAuthMessage("WCTRL_REVOKE|\(controllerIDHex)")
    }

    private static func randomData(count: Int) -> Data? {
        guard count > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) ==
                errSecSuccess,
              bytes.contains(where: { $0 != 0 }) else {
            return nil
        }
        return Data(bytes)
    }

    private func rememberedWatchControllerID(
        deviceID: String
    ) -> Data? {
        guard let records = UserDefaults.standard.dictionary(
            forKey: SettingsKeys.watchControllerIDsByDevice
        ) as? [String: String],
              let value = records[deviceID.lowercased()],
              let controllerID = Data(ownershipHex: value),
              controllerID.count == 16 else {
            return nil
        }
        return controllerID
    }

    private func rememberWatchControllerID(
        _ controllerID: Data?,
        deviceID: String
    ) {
        var records = UserDefaults.standard.dictionary(
            forKey: SettingsKeys.watchControllerIDsByDevice
        ) as? [String: String] ?? [:]
        let key = deviceID.lowercased()
        if let controllerID, controllerID.count == 16 {
            records[key] = controllerID.ownershipHex
        } else {
            records.removeValue(forKey: key)
        }
        if records.isEmpty {
            UserDefaults.standard.removeObject(
                forKey: SettingsKeys.watchControllerIDsByDevice
            )
        } else {
            UserDefaults.standard.set(
                records,
                forKey: SettingsKeys.watchControllerIDsByDevice
            )
        }
    }

    private func queueRememberedWatchControllerDeletion(
        deviceID: String
    ) {
        guard let controllerID = rememberedWatchControllerID(
            deviceID: deviceID
        ) else { return }
        watchConnectivityCoordinator?.queueWatchControllerRevocation(
            WatchControllerRequestV1(
                operation: .revoke,
                deviceID: deviceID,
                controllerID: controllerID
            )
        )
        rememberWatchControllerID(nil, deviceID: deviceID)
    }

    func rename(device: KnownBikeComputerDevice, to proposedName: String) {
        guard deviceOperationDeviceID == nil else {
            pairingError = "Another Bike Computer change is still in progress."
            return
        }
        guard connectedDeviceID == device.deviceID, isConnected else {
            pairingError = "Connect to this Bike Computer before renaming it."
            return
        }
        let name = DeviceOwnershipProtocol.normalizedName(proposedName)
        pairingError = nil
        pairingStatusMessage = "Saving Bike Computer name…"
        pendingRenameDeviceID = device.deviceID
        deviceOperationDeviceID = device.deviceID
        deviceFeedbackDeviceID = device.deviceID
        startDeviceOperationTimeout(kind: "rename")
        enqueueAuthMessage("NAME|\(Data(name.utf8).ownershipHex)")
    }

    func deregister(device: KnownBikeComputerDevice) {
        guard deviceOperationDeviceID == nil else {
            pairingError = "Another Bike Computer change is still in progress."
            return
        }
        guard connectedDeviceID == device.deviceID, isConnected, !device.isLegacy else {
            pairingError = "Connect to this Bike Computer before deregistering it."
            return
        }
        pendingDeregistrationDeviceID = device.deviceID
        deviceOperationDeviceID = device.deviceID
        deviceFeedbackDeviceID = device.deviceID
        pairingError = nil
        pairingStatusMessage = "Deregistering \(device.name)…"
        autoReconnect = false
        startDeviceOperationTimeout(kind: "deregister")
        enqueueAuthMessage("UNPAIR")
    }

    func forgetLocally(device: KnownBikeComputerDevice) {
        guard deviceOperationDeviceID == nil else {
            pairingError = "Another Bike Computer change is still in progress."
            return
        }
        guard !isConnected(to: device) || device.isLegacy else {
            pairingError = "Deregister the connected Bike Computer to remove ownership from both devices."
            return
        }
        let wasActive = deviceRegistry.activeDeviceID == device.deviceID
        let wasPendingPeripheral = connectedPeripheral?.identifier == device.peripheralIdentifier
        guard deviceRegistry.remove(deviceID: device.deviceID) else {
            pairingError = "Could not remove this Bike Computer’s secure credential from the iPhone. Try again."
            return
        }
        queueRememberedWatchControllerDeletion(deviceID: device.deviceID)

        locallyForgottenPeripheralIdentifiers.insert(device.peripheralIdentifier)
        if pendingScannedConnectionIdentifier == device.peripheralIdentifier {
            pendingScannedConnectionIdentifier = nil
        }
        discoveredPeripherals.removeValue(forKey: device.peripheralIdentifier)
        discoveredDevices.removeAll {
            $0.peripheralIdentifier == device.peripheralIdentifier
        }
        refreshKnownDevices()
        pairingError = nil
        pairingStatusMessage = nil
        deviceFeedbackDeviceID = nil

        let successorIdentifier = deviceRegistry.devices.first(where: {
            $0.deviceID == deviceRegistry.activeDeviceID
        })?.peripheralIdentifier
        if wasActive || wasPendingPeripheral {
            resetReconnectionState()
        }
        if BLELocalForgetPolicy.shouldStopScanning(
            wasActive: wasActive,
            hadPendingTransport: wasPendingPeripheral,
            hasSuccessor: successorIdentifier != nil
        ) {
            autoReconnect = false
            pendingConnectionAfterDisconnect = nil
            pendingScannedConnectionIdentifier = nil
            explicitDiscoveryRequested = false
            isExplicitDiscoveryPausedForCandidate = false
            isOpportunisticDiscoverySuppressed = true
            clearUnknownDiscoveryState()
            stopPhysicalScan(reason: "active Bike Computer forgotten locally")
            isPairingMode = false
        }
        if wasPendingPeripheral, let peripheral = connectedPeripheral {
            autoReconnect = successorIdentifier != nil
            invalidateAuthenticationForLocalForget()
            pendingConnectionAfterDisconnect = successorIdentifier
            centralManager.cancelPeripheralConnection(peripheral)
        } else if wasActive, successorIdentifier != nil {
            autoReconnect = true
            reconnectToLastDevice()
        } else if wasActive {
            autoReconnect = false
        }
    }

    private func invalidateAuthenticationForLocalForget() {
        authInfoFallbackTimer?.invalidate()
        authInfoFallbackTimer = nil
        authRetryTimer?.invalidate()
        authRetryTimer = nil
        authTimeoutTimer?.invalidate()
        authTimeoutTimer = nil
        pendingAuthNonce = nil
        authFlowState = .idle
        authenticatedWriteSession = nil
        ownerAuthenticationUsesProvisionalKey = false
        authWriteInFlight = false
        queuedAuthMessages.removeAll()
        pendingPairingSession = nil
        pendingPairingMaterial = nil
        pendingPairingCandidate = nil
        pairingPrompt = nil
        isPairingConfirmedOnDevice = false
        isPairingConfirmationSubmitting = false
        navigationWriteEndpoint = nil
        navigationWriteQueue.removeAll()
        isConnected = false
        isNavigationReady = false
        connectedDeviceID = nil
    }

    func isConnected(to device: KnownBikeComputerDevice) -> Bool {
        isConnected && connectedDeviceID == device.deviceID
    }

    private func connectDiscoveredPeripheral(identifier: UUID) {
        if let peripheral = discoveredPeripherals[identifier] ??
            centralManager.retrievePeripherals(withIdentifiers: [identifier]).first {
            connectToPeripheral(peripheral)
        } else {
            pendingScannedConnectionIdentifier = identifier
            pairingError = nil
            pairingStatusMessage = "Looking for the selected Bike Computer…"
            startPendingScannedConnectionTimeout(for: identifier)
            reconcileScanning(reason: "selected Bike Computer not cached")
        }
    }

    private func startPendingScannedConnectionTimeout(for identifier: UUID) {
        pendingScannedConnectionTimeoutTimer?.invalidate()
        pendingScannedConnectionTimeoutTimer = Timer.scheduledTimer(
            withTimeInterval: BLEPendingScanPolicy.timeout,
            repeats: false
        ) { [weak self] _ in
            guard let self,
                  self.pendingScannedConnectionIdentifier == identifier else {
                return
            }
            self.pendingScannedConnectionIdentifier = nil
            self.pendingScannedConnectionTimeoutTimer = nil
            if self.isScanning {
                self.stopPhysicalScan(
                    reason: "selected Bike Computer scan timed out"
                )
            }
            self.isPairingMode = false
            self.pairingStatusMessage = nil
            self.pairingError = "Could not find that Bike Computer. Move closer and try again."
        }
    }

    private func startDeviceOperationTimeout(kind: String) {
        deviceOperationTimeoutTimer?.invalidate()
        deviceOperationTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            guard let self,
                  self.pendingRenameDeviceID != nil || self.pendingDeregistrationDeviceID != nil else { return }
            self.pendingRenameDeviceID = nil
            self.pendingDeregistrationDeviceID = nil
            self.deviceOperationDeviceID = nil
            self.deviceOperationTimeoutTimer = nil
            self.pairingStatusMessage = nil
            self.pairingError = "The Bike Computer did not confirm the \(kind). Reconnect and try again."
            self.autoReconnect = true
            self.scheduleReconnectWithBackoff()
        }
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
        
        guard enqueueNavigationWrite(
            dataToSend,
            endpoint: endpoint,
            label: "navigation",
            writeClass: .navigationSnapshot,
            coalescingKey: DeviceBLEProtocol.navigationSnapshotCoalescingKey,
            prioritized: true
        ) else {
            log("Navigation snapshot not queued: priority lane unavailable")
            return false
        }
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

        let maxLength = navigationWriteEndpoint?.maximumWriteLength ?? 0
        if let characteristic = routeGeometryCharacteristic,
           let endpoint = navigationWriteEndpoint {
            guard data.count <= endpoint.maximumWriteLength else {
                log("Cannot send geometry: \(data.count) bytes exceeds write limit \(maxLength)")
                return
            }

            enqueueNavigationWrite(
                data,
                endpoint: endpoint,
                label: "native route geometry",
                writeClass: .route,
                atomically: true,
                transportWrite: { [weak self, weak peripheral, weak characteristic] payload in
                    guard let self, let peripheral, let characteristic else { return }
                    self.writeDeviceData(payload, to: characteristic, on: peripheral)
                }
            )
            log("Queued native route geometry: \(data.count) bytes")
            return
        }

        var fallback = Data(DeviceBLEProtocol.routeGeometryFallbackPrefix.utf8)
        fallback.append(data)
        guard fallback.count <= maxLength else {
            log("Cannot send geometry: \(data.count) bytes exceeds write limit \(maxLength)")
            return
        }

        sendFallbackMapPacket(
            fallback,
            label: "route geometry",
            writeClass: .route,
            atomically: true
        )
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
        heading: Double? = nil,
        speedMetersPerSecond: Double? = nil,
        altitudeMeters: Double? = nil,
        distanceTraveledMeters: Double? = nil,
        elapsedSeconds: TimeInterval? = nil,
        routeRemainingMeters: Double? = nil
    ) {
        guard isConnected,
              let endpoint = navigationWriteEndpoint,
              isNavigationReady else {
            log("Cannot send GPS position: BLE not ready")
            return
        }

        let data = DeviceGPSPacketBuilder.data(
            lat: lat,
            lon: lon,
            heading: DeviceGPSHeadingWirePolicy.heading(
                heading,
                supportsExplicitInvalidHeading: supportsExplicitInvalidGPSHeading
            ),
            speedMetersPerSecond: speedMetersPerSecond,
            altitudeMeters: altitudeMeters,
            distanceTraveledMeters: distanceTraveledMeters,
            elapsedSeconds: elapsedSeconds,
            routeRemainingMeters: routeRemainingMeters
        )

        if let peripheral = connectedPeripheral,
           let characteristic = gpsPositionCharacteristic {
            let route = GPSPositionWriteRouting.route(
                hasNativeWriteWithResponse:
                    characteristic.properties.contains(.write),
                hasNativeWriteWithoutResponse:
                    characteristic.properties.contains(.writeWithoutResponse),
                payloadLength: data.count,
                protectionOverhead: authenticatedWriteSession == nil
                    ? 0
                    : AuthenticatedBLEWriteSession.frameOverhead,
                withResponseMaximum: peripheral.maximumWriteValueLength(
                    for: .withResponse
                ),
                withoutResponseMaximum: peripheral.maximumWriteValueLength(
                    for: .withoutResponse
                )
            )
            let writeType: CBCharacteristicWriteType?
            switch route {
            case .nativeWithoutResponse:
                writeType = CBCharacteristicWriteType.withoutResponse
            case .nativeWithResponse:
                writeType = CBCharacteristicWriteType.withResponse
            case .navigationFallback:
                writeType = nil
            }
            if let writeType {
                let expectsWriteResponse = writeType == .withResponse
                guard enqueueNavigationWrite(
                    data,
                    endpoint: endpoint,
                    label: "native GPS position",
                    writeClass: .gpsPosition,
                    coalescingKey: DeviceBLEProtocol.gpsPositionCoalescingKey,
                    transportWrite: { [weak self, weak peripheral, weak characteristic] payload in
                        guard let self, let peripheral, let characteristic else { return }
                        self.writeDeviceData(
                            payload,
                            to: characteristic,
                            on: peripheral,
                            type: writeType
                        )
                    },
                    transportCanSend: { [weak self, weak peripheral] in
                        if expectsWriteResponse {
                            return self?.writeWithResponseInFlight == false
                        }
                        return peripheral?.canSendWriteWithoutResponse ?? false
                    },
                    transportExpectsWriteResponse: expectsWriteResponse
                ) else {
                    log("GPS position not queued: write queue unavailable")
                    return
                }
                if let heading {
                    log(String(format: "Queued native GPS position: heading=%.0f", heading))
                } else {
                    log("Queued native GPS position: heading=invalid")
                }
                return
            }
        }

        var fallback = Data(DeviceBLEProtocol.gpsPositionFallbackPrefix.utf8)
        fallback.append(data)
        guard fallback.count <= endpoint.maximumWriteLength else {
            log("Cannot send GPS position fallback: write limit exceeded")
            return
        }
        sendFallbackMapPacket(
            fallback,
            label: "GPS position",
            writeClass: .gpsPosition,
            coalescingKey: DeviceBLEProtocol.gpsPositionCoalescingKey
        )
    }

    /// Relays one fixed ride-automation frame only after authentication and
    /// explicit capability negotiation.
    @discardableResult
    func sendRideAutomationFrame(_ frame: RideAutomationFrame) -> Bool {
        guard let data = frame.encoded(),
              isConnected,
              isNavigationReady,
              hasReceivedDeviceCapabilities,
              supportsRideAutomation,
              let peripheral = connectedPeripheral else { return false }

        if let characteristic = rideAutomationCharacteristic,
           let writeType = preferredWriteType(for: characteristic),
           data.count + AuthenticatedBLEWriteSession.frameOverhead <=
              peripheral.maximumWriteValueLength(for: writeType) {
            writeDeviceData(
                data,
                to: characteristic,
                on: peripheral,
                type: writeType
            )
            return true
        }

        guard let characteristic = settingsCharacteristic,
              let writeType = preferredWriteType(for: characteristic) else {
            return false
        }
        var fallback = Data(DeviceBLEProtocol.rideAutomationFallbackPrefix.utf8)
        fallback.append(data)
        guard fallback.count + AuthenticatedBLEWriteSession.frameOverhead <=
                peripheral.maximumWriteValueLength(for: writeType) else {
            log("Ride automation fallback exceeds negotiated write length")
            return false
        }
        writeDeviceData(
            fallback,
            to: characteristic,
            on: peripheral,
            type: writeType
        )
        return true
    }

    @discardableResult
    func sendWorkoutTelemetryFrame(
        _ frame: Data,
        prioritized: Bool = false,
        onWrite: (() -> Void)? = nil,
        onDrop: (() -> Void)? = nil,
        onWriteFailure: (() -> Void)? = nil
    ) -> Bool {
        let hasValidLength: Bool
        switch frame.first {
        case 1, 2:
            hasValidLength = frame.count ==
                DeviceBLEProtocol.workoutTelemetryFrameLength
        case 3:
            hasValidLength = frame.count ==
                DeviceBLEProtocol.workoutTelemetryOriginFrameLength
        default:
            hasValidLength = false
        }
        guard hasValidLength else {
            log("Rejected malformed workout telemetry frame")
            return false
        }
        guard isConnected,
              isNavigationReady,
              hasReceivedDeviceCapabilities,
              supportsWorkoutTelemetry,
              let navigationEndpoint = navigationWriteEndpoint else {
            return false
        }

        let isCore = frame.first == 1
        let coalescingKey: String
        switch frame.first {
        case 1:
            coalescingKey =
                DeviceBLEProtocol.workoutTelemetryCoreCoalescingKey
        case 2:
            coalescingKey =
                DeviceBLEProtocol.workoutTelemetryExtendedCoalescingKey
        default:
            coalescingKey =
                DeviceBLEProtocol.workoutTelemetryOriginCoalescingKey
        }
        guard let write = workoutTelemetryWrite(
            frame,
            navigationEndpoint: navigationEndpoint,
            coalescingKey: coalescingKey,
            onWrite: onWrite,
            onDrop: onDrop,
            onWriteFailure: onWriteFailure
        ) else { return false }
        let didEnqueue = navigationWriteQueue.enqueueCoalescing(
            write,
            prioritized: prioritized && isCore
        )
        guard didEnqueue else {
            log("Workout telemetry frame not queued: write queue unavailable")
            return false
        }
        flushPendingNavigationWrites(endpoint: navigationEndpoint)
        scheduleNavigationFlushRetryIfNeeded()
        return true
    }

    /// Admits the correlated core and extended frames, plus optional transition
    /// provenance, as one queue transaction.
    /// Firmware publishes a generated update only after both halves arrive, so
    /// exposing the core to the transport before the extended frame is admitted
    /// can leave the device displaying no workout state under backpressure.
    @discardableResult
    func sendWorkoutTelemetryPair(
        core: Data,
        extended: Data,
        origin: Data? = nil,
        prioritized: Bool,
        onWrite: @escaping (Data) -> Void,
        onDrop: @escaping (Data) -> Void,
        onWriteFailure: @escaping (Data) -> Void
    ) -> Bool {
        guard core.count == DeviceBLEProtocol.workoutTelemetryFrameLength,
              core.first == 1,
              extended.count == DeviceBLEProtocol.workoutTelemetryFrameLength,
              extended.first == 2,
              origin == nil || (
                  origin?.count ==
                    DeviceBLEProtocol.workoutTelemetryOriginFrameLength
                      && origin?.first == 3
              ),
              isConnected,
              isNavigationReady,
              hasReceivedDeviceCapabilities,
              supportsWorkoutTelemetry,
              let navigationEndpoint = navigationWriteEndpoint,
              let coreWrite = workoutTelemetryWrite(
                  core,
                  navigationEndpoint: navigationEndpoint,
                  coalescingKey:
                    DeviceBLEProtocol.workoutTelemetryCoreCoalescingKey,
                  onWrite: { onWrite(core) },
                  onDrop: { onDrop(core) },
                  onWriteFailure: { onWriteFailure(core) }
              ),
              let extendedWrite = workoutTelemetryWrite(
                  extended,
                  navigationEndpoint: navigationEndpoint,
                  coalescingKey:
                    DeviceBLEProtocol.workoutTelemetryExtendedCoalescingKey,
                  onWrite: { onWrite(extended) },
                  onDrop: { onDrop(extended) },
                  onWriteFailure: { onWriteFailure(extended) }
              ) else {
            return false
        }

        var writes = [coreWrite, extendedWrite]
        if let origin {
            guard let originWrite = workoutTelemetryWrite(
                origin,
                navigationEndpoint: navigationEndpoint,
                coalescingKey:
                    DeviceBLEProtocol.workoutTelemetryOriginCoalescingKey,
                onWrite: { onWrite(origin) },
                onDrop: { onDrop(origin) },
                onWriteFailure: { onWriteFailure(origin) }
            ) else {
                return false
            }
            writes.append(originWrite)
        }
        let didEnqueue = prioritized
            ? navigationWriteQueue.enqueuePrioritizedAtomically(writes)
            : navigationWriteQueue.enqueueAtomically(writes)
        guard didEnqueue else {
            log("Workout telemetry pair not queued: insufficient write queue capacity")
            return false
        }
        flushPendingNavigationWrites(endpoint: navigationEndpoint)
        scheduleNavigationFlushRetryIfNeeded()
        return true
    }

    private func workoutTelemetryWrite(
        _ frame: Data,
        navigationEndpoint: NavigationWriteEndpoint,
        coalescingKey: String,
        onWrite: (() -> Void)?,
        onDrop: (() -> Void)?,
        onWriteFailure: (() -> Void)?
    ) -> NavigationWrite? {
        let payload: Data
        let label: String
        let transportWrite: ((Data) -> Void)?
        let transportCanSend: (() -> Bool)?
        let transportExpectsWriteResponse: Bool?

        let testEndpoint = workoutTelemetryWriteEndpointForTesting
        let characteristic = workoutTelemetryCharacteristic
        let route = WorkoutTelemetryWriteRouting.route(
            hasNativeWriteWithResponse:
                characteristic?.properties.contains(.write) == true,
            hasNativeWriteWithoutResponse:
                testEndpoint != nil ||
                characteristic?.properties.contains(.writeWithoutResponse) == true,
            navigationExpectsWriteResponse:
                navigationEndpoint.expectsWriteResponse
        )

        switch route {
        case .nativeWithResponse:
            guard let peripheral = connectedPeripheral,
                  let characteristic,
                  frame.count <= peripheral.maximumWriteValueLength(
                    for: .withResponse
                  ) else {
                return nil
            }
            payload = frame
            label = "native workout telemetry"
            transportCanSend = { [weak self] in
                self?.writeWithResponseInFlight == false
            }
            transportExpectsWriteResponse = true
            transportWrite = { [weak self, weak peripheral, weak characteristic] data in
                guard let self, let peripheral, let characteristic else { return }
                self.writeDeviceData(
                    data,
                    to: characteristic,
                    on: peripheral,
                    type: .withResponse
                )
            }
        case .navigationFallback:
            var fallback = Data(
                DeviceBLEProtocol.workoutTelemetryFallbackPrefix.utf8
            )
            fallback.append(frame)
            guard fallback.count <= navigationEndpoint.maximumWriteLength else {
                return nil
            }
            payload = fallback
            label = "fallback workout telemetry"
            transportWrite = nil
            transportCanSend = nil
            transportExpectsWriteResponse = nil
        case .nativeWithoutResponse:
            if let testEndpoint {
                guard frame.count <= testEndpoint.maximumWriteLength else {
                    return nil
                }
                payload = frame
                label = "native workout telemetry"
                transportWrite = testEndpoint.write
                transportCanSend = testEndpoint.canSend
                transportExpectsWriteResponse = false
                break
            }
            guard let peripheral = connectedPeripheral,
                  let characteristic,
                  characteristic.properties.contains(.writeWithoutResponse),
                  frame.count <= peripheral.maximumWriteValueLength(
                    for: .withoutResponse
                  ) else {
                return nil
            }
            payload = frame
            label = "native workout telemetry"
            transportCanSend = { [weak peripheral] in
                peripheral?.canSendWriteWithoutResponse ?? false
            }
            transportExpectsWriteResponse = false
            transportWrite = { [weak self, weak peripheral, weak characteristic] data in
                guard let self, let peripheral, let characteristic else { return }
                self.writeDeviceData(
                    data,
                    to: characteristic,
                    on: peripheral,
                    type: .withoutResponse
                )
            }
        }

        return NavigationWrite(
            data: payload,
            label: label,
            transportWrite: transportWrite,
            onWrite: onWrite,
            onDrop: onDrop,
            onWriteFailure: onWriteFailure,
            transportCanSend: transportCanSend,
            transportExpectsWriteResponse: transportExpectsWriteResponse,
            writeClass: .workoutTelemetry,
            coalescingKey: coalescingKey
        )
    }

    /// Persist and send a runtime map setting to ESP32 when supported.
    func sendSetting(id: UInt8, value: Int32,
                     synchronizeLegacyProfile: Bool = true) {
        if id == DeviceBLEProtocol.brightnessSettingID {
            deviceBrightnessPercent = DeviceBLEProtocol.normalizedBrightnessPercent(
                Double(value)
            )
        }
        if hasReceivedDeviceCapabilities,
           !supportsIndependentMapProfiles,
           !isSendingNegotiatedMapProfiles,
           synchronizeLegacyProfile,
           Self.isLegacyMapProfileSetting(id) {
            synchronizeMapPlusNavigationProfileWithMap(for: id)
        }
        saveSettings()
        if Self.isIndependentMapProfileSetting(id),
           (!hasReceivedDeviceCapabilities || !supportsIndependentMapProfiles) {
            log("Independent map setting id=\(id) not sent: connected firmware does not advertise support")
            return
        }
        if id == DeviceBLEProtocol.mapPlusNavigationBirdsEyeViewSettingID,
           (!hasReceivedDeviceCapabilities || !supportsBirdsEyeMapNavigation) {
            log("Bird's-eye map setting not sent: connected firmware does not advertise support")
            return
        }
        if id == DeviceBLEProtocol.mapPlusNavigationBirdsEyePerspectiveSettingID,
           (!hasReceivedDeviceCapabilities || !supportsBirdsEyeMapNavigationPerspective) {
            log("Bird's-eye perspective setting not sent: connected firmware does not advertise support")
            return
        }
        if id == DeviceBLEProtocol.mapPlusNavigation3DBuildingsSettingID,
           (!hasReceivedDeviceCapabilities || !supports3DBuildings) {
            log("3D buildings setting not sent: connected firmware does not advertise support")
            return
        }
        if Self.isStreetLabelSetting(id),
           (!hasReceivedDeviceCapabilities || !supportsStreetLabels) {
            log("Street-label setting id=\(id) not sent: connected firmware does not advertise support")
            return
        }
        let deviceValue: Int32
        if id == DeviceBLEProtocol.brightnessSettingID {
            deviceValue = Int32(deviceBrightnessPercent)
        } else if id == DeviceBLEProtocol.mapPlusNavigationBirdsEyePerspectiveSettingID {
            let maximum = supportsBirdsEyeMapNavigationStrongerPerspective
                ? MapNavigationBirdsEyePerspective.maximum.rawValue
                : MapNavigationBirdsEyePerspective.strong.rawValue
            deviceValue = min(max(value, 0), Int32(maximum))
        } else if id == 9 || id == DeviceBLEProtocol.mapPlusNavigationStreetLineWidthSettingID {
            deviceValue = DeviceBLEProtocol.legacyStreetWidthBoost(
                fromAbsoluteWidth: value
            )
        } else {
            deviceValue = value
        }
        guard sendSettingPacket(id: id, value: deviceValue, label: "setting id=\(id)") else {
            log("Settings characteristic unsupported; saved local setting id=\(id), value=\(value)")
            return
        }
    }

    func sendStreetLabelDensity(for screen: DeviceScreen) {
        let settingID: UInt8
        let enabled: Bool
        let density: Int
        switch screen {
        case .map:
            settingID = DeviceBLEProtocol.mapLabelDensitySettingID
            enabled = mapLabelsEnabled
            density = mapLabelDensity
        case .mapPlusNavigation:
            settingID = DeviceBLEProtocol.mapPlusNavigationLabelDensitySettingID
            enabled = mapPlusNavigationLabelsEnabled
            density = mapPlusNavigationLabelDensity
        case .navigation, .rideStats, .batteryStatus:
            return
        }
        sendSetting(
            id: settingID,
            value: DeviceBLEProtocol.effectiveStreetLabelDensity(
                enabled: enabled,
                density: density
            )
        )
    }

    @discardableResult
    private func sendSettingPacket(id: UInt8, value: Int32, label: String) -> Bool {
        guard isConnected, isNavigationReady else { return false }

        var data = Data()
        data.append(id)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }

        var fallback = Data(DeviceBLEProtocol.settingsFallbackPrefix.utf8)
        fallback.append(data)

        return DevicePacketRouting.sendPreferredThenFallback(
            preferred: {
                sendNativeMapTransferPacket(data, label: label)
            },
            fallback: {
                guard fallback.count <= (navigationWriteEndpoint?.maximumWriteLength ?? 0) else {
                    log("Cannot send \(label): write limit exceeded")
                    return false
                }
                return sendFallbackMapPacket(fallback, label: label)
            }
        )
    }

#if canImport(UIKit) && !HOST_TESTING
    private func sendPhoneBatteryStatus(force: Bool = false) {
        guard isConnected,
              isNavigationReady,
              hasReceivedDeviceCapabilities,
              supportsBatteryStatusScreen,
              let percentage = DeviceBLEProtocol.phoneBatteryPercentage(
                from: UIDevice.current.batteryLevel
              ) else {
            return
        }

        if (force || percentage != lastSentPhoneBatteryPercent),
           sendSettingPacket(
            id: DeviceBLEProtocol.phoneBatteryLevelSettingID,
            value: percentage,
            label: "phone battery level"
           ) {
            lastSentPhoneBatteryPercent = percentage
        }

        let isCharging = UIDevice.current.batteryState == .charging
        if (force || isCharging != lastSentPhoneBatteryCharging),
           sendSettingPacket(
            id: DeviceBLEProtocol.phoneBatteryChargingSettingID,
            value: DeviceBLEProtocol.phoneBatteryChargingValue(
                isCharging: isCharging
            ),
            label: "phone charging state"
           ) {
            lastSentPhoneBatteryCharging = isCharging
        }
    }
#else
    private func sendPhoneBatteryStatus(force: Bool = false) {}
#endif

    private static func isLegacyMapProfileSetting(_ id: UInt8) -> Bool {
        id == 1 || id == 2 || id == 3 || id == 7 || id == 8 || id == 9 || id == 10
    }

    private static func isIndependentMapProfileSetting(_ id: UInt8) -> Bool {
        (id >= DeviceBLEProtocol.mapPlusNavigationMinPolygonSizeSettingID &&
            id <= DeviceBLEProtocol.mapPlusNavigationPositionMarkerScaleSettingID) ||
            (id >= DeviceBLEProtocol.mapPlusNavigationLabelDensitySettingID &&
                id <= DeviceBLEProtocol.mapPlusNavigationLabelOrientationSettingID)
    }

    private static func isStreetLabelSetting(_ id: UInt8) -> Bool {
        id >= DeviceBLEProtocol.mapLabelDensitySettingID &&
            id <= DeviceBLEProtocol.mapPlusNavigationLabelOrientationSettingID
    }

    private func synchronizeMapPlusNavigationProfileWithMap(for settingID: UInt8) {
        switch settingID {
        case 1:
            mapPlusNavigationMinPolygonSize = minPolygonSize
        case 2:
            mapPlusNavigationDetailLevel = detailLevel
        case 3:
            mapPlusNavigationRouteLineWidth = routeLineWidth
        case 7:
            mapPlusNavigationZoomLevel = zoomLevel
        case 8:
            mapPlusNavigationShowBuildings = showBuildings
            mapPlusNavigationShowGreenSpace = showGreenSpace
            mapPlusNavigationShowPaths = showPaths
            mapPlusNavigationShowTracks = showTracks
            mapPlusNavigationShowMajorRoads = showMajorRoads
            mapPlusNavigationShowLocalStreets = showLocalStreets
            mapPlusNavigationShowServiceRoads = showServiceRoads
            mapPlusNavigationShowWater = showWater
            mapPlusNavigationShowRailways = showRailways
            mapPlusNavigationShowOtherAreas = showOtherAreas
        case 9:
            mapPlusNavigationStreetLineWidth = streetLineWidth
        case 10:
            mapPlusNavigationPositionMarkerScale = positionMarkerScale
        default:
            break
        }
    }

    private func sendMapProfilesAfterCapabilityNegotiation() {
        guard isConnected,
              isNavigationReady,
              hasReceivedDeviceCapabilities else { return }

        let shouldSendMap = !hasSentMapProfileForConnection
        let shouldSendMapNavigation = supportsIndependentMapProfiles &&
            !hasSentMapNavigationProfileForConnection
        guard shouldSendMap || shouldSendMapNavigation else { return }

        isSendingNegotiatedMapProfiles = true
        defer { isSendingNegotiatedMapProfiles = false }

        // The first independent packet switches new firmware out of legacy
        // mirroring mode before the Map profile's legacy IDs arrive.
        if shouldSendMapNavigation {
            hasSentMapNavigationProfileForConnection = true
            sendVisibilityMask(for: .mapPlusNavigation)
            sendSetting(id: DeviceBLEProtocol.mapPlusNavigationMinPolygonSizeSettingID,
                        value: Int32(mapPlusNavigationMinPolygonSize))
            sendSetting(id: DeviceBLEProtocol.mapPlusNavigationDetailLevelSettingID,
                        value: Int32(mapPlusNavigationDetailLevel))
            sendSetting(id: DeviceBLEProtocol.mapPlusNavigationRouteLineWidthSettingID,
                        value: Int32(mapPlusNavigationRouteLineWidth))
            sendSetting(id: DeviceBLEProtocol.mapPlusNavigationStreetLineWidthSettingID,
                        value: Int32(mapPlusNavigationStreetLineWidth))
            sendSetting(id: DeviceBLEProtocol.mapPlusNavigationPositionMarkerScaleSettingID,
                        value: Int32(mapPlusNavigationPositionMarkerScale))
            sendSetting(id: DeviceBLEProtocol.mapPlusNavigationZoomLevelSettingID,
                        value: Int32(mapPlusNavigationZoomLevel))
            if supportsBirdsEyeMapNavigation {
                sendSetting(
                    id: DeviceBLEProtocol.mapPlusNavigationBirdsEyeViewSettingID,
                    value: mapPlusNavigationBirdsEyeViewEnabled ? 1 : 0
                )
            }
            if supportsBirdsEyeMapNavigationPerspective {
                sendSetting(
                    id: DeviceBLEProtocol.mapPlusNavigationBirdsEyePerspectiveSettingID,
                    value: Int32(mapPlusNavigationBirdsEyePerspective.rawValue)
                )
            }
            if supportsStreetLabels {
                sendStreetLabelDensity(for: .mapPlusNavigation)
                sendSetting(id: DeviceBLEProtocol.mapPlusNavigationLabelLanguageModeSettingID,
                            value: Int32(mapPlusNavigationLabelLanguageMode))
                sendSetting(id: DeviceBLEProtocol.mapPlusNavigationLabelTextSizeSettingID,
                            value: Int32(mapPlusNavigationLabelTextSize))
                sendSetting(id: DeviceBLEProtocol.mapPlusNavigationLabelOrientationSettingID,
                            value: Int32(mapPlusNavigationLabelOrientation))
            }
            if supports3DBuildings {
                sendSetting(
                    id: DeviceBLEProtocol.mapPlusNavigation3DBuildingsSettingID,
                    value: mapPlusNavigation3DBuildingsEnabled ? 1 : 0
                )
            }
        }

        if shouldSendMap {
            hasSentMapProfileForConnection = true
            sendVisibilityMask(for: .map)
            sendSetting(id: 1, value: Int32(minPolygonSize))
            sendSetting(id: 2, value: Int32(detailLevel))
            sendSetting(id: 3, value: Int32(routeLineWidth))
            sendSetting(id: 9, value: Int32(streetLineWidth))
            sendSetting(id: 10, value: Int32(positionMarkerScale))
            sendSetting(id: 7, value: Int32(zoomLevel))
            if supportsStreetLabels {
                sendStreetLabelDensity(for: .map)
                sendSetting(id: DeviceBLEProtocol.mapLabelLanguageModeSettingID,
                            value: Int32(mapLabelLanguageMode))
                sendSetting(id: DeviceBLEProtocol.mapLabelTextSizeSettingID,
                            value: Int32(mapLabelTextSize))
                sendSetting(id: DeviceBLEProtocol.mapLabelOrientationSettingID,
                            value: Int32(mapLabelOrientation))
            }
        }
    }

    func useDeviceCapabilitiesFallback() {
        guard isConnected, isNavigationReady, !hasReceivedDeviceCapabilities else { return }
        supportsIndependentMapProfiles = false
        supportsExtendedMapVisibility = false
        supportsBirdsEyeMapNavigation = false
        supportsBirdsEyeMapNavigationPerspective = false
        supportsBirdsEyeMapNavigationStrongerPerspective = false
        supportsBatteryStatusScreen = false
        supportsDestinationPicker = false
        supportsStreetLabels = false
        supports3DBuildings = false
        supportsRideAutomation = false
        supportsExplicitInvalidGPSHeading = false
        supportsScopedWatchController = false
        watchControllerIDHex = nil
        hasReceivedWatchControllerStatus = false
        isWatchControllerPromotionInFlight = false
        updateWorkoutTelemetryCapability(false)
        nextDestinationCatalogTransferID = 1
        hasReceivedDeviceCapabilities = true
        log("Device capabilities unavailable; using baseline feature visibility")
        sendScreenSettingsAfterCapabilityNegotiation()
        sendMapProfilesAfterCapabilityNegotiation()
    }
    
    /// Send feature visibility bitmask
    func sendVisibilityMask() {
        sendVisibilityMask(for: .map, synchronizeLegacyProfile: false)
    }

    func sendVisibilityMask(for screen: DeviceScreen,
                            synchronizeLegacyProfile: Bool = true) {
        var mask: Int32 = 0
        let settingID: UInt8

        switch screen {
        case .map:
            if showBuildings { mask |= (1 << 0) }
            if showGreenSpace { mask |= (1 << 1) }
            if showPaths || (!supportsExtendedMapVisibility && showTracks) { mask |= (1 << 2) }
            if showMajorRoads { mask |= (1 << 3) }
            if showLocalStreets || (!supportsExtendedMapVisibility && showServiceRoads) { mask |= (1 << 4) }
            if showWater { mask |= (1 << 5) }
            if showRailways { mask |= (1 << 6) }
            if showOtherAreas { mask |= (1 << 7) }
            if showRouteOverlay { mask |= (1 << 8) }
            if showCurrentPosition { mask |= (1 << 9) }
            if supportsExtendedMapVisibility {
                if showServiceRoads { mask |= DeviceBLEProtocol.serviceRoadsVisibilityMask }
                if showTracks { mask |= DeviceBLEProtocol.tracksVisibilityMask }
                mask |= DeviceBLEProtocol.extendedVisibilityMarker
            }
            settingID = 8
        case .mapPlusNavigation:
            if mapPlusNavigationShowBuildings { mask |= (1 << 0) }
            if mapPlusNavigationShowGreenSpace { mask |= (1 << 1) }
            if mapPlusNavigationShowPaths || (!supportsExtendedMapVisibility && mapPlusNavigationShowTracks) { mask |= (1 << 2) }
            if mapPlusNavigationShowMajorRoads { mask |= (1 << 3) }
            if mapPlusNavigationShowLocalStreets || (!supportsExtendedMapVisibility && mapPlusNavigationShowServiceRoads) { mask |= (1 << 4) }
            if mapPlusNavigationShowWater { mask |= (1 << 5) }
            if mapPlusNavigationShowRailways { mask |= (1 << 6) }
            if mapPlusNavigationShowOtherAreas { mask |= (1 << 7) }
            if supportsExtendedMapVisibility {
                if mapPlusNavigationShowServiceRoads { mask |= DeviceBLEProtocol.serviceRoadsVisibilityMask }
                if mapPlusNavigationShowTracks { mask |= DeviceBLEProtocol.tracksVisibilityMask }
                mask |= DeviceBLEProtocol.extendedVisibilityMarker
            }
            settingID = DeviceBLEProtocol.mapPlusNavigationVisibilityMaskSettingID
        case .navigation, .rideStats, .batteryStatus:
            return
        }

        sendSetting(id: settingID, value: mask,
                    synchronizeLegacyProfile: synchronizeLegacyProfile)
    }

    func isDeviceScreenEnabled(_ screen: DeviceScreen) -> Bool {
        effectiveEnabledDeviceScreensMask & screen.bit != 0
    }

    func isOnlyEnabledDeviceScreen(_ screen: DeviceScreen) -> Bool {
        guard isDeviceScreenEnabled(screen) else { return false }
        return availableDeviceScreens.filter { isDeviceScreenEnabled($0) }.count == 1
    }

    func setDeviceScreen(_ screen: DeviceScreen, enabled: Bool) {
        guard availableDeviceScreens.contains(screen) else { return }

        var mask = effectiveEnabledDeviceScreensMask
        if !supportsBatteryStatusScreen {
            mask |= enabledDeviceScreensMask & DeviceScreen.batteryStatus.bit
        }
        if enabled {
            mask |= screen.bit
        } else {
            let candidateMask = mask & ~screen.bit
            guard candidateMask != 0 else { return }
            mask = candidateMask
        }

        let oldDefault = defaultDeviceScreen
        enabledDeviceScreensMask = DeviceScreen.normalizedMask(mask)
        defaultDeviceScreen = DeviceScreen.fallbackDefault(
            for: defaultDeviceScreen.rawValue,
            mask: enabledDeviceScreensMask
        )
        sendEnabledDeviceScreensMask()
        if defaultDeviceScreen != oldDefault {
            sendDefaultDeviceScreen()
        }
    }

    var enabledDeviceScreens: [DeviceScreen] {
        availableDeviceScreens.filter { isDeviceScreenEnabled($0) }
    }

    var availableDeviceScreens: [DeviceScreen] {
        DeviceScreen.displayOrder.filter { supportedDeviceScreensMask & $0.bit != 0 }
    }

    var effectiveDefaultDeviceScreen: DeviceScreen {
        DeviceScreen.fallbackDefault(
            for: defaultDeviceScreen.rawValue,
            mask: effectiveEnabledDeviceScreensMask,
            supportedMask: supportedDeviceScreensMask
        )
    }

    func sendEnabledDeviceScreensMask() {
        enabledDeviceScreensMask = DeviceScreen.normalizedMask(enabledDeviceScreensMask)
        defaultDeviceScreen = DeviceScreen.fallbackDefault(
            for: defaultDeviceScreen.rawValue,
            mask: enabledDeviceScreensMask
        )
        var outgoingMask = Int32(effectiveEnabledDeviceScreensMask)
        if supportsBatteryStatusScreen {
            outgoingMask |= DeviceBLEProtocol.currentScreenMaskMarker
        }
        sendSetting(id: DeviceBLEProtocol.enabledScreensSettingID,
                    value: outgoingMask)
    }

    func sendDefaultDeviceScreen() {
        defaultDeviceScreen = DeviceScreen.fallbackDefault(
            for: defaultDeviceScreen.rawValue,
            mask: enabledDeviceScreensMask
        )
        sendSetting(id: DeviceBLEProtocol.defaultScreenSettingID,
                    value: Int32(effectiveDefaultDeviceScreen.rawValue))
    }

    private var supportedDeviceScreensMask: Int {
        guard hasReceivedDeviceCapabilities else { return DeviceScreen.allScreensMask }
        return supportsBatteryStatusScreen
            ? DeviceScreen.allScreensMask
            : DeviceScreen.legacyScreensMask
    }

    private var effectiveEnabledDeviceScreensMask: Int {
        DeviceScreen.normalizedMask(
            enabledDeviceScreensMask,
            supportedMask: supportedDeviceScreensMask
        )
    }

    private func sendScreenSettingsAfterCapabilityNegotiation() {
        guard supportsDeviceSettings,
              hasReceivedDeviceCapabilities,
              !hasSentScreenSettingsForConnection else {
            return
        }
        hasSentScreenSettingsForConnection = true
        sendEnabledDeviceScreensMask()
        sendDefaultDeviceScreen()
        if supportsBatteryStatusScreen {
            sendPhoneBatteryStatus(force: true)
        }
    }

    @discardableResult
    func playDeviceSound(_ sound: DeviceSound, volumePercent: Double) -> Bool {
        guard supportsDeviceSounds else {
            log("Cannot play device sound: connected device does not advertise sound support")
            return false
        }

        let packet = sound.playPacket(volumePercent: volumePercent)
        let volume = packet.last ?? UInt8(DeviceSound.defaultVolumePercent)

        let label = "sound \(sound.rawValue) at \(volume)%"
        return DevicePacketRouting.sendPreferredThenFallback(
            preferred: { sendNativeMapTransferPacket(packet, label: label) },
            fallback: { sendFallbackMapPacket(packet, label: label) }
        )
    }

    @discardableResult
    func playSelectedDeviceSound() -> Bool {
        playDeviceSound(selectedDeviceSound, volumePercent: deviceSoundVolumePercent)
    }

    @discardableResult
    func sendPowerButtonHonkConfiguration() -> Bool {
        guard supportsPowerButtonHonk else {
            log("Cannot configure PWR honk: connected device does not advertise support")
            return false
        }

        let requestID: UInt32?
        if supportsPowerButtonHonkAcknowledgement {
            requestID = nextPowerButtonHonkRequestID
            nextPowerButtonHonkRequestID &+= 1
            if nextPowerButtonHonkRequestID == 0 {
                nextPowerButtonHonkRequestID = 1
            }
        } else {
            requestID = nil
        }
        let packet = selectedDeviceSound.powerButtonHonkPacket(
            enabled: isPowerButtonHonkEnabled,
            volumePercent: deviceSoundVolumePercent,
            requestID: requestID
        )
        powerButtonHonkConfigurationError = nil
        clearPendingPowerButtonHonkConfiguration()
        guard supportsPowerButtonHonkAcknowledgement else {
            let sent = routePowerButtonHonkConfiguration(packet)
            if !sent {
                reportPowerButtonHonkConfigurationFailure(
                    "PWR honk configuration could not be sent"
                )
            }
            return sent
        }

        pendingPowerButtonHonkPacket = packet
        powerButtonHonkAttempt = 0
        let sent = transmitPowerButtonHonkConfiguration(packet)
        if !sent {
            reportPowerButtonHonkConfigurationFailure(
                "PWR honk configuration could not be sent"
            )
        }
        return sent
    }

    func deviceSoundVolumeEditingChanged(_ isEditing: Bool) {
        guard !isEditing, isPowerButtonHonkEnabled else { return }
        sendPowerButtonHonkConfiguration()
    }

    private func transmitPowerButtonHonkConfiguration(_ packet: Data) -> Bool {
        let label = powerButtonHonkConfigurationLabel(packet)
        if sendNativeMapTransferPacket(packet, label: label) {
            schedulePowerButtonHonkRetry(
                for: packet,
                after: powerButtonHonkAckTimeout
            )
            return true
        }

        return sendFallbackMapPacket(
            packet,
            label: label,
            onWrite: { [weak self] in
                guard let self, self.pendingPowerButtonHonkPacket == packet else { return }
                self.schedulePowerButtonHonkRetry(
                    for: packet,
                    after: self.powerButtonHonkAckTimeout
                )
            },
            onDrop: { [weak self] in
                guard let self, self.pendingPowerButtonHonkPacket == packet else { return }
                self.reportPowerButtonHonkConfigurationFailure(
                    "PWR honk configuration was dropped before it could be sent"
                )
            }
        )
    }

    private func routePowerButtonHonkConfiguration(_ packet: Data) -> Bool {
        let label = powerButtonHonkConfigurationLabel(packet)
        return DevicePacketRouting.sendPreferredThenFallback(
            preferred: { sendNativeMapTransferPacket(packet, label: label) },
            fallback: { sendFallbackMapPacket(packet, label: label) }
        )
    }

    private func powerButtonHonkConfigurationLabel(_ packet: Data) -> String {
        let enabled = packet.count >= 3 && packet[packet.count - 3] == 1
        return "PWR honk \(enabled ? "enabled" : "disabled")"
    }

    private func schedulePowerButtonHonkRetry(
        for packet: Data,
        after delay: TimeInterval
    ) {
        powerButtonHonkRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.pendingPowerButtonHonkPacket == packet else { return }
            guard PowerButtonHonkRetry.shouldRetry(
                isNavigationReady: self.isNavigationReady,
                attempt: self.powerButtonHonkAttempt
            ) else {
                self.reportPowerButtonHonkConfigurationFailure(
                    "PWR honk configuration was not acknowledged"
                )
                return
            }

            self.powerButtonHonkAttempt += 1
            if !self.transmitPowerButtonHonkConfiguration(packet) {
                self.reportPowerButtonHonkConfigurationFailure(
                    "PWR honk configuration retry could not be sent"
                )
            }
        }
        powerButtonHonkRetryWorkItem = workItem
        powerButtonHonkRetryScheduler(delay, workItem)
    }

    private func reportPowerButtonHonkConfigurationFailure(_ logMessage: String) {
        log(logMessage)
        powerButtonHonkConfigurationError =
            "Could not apply PWR honk settings on the device."
        clearPendingPowerButtonHonkConfiguration()
    }

    private func clearPendingPowerButtonHonkConfiguration() {
        powerButtonHonkRetryWorkItem?.cancel()
        powerButtonHonkRetryWorkItem = nil
        pendingPowerButtonHonkPacket = nil
        powerButtonHonkAttempt = 0
    }

    @discardableResult
    func requestMapTransferMode(enabled: Bool) -> Bool {
        var packet = Data(DeviceBLEProtocol.mapTransferControlPrefix.utf8)
        packet.append(Data((enabled ? "enter" : "exit").utf8))
        let label = enabled ? "map transfer enter" : "map transfer exit"
        return sendTransferControlPacket(
            packet,
            label: label,
            coalescingKey: "transfer.map.control"
        )
    }

    @discardableResult
    func requestMapTransferStatus() -> Bool {
        let packet = Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8)
        return sendTransferControlPacket(
            packet,
            label: "map transfer status",
            coalescingKey: "transfer.map.status"
        )
    }

    func resetMapTransferActivationObservation() {
        mapTransferActivationStatus = "idle"
        mapTransferActivationSequence = nil
        mapTransferActivationSessionId = ""
        mapTransferActivationMapId = ""
        mapTransferActivationStep = nil
        mapTransferActivationStepCount = nil
        mapTransferActivationProgress = nil
        mapTransferActivationError = nil
    }

    @discardableResult
    func requestDeviceTransferMode(_ mode: DeviceTransferSession.Mode) -> Bool {
        var packet = Data(DeviceBLEProtocol.deviceTransferControlPrefix.utf8)
        packet.append(Data("enter|\(mode.rawValue)".utf8))
        let coalescingKey = mode == .map
            ? "transfer.map.control"
            : "transfer.device.control"
        return sendTransferControlPacket(
            packet,
            label: "\(mode.rawValue) transfer enter",
            coalescingKey: coalescingKey
        )
    }

    @discardableResult
    func requestDeviceTransferExit() -> Bool {
        var packet = Data(DeviceBLEProtocol.deviceTransferControlPrefix.utf8)
        packet.append(Data("exit".utf8))
        return sendTransferControlPacket(
            packet,
            label: "device transfer exit",
            coalescingKey: "transfer.device.control"
        )
    }

    @discardableResult
    func requestDeviceTransferStatus() -> Bool {
        let packet = Data(DeviceBLEProtocol.deviceTransferStatusPrefix.utf8)
        return sendTransferControlPacket(
            packet,
            label: "device transfer status",
            coalescingKey: "transfer.device.status"
        )
    }

    @discardableResult
    func requestDeviceCapabilities() -> Bool {
        var packet = Data(DeviceBLEProtocol.deviceCapabilitiesPrefix.utf8)
        packet.append(DeviceBLEProtocol.deviceCapabilitiesVersion)
        return DevicePacketRouting.sendPreferredThenFallback(
            preferred: {
                sendNativeMapTransferPacket(packet, label: "device capabilities")
            },
            fallback: {
                sendFallbackMapPacket(packet, label: "device capabilities")
            }
        )
    }

    @discardableResult
    func sendDestinationCatalog(_ payload: DeviceDestinationCatalogPayload) -> Bool {
        guard supportsDestinationPicker,
              let endpoint = navigationWriteEndpoint,
              isConnected,
              isNavigationReady,
              let frames = DeviceDestinationCatalogChunker.frames(
                payload: payload,
                transferID: nextDestinationCatalogTransferID,
                maximumWriteLength: endpoint.maximumWriteLength
              ) else {
            log("Cannot send destination catalog: picker unsupported or transport unavailable")
            return false
        }

        guard enqueueDestinationFrames(
            frames,
            endpoint: endpoint,
            label: "destination catalog generation=\(payload.generation)",
            onWriteFailure: { [weak self] in
                self?.onDestinationCatalogWriteFailure?()
            }
        ) else { return false }

        nextDestinationCatalogTransferID &+= 1
        if nextDestinationCatalogTransferID == 0 {
            nextDestinationCatalogTransferID = 1
        }
        return true
    }

    @discardableResult
    func sendDestinationStatus(
        generation: UInt32,
        token: UInt16,
        status: DeviceDestinationStatusCode,
        message: String
    ) -> Bool {
        destinationStatusSequence &+= 1
        return enqueueDestinationStatus(
            generation: generation,
            token: token,
            status: status,
            message: message,
            sequence: destinationStatusSequence,
            attempt: 0
        )
    }

    @discardableResult
    private func enqueueDestinationStatus(
        generation: UInt32,
        token: UInt16,
        status: DeviceDestinationStatusCode,
        message: String,
        sequence: UInt64,
        attempt: Int
    ) -> Bool {
        // A DREQ notification itself proves that the connected firmware knows
        // DNST. Allow the reply during the brief post-authentication window
        // before the CAPS response arrives, when the device may still show its
        // retained catalog from the previous connection.
        guard let endpoint = navigationWriteEndpoint,
              isConnected,
              isNavigationReady,
              endpoint.maximumWriteLength >= 11 else { return false }
        let packet = DeviceDestinationStatusPacketBuilder.data(
            generation: generation,
            token: token,
            status: status,
            message: message,
            maximumLength: endpoint.maximumWriteLength
        )
        guard packet.count <= endpoint.maximumWriteLength else {
            log("Cannot send destination status: write limit exceeded")
            return false
        }
        return enqueueDestinationFrames(
            [packet],
            endpoint: endpoint,
            label: "destination status \(status)",
            prioritized: true,
            coalescingKey: "destination-status",
            onWriteFailure: { [weak self] in
                self?.scheduleDestinationStatusRetry(
                    generation: generation,
                    token: token,
                    status: status,
                    message: message,
                    sequence: sequence,
                    failedAttempt: attempt
                )
            }
        )
    }

    private func scheduleDestinationStatusRetry(
        generation: UInt32,
        token: UInt16,
        status: DeviceDestinationStatusCode,
        message: String,
        sequence: UInt64,
        failedAttempt: Int
    ) {
        guard DeviceDestinationStatusRetryPolicy.shouldRetry(
            afterAttempt: failedAttempt
        ) else {
            log("Destination status write failed after all retries")
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + DeviceDestinationStatusRetryPolicy.retryDelay
        ) { [weak self] in
            guard let self,
                  self.destinationStatusSequence == sequence,
                  self.isConnected,
                  self.isNavigationReady else { return }
            let didRetry = self.enqueueDestinationStatus(
                generation: generation,
                token: token,
                status: status,
                message: message,
                sequence: sequence,
                attempt: failedAttempt + 1
            )
            if !didRetry {
                self.log("Destination status retry could not be queued")
            }
        }
    }

    func sendDebugNavigationPacket() {
        let packet = "\(NavigationIconID.left)|123|Debug turn left"
        guard sendNavigationData(packet) else {
            log("Debug navigation packet was not sent")
            return
        }

        log("Sent debug navigation packet")
    }

    var debugLogText: String {
        debugEvents.joined(separator: "\n")
    }
    
    /// Attempt to reconnect to last known peripheral
    func reconnectToLastDevice() {
        guard watchDirectRidePreparedDeviceID == nil else {
            stopPhysicalScan(reason: "Apple Watch direct ride owns BLE")
            log("Skipping reconnect while Apple Watch direct ride is active")
            return
        }
        guard isScanDriverPoweredOn else {
            log("Cannot reconnect: Bluetooth not powered on")
            return
        }
        guard !hasActiveBLESession else {
            log("Skipping reconnect: connection already active")
            return
        }

        guard let uuid = lastConnectedPeripheralIdentifier else {
            log("No last connected device")
            reconcileScanning(reason: "no trusted Bike Computer saved")
            return
        }

#if HOST_TESTING
        reconcileScanning(reason: "test trusted Bike Computer reconnect")
        return
#else
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        
        if let peripheral = peripherals.first {
            log("Attempting to reconnect to last device: \(peripheral.name ?? "Unknown")")
            connectToPeripheral(peripheral)
        } else {
            log("Last device not found, starting scan")
            reconcileScanning(reason: "trusted Bike Computer not cached")
        }
#endif
    }
    
    // MARK: - Private Methods
    
    private func connectToPeripheral(_ peripheral: CBPeripheral) {
        guard watchDirectRidePreparedDeviceID == nil else {
            stopPhysicalScan(reason: "Apple Watch direct ride owns BLE")
            log("Skipping connection while Apple Watch direct ride is active")
            return
        }
        guard !hasActiveBLESession else {
            log("Skipping connect: connection already active")
            return
        }

        stopPhysicalScan(reason: "connection attempt starting")
        connectedPeripheral = peripheral
        connectedDeviceID = nil
        navigationCharacteristic = nil
        authCharacteristic = nil
        routeGeometryCharacteristic = nil
        gpsPositionCharacteristic = nil
        settingsCharacteristic = nil
        workoutTelemetryCharacteristic = nil
        rideAutomationCharacteristic = nil
        navigationWriteEndpoint = nil
        isNavigationReady = false
        clearTransferState()
        deviceHasSDCard = nil
        deviceMapFoundForCurrentLocation = nil
        deviceMapBlockCount = 0
        pendingAuthNonce = nil
        authFlowState = .idle
        authenticatedWriteSession = nil
        ownerAuthenticationUsesProvisionalKey = false
        authWriteInFlight = false
        queuedAuthMessages.removeAll()
        authInfoFallbackTimer?.invalidate()
        authInfoFallbackTimer = nil
        authInfoAttempts = 0
        deviceOperationTimeoutTimer?.invalidate()
        deviceOperationTimeoutTimer = nil
        resetNavigationWriteResponseWait()
        navigationWriteQueue.removeAll()
        lastSentPhoneBatteryPercent = nil
        lastSentPhoneBatteryCharging = nil
        authRetryTimer?.invalidate()
        authRetryTimer = nil
        authTimeoutTimer?.invalidate()
        authTimeoutTimer = nil
        peripheral.delegate = self
        isConnecting = true
        centralManager.connect(peripheral, options: nil)
        log("Connecting to: \(peripheral.name ?? "Unknown")")
        if BLEConnectionPersistence.shouldCancelTimedOutConnection(
            isPairing: pendingPairingSession != nil
        ) {
            startConnectionTimeout(for: peripheral)
        }
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

            self.log("BLE connection timed out")
            if self.pendingPairingSession != nil {
                self.pairingError = "Could not connect to that Bike Computer."
                self.suppressNextReconnect = true
            }
            self.centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    private func clearConnectionState() {
        isConnected = false
        isConnecting = false
        supportsDeviceSettings = false
        connectedPeripheral = nil
        connectedDeviceID = nil
        navigationCharacteristic = nil
        authCharacteristic = nil
        routeGeometryCharacteristic = nil
        gpsPositionCharacteristic = nil
        settingsCharacteristic = nil
        workoutTelemetryCharacteristic = nil
        rideAutomationCharacteristic = nil
        navigationWriteEndpoint = nil
        isNavigationReady = false
        resetNavigationWriteResponseWait()
        pendingAuthNonce = nil
        authFlowState = .idle
        authenticatedWriteSession = nil
        ownerAuthenticationUsesProvisionalKey = false
        authWriteInFlight = false
        queuedAuthMessages.removeAll()
        authInfoFallbackTimer?.invalidate()
        authInfoFallbackTimer = nil
        authInfoAttempts = 0
        deviceOperationTimeoutTimer?.invalidate()
        deviceOperationTimeoutTimer = nil
        navigationWriteQueue.removeAll()
        lastSentPhoneBatteryPercent = nil
        lastSentPhoneBatteryCharging = nil
        navigationFlushRetryTimer?.invalidate()
        navigationFlushRetryTimer = nil
        lastNavigationQueuePendingLogAt = .distantPast
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        authRetryTimer?.invalidate()
        authRetryTimer = nil
        authTimeoutTimer?.invalidate()
        authTimeoutTimer = nil
        if pendingRenameDeviceID != nil || pendingDeregistrationDeviceID != nil {
            pendingRenameDeviceID = nil
            pendingDeregistrationDeviceID = nil
            deviceOperationDeviceID = nil
            pairingStatusMessage = nil
            pairingError = "The Bike Computer disconnected before confirming the change. Reconnect to verify and try again if needed."
            autoReconnect = true
        }
        clearTransferState()
        stopMonitoringRSSI()
    }

    private func clearTransferState() {
        mapTransferModeEnabled = false
        mapTransferBaseURL = nil
        mapTransferAccessPointSSID = nil
        mapTransferActiveMapId = ""
        mapTransferActiveSessionId = ""
        activeMapManifestReceipt = ""
        activeMapRendererFormat = nil
        activeMapLabelProfileVersion = nil
        activeMapLabelLanguages = []
        activeMapFontAssetHealthy = false
        mapTransferActivationStatus = "idle"
        mapTransferActivationSequence = nil
        mapTransferActivationSessionId = ""
        mapTransferActivationMapId = ""
        mapTransferActivationStep = nil
        mapTransferActivationStepCount = nil
        mapTransferActivationProgress = nil
        mapTransferActivationError = nil
        mapTransferLastError = nil
        mapTransferStatusDescription = "unknown"
        mapTransferStatusChunkTransferID = nil
        mapTransferStatusChunkCount = 0
        mapTransferStatusChunks.removeAll()
        deviceTransferStatusChunkTransferID = nil
        deviceTransferStatusChunkCount = 0
        deviceTransferStatusChunks.removeAll()
        deviceTransferMode = ""
        deviceTransferBaseURL = nil
        deviceTransferAccessPointSSID = nil
        deviceTransferSessionToken = nil
        deviceTransferLastErrorCode = nil
        deviceTransferLastErrorMessage = nil
        deviceTransferStatusRevision = 0
        firmwareUpdateStatus = "unknown"
        firmwareTarget = ""
        firmwareVersion = ""
        firmwareBuild = 0
        firmwareGitSha = ""
        firmwareUpdateReceivedBytes = 0
        firmwareUpdateTotalBytes = 0
        firmwareUpdateLastError = nil
        supportsDeviceSounds = false
        supportsPowerButtonHonk = false
        supportsPowerButtonHonkAcknowledgement = false
        supportsIndependentMapProfiles = false
        supportsExtendedMapVisibility = false
        supportsBirdsEyeMapNavigation = false
        supportsBirdsEyeMapNavigationPerspective = false
        supportsBirdsEyeMapNavigationStrongerPerspective = false
        supportsBatteryStatusScreen = false
        supportsDestinationPicker = false
        supportsStreetLabels = false
        supports3DBuildings = false
        supportsRideAutomation = false
        supportsExplicitInvalidGPSHeading = false
        supportsScopedWatchController = false
        watchControllerIDHex = nil
        hasReceivedWatchControllerStatus = false
        isWatchControllerPromotionInFlight = false
        pendingWatchControllerOperation = nil
        watchControllerOperationStatus = nil
        updateWorkoutTelemetryCapability(false)
        powerButtonHonkConfigurationError = nil
        nextDestinationCatalogTransferID = 1
        destinationStatusSequence &+= 1
        hasReceivedDeviceCapabilities = false
        hasSentMapProfileForConnection = false
        hasSentMapNavigationProfileForConnection = false
        hasSentScreenSettingsForConnection = false
        isSendingNegotiatedMapProfiles = false
        clearPendingPowerButtonHonkConfiguration()
    }

    private func updateTrustedPeripheralDescription() {
        if let activeDeviceID,
           let active = knownDevices.first(where: { $0.deviceID == activeDeviceID }) {
            trustedPeripheralDescription = "\(active.name) (\(active.shortIdentifier))"
        } else {
            trustedPeripheralDescription = lastConnectedPeripheralIdentifier?.uuidString ?? "none"
        }
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

    func installNavigationWriteEndpoint(_ endpoint: NavigationWriteEndpoint?) {
        navigationWriteEndpoint = endpoint
    }

#if HOST_TESTING
    func installWorkoutTelemetryWriteEndpoint(
        _ endpoint: WorkoutTelemetryWriteEndpoint?
    ) {
        workoutTelemetryWriteEndpointForTesting = endpoint
    }

    func installNavigationWriteQueueForTesting(
        maxCount: Int,
        priorityMaxCount: Int = 6
    ) {
        navigationWriteQueue = NavigationWriteQueue(
            maxCount: maxCount,
            priorityMaxCount: priorityMaxCount
        )
    }

    func installNavigationWriteStallRecoveryForTesting(
        timeout: TimeInterval,
        recovery: @escaping () -> Void
    ) {
        navigationWriteResponseTimeout = timeout
        navigationWriteStallRecoveryForTesting = recovery
    }

    @discardableResult
    func enqueueUnacknowledgedTransferWriteForTesting(
        _ data: Data,
        write: @escaping (Data) -> Void
    ) -> Bool {
        guard let endpoint = navigationWriteEndpoint else { return false }
        return enqueueNavigationWrite(
            data,
            endpoint: endpoint,
            label: "test unacknowledged transfer",
            writeClass: .transfer,
            coalescingKey: "test.transfer.control",
            prioritized: true,
            transportWrite: write,
            transportCanSend: { true },
            transportExpectsWriteResponse: false
        )
    }

    func sendInitialDeviceSettingsAfterAuthenticationForTesting() {
        sendInitialDeviceSettingsAfterAuthentication()
    }
#endif

    func installPowerButtonHonkRetryTiming(
        ackTimeout: TimeInterval,
        failureRetryDelay: TimeInterval
    ) {
        powerButtonHonkAckTimeout = max(0, ackTimeout)
        powerButtonHonkFailureRetryDelay = max(0, failureRetryDelay)
    }

#if HOST_TESTING
    func installPowerButtonHonkRetrySchedulerForTesting(
        _ scheduler: @escaping (TimeInterval, DispatchWorkItem) -> Void
    ) {
        powerButtonHonkRetryScheduler = scheduler
    }
#endif

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
                  !self.isNavigationReady else { return }
            self.log("BLE authentication timed out")
            if self.pendingPairingSession != nil {
                self.pairingError = "Pairing timed out. Bring the Bike Computer closer and try again."
            }
            self.centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    private func startPairingConfirmationTimeout(for peripheral: CBPeripheral) {
        authTimeoutTimer?.invalidate()
        authTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 115.0, repeats: false) { [weak self, weak peripheral] _ in
            guard let self,
                  let peripheral,
                  self.connectedPeripheral?.identifier == peripheral.identifier,
                  case .awaitingPairingConfirmation = self.authFlowState else { return }
            self.failAuthentication(
                "The pairing code expired. Start again to generate a new code.",
                peripheral: peripheral
            )
        }
    }

    private func beginAuthenticationIfReady(for peripheral: CBPeripheral, source: String = "discovery") {
        guard navigationCharacteristic != nil else {
            log("BLE auth not ready from \(source): navigation characteristic missing")
            return
        }
        guard authCharacteristic != nil else {
            log("BLE auth not ready from \(source): auth characteristic missing")
            return
        }
        guard case .idle = authFlowState else { return }
        authFlowState = .waitingForInfo
        authInfoAttempts = 1
        enqueueAuthMessage("INFO")
        scheduleOwnershipInfoRetry(for: peripheral)
        log("Requested Bike Computer ownership information from \(source)")
    }

    private func scheduleOwnershipInfoRetry(for peripheral: CBPeripheral) {
        authInfoFallbackTimer?.invalidate()
        authInfoFallbackTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self, weak peripheral] _ in
            guard let self, let peripheral,
                  self.connectedPeripheral?.identifier == peripheral.identifier,
                  case .waitingForInfo = self.authFlowState else { return }
            if self.authInfoAttempts < 3 {
                self.authInfoAttempts += 1
                self.enqueueAuthMessage("INFO")
                self.scheduleOwnershipInfoRetry(for: peripheral)
                return
            }
            let knownDevice = self.deviceRegistry.devices.first {
                $0.peripheralIdentifier == peripheral.identifier
            }
            let observedCandidate = self.pendingPairingCandidate ??
                self.discoveredDevices.first {
                    $0.peripheralIdentifier == peripheral.identifier
                }
            if DeviceOwnershipFlowPolicy.allowsLegacyFallback(
                knownDevice: knownDevice,
                pairingCandidate: observedCandidate
            ) {
                self.beginLegacyAuthentication()
            } else {
                self.failAuthentication(
                    "The Bike Computer did not return its secure identity. Reconnect and try again.",
                    peripheral: peripheral
                )
            }
        }
    }

    private func preferredWriteType(
        for characteristic: CBCharacteristic
    ) -> CBCharacteristicWriteType? {
        if characteristic.properties.contains(.write) { return .withResponse }
        if characteristic.properties.contains(.writeWithoutResponse) { return .withoutResponse }
        return nil
    }

    private func authWriteLabel(_ type: CBCharacteristicWriteType) -> String {
        type == .withResponse ? "withResponse" : "withoutResponse"
    }

    private func handleAuthResponse(_ data: Data, peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let responseData: Data
        if data.count >= 2, data[0] == 0x52, data[1] == 0x32 {
            guard let authenticatedWriteSession,
                  let plaintext = authenticatedWriteSession.notificationPayload(
                    from: data,
                    channel: .auth
                  ) else {
                log("Rejected invalid protected ownership response")
                return
            }
            responseData = plaintext
        } else {
            if authenticatedWriteSession != nil {
                log("Rejected unauthenticated ownership response")
                return
            }
            responseData = data
        }
        guard let message = BLEPairingAuthenticator.authMessage(from: responseData) else {
            log("Received undecodable BLE auth response: \(data.count) bytes hex=\(data.hexPreview)")
            return
        }
        log("Received BLE auth response: \(message.prefix(16))... (\(data.count) bytes)")

        if message == "LOCKED" { return }
        if message.hasPrefix("DEVICE|") {
            handleDeviceInformation(message, peripheral: peripheral)
            return
        }
        if message.hasPrefix("PAIRING|") {
            guard let session = pendingPairingSession,
                  session.matches(peripheralIdentifier: peripheral.identifier) else {
                failAuthentication("Received an unexpected pairing response.", peripheral: peripheral)
                return
            }
            do {
                let material = try session.material(from: message)
                if let candidate = pendingPairingCandidate,
                   let advertisedIdentitySuffix = candidate.identitySuffix,
                   String(material.deviceID.suffix(8)).uppercased() != advertisedIdentitySuffix.uppercased() {
                    failAuthentication("The Bike Computer identity did not match its nearby code.", peripheral: peripheral)
                    return
                }
                // Commit the credential before the physical confirmation can
                // commit ownership on the Bike Computer. This makes a lost
                // PAIRED notification recoverable on the next connection.
                guard deviceRegistry.saveProvisionalOwnerKey(
                    material.ownerKey,
                    deviceID: material.deviceID
                ) else {
                    failAuthentication("The secure owner credential could not be saved.", peripheral: peripheral)
                    return
                }
                pendingPairingMaterial = material
                guard ownershipLifecycle.markComparisonReady(
                    for: peripheral.identifier
                ) else {
                    failAuthentication(
                        "The secure-pairing response arrived outside the active registration.",
                        peripheral: peripheral
                    )
                    return
                }
                authFlowState = .awaitingPairingConfirmation
                startPairingConfirmationTimeout(for: peripheral)
                pairingPrompt = BikeComputerPairingPrompt(
                    peripheralIdentifier: peripheral.identifier,
                    deviceName: session.deviceName,
                    shortIdentifier: pendingPairingCandidate?.shortIdentifier ?? String(material.deviceID.suffix(4)).uppercased(),
                    comparisonCode: material.comparisonCode,
                    isReplacingExistingRegistration:
                        deviceRegistry.ownerKey(deviceID: material.deviceID) != nil
                )
                pairingStatusMessage = nil
            } catch {
                failAuthentication("The Bike Computer returned an invalid secure-pairing response.", peripheral: peripheral)
            }
            return
        }
        if message.hasPrefix("PAIRED|") {
            handlePairedResponse(message, peripheral: peripheral)
            return
        }
        if message.hasPrefix("PAIR_READY|") {
            let parts = message.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2,
                  let material = pendingPairingMaterial,
                  parts[1].lowercased() == material.deviceID else {
                failAuthentication("The physical pairing confirmation did not match this device.", peripheral: peripheral)
                return
            }
            isPairingConfirmedOnDevice = true
            pairingStatusMessage = "Confirm the matching code on this iPhone."
            return
        }
        if message.hasPrefix("SERVER2|") {
            handleOwnerServerProof(message, peripheral: peripheral)
            return
        }
        if message.hasPrefix("OK2|") {
            guard case .owner(let clientNonce, let serverNonce, let deviceID, _, let ownerKey) = authFlowState,
                  let serverNonce else {
                failAuthentication("Received an unexpected owner confirmation.", peripheral: peripheral)
                return
            }
            let parts = message.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, parts[1] == deviceID,
                  parts[2] == clientNonce, parts[3] == serverNonce else {
                failAuthentication("The owner confirmation did not match this connection.", peripheral: peripheral)
                return
            }
            authenticatedWriteSession = AuthenticatedBLEWriteSession(
                ownerKey: ownerKey,
                deviceID: deviceID,
                clientNonce: clientNonce,
                serverNonce: serverNonce
            )
            completeAuthentication(for: peripheral)
            return
        }
        if message.hasPrefix("NAME_OK|") {
            handleRenameResponse(message)
            return
        }
        if message.hasPrefix("NAME_INFO|") {
            handleDeviceNameResponse(message)
            return
        }
        if message.hasPrefix("UNPAIRED2|") {
            let parts = message.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4,
                  pendingDeregistrationDeviceID == parts[1],
                  verifyRevocationReceipt(parts: parts) else {
                log("Rejected invalid deregistration receipt")
                return
            }
            completeDeregistration(
                deviceID: parts[1],
                peripheral: peripheral
            )
            return
        }
        if message.hasPrefix("WCTRL_STAGED|") {
            handleWatchControllerStaged(message)
            return
        }
        if message.hasPrefix("WCTRL_COMMITTED|") {
            handleWatchControllerCommitted(message)
            return
        }
        if message.hasPrefix("WCTRL_REVOKED|") {
            handleWatchControllerRevoked(message)
            return
        }
        if message.hasPrefix("WCTRL_STATUS|") {
            handleWatchControllerStatus(message)
            return
        }
        if message.hasPrefix("OWNED|") || message.hasPrefix("DENIED|") {
            autoReconnect = false
            failAuthentication(
                "This Bike Computer belongs to another iPhone. Hold BOOT for 8 seconds to reset ownership.",
                peripheral: peripheral
            )
            return
        }
        if message.hasPrefix("ERROR|") {
            let detail = message.split(separator: "|", maxSplits: 1).last.map(String.init) ?? "unknown error"
            if pendingWatchControllerOperation != nil {
                failWatchControllerOperation(
                    "Bike Computer rejected the Apple Watch change: \(detail.replacingOccurrences(of: "_", with: " "))."
                )
                return
            }
            if pendingRenameDeviceID != nil {
                deviceOperationTimeoutTimer?.invalidate()
                deviceOperationTimeoutTimer = nil
                pendingRenameDeviceID = nil
                deviceOperationDeviceID = nil
                pairingStatusMessage = nil
                pairingError = "Could not rename the Bike Computer: \(detail.replacingOccurrences(of: "_", with: " "))."
                return
            }
            if pendingDeregistrationDeviceID != nil {
                deviceOperationTimeoutTimer?.invalidate()
                deviceOperationTimeoutTimer = nil
                pendingDeregistrationDeviceID = nil
                deviceOperationDeviceID = nil
                pairingStatusMessage = nil
                pairingError = "Could not deregister the Bike Computer: \(detail.replacingOccurrences(of: "_", with: " "))."
                autoReconnect = true
                return
            }
            if detail == "pairing_attempt_already_used" {
                failAuthentication(
                    "Cancel and add this Bike Computer again to start a new secure pairing attempt.",
                    peripheral: peripheral
                )
                return
            }
            failAuthentication(
                "Bike Computer pairing failed: \(detail.replacingOccurrences(of: "_", with: " ")).",
                peripheral: peripheral
            )
            return
        }
        if message.hasPrefix("SERVER|") {
            guard case .legacy(let nonce) = authFlowState,
                  BLEPairingAuthenticator.isValidServerResponse(message, nonce: nonce) else {
                failAuthentication("The Bike Computer failed authentication.", peripheral: peripheral)
                return
            }
            let proof = BLEPairingAuthenticator.clientProof(nonce: nonce)
            enqueueAuthMessage("CLIENT|\(nonce)|\(proof)")
            return
        }
        if case .legacy(let nonce) = authFlowState, message == "OK|\(nonce)" {
            completeAuthentication(for: peripheral)
            return
        }
        log("Ignoring unexpected BLE auth response: \(message.prefix(24))")
    }

    private func handleWatchControllerStaged(_ message: String) {
        let parts = message.split(
            separator: "|",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard parts.count == 3,
              case .staging(let credential) =
                pendingWatchControllerOperation,
              parts[1].lowercased() == credential.controllerIDHex,
              let challenge = Data(ownershipHex: parts[2]),
              challenge.count == 16,
              let watchConnectivityCoordinator else {
            failWatchControllerOperation(
                "The Bike Computer returned an invalid Apple Watch enrollment challenge."
            )
            return
        }
        let request = WatchControllerRequestV1(
            operation: .proveEnrollment,
            deviceID: credential.deviceID,
            controllerID: credential.controllerID,
            credential: credential,
            challenge: challenge
        )
        pendingWatchControllerOperation = .requestingProof(
            credential,
            challenge: challenge
        )
        watchControllerOperationStatus =
            "Confirming the credential with Apple Watch…"
        let callbackBox = WeakBLEManagerSendableBox(self)
        watchConnectivityCoordinator.sendWatchControllerRequest(request) {
            result in
            DispatchQueue.main.async {
                callbackBox.value?.receiveWatchControllerProof(
                    result,
                    requestID: request.requestID,
                    credential: credential,
                    challenge: challenge
                )
            }
        }
    }

    private func receiveWatchControllerProof(
        _ result: Result<
            WatchControllerResponseV1,
            PhoneWatchControllerTransportError
        >,
        requestID: UUID,
        credential: WatchControllerCredentialV1,
        challenge: Data
    ) {
        guard case .requestingProof(let pending, let pendingChallenge) =
                pendingWatchControllerOperation,
              pending == credential,
              pendingChallenge == challenge else {
            return
        }
        switch result {
        case .failure:
            failWatchControllerOperation(
                "Keep the unlocked Apple Watch nearby, open its Bicino app, and try again."
            )
        case .success(let response):
            guard response.requestID == requestID,
                  let suppliedProof = response.proof,
                  let expectedProof = try? WatchControllerCryptographyV1
                    .enrollmentProof(
                        credential: credential,
                        challenge: challenge
                    ),
                  suppliedProof == expectedProof else {
                failWatchControllerOperation(
                    "Apple Watch returned an invalid enrollment proof."
                )
                return
            }
            pendingWatchControllerOperation = .committing(credential)
            watchControllerOperationStatus =
                "Saving Apple Watch access on the Bike Computer…"
            enqueueAuthMessage(
                "WCTRL_COMMIT|\(credential.controllerIDHex)|\(challenge.ownershipHex)|\(suppliedProof.ownershipHex)"
            )
        }
    }

    private func handleWatchControllerCommitted(_ message: String) {
        let parts = message.split(
            separator: "|",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard parts.count == 2,
              case .committing(let credential) =
                pendingWatchControllerOperation,
              parts[1].lowercased() == credential.controllerIDHex else {
            failWatchControllerOperation(
                "The Bike Computer committed a different Apple Watch credential."
            )
            return
        }
        watchControllerIDHex = credential.controllerIDHex
        rememberWatchControllerID(
            credential.controllerID,
            deviceID: credential.deviceID
        )
        let request = WatchControllerRequestV1(
            operation: .promote,
            deviceID: credential.deviceID,
            controllerID: credential.controllerID
        )
        guard let watchConnectivityCoordinator else {
            pendingWatchControllerOperation = nil
            watchControllerOperationStatus = nil
            watchControllerOperationError =
                "Apple Watch access is saved on the Bike Computer. Open the Watch app while the iPhone is nearby to finish."
            return
        }
        watchControllerOperationStatus =
            "Finishing Apple Watch enrollment…"
        let callbackBox = WeakBLEManagerSendableBox(self)
        watchConnectivityCoordinator.sendWatchControllerRequest(request) {
            result in
            DispatchQueue.main.async {
                guard let self = callbackBox.value,
                      case .committing(let pending) =
                        self.pendingWatchControllerOperation,
                      pending == credential else { return }
                self.pendingWatchControllerOperation = nil
                self.watchControllerOperationStatus = nil
                switch result {
                case .success:
                    self.watchControllerOperationError = nil
                case .failure:
                    self.watchControllerOperationError =
                        "Apple Watch access is saved on the Bike Computer. Open the Watch app while the iPhone is nearby to finish."
                }
            }
        }
    }

    private func handleWatchControllerRevoked(_ message: String) {
        let parts = message.split(
            separator: "|",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard parts.count == 2,
              case .revoking(let deviceID, let controllerID) =
                pendingWatchControllerOperation,
              parts[1].lowercased() == controllerID.ownershipHex else {
            failWatchControllerOperation(
                "The Bike Computer revoked a different Apple Watch credential."
            )
            return
        }
        watchConnectivityCoordinator?.queueWatchControllerRevocation(
            WatchControllerRequestV1(
                operation: .revoke,
                deviceID: deviceID,
                controllerID: controllerID
            )
        )
        pendingWatchControllerOperation = nil
        watchControllerIDHex = nil
        rememberWatchControllerID(nil, deviceID: deviceID)
        watchControllerOperationStatus = nil
        watchControllerOperationError = nil
    }

    private func handleWatchControllerStatus(_ message: String) {
        let parts = message.split(
            separator: "|",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard parts.count == 2 else { return }
        if parts[1] == "none" {
            hasReceivedWatchControllerStatus = true
            isWatchControllerPromotionInFlight = false
            watchControllerIDHex = nil
            watchControllerOperationError = nil
            if let deviceID = connectedDeviceID {
                queueRememberedWatchControllerDeletion(deviceID: deviceID)
            }
            attemptAutomaticWatchControllerEnrollment()
            return
        }
        guard let controllerID = Data(ownershipHex: parts[1]),
              controllerID.count == 16,
              let deviceID = connectedDeviceID else {
            return
        }
        hasReceivedWatchControllerStatus = true
        watchControllerIDHex = controllerID.ownershipHex
        rememberWatchControllerID(controllerID, deviceID: deviceID)
        // Idempotently repairs an app termination or unreachable Watch between
        // the firmware commit and the Watch Keychain promotion.
        attemptWatchControllerPromotion()
    }

    private func failWatchControllerOperation(_ message: String) {
        pendingWatchControllerOperation = nil
        watchControllerOperationStatus = nil
        watchControllerOperationError = message
    }

    private func handleDeviceInformation(_ message: String, peripheral: CBPeripheral) {
        authInfoFallbackTimer?.invalidate()
        authInfoFallbackTimer = nil
        let parts = message.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard (parts.count == 5 || parts.count == 7), parts[1] == "2",
              let deviceID = Data(ownershipHex: parts[2]),
              deviceID.count == DeviceOwnershipProtocol.deviceIDLength,
              let nameData = Data(ownershipHex: parts[4]),
              let reportedName = String(data: nameData, encoding: .utf8) else {
            failAuthentication("The Bike Computer returned invalid identity information.", peripheral: peripheral)
            return
        }
        let deviceIDHex = parts[2].lowercased()
        let isClaimed = parts[3] == "1"
        let conflictingDeviceIDs = BLEIdentityObservationPolicy.conflictingDeviceIDs(
            knownDevices: knownDevices,
            peripheralIdentifier: peripheral.identifier,
            observedDeviceID: deviceIDHex
        )
        if !conflictingDeviceIDs.isEmpty {
            observedIdentityMismatchDeviceIDs.formUnion(conflictingDeviceIDs)
            log(
                "Observed Device \(String(deviceIDHex.suffix(8)).uppercased()) " +
                "on a peripheral saved with a different identity"
            )
        }
        let existingDevice = knownDevices.first(where: {
            $0.deviceID == deviceIDHex
        })
        let resolvedName = DeviceOwnershipProtocol.resolvedInfoName(
            reportedName: reportedName,
            isClaimed: isClaimed,
            existingName: existingDevice?.name,
            peripheralName: peripheral.name
        )
        connectedDeviceID = deviceIDHex
        peripheralName = resolvedName

        if parts.count == 7,
           verifyRevocationReceipt(parts: [
               "UNPAIRED2", deviceIDHex, parts[5], parts[6]
           ]) {
            // A retained receipt is signed by the superseded key. Once the
            // user has confirmed a replacement credential, recover that new
            // credential first; deleting it here would strand a device that
            // has already committed the replacement owner.
            if deviceRegistry.hasConfirmedReplacementCredential(
                deviceID: deviceIDHex
            ) {
                log("Ignoring a receipt for the superseded owner during confirmed replacement recovery")
            } else {
                guard deviceRegistry.remove(deviceID: deviceIDHex) else {
                    failAuthentication(
                        "The Bike Computer was deregistered, but its secure credential could not be removed from this iPhone. Try again.",
                        peripheral: peripheral
                    )
                    return
                }
                refreshKnownDevices()
                if pendingPairingSession == nil {
                    completeDeregistration(
                        deviceID: deviceIDHex,
                        peripheral: peripheral,
                        registryAlreadyRemoved: true
                    )
                    return
                }
            }
        }

        if let session = pendingPairingSession {
            guard session.matches(peripheralIdentifier: peripheral.identifier) else {
                failAuthentication("The pairing response came from a different Bike Computer.", peripheral: peripheral)
                return
            }
            guard !isClaimed else {
                if let credential = ownerCredential(deviceID: deviceIDHex),
                   let ownerID = deviceRegistry.installationOwnerID() {
                    ownerAuthenticationUsesProvisionalKey = credential.isProvisional
                    beginOwnerAuthentication(deviceID: deviceIDHex, ownerID: ownerID, ownerKey: credential.key)
                } else {
                    autoReconnect = false
                    failAuthentication("This Bike Computer is already registered to another iPhone.", peripheral: peripheral)
                }
                return
            }
            authFlowState = .pairing
            enqueueAuthMessage(session.pairingCommand)
            pairingStatusMessage = "Preparing secure comparison…"
            return
        }

        if isClaimed,
           let credential = ownerCredential(deviceID: deviceIDHex),
           let ownerID = deviceRegistry.installationOwnerID() {
            // INFO is plaintext discovery data. Do not mutate the trusted
            // registry until OWNER proof succeeds in completeAuthentication.
            ownerAuthenticationUsesProvisionalKey = credential.isProvisional
            beginOwnerAuthentication(deviceID: deviceIDHex, ownerID: ownerID, ownerKey: credential.key)
        } else if isClaimed {
            autoReconnect = false
            failAuthentication(
                "This Bike Computer belongs to another iPhone. Hold BOOT for 8 seconds to reset ownership.",
                peripheral: peripheral
            )
        } else {
            autoReconnect = false
            let shortIdentifier = String(deviceIDHex.suffix(4)).uppercased()
            let message = conflictingDeviceIDs.isEmpty
                ? "This Bike Computer is not registered yet. Add Device \(shortIdentifier) from Settings → Bike Computers."
                : "Saved registration does not match this hardware. Tap Add Bike Computer and choose Device \(shortIdentifier)."
            failAuthentication(message, peripheral: peripheral)
        }
    }

    private func handlePairedResponse(_ message: String, peripheral: CBPeripheral) {
        let parts = message.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let material = pendingPairingMaterial,
              let session = pendingPairingSession,
              session.matches(peripheralIdentifier: peripheral.identifier),
              parts[1].lowercased() == material.deviceID,
              let nameData = Data(ownershipHex: parts[2]),
              let name = String(data: nameData, encoding: .utf8),
              deviceRegistry.provisionalOwnerKey(deviceID: material.deviceID) == material.ownerKey,
              deviceRegistry.isProvisionalOwnerKeyConfirmed(deviceID: material.deviceID) else {
            failAuthentication("The provisional owner credential is unavailable.", peripheral: peripheral)
            return
        }
        // PAIRED is still pre-authentication. Keep the asserted identity and
        // name in memory until OWNER authentication proves possession of the
        // committed key; only then may this device alter the persistent
        // registry or active-device selection.
        connectedDeviceID = material.deviceID
        peripheralName = name
        pairingStatusMessage = "Finishing secure connection…"
        startAuthenticationTimeout(for: peripheral)
        // PAIRED is not authenticated. Keep the new key provisional until the
        // following OWNER/SERVER2/PROOF/OK2 exchange proves the hardware
        // committed the same credential.
        ownerAuthenticationUsesProvisionalKey = true
        beginOwnerAuthentication(
            deviceID: material.deviceID,
            ownerID: session.ownerID,
            ownerKey: material.ownerKey
        )
    }

    private func verifyRevocationReceipt(parts: [String]) -> Bool {
        guard parts.count == 4,
              parts[0] == "UNPAIRED2",
              Data(ownershipHex: parts[2])?.count == 16,
              Data(ownershipHex: parts[3])?.count == 32,
              let ownerID = deviceRegistry.installationOwnerID(),
              let ownerKey = deviceRegistry.ownerKey(deviceID: parts[1]) else {
            return false
        }
        return DeviceOwnerAuthenticator.isValidRevocationReceipt(
            suppliedProof: parts[3],
            key: ownerKey,
            deviceID: parts[1],
            ownerID: ownerID,
            nonce: parts[2]
        )
    }

    private func completeDeregistration(
        deviceID: String,
        peripheral: CBPeripheral,
        registryAlreadyRemoved: Bool = false
    ) {
        if !registryAlreadyRemoved && !deviceRegistry.remove(deviceID: deviceID) {
            deviceOperationTimeoutTimer?.invalidate()
            deviceOperationTimeoutTimer = nil
            pendingDeregistrationDeviceID = nil
            deviceOperationDeviceID = nil
            pairingStatusMessage = nil
            pairingError = "The Bike Computer was deregistered, but its secure credential could not be removed from this iPhone. Try removing it again."
            autoReconnect = false
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        deviceOperationTimeoutTimer?.invalidate()
        deviceOperationTimeoutTimer = nil
        pendingDeregistrationDeviceID = nil
        deviceOperationDeviceID = nil
        queueRememberedWatchControllerDeletion(deviceID: deviceID)
        connectedDeviceID = nil
        explicitDiscoveryRequested = false
        isExplicitDiscoveryPausedForCandidate = false
        isOpportunisticDiscoverySuppressed = true
        clearUnknownDiscoveryState()
        refreshKnownDevices()
        pairingError = nil
        pairingStatusMessage = "Bike Computer deregistered."
        if let successor = deviceRegistry.devices.first(where: {
            $0.deviceID == deviceRegistry.activeDeviceID
        }) {
            pendingConnectionAfterDisconnect = successor.peripheralIdentifier
            autoReconnect = true
        } else {
            autoReconnect = false
        }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    private func beginOwnerAuthentication(deviceID: String, ownerID: Data, ownerKey: Data) {
        guard let nonce = BLEPairingAuthenticator.makeNonce() else { return }
        authenticatedWriteSession = nil
        pendingAuthNonce = nonce
        authFlowState = .owner(clientNonce: nonce, serverNonce: nil, deviceID: deviceID, ownerID: ownerID, ownerKey: ownerKey)
        enqueueAuthMessage("OWNER|\(ownerID.ownershipHex)|\(nonce)")
    }

    private func ownerCredential(deviceID: String) -> (key: Data, isProvisional: Bool)? {
        if deviceRegistry.isProvisionalOwnerKeyConfirmed(deviceID: deviceID),
           let key = deviceRegistry.provisionalOwnerKey(deviceID: deviceID) {
            return (key, true)
        }
        if let key = deviceRegistry.ownerKey(deviceID: deviceID) {
            return (key, false)
        }
        return nil
    }

    private func handleOwnerServerProof(_ message: String, peripheral: CBPeripheral) {
        guard case .owner(let clientNonce, _, let deviceID, let ownerID, let ownerKey) = authFlowState else {
            failAuthentication("Received an unexpected owner challenge.", peripheral: peripheral)
            return
        }
        let parts = message.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5,
              parts[1] == deviceID,
              parts[2] == clientNonce,
              Data(ownershipHex: parts[3])?.count == 16 else {
            failAuthentication("The Bike Computer owner challenge was invalid.", peripheral: peripheral)
            return
        }
        let serverNonce = parts[3]
        let expected = DeviceOwnerAuthenticator.proof(
            key: ownerKey,
            message: DeviceOwnerAuthenticator.serverMessage(
                deviceID: deviceID,
                ownerID: ownerID,
                clientNonce: clientNonce,
                serverNonce: serverNonce
            )
        )
        guard DeviceOwnerAuthenticator.isValidProof(parts[4], expected: expected) else {
            failAuthentication("The Bike Computer owner proof was invalid.", peripheral: peripheral)
            return
        }
        let clientProof = DeviceOwnerAuthenticator.proof(
            key: ownerKey,
            message: DeviceOwnerAuthenticator.clientMessage(
                deviceID: deviceID,
                ownerID: ownerID,
                clientNonce: clientNonce,
                serverNonce: serverNonce
            )
        )
        authFlowState = .owner(
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            deviceID: deviceID,
            ownerID: ownerID,
            ownerKey: ownerKey
        )
        enqueueAuthMessage("PROOF|\(ownerID.ownershipHex)|\(clientNonce)|\(serverNonce)|\(clientProof)")
    }

    private func beginLegacyAuthentication() {
        guard let nonce = BLEPairingAuthenticator.makeNonce() else { return }
        pendingAuthNonce = nonce
        authFlowState = .legacy(nonce: nonce)
        enqueueAuthMessage("HELLO|\(nonce)")
        log("Ownership protocol unavailable; trying legacy authentication")
    }

    private func enqueueAuthMessage(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        queuedAuthMessages.append(data)
        flushAuthMessageQueue()
    }

    private func flushAuthMessageQueue() {
        guard !authWriteInFlight,
              !queuedAuthMessages.isEmpty,
              let peripheral = connectedPeripheral,
              let authCharacteristic,
              let writeType = preferredWriteType(for: authCharacteristic) else { return }
        let message = queuedAuthMessages.removeFirst()
        let data: Data
        if let authenticatedWriteSession {
            guard let frame = authenticatedWriteSession.frame(
                payload: message,
                channel: .auth
            ) else {
                failAuthentication("Could not protect the ownership command.", peripheral: peripheral)
                return
            }
            data = frame
        } else {
            data = message
        }
        authWriteInFlight = writeType == .withResponse
        peripheral.writeValue(data, for: authCharacteristic, type: writeType)
        log("Sent ownership command via \(authWriteLabel(writeType))")
        if writeType == .withoutResponse { flushAuthMessageQueue() }
    }

    private func authWriteCompleted(error: Error?, peripheral: CBPeripheral) {
        authWriteInFlight = false
        if let error {
            failAuthentication("Could not send secure ownership data: \(error.localizedDescription)", peripheral: peripheral)
            return
        }
        flushAuthMessageQueue()
    }

    private func failAuthentication(_ message: String, peripheral: CBPeripheral) {
        pairingError = message
        pairingStatusMessage = nil
        pairingPrompt = nil
        isPairingConfirmedOnDevice = false
        isPairingConfirmationSubmitting = false
        authInfoFallbackTimer?.invalidate()
        authInfoFallbackTimer = nil
        log("BLE auth failed: \(message)")
        suppressNextReconnect = pendingPairingSession != nil
        centralManager.cancelPeripheralConnection(peripheral)
    }

    private func handleRenameResponse(_ message: String) {
        guard let deviceID = pendingRenameDeviceID else { return }
        let parts = message.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              let nameData = Data(ownershipHex: parts[1]),
              let name = String(data: nameData, encoding: .utf8),
              var device = knownDevices.first(where: { $0.deviceID == deviceID }) else { return }
        device.name = name
        deviceRegistry.upsert(device)
        deviceOperationTimeoutTimer?.invalidate()
        deviceOperationTimeoutTimer = nil
        pendingRenameDeviceID = nil
        deviceOperationDeviceID = nil
        peripheralName = name
        pairingStatusMessage = nil
        pairingError = nil
        refreshKnownDevices()
    }

    private func handleDeviceNameResponse(_ message: String) {
        let parts = message.split(
            separator: "|",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard parts.count == 2,
              let nameData = Data(ownershipHex: parts[1]),
              let name = String(data: nameData, encoding: .utf8),
              DeviceOwnershipProtocol.normalizedName(name) == name,
              let deviceID = connectedDeviceID,
              var device = knownDevices.first(where: {
                  $0.deviceID == deviceID
              }) else {
            return
        }
        device.name = name
        deviceRegistry.upsert(device)
        peripheralName = name
        refreshKnownDevices()
    }

    private func completeAuthentication(for peripheral: CBPeripheral) {
        guard let characteristic = navigationCharacteristic,
              let navigationWriteType = preferredWriteType(for: characteristic) else {
            log("Navigation characteristic is not writable after authentication")
            return
        }

        let transportMaximum = peripheral.maximumWriteValueLength(for: navigationWriteType)
        let payloadMaximum = max(
            0,
            transportMaximum - (authenticatedWriteSession == nil
                ? 0
                : AuthenticatedBLEWriteSession.frameOverhead)
        )
        guard payloadMaximum > 0 else {
            failAuthentication("The BLE connection is too small for protected device commands.", peripheral: peripheral)
            return
        }
        installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: payloadMaximum,
            expectsWriteResponse: navigationWriteType == .withResponse,
            canSend: { [weak self, weak peripheral] in
                guard let self, let peripheral else { return false }
                return navigationWriteType == .withResponse
                    ? !self.writeWithResponseInFlight
                    : peripheral.canSendWriteWithoutResponse
            },
            write: { [weak self, weak peripheral, weak characteristic] data in
                guard let self, let peripheral, let characteristic else { return }
                self.writeDeviceData(data, to: characteristic, on: peripheral, type: navigationWriteType)
            }
        ))

        pendingAuthNonce = nil
        authFlowState = .authenticated
        authWriteInFlight = false
        queuedAuthMessages.removeAll()
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

        if let connectedDeviceID {
            if ownerAuthenticationUsesProvisionalKey,
               !deviceRegistry.promoteProvisionalOwnerKey(
                    deviceID: connectedDeviceID,
                    allowReplacingExisting:
                        deviceRegistry
                            .isProvisionalCredentialReplacementAuthorized(
                                deviceID: connectedDeviceID
                            )
               ) {
                failAuthentication("The recovered owner credential could not be finalized.", peripheral: peripheral)
                return
            }
            ownerAuthenticationUsesProvisionalKey = false
            var device = knownDevices.first(where: { $0.deviceID == connectedDeviceID })
                ?? KnownBikeComputerDevice(
                    deviceID: connectedDeviceID,
                    peripheralIdentifier: peripheral.identifier,
                    name: peripheralName.isEmpty ? DeviceOwnershipProtocol.defaultDeviceName : peripheralName,
                    lastConnectedAt: Date(),
                    isLegacy: connectedDeviceID.hasPrefix("legacy:")
                )
            device.peripheralIdentifier = peripheral.identifier
            device.lastConnectedAt = Date()
            deviceRegistry.upsert(
                device,
                makeActive: pendingPairingSession != nil ||
                    deviceRegistry.activeDeviceID == nil
            )
        } else if connectedDeviceID == nil {
            let legacyID = "legacy:\(peripheral.identifier.uuidString.lowercased())"
            connectedDeviceID = legacyID
            deviceRegistry.upsert(KnownBikeComputerDevice(
                deviceID: legacyID,
                peripheralIdentifier: peripheral.identifier,
                name: peripheralName.isEmpty ? DeviceOwnershipProtocol.defaultDeviceName : peripheralName,
                lastConnectedAt: Date(),
                isLegacy: true
            ), makeActive: pendingPairingSession != nil || knownDevices.isEmpty)
        }
        let completedPairing = pendingPairingSession != nil
        explicitDiscoveryRequested = false
        isExplicitDiscoveryPausedForCandidate = false
        pairingDiscoveryOrigin = nil
        isOpportunisticDiscoverySuppressed = true
        clearUnknownDiscoveryState()
        refreshKnownDevices()
        pairingPrompt = nil
        isPairingConfirmedOnDevice = false
        isPairingConfirmationSubmitting = false
        pairingStatusMessage = nil
        pairingError = nil
        if completedPairing {
            completedPairingGeneration &+= 1
        }
        pendingPairingSession = nil
        ownershipLifecycle.complete()
        pendingPairingMaterial = nil
        pendingPairingCandidate = nil
        autoReconnect = true
        reconcileScanning(reason: "authentication completed")
        log("BLE peripheral authenticated")
        enqueueAuthMessage("GET_NAME")
        requestDeviceCapabilities()
        sendInitialDeviceSettingsAfterAuthentication()
        requestDeviceTransferStatus()
        requestMapTransferStatus()
    }

    private func sendInitialDeviceSettingsAfterAuthentication() {
        sendSetting(id: 6, value: Int32(mapRotationMode))
        sendSetting(id: 11, value: tapToSwitchScreens ? 1 : 0)
        sendSetting(
            id: DeviceBLEProtocol.brightnessSettingID,
            value: Int32(deviceBrightnessPercent)
        )
        sendSetting(
            id: DeviceBLEProtocol.disconnectedSleepTimeoutSettingID,
            value: disconnectedSleepTimeout.settingValue
        )
    }

    @discardableResult
    private func enqueueNavigationWrite(
        _ data: Data,
        endpoint: NavigationWriteEndpoint,
        label: String,
        writeClass: NavigationWriteClass = .other,
        coalescingKey: String? = nil,
        prioritized: Bool = false,
        atomically: Bool = false,
        transportWrite: ((Data) -> Void)? = nil,
        transportCanSend: (() -> Bool)? = nil,
        transportExpectsWriteResponse: Bool? = nil,
        onWrite: (() -> Void)? = nil,
        onDrop: (() -> Void)? = nil,
        onWriteFailure: (() -> Void)? = nil
    ) -> Bool {
        let write = NavigationWrite(
            data: data,
            label: label,
            transportWrite: transportWrite,
            onWrite: onWrite,
            onDrop: onDrop,
            onWriteFailure: onWriteFailure,
            transportCanSend: transportCanSend,
            transportExpectsWriteResponse: transportExpectsWriteResponse,
            writeClass: writeClass,
            coalescingKey: coalescingKey
        )
        let didEnqueue: Bool
        if coalescingKey != nil {
            didEnqueue = navigationWriteQueue.enqueueCoalescing(
                write,
                prioritized: prioritized
            )
        } else if prioritized {
            didEnqueue = navigationWriteQueue.enqueuePrioritizedAtomically([write])
        } else if atomically {
            didEnqueue = navigationWriteQueue.enqueueAtomically([write])
        } else {
            if navigationWriteQueue.enqueue(write) {
                log("Navigation write queue full; dropped oldest packet")
            }
            didEnqueue = true
        }
        guard didEnqueue else {
            return false
        }

        flushPendingNavigationWrites(endpoint: endpoint)
        scheduleNavigationFlushRetryIfNeeded()
        return true
    }

    @discardableResult
    private func enqueueDestinationFrames(
        _ frames: [Data],
        endpoint: NavigationWriteEndpoint,
        label: String,
        writeClass: NavigationWriteClass = .transfer,
        prioritized: Bool = false,
        coalescingKey: String? = nil,
        onWriteFailure: (() -> Void)? = nil
    ) -> Bool {
        guard !frames.isEmpty,
              frames.allSatisfy({ $0.count <= endpoint.maximumWriteLength }) else {
            return false
        }

        let peripheral = connectedPeripheral
        let characteristic = settingsCharacteristic
        let writes = frames.enumerated().map { index, frame in
            NavigationWrite(
                data: frame,
                label: "\(characteristic == nil ? "fallback" : "native") \(label) \(index + 1)/\(frames.count)",
                transportWrite: characteristic == nil ? nil : { [weak self, weak peripheral, weak characteristic] payload in
                    guard let self, let peripheral, let characteristic else { return }
                    self.writeDeviceData(payload, to: characteristic, on: peripheral)
                },
                onWriteFailure: onWriteFailure,
                writeClass: writeClass,
                coalescingKey: coalescingKey
            )
        }
        let didEnqueue: Bool
        if prioritized, writes.count == 1, coalescingKey != nil {
            didEnqueue = navigationWriteQueue.enqueueCoalescing(
                writes[0],
                prioritized: true
            )
        } else if prioritized {
            didEnqueue = navigationWriteQueue.enqueuePrioritizedAtomically(writes)
        } else {
            didEnqueue = navigationWriteQueue.enqueueAtomically(writes)
        }
        guard didEnqueue else {
            log("Destination frames not queued: insufficient write queue capacity")
            return false
        }
        flushPendingNavigationWrites(endpoint: endpoint)
        scheduleNavigationFlushRetryIfNeeded()
        log("Queued \(frames.count) \(label) frame(s)")
        return true
    }

    @discardableResult
    private func sendFallbackMapPacket(
        _ data: Data,
        label: String,
        writeClass: NavigationWriteClass = .settingsControl,
        coalescingKey: String? = nil,
        prioritized: Bool = false,
        atomically: Bool = false,
        onWrite: (() -> Void)? = nil,
        onDrop: (() -> Void)? = nil
    ) -> Bool {
        guard let endpoint = navigationWriteEndpoint,
              isConnected,
              isNavigationReady else {
            log("Cannot send fallback \(label): navigation endpoint not ready")
            return false
        }

        guard enqueueNavigationWrite(
            data,
            endpoint: endpoint,
            label: "fallback \(label)",
            writeClass: writeClass,
            coalescingKey: coalescingKey,
            prioritized: prioritized,
            atomically: atomically,
            onWrite: onWrite,
            onDrop: onDrop
        ) else {
            log("Fallback \(label) not queued: write queue unavailable")
            return false
        }
        log("Queued fallback \(label): \(data.count) bytes")
        return true
    }

    @discardableResult
    private func sendTransferControlPacket(
        _ data: Data,
        label: String,
        coalescingKey: String
    ) -> Bool {
        DevicePacketRouting.sendPreferredThenFallback(
            preferred: {
                sendNativeMapTransferPacket(
                    data,
                    label: label,
                    writeClass: .transfer,
                    coalescingKey: coalescingKey,
                    prioritized: true
                )
            },
            fallback: {
                sendFallbackMapPacket(
                    data,
                    label: label,
                    writeClass: .transfer,
                    coalescingKey: coalescingKey,
                    prioritized: true
                )
            }
        )
    }

    @discardableResult
    private func sendNativeMapTransferPacket(
        _ data: Data,
        label: String,
        writeClass: NavigationWriteClass = .settingsControl,
        coalescingKey: String? = nil,
        prioritized: Bool = false
    ) -> Bool {
        guard isConnected,
              isNavigationReady,
              let peripheral = connectedPeripheral,
              let characteristic = settingsCharacteristic,
              let endpoint = navigationWriteEndpoint,
              let writeType = preferredWriteType(for: characteristic) else {
            return false
        }

        let protectedLength = data.count + (authenticatedWriteSession == nil
            ? 0
            : AuthenticatedBLEWriteSession.frameOverhead)
        guard data.count <= endpoint.maximumWriteLength,
              protectedLength <= peripheral.maximumWriteValueLength(
                for: writeType
              ) else { return false }
        let expectsWriteResponse = writeType == .withResponse

        guard enqueueNavigationWrite(
            data,
            endpoint: endpoint,
            label: "native \(label)",
            writeClass: writeClass,
            coalescingKey: coalescingKey,
            prioritized: prioritized,
            transportWrite: { [weak self, weak peripheral, weak characteristic] payload in
                guard let self, let peripheral, let characteristic else { return }
                self.writeDeviceData(
                    payload,
                    to: characteristic,
                    on: peripheral,
                    type: writeType
                )
            },
            transportCanSend: { [weak self, weak peripheral] in
                guard let self, let peripheral else { return false }
                return expectsWriteResponse
                    ? !self.writeWithResponseInFlight
                    : peripheral.canSendWriteWithoutResponse
            },
            transportExpectsWriteResponse: expectsWriteResponse
        ) else { return false }
        log("Queued native \(label): \(data.count) bytes")
        return true
    }

    func waitForNavigationWritesToDrain(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while navigationWriteQueue.count > 0 {
            if let endpoint = navigationWriteEndpoint {
                flushPendingNavigationWrites(endpoint: endpoint)
            }
            if navigationWriteQueue.count == 0 {
                return true
            }
            if Date() >= deadline {
                log("Navigation write queue did not drain before timeout")
                return false
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    private func flushPendingNavigationWrites(endpoint: NavigationWriteEndpoint) {
        var madeProgress = false
        navigationWriteQueue.flush(canSend: { [weak self] write in
            guard let self else { return false }
            let expectsWriteResponse = write.transportExpectsWriteResponse
                ?? endpoint.expectsWriteResponse
            if expectsWriteResponse && self.writeWithResponseInFlight {
                return false
            }
            return write.transportCanSend?() ?? endpoint.canSend()
        }, maxWrites: 1) { write in
            madeProgress = true
            let expectsWriteResponse = write.transportExpectsWriteResponse
                ?? endpoint.expectsWriteResponse
            if expectsWriteResponse {
                beginNavigationWriteResponseWait(for: write)
            }
            write.perform(using: endpoint.write)
            log("Sent \(write.label): \(write.data.count) bytes")
        }
        updateNavigationBackpressureWatchdog(
            madeProgress: madeProgress,
            hasPendingWrites: navigationWriteQueue.count > 0
        )
        if navigationWriteQueue.count == 0 {
            navigationFlushRetryTimer?.invalidate()
            navigationFlushRetryTimer = nil
            lastNavigationQueuePendingLogAt = .distantPast
        } else if Date().timeIntervalSince(lastNavigationQueuePendingLogAt) >= 1 {
            log("Navigation write queue pending: \(navigationWriteQueue.count)")
            lastNavigationQueuePendingLogAt = Date()
        }
    }

    private func logNavigationQueueMetricsInterval() {
#if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        let intervalMs = Int(
            max(0, (now - lastNavigationQueueMetricsUptime) * 1_000).rounded()
        )
        lastNavigationQueueMetricsUptime = now
        let metrics = navigationWriteQueue.snapshotMetricsAndReset()
        log(
            "PWRMET_IOS v=\(NavigationWriteQueueMetrics.schemaVersion) " +
            "intervalMs=\(intervalMs) " +
            "queue[depth=\(metrics.currentDepth) maxDepth=\(metrics.maxDepth) " +
            "oldestMs=\(metrics.oldestPendingAgeMs) retryAgeMs=\(metrics.retryAgeMs) " +
            "enqueued=\(metrics.enqueuedFrames) flushed=\(metrics.flushedFrames) " +
            "dropped=\(metrics.droppedFrames) rejected=\(metrics.rejectedFrames) " +
            "coalesced=\(metrics.coalescedFrames) cleared=\(metrics.clearedFrames) " +
            "retries=\(metrics.retrySchedules) " +
            "backpressure=\(metrics.backpressureStops) " +
            "class[gpsDrop=\(metrics.droppedFrames(for: .gpsPosition)) " +
            "gpsCoalesce=\(metrics.coalescedFrames(for: .gpsPosition)) " +
            "navDrop=\(metrics.droppedFrames(for: .navigationSnapshot)) " +
            "navCoalesce=\(metrics.coalescedFrames(for: .navigationSnapshot)) " +
            "routeDrop=\(metrics.droppedFrames(for: .route)) " +
            "settingsDrop=\(metrics.droppedFrames(for: .settingsControl)) " +
            "transferDrop=\(metrics.droppedFrames(for: .transfer)) " +
            "workoutDrop=\(metrics.droppedFrames(for: .workoutTelemetry)) " +
            "workoutCoalesce=\(metrics.coalescedFrames(for: .workoutTelemetry)) " +
            "otherDrop=\(metrics.droppedFrames(for: .other))]]"
        )
#endif
    }

    private func completeNavigationWrite(error: Error?) {
        let writeFailureHandler = navigationWriteWithResponseFailureHandler
        resetNavigationWriteResponseWait()
        if error != nil {
            writeFailureHandler?()
        }
        if isNavigationReady, let endpoint = navigationWriteEndpoint {
            flushPendingNavigationWrites(endpoint: endpoint)
            scheduleNavigationFlushRetryIfNeeded()
        }
    }

    private func beginNavigationWriteResponseWait(for write: NavigationWrite) {
        navigationBackpressureStartedAt = nil
        writeWithResponseInFlight = true
        navigationWriteWithResponseFailureHandler = write.onWriteFailure
        navigationWriteWithResponseLabel = write.label
        navigationWriteResponseGeneration &+= 1
        let generation = navigationWriteResponseGeneration
        navigationWriteResponseTimeoutTimer?.invalidate()
        navigationWriteResponseTimeoutTimer = Timer.scheduledTimer(
            withTimeInterval: navigationWriteResponseTimeout,
            repeats: false
        ) { [weak self] _ in
            guard let self,
                  self.writeWithResponseInFlight,
                  self.navigationWriteResponseGeneration == generation else {
                return
            }
            self.recoverFromNavigationWriteStall()
        }
    }

    private func resetNavigationWriteResponseWait() {
        navigationWriteResponseTimeoutTimer?.invalidate()
        navigationWriteResponseTimeoutTimer = nil
        navigationWriteResponseGeneration &+= 1
        writeWithResponseInFlight = false
        navigationWriteWithResponseFailureHandler = nil
        navigationWriteWithResponseLabel = nil
        navigationBackpressureStartedAt = nil
    }

    private func updateNavigationBackpressureWatchdog(
        madeProgress: Bool,
        hasPendingWrites: Bool
    ) {
        if madeProgress || !hasPendingWrites || writeWithResponseInFlight {
            navigationBackpressureStartedAt = nil
            return
        }

        let now = Date()
        guard let startedAt = navigationBackpressureStartedAt else {
            navigationBackpressureStartedAt = now
            return
        }
        guard now.timeIntervalSince(startedAt) >=
                navigationWriteResponseTimeout else {
            return
        }
        recoverFromNavigationBackpressure()
    }

    private func recoverFromNavigationBackpressure() {
        guard isNavigationReady else { return }
        log("BLE write-without-response backpressure timed out; reconnecting")
        navigationBackpressureStartedAt = nil
        navigationFlushRetryTimer?.invalidate()
        navigationFlushRetryTimer = nil
        isNavigationReady = false

        if let navigationWriteStallRecoveryForTesting {
            navigationWriteStallRecoveryForTesting()
            return
        }
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    private func recoverFromNavigationWriteStall() {
        guard writeWithResponseInFlight else { return }
        let label = navigationWriteWithResponseLabel ?? "unknown write"
        let failureHandler = navigationWriteWithResponseFailureHandler
        log("Acknowledged BLE write timed out: \(label); reconnecting")
        resetNavigationWriteResponseWait()
        navigationFlushRetryTimer?.invalidate()
        navigationFlushRetryTimer = nil
        isNavigationReady = false
        failureHandler?()

        if let navigationWriteStallRecoveryForTesting {
            navigationWriteStallRecoveryForTesting()
            return
        }
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

#if HOST_TESTING
    func completeNavigationWriteForTesting(error: Error?) {
        completeNavigationWrite(error: error)
    }
#endif

    private func writeDeviceData(
        _ data: Data,
        to characteristic: CBCharacteristic,
        on peripheral: CBPeripheral,
        type explicitType: CBCharacteristicWriteType? = nil
    ) {
        guard let writeType = explicitType ?? preferredWriteType(for: characteristic) else {
            log("Cannot write characteristic \(characteristic.uuid): unsupported properties")
            return
        }
        guard let payload = devicePayload(
            data,
            for: characteristic.uuid,
            authenticatedWriteSession: authenticatedWriteSession
        ) else {
            log("Cannot protect write for characteristic \(characteristic.uuid)")
            return
        }
        peripheral.writeValue(payload, for: characteristic, type: writeType)
    }

    private func devicePayload(
        _ data: Data,
        for uuid: CBUUID,
        authenticatedWriteSession: AuthenticatedBLEWriteSession?
    ) -> Data? {
        guard let authenticatedWriteSession else { return data }
        guard let channel = authenticatedChannel(for: uuid) else { return nil }
        return authenticatedWriteSession.frame(payload: data, channel: channel)
    }

    private func authenticatedChannel(for uuid: CBUUID) -> AuthenticatedBLEChannel? {
        if uuid == authCharacteristicUUID { return .auth }
        if uuid == characteristicUUID { return .navigation }
        if uuid == routeGeometryCharacteristicUUID { return .route }
        if uuid == gpsPositionCharacteristicUUID { return .gps }
        if uuid == settingsCharacteristicUUID { return .settings }
        if uuid == workoutTelemetryCharacteristicUUID { return .workout }
        if uuid == rideAutomationCharacteristicUUID { return .rideAutomation }
        return nil
    }

#if HOST_TESTING
    func devicePayloadForTesting(
        _ data: Data,
        for uuid: CBUUID,
        authenticatedWriteSession: AuthenticatedBLEWriteSession?
    ) -> Data? {
        devicePayload(
            data,
            for: uuid,
            authenticatedWriteSession: authenticatedWriteSession
        )
    }
#endif

    private func scheduleNavigationFlushRetryIfNeeded() {
        guard navigationWriteQueue.count > 0,
              navigationFlushRetryTimer == nil else { return }

        navigationFlushRetryTimer = Timer.scheduledTimer(withTimeInterval: 0.05,
                                                         repeats: false) { [weak self] _ in
            guard let self else { return }
            self.navigationFlushRetryTimer = nil
            guard self.isNavigationReady,
                  let endpoint = self.navigationWriteEndpoint else { return }
            self.flushPendingNavigationWrites(endpoint: endpoint)
            self.scheduleNavigationFlushRetryIfNeeded()
        }
        navigationWriteQueue.noteRetryScheduled()
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        // Core Bluetooth may restore a system-owned scan before this
        // instance's shadow state has observed it. Stop unconditionally at
        // the restoration boundary before accepting any connection.
        if central.isScanning {
            lastPhysicalScanStoppedAt = Date()
        }
        central.stopScan()
        stopPhysicalScan(reason: "CoreBluetooth state restoration boundary")
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey]
                as? [CBPeripheral],
              !peripherals.isEmpty else {
            log("CoreBluetooth restored without a Bike Computer peripheral")
            return
        }
        guard let selectedIdentifier = BLERestorationPolicy.selectedIdentifier(
            from: peripherals.map(\.identifier),
            trustedIdentifier: lastConnectedPeripheralIdentifier,
            isConnectionExclusiveOperationActive:
                watchDirectRidePreparedDeviceID != nil
        ), let restored = peripherals.first(where: {
            $0.identifier == selectedIdentifier
        }) else {
            log("Ignoring restored connection for a non-current Bike Computer")
            for peripheral in peripherals {
                central.cancelPeripheralConnection(peripheral)
            }
            return
        }
        clearUnknownDiscoveryState()
        isOpportunisticDiscoverySuppressed = true
        restored.delegate = self
        log("Restored Bike Computer connection state: \(restored.state.rawValue)")
        switch restored.state {
        case .connected:
            connectedPeripheral = restored
            isConnecting = false
            isConnected = false
            isNavigationReady = false
            peripheralName = restored.name ?? "BikeComputer"
            startMonitoringRSSI()
            startAuthenticationTimeout(for: restored)
            restored.discoverServices([serviceUUID, deviceInformationServiceUUID])
        case .connecting:
            connectedPeripheral = restored
            isConnecting = true
        case .disconnected:
            connectToPeripheral(restored)
        case .disconnecting:
            connectedPeripheral = restored
            pendingConnectionAfterDisconnect = restored.identifier
        @unknown default:
            connectedPeripheral = restored
            pendingConnectionAfterDisconnect = restored.identifier
        }
        let restoredIdentifiersToCancel = Set(
            BLERestorationPolicy.identifiersToCancel(
                from: peripherals.map(\.identifier),
                keeping: selectedIdentifier
            )
        )
        for peripheral in peripherals
        where restoredIdentifiersToCancel.contains(peripheral.identifier) {
            central.cancelPeripheralConnection(peripheral)
        }
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleCentralStateChange(central.state)
    }

    private func handleCentralStateChange(_ state: CBManagerState) {
        if state != .poweredOn {
            if isPureExplicitDiscoveryPhase {
                autoReconnect = false
                pairingStatusMessage = nil
                pairingError =
                    "Turn on Bluetooth to add a Bike Computer."
            } else {
                interruptPendingPairing("Pairing was interrupted because Bluetooth became unavailable. Start again when Bluetooth is on.")
                explicitDiscoveryRequested = false
                isExplicitDiscoveryPausedForCandidate = false
                isPairingMode = false
            }
            pendingConnectionAfterDisconnect = nil
            pendingScannedConnectionIdentifier = nil
            pendingScannedConnectionTimeoutTimer?.invalidate()
            pendingScannedConnectionTimeoutTimer = nil
            clearUnknownDiscoveryState(
                releasingUnpresentedCandidateSuppression: true
            )
            stopPhysicalScan(reason: "Bluetooth unavailable")
        }
        switch state {
        case .poweredOn:
            centralStateDescription = "powered on"
            log("Bluetooth powered on")
            // Attempt to reconnect to last device, or start scanning
            if watchDirectRidePreparedDeviceID != nil {
                stopPhysicalScan(
                    reason: "Apple Watch direct ride remains active"
                )
                log("Apple Watch direct ride owns BLE; reconnect deferred")
            } else if hasActiveBLESession {
                log("Using restored Bike Computer connection")
            } else if explicitDiscoveryRequested {
                autoReconnect = false
                if isPureExplicitDiscoveryPhase {
                    pairingError = nil
                }
                if isPureExplicitDiscoveryPhase &&
                    !isUnknownDeviceDiscoverySuspended {
                    pairingStatusMessage =
                        "Looking for nearby Bike Computers…"
                }
                reconcileScanning(
                    reason: "Bluetooth powered on for explicit discovery"
                )
            } else if lastConnectedPeripheralIdentifier != nil {
                reconnectToLastDevice()
            } else {
                reconcileScanning(reason: "Bluetooth powered on")
            }
            
        case .poweredOff:
            centralStateDescription = "powered off"
            log("Bluetooth powered off")
            stopPhysicalScan(reason: "Bluetooth powered off")
            clearConnectionState()
            resetReconnectionState()
            
        case .resetting:
            centralStateDescription = "resetting"
            log("Bluetooth resetting")
            stopPhysicalScan(reason: "Bluetooth resetting")
            clearConnectionState()
            
        case .unauthorized:
            centralStateDescription = "unauthorized"
            log("Bluetooth unauthorized")
            stopPhysicalScan(reason: "Bluetooth unauthorized")
            clearConnectionState()
            resetReconnectionState()
            
        case .unsupported:
            centralStateDescription = "unsupported"
            log("Bluetooth unsupported")
            stopPhysicalScan(reason: "Bluetooth unsupported")
            clearConnectionState()
            resetReconnectionState()
            
        case .unknown:
            centralStateDescription = "unknown"
            log("Bluetooth unknown state")
            stopPhysicalScan(reason: "Bluetooth state unknown")
            clearConnectionState()
            
        @unknown default:
            centralStateDescription = "unknown"
            log("Bluetooth unknown state")
            stopPhysicalScan(reason: "Bluetooth entered unknown state")
            clearConnectionState()
        }
    }
    
    func centralManager(_ central: CBCentralManager,
                       didDiscover peripheral: CBPeripheral,
                       advertisementData: [String : Any],
                       rssi RSSI: NSNumber) {
        guard isScanning, central.isScanning else {
            log("Ignoring discovery callback after scan stop")
            return
        }
        let purpose = currentScanPurpose
        let candidate = DiscoveredBikeComputerDevice.parse(
            peripheralIdentifier: peripheral.identifier,
            localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name,
            manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
            rssi: RSSI.intValue
        )
        if purpose.discoversUnknownDevices {
            guard let activeDiscoveryGeneration,
                  unknownScanObservationGate
                    .acceptsRepeatedObservation(
                        peripheralIdentifier: peripheral.identifier,
                        generation: activeDiscoveryGeneration
                    ) else {
                log(
                    "Waiting for a repeated Device " +
                    "\(candidate.shortIdentifier) observation in this scan"
                )
                return
            }
        }
        log(
            "Observed Device \(candidate.shortIdentifier) for " +
            "\(purpose.logDescription) " +
            "(RSSI: \(RSSI))"
        )

        switch purpose {
        case .selectedPeripheral(let pendingIdentifier):
            guard BLEPendingScanPolicy.accepts(
                discoveredIdentifier: peripheral.identifier,
                pendingIdentifier: pendingIdentifier
            ) else {
                log("Ignoring non-selected Bike Computer during selected-device scan")
                return
            }
            discoveredPeripherals[peripheral.identifier] = peripheral
            pendingScannedConnectionIdentifier = nil
            pendingScannedConnectionTimeoutTimer?.invalidate()
            pendingScannedConnectionTimeoutTimer = nil
            pairingStatusMessage = nil
            connectToPeripheral(peripheral)
        case .explicitDiscovery:
            discoveredPeripherals[peripheral.identifier] = peripheral
            if let index = discoveredDevices.firstIndex(where: {
                $0.id == candidate.id
            }) {
                discoveredDevices[index] = candidate
            } else {
                discoveredDevices.append(candidate)
            }
            discoveredDevices.sort { lhs, rhs in
                let lhsRank = BLEDiscoverySignalPolicy.rank(for: lhs.rssi)
                let rhsRank = BLEDiscoverySignalPolicy.rank(for: rhs.rssi)
                if lhsRank != rhsRank { return lhsRank > rhsRank }
                return lhs.peripheralIdentifier.uuidString <
                    rhs.peripheralIdentifier.uuidString
            }
            pairingStatusMessage = discoveredDevices.isEmpty ? "Looking for nearby Bike Computers…" : nil
        case .opportunisticDiscovery:
            guard let activeDiscoveryGeneration else {
                log("Ignoring opportunistic observation without an active generation")
                return
            }
            let observation = BLEDiscoveryObservation(
                device: candidate,
                generation: activeDiscoveryGeneration
            )
            guard BLEOpportunisticCandidatePolicy.isEligible(
                observation,
                activeGeneration: activeDiscoveryGeneration,
                knownDevices: knownDevices,
                // Core Bluetooth delivered this callback from the service-
                // filtered scan started by this manager.
                serviceMatched: true
            ) else {
                log("Device \(candidate.shortIdentifier) is not eligible for automatic setup")
                return
            }
            discoveredPeripherals[peripheral.identifier] = peripheral
            opportunisticObservations[peripheral.identifier] = observation
            scheduleOpportunisticCandidateSelection(
                generation: activeDiscoveryGeneration
            )
        case .trustedReconnect(let trustedIdentifier):
            guard peripheral.identifier == trustedIdentifier else {
                log("Ignoring non-current Bike Computer during trusted reconnect")
                return
            }
            connectToPeripheral(peripheral)
            signalStrength = RSSI.intValue
        case .none:
            log("Ignoring discovery callback without an active scan purpose")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard BLELocalForgetPolicy.acceptsCallback(
            peripheralIdentifier: peripheral.identifier,
            currentIdentifier: connectedPeripheral?.identifier,
            forgottenIdentifiers: locallyForgottenPeripheralIdentifiers
        ) else {
            log("Cancelling a late connection for a locally forgotten Bike Computer")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard connectedPeripheral?.identifier == peripheral.identifier else {
            log("Ignoring connection callback for a non-current Bike Computer")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard watchDirectRidePreparedDeviceID == nil else {
            log("Cancelling a late iPhone connection during Watch-direct handoff")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        stopPhysicalScan(reason: "Bike Computer connected")
        clearUnknownDiscoveryState(
            keepingCandidate: NearbyBicinoPresentationPolicy
                .shouldRetainCandidateDuringConnection(
                    discoveryOrigin: pairingDiscoveryOrigin,
                    hasPendingPairingSession: pendingPairingSession != nil
                )
        )
        log("Connected to: \(peripheral.name ?? "Unknown")")
        
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        isConnecting = false
        isConnected = false
        isNavigationReady = false
        lastSentPhoneBatteryPercent = nil
        lastSentPhoneBatteryCharging = nil
        peripheralName = peripheral.name ?? "BikeComputer"
        startMonitoringRSSI()
        startAuthenticationTimeout(for: peripheral)
        
        // Reset reconnection state on successful connection (Optimization #14)
        resetReconnectionState()
        
        // Discover services
        peripheral.discoverServices([serviceUUID, deviceInformationServiceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, 
                       didDisconnectPeripheral peripheral: CBPeripheral, 
                       error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else {
            log("Ignoring disconnect callback for a non-current Bike Computer")
            return
        }
        locallyForgottenPeripheralIdentifiers.remove(peripheral.identifier)
        log("Disconnected from: \(peripheral.name ?? "Unknown")")
        
        if let error = error {
            log("Disconnect error: \(error.localizedDescription)")
        }
        
        isConnected = false
        isConnecting = false
        supportsDeviceSettings = false
        hardwareLabel = ""
        deviceInformation.removeAll()
        connectedPeripheral = nil
        navigationCharacteristic = nil
        authCharacteristic = nil
        routeGeometryCharacteristic = nil
        gpsPositionCharacteristic = nil
        settingsCharacteristic = nil
        workoutTelemetryCharacteristic = nil
        rideAutomationCharacteristic = nil
        navigationWriteEndpoint = nil
        isNavigationReady = false
        clearTransferState()
        deviceHasSDCard = nil
        deviceMapFoundForCurrentLocation = nil
        deviceMapBlockCount = 0
        pendingAuthNonce = nil
        authFlowState = .idle
        authenticatedWriteSession = nil
        ownerAuthenticationUsesProvisionalKey = false
        authWriteInFlight = false
        queuedAuthMessages.removeAll()
        authInfoFallbackTimer?.invalidate()
        authInfoFallbackTimer = nil
        authInfoAttempts = 0
        deviceOperationTimeoutTimer?.invalidate()
        deviceOperationTimeoutTimer = nil
        resetNavigationWriteResponseWait()
        navigationWriteQueue.removeAll()
        lastSentPhoneBatteryPercent = nil
        lastSentPhoneBatteryCharging = nil
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        stopMonitoringRSSI()
        connectedDeviceID = nil

        if pendingRenameDeviceID != nil || pendingDeregistrationDeviceID != nil {
            pendingRenameDeviceID = nil
            pendingDeregistrationDeviceID = nil
            deviceOperationDeviceID = nil
            pairingStatusMessage = nil
            pairingError = "The Bike Computer disconnected before confirming the change. Reconnect to verify and try again if needed."
            autoReconnect = true
        }

        if let nextIdentifier = BLEPendingHandoffPolicy.consume(
            &pendingConnectionAfterDisconnect
        ) {
            connectDiscoveredPeripheral(identifier: nextIdentifier)
            return
        }

        if explicitDiscoveryRequested,
           pendingPairingSession == nil,
           isApplicationActive {
            pairingStatusMessage = "Looking for nearby Bike Computers…"
            reconcileScanning(
                reason: "confirmed disconnect completed before explicit discovery"
            )
            return
        }

        if pendingPairingSession != nil && pairingError == nil {
            pairingPrompt = nil
            isPairingConfirmedOnDevice = false
            pairingStatusMessage = nil
            pairingError = "Pairing was interrupted. Cancel and add the Bike Computer again."
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

        guard autoReconnect else { return }
        // Keep a CoreBluetooth operation active while the app is suspended;
        // run-loop timers alone cannot provide durable background reconnect.
        reconcileScanning(reason: "trusted reconnect backoff scheduled")
        let delay = BLEReconnectBackoff.delay(
            attempt: reconnectAttempts,
            base: baseReconnectDelay,
            maximum: maxReconnectDelay
        )
        reconnectAttempts = min(reconnectAttempts + 1, 30)
        
        log("Reconnection attempt \(reconnectAttempts) in \(String(format: "%.1f", delay))s")
        
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
        guard connectedPeripheral?.identifier == peripheral.identifier else {
            log("Ignoring connection failure for a non-current Bike Computer")
            return
        }
        locallyForgottenPeripheralIdentifiers.remove(peripheral.identifier)
        log("Failed to connect to: \(peripheral.name ?? "Unknown")")
        clearConnectionState()
        
        if let error = error {
            log("Connection error: \(error.localizedDescription)")
        }

        if let nextIdentifier = BLEPendingHandoffPolicy.consume(
            &pendingConnectionAfterDisconnect
        ) {
            connectDiscoveredPeripheral(identifier: nextIdentifier)
            return
        }

        if explicitDiscoveryRequested,
           pendingPairingSession == nil,
           isApplicationActive {
            reconcileScanning(
                reason: "connection failure returned to explicit discovery"
            )
            return
        }
        
        if pendingPairingSession != nil {
            pairingError = "Could not connect to that Bike Computer."
        } else if autoReconnect {
            scheduleReconnectWithBackoff()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard BLELocalForgetPolicy.acceptsCallback(
            peripheralIdentifier: peripheral.identifier,
            currentIdentifier: connectedPeripheral?.identifier,
            forgottenIdentifiers: locallyForgottenPeripheralIdentifiers
        ) else {
            return
        }
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
            if service.uuid == deviceInformationServiceUUID {
                log("Discovering Device Information characteristics")
                peripheral.discoverCharacteristics([
                    modelNumberCharacteristicUUID,
                    firmwareRevisionCharacteristicUUID,
                    hardwareRevisionCharacteristicUUID,
                    manufacturerNameCharacteristicUUID
                ], for: service)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didDiscoverCharacteristicsFor service: CBService, 
                   error: Error?) {
        guard BLELocalForgetPolicy.acceptsCallback(
            peripheralIdentifier: peripheral.identifier,
            currentIdentifier: connectedPeripheral?.identifier,
            forgottenIdentifiers: locallyForgottenPeripheralIdentifiers
        ) else {
            return
        }
        if let error = error {
            log("Error discovering characteristics: \(error.localizedDescription)")
            return
        }
        
        guard let characteristics = service.characteristics else { return }
        
        for characteristic in characteristics {
            log("Discovered characteristic: \(characteristic.uuid) props=\(characteristic.properties.debugDescription)")

            if service.uuid == deviceInformationServiceUUID,
               characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
                continue
            }
            
            if characteristic.uuid == characteristicUUID {
                guard preferredWriteType(for: characteristic) != nil else {
                    log("Navigation characteristic is not writable")
                    continue
                }

                navigationCharacteristic = characteristic
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
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
                guard preferredWriteType(for: characteristic) != nil else {
                    log("Route geometry characteristic is not writable")
                    continue
                }
                routeGeometryCharacteristic = characteristic
            }

            if characteristic.uuid == gpsPositionCharacteristicUUID {
                guard preferredWriteType(for: characteristic) != nil else {
                    log("GPS characteristic is not writable")
                    continue
                }
                gpsPositionCharacteristic = characteristic
            }

            if characteristic.uuid == settingsCharacteristicUUID {
                guard preferredWriteType(for: characteristic) != nil else {
                    log("Settings characteristic is not writable")
                    continue
                }
                settingsCharacteristic = characteristic
                supportsDeviceSettings = true
            }

            if characteristic.uuid == workoutTelemetryCharacteristicUUID {
                guard preferredWriteType(for: characteristic) != nil else {
                    log("Workout telemetry characteristic is not writable")
                    continue
                }
                workoutTelemetryCharacteristic = characteristic
            }

            if characteristic.uuid == rideAutomationCharacteristicUUID {
                guard preferredWriteType(for: characteristic) != nil else {
                    log("Ride automation characteristic is not writable")
                    continue
                }
                rideAutomationCharacteristic = characteristic
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                   didUpdateNotificationStateFor characteristic: CBCharacteristic,
                   error: Error?) {
        guard BLELocalForgetPolicy.acceptsCallback(
            peripheralIdentifier: peripheral.identifier,
            currentIdentifier: connectedPeripheral?.identifier,
            forgottenIdentifiers: locallyForgottenPeripheralIdentifiers
        ) else {
            return
        }
        if let error = error {
            log("Error updating notifications: \(error.localizedDescription)")
            return
        }

        if characteristic.uuid == authCharacteristicUUID {
            beginAuthenticationIfReady(for: peripheral, source: "notify enabled")
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard BLELocalForgetPolicy.acceptsCallback(
            peripheralIdentifier: peripheral.identifier,
            currentIdentifier: connectedPeripheral?.identifier,
            forgottenIdentifiers: locallyForgottenPeripheralIdentifiers
        ) else {
            return
        }
        guard isNavigationReady, let endpoint = navigationWriteEndpoint else { return }
        log("BLE transport ready; pending writes=\(navigationWriteQueue.count)")
        flushPendingNavigationWrites(endpoint: endpoint)
        scheduleNavigationFlushRetryIfNeeded()
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didWriteValueFor characteristic: CBCharacteristic, 
                   error: Error?) {
        guard BLELocalForgetPolicy.acceptsCallback(
            peripheralIdentifier: peripheral.identifier,
            currentIdentifier: connectedPeripheral?.identifier,
            forgottenIdentifiers: locallyForgottenPeripheralIdentifiers
        ) else {
            return
        }
        if let error = error {
            log("Error writing characteristic \(characteristic.uuid): \(error.localizedDescription); props=\(characteristic.properties.debugDescription)")
            if characteristic.uuid == authCharacteristicUUID {
                authWriteCompleted(error: error, peripheral: peripheral)
            } else {
                completeNavigationWrite(error: error)
            }
            return
        }

        if characteristic.uuid == authCharacteristicUUID {
            authWriteCompleted(error: nil, peripheral: peripheral)
        } else {
            completeNavigationWrite(error: nil)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didUpdateValueFor characteristic: CBCharacteristic, 
                   error: Error?) {
        guard BLELocalForgetPolicy.acceptsCallback(
            peripheralIdentifier: peripheral.identifier,
            currentIdentifier: connectedPeripheral?.identifier,
            forgottenIdentifiers: locallyForgottenPeripheralIdentifiers
        ) else {
            log("Ignored late value from a locally forgotten Bike Computer")
            return
        }
        if let error = error {
            log("Error reading characteristic: \(error.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value else { return }

        if characteristic.uuid == authCharacteristicUUID {
            handleAuthResponse(data, peripheral: peripheral, characteristic: characteristic)
            return
        }

        if characteristic.uuid == characteristicUUID {
            let isProtectedFrame = data.count >= 2 && data[0] == 0x52 && data[1] == 0x32
            let isAuthenticated: Bool
            if case .authenticated = authFlowState {
                isAuthenticated = true
            } else {
                isAuthenticated = false
            }
            guard BLENavigationNotificationPolicy.accepts(
                isAuthenticated: isAuthenticated,
                isLegacyDevice: connectedDeviceID?.hasPrefix("legacy:") == true,
                hasProtectedSession: authenticatedWriteSession != nil,
                isProtectedFrame: isProtectedFrame
            ) else {
                log("Rejected navigation notification outside its authenticated transport")
                return
            }
            let notificationData: Data
            if let authenticatedWriteSession {
                guard isProtectedFrame,
                      let plaintext = authenticatedWriteSession
                        .notificationPayload(
                            from: data,
                            channel: .navigation
                        ) else {
                    log("Rejected unauthenticated navigation notification")
                    return
                }
                notificationData = plaintext
            } else {
                notificationData = data
            }
            if handleNavigationCharacteristicNotification(notificationData) {
                return
            }
        }

        if characteristic.uuid == rideAutomationCharacteristicUUID {
            guard isNavigationReady,
                  supportsRideAutomation,
                  let authenticatedWriteSession,
                  let payload = authenticatedWriteSession.notificationPayload(
                    from: data,
                    channel: .rideAutomation
                  ),
                  let frame = RideAutomationFrame(payload) else {
                log("Rejected invalid or unauthenticated ride automation notification")
                return
            }
            onRideAutomationFrame?(frame)
            return
        }

        if [modelNumberCharacteristicUUID,
            firmwareRevisionCharacteristicUUID,
            hardwareRevisionCharacteristicUUID,
            manufacturerNameCharacteristicUUID].contains(characteristic.uuid),
           let value = String(data: data.trimmedTrailingNullsAndWhitespace, encoding: .utf8),
           !value.isEmpty {
            deviceInformation[characteristic.uuid] = value
            updateHardwareLabel()
            log("Device information \(characteristic.uuid): \(value)")
            return
        }
        
        if let string = String(data: data, encoding: .utf8) {
            log("Received from ESP32: \(string)")
        }
    }

    private func updateHardwareLabel() {
        hardwareLabel = DeviceBLEProtocol.hardwareLabel(
            model: deviceInformation[modelNumberCharacteristicUUID],
            hardware: deviceInformation[hardwareRevisionCharacteristicUUID]
        )
    }

    private func updateWorkoutTelemetryCapability(_ supported: Bool) {
        if !supported {
            // A capability downgrade is an authorization boundary for health
            // telemetry. Frames admitted while bit 7 was present must not
            // survive backpressure and transmit after that boundary changes.
            navigationWriteQueue.removePendingWrites(
                withCoalescingKey:
                    DeviceBLEProtocol.workoutTelemetryCoreCoalescingKey
            )
            navigationWriteQueue.removePendingWrites(
                withCoalescingKey:
                    DeviceBLEProtocol.workoutTelemetryExtendedCoalescingKey
            )
        }
        supportsWorkoutTelemetry = supported
    }

    private func rejectDeviceCapabilities(_ message: String) {
        supportsDeviceSounds = false
        supportsPowerButtonHonk = false
        supportsPowerButtonHonkAcknowledgement = false
        supportsIndependentMapProfiles = false
        supportsExtendedMapVisibility = false
        supportsBirdsEyeMapNavigation = false
        supportsBirdsEyeMapNavigationPerspective = false
        supportsBirdsEyeMapNavigationStrongerPerspective = false
        supportsBatteryStatusScreen = false
        supportsDestinationPicker = false
        supportsStreetLabels = false
        supports3DBuildings = false
        supportsRideAutomation = false
        supportsExplicitInvalidGPSHeading = false
        supportsScopedWatchController = false
        watchControllerIDHex = nil
        hasReceivedWatchControllerStatus = false
        isWatchControllerPromotionInFlight = false
        updateWorkoutTelemetryCapability(false)
        hasReceivedDeviceCapabilities = false
        hasSentScreenSettingsForConnection = false
        hasSentMapProfileForConnection = false
        hasSentMapNavigationProfileForConnection = false
        clearPendingPowerButtonHonkConfiguration()
        log(message)
    }

    @discardableResult
    func handleDeviceCapabilitiesNotification(_ data: Data) -> Bool {
        guard data.count >= 4,
              let prefix = String(data: data.prefix(4), encoding: .utf8),
              prefix == DeviceBLEProtocol.deviceCapabilitiesPrefix ||
                prefix == DeviceBLEProtocol.deviceCapabilitiesV2Prefix else {
            return false
        }

        let flags: UInt32
        let legacyExtendedFlags: UInt8
        let powerButtonConfig: Data?
        if prefix == DeviceBLEProtocol.deviceCapabilitiesPrefix {
            guard data.count == 5 || data.count == 6 ||
                    data.count == 8 || data.count == 9 else {
                rejectDeviceCapabilities("Received invalid device capabilities payload")
                return true
            }
            flags = UInt32(data[4])
            legacyExtendedFlags = data.count == 6
                ? data[5]
                : (data.count == 9 ? data[8] : 0)
            powerButtonConfig = data.count >= 8
                ? data.subdata(in: 5..<8)
                : nil
        } else {
            guard data.count >= 9, data[4] == 1 else {
                rejectDeviceCapabilities("Received invalid CAP2 header")
                return true
            }
            flags = UInt32(data[5]) |
                (UInt32(data[6]) << 8) |
                (UInt32(data[7]) << 16) |
                (UInt32(data[8]) << 24)
            var offset = 9
            var seenTypes = Set<UInt8>()
            var parsedPowerConfig: Data?
            var valid = true
            while offset < data.count {
                guard offset + 2 <= data.count else {
                    valid = false
                    break
                }
                let type = data[offset]
                let length = Int(data[offset + 1])
                offset += 2
                guard !seenTypes.contains(type), offset + length <= data.count else {
                    valid = false
                    break
                }
                seenTypes.insert(type)
                if type == 1 {
                    guard length == 3 else {
                        valid = false
                        break
                    }
                    parsedPowerConfig = data.subdata(in: offset..<(offset + length))
                }
                offset += length
            }
            guard valid, offset == data.count else {
                rejectDeviceCapabilities("Received invalid CAP2 TLV payload")
                return true
            }
            legacyExtendedFlags = 0
            powerButtonConfig = parsedPowerConfig
        }

        let legacyFlags = UInt8(truncatingIfNeeded: flags)
        let hasDeviceSounds = legacyFlags & DeviceBLEProtocol.deviceSoundsCapabilityMask != 0
        let hasPowerButtonHonk = hasDeviceSounds &&
            legacyFlags & DeviceBLEProtocol.powerButtonHonkCapabilityMask != 0
        let hasPowerButtonHonkAcknowledgement = hasPowerButtonHonk &&
            legacyFlags & DeviceBLEProtocol.powerButtonHonkAcknowledgementCapabilityMask != 0
        let hasIndependentMapProfiles =
            legacyFlags & DeviceBLEProtocol.independentMapProfilesCapabilityMask != 0
        let hasExtendedMapVisibility =
            legacyFlags & DeviceBLEProtocol.extendedMapVisibilityCapabilityMask != 0
        let hasBatteryStatusScreen =
            legacyFlags & DeviceBLEProtocol.batteryStatusScreenCapabilityMask != 0
        let hasDestinationPicker =
            legacyFlags & DeviceBLEProtocol.destinationPickerCapabilityMask != 0
        let hasWorkoutTelemetry =
            legacyFlags & DeviceBLEProtocol.workoutTelemetryCapabilityMask != 0
        let hasBirdsEyeMapNavigation =
            legacyExtendedFlags &
                DeviceBLEProtocol.birdsEyeMapNavigationExtendedCapabilityMask != 0 ||
            flags & DeviceBLEProtocol.birdsEyeMapNavigationCapabilityMask != 0
        let hasBirdsEyeMapNavigationPerspective =
            hasBirdsEyeMapNavigation &&
            (legacyExtendedFlags &
                DeviceBLEProtocol.birdsEyeMapNavigationPerspectiveExtendedCapabilityMask != 0 ||
             flags & DeviceBLEProtocol.birdsEyeMapNavigationPerspectiveCapabilityMask != 0)
        let hasBirdsEyeMapNavigationStrongerPerspective =
            hasBirdsEyeMapNavigationPerspective &&
            (legacyExtendedFlags &
                DeviceBLEProtocol.birdsEyeMapNavigationStrongerPerspectiveExtendedCapabilityMask != 0 ||
             flags & DeviceBLEProtocol.birdsEyeMapNavigationStrongerPerspectiveCapabilityMask != 0)
        let hasStreetLabels =
            flags & DeviceBLEProtocol.streetLabelsCapabilityMask != 0
        let has3DBuildings =
            flags & DeviceBLEProtocol.osm3DBuildingsCapabilityMask != 0
        let hasRideAutomation =
            flags & DeviceBLEProtocol.rideAutomationCapabilityMask != 0
        let hasExplicitInvalidGPSHeading =
            flags & DeviceBLEProtocol.explicitInvalidGPSHeadingCapabilityMask != 0
        let hasScopedWatchController =
            flags & DeviceBLEProtocol.scopedWatchControllerCapabilityMask != 0
        if has3DBuildings && shouldApply3DBuildingVisibilityDefault {
            shouldApply3DBuildingVisibilityDefault = false
            UserDefaults.standard.set(
                true,
                forKey: SettingsKeys.mapPlusNavigationShowBuildings
            )
            UserDefaults.standard.set(
                false,
                forKey: SettingsKeys.mapPlusNavigationBuildingVisibilityDefaultPending
            )
            mapPlusNavigationShowBuildings = true
        }
        if let powerButtonConfig {
            guard hasPowerButtonHonk,
                  powerButtonConfig[0] <= 1,
                  let deviceSound = DeviceSound(rawValue: powerButtonConfig[1]),
                  powerButtonConfig[2] <= 100 else {
                rejectDeviceCapabilities("Received invalid device capabilities configuration")
                return true
            }
            if pendingPowerButtonHonkPacket == nil {
                let deviceHonkEnabled = powerButtonConfig[0] == 1
                isPowerButtonHonkEnabled = deviceHonkEnabled
                if deviceHonkEnabled {
                    selectedDeviceSound = deviceSound
                    deviceSoundVolumePercent = Double(powerButtonConfig[2])
                }
                saveSettings()
            } else {
                log("Ignored device capabilities configuration while a local update is pending")
            }
        }
        let shouldSynchronizePowerButtonHonk = hasPowerButtonHonk &&
            powerButtonConfig == nil &&
            (!hasReceivedDeviceCapabilities || !supportsPowerButtonHonk)
        let shouldResendMapProfilesForExtendedVisibility =
            hasReceivedDeviceCapabilities &&
            !supportsExtendedMapVisibility &&
            hasExtendedMapVisibility
        let shouldResendMapNavigationForBirdsEye =
            hasReceivedDeviceCapabilities &&
            ((!supportsBirdsEyeMapNavigation && hasBirdsEyeMapNavigation) ||
             (!supportsBirdsEyeMapNavigationPerspective &&
              hasBirdsEyeMapNavigationPerspective) ||
             (!supportsBirdsEyeMapNavigationStrongerPerspective &&
              hasBirdsEyeMapNavigationStrongerPerspective))
        if shouldResendMapProfilesForExtendedVisibility {
            hasSentMapProfileForConnection = false
            hasSentMapNavigationProfileForConnection = false
        } else if shouldResendMapNavigationForBirdsEye {
            hasSentMapNavigationProfileForConnection = false
        }
        if hasReceivedDeviceCapabilities && !supportsStreetLabels && hasStreetLabels {
            hasSentMapProfileForConnection = false
            hasSentMapNavigationProfileForConnection = false
        }
        if hasReceivedDeviceCapabilities && !supports3DBuildings && has3DBuildings {
            hasSentMapNavigationProfileForConnection = false
        }
        if hasReceivedDeviceCapabilities &&
            supportsBatteryStatusScreen != hasBatteryStatusScreen {
            hasSentScreenSettingsForConnection = false
        }
        supportsDeviceSounds = hasDeviceSounds
        supportsPowerButtonHonk = hasPowerButtonHonk
        supportsPowerButtonHonkAcknowledgement = hasPowerButtonHonkAcknowledgement
        supportsIndependentMapProfiles = hasIndependentMapProfiles
        supportsExtendedMapVisibility = hasExtendedMapVisibility
        supportsBirdsEyeMapNavigation = hasBirdsEyeMapNavigation
        supportsBirdsEyeMapNavigationPerspective = hasBirdsEyeMapNavigationPerspective
        supportsBirdsEyeMapNavigationStrongerPerspective =
            hasBirdsEyeMapNavigationStrongerPerspective
        supportsBatteryStatusScreen = hasBatteryStatusScreen
        supportsDestinationPicker = hasDestinationPicker
        supportsStreetLabels = hasStreetLabels
        supports3DBuildings = has3DBuildings
        supportsRideAutomation = hasRideAutomation
        supportsExplicitInvalidGPSHeading = hasExplicitInvalidGPSHeading
        supportsScopedWatchController = hasScopedWatchController
        updateWorkoutTelemetryCapability(hasWorkoutTelemetry)
        if !hasPowerButtonHonkAcknowledgement {
            clearPendingPowerButtonHonkConfiguration()
        }
        hasReceivedDeviceCapabilities = true
        if hasScopedWatchController,
           pendingWatchControllerOperation == nil {
            hasReceivedWatchControllerStatus = false
            enqueueAuthMessage("WCTRL_STATUS")
        } else if !hasScopedWatchController {
            watchControllerIDHex = nil
            hasReceivedWatchControllerStatus = false
        }
        log("Device capabilities: schema=\(prefix) flags=0x\(String(format: "%08X", flags)) legacyExtended=0x\(String(format: "%02X", legacyExtendedFlags))")
        sendScreenSettingsAfterCapabilityNegotiation()
        sendMapProfilesAfterCapabilityNegotiation()
        if shouldSynchronizePowerButtonHonk {
            // @Published updates in willSet. Defer until the support flag is
            // observable so the guarded send uses the negotiated capability.
            DispatchQueue.main.async { [weak self] in
                _ = self?.sendPowerButtonHonkConfiguration()
            }
        }
        return true
    }

    @discardableResult
    func handleNavigationCharacteristicNotification(_ data: Data) -> Bool {
        let ridePrefix = Data(DeviceBLEProtocol.rideAutomationFallbackPrefix.utf8)
        if data.starts(with: ridePrefix) {
            guard isNavigationReady,
                  supportsRideAutomation,
                  let frame = RideAutomationFrame(
                    Data(data.dropFirst(ridePrefix.count))
                  ) else {
                log("Rejected invalid ride automation fallback")
                return true
            }
            onRideAutomationFrame?(frame)
            return true
        }
        if DeviceWorkoutStartRequest.matches(data) {
            guard isConnected, isNavigationReady else {
                log("Ignored workout start request before authentication completed")
                return true
            }
            log("Received workout start request")
            onWorkoutStartRequest?()
            return true
        }
        if let request = DeviceDestinationRequest.parse(data) {
            guard isConnected, isNavigationReady else {
                log("Ignored destination request before authentication completed")
                return true
            }
            log("Received destination request generation=\(request.generation) token=\(request.token)")
            onDestinationRequest?(request)
            return true
        }
        if handlePowerButtonHonkStatusNotification(data) {
            return true
        }
        if handleDeviceCapabilitiesNotification(data) {
            return true
        }
        if handleDeviceTransferStatusNotification(data) {
            return true
        }
        return handleMapTransferStatusNotification(data)
    }

    @discardableResult
    func handlePowerButtonHonkStatusNotification(_ data: Data) -> Bool {
        guard data.count >= 4,
              String(data: data.prefix(4), encoding: .utf8) ==
                DeviceBLEProtocol.powerButtonHonkStatusPrefix else {
            return false
        }

        let appliedIndex: Int
        let configStartIndex: Int
        var acknowledgedPacket = Data(DeviceBLEProtocol.powerButtonHonkPrefix.utf8)
        switch data.count {
        case 8:
            appliedIndex = 4
            configStartIndex = 5
        case 12:
            acknowledgedPacket.append(data.subdata(in: 4..<8))
            appliedIndex = 8
            configStartIndex = 9
        default:
            log("Received invalid PWR honk apply status")
            return true
        }

        guard data[appliedIndex] <= 1,
              data[configStartIndex] <= 1,
              DeviceSound(rawValue: data[configStartIndex + 1]) != nil,
              data[configStartIndex + 2] <= 100 else {
            log("Received invalid PWR honk apply status")
            return true
        }

        acknowledgedPacket.append(
            data.subdata(in: configStartIndex..<(configStartIndex + 3))
        )
        guard acknowledgedPacket == pendingPowerButtonHonkPacket else {
            log("Ignored stale PWR honk apply status")
            return true
        }

        if data[appliedIndex] == 1 {
            log("PWR honk configuration acknowledged")
            powerButtonHonkConfigurationError = nil
            clearPendingPowerButtonHonkConfiguration()
        } else {
            log("Device rejected PWR honk configuration; retrying")
            schedulePowerButtonHonkRetry(
                for: acknowledgedPacket,
                after: powerButtonHonkFailureRetryDelay
            )
        }
        return true
    }

    @discardableResult
    func handleDeviceTransferStatusNotification(_ data: Data) -> Bool {
        guard data.count >= 4,
              let prefix = String(data: data.prefix(4), encoding: .utf8) else {
            return false
        }

        if prefix == DeviceBLEProtocol.deviceTransferStatusChunkPrefix {
            return handleDeviceTransferStatusChunk(data)
        }
        guard prefix == DeviceBLEProtocol.deviceTransferStatusPrefix else {
            return false
        }

        return applyDeviceTransferStatusBody(Data(data.dropFirst(4)))
    }

    private func handleDeviceTransferStatusChunk(_ data: Data) -> Bool {
        guard data.count >= 7 else {
            firmwareUpdateStatus = "invalid status"
            return true
        }
        let transferID = data[4]
        let index = data[5]
        let count = data[6]
        guard count > 0, index < count else {
            firmwareUpdateStatus = "invalid status"
            return true
        }
        if deviceTransferStatusChunkTransferID != transferID ||
            deviceTransferStatusChunkCount != count {
            deviceTransferStatusChunkTransferID = transferID
            deviceTransferStatusChunkCount = count
            deviceTransferStatusChunks.removeAll(keepingCapacity: true)
        }
        deviceTransferStatusChunks[index] = Data(data.dropFirst(7))
        guard deviceTransferStatusChunks.count == Int(count) else {
            return true
        }
        var body = Data()
        for chunkIndex in UInt8(0)..<count {
            guard let chunk = deviceTransferStatusChunks[chunkIndex] else {
                return true
            }
            body.append(chunk)
        }
        deviceTransferStatusChunkTransferID = nil
        deviceTransferStatusChunkCount = 0
        deviceTransferStatusChunks.removeAll(keepingCapacity: true)
        return applyDeviceTransferStatusBody(body)
    }

    private func applyDeviceTransferStatusBody(_ body: Data) -> Bool {

        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            firmwareUpdateStatus = "invalid status"
            log("Received invalid device transfer status payload")
            return true
        }

        let enabled = object["enabled"] as? Bool ?? false
        deviceTransferMode = object["mode"] as? String ?? ""
        if let baseURLString = object["baseUrl"] as? String {
            deviceTransferBaseURL = URL(string: baseURLString)
        } else {
            deviceTransferBaseURL = nil
        }
        deviceTransferAccessPointSSID = object["apSsid"] as? String
        deviceTransferSessionToken = object["sessionToken"] as? String
        if let lastError = object["lastError"] as? [String: Any] {
            deviceTransferLastErrorCode = lastError["code"] as? String
            deviceTransferLastErrorMessage = lastError["message"] as? String
        } else {
            deviceTransferLastErrorCode = nil
            deviceTransferLastErrorMessage = nil
        }
        deviceTransferStatusRevision &+= 1

        if let firmware = object["firmware"] as? [String: Any] {
            firmwareUpdateStatus = firmware["status"] as? String ?? (enabled ? "unknown" : "idle")
            firmwareTarget = firmware["target"] as? String ?? firmwareTarget
            firmwareVersion = firmware["version"] as? String ?? firmwareVersion
            firmwareBuild = firmware["build"] as? Int ?? firmwareBuild
            firmwareGitSha = firmware["gitSha"] as? String ?? firmwareGitSha
            firmwareUpdateReceivedBytes = firmware["receivedBytes"] as? Int ?? 0
            firmwareUpdateTotalBytes = firmware["totalBytes"] as? Int ?? 0
            if let lastError = firmware["lastError"] as? [String: Any] {
                let code = lastError["code"] as? String ?? "error"
                let message = lastError["message"] as? String ?? ""
                firmwareUpdateLastError = message.isEmpty ? code : "\(code): \(message)"
            } else {
                firmwareUpdateLastError = nil
            }
        }

        log("Device transfer status: \(deviceTransferMode.isEmpty ? "none" : deviceTransferMode)")
        return true
    }

    @discardableResult
    func handleMapTransferStatusNotification(_ data: Data) -> Bool {
        guard data.count >= 4,
              let prefix = String(data: data.prefix(4), encoding: .utf8) else {
            return false
        }
        if prefix == DeviceBLEProtocol.mapTransferStatusChunkPrefix {
            return handleMapTransferStatusChunk(data)
        }
        guard prefix == DeviceBLEProtocol.mapTransferStatusPrefix else { return false }
        return applyMapTransferStatusBody(Data(data.dropFirst(4)))
    }

    private func handleMapTransferStatusChunk(_ data: Data) -> Bool {
        guard data.count >= 7 else {
            mapTransferStatusDescription = "invalid status"
            return true
        }
        let transferID = data[4]
        let index = data[5]
        let count = data[6]
        guard count > 0, index < count else {
            mapTransferStatusDescription = "invalid status"
            return true
        }
        if mapTransferStatusChunkTransferID != transferID ||
            mapTransferStatusChunkCount != count {
            mapTransferStatusChunkTransferID = transferID
            mapTransferStatusChunkCount = count
            mapTransferStatusChunks.removeAll(keepingCapacity: true)
        }
        mapTransferStatusChunks[index] = Data(data.dropFirst(7))
        guard mapTransferStatusChunks.count == Int(count) else { return true }

        var body = Data()
        for chunkIndex in UInt8(0)..<count {
            guard let chunk = mapTransferStatusChunks[chunkIndex] else { return true }
            body.append(chunk)
        }
        mapTransferStatusChunkTransferID = nil
        mapTransferStatusChunkCount = 0
        mapTransferStatusChunks.removeAll(keepingCapacity: true)
        return applyMapTransferStatusBody(body)
    }

    private func applyMapTransferStatusBody(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            mapTransferStatusDescription = "invalid status"
            log("Received invalid map transfer status payload")
            return true
        }

        mapTransferModeEnabled = object["enabled"] as? Bool ?? false
        if let baseURLString = object["baseUrl"] as? String {
            mapTransferBaseURL = URL(string: baseURLString)
        } else {
            mapTransferBaseURL = nil
        }
        mapTransferAccessPointSSID = object["apSsid"] as? String
        mapTransferActiveMapId = object["activeMapId"] as? String ?? ""
        mapTransferActiveSessionId = object["activeSessionId"] as? String ?? ""
        activeMapManifestReceipt = object["activeManifestReceipt"] as? String ?? ""
        activeMapRendererFormat =
            (object["activeRendererFormat"] as? NSNumber)?.intValue
        activeMapLabelProfileVersion =
            (object["labelProfileVersion"] as? NSNumber)?.intValue
        activeMapLabelLanguages = object["labelLanguages"] as? [String] ?? []
        activeMapFontAssetHealthy = object["fontAssetHealthy"] as? Bool ?? false
        if let activation = object["activation"] as? [String: Any] {
            mapTransferActivationStatus = activation["status"] as? String ?? "idle"
            mapTransferActivationSequence =
                (activation["sequence"] as? NSNumber)?.uint32Value
            mapTransferActivationSessionId = activation["sessionId"] as? String ?? ""
            mapTransferActivationMapId = activation["mapId"] as? String ?? ""
            mapTransferActivationStep = (activation["step"] as? NSNumber)?.intValue
            mapTransferActivationStepCount = (activation["steps"] as? NSNumber)?.intValue
            mapTransferActivationProgress = (activation["progress"] as? NSNumber)?.intValue
            if let activationError = activation["error"] as? [String: Any] {
                let code = activationError["code"] as? String ?? "activation_error"
                let message = activationError["message"] as? String ?? ""
                mapTransferActivationError = message.isEmpty ? code : "\(code): \(message)"
            } else {
                mapTransferActivationError = nil
            }
        } else {
            mapTransferActivationStatus = "idle"
            mapTransferActivationSequence = nil
            mapTransferActivationSessionId = ""
            mapTransferActivationMapId = ""
            mapTransferActivationStep = nil
            mapTransferActivationStepCount = nil
            mapTransferActivationProgress = nil
            mapTransferActivationError = nil
        }
        deviceHasSDCard = object["sdPresent"] as? Bool
        deviceMapFoundForCurrentLocation = object["mapFound"] as? Bool
        deviceMapBlockCount = object["mapBlocks"] as? Int ?? 0

        if let lastError = object["lastError"] as? [String: Any] {
            let code = lastError["code"] as? String ?? "error"
            let message = lastError["message"] as? String ?? ""
            mapTransferLastError = message.isEmpty ? code : "\(code): \(message)"
        } else if let activeError = object["activeError"] as? [String: Any],
                  (activeError["code"] as? String) != "active_missing" {
            let code = activeError["code"] as? String ?? "active_error"
            let message = activeError["message"] as? String ?? ""
            mapTransferLastError = message.isEmpty ? code : "\(code): \(message)"
        } else {
            mapTransferLastError = nil
        }

        if mapTransferModeEnabled, let mapTransferBaseURL {
            mapTransferStatusDescription = mapTransferBaseURL.absoluteString
        } else {
            mapTransferStatusDescription = "transfer mode disabled"
        }

        log("Map transfer status: \(mapTransferStatusDescription)")
        return true
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didReadRSSI RSSI: NSNumber, 
                   error: Error?) {
        guard BLELocalForgetPolicy.acceptsCallback(
            peripheralIdentifier: peripheral.identifier,
            currentIdentifier: connectedPeripheral?.identifier,
            forgottenIdentifiers: locallyForgottenPeripheralIdentifiers
        ) else {
            return
        }
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

extension BLEManager: RideAutomationBLETransport {
    var rideAutomationSupportPublisher: AnyPublisher<Bool, Never> {
        $supportsRideAutomation.eraseToAnyPublisher()
    }

    var rideAutomationDevicePublisher: AnyPublisher<String?, Never> {
        $connectedDeviceID.eraseToAnyPublisher()
    }
}
