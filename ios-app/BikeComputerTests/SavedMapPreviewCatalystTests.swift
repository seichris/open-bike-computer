import Foundation
import MapKit
import UIKit

private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    Foundation.exit(1)
}

private enum ExpectedPreviewTestError: Error {
    case metadataSave
}

private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8(value >> 8))
}

private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 24) & 0xff))
}

private func crc32(_ data: Data) -> UInt32 {
    var crc = UInt32.max
    for byte in data {
        var value = (crc ^ UInt32(byte)) & 0xff
        for _ in 0..<8 {
            value = value & 1 == 1
                ? (value >> 1) ^ 0xedb8_8320
                : value >> 1
        }
        crc = (crc >> 8) ^ value
    }
    return crc ^ UInt32.max
}

private func storedZip(entries: [(String, Data)]) -> Data {
    var zip = Data()
    for (path, body) in entries {
        let name = Data(path.utf8)
        appendUInt32LE(0x0403_4B50, to: &zip)
        appendUInt16LE(20, to: &zip)
        appendUInt16LE(0, to: &zip)
        appendUInt16LE(0, to: &zip)
        appendUInt16LE(0, to: &zip)
        appendUInt16LE(0, to: &zip)
        appendUInt32LE(crc32(body), to: &zip)
        appendUInt32LE(UInt32(body.count), to: &zip)
        appendUInt32LE(UInt32(body.count), to: &zip)
        appendUInt16LE(UInt16(name.count), to: &zip)
        appendUInt16LE(0, to: &zip)
        zip.append(name)
        zip.append(body)
    }
    return zip
}

private func hasVisiblePixel(_ image: UIImage) -> Bool {
    guard let source = image.cgImage else { return false }
    let width = source.width
    let height = source.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    return pixels.withUnsafeMutableBytes { bytes in
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
        return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 }
    }
}

private func rgbaPixels(_ image: UIImage) -> [UInt8]? {
    guard let source = image.cgImage else { return nil }
    let width = source.width
    let height = source.height
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
    return rendered ? pixels : nil
}

private func imageMatchesPNG(_ image: UIImage?, data: Data) -> Bool {
    guard let image,
          let expected = UIImage(data: data),
          image.size == expected.size,
          let actualPixels = rgbaPixels(image),
          let expectedPixels = rgbaPixels(expected) else {
        return false
    }
    return actualPixels == expectedPixels
}

private func solidPNG(color: UIColor) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(
        size: CGSize(width: 160, height: 96),
        format: format
    ).image { context in
        color.setFill()
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 160, height: 96))
    }
    guard let data = image.pngData() else {
        fail("test snapshot should encode as PNG")
    }
    return data
}

private func cropFixtureImage() -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 2
    format.opaque = true
    return UIGraphicsImageRenderer(
        size: CGSize(width: 160, height: 96),
        format: format
    ).image { context in
        UIColor(red: 0.75, green: 0.05, blue: 0.05, alpha: 1).setFill()
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 160, height: 96))
        UIColor(red: 0.05, green: 0.25, blue: 0.75, alpha: 1).setFill()
        context.cgContext.fill(CGRect(x: 30, y: 0, width: 100, height: 96))
        UIColor(red: 0.95, green: 0.75, blue: 0.05, alpha: 1).setFill()
        context.cgContext.fill(CGRect(x: 75, y: 0, width: 10, height: 96))
        UIColor.white.setFill()
        context.cgContext.fill(CGRect(x: 30, y: 44, width: 100, height: 8))
    }
}

private func variedSnapshotPNG() -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(
        size: CGSize(width: 160, height: 96),
        format: format
    ).image { context in
        UIColor(red: 0.88, green: 0.86, blue: 0.75, alpha: 1).setFill()
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 160, height: 96))
        UIColor(red: 0.28, green: 0.66, blue: 0.78, alpha: 1).setFill()
        context.cgContext.fill(CGRect(x: 70, y: 0, width: 18, height: 96))
        UIColor(red: 0.45, green: 0.43, blue: 0.40, alpha: 1).setFill()
        context.cgContext.fill(CGRect(x: 0, y: 38, width: 160, height: 7))
    }
    guard let data = image.pngData() else {
        fail("varied test snapshot should encode as PNG")
    }
    return data
}

private func pixel(
    in image: UIImage,
    x: Int,
    y: Int
) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)? {
    guard let source = image.cgImage,
          x >= 0, x < source.width,
          y >= 0, y < source.height,
          let pixels = rgbaPixels(image) else {
        return nil
    }
    let offset = (y * source.width + x) * 4
    return (
        pixels[offset],
        pixels[offset + 1],
        pixels[offset + 2],
        pixels[offset + 3]
    )
}

private func coordinatesMatch(
    _ lhs: CLLocationCoordinate2D,
    _ rhs: CLLocationCoordinate2D
) -> Bool {
    abs(lhs.latitude - rhs.latitude) < 0.000_000_001 &&
        abs(lhs.longitude - rhs.longitude) < 0.000_000_001
}

private func mapRectsMatch(_ lhs: MKMapRect, _ rhs: MKMapRect) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) < 0.001 &&
        abs(lhs.origin.y - rhs.origin.y) < 0.001 &&
        abs(lhs.size.width - rhs.size.width) < 0.001 &&
        abs(lhs.size.height - rhs.size.height) < 0.001
}

@main
struct SavedMapPreviewCatalystTests {
    @MainActor
    static func main() async {
        let suite = "saved-map-preview-catalyst-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fail("test defaults should create")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("saved-map-preview-catalyst-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            fail("test cache should create: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let mapID = "custom-map-4dc48b9bcb"
        let packURL = cacheDirectory.appendingPathComponent("\(mapID).zip")
        let manifest: Data
        do {
            manifest = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "mapId": mapID,
                "displayName": mapID,
                "bounds": [120.90, 30.70, 121.95, 31.55],
                "source": ["name": "Shanghai and Suzhou"],
            ])
            try storedZip(entries: [
                ("manifest.json", manifest),
                ("VECTMAP/\(mapID)/+0000+0000/1.fmb", Data("map-block".utf8)),
            ]).write(to: packURL)
        } catch {
            fail("preview-less test pack should write: \(error)")
        }
        defaults.set(
            [packURL.lastPathComponent: mapID],
            forKey: "offlineMap.packDisplayNames"
        )

        let manager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory,
            mapSnapshot: { _ in nil }
        )
        guard manager.displayName(forCachedPack: packURL) == "Shanghai and Suzhou" else {
            fail("source.name should repair the generated saved-map title")
        }

        manager.loadPreviewIfNeeded(forCachedPack: packURL)
        let deadline = Date().addingTimeInterval(3)
        while manager.previewImage(forCachedPack: packURL) == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let image = manager.previewImage(forCachedPack: packURL) else {
            fail("bounds fallback should publish a preview through OfflineMapManager")
        }
        guard image.size == CGSize(width: 160, height: 96) else {
            fail("bounds fallback should publish the expected 160x96 image")
        }
        guard hasVisiblePixel(image) else {
            fail("bounds fallback should contain visible rendered pixels")
        }

        let outlinePNG = solidPNG(color: .systemBlue)
        let snapshotPNG = variedSnapshotPNG()
        let snapshotMapID = "custom-map-snapshot"
        let snapshotPackURL = cacheDirectory
            .appendingPathComponent("\(snapshotMapID).zip")
        let expectedBounds = OfflineMapPreviewBounds(
            coordinates: [120.90, 30.70, 121.95, 31.55]
        )!
        do {
            let snapshotManifest = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "mapId": snapshotMapID,
                "bounds": [120.90, 30.70, 121.95, 31.55],
                "preview": [
                    "type": "boundary-png",
                    "path": "preview.png",
                    "width": 160,
                    "height": 96,
                    "dataBase64": outlinePNG.base64EncodedString(),
                ],
            ])
            try storedZip(entries: [
                ("manifest.json", snapshotManifest),
                ("preview.png", outlinePNG),
                (
                    "VECTMAP/\(snapshotMapID)/+0000+0000/1.fmb",
                    Data("map-block".utf8)
                ),
            ]).write(to: snapshotPackURL)
        } catch {
            fail("snapshot test pack should write: \(error)")
        }

        let outlineFallbackManager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory,
            mapSnapshot: { _ in nil }
        )
        outlineFallbackManager.loadPreviewIfNeeded(forCachedPack: snapshotPackURL)
        let outlineDeadline = Date().addingTimeInterval(3)
        while outlineFallbackManager.previewImage(forCachedPack: snapshotPackURL) == nil &&
            Date() < outlineDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard imageMatchesPNG(
            outlineFallbackManager.previewImage(forCachedPack: snapshotPackURL),
            data: outlinePNG
        ) else {
            fail("embedded boundary image should remain the MapKit failure fallback")
        }
        guard SavedMapSnapshotPreviewStore.imageData(for: snapshotPackURL) == nil else {
            fail("an embedded boundary fallback should not be persisted as a map snapshot")
        }

        let uniformSnapshotPNG = solidPNG(color: .systemGray)
        var uniformSnapshotReturned = false
        let uniformSnapshotManager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory,
            mapSnapshot: { _ in
                uniformSnapshotReturned = true
                return uniformSnapshotPNG
            }
        )
        uniformSnapshotManager.loadPreviewIfNeeded(forCachedPack: snapshotPackURL)
        let uniformDeadline = Date().addingTimeInterval(3)
        while !uniformSnapshotReturned && Date() < uniformDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard uniformSnapshotReturned else {
            fail("uniform snapshot negative control should finish")
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard imageMatchesPNG(
            uniformSnapshotManager.previewImage(forCachedPack: snapshotPackURL),
            data: outlinePNG
        ) else {
            fail("a uniform snapshot should not replace the embedded boundary fallback")
        }
        guard SavedMapSnapshotPreviewStore.imageData(for: snapshotPackURL) == nil else {
            fail("a uniform snapshot should not be persisted")
        }

        let staleMapID = "custom-map-stale-preview"
        let stalePackURL = cacheDirectory.appendingPathComponent("\(staleMapID).zip")
        do {
            let staleManifest = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "mapId": staleMapID,
                "bounds": [120.90, 30.70, 121.95, 31.55],
            ])
            try storedZip(entries: [
                ("manifest.json", staleManifest),
                (
                    "VECTMAP/\(staleMapID)/+0000+0000/1.fmb",
                    Data("map-block".utf8)
                ),
            ]).write(to: stalePackURL)
            try SavedMapSnapshotPreviewStore.save(
                uniformSnapshotPNG,
                for: stalePackURL
            )
        } catch {
            fail("stale preview race fixture should write: \(error)")
        }
        guard let staleSnapshotData = SavedMapSnapshotPreviewStore.imageData(
            for: stalePackURL
        ) else {
            fail("stale preview race should capture its invalid snapshot")
        }
        let staleLoadResult = OfflineMapPreviewLoadResult(
            snapshotData: staleSnapshotData,
            packContent: OfflineMapPackPreviewReader.content(for: stalePackURL)
        )
        var staleLoadStarted = false
        var staleLoadReturned = false
        var staleLoadContinuation: CheckedContinuation<
            OfflineMapPreviewLoadResult,
            Never
        >?
        let staleLoadManager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory,
            previewLoad: { _ in
                staleLoadStarted = true
                let result = await withCheckedContinuation { continuation in
                    staleLoadContinuation = continuation
                }
                staleLoadReturned = true
                return result
            },
            mapSnapshot: { _ in nil }
        )
        staleLoadManager.loadPreviewIfNeeded(forCachedPack: stalePackURL)
        let staleStartedDeadline = Date().addingTimeInterval(3)
        while !staleLoadStarted && Date() < staleStartedDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard staleLoadStarted, let continuation = staleLoadContinuation else {
            fail("stale preview load should start")
        }
        staleLoadManager.deleteCachedPack(at: stalePackURL)
        do {
            try SavedMapSnapshotPreviewStore.save(snapshotPNG, for: stalePackURL)
        } catch {
            fail("replacement snapshot should save during stale-load race: \(error)")
        }
        staleLoadContinuation = nil
        continuation.resume(returning: staleLoadResult)
        let staleReturnedDeadline = Date().addingTimeInterval(3)
        while !staleLoadReturned && Date() < staleReturnedDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard staleLoadReturned else {
            fail("non-cooperative stale preview load should return")
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard SavedMapSnapshotPreviewStore.imageData(for: stalePackURL) == snapshotPNG else {
            fail("a stale invalid-preview load must not delete a replacement snapshot")
        }

        let rollbackMapID = "custom-map-rollback-preview"
        let rollbackPackURL = cacheDirectory.appendingPathComponent("\(rollbackMapID).zip")
        let rollbackOldPackData: Data
        let rollbackNewPackData: Data
        let rollbackReplacementMetadata: SavedMapArtifactMetadata
        do {
            let oldManifest = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "mapId": rollbackMapID,
                "displayName": "Old Rollback Map",
                "bounds": [120.90, 30.70, 121.95, 31.55],
            ])
            rollbackOldPackData = storedZip(entries: [
                ("manifest.json", oldManifest),
                (
                    "VECTMAP/\(rollbackMapID)/+0000+0000/1.fmb",
                    Data("old-map-block".utf8)
                ),
            ])
            let newManifest = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "mapId": rollbackMapID,
                "displayName": "Replacement Rollback Map",
                "bounds": [10.0, 20.0, 11.0, 21.0],
            ])
            rollbackNewPackData = storedZip(entries: [
                ("manifest.json", newManifest),
                (
                    "VECTMAP/\(rollbackMapID)/+0000+0000/1.fmb",
                    Data("new-map-block".utf8)
                ),
            ])
            try rollbackOldPackData.write(to: rollbackPackURL)
            let oldMetadataData = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": SavedMapArtifactMetadata.currentSchemaVersion,
                "mapID": rollbackMapID,
                "displayName": "Old Rollback Map",
                "localArtifactFilename": rollbackPackURL.lastPathComponent,
                "userDefinedDisplayName": true,
            ])
            let oldMetadata = try JSONDecoder().decode(
                SavedMapArtifactMetadata.self,
                from: oldMetadataData
            )
            try SavedMapArtifactMetadataStore.save(oldMetadata, for: rollbackPackURL)
            let replacementMetadataData = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": SavedMapArtifactMetadata.currentSchemaVersion,
                "mapID": rollbackMapID,
                "displayName": "Replacement Rollback Map",
                "localArtifactFilename": rollbackPackURL.lastPathComponent,
                "userDefinedDisplayName": false,
            ])
            rollbackReplacementMetadata = try JSONDecoder().decode(
                SavedMapArtifactMetadata.self,
                from: replacementMetadataData
            )
        } catch {
            fail("rollback preview race fixture should write: \(error)")
        }
        let rollbackReplacementContent = OfflineMapPreviewLoadResult(
            snapshotData: nil,
            packContent: OfflineMapPackPreviewContent(
                imageData: nil,
                bounds: OfflineMapPreviewBounds(
                    coordinates: [10.0, 20.0, 11.0, 21.0]
                )
            )
        )
        var rollbackLoadStarted = false
        var rollbackLoadReturned = false
        var rollbackSnapshotGenerationCount = 0
        var rollbackLoadContinuation: CheckedContinuation<
            OfflineMapPreviewLoadResult,
            Never
        >?
        let rollbackManager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory,
            previewLoad: { _ in
                rollbackLoadStarted = true
                let result = await withCheckedContinuation { continuation in
                    rollbackLoadContinuation = continuation
                }
                rollbackLoadReturned = true
                return result
            },
            mapSnapshot: { _ in
                rollbackSnapshotGenerationCount += 1
                return snapshotPNG
            },
            metadataSave: { _, _ in
                throw ExpectedPreviewTestError.metadataSave
            }
        )
        rollbackManager.loadPreviewIfNeeded(forCachedPack: rollbackPackURL)
        let rollbackStartedDeadline = Date().addingTimeInterval(3)
        while !rollbackLoadStarted && Date() < rollbackStartedDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard rollbackLoadStarted, let rollbackContinuation = rollbackLoadContinuation else {
            fail("rollback preview load should start")
        }
        let rollbackIncomingURL = cacheDirectory.appendingPathComponent(
            ".rollback-incoming-\(UUID().uuidString).zip"
        )
        do {
            try rollbackNewPackData.write(to: rollbackIncomingURL)
            try rollbackManager.replaceDownloadedArtifact(
                at: rollbackIncomingURL,
                destination: rollbackPackURL,
                metadata: rollbackReplacementMetadata,
                mapID: rollbackMapID,
                fileExtension: "zip"
            )
            fail("rollback replacement should fail at metadata persistence")
        } catch ExpectedPreviewTestError.metadataSave {
            // Expected failure after the replacement artifact has been moved into place.
        } catch {
            fail("rollback replacement should fail with the injected error: \(error)")
        }
        guard (try? Data(contentsOf: rollbackPackURL)) == rollbackOldPackData,
              SavedMapArtifactMetadataStore.load(for: rollbackPackURL)?.displayName ==
                  "Old Rollback Map" else {
            fail("failed replacement should restore the previous artifact and metadata")
        }
        rollbackLoadContinuation = nil
        rollbackContinuation.resume(returning: rollbackReplacementContent)
        let rollbackReturnedDeadline = Date().addingTimeInterval(3)
        while !rollbackLoadReturned && Date() < rollbackReturnedDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard rollbackLoadReturned else {
            fail("non-cooperative rollback preview load should return")
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard rollbackSnapshotGenerationCount == 0,
              rollbackManager.previewImage(forCachedPack: rollbackPackURL) == nil,
              SavedMapSnapshotPreviewStore.imageData(for: rollbackPackURL) == nil else {
            fail("failed replacement should invalidate transient preview work")
        }

        var generatedBounds: OfflineMapPreviewBounds?
        var snapshotContinuation: CheckedContinuation<Data?, Never>?
        var gatedSnapshotStarted = false
        let snapshotManager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory,
            mapSnapshot: { bounds in
                generatedBounds = bounds
                gatedSnapshotStarted = true
                return await withCheckedContinuation { continuation in
                    snapshotContinuation = continuation
                }
            }
        )
        snapshotManager.loadPreviewIfNeeded(forCachedPack: snapshotPackURL)
        let fallbackDeadline = Date().addingTimeInterval(3)
        while (!gatedSnapshotStarted ||
            snapshotManager.previewImage(forCachedPack: snapshotPackURL) == nil) &&
            Date() < fallbackDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard gatedSnapshotStarted else {
            fail("snapshot generation should start after publishing the offline fallback")
        }
        guard imageMatchesPNG(
            snapshotManager.previewImage(forCachedPack: snapshotPackURL),
            data: outlinePNG
        ) else {
            fail("embedded preview should publish while MapKit is still pending")
        }
        guard SavedMapSnapshotPreviewStore.imageData(for: snapshotPackURL) == nil else {
            fail("a pending MapKit request should not persist the offline fallback")
        }
        snapshotContinuation?.resume(returning: snapshotPNG)
        snapshotContinuation = nil
        let snapshotDeadline = Date().addingTimeInterval(3)
        while (!imageMatchesPNG(
            snapshotManager.previewImage(forCachedPack: snapshotPackURL),
            data: snapshotPNG
        ) || SavedMapSnapshotPreviewStore.imageData(for: snapshotPackURL) != snapshotPNG) &&
            Date() < snapshotDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard generatedBounds == expectedBounds else {
            fail("snapshot generation should use the downloaded map's exact bounds")
        }
        guard imageMatchesPNG(
            snapshotManager.previewImage(forCachedPack: snapshotPackURL),
            data: snapshotPNG
        ) else {
            fail("generated map snapshot should replace the embedded boundary fallback")
        }
        guard SavedMapSnapshotPreviewStore.imageData(for: snapshotPackURL) == snapshotPNG else {
            fail("generated map snapshot should persist beside the saved artifact")
        }

        var restoredGenerationCount = 0
        let restoredManager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory,
            mapSnapshot: { _ in
                restoredGenerationCount += 1
                return nil
            }
        )
        restoredManager.loadPreviewIfNeeded(forCachedPack: snapshotPackURL)
        let restoredDeadline = Date().addingTimeInterval(3)
        while restoredManager.previewImage(forCachedPack: snapshotPackURL) == nil &&
            Date() < restoredDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard imageMatchesPNG(
            restoredManager.previewImage(forCachedPack: snapshotPackURL),
            data: snapshotPNG
        ) else {
            fail("persisted map snapshot should load after relaunch")
        }
        guard restoredGenerationCount == 0 else {
            fail("persisted map snapshot should avoid an unnecessary MapKit request")
        }
        restoredManager.deleteCachedPack(at: snapshotPackURL)
        guard SavedMapSnapshotPreviewStore.imageData(for: snapshotPackURL) == nil else {
            fail("deleting a saved map should delete its persisted snapshot")
        }

        let cancellationMapID = "custom-map-cancel"
        let cancellationPackURL = cacheDirectory
            .appendingPathComponent("\(cancellationMapID).zip")
        do {
            let cancellationManifest = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "mapId": cancellationMapID,
                "bounds": [120.91, 30.71, 121.94, 31.54],
            ])
            try storedZip(entries: [
                ("manifest.json", cancellationManifest),
                (
                    "VECTMAP/\(cancellationMapID)/+0000+0000/1.fmb",
                    Data("map-block".utf8)
                ),
            ]).write(to: cancellationPackURL)
        } catch {
            fail("cancellation test pack should write: \(error)")
        }
        var snapshotStarted = false
        var snapshotCancelled = false
        let cancellationManager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory,
            mapSnapshot: { _ in
                snapshotStarted = true
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return snapshotPNG
                } catch is CancellationError {
                    snapshotCancelled = true
                    throw CancellationError()
                }
            }
        )
        cancellationManager.loadPreviewIfNeeded(forCachedPack: cancellationPackURL)
        let startedDeadline = Date().addingTimeInterval(3)
        while !snapshotStarted && Date() < startedDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard snapshotStarted else {
            fail("snapshot generation should start for a previewable map")
        }
        cancellationManager.deleteCachedPack(at: cancellationPackURL)
        let cancelledDeadline = Date().addingTimeInterval(3)
        while !snapshotCancelled && Date() < cancelledDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard snapshotCancelled else {
            fail("deleting a map should cancel its in-flight snapshot")
        }
        guard SavedMapSnapshotPreviewStore.imageData(for: cancellationPackURL) == nil else {
            fail("a cancelled snapshot must not recreate a deleted map's thumbnail")
        }

        let lateMapID = "custom-map-late-snapshot"
        let latePackURL = cacheDirectory.appendingPathComponent("\(lateMapID).zip")
        do {
            let lateManifest = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "mapId": lateMapID,
                "bounds": [120.92, 30.72, 121.93, 31.53],
            ])
            try storedZip(entries: [
                ("manifest.json", lateManifest),
                (
                    "VECTMAP/\(lateMapID)/+0000+0000/1.fmb",
                    Data("map-block".utf8)
                ),
            ]).write(to: latePackURL)
        } catch {
            fail("late snapshot test pack should write: \(error)")
        }
        var lateSnapshotStarted = false
        var lateSnapshotReturned = false
        var lateSnapshotContinuation: CheckedContinuation<Data?, Never>?
        let lateSnapshotManager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory,
            mapSnapshot: { _ in
                lateSnapshotStarted = true
                let data = await withCheckedContinuation { continuation in
                    lateSnapshotContinuation = continuation
                }
                lateSnapshotReturned = true
                return data
            }
        )
        lateSnapshotManager.loadPreviewIfNeeded(forCachedPack: latePackURL)
        let lateStartedDeadline = Date().addingTimeInterval(3)
        while !lateSnapshotStarted && Date() < lateStartedDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard lateSnapshotStarted else {
            fail("non-cooperative snapshot generation should start")
        }
        lateSnapshotManager.deleteCachedPack(at: latePackURL)
        lateSnapshotContinuation?.resume(returning: snapshotPNG)
        lateSnapshotContinuation = nil
        let lateReturnedDeadline = Date().addingTimeInterval(3)
        while !lateSnapshotReturned && Date() < lateReturnedDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard lateSnapshotReturned else {
            fail("non-cooperative snapshot should finish after deletion")
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        guard lateSnapshotManager.previewImage(forCachedPack: latePackURL) == nil else {
            fail("a late snapshot must not republish a deleted map's thumbnail")
        }
        guard SavedMapSnapshotPreviewStore.imageData(for: latePackURL) == nil else {
            fail("a late snapshot must not persist after its map was deleted")
        }

        let deviceDescriptor = DeviceActiveMapDescriptor(
            mapID: "cloned-sd-map",
            sessionID: "cloned-sd-session",
            displayName: "Cloned SD Map",
            boundsE7: [1_209_000_000, 307_000_000, 1_219_500_000, 315_500_000]
        )!
        var deviceSnapshotGenerationCount = 0
        let devicePreviewManager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory,
            mapSnapshot: { bounds in
                guard bounds == expectedBounds else {
                    fail("device-only preview should use its reported bounds")
                }
                deviceSnapshotGenerationCount += 1
                return snapshotPNG
            }
        )
        devicePreviewManager.updateActiveDeviceMap(deviceDescriptor)
        guard let deviceItem = devicePreviewManager.savedMapListItems(
            activeDeviceMap: deviceDescriptor
        ).first(where: { $0.deviceMap?.mapID == deviceDescriptor.mapID }) else {
            fail("device-only map should appear in the merged saved-map inventory")
        }
        devicePreviewManager.loadPreviewIfNeeded(for: deviceItem)
        let devicePreviewDeadline = Date().addingTimeInterval(3)
        while (!imageMatchesPNG(
            devicePreviewManager.previewImage(for: deviceItem),
            data: snapshotPNG
        ) || DeviceMapSnapshotPreviewStore.imageData(
            for: deviceDescriptor,
            in: cacheDirectory
        ) != snapshotPNG) && Date() < devicePreviewDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard deviceSnapshotGenerationCount == 1,
              imageMatchesPNG(
                  devicePreviewManager.previewImage(for: deviceItem),
                  data: snapshotPNG
              ),
              DeviceMapSnapshotPreviewStore.imageData(
                  for: deviceDescriptor,
                  in: cacheDirectory
              ) == snapshotPNG else {
            fail("device-only map should generate and persist its MapKit preview")
        }

        var restoredDeviceGenerationCount = 0
        let restoredDevicePreviewManager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory,
            mapSnapshot: { _ in
                restoredDeviceGenerationCount += 1
                return nil
            }
        )
        restoredDevicePreviewManager.updateActiveDeviceMap(deviceDescriptor)
        guard let restoredDeviceItem = restoredDevicePreviewManager.savedMapListItems(
            activeDeviceMap: deviceDescriptor
        ).first(where: { $0.deviceMap?.mapID == deviceDescriptor.mapID }) else {
            fail("restored device-only map should remain visible")
        }
        restoredDevicePreviewManager.loadPreviewIfNeeded(for: restoredDeviceItem)
        let restoredDeviceDeadline = Date().addingTimeInterval(3)
        while !imageMatchesPNG(
            restoredDevicePreviewManager.previewImage(for: restoredDeviceItem),
            data: snapshotPNG
        ) && Date() < restoredDeviceDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard restoredDeviceGenerationCount == 0,
              imageMatchesPNG(
                  restoredDevicePreviewManager.previewImage(for: restoredDeviceItem),
                  data: snapshotPNG
              ) else {
            fail("device preview cache should survive relaunch without another snapshot")
        }
        restoredDevicePreviewManager.updateActiveDeviceMap(nil)
        guard restoredDevicePreviewManager.previewImage(for: restoredDeviceItem) == nil else {
            fail("disconnect should clear live device-only preview state")
        }

        let sessionlessDescriptorA = DeviceActiveMapDescriptor(
            mapID: "legacy-map",
            boundsE7: [1_209_000_000, 307_000_000, 1_219_500_000, 315_500_000]
        )!
        let sessionlessDescriptorB = DeviceActiveMapDescriptor(
            mapID: "legacy-map",
            boundsE7: [1_000_000_000, 200_000_000, 1_010_000_000, 210_000_000]
        )!
        do {
            try DeviceMapSnapshotPreviewStore.save(
                snapshotPNG,
                for: sessionlessDescriptorA,
                in: cacheDirectory
            )
        } catch {
            fail("sessionless device preview should persist: \(error)")
        }
        guard DeviceMapSnapshotPreviewStore.imageURL(
            for: sessionlessDescriptorA,
            in: cacheDirectory
        ) != DeviceMapSnapshotPreviewStore.imageURL(
            for: sessionlessDescriptorB,
            in: cacheDirectory
        ), DeviceMapSnapshotPreviewStore.imageData(
            for: sessionlessDescriptorB,
            in: cacheDirectory
        ) == nil else {
            fail("sessionless descriptors with different bounds must not share previews")
        }

        let pruneCacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "device-preview-prune-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: pruneCacheDirectory) }
        for index in 0..<18 {
            let descriptor = DeviceActiveMapDescriptor(
                mapID: ".map-\(index)",
                sessionID: "session-\(index)",
                boundsE7: [
                    1_000_000_000 + index,
                    200_000_000,
                    1_010_000_000 + index,
                    210_000_000,
                ]
            )!
            do {
                try DeviceMapSnapshotPreviewStore.save(
                    snapshotPNG,
                    for: descriptor,
                    in: pruneCacheDirectory
                )
            } catch {
                fail("bounded device preview cache should save entry \(index): \(error)")
            }
        }
        let prunedEntries = (try? FileManager.default.contentsOfDirectory(
            at: pruneCacheDirectory.appendingPathComponent(
                "DeviceMapPreviews",
                isDirectory: true
            ),
            includingPropertiesForKeys: nil,
            options: []
        ))?.filter { $0.pathExtension.lowercased() == "png" } ?? []
        guard prunedEntries.count <= 16,
              prunedEntries.allSatisfy({ !$0.lastPathComponent.hasPrefix(".") }) else {
            fail("device preview cache should prune dot-prefixed map identities")
        }

        let northWestCoordinate = CLLocationCoordinate2D(
            latitude: expectedBounds.maxLatitude,
            longitude: expectedBounds.minLongitude
        )
        let southEastCoordinate = CLLocationCoordinate2D(
            latitude: expectedBounds.minLatitude,
            longitude: expectedBounds.maxLongitude
        )
        let northWest = MKMapPoint(northWestCoordinate)
        let southEast = MKMapPoint(southEastCoordinate)
        let expectedMapRect = MKMapRect(
            x: min(northWest.x, southEast.x),
            y: min(northWest.y, southEast.y),
            width: abs(southEast.x - northWest.x),
            height: abs(southEast.y - northWest.y)
        )
        let expectedAspectRatio = abs(southEast.x - northWest.x) /
            abs(southEast.y - northWest.y)
        var capturedMapRect: MKMapRect?
        var capturedSize: CGSize?
        var capturedScale: CGFloat?
        var mappedCoordinates: [CLLocationCoordinate2D] = []
        let deterministicSnapshotData: Data
        do {
            guard let data = try await OfflineMapSnapshotPreviewRenderer.pngData(
                for: expectedBounds,
                snapshot: { options in
                    capturedMapRect = options.mapRect
                    capturedSize = options.size
                    capturedScale = options.scale
                    return OfflineMapSnapshotPreviewRenderer.SnapshotResult(
                        image: cropFixtureImage(),
                        pointForCoordinate: { coordinate in
                            mappedCoordinates.append(coordinate)
                            if coordinatesMatch(coordinate, northWestCoordinate) {
                                return CGPoint(x: 30, y: 0)
                            }
                            if coordinatesMatch(coordinate, southEastCoordinate) {
                                return CGPoint(x: 130, y: 96)
                            }
                            return .zero
                        }
                    )
                }
            ) else {
                fail("production renderer should process a deterministic snapshot fixture")
            }
            deterministicSnapshotData = data
        } catch {
            fail("deterministic production renderer should complete: \(error)")
        }
        guard let capturedMapRect,
              mapRectsMatch(capturedMapRect, expectedMapRect),
              capturedSize == CGSize(width: 160, height: 96),
              (capturedScale ?? 0) > 0 else {
            fail(
                "production renderer should request the exact projected map bounds " +
                    "(rect: \(String(describing: capturedMapRect)), " +
                    "size: \(String(describing: capturedSize)), " +
                    "scale: \(String(describing: capturedScale)))"
            )
        }
        guard mappedCoordinates.count == 2,
              coordinatesMatch(mappedCoordinates[0], northWestCoordinate),
              coordinatesMatch(mappedCoordinates[1], southEastCoordinate) else {
            fail("production renderer should crop using the requested bounds coordinates")
        }
        guard let croppedFixture = UIImage(data: deterministicSnapshotData) else {
            fail("deterministic production renderer output should decode")
        }
        guard croppedFixture.size == CGSize(width: 100, height: 96),
              let bluePixel = pixel(in: croppedFixture, x: 5, y: 20),
              Int(bluePixel.blue) > Int(bluePixel.red) + 80,
              let yellowPixel = pixel(in: croppedFixture, x: 50, y: 20),
              yellowPixel.red > 180,
              yellowPixel.green > 140,
              yellowPixel.blue < 100,
              let whitePixel = pixel(in: croppedFixture, x: 5, y: 48),
              whitePixel.red > 220,
              whitePixel.green > 220,
              whitePixel.blue > 220 else {
            fail("production renderer should return only the selected fixture area")
        }
        guard OfflineMapSnapshotPreviewRenderer.hasMeaningfulVisualVariation(croppedFixture) else {
            fail("production renderer output should contain varied map content")
        }

        do {
            let emptyCropData = try await OfflineMapSnapshotPreviewRenderer.pngData(
                for: expectedBounds,
                snapshot: { _ in
                    OfflineMapSnapshotPreviewRenderer.SnapshotResult(
                        image: cropFixtureImage(),
                        pointForCoordinate: { _ in CGPoint(x: 40, y: 40) }
                    )
                }
            )
            guard emptyCropData == nil else {
                fail("production renderer should reject an empty selected area")
            }
            let blankImage = UIImage(data: uniformSnapshotPNG)!
            let blankSnapshotData = try await OfflineMapSnapshotPreviewRenderer.pngData(
                for: expectedBounds,
                snapshot: { _ in
                    OfflineMapSnapshotPreviewRenderer.SnapshotResult(
                        image: blankImage,
                        pointForCoordinate: { coordinate in
                            coordinatesMatch(coordinate, northWestCoordinate)
                                ? CGPoint(x: 30, y: 0)
                                : CGPoint(x: 130, y: 96)
                        }
                    )
                }
            )
            guard blankSnapshotData == nil else {
                fail("production renderer should reject a uniform placeholder image")
            }
        } catch {
            fail("production renderer negative controls should complete: \(error)")
        }

        let alternateBounds = OfflineMapPreviewBounds(
            coordinates: [10.0, 20.0, 11.0, 21.0]
        )!
        var alternateMapRect: MKMapRect?
        do {
            guard try await OfflineMapSnapshotPreviewRenderer.pngData(
                for: alternateBounds,
                snapshot: { options in
                    alternateMapRect = options.mapRect
                    return OfflineMapSnapshotPreviewRenderer.SnapshotResult(
                        image: cropFixtureImage(),
                        pointForCoordinate: { coordinate in
                            coordinate.latitude == alternateBounds.maxLatitude
                                ? CGPoint(x: 30, y: 0)
                                : CGPoint(x: 130, y: 96)
                        }
                    )
                }
            ) != nil else {
                fail("alternate-bounds renderer fixture should produce output")
            }
        } catch {
            fail("alternate-bounds renderer fixture should complete: \(error)")
        }
        guard let alternateMapRect,
              !mapRectsMatch(alternateMapRect, expectedMapRect) else {
            fail("production renderer request should change for a different geographic region")
        }

        if ProcessInfo.processInfo.environment["RUN_LIVE_MAPKIT_SNAPSHOT_TESTS"] == "1" {
            let liveSnapshotTask = Task { @MainActor in
                try await OfflineMapSnapshotPreviewRenderer.pngData(for: expectedBounds)
            }
            let liveSnapshotTimeout = Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                liveSnapshotTask.cancel()
            }
            let liveSnapshotData: Data
            do {
                guard let data = try await liveSnapshotTask.value else {
                    fail("production MapKit renderer should return a cropped PNG")
                }
                liveSnapshotData = data
            } catch {
                fail("production MapKit renderer should complete: \(error)")
            }
            liveSnapshotTimeout.cancel()
            guard let liveSnapshotImage = UIImage(data: liveSnapshotData) else {
                fail("production MapKit renderer output should decode")
            }
            let actualAspectRatio = liveSnapshotImage.size.width /
                liveSnapshotImage.size.height
            guard abs(actualAspectRatio - expectedAspectRatio) / expectedAspectRatio < 0.05 else {
                fail("production MapKit renderer should crop to the selected bounds aspect ratio")
            }
            guard liveSnapshotImage.size.width <= 160,
                  liveSnapshotImage.size.height <= 96,
                  OfflineMapSnapshotPreviewRenderer.hasMeaningfulVisualVariation(
                      liveSnapshotImage
                  ) else {
                fail(
                    "production MapKit renderer should return varied map content within " +
                        "thumbnail limits (size: \(liveSnapshotImage.size))"
                )
            }
        } else {
            print("Skipping opt-in live MapKit snapshot smoke test")
        }

        print("SavedMapPreviewCatalystTests passed")
    }
}
