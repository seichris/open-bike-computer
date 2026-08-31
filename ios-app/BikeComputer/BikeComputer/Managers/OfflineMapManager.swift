//
//  OfflineMapManager.swift
//  BikeComputer
//
//  Coordinates offline map platform requests from the settings UI.
//

import CoreLocation
import Combine
import Foundation
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
        let previousMapId = previousMapId?.isEmpty == false ? previousMapId : nil
        let previousSessionId = previousSessionId?.isEmpty == false ? previousSessionId : nil
        let activeMapId = activeMapId?.isEmpty == false ? activeMapId : nil
        let activeSessionId = activeSessionId?.isEmpty == false ? activeSessionId : nil
        let sessionMatches = activationSessionId == sessionId
        let sequenceAdvanced: Bool
        if let previousSequence, let activationSequence {
            sequenceAdvanced = previousSequence != activationSequence
        } else {
            sequenceAdvanced = false
        }

        let acknowledgedSequenceMatches = acceptedSequence != nil &&
            activationSequence == acceptedSequence
        var observedCurrentAttempt = observedCurrentAttempt ||
            sequenceAdvanced || acknowledgedSequenceMatches
        if sessionMatches, activationStatus == "activating" {
            observedCurrentAttempt = true
        }

        if sessionMatches, observedCurrentAttempt {
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

        if activeMapId == expectedMapId,
           activeSessionId == sessionId,
           (!sessionMatches ||
            previousSessionId != sessionId) {
            return MapActivationEvaluation(
                decision: .installed,
                observedCurrentAttempt: observedCurrentAttempt
            )
        }

        if let previousMapId,
           activeMapId == expectedMapId,
           previousMapId != expectedMapId {
            return MapActivationEvaluation(
                decision: .installed,
                observedCurrentAttempt: observedCurrentAttempt
            )
        }

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
        activationSessionId: String
    ) -> CachedPackRecoveryDecision {
        if activeSessionId == expectedSessionId {
            return .installed
        }
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
        activationSessionID: String?
    ) -> Self {
        if activeSessionID == expectedSessionID {
            return .installed
        }
        guard activationSessionID == expectedSessionID else { return .upload }
        switch activationStatus {
        case "installed":
            return .installed
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
    case download
}

nonisolated enum OfflineMapOnboardingPresentation: Equatable {
    case hidden
    case step(OfflineMapOnboardingStep)
}

nonisolated enum OfflineMapOnboardingPolicy {
    static func presentation(
        hasCompletedFirstRun: Bool,
        confirmedDeviceMapMissing: Bool
    ) -> OfflineMapOnboardingPresentation {
        if !hasCompletedFirstRun {
            return .step(.welcome)
        }

        return confirmedDeviceMapMissing ? .step(.download) : .hidden
    }

    static func shouldOfferDownload(
        isLocationAuthorized: Bool,
        isNavigationReady: Bool,
        hasSDCard: Bool?,
        activeMapId: String,
        mapFoundForCurrentLocation: Bool?
    ) -> Bool {
        isLocationAuthorized &&
            isNavigationReady &&
            hasSDCard == true &&
            activeMapId.isEmpty &&
            mapFoundForCurrentLocation == false
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
}

nonisolated enum SavedMapRendererCompatibilityPolicy {
    static func isCompatible(
        rendererFormatVersion: Int?,
        supportsStreetLabels: Bool,
        supports3DBuildings: Bool,
        supportsMapPois: Bool
    ) -> Bool {
        switch rendererFormatVersion {
        case nil, 1:
            return true
        case 2:
            return supportsStreetLabels
        case 3:
            return supportsStreetLabels && supports3DBuildings
        case 4:
            return supportsStreetLabels && supports3DBuildings && supportsMapPois
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
        didSet { defaults.set(serverURLString, forKey: OfflineMapDefaults.serverURLKey) }
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
    @Published private(set) var catalogMaps: [OfflineMapCatalogMap] = []
    @Published private(set) var catalogShares: [OfflineMapCatalogShare] = []
    @Published private(set) var libraryLinkCode: OfflineMapLibraryLinkCode?
    @Published private(set) var pendingSharePreview: OfflineMapSharePreview?
    @Published private(set) var createdShareURL: URL?
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
        guard OfflineMapJobPersistence.shouldInstallOnDevice(defaults: defaults),
              let activeJobId = OfflineMapJobPersistence.activeJobId(defaults: defaults),
              OfflineMapJobPersistence.downloadedJobId(defaults: defaults) == activeJobId,
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
    @Published private var packDisplayNames: [String: String]
    private var mapJobTask: Task<Void, Never>?
    private var mapJobTaskID: UUID?
    private var inventorySyncTask: Task<Void, Never>?
    private var catalogSyncTask: Task<Void, Never>?
    private var pendingShareToken: String?
    private var activationReconciliationTask: Task<Void, Never>?
    private var backgroundUploadObserver: AnyCancellable?
    private var activityCounter = OfflineMapActivityCounter()
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
            try await OfflineMapPackDownloader.download(
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

    func createJobFromSelectedMapArea() {
        guard canStartNewMapJob() else { return }
        guard let selectedMapBounds else {
            errorMessage = OfflineMapPlatformError.invalidResponse.localizedDescription
            return
        }
        isMapAreaSelectionActive = false
        createJobAndDownload(request: .customBBox(selectedMapBounds))
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
        let persistedJobId = OfflineMapJobPersistence.activeJobId(defaults: defaults)
        let persistedInstallIntent = OfflineMapJobPersistence.shouldInstallOnDevice(defaults: defaults)
        let persistedServerURL = OfflineMapJobPersistence.serverURLString(defaults: defaults)
        if persistedJobId == nil {
            isServerRecoveryCheckPending = true
        }

        startMapJobTask { manager in
            if let persistedJobId,
               try await manager.finishDownloadedRecoveredJobIfAvailable(
                    jobId: persistedJobId,
                    installOnDevice: persistedInstallIntent,
                    bleManager: bleManager
               ) {
                return
            }
            let recoveryServerURL = manager.recoveryServerURL(
                persistedServerURL: persistedServerURL
            )
            var client = try manager.makeClient(serverURLString: recoveryServerURL)
            client = try await manager.ensureRegisteredInstallationWithRetry(
                client: client
            )
            var jobId = persistedJobId
            var shouldInstallOnDevice = persistedInstallIntent

            if jobId == nil {
                manager.statusMessage = "checking for server maps"
                let jobs = try await manager.listJobsWithRetry(client: client)
                if manager.consumeForgottenDiscovery(
                    jobs: jobs,
                    serverURLString: recoveryServerURL,
                    clientInstallationId: client.clientInstallationId
                ) {
                    manager.isServerRecoveryCheckPending = false
                    manager.statusMessage = ""
                    return
                }
                guard let recovered = manager.selectOwnedRecoverableJob(
                    from: jobs,
                    clientInstallationId: client.clientInstallationId
                ) else {
                    manager.isServerRecoveryCheckPending = false
                    manager.statusMessage = ""
                    return
                }
                manager.adoptRecoveredJob(recovered)
                jobId = recovered.jobId
                shouldInstallOnDevice = recovered.installOnDevice == true
                manager.persistCurrentJob(installOnDevice: shouldInstallOnDevice)
                manager.isServerRecoveryCheckPending = false
            }

            guard let jobId else { return }
            try await manager.finishRecoveredJob(
                jobId: jobId,
                installOnDevice: shouldInstallOnDevice,
                client: client,
                bleManager: bleManager
            )
        }
    }

    func pausePendingMapJob() {
        guard mapJobTask != nil else { return }
        mapJobTask?.cancel()
        statusMessage = "map preparation paused"
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
            statusMessage: statusMessage
        )
    }

    func isAwaitingMapActivationConfirmation(_ packURL: URL) -> Bool {
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
        activeDeviceMap: DeviceActiveMapDescriptor?
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

        if let activeDeviceMap {
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
        return items
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
            readerRequirements: verifiedReaderRequirements
        )
        try replaceDownloadedArtifact(
            at: temporaryURL,
            destination: destination,
            metadata: metadata,
            mapID: map.mapId,
            fileExtension: "bmap",
            obsoleteDestination: obsoleteDestination
        )
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
              activeMapId == savedMapID(for: packURL) else {
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

    func reconcileLastTransfer(bleManager: BLEManager) {
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
            updateLastTransferOutcome("installed")
            statusMessage = "map installed: \(displayName(forMapId: lastTransferMapId))"
            errorMessage = nil
        case .failed(let message):
            updateLastTransferOutcome("failed")
            statusMessage = ""
            errorMessage = OfflineMapPlatformError
                .mapActivationFailed(message)
                .localizedDescription
        case .pending:
            let deviceIsIdleOnAnotherMap =
                bleManager.mapTransferActivationStatus == "idle" &&
                bleManager.mapTransferActiveSessionId != sessionId
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
        return .customBBox(bounds)
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

    private func createJob(
        _ request: OfflineMapJobRequest,
        client: OfflineMapPlatformClient
    ) async throws -> OfflineMapJob {
        try await OfflineMapJobCreator.create(
            request: request,
            create: { identifiedRequest in
                try await client.createJob(identifiedRequest)
            },
            list: {
                try await client.jobs()
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
            serverURLString: value
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
            if currentJob?.isTerminal == true || shouldForgetPersistedJob(after: error) {
                clearPersistedJob()
            }
            throw error
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
        var artifactDisplayName: String?
        var rendererFormatVersion: Int?
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
                () throws -> (String?, Int?) in
                switch choice {
                case .bikeMapStream(let artifact, _):
                    let verified = try BikeMapStreamArtifactValidator.validate(
                        url: downloadedURL,
                        artifact: artifact,
                        expectedMapID: mapId,
                        trustStore: trustStore
                    )
                    return (verified.displayName, verified.rendererFormatVersion)
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
                    return (manifest.displayName, manifest.target?.formatVersion)
                }
            }
            let validation = try await withTaskCancellationHandler {
                try await validationTask.value
            } onCancel: {
                validationTask.cancel()
            }
            artifactDisplayName = validation.0
            rendererFormatVersion = validation.1
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
            downloadReceiptID: downloadReceiptID
        )
        do {
            try replaceDownloadedArtifact(
                at: temporaryURL,
                destination: destination,
                metadata: metadata,
                mapID: mapId,
                fileExtension: fileExtension
            )
        } catch {
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
        let backup = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).backup")
        let metadataURL = SavedMapArtifactMetadataStore.metadataURL(for: destination)
        let metadataBackup = SavedMapArtifactMetadataStore.metadataURL(for: backup)
        var backedUpArtifact = false
        var backedUpMetadata = false
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: destination, to: backup)
                backedUpArtifact = true
            }
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                try FileManager.default.moveItem(at: metadataURL, to: metadataBackup)
                backedUpMetadata = true
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            try metadataSave(metadata, destination)
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
            if backedUpArtifact { try? FileManager.default.removeItem(at: backup) }
            if backedUpMetadata { try? FileManager.default.removeItem(at: metadataBackup) }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: destination)
            try? SavedMapArtifactMetadataStore.delete(for: destination)
            if backedUpArtifact {
                try? FileManager.default.moveItem(at: backup, to: destination)
            }
            if backedUpMetadata {
                try? FileManager.default.moveItem(at: metadataBackup, to: metadataURL)
            }
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
                activationSessionId: bleManager.mapTransferActivationSessionId
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
    }

    private func clearPersistedJob(markHandled: Bool = false) {
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
               supportsMapPois: bleManager.supportsMapPois
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
                let verified = try BikeMapStreamArtifactValidator.validate(
                    url: packURL,
                    artifact: artifact,
                    expectedMapID: metadata.mapID,
                    trustStore: trustStore,
                    readerRequirements: metadata.readerRequirements
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
               supportsMapPois: bleManager.supportsMapPois
           ) {
            throw OfflineMapPlatformError.invalidPack(
                "This saved map is not compatible with the connected device. Regenerate it for this firmware."
            )
        }
        let expectedMapId = prepared.mapID
        let sessionId = prepared.sessionID
        var activationMayBeInFlight = false

#if os(iOS)
        let activeUploadActivity = await BackgroundMapUploadCoordinator.shared
            .activeUploadActivity()
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
                bleManager: bleManager
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

        let disposition = ExistingMapStreamAttemptDisposition.evaluate(
            expectedSessionID: sessionId,
            activeSessionID: bleManager.mapTransferActiveSessionId,
            activationStatus: bleManager.mapTransferActivationStatus,
            activationSessionID: bleManager.mapTransferActivationSessionId
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
                bleManager: bleManager
            )
            return
        }

        do {
            if resumePausedUpload {
                statusMessage = "restarting device transfer mode"
                await deviceTransferManager.exitMapTransfer(bleManager: bleManager)
            }
            let transferSession = try await deviceTransferManager.enterMapTransfer(
                bleManager: bleManager
            ) { message in
                self.statusMessage = message
            }
            try await withBackgroundTransferLifecycle(bleManager: bleManager) {
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
                let initialDeviceStatus = try await client.status()
                bleManager.applyAuthenticatedMapTransferStatus(initialDeviceStatus)
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
                if MapInstallProtocolSelector.select(
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
                   ) == .legacyArtifactRequired {
                    throw OfflineMapPlatformError.firmwareMapStreamUnsupported
                }
                let disposition = ExistingMapStreamAttemptDisposition.evaluate(
                    expectedSessionID: sessionId,
                    activeSessionID: initialDeviceStatus.activeSessionId,
                    activationStatus: initialDeviceStatus.activation?.status,
                    activationSessionID: initialDeviceStatus.activation?.sessionId
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
                        bleManager: bleManager
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
                    protocolVersion: 2,
                    streamFormatVersion: 1,
                    artifactURL: packURL
                )

                activationMayBeInFlight = true
                let retryProgressFloor = resumeProgressFloor
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
                            transferSession.tlsCertificateSHA256
                    ),
                    onTaskStarted: { taskID in
                        self.recordBackgroundUploadTask(
                            taskID,
                            mapID: expectedMapId
                        )
                    }
                ) { completedBytes, totalBytes in
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
            let outcome = MapTransferOutcomePolicy.outcome(
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
                statusMessage = uploadSucceeded
                    ? "Activation confirmation delayed. Reconnecting to device…"
                    : "Map upload paused. Tap Upload to resume."
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
        bleManager: BLEManager
    ) {
        let disposition = ExistingMapStreamAttemptDisposition.evaluate(
            expectedSessionID: sessionID,
            activeSessionID: activeSessionID,
            activationStatus: activationStatus,
            activationSessionID: activationSessionID
        )
        recordTransfer(
            mapId: mapID,
            sessionId: sessionID,
            previousMapId: activeMapID,
            previousSessionId: activeSessionID,
            previousSequence: activationSequence,
            outcome: disposition == .installed ? "installed" : "unconfirmed",
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
        let statusAfterUpload = try? await client.status()
        if let statusAfterUpload {
            bleManager.applyAuthenticatedMapTransferStatus(statusAfterUpload)
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
        case .installed:
            statusMessage = "map installed: \(displayName(forMapId: expectedMapID))"
            updateLastTransferOutcome("installed")
        case .continuesOnDevice:
            statusMessage = "Activation continues on device"
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
            await deviceTransferManager.exitMapTransfer(bleManager: bleManager)
            return value
        } catch {
            await deviceTransferManager.exitMapTransfer(bleManager: bleManager)
            throw error
        }
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
                             pollIntervalNanoseconds: UInt64 = OfflineMapDefaults.activationPollIntervalNanoseconds) async throws -> MapActivationConfirmationResult {
        let startedAt = Date()
        var deadline = startedAt.addingTimeInterval(timeout)
        var lastObservedState = "activation request accepted"
        var observedCurrentAttempt = false
        var lastProgress: MapActivationProgressPresentation?

        while Date() < deadline {
            var receivedHTTPStatus = false
            do {
                let status = try await client.status()
                receivedHTTPStatus = true
                bleManager.applyAuthenticatedMapTransferStatus(status)
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
                    deadline = Date().addingTimeInterval(timeout)
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
                    return .installed
                case .failed(let message):
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
                    deadline = Date().addingTimeInterval(timeout)
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
                    activationSessionId: bleManager.mapTransferActivationSessionId,
                    activationMapId: bleManager.mapTransferActivationMapId,
                    activationError: bleManager.mapTransferActivationError ??
                        bleManager.mapTransferLastError
                )
                observedCurrentAttempt = evaluation.observedCurrentAttempt
                switch evaluation.decision {
                case .installed:
                    return .installed
                case .failed(let message):
                    throw OfflineMapPlatformError.mapActivationFailed(message)
                case .pending(let state):
                    lastObservedState = state
                }
            }

            statusMessage = activationProgress?.label ??
                "activating \(displayName(forMapId: expectedMapId))"
            try await Task.sleep(
                nanoseconds: pollIntervalNanoseconds
            )
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
                                protocolVersion: Int = 1,
                                streamFormatVersion: Int? = nil,
                                artifactURL: URL? = nil) {
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
        updateLastTransferOutcome(outcome)
    }

    private func updateLastTransferOutcome(_ outcome: String) {
        lastTransferOutcome = outcome
        defaults.set(outcome, forKey: OfflineMapDefaults.lastTransferOutcomeKey)
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
            return cacheDirectoryOverride
        }
        let directory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("OfflineMapPacks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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

nonisolated struct OfflineMapDownloadConstraints: Equatable {
    let exactBytes: Int64?
    let maximumBytes: Int64
    let allowedDownloadHosts: Set<String>?

    init(
        exactBytes: Int64?,
        maximumBytes: Int64,
        allowedDownloadHosts: Set<String>? = nil
    ) {
        self.exactBytes = exactBytes
        self.maximumBytes = maximumBytes
        self.allowedDownloadHosts = allowedDownloadHosts
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
            allowedDownloadHosts: nil
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
            allowedDownloadHosts: [catalogHost.lowercased(), r2DownloadHost.lowercased()]
        )
    }
}

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
