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
    
    private let bleManager = BLEManager()
    private let navEngine = NavigationEngine()
    private let locationManager = CurrentLocationManager()
    private let healthKitManager = HealthKitManager()
    
    // MARK: - Published State (UI Observable)
    
    // BLE Connection
    @Published var isConnected: Bool = false
    @Published var peripheralName: String = ""
    @Published var signalStrength: Int = 0
    
    // Navigation
    @Published var isNavigating: Bool = false
    @Published var currentInstruction: String = "Ready to Navigate"
    @Published var distanceToManeuver: Int = 0
    @Published var currentIconID: Int = 0
    @Published var currentRoute: MKRoute?
    @Published var isSimulationMode: Bool = false
    @Published var simulatedPosition: CLLocationCoordinate2D?
    
    // Workout
    @Published var isWorkoutActive: Bool = false
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
    private var transportType: MKDirectionsTransportType = {
        if #available(iOS 18.0, *) {
            return .cycling
        } else {
            return .walking
        }
    }()
    
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
        
        bleManager.$signalStrength
            .assign(to: &$signalStrength)
        
        // Bind navigation engine state
        navEngine.$isNavigating
            .sink { [weak self] navigating in
                self?.isNavigating = navigating
                self?.locationManager.setNavigating(navigating)
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
        
        // Bind health kit manager state
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
        
        locationManager.$currentAddress
            .assign(to: &$currentAddress)
            
        // Send GPS to device whenever location updates and we are connected AND ready
        locationManager.$currentLocation
            .combineLatest(bleManager.$isGPSReady)
            .sink { [weak self] location, ready in
                guard let self = self, ready, let loc = location else { return }
                // Send current position and heading to device to update map
                // CLLocation.course is -1 if invalid, 0-359 if valid
                self.bleManager.sendGPSPosition(
                    lat: loc.coordinate.latitude, 
                    lon: loc.coordinate.longitude,
                    heading: loc.course
                )
            }
            .store(in: &cancellables)
    }
    
    private func setupManagers() {
        // Wire up inter-manager dependencies
        navEngine.setBLEManager(bleManager)
        locationManager.healthKitManager = healthKitManager
        healthKitManager.locationManager = locationManager
        
        // Start BLE operations
        bleManager.startScanning()
        bleManager.startMonitoringRSSI()
        
        // Enable location tracking for map view
        locationManager.setViewingMap(true)
    }
    
    // MARK: - Public API: BLE
    
    func disconnect() {
        bleManager.disconnect()
    }
    
    // MARK: - Public API: Navigation
    
    func startNavigation(from source: String, to destination: String, transportType: MKDirectionsTransportType, isTestMode: Bool = false) {
        self.transportType = transportType
        calculateRoute(from: source, to: destination, isTestMode: isTestMode)
    }
    
    func stopNavigation() {
        navEngine.stopNavigation()
        currentRoute = nil
        locationManager.setNavigating(false)
        selectedView = 0
    }
    
    func handleDestinationSelection(coordinate: CLLocationCoordinate2D, mapLocation: CLLocation?) {
        let sourceAddress = currentAddress
        
        guard let _ = mapLocation ?? currentLocation else {
            alert.message = "Unable to determine your current location. Please enable location services."
            alert.isShowing = true
            return
        }
        
        // Convert coordinate to address
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self = self else { return }
            
            if let placemark = placemarks?.first {
                var addressComponents: [String] = []
                
                if let name = placemark.name {
                    addressComponents.append(name)
                }
                if let locality = placemark.locality {
                    addressComponents.append(locality)
                }
                
                let destinationAddress = addressComponents.isEmpty ? "Selected Location" : addressComponents.joined(separator: ", ")
                
                DispatchQueue.main.async {
                    self.calculateRoute(from: sourceAddress, to: destinationAddress)
                }
            } else {
                DispatchQueue.main.async {
                    self.alert.message = "Could not determine destination address"
                    self.alert.isShowing = true
                }
            }
        }
    }
    
    // MARK: - Public API: Workout
    
    var isHealthKitAuthorized: Bool {
        healthKitManager.isAuthorized
    }
    
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
    
    private func calculateRoute(from source: String, to destination: String, isTestMode: Bool = false) {
        print("Starting route calculation from '\(source)' to '\(destination)'")
        
        // Cancel any ongoing searches
        ongoingSourceSearch?.cancel()
        ongoingDestinationSearch?.cancel()
        ongoingDirections?.cancel()
        
        routeCalculation.isCalculating = true
        routeCalculation.status = "Searching for locations..."
        
        // Check if source is current location
        let isUsingCurrentLocation = source.contains("Current Location") || source.contains("Getting current location")
        
        if isUsingCurrentLocation, let currentLoc = currentLocation {
            // Use current location directly
            let sourceItem = MKMapItem(placemark: MKPlacemark(coordinate: currentLoc.coordinate))
            sourceItem.name = "Current Location"
            
            print("Using current location: \(currentLoc.coordinate.latitude), \(currentLoc.coordinate.longitude)")
            routeCalculation.status = "Finding destination..."
            
            findDestinationAndCalculateRoute(from: sourceItem, destination: destination, isTestMode: isTestMode)
        } else {
            // Use MKLocalSearch for source address
            let sourceSearchRequest = MKLocalSearch.Request()
            sourceSearchRequest.naturalLanguageQuery = source
            
            let sourceSearch = MKLocalSearch(request: sourceSearchRequest)
            ongoingSourceSearch = sourceSearch
            sourceSearch.start { [weak self] response, error in
                guard let self = self else { return }
                self.ongoingSourceSearch = nil
                
                if let error = error {
                    print("Error searching for source: \(error.localizedDescription)")
                    self.routeCalculation.status = "Could not find starting location"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.routeCalculation.isCalculating = false
                        self.routeCalculation.status = ""
                    }
                    return
                }
                
                guard let sourceItem = response?.mapItems.first else {
                    print("No results for source location")
                    self.routeCalculation.status = "Starting location not found"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.routeCalculation.isCalculating = false
                        self.routeCalculation.status = ""
                    }
                    return
                }
                
                print("Source found: \(sourceItem.name ?? "Unknown") at \(sourceItem.placemark.coordinate.latitude), \(sourceItem.placemark.coordinate.longitude)")
                self.routeCalculation.status = "Finding destination..."
                
                self.findDestinationAndCalculateRoute(from: sourceItem, destination: destination, isTestMode: isTestMode)
            }
        }
    }
    
    private func findDestinationAndCalculateRoute(from sourceItem: MKMapItem, destination: String, isTestMode: Bool = false) {
        let destinationSearchRequest = MKLocalSearch.Request()
        destinationSearchRequest.naturalLanguageQuery = destination
        
        let destinationSearch = MKLocalSearch(request: destinationSearchRequest)
        ongoingDestinationSearch = destinationSearch
        destinationSearch.start { [weak self] response, error in
            guard let self = self else { return }
            self.ongoingDestinationSearch = nil
            
            if let error = error {
                print("Error searching for destination: \(error.localizedDescription)")
                self.routeCalculation.status = "Could not find destination"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.routeCalculation.isCalculating = false
                    self.routeCalculation.status = ""
                }
                return
            }
            
            guard let destinationItem = response?.mapItems.first else {
                print("No results for destination location")
                self.routeCalculation.status = "Destination not found"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.routeCalculation.isCalculating = false
                    self.routeCalculation.status = ""
                }
                return
            }
            
            print("Destination found: \(destinationItem.name ?? "Unknown") at \(destinationItem.placemark.coordinate.latitude), \(destinationItem.placemark.coordinate.longitude)")
            self.routeCalculation.status = "Calculating route..."
            
            // Now calculate the route
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
                    self.routeCalculation.status = "Route calculation failed"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
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
                
                // Start navigation
                self.navEngine.startNavigation(with: route, isTestMode: isTestMode)
                
                // Enable location tracking for navigation
                self.locationManager.setNavigating(true)
                
                // Show navigation+workout view
                self.selectedView = 1
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.routeCalculation.isCalculating = false
                    self.routeCalculation.status = ""
                }
            }
        }
    }
}

