//
//  AppModels.swift
//  BikeComputer
//
//  Data models for app state
//

import Foundation

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

