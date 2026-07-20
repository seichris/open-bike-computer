//
//  BikeComputerCoordinator.swift
//  BikeComputer
//
//  Central coordinator managing all app subsystems
//  Implements coordinator pattern to eliminate circular dependencies
//

import Foundation
import SwiftUI
import MapKit
import Combine
import CoreLocation

@MainActor
protocol NavigationDirectionsTask: AnyObject {
    func calculate(
        completion: @escaping @MainActor (Result<[MKRoute], Error>) -> Void
    )
    func cancel()
}

@MainActor
final class MapKitNavigationDirectionsTask: NavigationDirectionsTask {
    private let directions: MKDirections

    init(request: MKDirections.Request) {
        directions = MKDirections(request: request)
    }

    func calculate(
        completion: @escaping @MainActor (Result<[MKRoute], Error>) -> Void
    ) {
        directions.calculate { response, error in
            MainActor.assumeIsolated {
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(response?.routes ?? []))
                }
            }
        }
    }

    func cancel() {
        directions.cancel()
    }
}

typealias NavigationDirectionsFactory = @MainActor (MKDirections.Request) -> any NavigationDirectionsTask

enum NavigationStartOutcome: Equatable {
    case started
    case failed(String)
}

/// Main coordinator for the Bike Computer app
/// Manages BLE, navigation, and location subsystems.
@MainActor
class BikeComputerCoordinator: ObservableObject {

    // MARK: - Private Managers (Implementation Details)

    let bleManager = BLEManager()  // Accessible for settings view
    let firmwareUpdateManager = FirmwareUpdateManager()
    let destinationStore: SavedDestinationStore
    private let navEngine = NavigationEngine()
    private let locationManager = CurrentLocationManager()
    private let directionsFactory: NavigationDirectionsFactory
    private let startServices: Bool
    private let now: () -> Date

    // MARK: - Published State (UI Observable)

    // BLE Connection
    @Published var isConnected: Bool = false
    @Published var peripheralName: String = ""
    @Published var hardwareLabel: String = ""
    @Published var signalStrength: Int = 0

    // Navigation
    @Published var isNavigating: Bool = false
    @Published var currentInstruction: String = "Ready to Navigate"
    @Published var distanceToManeuver: Int = 0
    @Published var currentIconID: Int = NavigationIconID.straight
    @Published var currentRoute: MKRoute?
    @Published var isSimulationMode: Bool = false
    @Published var simulatedPosition: CLLocationCoordinate2D?
    @Published var routeRemainingDistance: CLLocationDistance?
    @Published var routeRemainingTime: TimeInterval?
    @Published var expectedArrivalDate: Date?

    // Location
    @Published var currentLocation: CLLocation?
    @Published var currentAddress: String = "Current Location"
    @Published var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined

    // Route Calculation
    @Published var routeCalculation = RouteCalculationState()

    // Alerts
    @Published var alert = AlertState()

    // MARK: - Private State

    private var cancellables = Set<AnyCancellable>()
    private var ongoingSourceSearch: MKLocalSearch?
    private var ongoingDestinationSearch: MKLocalSearch?
    private var ongoingDirections: (any NavigationDirectionsTask)?
    private var ongoingRerouteDirections: (any NavigationDirectionsTask)?
    private var latestRerouteLocation: CLLocation?
    private var navigationDestination: MKMapItem?
    private var routeDeviationDetector = RouteDeviationDetector()
    private var lastRerouteRequestDate = Date.distantPast
    private let rerouteCooldown: TimeInterval = 15
    private var transportType: MKDirectionsTransportType = RouteTransportTypes.cycling
    private var deviceCapabilityRefreshGeneration: UInt = 0
    private var routeCalculationGeneration: UInt = 0
    private var pendingNavigationStart: (
        generation: UInt,
        completion: (NavigationStartOutcome) -> Void
    )?
    private var destinationCatalogGeneration: UInt32?
    private var nextDestinationCatalogGeneration =
        DeviceDestinationCatalogGeneration.initial()
    private var destinationCatalogFingerprint: String?
    private var destinationCatalogByToken: [UInt16: SavedDestination] = [:]
    private var destinationCatalogRetryWorkItem: DispatchWorkItem?
    private var pendingDeviceDestinationLocationRequest: DeviceDestinationRequest?
    private var pendingDeviceDestinationLocationObservation: AnyCancellable?
    private var pendingDeviceDestinationLocationTimeout: DispatchWorkItem?
    private var pendingDeviceDestinationRequestDeadline: DispatchWorkItem?
    private var pendingDeviceDestinationRouteGeneration: UInt?
    private var wasNavigating = false

    // MARK: - Initialization

    convenience init() {
        self.init(destinationStore: SavedDestinationStore())
    }

    init(
        destinationStore: SavedDestinationStore,
        directionsFactory: @escaping NavigationDirectionsFactory = {
            MapKitNavigationDirectionsTask(request: $0)
        },
        startServices: Bool = true,
        now: @escaping () -> Date = Date.init
    ) {
        self.destinationStore = destinationStore
        self.directionsFactory = directionsFactory
        self.startServices = startServices
        self.now = now
        setupManagerBindings()
        setupManagers(startServices: startServices)
    }

    // MARK: - Setup

    private func setupManagerBindings() {
        // Bind BLE manager state
        bleManager.$isConnected
            .assign(to: &$isConnected)

        bleManager.$peripheralName
            .assign(to: &$peripheralName)

        bleManager.$hardwareLabel
            .assign(to: &$hardwareLabel)

        bleManager.$signalStrength
            .assign(to: &$signalStrength)

        // Bind navigation engine state
        navEngine.$isNavigating
            .sink { [weak self] navigating in
                guard let self = self else { return }
                self.isNavigating = navigating
                if self.startServices {
                    self.locationManager.setNavigating(navigating && !self.navEngine.isSimulationMode)
                }
                let didStopNavigation = self.wasNavigating && !navigating
                self.wasNavigating = navigating
                if didStopNavigation {
                    self.synchronizeDestinationCatalog(force: true)
                }
            }
            .store(in: &cancellables)

        navEngine.$isSimulationMode
            .assign(to: &$isSimulationMode)

        navEngine.$simulatedPosition
            .assign(to: &$simulatedPosition)

        navEngine.$currentInstruction
            .assign(to: &$currentInstruction)

        navEngine.$distanceToManeuver
            .assign(to: &$distanceToManeuver)

        navEngine.$currentIconID
            .assign(to: &$currentIconID)

        navEngine.$routeRemainingDistance
            .assign(to: &$routeRemainingDistance)

        navEngine.$routeRemainingTime
            .assign(to: &$routeRemainingTime)

        navEngine.$expectedArrivalDate
            .assign(to: &$expectedArrivalDate)

        // Bind location manager state
        locationManager.$currentLocation
            .assign(to: &$currentLocation)

        locationManager.$currentLocation
            .compactMap { $0 }
            .sink { [weak self] location in
                self?.processNavigationLocation(location)
            }
            .store(in: &cancellables)

        bleManager.$isNavigationReady
            .removeDuplicates()
            .sink { [weak self] isReady in
                guard let self else { return }
                self.deviceCapabilityRefreshGeneration &+= 1
                guard isReady else {
                    self.cancelPendingDeviceDestinationLocationResolution()
                    return
                }
                let generation = self.deviceCapabilityRefreshGeneration
                if let location = self.locationManager.currentLocation {
                    self.navEngine.processExternalLocation(location)
                }
                self.requestMapTransferStatusAfterDeviceRefresh()
                DeviceCapabilityRetry.scheduleInitial { [weak self] in
                    self?.refreshDeviceCapabilities(attempt: 0,
                                                    generation: generation)
                }
                self.bleManager.requestDeviceTransferStatus()
                self.scheduleFirmwareUpdateCheckAfterDeviceRefresh()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(
            bleManager.$isNavigationReady,
            bleManager.$supportsDestinationPicker
        )
        .map { $0 && $1 }
        .removeDuplicates()
        .sink { [weak self] isReady in
            guard isReady else { return }
            // @Published emits from willSet. Defer until both BLE properties
            // contain the negotiated values read by the guarded send.
            DispatchQueue.main.async { [weak self] in
                self?.synchronizeDestinationCatalog(force: true)
            }
        }
        .store(in: &cancellables)

        Publishers.CombineLatest3(
            bleManager.$isNavigationReady,
            bleManager.$supportsDestinationPicker,
            destinationStore.$favoriteDestinations
        )
        .map { isReady, supportsDestinationPicker, favorites in
            let hasDeviceDestinations = !DeviceDestinationCatalogBuilder.build(
                favorites: favorites,
                generation: 1
            ).payload.items.isEmpty
            return isReady && supportsDestinationPicker && hasDeviceDestinations
        }
        .removeDuplicates()
        .sink { [weak self] isEnabled in
            // Prepare background permission while the app is active, without
            // running continuous high-accuracy GPS before the rider taps a row.
            self?.locationManager.setDeviceDestinationRequestsEnabled(isEnabled)
        }
        .store(in: &cancellables)

        destinationStore.$favoriteDestinations
            .dropFirst()
            .sink { [weak self] _ in
                // Read the destination store after its @Published property has
                // committed the newly emitted favorites array.
                DispatchQueue.main.async { [weak self] in
                    self?.synchronizeDestinationCatalog()
                }
            }
            .store(in: &cancellables)

        locationManager.$currentLocation
            .compactMap { $0 }
            .combineLatest(bleManager.$isNavigationReady)
            .filter { _, ready in ready }
            .throttle(for: .seconds(8), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _, _ in
                self?.requestMapTransferStatusAfterDeviceRefresh()
            }
            .store(in: &cancellables)

        locationManager.$currentAddress
            .assign(to: &$currentAddress)

        locationManager.$authorizationStatus
            .assign(to: &$locationAuthorizationStatus)

        // Current firmware exposes only the navigation packet characteristic.
    }

    private func setupManagers(startServices: Bool) {
        // Wire up inter-manager dependencies
        navEngine.setBLEManager(bleManager)
        bleManager.onDestinationRequest = { [weak self] request in
            Task { @MainActor in
                self?.handleDestinationRequest(request)
            }
        }
        bleManager.onDestinationCatalogWriteFailure = { [weak self] in
            Task { @MainActor in
                self?.scheduleDestinationCatalogRetry()
            }
        }
        guard startServices else { return }

        // Start BLE operations
        bleManager.startScanning()

        // Enable location tracking for map view
        locationManager.setViewingMap(true)
    }

    private func processNavigationLocation(_ location: CLLocation) {
        let acceptedForNavigation = navEngine.processExternalLocation(location)
        if acceptedForNavigation {
            if ongoingRerouteDirections != nil,
               routeDeviationDetector.isEligible(
                   horizontalAccuracy: location.horizontalAccuracy
               ) {
                let routeLocation = CoordinateConverter.mapKitRouteLocation(
                    fromGPSLocation: location
                )
                latestRerouteLocation = routeLocation
            }
            evaluateRerouting(for: location)
        }
    }

#if HOST_TESTING
    func processNavigationLocationForTesting(_ location: CLLocation) {
        currentLocation = location
        processNavigationLocation(location)
    }
#endif

    // MARK: - Public API: BLE

    func disconnect() {
        bleManager.disconnect()
    }

    func reconnect() {
        bleManager.reconnect()
    }

    // MARK: - Public API: Navigation

    func startNavigation(
        from source: RouteEndpoint,
        to destination: RouteEndpoint,
        transportType: MKDirectionsTransportType,
        isTestMode: Bool = false,
        completion: ((NavigationStartOutcome) -> Void)? = nil
    ) {
        calculateRoute(
            from: source,
            to: destination,
            requestedTransportType: transportType,
            isTestMode: isTestMode,
            completion: completion
        )
    }

    func startNavigation(from source: String, to destination: String, transportType: MKDirectionsTransportType, isTestMode: Bool = false) {
        startNavigation(from: .query(source), to: .query(destination), transportType: transportType, isTestMode: isTestMode)
    }

    func stopNavigation() {
        ongoingRerouteDirections?.cancel()
        ongoingRerouteDirections = nil
        latestRerouteLocation = nil
        navigationDestination = nil
        routeDeviationDetector.reset()
        lastRerouteRequestDate = .distantPast
        navEngine.stopNavigation()
        currentRoute = nil
        if startServices {
            locationManager.setNavigating(false)
        }
    }

    func handleDestinationSelection(destination: SavedDestination, mapLocation: CLLocation?) {
        guard let sourceLocation = currentLocation ?? mapLocation else {
            alert.message = "Unable to determine your current location. Please enable location services."
            alert.isShowing = true
            return
        }

        guard let coordinate = destination.coordinate else {
            alert.message = "Unable to use the selected map location. Please choose another destination."
            alert.isShowing = true
            return
        }

        let routeSourceLocation = CoordinateConverter.mapKitRouteLocation(fromGPSLocation: sourceLocation)
        let source = MKMapItem(placemark: MKPlacemark(coordinate: routeSourceLocation.coordinate))
        source.name = "Current Location"

        let destinationItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        destinationItem.name = destination.name
        calculateRoute(
            from: .mapItem(source),
            to: .mapItem(destinationItem),
            requestedTransportType: RouteTransportTypes.cycling
        )
    }

    // MARK: - Public API: Location

    func setViewingMap(_ viewing: Bool) {
        locationManager.setViewingMap(viewing)
    }

    func requestLocationAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    func applicationDidBecomeActive() {
        locationManager.prepareDeviceDestinationRequestsIfNeeded()
        bleManager.resumeAutoReconnectIfNeeded()
    }

    var isLocationAuthorized: Bool {
#if os(macOS) && HOST_TESTING
        locationAuthorizationStatus == .authorizedAlways
#else
        locationAuthorizationStatus == .authorizedAlways ||
            locationAuthorizationStatus == .authorizedWhenInUse
#endif
    }

    private func requestMapTransferStatusAfterDeviceRefresh() {
        bleManager.requestMapTransferStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.bleManager.isNavigationReady else { return }
            self.bleManager.requestMapTransferStatus()
        }
    }

    private func scheduleFirmwareUpdateCheckAfterDeviceRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.runAutomaticFirmwareUpdateCheck(attempt: 0)
        }
    }

    private func refreshDeviceCapabilities(attempt: Int, generation: UInt) {
        guard DeviceCapabilityRetry.isCurrentSession(
            generation,
            currentGeneration: deviceCapabilityRefreshGeneration
        ) else { return }
        let shouldRequest = DeviceCapabilityRetry.shouldRequest(
            isNavigationReady: bleManager.isNavigationReady,
            hasReceivedCapabilities: bleManager.hasReceivedDeviceCapabilities,
            attempt: attempt
        )
        guard shouldRequest else {
            if bleManager.isNavigationReady,
               !bleManager.hasReceivedDeviceCapabilities,
               attempt >= DeviceCapabilityRetry.maxAttempts {
                bleManager.useDeviceCapabilitiesFallback()
            }
            return
        }

        bleManager.requestDeviceCapabilities()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshDeviceCapabilities(attempt: attempt + 1,
                                            generation: generation)
        }
    }

    private func runAutomaticFirmwareUpdateCheck(attempt: Int) {
        guard bleManager.isNavigationReady else { return }
        guard isFirmwareMetadataReadyForUpdateCheck else {
            if attempt < 5 {
                bleManager.requestDeviceTransferStatus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.runAutomaticFirmwareUpdateCheck(attempt: attempt + 1)
                }
            }
            return
        }
        firmwareUpdateManager.checkForUpdateAutomatically(bleManager: bleManager)
    }

    private var isFirmwareMetadataReadyForUpdateCheck: Bool {
        !bleManager.firmwareTarget.isEmpty &&
        !bleManager.firmwareVersion.isEmpty &&
        bleManager.firmwareBuild > 0 &&
        !bleManager.firmwareGitSha.isEmpty
    }

    private func synchronizeDestinationCatalog(force: Bool = false) {
        guard bleManager.isNavigationReady,
              bleManager.supportsDestinationPicker else { return }

        let nextGeneration = nextDestinationCatalogGeneration
        let build = DeviceDestinationCatalogBuilder.build(
            favorites: destinationStore.favoriteDestinations,
            generation: nextGeneration
        )
        guard DeviceDestinationCatalogSyncPolicy.shouldPublish(
            force: force,
            lastFingerprint: destinationCatalogFingerprint,
            nextFingerprint: build.sourceFingerprint
        ) else {
            destinationCatalogRetryWorkItem?.cancel()
            destinationCatalogRetryWorkItem = nil
            return
        }
        guard bleManager.sendDestinationCatalog(build.payload) else {
            scheduleDestinationCatalogRetry()
            return
        }

        destinationCatalogRetryWorkItem?.cancel()
        destinationCatalogRetryWorkItem = nil
        destinationCatalogGeneration = nextGeneration
        nextDestinationCatalogGeneration =
            DeviceDestinationCatalogGeneration.next(after: nextGeneration)
        destinationCatalogFingerprint = build.sourceFingerprint
        destinationCatalogByToken = build.destinationsByToken
    }

    private func scheduleDestinationCatalogRetry() {
        guard destinationCatalogRetryWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.destinationCatalogRetryWorkItem = nil
            // A failed enqueue is still unsynchronized even when the source
            // fingerprint matches the last catalog accepted by the queue.
            self.synchronizeDestinationCatalog(force: true)
        }
        destinationCatalogRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    private func handleDestinationRequest(_ request: DeviceDestinationRequest) {
        guard bleManager.isNavigationReady else { return }
        guard let destination = destination(for: request) else {
            rejectStaleDestinationRequest(request)
            return
        }

        guard !isNavigating,
              !routeCalculation.isCalculating,
              pendingDeviceDestinationLocationRequest == nil else {
            bleManager.sendDestinationStatus(
                generation: request.generation,
                token: request.token,
                status: .failed,
                message: "Navigation is already active"
            )
            return
        }

        bleManager.sendDestinationStatus(
            generation: request.generation,
            token: request.token,
            status: .calculating,
            message: "Starting navigation..."
        )
        pendingDeviceDestinationLocationRequest = request
        scheduleDeviceDestinationRequestDeadline(for: request)
        resolveFreshDeviceDestinationLocation { [weak self] location in
            guard let self,
                  self.pendingDeviceDestinationLocationRequest == request else {
                return
            }
            guard self.bleManager.isNavigationReady else {
                self.cancelPendingDeviceDestinationLocationResolution()
                return
            }
            guard let currentDestination = self.destination(for: request),
                  currentDestination == destination else {
                self.finishDeviceDestinationRequest(
                    request,
                    status: .stale,
                    message: "Destination list changed"
                )
                self.synchronizeDestinationCatalog(force: true)
                return
            }
            guard !self.isNavigating, !self.routeCalculation.isCalculating else {
                self.finishDeviceDestinationRequest(
                    request,
                    status: .failed,
                    message: "Navigation is already active"
                )
                return
            }
            guard let location else {
                self.finishDeviceDestinationRequest(
                    request,
                    status: .failed,
                    message: "Current location unavailable"
                )
                return
            }

            let routeLocation = CoordinateConverter.mapKitRouteLocation(
                fromGPSLocation: location
            )
            let source = MKMapItem(placemark: MKPlacemark(
                coordinate: routeLocation.coordinate
            ))
            source.name = "Current Location"
            self.startNavigation(
                from: .mapItem(source),
                to: currentDestination.routeEndpoint,
                transportType: RouteTransportTypes.cycling
            ) { [weak self] outcome in
                guard let self,
                      self.pendingDeviceDestinationLocationRequest == request else {
                    return
                }
                switch outcome {
                case .started:
                    self.finishDeviceDestinationRequest(
                        request,
                        status: .started,
                        message: "Navigation started"
                    )
                    self.destinationStore.addRecent(currentDestination)
                case .failed(let message):
                    self.finishDeviceDestinationRequest(
                        request,
                        status: .failed,
                        message: message
                    )
                }
            }
            self.pendingDeviceDestinationRouteGeneration =
                self.pendingNavigationStart?.generation
        }
    }

    private func scheduleDeviceDestinationRequestDeadline(
        for request: DeviceDestinationRequest
    ) {
        pendingDeviceDestinationRequestDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingDeviceDestinationLocationRequest == request else {
                return
            }
            self.cancelPendingDeviceDestinationRouteCalculation()
            self.finishDeviceDestinationRequest(
                request,
                status: .failed,
                message: "Route request timed out"
            )
        }
        pendingDeviceDestinationRequestDeadline = deadline
        DispatchQueue.main.asyncAfter(
            deadline: .now() + DeviceDestinationRequestTiming.appRequestDeadline,
            execute: deadline
        )
    }

    private func finishDeviceDestinationRequest(
        _ request: DeviceDestinationRequest,
        status: DeviceDestinationStatusCode,
        message: String
    ) {
        guard pendingDeviceDestinationLocationRequest == request else { return }
        pendingDeviceDestinationRequestDeadline?.cancel()
        pendingDeviceDestinationRequestDeadline = nil
        pendingDeviceDestinationLocationObservation?.cancel()
        pendingDeviceDestinationLocationObservation = nil
        pendingDeviceDestinationLocationTimeout?.cancel()
        pendingDeviceDestinationLocationTimeout = nil
        pendingDeviceDestinationLocationRequest = nil
        pendingDeviceDestinationRouteGeneration = nil
        locationManager.endDeviceDestinationLocationRefresh()
        bleManager.sendDestinationStatus(
            generation: request.generation,
            token: request.token,
            status: status,
            message: message
        )
    }

    private func destination(
        for request: DeviceDestinationRequest
    ) -> SavedDestination? {
        guard let generation = destinationCatalogGeneration,
              request.generation == generation,
              let fingerprint = destinationCatalogFingerprint,
              let destination = destinationCatalogByToken[request.token] else {
            return nil
        }
        let currentBuild = DeviceDestinationCatalogBuilder.build(
            favorites: destinationStore.favoriteDestinations,
            generation: generation
        )
        guard currentBuild.sourceFingerprint == fingerprint else { return nil }
        return destination
    }

    private func rejectStaleDestinationRequest(
        _ request: DeviceDestinationRequest
    ) {
        bleManager.sendDestinationStatus(
            generation: request.generation,
            token: request.token,
            status: .stale,
            message: "Destination list changed"
        )
        synchronizeDestinationCatalog(force: true)
    }

    private func resolveFreshDeviceDestinationLocation(
        completion: @escaping (CLLocation?) -> Void
    ) {
        if let currentLocation = locationManager.currentLocation,
           DeviceDestinationLocationPolicy.isUsable(currentLocation) {
            guard locationManager.beginDeviceDestinationLocationRefresh(
                restart: false
            ) else {
                completion(nil)
                return
            }
            completion(currentLocation)
            return
        }

        pendingDeviceDestinationLocationObservation?.cancel()
        pendingDeviceDestinationLocationTimeout?.cancel()

        pendingDeviceDestinationLocationObservation = locationManager.$currentLocation
            .compactMap { $0 }
            .filter { DeviceDestinationLocationPolicy.isUsable($0) }
            .first()
            .sink { [weak self] location in
                guard let self else { return }
                self.pendingDeviceDestinationLocationTimeout?.cancel()
                self.pendingDeviceDestinationLocationTimeout = nil
                self.pendingDeviceDestinationLocationObservation?.cancel()
                self.pendingDeviceDestinationLocationObservation = nil
                completion(location)
            }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDeviceDestinationLocationObservation?.cancel()
            self.pendingDeviceDestinationLocationObservation = nil
            self.pendingDeviceDestinationLocationTimeout = nil
            completion(nil)
        }
        pendingDeviceDestinationLocationTimeout = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + DeviceDestinationRequestTiming.locationRefreshTimeout,
            execute: timeout
        )
        guard locationManager.beginDeviceDestinationLocationRefresh(
            restart: true
        ) else {
            pendingDeviceDestinationLocationObservation?.cancel()
            pendingDeviceDestinationLocationObservation = nil
            pendingDeviceDestinationLocationTimeout?.cancel()
            pendingDeviceDestinationLocationTimeout = nil
            completion(nil)
            return
        }
    }

    private func cancelPendingDeviceDestinationLocationResolution() {
        cancelPendingDeviceDestinationRouteCalculation()
        pendingDeviceDestinationLocationObservation?.cancel()
        pendingDeviceDestinationLocationObservation = nil
        pendingDeviceDestinationLocationTimeout?.cancel()
        pendingDeviceDestinationLocationTimeout = nil
        pendingDeviceDestinationRequestDeadline?.cancel()
        pendingDeviceDestinationRequestDeadline = nil
        pendingDeviceDestinationLocationRequest = nil
        pendingDeviceDestinationRouteGeneration = nil
        locationManager.endDeviceDestinationLocationRefresh()
    }

    private func cancelPendingDeviceDestinationRouteCalculation() {
        guard let generation = pendingDeviceDestinationRouteGeneration,
              routeCalculationGeneration == generation else { return }
        ongoingSourceSearch?.cancel()
        ongoingSourceSearch = nil
        ongoingDestinationSearch?.cancel()
        ongoingDestinationSearch = nil
        ongoingDirections?.cancel()
        ongoingDirections = nil
        if pendingNavigationStart?.generation == generation {
            pendingNavigationStart = nil
        }
        routeCalculationGeneration &+= 1
        routeCalculation.isCalculating = false
        routeCalculation.status = ""
        pendingDeviceDestinationRouteGeneration = nil
    }
}

// MARK: - Route Calculation (Private Implementation)

extension BikeComputerCoordinator {

    private func calculateRoute(
        from source: RouteEndpoint,
        to destination: RouteEndpoint,
        requestedTransportType: MKDirectionsTransportType,
        isTestMode: Bool = false,
        completion: ((NavigationStartOutcome) -> Void)? = nil
    ) {
        print("Starting route calculation")

        // Cancel any ongoing searches
        if let pendingNavigationStart {
            pendingNavigationStart.completion(.failed("Route request replaced"))
            self.pendingNavigationStart = nil
        }
        ongoingSourceSearch?.cancel()
        ongoingDestinationSearch?.cancel()
        ongoingDirections?.cancel()
        ongoingRerouteDirections?.cancel()
        ongoingRerouteDirections = nil
        latestRerouteLocation = nil
        routeDeviationDetector.reset()
        routeCalculationGeneration &+= 1
        let generation = routeCalculationGeneration
        if let completion {
            pendingNavigationStart = (generation, completion)
        }

        routeCalculation.isCalculating = true
        routeCalculation.status = "Searching for locations..."

        resolveEndpoint(source, role: "Starting location", generation: generation) { [weak self] sourceItem in
            guard let self, self.routeCalculationGeneration == generation else { return }
            guard let sourceItem else {
                self.completeNavigationStart(.failed(self.routeCalculation.status.isEmpty
                    ? "Starting location unavailable"
                    : self.routeCalculation.status), generation: generation)
                return
            }

            self.routeCalculation.status = "Finding destination..."
            self.resolveEndpoint(destination, role: "Destination", generation: generation) { [weak self] destinationItem in
                guard let self, self.routeCalculationGeneration == generation else { return }
                guard let destinationItem else {
                    self.completeNavigationStart(.failed(self.routeCalculation.status.isEmpty
                        ? "Destination unavailable"
                        : self.routeCalculation.status), generation: generation)
                    return
                }

                self.routeCalculation.status = "Calculating route..."
                self.requestDirections(
                    from: sourceItem,
                    to: destinationItem,
                    requestedTransportType: requestedTransportType,
                    isTestMode: isTestMode,
                    generation: generation
                )
            }
        }
    }

    private func resolveEndpoint(
        _ endpoint: RouteEndpoint,
        role: String,
        generation: UInt,
        completion: @escaping (MKMapItem?) -> Void
    ) {
        switch endpoint {
        case .currentLocation:
            guard let currentLoc = currentLocation else {
                routeCalculation.status = "Current location unavailable"
                alert.message = "Unable to determine your current location. Please enable location services."
                alert.isShowing = true
                finishRouteCalculationAfterDelay(generation: generation)
                completion(nil)
                return
            }

            let routeLocation = CoordinateConverter.mapKitRouteLocation(fromGPSLocation: currentLoc)
            let item = MKMapItem(placemark: MKPlacemark(coordinate: routeLocation.coordinate))
            item.name = "Current Location"
            print("Using current location: \(routeLocation.coordinate.latitude), \(routeLocation.coordinate.longitude)")
            completion(item)

        case .mapItem(let item):
            print("\(role): \(item.name ?? "Map Item") at \(item.placemark.coordinate.latitude), \(item.placemark.coordinate.longitude)")
            completion(item)

        case .query(let query):
            let searchRequest = MKLocalSearch.Request()
            searchRequest.naturalLanguageQuery = query
            if let currentLocation {
                let routeLocation = CoordinateConverter.mapKitRouteLocation(fromGPSLocation: currentLocation)
                searchRequest.region = MKCoordinateRegion(
                    center: routeLocation.coordinate,
                    latitudinalMeters: 50000,
                    longitudinalMeters: 50000
                )
            }

            let search = MKLocalSearch(request: searchRequest)
            if role == "Starting location" {
                ongoingSourceSearch = search
            } else {
                ongoingDestinationSearch = search
            }

            search.start { [weak self] response, error in
                guard let self, self.routeCalculationGeneration == generation else { return }

                if role == "Starting location" {
                    self.ongoingSourceSearch = nil
                } else {
                    self.ongoingDestinationSearch = nil
                }

                if let error = error {
                    print("Error searching for \(role): \(error.localizedDescription)")
                    self.routeCalculation.status = "\(role) not found"
                    self.finishRouteCalculationAfterDelay(generation: generation)
                    completion(nil)
                    return
                }

                guard let item = response?.mapItems.first else {
                    print("No results for \(role)")
                    self.routeCalculation.status = "\(role) not found"
                    self.finishRouteCalculationAfterDelay(generation: generation)
                    completion(nil)
                    return
                }

                print("\(role) found: \(item.name ?? "Unknown") at \(item.placemark.coordinate.latitude), \(item.placemark.coordinate.longitude)")
                completion(item)
            }
        }
    }

    private func finishRouteCalculationAfterDelay(generation: UInt) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.routeCalculationGeneration == generation else { return }
            self.routeCalculation.isCalculating = false
            self.routeCalculation.status = ""
        }
    }

    private func requestDirections(
        from sourceItem: MKMapItem,
        to destinationItem: MKMapItem,
        requestedTransportType: MKDirectionsTransportType,
        isTestMode: Bool,
        generation: UInt
    ) {
        let request = MKDirections.Request()
        request.source = sourceItem
        request.destination = destinationItem
        request.transportType = requestedTransportType
        request.requestsAlternateRoutes = false

        print("Calculating route with transport type: \(self.transportType.rawValue)")

        let directions = directionsFactory(request)
        self.ongoingDirections = directions
        let initialLocation = RouteInitialLocation.location(
            for: sourceItem.placemark.coordinate
        )
        directions.calculate { [weak self] result in
            guard let self, self.routeCalculationGeneration == generation else { return }
            self.ongoingDirections = nil

            switch result {
            case .failure(let error):
                print("Error calculating route: \(error.localizedDescription)")
                // SHOW ERROR ON SCREEN
                self.routeCalculation.status = "Err: \(error.localizedDescription)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    guard self.routeCalculationGeneration == generation else { return }
                    self.routeCalculation.isCalculating = false
                    self.routeCalculation.status = ""
                }
                self.completeNavigationStart(
                    .failed(error.localizedDescription),
                    generation: generation
                )
                return
            case .success(let routes):
                guard let route = routes.first else {
                    print("No routes found")
                    self.routeCalculation.status = "No route available"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        guard self.routeCalculationGeneration == generation else { return }
                        self.routeCalculation.isCalculating = false
                        self.routeCalculation.status = ""
                    }
                    self.completeNavigationStart(
                        .failed("No route available"),
                        generation: generation
                    )
                    return
                }

                print("Route calculated successfully!")
                print("Distance: \(route.distance)m, ETA: \(route.expectedTravelTime)s")
                print("Steps: \(route.steps.count)")

                self.routeCalculation.status = "Starting navigation..."

                // Store the route for map display
                self.currentRoute = route
                self.navigationDestination = destinationItem
                self.transportType = requestedTransportType
                self.routeDeviationDetector.reset()
                self.lastRerouteRequestDate = .distantPast

                // Start navigation from the same source MapKit used to calculate the route.
                self.navEngine.startNavigation(
                    with: route,
                    isTestMode: isTestMode,
                    initialLocation: initialLocation
                )

                // Enable location tracking for navigation
                if self.startServices {
                    self.locationManager.setNavigating(!isTestMode)
                }

                self.completeNavigationStart(.started, generation: generation)

                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard self.routeCalculationGeneration == generation else { return }
                    self.routeCalculation.isCalculating = false
                    self.routeCalculation.status = ""
                }
            }
        }
    }

    private func evaluateRerouting(for gpsLocation: CLLocation) {
        guard navEngine.isNavigating,
              !navEngine.isSimulationMode,
              !routeCalculation.isCalculating,
              ongoingRerouteDirections == nil,
              let route = currentRoute,
              let destination = navigationDestination else {
            routeDeviationDetector.reset()
            return
        }

        guard now().timeIntervalSince(lastRerouteRequestDate) >= rerouteCooldown else {
            routeDeviationDetector.reset()
            return
        }

        let routeLocation = CoordinateConverter.mapKitRouteLocation(fromGPSLocation: gpsLocation)
        guard let distanceToRoute = navEngine.distanceToCurrentStep(from: routeLocation)
                ?? RouteDeviation.distance(from: routeLocation, to: route.polyline),
              routeDeviationDetector.shouldReroute(
                distanceToRoute: distanceToRoute,
                horizontalAccuracy: gpsLocation.horizontalAccuracy
              ) else {
            return
        }

        requestReroute(from: routeLocation, to: destination, distanceToRoute: distanceToRoute)
    }

    private func requestReroute(
        from routeLocation: CLLocation,
        to destination: MKMapItem,
        distanceToRoute: CLLocationDistance
    ) {
        let source = MKMapItem(placemark: MKPlacemark(coordinate: routeLocation.coordinate))
        source.name = "Current Location"

        let request = MKDirections.Request()
        request.source = source
        request.destination = destination
        request.transportType = transportType
        request.requestsAlternateRoutes = false

        lastRerouteRequestDate = now()
        print("Off route by \(Int(distanceToRoute.rounded()))m; requesting reroute")

        let directions = directionsFactory(request)
        ongoingRerouteDirections = directions
        latestRerouteLocation = routeLocation
        directions.calculate { [weak self] result in
            guard let self,
                  let activeDirections = self.ongoingRerouteDirections,
                  activeDirections === directions else {
                return
            }
            self.ongoingRerouteDirections = nil

            switch result {
            case .failure(let error):
                self.latestRerouteLocation = nil
                print("Reroute failed: \(error.localizedDescription)")
                return
            case .success(let routes):
                guard self.navEngine.isNavigating,
                      let route = routes.first else {
                    self.latestRerouteLocation = nil
                    print("Reroute returned no route")
                    return
                }

                let latestRouteLocation = self.latestRerouteLocation ?? routeLocation
                self.latestRerouteLocation = nil
                if let latestDistanceToRoute = RouteDeviation.distance(
                    from: latestRouteLocation,
                    to: route.polyline
                ), self.routeDeviationDetector.isOffRoute(
                    distanceToRoute: latestDistanceToRoute,
                    horizontalAccuracy: latestRouteLocation.horizontalAccuracy
                ) {
                    print("Discarding stale reroute response; rider is now \(Int(latestDistanceToRoute.rounded()))m away")
                    self.routeDeviationDetector.reset()
                    return
                }

                self.currentRoute = route
                self.routeDeviationDetector.reset()
                self.navEngine.replaceRoute(
                    with: route,
                    currentLocation: latestRouteLocation
                )
                print("Reroute applied: \(Int(route.distance.rounded()))m, \(route.steps.count) steps")
            }
        }
    }

    private func completeNavigationStart(
        _ outcome: NavigationStartOutcome,
        generation: UInt
    ) {
        guard let pendingNavigationStart,
              pendingNavigationStart.generation == generation else { return }
        self.pendingNavigationStart = nil
        pendingNavigationStart.completion(outcome)
    }
}
