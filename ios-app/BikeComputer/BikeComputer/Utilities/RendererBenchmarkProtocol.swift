import CoreLocation
import CryptoKit
import Foundation

enum RendererBenchmarkFixtureError: LocalizedError {
    case missing
    case invalid

    var errorDescription: String? {
        switch self {
        case .missing:
            return "The renderer benchmark fixture is missing from this build."
        case .invalid:
            return "The renderer benchmark fixture is invalid."
        }
    }
}

struct RendererBenchmarkPoint: Codable, Equatable {
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct RendererBenchmarkFixture: Codable, Equatable {
    static let resourceName = "renderer-benchmark-shanghai-v1"

    let schema: UInt8
    let id: String
    let cadenceHz: UInt8
    let nominalSpeedMetersPerSecond: Double
    let points: [RendererBenchmarkPoint]

    static func decode(_ data: Data) throws -> RendererBenchmarkFixture {
        guard data.count <= 32_768,
              let fixture = try? JSONDecoder().decode(
                RendererBenchmarkFixture.self,
                from: data
              ),
              fixture.schema == 1,
              fixture.cadenceHz == 1,
              !fixture.id.isEmpty,
              fixture.id.utf8.count < 49,
              fixture.nominalSpeedMetersPerSecond.isFinite,
              fixture.nominalSpeedMetersPerSecond > 0,
              (60...120).contains(fixture.points.count),
              fixture.points.allSatisfy({ point in
                  point.latitude.isFinite && point.longitude.isFinite &&
                      (-90...90).contains(point.latitude) &&
                      (-180...180).contains(point.longitude)
              }) else {
            throw RendererBenchmarkFixtureError.invalid
        }
        return fixture
    }

    static func load(
        bundle: Bundle = .main
    ) throws -> (fixture: RendererBenchmarkFixture, sha256: Data) {
        let url = bundle.url(
            forResource: resourceName,
            withExtension: "json",
            subdirectory: "Resources"
        ) ?? bundle.url(forResource: resourceName, withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url) else {
            throw RendererBenchmarkFixtureError.missing
        }
        return (try decode(data), Data(SHA256.hash(data: data)))
    }
}

struct RendererBenchmarkRouteCoverage: Equatable {
    let routeBounds: OfflineMapPreviewBounds
    let firstOutsidePointIndex: Int?
    let firstOutsidePoint: RendererBenchmarkPoint?

    var coversEntireRoute: Bool {
        firstOutsidePointIndex == nil
    }

    init?(
        fixture: RendererBenchmarkFixture,
        mapBounds: OfflineMapPreviewBounds
    ) {
        guard let minimumLongitude = fixture.points.map(\.longitude).min(),
              let minimumLatitude = fixture.points.map(\.latitude).min(),
              let maximumLongitude = fixture.points.map(\.longitude).max(),
              let maximumLatitude = fixture.points.map(\.latitude).max(),
              let routeBounds = OfflineMapPreviewBounds(coordinates: [
                minimumLongitude,
                minimumLatitude,
                maximumLongitude,
                maximumLatitude,
              ]) else {
            return nil
        }
        self.routeBounds = routeBounds
        firstOutsidePointIndex = fixture.points.firstIndex { point in
            point.longitude < mapBounds.minLongitude ||
                point.longitude > mapBounds.maxLongitude ||
                point.latitude < mapBounds.minLatitude ||
                point.latitude > mapBounds.maxLatitude
        }
        firstOutsidePoint = firstOutsidePointIndex.map { fixture.points[$0] }
    }

    func failureDescription(mapBounds: OfflineMapPreviewBounds) -> String {
        let mapDescription = Self.boundsDescription(mapBounds)
        let routeDescription = Self.boundsDescription(routeBounds)
        let sampleDescription: String
        if let firstOutsidePointIndex, let firstOutsidePoint {
            sampleDescription = String(
                format: " firstOutside=%d:(%.7f,%.7f)",
                locale: Locale(identifier: "en_US_POSIX"),
                firstOutsidePointIndex,
                firstOutsidePoint.longitude,
                firstOutsidePoint.latitude
            )
        } else {
            sampleDescription = ""
        }
        return "The active signed map does not cover the pinned Shanghai route. " +
            "map=[\(mapDescription)] route=[\(routeDescription)]" +
            sampleDescription
    }

    private static func boundsDescription(
        _ bounds: OfflineMapPreviewBounds
    ) -> String {
        String(
            format: "%.7f,%.7f,%.7f,%.7f",
            locale: Locale(identifier: "en_US_POSIX"),
            bounds.minLongitude,
            bounds.minLatitude,
            bounds.maxLongitude,
            bounds.maxLatitude
        )
    }
}

enum RendererBenchmarkProfile: UInt8, CaseIterable, Identifiable {
    case flat = 0
    case current = 1
    case medium = 2
    case high = 3

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .flat: return "Flat control"
        case .current: return "Current (32)"
        case .medium: return "Medium (40)"
        case .high: return "High (48)"
        }
    }
}

enum RendererBenchmarkRouteGeometry {
    static let maximumPointCount = 40

    static func data(
        fixture: RendererBenchmarkFixture,
        sampleIndex: Int,
        maximumPointCount: Int = maximumPointCount
    ) -> Data? {
        guard fixture.points.count >= 2,
              fixture.points.indices.contains(sampleIndex),
              maximumPointCount >= 2 else { return nil }
        let count = min(maximumPointCount, fixture.points.count)
        let points = (0..<count).map {
            fixture.points[(sampleIndex + $0) % fixture.points.count]
        }
        guard let first = points.first else { return nil }

        var data = Data()
        var previousLatitude = Int32(first.latitude * 1_000_000)
        var previousLongitude = Int32(first.longitude * 1_000_000)
        data.appendInt32LE(previousLatitude)
        data.appendInt32LE(previousLongitude)
        for point in points.dropFirst() {
            let latitude = Int32(point.latitude * 1_000_000)
            let longitude = Int32(point.longitude * 1_000_000)
            let latitudeDelta = Int64(latitude) - Int64(previousLatitude)
            let longitudeDelta = Int64(longitude) - Int64(previousLongitude)
            guard Int64(Int16.min)...Int64(Int16.max) ~= latitudeDelta,
                  Int64(Int16.min)...Int64(Int16.max) ~= longitudeDelta else {
                return nil
            }
            data.appendInt16LE(Int16(latitudeDelta))
            data.appendInt16LE(Int16(longitudeDelta))
            previousLatitude = latitude
            previousLongitude = longitude
        }
        return data
    }
}

enum RendererBenchmarkMarkerPacket {
    static let byteCount = 44

    static func data(
        fixtureSHA256: Data,
        sampleIndex: Int,
        sampleCount: Int,
        loop: UInt32
    ) -> Data? {
        guard fixtureSHA256.count == 32,
              sampleCount > 0,
              sampleCount <= Int(UInt16.max),
              sampleIndex >= 0,
              sampleIndex < sampleCount else { return nil }
        var data = Data(DeviceBLEProtocol.rendererBenchmarkMarkerPrefix.utf8)
        data.append(fixtureSHA256)
        data.appendUInt16LE(UInt16(sampleIndex))
        data.appendUInt16LE(UInt16(sampleCount))
        data.appendUInt32LE(loop)
        return data.count == byteCount ? data : nil
    }
}

enum RendererBenchmarkWindowPacket {
    static let maximumByteCount = 97

    static func data(
        profile: RendererBenchmarkProfile,
        repeatNumber: UInt16,
        runNonce: UInt64,
        fixtureSHA256: Data,
        fixtureID: String
    ) -> Data? {
        let fixtureIDData = Data(fixtureID.utf8)
        guard repeatNumber > 0,
              runNonce > 0,
              fixtureSHA256.count == 32,
              !fixtureIDData.isEmpty,
              fixtureIDData.count <= 48 else { return nil }
        var data = Data(DeviceBLEProtocol.rendererBenchmarkWindowPrefix.utf8)
        data.append(1)
        data.append(profile.rawValue)
        data.appendUInt16LE(repeatNumber)
        data.appendUInt64LE(runNonce)
        data.append(fixtureSHA256)
        data.append(UInt8(fixtureIDData.count))
        data.append(fixtureIDData)
        return data.count <= maximumByteCount ? data : nil
    }
}

enum RendererDiagnosticsChunkResult: Equatable {
    case pending
    case complete(Data)
    case rejected
}

struct RendererDiagnosticsChunkReassembler {
    static let maximumBodyBytes = 32_768

    private var transferID: UInt8?
    private var chunkCount: UInt8 = 0
    private var chunks: [UInt8: Data] = [:]
    private var accumulatedBytes = 0

    mutating func reset() {
        transferID = nil
        chunkCount = 0
        chunks.removeAll(keepingCapacity: true)
        accumulatedBytes = 0
    }

    mutating func consume(_ data: Data) -> RendererDiagnosticsChunkResult? {
        let prefix = Data(DeviceBLEProtocol.rendererMetricsChunkPrefix.utf8)
        guard data.starts(with: prefix) else { return nil }
        guard data.count >= 7 else {
            reset()
            return .rejected
        }
        let nextTransferID = data[4]
        let index = data[5]
        let count = data[6]
        guard count > 0, index < count else {
            reset()
            return .rejected
        }
        if transferID != nextTransferID || chunkCount != count {
            reset()
            transferID = nextTransferID
            chunkCount = count
        }

        let chunk = Data(data.dropFirst(7))
        guard chunks[index] == nil else {
            reset()
            return .rejected
        }
        guard accumulatedBytes + chunk.count <= Self.maximumBodyBytes else {
            reset()
            return .rejected
        }
        chunks[index] = chunk
        accumulatedBytes += chunk.count
        guard chunks.count == Int(count) else { return .pending }

        var body = Data()
        body.reserveCapacity(accumulatedBytes)
        for chunkIndex in UInt8(0)..<count {
            guard let chunk = chunks[chunkIndex] else { return .pending }
            body.append(chunk)
        }
        reset()
        return .complete(body)
    }
}

enum RendererDiagnosticsSnapshotEnvelope {
    static func normalizedJSONString(_ body: Data) -> String? {
        guard body.count <= RendererDiagnosticsChunkReassembler.maximumBodyBytes,
              let object = try? JSONSerialization.jsonObject(with: body)
                as? [String: Any],
              object["ok"] as? Bool == true,
              object["schema"] as? Int == 1,
              object["identity"] is [String: Any],
              object["memory"] is [String: Any],
              object["render"] is [String: Any],
              let value = String(data: body, encoding: .utf8) else {
            return nil
        }
        return value
    }
}

enum RendererOrdinaryDiagnosticsCapture {
    static let maximumSnapshotCount = 128

    static func json(
        fixtureID: String,
        fixtureSHA256: Data,
        snapshots: [String],
        generatedAt: Date = Date()
    ) -> String? {
        guard !fixtureID.isEmpty,
              fixtureID.utf8.count < 49,
              fixtureSHA256.count == 32,
              !snapshots.isEmpty,
              snapshots.count <= maximumSnapshotCount else {
            return nil
        }
        var decoded: [[String: Any]] = []
        decoded.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            let data = Data(snapshot.utf8)
            guard RendererDiagnosticsSnapshotEnvelope
                .normalizedJSONString(data) != nil,
                  let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
                return nil
            }
            decoded.append(object)
        }
        let payload: [String: Any] = [
            "schema": 1,
            "kind": "ordinary-renderer-diagnostics",
            "generatedAt": ISO8601DateFormatter().string(from: generatedAt),
            "routeFixture": [
                "id": fixtureID,
                "sha256": fixtureSHA256.map {
                    String(format: "%02x", $0)
                }.joined(),
                "mode": "ordinary-ble-1hz",
            ],
            "snapshots": decoded,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
              ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendInt16LE(_ value: Int16) {
        appendUInt16LE(UInt16(bitPattern: value))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func appendInt32LE(_ value: Int32) {
        appendUInt32LE(UInt32(bitPattern: value))
    }
}
