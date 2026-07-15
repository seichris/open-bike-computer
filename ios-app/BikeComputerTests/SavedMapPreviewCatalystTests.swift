import Foundation
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
        guard outlineFallbackManager.previewImage(forCachedPack: snapshotPackURL) != nil else {
            fail("embedded boundary image should remain the MapKit failure fallback")
        }
        guard SavedMapSnapshotPreviewStore.imageData(for: snapshotPackURL) == nil else {
            fail("an embedded boundary fallback should not be persisted as a map snapshot")
        }

        var generatedBounds: OfflineMapPreviewBounds?
        let snapshotManager = OfflineMapManager(
            defaults: defaults,
            cacheDirectory: cacheDirectory,
            mapSnapshot: { bounds in
                generatedBounds = bounds
                return snapshotPNG
            }
        )
        snapshotManager.loadPreviewIfNeeded(forCachedPack: snapshotPackURL)
        let snapshotDeadline = Date().addingTimeInterval(3)
        while snapshotManager.previewImage(forCachedPack: snapshotPackURL) == nil &&
            Date() < snapshotDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard generatedBounds == expectedBounds else {
            fail("snapshot generation should use the downloaded map's exact bounds")
        }
        guard snapshotManager.previewImage(forCachedPack: snapshotPackURL) != nil else {
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
        guard restoredManager.previewImage(forCachedPack: snapshotPackURL) != nil else {
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

        print("SavedMapPreviewCatalystTests passed")
    }
}
