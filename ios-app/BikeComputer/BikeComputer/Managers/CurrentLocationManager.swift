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
        isNavigationReady: Bool,
        supportsRideAutomation: Bool,
        supportsGPSPositionQualityV1: Bool,
        authorizationLevel: LocationAuthorizationLevel,
        accuracyAuthorization: CLAccuracyAuthorization,
        location: CLLocation?,
        now: Date = Date()
    ) -> RideDetectionLocationStatus {
        guard startMode != .off else {
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
        // Consumers explicitly stop this manager when idle. A distance filter
        // would make stationary silence indistinguishable from a stalled stream.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
#if !os(macOS)
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = false
#endif
    }

    func setBackgroundTrackingEnabled(_ enabled: Bool) {
#if !os(macOS)
        manager.allowsBackgroundLocationUpdates = enabled
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = enabled
#endif
    }

    func setRideDetectionTrackingEnabled(_ enabled: Bool) {
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
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
    private let now: () -> Date
    private var recoveryTimer: Timer?
    private var trackingStartedAt: Date?
    private var lastUsableLocationAt: Date?
    private var lastRecoveryAt: Date?
    private var locationUpdatesPaused = false
    private var isRecoveryDeferred = false
    static let locationStallInterval: TimeInterval = 45
    static let locationRecoveryInterval: TimeInterval = 30
    private var lastGeocodedLocation: CLLocation?
    private var lastGeocodeTime: Date?
    private var workoutActivityCancellable: AnyCancellable?
    
    // MARK: - Optimization #3: Intelligent Location Update Management
    private var isNavigating = false
    private var isViewingMap = false
    private var isSocialRideSharing = false
    func setSocialRideSharing(_ sharing: Bool) {
        isSocialRideSharing = sharing
        updateLocationTracking()
    }
    private var isWorkoutActive = false
    private var isPhoneWorkoutActive = false
    private var isRideDetectionArmed = false
    private var isLocationUpdating = false
    private var isDeviceDestinationRequestsEnabled = false
    private var isRefreshingDeviceDestinationLocation = false
    private var hasRequestedAlwaysAuthorizationForDeviceDestinations = false
    private var hasRequestedAlwaysAuthorizationForRideActivity = false
    private var hasRequestedWhenInUseAuthorizationForRideDetection = false
    private var lastDiagnosticsLocationRecordAt = Date.distantPast
#if DEBUG
    private let developerLocationOverride = DeveloperLocationOverride.coordinate(
        arguments: ProcessInfo.processInfo.arguments
    )
#endif
    
    init(
        locationManager: LocationManagerClient = CoreLocationManagerClient(),
        applicationIsActive: (() -> Bool)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.locationManager = locationManager
        self.now = now
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
        // The Ride Start setting is the app-level switch. If it becomes armed
        // before location permission exists, request the native permission from
        // the location lifecycle rather than adding a second app-level consent.
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

    @MainActor
    func prepareSocialRideLocation() async -> Bool {
        if locationManager.authorizationStatus == .notDetermined {
            requestWhenInUseAuthorization()
            // The OS permission sheet completes the original Join action.
            while locationManager.authorizationStatus == .notDetermined {
                do { try await Task.sleep(nanoseconds: 200_000_000) }
                catch { return false }
            }
        }
        return isLocationAuthorized
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

    func setWorkoutActive(_ active: Bool, phoneOwned: Bool = false) {
        let phoneActive = active && phoneOwned
        guard isWorkoutActive != active || isPhoneWorkoutActive != phoneActive else { return }
        isWorkoutActive = active
        isPhoneWorkoutActive = phoneActive
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
        workoutActivityCancellable = Publishers.CombineLatest(
            store.$shouldMaintainWorkoutServices, store.$recordingOwner
        )
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { [weak self] active, owner in
                self?.setWorkoutActive(active, phoneOwned: owner == .iphone)
            }
    }

    func applicationStateDidChange() {
        updateLocationTracking()
        recoverLocationIfNeeded()
    }

    func applicationDidBecomeActive() {
        applicationStateDidChange()
    }
    
    public func updateLocationTracking(restart: Bool = false) {
        let isApplicationActive = applicationIsActive()
        let shouldTrack = RideActivityPolicy.shouldTrackLocation(
            isNavigating: isNavigating,
            isViewingMap: isViewingMap && isApplicationActive,
            isWorkoutActive: isWorkoutActive || isSocialRideSharing,
            isRefreshingDeviceDestinationLocation:
                isRefreshingDeviceDestinationLocation,
            isRideDetectionArmed: isRideDetectionArmed
        )
        let shouldTrackInBackground =
            RideActivityPolicy.shouldTrackLocationInBackground(
                isNavigating: isNavigating,
                isWorkoutActive: isWorkoutActive || isSocialRideSharing,
                isRefreshingDeviceDestinationLocation:
                    isRefreshingDeviceDestinationLocation,
                isRideDetectionArmed: isRideDetectionArmed
            )

        if isApplicationActive && isRideDetectionArmed &&
            locationManager.authorizationLevel == .denied &&
            locationManager.authorizationStatus == .notDetermined &&
            !hasRequestedWhenInUseAuthorizationForRideDetection {
            hasRequestedWhenInUseAuthorizationForRideDetection = true
            locationManager.requestWhenInUseAuthorization()
        }

        if shouldTrackInBackground &&
            locationManager.authorizationLevel == .whenInUse &&
            isApplicationActive &&
            ((!isPhoneWorkoutActive && !isSocialRideSharing) || isNavigating || isRideDetectionArmed) &&
            !hasRequestedAlwaysAuthorizationForRideActivity {
            hasRequestedAlwaysAuthorizationForRideActivity = true
            locationManager.requestAlwaysAuthorization()
        }

        // A phone workout or explicitly consented social ride started in foreground may continue the
        // same When-In-Use location stream with the system background indicator.
        // Do not grant this exception to navigation, Watch mirroring or passive
        // ride detection, and never cold-start When-In-Use GPS in background.
        let phoneWhenInUse = (isPhoneWorkoutActive || isSocialRideSharing)
            && locationManager.authorizationLevel == .whenInUse
        let canTrackInBackground = shouldTrackInBackground &&
            (locationManager.authorizationLevel == .always || phoneWhenInUse)
        locationManager.setBackgroundTrackingEnabled(canTrackInBackground)

        let canStartUpdates =
            locationManager.authorizationLevel == .always
                || isApplicationActive
                || (phoneWhenInUse && isLocationUpdating)
        // A restart stops the stream before starting it again. When-In-Use
        // may only continue a foreground-started stream in background, so a
        // restart there would be a background cold start.
        let canRestartUpdates =
            locationManager.authorizationLevel == .always || isApplicationActive

        if shouldTrack &&
            isLocationAuthorized &&
            canStartUpdates &&
            (!isLocationUpdating || (restart && canRestartUpdates)) {
            if isLocationUpdating {
                locationManager.stopUpdatingLocation()
            }
            print("🌍 Starting location updates (navigating: \(isNavigating), map: \(isViewingMap), workout: \(isWorkoutActive), ride detection: \(isRideDetectionArmed), device destination request: \(isRefreshingDeviceDestinationLocation))")
            locationManager.startUpdatingLocation()
            isLocationUpdating = true
            locationUpdatesPaused = false
            isRecoveryDeferred = false
            trackingStartedAt = now()
            startRecoveryTimerIfNeeded()
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
            stopRecoveryTimer()
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
            trackingStartedAt = now()
            startRecoveryTimerIfNeeded()
        }
    }
    
    func stopUpdatingLocation() {
        if isLocationUpdating {
            locationManager.stopUpdatingLocation()
            isLocationUpdating = false
            stopRecoveryTimer()
        }
    }

    deinit { recoveryTimer?.invalidate() }

    private func startRecoveryTimerIfNeeded() {
        guard recoveryTimer == nil else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            self?.recoverLocationIfNeeded()
        }
        recoveryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRecoveryTimer() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        trackingStartedAt = nil
        lastUsableLocationAt = nil
        lastRecoveryAt = nil
        locationUpdatesPaused = false
        isRecoveryDeferred = false
    }

    // Packet delivery to BLE is not evidence that Core Location is still
    // producing fixes. Recover from pause/error/stale streams using source
    // timestamps, and let the ordinary demand/authorization gates own restarts.
    func recoverLocationIfNeeded() {
        guard isLocationUpdating else { return }
        let date = now()
        let baseline = max(trackingStartedAt ?? date, lastUsableLocationAt ?? .distantPast)
        guard locationUpdatesPaused || date.timeIntervalSince(baseline) >= Self.locationStallInterval else { return }
        let reason = locationUpdatesPaused ? "paused" : "stale"
        // Keep a background When-In-Use stream and its indicator rather than
        // stopping it; foreground activation performs the deferred restart.
        guard applicationIsActive() || locationManager.authorizationLevel == .always else {
            if !isRecoveryDeferred {
                isRecoveryDeferred = true
                diagnosticsRecorder?.record(category: .gps, event: "tracking_restart_deferred",
                    fields: ["reason": reason])
            }
            return
        }
        guard lastRecoveryAt.map({ date.timeIntervalSince($0) >= Self.locationRecoveryInterval }) ?? true else { return }
        lastRecoveryAt = date
        isRecoveryDeferred = false
        diagnosticsRecorder?.record(category: .gps, event: "tracking_restarted",
            fields: ["reason": reason])
        updateLocationTracking(restart: true)
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        guard isLocationUpdating else { return }
        locationUpdatesPaused = true
        diagnosticsRecorder?.record(category: .gps, event: "updates_paused")
        recoverLocationIfNeeded()
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        locationUpdatesPaused = false
        diagnosticsRecorder?.record(category: .gps, event: "updates_resumed")
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
        let receivedAt = self.now()
        let sourceAge = receivedAt.timeIntervalSince(location.timestamp)
        if location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0,
           CLLocationCoordinate2DIsValid(location.coordinate),
           sourceAge >= -1, sourceAge < Self.locationStallInterval {
            lastUsableLocationAt = location.timestamp
            locationUpdatesPaused = false
            isRecoveryDeferred = false
        }

        let now = receivedAt
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
        // Record the cause before any stop/restart it triggers.
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
        // Transient locationUnknown errors do not invalidate a running stream.
        // The watchdog retries a stalled stream without an error/restart loop.
        updateLocationTracking()
        recoverLocationIfNeeded()
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
