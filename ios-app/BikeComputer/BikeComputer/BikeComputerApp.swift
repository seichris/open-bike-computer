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
            ContentView()
        }
    }
}

// MARK: - App Delegate for Background Tasks

class AppDelegate: NSObject, UIApplicationDelegate {
    
    func application(_ application: UIApplication, 
                    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // Configure for background location updates
        print("BikeComputer app launched")
        
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
