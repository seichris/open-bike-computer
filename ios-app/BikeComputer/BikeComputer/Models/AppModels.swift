//
//  AppModels.swift
//  BikeComputer
//
//  Data models for app state
//

import Foundation
import CoreLocation
import MapKit

/// Route calculation state
struct RouteCalculationState {
    var isCalculating: Bool = false
    var status: String = ""
}

/// Alert state
struct AlertState {
    var isShowing: Bool = false
    var message: String = ""
}

/// Navigation icon IDs shared with the ESP32 firmware.
enum NavigationIconID {
    static let straight = 1
    static let left = 2
    static let right = 3
    static let uTurn = 4
}

enum RouteEndpoint {
    case currentLocation
    case mapItem(MKMapItem)
    case query(String)
}
