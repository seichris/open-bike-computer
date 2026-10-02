import CoreGraphics
import Foundation
import ImageIO

/// The signed contour companion uses WGS-84 XYZ pixels. Mainland-China Apple
/// Maps uses GCJ-02 coordinates for overlays, so each requested MapKit pixel
/// must look up its contour colour at the corresponding WGS-84 pixel. This
/// changes only the iPhone presentation; the saved and device artifacts stay
/// in WGS-84.
nonisolated enum TopographyMapKitTileWarp {
    typealias TileLoader = @Sendable (_ z: Int, _ x: Int, _ y: Int, _ scale: Int) async throws -> Data?

    private struct TileKey: Hashable { let x: Int; let y: Int }
    private struct Point { let x: Double; let y: Double }
    private static let tileSide = 256

    enum WarpError: Error { case sourceTile, outputTile, extent }

    static func sourcePixel(
        forMapKitPixelX x: Double,
        y: Double,
        zoom: Int,
        scale: Int
    ) -> (x: Double, y: Double) {
        let world = Double(tileSide * scale) * Double(1 << zoom)
        let longitude = x / world * 360 - 180
        let latitude = atan(sinh(.pi * (1 - 2 * y / world))) * 180 / .pi
        let wgs = CoordinateConverter.gcj02ToWGS84(lat: latitude, lon: longitude)
        let radians = wgs.lat * .pi / 180
        return (
            (wgs.lon + 180) / 360 * world,
            (1 - asinh(tan(radians)) / .pi) / 2 * world
        )
    }

    static func tile(
        z: Int,
        x: Int,
        y: Int,
        scale: Int,
        loader: TileLoader
    ) async throws -> Data? {
        guard (9...16).contains(z), scale == 1 || scale == 2,
              x >= 0, y >= 0, x < (1 << z), y < (1 << z) else { return nil }

        let side = tileSide * scale
        let step = 32 * scale
        let count = side / step
        let originX = Double(x * side)
        let originY = Double(y * side)
        let centerLongitude = (originX + Double(side) / 2) /
            (Double(side) * Double(1 << z)) * 360 - 180
        let centerLatitude = atan(sinh(.pi * (
            1 - 2 * (originY + Double(side) / 2) /
                (Double(side) * Double(1 << z))
        ))) * 180 / .pi
        guard CoordinateConverter.isInChina(lat: centerLatitude, lon: centerLongitude) else {
            return try await loader(z, x, y, scale)
        }

        var grid = [Point]()
        grid.reserveCapacity((count + 1) * (count + 1))
        for row in 0...count {
            for column in 0...count {
                let point = sourcePixel(
                    forMapKitPixelX: originX + Double(column * step),
                    y: originY + Double(row * step),
                    zoom: z,
                    scale: scale
                )
                grid.append(Point(x: point.x, y: point.y))
            }
        }
        let minX = Int(floor(grid.map(\.x).min()! - 0.5))
        let maxX = Int(floor(grid.map(\.x).max()! - 0.5)) + 1
        let minY = Int(floor(grid.map(\.y).min()! - 0.5))
        let maxY = Int(floor(grid.map(\.y).max()! - 0.5)) + 1
        let firstTileX = Int(floor(Double(minX) / Double(side)))
        let lastTileX = Int(floor(Double(maxX) / Double(side)))
        let firstTileY = Int(floor(Double(minY) / Double(side)))
        let lastTileY = Int(floor(Double(maxY) / Double(side)))
        guard firstTileX >= 0, firstTileY >= 0,
              lastTileX < (1 << z), lastTileY < (1 << z),
              lastTileX - firstTileX <= 2, lastTileY - firstTileY <= 2 else {
            throw WarpError.extent
        }

        var tiles: [TileKey: [UInt8]] = [:]
        for tileY in firstTileY...lastTileY {
            for tileX in firstTileX...lastTileX {
                try Task.checkCancellation()
                if let data = try await loader(z, tileX, tileY, scale) {
                    tiles[TileKey(x: tileX, y: tileY)] = try decode(data, side: side)
                }
            }
        }
        guard !tiles.isEmpty else { return nil }

        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ), let output = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw WarpError.outputTile
        }
        for pixelY in 0..<side {
            try Task.checkCancellation()
            let cellY = pixelY / step
            let fractionalY = (Double(pixelY) + 0.5 - Double(cellY * step)) / Double(step)
            for pixelX in 0..<side {
                let cellX = pixelX / step
                let fractionalX = (Double(pixelX) + 0.5 - Double(cellX * step)) / Double(step)
                let upperLeft = grid[cellY * (count + 1) + cellX]
                let upperRight = grid[cellY * (count + 1) + cellX + 1]
                let lowerLeft = grid[(cellY + 1) * (count + 1) + cellX]
                let lowerRight = grid[(cellY + 1) * (count + 1) + cellX + 1]
                let sourceX = interpolate(
                    upperLeft.x, upperRight.x, lowerLeft.x, lowerRight.x,
                    fractionalX, fractionalY
                ) - 0.5
                let sourceY = interpolate(
                    upperLeft.y, upperRight.y, lowerLeft.y, lowerRight.y,
                    fractionalX, fractionalY
                ) - 0.5
                let left = Int(floor(sourceX))
                let top = Int(floor(sourceY))
                let fractionX = sourceX - Double(left)
                let fractionY = sourceY - Double(top)
                let outputIndex = (pixelY * side + pixelX) * 4
                for channel in 0..<4 {
                    let a = component(atX: left, y: top, channel: channel, side: side, tiles: tiles)
                    let b = component(atX: left + 1, y: top, channel: channel, side: side, tiles: tiles)
                    let c = component(atX: left, y: top + 1, channel: channel, side: side, tiles: tiles)
                    let d = component(atX: left + 1, y: top + 1, channel: channel, side: side, tiles: tiles)
                    output[outputIndex + channel] = UInt8(
                        (interpolate(a, b, c, d, fractionX, fractionY))
                            .rounded().clamped(to: 0...255)
                    )
                }
            }
        }
        guard let image = context.makeImage() else { throw WarpError.outputTile }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            result, "public.png" as CFString, 1, nil
        ) else { throw WarpError.outputTile }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WarpError.outputTile }
        return result as Data
    }

    private static func decode(_ data: Data, side: Int) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == side, image.height == side,
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue
              ), let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw WarpError.sourceTile
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return Array(UnsafeBufferPointer(start: pixels, count: side * side * 4))
    }

    private static func interpolate(
        _ a: Double, _ b: Double, _ c: Double, _ d: Double,
        _ x: Double, _ y: Double
    ) -> Double {
        (a * (1 - x) + b * x) * (1 - y) + (c * (1 - x) + d * x) * y
    }

    private static func component(
        atX x: Int, y: Int, channel: Int, side: Int,
        tiles: [TileKey: [UInt8]]
    ) -> Double {
        let tileX = Int(floor(Double(x) / Double(side)))
        let tileY = Int(floor(Double(y) / Double(side)))
        guard let tile = tiles[TileKey(x: tileX, y: tileY)] else { return 0 }
        let localX = x - tileX * side
        let localY = y - tileY * side
        return Double(tile[(localY * side + localX) * 4 + channel])
    }
}

private extension Double {
    func clamped(to bounds: ClosedRange<Double>) -> Double {
        min(max(self, bounds.lowerBound), bounds.upperBound)
    }
}
