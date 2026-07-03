//
//  BikeComputerCoordinator.swift
//  BikeComputer
//
//  Central coordinator managing all app subsystems
//  Implements coordinator pattern to eliminate circular dependencies
//

import Foundation
import SwiftUI
import MapKit
import Combine
import CoreLocation

/// Main coordinator for the Bike Computer app
/// Manages BLE, Navigation, Location, and HealthKit subsystems
class BikeComputerCoordinator: ObservableObject {

    // MARK: - Private Managers (Implementation Details)

    let bleManager = BLEManager()  // Accessible for settings view
    private let navEngine = NavigationEngine()
    private let locationManager = CurrentLocationManager()
    private let healthKitManager = HealthKitManager()

    // MARK: - Published State (UI Observable)

    // BLE Connection
    @Published var isConnected: Bool = false
    @Published var peripheralName: String = ""
    @Published var hardwareLabel: String = ""
    @Published var signalStrength: Int = 0

    // Navigation
    @Published var isNavigating: Bool = false
    @Published var currentInstruction: String = "Ready to Navigate"
    @Published var distanceToManeuver: Int = 0
    @Published var currentIconID: Int = NavigationIconID.straight
    @Published var currentRoute: MKRoute?
    @Published var isSimulationMode: Bool = false
    @Published var simulatedPosition: CLLocationCoordinate2D?
    @Published var routeRemainingDistance: CLLocationDistance?
    @Published var routeRemainingTime: TimeInterval?
    @Published var expectedArrivalDate: Date?

    // Workout
    @Published var isWorkoutActive: Bool = false
    @Published var isHealthKitAuthorized: Bool = false
    @Published var isHealthKitAvailable: Bool = false
    @Published var workoutElapsedTime: TimeInterval = 0
    @Published var currentSpeedKmh: Double = 0
    @Published var distanceKm: Double = 0
    @Published var heartRate: Int?
    @Published var formattedElapsedTime: String = "00:00"

    // Location
    @Published var currentLocation: CLLocation?
    @Published var currentAddress: String = "Current Location"

    // Route Calculation
    @Published var routeCalculation = RouteCalculationState()

    // Alerts
    @Published var alert = AlertState()

    // UI State
    @Published var selectedView: Int = 0  // 0 = map, 1 = navigation+workout

    // MARK: - Private State

    private var cancellables = Set<AnyCancellable>()
    private var ongoingSourceSearch: MKLocalSearch?
    private var ongoingDestinationSearch: MKLocalSearch?
    private var ongoingDirections: MKDirections?
    private var transportType: MKDirectionsTransportType = RouteTransportTypes.cycling

    // MARK: - Initialization

    init() {
        setupManagerBindings()
        setupManagers()
    }

    // MARK: - Setup

    private func setupManagerBindings() {
        // Bind BLE manager state
        bleManager.$isConnected
            .assign(to: &$isConnected)

        bleManager.$peripheralName
            .assign(to: &$peripheralName)

        bleManager.$hardwareLabel
            .assign(to: &$hardwareLabel)

        bleManager.$signalStrength
            .assign(to: &$signalStrength)

        // Bind navigation engine state
        navEngine.$isNavigating
            .sink { [weak self] navigating in
                guard let self = self else { return }
                self.isNavigating = navigating
                self.locationManager.setNavigating(navigating && !self.navEngine.isSimulationMode)
            }
            .store(in: &cancellables)

        navEngine.$isSimulationMode
            .assign(to: &$isSimulationMode)

        navEngine.$simulatedPosition
            .assign(to: &$simulatedPosition)

        navEngine.$currentInstruction
            .assign(to: &$currentInstruction)

        navEngine.$distanceToManeuver
            .assign(to: &$distanceToManeuver)

        navEngine.$currentIconID
            .assign(to: &$currentIconID)

        navEngine.$routeRemainingDistance
            .assign(to: &$routeRemainingDistance)

        navEngine.$routeRemainingTime
            .assign(to: &$routeRemainingTime)

        navEngine.$expectedArrivalDate
            .assign(to: &$expectedArrivalDate)

        // Bind health kit manager state
        healthKitManager.$isAuthorized
            .assign(to: &$isHealthKitAuthorized)

        healthKitManager.$isHealthKitAvailable
            .assign(to: &$isHealthKitAvailable)

        healthKitManager.$isWorkoutActive
            .sink { [weak self] active in
                self?.isWorkoutActive = active
                self?.locationManager.updateLocationTracking()
            }
            .store(in: &cancellables)

        healthKitManager.$workoutElapsedTime
            .assign(to: &$workoutElapsedTime)

        healthKitManager.$currentSpeed
            .map { $0 * 3.6 }
            .assign(to: &$currentSpeedKmh)

        healthKitManager.$distanceTraveled
            .map { $0 / 1000.0 }
            .assign(to: &$distanceKm)

        healthKitManager.$heartRate
            .map { $0 > 0 ? Int($0) : nil }
            .assign(to: &$heartRate)

        healthKitManager.$workoutElapsedTime
            .map { TimeFormatter.format($0) }
            .assign(to: &$formattedElapsedTime)

        // Bind location manager state
        locationManager.$currentLocation
            .assign(to: &$currentLocation)

        locationManager.$currentLocation
            .compactMap { $0 }
            .sink { [weak self] location in
                self?.navEngine.processExternalLocation(location)
            }
            .store(in: &cancellables)

        bleManager.$isNavigationReady
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self, let location = self.locationManager.currentLocation else { return }
                self.navEngine.processExternalLocation(location)
            }
            .store(in: &cancellables)

        locationManager.$currentAddress
            .assign(to: &$currentAddress)

        // Current firmware exposes only the navigation packet characteristic.
    }

    private func setupManagers() {
        // Wire up inter-manager dependencies
        navEngine.setBLEManager(bleManager)
        locationManager.healthKitManager = healthKitManager
        healthKitManager.locationManager = locationManager

        // Start BLE operations
        bleManager.startScanning()

        // Enable location tracking for map view
        locationManager.setViewingMap(true)
    }

    // MARK: - Public API: BLE

    func disconnect() {
        bleManager.disconnect()
    }

    func reconnect() {
        bleManager.reconnect()
    }

    // MARK: - Public API: Navigation

    func startNavigation(from source: RouteEndpoint, to destination: RouteEndpoint, transportType: MKDirectionsTransportType, isTestMode: Bool = false) {
        self.transportType = transportType
        calculateRoute(from: source, to: destination, isTestMode: isTestMode)
    }

    func startNavigation(from source: String, to destination: String, transportType: MKDirectionsTransportType, isTestMode: Bool = false) {
        startNavigation(from: .query(source), to: .query(destination), transportType: transportType, isTestMode: isTestMode)
    }

    func stopNavigation() {
        navEngine.stopNavigation()
        currentRoute = nil
        locationManager.setNavigating(false)
        selectedView = 0
    }

    func handleDestinationSelection(coordinate: CLLocationCoordinate2D, mapLocation: CLLocation?) {
        guard let sourceLocation = currentLocation ?? mapLocation else {
            alert.message = "Unable to determine your current location. Please enable location services."
            alert.isShowing = true
            return
        }

        let routeSourceLocation = CoordinateConverter.mapKitRouteLocation(fromGPSLocation: sourceLocation)
        let source = MKMapItem(placemark: MKPlacemark(coordinate: routeSourceLocation.coordinate))
        source.name = "Current Location"

        let destination = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        destination.name = "Selected Location"
        transportType = RouteTransportTypes.cycling
        calculateRoute(from: .mapItem(source), to: .mapItem(destination))
    }

    // MARK: - Public API: Workout

    func startWorkout() {
        healthKitManager.startBikeWorkout()
    }

    func endWorkout() {
        healthKitManager.endBikeWorkout()
    }

    // MARK: - Public API: Location

    func setViewingMap(_ viewing: Bool) {
        locationManager.setViewingMap(viewing)
    }

    // MARK: - Public API: UI State

    func updateSelectedView(_ view: Int) {
        selectedView = view
        locationManager.setViewingMap(view == 0)
    }
}

// MARK: - Route Calculation (Private Implementation)

extension BikeComputerCoordinator {

    private func calculateRoute(from source: RouteEndpoint, to destination: RouteEndpoint, isTestMode: Bool = false) {
        print("Starting route calculation")

        // Cancel any ongoing searches
        ongoingSourceSearch?.cancel()
        ongoingDestinationSearch?.cancel()
        ongoingDirections?.cancel()

        routeCalculation.isCalculating = true
        routeCalculation.status = "Searching for locations..."

        resolveEndpoint(source, role: "Starting location") { [weak self] sourceItem in
            guard let self = self, let sourceItem = sourceItem else { return }

            self.routeCalculation.status = "Finding destination..."
            self.resolveEndpoint(destination, role: "Destination") { [weak self] destinationItem in
                guard let self = self, let destinationItem = destinationItem else { return }

                self.routeCalculation.status = "Calculating route..."
                self.requestDirections(from: sourceItem, to: destinationItem, isTestMode: isTestMode)
            }
        }
    }

    private func resolveEndpoint(_ endpoint: RouteEndpoint, role: String, completion: @escaping (MKMapItem?) -> Void) {
        switch endpoint {
        case .currentLocation:
            guard let currentLoc = currentLocation else {
                routeCalculation.status = "Current location unavailable"
                alert.message = "Unable to determine your current location. Please enable location services."
                alert.isShowing = true
                finishRouteCalculationAfterDelay()
                completion(nil)
                return
            }

            let routeLocation = CoordinateConverter.mapKitRouteLocation(fromGPSLocation: currentLoc)
            let item = MKMapItem(placemark: MKPlacemark(coordinate: routeLocation.coordinate))
            item.name = "Current Location"
            print("Using current location: \(routeLocation.coordinate.latitude), \(routeLocation.coordinate.longitude)")
            completion(item)

        case .mapItem(let item):
            print("\(role): \(item.name ?? "Map Item") at \(item.placemark.coordinate.latitude), \(item.placemark.coordinate.longitude)")
            completion(item)

        case .query(let query):
            let searchRequest = MKLocalSearch.Request()
            searchRequest.naturalLanguageQuery = query
            if let currentLocation {
                let routeLocation = CoordinateConverter.mapKitRouteLocation(fromGPSLocation: currentLocation)
                searchRequest.region = MKCoordinateRegion(
                    center: routeLocation.coordinate,
                    latitudinalMeters: 50000,
                    longitudinalMeters: 50000
                )
            }

            let search = MKLocalSearch(request: searchRequest)
            if role == "Starting location" {
                ongoingSourceSearch = search
            } else {
                ongoingDestinationSearch = search
            }

            search.start { [weak self] response, error in
                guard let self = self else { return }

                if role == "Starting location" {
                    self.ongoingSourceSearch = nil
                } else {
                    self.ongoingDestinationSearch = nil
                }

                if let error = error {
                    print("Error searching for \(role): \(error.localizedDescription)")
                    self.routeCalculation.status = "\(role) not found"
                    self.finishRouteCalculationAfterDelay()
                    completion(nil)
                    return
                }

                guard let item = response?.mapItems.first else {
                    print("No results for \(role)")
                    self.routeCalculation.status = "\(role) not found"
                    self.finishRouteCalculationAfterDelay()
                    completion(nil)
                    return
                }

                print("\(role) found: \(item.name ?? "Unknown") at \(item.placemark.coordinate.latitude), \(item.placemark.coordinate.longitude)")
                completion(item)
            }
        }
    }

    private func finishRouteCalculationAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.routeCalculation.isCalculating = false
            self.routeCalculation.status = ""
        }
    }

    private func requestDirections(from sourceItem: MKMapItem, to destinationItem: MKMapItem, isTestMode: Bool) {
        let request = MKDirections.Request()
        request.source = sourceItem
        request.destination = destinationItem
        request.transportType = self.transportType
        request.requestsAlternateRoutes = false

        print("Calculating route with transport type: \(self.transportType.rawValue)")

        let directions = MKDirections(request: request)
        self.ongoingDirections = directions
        directions.calculate { [weak self] response, error in
            guard let self = self else { return }
            self.ongoingDirections = nil

            if let error = error {
                print("Error calculating route: \(error.localizedDescription)")
                // SHOW ERROR ON SCREEN
                self.routeCalculation.status = "Err: \(error.localizedDescription)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self.routeCalculation.isCalculating = false
                    self.routeCalculation.status = ""
                }
                return
            }

            guard let route = response?.routes.first else {
                print("No routes found")
                self.routeCalculation.status = "No route available"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.routeCalculation.isCalculating = false
                    self.routeCalculation.status = ""
                }
                return
            }

            print("Route calculated successfully!")
            print("Distance: \(route.distance)m, ETA: \(route.expectedTravelTime)s")
            print("Steps: \(route.steps.count)")

            self.routeCalculation.status = "Starting navigation..."

            // Store the route for map display
            self.currentRoute = route

            // Start navigation from the same source MapKit used to calculate the route.
            self.navEngine.startNavigation(
                with: route,
                isTestMode: isTestMode,
                initialLocation: RouteInitialLocation.location(for: sourceItem.placemark.coordinate)
            )

            // Enable location tracking for navigation
            self.locationManager.setNavigating(!isTestMode)

            // Show navigation+workout view
            self.selectedView = 1

            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.routeCalculation.isCalculating = false
                self.routeCalculation.status = ""
            }
        }
    }
}
