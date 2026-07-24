//
//  BikeComputerApp.swift
//  BikeComputer
//
//  Main iOS App Entry Point
//

import AppIntents
import SwiftUI

@main
struct BikeComputerApp: App {
    
    // Ensure app continues running in background for navigation
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView(
                workoutMirrorManager: appDelegate.workoutMirrorManager,
                coordinator: appDelegate.coordinator,
                liveActivityDiagnostics:
                    appDelegate.workoutLiveActivityDiagnostics,
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
    let workoutMirrorManager = WorkoutMirrorManager()
    let locationManager = CurrentLocationManager()
    let workoutLiveActivityDiagnostics =
        WorkoutLiveActivityDiagnosticStore()
    private var workoutLiveActivityController: AnyObject?
    private var workoutLiveActivityCommandRouter: AnyObject?
    private var workoutLiveActivityIntentDispatcher: AnyObject?
    lazy var coordinator = BikeComputerCoordinator(
        destinationStore: SavedDestinationStore(),
        workoutMetricsStore: workoutMirrorManager.store,
        locationManager: locationManager
    )

    override init() {
        super.init()
        locationManager.bindWorkoutMetricsStore(
            workoutMirrorManager.store
        )
    }
    
    func application(_ application: UIApplication, 
                    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // Configure for background location updates
        print("BikeComputer app launched")
        _ = coordinator
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
        coordinator.applicationDidBecomeActive()
        setApplicationActive(true)
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        coordinator.setViewingMap(false)
        setApplicationActive(false)
        print("App entered background - navigation continues")
    }

    func setApplicationActive(_ isActive: Bool) {
        if #available(iOS 17.0, *),
           let controller =
               workoutLiveActivityController
                as? WorkoutLiveActivityController {
            controller.setApplicationForeground(isActive)
        }
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
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
