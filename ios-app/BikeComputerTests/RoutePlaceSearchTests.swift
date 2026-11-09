import CoreLocation
import Foundation
import MapKit

@MainActor
private final class RoutePlaceSearchRecorder {
    var centers: [CLLocationCoordinate2D] = []
    var kinds: [RoutePlaceKind] = []
}

private struct RoutePlaceSearchFailure: Error {}

extension OnlinePOISearchTests {
    @MainActor
    static func routePlaceSearchTests() async throws {
        // An 11 km route east along the equator with a point every 0.01°,
        // outside mainland China, so MapKit and WGS-84 coordinates agree.
        let points = (0...10).map { RouteCoordinateV1(latitude: 0, longitude: Double($0) * 0.01) }
        let cumulative = NavigationGeometryV1.cumulativeDistances(for: points)
        let total = cumulative[cumulative.count - 1]
        let degreesPerMeter = 0.01 / cumulative[1]
        func onRoute(_ meters: Double, north: Double = 0) -> RouteCoordinateV1 {
            RouteCoordinateV1(latitude: north * degreesPerMeter, longitude: meters * degreesPerMeter)
        }
        func close(_ value: Double?, _ expected: Double, within tolerance: Double = 2) -> Bool {
            guard let value else { return false }
            return abs(value - expected) <= tolerance
        }

        let centers = RoutePlaceCorridor.searchCenters(
            points: points, cumulative: cumulative, distanceAlongMeters: 0)
        precondition(centers.map(\.distanceMeters) == [1_000, 3_000, 5_000],
                     "Search circles sit 1, 3 and 5 km ahead")
        let late = RoutePlaceCorridor.searchCenters(
            points: points, cumulative: cumulative, distanceAlongMeters: 9_000)
        precondition(late.map(\.distanceMeters) == [10_000, total],
                     "The route end caps the last circle")
        let finished = RoutePlaceCorridor.searchCenters(
            points: points, cumulative: cumulative, distanceAlongMeters: total)
        precondition(finished.count == 1 && finished[0].distanceMeters == total,
                     "A finished route still searches around its end")
        precondition(RoutePlaceCorridor.searchCenters(
            points: [points[0]], cumulative: [0], distanceAlongMeters: 0).isEmpty,
                     "A single point is not a route")
        precondition(close(RoutePlaceCorridor.point(
            atDistance: 2_500, points: points, cumulative: cumulative)?.longitude,
            2_500 * degreesPerMeter, within: 1e-9), "Points interpolate along the route")

        let segments = RoutePlaceCorridor.searchSegments(cumulative: cumulative, from: 1_000, to: 7_000)
        func position(_ place: RouteCoordinateV1) -> (aheadMeters: Double, offRouteMeters: Double)? {
            RoutePlaceCorridor.position(of: place, points: points, cumulative: cumulative,
                                        segments: segments, from: 1_000, to: 7_000)
        }
        let beside = position(onRoute(2_500, north: 120))
        precondition(close(beside?.aheadMeters, 1_500) && close(beside?.offRouteMeters, 120),
                     "A place beside the route projects onto it")
        precondition(position(onRoute(2_500, north: 300)) == nil, "More than 250 m off the route is excluded")
        precondition(close(position(onRoute(970))?.aheadMeters, 0),
                     "A place the rider is just passing counts as here")
        precondition(position(onRoute(900)) == nil, "A place behind the rider is excluded")
        precondition(position(onRoute(7_500)) == nil, "A place past the searched stretch is excluded")

        func item(_ name: String, _ coordinate: RouteCoordinateV1) -> MKMapItem {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(
                latitude: coordinate.latitude, longitude: coordinate.longitude)))
            item.name = name
            return item
        }

        let recorder = RoutePlaceSearchRecorder()
        let search = RoutePlaceSearch { kind, center, radius in
            recorder.kinds.append(kind)
            recorder.centers.append(center)
            precondition(radius == 1_000, "Each circle uses the map search's 1 km radius")
            switch recorder.centers.count {
            case 1:
                return [item("Far Side", onRoute(1_800, north: 600)),
                        item("Corner Café", onRoute(2_000, north: 55)),
                        item("Corner Café", onRoute(2_010, north: 55)),
                        item("Behind", onRoute(300))]
            case 2:
                return [item("Bean There", onRoute(3_900, north: 110))]
            default:
                return [item("Last Stop", onRoute(5_800))]
            }
        }
        let found = await search.find(.coffeeShop, route: (points, 1_000), location: nil)
        guard case .onRoute(let places, let searched) = found else {
            preconditionFailure("A navigating rider searches the route ahead")
        }
        precondition(recorder.centers.count == 3 && recorder.kinds == [.coffeeShop, .coffeeShop, .coffeeShop],
                     "At most three circles per request")
        precondition(close(recorder.centers[0].longitude, 2_000 * degreesPerMeter, within: 1e-9),
                     "Circles start 1 km ahead of the rider")
        precondition(places.map(\.name) == ["Corner Café", "Bean There", "Last Stop"],
                     "Off-route, behind and duplicate places are dropped; the rest are ordered ahead")
        precondition(close(places[0].distanceMeters, 1_000) && close(places[0].offRouteMeters, 55),
                     "Distances are along the route from the rider and off the route")
        precondition(searched == 6_000, "The searched stretch is reported for an empty answer")

        var calls = 0
        let throttled = RoutePlaceSearch { _, _, _ in
            calls += 1
            throw NSError(domain: MKErrorDomain, code: Int(MKError.Code.loadingThrottled.rawValue))
        }
        let busy = await throttled.find(.bikeShop, route: (points, 0), location: nil)
        precondition(busy == .busy && calls == 1, "Throttling stops at the first error")

        calls = 0
        let partial = RoutePlaceSearch { _, _, _ in
            calls += 1
            if calls == 1 { return [item("Fresh Mart", onRoute(1_200, north: 20))] }
            throw RoutePlaceSearchFailure()
        }
        guard case .onRoute(let kept, _) = await partial.find(.supermarket, route: (points, 0), location: nil) else {
            preconditionFailure("Earlier circles survive a later failure")
        }
        precondition(kept.map(\.name) == ["Fresh Mart"] && calls == 2,
                     "A later failure keeps earlier results without retrying")

        calls = 0
        let failing = RoutePlaceSearch { _, _, _ in
            calls += 1
            throw RoutePlaceSearchFailure()
        }
        let unlocated = await failing.find(.pharmacy, route: nil, location: nil)
        precondition(unlocated == .noLocation && calls == 0,
                     "Without a route or location nothing is searched")
        let riderCoordinate = CLLocationCoordinate2D(latitude: 0, longitude: 3_000 * degreesPerMeter)
        func fix(accuracy: CLLocationAccuracy = 10, age: TimeInterval = 0) -> CLLocation {
            CLLocation(coordinate: riderCoordinate, altitude: 0, horizontalAccuracy: accuracy,
                       verticalAccuracy: -1, timestamp: Date().addingTimeInterval(-age))
        }
        let rider = fix()
        precondition(RoutePlaceCorridor.isUsable(rider), "A fresh, accurate fix is usable")
        precondition(!RoutePlaceCorridor.isUsable(fix(age: 600)), "A ten-minute-old fix is not")
        precondition(!RoutePlaceCorridor.isUsable(fix(accuracy: 500)), "A 500 m fix is not")
        precondition(!RoutePlaceCorridor.isUsable(fix(accuracy: -1)), "An invalid fix is not")
        let stale = await failing.find(.pharmacy, route: nil, location: fix(age: 600))
        precondition(stale == .noLocation && calls == 0, "A stale fix is never searched around")
        let unavailable = await failing.find(.pharmacy, route: nil, location: rider)
        precondition(unavailable == .unavailable && calls == 1,
                     "A failed nearby search reports the service as unavailable")

        let nearby = RoutePlaceSearch { _, _, _ in
            [item("Too Far", onRoute(4_500)), item("Fresh Mart", onRoute(3_300))]
        }
        guard case .nearby(let nearbyPlaces, let radius) = await nearby.find(
            .supermarket, route: nil, location: rider) else {
            preconditionFailure("A rider who isn't navigating gets nearby places")
        }
        precondition(nearbyPlaces.map(\.name) == ["Fresh Mart"] && radius == 1_000,
                     "Nearby places stay within the 1 km radius")

        let english = Locale(identifier: "en")
        precondition(RoutePlaceSearchReply.text(
            for: .onRoute([RoutePlace(name: "Corner Café", distanceMeters: 1_001, offRouteMeters: 56),
                           RoutePlace(name: "Bean There", distanceMeters: 2_892, offRouteMeters: 10)],
                          searchedMeters: 6_000),
            kind: .coffeeShop, locale: english)
            == "The nearest coffee shop on your route is Corner Café, 1 km ahead and 50 m off the route. Also on your route: Bean There in 2.9 km.",
                     "The reply names the nearest place first")
        precondition(RoutePlaceSearchReply.text(
            for: .onRoute([], searchedMeters: 6_000), kind: .bikeShop, locale: english)
            == "I couldn't find a bike shop in the next 6 km of your route.",
                     "An empty route search says how far it looked")
        precondition(RoutePlaceSearchReply.text(
            for: .nearby([RoutePlace(name: "Fresh Mart", distanceMeters: 320, offRouteMeters: 0)],
                         radiusMeters: 1_000),
            kind: .supermarket, locale: english)
            == "You're not navigating. The nearest supermarket is Fresh Mart, 300 m away.",
                     "Nearby replies round to 50 m")
        print("Route place search: corridor, bounded search, error handling and replies passed")
    }
}
