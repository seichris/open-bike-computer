import Combine
import CoreLocation
import Foundation

/// Saved-route archives store WGS-84, but favorites and recents hold MapKit
/// coordinates: map pins create them that way, and route planning, device
/// destination requests and the Watch favorite sync all read them that way.
/// Like every other conversion in the app, MapKit space here means GCJ-02
/// inside `RouteCoordinateNormalizationV1.isInMainlandChina`'s region.
@MainActor
enum SavedRouteFavoritePolicy {
    /// The favorite for a saved route's destination, in MapKit coordinates.
    static func favorite(for route: PlannedRouteSummaryV1) -> SavedDestination {
        SavedDestination(
            name: route.destination.label,
            coordinate: mapKitCoordinate(route.destination.coordinate)
        )
    }

    /// New coordinates, by ID, for destinations that came from starring a saved
    /// route before `favorite(for:)` converted. Each holds exactly its linked
    /// route's WGS-84 destination; only those still linked to an installed
    /// route can be told apart from a map pin, and only where the conversion
    /// moves the point are they wrong.
    static func legacyCoordinateRepairs(
        destinations: [SavedDestination],
        routes: [PlannedRouteSummaryV1]
    ) -> [UUID: CLLocationCoordinate2D] {
        let routeDestinations = Dictionary(
            routes.map { ($0.id, $0.destination.coordinate) },
            uniquingKeysWith: { first, _ in first }
        )
        var repairs: [UUID: CLLocationCoordinate2D] = [:]
        for destination in destinations {
            guard let routeID = destination.savedRouteID,
                  let routeDestination = routeDestinations[routeID],
                  destination.latitude == routeDestination.latitude,
                  destination.longitude == routeDestination.longitude else { continue }
            let mapKit = mapKitCoordinate(routeDestination)
            guard mapKit.latitude != routeDestination.latitude ||
                    mapKit.longitude != routeDestination.longitude else { continue }
            repairs[destination.id] = mapKit
        }
        return repairs
    }

    static func repairLegacyCoordinates(
        in store: SavedDestinationStore,
        routes: [PlannedRouteSummaryV1]
    ) {
        let favorites = Dictionary(
            store.favoriteDestinations.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let favoriteRepairs = legacyCoordinateRepairs(
            destinations: store.favoriteDestinations,
            routes: routes
        )
        // A recent with a favorite's ID is the copy planning to it left. It
        // moves only together with that favorite, even after the favorite was
        // re-linked to another route, so the two never come apart.
        var recentRepairs = legacyCoordinateRepairs(
            destinations: store.recentDestinations.filter { favorites[$0.id] == nil },
            routes: routes
        )
        for recent in store.recentDestinations {
            guard let favorite = favorites[recent.id],
                  let coordinate = favoriteRepairs[recent.id],
                  recent.latitude == favorite.latitude,
                  recent.longitude == favorite.longitude else { continue }
            recentRepairs[recent.id] = coordinate
        }
        store.replaceCoordinates(favorites: favoriteRepairs, recents: recentRepairs)
    }

    /// Repairs `store` with the installed routes now and whenever they change.
    static func repairLegacyCoordinates(
        in store: SavedDestinationStore,
        whenever routes: Published<[PlannedRouteSummaryV1]>.Publisher
    ) -> AnyCancellable {
        routes.sink { [weak store] routes in
            guard let store else { return }
            repairLegacyCoordinates(in: store, routes: routes)
        }
    }

    private static func mapKitCoordinate(_ coordinate: RouteCoordinateV1) -> CLLocationCoordinate2D {
        let mapKit = RouteCoordinateNormalizationV1.wgs84ToMapKit(coordinate)
        return CLLocationCoordinate2D(latitude: mapKit.latitude, longitude: mapKit.longitude)
    }
}
