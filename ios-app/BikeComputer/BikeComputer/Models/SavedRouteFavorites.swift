import CoreLocation
import Foundation

/// Saved-route archives store WGS-84, but favorites hold MapKit coordinates
/// (GCJ-02 in mainland China): map pins and search create them that way, and
/// route planning, device destination requests and the Watch favorite sync
/// all read them that way.
enum SavedRouteFavoritePolicy {
    /// The favorite for a saved route's destination, in MapKit coordinates.
    static func favorite(for route: PlannedRouteSummaryV1) -> SavedDestination {
        SavedDestination(
            name: route.destination.label,
            coordinate: mapKitCoordinate(route.destination.coordinate)
        )
    }

    /// New coordinates, by favorite ID, for favorites that were starred from a
    /// saved route before `favorite(for:)` converted. Such a favorite holds
    /// exactly its route's WGS-84 destination; only the ones still linked to
    /// an installed route can be told apart from a pin or search result, and
    /// only where MapKit's coordinates differ, in mainland China, are wrong.
    static func legacyCoordinateRepairs(
        favorites: [SavedDestination],
        routes: [PlannedRouteSummaryV1]
    ) -> [UUID: CLLocationCoordinate2D] {
        let destinations = Dictionary(
            routes.map { ($0.id, $0.destination.coordinate) },
            uniquingKeysWith: { first, _ in first }
        )
        var repairs: [UUID: CLLocationCoordinate2D] = [:]
        for favorite in favorites {
            guard let routeID = favorite.savedRouteID,
                  let destination = destinations[routeID],
                  favorite.latitude == destination.latitude,
                  favorite.longitude == destination.longitude else { continue }
            let mapKit = mapKitCoordinate(destination)
            guard mapKit.latitude != destination.latitude ||
                    mapKit.longitude != destination.longitude else { continue }
            repairs[favorite.id] = mapKit
        }
        return repairs
    }

    private static func mapKitCoordinate(_ coordinate: RouteCoordinateV1) -> CLLocationCoordinate2D {
        let mapKit = RouteCoordinateNormalizationV1.wgs84ToMapKit(coordinate)
        return CLLocationCoordinate2D(latitude: mapKit.latitude, longitude: mapKit.longitude)
    }
}
