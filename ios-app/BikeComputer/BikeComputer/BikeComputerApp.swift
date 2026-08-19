//
//  BikeComputerApp.swift
//  BikeComputer
//
//  Main iOS App Entry Point
//

import AppIntents
import Combine
import CoreLocation
import SwiftUI

@main
struct BikeComputerApp: App {
    
    // Ensure app continues running in background for navigation
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView(
                workoutMirrorManager: appDelegate.workoutMirrorManager,
                cyclingSensorStore: appDelegate.cyclingSensorStore,
                cyclingSensorDetectionCoordinator:
                    appDelegate.cyclingSensorDetectionCoordinator,
                coordinator: appDelegate.coordinator,
                rideDetectionSettingsStore:
                    appDelegate.rideDetectionSettingsStore,
                rideAutomationCoordinator:
                    appDelegate.rideAutomationCoordinator,
                watchAvailability: appDelegate.watchAvailability,
                routeLibrary: appDelegate.routeLibrary,
                liveActivityDiagnostics:
                    appDelegate.workoutLiveActivityDiagnostics,
                rideDiagnosticsRecorder: appDelegate.rideDiagnosticsRecorder,
                onApplicationActiveChange: {
                    appDelegate.setApplicationActive($0)
                }
            )
        }
    }
}

// MARK: - App Delegate for Background Tasks

@MainActor
class AppDelegate: NSObject, UIApplicationDelegate {
    let workoutMirrorManager: WorkoutMirrorManager
    let cyclingSensorStore: CyclingSensorStore
    let cyclingSensorDetectionCoordinator:
        CyclingSensorDetectionCoordinator
    let rideDetectionSettingsStore: RideDetectionSettingsStore
    let watchConnectivityCoordinator: PhoneWatchConnectivityCoordinator
    let watchAvailability: WorkoutWatchAvailabilityMonitor
    let routeLibrary: PhoneRouteLibrary
    let destinationStore: SavedDestinationStore
    let locationManager = CurrentLocationManager()
    let rideDiagnosticsRecorder: RideDiagnosticsRecorder
    let workoutLiveActivityDiagnostics =
        WorkoutLiveActivityDiagnosticStore()
    private var workoutLiveActivityController: AnyObject?
    private var workoutLiveActivityCommandRouter: AnyObject?
    private var workoutLiveActivityIntentDispatcher: AnyObject?
    private var cancellables = Set<AnyCancellable>()
    lazy var coordinator = BikeComputerCoordinator(
        destinationStore: destinationStore,
        workoutMetricsStore: workoutMirrorManager.store,
        locationManager: locationManager,
        rideDetectionSettingsStore: rideDetectionSettingsStore
    )
    lazy var rideAutomationCoordinator = RideAutomationCoordinator(
        bleManager: coordinator.bleManager,
        workoutManager: workoutMirrorManager,
        settingsStore: rideDetectionSettingsStore,
        watchAvailability: watchAvailability
    )

    override init() {
        let workoutMirrorManager = WorkoutMirrorManager()
        let cyclingSensorStore = CyclingSensorStore()
        let cyclingSensorDetectionCoordinator =
            CyclingSensorDetectionCoordinator(
                sensorStore: cyclingSensorStore
            )
        let rideDetectionSettingsStore = RideDetectionSettingsStore()
        let watchConnectivityCoordinator =
            PhoneWatchConnectivityCoordinator()
        let destinationStore = SavedDestinationStore()
        let rideDiagnosticsRecorder = RideDiagnosticsRecorder()
        let watchAvailability = WorkoutWatchAvailabilityMonitor(
            heartRateZoneDefaults: .standard,
            connectivityCoordinator: watchConnectivityCoordinator,
            rideDetectionSettingsStore: rideDetectionSettingsStore
        )
        self.workoutMirrorManager = workoutMirrorManager
        self.cyclingSensorStore = cyclingSensorStore
        self.cyclingSensorDetectionCoordinator =
            cyclingSensorDetectionCoordinator
        self.rideDetectionSettingsStore = rideDetectionSettingsStore
        self.watchConnectivityCoordinator = watchConnectivityCoordinator
        self.destinationStore = destinationStore
        self.rideDiagnosticsRecorder = rideDiagnosticsRecorder
        self.watchAvailability = watchAvailability
        routeLibrary = PhoneRouteLibrary(
            connectivity: watchConnectivityCoordinator
        )
        super.init()
        destinationStore.$favoriteDestinations
            .map { destinations in
                Array(destinations.compactMap { destination in
                    guard let coordinate = destination.coordinate else {
                        return nil
                    }
                    let normalized =
                        RouteCoordinateNormalizationV1.mapKitToWGS84(
                            RouteCoordinateV1(
                                latitude: coordinate.latitude,
                                longitude: coordinate.longitude
                            )
                        )
                    return SyncedCoordinateFavoriteV1(
                        id: destination.id,
                        name: destination.name,
                        coordinate: normalized
                    )
                }.prefix(CoordinateFavoritesEnvelopeV1.maximumFavorites))
            }
            .removeDuplicates()
            .sink { [weak watchConnectivityCoordinator] favorites in
                try? watchConnectivityCoordinator?.updateCoordinateFavorites(
                    favorites
                )
            }
            .store(in: &cancellables)
        cyclingSensorDetectionCoordinator.bind(
            to: workoutMirrorManager.store
        )
        locationManager.bindWorkoutMetricsStore(
            workoutMirrorManager.store
        )
    }
    
    func application(_ application: UIApplication, 
                    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // Configure for background location updates
        print("Bicino app launched")
        rideDiagnosticsRecorder.recordApplicationLifecycle(
            "app_launched",
            state: application.applicationState == .active ? "active" : "background"
        )
        _ = coordinator
        _ = rideAutomationCoordinator
        let bleManager = coordinator.bleManager
        bleManager.diagnosticsRecorder = rideDiagnosticsRecorder
        locationManager.diagnosticsRecorder = rideDiagnosticsRecorder
        coordinator.diagnosticsRecorder = rideDiagnosticsRecorder
        rideDiagnosticsRecorder.$detailedTraceEnabled
            .removeDuplicates()
            .sink { [weak bleManager, weak rideDiagnosticsRecorder] enabled in
                if enabled {
                    _ = bleManager?.sendDiagnosticsCaptureBinding(
                        rideDiagnosticsRecorder?.currentCaptureID
                    )
                } else {
                    _ = bleManager?.endDiagnosticsCapture()
                }
            }
            .store(in: &cancellables)
        coordinator.$isNavigating
            .scan((previous: false, current: false)) { state, navigating in
                (previous: state.current, current: navigating)
            }
            .filter { $0.previous && !$0.current }
            .sink { [weak rideDiagnosticsRecorder] _ in
                rideDiagnosticsRecorder?.endDetailedTrace(reason: "ride_ended")
            }
            .store(in: &cancellables)
        bleManager.bindWatchConnectivityCoordinator(
            watchConnectivityCoordinator
        )
        watchConnectivityCoordinator.onDirectRidePreparationRequest = {
            [weak self, weak bleManager] request in
            guard let self, let bleManager else {
                return WatchDirectRidePreparationResponseV1(
                    requestID: request.requestID,
                    accepted: false,
                    errorCode: "handler_unavailable"
                )
            }
            return bleManager.handleWatchDirectRidePreparationRequest(
                request,
                phoneNavigationActive: self.coordinator.isNavigating
            )
        }
        watchConnectivityCoordinator.$state
            .removeDuplicates()
            .sink { [weak bleManager] state in
                bleManager?.updateWatchConnectivityState(state)
            }
            .store(in: &cancellables)
        bleManager.$activeDeviceID
            .removeDuplicates()
            .sink { [weak watchConnectivityCoordinator] deviceID in
                try? watchConnectivityCoordinator?
                    .updateSelectedBikeComputer(deviceID: deviceID)
            }
            .store(in: &cancellables)
        watchConnectivityCoordinator.activate()
        workoutMirrorManager.installMirroringHandler()
        if #available(iOS 17.0, *) {
            let controller = WorkoutLiveActivityController(
                store: workoutMirrorManager.store,
                diagnostics: workoutLiveActivityDiagnostics
            )
            controller.start(
                isApplicationForeground: application.applicationState == .active
            )
            let commandRouter = WorkoutLiveActivityCommandRouter(
                manager: workoutMirrorManager
            )
            let dispatcher = WorkoutLiveActivityIntentDispatcher {
                [weak commandRouter, weak controller] action, sessionID in
                guard let commandRouter, let controller else { return false }
                guard await commandRouter.perform(
                    action,
                    sessionID: sessionID
                ) else {
                    return false
                }
                _ = await controller.publishCurrentStateForIntent(
                    sessionID: sessionID
                )
                await commandRouter.waitForResolution(
                    of: action,
                    sessionID: sessionID
                )
                _ = await controller.publishCurrentStateForIntent(
                    sessionID: sessionID
                )
                return true
            }
            AppDependencyManager.shared.add(dependency: dispatcher)

            workoutLiveActivityCommandRouter = commandRouter
            workoutLiveActivityIntentDispatcher = dispatcher
            workoutLiveActivityController = controller
        }
        
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        rideDiagnosticsRecorder.recordApplicationLifecycle(
            "app_active",
            state: "active"
        )
        coordinator.applicationDidBecomeActive()
        setApplicationActive(true)
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        rideDiagnosticsRecorder.recordApplicationLifecycle(
            "app_backgrounded",
            state: "background"
        )
        coordinator.setViewingMap(false)
        setApplicationActive(false)
        print("App entered background - navigation continues")
    }

    func setApplicationActive(_ isActive: Bool) {
        coordinator.setApplicationActive(isActive)
        if #available(iOS 17.0, *),
           let controller =
               workoutLiveActivityController
                as? WorkoutLiveActivityController {
            controller.setApplicationForeground(isActive)
        }
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        rideDiagnosticsRecorder.recordApplicationLifecycle(
            "app_foregrounding",
            state: "foregrounding"
        )
        print("App entering foreground")
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundMapUploadCoordinator.sessionIdentifier else {
            completionHandler()
            return
        }
        BackgroundMapUploadCoordinator.shared.handleEvents(
            completionHandler: completionHandler
        )
    }
}
