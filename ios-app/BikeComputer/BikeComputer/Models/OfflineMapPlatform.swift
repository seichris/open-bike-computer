//
//  OfflineMapPlatform.swift
//  BikeComputer
//
//  Backend models for offline map cut-outs.
//

import CoreLocation
import CryptoKit
import Foundation

nonisolated struct MapStreamAppBuildIdentity: Codable, Equatable {
    let schemaVersion: Int
    let build: String
    let gitSha: String
    let componentSha256: String

    var isReleaseGrade: Bool {
        schemaVersion == 1 &&
            build.range(
                of: "^[0-9]{1,18}(?:\\.[0-9]{1,18}){0,2}$",
                options: .regularExpression
            ) != nil &&
            gitSha.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil &&
            componentSha256.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            ) != nil
    }

    static var current: MapStreamAppBuildIdentity? {
        guard let url = Bundle.main.url(
            forResource: "MapStreamBuildIdentity",
            withExtension: "json"
        ), let data = try? Data(contentsOf: url),
           let identity = try? JSONDecoder().decode(Self.self, from: data),
           identity.isReleaseGrade else {
            return nil
        }
        return identity
    }
}

nonisolated enum MapStreamAppArtifactCompatibilityPolicy {
    // Stream artifacts are normally pinned to the exact app build that requested
    // them. Keep exceptions exact and reviewed so an app update can resume a
    // previously started transfer without accepting arbitrary older artifacts.
    static let resumablePredecessorIdentities = [
        MapStreamAppBuildIdentity(
            schemaVersion: 1,
            build: "202607132210",
            gitSha: "4ee3aa43dd3026917ceca52c4779438867ee0e7a",
            componentSha256: "271c2d9d17d4430548a46d5ea9ae677862ecf08c57b8e62f5a48c22ae8656002"
        )
    ]
}

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
    let clientInstallationId: String?
    let clientRequestId: String?
    let installOnDevice: Bool?

    static func customBBox(_ bounds: OfflineMapBounds) -> OfflineMapJobRequest {
        OfflineMapJobRequest(
            mode: "custom_bbox",
            bbox: bounds.apiArray,
            geometry: nil,
            route: nil,
            corridorWidthM: nil,
            clientInstallationId: nil,
            clientRequestId: nil,
            installOnDevice: nil
        )
    }

    static func customPolygon(ring: [CLLocationCoordinate2D]) -> OfflineMapJobRequest {
        OfflineMapJobRequest(
            mode: "custom_polygon",
            bbox: nil,
            geometry: GeoJSONGeometry.polygon(ring: ring),
            route: nil,
            corridorWidthM: nil,
            clientInstallationId: nil,
            clientRequestId: nil,
            installOnDevice: nil
        )
    }

    static func routeCorridor(route: [CLLocationCoordinate2D], widthMeters: Double) -> OfflineMapJobRequest {
        OfflineMapJobRequest(
            mode: "route_corridor",
            bbox: nil,
            geometry: nil,
            route: GeoJSONGeometry.lineString(route),
            corridorWidthM: widthMeters,
            clientInstallationId: nil,
            clientRequestId: nil,
            installOnDevice: nil
        )
    }

    func identified(
        clientInstallationId: String,
        clientRequestId: String,
        installOnDevice: Bool
    ) -> OfflineMapJobRequest {
        OfflineMapJobRequest(
            mode: mode,
            bbox: bbox,
            geometry: geometry,
            route: route,
            corridorWidthM: corridorWidthM,
            clientInstallationId: clientInstallationId,
            clientRequestId: clientRequestId,
            installOnDevice: installOnDevice
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
    let createdAt: String?
    let error: String?
    let mapId: String?
    let packPath: String?
    let geometry: OfflineMapJobGeometry?
    let sourceRegion: OfflineMapSourceRegion?
    let progress: OfflineMapJobProgress?
    let clientInstallationId: String?
    let clientRequestId: String?
    let installOnDevice: Bool?
    let artifacts: [OfflineMapArtifact]?
    let userLabel: String?
    let reuseStrategy: String?
    let downloadCount: Int?
    let firstDownloadedAt: String?
    let lastDownloadedAt: String?

    var isTerminal: Bool {
        ["ready", "failed", "expired", "cancelled"].contains(status)
    }
}

nonisolated struct OfflineMapArtifact: Codable, Equatable {
    static let bikeMapStreamFormat = "bike-map-stream-v1"
    static let storedZipFormat = "zip-stored-v1"

    let format: String
    let mediaType: String
    let filename: String
    let objectKey: String
    let bytes: Int64
    let sha256: String
    let manifestReceipt: String?
    let signedManifestReceipt: String?
    let signatureKeyId: String?
    let signatureKeySha256: String?
    let producerBuildSha256: String?
    let producerImageDigest: String?
    let requiredIosBuild: String?
    let requiredIosGitSha: String?
    let requiredIosBuildSha256: String?
    let requiredFirmwareVersion: String?
    let requiredFirmwareBuild: UInt32?
    let requiredFirmwareGitSha: String?

    init(
        format: String,
        mediaType: String,
        filename: String,
        objectKey: String,
        bytes: Int64,
        sha256: String,
        manifestReceipt: String? = nil,
        signedManifestReceipt: String? = nil,
        signatureKeyId: String? = nil,
        signatureKeySha256: String? = nil,
        producerBuildSha256: String? = nil,
        producerImageDigest: String? = nil,
        requiredIosBuild: String? = nil,
        requiredIosGitSha: String? = nil,
        requiredIosBuildSha256: String? = nil,
        requiredFirmwareVersion: String? = nil,
        requiredFirmwareBuild: UInt32? = nil,
        requiredFirmwareGitSha: String? = nil
    ) {
        self.format = format
        self.mediaType = mediaType
        self.filename = filename
        self.objectKey = objectKey
        self.bytes = bytes
        self.sha256 = sha256
        self.manifestReceipt = manifestReceipt
        self.signedManifestReceipt = signedManifestReceipt
        self.signatureKeyId = signatureKeyId
        self.signatureKeySha256 = signatureKeySha256
        self.producerBuildSha256 = producerBuildSha256
        self.producerImageDigest = producerImageDigest
        self.requiredIosBuild = requiredIosBuild
        self.requiredIosGitSha = requiredIosGitSha
        self.requiredIosBuildSha256 = requiredIosBuildSha256
        self.requiredFirmwareVersion = requiredFirmwareVersion
        self.requiredFirmwareBuild = requiredFirmwareBuild
        self.requiredFirmwareGitSha = requiredFirmwareGitSha
    }

    var isBikeMapStream: Bool { format == Self.bikeMapStreamFormat }
    var isStoredZip: Bool { format == Self.storedZipFormat }
}

nonisolated struct OfflineMapArtifactDownloadURL: Decodable, Equatable {
    let format: String
    let mediaType: String
    let filename: String
    let objectKey: String
    let bytes: Int64
    let sha256: String
    let manifestReceipt: String?
    let signedManifestReceipt: String?
    let signatureKeyId: String?
    let signatureKeySha256: String?
    let producerBuildSha256: String?
    let producerImageDigest: String?
    let requiredIosBuild: String?
    let requiredIosGitSha: String?
    let requiredIosBuildSha256: String?
    let requiredFirmwareVersion: String?
    let requiredFirmwareBuild: UInt32?
    let requiredFirmwareGitSha: String?
    let url: String
    let expiresAt: Int
    let expiresInSeconds: Int
}

nonisolated struct OfflineMapInstallationCredential: Codable, Equatable {
    let clientInstallationId: String
    let clientInstallationToken: String
}

nonisolated struct OfflineMapDisplayNameRequest: Encodable, Equatable {
    let displayName: String
}

nonisolated struct OfflineMapDownloadReceiptRequest: Encodable, Equatable {
    let receiptId: String
    let artifactFormat: String
    let sha256: String?
    let bytes: Int64
}

nonisolated struct OfflineMapInventoryMutationResponse: Decodable, Equatable {
    let jobId: String
    let userLabel: String?
    let downloadCount: Int
    let firstDownloadedAt: String?
    let lastDownloadedAt: String?
}

struct OfflineMapJobsResponse: Decodable, Equatable {
    let jobs: [OfflineMapJob]
}

enum OfflineMapJobRecoverySelector {
    static func select(
        jobs: [OfflineMapJob],
        clientInstallationId: String,
        excludedJobIds: Set<String> = []
    ) -> OfflineMapJob? {
        jobs
            .filter { job in
                guard job.clientInstallationId == clientInstallationId else { return false }
                guard !excludedJobIds.contains(job.jobId) else { return false }
                return job.status == "ready" ? job.mapId != nil : !job.isTerminal
            }
            .max { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
    }
}

struct SavedMapRenameCommit: Equatable {
    let filename: String
    let proposedName: String
}

struct SavedMapRenameInteraction: Equatable {
    private(set) var editingFilename: String?
    private(set) var draftName = ""

    mutating func begin(filename: String, currentName: String) -> SavedMapRenameCommit? {
        let previous = finish()
        editingFilename = filename
        draftName = currentName
        return previous
    }

    mutating func updateDraft(_ value: String) {
        draftName = value
    }

    mutating func finishIfFocusMoved(to focusedFilename: String?) -> SavedMapRenameCommit? {
        guard focusedFilename != editingFilename else { return nil }
        return finish()
    }

    mutating func finish() -> SavedMapRenameCommit? {
        guard let editingFilename else { return nil }
        let commit = SavedMapRenameCommit(
            filename: editingFilename,
            proposedName: draftName
        )
        self.editingFilename = nil
        draftName = ""
        return commit
    }
}

struct OfflineMapJobProgress: Decodable, Equatable {
    let completedBlocks: Int
    let totalBlocks: Int

    var fraction: Double {
        guard totalBlocks > 0 else { return 0 }
        return min(max(Double(completedBlocks) / Double(totalBlocks), 0), 1)
    }

    var percentage: Int {
        Int((fraction * 100).rounded())
    }
}

enum OfflineMapProgressPresentation {
    static func value(job: OfflineMapJob?, downloadProgress: Double) -> Double? {
        if job?.status == "converting_features", let progress = job?.progress {
            return progress.fraction
        }
        return downloadProgress > 0 ? downloadProgress : nil
    }
}

enum OfflineMapDownloadingSectionPresentation {
    static func isVisible(
        isBusy: Bool,
        hasPendingJob: Bool,
        hasPendingActivation: Bool,
        errorMessage: String?
    ) -> Bool {
        isBusy || hasPendingJob || hasPendingActivation || errorMessage != nil
    }
}

struct MapActivationProgressPresentation: Equatable {
    let step: Int
    let stepCount: Int
    let percentage: Int

    var fraction: Double {
        Double(percentage) / 100
    }

    var label: String {
        "Step \(step)/\(stepCount) - \(percentage)%"
    }

    static func make(
        status: String?,
        step: Int?,
        stepCount: Int?,
        percentage: Int?
    ) -> Self? {
        guard let status,
              ["receiving", "finalizing", "ready", "activating"]
                .contains(status),
              let step,
              let stepCount,
              let percentage,
              step > 0,
              stepCount >= step else {
            return nil
        }
        return Self(
            step: step,
            stepCount: stepCount,
            percentage: min(max(percentage, 0), 100)
        )
    }
}

nonisolated enum MapUploadProgressReconciler {
    static func percentage(
        retryTransportPercentage: Int?,
        durableDevicePercentage: Int?
    ) -> Int? {
        [retryTransportPercentage, durableDevicePercentage]
            .compactMap { $0 }
            .map { min(max($0, 0), 100) }
            .max()
    }
}

enum OfflineMapAutomaticRecoveryTrigger {
    static func shouldResume(
        hasPendingInstall: Bool,
        isBusy: Bool,
        isConnected: Bool,
        isNavigationReady: Bool
    ) -> Bool {
        hasPendingInstall && !isBusy && isConnected && isNavigationReady
    }
}

nonisolated enum PausedMapUploadResumePolicy {
    static func isAvailable(
        lastTransferOutcome: String,
        lastTransferMapID: String,
        candidateMapID: String,
        lastDeviceState: String?,
        statusMessage: String = ""
    ) -> Bool {
        guard lastTransferOutcome == "unconfirmed",
              !lastTransferMapID.isEmpty,
              lastTransferMapID == candidateMapID else {
            return false
        }
        return lastDeviceState == "paused" ||
            lastDeviceState == "idle" ||
            statusMessage == "Map upload paused. Tap Upload to resume." ||
            statusMessage == "Activation paused. Tap Upload to resume."
    }
}

struct OfflineMapJobGeometry: Decodable, Equatable {
    let mode: String
    let bounds: [Double]
    let areaKm2: Double
    let vertexCount: Int
    let routePointCount: Int
}

enum OfflineMapPreparationTimeEstimate {
    static func description(for areaKm2: Double) -> String {
        switch max(areaKm2, 0) {
        case ..<10:
            return "Usually under a minute"
        case ..<1_000:
            return "Usually a few minutes"
        case ..<15_000:
            return "May take 15–90 minutes"
        default:
            return "May take several hours"
        }
    }
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

nonisolated enum OfflineMapPlatformError: LocalizedError {
    case invalidBaseURL
    case missingMapId
    case missingDownloadURL
    case transferCommandNotSent
    case missingTransferBaseURL
    case deviceSDCardUnavailable
    case firmwareMapStreamUnsupported
    case backgroundMapUploadInProgress
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
        case .firmwareMapStreamUnsupported:
            return "This saved map needs newer device firmware, and no compatible legacy map artifact is available."
        case .backgroundMapUploadInProgress:
            return "Another map upload is already in progress. Wait for it to finish before transferring a different map."
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
    let crc32: UInt32
}

nonisolated struct OfflineMapPackManifest: Decodable, Equatable {
    struct File: Decodable, Equatable {
        let path: String
        let bytes: Int
        let sha256: String
    }

    struct Source: Decodable, Equatable {
        let region: String?
        let url: String?
    }

    struct Preview: Decodable, Equatable {
        let type: String
        let path: String
        let width: Int
        let height: Int
        let background: String?
        let dataBase64: String?
    }

    let mapId: String?
    let displayName: String?
    let source: Source?
    let preview: Preview?
    let files: [File]?

    private enum CodingKeys: String, CodingKey {
        case mapId
        case displayName
        case source
        case preview
        case files
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mapId = try container.decodeIfPresent(String.self, forKey: .mapId)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        source = try container.decodeIfPresent(Source.self, forKey: .source)
        preview = try? container.decode(Preview.self, forKey: .preview)
        files = try container.decodeIfPresent([File].self, forKey: .files)
    }
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
        let step: Int?
        let steps: Int?
        let progress: Int?
        let error: TransferError?
    }

    let enabled: Bool?
    let activeMapId: String?
    let activeSessionId: String?
    let activation: Activation?
    let protocols: [Int]?
    let streamFormatVersions: [Int]?
    let streamTrust: [String]?
    let firmwareVersion: String?
    let firmwareBuild: UInt32?
    let firmwareGitSha: String?

    var supportsBikeMapStreamV1: Bool {
        protocols?.contains(2) == true &&
            streamFormatVersions?.contains(1) == true
    }

    func supportsBikeMapStreamV1(trustCapability: String) -> Bool {
        supportsBikeMapStreamV1 && streamTrust?.contains(trustCapability) == true
    }
}

nonisolated struct MapTransferActivationAcknowledgement: Decodable, Equatable {
    let sessionId: String?
    let sequence: UInt32?
}

nonisolated enum MapInstallProtocolSelection: Equatable {
    case streamV2
    case archiveV1
    case legacyArtifactRequired
}

nonisolated enum MapInstallProtocolSelector {
    static func select(
        isBikeMapStream: Bool,
        signatureTrustCapability: String? = nil,
        requiredIosBuild: String? = nil,
        requiredIosGitSha: String? = nil,
        requiredIosBuildSha256: String? = nil,
        currentIosBuild: String? = nil,
        currentIosGitSha: String? = nil,
        currentIosBuildSha256: String? = nil,
        compatibleArtifactAppIdentities: [MapStreamAppBuildIdentity] = [],
        requiredFirmwareVersion: String? = nil,
        requiredFirmwareBuild: UInt32? = nil,
        requiredFirmwareGitSha: String? = nil,
        deviceStatus: MapTransferDeviceStatus
    ) -> MapInstallProtocolSelection {
        guard isBikeMapStream else { return .archiveV1 }
        guard let signatureTrustCapability else {
            return .legacyArtifactRequired
        }
        guard deviceStatus.supportsBikeMapStreamV1(
            trustCapability: signatureTrustCapability
        ) else {
            return .legacyArtifactRequired
        }
        let requirements = (
            requiredIosBuild,
            requiredIosGitSha,
            requiredIosBuildSha256,
            requiredFirmwareVersion,
            requiredFirmwareBuild,
            requiredFirmwareGitSha
        )
        guard let requiredAppBuild = requirements.0,
              let requiredAppGitSHA = requirements.1,
              let requiredAppBuildSHA256 = requirements.2,
              let currentAppBuild = currentIosBuild,
              let currentAppGitSHA = currentIosGitSha,
              let currentAppBuildSHA256 = currentIosBuildSha256 else {
            return .legacyArtifactRequired
        }
        let requiredAppIdentity = MapStreamAppBuildIdentity(
            schemaVersion: 1,
            build: requiredAppBuild,
            gitSha: requiredAppGitSHA,
            componentSha256: requiredAppBuildSHA256
        )
        let currentAppIdentity = MapStreamAppBuildIdentity(
            schemaVersion: 1,
            build: currentAppBuild,
            gitSha: currentAppGitSHA,
            componentSha256: currentAppBuildSHA256
        )
        guard requiredAppIdentity.isReleaseGrade,
              currentAppIdentity.isReleaseGrade,
              requiredAppIdentity == currentAppIdentity ||
                  compatibleArtifactAppIdentities.contains(requiredAppIdentity) else {
            return .legacyArtifactRequired
        }
        let deviceRequirements = (requirements.3, requirements.4, requirements.5)
        if deviceRequirements.0 == nil && deviceRequirements.1 == nil &&
            deviceRequirements.2 == nil {
            return .streamV2
        }
        guard let requiredVersion = deviceRequirements.0,
              let requiredBuild = deviceRequirements.1,
              let requiredGitSHA = deviceRequirements.2,
              deviceStatus.firmwareVersion == requiredVersion,
              deviceStatus.firmwareBuild == requiredBuild,
              deviceStatus.firmwareGitSha == requiredGitSHA else {
            return .legacyArtifactRequired
        }
        return .streamV2
    }
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

    nonisolated func manifest() throws -> OfflineMapPackManifest {
        guard let manifestEntry else {
            throw OfflineMapPlatformError.invalidPack("manifest.json is missing")
        }
        return try JSONDecoder().decode(OfflineMapPackManifest.self, from: data(for: manifestEntry))
    }

    nonisolated func previewImageData() -> Data? {
        guard let manifest = try? manifest(),
              let preview = OfflineMapPackPreviewReader.validPreview(manifest.preview) else {
            return nil
        }
        if let entry = entries.first(where: { $0.path == preview.path }),
           entry.byteCount <= OfflineMapPackPreviewReader.maximumImageBytes,
           let data = try? data(for: entry),
           OfflineMapPackPreviewReader.isValidPNG(
               data,
               expectedWidth: preview.width,
               expectedHeight: preview.height
           ) {
            return data
        }
        return OfflineMapPackPreviewReader.inlineImageData(preview)
    }

    nonisolated func validate(expectedMapId: String) throws {
        try Task.checkCancellation()
        let manifest = try manifest()
        guard manifest.mapId == expectedMapId else {
            throw OfflineMapPlatformError.invalidPack(
                "manifest mapId \(manifest.mapId ?? "missing") does not match \(expectedMapId)"
            )
        }
        guard let files = manifest.files, !files.isEmpty else {
            throw OfflineMapPlatformError.invalidPack("manifest contains no file hashes")
        }
        let declaredPaths = Set(files.map(\.path))
        let archivePaths = Set(mapFileEntries.map(\.path))
        guard declaredPaths.count == files.count,
              archivePaths.count == mapFileEntries.count,
              declaredPaths == archivePaths else {
            throw OfflineMapPlatformError.invalidPack("manifest file list does not match the archive")
        }
        let entriesByPath = Dictionary(uniqueKeysWithValues: mapFileEntries.map { ($0.path, $0) })
        for file in files {
            try Task.checkCancellation()
            guard let entry = entriesByPath[file.path], file.bytes == entry.byteCount else {
                throw OfflineMapPlatformError.invalidPack("file size mismatch for \(file.path)")
            }
            let actualHash = try sha256Hex(for: entry)
            guard file.sha256.count == 64,
                  file.sha256.allSatisfy({ $0.isHexDigit }),
                  actualHash == file.sha256.lowercased() else {
                throw OfflineMapPlatformError.invalidPack("file hash mismatch for \(file.path)")
            }
        }
    }

    private nonisolated func sha256Hex(for entry: OfflineMapPackEntry) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.offset)
        var remaining = entry.byteCount
        var hasher = SHA256()
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(remaining, 1_048_576)) ?? Data()
            guard !chunk.isEmpty else {
                throw OfflineMapPlatformError.invalidPack("truncated entry \(entry.path)")
            }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
            let crc32 = header.uint32LE(at: 10)
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
                    byteCount: Int(compressedSize),
                    crc32: crc32
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
            path == "preview.png" ||
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

nonisolated enum OfflineMapPackCompatibilityArchive {
    private static let filenamePrefix = "bike-map-device-"
    private static let activePathsLock = NSLock()
    nonisolated(unsafe) private static var activePaths: Set<String> = []

    private struct CentralDirectoryEntry {
        let name: Data
        let byteCount: UInt32
        let crc32: UInt32
        let localHeaderOffset: UInt32
    }

    static func make(from archive: OfflineMapPackArchive) throws -> URL {
        let entries = archive.entries.filter { $0.path != "preview.png" }
        guard entries.contains(where: { $0.path == "manifest.json" }),
              entries.contains(where: { $0.path.hasPrefix("VECTMAP/") }),
              Set(entries.map(\.path)).count == entries.count,
              entries.count <= Int(UInt16.max) else {
            throw OfflineMapPlatformError.invalidPack(
                "compatibility archive has invalid entries"
            )
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filenamePrefix)\(UUID().uuidString).zip")
        activePathsLock.lock()
        let created = FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil
        )
        if created {
            activePaths.insert(outputURL.standardizedFileURL.path)
        }
        activePathsLock.unlock()
        guard created else {
            throw OfflineMapPlatformError.invalidPack(
                "compatibility archive could not be created"
            )
        }

        do {
            let input = try FileHandle(forReadingFrom: archive.url)
            let output = try FileHandle(forWritingTo: outputURL)
            defer {
                try? input.close()
                try? output.close()
            }

            var outputOffset: UInt64 = 0
            var directoryEntries: [CentralDirectoryEntry] = []
            directoryEntries.reserveCapacity(entries.count)

            for entry in entries {
                try Task.checkCancellation()
                let name = Data(entry.path.utf8)
                guard !name.isEmpty,
                      name.count <= Int(UInt16.max),
                      entry.byteCount >= 0,
                      UInt64(entry.byteCount) <= UInt64(UInt32.max),
                      outputOffset <= UInt64(UInt32.max) else {
                    throw OfflineMapPlatformError.invalidPack(
                        "compatibility archive entry is too large"
                    )
                }

                let byteCount = UInt32(entry.byteCount)
                var localHeader = Data()
                appendUInt32LE(0x0403_4B50, to: &localHeader)
                appendUInt16LE(20, to: &localHeader)
                appendUInt16LE(0, to: &localHeader)
                appendUInt16LE(0, to: &localHeader)
                appendUInt16LE(0, to: &localHeader)
                appendUInt16LE(0, to: &localHeader)
                appendUInt32LE(entry.crc32, to: &localHeader)
                appendUInt32LE(byteCount, to: &localHeader)
                appendUInt32LE(byteCount, to: &localHeader)
                appendUInt16LE(UInt16(name.count), to: &localHeader)
                appendUInt16LE(0, to: &localHeader)
                try output.write(contentsOf: localHeader)
                try output.write(contentsOf: name)

                let localHeaderOffset = UInt32(outputOffset)
                outputOffset += UInt64(localHeader.count + name.count)
                try input.seek(toOffset: entry.offset)
                var remaining = entry.byteCount
                while remaining > 0 {
                    try Task.checkCancellation()
                    let chunk = try input.read(
                        upToCount: min(remaining, 1_048_576)
                    ) ?? Data()
                    guard !chunk.isEmpty else {
                        throw OfflineMapPlatformError.invalidPack(
                            "truncated entry \(entry.path)"
                        )
                    }
                    try output.write(contentsOf: chunk)
                    remaining -= chunk.count
                    outputOffset += UInt64(chunk.count)
                }

                directoryEntries.append(CentralDirectoryEntry(
                    name: name,
                    byteCount: byteCount,
                    crc32: entry.crc32,
                    localHeaderOffset: localHeaderOffset
                ))
            }

            guard outputOffset <= UInt64(UInt32.max) else {
                throw OfflineMapPlatformError.invalidPack(
                    "compatibility archive is too large"
                )
            }
            let directoryOffset = UInt32(outputOffset)
            for entry in directoryEntries {
                try Task.checkCancellation()
                var centralHeader = Data()
                appendUInt32LE(0x0201_4B50, to: &centralHeader)
                appendUInt16LE(0x0314, to: &centralHeader)
                appendUInt16LE(20, to: &centralHeader)
                appendUInt16LE(0, to: &centralHeader)
                appendUInt16LE(0, to: &centralHeader)
                appendUInt16LE(0, to: &centralHeader)
                appendUInt16LE(0, to: &centralHeader)
                appendUInt32LE(entry.crc32, to: &centralHeader)
                appendUInt32LE(entry.byteCount, to: &centralHeader)
                appendUInt32LE(entry.byteCount, to: &centralHeader)
                appendUInt16LE(UInt16(entry.name.count), to: &centralHeader)
                appendUInt16LE(0, to: &centralHeader)
                appendUInt16LE(0, to: &centralHeader)
                appendUInt16LE(0, to: &centralHeader)
                appendUInt16LE(0, to: &centralHeader)
                appendUInt32LE(UInt32(0o100644) << 16, to: &centralHeader)
                appendUInt32LE(entry.localHeaderOffset, to: &centralHeader)
                try output.write(contentsOf: centralHeader)
                try output.write(contentsOf: entry.name)
                outputOffset += UInt64(centralHeader.count + entry.name.count)
            }

            let directorySize = outputOffset - UInt64(directoryOffset)
            guard directorySize <= UInt64(UInt32.max),
                  outputOffset <= UInt64(UInt32.max) else {
                throw OfflineMapPlatformError.invalidPack(
                    "compatibility archive directory is too large"
                )
            }
            var endRecord = Data()
            appendUInt32LE(0x0605_4B50, to: &endRecord)
            appendUInt16LE(0, to: &endRecord)
            appendUInt16LE(0, to: &endRecord)
            appendUInt16LE(UInt16(directoryEntries.count), to: &endRecord)
            appendUInt16LE(UInt16(directoryEntries.count), to: &endRecord)
            appendUInt32LE(UInt32(directorySize), to: &endRecord)
            appendUInt32LE(directoryOffset, to: &endRecord)
            appendUInt16LE(0, to: &endRecord)
            try output.write(contentsOf: endRecord)
            try output.synchronize()
        } catch {
            remove(outputURL)
            throw error
        }
        return outputURL
    }

    static func remove(_ url: URL) {
        activePathsLock.lock()
        activePaths.remove(url.standardizedFileURL.path)
        activePathsLock.unlock()
        try? FileManager.default.removeItem(at: url)
    }

    static func removeOrphans() {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
        let candidates = (try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        activePathsLock.lock()
        let protectedPaths = activePaths
        activePathsLock.unlock()
        for candidate in candidates where
            candidate.lastPathComponent.hasPrefix(filenamePrefix) &&
            candidate.pathExtension.lowercased() == "zip" &&
            !protectedPaths.contains(candidate.standardizedFileURL.path) {
            try? fileManager.removeItem(at: candidate)
        }
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8(value >> 8))
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }
}

nonisolated enum OfflineMapPackPreviewReader {
    static let maximumImageBytes = 512 * 1024
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    static func imageData(for packURL: URL) -> Data? {
        switch packURL.pathExtension.lowercased() {
        case "zip":
            return try? OfflineMapPackArchive(url: packURL).previewImageData()
        case "bmap":
            guard let manifestData = streamManifestData(for: packURL) else { return nil }
            return imageData(fromManifestData: manifestData)
        default:
            return nil
        }
    }

    static func imageData(fromManifestData data: Data) -> Data? {
        guard data.count <= BikeMapStreamFormat.maximumManifestBytes,
              let manifest = try? JSONDecoder().decode(OfflineMapPackManifest.self, from: data),
              let preview = validPreview(manifest.preview) else {
            return nil
        }
        return inlineImageData(preview)
    }

    static func validPreview(
        _ preview: OfflineMapPackManifest.Preview?
    ) -> OfflineMapPackManifest.Preview? {
        guard let preview,
              preview.type == "boundary-png",
              preview.path == "preview.png",
              (1...512).contains(preview.width),
              (1...512).contains(preview.height) else {
            return nil
        }
        return preview
    }

    static func inlineImageData(_ preview: OfflineMapPackManifest.Preview) -> Data? {
        guard let encoded = preview.dataBase64,
              encoded.utf8.count <= maximumImageBytes * 2,
              let data = Data(base64Encoded: encoded),
              isValidPNG(
                  data,
                  expectedWidth: preview.width,
                  expectedHeight: preview.height
              ) else {
            return nil
        }
        return data
    }

    static func isValidPNG(
        _ data: Data,
        expectedWidth: Int,
        expectedHeight: Int
    ) -> Bool {
        guard data.count >= 33,
              data.count <= maximumImageBytes,
              data.starts(with: pngSignature),
              data.uint32BE(at: 8) == 13,
              data.subdata(in: 12..<16) == Data("IHDR".utf8) else {
            return false
        }
        return data.uint32BE(at: 16) == UInt32(expectedWidth) &&
            data.uint32BE(at: 20) == UInt32(expectedHeight)
    }

    private static func streamManifestData(for url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= BikeMapStreamFormat.fixedHeaderBytes,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        do {
            let headerData = try readExactly(
                BikeMapStreamFormat.fixedHeaderBytes,
                from: handle
            )
            let header = try BikeMapStreamFormat.parseHeader(headerData)
            _ = try BikeMapStreamFormat.layout(
                header: header,
                contentBytes: UInt64(fileSize)
            )
            return try readExactly(Int(header.manifestBytes), from: handle)
        } catch {
            return nil
        }
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let chunk = try handle.read(upToCount: count - data.count) ?? Data()
            guard !chunk.isEmpty else {
                throw OfflineMapPlatformError.invalidPack("map preview manifest is truncated")
            }
            data.append(chunk)
        }
        return data
    }
}

struct MapTransferDeviceClient {
    let baseURL: URL
    var sessionToken: String? = nil
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

    nonisolated func uploadArchiveInBackground(
        archiveURL: URL,
        sessionId: String,
        descriptor: BackgroundMapUploadDescriptor,
        onTaskStarted: @escaping @MainActor (Int) -> Void = { _ in },
        progress: @escaping @MainActor (_ completedBytes: Int64, _ totalBytes: Int64) -> Void
    ) async throws {
        let values = try archiveURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize > 0 else {
            throw OfflineMapPlatformError.invalidPack("archive size is unavailable")
        }
        if try await stagedByteCount(sessionId: sessionId, path: "pack.zip") == fileSize {
            await progress(Int64(fileSize), Int64(fileSize))
            return
        }

        let request = Self.archiveUploadRequest(
            baseURL: baseURL,
            sessionId: sessionId,
            sessionToken: sessionToken
        )

#if os(iOS)
        try await BackgroundMapUploadCoordinator.shared.upload(
            request: request,
            fileURL: archiveURL,
            expectedBytes: Int64(fileSize),
            descriptor: descriptor,
            onTaskStarted: onTaskStarted,
            progress: progress
        )
#else
        let response = try await session.upload(for: request, fromFile: archiveURL)
        try Self.validate(response: response.1, body: response.0)
        await progress(Int64(fileSize), Int64(fileSize))
#endif
    }

    nonisolated func uploadStreamInBackground(
        artifact: VerifiedBikeMapArtifact,
        sessionId: String,
        descriptor: BackgroundMapUploadDescriptor,
        onTaskStarted: @escaping @MainActor (Int) -> Void = { _ in },
        progress: @escaping @MainActor (_ completedBytes: Int64, _ totalBytes: Int64) -> Void
    ) async throws {
        let request = Self.streamUploadRequest(
            baseURL: baseURL,
            sessionId: sessionId,
            sessionToken: sessionToken,
            contentLength: artifact.bytes
        )

#if os(iOS)
        try await BackgroundMapUploadCoordinator.shared.upload(
            request: request,
            fileURL: artifact.url,
            expectedBytes: artifact.bytes,
            descriptor: descriptor,
            onTaskStarted: onTaskStarted,
            progress: progress
        )
#else
        await onTaskStarted(0)
        let response = try await session.upload(for: request, fromFile: artifact.url)
        try Self.validate(response: response.1, body: response.0)
        await progress(artifact.bytes, artifact.bytes)
#endif
    }

    nonisolated func activate(sessionId: String) async throws -> UInt32? {
        var request = URLRequest(url: Self.uploadURL(
            baseURL: baseURL,
            sessionId: sessionId,
            relativePath: "activate"
        ))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        authorize(&request)
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
        authorize(&request)
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
        authorize(&request)
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
            authorize(&request)

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
        try Self.validate(response: response.1, body: response.0)
        return response.0
    }

    private nonisolated func authorize(_ request: inout URLRequest) {
        if let sessionToken, !sessionToken.isEmpty {
            request.setValue(sessionToken, forHTTPHeaderField: "X-BikeComputer-Transfer-Token")
        }
    }

    fileprivate nonisolated static func validate(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OfflineMapPlatformError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let bodyText = String(data: body, encoding: .utf8) ?? ""
            throw OfflineMapPlatformError.serverStatus(http.statusCode, bodyText)
        }
    }

    nonisolated static func uploadURL(baseURL: URL, sessionId: String, relativePath: String) -> URL {
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedSegments = (["map-transfer", "sessions", sessionId] + relativePath.split(separator: "/").map(String.init))
            .map(percentEncodedPathComponent)
            .joined(separator: "/")
        return URL(string: "\(base)/\(encodedSegments)")!
    }

    nonisolated static func archiveUploadRequest(
        baseURL: URL,
        sessionId: String,
        sessionToken: String?
    ) -> URLRequest {
        var request = URLRequest(url: uploadURL(
            baseURL: baseURL,
            sessionId: sessionId,
            relativePath: "pack.zip"
        ))
        request.httpMethod = "PUT"
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        if let sessionToken, !sessionToken.isEmpty {
            request.setValue(sessionToken, forHTTPHeaderField: "X-BikeComputer-Transfer-Token")
        }
        return request
    }

    nonisolated static func streamUploadRequest(
        baseURL: URL,
        sessionId: String,
        sessionToken: String?,
        contentLength: Int64
    ) -> URLRequest {
        var request = URLRequest(url: uploadURL(
            baseURL: baseURL,
            sessionId: sessionId,
            relativePath: "install-stream"
        ))
        request.httpMethod = "PUT"
        request.setValue(
            "application/vnd.openbikecomputer.map-stream",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(String(contentLength), forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = 6 * 60 * 60
        if let sessionToken, !sessionToken.isEmpty {
            request.setValue(sessionToken, forHTTPHeaderField: "X-BikeComputer-Transfer-Token")
        }
        return request
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

nonisolated struct BackgroundMapUploadDescriptor: Codable, Equatable {
    let mapID: String
    let sessionID: String
    let protocolVersion: Int
    let streamFormatVersion: Int?
    let artifactFilename: String
    let accessPointSSID: String?

    init(
        mapID: String,
        sessionID: String,
        protocolVersion: Int,
        streamFormatVersion: Int?,
        artifactFilename: String,
        accessPointSSID: String? = nil
    ) {
        self.mapID = mapID
        self.sessionID = sessionID
        self.protocolVersion = protocolVersion
        self.streamFormatVersion = streamFormatVersion
        self.artifactFilename = artifactFilename
        self.accessPointSSID = accessPointSSID
    }
}

nonisolated enum BackgroundMapUploadArbitration: Equatable {
    case begin
    case retainExisting
    case retireExisting
    case blockForOther

    static func evaluate(
        active: [BackgroundMapUploadDescriptor],
        hasUnidentifiedActiveUpload: Bool = false,
        mapID: String,
        sessionID: String,
        resumeRequested: Bool = false
    ) -> Self {
        guard !hasUnidentifiedActiveUpload else { return .blockForOther }
        guard !active.isEmpty else { return .begin }
        guard active.allSatisfy({
            $0.mapID == mapID && $0.sessionID == sessionID
        }) else {
            return .blockForOther
        }
        return resumeRequested ? .retireExisting : .retainExisting
    }
}

nonisolated struct BackgroundMapUploadActivitySnapshot: Equatable {
    let descriptors: [BackgroundMapUploadDescriptor]
    let hasUnidentifiedTask: Bool

    var hasActiveTask: Bool {
        hasUnidentifiedTask || !descriptors.isEmpty
    }
}

nonisolated struct BackgroundMapUploadRecord: Codable, Equatable {
    let taskID: Int
    let descriptor: BackgroundMapUploadDescriptor
    let startedAt: Date
    var completedAt: Date?
    var succeeded: Bool?
    var errorCode: Int?
    var completedBytes: Int64?
    var expectedBytes: Int64?
    var httpStatusCode: Int?

    init(
        taskID: Int,
        descriptor: BackgroundMapUploadDescriptor,
        startedAt: Date,
        completedAt: Date?,
        succeeded: Bool?,
        errorCode: Int?,
        completedBytes: Int64? = nil,
        expectedBytes: Int64? = nil,
        httpStatusCode: Int? = nil
    ) {
        self.taskID = taskID
        self.descriptor = descriptor
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.succeeded = succeeded
        self.errorCode = errorCode
        self.completedBytes = completedBytes
        self.expectedBytes = expectedBytes
        self.httpStatusCode = httpStatusCode
    }

    var percentage: Int? {
        guard let completedBytes,
              let expectedBytes,
              expectedBytes > 0 else { return nil }
        return min(max(Int((Double(completedBytes) / Double(expectedBytes) * 100).rounded()), 0), 100)
    }
}

nonisolated struct BackgroundMapUploadResponseBuffer {
    static let maximumBytes = 4 * 1024

    private(set) var data = Data()

    mutating func append(_ chunk: Data) -> Bool {
        guard chunk.count <= Self.maximumBytes - data.count else { return false }
        data.append(chunk)
        return true
    }
}

nonisolated enum BackgroundMapUploadStateStore {
    private static let key = "offlineMap.backgroundUploads.v1"
    static let didChangeNotification = Notification.Name(
        "OfflineMapBackgroundUploadStateDidChange"
    )

    static func records(defaults: UserDefaults = .standard) -> [BackgroundMapUploadRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([BackgroundMapUploadRecord].self, from: data)) ?? []
    }

    static func markStarted(
        taskID: Int,
        descriptor: BackgroundMapUploadDescriptor,
        expectedBytes: Int64? = nil,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        var values = records(defaults: defaults)
        values.removeAll { $0.taskID == taskID }
        values.append(BackgroundMapUploadRecord(
            taskID: taskID,
            descriptor: descriptor,
            startedAt: now,
            completedAt: nil,
            succeeded: nil,
            errorCode: nil,
            completedBytes: 0,
            expectedBytes: expectedBytes.flatMap { $0 > 0 ? $0 : nil },
            httpStatusCode: nil
        ))
        persist(Array(values.suffix(32)), defaults: defaults)
    }

    static func markProgress(
        taskID: Int,
        completedBytes: Int64,
        expectedBytes: Int64?,
        defaults: UserDefaults = .standard
    ) {
        var values = records(defaults: defaults)
        guard let index = values.lastIndex(where: { $0.taskID == taskID }),
              values[index].completedAt == nil else { return }
        let boundedCompleted = max(completedBytes, 0)
        let previousPercentage = values[index].percentage
        values[index].completedBytes = boundedCompleted
        if let expectedBytes, expectedBytes > 0 {
            values[index].expectedBytes = expectedBytes
        }
        let newPercentage = values[index].percentage
        guard previousPercentage != newPercentage || boundedCompleted == 0 else { return }
        persist(Array(values.suffix(32)), defaults: defaults)
    }

    static func markCompleted(
        taskID: Int,
        succeeded: Bool,
        errorCode: Int?,
        httpStatusCode: Int? = nil,
        completedBytes: Int64? = nil,
        expectedBytes: Int64? = nil,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        var values = records(defaults: defaults)
        guard let index = values.lastIndex(where: { $0.taskID == taskID }) else { return }
        values[index].completedAt = now
        values[index].succeeded = succeeded
        values[index].errorCode = errorCode
        values[index].httpStatusCode = httpStatusCode
        if let completedBytes {
            values[index].completedBytes = max(completedBytes, 0)
        }
        if let expectedBytes, expectedBytes > 0 {
            values[index].expectedBytes = expectedBytes
        }
        persist(Array(values.suffix(32)), defaults: defaults)
    }

    static func latest(
        mapID: String,
        sessionID: String,
        defaults: UserDefaults = .standard
    ) -> BackgroundMapUploadRecord? {
        records(defaults: defaults)
            .filter {
                $0.descriptor.mapID == mapID &&
                    $0.descriptor.sessionID == sessionID
            }
            .max { $0.startedAt < $1.startedAt }
    }

    private static func persist(
        _ values: [BackgroundMapUploadRecord],
        defaults: UserDefaults
    ) {
        if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: key)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }
}

#if os(iOS)
final class BackgroundMapUploadCoordinator: NSObject,
                                            URLSessionDataDelegate,
                                            URLSessionTaskDelegate {
    static let shared = BackgroundMapUploadCoordinator()
    static let sessionIdentifier = "LetItRide.BikeComputer.map-transfer.background"

    private struct PendingUpload {
        let continuation: CheckedContinuation<Void, Error>
        let progress: @MainActor (Int64, Int64) -> Void
        let expectedBytes: Int64
        var response = BackgroundMapUploadResponseBuffer()
    }

    private let lock = NSLock()
    private var pendingUploads: [Int: PendingUpload] = [:]
    private var retiredTaskIDs: Set<Int> = []
    private var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func upload(
        request: URLRequest,
        fileURL: URL,
        expectedBytes: Int64,
        descriptor: BackgroundMapUploadDescriptor,
        onTaskStarted: @escaping @MainActor (Int) -> Void = { _ in },
        progress: @escaping @MainActor (Int64, Int64) -> Void
    ) async throws {
        let descriptorData = try JSONEncoder().encode(descriptor)
        guard let description = String(data: descriptorData, encoding: .utf8) else {
            throw OfflineMapPlatformError.invalidPack(
                "background upload identity could not be encoded"
            )
        }
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = description
        BackgroundMapUploadStateStore.markStarted(
            taskID: task.taskIdentifier,
            descriptor: descriptor,
            expectedBytes: expectedBytes
        )
        task.countOfBytesClientExpectsToSend = expectedBytes
        task.countOfBytesClientExpectsToReceive = 512
        await onTaskStarted(task.taskIdentifier)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                pendingUploads[task.taskIdentifier] = PendingUpload(
                    continuation: continuation,
                    progress: progress,
                    expectedBytes: expectedBytes
                )
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func handleEvents(completionHandler: @escaping () -> Void) {
        lock.lock()
        backgroundCompletionHandler = completionHandler
        lock.unlock()
        _ = session
    }

    func restorePersistedTasks() {
        session.getAllTasks { tasks in
            for task in tasks {
                if let descriptor = Self.descriptor(for: task) {
                    if !Self.hasMatchingStateRecord(
                        taskID: task.taskIdentifier,
                        descriptor: descriptor
                    ) {
                        BackgroundMapUploadStateStore.markStarted(
                            taskID: task.taskIdentifier,
                            descriptor: descriptor,
                            expectedBytes: task.countOfBytesExpectedToSend
                        )
                    }
                    BackgroundMapUploadStateStore.markProgress(
                        taskID: task.taskIdentifier,
                        completedBytes: task.countOfBytesSent,
                        expectedBytes: task.countOfBytesExpectedToSend
                    )
                }
                if task.state == .suspended {
                    task.resume()
                }
            }
        }
    }

    func activeUploadActivity() async -> BackgroundMapUploadActivitySnapshot {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                let activeTasks = tasks.filter {
                    $0.state == .running || $0.state == .suspended
                }
                let descriptors = activeTasks.compactMap(Self.descriptor(for:))
                continuation.resume(returning: BackgroundMapUploadActivitySnapshot(
                    descriptors: descriptors,
                    hasUnidentifiedTask: descriptors.count != activeTasks.count
                ))
            }
        }
    }

    func activeUploadDescriptors() async -> [BackgroundMapUploadDescriptor] {
        await activeUploadActivity().descriptors
    }

    func retireActiveUpload(mapID: String, sessionID: String) async -> Bool {
        let tasks = await allTasks()
        let matchingTasks = tasks.filter { task in
            guard let descriptor = Self.descriptor(for: task) else {
                return false
            }
            return descriptor.mapID == mapID && descriptor.sessionID == sessionID
        }
        markTasksRetired(matchingTasks.map(\.taskIdentifier))
        for task in matchingTasks
            where task.state == .running || task.state == .suspended {
            task.cancel()
        }
        guard !matchingTasks.isEmpty else { return true }

        for _ in 0..<20 {
            let remaining = await activeUploadActivity()
            if !remaining.hasUnidentifiedTask,
               remaining.descriptors.allSatisfy({
                   $0.mapID != mapID || $0.sessionID != sessionID
               }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        unmarkTasksRetired(matchingTasks.map(\.taskIdentifier))
        return false
    }

    func hasActiveUpload(mapID: String, sessionID: String) async -> Bool {
        let activity = await activeUploadActivity()
        guard !activity.hasUnidentifiedTask else { return true }
        return activity.descriptors.contains {
            $0.mapID == mapID && $0.sessionID == sessionID
        }
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    private func markTasksRetired(_ taskIDs: [Int]) {
        lock.lock()
        retiredTaskIDs.formUnion(taskIDs)
        lock.unlock()
    }

    private func unmarkTasksRetired(_ taskIDs: [Int]) {
        lock.lock()
        retiredTaskIDs.subtract(taskIDs)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        if let descriptor = Self.descriptor(for: task),
           !Self.hasMatchingStateRecord(
               taskID: task.taskIdentifier,
               descriptor: descriptor
           ) {
            BackgroundMapUploadStateStore.markStarted(
                taskID: task.taskIdentifier,
                descriptor: descriptor,
                expectedBytes: totalBytesExpectedToSend
            )
        }
        BackgroundMapUploadStateStore.markProgress(
            taskID: task.taskIdentifier,
            completedBytes: totalBytesSent,
            expectedBytes: totalBytesExpectedToSend
        )
        lock.lock()
        let pending = pendingUploads[task.taskIdentifier]
        lock.unlock()
        guard let pending else { return }
        let expectedBytes = totalBytesExpectedToSend > 0
            ? totalBytesExpectedToSend
            : pending.expectedBytes
        Task { @MainActor in
            pending.progress(totalBytesSent, expectedBytes)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        if var pending = pendingUploads[dataTask.taskIdentifier] {
            guard pending.response.append(data) else {
                lock.unlock()
                dataTask.cancel()
                return
            }
            pendingUploads[dataTask.taskIdentifier] = pending
        }
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let pending = pendingUploads.removeValue(forKey: task.taskIdentifier)
        let wasRetiredForResume = retiredTaskIDs.remove(task.taskIdentifier) != nil
        lock.unlock()
        let descriptor = Self.descriptor(for: task)
        if let descriptor,
           !Self.hasMatchingStateRecord(
               taskID: task.taskIdentifier,
               descriptor: descriptor
           ) {
            BackgroundMapUploadStateStore.markStarted(
                taskID: task.taskIdentifier,
                descriptor: descriptor,
                expectedBytes: task.countOfBytesExpectedToSend
            )
        }
        let nsError = error as NSError?
        let httpStatus = (task.response as? HTTPURLResponse)?.statusCode
        let succeeded = error == nil && httpStatus.map { 200..<300 ~= $0 } == true
        BackgroundMapUploadStateStore.markCompleted(
            taskID: task.taskIdentifier,
            succeeded: succeeded,
            errorCode: nsError?.code,
            httpStatusCode: httpStatus,
            completedBytes: task.countOfBytesSent,
            expectedBytes: task.countOfBytesExpectedToSend
        )
        NotificationCenter.default.post(
            name: BackgroundMapUploadStateStore.didChangeNotification,
            object: nil
        )
        if !wasRetiredForResume,
           let ssid = descriptor?.accessPointSSID,
           !ssid.isEmpty,
           descriptor?.protocolVersion == 2 {
            removeAccessoryNetworkConfigurationIfUnused(
                ssid: ssid,
                completedTaskID: task.taskIdentifier
            )
        }
        guard let pending else { return }
        if let error {
            pending.continuation.resume(throwing: error)
            return
        }
        do {
            guard let response = task.response else {
                throw OfflineMapPlatformError.invalidResponse
            }
            try MapTransferDeviceClient.validate(
                response: response,
                body: pending.response.data
            )
            pending.continuation.resume()
        } catch {
            pending.continuation.resume(throwing: error)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completionHandler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        lock.unlock()
        if let completionHandler {
            DispatchQueue.main.async(execute: completionHandler)
        }
    }

    private static func descriptor(for task: URLSessionTask) -> BackgroundMapUploadDescriptor? {
        guard let description = task.taskDescription,
              let data = description.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BackgroundMapUploadDescriptor.self, from: data)
    }

    private static func hasMatchingStateRecord(
        taskID: Int,
        descriptor: BackgroundMapUploadDescriptor
    ) -> Bool {
        BackgroundMapUploadStateStore.records().contains {
            $0.taskID == taskID && $0.descriptor == descriptor
        }
    }

    private func removeAccessoryNetworkConfigurationIfUnused(
        ssid: String,
        completedTaskID: Int
    ) {
        session.getAllTasks { tasks in
            let remainsInUse = tasks.contains { task in
                guard task.taskIdentifier != completedTaskID,
                      task.state == .running || task.state == .suspended else {
                    return false
                }
                guard let descriptor = Self.descriptor(for: task) else {
                    return true
                }
                return descriptor.accessPointSSID == ssid
            }
            if !remainsInUse {
                DeviceTransferManager.removeAccessoryNetworkConfiguration(ssid: ssid)
            }
        }
    }
}
#endif

struct OfflineMapPlatformClient {
    let baseURL: URL
    let apiToken: String?
    let clientInstallationId: String
    let clientInstallationToken: String?
    let mapStreamTrustCapabilities: String?
    let mapStreamAppBuildIdentity: MapStreamAppBuildIdentity?
    var session: URLSession = .shared

    init(
        baseURL: URL,
        apiToken: String? = nil,
        clientInstallationId: String,
        clientInstallationToken: String? = nil,
        mapStreamTrustCapabilities: String? = BikeMapStreamTrustStore.production.capabilityHeaderValue,
        mapStreamAppBuildIdentity: MapStreamAppBuildIdentity? = .current,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiToken = apiToken?.isEmpty == true ? nil : apiToken
        self.clientInstallationId = clientInstallationId
        self.clientInstallationToken = clientInstallationToken
        self.mapStreamTrustCapabilities = mapStreamTrustCapabilities
        self.mapStreamAppBuildIdentity = mapStreamAppBuildIdentity
        self.session = session
    }

    func createJob(_ jobRequest: OfflineMapJobRequest) async throws -> OfflineMapJob {
        guard jobRequest.clientInstallationId == clientInstallationId else {
            throw OfflineMapPlatformError.invalidResponse
        }
        var request = try Self.makeCreateJobURLRequest(
            baseURL: baseURL,
            apiToken: apiToken,
            jobRequest: jobRequest
        )
        authorizeInstallation(&request)
        return try await send(request: request)
    }

    func registerInstallation() async throws -> OfflineMapInstallationCredential {
        var request = URLRequest(
            url: try Self.endpointURL(baseURL: baseURL, path: "/v1/installations")
        )
        request.httpMethod = "POST"
        if let apiToken {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        let credential: OfflineMapInstallationCredential = try await send(request: request)
        guard credential.clientInstallationId.range(
            of: "^inst_v2_[0-9a-f]{32}$",
            options: .regularExpression
        ) != nil,
        credential.clientInstallationToken.range(
            of: "^v1\\.[A-Za-z0-9_-]{43}$",
            options: .regularExpression
        ) != nil else {
            throw OfflineMapPlatformError.invalidResponse
        }
        return credential
    }

    func job(id: String) async throws -> OfflineMapJob {
        let request = try Self.makeInstallationScopedURLRequest(
            baseURL: baseURL,
            apiToken: apiToken,
            path: "/v1/map-jobs/\(id)",
            method: "GET",
            clientInstallationId: clientInstallationId
        )
        var authorized = request
        authorizeInstallation(&authorized)
        return try await send(request: authorized)
    }

    func jobs() async throws -> [OfflineMapJob] {
        let request = try Self.makeListJobsURLRequest(
            baseURL: baseURL,
            apiToken: apiToken,
            clientInstallationId: clientInstallationId
        )
        var authorized = request
        authorizeInstallation(&authorized)
        let (data, response) = try await session.data(for: authorized)
        guard let http = response as? HTTPURLResponse else {
            throw OfflineMapPlatformError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw OfflineMapPlatformError.serverStatus(http.statusCode, bodyText)
        }
        return try JSONDecoder().decode(OfflineMapJobsResponse.self, from: data).jobs
    }

    func updateDisplayName(jobId: String, displayName: String) async throws {
        var request = try Self.makeUpdateDisplayNameURLRequest(
            baseURL: baseURL,
            apiToken: apiToken,
            clientInstallationId: clientInstallationId,
            jobId: jobId,
            displayName: displayName
        )
        authorizeInstallation(&request)
        let response: OfflineMapInventoryMutationResponse = try await send(request: request)
        guard response.jobId == jobId else {
            throw OfflineMapPlatformError.invalidResponse
        }
    }

    func recordDownload(
        jobId: String,
        receipt: OfflineMapDownloadReceiptRequest
    ) async throws {
        var request = try Self.makeRecordDownloadURLRequest(
            baseURL: baseURL,
            apiToken: apiToken,
            clientInstallationId: clientInstallationId,
            jobId: jobId,
            receipt: receipt
        )
        authorizeInstallation(&request)
        let response: OfflineMapInventoryMutationResponse = try await send(request: request)
        guard response.jobId == jobId, response.downloadCount > 0 else {
            throw OfflineMapPlatformError.invalidResponse
        }
    }

    func downloadURL(mapId: String, jobId: String) async throws -> URL {
        let request = try Self.makeInstallationScopedURLRequest(
            baseURL: baseURL,
            apiToken: apiToken,
            path: "/v1/map-packs/\(mapId)/download-url",
            method: "POST",
            clientInstallationId: clientInstallationId,
            additionalQueryItems: [URLQueryItem(name: "jobId", value: jobId)]
        )
        var authorized = request
        authorizeInstallation(&authorized)
        let response: OfflineMapDownloadURL = try await send(request: authorized)
        return try absoluteURL(for: response.url, baseURL: baseURL)
    }

    func artifactDownloadURL(
        mapId: String,
        jobId: String,
        artifact: OfflineMapArtifact
    ) async throws -> URL {
        if artifact.isBikeMapStream,
           artifact.signedManifestReceipt?.isEmpty != false {
            throw OfflineMapPlatformError.invalidResponse
        }
        var query = [URLQueryItem(name: "jobId", value: jobId)]
        if let signedManifestReceipt = artifact.signedManifestReceipt {
            query.append(URLQueryItem(
                name: "signedManifestReceipt",
                value: signedManifestReceipt
            ))
        }
        var request = try Self.makeInstallationScopedURLRequest(
            baseURL: baseURL,
            apiToken: apiToken,
            path: "/v1/map-packs/\(mapId)/artifacts/\(artifact.format)/download-url",
            method: "POST",
            clientInstallationId: clientInstallationId,
            additionalQueryItems: query
        )
        authorizeInstallation(&request)
        let response: OfflineMapArtifactDownloadURL = try await send(request: request)
        guard response.format == artifact.format,
              response.mediaType == artifact.mediaType,
              response.filename == artifact.filename,
              response.objectKey == artifact.objectKey,
              response.bytes == artifact.bytes,
              response.sha256 == artifact.sha256,
              response.manifestReceipt == artifact.manifestReceipt,
              response.signedManifestReceipt == artifact.signedManifestReceipt,
              response.signatureKeyId == artifact.signatureKeyId,
              response.signatureKeySha256 == artifact.signatureKeySha256,
              response.producerBuildSha256 == artifact.producerBuildSha256,
              response.producerImageDigest == artifact.producerImageDigest,
              response.requiredIosBuild == artifact.requiredIosBuild,
              response.requiredIosGitSha == artifact.requiredIosGitSha,
              response.requiredIosBuildSha256 == artifact.requiredIosBuildSha256,
              response.requiredFirmwareVersion == artifact.requiredFirmwareVersion,
              response.requiredFirmwareBuild == artifact.requiredFirmwareBuild,
              response.requiredFirmwareGitSha == artifact.requiredFirmwareGitSha else {
            throw OfflineMapPlatformError.invalidResponse
        }
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

    static func makeListJobsURLRequest(
        baseURL: URL,
        apiToken: String?,
        clientInstallationId: String
    ) throws -> URLRequest {
        let endpoint = try endpointURL(baseURL: baseURL, path: "/v1/map-jobs")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw OfflineMapPlatformError.invalidBaseURL
        }
        components.queryItems = [URLQueryItem(name: "clientInstallationId", value: clientInstallationId)]
        guard let url = components.url else {
            throw OfflineMapPlatformError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let apiToken, !apiToken.isEmpty {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func makeInstallationScopedURLRequest(
        baseURL: URL,
        apiToken: String?,
        path: String,
        method: String,
        clientInstallationId: String,
        additionalQueryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        let endpoint = try endpointURL(baseURL: baseURL, path: path)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw OfflineMapPlatformError.invalidBaseURL
        }
        components.queryItems = [
            URLQueryItem(name: "clientInstallationId", value: clientInstallationId)
        ] + additionalQueryItems
        guard let url = components.url else {
            throw OfflineMapPlatformError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let apiToken, !apiToken.isEmpty {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func makeUpdateDisplayNameURLRequest(
        baseURL: URL,
        apiToken: String?,
        clientInstallationId: String,
        jobId: String,
        displayName: String
    ) throws -> URLRequest {
        var request = try makeInstallationScopedURLRequest(
            baseURL: baseURL,
            apiToken: apiToken,
            path: "/v1/map-jobs/\(jobId)/display-name",
            method: "PATCH",
            clientInstallationId: clientInstallationId
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.offlineMap.encode(
            OfflineMapDisplayNameRequest(displayName: displayName)
        )
        return request
    }

    static func makeRecordDownloadURLRequest(
        baseURL: URL,
        apiToken: String?,
        clientInstallationId: String,
        jobId: String,
        receipt: OfflineMapDownloadReceiptRequest
    ) throws -> URLRequest {
        var request = try makeInstallationScopedURLRequest(
            baseURL: baseURL,
            apiToken: apiToken,
            path: "/v1/map-jobs/\(jobId)/downloads",
            method: "POST",
            clientInstallationId: clientInstallationId
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.offlineMap.encode(receipt)
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

        return try await send(request: request)
    }

    private func send<Response: Decodable>(request: URLRequest) async throws -> Response {
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

    private func authorizeInstallation(_ request: inout URLRequest) {
        if let clientInstallationToken, !clientInstallationToken.isEmpty {
            request.setValue(
                clientInstallationToken,
                forHTTPHeaderField: "X-Installation-Token"
            )
        }
        if let mapStreamTrustCapabilities, !mapStreamTrustCapabilities.isEmpty {
            request.setValue(
                mapStreamTrustCapabilities,
                forHTTPHeaderField: "X-Map-Stream-Trust"
            )
            if let identity = mapStreamAppBuildIdentity, identity.isReleaseGrade {
                request.setValue(
                    identity.build,
                    forHTTPHeaderField: "X-Map-Stream-App-Build"
                )
                request.setValue(
                    identity.gitSha,
                    forHTTPHeaderField: "X-Map-Stream-App-Git-Sha"
                )
                request.setValue(
                    identity.componentSha256,
                    forHTTPHeaderField: "X-Map-Stream-App-Build-Sha256"
                )
            }
        }
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
    nonisolated func uint32BE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 |
            UInt32(self[offset + 1]) << 16 |
            UInt32(self[offset + 2]) << 8 |
            UInt32(self[offset + 3])
    }

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
    nonisolated static var offlineMap: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
