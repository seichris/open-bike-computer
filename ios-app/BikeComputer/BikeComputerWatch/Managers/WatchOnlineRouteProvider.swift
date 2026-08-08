import CoreLocation
import Foundation
import MapKit

enum WatchOnlineRouteProviderError: Error, Equatable {
    case noRoute
    case invalidRequest
}

@MainActor
final class WatchOnlineRouteProvider: NavigationRouteProvider {
    let metadata = RouteProviderPolicyV1.mapKit
    private var activeDirections: MKDirections?

    func routes(
        for request: NavigationRouteRequestV1
    ) async throws -> [NavigationRouteV1] {
        guard request.transportType == .cycling,
              request.source.coordinate.isValid,
              request.destination.coordinate.isValid else {
            throw WatchOnlineRouteProviderError.invalidRequest
        }
        cancel()
        let directionsRequest = MKDirections.Request()
        directionsRequest.source = Self.mapItem(for: request.source)
        directionsRequest.destination = Self.mapItem(for: request.destination)
        directionsRequest.transportType = .cycling
        directionsRequest.requestsAlternateRoutes = request.requestAlternatives
        let directions = MKDirections(request: directionsRequest)
        activeDirections = directions
        defer {
            if activeDirections === directions { activeDirections = nil }
        }
        let response = try await directions.calculate()
        let routes = try response.routes.map {
            try WatchMapKitRouteAdapter.route(
                from: $0,
                sourceLabel: request.source.label,
                destinationLabel: request.destination.label,
                localeIdentifier: request.localeIdentifier
            )
        }
        guard !routes.isEmpty else { throw WatchOnlineRouteProviderError.noRoute }
        return routes
    }

    func cancel() {
        activeDirections?.cancel()
        activeDirections = nil
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
        sourceLabel: String,
        destinationLabel: String,
        localeIdentifier: String
    ) throws -> NavigationRouteV1 {
        let points = coordinates(from: mapKitRoute.polyline).map(normalize)
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
            let stepPoints = coordinates(from: mapStep.polyline).map(normalize)
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
            normalizationVersion: 1
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

    private static func normalize(
        _ coordinate: CLLocationCoordinate2D
    ) -> RouteCoordinateV1 {
        RouteCoordinateNormalizationV1.mapKitToWGS84(RouteCoordinateV1(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ))
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
