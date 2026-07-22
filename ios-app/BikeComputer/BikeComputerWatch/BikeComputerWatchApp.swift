import SwiftUI

@main
struct BikeComputerWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WatchWorkoutRootView(manager: appDelegate.workoutManager)
                .onOpenURL { url in
                    appDelegate.workoutManager.handleLaunchURL(url)
                }
        }
    }
}
