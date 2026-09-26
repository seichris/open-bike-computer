import CoreGraphics
import Foundation
import ImageIO

@main
struct TopographyMapKitTileWarpTests {
    static func main() async throws {
        for scale in [1, 2] {
            try await chinaControlPoint(scale: scale)
        }
        let unchanged = Data([1, 2, 3])
        let outside = try await TopographyMapKitTileWarp.tile(
            z: 12, x: 2048, y: 1362, scale: 1
        ) { _, _, _, _ in unchanged }
        precondition(outside == unchanged, "non-China tiles must retain their signed bytes")
        print("TopographyMapKitTileWarpTests passed")
    }

    private static func chinaControlPoint(scale: Int) async throws {
        let zoom = 16
        let side = 256 * scale
        let wgs = (lat: 31.04, lon: 103.5)
        let gcj = CoordinateConverter.wgs84ToGCJ02(lat: wgs.lat, lon: wgs.lon)
        let source = pixel(lat: wgs.lat, lon: wgs.lon, zoom: zoom, side: side)
        let target = pixel(lat: gcj.lat, lon: gcj.lon, zoom: zoom, side: side)
        let mapped = TopographyMapKitTileWarp.sourcePixel(
            forMapKitPixelX: target.x, y: target.y, zoom: zoom, scale: scale
        )
        precondition(abs(mapped.x - source.x) < 0.01 && abs(mapped.y - source.y) < 0.01,
                     "GCJ target must address the WGS source pixel")
        let sourceTileX = Int(floor(source.x / Double(side)))
        let sourceTileY = Int(floor(source.y / Double(side)))
        let targetTileX = Int(floor(target.x / Double(side)))
        let targetTileY = Int(floor(target.y / Double(side)))
        precondition(sourceTileX != targetTileX || sourceTileY != targetTileY,
                     "control fixture must exercise a neighbouring source tile")
        let sourceX = Int(source.x) - sourceTileX * side
        let sourceY = Int(source.y) - sourceTileY * side
        let targetX = Int(target.x) - targetTileX * side
        let targetY = Int(target.y) - targetTileY * side
        let sourcePNG = try markedTile(side: side, x: sourceX, y: sourceY)
        let sourceAlpha = try alpha(sourcePNG, side: side, x: sourceX, y: sourceY)
        precondition(sourceAlpha > 200,
                     "source image orientation is incorrect")
        let output = try await TopographyMapKitTileWarp.tile(
            z: zoom, x: targetTileX, y: targetTileY, scale: scale
        ) { _, x, y, _ in
            x == sourceTileX && y == sourceTileY ? sourcePNG : nil
        }
        guard let output else { preconditionFailure("warped tile is missing") }
        let targetAlpha = try alpha(output, side: side, x: targetX, y: targetY)
        precondition(targetAlpha > 128,
                     "contour did not move to its GCJ-aligned MapKit location")
    }

    private static func pixel(
        lat: Double, lon: Double, zoom: Int, side: Int
    ) -> (x: Double, y: Double) {
        let world = Double(side * (1 << zoom))
        return ((lon + 180) / 360 * world,
                (1 - asinh(tan(lat * .pi / 180)) / .pi) / 2 * world)
    }

    private static func markedTile(side: Int, x: Int, y: Int) throws -> Data {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue
        ), let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw TestError.image
        }
        for row in max(0, y - 4)...min(side - 1, y + 4) {
            for column in max(0, x - 4)...min(side - 1, x + 4) {
                let index = (row * side + column) * 4
                bytes[index] = 255
                bytes[index + 3] = 255
            }
        }
        guard let image = context.makeImage() else { throw TestError.image }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.png" as CFString, 1, nil
        ) else { throw TestError.image }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestError.image }
        return output as Data
    }

    private static func alpha(_ png: Data, side: Int, x: Int, y: Int) throws -> UInt8 {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue
              ), let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw TestError.image
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return bytes[(y * side + x) * 4 + 3]
    }

    private enum TestError: Error { case image }
}
