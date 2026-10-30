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

    static func mapKitToWGS84(
        _ coordinate: RouteCoordinateV1
    ) -> RouteCoordinateV1 {
        let converted = GCJ02.wgs84(
            fromMapKit: coordinate.latitude,
            longitude: coordinate.longitude
        )
        return RouteCoordinateV1(
            latitude: converted.latitude,
            longitude: converted.longitude
        )
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
