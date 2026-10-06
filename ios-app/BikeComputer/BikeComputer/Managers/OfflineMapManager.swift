//
//  OfflineMapManager.swift
//  BikeComputer
//
//  Coordinates offline map platform requests from the settings UI.
//

import CoreLocation
import Combine
import Foundation
import Darwin
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UIKit) && canImport(MapKit)
import MapKit
#endif
#if os(iOS)
import Security
#endif

private enum OfflineMapDefaults {
    nonisolated static let serverURLKey = "offlineMap.serverURL"
    nonisolated static let centerLatitudeKey = "offlineMap.centerLatitude"
    nonisolated static let centerLongitudeKey = "offlineMap.centerLongitude"
    nonisolated static let sideLengthKey = "offlineMap.sideLengthKm"
    nonisolated static let topographicMapsEnabledKey =
        "offlineMap.topographicMapsEnabled.v1"
    nonisolated static let includeTopographyInNewMapsKey =
        "offlineMap.includeTopographyInNewMaps.v1"
    nonisolated static let activeTopographyAssociationKey =
        "offlineMap.activeTopographyAssociation.v1"
    nonisolated static let packDisplayNamesKey = "offlineMap.packDisplayNames"
    nonisolated static let lastTransferMapIdKey = "offlineMap.lastTransfer.mapId"
    nonisolated static let lastTransferSessionIdKey = "offlineMap.lastTransfer.sessionId"
    nonisolated static let lastTransferPreviousMapIdKey = "offlineMap.lastTransfer.previousMapId"
    nonisolated static let lastTransferPreviousSessionIdKey = "offlineMap.lastTransfer.previousSessionId"
    nonisolated static let lastTransferPreviousSequenceKey = "offlineMap.lastTransfer.previousSequence"
    nonisolated static let lastTransferAcceptedSequenceKey = "offlineMap.lastTransfer.acceptedSequence"
    nonisolated static let lastTransferOutcomeKey = "offlineMap.lastTransfer.outcome"
    nonisolated static let lastTransferProtocolKey = "offlineMap.lastTransfer.protocol"
    nonisolated static let lastTransferStreamFormatKey = "offlineMap.lastTransfer.streamFormat"
    nonisolated static let lastTransferArtifactFilenameKey = "offlineMap.lastTransfer.artifactFilename"
    nonisolated static let lastTransferBackgroundTaskIDKey = "offlineMap.lastTransfer.backgroundTaskID"
    nonisolated static let mapJobPollIntervalNanoseconds: UInt64 = 2_000_000_000
    nonisolated static let activationConfirmationTimeout: TimeInterval = 10 * 60
    nonisolated static let activationPollIntervalNanoseconds: UInt64 = 2_000_000_000
    nonisolated static let legacyServerURLs = [
        "http://rhi0maej6bwo33hn0im6h4lf.178.18.245.246.sslip.io"
    ]
}

nonisolated enum OfflineMapSharedSecretMigration {
    private static let legacyKeys = [
        "offlineMap.apiToken",
        "offlineMap.activeJobAPIToken",
    ]

    static func removeLegacyValues(defaults: UserDefaults) {
        for key in legacyKeys {
            defaults.removeObject(forKey: key)
        }
    }

    static func migrateCustomServerValues(
        defaults: UserDefaults,
        tokenStore: OfflineMapLegacyBearerTokenStore
    ) {
        let candidates = [
            (
                serverKey: "offlineMap.activeJobServerURL",
                tokenKey: "offlineMap.activeJobAPIToken"
            ),
            (
                serverKey: "offlineMap.serverURL",
                tokenKey: "offlineMap.apiToken"
            ),
        ]
        for candidate in candidates {
            let server = defaults.string(forKey: candidate.serverKey) ?? ""
            let token = defaults.string(forKey: candidate.tokenKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty, !OfflineMapServerIdentity.isManaged(server) else {
                defaults.removeObject(forKey: candidate.tokenKey)
                continue
            }
            do {
                try tokenStore.save(token, serverURLString: server)
                defaults.removeObject(forKey: candidate.tokenKey)
            } catch {
                // Leave the legacy value available if secure migration failed.
            }
        }
    }

    static func legacyCustomToken(
        serverURLString: String,
        defaults: UserDefaults
    ) -> String? {
        guard !OfflineMapServerIdentity.isManaged(serverURLString) else { return nil }
        let candidates = [
            (
                serverKey: "offlineMap.serverURL",
                tokenKey: "offlineMap.apiToken"
            ),
            (
                serverKey: "offlineMap.activeJobServerURL",
                tokenKey: "offlineMap.activeJobAPIToken"
            ),
        ]
        for candidate in candidates {
            guard let candidateServer = defaults.string(forKey: candidate.serverKey),
                  OfflineMapServerIdentity.normalized(candidateServer) ==
                    OfflineMapServerIdentity.normalized(serverURLString) else {
                continue
            }
            let token = defaults.string(forKey: candidate.tokenKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !token.isEmpty {
                return token
            }
        }
        return nil
    }
}

@MainActor
enum OfflineMapSnapshotPreviewRenderer {
    nonisolated struct Configuration: Equatable, Sendable {
        let size: CGSize
        let scale: CGFloat

        static let thumbnail = Configuration(
            size: CGSize(width: 160, height: 96),
            scale: 1
        )
        static let detail = Configuration(
            size: CGSize(width: 400, height: 240),
            scale: 3
        )
    }

#if canImport(UIKit) && canImport(MapKit)
    struct Request {
        let options: MKMapSnapshotter.Options
        let northWestCoordinate: CLLocationCoordinate2D
        let southEastCoordinate: CLLocationCoordinate2D
        let configuration: Configuration
    }

    struct SnapshotResult {
        let image: UIImage
        let pointForCoordinate: @MainActor (CLLocationCoordinate2D) -> CGPoint
    }

    typealias SnapshotOperation = @MainActor (
        MKMapSnapshotter.Options
    ) async throws -> SnapshotResult
#endif

    static func pngData(
        for bounds: OfflineMapPreviewBounds,
        configuration: Configuration = .thumbnail
    ) async throws -> Data? {
#if canImport(UIKit) && canImport(MapKit)
        try await pngData(for: bounds, configuration: configuration) { options in
            let snapshotter = MKMapSnapshotter(options: options)
            let snapshot = try await withTaskCancellationHandler {
                try await snapshotter.start()
            } onCancel: {
                snapshotter.cancel()
            }
            return SnapshotResult(
                image: snapshot.image,
                pointForCoordinate: { snapshot.point(for: $0) }
            )
        }
#else
        nil
#endif
    }

    static func detailPNGData(for bounds: OfflineMapPreviewBounds) async throws -> Data? {
#if canImport(UIKit) && canImport(MapKit)
        try await pngData(for: bounds, configuration: .detail)
#else
        nil
#endif
    }

#if canImport(UIKit) && canImport(MapKit)
    static func request(
        for bounds: OfflineMapPreviewBounds,
        configuration: Configuration = .thumbnail
    ) -> Request {
        let options = MKMapSnapshotter.Options()
        let northWestCoordinate = CLLocationCoordinate2D(
            latitude: bounds.maxLatitude,
            longitude: bounds.minLongitude
        )
        let southEastCoordinate = CLLocationCoordinate2D(
            latitude: bounds.minLatitude,
            longitude: bounds.maxLongitude
        )
        let northWest = MKMapPoint(northWestCoordinate)
        let southEast = MKMapPoint(southEastCoordinate)
        options.mapRect = MKMapRect(
            x: min(northWest.x, southEast.x),
            y: min(northWest.y, southEast.y),
            width: abs(southEast.x - northWest.x),
            height: abs(southEast.y - northWest.y)
        )
        options.size = configuration.size
        options.scale = configuration.scale
        options.traitCollection = UITraitCollection(userInterfaceStyle: .light)
        if #available(iOS 17.0, macCatalyst 17.0, *) {
            options.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        } else {
            options.mapType = .standard
        }
        return Request(
            options: options,
            northWestCoordinate: northWestCoordinate,
            southEastCoordinate: southEastCoordinate,
            configuration: configuration
        )
    }

    static func pngData(
        for bounds: OfflineMapPreviewBounds,
        configuration: Configuration = .thumbnail,
        snapshot: SnapshotOperation
    ) async throws -> Data? {
        let request = request(for: bounds, configuration: configuration)
        let result = try await snapshot(request.options)
        try Task.checkCancellation()
        guard let croppedImage = croppedImage(
            from: result.image,
            request: request,
            pointForCoordinate: result.pointForCoordinate
        ), hasMeaningfulVisualVariation(croppedImage) else {
            return nil
        }
        return croppedImage.pngData()
    }

    static func croppedImage(
        from image: UIImage,
        request: Request,
        pointForCoordinate: @MainActor (CLLocationCoordinate2D) -> CGPoint
    ) -> UIImage? {
        croppedImage(
            from: image,
            northWestPoint: pointForCoordinate(request.northWestCoordinate),
            southEastPoint: pointForCoordinate(request.southEastCoordinate),
            configuration: request.configuration
        )
    }

    static func hasMeaningfulVisualVariation(_ image: UIImage) -> Bool {
        guard let source = image.cgImage else { return false }
        let width = min(source.width, 64)
        let height = min(source.height, 64)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return false }

        var minimum = [UInt8](repeating: .max, count: 3)
        var maximum = [UInt8](repeating: .min, count: 3)
        for offset in stride(from: 0, to: pixels.count, by: 4)
            where pixels[offset + 3] >= 128 {
            for channel in 0..<3 {
                minimum[channel] = min(minimum[channel], pixels[offset + channel])
                maximum[channel] = max(maximum[channel], pixels[offset + channel])
            }
        }
        return zip(minimum, maximum).contains { minimum, maximum in
            Int(maximum) - Int(minimum) >= 8
        }
    }

    private static func croppedImage(
        from image: UIImage,
        northWestPoint: CGPoint,
        southEastPoint: CGPoint,
        configuration: Configuration
    ) -> UIImage? {
        guard let source = image.cgImage else { return nil }
        let scale = image.scale
        let minimumX = max(
            0,
            ceil(min(northWestPoint.x, southEastPoint.x) * scale)
        )
        let minimumY = max(
            0,
            ceil(min(northWestPoint.y, southEastPoint.y) * scale)
        )
        let maximumX = min(
            CGFloat(source.width),
            floor(max(northWestPoint.x, southEastPoint.x) * scale)
        )
        let maximumY = min(
            CGFloat(source.height),
            floor(max(northWestPoint.y, southEastPoint.y) * scale)
        )
        guard maximumX > minimumX, maximumY > minimumY,
              let cropped = source.cropping(to: CGRect(
                  x: minimumX,
                  y: minimumY,
                  width: maximumX - minimumX,
                  height: maximumY - minimumY
              )) else {
            return nil
        }
        let croppedImage = UIImage(
            cgImage: cropped,
            scale: scale,
            orientation: image.imageOrientation
        )
        let normalizedSize = CGSize(
            width: min(
                configuration.size.width,
                max(1, floor(croppedImage.size.width))
            ),
            height: min(
                configuration.size.height,
                max(1, floor(croppedImage.size.height))
            )
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = configuration.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: normalizedSize, format: format).image { _ in
            croppedImage.draw(in: CGRect(origin: .zero, size: normalizedSize))
        }
    }
#endif
}

typealias OfflineMapSnapshotOperation = @MainActor (
    OfflineMapPreviewBounds
) async throws -> Data?

nonisolated struct OfflineMapPreviewLoadResult: Sendable {
    let snapshotData: Data?
    let packContent: OfflineMapPackPreviewContent?
}

typealias OfflineMapPreviewLoadOperation = @MainActor (
    URL
) async -> OfflineMapPreviewLoadResult

#if canImport(UIKit)
nonisolated private enum SavedMapPreviewPNGValidator {
    private static let pngSignature = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ])

    static func isValid(
        _ data: Data,
        maximumImageBytes: Int,
        maximumPixelDimension: UInt32,
        minimumLongestEdge: UInt32 = 1
    ) -> Bool {
        guard (33...maximumImageBytes).contains(data.count),
              data.starts(with: pngSignature),
              uint32BE(data, at: 8) == 13,
              data.subdata(in: 12..<16) == Data("IHDR".utf8) else {
            return false
        }
        let width = uint32BE(data, at: 16)
        let height = uint32BE(data, at: 20)
        return (1...maximumPixelDimension).contains(width) &&
            (1...maximumPixelDimension).contains(height) &&
            max(width, height) >= minimumLongestEdge
    }

    private static func uint32BE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 |
            UInt32(data[offset + 1]) << 16 |
            UInt32(data[offset + 2]) << 8 |
            UInt32(data[offset + 3])
    }
}

nonisolated enum SavedMapSnapshotPreviewStore {
    static let maximumImageBytes = 1_048_576

    static func imageURL(for artifactURL: URL) -> URL {
        artifactURL.appendingPathExtension("thumbnail.png")
    }

    static func imageData(for artifactURL: URL) -> Data? {
        let url = imageURL(for: artifactURL)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              (33...maximumImageBytes).contains(fileSize),
              let data = try? Data(contentsOf: url),
              isValidPNG(data) else {
            return nil
        }
        return data
    }

    static func save(_ data: Data, for artifactURL: URL) throws {
        guard isValidPNG(data) else {
            throw OfflineMapPlatformError.invalidPack("map snapshot preview is not a valid PNG")
        }
        try data.write(to: imageURL(for: artifactURL), options: .atomic)
    }

    static func delete(for artifactURL: URL) throws {
        let url = imageURL(for: artifactURL)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func isValidPNG(_ data: Data) -> Bool {
        SavedMapPreviewPNGValidator.isValid(
            data,
            maximumImageBytes: maximumImageBytes,
            maximumPixelDimension: 1_024
        )
    }
}

nonisolated enum SavedMapDetailPreviewStore {
    static let cacheVersion = 1
    static let maximumImageBytes = 4_194_304
    static let maximumPixelDimension: UInt32 = 1_200
    static let minimumLongestEdge: UInt32 = 600

    static func imageURL(for artifactURL: URL) -> URL {
        artifactURL.appendingPathExtension("detail-preview-v\(cacheVersion).png")
    }

    static func imageData(for artifactURL: URL) -> Data? {
        imageData(at: imageURL(for: artifactURL))
    }

    static func save(_ data: Data, for artifactURL: URL) throws {
        guard isValidPNG(data) else {
            throw OfflineMapPlatformError.invalidPack(
                "map detail preview is not a high-resolution PNG"
            )
        }
        try data.write(to: imageURL(for: artifactURL), options: .atomic)
    }

    static func delete(for artifactURL: URL) throws {
        let url = imageURL(for: artifactURL)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func isValidPNG(_ data: Data) -> Bool {
        SavedMapPreviewPNGValidator.isValid(
            data,
            maximumImageBytes: maximumImageBytes,
            maximumPixelDimension: maximumPixelDimension,
            minimumLongestEdge: minimumLongestEdge
        )
    }

    static func imageData(at url: URL) -> Data? {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        ),
        values.isRegularFile == true,
        let fileSize = values.fileSize,
        (33...maximumImageBytes).contains(fileSize),
        let data = try? Data(contentsOf: url),
        isValidPNG(data) else {
            return nil
        }
        return data
    }
}

nonisolated private enum DeviceMapPreviewCachePolicy {
    private static let maximumEntryCount = 16
    private static let maximumEntryAge: TimeInterval = 30 * 24 * 60 * 60

    static func prune(directory: URL, now: Date = Date()) {
        guard var entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
            ],
            options: []
        ) else {
            return
        }
        entries = entries.filter { url in
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            )
            return values?.isRegularFile == true &&
                url.pathExtension.lowercased() == "png"
        }
        entries.sort { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
        for (index, url) in entries.enumerated() {
            let date = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            if index >= maximumEntryCount || now.timeIntervalSince(date) > maximumEntryAge {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

nonisolated enum DeviceMapSnapshotPreviewStore {

    static func imageData(
        for descriptor: DeviceActiveMapDescriptor,
        in cacheRoot: URL
    ) -> Data? {
        let url = imageURL(for: descriptor, in: cacheRoot)
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        ),
        values.isRegularFile == true,
        let fileSize = values.fileSize,
        (33...SavedMapSnapshotPreviewStore.maximumImageBytes).contains(fileSize),
        let data = try? Data(contentsOf: url),
        SavedMapSnapshotPreviewStore.isValidPNG(data) else {
            return nil
        }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
        return data
    }

    static func save(
        _ data: Data,
        for descriptor: DeviceActiveMapDescriptor,
        in cacheRoot: URL
    ) throws {
        guard SavedMapSnapshotPreviewStore.isValidPNG(data) else {
            throw OfflineMapPlatformError.invalidPack(
                "device map snapshot preview is not a valid PNG"
            )
        }
        let directory = previewDirectory(in: cacheRoot)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(
            to: imageURL(for: descriptor, in: cacheRoot),
            options: .atomic
        )
        DeviceMapPreviewCachePolicy.prune(directory: directory)
    }

    static func imageURL(
        for descriptor: DeviceActiveMapDescriptor,
        in cacheRoot: URL
    ) -> URL {
        previewDirectory(in: cacheRoot)
            .appendingPathComponent(descriptor.previewFilename, isDirectory: false)
    }

    private static func previewDirectory(in cacheRoot: URL) -> URL {
        cacheRoot.appendingPathComponent("DeviceMapPreviews", isDirectory: true)
    }
}

nonisolated enum DeviceMapDetailPreviewStore {
    static func imageData(
        for descriptor: DeviceActiveMapDescriptor,
        in cacheRoot: URL
    ) -> Data? {
        let url = imageURL(for: descriptor, in: cacheRoot)
        guard let data = SavedMapDetailPreviewStore.imageData(at: url) else {
            return nil
        }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
        return data
    }

    static func save(
        _ data: Data,
        for descriptor: DeviceActiveMapDescriptor,
        in cacheRoot: URL
    ) throws {
        guard SavedMapDetailPreviewStore.isValidPNG(data) else {
            throw OfflineMapPlatformError.invalidPack(
                "device map detail preview is not a high-resolution PNG"
            )
        }
        let directory = previewDirectory(in: cacheRoot)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(
            to: imageURL(for: descriptor, in: cacheRoot),
            options: .atomic
        )
        DeviceMapPreviewCachePolicy.prune(directory: directory)
    }

    static func imageURL(
        for descriptor: DeviceActiveMapDescriptor,
        in cacheRoot: URL
    ) -> URL {
        previewDirectory(in: cacheRoot).appendingPathComponent(
            descriptor.previewFilename + ".detail-v\(SavedMapDetailPreviewStore.cacheVersion).png",
            isDirectory: false
        )
    }

    static func delete(
        for descriptor: DeviceActiveMapDescriptor,
        in cacheRoot: URL
    ) throws {
        let url = imageURL(for: descriptor, in: cacheRoot)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func previewDirectory(in cacheRoot: URL) -> URL {
        cacheRoot.appendingPathComponent(
            "DeviceMapDetailPreviews-v\(SavedMapDetailPreviewStore.cacheVersion)",
            isDirectory: true
        )
    }
}

@MainActor
private enum OfflineMapFallbackPreviewRenderer {
    private static let size = CGSize(width: 160, height: 96)
    private static let padding: CGFloat = 8

    static func image(for bounds: OfflineMapPreviewBounds) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let centerLatitude = (bounds.minLatitude + bounds.maxLatitude) / 2
            let longitudeScale = max(0.1, cos(centerLatitude * .pi / 180))
            let projectedWidth = (bounds.maxLongitude - bounds.minLongitude) * longitudeScale
            let projectedHeight = bounds.maxLatitude - bounds.minLatitude
            let scale = min(
                (Double(size.width - padding * 2) / projectedWidth),
                (Double(size.height - padding * 2) / projectedHeight)
            )
            let width = CGFloat(projectedWidth * scale)
            let height = CGFloat(projectedHeight * scale)
            let rect = CGRect(
                x: (size.width - width) / 2,
                y: (size.height - height) / 2,
                width: width,
                height: height
            )
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 3)
            UIColor(
                red: 76 / 255,
                green: 139 / 255,
                blue: 168 / 255,
                alpha: 0.82
            ).setFill()
            path.fill()
            UIColor(
                red: 40 / 255,
                green: 96 / 255,
                blue: 124 / 255,
                alpha: 1
            ).setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }
}
#endif

nonisolated enum OfflineMapServerIdentity {
    private static var managedIdentity: String {
        "managed:\(normalized(OfflineMapServiceConfig.defaultServerURLString))"
    }

    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            return trimmed.lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443) ||
            (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        while !components.path.isEmpty && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? trimmed.lowercased()
    }

    static func isManaged(_ value: String?) -> Bool {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        let normalizedValue = normalized(value)
        return ([
            OfflineMapServiceConfig.developmentServerURLString,
            OfflineMapServiceConfig.productionServerURLString,
        ] + OfflineMapDefaults.legacyServerURLs)
            .contains { normalized($0) == normalizedValue }
    }

    static func recoveryKey(_ value: String) -> String {
        isManaged(value) ? managedIdentity : normalized(value)
    }
}

nonisolated enum SavedMapReaderRequirementsMigrationPolicy {
    static func shouldDeriveFromSignedManifest(
        generationServerURLString: String?,
        isDevelopmentBuild: Bool
    ) -> Bool {
        guard isDevelopmentBuild, let generationServerURLString else {
            return false
        }
        return OfflineMapServerIdentity.normalized(generationServerURLString) ==
            OfflineMapServerIdentity.normalized(
                OfflineMapServiceConfig.developmentServerURLString
            )
    }
}

nonisolated enum MapActivationDecision: Equatable {
    case pending(String)
    case installed
    case failed(String)
}

nonisolated struct MapActivationEvaluation: Equatable {
    let decision: MapActivationDecision
    let observedCurrentAttempt: Bool
}

nonisolated enum MapActivationReconciler {
    static func evaluate(expectedMapId: String,
                         sessionId: String,
                         previousMapId: String?,
                         previousSessionId: String?,
                         previousSequence: UInt32?,
                         acceptedSequence: UInt32?,
                         observedCurrentAttempt: Bool,
                         activeMapId: String?,
                         activeSessionId: String?,
                         activationStatus: String?,
                         activationSequence: UInt32?,
                         activationSessionId: String?,
                         activationMapId: String?,
                         activationError: String?) -> MapActivationEvaluation {
        let activeMapId = activeMapId?.isEmpty == false ? activeMapId : nil
        let sessionMatches = activationSessionId == sessionId
        let sequenceAdvanced: Bool
        if let previousSequence, let activationSequence {
            // Serial-number arithmetic accepts wrap but rejects stale/out-of-order status.
            let distance = activationSequence &- previousSequence
            sequenceAdvanced = distance != 0 && distance < 0x8000_0000
        } else {
            sequenceAdvanced = false
        }

        let acknowledgedSequenceMatches = acceptedSequence != nil &&
            activationSequence == acceptedSequence
        let sequenceMatchesAttempt = acceptedSequence == nil || acknowledgedSequenceMatches
        let statusIsNotOlder = previousSequence == nil || activationSequence == nil ||
            sequenceAdvanced || acknowledgedSequenceMatches
        var observedCurrentAttempt = observedCurrentAttempt
        if sessionMatches, sequenceMatchesAttempt, statusIsNotOlder {
            observedCurrentAttempt = observedCurrentAttempt || sequenceAdvanced ||
                acknowledgedSequenceMatches || activationStatus == "activating"
        }

        if sessionMatches, sequenceMatchesAttempt, statusIsNotOlder, observedCurrentAttempt {
            if activationStatus == "failed" {
                return MapActivationEvaluation(
                    decision: .failed(activationError ?? "device reported activation failure"),
                    observedCurrentAttempt: true
                )
            }
            if activationStatus == "installed" {
                if let activationMapId,
                   !activationMapId.isEmpty,
                   activationMapId != expectedMapId {
                    return MapActivationEvaluation(
                        decision: .failed(
                            "device activated \(activationMapId) instead of \(expectedMapId)"
                        ),
                        observedCurrentAttempt: true
                    )
                }
                return MapActivationEvaluation(
                    decision: .installed,
                    observedCurrentAttempt: true
                )
            }
        }

        // Pointer selection precedes renderer acknowledgement. Neither exact session
        // identity nor a changed map ID can complete a live attempt, including after
        // reboot on legacy firmware that has lost its terminal activation status.

        let state: String
        if sessionMatches, let activationStatus, !activationStatus.isEmpty {
            state = activationStatus
        } else if activeMapId == expectedMapId {
            state = "active map is \(expectedMapId); waiting for current activation"
        } else {
            state = "waiting for activation status"
        }
        return MapActivationEvaluation(
            decision: .pending(state),
            observedCurrentAttempt: observedCurrentAttempt
        )
    }
}

nonisolated enum MapActivationTransport {
    static func isAmbiguousResponseError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorCallIsActive,
            NSURLErrorDataNotAllowed,
        ].contains(nsError.code)
    }
}

nonisolated enum MapArchiveUploadFallback {
    static func shouldUseForeground(
        for error: Error,
        allowLocalStorageFailure: Bool = false
    ) -> Bool {
        if let platformError = error as? OfflineMapPlatformError,
           case .serverStatus(let status, _) = platformError,
           status == 400 || status == 413 {
            // Older firmware rejects pack.zip as an unknown path (400).
            // Current firmware caps a single archive at 512 MiB (413), while
            // its per-file protocol can still accept the same valid map.
            return true
        }
        return allowLocalStorageFailure && isLocalStorageFailure(error)
    }

    private static func isLocalStorageFailure(
        _ error: Error,
        depth: Int = 0
    ) -> Bool {
        guard depth < 4 else { return false }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain &&
            nsError.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if nsError.domain == NSURLErrorDomain && [
            URLError.Code.fileDoesNotExist.rawValue,
            URLError.Code.noPermissionsToReadFile.rawValue,
            URLError.Code.cannotOpenFile.rawValue,
            URLError.Code.cannotCreateFile.rawValue,
            URLError.Code.dataLengthExceedsMaximum.rawValue,
        ].contains(nsError.code) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 28 {
            return true
        }
        guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error else {
            return false
        }
        return isLocalStorageFailure(underlying, depth: depth + 1)
    }
}

nonisolated enum MapArchiveUploadStrategy {
    static func requiresCompatibilityArchive(for archive: OfflineMapPackArchive) -> Bool {
        archive.entries.contains { $0.path == "preview.png" }
    }
}

@MainActor
final class OfflineMapPreviewLoadRegistry {
    private var tokens: [String: UUID] = [:]

    func begin(for key: String) -> UUID {
        let token = UUID()
        tokens[key] = token
        return token
    }

    func finishIfCurrent(_ token: UUID, for key: String) -> Bool {
        guard tokens[key] == token else { return false }
        tokens.removeValue(forKey: key)
        return true
    }

    func isCurrent(_ token: UUID, for key: String) -> Bool {
        tokens[key] == token
    }

    func invalidate(_ key: String) {
        tokens.removeValue(forKey: key)
    }

    func removeAll() {
        tokens.removeAll()
    }
}

private struct PreparedMapTransfer {
    let artifact: VerifiedBikeMapArtifact

    var mapID: String { artifact.mapID }
    var sessionID: String { artifact.signedManifestReceipt }
}

nonisolated enum MapTransferOutcomePolicy {
    static func outcome(after error: Error, activationMayBeInFlight: Bool) -> String {
        if activationMayBeInFlight,
           let platformError = error as? OfflineMapPlatformError,
           case .serverStatus(let status, _) = platformError,
           status == 408 {
            return "unconfirmed"
        }
        if activationMayBeInFlight,
           error is CancellationError || MapActivationTransport.isAmbiguousResponseError(error) {
            return "unconfirmed"
        }
        return "failed"
    }
}

nonisolated enum MapActivationConfirmationResult: Equatable {
    case installed
    case cancelled
    case retiredUnknown
    case continuesOnDevice(lastState: String)
}

nonisolated enum CachedPackRecoveryDecision: Equatable {
    case installed
    case pending
    case absent

    static func evaluate(
        expectedSessionId: String,
        activeSessionId: String,
        activationStatus: String,
        activationSessionId: String,
        bindsOriginalObservation: Bool = false
    ) -> CachedPackRecoveryDecision {
        if activationSessionId == expectedSessionId, activationStatus == "installed" {
            return bindsOriginalObservation ? .installed : .absent
        }
        // Only a live activation for this session waits. An exact active pointer
        // alone (for example after a reboot lost the terminal result) is not
        // evidence: re-send the same signed stream for a fresh terminal result.
        if activationSessionId == expectedSessionId,
           ["receiving", "paused", "finalizing", "ready", "activating", "installed"]
            .contains(activationStatus) {
            return .pending
        }
        return .absent
    }
}

nonisolated enum ExistingMapStreamAttemptDisposition: Equatable {
    case upload
    case awaitDevice
    case installed

    static func evaluate(
        expectedSessionID: String,
        activeSessionID: String?,
        activationStatus: String?,
        activationSessionID: String?,
        bindsOriginalObservation: Bool = false
    ) -> Self {
        // activeSessionID is deliberately not evidence: the pointer precedes the
        // renderer ACK and survives reboots that lose the terminal result. With
        // no live activation for this session, re-send the identical signed
        // stream; the device verifies its bytes and reports a fresh result.
        guard activationSessionID == expectedSessionID else { return .upload }
        switch activationStatus {
        case "installed":
            return bindsOriginalObservation ? .installed : .upload
        case "receiving", "finalizing", "ready", "activating":
            return .awaitDevice
        default:
            // Paused and failed streams need a matching retry from byte zero.
            return .upload
        }
    }
}

nonisolated enum MapTransferSessionIdentity {
    static func make(mapId: String, manifestData: Data) -> String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        )
        let sanitized = mapId.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let value = String(sanitized).trimmingCharacters(
            in: CharacterSet(charactersIn: ".-")
        )
        if value.isEmpty {
            return UUID().uuidString.lowercased()
        }
        let manifestDigest = FirmwareUpdateManager.sha256Hex(manifestData)
        let suffix = String(manifestDigest.prefix(16))
        return "\(String(value.prefix(63)))-\(suffix)"
    }
}

nonisolated enum OfflineMapPollingRetryPolicy {
    static func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        if let platformError = error as? OfflineMapPlatformError,
           case .serverStatus(let status, _) = platformError {
            return status == 408 || status == 425 || status == 429 || (500...599).contains(status)
        }
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .resourceUnavailable,
            .dataNotAllowed,
        ].contains(urlError.code)
    }

    static func delayNanoseconds(failureCount: Int) -> UInt64 {
        let exponent = min(max(failureCount - 1, 0), 4)
        let seconds = min(2 * (1 << exponent), 30)
        return UInt64(seconds) * 1_000_000_000
    }
}

nonisolated enum OfflineMapOnboardingStep: Equatable {
    case welcome
    case location
    case download
}

nonisolated enum OfflineMapOnboardingPresentation: Equatable {
    case hidden
    case step(OfflineMapOnboardingStep)
}

nonisolated enum OfflineMapOnboardingPolicy {
    static func presentation(
        hasCompletedFirstRun: Bool,
        hasCompletedLocationStep: Bool,
        needsLocationAuthorization: Bool,
        confirmedDeviceMapMissing: Bool
    ) -> OfflineMapOnboardingPresentation {
        if !hasCompletedFirstRun {
            return .step(.welcome)
        }

        if !hasCompletedLocationStep && needsLocationAuthorization {
            return .step(.location)
        }

        return confirmedDeviceMapMissing ? .step(.download) : .hidden
    }

    static func visibleStep(
        presentation: OfflineMapOnboardingPresentation,
        isStatePrepared: Bool,
        isDismissed: Bool,
        isMapAreaSelectionActive: Bool,
        isOfflineMapOperationBlocking: Bool
    ) -> OfflineMapOnboardingStep? {
        guard isStatePrepared,
              !isDismissed,
              !isMapAreaSelectionActive,
              case .step(let step) = presentation else {
            return nil
        }

        switch step {
        case .welcome, .location:
            return step
        case .download:
            return isOfflineMapOperationBlocking ? nil : step
        }
    }

    static func shouldOfferDownload(
        isLocationAuthorized: Bool,
        isNavigationReady: Bool,
        hasSDCard: Bool?,
        activeMapId: String,
        mapStateKnown: Bool,
        mapFoundForCurrentLocation: Bool?
    ) -> Bool {
        guard isLocationAuthorized,
              isNavigationReady,
              hasSDCard == true else {
            return false
        }
        if activeMapId.isEmpty {
            return true
        }
        return mapStateKnown && mapFoundForCurrentLocation == false
    }
}

@MainActor
enum OfflineMapJobPoller {
    static func waitForReady(
        jobId: String,
        pollIntervalNanoseconds: UInt64,
        fetch: @escaping (String) async throws -> OfflineMapJob,
        sleep: @escaping (UInt64) async throws -> Void,
        onUpdate: @escaping (OfflineMapJob) -> Void,
        onRetry: @escaping () -> Void,
        legacyFailedGraceSeconds: TimeInterval = 30,
        monotonicNow: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) async throws -> OfflineMapJob {
        var consecutiveFailures = 0
        var legacyFailedAttempt: Int?
        var legacyFailedDeadline: TimeInterval?
        while !Task.isCancelled {
            let job: OfflineMapJob
            do {
                job = try await fetch(jobId)
                consecutiveFailures = 0
            } catch {
                guard OfflineMapPollingRetryPolicy.shouldRetry(error) else { throw error }
                consecutiveFailures += 1
                onRetry()
                try await sleep(
                    OfflineMapPollingRetryPolicy.delayNanoseconds(
                        failureCount: consecutiveFailures
                    )
                )
                continue
            }

            if job.status != "failed" {
                legacyFailedAttempt = nil
                legacyFailedDeadline = nil
            }
            if job.mayBeLegacyRetryTransition,
               let attempt = job.attempts {
                // Older workers briefly persisted FAILED before QUEUED. Confirm
                // this ambiguous state for a bounded grace window so rolling
                // deployments do not discard a job the server is retrying.
                // Inline-worker failures remain terminal when the window ends.
                let observedAt = monotonicNow()
                if legacyFailedAttempt != attempt || legacyFailedDeadline == nil {
                    legacyFailedAttempt = attempt
                    legacyFailedDeadline = observedAt + max(
                        0,
                        legacyFailedGraceSeconds
                    )
                }
                if let deadline = legacyFailedDeadline, observedAt < deadline {
                    try await sleep(pollIntervalNanoseconds)
                    continue
                }
            }

            onUpdate(job)
            if job.status == "ready", job.mapId != nil {
                return job
            }
            if job.status == "cancelled" {
                throw OfflineMapPlatformError.mapJobCancelled
            }
            if job.status == "expired" {
                throw OfflineMapPlatformError.mapJobExpired
            }
            if job.isTerminal {
                throw OfflineMapPlatformError.mapJobFailed(
                    code: job.errorCode,
                    message: job.error ?? "Map job ended with status \(job.status)"
                )
            }
            try await sleep(pollIntervalNanoseconds)
        }
        throw CancellationError()
    }
}

@MainActor
enum OfflineMapJobCreator {
    static func create(
        request: OfflineMapJobRequest,
        maximumAttempts: Int = 3,
        create: @escaping (OfflineMapJobRequest) async throws -> OfflineMapJob,
        list: @escaping () async throws -> [OfflineMapJob],
        sleep: @escaping (UInt64) async throws -> Void,
        onRetry: @escaping () -> Void
    ) async throws -> OfflineMapJob {
        precondition(maximumAttempts > 0)
        var lastError: Error?
        for attempt in 1...maximumAttempts {
            do {
                return try await create(request)
            } catch {
                guard OfflineMapPollingRetryPolicy.shouldRetry(error) else { throw error }
                lastError = error
            }

            do {
                if let recovered = try await list().first(where: { job in
                    job.clientInstallationId == request.clientInstallationId &&
                        job.clientRequestId == request.clientRequestId
                }) {
                    return recovered
                }
            } catch {
                guard OfflineMapPollingRetryPolicy.shouldRetry(error) else { throw error }
                lastError = error
            }

            if attempt < maximumAttempts {
                onRetry()
                try await sleep(
                    OfflineMapPollingRetryPolicy.delayNanoseconds(failureCount: attempt)
                )
            }
        }
        throw lastError ?? OfflineMapPlatformError.invalidResponse
    }
}

nonisolated enum OfflineMapJobPersistence {
    private static let activeJobIdKey = "offlineMap.activeJobId"
    private static let installOnDeviceKey = "offlineMap.activeJobInstallOnDevice"
    private static let serverURLKey = "offlineMap.activeJobServerURL"
    private static let downloadedJobIdKey = "offlineMap.activeJobDownloadedJobId"
    private static let downloadedMapIdKey = "offlineMap.activeJobDownloadedMapId"

    static func activeJobId(defaults: UserDefaults) -> String? {
        guard let value = defaults.string(forKey: activeJobIdKey), !value.isEmpty else {
            return nil
        }
        return value
    }

    static func shouldInstallOnDevice(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: installOnDeviceKey)
    }

    static func serverURLString(defaults: UserDefaults) -> String? {
        guard let value = defaults.string(forKey: serverURLKey), !value.isEmpty else {
            return nil
        }
        return value
    }

    static func downloadedJobId(defaults: UserDefaults) -> String? {
        guard let value = defaults.string(forKey: downloadedJobIdKey), !value.isEmpty else {
            return nil
        }
        return value
    }

    static func downloadedMapId(defaults: UserDefaults) -> String? {
        guard let value = defaults.string(forKey: downloadedMapIdKey), !value.isEmpty else {
            return nil
        }
        return value
    }

    static func save(
        jobId: String,
        installOnDevice: Bool = false,
        serverURLString: String? = nil,
        defaults: UserDefaults
    ) {
        defaults.set(jobId, forKey: activeJobIdKey)
        defaults.set(installOnDevice, forKey: installOnDeviceKey)
        if downloadedJobId(defaults: defaults) != jobId {
            defaults.removeObject(forKey: downloadedJobIdKey)
            defaults.removeObject(forKey: downloadedMapIdKey)
        }
        if let serverURLString, !serverURLString.isEmpty {
            defaults.set(serverURLString, forKey: serverURLKey)
        }
    }

    static func markPackDownloaded(
        jobId: String,
        mapId: String,
        defaults: UserDefaults
    ) {
        guard activeJobId(defaults: defaults) == jobId else { return }
        defaults.set(jobId, forKey: downloadedJobIdKey)
        defaults.set(mapId, forKey: downloadedMapIdKey)
    }

    static func clear(defaults: UserDefaults) {
        defaults.removeObject(forKey: activeJobIdKey)
        defaults.removeObject(forKey: installOnDeviceKey)
        defaults.removeObject(forKey: serverURLKey)
        defaults.removeObject(forKey: downloadedJobIdKey)
        defaults.removeObject(forKey: downloadedMapIdKey)
    }
}

nonisolated enum OfflineMapInstallationIdentity {
    private static let key = "offlineMap.clientInstallationId"

    static func resolve(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: key),
           existing.range(of: "^[A-Za-z0-9_-]{8,128}$", options: .regularExpression) != nil {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: key)
        return created
    }
}

nonisolated enum OfflineMapInstallationRefreshBackoff {
    private static let keyPrefix = "offlineMap.installationRefreshDeferredUntil."
    static let retryInterval: TimeInterval = 25 * 60 * 60

    private static func key(serverURLString: String) -> String {
        keyPrefix + OfflineMapServerIdentity.normalized(serverURLString)
    }

    static func shouldDefer(
        serverURLString: String,
        defaults: UserDefaults,
        now: Date = Date()
    ) -> Bool {
        defaults.double(forKey: key(serverURLString: serverURLString)) >
            now.timeIntervalSince1970
    }

    static func deferRefresh(
        serverURLString: String,
        defaults: UserDefaults,
        now: Date = Date()
    ) {
        defaults.set(
            now.addingTimeInterval(retryInterval).timeIntervalSince1970,
            forKey: key(serverURLString: serverURLString)
        )
    }

    static func clear(serverURLString: String, defaults: UserDefaults) {
        defaults.removeObject(forKey: key(serverURLString: serverURLString))
    }
}

nonisolated enum OfflineMapInstallationCredentialStoreError: LocalizedError {
    case persistenceFailure(Int32)

    var errorDescription: String? {
        switch self {
        case .persistenceFailure(let status):
            "Could not securely save the map service installation credential (\(status))."
        }
    }
}

nonisolated struct OfflineMapInstallationCredentialStore {
    private static let service = "org.openbikecomputer.map-platform-installation-v1"
    private static let fallbackKeyPrefix = "offlineMap.installationCredential."
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load(serverURLString: String) -> OfflineMapInstallationCredential? {
        let account = OfflineMapServerIdentity.normalized(serverURLString)
#if os(iOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
#else
        guard let data = defaults.data(forKey: Self.fallbackKeyPrefix + account) else {
            return nil
        }
#endif
        return try? JSONDecoder().decode(OfflineMapInstallationCredential.self, from: data)
    }

    func save(
        _ credential: OfflineMapInstallationCredential,
        serverURLString: String
    ) throws {
        let account = OfflineMapServerIdentity.normalized(serverURLString)
        let data = try JSONEncoder().encode(credential)
#if os(iOS)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw OfflineMapInstallationCredentialStoreError.persistenceFailure(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw OfflineMapInstallationCredentialStoreError.persistenceFailure(updateStatus)
        }
#else
        defaults.set(data, forKey: Self.fallbackKeyPrefix + account)
#endif
    }

    func delete(serverURLString: String) {
        let account = OfflineMapServerIdentity.normalized(serverURLString)
#if os(iOS)
        _ = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
#else
        defaults.removeObject(forKey: Self.fallbackKeyPrefix + account)
#endif
    }
}

nonisolated struct OfflineMapLegacyBearerTokenStore {
    private static let service = "org.openbikecomputer.map-platform-legacy-bearer-v1"
    private static let fallbackKeyPrefix = "offlineMap.legacyBearerCredential."
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load(serverURLString: String) -> String? {
        let account = OfflineMapServerIdentity.normalized(serverURLString)
#if os(iOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
#else
        guard let data = defaults.data(forKey: Self.fallbackKeyPrefix + account) else {
            return nil
        }
#endif
        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            return nil
        }
        return token
    }

    func save(_ token: String, serverURLString: String) throws {
        let account = OfflineMapServerIdentity.normalized(serverURLString)
        let data = Data(token.utf8)
#if os(iOS)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw OfflineMapInstallationCredentialStoreError.persistenceFailure(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw OfflineMapInstallationCredentialStoreError.persistenceFailure(updateStatus)
        }
#else
        defaults.set(data, forKey: Self.fallbackKeyPrefix + account)
#endif
    }
}

nonisolated struct SavedMapArtifactMetadata: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let mapID: String
    var displayName: String?
    let localArtifactFilename: String
    let streamFormatVersion: Int?
    let rendererFormatVersion: Int?
    let jobID: String?
    let serverURLString: String?
    let clientInstallationID: String?
    let primaryArtifact: OfflineMapArtifact?
    let legacyArtifact: OfflineMapArtifact?
    var lastTransferProtocol: Int?
    var lastTransferStreamFormat: Int?
    var lastTransferSessionID: String?
    var lastBackgroundTaskID: Int?
    var lastDeviceSequence: UInt32?
    var lastDeviceState: String?
    var lastDeviceStep: Int?
    var lastDeviceStepCount: Int?
    var lastDeviceProgress: Int?
    var expectedActiveMapID: String?
    var expectedActiveSessionID: String?
    var lastTransferOutcome: String?
    var userDefinedDisplayName: Bool? = nil
    var downloadReceiptID: String? = nil
    var catalogMapEntryID: String? = nil
    var catalogLibraryID: String? = nil
    var originChannel: String? = nil
    var catalogAliasRevision: Int? = nil
    var sourceShareID: String? = nil
    var catalogSyncState: String? = nil
    var readerRequirements: OfflineMapReaderRequirements? = nil
    var catalogContentReceipt: String? = nil
    var topography: VerifiedBikeMapTopography? = nil
}

nonisolated enum SavedMapRendererCompatibilityPolicy {
    static func isCompatible(
        rendererFormatVersion: Int?,
        supportsStreetLabels: Bool,
        supports3DBuildings: Bool,
        supportsTopographicContours: Bool
    ) -> Bool {
        switch rendererFormatVersion {
        case nil, 1:
            return true
        case 2:
            return supportsStreetLabels
        case 3:
            return supports3DBuildings
        case 4:
            return supportsStreetLabels && supports3DBuildings &&
                supportsTopographicContours
        default:
            return false
        }
    }
}

nonisolated enum SavedMapArtifactMetadataStore {
    static func metadataURL(for artifactURL: URL) -> URL {
        artifactURL.appendingPathExtension("map.json")
    }

    static func load(for artifactURL: URL) -> SavedMapArtifactMetadata? {
        guard let data = try? Data(contentsOf: metadataURL(for: artifactURL)),
              let metadata = try? JSONDecoder().decode(SavedMapArtifactMetadata.self, from: data),
              metadata.schemaVersion == SavedMapArtifactMetadata.currentSchemaVersion,
              metadata.localArtifactFilename == artifactURL.lastPathComponent else {
            return nil
        }
        return metadata
    }

    static func save(_ metadata: SavedMapArtifactMetadata, for artifactURL: URL) throws {
        guard metadata.schemaVersion == SavedMapArtifactMetadata.currentSchemaVersion,
              metadata.localArtifactFilename == artifactURL.lastPathComponent else {
            throw OfflineMapPlatformError.invalidPack("saved map metadata does not match its artifact")
        }
        let data = try JSONEncoder.offlineMap.encode(metadata)
        try data.write(to: metadataURL(for: artifactURL), options: .atomic)
    }

    static func delete(for artifactURL: URL) throws {
        let url = metadataURL(for: artifactURL)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
#if canImport(UIKit)
        try SavedMapSnapshotPreviewStore.delete(for: artifactURL)
#endif
    }
}

typealias SavedMapArtifactMetadataSaveOperation = @MainActor (
    SavedMapArtifactMetadata,
    URL
) throws -> Void

// A replacement is a two-file transaction. Catch-based rollback alone cannot
// survive process termination between the artifact and metadata renames.
nonisolated enum SavedMapStorageDirectory {
    static func prepare(directory: URL, legacy: URL) throws -> URL {
        let manager = FileManager.default
        if manager.fileExists(atPath: legacy.path) {
            try SavedMapReplacementJournal.recover(in: legacy)
            if !manager.fileExists(atPath: directory.path) {
                try manager.moveItem(at: legacy, to: directory)
            } else {
                // An older app may have populated Caches after a downgrade.
                // Merge missing pairs; never overwrite a current saved artifact.
                try mergeMissingPairs(from: legacy, to: directory)
                let recovery = directory.deletingLastPathComponent()
                    .appendingPathComponent("OfflineMapLegacyRecovery", isDirectory: true)
                try manager.createDirectory(at: recovery, withIntermediateDirectories: true)
                try manager.moveItem(at: legacy, to: recovery.appendingPathComponent(UUID().uuidString))
                var recoveryURL = recovery
                var excluded = URLResourceValues()
                excluded.isExcludedFromBackup = true
                try recoveryURL.setResourceValues(excluded)
            }
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try SavedMapReplacementJournal.recover(in: directory)
        return directory
    }

    private static func mergeMissingPairs(from legacy: URL, to directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for artifact in try manager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
            let destination = directory.appendingPathComponent(artifact.lastPathComponent)
            if artifact.lastPathComponent == "Compatibility" {
                try mergeMissingPairs(from: artifact, to: destination)
            } else if ["zip", "bmap"].contains(artifact.pathExtension),
                      !manager.fileExists(atPath: destination.path) {
                let metadata = SavedMapArtifactMetadataStore.metadataURL(for: artifact)
                let newMetadata = SavedMapArtifactMetadataStore.metadataURL(for: destination)
                if manager.fileExists(atPath: metadata.path) {
                    if manager.fileExists(atPath: newMetadata.path) { try manager.removeItem(at: newMetadata) }
                    try manager.moveItem(at: metadata, to: newMetadata)
                    try SavedMapReplacementJournal.sync(directory)
                }
                try manager.moveItem(at: artifact, to: destination)
                try SavedMapReplacementJournal.sync(directory)
                try SavedMapReplacementJournal.sync(legacy)
            }
        }
    }
}

nonisolated struct SavedMapReplacementJournal: Codable {
    let filename: String
    let id: UUID
    let hadArtifact: Bool
    let hadMetadata: Bool
    var committed: Bool

    func artifact(in directory: URL) -> URL { directory.appendingPathComponent(filename) }
    func backup(in directory: URL) -> URL {
        directory.appendingPathComponent(".\(filename).\(id.uuidString).backup")
    }
    func url(in directory: URL) -> URL {
        directory.appendingPathComponent(".\(filename).replacement.json")
    }

    static func sync(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }

    func save(in directory: URL) throws {
        try JSONEncoder().encode(self).write(to: url(in: directory), options: .atomic)
        try Self.sync(url(in: directory))
        try Self.sync(directory)
    }

    static func begin(at destination: URL) throws -> Self {
        let manager = FileManager.default
        let value = Self(
            filename: destination.lastPathComponent, id: UUID(),
            hadArtifact: manager.fileExists(atPath: destination.path),
            hadMetadata: manager.fileExists(atPath: SavedMapArtifactMetadataStore.metadataURL(for: destination).path),
            committed: false
        )
        try value.save(in: destination.deletingLastPathComponent())
        return value
    }

    func finish(in directory: URL) throws {
        let manager = FileManager.default
        let destination = artifact(in: directory)
        let old = backup(in: directory)
        let pairs = [
            (destination, old, hadArtifact),
            (SavedMapArtifactMetadataStore.metadataURL(for: destination),
             SavedMapArtifactMetadataStore.metadataURL(for: old), hadMetadata)
        ]
        for (current, previous, existed) in pairs {
            if manager.fileExists(atPath: previous.path) {
                if committed {
                    try manager.removeItem(at: previous)
                } else {
                    if manager.fileExists(atPath: current.path) { try manager.removeItem(at: current) }
                    try manager.moveItem(at: previous, to: current)
                }
            } else if !committed && !existed && manager.fileExists(atPath: current.path) {
                try manager.removeItem(at: current)
            }
        }
        try Self.sync(directory)
        try manager.removeItem(at: url(in: directory))
        try Self.sync(directory)
    }

    static func recover(in directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        for file in files where file.lastPathComponent.hasSuffix(".replacement.json") {
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  (attributes.fileSize ?? Int.max) <= 4096 else { throw POSIXError(.EINVAL) }
            let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            guard !value.filename.isEmpty, !value.filename.hasPrefix("."),
                  !value.filename.contains("/"), !value.filename.contains("\\"),
                  ["zip", "bmap"].contains(URL(fileURLWithPath: value.filename).pathExtension),
                  value.url(in: directory).standardizedFileURL == file.standardizedFileURL else {
                throw POSIXError(.EINVAL)
            }
            try value.finish(in: directory)
        }
        // Older releases left UUID backups without a journal. Recover only an
        // unambiguous missing artifact; preserve conflicting copies for repair.
        let backups = files.filter { $0.lastPathComponent.hasSuffix(".backup") }
        for old in backups {
            let name = old.lastPathComponent
            guard name.hasPrefix("."), name.count > 45 else { continue }
            let suffix = String(name.dropLast(7).suffix(36))
            guard UUID(uuidString: suffix) != nil else { continue }
            let filename = String(name.dropFirst().dropLast(44))
            let destination = directory.appendingPathComponent(filename)
            guard ["zip", "bmap"].contains(destination.pathExtension),
                  !FileManager.default.fileExists(atPath: destination.path),
                  backups.filter({ $0.lastPathComponent.hasPrefix(".\(filename).") }).count == 1 else { continue }
            // Publish metadata first so a restart can safely repeat artifact recovery.
            let oldMetadata = SavedMapArtifactMetadataStore.metadataURL(for: old)
            let metadata = SavedMapArtifactMetadataStore.metadataURL(for: destination)
            if FileManager.default.fileExists(atPath: oldMetadata.path) {
                if FileManager.default.fileExists(atPath: metadata.path) { try FileManager.default.removeItem(at: metadata) }
                try FileManager.default.moveItem(at: oldMetadata, to: metadata)
            }
            try FileManager.default.moveItem(at: old, to: destination)
            try Self.sync(directory)
        }
    }
}

nonisolated enum SavedMapStreamMigrationFallback {
    static func shouldUseLegacyArtifact(
        for metadata: SavedMapArtifactMetadata
    ) -> Bool {
        guard let primary = metadata.primaryArtifact,
              primary.isBikeMapStream,
              primary.signatureKeySha256 == nil,
              primary.producerBuildSha256 == nil,
              metadata.legacyArtifact?.isStoredZip == true else {
            return false
        }
        return true
    }
}

nonisolated enum OfflineMapArtifactDownloadChoice: Equatable {
    case bikeMapStream(OfflineMapArtifact, legacy: OfflineMapArtifact?)
    case legacyZip(OfflineMapArtifact?)
}

nonisolated enum OfflineMapArtifactSelector {
    static func select(
        artifacts: [OfflineMapArtifact],
        trustStore: BikeMapStreamTrustStore,
        canDownloadStreamArtifact: Bool = true
    ) throws -> OfflineMapArtifactDownloadChoice {
        let streams = artifacts.filter(\.isBikeMapStream)
        let legacyArtifacts = artifacts.filter(\.isStoredZip)
        guard streams.count <= 1, legacyArtifacts.count <= 1 else {
            throw OfflineMapPlatformError.invalidResponse
        }
        let legacy = legacyArtifacts.first
        // Jobs owned by the pre-registration installation UUID cannot use the
        // new installation-token-protected immutable artifact endpoint. Keep
        // their durable ZIP path recoverable throughout the migration window.
        guard canDownloadStreamArtifact else { return .legacyZip(legacy) }
        let trustedStreams = streams.filter { artifact in
            artifact.signatureKeyId.map(trustStore.contains(keyID:)) == true
        }
        if let stream = trustedStreams.first {
            return .bikeMapStream(stream, legacy: legacy)
        }
        if !streams.isEmpty, !trustStore.isEmpty {
            throw BikeMapStreamFormatError.unknownKeyID(
                streams.compactMap(\.signatureKeyId).first ?? "missing"
            )
        }
        return .legacyZip(legacy)
    }
}

nonisolated enum OfflineMapRecoveryHistory {
    private static let key = "offlineMap.handledServerJobIds"
    private static let forgottenDiscoveryServersKey = "offlineMap.forgottenDiscoveryServers"
    private static let maximumCount = 1_000

    static func handledJobIds(defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    static func markHandled(jobId: String, defaults: UserDefaults) {
        markHandled(jobIds: [jobId], defaults: defaults)
    }

    static func markHandled(jobIds: [String], defaults: UserDefaults) {
        var values = defaults.stringArray(forKey: key) ?? []
        let additions = Set(jobIds)
        values.removeAll { additions.contains($0) }
        values.append(contentsOf: jobIds)
        defaults.set(Array(values.suffix(maximumCount)), forKey: key)
    }

    static func forgetNextDiscovery(serverURLString: String, defaults: UserDefaults) {
        var servers = Set(defaults.stringArray(forKey: forgottenDiscoveryServersKey) ?? [])
        servers.insert(serverIdentity(serverURLString))
        defaults.set(Array(servers).sorted(), forKey: forgottenDiscoveryServersKey)
    }

    static func shouldForgetNextDiscovery(
        serverURLString: String,
        defaults: UserDefaults
    ) -> Bool {
        let servers = Set(defaults.stringArray(forKey: forgottenDiscoveryServersKey) ?? [])
        return servers.contains(serverIdentity(serverURLString))
    }

    static func consumeForgottenDiscovery(
        serverURLString: String,
        jobIds: [String],
        defaults: UserDefaults
    ) -> Bool {
        let identity = serverIdentity(serverURLString)
        var servers = Set(defaults.stringArray(forKey: forgottenDiscoveryServersKey) ?? [])
        guard servers.remove(identity) != nil else { return false }
        markHandled(jobIds: jobIds, defaults: defaults)
        defaults.set(Array(servers).sorted(), forKey: forgottenDiscoveryServersKey)
        return true
    }

    private static func serverIdentity(_ value: String) -> String {
        OfflineMapServerIdentity.recoveryKey(value)
    }
}

nonisolated enum OfflineMapDownloadResponseValidator {
    static func validate(response: URLResponse?, errorBody: @autoclosure () -> String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OfflineMapPlatformError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            throw OfflineMapPlatformError.serverStatus(http.statusCode, errorBody())
        }
    }
}

nonisolated struct OfflineMapActivityCounter {
    private(set) var count = 0

    var isBusy: Bool { count > 0 }

    mutating func begin() {
        count += 1
    }

    mutating func end() {
        precondition(count > 0, "offline map activity counter is unbalanced")
        count -= 1
    }
}

nonisolated struct SavedMapLocalRecord: Equatable, Sendable {
    let packURL: URL
    let mapID: String
    let acceptedSessionIDs: Set<String>
    let displayName: String
    let catalogMapEntryID: String?
}

nonisolated struct SavedMapListItem: Identifiable, Equatable, Sendable {
    let id: String
    let localRecord: SavedMapLocalRecord?
    let deviceMap: DeviceActiveMapDescriptor?
    let displayName: String
    let catalogMap: OfflineMapCatalogMap?

    var packURL: URL? { localRecord?.packURL }
    var isOnIPhone: Bool { localRecord != nil }
    var isActiveOnDevice: Bool { deviceMap != nil }
    var isAvailableInLibrary: Bool { catalogMap != nil }
    var hasKnownMapLibraryCopy: Bool {
        isAvailableInLibrary || localRecord?.catalogMapEntryID != nil
    }
    var canRemoveFromMapLibrary: Bool {
        SavedMapRemovalPolicy.canRemoveFromMapLibrary(
            isOnIPhone: isOnIPhone,
            isActiveOnDevice: isActiveOnDevice,
            isAvailableInLibrary: isAvailableInLibrary
        )
    }
}

nonisolated enum SavedMapRemovalPolicy {
    static func canRemoveFromMapLibrary(
        isOnIPhone: Bool,
        isActiveOnDevice _: Bool,
        isAvailableInLibrary: Bool
    ) -> Bool {
        isAvailableInLibrary && !isOnIPhone
    }

    static func localDeletionMessage(
        displayName: String,
        libraryCopyRemains: Bool
    ) -> String {
        var message = "This removes \(displayName) from Saved Maps on this iPhone."
        if libraryCopyRemains {
            message += " The copy in your Map Library remains and can be removed separately."
        }
        return message + " A copy already installed on the Bike Computer remains there."
    }

    static func libraryRemovalMessage(displayName: String) -> String {
        "This removes \(displayName) from your Map Library. Copies already " +
            "downloaded to an iPhone, installed on a Bike Computer, or added " +
            "by friends are unaffected."
    }
}

@MainActor
final class OfflineMapManager: ObservableObject {
    private static let maximumInMemoryDetailPreviewCount = 3

    typealias PackDownloadOperation = (
        URL,
        OfflineMapDownloadConstraints,
        @escaping @MainActor @Sendable (Double) -> Void,
        @escaping @MainActor @Sendable (OfflineMapByteProgress) -> Void
    ) async throws -> URL

    @Published var serverURLString: String {
        didSet {
            defaults.set(serverURLString, forKey: OfflineMapDefaults.serverURLKey)
            if !canRequestTopographicMap {
                includeTopographyInNewMaps = false
            }
        }
    }
    @Published var centerLatitude: String {
        didSet { defaults.set(centerLatitude, forKey: OfflineMapDefaults.centerLatitudeKey) }
    }
    @Published var centerLongitude: String {
        didSet { defaults.set(centerLongitude, forKey: OfflineMapDefaults.centerLongitudeKey) }
    }
    @Published var sideLengthKm: String {
        didSet { defaults.set(sideLengthKm, forKey: OfflineMapDefaults.sideLengthKey) }
    }
    @Published var topographicMapsEnabled: Bool {
        didSet {
            defaults.set(
                topographicMapsEnabled,
                forKey: OfflineMapDefaults.topographicMapsEnabledKey
            )
#if canImport(UIKit) && canImport(MapKit)
            reloadTopographyOverlay()
#endif
        }
    }
    @Published var includeTopographyInNewMaps: Bool {
        didSet {
            defaults.set(
                includeTopographyInNewMaps,
                forKey: OfflineMapDefaults.includeTopographyInNewMapsKey
            )
        }
    }
    var canRequestTopographicMap: Bool {
        serverURLString == OfflineMapServiceConfig.developmentServerURLString ||
            serverURLString == OfflineMapServiceConfig.productionServerURLString
    }
    @Published private(set) var currentJob: OfflineMapJob?
    @Published private(set) var downloadURL: URL?
    @Published private(set) var downloadedPackURL: URL?
    @Published private(set) var cachedPackURLs: [URL] = []
    @Published private(set) var cachedMapRecords: [SavedMapLocalRecord] = []
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var downloadByteProgress: OfflineMapByteProgress?
    @Published private(set) var transferProgress: Double = 0
    @Published private(set) var isBusy = false
    @Published private(set) var isMapJobProcessing = false
    @Published private(set) var isDeviceTransferBusy = false
    @Published private(set) var hasActiveBackgroundUpload = false
    @Published private(set) var isServerRecoveryCheckPending = false
    @Published private(set) var isMapAreaSelectionActive = false
    @Published private(set) var selectedMapBounds: OfflineMapBounds?
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var activationProgress: MapActivationProgressPresentation?
    @Published private(set) var lastTransferMapId: String
    @Published private(set) var lastTransferOutcome: String
    @Published private(set) var lastTransferObservedIdleOnAnotherMap = false
    // In memory only: like a legacy record, a relaunched process has not
    // observed the last transfer and cannot bind its result to this epoch.
    private var lastTransferConnectionEpoch: UInt64?
    @Published private(set) var catalogMaps: [OfflineMapCatalogMap] = []
    @Published private(set) var catalogShares: [OfflineMapCatalogShare] = []
    @Published private(set) var libraryLinkCode: OfflineMapLibraryLinkCode?
    @Published private(set) var pendingSharePreview: OfflineMapSharePreview?
    @Published private(set) var createdShareURL: URL?
#if canImport(UIKit) && canImport(MapKit)
    @Published private(set) var topographyOverlay: MKTileOverlay?
    @Published private(set) var topographyOverlayStatus =
        "Download a topographic map to show offline contours."
#endif
    @Published private var pendingCatalogAliases: [
        String: OfflineMapCatalogPendingAlias
    ]
    private var pendingCatalogAliasTokens: [String: UUID]

    weak var diagnosticsRecorder: (any RideDiagnosticsEventSink)?

    var activityProgress: Double? {
        OfflineMapProgressPresentation.value(
            job: currentJob,
            downloadProgress: downloadProgress
        )
    }

    var hasPendingMapJob: Bool {
        OfflineMapJobPersistence.activeJobId(defaults: defaults) != nil ||
            isServerRecoveryCheckPending
    }

    var hasTerminalMapJobFailure: Bool {
        ["failed", "expired", "cancelled"].contains(currentJob?.status ?? "")
    }

    var hasPendingDeviceActivation: Bool {
        lastTransferOutcome == "unconfirmed"
    }

    var hasPausedMapUpload: Bool {
        guard let packURL = lastTransferArtifactURL(mapID: lastTransferMapId) else {
            return false
        }
        return isPausedMapUpload(packURL)
    }

    var hasDownloadedPendingDeviceInstall: Bool {
        OfflineMapJobPersistence.shouldInstallOnDevice(defaults: defaults) &&
            hasLocallySavedPendingMap
    }

    var hasLocallySavedPendingMap: Bool {
        guard let jobId = OfflineMapJobPersistence.activeJobId(defaults: defaults),
              OfflineMapJobPersistence.downloadedJobId(defaults: defaults) == jobId,
              let mapId = OfflineMapJobPersistence.downloadedMapId(defaults: defaults),
              let cachedURL = try? cachedPackURL(mapId: mapId) else {
            return false
        }
        return FileManager.default.fileExists(atPath: cachedURL.path)
    }

    private let defaults: UserDefaults
    private let mapPlatformSession: URLSession
    private let bicinoServiceSession: BicinoServiceSession
    private let packDownload: PackDownloadOperation
    private let previewLoad: OfflineMapPreviewLoadOperation
    private let mapSnapshot: OfflineMapSnapshotOperation
    private let detailMapSnapshot: OfflineMapSnapshotOperation
    private let metadataSave: SavedMapArtifactMetadataSaveOperation
    private let cacheDirectoryOverride: URL?
    private let mapStreamTrustStore: BikeMapStreamTrustStore
    private let catalogAppIdentity: MapStreamAppBuildIdentity?
    private let catalogHost: String?
    private let catalogCredentialStore: OfflineMapCatalogCredentialStore
    private let catalogPendingAliasStore: OfflineMapCatalogPendingAliasStore
    private let catalogClient: OfflineMapCatalogClient?
    private let catalogCredentialCoordinator = OfflineMapCatalogCredentialCoordinator()
    private(set) var clientInstallationId: String
    private(set) var clientInstallationToken: String?
    private let deviceTransferManager = DeviceTransferManager()
    private var deviceMapOperationStore = DeviceMapOperationStore.shared
#if HOST_TESTING
    private var fencedRetirementCleanupForTesting: ((BLEManager) async -> Bool)?
#endif
    @Published private var packDisplayNames: [String: String]
    private var mapJobTask: Task<Void, Never>?
    private var mapJobTaskID: UUID?
    private var inventorySyncTask: Task<Void, Never>?
    private var catalogSyncTask: Task<Void, Never>?
    private var pendingShareToken: String?
    private var activationReconciliationTask: Task<Void, Never>?
    private var backgroundUploadObserver: AnyCancellable?
    private var activityCounter = OfflineMapActivityCounter()
#if canImport(UIKit) && canImport(MapKit)
    private var topographyOverlayTask: Task<Void, Never>?
    private var topographyOverlayGeneration = UUID()
#endif
#if canImport(UIKit)
    @Published private var packPreviewImages: [String: UIImage] = [:]
    @Published private var detailPreviewImages: [String: UIImage] = [:]
    @Published private var detailPreviewLoadingKeys: Set<String> = []
    private var detailPreviewAccessOrder: [String] = []
    private var unavailablePackPreviews: Set<String> = []
    private var unavailableDetailPreviews: Set<String> = []
    private var previewLoadTasks: [String: Task<Void, Never>] = [:]
    private let previewLoadRegistry = OfflineMapPreviewLoadRegistry()
    private let detailPreviewLoadRegistry = OfflineMapPreviewLoadRegistry()
    private var currentActiveDeviceMap: DeviceActiveMapDescriptor?
#endif

    init(
        defaults: UserDefaults = .standard,
        mapPlatformSession: URLSession = .shared,
        bicinoServiceSession: BicinoServiceSession? = nil,
        cacheDirectory: URL? = nil,
        mapStreamTrustStore: BikeMapStreamTrustStore? = nil,
        catalogAppIdentity: MapStreamAppBuildIdentity? = .current,
        catalogHost: String? = OfflineMapCatalogConfig.catalogHost,
        catalogClient: OfflineMapCatalogClient? = nil,
        packDownload: @escaping PackDownloadOperation = { url, constraints, onProgress, onByteProgress in
            try await DurableMapDownloadCoordinator.shared.download(
                from: url,
                constraints: constraints,
                onProgress: onProgress,
                onByteProgress: onByteProgress
            )
        },
        previewLoad: @escaping OfflineMapPreviewLoadOperation = { packURL in
            await Task.detached(priority: .utility) {
#if canImport(UIKit)
                let snapshotData = SavedMapSnapshotPreviewStore.imageData(for: packURL)
#else
                let snapshotData: Data? = nil
#endif
                return OfflineMapPreviewLoadResult(
                    snapshotData: snapshotData,
                    packContent: OfflineMapPackPreviewReader.content(for: packURL)
                )
            }.value
        },
        mapSnapshot: @escaping OfflineMapSnapshotOperation = { bounds in
            try await OfflineMapSnapshotPreviewRenderer.pngData(for: bounds)
        },
        detailMapSnapshot: @escaping OfflineMapSnapshotOperation = { bounds in
            try await OfflineMapSnapshotPreviewRenderer.detailPNGData(for: bounds)
        },
        metadataSave: @escaping SavedMapArtifactMetadataSaveOperation = { metadata, url in
            try SavedMapArtifactMetadataStore.save(metadata, for: url)
        },
        diagnosticsRecorder: (any RideDiagnosticsEventSink)? = nil
    ) {
        OfflineMapPackCompatibilityArchive.removeOrphans()
        self.defaults = defaults
        self.mapPlatformSession = mapPlatformSession
        let bicinoServiceSession = bicinoServiceSession ??
            BicinoServiceSession(
                defaults: defaults,
                urlSession: mapPlatformSession
            )
        self.bicinoServiceSession = bicinoServiceSession
        self.packDownload = packDownload
        self.previewLoad = previewLoad
        self.mapSnapshot = mapSnapshot
        self.detailMapSnapshot = detailMapSnapshot
        self.metadataSave = metadataSave
        self.cacheDirectoryOverride = cacheDirectory
        self.mapStreamTrustStore = mapStreamTrustStore ??
            OfflineMapCatalogConfig.mapStreamTrustStore
        self.catalogAppIdentity = catalogAppIdentity
        self.catalogHost = catalogHost
        self.catalogCredentialStore = OfflineMapCatalogCredentialStore(
            defaults: defaults,
            catalogHost: catalogHost
        )
        let catalogPendingAliasStore = OfflineMapCatalogPendingAliasStore(
            defaults: defaults,
            catalogHost: catalogHost
        )
        self.catalogPendingAliasStore = catalogPendingAliasStore
        let pendingCatalogAliases = catalogPendingAliasStore.load()
        self.pendingCatalogAliases = pendingCatalogAliases
        self.pendingCatalogAliasTokens = Dictionary(
            uniqueKeysWithValues: pendingCatalogAliases.keys.map { ($0, UUID()) }
        )
#if HOST_TESTING
        self.catalogClient = catalogClient
#else
        self.catalogClient = catalogClient ?? (try? OfflineMapCatalogClient(
            session: mapPlatformSession
        ))
#endif
        let resolvedServerURL = Self.resolvedServerURL(defaults: defaults)
        let installationCredential = bicinoServiceSession.loadedCredential(
            serverURLString: resolvedServerURL
        )
        self.clientInstallationId = installationCredential?.clientInstallationId ??
            OfflineMapInstallationIdentity.resolve(defaults: defaults)
        self.clientInstallationToken = installationCredential?.clientInstallationToken
        self.packDisplayNames = defaults.dictionary(forKey: OfflineMapDefaults.packDisplayNamesKey) as? [String: String] ?? [:]
        self.serverURLString = resolvedServerURL
        self.centerLatitude = defaults.string(forKey: OfflineMapDefaults.centerLatitudeKey) ?? "35.16755"
        self.centerLongitude = defaults.string(forKey: OfflineMapDefaults.centerLongitudeKey) ?? "136.89451"
        self.sideLengthKm = defaults.string(forKey: OfflineMapDefaults.sideLengthKey) ?? "25"
        self.topographicMapsEnabled = defaults.object(
            forKey: OfflineMapDefaults.topographicMapsEnabledKey
        ) as? Bool ?? false
        self.includeTopographyInNewMaps = (defaults.object(
            forKey: OfflineMapDefaults.includeTopographyInNewMapsKey
        ) as? Bool ?? false) &&
            (resolvedServerURL == OfflineMapServiceConfig.developmentServerURLString ||
             resolvedServerURL == OfflineMapServiceConfig.productionServerURLString)
        self.lastTransferMapId = defaults.string(forKey: OfflineMapDefaults.lastTransferMapIdKey) ?? ""
        let restoredTransferOutcome = defaults.string(
            forKey: OfflineMapDefaults.lastTransferOutcomeKey
        ) ?? ""
        if ["preparing", "uploading", "activating"].contains(restoredTransferOutcome) {
            self.lastTransferOutcome = "unconfirmed"
        } else {
            self.lastTransferOutcome = restoredTransferOutcome
        }
        defaults.set(serverURLString, forKey: OfflineMapDefaults.serverURLKey)
        defaults.set(lastTransferOutcome, forKey: OfflineMapDefaults.lastTransferOutcomeKey)
        refreshCachedPacks()
        restoreLastTransferPresentation()
        self.diagnosticsRecorder = diagnosticsRecorder
        self.deviceTransferManager.diagnosticsRecorder = diagnosticsRecorder
#if os(iOS)
        backgroundUploadObserver = NotificationCenter.default.publisher(
            for: BackgroundMapUploadStateStore.didChangeNotification
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            Task { @MainActor in
                self?.restoreLastTransferPresentation()
                self?.refreshBackgroundUploadActivity()
            }
        }
        BackgroundMapUploadCoordinator.shared.restorePersistedTasks()
        refreshBackgroundUploadActivity()
#endif
    }

    func createCustomCutoutJob() {
        do {
            try createJobAndDownload(request: makeCustomBBoxRequest())
        } catch {
            errorMessage = diagnosticMessage(for: error)
        }
    }

    func beginMapAreaSelection() {
        guard canStartNewMapJob() else { return }
        errorMessage = nil
        selectedMapBounds = nil
        isMapAreaSelectionActive = true
    }

    func cancelMapAreaSelection() {
        isMapAreaSelectionActive = false
    }

    func updateMapAreaSelection(bounds: OfflineMapBounds) {
        selectedMapBounds = bounds
    }

    func createJobFromSelectedMapArea(bleManager: BLEManager) {
        guard canStartNewMapJob() else { return }
        guard !includeTopographyInNewMaps || canRequestTopographicMap else {
            errorMessage = "This map server does not support topographic map creation."
            return
        }
        guard !includeTopographyInNewMaps ||
                !bleManager.hasReceivedDeviceCapabilities ||
                bleManager.supportsTopographicContours else {
            errorMessage = "Update the Bike Computer firmware before creating a topographic map."
            return
        }
        guard let selectedMapBounds else {
            errorMessage = OfflineMapPlatformError.invalidResponse.localizedDescription
            return
        }
        isMapAreaSelectionActive = false
        createJobAndDownload(
            request: OfflineMapJobRequest
                .customBBox(selectedMapBounds)
                .withTopography(includeTopographyInNewMaps)
        )
    }

    func installCurrentLocationMap(location: CLLocation, bleManager: BLEManager) {
        guard canStartNewMapJob() else { return }
        centerLatitude = String(format: "%.6f", location.coordinate.latitude)
        centerLongitude = String(format: "%.6f", location.coordinate.longitude)

        installBoundsMap(
            OfflineMapBounds(
                center: location.coordinate,
                sideLengthKm: Double(sideLengthKm) ?? 25
            ),
            bleManager: bleManager
        )
    }

    func regenerateActiveMap(bleManager: BLEManager) {
        guard canStartNewMapJob(),
              !bleManager.mapTransferActiveMapId.isEmpty,
              let packURL = cachedPackURLs.first(where: {
                  savedMapID(for: $0) == bleManager.mapTransferActiveMapId
              }),
              let archive = try? OfflineMapPackArchive(url: packURL),
              let manifest = try? archive.manifest(),
              let coordinates = manifest.bounds,
              coordinates.count == 4 else {
            errorMessage = "The active map area is unavailable. Choose the area again in Saved Maps."
            return
        }
        installBoundsMap(
            OfflineMapBounds(
                minLon: coordinates[0],
                minLat: coordinates[1],
                maxLon: coordinates[2],
                maxLat: coordinates[3]
            ),
            bleManager: bleManager
        )
    }

    private func installBoundsMap(
        _ bounds: OfflineMapBounds,
        bleManager: BLEManager
    ) {
        guard canStartNewMapJob() else { return }
        guard !includeTopographyInNewMaps || canRequestTopographicMap else {
            errorMessage = "This map server does not support topographic map creation."
            return
        }
        guard !includeTopographyInNewMaps ||
                bleManager.supportsTopographicContours else {
            errorMessage = bleManager.hasReceivedDeviceCapabilities
                ? "Update the Bike Computer firmware to install topographic maps."
                : "Connect to the Bike Computer to check topographic map support."
            return
        }

        startMapJobTask { manager in
            var client = try manager.makeClient()
            client = try await manager.ensureRegisteredInstallation(client: client)
            if try await manager.recoverOwnedServerJobIfAvailable(
                client: client,
                bleManager: bleManager
            ) {
                return
            }
            let request = OfflineMapJobRequest
                .customBBox(bounds)
                .withTopography(manager.includeTopographyInNewMaps)
                .forDevice(
                    firmwareVersion: bleManager.firmwareVersion
                )
                .identified(
                    clientInstallationId: client.clientInstallationId,
                    clientRequestId: UUID().uuidString.lowercased(),
                    installOnDevice: true
                )
            try await manager.requireGenerationCapability(
                for: request,
                client: client
            )
            manager.currentJob = try await manager.createJob(request, client: client)
            manager.persistCurrentJob(installOnDevice: true)
            manager.downloadURL = nil
            manager.downloadedPackURL = nil
            manager.downloadProgress = 0
            manager.downloadByteProgress = nil
            manager.transferProgress = 0
            manager.statusMessage = "creating map"

            try await manager.waitForReadyMap(client: client)
            try await manager.downloadReadyPack(client: client)
            try await manager.transferReadyPack(bleManager: bleManager)
            manager.clearPersistedJob(markHandled: true)
        }
    }

    func resumePendingMapJobIfNeeded(bleManager: BLEManager? = nil) {
        syncDownloadedMapInventoryIfNeeded()
        syncCatalogLibraryIfNeeded()
        guard mapJobTask == nil, !isBusy else {
            return
        }
        if OfflineMapJobPersistence.activeJobId(defaults: defaults) == nil {
            isServerRecoveryCheckPending = true
        }
        startMapJobTask { manager in
            try await manager.recoverPendingMapJob(bleManager: bleManager)
        }
    }

    func retryPendingMapJob(bleManager: BLEManager? = nil) {
        guard hasPendingMapJob, !hasTerminalMapJobFailure else { return }
        guard mapJobTask != nil || !isBusy else { return }
        syncDownloadedMapInventoryIfNeeded()
        syncCatalogLibraryIfNeeded()

        let previousTask = mapJobTask
        previousTask?.cancel()
        let taskID = UUID()
        mapJobTaskID = taskID
        isMapJobProcessing = true
        mapJobTask = Task { [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard let self, mapJobTaskID == taskID else { return }

            downloadURL = nil
            downloadProgress = 0
            downloadByteProgress = nil
            errorMessage = nil
            statusMessage = currentJob?.mapId == nil
                ? "resuming map preparation"
                : "retrying map download"

            await runBusy {
                try await self.recoverPendingMapJob(bleManager: bleManager)
            }
            if mapJobTaskID == taskID {
                mapJobTask = nil
                mapJobTaskID = nil
                isMapJobProcessing = false
            }
        }
    }

    func pausePendingMapJob() {
        guard mapJobTask != nil else { return }
        mapJobTask?.cancel()
        statusMessage = currentJob?.mapId == nil
            ? "map preparation paused"
            : "map download paused"
    }

    func forgetPendingMapJob() {
        guard hasPendingMapJob else { return }
        if OfflineMapJobPersistence.activeJobId(defaults: defaults) == nil,
           isServerRecoveryCheckPending {
            OfflineMapRecoveryHistory.forgetNextDiscovery(
                serverURLString: serverURLString,
                defaults: defaults
            )
        }
        mapJobTask?.cancel()
        mapJobTask = nil
        mapJobTaskID = nil
        isMapJobProcessing = false
        clearPersistedJob(markHandled: true)
        currentJob = nil
        downloadURL = nil
        downloadProgress = 0
        downloadByteProgress = nil
        transferProgress = 0
        statusMessage = "pending map forgotten"
        errorMessage = nil
    }

    func discardPendingMapAndBeginSelection() {
        forgetPendingMapJob()
        beginMapAreaSelection()
    }

    func refreshJob() {
        guard let jobId = currentJob?.jobId else { return }
        Task {
            await runBusy {
                let client = try await self.ensureRegisteredInstallation(
                    client: self.makeClient()
                )
                self.currentJob = try await client.job(id: jobId)
                self.statusMessage = self.currentJob?.status ?? ""
                if self.currentJob?.mapId == nil {
                    self.downloadURL = nil
                    self.downloadedPackURL = nil
                    self.downloadProgress = 0
                    self.downloadByteProgress = nil
                    self.transferProgress = 0
                }
            }
        }
    }

    func fetchDownloadURL() {
        guard let mapId = currentJob?.mapId,
              let jobId = currentJob?.jobId else {
            errorMessage = OfflineMapPlatformError.missingMapId.localizedDescription
            return
        }
        Task {
            await runBusy {
                let client = try await self.ensureRegisteredInstallation(
                    client: self.makeClient()
                )
                self.downloadURL = try await client.downloadURL(mapId: mapId, jobId: jobId)
                self.statusMessage = "download ready"
            }
        }
    }

    func downloadPack() {
        Task {
            await runBusy {
                let client = try await self.ensureRegisteredInstallation(
                    client: self.makeClient()
                )
                try await self.downloadReadyPack(client: client)
            }
        }
    }

    func transferDownloadedPack(bleManager: BLEManager) {
        startDeviceTransfer { manager in
            guard let packURL = manager.downloadedPackURL else {
                throw OfflineMapPlatformError.missingDownloadURL
            }
            try await manager.transferPack(at: packURL, bleManager: bleManager)
        }
    }

    func transferCachedPack(at packURL: URL, bleManager: BLEManager) {
        startCachedPackTransfer(
            at: packURL,
            bleManager: bleManager,
            resumePausedUpload: isPausedMapUpload(packURL)
        )
    }

    func resumePausedMapUpload(bleManager: BLEManager) {
        guard let packURL = lastTransferArtifactURL(mapID: lastTransferMapId),
              isPausedMapUpload(packURL) else {
            return
        }
        startCachedPackTransfer(
            at: packURL,
            bleManager: bleManager,
            resumePausedUpload: true
        )
    }

    func isPausedMapUpload(_ packURL: URL) -> Bool {
        if let operation = currentDeviceMapOperation, operation.mapID == savedMapID(for: packURL),
           operation.cancellationRequestedAt != nil || ["prepared", "accepted"].contains(operation.lastReceipt?.phase ?? "") {
            return false
        }
        let metadata = SavedMapArtifactMetadataStore.load(for: packURL)
        let candidateMapID = savedMapID(for: packURL)
        let sessionID = metadata?.lastTransferSessionID ?? defaults.string(
            forKey: OfflineMapDefaults.lastTransferSessionIdKey
        )
        let backgroundUploadSucceeded = sessionID.flatMap { sessionID in
            BackgroundMapUploadStateStore.latest(
                mapID: candidateMapID,
                sessionID: sessionID,
                defaults: defaults
            )?.succeeded
        }
        return PausedMapUploadResumePolicy.isAvailable(
            lastTransferOutcome: lastTransferOutcome,
            lastTransferMapID: lastTransferMapId,
            candidateMapID: candidateMapID,
            lastTransferArtifactFilename: defaults.string(
                forKey: OfflineMapDefaults.lastTransferArtifactFilenameKey
            ),
            candidateArtifactFilename: packURL.lastPathComponent,
            lastDeviceState: metadata?.lastDeviceState,
            backgroundUploadSucceeded: backgroundUploadSucceeded,
            observedIdleOnAnotherMap: lastTransferObservedIdleOnAnotherMap,
            statusMessage: statusMessage
        )
    }

    func isAwaitingMapActivationConfirmation(_ packURL: URL) -> Bool {
        guard !isPausedMapUpload(packURL) else { return false }
        let candidateMapID = savedMapID(for: packURL)
        guard lastTransferOutcome == "unconfirmed",
              lastTransferMapId == candidateMapID,
              defaults.string(
                  forKey: OfflineMapDefaults.lastTransferArtifactFilenameKey
              ) == packURL.lastPathComponent,
              let sessionID = defaults.string(
                  forKey: OfflineMapDefaults.lastTransferSessionIdKey
              ),
              !sessionID.isEmpty else {
            return false
        }
        let metadata = SavedMapArtifactMetadataStore.load(for: packURL)
        guard metadata?.lastDeviceState != "paused" else { return false }
        return BackgroundMapUploadStateStore.latest(
            mapID: candidateMapID,
            sessionID: sessionID,
            defaults: defaults
        )?.succeeded == true
    }

    func mapUploadProgress(for packURL: URL) -> Double? {
        guard savedMapID(for: packURL) == lastTransferMapId,
              lastTransferOutcome == "uploading" || hasActiveBackgroundUpload,
              !isPausedMapUpload(packURL) else {
            return nil
        }
        return min(0.99, max(0.02, transferProgress))
    }

    private func startCachedPackTransfer(
        at packURL: URL,
        bleManager: BLEManager,
        resumePausedUpload: Bool
    ) {
        startDeviceTransfer { manager in
            try await manager.transferPack(
                at: packURL,
                bleManager: bleManager,
                resumePausedUpload: resumePausedUpload
            )
        }
    }

    func deleteCachedPack(at packURL: URL) {
        do {
            let mapID = savedMapID(for: packURL)
            let metadata = SavedMapArtifactMetadataStore.load(for: packURL)
            let deletesLastTransferArtifact = defaults.string(
                forKey: OfflineMapDefaults.lastTransferArtifactFilenameKey
            ) == packURL.lastPathComponent
            if FileManager.default.fileExists(atPath: packURL.path) {
                try FileManager.default.removeItem(at: packURL)
            }
            if deletesLastTransferArtifact {
                invalidateLastTransferForDeletedArtifact()
            }
            invalidateCachedPreview(for: packURL)
            try SavedMapArtifactMetadataStore.delete(for: packURL)
            try deleteTopographyCompanions(matching: metadata)
            try deleteCompatibilityArtifacts(mapID: mapID)
            packDisplayNames.removeValue(forKey: packURL.lastPathComponent)
            persistPackDisplayNames()
            if downloadedPackURL == packURL {
                downloadedPackURL = nil
                transferProgress = 0
            }
            refreshCachedPacks()
        } catch {
            errorMessage = diagnosticMessage(for: error)
        }
    }

    func displayName(forCachedPack packURL: URL) -> String {
        let metadata = SavedMapArtifactMetadataStore.load(for: packURL)
        if let displayName = packDisplayNames[packURL.lastPathComponent],
           !displayName.isEmpty,
           (metadata?.userDefinedDisplayName == true ||
               !SavedMapDisplayNamePolicy.isGeneratedGenericName(displayName)) {
            return displayName
        }
        if metadata?.userDefinedDisplayName == true,
           let displayName = metadata?.displayName,
           !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return displayName
        }
        if let displayName = SavedMapDisplayNamePolicy.preferred(metadata?.displayName) {
            return displayName
        }
        if let manifestName = manifestDisplayName(for: packURL) {
            return manifestName
        }
        if currentJob?.mapId == packURL.deletingPathExtension().lastPathComponent {
            return displayNameForCurrentJob()
        }
        return SavedMapDisplayNamePolicy.resolve(
            artifactDisplayName: nil,
            sourceRegionName: nil,
            mapID: packURL.deletingPathExtension().lastPathComponent
        )
    }

    func savedMapListItems(
        activeDeviceMap: DeviceActiveMapDescriptor?,
        scope: SavedMapListScope = .savedMaps
    ) -> [SavedMapListItem] {
        var remainingRecords = cachedMapRecords
        var remainingCatalogMaps = catalogMaps
        var items: [SavedMapListItem] = []

        func takeCatalogMap(for record: SavedMapLocalRecord) -> OfflineMapCatalogMap? {
            let metadata = SavedMapArtifactMetadataStore.load(for: record.packURL)
            let localArtifactSHA256s = Set<String>([
                metadata?.primaryArtifact?.sha256,
                metadata?.legacyArtifact?.sha256,
            ].compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            })
            let index = OfflineMapCatalogReconciliationPolicy.matchingMapIndex(
                catalogMapEntryID: record.catalogMapEntryID,
                localArtifactSHA256s: localArtifactSHA256s,
                catalogMaps: remainingCatalogMaps
            )
            guard let index else { return nil }
            return remainingCatalogMaps.remove(at: index)
        }

        func reconciledDisplayName(
            for record: SavedMapLocalRecord,
            catalogMap: OfflineMapCatalogMap?
        ) -> String {
            if SavedMapArtifactMetadataStore.load(
                for: record.packURL
            )?.catalogSyncState == "pending" {
                return record.displayName
            }
            return catalogMap?.alias ?? record.displayName
        }

        if let activeDeviceMap,
           !isUnconfirmedTransferIdentity(mapID: activeDeviceMap.mapID, sessionID: activeDeviceMap.sessionID) {
            let matchingIndex = activeDeviceMap.sessionID.flatMap { sessionID in
                remainingRecords.firstIndex { record in
                    record.mapID == activeDeviceMap.mapID &&
                        record.acceptedSessionIDs.contains(sessionID)
                }
            }
            if let matchingIndex {
                let record = remainingRecords.remove(at: matchingIndex)
                let catalogMap = takeCatalogMap(for: record)
                items.append(
                    SavedMapListItem(
                        id: "local:\(record.packURL.standardizedFileURL.path)",
                        localRecord: record,
                        deviceMap: activeDeviceMap,
                        displayName: reconciledDisplayName(
                            for: record,
                            catalogMap: catalogMap
                        ),
                        catalogMap: catalogMap
                    )
                )
            } else {
                items.append(
                    SavedMapListItem(
                        id: "device:\(activeDeviceMap.mapID):\(activeDeviceMap.stableIdentity)",
                        localRecord: nil,
                        deviceMap: activeDeviceMap,
                        displayName: SavedMapDisplayNamePolicy.resolve(
                            artifactDisplayName: activeDeviceMap.displayName,
                            sourceRegionName: nil,
                            mapID: activeDeviceMap.mapID
                        ),
                        catalogMap: nil
                    )
                )
            }
        }

        items.append(contentsOf: remainingRecords.map { record in
            let catalogMap = takeCatalogMap(for: record)
            return SavedMapListItem(
                id: "local:\(record.packURL.standardizedFileURL.path)",
                localRecord: record,
                deviceMap: nil,
                displayName: reconciledDisplayName(
                    for: record,
                    catalogMap: catalogMap
                ),
                catalogMap: catalogMap
            )
        })
        items.append(contentsOf: remainingCatalogMaps.map { map in
            SavedMapListItem(
                id: "catalog:\(map.mapEntryId)",
                localRecord: nil,
                deviceMap: nil,
                displayName: map.alias,
                catalogMap: map
            )
        })
        let channel = OfflineMapCatalogConfig.channel(
            generationServerURLString: serverURLString
        )
        return items.filter { scope.includes($0.catalogMap, channel: channel) }
    }

#if canImport(UIKit)
    func updateActiveDeviceMap(_ descriptor: DeviceActiveMapDescriptor?) {
        guard descriptor != currentActiveDeviceMap else { return }
        if let currentActiveDeviceMap {
            let key = devicePreviewCacheKey(for: currentActiveDeviceMap)
            previewLoadRegistry.invalidate(key)
            previewLoadTasks.removeValue(forKey: key)?.cancel()
            packPreviewImages.removeValue(forKey: key)
            unavailablePackPreviews.remove(key)
            detailPreviewLoadRegistry.invalidate(key)
            removeDetailPreviewImage(forKey: key)
            detailPreviewLoadingKeys.remove(key)
            unavailableDetailPreviews.remove(key)
        }
        currentActiveDeviceMap = descriptor
    }

    func previewImage(for item: SavedMapListItem) -> UIImage? {
        if let packURL = item.packURL {
            return previewImage(forCachedPack: packURL)
        }
        guard let descriptor = item.deviceMap else { return nil }
        return packPreviewImages[devicePreviewCacheKey(for: descriptor)]
    }

    func loadPreviewIfNeeded(for item: SavedMapListItem) {
        if let packURL = item.packURL {
            loadPreviewIfNeeded(forCachedPack: packURL)
            return
        }
        guard let descriptor = item.deviceMap else { return }
        loadDevicePreviewIfNeeded(for: descriptor)
    }

    func detailPreviewImage(for item: SavedMapListItem) -> UIImage? {
        guard let key = detailPreviewCacheKey(for: item),
              let image = detailPreviewImages[key] else {
            return nil
        }
        recordDetailPreviewAccess(forKey: key)
        return image
    }

    func isDetailPreviewLoading(for item: SavedMapListItem) -> Bool {
        guard let key = detailPreviewCacheKey(for: item) else { return false }
        return detailPreviewLoadingKeys.contains(key)
    }

    func loadDetailPreviewIfNeeded(for item: SavedMapListItem) async {
        guard let key = detailPreviewCacheKey(for: item),
              detailPreviewImages[key] == nil,
              !unavailableDetailPreviews.contains(key) else {
            return
        }
        let token = detailPreviewLoadRegistry.begin(for: key)
        detailPreviewLoadingKeys.insert(key)
        defer {
            if detailPreviewLoadRegistry.finishIfCurrent(token, for: key) {
                detailPreviewLoadingKeys.remove(key)
            }
        }

        let storedData: Data?
        let bounds: OfflineMapPreviewBounds?
        let storedFileExists: Bool
        let cacheRoot: URL?
        if let packURL = item.packURL {
            let loaded = await Task.detached(priority: .utility) {
                let storedURL = SavedMapDetailPreviewStore.imageURL(for: packURL)
                return (
                    SavedMapDetailPreviewStore.imageData(for: packURL),
                    OfflineMapPackPreviewReader.content(for: packURL)?.bounds,
                    FileManager.default.fileExists(atPath: storedURL.path)
                )
            }.value
            storedData = loaded.0
            bounds = loaded.1
            storedFileExists = loaded.2
            cacheRoot = nil
        } else if let descriptor = item.deviceMap,
                  let root = try? cachedPackDirectory() {
            let loaded = await Task.detached(priority: .utility) {
                let storedURL = DeviceMapDetailPreviewStore.imageURL(
                    for: descriptor,
                    in: root
                )
                return (
                    DeviceMapDetailPreviewStore.imageData(
                        for: descriptor,
                        in: root
                    ),
                    FileManager.default.fileExists(atPath: storedURL.path)
                )
            }.value
            storedData = loaded.0
            bounds = descriptor.bounds
            storedFileExists = loaded.1
            cacheRoot = root
        } else {
            unavailableDetailPreviews.insert(key)
            return
        }

        guard detailPreviewLoadRegistry.isCurrent(token, for: key),
              !Task.isCancelled,
              isDetailPreviewTargetCurrent(item, key: key) else {
            return
        }
        if let image = usableDetailPreviewImage(from: storedData) {
            cacheDetailPreviewImage(image, forKey: key)
            return
        }
        if storedFileExists {
            if let packURL = item.packURL {
                try? SavedMapDetailPreviewStore.delete(for: packURL)
            } else if let descriptor = item.deviceMap, let cacheRoot {
                try? DeviceMapDetailPreviewStore.delete(
                    for: descriptor,
                    in: cacheRoot
                )
            }
        }
        guard let bounds else {
            unavailableDetailPreviews.insert(key)
            return
        }

        let generatedData: Data?
        do {
            generatedData = try await detailMapSnapshot(bounds)
        } catch is CancellationError {
            return
        } catch {
            generatedData = nil
        }
        guard detailPreviewLoadRegistry.isCurrent(token, for: key),
              !Task.isCancelled,
              isDetailPreviewTargetCurrent(item, key: key),
              let generatedData,
              let image = usableDetailPreviewImage(from: generatedData) else {
            return
        }
        if let packURL = item.packURL {
            try? SavedMapDetailPreviewStore.save(generatedData, for: packURL)
        } else if let descriptor = item.deviceMap, let cacheRoot {
            try? DeviceMapDetailPreviewStore.save(
                generatedData,
                for: descriptor,
                in: cacheRoot
            )
        }
        cacheDetailPreviewImage(image, forKey: key)
    }

    func previewImage(forCachedPack packURL: URL) -> UIImage? {
        packPreviewImages[previewCacheKey(for: packURL)]
    }

    func loadPreviewIfNeeded(forCachedPack packURL: URL) {
        let key = previewCacheKey(for: packURL)
        guard packPreviewImages[key] == nil,
              !unavailablePackPreviews.contains(key),
              previewLoadTasks[key] == nil else {
            return
        }
        let token = previewLoadRegistry.begin(for: key)
        let previewLoad = self.previewLoad
        previewLoadTasks[key] = Task { [weak self] in
            let loaded = await previewLoad(packURL)
            guard let self else { return }
            if let image = self.usableSnapshotImage(from: loaded.snapshotData) {
                guard self.previewLoadRegistry.finishIfCurrent(token, for: key) else {
                    return
                }
                self.previewLoadTasks.removeValue(forKey: key)
                guard !Task.isCancelled,
                      self.cachedPackURLs.contains(where: {
                          self.previewCacheKey(for: $0) == key
                      }) else {
                    return
                }
                self.packPreviewImages[key] = image
                return
            }
            guard self.previewLoadRegistry.isCurrent(token, for: key),
                  !Task.isCancelled,
                  self.cachedPackURLs.contains(where: {
                      self.previewCacheKey(for: $0) == key
                  }) else {
                return
            }
            if loaded.snapshotData != nil {
                try? SavedMapSnapshotPreviewStore.delete(for: packURL)
            }
            var publishedFallback = false
            if let image = self.usablePreviewImage(from: loaded.packContent?.imageData) {
                self.packPreviewImages[key] = image
                publishedFallback = true
            } else if let bounds = loaded.packContent?.bounds {
                self.packPreviewImages[key] = OfflineMapFallbackPreviewRenderer.image(
                    for: bounds
                )
                publishedFallback = true
            }

            guard let bounds = loaded.packContent?.bounds else {
                guard self.previewLoadRegistry.finishIfCurrent(token, for: key) else {
                    return
                }
                self.previewLoadTasks.removeValue(forKey: key)
                if !publishedFallback {
                    self.unavailablePackPreviews.insert(key)
                }
                return
            }

            let generatedSnapshotData: Data?
            do {
                generatedSnapshotData = try await self.mapSnapshot(bounds)
            } catch is CancellationError {
                if self.previewLoadRegistry.finishIfCurrent(token, for: key) {
                    self.previewLoadTasks.removeValue(forKey: key)
                }
                return
            } catch {
                generatedSnapshotData = nil
            }

            guard self.previewLoadRegistry.finishIfCurrent(
                token,
                for: key
            ) else { return }
            self.previewLoadTasks.removeValue(forKey: key)
            guard !Task.isCancelled,
                  self.cachedPackURLs.contains(where: {
                      self.previewCacheKey(for: $0) == key
                  }) else {
                return
            }
            if let image = self.usableSnapshotImage(from: generatedSnapshotData),
               let generatedSnapshotData {
                try? SavedMapSnapshotPreviewStore.save(
                    generatedSnapshotData,
                    for: packURL
                )
                self.packPreviewImages[key] = image
                return
            }
            if !publishedFallback {
                self.unavailablePackPreviews.insert(key)
            }
        }
    }

    private func usablePreviewImage(from data: Data?) -> UIImage? {
        guard let data,
              let image = UIImage(data: data),
              image.size.width > 0,
              image.size.height > 0,
              image.size.width <= 512,
              image.size.height <= 512 else {
            return nil
        }
        return image
    }

    private func usableSnapshotImage(from data: Data?) -> UIImage? {
        guard let image = usablePreviewImage(from: data),
              OfflineMapSnapshotPreviewRenderer.hasMeaningfulVisualVariation(image) else {
            return nil
        }
        return image
    }

    private func usableDetailPreviewImage(from data: Data?) -> UIImage? {
        guard let data,
              SavedMapDetailPreviewStore.isValidPNG(data),
              let image = UIImage(data: data),
              OfflineMapSnapshotPreviewRenderer.hasMeaningfulVisualVariation(image) else {
            return nil
        }
        return image
    }

    private func cacheDetailPreviewImage(_ image: UIImage, forKey key: String) {
        detailPreviewImages[key] = image
        recordDetailPreviewAccess(forKey: key)
        while detailPreviewAccessOrder.count > Self.maximumInMemoryDetailPreviewCount {
            let evictedKey = detailPreviewAccessOrder.removeFirst()
            detailPreviewImages.removeValue(forKey: evictedKey)
        }
    }

    private func recordDetailPreviewAccess(forKey key: String) {
        detailPreviewAccessOrder.removeAll { $0 == key }
        detailPreviewAccessOrder.append(key)
    }

    private func removeDetailPreviewImage(forKey key: String) {
        detailPreviewImages.removeValue(forKey: key)
        detailPreviewAccessOrder.removeAll { $0 == key }
    }

    private func detailPreviewCacheKey(for item: SavedMapListItem) -> String? {
        if let packURL = item.packURL {
            return previewCacheKey(for: packURL)
        }
        guard let descriptor = item.deviceMap else { return nil }
        return devicePreviewCacheKey(for: descriptor)
    }

    private func isDetailPreviewTargetCurrent(
        _ item: SavedMapListItem,
        key: String
    ) -> Bool {
        if item.packURL != nil {
            return cachedPackURLs.contains { previewCacheKey(for: $0) == key }
        }
        return item.deviceMap == currentActiveDeviceMap
    }

    private func loadDevicePreviewIfNeeded(
        for descriptor: DeviceActiveMapDescriptor
    ) {
        if currentActiveDeviceMap != descriptor {
            updateActiveDeviceMap(descriptor)
        }
        let key = devicePreviewCacheKey(for: descriptor)
        guard packPreviewImages[key] == nil,
              !unavailablePackPreviews.contains(key),
              previewLoadTasks[key] == nil else {
            return
        }
        if let bounds = descriptor.bounds {
            packPreviewImages[key] = OfflineMapFallbackPreviewRenderer.image(
                for: bounds
            )
        }
        guard let cacheRoot = try? cachedPackDirectory() else {
            unavailablePackPreviews.insert(key)
            return
        }
        let token = previewLoadRegistry.begin(for: key)
        previewLoadTasks[key] = Task { [weak self] in
            let storedData = await Task.detached(priority: .utility) {
                DeviceMapSnapshotPreviewStore.imageData(
                    for: descriptor,
                    in: cacheRoot
                )
            }.value
            guard let self,
                  self.previewLoadRegistry.isCurrent(token, for: key),
                  !Task.isCancelled,
                  self.currentActiveDeviceMap == descriptor else {
                return
            }
            if let storedImage = self.usableSnapshotImage(from: storedData) {
                _ = self.previewLoadRegistry.finishIfCurrent(token, for: key)
                self.previewLoadTasks.removeValue(forKey: key)
                self.packPreviewImages[key] = storedImage
                return
            }
            guard let bounds = descriptor.bounds else {
                _ = self.previewLoadRegistry.finishIfCurrent(token, for: key)
                self.previewLoadTasks.removeValue(forKey: key)
                self.unavailablePackPreviews.insert(key)
                return
            }

            let generatedData: Data?
            do {
                generatedData = try await self.mapSnapshot(bounds)
            } catch is CancellationError {
                if self.previewLoadRegistry.finishIfCurrent(token, for: key) {
                    self.previewLoadTasks.removeValue(forKey: key)
                }
                return
            } catch {
                generatedData = nil
            }
            guard self.previewLoadRegistry.finishIfCurrent(token, for: key) else {
                return
            }
            self.previewLoadTasks.removeValue(forKey: key)
            guard !Task.isCancelled,
                  self.currentActiveDeviceMap == descriptor else {
                return
            }
            if let generatedData,
               let image = self.usableSnapshotImage(from: generatedData) {
                try? DeviceMapSnapshotPreviewStore.save(
                    generatedData,
                    for: descriptor,
                    in: cacheRoot
                )
                self.packPreviewImages[key] = image
            }
        }
    }
#endif

    @discardableResult
    func renameCachedPack(at packURL: URL, to proposedName: String) -> String {
        let displayName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            return self.displayName(forCachedPack: packURL)
        }
        packDisplayNames[packURL.lastPathComponent] = displayName
        var catalogTarget: (String, Int)?
        if var metadata = SavedMapArtifactMetadataStore.load(for: packURL) {
            metadata.displayName = displayName
            metadata.userDefinedDisplayName = true
            if let mapEntryID = metadata.catalogMapEntryID,
               let revision = metadata.catalogAliasRevision {
                catalogTarget = (mapEntryID, revision)
                metadata.catalogSyncState = "pending"
            }
            try? SavedMapArtifactMetadataStore.save(metadata, for: packURL)
        }
        persistPackDisplayNames()
        syncSavedMapInventory(packURL)
        refreshCachedPacks()
        if let catalogTarget {
            updateCatalogAlias(
                mapEntryID: catalogTarget.0,
                alias: displayName,
                expectedRevision: catalogTarget.1,
                packURL: packURL
            )
        }
        return displayName
    }

    @discardableResult
    func renameCatalogMap(
        _ map: OfflineMapCatalogMap,
        to proposedName: String
    ) -> String {
        guard let alias = OfflineMapCatalogAliasPolicy.normalizedAlias(
            proposedName
        ) else {
            return map.alias
        }
        if pendingCatalogAliases[map.mapEntryId] == nil,
           alias == map.alias {
            return alias
        }
        let pendingToken = setPendingCatalogAlias(
            OfflineMapCatalogPendingAlias(
                mapEntryID: map.mapEntryId,
                alias: alias,
                expectedRevision: map.aliasRevision,
                state: .pending
            )
        )
        if let index = catalogMaps.firstIndex(where: {
            $0.mapEntryId == map.mapEntryId
        }) {
            catalogMaps[index].alias = alias
        }
        updateCatalogAlias(
            mapEntryID: map.mapEntryId,
            alias: alias,
            expectedRevision: map.aliasRevision,
            packURL: nil,
            pendingToken: pendingToken
        )
        return alias
    }

    private func updateCatalogAlias(
        mapEntryID: String,
        alias: String,
        expectedRevision: Int,
        packURL: URL?,
        pendingToken: UUID? = nil
    ) {
        Task { [weak self] in
            guard let self,
                  let client = self.catalogClient else { return }
            do {
                guard let credential = try await self.ensureCatalogCredential() else { return }
                let updated = try await client.updateAlias(
                    mapEntryId: mapEntryID,
                    alias: alias,
                    expectedRevision: expectedRevision,
                    credential: credential.credential
                )
                var visibleMap = updated
                let requestOwnsPendingAlias =
                    OfflineMapCatalogPendingAliasPolicy.belongsToRequestSnapshot(
                        currentToken: self.pendingCatalogAliasTokens[mapEntryID],
                        requestStartToken: pendingToken
                    )
                if packURL == nil,
                   !requestOwnsPendingAlias,
                   let newerPending = self.pendingCatalogAliases[mapEntryID] {
                    visibleMap.alias = newerPending.alias
                }
                if let index = self.catalogMaps.firstIndex(where: {
                    $0.mapEntryId == mapEntryID
                }) {
                    self.catalogMaps[index] = visibleMap
                } else {
                    self.catalogMaps.append(visibleMap)
                }
                if packURL == nil, requestOwnsPendingAlias {
                    self.removePendingCatalogAlias(mapEntryID: mapEntryID)
                }
                if let packURL,
                   var metadata = SavedMapArtifactMetadataStore.load(for: packURL) {
                    metadata.catalogAliasRevision = updated.aliasRevision
                    metadata.catalogSyncState = "synced"
                    try? SavedMapArtifactMetadataStore.save(metadata, for: packURL)
                }
                self.refreshCachedPacks()
            } catch {
                if packURL == nil,
                   case OfflineMapCatalogError.serverStatus(409, _) = error,
                   OfflineMapCatalogPendingAliasPolicy.belongsToRequestSnapshot(
                    currentToken: self.pendingCatalogAliasTokens[mapEntryID],
                    requestStartToken: pendingToken
                   ),
                   var pending = self.pendingCatalogAliases[mapEntryID],
                   pending.alias == alias,
                   pending.expectedRevision == expectedRevision {
                    pending.state = .conflict
                    self.setPendingCatalogAlias(pending)
                    self.syncCatalogLibraryIfNeeded()
                }
                // A catalog-only alias remains durable and visible. Transient
                // failures retry on the next library refresh; conflicts wait
                // for an explicit rename against the refreshed revision.
            }
        }
    }

    func catalogAliasStatus(for mapEntryID: String) -> String? {
        guard let pending = pendingCatalogAliases[mapEntryID] else { return nil }
        switch pending.state {
        case .pending:
            return "Name change pending; retries automatically"
        case .conflict:
            return "Name changed in another app; rename again to apply this name"
        }
    }

    @discardableResult
    private func setPendingCatalogAlias(
        _ pending: OfflineMapCatalogPendingAlias
    ) -> UUID {
        let token = UUID()
        pendingCatalogAliases[pending.mapEntryID] = pending
        pendingCatalogAliasTokens[pending.mapEntryID] = token
        catalogPendingAliasStore.save(pendingCatalogAliases)
        return token
    }

    private func removePendingCatalogAlias(mapEntryID: String) {
        pendingCatalogAliases.removeValue(forKey: mapEntryID)
        pendingCatalogAliasTokens.removeValue(forKey: mapEntryID)
        catalogPendingAliasStore.save(pendingCatalogAliases)
    }

    func catalogAvailability(
        for map: OfflineMapCatalogMap
    ) -> OfflineMapCatalogAvailability {
        OfflineMapCatalogAvailabilityPolicy.availability(
            for: map,
            channel: OfflineMapCatalogConfig.channel(
                generationServerURLString: serverURLString
            ),
            trustStore: mapStreamTrustStore
        )
    }

    func catalogArtifactNeedsRefresh(for item: SavedMapListItem) -> Bool {
        guard let record = item.localRecord,
              let map = item.catalogMap else {
            return false
        }
        let metadata = SavedMapArtifactMetadataStore.load(for: record.packURL)
        let localArtifactSHA256s: Set<String> = Set([
            metadata?.primaryArtifact?.sha256,
            metadata?.legacyArtifact?.sha256,
        ].compactMap { (value: String?) -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        })
        return OfflineMapCatalogAvailabilityPolicy.localArtifactNeedsRefresh(
            localArtifactSHA256s: localArtifactSHA256s,
            localPrimaryArtifact: metadata?.primaryArtifact,
            map: map,
            channel: OfflineMapCatalogConfig.channel(
                generationServerURLString: serverURLString
            ),
            trustStore: mapStreamTrustStore
        )
    }

    func catalogAvailability(
        for preview: OfflineMapSharePreview
    ) -> OfflineMapCatalogAvailability {
        OfflineMapCatalogAvailabilityPolicy.availability(
            for: preview,
            channel: OfflineMapCatalogConfig.channel(
                generationServerURLString: serverURLString
            )
        )
    }

    private func upsertCatalogMap(_ map: OfflineMapCatalogMap) {
        if let index = catalogMaps.firstIndex(where: {
            $0.mapEntryId == map.mapEntryId
        }) {
            catalogMaps[index] = map
        } else {
            catalogMaps.append(map)
        }
    }

    func createShare(for item: SavedMapListItem) {
        guard let mapEntryID = item.catalogMap?.mapEntryId ?? item.localRecord.flatMap({ record in
            SavedMapArtifactMetadataStore.load(for: record.packURL)?.catalogMapEntryID
        }) else {
            errorMessage = "This map is still syncing to the shared library."
            syncDownloadedMapInventoryIfNeeded()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.runBusy {
                guard let client = self.catalogClient,
                      let credential = try await self.ensureCatalogCredential() else {
                    throw OfflineMapCatalogError.invalidConfiguration
                }
                let share = try await client.createShare(
                    mapEntryId: mapEntryID,
                    credential: credential.credential
                )
                self.createdShareURL = share.url
                if let shares = try? await client.shares(
                    credential: credential.credential
                ) {
                    self.catalogShares = shares
                }
                self.statusMessage = "share link ready"
            }
        }
    }

    func removeCatalogMapFromLibrary(_ map: OfflineMapCatalogMap) {
        Task { [weak self] in
            guard let self else { return }
            await self.runBusy {
                guard let client = self.catalogClient,
                      let credential = try await self.ensureCatalogCredential() else {
                    throw OfflineMapCatalogError.invalidConfiguration
                }
                try await client.removeMapFromLibrary(
                    mapEntryId: map.mapEntryId,
                    credential: credential.credential
                )
                self.removePendingCatalogAlias(mapEntryID: map.mapEntryId)
                self.catalogMaps.removeAll { $0.mapEntryId == map.mapEntryId }
                self.refreshCachedPacks()
                self.catalogMaps = try await client.maps(
                    credential: credential.credential
                )
                self.catalogShares = try await client.shares(
                    credential: credential.credential
                )
                self.refreshCachedPacks()
                self.statusMessage = "removed from map library"
            }
        }
    }

    func refreshCatalogShares() {
        Task { [weak self] in
            guard let self else { return }
            await self.runBusy {
                guard let client = self.catalogClient,
                      let credential = try await self.ensureCatalogCredential() else {
                    throw OfflineMapCatalogError.invalidConfiguration
                }
                self.catalogShares = try await client.shares(
                    credential: credential.credential
                )
            }
        }
    }

    func revokeCatalogShare(_ share: OfflineMapCatalogShare) {
        Task { [weak self] in
            guard let self else { return }
            await self.runBusy {
                guard let client = self.catalogClient,
                      let credential = try await self.ensureCatalogCredential() else {
                    throw OfflineMapCatalogError.invalidConfiguration
                }
                try await client.revokeShare(
                    shareId: share.shareId,
                    credential: credential.credential
                )
                self.catalogShares = try await client.shares(
                    credential: credential.credential
                )
                self.statusMessage = "share link revoked"
            }
        }
    }

    func createLibraryLinkCode() {
        Task { [weak self] in
            guard let self else { return }
            await self.runBusy {
                guard let client = self.catalogClient,
                      let credential = try await self.ensureCatalogCredential() else {
                    throw OfflineMapCatalogError.invalidConfiguration
                }
                self.libraryLinkCode = try await client.createLinkCode(
                    credential: credential.credential
                )
                self.statusMessage = "one-time link code ready"
            }
        }
    }

    func clearLibraryLinkCode() {
        libraryLinkCode = nil
    }

    func claimLibraryLinkCode(_ code: String) {
        Task { [weak self] in
            guard let self else { return }
            await self.runBusy {
                guard let client = self.catalogClient,
                      let current = try await self.ensureCatalogCredential() else {
                    throw OfflineMapCatalogError.invalidConfiguration
                }
                let linked = try await client.claimLinkCode(
                    code,
                    credential: current.credential
                )
                try self.catalogCredentialStore.save(linked)
                self.libraryLinkCode = nil
                self.catalogMaps = try await client.maps(
                    credential: linked.credential
                )
                self.catalogShares = try await client.shares(
                    credential: linked.credential
                )
                self.refreshCachedPacks()
                self.statusMessage = "map libraries linked"
            }
        }
    }

    func clearCreatedShareURL() {
        createdShareURL = nil
    }

    func handleShareURL(_ url: URL) {
        guard let token = OfflineMapShareLink.token(
            from: url,
            catalogHost: catalogHost
        ) else {
            errorMessage = "That is not a valid Bicino map share link."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.runBusy {
                guard let client = self.catalogClient else {
                    throw OfflineMapCatalogError.invalidConfiguration
                }
                let preview = try await client.previewShare(token: token)
                self.pendingShareToken = token
                self.pendingSharePreview = preview
                self.statusMessage = "shared map preview ready"
            }
        }
    }

    func dismissPendingShare() {
        pendingShareToken = nil
        pendingSharePreview = nil
    }

    func claimPendingShare() {
        guard let token = pendingShareToken,
              let preview = pendingSharePreview else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.runBusy {
                guard let client = self.catalogClient,
                      let credential = try await self.ensureCatalogCredential() else {
                    throw OfflineMapCatalogError.invalidConfiguration
                }
                let map = try await client.claimShare(
                    token: token,
                    credential: credential.credential
                )
                self.upsertCatalogMap(map)
                self.refreshCachedPacks()
                self.pendingShareToken = nil
                self.pendingSharePreview = nil
                let availability = self.catalogAvailability(for: map)
                guard availability.canDownload else {
                    self.statusMessage = availability.postClaimStatusMessage
                    return
                }
                try await self.downloadCatalogMap(
                    map,
                    sourceShareID: preview.shareId,
                    client: client,
                    credential: credential
                )
            }
        }
    }

    func downloadCatalogMap(_ map: OfflineMapCatalogMap) {
        let availability = catalogAvailability(for: map)
        guard availability.canDownload else {
            statusMessage = availability.statusText ?? "shared map is unavailable"
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.runBusy {
                guard let client = self.catalogClient,
                      let credential = try await self.ensureCatalogCredential() else {
                    throw OfflineMapCatalogError.invalidConfiguration
                }
                try await self.downloadCatalogMap(
                    map,
                    sourceShareID: nil,
                    client: client,
                    credential: credential
                )
            }
        }
    }

    private func downloadCatalogMap(
        _ map: OfflineMapCatalogMap,
        sourceShareID: String?,
        client: OfflineMapCatalogClient,
        credential: OfflineMapCatalogCredential
    ) async throws {
        guard catalogAvailability(for: map).canDownload else {
            throw OfflineMapCatalogError.missingCompatibleArtifact
        }
        let grant = try await client.downloadGrant(
            mapEntryId: map.mapEntryId,
            channel: OfflineMapCatalogConfig.channel(
                generationServerURLString: serverURLString
            ),
            trustStore: mapStreamTrustStore,
            appIdentity: catalogAppIdentity,
            credential: credential.credential
        )
        let artifact = grant.artifact.platformArtifact
        guard artifact.isBikeMapStream,
              OfflineMapReaderCompatibilityPolicy.isCompatible(
                artifact: grant.artifact,
                map: map
              ) else {
            throw OfflineMapCatalogError.missingCompatibleArtifact
        }
        let expectedCompanion = OfflineMapTopographyCompanionPolicy
            .compatibleCompanion(
                for: map,
                deliveryTier: grant.artifact.deliveryTier
            )
        if map.rendererFormatVersion == 4 {
            guard let expectedCompanion,
                  let grantedCompanion = grant.companion,
                  grantedCompanion.artifact.artifactId ==
                    expectedCompanion.artifactId,
                  grantedCompanion.artifact.companionRequirements ==
                    expectedCompanion.companionRequirements else {
                throw OfflineMapCatalogError.missingCompatibleArtifact
            }
        } else if grant.companion != nil {
            throw OfflineMapCatalogError.invalidResponse
        }
        downloadURL = grant.downloadURL
        statusMessage = "downloading shared map"
        downloadProgress = 0
        downloadByteProgress = nil
        guard let catalogHost = OfflineMapCatalogConfig.catalogHost,
              let r2DownloadHost = OfflineMapCatalogConfig.r2DownloadHost else {
            throw OfflineMapCatalogError.invalidConfiguration
        }
        let constraints = try OfflineMapDownloadConstraints.catalogArtifact(
            artifact,
            catalogHost: catalogHost,
            r2DownloadHost: r2DownloadHost
        )
        let temporaryURL = try await packDownload(
            grant.downloadURL,
            constraints,
            { [weak self] progress in self?.downloadProgress = progress },
            { [weak self] byteProgress in self?.downloadByteProgress = byteProgress }
        )
        let verifiedReaderRequirements: OfflineMapReaderRequirements
        var verifiedTopography: VerifiedBikeMapTopography?
        var topographyDownload: (
            temporaryURL: URL,
            association: SavedTopographyCompanionAssociation
        )?
        do {
            let trustStore = mapStreamTrustStore
            let mapID = map.mapId
            let verified = try await Task.detached(priority: .userInitiated) {
                try BikeMapStreamArtifactValidator.validate(
                    url: temporaryURL,
                    artifact: artifact,
                    expectedMapID: mapID,
                    trustStore: trustStore,
                    readerRequirements: grant.artifact.readerRequirements
                )
            }.value
            guard let requirements = verified.readerRequirements else {
                throw OfflineMapCatalogError.missingCompatibleArtifact
            }
            verifiedReaderRequirements = requirements
            verifiedTopography = verified.topography
            if let companionGrant = grant.companion {
                try validateTopographyCompanionBinding(
                    companionGrant.artifact.platformArtifact,
                    signedTopography: verified.topography
                )
                topographyDownload = try await
                    downloadAndValidateTopographyCompanion(
                        from: companionGrant.downloadURL,
                        artifact: companionGrant.artifact.platformArtifact,
                        associationID: map.mapEntryId,
                        mapID: map.mapId,
                        streamArtifactSHA256: artifact.sha256,
                        allowedDownloadHosts: [
                            catalogHost.lowercased(),
                            r2DownloadHost.lowercased(),
                        ]
                    )
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            downloadURL = nil
            throw error
        }
        let destination = try cachedCatalogPackURL(
            mapEntryID: map.mapEntryId,
            fileExtension: "bmap"
        )
        let obsoleteDestination = try cachedCatalogPackURL(
            mapEntryID: map.mapEntryId,
            fileExtension: "zip"
        )
        let metadata = SavedMapArtifactMetadata(
            schemaVersion: SavedMapArtifactMetadata.currentSchemaVersion,
            mapID: map.mapId,
            displayName: map.alias,
            localArtifactFilename: destination.lastPathComponent,
            streamFormatVersion: 1,
            rendererFormatVersion: map.rendererFormatVersion,
            jobID: nil,
            serverURLString: nil,
            clientInstallationID: nil,
            primaryArtifact: artifact,
            legacyArtifact: nil,
            lastTransferProtocol: nil,
            lastTransferStreamFormat: nil,
            lastTransferSessionID: nil,
            lastBackgroundTaskID: nil,
            lastDeviceSequence: nil,
            lastDeviceState: nil,
            lastDeviceStep: nil,
            lastDeviceStepCount: nil,
            lastDeviceProgress: nil,
            expectedActiveMapID: map.mapId,
            expectedActiveSessionID: nil,
            lastTransferOutcome: nil,
            userDefinedDisplayName: map.aliasSource == "user",
            downloadReceiptID: nil,
            catalogMapEntryID: map.mapEntryId,
            catalogLibraryID: credential.libraryId,
            originChannel: map.originChannel,
            catalogAliasRevision: map.aliasRevision,
            sourceShareID: sourceShareID,
            catalogSyncState: "synced",
            readerRequirements: verifiedReaderRequirements,
            catalogContentReceipt: map.contentReceipt,
            topography: verifiedTopography
        )
        do {
            if let topographyDownload {
                let companionDestination = try cachedTopographyCompanionURL(
                    associationID: map.mapEntryId
                )
                try replaceTopographyCompanion(
                    at: topographyDownload.temporaryURL,
                    destination: companionDestination,
                    association: topographyDownload.association
                )
                defaults.set(
                    map.mapEntryId,
                    forKey: OfflineMapDefaults.activeTopographyAssociationKey
                )
            }
            try replaceDownloadedArtifact(
                at: temporaryURL,
                destination: destination,
                metadata: metadata,
                mapID: map.mapId,
                fileExtension: "bmap",
                obsoleteDestination: obsoleteDestination
            )
        } catch {
            if let topographyDownload {
                try? FileManager.default.removeItem(
                    at: topographyDownload.temporaryURL
                )
            }
            throw error
        }
        upsertCatalogMap(map)
        packDisplayNames[destination.lastPathComponent] = map.alias
        persistPackDisplayNames()
        downloadedPackURL = destination
        refreshCachedPacks()
#if canImport(UIKit)
        loadPreviewIfNeeded(forCachedPack: destination)
#endif
        downloadProgress = 1
        downloadByteProgress = nil
        statusMessage = "shared map downloaded"
    }

    func isCachedPackInstalled(_ packURL: URL,
                               activeMapId: String,
                               activeSessionId: String) -> Bool {
        guard !activeMapId.isEmpty,
              activeMapId == savedMapID(for: packURL),
              !isUnconfirmedTransferIdentity(mapID: activeMapId, sessionID: activeSessionId) else {
            return false
        }
        // A stable map ID identifies an area, not a particular generated pack.
        // Older firmware does not expose the content-derived session, so it
        // cannot prove that a regenerated same-area pack is already installed.
        guard !activeSessionId.isEmpty else { return false }
        return acceptedActiveSessionIDs(
            for: packURL,
            mapID: activeMapId
        ).contains(activeSessionId)
    }

    private func isUnconfirmedTransferIdentity(mapID: String, sessionID: String?) -> Bool {
        !lastTransferOutcome.isEmpty && lastTransferOutcome != "installed" &&
            lastTransferMapId == mapID &&
            defaults.string(forKey: OfflineMapDefaults.lastTransferSessionIdKey) == sessionID
    }

    var lastTransferDescription: String? {
        guard !lastTransferMapId.isEmpty else { return nil }
        let outcome = lastTransferOutcome.isEmpty ? "unknown" : lastTransferOutcome
        return "\(displayName(forMapId: lastTransferMapId)) — \(outcome)"
    }

    func displayName(forMapId mapId: String) -> String {
        if let packURL = lastTransferArtifactURL(mapID: mapId) {
            return displayName(forCachedPack: packURL)
        }
        for filename in ["\(mapId).bmap", "\(mapId).zip"] {
            if let displayName = packDisplayNames[filename], !displayName.isEmpty {
                return displayName
            }
            if let directory = try? cachedPackDirectory(),
               let displayName = SavedMapArtifactMetadataStore.load(
                   for: directory.appendingPathComponent(filename)
               )?.displayName,
               !displayName.isEmpty {
                return displayName
            }
        }
        return mapId
    }

    private var currentDeviceMapOperation: DeviceMapOperationRecord? {
        guard let rawID = defaults.string(forKey: "offlineMap.deviceOperationID"),
              let id = UUID(uuidString: rawID) else { return nil }
        return try? self.deviceMapOperationStore.records().first { $0.operationID == id }
    }

    private func recordDeviceOperationReceipt(_ receipt: DeviceMapOperationReceipt,
                                               bleManager: BLEManager) throws -> DeviceMapOperationRecord? {
        guard let current = currentDeviceMapOperation,
              bleManager.isConnected, bleManager.isNavigationReady,
              current.deviceID == bleManager.activeDeviceID,
              current.appNamespace == BackgroundMapUploadSessionNamespace.identifier(bundleIdentifier: Bundle.main.bundleIdentifier),
              current.wireOperationID == receipt.operationID else { return nil }
        return try self.deviceMapOperationStore.ingest(receipt)
    }

    var canCancelCurrentMapOperation: Bool {
        guard let record = currentDeviceMapOperation, record.usesDurableProtocol,
              !record.isTerminal, !record.isRetiredUnknown, record.lastReceipt?.phase != "accepted" else { return false }
        return record.cancellationRequestedAt == nil
    }

    var isCurrentMapOperationAccepted: Bool {
        currentDeviceMapOperation?.lastReceipt?.phase == "accepted"
    }

    func cancelCurrentMapOperation(bleManager: BLEManager) async {
        guard let current = currentDeviceMapOperation,
              current.deviceID == bleManager.activeDeviceID else { return }
        do {
            let record = try self.deviceMapOperationStore.requestCancellation(operationID: current.operationID)
            guard !record.isTerminal else { return }
            if record.lastReceipt?.phase == "accepted" {
                statusMessage = "Device already accepted this map. Waiting for installation to finish."
                startActivationReconciliationMonitor(bleManager: bleManager)
                return
            }
            statusMessage = "Cancelling map upload; checking the device result"
            updateLastTransferOutcome("unconfirmed")
#if os(iOS)
            // Cancel only the exact OS upload. The durable cancellation intent
            // already prevents the active foreground task from issuing commit.
            _ = await BackgroundMapUploadCoordinator.shared.retireActiveUpload(
                mapID: record.mapID, sessionID: record.sessionID,
                deviceID: record.deviceID, operationID: record.operationID
            )
#endif
            if !isDeviceTransferBusy {
                startDeviceTransfer { manager in
                    try await manager.resumeDurableMapControl(bleManager: bleManager)
                }
            }
            startActivationReconciliationMonitor(bleManager: bleManager)
        } catch {
            errorMessage = "Could not save the cancellation request. The map result remains unresolved."
        }
    }

    private func acknowledgeDurableResult(_ record: DeviceMapOperationRecord,
                                          client: MapTransferDeviceClient) async {
        guard record.isTerminal, record.acknowledgedAt == nil else { return }
        do {
            try await client.acknowledgeOperation(operationID: record.wireOperationID)
            try self.deviceMapOperationStore.markAcknowledged(operationID: record.operationID)
        } catch { /* Keep receipt and retry ACK on a later authenticated session. */ }
    }

    private func advanceDurableMapControl(_ observed: DeviceMapOperationRecord,
                                         client: MapTransferDeviceClient,
                                         bleManager: BLEManager,
                                         connectionEpoch: UInt64) async throws -> DeviceMapOperationRecord? {
        guard let current = currentDeviceMapOperation, current.operationID == observed.operationID,
              current.deviceID == bleManager.activeDeviceID,
              connectionEpoch == bleManager.transferConnectionEpoch else { return nil }
        guard let httpContext = bleManager.captureMapTransferHTTPStatusContext() else { return nil }
        let action = current.nextControlAction
        guard action == .commit || action == .cancel else { return current }
        try Task.checkCancellation()
        let requested: DeviceMapOperationRecord
        if action == .commit {
            requested = try self.deviceMapOperationStore.requestCommit(operationID: current.operationID)
        } else {
            requested = try self.deviceMapOperationStore.requestCancellation(operationID: current.operationID)
            guard requested.nextControlAction == .cancel else { return requested }
        }
        do {
            let receipt: DeviceMapOperationReceipt
            if action == .commit {
                receipt = try await client.commitOperation(operationID: requested.wireOperationID,
                                                           streamSHA256: requested.streamSHA256)
            } else {
                receipt = try await client.cancelOperation(record: requested)
            }
            guard requested.deviceID == bleManager.activeDeviceID,
                  connectionEpoch == bleManager.transferConnectionEpoch,
                  bleManager.isCurrentMapTransferHTTPStatusContext(httpContext) else { return nil }
            guard let updated = try recordDeviceOperationReceipt(receipt, bleManager: bleManager) else {
                throw OfflineMapPlatformError.invalidResponse
            }
            if requested.cancellationRequestedAt != nil, updated.lastReceipt?.phase == "accepted" {
                statusMessage = "Device already accepted this map. Waiting for installation to finish."
            }
            if updated.lastReceipt?.phase == "accepted", requested.cancellationRequestedAt == nil {
                statusMessage = "Device accepted the map. Waiting for renderer confirmation."
            }
            return updated
        } catch {
            // Losing a POST response does not cancel accepted work. Preserve the
            // intent and re-query this same ID before another control request.
            try self.deviceMapOperationStore.markControlResponseUnknown(operationID: requested.operationID)
            return nil
        }
    }

    private func hasVerifiedPrecommitRecovery(_ record: DeviceMapOperationRecord,
                                             bleManager: BLEManager) -> Bool {
        guard bleManager.isConnected, bleManager.isNavigationReady,
              record.deviceID == bleManager.activeDeviceID,
              bleManager.mapOperationConnectionEpoch == bleManager.transferConnectionEpoch,
              let receipt = bleManager.mapOperationStatus else { return false }
        return record.permitsPrecommitSessionRecovery(after: receipt)
    }

    private func resumeDurableMapControl(bleManager: BLEManager) async throws {
        guard let record = currentDeviceMapOperation, record.usesDurableProtocol,
              record.deviceID == bleManager.activeDeviceID else { return }
        let recoveryEpoch = bleManager.transferConnectionEpoch
        let session = try await deviceTransferManager.resumeMapTransfer(
            bleManager: bleManager,
            verifiedPrecommitRecovery: hasVerifiedPrecommitRecovery(record, bleManager: bleManager),
            recoveryDeviceID: record.deviceID, recoveryConnectionEpoch: recoveryEpoch
        ) {
            self.statusMessage = $0
        }
        try await withBackgroundTransferLifecycle(bleManager: bleManager) {
            guard let pinnedSession = DeviceTransferPinnedSessionFactory.make(
                configuration: .ephemeral, baseURL: session.baseURL,
                certificateSHA256: session.tlsCertificateSHA256
            ) else { throw DeviceTransferSecurityError.secureTransferRequired }
            defer { pinnedSession.invalidateAndCancel() }
            let client = MapTransferDeviceClient(baseURL: session.baseURL,
                                                 sessionToken: session.sessionToken, session: pinnedSession)
            try await finishActivationConfirmation(expectedMapID: record.mapID, sessionID: record.sessionID,
                previousMapID: nil, previousSessionID: nil, previousSequence: nil, acceptedSequence: nil,
                client: client, bleManager: bleManager)
        }
    }

    private func hasBoundLegacyTransferObservation(mapID: String, sessionID: String,
                                                    bleManager: BLEManager) -> Bool {
        lastTransferMapId == mapID &&
            defaults.string(forKey: OfflineMapDefaults.lastTransferSessionIdKey) == sessionID &&
            lastTransferConnectionEpoch == bleManager.transferConnectionEpoch
    }

    // A legacy result is only bound in the BLE connection and app process that
    // observed its transfer; a device reboot always replaces the connection.
    // Elsewhere, wait only for a live activation of this session. Otherwise
    // nothing can still confirm it: stop polling and let a re-send of the same
    // signed stream produce a fresh terminal result. Never infer from a pointer.
    private func resolveUnboundLegacyResult(sessionID: String, bleManager: BLEManager) {
        guard bleManager.hasFreshMapTransferStatus else {
            statusMessage = "Waiting for device map status"
            startActivationReconciliationMonitor(bleManager: bleManager)
            return
        }
        if bleManager.mapTransferActivationSessionId == sessionID,
           ["receiving", "paused", "finalizing", "ready", "activating"]
            .contains(bleManager.mapTransferActivationStatus) {
            statusMessage = bleManager.mapTransferActivationStatus == "paused"
                ? "Map upload paused. Tap Upload to resume."
                : "Activation continues on device"
            errorMessage = nil
            startActivationReconciliationMonitor(bleManager: bleManager)
            return
        }
        updateLastTransferOutcome("unknown")
        statusMessage = "The device result for this map was not observed. Send it again to verify the installation."
        errorMessage = nil
    }

    private func reconcileDurableMapOperation(bleManager: BLEManager) -> Bool {
        guard let record = currentDeviceMapOperation else {
            guard defaults.string(forKey: "offlineMap.deviceOperationID") != nil else { return false }
            statusMessage = "Saved map operation needs recovery before its result can be confirmed"
            return true
        }
        guard record.mapID == lastTransferMapId else { return false }
        guard record.deviceID == bleManager.activeDeviceID else {
            statusMessage = "Reconnect the device that started this map transfer"
            return true
        }
        guard record.usesDurableProtocol else {
            // A legacy sequence retained across a connection/reboot is not an
            // exact-operation receipt. Do not bind old records to a new epoch.
            if record.connectionEpoch != bleManager.transferConnectionEpoch ||
                record.observationProcessID != DeviceMapOperationStore.observationProcessID {
                resolveUnboundLegacyResult(sessionID: record.sessionID, bleManager: bleManager)
                return true
            }
            return false
        }
        if record.isRetiredUnknown {
            updateLastTransferOutcome("unknown")
            statusMessage = "The previous map result is unknown. Send the map again to verify installation."
            errorMessage = nil
            return true
        }
        if record.observation == "installed_confirmed", record.lastReceipt?.phase == "installed" {
            updateLastTransferOutcome("installed")
            statusMessage = "map installed: \(displayName(forMapId: record.mapID))"
            errorMessage = nil
            Task { await self.cleanupTerminalMapOperationIfNeeded(bleManager: bleManager) }
            return true
        }
        if record.isTerminal {
            updateLastTransferOutcome(record.observation == "cancelled_before_commit" ? "cancelled" : "failed")
            if record.observation == "cancelled_before_commit" {
                statusMessage = "Map upload cancelled before installation"
                errorMessage = nil
            } else {
                errorMessage = "Device reported \(record.lastReceipt?.phase ?? "failed") for this map operation"
            }
            Task { await self.cleanupTerminalMapOperationIfNeeded(bleManager: bleManager) }
            return true
        }
        if let receipt = bleManager.mapOperationStatus,
           bleManager.mapOperationConnectionEpoch == bleManager.transferConnectionEpoch,
           let updated = try? recordDeviceOperationReceipt(receipt, bleManager: bleManager) {
            switch updated.observation {
            case "installed_confirmed":
                updateLastTransferOutcome("installed")
                statusMessage = "map installed: \(displayName(forMapId: updated.mapID))"
                errorMessage = nil
                Task { await self.cleanupTerminalMapOperationIfNeeded(bleManager: bleManager) }
                return true
            case "failed_or_rolled_back", "cancelled_before_commit":
                updateLastTransferOutcome(updated.observation == "cancelled_before_commit" ? "cancelled" : "failed")
                statusMessage = updated.observation == "cancelled_before_commit" ? "Map upload cancelled before installation" : ""
                errorMessage = updated.observation == "cancelled_before_commit" ? nil :
                    "Device reported \(receipt.phase ?? "failed") for this map operation"
                Task { await self.cleanupTerminalMapOperationIfNeeded(bleManager: bleManager) }
                return true
            default:
                if (updated.nextControlAction == .commit || updated.nextControlAction == .cancel),
                   !isDeviceTransferBusy, !hasActiveBackgroundUpload {
                    startDeviceTransfer { manager in
                        try await manager.resumeDurableMapControl(bleManager: bleManager)
                    }
                }
            }
        }
        if record.cancellationRequestedAt != nil, !isDeviceTransferBusy, !hasActiveBackgroundUpload,
           bleManager.mapOperationConnectionEpoch == bleManager.transferConnectionEpoch,
           bleManager.mapOperationStatus?.operationID == record.wireOperationID {
            startDeviceTransfer { manager in
                try await manager.resumeDurableMapControl(bleManager: bleManager)
            }
        }
        // The foreground recovery owns polling while it runs. A new query
        // clears the fresh BLE receipt before its scheduled task can verify
        // precommit recovery, and would also overwrite its connection status.
        guard !isDeviceTransferBusy else { return true }
        _ = bleManager.requestMapOperationStatus(operationID: record.wireOperationID)
        statusMessage = currentDeviceMapOperation?.lastReceipt?.phase == "accepted"
            ? "Device accepted this map. Waiting for installation to finish."
            : "Waiting for the device's saved map result"
        return true
    }

    private func restorePendingDurableTransfer(bleManager: BLEManager) {
        guard let record = currentDeviceMapOperation,
              record.usesDurableProtocol, !record.isTerminal, !record.isRetiredUnknown,
              record.deviceID == bleManager.activeDeviceID,
              record.appNamespace == BackgroundMapUploadSessionNamespace.identifier(
                bundleIdentifier: Bundle.main.bundleIdentifier) else { return }
        if lastTransferOutcome != "unconfirmed" || lastTransferMapId != record.mapID ||
            defaults.string(forKey: OfflineMapDefaults.lastTransferSessionIdKey) != record.sessionID ||
            defaults.string(forKey: OfflineMapDefaults.lastTransferArtifactFilenameKey) != record.artifactFilename {
            // The durable journal owns recovery even when the display summary
            // was left on an older map or settled by the legacy status path.
            recordTransfer(mapId: record.mapID, sessionId: record.sessionID,
                previousMapId: record.previousConfirmedSelection?.mapID,
                previousSessionId: record.previousConfirmedSelection?.sessionID,
                previousSequence: nil, outcome: "unconfirmed",
                connectionEpoch: record.connectionEpoch, protocolVersion: 2,
                streamFormatVersion: 1,
                artifactURL: (try? cachedPackDirectory())?.appendingPathComponent(record.artifactFilename),
                updateOperationRecord: false)
        }
        startActivationReconciliationMonitor(bleManager: bleManager)
    }

    func reconcileLastTransfer(bleManager: BLEManager) {
        restorePendingDurableTransfer(bleManager: bleManager)
        if lastTransferOutcome == "unconfirmed", reconcileDurableMapOperation(bleManager: bleManager) { return }
        guard bleManager.hasFreshMapTransferStatus else {
            lastTransferObservedIdleOnAnotherMap = false
            if lastTransferOutcome == "unconfirmed", !lastTransferMapId.isEmpty {
                activationProgress = nil
                statusMessage = "Waiting for device map status"
                errorMessage = nil
            }
            return
        }
        updateActivationProgress(
            status: bleManager.mapTransferActivationStatus,
            step: bleManager.mapTransferActivationStep,
            stepCount: bleManager.mapTransferActivationStepCount,
            percentage: bleManager.mapTransferActivationProgress
        )
        guard lastTransferOutcome == "unconfirmed",
              !lastTransferMapId.isEmpty,
              let sessionId = defaults.string(
                forKey: OfflineMapDefaults.lastTransferSessionIdKey
              ),
              !sessionId.isEmpty else {
            lastTransferObservedIdleOnAnotherMap = false
            return
        }

        guard hasBoundLegacyTransferObservation(mapID: lastTransferMapId, sessionID: sessionId,
                                               bleManager: bleManager) else {
            resolveUnboundLegacyResult(sessionID: sessionId, bleManager: bleManager)
            return
        }

        let previousMapId = defaults.string(
            forKey: OfflineMapDefaults.lastTransferPreviousMapIdKey
        )
        let previousSessionId = defaults.string(
            forKey: OfflineMapDefaults.lastTransferPreviousSessionIdKey
        )
        let previousSequence = (
            defaults.object(forKey: OfflineMapDefaults.lastTransferPreviousSequenceKey)
                as? NSNumber
        )?.uint32Value
        let acceptedSequence = (
            defaults.object(forKey: OfflineMapDefaults.lastTransferAcceptedSequenceKey)
                as? NSNumber
        )?.uint32Value
        let evaluation = MapActivationReconciler.evaluate(
            expectedMapId: lastTransferMapId,
            sessionId: sessionId,
            previousMapId: previousMapId,
            previousSessionId: previousSessionId,
            previousSequence: previousSequence,
            acceptedSequence: acceptedSequence,
            observedCurrentAttempt: false,
            activeMapId: bleManager.mapTransferActiveMapId,
            activeSessionId: bleManager.mapTransferActiveSessionId,
            activationStatus: bleManager.mapTransferActivationStatus,
            activationSequence: bleManager.mapTransferActivationSequence,
            activationSessionId: bleManager.mapTransferActivationSessionId,
            activationMapId: bleManager.mapTransferActivationMapId,
            activationError: bleManager.mapTransferActivationError ??
                bleManager.mapTransferLastError
        )
        updateSavedMapDeviceState(
            mapID: lastTransferMapId,
            sequence: bleManager.mapTransferActivationSequence,
            state: bleManager.mapTransferActivationStatus,
            step: bleManager.mapTransferActivationStep,
            stepCount: bleManager.mapTransferActivationStepCount,
            progress: bleManager.mapTransferActivationProgress
        )
        switch evaluation.decision {
        case .installed:
            recordLegacyTerminalProof("installed_confirmed", mapID: lastTransferMapId, sessionID: sessionId, bleManager: bleManager)
            lastTransferObservedIdleOnAnotherMap = false
            updateLastTransferOutcome("installed")
            statusMessage = "map installed: \(displayName(forMapId: lastTransferMapId))"
            errorMessage = nil
        case .failed(let message):
            recordLegacyTerminalProof("failed_or_rolled_back", mapID: lastTransferMapId, sessionID: sessionId, bleManager: bleManager)
            lastTransferObservedIdleOnAnotherMap = false
            updateLastTransferOutcome("failed")
            statusMessage = ""
            errorMessage = OfflineMapPlatformError
                .mapActivationFailed(message)
                .localizedDescription
        case .pending:
            let deviceIsIdleOnAnotherMap =
                bleManager.hasFreshMapTransferStatus &&
                bleManager.mapTransferActivationStatus == "idle" &&
                bleManager.mapTransferActiveSessionId != sessionId
            if deviceIsIdleOnAnotherMap &&
                !lastTransferObservedIdleOnAnotherMap {
                diagnosticsRecorder?.record(
                    category: .map,
                    event: "activation_retry_available",
                    fields: ["mapId": lastTransferMapId, "state": "idle"]
                )
            }
            lastTransferObservedIdleOnAnotherMap = deviceIsIdleOnAnotherMap
            switch bleManager.mapTransferActivationStatus {
            case "receiving":
                statusMessage = "Map upload continues on device"
            case "paused":
                statusMessage = "Map upload paused. Tap Upload to resume."
            case "finalizing", "ready", "activating":
                statusMessage = "Activation continues on device"
            default:
                statusMessage = deviceIsIdleOnAnotherMap
                    ? "Activation paused. Tap Upload to resume."
                    : "Waiting for device map status"
            }
            errorMessage = nil
            startActivationReconciliationMonitor(bleManager: bleManager)
        }
    }

    func makeCustomBBoxRequest() throws -> OfflineMapJobRequest {
        guard let latitude = Double(centerLatitude),
              let longitude = Double(centerLongitude),
              let sizeKm = Double(sideLengthKm) else {
            throw OfflineMapPlatformError.invalidResponse
        }
        let bounds = OfflineMapBounds(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            sideLengthKm: sizeKm
        )
        return OfflineMapJobRequest
            .customBBox(bounds)
            .withTopography(includeTopographyInNewMaps)
    }

    private func createJobAndDownload(request: OfflineMapJobRequest) {
        guard canStartNewMapJob() else { return }
        startMapJobTask { manager in
            var client = try manager.makeClient()
            client = try await manager.ensureRegisteredInstallation(client: client)
            if try await manager.recoverOwnedServerJobIfAvailable(
                client: client,
                bleManager: nil
            ) {
                return
            }
            manager.currentJob = nil
            manager.downloadURL = nil
            manager.downloadedPackURL = nil
            manager.downloadProgress = 0
            manager.downloadByteProgress = nil
            manager.transferProgress = 0
            manager.statusMessage = "creating map job"

            let identifiedRequest = request.identified(
                clientInstallationId: client.clientInstallationId,
                clientRequestId: UUID().uuidString.lowercased(),
                installOnDevice: false
            )
            try await manager.requireGenerationCapability(
                for: identifiedRequest,
                client: client
            )
            manager.currentJob = try await manager.createJob(identifiedRequest, client: client)
            manager.persistCurrentJob(installOnDevice: false)
            manager.statusMessage = manager.currentJob?.status ?? ""
            try await manager.waitForReadyMap(client: client)
            try await manager.downloadReadyPack(client: client)
            manager.clearPersistedJob(markHandled: true)
        }
    }

    private func startMapJobTask(
        _ operation: @MainActor @escaping (OfflineMapManager) async throws -> Void
    ) {
        guard mapJobTask == nil else { return }
        let taskID = UUID()
        mapJobTaskID = taskID
        isMapJobProcessing = true
        mapJobTask = Task { [weak self] in
            guard let self else { return }
            await runBusy {
                try await operation(self)
            }
            if mapJobTaskID == taskID {
                mapJobTask = nil
                mapJobTaskID = nil
                isMapJobProcessing = false
            }
        }
    }

    private func recoverPendingMapJob(bleManager: BLEManager?) async throws {
        let persistedJobId = OfflineMapJobPersistence.activeJobId(defaults: defaults)
        let persistedInstallIntent = OfflineMapJobPersistence.shouldInstallOnDevice(
            defaults: defaults
        )
        let persistedServerURL = OfflineMapJobPersistence.serverURLString(
            defaults: defaults
        )
        if let persistedJobId,
           try await finishDownloadedRecoveredJobIfAvailable(
                jobId: persistedJobId,
                installOnDevice: persistedInstallIntent,
                bleManager: bleManager
           ) {
            return
        }
        let recoveryServerURL = recoveryServerURL(
            persistedServerURL: persistedServerURL
        )
        var client = try makeClient(serverURLString: recoveryServerURL)
        client = try await ensureRegisteredInstallationWithRetry(client: client)
        var jobId = persistedJobId
        var shouldInstallOnDevice = persistedInstallIntent

        if jobId == nil {
            statusMessage = "checking for server maps"
            let jobs = try await listJobsWithRetry(client: client)
            if consumeForgottenDiscovery(
                jobs: jobs,
                serverURLString: recoveryServerURL,
                clientInstallationId: client.clientInstallationId
            ) {
                isServerRecoveryCheckPending = false
                statusMessage = ""
                return
            }
            guard let recovered = selectOwnedRecoverableJob(
                from: jobs,
                clientInstallationId: client.clientInstallationId
            ) else {
                isServerRecoveryCheckPending = false
                statusMessage = ""
                return
            }
            adoptRecoveredJob(recovered)
            jobId = recovered.jobId
            shouldInstallOnDevice = recovered.installOnDevice == true
            persistCurrentJob(installOnDevice: shouldInstallOnDevice)
            isServerRecoveryCheckPending = false
        }

        guard let jobId else { return }
        try await finishRecoveredJob(
            jobId: jobId,
            installOnDevice: shouldInstallOnDevice,
            client: client,
            bleManager: bleManager
        )
    }

    private func createJob(
        _ request: OfflineMapJobRequest,
        client: OfflineMapPlatformClient
    ) async throws -> OfflineMapJob {
        var activeClient = client
        var recoveredUnavailableKey = false
        return try await OfflineMapJobCreator.create(
            request: request,
            create: { identifiedRequest in
                do {
                    return try await activeClient.createJob(identifiedRequest)
                } catch ManagedAppAttestError.keyUnavailable
                    where !recoveredUnavailableKey {
                    recoveredUnavailableKey = true
                    activeClient = try await self.ensureRegisteredInstallation(
                        client: activeClient,
                        honorRefreshBackoff: false
                    )
                    return try await activeClient.createJob(identifiedRequest)
                }
            },
            list: {
                try await activeClient.jobs()
            },
            sleep: { nanoseconds in
                try await Task.sleep(nanoseconds: nanoseconds)
            },
            onRetry: { [weak self] in
                self?.statusMessage = "reconnecting to map server"
            }
        )
    }

    private func requireGenerationCapability(
        for request: OfflineMapJobRequest,
        client: OfflineMapPlatformClient
    ) async throws {
        guard let rendererFormatVersion = request.target?.rendererFormatVersion else {
            return
        }
        do {
            let capabilities = try await client.generationCapabilities()
            try capabilities.require(
                rendererFormatVersion: rendererFormatVersion
            )
        } catch OfflineMapPlatformError.serverStatus(let status, _) where status == 404 {
            // Preserve compatibility while the production control plane rolls
            // to the capabilities contract. The create endpoint remains the
            // authoritative fail-closed gate and never downgrades the request.
            return
        }
    }

    private func listJobsWithRetry(
        client: OfflineMapPlatformClient
    ) async throws -> [OfflineMapJob] {
        var failureCount = 0
        while !Task.isCancelled {
            do {
                return try await client.jobs()
            } catch {
                guard OfflineMapPollingRetryPolicy.shouldRetry(error) else { throw error }
                failureCount += 1
                statusMessage = "reconnecting to map server"
                try await Task.sleep(
                    nanoseconds: OfflineMapPollingRetryPolicy.delayNanoseconds(
                        failureCount: failureCount
                    )
                )
            }
        }
        throw CancellationError()
    }

    private func ensureRegisteredInstallationWithRetry(
        client: OfflineMapPlatformClient
    ) async throws -> OfflineMapPlatformClient {
        var failureCount = 0
        while !Task.isCancelled {
            do {
                return try await ensureRegisteredInstallation(client: client)
            } catch {
                guard OfflineMapPollingRetryPolicy.shouldRetry(error) else {
                    throw error
                }
                failureCount += 1
                statusMessage = "reconnecting to map server"
                try await Task.sleep(
                    nanoseconds: OfflineMapPollingRetryPolicy.delayNanoseconds(
                        failureCount: failureCount
                    )
                )
            }
        }
        throw CancellationError()
    }

    private func selectOwnedRecoverableJob(
        from jobs: [OfflineMapJob],
        clientInstallationId: String
    ) -> OfflineMapJob? {
        OfflineMapJobRecoverySelector.select(
            jobs: jobs,
            clientInstallationId: clientInstallationId,
            excludedJobIds: OfflineMapRecoveryHistory.handledJobIds(defaults: defaults)
        )
    }

    private func consumeForgottenDiscovery(
        jobs: [OfflineMapJob],
        serverURLString: String,
        clientInstallationId: String
    ) -> Bool {
        OfflineMapRecoveryHistory.consumeForgottenDiscovery(
            serverURLString: serverURLString,
            jobIds: jobs
                .filter { $0.clientInstallationId == clientInstallationId }
                .map(\.jobId),
            defaults: defaults
        )
    }

    private func recoverOwnedServerJobIfAvailable(
        client: OfflineMapPlatformClient,
        bleManager: BLEManager?
    ) async throws -> Bool {
        let jobs = try await client.jobs()
        if consumeForgottenDiscovery(
            jobs: jobs,
            serverURLString: client.baseURL.absoluteString,
            clientInstallationId: client.clientInstallationId
        ) {
            return false
        }
        guard let recovered = selectOwnedRecoverableJob(
            from: jobs,
            clientInstallationId: client.clientInstallationId
        ) else { return false }
        adoptRecoveredJob(recovered)
        let installOnDevice = recovered.installOnDevice == true
        persistCurrentJob(installOnDevice: installOnDevice)
        statusMessage = "resuming previous map"
        try await finishRecoveredJob(
            jobId: recovered.jobId,
            installOnDevice: installOnDevice,
            client: client,
            bleManager: bleManager
        )
        return true
    }

    private func syncDownloadedMapInventoryIfNeeded() {
        guard inventorySyncTask == nil else { return }
        let packURLs = cachedPackURLs
        inventorySyncTask = Task { [weak self] in
            guard let self else { return }
            defer { self.inventorySyncTask = nil }
            do {
                let catalogCredential = await OfflineMapCatalogInventorySyncPolicy
                    .bestEffortCredential {
                        try await self.ensureCatalogCredential()
                    }
                let client = try self.makeClient()
                guard client.clientInstallationToken?.isEmpty == false else { return }
                let jobs = try await client.jobs()
                for packURL in packURLs {
                    await self.syncSavedMapInventory(
                        packURL,
                        client: client,
                        jobs: jobs,
                        catalogCredential: catalogCredential
                    )
                }
            } catch {
                // Inventory sync is best-effort. A later app activation retries
                // the stable receipt and any explicit user label.
            }
        }
    }

    private func syncSavedMapInventory(_ packURL: URL) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let catalogCredential = await OfflineMapCatalogInventorySyncPolicy
                    .bestEffortCredential {
                        try await self.ensureCatalogCredential()
                    }
                let client = try self.makeClient()
                guard client.clientInstallationToken?.isEmpty == false else { return }
                let jobs = try await client.jobs()
                await self.syncSavedMapInventory(
                    packURL,
                    client: client,
                    jobs: jobs,
                    catalogCredential: catalogCredential
                )
            } catch {
                // The app remains the local source of truth until the next
                // idempotent background sync succeeds.
            }
        }
    }

    private func syncSavedMapInventory(
        _ packURL: URL,
        client: OfflineMapPlatformClient,
        jobs: [OfflineMapJob],
        catalogCredential: OfflineMapCatalogCredential?
    ) async {
        guard var metadata = SavedMapArtifactMetadataStore.load(for: packURL),
              let jobID = metadata.jobID,
              let savedServerURL = metadata.serverURLString,
              let savedInstallationID = metadata.clientInstallationID,
              savedInstallationID == client.clientInstallationId,
              OfflineMapServerIdentity.normalized(savedServerURL) ==
                OfflineMapServerIdentity.normalized(client.baseURL.absoluteString),
              let job = jobs.first(where: { $0.jobId == jobID }) else {
            return
        }

        if metadata.downloadReceiptID == nil {
            metadata.downloadReceiptID = UUID().uuidString.lowercased()
        }
        if metadata.userDefinedDisplayName == nil {
            let localName = metadata.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceName = job.sourceRegion?.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
            metadata.userDefinedDisplayName = {
                guard let localName, !localName.isEmpty,
                      let sourceName, !sourceName.isEmpty else {
                    return false
                }
                guard !SavedMapDisplayNamePolicy.isGeneratedGenericName(localName) else {
                    return false
                }
                return SavedMapDisplayNamePolicy.clean(localName)
                    .localizedCaseInsensitiveCompare(
                        SavedMapDisplayNamePolicy.clean(sourceName)
                ) != .orderedSame
            }()
        }
        try? SavedMapArtifactMetadataStore.save(metadata, for: packURL)

        if let catalogCredential,
           metadata.catalogMapEntryID == nil || metadata.catalogSyncState != "synced" {
            do {
                let attachment = try await client.attachCatalogLibrary(
                    jobId: jobID,
                    libraryCredential: catalogCredential.credential
                )
                var aliasRevision = attachment.aliasRevision
                if let alias = OfflineMapCatalogAliasPolicy.aliasToApplyAfterAttachment(
                    localDisplayName: metadata.displayName,
                    userDefinedDisplayName: metadata.userDefinedDisplayName,
                    attachedAlias: attachment.alias
                ) {
                    guard let catalogClient else {
                        throw OfflineMapCatalogError.invalidConfiguration
                    }
                    let updated = try await catalogClient.updateAlias(
                        mapEntryId: attachment.catalogMapEntryId,
                        alias: alias,
                        expectedRevision: attachment.aliasRevision,
                        credential: catalogCredential.credential
                    )
                    aliasRevision = updated.aliasRevision
                    if let index = catalogMaps.firstIndex(where: {
                        $0.mapEntryId == updated.mapEntryId
                    }) {
                        catalogMaps[index] = updated
                    } else {
                        catalogMaps.append(updated)
                    }
                }
                metadata.catalogMapEntryID = attachment.catalogMapEntryId
                metadata.catalogLibraryID = catalogCredential.libraryId
                metadata.originChannel = OfflineMapCatalogConfig.channel(
                    generationServerURLString: savedServerURL
                )
                metadata.catalogAliasRevision = aliasRevision
                metadata.catalogSyncState = "synced"
                try SavedMapArtifactMetadataStore.save(metadata, for: packURL)
            } catch {
                metadata.catalogSyncState = "pending"
                try? SavedMapArtifactMetadataStore.save(metadata, for: packURL)
            }
        }

        let artifact = metadata.primaryArtifact ?? job.artifacts?.first(where: { value in
            if packURL.pathExtension.lowercased() == "bmap" {
                return value.isBikeMapStream
            }
            return value.isStoredZip
        })
        let fileBytes = (try? packURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init)
        guard let receiptID = metadata.downloadReceiptID,
              let byteCount = artifact?.bytes ?? fileBytes,
              byteCount > 0 else {
            return
        }
        let receipt = OfflineMapDownloadReceiptRequest(
            receiptId: receiptID,
            artifactFormat: artifact?.format ?? OfflineMapArtifact.storedZipFormat,
            sha256: artifact?.sha256,
            bytes: byteCount
        )
        do {
            try await client.recordDownload(jobId: jobID, receipt: receipt)
            if metadata.userDefinedDisplayName == true,
               let displayName = metadata.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !displayName.isEmpty {
                try await client.updateDisplayName(
                    jobId: jobID,
                    displayName: displayName
                )
            }
        } catch {
            // Preserve the stable local receipt for a later retry.
        }
    }

    private func ensureCatalogCredential() async throws -> OfflineMapCatalogCredential? {
        guard let catalogClient else { return nil }
        return try await catalogCredentialCoordinator.credential(
            loadExisting: { [catalogCredentialStore] in
                catalogCredentialStore.load()
            },
            bootstrap: { existingCredential in
                try await catalogClient.bootstrap(
                    existingCredential: existingCredential
                )
            },
            persistAnonymousBootstrap: { [catalogCredentialStore] credential in
                try catalogCredentialStore.saveAnonymousBootstrapIfAbsent(credential)
            }
        )
    }

    private func syncCatalogLibraryIfNeeded() {
        guard catalogSyncTask == nil else { return }
        catalogSyncTask = Task { [weak self] in
            guard let self else { return }
            defer { self.catalogSyncTask = nil }
            do {
                guard let credential = try await self.ensureCatalogCredential(),
                      let catalogClient = self.catalogClient else { return }
                let pendingCatalogAliasesAtRequestStart = self.pendingCatalogAliases
                let pendingCatalogAliasTokensAtRequestStart = self.pendingCatalogAliasTokens
                var maps = try await catalogClient.maps(
                    credential: credential.credential
                )
                maps = await self.pushPendingCatalogAliases(
                    into: maps,
                    client: catalogClient,
                    credential: credential
                )
                maps = await self.pushPendingCatalogOnlyAliases(
                    into: maps,
                    client: catalogClient,
                    credential: credential,
                    pendingAtRequestStart: pendingCatalogAliasesAtRequestStart,
                    pendingTokensAtRequestStart: pendingCatalogAliasTokensAtRequestStart
                )
                self.catalogMaps = maps
                self.refreshCachedPacks()
            } catch {
                // Keep local maps available and retry the shared library on the
                // next activation.
            }
        }
    }

#if HOST_TESTING
    func syncCatalogLibraryForTesting() {
        syncCatalogLibraryIfNeeded()
    }

    func recordTransferObservationForTesting(connectionEpoch: UInt64) {
        lastTransferConnectionEpoch = connectionEpoch
    }

    func useMapOperationStoreForTesting(_ store: DeviceMapOperationStore) {
        deviceMapOperationStore = store
    }

    func useFencedRetirementCleanupForTesting(_ cleanup: @escaping (BLEManager) async -> Bool) {
        fencedRetirementCleanupForTesting = cleanup
    }
#endif

    private func pushPendingCatalogAliases(
        into maps: [OfflineMapCatalogMap],
        client: OfflineMapCatalogClient,
        credential: OfflineMapCatalogCredential
    ) async -> [OfflineMapCatalogMap] {
        var reconciled = maps
        for record in cachedMapRecords {
            guard var metadata = SavedMapArtifactMetadataStore.load(
                for: record.packURL
            ),
            metadata.catalogSyncState == "pending",
            metadata.userDefinedDisplayName == true,
            let pendingAlias = metadata.displayName,
            let mapEntryID = metadata.catalogMapEntryID,
            let remoteIndex = reconciled.firstIndex(where: {
                $0.mapEntryId == mapEntryID
            }) else {
                continue
            }
            do {
                let updated = try await client.updateAlias(
                    mapEntryId: mapEntryID,
                    alias: pendingAlias,
                    expectedRevision: reconciled[remoteIndex].aliasRevision,
                    credential: credential.credential
                )
                reconciled[remoteIndex] = updated
                metadata.catalogAliasRevision = updated.aliasRevision
                metadata.catalogSyncState = "synced"
                try SavedMapArtifactMetadataStore.save(
                    metadata,
                    for: record.packURL
                )
            } catch {
                // Preserve the local pending alias and retry after the next
                // authoritative catalog refresh.
            }
        }
        return reconciled
    }

    private func pushPendingCatalogOnlyAliases(
        into maps: [OfflineMapCatalogMap],
        client: OfflineMapCatalogClient,
        credential: OfflineMapCatalogCredential,
        pendingAtRequestStart: [String: OfflineMapCatalogPendingAlias],
        pendingTokensAtRequestStart: [String: UUID]
    ) async -> [OfflineMapCatalogMap] {
        var reconciled = maps
        for mapEntryID in pendingAtRequestStart.keys.sorted() {
            guard let pending = pendingAtRequestStart[mapEntryID],
                  let pendingToken = pendingTokensAtRequestStart[mapEntryID],
                  OfflineMapCatalogPendingAliasPolicy.belongsToRequestSnapshot(
                    currentToken: pendingCatalogAliasTokens[mapEntryID],
                    requestStartToken: pendingToken
                  ) else {
                // State created or changed while the list request was in
                // flight belongs to a newer snapshot and must survive.
                continue
            }
            guard let remoteIndex = reconciled.firstIndex(where: {
                    $0.mapEntryId == mapEntryID
                  }) else {
                // A complete successful library listing is authoritative. The
                // map may have been detached by the other app, or this app may
                // have lost the response after a successful DELETE. In either
                // case the old alias must not survive and replay on reclaim.
                removePendingCatalogAlias(mapEntryID: mapEntryID)
                continue
            }
            let remote = reconciled[remoteIndex]
            switch OfflineMapCatalogPendingAliasPolicy.resolution(
                pending: pending,
                remoteAlias: remote.alias,
                remoteRevision: remote.aliasRevision
            ) {
            case .fulfilled:
                removePendingCatalogAlias(mapEntryID: mapEntryID)
            case .conflict:
                var conflict = pending
                conflict.state = .conflict
                setPendingCatalogAlias(conflict)
                reconciled[remoteIndex].alias = pending.alias
            case .retry:
                do {
                    var updated = try await client.updateAlias(
                        mapEntryId: mapEntryID,
                        alias: pending.alias,
                        expectedRevision: pending.expectedRevision,
                        credential: credential.credential
                    )
                    let requestOwnsPendingAlias =
                        OfflineMapCatalogPendingAliasPolicy.belongsToRequestSnapshot(
                            currentToken: pendingCatalogAliasTokens[mapEntryID],
                            requestStartToken: pendingToken
                        )
                    if requestOwnsPendingAlias {
                        removePendingCatalogAlias(mapEntryID: mapEntryID)
                    } else if let newerPending = pendingCatalogAliases[mapEntryID] {
                        updated.alias = newerPending.alias
                    }
                    reconciled[remoteIndex] = updated
                } catch {
                    let requestOwnsPendingAlias =
                        OfflineMapCatalogPendingAliasPolicy.belongsToRequestSnapshot(
                            currentToken: pendingCatalogAliasTokens[mapEntryID],
                            requestStartToken: pendingToken
                        )
                    let isRevisionConflict: Bool
                    if case OfflineMapCatalogError.serverStatus(409, _) = error {
                        isRevisionConflict = true
                    } else {
                        isRevisionConflict = false
                    }
                    if requestOwnsPendingAlias, isRevisionConflict {
                        var conflict = pending
                        conflict.state = .conflict
                        setPendingCatalogAlias(conflict)
                        if let refreshed = try? await client.maps(
                            credential: credential.credential
                        ) {
                            reconciled = refreshed
                        }
                    }
                    if let currentPending = pendingCatalogAliases[mapEntryID],
                       let currentIndex = reconciled.firstIndex(where: {
                        $0.mapEntryId == mapEntryID
                       }) {
                        reconciled[currentIndex].alias = currentPending.alias
                    }
                }
            }
        }
        return reconciled
    }

    private func makeClient(
        serverURLString: String? = nil
    ) throws -> OfflineMapPlatformClient {
        let value = serverURLString ?? self.serverURLString
        return try bicinoServiceSession.makeOfflineMapClient(
            serverURLString: value,
            mapStreamTrustCapabilities: mapStreamTrustStore.capabilityHeaderValue
        )
    }

    private func ensureRegisteredInstallation(
        client: OfflineMapPlatformClient,
        honorRefreshBackoff: Bool = true
    ) async throws -> OfflineMapPlatformClient {
        let registered = try await bicinoServiceSession
            .ensureRegisteredInstallation(
                client: client,
                honorRefreshBackoff: honorRefreshBackoff
            )
        if OfflineMapServerIdentity.normalized(
            registered.baseURL.absoluteString
        ) == OfflineMapServerIdentity.normalized(serverURLString) {
            clientInstallationId = registered.clientInstallationId
            clientInstallationToken = registered.clientInstallationToken
        }
        return registered
    }

    private func recoveryServerURL(
        persistedServerURL: String?
    ) -> String {
        guard let persistedServerURL,
              !persistedServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return serverURLString
        }
        if OfflineMapServerIdentity.isManaged(persistedServerURL) {
            return OfflineMapServiceConfig.defaultServerURLString
        }
        if OfflineMapServerIdentity.normalized(persistedServerURL) ==
            OfflineMapServerIdentity.normalized(serverURLString) {
            return serverURLString
        }
        return persistedServerURL
    }

    private func adoptRecoveredJob(_ job: OfflineMapJob) {
        if currentJob?.jobId != job.jobId {
            downloadedPackURL = nil
            downloadProgress = 0
            downloadByteProgress = nil
            transferProgress = 0
        }
        currentJob = job
        downloadURL = nil
        diagnosticsRecorder?.record(
            category: .map,
            event: "job_recovered",
            fields: ["mapId": job.mapId ?? ""]
        )
    }

    nonisolated static func resolvedServerURL(defaults: UserDefaults) -> String {
        let stored = defaults.string(forKey: OfflineMapDefaults.serverURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if OfflineMapServerIdentity.isManaged(stored) {
            return OfflineMapServiceConfig.defaultServerURLString
        }
        return stored
    }

    private func readyMapId() throws -> String {
        guard let mapId = currentJob?.mapId else {
            throw OfflineMapPlatformError.missingMapId
        }
        return mapId
    }

    private func waitForReadyMap(
        client: OfflineMapPlatformClient,
        jobId explicitJobId: String? = nil
    ) async throws {
        guard let jobId = explicitJobId ?? currentJob?.jobId else {
            throw OfflineMapPlatformError.invalidResponse
        }

        do {
            currentJob = try await OfflineMapJobPoller.waitForReady(
                jobId: jobId,
                pollIntervalNanoseconds: OfflineMapDefaults.mapJobPollIntervalNanoseconds,
                fetch: { id in try await client.job(id: id) },
                sleep: { nanoseconds in try await Task.sleep(nanoseconds: nanoseconds) },
                onUpdate: { [weak self] job in
                    self?.currentJob = job
                    self?.statusMessage = job.status
                },
                onRetry: { [weak self] in
                    self?.statusMessage = "reconnecting to map server"
                }
            )
        } catch {
            // Keep terminal jobs until the user discards them. Recovery can then
            // show the server's failure after an app relaunch instead of making
            // the pending map silently disappear from Saved Maps.
            if shouldForgetPersistedJob(after: error) {
                clearPersistedJob()
            }
            throw error
        }
    }

    private func downloadAndValidateTopographyCompanion(
        from url: URL,
        artifact: OfflineMapArtifact,
        associationID: String,
        mapID: String,
        streamArtifactSHA256: String,
        allowedDownloadHosts: Set<String>? = nil
    ) async throws -> (
        temporaryURL: URL,
        association: SavedTopographyCompanionAssociation
    ) {
        guard artifact.filename == "\(mapID).btopo",
              let mapContentReceipt = artifact.mapContentReceipt,
              let intermediateSha256 = artifact.intermediateSha256,
              let sourcePolicySha256 = artifact.sourcePolicySha256,
              let attributionSha256 = artifact.attributionSha256,
              SavedTopographyCompanionStorage.filename(
                mapEntryID: associationID
              ) != nil else {
            throw OfflineMapCatalogError.invalidResponse
        }
        let constraints = try OfflineMapDownloadConstraints
            .topographyCompanion(
                artifact,
                allowedDownloadHosts: allowedDownloadHosts
            )
        statusMessage = "downloading topographic contours"
        let temporaryURL = try await packDownload(
            url,
            constraints,
            { [weak self] progress in self?.downloadProgress = progress },
            { [weak self] byteProgress in
                self?.downloadByteProgress = byteProgress
            }
        )
        let receipt = TopographyCompanionReceipt(
            mapEntryID: associationID,
            mapContentReceipt: mapContentReceipt,
            mapID: mapID,
            sha256: artifact.sha256,
            bytes: artifact.bytes,
            intermediateSha256: intermediateSha256,
            sourcePolicySha256: sourcePolicySha256,
            attributionSha256: attributionSha256
        )
        let association = SavedTopographyCompanionAssociation(
            schemaVersion:
                SavedTopographyCompanionAssociation.currentSchemaVersion,
            localArtifactFilename:
                SavedTopographyCompanionStorage.filename(
                    mapEntryID: associationID
                )!,
            streamArtifactSHA256: streamArtifactSHA256,
            receipt: receipt
        )
        do {
            try association.validate()
            let store = TopographyCompanionStore(
                url: temporaryURL,
                receipt: receipt
            )
            _ = try await store.validate()
            await store.close()
            try Task.checkCancellation()
            return (temporaryURL, association)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func validateTopographyCompanionBinding(
        _ artifact: OfflineMapArtifact,
        signedTopography: VerifiedBikeMapTopography?
    ) throws {
        guard let signedTopography,
              signedTopography.profileVersion == 1,
              artifact.intermediateSha256 ==
                signedTopography.intermediateSHA256,
              artifact.sourcePolicySha256 ==
                signedTopography.sourcePolicySHA256,
              artifact.attributionSha256 ==
                signedTopography.attributionSHA256 else {
            throw OfflineMapCatalogError.invalidResponse
        }
    }

    private func downloadReadyPack(client: OfflineMapPlatformClient) async throws {
        let mapId = try readyMapId()
        guard let job = currentJob else {
            throw OfflineMapPlatformError.invalidResponse
        }
        let choice = try OfflineMapArtifactSelector.select(
            artifacts: job.artifacts ?? [],
            trustStore: mapStreamTrustStore,
            canDownloadStreamArtifact: client.clientInstallationToken?.isEmpty == false
        )
        let url: URL
        let fileExtension: String
        let primaryArtifact: OfflineMapArtifact?
        let legacyArtifact: OfflineMapArtifact?
        switch choice {
        case .bikeMapStream(let artifact, let legacy):
            url = try await client.artifactDownloadURL(
                mapId: mapId,
                jobId: job.jobId,
                artifact: artifact
            )
            fileExtension = "bmap"
            primaryArtifact = artifact
            legacyArtifact = legacy
        case .legacyZip(let artifact):
            url = try await client.downloadURL(mapId: mapId, jobId: job.jobId)
            fileExtension = "zip"
            primaryArtifact = artifact
            legacyArtifact = nil
        }
        downloadURL = url

        statusMessage = "downloading map"
        downloadProgress = 0
        downloadByteProgress = nil
        var temporaryURL: URL?
        var topographyDownload: (
            temporaryURL: URL,
            association: SavedTopographyCompanionAssociation
        )?
        var artifactDisplayName: String?
        var rendererFormatVersion: Int?
        var verifiedTopography: VerifiedBikeMapTopography?
        let trustStore = mapStreamTrustStore
        do {
            let constraints = try OfflineMapDownloadConstraints.mapArtifact(primaryArtifact)
            let downloadedURL = try await packDownload(url, constraints, { [weak self] progress in
                self?.downloadProgress = progress
            }, { [weak self] byteProgress in
                self?.downloadByteProgress = byteProgress
            })
            temporaryURL = downloadedURL
            let validationTask = Task.detached(priority: .userInitiated) {
                () throws -> (String?, Int?, VerifiedBikeMapTopography?) in
                switch choice {
                case .bikeMapStream(let artifact, _):
                    let verified = try BikeMapStreamArtifactValidator.validate(
                        url: downloadedURL,
                        artifact: artifact,
                        expectedMapID: mapId,
                        trustStore: trustStore
                    )
                    return (
                        verified.displayName,
                        verified.rendererFormatVersion,
                        verified.topography
                    )
                case .legacyZip(let artifact):
                    if let artifact {
                        try OfflineMapArtifactFileValidator.validate(
                            url: downloadedURL,
                            artifact: artifact
                        )
                    }
                    let archive = try OfflineMapPackArchive(url: downloadedURL)
                    try archive.validate(expectedMapId: mapId)
                    let manifest = try archive.manifest()
                    return (
                        manifest.displayName,
                        manifest.target?.formatVersion,
                        nil
                    )
                }
            }
            let validation = try await withTaskCancellationHandler {
                try await validationTask.value
            } onCancel: {
                validationTask.cancel()
            }
            artifactDisplayName = validation.0
            rendererFormatVersion = validation.1
            verifiedTopography = validation.2
            try Task.checkCancellation()
        } catch {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            downloadURL = nil
            throw error
        }
        guard let temporaryURL else {
            downloadURL = nil
            throw OfflineMapPlatformError.missingDownloadURL
        }
        if rendererFormatVersion == 4 {
            guard let streamArtifact = primaryArtifact,
                  streamArtifact.isBikeMapStream else {
                try? FileManager.default.removeItem(at: temporaryURL)
                downloadURL = nil
                throw OfflineMapCatalogError.missingCompatibleArtifact
            }
            let companions = (job.artifacts ?? []).filter(
                \.isTopographyCompanion
            )
            guard companions.count == 1 else {
                try? FileManager.default.removeItem(at: temporaryURL)
                downloadURL = nil
                throw OfflineMapCatalogError.missingCompatibleArtifact
            }
            let companion = companions[0]
            let associationID = job.catalogMapEntryId.flatMap {
                SavedTopographyCompanionStorage.filename(mapEntryID: $0) == nil
                    ? nil : $0
            } ?? "job_v1_\(job.jobId)"
            do {
                try validateTopographyCompanionBinding(
                    companion,
                    signedTopography: verifiedTopography
                )
                let companionURL = try await client.artifactDownloadURL(
                    mapId: mapId,
                    jobId: job.jobId,
                    artifact: companion
                )
                topographyDownload = try await
                    downloadAndValidateTopographyCompanion(
                        from: companionURL,
                        artifact: companion,
                        associationID: associationID,
                        mapID: mapId,
                        streamArtifactSHA256: streamArtifact.sha256
                    )
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                downloadURL = nil
                throw error
            }
        }
        let destination = try cachedPackURL(mapId: mapId, fileExtension: fileExtension)
        let existingMetadata = ["bmap", "zip"]
            .compactMap { try? cachedPackURL(mapId: mapId, fileExtension: $0) }
            .compactMap { SavedMapArtifactMetadataStore.load(for: $0) }
            .first
        let existingDisplayName = ["\(mapId).bmap", "\(mapId).zip"]
            .compactMap { packDisplayNames[$0] }
            .first {
                !$0.isEmpty &&
                    (existingMetadata?.userDefinedDisplayName == true ||
                        !SavedMapDisplayNamePolicy.isGeneratedGenericName($0))
            }
        let defaultDisplayName = SavedMapDisplayNamePolicy.resolve(
            artifactDisplayName: artifactDisplayName,
            sourceRegionName: job.sourceRegion?.name,
            mapID: mapId
        )
        let displayName = existingDisplayName ?? defaultDisplayName
        let userDefinedDisplayName = existingMetadata?.userDefinedDisplayName ?? {
            guard let existingDisplayName else { return false }
            return SavedMapDisplayNamePolicy.clean(existingDisplayName)
                .localizedCaseInsensitiveCompare(
                    SavedMapDisplayNamePolicy.clean(defaultDisplayName)
            ) != .orderedSame
        }()
        let downloadReceiptID = UUID().uuidString.lowercased()
        let metadata = SavedMapArtifactMetadata(
            schemaVersion: SavedMapArtifactMetadata.currentSchemaVersion,
            mapID: mapId,
            displayName: displayName,
            localArtifactFilename: destination.lastPathComponent,
            streamFormatVersion: fileExtension == "bmap" ? 1 : nil,
            rendererFormatVersion: rendererFormatVersion,
            jobID: job.jobId,
            serverURLString: client.baseURL.absoluteString,
            clientInstallationID: client.clientInstallationId,
            primaryArtifact: primaryArtifact,
            legacyArtifact: legacyArtifact,
            lastTransferProtocol: nil,
            lastTransferStreamFormat: nil,
            lastTransferSessionID: nil,
            lastBackgroundTaskID: nil,
            lastDeviceSequence: nil,
            lastDeviceState: nil,
            lastDeviceStep: nil,
            lastDeviceStepCount: nil,
            lastDeviceProgress: nil,
            expectedActiveMapID: mapId,
            expectedActiveSessionID: nil,
            lastTransferOutcome: nil,
            userDefinedDisplayName: userDefinedDisplayName,
            downloadReceiptID: downloadReceiptID,
            catalogContentReceipt:
                topographyDownload?.association.receipt.mapContentReceipt,
            topography: verifiedTopography
        )
        do {
            if let topographyDownload {
                let companionDestination = try cachedTopographyCompanionURL(
                    associationID:
                        topographyDownload.association.receipt.mapEntryID
                )
                try replaceTopographyCompanion(
                    at: topographyDownload.temporaryURL,
                    destination: companionDestination,
                    association: topographyDownload.association
                )
                defaults.set(
                    topographyDownload.association.receipt.mapEntryID,
                    forKey: OfflineMapDefaults.activeTopographyAssociationKey
                )
            }
            try replaceDownloadedArtifact(
                at: temporaryURL,
                destination: destination,
                metadata: metadata,
                mapID: mapId,
                fileExtension: fileExtension
            )
        } catch {
            if let topographyDownload {
                try? FileManager.default.removeItem(
                    at: topographyDownload.temporaryURL
                )
            }
            downloadURL = nil
            throw error
        }
        downloadedPackURL = destination
        OfflineMapJobPersistence.markPackDownloaded(
            jobId: job.jobId,
            mapId: mapId,
            defaults: defaults
        )
        if packDisplayNames[destination.lastPathComponent]?.isEmpty != false {
            packDisplayNames[destination.lastPathComponent] = displayName
        }
        persistPackDisplayNames()
        let receiptBytes = primaryArtifact?.bytes ?? Int64(
            (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        if receiptBytes > 0 {
            try? await client.recordDownload(
                jobId: job.jobId,
                receipt: OfflineMapDownloadReceiptRequest(
                    receiptId: downloadReceiptID,
                    artifactFormat: primaryArtifact?.format ?? OfflineMapArtifact.storedZipFormat,
                    sha256: primaryArtifact?.sha256,
                    bytes: receiptBytes
                )
            )
        }
        if userDefinedDisplayName, !displayName.isEmpty {
            try? await client.updateDisplayName(jobId: job.jobId, displayName: displayName)
        }
        refreshCachedPacks()
#if canImport(UIKit)
        loadPreviewIfNeeded(forCachedPack: destination)
#endif
        downloadProgress = 1
        downloadByteProgress = nil
        transferProgress = 0
        statusMessage = "map downloaded"
    }

    func replaceDownloadedArtifact(
        at temporaryURL: URL,
        destination: URL,
        metadata: SavedMapArtifactMetadata,
        mapID: String,
        fileExtension: String,
        obsoleteDestination: URL? = nil
    ) throws {
        defer { invalidateCachedPreview(for: destination) }
        let directory = destination.deletingLastPathComponent()
        var journal = try SavedMapReplacementJournal.begin(at: destination)
        let backup = journal.backup(in: directory)
        let metadataURL = SavedMapArtifactMetadataStore.metadataURL(for: destination)
        let metadataBackup = SavedMapArtifactMetadataStore.metadataURL(for: backup)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: destination, to: backup)
                try SavedMapReplacementJournal.sync(directory)
            }
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                try FileManager.default.moveItem(at: metadataURL, to: metadataBackup)
                try SavedMapReplacementJournal.sync(directory)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            try metadataSave(metadata, destination)
            try SavedMapReplacementJournal.sync(destination)
            try SavedMapReplacementJournal.sync(metadataURL)
            try SavedMapReplacementJournal.sync(directory)
            journal.committed = true
            try journal.save(in: directory)
            // Once committed, recovery must keep the new coherent pair. Cleanup
            // failure is retried at launch, never treated as installation failure.
            try? journal.finish(in: directory)
            let obsoleteExtension = fileExtension == "bmap" ? "zip" : "bmap"
            let obsolete = try obsoleteDestination ?? cachedPackURL(
                mapId: mapID,
                fileExtension: obsoleteExtension
            )
            if FileManager.default.fileExists(atPath: obsolete.path) {
                try? FileManager.default.removeItem(at: obsolete)
                try? SavedMapArtifactMetadataStore.delete(for: obsolete)
                packDisplayNames.removeValue(forKey: obsolete.lastPathComponent)
                invalidateCachedPreview(for: obsolete)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            // Read the persisted commit decision, not an in-memory flag whose
            // journal write may have failed. Preserve the journal on repair error.
            try? SavedMapReplacementJournal.recover(in: directory)
            throw error
        }
    }

    private func finishRecoveredJob(
        jobId: String,
        installOnDevice: Bool,
        client: OfflineMapPlatformClient,
        bleManager: BLEManager?
    ) async throws {
        if try await finishDownloadedRecoveredJobIfAvailable(
            jobId: jobId,
            installOnDevice: installOnDevice,
            bleManager: bleManager
        ) {
            return
        }

        try await waitForReadyMap(client: client, jobId: jobId)
        let canReuseDownloadedPack = OfflineMapJobPersistence.downloadedJobId(
            defaults: defaults
        ) == jobId
        if canReuseDownloadedPack,
           let mapId = currentJob?.mapId {
            let cachedURL = try cachedPackURL(mapId: mapId)
            if FileManager.default.fileExists(atPath: cachedURL.path) {
                downloadedPackURL = cachedURL
                downloadProgress = 1
                statusMessage = "pack downloaded"
            } else {
                try await downloadReadyPack(client: client)
            }
        } else {
            try await downloadReadyPack(client: client)
        }
        if installOnDevice {
            guard let bleManager,
                  bleManager.isConnected,
                  bleManager.isNavigationReady else {
                statusMessage = "map downloaded; reconnect device to install"
                return
            }
            if let downloadedPackURL {
                let deviceState = await cachedPackDeviceState(
                    downloadedPackURL,
                    bleManager: bleManager
                )
                if deviceState == .pending {
                    statusMessage = "map activation is still running on device"
                    return
                }
                if deviceState == .installed {
                    statusMessage = "map installed: \(displayName(forCachedPack: downloadedPackURL))"
                    updateLastTransferOutcome("installed")
                    clearPersistedJob(markHandled: true)
                    return
                }
            }
            try await transferReadyPack(bleManager: bleManager)
        }
        clearPersistedJob(markHandled: true)
    }

    private func finishDownloadedRecoveredJobIfAvailable(
        jobId: String,
        installOnDevice: Bool,
        bleManager: BLEManager?
    ) async throws -> Bool {
        if !installOnDevice, restoreDownloadedPackIfAvailable(jobId: jobId) {
            clearPersistedJob(markHandled: true)
            statusMessage = "map downloaded"
            return true
        }
        if installOnDevice, restoreDownloadedPackIfAvailable(jobId: jobId) {
            guard let bleManager,
                  bleManager.isConnected,
                  bleManager.isNavigationReady else {
                statusMessage = "map downloaded; reconnect device to install"
                return true
            }
            if let downloadedPackURL {
                let deviceState = await cachedPackDeviceState(
                    downloadedPackURL,
                    bleManager: bleManager
                )
                if deviceState == .pending {
                    statusMessage = "map activation is still running on device"
                    return true
                }
                if deviceState == .installed {
                    statusMessage = "map installed: \(displayName(forCachedPack: downloadedPackURL))"
                    updateLastTransferOutcome("installed")
                    clearPersistedJob(markHandled: true)
                    return true
                }
            }
            try await transferReadyPack(bleManager: bleManager)
            clearPersistedJob(markHandled: true)
            return true
        }
        return false
    }

    private func cachedPackDeviceState(
        _ packURL: URL,
        bleManager: BLEManager
    ) async -> CachedPackRecoveryDecision {
        guard let identity = try? transferIdentity(for: packURL) else {
            return .absent
        }
        let expectedSessionId = identity.sessionID
        if defaults.string(forKey: "offlineMap.deviceOperationID") != nil,
           currentDeviceMapOperation == nil { return .pending }
        if let operation = currentDeviceMapOperation,
           operation.mapID == identity.mapID, operation.sessionID == expectedSessionId {
            guard operation.deviceID == bleManager.activeDeviceID else { return .pending }
            if operation.usesDurableProtocol {
                _ = reconcileDurableMapOperation(bleManager: bleManager)
                if currentDeviceMapOperation?.observation == "installed_confirmed" { return .installed }
                if currentDeviceMapOperation?.isRetiredUnknown == true { return .absent }
                if currentDeviceMapOperation?.isTerminal == true { return .absent }
                startActivationReconciliationMonitor(bleManager: bleManager)
                return .pending
            }
            // A legacy journal alone is not an observation in this process.
            // Only the in-memory transfer binding may accept its terminal result.
        }
        guard bleManager.requestMapTransferStatus() else { return .absent }
        _ = await bleManager.waitForNavigationWritesToDrain(timeoutSeconds: 2)
        let initialDeadline = Date().addingTimeInterval(2)
        var activationDeadline: Date?
        var pollCount = 0
        while true {
            if Task.isCancelled { return .pending }
            let decision = CachedPackRecoveryDecision.evaluate(
                expectedSessionId: expectedSessionId,
                activeSessionId: bleManager.mapTransferActiveSessionId,
                activationStatus: bleManager.mapTransferActivationStatus,
                activationSessionId: bleManager.hasFreshMapTransferStatus
                    ? bleManager.mapTransferActivationSessionId : "",
                bindsOriginalObservation: hasBoundLegacyTransferObservation(
                    mapID: identity.mapID, sessionID: expectedSessionId, bleManager: bleManager)
            )
            switch decision {
            case .installed:
                return .installed
            case .pending:
                if activationDeadline == nil {
                    activationDeadline = Date().addingTimeInterval(
                        OfflineMapDefaults.activationConfirmationTimeout
                    )
                }
            case .absent:
                if bleManager.mapTransferActivationSessionId == expectedSessionId,
                   bleManager.mapTransferActivationStatus == "failed" {
                    return .absent
                }
                break
            }
            let now = Date()
            if let activationDeadline {
                if now >= activationDeadline { return .pending }
            } else if now >= initialDeadline {
                return .absent
            }
            pollCount += 1
            if pollCount % 10 == 0 {
                bleManager.requestMapTransferStatus()
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func restoreDownloadedPackIfAvailable(jobId: String) -> Bool {
        guard OfflineMapJobPersistence.downloadedJobId(defaults: defaults) == jobId,
              let mapId = OfflineMapJobPersistence.downloadedMapId(defaults: defaults),
              let cachedURL = try? cachedPackURL(mapId: mapId),
              FileManager.default.fileExists(atPath: cachedURL.path) else {
            return false
        }
        downloadedPackURL = cachedURL
        downloadProgress = 1
        downloadByteProgress = nil
        statusMessage = "pack downloaded"
        return true
    }

    private func persistCurrentJob(installOnDevice: Bool) {
        guard let jobId = currentJob?.jobId else { return }
        OfflineMapJobPersistence.save(
            jobId: jobId,
            installOnDevice: installOnDevice,
            serverURLString: serverURLString,
            defaults: defaults
        )
        diagnosticsRecorder?.record(
            category: .map,
            event: "job_persisted",
            fields: [
                "mapId": currentJob?.mapId ?? "",
                "outcome": installOnDevice ? "device" : "iphone",
            ]
        )
    }

    private func clearPersistedJob(markHandled: Bool = false) {
        diagnosticsRecorder?.record(
            category: .map,
            event: "job_cleared",
            fields: [
                "mapId": currentJob?.mapId ?? "",
                "outcome": markHandled ? "handled" : "cleared",
            ]
        )
        if markHandled,
           let jobId = OfflineMapJobPersistence.activeJobId(defaults: defaults) {
            OfflineMapRecoveryHistory.markHandled(jobId: jobId, defaults: defaults)
        }
        OfflineMapJobPersistence.clear(defaults: defaults)
        isServerRecoveryCheckPending = false
    }

    private func canStartNewMapJob() -> Bool {
        guard !hasPendingMapJob else {
            errorMessage = "Resume the pending map before starting another download."
            return false
        }
        return true
    }

    private func shouldForgetPersistedJob(after error: Error) -> Bool {
        guard let platformError = error as? OfflineMapPlatformError,
              case .serverStatus(let status, _) = platformError else {
            return false
        }
        return status == 404
    }

    private func transferReadyPack(bleManager: BLEManager) async throws {
        guard let packURL = downloadedPackURL else {
            throw OfflineMapPlatformError.missingDownloadURL
        }
        while isDeviceTransferBusy || hasActiveBackgroundUpload {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        isDeviceTransferBusy = true
        defer { isDeviceTransferBusy = false }
        try await transferPack(at: packURL, bleManager: bleManager)
    }

    private func startDeviceTransfer(
        _ operation: @MainActor @escaping (OfflineMapManager) async throws -> Void
    ) {
        guard !isDeviceTransferBusy else { return }
        isDeviceTransferBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isDeviceTransferBusy = false }
            await self.runBusy {
                try await operation(self)
            }
        }
    }

    private func transferPack(
        at packURL: URL,
        bleManager: BLEManager,
        resumePausedUpload: Bool = false
    ) async throws {
        let transferDeviceID = bleManager.activeDeviceID
        let transferEpoch = bleManager.transferConnectionEpoch
        var resumeProgressFloor: Int
        if resumePausedUpload {
            let lastVisibleProgress = max(
                activationProgress?.percentage ?? 0,
                SavedMapArtifactMetadataStore.load(for: packURL)?.lastDeviceProgress ?? 0
            )
            resumeProgressFloor = min(max(lastVisibleProgress, 0), 100)
        } else {
            resumeProgressFloor = 0
        }
        if let metadata = SavedMapArtifactMetadataStore.load(for: packURL),
           !SavedMapRendererCompatibilityPolicy.isCompatible(
               rendererFormatVersion: metadata.rendererFormatVersion,
               supportsStreetLabels: bleManager.supportsStreetLabels,
               supports3DBuildings: bleManager.supports3DBuildings,
               supportsTopographicContours:
                   bleManager.supportsTopographicContours
           ) {
            throw OfflineMapPlatformError.invalidPack(
                "This saved map is not compatible with the connected device. Regenerate it for this firmware."
            )
        }
        statusMessage = "preparing transfer"
        transferProgress = 0
        activationProgress = resumeProgressFloor > 0
            ? MapActivationProgressPresentation(
                step: 1,
                stepCount: 3,
                percentage: resumeProgressFloor
            )
            : nil
        if packURL.pathExtension.lowercased() == "bmap",
           let metadata = SavedMapArtifactMetadataStore.load(for: packURL),
           SavedMapStreamMigrationFallback.shouldUseLegacyArtifact(for: metadata) {
            throw OfflineMapPlatformError.firmwareMapStreamUnsupported
        }
        let trustStore = mapStreamTrustStore
        let validationTask = Task.detached(priority: .userInitiated) {
            if packURL.pathExtension.lowercased() == "bmap" {
                guard let metadata = SavedMapArtifactMetadataStore.load(for: packURL),
                      let artifact = metadata.primaryArtifact,
                      artifact.isBikeMapStream else {
                    throw OfflineMapPlatformError.invalidPack(
                        "signed map metadata is missing or does not match"
                    )
                }
#if DEBUG
                let deriveReaderRequirementsFromSignedManifest =
                    SavedMapReaderRequirementsMigrationPolicy
                        .shouldDeriveFromSignedManifest(
                            generationServerURLString: metadata.serverURLString,
                            isDevelopmentBuild: true
                        )
#else
                let deriveReaderRequirementsFromSignedManifest = false
#endif
                let verified = try BikeMapStreamArtifactValidator.validate(
                    url: packURL,
                    artifact: artifact,
                    expectedMapID: metadata.mapID,
                    trustStore: trustStore,
                    readerRequirements: metadata.readerRequirements,
                    deriveReaderRequirementsFromSignedManifest:
                        deriveReaderRequirementsFromSignedManifest
                )
                return PreparedMapTransfer(artifact: verified)
            }
            throw OfflineMapPlatformError.firmwareMapStreamUnsupported
        }
        let prepared = try await withTaskCancellationHandler {
            try await validationTask.value
        } onCancel: {
            validationTask.cancel()
        }
        try Task.checkCancellation()
        if !SavedMapRendererCompatibilityPolicy.isCompatible(
               rendererFormatVersion: prepared.artifact.rendererFormatVersion,
               supportsStreetLabels: bleManager.supportsStreetLabels,
               supports3DBuildings: bleManager.supports3DBuildings,
               supportsTopographicContours:
                   bleManager.supportsTopographicContours
           ) {
            throw OfflineMapPlatformError.invalidPack(
                "This saved map is not compatible with the connected device. Regenerate it for this firmware."
            )
        }
        guard transferDeviceID == bleManager.activeDeviceID,
              transferEpoch == bleManager.transferConnectionEpoch else { throw CancellationError() }
        let expectedMapId = prepared.mapID
        let sessionId = prepared.sessionID
        var activationMayBeInFlight = false

#if os(iOS)
        let activeUploadActivity = await BackgroundMapUploadCoordinator.shared
            .activeUploadActivity()
        guard activeUploadActivity.descriptors.allSatisfy({
            $0.deviceID == transferDeviceID && $0.deviceID != nil &&
            $0.appNamespace == BackgroundMapUploadSessionNamespace.identifier(bundleIdentifier: Bundle.main.bundleIdentifier)
        }) else { throw OfflineMapPlatformError.backgroundMapUploadInProgress }
        switch BackgroundMapUploadArbitration.evaluate(
            active: activeUploadActivity.descriptors,
            hasUnidentifiedActiveUpload: activeUploadActivity.hasUnidentifiedTask,
            mapID: expectedMapId,
            sessionID: sessionId,
            resumeRequested: resumePausedUpload
        ) {
        case .retainExisting:
            retainExistingStreamAttempt(
                mapID: expectedMapId,
                sessionID: sessionId,
                artifactURL: packURL,
                activeMapID: bleManager.mapTransferActiveMapId,
                activeSessionID: bleManager.mapTransferActiveSessionId,
                activationStatus: "receiving",
                activationSequence: bleManager.mapTransferActivationSequence,
                activationSessionID: sessionId,
                activationStep: 1,
                activationStepCount: 3,
                activationProgress: BackgroundMapUploadStateStore.latest(
                    mapID: expectedMapId,
                    sessionID: sessionId,
                    defaults: defaults
                )?.percentage,
                bleManager: bleManager,
                bindsOriginalObservation: hasBoundLegacyTransferObservation(
                    mapID: expectedMapId, sessionID: sessionId, bleManager: bleManager)
            )
            return
        case .retireExisting:
            break
        case .blockForOther:
            throw OfflineMapPlatformError.backgroundMapUploadInProgress
        case .begin:
            break
        }
        if resumePausedUpload {
            guard await BackgroundMapUploadCoordinator.shared.retireActiveUpload(
                mapID: expectedMapId,
                sessionID: sessionId
            ) else {
                throw OfflineMapPlatformError.backgroundMapUploadInProgress
            }
            let remainingActivity = await BackgroundMapUploadCoordinator.shared
                .activeUploadActivity()
            hasActiveBackgroundUpload = remainingActivity.hasActiveTask
            guard BackgroundMapUploadArbitration.evaluate(
                active: remainingActivity.descriptors,
                hasUnidentifiedActiveUpload: remainingActivity.hasUnidentifiedTask,
                mapID: expectedMapId,
                sessionID: sessionId
            ) == .begin else {
                throw OfflineMapPlatformError.backgroundMapUploadInProgress
            }
        }
#endif

        let requiresDurableReconciliation = bleManager.supportsMapOperationsV1 ||
            defaults.string(forKey: "offlineMap.deviceOperationID") != nil
        let disposition: ExistingMapStreamAttemptDisposition = requiresDurableReconciliation ||
            !bleManager.hasFreshMapTransferStatus ? .upload : ExistingMapStreamAttemptDisposition.evaluate(
            expectedSessionID: sessionId,
            activeSessionID: bleManager.mapTransferActiveSessionId,
            activationStatus: bleManager.mapTransferActivationStatus,
            activationSessionID: bleManager.mapTransferActivationSessionId,
            bindsOriginalObservation: hasBoundLegacyTransferObservation(
                mapID: expectedMapId, sessionID: sessionId, bleManager: bleManager)
        )
        if disposition != .upload {
            retainExistingStreamAttempt(
                mapID: expectedMapId,
                sessionID: sessionId,
                artifactURL: packURL,
                activeMapID: bleManager.mapTransferActiveMapId,
                activeSessionID: bleManager.mapTransferActiveSessionId,
                activationStatus: bleManager.mapTransferActivationStatus,
                activationSequence: bleManager.mapTransferActivationSequence,
                activationSessionID: bleManager.mapTransferActivationSessionId,
                activationStep: bleManager.mapTransferActivationStep,
                activationStepCount: bleManager.mapTransferActivationStepCount,
                activationProgress: bleManager.mapTransferActivationProgress,
                bleManager: bleManager,
                bindsOriginalObservation: hasBoundLegacyTransferObservation(
                    mapID: expectedMapId, sessionID: sessionId, bleManager: bleManager)
            )
            return
        }

        var deviceOperation: DeviceMapOperationRecord?
        if let deviceID = bleManager.activeDeviceID, !deviceID.hasPrefix("legacy:") {
            let existing = try self.deviceMapOperationStore.records().first {
                $0.deviceID == deviceID && $0.blocksNewTransfer(
                    connectionEpoch: bleManager.transferConnectionEpoch,
                    processID: DeviceMapOperationStore.observationProcessID)
            }
            if let existing {
                guard existing.mapID == expectedMapId && existing.sessionID == sessionId &&
                    existing.streamSHA256 == prepared.artifact.sha256 &&
                    existing.streamBytes == UInt64(prepared.artifact.bytes) &&
                    existing.manifestReceipt == prepared.artifact.manifestReceipt &&
                    existing.signedManifestReceipt == prepared.artifact.signedManifestReceipt &&
                    existing.appNamespace == BackgroundMapUploadSessionNamespace.identifier(bundleIdentifier: Bundle.main.bundleIdentifier) else {
                    throw OfflineMapPlatformError.backgroundMapUploadInProgress
                }
                deviceOperation = existing
            } else {
                let artifact = prepared.artifact
                let previousSelection = previousConfirmedSelection(bleManager: bleManager)
                deviceOperation = DeviceMapOperationRecord(
                    schemaVersion: 1, deviceID: deviceID, operationID: UUID(),
                    sessionID: sessionId, mapID: expectedMapId,
                    manifestReceipt: artifact.manifestReceipt,
                    signedManifestReceipt: artifact.signedManifestReceipt,
                    streamSHA256: artifact.sha256, streamBytes: UInt64(artifact.bytes),
                    artifactFilename: packURL.lastPathComponent,
                    appNamespace: BackgroundMapUploadSessionNamespace.identifier(bundleIdentifier: Bundle.main.bundleIdentifier),
                    createdAt: Date(), connectionEpoch: bleManager.transferConnectionEpoch,
                    observation: "enter_requested", cleanup: "pending", usesDurableProtocol: false,
                    lastReceipt: nil,
                    observationProcessID: DeviceMapOperationStore.observationProcessID,
                    previousConfirmedSelection: previousSelection
                )
            }
            if let deviceOperation {
                try self.deviceMapOperationStore.save(deviceOperation)
                defaults.set(deviceOperation.operationID.uuidString, forKey: "offlineMap.deviceOperationID")
                if deviceOperation.usesDurableProtocol {
                    recordTransfer(mapId: expectedMapId, sessionId: sessionId,
                                   previousMapId: bleManager.mapTransferActiveMapId,
                                   previousSessionId: bleManager.mapTransferActiveSessionId,
                                   previousSequence: bleManager.mapTransferActivationSequence,
                                   outcome: "unconfirmed",
                                   connectionEpoch: bleManager.transferConnectionEpoch, protocolVersion: 2,
                                   streamFormatVersion: 1, artifactURL: packURL)
                }
            }
        } else {
            // An old operation must never attach to a legacy/unidentified device.
            guard currentDeviceMapOperation == nil else {
                throw OfflineMapPlatformError.backgroundMapUploadInProgress
            }
        }
        do {
            if resumePausedUpload, deviceOperation?.usesDurableProtocol != true {
                statusMessage = "restarting device transfer mode"
                await deviceTransferManager.exitMapTransfer(bleManager: bleManager)
            }
            let transferSession: DeviceTransferSession
            if let recoveryRecord = deviceOperation, recoveryRecord.usesDurableProtocol {
                transferSession = try await deviceTransferManager.resumeMapTransfer(
                    bleManager: bleManager,
                    verifiedPrecommitRecovery: hasVerifiedPrecommitRecovery(recoveryRecord, bleManager: bleManager),
                    recoveryDeviceID: recoveryRecord.deviceID,
                    recoveryConnectionEpoch: bleManager.transferConnectionEpoch
                ) {
                    self.statusMessage = $0
                }
            } else {
                transferSession = try await deviceTransferManager.enterMapTransfer(
                    bleManager: bleManager, expectedDeviceID: transferDeviceID,
                    expectedConnectionEpoch: transferEpoch
                ) {
                    self.statusMessage = $0
                }
            }
            try await withBackgroundTransferLifecycle(bleManager: bleManager) {
                guard transferDeviceID == bleManager.activeDeviceID,
                      transferEpoch == bleManager.transferConnectionEpoch else { throw CancellationError() }
                guard let pinnedSession =
                        DeviceTransferPinnedSessionFactory.make(
                    configuration: .ephemeral,
                    baseURL: transferSession.baseURL,
                    certificateSHA256:
                        transferSession.tlsCertificateSHA256
                ) else {
                    throw DeviceTransferSecurityError.secureTransferRequired
                }
                defer { pinnedSession.invalidateAndCancel() }
                let client = MapTransferDeviceClient(
                    baseURL: transferSession.baseURL,
                    sessionToken: transferSession.sessionToken,
                    session: pinnedSession
                )
                let originalDeviceID = bleManager.activeDeviceID
                let originalEpoch = bleManager.transferConnectionEpoch
                guard let httpContext = bleManager.captureMapTransferHTTPStatusContext() else { throw CancellationError() }
                let initialDeviceStatus = try await client.status()
                guard originalDeviceID == bleManager.activeDeviceID,
                      originalEpoch == bleManager.transferConnectionEpoch,
                              bleManager.isCurrentMapTransferHTTPStatusContext(httpContext) else { throw CancellationError() }
                guard bleManager.applyAuthenticatedMapTransferStatus(initialDeviceStatus, context: httpContext) else {
                    throw CancellationError()
                }
                guard initialDeviceStatus.mapOperationsV1 != true || deviceOperation != nil else {
                    throw OfflineMapPlatformError.invalidResponse
                }
                // ACK may have been impossible after the previous automatic AP
                // exit. Retire only already-durable terminal results for this
                // exact device once a fresh authenticated session is available.
                for terminal in try self.deviceMapOperationStore.records().filter({
                    $0.deviceID == originalDeviceID && $0.isTerminal && $0.usesDurableProtocol &&
                    $0.acknowledgedAt == nil && $0.lastReceipt != nil
                }).prefix(32) {
                    await acknowledgeDurableResult(terminal, client: client)
                    guard bleManager.isCurrentMapTransferHTTPStatusContext(httpContext) else { throw CancellationError() }
                }
                if var record = deviceOperation {
                    if record.usesDurableProtocol {
                        let receipt = try await client.operationStatus(operationID: record.wireOperationID)
                        guard originalDeviceID == bleManager.activeDeviceID,
                              originalEpoch == bleManager.transferConnectionEpoch,
                              bleManager.isCurrentMapTransferHTTPStatusContext(httpContext) else { throw CancellationError() }
                        if receipt.status != nil {
                            guard receipt.status == "result_unavailable", receipt.deviceID == record.deviceID,
                                  receipt.operationID == record.wireOperationID else {
                                throw OfflineMapPlatformError.invalidResponse
                            }
                            let admission = try await client.operationAdmission()
                            guard originalDeviceID == bleManager.activeDeviceID,
                                  originalEpoch == bleManager.transferConnectionEpoch,
                              bleManager.isCurrentMapTransferHTTPStatusContext(httpContext) else { throw CancellationError() }
                            record = try self.deviceMapOperationStore.prepareReplayAfterUnavailable(
                                operationID: record.operationID, admission: admission
                            )
                        } else {
                            guard let updated = try self.deviceMapOperationStore.ingest(receipt) else {
                                throw OfflineMapPlatformError.invalidResponse
                            }
                            record = updated
                        }
                        if record.isTerminal {
                            await acknowledgeDurableResult(record, client: client)
                            guard originalDeviceID == bleManager.activeDeviceID,
                                  originalEpoch == bleManager.transferConnectionEpoch,
                              bleManager.isCurrentMapTransferHTTPStatusContext(httpContext) else { throw CancellationError() }
                            updateLastTransferOutcome(record.observation == "installed_confirmed" ? "installed" : "failed")
                            return
                        }
                        if record.lastReceipt?.phase == "prepared" || record.lastReceipt?.phase == "accepted" ||
                            record.cancellationRequestedAt != nil {
                            deviceOperation = record
                            try await finishActivationConfirmation(expectedMapID: expectedMapId, sessionID: sessionId,
                                previousMapID: nil, previousSessionID: nil, previousSequence: nil,
                                acceptedSequence: nil, client: client, bleManager: bleManager)
                            return
                        }
                        if record.lastReceipt?.phase == "receiving" {
                            record = try self.deviceMapOperationStore.retireInterruptedTransport(operationID: record.operationID)
                        }
                    }
                    record.usesDurableProtocol = record.usesDurableProtocol || initialDeviceStatus.mapOperationsV1 == true
                    if record.usesDurableProtocol, record.admissionRevision == nil {
                        // Only an operation that has never uploaded may obtain a new
                        // admission revision. Retries keep their original admission.
                        guard record.uploadAttemptID == nil, record.lastReceipt == nil else {
                            throw OfflineMapPlatformError.invalidResponse
                        }
                        let admission = try await client.operationAdmission()
                        guard admission.schemaVersion == 1, admission.deviceID == record.deviceID,
                              DeviceMapOperationReceipt.isLowerHex(admission.admissionEpoch, count: 32),
                              originalDeviceID == bleManager.activeDeviceID,
                              originalEpoch == bleManager.transferConnectionEpoch,
                              bleManager.isCurrentMapTransferHTTPStatusContext(httpContext) else {
                            throw OfflineMapPlatformError.invalidResponse
                        }
                        record.admissionRevision = admission.admissionRevision
                        record.admissionEpoch = admission.admissionEpoch
                    }
                    record.observation = "in_progress"
                    try self.deviceMapOperationStore.save(record)
                    deviceOperation = record
                }
                if let activation = initialDeviceStatus.activation,
                   activation.sessionId == sessionId,
                   activation.step == 1,
                   let deviceProgress = activation.progress {
                    resumeProgressFloor = MapUploadProgressReconciler.percentage(
                        retryTransportPercentage: resumeProgressFloor,
                        durableDevicePercentage: deviceProgress
                    ) ?? 0
                    updateSavedMapDeviceState(
                        mapID: expectedMapId,
                        sequence: activation.sequence,
                        state: activation.status ?? "paused",
                        step: activation.step,
                        stepCount: activation.steps,
                        progress: deviceProgress
                    )
                }
                let artifact = prepared.artifact
                let protocolEvaluation = MapInstallProtocolSelector.evaluate(
                       isBikeMapStream: true,
                       signatureTrustCapability:
                           "\(artifact.signatureKeyID)=\(artifact.signatureKeySHA256)",
                       requiredIosBuild: artifact.requiredIosBuild,
                       requiredIosGitSha: artifact.requiredIosGitSHA,
                       requiredIosBuildSha256: artifact.requiredIosBuildSHA256,
                       currentIosBuild: MapStreamAppBuildIdentity.current?.build,
                       currentIosGitSha: MapStreamAppBuildIdentity.current?.gitSha,
                       currentIosBuildSha256:
                           MapStreamAppBuildIdentity.current?.componentSha256,
                       compatibleArtifactAppIdentities:
                           MapStreamAppArtifactCompatibilityPolicy
                               .resumablePredecessorIdentities,
                       readerRequirements: artifact.readerRequirements,
                       requiredFirmwareVersion: artifact.requiredFirmwareVersion,
                       requiredFirmwareBuild: artifact.requiredFirmwareBuild,
                       requiredFirmwareGitSha: artifact.requiredFirmwareGitSHA,
                       deviceStatus: initialDeviceStatus
                   )
                if let rejection = protocolEvaluation.rejection {
                    throw OfflineMapPlatformError.mapStreamCompatibilityRejected(
                        rejection
                    )
                }
                let disposition: ExistingMapStreamAttemptDisposition = deviceOperation?.usesDurableProtocol == true
                    ? .upload : ExistingMapStreamAttemptDisposition.evaluate(
                    expectedSessionID: sessionId,
                    activeSessionID: initialDeviceStatus.activeSessionId,
                    activationStatus: initialDeviceStatus.activation?.status,
                    activationSessionID: initialDeviceStatus.activation?.sessionId,
                    bindsOriginalObservation: hasBoundLegacyTransferObservation(
                        mapID: expectedMapId, sessionID: sessionId, bleManager: bleManager)
                )
                if disposition != .upload {
                    retainExistingStreamAttempt(
                        mapID: expectedMapId,
                        sessionID: sessionId,
                        artifactURL: packURL,
                        activeMapID: initialDeviceStatus.activeMapId,
                        activeSessionID: initialDeviceStatus.activeSessionId,
                        activationStatus: initialDeviceStatus.activation?.status,
                        activationSequence: initialDeviceStatus.activation?.sequence,
                        activationSessionID: initialDeviceStatus.activation?.sessionId,
                        activationStep: initialDeviceStatus.activation?.step,
                        activationStepCount: initialDeviceStatus.activation?.steps,
                        activationProgress: initialDeviceStatus.activation?.progress,
                        bleManager: bleManager,
                        bindsOriginalObservation: hasBoundLegacyTransferObservation(
                            mapID: expectedMapId, sessionID: sessionId, bleManager: bleManager)
                    )
                    return
                }
                transferProgress = 0
                statusMessage = "uploading \(displayName(forMapId: expectedMapId)) to device"
                recordTransfer(
                    mapId: expectedMapId,
                    sessionId: sessionId,
                    previousMapId: initialDeviceStatus.activeMapId ??
                        bleManager.mapTransferActiveMapId,
                    previousSessionId: initialDeviceStatus.activeSessionId ??
                        bleManager.mapTransferActiveSessionId,
                    previousSequence: initialDeviceStatus.activation?.sequence ??
                        bleManager.mapTransferActivationSequence,
                    outcome: "uploading",
                    connectionEpoch: bleManager.transferConnectionEpoch,
                    protocolVersion: 2,
                    streamFormatVersion: 1,
                    artifactURL: packURL
                )

                activationMayBeInFlight = true
                let retryProgressFloor = resumeProgressFloor
                let uploadOperationID = deviceOperation?.operationID
                do {
                    try await client.uploadStreamInBackground(
                        artifact: artifact,
                        sessionId: sessionId,
                        descriptor: BackgroundMapUploadDescriptor(
                            mapID: expectedMapId,
                            sessionID: sessionId,
                            protocolVersion: 2,
                            streamFormatVersion: 1,
                            artifactFilename: packURL.lastPathComponent,
                            accessPointSSID: transferSession.accessPointSSID,
                            tlsCertificateSHA256:
                                transferSession.tlsCertificateSHA256,
                            operationLeaseID: transferSession.operationLeaseID,
                            deviceID: deviceOperation?.deviceID,
                            operationID: deviceOperation?.usesDurableProtocol == true ? deviceOperation?.operationID : nil,
                            uploadAttemptID: UUID(),
                            appNamespace: deviceOperation?.appNamespace,
                            connectionEpoch: originalEpoch,
                            operationAdmissionRevision: deviceOperation?.admissionRevision,
                            operationAdmissionEpoch: deviceOperation?.admissionEpoch
                        ),
                        onTaskStarted: { taskID in
                            guard originalDeviceID == bleManager.activeDeviceID,
                                  originalEpoch == bleManager.transferConnectionEpoch,
                                  self.currentDeviceMapOperation?.operationID == uploadOperationID else { return }
                            self.recordBackgroundUploadTask(
                                taskID,
                                mapID: expectedMapId
                            )
                        }
                    ) { completedBytes, totalBytes in
                        guard originalDeviceID == bleManager.activeDeviceID,
                              originalEpoch == bleManager.transferConnectionEpoch,
                              self.currentDeviceMapOperation?.operationID == uploadOperationID else { return }
                        self.transferProgress = totalBytes == 0 ? 0 :
                            Double(completedBytes) / Double(totalBytes)
                        let percent = MapUploadProgressReconciler.percentage(
                            retryTransportPercentage:
                                Int((self.transferProgress * 100).rounded()),
                            durableDevicePercentage: retryProgressFloor
                        ) ?? 0
                        self.activationProgress = MapActivationProgressPresentation(
                            step: 1,
                            stepCount: 3,
                            percentage: percent
                        )
                    }
                } catch {
                    guard self.currentDeviceMapOperation?.cancellationRequestedAt != nil else { throw error }
                    // Intent is durable; query/cancel even when stopping the OS
                    // upload surfaced transport cancellation instead of a receipt.
                }
                guard originalDeviceID == bleManager.activeDeviceID,
                      originalEpoch == bleManager.transferConnectionEpoch,
                              bleManager.isCurrentMapTransferHTTPStatusContext(httpContext) else { throw CancellationError() }
                transferProgress = 1
                try await confirmStreamActivation(
                    expectedMapID: expectedMapId,
                    sessionID: sessionId,
                    initialDeviceStatus: initialDeviceStatus,
                    client: client,
                    bleManager: bleManager,
                    artifactURL: packURL
                )
                bleManager.requestMapTransferStatus()
            }
        } catch {
            let durablePending = currentDeviceMapOperation.map {
                $0.mapID == expectedMapId && $0.sessionID == sessionId && $0.usesDurableProtocol &&
                    !$0.isTerminal && !$0.isRetiredUnknown
            } ?? false
            let outcome = durablePending ? "unconfirmed" : MapTransferOutcomePolicy.outcome(
                after: error,
                activationMayBeInFlight: activationMayBeInFlight
            )
            updateLastTransferOutcome(outcome)
            if outcome == "unconfirmed" {
                let uploadSucceeded = BackgroundMapUploadStateStore.latest(
                    mapID: expectedMapId,
                    sessionID: sessionId,
                    defaults: defaults
                )?.succeeded == true
                statusMessage = currentDeviceMapOperation?.cancellationRequestedAt != nil
                    ? "Cancellation requested. Waiting for the device's saved result."
                    : (uploadSucceeded ? "Activation confirmation delayed. Reconnecting to device…"
                       : "Map upload paused. Tap Upload to resume.")
                errorMessage = nil
                startActivationReconciliationMonitor(bleManager: bleManager)
                return
            }
            throw error
        }
    }

    private func retainExistingStreamAttempt(
        mapID: String,
        sessionID: String,
        artifactURL: URL,
        activeMapID: String?,
        activeSessionID: String?,
        activationStatus: String?,
        activationSequence: UInt32?,
        activationSessionID: String?,
        activationStep: Int?,
        activationStepCount: Int?,
        activationProgress: Int?,
        bleManager: BLEManager,
        bindsOriginalObservation: Bool = false
    ) {
        let disposition = ExistingMapStreamAttemptDisposition.evaluate(
            expectedSessionID: sessionID,
            activeSessionID: activeSessionID,
            activationStatus: activationStatus,
            activationSessionID: activationSessionID,
            bindsOriginalObservation: bindsOriginalObservation
        )
        recordTransfer(
            mapId: mapID,
            sessionId: sessionID,
            previousMapId: activeMapID,
            previousSessionId: activeSessionID,
            previousSequence: activationSequence,
            outcome: disposition == .installed ? "installed" : "unconfirmed",
            connectionEpoch: bindsOriginalObservation ? bleManager.transferConnectionEpoch : nil,
            protocolVersion: 2,
            streamFormatVersion: 1,
            artifactURL: artifactURL
        )
        updateSavedMapDeviceState(
            mapID: mapID,
            sequence: activationSequence,
            state: activationStatus ?? "receiving",
            step: activationStep,
            stepCount: activationStepCount,
            progress: activationProgress
        )
        updateActivationProgress(
            status: activationStatus ?? "receiving",
            step: activationStep,
            stepCount: activationStepCount,
            percentage: activationProgress
        )
        if let activationSequence {
            defaults.set(
                Int(activationSequence),
                forKey: OfflineMapDefaults.lastTransferAcceptedSequenceKey
            )
        }
        switch disposition {
        case .installed:
            transferProgress = 1
            statusMessage = "map installed: \(displayName(forMapId: mapID))"
        case .awaitDevice:
            statusMessage = activationStatus == "receiving"
                ? "Map upload continues on device"
                : "Activation continues on device"
            startActivationReconciliationMonitor(bleManager: bleManager)
        case .upload:
            break
        }
    }

    private func confirmStreamActivation(
        expectedMapID: String,
        sessionID: String,
        initialDeviceStatus: MapTransferDeviceStatus,
        client: MapTransferDeviceClient,
        bleManager: BLEManager,
        artifactURL: URL
    ) async throws {
        if let record = currentDeviceMapOperation, record.usesDurableProtocol,
           record.mapID == expectedMapID, record.sessionID == sessionID {
            try await finishActivationConfirmation(expectedMapID: expectedMapID, sessionID: sessionID,
                previousMapID: nil, previousSessionID: nil, previousSequence: nil, acceptedSequence: nil,
                client: client, bleManager: bleManager)
            return
        }
        guard let httpContext = bleManager.captureMapTransferHTTPStatusContext() else { throw CancellationError() }
        let statusAfterUpload = try? await client.status()
        guard bleManager.isCurrentMapTransferHTTPStatusContext(httpContext) else { throw CancellationError() }
        if let statusAfterUpload {
            guard bleManager.applyAuthenticatedMapTransferStatus(statusAfterUpload, context: httpContext) else {
                throw CancellationError()
            }
        }
        let previousMapID = initialDeviceStatus.activeMapId ?? bleManager.mapTransferActiveMapId
        let previousSessionID = initialDeviceStatus.activeSessionId ??
            bleManager.mapTransferActiveSessionId
        let previousSequence = initialDeviceStatus.activation?.sequence ??
            bleManager.mapTransferActivationSequence
        let acceptedSequence = statusAfterUpload?.activation?.sessionId == sessionID
            ? statusAfterUpload?.activation?.sequence
            : nil
        recordTransfer(
            mapId: expectedMapID,
            sessionId: sessionID,
            previousMapId: previousMapID,
            previousSessionId: previousSessionID,
            previousSequence: previousSequence,
            outcome: "activating",
            connectionEpoch: bleManager.transferConnectionEpoch,
            protocolVersion: 2,
            streamFormatVersion: 1,
            artifactURL: artifactURL
        )
        if let acceptedSequence {
            defaults.set(
                Int(acceptedSequence),
                forKey: OfflineMapDefaults.lastTransferAcceptedSequenceKey
            )
        }
        bleManager.resetMapTransferActivationObservation()
        try await finishActivationConfirmation(
            expectedMapID: expectedMapID,
            sessionID: sessionID,
            previousMapID: previousMapID,
            previousSessionID: previousSessionID,
            previousSequence: previousSequence,
            acceptedSequence: acceptedSequence,
            client: client,
            bleManager: bleManager
        )
    }

    private func finishActivationConfirmation(
        expectedMapID: String,
        sessionID: String,
        previousMapID: String?,
        previousSessionID: String?,
        previousSequence: UInt32?,
        acceptedSequence: UInt32?,
        client: MapTransferDeviceClient,
        bleManager: BLEManager
    ) async throws {
        let confirmation = try await confirmActivatedMap(
            expectedMapId: expectedMapID,
            sessionId: sessionID,
            previousMapId: previousMapID,
            previousSessionId: previousSessionID,
            previousSequence: previousSequence,
            acceptedSequence: acceptedSequence,
            client: client,
            bleManager: bleManager
        )
        transferProgress = 1
        switch confirmation {
        case .retiredUnknown:
            updateLastTransferOutcome("unknown")
            statusMessage = "The previous map result is unknown. Send the map again to verify installation."
            errorMessage = nil
        case .cancelled:
            updateLastTransferOutcome("cancelled")
            statusMessage = "Map upload cancelled before installation"
            errorMessage = nil
        case .installed:
            statusMessage = "map installed: \(displayName(forMapId: expectedMapID))"
            updateLastTransferOutcome("installed")
        case .continuesOnDevice:
            if currentDeviceMapOperation?.lastReceipt?.phase == "accepted" {
                statusMessage = "Device accepted this map. Waiting for installation to finish."
            } else if currentDeviceMapOperation?.cancellationRequestedAt != nil {
                statusMessage = "Cancellation requested. Waiting for the device's saved result."
            } else {
                statusMessage = "Activation continues on device"
            }
            updateLastTransferOutcome("unconfirmed")
            startActivationReconciliationMonitor(bleManager: bleManager)
        }
    }

    private func withBackgroundTransferLifecycle<T>(
        bleManager: BLEManager,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            let value = try await operation()
            await cleanupTerminalMapOperationIfNeeded(bleManager: bleManager)
            return value
        } catch {
            await cleanupTerminalMapOperationIfNeeded(bleManager: bleManager)
            throw error
        }
    }

    private func cleanupTerminalMapOperationIfNeeded(bleManager: BLEManager) async {
        let record = currentDeviceMapOperation
        if defaults.string(forKey: "offlineMap.deviceOperationID") != nil, record == nil {
            return // A missing/corrupt journal is unresolved ownership, not legacy cleanup.
        }
        if let record, record.usesDurableProtocol, !record.isTerminal, !record.isRetiredUnknown { return }
        if await deviceTransferManager.exitMapTransfer(bleManager: bleManager), let record {
            try? self.deviceMapOperationStore.markCleanupComplete(operationID: record.operationID)
        }
    }

    private func retireUnavailablePrecommitIfFenced(
        _ unavailable: DeviceMapOperationReceipt, operation: DeviceMapOperationRecord,
        client: MapTransferDeviceClient, bleManager: BLEManager,
        context: MapTransferHTTPStatusContext
    ) async throws -> Bool {
        guard operation.commitRequestedAt == nil, operation.cancellationRequestedAt != nil,
              operation.lastReceipt?.phase != "accepted", !operation.isTerminal,
              operation.fencedRetirement == nil,
              bleManager.isCurrentMapTransferHTTPStatusContext(context) else { return false }
        let admission = try await client.operationAdmission()
        try Task.checkCancellation()
        guard bleManager.isCurrentMapTransferHTTPStatusContext(context),
              let current = currentDeviceMapOperation, current.operationID == operation.operationID,
              current.appNamespace == BackgroundMapUploadSessionNamespace.identifier(
                bundleIdentifier: Bundle.main.bundleIdentifier),
              current.originalUploadIsFenced(unavailable: unavailable, admission: admission) else { return false }
#if os(iOS)
        _ = await BackgroundMapUploadCoordinator.shared.retireActiveUpload(
            mapID: current.mapID, sessionID: current.sessionID,
            deviceID: current.deviceID, operationID: current.operationID)
        let uploads = await BackgroundMapUploadCoordinator.shared.activeUploadActivity()
        guard !uploads.hasActiveTask else { return false }
#else
        guard !hasActiveBackgroundUpload else { return false }
#endif
        guard bleManager.isCurrentMapTransferHTTPStatusContext(context),
              let beforeCleanup = currentDeviceMapOperation,
              beforeCleanup.operationID == current.operationID,
              beforeCleanup.permitsFencedRetirement(unavailable: unavailable, admission: admission) else { return false }
        let cleanupRevision = bleManager.deviceTransferStatusRevision
        let cleared: Bool
#if HOST_TESTING
        if let cleanup = fencedRetirementCleanupForTesting {
            cleared = await cleanup(bleManager)
        } else {
            cleared = await deviceTransferManager.exitMapTransfer(bleManager: bleManager)
        }
#else
        cleared = await deviceTransferManager.exitMapTransfer(bleManager: bleManager)
#endif
        guard cleared, bleManager.isConnected, bleManager.isNavigationReady,
              bleManager.activeDeviceID == current.deviceID,
              bleManager.connectedDeviceID == current.deviceID,
              bleManager.transferConnectionEpoch == context.connectionEpoch,
              bleManager.deviceTransferStatusRevision > cleanupRevision,
              bleManager.deviceTransferMode.isEmpty,
              bleManager.deviceTransferSessionToken?.isEmpty != false else { return false }
        let proof = DeviceMapFencedRetirement(unavailable: unavailable, admission: admission,
            connectionEpoch: context.connectionEpoch,
            observationProcessID: DeviceMapOperationStore.observationProcessID,
            cleanupRevisionBefore: cleanupRevision,
            cleanupRevisionAfter: bleManager.deviceTransferStatusRevision, observedAt: Date())
        _ = try deviceMapOperationStore.retireFencedPrecommit(operationID: current.operationID,
            deviceID: current.deviceID, appNamespace: current.appNamespace, proof: proof)
        return true
    }

    func confirmActivatedMap(expectedMapId: String,
                             sessionId: String,
                             previousMapId: String?,
                             previousSessionId: String?,
                             previousSequence: UInt32?,
                             acceptedSequence: UInt32?,
                             client: MapTransferDeviceClient,
                             bleManager: BLEManager,
                             timeout: TimeInterval = OfflineMapDefaults.activationConfirmationTimeout,
                             pollIntervalNanoseconds: UInt64 = OfflineMapDefaults.activationPollIntervalNanoseconds,
                             now: () -> Date = Date.init,
                             sleep: (UInt64) async throws -> Void = {
                                 try await Task.sleep(nanoseconds: $0)
                             }) async throws -> MapActivationConfirmationResult {
        let startedAt = now()
        var deadline = startedAt.addingTimeInterval(timeout)
        var lastObservedState = "activation request accepted"
        var observedCurrentAttempt = false
        var lastProgress: MapActivationProgressPresentation?

        let confirmationDeviceID = bleManager.activeDeviceID
        let confirmationEpoch = bleManager.transferConnectionEpoch
        let confirmationHTTPContext = bleManager.captureMapTransferHTTPStatusContext()
        var consumedOperationObservation = bleManager.mapOperationObservationGeneration
        while now() < deadline {
            if defaults.string(forKey: "offlineMap.deviceOperationID") != nil,
               currentDeviceMapOperation == nil {
                return .continuesOnDevice(lastState: "saved operation journal requires recovery")
            }
            guard confirmationDeviceID == bleManager.activeDeviceID else { return .continuesOnDevice(lastState: "device connection changed; exact result remains unconfirmed") }
            if let operation = currentDeviceMapOperation, operation.usesDurableProtocol,
               operation.mapID == expectedMapId && operation.sessionID == sessionId {
                guard operation.deviceID == confirmationDeviceID else {
                    return .continuesOnDevice(lastState: "reconnect the original device")
                }
                if operation.isRetiredUnknown { return .retiredUnknown }
                if operation.observation == "installed_confirmed", operation.lastReceipt?.phase == "installed" {
                    if bleManager.isCurrentMapTransferHTTPStatusContext(confirmationHTTPContext) {
                        await acknowledgeDurableResult(operation, client: client)
                    }
                    guard confirmationDeviceID == bleManager.activeDeviceID else {
                        return .continuesOnDevice(lastState: "device connection changed")
                    }
                    return .installed
                }
                if operation.isTerminal {
                    if bleManager.isCurrentMapTransferHTTPStatusContext(confirmationHTTPContext) {
                        await acknowledgeDurableResult(operation, client: client)
                    }
                    if operation.observation == "cancelled_before_commit" { return .cancelled }
                    throw OfflineMapPlatformError.mapActivationFailed(operation.lastReceipt?.phase ?? "failed")
                }
                var receipt: DeviceMapOperationReceipt?
                var receivedHTTPReceipt = false
                if bleManager.isCurrentMapTransferHTTPStatusContext(confirmationHTTPContext) {
                    receipt = try? await client.operationStatus(operationID: operation.wireOperationID)
                    if !bleManager.isCurrentMapTransferHTTPStatusContext(confirmationHTTPContext) { receipt = nil }
                    receivedHTTPReceipt = receipt != nil
                }
                guard confirmationDeviceID == bleManager.activeDeviceID else { return .continuesOnDevice(lastState: "device connection changed; exact result remains unconfirmed") }
                if receipt == nil {
                    if bleManager.mapOperationConnectionEpoch == bleManager.transferConnectionEpoch,
                       bleManager.mapOperationObservationGeneration != consumedOperationObservation {
                        receipt = bleManager.mapOperationStatus
                        consumedOperationObservation = bleManager.mapOperationObservationGeneration
                    }
                    _ = bleManager.requestMapOperationStatus(operationID: operation.wireOperationID)
                }
                var observedRecord: DeviceMapOperationRecord?
                if receivedHTTPReceipt, let receipt, receipt.status == "result_unavailable",
                   let context = confirmationHTTPContext,
                   try await retireUnavailablePrecommitIfFenced(receipt, operation: operation,
                       client: client, bleManager: bleManager, context: context) {
                    return .retiredUnknown
                }
                if let receipt {
                    observedRecord = try recordDeviceOperationReceipt(receipt, bleManager: bleManager)
                }
                // A cancellation carries its complete saved identity and original
                // admission, so even a pre-manifest upload can be tombstoned.
                if observedRecord == nil, currentDeviceMapOperation?.nextControlAction == .cancel {
                    observedRecord = currentDeviceMapOperation
                }
                if var record = observedRecord {
                    if (record.nextControlAction == .commit || record.nextControlAction == .cancel),
                       bleManager.isCurrentMapTransferHTTPStatusContext(confirmationHTTPContext),
                       let controlled = try await advanceDurableMapControl(record, client: client,
                            bleManager: bleManager, connectionEpoch: confirmationEpoch) {
                        record = controlled
                    }
                    if record.isTerminal, bleManager.isCurrentMapTransferHTTPStatusContext(confirmationHTTPContext) {
                        await acknowledgeDurableResult(record, client: client)
                    }
                    guard confirmationDeviceID == bleManager.activeDeviceID else {
                        return .continuesOnDevice(lastState: "device connection changed; exact result remains unconfirmed")
                    }
                    switch record.observation {
                    case "installed_confirmed": return .installed
                    case "cancelled_before_commit": return .cancelled
                    case "failed_or_rolled_back":
                        throw OfflineMapPlatformError.mapActivationFailed(record.lastReceipt?.phase ?? "failed")
                    default: break
                    }
                }
                try await sleep(pollIntervalNanoseconds)
                continue
            }
            if let operation = currentDeviceMapOperation, !operation.usesDurableProtocol,
               operation.connectionEpoch != confirmationEpoch ||
                operation.observationProcessID != DeviceMapOperationStore.observationProcessID {
                return .continuesOnDevice(lastState: "legacy operation requires fresh recovery evidence")
            }
            guard confirmationEpoch == bleManager.transferConnectionEpoch else { return .continuesOnDevice(lastState: "device connection changed; exact result remains unconfirmed") }
            var receivedHTTPStatus = false
            do {
                let status = try await client.status()
                guard confirmationDeviceID == bleManager.activeDeviceID,
                      confirmationEpoch == bleManager.transferConnectionEpoch else { return .continuesOnDevice(lastState: "device connection changed; exact result remains unconfirmed") }
                receivedHTTPStatus = true
                guard let confirmationHTTPContext,
                      bleManager.applyAuthenticatedMapTransferStatus(status, context: confirmationHTTPContext) else {
                    return .continuesOnDevice(lastState: "authenticated transfer session changed")
                }
                let activation = status.activation
                updateActivationProgress(
                    status: activation?.status,
                    step: activation?.step,
                    stepCount: activation?.steps,
                    percentage: activation?.progress
                )
                updateSavedMapDeviceState(
                    mapID: expectedMapId,
                    sequence: activation?.sequence,
                    state: activation?.status ?? "idle",
                    step: activation?.step,
                    stepCount: activation?.steps,
                    progress: activation?.progress
                )
                if let activationProgress,
                   activationProgress != lastProgress {
                    lastProgress = activationProgress
                    deadline = now().addingTimeInterval(timeout)
                }
                let evaluation = MapActivationReconciler.evaluate(
                    expectedMapId: expectedMapId,
                    sessionId: sessionId,
                    previousMapId: previousMapId,
                    previousSessionId: previousSessionId,
                    previousSequence: previousSequence,
                    acceptedSequence: acceptedSequence,
                    observedCurrentAttempt: observedCurrentAttempt,
                    activeMapId: status.activeMapId,
                    activeSessionId: status.activeSessionId,
                    activationStatus: activation?.status,
                    activationSequence: activation?.sequence,
                    activationSessionId: activation?.sessionId,
                    activationMapId: activation?.mapId,
                    activationError: activation?.error?.message ?? activation?.error?.code
                )
                observedCurrentAttempt = evaluation.observedCurrentAttempt
                switch evaluation.decision {
                case .installed:
                    recordLegacyTerminalProof("installed_confirmed", mapID: expectedMapId, sessionID: sessionId, bleManager: bleManager)
                    return .installed
                case .failed(let message):
                    recordLegacyTerminalProof("failed_or_rolled_back", mapID: expectedMapId, sessionID: sessionId, bleManager: bleManager)
                    throw OfflineMapPlatformError.mapActivationFailed(message)
                case .pending(let state):
                    lastObservedState = state
                }
            } catch let error as OfflineMapPlatformError {
                if case .mapActivationFailed = error {
                    throw error
                }
                receivedHTTPStatus = false
                lastObservedState = "device Wi-Fi status unavailable: \(error.localizedDescription)"
            } catch {
                receivedHTTPStatus = false
                lastObservedState = "device Wi-Fi status unavailable"
            }

            if !receivedHTTPStatus {
                bleManager.requestMapTransferStatus()
                updateActivationProgress(
                    status: bleManager.mapTransferActivationStatus,
                    step: bleManager.mapTransferActivationStep,
                    stepCount: bleManager.mapTransferActivationStepCount,
                    percentage: bleManager.mapTransferActivationProgress
                )
                updateSavedMapDeviceState(
                    mapID: expectedMapId,
                    sequence: bleManager.mapTransferActivationSequence,
                    state: bleManager.mapTransferActivationStatus,
                    step: bleManager.mapTransferActivationStep,
                    stepCount: bleManager.mapTransferActivationStepCount,
                    progress: bleManager.mapTransferActivationProgress
                )
                if let activationProgress,
                   activationProgress != lastProgress {
                    lastProgress = activationProgress
                    deadline = now().addingTimeInterval(timeout)
                }
                let evaluation = MapActivationReconciler.evaluate(
                    expectedMapId: expectedMapId,
                    sessionId: sessionId,
                    previousMapId: previousMapId,
                    previousSessionId: previousSessionId,
                    previousSequence: previousSequence,
                    acceptedSequence: acceptedSequence,
                    observedCurrentAttempt: observedCurrentAttempt,
                    activeMapId: bleManager.mapTransferActiveMapId,
                    activeSessionId: bleManager.mapTransferActiveSessionId,
                    activationStatus: bleManager.mapTransferActivationStatus,
                    activationSequence: bleManager.mapTransferActivationSequence,
                    activationSessionId: bleManager.hasFreshMapTransferStatus
                        ? bleManager.mapTransferActivationSessionId : nil,
                    activationMapId: bleManager.mapTransferActivationMapId,
                    activationError: bleManager.mapTransferActivationError ??
                        bleManager.mapTransferLastError
                )
                observedCurrentAttempt = evaluation.observedCurrentAttempt
                switch evaluation.decision {
                case .installed:
                    recordLegacyTerminalProof("installed_confirmed", mapID: expectedMapId, sessionID: sessionId, bleManager: bleManager)
                    return .installed
                case .failed(let message):
                    recordLegacyTerminalProof("failed_or_rolled_back", mapID: expectedMapId, sessionID: sessionId, bleManager: bleManager)
                    throw OfflineMapPlatformError.mapActivationFailed(message)
                case .pending(let state):
                    lastObservedState = state
                }
            }

            statusMessage = activationProgress?.label ??
                "activating \(displayName(forMapId: expectedMapId))"
            try await sleep(pollIntervalNanoseconds)
        }

        return .continuesOnDevice(
            lastState: lastObservedState
        )
    }

    private func updateActivationProgress(
        status: String?,
        step: Int?,
        stepCount: Int?,
        percentage: Int?
    ) {
        activationProgress = MapActivationProgressPresentation.make(
            status: status,
            step: step,
            stepCount: stepCount,
            percentage: percentage
        )
    }

    private func restoreLastTransferPresentation() {
        guard lastTransferOutcome == "unconfirmed",
              !lastTransferMapId.isEmpty,
              let url = lastTransferArtifactURL(mapID: lastTransferMapId),
              let metadata = SavedMapArtifactMetadataStore.load(for: url) else {
            return
        }
        if let operation = currentDeviceMapOperation, operation.usesDurableProtocol {
            if operation.lastReceipt?.phase == "accepted" {
                activationProgress = nil
                statusMessage = "Device accepted this map. Waiting for installation to finish."
                return
            }
            if operation.cancellationRequestedAt != nil {
                activationProgress = nil
                statusMessage = "Cancellation requested. Waiting for the device's saved result."
                return
            }
            if operation.lastReceipt?.phase == "prepared" {
                activationProgress = nil
                statusMessage = "Map prepared. Waiting to confirm installation."
                return
            }
        }
        updateActivationProgress(
            status: metadata.lastDeviceState,
            step: metadata.lastDeviceStep,
            stepCount: metadata.lastDeviceStepCount,
            percentage: metadata.lastDeviceProgress
        )
        let sessionID = defaults.string(
            forKey: OfflineMapDefaults.lastTransferSessionIdKey
        ) ?? ""
        if metadata.lastDeviceStep ?? 0 <= 1,
           let upload = BackgroundMapUploadStateStore.latest(
               mapID: lastTransferMapId,
               sessionID: sessionID,
               defaults: defaults
           ),
           currentDeviceMapOperation?.usesDurableProtocol != true ||
                upload.descriptor.operationID == currentDeviceMapOperation?.operationID,
           let percentage = MapUploadProgressReconciler.percentage(
               retryTransportPercentage: upload.percentage,
               durableDevicePercentage: metadata.lastDeviceProgress
           ) {
            activationProgress = MapActivationProgressPresentation(
                step: 1,
                stepCount: 3,
                percentage: percentage
            )
            if upload.completedAt == nil {
                statusMessage = "Map upload continues on device"
            } else if upload.succeeded == true {
                statusMessage = "Activation continues on device"
            } else {
                statusMessage = "Map upload paused. Tap Upload to resume."
            }
            return
        }
        switch metadata.lastDeviceState {
        case "receiving":
            statusMessage = "Map upload continues on device"
        case "paused":
            statusMessage = "Map upload paused. Tap Upload to resume."
        case "finalizing", "ready", "activating":
            statusMessage = "Activation continues on device"
        case "failed":
            statusMessage = "Map installation needs attention"
        default:
            statusMessage = "Checking device map transfer"
        }
    }

    private func refreshBackgroundUploadActivity() {
#if os(iOS)
        Task { @MainActor [weak self] in
            let active = await BackgroundMapUploadCoordinator.shared
                .activeUploadActivity()
            self?.hasActiveBackgroundUpload = active.hasActiveTask
        }
#endif
    }

    private func startActivationReconciliationMonitor(bleManager: BLEManager) {
        guard activationReconciliationTask == nil,
              lastTransferOutcome == "unconfirmed" else {
            return
        }
        activationReconciliationTask = Task { @MainActor [weak self, weak bleManager] in
            while !Task.isCancelled,
                  let self,
                  let bleManager,
                  self.lastTransferOutcome == "unconfirmed" {
                if bleManager.isNavigationReady {
                    bleManager.requestMapTransferStatus()
                    self.reconcileLastTransfer(bleManager: bleManager)
                }
                try? await Task.sleep(
                    nanoseconds: OfflineMapDefaults.activationPollIntervalNanoseconds
                )
            }
            self?.activationReconciliationTask = nil
        }
    }

    private func recordTransfer(mapId: String,
                                sessionId: String,
                                previousMapId: String?,
                                previousSessionId: String?,
                                previousSequence: UInt32?,
                                outcome: String,
                                connectionEpoch: UInt64?,
                                protocolVersion: Int = 1,
                                streamFormatVersion: Int? = nil,
                                artifactURL: URL? = nil,
                                updateOperationRecord: Bool = true) {
        lastTransferObservedIdleOnAnotherMap = false
        lastTransferConnectionEpoch = connectionEpoch
        lastTransferMapId = mapId
        defaults.set(mapId, forKey: OfflineMapDefaults.lastTransferMapIdKey)
        defaults.set(sessionId, forKey: OfflineMapDefaults.lastTransferSessionIdKey)
        defaults.set(previousMapId ?? "", forKey: OfflineMapDefaults.lastTransferPreviousMapIdKey)
        defaults.set(previousSessionId ?? "", forKey: OfflineMapDefaults.lastTransferPreviousSessionIdKey)
        defaults.set(protocolVersion, forKey: OfflineMapDefaults.lastTransferProtocolKey)
        if let streamFormatVersion {
            defaults.set(streamFormatVersion, forKey: OfflineMapDefaults.lastTransferStreamFormatKey)
        } else {
            defaults.removeObject(forKey: OfflineMapDefaults.lastTransferStreamFormatKey)
        }
        if let artifactURL {
            defaults.set(
                artifactURL.lastPathComponent,
                forKey: OfflineMapDefaults.lastTransferArtifactFilenameKey
            )
        }
        if outcome == "uploading" {
            defaults.removeObject(
                forKey: OfflineMapDefaults.lastTransferBackgroundTaskIDKey
            )
            clearSavedMapBackgroundTask(mapID: mapId)
        }
        defaults.removeObject(forKey: OfflineMapDefaults.lastTransferAcceptedSequenceKey)
        if let previousSequence {
            defaults.set(Int(previousSequence), forKey: OfflineMapDefaults.lastTransferPreviousSequenceKey)
        } else {
            defaults.removeObject(forKey: OfflineMapDefaults.lastTransferPreviousSequenceKey)
        }
        updateSavedMapTransferMetadata(
            mapID: mapId,
            protocolVersion: protocolVersion,
            streamFormatVersion: streamFormatVersion,
            sessionID: sessionId,
            outcome: outcome
        )
        updateLastTransferOutcome(outcome, updateOperationRecord: updateOperationRecord)
    }

    private func previousConfirmedSelection(bleManager: BLEManager) -> DeviceMapConfirmedSelectionSnapshot? {
        guard bleManager.isConnected, let deviceID = bleManager.activeDeviceID,
              bleManager.connectedDeviceID == deviceID,
              let selected = bleManager.activeDeviceMap else { return nil }
        let health = bleManager.mapSelectionHealth
        let confirmed: Bool
        if let health {
            confirmed = health.state == "ready" && health.mapID == selected.mapID &&
                health.sessionID == (selected.sessionID ?? "")
        } else {
            // Legacy firmware requires an exact terminal selection, never an
            // idle or pending pointer by itself.
            confirmed = bleManager.mapTransferActivationStatus == "installed" &&
                bleManager.mapTransferActivationMapId == selected.mapID &&
                selected.sessionID != nil &&
                bleManager.mapTransferActivationSessionId == selected.sessionID
        }
        let observation = DeviceMapConfirmedSelectionSnapshot(deviceID: deviceID,
            mapID: selected.mapID, sessionID: selected.sessionID,
            manifestReceipt: selected.manifestReceipt, root: health?.root,
            operationID: health.flatMap { $0.operationID.isEmpty ? nil : $0.operationID },
            healthBootID: health?.bootID, healthRevision: health?.revision,
            connectionEpoch: bleManager.transferConnectionEpoch,
            observationProcessID: DeviceMapOperationStore.observationProcessID, observedAt: Date())
        return DeviceMapConfirmedSelectionSnapshot.capture(observation,
            currentDeviceID: bleManager.connectedDeviceID, currentEpoch: bleManager.transferConnectionEpoch,
            currentProcessID: DeviceMapOperationStore.observationProcessID,
            hasFreshStatus: bleManager.hasFreshMapTransferStatus, isConfirmed: confirmed,
            isUnconfirmed: isUnconfirmedTransferIdentity(mapID: selected.mapID, sessionID: selected.sessionID))
    }

    private func recordLegacyTerminalProof(_ outcome: String, mapID: String, sessionID: String, bleManager: BLEManager) {
        guard bleManager.isConnected, let deviceID = bleManager.activeDeviceID,
              bleManager.connectedDeviceID == deviceID,
              var record = currentDeviceMapOperation, record.mapID == mapID, record.sessionID == sessionID,
              record.confirmLegacyTerminal(outcome: outcome, deviceID: deviceID,
                connectionEpoch: bleManager.transferConnectionEpoch,
                processID: DeviceMapOperationStore.observationProcessID) else { return }
        try? self.deviceMapOperationStore.save(record)
    }

    private func updateLastTransferOutcome(_ requestedOutcome: String, updateOperationRecord: Bool = true) {
        let outcome: String = {
            if defaults.string(forKey: "offlineMap.deviceOperationID") != nil,
               currentDeviceMapOperation == nil, ["installed", "failed"].contains(requestedOutcome) { return "unconfirmed" }
            guard let record = currentDeviceMapOperation, record.mapID == lastTransferMapId,
                  record.usesDurableProtocol else { return requestedOutcome }
            if record.isRetiredUnknown { return "unknown" }
            if requestedOutcome == "installed", record.observation != "installed_confirmed" { return "unconfirmed" }
            if requestedOutcome == "failed", !record.isTerminal { return "unconfirmed" }
            return requestedOutcome
        }()
        if updateOperationRecord, var record = currentDeviceMapOperation,
           record.mapID == lastTransferMapId, !record.isRetiredUnknown {
            if !record.usesDurableProtocol && ["installed", "failed"].contains(requestedOutcome) {
                record.observation = requestedOutcome == "installed" ? "installed_confirmed" : "failed_or_rolled_back"
            } else if requestedOutcome == "unconfirmed", !record.isTerminal, record.lastReceipt?.phase != "accepted" {
                record.observation = "result_unknown"
            }
            // Persistence failure cannot manufacture a successful durable result.
            try? self.deviceMapOperationStore.save(record)
        }
        let changed = lastTransferOutcome != outcome
        lastTransferOutcome = outcome
        defaults.set(outcome, forKey: OfflineMapDefaults.lastTransferOutcomeKey)
        if changed {
            diagnosticsRecorder?.record(
                category: .map,
                event: "transfer_outcome",
                fields: ["mapId": lastTransferMapId, "outcome": outcome]
            )
        }
        if outcome == "cancelled" || outcome == "unknown" || MapActivationProgressPresentation.shouldClear(
            forTransferOutcome: outcome
        ) {
            activationProgress = nil
        }
        if !lastTransferMapId.isEmpty {
            let protocolVersion = defaults.object(
                forKey: OfflineMapDefaults.lastTransferProtocolKey
            ) as? NSNumber
            let streamFormatVersion = defaults.object(
                forKey: OfflineMapDefaults.lastTransferStreamFormatKey
            ) as? NSNumber
            let sessionID = defaults.string(
                forKey: OfflineMapDefaults.lastTransferSessionIdKey
            )
            updateSavedMapTransferMetadata(
                mapID: lastTransferMapId,
                protocolVersion: protocolVersion?.intValue,
                streamFormatVersion: streamFormatVersion?.intValue,
                sessionID: sessionID,
                outcome: outcome
            )
        }
        if outcome != "unconfirmed" {
            lastTransferObservedIdleOnAnotherMap = false
            activationReconciliationTask?.cancel()
            activationReconciliationTask = nil
        }
    }

    private func invalidateLastTransferForDeletedArtifact() {
        activationReconciliationTask?.cancel()
        activationReconciliationTask = nil
        for key in [
            OfflineMapDefaults.lastTransferMapIdKey,
            OfflineMapDefaults.lastTransferSessionIdKey,
            OfflineMapDefaults.lastTransferPreviousMapIdKey,
            OfflineMapDefaults.lastTransferPreviousSessionIdKey,
            OfflineMapDefaults.lastTransferPreviousSequenceKey,
            OfflineMapDefaults.lastTransferAcceptedSequenceKey,
            OfflineMapDefaults.lastTransferOutcomeKey,
            OfflineMapDefaults.lastTransferProtocolKey,
            OfflineMapDefaults.lastTransferStreamFormatKey,
            OfflineMapDefaults.lastTransferArtifactFilenameKey,
            OfflineMapDefaults.lastTransferBackgroundTaskIDKey,
        ] {
            defaults.removeObject(forKey: key)
        }
        lastTransferMapId = ""
        lastTransferOutcome = ""
        lastTransferObservedIdleOnAnotherMap = false
        transferProgress = 0
        activationProgress = nil
        statusMessage = ""
    }

    func updateSavedMapTransferMetadata(
        mapID: String,
        protocolVersion: Int?,
        streamFormatVersion: Int?,
        sessionID: String?,
        outcome: String
    ) {
        for url in transferArtifactURLs(mapID: mapID) {
            guard var metadata = SavedMapArtifactMetadataStore.load(for: url) else { continue }
            let mergeIdentityChanged =
                metadata.lastTransferProtocol != protocolVersion ||
                metadata.lastTransferSessionID != sessionID ||
                metadata.expectedActiveMapID != mapID ||
                metadata.expectedActiveSessionID != sessionID
            metadata.lastTransferProtocol = protocolVersion
            metadata.lastTransferStreamFormat = streamFormatVersion
            metadata.lastTransferSessionID = sessionID
            metadata.expectedActiveMapID = mapID
            metadata.expectedActiveSessionID = sessionID
            metadata.lastTransferOutcome = outcome
            try? SavedMapArtifactMetadataStore.save(metadata, for: url)
            if mergeIdentityChanged {
                refreshCachedMapRecord(for: url)
            }
        }
    }

    func refreshCachedMapRecord(for packURL: URL) {
        guard let index = cachedMapRecords.firstIndex(where: {
            $0.packURL.standardizedFileURL == packURL.standardizedFileURL
        }) else {
            return
        }
        cachedMapRecords[index] = cachedMapRecord(for: packURL)
    }

    private func updateSavedMapDeviceState(
        mapID: String,
        sequence: UInt32?,
        state: String,
        step: Int?,
        stepCount: Int?,
        progress: Int?
    ) {
        for url in transferArtifactURLs(mapID: mapID) {
            guard var metadata = SavedMapArtifactMetadataStore.load(for: url) else { continue }
            if metadata.lastDeviceSequence == sequence,
               metadata.lastDeviceState == state,
               metadata.lastDeviceStep == step,
               metadata.lastDeviceStepCount == stepCount,
               metadata.lastDeviceProgress == progress {
                continue
            }
            metadata.lastDeviceSequence = sequence
            metadata.lastDeviceState = state
            metadata.lastDeviceStep = step
            metadata.lastDeviceStepCount = stepCount
            metadata.lastDeviceProgress = progress
            try? SavedMapArtifactMetadataStore.save(metadata, for: url)
        }
    }

    private func recordBackgroundUploadTask(_ taskID: Int, mapID: String) {
        defaults.set(taskID, forKey: OfflineMapDefaults.lastTransferBackgroundTaskIDKey)
        for url in transferArtifactURLs(mapID: mapID) {
            guard var metadata = SavedMapArtifactMetadataStore.load(for: url) else { continue }
            metadata.lastBackgroundTaskID = taskID
            try? SavedMapArtifactMetadataStore.save(metadata, for: url)
        }
    }

    private func clearSavedMapBackgroundTask(mapID: String) {
        for url in transferArtifactURLs(mapID: mapID) {
            guard var metadata = SavedMapArtifactMetadataStore.load(for: url) else { continue }
            metadata.lastBackgroundTaskID = nil
            try? SavedMapArtifactMetadataStore.save(metadata, for: url)
        }
    }

    private func displayNameForCurrentJob() -> String {
        SavedMapDisplayNamePolicy.resolve(
            artifactDisplayName: nil,
            sourceRegionName: currentJob?.sourceRegion?.name,
            mapID: currentJob?.mapId
        )
    }

    private func persistPackDisplayNames() {
        defaults.set(packDisplayNames, forKey: OfflineMapDefaults.packDisplayNamesKey)
    }

    private func topographyAssociationID(
        for metadata: SavedMapArtifactMetadata
    ) -> String? {
        if let mapEntryID = metadata.catalogMapEntryID,
           SavedTopographyCompanionStorage.filename(
            mapEntryID: mapEntryID
           ) != nil {
            return mapEntryID
        }
        guard let jobID = metadata.jobID else { return nil }
        let identifier = "job_v1_\(jobID)"
        return SavedTopographyCompanionStorage.filename(
            mapEntryID: identifier
        ) == nil ? nil : identifier
    }

    private func cachedTopographyCompanionURL(
        associationID: String
    ) throws -> URL {
        guard let filename = SavedTopographyCompanionStorage.filename(
            mapEntryID: associationID
        ) else {
            throw OfflineMapCatalogError.invalidResponse
        }
        return try cachedPackDirectory().appendingPathComponent(filename)
    }

    private func replaceTopographyCompanion(
        at temporaryURL: URL,
        destination: URL,
        association: SavedTopographyCompanionAssociation
    ) throws {
        let directory = destination.deletingLastPathComponent()
        var journal = try SavedTopographyCompanionReplacementJournal.begin(
            at: destination
        )
        let backup = journal.backup(in: directory)
        let associationURL = SavedTopographyCompanionStorage.associationURL(
            for: destination
        )
        let associationBackup = SavedTopographyCompanionStorage.associationURL(
            for: backup
        )
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: destination, to: backup)
                try SavedTopographyCompanionReplacementJournal.sync(directory)
            }
            if FileManager.default.fileExists(atPath: associationURL.path) {
                try FileManager.default.moveItem(
                    at: associationURL,
                    to: associationBackup
                )
                try SavedTopographyCompanionReplacementJournal.sync(directory)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            try SavedTopographyCompanionStorage.save(
                association,
                for: destination
            )
            try SavedTopographyCompanionReplacementJournal.sync(destination)
            try SavedTopographyCompanionReplacementJournal.sync(associationURL)
            try SavedTopographyCompanionReplacementJournal.sync(directory)
            journal.committed = true
            try journal.save(in: directory)
            try? journal.finish(in: directory)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? SavedTopographyCompanionReplacementJournal.recover(
                in: directory
            )
            throw error
        }
    }

    private func deleteTopographyCompanions(
        matching metadata: SavedMapArtifactMetadata?
    ) throws {
        guard let metadata,
              let directory = try? cachedPackDirectory() else { return }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for companionURL in files
        where companionURL.pathExtension.lowercased() == "btopo" {
            let associationURL = SavedTopographyCompanionStorage
                .associationURL(for: companionURL)
            guard let data = try? Data(contentsOf: associationURL),
                  let association = try? JSONDecoder().decode(
                    SavedTopographyCompanionAssociation.self,
                    from: data
                  ),
                  association.receipt.mapID == metadata.mapID,
                  association.streamArtifactSHA256 ==
                    metadata.primaryArtifact?.sha256 else {
                continue
            }
            try SavedTopographyCompanionStorage.delete(for: companionURL)
        }
    }

#if canImport(UIKit) && canImport(MapKit)
    private func reloadTopographyOverlay() {
        topographyOverlayGeneration = UUID()
        let generation = topographyOverlayGeneration
        topographyOverlayTask?.cancel()
        topographyOverlayTask = nil
        guard topographicMapsEnabled else {
            topographyOverlay = nil
            topographyOverlayStatus = "Topographic contours are turned off."
            return
        }
        guard let directory = try? cachedPackDirectory() else {
            topographyOverlay = nil
            topographyOverlayStatus = "Topographic map storage is unavailable."
            return
        }
        let preferredID = defaults.string(
            forKey: OfflineMapDefaults.activeTopographyAssociationKey
        )
        let candidates = cachedMapRecords.compactMap {
            record -> (
                String,
                URL,
                SavedTopographyCompanionAssociation
            )? in
            guard let metadata = SavedMapArtifactMetadataStore.load(
                for: record.packURL
            ),
            let associationID = topographyAssociationID(for: metadata),
            let contentReceipt = metadata.catalogContentReceipt,
            let streamSHA256 = metadata.primaryArtifact?.sha256,
            let filename = SavedTopographyCompanionStorage.filename(
                mapEntryID: associationID
            ) else { return nil }
            let companionURL = directory.appendingPathComponent(filename)
            guard let association = SavedTopographyCompanionStorage.load(
                for: companionURL,
                expectedMapEntryID: associationID,
                expectedMapContentReceipt: contentReceipt,
                expectedStreamArtifactSHA256: streamSHA256
            ) else { return nil }
            return (associationID, companionURL, association)
        }.sorted { lhs, rhs in
            if lhs.0 == preferredID { return true }
            if rhs.0 == preferredID { return false }
            return lhs.0 < rhs.0
        }
        guard let selected = candidates.first else {
            topographyOverlay = nil
            topographyOverlayStatus =
                "Download a topographic map to show offline contours."
            return
        }
        topographyOverlayStatus = "Verifying topographic contours…"
        topographyOverlayTask = Task { [weak self] in
            do {
                let overlay = try await BicinoTopographyTileOverlay.open(
                    url: selected.1,
                    receipt: selected.2.receipt
                )
                try Task.checkCancellation()
                guard let self,
                      self.topographyOverlayGeneration == generation else {
                    return
                }
                self.topographyOverlay = overlay
                self.topographyOverlayStatus =
                    "Offline contours are shown for the selected saved map."
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.topographyOverlayGeneration == generation else {
                    return
                }
                self.topographyOverlay = nil
                self.topographyOverlayStatus =
                    "The saved contour companion could not be verified."
            }
        }
    }
#endif

    private func cachedPackURL(mapId: String) throws -> URL {
        let bmap = try cachedPackURL(mapId: mapId, fileExtension: "bmap")
        if FileManager.default.fileExists(atPath: bmap.path) {
            return bmap
        }
        return try cachedPackURL(mapId: mapId, fileExtension: "zip")
    }

    private func cachedPackURL(mapId: String, fileExtension: String) throws -> URL {
        let directory = try cachedPackDirectory()
        return directory.appendingPathComponent("\(mapId).\(fileExtension)")
    }

    private func lastTransferArtifactURL(mapID: String) -> URL? {
        guard !mapID.isEmpty else { return nil }
        if let filename = defaults.string(
            forKey: OfflineMapDefaults.lastTransferArtifactFilenameKey
        ) {
            guard !filename.isEmpty,
                  URL(fileURLWithPath: filename).lastPathComponent == filename,
                  let directory = try? cachedPackDirectory() else {
                return nil
            }
            let candidate = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path),
               savedMapID(for: candidate) == mapID {
                return candidate
            }
            return nil
        }
        for fileExtension in ["bmap", "zip"] {
            guard let candidate = try? cachedPackURL(
                mapId: mapID,
                fileExtension: fileExtension
            ) else { continue }
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return cachedMapRecords.first(where: { $0.mapID == mapID })?.packURL
    }

    private func transferArtifactURLs(mapID: String) -> [URL] {
        if defaults.string(
            forKey: OfflineMapDefaults.lastTransferArtifactFilenameKey
        ) != nil {
            return lastTransferArtifactURL(mapID: mapID).map { [$0] } ?? []
        }
        if let exact = lastTransferArtifactURL(mapID: mapID) {
            return [exact]
        }
        return cachedMapRecords
            .filter { $0.mapID == mapID }
            .map(\.packURL)
    }

    private func cachedCatalogPackURL(
        mapEntryID: String,
        fileExtension: String
    ) throws -> URL {
        guard let filename = OfflineMapCatalogLocalArtifactPolicy.filename(
            mapEntryID: mapEntryID,
            fileExtension: fileExtension
        ) else {
            throw OfflineMapCatalogError.invalidResponse
        }
        return try cachedPackDirectory().appendingPathComponent(filename)
    }

    private func cachedPackDirectory() throws -> URL {
        if let cacheDirectoryOverride {
            try FileManager.default.createDirectory(
                at: cacheDirectoryOverride,
                withIntermediateDirectories: true
            )
            try SavedMapReplacementJournal.recover(in: cacheDirectoryOverride)
            try SavedTopographyCompanionReplacementJournal.recover(
                in: cacheDirectoryOverride
            )
            return cacheDirectoryOverride
        }
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("OfflineMapPacks", isDirectory: true)
        let legacy = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("OfflineMapPacks", isDirectory: true)
        let prepared = try SavedMapStorageDirectory.prepare(
            directory: directory,
            legacy: legacy
        )
        try SavedTopographyCompanionReplacementJournal.recover(in: prepared)
        return prepared
    }

    private func deleteCompatibilityArtifacts(mapID: String) throws {
        let directory = try cachedPackDirectory()
            .appendingPathComponent("Compatibility", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in files where url.pathExtension.lowercased() == "zip" {
            guard SavedMapArtifactMetadataStore.load(for: url)?.mapID == mapID else { continue }
            try FileManager.default.removeItem(at: url)
            try SavedMapArtifactMetadataStore.delete(for: url)
        }
    }

    private func refreshCachedPacks() {
        do {
            let directory = try cachedPackDirectory()
            let packURLs = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { ["bmap", "zip"].contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
#if canImport(UIKit)
            var activePreviewKeys = Set(packURLs.map(previewCacheKey))
            if let currentActiveDeviceMap {
                activePreviewKeys.insert(
                    devicePreviewCacheKey(for: currentActiveDeviceMap)
                )
            }
            for key in Array(packPreviewImages.keys) where !activePreviewKeys.contains(key) {
                packPreviewImages.removeValue(forKey: key)
            }
            for key in Array(detailPreviewImages.keys) where !activePreviewKeys.contains(key) {
                removeDetailPreviewImage(forKey: key)
            }
            for key in Array(previewLoadTasks.keys) where !activePreviewKeys.contains(key) {
                previewLoadTasks.removeValue(forKey: key)?.cancel()
                previewLoadRegistry.invalidate(key)
            }
            for key in detailPreviewLoadingKeys where !activePreviewKeys.contains(key) {
                detailPreviewLoadRegistry.invalidate(key)
            }
            detailPreviewLoadingKeys.formIntersection(activePreviewKeys)
            unavailablePackPreviews.formIntersection(activePreviewKeys)
            unavailableDetailPreviews.formIntersection(activePreviewKeys)
#endif
            cacheDefaultDisplayNames(for: packURLs)
            cachedMapRecords = packURLs.map(cachedMapRecord)
            cachedPackURLs = packURLs
#if canImport(UIKit) && canImport(MapKit)
            reloadTopographyOverlay()
#endif
        } catch {
#if canImport(UIKit)
            for task in previewLoadTasks.values {
                task.cancel()
            }
            previewLoadTasks.removeAll()
            previewLoadRegistry.removeAll()
            packPreviewImages.removeAll()
            detailPreviewLoadRegistry.removeAll()
            detailPreviewImages.removeAll()
            detailPreviewAccessOrder.removeAll()
            detailPreviewLoadingKeys.removeAll()
            unavailablePackPreviews.removeAll()
            unavailableDetailPreviews.removeAll()
#endif
            cachedPackURLs = []
            cachedMapRecords = []
#if canImport(UIKit) && canImport(MapKit)
            reloadTopographyOverlay()
#endif
        }
    }

#if canImport(UIKit)
    private func previewCacheKey(for packURL: URL) -> String {
        packURL.standardizedFileURL.path
    }

    private func devicePreviewCacheKey(
        for descriptor: DeviceActiveMapDescriptor
    ) -> String {
        "device:\(descriptor.previewFilename)"
    }

    private func invalidateCachedPreview(for packURL: URL) {
        let key = previewCacheKey(for: packURL)
        previewLoadRegistry.invalidate(key)
        previewLoadTasks.removeValue(forKey: key)?.cancel()
        packPreviewImages.removeValue(forKey: key)
        unavailablePackPreviews.remove(key)
        detailPreviewLoadRegistry.invalidate(key)
        removeDetailPreviewImage(forKey: key)
        detailPreviewLoadingKeys.remove(key)
        unavailableDetailPreviews.remove(key)
        try? SavedMapSnapshotPreviewStore.delete(for: packURL)
        try? SavedMapDetailPreviewStore.delete(for: packURL)
    }
#else
    private func invalidateCachedPreview(for packURL: URL) {}
#endif

    private func cacheDefaultDisplayNames(for packURLs: [URL]) {
        var didChange = false
        for packURL in packURLs {
            let metadata = SavedMapArtifactMetadataStore.load(for: packURL)
            let existing = packDisplayNames[packURL.lastPathComponent]
            if existing?.isEmpty != false,
               metadata?.userDefinedDisplayName == true,
               let userName = metadata?.displayName,
               !userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                packDisplayNames[packURL.lastPathComponent] = userName
                didChange = true
                continue
            }
            let needsDefault = existing?.isEmpty != false ||
                (metadata?.userDefinedDisplayName != true &&
                    SavedMapDisplayNamePolicy.isGeneratedGenericName(existing))
            guard needsDefault else { continue }
            guard let displayName = manifestDisplayName(for: packURL) else { continue }
            packDisplayNames[packURL.lastPathComponent] = displayName
            if var metadata, metadata.userDefinedDisplayName != true {
                metadata.displayName = displayName
                try? SavedMapArtifactMetadataStore.save(metadata, for: packURL)
            }
            didChange = true
        }
        if didChange {
            persistPackDisplayNames()
        }
    }

    private func manifestDisplayName(for packURL: URL) -> String? {
        if let displayName = SavedMapDisplayNamePolicy.preferred(
            SavedMapArtifactMetadataStore.load(for: packURL)?.displayName
        ) {
            return displayName
        }
        guard let manifest = OfflineMapPackPreviewReader.manifest(for: packURL) else {
            return nil
        }
        if let displayName = SavedMapDisplayNamePolicy.preferred(manifest.displayName) {
            return displayName
        }
        if let sourceName = SavedMapDisplayNamePolicy.preferred(manifest.source?.name) {
            return sourceName
        }
        let sourceCandidates = [
            manifest.source?.url.flatMap { URL(string: $0)?.lastPathComponent },
            manifest.source?.region
        ]
        for candidate in sourceCandidates {
            if let sourceName = SavedMapDisplayNamePolicy.preferredSourceName(candidate) {
                return sourceName
            }
        }
        return nil
    }

    private func savedMapID(for packURL: URL) -> String {
        SavedMapArtifactMetadataStore.load(for: packURL)?.mapID ??
            packURL.deletingPathExtension().lastPathComponent
    }

    private func cachedMapRecord(for packURL: URL) -> SavedMapLocalRecord {
        let mapID = savedMapID(for: packURL)
        return SavedMapLocalRecord(
            packURL: packURL,
            mapID: mapID,
            acceptedSessionIDs: acceptedActiveSessionIDs(
                for: packURL,
                mapID: mapID
            ),
            displayName: displayName(forCachedPack: packURL),
            catalogMapEntryID: SavedMapArtifactMetadataStore.load(
                for: packURL
            )?.catalogMapEntryID
        )
    }

    private func acceptedActiveSessionIDs(
        for packURL: URL,
        mapID: String
    ) -> Set<String> {
        if let metadata = SavedMapArtifactMetadataStore.load(for: packURL),
           metadata.primaryArtifact?.isBikeMapStream == true,
           let signedReceipt = metadata.primaryArtifact?.signedManifestReceipt,
           !signedReceipt.isEmpty {
            return Set([
                signedReceipt,
                metadata.expectedActiveSessionID,
                metadata.lastTransferSessionID,
            ].compactMap { value in
                value?.isEmpty == false ? value : nil
            })
        }
        guard let archive = try? OfflineMapPackArchive(url: packURL),
              let manifest = try? archive.manifest(),
              manifest.mapId == mapID,
              let manifestEntry = archive.manifestEntry,
              let manifestData = try? archive.data(for: manifestEntry) else {
            return []
        }
        return [MapTransferSessionIdentity.make(
            mapId: mapID,
            manifestData: manifestData
        )]
    }

    private func transferIdentity(for packURL: URL) throws -> (mapID: String, sessionID: String) {
        if let metadata = SavedMapArtifactMetadataStore.load(for: packURL),
           metadata.primaryArtifact?.isBikeMapStream == true,
           let signedReceipt = metadata.primaryArtifact?.signedManifestReceipt,
           !signedReceipt.isEmpty {
            if metadata.lastTransferProtocol == 1,
               let legacySessionID = metadata.expectedActiveSessionID,
               !legacySessionID.isEmpty {
                return (metadata.mapID, legacySessionID)
            }
            return (metadata.mapID, signedReceipt)
        }
        let archive = try OfflineMapPackArchive(url: packURL)
        guard let manifestEntry = archive.manifestEntry,
              let mapID = try archive.manifest().mapId,
              !mapID.isEmpty else {
            throw OfflineMapPlatformError.invalidPack("manifest.json has no mapId")
        }
        return (
            mapID,
            MapTransferSessionIdentity.make(
                mapId: mapID,
                manifestData: try archive.data(for: manifestEntry)
            )
        )
    }

    private func runBusy(_ operation: @MainActor @escaping () async throws -> Void) async {
        activityCounter.begin()
        isBusy = activityCounter.isBusy
        errorMessage = nil
        defer {
            activityCounter.end()
            isBusy = activityCounter.isBusy
        }
        do {
            try await operation()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = diagnosticMessage(for: error)
        }
    }

    private func diagnosticMessage(for error: Error) -> String {
        if error is OfflineMapPlatformError {
            return error.localizedDescription
        }

        let nsError = error as NSError
        var parts = [error.localizedDescription]
        if nsError.domain != NSCocoaErrorDomain || nsError.code != 0 {
            parts.append("\(nsError.domain) \(nsError.code)")
        }
        if let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            parts.append(failingURL.absoluteString)
        }
        return parts.joined(separator: "\n")
    }
}

struct OfflineMapByteProgress: Equatable {
    let completedBytes: Int64
    let totalBytes: Int64

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
    }

    var percentage: Int {
        Int((fraction * 100).rounded())
    }
}

nonisolated struct OfflineMapDownloadConstraints: Codable, Equatable {
    let exactBytes: Int64?
    let maximumBytes: Int64
    let allowedDownloadHosts: Set<String>?
    let artifactSHA256: String?

    init(
        exactBytes: Int64?,
        maximumBytes: Int64,
        allowedDownloadHosts: Set<String>? = nil,
        artifactSHA256: String? = nil
    ) {
        self.exactBytes = exactBytes
        self.maximumBytes = maximumBytes
        self.allowedDownloadHosts = allowedDownloadHosts
        self.artifactSHA256 = artifactSHA256
    }

    static let defaultMap = Self(
        exactBytes: nil,
        maximumBytes: BikeMapStreamFormat.maximumArtifactBytes,
        allowedDownloadHosts: nil
    )

    static func mapArtifact(_ artifact: OfflineMapArtifact?) throws -> Self {
        let exactBytes = artifact?.bytes
        if let exactBytes, exactBytes <= 0 {
            throw BikeMapStreamFormatError.invalidArtifactMetadata(
                "artifact byte count is invalid"
            )
        }
        let maximumBytes = BikeMapStreamFormat.maximumArtifactBytes
        if let exactBytes, exactBytes > maximumBytes {
            throw BikeMapStreamFormatError.invalidArtifactMetadata(
                "artifact exceeds the supported map size"
            )
        }
        return Self(
            exactBytes: exactBytes,
            maximumBytes: maximumBytes,
            allowedDownloadHosts: nil,
            artifactSHA256: artifact?.sha256
        )
    }

    static func catalogArtifact(
        _ artifact: OfflineMapArtifact,
        catalogHost: String,
        r2DownloadHost: String
    ) throws -> Self {
        let base = try mapArtifact(artifact)
        guard !catalogHost.isEmpty, !r2DownloadHost.isEmpty else {
            throw OfflineMapCatalogError.invalidConfiguration
        }
        return Self(
            exactBytes: base.exactBytes,
            maximumBytes: base.maximumBytes,
            allowedDownloadHosts: [catalogHost.lowercased(), r2DownloadHost.lowercased()],
            artifactSHA256: base.artifactSHA256
        )
    }

    static func topographyCompanion(
        _ artifact: OfflineMapArtifact,
        allowedDownloadHosts: Set<String>? = nil
    ) throws -> Self {
        guard artifact.isTopographyCompanion,
              artifact.mediaType ==
                OfflineMapTopographyCompanionPolicy.mediaType,
              artifact.filename.hasSuffix(".btopo"),
              (512...Int64(256 * 1024 * 1024)).contains(artifact.bytes),
              TopographyCompanionReceipt.isDigest(artifact.sha256),
              artifact.mapContentReceipt.map(
                TopographyCompanionReceipt.isDigest
              ) == true,
              artifact.intermediateSha256.map(
                TopographyCompanionReceipt.isDigest
              ) == true,
              artifact.sourcePolicySha256.map(
                TopographyCompanionReceipt.isDigest
              ) == true,
              artifact.attributionSha256.map(
                TopographyCompanionReceipt.isDigest
              ) == true else {
            throw OfflineMapCatalogError.invalidResponse
        }
        return Self(
            exactBytes: artifact.bytes,
            maximumBytes: 256 * 1024 * 1024,
            allowedDownloadHosts: allowedDownloadHosts,
            artifactSHA256: artifact.sha256
        )
    }
}

// One background session serves catalog and job downloads. Tasks are identified
// by immutable digest/length, not a short-lived grant URL. Completed bytes and
// opaque URLSession resume data remain private, excluded-from-backup app data.

final class OfflineMapPackDownloader: NSObject, URLSessionDownloadDelegate {
    private static let maximumErrorBodyBytes = 4 * 1024

    private let constraints: OfflineMapDownloadConstraints
    private let onProgress: @MainActor @Sendable (Double) -> Void
    private let onByteProgress: @MainActor @Sendable (OfflineMapByteProgress) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    private init(
        constraints: OfflineMapDownloadConstraints,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void,
        onByteProgress: @escaping @MainActor @Sendable (OfflineMapByteProgress) -> Void
    ) {
        self.constraints = constraints
        self.onProgress = onProgress
        self.onByteProgress = onByteProgress
    }

    static func download(
        from url: URL,
        constraints: OfflineMapDownloadConstraints = .defaultMap,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void,
        onByteProgress: @escaping @MainActor @Sendable (OfflineMapByteProgress) -> Void,
        configuration: URLSessionConfiguration = .default
    ) async throws -> URL {
        let downloader = OfflineMapPackDownloader(
            constraints: constraints,
            onProgress: onProgress,
            onByteProgress: onByteProgress
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.continuation = continuation
                configuration.timeoutIntervalForRequest = 120
                configuration.timeoutIntervalForResource = 60 * 60
                configuration.waitsForConnectivity = true
                let session = URLSession(configuration: configuration, delegate: downloader, delegateQueue: nil)
                downloader.session = session
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            downloader.session?.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if let exactBytes = constraints.exactBytes,
           totalBytesExpectedToWrite > 0,
           totalBytesExpectedToWrite != exactBytes {
            failDownload(
                downloadTask,
                error: BikeMapStreamFormatError.invalidArtifactMetadata(
                    "download content length does not match"
                )
            )
            return
        }
        let permittedBytes = constraints.exactBytes ?? constraints.maximumBytes
        guard totalBytesWritten <= permittedBytes else {
            failDownload(
                downloadTask,
                error: BikeMapStreamFormatError.invalidArtifactMetadata(
                    "download exceeds the declared map size"
                )
            )
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        let byteProgress = OfflineMapByteProgress(
            completedBytes: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite
        )
        Task { @MainActor [onProgress, onByteProgress] in
            onProgress(progress)
            onByteProgress(byteProgress)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let allowedHosts = constraints.allowedDownloadHosts else {
            completionHandler(request)
            return
        }
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.port == nil,
              let host = url.host?.lowercased(),
              allowedHosts.contains(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let allowedHosts = constraints.allowedDownloadHosts {
                guard let finalURL = downloadTask.response?.url,
                      finalURL.scheme?.lowercased() == "https",
                      finalURL.port == nil,
                      let finalHost = finalURL.host?.lowercased(),
                      allowedHosts.contains(finalHost) else {
                    throw OfflineMapCatalogError.invalidResponse
                }
            }
            let values = try location.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize else {
                throw BikeMapStreamFormatError.invalidArtifactMetadata(
                    "download size is unavailable"
                )
            }
            let downloadedBytes = Int64(fileSize)
            if let exactBytes = constraints.exactBytes {
                guard downloadedBytes == exactBytes else {
                    throw BikeMapStreamFormatError.invalidArtifactMetadata(
                        "download size does not match"
                    )
                }
            } else {
                guard downloadedBytes <= constraints.maximumBytes else {
                    throw BikeMapStreamFormatError.invalidArtifactMetadata(
                        "download exceeds the supported map size"
                    )
                }
            }
            try OfflineMapDownloadResponseValidator.validate(
                response: downloadTask.response,
                errorBody: Self.boundedErrorBody(at: location)
            )
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("zip")
            try FileManager.default.moveItem(at: location, to: temporaryURL)
            continuation?.resume(returning: temporaryURL)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    private func failDownload(_ task: URLSessionDownloadTask, error: Error) {
        guard continuation != nil else { return }
        task.cancel()
        continuation?.resume(throwing: error)
        continuation = nil
        session?.invalidateAndCancel()
    }

    private static func boundedErrorBody(at url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maximumErrorBodyBytes + 1)) ?? Data()
        let prefix = data.prefix(maximumErrorBodyBytes)
        let value = String(decoding: prefix, as: UTF8.self)
        return data.count > maximumErrorBodyBytes ? value + "\u{2026}" : value
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error, continuation != nil {
            continuation?.resume(throwing: error)
            continuation = nil
        }
        session.finishTasksAndInvalidate()
    }
}
