import CoreGraphics
import Foundation
import ImageIO

/// Display-only overview levels synthesized from the immutable signed tiles.
/// Two extra levels cap each output at 16 native tiles, decoded one at a time.
nonisolated enum TopographyContourOverview {
    typealias TileLoader = (_ z: Int, _ x: Int, _ y: Int, _ scale: Int) throws -> Data?
    enum OverviewError: Error { case sourceTile, outputTile }

    static let minimumZoom = 7
    static let nativeMinimumZoom = 9
    static let maximumZoom = 16

    static func tile(
        z: Int, x: Int, y: Int, scale: Int,
        loader: TileLoader
    ) throws -> Data? {
        guard (minimumZoom...maximumZoom).contains(z), (1...2).contains(scale),
              x >= 0, y >= 0, x < (1 << z), y < (1 << z) else { return nil }
        try Task.checkCancellation()
        if z >= nativeMinimumZoom { return try loader(z, x, y, scale) }
        let side = 256 * scale
        let factor = 1 << (nativeMinimumZoom - z)
        var context: CGContext?
        let childSide = side / factor
        var found = false
        for row in 0..<factor {
            for column in 0..<factor {
                try Task.checkCancellation()
                guard let data = try loader(
                    nativeMinimumZoom, x * factor + column, y * factor + row, scale
                ) else { continue }
                guard let source = CGImageSourceCreateWithData(
                    data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
                ), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      image.width == side, image.height == side else {
                    throw OverviewError.sourceTile
                }
                if context == nil {
                    context = CGContext(
                        data: nil, width: side, height: side, bitsPerComponent: 8,
                        bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                            CGBitmapInfo.byteOrder32Big.rawValue
                    )
                    context?.interpolationQuality = .high
                }
                guard let context else { throw OverviewError.outputTile }
                // XYZ rows increase southward; bitmap drawing rectangles
                // use a lower-left origin. Keep the child's pixels upright.
                context.draw(image, in: CGRect(
                    x: column * childSide, y: (factor - 1 - row) * childSide,
                    width: childSide, height: childSide
                ))
                found = true
            }
        }
        try Task.checkCancellation()
        guard found else { return nil }
        guard let image = context?.makeImage() else {
            throw OverviewError.outputTile
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.png" as CFString, 1, nil
        ) else { throw OverviewError.outputTile }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw OverviewError.outputTile
        }
        return output as Data
    }
}
