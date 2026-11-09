import CoreLocation
import Foundation
import MapKit

/// Kinds of place a rider can ask Siri to find along the route.
nonisolated enum RoutePlaceKind: String, CaseIterable, Sendable {
    case coffeeShop, restaurant, bakery, supermarket, convenienceStore
    case bikeShop, toilet, pharmacy, gasStation, hospital

    var spokenName: String {
        switch self {
        case .coffeeShop: return "coffee shop"
        case .restaurant: return "restaurant"
        case .bakery: return "bakery"
        case .supermarket: return "supermarket"
        case .convenienceStore: return "convenience store"
        case .bikeShop: return "bike shop"
        case .toilet: return "toilet"
        case .pharmacy: return "pharmacy"
        case .gasStation: return "gas station"
        case .hospital: return "hospital"
        }
    }

    var mapKitCategories: [MKPointOfInterestCategory] {
        switch self {
        case .coffeeShop: return [.cafe]
        case .restaurant: return [.restaurant]
        case .bakery: return [.bakery]
        case .supermarket: return [.foodMarket]
        case .toilet: return [.restroom]
        case .pharmacy: return [.pharmacy]
        case .gasStation: return [.gasStation]
        case .hospital: return [.hospital]
        // MapKit has no category for these; they are searched as text.
        case .convenienceStore, .bikeShop: return []
        }
    }

    /// Searched as text only where the structured endpoint has no coverage.
    var fallbackQueries: [String] {
        switch self {
        case .coffeeShop: return [String(localized: "cafe")]
        case .restaurant: return [String(localized: "restaurant")]
        case .bakery: return [String(localized: "bakery")]
        case .supermarket: return [String(localized: "supermarket")]
        case .toilet: return [String(localized: "public toilet")]
        case .pharmacy: return [String(localized: "pharmacy")]
        case .gasStation: return [String(localized: "gas station")]
        case .hospital: return [String(localized: "hospital")]
        case .convenienceStore, .bikeShop: return []
        }
    }

    var textQueries: [String] {
        switch self {
        case .convenienceStore: return [String(localized: "convenience store")]
        // The same queries as the map's Bicycle Shops & Repair filter.
        case .bikeShop: return [String(localized: "bike shop"), String(localized: "bicycle repair")]
        default: return []
        }
    }
}

nonisolated struct RoutePlace: Equatable, Sendable {
    let name: String
    /// Along the route from the rider, or straight-line when not navigating.
    let distanceMeters: CLLocationDistance
    /// From the route line; zero when not navigating.
    let offRouteMeters: CLLocationDistance
}

nonisolated enum RoutePlaceSearchOutcome: Equatable, Sendable {
    case onRoute([RoutePlace], searchedMeters: CLLocationDistance)
    case nearby([RoutePlace], radiusMeters: CLLocationDistance)
    case noLocation
    case busy
    case unavailable
}

/// The searched corridor ahead of the rider. WGS-84 throughout.
nonisolated enum RoutePlaceCorridor {
    static let searchRadiusMeters: CLLocationDistance = 1_000
    /// Twice the radius, so neighbouring circles meet along a straight route.
    static let searchSpacingMeters: CLLocationDistance = 2_000
    static let maximumSearches = 3
    static let maximumOffRouteMeters: CLLocationDistance = 250
    /// Matched progress can trail a place the rider is just passing.
    static let behindToleranceMeters: CLLocationDistance = 50
    static let maximumResults = 3
    static let maximumLocationAge: TimeInterval = 120
    static let maximumLocationAccuracyMeters: CLLocationAccuracy = 200

    /// Nearby answers need a recent fix; a suspended app can hold an old one.
    static func isUsable(_ location: CLLocation?, now: Date = Date()) -> Bool {
        guard let location,
              CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= maximumLocationAccuracyMeters else {
            return false
        }
        let age = now.timeIntervalSince(location.timestamp)
        return age >= -5 && age <= maximumLocationAge
    }

    /// Centres 1, 3 and 5 km ahead; a shorter remaining route gets fewer.
    static func searchCenters(
        points: [RouteCoordinateV1],
        cumulative: [Double],
        distanceAlongMeters start: Double
    ) -> [(coordinate: RouteCoordinateV1, distanceMeters: Double)] {
        guard points.count > 1, cumulative.count == points.count,
              let total = cumulative.last, start.isFinite else { return [] }
        var centers: [(coordinate: RouteCoordinateV1, distanceMeters: Double)] = []
        for index in 0..<maximumSearches {
            let distance = min(
                max(start, 0) + searchRadiusMeters + Double(index) * searchSpacingMeters,
                total
            )
            if let previous = centers.last, distance - previous.distanceMeters < searchRadiusMeters {
                break
            }
            guard let point = point(atDistance: distance, points: points, cumulative: cumulative) else {
                break
            }
            centers.append((point, distance))
        }
        return centers
    }

    static func point(
        atDistance distance: Double,
        points: [RouteCoordinateV1],
        cumulative: [Double]
    ) -> RouteCoordinateV1? {
        guard cumulative.count == points.count, let first = points.first else { return nil }
        guard distance > 0 else { return first }
        for index in 1..<points.count where cumulative[index] >= distance {
            let start = points[index - 1]
            let end = points[index]
            let length = cumulative[index] - cumulative[index - 1]
            let fraction = length > 0 ? (distance - cumulative[index - 1]) / length : 0
            return RouteCoordinateV1(
                latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                longitude: start.longitude + (end.longitude - start.longitude) * fraction
            )
        }
        return points.last
    }

    /// Segments between `start` and `end`, widened by the corridor so a place
    /// just outside the stretch finds the segment it really lies beside rather
    /// than the clamped end of a neighbouring one. Choosing by distance along
    /// the route keeps an out-and-back route's other leg out.
    static func searchSegments(cumulative: [Double], from start: Double, to end: Double) -> Range<Int> {
        guard cumulative.count > 1 else { return 0..<0 }
        let margin = behindToleranceMeters + maximumOffRouteMeters
        let lower = cumulative.lastIndex { $0 <= start - margin } ?? 0
        let upper = cumulative.firstIndex { $0 >= end + maximumOffRouteMeters } ?? (cumulative.count - 1)
        return lower..<max(lower, upper)
    }

    /// Where a place meets the route between `start` and `end`, or nil when it
    /// is behind the rider, past the searched stretch, or too far off it.
    static func position(
        of place: RouteCoordinateV1,
        points: [RouteCoordinateV1],
        cumulative: [Double],
        segments: Range<Int>,
        from start: Double,
        to end: Double
    ) -> (aheadMeters: Double, offRouteMeters: Double)? {
        let nearest = NavigationGeometryV1.projections(
            of: place,
            onto: points,
            cumulativeDistances: cumulative,
            segmentRange: segments
        )
        .min {
            ($0.crossTrackDistanceMeters, $0.distanceAlongRouteMeters) <
                ($1.crossTrackDistanceMeters, $1.distanceAlongRouteMeters)
        }
        guard let nearest,
              nearest.crossTrackDistanceMeters <= maximumOffRouteMeters,
              nearest.distanceAlongRouteMeters >= start - behindToleranceMeters,
              nearest.distanceAlongRouteMeters <= end else {
            return nil
        }
        return (max(0, nearest.distanceAlongRouteMeters - start), nearest.crossTrackDistanceMeters)
    }
}

/// Finds places for Siri with a bounded number of MapKit requests: at most
/// three search circles along the route, stopping at the first error. Results
/// follow `OnlinePOISearchSession`'s rules: they are only spoken and shown by
/// Siri, never saved, made into route endpoints, logged or sent to the device.
@MainActor
final class RoutePlaceSearch {
    typealias Search = @MainActor (
        _ kind: RoutePlaceKind,
        _ center: CLLocationCoordinate2D,
        _ radius: CLLocationDistance
    ) async throws -> [MKMapItem]

    private let search: Search

    init(search: Search? = nil) {
        if let search {
            self.search = search
        } else {
            let provider = MapKitOnlinePOISearchProvider()
            self.search = { kind, center, radius in
                try await provider.search(
                    pointOfInterestCategories: kind.mapKitCategories,
                    fallbackQueries: kind.fallbackQueries,
                    textQueries: kind.textQueries,
                    center: center,
                    radius: radius
                ).items
            }
        }
    }

    /// `route` points are WGS-84, as is `location`.
    func find(
        _ kind: RoutePlaceKind,
        route: (points: [RouteCoordinateV1], distanceAlongMeters: Double)?,
        location: CLLocation?
    ) async -> RoutePlaceSearchOutcome {
        if let route {
            let cumulative = NavigationGeometryV1.cumulativeDistances(for: route.points)
            let centers = RoutePlaceCorridor.searchCenters(
                points: route.points,
                cumulative: cumulative,
                distanceAlongMeters: route.distanceAlongMeters
            )
            if let last = centers.last {
                return await findOnRoute(
                    kind,
                    points: route.points,
                    cumulative: cumulative,
                    start: max(route.distanceAlongMeters, 0),
                    end: min(
                        last.distanceMeters + RoutePlaceCorridor.searchRadiusMeters,
                        cumulative.last ?? last.distanceMeters
                    ),
                    centers: centers.map(\.coordinate)
                )
            }
        }
        guard let location, RoutePlaceCorridor.isUsable(location) else {
            return .noLocation
        }
        return await findNearby(kind, around: RouteCoordinateV1(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        ))
    }

    private func findOnRoute(
        _ kind: RoutePlaceKind,
        points: [RouteCoordinateV1],
        cumulative: [Double],
        start: Double,
        end: Double,
        centers: [RouteCoordinateV1]
    ) async -> RoutePlaceSearchOutcome {
        let segments = RoutePlaceCorridor.searchSegments(cumulative: cumulative, from: start, to: end)
        var found: [(place: RoutePlace, coordinate: RouteCoordinateV1)] = []
        for center in centers {
            let candidates: [(name: String, coordinate: RouteCoordinateV1)]
            do {
                candidates = try await places(kind, around: center)
            } catch {
                // Never fan out after an error; keep what earlier circles found.
                guard !found.isEmpty else { return Self.failure(error) }
                break
            }
            for candidate in candidates {
                guard let position = RoutePlaceCorridor.position(
                    of: candidate.coordinate,
                    points: points,
                    cumulative: cumulative,
                    segments: segments,
                    from: start,
                    to: end
                ), !Self.isDuplicate(candidate, in: found.map { ($0.place.name, $0.coordinate) }) else {
                    continue
                }
                found.append((RoutePlace(
                    name: candidate.name,
                    distanceMeters: position.aheadMeters,
                    offRouteMeters: position.offRouteMeters
                ), candidate.coordinate))
            }
            if found.count >= RoutePlaceCorridor.maximumResults { break }
        }
        let places = found.map(\.place).sorted {
            ($0.distanceMeters, $0.offRouteMeters) < ($1.distanceMeters, $1.offRouteMeters)
        }
        return .onRoute(
            Array(places.prefix(RoutePlaceCorridor.maximumResults)),
            searchedMeters: max(0, end - start)
        )
    }

    private func findNearby(
        _ kind: RoutePlaceKind,
        around rider: RouteCoordinateV1
    ) async -> RoutePlaceSearchOutcome {
        let candidates: [(name: String, coordinate: RouteCoordinateV1)]
        do {
            candidates = try await places(kind, around: rider)
        } catch {
            return Self.failure(error)
        }
        var found: [(place: RoutePlace, coordinate: RouteCoordinateV1)] = []
        for candidate in candidates {
            let distance = NavigationGeometryV1.distance(from: rider, to: candidate.coordinate)
            guard distance <= RoutePlaceCorridor.searchRadiusMeters,
                  !Self.isDuplicate(candidate, in: found.map { ($0.place.name, $0.coordinate) }) else {
                continue
            }
            found.append((RoutePlace(name: candidate.name, distanceMeters: distance, offRouteMeters: 0),
                          candidate.coordinate))
        }
        let places = found.map(\.place).sorted { $0.distanceMeters < $1.distanceMeters }
        return .nearby(
            Array(places.prefix(RoutePlaceCorridor.maximumResults)),
            radiusMeters: RoutePlaceCorridor.searchRadiusMeters
        )
    }

    /// MapKit takes and returns its own coordinates, which are GCJ-02 inside
    /// mainland China; the corridor math is WGS-84.
    private func places(
        _ kind: RoutePlaceKind,
        around center: RouteCoordinateV1
    ) async throws -> [(name: String, coordinate: RouteCoordinateV1)] {
        let mapKitCenter = RouteCoordinateNormalizationV1.wgs84ToMapKit(center)
        let items = try await search(
            kind,
            CLLocationCoordinate2D(latitude: mapKitCenter.latitude, longitude: mapKitCenter.longitude),
            RoutePlaceCorridor.searchRadiusMeters
        )
        return items.compactMap { item in
            let coordinate = item.placemark.coordinate
            guard let name = item.name, !name.isEmpty,
                  CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return (name, RouteCoordinateNormalizationV1.mapKitToWGS84(
                RouteCoordinateV1(latitude: coordinate.latitude, longitude: coordinate.longitude),
                near: center
            ))
        }
    }

    /// Overlapping circles and text fallbacks can return the same place twice.
    private static func isDuplicate(
        _ candidate: (name: String, coordinate: RouteCoordinateV1),
        in found: [(name: String, coordinate: RouteCoordinateV1)]
    ) -> Bool {
        found.contains {
            $0.name == candidate.name &&
                NavigationGeometryV1.distance(from: $0.coordinate, to: candidate.coordinate) < 50
        }
    }

    private static func failure(_ error: Error) -> RoutePlaceSearchOutcome {
        // Codes only: never log queries, locations or provider payloads.
        let failure = error as NSError
        if failure.domain == MKErrorDomain,
           failure.code == Int(MKError.Code.loadingThrottled.rawValue) {
            return .busy
        }
        return .unavailable
    }
}

/// What Siri says. Distances are metric, like the rest of the app.
nonisolated enum RoutePlaceSearchReply {
    static func text(
        for outcome: RoutePlaceSearchOutcome,
        kind: RoutePlaceKind,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        switch outcome {
        case .onRoute(let places, let searchedMeters):
            guard let first = places.first else {
                return "I couldn't find a \(kind.spokenName) in the next \(distance(searchedMeters, locale)) of your route."
            }
            var text = "The nearest \(kind.spokenName) on your route is \(first.name), " +
                "\(distance(first.distanceMeters, locale)) ahead"
            if first.offRouteMeters >= 50 {
                text += " and \(distance(first.offRouteMeters, locale)) off the route"
            }
            text += "."
            let others = places.dropFirst().map { "\($0.name) in \(distance($0.distanceMeters, locale))" }
            if !others.isEmpty {
                text += " Also on your route: \(others.joined(separator: " and "))."
            }
            return text
        // Also the answer for a navigating rider who is off the route, so it
        // never claims the rider isn't navigating.
        case .nearby(let places, let radiusMeters):
            guard let first = places.first else {
                return "I couldn't find a \(kind.spokenName) within \(distance(radiusMeters, locale)) of you."
            }
            var text = "The nearest \(kind.spokenName) is \(first.name), " +
                "\(distance(first.distanceMeters, locale)) away."
            let others = places.dropFirst().map { "\($0.name), \(distance($0.distanceMeters, locale)) away" }
            if !others.isEmpty {
                text += " Also nearby: \(others.joined(separator: " and "))."
            }
            return text
        case .noLocation:
            return "Bicino doesn't know where you are yet. Try again in a moment."
        case .busy:
            return "Place search is busy. Try again in a moment."
        case .unavailable:
            return "Place search is unavailable. Check your internet connection and try again."
        }
    }

    /// Whole 50 m steps below a kilometre, then kilometres to one decimal.
    static func distance(_ meters: CLLocationDistance, _ locale: Locale) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .providedUnit
        if meters < 950 {
            formatter.numberFormatter.maximumFractionDigits = 0
            let rounded = max(50, (meters / 50).rounded() * 50)
            return formatter.string(from: Measurement(value: rounded, unit: UnitLength.meters))
        }
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter.string(from: Measurement(value: meters / 1_000, unit: UnitLength.kilometers))
    }
}
