//
//  NavigationEngine.swift
//  BikeComputer
//
//  Headless Navigation Engine for Bike Computer
//  Monitors location, extracts route instructions, and sends to ESP32 via BLE
//

import Foundation
import Combine
import MapKit
import CoreLocation

class NavigationEngine: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var currentInstruction: String = ""
    @Published var distanceToManeuver: Int = 0
    @Published var currentIconID: Int = 0
    @Published var isNavigating: Bool = false
    
    // MARK: - Private Properties
    private var locationManager: CLLocationManager
    private var currentRoute: MKRoute?
    private var currentStepIndex: Int = 0
    private var lastSentDistance: Int = 0
    private var lastSentInstruction: String = ""
    private var lastSentIconID: Int = 0
    
    // BLE Manager reference
    private var bleManager: BLEManager?
    
    // Distance threshold for sending updates (meters)
    private let distanceThreshold: Int = 10
    
    // MARK: - Initialization
    override init() {
        self.locationManager = CLLocationManager()
        super.init()
        setupLocationManager()
    }
    
    // MARK: - Public Methods
    
    /// Set the BLE manager for sending data to ESP32
    func setBLEManager(_ manager: BLEManager) {
        self.bleManager = manager
    }
    
    /// Start navigation with a given route
    func startNavigation(with route: MKRoute) {
        currentRoute = route
        currentStepIndex = 0
        isNavigating = true
        
        // Reset tracking
        lastSentDistance = 0
        lastSentInstruction = ""
        lastSentIconID = 0
        
        print("Navigation started with \(route.steps.count) steps")
        
        // Start location updates
        locationManager.startUpdatingLocation()
    }
    
    /// Stop navigation
    func stopNavigation() {
        isNavigating = false
        currentRoute = nil
        currentStepIndex = 0
        locationManager.stopUpdatingLocation()
        print("Navigation stopped")
    }
    
    // MARK: - Private Methods
    
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 5 // Update every 5 meters
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        
        // Request authorization
        locationManager.requestAlwaysAuthorization()
    }
    
    /// Process location update and extract navigation data
    private func processLocation(_ location: CLLocation) {
        guard let route = currentRoute, isNavigating else { return }
        
        // Check if we've completed all steps
        if currentStepIndex >= route.steps.count {
            print("Navigation complete!")
            stopNavigation()
            return
        }
        
        let currentStep = route.steps[currentStepIndex]
        let stepEndLocation = CLLocation(
            latitude: currentStep.polyline.coordinate.latitude,
            longitude: currentStep.polyline.coordinate.longitude
        )
        
        // Calculate distance to end of current step
        let distanceRemaining = Int(location.distance(from: stepEndLocation))
        
        // Check if we should advance to next step (within 20m of step end)
        if distanceRemaining < 20 && currentStepIndex < route.steps.count - 1 {
            currentStepIndex += 1
            print("Advanced to step \(currentStepIndex)")
        }
        
        // Update current navigation data
        let newStep = route.steps[currentStepIndex]
        let newInstruction = extractInstruction(from: newStep)
        let newIconID = mapInstructionToIconID(newStep.instructions)
        let newDistance = distanceRemaining
        
        // Update published properties
        currentInstruction = newInstruction
        distanceToManeuver = newDistance
        currentIconID = newIconID
        
        // Determine if we should send update to ESP32
        if shouldSendUpdate(iconID: newIconID, distance: newDistance, instruction: newInstruction) {
            sendNavigationDataToESP32(iconID: newIconID, distance: newDistance, instruction: newInstruction)
        }
    }
    
    /// Extract clean instruction text from MKRoute.Step
    private func extractInstruction(from step: MKRoute.Step) -> String {
        let instructions = step.instructions
        
        // Clean up the instruction (remove extra details if needed)
        let cleaned = instructions
            .replacingOccurrences(of: "Continue on ", with: "")
            .replacingOccurrences(of: "Turn on ", with: "")
        
        // Limit length for display
        let maxLength = 30
        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength)) + "..."
        }
        
        return cleaned
    }
    
    /// Map instruction text to icon ID for ESP32 display
    private func mapInstructionToIconID(_ instruction: String) -> Int {
        let lower = instruction.lowercased()
        
        // Icon ID mapping (customize based on your icon set)
        if lower.contains("left") {
            return lower.contains("slight") ? 1 : 2  // 1: slight left, 2: left
        } else if lower.contains("right") {
            return lower.contains("slight") ? 3 : 4  // 3: slight right, 4: right
        } else if lower.contains("u-turn") {
            return 5
        } else if lower.contains("merge") {
            return 6
        } else if lower.contains("roundabout") || lower.contains("traffic circle") {
            return 7
        } else if lower.contains("arrive") || lower.contains("destination") {
            return 8
        } else {
            return 0  // 0: straight/continue
        }
    }
    
    /// Determine if update should be sent (data changed significantly)
    private func shouldSendUpdate(iconID: Int, distance: Int, instruction: String) -> Bool {
        // Send if instruction changed (new maneuver)
        if instruction != lastSentInstruction {
            return true
        }
        
        // Send if icon changed
        if iconID != lastSentIconID {
            return true
        }
        
        // Send if distance changed by more than threshold
        if abs(distance - lastSentDistance) >= distanceThreshold {
            return true
        }
        
        return false
    }
    
    /// Send navigation data to ESP32 via BLE
    private func sendNavigationDataToESP32(iconID: Int, distance: Int, instruction: String) {
        guard let bleManager = bleManager, bleManager.isConnected else {
            print("BLE not connected, skipping send")
            return
        }
        
        // Format: "IconID|Distance|Instruction"
        let packet = "\(iconID)|\(distance)|\(instruction)"
        
        bleManager.sendNavigationData(packet)
        
        // Update last sent values
        lastSentIconID = iconID
        lastSentDistance = distance
        lastSentInstruction = instruction
        
        print("Sent to ESP32: \(packet)")
    }
}

// MARK: - CLLocationManagerDelegate

extension NavigationEngine: CLLocationManagerDelegate {
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        print("Location updated: \(location.coordinate.latitude), \(location.coordinate.longitude)")
        processLocation(location)
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager failed: \(error.localizedDescription)")
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            print("Location authorized")
        case .denied, .restricted:
            print("Location authorization denied")
        case .notDetermined:
            print("Location authorization not determined")
        @unknown default:
            break
        }
    }
}

// MARK: - Simulated Navigation for Testing

extension NavigationEngine {
    
    /// Start simulated navigation (for testing without actual GPS)
    func startSimulatedNavigation(with route: MKRoute) {
        currentRoute = route
        currentStepIndex = 0
        isNavigating = true
        
        print("Simulated navigation started")
        
        // Simulate location updates along the route
        simulateRouteProgress()
    }
    
    /// Simulate location updates along route
    private func simulateRouteProgress() {
        guard let route = currentRoute, isNavigating else { return }
        
        var simulatedDistance = 500 // Start 500m from maneuver
        
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self, self.isNavigating else {
                timer.invalidate()
                return
            }
            
            // Decrease distance
            simulatedDistance -= 25
            
            if simulatedDistance <= 0 {
                // Move to next step
                self.currentStepIndex += 1
                
                if self.currentStepIndex >= route.steps.count {
                    print("Simulated navigation complete")
                    timer.invalidate()
                    self.stopNavigation()
                    return
                }
                
                simulatedDistance = 500
            }
            
            let step = route.steps[self.currentStepIndex]
            let instruction = self.extractInstruction(from: step)
            let iconID = self.mapInstructionToIconID(step.instructions)
            
            self.currentInstruction = instruction
            self.distanceToManeuver = simulatedDistance
            self.currentIconID = iconID
            
            if self.shouldSendUpdate(iconID: iconID, distance: simulatedDistance, instruction: instruction) {
                self.sendNavigationDataToESP32(iconID: iconID, distance: simulatedDistance, instruction: instruction)
            }
        }
    }
}
