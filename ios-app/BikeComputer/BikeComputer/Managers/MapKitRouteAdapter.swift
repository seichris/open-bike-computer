import CoreLocation
import Foundation
import MapKit

enum MapKitRouteAdapter {
    static let normalizationVersion = RouteCoordinateNormalizationV1.mapKitVersion

    static func route(
        from mapKitRoute: MKRoute,
        fallbackSource: RouteCoordinateV1? = nil,
        routeID: UUID = UUID(),
        revision: UInt32 = 1,
        sourceLabel: String = "Route start",
        destinationLabel: String = "Destination",
        localeIdentifier: String = Locale.current.identifier
    ) throws -> NavigationRouteV1 {
        // Read in order from where the route was requested, so a route near a
        // mainland-China border keeps to its own side.
        var routePoints = RouteCoordinateNormalizationV1.mapKitToWGS84(
            routeCoordinates(from: mapKitRoute.polyline),
            startingNear: fallbackSource
        )
        if routePoints.count == 1,
           let fallbackSource,
           fallbackSource.isValid,
           fallbackSource != routePoints[0] {
            routePoints.insert(fallbackSource, at: 0)
        }
        guard let first = routePoints.first, let last = routePoints.last,
              let bounds = RouteBoundsV1.enclosing(routePoints) else {
            throw NavigationRouteValidationError.emptyGeometry
        }

        let cumulativeDistances = NavigationGeometryV1.cumulativeDistances(for: routePoints)
        let measuredDistance = cumulativeDistances.last ?? 0
        let distance = mapKitRoute.distance.isFinite && mapKitRoute.distance > 0
            ? mapKitRoute.distance
            : measuredDistance
        let expectedTravelTime = mapKitRoute.expectedTravelTime.isFinite &&
            mapKitRoute.expectedTravelTime > 0
            ? mapKitRoute.expectedTravelTime
            : nil

        var previousEndIndex = 0
        var routeSteps: [NavigationRouteStepV1] = []
        for (sourceStepIndex, step) in mapKitRoute.steps.enumerated() {
            // A step starts where the previous one ended.
            let stepPoints = RouteCoordinateNormalizationV1.mapKitToWGS84(
                routeCoordinates(from: step.polyline),
                startingNear: routePoints[min(previousEndIndex, routePoints.count - 1)]
            )
            guard let stepStart = stepPoints.first, let stepEnd = stepPoints.last else {
                if sourceStepIndex == mapKitRoute.steps.count - 1,
                   !routePoints.isEmpty {
                    let endpointIndex = routePoints.count - 1
                    routeSteps.append(NavigationRouteStepV1(
                        id: UInt32(routeSteps.count + 1),
                        geometryStartIndex: endpointIndex,
                        geometryEndIndex: endpointIndex,
                        instruction: "Arrive at destination",
                        maneuver: .arrive,
                        distanceMeters: 0
                    ))
                }
                continue
            }
            let startIndex = stepPoints.count == 1
                ? previousEndIndex
                : nearestIndex(
                    to: stepStart,
                    in: routePoints,
                    range: previousEndIndex..<routePoints.count
                ) ?? previousEndIndex
            let endIndex = nearestIndex(
                to: stepEnd,
                in: routePoints,
                range: startIndex..<routePoints.count
            ) ?? startIndex
            previousEndIndex = endIndex
            let instruction = normalizedInstruction(step.instructions)
            routeSteps.append(NavigationRouteStepV1(
                id: UInt32(routeSteps.count + 1),
                geometryStartIndex: startIndex,
                geometryEndIndex: endIndex,
                instruction: instruction,
                maneuver: ManeuverV1.infer(from: instruction),
                distanceMeters: step.distance.isFinite && step.distance > 0
                    ? step.distance
                    : max(cumulativeDistances[endIndex] - cumulativeDistances[startIndex], 0)
            ))
        }

        if routeSteps.isEmpty {
            let instruction = normalizedInstruction(mapKitRoute.name)
            routeSteps = [NavigationRouteStepV1(
                id: 1,
                geometryStartIndex: 0,
                geometryEndIndex: routePoints.count - 1,
                instruction: instruction,
                maneuver: ManeuverV1.infer(from: instruction),
                distanceMeters: distance
            )]
        }

        let route = NavigationRouteV1(
            id: routeID,
            revision: revision,
            provider: RouteProviderPolicyV1.mapKit,
            localeIdentifier: localeIdentifier,
            transportType: .cycling,
            source: RouteEndpointV1(coordinate: first, label: sourceLabel),
            destination: RouteEndpointV1(
                coordinate: last,
                label: destinationLabel
            ),
            bounds: bounds,
            distanceMeters: distance,
            expectedTravelTimeSeconds: expectedTravelTime,
            name: mapKitRoute.name.isEmpty ? nil : mapKitRoute.name,
            points: routePoints,
            steps: routeSteps,
            normalizationVersion: normalizationVersion
        )
        try route.validate()
        return route
    }

    /// `reference`, such as the rider's latest GPS fix, settles a location
    /// that a mainland-China border makes ambiguous, so a fix converted into
    /// MapKit route space comes back exactly.
    static func normalizedLocation(
        _ mapKitRouteLocation: CLLocation,
        near reference: CLLocation? = nil
    ) -> CLLocation {
        let coordinate = normalize(
            mapKitRouteLocation.coordinate,
            near: reference.map {
                RouteCoordinateV1(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
            }
        )
        return CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ),
            altitude: mapKitRouteLocation.altitude,
            horizontalAccuracy: mapKitRouteLocation.horizontalAccuracy,
            verticalAccuracy: mapKitRouteLocation.verticalAccuracy,
            course: mapKitRouteLocation.course,
            speed: mapKitRouteLocation.speed,
            timestamp: mapKitRouteLocation.timestamp
        )
    }

    private static func routeCoordinates(from polyline: MKPolyline) -> [RouteCoordinateV1] {
        coordinates(from: polyline).map {
            RouteCoordinateV1(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    private static func coordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
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
        _ coordinate: CLLocationCoordinate2D,
        near reference: RouteCoordinateV1?
    ) -> RouteCoordinateV1 {
        RouteCoordinateNormalizationV1.mapKitToWGS84(RouteCoordinateV1(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ), near: reference)
    }

    private static func nearestIndex(
        to target: RouteCoordinateV1,
        in points: [RouteCoordinateV1],
        range: Range<Int>
    ) -> Int? {
        var bestIndex: Int?
        var bestDistance = Double.infinity
        for index in range {
            let distance = NavigationGeometryV1.distance(
                from: target,
                to: points[index]
            )
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
            // MapKit step vertices normally reuse a full-route vertex. Taking
            // the first exact sequential match keeps loopbacks deterministic
            // and avoids rescanning the remaining route for every step.
            if distance < 0.01 {
                return index
            }
        }
        return bestIndex
    }

    private static func normalizedInstruction(_ instruction: String) -> String {
        let value = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Continue" : value
    }
}

extension NavigationLocationSampleV1 {
    init(location: CLLocation) {
        coordinate = RouteCoordinateV1(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        horizontalAccuracyMeters = location.horizontalAccuracy
        courseDegrees = location.course
        speedMetersPerSecond = location.speed
        altitudeMeters = location.altitude
        timestamp = location.timestamp
    }
}
