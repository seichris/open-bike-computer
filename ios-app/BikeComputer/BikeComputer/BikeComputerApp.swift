//
//  BikeComputerApp.swift
//  BikeComputer
//
//  Main iOS App Entry Point
//

import SwiftUI

@main
struct BikeComputerApp: App {
    
    // Ensure app continues running in background for navigation
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView(workoutMirrorManager: appDelegate.workoutMirrorManager)
        }
    }
}

// MARK: - App Delegate for Background Tasks

@MainActor
class AppDelegate: NSObject, UIApplicationDelegate {
    let workoutMirrorManager = WorkoutMirrorManager()
    
    func application(_ application: UIApplication, 
                    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // Configure for background location updates
        print("BikeComputer app launched")
        workoutMirrorManager.installMirroringHandler()
        
        return true
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        print("App entered background - navigation continues")
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
