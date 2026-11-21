import Foundation

/// The saved route around a temporary detour, for a Bicino One that draws it
/// as a second, muted line under the detour window (RTK1, CAP2 extended bit 7,
/// client 37). Devices without the bit keep the compatible single line: the
/// detour window replaces the route window during the detour.
///
/// Frame: "RTK1", version 1, operation (0 clear, 1 set). A set frame carries
/// the 2A6F point encoding: start latitude/longitude as Int32 microdegrees,
/// then Int16 deltas, little endian, 2...48 points.
nonisolated enum RouteReferenceTrackV1 {
    typealias Contract = RideBLEGeneratedProtocolV1

    /// Saved route shown behind the leave point and beyond the rejoin point.
    static let leadInMeters = 150.0
    static let leadOutMeters = 300.0
    /// Int16 deltas hold ±32,767 µdeg; longer segments are split well inside it.
    static let maximumDeltaMicrodegrees: Int64 = 30_000
    static let startPointBytes = 8
    static let deltaBytes = 4

    static var maximumFrameBytes: Int {
        Contract.routeReferenceTrackHeaderBytes + startPointBytes +
            deltaBytes * (Contract.routeReferenceTrackMaximumPoints - 1)
    }

    /// Most points one protected write of `writeLength` plaintext bytes holds,
    /// or nil when not even the minimum track fits.
    static func maximumPoints(forWriteLength writeLength: Int) -> Int? {
        let available = writeLength - Contract.routeReferenceTrackHeaderBytes - startPointBytes
        guard available >= 0 else { return nil }
        let points = min(1 + available / deltaBytes, Contract.routeReferenceTrackMaximumPoints)
        return points >= Contract.routeReferenceTrackMinimumPoints ? points : nil
    }

    /// The saved route from shortly before the last confirmed progress to past
    /// the rejoin point, in travel order.
    static func coordinates(
        geometry: SavedRouteGeometryV1,
        confirmedProgressMeters: Double,
        rejoinAlongMeters: Double
    ) -> [RouteCoordinateV1] {
        let total = geometry.totalMeters
        guard total > 0, geometry.route.points.count >= 2 else { return [] }
        let lower = min(max(confirmedProgressMeters - leadInMeters, 0), total)
        let upper = min(max(rejoinAlongMeters + leadOutMeters, lower), total)
        guard upper > lower else { return [] }
        var result = [geometry.coordinate(atDistance: lower)]
        for (index, point) in geometry.route.points.enumerated()
        where geometry.cumulative[index] > lower && geometry.cumulative[index] < upper {
            result.append(point)
        }
        result.append(geometry.coordinate(atDistance: upper))
        return result
    }

    /// Simplifies to at most `maximumPoints` encodable points, raising the
    /// Douglas–Peucker tolerance until the densified track fits.
    static func encodablePoints(
        _ coordinates: [RouteCoordinateV1],
        maximumPoints: Int
    ) -> [MicrodegreePoint]? {
        let limit = min(maximumPoints, Contract.routeReferenceTrackMaximumPoints)
        guard limit >= Contract.routeReferenceTrackMinimumPoints,
              coordinates.count >= 2, coordinates.allSatisfy(\.isValid) else { return nil }
        var tolerance = 2.0
        for _ in 0..<40 {
            let simplified = simplify(coordinates, toleranceMeters: tolerance)
            if let dense = densified(simplified.map(MicrodegreePoint.init)), dense.count <= limit {
                return dense.count >= Contract.routeReferenceTrackMinimumPoints ? dense : nil
            }
            tolerance *= 1.6
        }
        return nil
    }

    static func setFrame(_ points: [MicrodegreePoint]) -> Data? {
        guard (Contract.routeReferenceTrackMinimumPoints...Contract.routeReferenceTrackMaximumPoints)
            .contains(points.count),
              let first = points.first, first.isValid else { return nil }
        var data = header(.set)
        append(first.latitude, to: &data)
        append(first.longitude, to: &data)
        var previous = first
        for point in points.dropFirst() {
            guard point.isValid,
                  let deltaLatitude = Int16(exactly: Int64(point.latitude) - Int64(previous.latitude)),
                  let deltaLongitude = Int16(exactly: Int64(point.longitude) - Int64(previous.longitude))
            else { return nil }
            append(deltaLatitude, to: &data)
            append(deltaLongitude, to: &data)
            previous = point
        }
        return data
    }

    static func clearFrame() -> Data { header(.clear) }

    /// The complete set frame for the current detour, or nil when the track
    /// cannot be drawn (too short, or not encodable in `maximumPoints`).
    static func frame(
        geometry: SavedRouteGeometryV1,
        confirmedProgressMeters: Double,
        rejoinAlongMeters: Double,
        maximumPoints: Int
    ) -> Data? {
        let track = coordinates(
            geometry: geometry,
            confirmedProgressMeters: confirmedProgressMeters,
            rejoinAlongMeters: rejoinAlongMeters
        )
        guard let points = encodablePoints(track, maximumPoints: maximumPoints) else { return nil }
        return setFrame(points)
    }

    nonisolated struct MicrodegreePoint: Equatable, Sendable {
        let latitude: Int32
        let longitude: Int32

        init(latitude: Int32, longitude: Int32) {
            self.latitude = latitude
            self.longitude = longitude
        }

        init(_ coordinate: RouteCoordinateV1) {
            latitude = Int32((coordinate.latitude * 1_000_000).rounded())
            longitude = Int32((coordinate.longitude * 1_000_000).rounded())
        }

        var isValid: Bool {
            (-90_000_000...90_000_000).contains(latitude) &&
                (-180_000_000...180_000_000).contains(longitude)
        }
    }

    // MARK: - Private

    private static func header(_ operation: RideBLERouteReferenceTrackOperationV1) -> Data {
        var data = Data(Contract.routeReferenceTrackMagic.utf8)
        data.append(Contract.routeReferenceTrackVersion)
        data.append(operation.rawValue)
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// Splits segments whose deltas would not fit the Int16 encoding.
    private static func densified(_ points: [MicrodegreePoint]) -> [MicrodegreePoint]? {
        guard var previous = points.first else { return nil }
        var result = [previous]
        for point in points.dropFirst() {
            let deltaLatitude = Int64(point.latitude) - Int64(previous.latitude)
            let deltaLongitude = Int64(point.longitude) - Int64(previous.longitude)
            let span = max(abs(deltaLatitude), abs(deltaLongitude))
            let pieces = max(1, Int((span + maximumDeltaMicrodegrees - 1) / maximumDeltaMicrodegrees))
            // A track wider than the frame can ever hold (an antimeridian
            // crossing, for one) is not drawn.
            guard result.count + pieces <= Contract.routeReferenceTrackMaximumPoints * 4 else { return nil }
            if pieces > 1 {
                for piece in 1..<pieces {
                    let fraction = Double(piece) / Double(pieces)
                    result.append(MicrodegreePoint(
                        latitude: Int32(Double(previous.latitude) + Double(deltaLatitude) * fraction),
                        longitude: Int32(Double(previous.longitude) + Double(deltaLongitude) * fraction)
                    ))
                }
            }
            result.append(point)
            previous = point
        }
        return result
    }

    /// Douglas–Peucker in a local equirectangular frame (metres).
    private static func simplify(
        _ coordinates: [RouteCoordinateV1],
        toleranceMeters: Double
    ) -> [RouteCoordinateV1] {
        guard coordinates.count > 2 else { return coordinates }
        let origin = coordinates[0]
        let metersPerDegree = 111_320.0
        let cosLatitude = cos(origin.latitude * .pi / 180)
        let planar = coordinates.map {
            (x: ($0.longitude - origin.longitude) * metersPerDegree * cosLatitude,
             y: ($0.latitude - origin.latitude) * metersPerDegree)
        }
        var keep = [Bool](repeating: false, count: coordinates.count)
        keep[0] = true
        keep[coordinates.count - 1] = true
        var stack = [(0, coordinates.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            let a = planar[start]
            let b = planar[end]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            var farthest = start
            var farthestDistance = 0.0
            for index in (start + 1)..<end {
                let p = planar[index]
                let distance: Double
                if lengthSquared == 0 {
                    distance = hypot(p.x - a.x, p.y - a.y)
                } else {
                    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
                    distance = hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
                }
                if distance > farthestDistance {
                    farthestDistance = distance
                    farthest = index
                }
            }
            if farthestDistance > toleranceMeters {
                keep[farthest] = true
                stack.append((start, farthest))
                stack.append((farthest, end))
            }
        }
        return coordinates.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }
}
