import Foundation

/// Coordinate-space conversion shared by iPhone route export and Watch
/// online routing. Core Location positions are WGS-84; Apple route geometry
/// in mainland China is represented in GCJ-02.
nonisolated enum RouteCoordinateNormalizationV1 {
    private static let earthSemiMajorAxis = 6_378_245.0
    private static let eccentricitySquared = 0.00669342162296594323

    static func isInMainlandChina(_ coordinate: RouteCoordinateV1) -> Bool {
        coordinate.latitude >= 0.8293 && coordinate.latitude <= 55.8271 &&
            coordinate.longitude >= 72.004 && coordinate.longitude <= 135.5
    }

    static func mapKitToWGS84(
        _ coordinate: RouteCoordinateV1
    ) -> RouteCoordinateV1 {
        guard isInMainlandChina(coordinate) else { return coordinate }
        var latitude = coordinate.latitude
        var longitude = coordinate.longitude
        for _ in 0..<3 {
            let projected = wgs84ToMapKit(RouteCoordinateV1(
                latitude: latitude,
                longitude: longitude
            ))
            latitude += coordinate.latitude - projected.latitude
            longitude += coordinate.longitude - projected.longitude
        }
        return RouteCoordinateV1(
            latitude: latitude,
            longitude: longitude
        )
    }

    static func wgs84ToMapKit(
        _ coordinate: RouteCoordinateV1
    ) -> RouteCoordinateV1 {
        guard isInMainlandChina(coordinate) else { return coordinate }
        let x = coordinate.longitude - 105
        let y = coordinate.latitude - 35
        var latitudeDelta = transformLatitude(x: x, y: y)
        var longitudeDelta = transformLongitude(x: x, y: y)
        let radians = coordinate.latitude / 180 * .pi
        var magic = sin(radians)
        magic = 1 - eccentricitySquared * magic * magic
        let squareRoot = sqrt(magic)
        latitudeDelta = latitudeDelta * 180 /
            ((earthSemiMajorAxis * (1 - eccentricitySquared)) /
                (magic * squareRoot) * .pi)
        longitudeDelta = longitudeDelta * 180 /
            (earthSemiMajorAxis / squareRoot * cos(radians) * .pi)
        return RouteCoordinateV1(
            latitude: coordinate.latitude + latitudeDelta,
            longitude: coordinate.longitude + longitudeDelta
        )
    }

    private static func transformLatitude(x: Double, y: Double) -> Double {
        var value = -100 + 2 * x + 3 * y + 0.2 * y * y +
            0.1 * x * y + 0.2 * sqrt(abs(x))
        value += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        value += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
        value += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
        return value
    }

    private static func transformLongitude(x: Double, y: Double) -> Double {
        var value = 300 + x + 2 * y + 0.1 * x * x +
            0.1 * x * y + 0.1 * sqrt(abs(x))
        value += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        value += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
        value += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
        return value
    }
}
