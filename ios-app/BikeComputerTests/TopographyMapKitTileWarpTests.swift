import CoreGraphics
import Foundation
import ImageIO

@main
struct TopographyMapKitTileWarpTests {
    static func main() async throws {
        var coverage = ContourLabelCoverage()
        let visible = CGRect(x: 100, y: 100, width: 300, height: 300)
        precondition(coverage.queryRect(for: visible) != nil)
        for _ in 0..<100 { precondition(coverage.queryRect(for: visible) == nil) }
        precondition(coverage.queryRect(for: visible.offsetBy(dx: 10, dy: 10)) == nil)
        precondition(coverage.queryRect(for: visible.offsetBy(dx: 300, dy: 0)) != nil)
        precondition(coverage.queryRect(for: CGRect(x: 100, y: 100, width: 10, height: 10)) != nil)
        var route = ContourRouteOccupancy(bounds: CGRect(x: 0, y: 0, width: 400, height: 400))
        for i in 0..<10000 {
            route.add(CGPoint(x: -1000, y: i), CGPoint(x: -900, y: i + 1))
        }
        precondition(!route.intersects(CGRect(x: 40, y: 40, width: 50, height: 20)))
        route.add(CGPoint(x: -100, y: -100), CGPoint(x: 500, y: 500))
        precondition(route.intersects(CGRect(x: 180, y: 180, width: 50, height: 20)))
        precondition(!route.intersects(CGRect(x: 50, y: 300, width: 50, height: 20)), "diagonal bbox is not occupied")
        route.add(CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 100))
        precondition(route.intersects(CGRect(x: 195, y: 95, width: 10, height: 10)))
        for scale in [1, 2] {
            try await chinaControlPoint(scale: scale)
            try await overviewPlacement(scale: scale)
            try overzoomPlacement(scale: scale)
            try await chinaControlPoint(scale: scale, zoom: 22)
            for zoom in [16, 20] {
                try await borderControlPoints(scale: scale, zoom: zoom)
            }
            try await gapControlPoint(scale: scale)
        }
        try await overviewLimits()
        let unchanged = Data([1, 2, 3])
        let outside = try await TopographyMapKitTileWarp.tile(
            z: 12, x: 2048, y: 1362, scale: 1
        ) { _, _, _, _ in unchanged }
        precondition(outside == unchanged, "non-China tiles must retain their signed bytes")
        let hongKong = try await TopographyMapKitTileWarp.tile(
            z: 12, x: 3346, y: 1787, scale: 1
        ) { _, _, _, _ in unchanged }
        precondition(hongKong == unchanged, "Hong Kong uses WGS-84 in Apple Maps, so its tiles are not warped")
        print("TopographyMapKitTileWarpTests passed")
    }

    private final class Reads {
        var values: [[Int]] = []
        func record(_ z: Int, _ x: Int, _ y: Int, _ scale: Int) {
            values.append([z, x, y, scale])
        }
    }

    private static func overviewPlacement(scale: Int) async throws {
        let side = 256 * scale
        let png = try markedTile(side: side, x: side / 4, y: side / 4)
        for zoom in [7, 8] {
            let factor = 1 << (9 - zoom)
            // Test each corner separately: XYZ north/south and the mark's
            // within-child orientation must both survive downsampling.
            for row in [0, factor - 1] {
                for column in [0, factor - 1] {
                    let reads = Reads()
                    let output = try TopographyContourOverview.tile(
                        z: zoom, x: 3, y: 4, scale: scale
                    ) { z, x, y, s in
                        reads.record(z, x, y, s)
                        return x == 3 * factor + column && y == 4 * factor + row ? png : nil
                    }
                    guard let output else { preconditionFailure("missing overview") }
                    let childSide = side / factor
                    let expectedAlpha = try alpha(output, side: side,
                        x: column * childSide + childSide / 4,
                        y: row * childSide + childSide / 4)
                    precondition(expectedAlpha > 128,
                        "overview must preserve XYZ and within-child orientation")
                    let absentAlpha = try alpha(output, side: side,
                        x: (factor - 1 - column) * childSide + childSide / 4,
                        y: (factor - 1 - row) * childSide + childSide / 4)
                    precondition(absentAlpha == 0,
                        "missing child tiles must stay transparent")
                    let requested = reads.values
                    precondition(requested.count == factor * factor && requested.count <= 16)
                    precondition(requested.allSatisfy { $0[0] == 9 && $0[3] == scale })
                }
            }
            // China presentation must accept both overview levels, using the
            // same display-tile loader as the physical app.
            let location = pixel(lat: 31.04, lon: 103.5, zoom: zoom, side: side)
            let x = Int(location.x) / side, y = Int(location.y) / side
            let aligned = try await TopographyMapKitTileWarp.tile(z: zoom, x: x, y: y, scale: scale) {
                z, x, y, s in
                try TopographyContourOverview.tile(z: z, x: x, y: y, scale: s) {
                    _, _, _, _ in png
                }
            }
            precondition(aligned != nil, "China warp must retain overview contours")
        }
        let native = try TopographyContourOverview.tile(z: 9, x: 3, y: 4, scale: scale) {
            z, x, y, s in
            precondition(z == 9 && x == 3 && y == 4 && s == scale)
            return png
        }
        precondition(native == png, "native signed tile bytes must remain unchanged")
    }

    private static func overzoomPlacement(scale: Int) throws {
        let side = 256 * scale
        for zoom in [17, 18, 22] {
            let factor = 1 << (zoom - 16), childSide = side / factor
            for row in [0, factor - 1] {
                for column in [0, factor - 1] {
                    let png = try markedTile(side: side,
                        x: column * childSide + childSide / 2,
                        y: row * childSide + childSide / 2,
                        radius: max(0, childSide / 2 - 1))
                    let reads = Reads()
                    let output = try TopographyContourOverview.tile(
                        z: zoom, x: 5 * factor + column, y: 6 * factor + row, scale: scale
                    ) { z, x, y, s in
                        reads.record(z, x, y, s)
                        precondition(z == 16 && x == 5 && y == 6 && s == scale)
                        return png
                    }
                    guard let output else { preconditionFailure("missing enlarged tile") }
                    let value = try alpha(output, side: side, x: side / 2, y: side / 2)
                    precondition(value > 128, "close zoom must crop the correct XYZ child")
                    precondition(reads.values.count == 1, "close zoom reads just one verified parent")
                }
            }
        }
    }

    private static func overviewLimits() async throws {
        for path in [[6, 0, 0, 1], [23, 0, 0, 1], [7, -1, 0, 1],
                     [7, 128, 0, 1], [7, 0, 128, 1], [7, 0, 0, 3],
                     [Int.max, 0, 0, 1]] {
            let output = try TopographyContourOverview.tile(
                z: path[0], x: path[1], y: path[2], scale: path[3]
            ) { _, _, _, _ in preconditionFailure("invalid path reached storage") }
            precondition(output == nil)
        }
        let empty = try TopographyContourOverview.tile(z: 7, x: 0, y: 0, scale: 1) {
            _, _, _, _ in nil
        }
        precondition(empty == nil)
        for bad in [Data([1, 2, 3]), try markedTile(side: 128, x: 32, y: 32)] {
            do {
                _ = try TopographyContourOverview.tile(z: 8, x: 0, y: 0, scale: 1) {
                    _, _, _, _ in bad
                }
                preconditionFailure("invalid source image was accepted")
            } catch TopographyContourOverview.OverviewError.sourceTile { }
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try TopographyContourOverview.tile(z: 7, x: 0, y: 0, scale: 1) {
                _, _, _, _ in preconditionFailure("cancelled task reached storage")
            }
        }
        do { _ = try await cancelled.value; preconditionFailure("cancellation was ignored") }
        catch is CancellationError { }
    }

    private static func chinaControlPoint(scale: Int, zoom: Int = 16) async throws {
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
        let targetX = Int(target.x) - targetTileX * side
        let targetY = Int(target.y) - targetTileY * side
        let nativeZoom = min(zoom, 16)
        let native = pixel(lat: wgs.lat, lon: wgs.lon, zoom: nativeZoom, side: side)
        let nativeX = Int(native.x) / side, nativeY = Int(native.y) / side
        let sourcePNG = try markedTile(side: side, x: Int(native.x) % side, y: Int(native.y) % side)
        let sourceAlpha = try alpha(sourcePNG, side: side, x: Int(native.x) % side, y: Int(native.y) % side)
        precondition(sourceAlpha > 200,
                     "source image orientation is incorrect")
        let output = try await TopographyMapKitTileWarp.tile(
            z: zoom, x: targetTileX, y: targetTileY, scale: scale
        ) { _, x, y, _ in
            try TopographyContourOverview.tile(z: zoom, x: x, y: y, scale: scale) { z, x, y, _ in
                precondition(z == nativeZoom)
                return x == nativeX && y == nativeY ? sourcePNG : nil
            }
        }
        guard let output else { preconditionFailure("warped tile is missing") }
        let targetAlpha = try alpha(output, side: side, x: targetX, y: targetY)
        precondition(targetAlpha > 128,
                     "contour did not move to its GCJ-aligned MapKit location")
    }

    /// A Shenzhen position just inside the border and a Hong Kong position
    /// whose Apple Maps pixel lies just across the shifted border line. The
    /// warp must place each mark where Apple Maps draws it: interpolating a
    /// cell across that line would smear both, and at zoom 20 the two sides'
    /// sources are too far apart for a single source window.
    private static func borderControlPoints(scale: Int, zoom: Int) async throws {
        let side = 256 * scale
        // Walk from Shenzhen towards Sheung Shui to the border.
        var inside = (lat: 22.5431, lon: 114.0579)
        var outside = (lat: 22.5011, lon: 114.1281)
        for _ in 0..<60 {
            let middle = (lat: (inside.lat + outside.lat) / 2, lon: (inside.lon + outside.lon) / 2)
            if MainlandChinaRegion.contains(latitude: middle.lat, longitude: middle.lon) {
                inside = middle
            } else {
                outside = middle
            }
        }
        let gap = zoom >= 20 ? 3.0 : 20.0
        let heading = (lat: outside.lat - 22.5431, lon: outside.lon - 114.0579)
        let length = (heading.lat * heading.lat + heading.lon * heading.lon).squareRoot()
        func along(_ meters: Double) -> (lat: Double, lon: Double) {
            let degrees = meters / 111_320
            return (inside.lat + heading.lat / length * degrees, inside.lon + heading.lon / length * degrees)
        }
        let shenzhen = along(-gap)
        let acrossBorder = along(gap)
        let hongKong = GCJ02.fromWGS84(latitude: acrossBorder.lat, longitude: acrossBorder.lon)
        precondition(MainlandChinaRegion.contains(latitude: shenzhen.lat, longitude: shenzhen.lon) &&
                     !MainlandChinaRegion.contains(latitude: hongKong.latitude, longitude: hongKong.longitude),
                     "the control points lie on either side of the border")
        let shenzhenMapKit = GCJ02.mapKit(fromWGS84: shenzhen.lat, longitude: shenzhen.lon)
        let readBack = GCJ02.wgs84(fromMapKit: hongKong.latitude, longitude: hongKong.longitude)
        precondition(readBack.latitude == hongKong.latitude && readBack.longitude == hongKong.longitude,
                     "Apple Maps draws the Hong Kong position unshifted")
        let marks = [
            (source: pixel(lat: shenzhen.lat, lon: shenzhen.lon, zoom: zoom, side: side),
             target: pixel(lat: shenzhenMapKit.latitude, lon: shenzhenMapKit.longitude, zoom: zoom, side: side)),
            (source: pixel(lat: hongKong.latitude, lon: hongKong.longitude, zoom: zoom, side: side),
             target: pixel(lat: hongKong.latitude, lon: hongKong.longitude, zoom: zoom, side: side)),
        ]
        let distance = ((marks[0].target.x - marks[1].target.x) * (marks[0].target.x - marks[1].target.x) +
            (marks[0].target.y - marks[1].target.y) * (marks[0].target.y - marks[1].target.y)).squareRoot()
        precondition(distance < Double(64 * scale), "the two marks share a border cell or its neighbour")

        let nativeZoom = min(zoom, 16)
        let nativeMarks = [(lat: shenzhen.lat, lon: shenzhen.lon), (lat: hongKong.latitude, lon: hongKong.longitude)]
            .map { pixel(lat: $0.lat, lon: $0.lon, zoom: nativeZoom, side: side) }
        for mark in marks {
            let tileX = Int(floor(mark.target.x / Double(side)))
            let tileY = Int(floor(mark.target.y / Double(side)))
            let output = try await TopographyMapKitTileWarp.tile(
                z: zoom, x: tileX, y: tileY, scale: scale
            ) { _, x, y, _ in
                try TopographyContourOverview.tile(z: zoom, x: x, y: y, scale: scale) { z, x, y, _ in
                    precondition(z == nativeZoom)
                    let inTile = nativeMarks.filter {
                        Int($0.x) / side == x && Int($0.y) / side == y
                    }
                    guard !inTile.isEmpty else { return nil }
                    return try markedTile(side: side, points: inTile.map { (Int($0.x) % side, Int($0.y) % side) })
                }
            }
            guard let output else { preconditionFailure("border tile is missing") }
            let targetAlpha = try alpha(output, side: side,
                x: Int(mark.target.x) - tileX * side, y: Int(mark.target.y) - tileY * side)
            precondition(targetAlpha > 128,
                         "each side's contour lands where Apple Maps draws it (zoom \(zoom), scale \(scale))")
        }
    }

    /// At Khorgos GCJ-02 moves mainland China east, away from the Kazakh
    /// border, so Apple Maps pixels just inside the border have no terrain. A
    /// mark 100 m inside appears where Apple Maps draws it and leaves its own
    /// position transparent rather than drawn twice.
    private static func gapControlPoint(scale: Int, zoom: Int = 16) async throws {
        let side = 256 * scale
        var outside = (lat: 44.2, lon: 80.0)
        var inside = (lat: 44.2, lon: 80.8)
        for _ in 0..<60 {
            let middle = (lat: 44.2, lon: (inside.lon + outside.lon) / 2)
            if MainlandChinaRegion.contains(latitude: middle.lat, longitude: middle.lon) {
                inside = middle
            } else {
                outside = middle
            }
        }
        let mark = (lat: 44.2, lon: inside.lon + 100 / (111_320 * cos(44.2 * .pi / 180)))
        let drawn = GCJ02.mapKit(fromWGS84: mark.lat, longitude: mark.lon)
        let readAtMark = GCJ02.wgs84(fromMapKit: mark.lat, longitude: mark.lon)
        precondition(MainlandChinaRegion.contains(latitude: mark.lat, longitude: mark.lon) &&
                     readAtMark.latitude == mark.lat && readAtMark.longitude == mark.lon,
                     "the mark's own Apple Maps position is inside the region with no mainland reading")
        let source = pixel(lat: mark.lat, lon: mark.lon, zoom: zoom, side: side)
        let target = pixel(lat: drawn.latitude, lon: drawn.longitude, zoom: zoom, side: side)
        let sourceX = Int(source.x), sourceY = Int(source.y)
        func render(_ x: Int, _ y: Int) async throws -> Data {
            let output = try await TopographyMapKitTileWarp.tile(
                z: zoom, x: x / side, y: y / side, scale: scale
            ) { z, tileX, tileY, _ in
                tileX == sourceX / side && tileY == sourceY / side
                    ? try markedTile(side: side, x: sourceX % side, y: sourceY % side)
                    : nil
            }
            guard let output else { preconditionFailure("gap tile is missing") }
            return output
        }
        let targetX = Int(target.x), targetY = Int(target.y)
        let atTarget = try alpha(await render(targetX, targetY), side: side,
                                 x: targetX % side, y: targetY % side)
        let atSource = try alpha(await render(sourceX, sourceY), side: side,
                                 x: sourceX % side, y: sourceY % side)
        precondition(atTarget > 128 && atSource == 0,
                     "mainland terrain is drawn once, where Apple Maps draws it (scale \(scale))")
    }

    private static func pixel(
        lat: Double, lon: Double, zoom: Int, side: Int
    ) -> (x: Double, y: Double) {
        let world = Double(side * (1 << zoom))
        return ((lon + 180) / 360 * world,
                (1 - asinh(tan(lat * .pi / 180)) / .pi) / 2 * world)
    }

    private static func markedTile(side: Int, x: Int, y: Int, radius: Int = 4) throws -> Data {
        try markedTile(side: side, points: [(x, y)], radius: radius)
    }

    private static func markedTile(side: Int, points: [(Int, Int)], radius: Int = 4) throws -> Data {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue
        ), let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw TestError.image
        }
        for (x, y) in points {
            for row in max(0, y - radius)...min(side - 1, y + radius) {
                for column in max(0, x - radius)...min(side - 1, x + radius) {
                    let index = (row * side + column) * 4
                    bytes[index] = 255
                    bytes[index + 3] = 255
                }
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
