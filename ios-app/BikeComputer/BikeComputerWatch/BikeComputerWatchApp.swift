import SwiftUI

@main
struct BikeComputerWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WatchWorkoutRootView(
                manager: appDelegate.workoutManager,
                routeLibrary: appDelegate.routeLibrary,
                navigationManager: appDelegate.navigationManager,
                navigationSettings: appDelegate.navigationSettings
            )
                .onOpenURL { url in
                    appDelegate.workoutManager.handleLaunchURL(url)
                }
        }
    }
}
