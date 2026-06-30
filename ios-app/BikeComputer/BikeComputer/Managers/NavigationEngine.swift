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
    private var currentRoute: MKRoute?
    private var currentStepIndex: Int = 0
    private var currentSnapshot: NavigationManeuverSnapshot?
    private var sendTracker = NavigationSendTracker(distanceThreshold: 10)
    private var initialNavigationLocation: CLLocation?
    private var lastDeviceGpsLocation: (location: CLLocation, convertFromMapKitRoute: Bool)?
    private var hasAcceptedLiveLocation = false
    private var lastSentGeometryHash: Int = 0
    private var geometrySendInterval: TimeInterval = 2.0
    private var lastGeometrySendTime: Date = .distantPast
    private let geometryWindowSize: Int = 30
    
    // Simulation state
    private var simulationTimer: Timer?
    private var simulationProgress: Double = 0.0 // 0.0 to 1.0 along route
    private var simulationSpeed: Double = 10.0 // meters per second (~36 km/h)
    private var lastSimulationUpdate: Date?
    
    // BLE Manager reference
    private var bleManager: BLEManager?
    private var cancellables = Set<AnyCancellable>()
    private let liveLocationStartTolerance: CLLocationDistance = 150
    
    // MARK: - Public Methods
    
    /// Set the BLE manager for sending data to ESP32
    func setBLEManager(_ manager: BLEManager) {
        self.bleManager = manager
        cancellables.removeAll()

        manager.$isNavigationReady
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isReady in
                guard isReady else { return }
                self?.resendCurrentDeviceGpsPosition()
                self?.resendCurrentRouteGeometry()
                self?.resendCurrentNavigationState()
            }
            .store(in: &cancellables)
    }

    func processExternalLocation(_ location: CLLocation) {
        guard !isSimulationMode else { return }
        sendDeviceGpsPosition(location, convertFromMapKitRoute: false)
        let routeLocation = CoordinateConverter.mapKitRouteLocation(fromGPSLocation: location)
        guard shouldAcceptLiveLocation(routeLocation) else { return }
        processLocation(routeLocation)
    }
    
    /// Start navigation with a given route
    func startNavigation(with route: MKRoute, isTestMode: Bool = false, initialLocation: CLLocation? = nil) {
        currentRoute = route
        currentStepIndex = 0
        isSimulationMode = isTestMode
        isNavigating = true
        
        currentSnapshot = nil
        sendTracker.reset()
        initialNavigationLocation = initialLocation
        hasAcceptedLiveLocation = initialLocation == nil
        lastSentGeometryHash = 0
        lastGeometrySendTime = .distantPast
        
        print("Navigation started with \(route.steps.count) steps (Test Mode: \(isTestMode))")
        
        if isTestMode {
            startSimulation()
        } else if let initialLocation {
            sendDeviceGpsPosition(initialLocation, convertFromMapKitRoute: true)
            sendRouteGeometryIfNeeded(currentLocation: initialLocation)
            processLocation(initialLocation)
        }
    }
    
    /// Stop navigation
    func stopNavigation() {
        isNavigating = false
        currentRoute = nil
        currentStepIndex = 0
        currentSnapshot = nil
        sendTracker.reset()
        initialNavigationLocation = nil
        lastDeviceGpsLocation = nil
        hasAcceptedLiveLocation = false
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
            
            let location = CLLocation(latitude: position.latitude, longitude: position.longitude)
            sendDeviceGpsPosition(location, convertFromMapKitRoute: true)
            
            // Also process location for navigation instructions
            processLocation(location)
        }
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

        // Send each test packet with a delay
        for (index, packet) in testPackets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 2.0) {
                print("Sending test data: \(packet)")
                self.bleManager?.sendNavigationData(packet)
            }
        }

        print("Started sending test navigation data sequence")
    }
    
    // MARK: - Private Methods
    
    /// Process location update and extract navigation data
    private func processLocation(_ location: CLLocation) {
        guard let route = currentRoute, isNavigating else { return }
        sendRouteGeometryIfNeeded(currentLocation: location)
        
        // Check if we've completed all steps
        if currentStepIndex >= route.steps.count {
            print("Navigation complete!")
            stopNavigation()
            return
        }

        guard advanceToNextNavigableStep(in: route) else {
            print("Navigation route has no navigable steps")
            return
        }
        
        let currentStep = route.steps[currentStepIndex]
        guard let stepEndLocation = endpointLocation(for: currentStep) else { return }
        
        // Calculate distance to end of current step
        let distanceRemaining = Int(location.distance(from: stepEndLocation))
        
        // Check if we should advance to next step (within 20m of step end)
        if distanceRemaining < 20 && currentStepIndex < route.steps.count - 1 {
            currentStepIndex += 1
            _ = advanceToNextNavigableStep(in: route)
            print("Advanced to step \(currentStepIndex)")
        }
        
        // Update current navigation data
        let newStep = route.steps[currentStepIndex]
        let newInstruction = extractInstruction(from: newStep)
        let newIconID = mapInstructionToIconID(newInstruction)

        // Recalculate distance to the new step's endpoint after advancement
        guard let newStepEndLocation = endpointLocation(for: newStep) else { return }
        let newDistance = Int(location.distance(from: newStepEndLocation))
        let snapshot = NavigationManeuverSnapshot(iconID: newIconID, distance: newDistance, instruction: newInstruction)
        currentSnapshot = snapshot
        
        // Update published properties
        currentInstruction = snapshot.instruction
        distanceToManeuver = snapshot.distance
        currentIconID = snapshot.iconID
        
        // Determine if we should send update to ESP32
        if sendTracker.shouldSend(snapshot) {
            sendNavigationDataToESP32(snapshot)
        }

        sendRouteGeometryIfNeeded(currentLocation: location)
    }

    private func endpointLocation(for step: MKRoute.Step) -> CLLocation? {
        RoutePolylineEndpoint.location(for: step.polyline)
    }

    private func advanceToNextNavigableStep(in route: MKRoute) -> Bool {
        while currentStepIndex < route.steps.count,
              endpointLocation(for: route.steps[currentStepIndex]) == nil {
            print("Skipping route step without geometry at index \(currentStepIndex)")
            currentStepIndex += 1
        }

        return currentStepIndex < route.steps.count
    }

    private func shouldAcceptLiveLocation(_ location: CLLocation) -> Bool {
        guard !hasAcceptedLiveLocation, let initialNavigationLocation else {
            return true
        }

        guard location.distance(from: initialNavigationLocation) <= liveLocationStartTolerance else {
            print("Ignoring live location until device is near route start")
            return false
        }

        hasAcceptedLiveLocation = true
        return true
    }

    private func resendCurrentNavigationState() {
        guard isNavigating, let currentSnapshot else { return }

        sendTracker.resetForReadinessRetry()
        sendNavigationDataToESP32(currentSnapshot)
    }

    private func resendCurrentRouteGeometry() {
        guard isNavigating, let route = currentRoute, route.polyline.pointCount > 0 else { return }

        var startCoordinate = CLLocationCoordinate2D()
        route.polyline.getCoordinates(&startCoordinate, range: NSRange(location: 0, length: 1))
        lastSentGeometryHash = 0
        lastGeometrySendTime = .distantPast
        sendRouteGeometryIfNeeded(currentLocation: CLLocation(latitude: startCoordinate.latitude,
                                                              longitude: startCoordinate.longitude))
    }

    private func resendCurrentDeviceGpsPosition() {
        guard isNavigating, let lastDeviceGpsLocation else { return }

        sendDeviceGpsPosition(lastDeviceGpsLocation.location,
                              convertFromMapKitRoute: lastDeviceGpsLocation.convertFromMapKitRoute)
    }
    
    /// Extract clean instruction text from MKRoute.Step
    private func extractInstruction(from step: MKRoute.Step) -> String {
        let instructions = step.instructions
        
        // Clean up the instruction (remove extra details if needed)
        let cleaned = instructions
            .replacingOccurrences(of: "Continue on ", with: "")
            .replacingOccurrences(of: "Turn on ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return "Continue"
        }
        
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
    
    /// Send navigation data to ESP32 via BLE
    private func sendNavigationDataToESP32(_ snapshot: NavigationManeuverSnapshot) {
        guard let bleManager = bleManager, bleManager.isConnected else {
            print("BLE not connected, skipping send")
            return
        }
        
        guard bleManager.sendNavigationData(snapshot.packet) else {
            print("BLE navigation characteristic not ready, will retry on next update")
            return
        }
        
        sendTracker.markSent(snapshot)
        
        print("Sent to ESP32: \(snapshot.packet)")
    }

    private func sendDeviceGpsPosition(_ location: CLLocation, convertFromMapKitRoute: Bool) {
        lastDeviceGpsLocation = (location, convertFromMapKitRoute)
        let wgsCoordinate = convertFromMapKitRoute
            ? CoordinateConverter.gcj02ToWGS84(coordinate: location.coordinate)
            : location.coordinate
        let heading = location.course >= 0 ? location.course : 0
        bleManager?.sendGPSPosition(lat: wgsCoordinate.latitude,
                                    lon: wgsCoordinate.longitude,
                                    heading: heading)
    }
}

// MARK: - Route Geometry for Device Map

extension NavigationEngine {
    func extractSlidingWindowGeometry(currentLocation: CLLocation) -> Data? {
        guard let route = currentRoute else { return nil }

        let polyline = route.polyline
        let pointCount = polyline.pointCount
        guard pointCount > 0 else { return nil }

        var points = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        polyline.getCoordinates(&points, range: NSRange(location: 0, length: pointCount))

        var closestIndex = 0
        var closestDistance = Double.greatestFiniteMagnitude
        for (index, point) in points.enumerated() {
            let pointLocation = CLLocation(latitude: point.latitude, longitude: point.longitude)
            let distance = currentLocation.distance(from: pointLocation)
            if distance < closestDistance {
                closestDistance = distance
                closestIndex = index
            }
        }

        let endIndex = min(closestIndex + geometryWindowSize, pointCount)
        let windowPoints = Array(points[closestIndex..<endIndex])
        guard !windowPoints.isEmpty else { return nil }

        return compressRoutePoints(windowPoints)
    }

    private func compressRoutePoints(_ points: [CLLocationCoordinate2D]) -> Data {
        guard let first = points.first else { return Data() }

        let firstConverted = CoordinateConverter.gcj02ToWGS84(coordinate: first)
        var data = Data()
        let startLat = Int32(firstConverted.latitude * 1_000_000)
        let startLon = Int32(firstConverted.longitude * 1_000_000)
        withUnsafeBytes(of: startLat.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: startLon.littleEndian) { data.append(contentsOf: $0) }

        var previousLat = startLat
        var previousLon = startLon
        for point in points.dropFirst() {
            let converted = CoordinateConverter.gcj02ToWGS84(coordinate: point)
            let lat = Int32(converted.latitude * 1_000_000)
            let lon = Int32(converted.longitude * 1_000_000)
            let deltaLat = Int16(clamping: lat - previousLat)
            let deltaLon = Int16(clamping: lon - previousLon)
            withUnsafeBytes(of: deltaLat.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: deltaLon.littleEndian) { data.append(contentsOf: $0) }
            previousLat = lat
            previousLon = lon
        }

        return data
    }

    func sendRouteGeometryIfNeeded(currentLocation: CLLocation) {
        guard let bleManager = bleManager,
              bleManager.isConnected,
              bleManager.isNavigationReady else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastGeometrySendTime) >= geometrySendInterval else { return }
        guard let geometryData = extractSlidingWindowGeometry(currentLocation: currentLocation) else { return }

        let hash = geometryData.hashValue
        guard hash != lastSentGeometryHash else { return }

        bleManager.sendRouteGeometry(geometryData)
        lastGeometrySendTime = now
        lastSentGeometryHash = hash
    }
}
