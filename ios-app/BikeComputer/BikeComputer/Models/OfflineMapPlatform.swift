//
//  OfflineMapPlatform.swift
//  BikeComputer
//
//  Backend models for offline map cut-outs.
//

import CoreLocation
import Foundation

struct OfflineMapBounds: Codable, Equatable {
    let minLon: Double
    let minLat: Double
    let maxLon: Double
    let maxLat: Double

    init(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) {
        self.minLon = minLon
        self.minLat = minLat
        self.maxLon = maxLon
        self.maxLat = maxLat
    }

    init(center: CLLocationCoordinate2D, sideLengthKm: Double) {
        let halfSideKm = max(sideLengthKm, 0.1) / 2
        let latDelta = halfSideKm / 111.32
        let lonScale = max(cos(center.latitude * .pi / 180), 0.01)
        let lonDelta = halfSideKm / (111.32 * lonScale)
        self.init(
            minLon: max(center.longitude - lonDelta, -180),
            minLat: max(center.latitude - latDelta, -85.05112878),
            maxLon: min(center.longitude + lonDelta, 180),
            maxLat: min(center.latitude + latDelta, 85.05112878)
        )
    }

    var apiArray: [Double] {
        [minLon, minLat, maxLon, maxLat]
    }
}

struct OfflineMapJobRequest: Encodable, Equatable {
    let mode: String
    let bbox: [Double]?
    let geometry: GeoJSONGeometry?
    let route: GeoJSONGeometry?
    let corridorWidthM: Double?

    static func customBBox(_ bounds: OfflineMapBounds) -> OfflineMapJobRequest {
        OfflineMapJobRequest(
            mode: "custom_bbox",
            bbox: bounds.apiArray,
            geometry: nil,
            route: nil,
            corridorWidthM: nil
        )
    }

    static func customPolygon(ring: [CLLocationCoordinate2D]) -> OfflineMapJobRequest {
        OfflineMapJobRequest(
            mode: "custom_polygon",
            bbox: nil,
            geometry: GeoJSONGeometry.polygon(ring: ring),
            route: nil,
            corridorWidthM: nil
        )
    }

    static func routeCorridor(route: [CLLocationCoordinate2D], widthMeters: Double) -> OfflineMapJobRequest {
        OfflineMapJobRequest(
            mode: "route_corridor",
            bbox: nil,
            geometry: nil,
            route: GeoJSONGeometry.lineString(route),
            corridorWidthM: widthMeters
        )
    }
}

struct GeoJSONGeometry: Codable, Equatable {
    let type: String
    let coordinates: GeoJSONCoordinates

    static func polygon(ring: [CLLocationCoordinate2D]) -> GeoJSONGeometry {
        var closed = ring
        if let first = ring.first, let last = ring.last,
           first.latitude != last.latitude || first.longitude != last.longitude {
            closed.append(first)
        }
        return GeoJSONGeometry(
            type: "Polygon",
            coordinates: .polygon([closed.map { [$0.longitude, $0.latitude] }])
        )
    }

    static func lineString(_ points: [CLLocationCoordinate2D]) -> GeoJSONGeometry {
        GeoJSONGeometry(
            type: "LineString",
            coordinates: .lineString(points.map { [$0.longitude, $0.latitude] })
        )
    }
}

enum GeoJSONCoordinates: Codable, Equatable {
    case lineString([[Double]])
    case polygon([[[Double]]])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let polygon = try? container.decode([[[Double]]].self) {
            self = .polygon(polygon)
            return
        }
        self = .lineString(try container.decode([[Double]].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .lineString(let points):
            try container.encode(points)
        case .polygon(let rings):
            try container.encode(rings)
        }
    }
}

struct OfflineMapJob: Decodable, Equatable {
    let jobId: String
    let status: String
    let error: String?
    let mapId: String?
    let packPath: String?
    let geometry: OfflineMapJobGeometry?
    let sourceRegion: OfflineMapSourceRegion?

    var isTerminal: Bool {
        ["ready", "failed", "expired", "cancelled"].contains(status)
    }
}

struct OfflineMapJobGeometry: Decodable, Equatable {
    let mode: String
    let bounds: [Double]
    let areaKm2: Double
    let vertexCount: Int
    let routePointCount: Int
}

struct OfflineMapSourceRegion: Decodable, Equatable {
    let id: String
    let name: String
    let provider: String
}

struct OfflineMapDownloadURL: Decodable, Equatable {
    let mapId: String
    let url: String
    let expiresAt: Int
    let expiresInSeconds: Int
}

enum OfflineMapPlatformError: LocalizedError {
    case invalidBaseURL
    case missingMapId
    case missingDownloadURL
    case transferCommandNotSent
    case missingTransferBaseURL
    case deviceSDCardUnavailable
    case mapActivationTimedOut(String)
    case mapActivationFailed(String)
    case transferWiFiJoinFailed(String, String)
    case invalidPack(String)
    case unsupportedPackCompression(String)
    case invalidResponse
    case serverStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Invalid map server URL"
        case .missingMapId:
            return "Map pack is not ready"
        case .missingDownloadURL:
            return "Download URL is not ready"
        case .transferCommandNotSent:
            return "Device did not accept the map transfer command over BLE"
        case .missingTransferBaseURL:
            return "Device map transfer mode is not ready"
        case .deviceSDCardUnavailable:
            return "Device SD card is not mounted"
        case .mapActivationTimedOut(let message):
            return "Map activation could not be confirmed: \(message)"
        case .mapActivationFailed(let message):
            return "Map activation failed: \(message)"
        case .transferWiFiJoinFailed(let ssid, let message):
            return "Could not join device Wi-Fi \(ssid): \(message)"
        case .invalidPack(let message):
            return "Invalid map pack: \(message)"
        case .unsupportedPackCompression(let path):
            return "Map pack entry is compressed and cannot be transferred: \(path)"
        case .invalidResponse:
            return "Map server returned an invalid response"
        case .serverStatus(let status, let body):
            return "Map server returned \(status): \(body)"
        }
    }
}

struct OfflineMapPackEntry: Equatable {
    let path: String
    let offset: UInt64
    let byteCount: Int
}

struct OfflineMapPackManifest: Decodable, Equatable {
    struct Source: Decodable, Equatable {
        let region: String?
        let url: String?
    }

    let mapId: String?
    let displayName: String?
    let source: Source?
}

nonisolated struct MapTransferDeviceStatus: Decodable, Equatable {
    struct TransferError: Decodable, Equatable {
        let code: String?
        let message: String?
    }

    struct Activation: Decodable, Equatable {
        let status: String?
        let sequence: UInt32?
        let sessionId: String?
        let mapId: String?
        let error: TransferError?
    }

    let enabled: Bool?
    let activeMapId: String?
    let activeSessionId: String?
    let activation: Activation?
}

nonisolated struct MapTransferActivationAcknowledgement: Decodable, Equatable {
    let sessionId: String?
    let sequence: UInt32?
}

struct OfflineMapPackArchive {
    let url: URL
    let entries: [OfflineMapPackEntry]

    nonisolated var manifestEntry: OfflineMapPackEntry? {
        entries.first { $0.path == "manifest.json" }
    }

    nonisolated var mapFileEntries: [OfflineMapPackEntry] {
        entries.filter { $0.path.hasPrefix("VECTMAP/") }
    }

    nonisolated init(url: URL) throws {
        self.url = url
        self.entries = try Self.readEntries(url: url)
        guard manifestEntry != nil else {
            throw OfflineMapPlatformError.invalidPack("manifest.json is missing")
        }
        guard !mapFileEntries.isEmpty else {
            throw OfflineMapPlatformError.invalidPack("no VECTMAP files found")
        }
    }

    nonisolated func data(for entry: OfflineMapPackEntry) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.offset)
        let data = try handle.read(upToCount: entry.byteCount) ?? Data()
        guard data.count == entry.byteCount else {
            throw OfflineMapPlatformError.invalidPack("truncated entry \(entry.path)")
        }
        return data
    }

    func manifest() throws -> OfflineMapPackManifest {
        guard let manifestEntry else {
            throw OfflineMapPlatformError.invalidPack("manifest.json is missing")
        }
        return try JSONDecoder().decode(OfflineMapPackManifest.self, from: data(for: manifestEntry))
    }

    private nonisolated static func readEntries(url: URL) throws -> [OfflineMapPackEntry] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else {
            throw OfflineMapPlatformError.invalidPack("file size unavailable")
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset: UInt64 = 0
        var entries: [OfflineMapPackEntry] = []

        while offset + 4 <= fileSize {
            try handle.seek(toOffset: offset)
            let signatureData = try handle.read(upToCount: 4) ?? Data()
            guard signatureData.count == 4 else { break }
            let signature = signatureData.uint32LE(at: 0)
            if signature == 0x0201_4B50 || signature == 0x0605_4B50 {
                break
            }
            guard signature == 0x0403_4B50 else {
                throw OfflineMapPlatformError.invalidPack("unexpected zip header")
            }

            let header = try handle.read(upToCount: 26) ?? Data()
            guard header.count == 26 else {
                throw OfflineMapPlatformError.invalidPack("truncated local header")
            }

            let flags = header.uint16LE(at: 2)
            let compression = header.uint16LE(at: 4)
            let compressedSize = UInt64(header.uint32LE(at: 14))
            let uncompressedSize = UInt64(header.uint32LE(at: 18))
            let nameLength = Int(header.uint16LE(at: 22))
            let extraLength = UInt64(header.uint16LE(at: 24))

            guard flags & 0x0008 == 0 else {
                throw OfflineMapPlatformError.invalidPack("zip data descriptors are unsupported")
            }
            guard compression == 0 else {
                let nameData = try handle.read(upToCount: nameLength) ?? Data()
                let path = String(data: nameData, encoding: .utf8) ?? "unknown"
                throw OfflineMapPlatformError.unsupportedPackCompression(path)
            }
            guard compressedSize == uncompressedSize,
                  compressedSize <= UInt64(Int.max) else {
                throw OfflineMapPlatformError.invalidPack("entry size is invalid")
            }

            let nameData = try handle.read(upToCount: nameLength) ?? Data()
            guard nameData.count == nameLength,
                  let path = String(data: nameData, encoding: .utf8) else {
                throw OfflineMapPlatformError.invalidPack("entry name is invalid")
            }
            guard isSafePackPath(path) else {
                throw OfflineMapPlatformError.invalidPack("unsafe entry path \(path)")
            }

            let dataOffset = offset + 30 + UInt64(nameLength) + extraLength
            guard dataOffset + compressedSize <= fileSize else {
                throw OfflineMapPlatformError.invalidPack("entry extends past end of file")
            }

            if !path.hasSuffix("/") {
                entries.append(OfflineMapPackEntry(
                    path: path,
                    offset: dataOffset,
                    byteCount: Int(compressedSize)
                ))
            }
            offset = dataOffset + compressedSize
        }

        return entries
    }

    private nonisolated static func isSafePackPath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("//"),
              !path.contains("..") else {
            return false
        }
        if path == "manifest.json" ||
            path == "ATTRIBUTION.txt" ||
            path.hasPrefix("LICENSES/") {
            return true
        }
        guard path.hasPrefix("VECTMAP/") else {
            return false
        }
        return path.split(separator: "/").allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && !part.hasPrefix(".")
        }
    }
}

struct MapTransferDeviceClient {
    let baseURL: URL
    var session: URLSession = .shared
    var recoveryRetryNanoseconds: UInt64 = 2_000_000_000

    nonisolated func upload(
        archive: OfflineMapPackArchive,
        sessionId: String,
        progress: @escaping @MainActor (_ completed: Int, _ total: Int, _ path: String, _ didUpload: Bool) -> Void
    ) async throws {
        guard let manifest = archive.manifestEntry else {
            throw OfflineMapPlatformError.invalidPack("manifest.json is missing")
        }

        let uploadEntries = [manifest] + archive.mapFileEntries.sorted { $0.path < $1.path }
        for (index, entry) in uploadEntries.enumerated() {
            if try await stagedByteCount(sessionId: sessionId, path: entry.path) == entry.byteCount {
                await progress(index + 1, uploadEntries.count, entry.path, false)
                continue
            }
            let data = try archive.data(for: entry)
            try await put(sessionId: sessionId, path: entry.path, data: data)
            await progress(index + 1, uploadEntries.count, entry.path, true)
        }
    }

    nonisolated func activate(sessionId: String) async throws -> UInt32? {
        var request = URLRequest(url: Self.uploadURL(
            baseURL: baseURL,
            sessionId: sessionId,
            relativePath: "activate"
        ))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        let data = try await send(request: request, data: nil)
        let acknowledgement = try JSONDecoder().decode(
            MapTransferActivationAcknowledgement.self,
            from: data
        )
        guard acknowledgement.sessionId == nil ||
                acknowledgement.sessionId == sessionId else {
            throw OfflineMapPlatformError.invalidResponse
        }
        return acknowledgement.sequence
    }

    nonisolated func status() async throws -> MapTransferDeviceStatus {
        var request = URLRequest(url: Self.statusURL(baseURL: baseURL))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 2
        let data = try await send(request: request, data: nil)
        return try JSONDecoder().decode(MapTransferDeviceStatus.self, from: data)
    }

    private nonisolated func put(sessionId: String, path: String, data: Data) async throws {
        var request = URLRequest(url: Self.uploadURL(
            baseURL: baseURL,
            sessionId: sessionId,
            relativePath: path
        ))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        _ = try await send(request: request, data: data)
    }

    private nonisolated func stagedByteCount(sessionId: String, path: String) async throws -> Int? {
        let toleratesRecovery = path == "manifest.json"
        let recoveryDeadline = Date().addingTimeInterval(10 * 60)
        var observedRecoveryResponse = false
        var blindTransportRetries = 0
        while true {
            var request = URLRequest(url: Self.uploadURL(
                baseURL: baseURL,
                sessionId: sessionId,
                relativePath: path
            ))
            request.httpMethod = "HEAD"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 3

            do {
                let response = try await session.data(for: request)
                guard let http = response.1 as? HTTPURLResponse else {
                    throw OfflineMapPlatformError.invalidResponse
                }
                if http.statusCode == 404 {
                    return nil
                }
                if toleratesRecovery,
                   (http.statusCode == 409 || http.statusCode == 503),
                   Date() < recoveryDeadline {
                    observedRecoveryResponse = true
                    try await Task.sleep(nanoseconds: recoveryRetryNanoseconds)
                    continue
                }
                guard 200..<300 ~= http.statusCode else {
                    return nil
                }
                guard let value = http.value(forHTTPHeaderField: "Content-Length"),
                      let count = Int(value) else {
                    return nil
                }
                return count
            } catch {
                let urlError = error as? URLError
                let isAmbiguousRecoveryWait = urlError?.code == .timedOut ||
                    urlError?.code == .networkConnectionLost
                if isAmbiguousRecoveryWait && !observedRecoveryResponse {
                    blindTransportRetries += 1
                }
                guard toleratesRecovery,
                      isAmbiguousRecoveryWait,
                      (observedRecoveryResponse || blindTransportRetries <= 2),
                      Date() < recoveryDeadline else {
                    throw error
                }
                try await Task.sleep(nanoseconds: recoveryRetryNanoseconds)
            }
        }
    }

    private nonisolated func send(request: URLRequest, data: Data?) async throws -> Data {
        let response: (Data, URLResponse)
        if let data {
            response = try await session.upload(for: request, from: data)
        } else {
            response = try await session.data(for: request)
        }
        guard let http = response.1 as? HTTPURLResponse else {
            throw OfflineMapPlatformError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let bodyText = String(data: response.0, encoding: .utf8) ?? ""
            throw OfflineMapPlatformError.serverStatus(http.statusCode, bodyText)
        }
        return response.0
    }

    nonisolated static func uploadURL(baseURL: URL, sessionId: String, relativePath: String) -> URL {
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedSegments = (["map-transfer", "sessions", sessionId] + relativePath.split(separator: "/").map(String.init))
            .map(percentEncodedPathComponent)
            .joined(separator: "/")
        return URL(string: "\(base)/\(encodedSegments)")!
    }

    nonisolated static func statusURL(baseURL: URL) -> URL {
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/map-transfer/status")!
    }

    private nonisolated static func percentEncodedPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/+?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

struct OfflineMapPlatformClient {
    let baseURL: URL
    let apiToken: String?
    var session: URLSession = .shared

    init(baseURL: URL, apiToken: String? = nil) {
        self.baseURL = baseURL
        self.apiToken = apiToken?.isEmpty == true ? nil : apiToken
    }

    func createJob(_ jobRequest: OfflineMapJobRequest) async throws -> OfflineMapJob {
        try await send(path: "/v1/map-jobs", method: "POST", body: jobRequest)
    }

    func job(id: String) async throws -> OfflineMapJob {
        try await send(path: "/v1/map-jobs/\(id)", method: "GET", body: Optional<Data>.none)
    }

    func downloadURL(mapId: String) async throws -> URL {
        let response: OfflineMapDownloadURL = try await send(
            path: "/v1/map-packs/\(mapId)/download-url",
            method: "POST",
            body: Optional<Data>.none
        )
        return try absoluteURL(for: response.url, baseURL: baseURL)
    }

    static func makeCreateJobURLRequest(
        baseURL: URL,
        apiToken: String?,
        jobRequest: OfflineMapJobRequest
    ) throws -> URLRequest {
        var request = URLRequest(url: try endpointURL(baseURL: baseURL, path: "/v1/map-jobs"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiToken, !apiToken.isEmpty {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder.offlineMap.encode(jobRequest)
        return request
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body?
    ) async throws -> Response {
        var request = URLRequest(url: try Self.endpointURL(baseURL: baseURL, path: path))
        request.httpMethod = method
        if let apiToken {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder.offlineMap.encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OfflineMapPlatformError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw OfflineMapPlatformError.serverStatus(http.statusCode, bodyText)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private static func endpointURL(baseURL: URL, path: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw OfflineMapPlatformError.invalidBaseURL
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url else {
            throw OfflineMapPlatformError.invalidBaseURL
        }
        return url
    }

    private func absoluteURL(for value: String, baseURL: URL) throws -> URL {
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute
        }
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL else {
            throw OfflineMapPlatformError.invalidResponse
        }
        return url
    }
}

private extension Data {
    nonisolated func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    nonisolated func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }
}

extension JSONEncoder {
    static var offlineMap: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
