//
//  CurrentLocationManager.swift
//  BikeComputer
//
//  Location services manager with intelligent update control
//

import Foundation
import CoreLocation
import Combine

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
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.showsBackgroundLocationIndicator = false
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
    
    public func updateLocationTracking() {
        let shouldTrack = isNavigating || 
                         isViewingMap || 
                         (healthKitManager?.isWorkoutActive == true)
        let shouldTrackInBackground = isNavigating || (healthKitManager?.isWorkoutActive == true)

        if shouldTrackInBackground && locationManager.authorizationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }

        locationManager.allowsBackgroundLocationUpdates = shouldTrackInBackground
        locationManager.pausesLocationUpdatesAutomatically = !shouldTrackInBackground
        locationManager.showsBackgroundLocationIndicator = shouldTrackInBackground
        
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
        
        // Pass to HealthKit to calculate speed/distance
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
}
