import Foundation

/// Coordinate-space conversion shared by iPhone route export and Watch
/// online routing. Core Location positions are WGS-84; Apple route geometry
/// is GCJ-02 inside `MainlandChinaRegion` and WGS-84 elsewhere.
nonisolated enum RouteCoordinateNormalizationV1 {
    /// `NavigationRouteV1.normalizationVersion` of routes normalized from Apple
    /// Maps. Version 1 treated a rectangle from 0.8293 to 55.8271° N and 72.004
    /// to 135.5° E as GCJ-02, which also shifted Hong Kong, Macau, Taiwan and
    /// neighbouring countries; version 2 uses `MainlandChinaRegion`.
    static let mapKitVersion: UInt16 = 2

    static func isInMainlandChina(_ coordinate: RouteCoordinateV1) -> Bool {
        MainlandChinaRegion.contains(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    /// `reference` is a known WGS-84 position, such as the GPS fix a location
    /// was made from. It settles a coordinate shared across a mainland border
    /// only when it lies at one of the two readings.
    static func mapKitToWGS84(
        _ coordinate: RouteCoordinateV1,
        near reference: RouteCoordinateV1? = nil
    ) -> RouteCoordinateV1 {
        let converted = GCJ02.wgs84(
            fromMapKit: coordinate.latitude,
            longitude: coordinate.longitude,
            near: reference.map { (latitude: $0.latitude, longitude: $0.longitude) }
        )
        return RouteCoordinateV1(
            latitude: converted.latitude,
            longitude: converted.longitude
        )
    }

    /// Normalizes Apple route geometry in order. A coordinate that a mainland
    /// border makes ambiguous keeps the side of the point before it, so a route
    /// that stays on one side reads correctly however far apart its points
    /// are. `start`, where the route was requested from, is the reference for
    /// the first point. Past a border crossing, a route is misread until it
    /// leaves the few hundred metres where both readings exist.
    static func mapKitToWGS84(
        _ coordinates: [RouteCoordinateV1],
        startingNear start: RouteCoordinateV1?
    ) -> [RouteCoordinateV1] {
        var inMainland: Bool?
        return coordinates.map { coordinate in
            let point: RouteCoordinateV1
            if let inMainland {
                let converted = GCJ02.wgs84(
                    fromMapKit: coordinate.latitude,
                    longitude: coordinate.longitude,
                    inMainland: inMainland
                )
                point = RouteCoordinateV1(
                    latitude: converted.latitude,
                    longitude: converted.longitude
                )
            } else {
                point = mapKitToWGS84(coordinate, near: start)
            }
            inMainland = isInMainlandChina(point)
            return point
        }
    }

    static func wgs84ToMapKit(
        _ coordinate: RouteCoordinateV1
    ) -> RouteCoordinateV1 {
        let converted = GCJ02.mapKit(
            fromWGS84: coordinate.latitude,
            longitude: coordinate.longitude
        )
        return RouteCoordinateV1(
            latitude: converted.latitude,
            longitude: converted.longitude
        )
    }
}
