import Foundation

nonisolated enum WorldRadioCommand: UInt8, Sendable {
    case selectLocation = 1
    case randomStation = 2
    case playPause = 3
    case previousStation = 4
    case nextStation = 5
    case stop = 6
}

nonisolated struct WorldRadioRequest: Equatable, Sendable {
    static let version: UInt8 = 1
    static let byteCount = 20

    let command: WorldRadioCommand
    let flags: UInt8
    let requestID: UInt32
    let latitudeE7: Int32
    let longitudeE7: Int32

    init?(_ data: Data) {
        guard data.count == Self.byteCount,
              data.prefix(4) == Data(RideBLEGeneratedProtocolV1.worldRadioRequestMagic.utf8),
              data[4] == Self.version,
              data[7] == 0,
              let command = WorldRadioCommand(rawValue: data[5]) else {
            return nil
        }
        let requestID = data.readUInt32LE(at: 8)
        let latitudeE7 = Int32(bitPattern: data.readUInt32LE(at: 12))
        let longitudeE7 = Int32(bitPattern: data.readUInt32LE(at: 16))
        guard requestID != 0 else { return nil }
        if command == .selectLocation {
            guard Self.isValidCoordinate(
                latitudeE7: latitudeE7,
                longitudeE7: longitudeE7
            ) else { return nil }
        }
        self.command = command
        self.flags = data[6]
        self.requestID = requestID
        self.latitudeE7 = latitudeE7
        self.longitudeE7 = longitudeE7
    }

    static func isValidCoordinate(latitudeE7: Int32, longitudeE7: Int32) -> Bool {
        (-900_000_000...900_000_000).contains(latitudeE7) &&
            (-1_800_000_000...1_800_000_000).contains(longitudeE7)
    }
}

nonisolated enum WorldRadioPlaybackState: UInt8, Equatable, Sendable {
    case idle = 0
    case searching = 1
    case connecting = 2
    case buffering = 3
    case playing = 4
    case paused = 5
    case noStations = 6
    case error = 7
}

nonisolated struct WorldRadioStation: Equatable, Sendable {
    let uuid: String
    let name: String
    let place: String
    let countryCode: String
    let latitudeE7: Int32
    let longitudeE7: Int32
    let bitrateKbps: UInt16
    let streamURL: URL
    let clickCount: Int
    let distanceMeters: Double?
}

nonisolated struct WorldRadioStatus: Equatable, Sendable {
    static let version: UInt8 = 1
    static let headerBytes = 32
    static let maximumBytes = 160
    static let stationNameBytes = 48
    static let placeBytes = 28
    static let messageBytes = 24

    let state: WorldRadioPlaybackState
    let favorite: Bool
    let stationIndex: UInt8
    let stationCount: UInt8
    let bitrateKbps: UInt16
    let requestID: UInt32
    let station: WorldRadioStation?
    let message: String

    init(
        state: WorldRadioPlaybackState,
        favorite: Bool = false,
        stationIndex: Int = 0,
        stationCount: Int = 0,
        bitrateKbps: UInt16? = nil,
        requestID: UInt32,
        station: WorldRadioStation? = nil,
        message: String = ""
    ) {
        self.state = state
        self.favorite = favorite
        self.stationIndex = UInt8(clamping: stationIndex)
        self.stationCount = UInt8(clamping: stationCount)
        self.bitrateKbps = bitrateKbps ?? station?.bitrateKbps ?? 0
        self.requestID = requestID
        self.station = station
        self.message = message
    }

    func encoded() -> Data? {
        guard requestID != 0 else { return nil }
        let name = Self.boundedUTF8(station?.name ?? "", maximumBytes: Self.stationNameBytes)
        let place = Self.boundedUTF8(station?.place ?? "", maximumBytes: Self.placeBytes)
        let message = Self.boundedUTF8(message, maximumBytes: Self.messageBytes)
        let total = Self.headerBytes + name.count + place.count + message.count
        guard total <= Self.maximumBytes else { return nil }

        var data = Data(repeating: 0, count: Self.headerBytes)
        data.replaceSubrange(0..<4, with: Data(RideBLEGeneratedProtocolV1.worldRadioStatusMagic.utf8))
        data[4] = Self.version
        data[5] = state.rawValue
        var statusFlags: UInt8 = favorite ? 1 : 0
        if station != nil { statusFlags |= 1 << 1 }
        data[6] = statusFlags
        data[7] = stationIndex
        data[8] = stationCount
        data.writeUInt16LE(bitrateKbps, at: 10)
        data.writeUInt32LE(requestID, at: 12)
        data.writeUInt32LE(UInt32(bitPattern: station?.latitudeE7 ?? 0), at: 16)
        data.writeUInt32LE(UInt32(bitPattern: station?.longitudeE7 ?? 0), at: 20)
        let country = Self.asciiCountryCode(station?.countryCode ?? "")
        data[24] = country[0]
        data[25] = country[1]
        data[26] = UInt8(name.count)
        data[27] = UInt8(place.count)
        data[28] = UInt8(message.count)
        data.append(name)
        data.append(place)
        data.append(message)
        return data
    }

    private static func boundedUTF8(_ value: String, maximumBytes: Int) -> Data {
        var result = Data()
        result.reserveCapacity(min(maximumBytes, value.utf8.count))
        for character in value {
            let bytes = Data(String(character).utf8)
            guard result.count + bytes.count <= maximumBytes else { break }
            result.append(bytes)
        }
        return result
    }

    private static func asciiCountryCode(_ value: String) -> [UInt8] {
        let ascii = value.uppercased().utf8.filter { byte in
            (65...90).contains(byte)
        }
        return [ascii.first ?? 0, ascii.dropFirst().first ?? 0]
    }
}

private nonisolated extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }

    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
