import Foundation

/// Coordinate-space conversion shared by iPhone route export and Watch
/// online routing. Core Location positions are WGS-84; Apple route geometry
/// is GCJ-02 inside `MainlandChinaRegion` and WGS-84 elsewhere.
nonisolated enum RouteCoordinateNormalizationV1 {
    /// `NavigationRouteV1.normalizationVersion` of routes normalized from Apple
    /// Maps. Version 1 treated a rectangle from 0.8293 to 55.8271° N and 72.004
    /// to 135.5° E as GCJ-02, which also shifted Hong Kong, Macau, Taiwan and
    /// neighbouring countries; version 2 uses `MainlandChinaRegion`. Saved
    /// version-1 routes are read with version 2 by `rereadVersion1`.
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

/// Apple Maps routes saved with normalization version 1. Their stored bytes
/// keep the archive's content hash, so they are read again rather than
/// rewritten.
nonisolated extension RouteCoordinateNormalizationV1 {
    static let rectangleVersion: UInt16 = 1

    /// Version 1 treated every Apple Maps coordinate in this rectangle as
    /// GCJ-02, mainland China's neighbours included.
    static func isInVersion1Rectangle(_ coordinate: RouteCoordinateV1) -> Bool {
        coordinate.latitude >= 0.8293 && coordinate.latitude <= 55.8271 &&
            coordinate.longitude >= 72.004 && coordinate.longitude <= 135.5
    }

    /// A saved route as version 2 reads it. Version 1 moved route points in
    /// its rectangle but outside mainland China, such as Hong Kong, Macau,
    /// Taiwan, Singapore or Korea, about 130 to 730 m off the road. Each point
    /// in the rectangle gets back the GCJ-02 shift version 1 removed, as the
    /// phone drew it then. That recovers its Apple Maps coordinate, which is
    /// read with version 2 in order. A point read as mainland keeps its stored
    /// value, which both versions compute the same way. Any other route, and a
    /// route the reading leaves unchanged or would make invalid, is returned
    /// as stored.
    static func rereadVersion1(_ route: NavigationRouteV1) -> NavigationRouteV1 {
        guard route.provider.providerID == RouteProviderPolicyV1.mapKit.providerID,
              route.normalizationVersion == rectangleVersion,
              route.points.contains(where: { isInVersion1Rectangle($0) }),
              let extent = RouteBoundsV1.enclosing(route.points) else {
            return route
        }
        let coverage = coverage(of: extent)
        // Wholly inside mainland China, every point reads as mainland.
        guard coverage != .all else { return route }
        let mapKit = route.points.map { point -> RouteCoordinateV1 in
            guard isInVersion1Rectangle(point) else { return point }
            let shifted = GCJ02.fromWGS84(latitude: point.latitude, longitude: point.longitude)
            return RouteCoordinateV1(latitude: shifted.latitude, longitude: shifted.longitude)
        }
        let points = coverage == .none
            ? mapKit
            : readNearMainland(stored: route.points, mapKit: mapKit)
        guard points != route.points,
              let first = points.first,
              let last = points.last,
              let bounds = RouteBoundsV1.enclosing(points) else {
            return route
        }
        let reread = NavigationRouteV1(
            id: route.id,
            revision: route.revision,
            provider: route.provider,
            sourceReference: route.sourceReference,
            localeIdentifier: route.localeIdentifier,
            transportType: route.transportType,
            source: RouteEndpointV1(coordinate: first, label: route.source.label),
            destination: RouteEndpointV1(coordinate: last, label: route.destination.label),
            bounds: bounds,
            distanceMeters: route.distanceMeters,
            expectedTravelTimeSeconds: route.expectedTravelTimeSeconds,
            name: route.name,
            points: points,
            steps: route.steps,
            normalizationVersion: mapKitVersion
        )
        // Only the coordinates differ, so the route must still pass every
        // check the stored one is held to.
        let limits = NavigationRouteLimitsV1(
            maximumPoints: route.points.count,
            maximumSteps: route.steps.count,
            maximumEncodedBytes: .max
        )
        guard (try? reread.validate(limits: limits)) != nil else { return route }
        return reread
    }

    /// How much of mainland China lies near the stored points. GCJ-02 moves
    /// a point less than 0.02°, so the margin holds every point's Apple Maps
    /// coordinate and both its readings.
    private static func coverage(of extent: RouteBoundsV1) -> MainlandChinaRegion.Coverage {
        let margin = 0.02
        return MainlandChinaRegion.coverage(
            south: extent.south - margin,
            west: extent.west - margin,
            north: extent.north + margin,
            east: extent.east + margin
        )
    }

    /// Version 2's in-order reading of a route near mainland China. A point
    /// with two readings keeps the side of the point before it. Version 2
    /// settles the first point with the position the route was requested
    /// from, which an archive does not keep, so the first point with a single
    /// reading gives that side instead. A point read as mainland keeps its
    /// stored value. Runs of points clear of the region's edge have one
    /// reading each, so only points near it are read one by one.
    private static func readNearMainland(
        stored: [RouteCoordinateV1],
        mapKit: [RouteCoordinateV1]
    ) -> [RouteCoordinateV1] {
        var inMainland = mapKit.lazy.compactMap { onlyReadingIsInMainland($0) }.first ?? true
        var points: [RouteCoordinateV1] = []
        points.reserveCapacity(stored.count)
        var start = 0
        while start < stored.count {
            let run = start..<min(start + 64, stored.count)
            start = run.upperBound
            guard let extent = RouteBoundsV1.enclosing(Array(stored[run])) else { continue }
            switch coverage(of: extent) {
            case .all:
                points += stored[run]
                inMainland = true
            case .none:
                points += mapKit[run]
                inMainland = false
            case .partial:
                // A reference at the outside reading selects it.
                let read = mapKitToWGS84(
                    Array(mapKit[run]),
                    startingNear: inMainland ? nil : mapKit[run.lowerBound]
                )
                for (index, reading) in zip(run, read) {
                    points.append(reading == mapKit[index] ? mapKit[index] : stored[index])
                }
                inMainland = read.last.map { isInMainlandChina($0) } ?? inMainland
            }
        }
        return points
    }

    /// Whether an Apple Maps coordinate's only reading lies in mainland
    /// China, or nil where a border gives it one reading on each side.
    private static func onlyReadingIsInMainland(_ coordinate: RouteCoordinateV1) -> Bool? {
        let mainland = GCJ02.wgs84(
            fromMapKit: coordinate.latitude,
            longitude: coordinate.longitude,
            inMainland: true
        )
        let outside = GCJ02.wgs84(
            fromMapKit: coordinate.latitude,
            longitude: coordinate.longitude,
            inMainland: false
        )
        guard mainland.latitude == outside.latitude,
              mainland.longitude == outside.longitude else {
            return nil
        }
        return isInMainlandChina(RouteCoordinateV1(latitude: mainland.latitude, longitude: mainland.longitude))
    }
}
