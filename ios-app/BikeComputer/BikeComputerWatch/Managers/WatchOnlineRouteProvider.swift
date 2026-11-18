import CoreLocation
import Foundation
import MapKit

enum WatchOnlineRouteProviderError: Error, Equatable {
    case noRoute
    case invalidRequest
}

/// Apple Maps has no cycling directions in some regions, the UAE among them.
/// There a cycling request fails with `MKError.serverFailure`, and the error's
/// `MKDirectionsErrorCode` reports the area as out of coverage (8). A route
/// that does not exist between the points reports not reachable (16) with the
/// same `MKError` code (seen with macOS 26, iOS 26.5 and watchOS 27 MapKit;
/// the key is not documented). Only the out-of-coverage failure falls back to
/// car directions, which avoid highways and tolls because a bike may not use
/// them. If Apple drops the key, the rider sees the cycling failure as before.
///
/// The iPhone makes the same decision in `CyclingDirectionsFallback`, which
/// lives in its coordinator and is not compiled into the Watch app.
enum WatchCyclingDirectionsFallback {
    static let directionsErrorCodeKey = "MKDirectionsErrorCode"
    static let outOfCoverageCode = 8
    /// Shown while the active route is car directions. Same text as iPhone.
    static let routeNotice =
        "No cycling directions here: car route avoiding highways and tolls"

    static func isOutOfCoverage(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == MKErrorDomain else { return false }
        return (error.userInfo[directionsErrorCodeKey] as? NSNumber)?
            .intValue == outOfCoverageCode
    }

    /// The same endpoints and alternatives as car directions.
    static func carRequest(
        for request: MKDirections.Request
    ) -> MKDirections.Request {
        let car = MKDirections.Request()
        car.source = request.source
        car.destination = request.destination
        car.requestsAlternateRoutes = request.requestsAlternateRoutes
        car.transportType = .automobile
        car.highwayPreference = .avoid
        car.tollPreference = .avoid
        return car
    }
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

    func routes(
        for request: NavigationRouteRequestV1
    ) async throws -> NavigationRouteResponseV1 {
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
        let carRequest = WatchCyclingDirectionsFallback.carRequest(
            for: directionsRequest
        )

        let mapKitRoutes: [MKRoute]
        let directions: NavigationRouteDirectionsV1
        switch request.directions {
        case .carAvoidingHighwaysAndTolls:
            mapKitRoutes = try await calculate(carRequest)
            directions = .carAvoidingHighwaysAndTolls
        case .cycling:
            do {
                mapKitRoutes = try await calculate(directionsRequest)
                directions = .cycling
            } catch let cyclingError {
                guard WatchCyclingDirectionsFallback.isOutOfCoverage(
                    cyclingError
                ) else {
                    throw cyclingError
                }
                guard generation == cancellationGeneration,
                      !Task.isCancelled else {
                    throw CancellationError()
                }
                // If the car request fails too, report why cycling failed,
                // as the iPhone does.
                let carRoutes = (try? await calculate(carRequest)) ?? []
                guard !carRoutes.isEmpty else { throw cyclingError }
                mapKitRoutes = carRoutes
                directions = .carAvoidingHighwaysAndTolls
            }
        }
        let routes = try mapKitRoutes.map {
            try WatchMapKitRouteAdapter.route(
                from: $0,
                source: request.source.coordinate,
                sourceLabel: request.source.label,
                destinationLabel: request.destination.label,
                localeIdentifier: request.localeIdentifier
            )
        }
        guard !routes.isEmpty else { throw WatchOnlineRouteProviderError.noRoute }
        return NavigationRouteResponseV1(routes: routes, directions: directions)
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

private enum WatchMapKitRouteAdapter {
    static func route(
        from mapKitRoute: MKRoute,
        source: RouteCoordinateV1,
        sourceLabel: String,
        destinationLabel: String,
        localeIdentifier: String
    ) throws -> NavigationRouteV1 {
        // Read in order from the requested start, so a route near a
        // mainland-China border keeps to its own side.
        let points = RouteCoordinateNormalizationV1.mapKitToWGS84(
            routeCoordinates(from: mapKitRoute.polyline),
            startingNear: source
        )
        guard let first = points.first,
              let last = points.last,
              let bounds = RouteBoundsV1.enclosing(points) else {
            throw NavigationRouteValidationError.emptyGeometry
        }
        let cumulative = NavigationGeometryV1.cumulativeDistances(for: points)
        let measuredDistance = cumulative.last ?? 0
        let routeDistance = mapKitRoute.distance.isFinite &&
            mapKitRoute.distance > 0 ? mapKitRoute.distance : measuredDistance
        let travelTime = mapKitRoute.expectedTravelTime.isFinite &&
            mapKitRoute.expectedTravelTime > 0
            ? mapKitRoute.expectedTravelTime
            : nil

        var priorEnd = 0
        var steps: [NavigationRouteStepV1] = []
        for (sourceIndex, mapStep) in mapKitRoute.steps.enumerated() {
            // A step starts where the previous one ended.
            let stepPoints = RouteCoordinateNormalizationV1.mapKitToWGS84(
                routeCoordinates(from: mapStep.polyline),
                startingNear: points[min(priorEnd, points.count - 1)]
            )
            guard let stepStart = stepPoints.first,
                  let stepEnd = stepPoints.last else {
                if sourceIndex == mapKitRoute.steps.count - 1 {
                    let endpoint = points.count - 1
                    steps.append(NavigationRouteStepV1(
                        id: UInt32(steps.count + 1),
                        geometryStartIndex: endpoint,
                        geometryEndIndex: endpoint,
                        instruction: "Arrive at destination",
                        maneuver: .arrive,
                        distanceMeters: 0
                    ))
                }
                continue
            }
            let start = stepPoints.count == 1 ? priorEnd :
                nearestIndex(to: stepStart, in: points, from: priorEnd)
            let end = nearestIndex(to: stepEnd, in: points, from: start)
            priorEnd = end
            let instruction = normalizedInstruction(mapStep.instructions)
            steps.append(NavigationRouteStepV1(
                id: UInt32(steps.count + 1),
                geometryStartIndex: start,
                geometryEndIndex: end,
                instruction: instruction,
                maneuver: ManeuverV1.infer(from: instruction),
                distanceMeters: mapStep.distance.isFinite &&
                    mapStep.distance > 0
                    ? mapStep.distance
                    : max(cumulative[end] - cumulative[start], 0)
            ))
        }
        if steps.isEmpty {
            let instruction = normalizedInstruction(mapKitRoute.name)
            steps = [NavigationRouteStepV1(
                id: 1,
                geometryStartIndex: 0,
                geometryEndIndex: points.count - 1,
                instruction: instruction,
                maneuver: ManeuverV1.infer(from: instruction),
                distanceMeters: routeDistance
            )]
        }

        let route = NavigationRouteV1(
            id: UUID(),
            revision: 1,
            provider: RouteProviderPolicyV1.mapKit,
            localeIdentifier: localeIdentifier,
            transportType: .cycling,
            source: RouteEndpointV1(coordinate: first, label: sourceLabel),
            destination: RouteEndpointV1(
                coordinate: last,
                label: destinationLabel
            ),
            bounds: bounds,
            distanceMeters: routeDistance,
            expectedTravelTimeSeconds: travelTime,
            name: mapKitRoute.name.isEmpty ? nil : mapKitRoute.name,
            points: points,
            steps: steps,
            normalizationVersion: RouteCoordinateNormalizationV1.mapKitVersion
        )
        try route.validate()
        return route
    }

    private static func coordinates(
        from polyline: MKPolyline
    ) -> [CLLocationCoordinate2D] {
        guard polyline.pointCount > 0 else { return [] }
        var result = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(),
            count: polyline.pointCount
        )
        polyline.getCoordinates(
            &result,
            range: NSRange(location: 0, length: polyline.pointCount)
        )
        return result
    }

    private static func routeCoordinates(
        from polyline: MKPolyline
    ) -> [RouteCoordinateV1] {
        coordinates(from: polyline).map {
            RouteCoordinateV1(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    private static func nearestIndex(
        to target: RouteCoordinateV1,
        in points: [RouteCoordinateV1],
        from lowerBound: Int
    ) -> Int {
        var best = min(max(lowerBound, 0), points.count - 1)
        var bestDistance = Double.infinity
        for index in best..<points.count {
            let distance = NavigationGeometryV1.distance(
                from: target,
                to: points[index]
            )
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
            if distance < 0.01 { return index }
        }
        return best
    }

    private static func normalizedInstruction(_ instruction: String) -> String {
        let value = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Continue" : value
    }
}
