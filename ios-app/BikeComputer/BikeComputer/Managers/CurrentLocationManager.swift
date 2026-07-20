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

class CurrentLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var currentLocation: CLLocation?
    @Published var currentAddress: String = "Current Location"
    @Published var authorizationStatus: CLAuthorizationStatus
    
    private let locationManager = CLLocationManager()
    private var lastGeocodedLocation: CLLocation?
    private var lastGeocodeTime: Date?
    
    // MARK: - Optimization #3: Intelligent Location Update Management
    private var isNavigating = false
    private var isViewingMap = false
    private var isLocationUpdating = false
    private var isDeviceDestinationRequestsEnabled = false
    private var isRefreshingDeviceDestinationLocation = false
    private var hasRequestedAlwaysAuthorizationForDeviceDestinations = false
    
    override init() {
        authorizationStatus = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5 // Update every 5 meters for better tracking
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.pausesLocationUpdatesAutomatically = true
#if !os(macOS)
        locationManager.showsBackgroundLocationIndicator = false
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
              Self.isAuthorizedWhenInUse(authorizationStatus),
              Self.applicationIsActive,
              !hasRequestedAlwaysAuthorizationForDeviceDestinations else {
            return
        }
        hasRequestedAlwaysAuthorizationForDeviceDestinations = true
        locationManager.requestAlwaysAuthorization()
    }

    @discardableResult
    func beginDeviceDestinationLocationRefresh(restart: Bool) -> Bool {
        guard isLocationAuthorized,
              authorizationStatus == .authorizedAlways || Self.applicationIsActive else {
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
        authorizationStatus == .authorizedAlways ||
            Self.isAuthorizedWhenInUse(authorizationStatus)
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
    
    public func updateLocationTracking(restart: Bool = false) {
        let shouldTrack = isNavigating || 
                         isViewingMap || 
                         isRefreshingDeviceDestinationLocation
        let shouldTrackInBackground = isNavigating ||
                                      isRefreshingDeviceDestinationLocation

        if shouldTrackInBackground &&
            Self.isAuthorizedWhenInUse(locationManager.authorizationStatus) &&
            Self.applicationIsActive {
            locationManager.requestAlwaysAuthorization()
        }

        locationManager.allowsBackgroundLocationUpdates = shouldTrackInBackground
        locationManager.pausesLocationUpdatesAutomatically = !shouldTrackInBackground
#if !os(macOS)
        locationManager.showsBackgroundLocationIndicator = shouldTrackInBackground
#endif
        
        if shouldTrack && isLocationAuthorized && (!isLocationUpdating || restart) {
            if isLocationUpdating {
                locationManager.stopUpdatingLocation()
            }
            print("🌍 Starting location updates (navigating: \(isNavigating), map: \(isViewingMap), device destination request: \(isRefreshingDeviceDestinationLocation))")
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
        guard let location = locations.last else { return }
        
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

    private static var applicationIsActive: Bool {
#if canImport(UIKit) && !HOST_TESTING
        UIApplication.shared.applicationState == .active
#else
        true
#endif
    }

    private static func isAuthorizedWhenInUse(_ status: CLAuthorizationStatus) -> Bool {
#if os(macOS)
        false
#else
        status == .authorizedWhenInUse
#endif
    }
}
