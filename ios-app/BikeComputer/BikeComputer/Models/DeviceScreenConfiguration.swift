import Foundation
import Security

enum ConfiguredDeviceScreenType: UInt8, CaseIterable, Codable, Identifiable, Sendable {
    case map = 0
    case navigation = 1
    case rideStats = 2
    case mapPlusNavigation = 3
    case batteryStatus = 4

    var id: UInt8 { rawValue }
    var bit: UInt32 { 1 << UInt32(rawValue) }

    var title: String {
        switch self {
        case .map: return "Map"
        case .navigation: return "Navigation"
        case .rideStats: return "Ride Stats"
        case .mapPlusNavigation: return "Map + Navigation"
        case .batteryStatus: return "Battery Status"
        }
    }
}

enum RideStatsWidget: UInt8, CaseIterable, Codable, Identifiable, Sendable {
    case empty = 0
    case speed = 1
    case heartRate = 2
    case heartRateZone = 3
    case distance = 4
    case movingTime = 5
    case elapsedTime = 6
    case altitude = 7
    case routeRemaining = 8
    case power = 9
    case cadence = 10
    case averageSpeed = 11
    case maximumSpeed = 12
    case calories = 13
    case averageHeartRate = 14
    case smartMetric1 = 15
    case smartMetric2 = 16

    var id: UInt8 { rawValue }
    var bit: UInt32 { 1 << UInt32(rawValue) }

    var title: String {
        switch self {
        case .empty: return "Empty"
        case .speed: return "Speed"
        case .heartRate: return "Heart Rate"
        case .heartRateZone: return "Heart-Rate Zone"
        case .distance: return "Distance"
        case .movingTime: return "Moving Time"
        case .elapsedTime: return "Elapsed Time"
        case .altitude: return "Altitude"
        case .routeRemaining: return "Route Remaining"
        case .power: return "Power"
        case .cadence: return "Cadence"
        case .averageSpeed: return "Average Speed"
        case .maximumSpeed: return "Maximum Speed"
        case .calories: return "Calories"
        case .averageHeartRate: return "Average Heart Rate"
        case .smartMetric1: return "Smart Metric 1"
        case .smartMetric2: return "Smart Metric 2"
        }
    }
}

struct DeviceScreenConfigurationCapabilities: Equatable, Sendable {
    static let valueByteCount = 14

    var schemaVersion: UInt8
    var maximumInstances: UInt8
    var maximumNameBytes: UInt8
    var rideStatsSlotCount: UInt8
    var supportedScreenTypes: UInt32
    var supportedRideStatsWidgets: UInt32
    var maximumDocumentBytes: UInt16

    static let v1 = DeviceScreenConfigurationCapabilities(
        schemaVersion: RideBLEGeneratedProtocolV1.screenConfigurationSchemaVersion,
        maximumInstances: UInt8(RideBLEGeneratedProtocolV1.maximumScreenConfigurationInstances),
        maximumNameBytes: UInt8(RideBLEGeneratedProtocolV1.maximumScreenConfigurationNameBytes),
        rideStatsSlotCount: UInt8(RideBLEGeneratedProtocolV1.rideStatsConfigurationSlotCount),
        supportedScreenTypes: ConfiguredDeviceScreenType.allCases.reduce(0) { $0 | $1.bit },
        supportedRideStatsWidgets: RideStatsWidget.allCases.reduce(0) { $0 | $1.bit },
        maximumDocumentBytes: UInt16(RideBLEGeneratedProtocolV1.maximumScreenConfigurationDocumentBytes)
    )

    func supports(_ type: ConfiguredDeviceScreenType) -> Bool {
        supportedScreenTypes & type.bit != 0
    }

    func supports(_ widget: RideStatsWidget) -> Bool {
        supportedRideStatsWidgets & widget.bit != 0
    }

    init?(tlvValue: Data) {
        guard tlvValue.count == Self.valueByteCount else { return nil }
        schemaVersion = tlvValue[0]
        maximumInstances = tlvValue[1]
        maximumNameBytes = tlvValue[2]
        rideStatsSlotCount = tlvValue[3]
        supportedScreenTypes = tlvValue.readUInt32LE(at: 4)
        supportedRideStatsWidgets = tlvValue.readUInt32LE(at: 8)
        maximumDocumentBytes = tlvValue.readUInt16LE(at: 12)
        guard schemaVersion == RideBLEGeneratedProtocolV1.screenConfigurationSchemaVersion,
              maximumInstances > 0,
              maximumInstances <= RideBLEGeneratedProtocolV1.maximumScreenConfigurationInstances,
              maximumNameBytes > 0,
              maximumNameBytes <= RideBLEGeneratedProtocolV1.maximumScreenConfigurationNameBytes,
              rideStatsSlotCount == RideBLEGeneratedProtocolV1.rideStatsConfigurationSlotCount,
              maximumDocumentBytes > 0,
              maximumDocumentBytes <= RideBLEGeneratedProtocolV1.maximumScreenConfigurationDocumentBytes else {
            return nil
        }
    }

    init(
        schemaVersion: UInt8,
        maximumInstances: UInt8,
        maximumNameBytes: UInt8,
        rideStatsSlotCount: UInt8,
        supportedScreenTypes: UInt32,
        supportedRideStatsWidgets: UInt32,
        maximumDocumentBytes: UInt16
    ) {
        self.schemaVersion = schemaVersion
        self.maximumInstances = maximumInstances
        self.maximumNameBytes = maximumNameBytes
        self.rideStatsSlotCount = rideStatsSlotCount
        self.supportedScreenTypes = supportedScreenTypes
        self.supportedRideStatsWidgets = supportedRideStatsWidgets
        self.maximumDocumentBytes = maximumDocumentBytes
    }
}

struct DeviceScreenMapProfile: Equatable, Codable, Sendable {
    static let allowedVisibilityMask: UInt32 = 0x0fff

    var minimumPolygonSize: UInt8 = 0
    var detailLevel: UInt8 = 2
    var routeLineWidth: UInt8 = 4
    var streetLineWidth: UInt8 = 4
    var positionMarkerScale: UInt8 = 2
    var zoomLevel: UInt8 = 3
    var visibilityMask: UInt32 = allowedVisibilityMask
    var labelDensity: UInt8 = 2
    var labelLanguageMode: UInt8 = 2
    var labelTextSize: UInt8 = 0
    var labelOrientation: UInt8 = 1
    var rotationMode: UInt8 = 0
    var birdsEyeEnabled = true
    var birdsEyePerspective: UInt8 = 1
    var buildings3DEnabled = true

    static var mapDefault: DeviceScreenMapProfile { .init() }

    static var mapPlusNavigationDefault: DeviceScreenMapProfile {
        var profile = DeviceScreenMapProfile()
        profile.detailLevel = 0
        profile.routeLineWidth = 15
        profile.visibilityMask = 0x0339
        profile.labelDensity = 0
        return profile
    }

    func isValid(for type: ConfiguredDeviceScreenType) -> Bool {
        guard minimumPolygonSize <= 50,
              detailLevel <= 2,
              (2...48).contains(routeLineWidth),
              (1...24).contains(streetLineWidth),
              (1...5).contains(positionMarkerScale),
              zoomLevel <= 5,
              visibilityMask & ~Self.allowedVisibilityMask == 0,
              labelDensity <= 3,
              labelLanguageMode <= 2,
              labelTextSize <= 2,
              labelOrientation <= 1 else { return false }
        switch type {
        case .map: return rotationMode <= 1
        case .mapPlusNavigation: return birdsEyePerspective <= 4
        default: return false
        }
    }
}

struct RideStatsLayout: Equatable, Codable, Sendable {
    static let slotCount = 7
    static let defaultSlots: [RideStatsWidget] = [
        .speed, .heartRate, .heartRateZone, .distance,
        .movingTime, .smartMetric1, .smartMetric2,
    ]

    var slots: [RideStatsWidget] = defaultSlots
}

struct DeviceScreenInstance: Identifiable, Equatable, Codable, Sendable {
    var id: UInt32
    var type: ConfiguredDeviceScreenType
    var enabled: Bool
    var name: String
    var mapProfile: DeviceScreenMapProfile?
    var rideStatsLayout: RideStatsLayout?

    static func defaults(
        id: UInt32,
        type: ConfiguredDeviceScreenType,
        name: String? = nil
    ) -> DeviceScreenInstance {
        DeviceScreenInstance(
            id: id,
            type: type,
            enabled: true,
            name: name ?? type.title,
            mapProfile: type == .map ? .mapDefault :
                (type == .mapPlusNavigation ? .mapPlusNavigationDefault : nil),
            rideStatsLayout: type == .rideStats ? RideStatsLayout() : nil
        )
    }
}

enum DeviceScreenConfigurationValidationError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchema
    case invalidInstanceCount
    case invalidID
    case duplicateID
    case invalidName
    case unsupportedType
    case invalidPayload
    case unsupportedWidget
    case emptyRideStatsLayout
    case allDisabled
    case invalidDefault
    case documentTooLarge

    var description: String {
        switch self {
        case .unsupportedSchema: return "The device uses an unsupported screen-settings version."
        case .invalidInstanceCount: return "Add between 1 and 16 screens."
        case .invalidID, .duplicateID: return "A screen has an invalid identity."
        case .invalidName: return "Screen names must contain 1–24 UTF-8 bytes and no control characters."
        case .unsupportedType: return "A screen type is not supported by this device."
        case .invalidPayload: return "A screen contains invalid settings."
        case .unsupportedWidget: return "A workout widget is not supported by this device."
        case .emptyRideStatsLayout: return "A Ride Stats screen must show at least one widget."
        case .allDisabled: return "At least one screen must be enabled."
        case .invalidDefault: return "The default screen must be enabled."
        case .documentTooLarge: return "The screen configuration is too large."
        }
    }
}

struct DeviceScreenConfigurationDocument: Equatable, Codable, Sendable {
    static let schemaVersion: UInt8 = 1
    var defaultInstanceID: UInt32
    var instances: [DeviceScreenInstance]

    static let legacyDefault = DeviceScreenConfigurationDocument(
        defaultInstanceID: 4,
        instances: [
            .defaults(id: 4, type: .mapPlusNavigation),
            .defaults(id: 3, type: .rideStats),
            .defaults(id: 1, type: .map),
            .defaults(id: 2, type: .navigation),
            .defaults(id: 5, type: .batteryStatus),
        ]
    )

    func validate(
        capabilities: DeviceScreenConfigurationCapabilities = .v1,
        encodedByteCount: Int? = nil
    ) throws {
        guard capabilities.schemaVersion == Self.schemaVersion else {
            throw DeviceScreenConfigurationValidationError.unsupportedSchema
        }
        guard !instances.isEmpty,
              instances.count <= Int(capabilities.maximumInstances) else {
            throw DeviceScreenConfigurationValidationError.invalidInstanceCount
        }
        var ids = Set<UInt32>()
        var hasEnabled = false
        var defaultEnabled = false
        for instance in instances {
            guard instance.id != 0 else {
                throw DeviceScreenConfigurationValidationError.invalidID
            }
            guard ids.insert(instance.id).inserted else {
                throw DeviceScreenConfigurationValidationError.duplicateID
            }
            let nameBytes = instance.name.data(using: .utf8) ?? Data()
            guard !nameBytes.isEmpty,
                  nameBytes.count <= Int(capabilities.maximumNameBytes),
                  !instance.name.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw DeviceScreenConfigurationValidationError.invalidName
            }
            guard capabilities.supports(instance.type) else {
                throw DeviceScreenConfigurationValidationError.unsupportedType
            }
            switch instance.type {
            case .map, .mapPlusNavigation:
                guard let profile = instance.mapProfile,
                      profile.isValid(for: instance.type),
                      instance.rideStatsLayout == nil else {
                    throw DeviceScreenConfigurationValidationError.invalidPayload
                }
            case .rideStats:
                guard instance.mapProfile == nil,
                      let layout = instance.rideStatsLayout,
                      layout.slots.count == Int(capabilities.rideStatsSlotCount) else {
                    throw DeviceScreenConfigurationValidationError.invalidPayload
                }
                guard layout.slots.allSatisfy(capabilities.supports) else {
                    throw DeviceScreenConfigurationValidationError.unsupportedWidget
                }
                guard layout.slots.contains(where: { $0 != .empty }) else {
                    throw DeviceScreenConfigurationValidationError.emptyRideStatsLayout
                }
            case .navigation, .batteryStatus:
                guard instance.mapProfile == nil,
                      instance.rideStatsLayout == nil else {
                    throw DeviceScreenConfigurationValidationError.invalidPayload
                }
            }
            hasEnabled = hasEnabled || instance.enabled
            defaultEnabled = defaultEnabled ||
                (instance.enabled && instance.id == defaultInstanceID)
        }
        guard hasEnabled else {
            throw DeviceScreenConfigurationValidationError.allDisabled
        }
        guard defaultEnabled else {
            throw DeviceScreenConfigurationValidationError.invalidDefault
        }
        if let encodedByteCount,
           encodedByteCount > Int(capabilities.maximumDocumentBytes) {
            throw DeviceScreenConfigurationValidationError.documentTooLarge
        }
    }

    mutating func normalizeDefault() {
        if !instances.contains(where: { $0.enabled && $0.id == defaultInstanceID }),
           let fallback = instances.first(where: \.enabled) {
            defaultInstanceID = fallback.id
        }
    }

    mutating func setEnabled(_ enabled: Bool, instanceID: UInt32) -> Bool {
        guard let index = instances.firstIndex(where: { $0.id == instanceID }) else {
            return false
        }
        if !enabled && instances.filter(\.enabled).count == 1 && instances[index].enabled {
            return false
        }
        instances[index].enabled = enabled
        normalizeDefault()
        return true
    }

    mutating func remove(instanceID: UInt32) -> Bool {
        guard instances.count > 1,
              let index = instances.firstIndex(where: { $0.id == instanceID }) else {
            return false
        }
        let wasOnlyEnabled = instances[index].enabled && instances.filter(\.enabled).count == 1
        guard !wasOnlyEnabled else { return false }
        instances.remove(at: index)
        normalizeDefault()
        return true
    }

    mutating func move(fromOffsets: IndexSet, toOffset: Int) {
        let moving = fromOffsets.sorted().map { instances[$0] }
        for offset in fromOffsets.sorted(by: >) { instances.remove(at: offset) }
        let removedBefore = fromOffsets.filter { $0 < toOffset }.count
        instances.insert(contentsOf: moving, at: max(0, min(instances.count, toOffset - removedBefore)))
    }

    mutating func add(
        type: ConfiguredDeviceScreenType,
        after instanceID: UInt32?,
        generator: DeviceScreenInstanceIDGenerator = .secure
    ) throws -> UInt32 {
        let id = try generator.generate(excluding: Set(instances.map(\.id)))
        let duplicateNumber = instances.filter { $0.type == type }.count + 1
        let name = duplicateNumber == 1 ? type.title : "\(type.title) \(duplicateNumber)"
        let instance = DeviceScreenInstance.defaults(id: id, type: type, name: name)
        let insertionIndex = instanceID.flatMap { selected in
            instances.firstIndex(where: { $0.id == selected }).map { $0 + 1 }
        } ?? instances.endIndex
        instances.insert(instance, at: insertionIndex)
        return id
    }
}

struct DeviceScreenInstanceIDGenerator: Sendable {
    enum GenerationError: Error { case entropyUnavailable }
    var randomValue: @Sendable () throws -> UInt32

    static let secure = DeviceScreenInstanceIDGenerator {
        var value: UInt32 = 0
        guard SecRandomCopyBytes(kSecRandomDefault, MemoryLayout.size(ofValue: value), &value) == errSecSuccess else {
            throw GenerationError.entropyUnavailable
        }
        return value
    }

    func generate(excluding existing: Set<UInt32>) throws -> UInt32 {
        for _ in 0..<64 {
            let candidate = try randomValue() | 0x8000_0000
            if candidate != 0 && !existing.contains(candidate) { return candidate }
        }
        throw GenerationError.entropyUnavailable
    }
}

enum DeviceScreenConfigurationCodec {
    static let magic = Data("SCV1".utf8)
    static let maximumBytes = RideBLEGeneratedProtocolV1.maximumScreenConfigurationDocumentBytes
    private static let payloadVersion: UInt8 = 1

    static func encode(
        _ document: DeviceScreenConfigurationDocument,
        capabilities: DeviceScreenConfigurationCapabilities = .v1
    ) throws -> Data {
        try document.validate(capabilities: capabilities)
        var data = magic
        data.append(DeviceScreenConfigurationDocument.schemaVersion)
        data.append(UInt8(document.instances.count))
        data.appendUInt32LE(document.defaultInstanceID)
        for instance in document.instances {
            let name = Data(instance.name.utf8)
            let payload = try encodePayload(instance)
            data.appendUInt32LE(instance.id)
            data.append(instance.type.rawValue)
            data.append(instance.enabled ? 1 : 0)
            data.append(UInt8(name.count))
            data.appendUInt16LE(UInt16(payload.count))
            data.append(name)
            data.append(payload)
        }
        guard data.count + 4 <= Int(capabilities.maximumDocumentBytes) else {
            throw DeviceScreenConfigurationValidationError.documentTooLarge
        }
        data.appendUInt32LE(crc32(data))
        try document.validate(capabilities: capabilities, encodedByteCount: data.count)
        return data
    }

    static func decode(
        _ data: Data,
        capabilities: DeviceScreenConfigurationCapabilities = .v1
    ) throws -> DeviceScreenConfigurationDocument {
        guard data.count >= 14,
              data.count <= Int(capabilities.maximumDocumentBytes),
              data.prefix(4) == magic,
              crc32(data.dropLast(4)) == data.readUInt32LE(at: data.count - 4) else {
            throw DeviceScreenConfigurationValidationError.invalidPayload
        }
        var reader = ScreenConfigurationDataReader(data: Data(data.dropLast(4)), offset: 4)
        guard try reader.byte() == DeviceScreenConfigurationDocument.schemaVersion else {
            throw DeviceScreenConfigurationValidationError.unsupportedSchema
        }
        let count = Int(try reader.byte())
        let defaultID = try reader.uint32()
        var instances: [DeviceScreenInstance] = []
        instances.reserveCapacity(count)
        for _ in 0..<count {
            let id = try reader.uint32()
            guard let type = ConfiguredDeviceScreenType(rawValue: try reader.byte()) else {
                throw DeviceScreenConfigurationValidationError.unsupportedType
            }
            let flags = try reader.byte()
            guard flags & ~1 == 0 else {
                throw DeviceScreenConfigurationValidationError.invalidPayload
            }
            let nameLength = Int(try reader.byte())
            let payloadLength = Int(try reader.uint16())
            let nameData = try reader.data(count: nameLength)
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw DeviceScreenConfigurationValidationError.invalidName
            }
            let payload = try reader.data(count: payloadLength)
            instances.append(try decodeInstance(
                id: id,
                type: type,
                enabled: flags == 1,
                name: name,
                payload: payload
            ))
        }
        guard reader.isAtEnd else {
            throw DeviceScreenConfigurationValidationError.invalidPayload
        }
        let document = DeviceScreenConfigurationDocument(
            defaultInstanceID: defaultID,
            instances: instances
        )
        try document.validate(capabilities: capabilities, encodedByteCount: data.count)
        return document
    }

    static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc = UInt32.max
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0)
            }
        }
        return ~crc
    }

    static func documentCRC(_ data: Data) -> UInt32? {
        guard data.count >= 4 else { return nil }
        return data.readUInt32LE(at: data.count - 4)
    }

    private static func encodePayload(_ instance: DeviceScreenInstance) throws -> Data {
        var payload = Data([payloadVersion])
        switch instance.type {
        case .map, .mapPlusNavigation:
            guard let profile = instance.mapProfile else {
                throw DeviceScreenConfigurationValidationError.invalidPayload
            }
            payload.append(contentsOf: [
                profile.minimumPolygonSize, profile.detailLevel,
                profile.routeLineWidth, profile.streetLineWidth,
                profile.positionMarkerScale, profile.zoomLevel,
            ])
            payload.appendUInt32LE(profile.visibilityMask)
            payload.append(contentsOf: [
                profile.labelDensity, profile.labelLanguageMode,
                profile.labelTextSize, profile.labelOrientation,
            ])
            if instance.type == .map {
                payload.append(profile.rotationMode)
            } else {
                payload.append(profile.birdsEyeEnabled ? 1 : 0)
                payload.append(profile.birdsEyePerspective)
                payload.append(profile.buildings3DEnabled ? 1 : 0)
            }
        case .rideStats:
            guard let layout = instance.rideStatsLayout else {
                throw DeviceScreenConfigurationValidationError.invalidPayload
            }
            payload.append(1)
            payload.append(UInt8(layout.slots.count))
            payload.append(contentsOf: layout.slots.map(\.rawValue))
        case .navigation, .batteryStatus:
            break
        }
        return payload
    }

    private static func decodeInstance(
        id: UInt32,
        type: ConfiguredDeviceScreenType,
        enabled: Bool,
        name: String,
        payload: Data
    ) throws -> DeviceScreenInstance {
        var reader = ScreenConfigurationDataReader(data: payload)
        guard try reader.byte() == payloadVersion else {
            throw DeviceScreenConfigurationValidationError.unsupportedSchema
        }
        var mapProfile: DeviceScreenMapProfile?
        var rideStatsLayout: RideStatsLayout?
        switch type {
        case .map, .mapPlusNavigation:
            let expectedCount = type == .map ? 16 : 18
            guard payload.count == expectedCount else {
                throw DeviceScreenConfigurationValidationError.invalidPayload
            }
            var profile = type == .map
                ? DeviceScreenMapProfile.mapDefault
                : DeviceScreenMapProfile.mapPlusNavigationDefault
            profile.minimumPolygonSize = try reader.byte()
            profile.detailLevel = try reader.byte()
            profile.routeLineWidth = try reader.byte()
            profile.streetLineWidth = try reader.byte()
            profile.positionMarkerScale = try reader.byte()
            profile.zoomLevel = try reader.byte()
            profile.visibilityMask = try reader.uint32()
            profile.labelDensity = try reader.byte()
            profile.labelLanguageMode = try reader.byte()
            profile.labelTextSize = try reader.byte()
            profile.labelOrientation = try reader.byte()
            if type == .map {
                profile.rotationMode = try reader.byte()
            } else {
                let birdsEye = try reader.byte()
                profile.birdsEyePerspective = try reader.byte()
                let buildings = try reader.byte()
                guard birdsEye <= 1, buildings <= 1 else {
                    throw DeviceScreenConfigurationValidationError.invalidPayload
                }
                profile.birdsEyeEnabled = birdsEye == 1
                profile.buildings3DEnabled = buildings == 1
            }
            mapProfile = profile
        case .rideStats:
            guard payload.count == 10,
                  try reader.byte() == 1,
                  try reader.byte() == RideStatsLayout.slotCount else {
                throw DeviceScreenConfigurationValidationError.unsupportedSchema
            }
            var slots: [RideStatsWidget] = []
            for _ in 0..<RideStatsLayout.slotCount {
                guard let widget = RideStatsWidget(rawValue: try reader.byte()) else {
                    throw DeviceScreenConfigurationValidationError.unsupportedWidget
                }
                slots.append(widget)
            }
            rideStatsLayout = RideStatsLayout(slots: slots)
        case .navigation, .batteryStatus:
            guard payload.count == 1 else {
                throw DeviceScreenConfigurationValidationError.invalidPayload
            }
        }
        guard reader.isAtEnd else {
            throw DeviceScreenConfigurationValidationError.invalidPayload
        }
        return DeviceScreenInstance(
            id: id,
            type: type,
            enabled: enabled,
            name: name,
            mapProfile: mapProfile,
            rideStatsLayout: rideStatsLayout
        )
    }
}

private struct ScreenConfigurationDataReader {
    let data: Data
    var offset = 0
    var isAtEnd: Bool { offset == data.count }

    mutating func byte() throws -> UInt8 {
        guard offset < data.count else {
            throw DeviceScreenConfigurationValidationError.invalidPayload
        }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func uint16() throws -> UInt16 {
        let value = try data(count: 2)
        return value.readUInt16LE(at: 0)
    }

    mutating func uint32() throws -> UInt32 {
        let value = try data(count: 4)
        return value.readUInt32LE(at: 0)
    }

    mutating func data(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw DeviceScreenConfigurationValidationError.invalidPayload
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
}

extension Data {
    fileprivate mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    fileprivate mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    fileprivate func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    fileprivate func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }
}
