import Foundation
import MapKit
import UIKit

private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    Foundation.exit(1)
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

private func hasMeaningfulVisualVariation(_ image: UIImage) -> Bool {
    guard let source = image.cgImage,
          let pixels = rgbaPixels(image) else {
        return false
    }
    let pixelCount = source.width * source.height
    let sampleStride = max(1, pixelCount / 4_096)
    var quantizedColors = Set<UInt32>()
    var minimum = [UInt8](repeating: .max, count: 3)
    var maximum = [UInt8](repeating: .min, count: 3)
    for index in stride(from: 0, to: pixelCount, by: sampleStride) {
        let offset = index * 4
        guard pixels[offset + 3] >= 128 else { continue }
        let red = pixels[offset]
        let green = pixels[offset + 1]
        let blue = pixels[offset + 2]
        minimum[0] = min(minimum[0], red)
        minimum[1] = min(minimum[1], green)
        minimum[2] = min(minimum[2], blue)
        maximum[0] = max(maximum[0], red)
        maximum[1] = max(maximum[1], green)
        maximum[2] = max(maximum[2], blue)
        quantizedColors.insert(
            UInt32(red >> 4) << 8 |
                UInt32(green >> 4) << 4 |
                UInt32(blue >> 4)
        )
    }
    let widestChannelRange = zip(minimum, maximum)
        .map { Int($0.1) - Int($0.0) }
        .max() ?? 0
    return quantizedColors.count >= 3 && widestChannelRange >= 24
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
        let snapshotPNG = solidPNG(color: .systemOrange)
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

        let northWest = MKMapPoint(CLLocationCoordinate2D(
            latitude: expectedBounds.maxLatitude,
            longitude: expectedBounds.minLongitude
        ))
        let southEast = MKMapPoint(CLLocationCoordinate2D(
            latitude: expectedBounds.minLatitude,
            longitude: expectedBounds.maxLongitude
        ))
        let expectedAspectRatio = abs(southEast.x - northWest.x) /
            abs(southEast.y - northWest.y)
        guard let croppedFixture = OfflineMapSnapshotPreviewRenderer.croppedImage(
            from: cropFixtureImage(),
            northWestPoint: CGPoint(x: 30, y: 0),
            southEastPoint: CGPoint(x: 130, y: 96)
        ) else {
            fail("production crop helper should crop a deterministic snapshot fixture")
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
            fail("production crop helper should return only the selected fixture area")
        }
        guard OfflineMapSnapshotPreviewRenderer.croppedImage(
            from: cropFixtureImage(),
            northWestPoint: CGPoint(x: 40, y: 40),
            southEastPoint: CGPoint(x: 40, y: 40)
        ) == nil else {
            fail("production crop helper should reject an empty selected area")
        }
        guard hasMeaningfulVisualVariation(croppedFixture),
              let blankImage = UIImage(data: solidPNG(color: .systemGray)),
              !hasMeaningfulVisualVariation(blankImage) else {
            fail("map content validation should reject uniform placeholder images")
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
                  hasMeaningfulVisualVariation(liveSnapshotImage) else {
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
