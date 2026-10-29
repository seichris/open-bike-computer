import Combine
import CoreLocation
import Foundation
import MapKit

/// A favorite starred from a saved route uses MapKit coordinates, like a map
/// pin or search result, and favorites stored before that are repaired.
extension OfflineRouteSaveTests {
    static func savedRouteFavoriteCoordinates() throws {
        let suite = "saved-route-favorites.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        func installed(_ latitude: Double, _ longitude: Double, _ label: String) throws -> PlannedRouteSummaryV1 {
            let points = [RouteCoordinateV1(latitude: latitude - 0.002, longitude: longitude),
                          RouteCoordinateV1(latitude: latitude, longitude: longitude)]
            let route = NavigationRouteV1(
                id: UUID(), revision: 1, provider: RouteProviderPolicyV1.importedGPX,
                localeIdentifier: "en_US", transportType: .cycling,
                source: RouteEndpointV1(coordinate: points[0], label: "Start"),
                destination: RouteEndpointV1(coordinate: points[1], label: label),
                bounds: RouteBoundsV1.enclosing(points)!, distanceMeters: 222,
                expectedTravelTimeSeconds: nil, name: label, points: points,
                steps: [NavigationRouteStepV1(id: 1, geometryStartIndex: 0, geometryEndIndex: 1,
                    instruction: "Arrive at \(label)", maneuver: .arrive, distanceMeters: 222)],
                normalizationVersion: 1)
            return PlannedRouteSummaryV1(archive: try NavigationRouteArchiveV1.create(
                route: route, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                purpose: .offlineNavigation))
        }
        func point(_ coordinate: RouteCoordinateV1) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
        func stored(_ favorite: SavedDestination?) -> RouteCoordinateV1? {
            guard let latitude = favorite?.latitude, let longitude = favorite?.longitude else { return nil }
            return RouteCoordinateV1(latitude: latitude, longitude: longitude)
        }

        let bund = try installed(31.2304, 121.4737, "Bund")
        let jingAn = try installed(31.2286, 121.4480, "Jing'an")
        let chengdu = try installed(30.6586, 104.0648, "Chengdu")
        let london = try installed(51.5072, -0.1276, "Westminster")
        let wgs84 = bund.destination.coordinate
        let mapKit = RouteCoordinateNormalizationV1.wgs84ToMapKit(wgs84)

        let starred = SavedRouteFavoritePolicy.favorite(for: bund)
        check(starred.name == "Bund" && stored(starred) == mapKit &&
            NavigationGeometryV1.distance(from: wgs84, to: mapKit) > 100,
            "A route starred in mainland China becomes a MapKit-space favorite, not its WGS-84 archive point")
        check(NavigationGeometryV1.distance(
            from: RouteCoordinateNormalizationV1.mapKitToWGS84(stored(starred)!), to: wgs84) < 0.5,
            "The Watch favorite sync converts it back to the route's own destination")
        guard case .mapItem(let item) = starred.routeEndpoint else {
            preconditionFailure("A starred route favorite has a coordinate")
        }
        let planned: CLLocationCoordinate2D
        if #available(iOS 26.0, macOS 26.0, *) {
            planned = item.location.coordinate
        } else {
            planned = item.placemark.coordinate
        }
        check(planned.latitude == mapKit.latitude && planned.longitude == mapKit.longitude,
            "Planning to the favorite targets the saved route's destination in MapKit space")
        check(stored(SavedRouteFavoritePolicy.favorite(for: london)) == london.destination.coordinate,
            "Outside mainland China a starred route keeps its coordinates")

        // What the earlier star button stored, next to favorites it must not touch.
        let store = SavedDestinationStore(defaults: defaults)
        let legacy = SavedDestination(name: "Bund", coordinate: point(wgs84))
        store.addFavorite(legacy, savedRouteID: bund.id)
        let searched = SavedDestination(name: "Jing'an Temple",
            coordinate: CLLocationCoordinate2D(latitude: 31.2253, longitude: 121.4497))
        store.addFavorite(searched, savedRouteID: jingAn.id)
        let westminster = SavedDestination(name: "Westminster", coordinate: point(london.destination.coordinate))
        store.addFavorite(westminster, savedRouteID: london.id)
        let orphan = SavedDestination(name: "Deleted route", coordinate: point(
            RouteCoordinateV1(latitude: 31.1, longitude: 121.3)))
        store.addFavorite(orphan, savedRouteID: UUID())
        let unlinked = SavedDestination(name: "Chengdu", coordinate: point(chengdu.destination.coordinate))
        store.addFavorite(unlinked)
        let before = store.favoriteDestinations
        let routes = [bund, jingAn, chengdu, london]

        let repairs = SavedRouteFavoritePolicy.legacyCoordinateRepairs(
            favorites: before, routes: routes)
        check(Set(repairs.keys) == [legacy.id] &&
            repairs[legacy.id].map { $0.latitude == mapKit.latitude && $0.longitude == mapKit.longitude } == true,
            "Only a favorite holding its linked route's exact WGS-84 destination in mainland China is repaired")

        var publications = 0
        let observation = store.$favoriteDestinations.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        store.replaceFavoriteCoordinates([:])
        store.replaceFavoriteCoordinates([UUID(): point(mapKit)])
        check(publications == 0 && store.favoriteDestinations == before,
            "A repair with nothing to change neither publishes nor persists")
        store.replaceFavoriteCoordinates(repairs)
        let repaired = store.favoriteDestinations
        check(publications == 1 && repaired.map(\.id) == before.map(\.id) &&
            repaired.map(\.name) == before.map(\.name) &&
            repaired.map(\.savedRouteID) == before.map(\.savedRouteID),
            "Repairing keeps every favorite's identity, name, order and route link")
        check(stored(store.favorite(savedRouteID: bund.id)) == mapKit &&
            zip(repaired, before).filter { $0.0.id != legacy.id }.allSatisfy { $0.0 == $0.1 },
            "Only the legacy favorite's coordinate changes")
        check(SavedRouteFavoritePolicy.legacyCoordinateRepairs(favorites: repaired, routes: routes).isEmpty,
            "A repaired favorite is never moved again")

        let relaunched = SavedDestinationStore(defaults: defaults)
        check(relaunched.favoriteDestinations == repaired && stored(relaunched.favorite(savedRouteID: bund.id)) == mapKit,
            "The repair is persisted")

        let section = try String(contentsOfFile: "ios-app/BikeComputer/BikeComputer/Views/PlannedRoutesView.swift", encoding: .utf8)
        let app = try String(contentsOfFile: "ios-app/BikeComputer/BikeComputer/BikeComputerApp.swift", encoding: .utf8)
        check(section.contains("SavedRouteFavoritePolicy.favorite(for: route)") &&
            !section.contains("latitude: route.destination.coordinate.latitude"),
            "Starring a saved route creates its favorite in MapKit space")
        check(app.contains("routeLibrary.$routes") &&
            app.contains("SavedRouteFavoritePolicy.legacyCoordinateRepairs("),
            "Installed routes repair favorites stored by the earlier star button")
    }
}
