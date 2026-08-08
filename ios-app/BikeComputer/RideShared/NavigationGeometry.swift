import Foundation

enum NavigationGeometryV1 {
    static let earthRadiusMeters = 6_371_008.8

    struct Projection: Equatable {
        let segmentIndex: Int
        let fraction: Double
        let crossTrackDistanceMeters: Double
        let distanceAlongRouteMeters: Double
    }

    static func distance(
        from start: RouteCoordinateV1,
        to end: RouteCoordinateV1
    ) -> Double {
        let latitude1 = radians(start.latitude)
        let latitude2 = radians(end.latitude)
        let latitudeDelta = latitude2 - latitude1
        let longitudeDelta = radians(end.longitude - start.longitude)
        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2) +
            cos(latitude1) * cos(latitude2) *
            sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return earthRadiusMeters * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    static func cumulativeDistances(for points: [RouteCoordinateV1]) -> [Double] {
        guard !points.isEmpty else { return [] }
        var result = [Double](repeating: 0, count: points.count)
        for index in 1..<points.count {
            result[index] = result[index - 1] + distance(
                from: points[index - 1],
                to: points[index]
            )
        }
        return result
    }

    static func projections(
        of target: RouteCoordinateV1,
        onto points: [RouteCoordinateV1],
        cumulativeDistances: [Double],
        segmentRange: Range<Int>? = nil
    ) -> [Projection] {
        guard points.count > 1, cumulativeDistances.count == points.count else {
            return []
        }
        let availableRange = 0..<(points.count - 1)
        let requestedRange = segmentRange ?? availableRange
        let lowerBound = max(requestedRange.lowerBound, availableRange.lowerBound)
        let upperBound = min(requestedRange.upperBound, availableRange.upperBound)
        guard lowerBound < upperBound else { return [] }
        return (lowerBound..<upperBound).compactMap { index in
            project(
                target: target,
                start: points[index],
                end: points[index + 1],
                segmentIndex: index,
                distanceBeforeSegment: cumulativeDistances[index]
            )
        }
    }

    static func compressedRouteWindow(
        points: [RouteCoordinateV1],
        startingAt index: Int,
        count: Int = 30
    ) -> Data? {
        guard !points.isEmpty, count > 0 else { return nil }
        let start = min(max(index, 0), points.count - 1)
        let end = min(start + count, points.count)
        let window = points[start..<end]
        guard let first = window.first else { return nil }

        var data = Data()
        var previousLatitude = scaledCoordinate(first.latitude)
        var previousLongitude = scaledCoordinate(first.longitude)
        appendLittleEndian(previousLatitude, to: &data)
        appendLittleEndian(previousLongitude, to: &data)

        for point in window.dropFirst() {
            let latitude = scaledCoordinate(point.latitude)
            let longitude = scaledCoordinate(point.longitude)
            let latitudeDelta = Int64(latitude) - Int64(previousLatitude)
            let longitudeDelta = Int64(longitude) - Int64(previousLongitude)
            guard let encodedLatitude = Int16(exactly: latitudeDelta),
                  let encodedLongitude = Int16(exactly: longitudeDelta) else {
                return nil
            }
            appendLittleEndian(encodedLatitude, to: &data)
            appendLittleEndian(encodedLongitude, to: &data)
            previousLatitude = latitude
            previousLongitude = longitude
        }
        return data
    }

    static func routeWindowStartIndex(for projection: Projection) -> Int {
        projection.segmentIndex + (projection.fraction >= 0.5 ? 1 : 0)
    }

    static func isRouteWindowDeltaEncodable(
        from start: RouteCoordinateV1,
        to end: RouteCoordinateV1
    ) -> Bool {
        let latitudeDelta = Int64(scaledCoordinate(end.latitude)) -
            Int64(scaledCoordinate(start.latitude))
        let longitudeDelta = Int64(scaledCoordinate(end.longitude)) -
            Int64(scaledCoordinate(start.longitude))
        return (Int64(Int16.min)...Int64(Int16.max)).contains(latitudeDelta) &&
            (Int64(Int16.min)...Int64(Int16.max)).contains(longitudeDelta)
    }

    private static func project(
        target: RouteCoordinateV1,
        start: RouteCoordinateV1,
        end: RouteCoordinateV1,
        segmentIndex: Int,
        distanceBeforeSegment: Double
    ) -> Projection? {
        let referenceLatitude = radians((start.latitude + end.latitude + target.latitude) / 3)
        let longitudeScale = earthRadiusMeters * cos(referenceLatitude)
        let latitudeScale = earthRadiusMeters
        let startX = radians(start.longitude) * longitudeScale
        let startY = radians(start.latitude) * latitudeScale
        let endX = radians(end.longitude) * longitudeScale
        let endY = radians(end.latitude) * latitudeScale
        let targetX = radians(target.longitude) * longitudeScale
        let targetY = radians(target.latitude) * latitudeScale
        let deltaX = endX - startX
        let deltaY = endY - startY
        let lengthSquared = deltaX * deltaX + deltaY * deltaY
        guard lengthSquared.isFinite, lengthSquared > 0 else { return nil }

        let rawFraction = ((targetX - startX) * deltaX +
                           (targetY - startY) * deltaY) / lengthSquared
        let fraction = min(max(rawFraction, 0), 1)
        let projectedX = startX + fraction * deltaX
        let projectedY = startY + fraction * deltaY
        let crossTrackDistance = hypot(targetX - projectedX, targetY - projectedY)
        let segmentDistance = distance(from: start, to: end)
        guard crossTrackDistance.isFinite, segmentDistance.isFinite else { return nil }

        return Projection(
            segmentIndex: segmentIndex,
            fraction: fraction,
            crossTrackDistanceMeters: crossTrackDistance,
            distanceAlongRouteMeters: distanceBeforeSegment + segmentDistance * fraction
        )
    }

    private static func radians(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }

    private static func scaledCoordinate(_ value: Double) -> Int32 {
        Int32(clamping: Int64((value * 1_000_000).rounded()))
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
