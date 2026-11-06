import CoreGraphics
import Foundation
import ImageIO

/// The signed contour companion uses WGS-84 XYZ pixels. Apple Maps draws
/// mainland China in GCJ-02, so each requested MapKit pixel that Apple Maps
/// shifts looks up its contour colour at the corresponding WGS-84 pixel, and
/// every other pixel keeps its own. A tile across mainland China's border
/// samples one source area for each side. Where GCJ-02 moved mainland terrain
/// away from the border, the pixels it left behind stay transparent. This
/// changes only the iPhone presentation; the saved and device artifacts stay
/// in WGS-84.
nonisolated enum TopographyMapKitTileWarp {
    typealias TileLoader = @Sendable (_ z: Int, _ x: Int, _ y: Int, _ scale: Int) async throws -> Data?

    /// Where a MapKit pixel's colour comes from.
    private enum Reading {
        /// Outside mainland China: the pixel at the same position.
        case unshifted
        /// Mainland China: the WGS-84 pixel GCJ-02 moved here.
        case shifted
        /// Inside mainland China, but GCJ-02 moved this terrain elsewhere and
        /// nothing here: transparent.
        case empty
    }

    /// A source position in WGS-84 pixels, and how its MapKit pixel reads.
    private struct Point { let x: Double; let y: Double; let reading: Reading }

    /// The stitched source rectangle that one side of the border samples.
    private struct SourceWindow {
        let minX: Int
        let minY: Int
        let width: Int
        var pixels: [UInt8]
    }

    private static let tileSide = 256

    enum WarpError: Error { case sourceTile, outputTile, extent }

    static func sourcePixel(
        forMapKitPixelX x: Double,
        y: Double,
        zoom: Int,
        scale: Int
    ) -> (x: Double, y: Double) {
        let point = source(
            forMapKitPixelX: x, y: y,
            world: Double(tileSide * scale) * Double(1 << zoom)
        )
        return (point.x, point.y)
    }

    private static func source(forMapKitPixelX x: Double, y: Double, world: Double) -> Point {
        let longitude = x / world * 360 - 180
        let latitude = atan(sinh(.pi * (1 - 2 * y / world))) * 180 / .pi
        let wgs = GCJ02.wgs84(fromMapKit: latitude, longitude: longitude)
        guard wgs.latitude != latitude || wgs.longitude != longitude else {
            let inMainland = MainlandChinaRegion.contains(latitude: latitude, longitude: longitude)
            return Point(x: x, y: y, reading: inMainland ? .empty : .unshifted)
        }
        let radians = wgs.latitude * .pi / 180
        return Point(
            x: (wgs.longitude + 180) / 360 * world,
            y: (1 - asinh(tan(radians)) / .pi) / 2 * world,
            reading: .shifted
        )
    }

    static func tile(
        z: Int,
        x: Int,
        y: Int,
        scale: Int,
        loader: TileLoader
    ) async throws -> Data? {
        guard (TopographyContourOverview.minimumZoom...TopographyContourOverview.maximumZoom).contains(z), scale == 1 || scale == 2,
              x >= 0, y >= 0, x < (1 << z), y < (1 << z) else { return nil }

        let side = tileSide * scale
        let step = 32 * scale
        let count = side / step
        let originX = Double(x * side)
        let originY = Double(y * side)
        let world = Double(side) * Double(1 << z)
        func latitude(_ pixelY: Double) -> Double {
            atan(sinh(.pi * (1 - 2 * pixelY / world))) * 180 / .pi
        }
        // Tiles away from mainland China keep their signed bytes. The tile is
        // in MapKit space, so widen it by more than GCJ-02's largest offset.
        let margin = 0.02
        guard MainlandChinaRegion.coverage(
            south: latitude(originY + Double(side)) - margin,
            west: originX / world * 360 - 180 - margin,
            north: latitude(originY) + margin,
            east: (originX + Double(side)) / world * 360 - 180 + margin
        ) != .none else {
            return try await loader(z, x, y, scale)
        }

        func sample(_ pixelX: Double, _ pixelY: Double) -> Point {
            source(forMapKitPixelX: originX + pixelX, y: originY + pixelY, world: world)
        }
        var grid = [Point]()
        grid.reserveCapacity((count + 1) * (count + 1))
        for row in 0...count {
            for column in 0...count {
                grid.append(sample(Double(column * step), Double(row * step)))
            }
        }
        // Interpolating a cell that straddles the border would smear between
        // the two sides' source areas, so map each of its pixels exactly. Its
        // centre and edge midpoints also catch a border wiggle between corners.
        var exact: [Int: [Point]] = [:]
        for cellY in 0..<count {
            for cellX in 0..<count {
                let left = Double(cellX * step), top = Double(cellY * step)
                let half = Double(step) / 2, full = Double(step)
                let readings = [
                    grid[cellY * (count + 1) + cellX], grid[cellY * (count + 1) + cellX + 1],
                    grid[(cellY + 1) * (count + 1) + cellX], grid[(cellY + 1) * (count + 1) + cellX + 1],
                    sample(left + half, top + half), sample(left + half, top),
                    sample(left + half, top + full), sample(left, top + half), sample(left + full, top + half),
                ].map(\.reading)
                guard readings.contains(where: { $0 != readings[0] }) else { continue }
                var points = [Point]()
                points.reserveCapacity(step * step)
                for row in 0..<step {
                    try Task.checkCancellation()
                    for column in 0..<step {
                        points.append(sample(left + Double(column) + 0.5, top + Double(row) + 0.5))
                    }
                }
                exact[cellY * count + cellX] = points
            }
        }

        // Stitch only the sampled source rectangle of each side, with
        // transparent pixels for missing tiles. Sampling a dictionary of entire
        // RGBA arrays for every channel caused millions of hashes and
        // retain/release pairs per tile, delaying MapKit's replies during a zoom
        // gesture.
        var windows: [Reading: SourceWindow] = [:]
        var hasSource = false
        for reading in [Reading.unshifted, .shifted] {
            let points = grid.filter { $0.reading == reading } +
                exact.values.joined().filter { $0.reading == reading }
            guard let firstPoint = points.first else { continue }
            var lowX = firstPoint.x, highX = firstPoint.x
            var lowY = firstPoint.y, highY = firstPoint.y
            for point in points {
                lowX = min(lowX, point.x); highX = max(highX, point.x)
                lowY = min(lowY, point.y); highY = max(highY, point.y)
            }
            let minX = Int(floor(lowX - 0.5))
            let maxX = Int(floor(highX - 0.5)) + 1
            let minY = Int(floor(lowY - 0.5))
            let maxY = Int(floor(highY - 0.5)) + 1
            let firstTileX = Int(floor(Double(minX) / Double(side)))
            let lastTileX = Int(floor(Double(maxX) / Double(side)))
            let firstTileY = Int(floor(Double(minY) / Double(side)))
            let lastTileY = Int(floor(Double(maxY) / Double(side)))
            guard firstTileX >= 0, firstTileY >= 0,
                  lastTileX < (1 << z), lastTileY < (1 << z),
                  lastTileX - firstTileX <= 2, lastTileY - firstTileY <= 2 else {
                throw WarpError.extent
            }
            let sourceWidth = maxX - minX + 1
            let sourceHeight = maxY - minY + 1
            var window = SourceWindow(
                minX: minX, minY: minY, width: sourceWidth,
                pixels: [UInt8](repeating: 0, count: sourceWidth * sourceHeight * 4)
            )
            for tileY in firstTileY...lastTileY {
                for tileX in firstTileX...lastTileX {
                    try Task.checkCancellation()
                    if let data = try await loader(z, tileX, tileY, scale) {
                        let pixels = try decode(data, side: side)
                        hasSource = true
                        let left = max(minX, tileX * side)
                        let right = min(maxX + 1, (tileX + 1) * side)
                        let top = max(minY, tileY * side)
                        let bottom = min(maxY + 1, (tileY + 1) * side)
                        pixels.withUnsafeBufferPointer { input in
                            window.pixels.withUnsafeMutableBufferPointer { output in
                                for row in top..<bottom {
                                    let src = ((row - tileY * side) * side + left - tileX * side) * 4
                                    let dst = ((row - minY) * sourceWidth + left - minX) * 4
                                    output.baseAddress!.advanced(by: dst).update(
                                        from: input.baseAddress!.advanced(by: src),
                                        count: (right - left) * 4
                                    )
                                }
                            }
                        }
                    }
                }
            }
            windows[reading] = window
        }
        guard hasSource else { return nil }

        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ), let output = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw WarpError.outputTile
        }
        let empty = SourceWindow(minX: 0, minY: 0, width: 0, pixels: [])
        let unshifted = windows[.unshifted] ?? empty
        let shifted = windows[.shifted] ?? empty
        try unshifted.pixels.withUnsafeBufferPointer { unshiftedPixels in
            try shifted.pixels.withUnsafeBufferPointer { shiftedPixels in
                for pixelY in 0..<side {
                    try Task.checkCancellation()
                    let cellY = pixelY / step
                    let fractionalY = (Double(pixelY) + 0.5 - Double(cellY * step)) / Double(step)
                    for pixelX in 0..<side {
                        let cellX = pixelX / step
                        let sourceX: Double
                        let sourceY: Double
                        let reading: Reading
                        if let points = exact[cellY * count + cellX] {
                            let point = points[(pixelY - cellY * step) * step + pixelX - cellX * step]
                            sourceX = point.x - 0.5
                            sourceY = point.y - 0.5
                            reading = point.reading
                        } else {
                            let fractionalX = (Double(pixelX) + 0.5 - Double(cellX * step)) / Double(step)
                            let upperLeft = grid[cellY * (count + 1) + cellX]
                            let upperRight = grid[cellY * (count + 1) + cellX + 1]
                            let lowerLeft = grid[(cellY + 1) * (count + 1) + cellX]
                            let lowerRight = grid[(cellY + 1) * (count + 1) + cellX + 1]
                            sourceX = interpolate(
                                upperLeft.x, upperRight.x, lowerLeft.x, lowerRight.x,
                                fractionalX, fractionalY
                            ) - 0.5
                            sourceY = interpolate(
                                upperLeft.y, upperRight.y, lowerLeft.y, lowerRight.y,
                                fractionalX, fractionalY
                            ) - 0.5
                            reading = upperLeft.reading
                        }
                        let outputIndex = (pixelY * side + pixelX) * 4
                        guard reading != .empty else {
                            for channel in 0..<4 { output[outputIndex + channel] = 0 }
                            continue
                        }
                        let isShifted = reading == .shifted
                        let pixels = isShifted ? shiftedPixels : unshiftedPixels
                        let minX = isShifted ? shifted.minX : unshifted.minX
                        let minY = isShifted ? shifted.minY : unshifted.minY
                        let sourceWidth = isShifted ? shifted.width : unshifted.width
                        let left = Int(floor(sourceX))
                        let top = Int(floor(sourceY))
                        let fractionX = sourceX - Double(left)
                        let fractionY = sourceY - Double(top)
                        // Each side's window spans its points' extrema plus a
                        // one-pixel bilinear border, so all four neighbours are
                        // inside it.
                        let aIndex = ((top - minY) * sourceWidth + left - minX) * 4
                        let bIndex = aIndex + 4
                        let cIndex = aIndex + sourceWidth * 4
                        let dIndex = cIndex + 4
                        for channel in 0..<4 {
                            let a = Double(pixels[aIndex + channel])
                            let b = Double(pixels[bIndex + channel])
                            let c = Double(pixels[cIndex + channel])
                            let d = Double(pixels[dIndex + channel])
                            output[outputIndex + channel] = UInt8(
                                (interpolate(a, b, c, d, fractionX, fractionY))
                                    .rounded().clamped(to: 0...255)
                            )
                        }
                    }
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

}

private extension Double {
    func clamped(to bounds: ClosedRange<Double>) -> Double {
        min(max(self, bounds.lowerBound), bounds.upperBound)
    }
}
