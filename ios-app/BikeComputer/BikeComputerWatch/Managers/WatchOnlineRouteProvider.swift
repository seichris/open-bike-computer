import CoreLocation
import Foundation
import MapKit

enum WatchOnlineRouteProviderError: Error, Equatable {
    case noRoute
    case invalidRequest
}

/// One MapKit directions calculation. Tests replace it.
@MainActor
protocol WatchDirectionsCalculating: AnyObject {
    func calculate() async throws -> [MKRoute]
    func cancel()
}

typealias WatchDirectionsFactory =
    @MainActor (MKDirections.Request) -> any WatchDirectionsCalculating

@MainActor
final class MapKitWatchDirections: WatchDirectionsCalculating {
    private let directions: MKDirections

    init(request: MKDirections.Request) {
        directions = MKDirections(request: request)
    }

    func calculate() async throws -> [MKRoute] {
        try await directions.calculate().routes
    }

    func cancel() {
        directions.cancel()
    }
}

@MainActor
final class WatchOnlineRouteProvider: NavigationRouteProvider {
    let metadata = RouteProviderPolicyV1.mapKit
    private let directionsFactory: WatchDirectionsFactory
    private var activeDirections: (any WatchDirectionsCalculating)?
    /// Advanced by `cancel()`. A cancelled MapKit request can still finish
    /// with the out-of-coverage failure, and must not go on to a car request.
    private var cancellationGeneration: UInt64 = 0

    init(
        directionsFactory: @escaping WatchDirectionsFactory = {
            MapKitWatchDirections(request: $0)
        }
    ) {
        self.directionsFactory = directionsFactory
    }

    /// Cycling directions, or car directions where Apple Maps has none for
    /// the area (`CyclingDirectionsFallback`, shared with iPhone). Every call,
    /// a reroute too, asks for cycling first, so a ride returns to cycling
    /// directions where coverage resumes.
    func routes(
        for request: NavigationRouteRequestV1
    ) async throws -> [NavigationRouteOptionV1] {
        guard request.transportType == .cycling,
              request.source.coordinate.isValid,
              request.destination.coordinate.isValid else {
            throw WatchOnlineRouteProviderError.invalidRequest
        }
        cancel()
        let generation = cancellationGeneration
        let directionsRequest = MKDirections.Request()
        directionsRequest.source = Self.mapItem(for: request.source)
        directionsRequest.destination = Self.mapItem(for: request.destination)
        directionsRequest.transportType = .cycling
        directionsRequest.requestsAlternateRoutes = request.requestAlternatives

        let mapKitRoutes: [MKRoute]
        do {
            mapKitRoutes = try await calculate(directionsRequest)
        } catch let cyclingError {
            guard CyclingDirectionsFallback.usesCarDirections(
                after: cyclingError,
                requested: directionsRequest.transportType
            ) else {
                throw cyclingError
            }
            guard generation == cancellationGeneration,
                  !Task.isCancelled else {
                throw CancellationError()
            }
            let carRoutes: [MKRoute]
            do {
                carRoutes = try await calculate(
                    CyclingDirectionsFallback.carRequest(for: directionsRequest)
                )
            } catch {
                throw CyclingDirectionsFallback.isTransient(error)
                    ? error
                    : cyclingError
            }
            // Routes without highways or tolls first; the car request always
            // asks for alternatives so that one can be found.
            let preferred = CyclingDirectionsFallback.cyclingFriendlyRoutes(
                from: carRoutes
            )
            guard !preferred.isEmpty else { throw cyclingError }
            mapKitRoutes = request.requestAlternatives
                ? preferred
                : Array(preferred.prefix(1))
        }
        let options = try mapKitRoutes.map { mapKitRoute in
            NavigationRouteOptionV1(
                route: try MapKitNavigationRouteAdapterV1.route(
                    from: mapKitRoute,
                    source: request.source.coordinate,
                    sourceLabel: request.source.label,
                    destinationLabel: request.destination.label,
                    localeIdentifier: request.localeIdentifier
                ),
                notice: (mapKitRoute as? CyclingFallbackCarRoute)?
                    .advisoryNotices.first
            )
        }
        guard !options.isEmpty else { throw WatchOnlineRouteProviderError.noRoute }
        return options
    }

    func cancel() {
        cancellationGeneration &+= 1
        activeDirections?.cancel()
        activeDirections = nil
    }

    private func calculate(
        _ request: MKDirections.Request
    ) async throws -> [MKRoute] {
        let directions = directionsFactory(request)
        activeDirections = directions
        defer {
            if activeDirections === directions { activeDirections = nil }
        }
        return try await directions.calculate()
    }

    private static func mapItem(for endpoint: RouteEndpointV1) -> MKMapItem {
        let mapCoordinate = RouteCoordinateNormalizationV1.wgs84ToMapKit(
            endpoint.coordinate
        )
        let location = CLLocation(
            latitude: mapCoordinate.latitude,
            longitude: mapCoordinate.longitude
        )
        let item: MKMapItem
        if #available(watchOS 26.0, *) {
            item = MKMapItem(location: location, address: nil)
        } else {
            item = MKMapItem(placemark: MKPlacemark(
                coordinate: location.coordinate
            ))
        }
        item.name = endpoint.label
        return item
    }
}
