//
//  CurrentLocationManager.swift
//  BikeComputer
//
//  Location services manager with intelligent update control
//

import Foundation
import CoreLocation
import Combine
#if canImport(UIKit) && !HOST_TESTING
import UIKit
#endif

nonisolated enum RideActivityPolicy {
    static func shouldTrackLocation(
        isNavigating: Bool,
        isViewingMap: Bool,
        isWorkoutActive: Bool,
        isRefreshingDeviceDestinationLocation: Bool,
        isRideDetectionArmed: Bool = false
    ) -> Bool {
        isNavigating ||
            isViewingMap ||
            isWorkoutActive ||
            isRefreshingDeviceDestinationLocation ||
            isRideDetectionArmed
    }

    static func shouldTrackLocationInBackground(
        isNavigating: Bool,
        isWorkoutActive: Bool,
        isRefreshingDeviceDestinationLocation: Bool,
        isRideDetectionArmed: Bool = false
    ) -> Bool {
        isNavigating ||
            isWorkoutActive ||
            isRefreshingDeviceDestinationLocation ||
            isRideDetectionArmed
    }

    static func shouldReverseGeocodeLocation(
        isNavigating: Bool,
        isViewingMap: Bool,
        isWorkoutActive: Bool,
        isRefreshingDeviceDestinationLocation: Bool
    ) -> Bool {
        isNavigating || isViewingMap || isWorkoutActive ||
            isRefreshingDeviceDestinationLocation
    }

    static func shouldKeepScreenAwake(
        isNavigating: Bool,
        isWorkoutActive: Bool,
        isApplicationActive: Bool
    ) -> Bool {
        isApplicationActive && (isNavigating || isWorkoutActive)
    }
}

nonisolated enum LocationAuthorizationRemediation: Equatable {
    case requestInApp
    case openSettings
    case none
}

nonisolated enum LocationAuthorizationRemediationPolicy {
    static func action(
        for status: CLAuthorizationStatus
    ) -> LocationAuthorizationRemediation {
        switch status {
        case .notDetermined:
            .requestInApp
        case .restricted, .denied:
            .openSettings
        case .authorizedAlways:
            .none
#if !os(macOS)
        case .authorizedWhenInUse:
            .none
#endif
        @unknown default:
            .openSettings
        }
    }

    static func buttonTitle(
        for status: CLAuthorizationStatus
    ) -> String? {
        switch action(for: status) {
        case .requestInApp:
            "Continue"
        case .openSettings:
            "Open iPhone Settings"
        case .none:
            nil
        }
    }

    static func allowsDismissal(
        for status: CLAuthorizationStatus
    ) -> Bool {
        action(for: status) != .requestInApp
    }
}

nonisolated enum RideIdleTimerController {
    static func update(
        isNavigating: Bool,
        isWorkoutActive: Bool,
        isApplicationActive: Bool,
        setIdleTimerDisabled: (Bool) -> Void
    ) {
        setIdleTimerDisabled(
            RideActivityPolicy.shouldKeepScreenAwake(
                isNavigating: isNavigating,
                isWorkoutActive: isWorkoutActive,
                isApplicationActive: isApplicationActive
            )
        )
    }
}

nonisolated enum RideDetectionLocationStatus: Equatable {
    case disabled
    case waitingForCompatibleDevice
    case permissionNeeded
    case foregroundOnly
    case waitingForPreciseLocation
    case sending
    case stale

    var label: String {
        switch self {
        case .disabled: "Disabled"
        case .waitingForCompatibleDevice: "Waiting for compatible device"
        case .permissionNeeded: "Permission needed"
        case .foregroundOnly: "Foreground only"
        case .waitingForPreciseLocation: "Waiting for precise location"
        case .sending: "Sending"
        case .stale: "Location stale"
        }
    }
}

nonisolated enum RideDetectionLocationStatusResolver {
    static let freshnessInterval: TimeInterval = 3
    static let maximumHorizontalAccuracyMeters: CLLocationAccuracy = 12.5
    static let futureTimestampTolerance: TimeInterval = 1

    static func resolve(
        startMode: RideStartMode,
        locationUseAcknowledged: Bool,
        isNavigationReady: Bool,
        supportsRideAutomation: Bool,
        supportsGPSPositionQualityV1: Bool,
        authorizationLevel: LocationAuthorizationLevel,
        accuracyAuthorization: CLAccuracyAuthorization,
        location: CLLocation?,
        now: Date = Date()
    ) -> RideDetectionLocationStatus {
        guard startMode != .off, locationUseAcknowledged else {
            return .disabled
        }
        guard isNavigationReady, supportsRideAutomation,
              supportsGPSPositionQualityV1 else {
            return .waitingForCompatibleDevice
        }
        guard authorizationLevel == .always ||
                authorizationLevel == .whenInUse else {
            return .permissionNeeded
        }
        guard authorizationLevel == .always else {
            return .foregroundOnly
        }
        guard accuracyAuthorization == .fullAccuracy,
              let location else {
            return .waitingForPreciseLocation
        }
        let age = now.timeIntervalSince(location.timestamp)
        guard age.isFinite,
              age >= -futureTimestampTolerance else {
            return .waitingForPreciseLocation
        }
        guard age <= freshnessInterval else { return .stale }
        guard location.horizontalAccuracy.isFinite,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= maximumHorizontalAccuracyMeters,
              location.speed.isFinite,
              location.speed >= 0 else {
            return .waitingForPreciseLocation
        }
        return .sending
    }
}

nonisolated enum DeveloperLocationOverride {
    static let argumentPrefix = "--device-map-location="

    static func coordinate(arguments: [String]) -> CLLocationCoordinate2D? {
        guard let argument = arguments.first(where: {
            $0.hasPrefix(argumentPrefix)
        }) else {
            return nil
        }
        let value = argument.dropFirst(argumentPrefix.count)
        let components = value.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count == 2,
              let latitude = CLLocationDegrees(components[0]),
              let longitude = CLLocationDegrees(components[1]),
              latitude.isFinite,
              longitude.isFinite,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else {
            return nil
        }
        return CLLocationCoordinate2D(
            latitude: latitude,
            longitude: longitude
        )
    }

    static func applying(
        _ coordinate: CLLocationCoordinate2D,
        to location: CLLocation
    ) -> CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            course: location.course,
            speed: location.speed,
            timestamp: location.timestamp
        )
    }
}

nonisolated enum LocationAuthorizationLevel {
    case denied
    case whenInUse
    case always
}

protocol LocationManagerClient: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var authorizationLevel: LocationAuthorizationLevel { get }
    var accuracyAuthorization: CLAccuracyAuthorization { get }

    func setDelegate(_ delegate: CLLocationManagerDelegate?)
    func configureForCycling()
    func setRideDetectionTrackingEnabled(_ enabled: Bool)
    func setBackgroundTrackingEnabled(_ enabled: Bool)
    func requestLocation()
    func requestWhenInUseAuthorization()
    func requestAlwaysAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}

final class CoreLocationManagerClient: LocationManagerClient {
    private let manager = CLLocationManager()

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    var authorizationLevel: LocationAuthorizationLevel {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            return .always
#if !os(macOS)
        case .authorizedWhenInUse:
            return .whenInUse
#endif
        case .notDetermined, .restricted, .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    var accuracyAuthorization: CLAccuracyAuthorization {
        manager.accuracyAuthorization
    }

    func setDelegate(_ delegate: CLLocationManagerDelegate?) {
        manager.delegate = delegate
    }

    func configureForCycling() {
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .fitness
#if !os(macOS)
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
        manager.showsBackgroundLocationIndicator = false
#endif
    }

    func setBackgroundTrackingEnabled(_ enabled: Bool) {
#if !os(macOS)
        manager.allowsBackgroundLocationUpdates = enabled
        manager.pausesLocationUpdatesAutomatically = !enabled
        manager.showsBackgroundLocationIndicator = enabled
#endif
    }

    func setRideDetectionTrackingEnabled(_ enabled: Bool) {
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = enabled ? kCLDistanceFilterNone : 5
        manager.activityType = .fitness
    }

    func requestLocation() {
        manager.requestLocation()
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    func startUpdatingLocation() {
        manager.startUpdatingLocation()
    }

    func stopUpdatingLocation() {
        manager.stopUpdatingLocation()
    }
}

class CurrentLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var currentLocation: CLLocation?
    @Published var currentAddress: String = "Current Location"
    @Published var authorizationStatus: CLAuthorizationStatus
    @Published var accuracyAuthorization: CLAccuracyAuthorization

    weak var diagnosticsRecorder: (any RideDiagnosticsEventSink)?
    
    private let locationManager: LocationManagerClient
    private let applicationIsActive: () -> Bool
    private var lastGeocodedLocation: CLLocation?
    private var lastGeocodeTime: Date?
    private var workoutActivityCancellable: AnyCancellable?
    
    // MARK: - Optimization #3: Intelligent Location Update Management
    private var isNavigating = false
    private var isViewingMap = false
    private var isWorkoutActive = false
    private var isRideDetectionArmed = false
    private var isLocationUpdating = false
    private var isDeviceDestinationRequestsEnabled = false
    private var isRefreshingDeviceDestinationLocation = false
    private var hasRequestedAlwaysAuthorizationForDeviceDestinations = false
    private var hasRequestedAlwaysAuthorizationForRideActivity = false
    private var lastDiagnosticsLocationRecordAt = Date.distantPast
#if DEBUG
    private let developerLocationOverride = DeveloperLocationOverride.coordinate(
        arguments: ProcessInfo.processInfo.arguments
    )
#endif
    
    init(
        locationManager: LocationManagerClient = CoreLocationManagerClient(),
        applicationIsActive: (() -> Bool)? = nil
    ) {
        self.locationManager = locationManager
        self.applicationIsActive = applicationIsActive ?? {
#if canImport(UIKit) && !HOST_TESTING
            MainActor.assumeIsolated {
                UIApplication.shared.applicationState == .active
            }
#else
            true
#endif
        }
        authorizationStatus = locationManager.authorizationStatus
        accuracyAuthorization = locationManager.accuracyAuthorization
        super.init()
        locationManager.setDelegate(self)
        locationManager.configureForCycling()
#if DEBUG
        if let developerLocationOverride {
            print(
                "Developer device-map location override active: " +
                    "\(developerLocationOverride.latitude)," +
                    "\(developerLocationOverride.longitude)"
            )
        }
#endif
        // User-initiated feature flows own the permission request so the native
        // prompt appears in context and the user's response remains authoritative.
    }
    
    func requestLocation() {
        locationManager.requestLocation()
    }

    func setDeviceDestinationRequestsEnabled(_ enabled: Bool) {
        guard isDeviceDestinationRequestsEnabled != enabled else { return }
        isDeviceDestinationRequestsEnabled = enabled
        prepareDeviceDestinationRequestsIfNeeded()
    }

    func prepareDeviceDestinationRequestsIfNeeded() {
        guard isDeviceDestinationRequestsEnabled,
              locationManager.authorizationLevel == .whenInUse,
              applicationIsActive(),
              !hasRequestedAlwaysAuthorizationForDeviceDestinations else {
            return
        }
        hasRequestedAlwaysAuthorizationForDeviceDestinations = true
        locationManager.requestAlwaysAuthorization()
    }

    @discardableResult
    func beginDeviceDestinationLocationRefresh(restart: Bool) -> Bool {
        guard isLocationAuthorized,
              locationManager.authorizationLevel == .always
                || applicationIsActive() else {
            return false
        }
        isRefreshingDeviceDestinationLocation = true
        updateLocationTracking(restart: restart)
        return true
    }

    func endDeviceDestinationLocationRefresh() {
        guard isRefreshingDeviceDestinationLocation else { return }
        isRefreshingDeviceDestinationLocation = false
        updateLocationTracking()
    }

    func requestWhenInUseAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    var isLocationAuthorized: Bool {
        locationManager.authorizationLevel == .always ||
            locationManager.authorizationLevel == .whenInUse
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

    func setWorkoutActive(_ active: Bool) {
        guard isWorkoutActive != active else { return }
        isWorkoutActive = active
        updateLocationTracking()
    }

    func setRideDetectionArmed(_ armed: Bool) {
        guard isRideDetectionArmed != armed else { return }
        isRideDetectionArmed = armed
        locationManager.setRideDetectionTrackingEnabled(armed)
        updateLocationTracking()
    }

    @MainActor
    func bindWorkoutMetricsStore(_ store: WorkoutMetricsStore) {
        workoutActivityCancellable = store.$shouldMaintainWorkoutServices
            .removeDuplicates()
            .sink { [weak self] isWorkoutActive in
                self?.setWorkoutActive(isWorkoutActive)
            }
    }

    func applicationStateDidChange() {
        updateLocationTracking()
    }

    func applicationDidBecomeActive() {
        applicationStateDidChange()
    }
    
    public func updateLocationTracking(restart: Bool = false) {
        let isApplicationActive = applicationIsActive()
        let shouldTrack = RideActivityPolicy.shouldTrackLocation(
            isNavigating: isNavigating,
            isViewingMap: isViewingMap && isApplicationActive,
            isWorkoutActive: isWorkoutActive,
            isRefreshingDeviceDestinationLocation:
                isRefreshingDeviceDestinationLocation,
            isRideDetectionArmed: isRideDetectionArmed
        )
        let shouldTrackInBackground =
            RideActivityPolicy.shouldTrackLocationInBackground(
                isNavigating: isNavigating,
                isWorkoutActive: isWorkoutActive,
                isRefreshingDeviceDestinationLocation:
                    isRefreshingDeviceDestinationLocation,
                isRideDetectionArmed: isRideDetectionArmed
            )

        if shouldTrackInBackground &&
            locationManager.authorizationLevel == .whenInUse &&
            isApplicationActive &&
            !hasRequestedAlwaysAuthorizationForRideActivity {
            hasRequestedAlwaysAuthorizationForRideActivity = true
            locationManager.requestAlwaysAuthorization()
        }

        let canTrackInBackground = shouldTrackInBackground &&
            locationManager.authorizationLevel == .always
        locationManager.setBackgroundTrackingEnabled(canTrackInBackground)

        let canStartUpdates =
            locationManager.authorizationLevel == .always
                || isApplicationActive
        
        if shouldTrack &&
            isLocationAuthorized &&
            canStartUpdates &&
            (!isLocationUpdating || restart) {
            if isLocationUpdating {
                locationManager.stopUpdatingLocation()
            }
            print("🌍 Starting location updates (navigating: \(isNavigating), map: \(isViewingMap), workout: \(isWorkoutActive), ride detection: \(isRideDetectionArmed), device destination request: \(isRefreshingDeviceDestinationLocation))")
            locationManager.startUpdatingLocation()
            isLocationUpdating = true
            diagnosticsRecorder?.record(
                category: .gps,
                event: "tracking_started",
                fields: [
                    "navigating": String(isNavigating),
                    "viewingMap": String(isViewingMap),
                    "workoutActive": String(isWorkoutActive),
                    "rideDetectionArmed": String(isRideDetectionArmed),
                    "background": String(!isApplicationActive),
                ]
            )
        } else if (!shouldTrack || !isLocationAuthorized || !canStartUpdates) &&
                    isLocationUpdating {
            print("🌍 Stopping location updates (not needed)")
            locationManager.stopUpdatingLocation()
            isLocationUpdating = false
            diagnosticsRecorder?.record(
                category: .gps,
                event: "tracking_stopped",
                fields: [
                    "navigating": String(isNavigating),
                    "viewingMap": String(isViewingMap),
                    "workoutActive": String(isWorkoutActive),
                    "rideDetectionArmed": String(isRideDetectionArmed),
                    "authorized": String(isLocationAuthorized),
                ]
            )
        }
    }
    
    func startUpdatingLocation() {
        if isLocationAuthorized && !isLocationUpdating {
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
        guard let sourceLocation = locations.last else { return }
#if DEBUG
        let location = developerLocationOverride.map {
            DeveloperLocationOverride.applying($0, to: sourceLocation)
        } ?? sourceLocation
#else
        let location = sourceLocation
#endif
        
        currentLocation = location

        let now = Date()
        if now.timeIntervalSince(lastDiagnosticsLocationRecordAt) >= 30 {
            lastDiagnosticsLocationRecordAt = now
            let age = max(0, now.timeIntervalSince(location.timestamp))
            let accuracy = location.horizontalAccuracy
            let accuracyBucket: String
            if !accuracy.isFinite || accuracy < 0 {
                accuracyBucket = "unavailable"
            } else if accuracy <= 5 {
                accuracyBucket = "excellent"
            } else if accuracy <= 12.5 {
                accuracyBucket = "good"
            } else if accuracy <= 50 {
                accuracyBucket = "coarse"
            } else {
                accuracyBucket = "poor"
            }
            diagnosticsRecorder?.record(
                category: .gps,
                event: "quality_checkpoint",
                fields: [
                    "sampleCount": String(locations.count),
                    "ageMs": String(Int(min(age * 1000, 86_400_000))),
                    "accuracyBucket": accuracyBucket,
                    "speedAvailable": String(location.speed.isFinite && location.speed >= 0),
                    "authorization": locationAuthorizationLabel,
                ]
            )
        }

        // Ride detection consumes raw location only. Reverse geocoding every
        // minute during an otherwise headless all-day detector session adds
        // network, energy, and privacy cost without any visible consumer.
        guard RideActivityPolicy.shouldReverseGeocodeLocation(
            isNavigating: isNavigating,
            isViewingMap: isViewingMap && applicationIsActive(),
            isWorkoutActive: isWorkoutActive,
            isRefreshingDeviceDestinationLocation:
                isRefreshingDeviceDestinationLocation
        ) else { return }
        
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
                
                // Build street address (number + street name)
                var streetAddress = ""
                if let streetNumber = placemark.subThoroughfare {
                    streetAddress = streetNumber
                }
                if let street = placemark.thoroughfare {
                    streetAddress = streetAddress.isEmpty ? street : "\(streetAddress) \(street)"
                }
                if !streetAddress.isEmpty {
                    addressComponents.append(streetAddress)
                }
                
                if let city = placemark.locality {
                    addressComponents.append(city)
                }
                
                self?.currentAddress = addressComponents.isEmpty ? "Current Location" : addressComponents.joined(separator: ", ")
                print("Current location address: \(self?.currentAddress ?? "Unknown")")
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
        let nsError = error as NSError
        diagnosticsRecorder?.record(
            level: .warning,
            category: .gps,
            event: "error",
            fields: [
                "domain": String(nsError.domain.prefix(64)),
                "code": String(nsError.code),
            ],
            captureId: nil
        )
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = self.locationManager.accuracyAuthorization
        diagnosticsRecorder?.record(
            category: .gps,
            event: "authorization_changed",
            fields: [
                "authorization": locationAuthorizationLabel,
                "accuracy": String(accuracyAuthorization.rawValue),
            ]
        )
        prepareDeviceDestinationRequestsIfNeeded()
        updateLocationTracking()
    }

    private var locationAuthorizationLabel: String {
        switch locationManager.authorizationLevel {
        case .denied: return "denied"
        case .whenInUse: return "when_in_use"
        case .always: return "always"
        }
    }

}
