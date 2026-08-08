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
    private var currentRoute: NavigationRouteV1?
    private var navigationRuntime = NavigationRuntimeV1()
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
    
    // BLE Manager reference
    private var bleManager: BLEManager?
    private var cancellables = Set<AnyCancellable>()
    private let liveLocationStartTolerance: CLLocationDistance = 150

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
        let acceptedRouteLocation: CLLocation?
        if shouldAcceptLiveLocation(location) {
            processLocation(location)
            acceptedRouteLocation = location
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
        let normalizedInitialLocation = initialLocation.map(
            MapKitRouteAdapter.normalizedLocation
        )
        let sharedRoute: NavigationRouteV1
        do {
            sharedRoute = try MapKitRouteAdapter.route(
                from: route,
                fallbackSource: normalizedInitialLocation.map {
                    RouteCoordinateV1(
                        latitude: $0.coordinate.latitude,
                        longitude: $0.coordinate.longitude
                    )
                }
            )
        } catch {
            print("Navigation route conversion failed: \(error)")
            return
        }
        currentRoute = sharedRoute
        currentStepIndex = 0
        isSimulationMode = isTestMode
        isNavigating = true
        
        currentSnapshot = nil
        lastManeuverStepIndex = nil
        lastManeuverRemainingDistance = nil
        sendTracker.reset()
        initialNavigationLocation = normalizedInitialLocation
        hasAcceptedLiveLocation = normalizedInitialLocation == nil
        lastSentGeometryHash = 0
        lastGeometrySendTime = .distantPast
        resetRideTelemetry(startingAt: normalizedInitialLocation)
        let runtimeInitialLocation: CLLocation? = {
            if let normalizedInitialLocation {
                return normalizedInitialLocation
            }
            guard isTestMode, let first = sharedRoute.points.first else {
                return nil
            }
            return CLLocation(latitude: first.latitude, longitude: first.longitude)
        }()
        do {
            _ = try navigationRuntime.start(
                route: sharedRoute,
                mode: .online,
                initialStepStrategy: .first,
                initialLocation: runtimeInitialLocation.map(
                    NavigationLocationSampleV1.init(location:)
                )
            )
        } catch {
            print("Navigation runtime failed to start: \(error)")
            stopNavigation()
            return
        }
        updateNavigationSummary(
            route: sharedRoute,
            remainingDistance: sharedRoute.distanceMeters
        )
        
        print("Navigation started with \(sharedRoute.steps.count) steps (Test Mode: \(isTestMode))")
        
        if isTestMode {
            startSimulation()
        } else {
            startRideTelemetryTimer()
            if let normalizedInitialLocation {
                if let initialSnapshot = navigationRuntime.snapshot {
                    applyRuntimeSnapshot(
                        initialSnapshot,
                        route: sharedRoute,
                        currentLocation: normalizedInitialLocation
                    )
                }
                guard isNavigating else { return }
                updateRideTelemetry(
                    gpsLocation: normalizedInitialLocation,
                    routeLocation: normalizedInitialLocation
                )
                sendInitialDeviceGpsPosition(
                    normalizedInitialLocation,
                    convertFromMapKitRoute: false
                )
            }
        }
    }

    /// Replace an active route after rerouting without resetting ride telemetry.
    func replaceRoute(
        with route: MKRoute,
        currentLocation: CLLocation
    ) {
        guard isNavigating, !isSimulationMode else { return }

        let normalizedCurrentLocation = MapKitRouteAdapter.normalizedLocation(
            currentLocation
        )
        let sharedRoute: NavigationRouteV1
        do {
            sharedRoute = try MapKitRouteAdapter.route(
                from: route,
                fallbackSource: RouteCoordinateV1(
                    latitude: normalizedCurrentLocation.coordinate.latitude,
                    longitude: normalizedCurrentLocation.coordinate.longitude
                )
            )
        } catch {
            print("Replacement route conversion failed: \(error)")
            return
        }

        let replacementSnapshot: NavigationSnapshotV1
        do {
            replacementSnapshot = try navigationRuntime.replaceRoute(
                sharedRoute,
                mode: .online,
                currentLocation: NavigationLocationSampleV1(
                    location: normalizedCurrentLocation
                )
            )
        } catch {
            print("Navigation runtime failed to replace route: \(error)")
            return
        }
        currentRoute = sharedRoute
        currentSnapshot = nil
        lastManeuverStepIndex = nil
        lastManeuverRemainingDistance = nil
        sendTracker.reset()
        initialNavigationLocation = nil
        hasAcceptedLiveLocation = true
        lastSentGeometryHash = 0
        lastGeometrySendTime = .distantPast
        applyRuntimeSnapshot(
            replacementSnapshot,
            route: sharedRoute,
            currentLocation: normalizedCurrentLocation
        )
        guard isNavigating else { return }
        resendCurrentDeviceGpsPosition()

        print("Navigation route replaced with \(sharedRoute.steps.count) steps")
    }

    func distanceToCurrentStep(from location: CLLocation) -> CLLocationDistance? {
        guard let route = currentRoute,
              route.steps.indices.contains(currentStepIndex) else { return nil }
        let normalized = MapKitRouteAdapter.normalizedLocation(location)
        let step = route.steps[currentStepIndex]
        let stepPoints = Array(
            route.points[step.geometryStartIndex...step.geometryEndIndex]
        )
        let projections = NavigationGeometryV1.projections(
            of: RouteCoordinateV1(
                latitude: normalized.coordinate.latitude,
                longitude: normalized.coordinate.longitude
            ),
            onto: stepPoints,
            cumulativeDistances: NavigationGeometryV1.cumulativeDistances(
                for: stepPoints
            )
        )
        return projections.map(\.crossTrackDistanceMeters).min()
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
        navigationRuntime.stop()
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
        let totalDistance = route.distanceMeters
        
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

            let location = CLLocation(
                coordinate: position,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: -1,
                course: -1,
                speed: simulationSpeed,
                timestamp: now
            )

            // Also process location for navigation instructions
            processLocation(location)
            guard isNavigating, isSimulationMode else { return }
            updateRideTelemetry(gpsLocation: location, routeLocation: location)
            sendDeviceGpsPosition(location, convertFromMapKitRoute: false)
        }
    }
    
    private func interpolatePositionAlongRoute(progress: Double) -> CLLocationCoordinate2D? {
        guard let route = currentRoute else { return nil }
        
        let pointCount = route.points.count
        guard pointCount > 1 else { return nil }
        
        let targetDistance = progress * route.distanceMeters
        var currentDist = 0.0
        
        for i in 0..<(pointCount - 1) {
            let p1 = CLLocation(
                latitude: route.points[i].latitude,
                longitude: route.points[i].longitude
            )
            let p2 = CLLocation(
                latitude: route.points[i + 1].latitude,
                longitude: route.points[i + 1].longitude
            )
            let dist = p1.distance(from: p2)
            
            if currentDist + dist >= targetDistance {
                // We are in this segment
                let remaining = targetDistance - currentDist
                let ratio = remaining / dist
                
                let lat = route.points[i].latitude +
                    (route.points[i + 1].latitude - route.points[i].latitude) * ratio
                let lon = route.points[i].longitude +
                    (route.points[i + 1].longitude - route.points[i].longitude) * ratio
                
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            
            currentDist += dist
        }
        
        guard let last = route.points.last else { return nil }
        return CLLocationCoordinate2D(
            latitude: last.latitude,
            longitude: last.longitude
        )
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
        let runtimeSnapshot: NavigationSnapshotV1
        do {
            runtimeSnapshot = try navigationRuntime.process(
                NavigationLocationSampleV1(location: location)
            )
        } catch {
            print("Navigation location rejected: \(error)")
            return
        }

        applyRuntimeSnapshot(runtimeSnapshot, route: route, currentLocation: location)
    }

    private func applyRuntimeSnapshot(
        _ runtimeSnapshot: NavigationSnapshotV1,
        route: NavigationRouteV1,
        currentLocation: CLLocation
    ) {
        if runtimeSnapshot.maneuver == .arrive,
           runtimeSnapshot.distanceToManeuverMeters < 20 {
            print("Navigation complete!")
            stopNavigation()
            return
        }
        if runtimeSnapshot.currentStepIndex != currentStepIndex {
            currentStepIndex = runtimeSnapshot.currentStepIndex
            print("Advanced to step \(currentStepIndex)")
        }
        let instruction = displayInstruction(runtimeSnapshot.instruction)
        let maneuverSnapshot = NavigationManeuverSnapshot(
            iconID: runtimeSnapshot.maneuver.deviceIconID,
            distance: Int(runtimeSnapshot.distanceToManeuverMeters),
            instruction: instruction
        )
        currentSnapshot = maneuverSnapshot
        lastManeuverStepIndex = currentStepIndex
        lastManeuverRemainingDistance = runtimeSnapshot.distanceToManeuverMeters
        
        // Update published properties
        currentInstruction = maneuverSnapshot.instruction
        distanceToManeuver = maneuverSnapshot.distance
        currentIconID = maneuverSnapshot.iconID
        lastRouteRemainingMeters = runtimeSnapshot.routeRemainingDistanceMeters
        updateNavigationSummary(
            route: route,
            remainingDistance: runtimeSnapshot.routeRemainingDistanceMeters
        )
        
        // Determine if we should send update to ESP32
        if sendTracker.shouldSend(maneuverSnapshot) {
            sendNavigationDataToESP32(maneuverSnapshot)
        }

        sendRouteGeometryIfNeeded(currentLocation: currentLocation)
    }

    private func displayInstruction(_ instruction: String) -> String {
        let cleaned = instruction
            .replacingOccurrences(of: "Continue on ", with: "")
            .replacingOccurrences(of: "Turn on ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Continue" }
        return cleaned.count > 30 ? String(cleaned.prefix(30)) + "..." : cleaned
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
        guard isNavigating, let route = currentRoute, !route.points.isEmpty else { return }

        lastSentGeometryHash = 0
        lastGeometrySendTime = .distantPast
        sendRouteGeometryIfNeeded(currentLocation: routeGeometryResendLocation(for: route))
    }

    private func routeGeometryResendLocation(for route: NavigationRouteV1) -> CLLocation {
        if let lastDeviceGpsLocation {
            if lastDeviceGpsLocation.convertFromMapKitRoute {
                return MapKitRouteAdapter.normalizedLocation(
                    lastDeviceGpsLocation.location
                )
            }
            return lastDeviceGpsLocation.location
        }

        let startCoordinate = route.points[0]
        return CLLocation(
            latitude: startCoordinate.latitude,
            longitude: startCoordinate.longitude
        )
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

        if isNavigating, let route = currentRoute, routeLocation != nil,
           let runtimeSnapshot = navigationRuntime.snapshot {
            let remaining = runtimeSnapshot.routeRemainingDistanceMeters
            lastRouteRemainingMeters = remaining
            updateNavigationSummary(route: route, remainingDistance: remaining)
        } else {
            lastRouteRemainingMeters = nil
        }
    }

    private func updateNavigationSummary(
        route: NavigationRouteV1,
        remainingDistance: CLLocationDistance
    ) {
        let clampedDistance = min(
            max(remainingDistance, 0),
            max(route.distanceMeters, 0)
        )
        routeRemainingDistance = clampedDistance

        guard route.distanceMeters > 0,
              let expectedTravelTime = route.expectedTravelTimeSeconds,
              expectedTravelTime > 0 else {
            routeRemainingTime = nil
            expectedArrivalDate = nil
            return
        }

        let fractionRemaining = clampedDistance / route.distanceMeters
        let remainingTime = max(expectedTravelTime * fractionRemaining, 0)
        routeRemainingTime = remainingTime
        expectedArrivalDate = now().addingTimeInterval(remainingTime)
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
        let heading = location.course >= 0 ? location.course : 0
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
        let cumulative = NavigationGeometryV1.cumulativeDistances(for: route.points)
        let projections = NavigationGeometryV1.projections(
            of: RouteCoordinateV1(
                latitude: currentLocation.coordinate.latitude,
                longitude: currentLocation.coordinate.longitude
            ),
            onto: route.points,
            cumulativeDistances: cumulative
        )
        guard let closest = projections.min(by: {
            $0.crossTrackDistanceMeters < $1.crossTrackDistanceMeters
        }) else { return nil }
        return NavigationGeometryV1.compressedRouteWindow(
            points: route.points,
            startingAt: NavigationGeometryV1.routeWindowStartIndex(for: closest),
            count: geometryWindowSize
        )
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
