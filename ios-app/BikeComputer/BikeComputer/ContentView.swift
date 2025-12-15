//
//  ContentView.swift
//  BikeComputer
//
//  Main view demonstrating NavigationEngine and BLEManager integration
//

import SwiftUI
import MapKit
import Combine
import CoreLocation
import HealthKit

// MARK: - Constants (Optimization #12)

enum SystemIcon {
    static let heart = "heart.fill"
    static let heartCircle = "heart.circle.fill"
    static let speedometer = "gauge.high"
    static let distance = "road.lanes"
    static let timer = "timer"
    static let bicycle = "bicycle"
    static let play = "play.circle.fill"
    static let stop = "stop.circle.fill"
    static let location = "location.fill"
    static let mapPin = "mappin.and.ellipse"
    static let magnifyingGlass = "magnifyingglass"
    static let xmark = "xmark.circle.fill"
}

// MARK: - Formatters (Optimization #10)

struct TimeFormatter {
    static func format(_ timeInterval: TimeInterval) -> String {
        let hours = Int(timeInterval) / 3600
        let minutes = Int(timeInterval) / 60 % 60
        let seconds = Int(timeInterval) % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

struct MeasurementFormatter {
    static func speed(_ metersPerSecond: Double) -> String {
        String(format: "%.1f", metersPerSecond * 3.6)
    }
    
    static func distance(_ meters: Double) -> String {
        String(format: "%.2f", meters / 1000.0)
    }
}

// MARK: - State Groups (Optimization #11)

struct RouteCalculationState {
    var isCalculating: Bool = false
    var status: String = ""
}

struct AlertState {
    var isShowing: Bool = false
    var message: String = ""
}

// MARK: - HealthKit Manager

class HealthKitManager: NSObject, ObservableObject {
    @Published var isAuthorized = false
    @Published var isWorkoutActive = false
    @Published var workoutElapsedTime: TimeInterval = 0
    @Published var workoutStartTime: Date?
    @Published var heartRate: Double = 0
    @Published var currentSpeed: Double = 0 // m/s
    @Published var distanceTraveled: Double = 0 // meters

    private let healthStore = HKHealthStore()
    private var workoutTimer: Timer?
    
    weak var locationManager: CurrentLocationManager?
    
    // MARK: - Computed Properties (Optimization #1)
    
    /// Current speed in km/h
    var currentSpeedKmh: Double {
        currentSpeed * 3.6
    }
    
    /// Distance traveled in km
    var distanceKm: Double {
        distanceTraveled / 1000.0
    }
    
    /// Formatted time string for elapsed time
    var formattedElapsedTime: String {
        TimeFormatter.format(workoutElapsedTime)
    }
    
    /// Heart rate as integer, or nil if not available
    var heartRateInt: Int? {
        heartRate > 0 ? Int(heartRate) : nil
    }

    override init() {
        super.init()
        requestAuthorization()
    }

    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("HealthKit not available on this device")
            return
        }

        let typesToWrite: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKObjectType.quantityType(forIdentifier: .distanceCycling)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
        ]
        
        let typesToRead: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .heartRate)!
        ]

        healthStore.requestAuthorization(toShare: typesToWrite, read: typesToRead) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.isAuthorized = true
                    print("HealthKit authorization granted")
                } else {
                    self?.isAuthorized = false
                    if let error = error {
                        print("HealthKit authorization failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    func updateLocation(speed: Double, distance: Double) {
        DispatchQueue.main.async {
            self.currentSpeed = speed
            self.distanceTraveled = distance
        }
    }

    func startBikeWorkout() {
        // Optimization #13: Defensive authorization check
        guard isAuthorized && HKHealthStore.isHealthDataAvailable() else {
            print("HealthKit not authorized or not available")
            return
        }

        workoutStartTime = Date()
        isWorkoutActive = true
        distanceTraveled = 0
        heartRate = 0
        currentSpeed = 0
        locationManager?.resetDistance()
        locationManager?.updateLocationTracking() // Optimization #3: Enable location tracking
        startWorkoutTimer()
        print("📱 Bike workout started - will save to HealthKit when ended")
    }
    
    // MARK: - Combined Timer (Optimization #2 & #9)
    
    private var heartRatePollCounter = 0
    
    private func startWorkoutTimer() {
        heartRatePollCounter = 0
        
        // Single timer at 1-second interval for both elapsed time and heart rate
        workoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.workoutStartTime else {
                // Optimization #9: Invalidate timer if workout ended unexpectedly
                self?.stopWorkoutTimer()
                return
            }
            
            // Update elapsed time every second
            self.workoutElapsedTime = Date().timeIntervalSince(startTime)
            
            // Poll heart rate every 2 seconds (counter: 0, 2, 4, 6...)
            self.heartRatePollCounter += 1
            if self.heartRatePollCounter % 2 == 0 {
                self.fetchLatestHeartRate()
            }
        }
        
        // Fetch heart rate immediately on start
        fetchLatestHeartRate()
        print("Started workout timer (combined elapsed time & heart rate)")
    }
    
    private func fetchLatestHeartRate() {
        // Optimization #13: Guard against unauthorized access
        guard isAuthorized, HKHealthStore.isHealthDataAvailable() else { return }
        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return }
        
        let now = Date()
        let tenSecondsAgo = now.addingTimeInterval(-10)
        let predicate = HKQuery.predicateForSamples(withStart: tenSecondsAgo, end: now, options: .strictEndDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        
        let query = HKSampleQuery(sampleType: heartRateType, predicate: predicate, limit: 1, sortDescriptors: [sortDescriptor]) { [weak self] query, samples, error in
            if let samples = samples as? [HKQuantitySample], let sample = samples.first {
                let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
                let bpm = sample.quantity.doubleValue(for: heartRateUnit)
                
                DispatchQueue.main.async {
                    self?.heartRate = bpm
                }
            }
        }
        
        healthStore.execute(query)
    }

    func endBikeWorkout() {
        guard let startTime = workoutStartTime else {
            cleanupWorkout()
            return
        }

        let endDate = Date()
        let duration = endDate.timeIntervalSince(startTime)
        
        // Create distance quantity if distance was tracked
        let distanceQuantity: HKQuantity? = distanceTraveled > 0 ? HKQuantity(unit: .meter(), doubleValue: distanceTraveled) : nil

        let workout = HKWorkout(
            activityType: .cycling,
            start: startTime,
            end: endDate,
            duration: duration,
            totalEnergyBurned: nil,
            totalDistance: distanceQuantity,
            device: HKDevice.local(),
            metadata: nil
        )

        healthStore.save(workout) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    print("✅ Workout saved to HealthKit (Distance: \(String(format: "%.2f", (self?.distanceTraveled ?? 0) / 1000)) km)")
                } else if let error = error {
                    print("Failed to save: \(error.localizedDescription)")
                }
                self?.cleanupWorkout()
            }
        }
    }
    
    // MARK: - Cleanup (Optimization #9)
    
    private func cleanupWorkout() {
        stopWorkoutTimer()
        
        // Reset all workout state
        isWorkoutActive = false
        workoutStartTime = nil
        workoutElapsedTime = 0
        heartRate = 0
        currentSpeed = 0
        distanceTraveled = 0
        heartRatePollCounter = 0
        
        locationManager?.updateLocationTracking() // Optimization #3: Update location tracking state
        
        print("Workout cleaned up")
    }
    
    private func stopWorkoutTimer() {
        workoutTimer?.invalidate()
        workoutTimer = nil
        print("Stopped workout timer")
    }
    
    deinit {
        // Ensure timers are cleaned up when object is deallocated
        stopWorkoutTimer()
    }
}

// MARK: - Map View Container

// Custom annotation class to identify destination pins
class DestinationAnnotation: MKPointAnnotation {
    var coordinate2D: CLLocationCoordinate2D {
        return coordinate
    }
}

struct MapViewContainer: UIViewRepresentable {
    let location: CLLocation?
    let route: MKRoute?
    let onDestinationSelected: ((CLLocationCoordinate2D, CLLocation?) -> Void)?
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        
        // Configure map appearance
        mapView.showsCompass = true
        mapView.showsScale = true
        
        // Add long press gesture recognizer
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.5
        mapView.addGestureRecognizer(longPress)
        
        // Store the callback in coordinator
        context.coordinator.onDestinationSelected = onDestinationSelected
        
        return mapView
    }
    
    func updateUIView(_ uiView: MKMapView, context: Context) {
        // Store reference to map view in coordinator
        context.coordinator.mapView = uiView
        
        // Only set initial region once if not already set
        if let location = location, 
           !context.coordinator.hasSetInitialRegion,
           context.coordinator.lastRoute == nil {
            let region = MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
            uiView.setRegion(region, animated: false)
            context.coordinator.hasSetInitialRegion = true
        }
        
        // Update route overlay
        if let route = route, context.coordinator.lastRoute !== route {
            // Disable user tracking when showing route
            uiView.userTrackingMode = .none
            
            // Remove old overlays
            uiView.removeOverlays(uiView.overlays)
            
            // Add new route overlay
            uiView.addOverlay(route.polyline, level: .aboveRoads)
            
            // Fit route to view
            uiView.setVisibleMapRect(
                route.polyline.boundingMapRect,
                edgePadding: UIEdgeInsets(top: 60, left: 60, bottom: 60, right: 60),
                animated: true
            )
            
            context.coordinator.lastRoute = route
        } else if route == nil && context.coordinator.lastRoute != nil {
            // Clear route when navigation stops
            uiView.removeOverlays(uiView.overlays)
            context.coordinator.lastRoute = nil
            
            // Remove any destination annotations
            let destinationAnnotations = uiView.annotations.filter { $0 is DestinationAnnotation }
            uiView.removeAnnotations(destinationAnnotations)
            
            // Re-enable user tracking when navigation stops
            uiView.userTrackingMode = .follow
            context.coordinator.hasSetInitialRegion = false
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var lastRoute: MKRoute?
        var mapView: MKMapView?
        var onDestinationSelected: ((CLLocationCoordinate2D, CLLocation?) -> Void)?
        var hasSetInitialRegion = false
        
        @objc func handleLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
            guard gestureRecognizer.state == .began,
                  let mapView = mapView else { return }
            
            // Disable user tracking mode to allow free map movement
            mapView.userTrackingMode = .none
            
            let touchPoint = gestureRecognizer.location(in: mapView)
            let coordinate = mapView.convert(touchPoint, toCoordinateFrom: mapView)
            
            // Remove any existing destination annotations
            let existingAnnotations = mapView.annotations.filter { $0 is DestinationAnnotation }
            mapView.removeAnnotations(existingAnnotations)
            
            // Add new annotation
            let annotation = DestinationAnnotation()
            annotation.coordinate = coordinate
            annotation.title = "Navigate Here?"
            annotation.subtitle = "Tap to start navigation"
            
            mapView.addAnnotation(annotation)
            
            // Show the callout
            mapView.selectAnnotation(annotation, animated: true)
        }
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 6
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            // Use default view for user location
            if annotation is MKUserLocation {
                return nil
            }
            
            // Handle destination annotation
            if let destinationAnnotation = annotation as? DestinationAnnotation {
                let identifier = "DestinationPin"
                var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                
                if annotationView == nil {
                    annotationView = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    annotationView?.canShowCallout = true
                    
                    // Add a button to the callout
                    let button = UIButton(type: .detailDisclosure)
                    button.setImage(UIImage(systemName: "arrow.triangle.turn.up.right.diamond.fill"), for: .normal)
                    annotationView?.rightCalloutAccessoryView = button
                    
                    // Customize marker appearance
                    annotationView?.markerTintColor = .systemBlue
                    annotationView?.glyphImage = UIImage(systemName: "mappin.circle.fill")
                } else {
                    annotationView?.annotation = annotation
                }
                
                return annotationView
            }
            
            return nil
        }
        
        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            // Handle the callout button tap
            if let destinationAnnotation = view.annotation as? DestinationAnnotation {
                // Pass the map's user location as fallback
                onDestinationSelected?(destinationAnnotation.coordinate, mapView.userLocation.location)
                
                // Remove the annotation after selection
                mapView.removeAnnotation(destinationAnnotation)
            }
        }
    }
}

// MARK: - Current Location Manager

class CurrentLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var currentLocation: CLLocation?
    @Published var currentAddress: String = "Current Location"
    
    private let locationManager = CLLocationManager()
    private var lastGeocodedLocation: CLLocation?
    private var lastGeocodeTime: Date?
    private var lastLocation: CLLocation?
    private var totalDistance: Double = 0
    
    // MARK: - Optimization #3: Intelligent Location Update Management
    private var isNavigating = false
    private var isViewingMap = false
    private var isLocationUpdating = false
    
    weak var healthKitManager: HealthKitManager?
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5 // Update every 5 meters for better tracking
        locationManager.requestWhenInUseAuthorization()
        // Don't start by default - wait for explicit need
    }
    
    func resetDistance() {
        totalDistance = 0
        lastLocation = nil
    }
    
    func requestLocation() {
        locationManager.requestLocation()
    }
    
    // MARK: - Smart Location Update Control (Optimization #3)
    
    func setNavigating(_ navigating: Bool) {
        isNavigating = navigating
        updateLocationTracking()
    }
    
    func setViewingMap(_ viewing: Bool) {
        isViewingMap = viewing
        updateLocationTracking()
    }
    
    func updateLocationTracking() {
        let shouldTrack = isNavigating || 
                         isViewingMap || 
                         (healthKitManager?.isWorkoutActive == true)
        
        if shouldTrack && !isLocationUpdating {
            print("🌍 Starting location updates (navigating: \(isNavigating), map: \(isViewingMap), workout: \(healthKitManager?.isWorkoutActive == true))")
            locationManager.startUpdatingLocation()
            isLocationUpdating = true
        } else if !shouldTrack && isLocationUpdating {
            print("🌍 Stopping location updates (not needed)")
            locationManager.stopUpdatingLocation()
            isLocationUpdating = false
        }
    }
    
    func startUpdatingLocation() {
        if !isLocationUpdating {
            locationManager.startUpdatingLocation()
            isLocationUpdating = true
        }
    }
    
    func stopUpdatingLocation() {
        if isLocationUpdating {
            locationManager.stopUpdatingLocation()
            isLocationUpdating = false
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        currentLocation = location
        
        // Track distance and speed if workout is active
        if let healthKit = healthKitManager, healthKit.isWorkoutActive {
            if let last = lastLocation {
                // Calculate distance increment
                let distanceIncrement = location.distance(from: last)
                // Filter out unrealistic jumps (> 100m between updates at 5m filter)
                if distanceIncrement < 100 {
                    totalDistance += distanceIncrement
                }
            }
            lastLocation = location
            
            // Get current speed (m/s) from location, or calculate it
            let speed = location.speed >= 0 ? location.speed : 0
            
            // Update HealthKit manager with current speed and total distance
            healthKit.updateLocation(speed: speed, distance: totalDistance)
        }
        
        // Only reverse geocode if:
        // 1. We haven't geocoded yet, OR
        // 2. Location moved more than 100 meters, OR
        // 3. More than 60 seconds since last geocode
        let shouldGeocode: Bool = {
            guard let lastLocation = lastGeocodedLocation,
                  let lastTime = lastGeocodeTime else {
                return true // First time
            }
            
            let distanceMoved = location.distance(from: lastLocation)
            let timeSinceLastGeocode = Date().timeIntervalSince(lastTime)
            
            return distanceMoved > 100 || timeSinceLastGeocode > 60
        }()
        
        guard shouldGeocode else { return }
        
        lastGeocodedLocation = location
        lastGeocodeTime = Date()
        
        // Reverse geocode to get address
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            if let error = error {
                print("Reverse geocoding error: \(error.localizedDescription)")
                self?.currentAddress = "Current Location"
                return
            }
            
            if let placemark = placemarks?.first {
                var addressComponents: [String] = []
                
                if let street = placemark.thoroughfare {
                    addressComponents.append(street)
                }
                if let city = placemark.locality {
                    addressComponents.append(city)
                }
                if let state = placemark.administrativeArea {
                    addressComponents.append(state)
                }
                
                self?.currentAddress = addressComponents.isEmpty ? "Current Location" : addressComponents.joined(separator: ", ")
                print("Current location address: \(self?.currentAddress ?? "Unknown")")
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
}

struct ContentView: View {
    
    @StateObject private var bleManager = BLEManager()
    @StateObject private var navEngine = NavigationEngine()
    @StateObject private var locationManager = CurrentLocationManager()
    @StateObject private var healthKitManager = HealthKitManager()
    
    @State private var showingRouteInput = false
    @State private var sourceAddress = ""
    @State private var destinationAddress = ""
    @State private var routeCalculation = RouteCalculationState() // Optimization #11
    @State private var currentRoute: MKRoute?
    @State private var selectedView = 0  // 0 = map, 1 = navigation+workout
    @State private var alert = AlertState() // Optimization #11
    
    // Optimization #4: Track ongoing searches to cancel if needed
    @State private var ongoingSourceSearch: MKLocalSearch?
    @State private var ongoingDestinationSearch: MKLocalSearch?
    @State private var ongoingDirections: MKDirections?
    @State private var transportType: MKDirectionsTransportType = {
        if #available(iOS 18.0, *) {
            return .cycling
        } else {
            return .walking  // Fall back to walking for pre-iOS 18
        }
    }()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 15) {
                
                // // Header
                // Text("Bike Computer")
                //     .font(.system(size: 36, weight: .bold, design: .rounded))
                //     .padding(.top, 40)
                
                // BLE Connection Status
                connectionStatusView
                
                // Main Content Views
                if navEngine.isNavigating {
                    // Swipeable view: map | navigation+workout
                    TabView(selection: $selectedView) {
                        mapView
                            .tag(0)

                        navigationAndWorkoutView
                            .tag(1)
                    }
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .automatic))
                    .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
                    .frame(height: 550)
                } else if routeCalculation.isCalculating {
                    calculationStatusView
                } else {
                    // Swipeable view: map | workout
                    TabView(selection: $selectedView) {
                        mapView
                            .tag(0)

                        workoutOnlyView
                            .tag(1)
                    }
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .automatic))
                    .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
                    .frame(height: 550)
                }
                
                // Control Buttons
                VStack(spacing: 15) {
                    if !navEngine.isNavigating {
                        // Search bar for destination
                        Button(action: {
                            showingRouteInput = true
                        }) {
                            HStack {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(.secondary)
                                Text("Search for a destination")
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                                .padding()
                            .background(Color(.systemGray6))
                                .cornerRadius(12)
                        }
                        .disabled(!bleManager.isConnected)
                        .opacity(bleManager.isConnected ? 1.0 : 0.5)
                    } else {
                        Button(action: {
                            navEngine.stopNavigation()
                            currentRoute = nil
                            // Optimization #3: Disable navigation tracking
                            locationManager.setNavigating(false)
                            selectedView = 0
                        }) {
                            Label("Stop Navigation", systemImage: "stop.fill")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red)
                                .cornerRadius(12)
                        }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 0)
            }
            .navigationBarHidden(true)
            .fullScreenCover(isPresented: $showingRouteInput) {
                RouteInputView(
                    sourceAddress: $sourceAddress,
                    destinationAddress: $destinationAddress,
                    locationManager: locationManager,
                    onStartNavigation: { source, destination, transport in
                        transportType = transport
                        calculateRoute(from: source, to: destination)
                    }
                )
            }
            .alert("Navigation Error", isPresented: $alert.isShowing) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alert.message)
            }
        }
        .onAppear {
            setupManagers()
            // Optimization #3: Start tracking location for map view
            locationManager.setViewingMap(true)
        }
        .onChange(of: selectedView) { newValue in
            // Optimization #3: Track if user is viewing the map
            locationManager.setViewingMap(newValue == 0)
        }
    }
    
    // MARK: - Workout View

    // MARK: - Combined Navigation and Workout View
    
    private var navigationAndWorkoutView: some View {
        VStack(spacing: 15) {
            if navEngine.isNavigating {
                // Navigation Details
                VStack(spacing: 15) {
                    // Arrow Icon
                    Image(systemName: arrowIcon(for: navEngine.currentIconID))
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                    
                    // Distance
                    Text("\(navEngine.distanceToManeuver)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    
                    Text("meters")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    
                    // Instruction
                    Text(navEngine.currentInstruction)
                        .font(.title3)
                        .fontWeight(.medium)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .lineLimit(2)
                }
            }
            
            Divider()
                .padding(.vertical, 5)
            
            // Workout Section
            if healthKitManager.isWorkoutActive {
                // Compact Workout Metrics
                VStack(spacing: 12) {
                    Text("Workout Active")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // Metrics Grid (2x2)
                    HStack(spacing: 20) {
                        // Speed
                        VStack(spacing: 4) {
                            Image(systemName: "gauge.high")
                                .font(.title3)
                                .foregroundColor(.blue)
                            Text(String(format: "%.1f", healthKitManager.currentSpeedKmh))
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundColor(.primary)
                            Text("km/h")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        
                        // Distance
                        VStack(spacing: 4) {
                            Image(systemName: "road.lanes")
                                .font(.title3)
                                .foregroundColor(.green)
                            Text(String(format: "%.2f", healthKitManager.distanceKm))
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundColor(.primary)
                            Text("km")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    
                    HStack(spacing: 20) {
                        // Heart Rate
                        VStack(spacing: 4) {
                            Image(systemName: "heart.fill")
                                .font(.title3)
                                .foregroundColor(.red)
                            Text(healthKitManager.heartRateInt.map { "\($0)" } ?? "--")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundColor(.primary)
                            Text("BPM")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        
                        // Time
                        VStack(spacing: 4) {
                            Image(systemName: "timer")
                                .font(.title3)
                                .foregroundColor(.orange)
                            Text(healthKitManager.formattedElapsedTime)
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(.primary)
                            Text("TIME")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    
                    // End Workout Button (small version)
                    Button(action: {
                        healthKitManager.endBikeWorkout()
                    }) {
                        Label("End Workout", systemImage: "stop.circle.fill")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Color.red)
                            .cornerRadius(10)
                    }
                }
            } else {
                // Start Workout Button (small version during navigation)
                Button(action: {
                    healthKitManager.startBikeWorkout()
                }) {
                    Label("Start Workout", systemImage: "play.circle.fill")
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(healthKitManager.isAuthorized ? Color.green : Color.gray)
                        .cornerRadius(10)
                }
                .disabled(!healthKitManager.isAuthorized)
                
                if !healthKitManager.isAuthorized {
                    Text("HealthKit access required")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemGray6))
        )
        .padding(.horizontal, 30)
    }
    
    // MARK: - Workout Only View (when not navigating)
    
    private var workoutOnlyView: some View {
        VStack(spacing: 30) {
            if healthKitManager.isWorkoutActive {
                // Active Workout Display
                VStack(spacing: 20) {
                    // Workout Icon
                    Image(systemName: "bicycle")
                        .font(.system(size: 50))
                        .foregroundColor(.green)
                    
                    Text("Workout Active")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                    
                    // Metrics Grid (2x2)
                    VStack(spacing: 20) {
                        HStack(spacing: 20) {
                            // Speed
                            VStack(spacing: 8) {
                                Image(systemName: "gauge.high")
                                    .font(.system(size: 30))
                                    .foregroundColor(.blue)
                                Text(String(format: "%.1f", healthKitManager.currentSpeedKmh))
                                    .font(.system(size: 36, weight: .bold, design: .rounded))
                                    .foregroundColor(.primary)
                                Text("km/h")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(15)
                            
                            // Distance
                            VStack(spacing: 8) {
                                Image(systemName: "road.lanes")
                                    .font(.system(size: 30))
                                    .foregroundColor(.green)
                                Text(String(format: "%.2f", healthKitManager.distanceKm))
                                    .font(.system(size: 36, weight: .bold, design: .rounded))
                                    .foregroundColor(.primary)
                                Text("km")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(15)
                        }
                        
                        HStack(spacing: 20) {
                            // Heart Rate
                            VStack(spacing: 8) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.red)
                                Text(healthKitManager.heartRateInt.map { "\($0)" } ?? "--")
                                    .font(.system(size: 36, weight: .bold, design: .rounded))
                                    .foregroundColor(.primary)
                                Text("BPM")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(15)
                            
                            // Time
                            VStack(spacing: 8) {
                                Image(systemName: "timer")
                                    .font(.system(size: 30))
                                    .foregroundColor(.orange)
                                Text(healthKitManager.formattedElapsedTime)
                                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                                    .foregroundColor(.primary)
                                Text("TIME")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(15)
                        }
                    }
                    .padding(.horizontal)
                    
                    // End Workout Button
                    Button(action: {
                        healthKitManager.endBikeWorkout()
                    }) {
                        Label("End Workout", systemImage: "stop.circle.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .cornerRadius(15)
                    }
                    .padding(.horizontal)
                }
            } else {
                // Start Workout Display
                VStack(spacing: 20) {
                    Image(systemName: "bicycle")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)
                    
                    VStack(spacing: 10) {
                        Text("Start Bike Workout")
                            .font(.title)
                            .fontWeight(.semibold)
                        
                        Text("Track your cycling workout\nor start from Apple Watch")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    Button(action: {
                        healthKitManager.startBikeWorkout()
                    }) {
                        Label("Start Bike Workout", systemImage: "play.circle.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(healthKitManager.isAuthorized ? Color.green : Color.gray)
                            .cornerRadius(15)
                    }
                    .disabled(!healthKitManager.isAuthorized)
                    
                    if !healthKitManager.isAuthorized {
                        Text("HealthKit access required for workout tracking")
                        .font(.caption)
                        .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }
        }
        .padding(.horizontal, 30)
    }

    // MARK: - Map View

    private var mapView: some View {
        MapViewContainer(
            location: locationManager.currentLocation,
            route: currentRoute,
            onDestinationSelected: navEngine.isNavigating ? nil : { coordinate, mapLocation in
                handleDestinationSelection(coordinate: coordinate, mapLocation: mapLocation)
            }
        )
        .cornerRadius(20)
        .padding(.horizontal, 30)
    }
    
    // MARK: - Connection Status View
    
    private var connectionStatusView: some View {
        HStack(spacing: 8) {
            // 1. Status Light
            // Changed to Image(systemName: "circle.fill") to match the size of the signal icon exactly
            Image(systemName: "circle.fill")
                .font(.caption)
                .foregroundColor(bleManager.isConnected ? .green : .red)
                .shadow(color: bleManager.isConnected ? .green.opacity(0.5) : .red.opacity(0.5), 
                       radius: 4)
            
            // 2. "BikeComputer" Label
            // Now styled exactly like the dBm text (Gray & Caption size)
            Text("BikeComputer")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
            // 3. Signal Info
            if bleManager.isConnected && bleManager.signalStrength != 0 {
                // Adds a small divider dot or just space
                Text("•")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
                
                            Image(systemName: signalIcon(for: bleManager.signalStrength))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                            Text("\(bleManager.signalStrength) dBm")
                    .font(.caption)
                        .foregroundColor(.secondary)
                    }

            // 4. Reconnect Button (only shown when not connected)
            if !bleManager.isConnected {
                Button(action: {
                    bleManager.startScanning()
                }) {
                    Label(bleManager.isScanning ? "Scanning..." : "Reconnect",
                          systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                .disabled(bleManager.isScanning)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray6))
        )
        .padding(.horizontal, 30)
    }
    
    // MARK: - Navigation Status View
    
    private var navigationStatusView: some View {
        VStack(spacing: 20) {
            // Arrow Icon
            Image(systemName: arrowIcon(for: navEngine.currentIconID))
                .font(.system(size: 80))
                .foregroundColor(.blue)
            
            // Distance
            Text("\(navEngine.distanceToManeuver)")
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            
            Text("meters")
                .font(.title3)
                .foregroundColor(.secondary)
            
            // Instruction
            Text(navEngine.currentInstruction)
                .font(.title2)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemGray6))
        )
        .padding(.horizontal, 30)
    }
    
    // MARK: - Calculation Status View

    private var calculationStatusView: some View {
        VStack(spacing: 15) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Calculating Route...")
                .font(.title2)
                .foregroundColor(.secondary)

            if !routeCalculation.status.isEmpty {
                Text(routeCalculation.status)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .frame(height: 550)
    }
    
    // MARK: - Placeholder View
    
    private var placeholderView: some View {
        VStack(spacing: 15) {
            Image(systemName: "map")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("Ready to Navigate")
                .font(.title2)
                .foregroundColor(.secondary)
            
            if bleManager.isConnected {
                Text("Tap 'Start Navigation' to begin")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("Connect to bike computer first")
                    .font(.subheadline)
                    .foregroundColor(.orange)
            }
        }
        .frame(height: 550)
    }
    
    // MARK: - Helper Functions
    
    private func setupManagers() {
        navEngine.setBLEManager(bleManager)
        bleManager.startScanning()
        bleManager.startMonitoringRSSI()
        // Link managers for workout tracking
        locationManager.healthKitManager = healthKitManager
        healthKitManager.locationManager = locationManager
    }
    
    private func handleDestinationSelection(coordinate: CLLocationCoordinate2D, mapLocation: CLLocation?) {
        print("Destination selected at: \(coordinate.latitude), \(coordinate.longitude)")
        
        // Check if BLE is connected
        guard bleManager.isConnected else {
            print("BLE not connected - cannot start navigation")
            alert.message = "Please connect to your bike computer before starting navigation."
            alert.isShowing = true
            return
        }
        
        // Get current location - try locationManager first, then fall back to map's location
        let sourceLocation: CLLocation
        if let currentLoc = locationManager.currentLocation {
            sourceLocation = currentLoc
            print("Using locationManager location: \(currentLoc.coordinate.latitude), \(currentLoc.coordinate.longitude)")
        } else if let mapLoc = mapLocation {
            sourceLocation = mapLoc
            print("Using map's user location: \(mapLoc.coordinate.latitude), \(mapLoc.coordinate.longitude)")
        } else {
            print("Warning: No location available from any source")
            alert.message = "Unable to determine your current location. Please enable location services."
            alert.isShowing = true
            locationManager.requestLocation()
            return
        }
        
        // Create map items for route calculation
        let sourceItem = MKMapItem(placemark: MKPlacemark(coordinate: sourceLocation.coordinate))
        sourceItem.name = "Current Location"
        
        let destinationItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        destinationItem.name = "Selected Location"
        
        // Start route calculation
        routeCalculation.isCalculating = true
        routeCalculation.status = "Calculating route..."
        
        // Calculate the route
        let request = MKDirections.Request()
        request.source = sourceItem
        request.destination = destinationItem
        request.transportType = transportType
        request.requestsAlternateRoutes = false
        
        print("Calculating route with transport type: \(transportType.rawValue)")
        
        let directions = MKDirections(request: request)
        directions.calculate { [self] response, error in
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
            
            // Start simulated navigation with the real route
            self.navEngine.startSimulatedNavigation(with: route)
            
            // Optimization #3: Enable location tracking for navigation
            self.locationManager.setNavigating(true)
            
            // Show navigation+workout view
            self.selectedView = 1
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.routeCalculation.isCalculating = false
                self.routeCalculation.status = ""
            }
        }
    }
    
    private func calculateRoute(from source: String, to destination: String) {
        print("Starting route calculation from '\(source)' to '\(destination)'")
        
        // Optimization #4: Cancel any ongoing searches
        ongoingSourceSearch?.cancel()
        ongoingDestinationSearch?.cancel()
        ongoingDirections?.cancel()

        routeCalculation.isCalculating = true
        routeCalculation.status = "Searching for locations..."

        // Check if source is current location
        let isUsingCurrentLocation = source.contains("Current Location") || source.contains("Getting current location")
        
        if isUsingCurrentLocation, let currentLoc = locationManager.currentLocation {
            // Use current location directly
            let sourceItem = MKMapItem(placemark: MKPlacemark(coordinate: currentLoc.coordinate))
            sourceItem.name = "Current Location"
            
            print("Using current location: \(currentLoc.coordinate.latitude), \(currentLoc.coordinate.longitude)")
            self.routeCalculation.status = "Finding destination..."
            
            // Find destination and calculate route
            self.findDestinationAndCalculateRoute(from: sourceItem, destination: destination)
        } else {
            // Use MKLocalSearch for source address
            let sourceSearchRequest = MKLocalSearch.Request()
            sourceSearchRequest.naturalLanguageQuery = source
            
            let sourceSearch = MKLocalSearch(request: sourceSearchRequest)
            self.ongoingSourceSearch = sourceSearch // Optimization #4: Store reference
            sourceSearch.start { (response, error) in
                self.ongoingSourceSearch = nil // Clear reference when done
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
                
                // Find destination and calculate route
                self.findDestinationAndCalculateRoute(from: sourceItem, destination: destination)
            }
        }
    }
    
    private func findDestinationAndCalculateRoute(from sourceItem: MKMapItem, destination: String) {
        let destinationSearchRequest = MKLocalSearch.Request()
        destinationSearchRequest.naturalLanguageQuery = destination
        
        let destinationSearch = MKLocalSearch(request: destinationSearchRequest)
        self.ongoingDestinationSearch = destinationSearch // Optimization #4: Store reference
        destinationSearch.start { (response, error) in
            self.ongoingDestinationSearch = nil // Clear reference when done
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
                self.ongoingDirections = directions // Optimization #4: Store reference
                directions.calculate { response, error in
                    self.ongoingDirections = nil // Clear reference when done
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
                    
                    for (index, step) in route.steps.enumerated() {
                        print("Step \(index): \(step.instructions) - \(step.distance)m")
                    }
                    
                    self.routeCalculation.status = "Starting navigation..."
                    
                    // Store the route for map display
                    self.currentRoute = route
                    
                    // Start simulated navigation with the real route
                    self.navEngine.startSimulatedNavigation(with: route)
                    
                    // Reset to show navigation details first
                    self.selectedView = 1
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.routeCalculation.isCalculating = false
                        self.routeCalculation.status = ""
                }
            }
        }
    }
    
    private func signalIcon(for rssi: Int) -> String {
        if rssi > -50 {
            return "wifi"
        } else if rssi > -70 {
            return "wifi.slash"
        } else {
            return "wifi.exclamationmark"
        }
    }
    
    private func arrowIcon(for iconID: Int) -> String {
        switch iconID {
        case 1: return "arrow.turn.up.left"        // Slight left
        case 2: return "arrow.turn.up.left"        // Turn left
        case 3: return "arrow.turn.up.right"       // Slight right
        case 4: return "arrow.turn.up.right"       // Turn right
        case 5: return "arrow.uturn.left"          // U-turn
        case 6: return "arrow.merge"               // Merge
        case 7: return "arrow.triangle.2.circlepath" // Roundabout
        case 8: return "mappin.and.ellipse"        // Destination
        default: return "arrow.up"                 // Straight
        }
    }

    private func timeString(from timeInterval: TimeInterval) -> String {
        let hours = Int(timeInterval) / 3600
        let minutes = Int(timeInterval) / 60 % 60
        let seconds = Int(timeInterval) % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Route Input Sheet with Address Autocomplete

class AddressSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var suggestions: [MKLocalSearchCompletion] = []
    
    private let completer = MKLocalSearchCompleter()
    
    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }
    
    func search(query: String) {
        completer.queryFragment = query
    }
    
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results
    }
    
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        print("Address search error: \(error.localizedDescription)")
    }
}

struct RouteInputView: View {
    @Environment(\.dismiss) var dismiss
    
    @Binding var sourceAddress: String
    @Binding var destinationAddress: String
    @ObservedObject var locationManager: CurrentLocationManager
    
    var onStartNavigation: (String, String, MKDirectionsTransportType) -> Void
    
    @StateObject private var destinationCompleter = AddressSearchCompleter()
    @FocusState private var isDestinationFieldFocused: Bool
    
    @State private var hasSelectedDestination = false
    @State private var isSelectingFromSuggestion = false
    @State private var selectedTransportType: MKDirectionsTransportType = {
        if #available(iOS 18.0, *) {
            return .cycling
        } else {
            return .walking  // Fall back to walking for pre-iOS 18
        }
    }()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Destination Search Field (always visible)
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        
                        TextField("Search for a destination", text: $destinationAddress)
                        .textContentType(.fullStreetAddress)
                            .focused($isDestinationFieldFocused)
                            .onChange(of: destinationAddress) { newValue in
                                // Skip processing if we're programmatically selecting from suggestions
                                if isSelectingFromSuggestion {
                                    isSelectingFromSuggestion = false
                                    return
                                }
                                
                                destinationCompleter.search(query: newValue)
                                // Reset selection state when user starts typing again
                                if hasSelectedDestination {
                                    hasSelectedDestination = false
                                }
                            }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    
                    // From field (only shown after destination is selected)
                    if hasSelectedDestination {
                        HStack(spacing: 12) {
                            Image(systemName: "location.fill")
                                .foregroundColor(.blue)
                            
                            Text(locationManager.currentAddress)
                                .foregroundColor(.primary)
                            
                            Spacer()
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }
                }
                .padding()
                
                // Transport Type Selection (only shown after destination is selected)
                if hasSelectedDestination {
                    HStack(spacing: 12) {
                        if #available(iOS 18.0, *) {
                            TransportButton(
                                icon: "bicycle",
                                label: "Bike",
                                isSelected: selectedTransportType == .cycling,
                                action: { selectedTransportType = .cycling }
                            )
                        }
                        
                        TransportButton(
                            icon: "car.fill",
                            label: "Drive",
                            isSelected: selectedTransportType == .automobile,
                            action: { selectedTransportType = .automobile }
                        )
                        
                        TransportButton(
                            icon: "figure.walk",
                            label: "Walk",
                            isSelected: selectedTransportType == .walking,
                            action: { selectedTransportType = .walking }
                        )
                    }
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                // Suggestions (shown while typing destination)
                if !hasSelectedDestination && !destinationCompleter.suggestions.isEmpty {
                    suggestionsList(for: destinationCompleter.suggestions)
                } else {
                    Spacer()
                }
                
                // Go button (only shown after destination is selected)
                if hasSelectedDestination {
                    Button(action: {
                        onStartNavigation(locationManager.currentAddress, destinationAddress, selectedTransportType)
                        dismiss()
                    }) {
                        Text("Go")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(12)
                    }
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.title2)
                    }
                }
            }
            .onAppear {
                // Auto-focus destination field when view appears
                isDestinationFieldFocused = true
                
                // Request current location
                locationManager.startUpdatingLocation()
            }
            .onDisappear {
                // Reset state when dismissed
                hasSelectedDestination = false
                destinationAddress = ""
            }
        }
    }
    
    private func suggestionsList(for suggestions: [MKLocalSearchCompletion]) -> some View {
        List(suggestions, id: \.self) { suggestion in
            Button(action: {
                let fullAddress = "\(suggestion.title), \(suggestion.subtitle)"
                isSelectingFromSuggestion = true
                destinationAddress = fullAddress
                hasSelectedDestination = true
                isDestinationFieldFocused = false
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(suggestion.title)
                            .font(.body)
                        Text(suggestion.subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Transport Button Component

struct TransportButton: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                Text(label)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.blue : Color(.systemGray6))
            )
            .foregroundColor(isSelected ? .white : .primary)
        }
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
