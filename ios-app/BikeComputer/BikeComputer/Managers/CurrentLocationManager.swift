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
        isRefreshingDeviceDestinationLocation: Bool
    ) -> Bool {
        isNavigating ||
            isViewingMap ||
            isWorkoutActive ||
            isRefreshingDeviceDestinationLocation
    }

    static func shouldTrackLocationInBackground(
        isNavigating: Bool,
        isWorkoutActive: Bool,
        isRefreshingDeviceDestinationLocation: Bool
    ) -> Bool {
        isNavigating ||
            isWorkoutActive ||
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

enum LocationAuthorizationLevel {
    case denied
    case whenInUse
    case always
}

protocol LocationManagerClient: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var authorizationLevel: LocationAuthorizationLevel { get }

    func setDelegate(_ delegate: CLLocationManagerDelegate?)
    func configureForCycling()
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
    
    private let locationManager: LocationManagerClient
    private let applicationIsActive: () -> Bool
    private var lastGeocodedLocation: CLLocation?
    private var lastGeocodeTime: Date?
    private var workoutActivityCancellable: AnyCancellable?
    
    // MARK: - Optimization #3: Intelligent Location Update Management
    private var isNavigating = false
    private var isViewingMap = false
    private var isWorkoutActive = false
    private var isLocationUpdating = false
    private var isDeviceDestinationRequestsEnabled = false
    private var isRefreshingDeviceDestinationLocation = false
    private var hasRequestedAlwaysAuthorizationForDeviceDestinations = false
    private var hasRequestedAlwaysAuthorizationForRideActivity = false
#if DEBUG
    private let developerLocationOverride = DeveloperLocationOverride.coordinate(
        arguments: ProcessInfo.processInfo.arguments
    )
#endif
    
    init(
        locationManager: LocationManagerClient = CoreLocationManagerClient(),
        applicationIsActive: @escaping () -> Bool =
            CurrentLocationManager.defaultApplicationIsActive
    ) {
        self.locationManager = locationManager
        self.applicationIsActive = applicationIsActive
        authorizationStatus = locationManager.authorizationStatus
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
        // First-run onboarding owns the permission prompt so the user can read
        // the rationale or skip location before iOS asks for access.
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

    @MainActor
    func bindWorkoutMetricsStore(_ store: WorkoutMetricsStore) {
        workoutActivityCancellable = store.$shouldMaintainWorkoutServices
            .removeDuplicates()
            .sink { [weak self] isWorkoutActive in
                self?.setWorkoutActive(isWorkoutActive)
            }
    }

    func applicationDidBecomeActive() {
        updateLocationTracking()
    }
    
    public func updateLocationTracking(restart: Bool = false) {
        let isApplicationActive = applicationIsActive()
        let shouldTrack = RideActivityPolicy.shouldTrackLocation(
            isNavigating: isNavigating,
            isViewingMap: isViewingMap && isApplicationActive,
            isWorkoutActive: isWorkoutActive,
            isRefreshingDeviceDestinationLocation:
                isRefreshingDeviceDestinationLocation
        )
        let shouldTrackInBackground =
            RideActivityPolicy.shouldTrackLocationInBackground(
                isNavigating: isNavigating,
                isWorkoutActive: isWorkoutActive,
                isRefreshingDeviceDestinationLocation:
                    isRefreshingDeviceDestinationLocation
            )

        if shouldTrackInBackground &&
            locationManager.authorizationLevel == .whenInUse &&
            isApplicationActive &&
            !hasRequestedAlwaysAuthorizationForRideActivity {
            hasRequestedAlwaysAuthorizationForRideActivity = true
            locationManager.requestAlwaysAuthorization()
        }

        locationManager.setBackgroundTrackingEnabled(shouldTrackInBackground)

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
            print("🌍 Starting location updates (navigating: \(isNavigating), map: \(isViewingMap), workout: \(isWorkoutActive), device destination request: \(isRefreshingDeviceDestinationLocation))")
            locationManager.startUpdatingLocation()
            isLocationUpdating = true
        } else if (!shouldTrack || !isLocationAuthorized) && isLocationUpdating {
            print("🌍 Stopping location updates (not needed)")
            locationManager.stopUpdatingLocation()
            isLocationUpdating = false
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
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        prepareDeviceDestinationRequestsIfNeeded()
        updateLocationTracking()
    }

    private static func defaultApplicationIsActive() -> Bool {
#if canImport(UIKit) && !HOST_TESTING
        return UIApplication.shared.applicationState == .active
#else
        return true
#endif
    }

}
