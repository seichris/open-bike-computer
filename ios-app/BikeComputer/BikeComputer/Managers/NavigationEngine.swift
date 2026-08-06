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
    @Published var routeRemainingDistance: CLLocationDistance?
    @Published var routeRemainingTime: TimeInterval?
    @Published var expectedArrivalDate: Date?
    
    // MARK: - Private Properties
    private var currentRoute: MKRoute?
    private var currentStepIndex: Int = 0
    private var currentSnapshot: NavigationManeuverSnapshot?
    private var lastManeuverStepIndex: Int?
    private var lastManeuverRemainingDistance: CLLocationDistance?
    private var sendTracker = NavigationSendTracker(distanceThreshold: 10)
    private var initialNavigationLocation: CLLocation?
    private var lastDeviceGpsLocation: (location: CLLocation, convertFromMapKitRoute: Bool)?
    private var latestExternalGpsLocation: CLLocation?
    private var hasAcceptedLiveLocation = false
    private var lastSentGeometryHash: Int = 0
    private var geometrySendInterval: TimeInterval = 2.0
    private var lastGeometrySendTime: Date = .distantPast
    private let geometryWindowSize: Int = 30
    private var rideStartDate: Date?
    @Published private(set) var rideDistanceMeters: CLLocationDistance = 0
    private var lastRideLocation: CLLocation?
    private var lastRouteRemainingMeters: CLLocationDistance?
    private var rideTelemetryTimer: Timer?
    private let rideTelemetryRefreshInterval: TimeInterval = 1.0
    private let now: () -> Date
    
    // Simulation state
    private var simulationTimer: Timer?
    private var simulationProgress: Double = 0.0 // 0.0 to 1.0 along route
    private var simulationSpeed: Double = 10.0 // meters per second (~36 km/h)
    private var lastSimulationUpdate: Date?
    private var lastSimulationLogicUpdate: Date?
    private let simulationPresentationInterval: TimeInterval = 1.0 / 30.0
    private let simulationLogicInterval: TimeInterval = 0.2
    
    // BLE Manager reference
    private var bleManager: BLEManager?
    private var cancellables = Set<AnyCancellable>()
    private let liveLocationStartTolerance: CLLocationDistance = 150
    private let maneuverArrivalRadius: CLLocationDistance = 20

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        super.init()
    }

    deinit {
        rideTelemetryTimer?.invalidate()
        simulationTimer?.invalidate()
    }
    
    // MARK: - Public Methods
    
    /// Set the BLE manager for sending data to ESP32
    func setBLEManager(_ manager: BLEManager) {
        self.bleManager = manager
        cancellables.removeAll()

        manager.$isNavigationReady
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isReady in
                guard isReady, let self else { return }
                self.resendCurrentDeviceGpsPosition()
                guard self.isNavigating else {
                    self.bleManager?.clearRouteGeometry()
                    return
                }
                self.resendCurrentRouteGeometry()
                self.resendCurrentNavigationState()
            }
            .store(in: &cancellables)
    }

    @discardableResult
    func processExternalLocation(_ location: CLLocation) -> Bool {
        latestExternalGpsLocation = location
        guard !isSimulationMode else { return false }
        let routeLocation = CoordinateConverter.mapKitRouteLocation(fromGPSLocation: location)
        let acceptedRouteLocation: CLLocation?
        if shouldAcceptLiveLocation(routeLocation) {
            processLocation(routeLocation)
            acceptedRouteLocation = routeLocation
        } else {
            acceptedRouteLocation = nil
        }
        if isNavigating {
            updateRideTelemetry(gpsLocation: location, routeLocation: acceptedRouteLocation)
            sendDeviceGpsPosition(location, convertFromMapKitRoute: false)
        } else {
            sendDeviceGpsPosition(location,
                                  convertFromMapKitRoute: false,
                                  includeRideTelemetry: false)
        }
        return acceptedRouteLocation != nil
    }
    
    /// Start navigation with a given route
    func startNavigation(with route: MKRoute, isTestMode: Bool = false, initialLocation: CLLocation? = nil) {
        currentRoute = route
        currentStepIndex = 0
        isSimulationMode = isTestMode
        isNavigating = true
        
        currentSnapshot = nil
        lastManeuverStepIndex = nil
        lastManeuverRemainingDistance = nil
        sendTracker.reset()
        initialNavigationLocation = initialLocation
        hasAcceptedLiveLocation = initialLocation == nil
        lastSentGeometryHash = 0
        lastGeometrySendTime = .distantPast
        resetRideTelemetry(startingAt: initialLocation)
        updateNavigationSummary(route: route, remainingDistance: route.distance)
        
        print("Navigation started with \(route.steps.count) steps (Test Mode: \(isTestMode))")
        
        if isTestMode {
            startSimulation()
        } else {
            startRideTelemetryTimer()
            if let initialLocation {
                sendRouteGeometryIfNeeded(currentLocation: initialLocation)
                processLocation(initialLocation)
                updateRideTelemetry(gpsLocation: initialLocation, routeLocation: initialLocation)
                sendInitialDeviceGpsPosition(initialLocation, convertFromMapKitRoute: true)
            }
        }
    }

    /// Replace an active route after rerouting without resetting ride telemetry.
    func replaceRoute(
        with route: MKRoute,
        currentLocation: CLLocation
    ) {
        guard isNavigating, !isSimulationMode else { return }

        currentRoute = route
        currentStepIndex = RouteStepSelection.closestNavigableStepIndex(
            to: currentLocation,
            in: route
        ) ?? 0
        currentSnapshot = nil
        lastManeuverStepIndex = nil
        lastManeuverRemainingDistance = nil
        sendTracker.reset()
        initialNavigationLocation = nil
        hasAcceptedLiveLocation = true
        lastSentGeometryHash = 0
        lastGeometrySendTime = .distantPast

        let remainingDistance = RouteProgress.remainingDistance(from: currentLocation, in: route) ?? route.distance
        lastRouteRemainingMeters = remainingDistance
        updateNavigationSummary(route: route, remainingDistance: remainingDistance)
        processLocation(currentLocation)
        resendCurrentDeviceGpsPosition()

        print("Navigation route replaced with \(route.steps.count) steps")
    }

    func distanceToCurrentStep(from location: CLLocation) -> CLLocationDistance? {
        guard let route = currentRoute,
              currentStepIndex < route.steps.count else { return nil }

        return route.steps[currentStepIndex...].lazy.compactMap {
            RouteDeviation.distance(from: location, to: $0.polyline)
        }.first
    }
    
    /// Stop navigation
    func stopNavigation() {
        let deviceLocationToRestore: (location: CLLocation, convertFromMapKitRoute: Bool)? = {
            if isSimulationMode, let latestExternalGpsLocation {
                return (latestExternalGpsLocation, false)
            }
            return lastDeviceGpsLocation
        }()
        stopRideTelemetryTimer()
        bleManager?.clearRouteGeometry()
        isNavigating = false
        currentRoute = nil
        currentStepIndex = 0
        currentSnapshot = nil
        lastManeuverStepIndex = nil
        lastManeuverRemainingDistance = nil
        sendTracker.reset()
        initialNavigationLocation = nil
        lastDeviceGpsLocation = nil
        hasAcceptedLiveLocation = false
        lastSentGeometryHash = 0
        lastGeometrySendTime = .distantPast
        routeRemainingDistance = nil
        routeRemainingTime = nil
        expectedArrivalDate = nil
        resetRideTelemetry(startingAt: nil)
        stopSimulation()
        if let deviceLocationToRestore {
            sendDeviceGpsPosition(deviceLocationToRestore.location,
                                  convertFromMapKitRoute: deviceLocationToRestore.convertFromMapKitRoute,
                                  includeRideTelemetry: false)
        }
        print("Navigation stopped")
    }
    
    // MARK: - Simulation Methods
    
    private func startSimulation() {
        print("Starting simulated navigation")
        simulationProgress = 0.0
        lastSimulationUpdate = Date()
        lastSimulationLogicUpdate = nil
        
        simulationTimer?.invalidate()
        simulationTimer = Timer.scheduledTimer(withTimeInterval: simulationPresentationInterval, repeats: true) { [weak self] _ in
            self?.updateSimulation()
        }
        // Add timer to RunLoop to ensure it fires in common run loop modes (including background)
        RunLoop.current.add(simulationTimer!, forMode: .common)
    }
    
    internal func stopSimulation() {
        simulationTimer?.invalidate()
        simulationTimer = nil
        lastSimulationLogicUpdate = nil
        isSimulationMode = false
        simulatedPosition = nil
    }

    #if HOST_TESTING
    func updateSimulationForTesting(timeInterval: TimeInterval) {
        guard isSimulationMode else { return }
        lastSimulationUpdate = Date().addingTimeInterval(-timeInterval)
        updateSimulation()
    }
    #endif
    
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
            stopNavigation()
            return
        }
        
        // Calculate position
        if let position = interpolatePositionAlongRoute(progress: simulationProgress) {
            simulatedPosition = position

            let shouldRunLogic = lastSimulationLogicUpdate.map {
                now.timeIntervalSince($0) >= simulationLogicInterval
            } ?? true
            guard shouldRunLogic else { return }
            lastSimulationLogicUpdate = now

            let location = CLLocation(
                coordinate: position,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: -1,
                // MapKit does not provide a heading for a synthetic
                // location.  Supplying the current route bearing keeps the
                // bike computer's course-up projection deterministic during
                // test navigation instead of silently encoding north (0°).
                course: routeCourse(at: position) ?? -1,
                speed: simulationSpeed,
                timestamp: now
            )

            // Also process location for navigation instructions
            processLocation(location)
            guard isNavigating, isSimulationMode else { return }
            updateRideTelemetry(gpsLocation: location, routeLocation: location)
            sendDeviceGpsPosition(location, convertFromMapKitRoute: true)
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

    /// Return the bearing of the route segment nearest to a route-space
    /// coordinate.  Core Location's `course` is often -1 while a rider is
    /// stationary or while a simulation is running; the route itself is the
    /// authoritative course in those cases.  The caller supplies coordinates
    /// in the same MapKit/GCJ-02 space as `currentRoute`.
    private func routeCourse(at coordinate: CLLocationCoordinate2D) -> CLLocationDirection? {
        guard let route = currentRoute else { return nil }

        let polyline = route.polyline
        let pointCount = polyline.pointCount
        guard pointCount > 1 else { return nil }

        var points = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        polyline.getCoordinates(&points, range: NSRange(location: 0, length: pointCount))

        let currentMapPoint = MKMapPoint(coordinate)
        var closestSegmentIndex: Int?
        var closestDistance = Double.greatestFiniteMagnitude
        for index in 0..<(pointCount - 1) {
            let start = MKMapPoint(points[index])
            let end = MKMapPoint(points[index + 1])
            let dx = end.x - start.x
            let dy = end.y - start.y
            let lengthSquared = (dx * dx) + (dy * dy)
            guard lengthSquared > 0 else { continue }

            let projected = ((currentMapPoint.x - start.x) * dx +
                             (currentMapPoint.y - start.y) * dy) /
                lengthSquared
            let t = max(0, min(1, projected))
            let closest = MKMapPoint(x: start.x + dx * t,
                                     y: start.y + dy * t)
            let distance = currentMapPoint.distance(to: closest)
            if distance < closestDistance {
                closestDistance = distance
                closestSegmentIndex = index
            }
        }

        guard let index = closestSegmentIndex else { return nil }
        let start = points[index]
        let end = points[index + 1]
        let latitude1 = start.latitude * .pi / 180
        let latitude2 = end.latitude * .pi / 180
        let deltaLongitude = (end.longitude - start.longitude) * .pi / 180
        let y = sin(deltaLongitude) * cos(latitude2)
        let x = cos(latitude1) * sin(latitude2) -
            sin(latitude1) * cos(latitude2) * cos(deltaLongitude)
        guard x.isFinite, y.isFinite, abs(x) > 0 || abs(y) > 0 else {
            return nil
        }

        let bearing = atan2(y, x) * 180 / .pi
        let normalized = bearing >= 0 ? bearing : bearing + 360
        return normalized.isFinite && normalized < 360 ? normalized : nil
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

        let preferredRemainingDistance = lastManeuverStepIndex == currentStepIndex
            ? lastManeuverRemainingDistance
            : initialRemainingDistance(for: currentStep)
        guard var remainingDistance = distanceToManeuver(
            from: location,
            in: currentStep,
            preferredRemainingDistance: preferredRemainingDistance
        ) else { return }

        // Reaching the maneuver requires both physical endpoint proximity and
        // route progress. The second condition prevents a long U-shaped step
        // whose endpoint is nearby from being skipped at its start.
        let endpointDistance = location.distance(from: stepEndLocation)
        if endpointDistance < maneuverArrivalRadius,
           remainingDistance < maneuverArrivalRadius,
           currentStepIndex < route.steps.count - 1 {
            currentStepIndex += 1
            guard advanceToNextNavigableStep(in: route) else {
                print("Navigation complete!")
                stopNavigation()
                return
            }
            print("Advanced to step \(currentStepIndex)")

            guard let recalculatedDistance = distanceToManeuver(
                from: location,
                in: route.steps[currentStepIndex],
                preferredRemainingDistance: initialRemainingDistance(
                    for: route.steps[currentStepIndex]
                )
            ) else { return }
            remainingDistance = recalculatedDistance
        }
        
        // Update current navigation data
        let newStep = route.steps[currentStepIndex]
        let newInstruction = extractInstruction(from: newStep)
        let newIconID = mapInstructionToIconID(newInstruction)

        let newDistance = Int(remainingDistance)
        let snapshot = NavigationManeuverSnapshot(iconID: newIconID, distance: newDistance, instruction: newInstruction)
        currentSnapshot = snapshot
        lastManeuverStepIndex = currentStepIndex
        lastManeuverRemainingDistance = remainingDistance
        
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

    private func initialRemainingDistance(for step: MKRoute.Step) -> CLLocationDistance? {
        let distance = step.distance
        return distance.isFinite && distance > 0 ? distance : nil
    }

    private func distanceToManeuver(
        from location: CLLocation,
        in step: MKRoute.Step,
        preferredRemainingDistance: CLLocationDistance?
    ) -> CLLocationDistance? {
        guard let endpoint = endpointLocation(for: step) else { return nil }
        let endpointDistance = location.distance(from: endpoint)

        if let remainingDistance = RouteProgress.remainingDistance(
            from: location,
            in: step,
            preferredRemainingDistance: preferredRemainingDistance,
            ambiguityTolerance: maneuverArrivalRadius
        ) {
            // A projection beyond the final segment clamps to zero. If the
            // rider is not actually at the maneuver, report the distance back
            // to its endpoint instead of leaving stale "0 m" guidance.
            if remainingDistance <= 0, endpointDistance >= maneuverArrivalRadius {
                return endpointDistance
            }
            return remainingDistance
        }

        return endpointDistance
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

        lastSentGeometryHash = 0
        lastGeometrySendTime = .distantPast
        sendRouteGeometryIfNeeded(currentLocation: routeGeometryResendLocation(for: route))
    }

    private func routeGeometryResendLocation(for route: MKRoute) -> CLLocation {
        if let lastDeviceGpsLocation {
            if lastDeviceGpsLocation.convertFromMapKitRoute {
                return lastDeviceGpsLocation.location
            }
            return CoordinateConverter.mapKitRouteLocation(fromGPSLocation: lastDeviceGpsLocation.location)
        }

        var startCoordinate = CLLocationCoordinate2D()
        route.polyline.getCoordinates(&startCoordinate, range: NSRange(location: 0, length: 1))
        return CLLocation(latitude: startCoordinate.latitude, longitude: startCoordinate.longitude)
    }

    private func resendCurrentDeviceGpsPosition() {
        guard let lastDeviceGpsLocation else { return }

        sendDeviceGpsPosition(lastDeviceGpsLocation.location,
                              convertFromMapKitRoute: lastDeviceGpsLocation.convertFromMapKitRoute,
                              includeRideTelemetry: isNavigating)
    }

    private func startRideTelemetryTimer() {
        stopRideTelemetryTimer()
        let timer = Timer(timeInterval: rideTelemetryRefreshInterval,
                          repeats: true) { [weak self] _ in
            self?.refreshRideTelemetry()
        }
        rideTelemetryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRideTelemetryTimer() {
        rideTelemetryTimer?.invalidate()
        rideTelemetryTimer = nil
    }

    private func refreshRideTelemetry() {
        guard isNavigating,
              !isSimulationMode,
              let lastDeviceGpsLocation else { return }
        sendDeviceGpsPosition(
            lastDeviceGpsLocation.location,
            convertFromMapKitRoute: lastDeviceGpsLocation.convertFromMapKitRoute
        )
    }

    #if HOST_TESTING
    func refreshRideTelemetryForTesting() {
        refreshRideTelemetry()
    }
    #endif

    private func resetRideTelemetry(startingAt location: CLLocation?) {
        rideStartDate = location == nil ? nil : now()
        rideDistanceMeters = 0
        lastRideLocation = location
        lastRouteRemainingMeters = nil
    }

    private func updateRideTelemetry(gpsLocation: CLLocation, routeLocation: CLLocation?) {
        if rideStartDate == nil {
            rideStartDate = now()
        }

        if let lastRideLocation {
            let distanceIncrement = gpsLocation.distance(from: lastRideLocation)
            if distanceIncrement >= 0 && distanceIncrement < 100 {
                rideDistanceMeters += distanceIncrement
            }
        }
        lastRideLocation = gpsLocation

        if isNavigating, let route = currentRoute, let routeLocation {
            let remaining = RouteProgress.remainingDistance(from: routeLocation, in: route)
            lastRouteRemainingMeters = remaining
            if let remaining {
                updateNavigationSummary(route: route, remainingDistance: remaining)
            }
        } else {
            lastRouteRemainingMeters = nil
        }
    }

    private func updateNavigationSummary(route: MKRoute, remainingDistance: CLLocationDistance) {
        let clampedDistance = min(max(remainingDistance, 0), max(route.distance, 0))
        routeRemainingDistance = clampedDistance

        guard route.distance > 0, route.expectedTravelTime > 0 else {
            routeRemainingTime = nil
            expectedArrivalDate = nil
            return
        }

        let fractionRemaining = clampedDistance / route.distance
        let remainingTime = max(route.expectedTravelTime * fractionRemaining, 0)
        routeRemainingTime = remainingTime
        expectedArrivalDate = now().addingTimeInterval(remainingTime)
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

    private func sendDeviceGpsPosition(_ location: CLLocation, convertFromMapKitRoute: Bool, includeRideTelemetry: Bool = true) {
        lastDeviceGpsLocation = (location, convertFromMapKitRoute)
        let wgsCoordinate = convertFromMapKitRoute
            ? CoordinateConverter.gcj02ToWGS84(coordinate: location.coordinate)
            : location.coordinate
        let routeCoordinate = convertFromMapKitRoute
            ? location.coordinate
            : CoordinateConverter.mapKitRouteLocation(fromGPSLocation: location).coordinate
        let routeHeading = routeCourse(at: routeCoordinate)
        let locationHeading = location.course.isFinite &&
            location.course >= 0 && location.course < 360
            ? location.course
            : nil
        // Prefer a measured course, but never encode Core Location's invalid
        // -1 as a north-up 0°.  During simulation and low-speed GPS, the
        // current route bearing is the stable fallback for the firmware's
        // course-up presenter.
        let heading = locationHeading ?? routeHeading ?? 0
        bleManager?.sendGPSPosition(lat: wgsCoordinate.latitude,
                                    lon: wgsCoordinate.longitude,
                                    heading: heading,
                                    speedMetersPerSecond: includeRideTelemetry ? location.speed : nil,
                                    altitudeMeters: includeRideTelemetry ? location.altitude : nil,
                                    distanceTraveledMeters: includeRideTelemetry ? rideDistanceMeters : nil,
                                    elapsedSeconds: includeRideTelemetry ? rideStartDate.map { now().timeIntervalSince($0) } : nil,
                                    routeRemainingMeters: includeRideTelemetry ? lastRouteRemainingMeters : nil)
    }

    private func sendInitialDeviceGpsPosition(_ location: CLLocation, convertFromMapKitRoute: Bool) {
        sendDeviceGpsPosition(location, convertFromMapKitRoute: convertFromMapKitRoute)

        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isNavigating else { return }
                self.sendDeviceGpsPosition(location, convertFromMapKitRoute: convertFromMapKitRoute)
            }
        }
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

        let currentMapPoint = MKMapPoint(currentLocation.coordinate)
        var closestSegmentIndex = 0
        var closestDistance = Double.greatestFiniteMagnitude
        if pointCount > 1 {
            for index in 0..<(pointCount - 1) {
                let start = MKMapPoint(points[index])
                let end = MKMapPoint(points[index + 1])
                let dx = end.x - start.x
                let dy = end.y - start.y
                let lengthSquared = (dx * dx) + (dy * dy)
                let t: Double
                if lengthSquared > 0 {
                    let projected = ((currentMapPoint.x - start.x) * dx +
                                     (currentMapPoint.y - start.y) * dy) /
                        lengthSquared
                    t = max(0, min(1, projected))
                } else {
                    t = 0
                }
                let closest = MKMapPoint(x: start.x + dx * t,
                                         y: start.y + dy * t)
                let distance = currentMapPoint.distance(to: closest)
                if distance < closestDistance {
                    closestDistance = distance
                    closestSegmentIndex = index
                }
            }
        }

        // Always make the device's current route-space coordinate the first
        // point. The line therefore starts exactly under the marker after the
        // same GCJ-02 -> WGS-84 conversion used for every other route point,
        // even when GPS is a few metres away from Apple's route polyline.
        // Future route vertices begin at the projected segment, not at the
        // nearest coarse vertex.
        var windowPoints = [currentLocation.coordinate]
        if pointCount > 1 {
            let firstFutureIndex = min(closestSegmentIndex + 1, pointCount - 1)
            let endIndex = min(firstFutureIndex + max(geometryWindowSize - 1, 0),
                               pointCount)
            if firstFutureIndex < endIndex {
                for point in points[firstFutureIndex..<endIndex] {
                    let previous = windowPoints[windowPoints.count - 1]
                    let separation = CLLocation(latitude: previous.latitude,
                                                longitude: previous.longitude)
                        .distance(from: CLLocation(latitude: point.latitude,
                                                   longitude: point.longitude))
                    // Do not add a duplicate at an exact route vertex. The
                    // projected segment still contributes its next vertex.
                    if separation > 0.01 {
                        windowPoints.append(point)
                    }
                }
            }
        }
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
