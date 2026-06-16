//
//  NavigationProtocol.swift
//  BikeComputer
//
//  Testable navigation helpers shared by route UI and BLE packet generation.
//

import CoreLocation
import MapKit

enum NavigationInstructionMapper {
    static func iconID(for instruction: String) -> Int {
        let lower = instruction.lowercased()

        if lower.contains("u-turn") || lower.contains("uturn") {
            return NavigationIconID.uTurn
        } else if lower.contains("left") {
            return NavigationIconID.left
        } else if lower.contains("right") {
            return NavigationIconID.right
        } else {
            return NavigationIconID.straight
        }
    }
}

enum RoutePolylineEndpoint {
    static func location(for polyline: MKPolyline) -> CLLocation? {
        let pointCount = polyline.pointCount
        guard pointCount > 0 else { return nil }

        var coordinate = CLLocationCoordinate2D()
        polyline.getCoordinates(&coordinate, range: NSRange(location: pointCount - 1, length: 1))
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

enum RouteEndpointSelection {
    static func sourceEndpoint(hasSelectedSource: Bool, sourceAddress: String) -> RouteEndpoint {
        hasSelectedSource ? .query(sourceAddress) : .currentLocation
    }
}
