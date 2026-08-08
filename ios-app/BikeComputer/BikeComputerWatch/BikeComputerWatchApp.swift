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
                deviceLink: appDelegate.deviceLink,
                navigationSettings: appDelegate.navigationSettings,
                favoriteStore: appDelegate.favoriteStore
            )
                .onOpenURL { url in
                    appDelegate.workoutManager.handleLaunchURL(url)
                }
        }
    }
}
