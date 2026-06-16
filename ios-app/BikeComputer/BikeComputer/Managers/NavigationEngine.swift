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
    @Published var currentIconID: Int = NavigationIconID.straight
    @Published var isNavigating: Bool = false
    @Published var isSimulationMode: Bool = false
    @Published var simulatedPosition: CLLocationCoordinate2D?
    
    // MARK: - Private Properties
    private var locationManager: CLLocationManager
    private var currentRoute: MKRoute?
    private var currentStepIndex: Int = 0
    private var lastSentDistance: Int = 0
    private var lastSentInstruction: String = ""
    private var lastSentIconID: Int = 0
    
    // Simulation state
    private var simulationTimer: Timer?
    private var simulationProgress: Double = 0.0 // 0.0 to 1.0 along route
    private var simulationSpeed: Double = 10.0 // meters per second (~36 km/h)
    private var lastSimulationUpdate: Date?
    
    // Route geometry state
    private var lastSentGeometryHash: Int = 0
    private var geometrySendInterval: TimeInterval = 2.0  // Send geometry every 2 seconds
    private var lastGeometrySendTime: Date = .distantPast
    
    // BLE Manager reference
    private var bleManager: BLEManager?
    private var cancellables = Set<AnyCancellable>()
    
    // Distance threshold for sending updates (meters)
    private let distanceThreshold: Int = 10
    
    // Route geometry window size (number of points)
    private let geometryWindowSize: Int = 30
    
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
        manager.$isRouteReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isReady in
                guard let self = self, isReady else { return }
                print("BLE Route Ready: Resetting route geometry state to force resend")
                self.lastSentGeometryHash = 0
                self.lastGeometrySendTime = Date.distantPast

                if self.isNavigating, let route = self.currentRoute, route.polyline.pointCount > 0 {
                    var startCoord = CLLocationCoordinate2D()
                    route.polyline.getCoordinates(&startCoord, range: NSRange(location: 0, length: 1))
                    let startLoc = CLLocation(latitude: startCoord.latitude, longitude: startCoord.longitude)
                    self.sendRouteGeometryIfNeeded(currentLocation: startLoc)
                }
            }
            .store(in: &cancellables)
    }

    func processExternalLocation(_ location: CLLocation) {
        guard !isSimulationMode else { return }
        processLocation(location)
    }
    
    /// Start navigation with a given route
    func startNavigation(with route: MKRoute, isTestMode: Bool = false) {
        currentRoute = route
        currentStepIndex = 0
        isSimulationMode = isTestMode
        isNavigating = true
        
        // Reset tracking
        lastSentDistance = 0
        lastSentInstruction = ""
        lastSentIconID = 0
        
        print("Navigation started with \(route.steps.count) steps (Test Mode: \(isTestMode))")
        
        if isTestMode {
            startSimulation()
        } else {
            // Real location updates are supplied by CurrentLocationManager.
        }
    }
    
    /// Stop navigation
    func stopNavigation() {
        isNavigating = false
        currentRoute = nil
        currentStepIndex = 0
        stopSimulation()
        print("Navigation stopped")
    }
    
    // MARK: - Simulation Methods
    
    private func startSimulation() {
        print("Starting simulated navigation")
        simulationProgress = 0.0
        lastSimulationUpdate = Date()
        
        simulationTimer?.invalidate()
        simulationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateSimulation()
        }
        // Add timer to RunLoop to ensure it fires in common run loop modes (including background)
        RunLoop.current.add(simulationTimer!, forMode: .common)
    }
    
    internal func stopSimulation() {
        simulationTimer?.invalidate()
        simulationTimer = nil
        isSimulationMode = false
        simulatedPosition = nil
    }
    
    private var lastSimulatedPosition: CLLocationCoordinate2D?  // Track for heading calculation
    
    private func updateSimulation() {
        guard let route = currentRoute, let lastUpdate = lastSimulationUpdate else { return }
        
        let now = Date()
        let timeDelta = now.timeIntervalSince(lastUpdate)
        lastSimulationUpdate = now
        
        // Calculate distance covered in this time step
        let distanceCovered = simulationSpeed * timeDelta
        let totalDistance = route.distance
        
        // Update progress
        let progressDelta = distanceCovered / totalDistance
        simulationProgress += progressDelta
        
        if simulationProgress >= 1.0 {
            simulationProgress = 1.0
            print("Simulation complete")
            stopSimulation()
            stopNavigation()
            return
        }
        
        // Calculate position
        if let position = interpolatePositionAlongRoute(progress: simulationProgress) {
            simulatedPosition = position
            
            // Calculate heading from last position to current position
            var heading: Double = 0
            if let lastPos = lastSimulatedPosition {
                heading = calculateBearing(from: lastPos, to: position)
            }
            lastSimulatedPosition = position
            
            // Send to ESP32 with heading
            // Simulation points are from Apple Maps route (GCJ-02), so convert to WGS-84
            let convertedPos = CoordinateConverter.gcj02ToWGS84(coordinate: position)
            bleManager?.sendGPSPosition(lat: convertedPos.latitude, lon: convertedPos.longitude, heading: heading)
            
            // Trigger geometry update if needed
            let location = CLLocation(latitude: position.latitude, longitude: position.longitude)
            sendRouteGeometryIfNeeded(currentLocation: location)
            
            // Also process location for navigation instructions
            processLocation(location)
        }
    }
    
    /// Calculate bearing (heading) from one coordinate to another
    private func calculateBearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var bearing = atan2(y, x) * 180 / .pi
        
        // Normalize to 0-360
        if bearing < 0 { bearing += 360 }
        return bearing
    }
    
    private func interpolatePositionAlongRoute(progress: Double) -> CLLocationCoordinate2D? {
        guard let route = currentRoute else { return nil }
        
        let polyline = route.polyline
        let pointCount = polyline.pointCount
        guard pointCount > 1 else { return nil }
        
        var points = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        polyline.getCoordinates(&points, range: NSRange(location: 0, length: pointCount))
        
        let targetDistance = progress * route.distance
        var currentDist = 0.0
        
        for i in 0..<(pointCount - 1) {
            let p1 = CLLocation(latitude: points[i].latitude, longitude: points[i].longitude)
            let p2 = CLLocation(latitude: points[i+1].latitude, longitude: points[i+1].longitude)
            let dist = p1.distance(from: p2)
            
            if currentDist + dist >= targetDistance {
                // We are in this segment
                let remaining = targetDistance - currentDist
                let ratio = remaining / dist
                
                let lat = points[i].latitude + (points[i+1].latitude - points[i].latitude) * ratio
                let lon = points[i].longitude + (points[i+1].longitude - points[i].longitude) * ratio
                
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            
            currentDist += dist
        }
        
        return points.last
    }

    /// Send test navigation data for BLE testing
    func sendTestNavigationData() {
        guard let bleManager = bleManager, bleManager.isConnected else {
            print("BLE not connected, cannot send test data")
            return
        }

        // Test data packets with different navigation scenarios
        let testPackets = [
            "\(NavigationIconID.left)|150|Turn Left onto Main St",
            "\(NavigationIconID.right)|300|Slight Right onto Oak Ave",
            "\(NavigationIconID.straight)|75|Continue straight for 75m",
            "\(NavigationIconID.uTurn)|0|Make U-turn",
            "\(NavigationIconID.straight)|25|Arrive at destination"
        ]

        // Send test route geometry first
        sendTestRouteGeometry()

        // Send each test packet with a delay
        for (index, packet) in testPackets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 2.0) {
                print("Sending test data: \(packet)")
                self.bleManager?.sendNavigationData(packet)
            }
        }

        print("Started sending test navigation data sequence")
    }

    /// Send a synthetic test route geometry for debugging
    private func sendTestRouteGeometry() {
        guard let bleManager = bleManager, bleManager.isConnected else { return }

        print("Generating test route geometry...")

        // Start at default location (Kusel, Germany: 49.623877, 7.550343)
        let startLat = 49.623877
        let startLon = 7.550343

        var points: [CLLocationCoordinate2D] = []
        points.append(CLLocationCoordinate2D(latitude: startLat, longitude: startLon))

        // Create an L-shape route:
        // 1. Go North ~200m
        for i in 1...10 {
            points.append(CLLocationCoordinate2D(
                latitude: startLat + (Double(i) * 0.00020), // ~20m per step North
                longitude: startLon
            ))
        }

        // 2. Turn East ~200m
        let cornerLat = startLat + 0.0020
        for i in 1...10 {
            points.append(CLLocationCoordinate2D(
                latitude: cornerLat,
                longitude: startLon + (Double(i) * 0.00030) // ~20m per step East
            ))
        }

        let geometryData = compressRoutePoints(points)
        bleManager.sendRouteGeometry(geometryData)
        print("Sent test route geometry: \(geometryData.count) bytes")
    }
    
    // MARK: - Private Methods
    
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 5 // Update every 5 meters
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = false
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
        guard let stepEndLocation = endpointLocation(for: currentStep) else { return }
        
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

        // Recalculate distance to the new step's endpoint after advancement
        guard let newStepEndLocation = endpointLocation(for: newStep) else { return }
        let newDistance = Int(location.distance(from: newStepEndLocation))
        
        // Update published properties
        currentInstruction = newInstruction
        distanceToManeuver = newDistance
        currentIconID = newIconID
        
        // Determine if we should send update to ESP32
        if shouldSendUpdate(iconID: newIconID, distance: newDistance, instruction: newInstruction) {
            sendNavigationDataToESP32(iconID: newIconID, distance: newDistance, instruction: newInstruction)
        }
        
        // Send route geometry for map overlay (rate-limited internally)
        sendRouteGeometryIfNeeded(currentLocation: location)
    }

    private func endpointLocation(for step: MKRoute.Step) -> CLLocation? {
        RoutePolylineEndpoint.location(for: step.polyline)
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
        NavigationInstructionMapper.iconID(for: instruction)
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
        
        // Send initial geometry (window around start point)
        // This ensures overlay appears even in simulation mode
        if route.polyline.pointCount > 0 {
             var startCoord = CLLocationCoordinate2D()
             route.polyline.getCoordinates(&startCoord, range: NSRange(location: 0, length: 1))
             
             let startLoc = CLLocation(latitude: startCoord.latitude, longitude: startCoord.longitude)
             sendRouteGeometryIfNeeded(currentLocation: startLoc)
        }
        
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

// MARK: - Route Geometry Extraction for Map Overlay

extension NavigationEngine {
    
    /// Extract next ~30 points from route polyline relative to user's current location
    /// Uses a sliding window approach to always show the upcoming route segment
    func extractSlidingWindowGeometry(currentLocation: CLLocation) -> Data? {
        guard let route = currentRoute else { return nil }
        
        // Get all polyline points from the route
        let polyline = route.polyline
        let pointCount = polyline.pointCount
        
        guard pointCount > 0 else { return nil }
        
        var points = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        polyline.getCoordinates(&points, range: NSRange(location: 0, length: pointCount))
        
        // Find the closest point to user's current location
        var closestIndex = 0
        var closestDistance = Double.greatestFiniteMagnitude
        
        for (i, point) in points.enumerated() {
            let pointLocation = CLLocation(latitude: point.latitude, longitude: point.longitude)
            let dist = currentLocation.distance(from: pointLocation)
            if dist < closestDistance {
                closestDistance = dist
                closestIndex = i
            }
        }
        
        // Extract window of points starting from closest point
        let endIndex = min(closestIndex + geometryWindowSize, pointCount)
        let windowPoints = Array(points[closestIndex..<endIndex])
        
        guard !windowPoints.isEmpty else { return nil }
        
        return compressRoutePoints(windowPoints)
    }
    
    /// Compress route points to binary format for efficient BLE transfer
    /// Format: [StartLat:4][StartLon:4][DeltaLat:2][DeltaLon:2]...
    /// Uses microdegrees (lat * 1,000,000) for ~0.1m precision
    /// Apple Maps returns routes in GCJ-02 in China, convert to WGS-84 for map tiles
    private func compressRoutePoints(_ points: [CLLocationCoordinate2D]) -> Data {
        guard let first = points.first else { return Data() }
        
        // Convert first point from GCJ-02 (Apple Maps) to WGS-84 (our map tiles)
        let firstConverted = CoordinateConverter.gcj02ToWGS84(coordinate: first)
        
        print("Route: Raw(\(first.latitude), \(first.longitude)) -> WGS(\(firstConverted.latitude), \(firstConverted.longitude))")
        
        var data = Data()
        
        // Start point: 4 bytes lat, 4 bytes lon (scaled Int32 in microdegrees)
        let startLat = Int32(firstConverted.latitude * 1_000_000)
        let startLon = Int32(firstConverted.longitude * 1_000_000)
        
        // Append as little-endian (ESP32 is little-endian)
        withUnsafeBytes(of: startLat.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: startLon.littleEndian) { data.append(contentsOf: $0) }
        
        // Delta points: 2 bytes each (Int16 delta from previous point)
        // Max delta of ~3.2km at 0.1m precision per axis
        var prevLat = startLat
        var prevLon = startLon
        
        for point in points.dropFirst() {
            // Convert each point from GCJ-02 (Apple Maps) to WGS-84
            let converted = CoordinateConverter.gcj02ToWGS84(coordinate: point)
            let lat = Int32(converted.latitude * 1_000_000)
            let lon = Int32(converted.longitude * 1_000_000)
            
            // Clamp deltas to Int16 range (-32768 to 32767)
            // This gives us ~3.2km range per step at 0.1m precision
            let deltaLat = Int16(clamping: lat - prevLat)
            let deltaLon = Int16(clamping: lon - prevLon)
            
            withUnsafeBytes(of: deltaLat.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: deltaLon.littleEndian) { data.append(contentsOf: $0) }
            
            prevLat = lat
            prevLon = lon
        }
        
        return data
    }
    
    /// Send route geometry to ESP32 if enough time has passed
    func sendRouteGeometryIfNeeded(currentLocation: CLLocation) {
        guard let bleManager = bleManager, bleManager.isConnected else { return }
        
        // Rate limit geometry updates
        let now = Date()
        guard now.timeIntervalSince(lastGeometrySendTime) >= geometrySendInterval else { return }
        
        guard let geometryData = extractSlidingWindowGeometry(currentLocation: currentLocation) else {
            return
        }
        
        // Check if geometry has changed (simple hash of data)
        let hash = geometryData.hashValue
        guard hash != lastSentGeometryHash else { return }
        
        // Send the compressed geometry
        bleManager.sendRouteGeometry(geometryData)
        
        lastGeometrySendTime = now
        lastSentGeometryHash = hash
        
        print("Route geometry sent: \(geometryData.count) bytes, hash: \(hash)")
    }
}
